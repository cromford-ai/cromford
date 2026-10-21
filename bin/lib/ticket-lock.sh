# shellcheck shell=bash
# bin/lib/ticket-lock.sh — the cross-harness ticket lock, taken IN CODE by every
# build (2026-10-20). Contract: docs/HARNESS-COORDINATION.md (harness-locks
# worker: POST $LOCKS_URL/v1/{acquire,renew,release}, bearer $LOCKS_TOKEN).
#
# WHY. the partner harness builds the project-3, project-2, project-4 and project-1 boards too, and
# the two harnesses agree on a ticket through this lock. Until now only the
# triage PROMPT asked for it (prompts/<project>.md), so a build that did not
# come out of that prompt — a decompose child, a pool dispatch, a retry — ran
# with no lock. TK-249 (2026-10-04): our pool build started 00:21, partner asked
# at 00:43, nobody held it, and both harnesses opened a PR (#404, #405).
#
#   tl_ns      <project>                    the lock namespace, or nothing
#   tl_acquire <project> <KEY> <statefile>  rc 0 held (state written), rc 3 held
#                                           by another harness (holder printed),
#                                           rc 1 outage, rc 2 not applicable
#   tl_renew   <statefile>                  rc 0 renewed (or re-acquired), rc 3 LOST
#                                           (another holder has it), rc 1 outage,
#                                           rc 2 no lock to renew
#   tl_release <statefile> <outcome>        rc 0; never fails a build
#   tl_lost    <statefile>                  rc 0 when the lock is known lost
#   tl_beat_start <statefile> [secs]        background renew loop; prints its pid
#
# An outage is never "held by another harness": a build does not stop because
# the lock service is down (that would let one Cloudflare blip park the fleet).
# Only a 409 on acquire, or a 404 on renew, changes what a build does.
# Defines functions only. Nothing runs on source.

TL_TTL_S="${TL_TTL_S:-7200}"

tl_ns() {
  case "${1:-}" in
    project-3)       printf 'project-3' ;;
    project-2) printf 'project-2' ;;
    project-4)       printf 'project-4' ;;
    project-1)   printf 'project-1' ;;
    *)             return 1 ;;
  esac
}

# _tl_post <path> <json> — POST to the lock service. Prints "<http-code> <body>".
# rc 1 when the service is not configured or the transport failed.
_tl_post() {
  local code body tmp
  [ -n "${LOCKS_URL:-}" ] && [ -n "${LOCKS_TOKEN:-}" ] || return 1
  tmp=$(mktemp) || return 1
  # The bearer goes in on stdin (-H @-), never on argv where `ps` shows it.
  code=$(printf 'Authorization: Bearer %s\n' "$LOCKS_TOKEN" | curl -s --connect-timeout 5 -m 10 -o "$tmp" -w '%{http_code}' -X POST \
    -H @- -H "Content-Type: application/json" \
    --data-binary "$2" "${LOCKS_URL%/}$1" 2>/dev/null) || code=000
  body=$(head -c 2000 "$tmp" 2>/dev/null); rm -f "$tmp"
  [ "$code" = 000 ] && return 1
  printf '%s %s' "$code" "$body"
}

tl_acquire() {
  local ns key out code body lid
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 2
  ns=$(tl_ns "$1") || return 2
  [ -n "${LOCKS_URL:-}" ] && [ -n "${LOCKS_TOKEN:-}" ] || return 2
  key="$ns:$2"
  out=$(_tl_post /v1/acquire "$(jq -nc --arg k "$key" --argjson t "$TL_TTL_S" '{kind:"ticket",key:$k,ttl_s:$t}')") || return 1
  code="${out%% *}"; body="${out#* }"
  case "$code" in
    200|201)
      lid=$(jq -r '.lease_id // empty' <<<"$body" 2>/dev/null)
      [ -n "$lid" ] || return 1
      printf '%s\n%s\n' "$key" "$lid" > "$3.tmp" && mv -f "$3.tmp" "$3" ;;
    409)
      lid=$(jq -r '.holder // empty' <<<"$body" 2>/dev/null | head -1)
      printf '%s\n' "${lid:-another harness}"
      return 3 ;;
    *) return 1 ;;
  esac
}

