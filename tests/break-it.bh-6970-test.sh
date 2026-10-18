#!/bin/bash
# tests/break-it.bh-6970-test.sh — BH-6970 (BH-6544.4): the break-it verifier.
# After the lead verdict, ONE bounded model call (route review-break-it) writes
# at most break_it.max_tests cases against a medium or high head; they run at
# the head and the result (clean | failed:<k> | could-not-run) rides to the
# verdict row. Fixture model answers only (tests/fixtures/break-it.bh-6970/),
# no live call.
#
#   part U  "$SRC/bin/lib/break-it.sh" against a scratch repo, with stub
#           setting_get / model_for / gh_rest and a stub bin/agent-call.sh:
#     B1  enforce, medium, 3 cases, 1 fails: failed:1; the PUT carries the test
#         path, the branch and the file as base64; the review out ends with a
#         `- [BLOCK wrong-data] break-it:` line naming the case and `VERDICT:
#         BLOCK`; the prompt holds break-it.md verbatim, the acceptance tests and
#         the diff; the call env has role review-break-it, the budget, stage
#         lead-head, the ~breakit fp and no tools. B1f a fork and a moved head
#         commit nothing and still BLOCK, saying why.
#     B2  all pass: clean, no PUT, the file is not left in the worktree. A run
#         that prints 2 result lines for 3 cases: could-not-run.
#     B3  the same head twice: one call; the second prints the replayed word.
#     B4  review-tier:low: skipped:low, 0 calls; no tier: skipped:unclassified.
#     B5  shadow, 1 fails: failed:1, no PUT, the out file is byte-identical.
#     B6  the runner times out (a `timeout` that exits 124): could-not-run, no
#         BLOCK, no PUT. A repo with no framework: could-not-run, 0 calls. No
#         lane-alert call in either case.
#     B7  6 cases: 5 bi_case_ functions in the file (break_it.max_tests unset).
#     E1  agent-call rc 75: could-not-run and no replay file; the next run calls.
#     E2  a garbage answer and a 0-case answer: could-not-run, replayed (paid).
#     T-tier  the decision table: tier and mode.
#     T-area  the framework table (worker/jobs, console-ui, tie, none) and the
#         node runner (2 cases, 1 fails = failed:1; a bad import = could-not-run).
#     X1  a setpriv that cannot switch to nobody: could-not-run, no case runs,
#         no BLOCK, recorded (paid); no snapshot dir left (security review).
#     X2  root with setpriv only: the cases run as nobody, cannot read a 0600
#         root file, cannot write the review worktree, see no HARNESS/GH_TOKEN.
#   part R  "$SRC/bin/lead-review.sh" tick, whole, with curl, gh and agent-call
#           stubbed (the BH-6967 part B harness):
#     R1  shadow + `review-tier:medium review-mode:full`: two calls (lead.review,
#         review-break-it), the result POST detail holds break-it:failed:1, the
#         report has the `- break-it (BH-6970):` line above `- pr body:`, the
#         verdict is the model's MERGE. No break_it.mode row: one call, no
#         break-it in the detail, no report line.
#     R2  enforce: the verdict is BLOCK, the report carries the [BLOCK wrong-data]
#         finding, the PUT went to the PR branch.
#   part L  "$SRC/bin/lead-review-land.sh": the detail table becomes --break-it.
#   part P  "$SRC/bin/lead-verdict.sh" post --break-it: a bad value is rc 2 and
#           no POST; a good value is in the body; no flag, no key.
#   part S  S1 the composed schema: five break_it.* rows and a two-rung
#           review-break-it ladder (rung 1 = lead.review rung 0); a re-apply
#           changes nothing; a model_route_changes row means no seed.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/break-it.bh-6970-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/break-it.bh-6970"
LIB="$SRC/bin/lib/break-it.sh"
PROMPT="$SRC/prompts/lead-review.d/break-it.md"
SEED="$SRC/worker/jobs/schema.d/202610171749-bh-6970-break-it.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_ROW_NOTE AGENT_CALL_ROLE AGENT_CALL_BUDGET_USD AGENT_CALL_NO_TOOLS \
  LEAD_REVIEW_BUILDS_ON_BUILDER HARNESS_VERDICT_AUTHORS HARNESS_OPERATOR_LOGIN BOX_NAME JOBS_BOX HUB_BOX_NAME

[ -f "$LIB" ] && ok || bad "U0 bin/lib/break-it.sh does not exist"
[ -f "$PROMPT" ] && grep -q '"cases"' "$PROMPT" && ok || bad "U0 prompts/lead-review.d/break-it.md is missing or has no answer contract"

