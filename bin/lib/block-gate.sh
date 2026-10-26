#!/bin/bash
# gh-identity: raw-by-design — its reads run INSIDE a lane that has ALREADY armed the identity that can see this repo (the conductor's, the box queue's, the tier-2 sweep's admin-PAT fallback). Minting a second token here would override that fallback and answer "cannot judge" on exactly the repos #251 was about.
# bin/lib/block-gate.sh — BH-762: a human BLOCK gates EVERY merge path.
# Sourced by bin/lib/merge-conductor-lib.sh (so every lane that has the
# conductor lib has the gate); never executed. Contract: docs/MERGE-CONDUCTOR.md
# section 17.
#
# THE INCIDENT. A review landed BLOCK at 18:47Z and the conductor squash-merged
# the same two commits at 18:55Z, because nothing between "READY" and
# `gh pr merge` had ever read a comment. The ledger's APPROVE was true when it
# was written; the thread had moved since. THREAD RECENCY IS LAW governs the
# build side already, and this is the merge side of the same law.
#
# THE RULE, made mechanical. Walk the PR conversation, the PR's review bodies
# and (on an Issues-board project) the ticket thread in time order. A comment
# BLOCKS when a line of it matches the BLOCK marker, its time is strictly NEWER
# than the head's, and no LATER comment by the SAME login matches the CLEAR
# marker. A comment that matches both markers is read as a clear.
#
# TWO DATES, AND WHY THE AUTHOR DATE. The head's time is the newest authoredDate
# across the PR's commits, never committedDate: the conductor's own mechanical
# rebase rewrites committer dates, and "rebased, then merged 8 minutes after the
# BLOCK" is exactly how the incident happened. Author dates survive a rebase, so
# a real r2 clears its own block and a rebase does not. It is bought ONLY when a
# BLOCK marker was found, so the happy path costs nothing extra.
# All times are GitHub's ISO-8601 Z strings and are compared as such.
#
# THE IDENTITY IS THE LANE'S. Every gh call below runs on whatever token the
# calling lane armed for this repo before it called in here — the per-repo App
# token on the conductor and the box queue, the admin PAT the tier-2 sweep falls
# back to for a repo the default token cannot see. This file deliberately mints
# none of its own: a second mint here would override that fallback and answer
# "cannot judge" on exactly the repos it exists for. That is the reason on the
# `# gh-identity: raw-by-design` line at the top of this file, which is where
# tests/gh-app-ratchet-test.sh reads it since BH-1177.

# The markers are case-sensitive and anchored at the start of a line, after
# markdown noise (`#`, `*`, `_`, backtick, space) only. `>` is deliberately NOT
# in that class: a QUOTED block is somebody repeating a block, not posting one.
BG_BLOCK_RE='^[[:space:]#*_`]*((VERDICT|Verdict|verdict)[[:space:]]*:[[:space:]]*)?[*_`]*BLOCK[*_`]*([^A-Za-z0-9_-]|$)'
# A BARE approve is deliberately NOT a clear: `LGTM`, `APPROVED`, or the word
# APPROVE on its own is somebody being agreeable, not somebody retracting a
# finding, and the harness's own reviewers post under a PAT whose login can be
# the human blocker's own.
BG_CLEAR_RE='^[[:space:]#*_`]*[*_`]*(UNBLOCKED|UNBLOCK|CLEARED|BLOCK[[:space:]:-]+CLEARED)[*_`]*([^A-Za-z0-9_-]|$)'
# …but a TERMINAL VERDICT LINE from the same author is (BH-1131). PR #728 sat
# 7h40m with CI green because the review autopilot BLOCKed a head at 04:33Z and
# then, at 07:51Z, re-adjudicated the SAME head down to PLAUSIBLE and ended
# `VERDICT: APPROVE` — the strongest possible retraction, from the only author
# who could make it, and the gate ignored it because the autopilot never writes
# the word UNBLOCK. That head could then only be freed by pushing a commit,
# which buys another review: a deadlock the pipeline enters on its own with no
# human in the loop.
#
# THE `VERDICT:` PREFIX IS NOT THE WHOLE SAFETY MARGIN — it is one of three,
# and on its own it is not enough (r1 review of PR #1153). It says the line is
# the review lane's machine vocabulary (bin/review-autopilot.sh:163 writes
# exactly one of MERGE | MERGE-WITH-NOTES | BLOCK; bin/run-build.sh's reviewers
# write APPROVE or BLOCK) rather than prose, so a bare APPROVE, an APPROVED or
# an LGTM still clears nothing. What it does NOT say is WHO wrote it or WHICH
# head they judged, and both of those are load-bearing:
#
#   THE AUTHOR MUST BE A MACHINE (bg_bot_login). bin/review-prs.sh ends its
#   review body with `VERDICT: APPROVE` and posts it through whatever token the
#   lane armed — `gh_default_auth_for_project … || true` falls back to the fleet
#   PAT, whose login is `operator`, the same login the operator's own comments carry, and
#   every machine APPROVE on the OS repos today is authored by it (project-3 #355,
#   project-1 #691, project-2 #525/#526). Scoped by login alone this arm
#   would therefore let the review lane clear a PERSON's BLOCK minutes after it
#   was posted — the very thing the vocabulary rule was there to prevent. A
#   machine login cannot be worn by a person (GitHub refuses `[` and `]` in a
#   user name), so requiring one leaves every human BLOCK exactly where it was:
#   the drop is per login, and a person has no machine twin.
#
#   AND IT MUST NAME THIS HEAD (bg_headbound). A verdict is a fact about ONE
#   sha — the same rule the conductor's own head-bound review and
#   mc_autopilot_verdict obey — so a bot comment that merely ends in the
#   vocabulary, or one bound to a head that has since moved, clears nothing.
#   Every lane that posts a terminal verdict writes the head into its own
#   footer: `<!-- harness-review-autopilot <head12> -->` (review-autopilot),
#   `… re-review (Fable) of <sha>: APPROVE` (merge-conductor.sh:805),
#   `Automated harness review (Fable) of <sha>` (review-prs.sh). The SHA is
#   matched, not those three sentences: a footer's wording changing must not
#   quietly bring the deadlock back.
#
# AND IT ONLY EVER CLEARS ITS OWN AUTHOR'S BLOCK, in bg_scan, in time order —
# the same rule UNBLOCK obeys. A different login's approve clears nothing, and
# a later `VERDICT: BLOCK` re-blocks, because the newest verdict wins.
# BH-4468 is the one exception, and only for a MACHINE's block: a lead/human
# MERGE or MERGE-WITH-NOTES verdict ROW standing on the live head lifts it
# (bg_bot_lift). A person's block is never lifted that way.
# MERGE-WITH-NOTES is first in the alternation for the reader's sake; the
# trailing class already refuses to match `MERGE` inside `MERGE-WITH-NOTES`.
BG_APPROVE_RE='^[[:space:]#*_`]*(VERDICT|Verdict|verdict)[[:space:]]*:[[:space:]]*[*_`]*(APPROVE|MERGE-WITH-NOTES|MERGE)[*_`]*([^A-Za-z0-9_-]|$)'

