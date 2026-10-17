# shellcheck shell=bash
# pm-signals adapter: cost and credit burn for the project (BH-7259).
#   cost.7d, cost.30d        metric usd: the sum of cost_usd (column 13) over
#       $HARNESS/logs/cost.csv rows whose project (column 3) is the project
#       exactly and whose ISO ts (column 1) is inside [now - N days, now]. The
#       header, a non-ISO or future ts and an empty or non-numeric cost are
#       skipped. No readable file = not-configured.
#   cost.d1_7d, cost.d1_30d  metric usd_d1: GET $JOBS_URL/api/metrics/llm-spend
#       ?project=&since=&until= (the jobs D1 cost rows). JOBS_URL or
#       HARNESS_SECRET empty = not-configured, with no call and no fallback to
#       the fleet worker. A failed call or a non-number .usd = error.
# The jobs client lib is not used: its degraded path writes log and ALERTS lines.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/pm-signals-adapter.sh" || return 1
pms_cost() {
  local p="$1" root f now w d sums s7 s30 v body q
  root=$(_pmsa_root); f="$root/logs/cost.csv"; now=$(_pmsa_now)
  if [ -n "$root" ] && [ -f "$f" ] && [ -r "$f" ]; then
    sums=$(awk -F, -v p="$p" -v n="$(_pmsa_iso "$now")" \
      -v c7="$(_pmsa_iso $((now - 7*86400)))" -v c30="$(_pmsa_iso $((now - 30*86400)))" '
      BEGIN { a = 0; b = 0 }
      $3 != p { next }
      $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { next }
      $13 !~ /^-?[0-9]+(\.[0-9]+)?$/ { next }
      $1 > n { next }
      { if ($1 >= c7) a += $13; if ($1 >= c30) b += $13 }
      END { printf "%.4f %.4f\n", a, b }' "$f") || return 1
    read -r s7 s30 <<<"$sums"
    [ -n "${s30:-}" ] || return 1
    _pmsa_row cost.7d cost usd "$s7" 7d logs/cost.csv ok || return 1
    _pmsa_row cost.30d cost usd "$s30" 30d logs/cost.csv ok || return 1
  else
    _pmsa_nc cost.7d cost usd 7d logs/cost.csv || return 1
    _pmsa_nc cost.30d cost usd 30d logs/cost.csv || return 1
  fi
  for w in 7d 30d; do
    d=${w%d}
    if [ -z "${JOBS_URL:-}" ] || [ -z "${HARNESS_SECRET:-}" ]; then
      _pmsa_nc "cost.d1_$w" cost usd_d1 "$w" /api/metrics/llm-spend || return 1
      continue
    fi
    q="project=$p&since=$(_pmsa_iso $((now - d*86400)))&until=$(_pmsa_iso "$now")"
    if body=$(curl -fsS --max-time 8 -H @<(printf 'authorization: Bearer %s\n' "$HARNESS_SECRET") \
         "${JOBS_URL%/}/api/metrics/llm-spend?$q" 2>/dev/null) \
       && v=$(jq -e '.usd | numbers' <<<"$body" 2>/dev/null); then
      _pmsa_row "cost.d1_$w" cost usd_d1 "$v" "$w" /api/metrics/llm-spend ok || return 1
    else
      _pmsa_err "cost.d1_$w" cost usd_d1 "$w" /api/metrics/llm-spend || return 1
    fi
  done
  return 0
}
