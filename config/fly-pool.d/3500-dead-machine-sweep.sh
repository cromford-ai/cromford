# >>> dead-machine sweep (BH-660)
# THE SWEEP fly/builder-runner.sh:459-462 has been promising since wave 3 ("a
# stopped pool machine is then destroyed by fly-pool.sh's dead-machine sweep").
# It was never written. The REAP above only ever visits machines that have a
# tracking file, so the moment a destroy failed — or a machine was spawned by a
# rollout smoke run, or reaped by a tick that then lost its file — the machine
# left the harness's field of view entirely and idled to a `stopped` state
# nothing looked at again. BH-660 counted 18 of them across two pools.
#
# It lives HERE rather than in a second cleaner script on its own cron line: same
# tick, same flock, same listing, same destroy helper the reap uses. Two cleaners
# racing one app is the sprawl this pool already learned about.
#
# It runs ONLY with a dedicated pool app (SPRAWL GUARD, above) and ONLY on a
# usable listing.
if [ -n "${POOL_APP:-}" ]; then
  SWEEP_F="$POOL/.sweep.json"   # dotfile: invisible to every *.json glob that reads this dir
  if [ "$LIST_OK" != 1 ]; then
    jq -nc --arg at "$(STAMP)" --arg why "${LIST_WHY:-no answer}" \
      '{at:$at,listing:"failed",reason:$why}' > "$SWEEP_F.tmp" 2>/dev/null \
      && mv "$SWEEP_F.tmp" "$SWEEP_F" || rm -f "$SWEEP_F.tmp"
  else
    # KNOBS, resolved once per tick, with the fallback documented in
    # docs/verification-map/fly-pool-sweep.md. A value that is not a number is
    # never silently clamped — it is named in the log and the fallback is used.
    pool_knob() { # pool_knob <env-value> <setting-key|""> <default> <label>
      local v="${1:-}" key="${2:-}" def="$3" label="$4"
      case "$v" in
        '') ;;
        *[!0-9]*) say "ignoring unusable $label='$v' (not a number) — falling back" ;;
        *) printf '%s\n' "$v"; return 0 ;;
      esac
      if [ -n "$key" ] && command -v setting_get >/dev/null 2>&1; then
        v=$(setting_get "$key" 2>/dev/null) || v=""
        case "$v" in
          '') ;;
          *[!0-9]*) say "ignoring unusable setting $key='$v' (not a number) — falling back to the documented default $def" ;;
          *) printf '%s\n' "$v"; return 0 ;;
        esac
      fi
      printf '%s\n' "$def"
    }
    TTL_S=$(pool_knob "${POOL_STOPPED_TTL_S:-}" pool_stopped_ttl_s 600 POOL_STOPPED_TTL_S)
    MAX_D=$(pool_knob "${POOL_SWEEP_MAX_DESTROY:-}" "" 25 POOL_SWEEP_MAX_DESTROY)
    NOWS=$(date -u +%s)
    SW_STOPPED='[]'; SW_UNAGED='[]'; SW_DESTROYED='[]'; SW_FAILED='[]'; SW_ORPHANS='[]'
    NLISTED=0; NSTOP=0; NUNAGED=0; NDESTROY=0; NFAIL=0; NORPH=0; NSPENT=0; CAPPED=false
    jq -r '.[] | [(.id // ""),(.state // ""),(.updated_at // "")] | @tsv' "$LISTING" 2>/dev/null > "$LISTING.rows"
    while IFS=$'\t' read -r SID SST SUP; do
      [ -n "$SID" ] || continue
      NLISTED=$((NLISTED+1))
      # A machine the REAP owns this tick is never the sweep's to touch. Its file
      # is the reap's claim on it; if the reap's own destroy failed, the file is
      # gone by now and this sweep picks the machine up on a later tick, once it
      # has actually stopped.
      [ -f "$POOL/$SID.json" ] && continue
      case "$REAPED_IDS" in *" $SID "*) continue ;; esac
      # Everything that is running, booting or already on its way out is left
      # alone — including bin/fly-pool-rollout.sh's untracked `started` smoke
      # machine, which is somebody else's in-flight work.
      case "$SST" in stopped|failed|suspended|destroyed) ;; *) continue ;; esac
      # AN UNKNOWN AGE IS NOT AN OLD AGE. A machine whose updated_at is missing or
      # unparseable is reported, never destroyed: this gate stands in front of an
      # irreversible call.
      SAGE=-1
      if [ -n "$SUP" ]; then
        SEP=$(date -u -d "$SUP" +%s 2>/dev/null) || SEP=""
        case "$SEP" in ''|*[!0-9]*) SEP="" ;; esac
        [ -n "$SEP" ] && SAGE=$((NOWS - SEP))
      fi
      if [ "$SAGE" -lt 0 ]; then
        SW_UNAGED=$(jq -c --arg m "$SID" '. + [$m]' <<<"$SW_UNAGED"); NUNAGED=$((NUNAGED+1)); continue
      fi
      if [ "$SAGE" -lt "$TTL_S" ] || [ "$NSPENT" -ge "$MAX_D" ]; then
        [ "$SAGE" -ge "$TTL_S" ] && CAPPED=true
        SW_STOPPED=$(jq -c --arg m "$SID" --arg s "$SST" --argjson a "$SAGE" \
          '. + [{machine:$m,state:$s,age_s:$a}]' <<<"$SW_STOPPED"); NSTOP=$((NSTOP+1)); continue
      fi
      if destroy_machine "$SID" "swept: $SST for ${SAGE}s"; then
        SW_DESTROYED=$(jq -c --arg m "$SID" '. + [$m]' <<<"$SW_DESTROYED")
      else
        SW_FAILED=$(jq -c --arg m "$SID" --argjson rc "${DESTROY_RC:-1}" --arg e "${DESTROY_ERR:-}" \
          '. + [{machine:$m,rc:$rc,error:$e}]' <<<"$SW_FAILED"); NFAIL=$((NFAIL+1))
      fi
      # >>> machines rows (BH-1035)
      # Close the sweep machine row from the actual destroy outcome. Placed
      # after the if/else so BOTH arms close: a destroy the API refused is a
      # `destroy_failed` row, not a missing one.
      machines_row_close "$SID"
      # <<< machines rows
      # A refused destroy spent the same API call a successful one did, so it
      # counts against the per-tick bound either way.
      NSPENT=$((NSPENT+1))
    done < "$LISTING.rows"
    NDESTROY=$(jq -r 'length' <<<"$SW_DESTROYED")
    # ORPHANS: a job still tracked on a machine Fly no longer returns, AFTER the
    # reap has run. Normally none — the reap's dead path closed them. One that
    # survives is a job nothing will ever finish, so it pages — once per tick,
    # after the loop: pool/*.json has no bound when the cap is unlimited, and a
    # partial Fly listing orphans every row at once.
    ORPH=()
    for OMF in "$POOL"/*.json; do
      [ -f "$OMF" ] || continue
      OMID=$(jq -r '.machine // ""' "$OMF" 2>/dev/null)
      [ -n "$OMID" ] && [ "$OMID" != null ] || continue
      jq -e --arg m "$OMID" 'any(.[]; .id==$m)' "$LISTING" >/dev/null 2>&1 && continue
      OKEY=$(jq -r '.key // ""' "$OMF" 2>/dev/null); OTIC=$(jq -r '.ticket_id // ""' "$OMF" 2>/dev/null)
      SW_ORPHANS=$(jq -c --arg m "$OMID" --arg k "$OKEY" --arg t "$OTIC" \
        '. + [{machine:$m,key:$k,ticket_id:$t}]' <<<"$SW_ORPHANS"); NORPH=$((NORPH+1))
      OAF="$HARNESS/flags/alerted-pool-orphan-$P-$OKEY-$(date -u +%Y%m%d)"
      if [ ! -f "$OAF" ]; then
        mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$OAF" 2>/dev/null
        ORPH+=("$OKEY still tracked on $OMID")
      fi
    done
    if [ "${#ORPH[@]}" = 1 ]; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] ${ORPH[0]} which Fly no longer returns after the reap — the dead path did not close it"
    elif [ "${#ORPH[@]}" -gt 1 ]; then
      _OJ=$(printf '%s; ' "${ORPH[@]}")
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] ${#ORPH[@]} jobs still tracked on machines Fly no longer returns after the reap — the dead path did not close them: ${_OJ%; }"
    fi
    # BH-7382: a claimed fly row of this hub with no queue file, no job file and
    # no live machine goes back to queued after POOL_ORPHAN_ROW_RELEASE_S.
    command -v pool_orphan_rows_step >/dev/null 2>&1 && pool_orphan_rows_step
    jq -nc --arg at "$(STAMP)" --argjson listed "$NLISTED" --argjson ttl "$TTL_S" \
      --argjson capped "$CAPPED" --argjson stopped "$SW_STOPPED" --argjson unaged "$SW_UNAGED" \
      --argjson destroyed "$SW_DESTROYED" --argjson df "$SW_FAILED" --argjson oj "$SW_ORPHANS" \
      '{at:$at,listing:"ok",listed:$listed,ttl_s:$ttl,capped:$capped,stopped:$stopped,
        unaged:$unaged,destroyed:$destroyed,destroy_failed:$df,orphan_jobs:$oj}' \
      > "$SWEEP_F.tmp" 2>/dev/null && mv "$SWEEP_F.tmp" "$SWEEP_F" || rm -f "$SWEEP_F.tmp"
    # ONE GREPPABLE LINE, and only when there is something to say: a count that
    # lives only in a JSON field is a count nobody reads (BH-660 asks for exactly
    # this). A clean tick stays quiet.
    if [ $((NSTOP + NUNAGED + NDESTROY + NFAIL + NORPH)) -gt 0 ]; then
      say "sweep $P: listed=$NLISTED stopped=$((NSTOP + NUNAGED)) destroyed=$NDESTROY destroy_failed=$NFAIL orphans=$NORPH ttl=${TTL_S}s$([ "$CAPPED" = true ] && echo " capped")"
    fi
  fi
fi
# <<< dead-machine sweep

# ---------- SPAWN ----------
# EVERY QUEUED JOB THIS TICK CAN AFFORD, ALL AT ONCE (the operator, 2026-09-13: "change
# the rule so we never lock and serialize"). Each spawn is ~40-60s of waiting —
# `machine run`, a 20s boot sleep, an sftp harness push, an env bundle — and this
# loop used to do them one after another inside the tick, so 14 queued jobs took
# 7 ticks (~15 min) to reach a pool that could hold them all immediately. The
# waiting is now concurrent: the budget is computed ONCE up front, that many
# subshells are launched, and each writes its own $POOL/<mid>.json exactly as
# before. Nothing takes turns, and since 2026-09-14 nothing is capped either
# unless someone wrote a number down (see the budget just below).
if [ "${POOL_SPAWN:-1}" = 0 ]; then exit 0; fi
# The lane-failure hold (2026-09-23, see POOL_LANE_FAIL_HOLD_S): while it stands
# a new machine would only meet the same exhausted lane, so nothing is spawned.
if HOLDWHY=$(pool_spawn_held); then
  say "spawn hold: the runner lane failed ($HOLDWHY) — no spawns until $(date -u -d "@$(cut -d' ' -f1 "$(pool_spawn_hold_path)" 2>/dev/null)" '+%H:%MZ' 2>/dev/null || echo 'the hold expires')"
  exit 0
fi
# LOAD SHED (BH-7509): while state/hub-load/verdict says the hub is over
# hub_load.max_runnable, this tick spawns nothing. REAP and the sweep above
# already ran; the queued job files stay for the next tick. No verdict file
# (every box but the hub, every Fly machine) or a stale one: no shed.
# shellcheck source=bin/lib/hub-load-shed.sh
. "$HARNESS/bin/lib/hub-load-shed.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/hub-load-shed.sh" 2>/dev/null \
  || hls_over() { return 1; }
if hls_over "$HARNESS"; then
  say "$HLS_LINE — no spawns this tick (reap ran)"
  exit 0
fi
LIVE=$(ls "$POOL" 2>/dev/null | wc -l)
# --- AUTOSCALE: THE QUEUE SETS THE MACHINE COUNT (the operator, 2026-09-14) -----------
# "we can launch unlimited builders with fly.io" — so the budget is the DEPTH of
# this project's queue, not a countdown to a number we picked. Every queued build
# gets its own machine THIS tick: 40 queued tickets spawn 40 machines, and they
# do not wait on a sibling project's tick either (bin/fly-pool-tick.sh ticks the
# projects together for the same reason).
# WHAT COUNTS AS QUEUED: the files in state/build-queue/<p>, which are this
# project's materialised ledger rows — bin/fly-dispatch.sh writes one per
# `queued` row and CLAIMS the row as it does — minus the *.failed.json parks. A
# job that is already running had its file moved away at spawn, so the count is
# what is genuinely waiting, and `running` below is the live machines serving
# the rest.
# An explicit cap (flags/fly-pool-<p>, fly/pool-caps.conf, POOL_CAP_MAX) still
# binds, for cost safety only; bin/pool-cap.sh prints 0 when there is none.
# KILL FLAG: POOL_AUTOSCALE=0 restores the pre-autoscale budget exactly — cap
# minus live, no queue reading, and no per-tick line.
QUEUED=$(ls "$QDIR"/*.json 2>/dev/null | grep -cv '\.failed\.json$')
# --- THE HOTFIX EXEMPTION (#368) ---------------------------------------------
# A cap is a COST ceiling, and an emergency ticket is the one row allowed past
# it — by one machine per hotfix, never a suspension of the cap: every plain job
# behind it still waits for the next tick.
#
# A PAUSE IS NOT A CAP. flags/paused-<p> is a human saying "stop building this
# project", and #368 puts overriding it explicitly out of scope — so the
# exemption is withheld there and the wait is logged instead. pool-halt-<p> (a
# health stop after repeated gate refusals) and the box slot lock are the same
# kind of decision and are likewise untouched: this block only ever adds to the
# budget a CAP produced.
HOT=0
if [ "$HOTFIX_ON" = 1 ]; then
  HOT=$(grep -l '"hotfix": *true' "$QDIR"/*.json 2>/dev/null | grep -cv '\.failed\.json$')
  case "$HOT" in ''|*[!0-9]*) HOT=0 ;; esac
fi
HOTFIX_EXTRA=0; HOT_TXT=""
if [ "$HOT" -gt 0 ]; then
  HOT_TXT=" hotfix=$HOT"
  if { command -v flag_active >/dev/null 2>&1 && flag_active "paused-$P" >/dev/null 2>&1; } \
     || { ! command -v flag_active >/dev/null 2>&1 && [ -f "$HARNESS/flags/paused-$P" ]; }; then
    say "$HOT hotfix job(s) queued but paused-$P is set — exemption not applied, waiting on the pause (a pause is a human decision)"
  else
    HOTFIX_EXTRA=$HOT
  fi
fi
if [ "${POOL_AUTOSCALE:-1}" = 0 ]; then
  BUDGET=$((CAP - LIVE)); CAPTXT="$CAP"
else
  if [ "$CAP" -gt 0 ] 2>/dev/null; then
    BUDGET=$((CAP - LIVE)); [ "$BUDGET" -gt "$QUEUED" ] && BUDGET="$QUEUED"
    CAPTXT="$CAP"
  else
    BUDGET="$QUEUED"; CAPTXT=unlimited
  fi
  [ "$BUDGET" -lt 0 ] && BUDGET=0
  # ONE line per tick, because throughput that nobody can grep is a claim: this
  # is how "the pool is keeping up" stops being a guess (the operator, 2026-09-14).
  say "pool $P: queued=$QUEUED running=$LIVE spawning=$BUDGET cap=$CAPTXT$HOT_TXT"
fi
# BH-7107: queued work, no slot and nothing building for POOL_STALL_ALERT_S pages once an hour, with its cause.
command -v pool_stall_tick >/dev/null 2>&1 && pool_stall_tick
# BH-7382: queued > POOL_UNDERUSE_QUEUE_MIN and building < POOL_UNDERUSE_PCT of capacity for POOL_UNDERUSE_ALERT_S pages once an hour.
command -v pool_underuse_tick >/dev/null 2>&1 && pool_underuse_tick
# BH-6536: a ticket held in the review column by a human step says why it is not queued.
command -v nh_sd_stage_lines >/dev/null 2>&1 && while IFS=$'\t' read -r SK _ SST _ SRE; do
  [ -e "$QDIR/$SK.json" ] || say "pool $P: $SK not queued :: $SST: $SRE"
done < <(nh_sd_stage_lines "$P")
[ "$BUDGET" -gt 0 ] || [ "$HOTFIX_EXTRA" -gt 0 ] || exit 0
# pipeline-health halts spawns after 2 consecutive gate refusals — every
# refused spawn costs ~10min of performance-8x proving the same drift again.
# A harness deploy clears the flag (new code = new chance).
if command -v routing_halted >/dev/null 2>&1; then _POOL_HALTED() { routing_halted "$P"; }; else _POOL_HALTED() { [ -f "$HARNESS/flags/pool-halt-$P" ]; }; fi
_POOL_HALTED && { say "spawns halted for $P (pool-halt flag; deploy clears)"; exit 0; }
# An ephemeral pool app is routinely EMPTY (every machine is destroyed after
# its job), so the copy-the-first-machine trick can't bootstrap it — fall back
# to the ref fly-image-build.sh recorded. Machines-list first so a live pool
# keeps cloning exactly what it's already running.
# Resolved ONCE per tick rather than once per job: it is the same answer for every
# spawn in the burst, and it is two API calls each.
IMAGE=$(timeout 30 "$FLY" machines list -a "$APP" --json 2>/dev/null | jq -r '.[0].config.image // ""')
# Prefer the REF fly-image-build.sh recorded when it is NEWER than what the
# live pool runs: deployment ids are ULIDs, so a plain string compare orders
# them. Cloning the running machine's image kept every spawn on the stale
# bake until the pool emptied — the 2026-09-11 per-machine box-name fix sat
# unused while an old-image build held the pool open (TK-270 refused x6).
# BH-2523: the fly_images row's active digest first, the file when it gives none.
REC=""
declare -F fir_digest >/dev/null 2>&1 && { REC=$(fir_digest "$P" 2>/dev/null) || REC=""; }
[ -n "$REC" ] || REC=$(cat "$HARNESS/state/fly/$P.image" 2>/dev/null)
if [ -n "$REC" ] && { [ -z "$IMAGE" ] || [ "${REC##*:}" \> "${IMAGE##*:}" ]; }; then IMAGE="$REC"; fi
[ -n "$IMAGE" ] || { say "no image found for $APP — cannot spawn"; exit 0; }

