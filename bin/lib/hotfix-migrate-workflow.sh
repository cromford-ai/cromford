#!/bin/bash
# bin/lib/hotfix-migrate-workflow.sh: the WORKFLOW shape of the hotfix go-live
# stage (BH-370.3). Sourced by bin/hotfix-migrate.sh, never executed; it defines
# hm_workflow, which that stage calls when the mode resolves to `workflow`.
#
# WHY IT EXISTS. Four projects expose /api/internal/migrations and the endpoint
# shape applies their SQL through the app itself. The rest do not: their schema
# moves through a dispatchable GitHub Actions workflow that holds the database
# credential, and this box holds none. So here the stage's job is to DISPATCH
# that workflow, watch the run it started, and post the same proof comment the
# endpoint shape posts. A dispatch is a production write we cannot take back,
# which is why every refusal below happens BEFORE `gh workflow run`:
#
#   * checks not green            -> hold, nothing dispatched
#   * a needs-quiet answer that is neither `yes` nor `no` (or a nonzero exit)
#                                -> hold. An unreadable answer is never a `no`.
#   * a file needs a quiet window and no probe is configured -> hold
#   * the probe never printed exactly `0` inside the window  -> hold
#     (`00`, `0 scans`, ` 0`, an empty line and a nonzero exit are NOT zero)
#   * this fingerprint already has a run     -> watch that run, do not dispatch
#     a second one. An `applied` ledger returns straight away.
#
# And after the dispatch, honesty about what the run did: `applied` is written
# only when `gh run watch --exit-status` returned 0. Our own watch deadline
# (rc 124) records the run's real in-flight word plus its id, so a re-run
# RE-ATTACHES instead of dispatching again; any other nonzero records the
# conclusion GitHub reported. No blanket catch ever says applied.
#
# KNOBS (env/<project>.env, sourced by hm_main; every default documented here):
#   HOTFIX_MIGRATE_WORKFLOW     migrate-manual.yml   the workflow file to run
#   HOTFIX_WORKFLOW_FILES_INPUT files                the -f input carrying the
#                               file list (set it EMPTY to pass no -f at all;
#                               unset means `files`)
#   HOTFIX_WORKFLOW_FILES_SEP   ,                    what joins that list. The
#                               workflow's own parser owns this: project-5's
#                               migrate-manual.yml declares `file`, not `files`.
#   HOTFIX_WORKFLOW_MAX_FILES   (unset = no cap)     how many files that input
#                               can carry. More than this HOLDS before the
#                               dispatch rather than handing the run a token it
#                               cannot parse.
#   HOTFIX_NEEDS_QUIET_CMD      node scripts/migration-sql.mjs --needs-quiet
#                               run in $WT with the migration file appended as
#                               its last argument; must print `yes` or `no`
#   HOTFIX_QUIET_PROBE_CMD      (unset)              run in $WT, must print the
#                               number of active writers; `0` opens the window
# Both of those knobs are a COMMAND AND ITS ARGUMENTS, word-split once and then
# run as argv — never a shell line. The migration path is appended as a separate
# argument, so no filename is ever shell source (a pipeline or a redirect in one
# of these knobs belongs in a wrapper script the knob names).
#   HOTFIX_QUIET_MAX_WAIT       900   seconds to wait for that `0`
#   HOTFIX_QUIET_POLL           30    seconds between probes
#   HOTFIX_RUN_WAIT             1800  seconds to watch the run
#   HOTFIX_RUN_LOCATE_WAIT      60    seconds to find the run we dispatched
# A non-integer value falls back to the default (same shape as HOTFIX_CI_WAIT).
#
# THE SETTINGS ROW hotfix_migrate.conf.<project> (BH-9403, bin/lib/hotfix-migrate-
# knobs.sh) beats the env knobs above and adds these, all off by default:
#   HMK_DISPATCH_REF  the --ref of the dispatch (default the PR branch). project-6
#                     dispatches from `main`, because its production-db
#                     environment only admits main.
#   HMK_BRANCH_INPUT  the -f input that carries the PR branch (default none)
#   HMK_FILE_FORM     basename sends `x.sql`, path (default) sends the repo path
#   HMK_PER_FILE      1 = one dispatch per file, in file-name order, stop at the
#                     first file that does not come back applied (hm_wf_per_file)
#   HMK_APPROVE_HEAD  1 = post an APPROVED review pinned to the reviewed sha before
#                     the first dispatch (hm_wf_approve_head). Needs
#                     HM_VERDICT=APPROVE and HM_REVIEWED_SHA = the live head.
#   HMK_NEEDS_QUIET   off = no needs-quiet command and no probe: the apply
#                     workflow serialises its own applies
#   HMK_GATE_CHECKS / HMK_GATE_WORKFLOWS  the PR's migration-ledger gate checks.
#                     They stay red until the SQL is applied, so the checks wait
#                     ignores them (hm_wait_checks_except in the stage).
#   HMK_LOG_CAP_KB    2048  how much of the run log the outcome classifier reads
#   HMK_REQUIRE_WORD  1 = in per-file mode a green run with no word about OUR
#                     file is `failed`, never `applied` (project-6-os: its
#                     workflow always writes one)
#   HOTFIX_DISPATCH_LOCK_WAIT  120  the wait for the per-(repo, workflow, ref)
#                     dispatch lock (row key dispatch_lock_s)
#
# RUN BINDING (BH-9403 refute review). Many PRs dispatch one workflow on one ref
# (`main`). hm_wf_send holds a lock per (repo, workflow, ref) from the dispatch
# to the locate, and hm_wf_locate refuses a run that was listed before the
# dispatch. Two or more new runs = we cannot tell which one is ours: hold, one
# alert, no run watched.
#
# OUTCOME WORDS (per-file mode, hm_wf_outcome over the run log): applied,
# already-applied, refused, inert, failed, and success-unworded (a green run that
# printed no word about our file: applied, or `failed` when HMK_REQUIRE_WORD=1). refused, inert and failed are
# TERMINAL for this fingerprint: a re-run never dispatches that file again.
# refused raises one alert per (project, PR, fingerprint); inert one per project
# per UTC day (the day is in the alert id; no state/ file).
#
# FROM THE STAGE it uses: hm_wait_checks, hm_body_head, hm_revert_lines,
# hm_hold, hm_finish (-> hm_write_ledger + hm_post_proof); and the globals
# PROJECT BUILD SLUG PR_URL BRANCH WT FP FILES LEDGER MODE.
#
# FILES IT WRITES under $BUILD: hotfix-dispatch.txt (the dispatch output),
# hotfix-quiet.err (needs-quiet and probe read errors), hotfix-run-watch.txt,
# hotfix-run-log.txt (the last 60 lines of the run log, capped at 8000 bytes so
# 60 long lines cannot push the proof past GitHub's 65536-char comment limit and
# turn a real apply into `applied` with no comment id).
#
# THE IDENTITY IT RUNS ON. One fleet PAT is one 5000/h REST bucket for every lane
# on every box and one credential whose leak is fleet-wide (#425), so this lane
# arms a short-lived, repo-scoped App token for $SLUG before its first gh call
# and puts the caller's own token back when it returns. A box that mints none
# gets rc 1 from gh_auth_for, with no fork and no new failure mode, and the lane
# runs on exactly the identity it was handed.
#
# EXIT CODES (hm_workflow's return, which hm_main passes through): 0 applied,
# 3 hold — including a green run whose proof comment would not post.

