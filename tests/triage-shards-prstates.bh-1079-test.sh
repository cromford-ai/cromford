#!/bin/bash
# tests/triage-shards-prstates.bh-1079-test.sh — BH-1079: the two spend defects
# the round-2 review of BH-1015 found, plus the four nits around them.
#
# WHAT WENT WRONG, both of them in the lane that was supposed to STOP spending:
#
#   A — A SKIP-ONLY TICK NEVER CONSUMED THE BOARD FINGERPRINT.
#   bin/lib/rt/shards.sh absorbed state/<p>.gate.pending into state/<p>.gate.json
#   only when it had actually DISPATCHED something (`[ "$SHARD_N" -gt 0 ]`). A key
#   that the held path had re-armed out of gate.json therefore stayed out of it for
#   ever: every following tick re-fetched the board, bin/gate-diff.sh reported it
#   `NEW <id>` again, the per-ticket fingerprint correctly said "unchanged, no
#   session", and the tick paid for the board round-trip again — until the 4h
#   fingerprint TTL expired and bought one spurious session. The gate could never
#   answer `SKIP no-change`, because the file it compares against was missing the
#   very ticket the board keeps reporting.
#
#   B — AN OLDER PR STATE OVERWROTE A NEWER ONE.
#   triage_prstates_ingest folds line 3 of state/<p>.queuefp (the gate's own
#   45-minute PR lookup) into the ledger, and it stamped every pair with `now`
#   while _tsh_prstates_put overwrote unconditionally. queuefp line 3 SURVIVES
#   ticks the gate did not re-read on, so a vector written ten minutes ago was
#   re-ingested as if it had just been read — and a `12=OPEN` from then replaced a
#   `12 MERGED` the REST refresh had just established. Every key naming PR #12 then
#   flipped its fingerprint and bought a session, on a merge that had already
#   happened.
#
# The four nits are the same lane's economics: MERGED/CLOSED are terminal and must
# never be re-bought, a failed REST lookup must not be silent, both PR lookups
# (the ledger's and the gate's own) must consult bin/lib/gh-budget.sh before they
# spend, and the ledger must be pruned so it cannot grow for ever.
#
# WHAT IS AT STAKE IN EACH CASE. "0 calls" alone would pass a lane that had simply
# stopped working, so every skip case is paired with one that MUST still act: a
# thread that really moved (A3), a gate vector that really is newer (B2), an OPEN
# entry aged past the TTL (C2), a healthy budget (E2/F2), a named old entry (G1).
#
# Parts A, B3, F and G2 drive the REAL bin/run-triage.sh / bin/triage-gate.sh /
# bin/gate-diff.sh against a scratch $HARNESS; only the harness and repo ROOTS are
# rewritten (the precedent tests/triage-shards-ticket-fp-test.sh set). The stub
# agent-call writes a cost row, so "no session was bought" is asserted on
# logs/cost.csv and not only on a log line; the stub `gh` records every call, so
# "no lookup happened" is an assertion on fixture/gh-calls.
#
# Run from anywhere: tests/triage-shards-prstates.bh-1079-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read for the whole file: every fixture age below is derived from it,
# so this suite cannot pick its own red day (bin/test-determinism-lint.sh).
NOW=$(date +%s)
DAY=86400

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/catalog" "$H/fixture" "$T/calls" "$T/repos"
: > "$H/env/global.env"
P=project-5
K=563
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"
# Every budget case re-reads its fixture instead of a 60s-old cached answer.
export GH_BUDGET_TTL_S=0
# BH-10453: a could-not-read PR read (the RATELIMIT and gh-fail arms) now
# retries and records a box failure. This suite counts ONE lookup per PR and
# pins the carried-forward value, so the retry budget is 0 and the record is
# off here. The retry and the record are pinned in
# tests/triage-could-not-read.bh-9555-test.sh.
export CNR_RETRY_BUDGET_S=0 CNR_ENFORCE=0

