# shellcheck shell=bash
# bin/blocked-resolver.d/bh-10248-nothing-new-park.sh — a fix round that records
# nothing new is not re-offered for ever on the same head.
#
# WHY. On 2026-11-26 four cromford PRs with a lead BLOCK (#9510, #9643,
# #9974, #10045) took 10 to 19 fix rounds each. Every round answered `done`
# with the record it was given (n_in == n_out on fix_round_jobs rows 2925-2956),
# so br_fix_adopt said "recorded nothing new — re-offered next tick" and the
# next tick queued the same round again: about 5 minutes of a Fly machine each
# time, for no change. The box half stopped at br_fix_round's one-round-per-
# (PR, head) dedupe (BH-872): each head was already in review_fix_heads. The
# hub never asks that dedupe, because it queues the round (br_fix_remote) before
# it. Any other early return on the box that writes no attempt loops the same way.
#
# WHAT. Two one-line call sites in bin/blocked-resolver.sh, each `command -v`
# guarded, so BR_OPT_OFF=bh-10248-nothing-new-park runs as before:
#   br_fix_adopt   the `done)` branch, when the record did not grow:
#                  brnn_note counts the streak on the head the box read.
#   br_fix_remote  before the box lookup: brnn_gate, rc 0 = the park is parked,
#                  nothing is queued (the caller returns 0, nothing spent).
#
# THE COUNT. Record field .nothing_new = {head, n, attempts, at}. head is the
# head the round saw (record_out's sup_head, else its last review_fix_heads,
# else rung_head; the hub's own record when record_out is empty). attempts is
# the hub record's attempt count; a streak continues only while the head and
# that count are unchanged, so a round that recorded anything restarts it.
# At n >= BR_FIX_NOTHING_NEW_MAX the park is PARKED: one br_event and one
# lane-alert (id per project, cap key and head), and no round is queued again
# on that head. The gate reads the PR's live head once per tick only while
# parked: a moved head clears .nothing_new and the round is queued; a head
# that cannot be read stays parked this tick (nothing spent).
#
# Knob (catalog/lanes.d/blocked-resolver.knobs.d/BR_FIX_NOTHING_NEW_MAX.json):
#   BR_FIX_NOTHING_NEW_MAX  3  nothing-new rounds in a row on one head before
#                              the park is parked (0 = off, max 20)
# Tests: tests/fixround-nothing-new-park.bh-10248-test.sh.

