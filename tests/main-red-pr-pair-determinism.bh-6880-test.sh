#!/bin/bash
# tests/main-red-pr-pair-determinism.bh-6880-test.sh — two PRs that fail the
# "Test determinism lint" job on DIFFERENT findings never pair in
# bin/main-red-pr-pair.sh; two that fail on the SAME finding still pair.
#
#   THE INCIDENT: at 2026-10-15 12:51:53Z the lane paged "main is probably red"
#   for #6867 and #6875. Main was green. Both PRs failed the determinism lint on
#   unrelated files, but the lint's last line was its fixed footer ("Fix the
#   line, pin the file's clock, or waive it with a reason: ..."), and
#   first_error_of_job reads the line before the generic "Process completed
#   with exit code 1." So every failure of that job read one first error.
#
# The fix (BH-6880): on rc 1 the lint's LAST line names its first finding,
#   test-determinism-lint: first finding: <file>:<line>: <rule>
# and the lane groups on that.
#
# The job logs are BUILT here from the REAL lint output on two scratch trees, so
# this suite pins the lint and the lane together. $LINT picks the lint (default:
# this tree's bin/test-determinism-lint.sh); point it at main's copy to see the
# defect. Every timestamp is a literal.
#
# determinism: ok-file the fixture trees below carry a sleep and a printf|grep -q
# on purpose, as DATA for the lint; this suite reads no clock and never sleeps.
# Run from anywhere: tests/main-red-pr-pair-determinism.bh-6880-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="${LINT:-$DIR/bin/test-determinism-lint.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$DIR/bin/main-red-pr-pair.sh" ] && [ -f "$LINT" ] || {
  echo "FAIL: bin/main-red-pr-pair.sh or $LINT does not exist"
  echo "main-red-pr-pair-determinism: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-pr-pair-determinism: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin" "$T/h/flags"
scratch_install_closure bin/main-red-pr-pair.sh "$T" >/dev/null \
  || { echo "FAIL: cannot install the closure of bin/main-red-pr-pair.sh"
       echo "main-red-pr-pair-determinism: 0 passed, 1 failed"; exit 1; }
: > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# gh shim, the contract of tests/main-red-pr-pair-first-error.bh-5988-test.sh.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 echo "[]" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           sha=${A##*head_sha=}; sha=${sha%% *}
                              [ -s "$T/runs-$sha.json" ] || exit 1
                              jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url, id:.id}]' "$T/runs-$sha.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
JOB="Test determinism lint"
MARKS="$T/state/main-red/pairs/o-r"
LEDGER="$T/state/main-red/pr-errors/o-r"
FOOTER="Fix the line, pin the file's clock"
STAMP="2026-10-15T12:40:00.0000000Z"

pulls() { # pulls <number:head-sha:updatedAt>...
  local out='[' first=1 spec num sha upd
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)),
        title:"t", body:"", head:{sha:$sha, ref:("b"+($n|tostring))},
        base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null,
        labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}
head_run() { # head_run <head-sha> <created_at> <run-id>
  jq -nc --arg p "$CI" --arg t "$2" --argjson id "$3" \
    '{workflow_runs:[{name:"Harness CI", path:$p, status:"completed", conclusion:"failure",
       created_at:$t, html_url:"https://github.com/o/r/actions/runs/1", id:$id}]}' > "$T/runs-$1.json"
}
job_of() { printf '%s\t%s\n' "$JOB" "$2" > "$T/jobs-$1.txt"; }
drive() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN HARNESS_SECRET JOBS_URL
    bash "$T/bin/main-red-pr-pair.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
alerts()  { grep -cv -- '--resolve' "$T/alerts.txt" 2>/dev/null; }
markers() { ls -A "$MARKS" 2>/dev/null | awk 'END{print NR+0}'; }
col2()    { cut -f2 "$LEDGER/$1.tsv" 2>/dev/null; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/logs/main-red-pr-pair.log"
  scratch_rm "$MARKS"; scratch_rm "$LEDGER"
  rm -f "$T"/runs-*.json "$T"/jobs-*.txt "$T"/joblog-*.txt "$T/flags/main-red-o-r"
}

