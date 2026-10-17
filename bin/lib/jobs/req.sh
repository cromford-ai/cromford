#!/bin/bash
# shellcheck shell=bash
# alert-writer: by-design — its degraded-mode lines report a transport outage; the helper notes rows through this transport
# bin/lib/jobs/req.sh — BH-1194: the transport — where the worker is, who we say we are, the timeouts and the one transport retry, the degraded-mode log/alert, and _jobs_req / _jobs_req_file, the ONE place the fail-open contract lives. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# UNSET and EMPTY are different answers (BH-1957). An EMPTY JOBS_URL — in the
# environment, or a `JOBS_URL=` line in global.env, which the shipped template
# (env-templates/lanes/015-coordination-db.env.example) writes — means "no
# coordination DB here": every request fails open without a network call (see
# _jobs_not_configured). A fork must never send its HARNESS_SECRET to our worker
# because it left this blank. UNSET still falls back to the fleet's worker,
# because pool machines carry no JOBS_URL today (fly-envbundle only passes a
# line the box's global.env has); #2063 drops the fallback once every box's
# global.env and bundle carry JOBS_URL. Since BH-4080 the fallback is built
# from HARNESS_WORKERS_SUBDOMAIN (bin/lib/deployment.sh, sourced soft because
# jobs-client.sh is copied into test dirs with only bin/lib/jobs/ beside it):
# with no subdomain resolvable, UNSET becomes EMPTY, the "no worker" answer.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-${BASH_SOURCE[0]%/*}/../deployment.sh}" 2>/dev/null || :
JOBS_URL="${JOBS_URL-${HARNESS_WORKERS_SUBDOMAIN:+https://harness-jobs.$HARNESS_WORKERS_SUBDOMAIN.workers.dev}}"
# The box column is IDENTITY, not decoration: the worker slugs it into the
# paused-box-<box> flag, counts scope=box concurrency rules by it, and compares
# it on the claim-resume path. `hostname` cannot carry that, because every Orgo
# box answers the image default "orgo-desktop" — five machines sharing one name
# means one pause flag pauses all of them and one box-scoped build slot is
# shared fleet-wide. bin/box-name.sh resolves the real fleet name and leaves it
# in state/box-name; this file only READS that, and never depends on the script
# existing, because jobs-client.sh is copied standalone into test dirs and must
# stay self-contained. Falls back to the hostname exactly as before, so the hub
# and an unprovisioned box are byte-identical to today.
_jobs_box_name() {
  local n=""
  [ -n "${BOX_NAME:-}" ] && n=$(printf %s "$BOX_NAME" | tr -dc 'A-Za-z0-9._-')
  # Readability tested BEFORE the redirect: `2>/dev/null` on tr does not
  # suppress the SHELL's error for a failed `<`, which would print on every
  # single source of this file on a box with no state/box-name.
  [ -n "$n" ] || [ -z "${JOBS_HARNESS:-}" ] || [ ! -r "$JOBS_HARNESS/state/box-name" ] \
    || n=$(tr -dc 'A-Za-z0-9._-' < "$JOBS_HARNESS/state/box-name" 2>/dev/null)
  [ -n "$n" ] || n=$(hostname 2>/dev/null)
  printf %s "$n"
}
JOBS_BOX="${JOBS_BOX:-$(_jobs_box_name)}"
# Short and never retried: this is a side channel, not the work.
JOBS_TIMEOUT="${JOBS_TIMEOUT:-8}"
# One retry on a TRANSPORT failure only (timeout, connect, reset) — never on an
# HTTP answer. The worker answers in ~100ms from every box, yet each box logged
# several `transport rc=28` a day (2026-09-10), and each one silently ran that
# tick with the double-build guard off. A second attempt after a short pause
# costs nothing when the worker is really down (still fail-open) and turns a
# 5s edge blip into a normal call. JOBS_RETRIES=0 disables it.
JOBS_RETRIES="${JOBS_RETRIES:-1}"
JOBS_RETRY_SLEEP="${JOBS_RETRY_SLEEP:-1}"
# One retry on a D1 OVERLOAD answer (BH-5781): a 503 whose payload says
# "overloaded" ("D1_ERROR: D1 DB is overloaded. Requests queued for too long.").
# D1 refuses the statement before it runs, and the hub logged ~230 an hour on
# 2026-10-09, each a lost verdict or a skipped tick. It is its own class, apart
# from JOBS_RETRIES: any other 503, a 500 or a 4xx is still never retried. The
# wait is JOBS_OVERLOAD_SLEEP plus 0..JOBS_OVERLOAD_JITTER_S seconds, so a burst
# of boxes does not come back in step. JOBS_OVERLOAD_RETRIES=0 disables it.
JOBS_OVERLOAD_RETRIES="${JOBS_OVERLOAD_RETRIES:-1}"
JOBS_OVERLOAD_SLEEP="${JOBS_OVERLOAD_SLEEP:-2}"
JOBS_OVERLOAD_JITTER_S="${JOBS_OVERLOAD_JITTER_S:-2}"

