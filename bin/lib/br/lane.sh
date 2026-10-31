#!/bin/bash
# shellcheck shell=bash
# module: lane
# bin/lib/br/lane.sh — BH-7630: the resolver on a Fly LANE MACHINE (LANE_RUN_ID
# set, no project clones). The placement tests (br_fix_hops, br_lane_no_clone),
# the hop of a FREE rung (mechanical, regen:<next>) to the owning box, the heal
# of a lost write-back, and the setup-blocked rate alert. Sourced by
# bin/blocked-resolver.sh, never run; sourcing defines functions and reads
# SETUP_BLOCKED_ALERT_N, nothing else. Reads $H, $ST, $REPOS and the say/br_*
# helpers at CALL time. Moved here from the driver so
# tests/br/driver-ceiling.tsv holds (BH-5241).

# More rungs than this that could not START on one placement in one hour send
# ONE alert per project (br_setup_rate, BH-7630). Not a number: 2.
SETUP_BLOCKED_ALERT_N="${BR_SETUP_BLOCKED_ALERT_N:-2}"
case "$SETUP_BLOCKED_ALERT_N" in ''|*[!0-9]*) SETUP_BLOCKED_ALERT_N=2 ;; esac
# Seconds that one rate alert holds the next one for that project, and holds
# every per-park page of it (comment 6315926752, operator 2026-10-21: "rc=4
# repeats within 24h raise one alert per project, not one per PR"). Not a
# number, or under an hour: 86400.
SETUP_BLOCKED_ALERT_HOLD_S="${BR_SETUP_BLOCKED_ALERT_HOLD_S:-86400}"
case "$SETUP_BLOCKED_ALERT_HOLD_S" in ''|*[!0-9]*) SETUP_BLOCKED_ALERT_HOLD_S=86400 ;; esac
[ "$SETUP_BLOCKED_ALERT_HOLD_S" -ge 3600 ] || SETUP_BLOCKED_ALERT_HOLD_S=86400

# The window the setup-blocked rows are counted over, in seconds (br_setup_rate,
# br_placement_check). br_rate_window sets RATE_WINDOW_S once a run, from the
# settings row lib.br.lane.rate_window_s, then ${BR_RATE_WINDOW_S}, then 3600.
RATE_WINDOW_S=""
br_rate_window() {
  local v=""
  [ -n "$RATE_WINDOW_S" ] && return 0
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get lib.br.lane.rate_window_s 2>/dev/null 7>&- 8>&-)
  case "$v" in ''|*[!0-9]*|0) v="${BR_RATE_WINDOW_S:-}" ;; esac
  case "$v" in ''|*[!0-9]*|0) v=3600 ;; esac   # the fallback of lib.br.lane.rate_window_s
  RATE_WINDOW_S="$v"
}

# br_fix_hops — rc 0 when this run QUEUES its fix rounds for the owning box
# (fix_round_jobs) instead of running them here: the hub, and a Fly lane
# machine (LANE_RUN_ID set), which has no project clones (BH-7630). The owning
# box's --fix-here run always works here.
br_fix_hops() {
  [ "${BR_FIX_HERE:-0}" = 1 ] && return 1
  [ -n "${LANE_RUN_ID:-}" ] && return 0
  command -v hub_box_builds_here >/dev/null 2>&1 && ! hub_box_builds_here
}

# br_lane_no_clone <project> — rc 0 on a lane machine with no clone of the
# project: a rung that needs a working tree cannot run there (BH-7630).
br_lane_no_clone() {
  [ -n "${LANE_RUN_ID:-}" ] && [ ! -d "$REPOS/${1:-}/.git" ]
}

# br_hop_rung <rung> <p> <rkey> <reason> <url> <rec> <tkey> — queue a FREE rung
#   (mechanical, or regen:<next>) for the owning box (BH-7630). No slot gate and
#   no fix-round cap here: nothing paid runs unless the box's rung fails, and
#   then the box's br_fix_round applies the cap on the record it was handed.
#   THE ARCHIE-FIRST GATE (BH-4585) RUNS HERE, BEFORE THE ROW IS QUEUED: the box
#   runs the hopped rung under BR_FIX_HERE=1, where br_fix_round skips the gate,
#   so a conflict that still stands there would reach the paid round while
#   Archie (archie-fm) owns the head. When Archie owns it, nothing is queued and
#   the park is offered again next tick (rc 0).
br_hop_rung() {
  local r="$1" p="$2" rkey="$3" reason="$4" url="$5" rec="$6" tkey="$7" ck hot=0
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  br_archie_first "$p" "$rkey" "$reason" "$url" "$ck" || return 0
  if command -v priority_rank_meta >/dev/null 2>&1 && [ "${rec:--}" != - ] \
     && [ "$(priority_rank_meta "$rec/ticket-meta.json" "$H")" = 0 ]; then hot=1; fi
  BR_HOP_RUNG="$r" br_fix_remote "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$ck" "$hot"
}

