#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/tracker-test.sh — BH-7936: the hub probe behind the
# onboarding tracker sheets' "Test and connect". Sourced by common.sh's hp_run.
#
# hp_probe_tracker_test <linear|jira|board> <32-hex nonce>
#   1. onb_take <nonce>: the one-time KV row the console's
#      POST /api/onboarding/tracker-test wrote (worker/jobs/src/routes/
#      onboarding-tracker.js). The worker deletes it as it answers, so the
#      credential is gone before any vendor call. 404 →
#      `FAIL credential expired, test again`.
#   2. onb_tracker_check: one read and one dry write through bin/lib/tracker.sh
#      with the taken fields as the adapter context, in a subshell.
#   PASS (rc 0, HP_HTTP_STATUS=200): `ok list=<n> dry-write=ok`, or
#   `ok list=0 dry-write=skipped` and a line saying why when the list is empty.
#   FAIL (rc 1, HP_HTTP_STATUS=000): `FAIL <what>` and the adapter's stderr,
#   first 20 lines.
#   Every output line is scrubbed: each secret field value (api_key,
#   api_token, token) and the email, of 4 characters or more, is replaced by
#   `[redacted]`. The output is what the hub-probe ledger stores and what the
#   sheet shows. The taken row lives only in a mode-600 temp file, removed
#   before the function returns.
#
# onb_take <nonce> — POST /api/onboarding/tracker-secret/take. The row JSON
#   {kind, project, fields} on stdout, rc 0; rc 2 when the worker answered 404
#   (expired or already taken); rc 1 for anything else.
# onb_tracker_check <kind> <row file> — the read + dry write, as above, without
#   the take or the scrub. The onboarding `tracker` station (wave 1's
#   bin/lib/onboard-stations.sh) is meant to call this same function.
#
# TEMPORARY (BH-7936 decision 3): the KV row stands in for the secret envelope
# of onboarding wave 4, which replaces onb_take.
command -v _jobs_req >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../../jobs-client.sh" >/dev/null 2>&1

ONB_SECRET_FIELDS="api_key api_token token email"

onb_take() {
  local n="${1:-}" out rc=0
  [[ "$n" =~ ^[0-9a-f]{32}$ ]] || return 1
  command -v _jobs_req >/dev/null 2>&1 || return 1
  out=$(_jobs_req POST /api/onboarding/tracker-secret/take "{\"nonce\":\"$n\"}") || rc=$?
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 0 ] || return 1
  printf '%s' "$out" | jq -e 'type == "object" and (.kind | type == "string") and (.fields | type == "object")' >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

_onb_field() { jq -r --arg k "$1" '.fields[$k] // empty | strings' "$2" 2>/dev/null; }
_onb_errtail() { [ -s "$1" ] && head -n 20 "$1"; return 0; }

