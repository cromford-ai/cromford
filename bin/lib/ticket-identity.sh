#!/bin/bash
# bin/lib/ticket-identity.sh — ONE IDENTITY PER TICKET (BH-866). Sourced, never
# executed. Read-only: it writes nothing anywhere.
#
# WHY THIS EXISTS. Everywhere this fleet dedupes a build, the identity is the
# KEY. bin/run-build.sh claims its jobs row with `job_open "$PROJECT" "$KEY"
# build …` and the worker's double-build guard dedupes on
# (project, ticket_id=KEY, kind); the BOARD ticket id rides only in `meta`. On an
# in-app board that is one identity too few. A decomposed child can carry the
# title label `TK-1766.5` while the board's own key for the same ticket is
# `TK-1789` — so the same board ticket gets two keys, two claims, two plans, two
# executes and two PRs, and nothing anywhere notices. TK-1766.5 / TK-1789 is the
# case that paid for this file.
#
# ticket_identity_conflict <harness> <project> <ticket-id> <key>
#   rc 0  a conflict. ONE tab-separated line on stdout:
#         <other-key>\t<source>\t<state>
#           source: keymap | issues-key | build-record | ledger | queue
#           state:  board-key | pr_created | merged | running | claimed | queued
#   rc 1  nothing conflicts — launch.
#   rc 2  a source could NOT be consulted and nothing positive was found.
#         The caller PROCEEDS and says so. Refusal needs evidence: a worker
#         outage that refused every launch would stop the fleet, which is a
#         worse failure than the duplicate this guards against, and it is the
#         same fail-open every other guard in this repo takes.
#
# Sources are asked cheapest first and the FIRST HIT WINS — a keymap read is a
# local file, the issues-board key is a registry read plus a prompt grep (and
# one cached settings read for the tracker kind), a build-record scan is local
# stat calls, and only the last two cost a round trip each.
#
# THE ISSUES BOARD HAS NO KEYMAP (BH-1139). Source (a) is written by
# bin/triage-gate.sh from a BOARD API, and a GitHub-Issues project has none — so
# on that lane the first three of the remaining sources can only see a duplicate
# once a second build already exists, and the FIRST launch under a decomposed
# child's dotted title label was never refused. `TK-2411.2` (the title
# bin/run-decompose.sh gives the child) and `TK-2487` (the issue it filed it as)
# are one ticket with two identities. That board's key is DERIVABLE, which is
# what source (a2) does.
#
# THE QUEUED WINDOW (BH-1140). The first three sources leave a hole, and it is
# open on exactly the boards this guard was built for. On a Fly-routed project
# bin/run-build.sh enqueues at the QUEUED_FLY path, and `job_open` — the running
# row the `ledger` source reads — only happens on the pool machine, much later.
# In between there is no running row; there is no pool TWIN either, so
# `build-record` deliberately answers "nothing here" for a stub without one; and
# on a board whose list endpoint omits `key` (project-4: it returns `number`) the
# keymap was EMPTY until BH-1169 derived `<keyPrefix>-<number>` for those
# rows. Zero of three sources could see a ticket that was already
# queued, so a hand launch or a label launch in that window built it a second
# time. `queue_put "$PROJECT" "$KEY" "$TICKET"` already writes the board id onto
# the row, so the window closes with a fourth source, not a redesign. The window
# runs to `job_open`, not to the claim: `queue_claim` happens on the HUB at pool
# spawn, `job_open` on the MACHINE long after, so `claimed` is asked for too.
#
# THAT QUEUE IS SHARED. build_queue also carries the merge conductor's pool
# REBASE rows, whose `ticket_id` is a PR NUMBER and whose key is
# `RB-<num>-<head8>` (bin/lib/mc/rebase.sh). Board ids are integer strings in
# the same range, so source (d) filters on the row's meta `kind` exactly as
# `job_builds_running` does — an unfiltered read refuses board ticket 1592
# because PR #1592 is waiting for a rebase, which is the one thing this guard
# promises never to do.
#
# AND THE QUEUE IS READ FROM BOTH ENDS. Unlike the other three sources, (d) is
# asked by the launch that OWNS a row as well as by the one that duplicates it:
# the guard block runs on the hub before the Fly enqueue AND again on the pool
# machine, where the hub's claim is already on this launch's own row. A reader
# that refuses on any sibling row refuses the claimant too, and a machine-side
# deferral is requeued rather than closed — so a ticket with two rows livelocks
# and never builds, which is strictly worse than the duplicate. Source (d)
# therefore RANKS the rows and refuses only a launch that is behind one, with a
# total order (`_ti_older`) settling a pair in the same state so exactly one of
# them stands down.

