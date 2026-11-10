#!/bin/bash
# tests/main-red-detection.bh-9284-test.sh — BH-9284: the hourly main-red full
# pass is not starved by the */5 recheck, a starved full pass is said once, and
# the pair lane reads every fleet repo.
#
#   THE INCIDENT (2026-11-06 .. 2026-11-08). The merge conductor's hourly full
#   pass of bin/main-red-detector.sh took locks/main-red-detector.lock with
#   `flock -n` at minute 00, the same minute the */5 recheck held it. Every
#   full pass exited at once: 0 full passes from 2026-11-06 19:00Z on, and no
#   alert said so. On 2026-11-08 two project-6 PRs failed the same job with the
#   same first error, and bin/main-red-pr-pair.sh raised nothing because it
#   read only $HARNESS_REPO.
#
#   THE PROPERTY UNDER TEST.
#   W1  --wait-lock waits (default 90 s) for a lock held 20 s and completes.
#   W2  a lock held past the wait logs ONE `full pass: reason=lock-held` line,
#       reads no runs, stamps nothing.
#   W3  no flag: a held lock still ends the pass at once (flock -n).
#   W4  a wait knob that is not a whole number is the default 90.
#   W5  --flagged-only never waits, even with --wait-lock.
#   W6  --explain --wait-lock takes no lock and writes no record.
#   W7  -h names THE FULL PASS WAITS and --wait-lock; an unknown flag is rc 2.
#   C1  the conductor's mc_tick_main_red passes --wait-lock.
#   S1  a completed scheduled pass stamps full-pass.last.
#   S2  2 h since the last pass: exactly one warn alert that names the last
#       pass and quotes the last lock-held line.
#   S3  7199 s and 3600 s: no alert.
#   S4  two more starved passes: still one alert.
#   S5  no stamp: the first give-up only starts the clock; 2 h later one alert
#       that says "none recorded since".
#   S6  a completed pass resolves once and clears the marker; a later stale
#       period alerts again.
#   S7  --flagged-only and a pass with repo arguments never stamp.
#   S8  the stale knob 0 never alerts; a stamp that is not an epoch sends
#       nothing and logs one line.
#   R1  the ledgers-row store is the record: one alert, the marker row, no
#       state file.  R2  an unreadable row sends nothing and logs one line.
#   R3  a marker row that is not written sends nothing.  R4  a completed pass
#       stamps the row and resolves an open alert once.
#   P1  the pair lane with MAIN_RED_PAIR_REPOS unset reads every fleet repo
#       and raises the pair for example-org/project-6.
#   P2  a hand-set MAIN_RED_PAIR_REPOS wins.  P3  no fleet.conf: $HARNESS_REPO.
#   P4  repo arguments win over the env and fleet.conf.
#
# The scripts run with their real lib closure. Only lane-alert.sh,
# jobs-client.sh, fleet-conf.sh, gh and (for the clock edges) date are stubs:
# 0 network calls. Every case builds its own scratch tree. Run from anywhere;
# exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
  echo "main-red-detection.bh-9284-test: SKIPPED — jq/python3/flock is not installed"; exit 0; }
REAL_DATE=$(command -v date)

# ── one scratch tree per case ───────────────────────────────────────────────
NCASE=0; C=""
new_case() {
  release_lock
  NCASE=$((NCASE+1)); C="$T/case$NCASE"
  mkdir -p "$C/bin/lib" "$C/logs" "$C/state" "$C/flags" "$C/locks" "$C/env" "$C/fakebin" "$C/pages" "$C/ledger"
  : > "$C/env/global.env"; : > "$C/alerts.txt"; : > "$C/gh.txt"; : > "$C/publish.txt"
  printf '#!/bin/bash\nexit 0\n' > "$C/bin/beat.sh"
  cat > "$C/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
  # fleet.conf rows mk and demo map to two fleet repos; anything else to none.
  cat > "$C/bin/fleet-conf.sh" <<'SHIM'
#!/bin/bash
case "$1:$2" in
  mk:repo) echo example-org/project-6 ;;
  demo:repo) echo example-org/demo-os ;;
  *) exit 1 ;;
