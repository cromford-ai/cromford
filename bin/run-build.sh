#!/bin/bash
# Staged build pipeline: PLAN (Fable) -> EXECUTE (Opus + subagent fan-out) -> REVIEW (Fable) -> fix round -> PR.
# usage: run-build.sh <project> <ticket-id> <ticket-key>
# Invoked by the triage session when it finds a buildable ticket. Tier-1 auto-merges (double gate); tier-2 merges via the merge sweep (migration-gated PRs via the orchestrator's judged apply).
#
# gh-rest: no-graphql
#
set -uo pipefail
# A build is not the lane that launched it (BH-2303): a triage or responder
# session that starts this script must not hand its AGENT_CALL_LANE down, or
# the build's calls would be capped by, and stamped to, that lane.
unset AGENT_CALL_LANE
# A launching lane's lane_env_apply-exported caps (blocked-resolver's rebuild) are not
# fly-pool's env fallback; box-wide env/global.env is re-sourced below and still applies.
unset LLM_LANE_ENABLED LLM_RUNNER_ALLOWED LLM_USD_CAP_DAY "${!LLM_RUNNER_ALLOWED_@}"
PROJECT="${1:?project}"; TICKET="${2:?ticket-id}"; KEY="${3:?ticket-key}"
# >>> inherited fd guard
# A LAUNCHER'S LOCK IS NOT THIS BUILD'S TO HOLD. bash `exec N>file` sets no
# FD_CLOEXEC, so a tick or a shard that flocked something and then launched us
# hands the descriptor to this whole process tree — and a build lives for hours,
# which turns that launcher's dedupe lock into a queue nobody asked for
# (bin/run-triage.sh's per-project tick lock on fd 9, bin/triage-shard.sh's
# per-key lock on fd 8). Closed here, before this script opens any lock of its
# own, so no future launcher has to remember: 7, 8 and 9 are exactly the three
# this script reopens for itself (the per-key dedupe lock, and build-slot-N for
# BUILD_SLOTS>=1 — which is also why this block must stay OUTSIDE the
# `# >>> build slots` region below). `exec N>&-` on a descriptor that was never
# open is a silent no-op, so a build from cron or the Fly pool is unchanged.
exec 9>&- 8>&- 7>&-
# <<< inherited fd guard
# Both overridable so this pipeline can be DRIVEN against a scratch tree — the
# same change bin/review-prs.sh and bin/merge-sweep.sh took for the same reason
# (docs/DB-COORDINATION-SPEC.md, phase 4). Cron and the fly runner set neither,
# so production resolves to exactly the paths it always has.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
REPO="${REPOS_ROOT:-/root/repos}/$PROJECT"
BUILD="$HARNESS/builds/$PROJECT-$KEY-$(date -u +%Y%m%d%H%M)"
# The context gate's one re-exec on a freshly synced harness (bin/lib/rb/gates.sh
# `# >>> context gate`) lands back here: keep the first pass's build dir so
# nothing is orphaned, remember this IS the second pass, and drop both from the
# environment so no child (a stacked build, a resume) inherits them.
# >>> ctx reexec
RB_CTX_REEXEC_DONE="${RB_CTX_REEXEC:-}"
[ -n "${RB_CTX_REEXEC_BUILD:-}" ] && [ -d "$RB_CTX_REEXEC_BUILD" ] && BUILD="$RB_CTX_REEXEC_BUILD"
unset RB_CTX_REEXEC RB_CTX_REEXEC_BUILD
# <<< ctx reexec
# Checkpoint-resume (2026-08-18, graph-engineering review): RESUME_BUILD=<dir>
# re-enters a died-mid-flight build. The artifacts ARE the checkpoints — a
# valid plan.md skips PLAN, commits on the branch skip EXECUTE, an APPROVE
# tail on review.md skips REVIEW, and so on — each stage below guards on its
# own artifact, so a fresh dir runs everything and a resumed dir re-derives
# nothing. (TK-120 was hand-resurrected three times in one day; never again.)
if [ -n "${RESUME_BUILD:-}" ]; then
  # F1 (docs/RUN-BUILD-GRAPH.md): the dir we were told to re-enter IS $BUILD, so
  # there is nowhere to write a RESULT and no job row to close — an ALERTS line
  # is the only owner this stop can have. Without it the resume disappears into
  # the launcher's own log, which reads exactly like a resume that never ran.
  [ -d "$RESUME_BUILD" ] || {
    echo "RESUME_BUILD $RESUME_BUILD does not exist"
    mkdir -p "$HARNESS/logs" 2>/dev/null
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT/$KEY] resume abandoned: RESUME_BUILD $RESUME_BUILD no longer exists — nothing to re-enter and no RESULT can be written" >> "$HARNESS/logs/ALERTS.log"
    exit 2; }
  BUILD="$RESUME_BUILD"
  # A stale terminal RESULT would double-report; a stale COMMENTED (the sweep
  # marks deferred verdicts too) would make the sweep SKIP the real verdict
  # this resume produces — the close-out would be silently lost.
  # The reconciler's markers are per-DIR and terminal (bin/pr-url-reconcile.sh),
  # so a resumed build that reaches a new PR_CREATE_FAILED would be skipped by a
  # marker its previous life earned. They go with the stale RESULT (BH-848).
  # EVERY marker the reconciler writes, not the two it wrote first: a third one
  # (.pr-url-reconcile-mislinked, and the page's own memory beside it) is just as
  # terminal, and leaving it here would be the same bug wearing a new file name.
  rm -f "$BUILD/RESULT" "$BUILD/COMMENTED" "$BUILD/.pr-url-reconciled" \
        "$BUILD/.pr-url-reconcile-alerted" "$BUILD/.pr-url-reconcile-mislinked" \
        "$BUILD/.pr-url-reconcile-mislink-alerted" "$BUILD/.pr-url-reconcile-restacked" \
        "$BUILD/.pr-url-reconcile-restack-tries" "$BUILD/.pr-url-reconcile-restack-gaveup"
  # A day-cap deferral (BH-4489) is the reason this build is being resumed, not
  # a verdict about it: left in place, CC() would defer the resume on its first
  # call forever.
  rm -f "$BUILD/BUDGET_DEFER"
