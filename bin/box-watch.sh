#!/bin/bash
# bin/box-watch.sh tick | act <box> [<fails>] | lever-check
# The hub duty that owns box liveness (BH-10231, C1 of BH-9889). Owner: the
# quartermaster staff agent (staff_lanes row 'quartermaster','box-watch').
# Bash only, no model call.
#
# WHY. On 2026-11-21 box-small stayed dark for 5.5 hours until the operator
# restarted it by hand. bin/box-ssh-probe.sh records each box's ssh answer but
# never acts, and no lane called the restart lever (bin/box-ops.sh restart).
#
# tick (cron every 5 min on the hub, behind bin/hub-lease.sh check)
#   Probes each fleet.conf box (bin/fleet-conf.sh --boxes-with-roles) at once:
#   `timeout <probe_timeout_s> ssh root@<tailnet ip> true`. Not probed: role
#   hub (fleet-conf gives the hub box that role) or retired, this box
#   (bin/box-name.sh), a box with no tailnet IP. It counts the failed probes in
#   a row in state/box-watch/<box>.fails; a rc 0 probe resets it to 0.
#   MASS DARK: when mass_dark_boxes or more boxes fail in one tick, the hub's
#   own network is the likely fault, so it restarts none and sends ONE warn
#   alert (--id box-watch-mass-dark). Else a box at fail_probes or more starts
#   `act` detached (BOX_WATCH_ACT_SYNC=1 runs it inline, a test seam).
#   No roster = one log line, nothing probed (an empty roster is never "every
#   box down").
#
# act <box> [<fails>]
#   flock -n on locks/box-watch-act-<box>.lock (held = exit 0). The whole act
#   runs under `timeout act_timeout_s`; a timeout pages and keeps the stamp.
#   1. WINDOW. At most one restart per box per restart_window_min. Local stamp
#      state/box-watch/<box>.restart first, then the D1 claim
#      POST /api/box-watch/claim (one INSERT ... WHERE NOT EXISTS; the worker
#      reads the window from its own settings row). claimed:false = exit 0, no
#      restart. A worker that does not answer leaves the stamp to decide; the
#      log then says row=unrecorded. Both are written BEFORE the restart, so a
#      crash costs a missed restart, never a second one.
#   2. RESTART. bin/box-ops.sh restart <box_id> --host <box> --apply.
#      rc 2 = refused (no Orgo key, an unknown box): outcome refused + page.
#      Other rc != 0: outcome restart_failed + page. rc 0 with `already
#      running` (the box-ops lock is held: a restart is in progress) goes on to
#      the boot wait, and the re-probe decides.
#   3. BOOT WAIT. Probe every boot_poll_s until rc 0 or boot_wait_s.
#   4. RECOVERY. ONE ssh: bin/dns-guard.sh (static resolv.conf), the settings
#      refresh plus lane_env_apply update-runners, bin/tmpfs-ensure.sh (/tmp
#      size from the box's settings). Its rc is recovery_rc.
#   5. RE-PROBE once. rc 0 = outcome back (back_at set) and the page is
#      retracted (--severity resolved). Else outcome still_dark + page.
#   6. ROW. POST /api/box-watch/actions/<id> {box, probes, restart_rc,
#      recovery_rc, outcome, back_at, detail}.
#   Page = one critical alert, --id box-watch-dark-<box>.
#
# lever-check (cron hourly at :23 on the hub)
#   For each key_env in catalog/orgo-plans.json (fallback ORGO_API_KEY):
#   unset -> orgo_lever_alert <KEY> unset (bin/lib/orgo-lever.sh, the same
#   --id orgo-lever-<KEY> and text as box-ops); set -> GET /workspaces through
#   orgo() (bin/lib/restore-drill-orgo.sh); not 2xx -> orgo_lever_alert <KEY>
#   "answered HTTP <code> on GET /workspaces"; 2xx -> one --severity resolved
#   retraction of orgo-lever-<KEY>. It never restarts anything and never
#   prints a key value.
#
# Off: flags/lane-off-box-watch (or flags/all-off), or
# bin/harness-ctl.sh off box-watch. Every verb is gated.
# Knobs: settings rows box_watch.<name>, then env BOX_WATCH_<NAME> (the mass
# dark knob's env is BOX_WATCH_MASS_DARK), then the
# code fallback. A value out of range is the fallback plus one WARN log line:
#   fail_probes 3 (1..100)          restart_window_min 120 (5..10080)
#   probe_timeout_s 15 (1..110)     mass_dark_boxes 3 (1..1000)
#   boot_wait_s 600 (10..3600)      boot_poll_s 15 (1..600)
#   recovery_timeout_s 180 (5..1800) act_timeout_s 2400 (60..7200)
#   orgo_timeout_s 30 (1..300)
# Test seams (never set in cron): BOX_WATCH_SSH (the ssh command),
# BOX_WATCH_BOX_OPS (the box-ops command), BOX_WATCH_SELF (this box's name),
# BOX_WATCH_ACT_SYNC=1, BOX_WATCH_NOW (epoch), BOX_WATCH_BOOT_WAIT_SEAM_S,
# BOX_WATCH_ACT_TIMEOUT_SEAM_S. All are settable:false in the lane registry.
# Note: docs/notes/2026-11-26-BH-10231-box-watch.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
BIN="$(dirname "$SELF")"
VERB="${1:-}"
case "$VERB" in
  tick|act|lever-check) ;;
  *) echo "usage: box-watch.sh tick | act <box> [<fails>] | lever-check" >&2; exit 2 ;;
