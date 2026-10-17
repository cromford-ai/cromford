# shellcheck shell=bash
# bin/lib/lead-worklist.sh — the lead review lane's worklist and start limits.
# Sourced by bin/lead-review.sh after bin/jobs-client.sh, never run. Defining
# functions is its only effect at source time. The root is ${HARNESS:-${H:-}};
# an empty root makes the functions that need a path refuse (non-zero).
#
# WHY. The lane read only lead review request rows, so a PR with no row, or a
# row a dead producer left behind, was never reviewed. The jobs worker now
# folds PR gate facts into one ordered list of heads that need a lead review
# (GET /api/pr-state/needs-review, pr_needs_review). The lane reads that list
# first, and the request rows second.
#
# EACH FUNCTION, its rc contract:
#   lw_items <slug> <out>   pr_needs_review: rc 0 writes one JSON line per row,
#                           {repo, pr, head_sha, hotfix, nudged, approved_at,
#                           src:"worklist"}, in route order. rc 2 = a measured
#                           none (<out> empty). rc 1 = an outage or an answer
#                           that does not parse: <out> is empty, and the caller
#                           starts nothing from this repo's list.
#   lw_concurrency_ok <live>  rc 0 = a start is allowed. The settings row
#                           lead_review.concurrency is a fleet-wide count. No row,
#                           or a row that cannot be read or is not a positive
#                           integer, is rc 0: the box cap (RPOOL_K) governs, and
#                           it is logged once. With a row: rc 0 only when the
#                           lead_review jobs running on OTHER boxes plus <live>
#                           are under it. rc 1 sets LW_CONC_WHY: `full` (the
#                           count is at the row) or `unreadable` (the running
#                           count could not be read: no start this pass).
#   lw_spend_ok             rc 0 = under the daily cap. The settings row
#                           lead_review.daily_spend_usd against
#                           llm_gate_spend_today lead-review "" lead-review. No
#                           row = no cap (rc 0). rc 1 sets LW_SPEND_WHY: `cap`
#                           (spend >= cap: ONE lane-alert warn a UTC day, id
#                           lead-spend-cap-<day>, marker state/lead-review/
#                           spend-cap-<day> written only after lane-alert rc 0)
#                           or `unreadable` (a cap row exists and the cap or the
#                           spend could not be read: no alert). Unreadable is
#                           never "go" when money moves.
#   lw_attempts <slug> <pr> <sha>  prints the counted attempts on that head, 0..3
#                           (pr_attempts rows of kind lead-review-1..3, probed in
#                           order, stopping at the first miss). rc 1 = an outage
#                           or an answer with no attempt row: no count.
#   lw_attempt_add <slug> <pr> <sha> <n>  PUT the row lead-review-<n>. rc is the PUT's.
#   lw_release <slug> <pr> <sha>  PUT the row lead-review-free: this lane ended
#                           its job on purpose and left the request row
#                           `running` (a not-counted exit, or a counted failure
#                           already written). rc is the PUT's.
#   lw_released <slug> <pr> <sha>  rc 0 = a lead-review-free row was there; it is
#                           deleted, so it excuses ONE takeover (a delete that
#                           fails is logged). rc 2 = none: the takeover is a
#                           crashed claim and counts. rc 1 = unreadable.
#   lw_pr_day_ok <slug> <pr>  rc 0 when this box made agent calls for fewer than
#                           LEAD_REVIEW_MAX_PER_PR_DAY (default 4) lead reviews of
#                           that PR this UTC day (state/lead-review/started.tsv).
#                           LW_PR_DAY_MAX is the limit it applied. A claim that
#                           made no agent call (a refusal, a rate limit, paid,
#                           replayed, superseded) is not marked.
#   lw_pr_day_mark <slug> <pr>  one line in started.tsv, at the agent call.
#   lw_pr_day_trip <slug> <pr>  the tripwire fired: ONE lane-alert warn a PR a UTC
#                           day, id lead-trip-<slug_>-<pr>-<day>, marker
#                           state/lead-review/trip-<slug_>-<pr>-<day> written
#                           only after lane-alert rc 0.
#   lw_pr_day_prune         keep today's and yesterday's lines; drop trip markers
#                           older than 2 days.
#   lw_replay <slug> <pr> <sha> <clone>  the patch-same replay. Reads the PR's
#                           verdict rows, takes the newest source=lead MERGE,
#                           MERGE-WITH-NOTES or BLOCK on another head that is not
#                           itself a replay. A BLOCK is never replayed (rc 1: it
#                           leaves its head only through the enqueue's BH-3930
#                           rebound replay). For a MERGE it fetches both heads
#                           and asks ld_classify. Run in the caller's shell (it sets
#                           globals and prints nothing): rc 0 only on
#                           `replay <how>`, with LW_REPLAY_WORD, LW_REPLAY_PREV
#                           and LW_REPLAY_HOW (spaces removed). Any unknown is
#                           rc 1, LW_REPLAY_WHY says why, and the caller reviews
#                           as usual.
#
# READS ARE CACHED for LW_READ_TTL_S seconds (default 15; 0 = read every time):
# the settings rows, the running count and the day's spend. The pool polls
# every 0.2 s, and these reads must not hit D1 at that rate.

