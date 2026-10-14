#!/bin/bash
# bin/lib/session-profile.sh — the HEADLESS SESSION PROFILE a claude lane runs
# under (P1, 2026-09-24). Sourced by bin/agent-call.sh; the claude arm calls
# session_profile_build once per attempt and splices what it returns into the
# argv, the env and the --settings composition it already has.
#
# ── WHY ──────────────────────────────────────────────────────────────────────
# The fleet's notional spend was ~$47.5K a week, almost all Opus 5.5, and in
# sampled hub cost rows the prompt-cache WRITE was 60-82% of each call's cost:
# 70-115K tokens written per fresh session. Three things drive that, and each
# is a documented Claude Code behaviour (code.claude.com/docs/en/prompt-caching):
#   1. TTL. On a Claude subscription within plan usage the MAIN conversation of
#      a `-p` run requests the ONE-HOUR TTL, and a 1h write bills at 2x the
#      prompt rate against 1.25x for 5m. A one-shot triage/review session never
#      idles past five minutes, so it pays the higher rate for nothing.
#      CLAUDE_CODE_PROMPT_CACHE_TTL=5m|1h (CLI >= 2.1.242) picks it per call.
#   2. What loads. A headless call inherits the box's user plugins and MCP
#      servers (rules/settings.json enables the Vercel plugin on every box; the
#      project-9 alerts show it loading in headless triage). --strict-mcp-config
#      with a lane-specific --mcp-config, and an enabledPlugins:false override
#      in the --settings file, keep them out of a session that never uses them.
#   3. Prefix sharing. Each session's system prompt names its cwd, platform and
#      git status, so two builds in two worktrees never read each other's
#      cache. --exclude-dynamic-system-prompt-sections moves those into the
#      first user message, so every session of a lane can share one prefix.
# Measured on this repo with claude 2.1.282 (Haiku 4.5, "say ok"): the
# default run wrote 39,942 tokens at 1h ($0.082); the profiled run wrote 28,855
# at 5m and read 17,713 ($0.038); a second profiled run inside five minutes
# wrote NOTHING and read 46,568 ($0.005).
#
# ── WHAT IT NEVER DOES ───────────────────────────────────────────────────────
#   - It never drops the USER setting source unless a row says so. `user` is
#     where /root/.claude/CLAUDE.md (the fleet rules), the rtk hook and the
#     codegraph hook live; --setting-sources project,local would take the fleet
#     rulebook out of every build. SESSION_PROFILE_SETTING_SOURCES is there for
#     a measured experiment, default EMPTY.
#   - It never switches model or effort inside a session. The model is the one
#     --model agent-call.sh already passes; --effort is passed at most once, at
#     session start, and only when the lane's row names a level.
#   - It never replaces the iron-law guard. The plugin override is a settings
#     FILE handed back to agent-call.sh's own merge, which appends the guard
#     LAST so it still wins every key collision.
#
# ── ROLLOUT ──────────────────────────────────────────────────────────────────
# DARK BY DEFAULT: SESSION_PROFILE_STAGES is empty, so no stage is profiled and
# agent-call.sh's argv and env are byte-identical to before (the parity case of
# tests/agent-call-session-profile-test.sh). Canary: SESSION_PROFILE_STAGES=triage
# in ONE box's env/global.env, then the lib.session-profile.session_profile_stages
# settings row fleet-wide. docs/SESSION-PROFILE.md has the plan.
#
# Knobs (catalog/lanes.d/_lib.session-profile.json; settings rows
# lib.session-profile.<env lowercased>, applied by agent-call.sh through
# lib_env_apply session-profile; each read below keeps its code default):
#   SESSION_PROFILE_STAGES           "" (off) | "all" | space/comma list of stages
#   SESSION_PROFILE_TTL_MAP          stage=5m|1h pairs, `default=` for the rest
#   SESSION_PROFILE_MCP_MAP          stage=<server,server> pairs: the user MCP
#                                    servers a stage keeps; empty = none
#   SESSION_PROFILE_EFFORT_MAP       stage=<level> pairs; empty = no --effort
#   SESSION_PROFILE_PLUGINS_OFF      1 = every enabled plugin forced off
#   SESSION_PROFILE_EXCLUDE_DYNAMIC  1 = --exclude-dynamic-system-prompt-sections
#   SESSION_PROFILE_SETTING_SOURCES  "" = not passed (see above)

# The code defaults. Each is ALSO the registry default, and the registry is what
# a settings row overrides; these literals only serve a box with no lane-gate.
SESSION_PROFILE_TTL_MAP_DEFAULT="triage=5m preplan=5m preplan-files=5m review=5m plan=5m eval=5m execute=1h fix=1h chat=1h default=5m"
SESSION_PROFILE_MCP_MAP_DEFAULT="plan=codegraph execute=codegraph fix=codegraph default="

