#!/bin/bash
# shellcheck shell=bash
# module: classify after: locks
# bin/lib/mc/classify.sh — BH-477: enumeration, verdict, CI state, iron-law scan, provenance/hand-off holds, the red ladder, mc_classify. Sourced by bin/lib/merge-conductor-lib.sh, never run.
# THE DECISION READS GO THROUGH REST (BH-784), and the marker below is what
# tests/gh-no-graphql-decision-guard-test.sh scans this file for. It moved here
# with the code when BH-477.3 emptied bin/lib/merge-conductor-lib.sh: the lib
# carried the marker while it carried these calls, and a module holding them
# unmarked would be a call site the guard silently stopped policing.
# gh-rest: no-graphql


# --- Enumeration helpers -----------------------------------------------------
# mc_slug_of_url <pr-url> -> owner/repo ; mc_num_of_url -> number
mc_slug_of_url() { sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$1"; }
mc_num_of_url()  { grep -oE '[0-9]+$' <<<"$1"; }
# The keyed tick's filters (BH-1387). MC_ONLY_KEYS is the driver's parse of
# MC_ONLY_PR (" owner/repo#n … "); empty means an unkeyed tick, and both answer
# yes to everything. mc_only_has <owner/repo#n>, mc_only_slug <owner/repo>.
# Keys are stored lowercased and the probe is lowercased here (BH-1841): GitHub
# slugs are case-insensitive, and a webhook's spelling need not be fleet.conf's.
# Only the comparison folds; the caller's slug keeps fleet.conf's spelling.
mc_only_has()  { [ -z "${MC_ONLY_KEYS:-}" ] || case "$MC_ONLY_KEYS" in *" ${1,,} "*) return 0 ;; *) return 1 ;; esac; }
mc_only_slug() { [ -z "${MC_ONLY_KEYS:-}" ] || case "$MC_ONLY_KEYS" in *" ${1,,}#"*) return 0 ;; *) return 1 ;; esac; }

# ENROLLED PRs (BH-3933). bin/pr-owner-sweep.sh enrolls an ownerless PR — an
# outside author's included — by writing a pr_attempts row (kind `enrolled`, on
# its head) and then a READY row, and spawns ONE keyed run for those keys. The
# open list carries harness authors only, so a keyed run fetches each outside
# key by number (mc_enrolled_rows), and pr_worker accepts an enrolled PR (mc_enrolled_pr)
# in ANY tick — a harness-authored ORPHAN on a feature branch
# is in the open list, so the ordinary unkeyed tick drives it too. The answer is
# bound to THIS head: a new head, a miss and an outage are all "not enrolled".
# mc_enrolled_ok <owner/repo> <num> <head> — rc 0 enrolled on this head.
#   No kill switch here: pr_owner.enroll_external is about OUTSIDE authors, and
#   only mc_enrolled_rows knows the author. An outside PR reaches pr_worker only
#   through that injection, which reads the switch.
mc_enrolled_ok() {
  command -v pr_attempt_has >/dev/null 2>&1 || return 1
  [[ "${3:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
  pr_attempt_has "$1" "$2" enrolled "$3" && return 0
  return 1
}
# mc_enrolled_pr <record> <branch> <owner/repo> <num> <head> — pr_worker's
#   pre-check in front of the harness pr probe (BH-3933 r3): rc 0 only when
#   mc_is_harness_pr's two cheap tests both miss (no build record, the branch is
#   not ticket/* or main-red-revert/*) AND mc_enrolled_ok says enrolled on this
#   head. The common harness PR never pays the attempt read, and any miss falls
#   through to the probe unchanged.
mc_enrolled_pr() {
  [ -n "${1:-}" ] && return 1
  case "${2:-}" in ticket/*|main-red-revert/*) return 1 ;; esac
  mc_enrolled_ok "$3" "$4" "$5"
}
# mc_enroll_external_load — reads pr_owner.enroll_external once per run into
#   MC_ENROLL_EXTERNAL (tick_project primes it before the workers fork). The D1
#   row wins, then PR_OWNER_ENROLL_EXTERNAL, then 1, as in the sweep — except
#   that an unreadable settings row, or no bin/lib/pr-health.sh, reads 0: an
#   outage must not reopen a switch an operator threw.
mc_enroll_external_load() {
  [ -n "${_MC_EE_READ:-}" ] && return 0
  _MC_EE_READ=1
  command -v ph_knob >/dev/null 2>&1 || { MC_ENROLL_EXTERNAL=0; return 0; }
  local _o _v _src
  _o=$(ph_knob pr_owner.enroll_external PR_OWNER_ENROLL_EXTERNAL 1 2>/dev/null; printf '%s' "$PH_KNOB_SRC")
  _v="${_o%%$'\n'*}"; _src="${_o##*$'\n'}"
  [ "$_src" = outage ] && _v=0
  MC_ENROLL_EXTERNAL="$_v"
  mc_log "pr_owner.enroll_external=$MC_ENROLL_EXTERNAL (${_src:-unknown}) for enrolled PRs this run"
}
# Never inherited: an exported value would stand in for the D1 read.
unset _MC_EE_READ MC_ENROLL_EXTERNAL
# mc_enrolled_rows <owner/repo> <open-nums> — one pr_worker row (the open list's
#   13 columns, `-` for empty) per keyed PR of this repo the list did not carry,
#   read over REST, when it is open and enrolled on its head. An enrolled PR
#   found closed is settled MERGED/CLOSED so its row does not linger for the
#   backstop. A failed read injects nothing for that key and says so. THE KILL
#   SWITCH binds here, where the author is known: an outside author (not one of
#   harness_pr_authors) is injected only while pr_owner.enroll_external is 1, so
#   throwing it stops a PR enrolled earlier from merging, not only the next
#   enrollment. A box with no author list reads every author as outside.
mc_enrolled_rows() {
  local slug="$1" open=" ${2:-} " k n pj head st login
  [ -n "${MC_ONLY_KEYS:-}" ] || return 0
  for k in $MC_ONLY_KEYS; do
    case "$k" in "${slug,,}#"*) ;; *) continue ;; esac
    n="${k##*#}"
    case "$open" in *" $n "*) continue ;; esac
    if ! mc_rest_var pj gh_rest GET "repos/$slug/pulls/$n"; then
      mc_log "$slug#$n: keyed PR not in the open list and unreadable (HTTP $(mc_rest_status)) — not evaluated this tick"; continue
    fi
    head=$(jq -r '.head.sha // empty' <<<"$pj" 2>/dev/null)
    login=$(jq -r '.user.login // empty' <<<"$pj" 2>/dev/null)
    if ! { [ -n "$login" ] && command -v harness_pr_author_match >/dev/null 2>&1 \
           && { harness_pr_author_match "$login" || harness_pr_author_match "${login,,}"; }; } \
       && [ "${MC_ENROLL_EXTERNAL:-0}" != 1 ]; then
      mc_log "$slug#$n: author ${login:-unknown} is outside and pr_owner.enroll_external=${MC_ENROLL_EXTERNAL:-0} — external enrollment off, not evaluated"; continue
    fi
    mc_enrolled_ok "$slug" "$n" "$head" || continue
    st=$(jq -r 'if .state == "open" then "OPEN" elif .merged_at != null then "MERGED" else "CLOSED" end' <<<"$pj" 2>/dev/null)
    if [ "$st" != OPEN ]; then
      mc_transition "$slug#$n" "$st" enrolled-pr-closed "$head" - "$(jq -r '.html_url // "-"' <<<"$pj")" - - - >/dev/null
      continue
    fi
    jq -r 'def d: if . == null or . == "" then "-" else tostring end;
      [.number, .html_url, .head.sha, .head.ref, (.draft == true | tostring),
       ((.mergeable_state // "unknown") | ascii_upcase),
       (if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
       "OPEN", "false", ((.labels // []) | map(.name) | join(",")), .base.ref, .updated_at,
       (if (.head.repo.full_name // null) == null or (.base.repo.full_name // null) == null then null
        else (.head.repo.full_name != .base.repo.full_name) end)]
      | map(d) | @tsv' <<<"$pj" 2>/dev/null
  done
}

# mc_record_for <pr-url> -> the build dir whose RESULT names this PR (the
# sweep's discovery, same glob order), or nothing.
#   ONE PASS, NOT ONE FORK PER DIRECTORY (2026-09-16). The first shape of this
#   loop ran `head -1` + `grep` for every build dir; with 1,893 dirs on the hub
#   that was ~3,700 process spawns per PR per tick, and under load 184 the
#   conductor's workers spent whole ticks in it (every `ps` leaf under the
#   oldest tick was a `head -1 builds/…/RESULT`), holding their PR locks so
#   later ticks read locked=17 merges=0. awk reads all the RESULT files in a
#   single process; FNR==1 keeps the first-line-only contract, the two globs
#   keep the pool-first order, and the first hit wins exactly as before.
#   ONE PROCESS, NO ARGV (the #519 follow-up, same day). The first single-pass
#   shape piped the file list through xargs into awk and took the first line
#   with head: a second record for the same PR (every pool-* dir is listed by
#   BOTH globs) made the next awk write into the closed pipe, xargs stopped on
#   the signal and printf logged "write error: Broken pipe" in the cron log
#   every tick. awk now reads the file NAMES on stdin and the first LINE of each
#   file itself (getline < f), so there is one process, no argv to outgrow
#   (MAX_ARG_STRLEN, the #495 class), and exit on the first hit closes nothing
#   that is still being written to.
# --- The REST decision reads (BH-784) ----------------------------------------
# One normalising jq, applied once, so every call site below keeps comparing the
# WORDS it has always compared. REST answers `state`+`merged_at` where GraphQL
# answered one `state`, `mergeable` as a tri-state boolean where GraphQL spelled
# it MERGEABLE/CONFLICTING/UNKNOWN, and `mergeable_state` in lower case.
MC_REST_NORM='. + {
  STATE:     (if (.merged_at // null) != null then "MERGED" elif .state == "open" then "OPEN" else "CLOSED" end),
  MERGEABLE: (if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
  MSTATE:    ((.mergeable_state // "unknown") | ascii_upcase),
  LABELS:    ((.labels // []) | map(.name) | join(","))
}'
# How many pages a paginated read may buy. 30 x 100 is GitHub's own 3000-file
# cap on /pulls/{n}/files, so the bound costs nothing real and no read here can
# run away (D21).
MC_REST_PAGES_MAX="${MC_REST_PAGES_MAX:-30}"

# mc_rest_status — the HTTP status of the last read that FAILED, printed for a
# log line. `?` when nothing is known, which every log line below accepts.
#
# WHY NOT JUST $GH_REST_STATUS. Most call sites here capture their read
# (`ST=$(mc_pr_view …)`), and a command substitution is a SUBSHELL: the variable
# the contract set dies with it, and the caller's log line then names the last
# status THIS shell saw (000 until one read ran uncaptured) for a 403 the
# contract classified correctly. bin/lib/gh-rest.sh (#993) keeps the status in
# the calling shell only — its own rule is "call the helper with `> file`" —
# so the number here is a best effort for a log line, never a decision input.
# If the library ever persists a failed read's status per PROCESS
# (_gh_rest_stfile; $$ is the same in the subshell), that file is read here
# first, never consumed, so gh_rest_alert still gets to consume it afterwards.
mc_rest_status() {
  local sf st
  if command -v _gh_rest_stfile >/dev/null 2>&1; then
    sf=$(_gh_rest_stfile)
    if [ -r "$sf" ]; then
      read -r st _ < "$sf" 2>/dev/null
      [ -n "${st:-}" ] && { printf '%s' "$st"; return 0; }
    fi
  fi
  printf '%s' "${GH_REST_STATUS:-?}"
}

# mc_rest_slug_num <pr-url> — prints "<slug> <num>"; rc 75 on anything that is
# not a PR url, because a malformed slug is UNVERIFIABLE, never "absent".
mc_rest_slug_num() {
  local slug num
  slug=$(mc_slug_of_url "${1:-}"); num=$(mc_num_of_url "${1:-}")
  case "$slug" in */*) ;; *) return 75 ;; esac
  case "$num" in ''|*[!0-9]*) return 75 ;; esac
  printf '%s %s' "$slug" "$num"
}

# mc_rest_pr_json <slug> <num> — the pull object plus the normalised words.
#
# BH-1295 REVIEW FIX (B2): `b=$(gh_rest GET …)` ran gh_rest inside a `$( )`,
# which is exactly what bin/lib/gh-rest.sh's own header forbids — GH_REST_
# STATUS and GH_REST_REASON die in that subshell, and so do GH_ETAG_FETCHED/
# CACHED's file-backed replacement: every mc_pr_view read (the dominant
# traffic the ETag cache exists for) reported fetched=0 cached=0 forever.
# Read through a FILE instead, the same idiom `_gh_rest_field` and
# gh-pr-list.sh's `_gh_rest_list` already use.
mc_rest_pr_json() {
  local t rc=0
  t=$(mktemp "${TMPDIR:-/tmp}/mc-pr.XXXXXX") || return 75
  gh_rest GET "repos/${1:?slug}/pulls/${2:?num}" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; return "$rc"; fi
  jq -c "$MC_REST_NORM" "$t" 2>/dev/null || { rm -f "$t"; return 75; }
  rm -f "$t"
}

# mc_pr_view <pr-url> <jq-expr> — the read every `gh pr view --json … -q …` call
# site became. It prints NOTHING and returns the read's rc (44 or 75) when
# GitHub did not answer, which is what makes "I could not read it" different
# from "it says no" at every call site.
mc_pr_view() {
  local sn slug num j rc
  sn=$(mc_rest_slug_num "${1:-}") || return 75
  read -r slug num <<<"$sn"
  j=$(mc_rest_pr_json "$slug" "$num"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s' "$j" | jq -r "${2:-.}" 2>/dev/null || return 75
}

# mc_pr_diff <pr-url> <outfile> — the diff media type through the same contract.
# rc passes through, so a caller can tell an empty diff from an unread one.
mc_pr_diff() {
  local sn slug num
  sn=$(mc_rest_slug_num "${1:-}") || return 75
  read -r slug num <<<"$sn"
  gh_rest GET "repos/$slug/pulls/$num" -H "Accept: application/vnd.github.v3.diff" > "${2:?outfile}"
}

# mc_pr_diff_or_local <pr-url> <outfile> <slug> <project> <num> <base-ref> <head>
#   The iron-law scan's diff read (BH-5914, BH-6000). The API diff first,
#   exactly as mc_pr_diff. When the API read fails FOR ANY REASON (a 406 "too
#   large": example-org/project-6 #27, 837 files, 2026-10-10; a 403/429 rate
#   limit; a 5xx; no answer at all) the same diff comes from a local clone
#   instead (mc_pr_diff_local), which spends no API budget. Before BH-6000 only
#   a 406 fell back, and #5993 logged "the diff read was UNVERIFIABLE" on every
#   tick. The BH-784 rule is unchanged: a diff that neither read produces is
#   rc 75, and the caller never takes it for a clean one.
#   rc 0 = <outfile> holds the WHOLE diff.
#   rc 3 = <outfile> holds the diff, but MC_DIFF_UNSCANNED file(s) in it have no
#          text to scan (binary): the caller scans what is there and HOLDS.
#   rc 75 = no diff.
MC_DIFF_UNSCANNED=0
mc_pr_diff_or_local() {
  local url="$1" out="$2" slug="$3" project="$4" num="$5" base="$6" head="$7" st
  MC_DIFF_UNSCANNED=0
  mc_pr_diff "$url" "$out" && return 0
  st=$(mc_rest_status 2>/dev/null)
  MC_DIFF_API_STATUS="${st:-000}" mc_pr_diff_local "$slug" "$project" "$num" "$base" "$head" "$out"
}

# mc_pr_diff_local <slug> <project> <num> <base-ref> <head> <outfile>
#   `git diff <base>...<head>` from the conductor's clone (mc_funnel_repo: the
#   hub checkout, else the scratch clone it keeps per repo), STREAMED straight
#   into <outfile>, never held in a shell variable. Every text file is in it
#   whatever its size: the scan reads the file line by line, so size is no
#   reason to leave anything out. The PR head is fetched from
#   refs/pull/<n>/head and must BE <head>, the head the tick read: a diff of
#   any other head is a scan of code nobody is merging, so a mismatch is rc 75.
#
#   A FILE WITH NO TEXT TO SCAN HOLDS (BH-5914 review). A binary file has no
#   added lines in a diff, so the scan cannot see into it. Their count goes to
#   MC_DIFF_UNSCANNED, one mc_log line names them, and the rc is 3: the caller
#   holds the head ("iron-law: N file(s) not scanned"), exactly as for an
#   unread diff, and never stores the count as a clean scan.
#
#   rc 0 the whole diff is written; rc 3 written, N file(s) unscanned;
#   rc 75 no clone, fetch failed, head mismatch, or git failed.
mc_pr_diff_local() {
  local slug="$1" project="$2" num="$3" base="$4" head="$5" out="$6" wt got rc bins nbin
  MC_DIFF_UNSCANNED=0
  [ -n "$base" ] && [ -n "$head" ] || { mc_log "$slug#$num local diff: no base or head to diff — UNVERIFIABLE"; return 75; }
  mc_funnel_repo "$slug" "$project" || { mc_log "$slug#$num local diff: no clone of $slug could be had — UNVERIFIABLE"; return 75; }
  wt="$MC_FUNNEL_WT"
  if ! mc_git_bounded "${MC_MERGE_TREE_FETCH_SECS:-60}" git -C "$wt" -c credential.helper= fetch -q --no-tags origin \
        "+refs/heads/$base:refs/mc-diff/base" "+refs/pull/$num/head:refs/mc-diff/pr-$num" >/dev/null 2>&1; then
    mc_git_auth_clear; mc_log "$slug#$num local diff: fetch of $base and refs/pull/$num/head failed — UNVERIFIABLE"; return 75
  fi
  got=$(git -C "$wt" rev-parse -q --verify "refs/mc-diff/pr-$num^{commit}" 2>/dev/null)
  if [ "$got" != "$head" ]; then
    mc_git_auth_clear; mc_log "$slug#$num local diff: refs/pull/$num/head is ${got:-absent}, not the head ${head:0:8} this tick read — UNVERIFIABLE"; return 75
  fi
  git -C "$wt" diff --no-color --no-ext-diff --no-renames "refs/mc-diff/base...refs/mc-diff/pr-$num" > "$out" 2>/dev/null; rc=$?
  if [ "$rc" != 0 ]; then
    mc_git_auth_clear; : > "$out"; mc_log "$slug#$num local diff: git diff failed (rc $rc) — UNVERIFIABLE"; return 75
  fi
  bins=$(git -C "$wt" diff --numstat --no-renames "refs/mc-diff/base...refs/mc-diff/pr-$num" 2>/dev/null); rc=$?
  mc_git_auth_clear
  if [ "$rc" != 0 ]; then : > "$out"; mc_log "$slug#$num local diff: git diff --numstat failed (rc $rc) — UNVERIFIABLE"; return 75; fi
  bins=$(printf '%s\n' "$bins" | awk -F'\t' '$1 == "-" && $2 == "-" { print $3 }')
  nbin=$(printf '%s' "$bins" | grep -c .)
  if [ "${nbin:-0}" -gt 0 ]; then
    MC_DIFF_UNSCANNED="$nbin"
    mc_log "$slug#$num diff read from the API failed (HTTP ${MC_DIFF_API_STATUS-000}) — iron-law scan reads a local git diff of ${head:0:8}; $nbin file(s) not scanned (binary, no text to read): $(awk 'NR <= 20' <<<"$bins" | paste -sd, -)"
    return 3
  fi
  mc_log "$slug#$num diff read from the API failed (HTTP ${MC_DIFF_API_STATUS-000}) — iron-law scan reads a local git diff of ${head:0:8} instead (every file scanned)"
  return 0
}

# mc_iron_law_names <diff-file> — the iron-law literal hits in a diff, named:
#   one "<file> (<match>)" per hit, the same added-line filter and patterns as
#   mc_iron_law_scan's own count (checks-run.sh hits are counted there, not
#   named here). Streamed, so a file of any size is read line by line.
mc_iron_law_names() {
  awk '/^\+\+\+ /{f=substr($2,3); skip=($2 ~ /\.(test|spec)\.|__tests__\/|__mocks__\/|\/tests?\/|scripts\/migrations\/|\.harness\/specs\/|^b\/tasks\/|^b\/docs\/|\.md$|\.txt$/)} /^\+/ && !/^\+\+\+/ && !skip && $0 !~ /^\+[[:space:]]*(\/\/|\*|\/\*|#|--|<!--)/ {
         if (match($0, /window\.(confirm|alert|prompt)\(|claude-(fable|opus|sonnet|haiku)[A-Za-z0-9.-]*|VERCEL_URL/)) print f " (" substr($0, RSTART, RLENGTH) ")" }' "$1" 2>/dev/null
}

# mc_merge_verdict_put <key> <head> <hold|clear> <reason>
#   Publish the conductor's verdict for this head to the jobs ledger (BH-5914):
#   kind mc-merge-verdict, key <slug>#<n>, detail "<head> <reason>". Every other
#   lane that can merge reads it (bin/merge-queue.sh mq_conductor_hold), so a
#   refusal here holds on every box, not only in this process. One PUT per
#   (head, status): the last PUT that LANDED is remembered in
#   $MC_STATE_DIR/merge-verdict/, and a failed PUT is not remembered, so the
#   next tick sends it again. No ledger client: nothing to publish, rc 0.
mc_merge_verdict_put() {
  local key="$1" head="$2" status="$3" reason="${4:-}" dir f last=""
  [ -n "$key" ] && [ -n "$head" ] && [ -n "$status" ] || return 0
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  dir="$MC_STATE_DIR/merge-verdict"; f="$dir/$(mc_handoff_id "$key")"
  [ -r "$f" ] && last=$(cat "$f" 2>/dev/null)
  [ "$last" = "$head $status" ] && return 0
  job_ledger_put mc-merge-verdict "$key" "$status" "$head $reason" >/dev/null 2>&1 || return 0
  mkdir -p "$dir" 2>/dev/null && printf '%s %s' "$head" "$status" > "$f" 2>/dev/null
  return 0
}

# mc_issue_comment <slug> <num> <text> / mc_pr_comment <pr-url> <text>
#   The body goes by FILE, never on argv — a comment can quote a token, and argv
#   is world-readable in /proc. gh_rest_comment owns the POST.
mc_issue_comment() {
  local f rc
  f=$(mktemp "${TMPDIR:-/tmp}/mc-comment.XXXXXX") || return 75
  printf '%s' "${3:-}" > "$f"
  gh_rest_comment "${1:?slug}" "${2:?num}" "$f"; rc=$?
  rm -f "$f"
  return "$rc"
}

mc_pr_comment() {
  local sn slug num
  sn=$(mc_rest_slug_num "${1:-}") || return 75
  read -r slug num <<<"$sn"
  mc_issue_comment "$slug" "$num" "${2:-}"
}

# mc_rest_pages <path> [max] — a paginated LIST read, concatenated.
#   `gh api --paginate -i` would print one header block per page and the
#   contract's body parser cannot separate them, so the paging is done here.
#   A page that fails fails the WHOLE read (rc passed through, nothing printed):
#   a truncated list read as complete is the "absent = zero" bug (D11/D12).
mc_rest_pages() {
  local path="${1:?path}" max="${2:-$MC_REST_PAGES_MAX}" p=1 sep='?' body="" rc=0 tmp
  case "$path" in *\?*) sep='&' ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/mc-pages.XXXXXX") || return 75
  while [ "$p" -le "$max" ]; do
    # BH-1485: `gh_rest_var`, not `body=$(gh_rest GET …)`. The rc this loop
    # passes through was always right; the STATUS behind it died in the capture,
    # so a caller alerting on the returned 75 named HTTP 000 for a 403.
    rc=0
    gh_rest_var body GET "${path}${sep}per_page=100&page=$p" || rc=$?
    [ "$rc" = 0 ] || { rm -f "$tmp"; return "$rc"; }
    printf '%s\n' "$body" >> "$tmp"
    [ "$(printf '%s' "$body" | jq 'length' 2>/dev/null || echo 0)" = 100 ] || break
    p=$((p+1))
  done
  # RUNNING OUT OF PAGES IS A FAILED READ, not a short list. The loop above
  # only leaves `p` past the cap when the LAST page it took was full, i.e. there
  # is more and we stopped asking — and a list read as complete when it is not
  # is the same "absent = zero" answer a failed page gives. At the default 30
  # this is GitHub's own 3000-file ceiling on /pulls/{n}/files, so it fires for
  # an operator-lowered cap, which is exactly when it must.
  [ "$p" -le "$max" ] || { rm -f "$tmp"; return 75; }
  jq -s 'add // []' < "$tmp" 2>/dev/null; rc=$?
  rm -f "$tmp"
  return "$rc"
}