_lw_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_lw_log() { [ -n "${LW_LOGFN:-}" ] && "$LW_LOGFN" "$*"; return 0; }
# The clock and the UTC day through printf's builtin %(...)T: these run on the
# pool's serial claim path and its 0.2 s poll, where a fork per call shows.
_lw_now() { printf -v "$1" '%(%s)T' -1; }
_lw_day() { TZ=UTC0 printf -v "$1" "%(${2:-%F})T" -1; }
# _lw_fresh <at> — rc 0 while a read made at epoch <at> is still in the cache
_lw_fresh() {
  local now ttl="${LW_READ_TTL_S:-}"
  case "$ttl" in ''|*[!0-9]*) ttl=15 ;; esac
  [ -n "${1:-}" ] || return 1
  _lw_now now; [ $((now - $1)) -lt "$ttl" ]
}
# _lw_once <tag> <line> — log a line once per process
declare -gA _LW_SAID=()
_lw_once() { [ -n "${_LW_SAID[$1]:-}" ] && return 0; _LW_SAID[$1]=1; _lw_log "$2"; }

lw_items() {
  local slug="${1:-}" out="${2:-}" tsv rc
  [ -n "$slug" ] && [ -n "$out" ] || return 1
  : > "$out" || return 1
  tsv=$(pr_needs_review "$slug"); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  printf '%s\n' "$tsv" | jq -Rc --arg r "$slug" 'split("\t")
    | select(length >= 6 and (.[0] | test("^[0-9]+$")) and (.[1] | test("^[0-9a-f]{40}$")))
    | {repo: $r, pr: (.[0] | tonumber), head_sha: .[1], hotfix: (.[3] == "1"), nudged: (.[4] == "1"),
       approved_at: (if .[5] == "-" then "" else .[5] end), src: "worklist"}' > "$out" 2>/dev/null \
    || { : > "$out"; return 1; }
  [ "$(wc -l < "$out")" -eq "$(printf '%s\n' "$tsv" | wc -l)" ] \
    || _lw_log "needs-review for $slug: $(( $(printf '%s\n' "$tsv" | wc -l) - $(wc -l < "$out") )) malformed rows skipped"
  return 0
}