esac

# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$BIN/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-box-watch
# (or a pause_flags row driving either) is set. Both fail OPEN.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off box-watch.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit box-watch
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    box-watch
set -a
# shellcheck disable=SC1091
. "$HENV/global.env" 2>/dev/null
set +a
# Again below the env load: the settings row must win over global.env.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    box-watch
set -uo pipefail

LOG="$H/logs/box-watch.log"
SD="$H/state/box-watch"
mkdir -p "$H/locks" "$H/logs" "$SD" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) box-watch: $*" >> "$LOG"; }
now() { printf '%s' "${BOX_WATCH_NOW:-$(date -u +%s)}"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
alert() { "$H/bin/alert-line.sh" "$@" >/dev/null 2>&1 9>&- 8>&- || true; }

# The settings cache, once per run. A tree with no jobs client reads its cache
# as it stands; no cache = env then fallback.
if command -v _lg_settings_refresh >/dev/null 2>&1 && [ "${LANE_GATE_DISABLE:-0}" != 1 ]; then
  _lg_settings_refresh >/dev/null 2>&1 || true
  set -uo pipefail
fi

# bw_knob <name> <env value> <fallback> <min> <max> — the settings row
# box_watch.<name>, then the env value the caller read (BOX_WATCH_<NAME>), then
# <fallback>. A value that is not a whole number inside min..max is the
# fallback plus one WARN log line.
bw_knob() {
  local name="$1" ev="$2" fb="$3" lo="$4" hi="$5" v="" src
  if command -v _lg_setting_lookup >/dev/null 2>&1 && v=$(_lg_setting_lookup "box_watch.$name" 2>/dev/null) && [ -n "$v" ]; then
    src="row box_watch.$name"
  elif [ -n "$ev" ]; then
    v="$ev"; src="env BOX_WATCH_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
  else
    printf '%s' "$fb"; return 0
  fi
  case "$v" in
    ''|*[!0-9]*) log "WARN knob $src='${v:0:32}' is not a whole number; using fallback $fb"; printf '%s' "$fb"; return 0 ;;
  esac
  if [ "${#v}" -gt 9 ] || [ "$((10#$v))" -lt "$lo" ] || [ "$((10#$v))" -gt "$hi" ]; then
    log "WARN knob $src='${v:0:32}' is outside $lo..$hi; using fallback $fb"; printf '%s' "$fb"; return 0
  fi
  printf '%s' "$((10#$v))"
}

read -ra SSH_CMD <<< "${BOX_WATCH_SSH:-ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new}"
BOX_OPS="${BOX_WATCH_BOX_OPS:-$H/bin/box-ops.sh}"

