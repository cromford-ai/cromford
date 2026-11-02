#!/bin/bash
# gh-identity: raw-by-design — `bin/box-move.sh proof` is read-only by contract (BH-8324 E1: no file on the hub changes), and minting an App token writes the token and settings caches on the hub, so its two read-only GitHub reads run on the token the operator already holds.
# bin/lib/box-move/proof.sh — the 24 h before/after window of
# `bin/box-move.sh proof` (BH-8324, MKF-9). Sourced by bin/box-move.sh after
# common.sh and cutover.sh (bm_now, bm_step_status, bm_rows_load). Read-only:
# it writes no file, flag, row or alert. The runbook is
# docs/notes/2026-10-28-BH-8324-MKF-9-cutover.md.
#
#   bm_proof_window <oldbox> <new box address>
#       The windows come from $BM_STATE/steps.tsv: before = the W seconds that
#       end at the last `B2 ok` (the old cron stopped), after = the W seconds
#       that start at the last `B5 ok` (the new cron started); since is in,
#       until is out. W is BM_PROOF_WINDOW_S. The comparison runs only when the
#       last B5 row is `ok`; else one `window: none (<why>)` line and no remote
#       read. Per project of old-rows.tsv it prints one `count` line per lane:
#       verdict pass when after >= before - BM_PROOF_SLACK, fail when lower, NA
#       when a side was not measured or the after window is not over yet. A
#       value it could not measure is NA(<why>), never 0 (D11, D12). The
#       `rollback_drill` line (the newest `rollback ok` row with elapsed_s,
#       against BM_ROLLBACK_BUDGET_S) prints in every case. The last line is
#       `proof verdict=pass|fail|NA`: fail if any verdict fails, else NA if any
#       is NA (or there is no window), else pass.
#
# Counters (log stamps `YYYY-MM-DD HH:MM:SSZ`, compared as strings; each match
# is a fixed string at column 22, the bracketed tag after the stamp, so
# project-6-os never counts project-6-os2 or project-6-desktop):
#   triage_ticks  `[<p>] rc=` in logs/<p>.log (bin/run-triage.sh); before on
#                 the old box, after on the new box, both over ssh
#   pool_spawns   `[pool/<p>] ` and `: launch→first push ` in the hub
#                 logs/fly-pool.log (bin/fly-pool.sh, one line per spawn)
#   lead_reviews  `[pool/<p>] pool lead review reaped for LR-` (same log)
#   fix_rounds    GET /api/fix-rounds?project=<p>&status=done|adopted rows with
#                 finished_at in the window (an adopted round finished first)
#   merges        GitHub REST search `repo:<r> is:pr is:merged merged:A..B`
#                 total_count; mergify_* counts merged_by logins that start
#                 with "mergify" (one REST read per PR, NA past one page)
#   lane_silent   `[jobs-watchdog] LANE SILENT: <p>@` in the hub
#                 logs/ALERTS.log, after window only; pass at 0
# A log is read with its `.1` and `*.gz` rotations. A missing log is
# NA(missing); a log whose oldest stamp is after the window start is
# NA(partial oldest=<stamp>).

# $1 log, $2 since, $3 until, $4 the tag at column 22, $5 a second fixed
# string ("" = none), $6 the awk program. Prints `missing`, or
# `n=<count> oldest=<stamp>`; rc 1 on a read error.
BM_S_PW_COUNT='fs=(); for f in "$1" "$1".1 "$1"*.gz; do [ -f "$f" ] && fs+=("$f"); done
[ "${#fs[@]}" -gt 0 ] || { echo missing; exit 0; }
set -o pipefail
for f in "${fs[@]}"; do zcat -f "$f" || exit 1; done | LC_ALL=C awk -v s="$2" -v u="$3" -v p="$4" -v c="$5" "$6"'
BM_AWK_PW='{ st = substr($0, 1, 20) }
st !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { next }
{ if (o == "" || st < o) o = st }
st >= s && st < u && substr($0, 22, length(p)) == p && (c == "" || index($0, c) > 0) { n++ }
END { printf "n=%d oldest=%s\n", n, o }'

