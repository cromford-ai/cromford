#!/bin/bash
# tests/main-red-burst-backwalk.bh-1451-test.sh — the BURST BACK-WALK arm of
# bin/main-red-detector.sh, driven for real against a fake gh, a scratch
# $HARNESS and a recording lane-alert.sh (BH-1451).
#
#   THE BLINDNESS THIS KILLS (2026-09-22, 12:28-12:45Z). Main went red when
#   #1394 merged. The hub's merge lanes then merged FIVE more PRs onto that red
#   main while bin/main-red-detector.sh logged, every tick for 15+ minutes:
#   "no completed run of a REQUIRED workflow on main — nothing decided". During
#   a merge burst main advances every minute or two, so every run in the page is
#   still in_progress: the streak arm needs two completed reds and the tip arm
#   needs a completed red ON THE TIP, and a burst removes both kinds of evidence
#   from the page. The freeze the fleet has for exactly this case never engaged.
#
#   THE PROPERTY UNDER TEST: when the head's required runs are still in flight,
#   the detector walks BACK through the last MAIN_RED_BURST_DEPTH main shas and
#   decides from the newest COMPLETED required run it finds. A red there writes
#   the freeze — carrying the sha it JUDGED, the head it is behind and how far
#   behind — and pages exactly once. And every way that shape can be faked (the
#   newest completed run is green, nothing newer is actually pending, the only
#   newer run is a re-run of the same sha, a skip-listed workflow, an
#   unparseable timestamp, a red further back than the depth, the knob off)
#   decides NOTHING. The arm gates a fleet-wide merge freeze, so its negatives
#   carry as much weight as its positive.
#
# Time is pinned to ONE clock read: every fixture timestamp is `ago <minutes>`
# from the single NOW below, so this suite cannot pick its own red day the way
# the incident in docs/TEST-DETERMINISM.md did.
# Run from anywhere: tests/main-red-burst-backwalk.bh-1451-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A suite whose subject is absent must fail LOUD, never skip into green.
[ -f "$DIR/bin/main-red-detector.sh" ] || {
  echo "FAIL: bin/main-red-detector.sh does not exist — there is nothing to test"
  echo "main-red-burst-backwalk: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-burst-backwalk: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/main-red-gate.sh" "$T/bin/lib/"
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

# lane-alert.sh, recording: argv verbatim, so the first field says whether
# --critical was asked for.
cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# gh shim. Runs come from $T/runs.json ("" or absent = the API failed) and the
# page is SLICED at the per_page the caller asked for — that slice is the whole
# point of the deepen case (B6), where the completed red sits past the first
# page. The jobs read answers $JOBS_ANSWER.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)           [ -s "$T/runs.json" ] || exit 1
                              pp=${A##*per_page=}; pp=${pp%% *}
                              case "$pp" in ''|*[!0-9]*) pp=100 ;; esac
                              jq -c --argjson pp "$pp" \
                                '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion,
                                                       sha:.head_sha, t:.created_at, u:.html_url, id:.id}]
                                 | .[0:$pp]' "$T/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

NOW=$(date +%s)                     # the ONLY clock read in this file
ago() { date -u -d "@$((NOW - $1 * 60))" +%FT%TZ; }

# runs <spec>... — spec: name|path|conclusion|created_at|sha[|status]
# LIST THEM NEWEST FIRST: GitHub answers newest-first and the shim's per_page
# slice keeps that order, so the order here is the order a page would hold.
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
    bash "$T/bin/main-red-detector.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
ghcount() { awk -v p="$1" 'index($0,p){n++} END{print n+0}' "$T/gh.txt" 2>/dev/null; }
lastlog() { awk '!/Z pass end: /{l=$0} END{print l}' "$T/logs/main-red.log" 2>/dev/null; }  # the last DECISION line: BH-6352's pass end: line closes every pass
FLAG="$T/flags/main-red-o-r"
VERDICT="$T/state/main-red/o-r.verdict"
CI=".github/workflows/harness-ci.yml"; E2E=".github/workflows/e2e.yml"
LINT=".github/workflows/lint.yml"
reset_all() { : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/logs/main-red.log"
              rm -f "$T"/flags/main-red-* "$T"/flags/alerted-repo-invisible-*
              scratch_rm "$T/state/main-red"; : > "$T/logs/ALERTS.log"; }

