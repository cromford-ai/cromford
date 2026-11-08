#!/bin/bash
# shellcheck shell=bash
# bin/lib/review-disprove-report.sh — the pure half of the BH-9238 (C2 of
# BH-9047) lane bin/review-disprove-report.sh: the 7-day report line on the
# disprove pass and the stop rule. Sourced, never run. Defines functions only.
# Nothing here builds a path from a harness root; the network reads in
# drr_next_read go through _jobs_req and gh_rest, which the caller loads.
#
# The rows are the answer of GET /api/review-disprove (review_disprove_runs,
# BH-9047 C0): {repo, pr, head_sha, lane, project, mode, verdict_before,
# verdict_after, findings, checked, confirmed, disproved, kept_protected,
# unchecked, cost_usd, detail:[{cls, loc, outcome, reason}], created_at}.
#
#   drr_summary <since> <truncated> <window_d>   rows array on stdin -> summary JSON
#   drr_fully <since>                            rows array on stdin -> fully disproved rows, one JSON per line
#   drr_next_read <slug> <row-json>              agreed-false | disagreed | pending | unreadable
#   drr_hunks                                    one patch on stdin -> "<os> <oe> <ns> <ne>" per hunk
#   drr_touch <n> <m> <slack>                    hunks on stdin; rc 0 when one overlaps [n-slack, m+slack]
#   drr_file_touch <files-json> <path> <n> <m> <slack>  rc 0 when a fix PR's file list touches the lines
#   drr_candidates <since>                       rows array on stdin -> TSV repo pr head created_at loc project

# The jq time helper: D1 writes ISO times, with or without milliseconds, and a
# space form is read the same way. Seconds since the epoch.
_DRR_JQ_TS='def ts: (tostring | .[0:19] | sub(" "; "T")) + "Z" | fromdateiso8601;'

