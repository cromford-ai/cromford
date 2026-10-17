#!/bin/bash
# SCALE-PLAN wave 4a+ — the LANDER (the operator go: 2026-08-13). When the merge queue
# hits a conflicted / type-stale PR, this stage tries to land it the way the
# orchestrator did by hand all of 2026-08 (TK-24, TK-49 x2, TK-57, TK-189):
# merge fresh main INTO the PR branch in a worktree, have an agent resolve the
# conflicts keeping BOTH sides' intent, then verify independently before push.
# Semantic conflicts the agent can't resolve keep today's behavior — blocked
# for a human with one beat. The queue itself still serializes all landings.
#
# usage: lander.sh <project> <pr-number>
# exit 0 = branch resolved+pushed (caller requeues the PR), 1 = not resolved.
# Gates: flags/automerge-disabled kills it; flags/lander-disabled-<project>
# opts a project out. One attempt per PR head SHA (state/lander/).
set -uo pipefail
PROJECT="${1:?project}"; NUM="${2:?pr-number}"
HARNESS=/root/harness
. "${HARNESS}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$PROJECT.env" 2>/dev/null; set +a
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
# THE ROW TWIN of state/lander/ (BH-1036). "One attempt per PR head" is a file on
# one machine, so a hub wipe buys the same failed resolution session again.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=bin/lib/ledger-twin.sh
[ -r "$HARNESS/bin/lib/ledger-twin.sh" ] && . "$HARNESS/bin/lib/ledger-twin.sh"
# The configured commit identity and the author check before the push (BH-1134).
# Missing, gi_check is undefined and the push is refused.
# shellcheck source=bin/lib/git-identity.sh
. "$HARNESS/bin/lib/git-identity.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/git-identity.sh" 2>/dev/null || true
# The lane's own merge and commit below run under the same pin (it beats their
# `-c user.*`), so the check never refuses a commit the lane made itself.
command -v gi_export >/dev/null 2>&1 && { gi_resolve; gi_export; }
# A box mid-sync can carry this script without the library; every verb then
# answers "no row", which is today's behaviour exactly.
declare -F lt_on >/dev/null 2>&1 || { lt_on() { return 1; }; lt_get() { return 1; }; lt_read() { LT_VAL=""; return 1; }; lt_seen() { return 1; }; lt_put() { return 0; }; }
if command -v flag_active >/dev/null 2>&1; then flag_active automerge-disabled && exit 1
else [ -f "$HARNESS/flags/automerge-disabled" ] && exit 1; fi
# This board's own auto-merge toggle (#2322).
if command -v flag_active >/dev/null 2>&1; then flag_active "automerge-disabled-$PROJECT" && exit 1
else [ -f "$HARNESS/flags/automerge-disabled-$PROJECT" ] && exit 1; fi
if command -v flag_active >/dev/null 2>&1; then flag_active "lander-disabled-$PROJECT" && exit 1
else [ -f "$HARNESS/flags/lander-disabled-$PROJECT" ] && exit 1; fi
# BH-4080: the merge identity's defaults live in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
# THE LANDER'S PROJECT SET is unchanged by BH-4080: it runs only for the four
# in-app-board projects it always served. fleet.conf gives every project a repo,
# so the slug read below must not widen it: elsewhere a conflict or a red
# typecheck keeps parking and alerting, never buys a paid fix agent that pushes
# into the PR branch. Widening it is its own ticket and behaviour change.
case "$PROJECT" in
  project-1|project-2|project-3|project-4) ;;
  *) exit 1 ;;
esac
# >>> deployment slug (BH-4080): the repo is fleet.conf's column 2. A project
# with no row gets no guessed slug: one log line and the lane stops.
SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
[ -n "$SLUG" ] || { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] lander: no repo slug in fleet.conf — refusing" >> "$HARNESS/logs/lander.log"; exit 1; }
# <<< deployment slug
LOG="$HARNESS/logs/lander.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
REPO_DIR="/root/repos/$PROJECT"
mkdir -p "$HARNESS/state/lander"

command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
read -r BR HEAD <<<"$(gh pr view "$NUM" -R "$SLUG" --json headRefName,headRefOid -q '.headRefName + " " + .headRefOid' 2>/dev/null)"
[ -n "$BR" ] && [ -n "$HEAD" ] || exit 1

# >>> model-route (BH-1510.2): model_routes role `lander` (LANDER_MODEL still
# wins when set). Resolved BEFORE the one-attempt mark below, so a missing route
# (rc 75, alerted by bin/lib/model-route.sh) never burns this head's attempt.
. "$HARNESS/bin/lib/lane-model.sh"
LANDER_M=$(lane_model LANDER_MODEL lander "$PROJECT") \
  || { echo "$(STAMP) [$PROJECT] #$NUM lander: no model route for role lander — not attempted" >> "$LOG"; exit 75; }
# <<< model-route

# One attempt per head SHA — a failed resolution must not loop-burn sessions.
MARK="$HARNESS/state/lander/$PROJECT-$NUM"
LK="$PROJECT#$NUM@$HEAD"
{ [ "$(cat "$MARK" 2>/dev/null)" = "$HEAD" ] || lt_seen lander "$LK"; } \
  && { echo "$(STAMP) [$PROJECT] #$NUM lander: already attempted at $HEAD" >> "$LOG"; exit 1; }
