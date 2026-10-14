#!/bin/bash
# bin/lib/egress.sh — the egress allowlist per build stage (BH-4492, wave 5 of
# BH-4475). Sourced by bin/agent-call.sh; no side effect at source time beyond
# defining functions and capturing this file's own directory.
#
# A stage call whose $OUT lands in a build dir is run inside its own network
# namespace, and the only way out of it is bin/egress-proxy.py, which allows
# the hosts of one settings row and refuses (403, logged) everything else:
#   egress.stage.<stage>.hosts   space/comma list of host, *.suffix, host:port
# The seeds (worker/jobs/schema.sql) give execute the model APIs plus the npm
# and PyPI registries, and review the model APIs only. A stage with no row runs
# as it always has.
#
# Absent, unarmed, unreadable, unenforceable are four different answers:
#   not a build dir, no settings cache, no row, or the value `off`
#     -> not-armed: the call runs exactly as before (one state line in a build
#        dir so the evidence row can say so, nothing outside one);
#   a cache that is not a JSON object with .values, or a row with no valid
#     entries / one bad entry -> FAILS CLOSED to EG_FALLBACK_HOSTS (the model
#     hosts only), source fallback:<reason>; the stage still runs;
#   no unshare, unshare refused, no python3, no proxy script, or the proxy
#     socket not up within 5 s -> not-enforced: the call runs UNFENCED, the
#     state line says so, and ONE ALERTS line goes out per box/stage/day. The
#     fence never refuses the call (the FENCE_ENV doctrine in agent-call.sh).
#   everything in place -> enforced.
#
# Records, both in the build dir:
#   egress.log         the proxy's DENY / DENY-DIRECT / END lines, tagged
#                      stage= and id=<this call>
#   egress-state.txt   one line per call: state, source, host count, counts
# bin/evidence-summary.sh renders them as the `egress allowlist` row.
#
# Root: ${HARNESS:-${H:-}} and nothing else.
#
#   eg_hosts <stage>               rc 0 + EG_HOSTS + EG_SOURCE (row|fallback:*)
#                                  | rc 1 not armed + EG_REASON. Call it in this
#                                  shell, not in $(...).
#   eg_mechanism                   rc 0 | rc 1 + EG_REASON (memoised)
#   eg_begin <stage> <out> <runner>  sets the EG_WRAP array (empty = unfenced)
#   eg_end [cancelled]             stops the proxy, writes the enforced state
#                                  line (none when cancelled); always rc 0

_EG_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
# THE DOCUMENTED FALLBACK, not the configuration: what a stage may reach when
# its row (or the whole settings cache) cannot be read. The model hosts of the
# runners build stages use, and no package registry — an unreadable row must
# never read as a wider list. Gemini's host is in the seeded rows but not here:
# no build stage runs on gemini, and that name is an inference endpoint
# tests/llm-call-ratchet-test.sh keeps out of code outside agent-call. The
# rows themselves are the knob.
EG_FALLBACK_HOSTS="api.anthropic.com platform.claude.com api.x.ai api.openai.com chatgpt.com auth.openai.com openrouter.ai api.fireworks.ai"
EG_ENTRY_RE='^(\*\.)?[a-z0-9]([a-z0-9.-]{0,251})(:[0-9]{1,5})?$'
EG_HOSTS=""; EG_SOURCE=""; EG_REASON=""; EG_MECH=""; EG_MECH_REASON=""
EG_WRAP=()

_eg_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_eg_stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

