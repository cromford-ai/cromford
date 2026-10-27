#!/bin/bash
# bin/lib/mc/train.sh — BH-1269: what a MERGE TRAIN learned on 2026-09-21.
#
# Sourced by bin/batch-resolve.sh (its only caller), never executed. It is a
# module of bin/lib/mc/ rather than a block inside bin/lib/merge-conductor-lib.sh
# because that lib is being thinned to a shim (BH-477 / #1191) and a new helper
# put in it would have to move again the week it lands.
#
# THE DAY THIS CAME FROM. A Mac ran merge trains by hand against this repo for
# one day — ~52 merges — with a script a fifth the size of bin/batch-resolve.sh,
# and beat the lane on throughput for three reasons the lane did not have:
#
#   1. IT RAN TRAINS OF ONE. A train of one costs exactly one CI run, which is
#      what a direct merge costs, and it keeps the train's post-merge closure
#      (every member closed as merged by ancestry) and its merge-tree checks.
#      Waiting for a second member bought nothing and cost hours.
#   2. IT REBASED AN INHERITED RED INSTEAD OF RERUNNING IT. When main is red,
#      every open PR's own CI is red too — it ran against that main. GitHub pins
#      a workflow run to the merge commit it was created for, so
#      `rerun-failed-jobs` re-tests the SAME stale union and comes back red
#      (proved on #1238/#1239/#1235 at 13:54Z). Only a rebase onto current main
#      creates a fresh merge ref and therefore a fresh run.
#   3. IT DID NOT WAIT FOR A DETECTOR. A PR labelled `fix-main-red` whose own CI
#      concluded success IS main's next state; when it merges, the freeze is
#      over at that instant, not at the detector's next pass over main. That
#      wait cost ~20 minutes per red episode, three times in one day.
#
# WHAT A CARRY IS ALLOWED TO BE. A rebase moves the head, and a head-bound
# APPROVE does not move with it unless something says the patch is the same
# patch. mc_patch_id_rebind (bin/lib/mc/settle.sh) is the strict form: a
# `git patch-id` over the whole diff, CONTEXT LINES INCLUDED — so a neighbouring
# line that changed on main breaks it and buys a re-review of a diff nobody
# touched. The form here is the one the day's carry used: the sorted set of the
# patch's OWN added and removed lines must be identical, and context-only drift
# is allowed. It is still conservative by construction — it can say "this is the
# same patch" and it can never say "close enough": one different +/- line and
# the carry is REFUSED and the ordinary re-review path owns the PR.
#
# EVERY GitHub READ HERE IS REST (bin/lib/gh-rest.sh). gh-rest: no-graphql.

# The check runs that are NOT this repo's CI: Mergify's own reporter, which is
# pending until the queue takes the PR, and the share-mirror publish, which
# fails on a leak-guard hit without saying anything about the diff. `^Mergify`
# and not a full name on purpose — the reporter has been called both "Mergify
# Merge Protections" and "Mergify Merge Queue", and a name that drifts out of
# this list would make a queued Mergify run read as "this head is still
# pending" and the freeze lift would then never fire. A fixture or an operator
# may widen it; it is an ERE matched against the check run's name.
# BH-4080: the merge identity's defaults live in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-${BASH_SOURCE[0]%/*}/../deployment.sh}" || return 1
MC_TRAIN_CI_IGNORE="${BATCH_CI_IGNORE:-^(Mergify|Publish share mirror)}"

