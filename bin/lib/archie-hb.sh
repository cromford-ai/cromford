#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-hb.sh — Archie's heartbeat and activity rows on the
# /staff screen (BH-9127). Sourced, never executed. Defines functions only.
#
#   archie_hb_now                      the current instant, ISO-Z
#   archie_hb_key <kind> [started_at]  archie-<kind>-<epoch>-<pid>; kind is
#                                      turn | sweep | research. With an ISO-Z
#                                      started_at, the epoch is that instant.
#   archie_hb_trigger <origin> <transport> <from_name>
#                                      the turn trigger: dash | slack |
#                                      telegram | beat (see the table below)
#   archie_hb_tick <kind> <started_at> <phase> [collected] [model_calls] [digested]
#                                      POST /api/staff/ticks, agent archie
#   archie_hb_turn <turn_key> <started_at> <trigger> <outcome> <summary_file> [cost_run_id]
#                                      POST /api/staff/turns, agent archie
#
# FAIL OPEN. Every function returns 0 and prints nothing on stdout. A post
# that fails (rc != 0 or a non-2xx answer) writes ONE line to the log:
#   <iso> archie-heartbeat: tick|turn <key> post failed rc=<rc> http=<code>
# Nothing is retried: the next turn or tick posts its own row. Each of tick
# and turn posts at most once per process (_ARCHIE_HB_TICK_SENT,
# _ARCHIE_HB_TURN_SENT).
#
# THE TRANSPORT is `_jobs_req_file` (bin/lib/jobs/req.sh, through
# bin/jobs-client.sh). When the caller has not loaded it, the first post
# sources "$root/bin/jobs-client.sh". No root and no transport is a failed
# post (rc 127), logged when there is a log to write. Each post sets
# JOBS_ALERT=0, so a failed post writes no ALERTS line.
#
# THE TURN SUMMARY is the first non-blank line of <summary_file>, put through
# token_redact (bin/lib/token-redact.sh) and cut to the settings row
# staff.turns.summary_in_max (setting_get, box-cached; fallback 2000 when the
# row is absent, unreadable or not a positive integer). The route rejects a
# longer summary with that same row, and stores
# staff.turns.summary_max_chars of it.
# If the scrub cannot run, the summary is "(summary withheld: scrub failed)".
# link_url is the first https://github.com/<owner>/<repo>/(issues|pull)/<n> in
# the file, else null.
#
# TRIGGER TABLE (archie_hb_trigger):
#   origin dash                        -> dash
#   from_name set, transport slack     -> slack
#   from_name set, transport telegram
#     or empty                         -> telegram
#   anything else (no sidecar, an empty from_name, a cron or alert beat) -> beat
#
# SEAMS: ARCHIE_HB_NOW (epoch seconds; read only with HARNESS_TEST_SANDBOX=1)
# pins the clock. ARCHIE_HB_LOG names the log (default
# $root/logs/archie-heartbeat.log). The root is ${HARNESS:-${H:-}}; with no
# root and no ARCHIE_HB_LOG, nothing is logged.

_archie_hb_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_archie_hb_epoch() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_HB_NOW:-} =~ ^[0-9]+$ ]]; then
    printf '%s' "$ARCHIE_HB_NOW"
  else
    date -u +%s
  fi
}

archie_hb_now() { date -u -d "@$(_archie_hb_epoch)" +%Y-%m-%dT%H:%M:%SZ; }

archie_hb_key() {
  local kind="${1:-turn}" at="${2:-}" e=""
  [ -n "$at" ] && [[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && e=$(date -u -d "$at" +%s 2>/dev/null)
  [ -n "$e" ] || e=$(_archie_hb_epoch)
  printf 'archie-%s-%s-%s\n' "$kind" "$e" "$$"
}

archie_hb_trigger() {
  local origin="${1:-}" transport="${2:-}" from="${3:-}"
  if [ "$origin" = dash ]; then printf 'dash\n'; return 0; fi
  if [ -n "${from//[[:space:]]/}" ]; then
    case "$transport" in
      slack) printf 'slack\n'; return 0 ;;
      telegram|'') printf 'telegram\n'; return 0 ;;
    esac
  fi
  printf 'beat\n'
}

# _archie_hb_client: source bin/jobs-client.sh when the caller has not loaded
# the transport. Always rc 0.
_archie_hb_client() {
  local root
  root=$(_archie_hb_root)
  if ! type _jobs_req_file >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/jobs-client.sh" ]; then
    # shellcheck source=bin/jobs-client.sh
    . "$root/bin/jobs-client.sh" >/dev/null 2>&1
  fi
  return 0
}

# _archie_hb_summary_max: the settings row staff.turns.summary_in_max, the
# route's input bound. 2000 is its fallback, the same as the route's.
_archie_hb_summary_max() {
  local v=""
  _archie_hb_client
  type setting_get >/dev/null 2>&1 && v=$(JOBS_ALERT=0 setting_get staff.turns.summary_in_max 2>/dev/null)
  v="${v//[[:space:]]/}"
  if [[ $v =~ ^[0-9]{1,9}$ ]] && [ "$((10#$v))" -ge 1 ]; then printf '%s' "$((10#$v))"; else printf '2000'; fi
}

