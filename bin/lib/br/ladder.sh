#!/bin/bash
# shellcheck shell=bash
# module: ladder
# bin/lib/br/ladder.sh — BH-1176: the resolver's LADDER: the classifier (a
# reason word in, a ladder class / rung / action word out) and the regenerate
# rung. Sourced by bin/blocked-resolver.sh, never run. Sourcing it defines eight
# functions and does nothing else. The seven classifier functions are pure;
# br_regen_rung (the last one) is a rung: at call time it reads and writes
# through the record layer (record.sh), merges main with the conductor's
# mc_rebase, and dispatches the driver's other rungs.
#
# BH-5241 cut the inline copies: this file is the ONLY definition of these eight
# names, and tests/br-split-layout-test.sh case 4 holds them absent from the
# driver.
# ---------------------------------------------------------------------------
# The classifier. PURE: a reason word in, an action word out, nothing read and
# nothing written. It is the one place that decides what the ladder does with a
# park, which is what makes it the thing the fixture test drives directly.
#
# An UNKNOWN reason answers `none` on purpose. A future gate that invents a new
# park must be added here deliberately; silently rebuilding on a reason nobody
# has thought about is how an agent ladder turns into a loop. Until it is added,
# that park still pages through the conductor exactly as it does today.
# ---------------------------------------------------------------------------
# br_ladder_class <reason> -> rebase-conflict|ci-red|review-blocked|orphaned-parent|prequeue-red|""
#   The three park classes that are about a BRANCH somebody can still fix. They
#   are what the rung ladder applies to; everything else (a dead pool machine, a
#   malformed plan, a BUILD_DEAD record) has no branch to fix and keeps going
#   straight to REBUILD FRESH.
#
#   `ci-red` is NON-FLAKY by construction and not by a test here: the conductor
#   forgives a red whose every failing test is a known flake (mc_flake_rerun)
#   and re-runs any other red once (mc_red_rerun) BEFORE it parks the head as
#   RED_TWICE, so a red that reaches this lane has already survived both.
#
#   `orphaned-parent` (2026-09-16) is the fourth: the PR this branch was cut
#   from CLOSED without merging, and bin/merge-conductor.sh could not simply
#   retarget the child because it still carries the dead parent's commits or it
#   conflicts with main. There IS a branch to fix — the fix is to take the dead
#   parent's commits out of it — so it belongs to the ladder rather than going
#   straight to a rebuild.
#
#   `provenance-ci-red` (BH-3630) is a provenance park the conductor saw APPROVE + CI red on; same ladder as red-ci-twice.
#
#   `stale-replan` (BH-3935) is the PR-owner age ladder's park: nobody moved the
#   PR for pr_stale.replan_days. Its only rung is bin/lib/br/opt/stale.sh's
#   re-plan; br_one stops it before the ladder when that module is off.
#   `prequeue-red` (BH-4549) is NOT ci-red: the pre-queue gate parks a head
#   whose suites fail merged onto current main, and that head is GREEN on its
#   own PR CI, so the ci-red supersede guard would decline it green-at-head.
br_ladder_class() {
  case "${1:-}" in
    conflict-unresolvable|rebase-gate-red)      echo rebase-conflict ;;
    red-ci-twice|red-twice|queue-ejected-twice|provenance-ci-red|queue-dequeued) echo ci-red ;;
    head-not-reapproved)                        echo review-blocked ;;
    orphaned-child)                             echo orphaned-parent ;;
    stale-replan)                               echo stale-replan ;;
    prequeue-red)                               echo prequeue-red ;;
    *)                                          echo "" ;;
  esac
}

# br_skips_mechanical <class> — rc 0 for the classes whose rung 1 answers
#   nothing. Rung 1 is "merge origin/main into the branch and re-run CI", which
#   is a real answer to a conflict or a stale red, and no answer at all to a
#   review finding (review-blocked: the findings are already posted) or to a
#   branch carrying an abandoned parent's commits (orphaned-parent: merging main
#   does not take them out). Both start at the fix round. So does prequeue-red:
#   the gate already ran this exact head merged onto main, so a main merge plus
#   a CI re-run answers nothing.
br_skips_mechanical() {
  case "${1:-}" in review-blocked|orphaned-parent|prequeue-red) return 0 ;; esac
  return 1
}

