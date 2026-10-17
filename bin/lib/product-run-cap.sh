# shellcheck shell=bash
# Owner: BH-7244.5 (per-run USD cap, BH-7262).
#
# product_run_cap_check <stage> — rc 1 when this product cycle has spent its
# cap, rc 0 otherwise. bin/run-product.sh calls it after MAP, SIGNALS, IDEATE
# and SYNTH through cap_stop, which ends the cycle with rc 0 on a non-zero
# answer, so one run writes at most one ALERTS line.
#
# The spend is this run's rows in $HARNESS/logs/cost.csv: this project ($3,
# exact match), since the run start ($1 >= RUN_START_EPOCH as ISO), on a
# product stage ($4), summed over cost_usd ($13). That is the same window and
# layout as the cycle-summary sum in run-product.sh. The cap is the settings
# row PRODUCT_RUN_USD_CAP on lane run-product
# (catalog/lanes.d/run-product.knobs.d/PRODUCT_RUN_USD_CAP.json). The ALERTS
# line goes through bin/alert-line.sh, which beats it and appends it to
# $HARNESS/logs/ALERTS.log.
#
# Fail open (rc 0, no line): cap 0, empty or not a plain non-negative number;
# no HARNESS (or H), PROJECT or RUN_START_EPOCH (a bare source); no readable
# cost.csv. The root is never defaulted to /root/harness.
product_run_cap_check() {
  local stage="${1:-?}" cap="${PRODUCT_RUN_USD_CAP:-0}" h="${HARNESS:-${H:-}}" csv t0 spend now
  awk -v c="$cap" 'BEGIN { exit !(c ~ /^[0-9]+(\.[0-9]+)?$/ && c + 0 > 0) }' || return 0
  [ -n "$h" ] && [ -n "${PROJECT:-}" ] && [ -n "${RUN_START_EPOCH:-}" ] || return 0
  csv="$h/logs/cost.csv"
  [ -r "$csv" ] || return 0
  t0=$(date -u -d "@$RUN_START_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 0
  spend=$(awk -F, -v p="$PROJECT" -v t0="$t0" 'BEGIN { s = 0 }
    $1 >= t0 && $3 == p && $4 ~ /^(map|signals|ideate|synth|prd|mockup|pm)$/ { s += $13 }
    END { printf "%.2f", s }' "$csv" 2>/dev/null) || return 0
  awk -v s="$spend" -v c="$cap" 'BEGIN { exit !(s + 0 >= c + 0) }' || return 0
  now=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  echo "$now [$PROJECT] product: run cap reached after $stage: spend \$$spend >= cap \$$cap" >> "${LOG:-$h/logs/$PROJECT.log}"
  [ -x "$h/bin/alert-line.sh" ] && HARNESS="$h" "$h/bin/alert-line.sh" --project "$PROJECT" \
    "[$PROJECT] product: run USD cap reached after $stage: spend \$$spend >= PRODUCT_RUN_USD_CAP \$$cap, cycle stopped" >/dev/null 2>&1
  return 1
}