# hm_wf_int <value> <default>: an env knob is an integer or it is the default.
hm_wf_int() {
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# hm_wf_rtrim <string>: drop trailing whitespace only. Leading whitespace is
# deliberately KEPT: " 0" is not the answer `0`, and trimming it would turn a
# malformed probe answer into an open quiet window.
hm_wf_rtrim() {
  local s="$1"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# hm_wf_files_json <status> [run_id]: the ledger's files[] array, decorated with
# the run id when we have one (hm_write_ledger passes a decorated array through).
hm_wf_files_json() {
  printf '%s\n' "${FILES[@]}" \
    | jq -R -s --arg s "$1" --arg r "${2:-}" \
      'split("\n") | map(select(length > 0))
       | map({path:., status:$s} + (if $r == "" then {} else {run_id:$r} end))'
}

# hm_wf_body <headline> <note> [attach-file]: the proof body, in the shape
# BH-370.2's merge gate and the endpoint shape both read — headline, the files,
# the run (when there is one), the quiet-window decision PER FILE, the run log
# tail, then the revert lines.
hm_wf_body() {
  local headline="$1" note="$2" attach="${3:-}" i
  printf '%s\n\n' "$headline"
  hm_body_head
  [ -n "$note" ] && printf '%s\n\n' "$note"
  [ -n "${HM_GATE_NOTE:-}" ] && printf '%s\n\n' "$HM_GATE_NOTE"
  [ -n "$RUN_URL" ] && printf 'Workflow run: %s (%s)\n\n' "$RUN_URL" "$WORD"
  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do
    printf -- '- %s: quiet window: %s\n' "${FILES[$i]}" "${QL[$i]}"
    i=$((i+1))
  done
  printf '\n'
  if [ "${HM_PF:-0}" = 1 ]; then
    # Per-file mode: each file has its own run and its own word.
    i=0
    while [ "$i" -lt "${#FILES[@]}" ]; do
      if [ -n "${FRUN[$i]:-}" ]; then
        printf -- '- %s: %s (run https://github.com/%s/actions/runs/%s)\n' "${FILES[$i]}" "${FST[$i]:-not-dispatched}" "$SLUG" "${FRUN[$i]}"
      else
        printf -- '- %s: %s\n' "${FILES[$i]}" "${FST[$i]:-not-dispatched}"
      fi
      i=$((i+1))
    done
    printf '\n'
    [ -n "${HM_WF_REASON:-}" ] && printf 'The workflow said: %s\n\n' "$HM_WF_REASON"
  fi
  if [ -n "$RUN_ID" ]; then
    if [ "${HM_PF:-0}" != 1 ]; then
      i=0
      while [ "$i" -lt "${#FILES[@]}" ]; do
        printf -- '- %s: %s (run %s)\n' "${FILES[$i]}" "$FSTAT" "$RUN_ID"
        i=$((i+1))
      done
      printf '\n'
    fi
    if [ -s "$BUILD/hotfix-run-log.txt" ]; then
      printf 'Run log (last 60 lines), capped at 8 KB:\n\n```\n%s\n```\n\n' "$(cat "$BUILD/hotfix-run-log.txt")"
    else
      printf 'Run log (last 60 lines): we could not read it. That says nothing about the run itself, so it did not change the decision above.\n\n'
    fi
  fi
  if [ -n "$attach" ] && [ -s "$attach" ]; then
    printf 'What we read:\n\n```\n%s\n```\n\n' "$(tail -n 20 "$attach" | head -c 1500)"
  fi
  hm_revert_lines "${FILES[@]}"
}

# hm_wf_stop <decision> <headline> <note> <file-status> <code> [attach-file]:
# ledger, then proof, then the ledger again with the comment id — hm_finish owns
# that order, and owns rc 3 when the comment would not post.
hm_wf_stop() {
  local decision="$1" headline="$2" note="$3" fstat="$4" code="$5" attach="${6:-}"
  local body rc
  local fj
  body=$(mktemp)
  hm_wf_body "$headline" "$note" "$attach" > "$body"
  if [ "${HM_PF:-0}" = 1 ]; then fj=$(hm_wf_pf_json); else fj=$(hm_wf_files_json "$fstat" "$RUN_ID"); fi
  hm_finish "$decision" "$body" "$fj" "$code"
  rc=$?; rm -f "$body"; return "$rc"
}

# hm_wf_pf_json: the per-file ledger array of per-file mode, from the caller's
# FST (status) and FRUN (run id) arrays, index for index with FILES. A file the
# loop never reached is `not-dispatched`.
hm_wf_pf_json() {
  local i out='[]'
  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do
    out=$(jq -c --arg p "${FILES[$i]}" --arg s "${FST[$i]:-not-dispatched}" --arg r "${FRUN[$i]:-}" \
      '. + [{path:$p, status:$s} + (if $r == "" then {} else {run_id:$r} end)]' <<<"$out")
    i=$((i+1))
  done
  printf '%s\n' "$out"
}

# hm_wf_pf_ledger: write the per-file ledger NOW, between files. tmp then mv, so
# a crash after file 1 re-attaches or skips it and never dispatches it again.
hm_wf_pf_ledger() {
  hm_write_ledger in-progress "$(hm_wf_pf_json)"
}

# hm_wf_ere <string>: the string with every ERE metacharacter escaped.
hm_wf_ere() {
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'
}

# hm_wf_outcome <run-log-file> <watch-rc> <token> [<token>...]: ONE word for
# what the run did to the file the tokens name (the dispatched form and the
# repo path). Reads the whole capped log. HM_WF_REASON gets the refusal line.
#   refused          a `refused: ` line, and the run did not finish green
#   inert            the `migrate-branch is inert` notice on a green run
#   already-applied  `already-applied: <token>` on a green run
#   applied          `applied: <token>` (no `already-` before it) on a green run
#   failed           a run that did not finish green and said no refusal
#   success-unworded a green run with none of the words about our file
#                    (hm_wf_per_file: applied, or failed when HMK_REQUIRE_WORD=1)
#   in-flight        watch rc 124: our own deadline, the run is still going
# A word about ANOTHER file does not count, and a success word beside a failed
# run is `failed`.
hm_wf_outcome() {
  local log="$1" wrc="$2" alt="" t
  shift 2
  HM_WF_REASON=""
  for t in "$@"; do [ -n "$t" ] && alt="${alt:+$alt|}$(hm_wf_ere "$t")"; done
  [ -n "$alt" ] || alt='\x00'
  if [ "$wrc" = 124 ]; then echo in-flight; return 0; fi
  if [ "$wrc" != 0 ]; then
    HM_WF_REASON=$(grep -m1 -E '(^|[[:space:]])refused: ' "$log" 2>/dev/null | sed -E 's/.*(^|[[:space:]])(refused: )/\2/' | cut -c1-300)
    if [ -n "$HM_WF_REASON" ]; then echo refused; else echo failed; fi
    return 0
  fi
  if grep -q 'migrate-branch is inert' "$log" 2>/dev/null; then echo inert; return 0; fi
  if grep -qE "(^|[[:space:]])already-applied: ($alt)([[:space:]]|$)" "$log" 2>/dev/null; then echo already-applied; return 0; fi
  if grep -qE "(^|[[:space:]])applied: ($alt)([[:space:]]|$)" "$log" 2>/dev/null; then echo applied; return 0; fi
  echo success-unworded
}

# hm_wf_pr_num: the PR number out of PR_URL, or nothing.
hm_wf_pr_num() {
  sed -nE 's#.*/pull/([0-9]+).*#\1#p' <<<"$PR_URL" | head -n1
}

# hm_wf_approve_head: post an APPROVED review pinned to the reviewed sha, so the
# workflow's verify job (no approval on the head = refused) lets the apply run.
# rc 0 = the head carries an approval now (posted, or one was already there).
# rc 1 = nothing posted and nothing may be dispatched; HM_WF_APPROVE_WHY says why.
# It posts ONLY when the harness verdict is APPROVE and the PR's live head is the
# sha that verdict judged. A head that moved, a head nobody could read, a BLOCK,
# an empty or malformed sha: no approval.
hm_wf_approve_head() {
  local n head have body err rc
  HM_WF_APPROVE_WHY=""
  n=$(hm_wf_pr_num)
  if [ "${HM_VERDICT:-}" != APPROVE ]; then
    HM_WF_APPROVE_WHY="the harness verdict for this head is '${HM_VERDICT:-none}', not APPROVE. No approval posted, nothing dispatched."
    return 1
  fi
  if ! grep -qxE '[0-9a-f]{40}' <<<"${HM_REVIEWED_SHA:-}"; then
    HM_WF_APPROVE_WHY="no reviewed head sha was handed to the stage. No approval posted, nothing dispatched."
    return 1
  fi
  case "${n:-}" in ''|*[!0-9]*) HM_WF_APPROVE_WHY="no PR number in '$PR_URL'. No approval posted, nothing dispatched."; return 1 ;; esac
  head=$(gh api "repos/$SLUG/pulls/$n" -q .head.sha 2>>"$BUILD/hotfix-gh.err")
  head=$(hm_wf_rtrim "${head:-}")
  if [ -z "$head" ]; then
    HM_WF_APPROVE_WHY="we could not read the PR's live head. No approval posted, nothing dispatched."
    return 1
  fi
  if [ "$head" != "$HM_REVIEWED_SHA" ]; then
    HM_WF_APPROVE_WHY="the head moved after the review (reviewed ${HM_REVIEWED_SHA:0:12}, live ${head:0:12}). No approval posted, nothing dispatched."
    return 1
  fi
  have=$(gh api --paginate "repos/$SLUG/pulls/$n/reviews?per_page=100" \
           -q ".[] | select(.state == \"APPROVED\" and .commit_id == \"$head\") | .id" 2>>"$BUILD/hotfix-gh.err")
  [ -n "$(hm_wf_rtrim "${have:-}")" ] && return 0
  body="The harness review verdict for ${head} is APPROVE. This approval lets the migration workflow apply this PR's add-only SQL before the merge."
  err="$BUILD/hotfix-approve.err"
  gh api -X POST "repos/$SLUG/pulls/$n/reviews" -f "commit_id=$head" -f event=APPROVE -f "body=$body" \
    > /dev/null 2> "$err"
  rc=$?
  if [ "$rc" != 0 ] && grep -qi 'own pull request' "$err" 2>/dev/null; then
    # The App that opened the PR may not approve it. The default credential may,
    # the same rule bin/review-prs.sh applies (rp_author_is_reviewer_app).
    if command -v gh_auth_reset >/dev/null 2>&1; then gh_auth_reset; fi
    gh api -X POST "repos/$SLUG/pulls/$n/reviews" -f "commit_id=$head" -f event=APPROVE -f "body=$body" \
      > /dev/null 2>> "$err"
    rc=$?
    if command -v gh_auth_for >/dev/null 2>&1; then gh_auth_for "$SLUG" || true; fi
  fi
  if [ "$rc" != 0 ]; then
    HM_WF_APPROVE_WHY="the approval did not post (gh exit $rc: $(tr '\n' ' ' < "$err" | cut -c1-200)). Nothing dispatched."
    return 1
  fi
  return 0
}

# hm_wf_head_bound: a before-merge dispatch (HM_BEFORE_MERGE=1) runs only while
# the PR's LIVE head is the sha the APPROVE verdict judged. hm_wf_send calls it
# under the dispatch lock, right before EVERY dispatch (each file in per-file
# mode), whatever approve_head says: project-5 dispatches with --ref <PR branch>,
# so a push after the review would otherwise be applied unreviewed (BH-9403
# refute review). A hotfix (HM_BEFORE_MERGE unset or 0) is not checked here.
# rc 0 = dispatch; rc 1 = do not, HM_WF_HEAD_WHY says why.
hm_wf_head_bound() {
  local n head
  HM_WF_HEAD_WHY=""
  [ "${HM_BEFORE_MERGE:-0}" = 1 ] || return 0
  if [ "${HM_VERDICT:-}" != APPROVE ]; then
    HM_WF_HEAD_WHY="the harness verdict for this head is '${HM_VERDICT:-none}', not APPROVE. Nothing dispatched."
    return 1
  fi
  if ! grep -qxE '[0-9a-f]{40}' <<<"${HM_REVIEWED_SHA:-}"; then
    HM_WF_HEAD_WHY="no reviewed head sha was handed to the stage. Nothing dispatched."
    return 1
  fi
  n=$(hm_wf_pr_num)
  case "${n:-}" in ''|*[!0-9]*) HM_WF_HEAD_WHY="no PR number in '$PR_URL'. Nothing dispatched."; return 1 ;; esac
  head=$(gh api "repos/$SLUG/pulls/$n" -q .head.sha 2>>"$BUILD/hotfix-gh.err")
  head=$(hm_wf_rtrim "${head:-}")
  if [ -z "$head" ]; then
    HM_WF_HEAD_WHY="we could not read the PR's live head just before the dispatch. Nothing dispatched."
    return 1
  fi
  if [ "$head" != "$HM_REVIEWED_SHA" ]; then
    HM_WF_HEAD_WHY="the head moved after the review (reviewed ${HM_REVIEWED_SHA:0:12}, live ${head:0:12}). Nothing dispatched."
    return 1
  fi
  return 0
}