# br_ladder_rung <class> <mechanicals> <fixrounds> [<fixcap>]
#                                       -> mechanical|fix-round|rebuild-fresh
#   PURE, so the order is a thing the fixture drives rather than a thing the
#   reader believes. A review-blocked park skips rung 1: merging main into the
#   branch answers nothing a reviewer asked for, and the findings are already
#   posted, so its ladder is fix round then rebuild. An orphaned-parent park
#   skips it for the same shape of reason (br_skips_mechanical).
#
#   THE FIX CAP IS AN ARGUMENT (BH-579) because it is no longer one number: a
#   small conflict buys two rounds and a contested winner buys a bonus one
#   (br_fix_cap). It is passed in rather than read here so the rung CHOSEN and
#   the rung that RUNS read the same cap. Absent, it is today's single round.
br_ladder_rung() {
  local class="${1:-}" mech="${2:-0}" fix="${3:-0}" cap="${4:-${BR_MAX_FIXROUNDS:-1}}"
  case "$mech" in ''|*[!0-9]*) mech=0 ;; esac
  case "$fix"  in ''|*[!0-9]*) fix=0 ;; esac
  case "$cap"  in ''|*[!0-9]*) cap="${BR_MAX_FIXROUNDS:-1}" ;; esac
  case "$cap"  in ''|*[!0-9]*) cap=1 ;; esac
  if ! br_skips_mechanical "$class" && [ "$mech" -lt "${BR_MAX_MECHANICAL:-1}" ]; then echo mechanical; return 0; fi
  if [ "$fix" -lt "$cap" ]; then echo fix-round; return 0; fi
  echo rebuild-fresh
}

# br_regen_offered <state-json> <head> — rc 0 when this TICKET has already been
#   offered the regenerate rung on THIS head. Pure jq over the record, no file
#   I/O, so the dedup is a thing the fixture drives.
#
#   Keyed on head8 and not on the ticket alone: a regenerate that pushes moves
#   the head, CI runs, and the park that comes back is a genuinely new fact. An
#   EMPTY head is rc 1 — absent is not "already offered" (D11), and the rung
#   body refuses a park with no head of its own anyway.
br_regen_offered() {
  local st="${1:-}" head="${2:-}"
  [ -n "$head" ] || return 1
  printf '%s' "$st" | jq -e --arg h "${head:0:8}" \
    '[.attempts[]? | select((.action == "regen") or (.action == "regen-noop"))
                   | select((.detail // "") | contains("head8=" + $h))] | length > 0' \
    >/dev/null 2>&1
}

# br_eject_runs <pr-url> [<head>] — the failing batch runs the merge conductor
#   handed over for a queue-ejected-twice park (mc_eject_fix_now, BH-6000): the
#   lines of its mc_eject_runs_file after the head on line 1, and ONLY while
#   that head is the PR's head now. <head> is the caller's head; empty reads the
#   conductor row's head (mc_row_field field 4). A file for another head is
#   stale (the fix round pushed a new head, and that head's runs could not be
#   read): it is removed and answers rc 1, so neither the ladder nor the brief
#   ever acts on an older head's runs (lead review lr-6024). rc 0 printed at
#   least one run; rc 1 no file, an empty or stale one, no head to compare, or
#   no conductor lib on this box.
br_eject_runs() {
  local u="${1:-}" h="${2:-}" f out fh=""
  command -v mc_eject_runs_file >/dev/null 2>&1 || return 1
  case "$u" in https://github.com/*/*/pull/*) ;; *) return 1 ;; esac
  f=$(mc_eject_runs_file "$(mc_slug_of_url "$u")#$(mc_num_of_url "$u")")
  [ -s "$f" ] || return 1
  if [ -z "$h" ] && command -v mc_row_field >/dev/null 2>&1; then
    h=$(mc_row_field "$(mc_slug_of_url "$u")#$(mc_num_of_url "$u")" 4 2>/dev/null)
  fi
  [ "${#h}" -ge 7 ] || return 1
  { IFS= read -r fh < "$f"; } 2>/dev/null
  [ "${#fh}" -ge 7 ] || return 1
  case "$h" in "$fh"*) ;; *) case "$fh" in "$h"*) ;; *) rm -f "$f" 2>/dev/null; return 1 ;; esac ;; esac
  out=$(tail -n +2 "$f" 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# br_regen_ladder <class> <ladder-action> -> the action to DISPATCH.
#   RUNG 1b, THE REGENERATE RUNG (BH-950.2). A ci-red park whose mechanical rung
#   is spent went straight to an agent fix round, and 12 of the parks in the #950
#   census were red on a GENERATED file that was stale — a drift one more merge
#   of main answers for free. So between rung 1 and rung 2 the ci-red class gets
#   one more tokenless merge (mc_rebase, which regenerates the generated-files
#   table on the way through), and only the class that merge can help:
#   review-blocked has posted findings a merge answers nothing about,
#   orphaned-parent needs its parent's commits taken OUT, and a rebase-conflict
#   park has already had exactly this merge refused at rung 1.
#
#   BR_REGEN_RUNG=0 prints the ladder's own answer, so the dispatch is the
#   pre-BH-950 one to the letter.
br_regen_ladder() {
  local class="${1:-}" action="${2:-}"
  if [ "${BR_REGEN_RUNG:-1}" != 0 ] && [ "$class" = ci-red ]; then
    case "$action" in fix-round|rebuild-fresh) printf 'regen'; return 0 ;; esac
  fi
  printf '%s' "$action"
}

