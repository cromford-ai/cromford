#!/bin/bash
# gh-identity: app-token
# bin/size-remeasure.sh — the 14-day size re-measure one-shot on #6025 (BH-9502,
# slice C5 of #9441, scope item 6 from comment 6780689984).
#
#   size-remeasure.sh              the hub lane (daily, cron/lanes/781-size-remeasure.cron)
#   size-remeasure.sh --dry-run    print the gate verdict, both tables and the comment body
#   size-remeasure.sh buckets --builds <dir> [--days N]
#                                  the local bucket count only; no network call
#
# THE LANE, in order:
#   1. state/size-remeasure/posted exists -> log `done: posted <url>`, exit 0, no call.
#   2. Each issue in SIZE_REMEASURE_GATE_ISSUES (9441 9437) must be closed with
#      state_reason=completed. Open or not_planned -> `not due`. A failed or
#      non-JSON read -> `not judged`. Both exit 0. A failed read is never due.
#   3. due = the later closed_at + SIZE_REMEASURE_DELAY_DAYS. now < due -> exit 0.
#   4. Every page of the #<target> thread: a comment with the hidden marker
#      means it already posted -> write `posted` with that URL, exit 0. A read
#      that fails or a page cap hit -> no post, go to 9.
#   5. bin/split-chain-report.sh --days <window> --slug <slug> as a subprocess.
#      Exit 2 (INCOMPLETE) or any other non-zero -> no post, go to 9.
#   6. The bucket count over $HARNESS/builds (see BUCKETS).
#   7. Compose one comment: the marker, the baseline, both tables.
#   8. POST it. Only an answer with html_url writes `posted` (and clears `alerted`).
#   9. One ALERTS line `size-remeasure: due since <ISO>, not posted: <why>`,
#      only while state/size-remeasure/alerted is absent.
#
# BUCKETS. A build dir counts as `abandoned` when it holds
# .blocked-resolver-abandoned or its RESULT starts ABANDONED or ABANDONED_<X>,
# and as `closed-unmerged` when it holds .blocked-resolver-superseded or its
# RESULT starts PR_CLOSED. The deciding file's mtime must be inside the window.
# One count per PR URL (newest wins); a dir with no URL counts once. Repo =
# owner/repo of the URL, else job.json .project. Size = the last `SIZE: shipped
# <N> product lines` line of pipeline.log (bin/lib/rb/pr.sh); none -> unmeasured.
#
# IT CHANGES NO LIMIT. It reads no size knob and writes no settings row. The
# size limit stays a decision for the operator.
#
# Exit 0 on every lane path. OFF: flags/lane-off-size-remeasure
# (bin/harness-ctl.sh off size-remeasure). Registry: catalog/lanes.d/size-remeasure.json.
# Re-arm: delete state/size-remeasure/posted AND the #6025 comment.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
MARKER='<!-- harness-status: size-remeasure-bh-9502 -->'

# ---- the bucket count (pure, local) ----------------------------------------

# sr_edges -> sets E1 E2 E3 from the knobs; a bad set falls back and says so on stderr.
sr_edges() {
  E1="${SIZE_REMEASURE_EDGE_LOW:-600}"    # lane.size-remeasure.size_remeasure_edge_low
  E2="${SIZE_REMEASURE_EDGE_MID:-1200}"   # lane.size-remeasure.size_remeasure_edge_mid
  E3="${SIZE_REMEASURE_EDGE_HIGH:-3000}"  # lane.size-remeasure.size_remeasure_edge_high
  if ! [[ "$E1" =~ ^[1-9][0-9]*$ && "$E2" =~ ^[1-9][0-9]*$ && "$E3" =~ ^[1-9][0-9]*$ ]] \
     || [ "$E1" -ge "$E2" ] || [ "$E2" -ge "$E3" ]; then
    echo "size-remeasure: bad bucket edges $E1/$E2/$E3 (need three ascending positive integers); using 600/1200/3000" >&2
    E1=600; E2=1200; E3=3000
  fi
}

