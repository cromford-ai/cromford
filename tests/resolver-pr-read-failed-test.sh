#!/bin/bash
# tests/resolver-pr-read-failed-test.sh — in bin/blocked-resolver.sh a PR the lane
# COULD NOT READ is a retry, never a REBUILD FRESH.
#
# THE INCIDENT (2026-09-16 17:24Z and 18:04Z, hub). br_pr_ref read the PR with
# `gh pr view --json headRefOid,headRefName`, which is a GraphQL call. Both hub
# PATs are the same GitHub user (id 2220366), so they share one 5000/hr GraphQL
# budget — and it was exhausted: "API rate limit already exceeded for user ID
# 2220366". The read came back empty, br_pr_ref returned 1, and both callers read
# that rc as "this PR has no branch". project-5 #1677 and #1696 (ticket/TK-1669,
# OPEN, mergeable=true) and #1694 (ticket/TK-1564-r2, OPEN, mergeable=true) were
# closed and sent to REBUILD FRESH, and TK-1669 got a DUPLICATE fresh pool build
# enqueued on top. Clean PRs that needed nothing but a re-review were thrown away
# because GitHub was rate-limiting us.
#
# So br_pr_ref now separates the two answers it used to conflate:
#   rc 1  the PR was READ and really has no branch (head.ref null)  -> old path
#   rc 2  the READ FAILED (gh non-zero, empty body, rate limit, 5xx) -> retry
# and it asks REST (`gh api repos/<slug>/pulls/N`), which spends the core bucket
# rather than the GraphQL one that ran out.
# Run from anywhere: tests/resolver-pr-read-failed-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Scratch harness only. Nothing here may touch /root/harness.
export HARNESS="$T/h"; H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/env" "$T/fakebin"
TOK=tok_ONLY_0001

# The fake gh. `pulls/1696` is the rate-limited read: non-zero, and the real
# message from the incident on STDERR — which is exactly where the old code threw
# it away (`2>/dev/null`). `pulls/1694` is the same failure shaped as gh's other
# habit: rc 0 with an empty body. `pulls/8888` is a PR that WAS read and whose
# head repo is gone, so jq interpolates a null branch.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"api repos/example-org/project-5/pulls/1696"*)
      echo "API rate limit already exceeded for user ID 2220366." >&2
      echo "gh: try again later" >&2; exit 1 ;;
  *"api repos/example-org/project-5/pulls/1694"*) exit 0 ;;
  *"api repos/example-org/project-5/pulls/8888"*)
      echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef null"; exit 0 ;;
  *"api repos/example-org/project-5/pulls/1677"*)
      echo "aaaabbbbccccddddeeeeffff00001111deadbeef ticket/TK-1669"; exit 0 ;;
  "api repos/"*) echo "API rate limit already exceeded for user ID 2220366." >&2; exit 1 ;;
  "auth token") echo "$TOK"; exit 0 ;;
  *) echo ""; exit 0 ;;
esac
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN="$TOK"

cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# shellcheck source=/dev/null
. "$H/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$H/bin/lib/gh-repo-token.sh"

