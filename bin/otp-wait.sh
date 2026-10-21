#!/bin/bash
# bin/otp-wait.sh — BH-7732: wait for the one-time code a vendor emails to an
# address on otp.example.com, and print it. For web-task lanes that sign in
# to a vendor. SMS codes stay on Twilio.
#
#   bin/otp-wait.sh <address> [--timeout 120] [--since <ts>] [--interval 5]
#
# It polls the jobs route GET /api/otp?to=<address>&since=<ts> (bearer
# HARNESS_SECRET, through bin/jobs-client.sh) every --interval seconds until
# --timeout seconds have passed. The Email Worker worker/otp-inbox writes the
# rows that route reads.
#   --since  YYYY-MM-DDTHH:MM:SSZ or epoch seconds; the newest code received
#            at or after it wins. Default: now minus 60 s. Take the time
#            BEFORE you ask the vendor to send the code.
#
# Exit:
#   0   the code, alone, on stdout.
#   1   no code before the deadline (one stderr line), or the worker never
#       answered 200 (the client logs its error in logs/jobs-client.log).
#   64  bad arguments: usage on stderr, no request.
# THE CODE IS A SECRET. It goes to stdout only: never to stderr, a log file or
# an alert. The client logs a non-2xx answer only; a 200 body is never logged.
#
# Env: OTP_WAIT_NOW (epoch seconds) pins the --since default (test seam).
#      OTP_WAIT_DRYRUN_ARGS=1 prints the parsed arguments and exits 0 with no
#      request (test seam).
# Doc: docs/notes/2026-10-20-BH-7732-otp-inbox.md.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: otp-wait.sh <address> [--timeout <s>] [--since <YYYY-MM-DDTHH:MM:SSZ|epoch>] [--interval <s>]" >&2
  [ -n "${1:-}" ] && echo "otp-wait: $1" >&2
  exit 64
}

TO=""; TIMEOUT=120; INTERVAL=5; SINCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)  [ "$#" -ge 2 ] || usage "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
    --since)    [ "$#" -ge 2 ] || usage "--since needs a value"; SINCE="$2"; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || usage "--interval needs a value"; INTERVAL="$2"; shift 2 ;;
    -h|--help)  usage ;;
    -*)         usage "unknown flag $1" ;;
    *)          [ -z "$TO" ] || usage "one address only"; TO="$1"; shift ;;
  esac
done
TO=$(printf '%s' "$TO" | tr '[:upper:]' '[:lower:]')
[[ "$TO" =~ ^[^@[:space:]/]{1,64}@[a-z0-9.-]{1,190}$ ]] || usage "an email address is required"
[[ "$TIMEOUT" =~ ^[0-9]{1,5}$ ]] && [ "$TIMEOUT" -ge 1 ] || usage "--timeout must be whole seconds, 1 or more"
[[ "$INTERVAL" =~ ^[0-9]{1,4}$ ]] && [ "$INTERVAL" -ge 1 ] || usage "--interval must be whole seconds, 1 or more"
if [ -z "$SINCE" ]; then
  NOW="${OTP_WAIT_NOW:-}"; [[ "$NOW" =~ ^[0-9]+$ ]] || NOW=$(date -u +%s)
  SINCE=$(date -u -d "@$((NOW - 60))" +%Y-%m-%dT%H:%M:%SZ)
fi
[[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ || "$SINCE" =~ ^[0-9]{1,11}$ ]] \
  || usage "--since must be YYYY-MM-DDTHH:MM:SSZ or epoch seconds"

if [ "${OTP_WAIT_DRYRUN_ARGS:-}" = 1 ]; then
  echo "to=$TO timeout=$TIMEOUT interval=$INTERVAL since=$SINCE"
  exit 0
fi

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" || { echo "otp-wait: bin/jobs-client.sh did not load" >&2; exit 1; }

ENC=$(jq -rn --arg a "$TO" '$a|@uri') || { echo "otp-wait: jq is required" >&2; exit 1; }
START=$SECONDS
while :; do
  if BODY=$(_jobs_req GET "/api/otp?to=$ENC&since=$SINCE"); then
    CODE=$(jq -r '.code // empty' <<<"$BODY" 2>/dev/null)
    if [ -n "$CODE" ]; then printf '%s\n' "$CODE"; exit 0; fi
  fi
  ELAPSED=$((SECONDS - START))
  [ "$((ELAPSED + INTERVAL))" -le "$TIMEOUT" ] || break
  sleep "$INTERVAL"
done
echo "otp-wait: no code for $TO since $SINCE after ${TIMEOUT}s" >&2
exit 1
