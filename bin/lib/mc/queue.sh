#!/bin/bash
# shellcheck shell=bash
# module: queue after: classify
# bin/lib/mc/queue.sh — BH-477: batch trains, the two merge-queue providers, mc_merge/mc_enqueue. Sourced by bin/lib/merge-conductor-lib.sh, never run.
# THE DECISION READS GO THROUGH REST (BH-784), and the marker below is what
# tests/gh-no-graphql-decision-guard-test.sh scans this file for. It moved here
# with the code when BH-477.3 emptied bin/lib/merge-conductor-lib.sh: the lib
# carried the marker while it carried these calls, and a module holding them
# unmarked would be a call site the guard silently stopped policing.
# gh-rest: no-graphql


# --- Batch trains (BH-498) ---------------------------------------------------
# A PR that bin/batch-resolve.sh has put into a live merge-time train is HELD:
# the conductor must not merge it on its own while the train that carries it is
# in flight. Merging one member alone would land the same work twice and
# re-dirty every sibling in the train — which is the exact tail the train
# exists to end.
#
# THE HOLD IS KEYED ON (PR, HEAD), like every other marker in this file, so a
# push to the member's branch ends it by construction: the head the train was
# built from no longer exists on the PR, the train's copy of that work is now
# somebody else's problem, and the conductor owns the PR again on the next tick.
# batch-resolve releases the marker when the train lands, is closed, or the
# member is handed back.
mc_batch_file() { printf '%s/%s_%s' "$MC_BATCH_DIR" "$(mc_safe_name "$1")" "$(mc_safe_name "$2")"; }

# mc_batch_hold <owner/repo> <num> <head> <train-url>
mc_batch_hold() {
  mkdir -p "$MC_BATCH_DIR" 2>/dev/null
  printf '%s\t%s\t%s\n' "$(mc_now)" "${3:--}" "${4:--}" > "$(mc_batch_file "$1" "$2")"
  return 0
}
# mc_batch_release <owner/repo> <num>
mc_batch_release() { rm -f "$(mc_batch_file "$1" "$2")" 2>/dev/null; return 0; }
# mc_batch_held <owner/repo> <num> <head> -> rc 0 = leave this PR alone; prints
#   the train url for the log line.
mc_batch_held() {
  local f; f=$(mc_batch_file "$1" "$2")
  [ -s "$f" ] || return 1
  [ "$(cut -f2 "$f")" = "$3" ] || return 1
  printf '%s' "$(cut -f3 "$f")"
  return 0
}
# mc_batch_train_open <project> -> rc 0 when bin/batch-resolve.sh has a train
#   of this project still in flight (`open`, or `creating` after a crash between
#   the push and the record).
MC_BATCH_STATE_DIR="${MC_BATCH_STATE_DIR:-$MC_H/state/batch-resolve}"
# mc_batch_train_open <project> -> rc 0 when bin/batch-resolve.sh has a train
#   of this project still in flight (`open`, or `creating` after a crash between
#   the push and the record).
mc_batch_train_open() {
  local f
  for f in "$MC_BATCH_STATE_DIR/$1"/train-*.json; do
    [ -f "$f" ] || continue
    case "$(jq -r '.status // "open"' "$f" 2>/dev/null)" in open|creating) return 0 ;; esac
  done
  return 1
}

# mc_batch_should_spawn <project> <batchable-count> -> rc 0 when the tick should
#   spawn bin/batch-resolve.sh for this project.
#
#   THE OPEN-TRAIN CLAUSE IS WHY THIS IS A FUNCTION AND NOT AN INLINE `-ge 2`.
#   The count is of approved PRs the tick CLASSIFIED, and a member of a live
#   train returns before it is classified — so once a train carries every
#   approved PR of a repo the count is zero, the lane is never spawned, and
#   nothing ever reads the train's landing: the train merges, the members stay
#   open and held, and the holds only expire after mc_batch_gc's seven days.
#   The conductor is the lane's ONLY invoker (there is no cron line for it), so
#   "is there a train to settle" has to be one of the reasons to run it.
mc_batch_should_spawn() {
  local p="$1" n="${2:-0}" min=""
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  # THE SAME KNOB, AND THE SAME ROW, THE LANE ITSELF READS (BH-1269). A hard
  # `-ge 2` here is what would have made trains of one unreachable: the lane
  # honours BATCH_TRAIN_MIN perfectly and the conductor would simply never spawn
  # it for a lone approved PR, so the feature would have shipped dead.
  #
  # AND IT RESOLVES THROUGH lane_knob, not off the environment alone. The
  # conductor's own lane_env_apply loads `lane.merge-conductor.*` rows and
  # nothing else, so an operator who set `lane.batch-resolve.batch_train_min`
  # would have moved the lane's threshold and not this decision — two halves of
  # one knob disagreeing, which is the shape this control plane exists to end.
  # No lane-gate on the box (or no row) falls back to the environment and then
  # to 1, which is today's behaviour exactly.
  if command -v lane_knob >/dev/null 2>&1; then
    min=$(lane_knob batch-resolve BATCH_TRAIN_MIN "$p" 2>/dev/null)
  fi
  case "$min" in ''|*[!0-9]*|0) min="${BATCH_TRAIN_MIN:-}" ;; esac
  case "$min" in ''|*[!0-9]*|0) min=1 ;; esac
  [ "$n" -ge "$min" ] && return 0
  mc_batch_train_open "$p"
}

# mc_batch_gc — holds for trains that never settled. A week is far past any
#   queue's own patience, and a stale hold is a PR nothing merges.
mc_batch_gc() {
  [ -d "$MC_BATCH_DIR" ] || return 0
  find "$MC_BATCH_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
  return 0
}

# --- MERGE QUEUES: two providers, one switch ---------------------------------
# A "merge queue" here means: something other than this conductor takes the PR,
# builds it on top of CURRENT main (alone or in a batch) and merges it only if
# that tree is green. Two implementations exist for us, and they differ in the
# one place that matters — WHAT A MERGE CALL MEANS:
#
#   github   GitHub's native queue (a ruleset rule of type `merge_queue`).
#            `gh pr merge` ENQUEUES and exits 0: the PR stays OPEN,
#            mergeCommit.oid is null, isInMergeQueue becomes true.
#   mergify  The Mergify GitHub App, configured by `.mergify.yml` in the repo.
#            Entry is a LABEL (or an `@mergifyio queue` comment); the witness is
#            a Mergify CHECK RUN on the head. `gh pr merge` here still MERGES
#            OUTRIGHT — it BYPASSES the queue. That is why the fleet needs
#            mc_queue_conductor_only below and not just mc_queue_enabled.
#
# WHY MERGIFY AT ALL (the operator, 2026-09-12). example-org is GitHub **Team**, and the
# rulesets API rejects a `merge_queue` rule on a private repo with
# `422 Invalid rule 'merge_queue'` — GitHub limits private-repo merge queues to
# Enterprise Cloud. Every native-queue path shipped in #272 is therefore inert
# across the whole fleet. Mergify is a GitHub App (free at <= 5 active
# contributors) that gives the same batch-on-top-of-main guarantee on the plan we
# actually have. example-org/project-5 is the first repo. See docs/MERGIFY.md.
#
# THE REPO CAPABILITY IS STILL THE SWITCH, for both providers. There is no flag,
# because what changes is what GitHub or Mergify will actually DO. A capability
# probe is self-correcting (add the rule or the config, the fleet adapts on the
# next tick; remove it, every path reverts) and needs no fleet-wide coordination.
#
# FAIL-CLOSED: any API failure answers "no queue", i.e. today's synchronous
# behaviour. The opposite default would have the conductor believe in a merge it
# never made.
# BH-1939: the eleven MC_*/BATCH_TRAIN_MIN knobs this module reads have no literal
# here. They resolve through lib_env_apply mc-queue (catalog/lanes.d/
# _lib.mc-queue.json): row > cached row > env > registry default > fail closed,
# in a SUBSHELL for bin/lib/gh-budget.sh's reasons (a caller's stubs survive, a
# fail-closed exit 75 never stops the lane). The five settable:false ones take
# no lib row: their lane row (lane.merge-conductor.*, lane.batch-resolve.*)
# arrives as env, because lane_env_apply runs before this file is sourced. An
# empty answer leaves each read on the branch that does less: no cache, no
# wait, one Mergify pass.
_MCQ_KV=$(
  exec 3>&1
  _MCQ_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_MCQ_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_MCQ_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_MCQ_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _MCQ_K in MC_QUEUE_TTL MC_MERGE_SETTLE MC_ENQUEUE_SETTLE MC_MERGIFY_SETTLE MC_MERGIFY_WAIT_S MC_EJECT_REBASE MC_MERGIFY_STUCK_SECS MC_MERGIFY_REFRESH_WINDOW_SECS MC_MERGIFY_STUCK_ALERT_SECS MC_MERGIFY_REASK_S BATCH_TRAIN_MIN; do printf "%s\t%s\n" "$_MCQ_K" "${!_MCQ_K:-}" >&3; done' EXIT
  lib_env_apply mc-queue >/dev/null 2>&1)
while IFS=$'\t' read -r _MCQ_K _MCQ_V; do
  if [ -n "$_MCQ_V" ]; then printf -v "$_MCQ_K" '%s' "$_MCQ_V"; fi
done <<<"$_MCQ_KV"
unset _MCQ_KV _MCQ_K _MCQ_V
# The label that puts a PR into the Mergify queue. It is a CONTRACT with the
# repo's .mergify.yml (`pull_request_rules: conditions: - label = merge-queue`),
# which is why it is one name in one place — see docs/MERGIFY.md.
MC_MERGIFY_LABEL="${MC_MERGIFY_LABEL:-merge-queue}"

# BH-1586: the paged list reader (comments, PR files) and the per-repo policy
# cache (rulesets, .mergify.yml, protection). Off $MC_H like the shim's own
# sibling guards; a box without them reads through plain gh_rest, never raw gh.
command -v gh_rest_issue_comments >/dev/null 2>&1 || { [ -r "$MC_H/bin/lib/gh-rest-list.sh" ] && . "$MC_H/bin/lib/gh-rest-list.sh"; }
command -v gh_policy_read >/dev/null 2>&1 || { [ -r "$MC_H/bin/lib/gh-policy-cache.sh" ] && . "$MC_H/bin/lib/gh-policy-cache.sh"; }

# mc_rest_var <outvar> <helper> [args...] — run a gh_rest-family helper into a
#   FILE and assign its stdout to <outvar> (empty on any non-0), returning the
#   helper's own rc. The same shape as gh-rest-var.sh's _ghrv_run, written here
#   because a fixture tree may carry gh-rest.sh without gh-rest-var.sh, and a
#   missing helper is a 75 (unverifiable), never an empty answer read as a
#   state. BH-1586.
mc_rest_var() {
  local _mrv_out="$1" _mrv_fn="$2" _mrv_t _mrv_rc=0 _mrv_v=""
  shift 2
  command -v "$_mrv_fn" >/dev/null 2>&1 || { printf -v "$_mrv_out" '%s' ""; return 75; }
  _mrv_t=$(mktemp "${TMPDIR:-/tmp}/mc-rest.XXXXXX") || { printf -v "$_mrv_out" '%s' ""; return 75; }
  "$_mrv_fn" "$@" > "$_mrv_t" || _mrv_rc=$?
  [ "$_mrv_rc" = 0 ] && _mrv_v=$(cat "$_mrv_t" 2>/dev/null)
  rm -f "$_mrv_t"
  printf -v "$_mrv_out" '%s' "$_mrv_v"
  return "$_mrv_rc"
}

# mc_policy_get <outvar> <owner/repo> <name> <api path> — one POLICY read
#   (rulesets, .mergify.yml): through bin/lib/gh-policy-cache.sh's per-repo TTL
#   cache when it is loaded, else straight through gh_rest. BH-1586.
mc_policy_get() {
  local _mpg_out="$1"; shift
  if command -v gh_policy_read >/dev/null 2>&1; then mc_rest_var "$_mpg_out" gh_policy_read "$@"
  else mc_rest_var "$_mpg_out" gh_rest GET "$3"; fi
}

