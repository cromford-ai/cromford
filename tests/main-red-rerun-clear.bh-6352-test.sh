#!/bin/bash
# tests/main-red-rerun-clear.bh-6352-test.sh — BH-6352: a scheduled main-red
# pass decides the repos with a freeze up FIRST, and says
# `decision=none reason=<why>` for every flagged repo it does not decide.
#
#   THE INCIDENT (2026-10-13). The freeze on example-org/project-6 stayed up 39
#   minutes after a re-run of run 38322322575 turned main green. The scheduled
#   pass judged the 13 repos in fleet.conf order, and project-6 is the last
#   one. The pass logged repo 6 and then ended without deciding repos 7-13, and
#   nothing in logs/main-red.log said so. An explicit run cleared it at 00:43.
#
#   THE PROPERTY UNDER TEST. A re-run green page still clears (A1, the
#   BH-1927 floor does not reject an equal created_at), a truly stale page still
#   decides nothing (A1b), and a re-run red stays frozen with no second page
#   (A2). A flagged repo that is not decided gets exactly one decision=none line
#   (A3, A5, A6, A7). A scheduled pass reads the flagged repo first (A4, R2).
#   --explain writes none of the new lines (A8).
#
# bin/main-red-detector.sh runs with its real lib closure. Only lane-alert.sh,
# jobs-client.sh (flag_set recorder, ledger over a dir) and gh are stubs.
# Every timestamp is a literal. Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || {
  echo "main-red-rerun-clear.bh-6352-test: SKIPPED — jq/python3/timeout/mkfifo/flock is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin" "$T/pages" "$T/ledger"
mkfifo "$T/hang.fifo"
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# The coordination-DB client the detector sources: flag_set is a recorder, and
# the two ledger verbs keep the bin/lib/jobs/jobs.sh contract over one file per row.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/' '-')"; }
job_ledger_get() {
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2
  cat "$f"; return 0
}
job_ledger_put() { printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0; }
SHIM

# gh shim. A runs read serves $T/pages/<owner>-<repo>.json through the
# detector's OWN -q expression, so the projection is never hand copied. A slug
# listed in $T/hang blocks on a FIFO nobody writes (bounded at 30 s): a read
# that does not finish before the pass ends. No page file = no runs. The
# visibility probe answers 0.
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
    grep -qxF "$slug" "$T/hang" 2>/dev/null && read -r -t 30 _ <>"$T/hang.fifo"
    f="$T/pages/$(printf '%s' "$slug" | tr '/' '-').json"
    [ -s "$f" ] || exit 0
    if [ -n "$q" ]; then jq -c "$q" "$f"; else cat "$f"; fi ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

# The real lib closure; the stubs above were written first, so they stay.
scratch_install_closure bin/main-red-detector.sh "$T" >/dev/null || bad "setup: detector closure install failed"
scratch_install_closure bin/fleet-conf.sh "$T" >/dev/null || bad "setup: fleet-conf closure install failed"

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
# R: run 38322322575, re-run (attempt 2) with the SAME created_at as the floor.
RSHA=547879e4591a4ec9405d21bfd709e03a1b580814
r_page() { # r_page <slug> <conclusion of R>
  page "$1" 64 \
    "38322322575|$2|2026-10-12T23:28:36Z|2026-10-13T00:24:29Z|$RSHA|2" \
    "38322235694|success|2026-10-12T23:27:36Z|2026-10-12T23:40:00Z|green0003|1" \
    "38318317991|success|2026-10-12T22:43:59Z|2026-10-12T22:55:00Z|green0002|1" \
    "38318000001|success|2026-10-12T22:00:00Z|2026-10-12T22:10:00Z|green0001|1"
}
flag() { # flag <slug> — the body the raise tick left
  printf 'sha=%s\nworkflow=ci\npath=%s\nreason=tip\nrun=https://github.com/%s/actions/runs/38322322575\n' \
    "$RSHA" "$CI" "$1" > "$T/flags/main-red-$(printf '%s' "$1" | tr '/' '-')"
}
floor() { # floor <slug> <total> <newest>
  printf 'total=%s newest=%s' "$2" "$3" > "$T/ledger/main_red_runs__$(printf '%s' "$1" | tr '/' '-')"
}

