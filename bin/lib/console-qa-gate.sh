#!/bin/bash
# shellcheck shell=bash
# bin/lib/console-qa-gate.sh — BH-5909 slice 2: the lead gate for console UI
# changes. A harness PR that changes console-ui/src/ needs a browser QA PASS
# comment bound to its CURRENT head before the lead review may pass it.
# Sourced, never executed. Readers:
#   * bin/lead-review.sh: with LEAD_REVIEW_CONSOLE_QA_GATE=1 (default 0) a head
#     with no PASS gets a BLOCK report (reviewer model console-qa-gate) and no
#     model call, before the rules pack and before any replay;
#   * bin/pr-state-reconcile.sh (hub, every 15 min, since BH-7235; before it
#     bin/lead-review-enqueue.sh): a standing console-qa-gate BLOCK is lifted
#     with no push. Once a PASS names that head, the hub resets the lead review
#     request (POST /api/lead-reviews/<id>/reset), the box reviews the same head
#     again, and lead-review-land re-lands it (BH-5400: the earlier BLOCK review
#     is dismissed). The lead replay (BH-3930, worklist gate 50) is held for a
#     head with no PASS, so a replayed MERGE cannot skip the gate.
#
# WHY. #5838 and #5885 said "QA at 375px in a browser was not run"; the lead
# recorded that as a note and both merged. A note is not a gate.
#
# A PASS is ONE PR comment that has all of:
#   - an author who can write (author_association OWNER, MEMBER or
#     COLLABORATOR), or one of this fleet's own Apps (bin/lib/harness-self.sh),
#     which is how bin/console-preview-deploy.sh posts;
#   - a line that names the head: `QA: PASS for head <sha>`, `QA-HEAD: <sha>`
#     or `<!-- console-qa sha=<sha> result=PASS -->`, where <sha> is the full
#     head or a prefix of it of 9 or more hex digits;
#   - a line `QA COVERAGE: screens=<n> ... shots=<m>` with n >= 1 and m >= 1;
#   - no line that starts `QA: FAIL`.
#
# API:
#   cqg_verdict <repo> <pr> <head> <changed-files-file> <harness-repo>
#       prints ONE line: NOT-APPLICABLE (another repo, or no console-ui/src/
#       path; no thread read) | PASS <url> | STALE <sha12> <url> (the newest
#       PASS names another head) | MISSING | COULD NOT READ: <why>.
#   cqg_head_verdict <repo> <pr> <head>      the same, without the file check
#   cqg_report <key> <repo> <pr> <head> <verdict-line> <rvline>
#       the BLOCK report on stdout (the lead report format, VERDICT: BLOCK)
#   cqg_clear_block <repo> <pr> <head> <state-dir>
#       rc 0 and one line on stdout when it reset a console-qa-gate BLOCK's
#       request; rc 1 otherwise (a line on stdout only for a failed reset)
#   cqg_replay_hold <repo> <pr> <head> <clone> <base-ref> <harness-repo>
#       rc 0 and the reason on stdout = do not replay a lead word onto <head>
CQG_MODEL=console-qa-gate
_CQG_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
[ -n "${HARNESS_SELF_JQ_DEF:-}" ] || . "$_CQG_LIB/harness-self.sh" 2>/dev/null || true

# cqg_comments <repo> <pr> <out> — every page of the PR's issue comments as ONE
# array in <out>. rc 0 = a whole read; anything else = not a whole read.
cqg_comments() {
  local repo="$1" pr="$2" out="$3" p=1 rc tmp
  declare -F gh_rest >/dev/null || return 75
  tmp=$(mktemp "${TMPDIR:-/tmp}/cqg-c.XXXXXX") || return 75
  echo '[]' > "$out"
  while :; do
    rc=0; gh_rest GET "repos/$repo/issues/$pr/comments?per_page=100&page=$p" > "$tmp" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$tmp"; return "$rc"; fi
    jq -e 'type == "array"' "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 75; }
    jq -s '.[0] + .[1]' "$out" "$tmp" > "$out.n" 2>/dev/null && mv -f "$out.n" "$out" || { rm -f "$tmp" "$out.n"; return 75; }
    [ "$(jq length "$tmp")" -ge 100 ] || break
    [ "$p" -lt 20 ] || { rm -f "$tmp"; return 75; }
    p=$((p + 1))
  done
  rm -f "$tmp"
}