# br_placement_check — WHILE THE LANE IS PLACED FLY, the hub reads the rows the
#   lane machines' write-backs brought in (state/blocked-resolver/*/
#   setup-blocked.tsv, br_setup_rate). More than SETUP_BLOCKED_ALERT_N fly rows
#   in the last hour send ONE warning that names the kill row (BH-7630). It
#   reads and warns only: it never changes the placement or stops the dispatch.
br_placement_check() {
  local now sum
  command -v lp_decide >/dev/null 2>&1 || return 0
  LP_PLACE=hub; LP_WHY=""
  lp_decide blocked-resolver
  [ "$LP_PLACE" = fly ] || return 0
  br_rate_window
  now=$(date -u +%s)
  sum=$(for f in "$ST"/*/setup-blocked.tsv; do
          [ -r "$f" ] || continue
          awk -F'\t' -v c=$((now - RATE_WINDOW_S)) -v p="$(basename "$(dirname "$f")")" \
            '$2 == "fly" && $1 ~ /^[0-9]+$/ && $1 > c { n++; k[$3] = 1 }
             END { if (n) { s = ""; for (x in k) s = s (s == "" ? "" : ",") x; printf "%s\t%d\t%s\n", p, n, s } }' "$f"
        done)
  [ -n "$sum" ] || return 0
  local total projects classes
  total=$(printf '%s\n' "$sum" | awk -F'\t' '{ t += $2 } END { print t + 0 }')
  [ "$total" -gt "$SETUP_BLOCKED_ALERT_N" ] || return 0
  projects=$(printf '%s\n' "$sum" | awk -F'\t' '{ print $1 ":" $2 }' | sort | tr '\n' ' ')
  classes=$(printf '%s\n' "$sum" | cut -f3 | tr ',' '\n' | sort -u | tr '\n' ',')
  say "placement check: lane_placement.blocked-resolver=fly and $total rung(s) could not START on Fly in the last hour (${projects% }) — warned"
  "$H/bin/lane-alert.sh" --id lane-placement-unready-blocked-resolver --severity warn blocked-resolver \
    "lane_placement.blocked-resolver=fly ($LP_WHY) but $total rung(s) could not START on the Fly lane machines in the last hour (${projects% }, classes ${classes%,}). Set it back: bin/jobs-client.sh setting-set lane_placement.blocked-resolver hub." \
    >/dev/null 2>&1 || true
  return 0
}

# br_setup_class <what> — the machine reason, as one word for the counter.
br_setup_class() {
  case "${1:-}" in
    *"no local clone"*)       echo no-clone ;;
    "mc_rebase rc="*)         echo mc-rebase-setup ;;
    *"worktree add failed"*)  echo worktree ;;
    *"no non-hub box owns"*)  echo no-owner-box ;;
    *"no repo/branch"*)       echo no-branch ;;
    *"will not resolve"*)     echo ref-unresolved ;;
    *)                        echo other ;;
  esac
}

# br_setup_rate <project> <rung> <rkey> <what> <need> — EVERY rung that could
#   not START is one row in state/blocked-resolver/<p>/setup-blocked.tsv
#   (epoch, placement, class, rung, rkey), the episode marker below or not
#   (BH-7630: 156 blocks on one day sent no page). The file keeps one hour of
#   rows; each write drops the older ones. More than SETUP_BLOCKED_ALERT_N rows
#   of this run's placement in the hour send ONE alert, and the marker
#   setup-blocked.alerted (its epoch inside) holds the next one for
#   SETUP_BLOCKED_ALERT_HOLD_S (24 h). The marker is written before the send,
#   so a failed send loses one alert and never repeats it.
#   ONE ALERT PER PROJECT, NOT ONE PER PR (comment 6315926752): while the hold
#   stands, BR_SETUP_RATE_HELD=1 tells br_setup_blocked to send no per-park
#   page. The record, the event and the log line stay per park.
br_setup_rate() {
  local p="$1" rung="$2" rkey="$3" what="$4" need="$5" f m now place cls n at="" fix over
  BR_SETUP_RATE_HELD=0
  br_rate_window
  now=$(date -u +%s)
  place=hub; [ -n "${LANE_RUN_ID:-}" ] && place=fly
  cls=$(br_setup_class "$what")
  f="$ST/$p/setup-blocked.tsv"; m="$ST/$p/setup-blocked.alerted"
  mkdir -p "$ST/$p" 2>/dev/null || return 0
  { awk -F'\t' -v c=$((now - RATE_WINDOW_S)) '$1 ~ /^[0-9]+$/ && $1 > c' "$f" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$place" "$cls" "$rung" "$rkey"
  } > "$f.tmp" && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; return 0; }
  n=$(awk -F'\t' -v pl="$place" '$2 == pl' "$f" | wc -l)
  # The marker HOLDS THE EPOCH it was written at, not just an mtime: an empty
  # rewrite has the same sha, so the checkpoint would not carry it to the hub
  # and every later Fly run would read the hold as expired. A marker with no
  # epoch in it (an older empty one) falls back to its mtime.
  if [ -e "$m" ]; then
    at=$(head -c 32 "$m" 2>/dev/null | tr -cd '0-9')
    [ -n "$at" ] || at=$(stat -c %Y "$m" 2>/dev/null) || at=0
    [ $((now - at)) -ge "$SETUP_BLOCKED_ALERT_HOLD_S" ] || { BR_SETUP_RATE_HELD=1; return 0; }
  fi
  [ "$n" -gt "$SETUP_BLOCKED_ALERT_N" ] || return 0
  printf '%s\n' "$now" > "$m"; BR_SETUP_RATE_HELD=1
  # One id PER PROJECT, so each project's line names that project. The line
  # names how many projects are over N on the placement. Severity is warn only
  # (plan: the parks stay open and lose nothing, so it is not a page-now event).
  over=$(for g in "$ST"/*/setup-blocked.tsv; do
           [ -r "$g" ] || continue
           awk -F'\t' -v pl="$place" -v c=$((now - RATE_WINDOW_S)) '$2 == pl && $1 ~ /^[0-9]+$/ && $1 > c' "$g" | wc -l
         done | awk -v n="$SETUP_BLOCKED_ALERT_N" '$1 > n { k++ } END { print k + 0 }')
  if [ "$place" = fly ]; then
    fix="Fix: set lane_placement.blocked-resolver hub (bin/jobs-client.sh setting-set lane_placement.blocked-resolver hub) or give the lane machine a clone of $p."
  else
    fix="Needed on $(hostname 2>/dev/null || echo this box): $need."
  fi
  fix="$over projects are over $SETUP_BLOCKED_ALERT_N on placement $place. $fix"
  "$H/bin/lane-alert.sh" --id "resolver-setup-blocked-$place-$p" --severity warn blocked-resolver \
    "$p: $n rung(s) could not START in the last hour on placement $place (lane_placement.blocked-resolver); latest reason [$cls]: $what. No rung spent, the parks stand. $fix" \
    >/dev/null 2>&1 || true
  return 0
}