br_action() { # br_action <reason> -> ladder|rebuild-fresh|adjudicate|re-review|none
  # The ladder owns the branch classes unless it is switched off, in which case
  # every reason answers exactly what it answered before it shipped.
  if [ "${BR_LADDER:-1}" != 0 ] && [ -n "$(br_ladder_class "${1:-}")" ]; then echo ladder; return 0; fi
  case "${1:-}" in
    head-not-reapproved|orphaned-child)     echo fix-round ;;
    # THE REVIEW LANE'S OWN VERDICT (BH-872). Deliberately NOT a ladder class:
    # rung 1 (merge main / re-run CI) answers nothing a reviewer asked for, and
    # rung 3 (close the PR and rebuild the ticket) is not the answer to a review
    # finding on a PR that may have no ticket at all. Fix round, then ABANDONED.
    review-changes-requested)               echo fix-round ;;
    iron-law|test-tamper|rescue-real-deletion) echo adjudicate ;;
    no-verdict)                             echo re-review ;;
    # The rebuild this lane started has ENDED. A dead machine is worth another
    # rebuild; a planner that could not decompose the ticket, a plan that
    # stopped on an open question and a review that refused the diff are all
    # TICKET-level stops, and a second rebuild ends exactly the same way.
    rebuild-build-dead)                     echo rebuild-fresh ;;
    rebuild-decompose-failed|rebuild-plan-blocked|rebuild-review-blocked) echo abandon-rebuild ;;
    # THE ENQUEUE ITSELF DID NOT LAND (BH-488). Not a ticket-level stop and not
    # a new rung: the PR is already closed and the record already marked, so the
    # only thing owed is the enqueue, tried again.
    rebuild-enqueue-failed)                 echo rebuild-retry ;;
    conflict-unresolvable|rebase-gate-red|queue-ejected-twice|merge-failed-twice|\
    queue-enqueue-failed-twice|red-ci-twice|red-twice|provenance-ci-red|reproduction-gate|intent-gate|\
    pool-died-twice|pool-deferred-max|rescue-giving-up|plan-malformed|plan-blocked|\
    build-dead|pr-create-failed)            echo rebuild-fresh ;;
    # BH-1770 (the operator, 2026-09-24): bin/lane-reaper.sh killed this run past its
    # per-lane deadline, and THIS lane owns the relaunch, never the sweep. There
    # is no branch to fix — the run never finished — so it is a fresh build on
    # the capped ladder, and ABANDONED with one alert when that is spent.
    abandoned-timeout)                      echo rebuild-fresh ;;
    *)                                      echo none ;;
  esac
}