# THE INCIDENT FIXTURE. Four main shas, newest first:
#   dddd0004  the tip, Harness CI still in_progress   (the merge that just landed)
#   cccc0003  Harness CI still in_progress            (the merge before it)
#   bbbb0002  Harness CI COMPLETED failure, 20m old   (the one that can decide)
#   aaaa0001  Harness CI success                      (main was fine before that)
burst_fixture() {
  runs "Harness CI|$CI|null|$(ago 2)|dddd0004|in_progress" \
       "Harness CI|$CI|null|$(ago 10)|cccc0003|in_progress" \
       "Harness CI|$CI|failure|$(ago 20)|bbbb0002" \
       "Harness CI|$CI|success|$(ago 40)|aaaa0001"
}

# ── B1 (REPRO) — the freeze engages, on the sha that decided ────────────────
reset_all
JOBS_ANSWER="Test determinism lint"
burst_fixture
drive o/r
[ -f "$FLAG" ] && ok || bad "B1: a completed red two shas behind a busy head must raise the freeze (last log: $(lastlog))"
grep -q '^reason=burst$'   "$FLAG" && ok || bad "B1: the flag must say which arm fired: $(cat "$FLAG" 2>/dev/null)"
grep -q '^sha=bbbb0002$'   "$FLAG" && ok || bad "B1: the flag must carry the sha it JUDGED, not the head: $(cat "$FLAG" 2>/dev/null)"
grep -q '^head=dddd0004$'  "$FLAG" && ok || bad "B1: the flag must carry the head it is behind: $(cat "$FLAG" 2>/dev/null)"
grep -q '^depth=2$'        "$FLAG" && ok || bad "B1: the flag must say how far behind the head it decided: $(cat "$FLAG" 2>/dev/null)"
grep -q '^job=Test determinism lint$' "$FLAG" && ok || bad "B1: the flag must name the failing job: $(cat "$FLAG" 2>/dev/null)"
[ "$(alerts)" = 1 ] && ok || bad "B1: expected exactly one alert: $(cat "$T/alerts.txt")"
grep -q '^--critical main-red o/r main is RED' "$T/alerts.txt" && ok \
  || bad "B1: the alert must be critical and say main is RED: $(cat "$T/alerts.txt")"
grep -q 'job: Test determinism lint' "$T/alerts.txt" && ok \
  || bad "B1: the alert must name the failing job: $(cat "$T/alerts.txt")"
grep -q 'fix-main-red' "$T/alerts.txt" && ok || bad "B1: the alert must say how to land a fix: $(cat "$T/alerts.txt")"
# and the verdict file the PR-pair lane reads says the detector HAS decided
grep -q '^decision=red$' "$VERDICT" && ok || bad "B1: the verdict file must say red: $(cat "$VERDICT" 2>/dev/null)"
grep -q '^reason=burst$' "$VERDICT" && ok || bad "B1: the verdict file must name the arm: $(cat "$VERDICT" 2>/dev/null)"

# ── B2 — the alert tells the truth about WHICH sha it judged ────────────────
grep -q 'bbbb0002' "$T/alerts.txt" && ok || bad "B2: the alert must name the deciding sha: $(cat "$T/alerts.txt")"
grep -q 'dddd0004' "$T/alerts.txt" && ok || bad "B2: the alert must name the head it is behind: $(cat "$T/alerts.txt")"
grep -q 'behind head' "$T/alerts.txt" && ok \
  || bad "B2: the alert must say the decision was made behind the head: $(cat "$T/alerts.txt")"
grep -q 'in flight' "$T/alerts.txt" && ok \
  || bad "B2: the alert must say the head's own runs are still in flight: $(cat "$T/alerts.txt")"
grep -q 'runs in a row' "$T/alerts.txt" && bad "B2: this is not the streak arm: $(cat "$T/alerts.txt")" || ok
grep -q "main's tip"   "$T/alerts.txt" && bad "B2: this is not the tip arm — the red is NOT on the tip: $(cat "$T/alerts.txt")" || ok
# "head bbbb0002" would be the old copy, and it is false on this arm
grep -q 'head bbbb0002' "$T/alerts.txt" && bad "B2: bbbb0002 is not the head: $(cat "$T/alerts.txt")" || ok

# ── B3 — the log says which sha decided ─────────────────────────────────────
grep -q 'bbbb0002' "$T/logs/main-red.log" && ok \
  || bad "B3: the log must name the deciding sha: $(cat "$T/logs/main-red.log")"
grep -q 'dddd0004' "$T/logs/main-red.log" && ok \
  || bad "B3: the log must name the head it decided behind: $(cat "$T/logs/main-red.log")"

