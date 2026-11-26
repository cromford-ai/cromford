#!/bin/bash
# tests/pool-account-test.sh — WHAT A QUOTA READING MEANS, to both pickers.
#
# WHY THIS FILE EXISTS, SEPARATELY FROM pool-account-routing-test.sh. That suite
# drives the bundle swap: the bytes a machine boots with. This one drives the
# single judgement UNDER it — "does this reading exclude the account" — because
# the two pickers used to answer it separately and drifted apart in the only
# direction that costs money.
#
# The drift, 2026-09-16: bin/quota-poll.sh writes `status: unreadable` for every
# claude account that has no CLAUDE_CONFIG_DIR (its header says so — a setup
# token gets 403 on the usage endpoint, so there is nothing honest to write but
# "we cannot read this"). Every pool account is exactly that shape. The hub's
# account_headroom read `unreadable` as "no evidence against" and used the
# account; the pool's _pa_metered read it as "not ok" and dropped it. So the pool
# ranked ZERO accounts, logged `default_saturated` on every spawn, and shipped
# the one capped default token to every machine it launched.
#
# So the cases below are about the READING, not the bytes:
#   1  three accounts whose quota is all `unreadable` -> a lease is taken, on the
#      lowest priority NUMBER, and the bundle carries that account's token; the
#      log never names an `all_unreadable` class, because there is not one
#   2  a cooling account is skipped even when it would otherwise win
#   3  a `status: stale` account, and an `ok` poll that has aged past
#      ACCOUNT_POLL_STALE_SECS, are both skipped — a poller that stopped is a
#      different failure from a poller that answered honestly
#   4  account_headroom and the pool's filter agree on the same file, through one
#      shared classifier — including where they deliberately differ:
#        a  fresh `unreadable`        both usable, empty meter
#        b  fresh `ok` under the caps  both usable, meter survives
#        c  fresh `ok` over a cap      both exclude
#        d  aged `ok`, and no file     hub usable, pool excluded
#        e  AGED `unreadable`          still `unreadable`, still usable to both
#        f  `status: stale` from the poller itself, freshly polled
#   5  the fallback names its class: all_capped, all_stale, all_cooling,
#      all_leased, and `default_saturated` only for a MIXED set — never a bare
#      `default_saturated` for all of them, and never an `all_unreadable`
#
# Run from anywhere: tests/pool-account-test.sh   (exit 0 = all pass)
# Linux/GNU, like the rest of the suite: bin/run-tests-in-docker.sh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TOK_MASTER="sk-ant-oat01-FIXTURE-MASTER-token"

mkdir -p "$T/bin/lib" "$T/env/accounts.d" "$T/env/tokens.d" "$T/state/quota" \
         "$T/logs" "$T/flags" "$T/fly" "$T/bundle"
for f in account-pick.sh auth-fingerprint.sh; do
  cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"
done
cp "$DIR/bin/lib/pool-account.sh" "$T/bin/lib/pool-account.sh"
LIB="$T/bin/lib/pool-account.sh"
printf 'claude 4\ncodex 4\n' > "$T/fly/account-capacity.conf"

# ---------- fixtures ---------------------------------------------------------
# A shippable account: a registry file AND a tokens.d setup token, which is what
# a pool lease needs. The priority NUMBER is the first sort key, so the expected
# pick in every case below is the lowest number still standing.
reg() { # reg <name> <priority>
  printf 'ACCOUNT_NAME=%s\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=%s\nACCOUNT_LABEL=%s@fixture.test\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-do-not-ship-%s\n' \
    "$1" "$2" "$1" "$1" > "$T/env/accounts.d/$1.env"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-do-not-ship-%s\n' "$1" > "$T/env/tokens.d/$1-setup-token.env"
  chmod 600 "$T/env/accounts.d/$1.env" "$T/env/tokens.d/$1-setup-token.env"
}
reg pa1 20; reg pa2 30; reg pa3 40