# br_reason_of <raw-reason-string> -> the normalized word br_action understands.
# The raw strings are whatever the parking lane wrote, and they carry detail
# ("conflict-unresolvable: CONFLICT (content): Merge conflict in x.ts"). Matched
# on the PREFIX, so the detail rides along in the log without confusing this.
br_reason_of() {
  case "${1:-}" in
    conflict-unresolvable*)      echo conflict-unresolvable ;;
    rebase-gate-red*)            echo rebase-gate-red ;;
    queue-ejected-twice*)        echo queue-ejected-twice ;;
    merge-failed-twice*)         echo merge-failed-twice ;;
    queue-enqueue-failed-twice*) echo queue-enqueue-failed-twice ;;
    no-verdict*)                 echo no-verdict ;;
    head-not-reapproved*)        echo head-not-reapproved ;;
    red-ci-twice*)               echo red-ci-twice ;;
    # RED_TWICE (2026-09-15): the conductor re-ran this head's failed jobs once
    # and CI came back red on the SAME head. Same answer as its cross-head
    # sibling above — a branch whose own CI will not go green is rebuilt fresh
    # against current main; the fix round needs posted review findings and a red
    # CI run has none, so br_fix_round would only fall through to this anyway.
    red-twice*)                  echo red-twice ;;
    # 2026-09-16: the raw reason carries the dead base branch and the parent's
    # PR url, and the fix round reads both out of it — so it is matched on the
    # prefix like every other reason here and the detail rides along.
    orphaned-child*)             echo orphaned-child ;;
    # BH-3935: bin/lib/pr-owner/stale.sh's rung 2 writes it, with the age in
    # the detail ("stale-replan: no head or verdict change for 5d").
    stale-replan*)               echo stale-replan ;;
    # BH-872: the raw reason carries the PR and the head it was read at, so it
    # is matched on the prefix like every other reason and the detail rides
    # along into the log.
    review-changes-requested*)   echo review-changes-requested ;;
    # BH-614: the build was approved and its branch pushed, and the create
    # opened nothing (bin/run-build.sh's ratchet refused the url-less claim, or
    # bin/fly-pool.sh's reap rewrote a legacy line RESULT_MALFORMED). There is no
    # PR to read and no finding to fix, so no rung of the ladder applies — only a
    # fresh build against current main answers it.
    pr-create-failed*)           echo pr-create-failed ;;
    # BH-1770: a run bin/lane-reaper.sh killed past its deadline (REAPED on the
    # record). br_from_builds writes it; the relaunch is this lane's.
    abandoned-timeout*)          echo abandoned-timeout ;;
    iron-law*)                   echo iron-law ;;
    # A REBUILD'S OWN OUTCOME (2026-09-16, project-5 #1645). These four are
    # written by br_from_rebuilds and by nothing else: they mean the fresh build
    # THIS lane enqueued has finished, and they are deliberately distinct from
    # their bare siblings. `build-dead` is a record nobody has acted on yet;
    # `rebuild-build-dead` is our own rebuild dying, which spends the next
    # counter without re-closing a PR that rung 3 already closed.
    rebuild-build-dead*)         echo rebuild-build-dead ;;
    rebuild-decompose-failed*)   echo rebuild-decompose-failed ;;
    rebuild-plan-blocked*)       echo rebuild-plan-blocked ;;
    rebuild-review-blocked*)     echo rebuild-review-blocked ;;
    rebuild-enqueue-failed*)     echo rebuild-enqueue-failed ;;
    # BH-3630: a `provenance` park the conductor saw verdict=APPROVE + ci=red
    # on. The conductor's row only ever says `provenance`; br_from_conductor
    # writes this word after reading the conductor's own detail for the head
    # (br_prov_promote), so a bare `provenance` still answers "" below.
    provenance-ci-red*)          echo provenance-ci-red ;;
    # BH-4549: the pre-queue gate's park, `prequeue-red: <suites> on main <m12>
    # — …` (tracer) or `prequeue-red: <suites> (reproduced alone on <base12>,
    # batch #n)` (batch-solo). The fix round re-reads the suites and the sha.
    prequeue-red*)               echo prequeue-red ;;
    # A LOSER OF A CONTESTED PATH IS NOT THE LADDER'S (BH-579). Another ticket
    # won the path this PR conflicts on and holds it; this lane answers the hold
    # itself (br_one's loser skip) and the conductor gets the row back when the
    # hold is released. An empty answer is what keeps the row out of
    # br_from_conductor entirely, so no rung is ever offered to a loser.
    contested*)                  echo "" ;;
    *)                           echo "" ;;
  esac
}

