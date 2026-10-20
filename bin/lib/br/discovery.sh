#!/bin/bash
# shellcheck shell=bash
# module: discovery
# bin/lib/br/discovery.sh — BH-6517: the resolver's BUILD-RECORD discovery
# sources. br_from_queue reads the pool's parked queue rows, br_from_builds walks
# the build records, br_from_rebuilds (with br_rebuild_outcome and
# br_rebuild_artifact) reads a held rebuild's RESULT, and br_candidates calls
# every source in order. Sourced by bin/blocked-resolver.sh, never run. It reads
# $ST, $H and the BR_* knobs at CALL time and nothing at source time.
#
# This is the ONLY definition of the 6 functions. br_candidates still calls
# br_from_conductor and br_from_reviews in the driver: every call happens at run
# time, after the driver has defined everything. The conductor hand-off sources
# are the next slice (C1 of BH-6517).
# ---------------------------------------------------------------------------

# The pool's parked queue rows. The DB is the source when it answers; the
# .failed.json files bin/fly-pool.sh writes beside the queue are the fallback,
# because a worker outage must not make a parked ticket invisible — invisible is
# exactly the state this lane exists to end.
br_from_queue() {
  local p k rsn seen="" line lrc=1 rows_only=0 qtmp=""
  # BH-1026.3: once nothing WRITES the sidecar, reading it is reading a file
  # that no longer exists — but only once. The fallback loop below still runs
  # with the flag off (the pool writes the file then) and still runs when the
  # list did not answer, because a worker outage must not make a parked ticket
  # invisible. rc 1 is the only value that means "could not ask": rc 0 with no
  # rows is a real answer and means nothing is parked.
  command -v build_queue_rows_only_on >/dev/null 2>&1 && build_queue_rows_only_on && rows_only=1
  if command -v queue_list >/dev/null 2>&1; then
    # Through a temp file, not a process substitution: the rc of the list is
    # what decides whether the fallback runs, and `done < <(...)` throws it away.
    qtmp=$(mktemp "${TMPDIR:-/tmp}/br-queue.XXXXXX" 2>/dev/null) || qtmp=""
    if [ -n "$qtmp" ]; then
      queue_list "" failed > "$qtmp" 2>/dev/null; lrc=$?
    fi
    while IFS=$'\t' read -r p k _tid _st _tg _att _by _en rsn _meta; do
      [ -n "${p:-}" ] && [ -n "${k:-}" ] || continue
      [ -z "$ONLY" ] || [ "$ONLY" = "$p" ] || continue
      # A row whose reason begins PR_CREATE_FAILED is deliberately NOT a park
      # here (BH-614): bin/fly-pool.sh closes it FAILED at reap time, seconds
      # after the build ended, and bin/pr-url-reconcile.sh needs its ten-minute
      # window to find out whether the PR opened anyway. The RECORD is the
      # intake, behind br_from_builds' 90-minute floor.
      # A LANE FAILURE IS NOT A REBUILD (2026-09-23 pool loop). A row whose
      # reason is the runner lane's own verdict — RUNNER_EXHAUSTED, or
      # class=auth — deferred because every account or floor under it was out,
      # and a fresh rebuild meets the same lane and spends a machine finding
      # out: 71 tickets went round that loop in one night. bin/fly-pool.sh no
      # longer parks such a row; this skips the ones parked before it stopped.
      case "$rsn" in *RUNNER_EXHAUSTED*|*" class=auth"*) continue ;; esac
      case "$rsn" in
        *"died "*times*|*"died twice"*) printf 'queue\t%s\t%s\tpool-died-twice\t-\t-\t%s\t-\n' "$p" "$(br_rkey "$p-$k")" "$k" ;;
        *"deferred "*times*)            printf 'queue\t%s\t%s\tpool-deferred-max\t-\t-\t%s\t-\n' "$p" "$(br_rkey "$p-$k")" "$k" ;;
        # BH-5912: the per-key spawn cap closed rows this way before BH-4859
        # made it a timed retry, and nothing owned them. Same rebuild ladder.
        *"spawn cap"*"deferred to a human"*) printf 'queue\t%s\t%s\tpool-deferred-max\t-\t-\t%s\t-\n' "$p" "$(br_rkey "$p-$k")" "$k" ;;
        *) continue ;;
      esac
      seen="$seen $p/$k"
    done < "${qtmp:-/dev/null}"
    [ -n "$qtmp" ] && rm -f "$qtmp"
  fi
  # The rows answered and they are the source: the sidecar loop is what this
  # slice removes.
  [ "$rows_only" = 1 ] && [ "$lrc" -ne 1 ] && return 0
  for f in "$H"/state/build-queue/*/*.failed.json; do
    [ -f "$f" ] || continue
    p=$(basename "$(dirname "$f")"); k=$(jq -r '.key // ""' "$f" 2>/dev/null)
    [ -n "$k" ] || continue
    [ -z "$ONLY" ] || [ "$ONLY" = "$p" ] || continue
    case " $seen " in *" $p/$k "*) continue ;; esac
    printf 'queue\t%s\t%s\tpool-died-twice\t-\t-\t%s\t-\n' "$p" "$(br_rkey "$p-$k")" "$k"
  done
}

# Build records that ended on a terminal nothing re-enters: the REVIEW_BLOCKED
# gates, the PLAN_MALFORMED hold, the resume lane's BUILD_DEAD, and the two
# shapes bin/review-rescue.sh retires (`.review-rescued` on a still-blocked
# record, and a re-scan that found a real deletion).
#
# PLAN_BLOCKED IS DELIBERATELY NOT HERE FOR BOARD PROJECTS. On an in-app product
# board the open question is addressed to the CLIENT, and the client does answer
# — the early-engagement incident is the standing lesson about building past one. On a
# GitHub-Issues lane the planner no longer parks at all (bin/run-build.sh's
# assumption-forward rule), so any PLAN_BLOCKED record there is from before that
# shipped and is exactly a rebuild candidate.
br_from_builds() {
  local d bn core project rest key first rec_reason prefix pl bproj
  local -a bglob=()
  local -A bseen=()
  local bi="" bp rows bdir bupd bres bjob bep bst bsx bat bate bnow
  local -a bor_items=() bor_p=() bor_key=() bor_res=() bor_ep=()
  # LEDGER-ONLY RECORDS (BH-2349). A build whose record never reached this box
  # is still in the jobs ledger. Only rows with a job id and NO local dir are
  # added: a local dir stays the glob's below, markers and all, so nothing is
  # offered twice. An outage (rc 1) or an empty ledger (rc 2) adds nothing and
  # the glob is the whole answer, exactly as before the ledger existed.
  if command -v bor_union >/dev/null 2>&1; then
    # shellcheck source=bin/lib/build-archive.sh
    command -v ba_path >/dev/null 2>&1 || . "$H/bin/lib/build-archive.sh" 2>/dev/null || true
    bnow=$(date -u +%s)
    while IFS= read -r bp; do
      [ -n "$bp" ] || continue
      [ -z "$ONLY" ] || [ "$ONLY" = "$bp" ] || continue
      rows=$(bor_union "$bp" 2>/dev/null) || continue
      while IFS=$'\t' read -r _ bdir _ bupd bres _ bjob; do
        [ -n "$bdir" ] && [ "${bjob:--}" != - ] || continue
        bor_local_dir "$bdir" >/dev/null 2>&1 && continue
        # An archived dir (BH-7437) is a dir: its record is never re-offered.
        command -v ba_path >/dev/null 2>&1 && ba_path "$H" "$bdir" >/dev/null 2>&1 && continue
        case "$bdir" in "$bp"-*) ;; *) continue ;; esac
        rest="${bdir#"$bp"-}"; key="${rest%-*}"
        [ -n "$key" ] || continue
        [ -n "$bupd" ] || continue
        bep=$(date -u -d "$bupd" +%s 2>/dev/null) || continue
        # NOT RE-OFFERED. There is no dir to carry .blocked-resolver-superseded,
        # so the ticket's own state is the marker: this build already consumed
        # (rebuild_seen), or a ladder attempt at or after the record, means the
        # resolver has acted on it. An unreadable state file fails closed.
        # Read directly, not via br_load: its ledger restore (BH-2317) brings back
        # counters, not rebuild_seen or attempts, so a wiped file is "not seen" either way.
        bst="$ST/$bp/$(br_rkey "$bp-$key").json"
        if [ -f "$bst" ]; then
          bsx=$(jq -r --arg b "$bdir" '[
              ((.rebuild_seen // []) | any(. == $b or . == ("pool-" + $b) or . == ("fly-" + $b))),
              ([.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not))] | last | (.at // ""))
            ] | @tsv' "$bst" 2>/dev/null) || continue
          [ "${bsx%%$'\t'*}" = false ] || continue
          bat="${bsx#*$'\t'}"
          if [ -n "$bat" ]; then
            bate=$(date -u -d "$bat" +%s 2>/dev/null) || continue
            [ "$bate" -lt "$bep" ] || continue
          fi
        fi
        bor_items+=("ledger:${#bor_p[@]}")
        bor_p+=("$bp"); bor_key+=("$key"); bor_res+=("$bres"); bor_ep+=("$bep")
      done <<<"$rows"
    done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
  fi
  # NO FORK PER RECORD, AND A PROJECT RUN READS ONLY ITS OWN (BH-6044). On
  # 2026-10-11 builds/ held 7,887 dirs, and this walk forked bin/project-of.sh
  # (and through it fleet-conf.sh) for every record before it dropped the rows
  # of other projects. The second glob also matched every pool-* dir again.
  # Since BH-5913 thirteen project runs did that whole walk at once: ~4,700 s
  # of discovery each, the hub at load 80 on 8 vCPUs, and the merge conductor's
  # workers killed at their deadline before their first line. So a project run
  # globs builds/<p>-*/ and builds/pool-<p>-*/ only, the fleet glob visits each
  # dir once, and the owner of a dir is matched in this shell against ONE read
  # of the project list — project-of.sh --prefix's own rule: `pool-` stripped,
  # the longest project name that prefixes `<name>-` wins (project-6-os over
  # project-6). A list that cannot be read owns nothing, as project-of.sh did.
  pl=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-) || pl=""
  if [ -n "$ONLY" ]; then
    bglob=("$H"/builds/pool-"$ONLY"-*/ "$H"/builds/"$ONLY"-*/)
  else
    bglob=("$H"/builds/pool-*-*/ "$H"/builds/*-*/)
  fi
  for d in "${bglob[@]}" "${bor_items[@]}"; do
    bi=""
    case "$d" in ledger:*) bi="${d#ledger:}" ;; esac
    if [ -n "$bi" ]; then
      # A ledger-only record has no dir: `-` is its record, as on the queue source.
      project="${bor_p[$bi]}"; key="${bor_key[$bi]}"; first="${bor_res[$bi]}"; d=-
    else
    [ -d "$d" ] || continue
    d="${d%/}"; bn="${d##*/}"
    # `*-*` matches every pool-* dir as well: each record is visited once.
    [ -n "${bseen[$d]:-}" ] && continue
    bseen[$d]=1
    [ -f "$d/RESULT" ] || continue
    [ -f "$d/.blocked-resolver-abandoned" ] && continue
    [ -f "$d/.blocked-resolver-superseded" ] && continue
    core="${bn#pool-}"; core="${core#pool-}"; project=""
    for bproj in $pl; do
      case "$core" in "$bproj"-*) project="$bproj"; break ;; esac
    done
    [ -n "$project" ] || continue
    [ -z "$ONLY" ] || [ "$ONLY" = "$project" ] || continue
    rest="${core#"$project"-}"; key="${rest%-*}"
    [ -n "$key" ] || continue
    # HELD, AND RE-READ ON EVERY TICK. The incident's own shape is a park whose
    # PR is already closed, so the conductor has no row for it and this source is
    # the only one that can re-offer it. While the ladder's state still says HELD
    # the row IS offered — br_one re-reads the issue, answers rc 3 for as long as
    # the hold stands (no rung, no slot, no line) and resumes the ladder with its
    # counters intact the moment the thread lifts it. With no HELD row the marker
    # is the twin of .blocked-resolver-abandoned: out of the candidate list.
    if [ -f "$d/.blocked-resolver-held" ] \
       && [ "$(jq -r '.outcome // ""' "$ST/$project/$(br_rkey "$project-$key").json" 2>/dev/null)" != HELD ]; then
      continue
    fi
    first=$(head -1 "$d/RESULT" 2>/dev/null)
    fi
    rec_reason=""
    case "$first" in
      "REVIEW_BLOCKED test-tamper"*)       rec_reason=test-tamper ;;
      "REVIEW_BLOCKED reproduction-gate"*) rec_reason=reproduction-gate ;;
      "REVIEW_BLOCKED intent-gate"*)       rec_reason=intent-gate ;;
      "REVIEW_BLOCKED"*)                   rec_reason=rescue-giving-up ;;
      "PLAN_MALFORMED"*)                   rec_reason=plan-malformed ;;
      "BUILD_DEAD"*)                       rec_reason=build-dead ;;
      # A FAILED CREATE IS TAKEN FROM THE RECORD ONLY, NEVER FROM THE QUEUE ROW
      # (BH-614). bin/fly-pool.sh closes that row FAILED the moment it reaps, and
      # an intake there would rebuild within seconds — while
      # bin/pr-url-reconcile.sh (every 10 minutes) is still working out whether
      # the PR did open after all on a later rung and re-linking line 1 to
      # PR_CREATED. Rebuilding into that is two PRs for one ticket. The
      # 90-minute record floor below IS the reconciler's window, by
      # construction, and a record it re-linked reads PR_CREATED here and is
      # never offered.
      "PR_CREATE_FAILED"*)                 rec_reason=pr-create-failed ;;
      # BH-765's spelling of the same park, for a record an older pool image
      # wrote: the reap judged field 2 and found no PR url. It is read here as
      # the same reason and never as a PR_CREATED. RESULT_UNVERIFIED is
      # deliberately NOT in this list — that is a PR that could not be READ, the
      # alert medic owns it, and rebuilding it would open a second PR.
      "RESULT_MALFORMED PR_CREATED"*)      rec_reason=pr-create-failed ;;
      # A RUN THE LANE REAPER KILLED (BH-1770). the operator, 2026-09-24: the relaunch
      # is this lane's, on the capped ladder, and never the sweep's. Only with
      # REAPED: the reaper writes the verdict BEFORE it signals, so a verdict
      # with no REAPED is a kill that has not landed and a lane that may still
      # hold its claim — relaunching into that is two builds of one ticket.
      "ABANDONED_TIMEOUT"*)
        [ -f "$d/REAPED" ] && rec_reason=abandoned-timeout ;;
      "PLAN_BLOCKED"*)
        prefix=$("$H/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null)
        [ "$prefix" = "-" ] && rec_reason=plan-blocked ;;
    esac
    # A rescue that found a REAL deletion is a test-tamper ADJUDICATION, not a
    # rebuild: the question "was removing that test legitimate" has an answer,
    # and rebuilding without answering it just produces the same block again.
    [ -s "$d/test-tamper-rescan.txt" ] && grep -q 'JUSTIFICATION: NONE' "$d/test-tamper-rescan.txt" 2>/dev/null && rec_reason=rescue-real-deletion
    [ -n "$rec_reason" ] || continue
    # A record whose terminal was only reached MINUTES ago still belongs to the
    # lanes that own the first retry (review-rescue, the watchdog's resume pass). This
    # lane is the backstop, so it waits them out.
    #
    # A REAPED RUN WAITS ONLY FOR THE SWEEP'S CLOSE-OUT (BH-1770). Nobody but
    # this lane retries it — the reaper has finished and resume-dead-builds
    # skips any dir with a RESULT — so the one thing worth waiting for is the
    # sweep's honest board comment, which this lane's COMMENTED marker would
    # otherwise pre-empt. COMMENTED means it has been said; the 90-minute floor
    # is the backstop for a sweep that never gets there.
    #
    # A LEDGER-ONLY record is aged by its ledger updated_at, on the same floors.
    if [ -n "$bi" ]; then [ $((bnow - bor_ep[bi])) -gt 5400 ] || continue
    elif [ "$rec_reason" = abandoned-timeout ] && [ -f "$d/COMMENTED" ]; then :
    else [ -n "$(find "$d/RESULT" -mmin +90 2>/dev/null)" ] || continue; fi
    # REVIEW_BLOCKED specifically is bin/review-rescue.sh's first: it re-runs the
    # gate and can re-open the PR for a build that was only ever blocked by a
    # scanner bug, which is cheaper than any rung here. `.review-rescued` is the
    # marker it writes when it is finished with a record either way. The 6-hour
    # floor is the honest backstop for the case where that lane is switched off
    # (flags/review-rescue-disabled) and the marker will never arrive — without
    # it, one flag would make this whole class invisible again.
    #
    # A CONTRACT-FIRST CHILD BLOCKED ON TAMPER SKIPS THAT BACKSTOP (BH-1047).
    # review-rescue re-runs the SAME scanner, so on a tamper record whose report
    # says CONTRACT_CHILD: it will reach the same answer and the six hours buy
    # nothing but the delay five project-4 fillers already paid (TK-1828, 1872,
    # 1896, 1908, 1909 - a day or two each, then a person ruled on them by hand).
    # The adjudication is the rung that can actually answer "was that stub flip
    # legitimate", so it runs once the 90-minute floor above has passed, like
    # every other park here.
    #
    # The two lanes therefore share this record from minute 90, so the guard
    # runs both ways: bin/review-rescue.sh skips any record stamped
    # `.blocked-resolver-superseded`, which is what br_rebuild_fresh writes when
    # an adjudication here has closed the PR and enqueued the fresh build.
    # Without that, the rescue tick after an ACCEPT would open a second PR on
    # the old branch and buy a second review for one ticket.
    #
    # TAMPER ONLY, and the reason is that the scanner prints CONTRACT_CHILD: on
    # every `.N` child's scan including the clean ones. A contract child parked
    # on the repro gate or the intent gate has a report with that line in it and
    # a block the rescue lane CAN still help with, so it keeps the backstop it
    # has today.
    case "$rec_reason" in
      test-tamper|reproduction-gate|intent-gate|rescue-giving-up)
        [ -f "$d/.review-rescued" ] \
          || { [ "$rec_reason" = test-tamper ] \
               && grep -qs '^CONTRACT_CHILD:' "$d/test-tamper-rescan.txt" "$d/test-tamper.txt"; } \
          || [ -n "$(find "$d/RESULT" -mmin +360 2>/dev/null)" ] \
          || { [ -n "$bi" ] && [ $((bnow - bor_ep[bi])) -gt 21600 ]; } || continue ;;
    esac
    printf 'build\t%s\t%s\t%s\t-\t%s\t%s\t-\n' "$project" "$(br_rkey "$project-$key")" "$rec_reason" "$d" "$key"
  done
}

