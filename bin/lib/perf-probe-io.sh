# shellcheck shell=bash
# bin/lib/perf-probe-io.sh — BH-9786: the IO half of the daily perf probe
# (bin/perf-probe.sh). Sourced, never executed: no `exit`, no `set`, no output
# at source time. The root is ${HARNESS:-${H:-}}; with no root every function
# returns 1.
#
#   ppio_lock <project> <wait_s>   flock -w on FD 9 of locks/perf-probe-<project>.lock
#   ppio_unlock                    close FD 9
#   ppio_token <project>           the project's internal token VALUE on stdout
#                                  (board_token_var on env/projects/<project>.env).
#                                  The caller keeps it in a variable; it is never
#                                  logged and never put in argv.
#   ppio_session <project> <row>   the session jar path, rc 0; or skip:<why>, rc 1
#   ppio_load <url> <jar>          one GET; prints the load line
#                                  `<status> <ttfb_ms> <total_ms> <bytes> <location|->`
#                                  then sleeps PERF_PROBE_PAUSE_MS
#   ppio_state_get <project> <name>   cat state/perf-probe/<project>/<name>.json
#   ppio_state_put <project> <name>   stdin to that file (tmp + mv)
#   ppio_keepwarm_reset <project>     keepwarm.json = {"fails":0}
#
# SESSION. roles[0] of the row is the role. The token goes to curl on stdin
# (`-K -`, a header line), never in argv. POST <base_url><session_path> with
# {"role": roles[0]}, no -L. A 2xx with a cookie in the jar writes
# session.json {minted_at, expires_at}; expires_at is the answer's expiresAt,
# else minted_at, so a jar with no expiry is not reused on a later run. Any
# other answer removes the jar and prints skip:<status>. There is no other
# sign-in path. The jar is created under umask 077 (mode 0600).
# Knobs (exported by bin/perf-probe.sh from lane_knob): PERF_PROBE_TIMEOUT_S
# (fallback 30), PERF_PROBE_PAUSE_MS (fallback 500). PERF_PROBE_NOW pins the clock.
# Note: docs/notes/2026-11-17-BH-9786-perf-probe.md.

# shellcheck source=bin/lib/env-path.sh
. "${BASH_SOURCE[0]%/*}/env-path.sh" 2>/dev/null || true
# shellcheck source=bin/lib/board-creds.sh
. "$(dirname "${BASH_SOURCE[0]}")/board-creds.sh" 2>/dev/null || true

_ppio_root() { local h="${HARNESS:-${H:-}}"; [ -n "$h" ] || return 1; printf '%s' "$h"; }
_ppio_dir() { local h; h=$(_ppio_root) || return 1; printf '%s/state/perf-probe/%s' "$h" "$1"; }
_ppio_now_s() {
  if [ -n "${PERF_PROBE_NOW:-}" ]; then date -u -d "$PERF_PROBE_NOW" +%s 2>/dev/null; else date -u +%s; fi
}
_ppio_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

ppio_lock() {
  local h; h=$(_ppio_root) || return 1
  [ -n "${1:-}" ] || return 1
  mkdir -p "$h/locks" 2>/dev/null
  exec 9>"$h/locks/perf-probe-$1.lock" || return 1
  flock -w "${2:-0}" 9 && return 0
  exec 9>&-
  return 1
}

ppio_unlock() { exec 9>&-; }