# The functions under test, lifted out of the script the way the other resolver
# fixtures do it — the script's top level is a whole lane run.
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
fn() { awk -v F="^$1\\(\\)" '$0~F{f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh"; }
# br_fix_cap/br_shape/br_rebuild_cap ride along because br_fix_round asks the
# cap for the ticket BEFORE it reads anything (BH-579): without them `cap` was
# empty, `[ "$n" -ge "" ]` printed `integer expression expected` on stderr and
# the cap check this suite walks through was not the real one.
for f in br_use_token br_auth_log br_slug_of_url br_pr_ref br_mechanical br_fix_round \
         br_shape br_fix_cap br_rebuild_cap br_cap_rows br_rows_count; do
  src=$(fn "$f"); [ -n "$src" ] || { echo "FAIL: $f not found in bin/blocked-resolver.sh"; exit 1; }
  eval "$src"
done
declare -A _BR_AUTH_SAID

RL=https://github.com/example-org/project-5/pull/1696   # rate limited (rc 1 + stderr)
EMPTY=https://github.com/example-org/project-5/pull/1694 # rc 0, empty body
GONE=https://github.com/example-org/project-5/pull/8888  # read fine, head.ref null
GOOD=https://github.com/example-org/project-5/pull/1677  # read fine, has a branch

# --- 1. br_pr_ref's three exit codes ----------------------------------------
out=$(br_pr_ref "$GOOD"); rc=$?
[ "$rc" = 0 ] && ok || bad "a readable PR must be rc 0, got $rc"
[ "$out" = "example-org/project-5 ticket/TK-1669 aaaabbbbccccddddeeeeffff00001111deadbeef" ] && ok \
  || bad "rc 0 prints slug branch head, got '$out'"

out=$(br_pr_ref "$GONE"); rc=$?
[ "$rc" = 1 ] && ok || bad "a PR that was READ and has a null head.ref must be rc 1, got $rc"

out=$(br_pr_ref "$RL"); rc=$?
[ "$rc" = 2 ] && ok || bad "a rate-limited read must be rc 2, got $rc"
case "$out" in *"API rate limit already exceeded for user ID 2220366"*) ok ;;
  *) bad "rc 2 must carry gh's own first error line, got '$out'" ;; esac
# One line of it, not the whole of gh's chatter.
[ "$(printf '%s' "$out" | wc -l)" = 0 ] && ok || bad "rc 2 must return ONE line, got '$out'"

out=$(br_pr_ref "$EMPTY"); rc=$?
[ "$rc" = 2 ] && ok || bad "an empty body is a failed read (rc 2), not a branchless PR, got $rc"

# It really did try twice — once as-is, once under the repo's own token.
[ "$(grep -c 'pulls/1696' "$T/gh.txt")" -ge 2 ] && ok \
  || bad "a failed read must be re-tried under the repo's own token: $(cat "$T/gh.txt")"
# And never over GraphQL, which is the bucket that ran out.
grep -q 'pr view' "$T/gh.txt" && bad "br_pr_ref must not use the GraphQL 'gh pr view'" || ok