# ── B4 — the depth is a NUMBER AN OPERATOR MOVES, not a constant ────────────
#    the same completed red, seven shas behind the head: past MAIN_RED_BURST_DEPTH (5).
deep_fixture() {
  runs "Harness CI|$CI|null|$(ago 1)|s1s10001|in_progress" \
       "Harness CI|$CI|null|$(ago 2)|s2s20002|in_progress" \
       "Harness CI|$CI|null|$(ago 3)|s3s30003|in_progress" \
       "Harness CI|$CI|null|$(ago 4)|s4s40004|in_progress" \
       "Harness CI|$CI|null|$(ago 5)|s5s50005|in_progress" \
       "Harness CI|$CI|null|$(ago 6)|s6s60006|in_progress" \
       "Harness CI|$CI|failure|$(ago 20)|s7s70007" \
       "Harness CI|$CI|success|$(ago 40)|s8s80008"
}
reset_all
deep_fixture
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B4: a red 6 shas behind the head is past the default depth: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"
reset_all
deep_fixture
MAIN_RED_BURST_DEPTH=8 drive o/r
{ [ -f "$FLAG" ] && [ "$(alerts)" = 1 ]; } && ok \
  || bad "B4: MAIN_RED_BURST_DEPTH=8 must reach it — the knob is read, not decorative: $(cat "$T/alerts.txt")"
grep -q '^depth=6$' "$FLAG" && ok || bad "B4: and the flag records how far back it went: $(cat "$FLAG" 2>/dev/null)"

# ── B5 — MAIN_RED_BURST_BACKWALK=0 is the rollback switch ───────────────────
#    byte for byte the pre-BH-1451 decision on the B1 fixture — which is how
#    alarming the blindness was: the detector called a red main GREEN.
reset_all
burst_fixture
MAIN_RED_BURST_BACKWALK=0 drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B5: MAIN_RED_BURST_BACKWALK=0 must disarm the arm: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"
case "$(lastlog)" in
  *"o/r: main green (0 required workflow(s))") ok ;;
  *) bad "B5: the disarmed decision must read exactly as it did before BH-1451: $(lastlog)" ;;
esac

# ── B6 — the deepen: the completed red is past the first page ───────────────
#    THE INCIDENT'S OWN SHAPE. Twenty runs on main, every one of them still in
#    flight, and the run that can decide is on page two.
reset_all
JOBS_ANSWER="Test determinism lint"
runs "Harness CI|$CI|null|$(ago 1)|dddd0004|in_progress" \
     "Lint|$LINT|null|$(ago 2)|dddd0004|in_progress" \
     "Harness CI|$CI|null|$(ago 3)|cccc0003|in_progress" \
     "Lint|$LINT|null|$(ago 4)|cccc0003|in_progress" \
     "Harness CI|$CI|null|$(ago 5)|eeee0005|in_progress" \
     "Harness CI|$CI|failure|$(ago 20)|bbbb0002" \
     "Harness CI|$CI|success|$(ago 40)|aaaa0001"
MAIN_RED_PER_PAGE=5 drive o/r
[ -f "$FLAG" ] && ok || bad "B6: a page of nothing but in-flight runs must be re-read deeper (last log: $(lastlog))"
grep -q '^sha=bbbb0002$' "$FLAG" && ok || bad "B6: and decided on the completed red it found: $(cat "$FLAG" 2>/dev/null)"
grep -q '^depth=3$'      "$FLAG" && ok || bad "B6: three distinct shas newer than the one that decided: $(cat "$FLAG" 2>/dev/null)"
[ "$(ghcount 'actions/runs -f branch=main')" = 3 ] && ok \
  || bad "B6: expected exactly three runs reads (the page, the deeper one, then the BH-1927 re-read confirming the raise): $(cat "$T/gh.txt")"
#    and a page with no PENDING required run is never re-read: nothing newer is
#    coming, so a second read would buy nothing. (The N3 shape: an e2e-only page.)
reset_all
runs "E2E Nightly|$E2E|failure|$(ago 40)|f1f1f1f1"
drive o/r
[ "$(ghcount 'actions/runs -f branch=main')" = 1 ] && ok \
  || bad "B6: a page with nothing pending must not be re-read: $(cat "$T/gh.txt")"
case "$(lastlog)" in
  *"no completed run of a REQUIRED workflow on main"*) ok ;;
  *) bad "B6: and it still decides nothing, in the same words: $(lastlog)" ;;
esac
grep -q '^decision=none$'      "$VERDICT" && ok || bad "B6: the verdict file must say none: $(cat "$VERDICT" 2>/dev/null)"
grep -q '^reason=no-required$' "$VERDICT" && ok || bad "B6: and why: $(cat "$VERDICT" 2>/dev/null)"