# ── the scratch repo: bin/greet.sh claims `hello world` with no name, prints `hello ` ──
ORIG="$T/origin.git"; WK="$T/work"
git init -q --bare -b main "$ORIG"; git init -q -b main "$WK"
mkdir -p "$WK/bin" "$WK/tests" "$WK/worker/jobs/src" "$WK/worker/jobs/test" "$WK/console-ui/src" "$WK/console-ui/tests"
printf '#!/bin/bash\necho "hi $1"\n' > "$WK/bin/greet.sh"
printf '#!/bin/bash\nexit 0\n' > "$WK/tests/base-test.sh"
printf '{"type":"module"}\n' > "$WK/worker/jobs/package.json"
printf 'export const add = (a, b) => a + b;\n' > "$WK/worker/jobs/src/add.js"
printf '// keep\n' > "$WK/worker/jobs/test/keep.test.js"; printf '// keep\n' > "$WK/console-ui/tests/keep.test.js"
printf 'export const a = 1;\n' > "$WK/console-ui/src/a.js"
git -C "$WK" add -A; git -C "$WK" commit -qm base; git -C "$WK" push -q "$ORIG" main
# h_shell: the greet change (one bin/ file)
printf '#!/bin/bash\n# greet <name>: hello <name>; no name says hello world\necho "hello ${1}"\n' > "$WK/bin/greet.sh"
git -C "$WK" commit -qam "BH-9001: greet"; HS=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$ORIG" "HEAD:refs/heads/h-shell"
# h_worker: two worker/jobs files and one bin file -> node in worker/jobs
git -C "$WK" checkout -q -b h-worker main
printf 'export const add = (a, b) => a + b; // sum\n' > "$WK/worker/jobs/src/add.js"; printf 'export const sub = (a, b) => a - b;\n' > "$WK/worker/jobs/src/sub.js"
printf '#!/bin/bash\necho "hey $1"\n' > "$WK/bin/greet.sh"
git -C "$WK" add -A; git -C "$WK" commit -qm worker; HW=$(git -C "$WK" rev-parse HEAD); git -C "$WK" push -q "$ORIG" h-worker
# h_console: two console-ui files and one bin file -> node in console-ui
git -C "$WK" checkout -q -b h-console main
printf 'export const a = 2;\n' > "$WK/console-ui/src/a.js"; printf 'export const b = 1;\n' > "$WK/console-ui/src/b.js"
printf '#!/bin/bash\necho "yo $1"\n' > "$WK/bin/greet.sh"
git -C "$WK" add -A; git -C "$WK" commit -qm console; HC=$(git -C "$WK" rev-parse HEAD); git -C "$WK" push -q "$ORIG" h-console
# h_tie: one worker/jobs file, one bin file -> shell
git -C "$WK" checkout -q -b h-tie main
printf 'export const add = (a, b) => b + a;\n' > "$WK/worker/jobs/src/add.js"; printf '#!/bin/bash\necho "ho $1"\n' > "$WK/bin/greet.sh"
git -C "$WK" add -A; git -C "$WK" commit -qm tie; HT=$(git -C "$WK" rev-parse HEAD); git -C "$WK" push -q "$ORIG" h-tie
WT="$T/wt"; git clone -q "$ORIG" "$WT"; git -C "$WT" fetch -q origin h-shell h-worker h-console h-tie
# a repo with no known framework (no tests/*-test.sh, no worker/jobs, no console-ui)
NORIG="$T/norigin.git"; NWK="$T/nwork"; git init -q --bare -b main "$NORIG"; git init -q -b main "$NWK"
mkdir -p "$NWK/src"; printf 'a\n' > "$NWK/src/a.txt"; git -C "$NWK" add -A; git -C "$NWK" commit -qm base; git -C "$NWK" push -q "$NORIG" main
printf 'b\n' > "$NWK/src/a.txt"; git -C "$NWK" commit -qam change; HN=$(git -C "$NWK" rev-parse HEAD); git -C "$NWK" push -q "$NORIG" "HEAD:refs/heads/h"
NWT="$T/nwt"; git clone -q "$NORIG" "$NWT"; git -C "$NWT" fetch -q origin h; git -C "$NWT" checkout -q --detach "$HN"

# ═══════════════════════ part U: bin/lib/break-it.sh ═══════════════════════
UH="$T/uh"; mkdir -p "$UH/bin" "$UH/prompts/lead-review.d" "$UH/state" "$T/log" "$T/set" "$T/tbin"
cp "$PROMPT" "$UH/prompts/lead-review.d/" 2>/dev/null
cat > "$UH/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/calls"
env | grep '^AGENT_CALL_' | sort > "$T/log/env"
cp "\${6#@}" "$T/log/prompt"
cat "$T/answer" > "\$5" 2>/dev/null
exit "\$(cat "$T/acrc" 2>/dev/null || echo 0)"
EOF
cat > "$UH/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/alerts"
EOF
chmod +x "$UH/bin/agent-call.sh" "$UH/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 124\n' > "$T/tbin/timeout"; chmod +x "$T/tbin/timeout"
HARNESS="$UH"; H="$UH"
setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }
model_for() { [ -e "$T/no-route" ] && return 75; [ "$1" = review-break-it ] && echo fixture-breakit-model; }
log() { echo "$*" >> "$T/log/lane"; }
# gh_rest: the PR (head and branch from $T/pr-head and $T/pr-repo), no file on the
# branch yet, and a PUT that answers a commit.
gh_rest() {
  echo "$1 $2" >> "$T/log/gh"
  case "$1 $2" in
    "GET repos/example-org/demo-os/pulls/77")
      jq -nc --arg s "$(cat "$T/pr-head")" --arg r "$(cat "$T/pr-repo")" '{head:{sha:$s,ref:"ticket/bh-9001",repo:{full_name:$r}}}' ;;
    "GET repos/example-org/demo-os/contents/"*) return 44 ;;
    "PUT repos/example-org/demo-os/contents/"*) cp "$4" "$T/log/put.json"; echo "$2" > "$T/log/put.path"
      printf '{"commit":{"sha":"%s"}}\n' "$(printf 'c%.0s' {1..40})" ;;
    *) return 75 ;;
  esac
}
# shellcheck source=bin/lib/break-it.sh
. "$LIB" 2>/dev/null || bad "U0 bin/lib/break-it.sh does not source"
# The ticket body: an Acceptance tests section the prompt must carry.
jq -nc '{body:"## Scope\nGreet.\n\n## Acceptance tests\n- G1 no name prints hello world\n\n## Out of scope\nNothing."}' > "$T/issue.json"
printf 'BH-9001: greet\n' > "$T/body.md"
OUTF="$T/review.out"
reset_u() { # reset_u <answer fixture> <mode|-> — a clean slate for one bi_review
  scratch_rm "$UH/state/break-it"; scratch_rm "$T/wt.bi"; rm -f "$T/log/"*; mkdir -p "$T/log"
  rm -f "$T/acrc" "$T/no-route" "$T/set/"*
  cp "$FX/$1" "$T/answer"
  [ "$2" = - ] || printf '%s' "$2" > "$T/set/break_it.mode"
  printf '%s' "$HS" > "$T/pr-head"; printf 'example-org/demo-os' > "$T/pr-repo"
  printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$OUTF"
  git -C "$WT" checkout -q --detach "${3:-$HS}"
}
NOTES_MED="auto: builder APPROVE on x; review-tier:medium review-mode:full"
review() { # review <head> <notes> -> BIR (the one output line)
  BIR=$(bi_review example-org/demo-os 77 "$1" demo-os "$WT" main "$2" "BH-9001: greet" "$OUTF" 600 "$T/issue.json" "$T/body.md")
}
calls() { [ -f "$T/log/calls" ] && wc -l < "$T/log/calls" | tr -d ' ' || echo 0; }
REPLAY="$UH/state/break-it/example-org_demo-os-77-$HS.result"

# The run drops to nobody through setpriv (security review). Where this suite
# can do that for real (root, setpriv, a nobody user), every run below does.
# Elsewhere (CI runs as a plain user) a stub setpriv drops the switch flags, a
# stub chown does nothing and a stub id answers this user for nobody, so the
# probe and the run go through and the cases still decide. X1 and X2 pin the drop.
REAL_ID=$(command -v id)
ISO=0
if [ "$(id -u)" = 0 ] && command -v setpriv > /dev/null 2>&1 && id nobody > /dev/null 2>&1 \
   && setpriv --reuid="$(id -u nobody)" --regid="$(id -g nobody)" --clear-groups true > /dev/null 2>&1; then
  ISO=1