# _archie_hb_post <tick|turn> <key> <path> <body-file>: one post, one log line on failure.
_archie_hb_post() {
  local what="$1" key="$2" path="$3" f="$4" root rc=0 log
  root=$(_archie_hb_root)
  _archie_hb_client
  JOBS_HTTP=""
  if type _jobs_req_file >/dev/null 2>&1; then
    # JOBS_ALERT=0: the transport keeps its own log line and writes no ALERTS
    # line. A heartbeat is optional evidence; the lanes that depend on the
    # worker already alert an outage.
    JOBS_ALERT=0 _jobs_req_file POST "$path" "$f" >/dev/null 2>&1 || rc=$?
  else
    rc=127
  fi
  [ "$rc" = 0 ] && return 0
  log="${ARCHIE_HB_LOG:-}"
  [ -n "$log" ] || { [ -n "$root" ] && log="$root/logs/archie-heartbeat.log"; }
  [ -n "$log" ] || return 0
  { mkdir -p "${log%/*}" && printf '%s archie-heartbeat: %s %s post failed rc=%s http=%s\n' \
      "$(archie_hb_now)" "$what" "$key" "$rc" "${JOBS_HTTP:-none}" >> "$log"; } 2>/dev/null
  return 0
}

_archie_hb_int() { [[ ${1:-} =~ ^[0-9]+$ ]] && printf '%s' "$((10#$1))" || printf '0'; }

archie_hb_tick() {
  [ "${_ARCHIE_HB_TICK_SENT:-0}" = 1 ] && return 0
  _ARCHIE_HB_TICK_SENT=1
  local kind="${1:-turn}" started="${2:-}" phase="${3:-done}" key f
  key=$(archie_hb_key "$kind" "$started")
  [ -n "$started" ] || started=$(archie_hb_now)
  f=$(mktemp "${TMPDIR:-/tmp}/archie-hb.XXXXXX" 2>/dev/null) || { _archie_hb_post tick "$key" /api/staff/ticks /dev/null; return 0; }
  if jq -n --arg k "$key" --arg s "$started" --arg e "$(archie_hb_now)" --arg p "$phase" \
       --argjson col "$(_archie_hb_int "${4:-0}")" --argjson mc "$(_archie_hb_int "${5:-0}")" --argjson dg "$(_archie_hb_int "${6:-0}")" '
       {tick_key: $k, agent: "archie", started_at: $s, ended_at: $e, phase: $p,
        collector_rc: null, collector_s: null, model_rc: null,
        collected: $col, new_items: 0, deferred: 0, model_calls: $mc, digested: $dg,
        filed: 0, refused: 0, unsupported: 0, failed: 0, held: 0, cost_run_id: null}' > "$f" 2>/dev/null; then
    _archie_hb_post tick "$key" /api/staff/ticks "$f"
  else
    _archie_hb_post tick "$key" /api/staff/ticks /dev/null
  fi
  rm -f "$f"
  return 0
}

archie_hb_turn() {
  [ "${_ARCHIE_HB_TURN_SENT:-0}" = 1 ] && return 0
  _ARCHIE_HB_TURN_SENT=1
  local key="${1:-}" started="${2:-}" trigger="${3:-beat}" outcome="${4:-answered}" sf="${5:-}" run="${6:-}"
  local text="" line="" summary link f root
  root=$(_archie_hb_root)
  if ! type token_redact >/dev/null 2>&1 && [ -n "$root" ]; then
    # shellcheck source=bin/lib/token-redact.sh
    . "$root/bin/lib/token-redact.sh" 2>/dev/null
  fi
  [ -n "$sf" ] && text=$(head -c 65536 "$sf" 2>/dev/null)
  line=$(printf '%s\n' "$text" | tr -d '\r' | grep -m1 -v '^[[:space:]]*$')
  [ -n "$line" ] || line="(no reply text)"
  if type token_redact >/dev/null 2>&1 && summary=$(printf '%s\n' "$line" | token_redact 2>/dev/null) && [ -n "$summary" ]; then
    summary="${summary:0:$(_archie_hb_summary_max)}"
  else
    summary="(summary withheld: scrub failed)"
  fi
  # The same shape as LINK_RE in worker/jobs/src/routes/staff-turns.js, so a
  # link the route would refuse never costs the turn its row.
  link=$(printf '%s\n' "$text" | grep -oE 'https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}/(issues|pull)/[1-9][0-9]{0,9}' | head -n1)
  f=$(mktemp "${TMPDIR:-/tmp}/archie-hb.XXXXXX" 2>/dev/null) || { _archie_hb_post turn "$key" /api/staff/turns /dev/null; return 0; }
  if jq -n --arg k "$key" --arg s "$started" --arg e "$(archie_hb_now)" --arg t "$trigger" --arg o "$outcome" \
       --arg sm "$summary" --arg l "$link" --arg r "$run" '
       {agent: "archie", turn_key: $k, started_at: $s, ended_at: $e, trigger: $t, outcome: $o, summary: $sm,
        link_url: (if $l == "" then null else $l end), cost_run_id: (if $r == "" then null else $r end)}' > "$f" 2>/dev/null; then
    _archie_hb_post turn "$key" /api/staff/turns "$f"
  else
    _archie_hb_post turn "$key" /api/staff/turns /dev/null
  fi
  rm -f "$f"
  return 0
}
