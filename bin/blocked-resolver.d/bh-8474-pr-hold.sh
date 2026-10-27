# shellcheck shell=bash
# bin/blocked-resolver.d/bh-8474-pr-hold.sh — BH-8474: a per-PR hold label.
#
# WHY. On 2026-10-25/26 the resolver closed (ABANDONED) project-6#2606,
# project-6#2620 and cromford#7752 while a person or a Mac agent was
# fixing them. The only hold the lane read was the ticket's HOLD comment
# (br_hold_gate), which needs a ticket key and a comment on the issue.
#
# THE FIX. A person puts the label `resolver-hold` (knob BR_PR_HOLD_LABEL) on
# the PR. While it is there, the resolver runs no rung on that PR: no fix
# round, no mechanical, no rebuild, no close. Each tick says so in one line.
# The hold lasts BR_PR_HOLD_TTL_SECS (24 h) from the first tick that saw the
# label. Then one alert is sent and the PR is processed as normal. The label is
# never removed and nothing is written to GitHub.
#
# Two call sites, each on one driver line:
#   br_one, after the unchanged-skip    -> prh_gate (rc 1: br_one rc 3)
#   br_abandon, before zr_close_gate    -> prh_close_gate (rc 5: nothing closed)
# BR_OPT_OFF=bh-8474-pr-hold does not source this file, and each call site
# then does what it did before.