onb_tracker_check() {
  local kind="${1:-}" f="${2:-}" lib err body rc=0
  [ -r "$f" ] || { echo "FAIL no credential row"; return 1; }
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || { echo "FAIL no bin/lib"; return 1; }
  err=$(mktemp "${TMPDIR:-/tmp}/onb-trk-err.XXXXXX") || { echo "FAIL no temp file"; return 1; }
  body=$(mktemp "${TMPDIR:-/tmp}/onb-trk-body.XXXXXX") || { rm -f "$err"; echo "FAIL no temp file"; return 1; }
  (
    TRK_LOG=""; TRK_REQ_FILE=""; TRK_ERR="$err"; TRK_DRY=0
    # shellcheck source=bin/lib/tracker.sh
    . "$lib/tracker.sh" || { echo "FAIL tracker library missing"; exit 1; }
    tracker_load "$kind" || { echo "FAIL no $kind adapter"; exit 1; }
    case "$kind" in
      linear)
        TRK_LINEAR_TOKEN=$(_onb_field api_key "$f"); TRK_LINEAR_TOKEN_VAR=LINEAR_API_KEY
        TRK_LINEAR_TEAM=$(_onb_field team "$f"); TRK_LINEAR_LABEL=$(_onb_field label "$f") ;;
      jira)
        r=0
        trk_jira_context_fields "$(_onb_field site "$f")" "$(_onb_field email "$f")" "$(_onb_field api_token "$f")" \
          "$(_onb_field project_key "$f")" "$(_onb_field status_map "$f")" 2>>"$err" || r=$?
        if [ "$r" != 0 ]; then echo "FAIL jira context (rc $r)"; _onb_errtail "$err"; exit 1; fi ;;
      board)
        TRK_BOARD_BASE=$(_onb_field api_base "$f"); TRK_BOARD_TOKEN=$(_onb_field token "$f"); TRK_BOARD_TOKEN_VAR=BOARD_TOKEN ;;
      *) echo "FAIL $kind is not linear, jira or board"; exit 1 ;;
    esac
    r=0; list=$(tracker_list 2>>"$err") || r=$?
    if [ "$r" != 0 ] || ! n=$(printf '%s' "$list" | jq -er 'if type == "array" then length else error end' 2>/dev/null); then
      echo "FAIL tracker list failed (rc $r)"
      [ "$r" = 75 ] && echo "the tracker was rate-limited or did not answer; test again in a few minutes"
      _onb_errtail "$err"; exit 1
    fi
    first=$(printf '%s' "$list" | jq -r '.[0].id // empty')
    if [ -z "$first" ]; then
      echo "ok list=0 dry-write=skipped"
      echo "no open ticket with the build label; dry write skipped"
      exit 0
    fi
    printf 'Onboarding connection test (dry run, never sent).\n' > "$body"
    r=0; dry=$(TRK_DRY=1 tracker_comment "$first" "$body" 2>>"$err") || r=$?
    if [ "$r" != 0 ] || ! grep -q '^DRYRUN ' <<<"$dry"; then
      echo "FAIL dry write on $first failed (rc $r)"; _onb_errtail "$err"; exit 1
    fi
    echo "ok list=$n dry-write=ok"
  ) || rc=$?
  rm -f "$err" "$body"
  return "$rc"
}

# _onb_probe <kind> <nonce> <row file> — the take and the check; unscrubbed.
_onb_probe() {
  local kind="$1" nonce="$2" f="$3" rc=0 got
  onb_take "$nonce" > "$f" || rc=$?
  case "$rc" in
    0) ;;
    2) echo "FAIL credential expired, test again"; return 1 ;;
    *) echo "FAIL credential store unreachable (the take route did not answer), test again"; return 1 ;;
  esac
  got=$(jq -r '.kind' "$f" 2>/dev/null)
  [ "$got" = "$kind" ] || { echo "FAIL credential is for $got, not $kind"; return 1; }
  onb_tracker_check "$kind" "$f"
}

hp_probe_tracker_test() {
  local kind="${1:-}" nonce="${2:-}" f out rc=0
  HP_HTTP_STATUS=000
  f=$(umask 077; mktemp "${TMPDIR:-/tmp}/onb-trk-row.XXXXXX") || { echo "FAIL no temp file"; return 1; }
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/onb-trk-out.XXXXXX") || { rm -f "$f"; echo "FAIL no temp file"; return 1; }
  _onb_probe "$kind" "$nonce" "$f" > "$out" 2>&1 || rc=$?
  # The scrub: a literal split/join per secret value, so no value is a pattern.
  if ! jq -Rr --slurpfile r <(cat "$f" 2>/dev/null; echo) --arg names "$ONB_SECRET_FIELDS" '
      [(($r[0] // {}).fields // {}) | to_entries[]
        | select(.key as $k | ($names | split(" ") | index($k)) != null)
        | .value | select(type == "string" and length >= 4)] as $s
      | reduce $s[] as $x (.; split($x) | join("[redacted]"))' "$out" 2>/dev/null; then
    echo "FAIL the probe output could not be scrubbed, so it is not shown"; rc=1
  fi
  rm -f "$f" "$out"
  [ "$rc" = 0 ] && HP_HTTP_STATUS=200
  return "$rc"
}