# ── B7 — the flag we raise is the one the MERGE LANES read ──────────────────
#    Not a lookalike: bin/lib/main-red-gate.sh's own answer, against this tree.
reset_all
JOBS_ANSWER="Test determinism lint"
burst_fixture
drive o/r
NAME=$( export HARNESS="$T"; . "$T/bin/lib/main-red-gate.sh"; main_red_flag "" o/r )
[ "$NAME" = "main-red-o-r" ] && [ -f "$T/flags/$NAME" ] && ok \
  || bad "B7: the gate every merge lane reads does not see this freeze: got '$NAME'"

# ── B8 — the negatives, each one a way the shape can be faked ───────────────
# B8a: the newest COMPLETED required run two shas back is GREEN. This arm has no
#      green side: a green that predates two pushes is no claim about the head.
reset_all
runs "Harness CI|$CI|null|$(ago 2)|dddd0004|in_progress" \
     "Harness CI|$CI|null|$(ago 10)|cccc0003|in_progress" \
     "Harness CI|$CI|success|$(ago 20)|bbbb0002"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B8a: a green newest-completed run must decide nothing: $(cat "$T/alerts.txt")"

# B8b: the N2 shape — a red behind the head, but every NEWER sha has COMPLETED
#      required runs. Nothing is in flight, so the tip is simply green.
reset_all
runs "Lint|$LINT|success|$(ago 10)|cccc0003" \
     "Harness CI|$CI|failure|$(ago 20)|bbbb0002"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B8b: nothing pending on a newer sha means this arm must not fire: $(cat "$T/alerts.txt")"

# B8c: the N4 shape — the only newer run is on the SAME sha. That is a re-run in
#      flight, and the tip arm's wait is what keeps a flake from freezing a fleet.
reset_all
runs "Harness CI|$CI|null|$(ago 5)|5a5a5a5a|in_progress" \
     "Harness CI|$CI|failure|$(ago 40)|5a5a5a5a"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B8c: a re-run in flight on the SAME sha must not fire the burst arm: $(cat "$T/alerts.txt")"

# B8d: the red is a skip-listed workflow — bin/pipeline-health.sh's perma-red
#      business, never a merge freeze, however deep the walk goes.
reset_all
runs "Harness CI|$CI|null|$(ago 2)|dddd0004|in_progress" \
     "Harness CI|$CI|null|$(ago 10)|cccc0003|in_progress" \
     "E2E Nightly|$E2E|failure|$(ago 20)|bbbb0002"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B8d: a nightly/e2e red must never freeze merges: $(cat "$T/alerts.txt")"

# B8e: an unparseable created_at on the deciding run. A malformed field must not
#      read as evidence — the run is otherwise a perfect burst hit, and the
#      truncated stamp still SORTS where a 20-minute-old run belongs, so the
#      timestamp guard is the only thing standing between it and a fleet freeze.
reset_all
runs "Harness CI|$CI|null|$(ago 2)|dddd0004|in_progress" \
     "Harness CI|$CI|null|$(ago 10)|cccc0003|in_progress" \
     "Harness CI|$CI|failure|$(ago 20 | sed 's/Z$//')|bbbb0002"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B8e: an unparseable created_at must decide nothing: $(cat "$T/alerts.txt")"

# B8f: --explain on the B1 fixture. READ-ONLY means read-only: no flag, no
#      verdict file, not even the state dir they live in.
reset_all
JOBS_ANSWER="Test determinism lint"
burst_fixture
drive --explain o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ] && [ ! -d "$T/state/main-red" ]; } && ok \
  || bad "B8f: --explain wrote something: flag=$([ -f "$FLAG" ] && echo yes) state=$(ls "$T/state/main-red" 2>/dev/null)"
grep -q 'WOULD WRITE main-red-o-r' "$T/out.txt" && ok \
  || bad "B8f: --explain must say what it would have written: $(cat "$T/out.txt")"
grep -q 'reason=burst' "$T/out.txt" && ok \
  || bad "B8f: and which arm would have fired: $(cat "$T/out.txt")"

# ── B9 — idempotence, and the one thing that IS new information ─────────────
reset_all
JOBS_ANSWER="Test determinism lint"
burst_fixture
drive o/r
[ -f "$FLAG" ] || bad "B9 setup: the first tick must raise the freeze"
BEFORE=$(cat "$FLAG" 2>/dev/null); : > "$T/alerts.txt"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(cat "$FLAG" 2>/dev/null)" = "$BEFORE" ]; } && ok \
  || bad "B9: a second tick on the same fixture re-alerted or rewrote the flag: $(cat "$T/alerts.txt")"
