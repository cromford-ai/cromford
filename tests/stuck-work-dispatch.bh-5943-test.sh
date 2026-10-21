#!/bin/bash
# tests/stuck-work-dispatch.bh-5943-test.sh — BH-5943 (BH-5938.3): stuck-work
# on the per-project lane runner (bin/lib/project-lanes.sh). The cron line is
# `stuck-work.sh --dispatch`; each project's run has its own lock, log, pages
# and snapshot key, so a slow project never makes the next dispatch skip the
# others.
#
# THE RIG. A scratch $H (symlink tree of bin/ and catalog/, a built lanes.json)
# with fleet.conf p1 p2 p3 (FLEET_CONF). The real runner, gate, jobs client and
# classifier run. Stubbed: a fake `curl` as the jobs worker (ledger rows in
# $T/ledger.json, every request logged to $T/reqs as `<PL_PROJECT|-> METHOD
# path`), and bin/alert-line.sh, which records argv and, for `--project p1`,
# waits (30 s at most) until $T/release exists. The FACTS come from
# STUCK_WORK_FIXTURE=$T/fx, a directory of <project>.txt files.
#
#   AT-1a --dispatch returns rc 0, `started 3 project run(s)`, while p1's page
#         still blocks (no wall-clock bound, BH-6508)
#   AT-1b p1 blocked in its page: p2 and p3 finish, p1's lock is held
#   AT-1c a second dispatch: p2/p3 run again, p1 is `still live`, no p1 line
#   AT-1d release: p1 writes one line; each page carries its own --project;
#         the snapshot rows are per project, no `latest`
#   AT-1e the watched set: a named list, `self`, exact names, a bad value
#   AT-1f a hand run while the project's lock (or the legacy lock) is held: busy
#   AT-1g bad arguments exit 2 with no worker request
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-dispatch.bh-5943-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "stuck-work-dispatch: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "stuck-work-dispatch: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

FX="$DIR/tests/fixtures/stuck-work"
for f in "$DIR/bin/stuck-work.sh" "$DIR/bin/lib/project-lanes.sh" "$DIR/bin/project-lane-run.sh" \
         "$DIR/cron/lanes/723-stuck-work.cron" "$FX/scenario-ready-8m.txt"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "stuck-work-dispatch: 0 passed, 1 failed"; exit 1; }
done

# The cron line reaches the dispatcher, its output into the lane's cron log.
# The pattern sits in a variable and grep reads it directly, never through
# eval: a literal `>> /root/harness/...` inside an eval'd string is a write to
# the real harness as far as the trace check can tell (merge queue batch #6301).
CRON_RE='^\*/5 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/stuck-work.sh --dispatch >> /root/harness/logs/stuck-work-cron.log 2>&1$'
grep -qE "$CRON_RE" "$DIR/cron/lanes/723-stuck-work.cron" && ok || bad "AT-1a the cron line runs --dispatch"

H="$T/h"
mkdir -p "$H/env" "$T/fakebin" "$T/fx"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
: > "$H/env/global.env"
rm -f "$H/bin/lane-alert.sh" "$H/bin/alert-line.sh"
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts"
case " $* " in
  *" --project p1 "*) i=0; while [ ! -e "$FXT/release" ] && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
                      : > "$FXT/p1-page-returned" ;;
esac
exit 0
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/lane-alerts"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary|-d) body="$a" ;; -w) wfmt=1 ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
printf '%s %s %s\n' "${PL_PROJECT:--}" "$m" "$path" >> "$FXT/reqs"
dec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
code=200; out='{"ok":true}'
exec 7>"$FXT/ledger.lock"; flock 7
case "$m $path" in
  "GET /api/settings"*) out='{"settings":[]}' ;;
  "GET /api/ledger"*)
    k=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')")
    v=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')")
    row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
    if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi ;;
  "PUT /api/ledger"*)
    jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
      "$FXT/ledger.json" > "$FXT/ledger.tmp.$$" && mv "$FXT/ledger.tmp.$$" "$FXT/ledger.json" ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

# One READY PR past its SLA per project (the ready-8m fixture under another repo).
for p in p1 p2 p3; do sed "s#example-org/cromford#o/$p#g" "$FX/scenario-ready-8m.txt" > "$T/fx/$p.txt"; done
cp "$FX/scenario-ready-8m.txt" "$T/fx/cromford.txt"
printf 'p1 o/p1 - -\np2 o/p2 - -\np3 o/p3 - -\n' > "$T/fleet3.conf"
printf 'cromford example-org/cromford - -\np1 o/p1 - -\np2 o/p2 - -\n' > "$T/fleet-home.conf"

