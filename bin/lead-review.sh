#!/bin/bash
# bin/lead-review.sh tick | one <request-id> — BH-1950 (BH-1525.2): the lead review job lane on the
# build boxes. Every 15 minutes (cron/lanes/710-lead-review.cron, a backstop;
# rung by lead-review-enqueue and a nudge through the wakes doorbell,
# bin/lib/lead-chain-wake.sh) it reads two inputs, keeps what is for
# repos this box owns (fleet.conf + bin/box-for.sh), and reviews every eligible
# item as soon as a slot is free, until LEAD_REVIEW_DEADLINE_S closes STARTS.
# There is no per-tick start cap.
#
# THE WORKLIST (BH-4956), first, when LEAD_REVIEW_WORKLIST=1 (the default
# since BH-5878; see the AUTO_REPOS block). For each
# LEAD_REVIEW_AUTO_REPOS repo (the
# lead-review-land knob, read in a subshell) this box owns, pr_needs_review
# (GET /api/pr-state/needs-review, bin/lib/lead-worklist.sh lw_items) lists the
# heads the gate facts say need a lead review, in the route's order (nudged,
# hotfix, oldest approval). rc 1 for a repo is one log line, and nothing starts
# from that repo's list. An item is claimed with lr_start (POST
# /api/lead-reviews/start), which creates or takes its request row. A request
# row the list read (below) for the same (repo, pr, head) is worked in the
# item's place, by its id. Participant mode reads no worklist (/start refuses
# the participant header).
# Before each claim: the per-key lock locks/lead-review-<key>.lock (flock -n,
# a dedupe), for an item with no request row the counted attempts on the head
# (3 = no claim; unreadable = no claim this tick), and the per-PR
# tripwire LEAD_REVIEW_MAX_PER_PR_DAY (state/lead-review/started.tsv, one line
# a review the model answered; a trip is one lane-alert warn a PR a day). A start
# also needs the settings rows: lead_review.concurrency (fleet-wide, counted
# from the running lead_review jobs; no row = the box cap) and
# lead_review.daily_spend_usd (no row = no cap; at the cap one lane-alert a
# day; unreadable = no start). On a claim the lane writes the gate fact
# reviewing_sha. A COUNTED failure (live head unreadable, checkout failed, the
# artifact or result post failed, a stale claim taken over) writes the attempt
# lead-review-<n>; the third posts outcome=failed detail="attempts-exhausted:
# <reason>" and the gate fact review_failed_sha. Not counted: agent-call rc
# 74..79, a rate limit (the model's, or GitHub's on the live-head read),
# superseded, the caps. A worker that ends and leaves its row `running` on
# purpose (not counted, or counted already) writes the release marker
# pr_attempts lead-review-free, so the next takeover of that claim is not
# counted (lw_release, lw_released). /start answering terminal done
# is `paid` (no model call); a head carrying the patch of an earlier lead
# MERGE is `replayed` (lw_replay: no model call, reviewer_model lead-replay).
# An earlier BLOCK is never replayed here: it leaves its head only through the
# enqueue's BH-3930 rebound replay.
#
# THE GATES (BH-5873). A worklist item with no request row passes the gate
# loader bin/lib/lead-gates.sh (gates in bin/lib/lead-gates.d/, filename order)
# before its worker starts: after the slot, spend and /tmp checks, lg_run. rc 0
# starts it with the gates' LG_MODE (review_one's third argument; nothing
# reads it yet), 10 or 12 is skipped=, 11 or any other rc is held= in the
# summary (never deferred=, so a hold forces no rerun). lg_tick runs once a
# tick per worklist repo before its read; lg_job_fields goes into the job's meta
# (a failure = no job); lg_post runs after lr_start claimed the row. Gate 15
# skips a head that carries a Lead-Lane: commit, with the enqueue's warn. The
# lib missing = one log line and no worklist read; request rows still run.
#
# IN PARALLEL (BH-5284). Up to LEAD_REVIEW_CONCURRENCY reviews (default 10,
# capped per box: LEAD_REVIEW_BOX_MAX, else free memory and /tmp at
# LEAD_REVIEW_WORKER_TMP_MB a worker, the review-pool reads it by prefix) run at once,
# each in a worker of bin/lib/review-pool.sh that holds its own job, claim,
# heartbeat and scratch worktree. Claims are still made one at a time in queue
# order (the worker's gate is its claim). No new worker starts past the
# deadline, over the lane's LLM_USD_CAP_DAY, or with /tmp under
# LEAD_REVIEW_TMP_MIN_MB (one alert per episode); a running one finishes and
# records, and the tick waits for it. Each worker's review budget is
# LEAD_REVIEW_DEADLINE_S from its own start. The summary adds
# `concurrency=K running=N started=M` (N = still running when starts closed).
# The tick releases its lock when starts close, BEFORE that wait (BH-6984), so
# a later tick starts more reviews while these run: it counts every live worker
# on the box (state/lead-review/pool, rpool_box_running) against K and the
# fleet-wide row. The per-key lock and the job_open claim keep one request to
# one worker. BH-7792: a later tick on the SAME box gets the running worker's
# own job back from job_open (a same-box resume), so a loser of the per-key
# lock never closes a job the holder wrote to locks/lead-review-<key>.job: it
# closed it before, /start then read the request's job as not live, and a
# second box rebound the request while the first was still in its paid call.
#
# THE LEAD CHAIN (BH-4057, BH-5317). A worker whose terminal result (done, or
# outcome=failed) the jobs worker accepted rings lead-land on its way out
# (lr_ring_land in its exit trap, before the tick collects it): one
# POST /api/wakes/lane per (pr, head), deduped there, so the hub promotes the
# verdict in seconds instead of on its */15 cron. No ring for a superseded
# row, a skip, a non-terminal failure (rc 74..79, rate limited, an unreadable
# head), a failed result post, or a review whose rules pack could not run
# (`withheld`: the cron still lands it). The summary counts rings as rung=N.
# A tick that finds the lock held writes state/lead-review/rerun-owed; the
# holder, once its starts close and it unlocks, relaunches ONE tick for it
# however many were skipped, and once it ends, one when it left work deferred
# to its deadline.
# The chain is bounded by LEAD_REVIEW_RERUN_MAX (0 = off). Kill switch for the
# ring: flags/lead-chain-wake-off (the rerun is local and bounded).
#
# THE QUEUE (BH-5151), second. The tick reads EVERY page of the list (lr_list_all,
# following next_after) up to LEAD_REVIEW_MAX_PAGES pages; a cap hit, a failed
# page or a worker without the cursor is one log line, and the summary's
# total=/prs= then carry a `+` (a floor, not the D1 count). The owned rows are
# worked hotfix first (the PR carries hotfix_label, read from the repo's open-PR
# list, bin/lib/pr-snapshot.sh), then by `priority` (higher first, set with
# bin/lead-verdict.sh request --priority), then oldest. Before any review, a
# `requested` or `running` row whose PR is closed or whose head moved (the
# open-PR list says so AND one live pulls/<n> read confirms it) is superseded
# with no model call (a running row under a live job refuses the claim, and is
# skipped). If the list read fails, the tick still works the worklist.
# Without that lib the order is priority, then oldest, and dead
# rows fall to review_one's own live read. A job_open failure or a 503 on a
# claim is one log line and the END of the tick (summary `stopped=worker
# left=<n>`), never one skip per remaining row.
#
# Per request:
#
#   model_for lead.review   no route (rc 75) = stop before anything is written,
#                           so the request stays `requested` (a claim would
#                           move it to running with nobody able to finish it)
#   job_open lr-<pr>-<sha12> lane lead-review   rc 9 = another box has it: skip,
#                           never wait. The lane arg is what lets the watchdog
#                           find the seeded lead-review/*/* retry policy.
#   lr_post /<id>/claim, job_beat_start
#   live head (gh_rest)     closed or moved = post outcome=superseded (detail
#                           `pr closed` / `head moved to <sha12>`), no model call;
#                           unreadable = job failed, request left for next tick
#   exact head in a scratch worktree under tmp/, removed on every exit but a
#   SIGKILL (then tmp/lead-review-* is the operator's to clear)
#   host suite              the repo CLAUDE.md Verification Contract command
#                           (lr_verify_cmd, batch-resolve's reader); true rc,
#                           unpiped; none declared = "no host suite declared".
#                           LEAD_REVIEW_HOST_SUITE (settings row): the default
#                           skip-if-ci-green skips it when every check the
#                           base branch's .mergify.yml queue_conditions require ran
#                           green on THIS sha and no run there is pending or
#                           failed (one REST read, lr_ci_green) AND the diff
#                           touches nothing that decides what CI runs
#                           (lr_ci_cfg_touched); any unknown runs it.
#                           `always` = run it, `off` = never, fleet-wide
#                           (logged per review). A skip or off still says in
#                           the prompt that no test ran on this box.
#   paid already (BH-2202)  the job's lead_review_report artifact first (BH-2624):
#                           a body whose header names this repo, PR and full sha
#                           = replay it, detail.empty = billed with no verdict.
#                           Then the disk: state/lead-reviews/<key>.md with that
#                           header = replay it (finish_done), no checkout, no
#                           suite, no agent call; <key>.empty = billed with no
#                           verdict: outcome=failed detail=empty, no agent call.
#                           Either way a request is paid for once. A report
#                           whose `- pr body:` line names another PR body is
#                           not replayed (BH-5888): the body change is reviewed,
#                           and its paid call's guard key names the new body
#                           (`~body<D>`), so the K=1 lead-head guard lets it
#                           through once. With no body change seen, the key is
#                           the plain per-head key (BH-3930).
#   fresh conflict (BH-7816) right after the fetch: a lane-requested head that
#                           conflicts with origin/<base> is superseded, no agent
#                           call (bin/lib/lead-review/fresh-conflict.sh).
#   console qa (BH-5909)    LEAD_REVIEW_CONSOLE_QA_GATE=1 (default 0), right after
#                           the fetch and before any replay: a harness head that
#                           changes console-ui/src/ with no QA: PASS comment naming
#                           it (bin/lib/console-qa-gate.sh) is a BLOCK report with
#                           reviewer model console-qa-gate and NO agent call. An
#                           unreadable thread is not counted; the request waits.
#   rules pack (BH-3546)    bin/rules-pack.sh on the checkout, before the suite,
#                           only for the harness repo (fleet.conf cromford).
#                           rc 1 = a BLOCK report with reviewer model rules-pack
#                           and NO agent call; anything else is one line in the
#                           prompt and the header: clean, could not run (rc N),
#                           not installed on this box, not applicable to <repo>,
#                           or skipped (CI green on <sha12>): unless
#                           LEAD_REVIEW_HOST_SUITE=always, the lead does not
#                           re-run it when CI's lint job (which runs this pack)
#                           and its determinism job both passed on THIS sha AND
#                           the diff touches none of the pack's own inputs
#                           (lr_rp_inputs, derived from the box's trusted copy:
#                           CI runs the PR's pack, which a PR can weaken) nor
#                           anything that decides what CI runs (lr_ci_cfg_touched);
#                           that is clean, never red or could-not-run, and any
#                           unknown runs the pack as before
#   ticket thread           the PR body's first `Closes #<n>` for this repo, else
#                           its first `Refs #<n>` line (a partial build): the
#                           issue + its first 100 comments, cut in the middle at
#                           LEAD_REVIEW_THREAD_MAX_BYTES; a failed read says so
#   bin/agent-call.sh       prompts/lead-review.md + prompts/lead-review-checklist.md
#                           (Checklist-Version on line 1, `- checklist: v<N>` in
#                           the report) + PR + ticket thread + scope notes + prior
#                           verdict + rules pack + suite + diff. rc 74..79 = nothing billed:
#                           job failed, the claim's heartbeat stopped and the claim
#                           released to requested (lr_release, BH-7792; a refused
#                           release leaves it running), the release marker written,
#                           nothing else written. BH-7792: the same release runs
#                           BEFORE the rules pack when a read-only peek of the
#                           lead-head guard key says it is spent. An answer
#                           with no findings block (lr_has_findings) is replaced
#                           by the last message of its session transcript that
#                           has findings and a verdict (lr_pick_review, via
#                           <out>.session). An answer still with no findings, or
#                           whose last non-blank line is not exactly
#                           `VERDICT: <word>` (lr_verdict), gets ONE more call,
#                           then <key>.empty is written, put as an artifact
#                           with detail {empty:true,path,model}, and
#                           outcome=failed detail=empty. BH-8081: a spent head
#                           whose ~noverdict key is paid gets ONE more call on
#                           ~unread (no retry); unreadable again = one alert
#                           (bin/lib/lead-unread.sh, lu_alert).
#   delta mode (BH-5294)    scope_notes carrying `lead-delta:<G>` (set by
#                           bin/lead-review-enqueue.sh) puts G's report on this
#                           box, the inter-diff and the conflict resolutions
#                           (bin/lib/lead-delta.sh ld_build) where the diff goes,
#                           with the SAME model_for lead.review route, and adds
#                           `- review mode: delta from <G>` to the report. Any
#                           unknown is the full diff, logged. A
#                           `protected:<p1>,<p2>` token (BH-5582) names one line
#                           per file under DELTA REVIEW for full scrutiny; a
#                           token that does not parse is a full review.
#   re-review (BH-6391)     scope_notes carrying `lead-prev:<G> word:<W> ...`
#                           (bin/lib/lead-prev.sh) adds `## Re-review` between
#                           `## Rules pack` and `## Host suite`: G, its word, the
#                           own commits, own files and main files since G, and
#                           G's report outside delta mode. After a BLOCK on a
#                           head whose G was MERGE or MERGE-WITH-NOTES,
#                           lpv_downgrade rewrites each `- [BLOCK] path:line`
#                           on a file of H, on a line unchanged since G, with
#                           no `main-cause:` naming a main file or `own-cause:`
#                           naming an own file of the delta, to `- [NOTE
#                           unchanged-since <G12>]`; with no BLOCK line left the
#                           verdict is MERGE-WITH-NOTES, and the report adds
#                           `- re-review: from <G12> (<W>); <k> BLOCK finding(s)
#                           ...`. Git that cannot answer keeps the BLOCK, logged.
#   builder review (BH-5355) not in delta mode, with LEAD_REVIEW_BUILDS_ON_BUILDER
#                           on (default; settings row, read once a tick; any
#                           value but on|off is off, logged): the review-prs.sh
#                           review GitHub holds for this exact head
#                           (bin/lib/builder-review.sh br_fetch) goes in as
#                           `## Builder review (same head)` before the diff, and
#                           prompts/lead-review-builds-on.md after the checklist.
#                           Same model route, same full diff; the report adds
#                           `- review mode: builds on builder review <V> at <sha12>`.
#                           None, another sha, a failed read, the lib or the
#                           prompt missing = the full-review prompt, logged. Each
#                           agent call's cost row carries AGENT_CALL_ROW_NOTE
#                           lead-mode=build-on|full|delta|intent.
#   intent review (BH-6967) not in delta mode (no `lead-delta:`), scope_notes
#                           ENDING with `; review-tier:medium review-mode:intent`
#                           (set by bin/lead-review-enqueue.sh while the row
#                           risk_tier.medium_mode reads intent), and that row
#                           still reading intent at review time: the prompt is
#                           prompts/lead-review.md + prompts/lead-review.d/
#                           intent.md, with no checklist and no builder review,
#                           on the model of route review-intent. The report says
#                           `- review mode: intent (risk tier medium, route
#                           review-intent)` and `- checklist: none (intent
#                           review)`. No route, or no intent.md, is the full
#                           review on lead.review, logged.
#   report state/lead-reviews/<key>.md -> artifact (ref = that path, detail =
#   {body,path,verdict[,truncated]}, lr_detail; a truncated detail first pushes
#   the whole report to the job's transcripts as source lead_report through
#   bin/transcript-push.sh, fail-open) -> result done -> job done,
#   each only when the one before it succeeded (finish_done). A failed result
#   post leaves the job open; the watchdog's retry re-runs the tick under the
#   same job id, which replays the artifact's body, or the report on disk,
#   rather than calling again.
# `one <request-id>` (BH-5023) reviews that one request now, the same way; the
# in-build review (bin/inbuild-lead-review.sh) is its caller. See the block
# above the tick lock.
# FLY POOL (BH-8027). With lane_placement.lead-review.<project> = fly a tick
# queues that project's item as ONE pool row (bin/lib/lead-pool.sh) and runs
# nothing here; the pool machine runs `item` (block above the tick lock).
# HEARTBEAT (BH-5351). A claimed review re-stamps its claim's heartbeat_at
# (lr_beat_start, bin/lib/lead-reviews.sh) every stale_s/3 seconds, never under
# LR_BEAT_MIN_S (default 10), where stale_s is the settings row
# lead_review_claim_stale_s (fallback 900); the beat stops in cleanup. A claim
# that stops beating for stale_s is taken by the next claimer.
#
# PARTICIPANT MODE (BH-5351). With HARNESS_PARTICIPANT_TOKEN_FILE readable this
# machine is an enrolled participant: the tick starts with whoami (a failure is
# one line and no claim), every lead-reviews call carries its token, it takes
# the requests of every fleet.conf project it has a clone of under REPOS_ROOT
# (it is in no owner column), and a whoami `knobs` key named
# LEAD_REVIEW_CONCURRENCY or LEAD_REVIEW_DEADLINE_S with a positive-integer
# value replaces the lane's setting for this tick. Its
# reports carry `Reviewer: <name> (enrolled machine)` as line 1, above the title.
# Never runs on the hub. Kill switch: flags/lane-off-lead-review (both modes).
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=lead-review
MODE="${1:-}"; ONE_ID=""
case "$MODE" in
  tick) ;;
  one) ONE_ID="${2:-}"
       [[ "$ONE_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "usage: bin/lead-review.sh one <request-id>" >&2; exit 2; } ;;
  item) IT_P="${2:-}"; IT_F="${3:-}"; IT_M="${4:-full}"; IT_OUT="${5:-}"
        [[ "$IT_P" =~ ^[A-Za-z0-9._-]+$ && -r "$IT_F" && "$IT_M" =~ ^[a-z]+$ && -n "$IT_OUT" ]] \
          || { echo "usage: bin/lead-review.sh item <project> <item-file> <mode> <word-file>" >&2; exit 2; } ;;
  *) echo "usage: bin/lead-review.sh tick | one <request-id> | item <project> <item-file> <mode> <word-file>" >&2; exit 2 ;;