_LW_CONC_AT="" _LW_CONC_ROW="" _LW_ELSE_AT="" _LW_ELSE=""
LW_CONC_WHY=""
lw_concurrency_ok() {
  local live="${1:-0}" v rc resp
  LW_CONC_WHY=""
  if ! _lw_fresh "$_LW_CONC_AT"; then
    _lw_now _LW_CONC_AT; _LW_CONC_ROW=""
    v=$(setting_get lead_review.concurrency 2>/dev/null); rc=$?
    v=$(printf '%s' "$v" | tr -d '[:space:]')
    case "$rc" in
      0) case "$v" in ''|*[!0-9]*|0*) _lw_once conc-bad "lead_review.concurrency='$v' is not a positive integer; the box cap governs" ;;
           *) _LW_CONC_ROW=$v ;; esac ;;
      2) _lw_once conc-none "no lead_review.concurrency row; the box cap governs" ;;
      *) _lw_once conc-unread "lead_review.concurrency unreadable; the box cap governs" ;;
    esac
  fi
  [ -n "$_LW_CONC_ROW" ] || return 0
  if ! _lw_fresh "$_LW_ELSE_AT"; then
    _lw_now _LW_ELSE_AT; _LW_ELSE=""
    resp=$(_jobs_req GET "/api/jobs?kind=lead_review&status=running&limit=500" 2>/dev/null) \
      && _LW_ELSE=$(printf '%s' "$resp" | jq -r --arg b "${JOBS_BOX:-}" \
           '.jobs | if type == "array" then [.[] | select((.box // "") != $b)] | length else error end' 2>/dev/null)
    case "$_LW_ELSE" in ''|*[!0-9]*) _LW_ELSE="" ;; esac
  fi
  if [ -z "$_LW_ELSE" ]; then
    LW_CONC_WHY=unreadable
    _lw_log "lead_review running count unreadable; no start this pass"
    return 1
  fi
  [ $((_LW_ELSE + live)) -lt "$_LW_CONC_ROW" ] && return 0
  LW_CONC_WHY=full
  return 1
}

_LW_CAP_AT="" _LW_CAP="" _LW_CAP_RC=0 _LW_SPENT_AT="" _LW_SPENT=""
LW_SPEND_WHY="" LW_SPEND_LINE=""
lw_spend_ok() {
  local root day mark
  LW_SPEND_WHY=""; LW_SPEND_LINE=""
  if ! _lw_fresh "$_LW_CAP_AT"; then
    _lw_now _LW_CAP_AT
    _LW_CAP=$(setting_get lead_review.daily_spend_usd 2>/dev/null); _LW_CAP_RC=$?
    _LW_CAP=$(printf '%s' "$_LW_CAP" | tr -d '[:space:]')
    [ "$_LW_CAP_RC" -eq 0 ] && ! [[ "$_LW_CAP" =~ ^[0-9]+(\.[0-9]+)?$ ]] && _LW_CAP_RC=3
  fi
  case "$_LW_CAP_RC" in
    0) ;;
    2) return 0 ;;
    3) LW_SPEND_WHY=unreadable; LW_SPEND_LINE="lead_review.daily_spend_usd='$_LW_CAP' is not a number"; return 1 ;;
    *) LW_SPEND_WHY=unreadable; LW_SPEND_LINE="lead_review.daily_spend_usd unreadable"; return 1 ;;
  esac
  if ! _lw_fresh "$_LW_SPENT_AT"; then
    _lw_now _LW_SPENT_AT; _LW_SPENT=""
    command -v llm_gate_spend_today >/dev/null 2>&1 \
      && _LW_SPENT=$(llm_gate_spend_today lead-review "" lead-review 2>/dev/null)
    [[ "$_LW_SPENT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _LW_SPENT=""
  fi
  if [ -z "$_LW_SPENT" ]; then
    LW_SPEND_WHY=unreadable; LW_SPEND_LINE="the day's lead-review spend is unreadable (cap $_LW_CAP USD)"; return 1
  fi
  awk -v s="$_LW_SPENT" -v c="$_LW_CAP" 'BEGIN { exit !(s + 0 < c + 0) }' && return 0
  LW_SPEND_WHY=cap; LW_SPEND_LINE="$_LW_SPENT of $_LW_CAP USD"
  root=$(_lw_root); [ -n "$root" ] || return 1
  _lw_day day %Y%m%d; mark="$root/state/lead-review/spend-cap-$day"
  [ -e "$mark" ] && return 1
  if "$root/bin/lane-alert.sh" --severity warn --id "lead-spend-cap-$day" lead-review \
       "$LW_SPEND_LINE; no new lead review starts until the row is raised or the day ends" >/dev/null 2>&1; then
    mkdir -p "${mark%/*}" 2>/dev/null; : > "$mark" 2>/dev/null || _lw_log "spend cap alerted but $mark could not be written; this may alert again"
  else
    _lw_log "lane-alert.sh failed for lead-spend-cap-$day; the next start check retries"
  fi
  return 1
}

# _lw_attempt_has <slug> <pr> <kind> <sha> — rc 0 a row, 2 a 404, 1 anything else
#   (a 2xx without the attempt row is not proof of one).
_lw_attempt_has() {
  local q resp rc
  q=$(jq -nr --arg r "$1" --arg n "$2" --arg k "$3" --arg s "$4" \
    '"repo="+($r|@uri)+"&number="+($n|@uri)+"&kind="+($k|@uri)+"&sha="+($s|@uri)') || return 1
  resp=$(_jobs_req GET "/api/pr-attempts?$q" 2>/dev/null); rc=$?
  case "$rc" in
    0) printf '%s' "$resp" | jq -e --arg k "$3" '.attempt.kind == $k' >/dev/null 2>&1 && return 0; return 1 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}