# joblog <tree> <out> — run the lint from inside <tree> on a relative path, as
# CI runs it from the repo root, and wrap its output as the raw Actions log of
# the job: the Run group, the echoed script, each output line, then the generic
# ##[error] the runner appends on rc 1.
joblog() {
  local rc
  ( cd "$1" && HARNESS="$T/h" bash "$LINT" tests ) > "$T/lint.out" 2>&1; rc=$?
  [ "$rc" = 1 ] || bad "fixture: the lint on $1 must exit 1, got $rc: $(cat "$T/lint.out")"
  { echo "$STAMP ##[group]Run bin/test-determinism-lint.sh"
    printf '%s \033[36;1mbin/test-determinism-lint.sh\033[0m\n' "$STAMP"
    echo "$STAMP shell: /usr/bin/bash -e {0}"
    echo "$STAMP ##[endgroup]"
    sed "s/^/$STAMP /" "$T/lint.out"
    echo "$STAMP ##[error]Process completed with exit code 1."; } > "$2"
}

# tree X: a race-sleep finding in tests/x.sh. tree Y: a race-sigpipe-echo
# finding in tests/y.sh. Different file, different rule; the same footer.
mkdir -p "$T/X/tests" "$T/Y/tests"
printf '#!/bin/bash\necho start\nsleep 5\n' > "$T/X/tests/x.sh"
printf '#!/bin/bash\nX=abc\nprintf %%s "$X" | grep -q b && echo hit\n' > "$T/Y/tests/y.sh"
joblog "$T/X" "$T/log-x.txt"
joblog "$T/Y" "$T/log-y.txt"

pair() { # pair <log-a> <log-b> — #6867 (aaaa111) and #6875 (bbbb222)
  pulls "6867:aaaa111:2026-10-15T12:30:00Z" "6875:bbbb222:2026-10-15T12:45:00Z"
  head_run aaaa111 2026-10-15T12:20:00Z 9001; job_of 9001 8001; cp "$1" "$T/joblog-8001.txt"
  head_run bbbb222 2026-10-15T12:35:00Z 9002; job_of 9002 8002; cp "$2" "$T/joblog-8002.txt"
}

# ── G1. the incident: different findings, the same footer → no alert ───────
reset_case; pair "$T/log-x.txt" "$T/log-y.txt"; drive o/r
[ "$(alerts)" = 0 ] && ok || bad "G1: different lint findings paired: $(cat "$T/alerts.txt")"
[ "$(markers)" = 0 ] && ok || bad "G1: a pair marker was written: $(ls -A "$MARKS" 2>/dev/null)"
[ ! -e "$T/flags/main-red-o-r" ] && ok || bad "G1: a suspected freeze was raised"
A2=$(col2 aaaa111); B2=$(col2 bbbb222)
[ -n "$A2" ] && [ "$A2" != "$B2" ] && ok || bad "G1: the two first errors must differ: '$A2' vs '$B2'"
[ "$A2" = "test-determinism-lint: first finding: tests/x.sh:3: race-sleep" ] && ok \
  || bad "G1: #6867 first error must name tests/x.sh and race-sleep: '$A2'"
[ "$B2" = "test-determinism-lint: first finding: tests/y.sh:3: race-sigpipe-echo" ] && ok \
  || bad "G1: #6875 first error must name tests/y.sh and race-sigpipe-echo: '$B2'"
case "$A2$B2" in *"$FOOTER"*) bad "G1: the footer is still the first error: '$A2' / '$B2'" ;; *) ok ;; esac

# ── G2. positive control: the same finding on both PRs still pages once ─────
reset_case; pair "$T/log-x.txt" "$T/log-x.txt"; drive o/r
[ "$(alerts)" = 1 ] && ok || bad "G2: a real shared finding must alert once: $(cat "$T/alerts.txt")"
grep -qF 'first finding: tests/x.sh:3: race-sleep' "$T/alerts.txt" && ok \
  || bad "G2: the alert must name the shared finding: $(cat "$T/alerts.txt")"
[ "$(markers)" = 1 ] && ok || bad "G2: want 1 marker, got $(markers)"

# ── G3. column 2 is never a log marker ──────────────────────────────────────
case "$A2" in '##['*) bad "G3: a marker became #6867's first error: '$A2'" ;; *) ok ;; esac
case "$B2" in '##['*) bad "G3: a marker became #6875's first error: '$B2'" ;; *) ok ;; esac

echo "main-red-pr-pair-determinism: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
