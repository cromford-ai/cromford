#!/bin/bash
# tests/main-red-flagged-recheck.bh-6502-test.sh — BH-6502: a repo with a
# main-red freeze up is re-checked every 5 minutes, not once an hour.
#
#   THE INCIDENT (2026-10-13). bin/main-red-detector.sh ran only inside the
#   merge conductor's full tick, and that tick runs once an hour
#   (CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR, BH-5521). example-org/project-6 went
#   green and its freeze stayed up until an operator ran the detector by hand.
#
#   THE PROPERTY UNDER TEST. One bin/main-red-recheck.sh run clears a flagged
#   repo whose required run is green again (C1), reads no unflagged repo and
#   logs its read count (C2), and reads nothing at all with no freeze up (C2b,
#   C2c). A repo still red on the same sha keeps its flag and sends no alert
#   (C3). The cadence is the settings row, default 5, 0 = off, bad = 5 (C4-C4d).
#   The lane switch stops it (C5). `--flagged-only` keeps only flagged slugs in
#   list order (C6, C6b). The hourly pass is unchanged (C7).
#
# Both scripts run with their real lib closure. Only lane-alert.sh,
# jobs-client.sh (flag_set recorder, ledger over a dir, /api/settings from
# $ROWS) and gh are stubs. Every page timestamp is a literal. Run from
# anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
  echo "main-red-flagged-recheck.bh-6502-test: SKIPPED — jq/python3/flock is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin" "$T/pages" "$T/ledger" "$T/catalog"
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# The coordination-DB client: flag_set is a recorder, the two ledger verbs keep
# the bin/lib/jobs/jobs.sh contract over one file per row, and /api/settings
# answers the rows in $ROWS (key=value, one per line).
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/' '-')"; }
job_ledger_get() {
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2
  cat "$f"; return 0
}
job_ledger_put() { printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0; }
_jobs_req() {
  case "$2" in
    /api/settings)
      local out="[]" kv IFS=$'\n'
      for kv in ${ROWS:-}; do
        out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "$out" ;;
    *) return 1 ;;
  esac
}
SHIM

