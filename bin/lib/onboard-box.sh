# shellcheck shell=bash
# bin/lib/onboard-box.sh — the `box` station's pool and dedicated paths
# (BH-7975, slice BH-7939.1). Sourced by obs_box in bin/lib/onboard-stations.sh
# when OBS_BOX_PATH is not `shared`; sourcing defines functions only.
#
#   obx_run   run the path OBS_BOX_PATH names (pool | dedicated). Any other
#             value fails `unknown box path '<v>'` with no call.
#
# Path pool: the shared bootstrap first (the `load-project.sh --fly` order: the
# rollout needs the project's tailnet IP), then one line `<p> <ISO>` in
# $ROOT/fly/onboard-queue.conf when no line for <p> is there, then a wait for
# the `[fly-onboard/<p>] FLY_ONBOARD <p> OK|ALREADY|FAILED:` line that
# bin/fly-onboard.sh writes to logs/fly-pool-rollout.log after the byte offset
# read before the append. The station never runs bin/fly-onboard.sh: the
# fly-pool-tick drain does. bin/harness-sync.sh can rewrite fly/, so a wait
# that finds the line gone appends it again.
#
# Path dedicated: provision (fm_create box-<p> from the row onboard.box_image,
# then fm_state until `started`), tailnet (ts_join with TS_AUTHKEY_<P>, else
# TS_AUTHKEY; Tailscale off with no OBS_HAVE_BOX is refused before any Fly
# call: the registry takes only a dotted IPv4 tailnet_ip, so an fdaa: address
# could never register and the machine would bill with no owner), register
# (bin/registry.sh add-box <p>-box and move-project, read back with show),
# bootstrap (the shared obs_box block on the new address). OBS_HAVE_BOX (an
# IP in 100.64/10 or an RFC 1123 name) skips provision. A registry row for
# <p>-box with an address skips provision and tailnet, so a retry never calls
# fm_create again. Every refusal that needs no call (file-mode registry, a bad
# address, no image, no Fly token, no Tailscale key) comes before the first
# call, so a refused run spends nothing.
#
# Output: each step prints `BEAT box.<sub> <running|done|failed|skipped>
# <detail>` (one line, redacted, 160 chars at most). The runner stores the
# step's last ONBOARD_RUN_EXCERPT_BYTES bytes, so obx_run ends on every path
# with `== box summary ==` and the last line of each sub in path order;
# console-ui/src/screens/SetupLine.js reads those lines as the sub-lines.
#
# Knobs: one GET /api/settings through _jobs_req when the caller has it; a
# missing row, a failed read or a bad value is the code default, which equals
# the seed row (worker/jobs/schema.d/*-bh-7939-onboard-box-settings.sql).
# Globals read: PROJECT BOX ROOT OBS_BOX_PATH OBS_HAVE_BOX OBS_TAILSCALE
# REGISTRY_SOURCE REG_MODE; test seams OBX_SLEEP (the sleep command) and
# OBX_NOW (a command that prints epoch seconds; default `date +%s`).
#
# Waits: each poll sleeps onboard.box_poll_s, then calls obs_run_cancelled
# when the caller defines it (bin/onboard-run.sh does; bin/load-project.sh
# does not, so its path never probes). That probe is one READ of the run:
# rc 0 = the run is no longer running (cancelled), so the wait stops. A wait
# sends no beat of any kind, so the step's started_at stays the time of the
# runner's first `running` beat. Each timeout counts from the station's own
# start (t0, read once), never from a worker timestamp.
# shellcheck source=vendor/fly-machines.sh
. "${BASH_SOURCE[0]%/*}/vendor/fly-machines.sh" || return 1
# shellcheck source=vendor/tailscale.sh
. "${BASH_SOURCE[0]%/*}/vendor/tailscale.sh" || return 1
# shellcheck source=token-redact.sh
. "${BASH_SOURCE[0]%/*}/token-redact.sh" || return 1

