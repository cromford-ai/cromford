# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9906-verify-budget.sh — BH-9906: a fix round's
# verification has its own budget, and a verification that runs out of it
# keeps the agent's paid work for a verify-only retry.
#
# WHY. On project-3 (2026-11-23) four rounds ran on one box at once. Each agent
# finished, then the typecheck plus the unit suite ran past the one clock the
# round had for agent and verification together. The round was killed, its
# worktree removed, and the next round bought the agent call again.
#
# WHAT. br_fix_round calls these, one line each:
#   brvb_agent_done <p> <ck> <lease> <wt>
#       before the agent call. rc 0 when this record's .agent_done is for this
#       project and this PR head (compared lower-case) and its commit is
#       readable: the local checkpoint brfix/<ck>, else a fetch of
#       refs/harness/fixround/<ck>/<head> (a Fly machine has a fresh clone).
#       The worktree is put on that commit (reset --hard when HEAD does not
#       already contain it), and the agent call is skipped. A head that moved:
#       brvb_forget, rc 1. A commit not readable: one line, rc 1 (the agent runs).
#   brvb_mark_agent_done <p> <ck> <lease> <wt> [<main-ref>]
#       after the agent, rc 0, BEFORE verification: when the round has commits
#       of its own (non-merge, reachable from HEAD, not from the lease or
#       <main-ref>), push HEAD to refs/harness/fixround/<ck>/<lease> (a ref
#       that is not a branch: no CI run, no Mergify rule) and write ONE record
#       edit: .agent_done = {head, commit, at, ref, ref_pushed} plus one
#       attempt row fix-round-agent-done. A push that fails is ref_pushed:false
#       and one line; the box's own brfix/<ck> still has the commit.
#   brvb_forget <p> <ck>
#       a verification that ran to its end (green or red, not a timeout), the
#       pushed exit and a moved head: empty refs/harness/fixround/<ck>/ on
#       origin with a --prune push of that namespace (a failure is logged,
#       never fatal) and del(.agent_done). A red verify means the agent's work
#       was wrong, so the next round on that head buys the agent again with
#       the failing output; only a timeout (and the yield checkpoints) keep it.
#   brvb_budget / brvb_left / brvb_spent
#       the verify block's clock: BR_FIX_VERIFY_TIMEOUT seconds from
#       brvb_budget; brvb_left prints the seconds left (at least 1); brvb_spent
#       is rc 0 when none are left.
#   brvb_is_timeout <verify-out>
#       rc 0 on a line ^TYPECHECK_EXIT: 124$, ^UNIT_EXIT: 124$ or
#       ^VERIFY_TIMEOUT: . An OOM 137, a 1240 or a 124 inside test output is
#       not a timeout.
#   brvb_verify_timeout_exit <p> <ck> <rkey> <reason> <url> <head> <out>
#       the round's exit for it: one attempt row fix-round-verify-timeout (no
#       fixrounds count), a review park's head leaves .review_fix_heads (the
#       BH-9404 rule, so the head is offered again), brfix/<ck> and
#       .agent_done kept, the worktree dropped, then br_fix_verify_timeout
#       (FIX_RESULT verify-timeout <b64> on a box, one line on the hub).
#   brvb_tail_skip <selection-gate|repro> <verify-out>
#       BH-10245: before a verify step that has its own clock (the
#       selection gate, the repro re-run). rc 0 and one line when the step
#       must not run: `<STEP>_EXIT: skipped (an earlier verify step is red: <line>)`
#       when <verify-out> already holds `CI_LOCAL_EXIT: 1` or
#       `CLOSURE_LINT_EXIT: [1-9]` (both refuse the push and no rescore lifts
#       them), else `VERIFY_TIMEOUT: <step>` when the budget is spent. rc 1:
#       the step runs. On 2026-11-26 cromford rounds ran the gate after a
#       red ci-local, under its own 7200 s knob, until the 6600 s round bound.
# Knob: BR_FIX_VERIFY_TIMEOUT (catalog/lanes.d/blocked-resolver.knobs.d/BR_FIX_VERIFY_TIMEOUT.json).
# Tests: tests/fixround-verify-budget.bh-9906-test.sh, tests/fixround-verify-tail.bh-10245-test.sh.