cqg_head_verdict() {
  local repo="$1" pr="$2" head tmp rc apps out
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  [[ "$head" =~ ^[0-9a-f]{40}$ && "$pr" =~ ^[0-9]+$ ]] || { echo "COULD NOT READ: bad head '${3:-}' or PR '$pr'"; return 0; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/cqg.XXXXXX") || { echo "COULD NOT READ: no temp file"; return 0; }
  rc=0; cqg_comments "$repo" "$pr" "$tmp" || rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.n"; echo "COULD NOT READ: PR #$pr comments (rc=$rc HTTP ${GH_REST_STATUS:-000})"; return 0
  fi
  apps=$(command -v harness_self_apps_json >/dev/null 2>&1 && harness_self_apps_json || echo '[]')
  out=$(jq -r --arg h "$head" --argjson apps "$apps" "${HARNESS_SELF_JQ_DEF:-def hs_ours(\$a): false;}"'
    def named: . as $x | $h | startswith($x);
    [ .[]?
      | select(((.author_association // "") | IN("OWNER","MEMBER","COLLABORATOR")) or hs_ours($apps))
      | ((.body // "") | gsub("\r"; "") | split("\n")) as $ls
      | { url: (.html_url // ""),
          heads: [ $ls[] | (capture("^QA: PASS for head (?<s>[0-9a-fA-F]+)\\b")
                           // capture("^QA-HEAD: (?<s>[0-9a-fA-F]+)\\s*$")
                           // capture("^<!-- console-qa sha=(?<s>[0-9a-fA-F]+) result=PASS -->$")
                           // empty) | .s | ascii_downcase | select(length >= 9) ],
          screens: ([ $ls[] | capture("^QA COVERAGE: (.* )?screens=(?<n>[0-9]+)( |$)") | .n | tonumber ] | last),
          shots: ([ $ls[] | capture("^QA COVERAGE: (.* )?shots=(?<n>[0-9]+)( |$)") | .n | tonumber ] | last),
          fail: any($ls[]; startswith("QA: FAIL")) }
      | select((.heads | length) > 0 and (.fail | not) and (.screens // 0) >= 1 and (.shots // 0) >= 1) ] as $p
    | if any($p[]; any(.heads[]; named)) then "PASS " + ([ $p[] | select(any(.heads[]; named)) ] | last | .url)
      elif ($p | length) > 0 then "STALE " + ($p | last | .heads | last | .[0:12]) + " " + ($p | last | .url)
      else "MISSING" end' "$tmp" 2>/dev/null) || out=""
  rm -f "$tmp"
  [ -n "$out" ] || { echo "COULD NOT READ: PR #$pr comments did not parse"; return 0; }
  printf '%s\n' "$out"
}

cqg_verdict() {
  local repo="${1:-}" pr="${2:-}" head="${3:-}" files="${4:-}" hrepo="${5:-}"
  [ -r "$files" ] || { echo "COULD NOT READ: the PR's changed files"; return 0; }
  [ -n "$hrepo" ] || { echo "COULD NOT READ: the harness repo is unknown"; return 0; }
  [ "${repo,,}" = "${hrepo,,}" ] || { echo NOT-APPLICABLE; return 0; }
  grep -q '^console-ui/src/' "$files" || { echo NOT-APPLICABLE; return 0; }
  cqg_head_verdict "$repo" "$pr" "$head"
}

cqg_report() {
  local key="$1" repo="$2" pr="$3" head="$4" v="$5" rv="${6:-}" why
  case "$v" in
    MISSING) why="No QA comment on this PR passes." ;;
    "STALE "*) why=$(printf '%s' "$v" | awk '{printf "The newest QA: PASS names head %s (%s), not this head.", $2, $3}') ;;
    *) why="The QA check said: $v" ;;
  esac
  printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: BLOCK\n- console qa: %s\n- reviewer model: %s\n\nFindings\n' \
    "$rv" "$key" "$repo" "$pr" "$head" "$v" "$CQG_MODEL"
  printf -- '- [BLOCK console-qa] This PR changes console-ui/src/, and no `QA: PASS` comment names head %s. %s\n' "$head" "$why"
  printf -- '- [NOTE] What clears it: one PR comment, by a writer or the harness App, with the line `QA: PASS for head %s`, a line `QA COVERAGE: screens=<n> flows=<f> shots=<m>` with n and m of 1 or more, and no `QA: FAIL` line. bin/console-preview-deploy.sh posts one for each head when that lane is on. The next pr-state-reconcile sweep on the hub after that comment resets this review, and the lead reviews the same head again. No push is needed.\n' "$head"
  printf '\nVERDICT: BLOCK\n'
}

cqg_clear_block() {
  local repo="$1" pr="$2" head="$3" st="$4" f req v url mark
  declare -F _jobs_req >/dev/null && declare -F lr_post_lead >/dev/null || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/cqg-v.XXXXXX") || return 1
  if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$repo&pr=$pr&head=$head&standing_only=1" > "$f" 2>/dev/null; then
    rm -f "$f"; return 1
  fi
  req=$(jq -r --arg m "$CQG_MODEL" '.standing // empty
    | select(.verdict == "BLOCK" and .source == "lead" and .reviewer_model == $m)
    | (.note // "") | split(" ")[] | select(startswith("lead-review:")) | sub("^lead-review:"; "")' "$f" 2>/dev/null | head -n 1)
  rm -f "$f"
  [[ "$req" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  v=$(cqg_head_verdict "$repo" "$pr" "$head")
  case "$v" in "PASS "*) ;; *) return 1 ;; esac
  url=${v#PASS }
  mark="$st/qa-reset-$(printf '%s' "${repo//\//_}" | tr -cd 'A-Za-z0-9._-')-$pr-${head:0:12}"
  [ "$(cat "$mark" 2>/dev/null)" = "$url" ] && return 1
  if ! lr_post_lead "/$req/reset" '{}' >/dev/null 2>&1; then
    echo "a QA: PASS names head ${head:0:12} ($url), but the reset of lead review $req failed; the next tick retries"
    return 1
  fi
  printf '%s\n' "$url" > "$mark" 2>/dev/null
  echo "a QA: PASS names head ${head:0:12} ($url): lead review $req reset, so the console QA gate BLOCK is reviewed again on the same head"
}

cqg_replay_hold() {
  local repo="$1" pr="$2" head="$3" clone="$4" base="$5" hrepo="$6" f v
  [ "${repo,,}" = "${hrepo,,}" ] || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/cqg-f.XXXXXX") || { echo "console QA: no temp file"; return 0; }
  if ! git -C "$clone" diff --name-only "$base...$head" > "$f" 2>/dev/null; then
    rm -f "$f"; echo "console QA: the changed files of ${head:0:12} did not read"; return 0
  fi
  v=$(cqg_verdict "$repo" "$pr" "$head" "$f" "$hrepo"); rm -f "$f"
  case "$v" in NOT-APPLICABLE|"PASS "*) return 1 ;; esac
  echo "console QA: $v"
}