# The file bin/quota-poll.sh actually writes for an unpollable claude account:
# status only, no numbers, source "none", polled_at refreshed every run.
unreadable_quota() { # <account> [age-secs]
  local ts; ts=$(date -u -d "@$(( $(date -u +%s) - ${2:-60} ))" '+%Y-%m-%dT%H:%M:%SZ')
  jq -n --arg a "$1" --arg t "$ts" \
    '{account:$a,vendor:"claude",status:"unreadable",source:"none",polled_at:$t,
      five_hour:null,seven_day:null,per_model:{}}' > "$T/state/quota/$1.json"
}
quota() { # quota <account> <status> <age-secs> <5h> [week]
  local ts; ts=$(date -u -d "@$(( $(date -u +%s) - $3 ))" '+%Y-%m-%dT%H:%M:%SZ')
  jq -n --arg a "$1" --arg s "$2" --arg t "$ts" --argjson five "${4:-null}" --argjson week "${5:-2}" \
    '{account:$a,vendor:"claude",status:$s,source:"oauth-usage",polled_at:$t,
      five_hour:(if $five==null then null else {pct:$five} end),
      seven_day:{pct:$week}, per_model:{}}' > "$T/state/quota/$1.json"
}
all_unreadable() { unreadable_quota pa1; unreadable_quota pa2; unreadable_quota pa3; }
cooling() { mkdir -p "$T/state/quota/cooldown/claude"; date -u +%s > "$T/state/quota/cooldown/claude/$1"; }

mkbundle() {
  rm -f "$T/bundle/auth-accounts.local.json"
  printf 'CONSOLE_URL=https://console.test\nCLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=gh-fixture\nRUNNER_EXECUTE=claude\n' \
    "$TOK_MASTER" > "$T/bundle/global.env"
  chmod 600 "$T/bundle/global.env"
}
reset() {
  rm -f "$T/env/accounts.d/pa4.env" "$T/env/tokens.d/pa4-setup-token.env" "$T/state/quota/pa4.json"
  rm -rf "$T/state/quota/leases" "$T/state/quota/pins" "$T/state/quota/cooldown"
  rm -f "$T/logs/account-routing.log"
  mkbundle; all_unreadable
}

lease() { # lease <extra-env...> -- <project> <key> <bundle> <machine-id>
  local envs=(); while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  env HARNESS="$T" "${envs[@]}" bash -c '. "$0"; pool_account_lease "$@"' "$LIB" "$@" 2>"$T/lease.err"
}
lname()   { sed -n 's/.*\bname=\([^ ]*\).*/\1/p' <<<"$1"; }
lreason() { sed -n 's/.*\breason=\([^ ]*\).*/\1/p' <<<"$1"; }
# `reset` truncates the routing log between rows, so the never-an-all_unreadable
# negative below is asserted over a copy that survives every reset.
keep_log() { cat "$T/logs/account-routing.log" >> "$T/logs/all-reasons.log" 2>/dev/null; }

# =============================================================================
# 1. EVERY QUOTA FILE UNREADABLE -> a lease, not the default token
# =============================================================================
reset
OUT=$(lease -- proj K-1 "$T/bundle/global.env" mun0000000001)
[ "$(lname "$OUT")" = pa1 ] \
  && ok || bad "1: an all-unreadable registry must still rank (picked '$(lname "$OUT")', reason '$(lreason "$OUT")')"
[ "$(lreason "$OUT")" != default_saturated ] \
  && ok || bad "1: the pool called itself saturated while three accounts were usable"
grep -qxF "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-do-not-ship-pa1" "$T/bundle/global.env" \
  && ok || bad "1: the bundle does not carry the leased account's token"
grep -q "$TOK_MASTER" "$T/bundle/global.env" \
  && bad "1: the capped default token survived into the bundle" || ok
[ -f "$T/state/quota/leases/pa1/mun0000000001" ] \
  && ok || bad "1: no lease file was written for the leased account"
# There is deliberately no `all_unreadable` class: `unreadable` is the reading
# that RANKS, so it can never be the reason the pool shipped the default token.
grep -q all_unreadable "$T/logs/account-routing.log" \
  && bad "1: an all_unreadable class was logged for a registry that leased fine" || ok
# the rank is priority-then-name, and an empty meter must not poison the sort:
# pa1 is 20, pa2 is 30, pa3 is 40 — so the answer is the lowest NUMBER.
reset
OUT=$(lease -- proj K-1b "$T/bundle/global.env" mun0000000002)
[ "$(lname "$OUT")" = pa1 ] && ok || bad "1: the pick is not the lowest priority number (got '$(lname "$OUT")')"
[ ! -s "$T/lease.err" ] && ok || bad "1: the library wrote to stderr: $(cat "$T/lease.err")"

