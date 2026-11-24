#!/bin/bash
# shellcheck shell=bash
# bin/lib/claude-cli-pin.sh — the fleet's pinned Claude Code CLI version and the
# canary box that tries each new release first. Sourced, never run.
#
# Readers: bin/cli-update.sh (every box, 05:17), bin/fly-image-build.sh (the
# pool image bake), bin/bootstrap-machine.sh, bin/claude-cli-smoke.sh (the
# canary smoke) and bin/claude-cli-pin.sh (hub: watch, promote, drift).
# The caller loads the jobs client first (setting_get, setting_set, _jobs_req,
# _jobs_req_file). Without it every knob read is "unknown" (rc 1 inside).
#
#   ccp_enabled              rc 0 pin on, rc 1 pin off, rc 2 pin state unknown
#   ccp_pinned_version       the pinned version (row, else the fallback + WARN)
#   ccp_canary_box           the canary box name (row, else the fallback)
#   ccp_canary_version       the canary version, or empty (no row / unparseable)
#   ccp_knob_int <key> <fb>  a positive integer knob, else the fallback
#   ccp_box_id <name>        the name with one leading $HARNESS_BOX_PREFIX removed
#   ccp_is_canary <box> [canary-box]   rc 0 when <box> is the canary box
#   ccp_target_version <box> the version <box> must run under the pin
#   ccp_target_for <box> <pinned> <canary-version> <canary-box>  (no reads)
#   ccp_smoke_post <file>    POST /api/claude-cli/smoke with {rows:[...]}
#   ccp_smoke_list <box> <version> <limit>  GET /api/claude-cli/smoke rows
#
# KNOB OUTAGE (A9). "Unknown" is not "off": a worker outage on the day the pin
# is on must not send a box to `latest` (the 2.1.317 path). But a box that has
# never seen the pin on must keep today's behaviour through an outage too. So
# every successful read of claude_cli.pin.enabled is written to the box-local
# cache state/claude-cli-pin/pin-enabled, and an outage answers from it:
# cached 1 -> rc 2 (unknown, the caller holds); cached 0 or no cache -> rc 1.

_CCP_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/cli-version.sh
. "$_CCP_LIB_DIR/cli-version.sh"
# shellcheck source=bin/lib/hub-box.sh
[ -r "$_CCP_LIB_DIR/hub-box.sh" ] && . "$_CCP_LIB_DIR/hub-box.sh"
# HARNESS_BOX_PREFIX comes from bin/lib/deployment.sh (BH-4080), never a literal.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$_CCP_LIB_DIR/deployment.sh}" 2>/dev/null || : "${HARNESS_BOX_PREFIX:=box-}"

# Code fallbacks. Each is used only when its settings row is absent or not
# usable, and each equals the seed in
# worker/jobs/schema.d/202611241159-bh-9911-claude-cli-smoke.sql.
CCP_PINNED_FALLBACK=2.1.330              # fallback of settings row claude_cli.pinned_version
CCP_CANARY_BOX_FALLBACK="${HARNESS_BOX_PREFIX}small"  # fallback of settings row claude_cli.canary_box
CCP_SOAK_H_FALLBACK=24                   # fallback of settings row claude_cli.canary_soak_h
CCP_SMOKE_INTERVAL_H_FALLBACK=6          # fallback of settings row claude_cli.smoke_interval_h
CCP_LATE_STDIN_S_FALLBACK=5              # fallback of settings row claude_cli.smoke_late_stdin_s
CCP_STEP_TIMEOUT_S_FALLBACK=120          # fallback of settings row claude_cli.smoke_step_timeout_s
CCP_FAIL_CLASS_WINDOW_H_FALLBACK=168     # fallback of settings row claude_cli.fail_class_window_h
CCP_WATCH_TIMEOUT_S_FALLBACK=60          # fallback of settings row claude_cli.watch_timeout_s
CCP_DRIFT_MAX_AGE_H_FALLBACK=48          # fallback of settings row claude_cli.drift_max_age_h
CCP_SMOKE_LIST_LIMIT_FALLBACK=200        # fallback of settings row claude_cli.smoke_list_limit
# These five equal the seed in schema.d/202611241200-bh-9911-claude-cli-smoke-caps.sql.
CCP_STEP_GRACE_S_FALLBACK=30             # fallback of settings row claude_cli.smoke_step_grace_s
CCP_STEP_KILL_AFTER_S_FALLBACK=10        # fallback of settings row claude_cli.smoke_step_kill_after_s
CCP_WATCH_KILL_AFTER_S_FALLBACK=10       # fallback of settings row claude_cli.watch_kill_after_s
CCP_SMOKE_DETAIL_MAX_FALLBACK=500        # fallback of settings row claude_cli.smoke_detail_max (the worker's DETAIL_MAX reads the same row)
CCP_SMOKE_EXCERPT_MAX_FALLBACK=200       # fallback of settings row claude_cli.smoke_excerpt_max

# The five smoke steps that call a model. A red one blocks promotion and
# raises the RED alert. fail_classes is the sixth step and spends nothing.
CCP_MODEL_STEPS="stdin late_stdin tool_call haiku lane_tick"

_ccp_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _ccp_get <key> -> setting_get's contract (rc 0 value, 2 no row, 1 outage);
# rc 1 when no jobs client is loaded.
_ccp_get() {
  declare -F setting_get >/dev/null 2>&1 || return 1
  setting_get "$1" 2>/dev/null
}