# br_fix_heal <project> <rkey> <reason> <cap-key> [resp-file] — A LOST
#   WRITE-BACK IS HEALED BEFORE THE LADDER READS THE CAP (BH-7630). A lane
#   machine's br_fix_adopt br_save reaches the hub only through the write-back.
#   If that is lost after the adopt, the row reads adopted and the record has
#   lost the round, so the ladder would buy a second paid round. rc 0 when the
#   ladder may run: no adopted row, or the record already holds at least the
#   attempts of the newest adopted row's record_out, or that record_out was
#   saved now. rc 1 when the adopted rows could not be read: the park is held (an
#   outage must never let a second paid round be queued). <resp-file> is the
#   list fix_round_get saved (no second GET); it is removed here.
#   THE HEAL RUNS ONLY ON A LANE MACHINE (LANE_RUN_ID set), and only from a row
#   whose answer was done: the hub saves its own adopt locally, so it has no
#   write-back to lose, and an adopted row is never re-acted there (BH-2530 N2).
#   A terminal or rebuild-fresh answer was acted on at its adopt; a record
#   restored from it would make the ladder act on that answer again.
br_fix_heal() {
  local p="$1" rkey="$2" reason="$3" ck="$4" rf="${5:-}" ro rrc=0 rjson n0 n1
  [ -n "${LANE_RUN_ID:-}" ] || { rm -f "$rf"; return 0; }
  command -v fix_round_adopted_record >/dev/null 2>&1 || { rm -f "$rf"; return 0; }
  ro=$(fix_round_adopted_record "$p" "$ck" "$rf" 2>>"$LOG") || rrc=$?
  rm -f "$rf"
  case "$rrc" in
    0) ;;
    2) return 0 ;;
    *) say "$p/$rkey [$reason]: adopted fix-round rows unreadable, park held this tick"; return 1 ;;
  esac
  rjson=$(printf '%s' "$ro" | jq -c --arg p "$p" 'select(.project == $p) | del(.hop_rung)' 2>/dev/null)
  [ -n "$rjson" ] || return 0
  n0=$(br_load "$p" "$ck" | jq '(.attempts // []) | length' 2>/dev/null)
  n1=$(printf '%s' "$rjson" | jq '(.attempts // []) | length' 2>/dev/null)
  if [ -n "$n1" ] && [ "$n1" -gt "${n0:-0}" ] 2>/dev/null; then
    br_save "$p" "$ck" "$rjson"
    say "$p/$rkey [$reason]: the record had lost an adopted round (attempts ${n0:-0} < $n1) — restored from the adopted row's record before the ladder runs"
  fi
  return 0
}

