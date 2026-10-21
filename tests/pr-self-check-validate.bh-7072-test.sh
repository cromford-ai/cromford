#!/bin/bash
# tests/pr-self-check-validate.bh-7072-test.sh — BH-7072: the pre-review
# self-check runs each plan task's STATIC VALIDATE check against the PR head
# and the PR body, and refuses on a fail, a "not met" body line or a missed
# Target metric, unless an operator approved an `owed:` line. The rule is
# plan-validate (bin/lib/pr-self-check-validate.sh, bin/lib/plan-validate.py,
# the row in catalog/pr-self-check.d/bh-7072-plan-validate.tsv).
#
#   A1-A5  the ticket's acceptance cases, through bin/pr-self-check.sh
#   N1-N2  a plan with no VALIDATE line, or no plan: no line at all
#   P1-P12 counts, comparators, the PR body as the target, head file tests
#   G1-G10 shapes: what runs, what is skipped, what never reaches a shell
#   X1-X10 the words after a command: prints 0, prints nothing, exits 1,
#          for each file, is at least, prose it cannot read, a git-ignored file
#   B1-B10 the body: not met lines and Target metric lines
#   O1-O8  owed: lines and the operator's approval in the thread
#   E1-E3  could-not-run paths hold nothing
#   W1-W3  the catalog row, mode note, the line cap
#   H1     the enqueue tick holds a PR whose plan VALIDATE fails, and the
#          approved owed line (PSC_PR_REPO/N/PROJECT from the enqueue) lets it go
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-self-check-validate.bh-7072-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_SELF_CHECK_CATALOG PR_SELF_CHECK_ONLY PSC_TICKET_FILE PSC_PR_KEY PSC_PR_REPO PSC_PR_N PSC_PROJECT PLAN_VALIDATE_MAX_LINES HARNESS H

H="$T/h"; mkdir -p "$H" "$T/tmp" "$T/b" "$T/gh/set"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
# The evaluator is python, which the source closure does not follow.
cp "$SRC/bin/lib/plan-validate.py" "$H/bin/lib/plan-validate.py" || { echo "FAIL: no bin/lib/plan-validate.py"; exit 1; }
CAT="$SRC/catalog/pr-self-check.tsv"   # the real main file and its real .d/
[ -r "$SRC/catalog/pr-self-check.d/bh-7072-plan-validate.tsv" ] || bad "W0 the catalog row file is missing"
[ -r "$SRC/bin/lib/pr-self-check-validate.sh" ] && [ -r "$H/bin/lib/pr-self-check-validate.sh" ] || bad "W0 the rule lib is not in the closure"
export TMPDIR="$T/tmp"
RULE='plan-validate'

