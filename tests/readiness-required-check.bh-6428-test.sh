#!/bin/bash
# tests/readiness-required-check.bh-6428-test.sh — BH-6428: the readiness
# report says `OWED: required status check` for a repo whose default branch has
# no ruleset or protection rule that requires a status check.
#
# project-6's main ruleset had pull_request, deletion and non_fast_forward, and
# no required_status_checks, so GitHub accepted a REST merge of a red PR (#216).
#
# Driven: bin/readiness-report.sh --json --no-run on a fixture checkout with a
# `gh` stub on PATH. The stub answers each endpoint from a fixture file.
#   Q1 protection required_status_checks null + rules []        -> fail, OWED
#   Q2 rules carry required_status_checks                        -> pass
#   Q3 protection required_status_checks set + rules []          -> pass
#   Q4 "Branch not protected" + rules []                         -> fail, OWED
#   Q5 rules read fails (rate limit)                             -> unknown
#   Q6 READINESS_GH=0                                            -> skipped
#   Q7 the level is the same for Q1 and Q2 (report-only check)
#   Q8 protection read fails (not "not protected") + rules []    -> unknown
# Run from anywhere: bash tests/readiness-required-check.bh-6428-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RR="$DIR/bin/readiness-report.sh"
FIX="$DIR/tests/fixtures/readiness"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

mkdir -p "$T/h" "$T/bin" "$T/gh"
REPO="$T/repo"; mkdir -p "$REPO"; cp -R "$FIX/b-ready/." "$REPO/"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://github.com/acme/x.git

# The stub: repos/acme/x -> main; protection -> $T/gh/prot (rc in prot.rc,
# stderr in prot.err); rules -> $T/gh/rules (rc in rules.rc, stderr in rules.err).
cat > "$T/bin/gh" <<STUB
#!/bin/bash
echo "gh \$*" >> "$T/gh-log"
case "\$*" in
  *branches/main/protection*) cat "$T/gh/prot" 2>/dev/null; cat "$T/gh/prot.err" >&2 2>/dev/null; exit "\$(cat "$T/gh/prot.rc")" ;;
  *rules/branches/main*)      cat "$T/gh/rules" 2>/dev/null; cat "$T/gh/rules.err" >&2 2>/dev/null; exit "\$(cat "$T/gh/rules.rc")" ;;
  *label*)                    echo "ai-build" ;;
  *"repos/acme/x --jq .default_branch"*) echo main ;;
  *)                          exit 1 ;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"

fx() { # fx <prot-json|NOTPROT|FAIL> <rules-json|FAIL>
  rm -f "$T/gh"/*
  case "$1" in
    NOTPROT) echo 1 > "$T/gh/prot.rc"; echo "gh: Branch not protected (HTTP 404)" > "$T/gh/prot.err" ;;
    FAIL)    echo 1 > "$T/gh/prot.rc"; echo "gh: API rate limit exceeded (HTTP 403)" > "$T/gh/prot.err" ;;
    *)       echo 0 > "$T/gh/prot.rc"; printf '%s' "$1" > "$T/gh/prot" ;;
  esac
  case "$2" in
    FAIL) echo 1 > "$T/gh/rules.rc"; echo "gh: API rate limit exceeded (HTTP 403)" > "$T/gh/rules.err" ;;
    *)    echo 0 > "$T/gh/rules.rc"; printf '%s' "$2" > "$T/gh/rules" ;;
  esac
}
report() { # report <out> [env...]
  local out="$1"; shift
  : > "$T/gh-log"
  env PATH="$T/bin:$PATH" HARNESS="$T/h" "$@" bash "$RR" "$REPO" --no-run --json > "$T/$out.json" 2>"$T/$out.err"
}
st()  { jq -r --arg i "$2" '.checks[] | select(.id==$i) | .status' "$T/$1.json" 2>/dev/null; }
det() { jq -r --arg i "$2" '.checks[] | select(.id==$i) | .detail' "$T/$1.json" 2>/dev/null; }
lvl() { jq -r '.level' "$T/$1.json" 2>/dev/null; }

PROJECT_6_RULES='[{"type":"pull_request","parameters":{}},{"type":"deletion"},{"type":"non_fast_forward"}]'

# Q1. protected, required_status_checks null; the ruleset is project-6's shape
fx '{"url":"u","required_status_checks":null}' "$PROJECT_6_RULES"
report q1
[ "$(st q1 ci.required_check)" = fail ] && ok || bad "Q1 status must be fail (got '$(st q1 ci.required_check)', $(cat "$T/q1.err"))"
case "$(det q1 ci.required_check)" in "OWED: required status check"*) ok ;; *) bad "Q1 detail must start 'OWED: required status check' (got '$(det q1 ci.required_check)')" ;; esac
grep -q 'rules/branches/main' "$T/gh-log" && ok || bad "Q1 the rulesets endpoint must be read: $(cat "$T/gh-log")"
[ "$(st q1 ci.branch_protection)" = pass ] && ok || bad "Q1 ci.branch_protection must still pass (got '$(st q1 ci.branch_protection)')"

# Q2. a ruleset requires status checks
fx '{"url":"u","required_status_checks":null}' '[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"}]}}]'
report q2
[ "$(st q2 ci.required_check)" = pass ] && ok || bad "Q2 a required_status_checks rule must pass (got '$(st q2 ci.required_check)')"

# Q3. the protection rule requires status checks
fx '{"url":"u","required_status_checks":{"strict":true,"contexts":["ci"]}}' '[]'
report q3
[ "$(st q3 ci.required_check)" = pass ] && ok || bad "Q3 protection required_status_checks must pass (got '$(st q3 ci.required_check)')"

# Q4. branch not protected, no ruleset
fx NOTPROT '[]'
report q4
[ "$(st q4 ci.required_check)" = fail ] && ok || bad "Q4 must be fail (got '$(st q4 ci.required_check)')"
case "$(det q4 ci.required_check)" in "OWED: required status check"*) ok ;; *) bad "Q4 detail must start OWED (got '$(det q4 ci.required_check)')" ;; esac

# Q5. rules read fails -> unknown, never fail
fx '{"url":"u","required_status_checks":null}' FAIL
report q5
[ "$(st q5 ci.required_check)" = unknown ] && ok || bad "Q5 a failed rules read must be unknown (got '$(st q5 ci.required_check)')"

# Q6. READINESS_GH=0 -> skipped, and gh is never called
fx '{"url":"u","required_status_checks":null}' '[]'
report q6 READINESS_GH=0
[ "$(st q6 ci.required_check)" = skipped ] && ok || bad "Q6 READINESS_GH=0 must skip (got '$(st q6 ci.required_check)')"
[ -s "$T/gh-log" ] && bad "Q6 READINESS_GH=0 must not call gh: $(cat "$T/gh-log")" || ok

# Q7. report-only: the level does not move between the fail and the pass
[ -n "$(lvl q1)" ] && [ "$(lvl q1)" = "$(lvl q2)" ] && ok || bad "Q7 the level must not depend on ci.required_check (q1 $(lvl q1), q2 $(lvl q2))"

# Q8. protection unreadable, no ruleset -> unknown (nothing proves there is no rule)
fx FAIL '[]'
report q8
[ "$(st q8 ci.required_check)" = unknown ] && ok || bad "Q8 an unreadable protection must be unknown (got '$(st q8 ci.required_check)')"

echo "readiness-required-check.bh-6428: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