# mc_queue_github_enabled <owner/repo> — rc 0 when an ACTIVE ruleset targeting
# the repo's default branch carries a rule of type `merge_queue`. Uncached; the
# caching and the fail-closed default live in mc_queue_provider.
#
# BH-1586: both reads go through mc_policy_get — gh_rest (ledgered, ETag) behind
# the per-repo TTL cache of bin/lib/gh-policy-cache.sh, so two ticks inside
# GH_POLICY_TTL_SECS ask GitHub once. Any non-0 answer (404 no rulesets, 75
# unverifiable) is "no queue", as before.
mc_queue_github_enabled() {
  local slug="$1" ids id rs
  mc_policy_get ids "$slug" rulesets "repos/$slug/rulesets" || return 1
  ids=$(jq -r '.[]? | select(.enforcement=="active") | .id' <<<"$ids" 2>/dev/null) || return 1
  for id in $ids; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    mc_policy_get rs "$slug" "ruleset-$id" "repos/$slug/rulesets/$id" || continue
    # "targets the default branch" is read off the ruleset's own conditions
    # rather than by looking the branch name up: ~DEFAULT_BRANCH and ~ALL are
    # GitHub's own tokens for it, and refs/heads/main is the fleet's spelling.
    printf '%s' "$rs" | jq -e '
        ((.rules // []) | map(.type) | index("merge_queue")) and
        (((.conditions.ref_name.include // []) | map(. == "~DEFAULT_BRANCH" or . == "~ALL" or . == "refs/heads/main")) | index(true))
      ' >/dev/null 2>&1 && return 0
  done
  return 1
}

# mc_queue_mergify_enabled <owner/repo> — rc 0 when the DEFAULT BRANCH carries a
# `.mergify.yml` that declares `queue_rules:`.
#
# THE CONFIG IS THE PROBE, NOT THE APP INSTALLATION, because the installation is
# not readable with a repo-scoped PAT and the config is. A repo with the app
# installed but no `queue_rules` has no queue; a repo with `queue_rules` but no
# app is a misconfiguration that the enqueue verification below catches LOUDLY
# (the label goes on, no check run ever appears, the enqueue reports failure)
# rather than silently. `queue_rules:` and not merely "a .mergify.yml exists" —
# Mergify is also used for plain pull_request_rules automation, which is not a
# queue and must not change how anything in the fleet merges.
#
# ONE PATH ONLY (`.mergify.yml` at the repo root). Mergify also reads
# `.github/mergify.yml` and `.mergify/config.yml`; probing all three would treble
# the API calls for every repo in the fleet that has no Mergify at all, so
# docs/MERGIFY.md makes the root file the fleet's convention.
#
# THREE ANSWERS, NOT TWO (BH-2275). rc 0 queue_rules, rc 1 no queue (the file is
# ABSENT — GitHub's 404 — or declares none), rc 2 the file could not be READ (a
# 5xx, a rate limit, a network error, an answer that is not the contents
# shape). Folding rc 2 into "no queue" sent every merger on a Mergify repo to a
# direct merge for as long as a transient error lasted.
mc_queue_mergify_enabled() {
  local slug="$1" b64 yml rc=0
  mc_policy_get b64 "$slug" mergify "repos/$slug/contents/.mergify.yml" || rc=$?
  case "$rc" in 0) ;; 44) return 1 ;; *) return 2 ;; esac
  b64=$(jq -r '.content // empty' <<<"$b64" 2>/dev/null) || return 2
  [ -n "$b64" ] || return 2
  # The contents API returns base64. Decode when it decodes; a fixture (or a
  # future raw-media-type read) that hands back the YAML itself still works.
  yml=$(printf '%s' "$b64" | tr -d '\n\r ' | base64 -d 2>/dev/null) || yml=""
  [ -n "$yml" ] || yml="$b64"
  grep -qE '^[[:space:]]*queue_rules:' <<<"$yml"
}

# mc_queue_provider <owner/repo> -> github | mergify | none | unknown
#
# AN UNREADABLE PROBE ANSWERS THE LAST-KNOWN-GOOD PROVIDER (BH-2275, the lead's
# option B). Every REAL read — a 200, or GitHub's genuine 404 for an absent
# .mergify.yml — is recorded in the jobs-worker settings table as
# `mc.queue_provider.<owner>.<repo>` (mc_provider_record), so every box shares it
# and it survives a rebuild. When the .mergify.yml read fails (a 5xx, a rate
# limit, a network error), the answer is that record — a repo last read as
# `mergify` stays `mergify` and keeps holding and enqueueing — then this box's
# own cache file, and ONE alert a day says the probe failed
# (mc_queue_unknown_alert). THE REMAINING WINDOW: a repo with no record at all
# (never read successfully) answers `none`, as before this ticket, with a log
# line rather than a page.
#
# `unknown` is still understood by every caller that merges (the conductor holds
# the tick, mc_enqueue and the console Merge button refuse) as a defensive
# answer; this function no longer produces it. The GitHub-rulesets probe keeps
# its old reading — a 403 there is routine for a token without admin.
#
# Cached in a FILE, not just in memory: the conductor, the hub sweep, the box
# merge queue and the tier-2 sweep are separate processes asking the same
# question about the same handful of repos every few minutes. TTL is one tick.
# The cache file is NEW (`.provider`, not the old `.probe`) so a stale 0/1 left
# by the pre-Mergify build is never read back as a provider word.
mc_queue_provider() {
  local slug="$1" cache age ans=none
  [ -n "$slug" ] || { printf 'none'; return 0; }
  mkdir -p "$MC_H/tmp" 2>/dev/null
  cache="$MC_H/tmp/merge-queue-${slug//\//_}.provider"
  # BH-1586 (#1605 review): NO provider file = "ask GitHub now", which is the
  # documented fast path (docs/MERGIFY.md section 4: delete this file on the
  # hub). The policy cache under it (bin/lib/gh-policy-cache.sh) would otherwise
  # answer the probe from disk for GH_POLICY_TTL_SECS, so that repo's policy
  # entries go with it. An EXPIRED file is not a missing one: that is the
  # ordinary tick, and the policy TTL stands.
  if [ ! -e "$cache" ] && command -v gh_policy_cache_drop >/dev/null 2>&1; then
    gh_policy_cache_drop "$slug"
  fi
  if [ -f "$cache" ]; then
    age=$(( $(mc_now) - $(mc_mtime "$cache") ))
    # No TTL resolved = no cache: the probe below asks GitHub.
    case "${MC_QUEUE_TTL:-}" in ''|*[!0-9]*) age=-1 ;; esac
    if [ "$age" -ge 0 ] && [ "$age" -lt "$MC_QUEUE_TTL" ]; then
      ans=$(cat "$cache" 2>/dev/null)
      case "$ans" in github|mergify|none) printf '%s' "$ans"; return 0 ;; esac
    fi
  fi
  if mc_queue_github_enabled "$slug"; then ans=github
  else
    local mrc=0 known kfrom
    mc_queue_mergify_enabled "$slug" || mrc=$?
    case "$mrc" in
      0) ans=mergify ;;
      1) ans=none ;;
      *)
        # Unreadable: last-known-good, never written back as if it were a read.
        local rrc=0
        known=$(mc_provider_recorded "$slug") || rrc=$?
        kfrom="the jobs-worker record"
        if [ -z "$known" ]; then
          known=$(cat "$cache" 2>/dev/null); kfrom="this box's cache"
          case "$known" in github|mergify|none) ;; *) known="" ;; esac
        fi
        if [ -n "$known" ]; then
          mc_queue_unknown_alert "$slug" "the .mergify.yml probe failed; using the last-known provider '$known' from $kfrom" >/dev/null 2>&1 || true
          printf '%s' "$known"
        elif [ "$rrc" = 1 ]; then
          # The probe AND the worker failed, and this box has no cache: nobody
          # can say what this repo is. `unknown`, which every merging caller
          # holds on (the conductor holds the tick and pages once a day).
          printf 'unknown'
        else
          # A GENUINE no-row: this repo has never been read successfully (or
          # this box has no worker to record into). Exactly the pre-BH-2275
          # answer, so it is a LOG line, not a page.
          command -v mc_log >/dev/null 2>&1 \
            && mc_log "$slug merge-queue provider probe failed and this repo has no last-known provider record (never read successfully), so it is read as 'none' (no queue) — the one window BH-2275 leaves open"
          printf 'none'
        fi
        return 0 ;;
    esac
  fi
  printf '%s' "$ans" > "$cache" 2>/dev/null
  mc_provider_record "$slug" "$ans" "$cache.recorded"
  printf '%s' "$ans"
}

# mc_provider_key <owner/repo> — the settings key of a repo's last-known-good
#   provider: mc.queue_provider.<owner>.<repo>, lower-cased. rc 1 when the slug
#   cannot make a legal key (the worker's ^[a-z0-9_.-]{1,64}$).
mc_provider_key() {
  local k
  k="mc.queue_provider.$(printf '%s' "${1:-}" | tr 'A-Z/' 'a-z.')"
  case "$k" in *[!a-z0-9_.-]*) return 1 ;; esac
  [ "${#k}" -le 64 ] || return 1
  printf '%s' "$k"
}

# mc_provider_recorded <owner/repo> — prints the recorded provider, rc 0; rc 1
#   when there is no record, no jobs client, or the worker did not answer.
#
#   THREE ANSWERS, KEPT APART (review r2 of #2277): rc 0 the record; rc 2 there
#   is no record — a genuine no-row, or no jobs client CONFIGURED on this box
#   (no setting_get, no JOBS_URL or no HARNESS_SECRET: a box that never had a
#   worker to record into); rc 1 the worker IS configured and did not answer
#   (transport, 5xx, 401/403). The caller must not read rc 1 as "never read":
#   a worker outage on a box with no cache file would otherwise turn a
#   recorded `mergify` into `none` and a direct merge around the queue.
mc_provider_recorded() {
  local k v rc=0
  command -v setting_get >/dev/null 2>&1 || return 2
  [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 2
  k=$(mc_provider_key "$1") || return 2
  v=$(setting_get "$k" 2>/dev/null) || rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  case "$v" in github|mergify|none) printf '%s' "$v"; return 0 ;; esac
  return 2
}

# mc_provider_record <owner/repo> <provider> <marker-file> — record a provider
#   that was actually READ. Idempotent: the marker file holds the value this box
#   last wrote, so an unchanged answer costs no request, and the worker's upsert
#   makes a repeated write a no-op. A failed write leaves the marker unwritten,
#   so the next real read tries again. Never called on an unreadable probe.
mc_provider_record() {
  local slug="$1" ans="$2" mark="$3" k
  command -v setting_set >/dev/null 2>&1 || return 0
  [ "$(cat "$mark" 2>/dev/null)" = "$ans" ] && return 0
  k=$(mc_provider_key "$slug") || return 0
  setting_set "$k" "$ans" "BH-2275: last merge-queue provider read for $slug (a 200 or a genuine 404)" >/dev/null 2>&1 \
    && printf '%s' "$ans" > "$mark" 2>/dev/null
  return 0
}

# mc_queue_enabled <owner/repo> — rc 0 when the repo has a merge queue of EITHER
# provider. This is the fleet-wide switch every stand-down and skip written for
# the native queue already reads (bin/merge-queue.sh,
# the pre-arm skips), so a Mergify repo inherits all of them unchanged.
mc_queue_enabled() { [ "$(mc_queue_provider "$1")" != none ]; }

# mc_queue_conductor_only <owner/repo> — rc 0 when a plain `gh pr merge` on this
# repo would BYPASS the queue rather than feed it, i.e. provider mergify.
#
# This is the distinction the native-queue work did not need. Under GitHub's own
# queue `gh pr merge` IS the enqueue, so every merger in the fleet could keep
# calling it and simply read the answer apart. Mergify sits BESIDE GitHub's merge
# button, not in front of it: the same call lands the PR straight onto main with
# none of the batch verification the queue exists for. So on a mergify repo every
# other merger has to STAND DOWN and leave the PR to the conductor, which is the
# only thing that knows how to label it.
# An `unknown` provider (BH-2275) is conductor-only too: the lanes that would
# merge on their own stand down rather than guess that a repo has no queue.
mc_queue_conductor_only() { case "$(mc_queue_provider "$1")" in mergify|unknown) return 0 ;; esac; return 1; }

# mc_inqueue <pr-url> — rc 0 when GitHub says the PR is sitting in the NATIVE
# queue. Read per PR; the list read in bin/merge-conductor.sh asks for the field
# in bulk and only falls back to this when gh's --json allowlist refuses it.
mc_inqueue() { [ "$(mc_queue_state "$1")" = queued ]; }

# mc_mergify_check <owner/repo> <pr-url> <head-sha> — prints one
# "<status>|<conclusion>|<title>" line per Mergify queue check run on that head,
# and nothing when there is none. Callers deciding "did the queue take it" read
# mc_mergify_check_live instead, which drops Mergify's idle line.
#
# WHAT THE NAMES ARE, AND WHAT IS UNVERIFIED. Mergify's docs (merge-queue/
# lifecycle) say: "Every pull request in a repository with the merge queue
# enabled shows a single 'Mergify Merge Queue' check run", whose TITLE carries
# the state ("In merge queue", "Running merge queue checks"). Older Mergify
# reported through per-rule checks named `Rule: <name> (queue)` and `Queue: …`,
# so all three shapes are matched. THE CONCLUSION A DEQUEUED PR'S CHECK CARRIES
# IS NOT DOCUMENTED ANYWHERE WE COULD READ, so this treats the GitHub-standard
# failure conclusions as ejection and everything else as still running — and the
# LABELS in mc_queue_state are the second, independent witness.
#
# The checks API is 403 for the box PATs (the reason mc_ci_state reads
# actions/runs instead), so a refusal falls back to the PR's statusCheckRollup,
# which the same token can read. Rollup values are upper-case, hence the fold.
# Every Mergify check run on the head, one per line as `status|conclusion|title`.
# The title is the third field because it is the only thing that tells Mergify's
# IDLE check apart from a real one — see mc_mergify_check_live. The rollup
# fallback has no title, so its lines end in an empty field.
mc_mergify_check() {
  local slug="$1" url="$2" sha="$3" t rc out=""
  if [ -z "$sha" ]; then
    sha=$(mc_pr_view "$url" .head.sha 2>/dev/null); rc=$?
    # A head we could not READ is not a head that is not there.
    [ "$rc" = 0 ] || return "$rc"
  fi
  [ -n "$sha" ] || { printf ''; return 0; }
  t=$(mktemp "${TMPDIR:-/tmp}/mc-checks.XXXXXX") || return 75
  gh_rest GET "repos/$slug/commits/$sha/check-runs" -F per_page=100 > "$t"; rc=$?
  [ "$rc" = 0 ] || { rm -f "$t"; return "$rc"; }
  # A 2xx whose body jq cannot read is not an empty check list either.
  out=$(jq -r '.check_runs[]? | select(.name | test("^Mergify|^Queue:|\\(queue\\)")) | "\(.status)|\(.conclusion // "")|\(.output.title // "")"' "$t" 2>/dev/null) \
    || { rm -f "$t"; return 75; }
  rm -f "$t"
  printf '%s' "$out"
}

