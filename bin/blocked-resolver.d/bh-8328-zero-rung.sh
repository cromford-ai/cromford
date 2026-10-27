# shellcheck shell=bash
# bin/blocked-resolver.d/bh-8328-zero-rung.sh — BH-8328: no close on a ladder
# that counted no rung since the last head reset.
#
# WHY. project-6#2606: a person pushed a new head, br_head_gate reset the
# ladder to it, and a fix round on the owning box found nothing to brief. That
# round recorded nothing and answered FIX_RESULT terminal. The hub took the
# terminal under the park's new reason (review-changes-requested), and
# br_abandon closed the PR with "fix round 0 ... could not start: 0" in its
# close comment. headgate's no-real-rung guard did not fire, because no
# `-blocked` attempt was on the record.
#
# THE FIX, three call sites, each one line in the driver:
#   br_fix_round, nothing-to-brief branch -> zr_nobrief (one fix-round-blocked
#     attempt, no counter; FIX_RECORD carries it back to the hub)
#   br_abandon, before br_head_gate        -> zr_close_gate (rc 0 close)
#   br_close_facts (headgate.sh)           -> zr_counts (the same counts)
# BR_OPT_OFF=bh-8328-zero-rung does not source this file, and each call site
# then does what it did before.

# zr_counts <project> <cap-key> <pr-url> <reason> — prints `mech regen fix`,
#   the per-head counts since the last head reset. fix is br_cap_rows over the
#   record's fixrounds: the count br_fix_round's cap uses (the pr_attempts rows
#   when a rebuilt hub has more, less the head reset's baseline).
zr_counts() {
  local st m r f
  st=$(br_load "$1" "$2")
  m=$(br_num "$st" mechanicals); r=$(br_num "$st" regens); f=$(br_num "$st" fixrounds)
  f=$(br_cap_rows "$1" "$2" "${4:-close}" "$f" "${3:--}" fixround fixrounds "$st")
  case "$f" in ''|*[!0-9]*) f=$(br_num "$st" fixrounds) ;; esac
  printf '%s %s %s' "$m" "$r" "$f"
}

# zr_last_real <record-json> — the newest attempt that is not bookkeeping
#   (headgate's R6 set: held, stalled, stall-cleared, head-reset, hold-*), as
#   compact json, or `null`.
zr_last_real() {
  printf '%s' "$1" | jq -c '[.attempts[]? | select((.action // "") | (. == "held" or . == "stalled" or . == "stall-cleared" or . == "head-reset" or startswith("hold-")) | not)] | last' 2>/dev/null
}