# The GitHub and settings seams for the owed: approval. Exported, so the CLI's
# bash inherits them; the lib loads its own only when these are absent.
export GHT="$T/gh"
gh_rest() { # gh_rest GET repos/<slug>/issues/<n>/comments?per_page=100&page=<p>
  echo "$*" >> "$GHT/calls"
  if [ -f "$GHT/st-comments" ]; then GH_REST_STATUS=$(cat "$GHT/st-comments"); return 75; fi
  GH_REST_STATUS=200
  cat "$GHT/page-${2##*page=}.json" 2>/dev/null || echo '[]'
}
setting_get() { [ -f "$GHT/set/$1" ] || return 2; cat "$GHT/set/$1"; }
export -f gh_rest setting_get
gh_reset() { rm -f "$GHT"/page-*.json "$GHT/calls" "$GHT/st-comments" "$GHT"/set/*; }
# comments <page> <login> <body> [<login> <body>]... — one page of the thread
comments() {
  local p="$1"; shift
  local j='[]'
  while [ $# -ge 2 ]; do j=$(jq -c --arg l "$1" --arg b "$2" '. + [{user:{login:$l}, body:$b}]' <<<"$j"); shift 2; done
  printf '%s\n' "$j" > "$GHT/page-$p.json"
}
filler_page() { # filler_page <page> — 100 comments by a bot
  jq -nc '[range(100) | {user:{login:"cromford[bot]"}, body:"a status line"}]' > "$GHT/page-$1.json"
}

# ── the fixture repo ──────────────────────────────────────────────────────────
R="$T/repo"; mkdir -p "$R/bin" "$R/docs/sub" "$R/catalog"
git -C "$R" init -q -b main
printf '#!/bin/bash\necho x\n' > "$R/bin/a.sh"
printf 'x\nx\n' > "$R/bin/b.sh"
printf 'gone soon\n' > "$R/docs/old.md"
printf 'kept\n' > "$R/docs/sub/k.md"
: > "$R/docs/empty.md"
printf 'docs/gen.json\n' > "$R/.gitignore"
git -C "$R" add -A; git -C "$R" commit -qm M0

N=0
# plan <plan-text> [extra-step] — a fresh branch from main whose commit adds the
# plan (and runs the extra step first); BR is its name
plan() {
  N=$((N+1)); BR="c$N"
  git -C "$R" checkout -q main && git -C "$R" checkout -qB "$BR"
  mkdir -p "$R/.harness/specs/BH-9"
  printf '%s\n' "$1" > "$R/.harness/specs/BH-9/plan.md"
  [ -n "${2:-}" ] && eval "$2"
  git -C "$R" add -A && git -C "$R" commit -qm "spec: $BR"
}
body() { N=$((N+1)); printf '%s\n' "$1" > "$T/b/$N.md"; printf '%s' "$T/b/$N.md"; }
# run <body-file> [catalog] — the CLI, the rule alone, on $BR; OUT, RC
run() {
  OUT=$(PR_SELF_CHECK_CATALOG="${2:-$CAT}" bash "$H/bin/pr-self-check.sh" check \
        --repo "$R" --base main --head "$BR" --body "$1" --only "^$RULE\$" 2>/dev/null); RC=$?
}
has()  { grep -qF -- "$2" <<<"$1"; }
lines() { grep -c "^\(REFUSE\|NOTE\) $RULE" <<<"$1"; }
refs() { grep "^REFUSE $RULE" <<<"$1"; }
# rhas <out> <ERE> / rhasF <out> <text> — a REFUSE line of the rule matches
rhas()  { grep -q -- "$2" <<<"$(refs "$1")"; }
rhasF() { grep -qF -- "$2" <<<"$(refs "$1")"; }
task() { printf '### %s — a task\n- VALIDATE: %s\n- SATISFIES: x\n' "$1" "$2"; }
TOK=$(task T1 '`test -f bin/a.sh`')
WHY=$(body $'## Why\nIt adds a thing.')

# ── A1: grep -c on <PR body> >= 9, 0 matches ──────────────────────────────────
plan "$(task T4 "\`grep -c 'bake phases' <PR body>\` >= 9")"
P_A1="$BR"
run "$WHY"
{ [ "$RC" = 1 ] && rhas "$OUT" "^REFUSE $RULE: T4: .*bake phases.*got 0"; } \
  && ok || bad "A1 want rc 1 and REFUSE T4 naming bake phases and got 0, got rc $RC: $OUT"

# ── A2: test -f on a file only in the working tree ────────────────────────────
plan "$(task T2 '`test -f catalog/lanes.d/fly-pool.knobs.d/POOL_CAP.json`')"
mkdir -p "$R/catalog/lanes.d/fly-pool.knobs.d"; echo '{}' > "$R/catalog/lanes.d/fly-pool.knobs.d/POOL_CAP.json"
run "$WHY"
{ [ "$RC" = 1 ] && rhas "$OUT" "^REFUSE $RULE: T2: .*catalog/lanes.d/fly-pool.knobs.d/POOL_CAP.json.*missing at head"; } \
  && ok || bad "A2 want REFUSE T2 naming the path and missing at head, got rc $RC: $OUT"
scratch_rm "$R/catalog/lanes.d"

# ── A3: Target metric <= 50, measured 81.7 ────────────────────────────────────
plan "$TOK"
P_OK="$BR"
B_A3=$(body $'## Outcome replay\nTarget metric: suite runs <= 50\n\nmeasured: 81.7 on the last 40 runs')
run "$B_A3"
{ [ "$RC" = 1 ] && rhas "$OUT" "^REFUSE $RULE: Target metric suite runs <= 50 measured 81.7"; } \
  && ok || bad "A3 want REFUSE naming 81.7, got rc $RC: $OUT"

# ── A4: A1's failing task, owed: T4 approved by an operator on page 2 ─────────
BR="$P_A1"
gh_reset; echo operator > "$GHT/set/trigger.actors.cromford"
filler_page 1; comments 2 operator $'Looks fine.\napprove owed: T4'
B_OWED=$(body $'## Why\nIt adds a thing.\n\nowed: T4 the counts land in a follow-up')
PSC_PR_REPO=example-org/cromford PSC_PR_N=12 PSC_PROJECT=cromford run "$B_OWED"
{ [ "$RC" = 0 ] && [ -z "$(refs "$OUT")" ] && has "$OUT" "NOTE $RULE: T4 owed (approved by operator)"; } \
  && ok || bad "A4/O1 want rc 0 and NOTE T4 owed (approved by operator), got rc $RC: $OUT"
grep -q 'page=2' "$GHT/calls" 2>/dev/null && ! grep -q 'page=3' "$GHT/calls" \
  && ok || bad "A4/O1 want pages 1 and 2 read, then stop on the short page: $(cat "$GHT/calls" 2>/dev/null)"

# ── A5: every task passes: an ok line for each ────────────────────────────────
plan "$(task T1 '`test -f bin/a.sh`')
$(task T2 "\`grep -c 'x' bin/a.sh\` >= 1")
$(task T3 "\`grep -q 'Why' <PR body>\`")"
P_A5="$BR"
run "$WHY"
{ [ "$RC" = 0 ] && [ -z "$(refs "$OUT")" ] \
  && has "$OUT" "NOTE $RULE: T1 ok: \`test -f bin/a.sh\`" \
  && has "$OUT" "NOTE $RULE: T2 ok: \`grep -c 'x' bin/a.sh\`" \
  && has "$OUT" "NOTE $RULE: T3 ok: \`grep -q 'Why' <PR body>\`"; } \
  && ok || bad "A5 want rc 0 and one ok line per task, got rc $RC: $OUT"
! has "$OUT" "skipped" && ok || bad "A5 no task was skipped, so no skip line: $OUT"

# ── N1/N2: no VALIDATE line, no plan: nothing at all ──────────────────────────
plan $'# plan\n\n### T1 — a task\n- SATISFIES: x\n\n## Acceptance tests\n- VALIDATE: `test -f nope`\n```\n- VALIDATE: `test -f nope2`\n```'
B_BAD=$(body $'The target is NOT met.\nTarget metric: x <= 1\nmeasured 9')
run "$B_BAD"
{ [ "$RC" = 0 ] && [ "$(lines "$OUT")" = 0 ]; } && ok || bad "N1 a plan with no task VALIDATE line: want no line, got rc $RC: $OUT"
git -C "$R" checkout -q main && git -C "$R" checkout -qB n2 && echo y >> "$R/bin/a.sh" && git -C "$R" commit -qam n2; BR=n2
run "$B_BAD"
{ [ "$RC" = 0 ] && [ "$(lines "$OUT")" = 0 ]; } && ok || bad "N2 no plan in the diff: want no line, got rc $RC: $OUT"

# ── P: counts and comparators ─────────────────────────────────────────────────
NINE=$(for i in 1 2 3 4 5 6 7 8 9; do echo "- bake phases $i"; done)
EIGHT=$(for i in 1 2 3 4 5 6 7 8; do echo "- bake phases $i"; done)
BR="$P_A1"; run "$(body "$NINE")"
{ [ "$RC" = 0 ] && has "$OUT" "NOTE $RULE: T4 ok:"; } && ok || bad "P1 count 9 vs >= 9 passes, got rc $RC: $OUT"
run "$(body "$EIGHT")"
{ [ "$RC" = 1 ] && has "$OUT" "got 8"; } && ok || bad "P4 count 8 vs >= 9 fails with got 8, got rc $RC: $OUT"
plan "$(task T1 "\`grep -c 'TODO' bin/a.sh\` == 0")
$(task T2 "\`grep -c x bin/a.sh -ge 1\`")
$(task T3 "\`grep -c 'echo' bin/a.sh\` == 0")
$(task T4 "\`grep -c x bin/a.sh bin/b.sh\` >= 3")
$(task T5 "\`grep -c x bin/a.sh bin/b.sh\` >= 4")
$(task T6 "\`grep -cx 'bake phases' <PR body>\` >= 2")"
CRLF="$T/b/crlf.md"; printf 'bake phases\r\nbake phases\r\n' > "$CRLF"
run "$CRLF"
has "$OUT" "NOTE $RULE: T1 ok:" && ok || bad "P2 count 0 vs == 0 passes: $OUT"
has "$OUT" "NOTE $RULE: T2 ok:" && ok || bad "P3 -ge 1 inside the backticks with 1 passes: $OUT"
rhas "$OUT" "T3: .*wants count == 0 — got 1" && ok || bad "P5 1 vs == 0 fails: $OUT"
has "$OUT" "NOTE $RULE: T4 ok:" && ok || bad "P6 -c over two files sums to 3: $OUT"
rhas "$OUT" "T5: .*got 3" && ok || bad "P6b the sum 3 vs >= 4 fails with got 3: $OUT"
has "$OUT" "NOTE $RULE: T6 ok:" && ok || bad "P6c CRLF body lines still match -x: $OUT"
# The plan says the PR body must contain it, and names plan.md: the body decides.
plan "$(task T1 'the PR body has a Why section: `grep -q "^## Why" .harness/specs/BH-9/plan.md`')
## Why
the plan has this line, the body may not"
run "$(body $'no such section here')"
rhas "$OUT" "T1: " && ok || bad "P4b 'PR body' + plan.md: the body has no Why, so it fails (not read from plan.md): $OUT"
run "$WHY"
has "$OUT" "NOTE $RULE: T1 ok:" && ok || bad "P4c 'PR body' + plan.md: the body has the Why, so it passes: $OUT"
# Head file tests.
plan "$(task T1 '`test -f bin/a.sh`')
$(task T2 '`test -s bin/a.sh`')
$(task T3 '`test -d docs/sub`')
$(task T4 '`test -f docs/old.md`')
$(task T5 '`test -s docs/empty.md`')
$(task T6 '`test -f docs/sub`')
$(task T7 '`[ -f bin/b.sh ]`')
$(task T8 '`test ! -f docs/old.md`')
$(task T9 '`ls docs/sub/k.md`')" 'git -C "$R" rm -q docs/old.md'
run "$WHY"
for t in T1 T2 T3 T7 T8 T9; do has "$OUT" "NOTE $RULE: $t ok:" || bad "P7-P9 $t should pass at the head: $OUT"; done; ok
rhas "$OUT" "T4: .*missing at head" && ok || bad "P10 a file the PR deletes fails: $OUT"
rhas "$OUT" "T5: .*empty at head" && ok || bad "P11 -s on an empty blob fails: $OUT"
rhas "$OUT" "T6: .*a tree at head" && ok || bad "P12 -f on a directory fails: $OUT"

# ── G: shapes ─────────────────────────────────────────────────────────────────
plan "$(task T1 '`HARNESS_TEST_SANDBOX=1 bash tests/x-test.sh`')
$(task T2 '`grep -c x bin/a.sh | wc -l`')
$(task T3 '`cd worker/jobs && npm test`')
$(task T4 "\`grep -P 'x' bin/a.sh\`")
$(task T5 '`test -f $BUILD/validate.txt`')
$(task T6 'load the page at 375px')
$(task T7 "\`grep -c x bin/a.sh; touch $T/pwned\` >= 1")
$(task T8 '`test -f ../../etc/passwd`')
$(task T9 '`! grep -q TODO bin/a.sh`')
$(task T10 '`[ -s docs/sub/k.md ]`')
$(task T11 'gh pr view 12 --json body -q .body | grep -q Why')
$(task T12 "\`grep -c '\$(touch $T/pwned2)' bin/a.sh\` == 0")"
run "$WHY"
has "$OUT" "NOTE $RULE: 8 VALIDATE line(s) skipped (not a static check): T1,T2,T3,T4,T5,T6,T7,T8" \
  && ok || bad "G1-G8 want the 8 skips named in one NOTE, got: $OUT"
[ -z "$(refs "$OUT")" ] && ok || bad "G a skip is never a refusal: $OUT"
for t in T9 T10 T11 T12; do has "$OUT" "NOTE $RULE: $t ok:" || bad "G9-G10 $t should run and pass: $OUT"; done; ok
[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] && ok || bad "G no VALIDATE text may reach a shell"
for t in T1 T2 T3 T4 T5 T6 T7 T8; do has "$OUT" "NOTE $RULE: $t ok:" && bad "G a skipped $t must never print ok: $OUT"; done; ok

# ── X: the words after a command (the forms the spec plans on main use) ─────
plan "$(task T1 "\`grep -c 'echo' bin/a.sh\` prints 0 for both files")
$(task T2 '`grep -c x bin/a.sh` prints 1, and nothing else')
$(task T3 '`grep -n TODO bin/a.sh` prints nothing.')
$(task T4 '`grep -n echo bin/a.sh` prints nothing')
$(task T5 '`grep -c x bin/a.sh bin/b.sh` prints 1 for each file')
$(task T6 '`grep -q x bin/a.sh` shows only the header')
$(task T7 '`grep -c x bin/a.sh` prints 2 or 3')
$(task T8 '`grep -q echo bin/a.sh` exits 1')
$(task T9 '`grep -c x bin/b.sh` is at least 2')
$(task T10 '`test -f docs/gen.json` (generated by the build)')
$(task T11 '`grep -c x docs/gen.json` >= 1')"
run "$WHY"
rhas "$OUT" "T1: .*wants count == 0 — got 1" && ok || bad "X1 'prints 0' is count == 0, and 1 fails: $OUT"
has "$OUT" "NOTE $RULE: T2 ok:" && ok || bad "X2 'prints 1' with 1 passes: $OUT"
has "$OUT" "NOTE $RULE: T3 ok:" && ok || bad "X3 'prints nothing' with no match passes: $OUT"
rhas "$OUT" "T4: .*wants no match — got 1 matching line(s)" && ok || bad "X4 'prints nothing' with a match fails and names the count: $OUT"
rhas "$OUT" "T5: .*count == 1 in each file — got bin/a.sh: 1, bin/b.sh: 2" && ok || bad "X5 'for each file' compares each file: $OUT"
rhas "$OUT" "T8: .*wants no match" && ok || bad "X8 'exits 1' wants no match: $OUT"
has "$OUT" "NOTE $RULE: T9 ok:" && ok || bad "X9 'is at least 2' with 2 passes: $OUT"
has "$OUT" "skipped (not a static check): T6,T7,T10,T11" && ok || bad "X6/X7/X10 unreadable prose and a git-ignored file are skips: $OUT"
for t in T6 T7 T10 T11; do rhas "$OUT" "$t: " && bad "X a skipped $t must not refuse: $OUT"; done; ok

# ── B: the body ───────────────────────────────────────────────────────────────
BR="$P_OK"
for s in 'The target is NOT met.' '- [ ] T3: not met' '| T3 | NOT MET |'; do
  run "$(body "$s")"
  { [ "$RC" = 1 ] && rhasF "$OUT" "body says not met: $s"; } || bad "B1-B3 '$s' is red, got rc $RC: $OUT"
done; ok
NEG=$'- [x] not met is refused: met\nthe check is red when the body says `NOT MET`\nwe quote "not met" here\n```\nNOT MET\n```\nmet\nnot metered\n\n## Pre-open check: refusals left\n- plan-validate: body says not met: x\n'
run "$(body "$NEG")"
{ [ "$RC" = 0 ] && [ -z "$(refs "$OUT")" ]; } && ok || bad "B4-B8 none of the negatives is red, got rc $RC: $OUT"
run "$(body $'Target metric: p95 from 100 to 50\nmeasured 49\n\nTarget metric: ratio from 0.3 to 0.9\nmeasured: 0.95\n\nTarget metric: suite runs <= 50\nmeasured 50')"
{ [ "$RC" = 0 ] && [ -z "$(refs "$OUT")" ]; } && ok || bad "B9 met targets are not red, got rc $RC: $OUT"
run "$(body $'Target metric: p95 from 100 to 50\nmeasured 81.7')"
rhas "$OUT" "Target metric p95 from 100 to 50 measured 81.7" && ok || bad "B10 from 100 to 50 measured 81.7 is red: $OUT"
run "$(body $'Target metric: hits >= 10 (measured 9.99)')"
rhas "$OUT" "measured 9.99" && ok || bad "B10b >= 10 measured 9.99 on the same line is red: $OUT"
run "$(body $'- Target metric: p95 from 120 to 50, measured from 120 to 81.7')"
rhas "$OUT" "measured 81.7" && ok || bad "B10c 'measured from x to M' takes M: $OUT"
run "$(body $'Target metric: p95 from 100 to 50\n\nnothing measured yet')"
{ [ "$RC" = 0 ] && has "$OUT" "NOTE $RULE: Target metric p95 from 100 to 50 has no measured number"; } \
  && ok || bad "B10d no measured number is a NOTE, got rc $RC: $OUT"
run "$(body $'Target metric: p95 from 1 to 1\nmeasured 3')"
{ [ "$RC" = 0 ] && has "$OUT" "has no direction"; } && ok || bad "B10e from 1 to 1 is a NOTE, got rc $RC: $OUT"

# ── O: owed lines and approvals ───────────────────────────────────────────────
BR="$P_A1"
owedrun() { PSC_PR_REPO=example-org/cromford PSC_PR_N=12 PSC_PROJECT=cromford run "$@"; }
gh_reset; echo operator > "$GHT/set/trigger.actors.cromford"
comments 1 operator 'OWED T4 APPROVED'
owedrun "$B_OWED"
{ [ "$RC" = 0 ] && has "$OUT" "T4 owed (approved by operator)"; } && ok || bad "O2 'OWED T4 APPROVED' approves, got rc $RC: $OUT"
comments 1 'cromford[bot]' 'approve owed: T4' someone 'approve owed: T4'
owedrun "$B_OWED"
{ [ "$RC" = 1 ] && rhas "$OUT" "T4: .*its owed: line is not approved"; } && ok || bad "O3 a bot or an unlisted login does not approve, got rc $RC: $OUT"
comments 1 operator 'approve owed: T40' operator 'approve owed: T8'
owedrun "$B_OWED"
{ [ "$RC" = 1 ] && rhas "$OUT" "T4: "; } && ok || bad "O4 an approval of T8 or T40 does not excuse T4, got rc $RC: $OUT"
comments 1 operator 'lgtm'
owedrun "$B_OWED"
[ "$RC" = 1 ] && ok || bad "O5 an owed line with no approving comment is red, got rc $RC: $OUT"
comments 1 operator 'approve owed: T4'; rm -f "$GHT/set/trigger.actors.cromford"
owedrun "$B_OWED"
{ [ "$RC" = 1 ] && has "$OUT" "trigger.actors.cromford is absent"; } && ok || bad "O6 no allowlist row: not approved, and it says why, got rc $RC: $OUT"
echo operator > "$GHT/set/trigger.actors.cromford"; rm -f "$GHT/calls"
run "$B_OWED"
{ [ "$RC" = 1 ] && has "$OUT" "no PR yet" && [ ! -e "$GHT/calls" ]; } && ok || bad "O7 no PR number (the builder's pre-open check): no read, not approved, got rc $RC: $OUT"
echo 502 > "$GHT/st-comments"
owedrun "$B_OWED"
{ [ "$RC" = 1 ] && has "$OUT" "did not read"; } && ok || bad "O7b a failed comments read is not an approval, got rc $RC: $OUT"
rm -f "$GHT/st-comments"; rm -f "$GHT/calls"
owedrun "$WHY"
[ ! -e "$GHT/calls" ] && ok || bad "O7c no owed: line = no comments read"
BR="$P_OK"; comments 1 operator 'approve owed: T1'
owedrun "$(body $'The target is NOT met.\n\n- owed: T1 the replay runs next week')"
{ [ "$RC" = 0 ] && has "$OUT" "owed (approved by operator for T1)"; } && ok || bad "O8 an approved owed line excuses NOT MET, got rc $RC: $OUT"

# ── E: could not run ──────────────────────────────────────────────────────────
mkdir -p "$T/fakebin"; printf '#!/bin/sh\nexit 3\n' > "$T/fakebin/python3"; chmod +x "$T/fakebin/python3"
BR="$P_A1"
OUT=$(PATH="$T/fakebin:$PATH" PR_SELF_CHECK_CATALOG="$CAT" bash "$H/bin/pr-self-check.sh" check --repo "$R" --base main --head "$BR" --body "$WHY" --only "^$RULE\$" 2>/dev/null); RC=$?
{ [ "$RC" = 0 ] && has "$OUT" "NOTE $RULE: could not run"; } && ok || bad "E1 a failing evaluator is one NOTE and holds nothing, got rc $RC: $OUT"
H2="$T/h2"; mkdir -p "$H2"; scratch_install_closure bin/pr-self-check.sh "$H2" >/dev/null
OUT=$(PR_SELF_CHECK_CATALOG="$CAT" bash "$H2/bin/pr-self-check.sh" check --repo "$R" --base main --head "$BR" --body "$WHY" --only "^$RULE\$" 2>/dev/null); RC=$?
{ [ "$RC" = 0 ] && has "$OUT" "NOTE $RULE: could not run"; } && ok || bad "E2 no evaluator file is one NOTE, got rc $RC: $OUT"
plan "$TOK"
git -C "$R" rm -q .harness/specs/BH-9/plan.md && git -C "$R" commit -qm "drop plan"
run "$B_BAD"
{ [ "$RC" = 0 ] && [ "$(lines "$OUT")" = 0 ]; } && ok || bad "E3 a plan the head does not have: no line, got rc $RC: $OUT"

# ── W: the catalog row, mode note, the cap ────────────────────────────────────
ROW=$(PR_SELF_CHECK_CATALOG="$CAT" bash -c '. "$1/bin/lib/pr-self-check.sh"; _psc_rows' _ "$H" | awk -F'\t' -v r="$RULE" '$1 == r {print $2}')
[ "$ROW" = refuse ] && ok || bad "W1 _psc_rows lists plan-validate as refuse, got '$ROW'"
mkdir -p "$T/cat"; printf 'plan-validate\tnote\t-\tx\t-\n' > "$T/cat/pr-self-check.tsv"
BR="$P_A1"; run "$WHY" "$T/cat/pr-self-check.tsv"
{ [ "$RC" = 0 ] && has "$OUT" "NOTE $RULE: T4:" && [ -z "$(refs "$OUT")" ]; } && ok || bad "W2 mode note: a NOTE, rc 0, got rc $RC: $OUT"
BR="$P_A5"; OUT=$(PLAN_VALIDATE_MAX_LINES=1 PR_SELF_CHECK_CATALOG="$CAT" bash "$H/bin/pr-self-check.sh" check --repo "$R" --base main --head "$BR" --body "$WHY" --only "^$RULE\$" 2>/dev/null)
{ has "$OUT" "2 VALIDATE line(s) past the cap of 1" && has "$OUT" "T1 ok" && ! has "$OUT" "T2 ok"; } && ok || bad "W3 the cap reads 1 line and says 2 were not read: $OUT"

# ── H1: the enqueue tick (the rig of tests/lead-enqueue-self-check.bh-5798-test.sh) ─
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
echo base > "$WK/README"; git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; mkdir -p "$WK/bin" "$WK/.harness/specs/BH-41"
printf '# plan\n\n## Files to touch\n- `bin/a.sh`\n\n### T7 — the knob file\n- VALIDATE: `test -f catalog/knob.json`\n- SATISFIES: x\n' > "$WK/.harness/specs/BH-41/plan.md"
echo a > "$WK/bin/a.sh"; git -C "$WK" add -A; git -C "$WK" commit -qm "the pr"; C=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb pr2; mkdir -p "$WK/catalog"; echo '{}' > "$WK/catalog/knob.json"
printf '# plan\n\n## Files to touch\n- `bin/a.sh`\n- `catalog/knob.json`\n\n### T7 — the knob file\n- VALIDATE: `test -f catalog/knob.json`\n- SATISFIES: x\n' > "$WK/.harness/specs/BH-41/plan.md"
git -C "$WK" add -A; git -C "$WK" commit -qm "the pr, with the knob"; C2=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr pr2
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$Q/catalog/lanes.d" "$T/cfg" "$T/qrepos" "$T/log" "$T/qbin"
printf '#!/bin/bash\nexit 0\n' > "$Q/bin/lead-verdict.sh"; printf '#!/bin/bash\nexit 0\n' > "$Q/bin/lane-alert.sh"
chmod +x "$Q/bin/lead-verdict.sh" "$Q/bin/lane-alert.sh"
scratch_install_closure bin/lead-review-enqueue.sh "$Q" >/dev/null || bad "H closure of bin/lead-review-enqueue.sh"
scratch_install_closure bin/jobs-client.sh "$Q" >/dev/null || bad "H closure of bin/jobs-client.sh"
scratch_install_closure bin/lead-review.sh "$Q" >/dev/null || bad "H closure of bin/lead-review.sh"
cp "$SRC/bin/lib/plan-validate.py" "$Q/bin/lib/plan-validate.py"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$Q/catalog/lanes.d/"
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$SRC/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/qbin" "$LPPF" "$LPPDOWN"
cp "$SRC/catalog/pr-self-check.tsv" "$Q/catalog/"; cp -r "$SRC/catalog/pr-self-check.d" "$Q/catalog/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"
git clone -q "$OR" "$T/qrepos/demo-os"
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "CI"\n' | base64 | tr -d '\n' > "$T/mergify.b64"
cat > "$T/qbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*standing_only=1*)
    h=\$(printf '%s' "\$p" | tr '&?' '\n\n' | sed -n 's/^head_sha=//p')
    out=\$(jq -c --arg h "\$h" '{standing:([.rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | last // null),
      rows:[], truncated:false}' "$T/vrows.json") ;;
  "GET /api/verdicts?"*) out=\$(cat "$T/vrows.json") ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true}' ;;
  "POST /api/lead-reviews")
    h=\$(jq -r .head_sha <<<"\$body")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else printf '%s\n' "\$body" >> "$T/log/created"
      code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/qbin/gh" <<EOF
#!/bin/bash
H=\$(cat "$T/qhead")
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$H" '[{number:41, html_url:"https://github.com/example-org/demo-os/pull/41", title:"BH-41: t", draft:false, state:"open",
      user:{login:"operator",type:"User"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' ;;
  *"-X GET repos/example-org/demo-os/pulls/41"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$H" --rawfile b "$T/prbody" '{head:{sha:\$s,ref:"ticket/bh-41"},base:{ref:"main"},title:"BH-41: t",user:{login:"operator"},body:\$b}' ;;
  *"-X GET repos/example-org/demo-os/issues/41/comments"*)
    echo read >> "$T/log/comment-reads"
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/thread.json" 2>/dev/null || echo '[]' ;;
  *"-X POST repos/example-org/demo-os/issues/41/comments"*)
    echo post >> "$T/log/comments"
    f=\$(printf '%s' "\$*" | grep -oE 'body=@[^ ]+' | cut -c7-); cat "\$f" >> "$T/log/comment-bodies" 2>/dev/null
    printf 'HTTP/2 201\r\n\r\n{"id":1}\n' ;;
  *"-X GET repos/example-org/demo-os/contents/.mergify.yml"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg c "\$(cat "$T/mergify.b64")" '{content:\$c, encoding:"base64"}' ;;
  *"-X GET repos/example-org/demo-os/commits/"*"/check-runs"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$H" '{total_count:1, check_runs:[{name:"CI", head_sha:\$h, status:"completed", conclusion:"success", app:{slug:"github-actions"}}]}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"fix: outside"}}],"files":[]}\n' ;;
esac
exit 0
EOF
chmod +x "$T/qbin/curl" "$T/qbin/gh"
QLOG="$Q/logs/lead-review-enqueue.log"
approve() { # approve <head> <body-text>
  rm -f "$T/log"/* "$QLOG" "$T/thread.json"
  scratch_rm "$T/set"; mkdir -p "$T/set"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$1" > "$T/qhead"; printf '%s\n' "$2" > "$T/prbody"
  jq -nc --arg s "$1" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg h "$1" '{rows:[{id:4,repo:"example-org/demo-os",pr:41,head_sha:$h,source:"box",verdict:"APPROVE",note:""}],truncated:false}' > "$T/vrows.json"
}
tick() {
  ( cd "$T" && env -u GHT PATH="$T/qbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 GH_ETAG=0 \
      bash -c 'unset -f gh_rest setting_get; exec bash "$1/bin/lead-review-enqueue.sh" tick' _ "$Q" ) > "$T/out" 2>&1; RC=$?
}
cnt() { [ -f "$T/log/$1" ] && wc -l < "$T/log/$1" | tr -d ' ' || echo 0; }
HB="Refs #41

## Why
The knob file was missing, and nothing said so before the review.

## Acceptance self-check
- [x] a test

<!-- evidence-head: $C -->"
approve "$C" "$HB"; tick
{ [ "$(cnt created)" = 0 ] && [ "$(cnt comments)" = 1 ] && grep -q "plan-validate: T7: .*catalog/knob.json.*missing at head" "$T/log/comment-bodies"; } \
  && ok || bad "H1 a failing plan VALIDATE holds the review: created=$(cnt created) comments=$(cnt comments) bodies=$(cat "$T/log/comment-bodies" 2>/dev/null) log=$(tail -3 "$QLOG" 2>/dev/null) out=$(tail -5 "$T/out")"
approve "$C2" "${HB//$C/$C2}"; tick
{ [ "$(cnt created)" = 1 ] && [ "$(cnt comments)" = 0 ]; } \
  && ok || bad "H1b the same PR with the knob committed is requested: created=$(cnt created) comments=$(cnt comments) $(tail -3 "$QLOG" 2>/dev/null)"
approve "$C" "$HB

owed: T7 the knob lands with BH-42"
echo operator > "$T/set/trigger.actors.demo-os"
jq -nc '[{user:{login:"operator"}, body:"approve owed: T7"}]' > "$T/thread.json"
tick
{ [ "$(cnt created)" = 1 ] && [ "$(cnt comment-reads)" -ge 1 ]; } \
  && ok || bad "H1c an approved owed line (the enqueue passes the PR and project) is requested: created=$(cnt created) reads=$(cnt comment-reads) comments=$(cat "$T/log/comment-bodies" 2>/dev/null) $(tail -3 "$QLOG" 2>/dev/null)"

# ── H2: gates 75/78 (lgsc_run) pass the PR and the project to psc_check too ──
mkdir -p "$T/lgs"; jq -nc '{body:"x", base:{ref:"main"}, title:"BH-41: t"}' > "$T/lgs/pr.json"
H2OUT=$(cd "$T" && TT="$T" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" PR_SELF_CHECK_CATALOG="$CAT" bash -c '
  lgk_load() { LGK_PSC=1; }
  lgs_dir() { echo "$TT/lgs"; }
  lgs_pr_body() { LGS_BODY_FILE="$TT/lgs/pr.json"; }
  psc_check() { echo "env $PSC_PR_REPO $PSC_PR_N $PSC_PROJECT"; }
  . "$2/bin/lib/lead-gates-selfcheck.sh" || exit 9
  lgsc_run example-org/demo-os 41 "$3" || exit 8
  cat "$LGSC_OUT"' _ "$T" "$SRC" "$C" 2>&1)
[ "$H2OUT" = "env example-org/demo-os 41 demo-os" ] && ok || bad "H2 lgsc_run passes PSC_PR_REPO, PSC_PR_N and PSC_PROJECT: $H2OUT"

echo "pr-self-check-validate.bh-7072: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
