#!/bin/bash
# bin/lib/harness-sync-step.sh — the post-copy steps of bin/harness-sync.sh,
# bounded and named (BH-7122). Sourced, never executed. Sourced by
# bin/harness-sync.sh (in-process steps) and bin/harness-sync-step.sh (the
# runner of the three detached steps).
#
# WHY. fleet-propagate runs the whole of bin/harness-sync.sh under one outer
# timeout. The code copy (the rsyncs) runs early, and most kills land in the
# steps after it. Before this file a kill there was a CRITICAL "Still running
# the OLD harness: hub" page while the live bin/ was already at the new sha.
# So harness-sync now writes down how far it got, cuts each foreground step at
# its own timeout, and keeps a marker for each deploy step until it succeeds.
#
# THE PHASE STAMP. state/harness-sync-phase is one line,
#   <phase> <sha40> <iso-ts>
# where <phase> is `copied` (the code copy is live), `step=<name>` (that
# post-copy step is running) or `done`. Written tmp+mv. fleet-propagate reads it
# after an outer rc 124 (fp_hub_post_copy).
#
# THE PENDING MARKERS. state/harness-sync-pending/<step> is one line,
#   <sha40|-> <epoch> <queued|rc=<n>> <alerted 0|1>
# for a deploy step (worker-phase, model-prices, cost-caps, console-pages).
# Written `queued` at copy time for each step the run will launch, cleared when
# the step ends rc 0 for the same sha, rewritten `rc=<n>` when it fails or is
# cut. One ALERTS line per step and sha. The next sync logs
# `re-running pending step <name> from <sha7> (<status>)` and runs it again.
#
# THE STEP LINE. Every step writes one update-runners.log line:
#   <STAMP> harness sync: step=<name> rc=<n|busy> secs=<n>
#
# Root: ${HARNESS:-${H:-}} only. With no root every function returns without
# a write (D43): a lib never builds a path from an empty root.
#
#   HARNESS_SYNC_POST_STEP_TIMEOUT_S  seconds one foreground post-copy step may
#       run. Env first (fleet-propagate's lane_env_apply exports the settings
#       row lane.fleet-propagate.harness_sync_post_step_timeout_s), then that
#       row read once per run, then 240. Empty, 0 or not a number: one log line
#       and 240.

HS_POST_STEP_TIMEOUT_S_DEFAULT=240
HS_POST_STEP_KEY=lane.fleet-propagate.harness_sync_post_step_timeout_s

hs_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# hs_log <text> — one update-runners.log line.
hs_log() {
  local r; r=$(hs_root); [ -n "$r" ] || return 0
  mkdir -p "$r/logs" 2>/dev/null
  printf '%s harness sync: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" >> "$r/logs/update-runners.log" 2>/dev/null
  return 0
}

# hs_step_line <name> <rc|busy> <secs>
hs_step_line() { hs_log "step=$1 rc=$2 secs=$3"; }

# hs_phase <copied|step=<name>|done> — needs HS_SHA (the sha the copy put live).
hs_phase() {
  local r f; r=$(hs_root)
  [ -n "$r" ] && [ -n "${HS_SHA:-}" ] || return 0
  f="$r/state/harness-sync-phase"
  mkdir -p "$r/state" 2>/dev/null
  printf '%s %s %s\n' "$1" "$HS_SHA" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$f.tmp.$$" 2>/dev/null \
    && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  return 0
}

# hs_post_step_timeout — sets HS_POST_TO. Memoised for the run: the settings
# row is read at most once.
hs_post_step_timeout() {
  [ -n "${HS_POST_TO:-}" ] && return 0
  local v="${HARNESS_SYNC_POST_STEP_TIMEOUT_S:-}" src="env HARNESS_SYNC_POST_STEP_TIMEOUT_S" r
  r=$(hs_root)
  if [ -z "$v" ] && [ -n "$r" ] && [ -x "$r/bin/jobs-client.sh" ]; then
    v=$(HARNESS="$r" timeout 10 "$r/bin/jobs-client.sh" setting-get "$HS_POST_STEP_KEY" 2>/dev/null </dev/null | tr -d '[:space:]')
    src="settings row $HS_POST_STEP_KEY"
  fi
  case "$v" in
    '') v=$HS_POST_STEP_TIMEOUT_S_DEFAULT ;;
    0|*[!0-9]*)
      hs_log "$src=${v:0:40} is not a number of seconds above 0 — post-copy steps use ${HS_POST_STEP_TIMEOUT_S_DEFAULT}s"
      v=$HS_POST_STEP_TIMEOUT_S_DEFAULT ;;
  esac
  HS_POST_TO=$v
  return 0
}

# hs_tree <pid> — the pid and every descendant, parents first. The whole list
# is read before anything is killed: a killed parent's children move to init
# and `pgrep -P` can no longer find them.
hs_tree() {
  local c
  printf '%s\n' "$1"
  command -v pgrep >/dev/null 2>&1 || return 0
  for c in $(pgrep -P "$1" 2>/dev/null); do hs_tree "$c"; done
}

# hs_kill_tree <pid> <signal> — signal the pid and all its descendants. This
# reaches an inner `timeout` too, which sits in its own process group. Without
# pgrep it is a plain kill of the pid.
hs_kill_tree() {
  local p
  for p in $(hs_tree "$1"); do kill -"$2" "$p" 2>/dev/null; done
  return 0
}