# _jobs_root_writable — rc 0 when there is a root to log under (BH-2649): a
# non-empty JOBS_HARNESS whose logs/ exists or can be made, and is writable.
# Anything else (no root, or a caller that cannot write the box's logs, like a
# suite run as nobody) writes nothing and says nothing: this is the degraded
# channel, and it must not become a stderr line of its own.
_jobs_root_writable() {
  [ -n "${JOBS_HARNESS:-}" ] || return 1
  mkdir -p "$JOBS_HARNESS/logs" 2>/dev/null || return 1
  [ -w "$JOBS_HARNESS/logs" ]
}

_jobs_log() { # _jobs_log <message>
  _jobs_root_writable || return 0
  local ts; ts=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  { echo "$ts [jobs-client] $*" >> "$JOBS_HARNESS/logs/jobs-client.log"; } 2>/dev/null
  # A day-long silent outage is indistinguishable from "nothing to coordinate",
  # so it gets ONE actionable alert a day — not one per call, which would drown
  # the channel the moment the worker blinks.
  #
  # JOBS_ALERT=0 keeps the log line above and skips ONLY the ALERTS line, for a
  # caller that reads this API as OPTIONAL EVIDENCE and already has a documented
  # answer for "no answer" (bin/doorbell-coverage-check.sh's ring pre-check:
  # unknown, carry on exactly as before). Such a caller alerting would put a
  # second lane's line into a detector whose whole contract is one actionable
  # line per repo per day — and the outage is already alerted by the lanes that
  # do depend on it, every minute.
  [ "${JOBS_ALERT:-1}" = 0 ] && return 0
  local flag; flag="$JOBS_HARNESS/flags/alerted-jobs-client-$(date -u +%Y%m%d)"
  [ -f "$flag" ] || {
    mkdir -p "$JOBS_HARNESS/flags" 2>/dev/null && touch "$flag" 2>/dev/null
    { echo "$ts [jobs-client] harness-jobs unreachable ($*) — coordination is degraded to per-box files (double-build guard OFF, lane caps from catalog file). Check worker/jobs deploy + HARNESS_SECRET." \
      >> "$JOBS_HARNESS/logs/ALERTS.log"; } 2>/dev/null
  }
  return 0
}

# jobs_configured — rc 0 when this box HAS a coordination DB to ask, rc 1 when
#   it runs without one on purpose. It lets a caller tell "the worker did not
#   answer" (a DB outage) from "there is no worker here" (BH-2315: review-prs
#   holds paid reviews on the first and keeps today's behaviour on the second).
#   It judges on JOBS_URL ALONE (BH-2457): an EMPTY JOBS_URL is the only "no
#   worker here on purpose" answer (BH-1957, above). An unset one has already
#   defaulted to the fleet worker, so a box that lost HARNESS_SECRET is a
#   configured box whose worker cannot be read: it holds, it does not pay.
jobs_configured() { [ -n "${JOBS_URL:-}" ]; }