# One normalization, at every compare (D17): keys are case-insensitive across
# this fleet (`AB-12` and `ab-12` are one key) and carry no surrounding space.
_ti_norm() { printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }

# _ti_is_build_row <meta>
#   rc 0 when a build_queue row is a BUILD row, rc 1 when it is some other kind
#   of work on that shared table. A build row carries NO `kind` at all
#   (bin/run-build.sh's QMETA is stack_base/hotfix, bin/blocked-resolver.sh's is
#   deferrals plus a note), so "no meta" and "no kind" are both builds and only a
#   `kind` that is something else is skipped.
#
#   ASKED OF THE JSON, not of the bytes. A glob for '"kind":"build"' is
#   whitespace-sensitive: `{"kind": "build"}` — one space, which every
#   non-compact writer emits — matched the '"kind"' arm instead and the row was
#   skipped as a non-build, so a REAL duplicate went unrefused. No producer
#   writes it that way today (bin/lib/mc/rebase.sh is the only `kind` writer and
#   it is `jq -nc`), which is exactly why the bug would have sat here unseen. The
#   row carries JSON, jq is already required by this file, and this runs only for
#   a row that survived the ticket-id and status checks and only when the text
#   mentions `kind` at all — so the assumption goes away for about one process
#   per rebase row.
#
#   A meta that mentions `kind` but does not parse as an object with a string
#   `kind` is NOT read as a build: an unreadable row must never be the evidence
#   that refuses a launch.
_ti_is_build_row() {
  local m="${1:-}" k
  case "$m" in ''|'-') return 0 ;; esac
  case "$m" in *'"kind"'*) : ;; *) return 0 ;; esac
  k=$(printf '%s' "$m" | jq -r 'if type == "object" and (.kind | type) == "string" then .kind else "" end' 2>/dev/null) || k=""
  [ "$k" = build ]
}

# _ti_older <a-at> <a-key> <b-at> <b-key>
#   rc 0 when queue row A is strictly OLDER than queue row B, under a total order
#   that BOTH sides of a pair compute identically — which is the whole point. Two
#   rows for one ticket in the same state each see the other; if each simply
#   refuses the other, neither ever builds (see the tie-break note in source d).
#   Exactly one of _ti_older(A,B) and _ti_older(B,A) is true, so exactly one of
#   the two launches stands down.
#
#   enqueued_at is queue_list column 8 and is an ISO-8601 UTC string, which sorts
#   lexicographically in the same order it sorts chronologically. `-` is
#   queue_list's absent field; an unknown or equal timestamp cannot order a pair,
#   so both sides fall through to the normalized KEY compare, which is total,
#   stable, and identical from either side.
_ti_older() {
  local aat="${1:-}" akey="${2:-}" bat="${3:-}" bkey="${4:-}"
  [ "$aat" = "-" ] && aat=""
  [ "$bat" = "-" ] && bat=""
  if [ -n "$aat" ] && [ -n "$bat" ] && [ "$aat" != "$bat" ]; then
    [ "$aat" \< "$bat" ]
    return $?
  fi
  [ "$(_ti_norm "$akey")" \< "$(_ti_norm "$bkey")" ]
}