# mc_close_shipped <slug> <num> <comment-body> [record-dir] [pr-url]
#   The ONE close-out both merge lanes use, in the one order that survives a
#   half-answer: COMMENT, then CLOSE, then the `ai-build` strip, then — at the
#   caller — the marker. Prints the strip word, rc 0 only when the issue has
#   been RE-READ as closed.
#
#   WHY THE ORDER IS FIXED. A close before a comment leaves a shipped issue with
#   no note saying what shipped; a marker before a verified close is the BH-784
#   defect itself, a record stamped done over an issue that is still open.
#
#   THE COMMENT IS PAID FOR ONCE. `<record>/issue-commented` is written after a
#   201 and read before every attempt, so the retry that follows a 403'd PATCH —
#   or the OTHER lane, since the conductor (*/5) and the sweep (*/10) share the
#   build record — closes without posting a second "Closing this issue".
#
#   THE STRIP IS DELEGATED, NOT REIMPLEMENTED. bin/lib/issue-state-lib.sh owns
#   the `ai-build` rule for all four close paths (BH-637 §3b: the split-child
#   exemption, the switch, the label read), and it is called here with an EMPTY
#   body so it posts nothing — its own `gh issue close` is a no-op on an issue
#   this function has already read as closed. Its reads are still GraphQL and
#   BH-781 owns converting them, so a failure there is `strip-deferred`: the
#   issue IS verifiably closed, the label may still be on, and the caller's log
#   line says which. That is the same gap today's main has, not a new one.
mc_close_shipped() {
  local slug="${1:-}" num="${2:-}" body="${3:-}" rec="${4:-}" pr="${5:-}" w g kids src
  [ -n "$slug" ] && [ -n "$num" ] || { printf 'close-failed\n'; return 1; }
  # BH-2477: with the PR url, ask issue_close_guard whether this merge DELIVERED
  # the issue before anything is written. A slice gets the "Slice delivered"
  # comment (paid once through the same marker), then loses `ai-build`, and stays
  # open, rc 0 because the close-out is settled; a refused comment defers with
  # the label untouched, and an unreadable answer writes nothing and defers, rc 1.
  # A tree without bin/lib/issue-state-lib.sh has no guard and runs as before.
  if [ -n "$pr" ] && command -v issue_close_guard >/dev/null 2>&1; then
    g=$(issue_close_guard "$slug" "$num" "$pr" "$rec" "$MC_H")
    case "$g" in
      close) ;;
      slice:*)
        # BH-4662: slice:plan and slice:no-keyword have not seen a child yet.
        # Read them first: none keeps `ai-build` (the rest is re-offered) and
        # raises one warn alert once the honest comment lands; an unreadable
        # list writes nothing and defers. A lib without the helper runs as before.
        case "$g" in slice:plan|slice:no-keyword)
          if command -v _issue_open_children >/dev/null 2>&1; then
            kids=$(_issue_open_children "$slug" "$num" "$MC_H") || { printf 'close-deferred:children-read\n'; return 1; }
            if [ -z "$kids" ]; then
              # BH-6308: close a parent the merged slices delivered, or file the
              # rest as one child and close it (the same words as
              # issue_slice_settle); rc 3 runs the path below unchanged.
              if command -v sco_settle >/dev/null 2>&1; then
                w=$(sco_settle "$slug" "$num" "$pr" "$g" "$rec" "$MC_H"); src=$?
                case "$src" in
                  4) [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
                     printf 'closed-slice:%s\n' "$w"; return 0 ;;
                  0) [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
                     printf 'kept-slice:%s\n' "$w"; return 0 ;;
                  1) printf 'close-deferred:slice-closeout\n'; return 1 ;;
                esac
              fi
              # BH-5961: a SLICE plan files its remaining slices first (the same
              # four answers as issue_slice_settle). rc 2 already paged critical,
              # so the warn alert below is skipped.
              src=3
              if [ "$g" = slice:plan ] && command -v slice_remainder_settle >/dev/null 2>&1; then
                w=$(slice_remainder_settle "$slug" "$num" "$pr" "$rec" "$MC_H"); src=$?
                case "$src" in
                  0) [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
                     printf 'kept-slice:%s\n' "$w"; return 0 ;;
                  1) printf 'close-deferred:remainder\n'; return 1 ;;
                esac
              fi
              if [ -z "$rec" ] || [ ! -f "$rec/issue-commented" ]; then
                mc_issue_comment "$slug" "$num" "$(issue_slice_body "$pr" slice:no-children "$num")" \
                  || { printf 'comment-deferred\n'; return 1; }
                [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
                [ "$src" = 2 ] || _issue_slice_alert "$MC_H" "$slug" "$num" "$pr"
              fi
              printf 'kept-slice:no-children+label-kept\n'; return 0
            fi
          fi ;;
        esac
        if [ -z "$rec" ] || [ ! -f "$rec/issue-commented" ]; then
          if mc_issue_comment "$slug" "$num" "$(issue_slice_body "$pr" "$g" "$num")"; then
            [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
          else
            printf 'comment-deferred\n'; return 1
          fi
        fi
        # BH-2508: only once the master carries the explanation does it lose
        # `ai-build`, under the lib's own strip rule; a retry answers strip-noop.
        printf 'kept-%s+%s\n' "$g" "$(issue_strip_ai_build "$slug" "$num" "$MC_H" 2>/dev/null)"; return 0 ;;
      *) printf 'close-deferred:%s\n' "${g#unknown:}"; return 1 ;;
    esac
  fi
  if [ -z "$rec" ] || [ ! -f "$rec/issue-commented" ]; then
    if mc_issue_comment "$slug" "$num" "$body"; then
      [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
    else
      printf 'comment-deferred\n'; return 1
    fi
  fi
  gh_rest_close "$slug" "$num" issues >/dev/null 2>&1 || { printf 'close-deferred\n'; return 1; }
  # The issue IS closed from here on; only the label word is still in question.
  # On a tree without bin/lib/issue-state-lib.sh there is no label rule to run,
  # and the shim would just close an already-closed issue a second time.
  [ "${MC_ICS_SHIM:-0}" = 1 ] && { printf 'strip-unavailable\n'; return 0; }
  w=$(issue_close_shipped "$slug" "$num" "" "$MC_H" 2>/dev/null) || w=strip-deferred
  printf '%s\n' "${w:-strip-deferred}"
}

mc_record_for() {
  local url="$1" files d
  files=$(ls -d "$MC_H"/builds/pool-*-*/RESULT "$MC_H"/builds/*-*/RESULT 2>/dev/null) || true
  [ -n "$files" ] || return 1
  d=$(printf '%s\n' "$files" | awk -v u="$url" '
    { f = $0
      if ((getline line < f) > 0 && index(line, "PR_CREATED https://") == 1 && index(line, u)) {
        sub(/\/RESULT$/, "", f); print f; exit }
      close(f) }' 2>/dev/null)
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

# mc_is_harness_pr <branch> <record-dir-or-empty> <body-probe-cmd...>
#   rc 0 when the PR is the harness's: a build record names it, or its head
#   branch is ticket/* or main-red-revert/* (BH-3685), or its body carries run-build's "harness build" marker
#   (the same test bin/review-prs.sh uses to SKIP them). The body is fetched
#   lazily — only when the two cheap tests both miss.
mc_is_harness_pr() {
  local branch="$1" record="$2"; shift 2
  [ -n "$record" ] && return 0
  case "$branch" in ticket/*|main-red-revert/*) return 0 ;; esac
  [ $# -gt 0 ] || return 1
  "$@" 2>/dev/null | head -c 4000 | grep -q "harness build"
}

# mc_issue_of <record-dir-or-empty> <branch> -> the issue number a PR was built
#   for, the pm-changes rule (bin/run-build.sh CLOSES_LINE, bin/merge-sweep.sh
#   "issue close after merge"): the build KEY's digits from the record name
#   (pool-<project>-<PREFIX>-<n>-<stamp> or <project>-<PREFIX>-<n>-<stamp>),
#   falling back to the digits in the branch's last segment (ticket/TK-289)
#   when there is no record. Prints nothing when neither carries a number.
mc_issue_of() {
  local rec="$1" br="$2" n=""
  [ -n "$rec" ] && n=$(basename "$rec" | sed -nE 's/^(pool-)?.*-[A-Za-z]+-([0-9]+)-[0-9]+$/\2/p')
  [ -n "$n" ] || n=$(grep -oE '[0-9]+' <<<"${br##*/}" | head -1)
  printf '%s' "$n"
}

# --- Verdict ---------------------------------------------------------------
# mc_verdict <pr-url> <record-dir-or-empty>
#   prints "<VERDICT>\t<provenance>\t<reviewed_sha>\t<job_id>\t<headbound>"
#   with "-" for absent fields, using exactly the sweep's order: the jobs ledger
#   when it has a row (job_verdict), the record's review.md + reviewed-sha when
#   not. A ledger verdict that CONTRADICTS the record prints CONTRADICTION.
#
#   FIELD 5, `headbound`, is bin/run-build.sh's head-bound gate answering ABOUT A
#   SHA: `n/a` bare, or `<word>@<sha>` for reapproved | blocked | no-verdict, or
#   "-" for every row written before it existed. Printed RAW, suffix and all —
#   deciding whether the sha still matches is the classifier's job, not this
#   reader's. Ledger first (it survives a relay that drops the file), then the
#   record's headbound-outcome file (it survives a worker outage) — the same
#   belt-and-braces the reviewed sha already gets.
mc_verdict() {
  local url="$1" rec="$2" lv="" lt="" lp="" ls="" lj="" lr="" rv="-" rs="-" rh="-" lh=""
  if [ -n "$rec" ]; then
    # The record's verdict through the one shared reader (BH-1625): anchored,
    # final block only, -L because run-build's re-review rounds APPEND to
    # review.md; unknown stays "-" — never APPROVE.
    rv=$(verdict_parse -L "$rec/review.md" 2>/dev/null) || rv="-"
    rs=$(head -1 "$rec/reviewed-sha" 2>/dev/null || true); [ -n "$rs" ] || rs="-"
    rh=$(head -1 "$rec/headbound-outcome" 2>/dev/null || true); [ -n "$rh" ] || rh="-"
  fi
  if type job_verdict_headbound >/dev/null 2>&1; then
    lh=$(job_verdict_headbound "$url" 2>/dev/null || true)
  fi
  case "$lh" in ""|"-"|null) lh="$rh" ;; esac
  if type job_verdict >/dev/null 2>&1; then
    if lv=$(job_verdict "$url" 2>/dev/null) && [ -n "$lv" ]; then
      IFS=$'\t' read -r lv lt lp ls lj lr <<<"$lv"
      if [ -n "$rec" ] && [ "$rv" != "-" ] && [ "$lv" != "$rv" ]; then
        # The sha the contradiction is ABOUT: the ledger's, else the record's
        # (BH-4585). A head-bound re-review that finished on exactly that sha
        # is a newer read of it than either side, so its verdict stands.
        case "$lr" in ""|"-") lr="$rs" ;; esac
        local cv; cv=$(mc_rr_verdict_of "$url" "$lr")
        if [ -n "$cv" ]; then
          printf '%s\t%s\t%s\t%s\t%s' "$cv" "${lp:--}" "$lr" "${lj:--}" "${lh:--}"; return 0
        fi
        printf 'CONTRADICTION\t%s\t%s\t%s\t%s' "${lp:--}" "${lr:--}" "${lj:--}" "${lh:--}"; return 0
      fi
      case "$lr" in ""|"-") lr="$rs" ;; esac
      printf '%s\t%s\t%s\t%s\t%s' "${lv:--}" "${lp:--}" "${lr:--}" "${lj:--}" "${lh:--}"; return 0
    fi
  fi
  local prov="-"
  [ -n "$rec" ] && grep -q "judge provenance" "$rec/pipeline.log" 2>/dev/null && prov=fallback
  printf '%s\t%s\t%s\t-\t%s' "$rv" "$prov" "$rs" "${lh:--}"
}

# mc_rr_verdict_of <pr-url> <sha> -> APPROVE or BLOCK when the conductor's
#   detached head-bound re-review of exactly <sha> finished with that verdict,
#   else nothing (BH-4585). mc_verdict's CONTRADICTION branch reads it.
mc_rr_verdict_of() {
  local url="$1" sha="$2" slug num jf v
  case "$sha" in ""|-) return 0 ;; esac
  type mc_rr_file >/dev/null 2>&1 && type mc_rr_state >/dev/null 2>&1 || return 0
  slug=$(sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p' <<<"$url")
  num=$(mc_num_of_url "$url")
  [ -n "$slug" ] && [ -n "$num" ] || return 0
  jf=$(mc_rr_file "$slug" "$num" "$sha")
  [ "$(mc_rr_state "$jf")" = done ] || return 0
  v=$(mc_rr_field "$jf" verdict)
  case "$v" in APPROVE|BLOCK) printf '%s' "$v" ;; esac
  return 0
}

# mc_contradiction_words <pr-url> <record-dir> -> `ledger <V> vs record <V>`,
#   the two verdicts behind a CONTRADICTION, for the park's reason (BH-4585).
mc_contradiction_words() {
  local lv="-" rv="-"
  type job_verdict >/dev/null 2>&1 && lv=$(job_verdict "$1" 2>/dev/null | cut -f1)
  [ -n "$2" ] && rv=$(verdict_parse -L "$2/review.md" 2>/dev/null)
  printf 'ledger %s vs record %s' "${lv:--}" "${rv:--}"
}

# mc_job_running <pr-url> -> rc 0 when the PR's OWN BUILD IS STILL RUNNING and
#   has not recorded a verdict yet. Prints "job <id> stage <stage> running for
#   <n>s" for the log line; rc 1 means there is nothing to wait for.
#
#   WHY THE CONDUCTOR WAITS FOR IT (2026-09-14). A pool build reviews its own
#   PR at the END of its pipeline and writes the verdict into the ledger. The
#   conductor's */5 tick sees the PR the moment it is opened, which is MINUTES
#   before that — and with no verdict bound to the head it would buy a Fable
#   re-review of code the build's own reviewer is already reading. That is two
#   reviews of one head, the second one paid for by us, and on project-5 #864 it
#   is also how the row ended up parked on a `provenance` the build had not
#   even finished writing. So: a job row that is running and has no verdict yet
#   OWNS this PR, and the tick leaves it alone.
#
#   IT IS BOUNDED. A builder that dies mid-pipeline leaves `running` in the row
#   for ever, and a conductor that believed it would never review that PR again.
#   Past MC_JOB_WAIT_SECS (default 3600s, comfortably longer than a build) the
#   row is treated as dead and the tick proceeds exactly as it does today.
#
#   FAIL-OPEN like every other ledger read here: no client, no worker, no
#   answer, no wait.
MC_JOB_WAIT_SECS="${MC_JOB_WAIT_SECS:-3600}"
mc_job_running() {
  local url="${1:-}" resp q id st stage upd age now
  [ -n "$url" ] || return 1
  type _jobs_req >/dev/null 2>&1 || return 1
  q=$(jq -nr --arg v "$url" '"pr="+($v|@uri)' 2>/dev/null) || return 1
  resp=$(_jobs_req GET "/api/verdict?$q") || return 1
  # A row that already carries a SETTLED verdict has finished the review this
  # guard exists to wait for, whatever its status still says.
  #
  # SETTLED, since BH-858: the build now records its verdict when the review
  # settles, minutes before the PR opens and several demoters before the pipeline
  # ends. Reading "the field is non-empty" would disarm this guard in the middle
  # of the very build it exists to leave alone — the tick would buy a second
  # Fable read of a head the build's own reviewer has just finished with. A
  # provisional row (`settled:false`) is not a finished review. Absent detail,
  # unparseable detail and rows written before the field existed all read as
  # settled, so nothing already in the ledger changes meaning.
  [ -z "$(printf '%s' "$resp" | jq -r '
    if (.verdict // "") == "" then ""
    else (([.artifacts[]? | select(.artifact_kind == "verdict") | .detail // ""] | first // "")
          | if . == "" then "settled"
            else (try (fromjson | (if .settled == false then "" else "settled" end))
                  catch "settled") end)
    end' 2>/dev/null)" ] || return 1
  IFS=$'\t' read -r id st stage upd <<<"$(printf '%s' "$resp" | jq -r \
    '[(.job_id // "-"), (.job.status // "-"), (.job.stage // "-"),
      (.job.updated_at // .job.created_at // "")] | @tsv' 2>/dev/null)"
  [ "${st:-}" = running ] || return 1
  now=$(mc_now)
  [ -n "${upd:-}" ] && age=$(date -u -d "${upd:-}" +%s 2>/dev/null) || age="$now"
  case "$age" in ''|*[!0-9]*) age="$now" ;; esac
  age=$(( now - age )); [ "$age" -ge 0 ] || age=0
  [ "$age" -lt "${MC_JOB_WAIT_SECS:-3600}" ] || return 1
  printf 'job %s stage %s running for %ss' "${id:--}" "${stage:--}" "$age"
}

# --- CI ----------------------------------------------------------------------
# mc_ci_state <owner/repo> <sha> -> green | pending | red | none | unavailable
#   Read through actions/runs (the checks API is 403 for our PATs — the same
#   read bin/review-prs.sh makes). "none" = no usable run on this sha yet.
#
#   A CANCELLED RUN IS NOT A RED ONE (2026-09-14, project-5 #586). A push that
#   supersedes an in-flight run cancels it, so a sha whose CI is entirely green
#   carries a cancelled E2E entry from the run it replaced — and this read
#   answered `red`, which parked the PR at "re-review deferred — CI red" against
#   a workflow that never failed. Same for `skipped` (a path filter said this
#   workflow had nothing to do) and `neutral`. None of the three is evidence
#   either way, which is exactly how bin/pipeline-health.sh already reads them.
#
#   AND NEITHER IS A KILLED RUNNER (BH-636). `timed_out` sat in the RED set here
#   while `cancelled` was forgiven, and it is the same fact told differently: a
#   runner that ran out of its limit (or was OOM-killed, which GitHub reports as
#   a timeout) says nothing whatever about the diff. It cost a red strike, then
#   one rerun, then RED_TWICE — a fresh rebuild of a ticket that was never
#   broken. It joins the dropped group; what the ladder does about it instead is
#   mc_ci_flake_runs below. `failure` is the only conclusion left that means the
#   code is wrong, which is the whole of what this function is asked.
#
#   And only the LATEST run of each workflow counts. A failure that was re-run
#   green leaves both entries on the sha; judging the set would keep a fixed
#   workflow red for ever. Latest per workflow NAME, newest start then highest
#   run_attempt, so both shapes (a re-run attempt on one run, a second run of
#   the same workflow) resolve to the answer that is true now.
#
#   BH-1586: the read is gh_rest (ledgered, ETag — an unchanged run list is a
#   304), into a variable through mc_rest_var; any non-0 is `unavailable`, as
#   a failed `gh api` was.
mc_ci_state() {
  local slug="$1" sha="$2" runs
  mc_rest_var runs gh_rest GET "repos/$slug/actions/runs?head_sha=$sha&per_page=50" || { echo unavailable; return 0; }
  runs=$(jq -r '[.workflow_runs[]? | {n: ((.name // .workflow_id // "?") | tostring),
                              t: ((.run_started_at // .created_at) // ""),
                              a: (.run_attempt // 1),
                              s: (.status // ""), c: (.conclusion // "")}]
        | group_by(.n) | map(sort_by(.t, .a) | last)
        | .[] | "\(.s)|\(.c)"' <<<"$runs" 2>/dev/null) || { echo unavailable; return 0; }
  [ -n "$runs" ] || { echo none; return 0; }
  runs=$(grep -vE '^completed\|(cancelled|timed_out|skipped|neutral)$' <<<"$runs")
  # Every surviving workflow was cancelled or skipped: no failure, but no proof
  # of a pass either. `none` is the honest word — the classifier waits on it.
  [ -n "$runs" ] || { echo none; return 0; }
  grep -qv '^completed|' <<<"$runs" && { echo pending; return 0; }
  grep -qE '^completed\|failure$' <<<"$runs" && { echo red; return 0; }
  echo green
}

# mc_ci_flake_runs <owner/repo> <sha> -> "<run-id>|<workflow name>[|<head_sha>]" per LATEST
#   run of a workflow on this sha that ended cancelled or timed_out; nothing
#   when there is none.
#
#   WHY IT IS A SIDE READ AND NOT A FIFTH WORD OF mc_ci_state. Half the fleet
#   compares that answer with `= green` / `= none`, and project-5 #586 pinned
#   {green, cancelled} = green and {all cancelled} = none. A `flake` word would
#   break every one of those. What the ladder actually needs is not a different
#   verdict — it is the LIST of runs to re-run, which is this.
#
#   Same endpoint and the same latest-per-workflow reduction as mc_ci_state, so
#   the two answers can never disagree about which run is current. A READ THAT
#   FAILS PRINTS NOTHING AND SUCCEEDS: "no flake evidence" is the only honest
#   reading of a 500, and it buys no rerun. Same for a run whose cancellation
#   was superseded by a success on a later attempt — latest wins, so it is not
#   a flake and nothing is re-run.
mc_ci_flake_runs() {
  local slug="$1" sha="$2" runs
  mc_rest_var runs gh_rest GET "repos/$slug/actions/runs?head_sha=$sha&per_page=50" || return 0
  runs=$(jq -r '[.workflow_runs[]? | {i: ((.id // "") | tostring),
                              n: ((.name // .workflow_id // "?") | tostring),
                              t: ((.run_started_at // .created_at) // ""),
                              a: (.run_attempt // 1),
                              s: (.status // ""), c: (.conclusion // ""),
                              h: (.head_sha // "")}]
        | group_by(.n) | map(sort_by(.t, .a) | last)
        | .[] | select(.s == "completed" and (.c == "cancelled" or .c == "timed_out"))
        | "\(.i)|\(.n)" + (if .h != "" then "|\(.h)" else "" end)' <<<"$runs" 2>/dev/null) || return 0
  [ -n "$runs" ] && printf '%s\n' "$runs"
  return 0
}

# mc_ci_word <ci-state> [flake-list] -> the word the LOG uses for this head.
#   `none` is `absent` to a reader (BH-636: "distinguish ci=red, ci=absent and
#   ci=pending explicitly"), a non-empty flake list outranks both, and every
#   other state is already its own word.
mc_ci_word() {
  local state="${1:-}"
  [ -n "${2:-}" ] && { printf 'flake'; return 0; }
  case "$state" in none) printf 'absent' ;; *) printf '%s' "$state" ;; esac
}

# --- Iron-law scan (lifted verbatim from bin/merge-sweep.sh's block) ----------
# mc_iron_law_scan <diff-file> -> prints the red-flag count (0 = clean)
mc_iron_law_scan() {
  # Evidence artifacts are not product code (2026-09-13, project-5 #499/#492 parked
  # on 49 hits, every one inside tasks/**/TK-*-RED-OUTPUT.txt and the committed
  # plan/build-log prose): tasks/, docs/, *.md and *.txt are skipped like tests are.
  local f="$1" flags checks_run="" out rc
  flags=$(awk '/^\+\+\+ /{skip=($2 ~ /\.(test|spec)\.|__tests__\/|__mocks__\/|\/tests?\/|scripts\/migrations\/|\.harness\/specs\/|^b\/tasks\/|^b\/docs\/|\.md$|\.txt$/)} /^\+/ && !/^\+\+\+/ && !skip && $0 !~ /^\+[[:space:]]*(\/\/|\*|\/\*|#|--|<!--)/' "$f" | \
    grep -cE "window\.(confirm|alert|prompt)\(|claude-(fable|opus|sonnet|haiku)|VERCEL_URL" || true)
  [ -x "$MC_H/bin/checks-run.sh" ] && checks_run="$MC_H/bin/checks-run.sh"
  if [ -n "$checks_run" ] && [ -s "$f" ]; then
    out=$("$checks_run" "$f" 2>/dev/null); rc=$?
    [ "$rc" = 1 ] && flags=$((flags + $(printf '%s\n' "$out" | grep -c '^CHECK-HIT ')))
  fi
  echo "${flags:-0}"
}

# mc_hb_blocks <headbound> <head> -> rc 0 when the head-bound gate BLOCKED the
#   head this PR is sitting on right now, i.e. a reviewer read exactly this code
#   and said no.
#
#   WHY THE SHA IS LOAD-BEARING. A bare `blocked` says a reviewer refused SOME
#   head, and nothing more. Push a fix on top of that head and the record still
#   reads "blocked" — so a classifier that trusted the word alone would park a
#   head no reviewer has ever seen, forever, which is a worse version of the bug
#   this whole change exists to kill. The gate therefore writes `blocked@<sha>`
#   and this answers yes only when the sha is the current head.
#
#   A LEGACY BARE `blocked` IS THEREFORE A NO. Records written before the suffix
#   shipped cannot say which head they judged, and the safe reading of "we do not
#   know" is "buy the re-review" (HEAD_MOVED), never "park a human on it".
#   Prefixes compare both ways so an 8-char row and a 40-char head agree, with a
#   7-char floor so a stray short string cannot match half the repo.
mc_hb_blocks() {
  local hb="$1" head="$2" word="${1%%@*}" sha=""
  [ "$word" = blocked ] || return 1
  case "$hb" in *@*) sha="${hb#*@}" ;; *) return 1 ;; esac
  [ -n "$sha" ] && [ -n "$head" ] || return 1
  [ "${#sha}" -ge 7 ] || return 1
  case "$head" in "$sha"*) return 0 ;; esac
  case "$sha" in "$head"*) [ "${#head}" -ge 7 ] && return 0 ;; esac
  return 1
}

# --- A REFUSED HEAD BUYS OUR OWN READ BEFORE IT IS PARKED (2026-09-16) --------
# Lever 2 of the project-5 acceleration (the operator, "urgent"). `blocked@<this head>`
# used to park the PR on `head-not-reapproved` the instant mc_classify saw it,
# and every one of those parks cost bin/blocked-resolver.sh a FULL agent fix
# round: 61 of them on project-5 on 2026-09-16 alone, each one a lane, a branch
# and a wait, to answer a question a single detached read answers in minutes.
#
# The word came from the BUILD's OWN head-bound gate (bin/run-build.sh's
# `HB_OUTCOME`), which runs on whatever runner that build's survival ladder
# reached — and the conductor already knows how to buy the better and cheaper
# answer: the detached head-bound Claude re-review it buys for every other moved
# head (mc_rereview_spawn). So the refusal now BUYS THAT READ FIRST. The
# classifier answers HEAD_MOVED, the HEAD_MOVED arm spawns the re-review, the PR
# waits in that state while it runs, and the park happens only when the
# conductor's OWN read comes back BLOCK.
#
# THAT SECOND REFUSAL IS RECORDED HERE, per (PR, head), for exactly the reason a
# provenance clearance is (mc_prov_clear next door): the row must not oscillate.
# Without it, a park the resolver later releases would classify as HEAD_MOVED
# again, find its one-per-(PR, head) job already consumed, and sit there with
# nothing left to buy and nothing left to park it. With it, every later tick of
# that head agrees on the park, and a PUSH — a new head — is unread code again
# and buys its own read, exactly as it does today.
#
# MC_REREVIEW_ON_MOVE=0 restores the immediate park, byte-for-byte.
# mc_hb_refused <key> <head> -> rc 0 when the conductor's OWN head-bound
#   re-review has already BLOCKED this exact head.
mc_hb_refused() { mc_attempt_has "hbrefused $1 $2" 2>/dev/null; }
# mc_hb_refuse <key> <head> — record that it has. Idempotent, append-only.
mc_hb_refuse() {
  mc_hb_refused "$1" "$2" || mc_attempt_put "hbrefused $1 $2"
  return 0
}

# --- A HUMAN MERGE ON THIS HEAD OUTRANKS OUR OWN BLOCK OF IT (BH-3814) -------
# bin/lead-verdict.sh's contract: a lead/human MERGE or MERGE-WITH-NOTES row
# clears the conductor for THAT head. The re-review BLOCK above is the
# conductor's own read, and project-4 #1815 is what happened when nothing compared
# the two: a body-only BLOCK at 16:04Z, a human MERGE-WITH-NOTES (#366) on the
# same head at 16:19Z, and at 16:33Z the BLOCK was consumed and handed to the
# resolver for an agent fix round on a PR a human had already cleared.
#
# The newest verdict wins. The BLOCK's time is the job's finished_at, or (when
# there is no job file: a resolver re-review BLOCK, the autopilot's, a job gc'd
# after three days) the time the hand-off record parked THIS head, which is
# never earlier than the BLOCK. The comparison is made EVERY time, against the
# newest BLOCK time readable: a lane re-review re-run on the same head after an
# override rewrites the job file, and its later BLOCK ends the override. Only
# when neither time is readable does an override already applied to this head
# (the `hvoverride` marker: the job gc'd, the park released) still stand.
# Otherwise an unknowable block time is "no override".
#
# A LEAD row overrides only where lead authority stands (BH-3683): on a
# protected-path PR, or with the repo's lane authority revoked, bin/lead-verdict.sh
# records the lead MERGE as advisory (authority:human-required) and publishes
# nothing, so it must not clear our BLOCK either. la_decide <slug> <num> <head>
# lead is asked last (it reads the PR's files): rc 1 or no la_decide loaded is no
# override; rc 2 is a hold. A human row needs no such read.
# mc_hv_override <key> <head> -> rc 0 a lead/human MERGE|MERGE-WITH-NOTES row
#   stands on THIS head and is newer than our own BLOCK of it; rc 1 no (none, a
#   BLOCK row, older, the block time unknowable, or a lead row without lead
#   authority); rc 2 the verdicts table could not be read, or la_decide could
#   not decide for a lead row. Sets MC_HV_ID MC_HV_VERDICT MC_HV_SOURCE MC_HV_AT
#   (call it in THIS shell, never in $( )).
mc_hv_override() {
  local key="$1" head="$2" line rc v src id at bt atsec jf hf
  MC_HV_ID=""; MC_HV_VERDICT=""; MC_HV_SOURCE=""; MC_HV_AT=""
  command -v vd_standing >/dev/null 2>&1 || return 1
  [ -n "$key" ] && [ -n "$head" ] && [ "$head" != - ] || return 1
  line=$(vd_standing "${key%#*}" "${key##*#}" "$head"); rc=$?
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 0 ] || return 1
  IFS=$'\t' read -r v src id at _ <<<"$line"
  case "$v" in MERGE|MERGE-WITH-NOTES) ;; *) return 1 ;; esac
  case "$src" in lead|human) ;; *) return 1 ;; esac
  MC_HV_ID="$id"; MC_HV_VERDICT="$v"; MC_HV_SOURCE="$src"; MC_HV_AT="$at"
  bt=""
  jf=$(mc_rr_file "${key%#*}" "${key##*#}" "$head")
  [ -f "$jf" ] && bt=$(mc_rr_field "$jf" finished_at)
  case "$bt" in ''|*[!0-9]*|0) bt="" ;; esac
  if [ -z "$bt" ]; then
    hf=$(mc_handoff_file "$key")
    [ "$(cut -f2 "$hf" 2>/dev/null)" = "$head" ] && bt=$(cut -f1 "$hf" 2>/dev/null)
    case "$bt" in ''|*[!0-9]*|0) bt="" ;; esac
  fi
  if [ -z "$bt" ]; then
    # Already applied to this head, and no BLOCK time is left to compare: the
    # job gc'd and the park released. A later BLOCK row replaces the MERGE as
    # `standing` and was refused above; a later re-review writes a job file.
    if ! mc_attempt_has "hvoverride $key $head" 2>/dev/null; then
      mc_log "$key human verdict #$id ($v) stands on ${head:0:8}, but the time of our BLOCK of it is unknowable (no job file, no park record for this head) — not overridden"
      return 1
    fi
  else
    [ -n "$at" ] && [ "$at" != - ] || return 1
    atsec=$(date -u -d "$at" +%s 2>/dev/null) || return 1
    case "$atsec" in ''|*[!0-9]*) return 1 ;; esac
    [ "$atsec" -gt "$bt" ] || return 1
  fi
  [ "$src" = lead ] || return 0
  command -v la_decide >/dev/null 2>&1 || return 1
  rc=0; la_decide "${key%#*}" "${key##*#}" "$head" lead || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) mc_log "$key lead verdict #$id ($v) on ${head:0:8}: lead authority undecidable ($LA_REASON) — held, not overridden"; return 2 ;;
    *) mc_log "$key lead verdict #$id ($v) on ${head:0:8} is advisory ($LA_REASON) — a human verdict is required, not overridden"; return 1 ;;
  esac
}

# --- ...AND A PARK ON SILENCE RECORDS ITS SHA TOO (BH-1019) ------------------
# The same shape as mc_hb_refuse above, for the other way this lane stops: a
# `no-verdict` park, where nothing answered at all. The park is real and the
# resolver owns it — but `head != reviewed` is STILL TRUE the moment it lands,
# so the drift branch of mc_classify re-derived the row to HEAD_MOVED on the
# very next tick and the arm armed the spawn again, on a head nobody had
# touched. cromford#818 is that loop written out: eight spawns, five paid
# reads, one PR, no push in between.
#
# So the park records the sha it parked ON, and the reconciliation asks for a
# DIFFERENT one. A push is a new head, carries no record, and buys its read
# exactly as it does today — which is the whole distinction the loop was
# missing.
#
# AND IT RECORDS THE LANE-HEALTH EPOCH WITH IT (BH-1019 review, BLOCK 1). Keyed
# on (PR, head) alone, a push was the ONLY release event this park had — so an
# outage would park every moved head on the box and nothing would re-read one
# when the quota window reset. Keyed on (PR, head, epoch), the park is released
# by the other event too: the lane coming back. That gives exactly ONE re-arm
# per lane recovery, followed by a fresh read cap, and it is the event the docs
# have always claimed. Rows written before this change carry no epoch, match no
# current one, and so re-arm once — bounded, and then bound to sha and epoch.
#
# Nothing here is timed. The two events are a commit and a Claude answer.
# mc_hb_parked <key> <head> <epoch> -> rc 0 when the re-review lane has already
#   parked this exact head, under this lane-health epoch, for want of a verdict.
mc_hb_parked() { mc_attempt_has "hbpark $1 $2 ${3:-0}" 2>/dev/null; }
# mc_hb_park <key> <head> <epoch> — record that it has. Idempotent, append-only.
mc_hb_park() {
  mc_hb_parked "$1" "$2" "${3:-0}" || mc_attempt_put "hbpark $1 $2 ${3:-0}"
  return 0
}

# --- The provenance hold, and what ends it (2026-09-14) ----------------------
# project-5 #864: `HEAD_MOVED -> BLOCKED_HUMAN reason=provenance` at 20:25:41Z,
# the detached re-review of that very head came back APPROVE at 20:34:21Z, and
# nothing read it — the done-job handling lived only in the HEAD_MOVED arm, and
# the row was not in HEAD_MOVED any more. The orchestrator merged it by hand at
# 20:45Z. #867 was the same, #865 and #866 were still sitting in it.
#
# `provenance` says a non-primary runner authored the build's own APPROVE. That
# is a fact about WHO READ THE CODE, and the harness already has the answer to
# it: a claude head-bound review of the head that is sitting there. So the hold
# is not a terminal park, it is a review request — and when that review comes
# back APPROVE on the CURRENT head, the hold is over for that head.
#
# The clearance is recorded in MC_ATTEMPTS, beside `rebase`, `red` and
# `ejected`, rather than in the build record: a pool PR's record lives on the
# builder that made it and may not be on this box at all, and the fact is about
# (PR, head), which is exactly what that file keys on.

# mc_prov_held <prov> -> rc 0 when this provenance word is one mc_classify
#   parks on. `-` and empty are "the ledger said nothing", never a hold.
#
#   CLAUDE IS NOT ONLY THE `claude` RUNNER (2026-09-16). `claude-via-openrouter`
#   is a Claude model that answered through the tier-3 lane — a Claude read of
#   the diff, which is the whole of what this hold asks for — so it is not held
#   either. bin/lib/review-provenance.sh owns that judgement; every other word
#   (codex, grok, fireworks, gemini, a bare `fallback`) holds exactly as before.
mc_prov_held() {
  case "${1:-}" in -|""|null) return 1 ;; esac
  rp_prov_is_claude "$1" && return 1
  return 0
}
# mc_prov_cleared <key> <head> -> rc 0 when a claude head-bound re-review has
#   already APPROVED this exact head — or (BH-1525) a lead/human MERGE /
#   MERGE-WITH-NOTES row stands on it in the verdicts table, which is what the
#   lead's `provcleared` line written over SSH used to say. The line stays the
#   fallback for a worker this box cannot reach.
mc_prov_cleared() { mc_attempt_has "provcleared $1 $2" 2>/dev/null || { command -v vd_clears >/dev/null 2>&1 && vd_clears "${1%#*}" "${1##*#}" "$2"; }; }
# mc_prov_clear <key> <head> — record that it has. Idempotent.
mc_prov_clear() {
  mc_prov_cleared "$1" "$2" || mc_attempt_put "provcleared $1 $2"
  return 0
}

