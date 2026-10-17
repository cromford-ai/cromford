#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-reviews.sh — BH-1948 (BH-1525.0): the shell client for the
# lead_review_requests table (worker/jobs/schema.sql). Sourced, never executed;
# sourcing only defines the functions and constants below.
#
# THE ROUTES (implemented by the worker sibling, not in this slice):
#   POST /api/lead-reviews              lead token  {repo, pr, head_sha, scope_notes?, prior_verdict_ref?, requested_by?, priority?, head_authors?}
#                                                    priority (BH-5151): integer 1..1000, higher first; the same
#                                                    ask again re-sets it while the row is still requested
#                                       (bearer only when requested_by is exactly inbuild:<box>:<KEY>
#                                       and there is no priority: a build's own ask, BH-5023)
#                                                    head_authors (BH-5351): 1..16 identities that wrote the head;
#                                                    the same ask again records them on a row that has none
#   GET  /api/lead-reviews?status=a,b&repo=&after=   {requests:[...], truncated:bool, next_after?}
#                                                    after=<created_at>,<rowid> is the previous page's
#                                                    next_after (BH-5151); lr_list_all follows it
#   POST /api/lead-reviews/start        bearer      {repo, pr, head_sha, job_id, box, requested_by?, scope_notes?}
#        -> 200 {request, created} | 409 {request, terminal:true} done/failed | 409 {request} live job | 400
#        (BH-4955: creates the row if missing, and takes over a running row whose job is not live)
#   GET  /api/lead-reviews/:id                       {request}
#   POST /api/lead-reviews/:id/claim    bearer      {job_id, box}
#                                                    BH-5400: claiming a requested row that was worked
#                                                    before (job, verdict or promoted stamp set: a raw
#                                                    reset) bumps reset_count, stamps reset_at and
#                                                    clears promoted_verdict_at in the same CAS
#                                                    BH-5351: with x-participant-token, an enrolled
#                                                    machine's claim, box ignored: 401/403 refused,
#                                                    409 `self-review refused` / `authorship unknown`;
#                                                    a running row quiet past stale_s is taken, and
#                                                    the 200 names `reclaimed_from`. /start refuses the
#                                                    participant header (403).
#   POST /api/lead-reviews/:id/heartbeat bearer     {job_id} (BH-5351): only the job holding the running row
#   POST /api/lead-reviews/:id/result   bearer      {job_id, head_sha, outcome, verdict?, report_ref?, reviewer_model?, detail?}
#   POST /api/lead-reviews/:id/reset    lead token  {} (BH-5400) done|failed|superseded -> requested, the
#                                                    result and stamp cleared, reset_count+1, reset_at;
#                                                    requested = 200 {existing:true}, running = 409
#   POST /api/lead-reviews/:id/promoted lead token  {job_id?} (BH-5400): 409 when the row now holds
#                                                    another job; no body stamps as before
# Every function takes the part of the path AFTER /api/lead-reviews ("",
# "?status=requested", "/<id>/claim"); callers never build the base URL.
#
# rc:  lr_get       0 2xx (body on stdout) | 75 the route is not deployed | 1 anything else
#      lr_post      0 2xx | 1 anything else; the body is printed on every answer,
#      lr_post_lead   and `HTTP <code>` goes to stderr on a non-2xx
#      lr_start     0 started | 3 terminal (done = paid already: make no model call)
#                   | 4 held by a live job | 1 anything else (outage, 400, not deployed,
#                   a 409 that is not this route's); the body is printed on every answer
#      lr_heartbeat 0 2xx | 1 anything else (lr_post's)
#      lr_beat_start the beater's pid | 1 no id, no job or a bad interval
#      lr_whoami    0 2xx (the whoami body on stdout) | 1 anything else, `HTTP <code>` on stderr
# PARTICIPANT MODE (BH-5351): when HARNESS_PARTICIPANT_TOKEN_FILE names a readable,
# non-empty file, lr_post and lr_whoami send the bearer and x-participant-token
# from a 0600 header file, never on argv, removed on every path. Without it
# lr_post is the box bearer path, unchanged.
# rc 75 is ONLY the jobs worker's own unknown-endpoint 404 (_vd_worker_404 in
# bin/lib/verdicts.sh). A route's 404 for an unknown id, or a CDN/wrong-host
# 404, is rc 1: reading it as "not deployed" would turn a lookup miss or a bad
# JOBS_URL into "nothing to do".