# prh_label — the label name. Registry knob lane.blocked-resolver.BR_PR_HOLD_LABEL
#   (catalog/lanes.d/blocked-resolver.knobs.d/BR_PR_HOLD_LABEL.json); resolver-hold
#   is its documented fallback. The value goes into a jq filter, so only
#   [A-Za-z0-9._:-] is accepted.
prh_label() {
  local l="${BR_PR_HOLD_LABEL:-resolver-hold}"
  if [[ ! "$l" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    say "BR_PR_HOLD_LABEL is '$l', not a plain label name — the fallback resolver-hold is used"
    l=resolver-hold
  fi
  printf '%s' "$l"
}

# prh_gate <project> <rkey> <reason> <pr-url> <ticket-key>
#   rc 0 proceed (no label, not open, absent, hold expired, TTL 0).
#   rc 1 held: the label is on the open PR and younger than the TTL, or the PR
#   could not be read, or the hold could not be written. Nothing ran.
prh_gate() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" tkey="${5:--}"
  local lab out rc ck st since al ttl now age iso
  case "$url" in https://github.com/*/*/pull/*) ;; *) return 0 ;; esac
  lab=$(prh_label)
  out=$(br_pr_field "$url" "\"\\(.state // \"\") \\(any(.labels[]?; .name == \"$lab\"))\"" "pr labels (pr-hold gate)"); rc=$?
  case "$rc" in
    0) ;;
    44) return 0 ;;
    *) say "$p/$rkey [$reason]: PR HOLD — the labels of $url could not be read (rc $rc) — no rung this tick, retried next tick"
       return 1 ;;
  esac
  [ "${out%% *}" = open ] || return 0
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  st=$(br_load "$p" "$ck")
  if [ "${out#* }" != true ]; then
    # The label is gone: a hold this record kept for this PR is lifted.
    if [ "$(printf '%s' "$st" | jq -r --arg u "$url" '(.pr_hold.url // "") == $u' 2>/dev/null)" = true ] && [ "${OBSERVE:-0}" != 1 ]; then
      st=$(printf '%s' "$st" | jq -c 'del(.pr_hold)' 2>/dev/null) && [ -n "$st" ] && br_save "$p" "$ck" "$st" \
        && say "$p/$rkey [$reason]: PR HOLD — lifted on $url (label $lab removed)"
    fi
    return 0
  fi
  # Registry knob lane.blocked-resolver.BR_PR_HOLD_TTL_SECS (catalog/lanes.d/
  # blocked-resolver.knobs.d/BR_PR_HOLD_TTL_SECS.json); 86400 is its documented
  # fallback, 0 means the label is not honoured.
  ttl="${BR_PR_HOLD_TTL_SECS:-86400}"
  case "$ttl" in
    ''|*[!0-9]*) say "$p/$rkey [$reason]: BR_PR_HOLD_TTL_SECS is '$ttl', not a number — the fallback 86400 is used"; ttl=86400 ;;
  esac
  if [ "$ttl" = 0 ]; then
    say "$p/$rkey [$reason]: PR HOLD — $url carries label $lab, but BR_PR_HOLD_TTL_SECS=0 — the label is not honoured, processed as normal"
    return 0
  fi
  now=$(br_now)
  since=$(printf '%s' "$st" | jq -r --arg u "$url" 'if (.pr_hold.url // "") == $u then (.pr_hold.since // "") else "" end' 2>/dev/null)
  al=$(printf '%s' "$st" | jq -r --arg u "$url" 'if (.pr_hold.url // "") == $u then (.pr_hold.alerted // false) else false end' 2>/dev/null)
  case "$since" in
    ''|*[!0-9]*)
      since="$now"; al=false
      if [ "${OBSERVE:-0}" = 1 ]; then
        say "$p/$rkey [$reason]: PR HOLD — $url carries label $lab — observe mode, nothing written, no rung"
        return 1
      fi
      st=$(printf '%s' "$st" | jq -c --arg u "$url" --argjson s "$since" '.pr_hold = {url:$u, since:$s, alerted:false}' 2>/dev/null) || st=""
      if [ -z "$st" ] || ! br_save "$p" "$ck" "$st"; then
        say "$p/$rkey [$reason]: PR HOLD — $url carries label $lab, and the hold could not be written — no rung this tick, retried next tick"
        return 1
      fi ;;
  esac
  iso=$(jq -rn --argjson s "$since" '$s | todate' 2>/dev/null)
  age=$(( now - since ))
  if [ "$age" -lt "$ttl" ]; then
    say "$p/$rkey [$reason]: PR HOLD — $url carries label $lab (seen since ${iso:-$since}, expires in $(( ttl - age ))s) — no fix round, no rung, no close"
    return 1
  fi
  if [ "$al" = true ]; then
    say "$p/$rkey [$reason]: PR HOLD EXPIRED — $url still carries label $lab (seen since ${iso:-$since}, alerted) — processed as normal"
    return 0
  fi
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [$reason]: PR HOLD EXPIRED — WOULD alert on $url — observe mode, nothing written"
    return 0
  fi
  # The mark first (BH-8328's order): a crash after it cannot page twice.
  st=$(printf '%s' "$st" | jq -c '.pr_hold.alerted = true' 2>/dev/null) || st=""
  if [ -z "$st" ] || ! br_save "$p" "$ck" "$st"; then
    say "$p/$rkey [$reason]: PR HOLD EXPIRED — the alert mark could not be written — no alert sent, no rung this tick, retried next tick"
    return 1
  fi
  "$H/bin/lane-alert.sh" --id "br-pr-hold-expired:$(br_slug_of_url "$url")#${url##*/}:$since" blocked-resolver \
    "[$p] $url has carried the label $lab since ${iso:-$since}, longer than BR_PR_HOLD_TTL_SECS=${ttl}s. The hold expired: the resolver processes the PR again from this tick (fix round, rebuild or close). Remove the label, or close or fix the PR by hand." \
    >/dev/null 2>&1 </dev/null || true
  say "$p/$rkey [$reason]: PR HOLD EXPIRED — $url carried label $lab for ${age}s (BR_PR_HOLD_TTL_SECS=$ttl) — one alert sent, processed as normal"
  return 0
}

# prh_close_gate <project> <rkey> <reason> <pr-url> <ticket-key> — prh_gate for
#   br_abandon: rc 0 close as before, rc 5 nothing closed (held).
prh_close_gate() {
  prh_gate "$@" && return 0
  return 5
}
