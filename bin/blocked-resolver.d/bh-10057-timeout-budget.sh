# shellcheck shell=bash
# bin/blocked-resolver.d/bh-10057-timeout-budget.sh — BH-10057: a fix round
# that BH-9404 retries after a timeout runs with a larger agent budget.
#
# WHY. BH-9404 gives a round whose agent call ended rc 124 one more round per
# PR head. That round ran with the same FIX_AGENT_TIMEOUT (3600 s) it had
# already run out of.
#
# WHAT. br_fix_round calls brtb_agent_timeout once, before the agent call, and
# passes its answer to `timeout` and to agent-call.sh. The round is a retry when
# the record's .timeout_retry (written by brtr_take, bh-9404-timeout-retry.sh)
# holds this round's head, normalized as brtr_take does it (lower case; not
# 40-hex -> "-"). A retry gets FIX_AGENT_TIMEOUT * BR_FIX_TIMEOUT_RETRY_PCT / 100
# (bin/lib/fix-retry-budget.sh, default 150 % -> 5400 s). Every other case (no
# mark, an unreadable record, BR_FIX_TIMEOUT_RETRIES=0, no lib, a bad base)
# answers FIX_AGENT_TIMEOUT, the old behavior.
#
# ONE RETRY PER MARK. The mark stays on the record (brtr_take counts it), so
# the budget is spent with a second list: the round that gets the larger
# budget appends its head to .timeout_retry_ran. A head with as many ran
# entries as marks answers FIX_AGENT_TIMEOUT, so a later round on the same head
# (a review-park round, a round after a refund) gets the base budget again. A
# failed write answers FIX_AGENT_TIMEOUT (fail closed to the old behavior).
#
# brtb_agent_max is the agent term of br_fix_bound (bin/lib/br/cap.sh): the
# longest agent call of any round, so the unclaimed and stale-claim pages
# wait for a retry (8400 s at the defaults).

# brtb_lib — sources bin/lib/fix-retry-budget.sh once. rc 1 when it is missing.
brtb_lib() {
  command -v frb_retry_s >/dev/null 2>&1 && return 0
  [ -r "$H/bin/lib/fix-retry-budget.sh" ] || return 1
  # shellcheck source=../lib/fix-retry-budget.sh
  . "$H/bin/lib/fix-retry-budget.sh" || return 1
  command -v frb_retry_s >/dev/null 2>&1
}

# brtb_agent_timeout <project> <cap-key> <head> — prints the agent budget of
#   this round, in seconds. Always rc 0.
brtb_agent_timeout() {
  local p="$1" ck="$2" h n r pct prc=0 s
  local base="${FIX_AGENT_TIMEOUT:-}"
  case "${BR_FIX_TIMEOUT_RETRIES:-1}" in
    ''|*[!0-9]*) ;;                                   # junk: brtr_knob's fallback 1, the retry is on
    *) [ "$((10#${BR_FIX_TIMEOUT_RETRIES:-1}))" -gt 0 ] || { printf '%s' "$base"; return 0; } ;;
  esac
  brtb_lib || { printf '%s' "$base"; return 0; }
  h=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] || h="-"
  read -r n r < <(br_load "$p" "$ck" 2>/dev/null | jq -r --arg h "$h" \
    '"\([(.timeout_retry // [])[] | select(. == $h)] | length) \([(.timeout_retry_ran // [])[] | select(. == $h)] | length)"' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$r" in ''|*[!0-9]*) r=0 ;; esac
  [ "$n" -gt "$r" ] || { printf '%s' "$base"; return 0; }
  pct=$(frb_pct "${BR_FIX_TIMEOUT_RETRY_PCT:-}") || prc=$?
  [ "$prc" = 3 ] && say "$p/$ck: BR_FIX_TIMEOUT_RETRY_PCT is '${BR_FIX_TIMEOUT_RETRY_PCT:-}', not a whole number — the fallback 150 is used"
  s=$(frb_retry_s "$base" "$pct") || { printf '%s' "$base"; return 0; }
  # shellcheck disable=SC2016  # $h is a jq variable, bound by --arg
  if ! br_json_edit "$p" "$ck" '.timeout_retry_ran = ((.timeout_retry_ran // []) + [$h])' --arg h "$h"; then
    say "$p/$ck: timeout retry: the larger budget could not be recorded as spent — this round runs with ${base}s"
    printf '%s' "$base"; return 0
  fi
  say "$p/$ck: timeout retry: agent budget ${s}s (${pct}% of ${base}s)"
  printf '%s' "$s"
}

# brtb_agent_max — prints the longest agent call of any round (the agent term
#   of br_fix_bound): the retry budget when BR_FIX_TIMEOUT_RETRIES > 0, else
#   FIX_AGENT_TIMEOUT.
brtb_agent_max() {
  local a
  if brtb_lib && a=$(frb_agent_max "${FIX_AGENT_TIMEOUT:-}" "${BR_FIX_TIMEOUT_RETRIES:-1}" "$(frb_pct "${BR_FIX_TIMEOUT_RETRY_PCT:-}")"); then
    printf '%s' "$a"
  else
    printf '%s' "${FIX_AGENT_TIMEOUT:-}"
  fi
}
