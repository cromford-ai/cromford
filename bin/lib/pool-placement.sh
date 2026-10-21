# shellcheck shell=bash
# bin/lib/pool-placement.sh — BH-7505: the pool tick of ONE project on a
# lane-run machine, with the hub as fallback. Sourced by bin/fly-pool.sh and by
# bin/fly-pool-project.sh, never run. The pattern is BH-6890's
# (bin/lib/mc/project-placement.sh): a settings row places the project, the
# hub enqueues one lane_runs row, a machine runs it under the project lease.
#
#   lane_placement.fly-pool.<project>   fly | hub | box:<name>
#                                       (bin/lib/lane-placement.sh;
#                                       then the lane row lane_placement.fly-pool
#                                       and its hub_only text. The default row
#                                       does NOT place a pool: a pool moves by
#                                       a row that names it.)
#   lane_fallback.fly-pool.<project>    hub (no row, any other value) | off
#
# With the project placed fly, the hub's tick of that project (bin/fly-pool.sh,
# after its per-project flock and the lane gate) calls pp_gate. The gate
# enqueues ONE lane_runs row (lane fly-pool, args bin/fly-pool-project.sh
# <project>) and returns 0: the hub does no row work. A machine claims the row,
# takes the project lease, runs bin/fly-pool.sh with POOL_ON_MACHINE=1 and
# returns the write-backs. The partial unique index lane_runs_live keeps one
# live row per project.
#
# BOX PLACEMENT (BH-7636). box:<name> on the project row is handled as fly:
# the same row, and only the box <name> claims it (bin/lane-run-worker.sh --box
# <name> from the box's own cron). A claimed row whose lease ran out
# POOL_FLY_QUEUE_STALE_S ago or more is stale (box-silent): withdrawn with
# expired:1 and taken back. A take-back writes ONE ALERTS line per outage
# (bin/lane-alert.sh --id pool-box-<project>), held by <project>.box-down until
# the box answers again (a live claimed row, or a row with a run result) or the
# placement is hub. Log lines say `placed box:<name>` instead of `placed fly`.
#
# ONE RUN AT A TIME, ACROSS HUB AND FLY. The project lease (lane fly-pool,
# BH-6883) is the lock: a machine run holds it for the whole run, and a hub
# tick holds it for its whole run when a Fly run is possible (the project is
# placed fly, or was last tick and the row has just moved back). A second
# holder gets rc 3 and does nothing. The hub's own flock
# locks/fly-pool-<project>.lock stays, for two hub ticks. A run that loses the
# lease stops at its next spend: pp_fence_ok runs before a spawn and before a
# destroy.
#
#   pp_gate <project>
#       rc 0 = handled here, the hub runs nothing more for this project this
#       tick. rc 1 = the hub runs today's tick (not placed fly with no mark, or
#       a fallback, a take-back, a backoff, a rollback). With rc 1 after a fly
#       placement the hub holds the project lease until bin/fly-pool.sh ends
#       (pp_release). One log line per decision, `placed fly: ...`.
#   pp_none_fly
#       rc 0 when a FRESH box settings cache (state/settings-cache.json) says
#       no lane_placement.fly-pool row is fly and no project has a placed mark:
#       the hub skips the gate with one jq read.
#   pp_newest <rows-json> <project> <now-epoch> <stale-s> [box 0|1]
#       one line `<kind> <id> <detail>` for the NEWEST row of <project>, matched
#       by the exact project name (a prefix read also lists sibling projects,
#       and the window is _PP_ROWS_LIMIT rows). kind: none, unread (the window
#       was full and holds no row of <project>: not known), live (queued less than <stale-s> ago, or claimed), stale (queued
#       <stale-s> or more; detail = its age; with box 1 also claimed with a
#       lease_until <stale-s> or more in the past, detail box-silent), failed (died, failed, a done rc
#       that is not 0, or a done row with no `PROF fly-pool-project` line),
#       deferred (a done row whose PROF line has deferred=<w>, w not `-`),
#       withdrawn (died with a prof_line that starts `withdrawn `), done.
#   pp_publish <project>
#       applies the project's pending write-backs (every call) and publishes its
#       snapshot, at most once per POOL_FLY_PUBLISH_MIN_S (fallback 120 s).
#   pp_fence_ok
#       rc 0 = go on; rc 99 = the lease is lost, write nothing. With no
#       POOL_LEASE_FENCE it does nothing. A renew that cannot be answered is rc
#       99 on a machine (POOL_ON_MACHINE=1, it has no other lock) and rc 0 on
#       the hub (its flock still holds).
#   pp_checkpoint <project> <why>
#       a machine run posts what it changed as one write-back (lri_checkpoint).
#       A failure logs one line; the final write-back retries it.
#   pp_release
#       the hub tick's end: stops the renewer, releases the lease. Safe to call
#       with no lease. bin/fly-pool.sh calls it from both of its EXIT traps.
#
# Files under state/pool-fly/ (hub only):
#   <project>.placed      the last placement read was fly (fail closed when the
#                         next read cannot be answered; the rollback marker)
#   <project>.taken       the id of the finished row the hub already took back
#   <project>.takeback-at epoch of the last take-back (the backoff)
#   <project>.failed-n    consecutive machine-failed take-backs
#   <project>.box-down    a box placement's take-back alerted (BH-7636)
#   <project>.published-at, <project>.alert-at
#
# Knobs (lane fly-pool, catalog/lanes.d/fly-pool.knobs.d): POOL_FLY_QUEUE_STALE_S,
# POOL_FLY_TAKEBACK_BACKOFF_S, POOL_FLY_PUBLISH_MIN_S, POOL_FLY_ALERT_S,
# POOL_FLY_HUB_LEASE_TTL_S. The root is ${HARNESS:-${H:-}}. Defines functions only.

