#!/bin/bash
# tests/rule-miner-adopt.bh-3714-test.sh — the weekly rule miner classifies each
# drafted rule and splits the week into a lint-backed PR and a stacked
# judgement PR (BH-3714 / BH-3692.1), each rule carrying its evidence record.
#
# DRIVEN, NOT GREPPED: the real bin/rule-miner.sh runs in a scratch checkout
# ($T/co) against a scratch harness ($T/h). agent-call.sh is a stub that writes
# a fixed draft and keeps the prompt it was handed; gh clones and pushes to a
# local bare origin and records every `pr create`. Nothing leaves the box.
#
#   prompt   the prompt the session got carries the CLASS/EVIDENCE grammar and
#            lint-first numbering; the header and NO_RULE sentences are
#            byte-identical to origin/main's
#   next     NEXT counts main (D43) plus the open rules/mined-20260923 (D45)
#   split    (i) two creates, lint then judgement; (ii) the lint branch is off
#            main and holds only the lint rule plus its record; (iii) the
#            judgement branch stacks on it; (iv) body text; heads vs
#            RE_LINT_HEAD_RE; both URLs logged; seen.txt holds every id
#   v        a judgement-only week opens exactly one PR, on rules/mined-<d>;
#            a lint rule whose evidence is all invented is judgement/no evidence
#   partial  lint opens, judgement create fails: only the lint ids are seen,
#            one loud ALERTS line, rc 1
#   neg      the rule-recur call line and every block marker are intact
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "rule-miner-adopt.bh-3714-test: SKIPPED — jq missing"; exit 0; }
M="$DIR/bin/rule-miner.sh"
CLASSLIB="$DIR/bin/lib/rule-class.sh"
. "$DIR/bin/lib/rule-evidence.sh" || exit 1

H="$T/h"; CO="$T/co"; O="$T/origin.git"; S="$T/seed"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$H/bin/lib" "$H/catalog" "$CO/bin/lib" "$T/stub"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
: > "$H/fleet.conf"
cp "$M" "$DIR/bin/fleet-conf.sh" "$DIR/bin/rule-miner-digest.sh" "$DIR/bin/rule-recur.sh" "$CO/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$CLASSLIB" \
   "$DIR/bin/lib/rule-evidence.sh" "$DIR/bin/lib/gh-rest.sh" "$CO/bin/lib/"
cp "$DIR/catalog/context-budgets.json" "$H/catalog/"
DAY=$(date -u +%Y%m%d)  # determinism: ok the miner names its branches off the wall clock
LB="rules/mined-$DAY-lint"; JB="rules/mined-$DAY"

# The origin: main at D43 tracking tests/foo-test.sh, plus last week's
# unmerged rules/mined-20260923 at D45.
git init -q --bare "$O"; git init -q "$S"; mkdir -p "$S/prompts" "$S/tests"
printf '# discipline\n- **D42 A.** a\n- **D43 B.** b\n' > "$S/prompts/build-discipline.md"
echo 'exit 0' > "$S/tests/foo-test.sh"
g() { git -C "$S" -c user.name=t -c user.email=t@t "$@"; }
g add -A && g commit -qm main && g branch -M main && g push -q "$O" main
g checkout -qb rules/mined-20260923
printf -- '- **D44 C.** c\n- **D45 D.** d\n' >> "$S/prompts/build-discipline.md"
g commit -qam wk && g push -q "$O" rules/mined-20260923