brvb_budget() {
  # BR_FIX_VERIFY_TIMEOUT: lane.blocked-resolver.BR_FIX_VERIFY_TIMEOUT (fallback 2700)
  BRVB_BUDGET="${FIX_VERIFY_TIMEOUT:-${BR_FIX_VERIFY_TIMEOUT:-2700}}"
  case "$BRVB_BUDGET" in ''|*[!0-9]*) say "BR_FIX_VERIFY_TIMEOUT is '$BRVB_BUDGET', not a number of seconds — the fallback 2700 is used"; BRVB_BUDGET=2700 ;; esac
  BRVB_T0=$(date +%s)
}

brvb_left() {
  local l
  [ -n "${BRVB_T0:-}" ] || brvb_budget
  l=$(( BRVB_BUDGET - ($(date +%s) - BRVB_T0) ))
  [ "$l" -ge 1 ] || l=1
  echo "$l"
}

brvb_spent() {
  [ -n "${BRVB_T0:-}" ] || return 1
  [ $(( $(date +%s) - BRVB_T0 )) -ge "$BRVB_BUDGET" ]
}

brvb_tail_skip() {
  local step="$1" out="$2" red word
  red=$(grep -m1 -E '^CI_LOCAL_EXIT: 1|^CLOSURE_LINT_EXIT: [1-9]' "$out" 2>/dev/null)
  if [ -n "$red" ]; then
    case "$step" in selection-gate) word=SELECTION_GATE ;; repro) word=REPRO ;; *) word=$(printf '%s' "$step" | tr 'a-z-' 'A-Z_') ;; esac
    echo "${word}_EXIT: skipped (an earlier verify step is red: $red)"
    return 0
  fi
  if brvb_spent; then echo "VERIFY_TIMEOUT: $step"; return 0; fi
  return 1
}

brvb_is_timeout() {
  [ -r "${1:-}" ] || return 1
  grep -qE '^(TYPECHECK|UNIT)_EXIT: 124$|^VERIFY_TIMEOUT: ' "$1"
}

brvb_forget() {
  local p="$1" ck="$2" h
  h=$(br_load "$p" "$ck" | jq -r '.agent_done.head // empty | ascii_downcase' 2>/dev/null)
  [ -n "$h" ] || return 0
  # The park's checkpoint namespace refs/harness/fixround/<ck>/ is emptied:
  # the local refs go, then a --prune push of the namespace removes origin's
  # (this head's ref, and any left by an earlier delete that failed). Nothing
  # under refs/heads is touched, so no PR can be based on what goes (BH-1715).
  if git check-ref-format "refs/harness/fixround/$ck/$h" 2>/dev/null; then
    git -C "$REPOS/$p" for-each-ref --format='%(refname)' "refs/harness/fixround/$ck/" 2>/dev/null \
      | while IFS= read -r r; do git -C "$REPOS/$p" update-ref -d "$r" >/dev/null 2>&1; done
    git -C "$REPOS/$p" push -q --prune origin "refs/harness/fixround/$ck/*:refs/harness/fixround/$ck/*" >/dev/null 2>&1 \
      || say "$p/$ck: could not delete refs/harness/fixround/$ck/${h:0:8} on origin (it is left; a later round on that head deletes it)"
  fi
  br_json_edit "$p" "$ck" 'del(.agent_done)' \
    || say "$p/$ck: could NOT delete .agent_done on $(br_file "$p" "$ck" 2>/dev/null) — the next round re-checks the head before it uses it"
  return 0
}