# gh shim. A runs read serves $T/pages/<owner>-<repo>.json through the
# detector's OWN -q expression, so the projection is never hand copied. No
# page file = no runs. Every call is recorded in $GH_SINK.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/runs/"*) echo "" ;;
  *"actions/runs"*)
    slug=""; q=""; prev=""
    for a in "$@"; do
      case "$a" in repos/*/actions/runs) slug=${a#repos/}; slug=${slug%/actions/runs} ;; esac
      [ "$prev" = -q ] && q="$a"; prev="$a"
    done
    f="$T/pages/$(printf '%s' "$slug" | tr '/' '-').json"
    [ -s "$f" ] || exit 0
    if [ -n "$q" ]; then jq -c "$q" "$f"; else cat "$f"; fi ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

# The real lib closures; the stubs above were written first, so they stay.
scratch_install_closure bin/main-red-recheck.sh "$T" >/dev/null || bad "setup: recheck closure install failed"
scratch_install_closure bin/main-red-detector.sh "$T" >/dev/null || bad "setup: detector closure install failed"
# The rendered registry, so the settings row round-trips through the lane's knob.
cp "$(rendered_registry)" "$T/catalog/lanes.json" || bad "setup: no rendered registry"

CI=".github/workflows/ci.yml"
page() { # page <slug> <total_count> <id|conclusion|created_at|updated_at|sha|attempt>...
  local slug="$1" total="$2" out='[' first=1 spec id c t u sha a; shift 2
  for spec in "$@"; do
    IFS='|' read -r id c t u sha a <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg slug "$slug" --arg id "$id" --arg c "$c" --arg t "$t" --arg u "$u" \
      --arg sha "$sha" --arg a "$a" --arg p "$CI" '
      {id:($id|tonumber), name:"ci", path:$p, status:"completed",
       conclusion:(if $c=="null" then null else $c end), head_sha:$sha, event:"push",
       created_at:$t, updated_at:$u, run_attempt:($a|tonumber),
       html_url:("https://github.com/" + $slug + "/actions/runs/" + $id)}')
  done
  jq -nc --argjson r "$out]" --argjson tc "$total" '{total_count:$tc, workflow_runs:$r}' \
    > "$T/pages/$(printf '%s' "$slug" | tr '/' '-').json"
}
one_green() { page "$1" 1 "100|success|2026-10-12T20:00:00Z|2026-10-12T20:10:00Z|green0001|1"; }
# R: a re-run (attempt 2) with the SAME created_at as the floor.
RSHA=94413268a1b2c3d4e5f60718293a4b5c6d7e8f90
r_page() { # r_page <slug> <conclusion of R>
  page "$1" 64 \
    "38322322575|$2|2026-10-13T15:26:00Z|2026-10-13T16:20:00Z|$RSHA|2" \
    "38322235694|success|2026-10-13T15:00:00Z|2026-10-13T15:10:00Z|green0003|1" \
    "38318317991|success|2026-10-13T14:00:00Z|2026-10-13T14:10:00Z|green0002|1"
}
flag() { # flag <slug> — the body the raise tick left
  printf 'sha=%s\nworkflow=ci\npath=%s\nreason=tip\nrun=https://github.com/%s/actions/runs/38322322575\n' \
    "$RSHA" "$CI" "$1" > "$T/flags/main-red-$(printf '%s' "$1" | tr '/' '-')"
}
floor() { # floor <slug> <total> <newest>
  printf 'total=%s newest=%s' "$2" "$3" > "$T/ledger/main_red_runs__$(printf '%s' "$1" | tr '/' '-')"
}
STAMPF="$T/state/main-red/recheck.last"
stamp_ago() { mkdir -p "$T/state/main-red"; echo "$(( $(date +%s) - $1 ))" > "$STAMPF"; }

_env() { # the env both drivers share
  export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
         ALERT_SINK="$T/alerts.txt" PUBLISH_SINK="$T/publish.txt" LEDGER_DIR="$T/ledger" \
         MAIN_RED_QUEUE=0 HARNESS_REPO=o/harness MAIN_RED_REPOS="${REPOS:-}" \
         FLEET_CONF="$T/fleet.conf" ROWS="${ROWS:-}"
  unset REGISTRY_SOURCE GH_TOKEN LANE_START_SPREAD_S
  [ -n "$MAIN_RED_REPOS" ] || unset MAIN_RED_REPOS
  if [ -n "${MIN:-}" ]; then export MAIN_RED_RECHECK_MIN="$MIN"; else unset MAIN_RED_RECHECK_MIN; fi
}
DRC=0
drive_recheck() { ( _env; bash "$T/bin/main-red-recheck.sh" >"$T/out.txt" 2>"$T/err.txt" ); DRC=$?; }
drive_detector() { ( _env; bash "$T/bin/main-red-detector.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" ); DRC=$?; }
mrlog()   { cat "$T/logs/main-red.log" 2>/dev/null; }
cnt()     { grep -cE -- "$1" "$T/logs/main-red.log" 2>/dev/null | tr -d ' '; }
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
ghn()     { grep -cF -- "$1" "$T/gh.txt" 2>/dev/null | tr -d ' '; }
gh_empty() { [ ! -s "$T/gh.txt" ]; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"; : > "$T/gh.txt"
  rm -f "$T"/flags/* "$T"/locks/* "$T"/ledger/* "$T"/pages/*.json "$T/fleet.conf" "$T/state/settings-cache.json"
  scratch_rm "$T/state/main-red"; scratch_rm "$T/state/lane-gate"
  REPOS=""; ROWS=""; MIN=""
}
c1_tree() { # the C1 tree: o/r flagged and green again, a/one green and unflagged
  reset_case; REPOS="a/one o/r"; flag o/r; floor o/r 64 2026-10-13T15:26:00Z
  r_page o/r success; one_green a/one
}

# ── C1 (ticket A1): one recheck run clears a flagged repo that is green again ─
c1_tree
drive_recheck
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "C1 flag is still up after one recheck run (rc $DRC):
$(mrlog)
$(cat "$T/err.txt" 2>/dev/null)"
grep -q '^main-red-o-r off' "$T/publish.txt" && ok || bad "C1 no off publish: $(cat "$T/publish.txt")"
[ "$(alerts)" = 1 ] && grep -q 'GREEN again' "$T/alerts.txt" && ok || bad "C1 want 1 GREEN alert, got: $(cat "$T/alerts.txt")"
grep -qx 'decision=green' "$T/state/main-red/o-r.verdict" 2>/dev/null && ok || bad "C1 verdict is not green"
[ -s "$STAMPF" ] && ok || bad "C1 no recheck stamp written"

# ── C2 (ticket A2): the same run reads no unflagged repo and logs its count ──
[ "$(ghn 'repos/a/one/')" = 0 ] && ok || bad "C2 the unflagged a/one was read: $(cat "$T/gh.txt")"
[ "$(ghn 'repos/o/r/actions/runs')" -ge 1 ] && ok || bad "C2 o/r was not read"
[ "$(cnt 'recheck: 1 flagged repo\(s\), 1 Actions read\(s\)$')" = 1 ] && ok || bad "C2 want 1 recheck count line:
$(mrlog)"
[ "$(cnt 'pass start: recheck, 1 flagged repo\(s\): o/r$')" = 1 ] && ok || bad "C2 want 1 recheck pass start line"

# ── C2b: no freeze flag at all: no read, no detector, no stamp ───────────────
reset_case; REPOS="a/one o/r"; r_page o/r success; one_green a/one
drive_recheck
gh_empty && ok || bad "C2b a GitHub call with no flag up: $(cat "$T/gh.txt")"
[ "$(cnt 'pass start:|recheck:')" = 0 ] && ok || bad "C2b the detector started with no flag up"
[ ! -e "$STAMPF" ] && ok || bad "C2b a stamp with no flag up"
[ "$DRC" = 0 ] && ok || bad "C2b want rc 0, got $DRC"

# ── C2c: a switch file is not a freeze ───────────────────────────────────────
reset_case; REPOS="a/one o/r"; r_page o/r success; one_green a/one
: > "$T/flags/main-red-pr-pair-off"
drive_recheck
gh_empty && ok || bad "C2c a GitHub call with only a switch file: $(cat "$T/gh.txt")"
[ "$(cnt 'pass start:')" = 0 ] && ok || bad "C2c the detector started on a switch file"
[ ! -e "$STAMPF" ] && ok || bad "C2c a stamp on a switch file"

# ── C3 (ticket A3): still red on the same sha: flag stays, no alert, twice ───
reset_case; REPOS="a/one o/r"; flag o/r; floor o/r 64 2026-10-13T15:26:00Z
r_page o/r failure; one_green a/one
drive_recheck
grep -qx "sha=$RSHA" "$T/flags/main-red-o-r" 2>/dev/null && ok || bad "C3 the flag left R's sha"
[ "$(alerts)" = 0 ] && ok || bad "C3 an alert on a still-red repo: $(cat "$T/alerts.txt")"
[ "$(cnt 'o/r: still red')" = 1 ] && ok || bad "C3 want 1 still-red line:
$(mrlog)"
rm -f "$STAMPF"
drive_recheck
[ "$(alerts)" = 0 ] && ok || bad "C3 a second run alerted: $(cat "$T/alerts.txt")"
[ "$(cnt 'o/r: still red')" = 2 ] && ok || bad "C3 the second run did not judge o/r"
[ -e "$T/flags/main-red-o-r" ] && ok || bad "C3 the second run cleared the flag"

# ── C4: the settings row sets the cadence (10 min) ───────────────────────────
c1_tree; ROWS="lane.main-red-recheck.main_red_recheck_min=10"; stamp_ago 300
drive_recheck
gh_empty && ok || bad "C4 a run at 5 min under a 10-min row: $(cat "$T/gh.txt")"
[ -e "$T/flags/main-red-o-r" ] && ok || bad "C4 the flag cleared too soon"
stamp_ago 600
drive_recheck
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "C4 no run at 10 min under a 10-min row"

# ── C4b: no row, no env: the default 5 (with 30 s cron jitter slack) ─────────
c1_tree; stamp_ago 200
drive_recheck
gh_empty && ok || bad "C4b a run at 200 s under the default 5 min"
[ -e "$T/flags/main-red-o-r" ] && ok || bad "C4b the flag cleared at 200 s"
stamp_ago 280
drive_recheck
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "C4b no run at 280 s under the default 5 min"

# ── C4c: 0 is off ─────────────────────────────────────────────────────────────
c1_tree; MIN=0
drive_recheck
gh_empty && ok || bad "C4c a run with the knob at 0"
[ ! -e "$STAMPF" ] && ok || bad "C4c a stamp with the knob at 0"
[ -e "$T/flags/main-red-o-r" ] && ok || bad "C4c the flag cleared with the knob at 0"

# ── C4d: a value that is not a whole number is read as 5 ─────────────────────
c1_tree; MIN=abc; stamp_ago 280
drive_recheck
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "C4d a bad value did not run as 5"
c1_tree; MIN=abc; stamp_ago 200
drive_recheck
gh_empty && ok || bad "C4d a bad value ran at 200 s"

# ── C5: the lane switch stops it ──────────────────────────────────────────────
c1_tree; : > "$T/flags/lane-off-main-red-recheck"
drive_recheck
gh_empty && ok || bad "C5 a GitHub call with the lane off"
[ ! -e "$STAMPF" ] && ok || bad "C5 a stamp with the lane off"
[ -e "$T/flags/main-red-o-r" ] && ok || bad "C5 the flag cleared with the lane off"

# ── C6: --flagged-only reads only flagged slugs, in list order ───────────────
reset_case; REPOS="a/one b/two o/r"; flag b/two; flag o/r
one_green a/one; one_green b/two; one_green o/r
drive_detector --flagged-only
reads=$(grep -o 'repos/[^ ]*/actions/runs' "$T/gh.txt" 2>/dev/null | tr '\n' ' ')
[ "$reads" = "repos/b/two/actions/runs repos/o/r/actions/runs " ] && ok || bad "C6 want b/two then o/r, got: $reads"
[ "$(cnt 'pass start: recheck, 2 flagged repo\(s\): b/two o/r$')" = 1 ] && ok || bad "C6 no recheck pass start line:
$(mrlog)"
[ "$(cnt 'recheck: 2 flagged repo\(s\), 2 Actions read\(s\)$')" = 1 ] && ok || bad "C6 want 2 reads counted"
[ "$(cnt 'pass end: decided 2 of 2 repo\(s\) in [0-9]+s, exit 0, signal none, last repo o/r$')" = 1 ] && ok \
  || bad "C6 the pass end line changed shape"
