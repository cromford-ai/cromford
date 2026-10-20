#!/bin/bash
# gh-identity: raw-by-design — a merge the operator sent from the console runs as the operator's own identity by design; an App token here would land it as the bot.
# alert-writer: by-design — its re-beat tails ALERTS.log; routing its own writes through the helper would self-feed
# Console command poller — cron every minute. Claims commands (TTL-leased), executes, acks.
# Also syncs new ALERTS lines and pause/automerge flags up to the console.
set -uo pipefail
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
HARNESS=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
BEAT=$HARNESS/bin/beat.sh
set -a; . $HENV/global.env 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-poll-commands
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off poll-commands.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit poll-commands
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    poll-commands
[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
mkdir -p $HARNESS/flags
# Self-heal DNS: the resolv.conf symlink died once after a hot resize (dangling
# /run/systemd target on a systemd-less VM). If resolution is broken, restore a
# real file and alert once.
if ! getent hosts github.com >/dev/null 2>&1; then
  rm -f /etc/resolv.conf
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
  if getent hosts github.com >/dev/null 2>&1; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [vm] DNS was broken - self-healed resolv.conf" >> "$HARNESS/logs/ALERTS.log"
  else
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [vm] DNS broken and self-heal FAILED" >> "$HARNESS/logs/ALERTS.log"
    exit 1
  fi
fi
exec 7>"$HARNESS/locks/poller.lock"
flock -n 7 || exit 0

API() { curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$@"; }

# Pause flags are DB rows as of phase 3, and the file is still the flag. This
# handler writes BOTH: the file first (so the box is correct even if the next
# line never runs), the row second (so the console and every other box see the
# same state). With the worker unreachable flag_set returns nonzero after having
# already written the file — which is exactly today's behavior.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# BH-2657: a command for a box-owned project goes to that box as a
# box_console_commands row (box_ccmd_forward, addressed by cron_box_id_for), and
# one for a project this box owns runs here through bcx_run, the same code the
# boxes run. Guarded: a box without a lib answers those commands "not loaded",
# OK=false. There is no ssh fallback.
# shellcheck source=bin/lib/jobs/box-console-commands.sh
[ -r "$HARNESS/bin/lib/jobs/box-console-commands.sh" ] && . "$HARNESS/bin/lib/jobs/box-console-commands.sh"
# shellcheck source=bin/lib/box-cmd-exec.sh
[ -r "$HARNESS/bin/lib/box-cmd-exec.sh" ] && . "$HARNESS/bin/lib/box-cmd-exec.sh"
# shellcheck source=bin/lib/cron-lines.sh
[ -r "$HARNESS/bin/lib/cron-lines.sh" ] && . "$HARNESS/bin/lib/cron-lines.sh"
# The pause lib (BH-1672) for the flags beat's env_pauses field. Guarded the
# same way: a box without it beats env_pauses [].
# shellcheck source=bin/lib/pause.sh
[ -r "$HARNESS/bin/lib/pause.sh" ] && . "$HARNESS/bin/lib/pause.sh"
# The merge-queue provider probe, from the conductor's lib, for the merge_pr
# handler below: "did that call merge it or only queue it" has two different
# witnesses depending on the provider, and reporting the wrong one back to the
# console is a lie the requester acts on.
# shellcheck source=bin/lib/merge-conductor-lib.sh
if [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ]; then . "$HARNESS/bin/lib/merge-conductor-lib.sh"
# Without it the provider CANNOT be told, and `none` would send a Mergify repo's
# merge straight over REST around its queue (BH-2199): the stub says `unloaded`,
# which the merge_pr handler refuses as a retryable failure, never a merge.
else mc_pr_queued() { return 1; }; mc_queue_provider() { printf unloaded; }; fi
# The merge itself goes over REST (BH-892): `gh pr merge` is GraphQL, and on
# 2026-09-18 console commands 15934 and 15937 dead-lettered on an exhausted
# GraphQL bucket while the same PRs merged instantly over REST. Guarded — a box
# without the lib runs today's call, which is the rc-2 branch below.
# shellcheck source=bin/lib/gh-pr-merge.sh
[ -r "$HARNESS/bin/lib/gh-pr-merge.sh" ] && . "$HARNESS/bin/lib/gh-pr-merge.sh"
# The hold_ticket / unhold_ticket handler (BH-2326.1). Guarded: without it the
# arm answers "not run (lib not loaded)", OK=false.
# shellcheck source=bin/lib/ticket-hold-cmd.sh
[ -r "$HARNESS/bin/lib/ticket-hold-cmd.sh" ] && . "$HARNESS/bin/lib/ticket-hold-cmd.sh"
# The comment_issue handler (BH-5820). Guarded: without it the arm answers
# "comment not posted (lib not loaded)", OK=false.
# shellcheck source=bin/lib/issue-comment-cmd.sh
[ -r "$HARNESS/bin/lib/issue-comment-cmd.sh" ] && . "$HARNESS/bin/lib/issue-comment-cmd.sh"
# A head-moved merge_pr refusal is moved off its command key after the ack
# (BH-4917), so the next merge_pr from any entry point is a new command.
# Guarded: without it the key stays sticky, as before.
# shellcheck source=bin/lib/merge-pr-release.sh
[ -r "$HARNESS/bin/lib/merge-pr-release.sh" ] && . "$HARNESS/bin/lib/merge-pr-release.sh"
set_flag() { # set_flag <name> on|off [reason]
  if command -v flag_set >/dev/null 2>&1; then flag_set "$@" >/dev/null 2>&1 && return 0; fi
  case "${2:-}" in
    on)  touch "$HARNESS/flags/$1" ;;
    off) rm -f "$HARNESS/flags/$1" ;;
  esac
  return 0
}