# probe <ip> <timeout_s> — rc of `ssh root@<ip> true` under timeout.
probe() { timeout "$2" "${SSH_CMD[@]}" "root@$1" true </dev/null >/dev/null 2>&1 9>&- 8>&-; }

# The jobs client, sourced once. No client = every post answers rc 1.
jobs_post() { # jobs_post <path> <json> -> prints the body; rc of _jobs_req
  if ! declare -F _jobs_req >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    [ -f "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" >/dev/null 2>&1
    set -uo pipefail
  fi
  declare -F _jobs_req >/dev/null 2>&1 || return 1
  _jobs_req POST "$1" "$2" 9>&- 8>&-
}

# roster — `<box>\t<box_id>\t<ip>` for each box to watch. rc 1 = no roster.
roster() {
  local raw box id role ip me
  raw=$("$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  me="${BOX_WATCH_SELF:-$("$BIN/box-name.sh" 2>/dev/null)}"
  while IFS=$'\t' read -r box id role; do
    case "$box" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    case "$role" in hub|retired) continue ;; esac
    { [ -n "$me" ] && [ "$box" = "$me" ]; } && continue
    [[ "$id" =~ ^[a-z][a-z0-9]*$ ]] || { log "skip $box: box_id '${id:0:32}' is not a box id"; continue; }
    ip=$("$BIN/fleet-conf.sh" --tailnet-ip-of-box "$box" 2>/dev/null) || ip=""
    case "$ip" in ''|*[!0-9A-Fa-f.:]*) log "skip $box: no tailnet IP"; continue ;; esac
    printf '%s\t%s\t%s\n' "$box" "$id" "$ip"
  done <<< "$raw"
  return 0
}

