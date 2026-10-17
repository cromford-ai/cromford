#!/bin/bash
# bin/lib/fly-metrics.sh — per-machine CPU and network rates from Fly's
# Prometheus API (BH-6877). Sourced, never executed; sourcing it has no side
# effects. bin/fly-idle-reaper.sh reads it once per pass for the `metrics`
# idle signal: an app with no registry entry.
#
#   fly_metrics_fetch <org-slug> <window_s> <token> <out.tsv>
#     rc 0: <out.tsv> holds one line per machine (the `instance` label):
#       <machine_id> TAB <busy cpu %> TAB <net bytes/s>
#     A value Fly did not return is `-`. rc 1: a bad argument, curl or jq
#     missing, an HTTP or network failure, or an answer that is not a
#     Prometheus vector. <out.tsv> is then not to be read.
#
# The two queries, each over the last <window_s> seconds:
#   cpu  100 * rate(fly_instance_cpu{mode!="idle"}) / rate(fly_instance_cpu)
#        summed per instance: the share of CPU time that was not idle, so the
#        counter's unit does not matter.
#   net  rate(fly_instance_net_recv_bytes) + rate(fly_instance_net_sent_bytes)
#        summed per instance.
#
# The token goes to curl in a header file (mode 600, removed on return), never
# on the command line. FLY_METRICS_URL (default https://api.fly.io/prometheus)
# is the base; a test points it at nothing and stubs curl on PATH.
fly_metrics_fetch() {
  local org="$1" win="$2" tok="$3" out="$4" base hdr q f rc=0
  case "$org" in ''|*[!a-z0-9-]*) return 1 ;; esac
  case "$win" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$tok" ] && [ -n "$out" ] || return 1
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  base="${FLY_METRICS_URL:-https://api.fly.io/prometheus}"
  hdr=$(mktemp "${TMPDIR:-/tmp}/fly-metrics-hdr.XXXXXX") || return 1
  chmod 600 "$hdr" 2>/dev/null
  printf 'Authorization: %s\n' "$tok" > "$hdr"
  for f in cpu net; do
    case "$f" in
      cpu) q="100 * sum by (instance) (rate(fly_instance_cpu{mode!=\"idle\"}[${win}s])) / sum by (instance) (rate(fly_instance_cpu[${win}s]))" ;;
      net) q="sum by (instance) (rate(fly_instance_net_recv_bytes[${win}s])) + sum by (instance) (rate(fly_instance_net_sent_bytes[${win}s]))" ;;
    esac
    if ! curl -sS -f -G --max-time 30 -H "@$hdr" "$base/$org/api/v1/query" \
         --data-urlencode "query=$q" > "$out.$f.json" 2>/dev/null \
       || ! jq -e '.status == "success" and .data.resultType == "vector" and (.data.result | type == "array")' \
         "$out.$f.json" >/dev/null 2>&1; then
      rc=1; break
    fi
  done
  rm -f "$hdr"
  if [ "$rc" = 0 ]; then
    jq -nr --slurpfile c "$out.cpu.json" --slurpfile n "$out.net.json" '
      def vals($d): [$d[0].data.result[] | select(.metric.instance != null)
                     | {key: .metric.instance, value: (.value[1] | tonumber? // null)}] | from_entries;
      vals($c) as $cv | vals($n) as $nv
      | ([($cv, $nv) | keys[]] | unique)[]
      | [., ($cv[.] // "-" | tostring), ($nv[.] // "-" | tostring)] | @tsv' > "$out" 2>/dev/null || rc=1
  fi
  rm -f "$out.cpu.json" "$out.net.json"
  return "$rc"
}