# --- 1. claim + execute commands (4 sub-cycles/min so chat pickup is <=15s) ---
for CYCLE in 1 2 3 4; do
RESP=$(API -X POST "$CONSOLE_URL/api/commands/claim") || RESP='{"commands":[]}'
mapfile -t CMDS < <(jq -c '.commands[]?' <<<"$RESP" 2>/dev/null)
for CMD in "${CMDS[@]:-}"; do
  [ -n "$CMD" ] || continue
  ID=$(jq -r .id <<<"$CMD"); TYPE=$(jq -r .type <<<"$CMD"); PROJECT=$(jq -r .project <<<"$CMD")
  PAYLOAD=$(jq -r '.payload // "{}"' <<<"$CMD")
  OK=false; RESULT=""; OUTCOME=""
  ORC_SPAWN=""
  case "$TYPE" in
    # >>> merge_pr handler (tests/poll-commands-merge-pr.bh-892-test.sh runs this block)
    merge_pr)
      URL=$(jq -r '.pr_url // ""' <<<"$PAYLOAD")
      # Whitelist = every repo registered in fleet.conf (was a hardcoded four).
      # A READ THAT FAILED IS NOT A MISS (BH-2009). The console reads a
      # `refused:` result as its terminal status (BH-932), so a fleet.conf that
      # was unreadable for a moment must not refuse a registered PR forever.
      # WLBAD names the failed read; a url matching a slug that WAS read still
      # merges, and one matching nothing acks a retryable `merge failed:`.
      WLBAD=""; WLREPOS=""
      PJS=$("$HARNESS/bin/fleet-conf.sh" --projects); WLRC=$?
      if [ "$WLRC" -ne 0 ]; then WLBAD="fleet-conf --projects rc $WLRC"
      elif [ -z "${PJS//[[:space:]]/}" ]; then WLBAD="fleet-conf --projects returned no projects"
      else
        for pj in $PJS; do
          R=$("$HARNESS/bin/fleet-conf.sh" "$pj" repo); WLRC=$?
          if [ "$WLRC" -ne 0 ]; then WLBAD="fleet-conf $pj repo rc $WLRC"
          elif [ -z "$R" ]; then WLBAD="fleet-conf $pj repo returned nothing"
          else WLREPOS+="$R"$'\n'; fi
        done
      fi
      SLUGS=$(printf '%s' "$WLREPOS" | sort -u | sed 's/[.]/\\./g' | paste -sd'|' -)
      if [[ -n "$SLUGS" && "$URL" =~ ^https://github\.com/($SLUGS)/pull/[0-9]+$ ]]; then
        # MERGE OVER REST (BH-892). The request is the RECORDED pr_url and
        # nothing else: the whitelist regex has just captured its slug, and the
        # number is that url's tail. A repo behind GitHub's NATIVE queue is
        # skipped here on purpose — there `gh pr merge` IS the enqueue and REST
        # has no equivalent, so the rc-2 branch below is the only correct call.
        MSLUG="${BASH_REMATCH[1]}"; MNUM="${URL##*/}"
        MSHA=$(jq -r '.sha // ""' <<<"$PAYLOAD"); MRC=2; MOUT=""
        MPROV=$(mc_queue_provider "$MSLUG" 2>/dev/null)
        if [ "$MPROV" = unloaded ]; then
          MRC=14; MOUT="the merge-conductor lib is not loaded on this box, so whether $MSLUG merges through a queue cannot be told — nothing was merged"
        elif [ "$MPROV" = unknown ]; then
          # BH-2275: the .mergify.yml probe could not be read. Not proof of "no
          # queue": a PUT here could merge around a Mergify queue. Retryable.
          MRC=14; MOUT="$MSLUG's merge-queue provider could not be read (.mergify.yml probe) — nothing was merged; retry once it answers"
        elif [ "$MPROV" = mergify ]; then
          # A MERGIFY REPO IS ENQUEUED, NEVER MERGED OVER REST (BH-2199, from the
          # #2220 review). The provider is `mergify` only when .mergify.yml has
          # queue_rules: the repo chose a queue to keep main green, and a PUT
          # /merge from this button bypassed it exactly the way the conductor's
          # old degraded path did. So the button asks the queue the same way the
          # conductor does (mc_enqueue_mergify: the merge-queue label, then the
          # `@mergifyio queue` comment, then the witness poll) and reports what
          # happened. The ask is bound to the reviewed sha like the REST merge
          # is: a head that moved since the review is refused, not queued.
          if [ -z "$MSHA" ] && type job_verdict >/dev/null 2>&1; then
            MSHA=$(job_verdict "$URL" 2>/dev/null | cut -f6)
            case "$MSHA" in "-") MSHA="" ;; esac
          fi
          MHEAD=$(mc_pr_view "$URL" '.head.sha' 2>/dev/null) || MHEAD=""
          if ! command -v mc_enqueue_mergify >/dev/null 2>&1; then MRC=14; MOUT="the merge-conductor lib is not loaded on this box"
          elif [ -z "$MHEAD" ]; then MRC=14; MOUT="the PR's head could not be read"
          elif [ -n "$MSHA" ] && [[ "$MHEAD" != "$MSHA"* ]]; then MRC=4; MOUT="head is ${MHEAD:0:8}, the Mergify queue was not asked"
          else
            MOUT=$(mc_enqueue_mergify "$MSLUG" "$URL" "$MHEAD"); MRC=$?
            case "$MRC" in 0) MRC=10 ;; 2) MRC=11 ;; 3) MRC=12 ;; 4) MRC=15 ;; *) MRC=13 ;; esac
          fi
        elif [ "$MPROV" != github ] \
           && command -v gh_pr_merge_rest >/dev/null 2>&1; then
          # THE MERGE IS BOUND TO THE REVIEWED SHA ON THIS LANE TOO. Mission
          # Control's merge button posts {type, project, ticket, pr_url} and no
          # sha (console-ui/src/screens/PR.js), so the payload alone would send
          # every console merge out UNBOUND — on the one lane whose dead letters
          # are this ticket. The sha the review approved is in the ledger, and
          # bin/jobs-client.sh is already sourced above: this is the same lookup
          # bin/merge-queue.sh's hb_sha does, field 6 of the verdict row. "-" is
          # the ledger saying it has no claim (a row older than the field), which
          # stays unbound rather than becoming a guess. Asked for only on the
          # lane that can use it: a native-queue repo spends no ledger read.
          if [ -z "$MSHA" ] && type job_verdict >/dev/null 2>&1; then
            MSHA=$(job_verdict "$URL" 2>/dev/null | cut -f6)
            case "$MSHA" in "-") MSHA="" ;; esac
          fi
          MOUT=$(gh_pr_merge_rest "$MSLUG" "$MNUM" "$MSHA" \
                   "$HARNESS/logs/poll-commands-gh.err" "$HARNESS/logs/console-commands.log" \
                   "merge_pr $ID" 1); MRC=$?
        fi
        case "$MRC" in
          0) OK=true; RESULT="merged $URL${MOUT:+ at $MOUT}" ;;
          # BH-2199: the Mergify enqueue's answers. 10 = the queue acknowledged
          # it; 11 = it merged inside the ask; 12 = the ask is in place and the
          # queue said nothing — a terminal refusal naming why, because merging
          # around the queue is not this button's to do; 13/14 = the ask could
          # not be made (retryable); 15 = BH-3683 withholds the lead-verdict
          # status on this head, so nothing was labelled or asked (BH-3806) —
          # a terminal refusal naming the --source human command.
          10) OK=true; RESULT="queued $URL (Mergify merge queue at ${MHEAD:0:8} — the merge conductor settles it)" ;;
          11) OK=true; RESULT="merged $URL (by the Mergify merge queue)" ;;
          12) OUTCOME=refused; RESULT="refused: $MSLUG merges through its Mergify queue (queue_rules) and the queue acknowledged nothing yet — the merge-queue label and @mergifyio queue are in place, NOT merged directly; the merge conductor keeps asking. ${MOUT}" ;;
          13|14) RESULT="merge failed: the Mergify queue could not be asked — ${MOUT:-no reason given}" ;;
          15) OUTCOME=refused; RESULT="refused: $URL needs a human lead verdict before the Mergify queue is asked — ${MOUT#refused: }" ;;
          2)
            # THE METHOD COMES FROM THE REPO (BH-1313); `--squash` without lib.
            MFLAG=--squash
            command -v gh_pr_merge_flag >/dev/null 2>&1 \
              && MFLAG=$(gh_pr_merge_flag "$MSLUG" "$MNUM" "$HARNESS/logs/console-commands.log" "merge_pr $ID")
            # gh exits 0 for BOTH a merge and an enqueue: on a repo whose main is
            # behind GitHub's native merge queue this call only queues the PR, and
            # reporting "merged" back to the console would be a lie the requester
            # acts on. Ask GitHub which of the two happened.
            #
            # NO `--delete-branch` TO REAL gh (BH-1715): it deletes the head ref
            # with no look at the PRs stacked on it, and GitHub then CLOSES them
            # (#1664, #1666). On a merge the branch goes through the lib's
            # children-first delete instead; on an enqueue it is left alone, the
            # queue is about to build it. Without the lib it is kept.
            if OUT=$(gh pr merge "$URL" "$MFLAG" 2>&1); then
              OK=true
              # Provider-aware: GitHub's native queue sets isInMergeQueue, Mergify
              # never does. This is an EXPLICIT human merge from Mission Control, so
              # it is not stood down on a queue repo the way the automatic mergers
              # are — but what it reports back has to be the truth either way.
              if mc_pr_queued "$URL"; then
                RESULT="queued $URL (merge queue — the merge conductor settles it)"
              else
                RESULT="merged $URL"
                if command -v _gpm_delete_branch >/dev/null 2>&1; then
                  _gpm_delete_branch "$MSLUG" "$MNUM" "" "$HARNESS/logs/console-commands.log" "merge_pr $ID" || true
                fi
              fi
            else RESULT="merge failed: $(head -c 300 <<<"$OUT")"; fi ;;
          # A REFUSAL IS NOT A FAILURE. GitHub answered about this merge, so the
          # command is finished: `refused:` is what the console shows the person
          # who clicked, where `merge failed:` tells them nothing about why.
          # It acks OUTCOME=refused (BH-932), which the console's ack handler
          # (example-org/cromford-console src/index.js) stores as a TERMINAL
          # `refused` row: never re-leased, never dead-lettered, and never
          # stamped merged. NEVER ok:true: that handler stamps the build
          # merged=1/pr_merged on any ok merge_pr ack, which would hide the
          # still-open PR's Merge button and drop it from /api/builds/unmerged.
          # OK stays false, so a console older than the `refused` status reads a
          # retry, never a false merge. Only a real GitHub verdict (rc 3/4/5)
          # is a refusal: any other rc is no verdict at all and is not one.
          # A head-moved refusal (rc 4) is then moved off its command key by the
          # `merge_pr key release` block after the ack (BH-4917).
          3|5) OUTCOME=refused; RESULT="refused: GitHub would not merge — $MOUT" ;;
          4) OUTCOME=refused; RESULT="refused: head moved${MSHA:+ since sha ${MSHA:0:8}} — $MOUT" ;;
          *) RESULT="merge failed: no merge verdict (rc $MRC)${MOUT:+ — $MOUT}" ;;
        esac
      elif [ -n "$WLBAD" ]; then RESULT="merge failed: whitelist unreadable ($WLBAD)"
      else RESULT="refused: not a whitelisted fleet PR"; fi ;;
    # <<< merge_pr handler
    # >>> lead_review handler (tests/lead-review-doors.bh-1952-test.sh runs this block)
    lead_review)
      # REQUEST A LEAD REVIEW OF ONE HEAD (BH-1952): the console's REQUEST LEAD
      # REVIEW button. Every field is checked here before anything is sent, and
      # the repo must be a fleet.conf repo (the list merge_pr trusts), so a
      # click can only ever reach a fleet repo. The sha is the one the console
      # showed, never looked up. OK=true only when the worker answered 2xx; any
      # other answer (409 already requested, 403 no lead token) comes back as
      # the worker's own text.
      LREPO=$(jq -r '.repo // ""' <<<"$PAYLOAD"); LPR=$(jq -r '.pr // ""' <<<"$PAYLOAD")
      LSHA=$(jq -r '.head_sha // ""' <<<"$PAYLOAD" | tr 'A-F' 'a-f'); LNOTES=$(jq -r '.notes // ""' <<<"$PAYLOAD")
      LREPOS=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null | while read -r pj; do "$HARNESS/bin/fleet-conf.sh" "$pj" repo 2>/dev/null; done)
      if ! [[ "$LREPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! grep -qxF -- "$LREPO" <<<"$LREPOS"; then
        RESULT="refused: repo '$LREPO' is not a fleet.conf repo"
      elif ! [[ "$LPR" =~ ^[1-9][0-9]*$ ]]; then RESULT="refused: pr must be a positive integer, got '$LPR'"
      elif ! [[ "$LSHA" =~ ^[0-9a-f]{40}$ ]]; then RESULT="refused: head_sha must be a full 40-hex sha, got '$LSHA'"
      elif LOUT=$("$HARNESS/bin/lead-verdict.sh" request "$LREPO" "$LPR" "$LSHA" ${LNOTES:+--notes "$LNOTES"} 2>&1); then
        OK=true; RESULT="$LOUT"
      else RESULT="refused: $(head -c 300 <<<"$LOUT" | tr '\n' ' ')"; fi ;;
    # <<< lead_review handler
    # >>> run_triage handler (tests/ssh-forward-hardening-test.sh runs this block)
    run_triage)
      # Post-fleet-split: each project's triage (and the builds it launches) runs
      # ONLY on its owning box. Hub executing worker projects caused cross-box
      # duplicate builds (TK-42 twin PRs, 2026-07-25) — per-ticket locks are
      # per-box and can't dedupe across machines.
      #
      # BH-2657: a far box's triage is QUEUED as a box_console_commands row that
      # box's bin/box-console-commands.sh claims and runs; OK=true means the
      # worker holds the row, not that triage started. The project reaches the
      # far box only as JSON data. The same shape is inlined in every handler
      # below because the suites run each block on its own. Triage reads nothing
      # from the payload, so one that is not JSON travels as {} rather than
      # failing the forward with a worker error that never happened.
      jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || PAYLOAD='{}'
      BOX=$("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || true)
      if [ -z "$BOX" ]; then RESULT="unknown project $PROJECT"
      elif [ "$BOX" = local ]; then
        if ! command -v bcx_run >/dev/null 2>&1; then RESULT="local run failed (box-cmd-exec not loaded)"
        else bcx_run run_triage "$PROJECT" "$PAYLOAD" "$ID"; [ "$BCX_OK" = 1 ] && OK=true; RESULT="$BCX_RESULT"; fi
      elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
        RESULT="forward to $BOX failed (box-console-commands client not loaded)"
      elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$BOX")" run_triage "$PROJECT" "$PAYLOAD" >/dev/null; then
        OK=true; RESULT="queued for $BOX (box command $ID)"
      else RESULT="forward to $BOX failed (jobs worker ${JOBS_HTTP:-unreachable})"; fi ;;
    # <<< run_triage handler
    # >>> fetch_log handler (tests/poll-commands-handlers-test.sh runs this block)
    fetch_log)
      # Read one WHITELISTED log off the owning box and beat it back, so web
      # Mission Control can look at a lane without anyone SSH-ing in. Strict
      # whitelist in bin/fetch-log.sh; nothing from the payload is ever
      # interpolated into a path, and the project must be an EXACT fleet.conf
      # row (or the literal "hub") before it can pick a box. Fire-and-poll: a
      # local read beats and acks, and the console picks the tail up from the
      # beat stream; a far box's read is queued and answered on its row.
      #
      # EVERY exit that is not a queued forward beats. The pane is keyed on
      # log:<command_id>, so a refusal or a dead box that answered with silence
      # is indistinguishable from a fetch still in flight — and a box being down
      # is exactly when someone is staring at that pane.
      WHICH=$(jq -r '.which // ""' <<<"$PAYLOAD")
      LPROJ=$(jq -r '.project // ""' <<<"$PAYLOAD"); [ -n "$LPROJ" ] || LPROJ="$PROJECT"
      case "$LPROJ" in null) LPROJ="" ;; esac
      LPROJ=$(printf %s "$LPROJ" | tr -dc 'A-Za-z0-9_-')
      CJ="$HARNESS/logs/console-commands.log"
      CJS() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9_.:/-' | head -c 64; }
      if ! "$HARNESS/bin/fetch-log.sh" --path "$WHICH" "$LPROJ" >/dev/null 2>&1; then
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') fetch_log id=$(CJS "$ID") project=$(CJS "$LPROJ") which=$(CJS "$WHICH") -> REFUSED" >> "$CJ"
        # Name both halves: `triage` is legal but only for a project the fleet
        # actually runs, so "bad which" alone would send a debugger the wrong way.
        RESULT="refused: no whitelisted log for which='$WHICH' project='$LPROJ'"
        $BEAT "$("$HARNESS/bin/fetch-log.sh" --error "$LPROJ" "$WHICH" "$ID" refused)"
      else
        BOX=local
        [ "$LPROJ" = hub ] || BOX=$("$HARNESS/bin/box-for.sh" "$LPROJ" 2>/dev/null || true)
        if [ -z "$BOX" ] || [ "$BOX" = local ]; then
          # Read here by bcx_run, the code the boxes run (bin/lib/box-cmd-exec.sh).
          if ! command -v bcx_run >/dev/null 2>&1; then
            RESULT="local run failed (box-cmd-exec not loaded)"
            $BEAT "$("$HARNESS/bin/fetch-log.sh" --error "$LPROJ" "$WHICH" "$ID" fetch_failed)"
          else
            bcx_run fetch_log "$LPROJ" "$PAYLOAD" "$ID"
            if [ "$BCX_OK" = 1 ] && [ -n "$BCX_BODY" ] && jq -e . >/dev/null 2>&1 <<<"$BCX_BODY"; then
              $BEAT "$BCX_BODY"; OK=true; RESULT="log tail beat from ${BOX:-local}"
            else
              RESULT="fetch failed on ${BOX:-local}"
              if [ -n "$BCX_BODY" ] && jq -e . >/dev/null 2>&1 <<<"$BCX_BODY"; then $BEAT "$BCX_BODY"
              else $BEAT "$("$HARNESS/bin/fetch-log.sh" --error "$LPROJ" "$WHICH" "$ID" fetch_failed)"; fi
            fi
          fi
        # BH-2657: a far box's log is QUEUED. The box posts the tail back to the
        # row and the console reads it there (#2656), so a queued fetch beats
        # nothing; a failed forward beats fetch_failed, as a dead box always did.
        elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
          RESULT="forward to $BOX failed (box-console-commands client not loaded)"
          $BEAT "$("$HARNESS/bin/fetch-log.sh" --error "$LPROJ" "$WHICH" "$ID" fetch_failed)"
        elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$BOX")" fetch_log "$LPROJ" "$PAYLOAD" >/dev/null; then
          OK=true; RESULT="queued for $BOX (box command $ID)"
        else
          RESULT="forward to $BOX failed (jobs worker ${JOBS_HTTP:-unreachable})"
          $BEAT "$("$HARNESS/bin/fetch-log.sh" --error "$LPROJ" "$WHICH" "$ID" fetch_failed)"
        fi
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') fetch_log id=$(CJS "$ID") project=$(CJS "$LPROJ") which=$(CJS "$WHICH") box=$(CJS "${BOX:-local}") -> $RESULT" >> "$CJ"
      fi ;;
    # <<< fetch_log handler
    # >>> fetch_artifact handler (tests/poll-commands-handlers-test.sh runs this block)
    fetch_artifact)
      # Sibling of fetch_log for BUILD artifacts: plan/review/security/qa/
      # pipeline/cost/context out of the build dir for one ticket KEY. Same
      # fire-and-poll shape. The key is a second untrusted path component, so
      # bin/fetch-artifact.sh REJECTS anything outside [A-Za-z0-9_-]+ rather
      # than stripping it — a key quietly rewritten into a different key would
      # answer confidently about the wrong build.
      WHICH=$(jq -r '.which // ""' <<<"$PAYLOAD")
      AKEY=$(jq -r '.key // ""' <<<"$PAYLOAD"); case "$AKEY" in null) AKEY="" ;; esac
      LPROJ=$(jq -r '.project // ""' <<<"$PAYLOAD"); [ -n "$LPROJ" ] || LPROJ="$PROJECT"
      case "$LPROJ" in null) LPROJ="" ;; esac
      CJ="$HARNESS/logs/console-commands.log"
      CJS() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9_.:/-' | head -c 64; }
      "$HARNESS/bin/fetch-artifact.sh" --path "$LPROJ" "$AKEY" "$WHICH" >/dev/null 2>&1; PRC=$?
      # rc 1 is "refused" and is box-independent. rc 2 is "nothing here yet" and
      # is NOT a refusal — the owning box may hold the build this box never ran.
      if [ "$PRC" -eq 1 ]; then
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') fetch_artifact id=$(CJS "$ID") project=$(CJS "$LPROJ") key=$(CJS "$AKEY") which=$(CJS "$WHICH") -> REFUSED" >> "$CJ"
        RESULT="refused: no whitelisted artifact for which='$WHICH' key='$AKEY' project='$LPROJ'"
        $BEAT "$("$HARNESS/bin/fetch-artifact.sh" --error "$LPROJ" "$AKEY" "$WHICH" "$ID" refused)"
      else
        BOX=$("$HARNESS/bin/box-for.sh" "$LPROJ" 2>/dev/null || true)
        if [ -z "$BOX" ] || [ "$BOX" = local ]; then
          # Read here by bcx_run, as fetch_log does. A project fleet.conf does
          # not run (hub) is refused there and answers fetch_failed.
          if ! command -v bcx_run >/dev/null 2>&1; then
            RESULT="local run failed (box-cmd-exec not loaded)"
            $BEAT "$("$HARNESS/bin/fetch-artifact.sh" --error "$LPROJ" "$AKEY" "$WHICH" "$ID" fetch_failed)"
          else
            bcx_run fetch_artifact "$LPROJ" "$PAYLOAD" "$ID"
            if [ "$BCX_OK" = 1 ] && [ -n "$BCX_BODY" ] && jq -e . >/dev/null 2>&1 <<<"$BCX_BODY"; then
              $BEAT "$BCX_BODY"; OK=true; RESULT="artifact tail beat from ${BOX:-local}"
            else
              RESULT="fetch failed on ${BOX:-local}"
              if [ -n "$BCX_BODY" ] && jq -e . >/dev/null 2>&1 <<<"$BCX_BODY"; then $BEAT "$BCX_BODY"
              else $BEAT "$("$HARNESS/bin/fetch-artifact.sh" --error "$LPROJ" "$AKEY" "$WHICH" "$ID" fetch_failed)"; fi
            fi
          fi
        # A far box's artifact is queued, exactly as the fetch_log forward above.
        elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
          RESULT="forward to $BOX failed (box-console-commands client not loaded)"
          $BEAT "$("$HARNESS/bin/fetch-artifact.sh" --error "$LPROJ" "$AKEY" "$WHICH" "$ID" fetch_failed)"
        elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$BOX")" fetch_artifact "$LPROJ" "$PAYLOAD" >/dev/null; then
          OK=true; RESULT="queued for $BOX (box command $ID)"
        else
          RESULT="forward to $BOX failed (jobs worker ${JOBS_HTTP:-unreachable})"
          $BEAT "$("$HARNESS/bin/fetch-artifact.sh" --error "$LPROJ" "$AKEY" "$WHICH" "$ID" fetch_failed)"
        fi
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') fetch_artifact id=$(CJS "$ID") project=$(CJS "$LPROJ") key=$(CJS "$AKEY") which=$(CJS "$WHICH") box=$(CJS "${BOX:-local}") -> $RESULT" >> "$CJ"
      fi ;;
    # <<< fetch_artifact handler
    # >>> chat handler (tests/box-chat-routing-test.sh runs this block)
    chat)
      # Two targets since 2026-08-24. project "orchestrator" (or absent, the
      # shape every chat had before per-box chat existed) is the HUB orchestrator
      # and takes the original inbox path below, untouched. Any other project is
      # that project's own box session.
      #
      # It must be FORWARDED, because claims are not box-scoped: the claim POST
      # carries no box identity (only the fleet-wide bearer) and the console's
      # commands table has no box column, so whichever box's poller fires first
      # wins the command — very often the hub. Waiting for "the right box to
      # claim it" would need a new mechanism on both sides, so the hub forwards
      # it: since BH-2657 as a box_console_commands row addressed to the box
      # box-for.sh names, as in every other project-scoped handler.
      CHAT_TARGET="$PROJECT"; case "$CHAT_TARGET" in null|'') CHAT_TARGET=orchestrator ;; esac
      if [ "$CHAT_TARGET" != orchestrator ]; then
        CPROJ=$(printf %s "$CHAT_TARGET" | tr -dc 'A-Za-z0-9_-')
        CTEXT=$(jq -r '.text // ""' <<<"$PAYLOAD")
        if ! "$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null | grep -qxF "$CPROJ"; then
          RESULT="refused: '$CPROJ' is not a fleet.conf project"
        elif [ -z "$CTEXT" ]; then
          RESULT="refused: empty chat text"
        else
          CBOX=$("$HARNESS/bin/box-for.sh" "$CPROJ" 2>/dev/null || true)
          if [ -z "$CBOX" ] || [ "$CBOX" = local ]; then
            # bcx_run builds box-chat.sh's {text,command_id,origin,project}
            # payload and launches it detached, as the boxes do.
            if ! command -v bcx_run >/dev/null 2>&1; then RESULT="local run failed (box-cmd-exec not loaded)"
            else bcx_run chat "$CPROJ" "$PAYLOAD" "$ID"; [ "$BCX_OK" = 1 ] && OK=true; RESULT="$BCX_RESULT"; fi
          # BH-2657: a far box's chat is QUEUED as a row that box claims and
          # runs detached. The answer still comes back as that box's beat.
          elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
            RESULT="forward to $CBOX failed (box-console-commands client not loaded)"
          elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$CBOX")" chat "$CPROJ" "$PAYLOAD" >/dev/null; then
            OK=true; RESULT="queued for $CBOX (box command $ID)"
          else RESULT="forward to $CBOX failed (jobs worker ${JOBS_HTTP:-unreachable})"; fi
        fi
        # Every exit answers the pane, same discipline as the fetch handlers: a
        # chat that is refused or never reaches its box must say so, not hang.
        [ "$OK" = true ] || $BEAT "$(jq -nc --arg id "$ID" --arg p "$CPROJ" --arg t "$RESULT" \
          --arg ts "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
          '{kind:"chat_reply",rkey:("chat:"+$id),command_id:$id,project:$p,text:$t,error:"routing_failed",ts:$ts}')"
      else
      mkdir -p /root/orchestrator/inbox
      MSGF=$(mktemp /root/orchestrator/inbox/msg-XXXXXX.txt)
      # Telegram group attribution (2026-08-31): the console worker now sends
      # chat_id/thread_id/from_* with every chat payload. The harness channel is
      # the "the operator Harness" forum group, where several full-authority principals
      # talk, so the orchestrator needs WHO sent this and WHICH topic it landed
      # in. It rides as one header line on the message body (the sidecar is
      # consumed for beat routing only) plus the meta sidecar for logging.
      # Absent fields (dash origin, older worker) leave ATTRIB empty = old shape.
      TG_FROM=$(jq -r '.from_name // ""' <<<"$PAYLOAD")
      TG_USER=$(jq -r '.from_username // ""' <<<"$PAYLOAD")
      TG_CHAT=$(jq -r '.chat_id // ""' <<<"$PAYLOAD")
      TG_THREAD=$(jq -r '.thread_id // ""' <<<"$PAYLOAD")
      case "$TG_THREAD" in null) TG_THREAD="" ;; esac
      TG_TOPIC=""
      # Same refresh as the orchestrator turn (BH-437): D1 is the ledger of
      # record for the topic map, and this file is a cache the verb rebuilds.
      # The client is already sourced at the top of this script in production;
      # `command -v` is the guard that keeps the lifted-block suites — which run
      # this handler with no client at all — a no-op instead of a hard error.
      [ -z "$TG_THREAD" ] || ! command -v telegram_topics_sync >/dev/null 2>&1 \
        || telegram_topics_sync /root/harness/state/telegram-topics.json "${TG_TOPICS_SYNC_SECS:-600}" >/dev/null 2>&1 || true
      if [ -n "$TG_THREAD" ] && [ -f /root/harness/state/telegram-topics.json ]; then
        # BOTH SHAPES. The verb writes {"topics":{...}}; the file this handler
        # has always read was a root map. `(.topics // .)` resolves either, so a
        # box mid-migration never loses its topic names.
        TG_TOPIC=$(jq -r --arg t "$TG_THREAD" '(.topics // .)|to_entries|map(select((.value|tostring)==$t))|.[0].key // ""' \
                     /root/harness/state/telegram-topics.json 2>/dev/null)
      fi
      ATTRIB=""
      if [ -n "$TG_FROM" ]; then
        ATTRIB="[telegram: from ${TG_FROM}${TG_USER:+ (@$TG_USER)}${TG_TOPIC:+, topic $TG_TOPIC} — a full-authority principal of the the operator Harness group]"
      fi
      # WHICH FRONT DOOR (BH-618). Every payload before Slack existed carries no
      # transport at all, so absent (and jq's "null") means telegram and the
      # header above is untouched. A Slack message names its channel instead of
      # a topic; a Slack DM names neither.
      TG_TRANSPORT=$(jq -r '.transport // "telegram"' <<<"$PAYLOAD")
      case "$TG_TRANSPORT" in ''|null) TG_TRANSPORT=telegram ;; esac
      SL_CHAN=$(jq -r '.channel_name // ""' <<<"$PAYLOAD"); case "$SL_CHAN" in null) SL_CHAN="" ;; esac
      if [ "$TG_TRANSPORT" = slack ] && [ -n "$TG_FROM" ]; then
        ATTRIB="[slack: from ${TG_FROM}${SL_CHAN:+, #$SL_CHAN} — a full-authority principal of the the operator Harness group]"
      fi
      # Web-chat threading (2026-08-23): a dash-origin message needs its command
      # id carried to the orchestrator so the reply can be beaten back to the
      # browser that asked. It rides a SIDECAR rather than the message body —
      # the body is the prompt, and an inbox file written by an older poller (or
      # by tg-media.sh) simply has no sidecar and behaves exactly as before.
      ORIGIN=$(jq -r '.origin // ""' <<<"$PAYLOAD")
      case "$ORIGIN" in null) ORIGIN="" ;; esac
      # The message's own ids ride along too (BH-5336): the orchestrator holds a
      # reply inside an in-flight turn's thread until that turn ends. Slack sends
      # message_ts; Telegram message_id/reply_to_message_id when the console has them.
      if [ -n "$ORIGIN" ] || [ -n "$TG_FROM" ]; then
        jq -nc --arg id "$ID" --arg o "$ORIGIN" --arg f "$TG_FROM" --arg u "$TG_USER" \
           --arg c "$TG_CHAT" --arg th "$TG_THREAD" --arg tp "$TG_TOPIC" --arg tr "$TG_TRANSPORT" \
           --arg mi "$(jq -r '.message_id // "" | tostring' <<<"$PAYLOAD")" \
           --arg rt "$(jq -r '.reply_to_message_id // "" | tostring' <<<"$PAYLOAD")" \
           --arg mts "$(jq -r '.message_ts // "" | tostring' <<<"$PAYLOAD")" \
           '{command_id:$id,origin:$o,project:"orchestrator",from_name:$f,from_username:$u,chat_id:$c,thread_id:$th,topic:$tp,transport:$tr,message_id:$mi,reply_to_message_id:$rt,message_ts:$mts}' > "$MSGF.meta"
      fi
      if jq -e '.media | length > 0' <<<"$PAYLOAD" >/dev/null 2>&1; then
        # Media messages: download attachments + transcribe audio, then compose.
        # Backgrounded so a slow download/transcription never stalls the poller.
        PF=$(mktemp /root/orchestrator/inbox/payload-XXXXXX.json)
        printf %s "$PAYLOAD" > "$PF"
        ( { [ -n "$ATTRIB" ] && printf '%s\n' "$ATTRIB"; "$HARNESS/bin/tg-media.sh" "$PF"; } > "$MSGF" 2>>"$HARNESS/logs/tg-media.log"
          rm -f "$PF"
          setsid "$HARNESS/bin/orchestrate.sh" "$MSGF" </dev/null >/dev/null 2>&1 & ) &
        OK=true; RESULT="media message handed to orchestrator"
      else
        { [ -n "$ATTRIB" ] && printf '%s\n' "$ATTRIB"; jq -r '.text // ""' <<<"$PAYLOAD"; } > "$MSGF"
        # Spawned after the ack below (BH-4995.1), so this ack can never land
        # on top of the turn's own queued_behind/running/answered status.
        ORC_SPAWN="$MSGF"
        OK=true; RESULT="handed to orchestrator"
      fi
      fi ;;
    # <<< chat handler
    # >>> update_company_map handler (tests/ssh-forward-hardening-test.sh runs this block)
    update_company_map)
      # BH-2657: no hub temp file any more. A far box's map rides INSIDE the
      # queued row's payload (a function argument, then stdin to jq, and
      # _jobs_req spills a body over the argv cap to a file), and bcx_run writes
      # its own temp file wherever the map is applied.
      if [ -z "$(jq -j '.content // ""' <<<"$PAYLOAD" 2>/dev/null)" ]; then RESULT="refused: empty map content"; else
        BOX=$("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || true)
        if [ -z "$BOX" ]; then RESULT="unknown project $PROJECT"
        elif [ "$BOX" = local ]; then
          if ! command -v bcx_run >/dev/null 2>&1; then RESULT="local run failed (box-cmd-exec not loaded)"
          else bcx_run update_company_map "$PROJECT" "$PAYLOAD" "$ID"; [ "$BCX_OK" = 1 ] && OK=true; RESULT="$BCX_RESULT"; fi
        elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
          RESULT="forward to $BOX failed (box-console-commands client not loaded)"
        elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$BOX")" update_company_map "$PROJECT" "$PAYLOAD" >/dev/null; then
          OK=true; RESULT="queued for $BOX (box command $ID)"
        else RESULT="forward to $BOX failed (jobs worker ${JOBS_HTTP:-unreachable})"; fi
      fi ;;
    # <<< update_company_map handler
    # >>> chat_proposal handler (tests/slug-injection-test.sh runs this block)
    chat_proposal)
      # One idea-chat turn — runs detached on the owning box (a grounded chat
      # session takes 1-2 min; never block the poller). bcx_run builds the
      # {message,origin} b64 there, from the payload.
      SLUG=$(jq -r '.slug // ""' <<<"$PAYLOAD")
      # The slug is rejected unless it is a plain slug — never stripped into a
      # different one, which would act on the wrong proposal. Checked here so a
      # hostile one is never queued, and again by bcx_run on the box that runs it.
      case "$SLUG" in ''|*[!A-Za-z0-9_-]*) SLUG="" ;; esac
      if [ -z "$SLUG" ]; then RESULT="refused: missing or invalid slug"
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') chat_proposal id=$ID -> REFUSED (slug not [A-Za-z0-9_-]+)" >> "$HARNESS/logs/console-commands.log"
      else
        BOX=$("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || true)
        if [ -z "$BOX" ]; then RESULT="unknown project $PROJECT"
        elif [ "$BOX" = local ]; then
          if ! command -v bcx_run >/dev/null 2>&1; then RESULT="local run failed (box-cmd-exec not loaded)"
          else bcx_run chat_proposal "$PROJECT" "$PAYLOAD" "$ID"; [ "$BCX_OK" = 1 ] && OK=true; RESULT="$BCX_RESULT"; fi
        elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
          RESULT="forward to $BOX failed (box-console-commands client not loaded)"
        elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$BOX")" chat_proposal "$PROJECT" "$PAYLOAD" >/dev/null; then
          OK=true; RESULT="queued for $BOX (box command $ID)"
        else RESULT="forward to $BOX failed (jobs worker ${JOBS_HTTP:-unreachable})"; fi
      fi ;;
    # <<< chat_proposal handler
    # >>> proposal_gate handler (tests/slug-injection-test.sh runs this block)
    post_proposal|kill_proposal|revise_proposal)
      # Gate decisions from the Product Cockpit / Telegram. Like run_triage,
      # each project's product stage runs ONLY on its owning box.
      SLUG=$(jq -r '.slug // ""' <<<"$PAYLOAD")
      # Same slug rule as chat_proposal above: reject, never strip.
      case "$SLUG" in ''|*[!A-Za-z0-9_-]*) SLUG="" ;; esac
      if [ -z "$SLUG" ]; then RESULT="refused: missing or invalid slug"
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $TYPE id=$ID -> REFUSED (slug not [A-Za-z0-9_-]+)" >> "$HARNESS/logs/console-commands.log"
      else
        BOX=$("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || true)
        if [ -z "$BOX" ]; then RESULT="unknown project $PROJECT"
        elif [ "$BOX" = local ]; then
          if ! command -v bcx_run >/dev/null 2>&1; then RESULT="local run failed (box-cmd-exec not loaded)"
          else bcx_run "$TYPE" "$PROJECT" "$PAYLOAD" "$ID"; [ "$BCX_OK" = 1 ] && OK=true; RESULT="$BCX_RESULT"; fi
        elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
          RESULT="forward to $BOX failed (box-console-commands client not loaded)"
        elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$BOX")" "$TYPE" "$PROJECT" "$PAYLOAD" >/dev/null; then
          OK=true; RESULT="queued for $BOX (box command $ID)"
        else RESULT="forward to $BOX failed (jobs worker ${JOBS_HTTP:-unreachable})"; fi
      fi ;;
    # <<< proposal_gate handler
    # >>> pause handlers (tests/poll-commands-pause.bh-1685-test.sh runs this block)
    # BH-1672: a pause is also a row in the jobs worker's pauses table (the wire
    # contract is the header of bin/lib/pause.sh). pause_board/resume_board keep
    # the flag file as this box's authority and write it FIRST; the row is
    # second, and a row that did not land is named in RESULT while OK stays
    # true, because the flag took effect. pause_set/pause_end have no flag: the
    # row is their only effect, so a failed write is a failed command.
    # Bodies are built with jq --arg only; every write goes to /api/pauses*.
    # The worker 400s a blank reason ("reason required"), so a blank or missing
    # reason (the MCP tool, a bare action) is recorded as "paused from console,
    # no reason given", never sent blank; a typed reason is sent as typed,
    # trimmed. The row's actor is the command's own `actor` when it fits the
    # worker's actor charset, and "console" otherwise: a missing, non-string or
    # malformed actor is never sent. (BH-2515: the console's Pages function
    # stamps one, but harness-console's pauseCommand() drops it today, so
    # console-issued pauses still arrive without one and record "console".)
    pause_board)
      set_flag "paused-$PROJECT" on "console"; OK=true
      PACTOR=$(jq -r 'if (.actor | type) == "string" then .actor else "" end' <<<"$PAYLOAD" 2>/dev/null)
      [[ "$PACTOR" =~ ^[A-Za-z0-9._@-]{1,96}$ ]] || PACTOR="console"
      PREASON=$(jq -r '.reason // "" | tostring | sub("^\\s+"; "") | sub("\\s+$"; "")' <<<"$PAYLOAD" 2>/dev/null)
      [ -n "$PREASON" ] || PREASON="paused from console, no reason given"
      PTTL=$(jq -r '.ttl_s // "" | tostring' <<<"$PAYLOAD" 2>/dev/null)
      # A bad ttl is dropped, not refused: the flag must set.
      [[ "$PTTL" =~ ^[1-9][0-9]*$ ]] || PTTL=""
      # A BOARD PAUSE ALWAYS CARRIES ITS OWN EXPIRY. With no ttl_s the worker
      # applied its generic pause_default_ttl_s (86400), so a console pause
      # lapsed 24h after the last pause with nothing saying when. A payload
      # ttl_s still wins; otherwise the poll-commands settings row
      # PAUSE_BOARD_TTL_S (default 604800, the worker's one-week ceiling), and
      # a value that is not a positive integer falls back to that default.
      if [ -z "$PTTL" ]; then
        PTTL="${PAUSE_BOARD_TTL_S:-604800}"
        [[ "$PTTL" =~ ^[1-9][0-9]*$ ]] || PTTL=604800
      fi
      PBODY=$(jq -nc --arg p "$PROJECT" --arg r "$PREASON" --arg t "$PTTL" --arg a "$PACTOR" \
        '{scope:$p,what:"triage",reason:$r,actor:$a} + (if $t == "" then {} else {ttl_s:($t|tonumber)} end)')
      # In THIS shell (never `$( )`), so JOBS_HTTP reaches the failure RESULT;
      # the answer is read back from JOBS_BODY, which _jobs_req sets.
      if _jobs_req PUT /api/pauses "$PBODY" >/dev/null; then
        # The RESULT names the expiry the worker actually stored (after its
        # clamp), and only when it is an ISO time: never free text from a body.
        PEXP=$(jq -r '.pause.expires_at // "" | tostring' <<<"${JOBS_BODY:-}" 2>/dev/null)
        [[ "$PEXP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] || PEXP=""
        RESULT="paused${PEXP:+ until $PEXP}"
      else RESULT="paused (flag set; pause row not recorded: http=${JOBS_HTTP:-unreachable})"; fi ;;
    resume_board)
      set_flag "paused-$PROJECT" off "console"; OK=true; RESULT="resumed"
      # End only THIS project's live triage row: never a fleet row, another
      # project's, or another what.
      PERR=""
      if PLIST=$(_jobs_req GET "/api/pauses?active=1&scope=$(jq -rn --arg p "$PROJECT" '$p|@uri')"); then
        for PID in $(jq -r --arg p "$PROJECT" '.pauses[]? | select(.scope == $p and .what == "triage" and .ended_at == null) | .id | tostring' <<<"$PLIST" 2>/dev/null); do
          [[ "$PID" =~ ^[0-9]+$ ]] || continue
          _jobs_req POST "/api/pauses/$PID/end" '{}' >/dev/null || PERR="http=${JOBS_HTTP:-unreachable}"
        done
      else PERR="http=${JOBS_HTTP:-unreachable}"; fi
      [ -n "$PERR" ] && RESULT="resumed (flag cleared; pause row not ended: $PERR)" ;;
    pause_set)
      PWHAT=$(jq -r '.what // "" | tostring' <<<"$PAYLOAD" 2>/dev/null)
      PACTOR=$(jq -r 'if (.actor | type) == "string" then .actor else "" end' <<<"$PAYLOAD" 2>/dev/null)
      [[ "$PACTOR" =~ ^[A-Za-z0-9._@-]{1,96}$ ]] || PACTOR="console"
      PREASON=$(jq -r '.reason // "" | tostring | sub("^\\s+"; "") | sub("\\s+$"; "")' <<<"$PAYLOAD" 2>/dev/null)
      [ -n "$PREASON" ] || PREASON="paused from console, no reason given"
      # A fleet-wide pause arrives as project=hub (the console routes every
      # fleet-scope action to the hub) with payload scope "fleet", exactly.
      # Anything else is the command's own project, and "hub" is not one.
      PSCOPE="$PROJECT"
      [ "$(jq -r '.scope // "" | tostring' <<<"$PAYLOAD" 2>/dev/null)" = fleet ] && PSCOPE=fleet
      PTTL=$(jq -r 'if has("ttl_s") and .ttl_s != null then (.ttl_s | tostring) else "" end' <<<"$PAYLOAD" 2>/dev/null)
      PHASTTL=$(jq -r 'has("ttl_s") and .ttl_s != null' <<<"$PAYLOAD" 2>/dev/null)
      case "$PWHAT" in reviews|merges|builds|triage) ;; *) PWHAT="" ;; esac
      if [ -z "$PWHAT" ]; then RESULT="refused: invalid what"
      elif [ "$PHASTTL" = true ] && ! [[ "$PTTL" =~ ^[1-9][0-9]*$ ]]; then RESULT="refused: invalid ttl_s"
      elif [ -z "$PSCOPE" ] || [ "$PSCOPE" = null ] || [ "$PSCOPE" = hub ]; then RESULT="refused: no project"
      else
        PBODY=$(jq -nc --arg p "$PSCOPE" --arg w "$PWHAT" --arg r "$PREASON" --arg t "$PTTL" --arg a "$PACTOR" \
          '{scope:$p,what:$w,reason:$r,actor:$a} + (if $t == "" then {} else {ttl_s:($t|tonumber)} end)')
        if _jobs_req PUT /api/pauses "$PBODY" >/dev/null; then OK=true; RESULT="paused $PWHAT on $PSCOPE"
        else RESULT="pause not recorded: http=${JOBS_HTTP:-unreachable}"; fi
      fi ;;
    pause_end)
      # The id lands in a URL path, so it is digits or nothing.
      PID=$(jq -r '.id // "" | tostring' <<<"$PAYLOAD" 2>/dev/null)
      if ! [[ "$PID" =~ ^[0-9]+$ ]]; then RESULT="refused: invalid id"
      else
        _jobs_req POST "/api/pauses/$PID/end" '{}' >/dev/null; PRC=$?
        case "$PRC" in
          0) OK=true; RESULT="pause $PID ended" ;;
          2) RESULT="no such pause $PID" ;;
          *) RESULT="pause $PID not ended: http=${JOBS_HTTP:-unreachable}" ;;
        esac
      fi ;;
    # <<< pause handlers
    # >>> factory_stop handler (tests/poll-commands-factory-stop.bh-3687-test.sh runs this block)
    # BH-3687: {state:"on"|"off", reason, actor?} runs bin/factory-stop.sh, so
    # every path writes the same settings row and says ON/OFF only after the
    # same re-read. RESULT is the CLI's last line; OK only on its rc 0. A
    # blank reason is REFUSED, never defaulted as pause_set does: an unexplained
    # factory stop is what the audit row must not hold. The CLI's rc 2 (it
    # refused its args) is a refusal too; rc 1 and rc 3 stay retryable.
    factory_stop)
      FSTATE=$(jq -r '.state // "" | tostring' <<<"$PAYLOAD" 2>/dev/null)
      FREASON=$(jq -r '.reason // "" | tostring | sub("^\\s+"; "") | sub("\\s+$"; "")' <<<"$PAYLOAD" 2>/dev/null)
      PACTOR=$(jq -r 'if (.actor | type) == "string" then .actor else "" end' <<<"$PAYLOAD" 2>/dev/null)
      [[ "$PACTOR" =~ ^[A-Za-z0-9._@-]{1,96}$ ]] || PACTOR="console"
      case "$FSTATE" in on|off) ;; *) FSTATE="" ;; esac
      if [ -z "$FSTATE" ]; then RESULT="refused: invalid state"; OUTCOME=refused
      elif [ -z "$FREASON" ]; then RESULT="refused: reason required"; OUTCOME=refused
      else
        FOUT=$(FACTORY_STOP_ACTOR="$PACTOR" "$HARNESS/bin/factory-stop.sh" "$FSTATE" --reason "$FREASON" 2>&1); FRC=$?
        RESULT=$(printf '%s\n' "$FOUT" | awk 'NF{l=$0} END{print l}' | cut -c1-300)
        [ -n "$RESULT" ] || RESULT="factory-stop.sh said nothing (rc $FRC)"
        case "$FRC" in
          0) OK=true ;;
          2) OUTCOME=refused ;;
        esac
      fi ;;
    # <<< factory_stop handler
    # >>> automerge handlers (tests/automerge-scope.bh-2322-test.sh runs this block)
    automerge_off|automerge_on)
      # SCOPE FOLLOWS THE COMMAND'S PROJECT (#2322). The Project page toggle
      # sends its own project and means that board only; the dashboard KILL
      # button and chat /kill send 'all' and mean the fleet. This used to write
      # the fleet-wide automerge-disabled for both, so one board's toggle
      # stopped auto-merge everywhere. A project writes automerge-disabled-<p>,
      # which every per-project merge writer reads next to the fleet switch.
      # A fleet.conf that could not be read is retryable, never `refused:`
      # (BH-2009: the console reads refused as terminal).
      AMSTATE=on; [ "$TYPE" = automerge_on ] && AMSTATE=off
      AMFLAG=""; AMWHO=""
      if [ -z "$PROJECT" ] || [ "$PROJECT" = null ] || [ "$PROJECT" = all ]; then
        AMFLAG=automerge-disabled; AMWHO="fleet-wide"
      elif ! [[ "$PROJECT" =~ ^[A-Za-z0-9._-]+$ ]]; then
        RESULT="refused: invalid project '$PROJECT'"
      elif ! AMPJS=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null) || [ -z "${AMPJS//[[:space:]]/}" ]; then
        RESULT="auto-merge not changed: fleet-conf --projects could not be read; retry"
      elif grep -qxF -- "$PROJECT" <<<"$AMPJS"; then
        AMFLAG="automerge-disabled-$PROJECT"; AMWHO="for $PROJECT"
      else
        RESULT="refused: unknown project '$PROJECT'"
      fi
      if [ -n "$AMFLAG" ]; then
        set_flag "$AMFLAG" "$AMSTATE" "console"; OK=true
        if [ "$AMSTATE" = on ]; then RESULT="auto-merge disabled $AMWHO"; else RESULT="auto-merge enabled $AMWHO"; fi
        # BH-4153: the fleet switch is a harness_flags row; flag_has reads it
        # DB-first (the file when no worker is configured). An unreadable
        # switch is said so, never reported as off.
        if [ "$AMSTATE" = off ] && [ "$AMFLAG" != automerge-disabled ]; then
          if command -v flag_has >/dev/null 2>&1; then flag_has automerge-disabled >/dev/null 2>&1; AMFK=$?
          else [ -e "$HARNESS/flags/automerge-disabled" ]; AMFK=$?; fi
          case "$AMFK" in
            0) RESULT="$RESULT (the fleet kill switch automerge-disabled is still on)" ;;
            2) RESULT="$RESULT (the fleet kill switch automerge-disabled could not be read; until it can, the fleet treats it as on)" ;;
          esac
        fi
      fi ;;
    # <<< automerge handlers
    # >>> ticket hold handler (tests/ticket-hold-cmd.bh-2326-test.sh runs this block)
    # Runs here on the hub for every project, never forwarded. rc 3 is a
    # refusal and carries outcome=refused so the console stops re-leasing it
    # (BH-932); rc 1 is a retryable failure.
    hold_ticket|unhold_ticket)
      if command -v thc_run >/dev/null 2>&1; then
        RESULT=$(thc_run "${TYPE%_ticket}" "$PROJECT" "$PAYLOAD"); THRC=$?
        case "$THRC" in
          0) OK=true ;;
          3) OUTCOME=refused ;;
        esac
        [ -n "$RESULT" ] || RESULT="ticket hold not run (no result, rc $THRC)"
      else RESULT="ticket hold not run (lib not loaded)"; fi ;;
    # <<< ticket hold handler
    # >>> comment_issue handler (tests/issue-comment-cmd.bh-5820-test.sh runs this block)
    # Runs here on the hub, never forwarded: one App comment per command id.
    # rc 3 is a refusal (outcome=refused); rc 1 is a retryable failure.
    comment_issue)
      if command -v icc_run >/dev/null 2>&1; then
        RESULT=$(icc_run "$PROJECT" "$PAYLOAD" "$ID"); ICRC=$?
        case "$ICRC" in
          0) OK=true ;;
          3) OUTCOME=refused ;;
        esac
        [ -n "$RESULT" ] || RESULT="comment not posted (no result, rc $ICRC)"
      else RESULT="comment not posted (lib not loaded)"; fi ;;
    # <<< comment_issue handler
    # >>> fleet control handler (tests/poll-commands-fleet-control.bh-6737-test.sh runs this block)
    # BH-6737. The Fly pool (fly-pool.sh, flags/fly-pool-*, state/fly/, fly.env)
    # exists only on the hub, so these run here for every project and are never
    # forwarded. Each bin/cmd-<x>.sh prints one JSON line. rc 3 is a refusal
    # (outcome=refused, BH-932); any other non-zero rc is a retryable failure.
    dispatch_issue|machine_ctl|pool_cap|pool_hold)
      case "$TYPE" in
        dispatch_issue) FCS=cmd-dispatch-issue.sh; FCT=60 ;;
        machine_ctl)    FCS=cmd-machine-ctl.sh;    FCT=150 ;;
        pool_hold)      FCS=cmd-pool-hold.sh;      FCT=30 ;;
        *)              FCS=cmd-pool-cap.sh;       FCT=30 ;;
      esac
      RESULT=$(timeout "$FCT" "$HARNESS/bin/$FCS" "$PROJECT" "$PAYLOAD" "$ID" 7>&- 2>/dev/null); FCRC=$?
      case "$FCRC" in
        0) OK=true ;;
        3) OUTCOME=refused ;;
        124) RESULT=$(jq -nc --arg r "timed out after ${FCT}s" '{result:"failed",reason:$r}') ;;
      esac
      [ -n "$RESULT" ] || RESULT=$(jq -nc --arg r "$FCS gave no result (rc $FCRC)" '{result:"failed",reason:$r}') ;;
    # <<< fleet control handler
    # >>> run_script handler (tests/poll-commands-fleet-control.bh-6737-test.sh runs this block)
    # BH-6737. Row project `hub` runs here; a fleet project runs on the box that
    # owns it (bcx_run here, or a box_console_commands row for a far box), the
    # run_triage shape. bin/cmd-run-script.sh runs only allowlisted scripts.
    run_script)
      jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || PAYLOAD='{}'
      BOX=local; [ "$PROJECT" = hub ] || BOX=$("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || true)
      if [ -z "$BOX" ]; then RESULT="unknown project $PROJECT"
      elif [ "$BOX" = local ]; then
        if ! command -v bcx_run >/dev/null 2>&1; then RESULT="local run failed (box-cmd-exec not loaded)"
        else
          bcx_run run_script "$PROJECT" "$PAYLOAD" "$ID"; [ "$BCX_OK" = 1 ] && OK=true; RESULT="$BCX_RESULT"
          [ "$(jq -r '.result? // ""' <<<"$RESULT" 2>/dev/null)" = refused ] && OUTCOME=refused
        fi
      elif ! command -v box_ccmd_forward >/dev/null 2>&1 || ! command -v cron_box_id_for >/dev/null 2>&1; then
        RESULT="forward to $BOX failed (box-console-commands client not loaded)"
      elif JOBS_HTTP=""; box_ccmd_forward "$ID" "$(cron_box_id_for "$BOX")" run_script "$PROJECT" "$PAYLOAD" >/dev/null; then
        OK=true; RESULT="queued for $BOX (box command $ID)"
      else RESULT="forward to $BOX failed (jobs worker ${JOBS_HTTP:-unreachable})"; fi ;;
    # <<< run_script handler
    *) RESULT="unknown command type $TYPE" ;;
  esac
    # >>> command ack (tests/poll-commands-refusal-ack.bh-932-test.sh runs this block)
  # `outcome` is sent only when set, so every other ack is byte-for-byte today's.
  API -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --argjson ok "$OK" --arg r "$RESULT" --arg o "$OUTCOME" '{ok:$ok,result:$r} + (if $o == "" then {} else {outcome:$o} end)')" \
    "$CONSOLE_URL/api/commands/$ID/ack" >/dev/null
    # <<< command ack
    # >>> merge_pr key release (tests/merge-pr-release.bh-4917-test.sh runs this block)
  # The console keeps a terminal refusal under <project>:<ticket>:merge_pr and
  # hands it back to every later merge_pr; #4439 only renamed it for Pages
  # requests carrying verdict_sha. This renames it for every entry point, after
  # the ack, through the console's Pages endpoint /api/merge-pr/release (the hub
  # keeps no D1 access, BH-3905): its UPDATE re-checks status = 'refused', so a
  # lost ack frees nothing.
  if [ "$TYPE" = merge_pr ] && [ "$OUTCOME" = refused ] && [[ "$RESULT" == "refused: head moved"* ]] \
     && command -v mpr_release_head_moved >/dev/null 2>&1; then
    mpr_release_head_moved "$ID" "$HARNESS/logs/console-commands.log" || true
  fi
    # <<< merge_pr key release
    # >>> chat spawn after ack (tests/orchestrate-queue-status.bh-5028-test.sh runs this block)
  if [ -n "${ORC_SPAWN:-}" ]; then
    (setsid "$HARNESS/bin/orchestrate.sh" "$ORC_SPAWN" </dev/null >/dev/null 2>&1 &)
    ORC_SPAWN=""
  fi
    # <<< chat spawn after ack