# THE IDLE CHECK IS NOT A WITNESS (project-5 #547, 2026-09-13). With the Merge
# Queue product live, Mergify posts a neutral "Mergify Merge Queue" check titled
# "Merge queue is ready" on every PR it has evaluated — queued or not (#546
# carried it with no label ever, #547 carried it for 46 minutes while nothing
# was queued). A witness that accepted any Mergify* check reported QUEUED the
# moment our label went on, so the rc-3 fallback and its alert could never
# fire, and a PR the queue never took would sit QUEUED until its budget paged.
# This is mc_mergify_check minus that line: what remains is Mergify DOING
# something with the PR (queued, checking, merged, or a failure — the caller
# reads the conclusion).
mc_mergify_check_live() {
  local out rc
  out=$(mc_mergify_check "$@"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s' "$out" | grep -viE '^[^|]*\|[^|]*\|merge queue is ready' || true
}

# mc_mergify_witness <owner/repo> <pr-url> <head-sha> — rc 0 when MERGIFY ITSELF
# has acknowledged the PR: a queue check run on the head, or one of Mergify's own
# `queued`/`checking` labels. Deliberately NOT satisfied by our trigger label,
# which is only what we asked for — see mc_enqueue_mergify.
#   MC_WITNESS_FRESH=1 (BH-3776, set for a requeue): a head Mergify dequeued
#   still carries its failed queue check and "Dequeued …" line, and reading
#   those as an acknowledgement would stamp the row QUEUED and let the next
#   settle pass count the same failure as a second ejection. Dropped first.
mc_mergify_witness() {
  local slug="$1" url="$2" head="$3" chk lab rc
  chk=$(mc_mergify_check_live "$slug" "$url" "$head"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  [ "${MC_WITNESS_FRESH:-0}" = 1 ] \
    && chk=$(printf '%s\n' "$chk" | grep -viE '^[^|]*\|(failure|cancelled|timed_out|action_required|startup_failure|stale)\||^[^|]*\|[^|]*\|dequeued' | sed '/^$/d' || true)
  [ -n "$chk" ] && return 0
  lab=$(mc_pr_view "$url" .LABELS 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  grep -qE '(^|,)(queued|checking)(,|$)' <<<"$lab"
}

# mc_queue_state <pr-url> [head-sha] -> queued | merged | ejected | unknown
#
#   queued   the queue holds it; do nothing this tick
#   merged   it landed; the caller owes mc_settle_merged
#   ejected  it is open and the queue no longer holds it — under the native queue
#            because the merge_group build went red, under Mergify because the
#            batch failed (Mergify removes the culprit from the queue) or because
#            somebody took the label off. On a repo with NO queue every open PR
#            reads `ejected`; the only caller there is mc_pr_queued, which wants
#            "not queued" and gets it
#   unknown  the read failed, or the PR is CLOSED — say nothing rather than
#            invent an ejection out of an API outage. The conductor's QUEUED pass
#            leaves an `unknown` row exactly where it is.
#
# ORDER MATTERS. MERGED wins over every label and every check, because a label
# left behind on a merged PR is not a queue entry. A FAILED check beats a present
# label for the same reason in reverse: Mergify does NOT remove the label a human
# (or this conductor) added — its own signals are the check run and its own
# `dequeued` label — so a stale trigger label must never outvote a red batch.
mc_queue_state() {
  local url="$1" head="${2:-}" slug prov j st head2 labels chk chkrc=0
  slug=$(mc_slug_of_url "$url"); prov=$(mc_queue_provider "$slug")
  # ONE read for every provider now. head FIRST and labels LAST: `read` collapses
  # runs of whitespace, so a PR with no labels in the middle field would shift
  # the sha into $labels.
  j=$(mc_pr_view "$url" '"\(.STATE) \(.head.sha) \(.LABELS)"' 2>/dev/null) || j=""
  [ -n "$j" ] || { printf 'unknown'; return 0; }
  read -r st head2 labels <<<"$j"
  [ -n "$head" ] || head="$head2"
  case "$st" in
    MERGED) printf 'merged'; return 0 ;;
    OPEN) ;;
    *) printf 'unknown'; return 0 ;;   # CLOSED is the conductor's own branch
  esac
  # THE CHECK-RUNS READ ONLY HAPPENS UNDER MERGIFY (the operator, review of #941). It is
  # Mergify's own witness; on GitHub's queue and on a repo with no queue at all
  # there is no check to find, so asking spends a call to learn nothing and then
  # invites the "no witness" arm below to read that nothing as an ejection.
  if [ "$prov" = mergify ]; then
    chk=$(mc_mergify_check_live "$slug" "$url" "$head"); chkrc=$?
  else
    chk=""; chkrc=0
  fi
  grep -qE '\|(failure|cancelled|timed_out|action_required|startup_failure|stale)(\||$)' <<<"$chk" \
    && { printf 'ejected'; return 0; }
  # Mergify's own `dequeued_label` (default `dequeued`) is its explicit "this PR
  # left the queue without merging" marker, and beats our trigger label.
  grep -qE '(^|,)dequeued(,|$)' <<<"${labels:-}" && { printf 'ejected'; return 0; }
  # Our trigger label, or Mergify's own queued/checking labels.
  grep -qE "(^|,)($MC_MERGIFY_LABEL|queued|checking)(,|\$)" <<<"${labels:-}" && { printf 'queued'; return 0; }
  [ -n "$chk" ] && { printf 'queued'; return 0; }
  # No witness at all. On Mergify that IS the ejection (its label and its check
  # are both gone) — but ONLY when the check read actually answered. A 403 on
  # check-runs saw no witness because it saw nothing, and calling that an
  # ejection strikes and dequeues a PR the queue is still holding, which is the
  # incident class this whole change exists to stop. On GitHub's own queue — and
  # on a repo the fail-closed probe could not classify — we cannot see the queue
  # over REST at all, so say so.
  [ "$chkrc" = 0 ] || { printf 'unknown'; return 0; }
  case "$prov" in mergify) printf 'ejected' ;; *) printf 'unknown' ;; esac
}

# mc_queue_left_why <owner/repo> <pr-url> <head-sha>
#   -> merged | merging | ejected | nowitness | unknown, always rc 0 (BH-4562)
#
#   merged     a FRESH PR read says GitHub merged it
#   merging    still OPEN, but a Mergify queue check on the head is titled merged
#   ejected    OPEN with a stated reason: a failed queue check, a `dequeued`
#              title, or Mergify's `dequeued` label
#   nowitness  OPEN, the check read answered, and none of the above
#   unknown    either read failed, or the PR is CLOSED
#
# THE INCIDENT (#4142, 02:02:34Z). While Mergify lands a green batch it drops its
# queued/checking labels and moves its queue check BEFORE GitHub sets merged_at
# (02:02:35Z). mc_queue_state saw no witness and answered `ejected`, and the
# conductor counted a second ejection and parked a merged PR BLOCKED_HUMAN. The
# settle arm asks this before it counts anything on Mergify.
#
# THE PR READ SKIPS THE ETAG CACHE (GH_ETAG=0, scoped to that one call): a 304
# replays the cached OPEN body, which is exactly the stale answer that made the
# ejection. NOWITNESS IS NOT AN EJECTION ON FIRST SIGHT: it is the shape of the
# race itself, so the caller holds it a tick and lets the next read decide.
# ORDER: merged beats everything; a merged title beats a cancelled conclusion on
# a sibling check line; only then does a stated reason eject.
mc_queue_left_why() {
  local slug="$1" url="$2" head="$3" j st labels chk
  j=$(GH_ETAG=0 mc_pr_view "$url" '"\(.STATE) \(.LABELS)"' 2>/dev/null) || j=""
  [ -n "$j" ] || { printf 'unknown'; return 0; }
  read -r st labels <<<"$j"
  case "$st" in
    MERGED) printf 'merged'; return 0 ;;
    OPEN) ;;
    *) printf 'unknown'; return 0 ;;
  esac
  chk=$(mc_mergify_check "$slug" "$url" "$head") || { printf 'unknown'; return 0; }
  # A negated title ("cannot be merged", "not merged") is not a landing; it
  # would read `merging` every tick and the row would never be counted.
  grep -iE '^[^|]*\|[^|]*\|.*merged' <<<"$chk" | grep -qviE "(not|n't|be|un)[ -]?merged" \
    && { printf 'merging'; return 0; }
  grep -qE '\|(failure|cancelled|timed_out|action_required|startup_failure|stale)(\||$)' <<<"$chk" \
    && { printf 'ejected'; return 0; }
  grep -qiE '^[^|]*\|[^|]*\|.*dequeued' <<<"$chk" && { printf 'ejected'; return 0; }
  grep -qE '(^|,)dequeued(,|$)' <<<"${labels:-}" && { printf 'ejected'; return 0; }
  printf 'nowitness'
}

# mc_pr_queued <pr-url> [head-sha] — rc 0 when the PR is sitting in a merge queue
# of EITHER provider right now.
#
# Every reader in bin/ that asked `isInMergeQueue` directly goes through this, so
# a Mergify-queued PR is never mistaken for "not merged, not queued" — the
# reading that used to send an already-queued PR round the box merge queue every
# twenty minutes.
mc_pr_queued() { [ "$(mc_queue_state "$1" "${2:-}")" = queued ]; }

# mc_dequeue_label <pr-url> — take OUR trigger label back off, so the next
# enqueue is a fresh signal rather than a label that has sat there through a
# failed batch. A no-op for any provider but mergify, and it never touches
# Mergify's own labels: those are Mergify's to manage.
mc_dequeue_label() {
  local url="$1"
  [ "$(mc_queue_provider "$(mc_slug_of_url "$url")")" = mergify ] || return 0
  gh api -X DELETE "repos/$(mc_slug_of_url "$url")/issues/$(mc_num_of_url "$url")/labels/$MC_MERGIFY_LABEL" >/dev/null 2>&1 || true
}

# mc_dequeue_reason <owner/repo> <pr-url> <head-sha> -> `github-review-approved`
#   or the empty string (BH-872).
#
# WHY A DEQUEUE NEEDS A REASON. An ejection under Mergify is normally a red
# batch, and that is what the conductor's ejection arm says. But a standing
# changes-requested review makes Mergify's `github-review-approved` condition
# FALSE, and Mergify dequeues the PR for that too — a review fact reported as a
# CI fact, on a PR whose requeue arm then waits for a CLEAN merge state the
# review denies. Mergify names the unsatisfied condition in two places: its own
# dequeue comment on the thread, and the queue check run's `output.summary` on
# the head. Either one naming the condition is the answer.
#
# ONLY THE NEWEST MERGIFY COMMENT COUNTS. A PR that was dequeued for a review in
# the morning and for a red batch at noon is a red batch now; matching any
# comment in the thread would comment on the wrong cause for ever. The filter
# emits one line per mergify[bot] comment in API order (oldest first) with the
# newlines folded to \x01, so `tail -1` is the newest one and `tr` puts its LINES
# back — the line is the unit of meaning here (see mc_mergify_names_review).
#
# A SUBSTRING MATCH IS A FALSE CAUSE (#891 review round 1). The first cut of this
# grepped `github-review-approved` over the whole folded body. Mergify keeps ONE
# status comment per PR, edits it in place, and on a repo whose ruleset requires
# a review it prints that condition in the "All conditions" / "Required
# conditions to merge" checklist of EVERY status comment, satisfied or not:
# live on project-5, #2029 and #2120 (both `## Reason: the checks did not pass
# within the automatic checks timeout`) and merged #2367 all carry the token.
# Only conflict dequeues (#2604, #1775, #1403) lack it. So the substring made
# every checks-caused ejection — the normal one — post a client-visible comment
# and a fleet alert blaming a standing changes-requested review. The shape that
# actually distinguishes them is below.
#
# AN UNREADABLE REASON IS NOT A REASON (D11). Every failure — rc, an empty list,
# a body shape the filter does not match — answers "" and the caller says
# nothing; the ejection itself is already logged by the block that calls this.
#
# mc_mergify_names_review <token> — stdin: one Mergify body/summary, in LINES.
#   rc 0 when the body says the token is why the PR is out of the queue.
#
# TWO SHAPES, IN THIS ORDER, both read off real Mergify bodies:
#   1. A `## Reason` section exists (every dequeue comment has one). It is the
#      authoritative cause and it is the ONLY thing consulted: the token inside
#      it, on a line not marked `[X]`, is the answer. #2458's review dequeue
#      prints `> - \`github-review-approved\`` under "Blocked by:", #2372's
#      prints `>     - [ ] [\`github-review-approved\`](…)`; #2029's checks
#      timeout names no review anywhere in its Reason.
#   2. No `## Reason` (the queue check run's `output.summary`): an UNCHECKED
#      condition line — `- [ ] … github-review-approved`, with any blockquote or
#      indent in front — is the answer. A SATISFIED condition prints as a
#      checkbox-less parent (`- [\`github-review-approved\`](…)`) with `- [X]`
#      children, which is what the merged #2458 head's "Mergify Merge Queue"
#      summary carries and what must NOT match.
mc_mergify_names_review() {
  awk -v tok="${1:-github-review-approved}" '
    /^##[[:space:]]/ {
      if ($0 ~ /^##[[:space:]]+Reason[[:space:]]*$/) { inr = 1; rseen = 1 } else { inr = 0 }
      next
    }
    index($0, tok) > 0 {
      if (inr) { if ($0 !~ /\[[Xx]\]/) rhit = 1 }
      else if ($0 ~ /^[[:space:]>]*-[[:space:]]+\[[[:space:]]\]/) unchecked = 1
    }
    END { if (rseen) exit(rhit ? 0 : 1); exit(unchecked ? 0 : 1) }'
}

mc_dequeue_reason() {
  local slug="${1:-}" url="${2:-}" head="${3:-}" tok=github-review-approved num raw body sum
  [ -n "$slug" ] && [ -n "$url" ] || { printf ''; return 0; }
  num=$(mc_num_of_url "$url")
  # BH-1586: both reads through gh_rest (ledgered, ETag). The comments are the
  # paged list reader (every page, as --paginate was); a failed read is "no
  # reason", as it always was.
  if [ -n "$num" ]; then
    mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || raw=""
    [ -n "$raw" ] || raw='[]'
    raw=$(jq -r '.[]? | select((.user.login // "") == "mergify[bot]") | ((.body // "") | gsub("[\r\n]+"; "\u0001"))' <<<"$raw" 2>/dev/null) || raw=""
    body=$(printf '%s\n' "$raw" | tail -n 1 | tr '\001' '\n')
    printf '%s\n' "$body" | mc_mergify_names_review "$tok" && { printf '%s' "$tok"; return 0; }
  fi
  if [ -n "$head" ]; then
    mc_rest_var sum gh_rest GET "repos/$slug/commits/$head/check-runs" -F per_page=100 || sum=""
    [ -n "$sum" ] || sum='{}'
    sum=$(jq -r '.check_runs[]? | select(.name | test("^Mergify|^Queue:|\\(queue\\)")) | ((.output.summary // "") | gsub("[\r\n]+"; "\u0001"))' <<<"$sum" 2>/dev/null) || sum=""
    printf '%s\n' "$sum" | tr '\001' '\n' | mc_mergify_names_review "$tok" && { printf '%s' "$tok"; return 0; }
  fi
  printf ''
}

# mc_dequeue_conflict <owner/repo> <pr-url> <head-sha> -> "base-conflict" or ""
#   rc 0 always. Prints `base-conflict` when the NEWEST mergify[bot] comment's
#   `## Reason` section says "conflicts with the base branch" or "base branch
#   conflict" (case-insensitive); otherwise nothing (BH-1677). The read is
#   mc_dequeue_reason's comments read. Only `## Reason` counts: the conditions
#   checklist lists `#-conflict` on every status comment, and a Summary or a
#   human quoting Mergify is not why the PR left. An unreadable read, an empty
#   list or no match all print nothing (D11), so the ejection stays a strike.
#   No check-run fallback: a check-run summary has no `## Reason`.
mc_dequeue_conflict() {
  local slug="${1:-}" url="${2:-}" num raw
  [ -n "$slug" ] && [ -n "$url" ] || { printf ''; return 0; }
  num=$(mc_num_of_url "$url")
  [ -n "$num" ] || { printf ''; return 0; }
  mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || raw=""
  [ -n "$raw" ] || raw='[]'
  raw=$(jq -r '.[]? | select((.user.login // "") == "mergify[bot]") | ((.body // "") | gsub("[\r\n]+"; "\u0001"))' <<<"$raw" 2>/dev/null) || raw=""
  printf '%s\n' "$raw" | tail -n 1 | tr '\001' '\n' | awk '
    /^##[[:space:]]/ { inr = ($0 ~ /^##[[:space:]]+Reason[[:space:]]*$/); next }
    inr && tolower($0) ~ /conflicts with the base branch|base branch conflict/ { hit = 1 }
    END { exit(hit ? 0 : 1) }' && { printf 'base-conflict'; return 0; }
  printf ''
}