else
  mkdir -p "$T/isobin"
  printf '#!/bin/bash\nwhile [ "$#" -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done\nexec "$@"\n' > "$T/isobin/setpriv"
  printf '#!/bin/bash\nexit 0\n' > "$T/isobin/chown"
  printf '#!/bin/bash\ncase "$*" in "-u nobody") exec %s -u ;; "-g nobody") exec %s -g ;; *) exec %s "$@" ;; esac\n' "$REAL_ID" "$REAL_ID" "$REAL_ID" > "$T/isobin/id"
  chmod +x "$T/isobin/setpriv" "$T/isobin/chown" "$T/isobin/id"
  PATH="$T/isobin:$PATH"; export PATH
  echo "note: no real setpriv drop here; a stub setpriv runs the cases as $(id -un) and X2 is skipped"
fi

# ── B1 enforce, medium, 3 cases, 1 fails ──
reset_u three-cases.txt enforce; review "$HS" "$NOTES_MED"
[ "$BIR" = "failed:1 enforce 1" ] && ok || bad "B1 bi_review printed '$BIR', want 'failed:1 enforce 1': $(cat "$T/log/lane" 2>/dev/null)"
[ "$(calls)" = 1 ] && ok || bad "B1 $(calls) agent call(s), want 1"
grep -qx 'AGENT_CALL_ROLE=review-break-it' "$T/log/env" && ok || bad "B1 the call role is not review-break-it: $(cat "$T/log/env" 2>/dev/null)"
grep -qx 'AGENT_CALL_BUDGET_USD=1.50' "$T/log/env" && ok || bad "B1 the call budget is not the 1.50 fallback"
grep -qx 'AGENT_CALL_GUARD_STAGE=lead-head' "$T/log/env" && ok || bad "B1 the call guard stage is not lead-head"
grep -qx "AGENT_CALL_FP=lead:example-org/demo-os#77@$HS~breakit" "$T/log/env" && ok || bad "B1 the call fp: $(grep FP "$T/log/env")"
grep -qx 'AGENT_CALL_NO_TOOLS=1' "$T/log/env" && ok || bad "B1 the call has tools"
case "$(cat "$T/log/calls" 2>/dev/null)" in "break-it demo-os fixture-breakit-model 600 "*) ok ;; *) bad "B1 agent-call args: $(cat "$T/log/calls" 2>/dev/null)" ;; esac
P="$T/log/prompt"
n=$(wc -l < "$PROMPT"); head -n "$n" "$P" 2>/dev/null | cmp -s - "$PROMPT" && ok || bad "B1 the prompt does not start with break-it.md verbatim"
grep -qxF -- '- G1 no name prints hello world' "$P" && ok || bad "B1 the prompt lacks the ticket's acceptance tests"
grep -qxF 'Nothing.' "$P" && bad "B1 the prompt carries the section after Acceptance tests" || ok
grep -qxF -- '+echo "hello ${1}"' "$P" && ok || bad "B1 the prompt lacks the diff"
grep -qxF -- '- at most 5 cases' "$P" && grep -qxF -- '- framework: shell' "$P" && ok || bad "B1 the prompt lacks the limits"
[ "$(cat "$T/log/put.path" 2>/dev/null)" = "repos/example-org/demo-os/contents/tests/bh-9001-breakit-test.sh" ] && ok || bad "B1 PUT path: $(cat "$T/log/put.path" 2>/dev/null)"
[ "$(jq -r .branch "$T/log/put.json" 2>/dev/null)" = ticket/bh-9001 ] && ok || bad "B1 the PUT is not on the PR branch"
jq -r .content "$T/log/put.json" 2>/dev/null | base64 -d > "$T/put.file" 2>/dev/null
grep -q '^bi_case_2() {' "$T/put.file" && grep -q 'hello world' "$T/put.file" && ok || bad "B1 the PUT content is not the test file"
grep -q "^- \[BLOCK wrong-data\] break-it: tests/bh-9001-breakit-test.sh failed 1 of 3 case(s): c2 no name says hello world\. Test file committed to the PR branch as cccccccccccc\." "$OUTF" \
  && ok || bad "B1 the review out lacks the BLOCK line: $(cat "$OUTF")"
grep -q '^got: hello' "$OUTF" && ok || bad "B1 the BLOCK lacks the compact output"
[ "$(awk 'NF { l = $0 } END { print l }' "$OUTF")" = "VERDICT: BLOCK" ] && ok || bad "B1 the out does not end VERDICT: BLOCK"
[ "$(grep -c '^VERDICT:' "$OUTF")" = 1 ] && ok || bad "B1 the out has more than one VERDICT line"
[ -e "$WT/tests/bh-9001-breakit-test.sh" ] && bad "B1 the test file is left in the worktree" || ok
[ -s "${REPLAY%.result}.file" ] && ok || bad "B1 the failing file is not kept in state/break-it"
[ "$(head -n 1 "$REPLAY" 2>/dev/null)" = failed:1 ] && ok || bad "B1 the replay file does not say failed:1"

# ── B1f a fork, and a head that moved: nothing committed, the BLOCK stands ──
reset_u three-cases.txt enforce; printf 'someone/demo-os' > "$T/pr-repo"; review "$HS" "$NOTES_MED"
[ "$BIR" = "failed:1 enforce 1" ] && ok || bad "B1f fork: '$BIR'"
[ -e "$T/log/put.json" ] && bad "B1f a fork branch got a PUT" || ok
grep -q 'Test file not committed: the PR branch is in a fork\.' "$OUTF" && ok || bad "B1f the BLOCK does not say fork: $(grep BLOCK "$OUTF")"
reset_u three-cases.txt enforce; printf '%s' "$HW" > "$T/pr-head"; review "$HS" "$NOTES_MED"
[ -e "$T/log/put.json" ] && bad "B1f a moved head got a PUT" || ok
grep -q "Test file not committed: the PR head moved off ${HS:0:12}\." "$OUTF" && ok || bad "B1f the BLOCK does not say the head moved"