# _drr_path_ok <path> — the C0 rule (_dp_path_ok in bin/lib/review-disprove.sh):
# a path that is empty, starts with `-` or `/`, or holds `..` is no location.
_drr_path_ok() { case "$1" in ''|-*|/*|*..*) return 1 ;; esac; return 0; }

# drr_summary <since> <truncated true|false> <window_d> — rows array on stdin.
# Only rows with created_at >= <since> count. Per lane (lead, conductor) and total:
#   blocks           verdict_before = BLOCK and checked > 0
#   fully_disproved  of those, findings > 0 and disproved = findings
#   share            whole percent of fully_disproved / blocks; null when blocks = 0
#   confirmed, disproved, kept, unchecked   summed over the block rows
#   cost_usd         summed; null when every block row has a null cost
drr_summary() {
  jq -c --arg since "$1" --argjson trunc "${2:-false}" --argjson w "${3:-7}" "$_DRR_JQ_TS"'
    def blk: select(.verdict_before == "BLOCK" and (.checked // 0) > 0);
    def full: select((.findings // 0) > 0 and (.disproved // 0) == (.findings // 0));
    def part($r):
      ([$r[] | blk]) as $b
      | ([$b[] | full] | length) as $f
      | {blocks: ($b | length), fully_disproved: $f,
         share: (if ($b | length) == 0 then null else (($f * 100 / ($b | length)) | round) end),
         confirmed: ([$b[].confirmed // 0] | add // 0), disproved: ([$b[].disproved // 0] | add // 0),
         kept: ([$b[].kept_protected // 0] | add // 0), unchecked: ([$b[].unchecked // 0] | add // 0),
         cost_usd: ([$b[].cost_usd | select(. != null)] | if length == 0 then null else add end)};
    ($since | ts) as $s
    | [.[] | select((.created_at | ts) >= $s)] as $r
    | {window_d: $w, since: $since, truncated: $trunc,
       lead: part([$r[] | select(.lane == "lead")]),
       conductor: part([$r[] | select(.lane == "conductor")]),
       total: part($r)}'
}

# drr_fully <since> — rows array on stdin; one compact JSON line per fully
# disproved BLOCK row with created_at >= <since>, newest first (the answer order).
drr_fully() {
  jq -c --arg since "$1" "$_DRR_JQ_TS"'
    ($since | ts) as $s
    | .[] | select((.created_at | ts) >= $s and .verdict_before == "BLOCK" and (.checked // 0) > 0
                   and (.findings // 0) > 0 and (.disproved // 0) == (.findings // 0))'
}

# drr_next_read <slug> <row-json> — the next human/Opus read of one fully
# disproved row. The read is the earliest /api/verdicts row on the same repo
# and PR with created_at later than the disprove row and (head_sha not the
# disprove row's head, or source = human), and a verdict word MERGE,
# MERGE-WITH-NOTES, APPROVE or BLOCK. It prints:
#   pending       no such row yet
#   disagreed     that row says BLOCK, or the head moved and the compare shows
#                 a change to a DISPROVED finding's path
#   agreed-false  that row clears the PR on the same head, or on a moved head
#                 whose compare touches no DISPROVED finding's path
#   unreadable    a verdicts read, a compare read or a sha failed. Never agreed.
# The verdicts route answers the newest 100 rows of the PR; the earliest later
# row is picked from those.
drr_next_read() {
  local slug="$1" row="$2" pr old t pick v new paths rc
  pr=$(jq -r '.pr // empty' <<<"$row" 2>/dev/null)
  old=$(jq -r '.head_sha // empty' <<<"$row" 2>/dev/null)
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$pr" =~ ^[0-9]+$ ]] && [[ "$old" =~ ^[0-9a-f]{40}$ ]] \
    || { printf unreadable; return 0; }
  command -v _jobs_req >/dev/null 2>&1 || { printf unreadable; return 0; }
  t=$(mktemp "${TMPDIR:-/tmp}/drr-next.XXXXXX") || { printf unreadable; return 0; }
  if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$slug&pr=$pr" > "$t" 2>/dev/null \
     || ! pick=$(jq -ec --argjson row "$row" "$_DRR_JQ_TS"'
          if (.rows | type) != "array" then error("no rows") else . end
          | ($row.created_at | ts) as $c
          | [.rows[] | select(((.created_at // "") | ts) > $c
                              and ((.head_sha // "") != $row.head_sha or .source == "human")
                              and (.verdict | IN("MERGE", "MERGE-WITH-NOTES", "APPROVE", "BLOCK")))]
          | sort_by([(.created_at | ts), (.id // 0)]) | .[0] // {verdict: "none"}
          | {verdict, head: (.head_sha // "")}' "$t" 2>/dev/null); then
    rm -f "$t"; printf unreadable; return 0
  fi
  v=$(jq -r .verdict <<<"$pick"); new=$(jq -r .head <<<"$pick")
  case "$v" in
    none) rm -f "$t"; printf pending; return 0 ;;
    BLOCK) rm -f "$t"; printf disagreed; return 0 ;;
  esac
  if [ "$new" = "$old" ]; then rm -f "$t"; printf agreed-false; return 0; fi
  [[ "$new" =~ ^[0-9a-f]{40}$ ]] && command -v gh_rest >/dev/null 2>&1 || { rm -f "$t"; printf unreadable; return 0; }
  rc=0; gh_rest GET "repos/$slug/compare/$old...$new" > "$t" 2>/dev/null || rc=$?
  # GitHub lists at most 300 files of a compare: a full list cannot prove a
  # path is untouched, so it is unreadable, never agreed.
  if [ "$rc" != 0 ] || ! jq -e '(.files | type) == "array" and (.files | length) < 300' "$t" >/dev/null 2>&1; then
    rm -f "$t"; printf unreadable; return 0
  fi
  paths=$(jq -c '[.detail[]? | select(.outcome == "DISPROVED") | (.loc // "") | sub(":[0-9]+(-[0-9]+)?$"; "")]' <<<"$row")
  if jq -e --argjson p "$paths" '[.files[] | .filename, (.previous_filename // empty)] | any(.[]; IN($p[]))' "$t" >/dev/null 2>&1; then
    printf disagreed
  else
    printf agreed-false
  fi
  rm -f "$t"; return 0
}

# drr_hunks — one unified-diff patch on stdin; one line per `@@ -a,b +c,d @@`
# header: "<old_start> <old_end> <new_start> <new_end>". A missing count is 1;
# a count of 0 (pure insertion or deletion) is the one line at its start.
drr_hunks() {
  awk 'match($0, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/) {
         h = substr($0, 4, RLENGTH - 6); split(h, s, " ")
         o = substr(s[1], 2); n = substr(s[2], 2)
         oc = 1; if (index(o, ",")) { split(o, a, ","); o = a[1]; oc = a[2] }
         nc = 1; if (index(n, ",")) { split(n, b, ","); n = b[1]; nc = b[2] }
         oe = (oc > 0) ? o + oc - 1 : o + 0; ne = (nc > 0) ? n + nc - 1 : n + 0
         print o + 0, oe, n + 0, ne }'
}

# drr_touch <n> <m> <slack> — hunk lines from drr_hunks on stdin. rc 0 when
# the old or the new side of one hunk overlaps [n - slack, m + slack].
drr_touch() {
  awk -v n="$1" -v m="$2" -v s="$3" 'BEGIN { lo = n - s; hi = m + s; hit = 0 }
    NF == 4 { if (($1 <= hi && $2 >= lo) || ($3 <= hi && $4 >= lo)) hit = 1 }
    END { exit !hit }'
}

# drr_file_touch <files-json> <path> <n> <m> <slack> — <files-json> is the
# GET repos/<slug>/pulls/<f>/files answer (an array). rc 0 when an entry whose
# filename or previous_filename is exactly <path> has a hunk that overlaps the
# lines. An entry with no patch (GitHub leaves it out of a large or binary
# file) counts as a touch: the stop rule fails toward off.
drr_file_touch() {
  local f="$1" path="$2" n="$3" m="$4" s="$5" e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if [ "$(jq -r 'has("patch") and (.patch | type) == "string"' <<<"$e")" != true ]; then return 0; fi
    jq -r .patch <<<"$e" | drr_hunks | drr_touch "$n" "$m" "$s" && return 0
  done < <(jq -c --arg p "$path" '.[]? | select(.filename == $p or (.previous_filename // "") == $p)' "$f" 2>/dev/null)
  return 1
}

# drr_candidates <since> — rows array on stdin; one TSV line per DISPROVED
# finding location of a stop-rule candidate: repo, pr, head, created_at, loc,
# project. A candidate row has created_at >= <since>, mode enforce,
# verdict_before BLOCK and verdict_after APPROVE or MERGE-WITH-NOTES (the
# enforce pass cleared it). A loc must be <path>:<n>[-<m>] with a path that
# passes the C0 rule (_drr_path_ok).
drr_candidates() {
  local repo pr head c loc project
  while IFS=$'\t' read -r repo pr head c loc project; do
    [ -n "$repo" ] || continue
    _drr_path_ok "${loc%:*}" || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$pr" "$head" "$c" "$loc" "$project"
  done < <(jq -r --arg since "$1" "$_DRR_JQ_TS"'
    ($since | ts) as $s
    | .[] | select((.created_at | ts) >= $s and .mode == "enforce" and .verdict_before == "BLOCK"
                   and (.verdict_after | IN("APPROVE", "MERGE-WITH-NOTES")))
    | . as $r | .detail[]? | select(.outcome == "DISPROVED")
    | select((.loc // "") | test("^[A-Za-z0-9._/-]+:[0-9]+(-[0-9]+)?$"))
    | [$r.repo, ($r.pr | tostring), $r.head_sha, $r.created_at, .loc, $r.project] | @tsv' 2>/dev/null)
}
