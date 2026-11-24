#!/bin/bash
# tests/lib/pr-record-store.bh-9935.sh — BH-9935: an in-file pr_records store
# behind a _jobs_req double, and a gh_rest double, for the shell suites of the
# record readers (tests/pr-record-files.bh-9935-test.sh,
# tests/pr-record-readers.bh-9935-test.sh,
# tests/pr-record-label-list.bh-9935-test.sh). Sourced after tests/lib/scratch.sh
# ($T is set). Defines functions only; makes no network call.
#
# The store:  $PRS/rec/<owner_repo>_<n>.json is one row (absent = no record).
#   GET  /api/pr-records?repo=&number=  -> {row, age_s} (age_s from $PRS/age, default 0)
#   GET  /api/pr-records?repo=&state=   -> the text of $PRS/list.json
#   PUT  /api/pr-records                -> the row merged with .fields; the body is
#                                          saved to $PRS/put-<k>.json; {row, applied, stale}
#   $PRS/jobs-fail makes every request fail (rc 1); $PRS/put-fail only the PUT.
# gh_rest:  repos/<r>/pulls/<n>/files -F page=<p>  -> $PRS/gh/files-<n>-p<p>.json, else []
#           repos/<r>/commits/<sha>                 -> $PRS/gh/commit-<sha>.json, else rc 44
#   $PRS/gh-fail makes every read rc 75. Every call is one line in $PRS/gh.log.
PRS="$T/prs"
mkdir -p "$PRS/rec" "$PRS/gh"
: > "$PRS/jobs.log"; : > "$PRS/gh.log"; echo 0 > "$PRS/puts"

prs_file() { printf '%s/rec/%s_%s.json' "$PRS" "${1//\//_}" "$2"; }
prs_set()  { printf '%s\n' "$3" > "$(prs_file "$1" "$2")"; }   # <repo> <n> <row-json>
prs_row()  { cat "$(prs_file "$1" "$2")" 2>/dev/null; }
prs_puts() { cat "$PRS/puts"; }
prs_gh()   { local c; c=$(grep -c -- "$1" "$PRS/gh.log" 2>/dev/null); printf '%s' "${c:-0}"; }   # calls whose line holds <text>

_jobs_req() {
  local m="$1" p="$2" body="${3:-}" repo n f k
  printf '%s %s\n' "$m" "$p" >> "$PRS/jobs.log"
  [ -e "$PRS/jobs-fail" ] && return 1
  case "$m $p" in
    "GET /api/pr-records?repo="*"&number="*)
      repo=${p#*repo=}; repo=${repo%%&*}; n=${p##*number=}
      f=$(prs_file "$repo" "$n")
      if [ -s "$f" ]; then jq -c --argjson a "$(cat "$PRS/age" 2>/dev/null || echo 0)" '{row: ., age_s: $a}' "$f"
      else printf '{"row":null,"age_s":null}'; fi ;;
    "GET /api/pr-records?repo="*"&state="*)
      cat "$PRS/list.json" ;;
    "PUT /api/pr-records")
      k=$(( $(cat "$PRS/puts") + 1 )); echo "$k" > "$PRS/puts"
      printf '%s\n' "$body" > "$PRS/put-$k.json"
      [ -e "$PRS/put-fail" ] && return 1
      repo=$(jq -r .repo <<<"$body"); n=$(jq -r .number <<<"$body"); f=$(prs_file "$repo" "$n")
      { cat "$f" 2>/dev/null || echo '{}'; } | jq -c -s '.[0] + .[1].fields + {repo: .[1].repo, number: .[1].number}' - <(printf '%s' "$body") > "$f.new" \
        && mv "$f.new" "$f" || return 1
      jq -c --slurpfile b <(printf '%s' "$body") '{row: ., applied: ($b[0].fields | keys), stale: []}' "$f" ;;
    *) return 1 ;;
  esac
}

gh_rest() {
  local m="$1" p="$2" a page=1 n
  shift 2
  printf '%s %s %s\n' "$m" "$p" "$*" >> "$PRS/gh.log"
  [ -e "$PRS/gh-fail" ] && return 75
  for a in "$@"; do case "$a" in page=*) page=${a#page=} ;; esac; done
  case "$p" in
    repos/*/pulls/*/files)
      n=${p%/files}; n=${n##*/}
      if [ -r "$PRS/gh/files-$n-p$page.json" ]; then cat "$PRS/gh/files-$n-p$page.json"; else printf '[]'; fi ;;
    repos/*/commits/*)
      [ -r "$PRS/gh/commit-${p##*/}.json" ] || return 44
      cat "$PRS/gh/commit-${p##*/}.json" ;;
    *) return 75 ;;
  esac
}
