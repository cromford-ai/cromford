#!/bin/bash
# tests/nightly-report-ticket.bh-10020-test.sh — BH-10020: the nightly
# payload-pin report is red when the lint cannot run, and its findings go to
# one tracking issue through bin/nightly-ticket.sh.
#
# The lints step and the verdict step of harness-nightly.yml run for real in a
# scratch tree with stub scripts; bin/nightly-ticket.sh runs for real with a
# fake gh (the NT_GH seam).
#   L1  payload-pin rc 2 (could not run): the lints step exits 1, and lints.md
#       names payload-pin.
#   L2  payload-pin rc 1 (findings): the step exits 0, and lints/payload-pin.md
#       holds the finding lines.
#   L3  the lints upload step hands payload-pin.md to the verdict job.
#   V1  a green night with payload-pin.md calls bin/nightly-ticket.sh once with
#       NT_RED=0 and exits 0.
#   V2  a green night with no payload-pin.md calls nothing and exits 0.
#   V3  a red night calls bin/nightly-ticket.sh with NT_RED=1 and exits 1.
#   T1  NT_RED=0, a report and no open tracking issue: one issue opened (as
#       the App token) whose body carries the report marker and the finding,
#       no run-level ticket, a `payload-pin-report ... new` tsv row.
#   T2  NT_RED=0, a report and an open tracking issue: one comment on it, no
#       issue opened.
#   T3  NT_RED=0 and no report: no gh call at all.
#   T5  an open tracking issue WITHOUT ai-build (a split parent keeps its
#       issue open and loses the label): found and commented, no create; the
#       read sends no labels= filter (the fake gh honours one).
#   T6  a split child (`Part of #N`) that copied the marker loses to the
#       tracking issue even when it is older.
#   T7  HARNESS unset (a CI runner): the seam's files go under the run's temp,
#       which is gone at exit.
#   T8  a list read that answers 502 (gh_rest 75) or 404 (44): one
#       skipped-unreadable row, rc 1, no create, no comment.
#   T4  a red night (NT_RED unset) with a failing suite and a report: the
#       per-suite issue, plus the report issue, and still no regression of the
#       red path (rc 0, the suite row is there).
# Mutations (each turns this suite red): treat rc 2 as a report (L1); skip
# the payload-pin.md write (L2); call nightly-ticket.sh only when RED=1 (V1);
# let NT_RED=0 reach the run-level section (T1 opens 2 issues).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/nightly-report-ticket.bh-10020-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${NR_WORKFLOW:-$DIR/.github/workflows/harness-nightly.yml}"
NT="${NR_TICKET:-$DIR/bin/nightly-ticket.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null || ! command -v jq >/dev/null 2>&1; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML or jq missing on a CI runner"; exit 1; }
  echo "nightly-report-ticket: PyYAML or jq missing — skipping on this dev machine"; exit 0
fi

python3 - "$WF" "$T" <<'PY'
import sys, yaml
wf, t = sys.argv[1:3]
jobs = yaml.safe_load(open(wf)).get("jobs") or {}
def step(job, name):
    s = [x for x in (jobs.get(job) or {}).get("steps") or [] if x.get("name") == name]
    return s[0] if s else {}
open(t + "/lints-run.sh", "w").write(str(step("lints", "the hygiene lints, strict").get("run", "")))
open(t + "/verdict-run.sh", "w").write(str(step("verdict", "every shard ran, every suite passed, nothing touched a real harness").get("run", "")))
open(t + "/upload-path.txt", "w").write(str((step("lints", "hand a red lint report to the fan-in").get("with") or {}).get("path", "")))
PY

# ── L. the lints step ───────────────────────────────────────────────────────
W="$T/w"; mkdir -p "$W/bin" "$W/tests"
stub() { printf '#!/bin/bash\necho "%s"\nexit "${%s:-0}"\n' "$3" "$2" > "$W/$1"; chmod +x "$W/$1"; }
stub bin/test-determinism-lint.sh RC_DET 'determinism: clean'
stub bin/test-payload-pin-lint.sh RC_PIN 'console-ui/tests/x.test.js:49: payload-pin: deep-equal-whole: deep-equals the whole response'
stub tests/day-boundary-guard.bh-6052-test.sh RC_DAY 'day-boundary-guard: clean'
lints() {  # lints <pin rc> -> rc; files under $T/rt
  rm -rf "$T/rt"; mkdir -p "$T/rt"; : > "$T/rt/summary.md"
  ( cd "$W" && RC_DET=0 RC_PIN="$1" RC_DAY=0 RUNNER_TEMP="$T/rt" GITHUB_STEP_SUMMARY="$T/rt/summary.md" \
      LINTS_BASE=0000000000000000000000000000000000000000 bash -e "$T/lints-run.sh" ) > "$T/rt/out" 2>&1
}
lints 2; rc=$?
[ "$rc" = 1 ] && ok || bad "L1 payload-pin rc 2 (could not run) must make the step red (rc=$rc): $(tail -3 "$T/rt/out")"
grep -q '^# Nightly hygiene lints red: payload-pin' "$T/rt/lints/lints.md" 2>/dev/null && ok || bad "L1 lints.md must name payload-pin: $(cat "$T/rt/lints/lints.md" 2>/dev/null)"
lints 1; rc=$?
[ "$rc" = 0 ] && ok || bad "L2 payload-pin rc 1 (findings) must stay a report (rc=$rc)"
grep -q '^console-ui/tests/x.test.js:49: payload-pin: ' "$T/rt/lints/payload-pin.md" 2>/dev/null && ok \
  || bad "L2 lints/payload-pin.md must hold the finding: $(cat "$T/rt/lints/payload-pin.md" 2>/dev/null)"