DRC=0
drive() { # drive [args...] — one pass; TO=<s> runs it under timeout -s TERM
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" PUBLISH_SINK="$T/publish.txt" LEDGER_DIR="$T/ledger" \
           MAIN_RED_QUEUE=0 HARNESS_REPO="${HREPO:-o/harness}" MAIN_RED_REPOS="${REPOS:-}" \
           FLEET_CONF="$T/fleet.conf"
    unset REGISTRY_SOURCE
    [ -n "$MAIN_RED_REPOS" ] || unset MAIN_RED_REPOS
    unset GH_TOKEN
    if [ -n "${TO:-}" ]; then timeout -s TERM "$TO" bash "$T/bin/main-red-detector.sh" "$@"
    else bash "$T/bin/main-red-detector.sh" "$@"; fi >"$T/out.txt" 2>"$T/err.txt" )
  DRC=$?
}
mrlog()   { cat "$T/logs/main-red.log" 2>/dev/null; }
cnt()     { grep -cE -- "$1" "$T/logs/main-red.log" 2>/dev/null | tr -d ' '; }
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
first_runs_read() { grep -m1 'actions/runs -f branch=main' "$T/gh.txt" 2>/dev/null; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"; : > "$T/gh.txt"
  rm -f "$T"/flags/* "$T"/locks/* "$T"/ledger/* "$T"/pages/*.json "$T/hang" "$T/fleet.conf"
  scratch_rm "$T/state/main-red"
  REPOS=""; HREPO=""; TO=""
}

# ── A1: a re-run green R with the floor's own created_at clears the flag ──────
reset_case; REPOS="o/r"; flag o/r; floor o/r 64 2026-10-12T23:28:36Z; r_page o/r success
drive
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "A1 flag is still up on a re-run green page"
grep -q '^main-red-o-r off' "$T/publish.txt" && ok || bad "A1 no off publish: $(cat "$T/publish.txt")"
[ "$(alerts)" = 1 ] && grep -q 'GREEN again' "$T/alerts.txt" && ok || bad "A1 want 1 GREEN alert, got: $(cat "$T/alerts.txt")"
grep -qx 'decision=green' "$T/state/main-red/o-r.verdict" 2>/dev/null && ok || bad "A1 verdict is not green"
[ "$(cnt ' decision=none')" = 0 ] && ok || bad "A1 a decision=none line on a cleared repo"

# ── A1b: a page truly older than the floor still decides nothing (BH-1927) ───
reset_case; REPOS="o/r"; flag o/r; floor o/r 64 2026-10-13T01:00:00Z; r_page o/r success
drive
[ -e "$T/flags/main-red-o-r" ] && ok || bad "A1b a stale page cleared the flag"
[ "$(alerts)" = 0 ] && ok || bad "A1b a stale page alerted"
grep -qx 'reason=stale-page' "$T/state/main-red/o-r.verdict" 2>/dev/null && ok || bad "A1b verdict is not stale-page"
# ── A3a: that undecided flagged repo says so, once ───────────────────────────
[ "$(cnt ' o/r: decision=none reason=stale-page flag=main-red-o-r ')" = 1 ] && ok \
  || bad "A3a want 1 stale-page decision=none line:
$(mrlog)"

# ── A2: a re-run red R stays frozen on R, with no second page ────────────────
reset_case; REPOS="o/r"; flag o/r; floor o/r 64 2026-10-12T23:28:36Z; r_page o/r failure
drive
grep -qx "sha=$RSHA" "$T/flags/main-red-o-r" 2>/dev/null && ok || bad "A2 the flag left R's sha"
[ "$(alerts)" = 0 ] && ok || bad "A2 a second alert: $(cat "$T/alerts.txt")"
[ "$(cnt 'still red')" -ge 1 ] && ok || bad "A2 no still-red line"
[ "$(cnt ' decision=none')" = 0 ] && ok || bad "A2 a decision=none line on a red decision"

# ── A3b: flag up and no runs ─────────────────────────────────────────────────
reset_case; REPOS="o/r"; flag o/r
drive
[ "$(cnt ' o/r: decision=none reason=no-runs flag=main-red-o-r ')" = 1 ] && ok || bad "A3b want 1 no-runs line"
[ -e "$T/flags/main-red-o-r" ] && ok || bad "A3b no-runs touched the flag"

# ── A3c: no flag and no runs: nothing to say ─────────────────────────────────
reset_case; REPOS="o/r"
drive
[ "$(cnt ' decision=none')" = 0 ] && ok || bad "A3c a decision=none line with no flag up"
grep -q '^decision=none' "$T/state/main-red/o-r.verdict" 2>/dev/null && ok || bad "A3c the verdict file is not written"

# ── A3d: flag up and a green page: decided, so no line ───────────────────────
reset_case; REPOS="o/r"; flag o/r; one_green o/r
drive
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "A3d the green page did not clear"
[ "$(cnt ' decision=none')" = 0 ] && ok || bad "A3d a decision=none line on a decided repo"

# ── A4: the scheduled pass reads the flagged repo first ──────────────────────
reset_case; REPOS="a/one b/two o/r"; flag o/r
one_green a/one; one_green b/two; one_green o/r
drive
first_runs_read | grep -q 'repos/o/r/' && ok || bad "A4 first runs read is not o/r: $(first_runs_read)"
[ "$(cnt 'pass start: 3 repo\(s\), 1 with a flag up, decided first: o/r$')" = 1 ] && ok || bad "A4 no pass start line:
$(mrlog)"
[ "$(cnt 'pass end: decided 3 of 3 repo\(s\) in [0-9]+s, exit 0, signal none, last repo b/two$')" = 1 ] && ok \
  || bad "A4 no clean pass end line:
$(mrlog)"
# A4-neg: explicit args keep their order
reset_case; flag o/r; one_green a/one; one_green o/r
drive a/one o/r
first_runs_read | grep -q 'repos/a/one/' && ok || bad "A4-neg args were reordered: $(first_runs_read)"

# ── A5: a pass killed on a hung read names every flagged repo it did not decide
reset_case; REPOS="f/one f/two u/three"; flag f/one; flag f/two
one_green f/one; one_green f/two; one_green u/three; echo f/one > "$T/hang"
cp "$T/flags/main-red-f-one" "$T/f1.before"; cp "$T/flags/main-red-f-two" "$T/f2.before"
TO=5 drive
[ "$DRC" = 124 ] && ok || bad "A5 want timeout rc 124, got $DRC"
[ "$(cnt ' f/one: decision=none reason=not-reached flag=main-red-f-one ')" = 1 ] && ok || bad "A5 want 1 f/one not-reached line:
$(mrlog)"
[ "$(cnt ' f/two: decision=none reason=not-reached flag=main-red-f-two ')" = 1 ] && ok || bad "A5 want 1 f/two not-reached line"
[ "$(cnt 'u/three')" = 0 ] && ok || bad "A5 a line names the unflagged u/three"
[ "$(cnt 'pass end: decided 0 of 3 repo\(s\) in [0-9]+s, exit 143, signal TERM, last repo f/one$')" = 1 ] && ok \
  || bad "A5 want 1 pass end line with signal TERM and last repo f/one"
cmp -s "$T/f1.before" "$T/flags/main-red-f-one" && cmp -s "$T/f2.before" "$T/flags/main-red-f-two" && ok \
  || bad "A5 a flag changed"
[ "$(alerts)" = 0 ] && ok || bad "A5 alerted"

# ── A6: a lock-held pass says it skipped the flagged repo, and touches nothing
reset_case; REPOS="o/r"; flag o/r; one_green o/r; cp "$T/flags/main-red-o-r" "$T/f.before"
exec 9>"$T/locks/main-red-detector.lock"; flock -n 9 || bad "A6 setup: could not take the lock"
drive
exec 9>&-
[ "$DRC" = 0 ] && ok || bad "A6 want rc 0, got $DRC"
[ "$(cnt ' main-red-o-r: decision=none reason=lock-held ')" = 1 ] && ok || bad "A6 want 1 lock-held line:
$(mrlog)"
cmp -s "$T/f.before" "$T/flags/main-red-o-r" && ok || bad "A6 the flag changed"
[ -z "$(first_runs_read)" ] && ok || bad "A6 a runs read under a held lock"
# with no flag up, a held lock stays quiet
reset_case; REPOS="o/r"
exec 9>"$T/locks/main-red-detector.lock"; flock -n 9 || bad "A6 setup: could not take the lock"
drive
exec 9>&-
[ "$(cnt 'decision=none')" = 0 ] && ok || bad "A6 a lock-held line with no flag up"

# ── A7: a flag no listed repo maps to is named; a switch file never is ───────
reset_case; REPOS="a/one"; one_green a/one
printf 'sha=x\n' > "$T/flags/main-red-zz-gone"; : > "$T/flags/main-red-pr-pair-off"
drive
[ "$(cnt ' main-red-zz-gone: decision=none reason=not-in-repo-list ')" = 1 ] && ok || bad "A7 want 1 not-in-repo-list line:
$(mrlog)"
[ "$(cnt 'main-red-pr-pair-off')" = 0 ] && ok || bad "A7 a line names the pr-pair switch"
: > "$T/logs/main-red.log"
drive a/one
[ "$(cnt 'not-in-repo-list')" = 0 ] && ok || bad "A7 an explicit run named a stray flag"

# ── A8: --explain writes none of the new lines ───────────────────────────────
reset_case; REPOS="f/one f/two u/three"; flag f/one; flag f/two
one_green f/one; one_green f/two; one_green u/three
printf 'sha=x\n' > "$T/flags/main-red-zz-gone"
drive --explain
[ "$(cnt '(^|Z )pass (start|end): | decision=none reason=')" = 0 ] && ok || bad "A8 --explain logged a new line"
grep -qE '^pass (start|end): | decision=none reason=' "$T/out.txt" && bad "A8 --explain printed a new line" || ok
[ -e "$T/flags/main-red-f-one" ] && [ -e "$T/flags/main-red-f-two" ] && ok || bad "A8 --explain cleared a flag"

# ── R1/R2: the 2026-10-13 fleet, replayed ────────────────────────────────────
mk_fleet() {
  reset_case; HREPO=example-org/cromford
  cat > "$T/fleet.conf" <<'EOF'
project-1   example-org/project-1      -  /api/board  2 box-fixture 192.0.2.1
project-2 example-org/project-2   -  /api/board  4 box-fixture 192.0.2.2
project-3       example-org/project-3          -  /api/board  6 box-fixture 192.0.2.3
project-4       example-org/project-4          -  /api/board  8 box-fixture 192.0.2.4
project-5     example-org/project-5        -  -           9 box-fixture 192.0.2.5
project-6     example-org/project-6-runtime -  -          3 box-fixture 192.0.2.6
project-8 example-org/project-8 - /api/board 1 box-fixture 192.0.2.7
project-9    example-org/project-9       -  /api/board  5 box-fixture 192.0.2.8
project-7      example-org/project-7         -  -           1 box-fixture 192.0.2.6
cromford example-org/cromford    -  -           3 box-fixture 192.0.2.7
harness-console example-org/cromford-console - -     5 box-fixture 192.0.2.7
cromford      example-org/cromford-web     -  -           7 box-fixture 192.0.2.7
project-6-os  example-org/project-6        -  -           1 box-fixture 192.0.2.9
EOF
  local s
  for s in project-1 project-2 project-3 project-4 project-5 project-8 project-9 \
           project-7 cromford cromford-console cromford-web; do one_green "example-org/$s"; done
  # The live project-6 page of 2026-10-13: 10 runs, total_count 64, R newest.
  page example-org/project-6 64 \
    "38322322575|success|2026-10-12T23:28:36Z|2026-10-13T00:24:29Z|$RSHA|2" \
    "38322286491|cancelled|2026-10-12T23:28:10Z|2026-10-12T23:28:40Z|fixture0009|1" \
    "38322235694|success|2026-10-12T23:27:36Z|2026-10-12T23:40:00Z|fixture0008|1" \
    "38318317991|success|2026-10-12T22:43:59Z|2026-10-12T22:55:00Z|fixture0007|1" \
    "38318000006|success|2026-10-12T22:00:00Z|2026-10-12T22:10:00Z|fixture0006|1" \
    "38318000005|success|2026-10-12T21:00:00Z|2026-10-12T21:10:00Z|fixture0005|1" \
    "38318000004|success|2026-10-12T20:00:00Z|2026-10-12T20:10:00Z|fixture0004|1" \
    "38318000003|success|2026-10-12T19:00:00Z|2026-10-12T19:10:00Z|fixture0003|1" \
    "38318000002|success|2026-10-12T18:00:00Z|2026-10-12T18:10:00Z|fixture0002|1" \
    "38318000001|success|2026-10-12T17:00:00Z|2026-10-12T17:10:00Z|fixture0001|1"
  printf 'sha=%s\nworkflow=ci\npath=%s\nreason=tip\nrun=https://github.com/example-org/project-6/actions/runs/38322322575\n' \
    "$RSHA" "$CI" > "$T/flags/main-red-example-org-project-6"
  floor example-org/project-6 64 2026-10-12T23:28:36Z
}
MKF="$T/flags/main-red-example-org-project-6"
# R1: one scheduled pass clears it
mk_fleet
drive
[ ! -e "$MKF" ] && ok || bad "R1 the project-6 flag is still up after one pass:
$(mrlog)"
grep -q 'example-org/project-6 main is GREEN again' "$T/alerts.txt" && ok || bad "R1 no GREEN alert: $(cat "$T/alerts.txt")"
# R2: repo 7's read hangs and the pass is killed at 8 s; project-6 still clears
mk_fleet; echo example-org/project-8 > "$T/hang"
TO=8 drive
[ ! -e "$MKF" ] && ok || bad "R2 the project-6 flag is still up after a cut pass"
grep -q 'example-org/project-6 main is GREEN again' "$T/alerts.txt" && ok || bad "R2 no GREEN alert"
[ "$(cnt 'pass end: .* signal TERM, ')" = 1 ] && ok || bad "R2 want 1 pass end line with signal TERM"

echo "main-red-rerun-clear.bh-6352-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