# zr_nobrief <project> <cap-key> <reason> <pr-url> <head>
#   A fix round that found nothing to brief did not START, so it is one
#   `fix-round-blocked` attempt with no counter (br_setup_blocked's shape),
#   carrying the head and the url. Nothing is written when the newest real
#   attempt is already a nothing-to-brief one for this head, so a stuck park
#   does not add one row per tick. rc 0 written or skipped, rc 1 not written.
zr_nobrief() {
  local p="$1" ck="$2" reason="$3" url="${4:--}" head st t
  head=$(printf '%s' "${5:-}" | tr 'A-F' 'a-f')
  st=$(br_load "$p" "$ck")
  [ "$(zr_last_real "$st" | jq -r --arg h "$head" '(. // {}) | (.action // "") == "fix-round-blocked"
      and ((.detail // "") | startswith("nothing to brief")) and (.head // "") == $h' 2>/dev/null)" = true ] && return 0
  t=$(STAMP)
  st=$(printf '%s' "$st" | jq -c --arg t "$t" --arg r "$reason" --arg u "$url" --arg h "$head" '
    .attempts += [{at:$t, action:"fix-round-blocked", reason:$r,
      detail:"nothing to brief a fix round with (no posted findings, no conflict, no readable failing job): the round did not start, no rung counted"}
      + (if $u == "" or $u == "-" then {} else {url:$u} end)
      + (if $h == "" then {} else {head:$h} end)]
    | .updated = $t' 2>/dev/null) || return 1
  [ -n "$st" ] && br_save "$p" "$ck" "$st"
}

# zr_human_push <owner/repo> <sha> — one REST read of the commit. Prints
#   `<author-login>\t<committer-epoch>`; either may be empty (no linked
#   account; a date that does not parse). rc 75 the read failed.
zr_human_push() {
  local f rc out
  f=$(mktemp) || return 75
  gh_rest GET "repos/$1/commits/$2" > "$f" 2>/dev/null; rc=$?
  if [ "$rc" != 0 ]; then
    say "repos/$1/commits/${2:0:12}: head commit read UNVERIFIABLE (rc $rc, HTTP ${GH_REST_STATUS:-?}) — retried next tick"
    rm -f "$f"; return 75
  fi
  out=$(jq -r '"\(.author.login // "")\t\((.commit.committer.date // "") | (try fromdateiso8601 catch "") | tostring)"' "$f" 2>/dev/null) || out=""
  rm -f "$f"
  [ -n "$out" ] || return 75
  printf '%s' "$out"
}

# zr_close_gate <project> <cap-key> <reason> <pr-url>
#   Called by br_abandon before br_head_gate. Only an open PR is gated.
#   R2, THE ZERO-RUNG REFUSAL (a fix-round park only: br_action fix-round, and
#     a fix cap above 0). The per-head fix count (zr_counts, the count the
#     close comment prints) is 0, or the newest real attempt is a
#     nothing-to-brief round: nothing closes.
#     The next tick offers the park again, and its fix round reads the newest
#     lead review on the head (br_findings): that is the re-brief. The record
#     keeps zero_rung {head, n, alerted}. When n passes BR_ZERO_RUNG_REBRIEFS
#     on one head, ONE NEEDS_HUMAN alert is sent, and the PR still stays open.
#   R3, THE HUMAN-PUSH DEFER (any reason). The head is the one br_head_gate
#     already reset the ladder to (ladder_reset.to), no counted rung ran on it,
#     and it is not this lane's own fix push. Its commit is read: a non-[bot]
#     author (or none) who committed less than BR_HUMAN_PUSH_SETTLE_SECS ago
#     defers the close. Nothing is written.
#   rc 0  close as before. rc 5 nothing closed (refused or deferred).
#   rc 75 nothing closed, retried next tick: a read or the counter write failed.
zr_close_gate() {
  local p="$1" ck="$2" reason="$3" url="${4:--}" out rc cur st cap cnt fix last nob knob n al win info login ep age rh lt fh
  case "$url" in https://github.com/*/*/pull/*) ;; *) return 0 ;; esac
  out=$(br_pr_field "$url" '"\(.state // "") \(.head.sha // "")"' "pr head before a close (zero-rung gate)"); rc=$?
  case "$rc" in
    0) ;;
    44) return 0 ;;
    *) say "$p/$ck [$reason]: ZERO-RUNG GATE — the PR's head could not be read (rc $rc) — nothing closed, retried next tick"
       return 75 ;;
  esac
  [ "${out%% *}" = open ] || return 0
  cur=$(printf '%s' "${out#* }" | tr 'A-F' 'a-f')
  st=$(br_load "$p" "$ck")
  # A fix cap of 0 (BR_REVIEW_FIX_ROUNDS=0 and kin) means no round is ever due,
  # so a count of 0 is the operator's choice, not a round that never ran. The
  # cap is br_fix_round's own read, with its own fallback.
  cap=$(br_fix_cap "$st" "$reason" "$p" 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap="${MAX_FIXROUNDS:-${BR_MAX_FIXROUNDS:-1}}" ;; esac
  if [ "$(br_action "$reason")" = fix-round ] && [ "$cap" != 0 ]; then
    cnt=$(zr_counts "$p" "$ck" "$url" "$reason"); fix="${cnt##* }"
    last=$(zr_last_real "$st")
    nob=$(printf '%s' "$last" | jq -r '(. // {}) | (.action // "") == "fix-round-blocked" and ((.detail // "") | startswith("nothing to brief"))' 2>/dev/null)
    if [ "$fix" = 0 ] || [ "$nob" = true ]; then
      if [ "${OBSERVE:-0}" = 1 ]; then
        say "$p/$ck [$reason]: ZERO-RUNG GATE — WOULD refuse the close: $fix fix rounds counted on ${cur:0:12} since the last head reset — observe mode, nothing written"
        return 5
      fi
      # Registry knob lane.blocked-resolver.BR_ZERO_RUNG_REBRIEFS (catalog/lanes.d/
      # blocked-resolver.knobs.d/BR_ZERO_RUNG_REBRIEFS.json); 1 is its documented fallback.
      knob="${BR_ZERO_RUNG_REBRIEFS:-1}"
      case "$knob" in
        ''|*[!0-9]*) say "$p/$ck [$reason]: BR_ZERO_RUNG_REBRIEFS is '$knob', not a number — the fallback 1 is used"; knob=1 ;;
      esac
      n=$(printf '%s' "$st" | jq -r --arg h "$cur" 'if (.zero_rung.head // "") == $h then ((.zero_rung.n // 0) + 1) else 1 end' 2>/dev/null)
      al=$(printf '%s' "$st" | jq -r --arg h "$cur" 'if (.zero_rung.head // "") == $h then (.zero_rung.alerted // false) else false end' 2>/dev/null)
      case "$n" in ''|*[!0-9]*) n=1 ;; esac
      [ "$al" = true ] || al=false
      st=$(printf '%s' "$st" | jq -c --arg h "$cur" --argjson n "$n" --argjson a "$al" --arg t "$(STAMP)" \
        '.zero_rung = {head:$h, n:$n, alerted:$a} | .updated = $t' 2>/dev/null) || st=""
      if [ -z "$st" ] || ! br_save "$p" "$ck" "$st"; then
        say "$p/$ck [$reason]: ZERO-RUNG GATE — the refusal could not be written — nothing closed, retried next tick"
        return 75
      fi
      if [ "$fix" = 0 ]; then
        say "$p/$ck [$reason]: ZERO-RUNG GATE — 0 fix rounds counted on ${cur:0:12} since the last head reset (the same count the close comment prints) — nothing closed; re-briefed next tick (refusal $n on this head)"
      else
        say "$p/$ck [$reason]: ZERO-RUNG GATE — the newest attempt is a fix round that found nothing to brief (it did not start; $fix fix rounds counted on ${cur:0:12}) — nothing closed; re-briefed next tick (refusal $n on this head)"
      fi
      if [ "$n" -gt "$knob" ] && [ "$al" != true ]; then
        # The field first (br_cap_notes' order): a crash after it cannot page twice.
        st=$(printf '%s' "$st" | jq -c '.zero_rung.alerted = true' 2>/dev/null) || st=""
        if [ -z "$st" ] || ! br_save "$p" "$ck" "$st"; then
          say "$p/$ck [$reason]: ZERO-RUNG GATE — the alert mark could not be written — no alert sent, nothing closed, retried next tick"
          return 75
        fi
        "$H/bin/lane-alert.sh" --id "br-zero-rung:$p:$ck:${cur:0:12}" blocked-resolver \
          "NEEDS_HUMAN: [$p] $url was refused a close $n times on ${cur:0:12}: no fix round was counted on that head since the last head reset (fix count $fix), and the re-brief found nothing to act on. The PR stays open. Look at the head's review and either fix it or close the PR by hand." \
          >/dev/null 2>&1 </dev/null || true
        say "$p/$ck [$reason]: ZERO-RUNG GATE — NEEDS_HUMAN alert sent for ${cur:0:12} after $n refusals (BR_ZERO_RUNG_REBRIEFS=$knob); the PR stays open"
      fi
      return 5
    fi
  fi
  # R3. Registry knob lane.blocked-resolver.BR_HUMAN_PUSH_SETTLE_SECS
  # (catalog/lanes.d/blocked-resolver.knobs.d/BR_HUMAN_PUSH_SETTLE_SECS.json);
  # 3600 (60 min, BH-8474) is its documented fallback, 0 is off.
  win="${BR_HUMAN_PUSH_SETTLE_SECS:-3600}"
  case "$win" in
    ''|*[!0-9]*) say "$p/$ck [$reason]: BR_HUMAN_PUSH_SETTLE_SECS is '$win', not a number — the fallback 3600 is used"; win=3600 ;;
  esac
  [ "$win" -gt 0 ] || return 0
  lt=$(printf '%s' "$st" | jq -r --arg u "$url" 'if (.ladder_reset.url // "") == $u then (.ladder_reset.to // "") else "" end' 2>/dev/null | tr 'A-F' 'a-f')
  [ -n "$lt" ] && [ "$cur" = "$lt" ] || return 0
  rh=$(printf '%s' "$st" | jq -r --arg u "$url" 'if .rung_pr == $u then (.rung_head // "") else "" end' 2>/dev/null | tr 'A-F' 'a-f')
  [ "$cur" = "$rh" ] && return 0
  fh=$(printf '%s' "$st" | jq -r --arg u "$url" 'if .fix_pr == $u then (.fix_head // "") else "" end' 2>/dev/null | tr 'A-F' 'a-f')
  [ -n "$fh" ] && [ "$cur" = "$fh" ] && return 0
  info=$(zr_human_push "$(br_slug_of_url "$url")" "$cur") || {
    say "$p/$ck [$reason]: HUMAN-PUSH DEFER — the head commit ${cur:0:12} could not be read — nothing closed, retried next tick"
    return 75
  }
  login="${info%%$'\t'*}"; ep="${info#*$'\t'}"
  case "$login" in *'[bot]') return 0 ;; esac
  case "$ep" in
    ''|*[!0-9]*)
      say "$p/$ck [$reason]: HUMAN-PUSH DEFER — the committer date of ${cur:0:12} (by ${login:-an unlinked author}) does not parse, so its age is unknown — nothing closed, re-checked next tick"
      return 5 ;;
  esac
  age=$(( $(br_now) - ep ))
  [ "$age" -ge "$win" ] && return 0
  say "$p/$ck [$reason]: HUMAN-PUSH DEFER — deferred: ${login:-an unlinked author} committed ${cur:0:12} ${age}s ago (window ${win}s, BR_HUMAN_PUSH_SETTLE_SECS) — nothing closed, re-checked next tick"
  return 5
}