# =============================================================================
# 2. A COOLING ACCOUNT IS SKIPPED — even though it would otherwise win
# =============================================================================
reset
reg pa4 5; unreadable_quota pa4
OUT=$(lease -- proj K-2a "$T/bundle/global.env" mcool000000001)
[ "$(lname "$OUT")" = pa4 ] && ok || bad "2: priority 5 should win before the cooldown (got '$(lname "$OUT")')"
reset
reg pa4 5; unreadable_quota pa4
cooling pa4
OUT=$(lease -- proj K-2b "$T/bundle/global.env" mcool000000002)
[ "$(lname "$OUT")" = pa1 ] && ok || bad "2: a cooling account must be skipped (got '$(lname "$OUT")')"

# =============================================================================
# 3. STALE IS STILL FILTERED — a poller that stopped is not a poller that
#    answered "unreadable", and the pool may not guess at numbers it has no
#    fresh evidence for.
# =============================================================================
reset
reg pa4 5; quota pa4 stale 14400 10          # `status: stale`, polled 4h ago
OUT=$(lease -- proj K-3a "$T/bundle/global.env" mstale00000001)
[ "$(lname "$OUT")" = pa1 ] && ok || bad "3: a stale-status account must be skipped (got '$(lname "$OUT")')"
reset
reg pa4 5; quota pa4 ok 14400 10             # an `ok` poll aged past the window
OUT=$(lease -- proj K-3b "$T/bundle/global.env" mstale00000002)
[ "$(lname "$OUT")" = pa1 ] && ok || bad "3: an ok poll older than ACCOUNT_POLL_STALE_SECS must be skipped (got '$(lname "$OUT")')"
reset
reg pa4 5; rm -f "$T/state/quota/pa4.json"   # no meter at all
OUT=$(lease -- proj K-3c "$T/bundle/global.env" mstale00000003)
[ "$(lname "$OUT")" = pa1 ] && ok || bad "3: an account with no quota file must be skipped (got '$(lname "$OUT")')"

# =============================================================================
# 4. ONE CLASSIFIER, TWO PICKERS. The same file, read by account_headroom and by
#    the pool's filter, and the classes they both branch on.
# =============================================================================
verdict() { # <account> -> "<headroom>|<pool>|<class>|<meter>"
  env HARNESS="$T" bash -c '
    . "$0"
    a="$1"; h=excluded; p=excluded; m=""; c=""
    account_headroom "$a" "" && h=usable
    if m=$(_pa_metered "$a" ""); then p=usable; fi
    if command -v account_reading_class >/dev/null 2>&1; then
      c=$(account_reading_class "$a" ""); c="${c%%|*}"
    else c=NO_SHARED_PREDICATE; fi
    printf "%s|%s|%s|%s\n" "$h" "$p" "$c" "$m"
  ' "$LIB" "$1" 2>/dev/null
}
v_head()  { cut -d'|' -f1 <<<"$1"; }
v_pool()  { cut -d'|' -f2 <<<"$1"; }
v_class() { cut -d'|' -f3 <<<"$1"; }
v_meter() { cut -d'|' -f4 <<<"$1"; }

reset
# (a) unreadable — the reading at the heart of this ticket: both pickers use it.
V=$(verdict pa1)
[ "$(v_head "$V")" = "$(v_pool "$V")" ] \
  && ok || bad "4a: the two pickers disagree on an unreadable file: $V"
[ "$(v_pool "$V")" = usable ] && ok || bad "4a: an unreadable reading must not exclude the account: $V"
[ "$(v_class "$V")" = unreadable ] && ok || bad "4a: class was '$(v_class "$V")', expected unreadable"
[ -z "$(v_meter "$V")" ] && ok || bad "4a: an unreadable account must rank with an EMPTY meter, got '$(v_meter "$V")'"

# (e) an AGED unreadable poll is still `unreadable`, not `stale`. quota-poll.sh
#     rewrites the status every run precisely so it does not age, so this shape
#     only appears when the poller STOPPED — and reading it as stale is what put
#     every machine back on the default token on 2026-09-16. The class is the
#     poller's own word, and the age check belongs to `ok` readings only.
unreadable_quota pa1 14400
V=$(verdict pa1)
[ "$(v_class "$V")" = unreadable ] && ok || bad "4e: an aged unreadable poll must stay unreadable, got '$(v_class "$V")'"
[ "$(v_head "$V")" = usable ] && [ "$(v_pool "$V")" = usable ] \
  && ok || bad "4e: an aged unreadable poll must still be usable to both pickers: $V"