PP_LANE=fly-pool
PP_QUEUE_STALE_S=300
PP_BACKOFF_S=600
PP_PUBLISH_MIN_S=120
PP_ALERT_S=3600
PP_HUB_LEASE_TTL_S=600
PP_FAILED_ALERT_N=3
PP_RENEW_PID=""

_pp_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_pp_dir() { printf '%s/state/pool-fly' "$(_pp_root)"; }

# _pp_say <text> — bin/fly-pool.sh's `say` (the [pool/<project>] line), else stderr.
_pp_say() {
  if declare -F say >/dev/null 2>&1; then say "$*"; else printf '%s\n' "$*" >&2; fi
}

# _pp_int <ENV NAME> <fallback> [min] — a whole number min..86400 (min 1 unless
# given) from the env (a lane knob), else the fallback.
_pp_int() {
  local v="${!1:-}" min="${3:-1}"
  v=${v//[[:space:]]/}
  [[ $v =~ ^[0-9]{1,5}$ ]] && [ "$((10#$v))" -ge "$min" ] && [ "$((10#$v))" -le 86400 ] || v="$2"
  printf '%s' "$((10#$v))"
}

# _pp_put <file> <line> — one line into a state file, its dir made first.
_pp_put() {
  { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; } 2>/dev/null
  return 0
}

# _pp_client — rc 0 when lp_decide, lp_enqueue, setting_get and _jobs_req exist
# and the lease client is loaded.
_pp_client() {
  local root; root=$(_pp_root)
  if ! declare -F lp_decide >/dev/null 2>&1; then
    [ -n "$root" ] && [ -r "$root/bin/lib/lane-placement.sh" ] || return 1
    # shellcheck source=bin/lib/lane-placement.sh
    . "$root/bin/lib/lane-placement.sh" || return 1
  fi
  _lp_client || return 1
  if ! declare -F pjl_acquire >/dev/null 2>&1; then
    [ -r "$root/bin/lib/project-lease.sh" ] || return 1
    # shellcheck source=bin/lib/project-lease.sh
    . "$root/bin/lib/project-lease.sh" || return 1
  fi
  return 0
}

# pp_none_fly — see the header. One jq read; rc 1 = gate (a fly row, a mark, or
# no fresh cache).
pp_none_fly() {
  local root f ttl ans
  root=$(_pp_root); f="$root/state/settings-cache.json"
  compgen -G "$(_pp_dir)/*.placed" >/dev/null 2>&1 && return 1
  [ -r "$f" ] || return 1
  ttl="${JOBS_SETTINGS_CACHE_S:-${LANE_GATE_CACHE_S:-60}}"
  [[ $ttl =~ ^[0-9]+$ ]] && [ "$ttl" -gt 0 ] || return 1
  ans=$(jq -r --argjson now "$(date -u +%s)" --argjson ttl "$ttl" '
    ((.fetched_at | tonumber?) // 0) as $f
    | if ($now - $f) < 0 or ($now - $f) >= $ttl then "stale"
      else [((.seeded // {}) + (.values // {})) | to_entries[]
             | select(.key | startswith("lane_placement.fly-pool"))
             | select(.key | endswith(".hub_only") | not)
             | (.value | tostring | ascii_downcase | gsub("\\s"; ""))]
           | if any(. == "fly" or startswith("box:")) then "fly" else "none" end
      end' "$f" 2>/dev/null)
  [ "$ans" = none ]
}

# _pp_decide <project> — rc 0 placed fly or box:<name>, rc 1 hub, rc 3 not
# known (no jobs client, or the row could not be read). The default row never
# places a pool. Sets PP_BOX (the box name, empty for fly) and PP_TAG.
_pp_decide() {
  PP_BOX=""; PP_TAG="placed fly"
  _pp_client || { LP_WHY="no jobs client"; return 3; }
  lp_decide "$PP_LANE" "$1"
  [ "$LP_PLACE" = fly ] && case "$LP_WHY" in lane_placement.default=*) ;; *) return 0 ;; esac
  if [ "$LP_PLACE" = box ] && [ -n "${LP_BOX:-}" ]; then PP_BOX="$LP_BOX"; PP_TAG="placed box:$LP_BOX"; return 0; fi
  case "$LP_WHY" in "no jobs client"|"settings unreadable") return 3 ;; esac
  return 1
}

# _pp_fallback <project> — hub or off.
_pp_fallback() {
  local v
  if _pp_client && _setting_key_ok "lane_fallback.$PP_LANE.$1" \
     && v=$(setting_get "lane_fallback.$PP_LANE.$1" 2>/dev/null) \
     && [ "$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" = off ]; then
    printf off; return 0
  fi
  printf hub
}

# _PP_ROWS_LIMIT — the most rows the route lists (worker/jobs/src/routes/lane-runs.js
# LIST_LIMIT_MAX). A read asks for all of them: the project filter is a prefix
# range, so the project's own newest row can sit behind sibling projects' rows.
_PP_ROWS_LIMIT=50

# _pp_rows <project> [live] — the lane_runs rows of the project (prefix read, the
# whole window). rc and JOBS_HTTP are _jobs_req's.
_pp_rows() {
  _jobs_req GET "/api/lane-runs/by-prefix?lane=$PP_LANE&project_prefix=$1${2:+&live=1}&limit=$_PP_ROWS_LIMIT"
}

pp_newest() {
  local box=0; [ "${5:-0}" = 1 ] && box=1
  printf '%s' "${1:-}" | jq -r --arg p "${2:-}" --argjson now "${3:-0}" --argjson st "${4:-300}" --argjson box "$box" '
    (.truncated == true) as $trunc
    | (.rows | if type == "array" then . else error("no rows") end) as $all
    | (first($all[] | select(.project == $p)) // null) as $r
    | if $r == null and $trunc then "unread - -"
      elif $r == null then "none - -"
      else ($r.status // "") as $s | ($r.prof_line // "") as $pl | ($r.id | tostring) as $id
        | if $s == "died" and ($pl | startswith("withdrawn ")) then "withdrawn \($id) -"
          elif $s == "claimed" and $box == 1
               and ((($r.lease_until // "") | try fromdateiso8601 catch null) as $l | $l != null and ($now - $l) >= $st)
            then "stale \($id) box-silent"
          elif $s == "claimed" then "live \($id) claimed"
          elif $s == "queued" then
            ((($r.enqueued_at // "") | try fromdateiso8601 catch null)) as $t
            | if $t != null and ($now - $t) >= $st then "stale \($id) \($now - $t)" else "live \($id) queued" end
          elif $s == "died" then "failed \($id) died"
          elif $s == "failed" then "failed \($id) rc=\($r.rc)"
          elif $s != "done" then "live \($id) \($s)"
          elif ($r.rc != null and $r.rc != 0) then "failed \($id) rc=\($r.rc)"
          elif ($pl | test("(^| )PROF fly-pool-project ")) | not then "failed \($id) no-prof"
          else ($pl | capture("(^| )deferred=(?<d>[^ ]+)").d // "-") as $d
            | if $d != "-" then "deferred \($id) \($d)" else "done \($id) -" end
          end
      end' 2>/dev/null
}

# _pp_alert <project> <text> — ONE ALERTS line per project per POOL_FLY_ALERT_S.
_pp_alert() {
  local p="$1" text="$2" d stamp now last every a
  d=$(_pp_dir); stamp="$d/$p.alert-at"; now=$(date -u +%s)
  last=$(head -n 1 "$stamp" 2>/dev/null)
  every=$(_pp_int POOL_FLY_ALERT_S "$PP_ALERT_S")
  if [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$every" ]; then
    _pp_say "${PP_TAG:-placed fly}: alert held (one per ${every}s): $text"; return 0
  fi
  _pp_put "$stamp" "$now"
  a="$(_pp_root)/bin/lane-alert.sh"
  [ -x "$a" ] && "$a" --severity warn --id "fly-pool-fly-$p" fly-pool \
    "fly-pool $p (placed fly, fallback $(_pp_fallback "$p")): $text" >/dev/null 2>&1
  return 0
}

pp_publish() {
  local p="$1" root stamp now last out
  # Builtins for the clock and the stamp: this runs once per fly project per
  # tick (BH-7432 counts the forks of that tick).
  root=$(_pp_root); stamp="$(_pp_dir)/$p.published-at"; printf -v now '%(%s)T' -1
  if ! declare -F lri_publish >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-run-inputs.sh
    [ -r "$root/bin/lib/lane-run-inputs.sh" ] && . "$root/bin/lib/lane-run-inputs.sh" 2>/dev/null
  fi
  declare -F lri_publish >/dev/null 2>&1 || { _pp_say "${PP_TAG:-placed fly}: no lane-run-inputs lib — the cron publisher's snapshot is used"; return 1; }
  # The apply runs every time (one list call when nothing is pending): a
  # finished run's write-backs are the hub's state before the next row's
  # snapshot is cut. Only the publish is throttled.
  out=$(lri_apply_pending "$PP_LANE" "$p" 2>&1) || _pp_say "${PP_TAG:-placed fly}: write-back apply failed ($(printf '%s' "$out" | tail -n 1))"
  last=""; { IFS= read -r last < "$stamp"; } 2>/dev/null
  [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$(_pp_int POOL_FLY_PUBLISH_MIN_S "$PP_PUBLISH_MIN_S")" ] && return 0
  out=$(lri_publish "$PP_LANE" "$p" 2>&1) || { _pp_say "${PP_TAG:-placed fly}: snapshot publish failed ($(printf '%s' "$out" | tail -n 1))"; return 1; }
  _pp_put "$stamp" "$now"
  return 0
}

# _pp_apply <project> — the hub takes in what the machines wrote BEFORE it works
# the project itself: a hub tick on stale state would change the project's
# files, and the next compare-and-set apply of the machine's write-back would
# keep the hub's copy and drop the machine's. rc 0 = applied (or nothing to
# apply); PP_APPLY_WHY holds the line.
_pp_apply() {
  local p="$1" root out
  root=$(_pp_root)
  if ! declare -F lri_apply_pending >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-run-inputs.sh
    [ -r "$root/bin/lib/lane-run-inputs.sh" ] && . "$root/bin/lib/lane-run-inputs.sh" 2>/dev/null
  fi
  declare -F lri_apply_pending >/dev/null 2>&1 || { PP_APPLY_WHY="no lane-run-inputs lib"; return 1; }
  out=$(lri_apply_pending "$PP_LANE" "$p" 2>&1) || { PP_APPLY_WHY=$(printf '%s' "$out" | tail -n 1); return 1; }
  PP_APPLY_WHY="$out"
  return 0
}

# _pp_holder — this hub's lease holder id: hub-<hostname>, one id for every hub
# tick (the hub flock serialises them), reduced to [A-Za-z0-9._-], 64 at most.
_pp_holder() {
  local h; h="hub-$(hostname 2>/dev/null)"; h="${h//[^A-Za-z0-9._-]/_}"; printf '%s' "${h:0:64}"
}

# _pp_renew_loop <parent-pid> <project> <holder> <fence> <stop-file> <every-s>
# Runs in a background subshell. It ends with its parent, so a killed tick does
# not keep the lease alive; a `lost` answer touches the stop file and ends it.
_pp_renew_loop() {
  local parent="$1" p="$2" h="$3" f="$4" stop="$5" every="$6" rc
  while kill -0 "$parent" 2>/dev/null; do
    sleep "$every"
    kill -0 "$parent" 2>/dev/null || break
    pjl_renew "$PP_LANE" "$p" "$h" "$f" >/dev/null 2>&1; rc=$?
    [ "$rc" = 3 ] && { : > "$stop"; break; }
  done
}

# _pp_prune_stop <project> — remove the stop files of hub ticks that are gone
# (state/pool-fly/<project>.stop.<pid>, left by a tick that was killed before
# pp_release). A file whose pid is alive is kept.
_pp_prune_stop() {
  local f pid
  for f in "$(_pp_dir)/$1".stop.*; do
    [ -e "$f" ] || continue
    pid="${f##*.}"
    [[ $pid =~ ^[0-9]+$ ]] || continue
    [ "${f%.*}" = "$(_pp_dir)/$1.stop" ] || continue
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done
  return 0
}

# _pp_lease_take <project> — rc 0 = held (the fence and the stop file are
# exported for pp_fence_ok, and a renewer runs), rc 3 = another holder has it,
# rc 1 = not answered (the caller, _pp_take, fails closed).
_pp_lease_take() {
  local p="$1" h f ttl stop
  _pp_prune_stop "$p"
  h=$(_pp_holder); ttl=$(_pp_int POOL_FLY_HUB_LEASE_TTL_S "$PP_HUB_LEASE_TTL_S")
  [ "$ttl" -le 900 ] || ttl=900
  export PJL_TTL_S="$ttl"
  f=$(pjl_acquire "$PP_LANE" "$p" "$h"); case $? in 0) ;; 3) unset PJL_TTL_S; return 3 ;; *) unset PJL_TTL_S; return 1 ;; esac
  stop="$(_pp_dir)/$p.stop.$$"; mkdir -p "$(_pp_dir)" 2>/dev/null; rm -f "$stop"
  export POOL_LEASE_FENCE="$f" POOL_LEASE_PROJECT="$p" POOL_LEASE_HOLDER="$h" POOL_STOP_FILE="$stop"
  # fd 8 is the tick's flock and must never reach the renewer: a renewer that
  # outlives the tick by one sleep would turn the next tick away.
  ( _pp_renew_loop "$$" "$p" "$h" "$f" "$stop" "$((ttl / 5 > 0 ? ttl / 5 : 1))" ) </dev/null >/dev/null 2>&1 8>&- &
  PP_RENEW_PID=$!
  return 0
}

pp_release() {
  [ -n "${POOL_LEASE_FENCE:-}" ] && [ -n "${PP_RENEW_PID:-}" ] || return 0
  kill "$PP_RENEW_PID" 2>/dev/null; wait "$PP_RENEW_PID" 2>/dev/null
  PP_RENEW_PID=""
  declare -F pjl_release >/dev/null 2>&1 \
    && pjl_release "$PP_LANE" "${POOL_LEASE_PROJECT:-}" "${POOL_LEASE_HOLDER:-}" "$POOL_LEASE_FENCE" >/dev/null 2>&1
  [ -z "${POOL_STOP_FILE:-}" ] || rm -f "$POOL_STOP_FILE"
  unset POOL_LEASE_FENCE POOL_LEASE_PROJECT POOL_LEASE_HOLDER POOL_STOP_FILE PJL_TTL_S
  return 0
}

pp_fence_ok() {
  [ -n "${POOL_LEASE_FENCE:-}" ] || return 0
  if [ -n "${POOL_STOP_FILE:-}" ] && [ -e "$POOL_STOP_FILE" ]; then return 99; fi
  local p="${POOL_LEASE_PROJECT:-}" h="${POOL_LEASE_HOLDER:-}" rc=1
  # BH-7519: bin/fly-pool.sh runs as a CHILD of bin/fly-pool-project.sh, so it
  # does not inherit that script's pjl_* functions, and it never sources the lease
  # client itself (the hub gate does, through _pp_client, and a machine tick skips
  # the gate). Without this load every machine fence read `renew unavailable`.
  if ! declare -F pjl_renew >/dev/null 2>&1 && [ -r "$(_pp_root)/bin/lib/project-lease.sh" ]; then
    # shellcheck source=bin/lib/project-lease.sh
    . "$(_pp_root)/bin/lib/project-lease.sh" 2>/dev/null
  fi
  if declare -F pjl_renew >/dev/null 2>&1; then
    pjl_renew "$PP_LANE" "$p" "$h" "$POOL_LEASE_FENCE" >/dev/null 2>&1; rc=$?
  fi
  case "$rc" in
    0) return 0 ;;
    3) _pp_say "$p project lease lost (fence $POOL_LEASE_FENCE) — spend stopped"
       [ -n "${POOL_STOP_FILE:-}" ] && : > "$POOL_STOP_FILE" 2>/dev/null
       return 99 ;;
  esac
  if [ "${POOL_ON_MACHINE:-}" = 1 ]; then
    _pp_say "$p project lease renew unavailable on a lane-run machine — spend stopped"; return 99
  fi
  return 0
}

pp_checkpoint() {
  local p="${1:-}" why="${2:-}" out
  [ "${POOL_ON_MACHINE:-}" = 1 ] && [ -n "${LANE_RUN_ID:-}" ] && [ -n "$p" ] || return 0
  declare -F lri_checkpoint >/dev/null 2>&1 || {
    # shellcheck source=bin/lib/lane-run-inputs.sh
    [ -r "$(_pp_root)/bin/lib/lane-run-inputs.sh" ] && . "$(_pp_root)/bin/lib/lane-run-inputs.sh" 2>/dev/null
  }
  declare -F lri_checkpoint >/dev/null 2>&1 || { _pp_say "$why: no lane-run-inputs lib — the write-back is not posted"; return 1; }
  out=$(lri_checkpoint "$PP_LANE" "$p" 2>&1) \
    || { _pp_say "$why: write-back not posted ($(printf '%s' "$out" | tail -n 1)) — the final write-back retries it"; return 1; }
  return 0
}

# _pp_take <project> <word> <detail> — the hub runs this tick. Applies the
# machines' write-backs first, then takes the project lease. rc 1 = run on the
# hub; rc 0 = no hub work (a write-back could not be applied, a Fly run holds
# the lease, or the lease request was not answered).
_pp_take() {
  local p="$1" w="$2" det="$3"
  if ! _pp_apply "$p"; then
    _pp_say "${PP_TAG:-placed fly}: $w ($det) held — the machine's write-backs were not applied (${PP_APPLY_WHY:-?}); no hub work this tick"
    return 0
  fi
  _pp_lease_take "$p"
  case $? in
    0) _pp_say "${PP_TAG:-placed fly}: $w ($det) — this tick runs on the hub (${PP_APPLY_WHY:-applied})"; return 1 ;;
    3) _pp_say "a Fly run holds the project lease — $w ($det): no hub work this tick"; return 0 ;;
  esac
  # BH-7519: an unanswered lease is NOT a free project. A Fly run may hold it
  # right now, and the hub flock does not stop a machine. This function runs
  # only for a project placed fly or one with a placed mark, so it fails closed
  # (the same rule as _pp_unknown, #7446): no hub work, the next tick asks again.
  _pp_say "${PP_TAG:-placed fly}: $w ($det) — the project lease was not answered (http ${JOBS_HTTP:-none}); no hub work this tick"
  return 0
}

# _pp_fallback_run <project> <word> <detail> — a hub fallback, or with
# lane_fallback=off one held ALERTS line and rc 0.
_pp_fallback_run() {
  local p="$1" w="$2" det="$3"
  if [ "$(_pp_fallback "$p")" = off ]; then
    _pp_say "${PP_TAG:-placed fly}: $w ($det) and lane_fallback.$PP_LANE.$p=off — the hub runs nothing for $p this tick"
    _pp_alert "$p" "$w ($det); the hub runs nothing for this project while the fallback row is off. Rollback: set lane_placement.$PP_LANE.$p to hub."
    return 0
  fi
  _pp_take "$p" "fallback=$w" "$det"
}

# _pp_withdraw <project> <id> <why> [expired] — end a queued row before the hub
# takes the project; with expired = 1 (a box-silent row, BH-7636) also a claimed
# row whose lease ran out. rc 0 = ended, rc 3 = a machine claimed it (the row is
# live), rc 2 = not answered (the lease still keeps one run at a time).
_pp_withdraw() {
  local id="$2" why="$3" ex="${4:-0}" by rc
  by="hub-$(hostname 2>/dev/null)"; by="${by//[^A-Za-z0-9._-]/_}"; by="${by:0:64}"
  _jobs_req POST "/api/lane-runs/$id/withdraw" "$(jq -nc --arg b "$by" --arg w "$why" --arg e "$ex" \
    '{by:$b, why:$w} + (if $e == "1" then {expired:1} else {} end)')" >/dev/null; rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 9 ] && [ "$(printf '%s' "${JOBS_BODY:-}" | jq -r '.reason // empty' 2>/dev/null)" = not_queued ]; then return 3; fi
  _pp_say "${PP_TAG:-placed fly}: withdraw of row $id not answered (http ${JOBS_HTTP:-none}) — a machine may still claim it; the lease keeps one run at a time"
  return 2
}

# _pp_backoff — rc 0 while the last take-back is younger than
# POOL_FLY_TAKEBACK_BACKOFF_S; PP_BACKOFF_LEFT = the seconds left.
_pp_backoff() {
  local at b now
  at=$(head -n 1 "$(_pp_dir)/$1.takeback-at" 2>/dev/null); [[ $at =~ ^[0-9]+$ ]] || return 1
  b=$(_pp_int POOL_FLY_TAKEBACK_BACKOFF_S "$PP_BACKOFF_S" 0); now=$(date -u +%s)
  PP_BACKOFF_LEFT=$((at + b - now))
  [ "$PP_BACKOFF_LEFT" -gt 0 ]
}

_pp_stamp_takeback() { _pp_put "$(_pp_dir)/$1.takeback-at" "$(date -u +%s)"; }

# _pp_failed_count <project> <inc|reset> — the consecutive machine-failed
# take-backs; prints the count.
_pp_failed_count() {
  local f n; f="$(_pp_dir)/$1.failed-n"
  n=$(head -n 1 "$f" 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] || n=0
  if [ "$2" = inc ]; then n=$((n + 1)); else n=0; fi
  _pp_put "$f" "$n"
  printf '%s' "$n"
}

# _pp_enqueue <project> — publish, then one lp_enqueue. rc 0 = a row is queued
# or live; rc 1 = not enqueued.
_pp_enqueue() {
  local p="$1" rc
  pp_publish "$p" || true
  lp_enqueue "$PP_LANE" "$p" "$(_pp_root)/bin/fly-pool-project.sh" "$p"; rc=$?
  case "$rc" in
    0) _pp_say "${PP_TAG:-placed fly}: enqueued $PP_LANE $p — no hub pool work this tick"; return 0 ;;
    3) _pp_say "${PP_TAG:-placed fly}: a row of $p is already live — no hub pool work this tick"; return 0 ;;
  esac
  return 1
}

# _pp_enqueue_or_backoff <project> — a row for the machines, unless the hub took
# the tick back less than the backoff ago and the fallback is hub: then the hub
# keeps this tick too, so a machine that cannot work does not cost a row a tick.
_pp_enqueue_or_backoff() {
  local p="$1"
  if [ "$(_pp_fallback "$p")" = hub ] && _pp_backoff "$p"; then
    _pp_take "$p" backoff "${PP_BACKOFF_LEFT}s left after a take-back"; return
  fi
  _pp_enqueue "$p" || _pp_fallback_run "$p" enqueue-failed "http ${JOBS_HTTP:-none}"
}

# _pp_box_down <project> <id> <detail> <stale-s> — a box placement's take-back
# (the withdraw answered 200): ONE ALERTS line per outage, held by
# <project>.box-down, written only after bin/lane-alert.sh answers rc 0.
_pp_box_down() {
  local p="$1" id="$2" det="$3" st="$4" f a what
  f="$(_pp_dir)/$p.box-down"
  if [ -e "$f" ]; then _pp_say "$PP_TAG: row $id taken back ($det); the box-down alert of this outage is already sent"; return 0; fi
  what="it did not claim row $id within ${st}s"
  [ "$det" = box-silent ] && what="it claimed row $id and then stopped answering for ${st}s or more"
  a="$(_pp_root)/bin/lane-alert.sh"
  [ -x "$a" ] || return 0
  "$a" --severity warn --id "pool-box-$p" fly-pool \
    "fly-pool $p is placed on box $PP_BOX, and $what. The hub withdrew the row and took the project back to the hub. The box gets a new row after POOL_FLY_TAKEBACK_BACKOFF_S. Check the box cron (lane-run-worker.sh --box $PP_BOX) and its logs/lane-run-worker.log. Undo: set lane_placement.fly-pool.$p to hub." \
    >/dev/null 2>&1 || return 0
  _pp_put "$f" "$id $(date -u +%s)"
  return 0
}

# _pp_box_up <project> — the box answered: the outage (if any) ends.
_pp_box_up() {
  local f; f="$(_pp_dir)/$1.box-down"
  [ -e "$f" ] || return 0
  rm -f "$f"; _pp_say "${PP_TAG:-placed fly}: the box answers again — the next take-back alerts again"
}

# _pp_stale <project> <id> <age-s|box-silent> — an unclaimed row (or, on a box
# placement, a row its box went silent on): withdrawn, then the hub runs the
# tick (fallback=no-capacity). A row claimed meanwhile is live.
_pp_stale() {
  local p="$1" id="$2" age="$3" wrc=2 st="${4:-}"
  if [ "$(_pp_fallback "$p")" = hub ]; then
    if [ "$age" = box-silent ]; then _pp_withdraw "$p" "$id" box-silent 1; wrc=$?
    else _pp_withdraw "$p" "$id" "stale-${age}s"; wrc=$?; fi
    if [ "$wrc" = 3 ]; then _pp_say "${PP_TAG:-placed fly}: row $id was claimed before the withdraw — no hub work this tick"; return 0; fi
    [ "$wrc" != 0 ] || { _pp_put "$(_pp_dir)/$p.taken" "$id"; _pp_stamp_takeback "$p"; }
    [ "$wrc" = 0 ] && [ -n "${PP_BOX:-}" ] && _pp_box_down "$p" "$id" "$age" "$st"
  fi
  if [ "$age" = box-silent ]; then _pp_fallback_run "$p" no-capacity "row $id: box-silent"
  else _pp_fallback_run "$p" no-capacity "row $id unclaimed: ${age}s"; fi
}

# _pp_failed <project> <kind> <id> <detail> — a finished row the machine could
# not use: taken back once, then the backoff decides.
_pp_failed() {
  local p="$1" kind="$2" id="$3" det="$4" nf
  if [ "$id" = "$(head -n 1 "$(_pp_dir)/$p.taken" 2>/dev/null)" ]; then _pp_enqueue_or_backoff "$p"; return; fi
  _pp_put "$(_pp_dir)/$p.taken" "$id"; _pp_stamp_takeback "$p"
  # A row with a run result is the box's answer; a `died` row is none.
  [ "$det" = died ] || _pp_box_up "$p"
  if [ "$kind" = failed ]; then
    kind=machine-failed; nf=$(_pp_failed_count "$p" inc)
    if [ "$nf" -ge "$PP_FAILED_ALERT_N" ]; then
      _pp_alert "$p" "$nf machine runs in a row failed ($det at row $id); the hub takes each one back. Check logs/lane-run-worker.log on the lane-run machines."
    fi
  else
    kind=machine-deferred; _pp_failed_count "$p" reset >/dev/null
  fi
  _pp_fallback_run "$p" "$kind" "row $id: $det"
}

# _pp_fly_row <project> — the project is placed fly: decide from its newest row.
_pp_fly_row() {
  local p="$1" d rows kind id det st boxed=0
  d=$(_pp_dir); mkdir -p "$d" 2>/dev/null
  [ -n "${PP_BOX:-}" ] && boxed=1
  _pp_put "$d/$p.placed" "${PP_BOX:+box:}${PP_BOX:-fly}"
  st=$(_pp_int POOL_FLY_QUEUE_STALE_S "$PP_QUEUE_STALE_S" 0)
  rows=$(_pp_rows "$p") \
    && read -r kind id det < <(pp_newest "$rows" "$p" "$(date -u +%s)" "$st" "$boxed") \
    && [ -n "$kind" ] || { kind=read-failed; id=-; det="http ${JOBS_HTTP:-none}"; }
  case "$kind" in
    live) [ "$det" = claimed ] && _pp_box_up "$p"
          _pp_say "${PP_TAG:-placed fly}: row $id is $det — no hub pool work this tick"; return 0 ;;
    stale) _pp_stale "$p" "$id" "$det" "$st" ;;
    failed|deferred) _pp_failed "$p" "$kind" "$id" "$det" ;;
    none|done|withdrawn) [ "$kind" != done ] || { _pp_failed_count "$p" reset >/dev/null; _pp_box_up "$p"; }
                         _pp_enqueue_or_backoff "$p" ;;
    *) _pp_fallback_run "$p" enqueue-failed "lane_runs read: $det" ;;
  esac
}