# mc_eject_conflict_note <owner/repo> <key> <pr-url> <head-sha> -> rc 0
#   The settle pass's ejection, asked WHY: when Mergify's `## Reason` names a
#   base-branch conflict, mark the (PR, head) `ejectconflict` once and say so.
#   The mark is what mc_eject_strikes leaves out of the strike count and what
#   eject_rebase_arm (rebase.sh) spends its one out-of-budget rebase on. Called
#   before the strike count reads the file. MC_EJECT_REBASE=0: no read, no mark.
mc_eject_conflict_note() {
  local slug="$1" key="$2" url="$3" head="$4"
  [ "${MC_EJECT_REBASE:-}" != 0 ] || return 0
  [ -n "$key" ] && [ -n "$head" ] || return 0
  mc_attempt_has "ejectconflict $key $head" 2>/dev/null && return 0
  [ "$(mc_dequeue_conflict "$slug" "$url" "$head")" = base-conflict ] || return 0
  mc_attempt_put "ejectconflict $key $head"
  mc_log "EJECTED_CONFLICT $key $head — Mergify's ## Reason names a base-branch conflict; not a strike, one rebase is offered for this head"
  return 0
}

# mc_ejected_hold <key> <head> — rc 0 when this ejected head must never be put
#   back in the queue (BH-5819): it is the CULPRIT of its ejection — a
#   `dqwculprit` mark (dequeue-watch, a human dequeue or a failed solo check,
#   mc_eject_culprit_mark) or a `reejected` mark. A bystander Mergify dequeued
#   with a culprit keeps the BH-636 / BH-4428 requeue: freezing it would stall
#   good PRs until somebody pushes. MC_EJECTED_REQUEUE=never holds every head
#   with an `ejected` mark; anything else (the default `culprit`) holds culprits.
mc_ejected_hold() {
  mc_attempt_has "dqwculprit $1 $2" 2>/dev/null && return 0
  mc_attempt_has "reejected $1 $2" 2>/dev/null && return 0
  [ "${MC_EJECTED_REQUEUE:-}" = never ] && mc_attempt_has "ejected $1 $2" 2>/dev/null && return 0
  return 1
}