grep -q 'lints/payload-pin.md' "$T/upload-path.txt" && grep -q 'lints/lints.md' "$T/upload-path.txt" && ok \
  || bad "L3 the upload must carry lints.md and payload-pin.md: $(cat "$T/upload-path.txt")"

# ── V. the verdict step ─────────────────────────────────────────────────────
V="$T/vw"; mkdir -p "$V/bin"
printf '#!/bin/bash\nexit "${RC_VERDICTS:-0}"\n' > "$V/bin/ci-verdicts.sh"
printf '#!/bin/bash\nprintf "NT_RED=%%s dir=%%s\\n" "${NT_RED:-unset}" "$1" >> "$NT_CALLS"\nexit 0\n' > "$V/bin/nightly-ticket.sh"
chmod +x "$V/bin/ci-verdicts.sh" "$V/bin/nightly-ticket.sh"
verdict() {  # verdict <ci-verdicts rc> <with report 1|0> -> rc
  rm -rf "$T/vt"; mkdir -p "$T/vt/verdicts"; : > "$T/vt/calls"; : > "$T/vt/summary.md"
  [ "$2" = 1 ] && printf 'console-ui/tests/x.test.js:49: payload-pin: deep-equal-whole\n' > "$T/vt/verdicts/payload-pin.md"
  ( cd "$V" && RC_VERDICTS="$1" NT_CALLS="$T/vt/calls" RUNNER_TEMP="$T/vt" GITHUB_STEP_SUMMARY="$T/vt/summary.md" \
      PLAN_RESULT=success PLAN_N=1 PLAN_COUNT=1 PLAN_SUMMARY=x STRICT_RESULT=success LINTS_RESULT=success \
      NT_ON_MAIN=true NT_APP_TOKEN=app-tok GITHUB_REF=refs/heads/main bash -e "$T/verdict-run.sh" ) > "$T/vt/out" 2>&1
}
verdict 0 1; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c . "$T/vt/calls")" = 1 ] && grep -q '^NT_RED=0 ' "$T/vt/calls" && ok \
  || bad "V1 a green night with a report must call nightly-ticket once with NT_RED=0 and exit 0 (rc=$rc, calls: $(cat "$T/vt/calls"))"
verdict 0 0; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/vt/calls" ] && ok || bad "V2 a green night with no report must call nothing (rc=$rc, calls: $(cat "$T/vt/calls"))"
verdict 1 1; rc=$?
[ "$rc" = 1 ] && [ "$(grep -c . "$T/vt/calls")" = 1 ] && grep -q '^NT_RED=1 ' "$T/vt/calls" && ok \
  || bad "V3 a red night must call nightly-ticket once with NT_RED=1 and exit 1 (rc=$rc, calls: $(cat "$T/vt/calls"))"

# ── T. bin/nightly-ticket.sh with a fake gh ─────────────────────────────────
cat > "$T/gh" <<'GH'
#!/bin/bash
# The old helpers call `gh api ... --jq`; the tracker seam's gh_rest calls
# `gh api -i -X <M> <path> ...` and reads the status line and body.
printf '%s\t%s\n' "${GH_TOKEN:-}" "$*" >> "$FAKE_SINK"
printf '%s\n' "${HARNESS:-unset}" >> "$FAKE_SINK.harness"
JQ=""; POST=0; P=""; BODY=""; INC=0; PAGE=1; INPUT=""; LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    api|--paginate) ;;
    -i) INC=1 ;;
    --jq) JQ="$2"; shift ;;
    --input) INPUT="$2"; shift ;;
    -X) [ "$2" = POST ] && POST=1; shift ;;
    -F) case "$2" in body=@*) BODY="${2#body=@}" ;; page=*) PAGE="${2#page=}" ;; esac; shift ;;
    -f) case "$2" in labels=*) LABEL="${2#labels=}" ;; esac; shift ;;
    -H) shift ;;
    *) P="$1" ;;
  esac
  shift