# hs_pending_file <name>
hs_pending_file() { local r; r=$(hs_root); [ -n "$r" ] || return 1; printf '%s/state/harness-sync-pending/%s' "$r" "$1"; }

# hs_pending_write <name> <sha> <status> <alerted>
hs_pending_write() {
  local f; f=$(hs_pending_file "$1") || return 0
  mkdir -p "${f%/*}" 2>/dev/null
  printf '%s %s %s %s\n' "${2:--}" "$(date +%s)" "$3" "$4" > "${f%/*}/.$1.tmp.$$" 2>/dev/null \
    && mv -f "${f%/*}/.$1.tmp.$$" "$f" 2>/dev/null
  return 0
}

# hs_pending_queue <name> — at copy time, for each deploy step this run will
# launch. A marker left by an earlier run is logged as a re-run. Its alerted
# flag survives only for the same sha: one ALERT per step and sha.
hs_pending_queue() {
  local f msha mst mal alerted=0
  f=$(hs_pending_file "$1") || return 0
  if [ -f "$f" ] && read -r msha _ mst mal _ < "$f" 2>/dev/null; then
    hs_log "re-running pending step $1 from ${msha:0:7} (${mst:-?})"
    [ "$msha" = "${HS_SHA:--}" ] && [ "$mal" = 1 ] && alerted=1
  fi
  hs_pending_write "$1" "${HS_SHA:-}" queued "$alerted"
}

# hs_pending_note <name> <rc> <sha> — the end of a deploy step. rc 0 clears the
# marker, but only a marker of the same sha (or none): an older run that ends
# late never clears a newer run's marker. Any other rc rewrites the marker with
# `rc=<n>` and writes ONE ALERTS line per step and sha.
hs_pending_note() {
  local name="$1" rc="$2" sha="${3:-}" f msha mst mal alerted=0 r host
  f=$(hs_pending_file "$name") || return 0
  msha=""; mal=0
  [ -f "$f" ] && read -r msha _ mst mal _ < "$f" 2>/dev/null
  if [ "$rc" = 0 ]; then
    { [ ! -f "$f" ] || [ "$msha" = "${sha:--}" ]; } && rm -f "$f"
    return 0
  fi
  [ "$msha" = "${sha:--}" ] && [ "$mal" = 1 ] && alerted=1
  if [ "$alerted" = 0 ]; then
    r=$(hs_root); host=$(hostname 2>/dev/null || echo box)
    if [ -x "$r/bin/alert-line.sh" ]; then
      HARNESS="$r" "$r/bin/alert-line.sh" --id "harness-sync-step-$name-$host" \
        "[$host] harness sync step $name ended rc=$rc at ${sha:0:7} (124 = cut by its timeout) — it stays pending in state/harness-sync-pending/$name and re-runs on the next harness-sync (next fleet-path merge or 05:17Z update-runners); see update-runners.log" \
        </dev/null >/dev/null 2>&1
    fi
    alerted=1
  fi
  hs_pending_write "$name" "$sha" "rc=$rc" "$alerted"
}

# hs_pending_list — the names of the pending deploy steps, one per line.
hs_pending_list() {
  local r f; r=$(hs_root); [ -n "$r" ] || return 0
  for f in "$r/state/harness-sync-pending"/*; do
    [ -f "$f" ] && printf '%s\n' "${f##*/}"
  done
  return 0
}

# hs_step <name> <plain|deploy> <cmd...> — run one foreground post-copy step
# under its own timeout. The command runs in a forked subshell, so it sees
# every function and variable of the caller. fds 6-9 are closed in it: they are
# the caller's locks (fleet-propagate's lane lock on 9, its bake lock on 6,
# harness-sync's own 7 and 8), and a grandchild that outlives a kill must not
# hold one. Always returns 0: a step never changes harness-sync's exit code.
hs_step() {
  local name="$1" kind="$2" r to t0 pid wd rc fired
  shift 2
  r=$(hs_root)
  hs_phase "step=$name"
  hs_post_step_timeout; to=$HS_POST_TO
  fired=$(mktemp "${TMPDIR:-/tmp}/hs-step.XXXXXX" 2>/dev/null) && rm -f "$fired"
  t0=$(date +%s)
  ( "$@" ) 9>&- 8>&- 7>&- 6>&- &
  pid=$!
  # The watchdog waits with the read builtin on a pipe it holds open, not with
  # an external `sleep`: a PATH whose sleep is a stub (several suites) would
  # otherwise fire it at once.
  ( read -r -t "$to" _ <> <(:); [ -n "$fired" ] && : > "$fired"; hs_kill_tree "$pid" TERM
    read -r -t 10 _ <> <(:); hs_kill_tree "$pid" KILL ) </dev/null >/dev/null 2>&1 9>&- 8>&- 7>&- 6>&- &
  wd=$!
  wait "$pid"; rc=$?
  hs_kill_tree "$wd" TERM
  wait "$wd" 2>/dev/null
  if [ -n "$fired" ] && [ -e "$fired" ]; then rc=124; rm -f "$fired"; fi
  hs_step_line "$name" "$rc" "$(( $(date +%s) - t0 ))"
  [ "$kind" = deploy ] && hs_pending_note "$name" "$rc" "${HS_SHA:-}"
  return 0
}
