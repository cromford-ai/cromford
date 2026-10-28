#!/bin/bash
# bin/connection-probe.sh — BH-7924: probe the tracker connection of a project
# and store the answer in the settings row `connection.<project>.status`.
# No LLM call. The hourly lane is cron/lanes/776-connection-probe.cron; the
# console's PROBE NOW reaches it through the run_script command path
# (catalog/run-script-allowlist.d/bh-7924-connection-probe.json).
#
#   connection-probe.sh <project>            probe one project, write its status
#   connection-probe.sh --box                every project bin/box-for.sh maps to
#                                            this box, one after the other
#   connection-probe.sh --dry-run <project>  print the status JSON, write nothing
#
# ONE PROBE, per project, bounded by `timeout $CONNECTION_PROBE_TIMEOUT_S`:
#   1. tracker_kind <project>. No adapter: ok false, "no tracker adapter for <p>".
#   2. credentialVars: the adapter's env var NAMES, each "present" or "missing"
#      in <env dir>/<project>.env (read in a subshell). linear LINEAR_API_KEY;
#      jira JIRA_BASE, JIRA_EMAIL, JIRA_API_TOKEN; board its *_API_BASE and
#      *_INTERNAL_API_TOKEN; github-issues none (gh has its own auth).
#   3. tracker_context <project> connection-probe. rc 1: ok false,
#      "context: <TRK_CTX_MISSING>: <first stderr line>".
#   4. One read: linear trk_linear_viewer, jira trk_jira_myself, board and
#      github-issues `tracker_list --state open` (the rows are dropped). rc 75:
#      "rate limited"; other rc: the first stderr line (the 401 text).
#   5. The error text is scrubbed: every credential VALUE read in step 2 becomes
#      <redacted>, then every token-shaped word (sk-, lin_api_, lin_oauth_,
#      ATATT, ghp_, gho_, ghs_, ghu_, ghr_, github_pat_) does too, and it is cut
#      so its JSON encoding is at most $CONNECTION_PROBE_ERROR_MAX bytes.
#   6. POST {adapter, ok, checkedAt, error, credentialVars} to
#      /api/connections/<project>/status (bin/jobs-client.sh _jobs_req, no
#      retry, no ALERTS line). The worker adds webhookRoute and webhookSecret.
# A probe that runs past the timeout is written as ok false, "timed out after Ns".
# Never a credential value: in the body, the log or stdout.
#
# EXIT: 0 every status written (ok true or false); 1 a status write failed;
# 2 usage, or a knob out of range (one log line, nothing probed).
# LOG: one line per project to logs/connection-probe.log:
#   <checkedAt> <project> adapter=<a> ok=<true|false> write=<ok|failed|dry> [error=<scrubbed>]
# ENV: CONNECTION_PROBE_NOW (epoch seconds; test seam for checkedAt).
# OFF: flags/lane-off-connection-probe. Registry: catalog/lanes.d/connection-probe.json.
set -uo pipefail
set +x
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
SELF="$(cd "$(dirname "$0")" && pwd)"
ME="$SELF/$(basename "$0")"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# The worker URL and secret, as every lane reads them (bin/secrets-apply.sh).
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

usage() {
  echo "usage: connection-probe.sh <project> | --box | --dry-run <project>" >&2
  exit 2
}

# iso_now — checkedAt: CONNECTION_PROBE_NOW (epoch seconds) or the clock, UTC.
iso_now() {
  local now="${CONNECTION_PROBE_NOW:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u +%s)
  date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ
}

# status_json <adapter> <ok> <error> <credentialVars JSON> — the POST body.
status_json() {
  jq -nc --arg a "$1" --argjson ok "$2" --arg at "$(iso_now)" --arg e "$3" --argjson cv "$4" \
    '{adapter: (if $a == "" then null else $a end), ok: $ok, checkedAt: $at,
      error: (if $e == "" then null else $e end), credentialVars: $cv}'
}