for s in run-triage.sh triage-shard.sh triage-gate.sh gate-diff.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$H/bin/real-$s"
  chmod +x "$H/bin/real-$s"
done
cp "$H/bin/real-run-triage.sh"   "$H/bin/run-triage.sh"
cp "$H/bin/real-triage-shard.sh" "$H/bin/triage-shard.sh"
cp "$H/bin/real-gate-diff.sh"    "$H/bin/gate-diff.sh"
chmod +x "$H/bin/run-triage.sh" "$H/bin/triage-shard.sh" "$H/bin/gate-diff.sh"
mkdir -p "$H/bin/lib/rt"
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
# The shared gh libraries the PR-state refresh (and the gate's own lookup) go
# through, real and unmodified: gh-rest.sh is the REST reader, gh-app-auth.sh
# is what arms the App identity. The scratch box has no env/github-app.env and
# no bin/gh-token.sh, so gh_auth_armed says no and the pass runs on the
# ambient identity, same as an un-onboarded box.
# BH-1485: gh-rest-var.sh rides with gh-rest.sh — gh-rest.sh sources it by path
# from beside itself, and the refresh below calls gh_rest_pr_state_var.
for s in gh-rest.sh gh-rest-var.sh gh-app-auth.sh; do
  sed -e "s|/root/harness|$H|g" "$DIR/bin/lib/$s" > "$H/bin/lib/$s"
done
cp "$DIR/bin/lib/gh-budget.sh"         "$H/bin/lib/gh-budget.sh"
cp "$DIR/bin/lib/gh-pr-list.sh"        "$H/bin/lib/gh-pr-list.sh" 2>/dev/null || true
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs -------------------------------------------------------------------
# The gate stub for the cases that need a fixed decision (B3, G2). Parts A and F
# swap the REAL gate in with use_gate real.
cat > "$H/bin/stub-triage-gate.sh" <<STUB
#!/bin/bash
P="\$1"; MODE="\${2:-}"
cp "$H/fixture/pending.json" "$H/state/\$P.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
[ "\$MODE" = "--buildable" ] && { echo OK; exit 0; }
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/stub-triage-gate.sh"
use_gate() { # use_gate real|stub
  case "$1" in
    real) cp "$H/bin/real-triage-gate.sh" "$H/bin/triage-gate.sh" ;;
    stub) cp "$H/bin/stub-triage-gate.sh" "$H/bin/triage-gate.sh" ;;
  esac
  chmod +x "$H/bin/triage-gate.sh"
}
printf '#!/bin/sh\nexit 0\n' > "$H/bin/unblocked-children.sh"; chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# `gh`: every invocation is recorded, so "no lookup happened" is an assertion.
# Every read this lane makes goes through bin/lib/gh-rest.sh — never a raw
# `gh issue list` / `gh pr list` / `gh pr view` / `gh api --jq` call (BH-1015
# review round 2, and the same rule bin/triage-gate.sh's board fetch itself
# now obeys) — so every case below answers `gh api -i -X GET ...`, headers
# included: gh_rest reads the status line to tell 404 from "come back later".
#   */issues*                -> the board fetch (fetch_fingerprint): fixture/issues.json
#   */pulls* (no /N)         -> the board's open-PR list (fetch_fingerprint): always empty
#   */pulls/N                -> BOTH the gate's own 45-minute lookup and the
#                                ledger's REST refresh, both through
#                                gh_rest_pr_state. fixture/gh-fail forces a
#                                status-line-less response, which gh_rest reads
#                                as rc 75.
#   api rate_limit            -> fixture/rate_limit.json, verbatim (may be non-JSON)
#   auth token                -> rc 1, so the budget cache keys on `notoken`
cat > "$H/bin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$H/fixture/gh-calls"
case "\$*" in
  *rate_limit*) cat "$H/fixture/rate_limit.json"; exit 0 ;;
esac
case "\$1 \$2" in
  "auth token") exit 1 ;;
