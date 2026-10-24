#!/bin/bash
# bin/lib/qrf/ready.sh — BH-2342 (BH-2313.4), sourced by
# bin/queue-rows-flip-preflight.sh: the ready_queue_rows gate.
#
# Live probe: the read queue_ready_list sends (GET /api/queue?status=ready, no
# limit=, so the route default of 200, array .queue). A non-2xx, a non-array or
# rows = 200 FAILs, and parity is then "not checked", never matched.
# Row parity: every live line of logs/READY-QUEUE.log (the rq_lines parse:
# `^[A-Z]+-[0-9]`, key `^[A-Z]+-[0-9A-Za-z]+`, matched by key only) has a row
# in that answer. A line with no row FAILs, naming the line and the
# queue_ready_put that writes it. A row with no line is info: the rows are a
# superset. Reads only; the one file written is $QRF_TMP, through qrf_list.
qrf_gate_ready() {
  local log="$QRF_H/logs/READY-QUEUE.log" route="/api/queue?status=ready"
  local keys lines line key project n=0 bad=0 extra=0 k
  if ! qrf_list ready "$route" .queue 200 "$QRF_TMP"; then
    qrf_fail ready "row parity: not checked (live probe failed)"; return
  fi
  keys=$(jq -r '.queue[].ticket_key // empty' "$QRF_TMP" | sort -u)
  if [ -r "$log" ]; then
    if declare -F _rq_norm >/dev/null; then lines=$(_rq_norm < "$log"); else lines=$(grep -E '^[A-Z]+-[0-9]' "$log"); fi
  else qrf_info "no READY-QUEUE.log on this box"; lines=""; fi
  local wrapped=$'\n'"$keys"$'\n' seen=$'\n'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=$(printf '%s' "$line" | grep -oE '^[A-Z]+-[0-9A-Za-z]+')
    seen="$seen$key"$'\n'
    case "$wrapped" in *$'\n'"$key"$'\n'*) n=$((n+1)); continue ;; esac
    project=$(printf '%s' "$line" | grep -oE 'project=[a-z-]+' | head -n1)
    project="${project#project=}"
    qrf_fail ready "READY-QUEUE.log line has no ready row: $line — fix: queue_ready_put ${project:-<project>} $key - '$line'"
    bad=$((bad+1))
  done <<< "$lines"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$seen" in *$'\n'"$k"$'\n'*) ;; *) extra=$((extra+1)) ;; esac
  done <<< "$keys"
  [ "$extra" = 0 ] || qrf_info "$extra ready row(s) with no READY-QUEUE.log line (rows are a superset, not a failure)"
  [ "$bad" = 0 ] && qrf_pass "row parity: $n READY-QUEUE.log line(s) matched"
}