LR_STATUSES="requested running done superseded failed"
LR_VERDICT_WORDS="MERGE MERGE-WITH-NOTES BLOCK"

_lr_home() { printf '%s' "${HARNESS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"; }

# _lr_client — load the jobs client if the caller did not. Both the client and
#   its modules must be there first: jobs-client.sh exits on a missing module,
#   which inside a sourced function would take the caller down with it.
_lr_client() {
  command -v _jobs_req >/dev/null 2>&1 && return 0
  if [ -r "$(_lr_home)/bin/jobs-client.sh" ] && [ -r "$(_lr_home)/bin/lib/jobs/req.sh" ]; then
    # shellcheck source=/dev/null
    . "$(_lr_home)/bin/jobs-client.sh" 2>/dev/null
  fi
  command -v _jobs_req >/dev/null 2>&1 || { echo "lead-reviews: no jobs client under $(_lr_home)/bin" >&2; return 1; }
}

# _lr_worker_404 <body> — rc 0 when the body is the jobs worker's own
#   unknown-endpoint answer. The judgement lives in bin/lib/verdicts.sh.
_lr_worker_404() {
  command -v _vd_worker_404 >/dev/null 2>&1 || {
    # shellcheck source=/dev/null
    [ -r "${BASH_SOURCE[0]%/*}/verdicts.sh" ] && . "${BASH_SOURCE[0]%/*}/verdicts.sh"; }
  command -v _vd_worker_404 >/dev/null 2>&1 && _vd_worker_404 "$1"
}

lr_get() { # lr_get <path-and-query>
  local out rc
  _lr_client || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/lead-reviews.XXXXXX") || return 1
  # _jobs_req in THIS shell, so JOBS_HTTP / JOBS_BODY survive for the 404 judgement.
  JOBS_ALERT=0 _jobs_req GET "/api/lead-reviews${1:-}" > "$out"; rc=$?
  if [ "$rc" -eq 0 ]; then cat "$out"; rm -f "$out"; return 0; fi
  rm -f "$out"
  echo "HTTP ${JOBS_HTTP:-none}" >&2
  [ "$rc" -eq 2 ] && [ "${JOBS_HTTP:-}" = 404 ] && _lr_worker_404 "${JOBS_BODY:-}" && return 75
  return 1
}

lr_post() { # lr_post <path> <json> — the box bearer, plus the participant token in participant mode
  if [ -n "$(_lr_participant_tokf)" ]; then _lr_req_participant POST "/api/lead-reviews${1:-}" "${2:-}"; return; fi
  _lr_client || return 1
  JOBS_ALERT=0 _jobs_req POST "/api/lead-reviews${1:-}" "${2:-}" > /dev/null
  printf '%s' "${JOBS_BODY:-}"
  case "${JOBS_HTTP:-}" in 2*) return 0 ;; esac
  echo "HTTP ${JOBS_HTTP:-none}" >&2
  return 1
}