# hm_wf_pre_stop <headline> <note> <file-status> [attach]: a stop BEFORE any
# dispatch, for a cause a later run can clear (checks not green yet, the quiet
# window, the dispatch lock, a failed dispatch call, the approval POST, a moved or
# unreadable head). A hotfix writes `hold`, as before. A before-merge PR writes
# `retry`: the conductor does NOT park a `retry` proof as BLOCKED_HUMAN
# (mc_hotfix_proof reads it as stale), so the PR takes the ordinary path
# (mmh_decide / HELD_MIGRATION) and needs no person (BH-9403 refute review).
# Terminal outcomes (refused, inert, failed, a run we cannot bind) stay `hold`.
hm_wf_pre_stop() {
  local d=hold
  [ "${HM_BEFORE_MERGE:-0}" = 1 ] && d=retry
  hm_wf_stop "$d" "$1" "$2" "$3" 3 "${4:-}"
}

# hm_wf_checks: the PR's checks before a dispatch. With a migration-ledger gate
# configured (HMK_GATE_CHECKS / HMK_GATE_WORKFLOWS) the gate itself is ignored:
# it is red BECAUSE the SQL is not applied yet, and waiting on it would never end.
hm_wf_checks() {
  if { [ -n "${HMK_GATE_CHECKS:-}" ] || [ -n "${HMK_GATE_WORKFLOWS:-}" ]; } \
     && declare -F hm_wait_checks_except >/dev/null 2>&1; then
    hm_wait_checks_except
  else
    hm_wait_checks
  fi
}