[ -z "$(v_meter "$V")" ] && ok || bad "4e: an aged unreadable account must rank with an EMPTY meter, got '$(v_meter "$V")'"

# (b) a fresh ok poll under every threshold — usable to both, and the pool ranks
#     on the number it just read.
quota pa1 ok 60 12
V=$(verdict pa1)
[ "$(v_head "$V")" = usable ] && [ "$(v_pool "$V")" = usable ] \
  && ok || bad "4b: a fresh ok poll must be usable to both pickers: $V"
[ "$(v_class "$V")" = metered ] && ok || bad "4b: class was '$(v_class "$V")', expected metered"
[ "$(v_meter "$V")" = 12 ] && ok || bad "4b: the pool filter lost the 5h pct: $V"

# (c) over ACCOUNT_5H_MAX — excluded by BOTH, which is the agreement that matters
quota pa1 ok 60 97
V=$(verdict pa1)
[ "$(v_head "$V")" = excluded ] && [ "$(v_pool "$V")" = excluded ] \
  && ok || bad "4c: a capped account must be excluded by both pickers: $V"
[ "$(v_class "$V")" = capped ] && ok || bad "4c: class was '$(v_class "$V")', expected capped"

# (d) the DELIBERATE divergence, pinned so it cannot become accidental: a stale
#     or missing reading is fail-open on the hub (refusing every account would
#     take the fleet down) and fail-closed in the pool (the fallback is a token
#     that still works, so a guess costs a build).
quota pa1 ok 14400 12
V=$(verdict pa1)
[ "$(v_head "$V")" = usable ] && [ "$(v_pool "$V")" = excluded ] \
  && ok || bad "4d: stale must be fail-open on the hub and fail-closed in the pool: $V"
[ "$(v_class "$V")" = stale ] && ok || bad "4d: class was '$(v_class "$V")', expected stale"
rm -f "$T/state/quota/pa1.json"
V=$(verdict pa1)
[ "$(v_head "$V")" = usable ] && [ "$(v_pool "$V")" = excluded ] \
  && ok || bad "4d: a missing file must be fail-open on the hub and fail-closed in the pool: $V"
[ "$(v_class "$V")" = none ] && ok || bad "4d: class was '$(v_class "$V")', expected none"

# (f) the poller said `stale` ITSELF, on a poll made a minute ago. The status is
#     the evidence, not the timestamp: it is the same class as an aged `ok`, and
#     the same divergence applies.
quota pa1 stale 60 10
V=$(verdict pa1)
[ "$(v_class "$V")" = stale ] && ok || bad "4f: a poller-written stale status must class as stale, got '$(v_class "$V")'"
[ "$(v_head "$V")" = usable ] && [ "$(v_pool "$V")" = excluded ] \
  && ok || bad "4f: a poller-written stale status must be fail-open on the hub and fail-closed in the pool: $V"

# =============================================================================
# 5. THE FALLBACK NAMES ITS CLASS. `default_saturated` for both an exhausted
#    fleet and a blind one is what made the incident unreadable in the log.
# =============================================================================
# (a) every account over the 5h threshold -> all_capped
reset
quota pa1 ok 60 99; quota pa2 ok 60 99; quota pa3 ok 60 99
OUT=$(lease -- proj K-5a "$T/bundle/global.env" msat0000000001)
[ "$(lname "$OUT")" = default ] && ok || bad "5a: no headroom must answer default (got '$(lname "$OUT")')"
[ "$(lreason "$OUT")" = all_capped ] && ok || bad "5a: reason was '$(lreason "$OUT")', expected all_capped"
grep -q ',default,all_capped$' "$T/logs/account-routing.log" \
  && ok || bad "5a: the capped fallback class was not logged: $(cat "$T/logs/account-routing.log" 2>/dev/null)"
keep_log

# (b) every meter aged past the window -> all_stale
reset
quota pa1 ok 14400 10; quota pa2 ok 14400 10; quota pa3 ok 14400 10
OUT=$(lease -- proj K-5b "$T/bundle/global.env" msat0000000002)
# stale/missing, NOT `unreadable` — which now ranks, so it can never land here.
[ "$(lreason "$OUT")" = all_stale ] \
  && ok || bad "5b: a fleet whose meters have all gone stale must say so, got '$(lreason "$OUT")'"
