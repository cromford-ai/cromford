#!/bin/bash
# bin/lib/mc/block-ci.sh — BH-3932 (BH-3929.0) contract, filled by BH-3934
# (BH-3929.2): the conductor's CI-block step. Sourced by
# bin/lib/merge-conductor-lib.sh, never executed.
#
# mc_block_ci_step <slug> <num> <head> <url> <block_id> <block_body>
#   Called by bin/merge-conductor.sh's READY arm right after a block-gate
#   refusal (bg_scan rc 1, enforcement on). <block_id> is bg_scan's fourth
#   field: a comment or review id, verdict-<rowid> for a verdicts-table BLOCK
#   row, or cr-<id>@<sha> for a standing CHANGES_REQUESTED review (never
#   CI-cleared: declined). <block_body> is "" from the conductor, so the body
#   is read by id. Its rc is ignored: the refusal stands this tick whatever
#   this returns, and a later tick merges through the unchanged gate.
#
#   1. classify: the block must say only "CI did not run" (_mc_bci_ci_only)
#   2. dispatch, ONCE per (PR, head): the pr_attempts row (kind blockci) is
#      written BEFORE any POST, so a failed POST is never retried. A cancelled
#      or skipped latest run is re-run; otherwise the workflow the body names,
#      else harness-ci.yml, else the first with a workflow_dispatch trigger
#   3. green check: every job of every latest-per-workflow run whose head_sha
#      is exactly <head> concluded success (skipped is NOT green) → the ledger
#      row block_ci_clear "<slug>#<num>@<head>" cleared "<run> <id> [<id>…]",
#      then the log line `block-cleared-by-ci <slug>#<num> <head> <run>`.
#      bin/lib/block-gate.sh (bg_ci_cleared_ids) drops only the ids it names.
#   Observe mode (ACTIONS != 1) logs WOULD dispatch / WOULD clear and writes
#   nothing.
#
#   rc 0  cleared, or would clear in observe mode
#   rc 1  classified CI-only but not green yet, or a read/write failed after
#         classification
#   rc 2  declined: not CI-only, bad args, no body, a missing helper, or the
#         attempt row could not be written (then nothing is sent)
#   rc 3  the head moved
#
# _MC_BCI_CONTENT_READS bounds the workflow_dispatch lookup (one contents read
# per workflow file, on the one dispatch tick); it is a loop guard, not a knob.
_MC_BCI_CONTENT_READS=20

# The contract classifier lives one directory up; load it when the caller has
# not. No /root/harness default (D43): a missing file leaves it unloaded, and
# _mc_bci_ci_only then answers rc 1.
if ! command -v ph_ci_only_body >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-health.sh" ]; then
  # shellcheck source=bin/lib/pr-health.sh
  . "${BASH_SOURCE[0]%/*}/../pr-health.sh"
fi

# BH-8049: cds_check, the "a PR run already covers this head" skip.
if ! command -v cds_check >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../ci-dispatch-skip.sh" ]; then
  # shellcheck source=bin/lib/ci-dispatch-skip.sh
  . "${BASH_SOURCE[0]%/*}/../ci-dispatch-skip.sh"
fi

# _mc_bci_ci_only <body> — rc 0 only when ph_ci_only_body says every BLOCK is a
#   CI-did-not-run AND the body carries no word of doubt. ph_ci_only_body's own
#   known gap ("CI passed, but the migration did not run on prod" is rc 0 there)
#   is closed here: a success/contrast word or a non-CI subject anywhere in the
#   body is rc 1. Strict on purpose: rc 0 leads to an irreversible clear.
_MC_BCI_DOUBT_RE='\b(pass(ed|es)?|green|succeed(ed|s)?|success(ful)?|but|however|although|though|except)\b|\b(migrations?|deploy(ed|ment|s)?|prod(uction)?|backfill|cron|database|db)\b'
_mc_bci_ci_only() {
  local b="${1:-}"
  command -v ph_ci_only_body >/dev/null 2>&1 || return 1
  ph_ci_only_body "$b" || return 1
  ! grep -Eiq -- "$_MC_BCI_DOUBT_RE" <<<"$b"
}

_mc_bci_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }

# _mc_bci_get <var> <api path> — one GET through a FILE, never `$(gh_rest …)`
#   (the classify.sh idiom), so the read's rc is gh_rest's own: 0, 44, 75.
_mc_bci_get() {
  local _bg_out="$1" _bg_t _bg_rc=0 _bg_v=""
  _bg_t=$(mktemp "${TMPDIR:-/tmp}/mc-bci.XXXXXX") || { printf -v "$_bg_out" '%s' ""; return 75; }
  gh_rest GET "$2" > "$_bg_t" || _bg_rc=$?
  [ "$_bg_rc" = 0 ] && _bg_v=$(cat "$_bg_t" 2>/dev/null)
  rm -f "$_bg_t"
  printf -v "$_bg_out" '%s' "$_bg_v"
  return "$_bg_rc"
}

# _mc_bci_review_body <slug> <num> <id> / _mc_bci_comment_body <slug> <id>
#   rc 0 prints the body; rc 44 no such review/comment; anything else unreadable.
#   A comment counts only when it belongs to this repo's issues.
_mc_bci_review_body() {
  local j="" rc=0
  _mc_bci_get j "repos/$1/pulls/$2/reviews/$3" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  jq -er '.body // empty' <<<"$j" 2>/dev/null || return 75
}
_mc_bci_comment_body() {
  local j="" rc=0 iu=""
  _mc_bci_get j "repos/$1/issues/comments/$2" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  iu=$(jq -r '.issue_url // ""' <<<"$j" 2>/dev/null) || return 75
  case "$iu" in "https://api.github.com/repos/$1/issues/"[0-9]*) ;; *) return 44 ;; esac
  jq -er '.body // empty' <<<"$j" 2>/dev/null || return 75
}

# _mc_bci_body <slug> <num> <head> <block_id> — the BLOCK's body, by id.
_mc_bci_body() {
  local slug="$1" num="$2" head="$3" bid="$4" rc=0 line="" v="" id="" rurl="" n=""
  case "$bid" in
    verdict-*)
      command -v vd_standing >/dev/null 2>&1 || return 1
      line=$(vd_standing "$slug" "$num" "$head" 2>/dev/null) || return 1
      IFS=$'\t' read -r v _ id _ rurl _ <<<"$line"
      [ "$v" = BLOCK ] && [ "verdict-$id" = "$bid" ] || return 1
      case "$rurl" in
        *'#issuecomment-'*)       n="${rurl##*#issuecomment-}"
                                  [[ "$n" =~ ^[0-9]+$ ]] || return 1
                                  _mc_bci_comment_body "$slug" "$n" ;;
        *'#pullrequestreview-'*)  n="${rurl##*#pullrequestreview-}"
                                  [[ "$n" =~ ^[0-9]+$ ]] || return 1
                                  _mc_bci_review_body "$slug" "$num" "$n" ;;
        *) return 1 ;;
      esac ;;
    *)
      _mc_bci_review_body "$slug" "$num" "$bid" && return 0 || rc=$?
      [ "$rc" = 44 ] || return "$rc"
      _mc_bci_comment_body "$slug" "$bid" ;;
  esac
}

