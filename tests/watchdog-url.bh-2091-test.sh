#!/bin/bash
# tests/watchdog-url.bh-2091-test.sh — the repo-managed WATCHDOG_URL seed
# (BH-3320, part 1 of BH-2091).
#
# WHY. Nine scripts read ${WATCHDOG_URL:-<fleet host>}. The later BH-2091
# children drop that literal default, and on that day every box that never had
# WATCHDOG_URL in env/global.env stops pinging the watchdog. This child lands
# first and makes sure the line is already there: bin/harness-sync.sh appends
# catalog/fleet-watchdog.json's value into global.env, but ONLY on a checkout
# whose origin is example-org/cromford (a fork must not send its shared
# secret to our worker).
#
# §1 watchdog_url (unset = rc 1, one log line per lane per UTC day, no network)
# §1b the seed keeps its caller's fd 8 (harness-sync holds its own lock there)
# §2 watchdog_url_carry: the origin guard, positives and adversarial negatives
# §3 the registered lib knob and the catalog file
# §6 bin/harness-sync.sh run WHOLE against a scratch origin/checkout/HARNESS
#
# Fixtures use http://watchdog.invalid; the fleet host is only ever assembled
# from pieces here. Run from anywhere (0 = pass).
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null && command -v flock >/dev/null \
  && command -v rsync >/dev/null || { echo "jq/git/flock/rsync missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/watchdog-url.sh"
CAT="$DIR/catalog/fleet-watchdog.json"
FLEET_HOST='harness-watchdog.'"operator"'.workers'"."'dev'
DAY=$(date -u +%F)
# shellcheck disable=SC1090
. "$LIB" || bad "bin/lib/watchdog-url.sh could not be sourced"

# ── §1 watchdog_url ──────────────────────────────────────────────────────────
R1="$T/r1"; mkdir -p "$R1" "$T/fakebin"
CALLS="$T/net-calls.log"; : > "$CALLS"
for c in curl wget; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$c" "$CALLS" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done
WLOG="$R1/logs/watchdog-url.log"
wu() { # wu <args...> -> OUT, RC ; PATH carries the recording curl/wget
  OUT=$(PATH="$T/fakebin:$PATH" watchdog_url "$@"); RC=$?
}
unset WATCHDOG_URL
wu ping "$R1"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "§1a unset: want rc 1 + empty stdout, got rc=$RC out='$OUT'"
wu ping "$R1"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "§1a unset (2nd call): want rc 1 + empty stdout, got rc=$RC out='$OUT'"
n=$(grep -cE "^${DAY}T[0-9:]+Z \[ping\] WATCHDOG_URL not set, watchdog call skipped \(set it in env/global.env\)$" "$WLOG" 2>/dev/null)
[ "${n:-0}" = 1 ] && [ "$(wc -l < "$WLOG" 2>/dev/null)" = 1 ] && ok \
  || bad "§1a two calls on one day must leave exactly 1 line, log: $(cat "$WLOG" 2>/dev/null)"
wu push "$R1"
[ "$RC" = 1 ] && ok || bad "§1a second lane: want rc 1, got $RC"
[ "$(grep -c '\[push\] WATCHDOG_URL not set' "$WLOG" 2>/dev/null)" = 1 ] \
  && [ "$(wc -l < "$WLOG")" = 2 ] && ok \
  || bad "§1a a second lane adds its own line (2 total), log: $(cat "$WLOG" 2>/dev/null)"
WATCHDOG_URL="" wu ping "$R1"
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(wc -l < "$WLOG")" = 2 ] && ok \
  || bad "§1a WATCHDOG_URL='' must behave like unset (rc 1, no new line), rc=$RC lines=$(wc -l < "$WLOG")"
wu ping "$R1" "$T/custom/wd.log"
[ "$RC" = 1 ] && grep -q '\[ping\] WATCHDOG_URL not set' "$T/custom/wd.log" 2>/dev/null && ok \
  || bad "§1a a custom 3rd-arg log path must be honoured"
# Yesterday's line does not count as today's.
R1Y="$T/r1y"; mkdir -p "$R1Y/logs"
echo "2000-01-01T00:00:00Z [ping] WATCHDOG_URL not set, watchdog call skipped (set it in env/global.env)" > "$R1Y/logs/watchdog-url.log"
wu ping "$R1Y"
[ "$(wc -l < "$R1Y/logs/watchdog-url.log")" = 2 ] && ok || bad "§1a an older day's line must not suppress today's"
# §1c no network, ever.
[ ! -s "$CALLS" ] && ok || bad "§1c watchdog_url must make no network call, saw: $(cat "$CALLS")"
# §1d set: value printed with one trailing slash stripped, no log line.
R1D="$T/r1d"; mkdir -p "$R1D"
WATCHDOG_URL=http://watchdog.invalid/ wu ping "$R1D"
[ "$RC" = 0 ] && [ "$OUT" = http://watchdog.invalid ] && ok \
  || bad "§1d set: want rc 0 + 'http://watchdog.invalid', got rc=$RC out='$OUT'"
[ ! -e "$R1D/logs/watchdog-url.log" ] && ok || bad "§1d a set URL must write no log line"

# ── §2 watchdog_url_carry ────────────────────────────────────────────────────
mkck() { # mkck <dir> [origin] ; catalog with the invalid fixture host
  scratch_rm "$1" || return 1; mkdir -p "$1/catalog"; git init -q "$1"
  printf '{"repo":"example-org/cromford","watchdog_url":"http://watchdog.invalid"}\n' > "$1/catalog/fleet-watchdog.json"
  [ -n "${2:-}" ] && git -C "$1" remote add origin "$2"
  return 0
}
for o in 'https://x-access-token:t@github.com/example-org/cromford.git' \
         'git@github.com:example-org/cromford.git' \
         'https://GitHub.com/example-org/cromford/' \
         'https://github.com/example-org/cromford'; do
  mkck "$T/c2" "$o"
  OUT=$(watchdog_url_carry "$T/c2"); RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = http://watchdog.invalid ] && ok || bad "§2a origin '$o' must carry, got rc=$RC out='$OUT'"
done
for o in 'https://github.com/someone/cromford.git' \
         'git@github.com:someone/cromford.git' \
         'https://github.com/example-org/cromford-fork.git' \
         'https://github.com/example-org/cromford2' \
         'https://github.com/example-org/xcromford.git' \
         'https://example-org/cromford@evil.invalid/x.git'; do
  mkck "$T/c2" "$o"
  OUT=$(watchdog_url_carry "$T/c2"); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "§2b origin '$o' must NOT carry, got rc=$RC out='$OUT'"
done
mkck "$T/c2"
OUT=$(watchdog_url_carry "$T/c2"); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "§2b no origin must not carry, got rc=$RC out='$OUT'"
mkck "$T/c2" 'https://github.com/example-org/cromford.git'; rm "$T/c2/catalog/fleet-watchdog.json"
OUT=$(watchdog_url_carry "$T/c2"); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "§2b a missing catalog file must not carry, got rc=$RC"
mkck "$T/c2" 'https://github.com/example-org/cromford.git'
printf '{"repo":"example-org/cromford","watchdog_url":""}\n' > "$T/c2/catalog/fleet-watchdog.json"
OUT=$(watchdog_url_carry "$T/c2"); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "§2b an empty .watchdog_url must not carry, got rc=$RC out='$OUT'"

# ── §1b the seed never touches its caller's fd 8 ─────────────────────────────
R1B="$T/r1b"; mkdir -p "$R1B/locks" "$R1B/logs" "$R1B/env" "$R1B/bin"
# harden-state stub: records the order of release/rearm around the append.
printf '#!/bin/bash\necho "$1 $(grep -c "^WATCHDOG_URL=" "$2" 2>/dev/null)" >> "%s"\n' "$R1B/hs.log" > "$R1B/bin/harden-state.sh"
chmod +x "$R1B/bin/harden-state.sh"
printf 'HARNESS_SECRET=x\n' > "$R1B/env/global.env"
mkck "$T/c1b" 'git@github.com:example-org/cromford.git'
HELD=$(
  exec 8>"$R1B/locks/sync.lock"; flock 8
  watchdog_url_seed "$T/c1b" "$R1B/env/global.env" "$R1B" >/dev/null 2>&1
  if flock -n "$R1B/locks/sync.lock" true; then echo released; else echo held; fi
)
[ "$HELD" = held ] && ok || bad "§1b the caller's fd-8 lock must still be held after the seed, it was $HELD"
[ "$(grep -c '^WATCHDOG_URL=http://watchdog.invalid$' "$R1B/env/global.env")" = 1 ] && ok \
  || bad "§1b the seed's append must land, global.env: $(cat "$R1B/env/global.env")"
[ "$(tr '\n' '|' < "$R1B/hs.log" 2>/dev/null)" = '--release 0|--rearm 1|' ] && ok \
  || bad "§1b want harden-state --release before the append and --rearm after, saw: $(tr '\n' '|' < "$R1B/hs.log" 2>/dev/null)"

# ── §3 registry and catalog ──────────────────────────────────────────────────
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" 2>/dev/null \
  | jq -e '[.libs[]|select(.id=="watchdog-url" and .file=="bin/lib/watchdog-url.sh")|.knobs[]|select(.env=="WATCHDOG_URL")|select(.default=="" and .settable==false and .required==false)]|length==1' >/dev/null \
  && ok || bad "§3a the composed registry must carry lib watchdog-url with WATCHDOG_URL default \"\" settable false"
[ "$(jq -r .watchdog_url "$CAT" 2>/dev/null)" = "https://$FLEET_HOST" ] && ok \
  || bad "§3b catalog/fleet-watchdog.json .watchdog_url must be the fleet host, got $(jq -r .watchdog_url "$CAT" 2>/dev/null)"
jq -e '.repo=="example-org/cromford"' "$CAT" >/dev/null 2>&1 && ok || bad "§3b .repo must be example-org/cromford"

# ── §6 bin/harness-sync.sh, run whole ────────────────────────────────────────
# Scaffold from tests/harness-sync-catalog-reset.bh-1042-test.sh. The checkout
# commits the REAL lib and the REAL catalog/fleet-watchdog.json.
H6="$T/h6"
mkdir -p "$H6/bin" "$H6/logs" "$H6/state" "$H6/locks" "$H6/prompts" "$H6/fly" \
         "$H6/catalog" "$H6/checks" "$H6/guardrails" "$H6/config" "$H6/env"
cp "$DIR/bin/alert-line.sh" "$H6/bin/"
mkorigin() { # mkorigin <bare> <clone>
  mkdir -p "$(dirname "$1")"; git init -q --bare "$1"
  git clone -q "$1" "$2" 2>/dev/null
  git -C "$2" config user.email t@t; git -C "$2" config user.name t
  mkdir -p "$2/bin/lib" "$2/prompts" "$2/fly" "$2/catalog"
  printf '#!/bin/bash\n:\n' > "$2/bin/x.sh"
  printf 'p\n' > "$2/prompts/p.md"
  printf 'f\n' > "$2/fly/f.txt"
  printf 'fleet\n' > "$2/fleet.conf"
  printf '#!/bin/bash\nexit 0\n' > "$2/bin/jobs-client.sh"; chmod +x "$2/bin/jobs-client.sh"
  cp "$DIR/bin/lib/watchdog-url.sh" "$2/bin/lib/watchdog-url.sh"
  cp "$DIR/catalog/fleet-watchdog.json" "$2/catalog/fleet-watchdog.json"
  git -C "$2" add -A >/dev/null
  git -C "$2" commit -qm seed
  git -C "$2" branch -M main 2>/dev/null
  git -C "$2" push -q origin main
  git -C "$2" branch --set-upstream-to=origin/main main >/dev/null 2>&1
}
mkorigin "$T/gh/example-org/cromford.git" "$T/ck6"
mkorigin "$T/gh/someone/cromford.git" "$T/ck6f"
GENV="$H6/env/global.env"
ULOG="$H6/logs/update-runners.log"
ALOG="$H6/logs/ALERTS.log"
WANT=$(jq -r .watchdog_url "$CAT" 2>/dev/null)
sync6() { # sync6 <checkout> -> RC
  ( export HARNESS="$H6" HARNESS_CHECKOUT="$1"
    bash "$DIR/bin/harness-sync.sh" ) >"$T/out6.txt" 2>"$T/err6.txt"
  RC=$?
}
nseed() { local n; n=$(grep -c 'WATCHDOG_URL seeded into env/global.env' "$ULOG" 2>/dev/null); echo "${n:-0}"; }

# §6a fresh box: seeded once, idempotent on the second run.
printf 'HARNESS_SECRET=x\n' > "$GENV"; : > "$ULOG"; : > "$ALOG"
sync6 "$T/ck6"
[ "$RC" = 0 ] && ok || bad "§6a harness-sync must exit 0, got $RC: $(cat "$T/out6.txt" "$T/err6.txt")"
[ "$(grep -c '^WATCHDOG_URL=https' "$GENV")" = 1 ] && ok || bad "§6a want 1 WATCHDOG_URL=https line, global.env: $(cat "$GENV")"
GOT=$( set -a; . "$GENV"; printf '%s' "${WATCHDOG_URL:-}" )
[ -n "$WANT" ] && [ "$GOT" = "$WANT" ] && ok || bad "§6a seeded value '$GOT' must equal catalog '$WANT'"
[ "$(nseed)" = 1 ] && ok || bad "§6a want 1 seed line in update-runners.log, saw $(nseed)"
sync6 "$T/ck6"
[ "$RC" = 0 ] && [ "$(grep -c '^WATCHDOG_URL=' "$GENV")" = 1 ] && [ "$(nseed)" = 1 ] && ok \
  || bad "§6a a second run must change nothing (rc=$RC lines=$(grep -c '^WATCHDOG_URL=' "$GENV") seeds=$(nseed))"
[ ! -s "$ALOG" ] && ok || bad "§6a a clean seed must write no ALERTS line: $(cat "$ALOG")"

# §6b an operator's own value is left byte-identical.
printf 'HARNESS_SECRET=x\nWATCHDOG_URL=https://other.invalid\n' > "$GENV"; : > "$ULOG"
B=$(sha256sum < "$GENV")
sync6 "$T/ck6"
[ "$RC" = 0 ] && [ "$(sha256sum < "$GENV")" = "$B" ] && [ "$(nseed)" = 0 ] && ok \
  || bad "§6b an operator WATCHDOG_URL must be untouched (rc=$RC): $(cat "$GENV")"

# §6c no global.env: nothing is created.
rm -f "$GENV"
sync6 "$T/ck6"
[ "$RC" = 0 ] && [ ! -e "$GENV" ] && ok || bad "§6c a missing global.env must stay missing (rc=$RC)"

# §6d an EMPTY WATCHDOG_URL= line is overridden by the append.
printf 'HARNESS_SECRET=x\nWATCHDOG_URL=\n' > "$GENV"; : > "$ULOG"
sync6 "$T/ck6"
GOT=$( set -a; . "$GENV"; printf '%s' "${WATCHDOG_URL:-}" )
[ "$RC" = 0 ] && [ "$(grep -c '^WATCHDOG_URL=https' "$GENV")" = 1 ] && [ "$GOT" = "$WANT" ] && ok \
  || bad "§6d an empty line must be overridden (rc=$RC got='$GOT'): $(cat "$GENV")"

# §6e a global.env the seed cannot write: ONE ALERTS line, the sync still exits 0.
rm -f "$GENV"; : > "$ULOG"; : > "$ALOG"
if [ "$(id -u)" -eq 0 ]; then mkdir "$GENV"; else printf 'HARNESS_SECRET=x\n' > "$GENV"; chmod 444 "$GENV"; fi
sync6 "$T/ck6"
[ "$RC" = 0 ] && ok || bad "§6e harness-sync must exit 0 on a failed seed, got $RC"
[ "$(grep -c 'global.env' "$ALOG" 2>/dev/null)" = 1 ] && grep -q 'WATCHDOG_URL' "$ALOG" && [ "$(wc -l < "$ALOG")" = 1 ] && ok \
  || bad "§6e want exactly 1 ALERTS line naming global.env and WATCHDOG_URL, saw: $(cat "$ALOG" 2>/dev/null)"
[ "$(nseed)" = 0 ] && ok || bad "§6e a failed write must never log 'seeded'"
chmod 644 "$GENV" 2>/dev/null; scratch_rm "$GENV"

# §6f a fork's checkout seeds nothing.
printf 'HARNESS_SECRET=x\n' > "$GENV"; : > "$ULOG"
sync6 "$T/ck6f"
[ "$RC" = 0 ] && [ "$(grep -c 'WATCHDOG_URL' "$GENV")" = 0 ] && [ "$(nseed)" = 0 ] && ok \
  || bad "§6f a fork origin must leave 0 WATCHDOG_URL lines (rc=$RC): $(cat "$GENV")"

echo "watchdog-url.bh-2091-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
