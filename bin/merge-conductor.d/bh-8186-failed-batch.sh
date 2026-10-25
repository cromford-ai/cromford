# shellcheck shell=bash
# bin/merge-conductor.d/bh-8186-failed-batch.sh - A HEAD MERGIFY DEQUEUED FOR A
# FAILED BATCH IS NOT ENQUEUED AGAIN WHILE IT CARRIES THE SAME PATCH (BH-8186).
# Sourced by bin/merge-conductor.sh (the BH-7453 fragment block); no side
# effect at source time. The record, the parse and the decision are in
# bin/lib/mc-failed-batch.sh; this file holds the three conductor verbs.
#
# WHY. #8127 failed its batch at 3b036d00 (BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS).
# The harness rebased it to 653fca8a, the approval followed the patch
# (rebind_patch_id), every failure mark stayed on the old sha, and the READY
# arm enqueued it again at 19:02Z. The approval and the failure now both follow
# the patch: the same two rungs judge both (a verbatim patch-id, then
# mc_patch_same's clean-main-merge proof).
#
# THE VERBS (Mergify repos only; MC_FAILED_BATCH=0 makes each a no-op).
#   mc_fbh_record <slug> <project> <key> <url> <head>
#       The settle arm, at an ejection. One comments read. A dequeue whose code
#       counts (MC_FAILED_BATCH_CODES) and whose left sha is <head> writes a
#       `failed` line with the head's patch-id. A failed read writes `pending`.
#       Never stops the ejection.
#   mc_fbh_apply
#       pr_worker, on a READY row: in the requeue arm before its re-entry gate,
#       and before the READY arm. No record file = one stat and rc 1. Else it
#       judges the live record (fbh_decide) and, on a hold, sets STATE and WHY
#       and returns rc 0. A clear appends cleared:<why> and returns rc 1.
#   mc_fbh_clear <key> <head> <why>
#       Appends cleared:<why> when the live record is for <head>.
#
# Log lines, one per (key, head, word): FAILED_BATCH_RECORDED,
# FAILED_BATCH_PENDING, FAILED_BATCH_HELD, FAILED_BATCH_CLEARED,
# FAILED_BATCH_UNRECORDED; FAILED_BATCH_GC n=<count> when the gc deletes.

# shellcheck source=bin/lib/mc-failed-batch.sh
[ -r "$H/bin/lib/mc-failed-batch.sh" ] && . "$H/bin/lib/mc-failed-batch.sh"

# _mc_fbh_once <key> <head> <word> <line> — one log line per (key, head, word).
_mc_fbh_once() {
  mc_attempt_has "fbhlog $1 $2 $3" 2>/dev/null && return 0
  mc_attempt_put "fbhlog $1 $2 $3"
  mc_log "$4"
}

# _mc_fbh_gc — the record retention, at most once per MC_FAILED_BATCH_GC_INTERVAL_MIN minutes (fbh_gc).
_mc_fbh_gc() {
  local n; n=$(fbh_gc 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null && mc_log "FAILED_BATCH_GC n=$n — record files older than $(fbh_keep_days) days deleted"
  return 0
}

# _mc_fbh_patch_id <slug> <project> <num> <rec> <sha> — the stored patch-id of
#   <sha>, computed once under the git lock when it is not stored. rc 1 none.
_mc_fbh_patch_id() {
  local slug="$1" project="$2" num="$3" rec="$4" sha="$5" f id
  f=$(mc_patch_id_file "$rec" "$slug" "$num" "$sha" 2>/dev/null) || return 1
  [ -s "$f" ] || mc_git_locked "$project" mc_patch_id_remember "$rec" "$slug" "$project" "$num" "$sha" >/dev/null 2>&1 || return 1
  id=$(head -1 "$f" 2>/dev/null)
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# _mc_fbh_read <slug> <project> <key> <url> <head> — read the dequeue payload
#   and write the record. rc 0 a `failed` line was written (or stands), rc 1
#   the dequeue is not a counted failure of <head>, rc 2 the read failed.
_mc_fbh_read() {
  local slug="$1" project="$2" key="$3" url="$4" head="$5" num raw line prc code sha d chk rec pid f live
  num="${key##*#}"; f=$(fbh_file "$slug" "$num")
  command -v gh_rest_issue_comments >/dev/null 2>&1 || return 2
  mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || return 2
  prc=0; line=$(fbh_parse "$raw") || prc=$?
  [ "$prc" = 2 ] && return 2
  [ "$prc" = 0 ] || return 1
  IFS=$'\t' read -r code sha d chk <<<"$line"
  fbh_code_counts "$code" || return 1
  [ "${#sha}" -ge 7 ] || return 1
  case "$head" in "$sha"*) ;; *) return 1 ;; esac
  live=$(fbh_live "$f")
  [ "$(cut -f2,4 <<<"$live")" = "$head"$'\tfailed' ] && return 0
  rec=$(mc_record_for "$url" 2>/dev/null || true)
  pid=$(_mc_fbh_patch_id "$slug" "$project" "$num" "$rec" "$head") || pid=-
  if ! fbh_append "$f" "$(fbh_now)" "$head" "$pid" failed "$code" "$d" "$chk"; then
    mc_log "FAILED_BATCH_UNRECORDED $key $head — the record $f could not be written; the ejection goes on"
    return 1
  fi
  mc_log "FAILED_BATCH_RECORDED $key $head code=$code draft=#$d checks=$(fbh_checks_text "$chk") patch=${pid:0:12}"
  return 0
}