# _mc_bci_latest <runs-json> <head> — "<id>\t<status>\t<conclusion>" per
#   workflow, its newest run whose head_sha is exactly <head>. rc 1 unparseable.
_mc_bci_latest() {
  jq -r --arg h "$2" '[(.workflow_runs // [])[] | select(.head_sha == $h)]
    | group_by(.workflow_id) | map(max_by(.id)) | sort_by(.id)[]
    | [(.id|tostring), (.status // "-"), (.conclusion // "-")] | @tsv' <<<"$1" 2>/dev/null
}

# _mc_bci_pick_wf <slug> <branch> <body> — the workflow file to dispatch.
#   rc 0 prints its basename; rc 1 none is dispatchable; rc 75 a read failed.
_mc_bci_pick_wf() {
  local slug="$1" br="$2" body="$3" j="" rc=0 names="" n="" p="" c="" reads=0 brq=""
  _mc_bci_get j "repos/$slug/actions/workflows" || return 75
  names=$(jq -r '(.workflows // [])[] | select((.state // "active") == "active") | .path // empty' <<<"$j" 2>/dev/null) || return 75
  [ -n "$names" ] || return 1
  # (a) a workflow file the body names, (b) harness-ci.yml
  for n in $(grep -oE '[A-Za-z0-9_.-]+\.ya?ml' <<<"$body") harness-ci.yml; do
    while IFS= read -r p; do
      [ "${p##*/}" = "$n" ] && { printf '%s' "$n"; return 0; }
    done <<<"$names"
  done
  # (c) the first whose file declares a workflow_dispatch trigger
  brq=$(jq -rn --arg b "$br" '$b|@uri')
  while IFS= read -r p; do
    [ "$reads" -lt "$_MC_BCI_CONTENT_READS" ] || break
    reads=$((reads+1)); rc=0
    _mc_bci_get j "repos/$slug/contents/$p?ref=$brq" || rc=$?
    [ "$rc" = 0 ] || continue
    c=$(jq -r '.content // empty' <<<"$j" 2>/dev/null | base64 -d 2>/dev/null)
    grep -Eq '^[[:space:]]*workflow_dispatch[[:space:]]*:?' <<<"$c" && { printf '%s' "${p##*/}"; return 0; }
  done <<<"$names"
  return 1
}

# _mc_bci_post <what> <path> [args] — one POST, logged; a 422 is logged and not
#   alerted, any other failure is logged and alerted once (the attempt row is
#   already written, so there is no second POST on this head).
_mc_bci_post() {
  local what="$1" path="$2" rc=0; shift 2
  gh_rest POST "$path" "$@" >/dev/null || rc=$?
  if [ "$rc" = 0 ]; then _mc_bci_log "BLOCK_CI_DISPATCH $_MC_BCI_PR $_MC_BCI_HEAD $what"; return 0; fi
  if [ "${GH_REST_STATUS:-}" = 422 ]; then
    _mc_bci_log "BLOCK_CI_DISPATCH_FAILED $_MC_BCI_PR $_MC_BCI_HEAD $what 422 no workflow_dispatch trigger"
    return 1
  fi
  _mc_bci_log "BLOCK_CI_DISPATCH_FAILED $_MC_BCI_PR $_MC_BCI_HEAD $what ${GH_REST_STATUS:-000}"
  command -v mc_alert >/dev/null 2>&1 && mc_alert "$_MC_BCI_PR" READY \
    "CI dispatch for the CI-only BLOCK on ${_MC_BCI_HEAD:0:8} failed ($what, HTTP ${GH_REST_STATUS:-000}) and is not retried on this head — the block stands until CI runs green on it or a new commit lands"
  return 1
}

# _mc_bci_head_review_body <slug> <num> <head> — the newest PR review that IS
#   the lead's block on exactly <head>: on that commit, posted by an App (user
#   type Bot), carrying the `<!-- lead-review:` marker AND the lead title for
#   this head (`# Lead review lr-<num>-<head12> (`), with a BLOCK verdict in its
#   body (`VERDICT: BLOCK` or `- verdict: BLOCK`). Any other review on the head
#   (a tier or builder review that only says "CI did not run", a MERGE, a
#   person's comment, another head's title) is not this block's body, and a
#   CI-only clear read off it would drop the lead's real findings for good.
#   rc 1 when there is none or the read failed.
_mc_bci_head_review_body() {
  local j="" b=""
  _mc_bci_get j "repos/$1/pulls/$2/reviews?per_page=100" || return 1
  b=$(jq -r --arg h "$3" --arg t "# Lead review lr-$2-${3:0:12} (" '
        [ .[]? | select(.commit_id == $h and (.user.type // "") == "Bot")
               | select((.body // "") as $b
                        | ($b | contains("<!-- lead-review:")) and ($b | contains($t))
                          and ($b | test("(^|\n)(VERDICT: BLOCK|- verdict: BLOCK)[[:space:]]*(\n|$)"))) ]
        | last | .body // empty' <<<"$j" 2>/dev/null)
  [ -n "$b" ] || return 1
  printf '%s' "$b"
}

# _mc_bci_rereview <slug> <num> <head> <bid> — the block body could not be
#   read twice: mark the head "needs re-review" and request ONE new lead review
#   of it. The pr_attempts row (kind rereview) is written BEFORE the request,
#   so a failed request is never repeated on this head. A request the worker
#   refuses (one already exists for the head) falls back to resetting the
#   finished one. Observe mode logs WOULD and writes nothing.
_mc_bci_rereview() {
  local slug="$1" num="$2" head="$3" bid="$4" pr="$1#$2" rc=0 lv id
  lv="${MC_LEAD_VERDICT:-${MC_H:-${HARNESS:-}}/bin/lead-verdict.sh}"
  _mc_bci_log "block-ci $pr $bid: body unreadable twice — needs re-review of ${head:0:8}"
  pr_attempt_has "$slug" "$num" rereview "$head"; rc=$?
  case "$rc" in
    0) return 0 ;;
    1) _mc_bci_log "block-ci $pr ${head:0:8}: rereview attempt row unreadable — no request this tick"; return 1 ;;
  esac
  if [ "${ACTIONS:-0}" != 1 ]; then
    _mc_bci_log "block-ci $pr WOULD request a re-review of ${head:0:8} (block $bid) — observe mode: nothing written"; return 0
  fi
  pr_attempt_put "$slug" "$num" rereview "$head" || { _mc_bci_log "block-ci $pr ${head:0:8}: rereview attempt row not written — no request"; return 1; }
  [ -x "$lv" ] || { _mc_bci_log "block-ci $pr ${head:0:8}: $lv missing — re-review not requested"; return 1; }
  if "$lv" request "$slug" "$num" "$head" --notes "BH-5793: the block body ($bid) could not be read twice; needs re-review" >/dev/null 2>&1; then
    _mc_bci_log "block-ci $pr ${head:0:8}: re-review requested (block $bid unreadable)"; return 0
  fi
  id=$("$lv" list "$slug" 2>/dev/null | awk -F'\t' -v k="$pr" -v h="${head:0:12}" \
         '$3 == k && $4 == h && ($5 == "done" || $5 == "failed" || $5 == "superseded") {sub(/^#/, "", $1); print $1}' | tail -n 1)
  if [ -n "$id" ] && "$lv" reset "$id" >/dev/null 2>&1; then
    _mc_bci_log "block-ci $pr ${head:0:8}: re-review requested by resetting $id (block $bid unreadable)"; return 0
  fi
  _mc_bci_log "block-ci $pr ${head:0:8}: re-review request refused and no finished request to reset — needs a person"
  return 1
}

mc_block_ci_step() {
  local slug="${1:-}" num="${2:-}" head="${3:-}" bid="${5:-}" body="${6:-}"
  local pr key fn rc=0 runs="" latest="" runs_read=0 cds="" cds_rc=1 br="" wf="" j="" id="" st="" co="" run="" detail="" ids="" row="" cur="" rerun=""
  pr="$slug#$num"; key="$pr"
  if ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ "$num" =~ ^[0-9]+$ ]] \
     || ! [[ "$head" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$bid" =~ ^([0-9]+|verdict-[0-9]+)$ ]]; then
    _mc_bci_log "block-ci $pr ${bid:-?}: not a CI-clearable block (args) — declined"
    return 2
  fi
  for fn in gh_rest pr_attempt_has pr_attempt_put job_ledger_row job_ledger_put mc_head_still; do
    command -v "$fn" >/dev/null 2>&1 || { _mc_bci_log "block-ci $pr $bid: $fn not loaded — declined, block stands"; return 2; }
  done
  # The body, by id when the caller handed none.
  if [ -z "$body" ]; then
    body=$(_mc_bci_body "$slug" "$num" "$head" "$bid") || body=""
  fi
  # BH-5793: never let an unreadable block stand. Read it a second way (the
  # PR's own review on this head, where bin/lead-review-land.sh posts a lead
  # BLOCK's findings), then ask for a re-review of the head.
  [ -n "$body" ] || body=$(_mc_bci_head_review_body "$slug" "$num" "$head") || body=""
  [ -n "$body" ] || { _mc_bci_rereview "$slug" "$num" "$head" "$bid"; return 2; }
  _mc_bci_ci_only "$body" || { _mc_bci_log "block-ci $pr $bid: not a CI-only block — declined"; return 2; }

  _MC_BCI_PR="$pr"; _MC_BCI_HEAD="$head"
  pr_attempt_has "$slug" "$num" blockci "$head"; rc=$?
  case "$rc" in
    0) ;;
    1) _mc_bci_log "block-ci $pr ${head:0:8}: attempt row unreadable — no dispatch this tick" ;;
    *)
      if [ "${ACTIONS:-0}" != 1 ]; then
        _mc_bci_log "$key WOULD dispatch CI for ${head:0:8} (block $bid) — observe mode: nothing written"
      else
        mc_head_still "$slug" "$key" "$head" block-ci; rc=$?
        [ "$rc" = 1 ] && return 3
        [ "$rc" = 0 ] || return 2
        # Every read the dispatch needs comes BEFORE the attempt row: a read
        # failure leaves no row, so the next tick tries again; once the row is
        # written, nothing on this head is sent a second time.
        _mc_bci_get runs "repos/$slug/actions/runs?head_sha=$head&per_page=100" \
          && latest=$(_mc_bci_latest "$runs" "$head") \
          || { _mc_bci_log "block-ci $pr ${head:0:8}: runs unreadable — no dispatch this tick"; return 1; }
        runs_read=1
        rerun=$(awk -F'\t' '$3 == "cancelled" || $3 == "skipped" { print $1 }' <<<"$latest")
        if [ -z "$rerun" ]; then
          _mc_bci_get j "repos/$slug/pulls/$num" && br=$(jq -r '.head.ref // empty' <<<"$j" 2>/dev/null) && [ -n "$br" ] \
            || { _mc_bci_log "block-ci $pr ${head:0:8}: head branch unreadable — no dispatch this tick"; return 1; }
          wf=$(_mc_bci_pick_wf "$slug" "$br" "$body"); rc=$?
          [ "$rc" = 75 ] && { _mc_bci_log "block-ci $pr ${head:0:8}: workflows unreadable — no dispatch this tick"; return 1; }
        fi
        # BH-8049: a green or running pull_request/merge_group run of $wf on
        # this head (from the runs read above: no new read) makes the dispatch
        # a duplicate. Skip it and write no attempt row: the green check below
        # clears the block on a green run, and if that run ends red or
        # cancelled the next tick dispatches once as before.
        cds_rc=1
        if [ -z "$rerun" ] && [ -n "$wf" ] && command -v cds_check >/dev/null 2>&1; then
          cds_rc=0; cds=$(cds_check "$slug" "$head" "$wf" "$runs") || cds_rc=$?
          [ -n "$cds" ] && _mc_bci_log "$cds"
        fi
        if [ "$cds_rc" = 0 ]; then
          :
        elif ! pr_attempt_put "$slug" "$num" blockci "$head"; then
          _mc_bci_log "BLOCK_CI_DISPATCH_FAILED $pr $head attempt-row-unwritten"
          return 2
        elif [ -n "$rerun" ]; then
          for id in $rerun; do _mc_bci_post "run:$id" "repos/$slug/actions/runs/$id/rerun"; done
        elif [ -n "$wf" ]; then
          _mc_bci_post "$wf" "repos/$slug/actions/workflows/$wf/dispatches" -f "ref=$br"
        else
          _mc_bci_log "BLOCK_CI_DISPATCH_FAILED $pr $head no-dispatchable-workflow"
          command -v mc_alert >/dev/null 2>&1 && mc_alert "$pr" READY \
            "the CI-only BLOCK on ${head:0:8} needs a CI run, but no active workflow is harness-ci.yml, named in the block, or has a workflow_dispatch trigger — the block stands"
        fi
      fi ;;
  esac

  # The green check: reads only, then at most one ledger write.
  if [ "$runs_read" = 0 ]; then
    _mc_bci_get runs "repos/$slug/actions/runs?head_sha=$head&per_page=100" \
      && latest=$(_mc_bci_latest "$runs" "$head") \
      || { _mc_bci_log "block-ci $pr ${head:0:8}: runs unreadable — not green this tick"; return 1; }
  fi
  [ -n "$latest" ] || return 1
  run=""
  while IFS=$'\t' read -r id st co; do
    [ "$st" = completed ] && [ "$co" = success ] || return 1
    _mc_bci_get j "repos/$slug/actions/runs/$id/jobs?filter=latest&per_page=100" || return 1
    # Zero jobs, a job that is not success (skipped included), or a page that
    # does not hold every job is not green.
    jq -e '(.jobs // []) as $j | ($j | length) > 0 and ((.total_count // ($j|length)) <= ($j | length))
           and all($j[]; .conclusion == "success")' <<<"$j" >/dev/null 2>&1 || return 1
    run="$id"
  done <<<"$latest"
  [ -n "$run" ] || return 1
  if [ "${ACTIONS:-0}" != 1 ]; then
    _mc_bci_log "$key WOULD clear block $bid on ${head:0:8} (run $run)"
    return 0
  fi
  row=$(job_ledger_row block_ci_clear "$pr@$head"); rc=$?
  case "$rc" in
    0) detail="$run $bid"
       if [ "$(jq -r '.status // ""' <<<"$row" 2>/dev/null)" = cleared ]; then
         cur=$(jq -r '.detail // ""' <<<"$row" 2>/dev/null)
         read -r _ ids <<<"$cur"
         case " $ids " in *" $bid "*) detail="$run $ids" ;; *) detail="$run${ids:+ $ids} $bid" ;; esac
       fi ;;
    2) detail="$run $bid" ;;
    *) _mc_bci_log "block-ci $pr ${head:0:8}: clear row unreadable — not written, block stands"; return 1 ;;
  esac
  if ! job_ledger_put block_ci_clear "$pr@$head" cleared "$detail"; then
    _mc_bci_log "block-ci $pr ${head:0:8}: clear row unwritten — block stands"
    return 1
  fi
  _mc_bci_log "block-cleared-by-ci $pr $head $run"
  return 0
}