brvb_agent_done() {
  local p="$1" ck="$2" lease="$3" wt="$4" st h c ref
  st=$(br_load "$p" "$ck")
  h=$(printf '%s' "$st" | jq -r --arg p "$p" 'select(.project == $p) | .agent_done.head // empty | ascii_downcase' 2>/dev/null)
  [ -n "$h" ] || return 1
  c=$(printf '%s' "$st" | jq -r '.agent_done.commit // empty | ascii_downcase' 2>/dev/null)
  if [ "$h" != "$(printf '%s' "$lease" | tr 'A-F' 'a-f')" ]; then
    say "$p/$ck: the agent record is for head ${h:0:8}, the PR head is now ${lease:0:8} — the record and its ref are dropped, the agent runs"
    brvb_forget "$p" "$ck"
    return 1
  fi
  case "$c" in ''|*[!0-9a-f]*) say "$p/$ck: the agent record has no commit — the agent runs"; return 1 ;; esac
  ref="refs/harness/fixround/$ck/$h"
  if ! git -C "$wt" cat-file -e "$c^{commit}" 2>/dev/null; then
    git check-ref-format "$ref" 2>/dev/null && git -C "$REPOS/$p" fetch -q origin "+$ref:$ref" >/dev/null 2>&1
    if ! git -C "$wt" cat-file -e "$c^{commit}" 2>/dev/null; then
      say "$p/$ck: the agent's commit ${c:0:8} from an earlier round is not readable here (no brfix/$ck holds it, no $ref on origin) — the agent runs"
      return 1
    fi
  fi
  if ! git -C "$wt" merge-base --is-ancestor "$c" HEAD 2>/dev/null; then
    git -C "$wt" reset -q --hard "$c" 2>/dev/null || { say "$p/$ck: could not put the round's tree on ${c:0:8} — the agent runs"; return 1; }
  fi
  return 0
}

brvb_mark_agent_done() {
  local p="$1" ck="$2" lease="$3" wt="$4" mref="${5:-main}" c own ref rp=true not
  c=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 0
  [ -n "$c" ] && [ "$c" != "$lease" ] || return 0
  not="$lease"
  git -C "$wt" rev-parse --verify -q "origin/$mref" >/dev/null 2>&1 && not="$not origin/$mref"
  # shellcheck disable=SC2086
  own=$(git -C "$wt" rev-list --no-merges -n 1 HEAD --not $not 2>/dev/null)
  [ -n "$own" ] || return 0
  ref="refs/harness/fixround/$ck/$(printf '%s' "$lease" | tr 'A-F' 'a-f')"
  if ! git check-ref-format "$ref" 2>/dev/null; then
    rp=false; say "$p/$ck: '$ref' is not a valid ref — the agent's commit stays on brfix/$ck only"
  elif ! git -C "$wt" push -q origin "+HEAD:$ref" >/dev/null 2>&1; then
    rp=false; say "$p/$ck: the push of the agent's commit ${c:0:8} to $ref failed — it stays on brfix/$ck on this box only"
  fi
  # shellcheck disable=SC2016  # jq variables
  br_json_edit "$p" "$ck" '.agent_done = {head:$h, commit:$c, at:$a, ref:$r, ref_pushed:($rp == "true")}
    | .attempts += [{at:$a, action:"fix-round-agent-done", reason:"", detail:("the agent committed " + $c[0:8] + " on head " + $h[0:8] + "; kept for a verify-only retry")}]' \
    --arg h "$(printf '%s' "$lease" | tr 'A-F' 'a-f')" --arg c "$c" --arg a "$(STAMP 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" --arg r "$ref" --arg rp "$rp" \
    || say "$p/$ck: could NOT record the agent's commit ${c:0:8} — a verification timeout would buy the agent again"
  return 0
}

brvb_verify_timeout_exit() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" head="$6" out="$7" last why
  last=$(grep -E '^(TYPECHECK|UNIT)_EXIT: |^VERIFY_TIMEOUT: ' "$out" 2>/dev/null | tail -1)
  why="the agent is done (its commit is kept), the verification ran out of BR_FIX_VERIFY_TIMEOUT (${BRVB_BUDGET:-?}s): ${last:-no step line}"
  br_record "$p" "$ck" fix-round-verify-timeout "$reason" "$why" "" "$url" "${head:--}" \
    || say "$p/$rkey [$reason]: could NOT record the verification timeout on $(br_file "$p" "$ck" 2>/dev/null)"
  if [ "$reason" = review-changes-requested ] && [ -n "$head" ]; then
    # shellcheck disable=SC2016  # $h is a jq variable
    br_json_edit "$p" "$ck" '.review_fix_heads = ((.review_fix_heads // []) - [$h])' --arg h "$head" \
      || say "$p/$rkey [$reason]: could NOT un-mark ${head:0:8} after the verification timeout — that head may not be offered again"
  fi
  say "$p/$rkey [$reason]: VERIFY TIMEOUT — $why; brfix/$ck and the agent record are kept, the retry runs verification only"
  br_wt_drop "the verification ran out of its budget"
  mc_git_auth_clear 2>/dev/null
  br_fix_verify_timeout "$p" "$ck" "$rkey" "$reason" "$url" "$why"
  return 0
}