# session_profile_active <stage> — rc 0 when the profile applies to this stage.
session_profile_active() {
  local st="${1:-}" list="${SESSION_PROFILE_STAGES:-}"
  [ -n "$st" ] && [ -n "$list" ] || return 1
  list=" $(printf '%s' "$list" | tr ',' ' ') "
  case "$list" in *" all "*|*" $st "*) return 0 ;; esac
  return 1
}

# session_profile_map_get <map> <stage> — the value for <stage>, else the
# `default=` value, else nothing. Pairs are space- or comma-free `k=v` words;
# a value may itself carry commas (the MCP map's server lists).
session_profile_map_get() {
  local map="${1:-}" st="${2:-}" w k v def="" hit="" words=()
  # read -a, not `for w in $map`: a settings row is operator text, and an
  # unquoted split would glob a `*` against the caller's cwd.
  read -r -a words <<<"$map"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in *=*) ;; *) continue ;; esac
    k="${w%%=*}"; v="${w#*=}"
    [ "$k" = "$st" ] && { hit=1; printf '%s' "$v"; return 0; }
    [ "$k" = default ] && def="$v"
  done
  [ -n "$hit" ] || printf '%s' "$def"
}

# _sp_log <line> — the profile's own log, one line per decision worth knowing.
# The root is HARNESS, then the caller's H; with neither there is no log.
_sp_log() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s [session-profile] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" >> "$h/logs/session-profile.log" 2>/dev/null
}

# _sp_atomic <path> <json> — write-then-rename, and only when the bytes change,
# so parallel builds on one box never hand claude a half-written file.
_sp_atomic() {
  local p="$1" body="$2"
  [ -f "$p" ] && [ "$(cat "$p" 2>/dev/null)" = "$body" ] && return 0
  # 0600: an MCP server entry can carry a header or env token.
  ( umask 077; printf '%s\n' "$body" > "$p.tmp.$$" ) 2>/dev/null && mv -f "$p.tmp.$$" "$p" 2>/dev/null
}