[ "$(cnt 'not-in-repo-list')" = 0 ] && ok || bad "C6 a stray-flag line in a recheck"

# ── C6b: a stray flag alone reads nothing ────────────────────────────────────
reset_case; REPOS="a/one o/r"; one_green a/one; one_green o/r
printf 'sha=x\n' > "$T/flags/main-red-x-gone"
drive_detector --flagged-only
[ "$DRC" = 0 ] && ok || bad "C6b want rc 0, got $DRC"
gh_empty && ok || bad "C6b a GitHub call for a stray flag: $(cat "$T/gh.txt")"
[ "$(cnt 'pass start:|recheck:|not-in-repo-list')" = 0 ] && ok || bad "C6b a pass line for a stray flag:
$(mrlog)"

# ── C7: the hourly pass (no flag) still reads every repo, no recheck line ────
c1_tree
drive_detector
[ "$(ghn 'repos/a/one/actions/runs')" -ge 1 ] && [ "$(ghn 'repos/o/r/actions/runs')" -ge 1 ] && ok \
  || bad "C7 the full pass skipped a repo: $(cat "$T/gh.txt")"
[ "$(cnt 'recheck')" = 0 ] && ok || bad "C7 a recheck line in the full pass"
[ "$(cnt 'pass start: 2 repo\(s\), 1 with a flag up, decided first: o/r$')" = 1 ] && ok || bad "C7 the pass start line changed"

echo "main-red-flagged-recheck.bh-6502-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
