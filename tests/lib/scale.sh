# shellcheck shell=bash
# tests/lib/scale.sh — load helpers for the scale envelope suites (BH-7906).
# Sourced, never executed. No side effect at source time.
#
#   scale_wrap <cmd> [args...]
#     Runs the command and records the load it put on a shared resource in
#     ${SCALE_STATE:?}: `calls=N`, `in_flight=N`, `max_in_flight=N`, one per
#     line. The count steps run under flock on "$SCALE_STATE.lock", so N
#     parallel callers (xargs -P, background jobs) count correctly. Returns
#     the command's rc; a failing command still counts and still leaves
#     in_flight at 0. No clock and no $RANDOM.
#
#   scale_fake_gate <github|jobs|fly> <state-dir>
#     The hook the shared vendor fakes call, only when one of the two knobs
#     below is set. Returns 0 when it answered (it printed the vendor's
#     rate-limit shape), 1 when the fake must answer as before.
#       SCALE_FAKE_LATENCY_MS=<n>        every call sleeps n ms first.
#       SCALE_FAKE_RATE_LIMIT_EVERY=<n>  call n, 2n, 3n... of this vendor in
#                                        this state dir answers rate-limited.
#     A knob that is set but is not a positive integer is ignored, with one
#     `scale-fake: ignored <knob>=<value>` line on stderr. It is never clamped.
#     The per-vendor counter is <state-dir>/scale-fake.<vendor>.calls.
#
# THE SHAPES are the ones the production readers see (D4):
#   github  HTTP/2 403 with x-ratelimit-remaining: 0, in the gh-rest-stub
#           envelope; bin/lib/gh-rest.sh _gh_rest_sniff reads the body as
#           GH_REST_REASON=rate-limit and gh_rest answers rc 75.
#   jobs    status 503 with "D1 DB is overloaded" in the body, in the fake
#           curl's body-then-status order; worker/jobs/src/lib/http.js
#           d1OverloadGuarded emits it and bin/lib/jobs/req.sh _jobs_req
#           retries it as an overload.
#   fly     `Error: ... 429 Too Many Requests` on stderr and exit 1. No fly
#           reader classifies a 429 today; bin/fly-pool.sh reads any non-zero
#           rc of flyctl as a failed call. The text is assumed, not captured.

# _scale_sh is `command -p`: tests/lib/pool-reap-fixture.sh puts no-op sleep
# and flock stubs first on PATH, and a fake latency must still be real.
_scale_lock() { # _scale_lock <lockfile> <cmd...> — run cmd under an exclusive lock
  local lf="$1"; shift
  if command -p flock -V >/dev/null 2>&1; then
    ( command -p flock -x 9 || exit 1; "$@" ) 9>"$lf"
  else
    "$@"
  fi
}

_scale_state_get() { # _scale_state_get <file> <key> — the number, 0 when absent
  local v
  v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1)
  printf '%s' "${v:-0}"
}

_scale_enter() {
  local f="$SCALE_STATE" c i m
  c=$(_scale_state_get "$f" calls); i=$(_scale_state_get "$f" in_flight); m=$(_scale_state_get "$f" max_in_flight)
  c=$((c+1)); i=$((i+1)); [ "$i" -gt "$m" ] && m=$i
  printf 'calls=%s\nin_flight=%s\nmax_in_flight=%s\n' "$c" "$i" "$m" > "$f.tmp" && mv "$f.tmp" "$f"
}

_scale_leave() {
  local f="$SCALE_STATE" c i m
  c=$(_scale_state_get "$f" calls); i=$(_scale_state_get "$f" in_flight); m=$(_scale_state_get "$f" max_in_flight)
  i=$((i-1))
  printf 'calls=%s\nin_flight=%s\nmax_in_flight=%s\n' "$c" "$i" "$m" > "$f.tmp" && mv "$f.tmp" "$f"
}

scale_wrap() {
  local st="${SCALE_STATE:?scale_wrap: SCALE_STATE (the state file) must be set}" rc=0
  [ "$#" -gt 0 ] || { echo "scale_wrap: no command" >&2; return 2; }
  _scale_lock "$st.lock" _scale_enter || return 1
  "$@" || rc=$?
  _scale_lock "$st.lock" _scale_leave || return 1
  return "$rc"
}

# _scale_knob <name> — prints the knob when it is a positive integer.
_scale_knob() {
  local v="${!1:-}"
  [ -n "$v" ] || return 1
  if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$v"; return 0; fi
  echo "scale-fake: ignored $1=$v" >&2
  return 1
}

_scale_bump() { # _scale_bump <counter file> — adds 1, prints the new count
  local n
  n=$(cat "$1" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n+1)); printf '%s\n' "$n" > "$1"; printf '%s' "$n"
}

scale_fake_gate() {
  local vendor="${1:?scale_fake_gate: vendor}" sd="${2:?scale_fake_gate: state dir}" ms every n
  case "$vendor" in github|jobs|fly) ;; *) echo "scale_fake_gate: unknown vendor $vendor" >&2; return 1 ;; esac
  if ms=$(_scale_knob SCALE_FAKE_LATENCY_MS); then
    command -p sleep "$(printf '%d.%03d' $((ms/1000)) $((ms%1000)))"
  fi
  every=$(_scale_knob SCALE_FAKE_RATE_LIMIT_EVERY) || return 1
  n=$(_scale_lock "$sd/scale-fake.$vendor.calls.lock" _scale_bump "$sd/scale-fake.$vendor.calls") || return 1
  [ $((n % every)) -eq 0 ] || return 1
  case "$vendor" in
    github)
      printf 'HTTP/2 403\r\nserver: x\r\nx-ratelimit-limit: 6600\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 2000000000\r\n\r\n%s' \
        '{"message":"API rate limit exceeded (scale fake)"}' ;;
    jobs)
      printf '%s\n%s' '{"error":"scale-fake unavailable","detail":"D1_ERROR: D1 DB is overloaded. Requests queued for too long.","retryable":true,"d1_attempts":5}' 503 ;;
    fly)
      echo "Error: request failed with status 429 Too Many Requests (rate limited)" >&2 ;;
  esac
  return 0
}