# hm_wf_quiet <index>...: steps 3 and 4 for the files at these indexes of FILES.
# rc 0 = go on to the dispatch. Any other rc = the stop is already written (the
# proof and the ledger), and the caller returns that rc.
hm_wf_quiet() {
  local i f out rc
  local -a NEEDY=() NEEDYI=()
  if [ "${HMK_NEEDS_QUIET:-}" = off ]; then
    for i in "$@"; do QL[i]="not needed (needs_quiet=off: the apply workflow serialises its own applies)"; done
    return 0
  fi
  for i in "$@"; do
    f="${FILES[$i]}"
    out=$(cd "$WT" && "${NQA[@]}" "$f" 2>>"$BUILD/hotfix-quiet.err"); rc=$?
    out=$(hm_wf_rtrim "$out")
    if [ "$rc" = 0 ] && [ "$out" = yes ]; then
      NEEDY+=("$f"); NEEDYI+=("$i"); QL[i]="waiting"
    elif [ "$rc" = 0 ] && [ "$out" = no ]; then
      QL[i]="not needed"
    else
      QL[i]="HOLD: needs-quiet read error (exit $rc, output '$out')"
      printf 'needs-quiet %s: exit %s, output %s\n' "$f" "$rc" "$out" >> "$BUILD/hotfix-quiet.err"
      [ "${HM_PF:-0}" = 1 ] && FST[i]=hold
      hm_wf_pre_stop "$HEAD_HOLD" \
        "needs-quiet read error for $f: exit $rc, output '$out'. We do not read that as a no, so nothing was dispatched." \
        hold
      return $?
    fi
  done
  [ "${#NEEDY[@]}" -gt 0 ] || return 0
  if [ -z "$PROBE" ]; then
    for i in "${NEEDYI[@]}"; do QL[i]="HOLD: probe not configured"; [ "${HM_PF:-0}" = 1 ] && FST[i]=hold; done
    hm_wf_stop hold "$HEAD_HOLD" \
      "probe not configured: HOTFIX_QUIET_PROBE_CMD is unset and these files need a quiet window: $(printf '%s, ' "${NEEDY[@]}" | sed 's/, $//')." \
      hold 3
    return $?
  fi
  local start deadline now rem last prc waited
  start=$(date +%s); deadline=$(( start + QMAX )); last="never read"
  while :; do
    # No rtrim here: the shell already dropped the trailing newline, and a
    # probe that answered " 0" or "0 scans" has not answered 0.
    out=$(cd "$WT" && "${PRA[@]}" 2>>"$BUILD/hotfix-quiet.err"); prc=$?
    if [ "$prc" = 0 ] && [ -n "$out" ] && [ -z "${out//[0-9]/}" ]; then
      if [ "$out" = 0 ]; then
        waited=$(( $(date +%s) - start ))
        for i in "${NEEDYI[@]}"; do QL[i]="waited ${waited}s, active=0"; done
        return 0
      fi
      last="active=$out"
    else
      last="read error (exit $prc, output '$out')"
      printf 'quiet probe: %s\n' "$last" >> "$BUILD/hotfix-quiet.err"
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      for i in "${NEEDYI[@]}"; do QL[i]="HOLD: $last"; [ "${HM_PF:-0}" = 1 ] && FST[i]=hold; done
      hm_wf_pre_stop "$HEAD_HOLD" \
        "quiet window not reached in ${QMAX}s; last probe: $last" hold
      return $?
    fi
    rem=$(( deadline - now )); [ "$rem" -gt "$QPOLL" ] && rem="$QPOLL"
    sleep "$rem"
  done
}

# hm_wf_run_ids: the ids of the workflow_dispatch runs listed under the
# dispatch ref now, space separated. Read BEFORE a dispatch, so hm_wf_locate can
# refuse a run that existed before ours.
hm_wf_run_ids() {
  gh run list -R "$SLUG" --workflow "$WF" --branch "$DREF" --limit 5 \
     --json databaseId,createdAt,status,event 2>/dev/null \
   | jq -r '[.[] | .databaseId | tostring] | join(" ")' 2>/dev/null
}

# hm_wf_dispatch_lock: hold one lock per (repo, workflow, dispatch ref) from the
# dispatch to the locate (BH-9403 refute review). Every before-merge dispatch of
# a project whose dispatch_ref is `main` lists under ONE ref, so without the
# lock a second build's dispatch can land between our dispatch and our locate,
# and the locate would take that run. The lock is held for seconds (dispatch +
# at most LWAIT), never across a watch or a build: it is not a build queue.
# rc 0 = held (HM_WF_LFD is the fd), rc 1 = not held in the wait.
hm_wf_dispatch_lock() {
  local r="${HARNESS:-${H:-}}" d k w
  # knob: hotfix_migrate.conf.<project> dispatch_lock_s, else env HOTFIX_DISPATCH_LOCK_WAIT
  w=$(hm_wf_int "${HOTFIX_DISPATCH_LOCK_WAIT:-120}" 120)
  [ "$w" -ge 1 ] || w=1
  d="${r:-${TMPDIR:-/tmp}}/locks"
  mkdir -p "$d" 2>/dev/null
  k=$(printf '%s|%s|%s' "$SLUG" "$WF" "$DREF" | sha1sum | cut -c1-16)
  HM_WF_LFD=""
  exec {HM_WF_LFD}>"$d/hotfix-dispatch-$k.lock" || { HM_WF_LFD=""; return 1; }
  flock -w "$w" "$HM_WF_LFD" && return 0
  exec {HM_WF_LFD}>&-; HM_WF_LFD=""
  return 1
}