# brnn_max — the knob, 0..20; a value that is not a whole number is 3.
brnn_max() {
  # BR_FIX_NOTHING_NEW_MAX: lane.blocked-resolver.BR_FIX_NOTHING_NEW_MAX (fallback 3)
  local k="${BR_FIX_NOTHING_NEW_MAX:-3}"
  case "$k" in ''|*[!0-9]*) k=3 ;; esac
  k=$((10#$k)); [ "$k" -gt 20 ] && k=20
  printf '%s' "$k"
}

# brnn_head <record-json> — the head a round saw, lower case, or empty.
brnn_head() {
  printf '%s' "${1:-}" | jq -r '(.sup_head // (.review_fix_heads // [])[-1] // .rung_head // "")
    | strings | ascii_downcase' 2>/dev/null
}

# brnn_note <p> <ck> <rkey> <reason> <url> <box> <record_out-json> — one
#   nothing-new adopt. Always rc 0.
brnn_note() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="${5:--}" box="${6:-the owning box}" ro="${7:-}"
  local max st h a n
  max=$(brnn_max); [ "$max" -gt 0 ] || return 0
  st=$(br_load "$p" "$ck")
  h=$(brnn_head "$ro"); [ -n "$h" ] || h=$(brnn_head "$st"); [ -n "$h" ] || h=-
  a=$(printf '%s' "$st" | jq '(.attempts // []) | length' 2>/dev/null); case "$a" in ''|*[!0-9]*) a=0 ;; esac
  n=$(printf '%s' "$st" | jq -r --arg h "$h" --argjson a "$a" \
    'if (.nothing_new.head // "") == $h and (.nothing_new.attempts // -1) == $a then (.nothing_new.n // 0) else 0 end' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  # shellcheck disable=SC2016  # $h $n $a $t are jq variables
  if ! br_json_edit "$p" "$ck" '.nothing_new = {head:$h, n:($n|tonumber), attempts:($a|tonumber), at:$t}' \
      --arg h "$h" --arg n "$n" --arg a "$a" --arg t "$(STAMP)"; then
    say "$p/$rkey [$reason]: could not record the nothing-new count on ${h:0:8} — not counted, re-offered next tick"
    return 0
  fi
  if [ "$n" -lt "$max" ]; then
    say "$p/$rkey [$reason]: nothing new $n of $max in a row on ${h:0:8} (BR_FIX_NOTHING_NEW_MAX)"
    return 0
  fi
  say "$p/$rkey [$reason]: PARKED — $n fix rounds in a row on ${h:0:8} recorded nothing new (BR_FIX_NOTHING_NEW_MAX=$max); no round is queued again on this head, a push to the PR re-opens it"
  br_event resolver_fix_nothing_new_park "$p" "$ck" "$reason" "$n rounds on ${h:0:8} recorded nothing new — parked for a person"
  "$H/bin/lane-alert.sh" --id "fix-round-nothing-new-$p-$ck-${h:0:8}" blocked-resolver \
    "$p/$rkey [$reason]: $n fix rounds in a row on ${h:0:8} of ${url} answered done and recorded nothing new (last on $box) — the park is PARKED, no round is queued again on this head. The round returns before it does work (for example: the head is already in review_fix_heads, BH-872). Needed: a person reads the round's log and fixes the cause, or pushes the PR." \
    >/dev/null 2>&1 || true
  return 0
}

# brnn_gate <p> <ck> <rkey> <reason> <url> — rc 0 = parked: queue nothing.
#   rc 1 = queue the round (below the cap, knob off, or the head moved).
brnn_gate() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="${5:--}" max st h n a slug num live
  max=$(brnn_max); [ "$max" -gt 0 ] || return 1
  st=$(br_load "$p" "$ck")
  IFS=$'\t' read -r h n a < <(printf '%s' "$st" | jq -r '[(.nothing_new.head // ""), (.nothing_new.n // 0 | tostring),
      (if (.nothing_new.attempts // -1) == ((.attempts // []) | length) then "same" else "moved" end)] | @tsv' 2>/dev/null)
  case "${n:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "${h:-}" ] && [ "$a" = same ] && [ "$n" -ge "$max" ] || return 1
  slug=$(mc_slug_of_url "$url" 2>/dev/null); num=$(mc_num_of_url "$url" 2>/dev/null)
  if [ "$h" != - ] && [ -n "$slug" ] && [ -n "$num" ]; then
    if ! live=$(mc_pr_live_head "$slug" "$num" 2>/dev/null) || [ -z "$live" ]; then
      say "$p/$rkey [$reason]: parked on ${h:0:8} ($n nothing-new rounds) and the live head could not be read — stays parked this tick"
      return 0
    fi
    live=$(tr 'A-F' 'a-f' <<<"${live%%$'\n'*}")
    if [ "$live" != "$h" ]; then
      br_json_edit "$p" "$ck" 'del(.nothing_new)' \
        || { say "$p/$rkey [$reason]: the PR moved to ${live:0:8} but the park could not be lifted — stays parked this tick"; return 0; }
      say "$p/$rkey [$reason]: the PR moved from ${h:0:8} to ${live:0:8} — the nothing-new park is lifted, the round is queued"
      return 1
    fi
  fi
  say "$p/$rkey [$reason]: PARKED on ${h:0:8} — $n fix rounds in a row recorded nothing new (BR_FIX_NOTHING_NEW_MAX=$max); nothing queued, a push to the PR re-opens it"
  return 0
}