# _pp_row_ended <project> <kind> <id> <detail> — rc 0 when the newest row of the
# project is over (BH-7519): a queued row is withdrawn first, and only a withdraw
# answered rc 0 counts. A claimed row, a row that could not be read and a
# withdraw that was not answered are not over: the placed mark stays.
_pp_row_ended() {
  local p="$1" kind="$2" id="$3" det="$4"
  case "$kind:$det" in
    stale:*|live:queued) _pp_withdraw "$p" "$id" "rollback" >/dev/null && return 0; return 1 ;;
    none:*|done:*|failed:*|deferred:*|withdrawn:*) return 0 ;;
  esac
  return 1
}

# _pp_hub <project> — the row says hub. With no placed mark this is today's tick.
# With a mark the project was fly: a queued row is withdrawn so no machine claims
# it, and the hub takes the project lease, so a Fly run still in flight is
# never run beside the hub. The mark goes once the lease is held AND the newest
# row is over (_pp_row_ended); until then every tick takes this path again.
_pp_hub() {
  local p="$1" rows kind id det rc ended=1 d
  d=$(_pp_dir)
  [ -e "$d/$p.placed" ] || return 1
  if rows=$(_pp_rows "$p") && read -r kind id det < <(pp_newest "$rows" "$p" "$(date -u +%s)" 0) && [ -n "$kind" ]; then
    _pp_row_ended "$p" "$kind" "$id" "$det"; ended=$?
  fi
  _pp_take "$p" rollback "placement is hub again"; rc=$?
  [ "$rc" = 1 ] && [ "$ended" = 0 ] && [ -n "${POOL_LEASE_FENCE:-}" ] && rm -f "$d/$p.placed" "$d/$p.taken" "$d/$p.takeback-at" "$d/$p.box-down"
  [ "$rc" != 1 ] || [ "$ended" = 0 ] || _pp_say "${PP_TAG:-placed fly}: rollback keeps the placed mark — the newest row of $p is not over yet"
  return "$rc"
}