bm_pw_epoch() { [ -n "$1" ] || return 1; date -u -d "$1" +%s 2>/dev/null; }
bm_pw_stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
bm_pw_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# bm_pw_judge <since stamp> — turn one BM_S_PW_COUNT answer (stdin) and its rc
# ($2) into a count or NA(<why>). $3 is the NA text for a failed read.
bm_pw_judge() {
  local out rc="$2" n o
  out=$(cat)
  if [ "$rc" -ne 0 ]; then echo "NA($3)"; return; fi
  [ "$out" = missing ] && { echo "NA(missing)"; return; }
  n=$(sed -n 's/^n=\([0-9]*\) oldest=.*/\1/p' <<<"$out")
  o=$(sed -n 's/^n=[0-9]* oldest=//p' <<<"$out")
  [ -n "$n" ] || { echo "NA(bad answer)"; return; }
  [ -n "$o" ] || { echo "NA(empty)"; return; }
  if [[ "$o" > "$1" ]]; then echo "NA(partial oldest=${o/ /T})"; return; fi
  echo "$n"
}
# bm_pw_hub <log> <since> <until> <tag> [<fixed>] — a count from a hub log.
bm_pw_hub() {
  local out rc
  out=$(bash -c "$BM_S_PW_COUNT" pw "$1" "$2" "$3" "$4" "${5:-}" "$BM_AWK_PW" 2>/dev/null); rc=$?
  bm_pw_judge "$2" "$rc" "read rc=$rc" <<<"$out"
}
# bm_pw_remote <ip> <harness> <label> <log rel> <since> <until> <tag> — a count
# from a log on a box, over ssh.
bm_pw_remote() {
  local out rc why
  out=$(bm_sh "$1" "$BM_S_PW_COUNT" "$2/$4" "$5" "$6" "$7" "" "$BM_AWK_PW" 2>/dev/null); rc=$?
  why="read rc=$rc on $3"; [ "$rc" -eq 255 ] && why="$3 unreachable"
  bm_pw_judge "$5" "$rc" "$why" <<<"$out"
}

# bm_pw_fix_load <project> — PW_FIX_STAMPS (one `YYYY-MM-DD HH:MM:SSZ` per
# finished round) or PW_FIX_NA. 500 is the route's LIST_MAX (a protocol bound
# in worker/jobs/src/routes/fix-rounds.js, not a knob); more rows is
# NA(truncated). The worker is read in a subshell with no JOBS_HARNESS, so the
# transport's degraded log and alert write nothing.
bm_pw_fix_load() {
  local p="$1" st out rc
  PW_FIX_STAMPS=""; PW_FIX_NA=""
  for st in done adopted; do
    # shellcheck source=bin/lib/jobs/req.sh
    out=$( JOBS_HARNESS=""; JOBS_ALERT=0; . "$BIN/lib/jobs/req.sh" || exit 70
           _jobs_req GET "/api/fix-rounds?project=$p&status=$st&limit=500" ); rc=$?
    [ "$rc" -eq 0 ] || { PW_FIX_NA="NA(worker rc=$rc)"; return; }
    case "$(jq -r '.truncated' <<<"$out" 2>/dev/null)" in
      false) ;;
      true) PW_FIX_NA="NA(truncated)"; return ;;
      *) PW_FIX_NA="NA(worker bad answer)"; return ;;
    esac
    PW_FIX_STAMPS+=$(jq -r '.fix_round_jobs[] | .finished_at // empty | .[0:19] | sub("T"; " ") + "Z"' <<<"$out")$'\n'
  done
}
bm_pw_fix_count() { # <since> <until>
  if [ -n "$PW_FIX_NA" ]; then echo "$PW_FIX_NA"; return; fi
  LC_ALL=C awk -v s="$1" -v u="$2" '$0 >= s && $0 < u {n++} END {print n + 0}' <<<"$PW_FIX_STAMPS"
}