grep -q ',default,all_stale$' "$T/logs/account-routing.log" \
  && ok || bad "5b: the stale fallback class was not logged: $(cat "$T/logs/account-routing.log" 2>/dev/null)"
grep -q "$TOK_MASTER" "$T/bundle/global.env" \
  && ok || bad "5b: a saturated pick must ship the bundle it arrived with"
keep_log

# (c) every account inside its cooldown -> all_cooling. A quota problem and a
#     "they all just refused us" problem are not the same operator response.
reset
cooling pa1; cooling pa2; cooling pa3
OUT=$(lease -- proj K-5c "$T/bundle/global.env" msat0000000003)
[ "$(lname "$OUT")" = default ] && ok || bad "5c: all cooling must answer default (got '$(lname "$OUT")')"
[ "$(lreason "$OUT")" = all_cooling ] && ok || bad "5c: reason was '$(lreason "$OUT")', expected all_cooling"
grep -q ',default,all_cooling$' "$T/logs/account-routing.log" \
  && ok || bad "5c: the cooling fallback class was not logged: $(cat "$T/logs/account-routing.log" 2>/dev/null)"
keep_log

# (d) every account at its lease cap -> all_leased. Three accounts, a cap of one
#     each, three machines holding them, and a fourth machine asking.
reset
lease ACCOUNT_POOL_MAX_LEASES=1 -- proj K-5d1 "$T/bundle/global.env" mcap0000000001 >/dev/null
lease ACCOUNT_POOL_MAX_LEASES=1 -- proj K-5d2 "$T/bundle/global.env" mcap0000000002 >/dev/null
lease ACCOUNT_POOL_MAX_LEASES=1 -- proj K-5d3 "$T/bundle/global.env" mcap0000000003 >/dev/null
OUT=$(lease ACCOUNT_POOL_MAX_LEASES=1 -- proj K-5d4 "$T/bundle/global.env" mcap0000000004)
[ "$(lname "$OUT")" = default ] && ok || bad "5d: a fully leased pool must answer default (got '$(lname "$OUT")')"
[ "$(lreason "$OUT")" = all_leased ] && ok || bad "5d: reason was '$(lreason "$OUT")', expected all_leased"
grep -q ',default,all_leased$' "$T/logs/account-routing.log" \
  && ok || bad "5d: the lease-cap fallback class was not logged: $(cat "$T/logs/account-routing.log" 2>/dev/null)"
keep_log

# (e) a MIXED set is not named after its majority — one capped, one stale, one
#     cooling is three different problems, and `default_saturated` is the honest
#     answer for "it is not one thing".
reset
quota pa1 ok 60 99          # capped
quota pa2 ok 14400 10       # stale
cooling pa3                 # cooling
OUT=$(lease -- proj K-5e "$T/bundle/global.env" msat0000000005)
[ "$(lname "$OUT")" = default ] && ok || bad "5e: a mixed set must still answer default (got '$(lname "$OUT")')"
[ "$(lreason "$OUT")" = default_saturated ] \
  && ok || bad "5e: a mixed refusal set must stay default_saturated, got '$(lreason "$OUT")'"
grep -q ',default,default_saturated$' "$T/logs/account-routing.log" \
  && ok || bad "5e: the mixed fallback was not logged: $(cat "$T/logs/account-routing.log" 2>/dev/null)"
keep_log

# ...and across every fallback above, no class named `unreadable`: it RANKS now,
# so a reason naming it would send the next operator to the wrong file.
[ "$(grep -c all_unreadable "$T/logs/all-reasons.log")" -eq 0 ] \
  && ok || bad "5: an all_unreadable class was logged: $(grep all_unreadable "$T/logs/all-reasons.log")"

# ...and the class is what an operator actually reads: bin/fly-pool.sh puts the
# reason straight into its fallback line, so the rename above IS the log line.
# BH-10141: the line names the token's fp and source, not "project-6".
grep -F "ships the owning box's default claude token" "$DIR/bin/fly-pool.sh" | grep -qF '(${PAREASON:-no answer})' \
  && ok || bad "5: fly-pool.sh no longer prints the pool picker's reason in its fallback line"

echo "pool-account: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