# _obx_redact — stdin to stdout: GitHub token shapes, Fly and Tailscale
# credential shapes, and the value of every credential variable loaded here.
_obx_redact() {
  local t n v
  t=$(token_redact | sed -E -e 's/FlyV1 [^[:space:]]+/FlyV1 <redacted>/g' \
    -e 's/fm[12]_[A-Za-z0-9+\/=_-]+/<redacted>/g' -e 's/fo1_[A-Za-z0-9_-]+/<redacted>/g' \
    -e 's/tskey-[A-Za-z0-9-]+/<redacted>/g')
  for n in ${_OBX_SECRET_VARS:-}; do
    v="${!n:-}"
    [ "${#v}" -lt 8 ] || t="${t//"$v"/<redacted>}"
  done
  printf '%s\n' "$t"
}

# _obx_beat <sub> <state> [detail] — print one BEAT line and keep it for the summary.
_obx_beat() {
  local sub="$1" state="$2" d="${3:-}" line
  [[ "$sub" =~ ^[a-z_]{1,20}$ ]] || return 0
  case "$state" in running|done|failed|skipped) ;; *) return 0 ;; esac
  d=$(printf '%s' "$d" | tr '\r\n\t' '   ' | _obx_redact)
  d="${d:0:160}"
  line="BEAT box.$sub $state${d:+ $d}"
  printf '%s\n' "$line"
  _OBX_BEATS+=("$line")
}

# _obx_has_sub <sub> — rc 0 when a BEAT line for <sub> was printed.
_obx_has_sub() {
  local l
  for l in "${_OBX_BEATS[@]}"; do case "$l" in "BEAT box.$1 "*) return 0 ;; esac; done
  return 1
}

