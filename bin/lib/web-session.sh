#!/bin/bash
# bin/lib/web-session.sh — the client half of the saved browser session of a
# web-task run (worker/jobs/src/routes/web-session.js). Sourced, never run.
# Contract: docs/notes/2026-11-01-BH-7597-web-session.md.
#
# Every function runs inside a lane run on a lane-run machine, with the same
# environment as wv_read (bin/lib/web-vault.sh): LANE_RUN_ID, the machine
# (WEB_VAULT_MACHINE or FLY_MACHINE_ID), WEB_VAULT_RUN_TOKEN, JOBS_URL and
# HARNESS_SECRET. The bearer and the run token go to curl in a config on a
# file descriptor (wv_curl_cfg), never on argv. A session value is never put
# on stdout, stderr, argv or into a shell variable.
#
#   wsess_save <project> <site> <file>
#     Saves <file> (a Playwright storageState, 1..<cap> bytes) as the
#     session of (project, site). It replaces the saved one. <cap> is the
#     settings row lane.web-task.session_max_bytes (read with setting_get when
#     the caller loaded it, 1024..1048576), else 262144. The worker checks the
#     same row; this check only saves a request.
#     rc 0: `web-session: saved <project> <site>` on stdout, printed only on a
#           200 whose body has stored:true.
#     rc 1: `web-session: refused <why>` (or `web-session: <http> <error>`) on
#           stderr; the worker refused it or did not answer.
#     rc 2: bad arguments, a missing, empty or too large file, or the
#           environment is not set; no request is sent.
#
#   wsess_load <project> <site>
#     rc 0: the path of the session file on stdout. The file is mode 600 in a
#           new mode 700 directory `web-session.XXXXXX` under ${TMPDIR:-/tmp}.
#           Remove it with wsess_forget when the browser has read it.
#     rc 3: `web-session: none (<no_entry|expired>)` on stderr: no session to
#           use, so the run signs in and then calls wsess_save.
#     rc 1: another refusal, an unreachable worker, or a 200 with no value.
#     rc 2: bad arguments or the environment is not set; no request is sent.
#     On rc 1 and rc 3 no file and no directory is left behind.
#
#   wsess_forget <path>
#     Removes a file wsess_load made and its directory. rc 2 and nothing
#     removed when <path> is not one: the file must be `storage-state.json`,
#     not a symlink, in a directory `web-session.XXXXXX` whose physical path
#     (pwd -P) is directly in the physical ${TMPDIR:-/tmp}. A symlinked
#     directory, a `..` that leaves TMPDIR, or a TMPDIR changed since the load
#     is refused.
#
# Needs curl and jq.

# shellcheck source=bin/lib/web-vault.sh
. "$(dirname "${BASH_SOURCE[0]}")/web-vault.sh" || return 1

WSESS_FILE=storage-state.json

# _wsess_max_bytes — prints the size cap of a session file: the settings row
# lane.web-task.session_max_bytes when setting_get is loaded and the row is an
# integer in 1024..1048576, else the fallback. An outage (rc 1), no row (rc 2)
# or a bad value uses the fallback.
_wsess_max_bytes() {
  local v=""
  if declare -F setting_get >/dev/null 2>&1; then
    v=$(setting_get lane.web-task.session_max_bytes 2>/dev/null) || v=""
    v="${v//[[:space:]]/}"
  fi
  if [[ $v =~ ^[0-9]{1,7}$ ]] && [ "$((10#$v))" -ge 1024 ] && [ "$((10#$v))" -le 1048576 ]; then
    echo "$((10#$v))"
  else
    echo 262144 # fallback of settings row lane.web-task.session_max_bytes
  fi
}

# _wsess_env — rc 2 with one stderr line when the run environment is not set.
_wsess_env() {
  local machine="${WEB_VAULT_MACHINE:-${FLY_MACHINE_ID:-}}"
  [[ ${LANE_RUN_ID:-} =~ ^[1-9][0-9]{0,15}$ ]] || { echo "web-session: no LANE_RUN_ID (it runs inside a lane run)" >&2; return 2; }
  [ -n "$machine" ] || { echo "web-session: no machine id (WEB_VAULT_MACHINE or FLY_MACHINE_ID)" >&2; return 2; }
  [ -n "${WEB_VAULT_RUN_TOKEN:-}" ] || { echo "web-session: no WEB_VAULT_RUN_TOKEN (the claim of this run gave none)" >&2; return 2; }
  [ -n "${JOBS_URL:-}" ] || { echo "web-session: not-configured: JOBS_URL" >&2; return 2; }
  [ -n "${HARNESS_SECRET:-}" ] || { echo "web-session: not-configured: HARNESS_SECRET" >&2; return 2; }
  return 0
}

# The box-side HTTP timeouts are lib knobs (catalog/lanes.d/_lib.web-session.json,
# rows lib.web-session.web_session_timeout_s and
# lib.web-session.web_session_connect_timeout_s). A caller that loaded
# bin/lib/lane-gate.sh gets the rows; else the env or the fallback.
if declare -F lib_env_apply >/dev/null; then lib_env_apply web-session || true; fi

# _wsess_post <route> <out-file> — POSTs the JSON body on stdin, writes the
# answer body to <out-file>, prints the http code. rc 1 when curl fails.
# -m: row lib.web-session.web_session_timeout_s, fallback 15.
# --connect-timeout: row lib.web-session.web_session_connect_timeout_s, fallback 5.
_wsess_post() {
  curl -sS -m "${WEB_SESSION_TIMEOUT_S:-15}" --connect-timeout "${WEB_SESSION_CONNECT_TIMEOUT_S:-5}" -o "$2" -w '%{http_code}' -K <(wv_curl_cfg run) \
    -H 'content-type: application/json' -X POST --data-binary @- "$JOBS_URL/api/web-session/$1" 2>/dev/null
}