# br_hop_labels — sets what and rung (the caller's locals) for the line
# br_fix_remote says and the event it writes: the fix round, or the free rung
# BR_HOP_RUNG names (BH-7630).
br_hop_labels() {
  what="fix round"; rung="rung 2 fix-round"
  case "${BR_HOP_RUNG:-}" in
    mechanical) what="mechanical rung (fix round only if it does not clear)"; rung="rung 1 mechanical" ;;
    regen:*)    what="regenerate rung (then ${BR_HOP_RUNG#regen:})"; rung="rung 1b regenerate" ;;
  esac
}

# br_hop_record <project> <cap-key> — the record copy a queued row carries.
# THE RUNG RIDES ON THE RECORD COPY (BH-7630): the row's args are exactly six,
# so BR_HOP_RUNG (mechanical, or regen:<next>) is a hop_rung field on
# record_in. The box's --fix-here runs that free rung first and buys the agent
# round only when it does not clear the park. No BR_HOP_RUNG is the fix round.
br_hop_record() {
  br_load "$1" "$2" | jq -c --arg r "${BR_HOP_RUNG:-}" \
    'del(.hop_rung) + (if $r == "" then {} else {hop_rung:$r} end)' 2>/dev/null || br_load "$1" "$2"
}

# br_lane_hop_mech <p> <rkey> <reason> <url> <rec> <tkey> — rc 0 when rung 1 was
# handed to the owning box (or held for Archie): A LANE MACHINE WITH NO CLONE
# HANDS RUNG 1 TO THE OWNING BOX (BH-7630). mc_rebase needs a working tree and
# would answer rc 4 on every tick. The row carries hop_rung=mechanical, so the
# box runs mc_rebase and the CI re-run first and buys the agent round only if
# they do not clear the park. Nothing is recorded here; the box's record comes
# back through the adopt. rc 1: the caller runs rung 1 here as before.
br_lane_hop_mech() {
  br_lane_no_clone "$1" || return 1
  say "$1/$2 [$3]: rung 1 is not run on a lane machine with no clone of $1 — handed to the owning box"
  br_hop_rung mechanical "$@"
  return 0
}

# br_fix_here_run <record-json> <fix-here args...> — what the owning box's
# --fix-here runs. A FREE RUNG A LANE MACHINE HANDED OVER (BH-7630) rides as
# hop_rung on the record copy; it is read here and never saved, so FIX_RECORD
# carries none. The free rung runs first: mc_rebase and the CI re-run run on
# this box's clone, and its own failure arm calls br_fix_round here.
# REBASE_ON_POOL=0: a pool rebase moves a conductor row, and the conductor rows
# are the hub's.
br_fix_here_run() {
  local rung; rung=$(printf '%s' "$1" | jq -r '.hop_rung // "" | strings' 2>/dev/null); shift
  case "$rung" in
    mechanical) REBASE_ON_POOL=0 br_mechanical "${@:1:6}" ;;
    regen:*)    REBASE_ON_POOL=0 br_regen_rung "${@:1:6}" "${rung#regen:}" ;;
    *)          br_fix_round "$@" ;;
  esac
}