esac
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off lead-review.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lead-review
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review

LOG="$H/logs/lead-review.log"
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; lead-review tick skipped"; exit 0; }
if is_hub_box "$(local_box_name)"; then log "hub runs no agent work; lead-review tick skipped"; exit 0; fi

# jobs-client.sh exits its caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/lead-reviews.sh bin/lib/model-route.sh \
         bin/lib/verdict-parse.sh bin/lib/gh-rest.sh bin/lib/review-pool.sh bin/lib/lead-worklist.sh bin/box-for.sh \
         prompts/lead-review.md prompts/lead-review-checklist.md; do
  [ -r "$H/$f" ] || { log "missing $f; lead-review tick skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/lead-reviews.sh"; . "$H/bin/lib/model-route.sh"
  . "$H/bin/lib/verdict-parse.sh"; . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/review-pool.sh"
  . "$H/bin/lib/lead-worklist.sh"; }
LW_LOGFN=log
# The optional libs, one file each in bin/lib/lead-review/libs.d/, sourced here
# at top level in LC_ALL=C name order. A new optional lib is a new file there,
# named <yyyymmddhhmm>-<ticket-key>-<name>.sh, never a line in this file
# (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). No file = a broken
# checkout: the tick stops, as for the module dir below.
mapfile -t _lr_libs < <(for _lr_lib in "$H"/bin/lib/lead-review/libs.d/*.sh; do [ -f "$_lr_lib" ] && printf '%s\n' "$_lr_lib"; done | LC_ALL=C sort)
if [ "${#_lr_libs[@]}" = 0 ]; then
  log "bin/lib/lead-review/libs.d/ has no fragment; lead-review tick skipped"
  HARNESS="$H" "$H/bin/alert-line.sh" --id "lead-review-libs-$(hostname)" "LEAD REVIEW LIBS MISSING: bin/lib/lead-review/libs.d/ has no fragment on $(hostname); no lead review ran this tick" >/dev/null 2>&1 || true
  exit 0
fi
for _lr_lib in "${_lr_libs[@]}"; do
  # shellcheck source=/dev/null
  . "$H/bin/lib/lead-review/libs.d/${_lr_lib##*/}"
done
unset _lr_lib _lr_libs
# BH-5909: the console QA gate. With LEAD_REVIEW_CONSOLE_QA_GATE=1 a harness PR
# that changes console-ui/src/ and has no QA: PASS comment naming its head is a
# BLOCK with no model call (bin/lib/console-qa-gate.sh). Default 0: it goes on
# after bin/console-preview-deploy.sh has posted its first green QA. Anything
# but 1 is off. A missing lib with the gate on holds only the harness repo's
# console-ui/src/ heads (fail closed); every other head is reviewed as before.
CONSOLE_QA_GATE="${LEAD_REVIEW_CONSOLE_QA_GATE:-0}"
case "$CONSOLE_QA_GATE" in
  0|1) ;;
  *) log "LEAD_REVIEW_CONSOLE_QA_GATE='$CONSOLE_QA_GATE' is not 0|1; the console QA gate is off"; CONSOLE_QA_GATE=0 ;;
esac
[ "$CONSOLE_QA_GATE" = 1 ] && { . "$H/bin/lib/console-qa-gate.sh" 2>/dev/null || log "bin/lib/console-qa-gate.sh missing; console-ui heads of the harness repo are not reviewed this tick"; }
# The report names the checklist version it read, and never one it did not.
CK_VER=$(sed -n '1s/^Checklist-Version: *\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$H/prompts/lead-review-checklist.md")
[ -n "$CK_VER" ] || { log "checklist has no Checklist-Version line; reported as v?"; CK_VER="?"; }

# Participant mode (BH-5351, header): whoami first, then the machine's knobs.
PARTICIPANT=""; RVLINE=""
if [ -n "$(_lr_participant_tokf)" ]; then
  WHO=$(lr_whoami 2>&1) || { log "participant whoami failed ($(printf '%s' "$WHO" | tr '\n' ' ' | head -c 200)); tick skipped"; exit 0; }
  PARTICIPANT=$(jq -r '.name // empty' <<<"$WHO" 2>/dev/null)
  [ -n "$PARTICIPANT" ] || { log "participant whoami answered no name; tick skipped"; exit 0; }
  RVLINE="Reviewer: $PARTICIPANT (enrolled machine)"$'\n'
  taken=""
  for k in LEAD_REVIEW_CONCURRENCY LEAD_REVIEW_DEADLINE_S; do
    v=$(jq -r --arg k "$k" '.knobs[$k] // empty | tostring' <<<"$WHO" 2>/dev/null)
    case "$v" in ''|*[!0-9]*|0*) continue ;; esac
    export "$k=$v"; taken="$taken $k=$v"
  done
  log "participant mode as $PARTICIPANT${taken:+; knobs from the machine:$taken}"
fi

knob() { # knob <name> <value> <default> -> the value when it is a positive integer, else the default (logged; may be empty)
  case "$2" in ''|*[!0-9]*|0*) log "$1='$2' is not a positive integer; using ${3:-no value}"; printf '%s' "$3" ;; *) printf '%s' "$2" ;; esac
}
DEADLINE=$(knob LEAD_REVIEW_DEADLINE_S "${LEAD_REVIEW_DEADLINE_S:-3600}" 3600)
DIFF_MAX=$(knob LEAD_REVIEW_DIFF_MAX_BYTES "${LEAD_REVIEW_DIFF_MAX_BYTES:-400000}" 400000)
PAGES=$(knob LEAD_REVIEW_MAX_PAGES "${LEAD_REVIEW_MAX_PAGES:-20}" 20)
# BH-3546: required knob, so lane_env_apply always exports the registry default.
# Empty = the registry could not be read: no thread reads, and the prompt says so.
THREAD_MAX=$(knob LEAD_REVIEW_THREAD_MAX_BYTES "${LEAD_REVIEW_THREAD_MAX_BYTES:-}" "")
# BH-5284: reviews run at once (registry knob, settings row
# lane.lead-review.lead_review_concurrency), capped per box by rpool_init.
# 0 = no cap: every eligible review starts, bounded by the box guardrails.
if [ "${LEAD_REVIEW_CONCURRENCY:-}" = 0 ]; then CONC=0
else CONC=$(knob LEAD_REVIEW_CONCURRENCY "${LEAD_REVIEW_CONCURRENCY:-10}" 10); fi
# The host suite (registry knob, settings row lane.lead-review.lead_review_host_suite):
# skip-if-ci-green (default) | always | off. Read once per tick, so an unknown
# value is one log line, and it is `always`: unknown runs the suite.
HOST_SUITE="${LEAD_REVIEW_HOST_SUITE:-skip-if-ci-green}"
case "$HOST_SUITE" in
  skip-if-ci-green|always|off) ;;
  *) log "LEAD_REVIEW_HOST_SUITE='$HOST_SUITE' is not skip-if-ci-green|always|off; using always"; HOST_SUITE=always ;;
esac
# Build on the builder review (registry knob, settings row
# lane.lead-review.lead_review_builds_on_builder): on (default) | off. Read
# once per tick; an unknown value is one log line, and it is off.
BUILDS_ON="${LEAD_REVIEW_BUILDS_ON_BUILDER:-on}"
case "$BUILDS_ON" in
  on|off) ;;
  *) log "LEAD_REVIEW_BUILDS_ON_BUILDER='$BUILDS_ON' is not on|off; using off"; BUILDS_ON=off ;;
esac
REPOS="${REPOS_ROOT:-/root/repos}"

