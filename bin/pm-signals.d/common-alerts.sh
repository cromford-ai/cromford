# shellcheck shell=bash
# pm-signals adapter: $HARNESS/logs/ALERTS.log lines that carry [<project>]; ids alerts.7d, alerts.30d.
# A line counts when its first 19 chars are a UTC stamp (a space or a T between
# date and time) inside the window and not later than now. No readable file
# is "not-configured" with value null: a missing log is not evidence of zero.
pms_alerts() {
  local p="$1" f="${HARNESS:-/root/harness}/logs/ALERTS.log" now n7 n30 w
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    for w in 7d 30d; do
      jq -nc --arg w "$w" '{id:("alerts."+$w), source:"alerts", metric:"alert_lines", value:null, window:$w, link:"logs/ALERTS.log", status:"not-configured"}'
    done
    return 0
  fi
  now=${PM_SIGNALS_NOW:-$(date +%s)}
  read -r n7 n30 < <(awk -v p="[$p]" \
    -v n="$(date -u -d "@$now" '+%Y-%m-%d %H:%M:%S')" \
    -v c7="$(date -u -d "@$((now - 7*86400))" '+%Y-%m-%d %H:%M:%S')" \
    -v c30="$(date -u -d "@$((now - 30*86400))" '+%Y-%m-%d %H:%M:%S')" '
    BEGIN { a = 0; b = 0 }
    {
      t = substr($0, 1, 19)
      if (substr(t, 11, 1) == "T") t = substr(t, 1, 10) " " substr(t, 12)
      if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) next
      if (index($0, p) == 0 || t > n) next
      if (t >= c7) a++
      if (t >= c30) b++
    }
    END { print a, b }' "$f") || return 1
  [ -n "${n30:-}" ] || return 1
  for w in 7d 30d; do
    jq -nc --arg w "$w" --argjson v "$([ "$w" = 7d ] && echo "$n7" || echo "$n30")" \
      '{id:("alerts."+$w), source:"alerts", metric:"alert_lines", value:$v, window:$w, link:"logs/ALERTS.log", status:"ok"}'
  done
}