_ccp_cache_write() { # _ccp_cache_write <0|1>
  local r d
  r=$(_ccp_root); [ -n "$r" ] || return 0
  d="$r/state/claude-cli-pin"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$d/pin-enabled.tmp" 2>/dev/null && mv -f "$d/pin-enabled.tmp" "$d/pin-enabled" 2>/dev/null
  return 0
}

ccp_enabled() {
  local v rc r c
  v=$(_ccp_get claude_cli.pin.enabled); rc=$?
  case "$rc" in
    0) if [ "$v" = 1 ]; then _ccp_cache_write 1; return 0; fi
       [ "$v" = 0 ] || echo "WARN: claude_cli.pin.enabled row \"$v\" is not 0 or 1; the pin is off" >&2
       _ccp_cache_write 0; return 1 ;;
    2) _ccp_cache_write 0; return 1 ;;
  esac
  r=$(_ccp_root)
  c=$(cat "$r/state/claude-cli-pin/pin-enabled" 2>/dev/null)
  [ -n "$r" ] && [ "$c" = 1 ] && return 2
  return 1
}

# _ccp_strict <text> -> the x.y.z version when the text parses to one.
_ccp_strict() {
  local v
  v=$(cli_version_parse "${1:-}")
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s' "$v"
}

ccp_pinned_version() {
  local raw v
  raw=$(_ccp_get claude_cli.pinned_version) || raw=""
  if [ -n "$raw" ] && v=$(_ccp_strict "$raw"); then printf '%s\n' "$v"; return 0; fi
  if [ -n "$raw" ]; then
    echo "WARN: claude_cli.pinned_version row \"$raw\" is not a version; using the fallback $CCP_PINNED_FALLBACK" >&2
  else
    echo "WARN: claude_cli.pinned_version not readable (no row or no worker); using the fallback $CCP_PINNED_FALLBACK" >&2
  fi
  printf '%s\n' "$CCP_PINNED_FALLBACK"
}

ccp_canary_box() {
  local v
  v=$(_ccp_get claude_cli.canary_box) || v=""
  v=$(printf '%s' "$v" | tr -dc 'A-Za-z0-9._-')
  printf '%s\n' "${v:-$CCP_CANARY_BOX_FALLBACK}"
}

ccp_canary_version() {
  local raw v
  raw=$(_ccp_get claude_cli.canary_version) || raw=""
  [ -n "$raw" ] || return 0
  v=$(_ccp_strict "$raw") || { echo "WARN: claude_cli.canary_version row \"$raw\" is not a version; no canary" >&2; return 0; }
  printf '%s\n' "$v"
}

ccp_knob_int() { # ccp_knob_int <key> <fallback>
  local v
  v=$(_ccp_get "$1") || v=""
  if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then printf '%s\n' "$v"; return 0; fi
  [ -n "$v" ] && echo "WARN: $1 row \"$v\" is not a positive integer; using $2" >&2
  printf '%s\n' "$2"
}

ccp_box_id() { local n="${1:-}"; printf '%s' "${n#"$HARNESS_BOX_PREFIX"}"; }

# ccp_is_canary <box> [canary-box]. The two names match after one leading
# $HARNESS_BOX_PREFIX (box- by default) is removed from each (box
# ids are short: small, hub; the row may hold the host name
# box-small). The hub is never the
# canary: it runs the orchestrator, where 2.1.317 broke.
ccp_is_canary() {
  local box="${1:-}" cb="${2:-}" b c
  [ -n "$cb" ] || cb=$(ccp_canary_box)
  b=$(ccp_box_id "$box"); c=$(ccp_box_id "$cb")
  [ -n "$b" ] && [ -n "$c" ] || return 1
  [ "$b" = hub ] && return 1
  if declare -F is_hub_box >/dev/null 2>&1; then
    is_hub_box "$box" && return 1
    is_hub_box "$b" && return 1
  fi
  [ "$b" = "$c" ]
}

ccp_target_for() { # ccp_target_for <box> <pinned> <canary-version> <canary-box>
  if [ -n "${3:-}" ] && ccp_is_canary "$1" "$4"; then printf '%s\n' "$3"; else printf '%s\n' "$2"; fi
}

ccp_target_version() {
  local p c cb
  p=$(ccp_pinned_version 2>/dev/null)
  c=$(ccp_canary_version 2>/dev/null)
  cb=$(ccp_canary_box)
  ccp_target_for "${1:-}" "$p" "$c" "$cb"
}

# ccp_smoke_post <file> -> rc 0 when the worker took the rows.
ccp_smoke_post() {
  declare -F _jobs_req_file >/dev/null 2>&1 || return 1
  _jobs_req_file POST /api/claude-cli/smoke "$1" >/dev/null
}

# ccp_smoke_list <box> <version> <limit> -> the rows JSON array, newest first.
# rc 1 on any failed read: a caller never reads "no rows" from an outage.
ccp_smoke_list() {
  local resp rows
  declare -F _jobs_req >/dev/null 2>&1 || return 1
  [[ ${1:-} =~ ^[A-Za-z0-9._-]+$ ]] && [[ ${2:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ${3:-} =~ ^[0-9]+$ ]] || return 1
  resp=$(_jobs_req GET "/api/claude-cli/smoke?box=$1&version=$2&limit=$3") || return 1
  rows=$(printf '%s' "$resp" | jq -c '.rows | select(type == "array")' 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows"
}