# ── B2 all pass: clean, no PUT, no file left; 2 result lines for 3 cases ──
reset_u all-pass.txt enforce; review "$HS" "$NOTES_MED"
[ "$BIR" = "clean enforce 0" ] && ok || bad "B2 '$BIR', want 'clean enforce 0': $(cat "$T/log/lane" 2>/dev/null)"
[ -e "$T/log/put.json" ] && bad "B2 a clean run made a PUT" || ok
[ -e "$WT/tests/bh-9001-breakit-test.sh" ] && bad "B2 the passing file is left in the worktree" || ok
[ -e "${REPLAY%.result}.file" ] && bad "B2 a passing file is kept" || ok
cmp -s "$OUTF" <(printf 'Findings\n- none\n\nVERDICT: MERGE\n') && ok || bad "B2 a clean run changed the review out"
reset_u short-run.txt enforce; review "$HS" "$NOTES_MED"
[ "$BIR" = "could-not-run enforce 0" ] && ok || bad "B2 short run: '$BIR', want could-not-run"
grep -q '2 result line(s) for 3 case(s)' "$T/log/lane" && ok || bad "B2 the short run is not logged: $(cat "$T/log/lane" 2>/dev/null)"

# ── B3 the same head twice: one call ──
reset_u three-cases.txt shadow; review "$HS" "$NOTES_MED"; review "$HS" "$NOTES_MED"
[ "$(calls)" = 1 ] && ok || bad "B3 $(calls) calls for one head, want 1"
[ "$BIR" = "failed:1 shadow 0" ] && ok || bad "B3 the replay printed '$BIR'"
grep -q 'replayed failed:1; no call' "$T/log/lane" && ok || bad "B3 no replay line"

# ── B4 low tier and no tier: no run ──
reset_u three-cases.txt enforce; review "$HS" "auto: x; review-tier:low review-mode:full"
[ "$BIR" = "skipped:low enforce 0" ] && [ "$(calls)" = 0 ] && ok || bad "B4 low: '$BIR', $(calls) call(s)"
reset_u three-cases.txt enforce; review "$HS" "auto: builder APPROVE on x"
[ "$BIR" = "skipped:unclassified enforce 0" ] && [ "$(calls)" = 0 ] && ok || bad "B4 no tier: '$BIR', $(calls) call(s)"
[ -d "$UH/state/break-it" ] && [ -n "$(ls -A "$UH/state/break-it" 2>/dev/null)" ] && bad "B4 a skipped run wrote a replay file" || ok

# ── B5 shadow, 1 fails: recorded, nothing posted ──
reset_u three-cases.txt shadow; cp "$OUTF" "$T/out.before"; review "$HS" "$NOTES_MED"
[ "$BIR" = "failed:1 shadow 0" ] && ok || bad "B5 '$BIR', want 'failed:1 shadow 0'"
cmp -s "$OUTF" "$T/out.before" && ok || bad "B5 shadow changed the review out"
[ -e "$T/log/put.json" ] || [ -e "$T/log/gh" ] && bad "B5 shadow talked to GitHub: $(cat "$T/log/gh" 2>/dev/null)" || ok

# ── B6 a timeout, and a repo with no framework ──
reset_u three-cases.txt enforce; PATH="$T/tbin:$PATH" review "$HS" "$NOTES_MED"
[ "$BIR" = "could-not-run enforce 0" ] && ok || bad "B6 timeout: '$BIR'"
grep -q 'the run timed out after 300s' "$T/log/lane" && ok || bad "B6 the timeout is not read as a timeout: $(cat "$T/log/lane" 2>/dev/null)"
grep -q 'BLOCK' "$OUTF" && bad "B6 a timeout made a BLOCK" || ok
[ -e "$T/log/put.json" ] && bad "B6 a timeout made a PUT" || ok
[ "$(head -n 1 "$REPLAY" 2>/dev/null)" = could-not-run ] && ok || bad "B6 a paid timeout is not recorded"
reset_u three-cases.txt enforce
BIR=$(bi_review example-org/demo-os 77 "$HN" demo-os "$NWT" main "$NOTES_MED" "BH-9001: x" "$OUTF" 600 - -)
[ "$BIR" = "could-not-run enforce 0" ] && [ "$(calls)" = 0 ] && ok || bad "B6 no framework: '$BIR', $(calls) call(s)"
[ -e "$T/log/alerts" ] && bad "B6 a break-it failure paged: $(cat "$T/log/alerts")" || ok

# ── B7 6 cases: 5 kept ──
reset_u six-cases.txt shadow; review "$HS" "$NOTES_MED"
[ "$BIR" = "clean shadow 0" ] && ok || bad "B7 '$BIR'"
[ "$(grep -c '^bi_case_[0-9]*() {' "$T/wt.bi/break-it.file" 2>/dev/null)" = 5 ] && ok || bad "B7 the file has $(grep -c '^bi_case_' "$T/wt.bi/break-it.file" 2>/dev/null) cases, want 5"
grep -q '6 cases, kept 5' "$T/log/lane" && ok || bad "B7 no kept line"
reset_u six-cases.txt shadow; printf ' 2 ' > "$T/set/break_it.max_tests"; review "$HS" "$NOTES_MED"
[ "$(grep -c '^bi_case_[0-9]*() {' "$T/wt.bi/break-it.file" 2>/dev/null)" = 2 ] && ok || bad "B7 break_it.max_tests=2 kept $(grep -c '^bi_case_' "$T/wt.bi/break-it.file" 2>/dev/null)"
reset_u six-cases.txt shadow; printf '0' > "$T/set/break_it.max_tests"; printf 'lots' > "$T/set/break_it.budget_usd"; review "$HS" "$NOTES_MED"
[ "$(grep -c '^bi_case_[0-9]*() {' "$T/wt.bi/break-it.file" 2>/dev/null)" = 5 ] && ok || bad "B7 break_it.max_tests=0 did not fall back to 5"
grep -qx 'AGENT_CALL_BUDGET_USD=1.50' "$T/log/env" && ok || bad "B7 a bad budget row did not fall back to 1.50"
reset_u six-cases.txt shadow; printf '0.75' > "$T/set/break_it.budget_usd"; review "$HS" "$NOTES_MED"
grep -qx 'AGENT_CALL_BUDGET_USD=0.75' "$T/log/env" && ok || bad "B7 the budget row 0.75 is not the call budget"

# ── E1 a refused call: no replay, the next run calls ──
reset_u three-cases.txt shadow; echo 75 > "$T/acrc"; review "$HS" "$NOTES_MED"
[ "$BIR" = "could-not-run shadow 0" ] && ok || bad "E1 rc 75: '$BIR'"
[ -e "$REPLAY" ] && bad "E1 a refused call wrote a replay file" || ok
rm -f "$T/acrc"; review "$HS" "$NOTES_MED"
[ "$(calls)" = 2 ] && [ "$BIR" = "failed:1 shadow 0" ] && ok || bad "E1 the next run: $(calls) call(s), '$BIR'"