# ticket_identity_say <ticket-id> <other-key> <source> <state>
#   The one sentence both callers put in front of a human, worded PER STATE
#   because they are different claims and only one template can be true of all
#   of them. The keymap arm knows the board's key for this ticket is something
#   else — there may be no second build anywhere yet — so it must not say
#   "already has a build" (D13: copy that a sibling path can render while it is
#   false is a bug). The `merged`/`pr_created`/`running`/`claimed` arms have
#   seen the second build; `queued` has seen only the row, which is why it has
#   its own sentence too.
ticket_identity_say() {
  local tid="${1:-}" other="${2:-}" src="${3:-}" state="${4:-}"
  case "$state" in
    board-key)  printf "the board's own key for ticket %s is %s (%s), not the key this launch was given" "$tid" "$other" "$src" ;;
    merged)     printf 'ticket %s already shipped under key %s (%s)' "$tid" "$other" "$src" ;;
    pr_created) printf 'ticket %s already has an open PR under key %s (%s)' "$tid" "$other" "$src" ;;
    running)    printf 'ticket %s is already being built under key %s (%s)' "$tid" "$other" "$src" ;;
    # QUEUED is not "already has a build": nothing is building yet, which is the
    # whole reason this window was invisible. The generic arm below would render
    # "already has a queued build", a claim that is false while the row sits
    # there unclaimed — the same D13 reason the keymap arm has its own sentence.
    queued)     printf 'ticket %s is already queued for a build under key %s (%s)' "$tid" "$other" "$src" ;;
    # CLAIMED is a third claim and neither of the other two is true of it: a box
    # has taken the row and is booting, so "is already queued" is stale the
    # moment the claim lands, and the generic arm's "already has a claimed
    # build" is the unworded shape D13 keeps away from an operator.
    claimed)    printf 'ticket %s has already been taken by a box for a build under key %s (%s)' "$tid" "$other" "$src" ;;
    # Never silently empty: an unworded refusal is a RESULT nobody can act on.
    *)          printf 'ticket %s already has a %s build under key %s (%s)' "$tid" "$state" "$other" "$src" ;;
  esac
}

# ticket_identity <harness> <project> <ticket-id> — the id on stdout, rc 0,
# when it is a valid ticket id on that project's tracker (tracker_kind,
# bin/lib/tracker.sh); rc 1 and one stderr line otherwise.
#   github-issues  an issue number (`12`); `CRO-12` is refused
#   board          a board id (`[A-Za-z0-9_.:-]+`)
#   jira, linear   `<PREFIX>-<n>`, n >= 1, PREFIX the tracker's own key prefix
#                  (tracker_key_prefix: the Linear team, the Jira project),
#                  compared case-insensitively. A number, another team's key or
#                  no prefix is refused.
# A tracker that does not resolve is refused.
ticket_identity() {
  local h="${1:-}" p="${2:-}" id="${3:-}" kind pfx
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$id" ] || { printf 'ticket-identity: usage: ticket_identity <harness> <project> <ticket-id>\n' >&2; return 1; }
  if ! command -v tracker_kind >/dev/null 2>&1; then
    # shellcheck source=bin/lib/tracker.sh
    . "$h/bin/lib/tracker.sh" 2>/dev/null || { printf 'ticket-identity: no bin/lib/tracker.sh under %s\n' "$h" >&2; return 1; }
  fi
  HARNESS="$h" tracker_kind "$p" >/dev/null 2>&1 && kind=$(HARNESS="$h" tracker_kind "$p" 2>/dev/null) \
    || { printf 'ticket-identity: no tracker resolves for %s\n' "$p" >&2; return 1; }
  case "$kind" in
    github-issues)
      [[ "$id" =~ ^[0-9]+$ ]] || { printf 'ticket-identity: %s is not a GitHub issue number (%s)\n' "$id" "$p" >&2; return 1; } ;;
    board)
      [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ ]] || { printf 'ticket-identity: %s is not a board ticket id (%s)\n' "$id" "$p" >&2; return 1; } ;;
    jira|linear)
      pfx=$(HARNESS="$h" tracker_key_prefix "$p" 2>/dev/null) && [ -n "$pfx" ] \
        || { printf 'ticket-identity: no %s key prefix for %s\n' "$kind" "$p" >&2; return 1; }
      if ! [[ "$id" =~ ^([A-Za-z][A-Za-z0-9_]*)-[1-9][0-9]*$ ]] || [ "$(_ti_norm "${BASH_REMATCH[1]}")" != "$(_ti_norm "$pfx")" ]; then
        printf 'ticket-identity: %s is not a %s key of %s (%s-<n>)\n' "$id" "$kind" "$p" "$pfx" >&2; return 1
      fi ;;
    *) printf 'ticket-identity: %s has tracker %s\n' "$p" "$kind" >&2; return 1 ;;
  esac
  printf '%s\n' "$id"
}