# mc_prov_autoresolving <key> <reason> <head> <age-secs> -> rc 0 (and prints
#   what is happening) when this provenance hold is one the conductor is
#   fixing by itself and a page would only say "auto-resolving"; rc 1 = page.
#   True only for reason=provenance, actions armed (merge-conductor-actions on,
#   automerge-disabled off — read through flag_active, the file as fallback) and age < MC_PROV_AUTO_SECS
#   (default 3600). The printed word names the re-review job state so the log
#   says whether a read is running, finished, or still to be bought.
MC_PROV_AUTO_SECS="${MC_PROV_AUTO_SECS:-3600}"
mc_prov_autoresolving() {
  local key="$1" why="$2" head="$3" age="$4" slug num jst
  [ "$why" = provenance ] || return 1
  if command -v flag_active >/dev/null 2>&1; then flag_active merge-conductor-actions || return 1
  else [ -e "$MC_H/flags/merge-conductor-actions" ] || return 1; fi
  if command -v flag_active >/dev/null 2>&1; then flag_active automerge-disabled && return 1
  else [ -e "$MC_H/flags/automerge-disabled" ] && return 1; fi
  [ "$age" -lt "${MC_PROV_AUTO_SECS:-3600}" ] || return 1
  slug="${key%#*}"; num="${key##*#}"
  jst=$(mc_rr_state "$(mc_rr_file "$slug" "$num" "$head")")
  case "$jst" in
    running) printf 'claude head-bound read of %s is running' "${head:0:8}" ;;
    done)    printf 'claude head-bound read of %s finished, consumed next tick' "${head:0:8}" ;;
    failed|stale) return 1 ;;
    *)       printf 'the conductor buys a claude read of %s once CI is green' "${head:0:8}" ;;
  esac
  return 0
}

# --- Who owns a BLOCKED_HUMAN row (2026-09-13) -------------------------------
# mc_resolver_owns <reason> -> rc 0 when bin/blocked-resolver.sh has an agent
#   ladder for this park, i.e. nobody is waiting on a person and the conductor
#   must NOT page. The reasons here are exactly the ones the resolver's
#   classifier answers with an action; anything else (a reason a future gate
#   invents) still pages, because an unowned park that goes quiet is the
#   failure this whole change exists to prevent.
#
#   `tightened` is NOT here on purpose: bin/review-tighten.sh parks a REPO whose
#   trailing revert rate crossed the threshold, which is a policy state about
#   the repo and not a defect in this PR — rebuilding the PR would not clear it.
mc_resolver_owns() {
  case "${1:-}" in
    conflict-unresolvable*|rebase-gate-red*|queue-ejected-twice*|merge-failed-twice*|\
    queue-enqueue-failed-twice*|no-verdict*|head-not-reapproved*|iron-law*|red-ci-twice*|\
    red-twice*|orphaned-child*|contested*) return 0 ;;
    # stale-replan (BH-3932): the PR-owner age ladder's re-plan rung. Nothing
    # writes it until #3935; listed here because a hand-off reason must be
    # resolver-owned (mc_handoff_owns is a subset of this).
    stale-replan*) return 0 ;;
    # prequeue-red (BH-4545): the head fails its suites merged onto main; the
    # next move is the resolver's fix round.
    prequeue-red*) return 0 ;;
  esac
  return 1
}

# --- resolver claim (BH-3630) --------------------------------------------------
# example-org/project-7#530 sat BLOCKED_HUMAN `provenance (verdict=APPROVE ci=red
# …)` for days: bin/blocked-resolver.sh had no rung for `provenance`, dropped
# the row without a word, and this lane paged it CRITICAL tick after tick.
#
# THE DETAIL. The row's reason is the bare word `provenance`; the verdict and
# the CI word live only in the page text. So the tick writes them down for the
# resolver, per PR, in its own words (the same CIWORD the page prints):
#   state/merge-conductor/prov-detail/<id>   head <TAB> verdict <TAB> ci <TAB> epoch
# present only while the row is BLOCKED_HUMAN on provenance.
#
# THE CLAIM. When the resolver takes an APPROVE + ci=red provenance park onto
# its ci-red ladder it claims it:
#   state/merge-conductor/resolver-claim/<id>
#     head <TAB> reason <TAB> claimed_at <TAB> active_at <TAB> paged_at <TAB> stale_paged_at
# active_at moves only when the resolver RECORDS a rung (br_record calls
# mc_resolver_claim_touch), never on a re-list: a saturated resolver that only
# re-offers the park is doing nothing, and the 24h page is for exactly that.
# mc_budget_check reads the claim as the page ledger of this park (page once,
# once more after MC_CLAIMED_REPAGE_S with no rung, then silence).
mc_prov_detail_file() { printf '%s/prov-detail/%s' "$MC_STATE_DIR" "$(mc_handoff_id "$1")"; }

# mc_prov_detail_put <key> <state> <why> <head> <verdict> <ciword> — always rc 0.
mc_prov_detail_put() {
  local f tmp
  f=$(mc_prov_detail_file "${1:-}")
  if [ "${2:-}" = BLOCKED_HUMAN ] && [ "${3:-}" = provenance ]; then
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    tmp=$(mktemp "${f%/*}/.prov.XXXXXX" 2>/dev/null) || return 0
    printf '%s\t%s\t%s\t%s\n' "${4:--}" "${5:--}" "${6:--}" "$(mc_now)" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$f" 2>/dev/null
  fi
  return 0
}

# mc_prov_detail_get <key> — the detail line, or rc 1 when there is none.
mc_prov_detail_get() {
  local f; f=$(mc_prov_detail_file "${1:-}")
  [ -s "$f" ] || return 1
  head -1 "$f"
}

mc_resolver_claim_file() { printf '%s/%s' "$MC_RESOLVER_CLAIM_DIR" "$(mc_handoff_id "$1")"; }

# _mc_claim_write <key> <awk-program> [awk -v args...] — rewrite one claim under
#   the claim dir's lock. Both lanes write these files and run concurrently; the
#   critical section is one awk over one line.
_mc_claim_write() {
  local key="$1" prog="$2" f tmp; shift 2
  mkdir -p "$MC_RESOLVER_CLAIM_DIR" 2>/dev/null || return 0
  f=$(mc_resolver_claim_file "$key")
  ( flock 9 2>/dev/null
    tmp=$(mktemp "$MC_RESOLVER_CLAIM_DIR/.claim.XXXXXX" 2>/dev/null) || exit 0
    awk -F'\t' -v OFS='\t' "$@" "$prog" "$f" > "$tmp" 2>/dev/null </dev/null
    if [ -s "$tmp" ]; then mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
  ) 9>>"$MC_RESOLVER_CLAIM_DIR/.lock" 2>/dev/null
  return 0
}

# mc_resolver_claim <key> <head> <reason> — claim this park for the resolver.
#   A claim already standing on the SAME head is left exactly as it is (its
#   stamps are the page ledger, and a re-list is not activity). A claim on
#   another head, or none, is replaced by a fresh one.
mc_resolver_claim() {
  local key="${1:-}" head="${2:-}" reason="${3:--}" f now
  [ -n "$key" ] && [ -n "$head" ] || return 0
  f=$(mc_resolver_claim_file "$key")
  [ -e "$f" ] || { mkdir -p "$MC_RESOLVER_CLAIM_DIR" 2>/dev/null; : >> "$f" 2>/dev/null; }
  now=$(mc_now)
  _mc_claim_write "$key" \
    'NR==1 && $1==h {print; done=1; exit} END {if (!done) print h, r, n, n, "-", "-"}' \
    -v h="$head" -v r="$reason" -v n="$now"
}

# mc_resolver_claim_touch <key> — a resolver rung was recorded: active_at=now.
#   No claim, no-op.
mc_resolver_claim_touch() {
  local f; f=$(mc_resolver_claim_file "${1:-}")
  [ -s "$f" ] || return 0
  _mc_claim_write "$1" 'NR==1 {$4=n; print; exit}' -v n="$(mc_now)"
}

# mc_resolver_claim_get <key> <head> — the claim line when it stands on THIS
#   head, rc 1 otherwise. A claim on another head is not this park's.
mc_resolver_claim_get() {
  local f line; f=$(mc_resolver_claim_file "${1:-}")
  [ -s "$f" ] && [ -n "${2:-}" ] || return 1
  line=$(head -1 "$f")
  [ "$(cut -f1 <<<"$line")" = "$2" ] || return 1
  printf '%s\n' "$line"
}

# mc_resolver_claim_mark <key> <paged|stale> — stamp paged_at or stale_paged_at.
mc_resolver_claim_mark() {
  local f col; f=$(mc_resolver_claim_file "${1:-}")
  [ -s "$f" ] || return 0
  case "${2:-}" in paged) col=5 ;; stale) col=6 ;; *) return 0 ;; esac
  _mc_claim_write "$1" 'NR==1 {$c=n; print; exit}' -v c="$col" -v n="$(mc_now)"
}

# mc_resolver_claim_gc — the prov-detail and claim files of PRs settled long
#   ago, on mc_stuck_gc's two-week rule.
mc_resolver_claim_gc() {
  find "$MC_STATE_DIR/prov-detail" "$MC_RESOLVER_CLAIM_DIR" -maxdepth 1 -type f ! -name .lock -mtime +14 -delete 2>/dev/null
  return 0
}
# --- The hotfix migration proof (BH-370.2) -----------------------------------
# mc_hotfix_proof <owner/repo> <num> <labels-csv> [record-dir] [project] -> ONE WORD on
#   stdout, rc always 0 (the caller switches on the word, never on the rc):
#     n/a      this gate has nothing to say: not a hotfix PR, or it adds no
#              migration file
#     ok       an accepted proof for exactly this SQL
#     stale    a proof, but for other SQL — or a marker nobody can read
#     hold     the stage deliberately did not apply it
#     missing  no proof, or GitHub would not tell us
#
#   THE SHARED CONTRACT (BH-370, identical wording in every child — do not drift):
#     Migration files of a PR = files with git status `added` (never modified)
#     matching scripts/migrations/*.sql or prisma/migrations/manual/*.sql (plus
#     $HOTFIX_MIGRATE_GLOB when set, plus the project's migrations_glob.<project>
#     row when it holds a valid value, BH-5963, with `*` not crossing `/`). Same
#     definition as check-migration-appliable.sh's --diff-filter=A.
#     bin/hotfix-migrate.sh adds the same row to scripts/migrations/*.sql, never
#     in place of it, so both sides fingerprint the same files. An unreadable row
#     is `missing` here: the gate cannot know which files count, so it waits.
#     Fingerprint FP = sha256 of the sorted lines "<path> <git blob sha>" over
#     those files. bin/hotfix-migrate.sh computes it with git hash-object; the
#     `.sha` of the files endpoint IS that blob sha, so both sides land on the
#     same string, a rebase that leaves the SQL untouched keeps the proof, and
#     any edit to the SQL invalidates it.
#     Proof comment first line, exactly:
#       <!-- hotfix-migrate-proof fp=<FP> decision=<applied|deferred-to-deploy|hold|flagged|no-path> -->
#     Accepted by the conductor: `applied` or `deferred-to-deploy` with a
#     matching FP. `hold`, `flagged`, `no-path`, a stale FP or no marker are not
#     accepted.
#
#   FAIL CLOSED, in the one direction that matters. A files read that FAILS is
#   `missing`, never `n/a`: an expired token answering "this PR has no
#   migrations" would merge unapplied SQL on every repo in the fleet, which is
#   the whole failure this gate exists to prevent. Same for the comments read.
#
#   FP BEFORE DECISION. A marker whose FP does not match is `stale` even when it
#   says `hold`, because a hold about different SQL says nothing about the SQL
#   this head carries, and a fresh stage run is the cheaper, reversible answer.
#
#   NEWEST MARKER WINS. gh lists comments oldest first, so `last` is the newest
#   thing the stage said, which is the only one that describes what it did.
#
#   Reads only — it never posts a proof and never calls bin/hotfix-migrate.sh.
#   At most two gh calls for a hotfix-labelled PR (one when it adds no SQL),
#   ZERO for every other PR, because the label is already in the caller's row.
mc_hotfix_proof() {
  local slug="${1:-}" num="${2:-}" csv="${3:-}" rec="${4:-}" proj="${5:-}" files line path g keep="" fp marker mfp dec hfp_glob rowg=
  [ -n "$slug" ] && [ -n "$num" ] || { echo n/a; return 0; }
  # The label gate, with no API call. hotfix_pr_is is the fleet's one answer to
  # "is this the emergency" (exact whole-name match, the HOTFIX_LABEL knob, the
  # kill flag, the build record's ticket-meta.json); the literal match is the
  # fallback for a tree that has not sourced bin/lib/hotfix-lib.sh.
  if command -v hotfix_pr_is >/dev/null 2>&1; then
    hotfix_pr_is "$csv" "$rec" || { echo n/a; return 0; }
  else
    case ",$csv," in *,hotfix,*) ;; *) echo n/a; return 0 ;; esac
  fi
  mc_rest_var files _gh_rest_list "$slug" "pulls/$num/files" 1000 '.' || { echo missing; return 0; }  # BH-1586: paged gh_rest
  files=$(jq -r '.[] | select(.status=="added") | "\(.filename) \(.sha)"' <<<"$files" 2>/dev/null) || { echo missing; return 0; }
  # THE PROJECT'S migrations_glob ROW (BH-5963), only when the PR adds a file at
  # all. An unreadable row is `missing`, never the default: SQL under the row's
  # dir would otherwise read as `n/a` and merge unapplied.
  if [ -n "$files" ] && [ -n "$proj" ] && [ "$proj" != - ]; then
    declare -F mg_glob >/dev/null 2>&1 \
      || . "$(dirname "${BASH_SOURCE[0]}")/../migrations-glob.sh" 2>/dev/null || true
    if declare -F mg_glob >/dev/null 2>&1; then
      mg_glob "$proj" >/dev/null
      case "$MG_SRC" in
        unreadable) echo missing; return 0 ;;
        migrations_glob.*) rowg="$MG_GLOB" ;;
      esac
    fi
  fi
  # NOGLOB WHILE SPLITTING $HOTFIX_MIGRATE_GLOB. The word split below is what
  # turns "a b" into two patterns, and the same expansion also PATHNAME-expands
  # them: a caller whose cwd happened to hold a file matching db/manual/*.sql
  # would get that filename as the pattern instead, and the gate would then
  # match one exact path rather than the glob. `set -f` is saved and restored,
  # because this function is sourced into scripts that rely on globbing.
  hfp_glob=0; case "$-" in *f*) ;; *) hfp_glob=1; set -f ;; esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # The sha is the LAST field, so the path is everything before it — a path
    # with a space in it still matches its glob.
    path="${line% *}"
    case "$path" in
      scripts/migrations/*.sql|prisma/migrations/manual/*.sql) keep="$keep$line"$'\n'; continue ;;
    esac
    if [ -n "$rowg" ] && mg_path_in "$rowg" "$path"; then keep="$keep$line"$'\n'; continue; fi
    for g in ${HOTFIX_MIGRATE_GLOB:-}; do
      # shellcheck disable=SC2254
      case "$path" in $g) keep="$keep$line"$'\n'; break ;; esac
    done
  done <<<"$files"
  if [ "$hfp_glob" = 1 ]; then set +f; fi
  [ -n "$keep" ] || { echo n/a; return 0; }
  fp=$(printf '%s' "$keep" | sort | sha256sum | awk '{print $1}')
  # REST since BH-1585 (was the file's last GraphQL read, #854): the issue
  # comments through the same paged gh_rest reader as the files read above
  # (ledgered, ETag'd, a failed page fails the read). REST lists comments oldest
  # first, as gh did, so `last` is the newest marker. A read that fails is still
  # `missing`, never `n/a`.
  local comments
  mc_rest_var comments _gh_rest_list "$slug" "issues/$num/comments" 1000 '.' || { echo missing; return 0; }  # BH-1585: paged gh_rest
  marker=$(printf '%s' "$comments" | jq -r '[.[] | select((.body // "") | startswith("<!-- hotfix-migrate-proof "))] | last | (.body // "") | split("\n") | (.[0] // "")' 2>/dev/null) \
    || { echo missing; return 0; }
  [ -n "$marker" ] || { echo missing; return 0; }
  mfp=$(printf '%s' "$marker" | sed -nE 's/.*[[:space:]]fp=([0-9a-fA-F]+).*/\1/p')
  dec=$(printf '%s' "$marker" | sed -nE 's/.*[[:space:]]decision=([A-Za-z-]+).*/\1/p')
  [ -n "$mfp" ] && [ "$mfp" = "$fp" ] || { echo stale; return 0; }
  case "$dec" in
    applied|deferred-to-deploy) echo ok ;;
    hold|flagged|no-path)       echo hold ;;
    *)                          echo stale ;;
  esac
  return 0
}

# mc_park_state <state> -> rc 0 for the states that mean "this lane cannot move
#   the PR": BLOCKED_HUMAN and, since 2026-09-15, RED_TWICE. They age, alert and
#   display by the same rules, so the three places that used to test the one word
#   ask this instead.
mc_park_state() { case "${1:-}" in BLOCKED_HUMAN|RED_TWICE) return 0 ;; esac; return 1; }
# mc_state_display <state> [reason] -> the name a HUMAN-FACING string uses.
#   BLOCKED_HUMAN stays the stored word (every row and every reader keys on it);
#   BLOCKED_AGENT is what it is CALLED wherever a person reads it, because the
#   work is with bin/blocked-resolver.sh, not with a person.
mc_state_display() {
  if [ "${1:-}" = BLOCKED_HUMAN ] && mc_resolver_owns "${2:-}"; then echo BLOCKED_AGENT; else echo "${1:-}"; fi
}

# mc_ttl <STATE> -> seconds a PR may sit in ONE state before the stuck detector
#   says so (mc_stuck_check). -1 = no TTL: the three terminals, and any word this
#   table does not know.
#
#   WHY THIS IS NOT mc_budget. The budget is the ordinary age alert — "READY for
#   15m and not merged" — and several states deliberately do not page on it at
#   all (a park the resolver owns, an ABANDONED outcome). The TTL is the
#   BACKSTOP under all of it: whatever the state, whatever its budget, a PR that
#   has not moved in this long is stuck, and the alert names what it is waiting
#   on and what re-kick was tried. project-5 #1045 sat 10h inside its state's
#   budget (it had already paged once, at 30m) and #1124/#1136 sat hours in a
#   park that pages never; no budget in the table above could have caught either.
#
#   Every default is overridable per state from env/global.env as MC_TTL_<STATE>
#   (seconds; -1 turns one off). The defaults are the operator's, 2026-09-15.
mc_ttl() {
  local st="${1:-}" v d
  case "$st" in
    WAIT_CI)       d=5400 ;;   # 90m: a required check that has not reported in an hour and a half is not coming
    WAIT_REVIEW)   d=5400 ;;   # a one-tick parking state; 90m in it is a row nothing re-classified
    HEAD_MOVED)    d=5400 ;;   # two full MC_REREVIEW_TIMEOUT_SECS windows and no verdict
    NEEDS_REBASE)  d=1800 ;;   # 30m: the rebase is detached and takes minutes
    REBASING)      d=1800 ;;   # 30m: MC_REBASE_TIMEOUT_SECS is 1800 — past it the job is gone, not slow
    QUEUED)        d=3600 ;;   # an hour in the merge queue is a wedged queue
    READY)         d=1200 ;;   # 20m: READY and unmerged means the merge flag, the budget, or a refusal
    STACKED_WAIT)  d=21600 ;;  # 6h: one chain level is 60-75 min on project-5 plus the parent's own review
    BLOCKED_HUMAN) d=7200 ;;   # 2h: the resolver's ladder runs every 10 min, so two hours is many rungs
    NEEDS_HUMAN_VERDICT) d=3600 ;;  # an hour: only a person moves it, so the page is the hand-off (BH-3777)
    RED_TWICE)     d=7200 ;;
    *)             d=-1 ;;     # MERGED, CLOSED, ABANDONED and anything unknown
  esac
  v="MC_TTL_$st"; v="${!v:-}"
  case "$v" in ''|*[!0-9-]*) printf '%s' "$d" ;; *) printf '%s' "$v" ;; esac
}

# mc_park_human_action <reason> -> the NEXT MOVE this park names, for the one
#   park that has one to name (BH-292): a conflict git could not resolve. Every
#   other reason prints nothing, and its lines stay byte-for-byte what they
#   were — `rebase-gate-red` is a red gate, not a conflict, and
#   `head-not-reapproved` is the resolver's fix round. Since BH-5967 the move is
#   an agent's, never a person's: there are no human reviews and nobody
#   rebases by hand (the operator, 2026-10-10), so the line names the fix round that
#   resolves the conflict.
mc_park_human_action() {
  case "${1:-}" in
    conflict-unresolvable*) printf 'next step: an agent fix round (bin/blocked-resolver.sh) merges main into this branch and resolves the conflict, or re-plans the ticket with the conflicting files in scope; no person rebases' ;;
  esac
  return 0
}

# mc_identity_blocked <reason> -> rc 0 when this row is BLOCKED because the push
#   identity is not on the base branch's push allow-list (BH-988). GitHub
#   answers mergeState BLOCKED with no required check to report and no review to
#   buy; nothing in this lane moves such a row, only a repo admin does, so the
#   identity alert bin/merge-conductor.sh sends is the whole page and the budget
#   and the TTL must not add to it.
#
#   THE ANCHOR IS A PREFIX, terminated by the end of the string or by a space —
#   never a substring search. This predicate SUPPRESSES alerts, so every reason
#   it matches by accident is a PR that stops paging and nobody finds out:
#   `conflict-unresolvable: bin/lib/IDENTITY_NOT_PERMITTED-notes.sh` carries the
#   token and is a park the resolver owns, `IDENTITY_NOT_PERMITTEDX` is a
#   different word, and both must still page. An empty reason and `-` are rows
#   with nothing recorded, which is the one state that most needs its alert.
#
#   It gates three things and nothing else: mc_budget_check's identity arm,
#   mc_stuck_check's early return, and the sentence mc_stuck_waiting_on prints
#   for a WAIT_CI row.
mc_identity_blocked() {
  case "${1:-}" in
    IDENTITY_NOT_PERMITTED|"IDENTITY_NOT_PERMITTED "*) return 0 ;;
  esac
  return 1
}

# ── WHY A READY ROW DID NOT MERGE (2026-09-27) ──────────────────────────────
# The READY arm of bin/merge-conductor.sh used to `return 0` in silence when a
# ticket HOLD, the merge switch or the lead fence stopped the merge, so neither
# pipeline-health's sweepstall detector nor the STUCK page could tell a PR held
# on purpose from one nobody was landing (816 false sweepstall pages from 09-26).
#
# mc_ready_why <key> <head> <kind> <text> — record why this READY row is not
#   merging on this head. Two halves, both always rc 0:
#   - the NOTE, state/merge-conductor/ready-why/<mc_handoff_id key>, one line
#     `<epoch>\t<head>\t<kind>\t<text>`, rewritten EVERY tick the arm holds the
#     row, so its stamp says "the conductor still holds this, as of now";
#   - ONE log line per (PR, head, kind): `<key> READY not merged on <head8>:
#     <text>`, deduped against the note it replaces (same head and kind: no
#     line), so a hold that stands for a day is one line, not 288. NOT through
#     the attempts ledger: a `<kind> <key> <head>` attempt row moves
#     read_memo_fp for the head and would buy a re-read of the PR next tick.
#   A 5th argument `logged` writes the note only: the caller already logs that
#   hold's own deduped reason line (Lane D's merges-off line), so a second line
#   saying the same thing would be noise.
#   A ticket-hold or lead-held row is also handed to mc_hold_comment (BH-3456)
#   on every tick, as kind ticket-hold or lead; that contract dedupes, not this.
mc_ready_why() {
  local key="${1:-}" head="${2:-}" kind="${3:-hold}" text="${4:-}" dir f ph="" pk="" hk
  [ -n "$key" ] && [ -n "$head" ] || return 0
  text="${text//$'\t'/ }"; text="${text//$'\n'/ }"
  dir="$MC_STATE_DIR/ready-why"; f="$dir/$(mc_handoff_id "$key")"
  mkdir -p "$dir" 2>/dev/null
  [ -r "$f" ] && IFS=$'\t' read -r _ ph pk _ < "$f" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$(mc_now)" "$head" "$kind" "$text" > "$f.tmp.$$" 2>/dev/null \
    && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  case "$kind" in ticket-hold) hk=ticket-hold ;; lead-held) hk=lead ;; *) hk="" ;; esac
  [ -n "$hk" ] && command -v mc_hold_comment >/dev/null 2>&1 && _MC_HC_IN=1 mc_hold_comment "$key" "$head" "$hk" "$text"
  [ "${5:-}" = logged ] && return 0
  [ "$ph" = "$head" ] && [ "$pk" = "$kind" ] && return 0
  mc_log "$key READY not merged on ${head:0:8}: $text"
  return 0
}

