#!/bin/bash
# shellcheck shell=bash
# module: headgate after: record ladder
# bin/lib/br/headgate.sh — BH-7660: the HEAD GATE in front of every ladder
# close. Sourced by bin/blocked-resolver.sh, never run. Sourcing it defines
# three functions and does nothing else. At call time it reads the PR over REST
# (br_pr_field) and reads and writes the record through record.sh.
#
# WHY. A person pushed a new head to a parked PR, and the lane closed the PR
# ABANDONED 30 minutes later on rung counts that all ran on the OLD head. The
# supersede guard only DELAYS a close after a new head (the settle window); it
# never resets the counts. br_record now stores the head of each counted rung
# (rung_head / rung_pr), so the gate can compare it with the PR's head now.
#
# br_head_gate <project> <cap-key> <reason> <pr-url>
#   Called by br_abandon and by br_rebuild_fresh right before their close.
#   rc 0   close as before: no PR url, the PR is absent (404), not open, its
#          head is the head of the last counted rung, the head this lane's own
#          fix round pushed, the head the ladder was already reset to once, or
#          the record names no rung head for this PR (a legacy record).
#   rc 5   STOPPED, nothing closed: the head moved after the last counted rung
#          (the per-head counters are reset for the new head, br_head_reset),
#          or no real rung ever ran (every attempt since the counters were zero
#          could not START, br_setup_blocked).
#   rc 75  nothing closed, nothing written, retried next tick: the head could
#          not be read, is not a full sha, or the reset could not be written.
#   Sets BR_GATE_HEAD to the head it read on an open PR (else empty), which the
#   close comment prints (br_close_facts).
br_head_gate() {
  local p="$1" ck="$2" reason="$3" url="${4:--}" out rc state cur st rh fh lt k
  BR_GATE_HEAD=""
  case "$url" in https://github.com/*/*/pull/*) ;; *) return 0 ;; esac
  out=$(br_pr_field "$url" '"\(.state // "") \(.head.sha // "")"' "pr head before a ladder close"); rc=$?
  case "$rc" in
    0) ;;
    44) return 0 ;;
    *) say "$p/$ck [$reason]: HEAD GATE — the PR's head could not be read (rc $rc) — nothing closed, retried next tick"
       return 75 ;;
  esac
  state="${out%% *}"
  [ "$state" = open ] || return 0
  cur=$(printf '%s' "${out#* }" | tr 'A-F' 'a-f')
  BR_GATE_HEAD="$cur"
  st=$(br_load "$p" "$ck")
  # NO REAL RUNG RAN. A rung that could not START spends no counter
  # (br_setup_blocked), so a ladder terminal over zero counters whose newest
  # real attempt is a `-blocked` one is a machine problem, never a ladder that
  # ran out. Bookkeeping attempts (holds, stalls, a head reset) are read past.
  case "$(br_action "$reason")" in
    ladder|fix-round|adjudicate)
      if [ $(( $(br_num "$st" mechanicals) + $(br_num "$st" regens) + $(br_num "$st" fixrounds) + $(br_num "$st" adjudications) )) -eq 0 ] \
         && [ "$(printf '%s' "$st" | jq -r '[.attempts[]? | select((.action // "") | (. == "held" or . == "stalled" or . == "stall-cleared" or . == "head-reset" or startswith("hold-")) | not)] | last | (.action // "") | endswith("-blocked")' 2>/dev/null)" = true ]; then
        k=$(printf '%s' "$st" | jq -r '[.attempts[]? | select((.action // "") | endswith("-blocked"))] | length' 2>/dev/null)
        say "$p/$ck [$reason]: HEAD GATE — no real rung ran (${k:-?} attempts could not START) — nothing closed; the ladder is not exhausted"
        return 5
      fi ;;
  esac
  rh=$(printf '%s' "$st" | jq -r --arg u "$url" 'if .rung_pr == $u then (.rung_head // "") else "" end' 2>/dev/null)
  [ -n "$rh" ] || return 0
  if ! br_is_sha "$cur"; then
    say "$p/$ck [$reason]: HEAD GATE — the PR's head '${cur:-empty}' is not a full sha, and the last counted rung ran on ${rh:0:12} — nothing closed, retried next tick"
    return 75
  fi
  [ "$cur" = "$rh" ] && return 0
  fh=$(printf '%s' "$st" | jq -r --arg u "$url" 'if .fix_pr == $u then (.fix_head // "") else "" end' 2>/dev/null | tr 'A-F' 'a-f')
  [ -n "$fh" ] && [ "$cur" = "$fh" ] && return 0
  lt=$(printf '%s' "$st" | jq -r --arg u "$url" 'if (.ladder_reset.url // "") == $u then (.ladder_reset.to // "") else "" end' 2>/dev/null)
  [ -n "$lt" ] && [ "$cur" = "$lt" ] && return 0
  br_head_reset "$p" "$ck" "$reason" "$url" "$rh" "$cur"
}