export HARNESS="$H" FXT="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
  PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW=$((1789999520 + 900)) STUCK_WORK_FIXTURE="$T/fx" \
  STUCK_WORK_DISPATCH_SPREAD_S=0 FLEET_CONF="$T/fleet3.conf"
unset GH_TOKEN GITHUB_TOKEN STUCK_WORK_ENABLED STUCK_WORK_REPO STUCK_WORK_PROJECTS LANE_GATE_DISABLE \
  HARNESS_ENV_DIR PL_LANE PL_PROJECT PL_LOCK_FD PL_SLUG PL_STATE_DIR 2>/dev/null || true

cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
sumlines() { cnt ' items=' "$H/logs/$1"; }
held() { [ -e "$H/locks/$1" ] && ! flock -n "$H/locks/$1" true; }
# waitfor <cmd> — poll a condition, 20 s at most (0.2 s steps).
waitfor() { local i=0; until eval "$1"; do i=$((i + 1)); [ "$i" -ge 100 ] && return 1; sleep 0.2; done; return 0; }
# settle — release any blocked p1 page and wait until no run holds a lock.
settle() {
  local l
  : > "$T/release"
  for l in "$H"/locks/stuck-work*.lock; do [ -e "$l" ] && waitfor "! held '${l##*/}'"; done
  return 0
}
wreset() {
  local p
  settle
  for p in "$T/reqs" "$T/alerts" "$T/lane-alerts" "$T/ledger.json" "$T/release" "$T/out" "$T/p1-page-returned" \
    "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  echo '{}' > "$T/ledger.json"; : > "$T/reqs"; : > "$T/alerts"
}
dispatch() { # dispatch [VAR=value ...] — the cron line's command, stdout to $T/out
  env "$@" bash "$H/bin/stuck-work.sh" --dispatch > "$T/out" 2>&1
  echo $? > "$T/rc"
}
hand() { # hand <args...> — a hand run, with any leading VAR=value as env
  local e=()
  while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do e+=("$1"); shift; done
  env "${e[@]}" bash "$H/bin/stuck-work.sh" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
snaprow() { jq -r --arg i "stuck_work_snapshot/$1" 'has($i)' "$T/ledger.json"; }
ledreqsof() { awk -v p="$1" '$1 == p && $3 ~ /^\/api\/ledger/' "$T/reqs" | wc -l | tr -d ' '; }
# reqsof <project> — every worker request a dispatched run of <project> made.
reqsof() { awk -v p="$1" '$1 == p' "$T/reqs" | wc -l | tr -d ' '; }

# ── AT-1a / AT-1b ───────────────────────────────────────────────────────────
wreset
dispatch STUCK_WORK_PROJECTS=all
# Read the marker first: a dispatch that waited on its runs saw p1's page return.
[ -e "$T/p1-page-returned" ] && P1_AT_EXIT=returned || P1_AT_EXIT=blocked
check "AT-1a rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "AT-1a returns while p1's page still blocks (p1 page: $P1_AT_EXIT)" '[ "$P1_AT_EXIT" = blocked ]'
check "AT-1a prints the dispatch line" 'grep -q "stuck-work dispatch: started 3 project run(s)" "$T/out"'
waitfor '[ "$(sumlines stuck-work-p2.log)" -ge 1 ] && [ "$(sumlines stuck-work-p3.log)" -ge 1 ]' \
  || bad "AT-1b p2/p3 never wrote a summary line ($(cat "$H"/logs/*.log 2>/dev/null | head -5))"
waitfor '[ "$(cnt "--project p1" "$T/alerts")" -ge 1 ]' || bad "AT-1b p1 never reached its page"
check "AT-1b p2 paged=1 ($(tail -n1 "$H/logs/stuck-work-p2.log" 2>/dev/null))" 'tail -n1 "$H/logs/stuck-work-p2.log" | grep -q " paged=1 "'
check "AT-1b p3 paged=1" 'tail -n1 "$H/logs/stuck-work-p3.log" | grep -q " paged=1 "'
check "AT-1b p1's lock is held while its page blocks" 'held stuck-work-p1.lock'
check "AT-1b p1 has no summary line yet" '[ "$(sumlines stuck-work-p1.log)" = 0 ]'

# ── AT-1c: the next dispatch while p1 is still blocked ──────────────────────
dispatch STUCK_WORK_PROJECTS=all
check "AT-1c rc 0" '[ "$(cat "$T/rc")" = 0 ]'
waitfor '[ "$(sumlines stuck-work-p2.log)" -ge 2 ] && [ "$(sumlines stuck-work-p3.log)" -ge 2 ]' \
  || bad "AT-1c p2/p3 did not run again ($(sumlines stuck-work-p2.log)/$(sumlines stuck-work-p3.log))"
waitfor 'grep -q "a run of p1 is still live" "$H/logs/stuck-work-cron.log" 2>/dev/null' \
  || bad "AT-1c no 'still live' line for p1 ($(cat "$H/logs/stuck-work-cron.log" 2>/dev/null))"
check "AT-1c p2's second run pages nothing ($(tail -n1 "$H/logs/stuck-work-p2.log"))" \
  'tail -n1 "$H/logs/stuck-work-p2.log" | grep -q " paged=0 repaged=0 "'
check "AT-1c p1 still has no summary line" '[ "$(sumlines stuck-work-p1.log)" = 0 ]'

# ── AT-1d: release p1 ───────────────────────────────────────────────────────
: > "$T/release"
waitfor '[ "$(sumlines stuck-work-p1.log)" -ge 1 ] && ! held stuck-work-p1.lock' || bad "AT-1d p1 never finished"
check "AT-1d p1 wrote exactly one summary line, paged=1" \
  '[ "$(sumlines stuck-work-p1.log)" = 1 ] && grep -q " paged=1 " "$H/logs/stuck-work-p1.log"'
check "AT-1d one page per project, each with its own --project ($(cut -c1-80 "$T/alerts" | tr '\n' '|'))" \
  '[ "$(wc -l < "$T/alerts")" = 3 ] && for p in p1 p2 p3; do grep -q -- "--project $p STUCK-WORK o/$p#120 " "$T/alerts" || exit 1; done'
check "AT-1d snapshot rows p1 p2 p3, no latest" \
  '[ "$(snaprow p1)$(snaprow p2)$(snaprow p3)$(snaprow latest)" = truetruetruefalse ]'
check "AT-1d the home log was not written" '[ ! -s "$H/logs/stuck-work.log" ]'

# ── AT-1e: the watched set ──────────────────────────────────────────────────
wreset
dispatch STUCK_WORK_PROJECTS=p2
check "AT-1e p2 only: the dispatch still starts 3 runs" 'grep -q "started 3 project run(s)" "$T/out"'
waitfor '[ "$(sumlines stuck-work-p2.log)" -ge 1 ]' || bad "AT-1e p2 never ran"
waitfor '[ -e "$H/locks/stuck-work-p1.lock" ] && [ -e "$H/locks/stuck-work-p3.lock" ] && ! held stuck-work-p1.lock && ! held stuck-work-p3.lock' \
  || bad "AT-1e p1/p3 runs never ended"
check "AT-1e p1/p3 wrote no log" '[ ! -e "$H/logs/stuck-work-p1.log" ] && [ ! -e "$H/logs/stuck-work-p3.log" ]'
# TEST-CHANGE (BH-5943 review F1): no worker request at all, as the plan's
# AT-1e says, not only no ledger request. The gate's flag reads and liveness
# POST count too. (The lane-off-stuck-work-<p> stamps are the dispatcher's own
# per-project flag reads, logged as "-", so they are not checked here.)
check "AT-1e p1/p3 made no worker request ($(reqsof p1)/$(reqsof p3): $(awk '$1 == "p1" || $1 == "p3"' "$T/reqs" | head -4 | tr '\n' '|'))" \
  '[ "$(reqsof p1)" = 0 ] && [ "$(reqsof p3)" = 0 ]'
check "AT-1e p2 read the ledger" '[ "$(ledreqsof p2)" -ge 1 ]'
check "AT-1e only p2 paged" '[ "$(wc -l < "$T/alerts")" = 1 ] && grep -q -- "--project p2 " "$T/alerts"'

wreset
dispatch STUCK_WORK_PROJECTS=self FLEET_CONF="$T/fleet-home.conf"
waitfor '[ "$(sumlines stuck-work.log)" -ge 1 ]' || bad "AT-1e self: the home run never wrote stuck-work.log"
settle
check "AT-1e self: the home run wrote logs/stuck-work.log ($(tail -n1 "$H/logs/stuck-work.log"))" \
  'tail -n1 "$H/logs/stuck-work.log" | grep -qxE "[0-9T:Z-]+ items=1 states=ready:1 past_sla=1 paged=1 repaged=0 incomplete=0"'
check "AT-1e self: the latest snapshot, and no per-project one" '[ "$(snaprow latest)$(snaprow cromford)" = truefalse ]'
check "AT-1e self: the home page says --project cromford" \
  '[ "$(wc -l < "$T/alerts")" = 1 ] && grep -q -- "--project cromford STUCK-WORK example-org/cromford#120 " "$T/alerts"'
check "AT-1e self: p1/p2 made no worker request, wrote no log" \
  '[ "$(reqsof p1)" = 0 ] && [ "$(reqsof p2)" = 0 ] && [ ! -e "$H/logs/stuck-work-p1.log" ] && [ ! -e "$H/logs/stuck-work-p2.log" ]'

# sw_watched through hand runs: exact names only, empty = self, a bad value = self
watched_case() { # watched_case <label> <list> <project> <want 1|0>
  wreset
  hand STUCK_WORK_PROJECTS="$2" "$3"
  local got=0 want=$4; [ "$(sumlines "stuck-work-$3.log")" -ge 1 ] && got=1
  check "AT-1e $1: STUCK_WORK_PROJECTS='$2' $3 -> $want (got $got, rc $(cat "$T/rc"), $(head -c 200 "$T/err"))" \
    '[ "$got" = "$want" ] && [ "$(cat "$T/rc")" = 0 ]'
  # A hand run starts with a cold settings cache, so its one allowed request is
  # the TTL-shared GET /api/settings. Nothing else: no flag read, no liveness
  # POST, no ledger read, no lane-gate stamp (BH-5943 review F1). That read
  # also renders state/lane-gate/settings-cache.env from the new cache
  # (BH-7717). It is the one entry state/lane-gate may hold; any other entry
  # (a stamp, a .paused, a .settings-miss, a temp file) is still red.
  [ "$want" = 1 ] || check "AT-1e $1: not watched, so no request but the settings read ($(grep -v " GET /api/settings" "$T/reqs" | head -3 | tr '\n' '|')) and no lane-gate entry but the settings render ($(ls -A "$H/state/lane-gate" 2>/dev/null | grep -vx settings-cache.env | head -3 | tr '\n' '|'))" \
    '! grep -qv " GET /api/settings" "$T/reqs" && [ -z "$(ls -A "$H/state/lane-gate" 2>/dev/null | grep -vx settings-cache.env)" ] && [ ! -e "$H/logs" ]'
}
watched_case "all" all p3 1
watched_case "a single name" p2 p2 1
watched_case "a comma list" p1,p2 p2 1
watched_case "exact match only" p22 p2 0
watched_case "exact match only (list)" p1,p22 p2 0
watched_case "self, not home" self p1 0
watched_case "empty is self" "" p1 0
watched_case "a bad value is self" "bogus value" p1 0
check "AT-1e a bad value says so once on stderr ($(cat "$T/err"))" \
  '[ "$(grep -c "STUCK_WORK_PROJECTS" "$T/err")" = 1 ]'

# ── AT-1f: a hand run while the lock is held ────────────────────────────────
wreset; mkdir -p "$H/locks"
exec 8>"$H/locks/stuck-work-p2.lock"; flock -n 8 || bad "AT-1f setup: could not take the p2 lock"
hand STUCK_WORK_PROJECTS=all p2
exec 8>&-
check "AT-1f p2 held: rc 0, busy ($(tail -n1 "$H/logs/stuck-work-p2.log" 2>/dev/null))" \
  '[ "$(cat "$T/rc")" = 0 ] && tail -n1 "$H/logs/stuck-work-p2.log" | grep -qxE "[0-9T:Z-]+ busy"'
check "AT-1f p2 held: no ledger request, no page" '[ "$(cnt "/api/ledger" "$T/reqs")" = 0 ] && [ ! -s "$T/alerts" ]'
wreset; mkdir -p "$H/locks"
exec 8>"$H/locks/stuck-work.lock"; flock -n 8 || bad "AT-1f setup: could not take the legacy lock"
hand FLEET_CONF="$T/fleet-home.conf"
exec 8>&-
check "AT-1f legacy lock held: the home run logs busy ($(tail -n1 "$H/logs/stuck-work.log" 2>/dev/null))" \
  '[ "$(cat "$T/rc")" = 0 ] && tail -n1 "$H/logs/stuck-work.log" | grep -qxE "[0-9T:Z-]+ busy"'

# ── AT-1g: bad arguments ────────────────────────────────────────────────────
printf 'ci o/ci - -\np1 o/p1 - -\n' > "$T/fleet-ci.conf"
for a in 'a/b' nosuch ci led seen thread '--bogus' 'p1 p2'; do
  wreset
  # shellcheck disable=SC2086 # 'p1 p2' is two arguments on purpose
  hand STUCK_WORK_PROJECTS=all FLEET_CONF="$T/fleet-ci.conf" $a
  check "AT-1g '$a': rc 2 ($(cat "$T/rc"); $(head -c 200 "$T/err"))" '[ "$(cat "$T/rc")" = 2 ] && [ -s "$T/err" ]'
  check "AT-1g '$a': no worker request ($(head -3 "$T/reqs"))" '[ ! -s "$T/reqs" ]'
done
wreset; hand FLEET_CONF="$T/fleet-ci.conf" ci
check "AT-1g a fleet project named ci is refused as reserved ($(cat "$T/err"))" '[ "$(cat "$T/rc")" = 2 ] && grep -q "reserved" "$T/err"'

settle
echo "stuck-work-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
