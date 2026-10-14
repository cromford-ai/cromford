#!/bin/bash
# tests/main-red-tip-red-test.sh — the TIP arm of bin/main-red-detector.sh,
# driven for real against a fake gh, a scratch $HARNESS and a recording
# lane-alert.sh (BH-880 / BH-629.4).
#
#   THE SILENCE THIS KILLS (2026-09-17). The streak arm waits for
#   MAIN_RED_STREAK (2) red runs of one workflow, on a stream whose only
#   producer is a push to main — and in this harness a push to main is a merge.
#   So the second red run can only arrive from the very merge the red is meant
#   to prevent. #615 merged at 03:33Z, main went red on its FIRST run, and the
#   detector said "main green" for 7.5 hours while every open PR inherited the
#   red.
#
#   THE PROPERTY UNDER TEST: ONE red completed run of a required workflow, on
#   main's tip, aged past MAIN_RED_TIP_MIN_AGE_MIN, writes the flag and fires
#   exactly ONE critical alert naming the failing job — and every one of the
#   seven ways that shape can be faked (too young, not the tip, a skipped
#   workflow, a re-run in flight, an unreadable page, the knob off, an
#   unparseable timestamp) decides NOTHING. The arm gates a fleet-wide merge
#   freeze, so its negatives matter as much as its positive.
#
# Time is pinned to ONE clock read: every fixture timestamp is `ago <minutes>`
# from the single NOW below, so the suite cannot pick its own red day the way
# the incident in docs/TEST-DETERMINISM.md did.
# Run from anywhere: tests/main-red-tip-red-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

NOW=$(date +%s)                     # the ONLY clock read in this file
ago() { date -u -d "@$((NOW - $1 * 60))" +%FT%TZ; }

cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# lane-alert.sh, recording: the first field says whether --critical was asked for.
cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# gh shim. Visibility from $T/blind; runs from $T/runs.json ("" or absent = the
# API failed); the jobs read answers $JOBS_ANSWER.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id")   [ -f "$T/blind" ] && exit 1; exit 0 ;;
  # The -q read gets the joined names; a raw read (the BH-2165 infra check,
  # whose body names the job) gets the jobs JSON GitHub would send.
  *"/actions/runs/"*"/jobs"*" -q "*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"/actions/runs/"*"/jobs"*) jq -nc --arg n "${JOBS_ANSWER:-}" \
      '{total_count:(if $n=="" then 0 else 1 end), jobs:(if $n=="" then [] else [{name:$n, conclusion:"failure", run_attempt:1, steps:[{name:"tests/ suite", conclusion:"failure"}]}] end)}' ;;
  *"actions/runs"*)         [ -s "$T/runs.json" ] || exit 1
                            jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]' "$T/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

