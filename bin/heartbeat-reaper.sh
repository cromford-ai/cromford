#!/bin/bash
# bin/heartbeat-reaper.sh — the READER half of the lane-liveness heartbeat (BH-638), one pass per
# hub cron tick (*/5) over state/heartbeat/<lane>.<pid>.json. Pages ONCE per lane instance that is
# no longer alive, collapses a wave into one line, resolves when a lane comes back, relaunches only
# a dead lane that declared `restart`. NO LOCK, NO SIGNAL (kill -0 is a probe), nothing waits on it.
# Knobs (read from env/global.env below): HB_STALE_MULT 3, HB_SILENT_FLOOR_S 120 (0 = off),
# HB_MASS_STALE_N 3, HB_RESTART_PER_HOUR 3, HB_STALE_GC_S 86400. A `cron` lane is judged by its
# completion stamp in state/heartbeat-done/<lane> instead of its dead files (BH-4717). The states, the ids and what this cannot see: docs/verification-map/lane-heartbeat.md.
# Usage: heartbeat-reaper.sh   (no arguments; reads this box's own files)
set -uo pipefail
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-heartbeat-reaper
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off heartbeat-reaper.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit heartbeat-reaper
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    heartbeat-reaper
# THE KNOBS, READ HERE: the cron line is this script and nothing else, so a knob only the environment
# could carry is a knob nobody can turn. `HB_<NAME>=<digits>` lines only, environment wins. NOT
# `set -a; . global.env`: the restart branch nohups a lane and would hand that child every secret.
if [ -r "$HENV/global.env" ]; then
  while IFS= read -r _kv; do _k="${_kv%%=*}"; [ -n "${!_k:-}" ] || export "${_kv?}"; done \
    < <(sed -n 's/^\(export \)\{0,1\}\(HB_[A-Z_]*=[0-9][0-9]*\)$/\2/p' "$HENV/global.env" 2>/dev/null)
fi
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$SELF" ] || SELF="$H/bin"
mkdir -p "$H/logs" 2>/dev/null; LOG="$H/logs/heartbeat-reaper.log"
STAMP() { date -u '+%F %TZ'; }; log() { printf '%s %s\n' "$(STAMP)" "$*" >> "$LOG" 2>/dev/null || true; }
reaper_alert() { # reaper_alert <text> — one ALERTS line through bin/alert-line.sh
  if [ -x "$H/bin/alert-line.sh" ]; then
    HARNESS="$H" "$H/bin/alert-line.sh" "[orchestrator/heartbeat-reaper] $1"
  else
    # raw fallback kept (BH-2365): this lane pages exactly when bin/ is partial, and alert-line.sh may be the missing file
    printf '%s [orchestrator/heartbeat-reaper] %s\n' "$(STAMP)" "$1" >> "$H/logs/ALERTS.log" 2>/dev/null
  fi
}
# shellcheck source=bin/lib/heartbeat.sh
for _l in "$SELF/lib/heartbeat.sh" "$H/bin/lib/heartbeat.sh"; do [ -r "$_l" ] && { . "$_l"; break; }; done
# shellcheck source=bin/lib/alert-state.sh
for _l in "$SELF/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"; do [ -r "$_l" ] && { . "$_l"; break; }; done
if ! command -v hb_state >/dev/null 2>&1; then
  # Fail towards paging: worse than a dead lane is a dead lane detector nobody is told about.
  reaper_alert "bin/lib/heartbeat.sh is missing on this box — NO lane liveness check ran"
  log "bin/lib/heartbeat.sh missing — nothing was checked"
  exit 2
fi

DIR="$(hb_dir)"; RLOG="$DIR/restarts.log"; NOW=$(hb_now)
BOOT="${HB_BOOT_AT:-}"
if [ -z "$BOOT" ] && [ -r /proc/uptime ]; then
  UP=$(cut -d' ' -f1 /proc/uptime 2>/dev/null); UP="${UP%%.*}"
  case "$UP" in ''|*[!0-9]*) ;; *) BOOT=$(( NOW - UP )) ;; esac
fi
num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$1" ;; esac; }
iso() { local e; e=$(num "${1:-0}" 0); [ "$e" -gt 0 ] || { printf '%s' 'none'; return 0; }
        date -u -d "@$e" '+%F %TZ' 2>/dev/null || printf '%s' "$e"; }