esac
case "\$*" in
  *pulls/[0-9]*)
    [ -f "$H/fixture/gh-fail" ] && exit 1
    case "\$*" in
      *pulls/13*) ST=\$(cat "$H/fixture/pr13-state" 2>/dev/null || echo OPEN) ;;
      *)          ST=\$(cat "$H/fixture/pr12-state" 2>/dev/null || echo OPEN) ;;
    esac
    case "\$ST" in
      RATELIMIT) printf 'HTTP/2 403\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1 ;;
      GONE)      printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
      MERGED)    printf 'HTTP/2 200\r\n\r\n{"state":"closed","merged_at":"2026-09-19T05:00:00Z"}\n'; exit 0 ;;
      CLOSED)    printf 'HTTP/2 200\r\n\r\n{"state":"closed","merged_at":null}\n'; exit 0 ;;
      *)         printf 'HTTP/2 200\r\n\r\n{"state":"open","merged_at":null}\n'; exit 0 ;;
    esac ;;
  */issues*)
    printf 'HTTP/2 200\r\n\r\n%s\n' "\$(cat "$H/fixture/issues.json" 2>/dev/null || echo '[]')"
    exit 0 ;;
  */pulls*)
    printf 'HTTP/2 200\r\n\r\n[]\n'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$H/bin/gh"

# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$D/calls.tsv"
printf '2026-09-19T00:00:00Z,box,%s,%s,claude,%s,,,,,,,0.9100\n' "$2" "$1" "$3" >> "$COSTCSV"
echo "tickets=1 done" > "$5"
exit "${STUB_RC:-0}"
STUB
chmod +x "$H/bin/agent-call.sh"