lw_attempts() {
  local n=0 k rc
  [ -n "${1:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]] && [ -n "${3:-}" ] || return 1
  for k in 1 2 3; do
    _lw_attempt_has "$1" "$2" "lead-review-$k" "$3"; rc=$?
    case "$rc" in 0) n=$k ;; 2) break ;; *) return 1 ;; esac
  done
  printf '%s' "$n"
}
lw_attempt_add() { pr_attempt_put "${1:-}" "${2:-}" "lead-review-${4:-}" "${3:-}"; }
lw_release() { pr_attempt_put "${1:-}" "${2:-}" lead-review-free "${3:-}"; }
lw_released() {
  local rc
  [ -n "${1:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]] && [ -n "${3:-}" ] || return 1
  _lw_attempt_has "$1" "$2" lead-review-free "$3"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  pr_attempt_del "$1" "$2" lead-review-free "$3" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && _lw_log "release marker on $1#$2@${3:0:12} not deleted; it can excuse one more takeover"
  return 0
}

# _lw_started <var> — sets <var> to state/lead-review/started.tsv; rc 1 with no root
_lw_started() { local root="${HARNESS:-${H:-}}"; [ -n "$root" ] || return 1; printf -v "$1" '%s/state/lead-review/started.tsv' "$root"; }
LW_PR_DAY_MAX=""
lw_pr_day_ok() {
  local f max n d
  _lw_started f || return 1
  max="${LEAD_REVIEW_MAX_PER_PR_DAY:-}"
  case "$max" in ''|*[!0-9]*|0*) _lw_once prday-bad "LEAD_REVIEW_MAX_PER_PR_DAY='$max' is not a positive integer; using 4"; max=4 ;; esac
  LW_PR_DAY_MAX=$max
  [ -f "$f" ] || return 0
  _lw_day d
  n=$(awk -F'\t' -v d="$d" -v s="$1" -v p="$2" '$1 == d && $2 == s && $3 == p {c++} END {print c + 0}' "$f" 2>/dev/null)
  [ "${n:-0}" -lt "$max" ]
}
lw_pr_day_mark() {
  local f d; _lw_started f || return 1
  [ -d "${f%/*}" ] || mkdir -p "${f%/*}" 2>/dev/null
  _lw_day d
  printf '%s\t%s\t%s\n' "$d" "$1" "$2" >> "$f"
}
lw_pr_day_trip() {
  local root day safe mark
  root=$(_lw_root); [ -n "$root" ] || return 1
  _lw_day day %Y%m%d; safe=$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')
  mark="$root/state/lead-review/trip-$safe-$2-$day"
  [ -e "$mark" ] && return 0
  if "$root/bin/lane-alert.sh" --severity warn --id "lead-trip-$safe-$2-$day" lead-review \
       "$1#$2 had agent calls for $LW_PR_DAY_MAX lead reviews today (LEAD_REVIEW_MAX_PER_PR_DAY=$LW_PR_DAY_MAX), so no new lead review of it starts on this box until the UTC day ends. Look at why it is reviewed over and over, or raise the row." >/dev/null 2>&1; then
    mkdir -p "${mark%/*}" 2>/dev/null; : > "$mark" 2>/dev/null || _lw_log "tripwire alerted but $mark could not be written; this may alert again"
  else
    _lw_log "lane-alert.sh failed for lead-trip-$safe-$2-$day; the next skip retries"
  fi
  return 0
}
lw_pr_day_prune() {
  local f t y now; _lw_started f || return 1
  [ -d "${f%/*}" ] && find "${f%/*}" -maxdepth 1 -name 'trip-*' -mtime +2 -delete 2>/dev/null
  [ -f "$f" ] || return 0
  _lw_day t; _lw_now now; TZ=UTC0 printf -v y '%(%F)T' "$((now - 86400))"
  awk -F'\t' -v t="$t" -v y="$y" '$1 == t || $1 == y' "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f"
}

