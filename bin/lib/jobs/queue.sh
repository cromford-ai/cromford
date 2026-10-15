#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/queue.sh — BH-1194: the pre-claim build queue, the pre-plans that ride with it, the merge queue and the wake rows — every row that says work is WAITING rather than running. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- The pre-claim build queue (2026-09-10) ----------------------------------
# state/build-queue/<project>/<KEY>.json as ROWS. Until now the wait between
# "this ticket is buildable" and "a box claimed it" lived in a directory on the
# box that decided it, which is why the hub needed ssh into every box for the
# fly pool to see any work at all, and why a queued build was invisible to
# Mission Control until somebody claimed it.
#
# THE FILE STAYS THE FALLBACK for the whole transition. Producers write both and
# readers ask here FIRST: every helper below returns nonzero and prints nothing
# when the worker is unreachable, and every caller then behaves byte-for-byte as
# it does today. A queue that can refuse work when a database blinks is worse
# than no queue in a database at all.

# queue_put <project> <key> [ticket_id] [target] [attempt] [meta]
#   TARGET: an explicit local|fly is sent as given. Omitted, it is the
#   project's routing target (BH-3316): fly on a fly1/pool project, local
#   otherwise (queue_routing_facts + queue_route_target below). It used to be a
#   flat `local`, and nothing claims a local row on a fly-routed project.
#   IDEMPOTENT on project+KEY, which is exactly what a filename gave the file
#   queue: enqueueing a key that is already queued OR already claimed writes
#   nothing and prints `duplicate`.
#   rc 0 -> prints "queued" or "duplicate"
#   rc 1 -> API unusable. Say nothing; the file queue is still the queue.
queue_put() {
  local project="${1:-}" key="${2:-}" ticket="${3:-}" target="${4:-}" attempt="${5:-}" meta="${6:-}"
  [ -n "$project" ] && [ -n "$key" ] || return 1
  local body resp
  [ -n "$target" ] || target=$(queue_route_target "$(queue_routing_facts "$project" 2>/dev/null)")
  [ -n "$target" ] || target=local
  body=$(jq -nc --arg p "$project" --arg k "$key" --arg t "$ticket" --arg g "$target" \
    --arg a "$attempt" --arg m "$meta" --arg b "$JOBS_BOX" \
    '{project:$p,key:$k,target:$g,requested_by:$b}
     + (if $t == "" then {} else {ticket_id:$t} end)
     + (if ($a|test("^[0-9]+$")) then {attempt:($a|tonumber)} else {} end)
     + (if $m == "" then {} else {meta:$m} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/queue "$body") || return 1
  printf '%s' "$(printf '%s' "$resp" | jq -r 'if .duplicate then "duplicate" else "queued" end' 2>/dev/null)"
}

# queue_routing_facts <project> — print `builder|halted` (builder local|fly1|pool,
#   halted 0|1), the routing a queued row is judged against (BH-3316). The D1
#   routing row answers first; any failure to read it (outage, 404, a builder
#   it does not know) falls back to the flags/ files, which is what caps_route
#   and the launchers read. rc 1 only for a bad project name.
queue_routing_facts() {
  local p="${1:-}" row b h f
  _routing_name_ok "$p" || return 1
  if row=$(routing_get "$p" 2>/dev/null); then
    b=$(printf '%s' "$row" | jq -r '.builder // empty' 2>/dev/null)
    h=$(printf '%s' "$row" | jq -r 'if (.halted == true or .halted == 1 or .halted == "1") then 1 else 0 end' 2>/dev/null)
    case "$b" in local|fly1|pool) printf '%s|%s\n' "$b" "${h:-0}"; return 0 ;; esac
  fi
  f=$(routing_row_from_files "$p") || return 1
  printf '%s|%s\n' "${f%%|*}" "${f##*|}"
}

# queue_route_target <facts> — pure: fly for a fly1/pool builder, else local.
#   The worker knows only these two targets (worker/jobs/src/routes/queue.js).
queue_route_target() {
  case "${1%%|*}" in fly1|pool) echo fly ;; *) echo local ;; esac
}

# queue_target_stranded <facts> <target> — pure. rc 0 and a one-line reason
#   when nothing will ever claim a queued row with this target:
#     local on a fly1/pool project (only fly-dispatch and fly-pool claim, and
#     they claim fly), or fly while routing is halted.
#   rc 1 otherwise. A fly row on a `local` answer is NOT stranded: `local` is
#   also what a box with no flags and no routing row says.
queue_target_stranded() {
  local b="${1%%|*}" h="${1##*|}" t="${2:-}"
  case "$t:$b" in
    local:fly1|local:pool) echo "target=local on a $b-routed project: no launcher claims local rows"; return 0 ;;
  esac
  if [ "$t" = fly ] && [ "$h" = 1 ]; then echo "target=fly while routing is halted"; return 0; fi
  return 1
}