# ci <literal> — a sed ERE that matches the literal in any letter case
# (portable: BSD sed has no I flag).
ci() {
  local s="$1" o="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in [A-Za-z]) o+="[$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')]" ;; *) o+="$c" ;; esac
  done
  printf '%s' "$o"
}
TOKEN_PREFIXES="sk- lin_api_ lin_oauth_ ATATT ghp_ gho_ ghs_ ghu_ ghr_ github_pat_"

# scrub <text> <max> [value…] — step 5. One line, no control characters.
scrub() {
  local s="$1" max="$2" v alt="" t
  shift 2
  for v in "$@"; do
    [ "${#v}" -ge 4 ] && s="${s//"$v"/<redacted>}"
  done
  for t in $TOKEN_PREFIXES; do alt="${alt:+$alt|}$(ci "$t")"; done
  s=$(printf '%s' "$s" | tr '\n\t' '  ' | tr -d '\000-\037\177' \
      | sed -E "s/(^|[^A-Za-z0-9_])($alt)[^[:space:]\"',;)]*/\1<redacted>/g")
  s="${s:0:$max}"
  # The cut is in BYTES of the JSON string, not in characters: a quote or a
  # backslash doubles when encoded and a non-ASCII character is 2-4 bytes, so
  # a character cut alone can pass the worker's status bound (settings row
  # connection.status_max_bytes, at least 2048). Error max 1500 plus the other
  # status fields (under 550 bytes) always fits.
  printf '%s' "$s" | jq -Rsj --argjson m "$max" 'until((tojson | utf8bytelength) - 2 <= $m; .[:-1])'
}

# probe_json <project> — steps 1-5 in this process (the child the parent bounds
# with timeout). Prints the status JSON. The adapter name is written to
# CONNECTION_PROBE_KIND_FILE as soon as it is known, so a timed-out probe
# still names it.
probe_json() {
  local p="$1" max="${CONNECTION_PROBE_ERROR_MAX:-300}" kind="" errf ef err="" rc=0 okv=false line n miss cv='{}'
  local -a names=() vals=()
  errf=$(mktemp "${TMPDIR:-/tmp}/connection-probe.XXXXXX") || { status_json "" false "no temp file" '{}'; return 0; }
  # shellcheck source=bin/lib/tracker.sh
  . "$SELF/lib/tracker.sh" 2>/dev/null || { rm -f "$errf"; status_json "" false "bin/lib/tracker.sh did not load" '{}'; return 0; }
  ef="$HENV/$p.env"
  if tracker_kind "$p" >/dev/null 2>"$errf"; then kind=$(tracker_kind "$p" 2>/dev/null); fi
  if [ -z "$kind" ]; then
    line=$(head -1 "$errf"); rm -f "$errf"
    status_json "" false "$(scrub "no tracker adapter for $p${line:+: $line}" "$max")" '{}'
    return 0
  fi
  [ -n "${CONNECTION_PROBE_KIND_FILE:-}" ] && printf '%s' "$kind" > "$CONNECTION_PROBE_KIND_FILE" 2>/dev/null

  case "$kind" in
    linear) names=(LINEAR_API_KEY) ;;
    jira) names=(JIRA_BASE JIRA_EMAIL JIRA_API_TOKEN) ;;
    board)
      # shellcheck source=bin/lib/internal-token.sh
      . "$SELF/lib/internal-token.sh" 2>/dev/null || true
      n=""; command -v app_base_var >/dev/null 2>&1 && n=$(app_base_var "$ef" 2>/dev/null)
      names+=("${n:-API_BASE}")
      n=""; command -v internal_token_var >/dev/null 2>&1 && n=$(internal_token_var "$ef" 2>/dev/null)
      names+=("${n:-INTERNAL_API_TOKEN}") ;;
  esac
  if [ "${#names[@]}" -gt 0 ]; then
    if [ -r "$ef" ]; then
      # shellcheck source=/dev/null
      mapfile -t vals < <( for n in "${names[@]}"; do unset "$n"; done
                           set -a; . "$ef" >/dev/null 2>&1; set +a
                           for n in "${names[@]}"; do printf '%s\n' "$(printf '%s' "${!n:-}" | tr '\n' ' ')"; done )
    fi
    cv=$(for i in "${!names[@]}"; do printf '%s\t%s\n' "${names[$i]}" "$([ -n "${vals[$i]:-}" ] && echo present || echo missing)"; done \
         | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')
  fi

  export TRK_ERR="$errf"
  if ! tracker_context "$p" connection-probe 2>>"$errf"; then
    line=$(head -1 "$errf")
    miss=unknown; [ -n "${TRK_CTX_MISSING:+x}" ] && miss="$TRK_CTX_MISSING"
    err="context: $miss${line:+: $line}"
  else
    rc=0
    case "$kind" in
      linear) trk_linear_viewer >/dev/null 2>>"$errf" || rc=$? ;;
      jira) trk_jira_myself >/dev/null 2>>"$errf" || rc=$? ;;
      *) tracker_list --state open >/dev/null 2>>"$errf" || rc=$? ;;
    esac
    line=$(grep -m1 . "$errf")
    case "$rc" in
      0) okv=true ;;
      75) err="rate limited${line:+: $line}" ;;
      *) err="${line:-read failed (rc $rc)}" ;;
    esac
  fi
  rm -f "$errf"
  [ -n "$err" ] && err=$(scrub "$err" "$max" ${vals[@]+"${vals[@]}"})
  status_json "$kind" "$okv" "$err" "$cv"
}