# ── E2 a billed answer with no usable case: could-not-run, terminal ──
for fx in garbage.txt zero-cases.txt; do
  reset_u "$fx" enforce; review "$HS" "$NOTES_MED"
  [ "$BIR" = "could-not-run enforce 0" ] && ok || bad "E2 $fx: '$BIR'"
  [ "$(head -n 1 "$REPLAY" 2>/dev/null)" = could-not-run ] && ok || bad "E2 $fx: a paid unusable answer is not recorded"
  review "$HS" "$NOTES_MED"; [ "$(calls)" = 1 ] && ok || bad "E2 $fx: the head was paid twice"
done
# no route, and too little time: no call
reset_u three-cases.txt shadow; : > "$T/no-route"; review "$HS" "$NOTES_MED"
[ "$BIR" = "could-not-run shadow 0" ] && [ "$(calls)" = 0 ] && ok || bad "E2 no route: '$BIR', $(calls) call(s)"
reset_u three-cases.txt shadow
BIR=$(bi_review example-org/demo-os 77 "$HS" demo-os "$WT" main "$NOTES_MED" "BH-9001: greet" "$OUTF" 90 - -)
[ "$BIR" = "could-not-run shadow 0" ] && [ "$(calls)" = 0 ] && ok || bad "E2 90s left: '$BIR', $(calls) call(s)"

# ── T-tier: the run-or-skip decision table ──
while IFS='|' read -r mode notes want; do
  reset_u all-pass.txt "$mode"; review "$HS" "$notes"
  got=$(calls); [ "$got" = "$want" ] && ok || bad "T-tier mode '$mode' notes '$notes': $got call(s), want $want ($BIR)"
done <<'TABLE'
shadow|auto: x; review-tier:medium review-mode:full|1
shadow|auto: x; review-tier:high review-mode:full|1
enforce|auto: x; review-tier:medium review-mode:intent|1
 Shadow |auto: x; review-tier:high review-mode:full|1
shadow|auto: x; review-tier:low review-mode:full|0
shadow|auto: x|0
shadow|auto: x; review-tier:medium review-mode:full; other|0
shadow|auto: x; review-tier:mediumx review-mode:full|0
shadow|auto: x; review-tier:high review-mode:full; tail; review-tier:low review-mode:full|0
off|auto: x; review-tier:high review-mode:full|0
yes|auto: x; review-tier:high review-mode:full|0
-|auto: x; review-tier:high review-mode:full|0
TABLE

# ── T-area: the framework table, and the node runner ──
area() { BI_PATH=""; bi_area "$WT" main "$1" bh-9001 && echo "$BI_FW $BI_PATH $BI_RUNDIR" || echo none; }
[ "$(area "$HS")" = "shell tests/bh-9001-breakit-test.sh ." ] && ok || bad "T-area shell: $(area "$HS")"
[ "$(area "$HW")" = "node worker/jobs/test/bh-9001.breakit.test.js worker/jobs" ] && ok || bad "T-area worker: $(area "$HW")"
[ "$(area "$HC")" = "node console-ui/tests/bh-9001.breakit.test.js console-ui" ] && ok || bad "T-area console: $(area "$HC")"
[ "$(area "$HT")" = "shell tests/bh-9001-breakit-test.sh ." ] && ok || bad "T-area tie: $(area "$HT")"
bi_area "$NWT" main "$HN" bh-9001 && bad "T-area a repo with no framework has one" || ok
if command -v node >/dev/null 2>&1; then
  reset_u node-cases.txt shadow "$HW"; printf '%s' "$HW" > "$T/pr-head"; review "$HW" "$NOTES_MED"
  [ "$BIR" = "failed:1 shadow 0" ] && ok || bad "T-area node: '$BIR', want failed:1: $(cat "$T/log/lane" 2>/dev/null) $(head -c 600 "$T/wt.bi/break-it.txt" 2>/dev/null)"
  [ "$(cat "$T/wt.bi/break-it.failed" 2>/dev/null)" = "c2 adds a string and a number as numbers" ] && ok || bad "T-area node failing name: $(cat "$T/wt.bi/break-it.failed" 2>/dev/null)"
  grep -qF "import { add } from '../src/add.js';" "$T/wt.bi/break-it.file" && ok || bad "T-area node: the import is not in the file"
  grep -qxF -- '- framework: node' "$T/log/prompt" && ok || bad "T-area node: the prompt does not name node"
  [ -e "$WT/worker/jobs/test/bh-9001.breakit.test.js" ] && bad "T-area node: the file is left in the worktree" || ok
  for fx in node-bad-import.txt node-climb-import.txt; do
    reset_u "$fx" shadow "$HW"; review "$HW" "$NOTES_MED"
    [ "$BIR" = "could-not-run shadow 0" ] && ok || bad "T-area $fx: '$BIR', want could-not-run"
  done
else
  echo "note: node missing; the T-area node runner cases are skipped"
fi

# ── X1 a setpriv that cannot switch: could-not-run, no case runs (fail closed) ──
mkdir -p "$T/x1bin"
printf '#!/bin/bash\necho "setpriv: setgroups failed: Operation not permitted" >&2\nexit 127\n' > "$T/x1bin/setpriv"; chmod +x "$T/x1bin/setpriv"
reset_u three-cases.txt enforce; PATH="$T/x1bin:$PATH" review "$HS" "$NOTES_MED"
[ "$BIR" = "could-not-run enforce 0" ] && ok || bad "X1 a setpriv that cannot switch: '$BIR', want could-not-run"
grep -q 'setpriv cannot run the cases as nobody here' "$T/log/lane" && ok || bad "X1 the refusal is not logged: $(cat "$T/log/lane" 2>/dev/null)"
grep -q '^BREAKIT ' "$T/wt.bi/break-it.txt" 2>/dev/null && bad "X1 a case ran without the drop" || ok
grep -q 'BLOCK' "$OUTF" && bad "X1 a refused drop made a BLOCK" || ok
[ "$(head -n 1 "$REPLAY" 2>/dev/null)" = could-not-run ] && ok || bad "X1 the paid refused drop is not recorded"
[ -n "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'break-it.*' -newer "$T/answer" 2>/dev/null)" ] && bad "X1 a snapshot dir is left behind" || ok