# queue_list [project] [status] [target] [deferred] [limit]
#   TSV: project, key, ticket_id, status, target, attempt, claimed_by,
#   enqueued_at, REASON, META. An absent field prints "-", so a reader splitting
#   on tabs never shifts; columns 9 and 10 were appended (never inserted) for
#   the same reason — every existing reader indexes columns 1-8 positionally.
#   META is the row's own JSON blob, which is where a fly requeue keeps its
#   `deferrals` count: stand-downs are counted SEPARATELY from `attempt`, which
#   is deaths, so bin/jobs-watchdog.sh needs both to judge a row.
#   The reason is flattened to one line: it is the closing RESULT head, which
#   legitimately spans lines, and a newline inside a TSV field would split one
#   row into two for every caller.
#   `deferred` non-empty asks the worker for only the rows whose terminal reason
#   says the build STOOD DOWN (BUILD_DEFERRED / REFUSED) — bin/jobs-watchdog.sh
#   needs exactly those, and its own regex re-checks them, so an older worker
#   that ignores the parameter degrades to a wider list rather than a wrong one.
#   `limit` non-empty asks for at most that many rows. Unset, the worker
#   answers its default page (200); it clamps anything over 500
#   (worker/jobs/src/routes/queue.js). A caller that must know it saw EVERY row
#   sends a limit and treats a page of exactly that many rows as truncated.
#   rc 1 -> outage; the caller falls back to listing its own directory.
queue_list() {
  local project="${1:-}" status="${2:-}" target="${3:-}" deferred="${4:-}" limit="${5:-}" q="" resp
  [ -n "$project" ] && q="project=$project"
  [ -n "$status" ] && q="${q:+$q&}status=$status"
  [ -n "$target" ] && q="${q:+$q&}target=$target"
  [ -n "$deferred" ] && q="${q:+$q&}reason_deferred=1"
  [ -n "$limit" ] && q="${q:+$q&}limit=$limit"
  resp=$(_jobs_req GET "/api/queue${q:+?$q}") || return $?
  printf '%s' "$resp" | jq -r '.queue[]? | [ .project, .ticket_key, (.ticket_id // "-"),
    .status, .target, (.attempt // 0), (.claimed_by // "-"), (.enqueued_at // "-"),
    ((.reason // "-") | gsub("[\n\t\r]+"; " ")),
    (if (.meta // null) == null then "-"
     else (if (.meta | type) == "string" then .meta else (.meta | tojson) end
           | gsub("[\n\t\r]+"; " ")) end) ] | @tsv' 2>/dev/null
}

# queue_status <project> <key>
#   The status of ONE queued build, which is what tells "never enqueued" from
#   "already claimed or finished". bin/fly-dispatch.sh's ssh drain needs exactly
#   that distinction per file: a box file whose row is claimed/done is a leftover
#   whose build has already been reaped, and pulling it spawns a second machine.
#   rc 0 -> prints queued | ready | claimed | done | failed | dropped
#           CUSTODY IS A CLOSED LIST (BH-1033). Only claimed/done/failed mean
#           "this hub already took custody of the work". `queued` is the file's
#           own state; `ready` means triage says buildable and nobody launched
#           it; `dropped` means a queue line was consumed. Those three tell the
#           drain the same thing rc 2 does — nothing in the DB owns a launch for
#           this key — so a caller deciding whether a leftover box file is real
#           work must name the custody words it acts on, never "anything that is
#           not queued". bin/fly-dispatch.sh's ssh drain does exactly that.
#   rc 2 -> worker reachable, NO row for this key. A REAL answer: this build was
#           never enqueued to the DB (an older producer, or a fail-open tick), so
#           the caller must treat the file as real work, exactly as it does today.
#   rc 1 -> outage. Same conclusion as rc 2 for every caller, but for a different
#           reason, and the two are kept apart so a log line can say which.
queue_status() {
  local project="${1:-}" key="${2:-}" resp st
  [ -n "$project" ] && [ -n "$key" ] || return 1
  resp=$(_jobs_req GET "/api/queue?project=$project&key=$key&limit=1") || return $?
  st=$(printf '%s' "$resp" | jq -r '.queue[0].status // empty' 2>/dev/null)
  [ -n "$st" ] || return 2
  printf '%s' "$st"
}

# queue_row <project> <key>
#   The WHOLE row for one key, as one TSV line: status, enqueued_at, claimed_by,
#   requested_by, reason. queue_status answers "what state", which is enough for
#   the drain; a caller deciding whether a rebuild it enqueued is still running
#   needs the job's identity and its age too, and two calls for one row is two
#   chances for the row to move between them.
#   Every absent field prints "-" so a malformed row cannot shift the columns,
#   and `reason` is flattened to one line for the same reason.
#   rc 0 -> the row, printed
#   rc 2 -> worker reachable, NO row for this key (never enqueued). A REAL answer.
#   rc 1 -> outage. NOT "finished", and it prints nothing a caller could read
#           as a row.
queue_row() {
  local project="${1:-}" key="${2:-}" resp row
  [ -n "$project" ] && [ -n "$key" ] || return 1
  resp=$(_jobs_req GET "/api/queue?project=$project&key=$key&limit=1") || return $?
  row=$(printf '%s' "$resp" | jq -r '.queue[0] // empty
    | [ (.status // "-"), (.enqueued_at // "-"), (.claimed_by // "-"), (.requested_by // "-"),
        ((.reason // "-") | gsub("[\n\t\r]+"; " ")) ] | @tsv' 2>/dev/null)
  [ -n "$row" ] || return 2
  printf '%s' "$row"
}

# queue_stale <minutes>
#   Rows CLAIMED longer ago than <minutes>, fleet-wide. TSV: project, key,
#   claimed_by, claimed_at, target, attempt.
#   The THRESHOLD is the caller's and the CLOCK is the server's — the same split
#   job_stale uses, so every reader judges staleness by one clock.
queue_stale() {
  local mins="${1:-}" resp
  case "$mins" in ''|*[!0-9]*) return 1 ;; esac
  resp=$(_jobs_req GET "/api/queue?status=claimed&stale_min=$mins&limit=200") || return $?
  printf '%s' "$resp" | jq -r '.queue[]? | [ .project, .ticket_key, (.claimed_by // "-"),
    (.claimed_at // "-"), (.target // "local"), (.attempt // 0) ] | @tsv' 2>/dev/null
}

# queue_claim <project> [target] [key] [machine]
#   Takes ONE queued build and marks it claimed by this box, atomically. With a
#   key it claims that exact row (the local launch path knows which build it is
#   about to run); without one it takes the oldest.
#   `machine` (BH-1026) is the Fly machine the build will run on, recorded on the
#   row so "is this key already building, and where" is answerable without an ssh
#   into the box that holds state/fly/<p>-active.json. Omitted when empty, never
#   sent as "": an empty string is a value that compares, and it would land on
#   the row as one.
#   THE OUTPUT TSV IS UNCHANGED — key, ticket_id, target, attempt — because
#   existing parsers read those four columns positionally.
#   rc 0 -> prints TSV: key, ticket_id, target, attempt
#   rc 2 -> nothing queued. A REAL answer, not an outage — the worker was
#           reachable and the queue is empty, which is the normal shape of a
#           quiet project and never burns the daily unreachable alert.
#   rc 9 -> another claimant took it first. A CLEAN SKIP, never an error.
#   rc 1 -> API unusable. Fall back to the directory.
queue_claim() {
  local project="${1:-}" target="${2:-}" key="${3:-}" machine="${4:-}" body resp rc
  [ -n "$project" ] || return 1
  body=$(jq -nc --arg p "$project" --arg b "$JOBS_BOX" --arg g "$target" --arg k "$key" \
    --arg m "$machine" \
    '{project:$p,box:$b}
     + (if $g == "" then {} else {target:$g} end)
     + (if $k == "" then {} else {key:$k} end)
     + (if $m == "" then {} else {machine:$m} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/queue/claim "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -r '.queued | [ .ticket_key, (.ticket_id // "-"),
    (.target // "local"), (.attempt // 0) ] | @tsv' 2>/dev/null
}

# queue_done <project> <key> [status] [reason]
#   status defaults to `done`; `failed` records a build that ended badly.
queue_done() {
  local project="${1:-}" key="${2:-}" status="${3:-done}" reason="${4:-}" body
  [ -n "$project" ] && [ -n "$key" ] || return 1
  body=$(jq -nc --arg p "$project" --arg k "$key" --arg s "$status" --arg r "$reason" \
    '{project:$p,key:$k,status:$s} + (if $r == "" then {} else {reason:$r} end)' 2>/dev/null) || return 1
  _jobs_req PATCH /api/queue "$body" >/dev/null
}

# queue_release <project> <key> [reason]
#   Puts a claimed build back on the queue and CLEARS the claimant — a failed
#   env push, an un-claim, a machine that died before it started. A row that
#   still names a box reads to the next claim as work in flight.
queue_release() {
  local project="${1:-}" key="${2:-}" reason="${3:-}"
  [ -n "$project" ] && [ -n "$key" ] || return 1
  queue_done "$project" "$key" queued "$reason"
}

# --- BH-1033 (state→DB slice 8): the two log-as-state stores -----------------
# The READY queue and the age-out audit are files on ONE box that fleet-wide
# decisions depend on. These helpers let a lane ask the DATABASE first. They are
# inert until an operator flips the flag row, and both files stay exactly where
# they are as the write-through cache and the fallback.

# _flag_on_row <settings-key> <env-value> <cache-var> — the resolution order
# every behaviour flag in this client uses (the gh-budget pattern): the settings
# row first, then the documented env fallback, then the literal 0.
#
# MEMOISED PER PROCESS: a tick that asks per ticket must not buy a settings read
# per ticket. AN OUTAGE IS NEVER CACHED, so a worker that blinks cannot pin one
# answer for the rest of the process and cannot switch a lane on from a settings
# value nobody could read.
# IT DOES NOT FORCE OFF, THOUGH. On an outage the resolution simply continues to
# the DOCUMENTED env fallback, so `READY_QUEUE_ROWS=1` in env/global.env stays
# on through one — the only way a lane is on while the worker is down, and the
# case tests/ready-queue-rows-test.sh drives as `env down`. The sibling
# machines_rows_on (bin/lib/jobs/machines.sh) returns rc 1 on an outage because
# it has no env knob to fall back to, not because the rule differs.
_flag_on_row() {
  local key="${1:-}" envval="${2:-}" var="${3:-}" val="" rc cacheable=1 setvar
  setvar="${var}_SET"
  if [ "${!setvar-0}" = 1 ]; then [ "${!var-0}" = 1 ]; return $?; fi
  if command -v setting_get >/dev/null 2>&1; then
    val=$(setting_get "$key" 2>/dev/null); rc=$?
    case "$rc" in
      0) ;;
      2) val="" ;;
      *) val=""; cacheable=0 ;;
    esac
  fi
  [ -n "$val" ] || val="$envval"
  case "$val" in 1|on|true|yes) val=1 ;; *) val=0 ;; esac
  [ "$cacheable" = 1 ] && { printf -v "$var" '%s' "$val"; printf -v "$setvar" '%s' 1; }
  [ "$val" = 1 ]
}

# ready_queue_rows_on — rc 0 when the `ready` ROWS are the first reader of the
# ready queue. THE DEFAULT IS OFF, and off is today's behaviour byte for byte.
_RQR=0; _RQR_SET=0
ready_queue_rows_on() { _flag_on_row ready_queue_rows "${READY_QUEUE_ROWS:-0}" _RQR; }

# closeout_aged_table_on — rc 0 when the `closeout_aged` TABLE is the first
# reader of the age-out audit. Same shape, same default.
_CAT=0; _CAT_SET=0
closeout_aged_table_on() { _flag_on_row closeout_aged_table "${CLOSEOUT_AGED_TABLE:-0}" _CAT; }

# --- BH-1026 (queues are rows): three knobs, one per sibling slice -----------
# THREE ROWS, NOT ONE, on purpose: the slices of #1026 land as separate PRs, and
# one shared knob would arm a lane whose PR had not merged yet. Each is one line
# through _flag_on_row — the same resolution order every behaviour flag in this
# client uses (row, then the documented env fallback, then 0) — because a second
# resolution mechanism is a second answer to one question.
#
# ALL THREE DEFAULT OFF, and off is today's behaviour byte for byte: not one
# request beyond the memoised settings read, and every caller keeps its file.

# build_queue_rows_only_on — rc 0 when the build queue's ROWS are the first
# reader of what is queued and what is active (state/build-queue/<p>/<KEY>.json
# and state/fly/<p>-active.json second).
_BQR=0; _BQR_SET=0
build_queue_rows_only_on() { _flag_on_row build_queue_rows_only "${BUILD_QUEUE_ROWS_ONLY:-0}" _BQR; }

# merge_queue_rows_only_on — rc 0 when the merge_queue ROWS are the first reader
# of what is waiting to merge (state/merge-queue/<p>/<pr> second).
_MQR=0; _MQR_SET=0
merge_queue_rows_only_on() { _flag_on_row merge_queue_rows_only "${MERGE_QUEUE_ROWS_ONLY:-0}" _MQR; }

# deploy_queue_rows_on — rc 0 when the deploy_queue ROWS are the first reader of
# what is waiting to depart (state/deploy-queue/<p>/<epoch>-<sha8> second).
_DQR=0; _DQR_SET=0
deploy_queue_rows_on() { _flag_on_row deploy_queue_rows "${DEPLOY_QUEUE_ROWS:-0}" _DQR; }

# build_queue_active_key <project> [key]
#   "IS ANYTHING ALREADY BUILDING, AND WHERE" — the read that lives twice today,
#   as `jq -r '.key // ""' state/fly/<p>-active.json` in bin/run-build.sh and
#   bin/lib/rb/gates.sh. Both are DEDUPE guards, and a missed active job spawns a
#   second machine for a key already in flight (the TK-70 shape), so this helper
#   exists so the two copies cannot drift apart and so the sibling slices do not
#   both have to edit bin/run-build.sh.
#
#   PASS THE KEY. Both call sites ask "is THIS KEY already building", and the
#   answer must be about that key or it is a different question wearing the same
#   variable name. A project-wide row read cannot stand in for it: the file holds
#   the ONE non-pool fly job (bin/fly-dispatch.sh owns it), while `claimed` rows
#   are written for every local build (bin/run-build.sh, bin/lib/rb/gates.sh,
#   with an empty target) and for every pool machine (bin/fly-pool.sh) — so on a
#   project running anything beside the fly job, the oldest claimed row is some
#   other ticket. Worse, `GET /api/queue` ends `ORDER BY enqueued_at ASC LIMIT 1`,
#   and among claimed rows the OLDEST is the likeliest to be stale (a claim whose
#   build died, which bin/jobs-watchdog.sh only sweeps after JOBS_QUEUE_CLAIM_MIN
#   = 6h). Answering with that row would hand the guard a key that is not
#   building, the `[ "$ACTIVE_KEY" = "$KEY" ]` test would miss the key that IS,
#   and the guard would open on exactly the case it exists to close.
#   With a key, the row read is `&key=<key>`: it can only ever ADD this key as
#   active, never hide another one behind it.
#   Without a key it is the project-level question, and the answer is the UNION
#   of the rows and the file — ONE TSV LINE PER ACTIVE KEY, for the same reason
#   (an extra line is a caller looking somewhere it did not have to; a missing
#   one is a second machine).
#
#   rc 0 -> prints TSV: ticket_key<TAB>machine ("-" when no machine is recorded,
#           which is every row claimed by a local build and every row that
#           predates the column)
#   rc 1 -> nothing is active, and NOTHING IS PRINTED.
#
#   ROW FIRST, THEN THE FILE — never row-authoritative. With the flag on, a
#   `claimed` row answers; with no such row, an unreachable worker, or no flag at
#   all, the FILE answers exactly as both call sites read it today. That is the
#   parent ticket's "keep the file as a write-through cache for one full cycle"
#   rule, and it is load bearing right now: nothing writes a `claimed` row for
#   the fly lane until a sibling slice lands, so an empty answer from a reachable
#   worker is not evidence that nothing is building. An outage that printed
#   nothing would open the dedupe guard, which is the one failure this read
#   exists to prevent.
build_queue_active_key() {
  local project="${1:-}" want="${2:-}" resp rkey="" machine="" fkey="" found=1
  [ -n "$project" ] || return 1
  if build_queue_rows_only_on; then
    resp=$(_jobs_req GET "/api/queue?project=$project&status=claimed&limit=1${want:+&key=$want}") && {
      rkey=$(printf '%s' "$resp" | jq -r '.queue[0].ticket_key // ""' 2>/dev/null)
      machine=$(printf '%s' "$resp" | jq -r '.queue[0].machine // ""' 2>/dev/null)
      [ -n "$rkey" ] && { printf '%s\t%s\n' "$rkey" "${machine:--}"; found=0; }
    }
  fi
  # The file is never skipped because a row answered: it is the write-through
  # cache and, for the single fly slot, still the only writer. It is skipped only
  # when it names the key the row already reported (one key, one line).
  fkey=$(jq -r '.key // ""' "$JOBS_HARNESS/state/fly/$project-active.json" 2>/dev/null)
  if [ -n "$fkey" ] && [ "$fkey" != "$rkey" ] && { [ -z "$want" ] || [ "$fkey" = "$want" ]; }; then
    printf '%s\t-\n' "$fkey"; found=0
  fi
  return "$found"
}

# queue_ready_put <project> <key> [ticket_id] [line]
#   Enqueue a ticket as READY — buildable, unclaimed, and visible to every box
#   without an ssh. Idempotent on project+key exactly as queue_put is, and for
#   one more reason: the stale-owed sweep re-offers the same key every run and
#   its 24h cooldown is judged on the row's enqueued_at.
#   THE LINE RIDES IN META. A row that cannot reproduce the READY-QUEUE.log line
#   is not a replacement for it — the line carries the status word, the age and
#   the `project=` token every consumer parses.
#   rc 0 -> prints "queued" or "duplicate". rc 1 -> API unusable; say nothing.
queue_ready_put() {
  local project="${1:-}" key="${2:-}" ticket="${3:-}" line="${4:-}" body resp
  [ -n "$project" ] && [ -n "$key" ] || return 1
  body=$(jq -nc --arg p "$project" --arg k "$key" --arg t "$ticket" --arg l "$line" \
    --arg b "$JOBS_BOX" \
    '{project:$p,key:$k,status:"ready",target:"local",requested_by:$b}
     + (if $t == "" or $t == "-" then {} else {ticket_id:$t} end)
     + (if $l == "" then {} else {meta:({ready_line:$l}|tojson)} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/queue "$body") || return 1
  printf '%s' "$(printf '%s' "$resp" | jq -r 'if .duplicate then "duplicate" else "queued" end' 2>/dev/null)"
}

# queue_ready_list [project]
#   The READY rows, as TSV: project, key, ticket_id, line. An absent field
#   prints "-", so a reader splitting on tabs never shifts. `line` is flattened
#   to one line — a newline inside a TSV field splits one row into two for every
#   caller, and this one's field is free text from a board title.
#   rc 1 -> outage. The caller falls back to the log file, which is still the
#           queue; it must never read as "nothing is ready".
queue_ready_list() {
  local project="${1:-}" q="status=ready" resp
  [ -n "$project" ] && q="$q&project=$project"
  resp=$(_jobs_req GET "/api/queue?$q") || return $?
  printf '%s' "$resp" | jq -r '.queue[]? | [ .project, .ticket_key,
    ((.ticket_id // "") | if . == "" then "-" else . end),
    ((if (.meta // null) == null then ""
      elif (.meta | type) == "string" then ((.meta | fromjson? | .ready_line) // "")
      else (.meta.ready_line // "") end
     | gsub("[\n\t\r]+"; " ")) | if . == "" then "-" else . end ) ] | @tsv' 2>/dev/null
}

# queue_ready_drop <project> <key> [reason]
#   The row half of bin/queue-line-drop.sh: a line a triage session consumed is
#   a row that is no longer ready. `dropped`, not `done` — it did not build.
#   rc 9 is a REFUSAL, not an error: the worker only lets a `ready` row be
#   dropped, so a key that is already `claimed` on some box keeps its live
#   build. rc 2 = no row (nothing to drop), which is the common case today.
queue_ready_drop() {
  local project="${1:-}" key="${2:-}" reason="${3:-line consumed by triage}" body
  [ -n "$project" ] && [ -n "$key" ] || return 1
  body=$(jq -nc --arg p "$project" --arg k "$key" --arg r "$reason" \
    '{project:$p,key:$k,status:"dropped",reason:$r}' 2>/dev/null) || return 1
  _jobs_req PATCH /api/queue "$body" >/dev/null
}

# closeout_aged_put <project> <build-dir> [result-head] [reason]
#   Record the decision that a build record is too old to keep paging about.
#   THREE ANSWERS, because two would hide the one that matters:
#     rc 0 -> recorded now (a new decision)
#     rc 3 -> ALREADY recorded (the dedupe hit). Not an error and not "recorded"
#             — it is what tells the caller its file copy is redundant.
#     rc 1 -> outage / refused. The caller falls back to the tsv, which is the
#             same evidence it has always used.
closeout_aged_put() {
  local project="${1:-}" dir="${2:-}" head="${3:-}" reason="${4:-}" body resp
  [ -n "$dir" ] || return 1
  head=$(printf '%s' "$head" | tr '\t\n\r' '   ')
  reason=$(printf '%s' "$reason" | tr '\t\n\r' '   ')
  body=$(jq -nc --arg p "$project" --arg d "$dir" --arg h "$head" --arg r "$reason" \
    --arg a "$JOBS_BOX" \
    '{build_dir:$d,actor:$a}
     + (if $p == "" then {} else {project:$p} end)
     + (if $h == "" then {} else {result_head:$h} end)
     + (if $r == "" then {} else {reason:$r} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/closeout-aged "$body") || return 1
  case "$(printf '%s' "$resp" | jq -r '.duplicate // false' 2>/dev/null)" in
    true) return 3 ;;
  esac
  return 0
}

# closeout_aged_has <build-dir>
#   rc 0 -> this dir has already been aged out (by any box, ever)
#   rc 2 -> worker reachable, NO row. A REAL answer: never aged out.
#   rc 1 -> outage. NOT "never aged out" — the caller must fall back to the tsv
#           rather than decide from silence.
closeout_aged_has() {
  local dir="${1:-}" resp n
  [ -n "$dir" ] || return 1
  resp=$(_jobs_req GET "/api/closeout-aged?build_dir=$(jq -rn --arg v "$dir" '$v|@uri')") || return $?
  n=$(printf '%s' "$resp" | jq -r '(.aged // []) | length' 2>/dev/null)
  case "${n:-0}" in ''|0) return 2 ;; esac
  return 0
}


# --- Pre-plans (BH-658) ------------------------------------------------------
# The plan bin/run-preplan.sh already paid for, published so the hub can hand it
# to the Fly machine that builds the ticket. _jobs_req switches to a body FILE
# above 64KB, so a 200KB plan rides out as a file instead of failing as E2BIG.

# preplan_put <project> <key> <dir>
#   POST the consumable record in <dir> (plan.md + base-sha [+ planned-files.txt
#   + ticket-fp]) to /api/preplans.
#   rc 0 -> prints "published"
#   rc 3 -> REFUSED: a 4xx (413 over-size, 400 invalid, 404 a worker not yet
#           redeployed). The row is not stored and a retry is refused the same.
#   rc 1 -> unreachable or 5xx. We do NOT know whether the row landed, and the
#           caller says exactly that — the two send an operator to different
#           places (D10). JOBS_HTTP carries the status either way.
#   A MISSING planned-files.txt OR ticket-fp IS OMITTED, never sent as "": an
#   empty-string fingerprint is a value that compares, and the adopt's thread
#   check must fail OPEN on absence (D11).
preplan_put() {
  local p="${1:-}" k="${2:-}" d="${3:-}" body rc pf=/dev/null fpf=/dev/null ta
  [ -n "$p" ] && [ -n "$k" ] || return 1
  [ -s "$d/plan.md" ] && [ -s "$d/base-sha" ] || return 1
  [ -s "$d/planned-files.txt" ] && pf="$d/planned-files.txt"
  [ -s "$d/ticket-fp" ] && fpf="$d/ticket-fp"
  # BH-5799: when the planner started reading the thread (bin/lib/plan-thread.sh).
  ta=$(head -1 "$d/plan-thread-at" 2>/dev/null | tr -d ' \t\r')
  # --rawfile, never --arg "$(cat …)": the plan is the payload and command
  # substitution would eat its trailing newline and blow up on a 40KB argv.
  body=$(jq -n --arg p "$p" --arg k "$k" --arg b "$JOBS_BOX" \
    --arg sha "$(tr -d ' \t\n' < "$d/base-sha")" --arg ta "$ta" \
    --rawfile plan "$d/plan.md" --rawfile files "$pf" --rawfile fp "$fpf" \
    '{project:$p,ticket_key:$k,base_sha:$sha,plan_md:$plan,box:$b}
     + (if $files == "" then {} else {planned_files:$files} end)
     + (if $fp == "" then {} else {ticket_fp:$fp} end)
     + (if $ta == "" then {} else {thread_at:$ta} end)' 2>/dev/null) || return 1
  _jobs_req POST /api/preplans "$body" >/dev/null; rc=$?
  [ "$rc" -eq 0 ] && { printf 'published\n'; return 0; }
  case "${JOBS_HTTP:-}" in
    4*) return 3 ;;
    *)  return 1 ;;
  esac
}

# preplan_get <project> <key>
#   rc 0 -> prints the row JSON (plan_md included)
#   rc 2 -> no pre-plan for that ticket. A REAL answer, like queue_status.
#   rc 1 -> API unusable, or an answer this client cannot parse.
preplan_get() {
  local p="${1:-}" k="${2:-}" resp rc row
  [ -n "$p" ] && [ -n "$k" ] || return 1
  resp=$(_jobs_req GET "/api/preplans?project=$p&key=$k"); rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 2 ] && return 2; return 1; }
  row=$(printf '%s' "$resp" | jq -c '.preplan // empty' 2>/dev/null)
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

# preplan_index <project>
#   TSV, one row per ticket, no plan bodies:
#     ticket_key, base_sha, updated_at, planned_files
#   planned_files has its NEWLINES FLATTENED TO `|` so a TSV reader never shifts
#   a column (the same discipline queue_list follows with `reason`).
preplan_index() {
  local p="${1:-}" resp
  [ -n "$p" ] || return 1
  resp=$(_jobs_req GET "/api/preplans?project=$p") || return $?
  printf '%s' "$resp" | jq -r '.preplans[]? | [ .ticket_key, (.base_sha // "-"),
    (.updated_at // "-"), ((.planned_files // "") | gsub("\n"; "|")) ] | @tsv' 2>/dev/null
}


# --- The merge queue (2026-09-10) --------------------------------------------
# state/merge-queue/<project>/<pr> as rows. The hop this removes is the one a
# fly result takes: bin/fly-pool.sh and bin/fly-results-ingest.sh `ssh` into the
# OWNING box to `touch` a filename, because the queue a tier-1 APPROVE must join
# lives on that box.
#
# THESE ARE NOT A DONE-LIST. "Has this PR already been merged" is answered by
# job_ledger_get merge <pr-url> and by nothing else — a second copy of that fact
# would drift, and the copy that drifts is the one that merges something twice.
# Files stay the fallback, same contract as every helper above.

# merge_queue_put <project> <pr> [repo] [reason]
#   Idempotent while the entry is `queued`. A `blocked` entry IS re-queueable,
#   because that is what bin/tier2-merge-sweep.sh does with the file today.
#   rc 0 -> prints "queued" or "duplicate"; rc 1 -> outage, the file is the queue.
merge_queue_put() {
  local project="${1:-}" pr="${2:-}" repo="${3:-}" reason="${4:-}" body resp
  [ -n "$project" ] || return 1
  case "$pr" in ''|*[!0-9]*) return 1 ;; esac
  body=$(jq -nc --arg p "$project" --argjson n "$pr" --arg r "$repo" --arg w "$reason" \
    --arg b "$JOBS_BOX" \
    '{project:$p,pr:$n,enqueued_by:$b}
     + (if $r == "" then {} else {repo:$r} end)
     + (if $w == "" then {} else {reason:$w} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/merge-queue "$body") || return 1
  printf '%s' "$(printf '%s' "$resp" | jq -r 'if .duplicate then "duplicate" else "queued" end' 2>/dev/null)"
}

# merge_queue_list [project] [status]
#   TSV: project, pr, status, repo, enqueued_by, enqueued_at, reason.
#   FIFO by enqueued_at — the order `ls -tr` gave the directory. `reason` is
#   LAST because it is the only field that can be long.
merge_queue_list() {
  local project="${1:-}" status="${2:-}" q="" resp
  [ -n "$project" ] && q="project=$project"
  [ -n "$status" ] && q="${q:+$q&}status=$status"
  resp=$(_jobs_req GET "/api/merge-queue${q:+?$q}") || return $?
  printf '%s' "$resp" | jq -r '.merge_queue[]? | [ .project, .pr, .status, (.repo // "-"),
    (.enqueued_by // "-"), (.enqueued_at // "-"), (.reason // "-") ] | @tsv' 2>/dev/null
}

# merge_queue_set <project> <pr> <status> [reason]
#   status: queued | blocked | landed | dropped. `dropped` is for a PR removed
#   because it is no longer OPEN — it has not landed and nothing is blocking it,
#   and recording that as `landed` would put a lie in a ledger merges read.
merge_queue_set() {
  local project="${1:-}" pr="${2:-}" status="${3:-}" reason="${4:-}" body
  [ -n "$project" ] && [ -n "$status" ] || return 1
  case "$pr" in ''|*[!0-9]*) return 1 ;; esac
  body=$(jq -nc --arg p "$project" --argjson n "$pr" --arg s "$status" --arg r "$reason" \
    '{project:$p,pr:$n,status:$s} + (if $r == "" then {} else {reason:$r} end)' 2>/dev/null) || return 1
  _jobs_req PATCH /api/merge-queue "$body" >/dev/null
}

# ── MERGE TRAINS (BH-1269) ──────────────────────────────────────────────────
# One row per union branch bin/batch-resolve.sh builds. See the `merge_trains`
# comment in worker/jobs/schema.sql for what a per-box JSON file could not
# carry: Mission Control could not show a train at all, and a box rebuilt while
# one was in flight lost its members, its union sha and its run.
#
# STILL NOT A DONE-LIST. Whether a MEMBER's work landed is the `ledgers` row
# (kind=pr_merged, merged_via=batch:<sha>) and nothing else.

# merge_train_put <project> <branch> <outcome> [k=v ...]
#   outcome: creating | open | landed | abandoned.
#   Optional keys: repo, train_pr, members, member_count, union_sha, run_id,
#   merge_sha, train_group, detail. An unknown key is DROPPED rather than sent, because the
#   route would 400 the whole write for it and this call must never be the
#   reason a train is not recorded.
#   The row is an UPSERT and every optional field is COALESCEd server-side, so
#   the three writes of one train (creating / open / landed) accumulate.
#   rc 0 -> prints the outcome the row now carries; rc 1 -> outage, and the
#   file record under state/batch-resolve/ is still the lane's own truth.
merge_train_put() {
  local project="${1:-}" branch="${2:-}" outcome="${3:-}" body resp kv k v
  [ -n "$project" ] && [ -n "$branch" ] && [ -n "$outcome" ] || return 1
  shift 3 || true
  body=$(jq -nc --arg p "$project" --arg b "$branch" --arg o "$outcome" \
    '{project:$p,branch:$b,outcome:$o}' 2>/dev/null) || return 1
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$v" ] || continue
    case "$k" in
      train_pr|member_count)
        body=$(printf '%s' "$body" | jq -c --arg k "$k" --arg v "$v" \
          'if ($v|test("^[0-9]+$")) then .[$k] = ($v|tonumber) else . end' 2>/dev/null) ;;
      repo|members|union_sha|run_id|merge_sha|train_group|detail)
        body=$(printf '%s' "$body" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v' 2>/dev/null) ;;
      *) continue ;;
    esac
    [ -n "$body" ] || return 1
  done
  resp=$(_jobs_req PUT /api/merge-trains "$body") || return 1
  printf '%s' "$(printf '%s' "$resp" | jq -r '.train.outcome // empty' 2>/dev/null)"
}

# merge_train_list [project] [outcome] [limit]
#   TSV: project, branch, outcome, train_pr, member_count, members, union_sha,
#   run_id, merge_sha, train_group, created_at, detail. Newest first — a reader of this table
#   is asking what is in flight now, which is the opposite of the merge queue's
#   FIFO. `detail` is LAST because it is the only field that can be long.
merge_train_list() {
  local project="${1:-}" outcome="${2:-}" limit="${3:-}" q="" resp
  [ -n "$project" ] && q="project=$project"
  [ -n "$outcome" ] && q="${q:+$q&}outcome=$outcome"
  [ -n "$limit" ] && q="${q:+$q&}limit=$limit"
  resp=$(_jobs_req GET "/api/merge-trains${q:+?$q}") || return $?
  printf '%s' "$resp" | jq -r '.merge_trains[]? | [ .project, .branch, .outcome,
    (.train_pr // "-"), (.member_count // "-"), (.members // "-"), (.union_sha // "-"),
    (.run_id // "-"), (.merge_sha // "-"), (.train_group // "-"),
    (.created_at // "-"), (.detail // "-") ] | @tsv' 2>/dev/null
}

# ── THE DEPLOY QUEUE (BH-1026.1) ─────────────────────────────────────────────
# state/deploy-queue/<project>/<epoch>-<sha8> as ROWS. The file holds
# "<merge-sha> <build-dir>" and is one file per REQUEST; the table is keyed on
# (project, sha), because departing twice on one commit is a double-move.
#
# THE FILE STAYS THE FALLBACK. bin/deploy-request.sh writes it in every mode and
# bin/deploy-train.sh reads it whenever these helpers do not answer. Every one
# of them returns nonzero and prints NOTHING on an outage — the train reads an
# empty batch as "nothing to depart", so a helper that printed on a failure
# would be a merge that silently never deploys.

# deploy_queue_put <project> <sha> [build_dir]
#   IDEMPOTENT on (project, sha). A row that is `queued` or `claimed` answers
#   `duplicate` and is not touched; a TERMINAL row is RE-OPENED, which is what
#   the train's self-sourced retry needs (a sha that departed `done` while
#   production still does not serve it).
#   rc 0 -> prints "queued" or "duplicate"
#   rc 1 -> API unusable. Say nothing; the file is still the queue.
deploy_queue_put() {
  local project="${1:-}" sha="${2:-}" build="${3:-}" body resp
  [ -n "$project" ] && [ -n "$sha" ] || return 1
  body=$(jq -nc --arg p "$project" --arg s "$sha" --arg b "$build" \
    '{project:$p,sha:$s} + (if $b == "" or $b == "-" then {} else {build_dir:$b} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/deploy-queue "$body") || return 1
  printf '%s' "$(printf '%s' "$resp" | jq -r 'if .duplicate then "duplicate" else "queued" end' 2>/dev/null)"
}

# deploy_queue_list [project] [status] [stale_min]
#   TSV: project, sha, status, build_dir, claimed_by, enqueued_at, departed_at,
#   REASON. FIFO by enqueued_at — the order `ls -tr` gave the directory — with a
#   sha tiebreak, because a batch of merges lands inside one second routinely.
#   `reason` is LAST because it is the only field that can be long, and it is
#   flattened to one line so a newline inside it cannot split one row into two.
#   `stale_min` asks for the rows a train may RE-OFFER: claimed longer ago than
#   N minutes and never departed. Ignored unless it is a positive integer.
#   rc 1 -> outage; the caller falls back to listing its own directory.
deploy_queue_list() {
  local project="${1:-}" status="${2:-}" stale="${3:-}" q="" resp
  [ -n "$project" ] && q="project=$project"
  [ -n "$status" ] && q="${q:+$q&}status=$status"
  case "$stale" in ''|*[!0-9]*) ;; *) [ "$stale" -gt 0 ] && q="${q:+$q&}stale_min=$stale" ;; esac
  resp=$(_jobs_req GET "/api/deploy-queue${q:+?$q}") || return $?
  printf '%s' "$resp" | jq -r '.deploy_queue[]? | [ .project, .sha, .status,
    (.build_dir // "-"), (.claimed_by // "-"), (.enqueued_at // "-"),
    (.departed_at // "-"),
    ((.reason // "-") | gsub("[\n\t\r]+"; " ")) ] | @tsv' 2>/dev/null
}

# deploy_queue_claim <project> <sha> [stale_min]
#   Takes ONE departure, atomically. This is the cross-box guard the per-box
#   `locks/deploy-train-<p>.lock` never was: two trains ticking in the same
#   minute cannot both fire a deploy hook for one sha.
#   rc 0 -> prints TSV: sha, claimed_by
#   rc 9 -> another claimant has it. A CLEAN SKIP, never an error, and nothing
#           is printed — the 409 payload must not reach a caller that reads
#           stdout as the batch.
#   rc 2 -> no such row. A REAL answer, not an outage.
#   rc 1 -> API unusable.
deploy_queue_claim() {
  local project="${1:-}" sha="${2:-}" stale="${3:-}" body resp rc
  [ -n "$project" ] && [ -n "$sha" ] || return 1
  body=$(jq -nc --arg p "$project" --arg s "$sha" --arg b "$JOBS_BOX" --arg m "$stale" \
    '{project:$p,sha:$s,box:$b}
     + (if ($m|test("^[1-9][0-9]*$")) then {stale_min:($m|tonumber)} else {} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/deploy-queue/claim "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -r '.deploy | [ .sha, (.claimed_by // "-") ] | @tsv' 2>/dev/null
}

# deploy_queue_depart <project> <sha> <done|failed|queued> [reason]
#   Closes a claimed departure. `done` and `failed` stamp `departed_at`;
#   `queued` is the RELEASE a failed verify uses, and it clears the claimant so
#   the next train does not read the row as in flight. Refused (rc 9) on a row
#   that is not `claimed` — `departed_at` is never stamped by anything else.
#   rc 0 -> prints the status the row now carries. Same rc map as the claim.
deploy_queue_depart() {
  local project="${1:-}" sha="${2:-}" status="${3:-}" reason="${4:-}" body resp rc
  [ -n "$project" ] && [ -n "$sha" ] && [ -n "$status" ] || return 1
  body=$(jq -nc --arg p "$project" --arg s "$sha" --arg t "$status" --arg r "$reason" \
    '{project:$p,sha:$s,status:$t} + (if $r == "" then {} else {reason:$r} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/deploy-queue/depart "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -r '.deploy.status // empty' 2>/dev/null
}

# ── WAKES: the doorbell the fleet's clocks never had (2026-09-12) ────────────
# docs/EVENTS.md. A GitHub delivery lands in the `wakes` table as an IDENTIFIER
# and nothing else; bin/wake-loop.sh reads it and runs the lane that owns it
# immediately instead of waiting for that lane's cron. Fail-open like every
# other helper here: no worker, no rows, no wakes, and every lane keeps ticking
# on its clock exactly as it does today.

# wakes_list [since] [repo]
#   TSV: id, repo, kind, key, event, at
#   With SINCE (a row id) the worker answers everything newer than that
#   watermark, acked or not — which is what the loop uses, because the
#   watermark is LOCAL and therefore survives an ack that never landed. Without
#   it the worker answers the unacked backlog, which is the operator's view.
#   rc 1 -> outage. The caller does nothing, and cron covers the gap.
wakes_list() {
  local since="${1:-}" repo="${2:-}" q="" resp
  case "$since" in ''|*[!0-9]*) ;; *) q="since=$since" ;; esac
  [ -n "$repo" ] && q="${q:+$q&}repo=$repo"
  resp=$(_jobs_req GET "/api/wakes${q:+?$q}") || return $?
  printf '%s' "$resp" | jq -r '.wakes[]? | [ .id, .repo, .kind, .key,
    (.event // "-"), (.at // "-") ] | @tsv' 2>/dev/null
}

# wakes_ack <id>...
#   Housekeeping, never the guard: it keeps the unacked backlog readable for an
#   operator. A failed ack must never be able to make a lane run twice, which is
#   why the loop's real protection is its own watermark file.
wakes_ack() {
  local body
  [ "$#" -gt 0 ] || return 1
  body=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(test("^[0-9]+$")) | tonumber)
    | {ids: .}' 2>/dev/null) || return 1
  [ "$(printf '%s' "$body" | jq -r '.ids | length' 2>/dev/null)" -gt 0 ] 2>/dev/null || return 1
  _jobs_req POST /api/wakes/ack "$body" >/dev/null
}

# ── WAKE CLAIMS, CURSORS, COOLDOWNS (BH-2525) ────────────────────────────────
# The client side of the wake_claims / wake_cursors / wake_cooldowns tables.
# Contract only: nothing calls these yet. All four share one rc map, and rc 2
# is ANY unusable answer — no worker, a non-2xx (409 and 404 included), a body
# that does not parse, or bad arguments (refused before any request). A caller
# can never read a failed request as a claim, a cursor or a taken cooldown.

# wakes_claim <box> <limit> <repos-csv> <all-kinds-csv>
#   POST /api/wakes/claim {box, repos (lowercased), kinds_all_repos, limit}.
#   TSV: id, repo, kind, key, event, at (a missing event/at prints `-`), then a
#   final line `#top <scanned_top>`. rc 0 with those lines, rc 2 with NOTHING
#   printed — never partial rows without the `#top` line.
wakes_claim() {
  local box="${1:-}" limit="${2:-}" repos="${3:-}" kinds="${4:-}" body resp out
  [ -n "$box" ] || return 2
  case "$limit" in ''|*[!0-9]*) return 2 ;; esac
  body=$(jq -nc --arg b "$box" --arg l "$limit" --arg r "$repos" --arg k "$kinds" \
    '{box:$b,
      repos: ($r | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(. != "") | ascii_downcase)),
      kinds_all_repos: ($k | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(. != ""))),
      limit: ($l | tonumber)}' 2>/dev/null) || return 2
  resp=$(_jobs_req POST /api/wakes/claim "$body") || return 2
  out=$(printf '%s' "$resp" | jq -er 'if type == "object" and (.wakes | type) == "array"
      and (.scanned_top | type) == "number" then
      ((.wakes[] | [ .id, .repo, .kind, .key, (.event // "-"), (.at // "-") ] | @tsv),
       "#top \(.scanned_top)")
    else error("unusable") end' 2>/dev/null) || return 2
  printf '%s\n' "$out"
}

# wake_cursor_get <box>
#   GET /api/wakes/cursor?box=<box>. Prints the box's cursor, or NOTHING (rc 0)
#   when the worker says null. rc 2 on an unusable answer. Never invents a 0.
wake_cursor_get() {
  local box="${1:-}" q resp out
  [ -n "$box" ] || return 2
  q=$(jq -rn --arg b "$box" '$b | @uri') || return 2
  resp=$(_jobs_req GET "/api/wakes/cursor?box=$q") || return 2
  out=$(printf '%s' "$resp" | jq -er 'if type == "object" and has("cursor") then
      (if .cursor == null then ""
       elif (.cursor | type) == "number" and .cursor >= 0 and .cursor == (.cursor | floor)
       then (.cursor | tostring) else error("unusable") end)
    else error("unusable") end' 2>/dev/null) || return 2
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# wake_cursor_put <box> <n>
#   PUT /api/wakes/cursor {box, cursor}. rc 0 on 2xx, rc 2 otherwise.
wake_cursor_put() {
  local box="${1:-}" n="${2:-}" body
  [ -n "$box" ] || return 2
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  body=$(jq -nc --arg b "$box" --arg n "$n" '{box:$b, cursor:($n | tonumber)}') || return 2
  _jobs_req PUT /api/wakes/cursor "$body" >/dev/null || return 2
}

# wake_cooldown_take <kind> <project> <window_s> <box>
#   POST /api/wakes/cooldown/take {kind, project, window_s, box}. rc 0 only on
#   {"taken":true}, rc 1 on {"taken":false}, rc 2 on anything else.
wake_cooldown_take() {
  local kind="${1:-}" project="${2:-}" window="${3:-}" box="${4:-}" body resp taken
  [ -n "$kind" ] && [ -n "$project" ] && [ -n "$box" ] || return 2
  case "$window" in ''|*[!0-9]*) return 2 ;; esac
  body=$(jq -nc --arg k "$kind" --arg p "$project" --arg w "$window" --arg b "$box" \
    '{kind:$k, project:$p, window_s:($w | tonumber), box:$b}') || return 2
  resp=$(_jobs_req POST /api/wakes/cooldown/take "$body") || return 2
  taken=$(printf '%s' "$resp" | jq -r 'if type == "object" and (.taken | type) == "boolean"
    then (if .taken then "1" else "0" end) else empty end' 2>/dev/null)
  case "$taken" in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac
}

# wakes_summary [hours]
#   WHO HAS RUNG in the last <hours> (the worker clamps to 1..168; default 24).
#   TSV: repo, n, last_at, kinds, last_id. Since BH-6799 the worker answers
#   from wake_repo_last: no per-window count (n prints `-`), and last_id is the
#   repo's newest wake id. A field the worker did not send prints `-`.
#
#   rc 1 with EMPTY stdout on ANY failure, and the 404 of a worker that predates
#   the route is one of them — deliberately, not by accident. The caller is
#   bin/doorbell-coverage-check.sh, which suppresses a client-visible alert when
#   a repo is named here, so "the worker did not answer" must read as "cannot
#   tell" and never as "not ringing": a worker that is down is not evidence of
#   silence, and neither is a route that is not deployed yet.
#
#   JOBS_ALERT=0 for the same reason: the caller treats an unanswered read as
#   "cannot tell" and carries on, so this read is not the fleet's outage
#   detector and must not write into ALERTS.log. The jobs-client.log line stays.
wakes_summary() {
  local hours="${1:-}" q="" resp JOBS_ALERT=0
  case "$hours" in ''|*[!0-9]*) ;; *) q="?hours=$hours" ;; esac
  resp=$(_jobs_req GET "/api/wakes/summary$q") || return 1
  printf '%s' "$resp" | jq -r '.repos[]? | [ .repo, (.n // "-"), (.last_at // "-"),
    (.kinds // "-"), (.last_id // "-") ] | @tsv' 2>/dev/null
}

# wakes_prune <days>
#   RETENTION (BH-1267). Nothing deleted a wake until this verb existed, and the
#   daily doorbell lane is what calls it. TSV: deleted, before, capped.
#
#   DIGITS ONLY, AND AT LEAST 1, CHECKED HERE. This is the one call in this file
#   that destroys rows, so a caller whose knob did not parse — an empty
#   WAKES_RETENTION_DAYS, a typo, a `0` that means OFF — must not be able to
#   reach the route at all: rc 1, no request, nothing deleted. The worker
#   refuses the same values again on its own side; both checks are deliberate,
#   because neither end may assume the other ran.
#
#   rc 1 with EMPTY stdout on ANY failure, the 404 of a worker that predates the
#   route included: the caller logs "the worker did not answer" and the next
#   daily run tries again. JOBS_ALERT=0 for the same reason wakes_summary sets
#   it — the caller treats no answer as "cannot tell" and carries on, so this
#   read must not spend the box's daily ALERT. The jobs-client.log line stays.
wakes_prune() {
  local days="${1:-}" resp JOBS_ALERT=0
  case "$days" in ''|*[!0-9]*) return 1 ;; esac
  [ "$days" -ge 1 ] 2>/dev/null || return 1
  resp=$(_jobs_req POST /api/wakes/prune "{\"days\":$days}") || return 1
  printf '%s' "$resp" | jq -r '[ (.deleted // 0), (.before // "-"),
    (.capped // false) ] | @tsv' 2>/dev/null
}

# wake_put <repo> <kind> <key>
#   RING THE DOORBELL FROM A LANE, not only from GitHub (W2-B, 2026-09-14). The
#   wake table is what stops the merge conductor waiting out its */5 tick
#   (docs/EVENTS.md); a builder that has just opened a PR knows there is
#   something to look at before any webhook round-trip has been observed, and
#   the whole point of the direct path is that nothing waits on a tick.
#
#   THE WORKER ROUTE DOES NOT EXIST YET. `POST /api/wakes` is specified for the
#   worker change in docs/HARNESS-COORDINATION.md ("Endpoints this client calls
#   that the worker still owes"). Until it lands this is a fail-open no-op: the
#   worker 404s, _jobs_req prints nothing and returns nonzero, the caller
#   ignores it, and the conductor is still rung by GitHub's own pull_request
#   webhook exactly as it is today. Nothing anywhere waits for this call.
#
#   Identifiers only, like the receiver (docs/EVENTS.md section 3): a repo slug,
#   a kind and one key. No titles, no branches, no claims about state.
wake_put() {
  local repo="${1:-}" kind="${2:-}" key="${3:-}" body
  [ -n "$repo" ] && [ -n "$kind" ] && [ -n "$key" ] || return 1
  body=$(jq -nc --arg r "$repo" --arg k "$kind" --arg y "$key" --arg a "$JOBS_BOX" \
    '{repo:$r,kind:$k,key:$y,actor:$a}' 2>/dev/null) || return 1
  _jobs_req POST /api/wakes "$body" >/dev/null
}

# wake_lane_put <owner/repo> <kind> <pr> <dedupe>
#   The lead-chain doorbell (BH-4057): one row on POST /api/wakes/lane, which
#   only takes kind lead-review|lead-land. Transport only: rc 0 on a 2xx,
#   nonzero otherwise, prints nothing. Callers go through lcw_ring.
wake_lane_put() {
  local repo="${1:-}" kind="${2:-}" pr="${3:-}" dedupe="${4:-}" body
  [ -n "$repo" ] && [ -n "$kind" ] && [ -n "$pr" ] && [ -n "$dedupe" ] || return 1
  case "$pr" in *[!0-9]*) return 1 ;; esac
  body=$(jq -nc --arg r "$repo" --arg k "$kind" --argjson y "$pr" --arg d "$dedupe" \
    '{repo:$r,kind:$k,key:$y,dedupe:$d}' 2>/dev/null) || return 1
  _jobs_req POST /api/wakes/lane "$body" >/dev/null
}


# --- TRIAGE-STATE (the operator, 2026-09-28): the per-ticket triage state -------------
# worker/jobs/src/routes/triage-state.js. One row per ticket: the model's last
# verdict and the input hash it was made against, read by bin/lib/triage-state.sh
# before a tick spends a token. Transport only, fail-open like the rest of this
# file: rc 0 + the answer on a 2xx, rc 2 (nothing printed) on a 404, rc 1 on
# anything else.

# triage_state_get <project> <ticket_key> -> the row as ONE compact JSON object
triage_state_get() {
  local project="${1:-}" key="${2:-}" resp row
  [ -n "$project" ] && [ -n "$key" ] || return 1
  resp=$(_jobs_req GET "/api/triage-state/$project/$key") || return $?
  row=$(printf '%s' "$resp" | jq -c '.triage_state // empty' 2>/dev/null)
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# triage_state_list <project> [due] [limit] -> the project's rows as ONE compact
#   JSON array. `due` (any non-empty value) keeps only rows whose recheck is due.
triage_state_list() {
  local project="${1:-}" due="${2:-}" limit="${3:-}" q resp rows
  [ -n "$project" ] || return 1
  q="project=$project"
  [ -n "$due" ] && q="$q&due=1"
  [ -n "$limit" ] && q="$q&limit=$limit"
  resp=$(_jobs_req GET "/api/triage-state?$q") || return $?
  rows=$(printf '%s' "$resp" | jq -c '.triage_state // empty' 2>/dev/null)
  [ -n "$rows" ] || return 1
  printf '%s' "$rows"
}

# triage_state_put <json-file> -> PUT /api/triage-state with the file as the
#   body: one row {project, ticket_key, ...} or {project, rows:[...]} (<= 200).
#   Only the columns a row carries are written. A 400/413 is rc 1.
triage_state_put() {
  local f="${1:-}" body
  [ -s "$f" ] || return 1
  body=$(jq -c . "$f" 2>/dev/null) || return 1
  [ -n "$body" ] || return 1
  _jobs_req PUT /api/triage-state "$body"
}