ppio_token() {
  local h envd f name v
  h=$(_ppio_root) || return 1
  command -v board_token_var >/dev/null 2>&1 && command -v harness_env_dir >/dev/null 2>&1 || return 1
  envd=$(harness_env_dir "$h") || return 1
  f="$envd/projects/$1.env"
  [ -r "$f" ] || return 1
  name=$(board_token_var "$1" "$f" perf-probe) || return 1
  v=$(board_env_value "$name" "$f")
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

ppio_state_get() {
  local d; d=$(_ppio_dir "$1") || return 1
  cat "$d/$2.json" 2>/dev/null
}

ppio_state_put() {
  local d; d=$(_ppio_dir "$1") || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  cat > "$d/.$2.json.tmp" && mv -f "$d/.$2.json.tmp" "$d/$2.json"
}

ppio_keepwarm_reset() { printf '{"fails":0}\n' | ppio_state_put "$1" keepwarm; }

# _ppio_has_cookie <jar> — a cookie line (an #HttpOnly_ line counts; the
# header comments do not).
_ppio_has_cookie() { grep -qE '^(#HttpOnly_)?[^#[:space:]][^[:space:]]*'$'\t' "$1" 2>/dev/null; }

ppio_session() {
  local p="${1:-}" row="${2:-}" d jar role base sp tok tesc body code exp exps now resp
  d=$(_ppio_dir "$p") || { echo skip:no-root; return 1; }
  role=$(jq -r 'if (.roles|type) == "array" and (.roles[0]|type) == "string" then .roles[0] else "" end' "$row" 2>/dev/null)
  [ -n "$role" ] || { echo skip:no-roles; return 1; }
  (umask 077; mkdir -p "$d") || { echo skip:no-state-dir; return 1; }
  jar="$d/session.jar"
  now=$(_ppio_now_s)
  # An unexpired session from an earlier run is reused: 0 POSTs.
  if [ -s "$jar" ] && _ppio_has_cookie "$jar"; then
    exp=$(ppio_state_get "$p" session | jq -r '.expires_at // empty' 2>/dev/null)
    exps=""
    [ -n "$exp" ] && exps=$(date -u -d "$exp" +%s 2>/dev/null)
    if [ -n "$exps" ] && [ -n "$now" ] && [ "$exps" -gt "$now" ]; then printf '%s\n' "$jar"; return 0; fi
  fi
  rm -f "$jar" "$d/session.json"
  tok=$(ppio_token "$p") || { echo skip:no-token; return 1; }
  base=$(jq -r '.base_url' "$row")
  sp=$(jq -r '.session_path // "/api/internal/e2e/session"' "$row")
  body=$(jq -cn --arg r "$role" '{role: $r}')
  resp="$d/.session.resp"
  tesc=${tok//\\/\\\\}; tesc=${tesc//\"/\\\"}
  code=$( umask 077
    printf 'header = "Authorization: Bearer %s"\n' "$tesc" \
      | curl -sS -K - -X POST -H 'content-type: application/json' --data-binary "$body" \
          -c "$jar" -o "$resp" -w '%{http_code}' --max-time "${PERF_PROBE_TIMEOUT_S:-30}" "$base$sp" 2>/dev/null )
  tok=""; tesc=""
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  if [[ $code == 2* ]] && _ppio_has_cookie "$jar"; then
    chmod 600 "$jar" 2>/dev/null
    exp=$(jq -r 'if (.expiresAt|type) == "string" then .expiresAt else empty end' "$resp" 2>/dev/null)
    exps=""
    [ -n "$exp" ] && { exps=$(date -u -d "$exp" +%s 2>/dev/null) || exps=""; }
    [ -n "$exps" ] || exps=$now
    rm -f "$resp"
    jq -cn --arg m "$(_ppio_iso "$now")" --arg e "$(_ppio_iso "$exps")" '{minted_at: $m, expires_at: $e}' \
      | ppio_state_put "$p" session || { rm -f "$jar"; echo skip:no-state-dir; return 1; }
    printf '%s\n' "$jar"
    return 0
  fi
  rm -f "$jar" "$resp"
  if [[ $code == 2* ]]; then echo "skip:$code-no-cookie"; else echo "skip:$code"; fi
  return 1
}

# _ppio_ms <seconds> — integer ms, rounded.
_ppio_ms() { awk -v s="${1:-0}" 'BEGIN { if (s !~ /^[0-9.]+$/) s = 0; printf "%d", s * 1000 + 0.5 }'; }

ppio_load() {
  local out st tt tot by loc pause
  out=$(curl -sS -o /dev/null -H 'Accept: text/html' -b "${2:-/dev/null}" \
    --max-time "${PERF_PROBE_TIMEOUT_S:-30}" \
    -w '%{http_code} %{time_starttransfer} %{time_total} %{size_download} %{redirect_url}' "$1" 2>/dev/null)
  read -r st tt tot by loc <<<"$out"
  [[ ${st:-} =~ ^[0-9]{3}$ ]] || st=000
  [[ ${by:-} =~ ^[0-9]+$ ]] || by=0
  printf '%s %s %s %s %s\n' "$st" "$(_ppio_ms "$tt")" "$(_ppio_ms "$tot")" "$by" "${loc:--}"
  pause=${PERF_PROBE_PAUSE_MS:-500}
  [[ $pause =~ ^[0-9]+$ ]] && [ "$pause" -gt 0 ] && sleep "$(awk -v m="$pause" 'BEGIN { printf "%.3f", m / 1000 }')"
  return 0
}