# JOBS_URL is empty: coordination is switched off on purpose, not broken. ONE
# line a UTC day in the client's own log so the state is findable, and NO
# ALERTS line — a fork that runs without the DB must not be paged every day for
# its own choice. The flag is set before the line, as in _jobs_log.
_jobs_not_configured() {
  _jobs_root_writable || return 0
  local flag; flag="$JOBS_HARNESS/flags/alerted-jobs-not-configured-$(date -u +%Y%m%d)"
  [ -f "$flag" ] && return 0
  mkdir -p "$JOBS_HARNESS/flags" "$JOBS_HARNESS/logs" 2>/dev/null && touch "$flag" 2>/dev/null
  { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [jobs-client] coordination DB not configured (JOBS_URL is empty) — jobs-client calls fail open to per-box files; set JOBS_URL in env/global.env to your harness-jobs worker" \
    >> "$JOBS_HARNESS/logs/jobs-client.log"; } 2>/dev/null
  return 0
}

# Every request goes through here so the fail-open contract lives in ONE place.
# Prints the body on a 2xx, prints nothing otherwise, and hands the HTTP status
# back through JOBS_HTTP for the few callers that must tell 409 from an outage.
#
# JOBS_BODY is the answer's PAYLOAD, and it exists because of BH-1000: with
# hub_lease unapplied the worker answered 503 `{"error":"hub_lease schema not
# applied"}` and bin/hub-lease.sh still logged "worker unreachable", because a
# non-2xx payload was printed nowhere and every caller saw only an rc. Both are
# cleared at the top of each request, so an empty JOBS_HTTP means "never
# answered" and can never be last call's status.
#
# JOBS_STATUS_FILE (BH-5463): a caller that reads through a `$( )` loses
# JOBS_HTTP. When it sets this path, the request overwrites the file with one
# word: http=<code>, curl_rc=<n>, no-secret or no-url. Unset = no write.
#
# JOBS_BODY_FILE (BH-6433): the same opt-in for the payload. When set, the
# request empties the file first and, on an answer, writes the first 200 bytes
# of the payload to it (the cut _jobs_log uses). JOBS_STATUS_FILE stays one
# word: bin/model-prices-sync.sh reads it with head -c 64.
JOBS_HTTP=""
JOBS_BODY=""
# _jobs_curl <method> <path> <body> <body-arg> — one HTTP attempt; prints the
# payload, a newline and the status code. Both _jobs_req retry loops call it.
_jobs_curl() {
  local auth="authorization: Bearer $HARNESS_SECRET" hf="" rc
  # BH-7188: a secret read off the hub (keychain, file) never goes on argv: curl
  # reads the header from a 0600 file. No file, no request (never fall back to argv).
  if [ -n "${JOBS_AUTH_VIA_FILE:-}" ]; then
    hf=$(umask 077; mktemp "${TMPDIR:-/tmp}/jobs-auth.XXXXXX" 2>/dev/null) || return 1
    printf 'authorization: Bearer %s\n' "$HARNESS_SECRET" > "$hf" || { rm -f "$hf"; return 1; }
    auth="@$hf"
  fi
  if [ -n "$3" ]; then
    curl -sS -m "$JOBS_TIMEOUT" --connect-timeout 3 -w $'\n%{http_code}' \
      -X "$1" -H "$auth" \
      -H "content-type: application/json" --data-binary "$4" "$JOBS_URL$2" 2>/dev/null
  else
    curl -sS -m "$JOBS_TIMEOUT" --connect-timeout 3 -w $'\n%{http_code}' \
      -X "$1" -H "$auth" "$JOBS_URL$2" 2>/dev/null
  fi
  rc=$?
  [ -z "$hf" ] || rm -f "$hf"
  return "$rc"
}
_jobs_req() { # _jobs_req <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}" out rc
  JOBS_HTTP=""; JOBS_BODY=""
  { [ -z "${JOBS_BODY_FILE:-}" ] || : > "$JOBS_BODY_FILE"; } 2>/dev/null
  [ -n "${HARNESS_SECRET:-}" ] || { { [ -z "${JOBS_STATUS_FILE:-}" ] || echo no-secret > "$JOBS_STATUS_FILE"; } 2>/dev/null; _jobs_log "HARNESS_SECRET unset"; return 1; }
  [ -n "${JOBS_URL:-}" ] || { { [ -z "${JOBS_STATUS_FILE:-}" ] || echo no-url > "$JOBS_STATUS_FILE"; } 2>/dev/null; _jobs_not_configured; return 1; }
  local attempt=0 ovl=0 bodyf="" bodyarg="$body"
  # BH-6462: one call-trace line per request (retries included), inside a
  # bounded conductor worker only (bin/lib/call-trace.sh). Method and path.
  local ctr=0 ct0=""
  if [ -n "${HARNESS_CALL_TRACE_FILE:-}" ] && command -v call_trace_put >/dev/null 2>&1; then ctr=1; call_trace_t0 ct0; fi
  # A LARGE body rides in a file. Linux caps one argv string at 128KB
  # (MAX_ARG_STRLEN), and a batch endpoint's payload — a full pr-costs sweep is
  # hundreds of rows — can pass it; bash reports that E2BIG as rc=126, which the
  # loop below retried, identically, and logged as "transport rc=126" as if the
  # worker were down (2026-09-14, hourly on the hub's cost-rollup). Small bodies
  # stay on argv, exactly as every caller and every test stub has always seen.
  if [ "${#body}" -gt "${JOBS_BODY_ARGV_MAX:-65536}" ]; then
    bodyf=$(mktemp "${TMPDIR:-/tmp}/jobs-body.XXXXXX" 2>/dev/null) || { _jobs_log "$method $path mktemp failed"; return 1; }
    printf '%s' "$body" > "$bodyf"; bodyarg="@$bodyf"
  fi
  while :; do
    attempt=0
    while :; do
      out=$(_jobs_curl "$method" "$path" "$body" "$bodyarg")
      rc=$?
      [ "$rc" -ne 0 ] && [ "$attempt" -lt "${JOBS_RETRIES:-1}" ] || break
      attempt=$((attempt+1)); sleep "${JOBS_RETRY_SLEEP:-1}"
    done
    # The overload retry: 503 AND "overloaded" in the payload, nothing broader.
    [ "$rc" -eq 0 ] && [ "${out##*$'\n'}" = 503 ] && [ "$ovl" -lt "${JOBS_OVERLOAD_RETRIES:-1}" ] \
      && grep -qi overloaded <<<"${out%$'\n'*}" || break
    ovl=$((ovl+1))
    sleep $(( ${JOBS_OVERLOAD_SLEEP:-2} + RANDOM % (${JOBS_OVERLOAD_JITTER_S:-2} + 1) ))
  done
  local retried=""; [ "$ovl" -gt 0 ] && retried=" after overload retry"
  [ -n "$bodyf" ] && rm -f "$bodyf"
  if [ "$rc" -ne 0 ]; then [ "$ctr" = 1 ] && call_trace_put jobs "$method $path" "curl_rc=$rc" "$ct0"; { [ -z "${JOBS_STATUS_FILE:-}" ] || echo "curl_rc=$rc" > "$JOBS_STATUS_FILE"; } 2>/dev/null; _jobs_log "$method $path transport rc=$rc after $((attempt+1)) attempt(s)$retried"; return 1; fi
  JOBS_HTTP="${out##*$'\n'}"
  { [ -z "${JOBS_STATUS_FILE:-}" ] || echo "http=$JOBS_HTTP" > "$JOBS_STATUS_FILE"; } 2>/dev/null
  local payload="${out%$'\n'*}"
  JOBS_BODY="$payload"
  { [ -z "${JOBS_BODY_FILE:-}" ] || head -c 200 < <(printf '%s' "$payload") > "$JOBS_BODY_FILE"; } 2>/dev/null
  [ "$ctr" = 1 ] && call_trace_put jobs "$method $path" "$JOBS_HTTP" "$ct0"
  case "$JOBS_HTTP" in
    2*) printf '%s' "$payload"; return 0 ;;
    409) printf '%s' "$payload"; return 9 ;;
    # 404 is a real answer (ledger miss, unknown job), not an outage — do not
    # burn the daily ALERTS flag on "this PR is not in the table yet".
    404) return 2 ;;
    *)  _jobs_log "$method $path http=$JOBS_HTTP$retried $(printf '%s' "$payload" | head -c 200)"; return 1 ;;
  esac
}

