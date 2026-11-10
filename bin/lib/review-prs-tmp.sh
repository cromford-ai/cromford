#!/bin/bash
# bin/lib/review-prs-tmp.sh — BH-6130: the /tmp scratch of bin/review-prs.sh's
# pool workers and the once-per-episode report of a pool capped by
# /tmp. Sourced by bin/review-prs.sh, never executed; defining functions is its
# only effect at source time. The functions read the lane's globals: PROJECT,
# LOG, STAMP, REPO_DIR, RPOOL_K, RPOOL_CAP_BY, and the pool lib's
# _rpool_tmp_free_mb and _rpool_knob.
#
# Test seams (env only, never registry knobs): RP_TMP_PROC (the /proc to read
# a pid's cmdline from), RP_TMP_REPORT_NOW (epoch), RP_TMP_DU_TIMEOUT_S (20).

# A review agent that checks out the PR head does it under its worker's own
# dir, <tmp>/review-prs-wk-<tick pid>/<worker id> (the prompt says so). The
# worker removes it on exit, the tick removes a SIGKILLed worker's on collect
# and the root on exit, and the next tick removes the root of a tick that is
# no longer running (rp_scratch_reap). tmp-sweep's review-prs-* pattern is the
# last backstop. A sandbox with no REVIEW_POOL_TMP_PATH uses $HARNESS/tmp, so
# no suite scans or deletes in the real /tmp.
rp_tmp_base() {
  if [ -z "${REVIEW_POOL_TMP_PATH:-}" ] && [ "${HARNESS_TEST_SANDBOX:-0}" = 1 ]; then printf '%s' "${HARNESS:-${H:-}}/tmp"
  else printf '%s' "${REVIEW_POOL_TMP_PATH:-/tmp}"; fi
}
# rp_scratch_reap — remove <base>/review-prs-wk-<pid> whose <pid> is not a live
# review-prs.sh. No age floor: the owner is dead, so the dir is stale. Names
# that are not review-prs-wk-<digits>, and symlinks, are kept. The log line
# states the bytes freed (`du -sk` of each removed dir before its rm, bounded
# by RP_TMP_DU_TIMEOUT_S). A removed dir that du could not measure makes it
# `freed at least <bytes> bytes (<u> dir(s) not measured)`. A dir whose rm
# failed counts in neither number.
rp_scratch_reap() {
  local base d pid proc="${RP_TMP_PROC:-/proc}" n=0 kb freed_kb=0 unmeasured=0 freed
  base=$(rp_tmp_base)
  for d in "$base"/review-prs-wk-*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    pid=${d##*/review-prs-wk-}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    grep -qa 'review-prs\.sh' "$proc/$pid/cmdline" 2>/dev/null && continue
    kb=$(timeout "${RP_TMP_DU_TIMEOUT_S:-20}" du -sk -- "$d" 2>/dev/null | awk 'NR==1{print $1}')
    rm -rf -- "$d" 2>/dev/null
    [ -e "$d" ] && continue
    n=$((n + 1))
    case "$kb" in ''|*[!0-9]*) unmeasured=$((unmeasured + 1)) ;; *) freed_kb=$((freed_kb + kb)) ;; esac
  done
  freed="freed $((freed_kb * 1024)) bytes"
  [ "$unmeasured" -gt 0 ] && freed="freed at least $((freed_kb * 1024)) bytes ($unmeasured dir(s) not measured)"
  [ "$n" -gt 0 ] && echo "$(STAMP) [$PROJECT] review-prs: removed $n stale scratch dir(s) under $base, $freed" >> "$LOG"
  [ -e "$REPO_DIR/.git" ] && git -C "$REPO_DIR" worktree prune 2>/dev/null
  return 0
}