# hm_wf_dispatch_unlock: drop the lock hm_wf_dispatch_lock took. Safe to repeat.
hm_wf_dispatch_unlock() {
  [ -n "${HM_WF_LFD:-}" ] && exec {HM_WF_LFD}>&-
  HM_WF_LFD=""
  return 0
}

# hm_wf_locate <stamp> [<pre-dispatch ids>]: the run we just dispatched -> RUN_ID.
# A candidate is a workflow_dispatch run listed under the DISPATCH ref (a run
# dispatched from main lists under main, not under the PR branch), created at or
# after the stamp, and NOT in the id list read before the dispatch. ISO-8601 Z
# strings compare as strings.
#   rc 0  exactly one candidate: RUN_ID is it
#   rc 1  no candidate within LWAIT: RUN_ID empty (lost)
#   rc 2  two or more candidates: RUN_ID empty, HM_WF_LOCATE_WHY names them. We
#         cannot tell which one is ours, so we bind to none. The newest run is
#         NOT ours by default: another PR or a hand dispatch can be newer.
hm_wf_locate() {
  local stamp="$1" pre="${2:-}" ldl now rem cands n
  HM_WF_LOCATE_WHY=""; RUN_ID=""
  ldl=$(( $(date +%s) + LWAIT ))
  while :; do
    cands=$(gh run list -R "$SLUG" --workflow "$WF" --branch "$DREF" --limit 5 \
               --json databaseId,createdAt,status,event 2>/dev/null \
             | jq -r --arg t "$stamp" --arg pre "$pre" \
               '($pre | split(" ") | map(select(. != ""))) as $p
                | [.[] | select(.createdAt >= $t)
                       | select((.event // "workflow_dispatch") == "workflow_dispatch")
                       | select((.databaseId | tostring) as $id | ([$p[] | select(. == $id)] | length) == 0)]
                | sort_by(.createdAt) | .[].databaseId' 2>/dev/null)
    n=$(grep -c . <<<"$cands")
    if [ "$n" = 1 ]; then RUN_ID="$cands"; return 0; fi
    if [ "$n" -gt 1 ]; then
      HM_WF_LOCATE_WHY="$n runs of $WF on $DREF started after our dispatch ($(tr '\n' ' ' <<<"$cands" | sed 's/ $//')), so we cannot tell which one is ours"
      return 2
    fi
    now=$(date +%s)
    [ "$now" -ge "$ldl" ] && return 1
    rem=$(( ldl - now )); [ "$rem" -gt 5 ] && rem=5
    sleep "$rem"
  done
}

# hm_wf_send <gh argv...>: dispatch and locate as ONE step, under
# hm_wf_dispatch_lock. HM_WF_STAMP gets the dispatch stamp, HM_WF_DRC the gh exit.
#   rc 0  dispatched, RUN_ID is our run
#   rc 4  the lock was not free in its wait: nothing dispatched, a re-run is safe
#   rc 5  the dispatch failed: nothing is running
#   rc 1  dispatched, run not located (hm_wf_locate rc 1)
#   rc 2  dispatched, two or more candidate runs (hm_wf_locate rc 2)
#   rc 6  before-merge: the live head is not the reviewed sha (hm_wf_head_bound),
#         nothing dispatched
hm_wf_send() {
  local pre lrc
  HM_WF_STAMP=""; HM_WF_DRC=0; RUN_ID=""
  hm_wf_dispatch_lock || return 4
  if ! hm_wf_head_bound; then hm_wf_dispatch_unlock; return 6; fi
  pre=$(hm_wf_run_ids)
  HM_WF_STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh "$@" > "$BUILD/hotfix-dispatch.txt" 2>&1
  HM_WF_DRC=$?
  if [ "$HM_WF_DRC" != 0 ]; then hm_wf_dispatch_unlock; return 5; fi
  hm_wf_locate "$HM_WF_STAMP" "$pre"; lrc=$?
  hm_wf_dispatch_unlock
  return "$lrc"
}

# hm_wf_send_stop <rc> <file>: the hold for a hm_wf_send rc that is not 0. A run
# we cannot bind (rc 2) also sends one alert: a person must read the Actions tab.
hm_wf_send_stop() {
  local rc="$1" f="$2" lw
  lw=$(hm_wf_int "${HOTFIX_DISPATCH_LOCK_WAIT:-120}" 120)
  case "$rc" in
    4) hm_wf_pre_stop "$HEAD_HOLD" \
         "another dispatch of $WF on $DREF held the dispatch lock for ${lw}s, so we did not dispatch $f. Nothing is running for it, so a re-run is safe." \
         hold ;;
    5) hm_wf_pre_stop "$HEAD_HOLD" \
         "workflow dispatch failed for $f (gh exit $HM_WF_DRC). Nothing is running for it, so a re-run is safe." \
         dispatch-failed "$BUILD/hotfix-dispatch.txt" ;;
    6) hm_wf_pre_stop "$HEAD_HOLD" "$HM_WF_HEAD_WHY" hold "$BUILD/hotfix-gh.err" ;;
    2) hm_wf_alert "hotfix-migrate-unbound-$PROJECT-$(hm_wf_pr_num)-${FP:0:12}" \
         "hotfix-migrate: dispatched $f on $PR_URL but $HM_WF_LOCATE_WHY. Nothing was recorded as applied; a person checks the Actions tab for $WF on $DREF."
       hm_wf_stop hold "We dispatched this $NOUN's migration workflow and could not tell which run is ours." \
         "dispatched $f at $HM_WF_STAMP, but $HM_WF_LOCATE_WHY. We watched none of them and recorded nothing as applied. Check the Actions tab for $WF on $DREF before re-running, because a re-run dispatches again." \
         dispatched-unlocated 3 "$BUILD/hotfix-dispatch.txt" ;;
    *) hm_wf_stop hold "We dispatched this $NOUN's migration workflow and then lost sight of it." \
         "dispatched $f at $HM_WF_STAMP but could not locate the run within ${LWAIT}s; check the Actions tab for $WF on $DREF before re-running, because a re-run dispatches again." \
         dispatched-unlocated 3 "$BUILD/hotfix-dispatch.txt" ;;
  esac
}

