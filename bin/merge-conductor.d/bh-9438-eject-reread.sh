# shellcheck shell=bash
# bin/merge-conductor.d/bh-9438-eject-reread.sh - A queue-ejected-twice PARK
# THAT CARRIES THE OLD "unknown (no Mergify dequeue reason)" LABEL IS RE-READ
# ONCE AND RE-ROUTED BY ITS REAL CAUSE (BH-9438 item 4). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block); functions only, no side
# effect at source time.
#
# WHY. Before f19be3261 (BH-9229, 2026-11-08) ec_classify read only a
# `## Reason` heading. Current Mergify writes `**Reason**` and a payload JSON,
# so ec_cause answered `unknown\tno Mergify dequeue reason` for 138 of 182
# ejections, and the settle arm parked those PRs `queue-ejected-twice: …
# unknown (no Mergify dequeue reason) …`. The parked-row pass (bin/
# merge-conductor.sh, `parked merged settle`) visits every OPEN park each tick,
# but it never read the cause again: a conflict ejection stayed a fix-round
# park, not a rebase, and the row kept the wrong label.
#
# THE RULE. mc_ejr_reread reads the cause again, once per (PR, head), for a
# park that is MISLABELLED: the newest eject-cause record line for the head is
# `unknown` with a detail that starts `no Mergify dequeue reason`, or the row
# reason holds `unknown (no Mergify dequeue reason)`. Then, by the real cause:
#   conflict    the BH-1677 `ejectconflict <key> <head>` mark (not a strike;
#               eject_rebase_arm spends its one rebase on it), the row is
#               re-reasoned `queue-ejected: conflict (…) — re-read (BH-9438); a
#               rebase, not a fix round` (not a hand-off reason) and the
#               hand-off is released. rc 0: the caller does not hand it to a
#               fix round. The next tick's pr_worker classifies it again.
#   unknown     nothing re-reasoned. rc 1. When the answer is still `no
#               Mergify dequeue reason`, the `ejreread` mark is swapped for
#               `ejreread-none-r<EC_CLASSIFY_REV> <key> <head>`: spent for
#               this classifier, so a later classifier revision (a new
#               payload code mapped) reads the head once more. Any other
#               unknown detail keeps the `ejreread` mark spent.
#   any other   the row is re-reasoned `queue-ejected-twice: <cause> (<detail>)
#               on <h8> — re-read (BH-9438)`, so the resolver readers and the
#               sticky hand-off still match. rc 1: the caller runs mc_bv_solo /
#               mc_eject_fix_now as before, now with the right label.
# Every real answer is one eject-cause record line of ord `reread` and one
# `EJECT_REREAD <key> <h8> was=unknown now=<cause> (<detail>) route=<route>`
# log line.
#
# GUARDS, in order, each rc 1: knob MC_EJECT_REREAD 0; PROVIDER not mergify;
# not mislabelled (no read); `ejreread <key> <head>` or
# `ejreread-none-r<EC_CLASSIFY_REV> <key> <head>` already written; observe
# mode (one WOULD line, no mark, no read); the per-tick cap
# MC_EJECT_REREAD_PER_TICK spent (one line; the next tick asks again). The mark
# is written BEFORE the read. A read that fails (`dequeue comments
# unreadable`) clears the mark and counts one `ejreread-unread` line; the
# MC_EJECT_REREAD_UNREAD_MAX-th failure on one head (default 3) keeps the mark,
# so a lasting outage costs that many reads, not one a tick.
#
# KNOBS (catalog/lanes.d/merge-conductor.knobs.d/, read through ec_knob):
#   MC_EJECT_REREAD=1            0 = off: no re-read, the park as before
#   MC_EJECT_REREAD_PER_TICK=10  comment reads per project per tick, 0 = off
#   MC_EJECT_REREAD_UNREAD_MAX=3 unreadable answers per (PR, head) before the
#                                mark stays spent (min 1)

# mc_ejr_mislabelled <slug> <num> <head> <row-reason> — rc 0 when the park
#   carries the old label (see the header). Pure reads, no network.
mc_ejr_mislabelled() {
  local f l c d
  case "${4:-}" in *"unknown (no Mergify dequeue reason)"*) return 0 ;; esac
  command -v ec_file >/dev/null 2>&1 && command -v _ec_find >/dev/null 2>&1 || return 1
  f=$(ec_file "$1" "$2") || return 1
  l=$(_ec_find "$f" "$3"); [ -n "$l" ] || return 1
  IFS=$'\t' read -r _ _ _ c d <<<"$l"
  [ "$c" = unknown ] || return 1
  case "$d" in "no Mergify dequeue reason"*) return 0 ;; esac
  return 1
}