# _pp_unknown <project> — the placement could not be read. A project last
# placed fly, or with a live row, does no hub pool work (fail closed); any other
# project runs today's tick.
_pp_unknown() {
  local p="$1" rows
  if [ -e "$(_pp_dir)/$p.placed" ]; then
    _pp_say "${PP_TAG:-placed fly}: placement not readable ($LP_WHY) and $p was last placed fly — no hub pool work this tick"; return 0
  fi
  rows=$(_pp_rows "$p" live 2>/dev/null)
  if [ "$(printf '%s' "$rows" | jq -r --arg p "$p" '([.rows[]? | select(.project == $p)] | length) as $n | if $n == 0 and .truncated == true then 1 else $n end' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    _pp_say "${PP_TAG:-placed fly}: placement not readable ($LP_WHY) and a $PP_LANE row of $p is live — no hub pool work this tick"; return 0
  fi
  return 1
}

pp_gate() {
  local p="${1:-}" frc
  [ "${POOL_ON_MACHINE:-}" = 1 ] && return 1
  [ -n "$p" ] || return 1
  pp_none_fly && return 1
  _pp_decide "$p"; frc=$?
  case "$frc" in
    0) _pp_fly_row "$p" ;;
    3) _pp_unknown "$p" ;;
    *) _pp_hub "$p" ;;
  esac
}