fi
ALERTS="$HARNESS/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# >>> result pr url ratchet
# PR_CREATED IS A CLAIM THAT A PR EXISTS, and the whole fleet acts on it:
# bin/board-closeout.sh:56 moves the ticket to `review` on `PR_CREATED http*`,
# bin/merge-queue.sh, bin/lib/merge-conductor-lib.sh, bin/rebase-train.sh,
# bin/deploy-train.sh and bin/fly-pool.sh all go looking for the URL on the line.
# On 2026-09-17 a stacked child (project-5 job build-project-5-TK-1664-…) wrote
#   PR_CREATED  | STACKED on ticket/TK-1663 (parent PR not resolved)
# because its `gh pr create` had 422'd on a parent branch that was deleted
# mid-build — so every one of those readers hunted a PR nobody ever opened.
#
# So the WORD is derived from the line, not from the caller's optimism: a
# PR_CREATED without an `https://` on it cannot be written, and the file gets
# PR_CREATE_FAILED instead. That prefix matches none of the readers above (they
# need `PR_CREATED ` with its trailing space, or the glob `PR_CREATED*` in
# _job_finish, which the D in FAILED defeats), so the build lands on `failed`
# and the escalation is the truth. Every other RESULT kind passes through
# byte-for-byte — including `PR_MERGED` (see the plan's ASSUMPTIONS) and a
# legitimate `PR_CREATED <url> | QUEUED: …`.
#
# The rejected line's NOTES are kept for the reader, but its `PR_CREATED` token
# is not echoed back: the results-sweep prompts read this file with an LLM, and
# a rewritten line that still contains the word would re-introduce exactly the
# ambiguity the ratchet exists to remove.
#
# AND THE FAILED LINE CARRIES NO PULL URL AT ALL (BH-848). The notes folded in
# here are the caller's, and for a stacked child they read
#   STACKED on ticket/bh-776 (https://github.com/example-org/cromford/pull/803)
# — the PARENT's PR. Every multi-line reader of a pool record used to grep the
# FIRST url on the file, so that parent was published as this record's `PR:` and
# the merge sweep went off and evaluated somebody else's PR (BH-776 -> #803,
# BH-550 -> #754). A missing link is a gap; a mislink looks answered. So the URL
# is rewritten to `owner/repo PR N` — still readable by a human, matched by
# nothing that hunts for a link. The success line (`PR_CREATED <url> | STACKED on
# … (<parent url>)`) is untouched: there the first url IS this record's own.
_RESULT_NO_PULL_URL='s#https://github\.com/([^/ ]+/[^/ ]+)/pull/([0-9]+)#\1 PR \2#g'
RESULT() {
  local line="$*" note
  case "$line" in
    "PR_CREATED https://"*) : ;;
    PR_CREATED*)
      # Redacted BEFORE the 120-char fold: truncating first lands the cut inside
      # the URL, which leaves the reader a dangling `…/pull/` and tells them
      # nothing about which PR the parent was.
      note=$(printf '%s' "${line#PR_CREATED}" | sed -E "$_RESULT_NO_PULL_URL")
      line="PR_CREATE_FAILED: ${PR_CREATE_ERR:-gh pr create produced no url} — refused a url-less create claim carrying '$(printf '%.120s' "$note")'"
      # Again over the whole line, because PR_CREATE_ERR is gh's words and gh
      # puts URLs in them.
      line=$(printf '%s' "$line" | sed -E "$_RESULT_NO_PULL_URL") ;;
  esac
  echo "$line" > "$BUILD/RESULT"; echo "$line"
  if command -v hp_file_requests >/dev/null 2>&1; then
    local _hpf
    for _hpf in review.md execute-run.txt; do
      [ -r "$BUILD/$_hpf" ] && hp_file_requests "$PROJECT" "$KEY" "$BUILD/$_hpf" "build:${_hpf%%.*}" >> "$BUILD/pipeline.log" 2>&1
    done
  fi
  return 0
}
# <<< result pr url ratchet
# >>> hub-probe request seam
# BH-3434.4: once the terminal line is written, file every `HUB_PROBE:` line the
# reviewer (review.md) or the builder (execute-run.txt) wrote, through the jobs
# API. Fail-open: no lib, no client or a refused POST only logs to pipeline.log.
[ -r "$HARNESS/bin/lib/hub-probes/request.sh" ] && . "$HARNESS/bin/lib/hub-probes/request.sh" 2>/dev/null || true
# <<< hub-probe request seam