eg_hosts() {
  local stage="${1:-}" key f v e list="" n=0
  EG_HOSTS=""; EG_SOURCE=""; EG_REASON=""
  key="egress.stage.$stage.hosts"
  if ! command -v _lg_settings_file >/dev/null 2>&1 && [ -r "$_EG_LIB/lane-gate.sh" ]; then
    # shellcheck source=bin/lib/lane-gate.sh
    . "$_EG_LIB/lane-gate.sh" 2>/dev/null || true
  fi
  command -v _lg_settings_refresh >/dev/null 2>&1 && { _lg_settings_refresh >/dev/null 2>&1 || true; }
  if command -v _lg_settings_file >/dev/null 2>&1; then f=$(_lg_settings_file)
  elif [ -n "$(_eg_root)" ]; then f="$(_eg_root)/state/settings-cache.json"
  else f=""; fi
  [ -n "$f" ] && [ -e "$f" ] || { EG_REASON=no-settings-cache; return 1; }
  if ! jq -e '.values|type=="object"' "$f" >/dev/null 2>&1; then
    EG_HOSTS="$EG_FALLBACK_HOSTS"; EG_SOURCE="fallback:settings-unreadable"; return 0
  fi
  jq -e --arg k "$key" '.values|has($k)' "$f" >/dev/null 2>&1 || { EG_REASON=no-row; return 1; }
  if ! v=$(jq -r --arg k "$key" '.values[$k]|if type=="string" then . else tojson end' "$f" 2>/dev/null); then
    EG_HOSTS="$EG_FALLBACK_HOSTS"; EG_SOURCE="fallback:settings-unreadable"; return 0
  fi
  v=$(printf '%s' "$v" | tr 'A-Z,\t\r\n' 'a-z    ')
  if [ "$(printf '%s' "$v" | tr -d ' ')" = off ]; then EG_REASON=off; return 1; fi
  # Word-split, never glob: a `*.suffix` entry must not expand against the CWD.
  local -; set -f
  for e in $v; do
    e="${e%.}"
    case "$e" in *.:*) e="${e%%.:*}:${e##*:}" ;; esac
    if ! grep -Eq "$EG_ENTRY_RE" <<<"$e"; then n=0; list=""; break; fi
    list="${list:+$list }$e"; n=$((n + 1))
  done
  # One bad entry voids the row: a silently shorter list would read as configured.
  if [ "$n" -eq 0 ]; then
    EG_HOSTS="$EG_FALLBACK_HOSTS"; EG_SOURCE="fallback:row-unreadable:$key"; return 0
  fi
  EG_HOSTS="$list"; EG_SOURCE=row
  return 0
}

eg_mechanism() {
  EG_REASON=""
  if [ -n "$EG_MECH" ]; then
    [ "$EG_MECH" = ok ] && return 0
    EG_REASON="$EG_MECH_REASON"; return 1
  fi
  EG_MECH=no
  if ! command -v unshare >/dev/null 2>&1; then EG_MECH_REASON=no-unshare
  elif ! command -v python3 >/dev/null 2>&1; then EG_MECH_REASON=no-python3
  elif [ ! -r "$(_eg_proxy)" ]; then EG_MECH_REASON=no-proxy-script
  elif [ "$(id -u)" = 0 ] && unshare -n true >/dev/null 2>&1; then EG_MECH=ok; EG_MECH_REASON=""
  elif [ "$(id -u)" != 0 ] && unshare -rn true >/dev/null 2>&1; then EG_MECH=ok; EG_MECH_REASON=""
  else EG_MECH_REASON=unshare-refused; fi
  [ "$EG_MECH" = ok ] && return 0
  EG_REASON="$EG_MECH_REASON"; return 1
}

_eg_proxy() {
  if [ -r "${_EG_LIB%/lib}/egress-proxy.py" ]; then printf '%s' "${_EG_LIB%/lib}/egress-proxy.py"
  elif [ -n "$(_eg_root)" ]; then printf '%s' "$(_eg_root)/bin/egress-proxy.py"; fi
}

