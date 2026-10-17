#!/bin/bash
# tests/readiness-spec-trace.bh-6485-test.sh — BH-6485: bin/readiness-report.sh
# warns when a repo has a design/ or spec/ folder and open ai-build issues
# carry no `Spec:` line (bin/lib/spec-trace.sh's grammar). Report only: the
# level never moves on it.
#
# Driven: bin/readiness-report.sh --json --no-run on a fixture checkout with a
# `gh` stub on PATH that answers the issues read from a fixture file.
#   Q1 no design/ or spec/ -> na, and the issues are never read
#   Q2 design/ + 3 issues, 1 without Spec: -> fail, `WARN: 1 of 3`, its number
#   Q3 every issue carries Spec: -> pass
#   Q4 the issues read fails -> unknown, never pass
#   Q5 READINESS_GH=0 -> skipped
#   Q6 a PR in the issues answer is not counted
#   Q7 the level is the same for Q2 and Q3
#   Q8 a Spec: line only inside a fence, or a Spec-repo: line, does not count
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/readiness-spec-trace.bh-6485-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RR="$DIR/bin/readiness-report.sh"
FIX="$DIR/tests/fixtures/readiness"
unset PROJECT KEY BUILD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

mkdir -p "$T/h" "$T/bin" "$T/gh"
REPO="$T/repo"; mkdir -p "$REPO"; cp -R "$FIX/b-ready/." "$REPO/"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://github.com/acme/x.git

cat > "$T/bin/gh" <<STUB
#!/bin/bash
echo "gh \$*" >> "$T/gh-log"
case "\$*" in
  *"issues?state=open&labels=ai-build"*) cat "$T/gh/issues" 2>/dev/null; exit "\$(cat "$T/gh/issues.rc" 2>/dev/null || echo 0)" ;;
  *label*) echo "ai-build" ;;
  *"--jq .default_branch"*) echo main ;;
  *) echo '[]' ;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"

issues() { # issues <json|FAIL>
  rm -f "$T/gh"/*
  if [ "$1" = FAIL ]; then echo 1 > "$T/gh/issues.rc"; echo '{"message":"API rate limit exceeded"}' > "$T/gh/issues"
  else echo 0 > "$T/gh/issues.rc"; printf '%s' "$1" > "$T/gh/issues"; fi
}
report() { # report <out> [env...]
  local out="$1"; shift
  : > "$T/gh-log"
  env PATH="$T/bin:$PATH" HARNESS="$T/h" "$@" bash "$RR" "$REPO" --no-run --json > "$T/$out.json" 2>"$T/$out.err"
}
st()  { jq -r '.checks[] | select(.id=="spec.trace") | .status' "$T/$1.json" 2>/dev/null; }
det() { jq -r '.checks[] | select(.id=="spec.trace") | .detail' "$T/$1.json" 2>/dev/null; }
lvl() { jq -r '.level' "$T/$1.json" 2>/dev/null; }
I3='[{"number":11,"body":"Spec: design/prd.md#J01\nfixture"},{"number":12,"body":"no spec line here"},{"number":13,"body":"- `Spec:` design/prd.md#J02"}]'
I3OK='[{"number":11,"body":"Spec: design/prd.md#J01"},{"number":13,"body":"- `Spec:` design/prd.md#J02"}]'

# Q1
issues "$I3"
report q1
[ "$(st q1)" = na ] && ok || bad "Q1 no design/ or spec/ is na, got '$(st q1)': $(det q1)"
grep -q 'labels=ai-build' "$T/gh-log" && bad "Q1 no folder: the issues are never read" || ok

mkdir -p "$REPO/design"; printf '# PRD fixture\n' > "$REPO/design/prd.md"
# Q2
issues "$I3"
report q2
[ "$(st q2)" = fail ] && ok || bad "Q2 one issue without Spec: fails, got '$(st q2)': $(det q2)"
case "$(det q2)" in "WARN: 1 of 3 open ai-build issues carry no Spec: line: #12 (design/ present)") ok ;; *) bad "Q2 the warning: '$(det q2)'" ;; esac
# Q3
issues "$I3OK"
report q3
[ "$(st q3)" = pass ] && ok || bad "Q3 every issue carries Spec: passes, got '$(st q3)': $(det q3)"
# Q7
[ -n "$(lvl q2)" ] && [ "$(lvl q2)" = "$(lvl q3)" ] && ok || bad "Q7 the level is report-only: q2=$(lvl q2) q3=$(lvl q3)"
# Q4
issues FAIL
report q4
[ "$(st q4)" = unknown ] && ok || bad "Q4 a failed read is unknown, got '$(st q4)'"
issues '{"message":"not an array"}'
report q4b
[ "$(st q4b)" = unknown ] && ok || bad "Q4 an answer that is not a list is unknown, got '$(st q4b)'"
# Q5
issues "$I3"
report q5 READINESS_GH=0
[ "$(st q5)" = skipped ] && ok || bad "Q5 READINESS_GH=0 is skipped, got '$(st q5)'"
grep -q 'labels=ai-build' "$T/gh-log" && bad "Q5 READINESS_GH=0 reads nothing" || ok
# Q6
issues '[{"number":11,"body":"Spec: design/prd.md#J01"},{"number":14,"body":"a PR body","pull_request":{"url":"u"}}]'
report q6
[ "$(st q6)" = pass ] && grep -q '1 open ai-build issue(s)' <<<"$(det q6)" && ok || bad "Q6 a PR is not counted: '$(st q6)' $(det q6)"
# Q8
issues '[{"number":21,"body":"```\nSpec: design/prd.md#J01\n```"},{"number":22,"body":"Spec-repo: acme/prd"}]'
report q8
case "$(det q8)" in "WARN: 2 of 2 open ai-build issues carry no Spec: line: #21 #22 "*) ok ;; *) bad "Q8 a fenced Spec: or a Spec-repo: line does not count: '$(det q8)'" ;; esac
# spec/ counts as well as design/
scratch_rm "$REPO/design"; mkdir -p "$REPO/spec"; printf 'x\n' > "$REPO/spec/a.md"
issues "$I3"
report q9
[ "$(st q9)" = fail ] && grep -q '(spec/ present)' <<<"$(det q9)" && ok || bad "Q9 a spec/ folder counts: '$(st q9)' $(det q9)"

echo "readiness-spec-trace.bh-6485: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
