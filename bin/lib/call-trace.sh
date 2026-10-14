#!/bin/bash
# bin/lib/call-trace.sh — BH-6462: the per-worker call trace. Sourced by
# bin/lib/fanin.sh, never run. gh_rest (bin/lib/gh-rest.sh) and _jobs_req
# (bin/lib/jobs/req.sh) call call_trace_put behind `command -v`, so a lane
# that never sources this file writes nothing.
#
#   call_trace_t0 <var>
#       Sets the caller's <var> to EPOCHREALTIME (empty when the shell has
#       none), with printf -v: no subshell. The two transports call it rather
#       than read the clock themselves, because they are also sourced by the
#       lead's Mac post on bash 3.2 (tests/lead-verdict-bash32.bh-3565-test.sh
#       pins that closure free of bash >= 4 names).
#   call_trace_put <kind> <what> <status> <t0>
#       Appends `<step>\t<kind>\t<what>\t<ms>\t<status>` to
#       HARNESS_CALL_TRACE_FILE. <step> is MC_STEP_NAME (set by mc_step), or
#       `start` before the first step. <what> loses everything from its first
#       `?`, tabs and newlines become spaces, and it is cut to 80 bytes, so a
#       query string never reaches the file. <ms> is now minus <t0>, both
#       EPOCHREALTIME values. Writes nothing when the file variable, <t0> or
#       EPOCHREALTIME is empty (bash < 5 has no EPOCHREALTIME). Always rc 0.
#   call_trace_summary <file>
#       One line of 300 bytes or less: `<step> <kind>=<n>/<s.s>s ...; ...
#       slowest: <kind> <what> <s.s>s (<step>)`. Steps keep their first-seen
#       order; the steps that do not fit are counted as ` +N more`. A line that
#       does not have 5 tab fields and a numeric ms is skipped (a kill can cut
#       an append). A missing or empty file prints `none`.
#
# HARNESS_CALL_TRACE_FILE is set only by mc_worker_bounded, as a local that is
# never exported, so a lane that is not a bounded conductor worker, and every
# detached child, writes nothing. The callers put no `$( )` around a request to
# take the time: call_trace_t0 sets t0 in place.
if [ -n "${CALL_TRACE_LIB:-}" ]; then return 0 2>/dev/null; fi
CALL_TRACE_LIB=1

call_trace_t0() {
  [ -n "${1:-}" ] || return 0
  printf -v "$1" '%s' "${EPOCHREALTIME:-}"
}

call_trace_put() {
  local f="${HARNESS_CALL_TRACE_FILE:-}" t0="${4:-}" now="${EPOCHREALTIME:-}" what="${2:-}" s0 s1 u0 u1 ms
  [ -n "$f" ] && [ -n "$t0" ] && [ -n "$now" ] || return 0
  s0=${t0%[.,]*}; u0=${t0#*[.,]}; s1=${now%[.,]*}; u1=${now#*[.,]}
  [[ "$s0$u0$s1$u1" =~ ^[0-9]+$ ]] || return 0
  ms=$(( (s1 - s0) * 1000 + (10#$u1 - 10#$u0) / 1000 ))
  [ "$ms" -ge 0 ] || ms=0
  what=${what%%\?*}; what=${what//$'\t'/ }; what=${what//$'\n'/ }; what=${what:0:80}
  printf '%s\t%s\t%s\t%s\t%s\n' "${MC_STEP_NAME:-start}" "${1:-?}" "$what" "$ms" "${3:-?}" >> "$f" 2>/dev/null
  return 0
}

call_trace_summary() {
  local out
  out=$(awk -F '\t' '
    NF == 5 && $1 != "" && $2 != "" && $4 ~ /^[0-9]+$/ {
      if (!($1 in seen)) { seen[$1] = 1; ns++; st[ns] = $1 }
      k = $1 SUBSEP $2
      if (!(k in n)) { nk[$1]++; kd[$1, nk[$1]] = $2 }
      n[k]++; ms[k] += $4
      if (!found || $4 > top) { found = 1; top = $4; tk = $2; tw = $3; ts = $1 }
    }
    END {
      if (!found) { print "none"; exit }
      tail = sprintf("; slowest: %s %s %.1fs (%s)", tk, tw, top / 1000, ts)
      body = ""; more = 0
      for (i = 1; i <= ns; i++) {
        s = st[i]; it = s
        for (j = 1; j <= nk[s]; j++) { k = s SUBSEP kd[s, j]; it = it sprintf(" %s=%d/%.1fs", kd[s, j], n[k], ms[k] / 1000) }
        if (more || length(body) + length(it) + 2 + length(tail) > 285) { more++; continue }
        body = (body == "" ? it : body "; " it)
      }
      if (more) body = body " +" more " more"
      out = body tail
      print substr(out, 1, 300)
    }' "${1:-/dev/null}" 2>/dev/null)
  printf '%s\n' "${out:-none}"
}