# ── X2 (root only) the cases run as nobody: no root-only file, no worktree write ──
if [ "$ISO" = 1 ]; then
  printf 's3cret\n' > "$T/secret.env"; chmod 600 "$T/secret.env"
  reset_u all-pass.txt enforce
  jq -n --arg s "$T/secret.env" --arg w "$WT" '{framework:"shell",imports:[],cases:[
    {name:"runs as a user that is not root", body:"[ \"$(id -u)\" != 0 ]"},
    {name:"cannot read a root-only file", body:("! cat " + ($s | @sh) + " >/dev/null 2>&1")},
    {name:"cannot write the review worktree", body:("! touch " + ($w | @sh) + "/x2-mark 2>/dev/null")},
    {name:"inherits no harness env", body:"[ -z \"${HARNESS:-}\" ] && [ -z \"${GH_TOKEN:-}\" ]"}]}' > "$T/answer"
  HARNESS="$UH" GH_TOKEN=fixture-x2-token review "$HS" "$NOTES_MED"
  [ "$BIR" = "clean enforce 0" ] && ok || bad "X2 the cases did not run as nobody: '$BIR': $(cat "$T/wt.bi/break-it.txt" 2>/dev/null | head -n 8)"
  [ -e "$WT/x2-mark" ] && bad "X2 a case wrote the review worktree" || ok
else
  echo "note: no real setpriv drop here; X2 is skipped"
fi

# ═══════════════════════ part R: bin/lead-review.sh tick ═══════════════════════
unset -f setting_get model_for log gh_rest
unset HARNESS H
HB="$T/hb"; mkdir -p "$HB/bin" "$HB/prompts/lead-review.d" "$HB/catalog/lanes.d" "$HB/state" "$HB/env" "$T/brepos" "$T/bbin" "$T/rlog"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "\${AGENT_CALL_ROLE:-<unset>}" >> "$T/rlog/roles"
if [ "\${AGENT_CALL_ROLE:-}" = review-break-it ]; then cat "$FX/three-cases.txt" > "\$5"
else printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"; fi
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "R closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "R closure of bin/jobs-client.sh"
[ -f "$HB/bin/lib/break-it.sh" ] && ok || bad "R the closure of bin/lead-review.sh lacks bin/lib/break-it.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
# the review-level catalogs, so rl_cap (BH-7123) runs for real after the break-it block
cp "$SRC/catalog/review-always-block.tsv" "$SRC/catalog/review-nits.tsv" "$SRC/catalog/review-golive.tsv" "$HB/catalog/" 2>/dev/null
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$SRC/prompts/lead-review-builds-on.md" "$HB/prompts/"
cp "$PROMPT" "$HB/prompts/lead-review.d/" 2>/dev/null
echo box-demo > "$HB/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$HB/fleet.conf"
BLOG="$HB/logs/lead-review.log"
git -C "$WK" push -q "$ORIG" "$HS:refs/pull/77/head"
git clone -q "$ORIG" "$T/brepos/demo-os"
cat > "$T/bbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""; body=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/rlog/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/settings/break_it.mode")
    if [ -f "$T/rmode" ]; then out=\$(jq -nc --arg v "\$(cat "$T/rmode")" '{setting:{key:"break_it.mode",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
  "GET /api/model-routes/review-break-it"*) out='{"ladder":[{"position":0,"model":"fixture-breakit-model","runner":"claude"}],"source":"hub"}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"fixture-lead-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/bbin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/rlog/gh"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/reviews"*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$HS" '{state:"open",head:{sha:\$s,ref:"ticket/bh-9001",repo:{full_name:"example-org/demo-os"}},base:{ref:"main"},title:"BH-9001: greet",body:"BH-9001\n\n## Acceptance tests\n- G1 no name prints hello world\n"}' ;;
  *"-X GET repos/"*"/contents/"*) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
  *"-X PUT repos/"*"/contents/"*) printf 'HTTP/2 201\r\n\r\n{"commit":{"sha":"%s"}}\n' "$(printf 'd%.0s' {1..40})" ;;
esac
exit 0
EOF
chmod +x "$T/bbin/curl" "$T/bbin/gh"
# tick <tag> <scope notes> — one bin/lead-review.sh tick on PR 77 at $HS.
tick() {
  rm -f "$T/rlog/"*; scratch_rm "$HB/state/lead-reviews"; scratch_rm "$HB/state/lead-review"; scratch_rm "$HB/state/break-it"
  scratch_rm "$HB/state/model-routes"; mkdir -p "$HB/state/lead-reviews"; rm -f "$BLOG"
  jq -nc --arg s "$HS" --arg n "$2" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:77,head_sha:$s,
    scope_notes:$n,prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  ( cd "$T" && env PATH="$T/bbin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/brepos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HB/bin/lead-review.sh" tick ) > "$T/rout.$1" 2>&1
  cp "$HB/state/lead-reviews/lr-77-${HS:0:12}.md" "$T/report.$1" 2>/dev/null || : > "$T/report.$1"
  cp "$BLOG" "$T/rlane.$1" 2>/dev/null || : > "$T/rlane.$1"
  RDET=$(sed -n 's#^POST /api/lead-reviews/lr-1/result \(.*\)$#\1#p' "$T/rlog/worker" 2>/dev/null | head -n 1 | jq -r '.detail // ""' 2>/dev/null)
  RVER=$(sed -n 's#^POST /api/lead-reviews/lr-1/result \(.*\)$#\1#p' "$T/rlog/worker" 2>/dev/null | head -n 1 | jq -r '.verdict // ""' 2>/dev/null)
}
mkdir -p "$T/tmp"
# ── R1 shadow ──
printf 'shadow' > "$T/rmode"; tick r1 "auto: builder APPROVE on x; review-tier:medium review-mode:full"
[ "$(paste -sd, "$T/rlog/roles" 2>/dev/null)" = "lead.review,review-break-it" ] && ok \
  || bad "R1 agent roles '$(paste -sd, "$T/rlog/roles" 2>/dev/null)', want lead.review,review-break-it: $(tail -n 5 "$T/rlane.r1")"