# hm_wf_alert <id> <text>: one ALERTS line through the shared helper.
hm_wf_alert() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] && [ -x "$r/bin/alert-line.sh" ] || { echo "hotfix-migrate: ALERT $2" >&2; return 0; }
  HARNESS="$r" "$r/bin/alert-line.sh" --id "$1" --project "$PROJECT" "$2" >/dev/null 2>&1 || true
}

# hm_wf_inert_alert: once per project per UTC day (HM_TODAY is the clock seam).
# The UTC day is part of the alert id, and alert-line.sh keeps one alert row per
# id (akey alert:<id>), so the same day gives one alert. No state/ file is
# written (tests/no-state-files.bh-4159-test.sh).
hm_wf_inert_alert() {
  local day
  day="${HM_TODAY:-$(date -u +%F)}"
  hm_wf_alert "hotfix-migrate-inert-$PROJECT-$day" \
    "hotfix-migrate: $WF on $SLUG is inert (it says so in its run log), so before-merge applies of $PROJECT do nothing. Give the workflow its database credential. First seen on $PR_URL"
}

# hm_workflow: arm this repo's App token, run the body, put the caller's token
# back. Split in two so the reset happens on ALL of the body's return paths
# rather than being repeated at each of them.
hm_workflow() {
  local hmwrc r="${HARNESS:-${H:-}}"
  # No root = gh-app-auth is not loaded from one (BH-2650): the body runs on
  # the caller's token, as it does on a box without the lib.
  if ! command -v gh_auth_for >/dev/null 2>&1 \
     && [ -n "$r" ] && [ -r "$r/bin/lib/gh-app-auth.sh" ]; then
    # shellcheck source=bin/lib/gh-app-auth.sh
    . "$r/bin/lib/gh-app-auth.sh"
  fi
  if command -v gh_auth_for >/dev/null 2>&1; then gh_auth_for "$SLUG" || true; fi
  hm_workflow_body
  hmwrc=$?
  if command -v gh_auth_reset >/dev/null 2>&1; then gh_auth_reset; fi
  return "$hmwrc"
}


hm_workflow_body() {
  local WF INPUT SEP MAXF NQ PROBE QMAX QPOLL RWAIT LWAIT DREF NOUN
  local -a NQA=() PRA=()
  local RUN_ID="" RUN_URL="" WORD="" FSTAT="" HEAD_HOLD HEAD_OK
  local -a QL=()
  local i

  WF="${HOTFIX_MIGRATE_WORKFLOW:-migrate-manual.yml}"
  # Dash, not colon-dash: set-but-empty means "pass no -f", unset means `files`.
  INPUT="${HOTFIX_WORKFLOW_FILES_INPUT-files}"
  SEP="${HOTFIX_WORKFLOW_FILES_SEP-,}"
  MAXF="${HOTFIX_WORKFLOW_MAX_FILES:-}"
  NQ="${HOTFIX_NEEDS_QUIET_CMD:-node scripts/migration-sql.mjs --needs-quiet}"
  PROBE="${HOTFIX_QUIET_PROBE_CMD:-}"
  # The dispatch ref: the settings row's dispatch_ref, else the PR branch (the
  # shape every project had before BH-9403).
  DREF="${HMK_DISPATCH_REF:-$BRANCH}"
  # Word-split once, here, so the path below is argv and never shell source.
  eval "NQA=($NQ)" 2>/dev/null || NQA=()
  [ -n "$PROBE" ] && { eval "PRA=($PROBE)" 2>/dev/null || PRA=(); }
  QMAX=$(hm_wf_int "${HOTFIX_QUIET_MAX_WAIT:-900}" 900)
  QPOLL=$(hm_wf_int "${HOTFIX_QUIET_POLL:-30}" 30)
  RWAIT=$(hm_wf_int "${HOTFIX_RUN_WAIT:-1800}" 1800)
  LWAIT=$(hm_wf_int "${HOTFIX_RUN_LOCATE_WAIT:-60}" 60)
  # `timeout 0` is "no limit" in coreutils, the opposite of what a 0 caller means.
  [ "$RWAIT" -ge 1 ] || RWAIT=1
  # And a 0 poll is `sleep 0`: the probe is a live DB query, so an unfloored 0
  # would run it as fast as the box can fork for the whole window.
  [ "$QPOLL" -ge 1 ] || QPOLL=1

  NOUN=hotfix; [ "${HM_BEFORE_MERGE:-0}" = 1 ] && NOUN=PR
  HEAD_HOLD="We held this $NOUN and dispatched nothing."
  HEAD_OK="We dispatched this $NOUN's migration workflow and it finished green."

  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do QL+=("not checked"); i=$((i+1)); done

  if [ "${HMK_PER_FILE:-0}" = 1 ]; then
    hm_wf_per_file
    return $?
  fi

  # ── 1. dedupe BEFORE spend ────────────────────────────────────────────────
  # A dispatch is a production write, so the question "did we already pay for a
  # run of exactly this SQL" is asked first. hm_main's own idempotence block
  # normally catches an `applied` ledger before we are called; the rule lives
  # here too, so it holds wherever this function is called from.
  if [ -s "$LEDGER" ] && [ "$(jq -r --arg fp "$FP" '.fp == $fp' "$LEDGER" 2>/dev/null)" = true ]; then
    local ldec lrun lst
    ldec=$(jq -r '.decision // ""' "$LEDGER" 2>/dev/null)
    lrun=$(jq -r '[.files[]?.run_id // empty] | map(select(. != "")) | .[0] // ""' "$LEDGER" 2>/dev/null)
    lst=$(jq -r '[.files[]?.status // empty] | .[0] // ""' "$LEDGER" 2>/dev/null)
    if [ -n "$lrun" ] && [ "$ldec" = applied ]; then
      cat "$LEDGER"
      return 0
    fi
    # A run id in the ledger means a dispatch we already paid for, so the list
    # below is the SHORT one: only a word GitHub itself finished badly falls
    # through to a fresh dispatch. Everything else re-attaches — including the
    # words step 7 writes when the WATCH misfired rather than the run (a
    # transient `gh run watch` error after a green run records `success`, a
    # watch and a view that both failed record `exit <rc>`). Re-attaching a run
    # that already finished is free: `run watch --exit-status` returns at once
    # and the ledger becomes `applied`. Re-dispatching it applies the SQL twice.
    if [ -n "$lrun" ]; then
      case "$lst" in
        failure|cancelled|timed_out|startup_failure|action_required|dispatch-failed) ;;
        *) RUN_ID="$lrun" ;;
      esac
    fi
  fi

  if [ -z "$RUN_ID" ]; then
    # ── 2. the PR's checks ──────────────────────────────────────────────────
    if ! hm_wf_checks; then
      if [ "${HM_BEFORE_MERGE:-0}" = 1 ]; then
        hm_wf_pre_stop "$HEAD_HOLD" "checks not green, so we stopped before the dispatch." hold "$BUILD/hotfix-checks.txt"
      else
        hm_hold "checks not green, so we stopped before the dispatch." "$BUILD/hotfix-checks.txt"
      fi
      return $?
    fi

    # ── 3 + 4. does each file need a quiet window, and the window itself ─────
    local -a ALLI=()
    i=0; while [ "$i" -lt "${#FILES[@]}" ]; do ALLI+=("$i"); i=$((i+1)); done
    hm_wf_quiet "${ALLI[@]}" || return $?

    # ── 5. the dispatch ─────────────────────────────────────────────────────
    local joined drc f
    local -a args=(workflow run "$WF" -R "$SLUG" --ref "$DREF") toks=()
    if [ -n "$INPUT" ]; then
      # A cap that the PR does not fit under is a refusal, not a best effort:
      # project-5's migrate-manual.yml takes ONE `file`, and handing it `a,b`
      # fails inside a run we already paid to start.
      if [ -n "$MAXF" ] && [ "${#FILES[@]}" -gt "$MAXF" ]; then
        hm_wf_stop hold "$HEAD_HOLD" \
          "this PR adds ${#FILES[@]} migration files and $WF takes at most $MAXF on its \`$INPUT\` input (HOTFIX_WORKFLOW_MAX_FILES), so more migration files than the workflow can carry would have ridden on one dispatch. Apply them in separate hotfix PRs, or by hand." \
          hold 3
        return $?
      fi
      for f in "${FILES[@]}"; do
        if [ "${HMK_FILE_FORM:-path}" = basename ]; then toks+=("${f##*/}"); else toks+=("$f"); fi
      done
      joined=$(IFS="$SEP"; printf '%s' "${toks[*]}")
      args+=(-f "$INPUT=$joined")
    fi
    [ -n "${HMK_BRANCH_INPUT:-}" ] && args+=(-f "$HMK_BRANCH_INPUT=$BRANCH")
    if [ "${HMK_APPROVE_HEAD:-0}" = 1 ] && ! hm_wf_approve_head; then
      hm_wf_pre_stop "$HEAD_HOLD" "$HM_WF_APPROVE_WHY" hold "$BUILD/hotfix-approve.err"
      return $?
    fi
    # ── 5 + 6. dispatch, and bind the run we just started ──────────────────
    hm_wf_send "${args[@]}"; drc=$?
    if [ "$drc" != 0 ]; then
      hm_wf_send_stop "$drc" "this PR's SQL"
      return $?
    fi
  fi

  # ── 7. watch it ───────────────────────────────────────────────────────────
  local wrc word note
  RUN_URL="https://github.com/$SLUG/actions/runs/$RUN_ID"
  timeout "$RWAIT" gh run watch "$RUN_ID" -R "$SLUG" --exit-status > "$BUILD/hotfix-run-watch.txt" 2>&1
  wrc=$?
  word=$(gh run view "$RUN_ID" -R "$SLUG" --json status,conclusion \
           -q 'if (.conclusion // "") != "" then .conclusion else .status end' 2>/dev/null)
  word=$(hm_wf_rtrim "${word:-}")
  case "$word" in null) word="" ;; esac

  # ── 8. the log tail, best effort ──────────────────────────────────────────
  # Lines AND bytes: 60 lines of a verbose runner can be hundreds of KB, and a
  # body over GitHub's 65536-char comment limit fails to post, which turns a real
  # apply into `applied` with posted_comment_id null (hm_finish's rc 3).
  gh run view "$RUN_ID" -R "$SLUG" --log 2>&1 | tail -n 60 | tail -c 8000 \
    > "$BUILD/hotfix-run-log.txt"

  # ── 9. ledger, then proof ─────────────────────────────────────────────────
  if [ "$wrc" = 0 ]; then
    FSTAT=applied; WORD="${word:-success}"
    hm_wf_stop applied "$HEAD_OK" "" applied 0
    return $?
  fi
  if [ "$wrc" = 124 ]; then
    # OUR deadline, not GitHub's: the run is still going. Recording its real
    # in-flight word plus the id is what lets a re-run re-attach to it instead
    # of dispatching a second one.
    FSTAT="${word:-in_progress}"; WORD="$FSTAT"
    note="watch timed out after ${RWAIT}s. The run is still going; a re-run of this stage re-attaches to it and does not dispatch again."
  else
    FSTAT="${word:-exit $wrc}"; WORD="$FSTAT"
    note="the run did not finish green (gh run watch exit $wrc, GitHub says $FSTAT)."
  fi
  hm_wf_stop hold "We held this $NOUN: the migration workflow did not finish green." \
    "$note" "$FSTAT" 3 "$BUILD/hotfix-run-watch.txt"
  return $?
}