# _obx_summary <path> — the last line of each sub: the path's order, then the rest.
_obx_summary() {
  local -a order
  local s l last seen=" " i
  case "$1" in
    pool) order=(bootstrap queue pool_app image smoke) ;;
    *) order=(provision tailnet register bootstrap) ;;
  esac
  for l in "${_OBX_BEATS[@]}"; do
    s="${l#BEAT box.}"; s="${s%% *}"
    case " ${order[*]} " in *" $s "*) ;; *) case "$seen" in *" $s "*) ;; *) order+=("$s"); seen+="$s " ;; esac ;; esac
  done
  echo "== box summary =="
  for s in "${order[@]}"; do
    last=""
    for ((i = ${#_OBX_BEATS[@]} - 1; i >= 0; i--)); do
      case "${_OBX_BEATS[$i]}" in "BEAT box.$s "*) last="${_OBX_BEATS[$i]}"; break ;; esac
    done
    [ -z "$last" ] || printf '%s\n' "$last"
  done
}

# _obx_ks <settings-json> <key> <default> — a string knob.
_obx_ks() {
  local v
  v=$(jq -r --arg k "$2" '[.settings[] | select(.key == $k) | .value][0] // empty' <<<"$1" 2>/dev/null)
  printf '%s\n' "${v:-$3}"
}
# _obx_kn <settings-json> <key> <default> <min> <max> — an integer knob.
_obx_kn() {
  local v
  v=$(_obx_ks "$1" "$2" "$3")
  if [[ "$v" =~ ^[0-9]{1,9}$ ]] && [ "$v" -ge "$4" ] && [ "$v" -le "$5" ]; then printf '%s\n' "$((10#$v))"
  else printf '%s\n' "$3"; fi
}

# _obx_knobs — the seven onboard.box_* rows in one read.
_obx_knobs() {
  local s=""
  if declare -F _jobs_req >/dev/null; then s=$(_jobs_req GET /api/settings 2>/dev/null) || s=""; fi
  jq -e '(.settings | type) == "array"' <<<"$s" >/dev/null 2>&1 || s='{"settings":[]}'
  # Each default below is the seed row of the same key.
  OBX_IMAGE=$(_obx_ks "$s" onboard.box_image '')
  OBX_REGION=$(_obx_ks "$s" onboard.box_region 'iad')
  [[ "$OBX_REGION" =~ ^[a-z]{3}$ ]] || OBX_REGION=iad
  OBX_POOL_TIMEOUT_S=$(_obx_kn "$s" onboard.box_pool_timeout_s '3600' 1 86400)
  OBX_PROVISION_TIMEOUT_S=$(_obx_kn "$s" onboard.box_provision_timeout_s '600' 1 7200)
  OBX_POLL_S=$(_obx_kn "$s" onboard.box_poll_s '30' 1 600)
  OBX_CALL_TIMEOUT_S=$(_obx_kn "$s" onboard.box_call_timeout_s '120' 1 1800)
  OBX_FAIL_TAIL_LINES=$(_obx_kn "$s" onboard.box_fail_tail_lines '20' 1 200)
  FM_CALL_TIMEOUT_S="$OBX_CALL_TIMEOUT_S"; TS_CALL_TIMEOUT_S="$OBX_CALL_TIMEOUT_S"
}

# obx_knobs_dump — the resolved knobs, one `name=value` line each (a test seam).
obx_knobs_dump() {
  _obx_knobs
  printf 'image=%s\nregion=%s\npool_timeout_s=%s\nprovision_timeout_s=%s\npoll_s=%s\ncall_timeout_s=%s\nfail_tail_lines=%s\n' \
    "$OBX_IMAGE" "$OBX_REGION" "$OBX_POOL_TIMEOUT_S" "$OBX_PROVISION_TIMEOUT_S" "$OBX_POLL_S" "$OBX_CALL_TIMEOUT_S" "$OBX_FAIL_TAIL_LINES"
}

# _obx_fly_env — the Fly and Tailscale credentials from <env dir>/fly.env into
# shell variables (not exported). A value already in the environment wins.
_obx_fly_env() {
  local d f n v up
  up=$(printf '%s' "$PROJECT" | tr '[:lower:].-' '[:upper:]__')
  if declare -F harness_env_dir >/dev/null; then d=$(harness_env_dir "$ROOT"); else d="${HARNESS_ENV_DIR:-$ROOT/env}"; fi
  f="$d/fly.env"
  for n in FLY_ORG FLY_API_TOKEN "FLY_API_TOKEN_$up" TS_AUTHKEY "TS_AUTHKEY_$up"; do
    [ -z "${!n:-}" ] && [ -r "$f" ] || continue
    v=$(sed -n "s/^\(export \)\{0,1\}$n=//p" "$f" 2>/dev/null | tr -d "\"'" | head -n 1)
    [ -z "$v" ] || printf -v "$n" '%s' "$v"
  done
  _OBX_SECRET_VARS="FLY_API_TOKEN FLY_API_TOKEN_$up TS_AUTHKEY TS_AUTHKEY_$up"
}

# _obx_now — epoch seconds (OBX_NOW is the test seam).
_obx_now() { ${OBX_NOW:-date +%s}; }

# _obx_wait — one poll: sleep onboard.box_poll_s, then the read-only cancel
# probe. rc 1 when the probe says the run is no longer running. No beat.
_obx_wait() {
  "${OBX_SLEEP:-sleep}" "$OBX_POLL_S"
  if declare -F obs_run_cancelled >/dev/null && obs_run_cancelled; then
    echo "box: the run was cancelled"
    return 1
  fi
  return 0
}

_obx_size() { local n; n=$(wc -c < "$1" 2>/dev/null) || n=0; printf '%s\n' "${n:-0}"; }

# _obx_queue_add <file> <project> — append `<p> <ISO UTC>`, on its own line.
_obx_queue_add() {
  mkdir -p "$(dirname "$1")" || return 1
  [ ! -s "$1" ] || [ -z "$(tail -c1 "$1")" ] || echo >> "$1" || return 1
  printf '%s %s\n' "$2" "$(date -u +%FT%TZ)" >> "$1"
}

# _obx_routed <p> — rc 0 when the project already builds on its pool.
_obx_routed() {
  if declare -F routing_builder >/dev/null; then
    [ "$(routing_builder "$1" 2>/dev/null)" = pool ]
  else
    [ -f "$ROOT/flags/fly-pool-$1" ] && [ -f "$ROOT/flags/builder-fly-$1" ]
  fi
}

# _obx_pool_subs <log> <offset> <p> — the pool_app, image and smoke sub-lines
# from the rollout's own `[<p>] ` step lines after the offset.
_obx_pool_subs() {
  local msgs m
  msgs=$(tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | grep -F " [$3] " | sed "s/^.* \[$3\] //")
  m=$(grep -E "^pool-$3 app missing" <<<"$msgs" | tail -1)
  if [ -n "$m" ]; then _obx_beat pool_app failed "$m"
  elif grep -qE '^(building image|image: )' <<<"$msgs"; then _obx_beat pool_app done "pool-$3"; fi
  m=$(grep -E '^(image: |image build FAILED|no image ref recorded)' <<<"$msgs" | tail -1)
  case "$m" in
    "image: "*) _obx_beat image done "${m#image: }" ;;
    ?*) _obx_beat image failed "$m" ;;
  esac
  # `machine[ ]run` matches the rollout's log text `smoke machine run FAILED`;
  # the bracket keeps tests/vendor-budget.bh-7939-test.sh B3 (a Fly call
  # outside its seam) from reading this log match as a call.
  m=$(grep -E '^(SMOKE_OK|smoke machine[ ]run FAILED|smoke machine state=|smoke FAILED)' <<<"$msgs" | tail -1)
  case "$m" in
    SMOKE_OK*) _obx_beat smoke done "$m" ;;
    ?*) _obx_beat smoke failed "$m" ;;
  esac
}