done
out() { if [ "$INC" = 1 ]; then printf 'HTTP/2.0 %s OK\r\n\r\n' "$1"; jq -c . ; else jq -r "${JQ:-.}"; fi; }
if [ "$POST" = 1 ]; then
  [ -n "$BODY" ] && { printf -- '--- %s\n' "$P"; cat "$BODY"; } >> "$FAKE_BODIES"
  [ -n "$INPUT" ] && { printf -- '--- %s\n' "$P"; jq -r '.body' "$INPUT"; } >> "$FAKE_BODIES"
  case "$P" in
    */labels) printf '[{"name":"ai-build"}]\n' | out 200; exit 0 ;;
    */comments) printf '{"id":1}\n' | out 201; exit 0 ;;
  esac
  N=$(( $(cat "$FAKE_N" 2>/dev/null || echo 100) + 1 )); echo "$N" > "$FAKE_N"
  jq -n --argjson n "$N" '{number:$n,labels:[{name:"ai-build"}]}' | out 201
  exit 0
fi
if [ "$INC" = 1 ]; then
  # FAKE_GET_STATUS: the list read answers this status (502, 404) instead.
  if [ -n "${FAKE_GET_STATUS:-}" ]; then printf 'HTTP/2.0 %s X\r\n\r\n{"message":"fake"}\n' "$FAKE_GET_STATUS"; exit 1; fi
  # GitHub's labels= filter: an issue without that label is not on the page.
  if [ "$PAGE" = 1 ]; then
    jq --arg l "$LABEL" '[.[] | select($l == "" or ([(.labels // [])[].name] | index($l) != null))]' "$FAKE_OPEN" | out 200
  else printf '[]\n' | out 200; fi
  exit 0
fi
jq -r "$JQ" "$FAKE_OPEN"
GH
chmod +x "$T/gh"
RMARK='<!-- harness-nightly-report:payload-pin -->'
printf '[]\n' > "$T/none.json"
jq -n --arg m "$RMARK" '[{number:55,body:("tracking " + $m),labels:[{name:"ai-build"}]}]' > "$T/open.json"
# A split parent stays open with ai-build taken off (bin/lib/fc-issues.sh).
jq -n --arg m "$RMARK" '[{number:55,body:("tracking " + $m),labels:[]}]' > "$T/open-unlabelled.json"
# A split child (`Part of #N`) that copied the marker, older than the parent.
jq -n --arg m "$RMARK" '[{number:50,body:("child " + $m + "\n\nPart of #40\n"),labels:[{name:"ai-build"}]},
  {number:70,body:("tracking " + $m),labels:[]}]' > "$T/open-child.json"
nt() {  # nt <verdict dir> <open.json> [VAR=value ...] -> rc
  local v="$1" open="$2"; shift 2
  : > "$T/sink"; : > "$T/sink.harness"; : > "$T/bodies"; rm -f "$T/n"
  local hv=(HARNESS="$T/h"); [ "${NT_NO_HARNESS:-0}" = 1 ] && hv=(-u HARNESS)
  env "${hv[@]}" GH_TOKEN=wf-tok NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_BODIES="$T/bodies" FAKE_N="$T/n" FAKE_OPEN="$open" \
      NT_REPO=o/r NT_SHA=abc NT_PLAN_RESULT=success NT_PLAN_N=1 NT_APP_TOKEN=app-tok "$@" \
      bash "$NT" "$v" > "$T/nt.out" 2> "$T/nt.err"
}
creates() { grep -cE $'^[^\t]*\tapi (-i )?-X POST repos/o/r/issues (-f|--input)' "$T/sink"; }
mkdir -p "$T/g" "$T/g0" "$T/r"
printf 'tests=1\nfailed=0\n' > "$T/g/shard-0.txt"; printf -- '--- tests/a-test.sh rc=0 1s\n' > "$T/g/shard-0.log"
cp "$T/g/shard-0.txt" "$T/g/shard-0.log" "$T/g0/"
printf 'console-ui/tests/x.test.js:49: payload-pin: deep-equal-whole\n' > "$T/g/payload-pin.md"

nt "$T/g" "$T/none.json" NT_RED=0; rc=$?
[ "$rc" = 0 ] && ok || bad "T1 rc $rc ($(cat "$T/nt.err"))"
[ "$(creates)" = 1 ] && ok || bad "T1 a green night with a report must open exactly 1 issue, got $(creates): $(cat "$T/sink")"
grep -qF "$RMARK" "$T/bodies" && grep -q 'console-ui/tests/x.test.js:49' "$T/bodies" && ok \
  || bad "T1 the issue body must carry the report marker and the finding: $(cat "$T/bodies")"