# The drafting session: write $DRAFT_SRC as the draft, keep the prompt.
cat > "$CO/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s' "$6" > "$PROMPT_OUT"
cp "$DRAFT_SRC" "$(dirname "$5")/draft.md"
SH
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "repo clone") git clone -q --single-branch -b main "$ORIGIN" "$4"; exit $? ;;
  "pr list") exit 0 ;;
  "pr create")
    h=""; bf=""; a=("$@")
    for ((i = 0; i < ${#a[@]}; i++)); do
      case "${a[$i]}" in -H) h=${a[$((i+1))]} ;; --body-file) bf=${a[$((i+1))]} ;; esac
    done
    if [ "${GH_FAIL_JUDGEMENT:-0}" = 1 ] && [[ $h != *-lint ]]; then echo "HTTP 422: create refused" >&2; exit 1; fi
    n=$(( $(wc -l < "$CREATES" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$*" >> "$CREATES"; cp "$bf" "$CREATES.body$n"
    echo "https://github.com/example-org/cromford/pull/$((900 + n))"; exit 0 ;;
esac
[ "$1" = api ] && { printf 'HTTP/2 200\r\n\r\n[]\n'; exit 0; }
exit 1
SH
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"
chmod +x "$CO/bin/"*.sh "$T/stub/"*

TODAY=$(date -u +%Y-%m-%d)  # determinism: ok the miner's findings window is wall-clock
run() { # run <draft-file> [VAR=value ...] -> rc of the miner
  local src=$1; shift
  scratch_rm "$H/state/rule-mining"; mkdir -p "$H/state/rule-mining/manual"
  echo "lesson one" > "$H/state/rule-mining/manual/n1.md"
  echo "lesson two" > "$H/state/rule-mining/manual/n2.md"
  : > "$H/logs/findings.log"
  for k in 1 2 3; do
    printf '%s 12:00:00Z [x-os] ticket=TK-%s lens=general rule=D1 family=aaaaaaaaaaaa :: same finding\n' "$TODAY" "$k" >> "$H/logs/findings.log"
  done
  : > "$H/logs/rule-miner.log"; : > "$H/logs/ALERTS.log"; : > "$T/creates"; rm -f "$T/creates.body"*
  git --git-dir="$O" for-each-ref --format='%(refname)' "refs/heads/rules/mined-$DAY*" \
    | while read -r r; do git --git-dir="$O" update-ref -d "$r"; done
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    "$@" PATH="$T/stub:$PATH" HARNESS="$H" ORIGIN="$O" CREATES="$T/creates" GH_ETAG=0 \
    DRAFT_SRC="$src" PROMPT_OUT="$T/prompt.txt" bash "$CO/bin/rule-miner.sh" > "$T/stdout" 2>"$T/stderr"
}
ev() { git --git-dir="$O" show "$1:prompts/rule-evidence/$2.json" > "$T/ev.json" 2>/dev/null; re_field "$T/ev.json" "$3" 2>/dev/null; }
SEENF="$H/state/rule-mining/seen.txt"

cat > "$T/draft-split" <<EOF
## Mined $TODAY (rule-miner)
- **D46 Keep the foo suite green.** tests/foo-test.sh fails any diff that breaks foo; run it.
  CLASS: lint tests/foo-test.sh
  EVIDENCE: manual:n1, findings:aaaaaaaaaaaa
- **D47 Think before you ship.** A reviewer has to judge this one.
  CLASS: judgement
  EVIDENCE: manual:n2
EOF

# ── split ────────────────────────────────────────────────────────────────────
run "$T/draft-split"; rc=$?
eq "split rc" "$rc" 0
eq "(i) two pr creates" "$(wc -l < "$T/creates" | tr -d ' ')" 2
grep -q -- "-H $LB " <(sed -n 1p "$T/creates") && ok || bad "(i) first create is not -H $LB: $(sed -n 1p "$T/creates")"
grep -q -- "-H $JB " <(sed -n 2p "$T/creates") && ok || bad "(i) second create is not -H $JB: $(sed -n 2p "$T/creates")"
grep -q -- "-B main" <(sed -n 1p "$T/creates") && ok || bad "(i) lint PR does not target main"
grep -qF -- "-t rules: lint-backed, mined week of $DAY" "$T/creates" && ok || bad "(i) lint PR title"

eq "(ii) lint diff files" "$(git --git-dir="$O" diff --name-only main "$LB" | sort | tr '\n' ' ')" \
  "prompts/build-discipline.md prompts/rule-evidence/D46.json "
ADD=$(git --git-dir="$O" diff main "$LB" -- prompts/build-discipline.md | grep '^+[^+]')
grep -q 'D46 Keep the foo suite green' <<<"$ADD" && ok || bad "(ii) lint diff lacks D46"
grep -q 'D47' <<<"$ADD" && bad "(ii) lint diff carries the judgement rule D47" || ok
grep -qE 'CLASS:|EVIDENCE:' <<<"$ADD" && bad "(ii) tag lines were not stripped: $ADD" || ok
grep -qF '(Evidence: manual:n1, findings:aaaaaaaaaaaa; check: tests/foo-test.sh)' <<<"$ADD" \
  && ok || bad "(ii) the Evidence/check suffix is missing: $ADD"
eq "(ii) D46 class" "$(ev "$LB" D46 .class)" lint-backed
eq "(ii) D46 check" "$(ev "$LB" D46 .check)" tests/foo-test.sh
eq "(ii) D46 incidents" "$(ev "$LB" D46 '.incidents|join(",")')" "manual:n1,findings:aaaaaaaaaaaa"
eq "(ii) D46 families" "$(ev "$LB" D46 '.families|join(",")')" aaaaaaaaaaaa
eq "(ii) D46 source" "$(ev "$LB" D46 .source)" "manual+findings"
eq "(ii) lint committer" "$(git --git-dir="$O" log -1 --format='%an <%ae>' "$LB")" "rule-miner <harness@box>"

git --git-dir="$O" merge-base --is-ancestor "$LB" "$JB" && ok || bad "(iii) $JB is not stacked on $LB"
eq "(iii) judgement extra files" "$(git --git-dir="$O" diff --name-only "$LB" "$JB" | sort | tr '\n' ' ')" \
  "prompts/build-discipline.md prompts/rule-evidence/D47.json "
JADD=$(git --git-dir="$O" diff "$LB" "$JB" -- prompts/build-discipline.md | grep '^+[^+]')
grep -q 'D47 Think before you ship' <<<"$JADD" && ok || bad "(iii) judgement diff lacks D47"
grep -qF '(Evidence: manual:n2; check: none)' <<<"$JADD" && ok || bad "(iii) judgement suffix: $JADD"
eq "(iii) D47 class" "$(ev "$JB" D47 .class)" judgement
eq "(iii) D47 reason" "$(ev "$JB" D47 .reason)" "tagged judgement"
eq "(iii) D47 check is null" "$(ev "$JB" D47 .check)" null

LBODY="$T/creates.body1"; JBODY="$T/creates.body2"
grep -q 'harness build' "$LBODY" "$JBODY" && bad "(iv) a body carries 'harness build'" || ok
grep -q 'lead MERGE stands on its head' "$LBODY" && ok || bad "(iv) lint body does not name the lead lane"
grep -qF -- '- D46: check `tests/foo-test.sh`; evidence manual:n1, findings:aaaaaaaaaaaa; record `prompts/rule-evidence/D46.json`' "$LBODY" \
  && ok || bad "(iv) lint body per-rule line: $(grep 'D46' "$LBODY")"
grep -qF "**For the operator's approval: the miner never merges.**" "$JBODY" && ok || bad "(iv) judgement body lost the approval sentence"
grep -qF 'Nothing merges these without a human' "$JBODY" && ok || bad "(iv) judgement body lacks the no-human line"
grep -qF 'stacked on the lint-backed PR https://github.com/example-org/cromford/pull/901' "$JBODY" \
  && ok || bad "(iv) judgement body does not name the lint PR it stacks on"
[[ $LB =~ $RE_LINT_HEAD_RE ]] && ok || bad "(iv) $LB does not match RE_LINT_HEAD_RE"
[[ $JB =~ $RE_LINT_HEAD_RE ]] && bad "(iv) $JB matches RE_LINT_HEAD_RE" || ok
L="$H/logs/rule-miner.log"
grep -qE 'pull/901.*pull/902|pull/902.*pull/901' "$L" && ok || bad "split: no log line names both URLs: $(cat "$L")"
grep -q 'classified: 1 lint-backed, 1 judgement' "$L" && ok || bad "split: no classified line"
eq "split stdout" "$(cat "$T/stdout")" "https://github.com/example-org/cromford/pull/901
https://github.com/example-org/cromford/pull/902"
for id in manual:n1 manual:n2 findings:aaaaaaaaaaaa; do
  grep -qxF "$id" "$SEENF" && ok || bad "split: $id not marked seen"
done
[ -s "$H/logs/ALERTS.log" ] && bad "split: ALERTS written: $(cat "$H/logs/ALERTS.log")" || ok

# ── next (same run) ──────────────────────────────────────────────────────────
grep -q 'NEXT=D46 (main + 1 open rules/mined-\* branch(es))' "$L" && ok || bad "next: NEXT log line: $(grep NEXT "$L")"
grep -q 'numbered consecutively starting at D46' "$T/prompt.txt" && ok || bad "next: prompt does not start at D46"

# ── prompt (same run: the prompt the session actually got) ───────────────────
P=$(cat "$T/prompt.txt")
for s in "CLASS: lint <repo-relative path of the check>" "CLASS: judgement" "EVIDENCE: <incident id>" \
         "Number the CLASS: lint rules FIRST" "ALREADY exists on main under bin/, tests/, guardrails/, checks/ or .github/workflows/"; do
  grep -qF "$s" <<<"$P" && ok || bad "prompt lacks: $s"
done
HDR="a markdown section starting with the exact header line '## Mined \$(date -u +%Y-%m-%d) (rule-miner)'"
NOR="EITHER a first line that is exactly NO_RULE followed by one short line per rejected incident saying why it is weather"
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null; then
  git -C "$DIR" show origin/main:bin/rule-miner.sh > "$T/main-miner.sh"
  for s in "$HDR" "$NOR"; do
    grep -qF "$s" "$T/main-miner.sh" && ok || bad "prompt fixture: origin/main lacks: $s"
    grep -qF "$s" "$M" && ok || bad "prompt: sentence changed from origin/main: $s"
  done
else
  bad "prompt: no origin/main to compare the header and NO_RULE sentences with"
fi
grep -qF "the exact header line '## Mined $TODAY (rule-miner)'" <<<"$P" && ok || bad "prompt: expanded header sentence missing"

# ── v + no-evidence: a judgement-only week ───────────────────────────────────
cat > "$T/draft-judg" <<EOF
## Mined $TODAY (rule-miner)
- **D46 Use the missing check.** bin/does-not-exist.sh enforces it.
  CLASS: lint bin/does-not-exist.sh
  EVIDENCE: manual:n1
- **D47 Keep foo green.** tests/foo-test.sh catches it.
  CLASS: lint tests/foo-test.sh
  EVIDENCE: invented:1
EOF
run "$T/draft-judg"; rc=$?
eq "v rc" "$rc" 0
eq "v exactly one create" "$(wc -l < "$T/creates" | tr -d ' ')" 1
grep -q -- "-H $JB " "$T/creates" && ok || bad "v create is not on $JB: $(cat "$T/creates")"
git --git-dir="$O" rev-parse -q --verify "refs/heads/$LB" >/dev/null && bad "v a lint branch was pushed" || ok
eq "v D46 reason" "$(ev "$JB" D46 .reason)" "check not tracked on main"
eq "no-evidence D47 class" "$(ev "$JB" D47 .class)" judgement
eq "no-evidence D47 reason" "$(ev "$JB" D47 .reason)" "no evidence"
eq "no-evidence D47 incidents" "$(ev "$JB" D47 '.incidents|length')" 0
grep -qF '(Evidence: none; check: none)' <(git --git-dir="$O" show "$JB:prompts/build-discipline.md") \
  && ok || bad "no-evidence: suffix must say Evidence: none"
grep -q 'dropped 1 id(s).*invented:1' "$H/logs/rule-miner.log" "$T/stderr" && ok || bad "no-evidence: the drop was not counted"

# ── partial: lint opens, judgement fails ─────────────────────────────────────
run "$T/draft-split" GH_FAIL_JUDGEMENT=1; rc=$?
eq "partial rc" "$rc" 1
grep -qxF manual:n1 "$SEENF" && ok || bad "partial: lint id manual:n1 not seen"
grep -qxF findings:aaaaaaaaaaaa "$SEENF" && ok || bad "partial: lint id findings:aaaaaaaaaaaa not seen"
grep -qxF manual:n2 "$SEENF" && bad "partial: judgement id manual:n2 was marked seen" || ok
eq "partial one ALERTS line" "$(grep -c "PR STEP FAILED at 'gh pr create'" "$H/logs/ALERTS.log")" 1
eq "partial lint PR still opened" "$(wc -l < "$T/creates" | tr -d ' ')" 1

# ── neg: untouched lines and markers ─────────────────────────────────────────
grep -qxF '  "$SELF/rule-recur.sh" "$FINDINGS" "$HARNESS/prompts/rule-evidence" || true' "$M" && ok || bad "neg: DRY rule-recur line changed"
grep -qxF '  "$SELF/rule-recur.sh" "$FINDINGS" "$HARNESS/prompts/rule-evidence" >> "$LOG" 2>&1 || true' "$M" && ok || bad "neg: rule-recur line changed"
for mk in '# >>> pr body' '# <<< pr body' '# >>> pr steps' '# <<< pr steps' '# >>> lint pr' '# <<< lint pr'; do
  eq "neg marker '$mk' once" "$(grep -cxF "$mk" "$M")" 1
done

echo "rule-miner-adopt.bh-3714-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