# _eg_build <out> — the build dir an $OUT lives in, or rc 1 when it is in none.
_eg_build() {
  local out="${1:-}" pre rest id
  case "$out" in */builds/*/*) ;; *) return 1 ;; esac
  pre="${out%/builds/*}"; rest="${out#"$pre"/builds/}"; id="${rest%%/*}"
  [ -n "$id" ] || return 1
  printf '%s/builds/%s' "$pre" "$id"
}

_eg_state() { # _eg_state <state> <rest...> — one line into egress-state.txt
  [ -n "${_EG_B:-}" ] || return 0
  printf '%s stage=%s runner=%s state=%s %s\n' "$(_eg_stamp)" "$_EG_STAGE" "$_EG_RUNNER" "$1" "$2" \
    >> "$_EG_B/egress-state.txt" 2>/dev/null
  return 0
}

_eg_unenforced() { # _eg_unenforced <reason>
  local why="$1" root flag nh
  nh=$(printf '%s' "$EG_HOSTS" | wc -w | tr -d ' ')
  _eg_state not-enforced "source=$EG_SOURCE hosts=$nh direct_log=- caps=- deny=0 direct=0 reason=$why"
  root=$(_eg_root); [ -n "$root" ] || return 0
  # Once per box/stage/day; the noclobber create is the claim, so concurrent
  # calls still send one line.
  mkdir -p "$root/flags" 2>/dev/null
  flag="$root/flags/alerted-egress-unenforceable-$_EG_STAGE-$(date -u +%Y%m%d)"
  if ( set -C; : > "$flag" ) 2>/dev/null; then
    HARNESS="$root" "$root/bin/alert-line.sh" --severity warn --id "egress-unenforced-$_EG_STAGE" \
      "[agent-call] EGRESS ALLOWLIST NOT ENFORCED: $_EG_STAGE/${PROJECT:-?} has row egress.stage.$_EG_STAGE.hosts but this box cannot fence it ($why) — the stage runs with UNRESTRICTED outbound network. Fix the box (unshare/python3/bin/egress-proxy.py) or set the row to off." \
      >/dev/null 2>&1 || true
  fi
  return 0
}

eg_begin() {
  local stage="${1:-}" out="${2:-}" runner="${3:-}" py i
  EG_WRAP=(); _EG_B=""; _EG_DIR=""; _EG_PID=""; _EG_ID=""
  _EG_STAGE="$stage"; _EG_RUNNER="$runner"
  _EG_B=$(_eg_build "$out") || { _EG_B=""; return 0; }
  if ! eg_hosts "$stage"; then
    _eg_state not-armed "source=- hosts=0 direct_log=- caps=- deny=0 direct=0 reason=$EG_REASON"
    return 0
  fi
  if ! eg_mechanism; then _eg_unenforced "$EG_REASON"; return 0; fi
  _EG_DIR=$(mktemp -d /tmp/bhe.XXXXXX 2>/dev/null) || { _EG_DIR=""; _eg_unenforced mktemp-failed; return 0; }
  _EG_ID="${_EG_DIR##*.}"
  py=$(command -v python3)
  # A subshell that execs: $! is the proxy itself, its parent is still this
  # shell (it exits when we do), and the export stays out of the stage's env.
  (
    export PYTHONDONTWRITEBYTECODE=1
    exec python3 -B "$(_eg_proxy)" serve --sock "$_EG_DIR/s" --stage "$stage" --log "$_EG_B/egress.log" \
      --hosts "$EG_HOSTS" --id "$_EG_ID"
  ) </dev/null >/dev/null 2>"$_EG_DIR/err" &
  _EG_PID=$!
  for i in $(seq 1 50); do [ -S "$_EG_DIR/s" ] && break; kill -0 "$_EG_PID" 2>/dev/null || break; sleep 0.1; done
  if [ ! -S "$_EG_DIR/s" ]; then
    kill "$_EG_PID" 2>/dev/null; wait "$_EG_PID" 2>/dev/null
    rm -rf "$_EG_DIR"; _EG_DIR=""; _EG_PID=""
    _eg_unenforced proxy-not-up; return 0
  fi
  if [ "$(id -u)" = 0 ]; then EG_WRAP=(unshare -n --); else EG_WRAP=(unshare -rn --); fi
  EG_WRAP+=("$py" -B "$(_eg_proxy)" inner --sock "$_EG_DIR/s" --stage "$stage" --log "$_EG_B/egress.log" --id "$_EG_ID" --)
  return 0
}

eg_end() {
  local mode="${1:-}" i log deny direct dl caps nh
  [ -n "${_EG_PID:-}" ] || { EG_WRAP=(); return 0; }
  kill -TERM "$_EG_PID" 2>/dev/null
  for i in $(seq 1 30); do kill -0 "$_EG_PID" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$_EG_PID" 2>/dev/null
  wait "$_EG_PID" 2>/dev/null
  [ -n "${_EG_DIR:-}" ] && rm -rf "$_EG_DIR"
  if [ "$mode" != cancelled ]; then
    log="$_EG_B/egress.log"
    # The proxy's own END count is exact past the 500-line log cap; a proxy
    # that had to be KILLed wrote none, and then the lines are the count.
    deny=$(awk -v id="id=$_EG_ID" '$NF==id && $3=="END" {for(i=4;i<NF;i++) if($i~/^deny=/){sub(/^deny=/,"",$i); print $i}}' "$log" 2>/dev/null | tail -1)
    [ -n "$deny" ] || deny=$(awk -v id="id=$_EG_ID" '$NF==id && $3=="DENY"' "$log" 2>/dev/null | wc -l | tr -d ' ')
    direct=$(awk -v id="id=$_EG_ID" '$NF==id && $3=="END-INNER" {sub(/^direct=/,"",$4); print $4}' "$log" 2>/dev/null | tail -1)
    [ -n "$direct" ] || direct=$(awk -v id="id=$_EG_ID" '$NF==id && $3=="DENY-DIRECT"' "$log" 2>/dev/null | wc -l | tr -d ' ')
    dl=$(awk -v id="id=$_EG_ID" '$NF==id && $3=="INNER" {sub(/^direct_log=/,"",$4); print $4}' "$log" 2>/dev/null | tail -1)
    caps=$(awk -v id="id=$_EG_ID" '$NF==id && $3=="INNER" {sub(/^caps=/,"",$5); print $5}' "$log" 2>/dev/null | tail -1)
    nh=$(printf '%s' "$EG_HOSTS" | wc -w | tr -d ' ')
    _eg_state enforced "source=$EG_SOURCE hosts=$nh direct_log=${dl:--} caps=${caps:--} deny=${deny:-0} direct=${direct:-0}"
  fi
  EG_WRAP=(); _EG_PID=""; _EG_DIR=""
  return 0
}