lr_start() { # lr_start <repo> <pr> <sha> <job_id> <box> [scope_notes] — a row it
  # creates says requested_by lead-review-worklist, so bin/lead-review.sh can
  # tell it from a person's request (a person's row is never replayed, BH-4956).
  # A non-empty <scope_notes> (BH-5878: the gates' notes, lg_scope_notes) is
  # stored on a row /start creates; a row that exists keeps its own notes.
  local body
  body=$(jq -nc --arg r "${1:-}" --arg p "${2:-}" --arg s "${3:-}" --arg j "${4:-}" --arg b "${5:-}" --arg n "${6:-}" \
    '{repo:$r, pr:($p|tonumber? // $p), head_sha:$s, job_id:$j, box:$b, requested_by:"lead-review-worklist"}
     + (if $n == "" then {} else {scope_notes:$n} end)') || return 1
  # Cleared here: lr_post can return before _jobs_req runs, and a stale 409
  # from an earlier call in this shell must not be read as this one's answer.
  JOBS_HTTP=""; JOBS_BODY=""
  lr_post /start "$body" && return 0
  [ "${JOBS_HTTP:-}" = 409 ] || return 1
  printf '%s' "${JOBS_BODY:-}" | jq -e '.terminal == true' >/dev/null 2>&1 && return 3
  printf '%s' "${JOBS_BODY:-}" | jq -e '.request.id' >/dev/null 2>&1 && return 4
  return 1
}

# _lr_participant_tokf — prints HARNESS_PARTICIPANT_TOKEN_FILE when it is set,
#   readable and non-empty; prints nothing (rc 1) otherwise.
_lr_participant_tokf() {
  local f="${HARNESS_PARTICIPANT_TOKEN_FILE:-}"
  [ -n "$f" ] && [ -r "$f" ] && [ -s "$f" ] || return 1
  printf '%s' "$f"
}

# _lr_req_participant <GET|POST> <path> [json] — the bearer AND x-participant-token,
#   both in a 0600 header file that is removed on every path. lr_post_lead's shape.
_lr_req_participant() {
  local tokf tok hdr out code
  tokf=$(_lr_participant_tokf) || { echo "lead-reviews: no readable participant token file" >&2; return 1; }
  tok=$(head -1 "$tokf" | tr -d ' \r\n')
  [ -n "$tok" ] || { echo "lead-reviews: participant token file $tokf is empty" >&2; return 1; }
  _lr_client || return 1
  [ -n "${HARNESS_SECRET:-}" ] || { echo "lead-reviews: HARNESS_SECRET is not set" >&2; return 1; }
  hdr=$(umask 077; mktemp "${TMPDIR:-/tmp}/lead-reviews-h.XXXXXX") || return 1
  printf 'authorization: Bearer %s\nx-participant-token: %s\ncontent-type: application/json\n' "$HARNESS_SECRET" "$tok" > "$hdr"
  unset tok
  if [ "$1" = GET ]; then
    out=$(curl -sS -m "${JOBS_TIMEOUT:-8}" --connect-timeout 3 -w $'\n%{http_code}' -X GET \
            -H "@$hdr" "$JOBS_URL$2" 2>/dev/null)
  else
    out=$(curl -sS -m "${JOBS_TIMEOUT:-8}" --connect-timeout 3 -w $'\n%{http_code}' -X POST \
            -H "@$hdr" --data-binary "${3:-}" "$JOBS_URL$2" 2>/dev/null)
  fi || { rm -f "$hdr"; echo "HTTP none" >&2; return 1; }
  rm -f "$hdr"
  code="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  case "$code" in 2*) return 0 ;; esac
  echo "HTTP $code" >&2
  return 1
}

# lr_whoami — GET /api/participants/whoami as this machine's participant token.
lr_whoami() { _lr_req_participant GET /api/participants/whoami; }

# lr_heartbeat <id> <job> — re-stamp the claim's heartbeat_at (BH-5351).
lr_heartbeat() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  lr_post "/$1/heartbeat" "$(jq -nc --arg j "$2" '{job_id:$j}')"
}

# lr_beat_interval — the beat interval in seconds: stale_s/3, never under
#   LR_BEAT_MIN_S (default 10). stale_s is the settings row
#   lead_review_claim_stale_s; no row (setting_get rc 2) or no settings client
#   is 900 quietly, and any other unreadable answer is 900 with one stderr line.
lr_beat_interval() {
  local stale rc=0 min="${LR_BEAT_MIN_S:-10}" iv
  case "$min" in ''|*[!0-9]*|0*) min=10 ;; esac
  if command -v setting_get >/dev/null 2>&1; then
    stale=$(setting_get lead_review_claim_stale_s 2>/dev/null) || rc=$?
  else
    rc=2
  fi
  case "$stale" in ''|*[!0-9]*|0*)
    [ "$rc" -eq 2 ] || echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') lead_review_claim_stale_s unreadable (rc=$rc '${stale:-}'); heartbeat interval from 900s" >&2
    stale=900 ;;
  esac
  iv=$((stale / 3)); [ "$iv" -ge "$min" ] || iv=$min
  printf '%s' "$iv"
}