# --- fixtures ----------------------------------------------------------------
# RAW REST shape (bin/triage-gate.sh's fetch_fingerprint now reads
# `repos/<repo>/issues` through gh_rest, never `gh issue list`): lowercase
# `state`, snake_case `updated_at`, and `pull_request: null` so the "REST
# /issues returns PRs too" filter (`select(.pull_request == null)`) passes it.
issues_json() { printf '[{"number":%s,"state":"open","title":"c","comments":%s,"updated_at":"2026-09-19T05:00:00Z","pull_request":null}]' "$K" "${1:-0}"; }
# mkfp <comments> -> the bytes the REAL gate writes for that board: issues_json
# run through fetch_fingerprint's own jq transform (state upper-cased,
# updated_at -> updatedAt), so a seeded state/<p>.gate.json is comparable to a
# freshly fetched fingerprint. prs is always empty: the fixture PR list below
# answers `[]` to the gate's own open-PR REST list. Since BH-2133 the gate also
# writes a top-level `meta` map, {issue: first 16 hex of sha256 over [body,
# sorted labels, sorted assignees, [milestone number, title]]}; it is computed
# here the same way, so the bytes still match the real gate's.
mkfp() {
  local m
  m=$(issues_json "${1:-0}" | python3 -c '
import hashlib, json, sys
out = {}
for i in json.load(sys.stdin):
    m = i.get("milestone") or {}
    t = json.dumps([i.get("body") or "", sorted(l.get("name", "") for l in (i.get("labels") or [])),
                    sorted(a.get("login", "") for a in (i.get("assignees") or [])), [m.get("number"), m.get("title")]],
                   sort_keys=True, separators=(",", ":"))
    out[str(i.get("number"))] = hashlib.sha256(t.encode()).hexdigest()[:16]
print(json.dumps(out))')
  jq -cS -n '{issues: (input | map({number, state: (.state|ascii_upcase), title, comments, updatedAt: .updated_at})), prs: [], meta: input}' \
    <<<"$(issues_json "${1:-0}")"$'\n'"$m"
}
ratelimit() { # ratelimit <core-remaining>
  printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":%s},"graphql":{"remaining":%s,"limit":5000,"reset":%s}}}\n' \
    "$1" "$(( NOW + 3600 ))" "$1" "$(( NOW + 3600 ))" > "$H/fixture/rate_limit.json"
  rm -f "$H/state/gh-budget"/logged-* "$H/state/gh-budget"/*.json 2>/dev/null || true
}

held() { [ -e "$1" ] || return 1; if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi; return 0; }
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
ncost()  { grep -c ',triage,' "$H/logs/cost.csv" 2>/dev/null | tr -d ' ' || true; }
ngh()    { grep -c . "$H/fixture/gh-calls" 2>/dev/null | tr -d ' ' || true; }
npulls() { grep -c 'pulls/' "$H/fixture/gh-calls" 2>/dev/null | tr -d ' ' || true; }
nlog()   { grep -c "$1" "$H/logs/$P.log" 2>/dev/null | tr -d ' ' || true; }
led()    { cat "$H/state/$P.prstates" 2>/dev/null; }
gatehas() { python3 -c "
import json,sys
fp=json.load(open('$H/state/$P.gate.json'))
sys.exit(0 if $K in [i['number'] for i in fp['issues']] else 1)" 2>/dev/null; }

QL1="TK-$K tid-$K — ready to build, waiting on PR #12 to merge; Re-checked 2026-09-19T05:00:00Z project=project-5"
QL2="TK-$K tid-$K — still waiting on PR #12; nothing to do this tick. Re-checked 2026-09-19T05:40:00Z project=project-5"

reset() { # reset — a fresh box: no stamps, no ledger, a healthy budget
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  model_routes_fixture "$H" project-5 || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/flags/triage-shards-off" "$H/fixture/gh-fail"
  : > "$H/logs/READY-QUEUE.log"
  : > "$H/logs/cost.csv"
  : > "$H/fixture/gh-calls"
  echo OPEN > "$H/fixture/pr12-state"
  echo OPEN > "$H/fixture/pr13-state"
  issues_json 0 > "$H/fixture/issues.json"
  mkfp 0 > "$H/state/$P.gate.json"
  mkfp 0 > "$H/fixture/pending.json"
  echo "RUN queue-pending" > "$H/fixture/gate-decision"
  printf '%s' "" > "$H/fixture/diff"
  date +%s > "$H/state/$P.gate-meta"     # never the daily-sweep arm
  ratelimit 4000
}
nextick() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$H/logs/cost.csv"; : > "$H/fixture/gh-calls"; }
run() { CALLDIR="$T/calls" COSTCSV="$H/logs/cost.csv" PATH="$H/bin:$PATH" "$@" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
settle() { # wait for the detached shards to land, then one grace second
  local i=0 busy
  while [ "$i" -lt 80 ]; do
    if [ "$(ncalls)" -ge "${1:-0}" ]; then
      busy=0
      for L in "$H"/locks/triage-key-*.lock; do held "$L" && busy=1; done
      [ "$busy" = 0 ] && { sleep 1; return 0; }
    fi
    i=$((i+1)); sleep 0.25
  done
  sleep 1; return 1
}
# lib <fn> [args...] — one lib call with the scratch PATH, exactly as the
# dispatcher makes it.
lib() { ( PATH="$H/bin:$PATH"; export PATH; . "$H/bin/lib/triage-shards-lib.sh"; "$@" ) }

# ═══ PART A — a skip-only tick must CONSUME the board fingerprint ═══════════
# Real bin/run-triage.sh, real bin/triage-gate.sh, real bin/gate-diff.sh, empty
# queue. The board is the only input that moves.

use_gate real
reset
issues_json 1 > "$H/fixture/issues.json"      # a client replied: 0 -> 1 comments

# ---------- (A1) precondition: the moved board dispatches and is consumed -----
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(A1) a board that moved must dispatch exactly one shard (got $(ncalls))"
[ "$(ncost)" = 1 ] && ok || bad "(A1) the dispatched shard must leave one stage=triage cost row (got $(ncost))"
[ -s "$H/state/triage-shards/$P/$K.fp" ] && ok \
  || bad "(A1) the dispatcher must persist the per-ticket fingerprint before it spends"
[ "$(cat "$H/state/$P.gate.json")" = "$(mkfp 1)" ] && ok \
  || bad "(A1) a dispatching tick must absorb gate.pending into gate.json (got $(cat "$H/state/$P.gate.json"))"

# ---------- (A2) THE DEFECT: the held path re-arms, then nothing consumes -----
lib triage_shard_rearm "$H" "$P" "$K" 1
gatehas && bad "(A2) precondition: triage_shard_rearm must take $K back OUT of gate.json" || ok

nextick
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(A2) the re-armed key has not moved, so tick 1 must buy nothing (got $(ncalls))"
[ "$(nlog 'unchanged since the last shard')" = 1 ] && ok \
  || bad "(A2) tick 1 must log the per-ticket skip once (got $(nlog 'unchanged since the last shard'))"
gatehas && ok \
  || bad "(A2) THE DEFECT: a tick that skipped every key must still consume gate.pending — $K is missing from gate.json, so the board is re-fetched and re-diffed for ever and one spurious session is bought at the TTL"

SKIPS0=$(nlog 'gate no-change')
for i in 2 3 4; do
  nextick
  run
  settle 0 >/dev/null
  [ "$(ncalls)" = 0 ] || bad "(A2) tick $i over an unchanged world must buy nothing (got $(ncalls))"
  [ "$(ncost)" = 0 ] || bad "(A2) tick $i must write no cost row (got $(ncost))"
done
[ "$(( $(nlog 'gate no-change') - SKIPS0 ))" = 3 ] && ok \
  || bad "(A2) ticks 2-4 must each stop at the gate with 'SKIP no-change' (got $(( $(nlog 'gate no-change') - SKIPS0 )) of 3) — that is the whole saving the consume buys"
[ "$(nlog 'unchanged since the last shard')" = 1 ] && ok \
  || bad "(A2) ticks 2-4 must not even reach the per-ticket fingerprint (skip lines: $(nlog 'unchanged since the last shard'))"

# ---------- (A3) negative: a real thread move still dispatches ---------------
nextick
issues_json 2 > "$H/fixture/issues.json"      # the client replied again
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok \
  || bad "(A3) a consumed fingerprint must NOT hide a client reply — the moved thread must dispatch (got $(ncalls))"
F=$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1)
grep -q "Work ONLY ticket $K this tick" "${F:-/dev/null}" && ok \
  || bad "(A3) the dispatched shard must be scoped to $K"

# ═══ PART B — ingest carries the gate vector's OWN age ══════════════════════

seed_led() { printf '%s\n' "$@" > "$H/state/$P.prstates"; }
seed_qfp() { printf '%s\n' "$@" > "$H/state/$P.queuefp"; }

# ---------- (B1) an OLDER gate vector must not overwrite a NEWER ledger ------
reset
seed_led "$(printf '12\tMERGED\t%s' "$NOW")"
seed_qfp hash "$(( NOW - 600 ))" '12=OPEN;'
lib triage_prstates_ingest "$H" "$P"
[ "$(lib triage_prstates_get "$H" "$P" 12)" = MERGED ] && ok \
  || bad "(B1) THE DEFECT: queuefp line 3 survives ticks the gate did not re-read on, so a 10-minute-old '12=OPEN' must never replace a MERGED the REST refresh just wrote (got $(lib triage_prstates_get "$H" "$P" 12), ledger: $(led))"
[ "$(led)" = "$(printf '12\tMERGED\t%s' "$NOW")" ] && ok \
  || bad "(B1) the stamp must be left alone too (got $(led))"

# ---------- (B2) negative: a NEWER gate vector must still win ----------------
reset
seed_led "$(printf '12\tOPEN\t%s' "$(( NOW - 4000 ))")"
seed_qfp hash "$(( NOW - 100 ))" '12=MERGED;'
lib triage_prstates_ingest "$H" "$P"
[ "$(lib triage_prstates_get "$H" "$P" 12)" = MERGED ] && ok \
  || bad "(B2) the fix must not become 'ingest never writes' — a gate vector newer than the entry must win (ledger: $(led))"
[ "$(led)" = "$(printf '12\tMERGED\t%s' "$(( NOW - 100 ))")" ] && ok \
  || bad "(B2) an ingested value carries the GATE's epoch, not now (got $(led))"

# ---------- (B3) the same defect through the real tick -----------------------
use_gate stub
reset
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
seed_led "$(printf '12\tMERGED\t%s' "$NOW")"
seed_qfp hash "$NOW"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(B3) precondition: the first queue tick must dispatch (got $(ncalls))"
LED3=$(led)
nextick
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
seed_qfp hash "$(( NOW - 600 ))" '12=OPEN;'
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok \
  || bad "(B3) a stale gate vector flipping MERGED back to OPEN must not buy a session for every key naming PR #12 (got $(ncalls))"
[ "$(ncost)" = 0 ] && ok || bad "(B3) the quiet tick must write no cost row (got $(ncost))"
[ "$(led)" = "$LED3" ] && ok \
  || bad "(B3) the ledger must be byte-identical after the stale ingest (was '$LED3', now '$(led)')"

# ---------- (B4) a vector with no usable age ingests nothing -----------------
reset
seed_led "$(printf '12\tMERGED\t%s' "$NOW")"
seed_qfp hash garbage '12=OPEN;'
LED4=$(led)
lib triage_prstates_ingest "$H" "$P"
[ "$(led)" = "$LED4" ] && ok \
  || bad "(B4) a queuefp whose line 2 is not an epoch cannot claim to be newer — ingest must write nothing (got $(led))"

# ---------- (B5) a SAME-SECOND vector is not an older one --------------------
# The tie comes from TWO GATE READS landing in the same second — 45 minutes
# apart on a box, back to back here — not from the refresh, which runs after the
# ingest and skips rows younger than the TTL. Reading equal seconds as "not
# newer" would hold a merge for the gate's whole 45-minute window, which is the
# very flip this ledger exists to catch.
reset
seed_led "$(printf '12\tOPEN\t%s' "$NOW")"
seed_qfp hash "$NOW" '12=MERGED;'
lib triage_prstates_ingest "$H" "$P"
[ "$(lib triage_prstates_get "$H" "$P" 12)" = MERGED ] && ok \
  || bad "(B5) a vector stamped the SAME second as the entry is not an older one — the merge must land (ledger: $(led))"

# ═══ PART C — MERGED and CLOSED are terminal ════════════════════════════════
units() { printf '%s\t%s\t%s\n' "$@" > "$H/fixture/units"; }

# ---------- (C1) a terminal entry is never re-bought -------------------------
reset
seed_led "$(printf '12\tMERGED\t%s' "$(( NOW - 4000 ))")" "$(printf '13\tCLOSED\t%s' "$(( NOW - 4000 ))")"
LED5=$(led)
printf '%s\tqueue\t%s\n' "$K" "TK-$K — waiting on PR #12 and PR #13" > "$H/fixture/units"
lib triage_prstates_refresh "$H" "$P" "$H/fixture/units"
[ "$(npulls)" = 0 ] && ok \
  || bad "(C1) a MERGED or CLOSED PR cannot change back on its own — refreshing it once per TTL is pure spend (pulls calls: $(npulls))"
[ "$(led)" = "$LED5" ] && ok || bad "(C1) the terminal entries must be left byte-identical (got $(led))"

# ---------- (C2) negative: an OPEN entry past the TTL is still refreshed -----
nextick
seed_led "$(printf '12\tOPEN\t%s' "$(( NOW - 4000 ))")"
printf '%s\tqueue\t%s\n' "$K" "TK-$K — waiting on PR #12" > "$H/fixture/units"
echo MERGED > "$H/fixture/pr12-state"
lib triage_prstates_refresh "$H" "$P" "$H/fixture/units"
[ "$(npulls)" = 1 ] && ok \
  || bad "(C2) terminal must not become 'never refresh' — an OPEN entry past the TTL needs exactly one lookup (got $(npulls))"
[ "$(lib triage_prstates_get "$H" "$P" 12)" = MERGED ] && ok \
  || bad "(C2) the refreshed value must reach the ledger (got $(led))"
TS2=$(awk -F'\t' '$1==12{print $3}' "$H/state/$P.prstates" 2>/dev/null)
case "$TS2" in ''|*[!0-9]*) TS2=0 ;; esac
[ "$TS2" -ge "$NOW" ] && ok || bad "(C2) a REST refresh restamps with now (got $TS2, expected >= $NOW)"

# ═══ PART D — a failed lookup is logged, and changes nothing ════════════════
reset
seed_led "$(printf '12\tOPEN\t%s' "$(( NOW - 4000 ))")"
LED6=$(led)
printf '%s\tqueue\t%s\n' "$K" "TK-$K — waiting on PR #12" > "$H/fixture/units"
: > "$H/fixture/gh-fail"
lib triage_prstates_refresh "$H" "$P" "$H/fixture/units"
grep -q "prstates refresh: PR #12 lookup failed" "$H/logs/$P.log" && ok \
  || bad "(D1) a failed REST lookup must say so in one line — silence is indistinguishable from a fresh read (log: $(cat "$H/logs/$P.log" 2>/dev/null))"
[ "$(led)" = "$LED6" ] && ok \
  || bad "(D1) a failed lookup keeps the previous value AND its stamp (got $(led))"
rm -f "$H/fixture/gh-fail"

# ═══ PART E — the refresh consults the shared GitHub budget ═════════════════

# ---------- (E1) a low budget spends nothing --------------------------------
reset
ratelimit 10
seed_led "$(printf '12\tOPEN\t%s' "$(( NOW - 4000 ))")"
LED7=$(led)
printf '%s\tqueue\t%s\n' "$K" "TK-$K — waiting on PR #12" > "$H/fixture/units"
lib triage_prstates_refresh "$H" "$P" "$H/fixture/units"
[ "$(npulls)" = 0 ] && ok \
  || bad "(E1) under an exhausted budget the refresh must carry values forward, not spend up to 20 calls per project per tick (pulls calls: $(npulls))"
[ "$(led)" = "$LED7" ] && ok || bad "(E1) a skipped refresh writes nothing (got $(led))"
grep -q 'budget low' "$H/logs/triage-prstates.log" 2>/dev/null && ok \
  || bad "(E1) the budget library must record the lane's skip in logs/triage-prstates.log"

# ---------- (E2) negative: a healthy budget still looks up -------------------
nextick
ratelimit 4000
seed_led "$(printf '12\tOPEN\t%s' "$(( NOW - 4000 ))")"
lib triage_prstates_refresh "$H" "$P" "$H/fixture/units"
[ "$(npulls)" = 1 ] && ok \
  || bad "(E2) a healthy budget must not stop the refresh (pulls calls: $(npulls))"

# ---------- (E3) an UNKNOWN budget proceeds, like every other consumer -------
nextick
seed_led "$(printf '12\tOPEN\t%s' "$(( NOW - 4000 ))")"
printf 'not json at all\n' > "$H/fixture/rate_limit.json"
rm -f "$H/state/gh-budget"/logged-* "$H/state/gh-budget"/*.json 2>/dev/null || true
lib triage_prstates_refresh "$H" "$P" "$H/fixture/units"
[ "$(npulls)" = 1 ] && ok \
  || bad "(E3) a broken rate_limit endpoint must not freeze the ledger — unknown proceeds (pulls calls: $(npulls))"

# ---------- (E4) a quiet tick stays free ------------------------------------
nextick
ratelimit 4000
seed_led "$(printf '12\tOPEN\t%s' "$NOW")"
lib triage_prstates_refresh "$H" "$P" "$H/fixture/units"
[ "$(ngh)" = 0 ] && ok \
  || bad "(E4) no number needs a lookup, so the budget must not be read either — a fresh ledger tick costs 0 gh calls (got $(ngh): $(cat "$H/fixture/gh-calls"))"

# ═══ PART F — the gate's OWN 45-minute PR lookup consults it too ════════════
use_gate real
gaterun() { HARNESS="$H" PATH="$H/bin:$PATH" "$H/bin/triage-gate.sh" "$P" 2>/dev/null; }
qfplines() { grep -c . "$H/state/$P.queuefp" 2>/dev/null | tr -d ' ' || true; }
backdate() { # backdate <seconds> — age the gate's stamp without touching the hash
  local f="$H/state/$P.queuefp" h s v
  [ -s "$f" ] || return 0
  h=$(sed -n 1p "$f"); s=$(sed -n 2p "$f"); v=$(sed -n 3p "$f")
  printf '%s\n%s\n' "$h" "$(( s - $1 ))" > "$f"
  [ -n "$v" ] && printf '%s\n' "$v" >> "$f"
  return 0
}

# ---------- (F1) a low budget: RUN with no lookups at all -------------------
reset
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
gaterun >/dev/null                       # first write: 2 lines
backdate 3000                            # past the gate's own 45-minute window
nextick
ratelimit 10
FOUT=$(gaterun)
[ "$FOUT" = "RUN queue-pending" ] && ok \
  || bad "(F1) under a low budget the gate must fail open to the branch it already takes on ERR (got '$FOUT')"
[ "$(grep -c 'pulls/' "$H/fixture/gh-calls" 2>/dev/null | tr -d ' ')" = 0 ] && ok \
  || bad "(F1) the gate's own lookup is up to 20 calls per project per tick and must not run under an exhausted budget (calls: $(cat "$H/fixture/gh-calls"))"
[ "$(qfplines)" = 2 ] && ok \
  || bad "(F1) with no vector the gate writes 2 lines, exactly as it does on ERR (got $(qfplines))"

# ---------- (F2) negative: a healthy budget still looks up ------------------
backdate 3000
nextick
ratelimit 4000
FOUT2=$(gaterun)
grep -q 'pulls/12' "$H/fixture/gh-calls" && ok \
  || bad "(F2) a healthy budget must leave the gate's PR lookup alone (gate said '$FOUT2', calls: $(cat "$H/fixture/gh-calls"))"
[ "$(qfplines)" = 3 ] && grep -q '12=OPEN' "$H/state/$P.queuefp" && ok \
  || bad "(F2) the healthy lookup must still be parked on queuefp line 3 (got $(qfplines) lines: $(cat "$H/state/$P.queuefp"))"

# ═══ PART G — the ledger is pruned ══════════════════════════════════════════

# ---------- (G1) unnamed AND old goes; named or young stays -----------------
reset
seed_led "$(printf '99\tMERGED\t%s' "$(( NOW - 8*DAY ))")" \
         "$(printf '12\tOPEN\t%s'   "$(( NOW - 8*DAY ))")" \
         "$(printf '98\tOPEN\t%s'   "$(( NOW - DAY ))")"
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
lib triage_prstates_prune "$H" "$P"
grep -q '^99	' "$H/state/$P.prstates" && bad "(G1) an 8-day-old entry no queue line names must be pruned (ledger: $(led))" || ok
grep -q '^12	' "$H/state/$P.prstates" && ok \
  || bad "(G1) an entry a queue line still names must survive whatever its age (ledger: $(led))"
grep -q '^98	' "$H/state/$P.prstates" && ok \
  || bad "(G1) an entry younger than the cutoff must survive even unnamed (ledger: $(led))"

# ---------- (G2) and it runs from the real tick ------------------------------
use_gate stub
reset
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
seed_led "$(printf '99\tMERGED\t%s' "$(( NOW - 8*DAY ))")" \
         "$(printf '12\tOPEN\t%s'   "$NOW")"
run
settle 1 >/dev/null
grep -q '^99	' "$H/state/$P.prstates" && bad "(G2) the prune must run once per tick from the dispatcher (ledger: $(led))" || ok
grep -q '^12	' "$H/state/$P.prstates" && ok || bad "(G2) the live entry must survive the tick's prune (ledger: $(led))"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
