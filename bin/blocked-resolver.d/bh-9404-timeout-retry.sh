# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9404-timeout-retry.sh — BH-9404 (TK-3699): a fix
# round whose agent call timed out gets one more round per PR head before the
# ticket goes to its terminal.
#
# WHY. TK-3699's fix round ran into FIX_AGENT_TIMEOUT (agent rc 124). The
# round was recorded, the cap was spent, brfix/<ck> was deleted and
# br_fix_terminal closed the PR after one try that never finished.
#
# WHAT. br_fix_round calls brtr_take in its failed-round branch, after the
# "rounds remaining" exit and before the terminal. brtr_take takes the retry
# only when the agent rc is exactly 124, the knob is above 0 and this head has
# fewer timeout_retry marks than the knob. It then writes ONE record edit:
#   .timeout_retry += [head]     (the mark; "-" when the head is unknown)
#   .fixround_refunds += 1       (br_fix_cap adds it in every branch, BH-8896:
#                                 the round does not count against the cap)
#   review-changes-requested: the head leaves .review_fix_heads, so the next
#                                 tick offers that head again
#   one attempt row fix-round-timeout-retry
# The checkpoint branch brfix/<ck> is kept (deleted only for a foreign author,
# as the rounds-remaining exit does). A second timeout on the same head finds
# the mark and the terminal runs as before. A failed write also falls to the
# terminal (fail closed to the old behavior).
#
# The mark rides the FIX_RECORD of a hopped round back to the hub, and
# br_fix_adopt saves it because the attempt count grew.

# brtr_knob <label> — BR_FIX_TIMEOUT_RETRIES, the registry knob
#   lane.blocked-resolver.BR_FIX_TIMEOUT_RETRIES (catalog/lanes.d/
#   blocked-resolver.knobs.d/BR_FIX_TIMEOUT_RETRIES.json). 1 is its documented
#   fallback; a value that is not a whole number uses it with one line; a value
#   over the row's max 5 is 5.
brtr_knob() {
  local k="${BR_FIX_TIMEOUT_RETRIES:-1}"
  case "$k" in
    ''|*[!0-9]*) say "$1: BR_FIX_TIMEOUT_RETRIES is '$k', not a number — the fallback 1 is used"; k=1 ;;
  esac
  k=$((10#$k)); [ "$k" -gt 5 ] && k=5
  printf '%s' "$k"
}

# brtr_take <project> <cap-key> <rkey> <reason> <pr-url> <head> <agent-rc> <author-bad>
#   rc 0 = the retry was taken and recorded: the caller ends the round (return 0).
#   rc 1 = no retry: the caller runs its terminal as before.
brtr_take() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" head="${6:-}" arc="$7" bad="${8:-0}"
  local knob h h8 used
  [ "$arc" = 124 ] || return 1
  knob=$(brtr_knob "$p/$rkey [$reason]")
  [ "$knob" -gt 0 ] 2>/dev/null || return 1
  h=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] || h="-"
  h8="${h:0:8}"
  used=$(br_load "$p" "$ck" | jq -r --arg h "$h" '[(.timeout_retry // [])[] | select(. == $h)] | length' 2>/dev/null)
  case "$used" in ''|*[!0-9]*)
    say "$p/$rkey [$reason]: the fix round timed out on $h8, but the record would not read — no timeout retry, the terminal runs as before"
    return 1 ;;
  esac
  if [ "$used" -ge "$knob" ]; then
    say "$p/$rkey [$reason]: the fix round timed out again on $h8 — no timeout retry left ($used of $knob used)"
    return 1
  fi
  # shellcheck disable=SC2016  # $h $r $u $t $d are jq variables, bound by --arg
  if ! br_json_edit "$p" "$ck" '.timeout_retry = ((.timeout_retry // []) + [$h])
      | .fixround_refunds = ((.fixround_refunds // 0) + 1)
      | (if $r == "review-changes-requested" then .review_fix_heads = ((.review_fix_heads // []) - [$h]) else . end)
      | .attempts = ((.attempts // []) + [{at:$t, action:"fix-round-timeout-retry", reason:$r, url:$u, head:$h, detail:$d}])
      | .updated = $t' \
      --arg h "$h" --arg r "$reason" --arg u "$url" --arg t "$(STAMP)" \
      --arg d "agent rc=124 (timed out) on $h8; this round does not count against the fix rung; timeout retry $((used+1)) of $knob"; then
    say "$p/$rkey [$reason]: the fix round timed out on $h8, but the timeout retry was not recorded — the terminal runs as before"
    return 1
  fi
  br_wt_drop "the round timed out; one more round is owed"
  # A foreign-authored checkpoint is never reused (the rounds-remaining exit's rule).
  [ "$bad" = 1 ] && git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
  mc_git_auth_clear 2>/dev/null
  br_event resolver_fix_timeout_retry "$p" "$ck" "$reason" "agent rc=124 on $h8; timeout retry $((used+1)) of $knob"
  say "$p/$rkey [$reason]: the fix round timed out (agent rc=124) on $h8 — one more round next tick, timeout retry $((used+1)) of $knob"
  return 0
}