esac
SHIM
  # No JOBS_URL is set, so mrs_on says "no DB here" and the lanes use state/.
  cat > "$C/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
SHIM
  # A pinned clock for the edge cases: `date +%s` answers FAKE_NOW when set.
  cat > "$C/fakebin/date" <<SHIM
#!/bin/bash
if [ "\$*" = "+%s" ] && [ -n "\${FAKE_NOW:-}" ]; then echo "\$FAKE_NOW"; exit 0; fi
exec "$REAL_DATE" "\$@"
SHIM
  # gh shim. The detector's runs read serves pages/<dashed>.json through its
  # own -q expression. The pair lane's PR list serves pulls-<dashed>.json (else
  # an empty list), its head runs runs-<sha>.json, its jobs and logs
  # jobs-<run>.txt and joblog-<job>.txt. Every call is recorded.
  cat > "$C/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
case "$A" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/pulls?state=open"*)
    s=${A#*repos/}; s=${s%%/pulls*}
    case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
    f="$C/pulls-$(printf '%s' "$s" | tr '/' '-').json"
    if [ -f "$f" ]; then cat "$f"; else echo "[]"; fi ;;
  "pr list"*) echo "[]" ;;
  *"/actions/jobs/"*"/logs"*)
    jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
    case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
    [ -f "$C/joblog-$jid.txt" ] || exit 1
    cat "$C/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*)
    rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
    cat "$C/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*"head_sha="*)
    sha=${A##*head_sha=}; sha=${sha%% *}
    [ -s "$C/runs-$sha.json" ] || exit 1
    jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url, id:.id}]' "$C/runs-$sha.json" ;;
  *"/actions/runs/"*) echo "" ;;
  *"actions/runs"*)
    slug=""; q=""; prev=""
    for a in "$@"; do
      case "$a" in repos/*/actions/runs) slug=${a#repos/}; slug=${slug%/actions/runs} ;; esac
      [ "$prev" = -q ] && q="$a"; prev="$a"
    done
    f="$C/pages/$(printf '%s' "$slug" | tr '/' '-').json"
    [ -s "$f" ] || exit 0
    if [ -n "$q" ]; then jq -c "$q" "$f"; else cat "$f"; fi ;;
  *) echo "" ;;
esac
SHIM
  chmod +x "$C/bin/beat.sh" "$C/bin/lane-alert.sh" "$C/bin/fleet-conf.sh" "$C/fakebin/gh" "$C/fakebin/date"
  # The real lib closures; the stubs above were written first, so they stay.
  for s in bin/main-red-detector.sh bin/main-red-pr-pair.sh; do
    scratch_install_closure "$s" "$C" >/dev/null || bad "setup case$NCASE: $s closure install failed"
  done
  REPOS=""; WAIT=""; STALE=""; PAIRS=""; NOWV=""; ROWS=""
}

CI=".github/workflows/ci.yml"
one_green() { # one_green <slug> — one completed green required run on main
  jq -nc --arg slug "$1" --arg p "$CI" '{total_count:1, workflow_runs:[
    {id:100, name:"ci", path:$p, status:"completed", conclusion:"success", head_sha:"green0001",
     event:"push", created_at:"2026-11-08T20:00:00Z", updated_at:"2026-11-08T20:10:00Z", run_attempt:1,
     html_url:("https://github.com/" + $slug + "/actions/runs/100")}]}' \
    > "$C/pages/$(printf '%s' "$1" | tr '/' '-').json"
}
flag() { # flag <slug>
  printf 'sha=deadbeef\nworkflow=ci\npath=%s\nreason=tip\nrun=https://github.com/%s/actions/runs/1\n' \
    "$CI" "$1" > "$C/flags/main-red-$(printf '%s' "$1" | tr '/' '-')"
}
fp()   { printf '%s/state/main-red/full-pass.%s' "$C" "$1"; }
setfp() { mkdir -p "$C/state/main-red"; printf '%s\n' "$2" > "$(fp "$1")"; }
getfp() { [ -f "$(fp "$1")" ] && tr -d '\n' < "$(fp "$1")"; }
nofp()  { ! ls "$C"/state/main-red/full-pass.* >/dev/null 2>&1; }
iso() { "$REAL_DATE" -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

HOLDER=""
hold_lock() { # hold_lock <seconds> — a background holder of the detector lock
  local lf="$C/locks/main-red-detector.lock" i=0
  flock -o "$lf" sleep "$1" & HOLDER=$!
  while flock -n "$lf" true 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 100 ] && { bad "setup: the holder never took the lock"; return 1; }
    sleep 0.1
  done
}
release_lock() {
  [ -n "$HOLDER" ] || return 0
  pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
}
trap release_lock EXIT

_env() {
  export PATH="$C/fakebin:$PATH" HARNESS="$C" C="$C" GH_SINK="$C/gh.txt" \
         ALERT_SINK="$C/alerts.txt" PUBLISH_SINK="$C/publish.txt" \
         MAIN_RED_QUEUE=0 HARNESS_REPO=example-org/cromford
  unset REGISTRY_SOURCE GH_TOKEN LANE_START_SPREAD_S JOBS_URL HARNESS_SECRET MAIN_RED_PAIR_REPOS \
        MAIN_RED_FULL_PASS_LOCK_WAIT_S MAIN_RED_FULL_PASS_STALE_MIN MAIN_RED_REPOS FAKE_NOW
  [ -n "$REPOS" ] && export MAIN_RED_REPOS="$REPOS"
  [ -n "$WAIT" ] && export MAIN_RED_FULL_PASS_LOCK_WAIT_S="$WAIT"
  [ -n "$STALE" ] && export MAIN_RED_FULL_PASS_STALE_MIN="$STALE"
  [ -n "$PAIRS" ] && export MAIN_RED_PAIR_REPOS="$PAIRS"
  [ -n "$NOWV" ] && export FAKE_NOW="$NOWV"
  [ -n "$ROWS" ] && export JOBS_URL=http://192.0.2.1 HARNESS_SECRET=fixture-secret
  return 0
}
DRC=0; DSEC=0
drive_detector() { local t0=$SECONDS; ( _env; bash "$C/bin/main-red-detector.sh" "$@" >"$C/out.txt" 2>"$C/err.txt" ); DRC=$?; DSEC=$((SECONDS - t0)); }
drive_pair()     { ( _env; bash "$C/bin/main-red-pr-pair.sh" "$@" >"$C/out.txt" 2>"$C/err.txt" ); DRC=$?; }
mrlog()  { cat "$C/logs/main-red.log" 2>/dev/null; }
cnt()    { grep -cE -- "$1" "$C/logs/main-red.log" 2>/dev/null | tr -d ' '; }
alerts() { awk 'END{print NR+0}' "$C/alerts.txt" 2>/dev/null; }
stale_alerts() { grep -c -- '--severity warn --id main-red-full-pass-stale ' "$C/alerts.txt" 2>/dev/null | tr -d ' '; }
runs_reads() { grep -c 'actions/runs' "$C/gh.txt" 2>/dev/null | tr -d ' '; }
# give_up — one waited full pass that loses the lock (wait 1 s).
give_up() { WAIT=1; hold_lock 30; drive_detector --wait-lock; release_lock; }

# ── W1 (AT1): --wait-lock waits out a 20 s hold (default wait) and completes ─
new_case; REPOS="o/r"; one_green o/r
hold_lock 20
drive_detector --wait-lock
release_lock
[ "$DRC" = 0 ] && ok || bad "W1 want rc 0, got $DRC: $(head -3 "$C/err.txt")"
[ "$DSEC" -ge 10 ] && ok || bad "W1 the pass did not wait for the lock (${DSEC}s)"
[ "$(cnt 'pass end: decided 1 of 1 repo\(s\) in [0-9]+s, exit 0, signal none')" = 1 ] && ok || bad "W1 no clean pass end line:
$(mrlog)"
[ "$(cnt 'reason=lock-held')" = 0 ] && ok || bad "W1 a lock-held line on a pass that waited:
$(mrlog)"
case "$(getfp last)" in ''|*[!0-9]*) bad "W1 full-pass.last is not an epoch: '$(getfp last)'" ;; *) ok ;; esac

# ── W2 (AT2): a lock held past the wait: one lock-held line, nothing read ────
new_case; REPOS="o/r"; WAIT=2; one_green o/r; flag o/r; cp "$C/flags/main-red-o-r" "$C/f.before"
hold_lock 30
drive_detector --wait-lock
release_lock
[ "$DRC" = 0 ] && ok || bad "W2 want rc 0, got $DRC"
[ "$(cnt 'full pass: reason=lock-held .*waited 2s for locks/main-red-detector.lock')" = 1 ] && ok || bad "W2 want 1 full-pass lock-held line:
$(mrlog)"
[ "$(cnt ' main-red-o-r: decision=none reason=lock-held ')" = 1 ] && ok || bad "W2 the per-flag lock-held line is gone"
[ "$(cnt 'pass end:')" = 0 ] && ok || bad "W2 a pass end line on a pass that never got the lock"
[ "$DSEC" -ge 2 ] && [ "$DSEC" -le 10 ] && ok || bad "W2 want 2..10 s, took ${DSEC}s"
[ "$(runs_reads)" = 0 ] && ok || bad "W2 a runs read under a held lock"
[ -z "$(getfp last)" ] && ok || bad "W2 a pass that never ran stamped last"
cmp -s "$C/f.before" "$C/flags/main-red-o-r" && ok || bad "W2 the flag changed"

# ── W3: no flag: a held lock ends the pass at once, as before ────────────────
new_case; REPOS="o/r"; one_green o/r
hold_lock 30
drive_detector
release_lock
[ "$DRC" = 0 ] && [ "$DSEC" -lt 3 ] && ok || bad "W3 want rc 0 in < 3 s, got rc $DRC in ${DSEC}s"
[ "$(cnt 'full pass:')" = 0 ] && ok || bad "W3 an unwaited pass logged a full pass line"

# ── W4: a wait knob that is not a whole number is the default 90 ─────────────
new_case; REPOS="o/r"; WAIT=abc; one_green o/r
drive_detector --wait-lock
[ "$(cnt 'full-pass knobs wait=90 \(from default\) stale=120 \(from default\)')" = 1 ] && ok || bad "W4 want the default knobs line:
$(mrlog)"
new_case; REPOS="o/r"; WAIT=7; STALE=30; one_green o/r
drive_detector --wait-lock
[ "$(cnt 'full-pass knobs wait=7 \(from env\) stale=30 \(from env\)')" = 1 ] && ok || bad "W4 want the env knobs line:
$(mrlog)"

# ── W5: --flagged-only never waits, even with --wait-lock ────────────────────
new_case; REPOS="o/r"; flag o/r
hold_lock 30
drive_detector --flagged-only --wait-lock
release_lock
[ "$DRC" = 0 ] && ok || bad "W5 want rc 0, got $DRC: $(head -3 "$C/err.txt")"
[ "$DSEC" -lt 3 ] && ok || bad "W5 the recheck waited for the lock (${DSEC}s)"
[ "$(cnt 'full pass:')" = 0 ] && ok || bad "W5 a recheck logged a full pass line"
nofp && ok || bad "W5 a recheck wrote a full-pass record: $(ls "$C/state/main-red")"

# ── W6: --explain --wait-lock takes no lock and writes no record ─────────────
new_case; REPOS="o/r"; one_green o/r
hold_lock 30
drive_detector --explain --wait-lock
release_lock
[ "$DRC" = 0 ] && [ "$DSEC" -lt 5 ] && ok || bad "W6 want rc 0 at once, got rc $DRC in ${DSEC}s"
[ -s "$C/out.txt" ] && ok || bad "W6 --explain printed nothing"
nofp && ok || bad "W6 --explain wrote a full-pass record"

# ── W7: the header documents the choice; an unknown flag is still rc 2 ───────
new_case
( _env; bash "$C/bin/main-red-detector.sh" -h ) > "$C/help.txt" 2>&1
grep -q 'THE FULL PASS WAITS' "$C/help.txt" && grep -q -- '--wait-lock' "$C/help.txt" && ok \
  || bad "W7 -h does not show THE FULL PASS WAITS and --wait-lock"
( _env; bash "$C/bin/main-red-detector.sh" --nope ) >/dev/null 2>&1; [ $? = 2 ] && ok || bad "W7 an unknown flag is not rc 2"

# ── C1: the conductor's full pass passes --wait-lock ─────────────────────────
new_case
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/det-argv.txt"\nexit 0\n' "$C" > "$C/bin/main-red-detector.sh"
chmod +x "$C/bin/main-red-detector.sh"
( H="$C"; MC_LOCK_DIR="$C/locks"; MC_ONLY_KEYS=""
  unset MC_ONLY_PROJECT MC_MAIN_RED_DETECT MC_FLEET_SWEEPS
  mc_log() { :; }
  # shellcheck source=bin/lib/mc/tick-scope.sh
  . "$DIR/bin/lib/mc/tick-scope.sh" || exit 8
  mc_tick_main_red )
[ "$(cat "$C/det-argv.txt" 2>/dev/null)" = "--wait-lock" ] && ok \
  || bad "C1 the conductor called the detector with '$(cat "$C/det-argv.txt" 2>/dev/null)', want --wait-lock"

# ── S1: a completed scheduled pass stamps full-pass.last ─────────────────────
new_case; REPOS="o/r"; one_green o/r
B=$("$REAL_DATE" +%s)
drive_detector
L=$(getfp last)
[ -n "$L" ] && [ "$L" -ge "$B" ] && ok || bad "S1 a completed pass did not stamp last (got '$L', want >= $B)"
[ "$(alerts)" = 0 ] && ok || bad "S1 a completed pass with no open alert sent: $(cat "$C/alerts.txt")"

# ── S2 (AT2): 2 h: one alert naming the last pass and the lock-held line ─────
new_case; REPOS="o/r"
N=2000000000; L=$((N - 7200)); setfp last "$L"; NOWV=$N
HL='2026-11-08 19:00:01Z main-red-o-r: decision=none reason=lock-held — another pass holds locks/main-red-detector.lock'
printf '%s\n' "$HL" >> "$C/logs/main-red.log"
give_up
[ "$(stale_alerts)" = 1 ] && [ "$(alerts)" = 1 ] && ok || bad "S2 want 1 stale alert, got: $(cat "$C/alerts.txt")"
grep -qF "Last completed pass: $(iso "$L")" "$C/alerts.txt" && ok || bad "S2 the alert does not name the last pass $(iso "$L"): $(cat "$C/alerts.txt")"
# The give-up's own line is logged before the watch reads, so it is the last one.
grep -qF 'Last lock-held line: ' "$C/alerts.txt" && grep -qF 'full pass: reason=lock-held — waited 1s' "$C/alerts.txt" && ok \
  || bad "S2 the alert does not quote the last lock-held line: $(cat "$C/alerts.txt")"
[ "$(getfp alerted)" = "$L" ] && ok || bad "S2 the marker is not the last pass: '$(getfp alerted)'"
[ "$(cnt 'full-pass watch: ALERT\(warn\) sent')" = 1 ] && ok || bad "S2 no ALERT sent log line"

# ── S3: 7199 s and 3600 s: no alert ──────────────────────────────────────────
new_case; REPOS="o/r"; setfp last $((N - 7199)); NOWV=$N
give_up
[ "$(alerts)" = 0 ] && ok || bad "S3 an alert at 7199 s: $(cat "$C/alerts.txt")"
new_case; REPOS="o/r"; setfp last $((N - 3600)); NOWV=$N
give_up
[ "$(alerts)" = 0 ] && ok || bad "S3 an alert at 3600 s: $(cat "$C/alerts.txt")"

# ── S4: two more starved passes in one stale period: still one alert ─────────
new_case; REPOS="o/r"; L=$((N - 7200)); setfp last "$L"; NOWV=$N
give_up
NOWV=$((N + 3600)); give_up
NOWV=$((N + 7200)); give_up
[ "$(stale_alerts)" = 1 ] && [ "$(alerts)" = 1 ] && ok || bad "S4 a second alert in one stale period: $(cat "$C/alerts.txt")"

# ── S5: no stamp: the first give-up starts the clock, 2 h later one alert ────
new_case; REPOS="o/r"; NOWV=$N
give_up
[ "$(alerts)" = 0 ] && ok || bad "S5 the first give-up with no history alerted"
[ "$(getfp watch_since)" = "$N" ] && ok || bad "S5 the first give-up did not write watch_since=$N: '$(getfp watch_since)'"
NOWV=$((N + 7200)); give_up
[ "$(stale_alerts)" = 1 ] && ok || bad "S5 want 1 alert 2 h after watch_since: $(cat "$C/alerts.txt")"
grep -qF "none recorded since $(iso "$N")" "$C/alerts.txt" && ok || bad "S5 the alert does not say none recorded since: $(cat "$C/alerts.txt")"

# ── S6: a completed pass resolves once; a later stale period alerts again ────
new_case; REPOS="o/r"; one_green o/r; L=$((N - 7200)); setfp last "$L"; NOWV=$N
give_up
NOWV=""; WAIT=""
drive_detector
[ "$DRC" = 0 ] && ok || bad "S6 want rc 0, got $DRC: $(head -3 "$C/err.txt")"
[ "$(grep -c -- '--resolve --log-only --id main-red-full-pass-stale ' "$C/alerts.txt")" = 1 ] && [ "$(alerts)" = 2 ] && ok \
  || bad "S6 want exactly 1 resolve after the alert: $(cat "$C/alerts.txt")"
[ ! -e "$(fp alerted)" ] && [ ! -e "$(fp watch_since)" ] && ok || bad "S6 the marker or watch_since is not cleared"
L2=$(getfp last)
NOWV=$((L2 + 7200)); give_up
[ "$(stale_alerts)" = 2 ] && ok || bad "S6 a new stale period did not alert again: $(cat "$C/alerts.txt")"

# ── S7: a recheck and a pass with repo arguments never stamp ─────────────────
new_case; REPOS="o/r"; one_green o/r; flag o/r; setfp last 1000
drive_detector --flagged-only
[ "$(cnt 'pass start: recheck')" = 1 ] && ok || bad "S7 the recheck did not run"
[ "$(getfp last)" = 1000 ] && ok || bad "S7 a recheck stamped last"
drive_detector o/r
[ "$(cnt 'pass end:.*exit 0')" -ge 2 ] && ok || bad "S7 the args pass did not complete"
[ "$(getfp last)" = 1000 ] && ok || bad "S7 a pass with repo arguments stamped last"

# ── S8: stale knob 0 never alerts; a non-epoch stamp sends nothing ───────────
new_case; REPOS="o/r"; setfp last $((N - 86400)); NOWV=$N; STALE=0
give_up
[ "$(alerts)" = 0 ] && ok || bad "S8 the stale knob 0 still alerted"
new_case; REPOS="o/r"; setfp last "garbage"; NOWV=$N
give_up
[ "$(alerts)" = 0 ] && ok || bad "S8 a non-epoch stamp alerted"
[ "$(cnt 'full-pass watch: .*not an epoch')" = 1 ] && ok || bad "S8 a non-epoch stamp logged no line:
$(mrlog)"

# ── R1-R3: the ledgers-row store (JOBS_URL set, every other request fails) ───
rows_case() { # a case whose record is the main_red_full_pass ledgers rows
  new_case; REPOS="o/r"; ROWS=1
  cat >> "$C/bin/jobs-client.sh" <<'SHIM'
_jobs_req() { return 1; }
job_ledger_get() {
  [ "$1" = main_red_full_pass ] && [ -n "${LEDGER_GET_FAIL:-}" ] && return 1
  local f="$C/ledger/$1__$(printf '%s' "$2" | tr '/' '-')"; [ -f "$f" ] || return 2; cat "$f"
}
job_ledger_put() {
  [ "$1" = main_red_full_pass ] && [ "$2" = alerted ] && [ -n "${LEDGER_PUT_FAIL:-}" ] && return 1
  printf '%s' "$3" > "$C/ledger/$1__$(printf '%s' "$2" | tr '/' '-')"
}
SHIM
  printf '#!/bin/bash\nexit 7\n' > "$C/fakebin/curl"; chmod +x "$C/fakebin/curl"
}
row() { cat "$C/ledger/main_red_full_pass__$1" 2>/dev/null; }
# R1: the row store is the record: one alert, the marker row, no state file.
rows_case; printf '%s' $((N - 7200)) > "$C/ledger/main_red_full_pass__last"; NOWV=$N
give_up
[ "$(stale_alerts)" = 1 ] && [ "$(row alerted)" = $((N - 7200)) ] && ok \
  || bad "R1 the row store did not alert and mark: $(cat "$C/alerts.txt") / marker '$(row alerted)'"
nofp && ok || bad "R1 the row store wrote the file fallback: $(ls "$C/state/main-red")"
give_up
[ "$(stale_alerts)" = 1 ] && ok || bad "R1 a second alert from the row store"
# R2: an unreadable row is never read as none: no alert, one line.
rows_case; printf '%s' $((N - 7200)) > "$C/ledger/main_red_full_pass__last"; NOWV=$N
( export LEDGER_GET_FAIL=1; give_up )
[ "$(alerts)" = 0 ] && ok || bad "R2 an unreadable row sent: $(cat "$C/alerts.txt")"
[ "$(cnt 'full-pass watch: the completed-pass stamp row is unreadable')" = 1 ] && ok || bad "R2 no unreadable line:
$(mrlog)"
# R3: a marker that cannot be written sends nothing.
rows_case; printf '%s' $((N - 7200)) > "$C/ledger/main_red_full_pass__last"; NOWV=$N
( export LEDGER_PUT_FAIL=1; give_up )
[ "$(alerts)" = 0 ] && ok || bad "R3 a send with no marker written: $(cat "$C/alerts.txt")"
[ "$(cnt 'full-pass watch: the alert marker was not written')" = 1 ] && ok || bad "R3 no marker-not-written line:
$(mrlog)"
# R4: a completed pass stamps the row and resolves the open alert once.
rows_case; one_green o/r; printf '%s' 1000 > "$C/ledger/main_red_full_pass__last"; printf '%s' 1000 > "$C/ledger/main_red_full_pass__alerted"
drive_detector
[ "$DRC" = 0 ] && ok || bad "R4 want rc 0, got $DRC: $(head -3 "$C/err.txt")"
L=$(row last); [ -n "$L" ] && [ "$L" -gt 1000 ] && ok || bad "R4 the completed pass did not stamp the row: '$L'"
[ "$(row alerted)" = - ] && [ "$(grep -c -- '--resolve --log-only --id main-red-full-pass-stale ' "$C/alerts.txt")" = 1 ] && ok \
  || bad "R4 want one resolve and a cleared marker row: '$(row alerted)' $(cat "$C/alerts.txt")"

# ── P1 (AT3): the pair lane reads every fleet repo by default ────────────────
PCI=".github/workflows/harness-ci.yml"
head_runs() { # head_runs <sha> <run-id> <created_at>
  jq -nc --arg p "$PCI" --arg t "$3" --argjson id "$2" '{workflow_runs:[{name:"Harness CI", path:$p,
    status:"completed", conclusion:"failure", created_at:$t,
    html_url:("https://github.com/x/y/actions/runs/"+($id|tostring)), id:$id}]}' > "$C/runs-$1.json"
}
pulls() { # pulls <slug> <num:sha:updated>...
  local slug="$1" out='[' first=1 spec num sha upd; shift
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" --arg s "$slug" \
      '{number:$n, html_url:("https://github.com/"+$s+"/pull/"+($n|tostring)),
        title:"t", body:"", head:{sha:$sha, ref:("b"+($n|tostring))},
        base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null, labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$C/pulls-$(printf '%s' "$slug" | tr '/' '-').json"
}
pulls_asked() { grep -o 'repos/[^/ ]*/[^/ ]*/pulls' "$C/gh.txt" | sed 's#^repos/##; s#/pulls$##' | sort -u | tr '\n' ' '; }
new_case
printf '# a comment row\nmk x\ndemo y\n' > "$C/fleet.conf"
pulls example-org/project-6 "11:aaaa111:2026-11-08T10:05:00Z" "12:bbbb222:2026-11-08T10:06:00Z"
head_runs aaaa111 9001 2026-11-08T10:00:00Z; head_runs bbbb222 9002 2026-11-08T10:10:00Z
printf 'decisions\t8001\n' > "$C/jobs-9001.txt"; printf 'decisions\t8002\n' > "$C/jobs-9002.txt"
echo "2026-11-08T10:01:02Z FAIL: the date fixture expired" > "$C/joblog-8001.txt"
echo "2026-11-08T10:11:02Z FAIL: the date fixture expired" > "$C/joblog-8002.txt"
drive_pair
[ "$(pulls_asked)" = "example-org/cromford example-org/demo-os example-org/project-6 " ] && ok \
  || bad "P1 want all 3 fleet repos read, got: $(pulls_asked)"