# mc_ready_why_last <key> <head> -> the reason the conductor last recorded for
#   this READY row ON THIS HEAD: the ready-why note's text, else the last
#   MERGE_HELD / dependency-gate / main-red hold line naming the head. Prints
#   nothing when the conductor recorded no reason for this head.
mc_ready_why_last() {
  local key="${1:-}" head="${2:-}" f ts h k t line
  [ -n "$key" ] && [ -n "$head" ] || return 0
  f="$MC_STATE_DIR/ready-why/$(mc_handoff_id "$key")"
  if [ -r "$f" ] && IFS=$'\t' read -r ts h k t < "$f" && [ "$h" = "$head" ] && [ -n "$t" ]; then
    printf '%s' "$t"; return 0
  fi
  line=$(grep -F "$key " "$MC_LOG" 2>/dev/null | grep -F "${head:0:8}" \
         | grep -E "MERGE_HELD|READY and HELD by" | tail -1)
  [ -n "$line" ] && printf '%s' "$line"
  return 0
}

# mc_ready_why_kind <key> <head> -> the KIND of the ready-why note (field 3)
#   when that note is for this head, else nothing. mc_ready_rekick reads it to
#   tell a hold (main-red, dep-hold, ...) from a note that only says what this
#   tick did (prequeue-pending, queue-held, worker-locked, ...).
mc_ready_why_kind() {
  local key="${1:-}" head="${2:-}" f ts h k t
  [ -n "$key" ] && [ -n "$head" ] || return 0
  f="$MC_STATE_DIR/ready-why/$(mc_handoff_id "$key")"
  if [ -r "$f" ] && IFS=$'\t' read -r ts h k t < "$f" && [ "$h" = "$head" ] && [ -n "$k" ]; then
    printf '%s' "$k"
  fi
  return 0
}

# mc_dep_live <key> [url] -> the PR-dependency gate's answer for this PR, read
#   NOW (BH-4497), as one phrase for the STUCK page: still open / released /
#   could not read. Prints nothing when pdg_hold is not loaded or the key is not
#   <slug>#<n>. Under a conductor tick the issue and list reads share the READY
#   arm's per-tick memo (tick_memo_file); the PR body is one REST GET, paid only
#   on the tick a (PR, READY, head) crosses its TTL.
mc_dep_live() {
  local key="${1:-}" slug num out rc=0
  command -v pdg_hold >/dev/null 2>&1 || return 0
  case "$key" in *?'#'?*) ;; *) return 0 ;; esac
  slug=${key%#*}; num=${key##*#}
  case "$num" in *[!0-9]*) return 0 ;; esac
  out=$(PDG_SAY_PASS=1 pdg_hold "$slug" "$num" "${2:-https://github.com/$slug/pull/$num}" "") || rc=$?
  case "$rc" in
    0) printf 'the PR-dependency gate, read this tick: still open — it declares %s' "${out:-a dependency}" ;;
    1) printf 'the PR-dependency gate, read this tick: released — %s; the READY arm goes on to the merge checks this tick' "${out:-no open dependency}" ;;
    *) printf 'the PR-dependency gate, read this tick: could not read the dependency (held, fail closed)' ;;
  esac
  return 0
}

# mc_stuck_waiting_on <state> <reason> [key] [head] -> the WHAT IT IS WAITING ON
#   half of the stuck alert. An alert that says only "stuck in WAIT_CI for 4h"
#   tells the reader to go and look; this one names the thing that has not
#   happened. READY names the reason the conductor LOGGED for this head
#   (mc_ready_why_last), and says plainly when it logged none.
mc_stuck_waiting_on() {
  local act r dl rh rk
  case "${1:-}" in
    # A row whose reason says there are NO required checks must not be told it
    # is waiting on one (BH-988). mc_stuck_check returns before it reaches here
    # for these rows, so this arm is the backstop for the day that guard is
    # relaxed or a second caller appears — the sentence stays true either way.
    WAIT_CI)       if mc_identity_blocked "${2:-}"; then
                     printf 'a repo admin to permit this identity to push to the base branch (%s)' "$2"
                   else
                     printf 'a required check to report on this head (%s)' "${2:-checks}"
                   fi ;;
    WAIT_REVIEW)   printf 'the next tick to re-classify a re-approved head' ;;
    HEAD_MOVED)    printf 'a head-bound review of this head (deferred while CI is not green, or never spawned)' ;;
    NEEDS_REBASE)  printf 'a rebase of this head onto the project base' ;;
    REBASING)      printf 'a detached rebase job that has not written a result' ;;
    QUEUED)        printf 'the merge queue to land or eject this entry' ;;
    # A dependency-gate hold is never replayed from the note or the log line
    # (BH-4497: #4415's page said "#4242 QUEUED" 19 minutes after #4242 merged):
    # the gate is read again, and its answer as of this tick is what the page says.
    READY)         r=$(mc_ready_why_last "${3:-}" "${4:-}")
                   rk=""
                   [ -n "${3:-}" ] && [ -r "$MC_STATE_DIR/ready-why/$(mc_handoff_id "$3")" ] \
                     && IFS=$'\t' read -r _ rh rk _ < "$MC_STATE_DIR/ready-why/$(mc_handoff_id "$3")" \
                     && [ "$rh" = "${4:-}" ] || rk=""
                   if [ "$rk" = dep-hold ] || [[ $r == *"READY and HELD by the PR-dependency gate"* ]]; then
                     dl=$(mc_dep_live "${3:-}")
                     [ -z "$dl" ] || { printf 'the merge itself — %s' "$dl"; return 0; }
                   fi
                   if [ -n "$r" ]; then
                     printf 'the merge itself, which the conductor logged it is holding: %s' "$r"
                   else
                     printf 'the merge itself — the conductor logged no reason for not merging this head (see logs/merge-conductor.log)'
                   fi ;;
    STACKED_WAIT)  printf 'the parent PR to merge and this one to be retargeted' ;;
    NEEDS_HUMAN_VERDICT) printf 'a human lead verdict on this head (%s)' "${2:-no reason recorded}" ;;
    BLOCKED_HUMAN|RED_TWICE) printf 'bin/blocked-resolver.sh to drain the park (%s)' "${2:-no reason recorded}"
                             act=$(mc_park_human_action "${2:-}"); [ -n "$act" ] && printf ' — %s' "$act" ;;
    *)             printf 'nothing this lane knows how to name (%s)' "${2:-no reason recorded}" ;;
  esac
  return 0
}

# mc_stuck_check <key> <state> <since> <head> <url> <reason> [detail]
#   rc 0 = this (PR, state, head) has JUST crossed its TTL: the marker is
#          written, one alert is out, and the caller must now do the state's
#          deterministic re-kick (stuck_rekick in bin/merge-conductor.sh).
#   rc 1 = inside the TTL, no TTL at all, or already alerted for this triple.
#
#   THE DEDUPE KEY IS (PR, STATE, HEAD), not (PR, state) like the budget's
#   `alerted` field. A row that leaves a state and comes back on the SAME head
#   is the same stuck PR and must not page twice; a row on a NEW head is a PR
#   somebody moved, and it gets its own TTL and its own one alert. The marker is
#   a file rather than a row field because the row carries exactly one `alerted`
#   value and the budget already owns it.
# mc_resolver_saturated <key> — rc 0 when bin/blocked-resolver.sh says the lane
# that owns this PR is out of rungs. A whole-fleet scan writes $MC_RESOLVER_SAT;
# since BH-5913 each project has its own run and writes
# $MC_RESOLVER_SAT-<owner>_<repo>, keyed on the repo this key names.
mc_resolver_saturated() {
  local slug="${1%%#*}"
  [ -e "$MC_RESOLVER_SAT" ] && return 0
  [ -n "$slug" ] && [ -e "$MC_RESOLVER_SAT-${slug//\//_}" ]
}
mc_stuck_check() {
  local key="$1" st="$2" since="$3" head="$4" url="$5" why="${6:--}" detail="${7:-}"
  local ttl age mark waiting sat=""
  [ -n "$key" ] && [ -n "$st" ] || return 1
  # A contested park has its own clock (the hold's CONTESTED_TTL) and its own
  # release; a second pager on top of it would page about a wait that is by design.
  case "$why" in contested*) return 1 ;; esac
  ttl=$(mc_ttl "$st"); case "$ttl" in ''|-1|-*) return 1 ;; esac
  case "${since:-}" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(mc_now) - since )); [ "$age" -ge "$ttl" ] || return 1
  # AN IDENTITY-BLOCKED ROW HAS ALREADY HAD ITS ONE PAGE (BH-988). Before the
  # marker, not after: rc 1 here leaves the (PR, state, head) triple unspent, so
  # the day a repo admin permits the identity and the row then genuinely stalls
  # on a check, it can still page. Writing the marker and returning 1 would burn
  # that alert on a wait nothing here could have shortened. rc 1 also means the
  # caller does not run stuck_rekick, which for WAIT_CI is a CI kick that would
  # not move a row GitHub is refusing on identity.
  mc_identity_blocked "$why" && return 1
  mkdir -p "$MC_STUCK_DIR" 2>/dev/null
  mark="$MC_STUCK_DIR/$(mc_handoff_id "$key")_${st}_$(mc_handoff_id "${head:0:12}")"
  waiting=$(mc_stuck_waiting_on "$st" "$why" "$key" "$head")
  # THE PAGE POINTS AT THE LANE ALERT (BH-1122). A park whose page says "waiting
  # on bin/blocked-resolver.sh to drain the park" sends the reader to a lane that
  # is already out of rungs and has said so once, in its own SATURATED alert. So
  # while that marker stands, the page carries the pointer — the same fact the
  # re-kick below it logs, on the surface a person actually receives. Marker
  # gone: this is byte-for-byte the line it has always been.
  case "$st" in
    BLOCKED_HUMAN|RED_TWICE)
      mc_resolver_saturated "$key" && sat=" — bin/blocked-resolver.sh is SATURATED: see the [blocked-resolver] SATURATED line in logs/ALERTS.log. This park is already in that lane's candidate list and the lane has more parks than rungs, so what moves it is that lane's budget (BR_PER_TICK), not another hand-off" ;;
  esac
  # The alert text is built ONCE, above the marker check, because the held row
  # carries the same string the page would have: one place, so a held page and
  # an un-held one can never drift apart.
  local text="STUCK: $((age/60))m in one state (TTL $((ttl/60))m) on ${head:0:8} — waiting on $waiting${detail:+; $detail}$sat — $url"
  # THE PAUSED HOLD (BH-1201), before the marker on purpose: a held page leaves
  # the (PR, state, head) triple UNSPENT, so the row still owes exactly one page.
  # (i) The flush already owns this row — in every mode, including merge.
  mc_hold_cached "$key" "$st" "$head" STUCK && return 1
  # (ii) kill-switch / observe: hold it. No marker, no alert, and rc 1 so the
  # caller does not run stuck_rekick either — a pause that still kicked CI would
  # be a pause in name only.
  if mc_hold_mode; then
    mc_log "$key STUCK $((age/60))m in $(mc_state_display "$st" "$why") on ${head:0:8}, past its $((ttl/60))m TTL — HELD (mode=$MC_MODE), not paged: $url"
    mc_hold_page "$key" "$st" "$head" STUCK "$text" "$(basename "$mark")"
    return 1
  fi
  # THE ONE PAGE IS ALSO A ROW (BH-2358): a wiped MC_STUCK_DIR must not page this
  # triple twice. The row answers only when the marker is gone, and a hit warms
  # the marker back; an outage answers "no row", so the file decides as today.
  local line="stuck $key $st $head"
  [ -e "$mark" ] && return 1
  if mc_rows_twin_on && mc_attempt_has "$line"; then printf '%s\n' "$line" > "$mark"; return 1; fi
  # Row and ledger line, then the marker, then the send: marked before sent.
  if mc_rows_twin_on; then mc_attempt_put "$line"; printf '%s\n' "$line" > "$mark"; else : > "$mark"; fi
  # A CLAIMED PARK THAT HAS HAD ITS PAGE IS NOT STUCK-PAGED TOO (BH-3630): the
  # claimed-park gate in mc_budget_check owns its second page. The marker is
  # spent and rc 0 kept, so stuck_rekick still runs exactly as it does today.
  local claim
  if mc_park_state "$st" && claim=$(mc_resolver_claim_get "$key" "$head") \
     && case "$(cut -f5 <<<"$claim")" in ''|-|*[!0-9]*) false ;; *) true ;; esac; then
    mc_log "$key STUCK $((age/60))m in $(mc_state_display "$st" "$why") on ${head:0:8} — claimed by bin/blocked-resolver.sh, STUCK page folded into the claimed-park gate: $url"
    return 0
  fi
  mc_log "$key STUCK $((age/60))m in $(mc_state_display "$st" "$why") on ${head:0:8}, past its $((ttl/60))m TTL — waiting on $waiting${detail:+ ($detail)}$sat: $url"
  mc_alert "$key" "$(mc_state_display "$st" "$why")" "$text"
  return 0
}

# mc_stuck_gc — markers for PRs settled long ago, on the same two-week rule the
#   hand-off markers use.
mc_stuck_gc() {
  local f kind k st h
  [ -d "$MC_STUCK_DIR" ] || return 0
  # A marker carries its row's line when the twin wrote it (BH-2358); an empty
  # one (flag down, or log.sh's held-page flush) has no row to forget.
  if mc_rows_twin_on; then
    while IFS= read -r f; do
      read -r kind k st h < "$f" 2>/dev/null || continue
      [ "$kind" = stuck ] && [ -n "$h" ] && mc_attempt_clear stuck "$k" "$st $h"
    done < <(find "$MC_STUCK_DIR" -maxdepth 1 -type f -mtime +14 2>/dev/null)
  fi
  find "$MC_STUCK_DIR" -maxdepth 1 -type f -mtime +14 -delete 2>/dev/null
  return 0
}

# --- A hand-off to the resolver is STICKY (2026-09-14) -----------------------
# project-5 #759, 16:30:30Z: the tick parked it `BLOCKED_HUMAN
# reason=conflict-unresolvable` and logged the hand-off to
# bin/blocked-resolver.sh. TWENTY-TWO SECONDS later the next tick's DIRTY branch
# re-classified the same PR back to NEEDS_REBASE, and the resolver — which reads
# rows whose state IS BLOCKED_HUMAN — never saw it. For the next 45 minutes every
# tick logged `MERGE_TREE conflict on 382730a5 … GitHub is right, rebasing` and
# did nothing else: the rebase was capped, the resolver was blind, and the
# one-alert-per-PR-per-state rule had already fired. The PR parked in silence.
# project-5 #749 and project-7#438 are the same shape, and at wave scale (35
# decomposed children in one afternoon, siblings conflicting on shared files)
# this parks a growing share of APPROVED PRs with nothing saying so.
#
# So a hand-off parks the ROW, not just the tick that wrote it. While one is open
# the conductor takes NO action on that PR — no merge-tree test, no rebase, no
# re-review, no merge — and does not re-classify it. The park ends when something
# real changes: the head moves, the PR leaves the open list (merged or closed),
# or bin/blocked-resolver.sh writes its release marker. MC_STICKY_HANDOFF=0
# restores the re-classify-every-tick behaviour exactly.

# mc_handoff_owns <reason> -> rc 0 when this BLOCKED_HUMAN reason is a HAND-OFF,
#   i.e. one of the parks whose log line says "handed to bin/blocked-resolver.sh
#   (…)" and whose next move belongs to that lane and to nothing here.
#
#   It is a SUBSET of mc_resolver_owns on purpose. `iron-law` and `red-ci-twice`
#   are parks mc_classify re-derives every tick from the diff and from CI, and
#   both can legitimately clear underneath us (an adjudication marker, a rerun
#   going green); freezing them would freeze a fact that is supposed to move.
#   The four reasons no lane owns — migration-gated, verdict-contradiction,
#   provenance, tightened — are untouched here and page exactly as they do today.
mc_handoff_owns() {
  case "${1:-}" in
    conflict-unresolvable*|rebase-gate-red*|queue-ejected-twice*|merge-failed-twice*|\
    queue-enqueue-failed-twice*|no-verdict*|head-not-reapproved*) return 0 ;;
    # orphaned-child (2026-09-16) is sticky for the ordinary reason: the next
    # move is a fix round on the branch, and nothing this tick does can make it.
    # It is also the expensive one to re-derive — the verdict comes from a fetch
    # and two rev-lists — and it cannot clear underneath us without the head
    # moving, which ends the park by itself. NOT its sibling `parent-closed`:
    # that word means this box could not READ the branch, which is exactly the
    # kind of fact that clears on the next tick when the token or the checkout
    # comes back.
    orphaned-child*) return 0 ;;
    # stale-replan (BH-3932): the age ladder parked a PR nobody touched for
    # PO_STALE_REPLAN_D days, and the next move is a re-plan the resolver owns.
    # Nothing writes this reason until #3935.
    stale-replan*) return 0 ;;
    # prequeue-red (BH-4545): the gate already ran this head merged onto main,
    # so re-asking each tick only flips the row READY and back. It clears when
    # the resolver's fix round moves the head.
    prequeue-red*) return 0 ;;
  esac
  return 1
}

# The file name both lanes agree on: `<owner>_<repo>_<num>` out of the row key
# `<owner>/<repo>#<num>`, with everything a path dislikes replaced.
mc_handoff_id()       { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
mc_handoff_file()     { printf '%s/%s' "$MC_HANDOFF_DIR" "$(mc_handoff_id "$1")"; }
mc_handoff_rel_file() { printf '%s/%s' "$MC_HANDOFF_REL_DIR" "$(mc_handoff_id "$1")"; }

# mc_rows_twin_on — rc 0 when the pr-state-rows twin is up in this shell. Every
#   marker row BH-2358 added (handoff, handoff-rel, stuck, rbjob, rrjob) is
#   written and read only behind it, so flag down is today's path byte for byte.
mc_rows_twin_on() { type pr_rows_on >/dev/null 2>&1 && pr_rows_on; }

# mc_handoff_record <key> <head> <reason> <url> — mc_transition calls this the
#   moment a row ENTERS BLOCKED_HUMAN on a hand-off reason. Every call is a real
#   park (mc_transition only reaches it on a state CHANGE), so it always writes:
#   a new park on a head the resolver already released is a new hand-off, and the
#   stale release marker goes with it.
mc_handoff_record() {
  local key="$1" f
  [ -n "$key" ] || return 0
  mkdir -p "$MC_HANDOFF_DIR" "$MC_HANDOFF_REL_DIR" 2>/dev/null
  f=$(mc_handoff_file "$key")
  # The park is a row too (BH-2358), written before the marker: a new park on
  # a released head drops the stale release row, as the rm below drops its file.
  if [ -n "${2:-}" ] && [ "$2" != - ] && mc_rows_twin_on; then
    mc_attempt_clear handoff-rel "$key" "$2"
    mc_attempt_put "handoff $key $2"
  fi
  printf '%s\t%s\t%s\t%s\n' "$(mc_now)" "${2:--}" "${3:--}" "${4:--}" > "$f"
  rm -f "$(mc_handoff_rel_file "$key")" "$f.logged"
  return 0
}

# mc_handoff_release <key> [who] — THE RESOLVER'S RELEASE. bin/blocked-resolver.sh
#   calls it once it has taken the PR: a rung ran, so the park is that lane's now
#   and the conductor may classify this PR again on its next tick. It is a marker
#   the resolver WRITES rather than conductor state it deletes, so neither lane
#   reaches into the other's files.
mc_handoff_release() {
  local key="$1" head
  [ -n "$key" ] || return 0
  # The release is a row for the head that was parked (BH-2358). No parked head
  # anywhere, no row: a release of "-" would release nothing on any head.
  head=$(cut -f2 "$(mc_handoff_file "$key")" 2>/dev/null)
  [ -n "$head" ] && [ "$head" != - ] || head=$(mc_row_field "$key" 4)
  [ -n "$head" ] && [ "$head" != - ] && mc_rows_twin_on && mc_attempt_put "handoff-rel $key $head"
  mkdir -p "$MC_HANDOFF_REL_DIR" 2>/dev/null
  printf '%s\t%s\n' "$(mc_now)" "${2:-blocked-resolver}" > "$(mc_handoff_rel_file "$key")"
  return 0
}

# mc_handoff_sticky <key> <head> -> rc 0 means LEAVE THIS PR ALONE this tick.
#   Four questions, all cheap and all local: is the flag on, is the row parked on
#   a hand-off reason, is the PR still on the head that was parked, and has the
#   resolver released it. Any `no` and the caller classifies exactly as it does
#   today.
mc_handoff_sticky() {
  local key="$1" head="$2" row st why parked hf
  [ "${MC_STICKY_HANDOFF:-1}" != 0 ] || return 1
  [ -n "$key" ] && [ -n "$head" ] || return 1
  row=$(mc_row_get "$key"); [ -n "$row" ] || return 1
  st=$(cut -f2 <<<"$row"); [ "$st" = BLOCKED_HUMAN ] || return 1
  why=$(cut -f7 <<<"$row"); mc_handoff_owns "$why" || return 1
  # The head the hand-off named. The hand-off file is the record; a row parked
  # before this shipped has none, and then the row's own head field is the head
  # that was parked — the tick stops writing to it the moment the park is sticky.
  hf=$(mc_handoff_file "$key")
  parked=$(cut -f4 <<<"$row")
  [ -s "$hf" ] && parked=$(cut -f2 "$hf")
  # No marker: the `handoff` row for this head is the record (BH-2358). An
  # outage answers "no row", which leaves the row's head field to decide.
  if [ ! -s "$hf" ] && mc_rows_twin_on && mc_attempt_has "handoff $key $head"; then parked="$head"; fi
  [ -n "$parked" ] && [ "$parked" != "-" ] || return 1
  [ "$parked" = "$head" ] || return 1
  [ -e "$(mc_handoff_rel_file "$key")" ] && return 1
  mc_rows_twin_on && mc_attempt_has "handoff-rel $key $parked" && return 1
  return 0
}

# mc_handoff_sticky_log <key> <url> <head> — ONE line per hand-off, then quiet.
#   A park is a fact that does not change, and a line per tick about it is what
#   buried #759 under 25 identical MERGE_TREE lines in 45 minutes. Repeated at
#   most once per MC_STICKY_LOG_SECS (default an hour, 12 ticks) so a park that
#   outlives a day is still visible to somebody reading the log.
mc_handoff_sticky_log() {
  local key="$1" url="$2" head="$3" hf mark why at age act used=""
  hf=$(mc_handoff_file "$key"); mark="$hf.logged"
  if [ -e "$mark" ] && [ "$(( $(mc_now) - $(mc_mtime "$mark") ))" -lt "${MC_STICKY_LOG_SECS:-3600}" ]; then return 0; fi
  mkdir -p "$MC_HANDOFF_DIR" 2>/dev/null; : > "$mark"
  why=$(cut -f3 "$hf" 2>/dev/null); [ -n "$why" ] || why=$(mc_row_field "$key" 7)
  at=$(cut -f1 "$hf" 2>/dev/null); [ -n "$at" ] || at=$(mc_row_field "$key" 3)
  case "${at:-}" in ''|*[!0-9]*) at=$(mc_now) ;; esac
  age=$(( ( $(mc_now) - at ) / 60 ))
  act=$(mc_park_human_action "$why")
  # A person who re-applies the label and sees nothing move gets the reason here
  # rather than from the source: the label is once per (PR, head).
  [ -n "${MC_RELEASE_LABEL:-}" ] && [ -e "$(mc_handoff_human_file "$key" "$head")" ] \
    && used="; the $MC_RELEASE_LABEL label was already used on this head"
  mc_log "$key PARKED ${age}m in BLOCKED_AGENT ($why) on ${head:0:8} — bin/blocked-resolver.sh owns it; no merge-tree test, no rebase, no re-review, no merge here until the head moves, the PR closes, or the resolver releases it${act:+ — $act}${used}: $url"
  return 0
}

# --- A PERSON ends a park with a LABEL (BH-292) ------------------------------
# The park above ends on three things a lane can see: the head moved, the PR
# left the open list, the resolver released it. The fourth — "a person looked at
# this and says carry on" — had no way in at all, and the ticket asks for one.
#
# It is a LABEL rather than a comment phrase because a label is one field the
# tick already reads for every open PR (the `labels` column of the list read the
# Mergify queue witness rides on), so it costs no API call, and because it is
# unambiguous: no phrase matching, no comment scan per parked PR per tick.
#
# ONCE PER (PR, HEAD), recorded in a marker written BEFORE anything else. The
# label may sit on the PR for hours — observe mode never removes it, and a
# removal can fail — and a standing "always release" label would release every
# re-park on that head, which is the oscillation this whole file exists to stop.
# A crash between the marker and the release leaves "used, not released": the
# person re-applies on the next head, which is the safe direction.