# >>> stage modules
# The pipeline is being split into stage modules under bin/lib/rb/ (BH-478).
# Each module is a function library and nothing calls into one yet, so sourcing
# them changes nothing about what runs below. The list is the single source of
# truth for module order; the test helper reads it off this line, so it stays a
# literal. A module missing on a box means the box's bin/ arrived in two pieces,
# and a half-synced pipeline must not build: one ALERTS line and exit 2, the
# same owner shape as the resume guard above, because no lock, claim, job row or
# worktree exists yet — there is nothing to release, so exiting IS the whole
# story. run-triage.sh's rt/ seam refuses the same condition, and writes it as a
# `[ -r ] && . && continue` chain falling through to exit 1; the shape here is a
# guard clause and the code is 2 because that is what this driver's own stops
# before it owns anything look like (the resume guard above, same file).
# A fresh run writes no RESULT (there is no dir anyone is watching);
# a RESUMED run already has its dir, and the jobs watchdog's resume pass
# (bin/lib/resume-dead.sh) re-enters any
# dir with no RESULT in it, so that path writes BUILD_DEFERRED first and the
# resumer refunds the attempt instead of looping the build to death.
RB_MODULES="gates plan execute spec review pr result"
for _m in $RB_MODULES; do
  [ -r "$HARNESS/bin/lib/rb/$_m.sh" ] || {
    mkdir -p "$HARNESS/logs" 2>/dev/null
    echo "$(STAMP) [$PROJECT/$KEY] stage module bin/lib/rb/$_m.sh is missing on $(hostname) — the box's bin/ is half-synced; nothing was built" >> "$ALERTS"
    [ -n "${RESUME_BUILD:-}" ] && RESULT "BUILD_DEFERRED stage module bin/lib/rb/$_m.sh missing on $(hostname)"
    exit 2; }
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/rb/$_m.sh"
done
# <<< stage modules
# The ONE verdict reader (BH-1625). Every review verdict this pipeline acts on
# — each lens's, the head-bound re-review's, the ledger word — goes through
# verdict_parse / verdict_is. A box whose bin/ lacks it reads every verdict as
# unknown, which is BLOCK / none everywhere below: fail closed, never APPROVE.
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/verdict-parse.sh" 2>/dev/null || true
command -v verdict_prime >/dev/null 2>&1 && verdict_prime || true
# BH-5003: bn_take/bn_mark/bn_used for the plan stage's carried-note block (a
# build note as a ledger row, so a watcher-box build sees it). Fail-open: a box
# without it reads the relay and hub files exactly as before.
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/build-note-db.sh" 2>/dev/null || true

# >>> plan blocked marker
# A plan is parked only when its FIRST LINE OPENS with the marker the planner
# prompts ask for ("write BLOCKED / BLOCKED-NEEDS-CLARIFICATION as the first
# line"), after any markdown heading/bold decoration (`# BLOCKED:`, `**BLOCKED**`,
# `# **BLOCKED** on hold`), and the word ENDS there — any non-word character or
# end of line may follow it, but never `_` or another letter/digit. A ticket title
# that merely contains the word (BLOCKED_HUMAN, REVIEW_BLOCKED, PLAN_BLOCKED gate
# …) is not a parked plan — BH-387: the unanchored `grep -q BLOCKED` refused four
# complete plans in two days, including two for the ticket that reported it.
PLAN_IS_BLOCKED() { # PLAN_IS_BLOCKED <plan.md>  -> 0 when line 1 declares the plan parked
  [ -s "$1" ] || return 1
  head -1 "$1" | grep -Eq '^[[:space:]]*([#*]+[[:space:]]*)*(PLAN[_ -])?BLOCKED([^_[:alnum:]]|$)'
}
# <<< plan blocked marker
rb_gate_prelude