# bm_pw_merges <repo> <since epoch> <until epoch> — PW_MERGES and PW_MERGIFY.
# per_page=100 is one page of the search API; past it the total stays exact
# and only the mergify count is NA(truncated).
bm_pw_merges() {
  local repo="$1" q out rc total got n login m=0
  q="repo:$repo is:pr is:merged merged:$(date -u -d "@$2" '+%Y-%m-%dT%H:%M:%S+00:00')..$(date -u -d "@$(( $3 - 1 ))" '+%Y-%m-%dT%H:%M:%S+00:00')"
  out=$(gh api -X GET search/issues -f q="$q" -f per_page=100 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { PW_MERGES="NA(gh rc=$rc)"; PW_MERGIFY="$PW_MERGES"; return; }
  total=$(jq -r '.total_count' <<<"$out" 2>/dev/null)
  bm_is_uint "$total" || { PW_MERGES="NA(gh bad answer)"; PW_MERGIFY="$PW_MERGES"; return; }
  [ "$(jq -r '.incomplete_results' <<<"$out")" = false ] || { PW_MERGES="NA(incomplete)"; PW_MERGIFY="$PW_MERGES"; return; }
  PW_MERGES="$total"
  got=$(jq -r '.items | length' <<<"$out")
  [ "$got" = "$total" ] || { PW_MERGIFY="NA(truncated)"; return; }
  for n in $(jq -r '.items[].number' <<<"$out"); do
    login=$(gh api "repos/$repo/pulls/$n" 2>/dev/null | jq -r '.merged_by.login // empty'); rc=$?
    [ "$rc" -eq 0 ] || { PW_MERGIFY="NA(gh pull $n)"; return; }
    case "$login" in mergify*) m=$((m+1)) ;; esac
  done
  PW_MERGIFY="$m"
}

# bm_pw_verdict <before> <after> — pass|fail|NA (PW_PARTIAL=1 is NA).
bm_pw_verdict() {
  [ "$PW_PARTIAL" -eq 0 ] && bm_is_uint "$1" && bm_is_uint "$2" || { echo NA; return; }
  if [ "$2" -ge $(( $1 - BM_PROOF_SLACK )) ]; then echo pass; else echo fail; fi
}
bm_pw_tally() { case "$1" in fail) PW_FAIL=1 ;; NA) PW_NA=1 ;; esac; }
bm_pw_after() { if [ "$PW_PARTIAL" -eq 1 ]; then echo "$1(partial)"; else echo "$1"; fi; }
bm_pw_line() { # <project> <counter> <before> <after> [extra]
  local v; v=$(bm_pw_verdict "$3" "$4"); bm_pw_tally "$v"
  echo "count $1 $2 before=$3 after=$(bm_pw_after "$4") verdict=$v${5:+ $5}"
}

bm_pw_drill() {
  local el v=NA
  el=$(awk -F'\t' '$2 == "rollback" && $3 == "ok" && match($4, /elapsed_s=[0-9]+/) {v = substr($4, RSTART + 10, RLENGTH - 10)} END {print v}' \
    "$BM_STATE/steps.tsv" 2>/dev/null)
  if bm_is_uint "$el"; then
    if [ "$el" -le "$BM_ROLLBACK_BUDGET_S" ]; then v=pass; else v=fail; fi
  fi
  bm_pw_tally "$v"
  echo "rollback_drill elapsed_s=${el:-none} budget_s=$BM_ROLLBACK_BUDGET_S verdict=$v"
}