# mc_labels_csv_has <labels-csv> <label> -> rc 0 when the label is one of the
#   names in the tick's labels field (`hotfix,queued`, `-` when there are none).
#   Whole name after trim + lowercase, so `conductor-released` is NOT a match.
#   NOT hotfix_labels_csv_has: that one is gated on the hotfix lane flag and
#   hard-wired to the hotfix label.
mc_labels_csv_has() {
  local csv="${1:-}" want="${2:-}" one parts=()
  [ -n "$want" ] || return 1
  [ -n "$csv" ] && [ "$csv" != "-" ] || return 1
  want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
  local IFS=','
  # `read -a`, never `for one in $csv`: an unquoted expansion would glob, and a
  # label may legitimately contain a `*`.
  read -r -a parts <<<"$csv"
  for one in ${parts[@]+"${parts[@]}"}; do
    one=$(printf '%s' "$one" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    [ "$one" = "$want" ] && return 0
  done
  return 1
}

# mc_label_remove <pr-url> <label> — take a label back off a PR. rc is gh's own
#   and is never swallowed: a label left on the PR would release the NEXT park
#   on the next head, so the caller has to be able to say so.
mc_label_remove() {
  local url="${1:-}" label="${2:-}"
  [ -n "$url" ] && [ -n "$label" ] || return 2
  gh api -X DELETE "repos/$(mc_slug_of_url "$url")/issues/$(mc_num_of_url "$url")/labels/$label" >/dev/null 2>&1
}

# The once-per-(PR, head) marker. Same key shape as the stuck detector's.
mc_handoff_human_file() { printf '%s/%s_%s' "$MC_HANDOFF_HUMAN_DIR" "$(mc_handoff_id "$1")" "$(mc_handoff_id "${2:0:12}")"; }

# mc_handoff_human_release <key> <head> <labels-csv> <url> -> rc 0 when THIS tick
#   ended the park because the release label is on the PR and this head has not
#   used it yet. Everything here is local; the label on GitHub is the caller's to
#   remove, because only the caller knows whether the lane may write at all.
#
#   The attempts this head has already spent are FORGOTTEN, or the release moves
#   nothing: a released conflict lands in NEEDS_REBASE, where mc_attempted
#   refuses a second rebase of the same head, and the person who applied the
#   label watches it sit there.
mc_handoff_human_release() {
  local key="${1:-}" head="${2:-}" csv="${3:-}" url="${4:-}" mark
  [ -n "${MC_RELEASE_LABEL:-}" ] || return 1
  [ -n "$key" ] && [ -n "$head" ] || return 1
  mc_labels_csv_has "$csv" "$MC_RELEASE_LABEL" || return 1
  mark=$(mc_handoff_human_file "$key" "$head")
  [ -e "$mark" ] && return 1
  mkdir -p "$MC_HANDOFF_HUMAN_DIR" 2>/dev/null
  : > "$mark" || return 1
  mc_handoff_release "$key" "human/$MC_RELEASE_LABEL"
  mc_attempt_clear rebase "$key" "$head"
  mc_attempt_clear mergetree "$key" "$head"
  mc_attempt_clear rebasedone "$key" "$head"
  mc_attempt_clear rebasefailed "$key" "$head"
  # ...and the NO_REBASE said-once records (BH-764), for the same reason
  # stuck_rekick clears them: the point of forgetting the attempt is that the
  # next cycle may act again, and an exit that stayed deduped would act in
  # silence — which is the state the release label was applied to end.
  mc_attempt_clear rebasenoop-consumed "$key" "$head"
  mc_attempt_clear rebasenoop-attempted "$key" "$head"
  # ...and the finished-job line (BH-2358), or the fresh rebase is refused.
  mc_attempt_clear rbjob "$key" "$head done"
  [ -n "$url" ] && rm -f "$(mc_rb_file "$(mc_slug_of_url "$url")" "$(mc_num_of_url "$url")" "$head")" 2>/dev/null
  return 0
}


# mc_handoff_gc — hand-off and release markers for PRs long since settled. Two
#   weeks is far past every rung's own cap, so anything this old is finished.
mc_handoff_gc() {
  local f k h
  # The rows of a hand-off this old go with its marker (BH-2358). The key and
  # head come from the marker itself: field 4 is the PR url, field 2 the head.
  if [ -d "$MC_HANDOFF_DIR" ] && mc_rows_twin_on; then
    while IFS= read -r f; do
      h=$(cut -f2 "$f" 2>/dev/null); k=$(cut -f4 "$f" 2>/dev/null)
      case "$k" in https://github.com/*/pull/[0-9]*) k="$(mc_slug_of_url "$k")#$(mc_num_of_url "$k")" ;; *) continue ;; esac
      [ -n "$h" ] && [ "$h" != - ] || continue
      mc_attempt_clear handoff "$k" "$h"
      mc_attempt_clear handoff-rel "$k" "$h"
    done < <(find "$MC_HANDOFF_DIR" -maxdepth 1 -type f ! -name '*.logged' -mtime +14 2>/dev/null)
  fi
  for f in "$MC_HANDOFF_DIR" "$MC_HANDOFF_REL_DIR" "$MC_HANDOFF_HUMAN_DIR"; do
    [ -d "$f" ] || continue
    find "$f" -maxdepth 1 -type f -mtime +14 -delete 2>/dev/null
  done
  return 0
}


# --- A withheld lead-verdict (BH-3777) ---------------------------------------
# #3753 and #3758 (2026-09-30) touched a protected path, so BH-3683 withheld the
# lead-verdict status; the enqueue labelled them and asked Mergify anyway, and
# the rows read QUEUED for 17 hours while Mergify waited on queue_conditions for
# a status only a person could publish. The conductor now asks la_decide BEFORE
# it classifies a READY Mergify row, and a withheld verdict is its own state.
#
# mc_nhv_reason <owner/repo> <num> <head> <la_reason> -> the row's reason: what
#   withheld it and the exact command that publishes it, on one line. It renders
#   only under lead_authority_mode=human: under lane (the default, BH-4145)
#   la_decide never answers rc 1 for a protected path, so no row is classified
#   NEEDS_HUMAN_VERDICT for one.
mc_nhv_reason() {
  printf 'lead-verdict withheld on %s: %s — a human verdict publishes it: bin/lead-verdict.sh post %s %s %s MERGE --source human' \
    "${3:0:12}" "${4:-no reason given}" "$1" "$2" "$3" | tr '\t\n' '  '
}

# mc_la_decide <owner/repo> <num> <head> -> la_decide's rc and LA_REASON for
#   source=conductor, asked ONCE per (PR, head) per worker (BH-3806). Each
#   la_decide costs two or more REST reads, and one READY row asked it in the
#   unqueue check, the gate and the enqueue. Every rc is kept, 2 included: an
#   undecidable answer is the BH-2199 hold for the rest of this row's tick and
#   is asked again next tick. pr_worker clears MC_LA_MEMO_KEY on entry and each
#   worker is its own subshell, so the memo never outlives one row of one tick;
#   a process that never sets the key (poll-commands, rule-adopt,
#   batch-resolve) asks fresh on its first call. No la_decide loaded = rc 0
#   with LA_REASON empty, the "no gate" every caller already had.
mc_la_decide() {
  local key="$1#$2@$3" rc=0
  if [ -n "${MC_LA_MEMO_KEY:-}" ] && [ "$MC_LA_MEMO_KEY" = "$key" ]; then
    LA_REASON="${MC_LA_MEMO_REASON:-}"
    return "${MC_LA_MEMO_RC:-2}"
  fi
  command -v la_decide >/dev/null 2>&1 || { LA_REASON=""; return 0; }
  la_decide "$1" "$2" "$3" conductor || rc=$?
  MC_LA_MEMO_KEY="$key"; MC_LA_MEMO_RC="$rc"; MC_LA_MEMO_REASON="$LA_REASON"
  return "$rc"
}

# mc_nhv_gate <owner/repo> <num> <head> <actions> -> sets MC_NEEDS_HV.
#   la_decide rc 1 = the reason (mc_nhv_reason), and with actions=1 the warn
#   beat la_human_needed sends (once per (PR, head) per day). rc 0 and rc 2
#   leave it empty: rc 2 is the BH-2199 hold mc_enqueue_mergify already makes,
#   and is never reported as a withheld verdict. No la_decide loaded = no gate.
mc_nhv_gate() {
  local slug="$1" num="$2" head="$3" actions="${4:-0}" rc=0
  MC_NEEDS_HV=""
  command -v la_decide >/dev/null 2>&1 || return 0
  mc_la_decide "$slug" "$num" "$head" || rc=$?
  [ "$rc" = 1 ] || return 0
  MC_NEEDS_HV=$(mc_nhv_reason "$slug" "$num" "$head" "$LA_REASON")
  if [ "$actions" = 1 ] && command -v la_human_needed >/dev/null 2>&1; then
    la_human_needed "$slug" "$num" "$head" "$LA_REASON" merge-conductor || true
  fi
  return 0
}

# mc_vs_success_on <owner/repo> <head> -> rc 0 when the head's combined status
#   carries the lead-verdict context in state success, 1 when it does not (no
#   such status, or a failure/pending one), 2 when the read did not answer
#   (gh_rest non-zero: any non-2xx; or a body with no statuses array). 2 is
#   never read as "absent" (BH-3806).
mc_vs_success_on() {
  local f rc=0 ctx n
  command -v gh_rest >/dev/null 2>&1 || return 2
  ctx=$(command -v vs_context >/dev/null 2>&1 && vs_context || echo "${LEAD_VERDICT_CONTEXT:-lead-verdict}")
  f=$(mktemp "${TMPDIR:-/tmp}/mc-vs.XXXXXX") || return 2
  gh_rest GET "repos/$1/commits/$2/status" > "$f" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] || { rm -f "$f"; return 2; }
  n=$(jq -r --arg c "$ctx" 'if (.statuses | type) == "array" then [.statuses[] | select(.context == $c and .state == "success")] | length else "unparsed" end' "$f" 2>/dev/null) || n=""
  rm -f "$f"
  case "$n" in ''|*[!0-9]*) return 2 ;; 0) return 1 ;; *) return 0 ;; esac
}

# mc_vs_state_on <owner/repo> <head> [context] -> prints the head's state for
#   <context> (default: the lead-verdict context in force, vs_context):
#   success|failure|error|pending, or `absent` when no status carries the
#   context; rc 0. rc 2 (nothing printed) when the read did not answer, the same
#   read and context as mc_vs_success_on, which cannot tell absent from a
#   failure (BH-4596 needs that difference: absent is republished, failure never).
mc_vs_state_on() {
  local f rc=0 ctx s
  command -v gh_rest >/dev/null 2>&1 || return 2
  ctx="${3:-$(command -v vs_context >/dev/null 2>&1 && vs_context || echo "${LEAD_VERDICT_CONTEXT:-lead-verdict}")}"
  f=$(mktemp "${TMPDIR:-/tmp}/mc-vs.XXXXXX") || return 2
  gh_rest GET "repos/$1/commits/$2/status" > "$f" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] || { rm -f "$f"; return 2; }
  s=$(jq -r --arg c "$ctx" 'if (.statuses | type) == "array" then ([.statuses[] | select(.context == $c) | .state][0] // "absent") else "unparsed" end' "$f" 2>/dev/null) || s=""
  rm -f "$f"
  case "$s" in success|failure|error|pending|absent) printf '%s' "$s"; return 0 ;; esac
  return 2
}

# mc_nhv_unqueue <owner/repo> <key> <url> <num> <head> <labels-csv> <merges>
#   A PR the enqueue labelled BEFORE BH-3777/BH-3806 (#3798, #3799): our label
#   on, the row QUEUED, no lead-verdict success on the head and la_decide rc 1.
#   MC_INQUEUE wins before the CLEAN arm, so the gate never saw it and Mergify
#   waits on queue_conditions for a person. This takes OUR label off, once per
#   (PR, head), and rc 0 tells the caller to drop MC_INQUEUE for the tick so the
#   gate classifies the row NEEDS_HUMAN_VERDICT. Cheapest guard first; every
#   unreadable answer leaves the row alone. The mark is written only after the
#   DELETE landed (or answered 404: the label is already gone), so a failed
#   DELETE is retried next tick and a hand re-label on the same head is left be.
#   merges != 1: one WOULD line, nothing written.
mc_nhv_unqueue() {
  local slug="$1" key="$2" url="$3" num="$4" head="$5" labels="${6:-}" merges="${7:-0}" err lrc=0
  grep -qE "(^|,)$MC_MERGIFY_LABEL(,|\$)" <<<"$labels" || return 1
  mc_attempt_has "nhvunqueue $key $head" 2>/dev/null && return 1
  if command -v la_scope >/dev/null 2>&1; then
    la_scope "$slug" || lrc=$?
    [ "$lrc" = 1 ] && return 1
  fi
  mc_vs_success_on "$slug" "$head"; [ "$?" = 1 ] || return 1
  mc_la_decide "$slug" "$num" "$head"; [ "$?" = 1 ] || return 1
  if [ "$merges" != 1 ]; then
    mc_log "$key WOULD unqueue ${head:0:8}: $MC_MERGIFY_LABEL is on and the lead-verdict is withheld (${LA_REASON}) — merges are off this tick"
    return 1
  fi
  if ! err=$(gh api -X DELETE "repos/$slug/issues/$num/labels/$MC_MERGIFY_LABEL" 2>&1 >/dev/null); then
    case "$err" in
      *404*|*"Not Found"*|*"Label does not exist"*) : ;;
      *) mc_log "$key unqueue of ${head:0:8} FAILED: $MC_MERGIFY_LABEL could not be removed ($(head -1 <<<"$err")) — tried again next tick: $url"
         return 1 ;;
    esac
  fi
  mc_attempt_put "nhvunqueue $key $head"
  mc_log "NHV_UNQUEUED $key $head — label off, lead-verdict withheld (${LA_REASON})"
  return 0
}

# mc_nhv_parent_note <owner/repo> <parent-url> -> `parent #N needs a human
#   verdict (<its reason>)` when the parent's row is NEEDS_HUMAN_VERDICT, else
#   nothing — so a stacked child's STACKED_WAIT says what it is really waiting on.
mc_nhv_parent_note() {
  local n row
  n=$(mc_num_of_url "${2:-}") || return 0
  [ -n "$n" ] || return 0
  row=$(mc_row_get "$1#$n")
  [ "$(cut -f2 <<<"$row")" = NEEDS_HUMAN_VERDICT ] || return 0
  printf 'parent #%s needs a human verdict (%s)' "$n" "$(cut -f7 <<<"$row")"
}

# --- The classifier ----------------------------------------------------------
# mc_classify <pstate> <mstate> <mergeable> <head> <reviewed> <verdict> <prov>
#             <ci> <reds> <tightened> <scan> <prearm> <prev-state> <headbound>
#   <headbound> is the raw word[@sha] the gate wrote; see mc_hb_blocks below.
#   Pure: prints "<STATE>\t<reason>". Inputs are words gh and the readers above
#   already produce; nothing here calls anything. Order matters and is the
#   order docs/MERGE-CONDUCTOR.md section 3 states.
#   Four further inputs arrive as NAMED variables, because none of them is a
#   word gh's PR fields produce: MC_INQUEUE (1 = GitHub says the PR is in the
#   native merge queue), MC_STACK (`wait` / `parent-closed` = this PR is based
#   on another PR's branch, with MC_STACK_BASE naming it), MC_PROV_CLEARED
#   (1 = a claude head-bound re-review APPROVED this exact head, so the build's
#   non-primary provenance no longer parks it) and MC_IDENTITY_BLOCKED
#   (1 = BLOCKED is about the token's push permission, not about a check, with
#   MC_IDENTITY_WORD naming the identity — BH-800). See their clauses below.
#   MC_NEEDS_HV (BH-3777) is a fifth: non-empty = BH-3683 withholds the
#   lead-verdict status on this head (la_decide rc 1), and it IS the reason
#   string, command included (mc_nhv_gate sets it, the conductor resets it).
mc_classify() {
  local ps="$1" ms="$2" mg="$3" head="$4" rev="$5" v="$6" prov="$7" ci="$8" reds="$9"
  local tight="${10}" scan="${11}" prearm="${12}" prev="${13}" hb="${14:--}"
  case "$ps" in
    MERGED) printf 'MERGED\tgithub says merged'; return ;;
    CLOSED) printf 'CLOSED\tclosed without merging'; return ;;
  esac
  # ABANDONED is terminal (see MC_STATES). The resolver moved this row here
  # after its ladder ran out and closed the PR; if the close did not land, a
  # later tick must not walk it back into WAIT_CI and start the whole cycle
  # again. Pinning it here is what makes "outcome record" true.
  [ "$prev" = ABANDONED ] && { printf 'ABANDONED\tterminal: the resolver ladder was exhausted'; return; }
  # STACKED ON A FEATURE BRANCH (2026-09-14). A child build cut from its
  # parent's PR branch opens its PR with --base <parent-branch>, so this PR's
  # base is NOT the project's. Merging it would land the child INTO the parent,
  # which is the one merge this lane must never make — and every state below
  # would be wrong about it too (mc_rebase merges origin/main into the branch,
  # which for a stacked child would drag main's whole diff into a PR that is
  # supposed to show one ticket). So it parks here, ahead of everything, and
  # flows normally the moment its base becomes the project's: GitHub retargets
  # it by itself when the parent merges and its branch is deleted, and
  # bin/merge-conductor.sh retargets it explicitly when GitHub does not.
  #
  # Passed as the NAMED variable MC_STACK for the same reason MC_INQUEUE is:
  # it is not a word gh's PR fields produce, it is a COMPARISON between
  # baseRefName and the project's base, which only the caller can make.
  # MC_STACK_BASE is the base branch, for the reason string.
  case "${MC_STACK:-}" in
    parent-closed) printf 'BLOCKED_HUMAN\tparent-closed: the PR this one is stacked on (%s) closed without merging' "${MC_STACK_BASE:-?}"; return ;;
    # THE SAME PARK, WITH AN OWNER (2026-09-16). `parent-closed` above is the
    # answer when the tick could not read the branch; this one is the answer
    # when it COULD and the branch cannot simply be retargeted (mc_orphan_clean
    # rc 1) — it still carries the closed parent's commits, or it conflicts with
    # the base. That is a branch an agent can move, so the reason is one
    # mc_resolver_owns recognises and bin/blocked-resolver.sh drains it on its
    # ladder. Same state, same budget; the difference is that something comes
    # for it. project-5 #1586/#1585/#1587 sat on `parent-closed` because nothing
    # did.
    parent-closed-orphan) printf 'BLOCKED_HUMAN\torphaned-child: the PR this one is stacked on (%s) closed without merging, and this branch cannot be retargeted as it stands' "${MC_STACK_BASE:-?}"; return ;;
    wait)          printf 'STACKED_WAIT\tbased on %s, not the project base — waiting for the parent to merge and retarget' "${MC_STACK_BASE:-?}"; return ;;
  esac
  [ "$tight" = 1 ] && { printf 'BLOCKED_HUMAN\ttightened'; return; }
  # A CONTRADICTION ABOUT AN OLDER HEAD IS NOT ONE ABOUT THIS HEAD (BH-4585,
  # #4620): nobody has read the head that is here now, so the row is
  # head-moved like any other drift and buys the head-bound re-review below;
  # mc_verdict lets that re-review's verdict stand on the next tick. Only a
  # contradiction on the CURRENT head (or an unknown one) parks, and it says
  # both verdicts (MC_CONTRA, the caller's mc_contradiction_words).
  if [ "$v" = CONTRADICTION ]; then
    if [ -n "$rev" ] && [ "$rev" != "-" ] && [ -n "$head" ] && [ "$rev" != "$head" ]; then
      v="-"
    else
      printf 'BLOCKED_HUMAN\tverdict-contradiction%s' "${MC_CONTRA:+: $MC_CONTRA on ${head:0:8}}"; return
    fi
  fi
  [ "$v" = BLOCK ] && { printf 'BLOCKED_HUMAN\treview-block'; return; }
  # A PROVENANCE HOLD IS CLEARED BY A CLAUDE READ OF THIS HEAD (2026-09-14,
  # project-5 #864/#865/#866/#867). `provenance` means a NON-primary runner
  # authored the build's own APPROVE, so nothing claude has read this code —
  # and the fix for that is exactly the detached head-bound re-review this lane
  # already buys. bin/merge-conductor.sh buys it, and when it comes back
  # APPROVE on the CURRENT head it records `provcleared <key> <head>` and hands
  # the answer in as MC_PROV_CLEARED. A NAMED variable for the same reason
  # MC_INQUEUE and MC_STACK are: it is not a word gh's PR fields produce, it is
  # a fact about (this PR, this head) only the caller can look up.
  #
  # It clears the hold for THAT HEAD ONLY, and it does not rewrite the ledger's
  # provenance — the build's own review really was served by the runner the row
  # names, and #864's history must keep saying so. What changed is that a head
  # a claude reviewer approved is no longer parked for who reviewed it BEFORE.
  # mc_prov_held, not a literal word list: `claude-via-openrouter` is a Claude
  # model that answered on the tier-3 lane, and parking a PR for that is parking
  # it for the read it asked for (2026-09-16).
  #
  # ...AND A DIRTY HEAD IS NOT PARKED FOR PROVENANCE AT ALL (BH-491,
  # 2026-09-16). A conflicted PR on a non-primary provenance sat in
  # BLOCKED_HUMAN forever: GitHub runs no workflow on a head that cannot
  # merge, so no claude read could ever be bought and no event was left to
  # clear the hold. It falls through to the DIRTY arm below instead, which
  # rebases and says `dirty-under-provenance`. The guard lives HERE, on the
  # provenance arm, rather than as a copy of the DIRTY test hoisted above it:
  # hoisting shadowed the head-drift branch, so every conflicted PR whose head
  # had moved answered NEEDS_REBASE instead of HEAD_MOVED and stopped buying
  # the head-bound re-review that binds an approval to the sha it read.
  if mc_prov_held "$prov" && [ "${MC_PROV_CLEARED:-0}" != 1 ] \
     && [ "$ms" != DIRTY ] && [ "$mg" != CONFLICTING ]; then
    printf 'BLOCKED_HUMAN\tprovenance'; return
  fi
  if [ -n "$rev" ] && [ "$rev" != "-" ] && [ -n "$head" ] && [ "$rev" != "$head" ]; then
    # WHY THE HEAD-BOUND OUTCOME IS READ HERE AND NOWHERE ELSE. It is only ever
    # anything but `n/a` when the head moved, and `blocked` can only ever be
    # seen alongside drift — the gate leaves reviewed-sha on the old head
    # precisely because it did not re-approve the new one. So the clause lives
    # inside the drift branch: outside it, it would be unreachable.
    #
    # `blocked@<this head>` means a reviewer READ the code that is sitting here
    # right now and said no. Sending the conductor off to buy another re-review
    # spends a second Fable call to be told the same word, and then parks anyway
    # — which is what project-5 TK-419/TK-290 did on 2026-09-12 (the sweep parked
    # forever; nothing said why).
    #
    # `blocked@<some OTHER head>` is the opposite answer: somebody pushed a fix
    # on top of the refused head, nobody has read THAT, and buying the re-review
    # is exactly right. Same for `no-verdict`, a bare legacy `blocked` whose head
    # is unknowable, and `-`: keep today's HEAD_MOVED.
    #
    # AND SINCE 2026-09-16 `blocked@<this head>` DOES NOT PARK ON SIGHT EITHER.
    # It is the BUILD's own gate speaking, on whatever runner that build's
    # ladder reached, and the answer to it is the same detached head-bound
    # Claude read the line below already buys — one read, minutes, versus the
    # full agent fix round a `head-not-reapproved` park costs the resolver (61
    # of those on project-5 on 2026-09-16). So the row stays HEAD_MOVED, the
    # conductor buys its OWN read, and the park waits for THAT verdict:
    # MC_HB_REFUSED=1 is the caller handing back "my own re-review of this exact
    # head came back BLOCK" (mc_hb_refused), which is the only thing that parks
    # it now. See the block above mc_hb_refused for why the fact has to be
    # recorded rather than re-derived.
    #
    # THREE WAYS BACK TO TODAY'S IMMEDIATE PARK, and each is load-bearing:
    #   MC_REREVIEW_ON_MOVE=0  the operator's kill flag, byte-for-byte as before.
    #   MC_HB_REFUSED=1        our own read already said no about THIS head.
    #   DIRTY / CONFLICTING    a conflicted head can never be re-reviewed at all
    #                          — GitHub runs no workflow on it, so the CI-green
    #                          debounce in headbound_review defers the read for
    #                          ever (BH-491) — and a PR that can neither be read
    #                          nor parked is the silent strand this whole file
    #                          exists to prevent.
    if mc_hb_blocks "$hb" "$head"; then
      if [ "${MC_REREVIEW_ON_MOVE:-1}" = 0 ] || [ "${MC_HB_REFUSED:-0}" = 1 ] || \
         [ "$ms" = DIRTY ] || [ "$mg" = CONFLICTING ]; then
        printf 'BLOCKED_HUMAN\thead-not-reapproved'; return
      fi
    fi
    # A PARK ON THIS EXACT HEAD IS NOT UNDONE BY THE DRIFT THAT CAUSED IT
    # (BH-1019). The `no-verdict` park below happens BECAUSE the head moved and
    # nothing could read it — so `rev != head` is still true the instant it
    # lands, and this branch handed the row straight back to HEAD_MOVED, which
    # armed the spawn again. cromford#818: eight spawns of one PR, five of
    # them paid, no commit in between any of them.
    #
    # MC_HB_PARKED is the caller handing back `hbpark <key> <this head>`
    # (mc_hb_park) — a NAMED variable for the same reason MC_HB_REFUSED is: it
    # is a fact about (this PR, this head) that only the caller can look up.
    # Guarded on the PREVIOUS state so this says exactly what it means: it is
    # the BLOCKED_HUMAN -> HEAD_MOVED reconciliation that must not re-arm, and
    # nothing else. A PUSH lands a head with no record and buys its read,
    # unchanged; so does an operator who clears the row.
    if [ "${MC_HB_PARKED:-0}" = 1 ] && [ "$prev" = BLOCKED_HUMAN ]; then
      printf 'BLOCKED_HUMAN\tno-verdict: parked on %s and nothing has been pushed since' "${head:0:8}"; return
    fi
    printf 'HEAD_MOVED\treviewed %s head %s' "${rev:0:8}" "${head:0:8}"; return
  fi
  # In GitHub's native merge queue. Passed as the NAMED variable MC_INQUEUE
  # rather than a positional word, because `mergeStateStatus` has no QUEUED
  # value to read it from — the enum is DIRTY UNKNOWN BLOCKED BEHIND UNSTABLE
  # HAS_HOOKS CLEAN — so the only witness is isInMergeQueue, which the caller
  # reads. It is tested BEFORE the merge-state case below and therefore guards
  # BOTH the CLEAN -> READY line and the BLOCKED -> WAIT_CI line: which of the
  # two GitHub reports for a queued PR is not documented anywhere we could
  # verify, and re-enqueueing a PR that is already in the queue is the
  # forever-loop this state exists to prevent.
  [ "${MC_INQUEUE:-0}" = 1 ] && { printf 'QUEUED\tin the merge queue (mergeState %s)' "${ms:--}"; return; }
  # A CONFLICTED HEAD REBASES BEFORE IT WAITS FOR ANYTHING ELSE (2026-09-14,
  # project-5 #799/#826/#838/#863). This test used to sit BELOW the CI case,
  # and that is the bug: GitHub runs no `pull_request` workflow on a PR it
  # cannot merge, so `ci=none` is the NORMAL state of a DIRTY PR, not an
  # exception. Every conflicted PR therefore answered `WAIT_CI checks none` and
  # waited for a run that GitHub was never going to start — #799 sat there for
  # four hours, #838/#826/#863 the same, and not one of them ever reached
  # mc_rebase, which is the only thing that could have moved them.
  #
  # The rebase is what produces a head CI will build, so CI has nothing to say
  # about a head that conflicts. It runs ahead of the no-verdict branch too:
  # a DIRTY head with no verdict used to answer `WAIT_REVIEW`, and nothing in
  # the harness reviews a WAIT_REVIEW row — rebase first, and the fresh
  # head-bound review is bought on the head the rebase pushes, which is the
  # head that can actually merge.
  #
  # It sits BELOW the drift branch, not above it: a head nobody has reviewed is
  # HEAD_MOVED whether or not it conflicts, because the re-review is what binds
  # an approval to the sha that carries it, and a rebase only moves the head
  # again. BH-491 hoisted this test to the top of the classifier to beat the
  # provenance hold and took the drift branch with it (2026-09-16).
  #
  # The red-twice park is unchanged for every PR that is not DIRTY. A DIRTY PR
  # skips it on purpose: the red it collected is a red about a tree nobody can
  # merge, and the pushed head gets its own CI and its own strikes.
  if [ "$ms" = DIRTY ] || [ "$mg" = CONFLICTING ]; then
    # BH-491: a DIRTY head under a non-primary provenance names the hold the
    # guard above let it through, so the operator reads WHY it is rebasing
    # rather than parked.
    if mc_prov_held "$prov" && [ "${MC_PROV_CLEARED:-0}" != 1 ]; then
      printf 'NEEDS_REBASE\tdirty-under-provenance'
    else
      printf 'NEEDS_REBASE\tmergeState %s' "$ms"
    fi
    return
  fi
  # NO VERDICT BOUND TO THIS HEAD (2026-09-14, project-5 #586/#611). WAIT_REVIEW
  # here was a dead end: nothing in the harness reviews a WAIT_REVIEW row, so a
  # PR whose reviewed sha is absent, or equals the head while the verdict is
  # empty (an old BLOCK cleared by a migration apply, a resolver hand-off that
  # set no verdict), sat there forever. It is the SAME fact the drift branch
  # above acts on — nobody has adjudicated the code sitting here — so it gets
  # the same answer: the detached head-bound review (mc_rereview_spawn), still
  # behind the tick's CI-green debounce and still one review per (PR, head).
  [ "$v" != APPROVE ] && { printf 'HEAD_MOVED\tno verdict bound to head %s — fresh detached review' "${head:0:8}"; return; }
  case "$ci" in
    # A HEAD WHOSE LATEST RUNS WERE KILLED IS NOT A HEAD WITH NOTHING ON IT
    # (BH-636). `checks none` sends a reader to "CI has not started"; what has
    # actually happened is that every run there was cancelled or timed out, and
    # the tick has bought (or spent) its one rerun. MC_CI_FLAKE is a NAMED
    # variable for the reason MC_RED_RUNG and MC_INQUEUE are: it is not a word
    # gh's fields produce, it is a second read only the caller can make.
    pending|none)
      if [ "$ci" = none ] && [ "${MC_CI_FLAKE:-0}" = 1 ]; then
        # BH-3775: the check dies at its timeout-minutes on this repo, so no
        # rerun was bought and the repo page owns it (bin/lib/mc-ci-timeout-budget.sh).
        [ "${MC_CI_TIMEOUT_FIRING:-0}" = 1 ] && { printf 'WAIT_CI\tchecks timeout budget — "%s" dies at its %s-min limit (CI_TIMEOUT_BUDGET; no rerun)' "${MC_CI_TIMEOUT_CHECK:-}" "${MC_CI_TIMEOUT_T:-}"; return; }
        printf 'WAIT_CI\tchecks flake (cancelled/timed_out latest run — not a verdict; rung %s)' "${MC_FLAKE_RUNG:-0}"; return; fi
      printf 'WAIT_CI\tchecks %s' "$ci"; return ;;
    # THE RED LADDER (2026-09-15, project-5 #1045). `checks red once` used to be
    # the whole answer for a red head and it had no next transition — the
    # red-ci-twice park counted reds on DIFFERENT heads (removed by BH-1671), so a
    # PR that went red and was never pushed to again sat here for ever. MC_RED_RUNG is where this
    # (PR, head) is on the ladder, and it is a NAMED variable for the reason
    # MC_INQUEUE and MC_STACK are: it is not a word gh's fields produce, it is a
    # fact about (this PR, this head) that only the caller can look up.
    #   0  nothing tried yet            -> WAIT_CI, and the tick dispatches the rerun
    #   1  the rerun is in flight       -> WAIT_CI, and the reason says so
    #   2  red again on the SAME head   -> RED_TWICE, which the resolver owns
    #
    # RED IS COUNTED PER HEAD, NEVER ACROSS HEADS (BH-1671). `reds` (strikes on
    # DIFFERENT heads of this PR) used to park `BLOCKED_HUMAN red-ci-twice` here
    # at 2, ahead of the ladder. So a head that went red ONCE after an earlier
    # head had gone red was parked before it got its rerun, and the resolver's
    # rebuild rung then closed it as superseded on a count that spanned code no
    # longer on the branch. The strike ledger is still written by the caller.
    # It no longer decides anything: only this head's own ladder parks it.
    red)
      if [ "${MC_RED_RUNG:-0}" -ge 2 ] 2>/dev/null; then
        printf 'RED_TWICE\tred-twice: still red on %s after its failed jobs were re-run once' "${head:0:8}"; return; fi
      if [ "${MC_RED_RUNG:-0}" = 1 ]; then printf 'WAIT_CI\tchecks red once — failed jobs re-run, waiting on the rerun'; else printf 'WAIT_CI\tchecks red once'; fi
      return ;;
  esac
  [ "${scan:-0}" -gt 0 ] 2>/dev/null && { printf 'BLOCKED_HUMAN\tiron-law (%s hit(s))' "$scan"; return; }
  [ "$prearm" = 1 ] && { printf 'BLOCKED_HUMAN\tstatic-guards-red'; return; }
  case "$ms" in
    # A clean, approved row whose lead-verdict status is withheld (BH-3777)
    # is NOT READY: the READY arm would label it and ask Mergify, and Mergify
    # would then wait on queue_conditions until a person posted the verdict —
    # 17h of "QUEUED" on #3753/#3758. Here, so it is never enqueued at all.
    CLEAN) if [ -n "${MC_NEEDS_HV:-}" ]; then printf 'NEEDS_HUMAN_VERDICT\t%s' "$MC_NEEDS_HV"
           else printf 'READY\tclean, approved, checks green'; fi ;;
    # The same fact wearing GitHub's word for it: every run we can see passed,
    # but a REQUIRED context is not green, because the run that would have
    # reported it was cancelled or timed out (BH-636).
    UNSTABLE|BLOCKED)
      # ...UNLESS NOTHING ON THE BASE REQUIRES ANYTHING AT ALL (BH-800). That
      # BLOCKED is GitHub refusing the PUSH: this token is not in the branch's
      # push allow-list. The old reason was a forward-written claim about a
      # required context that does not exist (D5/D13), and the flake ladder was
      # spent re-running CI that could not change the answer. The STATE stays
      # WAIT_CI on purpose — BLOCKED_HUMAN feeds bin/blocked-resolver.sh, whose
      # ladder ends in a closed PR, and closing 42 PRs over a config gap is a
      # worse outcome than holding them.
      if [ "$ms" = BLOCKED ] && [ "${MC_IDENTITY_BLOCKED:-0}" = 1 ]; then
        printf 'WAIT_CI\tIDENTITY_NOT_PERMITTED %s: mergeState BLOCKED with no required checks and no required reviews — this identity cannot push' "${MC_IDENTITY_WORD:-unknown}"
      elif [ "${MC_CI_FLAKE:-0}" = 1 ] && [ "${MC_CI_TIMEOUT_FIRING:-0}" = 1 ]; then
        printf 'WAIT_CI\tchecks timeout budget — "%s" dies at its %s-min limit (CI_TIMEOUT_BUDGET; no rerun)' "${MC_CI_TIMEOUT_CHECK:-}" "${MC_CI_TIMEOUT_T:-}"
      elif [ "${MC_CI_FLAKE:-0}" = 1 ]; then printf 'WAIT_CI\tchecks flake — a required context was cancelled/timed_out; re-run once'
      else printf 'WAIT_CI\tmergeState %s (required context not green)' "$ms"; fi ;;
    UNKNOWN|"") if [ -n "$prev" ] && [ "$prev" != "-" ]; then printf '%s\tmergeState unknown, keeping prior state' "$prev"; else printf 'WAIT_CI\tmergeState unknown'; fi ;;
    *) printf 'WAIT_CI\tmergeState %s' "$ms" ;;
  esac
}