[ "$RDET" = "break-it:failed:1" ] && ok || bad "R1 the result detail is '$RDET', want break-it:failed:1: $(grep result "$T/rlog/worker" 2>/dev/null | head -c 600)"
[ "$RVER" = MERGE ] && ok || bad "R1 shadow changed the verdict to '$RVER'"
bl=$(grep -nx -- '- break-it (BH-6970): failed:1 (mode shadow)' "$T/report.r1" | cut -d: -f1)
pl=$(grep -n -- '^- pr body:' "$T/report.r1" | head -n 1 | cut -d: -f1)
[ -n "$bl" ] && [ -n "$pl" ] && [ "$bl" -lt "$pl" ] && ok || bad "R1 the report lacks the break-it line above - pr body: $(head -n 14 "$T/report.r1")"
grep -q 'BLOCK wrong-data' "$T/report.r1" && bad "R1 shadow put a BLOCK in the report" || ok
grep -q 'break-it: failed:1 (mode shadow)' "$T/rlane.r1" && ok || bad "R1 no lane log line"
grep -q -- '-X PUT' "$T/rlog/gh" 2>/dev/null && bad "R1 shadow made a PUT" || ok
# ── R1 no break_it.mode row: today's review ──
rm -f "$T/rmode"; tick r1n "auto: builder APPROVE on x; review-tier:medium review-mode:full"
[ "$(paste -sd, "$T/rlog/roles" 2>/dev/null)" = "lead.review" ] && ok || bad "R1 no mode row: roles '$(paste -sd, "$T/rlog/roles" 2>/dev/null)'"
case "$RDET" in *break-it*) bad "R1 no mode row: the detail says '$RDET'" ;; *) ok ;; esac
grep -q -- '- break-it' "$T/report.r1n" && bad "R1 no mode row: the report has a break-it line" || ok
[ "$RVER" = MERGE ] && ok || bad "R1 no mode row: verdict '$RVER'"
# ── R2 enforce: BLOCK, the finding in the report, the PUT ──
printf 'enforce' > "$T/rmode"; tick r2 "auto: builder APPROVE on x; review-tier:high review-mode:full"
[ "$RVER" = BLOCK ] && ok || bad "R2 enforce verdict '$RVER', want BLOCK: $(tail -n 8 "$T/rlane.r2")"
grep -qx -- '- verdict: BLOCK' "$T/report.r2" && ok || bad "R2 the report verdict is not BLOCK"
grep -q '^- \[BLOCK wrong-data\] break-it: tests/bh-9001-breakit-test.sh failed 1 of 3 case(s): c2 no name says hello world\. Test file committed to the PR branch as dddddddddddd\.' "$T/report.r2" \
  && ok || bad "R2 the report lacks the BLOCK finding: $(grep -i break "$T/report.r2")"
grep -q -- '-X PUT repos/example-org/demo-os/contents/tests/bh-9001-breakit-test.sh' "$T/rlog/gh" 2>/dev/null && ok || bad "R2 no PUT of the test file: $(grep PUT "$T/rlog/gh" 2>/dev/null)"
[ "$RDET" = "break-it:failed:1" ] && ok || bad "R2 detail '$RDET'"
# the review-level cap ran (mode levels, the demoting one) and kept the ALWAYS-BLOCK finding
grep -q "lr-77-${HS:0:12}: review level: .*; verdict BLOCK" "$T/rlane.r2" && ok \
  || bad "R2 the review level cap did not run on the break-it BLOCK: $(grep -i 'review level' "$T/rlane.r2" "$T/report.r2")"

# ═══════════════════════ part L: bin/lead-review-land.sh ═══════════════════════
HL="$T/hl"; mkdir -p "$HL/state" "$HL/logs" "$T/lbin"
scratch_install_closure bin/jobs-client.sh "$HL" >/dev/null || exit 1
scratch_install_closure bin/lead-review-land.sh "$HL" >/dev/null || exit 1
cat > "$HL/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/landlv"
echo "recorded verdict #9: MERGE"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$HL/bin/lane-alert.sh"
chmod +x "$HL/bin/lead-verdict.sh" "$HL/bin/lane-alert.sh"
cat > "$T/lbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/lrequests.json") ;;
  "GET /api/verdicts?"*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "POST /api/lead-reviews/"*/promoted) out='{"request":{"promoted_verdict_at":"2026-10-17T00:00:00Z"}}' ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/lbin/gh"
chmod +x "$T/lbin/curl" "$T/lbin/gh"
mkdir -p "$T/cfg"; printf 'lead-test-token-fixture\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
SHA=$(printf 'a%.0s' {1..40})
land() { # land <detail|null> — one done MERGE request with that detail, one land tick
  rm -f "$T/log/landlv"; scratch_rm "$HL/state/lead-review-land"; echo box-hub > "$HL/state/box-name"
  jq -nc --arg s "$SHA" --arg d "$1" '{requests:[{id:"lr-1", repo:"example-org/demo-os", pr:41, head_sha:$s, status:"done",
    verdict:"MERGE", reviewer_model:"fixture-lead-model", report_ref:"state/lead-reviews/lr-41-aaaaaaaaaaaa.md",
    promoted_verdict_at:null, detail:(if $d == "null" then null else $d end), scope_notes:"auto: x; review-tier:medium review-mode:full",
    created_at:"2026-10-17T00:00:00Z", updated_at:"2026-10-17T00:00:00Z"}], truncated:false}' > "$T/lrequests.json"
  ( cd "$T" && env PATH="$T/lbin:$PATH" HARNESS="$HL" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
      TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" bash "$HL/bin/lead-review-land.sh" ) > "$T/out.land" 2>&1
  LLV=$(head -n 1 "$T/log/landlv" 2>/dev/null)
}
while IFS='|' read -r det want; do
  land "$det"
  case "$LLV" in "post example-org/demo-os 41 $SHA MERGE "*) ;; *) bad "L1 detail '$det': land did not post: '$LLV' $(tail -n 3 "$T/out.land")"; continue ;; esac
  if [ "$want" = - ]; then
    case "$LLV" in *--break-it*) bad "L1 detail '$det' passed a flag: '$LLV'" ;; *) ok ;; esac
  else
    case " $LLV " in *" --break-it $want "*) ok ;; *) bad "L1 detail '$det': want --break-it $want: '$LLV'" ;; esac
    [ "$(grep -o -- '--break-it' <<<"$LLV" | wc -l)" = 1 ] && ok || bad "L1 detail '$det': more than one flag"
  fi
  case " $LLV " in *" --review-tier medium --review-mode full "*) ok ;; *) bad "L1 detail '$det' lost the BH-6967 flags: '$LLV'" ;; esac
done <<'TABLE'
break-it:clean|clean
break-it:failed:3|failed:3
golive:2 break-it:could-not-run|could-not-run
golive:1 break-it:failed:2|failed:2
break-it:failed:0|-
break-it:bogus|-
xbreak-it:clean|-
break-it:cleanx|-
break-it:failed:1000|-
golive:1|-
null|-
TABLE