grep -q -- '--id main-red-prs:example-org-project-6:' "$C/alerts.txt" && ok \
  || bad "P1 no pair alert for example-org/project-6: $(cat "$C/alerts.txt") / $(tail -5 "$C/logs/main-red-pr-pair.log")"
grep -q 'repos: 3 (from fleet.conf)' "$C/logs/main-red-pr-pair.log" && ok \
  || bad "P1 no 'repos: 3 (from fleet.conf)' line: $(cat "$C/logs/main-red-pr-pair.log")"

# ── P2 (AT4): a hand-set MAIN_RED_PAIR_REPOS wins ────────────────────────────
new_case
printf 'mk x\ndemo y\n' > "$C/fleet.conf"
PAIRS=example-org/only
drive_pair
[ "$(pulls_asked)" = "example-org/only " ] && ok || bad "P2 the hand-set list did not win: $(pulls_asked)"
grep -q 'repos: 1 (from env)' "$C/logs/main-red-pr-pair.log" && ok || bad "P2 no 'repos: 1 (from env)' line"

# ── P3: no fleet.conf, env unset: $HARNESS_REPO only ─────────────────────────
new_case
drive_pair
[ "$(pulls_asked)" = "example-org/cromford " ] && ok || bad "P3 want only \$HARNESS_REPO read: $(pulls_asked)"

# ── P4: repo arguments win over the env and fleet.conf ───────────────────────
new_case
printf 'mk x\ndemo y\n' > "$C/fleet.conf"
PAIRS=example-org/only
drive_pair example-org/argrepo
[ "$(pulls_asked)" = "example-org/argrepo " ] && ok || bad "P4 the repo argument did not win: $(pulls_asked)"
grep -q 'repos: 1 (from args)' "$C/logs/main-red-pr-pair.log" && ok || bad "P4 no 'repos: 1 (from args)' line"

echo "main-red-detection.bh-9284: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