# ============================================================ tick
do_tick() {
  exec 9>"$H/locks/box-watch.lock"
  flock -n 9 || exit 0
  local N TO MASS R W n i box id ip rc f dark=0 due=() t
  N=$(bw_knob fail_probes "${BOX_WATCH_FAIL_PROBES:-}" 3 1 100)
  TO=$(bw_knob probe_timeout_s "${BOX_WATCH_PROBE_TIMEOUT_S:-}" 15 1 110)
  MASS=$(bw_knob mass_dark_boxes "${BOX_WATCH_MASS_DARK:-}" 3 1 1000)
  R=$(roster) || { log "tick: fleet.conf unreadable; nothing probed"; exit 0; }
  [ -n "$R" ] || { log "tick: no box to watch"; exit 0; }
  W=$(mktemp -d "${TMPDIR:-/tmp}/box-watch.XXXXXX") || { log "tick: mktemp failed; nothing probed"; exit 0; }
  trap 'rm -rf "$W"' EXIT
  n=0
  while IFS=$'\t' read -r box id ip; do
    n=$((n+1))
    printf '%s\t%s\t%s\n' "$box" "$id" "$ip" > "$W/$n.box"
    ( probe "$ip" "$TO"; echo $? > "$W/$n.rc" ) 9>&- &
  done <<< "$R"
  wait
  for ((i = 1; i <= n; i++)); do
    IFS=$'\t' read -r box id ip < "$W/$i.box"
    rc=$(cat "$W/$i.rc" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=255 ;; esac
    if [ "$rc" = 0 ]; then
      echo 0 > "$SD/$box.fails"
      continue
    fi
    f=$(tr -dc '0-9' < "$SD/$box.fails" 2>/dev/null); f=$(( ${f:-0} + 1 ))
    echo "$f" > "$SD/$box.fails"
    dark=$((dark+1))
    log "probe $box ($ip) rc=$rc fails=$f/$N"
    [ "$f" -ge "$N" ] && due+=("$box $f")
  done
  if [ "$dark" -ge "$MASS" ]; then
    alert --severity warn --id box-watch-mass-dark \
      "[box-watch] $dark of $n boxes failed the ssh probe in one tick (mass_dark_boxes $MASS). The hub's own network is the likely fault, so no box was restarted. Check tailscale on the hub."
    : > "$SD/.mass-dark"
    log "tick: probed $n, dark $dark >= mass_dark_boxes $MASS; restarted none"
    exit 0
  fi
  if [ -e "$SD/.mass-dark" ]; then
    alert --severity resolved --id box-watch-mass-dark "[box-watch] the mass-dark condition cleared: $dark of $n boxes dark"
    rm -f "$SD/.mass-dark"
  fi
  for t in "${due[@]+"${due[@]}"}"; do
    box=${t% *}; f=${t##* }
    log "tick: $box failed $f probes in a row; act"
    if [ "${BOX_WATCH_ACT_SYNC:-0}" = 1 ]; then
      bash "$SELF" act "$box" "$f" </dev/null >/dev/null 2>&1 9>&-
    else
      setsid nohup bash "$SELF" act "$box" "$f" </dev/null >/dev/null 2>&1 9>&- &
    fi
  done
  log "tick: probed $n, dark $dark, acted ${#due[@]}"
  exit 0
}

# ============================================================ act
# record <id> <json> — the end-state row. Logs recorded / unrecorded.
record() {
  local id="$1" body="$2" out
  if [ -z "$id" ]; then log "act $BOX: row=unrecorded (no claim id) $(jq -c '{outcome,restart_rc,recovery_rc}' <<<"$body" 2>/dev/null)"; return 0; fi
  if out=$(jobs_post "/api/box-watch/actions/$id" "$body" 2>/dev/null); then
    log "act $BOX: row=recorded id=$id $(jq -c '{outcome,restart_rc,recovery_rc}' <<<"$body" 2>/dev/null)"
  else
    log "act $BOX: row=unrecorded id=$id http=${JOBS_HTTP:-none} ${out:0:120}"
  fi
}
page() { # page <text>
  alert --severity critical --id "box-watch-dark-$BOX" "[box-watch] $BOX: $1"
}

# The recovery steps, run on the box in one ssh. Each step runs even when one
# before it failed; the rc is the first non-zero one.
RECOVERY_CMD='cd /root/harness || exit 1; r=0; bin/dns-guard.sh >/dev/null 2>&1 || r=1; HARNESS=/root/harness bash -c ". bin/lib/lane-gate.sh && _lg_settings_refresh && lane_env_apply update-runners" >/dev/null 2>&1 || { [ "$r" = 0 ] && r=2; }; bin/tmpfs-ensure.sh >/dev/null 2>&1 || { [ "$r" = 0 ] && r=3; }; exit $r'

act_inner() {
  local FAILS="${3:-0}" WIN BW BP RTO ID="" stamp last t0 out orc rc=255 rrc=-1 outcome detail back="" body claim
  case "$FAILS" in ''|*[!0-9]*) FAILS=0 ;; esac
  [ "${#FAILS}" -le 6 ] || FAILS=0
  WIN=$(bw_knob restart_window_min "${BOX_WATCH_RESTART_WINDOW_MIN:-}" 120 5 10080)
  BW=$(bw_knob boot_wait_s "${BOX_WATCH_BOOT_WAIT_S:-}" 600 10 3600)
  BP=$(bw_knob boot_poll_s "${BOX_WATCH_BOOT_POLL_S:-}" 15 1 600)
  RTO=$(bw_knob recovery_timeout_s "${BOX_WATCH_RECOVERY_TIMEOUT_S:-}" 180 5 1800)
  TO=$(bw_knob probe_timeout_s "${BOX_WATCH_PROBE_TIMEOUT_S:-}" 15 1 110)
  [ -n "${BOX_WATCH_BOOT_WAIT_SEAM_S:-}" ] && BW="$BOX_WATCH_BOOT_WAIT_SEAM_S"

  # 1. WINDOW: local stamp, then the D1 claim.
  t0=$(now)
  stamp="$SD/$BOX.restart"
  last=$(tr -dc '0-9' < "$stamp" 2>/dev/null)
  if [ -n "$last" ] && [ $(( t0 - last )) -lt $(( WIN * 60 )) ]; then
    log "act $BOX: restarted at $(iso "$last"), inside restart_window_min $WIN; no restart"
    return 0
  fi
  echo "$t0" > "$stamp"
  body=$(jq -nc --arg b "$BOX" --arg id "$BOXID" --argjson p "$FAILS" '{box:$b, box_id:$id, probes:$p}')
  if claim=$(jobs_post /api/box-watch/claim "$body" 2>/dev/null); then
    if [ "$(jq -r '.claimed' <<<"$claim" 2>/dev/null)" = false ]; then
      log "act $BOX: claim refused (a restart at $(jq -r '.last_acted_at // "?"' <<<"$claim" 2>/dev/null) is inside the window); no restart"
      return 0
    fi
    ID=$(jq -r '.id // empty' <<<"$claim" 2>/dev/null)
    case "$ID" in *[!0-9]*) ID="" ;; esac
  else
    log "act $BOX: claim not answered (http=${JOBS_HTTP:-none}); the local stamp decides"
  fi

  # 2. RESTART.
  out=$("$BOX_OPS" restart "$BOXID" --host "$BOX" --apply 2>&1 9>&- 8>&-); orc=$?
  log "act $BOX: box-ops restart $BOXID rc=$orc: $(printf '%s' "$out" | tail -1 | cut -c1-200)"
  if [ "$orc" = 2 ]; then
    outcome=refused; detail="box-ops refused the restart: $(printf '%s' "$out" | tail -1 | cut -c1-200)"
    page "dark for $FAILS probes; the restart was REFUSED (rc 2): $(printf '%s' "$out" | tail -1 | cut -c1-200). Fix the lever (bin/box-watch.sh lever-check names the key), then run bin/box-ops.sh restart $BOXID --host $BOX --apply."
    record "$ID" "$(jq -nc --arg b "$BOX" --argjson p "$FAILS" --argjson o "$orc" --arg d "$detail" '{box:$b, probes:$p, restart_rc:$o, recovery_rc:null, outcome:"refused", back_at:null, detail:$d}')"
    return 0
  fi
  if [ "$orc" != 0 ]; then
    detail="box-ops restart failed rc $orc: $(printf '%s' "$out" | tail -1 | cut -c1-200)"
    page "dark for $FAILS probes; the restart FAILED (rc $orc). Read logs/box-watch.log on the hub."
    record "$ID" "$(jq -nc --arg b "$BOX" --argjson p "$FAILS" --argjson o "$orc" --arg d "$detail" '{box:$b, probes:$p, restart_rc:$o, recovery_rc:null, outcome:"restart_failed", back_at:null, detail:$d}')"
    return 0
  fi
  case "$out" in *"already running"*) log "act $BOX: box-ops lock held (a restart is in progress); the re-probe decides" ;; esac

  # 3. BOOT WAIT.
  local waited=0 up=0
  while [ "$waited" -le "$BW" ]; do
    if probe "$IP" "$TO"; then up=1; break; fi
    [ "$waited" -lt "$BW" ] || break
    sleep "$BP"   # determinism: ok poll interval of the boot wait (knob box_watch.boot_poll_s)
    waited=$((waited + BP))
  done
  # 4. RECOVERY, one ssh (only when the box answers).
  if [ "$up" = 1 ]; then
    timeout "$RTO" "${SSH_CMD[@]}" "root@$IP" "$RECOVERY_CMD" </dev/null >/dev/null 2>&1 9>&- 8>&-; rrc=$?
    log "act $BOX: recovery rc=$rrc"
  else
    log "act $BOX: no ssh answer within boot_wait_s $BW; recovery skipped"
  fi
  # 5. RE-PROBE once.
  if probe "$IP" "$TO"; then rc=0; else rc=$?; fi
  if [ "$rc" = 0 ]; then
    outcome=back; back=$(iso "$(now)"); detail="back after restart"
    echo 0 > "$SD/$BOX.fails"
    alert --severity resolved --id "box-watch-dark-$BOX" "[box-watch] $BOX is back after a restart (recovery rc $rrc)"
  else
    outcome=still_dark; detail="re-probe rc $rc after restart"
    page "still DARK after a restart (re-probe rc $rc, recovery rc $rrc). Open the box in the Orgo console."
  fi
  log "act $BOX: outcome=$outcome"
  # 6. ROW.
  record "$ID" "$(jq -nc --arg b "$BOX" --argjson p "$FAILS" --argjson o "$orc" --argjson r "$rrc" --arg oc "$outcome" --arg back "$back" --arg d "$detail" \
    '{box:$b, probes:$p, restart_rc:$o, recovery_rc:(if $r < 0 then null else $r end), outcome:$oc, back_at:(if $back == "" then null else $back end), detail:$d}')"
  return 0
}