# The claim is recorded BEFORE the worktree and before the session is bought, so
# a crash after this point never re-buys the resolution. Both halves, file first.
echo "$HEAD" > "$MARK"
lt_put lander "$LK" attempted

WT=$(mktemp -d /tmp/lander-XXXX)
cleanup() { (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"; }
trap cleanup EXIT

(cd "$REPO_DIR" && git fetch -q origin main "$BR" && git worktree add -f "$WT" "origin/$BR" >/dev/null 2>&1) || exit 1
# MAIN ONLY ON A CONFLICT (BH-7042). A clean merge of main makes a new head
# that loses its verdict and restarts CI, and the merge queue already tests on
# current main. A clean or queued PR is not merged into and buys no session.
# rc 0/2 (conflict, stale schema stamp, cannot tell, no lib): merge as before.
# shellcheck source=bin/lib/main-merge-need.sh
{ command -v pr_needs_main_merge >/dev/null 2>&1 || . "$HARNESS/bin/lib/main-merge-need.sh" 2>/dev/null \
    || . "$(dirname "${BASH_SOURCE[0]}")/lib/main-merge-need.sh" 2>/dev/null; } || true
if command -v pr_needs_main_merge >/dev/null 2>&1; then
  MMN_WHY=$(pr_needs_main_merge "$SLUG" "$NUM" "$REPO_DIR" "$HEAD" origin/main)
  if [ "$?" = 1 ]; then
    echo "$(STAMP) [$PROJECT] #$NUM lander: main merge skipped: $(pr_main_merge_why "$MMN_WHY") at ${HEAD:0:8} — not resolved here" >> "$LOG"
    exit 1
  fi
fi
# The head this round starts from: the push below leases on it (BH-2504), so a
# lead commit that lands while the session resolves makes the push fail
# instead of being force-overwritten.
LEASE_SHA=$(git -C "$WT" rev-parse --verify -q "origin/$BR") || exit 1
(cd "$WT" && git checkout -qB "lander/$BR" "origin/$BR" && \
  git -c user.name="$HARNESS_MERGE_GIT_NAME" -c user.email="$HARNESS_GIT_EMAIL" merge --no-edit origin/main >/dev/null 2>&1)
MERGE_RC=$?
CONFLICTED=$(cd "$WT" && git status --porcelain | grep -cE '^(UU|AA|DD|AU|UA)')

if [ "$MERGE_RC" -ne 0 ] && [ "$CONFLICTED" -eq 0 ]; then
  echo "$(STAMP) [$PROJECT] #$NUM lander: merge failed without conflicts (?) — giving up" >> "$LOG"
  exit 1
fi

if [ "$CONFLICTED" -gt 0 ]; then
  CONFLICT_FILES=$(cd "$WT" && git status --porcelain | awk '$1 ~ /U|AA|DD/ {print $2}' | head -40)
  OUT="$HARNESS/logs/lander-$PROJECT-$NUM.txt"
  # The resolution doctrine below is the distilled manual playbook (2026-08
  # rebase week). The agent resolves and verifies; the script re-verifies.
  PROMPT="You are resolving merge conflicts in the git worktree at $WT (branch lander/$BR: PR #$NUM merging current origin/main INTO the PR branch). Conflicted files:
$CONFLICT_FILES

Resolution doctrine — follow exactly:
1. Read BOTH sides of every conflict and identify each side's INTENT before touching anything. The goal is a resolution that keeps both intents; never pick a side wholesale without stating why in the commit message.
2. Both-append conflicts (two features appended to the same file — schema models, doc sections, config lists): keep BOTH blocks. Watch for a SHARED CLOSING DELIMITER swallowed by the conflict (a }, ), or heading that both sides need) — re-add it. Validate structured files after (prisma format/parse, JSON parse).
3. Structural rewrite vs patch (one side moved/rewrote what the other side patched): take the REWRITE's structure, re-apply the patch's behavior into the new structure. If code moved to a new file, port the patch there.
4. Guard tests are the spec: if the repo has palette/architecture guard tests, satisfy them by mapping values to the new convention (derive the mapping from the diff itself), never by editing the guard.
5. NEVER weaken, skip, or delete an existing test to make the merge pass. Never drop a migration. Schema changes must stay additive.
6. After resolving: run the repo's typecheck and, if present, the test suites relevant to the conflicted files (per its CLAUDE.md verification contract). Everything must pass.
7. Commit the merge (all files staged, no conflict markers) with a message starting 'Lander: merge main into $BR' that names each conflict and how you resolved it. Do NOT push. If you cannot produce a resolution you would defend in review — one that provably keeps both sides' behavior — stop and end your output with the single line LANDER_BLOCKED: <reason> and do not commit."
  AGENT_SYSTEM_APPEND="" "$HARNESS/bin/agent-call.sh" fix "$PROJECT" "$LANDER_M" 3600 "$OUT" "$PROMPT"
  if grep -q "LANDER_BLOCKED" "$OUT" 2>/dev/null; then
    echo "$(STAMP) [$PROJECT] #$NUM lander: agent declined — $(grep -o 'LANDER_BLOCKED.*' "$OUT" | head -c 120)" >> "$LOG"
    exit 1
  fi