# MERGIFY'S OWN CHECK RUNS ARE NEVER THIS HEAD'S CI (BH-8623). The name list
# above missed the queue-rule run, `Rule: queue on the harness label (queue)`:
# at 16:06Z on 2026-10-27 a CANCELLED run of it read as #8570's own CI red, the
# lane rebased and force-pushed the PR, and the push dequeued it from Mergify
# batch #8620. A run whose app is `mergify` is Mergify's whatever its name. A
# run with no app object falls back to the name ERE mc_mergify_check reads.
# A run from any other app is own CI, so a job named `lint (queue)` counts.
MC_TRAIN_MERGIFY_JQ='def mergify_run: if ((.app.slug // "") != "") then (.app.slug == "mergify")
  else ((.name // "") | test("^Mergify|^Queue:|\\(queue\\)")) end;'

# THE WORKFLOW RUN A HEAD IS JUDGED ON, by name. Check-run COUNTS lie: train
# #1229 merged at 08:45Z on "0 pending, 6 ok" while its shard jobs were still
# waiting for a pool runner and had raised no check runs at all, and the run
# failed at 08:54Z. So the workflow run is asked for as well, and when this repo
# has one of this name for the sha it must have CONCLUDED SUCCESS. A repo with
# no run of this name is judged on its check runs alone, which is the strict
# gate below and not a waiver.
MC_TRAIN_CI_WORKFLOW="${BATCH_CI_WORKFLOW:-Harness CI}"

# The fix label's default, for the one case the resolver is not loaded (a box
# whose sync has not landed bin/lib/main-red-label.sh). BH-1770 made the label
# ONE knob, so nothing below guesses between two spellings any more.
MC_TRAIN_RED_LABEL_DEFAULT=fix-main-red

# MUST a run of that workflow EXIST before a head can be called green? On this
# fleet, yes, and the reason is our own push identity: a push made with the App
# token raises NO `pull_request` run, so a fix PR landed that way carries a
# `Summary` success, a neutral Mergify run and ZERO runs of the named workflow —
# a head whose shards never ran, which the check-runs half alone reads as green
# and would lift a fleet-wide freeze onto. 1 refuses that and says so in the log.
# 0 is the fallback for a repo that genuinely raises no workflow of this name,
# where requiring one would make its freezes unliftable for ever.
#
# The name is BATCH_CI_RUN_REQUIRED and not BATCH_CI_WORKFLOW_REQUIRED because
# the settings key that spelling builds for the longest project in fleet.conf,
# `lane.batch-resolve.project-8.batch_ci_workflow_required`, is 65
# characters and PUT /api/settings refuses anything over 64. A knob an operator
# cannot set is not a knob (tests/lanes-registry-test.sh case 9).
MC_TRAIN_CI_REQUIRED="${BATCH_CI_RUN_REQUIRED:-1}"

# mrt_iso_at <epoch> — the epoch as an ISO-8601 Z stamp, on GNU date and on BSD
# date. Printed empty when neither spelling works, and every caller treats an
# empty answer as "no lower bound I can prove", which is the conservative arm.
mrt_iso_at() {
  local e="${1:-}"
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  date -u -d "@$e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && return 0
  date -u -r "$e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && return 0
  return 1
}

# mrt_own_red <slug> <sha> — the names of this head's OWN check runs that
#   CONCLUDED badly, semicolon-joined. rc 0 = at least one is red, rc 1 = none,
#   rc 2 = GitHub could not be read (which is never "green": a candidate whose
#   CI nobody can read is left exactly where it is).
#
#   WHY A TRAIN NEEDS THIS AT ALL. A member whose own head is red sinks the
#   whole union: at 04:08Z one PR's replay-evals job, red on a dead credential,
#   took ten PRs down with it and bought a binary split to find out. Reading it
#   BEFORE the union is built is one API call per candidate against a split that
#   costs a full CI run per half.
mrt_own_red() {
  local slug="${1:-}" sha="${2:-}" body="" names
  [ -n "$slug" ] && [ -n "$sha" ] || return 2
  # BH-1485: `gh_rest_var`, never `body=$(gh_rest GET …)` — the capture was a
  # subshell and GH_REST_STATUS/GH_REST_REASON died in it, so a train that
  # skipped a candidate on a 403 logged the same nothing as one that skipped it
  # on a dead network.
  gh_rest_var body GET "repos/$slug/commits/$sha/check-runs" -F per_page=100 2>/dev/null || return 2
  names=$(printf '%s' "$body" | jq -r --arg ig "$MC_TRAIN_CI_IGNORE" "$MC_TRAIN_MERGIFY_JQ"'
    [ .check_runs[]? | select((.name // "") | test($ig) | not) | select(mergify_run | not)
      | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")
      | .name ] | join("; ")' 2>/dev/null) || return 2
  [ -n "$names" ] || return 1
  printf '%s' "$names"
  return 0
}

# mrt_head_green <slug> <sha> — rc 0 ONLY when this head has actually passed.
#   rc 1 for everything else, including every unreadable answer: a freeze is
#   lifted on a fact or not at all.
#
#   "NO FAILURE" IS NOT "GREEN", and the difference is the whole of this
#   function. mrt_own_red answers "has anything concluded badly", which is
#   vacuously true — and therefore silently wrong — on a head with ZERO check
#   runs, with everything still queued or in_progress, with only skipped or
#   neutral ones, or with only names the ignore list drops. A `fix-main-red` PR
#   admin-merged while its CI is still running is the most likely way a human
#   lands a hot fix during a red episode, and on any of those shapes the older
#   code lifted the fleet-wide freeze onto an unproven base.
#
#   So all four of these must hold:
#     * the named CI workflow run for this sha is `completed` and `success`, and
#       nothing of that name is still in flight. A sha with NO run of that name
#       REFUSES while MC_TRAIN_CI_REQUIRED is 1 — the default, and this fleet's
#       shape, because an App-token push raises no `pull_request` run at all, so
#       "no run" is exactly what a merged fix whose shards never ran looks like;
#     * at least one non-ignored check run exists;
#     * every one of them is `completed` — nothing queued, nothing in flight;
#     * none concluded badly, and at least one concluded `success`, so a head
#       whose only check runs were skipped or neutral proves nothing.
# MRT_GREEN_WHY carries the refusal out in the CALLING shell, for the lane's one
# log line: a freeze that stands because the fix is not green yet is something an
# operator has to be able to read, and a memo written inside $( ) dies with the
# subshell (bin/lib/main-red-gate.sh's MRG_FLAG, same reason).
MRT_GREEN_WHY=""
mrt_head_green() {
  local slug="${1:-}" sha="${2:-}" runs="" st body="" ans
  MRT_GREEN_WHY=""
  [ -n "$slug" ] && [ -n "$sha" ] || return 1
  gh_rest_var runs GET "repos/$slug/actions/runs" -f "head_sha=$sha" -F per_page=20 2>/dev/null \
    || { MRT_GREEN_WHY="the workflow runs for ${sha:0:12} could not be read (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON})"; return 1; }
  # THE NEWEST RUN OF THAT NAME, AND NOTHING OF THAT NAME STILL RUNNING.
  # `sort_by(.run_attempt)` was wrong twice over: the list API returns one entry
  # per run at its LATEST attempt, so the key ties, and it orders newest-first —
  # so `last` picked the OLDEST run and a head with [in_progress (new), success
  # (old)] read green. Two runs for one sha is an ordinary fleet shape:
  # mc_kick_ci's close/reopen raises a second `pull_request` run for the same
  # head, and so does a workflow_dispatch on the fix branch.
  #
  # `created_at` then `id` is the order mrt_run_id already uses, so the two
  # helpers agree about which run is "the" run. The pending test is separate and
  # comes first: an older run that was superseded may legitimately be cancelled,
  # but nothing of that name may still be in flight when a freeze is lifted.
  st=$(printf '%s' "$runs" | jq -r --arg w "$MC_TRAIN_CI_WORKFLOW" '
    [ .workflow_runs[]? | select((.name // "") == $w) ] as $r
    | if ($r | length) == 0 then ""
      elif ([ $r[] | select((.status // "") != "completed") ] | length) > 0 then "pending"
      else ($r | sort_by((.created_at // ""), (.id // 0)) | last | (.conclusion // "?")) end' 2>/dev/null) || return 1
  if [ -z "$st" ]; then
    if [ "$MC_TRAIN_CI_REQUIRED" = 1 ]; then
      MRT_GREEN_WHY="no $MC_TRAIN_CI_WORKFLOW run for ${sha:0:12} — not lifting (BATCH_CI_RUN_REQUIRED=1; an App-token push raises none, so this is what a head whose shards never ran looks like)"
      return 1
    fi
  elif [ "$st" != success ]; then
    MRT_GREEN_WHY="the $MC_TRAIN_CI_WORKFLOW run for ${sha:0:12} is '$st', not a concluded success"
    return 1
  fi
  gh_rest_var body GET "repos/$slug/commits/$sha/check-runs" -F per_page=100 2>/dev/null \
    || { MRT_GREEN_WHY="the check runs for ${sha:0:12} could not be read (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON})"; return 1; }
  ans=$(printf '%s' "$body" | jq -r --arg ig "$MC_TRAIN_CI_IGNORE" '
    [ .check_runs[]? | select((.name // "") | test($ig) | not) ] as $c
    | if ($c | length) == 0 then "none"
      elif ([ $c[] | select(.status != "completed") ] | length) > 0 then "pending"
      elif ([ $c[] | select(.conclusion == "failure" or .conclusion == "timed_out"
                            or .conclusion == "cancelled" or .conclusion == "action_required"
                            or .conclusion == "stale") ] | length) > 0 then "red"
      elif ([ $c[] | select(.conclusion == "success") ] | length) == 0 then "inconclusive"
      else "green" end' 2>/dev/null) || return 1
  if [ "$ans" != green ]; then
    MRT_GREEN_WHY="the check runs for ${sha:0:12} read '$ans', not green"
    return 1
  fi
  return 0
}

# mrt_run_cancel <slug> <run-id> — stop a workflow run nothing is waiting for
#   any more. Best effort and never load-bearing: a train that has been closed
#   and whose branch is gone is finished either way, but its run keeps a pool
#   runner busy for as long as it takes to finish testing a branch that no
#   longer exists.
mrt_run_cancel() {
  local slug="${1:-}" id="${2:-}"
  [ -n "$slug" ] || return 1
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  gh_rest POST "repos/$slug/actions/runs/$id/cancel" >/dev/null 2>&1
}

# mrt_run_id <slug> <sha> — the newest workflow run id for a sha, or nothing.
#   Recorded on the train's D1 row so Mission Control can link the ONE run a
#   train bought. Never load-bearing: an unreadable answer leaves the field null.
mrt_run_id() {
  local slug="${1:-}" sha="${2:-}" body="" id
  [ -n "$slug" ] && [ -n "$sha" ] || return 1
  gh_rest_var body GET "repos/$slug/actions/runs" -f "head_sha=$sha" -F per_page=20 2>/dev/null || return 1
  id=$(printf '%s' "$body" | jq -r '[.workflow_runs[]?] | sort_by(.run_started_at // "") | last | .id // empty' 2>/dev/null)
  [ -n "$id" ] && [ "$id" != null ] || return 1
  printf '%s' "$id"
}

# mrt_skip_listed <file> <num> — rc 0 when an operator has parked this PR.
#   READ LIVE, once per candidate, so a member can be taken out of the next
#   train by appending one line to a file — no restart, no flag, no deploy. One
#   PR number per line; `#` comments and blanks are ignored.
mrt_skip_listed() {
  local f="${1:-}" n="${2:-}"
  [ -n "$n" ] || return 1
  [ -r "$f" ] || return 1
  sed -e 's/#.*$//' -e 's/[[:space:]]//g' "$f" 2>/dev/null | grep -qxF "$n"
}

# mrt_lineset <repo> <from> <to> <exclude-file> — the sorted set of the patch's
#   own ADDED and REMOVED lines, one per line, on stdout. The exclude file holds
#   one pathspec per line (the repo's declared generated files): those are a
#   function of the tree and are regenerated on both sides, so they are not part
#   of the patch's identity.
mrt_lineset() {
  local repo="${1:-}" a="${2:-}" b="${3:-}" ex="${4:-}" p
  local -a spec=(.)
  if [ -n "$ex" ] && [ -r "$ex" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      spec+=(":!$p")
    done < "$ex"
  fi
  git -C "$repo" diff "$a" "$b" -- "${spec[@]}" 2>/dev/null \
    | grep -E '^[-+]' | grep -vE '^(\+\+\+|---)' | LC_ALL=C sort
}

# mrt_carry_ok <repo> <base-ref> <old-head> <new-head> <exclude-file>
#   rc 0 when the verdict recorded against <old-head> binds to <new-head>: the
#   two patches, each read against its OWN merge base with the base branch, have
#   an identical sorted +/- line set. rc 1 = they do not, and the caller owes a
#   re-review exactly as it did before.
mrt_carry_ok() {
  local repo="${1:-}" base="${2:-}" old="${3:-}" new="${4:-}" ex="${5:-}" bo bn t1 t2 rc=1
  [ -n "$repo" ] && [ -n "$old" ] && [ -n "$new" ] || return 1
  bo=$(git -C "$repo" merge-base "$base" "$old" 2>/dev/null) || return 1
  bn=$(git -C "$repo" merge-base "$base" "$new" 2>/dev/null) || return 1
  [ -n "$bo" ] && [ -n "$bn" ] || return 1
  t1=$(mktemp "${TMPDIR:-/tmp}/mrt-old.XXXXXX") || return 1
  t2=$(mktemp "${TMPDIR:-/tmp}/mrt-new.XXXXXX") || { rm -f "$t1"; return 1; }
  mrt_lineset "$repo" "$bo" "$old" "$ex" > "$t1"
  mrt_lineset "$repo" "$bn" "$new" "$ex" > "$t2"
  # An EMPTY set on both sides is not an identity: a diff nobody could read
  # (a sha the remote no longer has) reads as empty on both sides and would
  # carry an approval onto anything at all.
  if [ -s "$t1" ] && cmp -s "$t1" "$t2"; then rc=0; fi
  rm -f "$t1" "$t2"
  return "$rc"
}

# _mrt_run_regens <worktree> <regen-table-file> — run every distinct command the
#   repo declares, once, over this tree. A command that FAILS is not fatal and
#   not reported: a generator having a bad day must not park a PR, and the only
#   thing that matters here is whether the declared paths end up consistent.
#   That is also what makes this degrade to the pre-BH-1269 behaviour on a box
#   where nothing can run: no command works, nothing changes, nothing is
#   refused.
_mrt_run_regens() {
  local wt="$1" tbl="$2" cmd out
  out=$(mktemp "${TMPDIR:-/tmp}/mrt-regen.XXXXXX") || return 1
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    # `eval` of a string out of the repo's own markdown is the same trust level
    # as running that repo's test suite, which bin/batch-resolve.sh does two
    # functions away; both are the repo telling us how to build it. 9>&- so a
    # generator that leaves a process behind cannot hold the lane's dedupe lock,
    # </dev/null so one that reads stdin cannot swallow the remaining rows.
    ( cd "$wt" && eval "$cmd" ) >"$out" 2>&1 9>&- </dev/null || true
  done < <(cut -f2- "$tbl" | awk 'NF && !seen[$0]++')
  rm -f "$out"
  return 0
}

# _mrt_regen_dirty <worktree> <regen-table-file> — the declared paths that differ
#   from what is committed, space-joined. Prints nothing when they all agree.
_mrt_regen_dirty() {
  local wt="$1" tbl="$2" p dirty=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # `status --porcelain` and not `diff HEAD`: a generator that CREATES a
    # declared path leaves it UNTRACKED, which `diff` reports as no change at
    # all — and the stage-and-commit below would then quietly add a file no
    # check had looked at.
    [ -z "$(git -C "$wt" status --porcelain -- "$p" 2>/dev/null)" ] || dirty="${dirty:+$dirty }$p"
  done < <(cut -f1 "$tbl" | awk 'NF && !seen[$0]++')
  [ -n "$dirty" ] || return 1
  printf '%s' "$dirty"
}

# mrt_regen_settle <worktree> <regen-table-file> — make the repo's declared
#   generated files agree with the tree the rebase produced, committing ONE
#   regenerate commit if they do not. rc 0 = they agree now (nothing to do, or
#   one commit made it so). rc 1 = they do NOT settle: a second run still moves
#   them, which is a generator that does not converge and a tree nothing should
#   push. Prints the paths on rc 1.
#
#   WHY A COMMIT AND NOT A REFUSAL. The declared generated files are excluded
#   from the carry identity — they are a function of the tree and are rebuilt on
#   both sides — so regenerating them does not touch what the verdict is bound
#   to; carry.sh did exactly this and recorded it in the carried verdict. And a
#   refusal here would be a refusal almost every time: any branch that adds a
#   file which a generated index lists comes out of a rebase with that index
#   stale, by construction, because the member could not have predicted what the
#   base would add. Parking those would leave this lane unable to rebase
#   anything in the repo it was built for.
#
#   WHAT IS STILL REFUSED is the case the review named: a render that no longer
#   BUILDS from the rebased tree. A generator that cannot reach a fixed point
#   would otherwise be pushed as a head that is red for a brand-new reason —
#   and one that is no longer behind the base, so this lane would park it and
#   never retry.
mrt_regen_settle() {
  local wt="${1:-}" tbl="${2:-}" dirty p
  [ -n "$wt" ] || return 0
  [ -n "$tbl" ] && [ -s "$tbl" ] || return 0
  _mrt_run_regens "$wt" "$tbl"
  if dirty=$(_mrt_regen_dirty "$wt" "$tbl"); then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      git -C "$wt" add -A -- "$p" >/dev/null 2>&1 || true
    done < <(cut -f1 "$tbl" | awk 'NF && !seen[$0]++')
    git -C "$wt" diff --cached --quiet && return 0
    git -C "$wt" -c commit.gpgsign=false \
      -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
      commit -q -m "regenerate the repo's generated files after the rebase onto the base

The rebase is a pure replay and this commit touches only paths the repo itself
declares machine-written, so the head-bound verdict still binds: those paths are
excluded from the patch identity the carry is decided on." >/dev/null 2>&1 \
      || { printf '%s' "$dirty"; return 1; }
    # AND IT HAS TO CONVERGE. One more run: anything that still moves is a
    # generator with no fixed point on this tree, and pushing that is pushing a
    # head that is red for a new reason.
    _mrt_run_regens "$wt" "$tbl"
    if dirty=$(_mrt_regen_dirty "$wt" "$tbl"); then printf '%s' "$dirty"; return 1; fi
  fi
  return 0
}

# mrt_rebase_pure <repo> <remote> <base-ref> <head-branch> <head-sha>
#                 <exclude-file> [regen-table-file] [project] [pr-url]
#   [project] names the lane's project so the push can read the ticket's hold
#   (BH-2504, bin/lib/hold-push.sh); `-` or absent = lease only.
#   [pr-url] lets the push ask Mergify first (BH-8623); absent = no read.
#   A PURE rebase onto the base ref: no regenerate, no resolver, no merge of
#   main into the branch. Prints the new head sha. Exit codes:
#     0  rebased, the verdict carries, the renders still build, and the new head
#        is PUSHED
#     1  it did not rebase (a conflict, a failed worktree, a refused push) and
#        nothing was pushed
#     2  it rebased cleanly but the patch is NOT the same patch — a commit was
#        dropped as already-upstream, a hunk was auto-merged — so nothing was
#        pushed and a re-review is genuinely owed
#     3  it rebased cleanly and carries, but the repo's own generated files do
#        not SETTLE on the result — a generator with no fixed point — so nothing
#        was pushed: that is a real conflict wearing a clean rebase's clothes
#     4  it rebased cleanly and carries, but Mergify holds the PR (queued or
#        checking, mc_mergify_holds) — nothing was pushed: a push would dequeue
#        it and dissolve its batch (BH-8623)
#   On 3 the unsettled paths are printed, on 4 the Mergify reason. The worktree
#   is removed on every path.
#
#   WHY PURE, AND WHY EVERYTHING IS DECIDED BEFORE THE PUSH. The point is a
#   FRESH MERGE REF so GitHub raises a fresh run; any content change would move
#   the head for a second reason, and a head that moves without a carry costs a
#   paid re-review of a diff nobody wrote. So the carry and the render check are
#   both settled in the worktree, and a rebase that fails either is thrown away
#   instead of pushed.
mrt_rebase_pure() {
  local repo="${1:-}" remote="${2:-}" base="${3:-}" br="${4:-}" head="${5:-}" ex="${6:-}"
  local tbl="${7:-}" proj="${8:--}" url="${9:-}" w new drift mqwhy rc=1
  [ -n "$repo" ] && [ -n "$remote" ] && [ -n "$br" ] && [ -n "$head" ] || return 1
  w=$(mktemp -d "${TMPDIR:-/tmp}/mrt-rb-XXXXXX") || return 1
  if git -C "$repo" worktree add -f --detach "$w" "$head" >/dev/null 2>&1; then
    if git -C "$w" -c rebase.autoStash=false -c commit.gpgsign=false \
         -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
         rebase "$base" >/dev/null 2>&1; then
      new=$(git -C "$w" rev-parse HEAD 2>/dev/null)
      if [ -z "$new" ] || [ "$new" = "$head" ]; then
        rc=1
      elif ! mrt_carry_ok "$repo" "$base" "$head" "$new" "$ex"; then
        rc=2
      else
        # The generators are as likely to need the repo's deps as a typecheck
        # is; both twins link node_modules first (bin/lib/rebase-job.sh step 6b,
        # mc_rebase) and docs/verification-map/regen-on-rebase.md says so.
        [ -d "$repo/node_modules" ] && [ ! -e "$w/node_modules" ] \
          && ln -s "$repo/node_modules" "$w/node_modules" 2>/dev/null
        if ! drift=$(mrt_regen_settle "$w" "$tbl"); then
          printf '%s' "$drift"; rc=3
        else
          new=$(git -C "$w" rev-parse HEAD 2>/dev/null)
          # THE QUEUE IS READ AT THE PUSH (BH-8623), as mc_rebase does
          # (BH-8021): a push to a PR Mergify holds dequeues it and dissolves
          # its batch (#8570 left batch #8620 at 16:06Z on 2026-10-27). Held =
          # rc 4, nothing pushed. A read that fails pushes as before (BH-8021).
          if [ -n "$url" ] && command -v mc_mergify_holds >/dev/null 2>&1 \
             && [ "$(mc_queue_provider "$(mc_slug_of_url "$url")" 2>/dev/null)" = mergify ] \
             && mqwhy=$(mc_mergify_holds "$(mc_slug_of_url "$url")" "$url" "$head" 2>/dev/null); then
            printf '%s' "$mqwhy"; rc=4
          # A PR branch, rewritten: the hold is re-read and the lease is the
          # head this rebase started from (BH-2504, bin/lib/hold-push.sh).
          elif { command -v hold_push >/dev/null 2>&1 \
                 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hold-push.sh" 2>/dev/null; } \
             && HOLD_PUSH_LOG="${MC_LOG:-}" hold_push -n "$proj" - "$repo" "$remote" "$new" "$br" "$head" >/dev/null 2>&1; then
            printf '%s' "$new"; rc=0
          fi
        fi
      fi
    else
      git -C "$w" rebase --abort >/dev/null 2>&1
    fi
  fi
  rm -f "$w/node_modules" 2>/dev/null
  git -C "$repo" worktree remove -f "$w" >/dev/null 2>&1
  rm -rf "$w"
  return "$rc"
}

# mrt_carry_verdict <record-or-empty> <slug> <project> <num> <url> <new-head>
#                   <provenance> <key>
#   Bind the head-bound APPROVE to the new head — the same three writes
#   hb_approve_bind makes in bin/merge-conductor.sh, in the same order, because
#   a carry that wrote only one of them would leave the ledger and the record
#   disagreeing about which sha was read. A provenance hold that was already
#   cleared at the OLD head is cleared at the new one too: the diff is the same
#   diff, and the hold is about who read it.
mrt_carry_verdict() {
  local rec="${1:-}" slug="${2:-}" project="${3:-}" num="${4:-}" url="${5:-}" head="${6:-}"
  local prov="${7:--}" key="${8:-}"
  [ -n "$head" ] || return 1
  [ -n "$rec" ] && [ -d "$rec" ] && printf '%s\n' "$head" > "$rec/reviewed-sha"
  type job_verdict_rebind >/dev/null 2>&1 && job_verdict_rebind "$url" "$head" >/dev/null 2>&1 || true
  type mc_patch_id_remember >/dev/null 2>&1 \
    && mc_patch_id_remember "$rec" "$slug" "$project" "$num" "$head" >/dev/null 2>&1 || true
  if [ -n "$key" ] && type mc_prov_held >/dev/null 2>&1 && mc_prov_held "$prov"; then
    type mc_prov_clear >/dev/null 2>&1 && mc_prov_clear "$key" "$head"
  fi
  return 0
}

# mrt_main_red_fixed <slug> <flag-file> — prints "<pr-number>\t<head-sha>" and
#   rc 0 when a PR labelled `fix-main-red` has MERGED since the freeze went up
#   and its own CI on that head CONCLUDED SUCCESS. rc 1 otherwise, including
#   every unreadable answer: a freeze is only ever lifted on a fact.
#
#   THE LOWER BOUND IS THE FLAG FILE'S OWN MTIME, which is when this box learned
#   the freeze was on. Without it, a fix that merged during LAST week's episode
#   would lift this week's freeze the first time the lane ticked.
# MRT_FIX_WHY / MRT_FIX_NUM / MRT_FIX_HEAD are set in the CALLING shell, so this
# function must NOT be called inside $( ) — a memo written in a command
# substitution dies with the subshell that wrote it, which is how the first cut
# of the refusal log line came out empty in the suite.
MRT_FIX_WHY=""; MRT_FIX_NUM=""; MRT_FIX_HEAD=""
mrt_main_red_fixed() {
  MRT_FIX_WHY=""; MRT_FIX_NUM=""; MRT_FIX_HEAD=""
  local slug="${1:-}" flagf="${2:-}" since="" body="" pick num head label
  [ -n "$slug" ] || return 1
  if [ -e "$flagf" ]; then
    since=$(mrt_iso_at "$(mc_mtime "$flagf" 2>/dev/null || echo 0)" 2>/dev/null) || since=""
  fi
  [ -n "$since" ] || return 1
  # THE LABEL IS THE FLEET'S, never a literal (the review's Important 4), and
  # since BH-1770 it is ONE knob: bin/lib/main-red-label.sh resolves the
  # settings row, MC_MAIN_RED_LABEL and its deprecated alias MAIN_RED_LABEL the
  # same way for every lane and every build, so this asks it rather than
  # guessing which of two spellings somebody meant. Without the lib, the
  # conductor's resolved MC_MAIN_RED_LABEL, then the alias.
  label=""
  if command -v main_red_label_resolve >/dev/null 2>&1; then
    label=$(main_red_label_resolve 2>/dev/null)
  fi
  [ -n "$label" ] || label="${MC_MAIN_RED_LABEL:-${MAIN_RED_LABEL:-}}"
  [ -n "$label" ] || label="$MC_TRAIN_RED_LABEL_DEFAULT"
  gh_rest_var body GET "repos/$slug/pulls" -f state=closed -f sort=updated -f direction=desc \
           -F per_page=30 2>/dev/null || return 1
  pick=$(printf '%s' "$body" | jq -r --arg s "$since" --arg l "$label" '
    [ .[]? | select((.merged_at // null) != null) | select(.merged_at >= $s)
      | select([.labels[]?.name] | index($l))
      | {n: .number, h: (.head.sha // "")} ]
    | sort_by(.n) | last | if . == null then "" else "\(.n)\t\(.h)" end' 2>/dev/null)
  [ -n "$pick" ] || return 1
  num=${pick%%$'\t'*}; head=${pick##*$'\t'}
  [ -n "$num" ] && [ -n "$head" ] || return 1
  # Its own CI, on the head GitHub ran the merge ref for, and it must have
  # CONCLUDED SUCCESS — not merely "nothing has failed yet". A red, a pending,
  # an empty and an unreadable answer all leave the freeze exactly where it is.
  if ! mrt_head_green "$slug" "$head"; then
    MRT_FIX_WHY="the fix PR #$num merged but ${MRT_GREEN_WHY:-its head is not green}"
    return 1
  fi
  MRT_FIX_NUM="$num"; MRT_FIX_HEAD="$head"
  printf '%s\t%s' "$num" "$head"
  return 0
}

# mrt_row_put <project> <branch> <outcome> [k=v ...] — the train as a D1 row.
#   Fail-open like every other jobs-client call: no client, no worker, no row,
#   and the lane behaves exactly as it does today. The FILE record under
#   state/batch-resolve/ stays the thing this lane reads; the row is what
#   Mission Control shows and what lets a conductor resume a train after a box
#   restart.
mrt_row_put() {
  type merge_train_put >/dev/null 2>&1 || return 1
  merge_train_put "$@" >/dev/null 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# PARALLEL TRAINS — BH-1270
#
# ONE TRAIN IN FLIGHT BOUNDS THE BASE BRANCH'S MERGE RATE AT ONE CI RUN. A
# train costs one run whether it carries one member or eight, and the next one
# cannot start until the first has landed — so main's throughput is (members
# per train) / (CI wall time), and on 2026-09-21 that was ~17 minutes per
# train. Nothing about that wait is a safety property: two unions cut from the
# same base only meet if they TOUCH THE SAME FILES, and the conductor already
# knows what each PR's ticket set out to touch (bin/overlap-guard.sh and
# bin/overlap-schedule.sh have read `plans/<project>-<KEY>/planned-files.txt`
# since BH-475). So the set of verdict-bearing candidates is partitioned into
# groups that cannot meet, and one train per group is opened in ONE tick.
#
# WHAT MAKES A PARTITION SAFE, in one sentence: two candidates that could ever
# conflict must ride the SAME train, never two trains at once. That is the
# whole of the rule, and it is why the grouping below is a connected-component
# walk rather than a bin-packing. Overlap is an EDGE, a component is
# indivisible, and components are disjoint by construction — so any assignment
# of whole components to groups is safe, and merging two components into one
# group is always safe (it is just a bigger train).
#
# THE THREE THINGS THAT COUNT AS "COULD EVER CONFLICT":
#   1. their planned-file sets intersect under the file-equals-file /
#      dir-contains-file rule bin/conflict-check.sh already uses;
#   2. they touch the same MODULE DIRECTORY (MC_TRAIN_MODULE_DIRS) — two PRs
#      editing different files of one module are a textual non-conflict and a
#      semantic one, and a module's own suite is the thing that would catch it;
#   3. either one's set could not be determined at all. An unjudged candidate
#      conflicts with EVERYTHING, which collapses the partition back to a
#      single group — i.e. to BH-1269's behaviour, which is the conservative
#      arm and the one a missing plan must land on.

# MODULE BOUNDARIES, as this repo's own layout draws them. An entry ending in
# `*/` means the CHILD directory names the module (`bin/lib/mc/`,
# `bin/lib/jobs/`, `bin/lib/rb/` are three modules); an entry ending in `/`
# means the directory ITSELF is one module. Read into an ARRAY with `read -a`
# and never iterated as an unquoted word list: word splitting is followed by
# PATHNAME EXPANSION, and `bin/lib/*/` in a `for` would silently become
# whatever directories the caller happened to be standing in — the trap
# bin/overlap-guard.sh's IGNORE_PATS comment spells out.
#
# THE MOST-COUPLED DIRECTORIES ARE IN THE LIST (BH-1306). `bin/lib/` (the
# top-level shared libs every lane sources), `bin/` (the lane scripts) and
# `worker/jobs/src/lib/` (the worker's shared code) used to belong to no module
# at all, so two PRs editing the very files the whole fleet runs on could ride
# two trains at once on the strength of touching different ones. A wider list is
# the SAFE direction — it merges groups, it never splits them.
#
# ORDER MATTERS, because mrt_module_of takes the FIRST pattern that matches: the
# `*/` child pattern must come before its plain parent, or `bin/lib/mc/train.sh`
# would answer `bin/lib/` (and then `bin/`) and the three lib modules would
# collapse into one.
MC_TRAIN_MODULE_DIRS="${BATCH_MODULE_DIRS:-bin/lib/*/ bin/lib/ bin/ worker/jobs/src/routes/ worker/jobs/src/lib/ console-ui/src/screens/}"
MC_TRAIN_MODULE_PATS=()
IFS=' ' read -r -a MC_TRAIN_MODULE_PATS <<<"$MC_TRAIN_MODULE_DIRS"

# mrt_parallel_cap <declared> <runners> <jobs-per-run> — how many trains this
#   lane may have in flight at once. `declared` is TRAIN_PARALLEL; the other
#   two are the pool's declared size and what one CI run occupies of it, both
#   from the catalog (catalog/lanes.d/batch-resolve.json -> catalog/lanes.json).
#
#   THE LANE MUST NEVER DEMAND MORE CI THAN THE POOL HAS. N trains in flight
#   raise N concurrent runs of the repo's workflow, and this repo's run is 8
#   shard jobs wide (two 4-way matrices). Asking a pool of 8 runners for two of
#   those does not make anything faster — the second run's shards QUEUE, and a
#   queued job is indistinguishable from a slow one (docs/CI-RUNNERS.md), so
#   the lane would buy latency and an unreadable drain instead of throughput.
#
#   `runners` 0 means NOBODY HAS DECLARED A POOL SIZE, which is the default and
#   the honest state of this fleet: CI runs on `vars.CI_RUNNER`, hosted by
#   default, whose concurrency is the account's and not ours to count. Then
#   only the declared parallelism binds. A fleet that moves CI onto the Fly
#   pool sets the row and gets the arithmetic.
mrt_parallel_cap() {
  local want="${1:-1}" runners="${2:-0}" per="${3:-1}" fit
  case "$want" in ''|*[!0-9]*|0) want=1 ;; esac
  case "$runners" in ''|*[!0-9]*) runners=0 ;; esac
  case "$per" in ''|*[!0-9]*|0) per=1 ;; esac
  if [ "$runners" -gt 0 ]; then
    fit=$(( runners / per ))
    [ "$fit" -ge 1 ] || fit=1
    [ "$fit" -lt "$want" ] && want="$fit"
  fi
  printf '%s' "$want"
  return 0
}

# _mrt_pf_prune <src> <dst> — a planned-files list in its normal form: one
#   repo-relative path per line, sorted, deduped, no trailing slash. rc 0 only
#   when something survived.
#
#   THE `SOURCE:` HEADER IS DROPPED, and it is not a cosmetic strip:
#   bin/planned-files-cheap.sh writes which tier produced a list as the FIRST
#   LINE of the very file this reads, so two unrelated tickets both carrying
#   `SOURCE: ticket-body` would "intersect" on it and be forced into one train
#   for ever. bin/overlap-guard.sh's prune() and dep_norm drop it for the same
#   reason; this is the third reader of that file and it inherits the lesson.
_mrt_pf_prune() {
  local src="${1:-}" dst="${2:-}"
  [ -n "$dst" ] || return 1
  : > "$dst" 2>/dev/null || return 1
  [ -s "$src" ] || return 1
  sed -e 's/\r$//' -e 's|^\./||' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|/*$||' "$src" 2>/dev/null \
    | grep -v -e '^$' -e '^#' -e '^SOURCE:' -e '^source:' \
    | LC_ALL=C sort -u > "$dst"
  [ -s "$dst" ]
}

# mrt_plan_key <record-dir> <branch> — the ticket key whose plan to look for.
#   The build record's own meta first (it is what the launcher wrote), then the
#   record directory's name in the shape mc_issue_of reads it
#   (`<project>-<KEY>-<stamp>`, optionally `pool-` prefixed), then the branch's
#   last segment upper-cased, which is what `ticket/bh-1270` means.
mrt_plan_key() {
  local rec="${1:-}" br="${2:-}" k=""
  if [ -n "$rec" ] && [ -r "$rec/ticket-meta.json" ]; then
    k=$(jq -r '.key // .ticket_key // empty' "$rec/ticket-meta.json" 2>/dev/null)
    [ "$k" = null ] && k=""
  fi
  [ -n "$k" ] || { [ -n "$rec" ] && k=$(basename "$rec" 2>/dev/null \
      | sed -nE 's/^(pool-)?.*-([A-Za-z]+-[0-9]+)-[0-9]+$/\2/p'); }
  [ -n "$k" ] || k=$(printf '%s' "${br##*/}" | tr '[:lower:]' '[:upper:]')
  printf '%s' "$k"
  [ -n "$k" ]
}

# mrt_planned_files <harness> <project> <record> <branch> <repo> <base> <head>
#                   <dst>
#   The files this candidate claims, written to <dst>. rc 0 = a set was found
#   and MRT_PF_SOURCE says which of the three homes answered; rc 1 = UNJUDGED,
#   and the caller must treat it as conflicting with everything.
#
#   THREE HOMES, THE PATCH FIRST (BH-1306). The DIFF is the change this PR
#   actually carries and the thing its review was of; the pre-plan's list is a
#   PREDICTION of that diff, written before a line was typed, and the build
#   record's list is a copy of the same prediction. Reading the prediction first
#   — which is what BH-475's launch-scheduler order did here — means a PR whose
#   patch grew past its plan is partitioned on files it does not touch and, more
#   to the point, is called disjoint from a sibling it really meets. So the
#   order is diff, then plan, then build record.
#
#   BUT AN EMPTY DIFF IS NOT AN ANSWER. A PR whose whole patch is declared
#   generated output has nothing left once the exclude list is applied, and that
#   is not the same fact as "it touches nothing" — so the plan and the record
#   still speak for it, exactly as they did, and only a candidate with no
#   readable answer anywhere is UNJUDGED.
#
#   THE DIFF IS TAKEN AGAINST THE MERGE BASE (`base...head`), not `base..head`.
#   The two-dot form is every file that differs between the two commits, which
#   on a branch that is behind includes everything the BASE changed since — so
#   on a busy repo every candidate would "touch" every other candidate's files
#   and the partition would collapse to one group every time. The three-dot
#   form is the patch this PR actually carries, which is what "the files this
#   PR touches" means and what the review was of.
#
#   AND THE REPO'S DECLARED GENERATED FILES ARE SUBTRACTED (the optional 9th
#   argument, the same exclude list the carry identity uses). Every member of
#   every train rewrites the registry this lane regenerates — that is the whole
#   tail it exists for — so counting those paths would make every candidate
#   overlap every other one and the partition would collapse to one group on
#   the only repo this feature is for. A conflict there is not a reason to
#   serialise: it is resolved by the one regenerate each union already runs,
#   and by reform_train when the other group lands first.
MRT_PF_SOURCE=""
mrt_planned_files() {
  local h="${1:-}" proj="${2:-}" rec="${3:-}" br="${4:-}" repo="${5:-}"
  local base="${6:-}" head="${7:-}" dst="${8:-}" ex="${9:-}" key tmp
  MRT_PF_SOURCE=""
  [ -n "$dst" ] || return 1
  : > "$dst" 2>/dev/null || return 1
  if [ -n "$repo" ] && [ -n "$base" ] && [ -n "$head" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/mrt-pf.XXXXXX") || return 1
    git -C "$repo" diff --name-only "$base...$head" > "$tmp" 2>/dev/null
    if _mrt_pf_prune "$tmp" "$dst" && _mrt_pf_exclude "$dst" "$ex"; then
      rm -f "$tmp"; MRT_PF_SOURCE="diff"; return 0
    fi
    rm -f "$tmp"
  fi
  key=$(mrt_plan_key "$rec" "$br")
  if [ -n "$key" ] && [ -n "$h" ] && [ -n "$proj" ] \
     && _mrt_pf_prune "$h/plans/$proj-$key/planned-files.txt" "$dst"; then
    MRT_PF_SOURCE="plan:$key"; _mrt_pf_exclude "$dst" "$ex"; return $?
  fi
  if [ -n "$rec" ] && _mrt_pf_prune "$rec/planned-files.txt" "$dst"; then
    MRT_PF_SOURCE="build-record"; _mrt_pf_exclude "$dst" "$ex"; return $?
  fi
  # The diff arm above may have left a pruned-then-emptied set behind, and an
  # UNJUDGED candidate must leave <dst> empty: _mrt_pair_conflicts reads a
  # non-empty file as "these are the files it touches".
  : > "$dst" 2>/dev/null
  return 1
}

# _mrt_pf_exclude <set-file> <exclude-file> — drop the repo's declared generated
#   files from a set, in place. The exclude file holds one path-or-glob per line
#   (`cut -f1` of the regenerate table), matched the way bin/batch-resolve.sh's
#   regen_cmd_for matches them: literal first, then as a glob. rc 1 when
#   NOTHING survives, which makes the candidate UNJUDGED — the conservative
#   arm, and the right one for a PR that is nothing but regenerated output.
_mrt_pf_exclude() {
  local dst="${1:-}" ex="${2:-}" f p keep tmp
  [ -n "$ex" ] && [ -s "$ex" ] && [ -s "$dst" ] || { [ -s "$dst" ]; return $?; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/mrt-pfx.XXXXXX") || { [ -s "$dst" ]; return $?; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    keep=1
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ "$p" = "$f" ] && { keep=0; break; }
      # shellcheck disable=SC2254
      case "$f" in $p) keep=0; break ;; esac
    done < "$ex"
    [ "$keep" = 1 ] && printf '%s\n' "$f"
  done < "$dst" > "$tmp"
  mv -f "$tmp" "$dst" 2>/dev/null || rm -f "$tmp"
  [ -s "$dst" ]
}

# mrt_modules_of <set-file> <dst> — the module directories a file set reaches,
#   one per line. Empty when it reaches none, which is not an error: a PR that
#   touches only top-level docs belongs to no module and is judged on its files
#   alone.
mrt_modules_of() {
  local src="${1:-}" dst="${2:-}" f m
  [ -n "$dst" ] || return 1
  : > "$dst" 2>/dev/null || return 1
  [ -s "$src" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m=$(mrt_module_of "$f") || continue
    printf '%s\n' "$m"
  done < "$src" | LC_ALL=C sort -u > "$dst"
  return 0
}

# mrt_module_of <path> — the module directory this path belongs to, or rc 1.
mrt_module_of() {
  local f="${1:-}" p pre rest
  [ -n "$f" ] || return 1
  for p in ${MC_TRAIN_MODULE_PATS+"${MC_TRAIN_MODULE_PATS[@]}"}; do
    [ -n "$p" ] || continue
    case "$p" in
      */'*'/)
        pre="${p%'*'/}"
        case "$f" in
          "$pre"?*/?*) rest="${f#"$pre"}"; printf '%s/' "$pre${rest%%/*}"; return 0 ;;
        esac ;;
      */)
        case "$f" in "$p"?*) printf '%s' "$p"; return 0 ;; esac ;;
    esac
  done
  return 1
}

# mrt_sets_overlap <a> <b> — rc 0 when the two path sets INTERSECT under
#   bin/conflict-check.sh's rule: a path of one equals, or is a directory
#   prefix of, a path of the other. An empty or missing set never intersects —
#   the caller, not this function, decides what an unjudged candidate means.
mrt_sets_overlap() {
  local a="${1:-}" b="${2:-}"
  [ -s "$a" ] && [ -s "$b" ] || return 1
  awk '
    function ancestors(p,   n, parts, i, acc) {
      n = split(p, parts, "/")
      acc = ""
      for (i = 1; i < n; i++) { acc = (i == 1 ? parts[1] : acc "/" parts[i]); D[acc] = 1 }
    }
    NR == FNR { A[$0] = 1; ancestors($0); next }
    {
      if ($0 in A) { found = 1; exit }
      if ($0 in D) { found = 1; exit }
      n = split($0, parts, "/"); acc = ""
      for (i = 1; i < n; i++) {
        acc = (i == 1 ? parts[1] : acc "/" parts[i])
        if (acc in A) { found = 1; exit }
      }
    }
    END { exit(found ? 0 : 1) }' "$a" "$b" 2>/dev/null
}

# _mrt_pair_conflicts <set-dir> <a> <b> — rc 0 when these two candidates must
#   ride the SAME train. <set-dir> holds `<num>.files` and `<num>.mods` per
#   candidate, as mrt_planned_files and mrt_modules_of wrote them.
#
#   A MISSING OR EMPTY `.files` IS A CONFLICT WITH EVERYTHING. That is the one
#   direction this may fail in: a candidate nobody can judge must not be the
#   reason two unions that do meet were run side by side, and folding it into
#   the others' component costs exactly the throughput BH-1269 already had.
_mrt_pair_conflicts() {
  local d="${1:-}" a="${2:-}" b="${3:-}"
  [ -s "$d/$a.files" ] && [ -s "$d/$b.files" ] || return 0
  mrt_sets_overlap "$d/$a.files" "$d/$b.files" && return 0
  mrt_sets_overlap "$d/$a.mods"  "$d/$b.mods"  && return 0
  return 1
}

# mrt_group_plan <max-groups> <max-members> <set-dir> <num...>
#   The partition, as `<group-index>\t<num>` lines on stdout, in the candidate
#   order it was given. rc 1 when there is nothing to plan.
#
#   STEP 1 — COMPONENTS. Every pair that _mrt_pair_conflicts joins is unioned;
#   what comes out are sets that CANNOT meet each other. This is the safety
#   property and it does not depend on max-groups at all.
#
#   STEP 2 — COMPONENTS INTO GROUPS. The first max-groups components take a
#   group each, in first-appearance order; any further component joins the
#   SMALLEST group so far (lowest index on a tie, so the answer is
#   deterministic and a test can assert it). Merging components is always safe
#   — a group is a train, and two disjoint components in one train is just a
#   bigger train, which is what this lane did before BH-1270.
#
#   AND THEREFORE `max-groups` 1 REPRODUCES BH-1269 EXACTLY: one group, every
#   candidate in it, in the order the caller listed them, capped at
#   max-members. No partition is computed that can change that answer.
mrt_group_plan() {
  local maxg="${1:-1}" maxm="${2:-0}" d="${3:-}"
  shift 3 || return 1
  local -a cand=("$@")
  local n=${#cand[@]}
  [ "$n" -gt 0 ] || return 1
  case "$maxg" in ''|*[!0-9]*|0) maxg=1 ;; esac
  case "$maxm" in ''|*[!0-9]*|0) maxm="$n" ;; esac
  local -a comp=() leader=() lgroup=() size=() used=() gof=()
  local i j k from to c idx ng=0 g best bs
  for (( i = 0; i < n; i++ )); do comp[i]=$i; done
  if [ "$maxg" -gt 1 ]; then
    for (( i = 0; i < n; i++ )); do
      for (( j = i + 1; j < n; j++ )); do
        [ "${comp[i]}" = "${comp[j]}" ] && continue
        _mrt_pair_conflicts "$d" "${cand[i]}" "${cand[j]}" || continue
        from=${comp[j]}; to=${comp[i]}
        for (( k = 0; k < n; k++ )); do
          [ "${comp[k]}" = "$from" ] && comp[k]=$to
        done
      done
    done
  fi
  for (( i = 0; i < n; i++ )); do
    c=${comp[i]}; idx=-1
    for (( k = 0; k < ng; k++ )); do
      if [ "${leader[k]}" = "$c" ]; then idx=$k; break; fi
    done
    if [ "$idx" -lt 0 ]; then
      leader[ng]=$c
      if [ "$ng" -lt "$maxg" ]; then
        lgroup[ng]=$ng
      else
        best=0; bs=${size[0]:-0}
        for (( k = 1; k < maxg; k++ )); do
          if [ "${size[k]:-0}" -lt "$bs" ]; then best=$k; bs=${size[k]:-0}; fi
        done
        lgroup[ng]=$best
      fi
      idx=$ng; ng=$((ng + 1))
    fi
    g=${lgroup[idx]}
    size[g]=$(( ${size[g]:-0} + 1 ))
    gof[i]=$g
  done
  for (( i = 0; i < n; i++ )); do
    g=${gof[i]}
    used[g]=$(( ${used[g]:-0} + 1 ))
    [ "${used[g]}" -gt "$maxm" ] && continue
    printf '%s\t%s\n' "$g" "${cand[i]}"
  done
  return 0
}