# mc_ejr_reread <project> <slug> <key> <head> <url> <row-reason> — see the
#   header. Reads PROVIDER and ACTIONS from the caller's scope. rc 0 only on the
#   conflict route.
mc_ejr_reread() {
  local p="$1" slug="$2" key="$3" head="$4" url="$5" why="${6:-}" num cap ec cause detail cw n
  local rec v rev umax
  [ -n "$key" ] && [ -n "$head" ] && [ "$head" != - ] || return 1
  command -v ec_cause >/dev/null 2>&1 && command -v ec_record >/dev/null 2>&1 && command -v ec_knob >/dev/null 2>&1 || return 1
  # Fallback 1: catalog MC_EJECT_REREAD.json, row lane.merge-conductor.mc_eject_reread.
  [ "$(ec_knob MC_EJECT_REREAD 1)" = 0 ] && return 1
  [ "${PROVIDER:-}" = mergify ] || return 1
  num="${key##*#}"
  mc_ejr_mislabelled "$slug" "$num" "$head" "$why" || return 1
  mc_attempt_has "ejreread $key $head" 2>/dev/null && return 1
  mc_attempt_has "ejreread-none-r${EC_CLASSIFY_REV:-1} $key $head" 2>/dev/null && return 1
  if [ "${ACTIONS:-0}" != 1 ]; then
    mc_log "$key would re-read the queue-ejected-twice cause of ${head:0:8} (old label: unknown (no Mergify dequeue reason)) — observe mode: nothing read"
    return 1
  fi
  # Fallback 10: catalog MC_EJECT_REREAD_PER_TICK.json, row
  # lane.merge-conductor.mc_eject_reread_per_tick. 0 = off.
  cap=$(ec_knob MC_EJECT_REREAD_PER_TICK 10)
  [ "$cap" -gt 0 ] 2>/dev/null || return 1
  if ! mc_tick_budget_take "$p" ejreread "$cap"; then
    mc_log "$key eject re-read of ${head:0:8} waits — this tick's $cap re-reads (MC_EJECT_REREAD_PER_TICK) are spent; the next tick asks again"
    return 1
  fi
  mc_attempt_put "ejreread $key $head"
  ec=$(ec_cause mergify "$slug" "$url" "$head")
  cause="${ec%%$'\t'*}"; detail=""
  [ "$ec" != "$cause" ] && detail="${ec#*$'\t'}"
  if [ "$cause" = unknown ] && [ "$detail" = "dequeue comments unreadable" ]; then
    n=$(mc_attempt_count ejreread-unread "$key" "$head")
    mc_attempt_put_n ejreread-unread "$key" "$head"
    n=$((n + 1))
    # Fallback 3: catalog MC_EJECT_REREAD_UNREAD_MAX.json, row
    # lane.merge-conductor.mc_eject_reread_unread_max (min 1).
    umax=$(ec_knob MC_EJECT_REREAD_UNREAD_MAX 3)
    [ "$umax" -ge 1 ] 2>/dev/null || umax=1
    if [ "$n" -lt "$umax" ]; then
      mc_attempt_clear ejreread "$key" "$head"
      mc_log "$key eject re-read of ${head:0:8}: the dequeue comments could not be read (try $n of $umax) — asked again next tick"
    else
      mc_log "$key eject re-read of ${head:0:8}: the dequeue comments could not be read $umax times (MC_EJECT_REREAD_UNREAD_MAX) — not asked again for this head; the park keeps its label"
    fi
    return 1
  fi
  ec_record "$slug" "$num" "$head" reread "$cause" "$detail"
  cw="$cause${detail:+ ($detail)}"
  if [ "$cause" = unknown ]; then
    case "$detail" in "no Mergify dequeue reason"*)
      mc_attempt_put "ejreread-none-r${EC_CLASSIFY_REV:-1} $key $head"
      mc_attempt_clear ejreread "$key" "$head"
      mc_log "EJECT_REREAD $key ${head:0:8} was=unknown now=$cw route=none — still no cause for classifier r${EC_CLASSIFY_REV:-1}; the park stands, read again when the classifier changes"
      return 1 ;;
    esac
    mc_log "EJECT_REREAD $key ${head:0:8} was=unknown now=$cw route=none — still no cause; the park stands"
    return 1
  fi
  rec=$(mc_record_for "$url" || true)
  IFS=$'\t' read -r v _ _ _ _ <<<"$(mc_verdict "$url" "$rec")"
  rev=$(mc_row_field "$key" 5); [ -n "$rev" ] || rev=-
  if [ "$cause" = conflict ]; then
    mc_attempt_has "ejectconflict $key $head" 2>/dev/null || mc_attempt_put "ejectconflict $key $head"
    mc_transition "$key" BLOCKED_HUMAN "queue-ejected: $cw — re-read (BH-9438); a rebase, not a fix round" \
      "$head" "$rev" "$url" "${v:--}" UNKNOWN "${rec:--}" >/dev/null
    mc_handoff_release "$key" eject-reread
    mc_log "EJECT_REREAD $key ${head:0:8} was=unknown now=$cw route=rebase — ejectconflict marked, hand-off released; the next tick classifies it again"
    return 0
  fi
  mc_transition "$key" BLOCKED_HUMAN "queue-ejected-twice: $cw on ${head:0:8} — re-read (BH-9438)" \
    "$head" "$rev" "$url" "${v:--}" UNKNOWN "${rec:--}" >/dev/null
  mc_log "EJECT_REREAD $key ${head:0:8} was=unknown now=$cw route=park — re-labelled; the fix-round hand-over goes on"
  return 1
}