# _jobs_req_file <method> <path> <body-file>
#   The same request, with the JSON body read from a FILE instead of from an
#   argument. Not an optimisation — a correctness requirement for transcripts:
#   a ~150KB body handed to curl as an argv element blows MAX_ARG_STRLEN
#   (128KB) and execve fails E2BIG before curl runs, which would look exactly
#   like an unreachable worker and would be wrong for a completely different
#   reason. Everything else about the contract is identical, fail-open included.
_jobs_req_file() {
  local method="$1" path="$2" file="$3" out rc
  JOBS_HTTP=""; JOBS_BODY=""
  [ -n "${HARNESS_SECRET:-}" ] || { _jobs_log "HARNESS_SECRET unset"; return 1; }
  [ -n "${JOBS_URL:-}" ] || { _jobs_not_configured; return 1; }
  [ -s "$file" ] || { _jobs_log "$method $path empty body file"; return 1; }
  local auth="authorization: Bearer $HARNESS_SECRET" hf=""
  if [ -n "${JOBS_AUTH_VIA_FILE:-}" ]; then # BH-7188: see _jobs_curl
    hf=$(umask 077; mktemp "${TMPDIR:-/tmp}/jobs-auth.XXXXXX" 2>/dev/null) || { _jobs_log "$method $path mktemp failed"; return 1; }
    printf 'authorization: Bearer %s\n' "$HARNESS_SECRET" > "$hf" || { rm -f "$hf"; return 1; }
    auth="@$hf"
  fi
  out=$(curl -sS -m "$JOBS_TIMEOUT" --connect-timeout 3 -w $'\n%{http_code}' \
    -X "$method" -H "$auth" \
    -H "content-type: application/json" --data-binary "@$file" "$JOBS_URL$path" 2>/dev/null)
  rc=$?
  [ -z "$hf" ] || rm -f "$hf"
  if [ "$rc" -ne 0 ]; then _jobs_log "$method $path transport rc=$rc"; return 1; fi
  JOBS_HTTP="${out##*$'\n'}"
  local payload="${out%$'\n'*}"
  JOBS_BODY="$payload"
  case "$JOBS_HTTP" in
    2*) printf '%s' "$payload"; return 0 ;;
    409) printf '%s' "$payload"; return 9 ;;
    404) return 2 ;;
    *)  _jobs_log "$method $path http=$JOBS_HTTP $(printf '%s' "$payload" | head -c 200)"; return 1 ;;
  esac
}