# mc_discount <owner/repo> <mstate> <ci> -> the effective merge state. The
# sweep's green-run discount: UNSTABLE with every run on the head concluded
# success is CLEAN for a non-project-4 repo. project-4 keeps its stricter rule (its E2E
# judges prod and is genuinely red), so it is not discounted here.
mc_discount() {
  local slug="$1" ms="$2" ci="$3"
  if [ "$ms" = UNSTABLE ] && [ "$ci" = green ] && ! grep -q '/project-4$' <<<"$slug"; then echo CLEAN; else echo "$ms"; fi
}


# mc_flake_rerun <owner/repo> <key> <head>
#   rc 0 means: this red is a KNOWN FLAKE, one rerun has been dispatched, and
#   the caller must NOT count a red strike for it. rc 1 means: count it.
#
#   WHY THIS IS SAFE AND WHY IT IS SO NARROW. Not counting reds is the cheapest
#   possible way to stop flaky CI blocking merges, and it is also how a
#   genuinely broken build gets auto-merged. So every one of these has to hold
#   before a red is forgiven:
#     * EVERY failing test on the head is already in the ledger as a flake on
#       at least FLAKY_MIN other heads. One unknown failure alongside a known
#       flake is an unknown red.
#     * We could READ what failed. A red we cannot name fails closed — "we
#       could not tell what broke" must never read as "nothing real broke".
#     * ONE rerun per (PR, head), guarded on MC_ATTEMPTS exactly like the
#       rebase and the re-review. The second red on the same head is a real red
#       and takes its strike, so the existing red-twice budget is untouched:
#       this buys a retry, it never buys forgiveness.
#     * It is a GitHub WRITE, so bin/merge-conductor.sh calls it only in actions
#       mode. In observe mode every red counts as it does today.
#
#   `gh run rerun --failed` re-runs the failed jobs INSIDE the same run, so the
#   run's own conclusion flips — which is what makes the next tick's mc_ci_state
#   see green without any special case there.
mc_flake_rerun() {
  local slug="$1" key="$2" head="$3" runs names id path name rsha n=0
  command -v flaky_all_known >/dev/null 2>&1 || return 1
  mc_attempt_has "flakererun $key $head" 2>/dev/null && return 1
  # ONE RERUN PER HEAD, WHOEVER BOUGHT IT (2026-09-15). The red ladder re-runs
  # any red once, so this head may already have had its rerun from the generic
  # path; dispatching a second one would be two builds of the same tree and, for
  # a head that is red for a real reason, a way to never reach RED_TWICE.
  [ -n "$(mc_rerun_mark "$key" "$head")" ] && return 1
  runs=$(flaky_failed_runs "$slug" "$head"); [ -n "$runs" ] || return 1
  names=$(while IFS='|' read -r id path name rsha; do
            [ -n "$id" ] && flaky_run_tests "$slug" "$id"
          done <<<"$runs" | grep -av '^$' | sort -u)
  [ -n "$names" ] || return 1
  flaky_all_known "$slug" <<<"$names" || return 1
  # BH-3804: still the PR's head? Asked only for a known flake, so an ordinary
  # red pays no extra read here; rc 1 counts the strike and mc_red_rerun, next,
  # stands down on its own check.
  mc_head_still "$slug" "$key" "$head" rerun || return 1
  # Recorded BEFORE the dispatch: a rerun we tried and could not send must not
  # become a rerun we try again every five minutes.
  mc_attempt_put "flakererun $key $head"
  mc_rerun_record "$key" "$head"
  while IFS='|' read -r id path name rsha; do
    [ -n "$id" ] || continue
    # BH-3804: a run listed for another sha is never re-run. An empty rsha (a
    # lib that prints three fields) leans on the list's own head_sha= filter.
    [ -n "$rsha" ] && [ "$rsha" != "$head" ] && { mc_log "$key run $id is on ${rsha:0:8}, not the PR head ${head:0:8} — not re-run"; continue; }
    gh run rerun "$id" --failed -R "$slug" >/dev/null 2>&1 && n=$((n+1))  # gh-guard-allow: CI rerun write verb, not a decision read (BH-784)
  done <<<"$runs"
  if [ "$n" -eq 0 ]; then
    mc_log "$key red on ${head:0:8} is a known flake but no rerun could be dispatched — counting it as a red"
    return 1
  fi
  mc_log "$key red on ${head:0:8}: every failing test is a known flake ($(printf '%s' "$names" | tr '\n' ';')) — re-ran $n failed run(s), no red strike"
  return 0
}

# --- The red ladder (2026-09-15, the operator: project-5 #1045) ----------------------
# `WAIT_CI checks red once` was a state with no exit. The red-twice park counts
# reds on DIFFERENT heads, so a PR that goes red and is never pushed to again
# stays in WAIT_CI for ever: #1045 (TK-989) went red at 02:04Z, was logged once,
# and was still sitting there at 12:52Z when the operator closed it by hand. The ladder
# gives that row its next transition, per HEAD:
#   rung 0  red seen, nothing tried        -> ONE `gh run rerun --failed`
#   rung 1  the rerun is in flight         -> WAIT_CI, and the reason says so
#   rung 2  red AGAIN on the same head     -> RED_TWICE, the resolver's
# and a NEW head resets it to rung 0, because a pushed head is a different tree
# with its own CI.
#
# The mechanics are mc_flake_rerun's (`gh run rerun --failed` re-runs the failed
# jobs INSIDE the same run, so the run's own conclusion flips and the next tick's
# mc_ci_state sees the answer with no special case). What is NOT shared is the
# forgiveness: the flake path's whole point is that a red whose every failing
# test is a known flake takes NO strike, and that bookkeeping is untouched here.
# This rerun buys a retry for a red that HAS already taken its strike.

# mc_rerun_mark <key> <head> -> the epoch the rerun for this (PR, head) was
#   dispatched at, or nothing. One line in MC_ATTEMPTS, beside rebase/red/
#   ejected/cikick, with a timestamp because the ladder has to tell "red again"
#   from "the same red, before GitHub flipped the run".
mc_rerun_mark() {
  mc_attempt_tail cirerun "$1" "$2" first
}

# --- Merge-queue re-entry (BH-636) -------------------------------------------
# mc_requeued_mark <key> <head>   -> the epoch this (PR, head) was put back into
#                                    the queue at, or nothing.
# mc_requeued_record <key> <head> -> record one.
# mc_ejection_live <key> <head>   -> rc 0 while this head is OUT of the queue
#                                    because the queue threw it out.
#
# THE PREDICATE IS THE WHOLE SAFETY ARGUMENT. `ejected` is append-only and keyed
# on the head, so it is true for ever once written — which is exactly right for
# "was this head ever ejected" and exactly wrong for "is it still out". Reading
# the bare mark as the second question is how a PR would be re-queued on every
# tick after the re-entry landed. So: ejected and not yet put back = live; put
# back = not live (the queue has it, or is deciding); put back and thrown out
# AGAIN = live once more, and that one belongs to bin/blocked-resolver.sh, not
# to another requeue.
mc_requeued_mark() {
  mc_attempt_tail requeued "$1" "$2" first
}
mc_requeued_record() { mc_attempt_put "requeued $1 $2 $(mc_now)"; }
mc_ejection_live() {
  local key="$1" head="$2"
  mc_attempt_has "ejected $key $head" 2>/dev/null || return 1
  [ -n "$(mc_requeued_mark "$key" "$head")" ] || return 0
  mc_attempt_has "reejected $key $head" 2>/dev/null
}
mc_rerun_record() { mc_attempt_put "cirerun $1 $2 $(mc_now)"; }