# lr_verify_cmd <CLAUDE.md> — the Verification Contract command, read by the awk
#   of bin/batch-resolve.sh's verify_cmd verbatim (the suite pins the parity).
#   Unlike verify_cmd there is NO `npm test` fallback: nothing declared is rc 1.
lr_verify_cmd() {
  local c
  [ -r "${1:-}" ] || return 1
  c=$(awk '
    /^##+[ \t]*[Vv]erification [Cc]ontract/ { sec=1; next }
    sec && /^## / { exit }
    sec && /^```/ { fence = 1 - fence; next }
    sec && fence && NF && $0 !~ /^[ \t]*#/ { print; exit }' "$1")
  c=$(printf '%s' "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$c" ] || return 1
  printf '%s' "$c"
}

# >>> lead ci green (BH-5630: bin/lead-review-enqueue.sh sources this block, so
# both lanes read "CI green on a head" through the one definition below)
# lr_ci_required <mergify-file> — the check names the repo's merge queue asks of
#   a PR: every `check-success = "<name>"` under a `queue_conditions:` block, one
#   per line, sorted. `lead-verdict` is left out: it is the status this very
#   review publishes, so it is never there before it. The caller hands it the
#   BASE branch's .mergify.yml, never the PR's own, so a PR cannot drop a name
#   to make its own skip fire. No file, or no name in it, is rc 1 (the caller
#   then runs the suite), and so is a file using a YAML anchor, alias, merge key
#   or `extends:`. A name under a nested `- or:` counts as required too:
#   that fails safe (the suite runs) and no repo uses `or:` today.
lr_ci_required() {
  local f="${1:-}" names
  [ -r "$f" ] || return 1
  # A YAML anchor, alias, merge key or `extends:` can hide a required name from
  # this line parser: then there is no list (the suite runs).
  grep -qE '^[^#]*([:-][[:space:]]+[&*][A-Za-z0-9_-]|<<:)|^extends:' "$f" && return 1
  names=$(awk '
    /^[ \t]*#/ || !NF { next }
    { ind = match($0, /[^ ]/) }
    q && (ind < qi || (ind == qi && $0 !~ /^[ \t]*-/)) { q = 0 }
    /^[ \t]*queue_conditions:[ \t]*$/ { q = 1; qi = ind; next }
    q && /check-success[ \t]*=/ {
      s = $0; sub(/.*check-success[ \t]*=[ \t]*/, "", s); sub(/[ \t]*$/, "", s)
      gsub(/^["\047]|["\047]$/, "", s); if (s != "" && s != "lead-verdict") print s }' "$f" | sort -u)
  [ -n "$names" ] || return 1
  printf '%s\n' "$names"
}

# lr_ci_fetch <repo> <sha> <scratch-file> — ONE REST read of the check runs on
#   <sha> per review (gh_rest, never GraphQL), shared by the rules-pack skip and
#   the host-suite skip. A second call for the same sha reuses the first answer.
#   rc 1 = unreadable, LR_CI_WHY says why. The caller resets LR_CI_SHA per review.
lr_ci_fetch() {
  if [ "${LR_CI_SHA:-}" != "$2" ]; then
    LR_CI_SHA="$2"; LR_CI_FETCH_RC=0; LR_CI_FETCH_WHY=""
    if ! gh_rest GET "repos/$1/commits/$2/check-runs?per_page=100&filter=latest" > "$3" 2>/dev/null; then
      LR_CI_FETCH_RC=1; LR_CI_FETCH_WHY="check runs unreadable (HTTP ${GH_REST_STATUS:-000})"
    fi
  fi
  LR_CI_WHY="$LR_CI_FETCH_WHY"
  return "$LR_CI_FETCH_RC"
}

# _lr_ci_judge <sha> <file> <required names, newline separated> <all:1|0> — the
#   verdict on a fetched answer: `green <n>` (n = the required names, each
#   verified) or the reason it is not. Every
#   required name needs a run on <sha>, and every run of it completed success.
#   all=1 also refuses ANY GitHub Actions run on <sha> that is pending or failed
#   (skipped and neutral are fine: path-filtered jobs). Other apps' runs (Mergify's
#   `Mergify Merge Queue` / `Summary`, in_progress while a PR sits in the queue)
#   are not CI results and only count when required. A run naming another sha, a malformed
#   answer, or a list longer than one page is never green.
_lr_ci_judge() {
  jq -r --arg s "$1" --arg req "$3" --arg all "$4" '
    if type != "object" or (.check_runs | type) != "array" then "malformed check-run answer"
    elif (.total_count // 0) > (.check_runs | length) then "more check runs than one page (\(.total_count))"
    else .check_runs as $r
      | ($req | split("\n") | map(select(length > 0))) as $need
      | [$r[] | select(.head_sha != $s)] as $other
      | [$r[] | select((.app.slug // "github-actions") == "github-actions")] as $ci
      | (if $all == "1" then [$ci[] | select(.status != "completed")] else [] end) as $pend
      | (if $all == "1" then [$ci[] | select(.status == "completed" and ((.conclusion // "") | IN("success","skipped","neutral") | not))] else [] end) as $bad
      | [$need[] as $n | select(([$r[] | select(.name == $n)] | length) == 0
                               or ([$r[] | select(.name == $n and (.status != "completed" or .conclusion != "success"))] | length) > 0) | $n] as $miss
      | if ($need | length) == 0 then "no required check named"
        elif ($other | length) > 0 then "check runs name another sha (\($other[0].head_sha[0:12]))"
        elif ($pend | length) > 0 then "pending: \($pend | map(.name) | join(", "))"
        elif ($bad | length) > 0 then "failed: \($bad | map("\(.name)=\(.conclusion)") | join(", "))"
        elif ($miss | length) > 0 then "required not green: \($miss | join(", "))"
        else "green \($need | length)" end
    end' "$2" 2>/dev/null
}

# lr_ci_green <repo> <sha> <mergify-file> <scratch-file> — rc 0 when the PR's CI already
#   passed on EXACTLY <sha>: every check the merge queue requires (lr_ci_required)
#   has a run on <sha> that completed with success, and no check run on <sha> is
#   pending or failed. LR_CI_N = the required checks verified. Anything unknown is rc 1
#   with LR_CI_WHY: no required list, an unreadable or malformed answer, a list
#   longer than one page, a run naming another sha.
lr_ci_green() {
  local req verdict
  LR_CI_N=0; LR_CI_REQ=""; LR_CI_WHY=""
  req=$(lr_ci_required "$3") || { LR_CI_WHY="no merge-queue check list (.mergify.yml)"; return 1; }
  lr_ci_fetch "$1" "$2" "$4" || return 1
  verdict=$(_lr_ci_judge "$2" "$4" "$req" 1)
  case "$verdict" in
    "green "[0-9]*) LR_CI_N="${verdict#green }"; LR_CI_REQ="$req"; return 0 ;;
    "") LR_CI_WHY="malformed check-run answer"; return 1 ;;
    *) LR_CI_WHY="$verdict"; return 1 ;;
  esac
}

# lr_ci_jobs_green <repo> <sha> <scratch-file> <name>... — rc 0 when each named
#   CI job has a run on EXACTLY <sha> and every run of it completed success.
#   Pending, failed, missing, unreadable or another sha = rc 1, LR_CI_WHY.
lr_ci_jobs_green() {
  local repo="$1" sha="$2" f="$3" req verdict
  shift 3; LR_CI_WHY=""
  req=$(printf '%s\n' "$@")
  lr_ci_fetch "$repo" "$sha" "$f" || return 1
  verdict=$(_lr_ci_judge "$sha" "$f" "$req" 0)
  case "$verdict" in
    "green "[0-9]*) return 0 ;;
    "") LR_CI_WHY="malformed check-run answer"; return 1 ;;
    *) LR_CI_WHY="$verdict"; return 1 ;;
  esac
}
# <<< lead ci green

# split-host: bin/lib/lead-review/ max-growth=40
# The lane's function groups, one concern a module, loaded through the module
# map (docs/MODULE-MAP.md). New code goes there: bin/split-host-growth-lint.sh
# refuses more than 40 net new lines in this file in one PR.
# shellcheck source=bin/lib/lead-review/load.sh
if ! . "$H/bin/lib/lead-review/load.sh"; then
  log "bin/lib/lead-review/ did not load; lead-review tick skipped"
  HARNESS="$H" "$H/bin/alert-line.sh" --id "lead-review-modules-$(hostname)" "LEAD REVIEW MODULE MISSING: bin/lib/lead-review/ is missing or unusable on $(hostname); no lead review ran this tick" >/dev/null 2>&1 || true
  exit 0
fi

# lr_ci_cfg_inputs <tree> <base-ref> — the files that decide what the PR's CI
#   runs, read from the BASE branch (never the PR's head): a PR that edits any of
#   them can make its own CI green on a weaker run, so neither lead skip trusts
#   that green. One entry a line; one ending in `/` or `*` is a prefix.
#   The floor, named whether or not a workflow names it: .github/, .mergify.yml,
#   other CI systems' config, bin/ci-*, bin/test-impact*, catalog/ci-*,
#   catalog/test-impact*. Then every file the base workflows name (the scripts
#   they invoke, the confs they pass), the package.json/Makefile of the repo root
#   and of every directory they name (`npm test` reads its script there), and,
#   from the scripts among them (not tests), the libs they source (`lib/`) and
#   the data and config files they read (the impact map, the tier list).
#   Only names that exist in the base tree count. rc 1 = the base tree cannot be
#   read: the caller then treats the PR as touching CI.
lr_ci_cfg_inputs() {
  local tree="${1:-}" ref="${2:-}" all wf l1 f t
  all=$(git -C "$tree" ls-tree -r --name-only "$ref" 2>/dev/null) && [ -n "$all" ] || return 1
  wf=$(grep -E '^\.github/workflows/[^/]+\.ya?ml$' <<<"$all")
  # _names: the path-like words in stdin that name a file (or with -d, a
  # directory) of the base tree.
  _lr_cfg_names() {
    grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+|[A-Za-z0-9_-]+\.(sh|bash|py|js|mjs|cjs|ts|json|ya?ml|toml|conf|cfg|ini|tsv|txt|mk)' \
      | sed -E 's#^\./##; s#/+$##' | sort -u \
      | awk -v d="${1:-}" 'NR == FNR { f[$0] = 1; n = split($0, p, "/"); s = ""
                                       for (i = 1; i < n; i++) { s = s (i > 1 ? "/" : "") p[i]; dir[s] = 1 }; next }
                           ($0 in f) { print; next }
                           d == "-d" && ($0 in dir) { print $0 "/" }' <(printf '%s\n' "$all") -
  }
  l1=$(for f in $wf; do git -C "$tree" show "$ref:$f" 2>/dev/null; done | _lr_cfg_names -d)
  {
    printf '%s\n' .github/ .mergify.yml .mergify/ .circleci/ .buildkite/ .gitlab-ci.yml Jenkinsfile \
      'bin/ci-*' 'bin/test-impact*' 'catalog/ci-*' 'catalog/test-impact*'
    printf '%s\n' "$l1" | grep -v '/$'
    for f in "" $(grep '/$' <<<"$l1"); do
      for t in "${f}package.json" "${f}Makefile"; do grep -qxF "$t" <<<"$all" && printf '%s\n' "$t"; done
    done
    # One level down, from the scripts that run CI (not its tests; a name
    # that says ci, test, lint, check, suite, tier, plan, impact, verdict or
    # run): the data and config they read and the libs they source. Other
    # scripts a workflow names, and what those name, are the code CI judges.
    while IFS= read -r f; do
      case "$f" in ''|*/|.github/*|tests/*|test/*|spec/*|*/test/*|*/tests/*) continue ;; esac
      case "${f##*/}" in *ci[-_.]*|ci|*[-_]ci|*impact*|*plan*|*verdict*|*suite*|*tier*|*check*|*lint*|*test*|run[-_.]*|Makefile) ;; *) continue ;; esac
      case "$f" in *.sh|*.bash|*.py|*.js|*.mjs|*.cjs|*.ts|bin/*|*/Makefile|Makefile) git -C "$tree" show "$ref:$f" 2>/dev/null ;; esac
    done <<<"$l1" | _lr_cfg_names \
      | grep -E '(^|/)lib/|\.(tsv|txt|json|conf|cfg|ini|ya?ml|toml|csv|list|mk)$|(^|/)(Makefile|package\.json)$'
  } | grep -v '^$' | sort -u
}

# lr_ci_cfg_touched <tree> <base-ref> <sha> — rc 0 (and LR_CICFG_WHY) when the
#   PR's diff base...sha touches a file that decides what CI runs
#   (lr_ci_cfg_inputs), or when that cannot be known: then CI's green is the
#   PR's own and both skips are off. rc 1 only when the diff is read and touches
#   none. One answer per review: a second call for the same sha reuses it.
lr_ci_cfg_touched() {
  local inputs changed hit
  if [ "${LR_CICFG_SHA:-}" = "$3" ]; then LR_CICFG_WHY="$LR_CICFG_SAVED"; return "$LR_CICFG_RC"; fi
  LR_CICFG_SHA="$3"; LR_CICFG_WHY=""; LR_CICFG_RC=0
  if ! inputs=$(lr_ci_cfg_inputs "$1" "$2"); then
    LR_CICFG_WHY="the files that decide CI could not be listed from $2"
  elif ! changed=$(git -C "$1" diff --no-renames --name-only "$2...$3" 2>/dev/null); then
    LR_CICFG_WHY="the diff ${2}...${3:0:12} could not be read"
  elif [ -z "$changed" ]; then
    LR_CICFG_WHY="the diff ${2}...${3:0:12} is empty"
  else
    hit=$(awk 'NR == FNR { if ($0 ~ /[\/*]$/) { sub(/\*$/, ""); d[$0] = 1 } else f[$0] = 1; next }
               ($0 in f) { print; exit }
               { for (k in d) if (index($0, k) == 1) { print; exit } }' <(printf '%s\n' "$inputs") <(printf '%s\n' "$changed"))
    if [ -n "$hit" ]; then LR_CICFG_WHY="the PR changes CI itself: $hit"; else LR_CICFG_RC=1; fi
  fi
  LR_CICFG_SAVED="$LR_CICFG_WHY"
  return "$LR_CICFG_RC"
}

# The CI jobs that run the rules pack on a cromford PR head: the lint job
# runs bin/rules-pack.sh with --skip determinism, and the determinism job runs
# the part it skips. CI runs the PR's OWN pack (its catalog, its ratchets), the
# lead runs the box's trusted copy. They are the same pack only when the diff
# touches none of the pack's inputs (lr_rp_touched), so the lead skips its run
# only then AND with both jobs green on the reviewed sha (skip-if-ci-green and
# off; `always` runs it).
LR_RP_CI_JOBS=("Syntax + shellcheck + config integrity" "Test determinism lint")

# The parser's word match ends at any non-word character, so an echoed template
# line (`VERDICT: MERGE|MERGE-WITH-NOTES|BLOCK`) or `VERDICT: MERGE.` reads as
# MERGE. A verdict counts only when the last non-blank line is exactly the label
# and that one word, nothing after it; anything else is unknown.
lr_verdict() {
  local v last
  v=$(verdict_parse -c -w 'MERGE-WITH-NOTES|BLOCK|MERGE' "$1")
  last=$(tr -d '\r' < "$1" 2>/dev/null | awk 'NF {l=$0} END {print l}' | sed 's/[[:space:]]*$//')
  case "$last" in
    "VERDICT: $v"|"**VERDICT:** $v") printf '%s' "$v" ;;
    *) printf unknown ;;
  esac
}

# lr_has_findings <file> — rc 0 when the text holds a findings block: a heading
#   line `Findings` (`## Findings`, `**Findings**`, `Findings:`, any case), then
#   on a later line an item `- [BLOCK...`, `- [NOTE...`, `- none` or
#   `no findings`; or `Findings: none` on one line. A postscript after the
#   review has none of these (BH-6090).
lr_has_findings() {
  tr -d '\r' < "$1" 2>/dev/null | awk '
    { l = tolower($0); sub(/[ \t]+$/, "", l) }
    l ~ /^[#* ]*findings[*:]*[ \t]*(-[ \t]*)?none\.?$/ { f = 1; exit }
    l ~ /^[#* ]*findings[*:]*$/ { h = 1; next }
    h && (l ~ /^- \[(block|note)/ || l ~ /^- none\.?$/ || l ~ /^-? *no findings\.?$/) { f = 1; exit }
    END { exit !f }'
}

# lr_pick_review <out> <key> — rc 0 = <out> holds a readable review. The answer
#   in <out> is the CLI's `.result`, the model's LAST message. When it holds no
#   findings (a postscript after the review, BH-6090), the session transcript
#   that bin/agent-call.sh names in <out>.session (`<sid><TAB><config-dir>`) is
#   read: its non-sidechain assistant text, one entry per message id, from the
#   last to the first. The first one with findings AND a verdict (lr_verdict)
#   replaces <out>. rc 1 = no such message, or no transcript to read.
lr_pick_review() {
  local out="$1" sid="" cfg="" tf n i m tfs
  lr_has_findings "$out" && return 0
  IFS=$'\t' read -r sid cfg 2>/dev/null < "$out.session" || { log "no findings in the answer for $2 and no session file; unreadable"; return 1; }
  [[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] && [ -n "$cfg" ] || { log "no findings in the answer for $2; session line unusable; unreadable"; return 1; }
  tfs=("$cfg"/projects/*/"$sid".jsonl); tf=${tfs[0]}
  [ -r "$tf" ] || { log "no findings in the answer for $2; transcript $sid not found under $cfg; unreadable"; return 1; }
  jq -c 'select(.type == "assistant" and ((.isSidechain // false) | not))
    | {id: (.message.id // ""), t: (.message.content | if type == "string" then .
        else ([.[]? | select(.type == "text") | .text] | join("\n")) end)}
    | select(.t != "")' "$tf" 2>/dev/null \
  | jq -s 'reduce to_entries[] as $e ({o: [], m: {}};
      ($e.value.id | if . == "" then "n\($e.key)" else . end) as $k
      | if .m[$k] then .m[$k] += "\n" + $e.value.t else .o += [$k] | .m[$k] = $e.value.t end)
      | [.o[] as $k | .m[$k]]' > "$out.msgs" 2>/dev/null
  n=$(jq 'length' "$out.msgs" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
  for ((i = n - 1; i >= 0; i--)); do
    m="$out.msg.$i"; jq -r --argjson i "$i" '.[$i]' "$out.msgs" > "$m" 2>/dev/null || continue
    if lr_has_findings "$m" && [ "$(lr_verdict "$m")" != unknown ]; then
      cp -f "$m" "$out" && rm -f "$out.msgs" "$out.msg."* \
        && { log "kept review message $((i + 1)) of $n from session $sid for $2; the last message held no findings"; return 0; }
      log "could not copy review message $((i + 1)) of session $sid over the answer for $2; unreadable"; return 1
    fi
  done
  rm -f "$out.msgs" "$out.msg."*
  log "no message of $n in session $sid for $2 holds findings and a verdict; unreadable"; return 1
}

WT=""; BEAT=""; LRBEAT=""; REPO_DIR=""; LR_KEYFD=""
QF="$H/tmp/lead-review-queue-$$"  # the tick's queue files (BH-5151), removed at exit
trap 'cleanup; rm -f "$QF".*; command -v rpool_finish >/dev/null 2>&1 && rpool_finish' EXIT
trap 'cleanup; rm -f "$QF".*; command -v rpool_finish >/dev/null 2>&1 && rpool_finish; exit 130' INT TERM

R=""
# The lead-land ring (BH-5317). Globals, because the worker's exit trap reads
# them after review_one's locals are gone. LR_RING=1 only once a terminal
# result post answered 2xx; LR_RING_RP is the rules-pack state of a fresh
# review, LR_RING_REPORT the report a replay delivered (its `- rules pack:` line).
LR_RING=0 LR_RING_REPO="" LR_RING_PR="" LR_RING_SHA="" LR_RING_REPORT="" LR_RING_RP=""
# lr_file_predates <file> <iso-time> — rc 0 when the file was last written
# before <iso-time>. An empty or unreadable time, or an unreadable mtime, is
# rc 1: nothing is called stale on a guess.
lr_file_predates() {
  local m t
  [ -n "${2:-}" ] || return 1
  t=$(date -u -d "$2" +%s 2>/dev/null) || return 1
  m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  [[ "$m" =~ ^[0-9]+$ && "$t" =~ ^[0-9]+$ ]] || return 1
  [ "$m" -lt "$t" ]
}
review_one() {
  local r="$1" id repo pr sha project key model job rc pr_json live state base title body left res n st rw rprev rhow rby rsrc
  local suite_cmd suite_line suite_rc ci_ok pf out verdict report empty rmodel ad akind hdr
  local RP_STATE="" RP_TAIL="" CL_STATE="" CL_TAIL="" rp_rc rp_ci harness_repo dmode="" dprev="" dline="" dreport lb tn tslug tdone thread_note total half lfp lstage lnote
  local capr="" capo capf ctitle clabels
  local resets mreset since f what fields="" bfp bchg rsn gpaid bmode="" bline="" ldp_rc="" dbytes ldp_why nprod ldp_mode ldp_find
  local lunread=0 lspent=""
  local lpv=0 lpk="" lprc imode="" imodel ire ckl imm wlnotes="" rlcap="" rlgl=0 rlgo bires="" bimode=off birw=0 biline=""
  # BH-5873: the mode the gates chose (full|delta|replay). Nothing reads it yet;
  # child 2 of #5870 (delta and replay) does.
  # shellcheck disable=SC2034
  local lg_mode="${3:-full}"
  id=$(jq -r '.id // empty' <<<"$r"); repo=$(jq -r '.repo // empty' <<<"$r")
  pr=$(jq -r '.pr // empty' <<<"$r"); sha=$(jq -r '.head_sha // empty' <<<"$r"); project="$2"
  # BH-5793: how many times lead-review-land requeued this request. The .empty
  # marker is written with it, so a requeue gets a real review (see below).
  resets=$(jq -r '.reset_count // 0' <<<"$r"); [[ "$resets" =~ ^[0-9]+$ ]] || resets=0
  since=$(jq -r '.reset_at // .created_at // ""' <<<"$r")
  key="lr-$pr-${sha:0:12}"
  LR_RING_REPO="$repo"; LR_RING_PR="$pr"; LR_RING_SHA="$sha"
  R=skipped
  model=$(model_for lead.review "$project" 2>/dev/null) && [ -n "$model" ] \
    || { log "no model route for lead.review; request $id left requested"; return; }
  # A worklist item's job carries the gates' fields (lg_job_fields); none = no
  # meta. The same fields are its scope_notes on /start (BH-5878, lg_scope_notes).
  if [ -z "$id" ]; then
    fields=$(lg_job_fields "$repo" "$pr" "$sha") || { log "skip $key: gate fields unreadable"; R=skipped; return; }
    wlnotes=$(lg_scope_notes "$sha" "$fields")
    [ "$fields" = '{}' ] && fields=""
  fi
  job=$(job_open "$project" "$key" lead_review review lead-review "$fields"); rc=$?
  [ "$rc" -eq 9 ] && { log "skip $key: $job"; return; }
  # rc 1 is job_open's "API unusable": a fault of the whole worker, not this row.
  [ "$rc" -eq 0 ] || { log "job_open for $key failed (worker unusable); tick ended"; R=stop; return; }
  # BH-4956: one worker per key on this box, a dedupe and never a wait. fd 8,
  # closed in cleanup and wherever fd 7 is closed.
  [ -d "$H/locks" ] || mkdir -p "$H/locks"
  if ! { exec 8>"$H/locks/lead-review-$key.lock" && flock -n 8; }; then
    exec 8>&-; log "skip $key: another worker holds locks/lead-review-$key.lock"
    # BH-7792: the holder's job is ours too when job_open resumed it on this box.
    if [ "$(cat "$H/locks/lead-review-$key.job" 2>/dev/null)" = "$job" ]; then
      log "skip $key: job $job is the lock holder's; left open"; return
    fi
    job_update "$job" status=done 'meta={"reason":"key held"}'; return
  fi
  LR_KEYFD=8
  printf '%s\n' "$job" > "$H/locks/lead-review-$key.job" 2>/dev/null || log "$key: holder job not recorded in locks/lead-review-$key.job"
  # The limits a tick applies before a claim (header); `one` has none. The
  # attempts gate is for a worklist item: a request row's own status is its
  # record (the third counted failure posts outcome=failed to it, and a failed
  # row is not listed again), so a row costs no extra read on the serial path.
  # A pool `item` (BH-8027) is a tick's item and keeps these limits.
  if [ "$MODE" != one ]; then
    if [ -z "$id" ]; then
      if ! n=$(lw_attempts "$repo" "$pr" "$sha"); then
        log "skip $key: its counted attempts are unreadable"; job_update "$job" status=done 'meta={"reason":"attempts unreadable"}'; return
      elif [ "$n" -ge 3 ]; then
        log "skip $key: 3 counted attempts on this head"; job_update "$job" status=done 'meta={"reason":"attempts exhausted"}'; return
      fi
    fi
    if ! lw_pr_day_ok "$repo" "$pr"; then
      log "skip $key: $repo#$pr had agent calls for LEAD_REVIEW_MAX_PER_PR_DAY=$LW_PR_DAY_MAX lead reviews today on this box"
      lw_pr_day_trip "$repo" "$pr"
      job_update "$job" status=done 'meta={"reason":"per-pr-day cap"}'; R=capped; return
    fi
  fi
  R=failed
  if [ -z "$id" ]; then
    # A worklist item: /start creates or takes its request row (lr_start rc contract).
    res=$(lr_start "$repo" "$pr" "$sha" "$job" "$JOBS_BOX" "$wlnotes" 2>/dev/null); rc=$?
    case "$rc" in
      0) r=$(jq -c '.request // empty' <<<"$res" 2>/dev/null); id=$(jq -r '.id // empty' <<<"$r" 2>/dev/null)
         [ -n "$id" ] || { log "start of $key answered no request id; job failed"; job_update "$job" status=failed; return; }
         # A row made before its notes existed reads this start's notes.
         [ -n "$(jq -r '.scope_notes // empty' <<<"$r" 2>/dev/null)" ] || r=$(jq -c --arg n "$wlnotes" '.scope_notes = $n' <<<"$r")
         lg_post "$repo" "$pr" "$sha" ;;
      3) st=$(jq -r '.request.status // empty' <<<"$res" 2>/dev/null)
         job_update "$job" status=done
         if [ "$st" = done ]; then log "paid already $key: its request is done; no agent call"; R=paid
         else log "skip $key: its request is ${st:-terminal}"; R=skipped; fi
         return ;;
      4) log "skip $key: a live job holds its request"; job_update "$job" status=done; R=skipped; return ;;
      *) log "start of $key failed (rc=$rc): $(printf '%s' "$res" | tr '\n' ' ' | head -c 200)"; job_update "$job" status=failed; return ;;
    esac
  else
    claim_req "$id" "$job" "$key"; rc=$?
    [ "$rc" -eq 2 ] && { R=stop; return; }
    [ "$rc" -eq 0 ] || return
    # The list showed it running under another job: a stale claim taken over is
    # a counted attempt, unless this lane left it running on purpose (the
    # release marker, lr_left_running: a refusal before billing, a rate limit,
    # or a failure it already counted). $r is jq -c output (no spaces), so a
    # plain match reads its status.
    if [[ "$r" == *'"status":"running"'* ]]; then
      lw_released "$repo" "$pr" "$sha"; rc=$?
      case "$rc" in
        0) log "$key: the claim taken over was released by this lane; not counted" ;;
        2) lr_count_fail "$id" "$job" "$sha" "stale claim taken over" && return ;;
        *) log "$key: release marker unreadable; the takeover is not counted" ;;
      esac
    fi
  fi
  BEAT=$(job_beat_start "$job")
  LRBEAT=$(lr_beat_start "$id" "$job" auto)
  # BH-5284: claimed, so the tick may claim the next request while this one
  # reviews. Everything before this line runs in queue order, one at a time.
  rpool_gate_open
  # The gate fact (BH-4956): this head is under review. Fail-open, after the
  # gate, so it never holds the next claim.
  pr_gate_event_put "$repo" "$pr" "lead-review@${sha:0:12}@$job" lead-review:claim "reviewing_sha=$sha" >/dev/null 2>&1 \
    || log "$key: gate fact reviewing_sha not recorded"
  REPO_DIR="$REPOS/$project"; mkdir -p "$H/tmp"; WT="$H/tmp/lead-review-$key-$$"
  # To a file, not $( ): GH_REST_STATUS / GH_REST_REASON live in this shell only.
  gh_rest GET "repos/$repo/pulls/$pr" > "$WT.pr" 2>/dev/null; rc=$?
  pr_json=$(cat "$WT.pr"); live=$(jq -r '.head.sha // empty' <<<"$pr_json" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$live" ]; then
    log "live head of $repo#$pr unreadable (rc=$rc HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}); $key left for the next tick"
    # A GitHub rate limit (or the quota reserve), a 5xx or a transport failure
    # (no HTTP status) is GitHub's outage, not this head's fault: not counted,
    # the row is left for a later tick. A terminal failed row is not reopened
    # by a re-POST, so counting an outage would strand every waiting head.
    # Counted: a 4xx, or a 2xx with no head sha.
    case "${GH_REST_REASON:-}" in
      rate-limit|quota-reserve) lr_left_running "github $GH_REST_REASON"; job_update "$job" status=failed; return ;;
    esac
    case "${GH_REST_STATUS:-000}" in
      5??|000|"") lr_left_running "github HTTP ${GH_REST_STATUS:-000}"; job_update "$job" status=failed; return ;;
    esac
    lr_fail_counted "$id" "$job" "$sha" "live head unreadable"; return
  fi
  # A closed PR is not reviewed (BH-5151); a missing .state says nothing.
  state=$(jq -r '.state // empty' <<<"$pr_json" 2>/dev/null)
  if [ -n "$state" ] && [ "$state" != open ]; then
    post_result "$id" "$(jq -nc --arg j "$job" --arg s "$sha" '{job_id:$j,head_sha:$s,outcome:"superseded",detail:"pr closed"}')" || return
    job_update "$job" status=done; log "superseded $key: pr closed"; R=superseded; return
  fi
  if [ "$live" != "$sha" ]; then
    post_result "$id" "$(jq -nc --arg j "$job" --arg s "$sha" --arg d "head moved to ${live:0:12}" '{job_id:$j,head_sha:$s,outcome:"superseded",detail:$d}')" || return
    job_update "$job" status=done; log "superseded $key: live head is ${live:0:12}"; R=superseded; return
  fi
  # BH-5888: the body this review reads. Every report names it, and a replay
  # needs the same one (lr_report_body_ok, below).
  body=$(jq -r '.body // ""' <<<"$pr_json"); bfp=$(lr_body_fp <<<"$pr_json")
  # bchg=1 once a stored review of this head is seen to name another body: the
  # paid call then carries the body in its guard key (below).
  bchg=0
  # BH-5022: a risk-tier MERGE already stands on this head (the enqueue signed
  # it off after this request was made), so the review would buy nothing. Only
  # an answered rc 0 with source risk-tier skips; any other answer reviews. Only
  # the enqueue's own requests are superseded: one a person filed (REQUEST LEAD
  # REVIEW, lead-verdict.sh request) is a review someone asked for, so it runs.
  if command -v vd_standing >/dev/null 2>&1 \
     && [[ "$(jq -r '.requested_by // ""' <<<"$r")" == lead-review-enqueue:* ]] \
     && [ "$(vd_standing "$repo" "$pr" "$sha" 2>/dev/null | cut -f2)" = risk-tier ]; then
    post_result "$id" "$(jq -nc --arg j "$job" --arg s "$sha" '{job_id:$j,head_sha:$s,outcome:"superseded"}')" || return
    job_update "$job" status=done; log "superseded $key: signed off by risk-tier"; R=superseded; return
  fi
  # Paid already (BH-2202): a retry after a failed post replays what it stored,
  # the job's artifact first (BH-2624), the disk second.
  mkdir -p "$H/state/lead-reviews"
  report="$H/state/lead-reviews/$key.md"; empty="$H/state/lead-reviews/$key.empty"
  hdr="# Lead review $key ($repo#$pr at $sha)"
  # rc 3 = no row, or an old row with no detail; rc 1 = the worker could not be
  # asked, which says nothing about rows. Both read the disk.
  ad=$(job_artifact_detail lead_review_report "$job"); rc=$?; akind=""
  [ "$rc" -eq 1 ] && log "artifact for $key unavailable (rc=1); reading disk"
  [ "$rc" -eq 0 ] && { akind=$(jq -r --arg e "$key.empty" '
      if type != "object" then "bad"
      elif .empty == true then (if ((.path // "") | split("/") | last) == $e then "empty" else "bad" end)
      elif (.body | type) == "string" then (if .truncated == true then "truncated" else "body" end)
      else "bad" end' <<<"$ad" 2>/dev/null) || akind=bad; }
  case "$akind" in
    empty)
      rmodel=$(jq -r '.model // ""' <<<"$ad"); rmodel="${rmodel:-$model}"
      log "billed with no verdict earlier for $key (artifact); no agent call"
      fail_terminal "$id" "$job" "$sha" empty "$rmodel"; return ;;
    body|truncated)
      jq -j '.body' <<<"$ad" > "$WT.replay"
      if [ "$(lr_report_title "$WT.replay")" != "$hdr" ]; then
        log "artifact lead_review_report for $key names another head; reading disk"
      elif ! lr_report_body_ok "$WT.replay" "$bfp"; then
        bchg=1
        log "artifact lead_review_report for $key was written against another PR body; reading disk"
      elif [ "$akind" = truncated ] && [ -f "$report" ] && [ "$(lr_report_title "$report")" = "$hdr" ]; then
        log "artifact lead_review_report for $key is truncated; the disk report is authoritative"
      else
        if [ "$akind" = truncated ]; then
          verdict=$(jq -r '.verdict // ""' <<<"$ad")
          case "$verdict" in MERGE|MERGE-WITH-NOTES|BLOCK) ;; *) verdict=unknown ;; esac
        else
          verdict=$(lr_verdict "$WT.replay")
        fi
        rmodel=$(sed -n 's/^- reviewer model: //p' "$WT.replay" | head -n 1); rmodel="${rmodel:-$model}"
        LR_RING_RP=$(sed -n 's/^- rules pack: //p' "$WT.replay" | head -n 1)
        suite_line=$(sed -n 's/^- \(host suite: .*\)$/\1/p' "$WT.replay" | head -n 1)
        log "reusing artifact lead_review_report for $key; no agent call"
        [ "$verdict" = unknown ] && { fail_terminal "$id" "$job" "$sha" empty "$rmodel"; return; }
        finish_done "$id" "$job" "$sha" "$verdict" "$report" "$rmodel" "$suite_line" "$key" 1; return
      fi ;;
    bad) log "artifact lead_review_report for $key is not a report; reading disk" ;;
  esac
  # BH-5888: a report written against another PR body is not this body's
  # review: a body-only fix gets a review that reads it. Read before the
  # BH-5793 loop below, which would delete a reset request's report unread.
  if [ -f "$report" ] && ! lr_report_body_ok "$report" "$bfp"; then
    bchg=1
    log "report for $key was written against another PR body; it gets a real review"
    rm -f "$report"
  fi
  # BH-5793: the disk report and the .empty marker are keyed by PR and head, so
  # one written for an EARLIER request on this head (the conductor's new
  # request, a reset by lead-review-land or the env sweep) must not be replayed:
  # that request asked for a new review. Only a file written at or after this
  # request's latest start (reset_at, else created_at) is this request's own,
  # which is what a watchdog retake of the same claim finds. A request with no
  # start time keeps the old behaviour.
  for f in "$report" "$empty"; do
    if [ -f "$f" ] && lr_file_predates "$f" "$since"; then
      case "$f" in *.md) what=report ;; *) what="empty marker" ;; esac
      log "$what for $key predates request $id (started $since); it gets a real review"
      rm -f "$f"
    fi
  done
  if [ -f "$report" ] && [ "$(lr_report_title "$report")" = "# Lead review $key ($repo#$pr at $sha)" ]; then
    verdict=$(lr_verdict "$report")
    rmodel=$(sed -n 's/^- reviewer model: //p' "$report" | head -n 1); rmodel="${rmodel:-$model}"
    suite_line=$(sed -n 's/^- \(host suite: .*\)$/\1/p' "$report" | head -n 1)
    log "reusing $report for $key; no agent call"
    [ "$verdict" = unknown ] && { fail_terminal "$id" "$job" "$sha" empty "$rmodel"; return; }
    finish_done "$id" "$job" "$sha" "$verdict" "$report" "$rmodel" "$suite_line" "$key"; return
  fi
  # The marker stops a retake of the SAME request from paying twice. A marker
  # from an earlier reset does not: lead-review-land reset the request on
  # purpose (an `empty` is a timeout or a model error, BH-5793) and capped the
  # resets at ENV_RETRY_MAX, so that request gets one real review per reset.
  # A marker with no reset= line predates the field and counts as reset 0.
  if [ -f "$empty" ]; then
    mreset=$(sed -n 's/^reset=//p' "$empty" | head -n 1); [[ "$mreset" =~ ^[0-9]+$ ]] || mreset=0
    if [ "$mreset" = "$resets" ]; then
      rmodel=$(head -n 1 "$empty"); rmodel="${rmodel:-$model}"
      log "billed with no verdict earlier for $key; no agent call"
      fail_terminal "$id" "$job" "$sha" empty "$rmodel"; return
    fi
    log "empty marker for $key is from reset $mreset; the request is at reset $resets, so it gets a real review"
    rm -f "$empty"
  fi
  base=$(jq -r '.base.ref // "main"' <<<"$pr_json"); title=$(jq -r '.title // ""' <<<"$pr_json")
  [ -d "$REPO_DIR/.git" ] || { log "$REPO_DIR is not a clone on this box"; fail_terminal "$id" "$job" "$sha" no-checkout; return; }
  if ! git -C "$REPO_DIR" fetch -q origin "$base" "+refs/pull/$pr/head:refs/lead-review/$pr" >/dev/null 2>&1; then
    # A failed fetch is a network or GitHub fault, not this head's: not counted,
    # the row is left for a later tick (as before BH-4956).
    log "checkout of $sha for $key failed (fetch); $key left for the next tick, not counted"
    lr_left_running "fetch failed"; job_update "$job" status=failed; return
  fi
  # >>> fresh conflict hold (BH-7816): main rewrote what this head changes, so a
  # review buys only a BLOCK the PR did not cause. Superseded, no agent call.
  if command -v lr_fresh_conflict >/dev/null 2>&1 && lr_fresh_applies "$r" \
     && lr_fresh_conflict "$REPO_DIR" "$base" "$sha"; then lr_fresh_supersede "$id" "$job" "$sha" "$key"; return; fi
  # <<< fresh conflict hold
  # >>> selection gate record (BH-8062)
  # A ticket/* head with no record, or another head's, is a BLOCK, no agent call.
  # Only where the merge base carries bin/selection-gate.sh (r3, F1).
  local grw LR_GR_NOTE=""; grw=$(lr_gate_record "$body" "$sha" "$(jq -r '.head.ref // ""' <<<"$pr_json")" "$(lr_gate_record_mode)" "$REPO_DIR" "$base")
  case "$grw" in
    "refuse "*) mkdir -p "$(dirname "$report")"
      lr_gate_record_report "$RVLINE" "$key" "$repo" "$pr" "$sha" "$bfp" "$grw" > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
        || { log "could not write $report"; job_update "$job" status=failed; return; }
      log "$key: selection gate $grw; BLOCK with no agent call"
      finish_done "$id" "$job" "$sha" BLOCK "$report" none:gate-record "selection gate: ${grw#refuse }" "$key"; return ;;
    "note "*) LR_GR_NOTE="[NOTE] ${grw#note }"; log "$key: selection gate $LR_GR_NOTE" ;;
  esac
  # <<< selection gate record
  # >>> console qa gate (BH-5909), before any replay: a console-ui/src/ head of
  # the harness repo with no QA: PASS naming it is a BLOCK with no model call.
  # An unreadable answer is not counted, and the request waits for the next tick.
  [ "$CONSOLE_QA_GATE" = 1 ] && harness_repo=$("$H/bin/fleet-conf.sh" cromford repo 2>/dev/null)
  if [ "$CONSOLE_QA_GATE" = 1 ] && [ -n "$harness_repo" ] && [ "${repo,,}" = "${harness_repo,,}" ]; then
    if ! git -C "$REPO_DIR" diff --name-only "origin/$base...$sha" > "$H/tmp/lead-review-$key-$$.cqfiles" 2>/dev/null; then
      what="COULD NOT READ: the changed files of ${sha:0:12}"
    elif ! grep -q '^console-ui/src/' "$H/tmp/lead-review-$key-$$.cqfiles"; then
      what=NOT-APPLICABLE
    elif declare -F cqg_head_verdict >/dev/null; then
      what=$(cqg_head_verdict "$repo" "$pr" "$sha" 7>&-)
    else
      what="COULD NOT READ: bin/lib/console-qa-gate.sh is not loaded"
    fi
    rm -f "$H/tmp/lead-review-$key-$$.cqfiles"
    case "$what" in
      NOT-APPLICABLE|"PASS "*) log "$key: console qa $what" ;;
      "MISSING"|"STALE "*)
        mkdir -p "$(dirname "$report")"
        cqg_report "$key" "$repo" "$pr" "$sha" "$what" "$RVLINE" > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
          || { log "could not write $report"; job_update "$job" status=failed; return; }
        log "console qa gate for $key: $what; BLOCK with no agent call"
        finish_done "$id" "$job" "$sha" BLOCK "$report" "$CQG_MODEL" "console qa: $what" "$key"; return ;;
      *)
        log "console qa for $key unreadable ($what); left for the next tick, not counted"
        lr_left_running "console qa unreadable"; job_update "$job" status=failed; return ;;
    esac
  fi
  # <<< console qa gate
  # >>> migration index lint (BH-7667), before any replay: a plain CREATE INDEX
  # on a table in review.large_tables.<project> is a BLOCK with no model call
  # (bin/lib/migration-index-lint.sh). No row = off, and no diff is read. A
  # diff git cannot read is not counted, and the request waits for the next tick.
  local milt="" milrc=0 MIL_STATE=""
  if ! command -v mil_scan >/dev/null 2>&1; then MIL_STATE="off (bin/lib/migration-index-lint.sh not loaded)"
  else
    milt=$(mil_tables "$project" 7>&- 8>&-)
    if [ -z "$milt" ]; then MIL_STATE="off (no review.large_tables row for ${project:-this project})"
    elif ! git -C "$REPO_DIR" diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "origin/$base...$sha" -- ':(icase)*.sql' \
         > "$H/tmp/lead-review-$key-$$.mil" 2>/dev/null; then
      rm -f "$H/tmp/lead-review-$key-$$.mil"
      log "migration lint for $key unreadable (git diff origin/$base...${sha:0:12} failed); left for the next tick, not counted"
      lr_left_running "migration lint unreadable"; job_update "$job" status=failed; return
    else
      milrc=0; mil_scan "$H/tmp/lead-review-$key-$$.mil" "$milt" "$project" > "$H/tmp/lead-review-$key-$$.milf" || milrc=$?
      case "$milrc" in
        0) MIL_STATE=clean ;;
        1)
          mkdir -p "$(dirname "$report")"
          { printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: BLOCK\n- migration lint: red\n- reviewer model: migration-lint\n- pr body: %s\n\nFindings\n' \
              "$RVLINE" "$key" "$repo" "$pr" "$sha" "$bfp"
            grep '[^[:space:]]' "$H/tmp/lead-review-$key-$$.milf"
            printf '\nVERDICT: BLOCK\n'; } > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
            || { rm -f "$H/tmp/lead-review-$key-$$.mil" "$H/tmp/lead-review-$key-$$.milf"; log "could not write $report"; job_update "$job" status=failed; return; }
          log "$key: migration lint red ($(grep -c '[^[:space:]]' "$H/tmp/lead-review-$key-$$.milf") finding(s)); BLOCK with no agent call"
          rm -f "$H/tmp/lead-review-$key-$$.mil" "$H/tmp/lead-review-$key-$$.milf"
          finish_done "$id" "$job" "$sha" BLOCK "$report" migration-lint "migration lint: red" "$key"; return ;;
        *) MIL_STATE="could not run (rc $milrc)" ;;
      esac
    fi
    rm -f "$H/tmp/lead-review-$key-$$.mil" "$H/tmp/lead-review-$key-$$.milf"
  fi
  log "$key: migration lint $MIL_STATE"
  # <<< migration index lint
  # The patch-same replay (BH-4956, header): the lead's MERGE on an earlier head
  # that carries this same patch is posted on this one, with no model call. A
  # BLOCK is never replayed (lw_replay rc 1), so the head is reviewed. Only the
  # enqueue's own requests (requested_by lead-review-enqueue:*) and worklist
  # items (a row lr_start created: requested_by lead-review-worklist) are replayed:
  # any other row is a review someone asked for (REQUEST LEAD REVIEW,
  # lead-verdict.sh request, harness-ctl review), so it runs, the same rule as
  # the risk-tier supersede above (BH-5022).
  rby=$(jq -r '.requested_by // ""' <<<"$r"); rsrc=$(jq -r '.src // ""' <<<"$r")
  if [[ "$rby" != lead-review-enqueue:* ]] && [ "$rby" != lead-review-worklist ] && [ "$rsrc" != worklist ]; then
    LW_REPLAY_WHY="requested by ${rby:-unknown}, not the enqueue: a person's request is reviewed"; false
  elif lw_replay "$repo" "$pr" "$sha" "$REPO_DIR"; then
    rw="$LW_REPLAY_WORD"; rprev="$LW_REPLAY_PREV"; rhow="$LW_REPLAY_HOW"
    if ! post_result "$id" "$(jq -nc --arg j "$job" --arg s "$sha" --arg v "$rw" --arg f "lead-replay:${rprev:0:12}:$rhow" \
         '{job_id:$j,head_sha:$s,outcome:"done",verdict:$v,reviewer_model:"lead-replay",report_ref:$f}')"; then
      log "replay of $key not recorded"; lr_fail_counted "$id" "$job" "$sha" "result post failed"; return
    fi
    LR_RING=1; job_update "$job" status=done
    log "replayed $key: lead $rw from ${rprev:0:12} ($rhow); no agent call"; R=replayed; return
  fi
  [ "$LW_REPLAY_WHY" = "no earlier lead verdict" ] || log "$key: no replay ($LW_REPLAY_WHY)"
  # BH-3930: the head, as the K=1 guard key lead:<slug>#<n>@<sha> on stage
  # lead-head, so one head is paid once; the unknown-verdict retry is its own
  # key (~noverdict). Empty when review-bought.sh is missing = no fp, as before.
  # BH-5888: when the body changed since the stored review (bchg), the keys are
  # ~body<D> and ~nvbody<D> (lr_body_reason), so one head and body is paid once.
  lfp=""; lstage=""
  if command -v lead_fp >/dev/null 2>&1; then
    if [ "$bchg" = 1 ] && rsn=$(lr_body_reason "$bfp"); then
      lfp=$(lead_fp "$repo" "$pr" "$sha" "$rsn")
      log "body changed since the stored review of $key; guard key $lfp"
    else
      lfp=$(lead_fp "$repo" "$pr" "$sha")
    fi
    lstage=lead-head
  fi
  # BH-7792 (#7792 comment 6309315490): ask the lead-head guard first, read-only.
  # A head already paid for, not replayed above, would be refused at the agent
  # call after the rules pack and the host suite: release the claim now instead.
  # BH-8081: a paid round with no readable verdict gets one more paid call on
  # ~unread (bin/lib/lead-unread.sh); a blocked head counts ticks and alerts.
  if [ -n "$lfp" ] && gpaid=$(lr_guard_spent "$project" "$lfp"); then
    if command -v lu_extra_fp >/dev/null 2>&1 && lu_extra_fp "$project" "$repo" "$pr" "$sha" "$bchg" "$bfp"; then
      log "$key: lead-head paid $gpaid on $lfp with no readable verdict; one more paid call on $LU_FP (BH-8081)"
      lspent="$lfp"; lfp="$LU_FP"; lunread=1
    else
      log "$key: lead-head call-guard paid $gpaid on $lfp; no rules pack, no host suite, no agent call"
      command -v lu_guard_blocked >/dev/null 2>&1 && lu_guard_blocked "$project" "$repo" "$pr" "$sha" "$key" "$lfp" "$gpaid"
      lr_release_claim "$id" "$job" "$key" "call-guard: lead-head paid $gpaid"; return
    fi
  fi
  if ! git -C "$REPO_DIR" worktree add -q --detach "$WT" "$sha" >/dev/null 2>&1; then
    log "checkout of $sha for $key failed"; lr_fail_counted "$id" "$job" "$sha" checkout; return
  fi
  # Rules pack first (BH-3546): a red is a BLOCK with no model call. Half of what
  # is left of the deadline, the same split the suite gets. True rc, unpiped.
  # One check-run read per review, shared with the host-suite skip below.
  LR_CI_SHA=""; LR_CICFG_SHA=""
  harness_repo=$("$H/bin/fleet-conf.sh" cromford repo 2>/dev/null)
  rp_ci=0
  if [ -x "$H/bin/rules-pack.sh" ] && [ -n "$harness_repo" ] && [ "${repo,,}" = "${harness_repo,,}" ] \
     && [ "$HOST_SUITE" != always ]; then
    if lr_rp_touched "$H" "$WT" "origin/$base" "$sha"; then
      log "$key: rules pack runs (trusted copy: $LR_RP_WHY)"
    elif ! lr_ci_jobs_green "$repo" "$sha" "$WT.checks" "${LR_RP_CI_JOBS[@]}"; then
      log "$key: rules pack runs (CI not known green on ${sha:0:12}: $LR_CI_WHY)"
    # CI's green is the PR's own CI: a PR that edits what CI runs earns no skip.
    elif lr_ci_cfg_touched "$WT" "origin/$base" "$sha"; then log "$key: rules pack runs ($LR_CICFG_WHY)"
    else rp_ci=1; fi
  fi
  if [ ! -x "$H/bin/rules-pack.sh" ]; then RP_STATE="not installed on this box"
  elif [ -z "$harness_repo" ] || [ "${repo,,}" != "${harness_repo,,}" ]; then RP_STATE="not applicable to $repo"
  elif [ "$rp_ci" = 1 ]; then
    # Clean, not "could not run": CI ran this same pack green on this head.
    RP_STATE="skipped (CI green on ${sha:0:12})"
    RP_TAIL="CI ran this rules pack on this exact head and it passed ($(printf '"%s", ' "${LR_RP_CI_JOBS[@]}" | sed 's/, $//')), and this PR changes none of the pack's own files, so CI's pack is the trusted one; treat it as clean."
  else
    left=$((DEADLINE - SECONDS)); [ "$left" -lt 120 ] && left=120
    timeout "$((left / 2))" "$H/bin/rules-pack.sh" --tree "$WT" --base "origin/$base" --out "$WT.rp" \
      7>&- 8>&- > "$WT.rpout" 2> "$WT.rperr"; rp_rc=$?
    case "$rp_rc" in
      0) RP_STATE=clean ;;
      1)
        if ! grep -q '[^[:space:]]' "$WT.rpout"; then
          log "rules pack exited 1 with no finding line for $key; stderr tail: $(tail -n 20 "$WT.rperr" | tr '\n' ' ')"
          echo "rules pack exited 1 with no finding line (stderr tail in the lead-review log)" > "$WT.rpout"
        fi
        # BH-5793: an environment failure (a suite the head does not carry, a
        # suite's own repo setup) is not a finding. Only env lines: the review
        # failed, nothing is recorded, and bin/lead-review-land.sh requeues the
        # request. Real lines beside env lines: a BLOCK on the real lines only,
        # the env lines kept as NOTEs.
        : > "$WT.rpenv"; cp "$WT.rpout" "$WT.rpreal" 2>/dev/null
        command -v rev_env_split >/dev/null 2>&1 && rev_env_split "$WT.rpout" "$WT.rpreal" "$WT.rpenv"
        # BH-6842: a stamp-order line alone is a NOTE and the review goes on.
        : > "$WT.rpstamp"
        command -v sr_stamp_split >/dev/null 2>&1 && sr_stamp_split "$WT.rpreal" "$WT.rpreal2" "$WT.rpstamp" \
          && mv -f "$WT.rpreal2" "$WT.rpreal"
        if [ -s "$WT.rpstamp" ] && [ ! -s "$WT.rpenv" ] && ! grep -q '[^[:space:]]' "$WT.rpreal"; then
          RP_STATE="clean except schema stamp order (NOTE, the merge conductor restamps before queueing)"
          RP_TAIL=$(printf 'Each line below is a stamp-order NOTE, not a BLOCK: the merge conductor renames the fragment to the current UTC minute before it queues the PR, and the lead approval is carried across that restamp commit.\n'; cat "$WT.rpstamp")
          log "rules pack red for $key on schema stamp order only ($(grep -c . "$WT.rpstamp") line(s)); a NOTE, the review goes on"
        elif [ -s "$WT.rpenv" ] && ! grep -q '[^[:space:]]' "$WT.rpreal"; then
          log "rules pack red for $key on environment failures only ($(head -n 1 "$WT.rpenv" | cut -c1-200)); review-failed, no verdict, requeued by lead-review-land"
          fail_terminal "$id" "$job" "$sha" "review-failed: env: $(head -n 1 "$WT.rpenv" | tr -d '\r' | cut -c1-300)" rules-pack; return
        else
          { printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: BLOCK\n- rules pack: red\n- reviewer model: rules-pack\n- pr body: %s\n\nFindings\n' \
              "$RVLINE" "$key" "$repo" "$pr" "$sha" "$bfp"
            awk 'NF {print "- [BLOCK] " $0}' "$WT.rpreal"
            awk 'NF {print "- [NOTE] environment, not a finding: " $0}' "$WT.rpenv"
            awk 'NF {print "- [NOTE] stamp order, the merge path restamps: " $0}' "$WT.rpstamp"
            printf '\nVERDICT: BLOCK\n'; } > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
            || { log "could not write $report"; job_update "$job" status=failed; return; }
          log "rules pack red for $key; BLOCK with no agent call"
          finish_done "$id" "$job" "$sha" BLOCK "$report" rules-pack "rules pack: red" "$key"; return  # rules-pack BLOCK: no agent call
        fi
        ;;
      *) RP_STATE="could not run (rc $rp_rc)"; RP_TAIL=$(tail -n 20 "$WT.rperr") ;;
    esac
  fi
  LR_RING_RP="$RP_STATE"
  # >>> ci-local (BH-6897)
  # CI's lint job steps on the reviewed head: the box's trusted bin/ci-local.sh
  # over the PR's own workflow, the pack already ran above. Skipped when CI's
  # lint job is green on this exact sha (the same steps, already run). A
  # quarter of what is left of the deadline. Red is a BLOCK with no agent call.
  if [ -z "$harness_repo" ] || [ "${repo,,}" != "${harness_repo,,}" ]; then CL_STATE="not applicable to $repo"
  elif ! command -v cl_run >/dev/null 2>&1; then CL_STATE="off (bin/lib/ci-local-verify.sh not on this box)"
  elif ! cl_on; then CL_STATE=off
  # HOST_SUITE=always runs everything here and reads no check runs, as the pack.
  elif [ "${HOST_SUITE:-}" != always ] && lr_ci_jobs_green "$repo" "$sha" "$WT.checks" "Syntax + shellcheck + config integrity"; then
    CL_STATE="skipped (CI lint job green on ${sha:0:12})"
  else
    left=$((DEADLINE - SECONDS)); [ "$left" -lt 240 ] && left=240
    CL_STATE=$(CL_BUDGET_CAP=$((left / 4)) cl_run "$H/bin/ci-local.sh" "$WT" "origin/$base" "$WT.cl" --skip-rules-pack 7>&- 8>&-)
    case "$CL_STATE" in
      red)
        { printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: BLOCK\n- rules pack: %s\n- ci-local: red\n- reviewer model: ci-local\n- pr body: %s\n\nFindings\n' \
            "$RVLINE" "$key" "$repo" "$pr" "$sha" "$RP_STATE" "$bfp"
          cl_findings "$WT.cl" | awk 'NF {print "- [BLOCK] " $0}'
          printf '\nVERDICT: BLOCK\n'; } > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
          || { log "could not write $report"; job_update "$job" status=failed; return; }
        log "ci-local red for $key; BLOCK with no agent call"
        finish_done "$id" "$job" "$sha" BLOCK "$report" ci-local "ci-local: red" "$key"; return  # ci-local BLOCK: no agent call
        ;;
      clean|skipped|off) ;;
      *) CL_STATE="could not run"; CL_TAIL=$(tail -n 20 "$WT.cl.stdout" 2>/dev/null) ;;
    esac
  fi
  # <<< ci-local
  # The ticket thread (BH-3546): the first `Closes #<n>` naming this repo, else
  # the first `Refs #<n>` line naming it. Both reads to files (GH_REST_STATUS
  # lives in this shell), both whole, or no thread.
  tn=""; lb="${body,,}"
  while [[ "$lb" =~ (^|[^a-z0-9_])closes[[:space:]]+(([a-z0-9_.-]+/[a-z0-9_.-]+)?#([0-9]+))(.*)$ ]]; do
    tslug="${BASH_REMATCH[3]}"; lb="${BASH_REMATCH[5]}"
    if [ -z "$tslug" ] || [ "$tslug" = "${repo,,}" ]; then tn="${BASH_REMATCH[4]}"; break; fi
  done
  if [ -z "$tn" ]; then
    # BH-5905: a partial build (BH-5798) says `Refs #<n>`; it names the same
    # ticket. Line-anchored, the prefix class of PDG_REFS_RE, so prose is not read.
    lr_refs_re='^[[:space:]#*_`]*refs[*_:[:space:]]+(([a-z0-9_.-]+/[a-z0-9_.-]+)?#([0-9]+))'
    while IFS= read -r ll; do
      [[ "$ll" =~ $lr_refs_re ]] || continue
      tslug="${BASH_REMATCH[2]}"
      if [ -z "$tslug" ] || [ "$tslug" = "${repo,,}" ]; then tn="${BASH_REMATCH[3]}"; break; fi
    done <<<"${body,,}"
  fi
  if [ -z "$THREAD_MAX" ]; then
    thread_note="(the ticket thread was not included: LEAD_REVIEW_THREAD_MAX_BYTES is unset)"
  elif [ -z "$tn" ]; then
    thread_note="(no Closes #<n> line in the PR body)"
  else
    thread_note=""; tdone=0
    gh_rest GET "repos/$repo/issues/$tn" > "$WT.issue" 2>/dev/null \
      && jq -e 'type == "object"' "$WT.issue" >/dev/null 2>&1 && tdone=1
    if [ "$tdone" = 1 ]; then
      tdone=0
      gh_rest GET "repos/$repo/issues/$tn/comments?per_page=100" > "$WT.comments" 2>/dev/null \
        && jq -e 'type == "array"' "$WT.comments" >/dev/null 2>&1 && tdone=1
    fi
# >>> ticket thread render (BH-5799)
    # Each comment's id rides under its heading (the heading line is unchanged),
    # so the reviewer can match the plan's 'Spec changes from comments' ids.
    if [ "$tdone" = 1 ]; then
      jq -r --arg n "$tn" --slurpfile c "$WT.comments" '
        "#\($n) \(.title // "")\n\n\(.body // "")\n"
        + ($c[0] | map("\n### \(.user.login // "unknown") at \(.created_at // "unknown")\n"
            + (if .id != null then "comment-id: \(.id)\n" else "" end)
            + "\n\(.body // "")\n") | join(""))
        + (if ($c[0] | length) >= 100 then "\n(first 100 comments only; the thread may have more)\n" else "" end)' \
        "$WT.issue" > "$WT.thread" 2>/dev/null || tdone=0
    fi
# <<< ticket thread render (BH-5799)
    [ "$tdone" = 1 ] || { thread_note="(the ticket thread could not be read: HTTP ${GH_REST_STATUS:-000})"
      log "ticket thread #$tn of $repo unreadable for $key (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON})"; }
  fi
  if [ -z "$thread_note" ]; then
    total=$(wc -c < "$WT.thread")
    if [ "$total" -gt "$THREAD_MAX" ]; then
      # The head is the spec, the tail the latest word: cut the middle, never the end.
      half=$((THREAD_MAX / 2))
      { head -c "$half" "$WT.thread"
        printf '\n(ticket thread cut: %s bytes, %s bytes removed from the middle to fit LEAD_REVIEW_THREAD_MAX_BYTES=%s)\n' \
          "$total" "$((total - 2 * half))" "$THREAD_MAX"
        tail -c "$half" "$WT.thread"; } > "$WT.thread.cut" && mv -f "$WT.thread.cut" "$WT.thread"
    fi
  else
    printf '%s\n' "$thread_note" > "$WT.thread"
  fi
  # The suite gets half of what is left of the deadline, the reviewer the rest.
  left=$((DEADLINE - SECONDS)); [ "$left" -lt 120 ] && left=120
  # LEAD_REVIEW_HOST_SUITE: `off` never runs it; `skip-if-ci-green` skips it only
  # when the PR's own CI passed on THIS sha (lr_ci_green; unknown = run).
  ci_ok=0
  if [ "$HOST_SUITE" = skip-if-ci-green ]; then
    git -C "$WT" show "origin/$base:.mergify.yml" > "$WT.mergify" 2>/dev/null || : > "$WT.mergify"
    if ! lr_ci_green "$repo" "$sha" "$WT.mergify" "$WT.checks"; then
      log "$key: host suite runs (CI not known green on ${sha:0:12}: $LR_CI_WHY)"
    # CI's green is the PR's own CI: a PR that edits what CI runs earns no skip.
    elif lr_ci_cfg_touched "$WT" "origin/$base" "$sha"; then log "$key: host suite runs ($LR_CICFG_WHY)"
    else ci_ok=1; fi
  fi
  # A skipped or off suite still tells the reviewer, in the suite's own section,
  # that no test ran on this box, so a bare MERGE never rests on local evidence.
  if [ "$HOST_SUITE" = off ]; then
    log "$repo: host suite not run (LEAD_REVIEW_HOST_SUITE=off, fleet-wide); no verification ran on this box for $key"
    suite_line="host suite: off (LEAD_REVIEW_HOST_SUITE)"
    printf '%s\n' "No host suite ran on this head: LEAD_REVIEW_HOST_SUITE=off turns it off on every repo. Treat this as a repo with no declared suite." > "$WT.suite"
  elif [ "$ci_ok" = 1 ]; then
    suite_line="host suite: skipped (CI green on ${sha:0:12}: $LR_CI_N checks)"
    printf '%s\n' "The host suite was not run on this box. CI's required checks passed on this exact head ${sha:0:12}: $(printf '%s' "$LR_CI_REQ" | sed 's/^/"/; s/$/"/' | paste -sd, - | sed 's/,/, /g'). That is the only test evidence for this review, and CI may run only part of the repo's tests on a PR head. Do not claim local test evidence." > "$WT.suite"
  elif suite_cmd=$(lr_verify_cmd "$WT/CLAUDE.md"); then
    ( cd "$WT" && timeout "$((left / 2))" bash -c "$suite_cmd" ) 7>&- 8>&- > "$WT.suite" 2>&1; suite_rc=$?
    suite_line="host suite: $suite_cmd rc=$suite_rc"
  else
    suite_line="host suite: no host suite declared"; : > "$WT.suite"
  fi
  # >>> delta mode (BH-5294). bin/lead-review-enqueue.sh asks for it with
  # `lead-delta:<G>` in scope_notes, when the lead approved head G and the PR's
  # own files changed by a few lines since. The reviewer then reads G's report
  # (this box's state/lead-reviews/lr-<pr>-<G12>.md, header checked), the
  # inter-diff G..head and the conflict resolutions (bin/lib/lead-delta.sh
  # ld_build), in place of the branch diff. Same model_for lead.review route:
  # only what it reads changes. Any unknown (no lib, no report here, G not
  # fetchable, the delta over its byte cap) is a full review, logged.
  # BH-5582: `protected:<p1>,<p2>` in the same note names the lead protected
  # files in the delta; each gets a full-scrutiny line in the header. A token
  # with an empty or unplain path is a full review.
  dmode=""; dprev=""; dline=""; dsn=$(jq -r '.scope_notes // ""' <<<"$r"); dprot=(); dbad=0
  if [[ "$dsn" =~ (^|[^a-z])lead-delta:([0-9a-f]{40})($|[^0-9a-f]) ]]; then
    dprev="${BASH_REMATCH[2]}"
    dreport="$H/state/lead-reviews/lr-$pr-${dprev:0:12}.md"
    dre='(^|[ ;])protected:([^ ;]*)'
    if [[ "$dsn" =~ $dre ]]; then
      IFS=, read -ra dprot <<<"${BASH_REMATCH[2]},"
      [ "${#dprot[@]}" -gt 0 ] || dbad=1
      for dpf in "${dprot[@]}"; do [[ "$dpf" =~ ^[A-Za-z0-9._/@+-]+$ ]] || dbad=1; done
    fi
    if ! command -v ld_build >/dev/null 2>&1; then dline="bin/lib/lead-delta.sh not loaded"
    elif [ "$dbad" = 1 ]; then dline="protected list unreadable"
    elif [ ! -f "$dreport" ] || [ "$(lr_report_title "$dreport")" != "# Lead review lr-$pr-${dprev:0:12} ($repo#$pr at $dprev)" ]; then
      dline="the lead report for ${dprev:0:12} is not on this box"
    else
      git -C "$REPO_DIR" fetch -q origin "$dprev" >/dev/null 2>&1
      dline=$(ld_build "$REPO_DIR" "origin/$base" "$dprev" "$sha" "$WT.delta") && dmode=delta
    fi
    if [ "$dmode" = delta ]; then log "$key: delta review from ${dprev:0:12} ($dline bytes), model $model"
    else log "$key: delta review from ${dprev:0:12} not possible (${dline:-unknown}); full review"; fi
  fi
  if [ "$dmode" = delta ]; then
    { printf 'DELTA REVIEW. The lead already reviewed this PR at %s; that report is under "Prior lead report" below. The head has moved to %s since. Review only what changed: the inter-diff of the PR'"'"'s own files and the conflict resolutions below. Confirm the earlier findings still hold and the resolution did not break or drop anything. If the change is too large or too unclear to judge from the delta alone, say so and answer BLOCK.\n' "${dprev:0:12}" "${sha:0:12}"
      for dpf in "${dprot[@]}"; do
        printf 'PROTECTED FILE %s: a lead protected path. Read every changed line of it in the delta with full scrutiny, the same as in a full review.\n' "$dpf"
      done
      printf '\n## Prior lead report\n'
      cat "$dreport"
      printf '\n## Delta\n'
      cat "$WT.delta"; } > "$WT.diff"
  else
  git -C "$WT" diff "origin/$base...$sha" > "$WT.diff" 2>&1 || echo "(the diff could not be read)" >> "$WT.diff"
  fi
  # <<< delta mode
  # >>> intent review (BH-6967, header). A misconfiguration (no route, no prompt
  # file) is the full review: it never lowers the depth of a review. The tokens
  # count only as the LAST group of the notes, where bin/lead-review-enqueue.sh
  # puts them (it rewrites the same words anywhere else), and only while the
  # protected row risk_tier.medium_mode reads intent HERE too: a forged note
  # cannot go around the row. The setting and route reads are network reads,
  # so fd 7 and 8 are closed for them.
  imode=""
  ire='(^|; )review-tier:medium review-mode:intent$'
  if [ -z "$dprev" ] && [[ "$dsn" =~ $ire ]]; then
    imm=$(setting_get risk_tier.medium_mode 2>/dev/null 7>&- 8>&-) || imm=""
    imm=$(printf '%s' "$imm" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [ "$imm" != intent ]; then log "$key: full review (risk_tier.medium_mode reads '${imm:-no value}', not intent)"
    elif [ ! -r "$H/prompts/lead-review.d/intent.md" ]; then log "$key: full review (prompts/lead-review.d/intent.md missing)"
    elif ! imodel=$(model_for review-intent "$project" 2>/dev/null 7>&- 8>&-) || [ -z "$imodel" ]; then log "$key: full review (no review-intent route)"
    else imode=intent; model="$imodel"; log "$key: intent review (risk tier medium, route review-intent), model $model"
    fi
  fi
  # <<< intent review
  # >>> cap-reached re-review (BH-7123 wave B). bin/blocked-resolver.sh asked
  # for this review after the ticket spent its fix-round cap on findings none
  # of which is an ALWAYS-BLOCK class (br_cap_notes): the scope token
  # `review-level:cap-reached` on a fresh request, or — when the head's request
  # row was already done and was reset instead — the ledger row
  # review_cap "<repo>#<pr>@<head>" = cap-reached. Either makes this ONE review
  # run rl_cap in cowboy mode (REVIEW_LEVEL_MODE, which rl_knob honours above
  # every row): every finding without an ALWAYS-BLOCK class is a NOTE and the
  # verdict lands MERGE-WITH-NOTES; the floor still stands. The ledger read is a
  # network read, so fd 7 and 8 are closed for it.
  rlcap=""
  if [[ "$dsn" =~ (^|[[:space:];])review-level:cap-reached([[:space:];]|$) ]]; then rlcap=scope
  elif command -v job_ledger_get >/dev/null 2>&1 \
       && [ "$(job_ledger_get review_cap "$repo#$pr@$sha" 2>/dev/null 7>&- 8>&- </dev/null)" = cap-reached ]; then rlcap=ledger
  fi
  [ -z "$rlcap" ] || log "$key: notes-only re-review (the fix-round cap is spent, $rlcap): every finding without an ALWAYS-BLOCK class is a NOTE"
  # <<< cap-reached re-review
  # >>> re-review (BH-6391): a `lead-prev:<G>` group in scope_notes (set by
  # bin/lead-review-enqueue.sh) adds a `## Re-review` prompt section: G, its
  # word, the own commits and files and the main files since G, and G's report
  # (delta mode already shows it). After a BLOCK on an approved G, lpv_downgrade
  # keeps each finding on a line unchanged since G as a NOTE.
  rm -f "$WT.rereview" "$WT.lpvmain" "$WT.lpvown"
  if command -v lpv_parse >/dev/null 2>&1 && lpv_parse "$dsn"; then
    lpv=1
    git -C "$REPO_DIR" fetch -q origin "$LPV_PREV" >/dev/null 2>&1
    LPV_MAINF=""; LPV_OWNF=""
    lpv_section "$REPO_DIR" "origin/$base" "$pr" "$repo" "$sha" "$H/state/lead-reviews" "$([ "$dmode" = delta ] && echo 0 || echo 1)" > "$WT.rereview" 2>/dev/null
    printf '%s\n' "$LPV_MAINF" > "$WT.lpvmain"
    printf '%s\n' "$LPV_OWNF" > "$WT.lpvown"
    log "$key: re-review of ${LPV_PREV:0:12} ($LPV_WORD)"
  fi
  # <<< re-review
  # Over the limit, a full review reads the diff in parts (bin/lib/lead-diff-parts.sh):
  # ldp_rc 0 = $WT.parts replaces the diff; 2 = the PR's own tests do not fit.
  # A cut diff never reaches the reviewer (lead review BLOCK at b5426ef9d: a cut
  # diff with no `## Diff coverage` could get a bare MERGE). Every other case over
  # the limit (no lib, ldp_build rc 1, a delta over the limit) is ldp_rc 3: no
  # model call and the same split-required BLOCK, naming the reason.
  dbytes=$(wc -c < "$WT.diff" | tr -d ' ')
  ldp_why=""
  if [ "$dbytes" -gt "$DIFF_MAX" ]; then
    if [ "$dmode" = delta ]; then
      ldp_rc=3; ldp_why="the delta from ${dprev:0:12} is $dbytes bytes, over the review limit, and a delta is not read in parts"
    elif command -v ldp_build >/dev/null 2>&1; then
      ldp_build "$WT" "origin/$base" "$sha" "$DIFF_MAX" "$WT.parts" "$WT.split" any 2>>"$LOG"; ldp_rc=$?
      case "$ldp_rc" in 0|2) ;; *) ldp_why="the diff ($dbytes bytes) could not be read in parts (rc $ldp_rc)"; ldp_rc=3 ;; esac
      # Nothing merges unread (the operator, #5803): a file not read, test or not, is
      # split required, whatever the lib answered.
      [ "$ldp_rc" = 0 ] && [ -n "$LDP_UNREAD" ] && ldp_rc=2
    else
      ldp_rc=3; ldp_why="the diff is $dbytes bytes and bin/lib/lead-diff-parts.sh is not loaded, so it could not be read in parts"
    fi
    case "$ldp_rc" in
      0) log "$key: diff $dbytes over $DIFF_MAX: read in parts, $(printf '%s' "$LDP_UNREAD" | grep -c .) files not read" ;;
      2) log "$key: diff $dbytes over $DIFF_MAX: split required" ;;
      *) log "$key: diff $dbytes over $DIFF_MAX: $ldp_why; split required, no model call" ;;
    esac
  fi
  if [ "$ldp_rc" = 3 ]; then
    { printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: BLOCK\n- review mode: split required (%s)\n- %s\n- rules pack: %s\n- reviewer model: none:split-required\n- checklist: v%s\n\n' \
        "$RVLINE" "$key" "$repo" "$pr" "$sha" "$ldp_why" "$suite_line" "$RP_STATE" "$CK_VER"
      printf 'Findings\n- [BLOCK split-required] %s. No reviewer reads a cut diff, so this PR must be split under the %s-byte review limit; this is not a finding on the code.\n\n' \
        "$ldp_why" "$DIFF_MAX"
      printf 'VERDICT: BLOCK\n'; } > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
      || { log "could not write $report"; job_update "$job" status=failed; return; }
    finish_done "$id" "$job" "$sha" BLOCK "$report" "none:split-required" "$suite_line" "$key"; return
  fi
  if [ "$ldp_rc" = 2 ]; then
    nprod=$(( $(printf '%s' "$LDP_UNREAD" | grep -c .) - LDP_TEST_UNREAD ))
    if [ "$LDP_TEST_UNREAD" -gt 0 ]; then
      ldp_mode="the PR's own tests do not fit LEAD_REVIEW_DIFF_MAX_BYTES=$DIFF_MAX"
      ldp_find="$LDP_TEST_UNREAD of $LDP_TEST_FILES test files do not fit the $DIFF_MAX-byte review limit; this is not a finding on the code. Not read: $(ldp_unread_line)."
    else
      ldp_mode="$nprod file$([ "$nprod" = 1 ] || echo s) that $([ "$nprod" = 1 ] && echo is || echo are) not a test do$([ "$nprod" = 1 ] && echo es) not fit LEAD_REVIEW_DIFF_MAX_BYTES=$DIFF_MAX; nothing merges unread"
      ldp_find="$nprod file$([ "$nprod" = 1 ] && echo " that is not a test does" || echo "s that are not tests do") not fit the $DIFF_MAX-byte review limit, and nothing merges unread (the operator, #5803): $(ldp_unread_line). This is not a finding on the code."
    fi
    { printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: BLOCK\n- review mode: split required (%s)\n- %s\n- rules pack: %s\n- reviewer model: none:split-required\n- checklist: v%s\n\n' \
        "$RVLINE" "$key" "$repo" "$pr" "$sha" "$ldp_mode" "$suite_line" "$RP_STATE" "$CK_VER"
      printf 'Findings\n- [BLOCK split-required] %s\n\n## Proposed split\n' "$ldp_find"
      if [ -s "$WT.split" ]; then cat "$WT.split"; else printf 'No split was proposed (the parts reader did not write one). Split the change so each part reads whole under the limit.\n'; fi
      printf '\n'
      awk '$0 == "## Diff" {exit} {print}' "$WT.parts"
      printf 'VERDICT: BLOCK\n'; } > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
      || { log "could not write $report"; job_update "$job" status=failed; return; }
    log "$key: split required ($LDP_TEST_UNREAD test files not read$([ "$nprod" -gt 0 ] && printf ', %s other files not read' "$nprod")); no model call"
    finish_done "$id" "$job" "$sha" BLOCK "$report" "none:split-required" "$suite_line" "$key"; return
  fi
  # >>> conflict hotspots (BH-5271). The request's project's measured hotspot
  # files (bin/lib/hotspot-context.sh, knob PLAN_CONTEXT_HOTSPOT_TOP), for
  # checklist item 9. A network read, so fd 7 is closed; any failure is a
  # labelled line in the section, never a skipped review.
  if command -v hc_section >/dev/null 2>&1; then
    hc_section "$project" > "$WT.hotspots" 2>>"$LOG" 7>&- 8>&-
    log "$key: conflict hotspots ${HC_STATE:-unknown}"
  else
    echo 'COULD NOT READ: bin/lib/hotspot-context.sh is not loaded (tool failure, not "no hotspots").' > "$WT.hotspots"
    log "$key: conflict hotspots unknown"
  fi
  # The live-probe evidence (BH-5801): only the harness App's comment for this
  # head counts. A network read, so fd 7 is closed, as for the hotspots.
  if command -v lp_evidence >/dev/null 2>&1; then
    lp_evidence "$repo" "$pr" "$sha" > "$WT.probes" 2>>"$LOG" 7>&-
  else
    echo '(no live-probe evidence: bin/lib/live-probes.sh is not loaded)' > "$WT.probes"
  fi
  # The builder review of this exact head (BH-5355, header). A network read,
  # so fd 7 is closed; every miss is a full review, logged.
  if [ "$dmode" = delta ] || [ "$imode" = intent ]; then :
  elif [ "$BUILDS_ON" != on ]; then log "$key: full review (LEAD_REVIEW_BUILDS_ON_BUILDER=$BUILDS_ON)"
  elif ! command -v br_fetch >/dev/null 2>&1; then log "$key: full review (bin/lib/builder-review.sh not loaded)"
  elif [ ! -r "$H/prompts/lead-review-builds-on.md" ]; then log "$key: full review (prompts/lead-review-builds-on.md missing)"
  elif br_fetch "$repo" "$pr" "$sha" "$WT.builder" 7>&- 8>&-; then
    bmode=build-on; bline="builds on builder review $BR_VERDICT at ${sha:0:12}"; log "$key: $bline"
  else
    log "$key: full review ($BR_WHY)"
  fi
  pf="$WT.prompt"
  { cat "$H/prompts/lead-review.md"
    printf '\n'
    if [ "$imode" = intent ]; then
      cat "$H/prompts/lead-review.d/intent.md"
    else
    cat "$H/prompts/lead-review-checklist.md"
    if [ "$bmode" = build-on ]; then
      printf '\n'
      cat "$H/prompts/lead-review-builds-on.md"
    fi
    fi
    printf '\n## PR\n%s\n\n%s\n\n## Ticket thread\n' "$title" "$body"
    cat "$WT.thread"
    printf '\n## Scope notes\n%s\n\n## Prior verdict\n%s\n\n## Rules pack\n%s\n' \
      "$(jq -r '.scope_notes // "none"' <<<"$r")" "$(jq -r '.prior_verdict_ref // "none"' <<<"$r")" "$RP_STATE"
    case "$RP_STATE" in
      "skipped (CI green"*|"clean except schema stamp order"*) printf '%s\n' "$RP_TAIL" ;;
      *) [ -n "$RP_TAIL" ] && printf 'stderr tail:\n%s\n' "$RP_TAIL" ;;
    esac
    [ -s "$WT.rereview" ] && { printf '\n## Re-review\n'; cat "$WT.rereview"; }
    printf '\n## Host suite\n%s\n' "$suite_line"
    tail -n 80 "$WT.suite"
    printf '\n## CI local\n%s\n' "$CL_STATE"
    [ -n "$CL_TAIL" ] && printf 'output tail:\n%s\n' "$CL_TAIL"
    lr_gate_record_section
    printf '\n## Live probes\n'
    cat "$WT.probes"
    printf '\n## Conflict hotspots\n'
    cat "$WT.hotspots"
    if [ "$bmode" = build-on ]; then
      printf '\n## Builder review (same head)\n'
      cat "$WT.builder"
    fi
    if [ "$ldp_rc" = 0 ]; then
      printf '\n'; cat "$WT.parts"
    else
    # At or under the limit here: an over-limit diff left above as parts or a BLOCK.
    printf '\n## Diff\n'
    cat "$WT.diff"
    fi
  } > "$pf"
  out="$WT.out"
  left=$((DEADLINE - SECONDS)); [ "$left" -lt 60 ] && left=60
  # BH-2537: both calls name the PR for the cost row. $key is a job key, not a ticket.
  # The guard key lfp (lead-head) is set before the rules pack (BH-7792, above).
  # BH-5355: the cost row says which prompt this was, so the ledger splits by mode.
  lnote="lead-mode=${dmode:-${imode:-${bmode:-full}}}"
  AGENT_CALL_GUARD_STAGE="$lstage" AGENT_CALL_FP="$lfp" AGENT_CALL_ROW_NOTE="$lnote" \
  AGENT_CALL_PR="${repo:+https://github.com/$repo/pull/$pr}" AGENT_CALL_ROLE=lead.review "$H/bin/agent-call.sh" lead-review "$project" "$model" "$left" "$out" "@$pf" >/dev/null 2>&1; rc=$?
  if [ "$rc" -lt 74 ] || [ "$rc" -gt 79 ]; then
    lr_rate_limited "$rc" "$out" && { lr_release_rl "$key" "$job" "$rc"; return; }
    # The per-PR tripwire counts reviews the model answered, once a review (the
    # unknown-verdict retry is the same review). A refusal before billing and a
    # rate limit are not marked.
    [ "$MODE" = tick ] && lw_pr_day_mark "$repo" "$pr"
    verdict=unknown; lr_pick_review "$out" "$key" && verdict=$(lr_verdict "$out")
    if [ "$verdict" = unknown ] && [ "$lunread" != 1 ]; then
      out="$WT.out2"
      if [ -n "$lfp" ]; then
        if [ "$bchg" = 1 ] && rsn=$(lr_body_reason "$bfp" nv); then lfp=$(lead_fp "$repo" "$pr" "$sha" "$rsn")
        else lfp=$(lead_fp "$repo" "$pr" "$sha" noverdict); fi
      fi
      AGENT_CALL_GUARD_STAGE="$lstage" AGENT_CALL_FP="$lfp" AGENT_CALL_ROW_NOTE="$lnote" \
      AGENT_CALL_PR="${repo:+https://github.com/$repo/pull/$pr}" AGENT_CALL_ROLE=lead.review "$H/bin/agent-call.sh" lead-review "$project" "$model" "$left" "$out" "@$pf" >/dev/null 2>&1; rc=$?
      lr_rate_limited "$rc" "$out" && { lr_release_rl "$key" "$job" "$rc"; return; }
      verdict=unknown; lr_pick_review "$out" "$key" && verdict=$(lr_verdict "$out")
    fi
  fi
  if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
    log "agent-call refused $key (rc=$rc, nothing billed); request left for the next tick"
    # BH-7792: the claim goes back at once (lr_release_claim).
    lr_release_claim "$id" "$job" "$key" "agent-call rc $rc: nothing billed"; return
  fi
  if [ "$verdict" = unknown ]; then
    log "no readable review (findings and a verdict) from $model for $key $([ "$lunread" = 1 ] && echo "on the extra ~unread call" || echo "after one retry")"
    printf '%s\nreset=%s\n' "$model" "$resets" > "$empty.tmp.$$" && mv -f "$empty.tmp.$$" "$empty" || log "could not write $empty"
    job_artifact_put lead_review_report "$empty" "$(jq -nc --arg p "$empty" --arg m "$model" '{empty:true,path:$p,model:$m}')" "$job" \
      || log "empty artifact put for $key failed"
    fail_terminal "$id" "$job" "$sha" empty "$model"
    [ "$lunread" = 1 ] && command -v lu_alert >/dev/null 2>&1 && lu_alert "$project" "$repo" "$pr" "$sha" "$lspent" "second unreadable answer"
    return
  fi
  # BH-6391: a BLOCK after an approved head keeps its findings on unchanged lines as NOTEs.
  if [ "$verdict" = BLOCK ] && [ "$lpv" = 1 ] && { [ "$LPV_WORD" = MERGE ] || [ "$LPV_WORD" = MERGE-WITH-NOTES ]; }; then
    lprc=0
    if cp -f "$out" "$out.lpvkeep" 2>/dev/null; then
      lpk=$(lpv_downgrade "$REPO_DIR" "$LPV_PREV" "$sha" "$out" "$WT.lpvmain" "$WT.lpvown") || lprc=$?
    else lprc=5
    fi
    # Fail closed: a rewrite whose verdict no longer reads restores the model's answer.
    if [ "$lprc" = 0 ] && [ "$(lr_verdict "$out")" = unknown ]; then
      mv -f "$out.lpvkeep" "$out" && lprc=3 || lprc=4
    fi
    rm -f "$out.lpvkeep"
    case "$lprc" in
      0) verdict=$(lr_verdict "$out")
         log "$key: $lpk BLOCK finding(s) on lines unchanged since ${LPV_PREV:0:12} kept as NOTE; verdict $verdict" ;;
      3) lpk=""; log "$key: re-review rewrite left no readable verdict; the model's BLOCK stands" ;;
      4) lpk=""; log "$key: re-review rewrite left no readable verdict and the answer could not be restored; BLOCK" ;;
      5) lpk=""; log "$key: re-review check could not copy the answer; the model's BLOCK stands" ;;
      2) lpk=""; log "$key: re-review check could not read git; the model's BLOCK stands" ;;
      *) lpk="" ;;
    esac
  fi
  # >>> break-it (BH-6970): bin/lib/break-it.sh. Runs on a medium or high tier
  # token (the last notes group) while break_it.mode reads shadow or enforce.
  # enforce + failed:<k> adds a [BLOCK wrong-data] finding to $out (birw=1).
  bires=""; bimode=off; birw=0; printf '%s\n' "$body" > "$WT.bibody"
  command -v bi_review >/dev/null 2>&1 && read -r bires bimode birw < <(bi_review "$repo" "$pr" "$sha" "$project" "$WT" \
    "$base" "$dsn" "$title" "$out" "$((DEADLINE - SECONDS))" "$WT.issue" "$WT.bibody")
  bires="${bires:-skipped:nolib}"; log "$key: break-it: $bires (mode ${bimode:-off})"
  [ "$birw" = 1 ] && verdict=$(lr_verdict "$out")
  case "$bires" in skipped:*) ;; *) biline="- break-it (BH-6970): $bires (mode $bimode)"$'\n' ;; esac
  # <<< break-it
  # BH-7123: the review level cap, after the re-review downgrade and before the
  # outcome cap (BH-8338: an INCONCLUSIVE claim adds a NOTE below, or a BLOCK
  # with its own finding line on a perf-gate ticket).
  # Fail closed like lpv_downgrade: a rewrite whose verdict no longer reads
  # restores the model's answer. strict/shadow modes rewrite nothing (rc 1).
  rlk=""; rlgl=0
  if [ "$verdict" = BLOCK ] && command -v rl_cap >/dev/null 2>&1; then
    rlrc=0
    # --golive (wave B): a go-live human step becomes `- [HUMAN go-live] <step>`
    # and gates nothing while review.golive_gates_merge reads 0; the land lane
    # places it on the ticket from the result detail's golive:N. A cap-reached
    # re-review (rlcap, above) runs the demoter in cowboy mode for this one call.
    rlgo=stand; command -v rl_golive_opt >/dev/null 2>&1 && rlgo=$(rl_golive_opt "$project" 2>/dev/null 7>&- 8>&-)
    if cp -f "$out" "$out.rlkeep" 2>/dev/null; then
      if [ -n "$rlcap" ]; then
        rlk=$(REVIEW_LEVEL_MODE=cowboy rl_cap "$out" "$project" --approve MERGE-WITH-NOTES --block BLOCK --lens lead --golive "$rlgo" 2>"$WT.rlnote") || rlrc=$?
      else
        rlk=$(rl_cap "$out" "$project" --approve MERGE-WITH-NOTES --block BLOCK --lens lead --golive "$rlgo" 2>"$WT.rlnote") || rlrc=$?
      fi
      rlgl=$(printf '%s' "$rlk" | sed -nE 's/.* golive=([0-9]+).*/\1/p'); case "$rlgl" in ''|*[!0-9]*) rlgl=0 ;; esac
    else rlrc=5
    fi
    if [ "$rlrc" = 0 ] && [ "$(lr_verdict "$out")" = unknown ]; then
      mv -f "$out.rlkeep" "$out" && rlrc=3 || rlrc=4
    fi
    rm -f "$out.rlkeep"
    case "$rlrc" in
      0) verdict=$(lr_verdict "$out"); log "$key: review level: $rlk; verdict $verdict" ;;
      1) log "$key: review level: ${rlk:-no rewrite}"; rlk="" ;;
      3) log "$key: review level rewrite left no readable verdict; the model's BLOCK stands"; rlk="" ;;
      4) log "$key: review level rewrite left no readable verdict and the answer could not be restored; BLOCK"; rlk="" ;;
      *) log "$key: review level cap rc $rlrc; the model's BLOCK stands"; rlk="" ;;
    esac
    while IFS= read -r ll; do [ -n "$ll" ] && log "$key: $ll"; done < "$WT.rlnote" 2>/dev/null
    rm -f "$WT.rlnote"
  fi
  # BH-6372.3: the outcome cap. The ticket is the one the thread read (when it
  # read), else loc_cap reads #$tn itself; no ticket number is class unknown.
  # BH-8338: line 1 the verdict, line 3 the finding line (lr_cap_body).
  capr=""; capfind=""
  if command -v loc_cap >/dev/null 2>&1; then
    printf '%s\n' "$body" > "$WT.capbody"; capf=""; ctitle=""; clabels=""
    if [ -n "$tn" ] && [ -z "$thread_note" ] && jq -r '.body // ""' "$WT.issue" > "$WT.capticket" 2>/dev/null; then
      capf="$WT.capticket"; ctitle=$(jq -r '.title // ""' "$WT.issue"); clabels=$(jq -r '[.labels[]?.name] | join(",")' "$WT.issue")
    fi
    capo=$(loc_cap "$verdict" "$WT.capbody" "$capf" "$ctitle" "$clabels" ${tn:+"$repo" "$tn"} 2>"$WT.capnote") \
      && { verdict=$(sed -n 1p <<<"$capo"); capr=$(sed -n 2p <<<"$capo"); capfind=$(sed -n 3p <<<"$capo")
           log "$key: outcome cap: $capr; verdict $verdict"; }
    while IFS= read -r ll; do [ -n "$ll" ] && log "$key: $ll"; done < "$WT.capnote"
  fi
  # The report names the checklist it read; an intent review read none.
  ckl="v$CK_VER"; [ "$imode" = intent ] && ckl="none (intent review)"
  # BH-7123: every report names the mode it was judged under, with the cap
  # summary when the cap ran (a BLOCK answer). It sits ABOVE `- pr body:`, which
  # readers treat as the last header line before the agent's text
  # (tests/lead-review-inconclusive-block.bh-6381-test.sh L2).
  { printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: %s\n- %s\n- rules pack: %s\n- reviewer model: %s\n- checklist: %s\n- review level (BH-7123): mode %s%s\n- ci-local: %s\n%s- pr body: %s\n' \
      "$RVLINE" "$key" "$repo" "$pr" "$sha" "$verdict" "$suite_line" "$RP_STATE" "$model" "$ckl" "$(rl_mode "$project" 2>/dev/null || echo unknown)" "${rlk:+; $rlk}" "${CL_STATE:-not run}" "$biline" "$bfp"
    [ -n "$capr" ] && printf -- '- outcome cap: %s\n' "$capr"
    # BH-7123 wave B: a cap-reached (notes-only) re-review says so under the header.
    [ -n "$rlcap" ] && printf -- '- review level (BH-7123): cap-reached notes-only re-review (%s): the fix-round cap is spent; every finding without an ALWAYS-BLOCK class is a NOTE\n' "$rlcap"
    [ "$dmode" = delta ] && printf -- '- review mode: delta from %s\n' "$dprev"
    [ "$bmode" = build-on ] && printf -- '- review mode: %s\n' "$bline"
    [ "$imode" = intent ] && printf -- '- review mode: intent (risk tier medium, route review-intent)\n'
    [ -n "$lpk" ] && printf -- '- re-review: from %s (%s); %s BLOCK finding(s) on lines unchanged since then kept as NOTE\n' "${LPV_PREV:0:12}" "$LPV_WORD" "$lpk"
    [ "$ldp_rc" = 0 ] && printf -- '- diff read in parts: %s of %s files; not read: %s; digest: %s files\n' \
      "$LDP_READ_FILES" "$LDP_TOTAL_FILES" "$(ldp_unread_line)" "$LDP_DIGEST_FILES"
    printf '\n'
    if [ -n "$capr" ]; then lr_cap_body "$out" "$capfind" "$verdict"; else cat "$out"; fi
  } > "$report.tmp.$$" && mv -f "$report.tmp.$$" "$report" \
    || { log "could not write $report"; job_update "$job" status=failed; return; }
  # BH-7123 wave B: the go-live count rides on the result row's detail, so
  # bin/lead-review-land.sh reads the report only for a MERGE that noted one.
  LR_DONE_DETAIL=""; [ "${rlgl:-0}" -gt 0 ] 2>/dev/null && LR_DONE_DETAIL="golive:$rlgl"
  # BH-6970: and the break-it result, which bin/lead-review-land.sh posts as --break-it.
  case "$bires" in clean|could-not-run|failed:*) LR_DONE_DETAIL="${LR_DONE_DETAIL:+$LR_DONE_DETAIL }break-it:$bires" ;; esac
  lr_block_no_finding "$verdict" "$report" && { log "$key: BLOCK report has no '- [BLOCK' finding line; refused (outcome failed, detail block-no-finding)"
    LR_DONE_DETAIL=""; fail_terminal "$id" "$job" "$sha" block-no-finding "$model"; return; }
  finish_done "$id" "$job" "$sha" "$verdict" "$report" "$model" "$suite_line" "$key"
  LR_DONE_DETAIL=""
}

# The heartbeat (BH-5351, header) logs to the lane log. Its interval is read
# inside each beater (lr_beat_start auto), never on the serial claim path.
LR_BEAT_LOG="$LOG"

# one <request-id> (BH-5023): the in-build lead-grade review. bin/inbuild-lead-review.sh
# filed the request for the head its build just pushed, and this reviews THAT
# request now, through review_one, so the prompt, checklist, model route, rules
# pack, suite, thread, paid-once ledger and result post are the tick's own. No
# tick lock (fd 7 is the tick's dedupe; job_open rc 9 and the claim's 409 stop a
# double run) and no box-ownership filter (the build owns this head).
# rc 0 = done, 3 = superseded, 2 = skipped (not requested any more, or no
# route / job), 1 = failed or unreadable.
if [ "$MODE" = one ]; then
  ONE=$(lr_get "/$ONE_ID" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { log "one $ONE_ID: request unreadable (rc=$rc)"; exit 1; }
  r=$(jq -c '.request // empty' <<<"$ONE" 2>/dev/null)
  repo=$(jq -r '.repo // empty' <<<"$r" 2>/dev/null); pr=$(jq -r '.pr // empty' <<<"$r" 2>/dev/null)
  sha=$(jq -r '.head_sha // empty' <<<"$r" 2>/dev/null); st=$(jq -r '.status // empty' <<<"$r" 2>/dev/null)
  if ! [[ "$pr" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ && "$(jq -r '.id // empty' <<<"$r")" = "$ONE_ID" ]]; then
    log "one $ONE_ID: malformed request: $(head -c 200 <<<"$r")"; exit 1
  fi
  [ "$st" = requested ] || { log "one $ONE_ID: request is $st; not reviewed again"; exit 2; }
  project=$(awk -v r="$repo" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
  [ -n "$project" ] || { log "one $ONE_ID: no fleet.conf project for $repo"; exit 1; }
  review_one "$r" "$project"; cleanup
  log "one $ONE_ID: ${R:-skipped}"
  case "$R" in done) exit 0 ;; superseded) exit 3 ;; failed) exit 1 ;; *) exit 2 ;; esac