# A 404 on renew does NOT mean lost. The worker gives a NEW lease_id every time
# the same holder acquires (locks-worker/src/index.js acquire upsert), and all
# our machines share one token, so a triage tick that acquires the key during a
# build rotates the lease under it. So a 404 re-acquires the key: 201 = still
# ours (store the new lease), 409 = another holder has it (LOST), anything else
# = an outage (never lost). Lead review of #7788.
tl_renew() {
  local key lid out code body nl
  [ -s "${1:-}" ] || return 2
  key=$(sed -n 1p "$1"); lid=$(sed -n 2p "$1")
  [ -n "$key" ] && [ -n "$lid" ] || return 2
  out=$(_tl_post /v1/renew "$(jq -nc --arg k "$key" --arg l "$lid" --argjson t "$TL_TTL_S" '{key:$k,lease_id:$l,ttl_s:$t}')") || return 1
  code="${out%% *}"
  case "$code" in
    200|201) return 0 ;;
    404) ;;
    *) return 1 ;;
  esac
  out=$(_tl_post /v1/acquire "$(jq -nc --arg k "$key" --argjson t "$TL_TTL_S" '{kind:"ticket",key:$k,ttl_s:$t}')") || return 1
  code="${out%% *}"; body="${out#* }"
  case "$code" in
    200|201)
      nl=$(jq -r '.lease_id // empty' <<<"$body" 2>/dev/null)
      [ -n "$nl" ] || return 1
      # tmp + mv: the beat and the push gate can renew at once; a reader must
      # never see a half-written file.
      printf '%s\n%s\n' "$key" "$nl" > "$1.tmp" && mv -f "$1.tmp" "$1"; return 0 ;;
    409) : > "$1.lost"; return 3 ;;
    *) return 1 ;;
  esac
}

# Released by KEY, not lease: the worker deletes only rows our token holds
# (DELETE ... WHERE key AND holder), so this frees a lease that rotated under the
# build and can never delete the other harness's lock.
tl_release() {
  local key
  [ -s "${1:-}" ] || return 0
  key=$(sed -n 1p "$1")
  [ -n "$key" ] || return 0
  _tl_post /v1/release "$(jq -nc --arg k "$key" --arg o "${2:-done}" '{key:$k,outcome:$o}')" >/dev/null 2>&1 || true
  rm -f "$1" "$1.lost"
  return 0
}

tl_lost() { [ -e "${1:-}.lost" ]; }

# _tl_shed_fds — close every inherited fd 3..199 in the current shell (the same
# sweep as bin/lib/jobs/jobs.sh _job_beat_shed_fds, kept here so this lib needs
# no other lib). The renew loop needs no descriptor above stderr.
_tl_shed_fds() {
  local fd list
  list=$(ls /dev/fd 2>/dev/null || ls "/proc/$$/fd" 2>/dev/null)
  for fd in $list 3 4 5 6 7 8 9 10 11 12; do
    case "$fd" in ''|*[!0-9]*) continue ;; esac
    { [ "$fd" -ge 3 ] && [ "$fd" -lt 200 ]; } || continue
    eval "exec $fd>&-" 2>/dev/null || true
  done
  return 0
}

# tl_beat_start <statefile> [secs] — renew every <secs> (default 600) while the
# caller lives. A 404 writes <statefile>.lost and ends the loop; the push gate
# reads that file. An outage is retried on the next beat.
tl_beat_start() {
  local f="${1:-}" iv="${2:-${TL_BEAT_SECS:-600}}" me=$$
  [ -s "$f" ] || return 1
  # Shed inherited fds FIRST (job_beat_start's reason): a SIGKILLed build must not
  # leave this loop holding the per-key flock (run-build.sh fd 7) or renewing a
  # lock nobody is using.
  ( _tl_shed_fds
    _sp=""
    trap '[ -n "$_sp" ] && kill "$_sp" 2>/dev/null; exit 0' TERM
    while kill -0 "$me" 2>/dev/null; do
      sleep "$iv" & _sp=$!
      wait "$_sp" 2>/dev/null
      kill -0 "$me" 2>/dev/null || break
      [ -s "$f" ] || break
      tl_renew "$f"; [ "$?" = 3 ] && break
    done
    exit 0 ) >/dev/null 2>&1 &
  printf '%s' "$!"
}