bm_proof_window() {
  local old="$1" nip="$2" f="$BM_STATE/steps.tsv" why="" b5 b2 e2 e5 now w="$BM_PROOF_WINDOW_S"
  local bs bu as au p tb ta repo mb ma gb ga fb fa
  PW_FAIL=0; PW_NA=0; PW_PARTIAL=0
  if [ ! -s "$f" ]; then why="no steps.tsv"
  elif [ "$(bm_step_status B5)" != ok ]; then why="the last B5 row is $(bm_step_status B5 | grep . || echo absent), not ok"
  else
    b2=$(awk -F'\t' '$2 == "B2" && $3 == "ok" {v = $1} END {print v}' "$f")
    b5=$(awk -F'\t' '$2 == "B5" && $3 == "ok" {v = $1} END {print v}' "$f")
    e2=$(bm_pw_epoch "$b2"); e5=$(bm_pw_epoch "$b5")
    if [ -z "$b2" ]; then why="no B2 ok row"
    elif [ -z "$e2" ] || [ -z "$e5" ]; then why="a bad stamp in steps.tsv"
    elif ! bm_rows_load; then why="no usable old-rows.tsv"
    fi
  fi
  if [ -n "$why" ]; then
    echo "window: none ($why)"
    bm_pw_drill
    echo "proof verdict=NA"
    return 0
  fi
  now=$(bm_now)
  [ "$now" -ge $(( e5 + w )) ] || PW_PARTIAL=1
  bs=$(bm_pw_stamp $(( e2 - w ))); bu=$(bm_pw_stamp "$e2")
  as=$(bm_pw_stamp "$e5"); au=$(bm_pw_stamp $(( e5 + w )))
  echo "window before=$(bm_pw_iso $(( e2 - w )))..$(bm_pw_iso "$e2") after=$(bm_pw_iso "$e5")..$(bm_pw_iso $(( e5 + w ))) width_s=$w after_state=$([ "$PW_PARTIAL" -eq 1 ] && echo partial || echo complete)"
  for p in $BM_PROJECTS; do
    tb=$(bm_pw_remote "$BM_OLD_IP" "$BM_OH" "old box" "logs/$p.log" "$bs" "$bu" "[$p] rc=")
    ta=$(bm_pw_remote "$nip" "$BM_TH" "new box" "logs/$p.log" "$as" "$au" "[$p] rc=")
    bm_pw_line "$p" triage_ticks "$tb" "$ta"
    bm_pw_line "$p" pool_spawns \
      "$(bm_pw_hub "$HARNESS/logs/fly-pool.log" "$bs" "$bu" "[pool/$p] " ": launch→first push ")" \
      "$(bm_pw_hub "$HARNESS/logs/fly-pool.log" "$as" "$au" "[pool/$p] " ": launch→first push ")"
    bm_pw_line "$p" lead_reviews \
      "$(bm_pw_hub "$HARNESS/logs/fly-pool.log" "$bs" "$bu" "[pool/$p] pool lead review reaped for LR-")" \
      "$(bm_pw_hub "$HARNESS/logs/fly-pool.log" "$as" "$au" "[pool/$p] pool lead review reaped for LR-")"
    bm_pw_fix_load "$p"
    fb=$(bm_pw_fix_count "$bs" "$bu"); fa=$(bm_pw_fix_count "$as" "$au")
    bm_pw_line "$p" fix_rounds "$fb" "$fa"
    repo=$("$BIN/fleet-conf.sh" "$p" repo 2>/dev/null)
    if [ -n "$repo" ]; then
      bm_pw_merges "$repo" $(( e2 - w )) "$e2"; mb="$PW_MERGES"; gb="$PW_MERGIFY"
      bm_pw_merges "$repo" "$e5" $(( e5 + w )); ma="$PW_MERGES"; ga="$PW_MERGIFY"
    else
      mb="NA(no repo)"; ma="$mb"; gb="$mb"; ga="$mb"
    fi
    bm_pw_line "$p" merges "$mb" "$ma" "mergify_before=$gb mergify_after=$ga"
    ta=$(bm_pw_hub "$HARNESS/logs/ALERTS.log" "$as" "$au" "[jobs-watchdog] LANE SILENT: $p@")
    if [ "$PW_PARTIAL" -eq 1 ] || ! bm_is_uint "$ta"; then tb=NA
    elif [ "$ta" -eq 0 ]; then tb=pass; else tb=fail; fi
    bm_pw_tally "$tb"
    echo "count $p lane_silent after=$(bm_pw_after "$ta") verdict=$tb"
  done
  bm_pw_drill
  if [ "$PW_FAIL" -eq 1 ]; then echo "proof verdict=fail"
  elif [ "$PW_NA" -eq 1 ]; then echo "proof verdict=NA"
  else echo "proof verdict=pass"; fi
}