send() { # send <id> <text> — lane-alert.sh is the point (log + beat), so its absence is worth saying.
  local id="$1"; shift
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --id "$id" heartbeat-reaper "$*" >/dev/null 2>&1 || true
  else
    reaper_alert "$*"
    log "bin/lane-alert.sh missing — wrote the line straight into ALERTS.log"
  fi
}
resolve() { # resolve <id> <text> — close a condition this pass opened. lane-alert is silent on an
  local id="$1"; shift   # unknown or closed id, so a recovery nobody was paged about stays quiet.
  [ -x "$H/bin/lane-alert.sh" ] || return 0   # no pager, nothing to retract against
  "$H/bin/lane-alert.sh" --resolve --id "$id" heartbeat-reaper "$*" >/dev/null 2>&1 || true
}
# restart_outcome — the alert's restart clause, written FROM the outcome.
restart_outcome() {
  local lane="$1" st="$2" spec="$3" f="$4" cap n pre=""
  [ -n "$spec" ] || { printf 'not restartable (it declared no restart command)'; return 0; }
  [ "$st" = dead ] || { printf 'not relaunched (it is %s, not dead)' "$st"; return 0; }
  # SPLIT ON WHITESPACE, NEVER HANDED TO A SHELL: `bash -c "$spec"` would be arbitrary code out of a state file.
  local -a cmd=(); read -r -a cmd <<<"$spec"
  [ "${#cmd[@]}" -gt 0 ] || { printf 'restart refused: the command is empty'; return 0; }
  case "${cmd[0]}" in /*) ;; *) printf 'restart refused: %s is not an absolute path' "${cmd[0]}"; return 0 ;; esac
  [ -x "${cmd[0]}" ] || { printf 'restart refused: %s is not an executable file' "${cmd[0]}"; return 0; }
  cap=$(num "${HB_RESTART_PER_HOUR:-3}" 3)
  n=$(awk -F'\t' -v l="$lane" -v c="$(( NOW - 3600 ))" '$1+0>=c && $2==l {n++} END{print n+0}' "$RLOG" 2>/dev/null)
  n=$(num "$n" 0)
  [ "$n" -lt "$cap" ] || { printf 'restart cap reached (%s in the last hour, cap %s) — not relaunched' "$n" "$cap"; return 0; }
  # Ledgered BEFORE the launch: an exec that fails must still count, or a broken command is retried all hour.
  printf '%s\t%s\t%s\n' "$NOW" "$lane" "$spec" >> "$RLOG" 2>/dev/null
  # fd 9 is closed first so the child can never inherit a lane's own exclusive file handle (wake-loop's).
  command -v setsid >/dev/null 2>&1 && pre=setsid
  # AND HARNESS_SECRET IS STRIPPED (BH-1165 review). The lane header above
  # sources bin/lib/lane-gate.sh, which sources bin/jobs-client.sh to reach the
  # pause_flags row — and that file EXPORTS HARNESS_SECRET, so this nohup'd
  # child would inherit the fleet bearer from a parent that deliberately refuses
  # to `set -a; . global.env` for exactly that reason. The relaunched lane reads
  # the secret itself, from the same env file, the way cron's copy of it does.
  # shellcheck disable=SC2086
  ( exec 9>&-; $pre env -u HARNESS_SECRET nohup "${cmd[@]}" </dev/null >> "$H/logs/heartbeat-restarts.log" 2>&1 & ) 2>/dev/null
  rm -f "$f" 2>/dev/null   # the relaunched lane writes its own; this one is spent
  printf 'relaunched (%s of %s this hour)' "$(( n + 1 ))" "$cap"
}

DETAILS=(); LANES=(); IDS=(); MINSTART=0; N=0; GC_S=$(num "${HB_STALE_GC_S:-86400}" 86400)
declare -A LANEID_SEEN=() DEADPAGED=()
# hb_done_at <lane> — the lane's last completion epoch from hb_done's stamp, 0 when none or unreadable.
hb_done_at() { local d e=""; d="$(hb_done_dir)"; [ -n "$d" ] || { printf 0; return 0; }
  [ -r "$d/$(_hb_slug "$1")" ] && IFS=$'\t' read -r e _ < "$d/$(_hb_slug "$1")"; num "$e" 0; }
# hb_spent <lane> <start> <file> — rc 0 and the evidence on stdout when this instance is spent: a
# later run of the SAME lane (the .lane field, never a name prefix) started after it, or the lane
# completed after it started. An equal started_at is not later.
hb_spent() {
  local lane="$1" start="$2" f="$3" i ia ip dn
  for i in "$DIR/$(_hb_slug "$lane")".*.json; do
    [ -f "$i" ] && [ "$i" != "$f" ] || continue
    IFS=$'\037' read -r ia ip < <(jq -r --arg l "$lane" 'select(.lane == $l) | [(.started_at//0),(.pid//0)] | map(tostring) | join("\u001f")' "$i" 2>/dev/null)
    ia=$(num "${ia:-}" 0)
    [ "$ia" -gt "$start" ] && { printf 'later run pid %s started at %s' "$(num "${ip:-}" 0)" "$(iso "$ia")"; return 0; }
  done
  dn=$(hb_done_at "$lane")
  [ "$dn" -gt "$start" ] && { printf 'completion stamp %s' "$(iso "$dn")"; return 0; }
  return 1
}
# The file pass can only ever speak for THIS box, so what it has spoken for is
# keyed (lane, box) — never the lane alone (round 1 on #1150). merge-conductor
# runs on several boxes (hub-lease failover is exactly when it moves), and a
# lane-only key let a stale file here swallow the ROW's finding for the same
# lane somewhere else: the one case the DB pass exists to cover, latched on and
# never paged.
SELF_BOX=$(cat "$H/state/box-name" 2>/dev/null || printf '%s' "${BOX_NAME:-}")
declare -A SEEN_LANE=()
for F in "$DIR"/*.json; do
  [ -f "$F" ] || continue
  BASE=$(basename "$F" .json)
  ST=$(hb_state "$F" "$NOW" "$BOOT")
  case "$ST" in
    fresh) continue ;;
    unparseable)  # Never skipped, never rewritten: a corrupt file is evidence, and with no jq EVERY
      # file reads this way, so the lane name comes off the FILE NAME — the body is what did not read.
      DETAILS+=("$BASE unreadable heartbeat ($F did not parse — bad JSON, or no jq on this box) — blocks: unknown — not restartable")
      LANES+=("$BASE"); IDS+=("hb-$BASE-unreadable"); N=$(( N + 1 )); SEEN_LANE["$BASE@$SELF_BOX"]=1
      log "$BASE: unreadable heartbeat $F"
      continue ;;
  esac
  # UNIT-SEPARATED, NEVER TAB: tab is IFS whitespace, so a run of delimiters COLLAPSES — a lane that
  # has not ticked has an empty `note`, `blocks` shifts into NOTE, and the alert loses its point.
  IFS=$'\037' read -r LANE PID START LT IV DL NOTE BLOCKS RESTART SA < <(
    jq -r '[(.lane//""),(.pid//0),(.started_at//0),(.last_tick//0),(.interval//0),(.deadline//0),(.note//""),(.blocks//""),(.restart//""),(.stale_at//0)]|map(tostring)|join("\u001f")' \
      "$F" 2>/dev/null)
  # The lane is a FIELD, not the file name: that is what lets two instances be two findings.
  [ -n "${LANE:-}" ] || LANE="$BASE"
  PID=$(num "$PID" 0); START=$(num "$START" 0); LT=$(num "$LT" 0); IV=$(num "$IV" 0)
  DL=$(num "$DL" 0); SA=$(num "$SA" 0)
  # A CRON LANE IS KILLED ON PURPOSE (merge-conductor runs under `timeout 240`), so its dead
  # instance is spent, not news: the lane is judged by its completion stamp in the block below.
  if [ "$ST" = dead ] && grep -q '"kind":"cron"' "$F" 2>/dev/null; then
    rm -f "$F" "$DIR-db/$BASE" 2>/dev/null
    log "$LANE: cron tick pid $PID ended without hb_done — not a page; judged by its last completed tick"
    SEEN_LANE["$LANE@$SELF_BOX"]=1
    continue
  fi
  # A SPENT INSTANCE IS NOT A DEAD LANE (BH-9114). A run that exited after a later run of the same
  # lane started, or before the lane last completed, is history: its pid is gone because it ended.
  if [ "$ST" = dead ] && SPENT=$(hb_spent "$LANE" "$START" "$F"); then
    rm -f "$F" "$DIR-db/$BASE" 2>/dev/null
    log "$LANE: pid $PID ended; $SPENT — not a page"
    SEEN_LANE["$LANE@$SELF_BOX"]=1
    continue
  fi
  if [ "$ST" = marked ]; then
    # ALREADY PAGED, so nothing is ever FIRED about this file again whatever the lane does (an
    # alive-overdue lane ticks for hours). RECOVERED = inside its rhythm AND ticked after the page
    # (the second half stops the tick already in the file at mark time reading as news).
    if [ "$(hb_state "$F" "$NOW" "$BOOT" nomark)" = fresh ] && [ "$LT" -gt "$SA" ]; then
      hb_mark_stale "$F" "$NOW" false || log "$LANE: could not clear the stale mark on $F"
      resolve "hb-$LANE" \
        "$LANE resumed ticking (pid $PID, it ticked $(( (LT - SA) / 60 ))m after the page)"
      log "$LANE: recovered, mark cleared, alert resolved"
    elif [ "$SA" -gt 0 ] && [ "$(( NOW - SA ))" -gt "$GC_S" ]; then
      rm -f "$F" "$DIR-db/$BASE" 2>/dev/null
      log "gc: removed $BASE (marked stale $(( (NOW - SA) / 3600 ))h ago, past HB_STALE_GC_S=${GC_S}s)"
    fi
    continue
  fi
  AGE=$(( NOW - LT )); [ "$AGE" -lt 0 ] && AGE=0
  ALIVE=gone; kill -0 "$PID" 2>/dev/null && ALIVE=alive
  # A pid that answers the liveness probe but last ticked before the boot is not the lane.
  [ "$ST" = dead ] && [ "$ALIVE" = alive ] && ALIVE="reused by another process, this lane last ticked before the boot"
  # MARK STALE, THEN SEND: dying between mark and send loses one alert; dying between send and mark
  # pages every five minutes for ever — the complaint this lane answers.
  hb_mark_stale "$F" "$NOW" || log "$LANE: could not mark $F stale — the next pass will page it again"
  OUTCOME=$(restart_outcome "$LANE" "$ST" "$RESTART" "$F")
  [ "$ST" = dead ] && DEADPAGED["$LANE"]=1
  log "$LANE: $ST, age ${AGE}s, pid $PID $ALIVE, $OUTCOME"
  # ONE FINDING PER LANE: the id is the lane, so a second instance in the same pass is the same page.
  if [ -n "${LANEID_SEEN[$LANE]:-}" ]; then log "$LANE: pid $PID is a second instance this pass — one page per lane"; continue; fi
  LANEID_SEEN["$LANE"]=1
  DETAILS+=("$LANE $ST for $(hb_age_text "$AGE") (pid $PID $ALIVE, interval ${IV}s, expected-by $(iso "$DL"), note: ${NOTE:--}) — blocks: ${BLOCKS:-unknown} — $OUTCOME")
  LANES+=("$LANE"); IDS+=("hb-$LANE"); N=$(( N + 1 )); SEEN_LANE["$LANE@$SELF_BOX"]=1
  { [ "$MINSTART" = 0 ] || [ "$START" -lt "$MINSTART" ]; } && [ "$START" -gt 0 ] && MINSTART=$START
done
# >>> lane markers (BH-9114) — <slug>.hbpaged (<epoch>\t<lane>) says "this lane was paged dead".
# A fresh run of the lane, or a completion stamp newer than the page, resolves hb-<lane>. A marker
# older than HB_STALE_GC_S goes with no resolve. Not *.json, so the file loop above never reads it.
for M in "$DIR"/*.hbpaged; do
  [ -f "$M" ] || continue
  MEP=""; MLANE=""; IFS=$'\t' read -r MEP MLANE < "$M" 2>/dev/null
  MEP=$(num "$MEP" 0); [ -n "$MLANE" ] || MLANE=$(basename "$M" .hbpaged)
  if [ "$(( NOW - MEP ))" -gt "$GC_S" ]; then
    rm -f "$M" 2>/dev/null; log "gc: removed $(basename "$M") (paged $(( (NOW - MEP) / 3600 ))h ago, past HB_STALE_GC_S=${GC_S}s)"
    continue
  fi
  WHY=""
  for I in "$DIR/$(_hb_slug "$MLANE")".*.json; do
    [ -f "$I" ] && [ "$(jq -r '.lane // ""' "$I" 2>/dev/null)" = "$MLANE" ] \
      && [ "$(hb_state "$I" "$NOW" "$BOOT" nomark)" = fresh ] && { WHY="is running"; break; }
  done
  [ -z "$WHY" ] && [ "$(hb_done_at "$MLANE")" -gt "$MEP" ] && WHY="completed"
  [ -n "$WHY" ] || continue
  resolve "hb-$MLANE" "a later run of $MLANE $WHY"
  rm -f "$M" 2>/dev/null
  log "$MLANE: a later run $WHY, dead page resolved"
done
# >>> cron lane staleness (BH-4717) — a lane that declared `cron` is judged by the stamp hb_done
# left in state/heartbeat-done/<lane> (<epoch>\t<interval>): older than interval x HB_STALE_MULT
# pages ONCE, id hb-cron-<lane>-<last_done>, and <lane>.paged holds the last_done it paged. A newer
# stamp resolves it whatever the gates say, since retracting a page is always safe.
DONED="$(hb_done_dir)"; CMULT=$(num "${HB_STALE_MULT:-3}" 3)
for S in "$DONED"/*; do
  [ -f "$S" ] || continue
  case "$S" in *.paged|*.tmp) continue ;; esac
  LANE=$(basename "$S"); LD=""; SIV=""
  IFS=$'\t' read -r LD SIV < "$S" 2>/dev/null
  case "$LD" in ''|*[!0-9]*) log "$LANE: unreadable completion stamp $S — skipped"; continue ;; esac
  case "$SIV" in ''|*[!0-9]*) log "$LANE: unreadable completion stamp $S — skipped"; continue ;; esac
  AGE=$(( NOW - LD )); [ "$AGE" -lt 0 ] && AGE=0
  IV=$(hb_cron_interval "$LANE" "$SIV"); IV=$(num "$IV" 60); [ "$IV" -lt 60 ] && IV=60
  THR=$(( IV * CMULT ))
  P=$(cat "$S.paged" 2>/dev/null)
  case "$P" in ''|*[!0-9]*) ;; *)
    if [ "$LD" -gt "$P" ]; then
      resolve "hb-cron-$LANE-$P" "$LANE completed a tick again (last completed $(iso "$LD"))"
      rm -f "$S.paged" 2>/dev/null; P=""
      log "$LANE: completed a tick again, cron staleness alert resolved"
    fi ;;
  esac
  [ "$AGE" -gt "$THR" ] || continue
  # A paused lane is meant to be silent: lane_paused reads all-off and lane-off-<lane> the way the
  # lane's own gate does (row first, then the file), so a stop flipped in the console counts too.
  if command -v lane_paused >/dev/null 2>&1 && lane_paused "$LANE"; then
    log "$LANE: cron staleness check skipped ($LANE_PAUSED_WHY)"; continue
  fi
  LIVEF=""
  for I in "$DIR/$LANE".*.json; do
    [ -f "$I" ] && [ "$(hb_state "$I" "$NOW" "$BOOT" nomark)" = fresh ] && { LIVEF="$I"; break; }
  done
  [ -n "$LIVEF" ] && { log "$LANE: last completed tick is $(hb_age_text "$AGE") old, but $(basename "$LIVEF") is ticking fresh — not paged"; continue; }
  [ "$P" = "$LD" ] && continue
  if [ "$(jq -r '.scope // ""' "$H/catalog/lanes.d/$LANE.json" 2>/dev/null)" = hub ] && [ -x "$H/bin/hub-lease.sh" ] \
     && ! "$H/bin/hub-lease.sh" check >/dev/null 2>&1; then
    log "$LANE: cron staleness check skipped (not the hub-lease holder)"; continue
  fi
  # MARK, THEN SEND — the file pass's order: dying between them loses one page, never repeats it.
  { printf '%s\n' "$LD" > "$S.paged.tmp" && mv -f "$S.paged.tmp" "$S.paged"; } 2>/dev/null \
    || { rm -f "$S.paged.tmp" 2>/dev/null; log "$LANE: could not write $S.paged — the next pass will page it again"; }
  DETAILS+=("$LANE has not completed a tick for $(hb_age_text "$AGE") (cron every $(( IV / 60 ))m, threshold $(( THR / 60 ))m = $(( IV / 60 ))m x HB_STALE_MULT $CMULT); last completed $(iso "$LD")")
  LANES+=("$LANE"); IDS+=("hb-cron-$LANE-$LD"); N=$(( N + 1 )); SEEN_LANE["$LANE@$SELF_BOX"]=1
  log "$LANE: no completed tick for ${AGE}s (threshold ${THR}s), paged"
done
# ── THE SAME QUESTION, ASKED OF THE ONE FACT (BH-1031, state→DB slice 6) ──────
# Everything above reads FILES ON THIS BOX, and that is the half that cannot be
# fixed by reading it harder: state/heartbeat/<lane>.<pid>.json is legible only
# to the machine that wrote it, so a lane whose whole box went away leaves no
# file for anyone to find, and the detector goes quietest exactly when the
# failure is largest. The fleet's answer to that used to be bin/fleet-heartbeat.sh
# ssh'ing every box to stat a log — which answered "can the hub reach it", not
# "is the lane alive" (its own comments said so), and which this slice deletes.
#
# So the lane's beats are written through to the `lanes` row as well
# (bin/lib/heartbeat.sh _hb_db), the WORKER computes stale from them on the
# row's own declared rhythm, and this pass reads the verdict back for every box
# at once. One threshold, one fact, one page.
#
# THE FILE PASS STILL WINS FOR THIS BOX. Only it can `kill -0` a pid, so a lane
# it already reported is skipped here rather than reported twice — the DB pass
# is what covers the lanes no file on this box could speak for.
#
# THE SECRET NEVER LEAVES THIS SUBSHELL. The restart branch above nohups a lane,
# and sourcing global.env into this script's environment would hand that child
# every credential in it — the reason this file reads HB_* knobs by hand. The
# client is sourced in a subshell that prints findings and exits.
#
# FAIL-OPEN, LOUDLY-IN-THE-LOG-ONLY: no worker, no flag, no jq, no client — the
# file pass above is untouched and this adds nothing. A liveness check that
# cannot run must never be the reason a box does less.
db_findings() {
  ( set -a; [ -r "$HENV/global.env" ] && . "$HENV/global.env" 2>/dev/null; set +a
    [ -r "$H/bin/jobs-client.sh" ] || exit 0
    # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1 || exit 0
    command -v lane_procs >/dev/null 2>&1 || exit 0
    # THE FLAG IS A DB ROW, the file is its cache: flag_active reconciles one
    # then answers from the other, so turning this lane on is a console edit and
    # not a deploy — and an unreachable worker leaves the box exactly as it is.
    command -v flag_active >/dev/null 2>&1 || exit 0
    flag_active lane-liveness-db || exit 0
    while IFS=$'\t' read -r LANE BOX PST AGE PID AFTER ALERTED STARTED NOTE; do
      [ -n "${LANE:-}" ] && [ -n "${BOX:-}" ] || continue
      case "${AGE:-}" in ''|*[!0-9-]*) AGE=-1 ;; esac
      case "${AFTER:-}" in ''|*[!0-9]*) AFTER=900 ;; esac
      case "$PST" in
        silent|overdue)
          [ "${ALERTED:-0}" = 1 ] && continue   # paged already; a repeat is how a channel dies
          # LATCH BEFORE THE PAGE, the same order the file path marks in: dying
          # between them loses one alert, the other way round pages for ever.
          lane_alert_set "hb.$LANE" "$BOX" on >/dev/null 2>&1
          printf 'page\thb-db-%s-%s\t%s\t%s\t%s\n' "$LANE" "$BOX" "$LANE" "$BOX" \
            "$LANE on $BOX is $PST: its last beat was $(hb_age_text "$AGE") ago (threshold $(( AFTER / 60 ))m), pid ${PID:-?}, started ${STARTED:--}, note: ${NOTE:--}. This is the ROW talking, not a file on this box — the process stopped beating even though $BOX's cron may be ticking normally. If the box is reachable, check the lane's log and relaunch it there." ;;
        *)
          [ "${ALERTED:-0}" = 1 ] || continue
          lane_alert_set "hb.$LANE" "$BOX" off >/dev/null 2>&1
          printf 'resolve\thb-db-%s-%s\t%s\t%s\t%s\n' "$LANE" "$BOX" "$LANE" "$BOX" \
            "$LANE on $BOX is beating again ($PST, last beat $(hb_age_text "$AGE") ago)" ;;
      esac
    done < <(lane_procs 2>/dev/null)
  ) 2>/dev/null
}
while IFS=$'\t' read -r ACTION ID LANE BOX TEXT; do
  [ -n "${ACTION:-}" ] && [ -n "${ID:-}" ] || continue
  case "$ACTION" in
    resolve) resolve "$ID" "$TEXT"; log "$LANE on $BOX: db row recovered, alert resolved"; continue ;;
  esac
  # A lane the file pass has already spoken for is not a second finding — ON
  # THIS BOX. The file pass is blind to every other machine by construction, so
  # the same lane name elsewhere is a different fact and gets its own line.
  if [ -n "${SEEN_LANE[$LANE@$BOX]:-}" ]; then
    log "$LANE on $BOX: db row stale too, already reported from the file"; continue
  fi
  DETAILS+=("$TEXT"); LANES+=("$LANE"); IDS+=("$ID"); N=$(( N + 1 )); SEEN_LANE["$LANE@$BOX"]=1
  log "$LANE on $BOX: stale in the lanes row (db pass)"
done < <(db_findings)

[ "$N" -gt 0 ] || exit 0
# mark_dead_lanes — AFTER the send: the marker is what lets a later run resolve hb-<lane>.
mark_dead_lanes() { local l m
  for l in "${!DEADPAGED[@]}"; do
    m="$DIR/$(_hb_slug "$l").hbpaged"
    { printf '%s\t%s\n' "$NOW" "$l" > "$m.tmp" && mv -f "$m.tmp" "$m"; } 2>/dev/null \
      || { rm -f "$m.tmp" 2>/dev/null; log "$l: could not write $m — a later run will not resolve the page"; }
  done; }

MASS=$(num "${HB_MASS_STALE_N:-3}" 3)
if [ "$N" -ge "$MASS" ]; then
  # The reboot clause only when the evidence says so: a boot later than the oldest launch is every lane dying at once.
  WHY=""; [ -n "$BOOT" ] && [ "$MINSTART" -gt 0 ] && [ "$BOOT" -gt "$MINSTART" ] \
    && WHY=" — this box rebooted at $(iso "$BOOT"), and a hub reboot kills every lane at once"
  TEXT="$N lanes stale at once: $(printf '%s, ' "${LANES[@]}" | sed 's/, $//')$WHY :: $(printf '%s; ' "${DETAILS[@]}" | sed 's/; $//')"
  # The id is built from the FINDINGS, never the clock (a per-pass id would page every 5 minutes),
  # and sorted, because readdir order is not a fact about the incident.
  MID=$(printf '%s\n' "${IDS[@]}" | sort | sha256sum 2>/dev/null | cut -c1-12)
  case "$MID" in ''|*[!0-9a-f]*) MID=$(printf '%s' "${LANES[*]}" | tr -c 'A-Za-z0-9' '-' | cut -c1-48) ;; esac
  send "hb-mass-$MID" "$TEXT"
  # OPEN EVERY MEMBER ID TOO. The marked lanes drop out of the next pass, but an unparseable file is
  # never marked (it is evidence), so it comes back alone, below the threshold, and pages under its
  # own id — a per-lane line five minutes after the collapse that was meant to be the whole story.
  # Registered, that second sighting is a suppress. No lib, no registration: the legacy lane-alert
  # path has no dedupe at all and pages every time, which is the fail-open its own docs state.
  if command -v alert_state_note >/dev/null 2>&1 && alert_state_enabled; then
    for i in "${!IDS[@]}"; do alert_state_note "$(as_sanitize_id "${IDS[$i]}")" \
      "$(alert_state_route "${DETAILS[$i]}" '')" "[orchestrator/heartbeat-reaper] ${DETAILS[$i]}" >/dev/null 2>&1; done
  fi
  log "collapsed $N findings into one line (HB_MASS_STALE_N=$MASS)"
  mark_dead_lanes
  exit 0
fi
for i in "${!IDS[@]}"; do send "${IDS[$i]}" "${DETAILS[$i]}"; done
mark_dead_lanes
exit 0