obx_pool() {
  local p="$PROJECT" q="$ROOT/fly/onboard-queue.conf" log="$ROOT/logs/fly-pool-rollout.log"
  local off size v="" t0 requeued=0 rc s led="" st="$ROOT/state/fly-onboard/$PROJECT"
  _obx_beat bootstrap running "shared bootstrap on $BOX"
  OBS_BOX_PATH=shared obs_box; rc=$?
  if [ "$rc" != 0 ]; then _obx_beat bootstrap failed "rc $rc"; return 1; fi
  _obx_beat bootstrap done "rc 0"
  if _obx_routed "$p"; then
    for s in pool_app image smoke; do _obx_beat "$s" skipped "already fly-routed"; done
    return 0
  fi
  if [ -e "$ROOT/flags/alerted-fly-onboard-gaveup-$p" ]; then
    echo "box: the hub gave up on $p. On the hub: rm state/fly-onboard/$p.attempts; rm flags/alerted-fly-onboard-gaveup-$p (paths under the harness root, see fly/onboard-queue.conf), then retry."
    _obx_beat queue failed "the hub gave up on $p: rm state/fly-onboard/$p.attempts; rm flags/alerted-fly-onboard-gaveup-$p"
    return 1
  fi
  t0=$(_obx_now)
  off=$(_obx_size "$log")
  if grep -qE "^$p([[:space:]]|\$)" "$q" 2>/dev/null; then
    _obx_beat queue done "already queued offset=$off"
  else
    _obx_queue_add "$q" "$p" || { _obx_beat queue failed "cannot write $q"; return 1; }
    _obx_beat queue done "queued offset=$off"
  fi
  while :; do
    size=$(_obx_size "$log")
    [ "$size" -ge "$off" ] || off=0
    v=$(tail -c +"$((off + 1))" "$log" 2>/dev/null \
      | grep -oE "\[fly-onboard/$p\] FLY_ONBOARD $p (OK|ALREADY|FAILED):" | head -1 | awk '{print $4}')
    v="${v%:}"
    [ -z "$v" ] || break
    if [ $(( $(_obx_now) - t0 )) -ge "$OBX_POOL_TIMEOUT_S" ]; then
      _obx_pool_subs "$log" "$off" "$p"
      [ ! -r "$st.attempts" ] || led=" (drain ledger: attempts=$(head -c 20 "$st.attempts" | tr -dc '0-9') last=$(head -c 30 "$st.last" 2>/dev/null | tr -dc '0-9TZ:-'))"
      _obx_beat queue failed "no FLY_ONBOARD verdict for $p in ${OBX_POOL_TIMEOUT_S}s$led"
      return 1
    fi
    if ! grep -qE "^$p([[:space:]]|\$)" "$q" 2>/dev/null; then
      _obx_queue_add "$q" "$p" || { _obx_beat queue failed "cannot write $q"; return 1; }
      [ "$requeued" = 1 ] || { requeued=1; _obx_beat queue running "re-queued after a sync"; }
    fi
    _obx_wait || { _obx_beat queue failed "the run was cancelled"; return 1; }
  done
  _obx_pool_subs "$log" "$off" "$p"
  case "$v" in
    OK) _obx_beat queue done "FLY_ONBOARD $p OK"; return 0 ;;
    ALREADY)
      for s in pool_app image smoke; do
        _obx_has_sub "$s" || _obx_beat "$s" skipped "already fly-routed"
      done
      _obx_beat queue done "FLY_ONBOARD $p ALREADY"; return 0 ;;
  esac
  _obx_beat queue failed "FLY_ONBOARD $p FAILED"
  echo "== rollout log tail =="
  tail -c +"$((off + 1))" "$log" 2>/dev/null | tail -n "$OBX_FAIL_TAIL_LINES" | _obx_redact | cut -c1-160
  return 1
}