fi
# item <project> <item-file> <mode> <word-file> (BH-8027): one pool LR- row on
# a Fly machine, through review_one (bin/lib/lead-review/item.sh, lr_item_run).
if [ "$MODE" = item ]; then lr_item_run; exit $?; fi

# A tick DEDUPE, never a wait (BH-3930): a lead review runs 7-9 minutes, and a
# second tick on the same request paid for it twice. fd 7 is held while the
# tick decides and starts (BH-6984: released when starts close, before the wait
# for running reviews); the agent call inherits it, so a tick killed while it
# starts keeps the lock until that call ends too. The host suite and the rules
# pack are repo code and run with fd 7 closed, so a process they leave behind
# never pins it. cleanup never touches it. A tick that finds it held owes a
# rerun (BH-5317): the holder relaunches one tick when it unlocks.
STATE="$H/state/lead-review"; mkdir -p "$H/locks" "$STATE"
exec 7>"$H/locks/lead-review-tick.lock"
# BH-5945: the holder stamps when it took the lock, so a skipped tick logs how
# long the holder has held it, and lr_unlock logs how long this tick held it.
if ! flock -n 7; then
  : > "$STATE/rerun-owed"; since=$(head -c 20 "$STATE/tick-lock.since" 2>/dev/null); since=${since//[!0-9]/}
  log "tick skipped: the previous tick still holds locks/lead-review-tick.lock (a review is running) held $([ -n "$since" ] && echo "$(( $(date +%s) - 10#$since ))" || echo '?')s (rerun owed)"; exit 0
fi
LR_LOCK_T0=$SECONDS; date +%s > "$STATE/tick-lock.since" 2>/dev/null
mkdir -p "$H/tmp"
lw_pr_day_prune
ME=$(local_box_name)
# Spillover knobs (BH-5284): off unless the row says 1.
SPILL_ON=0; [ "${LEAD_REVIEW_SPILLOVER:-0}" = 1 ] && SPILL_ON=1
SPILL_AFTER=$(knob LEAD_REVIEW_SPILL_AFTER_S "${LEAD_REVIEW_SPILL_AFTER_S:-900}" 900)
NOW_EPOCH=$(date +%s); spill=0
declare -A PROJ BOX OWNED_REPO
# The worklist (BH-4956, header), first. LEAD_REVIEW_AUTO_REPOS is
# lead-review-land's knob, read in a subshell so that lane's other knobs stay
# out of this one. Unset or empty = no worklist: the request rows alone.
# LEAD_REVIEW_WORKLIST (default 1, BH-5878) must be 1 too. The enqueue's holds
# run as the gates of bin/lib/lead-gates.d/ before each worklist start (#5870).
# bin/lead-review-enqueue.sh still writes request rows; a head it requested is
# reviewed once (lr_start rc 3, gate 20). A row =0 turns the worklist off.
AUTO_REPOS=""
case "${LEAD_REVIEW_WORKLIST:-1}" in
  1) AUTO_REPOS=$(command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lead-review-land >/dev/null 2>&1
       [ -n "${LEAD_REVIEW_AUTO_REPOS+x}" ] && printf '%s' "$LEAD_REVIEW_AUTO_REPOS") ;;
  0) ;;
  *) log "LEAD_REVIEW_WORKLIST='${LEAD_REVIEW_WORKLIST}' is not 0 or 1; no worklist this tick" ;;