# RUNG 1b: REGENERATE (BH-950.2). One more merge of origin/main into the branch,
# and nothing else. No model, no tokens.
#
# WHY IT IS ITS OWN RUNG. Rung 1 merges main once, and the commonest red CI in
# this repo is a GENERATED file that main has since moved: the generated-files
# table is rebuilt by the merge itself (mc_regen_table, bin/lib/merge-conductor-lib.sh),
# so a park sitting on that drift is one free merge from green. 12 of the open
# PRs in the #950 census were parked there, and each of them was about to buy an
# agent fix round to do what a merge does for nothing.
#
# AND IT IS BOUNDED, twice: br_regen_offered refuses a head this ticket has
# already been offered the rung on, and `regens` refuses a ticket that has spent
# BR_MAX_REGEN of them however far main has moved since. A regenerate that
# landed nothing DOES NOT DELAY THE PARK — the displaced ladder answer (the fix
# round, or the rebuild when the fix round is spent) is dispatched in the SAME
# tick, so this rung can only ever cost a merge.
br_regen_rung() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6" next="${7:-fix-round}"
  local ck st n slug br head out rc ref ckey rvw mark=0 why=""
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  st=$(br_load "$p" "$ck")
  # The displaced answer, dispatched by name. Everything below that cannot take
  # the rung comes through here, so "the park moved this tick" is one path.
  br_regen_next() {
    case "$next" in
      rebuild-fresh) br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
      *)             br_fix_round     "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    esac
  }
  # OBSERVE BEFORE THE PR READ, the way br_mechanical does it: a dry run costs
  # this lane no GitHub call at all. The head8 dedup and the bound are read from
  # the PR below, so the sentence names the condition rather than claiming the
  # rung would certainly be taken.
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD take the regenerate rung unless it was already offered on this head or the ticket has spent BR_MAX_REGEN=$MAX_REGEN (merge origin/main into the PR branch, which regenerates the generated files once #969 lands) and then $next — observe mode"
    return 0
  fi
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  [ -n "$slug" ] || slug=$(br_slug_of_url "$url") || slug=""
  br=""; head=""
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    ref=$(br_pr_ref "$url" "$slug"); rc=$?
    # rc 2 IS "GITHUB DID NOT ANSWER" (see br_pr_ref): no rung spent, no state
    # written, the park is re-offered next tick — exactly as rung 1 treats it.
    if [ "$rc" = 2 ]; then
      say "$p/$rkey [$reason]: PR read FAILED (${ref:-no detail}) — retrying next tick, no rung spent"
      return 0
    fi
    [ "$rc" = 0 ] && read -r slug br head <<<"$ref"
    # The head this rung read is the head this lane now knows the PR on (BH-1642).
    [ "$rc" = 0 ] && br_sup_seen "$p" "$ck" "$url" "$head"
    [ -n "${slug:-}" ] && br_use_token "$slug"
  fi
  if [ -z "$slug" ] || [ -z "${br:-}" ] || [ -z "${head:-}" ]; then
    say "$p/$rkey [$reason]: no branch/head for ${url:--} even after re-reading it under ${slug:-no repo}'s own token — nothing to regenerate, $next"
    br_regen_next; return 0
  fi
  if br_regen_offered "$st" "$head"; then
    say "$p/$rkey [$reason]: the regenerate rung was already offered on ${head:0:8} — $next"
    br_regen_next; return 0
  fi
  # AND THE PER-TICKET BOUND ON LANDED REGENERATES, read after the head so the
  # more precise sentence (this exact head) is the one a park on an unchanged
  # head gets. main keeps moving, so the head8 dedup above would let a ticket
  # LAND a regenerate per new head for ever; this is what ends that. It does not
  # bound mc_rebase calls — the dedup does, at one per distinct head.
  n=$(br_num "$st" regens)
  if [ "$n" -ge "$MAX_REGEN" ]; then
    say "$p/$rkey [$reason]: the regenerate rung has already run $n time(s) (BR_MAX_REGEN=$MAX_REGEN) — $next"
    br_regen_next; return 0
  fi
  br_event resolver_rung "$p" "$ck" "$reason" "rung 1b regenerate: mc_rebase on $br at ${head:0:8}"
  [ -f "${MC_LOG:-}" ] && mark=$(wc -l < "$MC_LOG" | tr -d ' ')   # BH-8003: this call's own log lines
  out=$(mc_rebase "$slug" "$p" "$br" "$head" "$url"); rc=$?
  # Same as rung 1: the setup alert is cleared the moment the rung RAN. rc 4 is
  # the setup arm below and must not clear it.
  case "$rc" in 0|1|2|3|5|6) rm -f "$ST/$p/$ck.setup-alerted" 2>/dev/null ;; esac
  case "$rc" in
    0|5)
      if [ -n "$out" ] && [ "$out" != "$head" ]; then
        br_record "$p" "$ck" regen "$reason" "regenerated $br: pushed ${out:0:8} over head8=${head:0:8} (mc_rebase rc=$rc)" regens
        say "$p/$rkey [$reason]: REGENERATE — pushed ${out:0:8} over ${head:0:8}; CI runs on the new head and the conductor judges it"
        return 0
      fi
      # Nothing landed, so nothing was regenerated. Recorded against the head so
      # this park is never offered the rung on it again, the counter is NOT spent
      # (no merge happened), and the ladder's own answer runs now.
      br_record "$p" "$ck" regen-noop "$reason" "mc_rebase rc=$rc left head8=${head:0:8} in place — $next now"
      say "$p/$rkey [$reason]: the regenerate rung had nothing to merge into $br at ${head:0:8} — $next"
      br_regen_next; return 0 ;;
    1|2)
      # A conflict, or a merged tree the hub's gate refuses: nothing regenerated
      # landed, and both are exactly what the fix round exists for. Same tick.
      br_record "$p" "$ck" regen-noop "$reason" "mc_rebase rc=$rc left head8=${head:0:8} in place — $next now"
      say "$p/$rkey [$reason]: the regenerate rung could not land (mc_rebase rc=$rc) — $next"
      br_regen_next; return 0 ;;
    3|7)
      # The head moved under the lease, or the pool queue refused it. Nothing is
      # spent and nothing is said twice — the next tick reads the new head.
      say "$p/$rkey [$reason]: the regenerate rung's lease was rejected or the pool queue was unreachable (mc_rebase rc=$rc) — no rung spent, retried next tick"
      return 0 ;;
    6)
      # The pool took it: a queue row exists and a machine is rebasing this
      # branch, so the rung RAN, and the conductor row leaves the park the same
      # way rung 1's rc-6 arm leaves it.
      ckey="$(mc_slug_of_url "$url")#$(mc_num_of_url "$url")"; rvw=$(mc_row_field "$ckey" 5)
      br_record "$p" "$ck" regen "$reason" \
        "queued a pool rebase of $br at head8=${head:0:8} ($(mc_pool_rebase_key "$(mc_num_of_url "$url")" "$head")); the conductor reads the pool's result" regens
      mc_transition "$ckey" REBASING "pool rebase queued by the resolver's regenerate rung" "$head" "${rvw:--}" "$url" "-" "-" "${rec:--}" >/dev/null
      say "$p/$rkey [$reason]: REGENERATE — pool rebase queued for ${head:0:8}; the row leaves the park and the conductor reads the result"
      return 0 ;;
    *)
      # SETUP FAILED (rc 4 and any rc mc_rebase does not document): a fact about
      # this box, not an event about the PR. It spends nothing, cascades into
      # nothing — the fix round wants the same clone and the same credential —
      # and pages once per episode (br_setup_blocked). The alert names the
      # reason mc_rebase logged in this call, or says it logged none (BH-8003).
      command -v mc_rebase_reason >/dev/null 2>&1 && why=$(mc_rebase_reason "$url" "$mark")
      if [ -n "$why" ]; then br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "mc_rebase rc=$rc on $slug — $why (merge-conductor.log)" regen "the cause in that merge-conductor.log line fixed"
      else br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "mc_rebase rc=$rc on $slug — a setup failure that logged no reason (credential, clone or fetch); see merge-conductor.log" regen; fi
      return 0 ;;
  esac
}