# _obx_addr_ok <v> — an IPv4 in 100.64/10, or an RFC 1123 host name.
_obx_addr_ok() {
  if [[ "$1" =~ ^[0-9.]+$ ]]; then ts_ip_ok "$1"; return; fi
  [ "${#1}" -le 253 ] && [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]
}

# _obx_reg_row <show-output> <box> — the `<box> <id> <ip> projects=... ` line.
_obx_reg_row() { awk -v b="$2" '$1 == b' <<<"$1" | head -1; }
_obx_row_has() { # _obx_row_has <row> <ip> <project>
  local ps
  [ "$(awk '{print $3}' <<<"$1")" = "$2" ] || return 1
  ps=$(grep -oE 'projects=[^ ]*' <<<"$1"); ps="${ps#projects=}"
  case ",$ps," in *",$3,"*) return 0 ;; esac
  return 1
}

obx_dedicated() {
  local p="$PROJECT" rbox="$PROJECT-box" app="box-$PROJECT" have="${OBS_HAVE_BOX:-}" ts="${OBS_TAILSCALE:-on}"
  local show row ip="" id="" st out kvar="" pv t0 el like rc up
  REG_MODE="${REG_MODE:-$(_obs_reg_mode)}"
  up=$(printf '%s' "$p" | tr '[:lower:].-' '[:upper:]__')
  # Refusals that need no call.
  if [ "$REG_MODE" != db ]; then _obx_beat register failed "dedicated box needs REGISTRY_SOURCE=db"; return 1; fi
  if [ -n "$have" ] && ! _obx_addr_ok "$have"; then _obx_beat provision failed "invalid box address"; return 1; fi
  show=$("$ROOT/bin/registry.sh" show 2>&1) || { _obx_beat register failed "registry show failed: $show"; return 1; }
  row=$(_obx_reg_row "$show" "$rbox")
  ip=$(awk '{print $3}' <<<"$row"); [ "$ip" != - ] || ip=""
  if [ -n "$ip" ]; then
    _obx_beat provision skipped "box $rbox already registered at $ip"
    _obx_beat tailnet skipped "box $rbox already registered at $ip"
  else
    if [ -z "$have" ]; then
      # The registry validator refuses an fdaa: tailnet_ip, so a new machine
      # with Tailscale off could never pass register. Refuse before the spend.
      if [ "$ts" = off ]; then _obx_beat tailnet failed "Tailscale off needs an existing box (have_box): the registry takes only a 100.64/10 address"; return 1; fi
      [ -n "$OBX_IMAGE" ] || { _obx_beat provision failed "no box image set"; return 1; }
      if ! fly_token_resolve "$p"; then _obx_beat provision failed "no Fly token"; return 1; fi
      unset FLY_TOKEN_VAL
      pv="TS_AUTHKEY_$up"
      if [ -n "${!pv:-}" ]; then kvar="$pv"
      elif [ -n "${TS_AUTHKEY:-}" ]; then kvar=TS_AUTHKEY
      else _obx_beat tailnet failed "no Tailscale auth key"; return 1; fi
      t0=$(_obx_now)
      _obx_beat provision running "$app in $OBX_REGION"
      out=$(FM_PROJECT="$p" FM_TS_KEY_VAR="$kvar" fm_create "$app" "$app" "$OBX_IMAGE" "$OBX_REGION" 2>&1) \
        || { _obx_beat provision failed "$out"; return 1; }
      id="$out"
      while :; do
        st=$(FM_PROJECT="$p" fm_state "$app" "$id" 2>&1) || { _obx_beat provision failed "$st"; return 1; }
        [ "$st" != started ] || break
        el=$(( $(_obx_now) - t0 ))
        if [ "$el" -ge "$OBX_PROVISION_TIMEOUT_S" ]; then _obx_beat provision failed "state $st after ${el}s"; return 1; fi
        _obx_wait || { _obx_beat provision failed "the run was cancelled"; return 1; }
      done
      _obx_beat provision done "$id"
    else
      _obx_beat provision skipped "I have a box: $have"
    fi
    _obx_beat tailnet running "${have:-$app}"
    if [ -n "$have" ]; then
      out=$(ts_ip "$have" 2>&1) || { _obx_beat tailnet failed "$out"; return 1; }
    else
      out=$(FM_PROJECT="$p" fm_private_ip "$app" "$id" 2>&1) || { _obx_beat tailnet failed "$out"; return 1; }
      out=$(ts_join "$out" "$kvar" "$rbox" 2>&1) || { _obx_beat tailnet failed "$out"; return 1; }
    fi
    ts_ip_ok "$out" || { _obx_beat tailnet failed "not one 100.64/10 address: ${out:0:60}"; return 1; }
    ip="$out"; _obx_beat tailnet done "$ip ${have:-$rbox}"
  fi
  if _obx_row_has "$row" "$ip" "$p"; then
    _obx_beat register skipped "$rbox $ip already lists $p"
  else
    declare -F cron_box_id_for >/dev/null || . "${BASH_SOURCE[0]%/*}/cron-lines.sh" || return 1
    like=$(cron_box_id_for "$BOX")
    _obx_beat register running "$rbox $ip like $like"
    "$ROOT/bin/registry.sh" add-box "$rbox" --ip "$ip" --like "$like" --actor onboard-run \
      || { _obx_beat register failed "registry add-box $rbox failed"; return 1; }
    "$ROOT/bin/registry.sh" move-project "$p" --box "$rbox" --actor onboard-run \
      || { _obx_beat register failed "registry move-project $p failed"; return 1; }
    show=$(REGISTRY_CACHE_TTL_S=0 "$ROOT/bin/registry.sh" show 2>&1) || { _obx_beat register failed "registry show failed: $show"; return 1; }
    row=$(_obx_reg_row "$show" "$rbox")
    _obx_row_has "$row" "$ip" "$p" \
      || { _obx_beat register failed "read back: ${row:-no $rbox row} (want $ip and $p)"; return 1; }
    _obx_beat register done "$rbox $ip"
  fi
  _obx_beat bootstrap running "on ${have:-$ip}"
  ( BOX="${have:-$ip}"; OBS_SSH_ACCEPT_NEW=1 OBS_BOX_PATH=shared obs_box ); rc=$?
  if [ "$rc" != 0 ]; then _obx_beat bootstrap failed "rc $rc"; return 1; fi
  _obx_beat bootstrap done "rc 0"
}

obx_run() {
  local rc path="${OBS_BOX_PATH:-}"
  _OBX_BEATS=()
  case "$path" in
    pool|dedicated) ;;
    *) echo "box: unknown box path '$path'"; return 1 ;;
  esac
  [[ "${PROJECT:-}" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "box: bad project name '${PROJECT:-}'"; return 1; }
  _obx_knobs
  _obx_fly_env
  if [ "$path" = pool ]; then obx_pool; else obx_dedicated; fi
  rc=$?
  _obx_summary "$path"
  return "$rc"
}