# br_head_reset <project> <cap-key> <reason> <pr-url> <rung-head> <new-head>
#   ONE write: mechanicals, regens and fixrounds go to 0, head_resets +1, one
#   `head-reset` attempt, and ladder_reset {url, from, to, at, base}. rebuilds,
#   rebuild_jobs and adjudications stay: the rebuild cap is the ticket's spend
#   cap, and a rebuild does not run on a head. base.fixround is the fix-round
#   count the pr_attempts rows already hold for this PR, which br_cap_rows
#   subtracts, so the rows cannot undo the reset on the next tick. The event and
#   the log line come only after the write landed. rc 5 reset (or WOULD, in
#   observe mode), rc 75 the write failed.
br_head_reset() {
  local p="$1" ck="$2" reason="$3" url="$4" from="$5" to="$6" st was
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$ck [$reason]: HEAD GATE — WOULD reset the ladder: the last counted rung ran on ${from:0:12} and the PR is on ${to:0:12} now — observe mode, nothing closed"
    return 5
  fi
  st=$(br_load "$p" "$ck")
  was="mechanical $(br_num "$st" mechanicals), regenerate $(br_num "$st" regens), fix round $(br_num "$st" fixrounds)"
  st=$(printf '%s' "$st" | jq -c --arg u "$url" --arg f "$from" --arg h "$to" --arg r "$reason" --arg t "$(STAMP)" \
      --arg d "the last counted rung ran on ${from:0:12} and the PR is on ${to:0:12} now: the ladder starts again on the new head (was $was); nothing closed" '
    (if (.ladder_reset.url // "") == $u then (.ladder_reset.base.fixround // 0) else 0 end) as $b
    | .ladder_reset = {url:$u, from:$f, to:$h, at:$t, base:{fixround:($b + (.fixrounds // 0))}}
    | .mechanicals = 0 | .regens = 0 | .fixrounds = 0
    | .head_resets = ((.head_resets // 0) + 1)
    | .attempts += [{at:$t, action:"head-reset", reason:$r, detail:$d, url:$u, head:$h}]
    | .updated = $t' 2>/dev/null) || st=""
  if [ -z "$st" ] || ! br_save "$p" "$ck" "$st"; then
    say "$p/$ck [$reason]: HEAD GATE — the PR moved from ${from:0:12} to ${to:0:12}, and the reset could not be written — nothing closed, retried next tick"
    return 75
  fi
  br_event resolver_head_reset "$p" "$ck" "$reason" "the last counted rung ran on ${from:0:12}, the PR is on ${to:0:12}: counts reset (was $was), nothing closed"
  say "$p/$ck [$reason]: HEAD RESET — the last counted rung ran on ${from:0:12} and $url is on ${to:0:12} now; the ladder starts again on the new head (was $was); nothing closed"
  return 5
}

# br_close_facts <project> <cap-key> <pr-url> — the paragraph a ladder close
#   appends to its comment: the head the gate read in this call and what the
#   ladder counted. Printed with two leading newlines, so it ends the body.
br_close_facts() {
  # The counts the close decided with (BH-8328, zr_counts), when it is loaded.
  local zc=""
  command -v zr_counts >/dev/null 2>&1 && zc=$(zr_counts "$1" "$2" "${3:-}" close 2>/dev/null)
  br_load "$1" "$2" | jq -r --arg h "${BR_GATE_HEAD:-}" --arg u "${3:-}" --arg zc "$zc" '
    ($zc | split(" ")) as $z
    | (if ($z | length) == 3 then {m:$z[0], r:$z[1], f:$z[2]}
       else {m:(.mechanicals // 0), r:(.regens // 0), f:(.fixrounds // 0)} end) as $c
    | "\n\nJudged head: \(if $h == "" then "not read (the PR is not open)" else $h end). "
    + "Last counted rung ran on: \(if .rung_pr == $u and (.rung_head // "") != "" then .rung_head else "not recorded" end). "
    + "Rungs counted since the last head reset: mechanical \($c.m), regenerate \($c.r), fix round \($c.f). "
    + "Ticket-wide: adjudicate \(.adjudications // 0), rebuild \([(.rebuilds // 0), ((.rebuild_jobs // []) | length)] | max). "
    + "Attempts that could not start (not counted): \([.attempts[]? | select((.action // "") | endswith("-blocked"))] | length)."' 2>/dev/null
}