# mc_eject_culprit_mark <slug> <num> <key> <head> -> rc 0 marked (or already
#   marked), rc 1 no culprit evidence (or it could not be read)
#   BH-5819 (#5462): a head is the CULPRIT of its ejection, not a flake, when
#     * a human posted `@Mergifyio dequeue` on the PR after this head was
#       committed (not the conductor's own CR dequeue: no `crdequeue` mark, and
#       no MC_CRDEQUEUE_TAG in the comment; a head whose date cannot be read
#       skips this check for the tick instead of counting every dequeue), or
#     * Mergify's dequeue named a draft that held this PR ALONE (bej_verdict
#       `solo`) and fewer than MC_BATCH_EJECT_SHARED_MIN PRs failed alone on that
#       base (else main was red: `sharedred`, not this PR).
#   Marked as `dqwculprit <key> <head>` + `reejected <key> <head>`, so the
#   re-entry arm and the stale-dequeue arm never put the head back, and the strike
#   count hands it to bin/blocked-resolver.sh (queue-ejected-twice). Only a new
#   head clears it. Logged once: EJECT_CULPRIT <key> <head> — <cause>.
#   An optional 5th arg 0 skips the solo check (the caller's `bejv` line is
#   from this tick).
mc_eject_culprit_mark() {
  local slug="$1" num="$2" key="$3" head="$4" solo_ok="${5:-1}" raw="" hd="" he=0 cause="" min n read=0 solo=0
  mc_attempt_has "dqwculprit $key $head" 2>/dev/null && return 0
  # Looked at once per head: a clean answer is remembered (`culpritchecked`),
  # so a held head costs no reads on later ticks. A failed read is not.
  mc_attempt_has "culpritchecked $key $head" 2>/dev/null && return 1
  # A human dequeue, read from the PR's comments (newest first is not needed:
  # any one after the head counts). Read once per head: a clean answer is
  # remembered (`culpritread`), so a head that waits tick after tick (a deferred
  # requeue) spends no second read (bh-3857 RC1). A later human dequeue needs a
  # requeue first, and its ejection is a second strike anyway.
  if mc_attempt_has "culpritread $key $head" 2>/dev/null; then
    read=1
  elif ! mc_attempt_has "crdequeue $key $head" 2>/dev/null && command -v gh_rest_issue_comments >/dev/null 2>&1; then
    # The head's date bounds which dequeues count, and it is read FIRST.
    # Unread (rate limit, 5xx, no committer date) is NOT the epoch: that would
    # count every dequeue the PR ever had. The check is skipped this tick,
    # nothing is remembered, and the comments are not read for nothing.
    if mc_rest_var hd gh_rest GET "repos/$slug/commits/$head"; then
      hd=$(jq -r '.commit.committer.date // empty' <<<"$hd" 2>/dev/null)
      [ -n "$hd" ] && he=$(date -u -d "$hd" +%s 2>/dev/null) || he=0
    fi
    if [ "${he:-0}" -gt 0 ] 2>/dev/null && mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000; then
      read=1
      cause=$(jq -r --argjson he "$he" --arg tag "${MC_CRDEQUEUE_TAG:-<!-- mc:crdequeue -->}" '
        [ .[]? | select((.user.type // "") != "Bot" and ((.user.login // "") | test("\\[bot\\]$") | not))
               | select((.body // "") | test("^\\s*@mergifyio\\s+dequeue\\b"; "i"))
               | select((.body // "") | contains($tag) | not)
               | select(((.created_at // "") | fromdateiso8601? // 0) >= $he) ]
        | last // empty | "a human dequeue by \(.user.login) at \(.created_at)"' <<<"$raw" 2>/dev/null)
      [ -n "$cause" ] || mc_attempt_put "culpritread $key $head"
    fi
  fi
  # A solo check that failed: Mergify tested this PR alone and named it.
  # A SOLO verdict counts only once bej_reentry_gate cached it on an EARLIER
  # tick (its `bejv` line): another PR ejected alone on the same base in the
  # same tick can still make it `sharedred` (main red), and the gate's own
  # culprit comment waits that tick for the same reason. This never does the
  # first read itself, so the gate's one-tick wait is kept.
  # solo_ok=0: the caller saw no `bejv` line BEFORE this tick's re-entry gate,
  # so a line there now is this tick's and does not count yet.
  if [ -z "$cause" ] && [ "$solo_ok" = 1 ] && command -v bej_verdict >/dev/null 2>&1 \
     && [ "$(mc_attempt_count bejv "$key" "$head")" -gt 0 ] 2>/dev/null; then
    bej_verdict "$slug" "$num" "$key" "$head"
    solo=1
    if [ "${BEJ_WORD:-}" = solo ]; then
      command -v bej_solo_note >/dev/null 2>&1 && bej_solo_note "$slug" "$BEJ_BASE" "$BEJ_CHECKS" "$key"
      min=$(_bej_knob MC_BATCH_EJECT_SHARED_MIN 2 2>/dev/null); case "$min" in ''|*[!0-9]*) min=2 ;; esac
      [ "$min" -ge 2 ] || min=2
      n=$(bej_shared_count "$slug" "$BEJ_BASE" "$BEJ_CHECKS" 2>/dev/null)
      if [ "${n:-0}" -lt "$min" ]; then
        cause="a failed solo check (draft #${BEJ_DRAFT:-?} held this PR alone on ${BEJ_BASE:-?})"
        # The PR is told what failed, as bej_reentry_gate tells a culprit.
        command -v bej_culprit_note >/dev/null 2>&1 && bej_culprit_note "$slug" "$num" "$key" "$head" >/dev/null 2>&1
      fi
    fi
  fi
  if [ -z "$cause" ]; then
    # Remembered only when both reads had their say (the solo one needs the
    # gate's cached verdict, so it may come a tick later).
    [ "$read" = 1 ] && [ "$solo" = 1 ] && mc_attempt_put "culpritchecked $key $head"
    return 1
  fi
  mc_attempt_put "dqwculprit $key $head"
  # `culpritreejected` names the strike this mark adds, so mc_eject_head_strikes
  # can leave out exactly this one and never a real second ejection.
  mc_attempt_has "reejected $key $head" 2>/dev/null || { mc_attempt_put "reejected $key $head"; mc_attempt_put "culpritreejected $key $head"; }
  mc_log "EJECT_CULPRIT $key $head — $cause; not a flake: never re-queued, only a new head clears it"
  return 0
}

# mc_eject_strikes <key> -> the number of queue ejections that count as strikes
#   Every `ejected`/`reejected` line for the PR, less those on a head marked
#   `ejectconflict`: a base-branch conflict is main moving under the PR, and the
#   rebase answers it (BH-1677). MC_EJECT_REBASE=0 runs the count this replaced,
#   verbatim. An unreadable file counts 0, as the grep did.
#   Both reads go through the attempt verbs (BH-2360); the awk runs over the
#   lines mc_attempt_lines copies out, in file order.
mc_eject_strikes() {
  if [ "${MC_EJECT_REBASE:-}" = 0 ]; then
    mc_attempt_count "ejected|reejected" "$1"
    return 0
  fi
  local t
  t=$(mktemp "${TMPDIR:-/tmp}/mc-eject.XXXXXX") || { echo 0; return 0; }
  mc_attempt_lines "ejected|reejected|ejectconflict" "$1" "$t"
  awk -v k="$1" '
    $1 == "ejectconflict" && $2 == k { c[$3] = 1; next }
    ($1 == "ejected" || $1 == "reejected") && $2 == k { h[NR] = $3 }
    END { n = 0; for (i in h) if (!(h[i] in c)) n++; print n }' "$t" 2>/dev/null || echo 0
  rm -f "$t"
}

# mc_eject_head_strikes <key> <head> -> mc_eject_strikes, less the `reejected`
#   line mc_eject_culprit_mark wrote on an OLDER head (it marks it
#   `culpritreejected`; BH-5819 lead reviews of 4fedb2dd and 2cc40e58). That
#   line sends the culprit head to the resolver at once; counted against a new
#   head, it would send every later head there too, and only a new head clears a
#   culprit. A real second ejection, and the old head's real `ejected` line,
#   still count. Not under MC_EJECT_REBASE=0 or with no head.
mc_eject_head_strikes() {
  local n x=0 h t
  n=$(mc_eject_strikes "$1")
  if [ -n "${2:-}" ] && [ "${MC_EJECT_REBASE:-}" != 0 ] && t=$(mktemp "${TMPDIR:-/tmp}/mc-eject.XXXXXX"); then
    mc_attempt_lines culpritreejected "$1" "$t"
    while IFS= read -r h; do
      [ -n "$h" ] && [ "$h" != "$2" ] && mc_attempt_has "reejected $1 $h" 2>/dev/null \
        && ! mc_attempt_has "ejectconflict $1 $h" 2>/dev/null && x=$((x + 1))
    done < <(awk '{ print $3 }' "$t" 2>/dev/null | sort -u)
    rm -f "$t"
  fi
  n=$((${n:-0} - x)); [ "$n" -ge 0 ] || n=0
  echo "$n"
}

# mc_eject_runs_file <key> — where the conductor leaves a twice-ejected PR's
#   failing batch runs for bin/blocked-resolver.sh's fix-round brief (BH-6000).
mc_eject_runs_file() { printf '%s/eject-runs/%s' "$MC_STATE_DIR" "$(mc_handoff_id "$1")"; }

# mc_eject_fix_now <project> <slug> <key> <head> <url> -> rc 0
#   The queue-ejected-twice park gets its fix round NOW, not on the resolver's
#   next pass (BH-6000 part 5). Once per (PR, head) (`ejectfix` attempt):
#     1. the last two Mergify dequeues' failing batch runs (bej_eject_runs, one
#        REST read) go to mc_eject_runs_file, which the resolver's fix-round
#        brief reads, and which sends the park straight to the fix round
#        (merging main and re-running CI answer nothing about a batch build
#        that is red against current main);
#     2. bin/blocked-resolver.sh is started for this one PR, detached:
#        `BR_ONLY_PR=<key> blocked-resolver.sh <project>`, so the round starts
#        in this tick. Its own per-key and per-project locks still apply: a
#        resolver run of this project that is already scanning turns it away.
#        That run takes the park only if it listed it; else the next resolver
#        tick does, and the runs file still sends it to the fix round.
#   Observe mode (ACTIONS!=1): one WOULD line, nothing written. No runs found
#   (rc 1): the file is not written, the resolver is still started, and its
#   ladder runs as before (rung 1 first). An unreadable read (rc 2) writes no
#   mark and starts nothing; the parked-row pass of the next tick (`parked
#   merged settle` in bin/merge-conductor.sh, which visits every OPEN
#   queue-ejected-twice row under its PR lock) calls this again. The third
#   unreadable read on one head (`ejectfix-unread` attempts) hands the park
#   over without runs, so a lasting read failure costs two ticks, not the
#   fix round. The mark is written BEFORE the launch, so a head is never
#   handed over twice.
mc_eject_fix_now() {
  local p="$1" slug="$2" key="$3" head="$4" url="$5" runs="" rc f
  [ -n "$key" ] && [ -n "$head" ] || return 0
  command -v nv_twice_note >/dev/null 2>&1 && nv_twice_note "$p" "$slug" "$key" "$head" "$url"
  mc_attempt_has "ejectfix $key $head" 2>/dev/null && return 0
  if [ "${ACTIONS:-0}" != 1 ]; then
    mc_log "$key would hand queue-ejected-twice to a fix round now with its two failing batch runs (observe mode: nothing written)"; return 0; fi
  f=$(mc_eject_runs_file "$key")
  rc=0; command -v bej_eject_runs >/dev/null 2>&1 && runs=$(bej_eject_runs "$slug" "${key##*#}" 2) || rc=$?
  # AN UNREADABLE READ IS RETRIED, NOT STAMPED (lead reviews lr-6024). rc 2 is
  # "the comments could not be read" (a rate limit included): no mark, no file,
  # no launch, and the parked-row pass of the next tick calls this again. Three
  # unreadable reads on one head end the retries: the park is handed over
  # without runs. rc 1 (read, no runs found) is an answer.
  if [ "$rc" = 2 ]; then
    local tries; tries=$(mc_attempt_count ejectfix-unread "$key" "$head")
    case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
    if [ "$tries" -lt 2 ]; then
      mc_attempt_put_n ejectfix-unread "$key" "$head"
      mc_log "$key queue-ejected-twice: the dequeue comments could not be read (rc 2, read $((tries + 1)) of 3) — the next tick's parked-row pass asks again"
      return 0
    fi
  fi
  mc_attempt_put "ejectfix $key $head"
  if [ -n "$runs" ]; then
    mkdir -p "$(dirname "$f")" 2>/dev/null
    { printf '%s\n' "$head"; printf '%s\n' "$runs"; } > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  else
    mc_log "$key queue-ejected-twice: the failing batch runs could not be read from Mergify's dequeue comments (rc $rc) — the fix round starts without them"
  fi
  ( BR_ONLY_PR="$key" setsid "$MC_H/bin/blocked-resolver.sh" "$p" </dev/null >>"$MC_H/logs/blocked-resolver-cron.log" 2>&1 9>&- 8>&- 7>&- 6>&- & ) 2>/dev/null
  # "launch requested", not "started": the detached launch reports nothing
  # back (Fable review of 9a72142b2, finding 1). The resolver's own
  # `one-PR run for <key>` line in its log is the proof that it ran.
  mc_log "$key queue-ejected-twice — bin/blocked-resolver.sh launch requested for this PR now (BR_ONLY_PR), its fix round handed $(grep -c . <<<"$runs") failing batch run(s): $url"
  return 0
}

# mc_dequeue_surface <key> <pr-url> <head-sha> <reason> [merges] -> rc 0
#   One PR comment + one fleet_alert beat + one log line per (PR, head), for a
#   dequeue mc_dequeue_reason could name (BH-872). Called from the ejection arm
#   of bin/merge-conductor.sh, inside its `# >>> dequeue surface` markers.
#
# THE MARK IS WRITTEN FIRST (D16). The conductor ticks every five minutes and a
# dequeued PR stays dequeued, so the failure this guards is a comment per tick
# for ever. A crash between the mark and the comment costs this head its one
# comment; the beat's akey carries the same (PR, head) key, so the fleet feed
# still dedupes and the next HEAD gets its own notice.
#
# The comment is a gh WRITE, so it happens only in merge mode, exactly like the
# label retraction above it. The beat fires in every mode: an observe tick that
# noticed the dequeue is the only thing that noticed it.
#
# OVER REST, NEVER `gh pr comment` (#891 review round 1, Important 2). `gh pr
# comment` is a GraphQL mutation and this fleet's accounts hit the GraphQL limit
# and die mid-tick — the same reason br_escalate_review posts through
# br_pr_comment and mc_close_for_rebuild (:1726 above) posts through
# `gh api -X POST repos/<slug>/issues/<n>/comments`. This is that shape.
mc_dequeue_surface() {
  local key="${1:-}" url="${2:-}" head="${3:-}" reason="${4:-}" merges="${5:-0}" body cslug cnum
  [ -n "$key" ] && [ -n "$url" ] && [ -n "$head" ] && [ -n "$reason" ] || return 0
  mc_attempt_has "dequeue-surfaced $key $head" 2>/dev/null && return 0
  mc_attempt_put "dequeue-surfaced $key $head"
  body="Mergify took this PR out of the queue because a standing changes-requested review makes github-review-approved false. What re-enqueues it: that review is dismissed or a newer head is approved; the conductor requeues a head once, and a head already requeued needs a person."
  if [ "$merges" = 1 ]; then
    cslug=$(mc_slug_of_url "$url"); cnum=$(mc_num_of_url "$url")
    if [ -n "$cslug" ] && [ -n "$cnum" ]; then
      gh api -X POST "repos/$cslug/issues/$cnum/comments" -f "body=$body" >/dev/null 2>&1 \
        || mc_log "$key dequeue ($reason) on ${head:0:8} could NOT be commented on the PR — the beat is the only notice this head gets (POST repos/$cslug/issues/$cnum/comments)"
    else
      mc_log "$key dequeue ($reason) on ${head:0:8} has no readable owner/repo#number in its URL ($url) — no PR comment, the beat is the only notice"
    fi
  fi
  "$MC_H/bin/beat.sh" "$(jq -nc --arg akey "dequeue:$key:$head" \
    --arg l "[merge-conductor] $key left the merge queue on $reason (${head:0:8}) — a standing changes-requested review, not a red batch: $url" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  mc_log "$key DEQUEUED_REVIEW $reason on ${head:0:8} — Mergify dropped it because a standing changes-requested review makes $reason false, not because its batch went red; it re-enters the queue when that review is dismissed or a newer head is approved, and a head the conductor already requeued once needs a person: $url"
  return 0
}


# mc_merge <url> <head-sha> -> rc 0 merged (GitHub verified), 1 not merged (stderr line on stdout)
#
# REST FIRST (BH-892). `gh pr merge` is a GraphQL mutation; with that bucket
# empty this function failed on a PR that was perfectly mergeable, the caller
# spent a strike, and two strikes park the ticket merge-failed-twice for
# bin/blocked-resolver.sh to rebuild. `PUT …/pulls/<n>/merge` is a different
# budget, and the reviewed head rides on it as the `sha` field — the REST
# equivalent of --match-head-commit, so a moved head is a 409 rather than a blind
# merge. A 405/409/422 is GitHub's answer ABOUT THIS MERGE and is returned as a
# plain rc 1 with the reason, which is exactly what the two-strike path expects.
#
# On rc 0 STDOUT carries the merge sha the 200 answered with (empty when the
# 200 carried none, or when the merge went over gh's own line below). It rides
# on stdout and nothing else: every production caller is
# `ERR=$(mc_merge_locked "$P" mc_merge …)`, a command substitution, so a shell
# variable set in here would die in that subshell and never reach the settle.
# bin/merge-conductor.sh's conductor_settle threads the captured stdout into
# mc_settle_merged as its trailing argument, so the deploy hand-off needs no
# GraphQL read for a sha GitHub already gave us — under the cap that read is
# the one that fails.
mc_merge() {
  local url="$1" head="$2" err rc out slug num sn pst=""
  if command -v gh_pr_merge_rest >/dev/null 2>&1; then
    out=$(gh_pr_merge_rest "$(mc_slug_of_url "$url")" "${url##*/}" "$head" \
            "$MC_H/logs/merge-conductor-gh.err" "$MC_LOG" "mc_merge ${url##*/}"); rc=$?
    case "$rc" in
      0) printf '%s' "$out"; return 0 ;;
      2) : ;;   # no REST verdict — today's call below
      3) # A 405 is GitHub refusing to merge NOW, and one of its readings is a
         # PR the console or the sweep landed between the conductor's list read
         # and this call ("Pull Request is not mergeable"). The gh line below
         # turned that into rc 0 through its state read; keep that, so a PR
         # that has already merged never costs a mergefail row. The read is the
         # REST one (BH-784): under the cap a GraphQL read is the call that
         # fails, and an unanswered read stays rc 1, like any other refusal.
         # BH-1485: the `_var` variant. The old `[ "$(gh_rest_pr_state …)" = merged ]`
         # decided correctly and threw GH_REST_STATUS away with the subshell.
         if sn=$(mc_rest_slug_num "$url"); then read -r slug num <<<"$sn"
           gh_rest_pr_state_var pst "$slug" "$num" 2>/dev/null || pst=""
           [ "$pst" = merged ] && return 0; fi
         printf '%s' "HTTP refusal (rc $rc): $out"; return 1 ;;
      *) printf '%s' "HTTP refusal (rc $rc): $out"; return 1 ;;
    esac
  fi
  # THE METHOD COMES FROM THE REPO (BH-1313); `--squash` without the lib.
  local mflag=--squash
  command -v gh_pr_merge_flag >/dev/null 2>&1 \
    && mflag=$(gh_pr_merge_flag "$(mc_slug_of_url "$url")" "${url##*/}" "$MC_LOG" "mc_merge ${url##*/}")
  err=$(gh pr merge "$url" "$mflag" --match-head-commit "$head" 2>&1 >/dev/null) || true  # gh-guard-allow: gated merge verb, out of BH-770 scope
  case "${MC_MERGE_SETTLE:-}" in ''|*[!0-9]*) ;; *) sleep "$MC_MERGE_SETTLE" ;; esac
  # The VERIFYING read, not gh's exit code (#272). A read that could not answer
  # is "not merged" here exactly as an empty GraphQL answer was — the caller's
  # two-strike path owns it — but it can no longer be mistaken for a fact.
  sn=$(mc_rest_slug_num "$url") && { read -r slug num <<<"$sn"
    gh_rest_pr_state_var pst "$slug" "$num" 2>/dev/null || pst=""
    [ "$pst" = merged ] && return 0; }
  printf '%s' "$(head -1 <<<"$err")"; return 1
}

# mc_enqueue <url> <head-sha> — put a READY PR into its repo's merge queue,
# whichever provider that repo has. One contract for both:
#   rc 0  enqueued  (the provider's own witness says so)
#   rc 2  merged outright inside the tick (a one-entry queue can land that fast;
#         also what happens if the queue was removed between probe and call)
#   rc 3  mergify only: the request is in place and the QUEUE never answered —
#         a standing condition on the repo (the Merge Queue product is off), not
#         a fact about this PR. NOT a strike; see mc_enqueue_mergify
#   rc 1  a real failure — stdout carries one line saying why, and the caller's
#         existing two-strike path owns it
#   rc 4  mergify only: a human lead verdict is required (BH-3806); nothing
#         written; stdout is the refusal, `refused: ` then the reason naming
#         `bin/lead-verdict.sh post ... MERGE --source human`. NOT a strike
#   rc 99 on a lane-run machine (MC_ON_MACHINE=1, BH-6495): nothing written
mc_enqueue() {
  local url="$1" head="$2" slug
  # A lane-run machine enqueues nothing (BH-6495): an enqueue is a landing, and
  # the hub owns every landing. 99 = nothing was written, the next tick tries.
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then
    [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo enqueue >> "$MC_PR_DEFERRED_FILE"
    printf 'on a lane-run machine — not enqueued here; the hub enqueues it'; return 99
  fi
  slug=$(mc_slug_of_url "$url")
  case "$(mc_queue_provider "$slug")" in
    mergify) mc_enqueue_mergify "$slug" "$url" "$head" ;;
    # BH-2275: an unreadable probe is not "no queue". gh pr merge here would
    # MERGE on a repo with no native queue, so refuse; the caller retries.
    unknown) printf 'the merge-queue provider of %s could not be read (.mergify.yml probe) — nothing enqueued or merged' "$slug"; return 1 ;;
    *)       mc_enqueue_github "$url" "$head" ;;
  esac
}

# mc_enqueue_github <url> <head-sha> — the same call as mc_merge, on a repo whose
# main is behind GitHub's NATIVE queue, where it means something different.
#
# --auto IS DELIBERATELY NOT PASSED. `--auto` maps to enablePullRequestAutoMerge,
# which requires allow_auto_merge on the repo, and that setting is FALSE on every
# fleet repo (docs/MERGE-CONDUCTOR.md section 6). gh 2.100 already enqueues on a
# merge-queue branch without it — its own help says so — so one command form
# serves the whole fleet: it enqueues where there is a queue and merges where
# there is not. Turning allow_auto_merge on is a repo-settings change and gets
# its own decision, not a silent flag here.
mc_enqueue_github() {
  local url="$1" head="$2" err mrc st src mflag=--squash
  # The ENQUEUE carries a method too: the repo's own queue settles it, but a
  # repo that refuses squash refuses the verb (BH-1313). `--squash` without lib.
  command -v gh_pr_merge_flag >/dev/null 2>&1 \
    && mflag=$(gh_pr_merge_flag "$(mc_slug_of_url "$url")" "${url##*/}" "$MC_LOG" "mc_enqueue ${url##*/}")
  err=$(gh pr merge "$url" "$mflag" --match-head-commit "$head" 2>&1 >/dev/null); mrc=$?  # gh-guard-allow: gated merge verb, out of BH-770 scope
  case "${MC_ENQUEUE_SETTLE:-}" in ''|*[!0-9]*) ;; *) sleep "$MC_ENQUEUE_SETTLE" ;; esac
  st=$(mc_pr_view "$url" .STATE 2>/dev/null); src=$?
  [ "$src" = 0 ] || st=""
  [ "$st" = MERGED ] && return 2
  [ "$mrc" = 0 ] && [ "$st" = OPEN ] && return 0
  # THE VERB SUCCEEDED AND THE VERIFYING READ DID NOT ANSWER (BH-784). rc 75 is
  # "come back later", not "the enqueue failed", and falling through to rc 1 here
  # turns a rate limit into a merge failure — a strike against the PR, twice and
  # it is BLOCKED_AGENT, for an enqueue GitHub accepted. Report it enqueued: the
  # settle pass reads the real state on the next tick and is the thing that
  # decides merged/ejected anyway. Only 75; a 404 after an accepted merge verb is
  # a genuine contradiction and keeps the failure path.
  [ "$mrc" = 0 ] && [ "$src" = 75 ] && return 0
  printf '%s' "$(head -1 <<<"$err")"; return 1
}

# mc_mergify_command <owner/repo> <issue-num> <body> — post one `@mergifyio …`
# comment AS A PAT (review round 3 of #2231). Mergify ignores commands the App
# authors, and on a C2 box a bare `gh api` with no GH_TOKEN is the App: the gh
# shim mints one for repos/example-org/*. So the identity is chosen explicitly in
# a subshell (the caller's GH_TOKEN is untouched): gh_repo_use_pat's PAT
# (default, then admin), and GH_USE_PAT=1 so the shim can never swap in the
# App. No PAT can see the repo: rc 1, nothing posted — a command the App posts
# is one Mergify never acts on, which is worse than a visible failure.
mc_mergify_command() {
  local slug="$1" num="$2" body="$3"
  (
    if command -v gh_repo_use_pat >/dev/null 2>&1; then
      gh_repo_use_pat "$slug" >/dev/null 2>&1 || exit 1
    else
      case "${GH_TOKEN:-}" in ghs_*) unset GH_TOKEN ;; esac
    fi
    export GH_USE_PAT=1
    gh api -X POST "repos/$slug/issues/$num/comments" -f "body=$body" >/dev/null 2>&1
  )
}