# the red moves forward one sha while the head is still busy: somebody pushed and
# it did not fix this. ONE non-critical line, and the watermark moves.
: > "$T/alerts.txt"
JOBS_ANSWER="Syntax + shellcheck + config integrity"
runs "Harness CI|$CI|null|$(ago 1)|dddd0004|in_progress" \
     "Harness CI|$CI|failure|$(ago 8)|cccc0003" \
     "Harness CI|$CI|success|$(ago 20)|bbbb0002"
drive o/r
[ "$(alerts)" = 1 ] && ok || bad "B9: a new red sha must raise exactly one line: $(cat "$T/alerts.txt")"
grep -q '^main-red o/r main is STILL RED on a new sha' "$T/alerts.txt" && ok \
  || bad "B9: and it is the non-critical notice: $(cat "$T/alerts.txt")"
grep -q '^--critical' "$T/alerts.txt" && bad "B9: the episode already paged once: $(cat "$T/alerts.txt")" || ok
grep -q '^sha=cccc0003$' "$FLAG" && ok || bad "B9: the watermark must move: $(cat "$FLAG" 2>/dev/null)"
grep -q '^depth=1$'      "$FLAG" && ok || bad "B9: and say how far behind the head it now is: $(cat "$FLAG" 2>/dev/null)"

# ── B10 — we could not look. An unreadable page decides nothing and clears
#    nothing, on this arm as on every other.
reset_all
{ echo "sha=bbbb0002"; echo "workflow=Harness CI"; echo "path=$CI"; echo "job=Test determinism lint";
  echo "since=$(ago 20)"; echo "streak=1"; echo "run=https://github.com/o/r/actions/runs/1";
  echo "detected=2026-09-22 12:40:00Z"; echo "reason=burst"; echo "head=dddd0004"; echo "depth=2"; } > "$FLAG"
BEFORE=$(cat "$FLAG")
rm -f "$T/runs.json"
drive o/r
{ [ "$(cat "$FLAG" 2>/dev/null)" = "$BEFORE" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B10: an unreadable runs page changed the flag or alerted: $(cat "$T/alerts.txt")"
grep -q '^reason=no-runs$' "$VERDICT" && ok \
  || bad "B10: and the verdict file says we could not look: $(cat "$VERDICT" 2>/dev/null)"

# ── B11 — THE HOLD WINS OVER THIS ARM (BH-1281 x BH-1451) ──────────────────
#    Two completed reds of the required workflow with the fix's own run in
#    flight one sha up: bin/batch-resolve.sh lifted the freeze the moment that
#    fix merged green, so there is no flag on disk, and the streak arm HOLDS
#    rather than raising on evidence a re-test is about to replace (BH-1281).
#    Every precondition this arm reads is also true there — a completed red one
#    sha behind a head whose required run has not finished — so without the
#    gate the hold is dead code for every re-test, and the freeze comes back
#    through this arm with a fresh mtime, which is the lower bound the lift
#    reads. A held tick raises nothing, pages nothing, and says so.
reset_all
JOBS_ANSWER="Test determinism lint"
runs "Harness CI|$CI|null|$(ago 2)|f1x00001|in_progress" \
     "Harness CI|$CI|failure|$(ago 20)|aaaa1111" \
     "Harness CI|$CI|failure|$(ago 30)|cccc3333" \
     "Harness CI|$CI|success|$(ago 60)|dddd4444"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "B11: a streak held for a re-test must not be frozen by the burst arm: $(cat "$T/alerts.txt")"
grep -q 'a re-test is under way' "$T/logs/main-red.log" && ok \
  || bad "B11: and the tick must say why nothing went up: $(cat "$T/logs/main-red.log")"
grep -q 'burst back-walk decided' "$T/logs/main-red.log" \
  && bad "B11: the burst arm decided on a held streak: $(cat "$T/logs/main-red.log")" || ok
# A HELD TICK IS A LOOK, and the verdict file is the only place another lane can
# read that. `none` there is what bin/main-red-pr-pair.sh reads as "the detector
# never looked" — it would then raise its own sha-less freeze during the
# re-test, and the next detector tick would take that flag over with a
# --critical page. The same defect, one lane further out.
grep -q '^decision=held$' "$VERDICT" && ok \
  || bad "B11: a held tick must record that it LOOKED: $(cat "$VERDICT" 2>/dev/null || echo '(no file)')"
grep -q '^sha=f1x00001$' "$VERDICT" && ok \
  || bad "B11: and name the re-test it is waiting on: $(cat "$VERDICT" 2>/dev/null)"

echo "main-red-burst-backwalk: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
