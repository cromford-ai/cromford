#!/bin/bash
# bin/lib/contract-change-record.sh — cc_record, the write of one contract-change
# step row to the jobs worker (BH-9929). Sourced, never executed.
#
# cc_record <project> <parent_ticket> <step> [key=value ...]
#   step is expand | migrate | contract. The keys are pr_url head_sha classes
#   backup_ref restore_ref verdict approved_by. It POSTs one JSON body to
#   POST /api/contract-changes (worker/jobs/src/routes/contract-changes.js)
#   through _jobs_req in bin/jobs-client.sh. The worker upserts on
#   (project, parent_ticket, step) and never overwrites a stored value with an
#   empty one, so a later call with only verdict= and approved_by= keeps the
#   backup_ref of the first call. A key given as `key=` (empty) is not sent.
#   rc 0 when the worker answers with the row. rc 1 on a bad argument, no
#   client, or a failed POST: ONE line goes to $BUILD/pipeline.log when BUILD
#   is set, else to stderr. It never exits.
#
# A failed write never fails a build: the reader (bin/migration-autopilot.sh)
# treats a missing row as "not approved", so a lost write can never cause an
# apply. The client is fail-open (bin/jobs-client.sh), and tests stub _jobs_req
# (tests/contract-change-record.bh-9929-test.sh), so a test makes 0 network calls.
#
# The root is ${HARNESS:-${H:-}}; it is read only when _jobs_req is not yet
# defined.

# _cc_rec_log <text> — the one failure line.
_cc_rec_log() {
  local line="contract-change: record failed: $*"
  if [ -n "${BUILD:-}" ] && [ -d "$BUILD" ]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$BUILD/pipeline.log" 2>/dev/null && return 0
  fi
  printf '%s\n' "$line" >&2
}

# _cc_rec_client — rc 0 when _jobs_req exists. Sources bin/jobs-client.sh when
# it does not, and restores nounset and pipefail, which the client switches on
# (the lib/alert-line-remote.sh _alr_client pattern).
_cc_rec_client() {
  local root pf nu=0
  command -v _jobs_req >/dev/null 2>&1 && return 0
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -r "$root/bin/jobs-client.sh" ] || return 1
  case $- in *u*) nu=1 ;; esac
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck source=bin/jobs-client.sh
  . "$root/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  [ "$nu" = 0 ] && set +u
  command -v _jobs_req >/dev/null 2>&1
}

cc_record() {
  local project="${1:-}" ticket="${2:-}" step="${3:-}" body kv k v out rc
  local -a args=()
  case "$project" in
    ''|*[!a-z0-9._-]*) _cc_rec_log "bad project '$project'"; return 1 ;;
  esac
  case "$ticket" in
    ''|*[!0-9]*|0|00*|?????????????*) _cc_rec_log "$project: bad parent_ticket '$ticket'"; return 1 ;;
  esac
  case "$step" in
    expand|migrate|contract) ;;
    *) _cc_rec_log "$project #$ticket: bad step '$step'"; return 1 ;;
  esac
  shift 3
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) _cc_rec_log "$project #$ticket $step: bad argument '$kv'"; return 1 ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      pr_url|head_sha|classes|backup_ref|restore_ref|verdict|approved_by) ;;
      *) _cc_rec_log "$project #$ticket $step: unknown key '$k'"; return 1 ;;
    esac
    [ -n "$v" ] && args+=(--arg "$k" "$v")
  done
  body=$(jq -nc --arg project "$project" --argjson parent_ticket "$((10#$ticket))" --arg step "$step" ${args[@]+"${args[@]}"} \
    '$ARGS.named' 2>/dev/null) \
    || { _cc_rec_log "$project #$ticket $step: cannot build the JSON body"; return 1; }
  _cc_rec_client || { _cc_rec_log "$project #$ticket $step: no jobs client"; return 1; }
  out=$(_jobs_req POST /api/contract-changes "$body" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e '.row.id | numbers' <<<"$out" >/dev/null 2>&1; then
    _cc_rec_log "$project #$ticket $step: POST /api/contract-changes rc $rc"
    return 1
  fi
  return 0
}