# mc_mergify_ask_file <owner/repo> <url> — the per-PR ask ledger: one line,
#   "<head>\t<command>", its mtime the time of the last accepted post.
mc_mergify_ask_file() {
  [ -n "${MC_STATE_DIR:-}" ] || return 0
  printf '%s/mergify-asked/%s_%s' "${MC_STATE_DIR:-}" "$(mc_safe_name "$1")" "$(mc_num_of_url "$2")"
}
# mc_mergify_ask_due <file> <head> <cmd> — rc 0 when the command should be
#   posted: no ledger (or no state dir to keep one in), a different head or
#   command, or an ask older than MC_MERGIFY_REASK_S. That knob unset, 0 or not
#   a number reads as the branch that does less: once per head.
mc_mergify_ask_due() {
  local f="$1" head="$2" cmd="$3" win="${MC_MERGIFY_REASK_S:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  [ "$(head -1 "$f" 2>/dev/null)" = "$head"$'\t'"$cmd" ] || return 0
  case "$win" in ''|*[!0-9]*|0) return 1 ;; esac
  [ $(( $(date -u +%s) - $(mc_mtime "$f") )) -ge "$win" ]
}

# mc_enqueue_mergify <owner/repo> <url> <head-sha> — enqueue by LABEL.
#
# WHY THE LABEL AND NOT `@mergifyio queue`. Both work. The label is idempotent
# (adding it twice is one state, a comment twice is two comments on the PR), it
# is visible in the PR list — which is how the conductor's own open pass reads
# "is this queued" for free, with no extra API call — and it is the condition the
# fleet's `.mergify.yml` template keys on, so one contract covers entry, the read
# and the retraction (mc_dequeue_label). Creating the label in a repo is an OPS
# step, not code: `gh label create merge-queue` once per repo. Deliberately not
# done here — a merger that can invent repo-level metadata on a failure path is
# how a typo becomes a silent second queue. gh's error when the label is missing
# is carried out of here verbatim, and docs/MERGIFY.md names the fix.
#
# --match-head-commit HAS NO EQUIVALENT, and this is the honest gap. Under the
# native queue the enqueue is head-pinned server-side. A label is not: Mergify
# queues whatever the head is when it picks the PR up. The guard is therefore the
# caller's — bin/merge-conductor.sh re-reads state+headRefOid immediately before
# acting and only labels a PR whose head is still the reviewed sha — and that is
# a TOCTOU window, not a guarantee. A push landing inside that window is caught
# one tick later as HEAD_MOVED, and by Mergify's own queue_conditions if the
# repo's config carries a head-bound one.
#
# VERIFICATION IS A MERGIFY WITNESS, NOT OUR OWN LABEL. The label is what we
# asked for; the check run is what Mergify did. A repo whose .mergify.yml has
# queue_rules but whose app was never installed would otherwise sit in QUEUED
# forever with nobody merging it — the label would be its own proof.
#
# "NO WITNESS" IS ITS OWN OUTCOME (rc 3), AND IT IS NOT A FAILURE.
# THE LIVE EVIDENCE (project-5 #510, 2026-09-12): `@mergifyio queue` was answered
# with **"The product Merge Queue needs to be activated"**. The app was installed,
# the config was right, the label was right — the QUEUE PRODUCT was simply not
# turned on for the account. That is a standing condition somebody has to fix in
# a dashboard, not a transient this conductor can retry its way out of, and the
# PR is in no way broken. Routing it into the two-strike `mergefail` path would
# park every READY PR on the repo in BLOCKED_HUMAN — a state a human then has to
# clear by hand, one PR at a time, for a condition that has nothing to do with any
# of them. So:
#
#   rc 3  the label IS applied (or could not be written — the reason says
#         which), no strike is recorded, and the CALLER decides what to do about
#         a queue that did not answer. Since BH-2199 bin/merge-conductor.sh HOLDS
#         the PR READY with the label on, raises ONE alert per repo per day, and
#         asks again every MC_MERGIFY_REASK_TICKS held ticks; it never merges
#         around the queue (a direct merge there is a lead action), and the
#         console Merge button acks a terminal refusal.
#   rc 1  a real failure: gh refused the write (missing label, no permission).
#   rc 4  a human lead verdict is required; nothing written; stdout is the
#         refusal (BH-3806, below).
#
# The three polls are the transient budget. Mergify posts its check within
# seconds when the product is live, so "still nothing after three" means the
# condition is standing, not slow.
#   THE COMMAND IS THE 4th ARGUMENT (BH-636), defaulting to what every existing
#   caller sends, so the re-entry path can ask for `@mergifyio requeue` — the
#   only thing that re-embarks a PR Mergify dequeued on the same head — through
#   this one function instead of a second copy of the label+comment+witness
#   dance.
mc_enqueue_mergify() {
  local slug="$1" url="$2" head="$3" cmd="${4:-@mergifyio queue}" err n vsnote=""
  # BH-3348: the `lead-verdict` commit status FIRST, on the head being asked
  # for. Every caller reaches this only after its own head-bound verdict, and
  # cromford's queue_conditions require the status, so without it Mergify
  # would refuse every harness-built PR. A refused publish does not change the
  # rc (a repo that does not require it queues as before); if Mergify then
  # stays silent, the rc 3 reason says the status is the likely cause.
  # NEVER SILENT (BH-3348 review): on a repo that requires the status, a head
  # without it is witnessed by Mergify and then waits on queue_conditions
  # forever, so rc 0 alone would read as a good enqueue. Every failed publish
  # is one conductor log line and one alert per repo per UTC day.
  local vserr lac=0
  # BH-3683: the conductor obeys the same authority rule as a lead post. A PR
  # touching a protected path (or a repo whose lane authority is revoked) gets
  # no success from here. BH-3806: and no label and no ask either, from ANY
  # caller (the conductor, the console Merge button, rule-adopt, the
  # batch-resolve train, the requeue paths) — a labelled PR Mergify will not
  # take read QUEUED for hours (#3753, #3758). rc 4, nothing written, stdout
  # the refusal naming the --source human command that publishes the status.
  # Undecidable = the BH-2199 hold: nothing published, nothing asked, rc 3.
  # mc_la_decide when loaded: inside a conductor worker the gate already asked.
  if command -v la_decide >/dev/null 2>&1; then
    if command -v mc_la_decide >/dev/null 2>&1; then
      mc_la_decide "$slug" "$(mc_num_of_url "$url")" "$head" || lac=$?
    else
      la_decide "$slug" "$(mc_num_of_url "$url")" "$head" conductor || lac=$?
    fi
    case "$lac" in
      0) ;;
      1) command -v mc_log >/dev/null 2>&1 && mc_log "$slug@${head:0:12}: lead-verdict withheld, a human verdict publishes it (${LA_REASON}) — NOT labelled or asked: $url"
         la_human_needed "$slug" "$(mc_num_of_url "$url")" "$head" "$LA_REASON" merge-conductor || true
         if command -v mc_nhv_reason >/dev/null 2>&1; then
           printf 'refused: %s' "$(mc_nhv_reason "$slug" "$(mc_num_of_url "$url")" "$head" "$LA_REASON")"
         else
           printf 'refused: lead-verdict withheld on %s: %s — a human verdict publishes it: bin/lead-verdict.sh post %s %s %s MERGE --source human' \
             "${head:0:12}" "${LA_REASON:-no reason given}" "$slug" "$(mc_num_of_url "$url")" "$head"
         fi
         return 4 ;;
      *) printf 'the lead authority could not be decided (%s) — nothing published or asked; asked again next hold' "$LA_REASON"
         return 3 ;;
    esac
  fi
  if command -v vs_publish >/dev/null 2>&1 \
     && ! vserr=$(vs_publish "$slug" "$head" success "harness verdict cleared ${head:0:12} for the queue" "$url" 2>&1 >/dev/null); then
    # vs_publish ran in a substitution, so its GH_REST_STATUS never reached
    # this shell: the HTTP answer is the one its stderr line names.
    vserr=$(head -1 <<<"$vserr")
    vsnote="the lead-verdict status could not be published on ${head:0:12} (${vserr:-no reason given}); "
    echo "${vserr:-vs_publish failed on $slug@${head:0:12}}" >&2
    command -v mc_log >/dev/null 2>&1 && mc_log "${vserr:-vs_publish failed on $slug@${head:0:12}} — $url"
    mc_status_unpublished_alert "$slug" "$url" "$vserr"
  fi
  # >>> queue partition scopes (BH-4979)
  # The PR's impact lane (bin/lib/queue-partition.sh): logged as a PARTITION
  # line, uploaded as Mergify scopes in enforce mode, BEFORE the label. rc 3 is
  # the BH-2199 hold: a parallel queue never takes a PR without its scopes.
  local qpout
  command -v qp_enqueue_step >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/../queue-partition.sh" ] && . "${BASH_SOURCE[0]%/*}/../queue-partition.sh"; }
  if command -v qp_enqueue_step >/dev/null 2>&1; then
    qpout=$(qp_enqueue_step "$slug" "$(mc_num_of_url "$url")" "$head") || { printf '%s%s' "$vsnote" "$qpout"; return 3; }
  fi
  # <<< queue partition scopes (BH-4979)
  # >>> queue risk (BH-5430)
  # The PR's break-risk score (bin/lib/queue-risk.sh): logged as a QRISK line
  # and recorded on every enqueue, so a requeue re-scores under the current
  # rows; in enforce mode a high score adds the solo label BEFORE merge-queue.
  # rc 0 always — it never holds a PR.
  command -v qr_enqueue_step >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/../queue-risk.sh" ] && . "${BASH_SOURCE[0]%/*}/../queue-risk.sh"; }
  if command -v qr_enqueue_step >/dev/null 2>&1; then
    qr_enqueue_step "$slug" "$(mc_num_of_url "$url")" "$head" || true
  fi
  # <<< queue risk (BH-5430)
  # REST, not `gh pr edit`: on 2026-09-13 `gh pr edit --add-label` failed on
  # every example-org PR with a GraphQL "Projects (classic) is being deprecated"
  # error (gh's edit path queries project cards the token cannot read), and
  # four READY project-5 PRs were parked BLOCKED_HUMAN for a label that never
  # went on. The issues labels endpoint is one request and reads nothing else.
  # A label write that fails is "the queue cannot be entered", the same
  # condition as a queue that never answers — rc 3, the conductor's hold with
  # its once-a-day alert (BH-2199) — never a strike against the PR.
  err=$(gh api -X POST "repos/$slug/issues/$(mc_num_of_url "$url")/labels" -f "labels[]=$MC_MERGIFY_LABEL" 2>&1 >/dev/null) || {
    printf 'label %s could not be added via REST (%s) — the queue cannot be entered' "$MC_MERGIFY_LABEL" "$(head -1 <<<"$err")"
    return 3
  }
  # THE LABEL IS THE MARK, THE COMMAND IS THE ASK (2026-09-13, project-5 #516).
  # With the Merge Queue product live, a PR carrying the label got Mergify's
  # "Merge queue is ready — use @Mergifyio queue or the dashboard" check and
  # nothing else: the label rule did not queue it, the command did (entered
  # queue 2026-09-13 03:00). So the conductor posts the command as well. It is
  # idempotent on Mergify's side (a queued PR answers "already queued"), and a
  # failed comment is not fatal — the witness poll below decides.
  #
  # ONCE PER HEAD, NOT ONCE PER TICK (review round 3). A held PR (BH-2199: a
  # silent queue holds the row READY) comes back READY every tick, and a comment is
  # not idempotent on OUR side: every tick was one more `@mergifyio queue` on
  # the PR. The ledger (mc_mergify_ask_due) posts it again only for a new head,
  # a different command, or once MC_MERGIFY_REASK_S has passed. It records only
  # a post GitHub accepted, so a failed post is asked again next tick, and it is
  # CLEARED the moment Mergify answers (witnessed or merged): the ledger only
  # ever holds an ask nobody acknowledged, so a later legitimate ask on the same
  # head (a PR the queue took and later let go) is never swallowed.
  local askf; askf=$(mc_mergify_ask_file "$slug" "$url")
  if mc_mergify_ask_due "$askf" "$head" "$cmd"; then
    # The post is mc_mergify_command (C2): as a PAT, never the App, whose
    # commands Mergify ignores. Recorded only when that post succeeded.
    if mc_mergify_command "$slug" "$(mc_num_of_url "$url")" "$cmd"; then
      [ -n "$askf" ] && mkdir -p "${askf%/*}" 2>/dev/null \
        && printf '%s\t%s\n' "$head" "$cmd" > "$askf" 2>/dev/null
    fi
  fi
  # Mergify acknowledges in ~40-60s, not 9: it evaluates on its own worker, posts
  # the queue-status comment, then the check. MC_MERGIFY_WAIT_S (registry
  # default 90) bounds the wait in MC_MERGIFY_SETTLE steps; the fixtures set both
  # to 0, and a value that is not a number reads as 0: one pass, no wait.
  local waited=0 step="${MC_MERGIFY_SETTLE:-}" limit="${MC_MERGIFY_WAIT_S:-}"
  case "$step" in ''|*[!0-9]*) step=0 ;; esac
  case "$limit" in ''|*[!0-9]*) limit=0 ;; esac
  while :; do
    [ "$(mc_queue_state "$url" "$head")" = merged ] && { rm -f "$askf" 2>/dev/null; return 2; }
    mc_mergify_witness "$slug" "$url" "$head" && { rm -f "$askf" 2>/dev/null; return 0; }
    [ "$waited" -ge "$limit" ] && break
    sleep "$step"; waited=$((waited + step))
    [ "$step" -le 0 ] && break   # fixtures: one pass, no wait
  done
  printf '%slabel %s is applied, but Mergify acknowledged nothing on %s — activate the Merge Queue product for %s (Mergify answers `@mergifyio queue` with "The product Merge Queue needs to be activated" when it is off), or check that the app is installed and .mergify.yml queues on that label' \
    "$vsnote" "$MC_MERGIFY_LABEL" "${head:0:8}" "$slug"
  return 3
}

# mc_requeue_mergify <owner/repo> <pr-url> <head-sha> — PUT A DEQUEUED PR BACK.
#   Return codes are mc_enqueue_mergify's, unchanged (0 witnessed, 2 merged
#   meanwhile, 3 label on but nothing acknowledged, 1 refused, 4 a human lead
#   verdict is required and nothing was labelled or asked), so the caller has
#   one ladder to read; stdout is the reason on a refusal.
#
#   IT TOUCHES MERGIFY'S OWN LABEL, WHICH NOTHING ELSE HERE DOES. mc_dequeue_label
#   is deliberately limited to OUR trigger label — Mergify's labels are Mergify's
#   to manage — but `dequeued` is the marker that keeps this head out of the
#   queue, so leaving it on would make the re-add and the command both no-ops.
#   BH-636 asks for exactly this, on exactly this path, and docs/MERGIFY.md says
#   so. A 404 is the label already being gone, which is the desired state and not
#   a failure; ANY other refusal stops the whole thing, because a PR carrying
#   `merge-queue` AND `dequeued` is a PR nobody queues and nobody can read.
mc_requeue_mergify() {
  local slug="$1" url="$2" head="$3" n err
  n=$(mc_num_of_url "$url")
  if ! err=$(gh api -X DELETE "repos/$slug/issues/$n/labels/dequeued" 2>&1 >/dev/null); then
    case "$err" in
      *404*|*"Not Found"*|*"Label does not exist"*) : ;;
      *) printf 'the dequeued label could not be removed (%s)' "$(head -1 <<<"$err")"; return 1 ;;
    esac
  fi
  MC_WITNESS_FRESH=1 mc_enqueue_mergify "$slug" "$url" "$head" "${MC_MERGIFY_REQUEUE_CMD:-@mergifyio requeue}"
}

# mc_queue_inactive_alert <owner/repo> <url> — ONE alert per repo per UTC day for
# the standing "the queue is not taking PRs" condition above.
#
# PER REPO AND NOT PER PR, because the condition is the repo's: with the product
# off, every PR on it produces the same line, and a fleet that pages once per PR
# per tick for one dashboard toggle is a fleet nobody reads. rc 0 when it
# alerted, rc 1 when the day's line was already written.
#
# THE PR IS HELD, NOT MERGED (BH-2199). It used to be raised after a degraded
# DIRECT merge and said so; the conductor no longer merges around a Mergify
# queue, so the sentence says what is true now: held, and why, and what to do.
#
# UNDER A LOCK. Every PR of the repo runs in its own `pr_worker &` of one tick,
# and the ledger check below is a read-then-write: without the lock two held PRs
# of one tick page twice.
#
# THE SENTENCE FOLLOWS WHAT HAPPENED (BH-2275). The third argument is the
# enqueue's own reason; when it says the label could not be written, the alert
# says so instead of claiming the label went on.
mc_queue_inactive_alert() {
  local slug="$1" url="$2" why="${3:-}" mark lock asked
  mark="queue-inactive $slug $(date -u +%Y%m%d)"
  lock="${MC_LOCK_DIR:-$MC_H/locks}/merge-conductor-queue-silent-${slug//\//_}.lock"
  mkdir -p "${lock%/*}" 2>/dev/null
  (
    flock -x 9
    mc_attempt_has "$mark" 2>/dev/null && exit 1
    mc_attempt_put "$mark"
    case "$why" in
      *"could not be added"*) asked="the $MC_MERGIFY_LABEL label could not be written (${why%% — *}), so the queue was never entered" ;;
      *) asked="the queue was asked (the $MC_MERGIFY_LABEL label went on and \`@mergifyio queue\` was posted) and acknowledged nothing" ;;
    esac
    mc_alert "$slug" READY "mergify queue not answering for $slug — READY PRs are held, NOT merged: $asked. The conductor never merges around a queue_rules repo's queue (BH-2199); it asks again every $(mergify_reask_ticks_for "") held ticks. Activate the Merge Queue product (Mergify answers \`@mergifyio queue\` with \"The product Merge Queue needs to be activated\" when it is off) or check the app install; a direct merge meanwhile is a lead action: $url"
    exit 0
  ) 9>"$lock"
}

# mc_status_unpublished_alert <owner/repo> <pr-url> <why> — ONE alert per repo
#   per UTC day when mc_enqueue_mergify could not publish the lead-verdict
#   status (BH-3348). Same lock and ledger shape as mc_queue_inactive_alert. On
#   a repo whose queue_conditions require the status, every PR the conductor
#   asks for waits in the queue until a publish succeeds; the usual cause is an
#   App without "Commit statuses: Read and write" or a token mint that failed.
mc_status_unpublished_alert() {
  local slug="$1" url="$2" why="${3:-}" mark lock
  command -v mc_alert >/dev/null 2>&1 && command -v mc_attempt_has >/dev/null 2>&1 || return 0
  mark="status-unpublished $slug $(date -u +%Y%m%d)"
  lock="${MC_LOCK_DIR:-$MC_H/locks}/merge-conductor-status-unpublished-${slug//\//_}.lock"
  mkdir -p "${lock%/*}" 2>/dev/null
  (
    flock -x 9
    mc_attempt_has "$mark" 2>/dev/null && exit 1
    mc_attempt_put "$mark"
    mc_alert "$slug" READY "the $(vs_context 2>/dev/null || echo lead-verdict) commit status could not be published (${why:-no reason given}). If this repo's queue_conditions require it, Mergify holds every PR the conductor queues until a publish succeeds: give the hub App \"Commit statuses: Read and write\" or fix its token mint. The next enqueue ask publishes again: $url"
    exit 0
  ) 9>"$lock"
}

# mergify_reask_ticks_for <project> — MC_MERGIFY_REASK_TICKS for this project,
#   through the lane registry: how many held ticks pass between two queue asks
#   for a PR the queue has not acknowledged (BH-2199). Anything that is not a
#   positive integer reads as the registry default, 6 (about 30 minutes at the
#   conductor's 5-minute tick).
mergify_reask_ticks_for() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_MERGIFY_REASK_TICKS "${1:-}" 2>/dev/null)
  else v="${MC_MERGIFY_REASK_TICKS:-}"; fi
  case "$v" in ''|*[!0-9]*|0) v=6 ;; esac
  printf '%s' "$v"
}

# mc_queue_unknown_alert <owner/repo> <why> — ONE alert per repo per UTC day for
#   a queue provider that could not be read (BH-2275). Same lock and ledger
#   shape as mc_queue_inactive_alert: parallel PR workers page once.
mc_queue_unknown_alert() {
  local slug="$1" why="${2:-}" mark lock
  mark="queue-unknown $slug $(date -u +%Y%m%d)"
  lock="${MC_LOCK_DIR:-$MC_H/locks}/merge-conductor-queue-unknown-${slug//\//_}.lock"
  mkdir -p "${lock%/*}" 2>/dev/null
  (
    flock -x 9
    mc_attempt_has "$mark" 2>/dev/null && exit 1
    mc_attempt_put "$mark"
    mc_alert "$slug" READY "merge-queue provider probe failed for $slug: ${why:-the .mergify.yml probe could not be read} (BH-2275). If this persists, check the token's access to the repo contents"
    exit 0
  ) 9>"$lock"
}

# The hidden tag on every `@mergifyio dequeue` the conductor posts itself.
MC_CRDEQUEUE_TAG='<!-- mc:crdequeue -->'

# mc_cr_dequeue <owner/repo> <key> <pr-url> <head> <merges 0|1> [<scan-line>]
#   rc 0 when THIS call took a lead/human-blocked PR out of the Mergify queue
#   (BH-2275): a standing CHANGES_REQUESTED (bg_cr_standing) on a PR that is
#   queued, or held with our label on. Our label comes off and ONE
#   `@mergifyio dequeue` is posted, once per (PR, head) — the `crdequeue
#   <key> <head>` attempt line is written BEFORE the writes, so a crash costs a
#   missed dequeue, never a second one. The line also keeps the row out of
#   QUEUED (mc_mergify_inqueue) until a later witnessed enqueue clears it, i.e.
#   until the reviewer cleared the CR and the READY arm asked the queue again. rc 1 = nothing to do (no CR, already
#   done, not merge mode, or the reviews could not be read this tick).
#   <scan-line> is the block gate's answer when the caller already has it (the
#   READY arm); otherwise the reviews are read here, and the PR thread only when
#   a CR stands, so a RESUME/MERGE word from the reviewer is still honoured.
mc_cr_dequeue() {
  local slug="$1" key="$2" url="$3" head="$4" merges="${5:-0}" line="${6:-}" num c login at id
  num=$(mc_num_of_url "$url")
  if [ -z "$line" ]; then
    command -v bg_cr_standing >/dev/null 2>&1 || return 1
    line=$(bg_cr_standing "$slug" "$num" "$url" "$head" "") || return 1
    c=$(bg_read "repos/$slug/issues/$num/comments" created_at 2>/dev/null) || c=""
    if [ -n "$c" ]; then line=$(bg_cr_standing "$slug" "$num" "$url" "$head" "$c") || return 1; fi
  fi
  IFS=$'\t' read -r _ login at id <<<"$line"
  case "$id" in cr-*) ;; *) return 1 ;; esac
  mc_attempt_has "crdequeue $key $head" 2>/dev/null && return 1
  if [ "$merges" != 1 ]; then
    mc_log "$key WOULD dequeue: a standing CHANGES_REQUESTED (lead/human BLOCK) by @$login ($at) on a PR in the Mergify queue — not in merge mode, nothing written"
    return 1
  fi
  mc_attempt_put "crdequeue $key $head"
  gh api -X DELETE "repos/$slug/issues/$num/labels/$MC_MERGIFY_LABEL" >/dev/null 2>&1 || true
  # The tag marks this comment as the conductor's own (BH-5819 lead review):
  # it posts as the shared PAT (type User), and mc_eject_culprit_mark must not
  # read it as a human dequeue once the crdequeue mark is cleared. The command
  # stays alone on the first line, where Mergify reads it.
  gh api -X POST "repos/$slug/issues/$num/comments" -f body="@mergifyio dequeue

$MC_CRDEQUEUE_TAG" >/dev/null 2>&1 \
    || mc_log "$key the @mergifyio dequeue comment could not be posted — the label is off and .mergify.yml's #changes-requested-reviews-by=0 keeps it out"
  mc_log "$key CR_DEQUEUED: standing CHANGES_REQUESTED (lead/human BLOCK) by @$login ($at, ${id#*@}) on a PR in the Mergify queue — removed $MC_MERGIFY_LABEL and posted @mergifyio dequeue at ${head:0:8}"
  return 0
}

# mc_mergify_inqueue <owner/repo> <key> <url> <head> <labels-csv> <prev-state>
#   rc 0 when an OPEN PR on a mergify repo should classify QUEUED.
#
# OUR OWN LABEL IS NOT ENOUGH ON ITS OWN, and that is the whole point. Our label
# goes on BEFORE the witness poll, so a PR can carry it while the queue has never
# heard of it — during the rc-3 tick itself, and afterwards on any PR whose
# degraded direct merge then failed. If the label alone said "queued", such a PR
# would move to QUEUED, the settle pass would find it neither merged nor ejected,
# and it would sit there until its 3600s budget paged — a stall invented out of
# our own request. So the label counts only when something OTHER than us has
# confirmed it:
#   * one of Mergify's OWN labels (`queued`/`checking`) is present — free, it is
#     already in the list row;
#   * the row is ALREADY QUEUED, i.e. a witnessed enqueue put it there;
#   * otherwise, ask for the check run (one call, and only for the rare PR that
#     carries the label without being queued — normally none).
# An ejected head is never queued, whatever the label says: the local mark is
# authoritative because GitHub's PR list is eventually consistent. A head we
# have since PUT BACK is not ejected any more (mc_ejection_live, BH-636) — the
# bare mark would have made a requeued PR unable to ever read as queued again.
mc_mergify_inqueue() {
  local slug="$1" key="$2" url="$3" head="$4" labels="${5:-}" prev="${6:-}"
  mc_ejection_live "$key" "$head" && return 1
  # WE TOOK IT OUT FOR A LEAD CR (BH-2275). Mergify drops its own `queued`
  # label asynchronously, so a list read inside that window would put the row
  # straight back in QUEUED, and the next settle pass would count our own
  # dequeue as an ejection strike. Cleared by the next witnessed enqueue.
  mc_attempt_has "crdequeue $key $head" 2>/dev/null && return 1
  grep -qE '(^|,)(queued|checking)(,|$)' <<<"$labels" && return 0
  grep -qE "(^|,)$MC_MERGIFY_LABEL(,|\$)" <<<"$labels" || return 1
  [ "$prev" = QUEUED ] && return 0
  # A head we re-queued is witnessed only by something newer than the failure
  # it was ejected on (BH-3776, see mc_mergify_witness).
  if [ -n "$(mc_requeued_mark "$key" "$head")" ]; then
    MC_WITNESS_FRESH=1 mc_mergify_witness "$slug" "$url" "$head"
  else
    mc_mergify_witness "$slug" "$url" "$head"
  fi
}

# inq_mark — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# BH-1585 (review round 1, Q2): ONE MARKER PER REPO. The mark used to be one
# file for the whole fleet, so one repo's refusal switched the native-queue
# ejection witness off for every repo. inq_mark <slug> is that repo's file.
inq_mark() { printf '%s/gh-no-inqueue-%s' "$MC_STATE_DIR" "$(printf '%s' "${1:-}" | tr '/' '_')"; }

# inq_list_ok — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# inq_list_ok <slug> — rc 0 when this tick should ASK for isInMergeQueue in the list.
inq_list_ok() {
  case "$MC_LIST_INQUEUE" in 1) return 0 ;; 0) return 1 ;; esac
  local m; m=$(inq_mark "${1:-}")
  [ -f "$m" ] || return 0
  local age; age=$(( $(date -u +%s) - $(mc_mtime "$m") ))
  [ "$age" -lt 0 ] || [ "$age" -ge "$MC_INQUEUE_PROBE_TTL_SECS" ]
}

# inq_matters — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# inq_matters <mergeStateStatus> <previous-row-state> — rc 0 when the per-PR read
# is worth a call: the PR is in a merge state where the queue can hold it, or our
# own row already says it is queued.
inq_matters() {
  local ms="${1:-}" prev="${2:-}" w
  [ "$prev" = QUEUED ] && return 0
  for w in $MC_INQUEUE_STATES; do [ "$ms" = "$w" ] && return 0; done
  return 1
}

# --- A STUCK MERGIFY BATCH DRAFT IS REFRESHED (BH-1790) ----------------------
# 2026-09-23: three times Mergify left a merge-queue batch draft
# (`mergify/merge-queue/*`) with every check green for 18-25 minutes, "Waiting
# for check-success = ..." on two `if: always()` aggregate jobs that had passed.
# It had missed their completion event. Refreshing a MEMBER PR did nothing;
# `@mergifyio refresh` on the DRAFT unstuck it within 2 minutes, every time.
# While a batch is stuck the whole queue waits behind it and nothing is red.
#
# Deterministic, no LLM: an open batch draft whose non-Mergify check runs are
# ALL completed and green, with a run for every `check-success` name in
# .mergify.yml's queue_rules (BH-1887), the newest completion at least
# MC_MERGIFY_STUCK_SECS old, gets one `@mergifyio refresh` per
# MC_MERGIFY_REFRESH_WINDOW_SECS (0 = one per head for ever; 1-299 reads as the
# conductor tick, BH-1887). Still stuck MC_MERGIFY_STUCK_ALERT_SECS past the
# point it became due = one alert per day, for the OLDEST open batch draft only:
# a green batch N+1 is normal while Mergify is still waiting on batch N.
#
# THE RECORD is the attempts ledger (mc_attempt_put: the file, then the
# pr_attempts row twin), two lines per (draft, head, green moment, slot):
# `mergifyrefresh <slug>#<n> <head> <green-epoch> <slot>` is written once before
# the first POST (ATTEMPTED), `mergifyposted …` with the same words only after a
# POST that returned 0 (BH-1887). The green epoch is the newest completion, so a
# re-run check on the same head is a new green moment; the slot is which window
# since it became due (always 0 when the window is 0). A slot is used up only by
# a POST that went through: a failed one is retried on the next tick, and the
# alert says the refresh could not be posted.
#
# FAIL-SAFE: a list, check-run or .mergify.yml read that cannot be answered (a
# 403, a 5xx, no network, a body jq cannot read, a page that does not hold every
# check run) refreshes nothing and records nothing. Unverifiable is never "green".
# MC_MERGIFY_STUCK_SECS (0 = never refresh a batch draft, BH-1790),
# MC_MERGIFY_REFRESH_WINDOW_SECS (one refresh per draft per window while it
# stays stuck; 0 = one per head) and MC_MERGIFY_STUCK_ALERT_SECS (still stuck
# this long after a refresh was due = one alert per draft per day) resolve at
# the top of this file (BH-1939).
# The branch prefix Mergify gives its batch drafts. A contract with Mergify, not a knob.
MC_MERGIFY_BATCH_PREFIX="mergify/merge-queue/"

# mc_mergify_required_checks <slug> — the `check-success` names Mergify's
#   queue conditions wait on, one per line, de-duplicated (BH-1887). Read from
#   the `queue_rules:` block of the repo's .mergify.yml only (every queue, both
#   queue_conditions and merge_conditions: the strictest set). `~=`, `!=`, a
#   negated `-check-success` and `check-success-or-neutral` are not required
#   names; pull_request_rules are not queue conditions. rc 0 with no output =
#   the block names none; rc 75 = the file could not be read.
#   The decode is mc_queue_mergify_enabled's, duplicated on purpose: that one
#   gates the provider for every repo in the fleet and is not touched here.
#   The STATUS contexts in qsc_list (bin/lib/queue-status-contexts.sh:
#   `lead-verdict`, BH-3348, and `prequeue-verdict`, BH-5441) are skipped: each
#   is a commit status on the PR head, never a check run on a batch draft, so
#   asking the draft for one would stop every refresh. Without the lib, only the
#   lead-verdict context is skipped, as before. The lib is sourced at call time,
#   not at module load, so this module never reads as defining qsc_list
#   (tests/mc-split-layout-test.sh; the settle.sh patch-same.sh precedent).
mc_mergify_required_checks() {
  local slug="$1" b64 yml skip
  command -v qsc_list >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/../queue-status-contexts.sh" ] && . "${BASH_SOURCE[0]%/*}/../queue-status-contexts.sh"; }
  if command -v qsc_list >/dev/null 2>&1; then skip=$(qsc_list | paste -sd'|')
  else skip=$(command -v vs_context >/dev/null 2>&1 && vs_context || echo "${LEAD_VERDICT_CONTEXT:-lead-verdict}"); fi
  mc_policy_get b64 "$slug" mergify "repos/$slug/contents/.mergify.yml" || return 75
  b64=$(jq -r '.content // empty' <<<"$b64" 2>/dev/null) || return 75
  [ -n "$b64" ] || return 75
  yml=$(printf '%s' "$b64" | tr -d '\n\r ' | base64 -d 2>/dev/null) || yml=""
  [ -n "$yml" ] || yml="$b64"
  awk -v q="'" -v skip="$skip" '
    BEGIN { n = split(skip, sk, "|"); for (i = 1; i <= n; i++) skipset[sk[i]] = 1 }
    /^queue_rules:/ { inq = 1; next }
    inq && /^[^[:space:]#-]/ { inq = 0 }
    !inq || /^[[:space:]]*#/ { next }
    match($0, /(^|[[:space:]"\047])check-success[[:space:]]*=[[:space:]]*/) {
      v = substr($0, RSTART + RLENGTH)
      if (substr(v, 1, 1) == "\"" || substr(v, 1, 1) == q) {
        c = substr(v, 1, 1); v = substr(v, 2); i = index(v, c); if (i) v = substr(v, 1, i - 1)
      } else {
        sub(/[[:space:]]+#.*$/, "", v); sub(/["\047][[:space:]]*$/, "", v); sub(/[[:space:]]+$/, "", v)
      }
      if (v != "" && !(v in skipset) && !seen[v]++) print v
    }' <<<"$yml"
}