do_act() {
  BOX="${2:-}"
  case "$BOX" in ''|*[!A-Za-z0-9._-]*) echo "box-watch: act needs a box name" >&2; exit 2 ;; esac
  [ "${#BOX}" -le 64 ] || { echo "box-watch: act needs a box name" >&2; exit 2; }
  local line ATO rc
  line=$(roster | awk -F'\t' -v b="$BOX" '$1 == b' | head -1)
  [ -n "$line" ] || { log "act $BOX: not in the watched roster; nothing done"; exit 0; }
  IFS=$'\t' read -r BOX BOXID IP <<< "$line"
  # The inner run (BOX_WATCH_ACT_INNER=1) is this script under timeout; the
  # outer run holds the act lock for it, so the inner one takes none.
  if [ "${BOX_WATCH_ACT_INNER:-0}" = 1 ]; then
    act_inner "$@"; exit 0
  fi
  exec 8>"$H/locks/box-watch-act-$BOX.lock"
  flock -n 8 || exit 0
  ATO=$(bw_knob act_timeout_s "${BOX_WATCH_ACT_TIMEOUT_S:-}" 2400 60 7200)
  [ -n "${BOX_WATCH_ACT_TIMEOUT_SEAM_S:-}" ] && ATO="$BOX_WATCH_ACT_TIMEOUT_SEAM_S"
  timeout "$ATO" env BOX_WATCH_ACT_INNER=1 bash "$SELF" act "$BOX" "${3:-0}" </dev/null >/dev/null 2>&1 8>&- 9>&-; rc=$?
  if [ "$rc" = 124 ]; then
    log "act $BOX: timed out after act_timeout_s $ATO"
    page "the restart run TIMED OUT after ${ATO}s; the box state is unknown. Read logs/box-watch.log on the hub."
  fi
  exit 0
}