# --- BH-3804: a CI write is for the PR's LIVE head, never the tick's ----------
# The head every verb below is handed was read at the top of the tick, minutes
# before the write. project-4 #1815 (2026-10-01): a fix was pushed mid-tick, the
# red ladder re-ran the OLD head's failed run, and the repo's per-PR
# `cancel-in-progress` concurrency group cancelled every shard of the CURRENT
# head's run. So each write re-reads the head first.
#
# mc_pr_live_head <owner/repo> <pr-number> -> the PR's head.sha now, rc 0; rc 1
#   and nothing when the read failed or carried no sha. NOT memoised: it runs
#   right before a write, and a cached answer is the stale fact it exists to
#   replace.
mc_pr_live_head() {
  local slug="$1" num="$2" _plh="" sha
  command -v mc_rest_var >/dev/null 2>&1 || return 1
  mc_rest_var _plh gh_rest GET "repos/$slug/pulls/$num" || return 1
  sha=$(jq -r '.head.sha // ""' <<<"$_plh" 2>/dev/null)
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# mc_head_still <owner/repo> <key> <head> <what> — rc 0 when the PR is still at
#   <head>. rc 1 when it has moved (logged, stale_head_rerun_skipped bumped,
#   MC_LIVE_HEAD set); rc 2 when the head could not be read. FAIL CLOSED: an
#   unreadable head dispatches nothing either, at the cost of one tick — the
#   same "an empty read does not spend the rung" rule mc_red_rerun keeps.
mc_head_still() {
  local slug="$1" key="$2" head="$3" what="$4" num live
  num="${key##*#}"
  if ! live=$(mc_pr_live_head "$slug" "$num"); then
    mc_log "$key live head unreadable before a $what on ${head:0:8} — nothing dispatched this tick, no rung spent; the next tick asks again"
    return 2
  fi
  [ "$live" = "$head" ] && return 0
  mc_log "$key stale head: tick read ${head:0:8}, PR is at ${live:0:8} — no $what"
  [ -n "${P:-}" ] && mc_count_inc "$P" stale_head_rerun_skipped >/dev/null
  export MC_LIVE_HEAD="$live"
  return 1
}

# mc_flake_kick <owner/repo> <key> <head> <flake-runs> — ONE rerun of the runs a
#   killed runner left behind (mc_ci_flake_runs' "<id>|<name>[|<head_sha>]" lines). rc 0 when
#   something was dispatched, rc 1 when nothing was.
#
#   A FULL RERUN, NOT `--failed`. The red ladder re-runs failed JOBS inside a
#   run; a cancelled or timed-out run may have no failed job at all to name, and
#   `gh run rerun --failed` refuses it. Re-running the whole run is also the
#   right shape here: the question is not "does this job pass on a second look",
#   it is "does this tree build on a runner that lives".
#
#   It shares the `cirerun` mark with the red ladder, so a head gets ONE rerun
#   whoever buys it — a head that is both red and flaky must not be built twice,
#   and must still be able to reach RED_TWICE. The mark is written BEFORE the
#   dispatch, for mc_red_rerun's reason: a rerun we tried and could not send
#   must not be retried every five minutes.
mc_flake_kick() {
  local slug="$1" key="$2" head="$3" runs="$4" id name rsha n=0 names
  [ -n "$runs" ] || return 1
  [ -n "$(mc_rerun_mark "$key" "$head")" ] && return 1
  mc_head_still "$slug" "$key" "$head" rerun || return 1
  names=$(cut -d'|' -f2 <<<"$runs" | tr '\n' ';' | sed 's/;$//')
  mc_rerun_record "$key" "$head"
  while IFS='|' read -r id name rsha; do
    [ -n "$id" ] || continue
    [ -n "$rsha" ] && [ "$rsha" != "$head" ] && { mc_log "$key run $id is on ${rsha:0:8}, not the PR head ${head:0:8} — not re-run"; continue; }
    gh run rerun "$id" -R "$slug" >/dev/null 2>&1 && n=$((n+1))  # gh-guard-allow: CI rerun write verb, not a decision read (BH-784)
  done <<<"$runs"
  if [ "$n" -eq 0 ]; then
    mc_log "$key CI_FLAKE_RERUN dispatched nothing on ${head:0:8} ($names) — gh refused every run; the rung still moves, and the next flake on this head alerts"
    return 1
  fi
  mc_log "CI_FLAKE_RERUN $key $head ($n run(s): $names) — cancelled/timed_out is a killed runner, not a code failure: re-run in full, no red strike"
  return 0
}

# mc_red_rung <key> <head> -> 0 | 1 | 2 (see the ladder above).
#   THE SETTLE WINDOW IS LOAD-BEARING. `gh run rerun --failed` flips the run to
#   in_progress, but the tick that dispatched it reads CI BEFORE that, and the
#   API is not instant either. Without the window the very next tick would read
#   the old `completed|failure`, call it a second red, and park a PR whose rerun
#   is still running. MC_RED_RERUN_SETTLE_SECS (300, one tick) is that guard.
mc_red_rung() {
  local at
  at=$(mc_rerun_mark "$1" "$2")
  case "${at:-}" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  if [ "$(( $(mc_now) - at ))" -ge "${MC_RED_RERUN_SETTLE_SECS:-300}" ]; then printf '2'; else printf '1'; fi
}

# mc_red_rerun <owner/repo> <key> <head>
#   ONE rerun of the failed runs on this head, for ANY red — not just the
#   quarantined-flake red mc_flake_rerun forgives. rc 0 when a rerun was
#   dispatched by this call, rc 1 when none was (already used, nothing failed we
#   could name, or every dispatch was refused).
#
#   It is a GitHub WRITE, so bin/merge-conductor.sh calls it in actions mode
#   only; in observe mode a red behaves exactly as it did before this shipped.
#   The mark is written BEFORE the dispatch for mc_flake_rerun's reason: a rerun
#   we tried and could not send must not be retried every five minutes. A
#   dispatch that sent NOTHING says so in the log and the ladder still moves on
#   — nothing else is going to re-run that head, and RED_TWICE is an owner.
mc_red_rerun() {
  local slug="$1" key="$2" head="$3" runs id path name rsha n=0
  [ "${MC_RED_RERUN:-1}" != 0 ] || return 1
  [ -n "$(mc_rerun_mark "$key" "$head")" ] && return 1
  # A tree without bin/lib/flaky.sh cannot NAME the failed runs, so there is
  # nothing to re-run — but the rung still has to move, or the row is back in
  # the `red once` dead end this whole ladder exists to close. The mark is
  # recorded and the next red on this head is RED_TWICE, which has an owner.
  if ! command -v flaky_failed_runs >/dev/null 2>&1; then
    mc_head_still "$slug" "$key" "$head" rerun || return 1
    mc_log "$key red on ${head:0:8}: bin/lib/flaky.sh is absent, so the failed runs cannot be read — no rerun; the next red on this head is RED_TWICE"
    mc_rerun_record "$key" "$head"; return 1
  fi
  # AN EMPTY READ IS TRANSIENT, AND IT DOES NOT SPEND THE RUNG. mc_ci_state has
  # just said `red` off the SAME actions/runs endpoint, so a read that names no
  # failed run at all is the API refusing us, not a head with nothing to re-run.
  # Recording the mark here would put the row one tick from RED_TWICE — a fresh
  # rebuild of the ticket — on the strength of one flaky GET. The rung stays 0,
  # the next tick asks again, and a red that is permanently unreadable is caught
  # by the WAIT_CI TTL (mc_stuck_check) instead, which alerts rather than spends.
  runs=$(flaky_failed_runs "$slug" "$head")
  if [ -z "$runs" ]; then
    mc_log "$key red on ${head:0:8} but the failed runs could not be read — no rerun this tick and no rung spent; the next tick asks again"
    return 1
  fi
  # BH-3804: the PR must still be at this head, or nothing is written — no
  # rerun and no mark for either sha (project-4 #1815: a rerun of the old head's
  # run cancelled the new head's through the repo's cancel-in-progress group).
  mc_head_still "$slug" "$key" "$head" rerun || return 1
  mc_rerun_record "$key" "$head"
  while IFS='|' read -r id path name rsha; do
    [ -n "$id" ] || continue
    # BH-3804: a run listed for another sha is never re-run. An empty rsha (a
    # lib that prints three fields) leans on the list's own head_sha= filter.
    [ -n "$rsha" ] && [ "$rsha" != "$head" ] && { mc_log "$key run $id is on ${rsha:0:8}, not the PR head ${head:0:8} — not re-run"; continue; }
    gh run rerun "$id" --failed -R "$slug" >/dev/null 2>&1 && n=$((n+1))  # gh-guard-allow: CI rerun write verb, not a decision read (BH-784)
  done <<<"$runs"
  if [ "$n" -eq 0 ]; then
    mc_log "$key red on ${head:0:8}: no rerun could be dispatched (gh refused every failed run) — the next red on this head is RED_TWICE"
    return 1
  fi
  mc_log "$key red on ${head:0:8}: re-ran $n failed run(s) once (red ladder rung 1) — still red on this head and it is RED_TWICE, which bin/blocked-resolver.sh owns"
  return 0
}

# --- BH-1024: is an autopilot read already owed for this head? ---------------
# mc_ap_consumed <key> <head> <url> — rc 0 when no autopilot read is owed for
# this head, so the caller must not buy one.
#
# BH-1024: AN APPROVAL BOUND TO THIS EXACT SHA IS ASKED FOR FIRST. That is the
# fact the `apverdict <key> <head>` line stands in for after a consumed MERGE —
# hb_approve_bind rebinds the ledger approval onto this head — and unlike the
# line, the ledger can be read from a box that never ran the tick that wrote it,
# and survives an attempts.txt this box has rotated away.
#
# WHAT IT CANNOT DO, SAID PLAINLY. The only caller is the HEAD_MOVED arm, and
# mc_classify reaches HEAD_MOVED only when the verdict it read is not an APPROVE
# bound to this head. So on the ORDINARY path — one consistent read of the
# ledger — this arm answers rc 1 by construction and the `apverdict` line is
# what decides, exactly as before this ticket. It answers rc 0 only where the
# classifier's snapshot and the ledger DISAGREE, which is the drift this ticket
# is about: mc_verdict fell back to the record's `reviewed-sha` file because its
# own ledger read failed, or another lane (bin/blocked-resolver.sh's re-review,
# a rebase train's rebind) bound an approval to this head in the seconds between
# that read and this one. Then this answers with the newer fact and no second
# review is bought. The `apverdict` write stays for one full cycle either way.
#
# THE WORD IS CHECKED, NOT JUST THE SHA. "A settled verdict bound to this head"
# includes a BLOCK, and treating that as "consumed" would skip the free park in
# the caller below and buy a paid re-review instead — worse than the line it
# replaces. Only an APPROVE answers here.
#
# A CONSUMED BLOCK STAYS FILE-DEDUPED: hb_block_park writes no verdict row (a
# BLOCK row would overwrite the build's APPROVE and trip the sweep's
# contradiction park), so for BLOCK the line remains the only record. Giving a
# BLOCK its own ledger home is a separate slice.
mc_ap_consumed() {
  local key="$1" head="$2" url="$3"
  if type verdict_single_home_on >/dev/null 2>&1 && verdict_single_home_on \
     && [ -n "$url" ] && job_verdict_covers "$url" "$head" "" APPROVE; then return 0; fi
  mc_attempt_has "apverdict $key $head" 2>/dev/null
}

# --- The >12h autopilot's verdict (BH-764, 2026-09-18) -----------------------
# mc_autopilot_verdict <owner/repo> <num> <key> <head>
#   -> MERGE | MERGE-WITH-NOTES | BLOCK, or nothing.
#
# WHY THIS IS READ AT ALL. bin/review-autopilot.sh already buys an adversarial
# Fable review of every PR older than 12h and posts it, and NOTHING consumed the
# answer: a HEAD_MOVED row whose PR carried a `MERGE` verdict for its current
# head still bought a second review, and a `BLOCK` one was never parked. The
# review this lane needs has in many cases already been paid for.
#
# THE HEAD12 IN THE MARKER IS THE BINDING. A verdict is a fact about ONE sha, so
# a comment (or a row) for any other head prints nothing here — the same
# rule the conductor's own head-bound review follows.
#
# AND THE AUTHOR IS THE OTHER HALF OF THE BINDING. This verdict rebinds an
# approval, so the marker alone cannot be the credential: anyone with comment
# rights on the repo could otherwise paste `<!-- harness-review-autopilot … -->`
# plus `VERDICT: MERGE` and walk a PR to READY. The comment must be written by a
# login in harness_verdict_authors_json — the VERDICT-author set, deliberately
# narrower than the PR-author set: the builders App opens pool PRs but must never
# approve one (BH-1668) — normalised the way bin/lib/gh-pr-list.sh:180-182 normalises it
# (`app/` prefix and `[bot]` suffix stripped), because REST, GraphQL and git
# each hand us a different one of the three. If that function is not callable in
# this process (bin/merge-conductor.sh sources gh-pr-list.sh only when it is
# readable) the comment path is SKIPPED ENTIRELY: fail closed, rows only. An
# unauthenticated rebind is worse than a review we pay for twice.
#
# ORDER, AND WHAT IT COSTS (BH-1951: rows, then the comment; NO box file).
# 1. vd_clear_word: a lead/human MERGE or MERGE-WITH-NOTES standing on this
#    head. One verdicts GET.
# 2. vd_box_word: the newest `source=box` row on this head, which
#    bin/review-autopilot.sh POSTs after its comment is up and before its key
#    reaches `reviewed`. One more GET, only when nothing stands. A box BLOCK is
#    printed like the file's BLOCK was, so the arm below still parks it for the
#    resolver; a box row never STANDS, so it never trips the block gate.
# 3. Only when neither answers (no row, rc 1; or unreadable, rc 2) this reads
#    the PR — one `issues/<n>/comments` call, bounded to one per (PR, head) per
#    MC_AUTOPILOT_RECHECK_SECS by an `apread` mark.
# state/review-autopilot/ is NOT read: it is the autopilot's own dedupe ledger,
# and a verdict a merge lane acts on lives in the verdicts table or on the PR.
mc_autopilot_verdict() {
  local slug="$1" num="$2" key="$3" head="$4" h12 v at q body authors
  # h12 on its own line: `local` expands its whole argument list before any of
  # the assignments land, so "${head:0:12}" beside head="$4" reads the CALLER's
  # (unset) head and dies under set -u.
  h12="${head:0:12}"
  [ "${MC_AUTOPILOT_CONSUME:-1}" != 0 ] || return 0
  [ -n "$h12" ] || return 0
  # BH-1525: a lead/human MERGE row on this head, read from the table first. A
  # lead BLOCK row prints nothing here: the block gate enforces it, and this arm
  # would send it to the resolver's fix round instead of back to the lead.
  v=$(command -v vd_clear_word >/dev/null 2>&1 && vd_clear_word "$slug" "$num" "$head") && { printf '%s' "$v"; return 0; }
  # BH-1951: the autopilot's own box row on this head. rc 1 or 2 falls to the
  # comment read below, never to a file. The word is re-checked so a row can
  # only ever answer with the three words this arm acts on.
  v=$(command -v vd_box_word >/dev/null 2>&1 && vd_box_word "$slug" "$num" "$head") && case "$v" in
    MERGE|MERGE-WITH-NOTES|BLOCK) printf '%s' "$v"; return 0 ;; esac
  type harness_verdict_authors_json >/dev/null 2>&1 || return 0
  authors=$(harness_verdict_authors_json 2>/dev/null)
  [ -n "$authors" ] || return 0
  at=$(mc_ap_read_mark "$key" "$head")
  case "${at:-}" in
    ''|*[!0-9]*) ;;
    *) [ "$(( $(mc_now) - at ))" -ge "${MC_AUTOPILOT_RECHECK_SECS:-3600}" ] || return 0 ;;
  esac
  mc_attempt_put "apread $key $head $(mc_now)"
  # `gh api -q` takes a jq PROGRAM and no --argjson, so the author list is
  # interpolated as the JSON literal harness_verdict_authors_json just printed.
  q='('"$authors"' | map(sub("^app/"; "") | sub("\\[bot\\]$"; ""))) as $a
     | [.[]? | select((.body // "") | contains("<!-- harness-review-autopilot '"$h12"' -->"))
             | select(((.user.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "")) as $l | $a | index($l))]
     | last | .body // empty'
  # BH-1586: one page through gh_rest (ledgered, ETag), the program applied here.
  mc_rest_var body gh_rest GET "repos/$slug/issues/$num/comments?per_page=100" || return 0
  body=$(jq -r "$q" <<<"$body" 2>/dev/null) || return 0
  [ -n "$body" ] || return 0
  # The SAME reader bin/review-autopilot.sh writes the word with
  # (bin/lib/verdict-parse.sh, BH-1625): an anchored VERDICT line in the
  # review's final block, the comment's footer (after its last `---`) dropped
  # first. The word BLOCK in the prose above it is not one, and neither is a
  # verdict the review quotes.
  v=$(printf '%s\n' "$body" | verdict_parse -c -w 'MERGE-WITH-NOTES|BLOCK|MERGE' 2>/dev/null) || return 0
  printf '%s' "$v"
}
# The newest `apread` epoch for this (PR, head). Append-only like every other
# record in this file, so the last matching line is the current one.
mc_ap_read_mark() {
  mc_attempt_tail apread "$1" "$2" last
}

# mc_rr_noci_why <key> <head> — the sentence a verdict comment owes the PR when
#   the read behind it was bought without CI (the `rrnoci` record). Prints
#   nothing for every ordinary head, so the caller can append it unconditionally.
mc_rr_noci_why() {
  mc_attempt_has "rrnoci $1 $2" 2>/dev/null || return 0
  printf ' Judged WITHOUT CI: every workflow run on this head was cancelled or timed out, and the one full re-run the flake ladder sent ended the same way; this verdict rests on a static read alone.'
}
# pr_body_read — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# pr_body_read <pr-url> <flag-file> — the PR body, and a file left behind when
# GitHub would not give it. mc_is_harness_pr runs this down a pipe, so a
# variable is not a way to carry the rc back out; the file is (BH-784).
pr_body_read() {
  local out rc
  out=$(mc_pr_view "$1" .body); rc=$?
  [ "$rc" = 0 ] || : > "$2"
  printf '%s' "$out"
  return "$rc"
}

# ticket_open — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# ticket_open <project> <slug> <record-or-empty> <branch> — rc 0 when the
# issue a closed-unmerged PR was built for is still open. Issue-driven projects
# only (board prefix "-"); a board project's status is a thread-level judgement
# the triage prompt makes, so it is not decided here. The number is derived the
# way run-build/merge-sweep derive it (mc_issue_of: build KEY, then branch).
ticket_open() {
  local project="$1" slug="$2" rec="$3" br="$4" n st rc
  [ "$("$H/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null)" = "-" ] || return 1
  n=$(mc_issue_of "$rec" "$br"); [ -n "$n" ] || return 1
  # rc 75 is NOT "the issue is closed". It is "we could not ask", and the answer
  # this function owes on that is the same rc 1 a closed issue gets — skip the
  # close-out this tick — but it says so out loud, because a close-out silently
  # skipped every tick for an hour looks exactly like one that was never owed.
  # A 44 is a different sentence and gets its own line: an issue that is not
  # there is closed-equivalent for this decision, and it is still worth knowing
  # that the number we derived does not name an issue on that repo.
  # BH-1485: the `_var` variant, so the UNKNOWN line below names the real
  # status instead of whatever this shell last saw (000 until something else
  # had read uncaptured).
  rc=0; st=""
  gh_rest_issue_state_var st "$slug" "$n" || rc=$?
  if [ "$rc" = 44 ]; then
    mc_log "$slug#$n ticket_open ABSENT (HTTP 404) — no issue to close, close-out skipped this tick"
    return 1
  fi
  if [ "$rc" != 0 ]; then
    mc_log "$slug#$n ticket_open UNKNOWN (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — close-out skipped this tick"
    return 1
  fi
  [ "$st" = open ]
}

# hb_model_label — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# >>> rereview helpers (tests/review-record-integrity-test.sh section 1 sources these)
# hb_model_label <review-out-file> — the model that WROTE this review, for the
#   footer: the first line of <out>.model, which bin/agent-call.sh writes from
#   the model the lane actually served. It used to be the literal "(Fable)", and
#   #1577's re-review said "Fable" about an Opus 5.5 read (BH-1625). No
#   file, or nothing name-shaped in it, says so rather than naming a model.
hb_model_label() {
  local m=""
  [ -n "${1:-}" ] && [ -r "$1.model" ] && m=$(head -1 "$1.model" 2>/dev/null | tr -cd 'A-Za-z0-9._:/@+-' | head -c 120)
  [ -n "$m" ] || m="model unrecorded"
  printf '%s' "$m"
}

# hb_post — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# hb_post <key> <url> <rec> <head> <body-or-footer> [review-out-file]
#   THE ONE PLACE THE TWO HELPERS BELOW POST FROM (BH-641). Handed the review
#   file the lane wrote, it goes through bin/lib/review-post.sh: the findings
#   the verdict references are rendered INTO the comment, the review and its raw
#   envelope are written into the build record BEFORE the network call, and the
#   caller's line rides as the footer. Handed no review file (the >12h
#   autopilot's note, the re-apply's empty body) it posts the body as it stands,
#   which is what those callers have always done.
#   A POST THAT DID NOT LAND IS LOGGED, never swallowed by `|| true`: the
#   findings are on disk either way and the log line says where.
hb_post() {
  local key="$1" url="$2" rec="$3" head="$4" body="$5" outf="${6:-}"
  local kept rc=0 stub="" stubd="" env="" envnote=""
  # A NAMED OUT FILE THAT IS NOT THERE IS NOT "no review" (BH-641). Falling
  # through to the footer alone posts "BLOCK. Push fixes." with no findings in
  # it — byte for byte the artifact this ticket exists to stop — and persists
  # nothing and logs nothing. An empty file through the renderer says
  # PARSE_INCOMPLETE instead, which is the truth: the verdict is real, the
  # review text is gone. rp_persist refuses an empty copy, so the review an
  # earlier tick kept at this head is not overwritten.
  # THE ENVELOPE BESIDE THE MISSING .md IS REAL EVIDENCE (BH-1320), so it rides
  # in the comment: rp_post reads the envelope from beside the file it is
  # HANDED, so the stub goes in its own dir with a copy of <outf>.json next to
  # it, and the log names both paths. The envelope is NOT persisted to the build
  # record: rp_persist refuses the empty .md, and copying the .json alone would
  # split an earlier tick's pair there into an old review with a new envelope.
  if [ -n "$outf" ] && [ ! -r "$outf" ]; then
    envnote="; no envelope at $outf.json either"
    if [ -s "$outf.json" ]; then
      env="$outf.json"
      envnote="; its envelope $env is beside it and rides in the comment"
    fi
    mc_log "$key re-review of ${head:0:8}: the review out file $outf is missing or unreadable$envnote — posting PARSE_INCOMPLETE rather than the footer alone"
    if stubd=$(mktemp -d 2>/dev/null); then
      stub="$stubd/review.md"; : > "$stub"
      [ -n "$env" ] && cp "$env" "$stub.json" 2>/dev/null
      outf="$stub"
    fi
  fi
  if [ -n "$outf" ] && [ -r "$outf" ]; then
    kept=$(rp_post "$rec" "$head" "$outf" "$url" "$body") || rc=$?
    [ "$rc" = 0 ] || mc_log "$key re-review of ${head:0:8}: the review is persisted at ${kept:--} but the PR comment did NOT post (rc $rc)"
    [ -n "$stubd" ] && rm -rf "$stubd"
    return 0
  fi
  [ -n "$body" ] && { mc_pr_comment "$url" "$body" >/dev/null 2>&1 || true; }
  return 0
}

# hb_approve_bind — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# hb_approve_bind <mode> <key> <slug> <proj> <num> <url> <rec> <head> <mstate>
#                 <comment-body-or-empty> [review-out-file] [wait-review-reason]
#   WHAT AN APPROVE OF THIS HEAD DOES, in one place. Lifted out of the done)
#   branch below (BH-764) unchanged, because three callers now need exactly it:
#   the detached job's APPROVE, the >12h autopilot's MERGE, and the re-apply of
#   a verdict consumed on an earlier tick. The comment BODY belongs to the
#   caller, since only the caller knows what was read; an EMPTY body and no
#   review file post nothing, which is what the re-apply wants — that comment is
#   on the PR already. With a review file the body is the FOOTER under the
#   rendered findings (hb_post).
#   rc 0 = a provenance hold cleared and the tick carries on classifying.
#   rc 1 = the row was transitioned here; this tick is finished with the PR.
hb_approve_bind() {
  local mode="$1" key="$2" slug="$3" proj="$4" num="$5" url="$6" rec="$7" head="$8"
  local mstate="$9" body="${10}" outf="${11:-}"
  [ -n "$rec" ] && echo "$head" > "$rec/reviewed-sha"
  type job_verdict_rebind >/dev/null 2>&1 && job_verdict_rebind "$url" "$head" >/dev/null 2>&1 || true
  # The head this approval is now bound to gets its patch-id, so the
  # NEXT rebase of this PR is a rebind and not another review.
  mc_patch_id_remember "$rec" "$slug" "$proj" "$num" "$head" || true
  hb_post "$key" "$url" "$rec" "$head" "$body" "$outf"
  if [ "$mode" = provenance ]; then
    mc_prov_clear "$key" "$head"
    MC_PROV_CLEARED=1; REVIEWED="$head"; VERDICT=APPROVE
    mc_log "$key re-review APPROVE consumed on a provenance hold — ${head:0:8} has now been read by claude, so the non-primary provenance of the build's own review no longer parks it; classifying normally"
    return 0
  fi
  mc_transition "$key" WAIT_REVIEW "${12:-re-approved ${head:0:8}; reclassify next tick}" "$head" "$head" "$url" APPROVE "$mstate" "$rec" >/dev/null
  return 1
}

# hb_block_park — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# hb_block_park <key> <url> <rec> <head> <reviewed> <mstate> <comment-body-or-empty>
#               [clause] [review-out-file]
#   WHAT A BLOCK OF THIS HEAD DOES. Same lift, same reason. The log line's SHAPE
#   is load-bearing: bin/blocked-resolver.sh's br_handoff_lines parses
#   "<stamp>Z <key> BLOCKED_AGENT <reason> … <url>" out of this log, and
#   mc_transition writes the hand-off record on the way into BLOCKED_HUMAN. Only
#   the clause between the reason and " — handed to" varies by caller.
hb_block_park() {
  local key="$1" url="$2" rec="$3" head="$4" reviewed="$5" mstate="$6" body="${7:-}"
  local clause="${8:-the moved head was not re-approved, findings posted on the PR}"
  local outf="${9:-}"
  hb_post "$key" "$url" "$rec" "$head" "$body" "$outf"
  mc_hb_refuse "$key" "$head"   # OUR read said no about THIS head: mc_classify parks it from here on
  mc_transition "$key" BLOCKED_HUMAN "head-not-reapproved" "$head" "$reviewed" "$url" BLOCK "$mstate" "$rec" >/dev/null
  mc_log "$key BLOCKED_AGENT head-not-reapproved: $clause — handed to bin/blocked-resolver.sh (agent fix round against those findings): $url"
  return 1
}
# <<< rereview helpers

# headbound_review — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# headbound_review <mode> <key> <slug> <num> <project> <url> <record> <head>
#                  <reviewed> <verdict> <mstate> <ci>
#   THE TICK NEVER RUNS THE REVIEW (2026-09-14). It reads the detached job for
#   (this PR, THIS head) and does one of four things: consume a finished
#   verdict, note one still running, fail one that is not coming back, or spawn
#   one. Nothing here waits, so a 20-minute Fable call costs the next PR in the
#   list nothing at all.
#
#   ONE COPY, TWO CALLERS (2026-09-14, the #864 fix). It used to be the body of
#   the HEAD_MOVED arm and nothing else, and that is precisely how a PR parked
#   on `provenance` came to sit on a finished APPROVE nobody read: the row was
#   not in HEAD_MOVED, so the arm never ran. The same four answers are what a
#   provenance hold needs, so they live in one function with one difference —
#   what an APPROVE MEANS:
#     moved       the approval is rebound to the new head and the row goes
#                 WAIT_REVIEW to reclassify, exactly as before.
#     provenance  the head was READ BY CLAUDE, which is the whole of what the
#                 hold was about. The clearance is recorded (mc_prov_clear),
#                 the caller's VERDICT/REVIEWED/MC_PROV_CLEARED are moved onto
#                 this head, and NOTHING is transitioned — mc_classify runs
#                 straight after and gives the row its real state (READY, on a
#                 PR whose checks are green and whose merge state is CLEAN).
#   A BLOCK, a dead job and a spawn are identical in both modes.
#
#   rc 0 = CARRY ON CLASSIFYING this PR: nothing here put a state on the row, so
#          something must (a spawned review, a running one, a consumed APPROVE).
#   rc 1 = this tick is finished with this PR — this function already
#          transitioned it (a BLOCK, a dead job) and mc_classify would only
#          overwrite that with the reason it was parked on before.
#   The HEAD_MOVED arm ignores the rc: it is the end of the arm either way, and
#   every one of its paths transitions the row itself.
#   REREVIEW_BUDGET, REREVIEW_CAP and CAPFILE stay tick-level globals, because
#   they are per-tick and per-project budgets and not facts about this PR.
headbound_review() {
  local mode="$1" key="$2" slug="$3" num="$4" proj="$5" url="$6" rec="$7" head="$8"
  local reviewed="$9" verdict="${10}" mstate="${11}" ci="${12}"
  local jobf jobst rrwhat v outf rc run why n ep apv rr_acct
  jobf=$(mc_rr_file "$slug" "$num" "$head"); jobst=$(mc_rr_state "$jobf")
  # What to CALL it on the PR. HEAD_MOVED also covers a head with no verdict
  # bound to it at all (2026-09-14), where there is no previous reviewed sha and
  # so nothing to re-review: that reads as a fresh review.
  rrwhat="Head-bound harness re-review"
  case "${reviewed:--}" in ''|-) rrwhat="Fresh head-bound harness review" ;; esac
  case "$jobst" in
    running)
      if [ "$mode" = provenance ]; then
        mc_log "$key re-review of ${head:0:8} still running on a provenance hold — nothing waits on it"
      else
        mc_log "$key REREVIEWING ${head:0:8} — detached job (pid $(mc_rr_field "$jobf" pid)) still running; nothing waits on it"
        mc_transition "$key" HEAD_MOVED "REREVIEWING ${head:0:8} (detached re-review running)" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
      fi
      return 0 ;;
    done)
      v=$(mc_rr_field "$jobf" verdict); outf=$(mc_rr_field "$jobf" out_file)
      # Consumed ONCE per (PR, head): the verdict is a fact about a head, and a
      # BLOCK that re-posted its findings every five minutes would be the
      # comment spam the one-review-per-head rule exists to stop.
      #
      # BUT A CONSUMED VERDICT IS NOT A SILENT RETURN (BH-764). This was the
      # ONLY exit from this function that said nothing at all on a green head,
      # and it is the shape cromford#609 sat in: the verdict was read on an
      # earlier tick, the ledger's reviewed sha never moved, and every tick
      # since walked out of here with no line and no transition. An APPROVE
      # still HAS something to apply, so it is applied once — anything else says
      # so once and leaves the PR to the stuck alert, which is a real owner.
      if mc_attempted rereviewdone "$key" "$head"; then
        if [ "$v" = APPROVE ] && ! mc_attempted rereviewreapply "$key" "$head"; then
          mc_log "$key head-bound APPROVE of ${head:0:8} was consumed on an earlier tick but the row is still HEAD_MOVED (the ledger's reviewed sha did not move) — re-applied once"
          hb_approve_bind "$mode" "$key" "$slug" "$proj" "$num" "$url" "$rec" "$head" "$mstate" ""
          return $?
        fi
        mc_attempted rrconsumed "$key" "$head" || \
          mc_log "$key head-bound verdict $v on ${head:0:8} was consumed earlier and the row is still HEAD_MOVED — nothing left to apply here; the stuck alert stands"
        return 1
      fi
      # >>> rereview post (tests/review-record-integrity-test.sh section 1 drives this block)
      # THE OUT FILE, NOT A PRE-BUILT BODY (BH-641). The two helpers are handed
      # the review the lane wrote and the lane's own line; bin/lib/review-post.sh
      # renders the findings the verdict references INTO the comment and leaves
      # a copy in the build record before the post, instead of publishing the
      # agent's stdout verbatim and keeping nothing.
      if [ "$v" = APPROVE ]; then
        # Only in `moved` mode, as before: a provenance hold logs its own line
        # inside hb_approve_bind and never carried this one.
        [ "$mode" = provenance ] || mc_log "$key head-bound re-review APPROVED ${head:0:8} — approval rebound"
        hb_approve_bind "$mode" "$key" "$slug" "$proj" "$num" "$url" "$rec" "$head" "$mstate" \
          "$(printf '_%s (%s) of %s: APPROVE — approval rebound to this head. Static review, no build run._%s' "$rrwhat" "$(hb_model_label "$outf")" "$head" "$(mc_rr_noci_why "$key" "$head")")" "$outf"
        return $?
      fi
      # A NEWER HUMAN MERGE ON THIS HEAD OVERRIDES THE BLOCK (BH-3814). The
      # findings still post, under a footer that says why they do not park it.
      # rc 1 and rc 2 (the verdicts table unreadable) park exactly as before.
      if command -v mc_hv_override >/dev/null 2>&1 && mc_hv_override "$key" "$head"; then
        mc_attempt_put "hvoverride $key $head"
        mc_log "$key human verdict #$MC_HV_ID overrides re-review BLOCK on ${head:0:8} — $MC_HV_VERDICT by $MC_HV_SOURCE at $MC_HV_AT, after the re-review finished; approval rebound, no hand-off to bin/blocked-resolver.sh"
        hb_approve_bind "$mode" "$key" "$slug" "$proj" "$num" "$url" "$rec" "$head" "$mstate" \
          "$(printf '_%s (%s) of %s: BLOCK. Human verdict #%s (%s, %s) on this exact head came after it, so it overrides the BLOCK. Approval rebound; no agent fix round._' "$rrwhat" "$(hb_model_label "$outf")" "$head" "$MC_HV_ID" "$MC_HV_VERDICT" "$MC_HV_AT")" \
          "$outf" "human verdict #$MC_HV_ID overrides re-review BLOCK on ${head:0:8}; reclassify next tick"
        return $?
      fi
      mc_log "$key head-bound re-review BLOCKED ${head:0:8}"
      hb_block_park "$key" "$url" "$rec" "$head" "$reviewed" "$mstate" \
        "$(printf '_%s (%s) of %s: BLOCK. Static review, no build run. Push fixes; the conductor reviews the next head._%s' "$rrwhat" "$(hb_model_label "$outf")" "$head" "$(mc_rr_noci_why "$key" "$head")")" "" "$outf"
      # <<< rereview post
      return 1 ;;
    lanefail)
      # THE LANE DIED UNDER THE JOB — this is not an answer about the PR
      # (2026-09-16, project-5 #1621). The job ran and came back with our own
      # outage in its hands: a 429 session limit on the claude account, a
      # survival ladder that could not carry a review-sized prompt, or a
      # non-Claude runner serving a read the gate asked Claude for. None of
      # those is evidence about this diff, so none of them spends the PR's
      # no-verdict strike. The job file is REMOVED, which puts this head back in
      # the `none` case: the next tick buys another read, through the same
      # budget, cap and CI-green debounce as the first one.
      why=$(mc_rr_field "$jobf" reason)
      case "$why" in ''|-|null) why="the review lane failed" ;; esac
      # COUNTED AGAINST THE OUTAGE, NOT JUST THE HEAD (BH-1019). A 429 on this
      # box's claude account is true of every call it makes for the next hour,
      # so a cap keyed on (PR, head) alone bought five copies of one refusal.
      # The epoch is the lane's health, and it changes only when the lane does:
      # reads are capped WITHIN an outage, and a lane that recovers is a new
      # condition worth asking under.
      ep=$(mc_lane_epoch)
      n=$(mc_rr_lanefail_count "$key" "$head" "$ep")
      if [ "$n" -lt "${MC_RR_LANEFAIL_MAX:-5}" ]; then
        mc_rr_lanefail_note "$key" "$head" "$ep"
        rm -f "$jobf" "${jobf%.json}.out.lanefail"
        mc_log "$key re-review LANE FAILED on ${head:0:8} (read $((n+1)) of ${MC_RR_LANEFAIL_MAX:-5} in lane epoch $ep): $why — nothing read the code, so no verdict, no strike and no park; the next tick buys another read once the lane is up"
        return 0
      fi
      # Out of reads. The lane, not the PR, is what is broken, and stopping is
      # an alert rather than a whisper: ONE line naming what is down and what it
      # is holding. The park is still `no-verdict`, which bin/blocked-resolver.sh
      # owns and which NEVER closes a PR — silence from our own reviewer is not
      # a failed event of somebody's build.
      rm -f "$jobf" "${jobf%.json}.out.lanefail"
      # THE SHA THE PARK IS BOUND TO (BH-1019), written BEFORE the transition:
      # the next tick's classifier reads it back and holds the park, instead of
      # re-deriving the row to HEAD_MOVED on the very drift that caused it and
      # arming the spawn again on an untouched head (cromford#818).
      mc_hb_park "$key" "$head" "$ep"
      mc_alert "$key" BLOCKED_AGENT "the review lane has failed ${MC_RR_LANEFAIL_MAX:-5} times on ${head:0:8} and no Claude read of this head has been possible — $why. The PR is parked (not closed) and bin/blocked-resolver.sh keeps asking; fix the review lane (account quota / survival ladder) and it clears itself: $url" 1
      mc_log "$key BLOCKED_AGENT no-verdict: the review lane failed ${MC_RR_LANEFAIL_MAX:-5} times on ${head:0:8} ($why) — nothing read the code; handed to bin/blocked-resolver.sh, which re-asks and never closes the PR on silence: $url"
      mc_transition "$key" BLOCKED_HUMAN "no-verdict: review lane down — $why" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
      return 1 ;;
    failed|stale)
      # A job whose pid is gone or that is past MC_REREVIEW_TIMEOUT_SECS is the
      # SAME fact as the old inline "no verdict": nobody answered. It takes the
      # existing no-verdict path, which the resolver owns.
      [ "$jobst" = stale ] && { mc_rr_fail "$jobf"; mc_log "$key detached re-review on ${head:0:8} is gone (pid dead or past ${MC_REREVIEW_TIMEOUT_SECS:-2700}s) — failed"; }
      rereview_lane_retry "$mode" "$key" "$url" "$rec" "$head" "$reviewed" "$verdict" "$mstate" "$jobf" && return 0
      mc_attempted rereviewfailed "$key" "$head" && return 1
      mc_log "$key head-bound re-review produced NO verdict on ${head:0:8}"
      # BH-1019: bound to this sha AND to the lane-health epoch, so the park
      # cannot re-arm itself on the drift that caused it — and IS released
      # when the lane comes back, which a sha-only key could never do.
      mc_hb_park "$key" "$head" "$(mc_lane_epoch)"
      mc_transition "$key" BLOCKED_HUMAN "no-verdict" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
      mc_log "$key BLOCKED_AGENT no-verdict: the re-review of the moved head produced no verdict — handed to bin/blocked-resolver.sh, which re-asks and never closes the PR on silence: $url"
      return 1 ;;
    *)
      # THE REVIEW MAY ALREADY BE PAID FOR (BH-764). bin/review-autopilot.sh
      # posts an adversarial Fable review on every PR open more than 12h, and
      # nothing consumed the answer: a moved head whose PR already carried a
      # MERGE verdict for THIS exact sha bought a second read, and a BLOCK one
      # was never parked at all. Asked FIRST, before the budget, because
      # consuming a verdict spends none of it.
      #
      # A MERGE IS CONSUMED ONLY WHERE A REVIEW WOULD HAVE BEEN BOUGHT. The
      # debounce below buys nothing until CI is green (or, on the rung-2 path,
      # until the runs have been proved dead), and rebinding an approval on a
      # head that is still building would be a weaker gate than the one it
      # replaces. So a MERGE on a non-green head records NOTHING and falls
      # through to the ordinary deferral; the row reads are one GET each and the
      # comment read is bounded hourly, so asking again costs almost nothing.
      # A BLOCK is consumed whatever CI says: it parks, and parking a head whose
      # build is still running is not a risk, it is the answer.
      #
      # The `apverdict` record is written only once a verdict string was
      # PARSED — an absent verdict must be asked for again (the hourly `apread`
      # mark inside mc_autopilot_verdict is what bounds that), and "stamped
      # consumed without a verdict" must be impossible.
      #
      # WHETHER IT IS ALREADY CONSUMED is mc_ap_consumed's question (BH-1024):
      # a ledger APPROVAL bound to this exact sha answers it first, and the
      # `apverdict` line below is the fallback it is standing in for. It can
      # only differ from the line where this tick's classification and the
      # ledger disagree — a stale record file, or a rebind by another lane
      # since the read above. The function says which, and why a BLOCK bound to
      # this head is deliberately NOT "consumed" here: parking it below is free
      # and a re-review is not.
      if [ "$mode" = moved ] && ! mc_ap_consumed "$key" "$head" "$url"; then
        apv=$(mc_autopilot_verdict "$slug" "$num" "$key" "$head")
        case "$apv" in
          MERGE|MERGE-WITH-NOTES)
            if [ "$ci" = green ] || mc_attempt_has "rrnoci $key $head" 2>/dev/null; then
              mc_attempt_put "apverdict $key $head"
              mc_log "$key AUTOPILOT_VERDICT consumed: $apv on ${head:0:8} — the >12h review autopilot has already read this exact head, so no second review was bought; approval rebound, reclassify next tick"
              hb_approve_bind "$mode" "$key" "$slug" "$proj" "$num" "$url" "$rec" "$head" "$mstate" \
                "$(printf '_Merge conductor: the >12h autopilot review of %s verdicted %s, which is bound to this exact head — approval rebound to it; no second review bought. Static review, no build run; the notes above stand._%s' "${head:0:12}" "$apv" "$(mc_rr_noci_why "$key" "$head")")"
              return 1
            fi ;;
          BLOCK)
            mc_attempt_put "apverdict $key $head"
            mc_log "$key AUTOPILOT_VERDICT consumed: BLOCK on ${head:0:8} — the >12h review autopilot has already read this exact head; parking it rather than buying a second read"
            hb_block_park "$key" "$url" "$rec" "$head" "$reviewed" "$mstate" \
              "$(printf '_Merge conductor: the >12h autopilot review of %s verdicted BLOCK, bound to this exact head. Parked as head-not-reapproved and handed to bin/blocked-resolver.sh, which runs a fix round against the findings above. No second review was bought._' "${head:0:12}")" \
              "the >12h autopilot review of ${head:0:12} verdicted BLOCK on this exact head and nothing has re-approved it"
            return 1 ;;
        esac
      fi
      # A LEAD/HUMAN BLOCK ROW ON THIS HEAD IS THE READ ALREADY BOUGHT (BH-1525):
      # the block gate refuses the merge whatever a box review says, so a box
      # re-review of this exact head is spend with no possible effect. Said once.
      if command -v vd_block_line >/dev/null 2>&1 && vd_block_line "$slug" "$num" "$url" "$head" >/dev/null; then
        mc_attempt_has "leadblock $key $head" 2>/dev/null || { mc_attempt_put "leadblock $key $head"
          mc_log "$key re-review of ${head:0:8} not bought — a lead/human BLOCK verdict row stands on this exact head; the block gate refuses it until a push or a newer MERGE row"; }
        return 0
      fi
      # >>> conductor bound-verdict consume (BH-3930)
      # A VERDICT ALREADY PAID FOR ON THIS EXACT HEAD IS NOT BOUGHT AGAIN.
      # review_bought (bin/lib/review-bought.sh) asks the D1 rows and the box
      # history, minus the builder's own round (--except-builder). Same arms as
      # the AUTOPILOT consume above: an approve rebinds only where a review
      # would have been bought (CI green, or the rung-2 `rrnoci` record), and a
      # non-green head records nothing and falls through to the CI deferral; a
      # block parks whatever CI says. Any other class, a miss, a failed read, a
      # provenance hold or a tree without the lib takes today's path.
      # THE PROVENANCE HOLD (BH-4134): an approve whose serving lane is unknown
      # or a fallback (review_bought_prov) is not consumed. It is marked
      # `rbprov` once, and the spawn below buys a Claude read of this head under
      # MC_RR_REASON=prov, its own key. A lead/human row is cleared (BH-1525).
      if [ "$mode" = moved ] && command -v mc_rb_load >/dev/null 2>&1 && mc_rb_load \
         && review_dedupe_on && review_bought "$slug" "$num" "$head" --except-builder >/dev/null 2>&1; then
        case "${RB_CLASS:-}" in
          approve)
            case "$(review_bought_prov 2>/dev/null || echo unknown)" in
              unknown|fallback)
                if ! mc_attempt_has "rbprov $key $head" 2>/dev/null; then
                  mc_attempt_put "rbprov $key $head"
                  mc_log "$key BOUND_VERDICT refused: $RB_SOURCE's APPROVE on ${head:0:8} carries provenance '${RB_SERVED:-none}' — not consumed; a claude read is bought under ~prov"
                fi ;;
              *)
                if [ "$ci" = green ] || mc_attempt_has "rrnoci $key $head" 2>/dev/null; then
                  mc_attempt_put "rbverdict $key $head"
                  review_skip_log "$MC_LOG" "$slug" "$num" "$head" merge-conductor
                  mc_log "$key BOUND_VERDICT consumed: $RB_SOURCE verdicted $RB_WORD on ${head:0:8} — already paid for on this exact head, so no second review was bought; approval rebound, reclassify next tick"
                  hb_approve_bind "$mode" "$key" "$slug" "$proj" "$num" "$url" "$rec" "$head" "$mstate" \
                    "$(printf '_Merge conductor: %s already verdicted %s on this exact head (%s). Approval rebound; no second review bought._%s' "$RB_SOURCE" "$RB_WORD" "${head:0:12}" "$(mc_rr_noci_why "$key" "$head")")"
                  return 1
                fi
                ;;
            esac ;;
          block)
            mc_attempt_put "rbverdict $key $head"
            review_skip_log "$MC_LOG" "$slug" "$num" "$head" merge-conductor
            mc_log "$key BOUND_VERDICT consumed: $RB_SOURCE verdicted $RB_WORD on ${head:0:8} — already paid for on this exact head; parking it rather than buying a second read"
            hb_block_park "$key" "$url" "$rec" "$head" "$reviewed" "$mstate" \
              "$(printf '_Merge conductor: %s already verdicted %s on this exact head (%s). Parked as head-not-reapproved and handed to bin/blocked-resolver.sh. No second review was bought._' "$RB_SOURCE" "$RB_WORD" "${head:0:12}")" \
              "$RB_SOURCE verdicted $RB_WORD on ${head:0:12} and nothing has re-approved it"
            return 1 ;;
        esac
      fi
      # <<< conductor bound-verdict consume
      # THE LANE IS DOWN: DO NOT BUY A READ IT CANNOT SERVE (BH-1019/BH-1090).
      # bin/claude-auth-check.sh probes `claude -p ok` end to end and keeps
      # state/claude-auth-down.txt; while this box is on that list, every
      # head-bound read spawned here either refuses (mc_rereview now asks for
      # the claude lane and nothing else) or, before this change, descended the
      # ladder and bought a verdict the provenance gate rejects on arrival.
      # Either way nothing reads the code, so the tick simply waits for an
      # EVENT — the lane answering its canary again — rather than spending a
      # spawn, a budget unit and a daily-cap slot every five minutes.
      # Said once per (PR, head, epoch): the marker can stand for hours.
      # The account that would actually pay is consulted so a routed-account
      # cooldown is not masked by a healthy default-account canary.
      rr_acct=$(mc_lane_next_review_account)
      if mc_lane_down_for_account "$rr_acct"; then
        ep=$(mc_lane_epoch)
        if ! mc_attempt_has "lanedown $key $head $ep" 2>/dev/null; then
          mc_attempt_put "lanedown $key $head $ep"
          mc_log "$key re-review of ${head:0:8} not spawned — account $rr_acct lane-down marker is set (lane epoch $ep) and a claude read of this head is what the gate asks for; nothing is bought until that account answers its canary again, or — for a routed account, which no canary probes — until the marker ages past ${MC_LANE_ROUTED_RETRY_SECS}s and this tick's re-review budget is spent asking again"
        fi
        return 0
      fi
      # Same file-not-variable rule as the rebase and merge budgets: this
      # function runs inside a PR worker, and a variable it decremented would be
      # decremented in that worker's own copy.
      mc_tick_budget_left "$proj" rereview "$REREVIEW_BUDGET" || { budget_spent "$proj" rereview "$key"; return 0; }
      # The review-prs debounce: a moved head is re-reviewed only once its CI is
      # green — a head that dies in CI is reviewed for nothing.
      #
      # AND "NO RUN AT ALL" IS NOT A CI STATE TO WAIT ON (BH-636). The debounce
      # waits for green, and a head GitHub never built never goes green, so this
      # line was the whole of what #1827 and #1645 got, every five minutes, for
      # ever. The three silences are now told apart by name: a run in flight is
      # waited on (unchanged, byte for byte — other suites pin that line), a
      # killed runner is the flake ladder's, and an ABSENT run is kicked.
      #
      # AND A FLAKE LADDER THAT HAS RUN OUT IS NOT A CI STATE TO WAIT ON EITHER
      # (BH-764). BH-636 re-runs a cancelled/timed_out head ONCE, on the shared
      # `cirerun` mark. When that rerun dies the same way — a 20-minute compile
      # against a `timeout-minutes: 20` job does it every time — the ladder is
      # spent, WAIT_CI has already alerted CI_FLAKE_TWICE, and this line was all
      # the PR got, every five minutes, for ever. Rung 2 is that fact, so rung 2
      # buys the read WITHOUT CI and the verdict comment says so. Nothing merges
      # on it: the row goes to WAIT_REVIEW and READY still requires green.
      case "$ci" in
        green) ;;
        none)
          if [ -n "${MC_FLAKE:-}" ]; then
            if [ "${MC_FLAKE_RUNG:-0}" -ge 2 ]; then
              # SAID ONCE, not once per tick: the spawn below can still be
              # refused by a running job, the daily cap or the budget, and this
              # line must not become the every-five-minutes noise it replaces.
              # Recorded BEFORE the spawn so a refusal keeps the record and only
              # retries the spawn.
              if ! mc_attempt_has "rrnoci $key $head" 2>/dev/null; then
                mc_attempt_put "rrnoci $key $head"
                mc_log "$key re-review bought WITHOUT CI on ${head:0:8} — every run was cancelled/timed_out, the flake ladder's one rerun ended the same way; the verdict comment will say so"
              fi
            else
              mc_log "$key re-review deferred — ci=flake on ${head:0:8} (cancelled/timed_out; the flake ladder re-runs it once)"
              return 0
            fi
          else
            ci_absent_kick "$key" "$slug" "$num" "$url" "$head" "$mstate"
            return 0
          fi ;;
        *) mc_log "$key re-review deferred — CI $ci on ${head:0:8}"; return 0 ;;
      esac
      # THE PR'S OWN BUILD MAY STILL BE REVIEWING IT (2026-09-14). A pool build
      # writes its verdict at the END of its pipeline, and the tick sees the PR
      # minutes earlier. Buying a review here is a second Fable call on a head
      # somebody is already reading — and the verdict that lands afterwards is
      # what put project-5 #864 into a `provenance` park in the first place.
      # Bounded by MC_JOB_WAIT_SECS so a builder that died cannot hold a PR.
      if run=$(mc_job_running "$url"); then
        mc_log "$key job still running, not buying a review — the build's own pipeline owns this PR ($run)"
        return 0
      fi
      if [ "${REREVIEW_CAP:-0}" -gt 0 ] && [ "$(grep -c "^$proj " "$CAPFILE")" -ge "$REREVIEW_CAP" ]; then
        mc_log "$key re-review deferred — $proj hit the operator-set daily cap ($REREVIEW_CAP)"; return 0; fi
      # Taken before the spawn, handed back when the spawn was refused at the
      # fleet-wide parallel cap (rc 3) or failed: a review nobody bought must
      # not cost the project one.
      mc_tick_budget_take "$proj" rereview "$REREVIEW_BUDGET" || { budget_spent "$proj" rereview "$key"; return 0; }
      mc_rereview_spawn "$slug" "$num" "$proj" "$url" "$reviewed" "$head" "$rec"; rc=$?
      [ "$rc" = 0 ] || mc_tick_budget_give "$proj" rereview
      case "$rc" in
        0) mc_count_inc "$proj" rereviews >/dev/null; echo "$proj $key $head" >> "$CAPFILE"
           mc_log "$key REREVIEW_SPAWNED — detached head-bound re-review of ${head:0:8} (job $jobf)"
           if [ "$mode" = provenance ]; then
             mc_log "$key provenance hold: the fix for a non-claude review is a claude read of this head, so the conductor bought one"
           else
             mc_transition "$key" HEAD_MOVED "REREVIEWING ${head:0:8} (detached re-review spawned)" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
           fi ;;
        4) mc_log "$key re-review of ${head:0:8} already finished (its job file is gone, the row says done) — not bought again; the stuck alert owns this row" ;;
        3) mc_log "$key REREVIEW_QUEUED — ${MC_REREVIEW_PARALLEL:-0} re-reviews already running fleet-wide (operator-set MC_REREVIEW_PARALLEL); spawning on a later tick" ;;
        *) mc_log "$key detached re-review could not be spawned (rc $rc)" ;;
      esac
      return 0 ;;
  esac
}