# mc_mergify_batch_green <slug> <sha> [<required names, one per line>] — prints
#   the newest completion epoch and answers rc 0 when every non-Mergify check
#   run on the head is completed and green (success, neutral, skipped) and
#   every required name has a run; rc 1 when one is pending or red, or there is
#   none, or a required name has no run (then the missing names are printed,
#   comma-separated); rc 75 when the page cannot be read or does not hold every run.
mc_mergify_batch_green() {
  local slug="$1" sha="$2" req="${3:-}" body rc=0 out
  # BH-7121: crs_status (completed_at + a green conclusion is completed).
  # Absent lib -> rc 75, unreadable, as for an unreadable page.
  # shellcheck source=bin/lib/mc/check-run-state.sh
  [ -n "${CRS_JQ_DEFS:-}" ] || . "${BASH_SOURCE[0]%/*}/check-run-state.sh" 2>/dev/null
  [ -n "${CRS_JQ_DEFS:-}" ] || return 75
  mc_rest_var body gh_rest GET "repos/$slug/commits/$sha/check-runs?per_page=100" || rc=$?
  [ "$rc" = 0 ] || return 75
  out=$(jq -r --arg req "$req" "$CRS_JQ_DEFS"'
    (.check_runs // []) as $all
    | [$all[] | select((.app.slug // "") != "mergify")] as $c
    | [$req | split("\n")[] | select(length > 0) | . as $n | select(any($c[]; .name == $n) | not)] as $miss
    | if (.total_count // 0) > ($all | length) then "partial"
      elif ($c | length) == 0 then "none"
      elif ([$c[] | select(crs_status != "completed"
               or ((.conclusion // "") | IN("success", "neutral", "skipped") | not))] | length) > 0 then "notgreen"
      elif ($miss | length) > 0 then "missing:" + ($miss | join(", "))
      else ([$c[].completed_at | fromdateiso8601] | max | tostring) end' <<<"$body" 2>/dev/null) || return 75
  case "$out" in
    none|notgreen) return 1 ;;
    missing:*) printf '%s' "${out#missing:}"; return 1 ;;
    ''|*[!0-9]*) return 75 ;;
  esac
  printf '%s' "$out"
}

# mc_mergify_stuck_pass <project> <owner/repo> <writes 0|1> — one pass over the
#   repo's open batch drafts. writes=0 (observe, kill switch, a merges pause)
#   logs what it WOULD post and records nothing, so the refresh is still owed.
mc_mergify_stuck_pass() {
  local proj="$1" slug="$2" writes="${3:-0}" stuck window alert_after
  local drafts rc=0 now num sha key green age slot line posted prev s floor oldest req
  stuck="${MC_MERGIFY_STUCK_SECS:-}"; window="${MC_MERGIFY_REFRESH_WINDOW_SECS:-}"; alert_after="${MC_MERGIFY_STUCK_ALERT_SECS:-}"
  case "$stuck" in ''|*[!0-9]*) stuck=300 ;; esac
  case "$window" in ''|*[!0-9]*) window=3600 ;; esac
  case "$alert_after" in ''|*[!0-9]*) alert_after=600 ;; esac
  # BH-1887: a window shorter than the conductor tick refreshes every tick and
  # never finds the previous slot's line, so the alert could never fire. 1..tick-1
  # reads as the tick: MC_TICK_SECS when it is longer, else 300, the */5 cadence
  # of cron/lanes/410-merge-conductor.cron. 0 keeps its meaning (one per head).
  floor=0; command -v tick_secs_for >/dev/null 2>&1 && floor=$(tick_secs_for "$proj")
  case "$floor" in ''|*[!0-9]*) floor=0 ;; esac
  [ "$floor" -ge 300 ] || floor=300
  [ "$window" -gt 0 ] && [ "$window" -lt "$floor" ] && window=$floor
  [ "$stuck" -gt 0 ] || return 0
  mc_rest_var drafts _gh_rest_list "$slug" pulls 1000 \
    "select((.head.ref // \"\") | startswith(\"$MC_MERGIFY_BATCH_PREFIX\")) | \"\\(.number) \\(.head.sha)\"" \
    -f state=open || rc=$?
  if [ "$rc" != 0 ]; then
    mc_log "$slug MERGIFY_REFRESH: open-PR list UNVERIFIABLE (HTTP $(mc_rest_status)) — no batch draft is refreshed this tick"
    return 0
  fi
  drafts=$(jq -r '.[]?' <<<"$drafts" 2>/dev/null) || {
    mc_log "$slug MERGIFY_REFRESH: open-PR list UNVERIFIABLE (unreadable body) — no batch draft is refreshed this tick"; return 0; }
  # BH-1887: only the oldest open batch draft can be "stuck"; the ones behind it
  # wait on it by design (merge_queue.max_parallel_checks).
  oldest=$(awk 'NF >= 2 { print $1 }' <<<"$drafts" | sort -n | head -1)
  [ -n "$oldest" ] || return 0
  # BH-1887: the names the queue waits on, read once per pass (policy cache).
  rc=0; req=$(mc_mergify_required_checks "$slug") || rc=$?
  if [ "$rc" != 0 ]; then
    mc_log "$slug MERGIFY_REFRESH: .mergify.yml UNVERIFIABLE (HTTP $(mc_rest_status)) — no batch draft is refreshed this tick"
    return 0
  fi
  now=$(mc_now)
  while read -r num sha; do
    [ -n "${num:-}" ] && [ -n "${sha:-}" ] || continue
    key="$slug#$num"
    rc=0; green=$(mc_mergify_batch_green "$slug" "$sha" "$req") || rc=$?
    case "$rc" in
      0) ;;
      1) # pending, red, or nothing yet: Mergify is not waiting on a missed event
         [ -n "$green" ] && mc_log "$key MERGIFY_REFRESH: batch draft ${sha:0:8} has no run for required check(s) $green — not refreshed"
         continue ;;
      *) mc_log "$key MERGIFY_REFRESH: check runs of batch draft ${sha:0:8} UNVERIFIABLE (HTTP $(mc_rest_status)) — not refreshed; the next tick asks again"
         continue ;;
    esac
    age=$((now - green))
    [ "$age" -ge "$stuck" ] || continue
    slot=0; [ "$window" -gt 0 ] && slot=$(( (age - stuck) / window ))
    line="mergifyrefresh $key $sha $green $slot"
    posted="mergifyposted $key $sha $green $slot"
    # Refresh attempted before (this window or the one before it) and STILL
    # here; `prev=2` when one of those attempts was actually posted.
    prev=0
    for s in "$slot" $((slot - 1)); do
      [ "$s" -ge 0 ] || continue
      mc_attempt_has "mergifyrefresh $key $sha $green $s" || continue
      [ "$prev" = 0 ] && prev=1
      mc_attempt_has "mergifyposted $key $sha $green $s" && { prev=2; break; }
    done
    if [ "$prev" != 0 ] && [ "$num" = "$oldest" ] && [ "$age" -ge $((stuck + alert_after)) ] \
       && ! mc_attempt_has "mergifystuckalert $key $((now / 86400))"; then
      mc_attempt_put "mergifystuckalert $key $((now / 86400))"
      if [ "$prev" = 2 ]; then
        mc_alert "$key" QUEUED "MERGIFY_BATCH_STUCK: batch draft ${sha:0:8} has been green for ${age}s and is still unmerged after @mergifyio refresh — look at the queue in the Mergify dashboard: https://github.com/$slug/pull/$num"
      else
        mc_alert "$key" QUEUED "MERGIFY_BATCH_STUCK: batch draft ${sha:0:8} has been green for ${age}s and is still unmerged; @mergifyio refresh could NOT be posted (POST repos/$slug/issues/$num/comments failed) — post it by hand on the draft and check the token can comment: https://github.com/$slug/pull/$num"
      fi
    fi
    mc_attempt_has "$posted" && continue
    if [ "$writes" != 1 ]; then
      mc_log "$key MERGIFY_REFRESH WOULD post @mergifyio refresh on batch draft ${sha:0:8} (green ${age}s >= MC_MERGIFY_STUCK_SECS=$stuck) — not in merge mode, nothing posted or recorded"
      continue
    fi
    mc_attempt_has "$line" || mc_attempt_put "$line"
    if mc_mergify_command "$slug" "$num" "@mergifyio refresh"; then
      mc_attempt_put "$posted"
      mc_log "$key MERGIFY_REFRESH posted @mergifyio refresh on batch draft ${sha:0:8}: every non-Mergify check green for ${age}s (>= MC_MERGIFY_STUCK_SECS=$stuck) and still unmerged (window slot $slot)"
    else
      mc_log "$key MERGIFY_REFRESH could NOT post @mergifyio refresh on batch draft ${sha:0:8} (POST repos/$slug/issues/$num/comments) — the next tick retries"
    fi
  done <<<"$drafts"
  return 0
}