# BH-1525: the verdicts table's reader. A lead/human BLOCK row standing on the
# head is a block this gate enforces on every lane that calls it; see
# bin/lib/verdicts.sh for the binding and the fail-open rule.
command -v vd_block_line >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/verdicts.sh" ] && . "${BASH_SOURCE[0]%/*}/verdicts.sh"; }

# bg_home — the harness root, read at CALL time: a lane that sets HARNESS after
# sourcing the lib (every fixture does) must still write to its own tree.
bg_home() { printf '%s' "${HARNESS:-${MC_H:-/root/harness}}"; }

# bg_enforce — rc 0 when a block REFUSES the merge, rc 1 when it only warns.
# BLOCK_GATE_ENFORCE lives in env/global.env and defaults to on; 0 is the
# rollback switch, the same shape HEADBOUND_ENFORCE has.
bg_enforce() { [ "${BLOCK_GATE_ENFORCE:-1}" = 1 ]; }

# THE BODY IS HANDED TO grep AS A HERE-STRING, NEVER DOWN A LIVE PIPE (BH-1290).
# These read `printf '%s\n' "$1" | tr -d '\r' | grep -qE …` until 2026-09-22.
# `grep -q` exits the moment it matches, which for a marker on line 1 is after
# the first read; `tr` then writes into a closed pipe and dies of SIGPIPE (141)
# or, where the signal is ignored, takes EPIPE and exits 1. Every production
# caller runs `set -o pipefail` — merge-conductor.sh, blocked-resolver.sh,
# review-autopilot.sh — so the pipeline's answer became the writer's, and the
# predicate said NO MARKER. For bg_marker_block that is FAIL-OPEN: a real BLOCK
# on a long comment read as absent and the merge proceeded, which is the one way
# this file must never be wrong. Measured here at 0/200 on a 4.7 KB body but
# 20/20 at 256 KB and above; CI shard log 106428451073 caught it live as
# `tr: write error: Broken pipe` followed by `FAIL: D: without the APPROVE the
# real BLOCK must still gate (rc=0 out=)`.
# A here-string leaves no writer to break, and `${b//$'\r'/}` strips every CR
# exactly as `tr -d '\r'` did. The regexes are untouched: only the transport
# from body to grep changed.
bg_marker_block() { local b="${1:-}"; grep -qE "$BG_BLOCK_RE" <<<"${b//$'\r'/}"; }
bg_marker_clear() { local b="${1:-}"; grep -qE "$BG_CLEAR_RE" <<<"${b//$'\r'/}"; }
# bg_marker_approve — a TERMINAL VERDICT line. Read by bg_scan only, and only
# for the author's own pending block; it is not part of BG_CLEAR_RE, so
# `bg_marker_clear "VERDICT: APPROVE"` is still false and nothing that consults
# the clear vocabulary alone changed meaning.
bg_marker_approve() { local b="${1:-}"; grep -qE "$BG_APPROVE_RE" <<<"${b//$'\r'/}"; }

# bg_bot_login <login> — rc 0 when the login is a MACHINE account: a GitHub App
# (`<name>[bot]`, the spelling REST and the UI use) or the `app/<name>` spelling
# the GraphQL/ledger paths hand over. GitHub does not allow `[`, `]` or `/` in a
# user name, so neither spelling can belong to a person — which is what makes
# this a credential and not a naming convention. Normalised the same way
# bin/lib/gh-pr-list.sh:180-182 normalises the three spellings.
bg_bot_login() {
  case "${1:-}" in
    app/?*)   return 0 ;;
    ?*'[bot]') return 0 ;;
    *)        return 1 ;;
  esac
}

# bg_headbound <body> <head> — rc 0 when the body NAMES this head, i.e. carries
# the head's sha (the first 12 characters of it, the shortest prefix any harness
# lane writes). Case-folded, because a footer may carry it either way.
#
# FAIL CLOSED ON ANYTHING THAT IS NOT A SHA. An empty head — a caller that could
# not read one — would make `*""*` match every body and dissolve the binding
# silently, which is the single worst way for this file to be wrong. A head that
# is too short to identify a commit, or not hex at all, is the same class.
bg_headbound() {
  local body="${1:-}" h
  h=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z'); h="${h:0:12}"
  [ "${#h}" -ge 7 ] || return 1
  case "$h" in *[!0-9a-f]*) return 1 ;; esac
  # Here-string, not `printf | tr | grep -q`, for the reason at bg_marker_block:
  # a short-circuiting grep on the right of a live writer answers "no" under
  # pipefail (BH-1290). Here the wrong answer is the DEADLOCK direction — a
  # machine's own head-bound APPROVE stops clearing its own BLOCK, which is
  # #728's 7h40m hold. `-i` on an already-lower-cased hex needle is the same
  # predicate as lower-casing the body was.
  grep -qiF -- "$h" <<<"$body"
}

# bg_verdict_clears <body> <login> <head> — rc 0 when this comment retracts its
# OWN author's block on THIS head. The whole rule in one seam, so bg_scan_read
# (and any lane that ever has to ask the same question) cannot hold three
# conditions and forget one:
#   1. it carries a terminal verdict line — the machine vocabulary, not prose;
#   2. it does NOT also carry a BLOCK marker — a re-review that still names a
#      finding blocks whatever its last line says, the fail-closed reading;
#   3. its author is a machine account — a person's block has no machine twin,
#      so no machine verdict can drop it (the drop in bg_pend_drop is by login);
#   4. it names this head — a verdict is a fact about one sha.
bg_verdict_clears() {
  local body="${1:-}" login="${2:-}" head="${3:-}"
  bg_marker_approve "$body" || return 1
  bg_marker_block   "$body" && return 1
  bg_bot_login  "$login" || return 1
  bg_headbound  "$body" "$head"
}

# bg_newer <a> <b> — rc 0 when ISO timestamp <a> is strictly newer than <b>.
# Compared digits-only so no locale's collation rules can reorder two stamps.
bg_newer() {
  local a="${1//[^0-9]/}" b="${2//[^0-9]/}"
  [ "${#a}" = "${#b}" ] || { a="${1:-}"; b="${2:-}"; }
  [ "$a" \> "$b" ]
}

# bg_read <api-path> <time-field> [no-such-thread-is-empty] — one source,
# normalised to one TSV line per comment: id, time, login, html_url,
# body@base64. rc 1 = the read FAILED (gh exited nonzero, or answered something
# that is not that shape). An rc-0 read that prints NOTHING is an empty thread,
# which is what `.[]` prints for `[]`.
#
# THE ROWS COME OUT UNIT-SEPARATED, NOT TAB-SEPARATED. `IFS=$'\t' read` would
# COLLAPSE two tabs in a row, because tab is IFS whitespace: a comment with an
# empty html_url would shift its base64 body into the url field and read as a
# body of nothing — a BLOCK missed in silence, which is the one way of being
# wrong this file exists to prevent. \x1f is not IFS whitespace, so an empty
# field stays an empty field. `@tsv` writes any real tab inside a value as the
# two characters `\t`, so the only tabs left to translate are the separators.
# html_url also falls back to "-" for the human reading the answer; bg_scan
# turns that back into the PR's own url.
#
# THE THIRD ARGUMENT IS FOR THE TICKET THREAD ONLY. A 404 there means "no such
# thread" — the issue number was derived from a branch name and there is no
# issue behind it — and an empty thread is the honest answer, not "cannot
# judge"; without this a harness PR on an Issues-board repo whose branch merely
# LOOKS like it carries a number would refuse its merge on every tick for ever.
# Every other read stays fail-closed: a 404 on the PR's OWN comments means the
# token cannot see the repo, which is precisely when not to merge.
bg_read() {
  local path="$1" tf="$2" soft="${3:-}" out rc errf
  errf="${TMPDIR:-/tmp}/bg-read.$$.$RANDOM"
  out=$(gh api "$path" --paginate \
        -q ".[] | select(.$tf != null) | [(.id|tostring), .$tf, (.user.login // \"-\"), (if (.html_url // \"\") == \"\" then \"-\" else .html_url end), (.body // \"\" | @base64)] | @tsv" 2>"$errf"); rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$soft" = no-thread-is-empty ] && grep -qE 'HTTP 404|Not Found' "$errf" 2>/dev/null; then
      rm -f "$errf"; return 0
    fi
    rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  [ -z "$out" ] || awk -F'\t' 'NF!=5{exit 1}' <<<"$out" || return 1
  printf '%s' "$out" | tr '\t' '\037'
}

# bg_head_time <slug> <num> — the newest commit AUTHOR date across the PR's
# commits, read over REST. rc 1 = the read failed, which bg_scan turns into
# rc 2 `head-time`, which is a refusal.
#
# IT USED TO BE THE CLI's `--json commits` READ, WHICH IS GRAPHQL. The token's
# GraphQL budget is capped and invisible in `rate_limit`, so when it ran out
# this read failed and the gate went blind: 81 identical "block gate could not
# read head-time — nothing written, the next tick tries again" lines in one
# day's logs/merge-conductor.log, on PRs that were otherwise mergeable, and not
# one alert (BH-1131). rc 2 was the right answer to a failed read; using
# GraphQL for it at all was the bug. `repos/<slug>/pulls/<num>/commits` is the
# REST equivalent and was verified to give the identical answer on PR #728
# (2026-09-20T04:11:16Z from both).
#
# THE MAX IS TAKEN IN THE SHELL, NOT IN jq. `gh api --paginate -q` runs the jq
# program ONCE PER PAGE, so `[.[]…] | max` prints one line per page and a PR
# with more than 100 commits would answer two maxima; the newest is then
# whichever page came last, not the newest. Printing every date and sorting is
# the same answer on one page and the right one on five. ISO-8601 Z strings
# sort lexicographically in the order they sort chronologically, and LC_ALL=C
# keeps a locale's collation out of it.
#
# AN ANSWER THAT IS NOT A DATE IS A FAILED READ, never a time. A rate-limited
# gh has answered an EMPTY STRING before (#768) and a decision path read that
# silence as fact; the shape check below is why this one cannot.
bg_head_time() {
  local slug="$1" num="$2" t
  t=$(gh api "repos/$slug/pulls/$num/commits?per_page=100" --paginate \
        -q '.[] | .commit.author.date // empty' 2>/dev/null) || return 1
  [ -n "$t" ] || return 1
  t=$(LC_ALL=C sort <<<"$t" | tail -1)
  case "$t" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$t"
}

# ── A STANDING CHANGES_REQUESTED IS A BLOCK (BH-2199) ────────────────────────
# THE INCIDENTS. #2158 merged at 20:39Z on 2026-09-24 over the lead's
# CHANGES_REQUESTED: the review said `## BLOCKING`, which BG_BLOCK_RE does not
# read as a marker, and the only commits after it were `Merge origin/main`,
# whose AUTHOR dates are newer than the review, so the text walk above would
# have read even a real marker as "fixed since". #2196 merged at the very head
# the review named. Both were readable in one field the gate never looked at:
# the review's STATE. So the state is read here, by itself, and stands on its
# own — no marker, no author-date race.
#
# WHOSE REVIEW. A person with write access: `user.type` is not Bot, the login is
# not an App login (bg_bot_login), and `author_association` is OWNER, MEMBER or
# COLLABORATOR — it rides on the same read. Any OTHER association is asked once
# more (bg_reviewer_can_write): GitHub reports a PRIVATE org member as
# CONTRIBUTOR to a token that cannot see the membership (an App installation
# token can be one), and reading that as "no write access" would drop the
# lead's own block. NOT the harness review lane's machine
# review, which posts under the fleet PAT's human login with the
# `Automated harness review (` footer and dismisses its own CHANGES_REQUESTED
# itself (bin/review-prs.sh rp_dismiss_own) — its verdict has a consumer.
#
# STANDING. The reviewer's LATEST review, in submitted_at order, that is
# APPROVED / CHANGES_REQUESTED / DISMISSED is CHANGES_REQUESTED (COMMENTED does
# not change a reviewer's standing state on GitHub either). Lifted by:
#   * a later PR comment by the SAME login carrying a line-anchored RESUME,
#     MERGE, MERGE-WITH-NOTES, UNBLOCK or CLEARED;
#   * a lead/human MERGE or MERGE-WITH-NOTES verdict row on the live head
#     (vd_clears);
#   * a head that changed the PR's OWN diff since the reviewed commit.
#
# THE PR'S OWN DIFF, not `git diff <blocked> <head>`: a head that only merged
# main differs from the blocked one by everything main did, and none of it is a
# fix. `compare/<base>...<sha>` is three-dot, i.e. diffed from the merge-base
# with the base branch, which is exactly the PR's own change at that head. Two
# heads carry the same change when every file's (name, status, +/- lines) match
# — context lines and hunk offsets are left out, because a main merge moves
# them. A compare that cannot be read, is truncated (GitHub stops at 300 files)
# or omits a file's patch cannot tell, and the block STANDS: the reviewer
# clears it with a review or a word, and nothing merges on a guess.

BG_RESUME_RE='^[[:space:]#*_`]*[*_`]*(RESUME|MERGE-WITH-NOTES|MERGE)[*_`]*([^A-Za-z0-9_-]|$)'
bg_marker_resume() { local b="${1:-}"; grep -qE "$BG_RESUME_RE" <<<"${b//$'\r'/}"; }

# bg_own_diff_fp <slug> <base> <sha> — the PR's own diff at <sha>, fingerprinted.
#   rc 0 + the fingerprint; rc 1 when it cannot be told (unreadable, truncated,
#   a file with changes but no patch).
bg_own_diff_fp() {
  local fp
  fp=$(gh api -X GET "repos/$1/compare/$2...$3" -q '
    if (.files | type) != "array" then "UNKNOWN"
    elif (.files | length) >= 300 then "UNKNOWN"
    else (.files | sort_by(.filename) | map(
      if .patch == null then
        (if (.changes // 0) > 0 then "UNKNOWN" else "\(.filename)\t\(.status)\t\(.sha // "-")" end)
      else "\(.filename)\t\(.status)\n" + (.patch | split("\n") | map(select(test("^[-+]"))) | join("\n")) end)
      | join("\n\u001e\n")) end' 2>/dev/null) || return 1
  grep -qx 'UNKNOWN' <<<"$fp" && return 1
  printf '%s' "$fp"
}

# bg_reviewer_can_write <slug> <login> — rc 0 when the login has write (or
#   maintain/admin) on the repo, per the collaborator-permission read. A read
#   that fails answers rc 0: whether a reviewer who left CHANGES_REQUESTED may
#   block cannot be told, and the fail-closed answer is that they may.
#   BH-8457: with BG_PERM_MEMO_DIR set (the conductor sets it to a dir of this
#   tick), a read permission word is kept in <dir>/<slug>.<login>, so one tick
#   reads each (repo, login) once. A failed or empty read is never stored.
bg_reviewer_can_write() {
  local p f=""
  if [ -n "${BG_PERM_MEMO_DIR:-}" ]; then
    f="$BG_PERM_MEMO_DIR/$(printf '%s.%s' "${1//\//_}" "$2" | tr -cd 'A-Za-z0-9._-')"
    [ -s "$f" ] && p=$(head -c 32 "$f" 2>/dev/null)
  fi
  if [ -z "${p:-}" ]; then
    p=$(gh api -X GET "repos/$1/collaborators/$2/permission" -q '.permission // empty' 2>/dev/null) || return 0
    [ -n "$f" ] && [ -n "$p" ] && mkdir -p "$BG_PERM_MEMO_DIR" 2>/dev/null \
      && printf '%s' "$p" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
    [ -n "$f" ] && rm -f "$f.$$" 2>/dev/null
  fi
  case "$p" in admin|maintain|write) return 0 ;; '') return 0 ;; *) return 1 ;; esac
}

# bg_cr_standing <slug> <num> <pr-url> <head-sha> <pr-comments>
#   <pr-comments> is bg_read's answer for the PR conversation (the thread
#   bg_scan_read already read), so the RESUME/MERGE clear costs no call.
#   rc 0  a CR stands; stdout is ONE scan line, bg_scan_read's shape:
#         <review-url>\t<login>\t<submitted_at>\tcr-<review-id>@<commit12>
#   rc 1  none stands
#   rc 2  the reviews could not be read — never rc 1: a lane that cannot see
#         the reviews does not merge this tick.
bg_cr_standing() {
  local slug="$1" num="$2" url="$3" head="$4" comments="${5:-}"
  local rows cands US=$'\037' NL=$'\n' base="" hfp="" bfp
  local id at login commit rurl cid cat clogin curl cb64 cleared
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  rows=$(gh api -X GET "repos/$slug/pulls/$num/reviews?per_page=100" --paginate -q '.[] | [
      (.id|tostring), (.submitted_at // "-"), (.user.login // "-"), (.user.type // "-"),
      (.author_association // "-"), (.state // "-"), ((.commit_id // "-") | ascii_downcase),
      (if (.html_url // "") == "" then "-" else .html_url end),
      (if ((.body // "") | contains("Automated harness review (")) then "1" else "0" end)
    ] | @tsv' 2>/dev/null) || return 2
  [ -n "$rows" ] || return 1
  awk -F'\t' 'NF!=9{exit 1}' <<<"$rows" || return 2
  # The latest standing-relevant review per eligible login, then only the CRs.
  cands=$(LC_ALL=C sort -s -t$'\t' -k2,2 <<<"$rows" | awk -F'\t' '
    $6 !~ /^(APPROVED|CHANGES_REQUESTED|DISMISSED)$/ { next }
    $4 == "Bot" || $3 ~ /\[bot\]$/ || $3 ~ /^app\// || $3 == "-" { next }
    $9 == "1" { next }
    { last[$3] = $0 }
    END { for (l in last) { split(last[l], f, "\t"); if (f[6] == "CHANGES_REQUESTED") print last[l] } }' \
    | LC_ALL=C sort -t$'\t' -k2,2r)
  [ -n "$cands" ] || return 1
  while IFS=$'\t' read -r id at login _ assoc _ commit rurl _; do
    [ -n "$id" ] || continue
    case "$assoc" in
      OWNER|MEMBER|COLLABORATOR) ;;
      *) bg_reviewer_can_write "$slug" "$login" || continue ;;
    esac
    case "$rurl" in ''|-) rurl="$url" ;; esac
    # The reviewer's own later word.
    cleared=0
    if [ -n "$comments" ]; then
      while IFS="$US" read -r cid cat clogin curl cb64; do
        [ "$clogin" = "$login" ] || continue
        bg_newer "$cat" "$at" || continue
        cb64=$(printf '%s' "$cb64" | base64 -d 2>/dev/null)
        if bg_marker_resume "$cb64" || bg_marker_clear "$cb64"; then cleared=1; break; fi
      done <<<"$comments"
    fi
    [ "$cleared" = 1 ] && continue
    command -v vd_clears >/dev/null 2>&1 && vd_clears "$slug" "$num" "$head" && continue
    # On which head: the live one, or one whose own diff this head still carries.
    if [ "$commit" != "$head" ]; then
      if [ -z "$base" ]; then
        base=$(gh api -X GET "repos/$slug/pulls/$num" -q '.base.ref // empty' 2>/dev/null) || base=""
      fi
      if [ -n "$base" ] && bfp=$(bg_own_diff_fp "$slug" "$base" "$commit"); then
        [ -n "$hfp" ] || hfp=$(bg_own_diff_fp "$slug" "$base" "$head") || hfp="${NL}unknown"
        # A head whose own diff differs is a new change: the CR no longer stands.
        [ "$hfp" = "${NL}unknown" ] || [ "$hfp" = "$bfp" ] || continue
      fi
    fi
    printf '%s\t%s\t%s\tcr-%s@%s' "$rurl" "$login" "$at" "$id" "${commit:0:12}"
    return 0
  done <<<"$cands"
  return 1
}

# bg_ci_cleared_ids <slug> <num> <head> — BH-3934: the block ids that a CI
#   clear names on exactly this head. bin/lib/mc/block-ci.sh writes the ledger
#   row block_ci_clear "<slug>#<num>@<head>" cleared "<run-id> <id> [<id>…]"
#   only after every job of every latest run on that head concluded success.
#   rc 0 prints the ids (fields 2..n) when the row's status is exactly cleared;
#   rc 1 prints nothing: no full head, no jobs client, no row, an outage, an
#   unparseable row. rc 1 never changes a scan's answer, it lifts nothing.
bg_ci_cleared_ids() {
  local slug="${1:-}" num="${2:-}" head="${3:-}" row ids=""
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [ -n "$slug" ] && [ -n "$num" ] || return 1
  command -v job_ledger_row >/dev/null 2>&1 || return 1
  row=$(job_ledger_row block_ci_clear "$slug#$num@$head" 2>/dev/null) || return 1
  [ "$(jq -r '.status // ""' <<<"$row" 2>/dev/null)" = cleared ] || return 1
  read -r _ ids <<<"$(jq -r '.detail // ""' <<<"$row" 2>/dev/null)"
  [ -n "$ids" ] || return 1
  printf '%s' "$ids"
}

# bg_scan <slug> <num> <pr-url> <head-sha> [<issue-num>]
#   rc 0  no unresolved BLOCK — the merge may proceed
#   rc 1  BLOCKED; stdout is ONE line for the newest unresolved block:
#         <comment-html-url>\t<login>\t<created_at>\t<comment-id>
#   rc 2  cannot judge; stdout names the read that failed (comments | reviews |
#         issue-comments | head-time). NEVER map rc 2 to rc 0: a lane that
#         cannot read the thread does not merge this tick.
#   <issue-num> is read only on Issues-board projects (fleet.conf board prefix
#   "-"); the callers decide that, the gate just reads what it is handed, and an
#   issue number equal to the PR number is the same thread, already read.
#   <head-sha> is what a terminal-verdict clear is BOUND to (bg_verdict_clears);
#   the head's TIME still comes from the PR's commits, and bg_refuse keys on the
#   same sha. A caller that hands over an empty or non-sha head loses only the
#   verdict clear, which then fails closed — nothing else in the walk needs it.
#
#   bg_scan is the WRAPPER below; this is the read itself. Every lane calls
#   bg_scan, so the streak counter cannot be forgotten by a new call site.
bg_scan_read() {
  local slug="$1" num="$2" url="$3" head="$4" issue="${5:-}"
  local c r i all ht id at login lurl b64 body newest="" anyblock=0
  # The still-standing blockers, one "<login> <url> <time> <id>" line each. A
  # plain string and not an associative array on purpose: an EMPTY associative
  # array is an unbound variable under `set -u` (bash 5.2 still), and every lane
  # that calls this runs with -u.
  # US is the separator bg_read hands over (see there: a tab-split collapses an
  # empty field away and can swallow a BLOCK); TAB is what the ANSWER line uses,
  # and every field of that line is non-empty, so it splits back safely.
  local pend="" US=$'\037' TAB=$'\t' NL=$'\n'
  # BH-1525: a lead/human BLOCK ROW on this head refuses first — no thread read
  # is needed to know it, and no later comment can lift it (a newer MERGE row
  # on the same head, or a push, does). An UNREADABLE table is "could not read
  # verdicts" (rc 2): the lane skips this tick's merge and asks again next tick.
  # BH-3934: a row whose id a block_ci_clear on this head names (CI-only, CI
  # green on exactly this head) is lifted, and the thread is read as usual.
  local vline vrc=0 cids="" cread=0
  if command -v vd_block_line >/dev/null 2>&1; then
    vline=$(vd_block_line "$slug" "$num" "$url" "$head") || vrc=$?
    case $vrc in
      0) cids=$(bg_ci_cleared_ids "$slug" "$num" "$head") || cids=""; cread=1
         case " $cids " in
           *" ${vline##*$'\t'} "*) ;;
           *) printf '%s' "$vline"; return 1 ;;
         esac ;;
      2) printf 'verdicts'; return 2 ;;
    esac
  fi
  c=$(bg_read "repos/$slug/issues/$num/comments" created_at)  || { printf 'comments'; return 2; }
  r=$(bg_read "repos/$slug/pulls/$num/reviews" submitted_at)  || { printf 'reviews'; return 2; }
  i=""
  if [ -n "$issue" ] && [ "$issue" != "$num" ]; then
    i=$(bg_read "repos/$slug/issues/$issue/comments" created_at no-thread-is-empty) \
      || { printf 'issue-comments'; return 2; }
  fi
  # BH-2199: a standing lead/human CHANGES_REQUESTED refuses on its STATE, with
  # no marker and no author-date comparison (see bg_cr_standing).
  local crl crrc=0
  crl=$(bg_cr_standing "$slug" "$num" "$url" "$head" "$c") || crrc=$?
  case "$crrc" in
    0) printf '%s' "$crl"; return 1 ;;
    2) printf 'review-states'; return 2 ;;
  esac
  all=$(printf '%s\n%s\n%s\n' "$c" "$r" "$i" | sed '/^$/d')
  [ -n "$all" ] || return 0
  while IFS="$US" read -r id at login lurl b64; do
    body=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
    if bg_marker_block "$body"; then anyblock=1; break; fi
  done <<<"$all"
  [ "$anyblock" = 1 ] || return 0
  ht=$(bg_head_time "$slug" "$num") || { printf 'head-time'; return 2; }
  # -s: two comments of the SAME second keep the order their source gave them.
  while IFS="$US" read -r id at login lurl b64; do
    [ -n "$login" ] || login="-"
    # "-" is bg_read's "GitHub sent no url"; the PR itself is the honest link
    # then. With login, this keeps every field of the answer line non-empty,
    # which is what lets the CALLERS split that line on tabs safely.
    case "$lurl" in ''|-) lurl="$url" ;; esac
    body=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
    # A comment that matches BOTH markers ("BLOCK CLEARED") is read as a clear.
    if bg_marker_clear "$body"; then pend=$(bg_pend_drop "$pend" "$login"); continue; fi
    # …and a MACHINE's HEAD-BOUND TERMINAL VERDICT clears that login's own block
    # (BH-1131), on the same ordering rule: this walk is in time order, so an
    # approve older than the block reaches an empty pending list and drops
    # nothing. A body that ALSO carries a BLOCK marker falls through to the
    # block arm instead — a re-review that still names a blocking finding
    # blocks, whatever its last line says, because that is the fail-closed way
    # to read an ambiguous comment. The login and head conditions are up at
    # bg_verdict_clears; between them they are why the machine reviewer's
    # `VERDICT: APPROVE`, which lands under the fleet PAT's `operator` login,
    # cannot clear a BLOCK a person typed.
    if bg_verdict_clears "$body" "$login" "$head"; then
      pend=$(bg_pend_drop "$pend" "$login"); continue
    fi
    bg_marker_block "$body" || continue
    bg_newer "$at" "$ht" || continue
    pend=$(bg_pend_drop "$pend" "$login")
    pend="${pend:+$pend$NL}$login$TAB$lurl$TAB$at$TAB$id"
  done <<<"$(LC_ALL=C sort -s -t"$US" -k2,2 <<<"$all")"
  # BH-4468: a lead/human MERGE verdict row on THIS head lifts a MACHINE's
  # comment BLOCK (#4175: the autopilot never re-reviews a head it answered, so
  # only an empty re-head commit could free it). Never a person's.
  pend=$(bg_bot_lift "$slug" "$num" "$head" "$pend")
  [ -n "$pend" ] || return 0
  # BH-3934: drop each pending block whose id the block_ci_clear row for this
  # head names, by whole word. One ledger read per scan, and only on a scan
  # that would refuse; an unreadable row lifts nothing.
  [ "$cread" = 1 ] || cids=$(bg_ci_cleared_ids "$slug" "$num" "$head") || cids=""
  if [ -n "$cids" ]; then
    pend=$(awk -F'\t' -v ids=" $cids " 'NF > 0 && index(ids, " " $4 " ") == 0' <<<"$pend")
    [ -n "$pend" ] || return 0
  fi
  newest=$(LC_ALL=C sort -s -t"$TAB" -k3,3 <<<"$pend" | tail -1)
  IFS=$'\t' read -r login lurl at id <<<"$newest"
  printf '%s\t%s\t%s\t%s' "$lurl" "$login" "$at" "$id"
  return 1
}

# bg_scan <slug> <num> <pr-url> <head-sha> [<issue-num>] — the read above, plus
# the refusal streak. Exit codes, stdout and cost are the read's, unchanged.
#
# WHY THE COUNTER LIVES HERE AND NOT IN THE SIX LANES. The same 81 log lines
# that said "could not read head-time" said it once per tick for eight hours and
# raised nothing, because every lane logs its own refusal and no lane can see
# that the PREVIOUS tick said the same sentence. A lane that had to remember to
# call the counter would be a lane that forgets; the gate is the one place every
# refusal already passes through.
#
# STDOUT IS THE ANSWER, so the streak may print NOTHING: every lane reads this
# as `out=$(bg_scan …)`, and one stray line from lane-alert.sh inside that
# substitution would be parsed as a blocking comment's url. The redirect below
# is load-bearing, and a test pins it with a deliberately noisy alerter.
bg_scan() {
  local out rc=0
  out=$(bg_scan_read "$@") || rc=$?
  bg_streak_note "$1" "$2" "${4:-}" "$rc" "$out" >/dev/null 2>&1
  printf '%s' "$out"
  return "$rc"
}

# bg_streak_note <slug> <num> <head> <rc> <scan-stdout> — count the CONSECUTIVE
# refusals of one (PR, head, reason) and say so ONCE, out loud, when the count
# reaches BLOCK_GATE_STREAK_K (default 6; at the conductor's 5-minute tick that
# is ~30 minutes of a PR going nowhere in silence).
#
# WHAT RESETS IT: a clean scan (rc 0 — the gate stopped refusing), a new head, a
# different failed read, or a different blocking comment. Each of those is a
# NEW condition and gets its own alert if it, too, persists. What does NOT reset
# it is another tick of the same thing, which is the entire point.
#
# ONE LINE PER PR, rewritten in place: the file cannot grow with every head a PR
# ever had, and the previous head's count is exactly the thing that must be
# forgotten when the head moves.
#
# THE REASON CARRIES THE BLOCKING COMMENT'S ID on rc 1, so a second reviewer
# blocking the same head is a new condition rather than a continuation of the
# first. bg_reason writes the human sentence for both exit codes already.
#
# This never fails its caller and never writes to stdout.
bg_streak_note() {
  local slug="$1" num="$2" head="$3" rc="$4" out="$5"
  local dir f reason prev_head prev_reason count alerted k txt lane box vstamp lstamp
  dir="$(bg_home)/state/block-gate/streak"
  f="$dir/${slug//\//-}-$num"
  # BH-1525 (review F3): an unreadable verdicts TABLE is one fact about this
  # box and lane, not one per READY PR, so it gets one alert id and one alert
  # per outage window — the stamp is cleared by the next clean scan.
  # BH-1606: so is an unreadable lead_pr_authors ROW (the lead fence's
  # `lead-row` reason, fed by to_lane_lead_fence) — its own stamp and id, the
  # same one-per-lane rule.
  lane=$(basename "${0:-lane}" .sh | tr -c 'A-Za-z0-9._-' '_')
  box="${JOBS_BOX:-$(hostname 2>/dev/null)}"
  vstamp="$(bg_home)/state/block-gate/verdicts-outage-$lane"
  lstamp="$(bg_home)/state/block-gate/lead-row-outage-$lane"
  case "$rc" in
    0) rm -f "$f" "$vstamp" "$lstamp" 2>/dev/null; return 0 ;;
    1) reason="blocked:$(awk -F'\t' '{print $4}' <<<"$out")" ;;
    2) reason="unreadable:${out:-unknown}" ;;
    *) return 0 ;;
  esac
  mkdir -p "$dir" 2>/dev/null || return 0
  count=0; alerted=0; prev_head=""; prev_reason=""
  if [ -r "$f" ]; then
    IFS=$'\t' read -r prev_head prev_reason count alerted < "$f"
  fi
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  case "${alerted:-}" in 1) ;; *) alerted=0 ;; esac
  if [ "${prev_head:-}" = "$head" ] && [ "${prev_reason:-}" = "$reason" ]; then
    count=$((count + 1))
  else
    count=1; alerted=0
  fi
  k="${BLOCK_GATE_STREAK_K:-6}"
  case "$k" in ''|*[!0-9]*) k=6 ;; esac
  if [ "$reason" = unreadable:verdicts ]; then
    # THE LANE STAMP DECIDES, not this PR's `alerted` (BH-1606): the streak file
    # is per PR and shared by every lane on the box, so a PR another lane already
    # alerted about must not silence this lane's one alert.
    if [ "$count" -ge "$k" ] && [ ! -e "$vstamp" ] && [ -x "$(bg_home)/bin/lane-alert.sh" ]; then
      txt="the verdicts table could not be read by $lane on $box for $count consecutive checks (first stuck PR: $slug#$num). Every merge this lane would make is held until the jobs worker answers GET /api/verdicts again — see logs/verdicts.log and logs/jobs-client.log."
      "$(bg_home)/bin/lane-alert.sh" --severity warn \
        --id "block-gate-verdicts-unreadable:$box:$lane" \
        block-gate "$txt" >/dev/null 2>&1 && { alerted=1; : > "$vstamp" 2>/dev/null; }
    elif [ -e "$vstamp" ]; then alerted=1
    fi
  elif [ "$reason" = unreadable:lead-row ]; then
    if [ "$count" -ge "$k" ] && [ ! -e "$lstamp" ] && [ -x "$(bg_home)/bin/lane-alert.sh" ]; then
      txt="the lead_pr_authors settings row could not be read by $lane on $box for $count consecutive checks (first stuck PR: $slug#$num). Whose PR is the lead's cannot be told, so every merge this lane would make is held until the jobs worker answers GET /api/settings/lead_pr_authors with a lead list again — see logs/jobs-client.log."
      "$(bg_home)/bin/lane-alert.sh" --severity warn \
        --id "block-gate-lead-row-unreadable:$box:$lane" \
        block-gate "$txt" >/dev/null 2>&1 && { alerted=1; : > "$lstamp" 2>/dev/null; }
    elif [ -e "$lstamp" ]; then alerted=1
    fi
  elif [ "$count" -ge "$k" ] && [ "$alerted" = 0 ] && [ -x "$(bg_home)/bin/lane-alert.sh" ]; then
    txt="$slug#$num has been refused $count consecutive times on head ${head:0:8} by the block gate: $(bg_reason "$rc" "$out" "$head"). Nothing merges until the head moves or the thread clears."
    "$(bg_home)/bin/lane-alert.sh" --severity warn \
      --id "block-gate-stuck:$slug#$num:${head:0:12}:$reason" \
      block-gate "$txt" >/dev/null 2>&1 && alerted=1
  fi
  printf '%s\t%s\t%s\t%s\n' "$head" "$reason" "$count" "$alerted" > "$f" 2>/dev/null
  return 0
}

# bg_pend_drop <pending-lines> <login> — the pending list without that login's
# entry. awk and not grep: a login can carry regex metacharacters (`app[bot]`).
bg_pend_drop() {
  [ -n "${1:-}" ] || return 0
  awk -F'\t' -v l="${2:-}" '$1!=l && NF>0' <<<"$1"
}

# bg_log <text> — one stamped line in logs/block-gate.log. Never stdout: bg_scan's
# stdout is the answer every lane parses (see bg_scan).
bg_log() {
  mkdir -p "$(bg_home)/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$(bg_home)/logs/block-gate.log" 2>/dev/null
}

# bg_bot_lift <slug> <num> <head> <pending-lines> — BH-4468: the pending list without
# every MACHINE login's block, when a lead/human MERGE or MERGE-WITH-NOTES verdict row
# stands on this head. A person's block is never touched: only that person's UNBLOCK,
# or a newer head, clears it. Asks the table at most once, and only when a bot block is
# pending, so the happy path costs nothing. A read that fails or finds no row lifts
# nothing (fail closed).
bg_bot_lift() {
  local slug="$1" num="$2" head="$3" pend="${4:-}" out="" line login lurl at id
  local asked=0 v="" src="" vid=""
  [ -n "$pend" ] || return 0
  while IFS=$'\t' read -r login lurl at id; do
    [ -n "$login" ] || continue
    if bg_bot_login "$login" && command -v vd_standing >/dev/null 2>&1; then
      if [ "$asked" = 0 ]; then
        asked=1
        line=$(vd_standing "$slug" "$num" "$head" 2>/dev/null) \
          && IFS=$'\t' read -r v src vid _ <<<"$line"
      fi
      case "$v:$src" in
        MERGE:lead|MERGE:human|MERGE-WITH-NOTES:lead|MERGE-WITH-NOTES:human)
          bg_log "block-gate: bot BLOCK $id lifted by human verdict #$vid ($slug#$num head ${head:0:8}, $src $v, @$login)"
          continue ;;
      esac
    fi
    out="${out:+$out$'\n'}$login"$'\t'"$lurl"$'\t'"$at"$'\t'"$id"
  done <<<"$pend"
  printf '%s' "$out"
}

# bg_why <scan-line> <head-sha> — the phrase every lane's refusal line carries.
bg_why() {
  local url login at id on
  IFS=$'\t' read -r url login at id <<<"${1:-}"
  case "$id" in
    cr-*@*)
      on="${id##*@}"
      printf 'standing CHANGES_REQUESTED (lead/human BLOCK) %s by @%s at %s on %s blocks head %s' "$url" "$login" "$at" "${on:0:8}" "${2:0:8}"
      [ "${on:0:8}" = "${2:0:8}" ] || printf ' (every head since only merged main: the PR'"'"'s own diff is unchanged)'
      ;;
    *) printf '%s by @%s at %s blocks head %s' "$url" "$login" "$at" "${2:0:8}" ;;
  esac
}

# bg_reason <scan-rc> <scan-stdout> <head-sha> — the phrase a lane's log line
# carries, for either non-zero rc, so the warn-only path says as much as the
# refusal does.
bg_reason() {
  case "${1:-}" in
    1) bg_why "${2:-}" "${3:-}" ;;
    *) printf 'the thread could not be read (%s)' "${2:-unknown}" ;;
  esac
}

# bg_refuse <slug> <num> <pr-url> <head-sha> <scan-line> <lane>
#   ONE comment per (PR, head, blocking-comment-id) — across the WHOLE fleet,
#   not per box. Two things say "already said it":
#     1. the local ledger `state/block-gate/posted.txt`, free, and the only one
#        consulted on the ticks after this box's own refusal;
#     2. the PR itself, when the local ledger has never heard of this key. Six
#        lanes on three different machines can refuse the same head — a tier-1
#        build on a builder box stands down and the hub conductor picks the PR
#        up READY minutes later with an empty ledger — and each of them would
#        otherwise post its own copy of the same sentence. The marker below is
#        what they recognise each other by; it is an HTML comment, so it is
#        invisible on the PR, and it matches neither the BLOCK marker nor the
#        CLEAR one (a test pins that, the same way the prose is pinned).
#   A failed marker read posts anyway: a duplicate comment is noise, a skipped
#   one is a hold nobody can see.
#   The ledger line is written AFTER the comment posts, so a crash between the
#   two costs a duplicate comment and never a silent hold. rc 1 = the comment
#   could not be posted (no ledger line, the next tick retries the post); the
#   merge is refused either way, because the refusal is decided before this is
#   ever called.
bg_refuse() {
  local slug="$1" num="$2" url="$3" head="$4" line="$5" lane="$6"
  local burl login at id dir key mark body
  IFS=$'\t' read -r burl login at id <<<"${line:-}"
  [ -n "$id" ] || return 1
  dir="$(bg_home)/state/block-gate"
  key="$slug#$num $head $id"
  mark="<!-- block-gate refused ${head:0:8} $id -->"
  mkdir -p "$dir" 2>/dev/null
  grep -qxF "$key" "$dir/posted.txt" 2>/dev/null && return 0
  if gh api "repos/$slug/issues/$num/comments" --paginate -q '.[].body' 2>/dev/null | grep -qF "$mark"; then
    printf '%s\n' "$key" >> "$dir/posted.txt"
    return 0
  fi
  case "$id" in
    cr-*) body="Not merging ${head:0:8}: @$login's CHANGES_REQUESTED review ($burl, $at) still stands. It was left on ${id##*@} and the PR's own diff has not changed since (a head that only merges main is not a fix). It merges when that reviewer approves or dismisses the review, posts RESUME or MERGE on this PR, a lead MERGE verdict is recorded for this head, or a commit changes the PR's own diff. Refused by the $lane merge gate.

$mark" ;;
    verdict-*) body="Not merging ${head:0:8}: a ${login%-verdict} BLOCK verdict is recorded for this exact head in the harness verdicts table (row ${id#verdict-}, $at; report: $burl). It merges when a newer commit is pushed, or when a later lead or human MERGE / MERGE-WITH-NOTES verdict is recorded for this head (bin/lead-verdict.sh post). Refused by the $lane merge gate.

$mark" ;;
    *)
      body="Not merging ${head:0:8}: $burl (@$login, $at) is a BLOCK on this head with no later clearing comment from that author. It merges when a newer commit is pushed, or when the same author posts UNBLOCK or CLEARED — and, for a block posted by one of the harness's own review lanes, when that same machine login posts a later terminal verdict line naming this head. Refused by the $lane merge gate.

$mark" ;;
  esac
  gh pr comment "$url" --body "$body" >/dev/null 2>&1 || return 1
  printf '%s\n' "$key" >> "$dir/posted.txt"
  return 0
}