# mc_fbh_record <slug> <project> <key> <url> <head> — see the header.
mc_fbh_record() {
  local slug="$1" project="$2" key="$3" url="$4" head="$5" rc f
  fbh_enabled || return 0
  [ -n "$key" ] && [ -n "$head" ] || return 0
  _mc_fbh_gc
  rc=0; _mc_fbh_read "$slug" "$project" "$key" "$url" "$head" || rc=$?
  if [ "$rc" = 2 ]; then
    f=$(fbh_file "$slug" "${key##*#}")
    if fbh_append "$f" "$(fbh_now)" "$head" - pending - - -; then
      mc_log "FAILED_BATCH_PENDING $key $head — the dequeue payload could not be read; the hold reads it again before any enqueue"
    else
      mc_log "FAILED_BATCH_UNRECORDED $key $head — the dequeue payload could not be read and $f could not be written; the ejection goes on"
    fi
  fi
  return 0
}

# mc_fbh_clear <key> <head> <why> — see the header.
mc_fbh_clear() {
  local key="$1" head="$2" why="$3" slug f live
  slug="${key%#*}"; f=$(fbh_file "$slug" "${key##*#}")
  [ -s "$f" ] || return 0
  live=$(fbh_live "$f")
  [ -n "$live" ] && [ "$(cut -f2 <<<"$live")" = "$head" ] || return 0
  fbh_append "$f" "$(fbh_now)" "$head" - "cleared:$why" - - - || return 0
  mc_log "FAILED_BATCH_CLEARED $key $head $why — the failed-batch record is cleared"
}

# _mc_fbh_same <rec-head> <rec-pid> — 1 when HEAD carries the recorded head's
#   patch, 0 when not, ? when it could not be judged this tick. Memoised per
#   (key, head, recorded head) as `fbhsame`, so the git work runs once.
_mc_fbh_same() {
  local rh="$1" rpid="$2" hp m rc
  [ "$HEAD" = "$rh" ] && { echo 1; return 0; }
  # No patch-id was recorded: ask mc_patch_same alone. Only its rc 0 is the
  # same patch; anything else is a new patch, as before (no hold for ever).
  if [ "$rpid" = - ]; then
    rc=0
    mc_git_locked "$P" mc_patch_same "$SLUG" "$P" "$rh" "$HEAD" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] && { echo 1; return 0; }
    echo 0; return 0
  fi
  m=$(awk -v k="$KEY" -v h="$HEAD" -v r="$rh" '$1 == "fbhsame" && $2 == k && $3 == h && $4 == r { w = $5 } END { print w }' "$MC_ATTEMPTS" 2>/dev/null)
  case "$m" in 0|1) echo "$m"; return 0 ;; esac
  hp=$(_mc_fbh_patch_id "$SLUG" "$P" "$NUM" "${REC:-}" "$HEAD") || { echo '?'; return 0; }
  if [ "$hp" = "$rpid" ]; then m=1
  else
    rc=0; MC_PATCH_SAME_UNJUDGED=1
    mc_git_locked "$P" mc_patch_same "$SLUG" "$P" "$rh" "$HEAD" >/dev/null 2>&1 || rc=$?
    # Only an rc 1 that patch_same judged is a different patch. An rc 1 it could
    # not judge (no lib, a fetch failure), 99 (the git lock) and anything else
    # are unknown: wait this tick and remember nothing.
    case "$rc:${MC_PATCH_SAME_UNJUDGED:-1}" in 0:*) m=1 ;; 1:0) m=0 ;; *) echo '?'; return 0 ;; esac
  fi
  mc_attempt_put "fbhsame $KEY $HEAD $rh $m"
  echo "$m"
}

