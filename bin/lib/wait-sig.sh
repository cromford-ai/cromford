# shellcheck shell=bash
# bin/lib/wait-sig.sh — BH-9863: a local signature of the thing a deferred
# ticket waits on. Sourced, never run. Functions only; no network read.
#
# WHY. project-3, 2026-11-20 02:00-13:50Z: 6 ready tickets stayed queued with no
# spawn while 1 build ran. A row held on a blocker (bin/lib/defer-after-stop.sh)
# read the open-PR list again only on a clock (10, 20, 40 ... 240 min), so a
# blocker that merged between two checks stayed unseen for up to 240 min. The
# triage fingerprint and the call-guard repeat park did not see the blocker at
# all, so they did not move either.
#
# THE SIGNATURE. ws_blocker_sig hashes what this box already knows about the
# blocker. A change makes a check due now. It is never a release on its own:
# the open-PR list stays the release truth.
#   ws_newest_rec <h> <p> <KEY>   the newest record dir of KEY (pool-<p>-<KEY>-*
#                                 or <p>-<KEY>-*), by RESULT mtime; rc 1 if none.
#   ws_rec_key <p> <dir-basename> the full KEY of a record dir name; rc 1 if none.
#   ws_blocker_sig <h> <p> <BLK> [slug]  16 hex; rc 1 (no output) with no sha256sum.
#     Lines hashed:
#       rec <basename> <first word of RESULT> <COMMENTED y|n>   (or `rec none`)
#       merged-done y|n     the record's PR URL, exact line, in state/merge-sweep-done.txt
#       closed-watch <st>   field 1 of state/merge-conductor/closed-watch/<slug>/<n>
#       prstate <STATE>     state/<p>.prstates for that PR number
#       queued y|n          state/build-queue/<p>/<BLK>.json exists

_WS_KEY_RE='^[A-Z][A-Z0-9]*-[0-9]+$'

ws_newest_rec() {
  local h="${1:-}" p="${2:-}" k="${3:-}" f mt nt=-1 newest=""
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  for f in "$h/builds/pool-$p-$k-"*/RESULT "$h/builds/$p-$k-"*/RESULT; do
    [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mt" -ge "$nt" ] && { nt=$mt; newest="${f%/RESULT}"; }
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

ws_rec_key() {
  local p="${1:-}" b="${2:-}"
  [ -n "$p" ] && [ -n "$b" ] || return 1
  b="${b#pool-}"
  case "$b" in "$p"-*) b="${b#"$p"-}" ;; *) return 1 ;; esac
  [[ "$b" =~ ^([A-Z][A-Z0-9]*-[0-9]+)(-.*)?$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

ws_blocker_sig() {
  local h="${1:-}" p="${2:-}" b="${3:-}" slug="${4:-${POOL_SLUG:-}}" rec l1 url="" n="" st cw
  [ -n "$h" ] && [ -n "$p" ] && [[ "$b" =~ $_WS_KEY_RE ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  {
    if rec=$(ws_newest_rec "$h" "$p" "$b"); then
      l1=$(head -1 "$rec/RESULT" 2>/dev/null | tr -d '\r')
      if [ -e "$rec/COMMENTED" ]; then cw=y; else cw=n; fi
      printf 'rec %s %s %s\n' "$(basename "$rec")" "${l1%% *}" "$cw"
      [[ "$l1" =~ ^(PR_CREATED|PR_MERGED)\ (https://[^[:space:]]+/pull/([0-9]+)) ]] \
        && { url="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"; }
    else
      printf 'rec none\n'
    fi
    if [ -n "$url" ] && grep -qxF "$url" "$h/state/merge-sweep-done.txt" 2>/dev/null; then
      printf 'merged-done y\n'
    else
      printf 'merged-done n\n'
    fi
    st=""
    if [ -n "$n" ] && [ -n "$slug" ]; then
      st=$(cut -f1 "$h/state/merge-conductor/closed-watch/${slug//[^A-Za-z0-9._-]/_}/$n" 2>/dev/null | head -1)
    fi
    printf 'closed-watch %s\n' "${st:--}"
    st=""
    if [ -n "$n" ]; then
      if command -v triage_prstates_get >/dev/null 2>&1; then
        st=$(triage_prstates_get "$h" "$p" "$n" 2>/dev/null)
      else
        st=$(awk -F'\t' -v n="$n" '$1==n{v=$2} END{print v}' "$h/state/$p.prstates" 2>/dev/null)
      fi
    fi
    printf 'prstate %s\n' "${st:--}"
    if [ -e "$h/state/build-queue/$p/$b.json" ]; then printf 'queued y\n'; else printf 'queued n\n'; fi
  } | sha256sum | cut -c1-16
}

# ws_blocker_pr <h> <p> <BLK> -> the PR number in the blocker's newest record
# (PR_CREATED/PR_MERGED <url>); rc 1 when there is none.
ws_blocker_pr() {
  local rec l1
  rec=$(ws_newest_rec "$@") || return 1
  l1=$(head -1 "$rec/RESULT" 2>/dev/null)
  [[ "$l1" =~ ^(PR_CREATED|PR_MERGED)\ https://[^[:space:]]+/pull/([0-9]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[2]}"
}