ticket_identity_conflict() {
  local h="${1:-}" project="${2:-}" tid="${3:-}" key="${4:-}"
  [ -n "$h" ] && [ -n "$project" ] && [ -n "$tid" ] && [ -n "$key" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2

  local tidn keyn; tidn=$(_ti_norm "$tid"); keyn=$(_ti_norm "$key")
  # A GitHub-Issues project hands the issue NUMBER as the id and `BH-<n>` as the
  # key, and a board project that has not been mapped yet hands the key twice.
  # Either way there is no second identity to find.
  [ -n "$tidn" ] && [ -n "$keyn" ] && [ "$tidn" != "$keyn" ] || return 1
  # ...and `866` + `BH-866` is the shape an issues lane ACTUALLY hands over:
  # the two strings differ, so the equality above never fired, and every issues
  # launch paid a build-tree scan plus a ledger round trip to learn what the key
  # already says — and answered "I could not consult the ledger" during an
  # outage, about a question that has no second identity in it. The suffix is
  # the WHOLE id after the prefix's dash, so `66` against `BH-866` is still a
  # real question.
  case "$keyn" in *-"$tidn") return 1 ;; esac

  # `unknown` is the difference between "nothing conflicts" and "I could not
  # look". Only the two round-trip sources (c, d) can set it; the two local
  # sources are either there or legitimately absent.
  local unknown=0

  # ── a. the keymap ─────────────────────────────────────────────────────────
  # bin/triage-gate.sh:158 rebuilds state/<project>.keymap.json every consumed
  # tick, id->key and key->id. If the board says this id is some OTHER key, then
  # the key we were handed is a label and this launch is the second identity.
  # A stale keymap can only ever name the BOARD's key for an id, never a label,
  # so it can refuse a label launch and can never refuse a board-key launch.
  local km="$h/state/$project.keymap.json" bk=""
  if [ -s "$km" ]; then
    bk=$(jq -r --arg t "$tid" '.[$t] // ""' "$km" 2>/dev/null) || bk=""
    if [ -n "$bk" ] && [ "$(_ti_norm "$bk")" != "$keyn" ]; then
      printf '%s\t%s\t%s\n' "$bk" keymap board-key
      return 0
    fi
  fi

  # ── a2. the issues board's OWN key, DERIVED (BH-1139) ─────────────────────
  # THE KEYMAP CANNOT COVER A GITHUB-ISSUES BOARD, ever. bin/triage-gate.sh
  # builds state/<project>.keymap.json from a BOARD API; an issues project has
  # none and never will, so source (a) is permanently empty there — and the
  # three sources below only see a duplicate once a second build EXISTS. The
  # first launch under a decomposed child's dotted TITLE LABEL therefore had
  # nothing to refuse it: bin/run-decompose.sh's issues lane titles the child
  # `TK-2411.2: …` while filing it as issue #2487, so `TK-2411.2` and `TK-2487`
  # are one issue with two identities, and `job_open` plus the worker's
  # double-build guard each see only one of them. Two plans, two executes, two
  # PRs, per child, on every split.
  #
  # An issues board needs no keymap: its key for issue N is `<PREFIX>-N` BY
  # CONSTRUCTION. run-decompose writes `children.txt` that way, and
  # bin/orphan-reconcile.sh, bin/preplan-candidates.sh, bin/hotfix-seen.sh and
  # bin/dep-verify.sh all derive it the same way through `preplan_key_prefix`,
  # which reads the rendered launch line in prompts/<project>.md — the ONE place
  # that prefix is written down (fleet.conf has no column for it). So this asks
  # the same function rather than growing a second answer that could disagree
  # with the line triage actually runs.
  #
  # ASKED SECOND, and it is cheap: a registry read, a prompt grep, and at most
  # one settings read (tracker_kind, cached per process). A mis-keyed launch is
  # refused before the build-tree scan and before the ledger and queue are
  # asked at all.
  #
  # EVERY LEG FAILS OPEN AND SILENT — never `unknown`. No fleet-conf.sh on the
  # box, no row in the registry, an in-app board, a non-numeric id, no
  # preplan-lib.sh, no launch line in the prompt: the source says nothing and
  # the other four decide. `unknown` is for a source that could not be
  # CONSULTED; these are a derivation that is not available, and turning them
  # into rc 2 would print "could not consult the ledger" on every board-project
  # launch on the fleet. The in-app gate is the point of the board_prefix test:
  # an in-app board's key for ticket 4711 is whatever the board assigned
  # (AB-12), so deriving `AB-4711` there would refuse a launch naming a key that
  # exists nowhere — the one failure this guard promises never to produce.
  #
  # The GitHub-Issues lane is the tracker seam's answer (tracker_kind,
  # bin/lib/tracker.sh, BH-7919), not fleet.conf column 4 alone: a Linear or
  # Jira project has column 4 `-` too, and its key is the tracker's (CRO-12),
  # never `<PREFIX>-<id>`. tracker_kind is one settings read per process; with
  # no worker it takes column 4, the test bin/run-decompose.sh,
  # bin/orphan-reconcile.sh and bin/triage-gate.sh apply. The id must then be a
  # valid id on that tracker (ticket_identity: an issue NUMBER), or there is
  # nothing a key can be built out of.
  local ipfx="" ikind=""
  if ! command -v tracker_kind >/dev/null 2>&1 && [ -r "$h/bin/lib/tracker.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "$h/bin/lib/tracker.sh" 2>/dev/null
  fi
  if command -v tracker_kind >/dev/null 2>&1 && HARNESS="$h" tracker_kind "$project" >/dev/null 2>&1; then
    ikind=$(HARNESS="$h" tracker_kind "$project" 2>/dev/null) || ikind=""
  fi
  if [ "$ikind" = github-issues ] && ticket_identity "$h" "$project" "$tid" >/dev/null 2>&1; then
    if ! command -v preplan_key_prefix >/dev/null 2>&1 && [ -r "$h/bin/lib/preplan-lib.sh" ]; then
      # shellcheck source=bin/lib/preplan-lib.sh
      . "$h/bin/lib/preplan-lib.sh" 2>/dev/null
    fi
    if command -v preplan_key_prefix >/dev/null 2>&1; then
      ipfx=$(preplan_key_prefix "$h" "$project" 2>/dev/null) || ipfx=""
    fi
    # The inequality is defensive, not decorative: the `*-<tid>` skip at the
    # top already returned for the board's own key, and this has to keep
    # holding if that skip is ever narrowed.
    if [ -n "$ipfx" ] && [ "$(_ti_norm "$ipfx-$tid")" != "$keyn" ]; then
      printf '%s\t%s\t%s\n' "$ipfx-$tid" issues-key board-key
      return 0
    fi
  fi

  # ── b. this box's own build records ───────────────────────────────────────
  # bin/run-build.sh:166 writes {project,ticket_id,key} to every build dir. A
  # sibling dir for the same BOARD id under a different key is the duplicate,
  # and its RESULT says whether that identity still holds the ticket.
  #
  # THE FLY HOP. On a Fly-routed project — most of the fleet, project-4 included —
  # the dir this glob matches is a QUEUED_FLY STUB: it carries the job.json but
  # its RESULT is never rewritten (bin/queued-fly-relayed.sh:21 depends on that
  # exact shape). The build's real outcome lands in the pool TWIN the reap
  # writes, `builds/pool-<project>-<KEY>-<stamp>/` (bin/fly-pool.sh:751), which
  # holds the PR_CREATED/PR_MERGED line and no job.json of its own. Reading only
  # the stub, this source answered "nothing here" for every pool build ever run
  # — so `pr_created` and `merged` fired on watcher-local builds only, and the
  # TK-1789-after-#1592 sequence this ticket is named for happened on project-4,
  # which is pool-routed. A stub therefore hands off to its twin: identity from
  # the stub's job.json, RESULT from the twin. Same `<KEY>` pairing
  # bin/fleet-status-push.sh:218 and bin/pipeline-health.sh:259 already walk.
  #
  # ONE jq PER DIRECTORY, not two. This hub holds 600+ build dirs per project
  # and every launch walks them; asking for `.ticket_id` and then `.key` cost a
  # second process for every dir on the box. One read answers both. (One jq for
  # the WHOLE glob would be cheaper still, and is deliberately not done: jq
  # aborts on the first unparseable input, so a single half-written job.json
  # from a killed build would blind the guard for every other dir behind it.)
  local jf d rk rtid rec url st tw twrec
  for jf in "$h"/builds/"$project"-*/job.json; do
    [ -r "$jf" ] || continue
    IFS=$'\t' read -r rtid rk < <(jq -r '[(.ticket_id // ""), (.key // "")] | @tsv' "$jf" 2>/dev/null)
    [ "$rtid" = "$tid" ] || continue
    [ -n "$rk" ] || continue
    [ "$(_ti_norm "$rk")" = "$keyn" ] && continue   # a -r2 rebuild or a RESUME
    d=$(dirname "$jf")
    rec=$(head -1 "$d/RESULT" 2>/dev/null)
    case "$rec" in
      QUEUED_FLY*)
        # A key with anything glob-shaped in it is not a directory name this
        # walks — same validation bin/queued-fly-relayed.sh:19 applies.
        case "$rk" in
          ''|*[!A-Za-z0-9._-]*) : ;;
          *)
            # Timestamp-ordered glob, so the LAST PR_CREATED read is the newest
            # twin; a MERGED twin ends the walk outright, it is the stronger
            # fact and the one this ticket is about.
            for tw in "$h"/builds/pool-"$project"-"$rk"-*; do
              [ -r "$tw/RESULT" ] || continue
              twrec=$(head -1 "$tw/RESULT" 2>/dev/null)
              case "$twrec" in
                PR_MERGED*)         d="$tw"; rec="$twrec"; break ;;
                "PR_CREATED http"*) d="$tw"; rec="$twrec" ;;
              esac
            done ;;
        esac ;;
    esac
    case "$rec" in
      PR_MERGED*)
        # The work SHIPPED under the other key. Building it again is exactly the
        # TK-1789-after-#1592 sequence this ticket describes.
        printf '%s\t%s\t%s\n' "$rk" build-record merged
        return 0 ;;
      "PR_CREATED http"*)
        [ -e "$d/SUPERSEDED" ] && continue
        url=$(printf '%s' "$rec" | awk '{print $2}')
        if [ -n "$url" ] && command -v job_ledger_get >/dev/null 2>&1; then
          st=$(job_ledger_get merge "$url" 2>/dev/null) || st=""
          case "$st" in
            # THE OTHER HALF OF BH-866: a PR closed unmerged is `pr_closed`,
            # nothing shipped, and the ticket is launchable again.
            closed|abandoned) continue ;;
            # MERGED, and the record does not know it: bin/merge-sweep.sh writes
            # the ledger row and never rewrites the build's RESULT, so a sibling
            # the sweep merged an hour ago still reads PR_CREATED on disk. Saying
            # "already has an open PR" there sends the operator to a PR that is
            # gone, and hides the one state that actually matters — the work
            # SHIPPED under the other key, which is the TK-1789 case itself.
            merged) printf '%s\t%s\t%s\n' "$rk" build-record merged; return 0 ;;
          esac
        fi
        printf '%s\t%s\t%s\n' "$rk" build-record pr_created
        return 0 ;;
    esac
    # Any other RESULT (PLAN_BLOCKED, a failure, BUILD_DEFERRED) is a finished
    # attempt, and a dir with NO RESULT is a dead build — resume-dead-builds.sh's
    # business, not evidence of a live identity. Liveness comes from (c).
  done
  # ── b2. archived build records (BH-7437) ───────────────────────────────────
  # bin/builds-retention.sh moves only MERGED groups to builds-archive/, so an
  # archived key with this board id under another key is the merged case above.
  # shellcheck source=bin/lib/build-archive.sh
  command -v ba_merged_other >/dev/null 2>&1 || . "$h/bin/lib/build-archive.sh" 2>/dev/null || true
  if command -v ba_merged_other >/dev/null 2>&1 && rec=$(ba_merged_other "$h" "$project" "$tid" "$keyn"); then
    printf '%s\t%s\t%s\n' "${rec%%$'\t'*}" build-record merged
    return 0
  fi

  # ── c. the jobs ledger: a LIVE build, on any box ──────────────────────────
  # The only place a build running on another machine is visible, and the board
  # id lives only in the row's meta (bin/run-build.sh:620).
  local rows id rkey rtid rbox rkind
  if command -v job_builds_running >/dev/null 2>&1 && rows=$(job_builds_running "$project" 2>/dev/null); then
    while IFS=$'\t' read -r id rkey rtid rbox rkind; do
      [ "$rtid" = "$tid" ] || continue
      [ -n "$rkey" ] || continue
      [ "$(_ti_norm "$rkey")" = "$keyn" ] && continue
      printf '%s\t%s\t%s\n' "$rkey" ledger running
      return 0
    done <<<"$rows"
  else
    unknown=1
  fi

  # ── d. the queue: ENQUEUED or CLAIMED, no running row on any box yet ──────
  # The window above. Asked AFTER the ledger on purpose: a row that has reached
  # a running row is past this source entirely, so nothing is paid for the
  # order — and if a stale queue row and a running row ever do overlap,
  # `running` is the stronger, later fact and the sentence an operator can act
  # on. Every earlier source keeps the order it already had.
  #
  # ONE PAGE, ONE STATUS. queue_list takes the worker's default page (200 rows,
  # oldest first) and this asks it once per status, so the list is only the rows
  # in that state — never the project's whole history, which is what an
  # unfiltered ask would page through and where a recent row would fall off the
  # end. job_builds_running pages explicitly at 500 for the same reason.
  #
  # CLAIMED IS ASKED FIRST, and it is asked at all because the window does not
  # end at `queued`. `queue_claim` runs on the HUB when a pool machine is
  # spawned or reused (bin/fly-pool.sh); `job_open` — the running row (c) reads
  # — runs on the MACHINE, after boot, clone and the context gate
  # (bin/run-build.sh). Between those two the row says `claimed`, there is no
  # running row anywhere, the stub still has no twin and project-4 still has no
  # keymap: the same blind window, one state further along, and a machine that
  # dies after the claim holds it there until bin/jobs-watchdog.sh's stale sweep
  # releases the row. A claim is also the LATER, stronger fact — the same
  # ordering rule that puts (c)'s `running` ahead of this source — so when a
  # ticket somehow has both, the key a box already took is the one named.
  #
  # THE STATUS COLUMN IS RE-CHECKED HERE, not trusted to the filter. An older
  # worker that ignores `status` degrades to a WIDER list — queue_list documents
  # exactly that for its `deferred` parameter — and a `done` or `failed` row is
  # a finished attempt, never an identity holding the ticket.
  #
  # AND THE ROWS ARE SCOPED TO BUILDS. build_queue is SHARED: the merge
  # conductor enqueues pool REBASE rows on it (`mc_pool_rebase_enqueue`,
  # bin/lib/mc/rebase.sh) whose `ticket_id` is the PR NUMBER and whose key is
  # `RB-<num>-<head8>`. Board ticket ids are integer strings (bin/triage-gate.sh
  # builds the keymap from `.id | tostring`) in the same range as PR numbers, so
  # an unscoped reader answers "ticket 1592 is already queued for a build under
  # key RB-1592-deadbeef" for a launch that duplicates nothing — a refusal in
  # error, repeated every tick, naming a key no operator can launch. (c) has
  # always been scoped this way (`job_builds_running` selects `kind == "build"`)
  # and so is this. A build row carries NO `kind` at all — bin/run-build.sh's
  # QMETA is stack_base/hotfix, bin/blocked-resolver.sh's is deferrals plus a
  # note, bin/jobs-watchdog.sh's is deferrals — so the test is "no kind, or kind
  # build", never "no meta".
  #
  # AND A ROW ONLY REFUSES A LAUNCH THAT IS BEHIND IT. This source sees the same
  # table from BOTH ends of a duplicate, and the guard block runs twice per
  # build: once on the hub before the Fly enqueue, and again on the pool MACHINE
  # (fly/builder-runner.sh -> bin/run-build.sh), where it sits above `job_open`
  # and above the machine's own `queue_claim` while the HUB has already claimed
  # the row at spawn (bin/fly-pool.sh). So the machine's own row reads `claimed`
  # when it asks. A reader that refuses on any sibling row therefore refuses the
  # launch that already HOLDS the claim, and a machine-side BUILD_DEFERRED is
  # REQUEUED by the reap, not closed (bin/fly-pool.sh) — so a ticket that ever
  # holds two rows livelocks: claim, defer, requeue, claim the other, defer,
  # until jobs-watchdog's QDEFER_MAX parks both `failed` and blocked-resolver
  # abandons both, ~18 machines and zero builds, for a ticket that had one
  # legitimate build in it. Two `queued` rows do the same thing to each other.
  # Two rows for one ticket is not hypothetical — it is the project-4 TK-1784 /
  # TK-1766.0 pair this ticket is named for, and it is also what a death-requeue
  # next to a deferral-parked duplicate, jobs-watchdog's deferral requeue, or
  # blocked-resolver's fresh enqueue produce.
  #
  # So the rows are RANKED (`claimed` 2, `queued` 1, no row of our own 0) and a
  # sibling refuses only when it is AHEAD of us:
  #   - a sibling further along (we are queued, it is claimed) refuses — a box
  #     already has that one;
  #   - a sibling BEHIND us (we hold the claim, it is merely queued) does not —
  #     it will meet our `running` row at (c) when its turn comes;
  #   - a sibling in the SAME state is settled by `_ti_older`, a total order both
  #     sides compute identically, so exactly one of the pair stands down and the
  #     other builds. Never both, which was the livelock;
  #   - and a launch with NO row of its own — a hand launch or a label launch in
  #     the blind window, the case this source was written for — is behind every
  #     row and is still refused by all of them.
  #
  # AND A PAGE IT COULD NOT READ MAY HOLD OUR OWN ROW. The two statuses are two
  # round trips, so a PARTIAL outage is a real shape: `claimed` fails, `queued`
  # answers. On the pool machine our own row is the claimed one, so our rank
  # reads 0 — "no row of our own", the rank every sibling is ahead of — and a
  # merely queued sibling refuses the launch that is holding the claim. That is
  # the livelock above, reopened one transient error at a time. So the highest
  # rank that went UNREAD is remembered, and while we have no row of our own a
  # candidate no further along than that rank cannot be proven ahead of us and
  # does not refuse. The refusal survives where the unread page cannot change
  # the answer: a CLAIMED sibling is ahead of us whatever an unread `queued`
  # page holds, and a row of our own that WAS read ranks us for the tie-break.
  local qs qrows qkey qtid qstatus qmeta qat rank
  local own_rank=0 own_at="" cands="" blind_rank=0
  if command -v queue_list >/dev/null 2>&1; then
    for qs in claimed queued; do
      if qrows=$(queue_list "$project" "$qs" 2>/dev/null); then
        while IFS=$'\t' read -r _ qkey qtid qstatus _ _ _ qat _ qmeta; do
          # A row missing a field collapses under IFS=$'\t' and every later
          # column shifts left, so this check drops a malformed row too.
          [ "$qstatus" = "$qs" ] || continue
          [ "$qtid" = "$tid" ] || continue
          [ -n "$qkey" ] || continue
          _ti_is_build_row "$qmeta" || continue
          [ "$qs" = claimed ] && rank=2 || rank=1
          if [ "$(_ti_norm "$qkey")" = "$keyn" ]; then
            # OUR OWN row — this launch's enqueue, or the claim the hub took for
            # this very machine. Never a conflict, and the thing every sibling is
            # ranked against.
            [ "$rank" -gt "$own_rank" ] && { own_rank=$rank; own_at="$qat"; }
            continue
          fi
          cands="$cands$qkey"$'\t'"$qs"$'\t'"$rank"$'\t'"$qat"$'\n'
        done <<<"$qrows"
      else
        unknown=1
        [ "$qs" = claimed ] && rank=2 || rank=1
        [ "$rank" -gt "$blind_rank" ] && blind_rank=$rank
      fi
    done
    # Claimed candidates were collected first and are judged first: a claim is
    # the later, stronger fact, the same ordering rule that puts (c)'s `running`
    # ahead of this whole source.
    while IFS=$'\t' read -r qkey qs rank qat; do
      [ -n "$qkey" ] || continue
      [ "$rank" -lt "$own_rank" ] && continue
      # No row of our own was READ, and a page that could have held one went
      # unread: a candidate at or below that rank is not evidence that we are
      # behind it. Falls to rc 2 (unknown is already set) — proceed and say so.
      [ "$own_rank" -eq 0 ] && [ "$rank" -le "$blind_rank" ] && continue
      if [ "$rank" -eq "$own_rank" ] && [ "$own_rank" != 0 ] \
         && ! _ti_older "$qat" "$qkey" "$own_at" "$key"; then
        continue
      fi
      printf '%s\t%s\t%s\n' "$qkey" queue "$qs"
      return 0
    done <<<"$cands"
  else
    unknown=1
  fi

  [ "$unknown" = 1 ] && return 2
  return 1
}