# mc_fbh_apply — see the header. Reads and sets the pr_worker globals SLUG, P,
#   NUM, KEY, URL, HEAD, REC, STATE, WHY.
mc_fbh_apply() {
  local f live ep rh rpid word code d chk same solo="-" age win dec t rc suites rh8 h8 cw
  f=$(fbh_file "$SLUG" "$NUM")
  [ -s "$f" ] || return 1
  fbh_enabled || return 1
  _mc_fbh_gc
  live=$(fbh_live "$f")
  [ -n "$live" ] || return 1
  IFS=$'\t' read -r ep rh rpid word code d chk <<<"$live"
  h8="${HEAD:0:8}"; rh8="${rh:0:8}"
  # A record whose payload read failed at the ejection: read it now.
  if [ "$word" = pending ]; then
    rc=0; _mc_fbh_read "$SLUG" "$P" "$KEY" "$URL" "$rh" || rc=$?
    case "$rc" in
      0) live=$(fbh_live "$f"); IFS=$'\t' read -r ep rh rpid word code d chk <<<"$live" ;;
      1) fbh_append "$f" "$(fbh_now)" "$rh" - cleared:not-counted - - - \
           && _mc_fbh_once "$KEY" "$HEAD" cleared:not-counted "FAILED_BATCH_CLEARED $KEY $HEAD not-counted — the dequeue of $rh8 was not a counted batch failure"
         return 1 ;;
      *) STATE=WAIT_CI
         WHY="dequeued from Mergify on $rh8 and the dequeue reason could not be read yet; ${h8} is not enqueued until it is"
         _mc_fbh_once "$KEY" "$HEAD" wait "FAILED_BATCH_HELD $KEY $HEAD — the dequeue payload of $rh8 is still unread"
         return 0 ;;
    esac
  fi
  same=$(_mc_fbh_same "$rh" "$rpid")
  # The solo re-run (bs_batch, BH-4550) is the bystander proof. Its line is for
  # the member's head when it ran: the recorded head, or this same-patch head.
  if [ "$same" = 1 ] && [ "$d" != - ] && declare -F bs_batch >/dev/null; then
    t=$(mktemp "${TMPDIR:-/tmp}/fbh-bs.XXXXXX" 2>/dev/null) && {
      bs_batch "$SLUG" "$d" > "$t" 2>/dev/null
      solo=$(awk -v n="$NUM" -v a="$rh" -v b="$HEAD" '$1 == n && ($2 == a || $2 == b) { print $3; exit }' "$t" 2>/dev/null)
      rm -f "$t"; }
    [ -n "$solo" ] || solo=-
  fi
  age=$(( $(fbh_now) - ${ep:-0} ))
  win=$(fbh_window_s)
  dec=$(fbh_decide "$same" "$solo" "$age" "$win")
  cw="$code: $(fbh_checks_text "$chk")"
  case "$dec" in
    clear:*)
      fbh_append "$f" "$(fbh_now)" "$HEAD" - "cleared:${dec#clear:}" - - - || return 1
      _mc_fbh_once "$KEY" "$HEAD" "$dec" "FAILED_BATCH_CLEARED $KEY $HEAD ${dec#clear:} — the failed-batch record of $rh8 (draft #$d) is cleared"
      return 1 ;;
    hold-judged)
      suites="${BS_SUITES:-}"; [ -n "$suites" ] || suites=$(fbh_checks_text "$chk")
      STATE=BLOCKED_HUMAN
      WHY="prequeue-red: $suites (failed in batch #$d on $rh8, reproduced alone; $h8 carries the same patch)"
      _mc_fbh_once "$KEY" "$HEAD" hold-judged "FAILED_BATCH_HELD $KEY $HEAD — batch #$d failed on $rh8 and the solo re-run reproduces it; parked for the resolver"
      return 0 ;;
    wait)
      STATE=WAIT_CI
      WHY="failed in Mergify batch #$d ($cw) on $rh8; whether $h8 carries the same patch could not be read this tick"
      _mc_fbh_once "$KEY" "$HEAD" wait "FAILED_BATCH_HELD $KEY $HEAD — failed in batch #$d on $rh8; the patch could not be compared this tick"
      return 0 ;;
    *)
      STATE=WAIT_CI
      WHY="failed in Mergify batch #$d ($cw) on $rh8; $h8 carries the same patch — only a new patch or a bystander proof clears it"
      _mc_fbh_once "$KEY" "$HEAD" hold "FAILED_BATCH_HELD $KEY $HEAD — failed in batch #$d ($cw) on $rh8 and this head carries the same patch; not enqueued"
      return 0 ;;
  esac
}