# ci_absent_kick — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# ci_absent_kick <key> <slug> <num> <url> <head> <mstate>
#   A head with NO workflow run on it, on the re-review path. The WAIT_CI
#   catch-all further down has fired this kick since 2026-09-15; this is the
#   same answer for the same fact seen from the other arm, and it is the one
#   #1827/#1645 needed.
#
#   THE GUARDS ARE THE CATCH-ALL'S, minus one. Not DIRTY, because GitHub runs no
#   workflow on a tree it cannot merge and kicking those would close and reopen
#   every conflicted PR on the fleet for nothing. Old enough, because below the
#   window a missing run is a run that has not APPEARED yet. Once per head,
#   recorded. Actions only. The BASE guard is not repeated here: a PR that is not
#   on the project's base classifies STACKED_WAIT in mc_classify, ahead of the
#   drift branch, so a HEAD_MOVED row is on the project base by construction.
ci_absent_kick() {
  local key="$1" slug="$2" num="$3" url="$4" head="$5" mstate="$6" since age
  if [ "$mstate" = DIRTY ]; then
    mc_log "$key re-review deferred — ci=absent on ${head:0:8} (the head conflicts, so GitHub builds nothing: the rebase owns it, not the kick)"
    return 0
  fi
  since=$(mc_row_field "$key" 3); age=$(( $(mc_now) - ${since:-0} ))
  if [ -z "$since" ] || [ "$age" -lt "${MC_CI_KICK_MIN_AGE:-600}" ]; then
    mc_log "$key re-review deferred — ci=absent on ${head:0:8} ($((age/60))m; a run that has not appeared yet)"
    return 0
  fi
  if mc_attempt_has "cikick $key $head" 2>/dev/null; then
    ci_absent_escalate "$key" "$url" "$head" "$age"
    return 0
  fi
  if [ "$ACTIONS" != 1 ]; then
    mc_log "$key would kick CI on ${head:0:8} — ci=absent, $((age/60))m with no workflow run at all (observe mode: nothing written)"
    return 0
  fi
  if mc_kick_ci "$slug" "$num" "$head"; then
    mc_attempt_put "cikick $key $head"
    mc_log "$key CI_KICKED $key $head — ci=absent after $((age/60))m, closed and reopened so GitHub starts a run on the head the re-review is waiting for"
  else
    mc_log "$key CI kick FAILED on ${head:0:8} — the re-review stays deferred and a later tick tries again"
  fi
  return 0
}

# ci_absent_escalate — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# ci_absent_escalate <key> <url> <head> <age>
#   THE SECOND SILENCE IS A DIFFERENT FACT FROM THE FIRST. One kick and still no
#   run means the workflow is not going to fire for this head at all — a
#   `pull_request` branches filter that does not match this base, a workflow file
#   that does not exist on it — and no amount of waiting fixes that. So it says
#   so ONCE, with the two things a person would actually check, and then goes
#   quiet again. The mark is written BEFORE the alert: a send that dies costs one
#   alert, never a storm.
ci_absent_escalate() {
  local key="$1" url="$2" head="$3" age="${4:-0}" win
  win=$(( ${MC_CI_KICK_MIN_AGE:-600} * 2 ))
  if [ "$age" -ge "$win" ] && ! mc_attempt_has "cikickalert $key $head" 2>/dev/null; then
    mc_attempt_put "cikickalert $key $head"
    mc_alert "$key" WAIT_CI "CI_ABSENT_TWICE: kicked once (close/reopen) and GitHub still ran no workflow on ${head:0:8} after $((age/60))m — check ci.yml's pull_request branches filter for this base, or push an empty commit by hand: $url"
    mc_log "$key CI_ABSENT_TWICE $key $head — one kick spent and the head is still run-less; alerted once"
    return 0
  fi
  mc_log "$key re-review deferred — ci=absent on ${head:0:8} (kicked once, $((age/60))m waiting for a run to appear)"
  return 0
}

# stuck_rekick — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# stuck_rekick <key> <state> <reason> <slug> <num> <url> <head> <mstate>
#             <mergeable> <baseRef> <projectBase> <ci>
#   Called ONCE per (PR, state, head), by the tick, the moment mc_stuck_check
#   says that triple has crossed its TTL. Its job is the second half of "no
#   terminal state without an owner": the alert says what the PR is waiting on,
#   and this does the deterministic thing that can make it move again. Where no
#   such thing exists the alert IS the action, and that is said out loud in the
#   log rather than left as silence.
#
#   THE RE-KICKS, AND WHY EACH IS SAFE TO DO BLIND:
#     WAIT_CI            close/reopen, which fires the repo's `pull_request`
#                        workflows — but ONLY on a head with no run at all
#                        (`ci=none`). A kick on a pending run CANCELS it through
#                        the repo's own concurrency group, and a kick on a red
#                        one is the red ladder's business, not this one's.
#                        Guarded exactly like the 10-minute kick above,
#                        including its one-cikick-per-head record.
#     NEEDS_REBASE /     forget this head's `rebase` and `mergetree` attempts and
#     REBASING           its `rebasedone`/`rebasefailed` consumed-result markers
#                        (BH-523 — a marker left behind makes rebase_consume drop
#                        the respawned rebase's result), so the next tick
#                        re-derives the merge state from GitHub and may spawn a
#                        fresh rebase. This is the shape that strands silently:
#                        the attempt is recorded, the detached job file is gone
#                        (a lost spawn, a GC'd result), and the NEEDS_REBASE
#                        arm's `*)` case then `continue`s for ever.
#                        Local state only — nothing is written to GitHub.
#     BLOCKED_HUMAN /    re-offer the park to bin/blocked-resolver.sh: a fresh
#     RED_TWICE          hand-off record (which drops the stale release marker)
#                        and the hand-off log line its recovery path reads. Only
#                        for a reason the resolver actually owns — re-handing
#                        `tightened` or `migration-gated` would hand it to a lane
#                        that has no rung for it.
#     NEEDS_HUMAN_VERDICT  nothing to kick (BH-3777): a lane cannot produce a
#                        human verdict, so the line names the reason, which
#                        carries the exact command a person runs.
#     QUEUED             on a Mergify repo, republish the `lead-verdict` status
#                        from the standing verdict when the head carries none
#                        (BH-4596, mc_vs_ttl_republish): a head that moved
#                        without passing through mc_enqueue_mergify has no
#                        status, and Mergify waits on it for good. Never over a
#                        failure, never without an approval bound to the head.
#                        Every other repo: no re-kick, as before.
#     READY              (BH-6000) a keyed conductor run for this PR now,
#                        ONCE per (PR, head), and only when the conductor has
#                        recorded no hold for this head (mc_ready_rekick). A
#                        READY row the conductor itself holds (main-red freeze,
#                        PR dependency, unread diff, base guard, budget: its
#                        ready-why note) is left alone, as BH-4596's review F1
#                        asked. The re-kick is a fresh run of the READY arm with
#                        every gate, never a republish ahead of them.
#   Everything else (HEAD_MOVED, STACKED_WAIT, WAIT_REVIEW) has no re-kick that
#   is not somebody else's decision, and says so.
#   Optional args 13-15 (BH-4596): <verdict> <reviewed> <provider>, read only by
#   the QUEUED arm; a caller that passes 12 gets the old answer there.
stuck_rekick() {
  local key="$1" st="$2" why="$3" slug="$4" num="$5" url="$6" head="$7" ms="$8" mg="$9"
  local baseref="${10}" pbase="${11}" ci="${12}"
  case "$st" in
    WAIT_CI)
      if [ "$ci" != none ]; then
        mc_log "$key stuck in WAIT_CI with CI $ci on ${head:0:8} — no re-kick: a close/reopen would cancel a running build, and a red head is the red ladder's"; return 0; fi
      # AN IDENTITY BLOCK IS NOT KICKABLE EITHER (BH-800). A BLOCKED row is
      # otherwise kickable — BLOCKED is not DIRTY and the base is the project's
      # — so without this the stuck detector would close and reopen a PR whose
      # only problem is that this token may not push to the branch.
      if [ "${MC_IDENTITY_BLOCKED:-0}" = 1 ]; then
        mc_log "$key stuck in WAIT_CI because this identity may not push to ${baseref:--} — a close/reopen cannot add a push permission; the ALERT is the action"; return 0; fi
      if [ "$mg" != MERGEABLE ] || [ "$ms" = DIRTY ] || [ -z "$pbase" ] || [ "$baseref" != "$pbase" ]; then
        mc_log "$key stuck in WAIT_CI but not kickable (mergeable=$mg mergeState=$ms base=${baseref:--}) — the alert is the action"; return 0; fi
      if mc_attempt_has "cikick $key $head" 2>/dev/null; then
        mc_log "$key stuck in WAIT_CI and ${head:0:8} has already had its one CI kick — nothing left to re-kick here"; return 0; fi
      if [ "$ACTIONS" != 1 ]; then
        mc_log "$key stuck in WAIT_CI — would kick CI on ${head:0:8} (observe mode: nothing written)"; return 0; fi
      if mc_kick_ci "$slug" "$num" "$head"; then
        mc_attempt_put "cikick $key $head"
        mc_log "$key stuck in WAIT_CI past its TTL — CI re-kicked (close/reopen) on ${head:0:8}"
      else
        mc_log "$key stuck in WAIT_CI past its TTL and the CI kick FAILED on ${head:0:8} — the alert stands"
      fi ;;
    NEEDS_REBASE|REBASING)
      mc_attempt_clear rebase "$key" "$head"
      mc_attempt_clear mergetree "$key" "$head"
      # The consumed-result markers go too (BH-523). Leaving `rebasedone` /
      # `rebasefailed` behind is how the forget failed to forget: the respawned
      # rebase finished, and rebase_consume answered "already read this head"
      # and dropped its result, on every tick, for ever.
      mc_attempt_clear rebasedone "$key" "$head"
      mc_attempt_clear rebasefailed "$key" "$head"
      # ...and the NO_REBASE said-once records with them (BH-764): the point of
      # clearing the attempt is that the next cycle may act again, and an exit
      # that stayed deduped would act in silence.
      mc_attempt_clear rebasenoop-consumed "$key" "$head"
      mc_attempt_clear rebasenoop-attempted "$key" "$head"
      mc_attempt_clear rbjob "$key" "$head done"
      rm -f "$(mc_rb_file "$slug" "$num" "$head")" 2>/dev/null
      mc_log "$key stuck in $st past its TTL — forgot this head's rebase attempt, its consumed-result markers and its detached job file; the next tick re-reads the merge state and may spawn a fresh rebase on ${head:0:8}" ;;
    BLOCKED_HUMAN|RED_TWICE)
      if mc_resolver_owns "$why"; then
        # IS THE LANE WE ARE HANDING TO ALREADY UNDERWATER (BH-1122)?
        # bin/blocked-resolver.sh writes state/blocked-resolver/.saturated on the
        # tick its SATURATED alert goes out and removes it on the first tick that
        # ends for any other reason. While it stands, a re-hand-off buys nothing:
        # the park is already in that lane's candidate list and the lane has more
        # parks than rungs, so rewriting the hand-off record only resets the one
        # timestamp anybody could have read the wait from. So the page this tick
        # already sent (mc_stuck_check, which carries the same pointer) is the
        # action instead. No flag and no new state: delete the marker and this is
        # byte-for-byte the previous behaviour.
        if mc_resolver_saturated "$key"; then
          mc_log "$key $(mc_state_display "$st" "$why") $why: still parked past its TTL on ${head:0:8} — bin/blocked-resolver.sh is SATURATED (see the [blocked-resolver] SATURATED line in logs/ALERTS.log); not re-handed off, its hand-off record stands: $url"
        else
          mc_handoff_record "$key" "$head" "$why" "$url"
          mc_log "$key $(mc_state_display "$st" "$why") $why: still parked past its TTL on ${head:0:8} — handed to bin/blocked-resolver.sh again (the release marker is cleared, so the park is offered fresh): $url"
        fi
      else
        mc_log "$key stuck in $st ($why) past its TTL — no lane owns this reason, so the alert is the action"
      fi ;;
    NEEDS_HUMAN_VERDICT)
      mc_log "$key stuck in NEEDS_HUMAN_VERDICT past its TTL — only a human verdict moves it: $why" ;;
    QUEUED)
      mc_vs_ttl_republish "$key" "$st" "$slug" "$num" "$url" "$head" "${13:-}" "${14:-}" "${15:-}" ;;
    READY)
      mc_ready_rekick "$key" "$slug" "$num" "$url" "$head" ;;
    *)
      mc_log "$key stuck in $st past its TTL — no deterministic re-kick for this state; the alert is the action" ;;
  esac
  return 0
}

# mc_ready_rekick <key> <slug> <num> <url> <head> — the READY arm of
#   stuck_rekick (BH-6000). #5982 sat in READY past its TTL with "no
#   deterministic re-kick for this state" on every tick. The STUCK page already
#   went out once (mc_stuck_check): this adds the move, once per (PR, head):
#     a recorded HOLD for this head, or one this tick already knows (a red
#       main, an unread diff) -> no re-kick: the conductor is holding it on
#       purpose, and a re-kick would only repeat that gate's answer (BH-4596
#       review F1). A hold is a ready-why note of a kind in the `holds` list,
#       or, with no note on this head, a MERGE_HELD / HELD-by log line
#       (mc_ready_why_last). A note of any other kind (prequeue-pending,
#       queue-held, gh-unread, state-moved, merge-lock, enqueue-failed,
#       merge-failed, worker-locked, lead-unread) only says what one tick did,
#       so the row is re-kicked (Fable review of 9fc9454d1, finding 1).
#     already re-kicked on this head (`readykick` attempt) -> nothing more
#     observe mode -> a WOULD line, nothing written
#     else -> stamp `readykick <key> <head>` FIRST, then launch the PR's own
#       keyed conductor run (kw_conductor: MC_ONLY_PR, its PR lock, setsid),
#       which runs the READY arm with all its gates and enqueues.
#   A launch the keyed wake refuses (off, deduped) is logged; the stamp stays,
#   so the re-kick is never repeated on the same head. Always rc 0.
mc_ready_rekick() {
  local key="$1" slug="$2" num="$3" url="$4" head="$5" held="" kind
  local holds=" main-red dep-hold dep-unread diff-unread ticket-hold lead-held block-gate block-gate-unread budget merges-off lead-unpinned "
  kind=$(mc_ready_why_kind "$key" "$head")
  if [ -z "$kind" ]; then held=$(mc_ready_why_last "$key" "$head")
  elif [[ "$holds" == *" $kind "* ]]; then held=$(mc_ready_why_last "$key" "$head"); held="${held:-$kind}"
  fi
  # The holds this tick already knows, before the READY arm writes its note:
  # stuck_rekick runs ahead of that arm in pr_worker, so on the first tick a
  # row is past its TTL the note may not exist yet. A red main and an unread
  # diff are both decided by then (MAIN_RED, DIFF_UNREAD in the worker's scope).
  [ -z "$held" ] && [ -n "${MAIN_RED:-}" ] && held="main is red (flags/${MAIN_RED})"
  [ -z "$held" ] && [ "${DIFF_UNREAD:-0}" = 1 ] && held="${DIFF_WHY:-the diff read was UNVERIFIABLE so the iron-law scan NOT run}"
  if [ -n "$held" ]; then
    mc_log "$key stuck in READY past its TTL on ${head:0:8} — the conductor holds it on purpose ($held); no re-kick, the alert is the action"; return 0; fi
  if mc_attempt_has "readykick $key $head" 2>/dev/null; then
    mc_log "$key stuck in READY past its TTL and ${head:0:8} has already had its one re-kick — the alert is the action"; return 0; fi
  if [ "${ACTIONS:-0}" != 1 ]; then
    mc_log "$key stuck in READY past its TTL — would re-kick a keyed conductor run on ${head:0:8} (observe mode: nothing written)"; return 0; fi
  mc_attempt_put "readykick $key $head"
  command -v kw_conductor >/dev/null 2>&1 || . "$MC_H/bin/lib/keyed-wake.sh" 2>/dev/null
  # THE LAUNCHER HOLDS THIS PR'S LOCK (lead review lr-6015): this runs inside
  # pr_worker, which keeps fd 9 until it exits, so the keyed run would lose
  # the `flock -n` race and skip, and this once-per-head re-kick would be gone.
  # The run waits for the lock instead, up to this worker's own deadline (the
  # longest the launcher can still hold it).
  local kwait="${MC_WORKER_DEADLINE_S:-180}"; case "$kwait" in ''|*[!0-9]*|0) kwait=180 ;; esac
  if command -v kw_conductor >/dev/null 2>&1 && KW_PR_LOCK_WAIT_S="$kwait" kw_conductor "$slug" "$num" "READY past its TTL on ${head:0:8}"; then
    mc_log "$key stuck in READY past its TTL — re-kicked once: a keyed conductor run for ${head:0:8} started now (it runs the READY arm with every gate and enqueues): $url"
  else
    mc_log "$key stuck in READY past its TTL — the re-kick could not launch a keyed run (keyed wake off or deduped); recorded once for ${head:0:8}, the next tick's READY arm is the retry: $url"
  fi
  return 0
}

# mc_vs_ttl_republish <key> <state> <slug> <num> <url> <head> <verdict> <reviewed> <provider>
#   The QUEUED arm of stuck_rekick (BH-4596); never READY, see stuck_rekick.
#   The generic backstop under every path that moves a Mergify head without publishing `lead-verdict` on
#   it: the rebind arms publish themselves (mc_rebind_publish), and this is for
#   whatever strands anyway. It POSTs success at most once per (PR, head)
#   (`vsttl` attempt line, written BEFORE the POST), and only when:
#     the repo is on Mergify (anything else: the old "no re-kick" line, verbatim);
#     the standing verdict is APPROVE and bound to this head (reviewed == head,
#       which includes the BH-3778 lead MERGE mc_lead_ready folds in);
#     the head's lead-verdict is absent or pending (mc_vs_state_on): success
#       means the hold is something else, failure/error is a lead or human
#       BLOCK and is never overwritten, an unread status POSTs nothing;
#     actions and merges are on, and mc_la_decide answers rc 0.
#   With an approval bound to the head and actions and merges on, it also calls
#   pq_status_ensure (BH-5441) first, whatever the lead-verdict state: a missing
#   prequeue-verdict is a hold this arm can see too.
#   The STUCK page already went out; this only adds the move. Always rc 0.
mc_vs_ttl_republish() {
  local key="$1" st="$2" slug="$3" num="$4" url="$5" head="$6" verdict="${7:-}" reviewed="${8:-}" provider="${9:-}"
  local vst lac=0 err
  if [ "$provider" != mergify ] || ! command -v vs_publish >/dev/null 2>&1; then
    mc_log "$key stuck in $st past its TTL — no deterministic re-kick for this state; the alert is the action"; return 0; fi
  if [ "$verdict" != APPROVE ] || [ -z "$head" ] || [ "$reviewed" != "$head" ]; then
    mc_log "$key stuck in $st past its TTL — no approval is bound to ${head:0:8}, so no lead-verdict is republished; the alert is the action"; return 0; fi
  [ "${ACTIONS:-0}" = 1 ] && [ "${MERGES:-0}" = 1 ] && command -v pq_status_ensure >/dev/null 2>&1 \
    && pq_status_ensure "$slug" "$head" "$url" "QUEUED past its $st TTL"
  if ! vst=$(mc_vs_state_on "$slug" "$head"); then
    mc_log "$key stuck in $st past its TTL — the lead-verdict status on ${head:0:8} could not be read; nothing republished, the alert is the action"; return 0; fi
  case "$vst" in
    success)
      mc_log "$key stuck in $st past its TTL — lead-verdict is already success on ${head:0:8}, so the hold is something else; the alert is the action"; return 0 ;;
    failure|error)
      mc_log "$key stuck in $st past its TTL — lead-verdict is $vst on ${head:0:8}: a lead or human BLOCK is never overwritten; the alert is the action"; return 0 ;;
  esac
  if mc_attempt_has "vsttl $key $head" 2>/dev/null; then
    mc_log "$key stuck in $st past its TTL — lead-verdict was already republished once on ${head:0:8} and is still $vst; the alert is the action"; return 0; fi
  if [ "${ACTIONS:-0}" != 1 ] || [ "${MERGES:-0}" != 1 ]; then
    mc_log "$key stuck in $st past its TTL — WOULD republish lead-verdict=success on ${head:0:8} (it is $vst); merges are off this tick"; return 0; fi
  if command -v mc_la_decide >/dev/null 2>&1; then
    mc_la_decide "$slug" "$num" "$head" || lac=$?
  fi
  case "$lac" in
    0) ;;
    1) mc_log "$key stuck in $st past its TTL — lead-verdict withheld on ${head:0:8} (${LA_REASON:-no reason given}); the NEEDS_HUMAN_VERDICT gate owns it"; return 0 ;;
    *) mc_log "$key stuck in $st past its TTL — the lead authority could not be decided (${LA_REASON:-no reason given}); nothing republished"; return 0 ;;
  esac
  mc_attempt_put "vsttl $key $head"
  if err=$(vs_publish "$slug" "$head" success "harness verdict on ${head:0:12} republished at the $st TTL" "$url" 2>&1 >/dev/null); then
    mc_log "$key VS_REPUBLISHED $head lead-verdict=success at the $st TTL (it was $vst)"
  else
    mc_log "$key stuck in $st past its TTL — the lead-verdict republish on ${head:0:8} FAILED ($(head -1 <<<"${err:-vs_publish failed}")); not retried, the alert stands"
  fi
  return 0
}