# session_profile_build <stage> <cwd> [config-dir]
#
# [config-dir] is the CLAUDE_CONFIG_DIR the CHILD will run under. On an
# account-routed call that is the routed account's dir, which exists only in
# ACCT_EXPORTS (eval'd inside the claude subshell, never in this shell), so the
# caller resolves it there and passes it in. Empty = the default ~/.claude.
#
# Sets, for the caller (dynamic scope, like cost_row_source does):
#   SP_ACTIVE    1 when the profile applied, else empty
#   SP_ARGS      argv words to append to the claude invocation
#   SP_ENV       NAME=value words for the `env` in front of claude
#   SP_SETTINGS  a settings file to merge (the plugin override), or empty
#   SP_TTL       the TTL this call REQUESTED (5m|1h), or empty
# Always rc 0: a profile that cannot be built runs the call unprofiled, never
# refuses it.
session_profile_build() {
  local st="${1:-}" cwd="${2:-$PWD}" cdir="${3:-}" h="${HARNESS:-${H:-}}"
  SP_ACTIVE=""; SP_ARGS=(); SP_ENV=(); SP_SETTINGS=""; SP_TTL=""
  session_profile_active "$st" || return 0
  command -v jq >/dev/null 2>&1 || { _sp_log "$st: jq missing — running unprofiled"; return 0; }
  # No root = no state dir: the MCP and plugin files below are skipped, which
  # is what an unwritable state dir already gives (BH-2613.4).
  [ -n "$h" ] && mkdir -p "$h/state" 2>/dev/null
  SP_ACTIVE=1

  # 1. TTL — only the two values the CLI honours; anything else is ignored by
  #    the CLI anyway, so it is logged and not passed rather than passed inert.
  local ttl
  ttl=$(session_profile_map_get "${SESSION_PROFILE_TTL_MAP:-$SESSION_PROFILE_TTL_MAP_DEFAULT}" "$st")
  case "$ttl" in
    5m|1h) SP_TTL="$ttl"; SP_ENV+=("CLAUDE_CODE_PROMPT_CACHE_TTL=$ttl") ;;
    '')    ;;
    *)     _sp_log "$st: TTL '$ttl' is not 5m or 1h — not set, the CLI default applies" ;;
  esac

  # 2. MCP — strict, with only the servers this stage keeps, copied from the
  #    user config the session would otherwise have loaded them from. A named
  #    server that is not there is left out and said once.
  local keep cfgs mcp missing="" name names=()
  keep=$(session_profile_map_get "${SESSION_PROFILE_MCP_MAP:-$SESSION_PROFILE_MCP_MAP_DEFAULT}" "$st")
  cfgs=()
  # Under a config dir the CLI reads <dir>/.claude.json and NOT ~/.claude.json,
  # so only that file is the source; a server from the default account would
  # be one the routed session never had.
  if [ -n "$cdir" ]; then
    [ -r "$cdir/.claude.json" ] && cfgs+=("$cdir/.claude.json")
  else
    [ -r "${HOME:-/root}/.claude.json" ] && cfgs+=("${HOME:-/root}/.claude.json")
  fi
  mcp=$(jq -cn --arg keep "$keep" '
      ($keep | split(",") | map(select(length > 0))) as $k
      | [inputs | (.mcpServers // {})] | reverse | add // {}
      | with_entries(select(.key as $n | $k | index($n)))
      | {mcpServers: .}' ${cfgs[@]+"${cfgs[@]}"} </dev/null 2>/dev/null) || mcp='{"mcpServers":{}}'
  [ -n "$mcp" ] || mcp='{"mcpServers":{}}'
  IFS=',' read -r -a names <<<"$keep"
  for name in ${names[@]+"${names[@]}"}; do
    [ -n "$name" ] || continue
    printf '%s' "$mcp" | jq -e --arg n "$name" '.mcpServers | has($n)' >/dev/null 2>&1 || missing="$missing $name"
  done
  [ -n "$missing" ] && _sp_log "$st: MCP server(s)$missing named by SESSION_PROFILE_MCP_MAP are not configured on this box — left out"
  local mf=""
  [ -n "$h" ] && mf="$h/state/session-profile-mcp-$(printf '%s' "$mcp" | cksum | cut -d' ' -f1).json"
  if [ -n "$mf" ] && _sp_atomic "$mf" "$mcp"; then
    SP_ARGS+=(--strict-mcp-config --mcp-config "$mf")
  else
    _sp_log "$st: could not write $mf — MCP left as the box configures it"
  fi

  # 3. Plugins — every plugin the session's setting sources enable, forced off
  #    by a flag-scope setting (which outranks user and project settings).
  if [ "${SESSION_PROFILE_PLUGINS_OFF:-1}" = 1 ]; then
    local sfs=() f po
    for f in "$cdir/settings.json" "${HOME:-/root}/.claude/settings.json" \
             "$cwd/.claude/settings.json" "$cwd/.claude/settings.local.json"; do
      [ "$f" != /settings.json ] && [ -r "$f" ] && sfs+=("$f")
    done
    po=$(jq -cn '[inputs | (.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key]
                 | unique | map({key: ., value: false}) | from_entries' ${sfs[@]+"${sfs[@]}"} </dev/null 2>/dev/null)
    if [ -n "$h" ] && [ -n "$po" ] && [ "$po" != "{}" ]; then
      local pf="$h/state/session-profile-plugins-$(printf '%s' "$po" | cksum | cut -d' ' -f1).json"
      _sp_atomic "$pf" "{\"enabledPlugins\":$po}" && SP_SETTINGS="$pf"
    fi
  fi

  # 4. One prefix for the fleet: per-machine sections out of the system prompt.
  [ "${SESSION_PROFILE_EXCLUDE_DYNAMIC:-1}" = 1 ] && SP_ARGS+=(--exclude-dynamic-system-prompt-sections)

  # 5. Effort, once, at session start — or not at all.
  local eff
  eff=$(session_profile_map_get "${SESSION_PROFILE_EFFORT_MAP:-}" "$st")
  case "$eff" in
    low|medium|high|xhigh|max) SP_ARGS+=(--effort "$eff") ;;
    '') ;;
    *) _sp_log "$st: effort '$eff' is not a CLI level — not passed" ;;
  esac

  # 6. Setting sources — only when a row asks (see the header: `user` carries
  #    the fleet rules).
  local ss="${SESSION_PROFILE_SETTING_SOURCES:-}"
  if [ -n "$ss" ]; then
    if grep -qE '^(user|project|local)(,(user|project|local))*$' <<<"$ss"; then
      SP_ARGS+=(--setting-sources "$ss")
    else
      _sp_log "$st: SESSION_PROFILE_SETTING_SOURCES '$ss' is not a user/project/local list — not passed"
    fi
  fi
  return 0
}

# session_profile_ttl_seen <envelope.json> — the TTL the session's cache writes
# ACTUALLY used, read from the CLI envelope's usage.cache_creation split:
# 5m, 1h, mixed, or nothing when the envelope says nothing. Observed, never
# inferred from what was requested.
session_profile_ttl_seen() {
  [ -r "${1:-}" ] || return 0
  jq -r '(.usage.cache_creation // null) as $c
         | if $c == null then ""
           else (($c.ephemeral_5m_input_tokens // 0) | tonumber) as $a
              | (($c.ephemeral_1h_input_tokens // 0) | tonumber) as $b
              | if $a > 0 and $b > 0 then "mixed"
                elif $b > 0 then "1h" elif $a > 0 then "5m" else "" end
           end' "$1" 2>/dev/null
}