fi

# Independent verification — the agent's word is never the gate.
# >>> lander conflict check
# Both reads go into variables first. As pipelines under pipefail they reported
# a CONFLICTED tree as clean: grep -q / head -1 exit at the first hit, the
# producer (git status in a big tree, or the recursive grep) dies of SIGPIPE,
# pipefail hands the pipeline 141, and the check fell through to `git add -A &&
# commit` — landing the unresolved tree as a "resolution" (BH-806).
ST=$(cd "$WT" && git status --porcelain 2>/dev/null)
MK=$(cd "$WT" && grep -rn "^<<<<<<< " --include="*.*" -l . 2>/dev/null | grep -v ".git")
if grep -qE '^(UU|AA|DD|AU|UA)' <<<"$ST" || [ -n "$MK" ]; then
  echo "$(STAMP) [$PROJECT] #$NUM lander: conflicts/markers remain after agent pass" >> "$LOG"
  exit 1
fi
# <<< lander conflict check
# Uncommitted resolution (agent forgot to commit) — commit it ourselves.
# BH-1138-PYCACHE-EXCLUDE: the same blunt whole-tree add as the checkpoint's, so
# the same exclusion. A python gate that ran in this worktree leaves __pycache__
# behind, and a tracked one is restaged by `git add -A` however the repo's
# .gitignore reads — that is how a byte-compiled artifact rode into main twice,
# inside a merge nobody was reviewing for it. The pathspec magic is spelled
# `:(exclude)` and not `:!`: git reads the short form's characters as more magic
# and dies with "Unimplemented pathspec magic '_'" on `:!__pycache__/*`, which
# `2>/dev/null` would have turned into a silently empty stage.
(cd "$WT" && git diff --quiet && git diff --cached --quiet) || \
  (cd "$WT" && git add -A -- . ':(exclude)__pycache__/*' ':(exclude)*/__pycache__/*' ':(exclude)*.pyc' ':(exclude)*.pyo' && git -c user.name="$HARNESS_MERGE_GIT_NAME" -c user.email="$HARNESS_GIT_EMAIL" commit -q -m "Lander: merge main into $BR (resolution committed by lander)")

TC=ok
if (cd "$WT" && jq -e '.scripts.typecheck' package.json >/dev/null 2>&1); then
  (cd "$WT" && [ -d "$REPO_DIR/node_modules" ] && ln -sfn "$REPO_DIR/node_modules" node_modules 2>/dev/null; NODE_OPTIONS=--max-old-space-size=12288 npm run typecheck >/dev/null 2>&1) || TC=fail
fi
if [ "$TC" != ok ]; then
  echo "$(STAMP) [$PROJECT] #$NUM lander: post-resolution typecheck FAILED" >> "$LOG"
  exit 1
fi

# NOTHING BUT THE CONFIGURED AUTHOR IS PUSHED (BH-1134). The agent committed the
# resolution, and an explicit --author is the one identity the session pin in
# bin/agent-call.sh cannot beat. A check that cannot run (no lib, a ref that will
# not resolve) refuses too.
GIRC=3; GIBAD=""
command -v gi_check >/dev/null 2>&1 && { GIBAD=$(gi_check "$WT" "origin/$BR" origin/main); GIRC=$?; }
if [ "$GIRC" != 0 ]; then
  if [ "$GIRC" = 1 ]; then
    echo "$(STAMP) [$PROJECT] #$NUM lander: commit author is not $GI_EMAIL ($(printf '%s' "$GIBAD" | awk '{printf "%s ", $1}')) — not pushed" >> "$LOG"
  else
    echo "$(STAMP) [$PROJECT] #$NUM lander: commit author check could not run (bin/lib/git-identity.sh missing or git log failed) — not pushed" >> "$LOG"
  fi
  exit 1
fi
# NEVER A PLAIN FORCE (BH-2504): the ticket's hold is re-read at the push and
# the branch must still be where this round found it.
# shellcheck source=bin/lib/hold-push.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null || . "$HARNESS/bin/lib/hold-push.sh" 2>/dev/null
HOLD_PUSH_LOG="$LOG" hold_push "$PROJECT" - "$WT" origin "lander/$BR" "$BR" "$LEASE_SHA" 2>/dev/null \
  || { echo "$(STAMP) [$PROJECT] #$NUM lander: not pushed (a HOLD on the ticket, an unreadable hold, or $BR moved since ${LEASE_SHA:0:8}: the hold-push line above says which)" >> "$LOG"; exit 1; }
echo "$(STAMP) [$PROJECT] #$NUM lander: RESOLVED and pushed ($CONFLICTED conflicted files) — requeue for landing" >> "$LOG"
"$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "lander:$PROJECT:$NUM" \
  --arg l "Lander auto-resolved #$NUM against fresh main ($CONFLICTED conflicted files, typecheck green) — back in the merge queue." \
  '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