# A pool capped below 3 by /tmp is reported to Sentry once per cap episode,
# and again each REVIEW_TMP_CAPPED_REPORT_S while the episode lasts (registry
# knob on the review-prs lane, default 86400; 0 = every capped tick), with the
# free space, the threshold, the count of review-prs dirs and the
# REVIEW_TMP_TOP_N largest (default 5) entries at the top of the tmp path. It is
# sent only after REVIEW_TMP_CAPPED_MIN_TICKS (default 3) consecutive capped
# ticks on the box (BH-9035). Inside the window a cap that drops below the last
# reported concurrency is reported again (BH-6132); the same or a higher cap is
# not. The window is claimed BEFORE the measure and the send, so
# a failed send still counts. The marker `<epoch> <concurrency>` has no project
# in its name: every project on the box shares it. A BH-6130 marker has no
# concurrency and only the window applies to it. An episode ends when a tick
# that is not capped by /tmp measures free space at or above the threshold
# (rp_tmp_episode_end removes the marker), so the next cap is due at once
# (BH-6133). The per-review need is REVIEW_WORKER_TMP_MB (registry knob,
# default 256), read through _rpool_knob WORKER_TMP_MB.
# _rp_tmp_state_dir <harness> — make the dir the marker and the streak live in.
# The one `mkdir` of state/ in this file: the marker and the streak are classed
# box-local in catalog/state-paths.d/9035-review-prs-tmp-capped.json, and
# tests/no-state-files.bh-4159-test.sh counts each raw state/ site. Always rc 0.
_rp_tmp_state_dir() { mkdir -p "$1/state" 2>/dev/null; return 0; }
# rp_tmp_report_due — rc 0: this tick claimed the window; `<trigger>
# <previous concurrency>` on stdout, trigger `window` or `cap_lowered`, the
# previous concurrency empty when unknown. rc 3: not due, `<epoch>
# <concurrency>` of the marker on stdout. rc 1: the marker could not be locked
# or written.
rp_tmp_report_due() {
  local h="${HARNESS:-${H:-}}" f now win k="${RPOOL_K:-}"
  [ -n "$h" ] || return 1
  f="$h/state/review-prs-tmp-capped.last"
  now="${RP_TMP_REPORT_NOW:-$(date -u +%s)}"; win="${REVIEW_TMP_CAPPED_REPORT_S:-86400}"
  case "$now" in ''|*[!0-9]*) now=$(date -u +%s) ;; esac
  case "$win" in ''|*[!0-9]*) win=86400 ;; esac
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  _rp_tmp_state_dir "$h"
  ( exec 9>>"$f.lock" || exit 1
    flock -w 2 9 || exit 1
    last=""; lastk=""; trig=window
    [ -f "$f" ] && read -r last lastk _ < "$f" 2>/dev/null
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    case "$lastk" in ''|0|*[!0-9]*) lastk="" ;; esac
    if [ "$now" -ge "$last" ] && [ $((now - last)) -lt "$win" ]; then
      if [ -n "$lastk" ] && [ "$k" -lt "$lastk" ]; then trig=cap_lowered
      else printf '%s %s' "$last" "$lastk"; exit 3; fi
    fi
    printf '%s %s\n' "$now" "$k" > "$f.tmp" 2>/dev/null && mv -fT "$f.tmp" "$f" 2>/dev/null \
      && { printf '%s %s' "$trig" "$lastk"; exit 0; }
    rm -f "$f.tmp" 2>/dev/null; exit 1 ) 2>/dev/null
}
# rp_tmp_episode_end — end the cap episode when measured free /tmp is at or
# above TMP_MIN_MB + 3 x WORKER_TMP_MB, the point where /tmp no longer caps the
# pool below 3. It reads the space, not RPOOL_CAP_BY: a tick capped by
# REVIEW_BOX_MAX, memory or a low REVIEW_CONCURRENCY must not end a box-wide
# episode while /tmp is still low. An unreadable df or a lock timeout keeps the
# episode. It also removes the capped-tick streak (BH-9035), so the next cap
# counts from 1. With no marker (no report was sent) the log line says
# `capped-tick streak reset`, not `cap episode ended`. Always rc 0.
rp_tmp_episode_end() {
  local h="${HARNESS:-${H:-}}" f s free min per thr had=""
  [ -n "$h" ] || return 0
  f="$h/state/review-prs-tmp-capped.last"; s="$h/state/review-prs-tmp-capped.streak"
  [ -e "$f" ] || [ -e "$s" ] || return 0
  free=$(_rpool_tmp_free_mb) || return 0
  min=$(_rpool_knob TMP_MIN_MB 1536); per=$(_rpool_knob WORKER_TMP_MB 256)
  thr=$((min + 3 * per))
  [ "$free" -ge "$thr" ] || return 0
  [ -e "$f" ] && had=1
  ( exec 9>>"$f.lock" || exit 1
    flock -w 2 9 || exit 1
    rm -f "$f" "$s" 2>/dev/null ) 2>/dev/null
  [ -e "$f" ] || [ -e "$s" ] && return 0
  if [ -n "$had" ]; then
    echo "$(STAMP) [$PROJECT] review-prs: /tmp recovered (${free}MB free, threshold ${thr}MB); cap episode ended" >> "$LOG"
  else
    echo "$(STAMP) [$PROJECT] review-prs: /tmp recovered (${free}MB free, threshold ${thr}MB); capped-tick streak reset" >> "$LOG"
  fi
  return 0
}
# rp_tmp_streak_bump — BH-9035: add this tick to the box-wide count of
# consecutive review-prs ticks capped by /tmp, state/review-prs-tmp-capped.streak
# (`<count> <first_epoch>`), under the marker's lock. Every project on the box
# adds to one count; rp_tmp_episode_end removes it. Prints the new count, rc 0.
# rc 1, nothing printed, when the lock or the write fails.
rp_tmp_streak_bump() {
  local h="${HARNESS:-${H:-}}" f s now
  [ -n "$h" ] || return 1
  f="$h/state/review-prs-tmp-capped.last"; s="$h/state/review-prs-tmp-capped.streak"
  now="${RP_TMP_REPORT_NOW:-$(date -u +%s)}"
  case "$now" in ''|*[!0-9]*) now=$(date -u +%s) ;; esac
  _rp_tmp_state_dir "$h"
  ( exec 9>>"$f.lock" || exit 1
    flock -w 2 9 || exit 1
    c=""; first=""
    [ -f "$s" ] && read -r c first _ < "$s" 2>/dev/null
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    case "$first" in ''|*[!0-9]*) first="" ;; esac
    [ "$c" -gt 0 ] && [ -n "$first" ] || first=$now
    c=$((c + 1))
    printf '%s %s\n' "$c" "$first" > "$s.tmp" 2>/dev/null && mv -fT "$s.tmp" "$s" 2>/dev/null \
      && { printf '%s' "$c"; exit 0; }
    rm -f "$s.tmp" 2>/dev/null; exit 1 ) 2>/dev/null
}
# rp_tmp_top — a JSON array of the REVIEW_TMP_TOP_N largest (default 5)
# top-level entries of the tmp path, [{path, mb}], largest first; [] when du
# times out or reads nothing. No `du -x`: on an overlay root a file reports
# another device than its dir and -x skips it.
rp_tmp_top() {
  local base out n="${REVIEW_TMP_TOP_N:-5}" # 5: fallback of the row lane.review-prs.review_tmp_top_n
  case "$n" in ''|*[!0-9]*) n=5 ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le 20 ] || n=5
  base=$(rp_tmp_base)
  out=$(timeout "${RP_TMP_DU_TIMEOUT_S:-20}" du -sm -- "$base"/* "$base"/.[!.]* 2>/dev/null \
    | sort -rn | head -n "$n" \
    | jq -Rsc '[split("\n")[] | select(length > 0) | capture("^(?<mb>[0-9]+)\\s+(?<path>.*)$") | {path, mb: (.mb | tonumber)}]' 2>/dev/null)
  [ -n "$out" ] && printf '%s' "$out" || printf '[]'
}
# rp_tmp_capped_report — called by the lane when the pool is capped below 3 by
# /tmp. It first adds the tick to the streak (BH-9035): below
# REVIEW_TMP_CAPPED_MIN_TICKS consecutive capped ticks it logs `capped tick <n>
# of <min>, not reported` and returns 1 without claiming the window. A streak
# it cannot write is logged (`tmp streak not counted`) and does not hold the
# report. rc 0 when this tick claimed the window and must send; the extra then
# carries `trigger`, `previous_concurrency` (null when unknown), `capped_ticks`
# (null when the streak was not counted) and `min_ticks`. It writes the lane
# log line and sets RP_TMP_MSG and RP_TMP_EXTRA (the event's extra JSON) for
# the lane's sentry_report call. rc 1 otherwise, with RP_TMP_MSG empty.
RP_TMP_MSG=""; RP_TMP_EXTRA=""
rp_tmp_capped_report() {
  local base out last lastk trig prevk rc free min per thr fstype top toptxt d dirs=0 ticks="" mint
  RP_TMP_MSG=""; RP_TMP_EXTRA=""
  mint="${REVIEW_TMP_CAPPED_MIN_TICKS:-3}" # 3: fallback of the row lane.review-prs.review_tmp_capped_min_ticks
  case "$mint" in ''|*[!0-9]*) mint=3 ;; esac
  [ "$mint" -ge 1 ] && [ "$mint" -le 100 ] || mint=3
  if ticks=$(rp_tmp_streak_bump) && [ -n "$ticks" ]; then
    if [ "$ticks" -lt "$mint" ]; then
      echo "$(STAMP) [$PROJECT] review-prs: /tmp capped at $RPOOL_K; capped tick $ticks of $mint, not reported" >> "$LOG"
      return 1
    fi
  else
    ticks=""
    echo "$(STAMP) [$PROJECT] review-prs: tmp streak not counted: ${HARNESS:-${H:-}}/state/review-prs-tmp-capped.streak not writable" >> "$LOG"
  fi
  out=$(rp_tmp_report_due); rc=$?
  case "$rc" in
    0) read -r trig prevk <<<"$out" ;;
    3) read -r last lastk <<<"$out"
       echo "$(STAMP) [$PROJECT] review-prs: /tmp capped at $RPOOL_K; not reported, last report $(date -u -d "@$last" '+%Y-%m-%dT%H:%M:%SZ') at concurrency ${lastk:-unknown} (window ${REVIEW_TMP_CAPPED_REPORT_S:-86400}s)" >> "$LOG"
       return 1 ;;
    *) echo "$(STAMP) [$PROJECT] review-prs: tmp report skipped: marker ${HARNESS:-${H:-}}/state/review-prs-tmp-capped.last not writable" >> "$LOG"
       return 1 ;;
  esac
  base=$(rp_tmp_base)
  free=$(_rpool_tmp_free_mb) || free=null
  min=$(_rpool_knob TMP_MIN_MB 1536); per=$(_rpool_knob WORKER_TMP_MB 256)
  thr=$((min + 3 * per))
  fstype=$(stat -f -c %T "$base" 2>/dev/null)
  top=$(rp_tmp_top)
  for d in "$base"/review-prs-*; do [ -d "$d" ] && [ ! -L "$d" ] && dirs=$((dirs + 1)); done
  toptxt=$(jq -r 'map("\(.path) \(.mb)MB") | join(", ")' <<<"$top" 2>/dev/null)
  echo "$(STAMP) [$PROJECT] review-prs: concurrency capped at $RPOOL_K by $base: ${free}MB free, threshold ${thr}MB (floor ${min}MB + 3 x ${per}MB); top: ${toptxt:-none}; reported (${trig:-window})" >> "$LOG"
  RP_TMP_MSG="review-prs concurrency capped at $RPOOL_K by free space under $base: ${free}MB free, threshold ${thr}MB, $dirs review-prs dirs"
  RP_TMP_EXTRA=$(jq -nc --arg p "$PROJECT" --argjson k "$RPOOL_K" --argjson free "$free" --argjson min "$min" \
      --argjson per "$per" --argjson thr "$thr" --arg path "$base" --arg fs "$fstype" --argjson top "$top" \
      --argjson dirs "$dirs" --arg tr "${trig:-window}" --arg pk "$prevk" --arg ct "$ticks" --argjson mt "$mint" \
      '{project:$p, concurrency:$k, free_mb:$free, tmp_min_mb:$min, worker_tmp_mb:$per, threshold_mb:$thr,
        tmp_path:$path, fstype:$fs, top:$top, review_prs_dirs:$dirs, trigger:$tr,
        previous_concurrency:(if $pk == "" then null else ($pk | tonumber) end),
        capped_ticks:(if $ct == "" then null else ($ct | tonumber) end), min_ticks:$mt}' 2>/dev/null) \
    || RP_TMP_EXTRA=$(jq -nc --arg p "$PROJECT" --argjson k "$RPOOL_K" --arg tr "${trig:-window}" --arg ct "$ticks" --argjson mt "$mint" \
         '{project:$p, concurrency:$k, trigger:$tr, capped_ticks:(if $ct == "" then null else ($ct | tonumber) end), min_ticks:$mt}')
  return 0
}