# THE REBUILD THIS LANE STARTED HAS FINISHED — the fourth source (2026-09-16).
#
# Rung 3 closed a PR and enqueued a fresh build, and then nothing in this lane
# ever asked how that build ended. project-5 #1645: rebuild enqueued 14:24Z, the
# fresh build ended DECOMPOSE_FAILED at 14:39Z, and the ticket sat untouched —
# no rebuild 2, no abandon, no comment, and a board whose last word was still
# "Built and opened for review". The other three sources could not see it
# either: br_from_builds waits 90 minutes (6 hours for a REVIEW_BLOCKED), reads
# PLAN_BLOCKED only on a GitHub-Issues lane and DECOMPOSE_FAILED never, and the
# original record was marked superseded before the enqueue precisely so it would
# not be re-offered.
#
# So the ticket's own state file is the source: a record with no outcome whose
# LAST attempt was `rebuild-fresh` has a build in flight, and the answer is
# whichever RESULT arrived after that attempt.

# br_rebuild_outcome <RESULT first line> -> the reason word, or nothing.
# PURE, so §1 of the fixture drives it as a table. Anything not listed here
# belongs to the lane that owns it today (a BUILD_DEFERRED to the pool's own
# re-offer, a DECOMPOSED to the dispatcher) and is NOT consumed: a classifier
# that gates an irreversible ABANDON has to answer "not mine" far more often
# than it answers at all.
br_rebuild_outcome() {
  case "${1:-}" in
    "PR_CREATED "*|"RESULT_UNVERIFIED PR_CREATED"*|"PR_MERGED"*) echo rebuild-landed ;;
    "BUILD_DEAD"*)        echo rebuild-build-dead ;;
    # The rebuild ran past its deadline and bin/lane-reaper.sh killed it
    # (BH-1770): a dead run like any other, so it spends the next rebuild.
    # br_from_rebuilds consumes it only once the record carries REAPED.
    "ABANDONED_TIMEOUT"*) echo rebuild-build-dead ;;
    "DECOMPOSE_FAILED"*)  echo rebuild-decompose-failed ;;
    "PLAN_BLOCKED"*)      echo rebuild-plan-blocked ;;
    "REVIEW_BLOCKED"*)    echo rebuild-review-blocked ;;
    # A rebuild that itself ends PR_CREATE_FAILED (or RESULT_MALFORMED) is "not
    # mine" here on purpose (BH-614): it re-enters through br_from_builds after
    # the 90-minute floor, on the same per-ticket `rebuilds` counter, so one
    # PR-open failure buys one rebuild and the third park ends ABANDONED.
    *)                    echo "" ;;
  esac
}

