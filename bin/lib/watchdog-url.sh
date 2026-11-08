#!/bin/bash
# bin/lib/watchdog-url.sh — where the watchdog worker lives (BH-2091). Sourced,
# never executed; set -u safe; defines functions only.
#
#   watchdog_url <lane> <harness-root> [log-file]
#     prints $WATCHDOG_URL (one trailing / stripped), rc 0. Unset or empty: prints
#     nothing, makes no network call, appends ONE line per lane per UTC day to
#     [log-file] (default <harness-root>/logs/watchdog-url.log), rc 1. The log
#     itself is the dedupe; there are no flag files.
#   watchdog_url_carry <checkout>
#     prints catalog/fleet-watchdog.json's .watchdog_url, rc 0, only when the
#     checkout's origin (credentials, .git and trailing / dropped, lowercased)
#     ends in /<repo> or :<repo>. Anything else rc 1: a fork must never send its
#     shared secret to this fleet's worker.
#   watchdog_url_seed <checkout> <global.env> <harness-root>
#     appends WATCHDOG_URL=<carry> to global.env when it exists, has no non-empty
#     WATCHDOG_URL= line and the carry applies. Called by bin/harness-sync.sh.
#     Success: one update-runners.log line. Failed write: one ALERTS line, rc 1.

watchdog_url() {
  local lane="$1" root="$2" v="${WATCHDOG_URL:-}"
  v="${v%/}"
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  local log="${3:-$root/logs/watchdog-url.log}" day
  day=$(date -u +%F)
  if ! grep "^$day" "$log" 2>/dev/null | grep -F "[$lane] WATCHDOG_URL not set" >/dev/null; then
    { mkdir -p "$(dirname "$log")" \
        && printf '%s [%s] WATCHDOG_URL not set, watchdog call skipped (set it in env/global.env)\n' \
             "$(date -u +%FT%TZ)" "$lane" >> "$log"; } 2>/dev/null
  fi
  return 1
}

watchdog_url_carry() {
  local ck="$1" f repo url o
  f="$ck/catalog/fleet-watchdog.json"
  [ -f "$f" ] || return 1
  repo=$(jq -r '.repo // empty' "$f" 2>/dev/null)
  url=$(jq -r '.watchdog_url // empty' "$f" 2>/dev/null)
  [ -n "$repo" ] && [ -n "$url" ] || return 1
  o=$(git -C "$ck" remote get-url origin 2>/dev/null) || return 1
  [ -n "$o" ] || return 1
  o=$(printf '%s' "$o" | sed -E 's#://[^@/]*@#://#' | tr '[:upper:]' '[:lower:]')
  o="${o%/}"; o="${o%.git}"
  repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
  case "$o" in
    */"$repo"|*:"$repo") printf '%s\n' "$url"; return 0 ;;
  esac
  return 1
}

watchdog_url_seed() {
  local ck="$1" genv="$2" root="$3" v rc
  [ -e "$genv" ] || return 0
  grep -q '^WATCHDOG_URL=.' "$genv" 2>/dev/null && return 0
  v=$(watchdog_url_carry "$ck") || return 0
  # global.env is +i on an armed box: release -> append -> rearm under the
  # re-arm lane's lock (the bin/bootstrap-machine.sh pattern). The subshell owns
  # its fd 8, so the caller's fd 8 (harness-sync's own lock) is never touched.
  (
    flock -w 60 8 || exit 3
    [ -x "$root/bin/harden-state.sh" ] && "$root/bin/harden-state.sh" --release "$genv" >/dev/null 2>&1
    printf 'WATCHDOG_URL=%s\n' "$v" 2>/dev/null >> "$genv"; rc=$?
    [ -x "$root/bin/harden-state.sh" ] && "$root/bin/harden-state.sh" --rearm "$genv" >/dev/null 2>&1
    exit $rc
  ) 8>"$root/locks/harden-state.lock" 2>/dev/null
  rc=$?
  if [ "$rc" = 0 ]; then
    printf '%s harness sync: WATCHDOG_URL seeded into env/global.env from catalog/fleet-watchdog.json (BH-2091)\n' \
      "$(date -u '+%Y-%m-%d %H:%M:%SZ')" >> "$root/logs/update-runners.log" 2>/dev/null
    return 0
  fi
  local msg="harness sync: could not append WATCHDOG_URL to $genv (rc $rc) — watchdog-ping, progress-push, fleet-status-push, tickets-snapshot-push, cost-rollup and the other WATCHDOG_URL readers go silent once their callers drop the default (BH-2091). Fix: add the WATCHDOG_URL= line from catalog/fleet-watchdog.json to $genv by hand (bin/harden-state.sh --release it first on an armed box)"
  # Through bin/alert-line.sh only (BH-2314): the root's copy, else the one
  # beside this lib. With neither there is no sanctioned writer, so the line
  # goes to update-runners.log instead of a raw ALERTS.log append.
  local al="$root/bin/alert-line.sh"
  [ -x "$al" ] || al="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/alert-line.sh"
  if [ -x "$al" ]; then
    HARNESS="$root" "$al" "$msg"
  else
    printf '%s %s (no bin/alert-line.sh to page with)\n' "$(date -u '+%F %TZ')" "$msg" >> "$root/logs/update-runners.log" 2>/dev/null
  fi
  return 1
}

# A dedicated credential; never reuse the jobs-plane bearer. Keep the header
# out of process arguments, including callers that stream JSON on stdin.
watchdog_secret() {
  local secret="" file="${WATCHDOG_SECRET_FILE:-${HENV:-${HARNESS:-/root/harness}/env}/.watchdog-secret}"
  [ ! -r "$file" ] || secret=$(tr -d '\r\n' < "$file")
  [ -n "$secret" ] || secret="${WATCHDOG_SECRET:-}"
  [ -n "$secret" ] || return 1
  case "$secret" in *'"'*|*\\*|*$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s' "$secret"
}
watchdog_curl() {
  local secret
  secret=$(watchdog_secret) || return 1
  curl --config /dev/fd/3 "$@" 3<<<"header = \"Authorization: Bearer $secret\""
}