# lr_beat_start <id> <job> <interval-s|auto> — a background lr_heartbeat every
#   <interval-s> seconds while the calling shell lives (auto: lr_beat_interval,
#   read inside the beater so the caller never waits on it); prints its pid, which
#   job_beat_stop ends (the shape of job_beat_start: the sleep is waited on, so
#   TERM takes it down with the loop). A failed beat is one line on stderr,
#   which goes to LR_BEAT_LOG (default /dev/null), and is not retried: the
#   claim then goes stale, which is what a lost holder should look like.
lr_beat_start() {
  local id="${1:-}" job="${2:-}" iv="${3:-}" me=$$
  [ -n "$id" ] && [ -n "$job" ] || return 1
  case "$iv" in auto) ;; ''|*[!0-9]*|0) return 1 ;; esac
  ( command -v _job_beat_shed_fds >/dev/null 2>&1 && _job_beat_shed_fds
    [ "$iv" = auto ] && iv=$(lr_beat_interval)
    _sp=""
    trap '[ -n "$_sp" ] && kill "$_sp" 2>/dev/null; exit 0' TERM
    while kill -0 "$me" 2>/dev/null; do
      sleep "$iv" & _sp=$!
      wait "$_sp" 2>/dev/null
      kill -0 "$me" 2>/dev/null || break
      lr_heartbeat "$id" "$job" >/dev/null 2>&1 \
        || echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') lead review heartbeat for $id (job $job) failed" >&2
    done
    [ -n "$_sp" ] && kill "$_sp" 2>/dev/null
    exit 0 ) >/dev/null 2>>"${LR_BEAT_LOG:-/dev/null}" &
  printf '%s' "$!"
}

# lr_report_title [file] — a lead review report's title line (`# Lead review
#   <key> (<repo>#<pr> at <sha>)`): line 1, or line 2 when line 1 is the
#   participant `Reviewer: <name> (enrolled machine)` line (BH-5351). Reads
#   stdin without a file. The replay guards and the land lane match on it.
lr_report_title() {
  awk 'NR == 1 && /^Reviewer: .* \(enrolled machine\)$/ { next } { print; exit }' "${1:--}" 2>/dev/null
}

# lr_body_fp — the fingerprint of the PR body a review reads (BH-5888): a pulls
#   JSON on stdin, `sha256:` + the first 16 hex of sha256 over `.body` exactly as
#   GitHub returns it. A null or missing body hashes as the empty string.
lr_body_fp() {
  local h
  h=$(jq -j '.body // ""' 2>/dev/null | sha256sum) || return 1
  printf 'sha256:%s' "${h:0:16}"
}

# lr_body_reason <bfp> [nv] — the lead guard key reason for a changed PR body
#   (BH-5888): `body<D>` (`nvbody<D>` with nv), <D> the decimal of the first 12
#   hex of <bfp>. Decimal, because review-paid-unchanged.sh strips the trailing
#   digits of a reason to group it; max 21 chars, under _rb_fp's 24-char cap.
#   A <bfp> that is not `sha256:` + 16 lower hex prints nothing, rc 1.
lr_body_reason() {
  [[ "${1:-}" =~ ^sha256:([0-9a-f]{12})[0-9a-f]{4}$ ]] || return 1
  local p=""; [ "${2:-}" = nv ] && p=nv
  printf '%sbody%s' "$p" "$((16#${BASH_REMATCH[1]}))"
}