# ============================================================ lever-check
do_lever() {
  # shellcheck source=bin/lib/orgo-lever.sh
  . "$BIN/lib/orgo-lever.sh" || { log "lever-check: bin/lib/orgo-lever.sh missing"; exit 0; }
  # shellcheck source=bin/lib/restore-drill-orgo.sh
  . "$BIN/lib/restore-drill-orgo.sh" || { log "lever-check: bin/lib/restore-drill-orgo.sh missing"; exit 0; }
  local OTO PLANS keys k val
  OTO=$(bw_knob orgo_timeout_s "${BOX_WATCH_ORGO_TIMEOUT_S:-}" 30 1 300)
  PLANS="$BIN/../catalog/orgo-plans.json"
  keys=$(jq -r '[.accounts[]?.key_env // empty] | unique | .[]' "$PLANS" 2>/dev/null)
  [ -n "$keys" ] || keys=ORGO_API_KEY
  while IFS= read -r k; do
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { log "lever-check: key_env '${k:0:64}' is not an env var name; skipped"; continue; }
    val="${!k:-}"
    if [ -z "$val" ]; then
      HARNESS="$H" orgo_lever_alert "$k" unset
      log "lever-check: $k unset; alert orgo-lever-$k"
      continue
    fi
    if ORGO_API_KEY="$val" RESTORE_DRILL_CALL_TIMEOUT_S="$OTO" orgo GET /workspaces >/dev/null 2>&1; then
      alert --severity resolved --id "orgo-lever-$k" "[orgo-lever] $k answered HTTP $ORGO_HTTP on GET /workspaces; the restart lever works"
      log "lever-check: $k ok (HTTP $ORGO_HTTP)"
    else
      HARNESS="$H" orgo_lever_alert "$k" "answered HTTP $ORGO_HTTP on GET /workspaces"
      log "lever-check: $k answered HTTP $ORGO_HTTP; alert orgo-lever-$k"
    fi
  done <<< "$keys"
  exit 0
}

case "$VERB" in
  tick) do_tick ;;
  act) do_act "$@" ;;
  lever-check) do_lever ;;
esac