esac
WL_N=0 WL_READ=0 WL_SPILL=0
: > "$QF.wl"; : > "$QF.wlspill"
if [ -z "$PARTICIPANT" ] && [ -n "${AUTO_REPOS// /}" ] && [ "$LG_OK" != 1 ]; then
  log "bin/lib/lead-gates.sh missing; no worklist item starts this tick"; AUTO_REPOS=""
fi
if [ -z "$PARTICIPANT" ] && [ -n "${AUTO_REPOS// /}" ]; then
  for slug in $AUTO_REPOS; do
    case "$slug" in */*) ;; *) log "'$slug' in LEAD_REVIEW_AUTO_REPOS is not owner/repo; no worklist for it"; continue ;; esac
    [ -n "${PROJ[$slug]+x}" ] || PROJ[$slug]=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
    project="${PROJ[$slug]}"
    [ -n "$project" ] || { log "no fleet.conf project for $slug; no worklist for it"; continue; }
    [ -n "${BOX[$project]+x}" ] || BOX[$project]=$("$H/bin/box-for.sh" "$project" 2>/dev/null)
    wlown=1
    if [ -z "$ME" ] || [ "${BOX[$project]}" != "$ME" ]; then
      # Spillover (BH-5284) takes another box's items that waited
      # LEAD_REVIEW_SPILL_AFTER_S since approval, when this box has a clone.
      { [ "$SPILL_ON" = 1 ] && [ -d "$REPOS/$project/.git" ]; } || continue
      wlown=0
    fi
    lg_tick "$slug"
    rc=0; lw_items "$slug" "$QF.wl1" || rc=$?
    case "$rc" in
      0|2) WL_READ=1 ;;
      *) log "needs-review for $slug unreadable (rc=$rc); nothing starts from its worklist this tick"; continue ;;
    esac
    [ "$rc" -eq 0 ] || continue
    if [ "$wlown" = 1 ]; then
      jq -c --arg p "$project" '{r: ., p: $p, c: ""}' "$QF.wl1" >> "$QF.wl"
    else
      jq -c --arg p "$project" --argjson cut "$((NOW_EPOCH - SPILL_AFTER))" '
        select((try (.approved_at | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) as $a | $a != null and $a <= $cut)
        | {r: ., p: $p, c: ""}' "$QF.wl1" >> "$QF.wlspill"
    fi
  done
  cat "$QF.wlspill" >> "$QF.wl"
  WL_N=$(wc -l < "$QF.wl" | tr -d ' '); WL_SPILL=$(wc -l < "$QF.wlspill" | tr -d ' ')
fi
# The whole queue (BH-5151), second: every page, then one jq pass for the row checks.
lr_list_all '?status=requested,running' "$PAGES" > "$QF.list" 2>/dev/null; rc=$?
[ "$rc" -eq 75 ] && { log "lead-review routes not deployed; tick skipped"; exit 0; }
if [ "$rc" -ne 0 ]; then
  [ "$WL_READ" = 1 ] || { log "lead-review list failed (rc=$rc); tick skipped"; exit 0; }
  log "lead-review list failed (rc=$rc); this tick works the worklist only"
  printf '{"requests":[],"pages":0,"stop":""}' > "$QF.list"
fi
read -r TOTAL PRS STOP NPAGES < <(jq -r '[(.requests | length), ([.requests[] | "\(.repo)#\(.pr)"] | unique | length),
  (if .stop == "" then "-" else .stop end), .pages] | @tsv' "$QF.list" 2>/dev/null)
[ -n "${NPAGES:-}" ] || { log "lead-review list unreadable; tick skipped"; exit 0; }
case "$STOP" in
  cap) log "request list hit LEAD_REVIEW_MAX_PAGES=$PAGES after $TOTAL rows; rows past it are not ordered or counted this tick" ;;
  page-failed) log "request list page $((NPAGES + 1)) failed; this tick works the $TOTAL rows read" ;;
  no-cursor) log "request list truncated and the worker returned no next_after (cursor paging not deployed); this tick works the first $TOTAL rows" ;;
  cursor-loop) log "request list cursor repeated after page $NPAGES; this tick works the $TOTAL rows read" ;;
esac
PLUS=""; [ "$STOP" = - ] || PLUS="+"
seen=0 owned=0 done_n=0 superseded=0 failed=0 skipped=0 deferred=0 visited=0 stopped=""
# Pass 1, classify: the per-row checks of before, one project and one box-for
# lookup per repo instead of per row.
: > "$QF.owned"
while IFS=$'\t' read -r i repo okrow rstatus rat; do
  seen=$((seen + 1))
  if [ "$okrow" != 1 ]; then
    log "malformed request skipped: $(jq -c ".requests[$i]" "$QF.list" | head -c 200)"; skipped=$((skipped + 1)); continue
  fi
  [ -n "${PROJ[$repo]+x}" ] || PROJ[$repo]=$(awk -v r="$repo" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
  project="${PROJ[$repo]}"
  [ -n "$project" ] || { log "no fleet.conf project for $repo; skipped"; continue; }
  if [ -n "$PARTICIPANT" ]; then
    # A participant owns what it has a clone of (header); no spillover.
    [ -d "$REPOS/$project/.git" ] || continue
  else
    [ -n "${BOX[$project]+x}" ] || BOX[$project]=$("$H/bin/box-for.sh" "$project" 2>/dev/null)
    if [ -z "$ME" ] || [ "${BOX[$project]}" != "$ME" ]; then
      # SPILLOVER (BH-5284, behind LEAD_REVIEW_SPILLOVER=1, default off): a
      # request another box owns that has waited LEAD_REVIEW_SPILL_AFTER_S is
      # taken here too, after this box's own, when this box holds a clone of the
      # repo. The claim (job_open rc 9, then the request claim) keeps it to one.
      if [ "$SPILL_ON" = 1 ] && [ "$rstatus" = requested ] && [ "${rat:-0}" -gt 0 ] \
         && [ $((NOW_EPOCH - rat)) -ge "$SPILL_AFTER" ] && [ -d "$REPOS/$project/.git" ]; then
        spill=$((spill + 1)); printf '%s\t%s\t1\n' "$i" "$project" >> "$QF.owned"
      fi
      continue
    fi
  fi
  owned=$((owned + 1)); OWNED_REPO[$repo]=1
  printf '%s\t%s\t0\n' "$i" "$project" >> "$QF.owned"
done < <(jq -r '.requests | to_entries[] | .value as $r
  | [.key, ($r.repo // "" | tostring),
     (if (($r.pr // "") | tostring | test("^[0-9]+$")) and (($r.head_sha // "") | tostring | test("^[0-9a-f]{40}$"))
         and (($r.id // "") | tostring) != "" then 1 else 0 end),
     ($r.status // "-" | tostring | if . == "" then "-" else . end),
     (try (($r.created_at // "") | tostring | sub(" "; "T") | sub("\\.[0-9]+"; "")
           | (if test("Z$") then . else . + "Z" end) | fromdateiso8601) catch 0)] | @tsv' "$QF.list" 2>/dev/null)

# The open-PR list of each owned repo: which PR carries the hotfix label, and
# which rows are dead candidates. Unreadable = no hotfix order and no sweep for
# that repo; a list at _gh_rest_list's 1000-row cap is no sweep (absent would
# not mean closed).
HOTL=""
command -v hotfix_label >/dev/null 2>&1 && [ "$(hotfix_lane_on "$H")" = 1 ] && HOTL=$(hotfix_label "$H")
printf '{}' > "$QF.snap"
if command -v prs_open_list >/dev/null 2>&1; then
  for repo in "${!OWNED_REPO[@]}"; do
    rc=0; prs_open_list "$repo" "$QF.open" || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e 'type == "array"' "$QF.open" >/dev/null 2>&1; then
      log "open-PR list of $repo unreadable (rc=$rc); no hotfix order and no dead-row sweep for it this tick"; continue
    fi
    jq -c --arg repo "$repo" --arg l "$HOTL" --slurpfile o "$QF.open" '
      ($l | ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $l
      | . + {($repo): {sweep: (($o[0] | length) < 1000),
          prs: ($o[0] | map({key: (.number | tostring), value: {head: (.head.sha // ""),
            hot: ($l != "" and ((.labels // []) | map((.name // "") | ascii_downcase
                   | gsub("^[[:space:]]+|[[:space:]]+$"; "")) | any(. == $l)))}}) | from_entries)}}' \
      "$QF.snap" > "$QF.snap.new" && mv -f "$QF.snap.new" "$QF.snap"
  done
fi
# Order: hotfix, then priority (higher first), then oldest, then server order.
# c = closed|moved for a requested or running row the open-PR list says is dead.
jq -Rn '[inputs | split("\t") | {i: (.[0] | tonumber), p: .[1], s: (.[2] == "1")}]' "$QF.owned" > "$QF.ownedj"
mapfile -t ORDER < <(jq -c --slurpfile own "$QF.ownedj" --slurpfile snap "$QF.snap" '
  .requests as $q | $snap[0] as $s
  | [$own[0][] as $o | $q[$o.i] as $r | ($s[$r.repo] // null) as $rs
     | (($rs.prs // {})[$r.pr | tostring] // null) as $sp
     | {r: $r, p: $o.p, i: $o.i, s: $o.s, hot: ($sp.hot // false),
        pri: ($r.priority | if type == "number" then . else null end),
        c: (if $rs == null or ($rs.sweep | not) or ($r.status != "requested" and $r.status != "running") then ""
            elif $sp == null then "closed" elif $sp.head != $r.head_sha then "moved" else "" end)}]
  | sort_by([(if .s then 1 else 0 end), (if .hot then 0 else 1 end), (if .pri == null then 1 else 0 end), -(.pri // 0), (.r.created_at // ""), .i])
  | .[] | {r, p, c}' "$QF.list" 2>/dev/null)
[ "${#ORDER[@]}" -eq $((owned + spill)) ] || { log "ordering the $owned owned requests failed (got ${#ORDER[@]}); tick skipped"; exit 0; }
# The worklist goes first (BH-4956). A request row for the same (repo, pr, head)
# takes its item's place, so its id, scope notes and requester ride along; the
# rest of the rows follow in their own order.
if [ "$WL_N" -gt 0 ]; then
  [ "${#ORDER[@]}" -gt 0 ] && printf '%s\n' "${ORDER[@]}" > "$QF.rows" || : > "$QF.rows"
  if jq -cn --slurpfile w "$QF.wl" --slurpfile o "$QF.rows" '
      def k: "\(.r.repo)#\(.r.pr)@\(.r.head_sha)";
      ($o | map({key: k, value: .}) | from_entries) as $byk
      | ($w | map(k)) as $wk
      | ($w[] | k as $k | ($byk[$k] // .)), ($o[] | k as $k | select(($wk | index($k)) == null))' > "$QF.merged" 2>/dev/null; then
    mapfile -t ORDER < "$QF.merged"
    spill=$((spill + WL_SPILL))
  else
    log "merging the worklist with the $owned owned requests failed; tick skipped"; exit 0
  fi
fi

# Pass 2, dead rows before any budget. A candidate is superseded only when one
# live pulls/<n> read (cached per PR for the tick) confirms it: the open-PR
# list may be PR_SNAPSHOT_TTL_S stale, and a live row is a real request.
declare -A HANDLED
for n in "${!ORDER[@]}"; do
  [ "$SECONDS" -lt "$DEADLINE" ] || break
  c=$(jq -r '.c' <<<"${ORDER[$n]}"); [ -n "$c" ] || continue
  r=$(jq -c '.r' <<<"${ORDER[$n]}")
  repo=$(jq -r '.repo' <<<"$r"); pr=$(jq -r '.pr' <<<"$r"); sha=$(jq -r '.head_sha' <<<"$r")
  f="$QF.pr.${repo//\//_}.$pr"
  if [ ! -e "$f.done" ]; then
    gh_rest GET "repos/$repo/pulls/$pr" > "$f" 2>/dev/null || : > "$f"; : > "$f.done"
  fi
  state=$(jq -r '.state // empty' "$f" 2>/dev/null); live=$(jq -r '.head.sha // empty' "$f" 2>/dev/null)
  if [ -n "$state" ] && [ "$state" != open ]; then why="pr closed"
  elif [ -n "$live" ] && [ "$live" != "$sha" ]; then why="head moved to ${live:0:12}"
  else continue; fi
  supersede_dead "$r" "$(jq -r '.p' <<<"${ORDER[$n]}")" "$why"
  HANDLED[$n]=1; visited=$((visited + 1))
  case "$R" in
    superseded) superseded=$((superseded + 1)) ;; failed) failed=$((failed + 1)) ;;
    stop) stopped=worker; break ;; *) skipped=$((skipped + 1)) ;;
  esac
done

# Pass 3, review, up to RPOOL_K at once (BH-5284, bin/lib/review-pool.sh).
# Each item runs in a worker; the tick waits for its claim (the worker's
# gate) before it starts the next, so claims stay in queue order and a 503
# still ends the tick after one. Every eligible item starts as soon as a slot
# is free (BH-4956: no per-tick start cap). A slot is free under K and under
# the fleet-wide lead_review.concurrency row (lw_concurrency_ok). No new worker
# starts past LEAD_REVIEW_DEADLINE_S, over the lane's spend cap or the
# lead_review.daily_spend_usd row, with the running count unreadable, or with
# /tmp below LEAD_REVIEW_TMP_MIN_MB; one already running finishes and records,
# and the tick waits for it before the summary.
running_at_close=0 closed_by="" ratelimited="" paid=0 replayed=0 capped=0 held=0 pooled=0 poolreviewed=0
# lr_rerun <force> — launch the owed (0) or forced (1) rerun (BH-5317); logs its line.
lr_rerun() {
  local line
  line=$(command -v lcw_rerun >/dev/null 2>&1 && lcw_rerun "$H/bin/lead-review.sh" "$STATE" "${LEAD_REVIEW_RERUN_MAX:-}" "$1" tick)
  [ -n "$line" ] && log "$line"
  return 0
}
# lr_unlock — release the tick lock: flock -u releases the open file
# description, so a process this tick left behind holding fd 7 does not pin it.
LR_LOCKED=1
lr_unlock() {
  [ "$LR_LOCKED" = 1 ] || return 1; LR_LOCKED=0; flock -u 7 2>/dev/null; exec 7>&-
  log "tick lock held $((SECONDS - LR_LOCK_T0))s started=$RPOOL_STARTED"; return 0
}
RPOOL_TMP_PREFIX=lr RPOOL_LIVE_DIR="$STATE/pool"
# The pool reads LEAD_REVIEW_RATE_BACKOFF_S under the LEAD_REVIEW prefix (bin/lib/review-pool.sh).
rpool_init lead-review LEAD_REVIEW "$CONC" "$QF.pool" log
command -v lr_capped_check >/dev/null 2>&1 && lr_capped_check "$CONC" "$(local_box_name)"
if [ -z "$stopped" ]; then
  for n in "${!ORDER[@]}"; do
    [ -n "${HANDLED[$n]:-}" ] && continue
    rpool_reap
    [ -n "$stopped" ] && break
    visited=$((visited + 1))
    if [ -n "$closed_by" ] || [ "$SECONDS" -ge "$DEADLINE" ]; then
      deferred=$((deferred + 1)); case "$closed_by" in spend*) capped=$((capped + 1)) ;; esac; continue
    fi
    # BH-8027: an item placed on the Fly pool takes no slot, pause or /tmp here.
    p=$(jq -r '.p' <<<"${ORDER[$n]}"); lrfly=0
    command -v lrp_placed >/dev/null 2>&1 && lrp_placed "$p" && lrfly=1
    # A free place: under K and the fleet-wide row. The wait ends at the
    # deadline too, so starts close on time. An unreadable running count, or a
    # full fleet with nothing of ours running to free a place, closes starts:
    # the next tick asks again.
    slot=$lrfly
    while [ "$lrfly" = 0 ]; do
      lr_slot_free && { slot=1; break; }
      [ "$SECONDS" -ge "$DEADLINE" ] && break
      if [ "$LW_CONC_WHY" = unreadable ]; then closed_by=concurrency-unreadable; break; fi
      if [ "$LW_CONC_WHY" = full ] && [ "$(rpool_box_running)" -eq 0 ]; then
        log "lead_review.concurrency is full fleet-wide and none runs here; no new review starts this tick"
        closed_by=concurrency; break
      fi
      _rpool_sleep; rpool_reap
    done
    [ -n "$stopped" ] && break
    [ "$slot" = 1 ] || { deferred=$((deferred + 1)); continue; }
    # A rate-limit pause (BH-5284): wait it out inside the deadline, else defer.
    while [ "$lrfly" = 0 ] && rpool_paused && [ "$SECONDS" -lt "$DEADLINE" ]; do _rpool_sleep; rpool_reap; done
    if [ "$lrfly" = 0 ] && rpool_paused; then deferred=$((deferred + 1)); continue; fi
    [ -n "$stopped" ] && break
    if [ "$lrfly" = 1 ] && ! lw_concurrency_ok "$(rpool_box_running)"; then deferred=$((deferred + 1)); continue; fi
    if [ "$lrfly" = 0 ] && ! rpool_tmp_ok; then closed_by=tmp; deferred=$((deferred + 1)); continue; fi
    if ! rpool_spend_ok lead-review "$p"; then
      log "spend cap reached for $p ($RPOOL_SPEND_REASON); no new review starts this tick"
      closed_by=spend; deferred=$((deferred + 1)); continue
    fi
    if ! lw_spend_ok; then
      if [ "$LW_SPEND_WHY" = cap ]; then
        log "lead_review.daily_spend_usd reached ($LW_SPEND_LINE); no new review starts this tick"; closed_by=spend
      else
        log "$LW_SPEND_LINE; no new review starts this tick"; closed_by=spend-unreadable
      fi
      deferred=$((deferred + 1)); capped=$((capped + 1)); continue
    fi
    # The gates (BH-5873), for a worklist item with no request row only.
    lgm=full
    if [ -z "$(jq -r '.r.id // empty' <<<"${ORDER[$n]}")" ]; then
      IFS=$'\t' read -r grepo gpr gsha < <(jq -r '[.r.repo, (.r.pr | tostring), .r.head_sha] | @tsv' <<<"${ORDER[$n]}")
      lrc=0; lg_run "$grepo" "$gpr" "$gsha" || lrc=$?
      case "$lrc" in
        0) lgm="$LG_MODE" ;;
        10|12) skipped=$((skipped + 1)); continue ;;
        *) held=$((held + 1)); continue ;;
      esac
    fi
    if [ "$lrfly" = 1 ]; then
      lrp_put "${ORDER[$n]}" "$p" "$lgm"
      case "$LRP_WORD" in queued|inflight) pooled=$((pooled + 1)) ;; held) held=$((held + 1)) ;; reviewed) poolreviewed=$((poolreviewed + 1)) ;; *) deferred=$((deferred + 1)) ;; esac; continue
    fi
    rpool_start "r$n" lr_worker "$(jq -c '.r' <<<"${ORDER[$n]}")" "$p" "$lgm"
    rpool_gate_wait "r$n"
    rpool_reap
    [ -n "$stopped" ] && break
  done
  running_at_close=$(rpool_running)
  [ "$running_at_close" -gt 0 ] && log "starts closed concurrency=$RPOOL_K running=$running_at_close started=$RPOOL_STARTED; waiting for the running reviews to record (tick lock released)"
  # BH-6984: unlock BEFORE the wait, so the next tick or doorbell starts more
  # reviews while these run, and launch the rerun a skipped tick owed now.
  lr_unlock && lr_rerun 0
  rpool_wait_all
fi
rpool_finish
rung=$(wc -l < "$QF.rung" 2>/dev/null | tr -d ' '); rung="${rung:-0}"
log "tick seen=$seen owned=$owned done=$done_n superseded=$superseded failed=$failed skipped=$skipped deferred=$deferred concurrency=$RPOOL_K running=$running_at_close started=$RPOOL_STARTED worklist=$WL_N paid=$paid replayed=$replayed capped=$capped held=$held$([ "$pooled" -gt 0 ] && printf ' pooled=%s' "$pooled")$([ "$poolreviewed" -gt 0 ] && printf ' poolreviewed=%s' "$poolreviewed")${ratelimited:+ ratelimited=$ratelimited} rung=$rung total=$TOTAL$PLUS prs=$PRS$PLUS${stopped:+ stopped=$stopped left=$((${#ORDER[@]} - visited))}$([ "$SPILL_ON" = 1 ] && printf ' spill=%s' "$spill")"
# The rerun (BH-5317). It is owed when a tick skipped on the lock (the marker),
# or forced when this tick deferred work to its deadline. Never into a refusal
# it would only repeat: low /tmp, a spend cap, the concurrency row, a stopped
# worker, a rate pause. A tick that unlocked when its starts closed launched
# the owed one then; here it launches only a forced one.
force=0
[ "$deferred" -gt 0 ] && [ -z "$closed_by" ] && [ -z "$stopped" ] && ! rpool_paused && force=1
if lr_unlock; then lr_rerun "$force"; elif [ "$force" = 1 ]; then lr_rerun 1; fi
exit 0