# ═══════════════════════ part P: bin/lead-verdict.sh post ═══════════════════════
HV="$T/hv"; mkdir -p "$HV" "$T/vbin"
scratch_install_closure bin/jobs-client.sh "$HV" >/dev/null || exit 1
scratch_install_closure bin/lead-verdict.sh "$HV" >/dev/null || exit 1
cat > "$T/vbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/vworker"
code=200; out='{}'
case "\$m \$p" in
  "POST /api/verdicts") code=201; out=\$(jq -c '{verdict:(. + {id:9, created_at:"2026-10-17T00:00:00Z"})}' <<<"\$body") ;;
  "GET /api/lead-protected-paths"*) out='{"rows":[]}' ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/vbin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/vgh"
case "\$*" in
  *"-X GET repos/"*"/pulls/41"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n' ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
chmod +x "$T/vbin/curl" "$T/vbin/gh"
lvpost() { rm -f "$T/log/vworker" "$T/log/vgh"; ( cd "$T" && env PATH="$T/vbin:$PATH" HARNESS="$HV" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" GH_ETAG=0 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LV_DISMISS_STALE=0 \
  bash "$HV/bin/lead-verdict.sh" post example-org/demo-os 41 "$SHA" MERGE --source box --reviewer box:fixture "$@" ) > "$T/out.lv" 2>&1; LRC=$?
  VB=$(sed -n 's#^POST /api/verdicts \(.*\)$#\1#p' "$T/log/vworker" 2>/dev/null | head -n 1); }
for v in bogus failed:0 failed:1000 CLEAN skipped:off ""; do
  lvpost --break-it "$v"
  [ "$LRC" = 2 ] && ok || bad "P1 --break-it '$v': rc $LRC, want 2: $(cat "$T/out.lv")"
  [ -s "$T/log/vworker" ] || [ -s "$T/log/vgh" ] && bad "P1 --break-it '$v' still made a request" || ok
done
grep -q "break-it must be clean, failed:<k> (k 1..999) or could-not-run, got ''" "$T/out.lv" && ok || bad "P1 the refusal does not name the value: $(cat "$T/out.lv")"
for v in clean could-not-run failed:1 failed:999; do
  lvpost --break-it "$v"
  [ "$LRC" = 0 ] && ok || bad "P1 --break-it $v: rc $LRC $(cat "$T/out.lv")"
  [ "$(jq -r '.break_it // "-"' <<<"$VB" 2>/dev/null)" = "$v" ] && ok || bad "P1 --break-it $v: the POST body is '$VB'"
done
lvpost --review-tier high --review-mode full
[ "$LRC" = 0 ] && [ "$(jq -r 'has("break_it")' <<<"$VB" 2>/dev/null)" = false ] && ok || bad "P1 no flag still sends break_it: '$VB'"

# ═══════════════════════ part S: the seed (S1) ═══════════════════════
[ -f "$SEED" ] && ok || bad "S1 the seed fragment $SEED does not exist"
grep -qiE "'(claude|gpt|gemini)-" "$SEED" 2>/dev/null && bad "S1 the seed carries a model literal" || ok
if [ -f "$SEED" ] && command -v python3 >/dev/null 2>&1 && jobs_schema_render; then
  python3 -I - "$SRC/worker/jobs/schema.sql" "$SEED" "$T/hub.sqlite" > "$T/s1.out" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[3])
db.executescript(open(sys.argv[1]).read())
db.commit()
for k, v in db.execute("SELECT key, value FROM settings WHERE key LIKE 'break_it.%' ORDER BY key"):
    print("set", k, v)
for p, m, rn in db.execute("SELECT position, model, runner FROM model_routes WHERE project IS NULL AND role='review-break-it' ORDER BY position"):
    print("rung", p, m, rn)
for role in ("lead.review", "triage.light"):
    r = db.execute("SELECT model FROM model_routes WHERE project IS NULL AND role=? AND position=0", (role,)).fetchone()
    print("src", role, r[0] if r else "-")
db.execute("UPDATE settings SET value='enforce' WHERE key='break_it.mode'")
db.executescript(open(sys.argv[1]).read())
print("after", db.execute("SELECT COUNT(*) FROM model_routes WHERE role='review-break-it'").fetchone()[0],
      db.execute("SELECT value FROM settings WHERE key='break_it.mode'").fetchone()[0])
# An operator cut: the routes gone and a model_route_changes row for the role.
db.execute("DELETE FROM model_routes WHERE role='review-break-it'")
db.execute("INSERT INTO model_route_changes (scope, project, role, position, actor, at) VALUES ('hub', NULL, 'review-break-it', 0, 'op', '2026-10-17T00:00:00Z')")
db.executescript(open(sys.argv[2]).read())
print("cut", db.execute("SELECT COUNT(*) FROM model_routes WHERE role='review-break-it'").fetchone()[0])
PY
  [ "$?" = 0 ] && ok || bad "S1 the schema did not apply: $(head -n 3 "$T/s1.out")"
  for kv in "break_it.mode shadow" "break_it.max_tests 5" "break_it.budget_usd 1.50" "break_it.max_diff_bytes 200000" "break_it.cache_days 14"; do
    grep -qx "set $kv" "$T/s1.out" && ok || bad "S1 not seeded: $kv: $(grep '^set' "$T/s1.out")"
  done
  LEADM=$(sed -n 's/^src lead.review //p' "$T/s1.out"); LIGHTM=$(sed -n 's/^src triage.light //p' "$T/s1.out")
  grep -qx "rung 0 $LIGHTM claude" "$T/s1.out" && ok || bad "S1 rung 0 is not the triage.light rung 0 ($LIGHTM): $(grep rung "$T/s1.out")"
  grep -qx "rung 1 $LEADM claude" "$T/s1.out" && ok || bad "S1 rung 1 is not the lead.review rung 0 ($LEADM): $(grep rung "$T/s1.out")"
  [ "$(grep -c '^rung ' "$T/s1.out")" = 2 ] && ok || bad "S1 want 2 rungs: $(grep rung "$T/s1.out")"
  grep -qx 'after 2 enforce' "$T/s1.out" && ok || bad "S1 a re-apply changed a row: $(grep after "$T/s1.out")"
  grep -qx 'cut 0' "$T/s1.out" && ok || bad "S1 an operator cut was put back: $(grep cut "$T/s1.out")"
else
  bad "S1 the composed schema could not be checked (no seed, no python3 or jobs_schema_render failed)"
fi

echo "break-it.bh-6970: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