# Per-ticket DEDUPE (2026-07-23): the same KEY must never build twice at once
# (duplicate queue pickups). `flock -n`, never a wait — two ticks racing one key
# is a duplicate to drop, not a second build to schedule. This is also what makes
# the per-key worktree below exclusive when BUILD_SLOTS is unlimited.
#
# A SAME-BOX FAST PATH, NOT THE SOURCE OF TRUTH (W2-B, 2026-09-14). This flock
# sees one machine, and the same ticket key can be offered to any builder in the
# pool — one pool machine had 277 of these files and not one of them could have
# stopped a second machine building the same ticket. The fleet-wide dedupe is
# the LEDGER claim below (job_open, then the conditional queue-row claim), and
# when those two disagree the ledger wins. This stays because it is free and it
# is the cheapest possible answer to a duplicate pickup on THIS box — and
# because it is still what makes the per-key worktree exclusive.
exec 7>"$HARNESS/locks/build-key-$PROJECT-$KEY.lock"
flock -n 7 || { RESULT "BUILD_DEFERRED $KEY already building"; exit 3; }

set -a; . "$HENV/global.env"; [ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"; set +a
rb_gate_claim_and_workspace
rb_plan
trap 'CKPT_ON_EXIT; declare -F PO_FLUSH_ON_EXIT >/dev/null && PO_FLUSH_ON_EXIT; rm -f "$HARNESS/state/claims/$PROJECT/$KEY"; _job_finish' EXIT
rb_gate_overlap
# >>> route shadow (P4; tests/route-rules.p4-test.sh drives this block)
# LOG ONLY. The last point before EXECUTE, and the first where a plan exists:
# EXECUTE_MODEL was resolved in the prelude, before there was a plan to read.
# bin/lib/route-rules.sh records what the plan-driven rules WOULD pick beside
# what this build runs on ($BUILD/route-shadow.json, a pipeline.log line, a
# route_shadow row). Its own process, argv in, nothing out, fds 6-9 closed
# here and every other inherited fd above 2 closed by the script on entry, so
# it cannot change a variable, hold a lock or alter the exit path of this
# build. It does add wall time: up to 30 s (the ceiling), usually well under a
# second of worker reads. docs/ROUTE-RULES.md.
[ -r "$HARNESS/bin/lib/route-rules.sh" ] && HARNESS="$HARNESS" timeout 30 bash "$HARNESS/bin/lib/route-rules.sh" shadow \
  "$PROJECT" "$KEY" "$BUILD" "${EXECUTE_MODEL:-}" "${REVIEW_MODEL:-}" "${JOB_ID:-}" </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- || true
# <<< route shadow
rb_execute
rb_spec_artifact
rb_execute_gates
rb_review
rb_pr
rb_settle
# >>> inbuild lead review (BH-5023; tests/medium-tier-inbuild-review.bh-5023-test.sh drives this block)
# An APPROVE'd build with a PR asks bin/inbuild-lead-review.sh for the lead-grade
# review of the head it settled on; the script acts only on a medium risk tier
# under enforce. Before close-out, so a tier-1 merge sees the verdict. Its own
# process, fds 6-9 closed, `|| true`: it cannot change a variable, hold a lock or
# alter the exit path. Up to LEAD_REVIEW_DEADLINE_S + 120 s of wall time.
if [ -n "${PR_URL:-}" ] && [ "${VERDICT_WORD:-}" = APPROVE ] && [ -x "$HARNESS/bin/inbuild-lead-review.sh" ] \
   && [[ "$PR_URL" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
  _ILR_DL="${LEAD_REVIEW_DEADLINE_S:-3600}"; case "$_ILR_DL" in ''|*[!0-9]*) _ILR_DL=3600 ;; esac
  KEY="$KEY" HARNESS="$HARNESS" timeout -k 30 "$((_ILR_DL + 120))" "$HARNESS/bin/inbuild-lead-review.sh" "$PROJECT" "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[2]}" "$(cat "$BUILD/reviewed-sha" 2>/dev/null || cat "$BUILD/review-head" 2>/dev/null)" "$BUILD" \
    </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- || true
fi
# <<< inbuild lead review
rb_close_out
