# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9952-rung-bound.sh — BH-9952: one rung has a time
# bound from a knob row. A rung past its bound is ended and recorded, and the
# tick goes to the next candidate.
#
# WHY. On 2026-11-24 one rung (cromford #9700) took 569 s of a 581 s
# loop, and the tick ended on tick-budget with rungs=0/100.
#
# HOW. Three call sites in the drain loop of bin/blocked-resolver.sh:
#   brrb_begin   parent, before the rung subshell: knobs, the marker path
#   brrb_arm     inside the rung subshell, after the key flock: the watchdog
#   brrb_end     parent, after the subshell: rc 0 when the bound fired, and
#                the driver then sets RC=124 (a rung that ran: N+1)
# The watchdog is one background subshell. It closes every inherited fd above
# 2 (the key lock and the lane lock stay with their owners), sleeps
# BR_RUNG_MAX_SECS, and when the rung is still alive writes `fired` to the
# marker, sends TERM to the rung's process tree, waits
# BR_RUNG_KILL_GRACE_SECS, and sends KILL to what is left. The rung's own TERM
# trap (br_wt_drop, br_round_end, exit 143) is the path a reaper kill takes.
# The tree walk is _mc_kill_tree's rule (bin/lib/fanin.sh): children first, a
# process in another session (a setsid lane) and its subtree are skipped, and
# the watchdog skips itself.
#
# THE MARKER: $ST/.rung-bound[-<project>].<lane pid>, at depth 1 of $ST (no
# record glob reads it). Lines: the watchdog pid, then `fired`, then `done`.
# brrb_end removes it. A tick killed during a rung leaves one small file; the
# watchdog then finds its target gone (kill -0) and exits after its sleep.
#
# "RECORDED" is the log line, the profile row's rc 124 and the prof line's
# rung_bound=<n>. There is NO attempt row on the ticket record on purpose: an
# unfiltered attempt would hide a rebuild-fresh in flight from
# br_from_rebuilds (the project-5 #1645 shape).
#
# Knobs (catalog/lanes.d/blocked-resolver.knobs.d/):
#   BR_RUNG_MAX_SECS         0   0 = no bound: brrb_arm starts nothing
#   BR_RUNG_KILL_GRACE_SECS  30  seconds between TERM and KILL
# BR_OPT_OFF=bh-9952-rung-bound does not source this file: no bound.

# brrb_knob <name> <default> <min> <max> — an integer knob into $_BRRB_V. A
#   non-number is said once per run and the default is used; it is clamped.
brrb_knob() {
  local n="$1" d="$2" lo="$3" hi="$4" v
  v="${!n:-$d}"
  case "$v" in
    ''|*[!0-9]*|?????????*)
      case " ${_BRRB_SAID:-} " in
        *" $n "*) ;;
        *) say "$n is '$v', not a number — the fallback $d is used"
           _BRRB_SAID="${_BRRB_SAID:-} $n" ;;
      esac
      v="$d" ;;
  esac
  v=$((10#$v))
  [ "$v" -ge "$lo" ] || v="$lo"
  [ "$v" -le "$hi" ] || v="$hi"
  _BRRB_V="$v"
}

# brrb_begin — before the rung subshell: the bound, the grace, a clean marker.
brrb_begin() {
  brrb_knob BR_RUNG_MAX_SECS 0 0 7200; BRRB_BOUND="$_BRRB_V"
  brrb_knob BR_RUNG_KILL_GRACE_SECS 30 1 600; BRRB_GRACE="$_BRRB_V"
  BRRB_MARK="$ST/.rung-bound${ONLY:+-$ONLY}.$$"
  rm -f "$BRRB_MARK" 2>/dev/null
  return 0
}

# brrb_kill_tree <sig> <root pid> [skip pid] — <sig> to <root> and every
# descendant in ITS session, children first. <skip pid> and its subtree are
# left alone. With no `ps`, only <root> is signalled. Always rc 0.
brrb_kill_tree() {
  local sig="$1" root="$2" skip="${3:-}" sid p k ks i=0
  local -a q=()
  [[ "$root" =~ ^[0-9]+$ ]] || return 0
  if ! command -v ps >/dev/null 2>&1; then kill -"$sig" "$root" 2>/dev/null; return 0; fi
  sid=$(ps -o sid= -p "$root" 2>/dev/null | tr -d ' ')
  q=("$root")
  while [ "$i" -lt "${#q[@]}" ]; do
    p=${q[$i]}; i=$((i + 1))
    for k in $(ps -o pid= --ppid "$p" 2>/dev/null); do
      [ "$k" = "$skip" ] && continue
      ks=$(ps -o sid= -p "$k" 2>/dev/null | tr -d ' ')
      [ -n "$sid" ] && [ -n "$ks" ] && [ "$ks" != "$sid" ] && continue
      q+=("$k")
    done
  done
  for ((i = ${#q[@]} - 1; i >= 0; i--)); do kill -"$sig" "${q[$i]}" 2>/dev/null; done
  return 0
}

# brrb_arm — inside the rung subshell, after the key flock. With a bound above
# 0, one background watchdog for this subshell ($BASHPID).
brrb_arm() {
  [ "${BRRB_BOUND:-0}" -gt 0 ] && [ -n "${BRRB_MARK:-}" ] || return 0
  local target="$BASHPID" b="$BRRB_BOUND" g="${BRRB_GRACE:-30}" m="$BRRB_MARK" wp
  (
    trap - EXIT TERM INT HUP
    exec </dev/null >/dev/null 2>&1
    # The key lock (fd 9) and the lane lock (fd 8) must not live on in here.
    for wp in /proc/"$BASHPID"/fd/*; do
      wp="${wp##*/}"
      case "$wp" in 0|1|2|255|*[!0-9]*) ;; *) eval "exec $wp>&-" 2>/dev/null ;; esac
    done
    sleep "$b"
    kill -0 "$target" 2>/dev/null || exit 0
    printf 'fired\n' >> "$m"
    brrb_kill_tree TERM "$target" "$BASHPID"
    sleep "$g"
    kill -0 "$target" 2>/dev/null && brrb_kill_tree KILL "$target" "$BASHPID"
    printf 'done\n' >> "$m"
  ) &
  wp=$!
  if [ -z "$wp" ]; then
    say "the rung watchdog did not start — this rung runs with no bound"
    return 0
  fi
  printf '%s\n' "$wp" >> "$m" 2>/dev/null \
    || say "the rung watchdog marker $m was not written — a bound kill of this rung is not recorded"
  return 0
}

# brrb_end <project> <rkey> <src> <reason> — after the rung subshell. Ends the
# watchdog when it still runs. rc 0 (and one line) when the bound fired.
brrb_end() {
  local m="${BRRB_MARK:-}" wp="" fired=0 dn=0 line
  [ -n "$m" ] && [ -f "$m" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      fired) fired=1 ;;
      done) dn=1 ;;
      ''|*[!0-9]*) ;;
      *) [ -n "$wp" ] || wp="$line" ;;
    esac
  done < "$m"
  [ -n "$wp" ] && [ "$dn" != 1 ] && brrb_kill_tree TERM "$wp"
  rm -f "$m" 2>/dev/null
  [ "$fired" = 1 ] || return 1
  BRRB_FIRED=$(( ${BRRB_FIRED:-0} + 1 ))
  say "$1/$2: the rung ran past BR_RUNG_MAX_SECS=${BRRB_BOUND:-?} — ended (reason=rung-bound, source $3, park $4); the tick goes to the next candidate"
  return 0
}