done
    # >>> box-command expiry (BH-2528)
    # A forwarded command no box claimed within BOX_CONSOLE_COMMANDS_TTL_S is
    # flipped to expired by the worker, which returns each such row exactly
    # once. The hub answers it here: the fetch/chat failure beat the handler
    # would have sent, a console-commands.log line per row, and one ALERTS line
    # per box. A claim nobody answered within twice the TTL is listed on every
    # call, so each stale id pages once (state/box-console-commands-stale.ids).
    # A failed call is one poll-commands.log line; the next sub-cycle retries.
    # The answer goes to a file, not $(...), so JOBS_HTTP survives for the log.
    if command -v box_ccmd_expire >/dev/null 2>&1; then
      BCTTL="${BOX_CONSOLE_COMMANDS_TTL_S:-300}"
      BCS() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9_.:-' | head -c 64; }
      EF=$(mktemp) || EF=""
      if [ -n "$EF" ]; then
        box_ccmd_expire "$BCTTL" > "$EF"; ERC=$?
        BCNOW=$(date -u '+%Y-%m-%d %H:%M:%SZ')
        if [ "$ERC" -ne 0 ]; then
          echo "$BCNOW box-console-commands expire failed rc=$ERC http=${JOBS_HTTP:-unreachable}" >> "$HARNESS/logs/poll-commands.log"
        else
          while IFS= read -r XROW; do
            [ -n "$XROW" ] || continue
            XT=$(jq -r '.type // ""' <<<"$XROW"); XID=$(jq -r '.command_id // ""' <<<"$XROW")
            XBOX=$(jq -r '.box // ""' <<<"$XROW"); XPROJ=$(jq -r '.project // ""' <<<"$XROW")
            case "$XPROJ" in null) XPROJ="" ;; esac
            XPL=$(jq -r '.payload // "{}"' <<<"$XROW")
            XWHICH=$(jq -r '.which // ""' <<<"$XPL" 2>/dev/null); case "$XWHICH" in null) XWHICH="" ;; esac
            XKEY=$(jq -r '.key // ""' <<<"$XPL" 2>/dev/null); case "$XKEY" in null) XKEY="" ;; esac
            case "$XT" in
              fetch_log) $BEAT "$("$HARNESS/bin/fetch-log.sh" --error "$XPROJ" "$XWHICH" "$XID" fetch_failed)" ;;
              fetch_artifact) $BEAT "$("$HARNESS/bin/fetch-artifact.sh" --error "$XPROJ" "$XKEY" "$XWHICH" "$XID" fetch_failed)" ;;
              chat) $BEAT "$(jq -nc --arg id "$XID" --arg p "$XPROJ" --arg ts "$BCNOW" \
                      --arg t "$XPROJ box $(BCS "$XBOX") did not pick this up within ${BCTTL}s" \
                      '{kind:"chat_reply",rkey:("chat:"+$id),command_id:$id,project:$p,text:$t,error:"routing_failed",ts:$ts}')" ;;
            esac
            echo "$BCNOW box_command_expired id=$(BCS "$XID") type=$(BCS "$XT") box=$(BCS "$XBOX") project=$(BCS "$XPROJ")" >> "$HARNESS/logs/console-commands.log"
          done < <(jq -c '.expired[]' "$EF")
          # One line per box; the worker sorts expired oldest first.
          # @tsv escapes newlines; its tabs become \x1f because tab is IFS whitespace
          # and an empty field would collapse and shift the rest.
          while IFS=$'\x1f' read -r XBOX XN XT XID; do
            [ -n "$XBOX$XID" ] || continue
            echo "$BCNOW [box-console-commands] $(BCS "$XBOX"): $XN command(s) expired unclaimed after ${BCTTL}s (oldest $(BCS "$XT") $(BCS "$XID")); is bin/box-console-commands.sh running there?" >> "$HARNESS/logs/ALERTS.log"
          done < <(jq -r '.expired as $r | ($r | map(.box) | unique)[] as $b | [$r[] | select(.box == $b)]
                    | [($b // ""), (length|tostring), (.[0].type // ""), (.[0].command_id // "")] | @tsv' "$EF" | tr '\t' '\037')
          SF="$HARNESS/state/box-console-commands-stale.ids"
          mkdir -p "$HARNESS/state"; touch "$SF"
          STALE=$(jq -r '.stale_claimed[] | [(.box // ""), (.command_id // "")] | @tsv' "$EF" | tr '\t' '\037')
          for XBOX in $(cut -d$'\x1f' -f1 <<<"$STALE" | while IFS= read -r b; do BCS "$b"; echo; done | sort -u); do
            NEW=""
            while IFS=$'\x1f' read -r b i; do
              [ "$(BCS "$b")" = "$XBOX" ] || continue
              i=$(BCS "$i"); [ -n "$i" ] || continue
              grep -qxF -- "$i" "$SF" && continue
              NEW="${NEW:+$NEW,}$i"; echo "$i" >> "$SF"
            done <<<"$STALE"
            [ -z "$NEW" ] || echo "$BCNOW [box-console-commands] $XBOX: command(s) claimed but never answered: $NEW" >> "$HARNESS/logs/ALERTS.log"
          done
          # Forget ids that are no longer stale, but only against a complete list.
          if [ "$(jq -r '.stale_truncated' "$EF")" = false ]; then
            cut -d$'\x1f' -f2 <<<"$STALE" | while IFS= read -r i; do BCS "$i"; echo; done | grep . | sort -u > "$SF.new"
            mv "$SF.new" "$SF"
          fi
        fi
        rm -f "$EF"
      fi
    fi
    # <<< box-command expiry
[ "$CYCLE" -lt 4 ] && sleep 15
done

# --- 2. sync new alert lines (cursor = byte offset) ---
# >>> alerts re-beat
# This block KEEPS RUNNING with flags/alerts-db on (BH-1070). ALERTS.log is
# still the fleet's append-only alert record, this is still the only path that
# carries a line an emitter wrote straight into it, and beat.sh's state machine
# is where the row-vs-file decision is made — not here. The markers exist so
# tests/alerts-table-test.sh can source the block that ships.
AL=$HARNESS/logs/ALERTS.log; CUR=$HARNESS/flags/.alerts-cursor
# The condition-id rule (V1): functions only, guarded against double sourcing,
# and a missing library leaves the row_key fallback below.
# shellcheck source=bin/lib/alert-state.sh
. "$HARNESS/bin/lib/alert-state.sh" 2>/dev/null || true
if [ -f "$AL" ]; then
  SIZE=$(wc -c < "$AL"); LAST=$(cat "$CUR" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt "$LAST" ]; then
    tail -c +$((LAST + 1)) "$AL" | while IFS= read -r LINE; do
      [ -n "$LINE" ] || continue
      # bin/alert-line.sh already noted this exact line at emit time and left a
      # marker (BH-2314): one emission is one table note, so skip it here.
      MK="$HARNESS/state/alert-line-sent/$(printf %s "$LINE" | sha1sum | cut -c1-40)"
      if [ -e "$MK" ]; then rm -f "$MK"; continue; fi
      # The akey used to be md5 of the WHOLE line — which begins with a UTC
      # timestamp, so the same unchanged condition minted a brand-new console row
      # and a fresh Telegram page on every emission, forever. This path skips the
      # quarantine and the triage lane entirely (kind:"alert", not fleet_alert),
      # so it had no brake of any kind on it.
      #
      # It is keyed on row_key + the UTC day: a persistent condition says itself
      # once a day instead of once per write, and a genuinely new one still pages
      # at once. row_key, NOT family, because family() folds digit runs — TK-1
      # and TK-99 stuck at different hours are ONE family, and keying a console
      # ROW on that would have traded this over-paging bug for silently losing
      # the second stuck build. Nothing downstream could recover it either;
      # unlike the medic's brake, which only skipped a session while every alert
      # kept its row, a collapse here is a row that never exists.
      #
      # V1 alert hygiene (2026-09-25): NO DATE. The day suffix re-opened the same
      # condition as a fresh console row, and a fresh page, every UTC day — 1,036
      # deferred lines over 533 families on the day this changed. Repeats are the
      # state machine's job (bin/beat.sh: fire once, remind, resolve), and the
      # console re-opens a resolved row when its akey fires again. The key is the
      # state machine's own condition id (collapse rules + aliases, then row_key),
      # so this row and the emitter's own beat name ONE condition; row_key alone
      # is the fallback when the library is not there.
      AKEY=""
      command -v alert_state_key >/dev/null 2>&1 && AKEY=$(alert_state_key "$LINE" 2>/dev/null)
      [ -n "$AKEY" ] || AKEY=$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);from alert_family import row_key;print(row_key(sys.argv[2]))' \
               "$HARNESS/bin" "$LINE" 2>/dev/null) || AKEY=""
      [ -n "$AKEY" ] && AKEY="alert:$AKEY"
      # Fail OPEN: if the normalizer is unavailable, page exactly as before
      # rather than letting a helper's absence silence an alert.
      [ -n "$AKEY" ] || AKEY=$(printf %s "$LINE" | md5sum | cut -c1-16)
      # The project an alert beat is tagged with decides which Telegram topic
      # it lands in. This read a bracketed prefix from a three-name list, so
      # every other project's alerts arrived in General.
      PROJ=$("$HARNESS/bin/project-of.sh" "$LINE" 2>/dev/null || echo "")
      $BEAT "$(jq -nc --arg k "alert" --arg akey "$AKEY" --arg p "${PROJ:-}" --arg l "$LINE" '{kind:$k,akey:$akey,project:$p,line:$l}')"
    done
    echo "$SIZE" > "$CUR"
  fi
fi
# <<< alerts re-beat

# --- 3. flags beat (cheap, keeps dashboard truthful) ---
# Reconcile from the DB first, so a pause set in the console lands on this box
# within the minute. flag_active reconciles last-writer-wins on the row's
# updated_at against the file's mtime (the row wins ties), so a later local
# touch/rm is only undone by a row written after it; an unreachable worker
# changes nothing at all.
# >>> flags beats
# Read the list ONCE and refuse on empty. Every registry project gets a flags
# beat: a project absent from this loop has no paused/automerge row on the
# dashboard at all, which renders as running — and an empty list silently does
# that to the whole fleet.
FLAG_PROJECTS=$("$HARNESS/bin/fleet-projects-or-alert.sh" poll-commands) || exit 1
# fb_on <name> — the flag as this box reads it: flag_active (BH-4153: the
# paused-*/automerge-disabled* rows DB-first) when the client is loaded, else
# the file.
fb_on() { if command -v flag_active >/dev/null 2>&1; then flag_active "$1" >/dev/null 2>&1; else [ -f "$HARNESS/flags/$1" ]; fi; }
if command -v flag_active >/dev/null 2>&1; then
  # The alerts-table switch reaches the box the same reconcile a pause
  # did: console flip -> row -> this reconcile -> flags/alerts-db. Without it
  # the slice could only ever be turned on by hand, on each box.
  flag_active alerts-db >/dev/null 2>&1 || true
fi
FLEET_AM=true; fb_on automerge-disabled && FLEET_AM=false
# env_pauses: the pause shapes this box's env carries (BH-1672), read once.
# Anything that is not a JSON array — nothing, garbage, no lib — is [].
ENVP_JSON='[]'
if command -v pause_env_shapes >/dev/null 2>&1; then
  ENVP=$(pause_env_shapes 2>/dev/null) || ENVP=""
  [ -n "$ENVP" ] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$ENVP" && ENVP_JSON=$(jq -c . <<<"$ENVP")
fi
for p in $FLAG_PROJECTS; do
  PAUSED=false; fb_on "paused-$p" && PAUSED=true
  # A board's automerge is off under the fleet switch or its own (#2322).
  AM=$FLEET_AM; fb_on "automerge-disabled-$p" && AM=false
  # automerge_fleet is the fleet kill switch ALONE (#2322 follow-up): the
  # console's fleet KILL / RE-ENABLE button keys on it, never on one board's
  # automerge, which its own toggle can turn off.
  $BEAT "$(jq -nc --arg p "$p" --argjson paused "$PAUSED" --argjson am "$AM" --argjson amf "$FLEET_AM" --argjson envp "$ENVP_JSON" '{kind:"flags",project:$p,paused:$paused,automerge:$am,automerge_fleet:$amf,env_pauses:$envp}')"
done
# <<< flags beats
# >>> steer outbox (BH-5839)
# The ticket page's "Add to the ticket" and "Hold, then tell it" notes: one App
# comment, or the hold plus the note, per note in the jobs worker's outbox.
# Hub only: this script runs on every box each minute, and the outbox is a
# read, not a claim, so only the lease holder delivers (one box, one post).
# flock -n 7 above already keeps two ticks on this box apart. Fail-open.
# shellcheck source=bin/lib/steer-deliver.sh
if "$HARNESS/bin/hub-lease.sh" check >/dev/null 2>&1 \
  && [ -r "$HARNESS/bin/lib/steer-deliver.sh" ] && . "$HARNESS/bin/lib/steer-deliver.sh"; then
  steer_deliver_tick || true
fi
# <<< steer outbox
exit 0