# br_rebuild_artifact <RESULT line> <OUTCOME> — the file a person should open.
# The RESULT line usually names it ("… see /root/harness/builds/…/plan.md"), and
# when it does not, each outcome has one conventional file. Never invented: with
# neither, the caller says "the build record" rather than a plausible path.
br_rebuild_artifact() {
  local line="${1:-}" oc="${2:-}" a=""
  a=$(printf '%s' "$line" | sed -nE 's#.*[[:space:]]see[[:space:]]+([^[:space:]]+).*#\1#p' | head -1)
  [ -n "$a" ] || a=$(printf '%s' "$line" | grep -oE '(^| )/[^ ]+' | tail -1 | tr -d ' ')
  if [ -z "$a" ]; then
    case "$oc" in
      DECOMPOSE_FAILED) a="decompose-run.txt" ;;
      PLAN_BLOCKED)     a="plan.md" ;;
      REVIEW_BLOCKED)   a="review.md" ;;
    esac
  fi
  printf '%s' "$a"
}

br_from_rebuilds() {
  local f p ck key st at at_ep url seen d dn ep out res res_ep rec n=0
  local qrow qat qep wj recname now oc last prec brc bdir bupd bres
  local -A bor_rows=() bor_rc=()
  now=$(date -u +%s)
  for f in "$ST"/*/*.json; do
    [ -f "$f" ] || continue
    # THE EFFECTIVE budget, not the knob (review M12): on a tick that carried
    # unspent rungs the fleet may spend up to twice BR_PER_TICK, and a source
    # that stopped at the knob would leave the carry nothing to buy.
    [ "$n" -lt "${EFF_PER_TICK:-$PER_TICK}" ] || break
    # NO FORK BEFORE THE PROJECT FILTER (BH-6044): all 13 project runs walk
    # every project's state files, so a fork here is paid 13 times per file.
    p="${f%/*}"; p="${p##*/}"
    [ -z "$ONLY" ] || [ "$ONLY" = "$p" ] || continue
    st=$(cat "$f" 2>/dev/null); [ -n "$st" ] || continue
    oc=$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)
    ck="${f##*/}"; ck="${ck%.json}"
    # THE ENQUEUE THAT DID NOT LAND (BH-488). Rung 3 closed the PR, marked the
    # record superseded and released the conductor's hand-off BEFORE the enqueue
    # — so when the enqueue answers rc 1 there is no source left that can see
    # this ticket: the conductor row is CLOSED, the record is marked, the queue
    # never got a row. "Retried next tick" was false for seven hours on
    # project-5 #1315/#1383. THIS is the source that re-offers it, and the retry
    # rung re-tries the ENQUEUE ONLY — it never closes a PR a second time.
    #
    # BOTH NON-TERMINAL ENQUEUE ANSWERS COME BACK HERE (BH-1007). rc 1 writes
    # `rebuild-fresh-failed` and rc 4 writes `rebuild-fresh-board-miss`, and the
    # two are the same shape of unfinished business: the PR is closed, the row
    # is on its way to CLOSED, and the queue row is still owed. Re-offering only
    # the first is how the board-miss cap became unreachable — the conductor's
    # closed-without-merging sweep (bin/merge-conductor.sh) moves the row to
    # CLOSED on its next tick, br_from_conductor reads BLOCKED_HUMAN/RED_TWICE
    # only, and a park recorded as a board miss was then never revisited:
    # board_misses frozen at 1, no second miss, no cap, no abandon, no page —
    # the silent orphan BH-1007 was filed about. The cap only ever ran in a
    # fixture with no conductor, where the row stayed BLOCKED_HUMAN and rung 3
    # was re-entered each tick.
    #
    # HELD is allowed here and nowhere else in this source: br_hold_gate can
    # park the retry, and the row has to keep being offered so br_hold_recheck
    # sees the lift. A held row costs no slot (br_one answers rc 3).
    # A data-lane park's own rows (BH-4926) are read past the same way.
    last=$(printf '%s' "$st" | jq -r '[.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not) and (startswith("data-lane") | not) and . != "escalate-data-lane")] | last | (.action // "")' 2>/dev/null)
    case "$last" in
      rebuild-fresh-failed|rebuild-fresh-board-miss)
      case "$oc" in ''|HELD) ;; *) continue ;; esac
      # A PR-number cap key means no key was EVER derivable (the rc-2 refusal,
      # which is counted and capped by br_rebuild_fresh). There is nothing to
      # enqueue with, so there is nothing to retry.
      case "$ck" in "$p"-*) ;; *) continue ;; esac
      key=$(br_key_shape "${ck#"$p"-}") || continue
      url=$(printf '%s' "$st" | jq -r '.parked_url // "-"' 2>/dev/null)
      prec=$(printf '%s' "$st" | jq -r '.parked_rec // "-"' 2>/dev/null)
      printf 'rebuild\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$p" "$ck" rebuild-enqueue-failed "${url:--}" "${prec:--}" "$key"
      n=$((n+1))
      continue
      ;;
    esac
    # Terminal, or no rebuild in flight: the last attempt is what says whether
    # this lane is waiting on a build of its own. A rebuild parked on a human
    # step (BH-3443: HELD with nh_placed) is still offered, so br_one re-reads
    # its hold on every tick the way it does for rebuild-fresh-failed above;
    # held, it costs no slot (rc 3).
    case "$oc" in
      '') ;;
      HELD) [ -n "$(printf '%s' "$st" | jq -r '.nh_placed // ""' 2>/dev/null)" ] || continue ;;
      # Parked on the data lane (BH-4926): offered so br_one re-reads the
      # ledger and the probe; parked, it costs no slot (rc 3).
      DATA_LANE) ;;
      *) continue ;;
    esac
    # THE HOLD AND STALL ATTEMPTS ARE NOT LADDER ATTEMPTS, so they are read past.
    # `held`, `hold-unreadable` and `hold-lifted` are written by a gate that
    # spends no rung and starts no build; counting one of them as "the last thing
    # this lane did" would hide a rebuild that IS in flight — one rate-limited
    # read while a fresh build is running would drop the ticket out of this
    # source for good, which is the project-5 #1645 shape all over again.
    # `stalled` and `stall-cleared` (BH-1122) are the same shape and were bought
    # by the same mistake once: a stall that displaced `rebuild-fresh-failed`
    # would make the STALLED alert's own instruction false, because clearing
    # .outcome would put back a row this source no longer recognises.
    [ "$last" = rebuild-fresh ] || continue
    at=$(printf '%s' "$st" | jq -r '[.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not) and (startswith("data-lane") | not) and . != "escalate-data-lane")] | last | (.at // "")' 2>/dev/null)
    # AN UNREADABLE TIMESTAMP ABORTS. Everything below is "did this RESULT arrive
    # after the rebuild started", and without a start there is no such question.
    [ -n "$at" ] || continue
    at_ep=$(date -u -d "$at" +%s 2>/dev/null) || continue
    # The cap key is <project>-<KEY> whenever a key was derivable. When it is not
    # (a PR-number key like o-tproj-77) there is no build to poll for, and the
    # nokey cap in br_rebuild_fresh is that park's answer instead.
    case "$ck" in "$p"-*) ;; *) continue ;; esac
    key=$(br_key_shape "${ck#"$p"-}") || continue
    url=$(printf '%s' "$st" | jq -r '.parked_url // "-"' 2>/dev/null)
    seen=$(printf '%s' "$st" | jq -r '(.rebuild_seen // []) | join(" ")' 2>/dev/null)
    # THE RECORD. Every shape the rebuild can land in: a pool build reaped onto
    # the hub (pool-…), a fly lane's own dir, a box/hub build, and the relayed
    # copy (<project>-<KEY>-remote<stamp>, which the third glob already covers).
    # The ORIGINAL record is marked superseded before the enqueue, so it can
    # never match; an already-abandoned one is somebody's closed evidence.
    rec=""; res=""; res_ep=0; recname=""
    # THE LEDGER FIRST (BH-2349): bor_union is the ledger's rows plus every local
    # record it does not name, read once per project per call. Its updated_at
    # replaces the RESULT mtime (a local-only row's updated_at IS that mtime).
    # An outage (rc 1) or no lib is the glob below, unchanged.
    brc=1
    if command -v bor_union >/dev/null 2>&1; then
      if [ -z "${bor_rc[$p]+x}" ]; then
        bor_rows[$p]=$(bor_union "$p" 2>/dev/null); bor_rc[$p]=$?
      fi
      brc="${bor_rc[$p]}"
    fi
    if [ "$brc" != 1 ]; then
      while IFS=$'\t' read -r _ bdir _ bupd bres _ _; do
        # The trailing dash keeps BH-23 from answering for BH-234.
        case "$bdir" in "$p-$key-"*) ;; *) continue ;; esac
        d=$(bor_local_dir "$bdir" 2>/dev/null) || d=""
        if [ -n "$d" ]; then
          [ -f "$d/.blocked-resolver-superseded" ] && continue
          [ -f "$d/.blocked-resolver-abandoned" ] && continue
          dn=$(basename "$d")
        else
          dn="$bdir"
        fi
        case " $seen " in *" $dn "*|*" $bdir "*|*" pool-$bdir "*|*" fly-$bdir "*) continue ;; esac
        [ -n "$bupd" ] || continue
        ep=$(date -u -d "$bupd" +%s 2>/dev/null) || continue
        [ "$ep" -ge "$at_ep" ] || continue
        [ "$ep" -ge "$res_ep" ] || continue
        rec="$d"; recname="$dn"; res_ep="$ep"; res="$bres"
        # A local RESULT wins over the ledger's copy of line 1: bin/pr-url-reconcile.sh
        # rewrites it in place (PR_CREATE_FAILED -> PR_CREATED), and the ledger
        # line would rebuild into a PR that did open (BH-614).
        [ -n "$d" ] && [ -f "$d/RESULT" ] && res=$(head -1 "$d/RESULT" 2>/dev/null)
      done <<<"${bor_rows[$p]}"
    else
    for d in "$H"/builds/pool-"$p"-"$key"-* "$H"/builds/fly-"$p"-"$key"-* \
             "$H"/builds/"$p"-"$key"-*; do
      d="${d%/}"
      [ -d "$d" ] && [ -f "$d/RESULT" ] || continue
      [ -f "$d/.blocked-resolver-superseded" ] && continue
      [ -f "$d/.blocked-resolver-abandoned" ] && continue
      dn=$(basename "$d")
      case " $seen " in *" $dn "*) continue ;; esac
      ep=$(date -u -r "$d/RESULT" +%s 2>/dev/null) || continue
      # A RESULT older than the rebuild attempt is a PREVIOUS build of this
      # ticket, not the one we started. Two newer ones: the newest wins and the
      # other is left to br_from_builds exactly as today.
      [ "$ep" -ge "$at_ep" ] || continue
      [ "$ep" -ge "$res_ep" ] || continue
      rec="$d"; recname="$dn"; res_ep="$ep"; res=$(head -1 "$d/RESULT" 2>/dev/null)
    done
    fi
    # THE LEDGER ROW is the fallback for a remote build whose record never
    # reached this box: bin/fly-pool.sh closes the row `done` with the RESULT
    # line as its reason. Fail closed on anything it cannot place in time.
    if [ -z "$res" ] && command -v queue_list >/dev/null 2>&1; then
      qrow=$(queue_list "$p" "done" 2>/dev/null \
             | awk -F'\t' -v k="$key" '$2==k && $4=="done" {print; exit}')
      if [ -n "$qrow" ]; then
        qat=$(cut -f8 <<<"$qrow")
        # AN EXTERNAL BUILD IS ALWAYS OLDER THAN OUR ATTEMPT (BH-947 review I1).
        # `>= at_ep` asks "did this RESULT arrive after the rebuild started",
        # which is the right question for a build THIS LANE enqueued. For a job
        # somebody else queued, the attempt br_rebuild_wait records is written at
        # FIRST SIGHTING — always after the worker's own enqueue — so that test
        # can never be true and the build the lane is holding for would never be
        # consumed: the next tick reads the row as `done`, finds no result, and
        # buys a second build on top of one that already produced a PR. The wait
        # field is what says the row IS that job: an external hold writes
        # `wait_job=<KEY>@<enqueued_at>` (br_rebuild_wait) or, when the re-probe
        # behind a `duplicate` answer could not read a row, the placeholder
        # `<KEY>@duplicate-race`. A job this lane enqueued has a ledger id there
        # (`~rN`), so neither shape can match one of our own rows.
        wj=$(printf '%s' "$st" | jq -r '.wait_job // ""' 2>/dev/null)
        if [ -n "$qat" ] && qep=$(date -u -d "$qat" +%s 2>/dev/null) \
           && { [ "$qep" -ge "$at_ep" ] || [ "$wj" = "$key@$qat" ] || [ "$wj" = "$key@duplicate-race" ]; }; then
          case " $seen " in *" queue:$qat "*) continue ;; esac
          res=$(cut -f9 <<<"$qrow"); res_ep="$qep"; recname="queue:$qat"
        else
          say "$p/$ck: the pool queue row for $key carries '$qat', which is either unreadable or older than this rebuild — not consumed"
        fi
      fi
    fi
    [ -n "$res" ] || continue
    out=$(br_rebuild_outcome "$res"); [ -n "$out" ] || continue
    # A REAP THAT HAS NOT LANDED IS NOT AN ENDING (BH-1770). The reaper writes
    # ABANDONED_TIMEOUT before it signals and REAPED once the lane is gone and
    # its claim released; between the two the run may still be alive. Only a
    # record on THIS box can carry REAPED, so a ledger-row answer never counts.
    case "$res" in
      "ABANDONED_TIMEOUT"*)
        if [ -z "$rec" ] || [ ! -f "$rec/REAPED" ]; then
          say "$p/$ck: the fresh rebuild was reaped but the kill has not landed yet (no REAPED on ${recname:-its record}) — not consumed this tick"
          continue
        fi ;;
    esac
    # REVIEW_BLOCKED IS NOT OURS YET. bin/review-rescue.sh re-runs the gate and
    # can rewrite this very record to PR_CREATED (review-rescue.sh:315), so
    # abandoning on sight would throw away a rescue and leave a live PR under an
    # ABANDONED ticket. The floor is the one br_from_builds already uses: the
    # marker that lane writes when it is finished, its kill flag, or 6 hours.
    if [ "$out" = rebuild-review-blocked ] \
       && ! { [ -n "$rec" ] && [ -f "$rec/.review-rescued" ]; } \
       && ! flag_on review-rescue-disabled \
       && [ $((now - res_ep)) -lt 21600 ]; then
      say "$p/$ck: the fresh rebuild is REVIEW_BLOCKED and bin/review-rescue.sh has not finished with ${recname:-it} — not consumed this tick"
      continue
    fi
    # IT LANDED. The rebuild produced a PR and the conductor owns it from here:
    # no counter, no send, and the record is remembered so this is written once
    # rather than on every tick until the new PR moves.
    if [ "$out" = rebuild-landed ]; then
      if [ "$OBSERVE" = 1 ]; then
        say "$p/$ck: WOULD record the fresh rebuild as landed ($(printf '%.80s' "$res")) — observe mode"
        continue
      fi
      br_record "$p" "$ck" rebuild-landed rebuild-landed "the fresh rebuild landed: $(printf '%.160s' "$res")"
      [ -n "$recname" ] && br_seen_rebuild "$p" "$ck" "$recname"
      # A finished build is never re-held: the wait is cleared right after the
      # rebuild-landed record above.
      [ "$OBSERVE" = 1 ] || br_set_wait "$p" "$ck" -
      say "$p/$ck: the fresh rebuild landed ($(printf '%.100s' "$res")) — the conductor owns the new PR from here"
      continue
    fi
    # The RESULT line rides on the record: the abandon quotes it, and on the
    # ledger-row path there is no directory for it to re-read.
    [ "$OBSERVE" = 1 ] || br_set_field "$p" "$ck" rebuild_result "$res"
    # A result has arrived for the held build; do not keep waiting.
    [ "$OBSERVE" = 1 ] || br_set_wait "$p" "$ck" -
    printf 'rebuild\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$p" "$ck" "$out" "${url:--}" "${rec:--}" "$key"
    n=$((n+1))
  done
}

br_candidates() {
  br_from_rebuilds; br_from_conductor; br_from_queue; br_from_builds; br_from_reviews
  # BH-4664: an external PR source, when bin/lib/br/opt/external.sh is installed.
  ! command -v br_opt_external_candidates >/dev/null 2>&1 || br_opt_external_candidates
}