# The child: no gate, no knobs, no write. Only this script starts it.
if [ "${1:-}" = --probe-json ]; then
  [ $# -eq 2 ] || exit 2
  probe_json "$2"
  exit 0
fi

MODE=one P=""
case "${1:-}" in
  --box) [ $# -eq 1 ] || usage; MODE=box ;;
  --dry-run) [ $# -eq 2 ] || usage; MODE=dry; P="$2" ;;
  ''|-*) usage ;;
  *) [ $# -eq 1 ] || usage; P="$1" ;;
esac
[ "$MODE" = box ] || [[ "$P" =~ ^[a-z0-9_.-]+$ ]] || usage

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit connection-probe
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply connection-probe

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/connection-probe.log"
logline() { printf '%s\n' "$1" >> "$LOG" 2>/dev/null || true; }

# Knobs: catalog/lanes.d/connection-probe.json, rows lane.connection-probe.<knob>.
# An out-of-range value is refused, never clamped.
TMO="${CONNECTION_PROBE_TIMEOUT_S:-60}"    # lane.connection-probe.connection_probe_timeout_s
EMAX="${CONNECTION_PROBE_ERROR_MAX:-300}"  # lane.connection-probe.connection_probe_error_max
knob() { # knob <name> <value> <min> <max>
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] && return 0
  logline "$(iso_now) refused: $1=$2 is not in $3..$4; nothing probed"
  echo "connection-probe: $1=$2 is not in $3..$4" >&2
  exit 2
}
knob CONNECTION_PROBE_TIMEOUT_S "$TMO" 5 300
knob CONNECTION_PROBE_ERROR_MAX "$EMAX" 40 1500

# probe_one <project> — the bounded child, then the write (or the print).
# rc 0 written, 1 the write failed.
probe_one() {
  local p="$1" body rc=0 kf kind ok err sf st wr
  kf=$(mktemp "${TMPDIR:-/tmp}/connection-probe-kind.XXXXXX") || kf=""
  body=$(CONNECTION_PROBE_ERROR_MAX="$EMAX" CONNECTION_PROBE_KIND_FILE="$kf" \
         timeout -k 5 "$TMO" bash "$ME" --probe-json "$p" 2>/dev/null) || rc=$?
  if ! jq -e 'type == "object" and (.ok | type == "boolean")' >/dev/null 2>&1 <<<"$body"; then
    kind=""; [ -n "$kf" ] && kind=$(tr -dc 'a-z-' < "$kf" 2>/dev/null)
    case "$rc" in
      124|137) err="timed out after ${TMO}s" ;;
      *) err="the probe gave no answer (rc $rc)" ;;
    esac
    body=$(status_json "$kind" false "$err" '{}')
  fi
  [ -n "$kf" ] && rm -f "$kf"
  kind=$(jq -r '.adapter // "none"' <<<"$body"); ok=$(jq -r '.ok' <<<"$body")
  err=$(jq -r '.error // ""' <<<"$body")
  if [ "$MODE" = dry ]; then
    printf '%s\n' "$body"
    return 0
  fi
  sf=$(mktemp "${TMPDIR:-/tmp}/connection-probe-st.XXXXXX") || sf=/dev/null
  wr=0
  # shellcheck source=bin/jobs-client.sh
  ( . "$SELF/jobs-client.sh" >/dev/null 2>&1 || exit 1
    JOBS_STATUS_FILE="$sf" JOBS_ALERT=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
      _jobs_req POST "/api/connections/$p/status" "$body" >/dev/null ) || wr=1
  st=$(head -c 40 "$sf" 2>/dev/null); [ "$sf" = /dev/null ] || rm -f "$sf"
  if [ "$wr" = 0 ]; then
    logline "$(jq -r .checkedAt <<<"$body") $p adapter=$kind ok=$ok write=ok${err:+ error=$err}"
    return 0
  fi
  logline "$(jq -r .checkedAt <<<"$body") $p adapter=$kind ok=$ok write=failed (${st:-no client})${err:+ error=$err}"
  return 1
}

if [ "$MODE" != box ]; then
  probe_one "$P"
  exit $?
fi

# --box: the projects this box owns. bin/box-for.sh answers `local` for the
# hub's own projects and a box name for the rest; this box is
# bin/box-name.sh's answer (BOX_NAME, state/box-name, the crontab, hostname).
# project-loop-ok: each box probes only its own projects (at most 7), one after the other, each bounded by its own timeout; pl_dispatch starts every fleet project and does not filter by owning box.
exec 9>"$H/locks/connection-probe.lock"
flock -n 9 || exit 0
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || true
# shellcheck source=bin/lib/hub-box.sh
. "$SELF/lib/hub-box.sh" 2>/dev/null || { logline "$(iso_now) refused: bin/lib/hub-box.sh did not load; nothing probed"; exit 1; }
MYBOX=$(local_box_name)
[ -n "$MYBOX" ] || MYBOX=$(hostname 2>/dev/null)
RC=0
while IFS= read -r p; do
  [[ "$p" =~ ^[a-z0-9_.-]+$ ]] || continue
  b=$("$SELF/box-for.sh" "$p" 2>/dev/null) || continue
  if [ "$b" = "$MYBOX" ] || { [ "$b" = local ] && is_hub_box "$MYBOX"; }; then
    probe_one "$p" || RC=1
  fi
done < <("$SELF/fleet-conf.sh" --projects 2>/dev/null)
exit "$RC"
