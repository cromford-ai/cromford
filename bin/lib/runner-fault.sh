#!/bin/bash
# bin/lib/runner-fault.sh — BH-10274: a triage shard's runner failed before the
# model answered. Functions only; nothing runs on source.
#
# On 2026-11-26 11:28Z eight project-3 shards ended `codex rc=1`. The shard called
# bin/agent-call.sh once, and agent-call.sh fails over only when its FALLBACK
# differs from the runner (bin/agent-call.sh, `"$FALLBACK" != "$RUNNER"`), while
# bin/bootstrap-machine.sh writes RUNNER_TRIAGE_FALLBACK=codex: a codex primary
# had no other rung. The console summary was `tail -3` of the output, which on a
# Node crash is three `at ...` frames, so the error itself was never shown.
#
#   rf_first_error <file>...                 the first error line
#   rf_cut <text>                            text cut to TRIAGE_SHARD_ERR_LINE_MAX
#   rf_start_fault <rc> <elapsed_s> <out>    rc 0 = a runner fault before the model answered
#   rf_other_runner <failed_runner>          the runner to retry on
#   rf_fault_line <p> <key> <runner> <rc> <secs> <errline> <outcome>
#
# Knobs (rows in catalog/lanes.d/run-triage.knobs.d/, delivered by
# lane_env_apply run-triage): TRIAGE_SHARD_FAULT_S, TRIAGE_SHARD_RETRY_RUNNER,
# TRIAGE_SHARD_ERR_LINE_MAX. TRIAGE_SHARD_FAULT_RETRY is read in bin/triage-shard.sh.

# An error head: `Error: x`, `TypeError: x`, `Uncaught Error`, `FooException [..]`,
# `ERROR: x`, `error: x`, or an errno / Node error code anywhere in the line.
_RF_ERR_RE='^(Uncaught )?([A-Za-z_$][A-Za-z0-9_$.]*)?(Error|Exception)(:| \[|$)|^(ERROR|Error|error)(:|\[| \[)|(^|[^A-Za-z])(ENOENT|ENOSPC|EACCES|ERR_[A-Z_]+)\b'
# Not an error and not a message: a stack frame, a caret line, a bare location.
_RF_NOISE_RE='^$|^at |^\^+[[:space:]]*$|^(node:internal/|file://)[^ ]*:[0-9]+$'

# _rf_lines <file>: the file with CR stripped and leading space trimmed.
_rf_lines() { tr -d '\r' < "$1" 2>/dev/null | sed -E 's/^[[:space:]]+//'; }

_rf_err_max() {
  # Knob row lane.run-triage.triage_shard_err_line_max; code fallback 300.
  local max="${TRIAGE_SHARD_ERR_LINE_MAX:-300}"
  case "$max" in ''|0|*[!0-9]*) max=300 ;; esac
  printf '%s\n' "$max"
}

# rf_cut <text>: the text cut to TRIAGE_SHARD_ERR_LINE_MAX chars (the refusal
# marker in the fault line uses the same row as the error line).
rf_cut() { local t="${1:-}" max; max=$(_rf_err_max); printf '%s\n' "${t:0:$max}"; }

rf_first_error() {
  local max f l=""
  max=$(_rf_err_max)
  for f in "$@"; do
    [ -r "$f" ] || continue
    l=$(_rf_lines "$f" | grep -m1 -aE "$_RF_ERR_RE") && [ -n "$l" ] && break
    l=""
  done
  if [ -z "$l" ]; then
    for f in "$@"; do
      [ -r "$f" ] || continue
      l=$(_rf_lines "$f" | grep -m1 -avE "$_RF_NOISE_RE") && [ -n "$l" ] && break
      l=""
    done
  fi
  if [ -z "$l" ]; then
    for f in "$@"; do
      [ -r "$f" ] || continue
      l=$(_rf_lines "$f" | grep -m1 -a .) && [ -n "$l" ] && break
      l=""
    done
  fi
  printf '%s\n' "${l:0:$max}"
}

rf_start_fault() {
  local rc="${1:-}" el="${2:-}" out="${3:-}"
  # Knob row lane.run-triage.triage_shard_fault_s; code fallback 120.
  local max="${TRIAGE_SHARD_FAULT_S:-120}"
  case "$max" in ''|0|*[!0-9]*) max=120 ;; esac
  case "$rc" in 1|126|127) ;; *) return 1 ;; esac
  case "$el" in ''|*[!0-9]*) return 1 ;; esac
  [ "$el" -le "$max" ] || return 1
  if [ -n "$out" ] && [ -f "$out" ]; then
    case "$(head -1 "$out" 2>/dev/null)" in AGENT_CALL_REFUSED*) return 1 ;; esac
    grep -qa '^DECISION:' "$out" 2>/dev/null && return 1
    grep -qa 'tickets=' "$out" 2>/dev/null && return 1
  fi
  return 0
}

rf_other_runner() {
  local failed="${1:-}"
  # Knob row lane.run-triage.triage_shard_retry_runner; empty = the default below.
  local k="${TRIAGE_SHARD_RETRY_RUNNER:-}"
  if [[ "$k" =~ ^[a-z0-9_-]+$ ]] && [ "$k" != "$failed" ]; then
    printf '%s\n' "$k"; return 0
  fi
  if [ "$failed" = claude ]; then echo codex; else echo claude; fi
}

rf_fault_line() {
  local p="$1" k="$2" r="$3" rc="$4" s="$5" e="${6:-}" o="$7"
  [ -n "$e" ] || e="(no error text)"
  printf '[%s/%s] TRIAGE RUNNER FAULT: %s rc=%s before the model answered (%ss): %s — %s\n' "$p" "$k" "$r" "$rc" "$s" "$e" "$o"
}