LW_REPLAY_WHY="" LW_REPLAY_WORD="" LW_REPLAY_PREV="" LW_REPLAY_HOW=""
lw_replay() {
  local slug="${1:-}" pr="${2:-}" sha="${3:-}" clone="${4:-}" resp ph pw cls how
  LW_REPLAY_WHY=""; LW_REPLAY_WORD=""; LW_REPLAY_PREV=""; LW_REPLAY_HOW=""
  if ! command -v patch_same_fetch >/dev/null 2>&1 || ! command -v ld_classify >/dev/null 2>&1; then
    LW_REPLAY_WHY="patch-same or lead-delta lib not loaded"; return 1
  fi
  # A truncated history cannot prove which lead row is newest: unreadable.
  resp=$(JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$slug&pr=$pr" 2>/dev/null) \
    && printf '%s' "$resp" | jq -e '(.rows | type) == "array" and .truncated != true' >/dev/null 2>&1 \
    || { LW_REPLAY_WHY="verdicts unreadable"; return 1; }
  IFS=$'\t' read -r ph pw < <(printf '%s' "$resp" | jq -r --arg h "$sha" '[.rows[] | select(.source == "lead"
      and ((.head_sha // "") | ascii_downcase) != $h
      and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK"))
      and (((.note // "") | contains("lead-replay:")) | not))]
    | max_by(.id) // empty | "\(.head_sha | ascii_downcase)\t\(.verdict)"' 2>/dev/null)
  [[ "${ph:-}" =~ ^[0-9a-f]{40}$ ]] || { LW_REPLAY_WHY="no earlier lead verdict"; return 1; }
  # A BLOCK is never replayed from the lane: it leaves its own head only through
  # the enqueue's BH-3930 rebound replay (bin/lead-review-enqueue.sh, BH-5294).
  # A main-merge after a BLOCK, or a person's request, is a fresh review.
  [ "$pw" != BLOCK ] || { LW_REPLAY_WHY="the newest lead verdict (${ph:0:12}) is a BLOCK; only a MERGE is replayed"; return 1; }
  patch_same_fetch "$clone" "$ph" "$sha" "$pr" || { LW_REPLAY_WHY="fetch of ${ph:0:12}/${sha:0:12} failed ($PS_FETCH_ERR)"; return 1; }
  cls=$(ld_classify "$clone" origin/main "$ph" "$sha" "$slug" "$pw")
  case "$cls" in
    "replay "*) how="${cls#replay }"; LW_REPLAY_WORD="$pw"; LW_REPLAY_PREV="$ph"; LW_REPLAY_HOW="${how// /}"; return 0 ;;
  esac
  LW_REPLAY_WHY="since ${ph:0:12}: ${cls:-no class}"
  return 1
}