# --- 2. the rungs ------------------------------------------------------------
mkdir -p "$H/bin"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
ST="$T/st"; mkdir -p "$ST"; LOG="$T/resolver.log"; REPOS="$T/repos"
OBSERVE=0; MAX_MECHANICAL=1; MAX_FIXROUNDS=1
say() { echo "$*" >> "$LOG"; }
br_cap_key() { echo "tkey"; }
br_load()    { echo '{}'; }
br_num()     { echo 0; }
br_event()   { echo "EVENT $*" >> "$T/rungs.txt"; }
br_record()  { echo "record $*" >> "$T/rungs.txt"; }
br_findings(){ echo ""; }
br_rerun_ci(){ return 1; }
br_setup_blocked(){ echo "SETUP_BLOCKED $*" >> "$T/rungs.txt"; }
br_rebuild_fresh(){ echo "REBUILD_FRESH $*" >> "$T/rungs.txt"; echo "enqueued $2" >> "$T/queue.txt"; }
mc_rebase()  { echo "MC_REBASE $*" >> "$T/rungs.txt"; printf '%s' "ffffffffffffffffffffffffffffffffffffffff"; return 0; }
reset() { : > "$T/rungs.txt"; : > "$T/queue.txt"; : > "$LOG"; for p in "${ST:?}"/*; do scratch_rm "$p"; done; }

# 2a. RUNG 1 ON A RATE-LIMITED READ: say so, spend nothing, cascade nowhere.
reset
br_fix_round() { echo "FIX_ROUND $*" >> "$T/rungs.txt"; }
br_mechanical project-5 example-org-project-5-1696 conflict-unresolvable "$RL" - TK-1669
grep -q 'PR read FAILED' "$LOG" && ok || bad "rung 1 must log the failed read: $(cat "$LOG")"
grep -q 'API rate limit already exceeded' "$LOG" && ok \
  || bad "the log line must carry gh's reason: $(cat "$LOG")"
grep -q 'no rung spent' "$LOG" && ok || bad "the log line must say no rung was spent: $(cat "$LOG")"
grep -qE 'FIX_ROUND|REBUILD_FRESH|MC_REBASE' "$T/rungs.txt" \
  && bad "rung 1 must take no rung on a failed read: $(cat "$T/rungs.txt")" || ok
grep -q 'record ' "$T/rungs.txt" && bad "a failed read must spend no counter: $(cat "$T/rungs.txt")" || ok
grep -q 'EVENT ' "$T/rungs.txt" && bad "a failed read must write no rung event: $(cat "$T/rungs.txt")" || ok
[ -s "$T/queue.txt" ] && bad "a failed read must enqueue nothing: $(cat "$T/queue.txt")" || ok
[ -z "$(ls -A "$ST")" ] && ok || bad "a failed read must write no state: $(ls -A "$ST")"

# 2b. RUNG 2 ON THE SAME READ. This is the one that cost the incident: rung 2
# read the same rc and walked on to REBUILD FRESH, which CLOSES the PR and
# enqueues a duplicate build of a ticket whose PR was fine. rc 2 must stop
# ABOVE every one of those paths — above the setup block #511 put on the
# branchless give-up too, because a read that failed has diagnosed nothing.
reset
unset -f br_fix_round; eval "$(fn br_fix_round)"
# The rung under test is the REAL br_fix_round, lifted out of the script by `fn`
# and eval'd above; the stub of the same name further down is what rung 1's own
# case uses. shellcheck reads the later stub as the only definition.
# shellcheck disable=SC2218
br_fix_round project-5 example-org-project-5-1696 conflict-unresolvable "$RL" - TK-1669
grep -q 'PR read FAILED' "$LOG" && ok || bad "rung 2 must log the failed read: $(cat "$LOG")"
grep -q 'REBUILD FRESH' "$LOG" && bad "rung 2 must NOT drop to REBUILD FRESH: $(cat "$LOG")" || ok
grep -q 'REBUILD_FRESH' "$T/rungs.txt" \
  && bad "rung 2 must not rebuild a PR it could not read: $(cat "$T/rungs.txt")" || ok
[ -s "$T/queue.txt" ] && bad "rung 2 must enqueue nothing: $(cat "$T/queue.txt")" || ok
[ -z "$(ls -A "$ST")" ] && ok || bad "rung 2 must write no state: $(ls -A "$ST")"

# 2c. THE OLD PATH SURVIVES. A PR that WAS read and genuinely has no branch —
# head repo deleted, head.ref null — still falls through exactly as before,
# which since #511 means the fix round's branchless give-up is a SETUP BLOCK:
# the rung never ran, so nothing escalates. rc 2 must not reach even this —
# a setup block names a park we DID diagnose, and a failed read diagnoses
# nothing, so the two stay different lines on different paths.
reset
# shellcheck disable=SC2218
br_fix_round project-5 example-org-project-5-8888 conflict-unresolvable "$GONE" - TK-8888
grep -q 'SETUP_BLOCKED' "$T/rungs.txt" && ok \
  || bad "rc 1 must reach br_setup_blocked: $(cat "$T/rungs.txt")"
# And it is named as the park it is — the reason br_setup_blocked carries is
# the branch derivation that came back empty, never a read that did not answer.
grep -q 'no repo/branch could be resolved' "$T/rungs.txt" && ok \
  || bad "the setup block must name the empty derivation: $(cat "$T/rungs.txt")"
grep -q 'PR read FAILED' "$LOG" && bad "a PR that WAS read must not claim a failed read: $(cat "$LOG")" || ok

# 2d. And a PR that reads fine still runs the rung it was always going to run.
reset
br_fix_round() { echo "FIX_ROUND $*" >> "$T/rungs.txt"; }
br_mechanical project-5 example-org-project-5-1677 conflict-unresolvable "$GOOD" - TK-1669
grep -q 'MC_REBASE example-org/project-5 project-5 ticket/TK-1669' "$T/rungs.txt" && ok \
  || bad "a readable PR must still reach rung 1: $(cat "$T/rungs.txt")"
grep -q 'PR read FAILED' "$LOG" && bad "a readable PR must not log a failed read: $(cat "$LOG")" || ok

echo "resolver-pr-read-failed: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