# _wsess_fail <code> <answer-file> — the stderr line for a non-200 answer.
_wsess_fail() {
  local why
  why=$(jq -r '.why // empty' "$2" 2>/dev/null)
  if [ -n "$why" ]; then echo "web-session: refused $why" >&2; return 0; fi
  echo "web-session: $1 $(jq -r '.error // empty' "$2" 2>/dev/null)" >&2
}

wsess_save() {
  local project="${1:-}" site="${2:-}" file="${3:-}" size max dir code
  if [ "$#" -ne 3 ] || [ -z "$project" ] || [ -z "$site" ] || [ -z "$file" ]; then
    echo "web-session: usage: wsess_save <project> <site> <file>" >&2; return 2
  fi
  [ -f "$file" ] && [ -r "$file" ] || { echo "web-session: no such file: $file" >&2; return 2; }
  size=$(wc -c < "$file" | tr -d ' ')
  max=$(_wsess_max_bytes)
  { [ "$size" -ge 1 ] && [ "$size" -le "$max" ]; } 2>/dev/null \
    || { echo "web-session: the session file must be 1..$max bytes (it is $size)" >&2; return 2; }
  _wsess_env || return 2
  dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/web-session-save.XXXXXX") || { echo "web-session: no temp dir" >&2; return 1; }
  code=$(jq -nc --arg project "$project" --arg site "$site" --arg machine "${WEB_VAULT_MACHINE:-${FLY_MACHINE_ID:-}}" \
            --argjson run_id "$LANE_RUN_ID" --rawfile value "$file" \
            '{project:$project, site:$site, machine:$machine, run_id:$run_id, value:$value}' \
          | _wsess_post save "$dir/answer") \
    || { rm -rf -- "${dir:?}"; echo "web-session: worker unreachable" >&2; return 1; }
  if [ "$code" = 200 ] && jq -e '.stored == true' "$dir/answer" >/dev/null 2>&1; then
    rm -rf -- "${dir:?}"; echo "web-session: saved $project $site"; return 0
  fi
  if [ "$code" = 200 ]; then echo "web-session: the worker answered 200 with no stored:true" >&2
  else _wsess_fail "$code" "$dir/answer"; fi
  rm -rf -- "${dir:?}"; return 1
}

wsess_load() {
  local project="${1:-}" site="${2:-}" dir code why
  if [ "$#" -ne 2 ] || [ -z "$project" ] || [ -z "$site" ]; then
    echo "web-session: usage: wsess_load <project> <site>" >&2; return 2
  fi
  _wsess_env || return 2
  dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/web-session.XXXXXX") || { echo "web-session: no temp dir" >&2; return 1; }
  # The answer holds the value, so it lands in the private dir, never in a variable.
  code=$(jq -nc --arg project "$project" --arg site "$site" --arg machine "${WEB_VAULT_MACHINE:-${FLY_MACHINE_ID:-}}" \
            --argjson run_id "$LANE_RUN_ID" '{project:$project, site:$site, machine:$machine, run_id:$run_id}' \
          | (umask 077 && _wsess_post load "$dir/answer")) \
    || { rm -rf -- "${dir:?}"; echo "web-session: worker unreachable" >&2; return 1; }
  if [ "$code" = 200 ]; then
    if (umask 077 && jq -j 'if (.value | type) == "string" then .value else error("no value") end' "$dir/answer" > "$dir/$WSESS_FILE") 2>/dev/null \
       && [ -s "$dir/$WSESS_FILE" ]; then
      rm -f -- "${dir:?}/answer"; printf '%s\n' "$dir/$WSESS_FILE"; return 0
    fi
    rm -rf -- "${dir:?}"; echo "web-session: the worker answered 200 with no value" >&2; return 1
  fi
  why=$(jq -r '.why // empty' "$dir/answer" 2>/dev/null)
  case "$code:$why" in
    404:no_entry|404:expired) rm -rf -- "${dir:?}"; echo "web-session: none ($why)" >&2; return 3 ;;
  esac
  _wsess_fail "$code" "$dir/answer"
  rm -rf -- "${dir:?}"; return 1
}

wsess_forget() {
  local p="${1:-}" d pd pt
  [ "$#" -eq 1 ] && [ -f "$p" ] && [ ! -L "$p" ] || { echo "web-session: forget: not a session file: $p" >&2; return 2; }
  d=$(dirname "$p")
  case "$(basename "$d")/$(basename "$p")" in
    web-session.??????/"$WSESS_FILE") ;;
    *) echo "web-session: forget: not a session file: $p" >&2; return 2 ;;
  esac
  # The TMPDIR check: the physical dir must be directly in the physical TMPDIR.
  pd=$(cd -- "$d" 2>/dev/null && pwd -P) && pt=$(cd -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) \
    && [ -n "$pd" ] && [ -n "$pt" ] && [ "$pd" = "${pt%/}/$(basename "$d")" ] && [ ! -L "$pd/$WSESS_FILE" ] \
    || { echo "web-session: forget: not in TMPDIR: $p" >&2; return 2; }
  p="$pd/$WSESS_FILE" d="$pd"
  rm -f -- "${p:?}" && rmdir -- "${d:?}" 2>/dev/null
  [ ! -e "$p" ] || { echo "web-session: forget: could not remove $p" >&2; return 1; }
  return 0
}