# lr_report_body_ok <file> <fp> — rc 0 when the report may be replayed for the
#   PR body <fp> (BH-5888): its `- pr body:` header line names <fp>, or it has
#   none (a report written before BH-5888). rc 1 when it names another body.
#   Only the header block (after the title, up to the next empty line) is read,
#   so a finding that quotes `- pr body:` does not count.
lr_report_body_ok() {
  local got
  got=$(awk '/^$/ { b++; if (b == 2) exit; next }
             b == 1 && sub(/^- pr body: /, "") { print; exit }' "$1" 2>/dev/null)
  [ -z "$got" ] || [ "$got" = "${2:-}" ]
}

# lr_post_lead <path> <json> — the bearer AND the lead token (LEAD_VERDICT_TOKEN_FILE,
#   the file bin/lead-verdict.sh reads). Both travel in a 0600 header file, never
#   on argv, and that file is removed on every path. Never echoes a secret.
lr_post_lead() {
  local tokf="${LEAD_VERDICT_TOKEN_FILE:-$HOME/.config/cromford/lead-verdict-token}" tok hdr out code
  [ -r "$tokf" ] || { echo "lead-reviews: lead token file $tokf is not readable" >&2; return 1; }
  tok=$(head -1 "$tokf" | tr -d ' \r\n')
  [ -n "$tok" ] || { echo "lead-reviews: lead token file $tokf is empty" >&2; return 1; }
  _lr_client || return 1
  [ -n "${HARNESS_SECRET:-}" ] || { echo "lead-reviews: HARNESS_SECRET is not set" >&2; return 1; }
  hdr=$(umask 077; mktemp "${TMPDIR:-/tmp}/lead-reviews-h.XXXXXX") || return 1
  printf 'authorization: Bearer %s\nx-lead-verdict-token: %s\ncontent-type: application/json\n' "$HARNESS_SECRET" "$tok" > "$hdr"
  unset tok
  out=$(curl -sS -m "${JOBS_TIMEOUT:-8}" --connect-timeout 3 -w $'\n%{http_code}' -X POST \
          -H "@$hdr" --data-binary "${2:-}" "$JOBS_URL/api/lead-reviews${1:-}" 2>/dev/null) \
    || { rm -f "$hdr"; echo "HTTP none" >&2; return 1; }
  rm -f "$hdr"
  code="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  case "$code" in 2*) return 0 ;; esac
  echo "HTTP $code" >&2
  return 1
}

# lr_list_all <path-and-query> <max-pages> — BH-5151: EVERY page of the list,
#   following next_after until truncated is false, at most <max-pages> pages.
#   Prints ONE object on stdout:
#     {requests:[...in server order, de-duplicated by id...], pages:<n>,
#      complete:<bool>, stop:"" | "cap" | "page-failed" | "no-cursor" | "cursor-loop"}
#   cap          <max-pages> pages were read and the last was still truncated
#   page-failed  page <pages+1> failed; the rows already read are kept
#   no-cursor    a truncated page without next_after: a worker that predates
#                the cursor (it would answer page 1 again, forever)
#   cursor-loop  next_after repeated the cursor that produced it
#   rc 0 page 1 was read (a partial read too: complete=false says why)
#      75 page 1 says the route is not deployed | 1 page 1 failed any other way
#   Pages pile up in a temp FILE and jq slurps files: rows never ride argv.
lr_list_all() {
  local q="${1:-}" max="${2:-}" acc pg n=0 rc after="" next stop="" sep="?" path merged
  case "$max" in ''|*[!0-9]*|0) echo "lead-reviews: lr_list_all needs a positive page cap, got '$max'" >&2; return 1 ;; esac
  case "$q" in *\?*) sep="&" ;; esac
  acc=$(mktemp "${TMPDIR:-/tmp}/lead-reviews.XXXXXX") || return 1
  pg=$(mktemp "${TMPDIR:-/tmp}/lead-reviews.XXXXXX") || { rm -f "$acc"; return 1; }
  printf '[]' > "$acc"
  while :; do
    path="$q"
    [ -n "$after" ] && path="$q${sep}after=$(jq -rn --arg a "$after" '$a | @uri')"
    lr_get "$path" > "$pg"; rc=$?
    if [ "$rc" -eq 0 ] && ! jq -e '.requests | type == "array"' "$pg" >/dev/null 2>&1; then
      echo "lead-reviews: page $((n + 1)) of $q is not a request list" >&2; rc=1
    fi
    if [ "$rc" -ne 0 ]; then
      [ "$n" -eq 0 ] && { rm -f "$acc" "$pg"; return "$rc"; }
      stop=page-failed; break
    fi
    n=$((n + 1))
    merged=$(jq -c -s '.[0] + .[1].requests' "$acc" "$pg" 2>/dev/null) && [ -n "$merged" ] \
      || { rm -f "$acc" "$pg"; echo "lead-reviews: could not merge page $n" >&2; return 1; }
    printf '%s' "$merged" > "$acc"
    [ "$(jq -r '.truncated == true' "$pg")" = true ] || break
    next=$(jq -r '.next_after // empty | tostring' "$pg")
    if [ -z "$next" ]; then stop=no-cursor; break; fi
    if [ "$next" = "$after" ]; then stop=cursor-loop; break; fi
    if [ "$n" -ge "$max" ]; then stop=cap; break; fi
    after="$next"
  done
  jq -c --argjson n "$n" --arg stop "$stop" '
    {requests: (reduce .[] as $r ({seen: {}, out: []};
                 if $r.id == null then .out += [$r]
                 elif .seen[$r.id | tostring] then .
                 else .seen[$r.id | tostring] = true | .out += [$r] end) | .out),
     pages: $n, complete: ($stop == ""), stop: $stop}' "$acc"; rc=$?
  rm -f "$acc" "$pg"
  [ "$rc" -eq 0 ] || return 1
}