# hm_wf_per_file: HMK_PER_FILE=1. One dispatch per file, in file-name order
# (LC_ALL=C on the base name), each watched and classified before the next one
# starts. It stops at the first file that does not come back applied or
# already-applied. Called from hm_workflow_body, whose locals it reads.
#
# Per file, from the ledger of THIS fingerprint, before any spend:
#   applied / already-applied           skip it, it is done
#   refused / inert / failed            stop, dispatch nothing (terminal)
#   a run id with any other word        re-attach to that run, never re-dispatch
#   no run id                           checks, approval, quiet window, dispatch
# The ledger is rewritten after every file, so a crash between files costs a
# re-attach, never a second apply.
hm_wf_per_file() {
  local HM_PF=1
  local -a FST=() FRUN=() SORTED=()
  local i f st run tok drc wrc word lcap checked=0 approved=0
  HM_WF_REASON=""
  mapfile -t SORTED < <(for f in "${FILES[@]}"; do printf '%s\t%s\n' "${f##*/}" "$f"; done \
                         | LC_ALL=C sort -t "$(printf '\t')" -k1,1 | cut -f2-)
  FILES=("${SORTED[@]}")
  lcap=$(hm_wf_int "${HMK_LOG_CAP_KB:-2048}" 2048)   # knob: hotfix_migrate.conf.<project> log_cap_kb
  [ "$lcap" -ge 1 ] || lcap=1

  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do
    FST[i]=""; FRUN[i]=""
    if [ -s "$LEDGER" ] && [ "$(jq -r --arg fp "$FP" '.fp == $fp' "$LEDGER" 2>/dev/null)" = true ]; then
      FST[i]=$(jq -r --arg p "${FILES[$i]}" '[.files[]? | select(.path == $p) | .status // ""] | .[0] // ""' "$LEDGER" 2>/dev/null)
      FRUN[i]=$(jq -r --arg p "${FILES[$i]}" '[.files[]? | select(.path == $p) | .run_id // "" | tostring] | .[0] // ""' "$LEDGER" 2>/dev/null)
      # A pre-dispatch stop of an earlier run says nothing about this one.
      case "${FST[$i]}" in hold|not-dispatched|dispatch-failed|dispatched-unlocated) FST[i]=""; FRUN[i]="" ;; esac
    fi
    i=$((i+1))
  done

  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do
    f="${FILES[$i]}"; st="${FST[$i]}"; run="${FRUN[$i]}"
    case "$st" in
      applied|already-applied) QL[i]="not needed (applied earlier)"; i=$((i+1)); continue ;;
      refused|inert|failed)
        # Terminal: we stopped on this file before. No dispatch, no new alert.
        local pid; pid=$(jq -r '.posted_comment_id // "null"' "$LEDGER" 2>/dev/null)
        if [ "$pid" != null ] && [ -n "$pid" ]; then cat "$LEDGER"; return 3; fi
        hm_wf_stop hold "We held this $NOUN: the migration workflow did not apply $f." \
          "$f came back $st on an earlier run. We do not dispatch it again; a person reads the run and decides." "$st" 3
        return $? ;;
    esac
    RUN_ID=""
    [ -n "$run" ] && RUN_ID="$run"

    if [ -z "$RUN_ID" ]; then
      if [ "$checked" = 0 ]; then
        if ! hm_wf_checks; then
          FST[i]=hold
          hm_wf_pre_stop "$HEAD_HOLD" "checks not green, so we stopped before the dispatch." hold "$BUILD/hotfix-checks.txt"
          return $?
        fi
        checked=1
      fi
      if [ "${HMK_APPROVE_HEAD:-0}" = 1 ] && [ "$approved" = 0 ]; then
        if ! hm_wf_approve_head; then
          FST[i]=hold
          hm_wf_pre_stop "$HEAD_HOLD" "$HM_WF_APPROVE_WHY" hold "$BUILD/hotfix-approve.err"
          return $?
        fi
        approved=1
      fi
      hm_wf_quiet "$i" || return $?
      tok="$f"; [ "${HMK_FILE_FORM:-path}" = basename ] && tok="${f##*/}"
      local -a args=(workflow run "$WF" -R "$SLUG" --ref "$DREF")
      [ -n "$INPUT" ] && args+=(-f "$INPUT=$tok")
      [ -n "${HMK_BRANCH_INPUT:-}" ] && args+=(-f "$HMK_BRANCH_INPUT=$BRANCH")
      hm_wf_send "${args[@]}"; drc=$?
      if [ "$drc" != 0 ]; then
        case "$drc" in 4|6) FST[i]=hold ;; 5) FST[i]=dispatch-failed ;; *) FST[i]=dispatched-unlocated ;; esac
        hm_wf_send_stop "$drc" "$f"
        return $?
      fi
      FRUN[i]="$RUN_ID"; FST[i]=dispatched
      hm_wf_pf_ledger
    fi

    # watch, then the whole (capped) log, then the word
    RUN_URL="https://github.com/$SLUG/actions/runs/$RUN_ID"
    timeout "$RWAIT" gh run watch "$RUN_ID" -R "$SLUG" --exit-status > "$BUILD/hotfix-run-watch.txt" 2>&1
    wrc=$?
    gh run view "$RUN_ID" -R "$SLUG" --log 2>/dev/null | head -c $(( lcap * 1024 )) > "$BUILD/hotfix-run-log-full.txt"
    tail -n 60 "$BUILD/hotfix-run-log-full.txt" | tail -c 8000 > "$BUILD/hotfix-run-log.txt"
    # Not in $(...): hm_wf_outcome sets HM_WF_REASON, which the proof and the
    # alert read, and a subshell would drop it.
    hm_wf_outcome "$BUILD/hotfix-run-log-full.txt" "$wrc" "${f##*/}" "$f" > "$BUILD/hotfix-outcome.txt"
    word=$(cat "$BUILD/hotfix-outcome.txt")
    WORD="$word"
    case "$word" in
      success-unworded)
        if [ "${HMK_REQUIRE_WORD:-0}" = 1 ]; then
          # This workflow always names the file it applied (row key require_word).
          # A green run with no word about OUR file did not apply it: it can be
          # another dispatch's run, or a log cut at log_cap_kb. Never `applied`.
          FST[i]=failed
          hm_wf_alert "hotfix-migrate-unworded-$PROJECT-$(hm_wf_pr_num)-${FP:0:12}" \
            "hotfix-migrate: run $RUN_ID of $WF finished green on $PR_URL but its log has no applied, already-applied or refused line for $f. Not recorded as applied; a person reads the run."
          hm_wf_stop hold "We held this $NOUN: the migration run did not say it applied $f." \
            "run $RUN_ID finished green, but its log has no \`applied:\`, \`already-applied:\` or \`refused:\` line for $f, and $WF always writes one. So this run did not apply $f. We do not dispatch it again; a person reads the run." \
            failed 3 "$BUILD/hotfix-run-log.txt"
          return $?
        fi
        FST[i]=applied
        hm_wf_pf_ledger
        i=$((i+1)); continue ;;
      applied|already-applied)
        FST[i]="$word"
        hm_wf_pf_ledger
        i=$((i+1)); continue ;;
      in-flight)
        local live
        live=$(gh run view "$RUN_ID" -R "$SLUG" --json status -q .status 2>/dev/null)
        FST[i]=$(hm_wf_rtrim "${live:-in_progress}")
        [ -n "${FST[$i]}" ] && [ "${FST[$i]}" != null ] || FST[i]=in_progress
        hm_wf_stop hold "$HEAD_HOLD" \
          "watch timed out after ${RWAIT}s on $f. The run is still going; a re-run of this stage re-attaches to it and does not dispatch again." \
          "${FST[$i]}" 3 "$BUILD/hotfix-run-watch.txt"
        return $? ;;
      refused)
        FST[i]=refused
        hm_wf_alert "hotfix-migrate-refused-$PROJECT-$(hm_wf_pr_num)-${FP:0:12}" \
          "hotfix-migrate: $WF refused $f on $PR_URL: $HM_WF_REASON. Not retried; a person reads the proof comment."
        hm_wf_stop hold "We held this $NOUN: the migration workflow refused $f." \
          "$WF refused $f. We do not retry a refusal. The files after it were not dispatched." refused 3
        return $? ;;
      inert)
        FST[i]=inert
        hm_wf_inert_alert
        hm_wf_stop hold "We held this $NOUN: the migration workflow is inert." \
          "$WF ran but says it is inert, so $f was not applied. The files after it were not dispatched." inert 3
        return $? ;;
      *)
        FST[i]=failed
        hm_wf_stop hold "We held this $NOUN: the migration workflow did not finish green." \
          "the run for $f did not finish green (gh run watch exit $wrc). We do not dispatch it again; a person reads the run." \
          failed 3 "$BUILD/hotfix-run-watch.txt"
        return $? ;;
    esac
  done
  WORD=applied
  hm_wf_stop applied "$HEAD_OK" "" applied 0
  return $?
}