# runs <spec>... — spec: name|path|conclusion|created_at|sha[|status]
# id falls back to 0 for a created_at with no digits in it (the N7 fixture).
runs() {
  local out='{"workflow_runs":[' first=1 spec n p c t s sha
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" \
      --arg c "$c" --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end),
        created_at:$t, head_sha:$sha, html_url:$u,
        id:(($t|gsub("[^0-9]";"")) as $d | (if $d=="" then 0 else ($d|tonumber) end))}')
  done
  printf '%s]}' "$out" > "$T/runs.json"
}
drive() { # drive [args...] — one tick of the real detector
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" JOBS_ANSWER="${JOBS_ANSWER:-}"; unset GH_TOKEN
    bash "$T/bin/main-red-detector.sh" "$@" >/dev/null 2>"$T/err.txt" )
}
alerts()   { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
ghcount()  { awk -v p="$1" 'index($0,p){n++} END{print n+0}' "$T/gh.txt" 2>/dev/null; }
lastlog()  { awk '!/Z pass end: /{l=$0} END{print l}' "$T/logs/main-red.log" 2>/dev/null; }  # the last DECISION line: BH-6352's pass end: line closes every pass
FLAG="$T/flags/main-red-o-r"
CI=".github/workflows/harness-ci.yml"; E2E=".github/workflows/e2e.yml"
LINT=".github/workflows/lint.yml"
reset_all() { : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/logs/main-red.log"
              rm -f "$T"/flags/main-red-* "$T"/flags/alerted-repo-invisible-*; : > "$T/logs/ALERTS.log"; }

# ── R1 (REPRO) — ONE red run of a required workflow, on the tip, 40 minutes
#    old, nothing else in the page. This is the 2026-09-17 shape.
reset_all
JOBS_ANSWER="Pure-logic gate fixtures"
R1_AT=$(ago 40)
runs "Harness CI|$CI|failure|$R1_AT|f1f1f1f1"
drive o/r
[ -f "$FLAG" ] && ok || bad "R1: one red run on the tip must raise the flag (err=$(cat "$T/err.txt"))"
grep -q '^reason=tip$'      "$FLAG" && ok || bad "R1: the flag must say which arm fired: $(cat "$FLAG" 2>/dev/null)"
grep -q '^sha=f1f1f1f1$'    "$FLAG" && ok || bad "R1: the flag must carry the tip sha: $(cat "$FLAG" 2>/dev/null)"
grep -q "^job=Pure-logic gate fixtures$" "$FLAG" && ok || bad "R1: the flag must name the failing job: $(cat "$FLAG" 2>/dev/null)"
grep -q "^since=$R1_AT$"    "$FLAG" && ok || bad "R1: since must be that run's created_at: $(cat "$FLAG" 2>/dev/null)"
grep -q '^streak=1$'        "$FLAG" && ok || bad "R1: the streak is one run: $(cat "$FLAG" 2>/dev/null)"
[ "$(alerts)" = 1 ] && ok || bad "R1: expected exactly one alert: $(cat "$T/alerts.txt")"
grep -q '^--critical main-red o/r main is RED' "$T/alerts.txt" && ok || bad "R1: the alert must be critical and say main is RED: $(cat "$T/alerts.txt")"
grep -q 'job: Pure-logic gate fixtures' "$T/alerts.txt" && ok || bad "R1: the alert must name the failing job: $(cat "$T/alerts.txt")"
grep -q 'fix-main-red'      "$T/alerts.txt" && ok || bad "R1: the alert must say how to land a fix: $(cat "$T/alerts.txt")"
grep -q '1 runs in a row'   "$T/alerts.txt" && bad "R1: 'failed 1 runs in a row' is not English and not true of this arm: $(cat "$T/alerts.txt")" || ok
grep -q "main's tip"        "$T/alerts.txt" && ok || bad "R1: the alert must say the red is on main's tip: $(cat "$T/alerts.txt")"
# and it costs no API call of its own: the runs page it already read, the one
# re-read every NEW raise makes to confirm the page was not stale (BH-1927), and
# the one jobs read the streak arm also makes the tick a repo turns red.
[ "$(ghcount 'actions/runs -f branch=main')" = 2 ] && ok || bad "R1: expected exactly two runs reads (the page and the BH-1927 confirming re-read): $(cat "$T/gh.txt")"
[ "$(ghcount '/jobs')" = 1 ] && ok || bad "R1: expected exactly one jobs read: $(cat "$T/gh.txt")"

# ── R2 — same sha on the next tick: one log line, no second alert, flag
#    byte-identical. The flag is the dedupe.
BEFORE=$(cat "$FLAG"); : > "$T/alerts.txt"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(cat "$FLAG")" = "$BEFORE" ]; } && ok \
  || bad "R2: a still-red tip re-alerted or rewrote its flag: alerts=$(cat "$T/alerts.txt")"
grep -q '1 in a row' "$T/logs/main-red.log" && bad "R2: the still-red log line must not claim a streak of 1: $(lastlog)" || ok

# ── R3 — green again on a new sha: the flag goes, ONE resolve alert, not
#    critical, naming when it first broke.
: > "$T/alerts.txt"
runs "Harness CI|$CI|success|$(ago 10)|a2a2a2a2" \
     "Harness CI|$CI|failure|$R1_AT|f1f1f1f1"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "R3: a green main must clear the flag"
[ "$(alerts)" = 1 ] && ok || bad "R3: expected exactly one resolve alert: $(cat "$T/alerts.txt")"
# BH-2337: GREEN resolves the RED's condition and opens no row of its own.
grep -q '^--resolve --log-only main-red o/r main is GREEN again' "$T/alerts.txt" && ok || bad "R3: resolve alert wrong shape: $(cat "$T/alerts.txt")"
grep -q "red since $R1_AT" "$T/alerts.txt" && ok || bad "R3: the resolve must say how long it was red: $(cat "$T/alerts.txt")"

# ── R4 — a tip hit on a NEW sha while the flag is up: exactly one NON-critical
#    "still red" notice, the watermark moves, `since` does not.
reset_all
JOBS_ANSWER="Pure-logic gate fixtures"
R4_AT=$(ago 60)
runs "Harness CI|$CI|failure|$R4_AT|f1f1f1f1" \
     "Harness CI|$CI|success|$(ago 70)|d4d4d4d4"
drive o/r
{ [ -f "$FLAG" ] && [ "$(alerts)" = 1 ]; } && ok || bad "R4 setup: the first tip hit must flag and page once: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"
JOBS_ANSWER="Syntax + shellcheck + config integrity"
runs "Harness CI|$CI|failure|$(ago 30)|b3b3b3b3" \
     "Harness CI|$CI|success|$(ago 40)|c3c3c3c3"
drive o/r
[ "$(alerts)" = 1 ] && ok || bad "R4: a new red sha must raise exactly one line: $(cat "$T/alerts.txt")"
grep -q '^main-red o/r main is STILL RED on a new sha' "$T/alerts.txt" && ok || bad "R4: and it is the non-critical notice: $(cat "$T/alerts.txt")"
grep -q '^--critical' "$T/alerts.txt" && bad "R4: the episode already paged once — no second critical: $(cat "$T/alerts.txt")" || ok
grep -q '^sha=b3b3b3b3$'  "$FLAG" && ok || bad "R4: the watermark must move to the new sha: $(cat "$FLAG" 2>/dev/null)"
grep -q "^since=$R4_AT$"  "$FLAG" && ok || bad "R4: but since still says when main first broke: $(cat "$FLAG" 2>/dev/null)"
grep -q '^reason=tip$'    "$FLAG" && ok || bad "R4: and the arm that fired is still recorded: $(cat "$FLAG" 2>/dev/null)"

# ── N1 — younger than MAIN_RED_TIP_MIN_AGE_MIN: a re-run may still be coming.
reset_all
runs "Harness CI|$CI|failure|$(ago 5)|f1f1f1f1"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "N1: a red 5 minutes old must not freeze the fleet: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"
# the same fixture with the threshold lowered DOES fire — the knob is read, not decorative
reset_all
runs "Harness CI|$CI|failure|$(ago 5)|f1f1f1f1"
MAIN_RED_TIP_MIN_AGE_MIN=3 drive o/r
{ [ -f "$FLAG" ] && [ "$(alerts)" = 1 ]; } && ok \
  || bad "N1: MAIN_RED_TIP_MIN_AGE_MIN=3 must fire on a 5-minute-old red: alerts=$(cat "$T/alerts.txt")"

# ── N2 — red, aged, but NOT on the tip: a newer push exists and its required
#    run passed. The tip is green.
reset_all
runs "Harness CI|$CI|failure|$(ago 40)|aaaa0001" \
     "Lint|$LINT|success|$(ago 30)|bbbb0002"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "N2: a red on an older sha must not freeze: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"

# ── N3 — a MAIN_RED_SKIP_RE workflow (e2e/nightly/smoke/publish/deploy) red on
#    the tip is bin/pipeline-health.sh's perma-red business, never a freeze.
reset_all
runs "E2E Nightly|$E2E|failure|$(ago 40)|f1f1f1f1"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "N3: a nightly/e2e red must not freeze merges"

# ── N4 — a newer run of the SAME workflow that is not evidence
#    (in_progress / cancelled / skipped): somebody is re-running or intervening.
for KIND in in_progress cancelled skipped; do
  reset_all
  case "$KIND" in
    in_progress) runs "Harness CI|$CI|failure|$(ago 40)|5a5a5a5a" \
                      "Harness CI|$CI|null|$(ago 5)|5a5a5a5a|in_progress" ;;
    *)           runs "Harness CI|$CI|failure|$(ago 40)|5a5a5a5a" \
                      "Harness CI|$CI|$KIND|$(ago 5)|5a5a5a5a" ;;
  esac
  drive o/r
  { [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
    || bad "N4($KIND): a newer non-evidence run of the same workflow must hold the arm: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"
done

# ── N5 — we could not look. An unreadable page and an EMPTY page both decide
#    nothing, and neither clears a flag.
reset_all
{ echo "sha=f1f1f1f1"; echo "workflow=Harness CI"; echo "path=$CI"; echo "job=Pure-logic gate fixtures";
  echo "since=$(ago 40)"; echo "streak=1"; echo "run=https://github.com/o/r/actions/runs/1";
  echo "detected=2026-09-18 00:00:00Z"; echo "reason=tip"; } > "$FLAG"
BEFORE=$(cat "$FLAG")
rm -f "$T/runs.json"
drive o/r
{ [ "$(cat "$FLAG" 2>/dev/null)" = "$BEFORE" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "N5: an unreadable runs page changed the flag or alerted: $(cat "$T/alerts.txt")"
printf '%s' '{"workflow_runs":[]}' > "$T/runs.json"
drive o/r
{ [ "$(cat "$FLAG" 2>/dev/null)" = "$BEFORE" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "N5: an empty runs page changed the flag or alerted: $(cat "$T/alerts.txt")"

# ── N6 — MAIN_RED_TIP_RED=0 is the rollback switch: byte for byte the
#    pre-BH-629 decision on the R1 fixture, down to the log line.
reset_all
runs "Harness CI|$CI|failure|$(ago 40)|f1f1f1f1"
MAIN_RED_TIP_RED=0 drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "N6: MAIN_RED_TIP_RED=0 must disarm the arm: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"
case "$(lastlog)" in
  *"o/r: main green (0 required workflow(s))") ok ;;
  *) bad "N6: the disarmed decision must read exactly as it did before BH-629: $(lastlog)" ;;
esac

# ── N7 — an unparseable created_at disarms the arm. A malformed field must not
#    read as "infinitely old" and freeze a fleet.
reset_all
runs "Harness CI|$CI|failure|not-a-date|f1f1f1f1"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "N7: an unparseable created_at must decide nothing: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"

echo "main-red-tip-red: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