# sr_buckets <builds dir> <days> <now> -> the markdown table on stdout, one summary line on stderr.
sr_buckets() {
  local b="$1" days="$2" now="$3" from d res tok cls sf st url key repo sz l
  local scanned=0 deduped=0 unmeasured=0
  from=$((now - days * 86400))
  declare -A K_ST=() K_CLS=() K_REPO=() K_SZ=()
  for d in "$b"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; scanned=$((scanned + 1))
    res=$(head -n 1 "$d/RESULT" 2>/dev/null)
    tok="${res%%[[:space:]]*}"
    cls=""; sf=""
    if [ -e "$d/.blocked-resolver-abandoned" ]; then cls=abandoned; sf="$d/.blocked-resolver-abandoned"
    elif [[ "$tok" =~ ^ABANDONED(_[A-Z]+)?$ ]]; then cls=abandoned; sf="$d/RESULT"
    elif [ -e "$d/.blocked-resolver-superseded" ]; then cls=closed-unmerged; sf="$d/.blocked-resolver-superseded"
    elif [ "$tok" = PR_CLOSED ]; then cls=closed-unmerged; sf="$d/RESULT"
    fi
    [ -n "$cls" ] || continue
    st=$(stat -c %Y "$sf" 2>/dev/null) || continue
    [ "$st" -ge "$from" ] && [ "$st" -le "$now" ] || continue
    url=$(grep -m1 -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' "$d/RESULT" 2>/dev/null)
    if [ -n "$url" ]; then
      key="$url"
      repo=$(sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/.*#\1#' <<<"$url")
    else
      key="dir:$d"
      repo=$(jq -r '.project // empty' "$d/job.json" 2>/dev/null)
      [[ "$repo" =~ ^[A-Za-z0-9._/-]+$ ]] || repo=unknown
    fi
    l=$(grep -E 'SIZE: shipped [0-9]+ product lines' "$d/pipeline.log" 2>/dev/null | tail -n 1)
    sz=U
    [[ "$l" =~ SIZE:\ shipped\ ([0-9]+)\ product\ lines ]] && sz="${BASH_REMATCH[1]}"
    if [ -n "${K_ST[$key]:-}" ]; then
      deduped=$((deduped + 1))
      [ "$st" -ge "${K_ST[$key]}" ] || continue
    fi
    K_ST[$key]="$st"; K_CLS[$key]="$cls"; K_REPO[$key]="$repo"; K_SZ[$key]="$sz"
  done
  for key in "${!K_ST[@]}"; do [ "${K_SZ[$key]}" = U ] && unmeasured=$((unmeasured + 1)); done
  echo "size-remeasure buckets: scanned=$scanned counted=${#K_ST[@]} deduped=$deduped unmeasured=$unmeasured" >&2
  for key in "${!K_ST[@]}"; do
    printf '%s\t%s\t%s\n' "${K_REPO[$key]}" "${K_CLS[$key]}" "${K_SZ[$key]}"
  done | awk -F'\t' -v e1="$E1" -v e2="$E2" -v e3="$E3" '
    function col(s) { if (s == "U") return 5; s += 0
      if (s < e1) return 1; if (s <= e2) return 2; if (s <= e3) return 3; return 4 }
    { k = $1 SUBSEP $2; c = col($3); n[k, c]++; seen[k] = 1; t[$2, c]++; any = 1 }
    function row(name, cls, arr_k,   i, s) { s = "| " name " | " cls " |"
      for (i = 1; i <= 5; i++) s = s " " (arr_k == "" ? t[cls, i] + 0 : n[arr_k, i] + 0) " |"
      print s }
    END {
      printf "| repo | outcome | under %d | %d to %d | %d to %d | over %d | unmeasured |\n", e1, e1, e2, e2, e3, e3
      print "|---|---|---:|---:|---:|---:|---:|"
      m = 0; for (k in seen) keys[++m] = k
      for (i = 2; i <= m; i++) { v = keys[i]; j = i - 1
        while (j > 0 && keys[j] > v) { keys[j + 1] = keys[j]; j-- } keys[j + 1] = v }
      for (i = 1; i <= m; i++) { split(keys[i], p, SUBSEP); row(p[1], p[2], keys[i]) }
      row("all repos", "abandoned", ""); row("all repos", "closed-unmerged", "")
      if (!any) { print ""; print "No ABANDONED or closed-unmerged PR in the window." }
    }'
}

sr_now() {
  local n="${SIZE_REMEASURE_NOW:-0}"   # lane.size-remeasure.size_remeasure_now (test seam, not settable)
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=$(date +%s)
  printf '%s\n' "$n"
}
sr_days() { # sr_days <value> -> an int 1-90, else 14
  if [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && [ "$1" -le 90 ]; then printf '%s\n' "$1"; else echo 14; fi
}

if [ "${1:-}" = buckets ]; then
  shift; BDIR=""; BDAYS="${SIZE_REMEASURE_WINDOW_DAYS:-14}"   # lane.size-remeasure.size_remeasure_window_days
  while [ $# -gt 0 ]; do
    case "$1" in
      --builds) BDIR="${2:-}"; shift 2 ;;
      --days) BDAYS="${2:-}"; shift 2 ;;
      *) echo "usage: size-remeasure.sh buckets --builds <dir> [--days N]" >&2; exit 1 ;;
    esac
  done
  [ -d "$BDIR" ] || { echo "size-remeasure: no builds dir '$BDIR'" >&2; exit 1; }
  sr_edges
  sr_buckets "$BDIR" "$(sr_days "$BDAYS")" "$(sr_now)"
  exit 0
fi

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: size-remeasure.sh [--dry-run] | buckets --builds <dir> [--days N]" >&2; exit 1 ;;
esac

# ---- the lane header (project-21-daily pattern) ---------------------------------
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit size-remeasure
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply size-remeasure

DELAY=$(sr_days "${SIZE_REMEASURE_DELAY_DAYS:-14}")    # lane.size-remeasure.size_remeasure_delay_days
WINDOW=$(sr_days "${SIZE_REMEASURE_WINDOW_DAYS:-14}")  # lane.size-remeasure.size_remeasure_window_days
GATES="${SIZE_REMEASURE_GATE_ISSUES:-9441 9437}"       # lane.size-remeasure.size_remeasure_gate_issues
TARGET="${SIZE_REMEASURE_TARGET_ISSUE:-6025}"          # lane.size-remeasure.size_remeasure_target_issue
MAXP="${SIZE_REMEASURE_MAX_PAGES:-30}"                 # lane.size-remeasure.size_remeasure_max_pages
SCR="${SIZE_REMEASURE_SPLIT_CHAIN:-$SELF/split-chain-report.sh}"  # test seam, not settable
[[ "$TARGET" =~ ^[1-9][0-9]*$ ]] || TARGET=6025
if ! [[ "$MAXP" =~ ^[1-9][0-9]*$ ]] || [ "$MAXP" -gt 100 ]; then MAXP=30; fi
[[ "$GATES" =~ ^[0-9\ ]+$ ]] && [ -n "${GATES// /}" ] || GATES="9441 9437"
NOW=$(sr_now)
[ -n "${SIZE_REMEASURE_NOW:-}" ] && [ "${SIZE_REMEASURE_NOW:-0}" != 0 ] && export SPLIT_CHAIN_NOW="$NOW"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

ST="$H/state/size-remeasure"
LOG="$H/logs/size-remeasure.log"
[ "$DRY" = 1 ] || mkdir -p "$ST" "$H/logs" 2>/dev/null
say() { # lane mode: one log line; dry-run: stdout
  if [ "$DRY" = 1 ]; then printf '%s\n' "$1"; else printf '%s %s\n' "$(iso "$NOW")" "$1" >> "$LOG"; fi
}

# 1. done check: no network call.
if [ -s "$ST/posted" ]; then
  if [ "$DRY" = 1 ]; then say "done: posted $(cat "$ST/posted") (dry-run goes on)"
  else say "done: posted $(cat "$ST/posted")"; exit 0; fi
fi

# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || true
SLUG="${HARNESS_REPO:-}"
if ! [[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  say "not judged: no usable harness slug (HARNESS_REPO='$SLUG')"; exit 0
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/size-remeasure.XXXXXX") || { say "not judged: no temp dir"; exit 0; }
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$SELF/lib/gh-app-auth.sh" ] && . "$SELF/lib/gh-app-auth.sh" || true
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
trap 'rm -rf "$W"; command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset || true' EXIT

# 2-3. the gate.
VERDICT=""; LATEST=0; GATE_NOTE=""
for n in $GATES; do
  rc=0
  gh api "repos/$SLUG/issues/$n" > "$W/issue-$n.json" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then VERDICT="not judged: #$n read failed (rc $rc)"; break; fi
  if ! g=$(jq -er '[.state, (.state_reason // "none"), (.closed_at // "")] | @tsv' "$W/issue-$n.json" 2>/dev/null); then
    VERDICT="not judged: #$n answer is not an issue"; break
  fi
  IFS=$'\t' read -r gs gr gc <<<"$g"
  if [ "$gs" != closed ]; then VERDICT="not due: #$n open"; break; fi
  if [ "$gr" != completed ]; then VERDICT="not due: #$n closed $gr"; break; fi
  if [ -z "$gc" ] || ! ce=$(date -u -d "$gc" +%s 2>/dev/null); then VERDICT="not judged: #$n has no closed_at"; break; fi
  [ "$ce" -gt "$LATEST" ] && LATEST="$ce"
  GATE_NOTE="${GATE_NOTE:+$GATE_NOTE, }#$n closed $(iso "$ce")"
done
DUE=0
if [ -z "$VERDICT" ]; then
  DUE=$((LATEST + DELAY * 86400))
  if [ "$NOW" -lt "$DUE" ]; then VERDICT="not due until $(iso "$DUE")"; else VERDICT="due since $(iso "$DUE")"; fi
fi
if [ "$DRY" = 1 ]; then say "gate: $VERDICT"
else
  case "$VERDICT" in due\ since*) ;; *) say "$VERDICT"; exit 0 ;; esac
fi

FAILWHY=""
# 4. the thread check: is the marker already on the target issue?
FOUND=""; p=1
while :; do
  if [ "$p" -gt "$MAXP" ]; then FAILWHY="thread #$TARGET has more than $MAXP pages; absence not proven"; break; fi
  rc=0
  gh api "repos/$SLUG/issues/$TARGET/comments?per_page=100&page=$p" > "$W/c.json" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then FAILWHY="thread #$TARGET page $p read failed (rc $rc)"; break; fi
  jq -e 'type == "array"' "$W/c.json" >/dev/null 2>&1 || { FAILWHY="thread #$TARGET page $p is not a JSON array"; break; }
  FOUND=$(jq -r --arg m "$MARKER" '[.[] | select((.body // "") | contains($m)) | .html_url][0] // empty' "$W/c.json")
  [ -n "$FOUND" ] && break
  [ "$(jq length "$W/c.json")" -ge 100 ] || break
  p=$((p + 1))
done
if [ -n "$FOUND" ]; then
  if [ "$DRY" = 1 ]; then say "thread: the marker is already on #$TARGET at $FOUND; the lane would post nothing"
  else
    printf '%s %s\n' "$FOUND" "$(iso "$NOW")" > "$ST/posted"
    rm -f "$ST/alerted"
    say "posted $FOUND (found on the thread)"; exit 0
  fi
elif [ -n "$FAILWHY" ]; then say "thread: $FAILWHY"
else say "thread: no marker on #$TARGET"
fi

# 5. the split-chain report, a subprocess.
if [ "$DRY" = 1 ]; then SJ="$W/split-chain.json"; else SJ="$ST/split-chain.json"; fi
rm -f "$SJ"
REPOCLONE=$(cd "$SELF/.." && pwd)
rc=0
SOUT=$("$SCR" --days "$WINDOW" --slug "$SLUG" --repo "$REPOCLONE" --json "$SJ" 2>"$W/scr.err") || rc=$?
SLINE=$(grep -m1 -E '^(split-chain|INCOMPLETE)' <<<"$SOUT" || true)
if [ "$rc" != 0 ] || ! jq -e '.decision' "$SJ" >/dev/null 2>&1; then
  SCR_OK=0
  why="split-chain-report exit $rc${SLINE:+: $SLINE}"
  [ -n "$FAILWHY" ] || FAILWHY="$why"
  say "split-chain: $why"
else
  SCR_OK=1
  say "split-chain: ${SLINE:-report written}"
fi

# 6. the bucket count.
sr_edges 2>"$W/edges.err"
[ -s "$W/edges.err" ] && say "$(cat "$W/edges.err")"
BT=$(sr_buckets "$H/builds" "$WINDOW" "$NOW" 2>"$W/b.err")
BSUM=$(cat "$W/b.err")
UNM=$(sed -n 's/.* unmeasured=\([0-9]*\).*/\1/p' <<<"$BSUM")
say "$BSUM"

# 7. the comment body. Plain text, no model call.
sj() { jq -r "$1 | if . == null then \"-\" else . end" "$SJ" 2>/dev/null; }
{
  printf '%s\n' "$MARKER"
  printf 'This is the %s-day size re-measure from #9441 scope item 6. Window: %s to %s. Gate: %s, plus %s days.\n\n' \
    "$WINDOW" "$(iso $((NOW - WINDOW * 86400)))" "$(iso "$NOW")" "${GATE_NOTE:-not met}" "$DELAY"
  printf '### Baseline (2026-10-27 to 2026-11-10)\n\n'
  printf '36 PRs abandoned on "findings outlasted the fix round", 20 with a large-diff note, median about 2,900 lines. This is the read quoted in #9441 (comment 6780689984). It is a record of a past read, not a limit.\n\n'
  printf '### Split chain (bin/split-chain-report.sh --days %s)\n\n' "$WINDOW"
  if [ "$SCR_OK" = 1 ]; then
    printf '| side | n | median h | p75 h |\n|---|---:|---:|---:|\n'
    printf '| split | %s | %s | %s |\n' "$(sj .split.n)" "$(sj .split.median_h)" "$(sj .split.p75_h)"
    printf '| unsplit | %s | %s | %s |\n\n' "$(sj .unsplit.n)" "$(sj .unsplit.median_h)" "$(sj .unsplit.p75_h)"
    printf 'Split children: n=%s, unmeasured %s, product lines p50/p75/p90 %s/%s/%s, files p75/p90 %s/%s, over budget %s. Pages capped: %s.\n\n' \
      "$(sj .children.n)" "$(sj .children.unmeasured)" "$(sj .children.lines_p50)" "$(sj .children.lines_p75)" \
      "$(sj .children.lines_p90)" "$(sj .children.files_p75)" "$(sj .children.files_p90)" "$(sj .children.over_budget_n)" \
      "$(sj .sources.capped)"
    printf 'decision: %s\n\n' "$(sj .decision)"
  else
    printf 'The report is INCOMPLETE: %s\n\n' "${SLINE:-exit $rc}"
  fi
  printf '### ABANDONED and closed-unmerged PRs by product-line size, per repo\n\n'
  printf '%s\n\n' "$BT"
  printf 'Source: the hub build dirs (RESULT, .blocked-resolver-abandoned, .blocked-resolver-superseded), one count per PR. Unmeasured: %s (no `SIZE: shipped` line in the build pipeline.log). A PR closed by hand with no marker is not counted.\n\n' "${UNM:-0}"
  printf 'This comment changes no limit. The size gate stays at 1200 lines / 30 files until the operator decides.\n'
} > "$W/body.md"

if [ "$DRY" = 1 ]; then
  printf '\n----- comment body (not posted: dry-run) -----\n'
  cat "$W/body.md"
  exit 0
fi

alert_once() {
  [ -e "$ST/alerted" ] && return 0
  "$SELF/alert-line.sh" --id size-remeasure-not-posted --severity warn \
    "size-remeasure: due since $(iso "$DUE"), not posted: $1" >/dev/null 2>&1 || true
  printf '%s\n' "$(iso "$NOW")" > "$ST/alerted"
}
if [ -n "$FAILWHY" ]; then say "not posted: $FAILWHY"; alert_once "$FAILWHY"; exit 0; fi

# 8. the post. The send comes before the stamp.
jq -n --rawfile b "$W/body.md" '{body: $b}' > "$W/post.json"
rc=0
gh api -X POST "repos/$SLUG/issues/$TARGET/comments" --input "$W/post.json" > "$W/post.out" 2>"$W/post.err" || rc=$?
URL=$(jq -r '.html_url // empty' "$W/post.out" 2>/dev/null)
if [ "$rc" = 0 ] && [ -n "$URL" ]; then
  printf '%s %s\n' "$URL" "$(iso "$NOW")" > "$ST/posted"
  say "posted $URL"
  if [ -e "$ST/alerted" ]; then
    rm -f "$ST/alerted"
    "$SELF/alert-line.sh" --id size-remeasure-not-posted --severity resolved \
      "size-remeasure: posted $URL" >/dev/null 2>&1 || true
  fi
else
  why="POST to #$TARGET answered rc $rc with no html_url"
  say "not posted: $why"; alert_once "$why"
fi
exit 0