grep -q '<!-- harness-nightly-red -->' "$T/bodies" && bad "T1 a green night must not open the run-level ticket" || ok
grep -qE $'^app-tok\tapi -i -X POST repos/o/r/issues --input ' "$T/sink" && ok \
  || bad "T1 the create must run as the App token, through the tracker seam (gh_rest): $(cat "$T/sink")"
grep -qE $'^[^\t]*\tapi -i -X GET repos/o/r/issues -f state=open -F per_page=100 -F page=1$' "$T/sink" && ok \
  || bad "T1 the open-issue read must go through the tracker seam (trk_gh_open_issue_page): $(cat "$T/sink")"
grep -qE $'^payload-pin-report\t.*\tnew\thttps://github.com/o/r/issues/101$' "$T/g/ticket-requests.tsv" && ok \
  || bad "T1 the tsv must carry the report row: $(cat "$T/g/ticket-requests.tsv")"

nt "$T/g" "$T/open.json" NT_RED=0; rc=$?
[ "$rc" = 0 ] && [ "$(creates)" = 0 ] && grep -qE $'\tapi -i -X POST repos/o/r/issues/55/comments ' "$T/sink" && ok \
  || bad "T2 an open tracking issue must get one comment and no new issue (rc=$rc): $(cat "$T/sink")"

nt "$T/g0" "$T/none.json" NT_RED=0; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/sink" ] && ok || bad "T3 a green night with no report must make no gh call (rc=$rc): $(cat "$T/sink")"

printf 'tests=1\nfailed=1\n' > "$T/r/shard-0.txt"; printf -- '--- tests/a-test.sh rc=1 1s\n' > "$T/r/shard-0.log"
cp "$T/g/payload-pin.md" "$T/r/"
nt "$T/r" "$T/none.json"; rc=$?
[ "$rc" = 0 ] && ok || bad "T4 rc $rc ($(cat "$T/nt.err"))"
grep -qE $'^tests/a-test.sh\t.*\tnew\t' "$T/r/ticket-requests.tsv" && grep -qE $'^payload-pin-report\t.*\tnew\t' "$T/r/ticket-requests.tsv" && ok \
  || bad "T4 a red night must file the suite and the report: $(cat "$T/r/ticket-requests.tsv")"

comments_on() { grep -cE $'\tapi -i -X POST repos/o/r/issues/'"$1"'/comments ' "$T/sink"; }

nt "$T/g" "$T/open-unlabelled.json" NT_RED=0; rc=$?
[ "$rc" = 0 ] && [ "$(creates)" = 0 ] && [ "$(comments_on 55)" = 1 ] && ok \
  || bad "T5 an open tracking issue with no ai-build label (a split parent) must be found and commented, no create (rc=$rc): $(cat "$T/sink")"
grep -qE $'\tapi -i -X GET repos/o/r/issues ' "$T/sink" && ! grep -q 'labels=' "$T/sink" && ok \
  || bad "T5 the open-issue read must send no labels= filter: $(cat "$T/sink")"

nt "$T/g" "$T/open-child.json" NT_RED=0; rc=$?
[ "$rc" = 0 ] && [ "$(creates)" = 0 ] && [ "$(comments_on 70)" = 1 ] && [ "$(comments_on 50)" = 0 ] && ok \
  || bad "T6 a split child (Part of #N) carrying the marker must lose to the tracking issue (rc=$rc): $(cat "$T/sink")"

rm -rf "$T/tmpw"; mkdir -p "$T/tmpw"
NT_NO_HARNESS=1 nt "$T/g" "$T/open.json" NT_RED=0 TMPDIR="$T/tmpw"; rc=$?
[ "$rc" = 0 ] && [ "$(comments_on 55)" = 1 ] && ok || bad "T7 HARNESS unset (a runner) must still comment (rc=$rc): $(cat "$T/nt.err")"
h=$(sort -u "$T/sink.harness" | grep -v '^unset$' | head -n 1)
case "$h" in "$T/tmpw/nightly-ticket."*/harness) ok ;; *) bad "T7 HARNESS unset: the seam's files must go under the run's temp, gh saw HARNESS='$h'" ;; esac
[ -z "$(ls -A "$T/tmpw")" ] && ok || bad "T7 the run's temp (and the seam's files) must be gone at exit: $(ls -A "$T/tmpw")"

for st in 502 404; do
  nt "$T/g" "$T/open.json" NT_RED=0 FAKE_GET_STATUS="$st"; rc=$?
  [ "$rc" = 1 ] && [ "$(creates)" = 0 ] && ! grep -q '/comments' "$T/sink" \
    && grep -qE $'^payload-pin-report\t.*\tskipped-unreadable\t-$' "$T/g/ticket-requests.tsv" && ok \
    || bad "T8 a list read that answers $st must end skipped-unreadable, rc 1, no create, no comment (rc=$rc): $(cat "$T/g/ticket-requests.tsv") / $(cat "$T/sink")"
done

echo "nightly-report-ticket.bh-10020: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
