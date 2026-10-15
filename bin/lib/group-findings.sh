#!/bin/bash
# bin/lib/group-findings.sh — a QA run collects its findings FIRST, then files
# ONE issue per screen or flow. Sourced, never executed.
#
# THE RULE (the operator, 2026-10-15; rules/topics/12-qa-findings.md). A QA pass never
# files a ticket per finding. Every finding goes to one ledger for the run; then
# each screen or flow gets one issue with all its items as a checklist, so one
# PR fixes the whole screen. An open issue for the same screen or flow gets a
# comment instead, unless its PR is already approved: then a follow-up issue,
# Blocked-by that PR. A high data-leak or launch-blocker is filed at once and
# still stays in its group.
#
#   gf_key <screen_or_flow>                      the one key normaliser
#   gf_from_observed <board> <observed.json>...  qa-drive output -> findings JSONL
#   gf_run <findings.jsonl> <run_dir> <owner/repo> [--dry-run]
#
# INPUT, one JSON object per line:
#   {board, screen_or_flow, severity, title, repro, cause, class?, files?}
#   severity low|medium|high|critical (anything else is medium, and the ledger
#   row says severity_coerced); class data-leak|launch-blocker or nothing;
#   files = the repo paths the fix edits (the Blocked-by rule reads them).
#
# OUTPUT, in <run_dir>: findings-ledger.jsonl (append-only; a finding's state is
# its LAST row, keyed by fp) and group-findings.md (one line per group and the
# totals line). Both live in the run dir and follow its retention.
#
# THE MARKERS, matched exactly, in an issue BODY only:
#   <!-- findings-group: <board>|<key> -->     the group an issue belongs to
#   <!-- findings-run: <run_id> -->            the run that wrote a body/comment
#   <!-- findings-urgent: <fp> -->             an urgent finding's own issue
#   <!-- findings-followup-of: #<n> -->        a follow-up of an approved issue
#
# RETURN of gf_run: 0 every group acted (or the knob is off); 1 one or more
# POSTs failed (rows `failed`, a rerun on the run dir retries only those);
# 75 the open-issue list (or a PR read a group needed) is unknown, nothing is
# filed blind (rows `deferred`); 2 bad arguments.
#
# Knobs (catalog/lanes.d/_lib.group-findings.json, per board through
# lib_env_apply group-findings <board>): GROUP_FINDINGS (0 off, the default)
# and GROUP_FINDINGS_URGENT_RANK (1 low .. 4 critical, default 3).
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${GROUP_FINDINGS_LIB:-}" ]; then return 0 2>/dev/null; fi
GROUP_FINDINGS_LIB=1
_GF_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=bin/lib/gh-rest-list.sh
[ -r "$_GF_DIR/gh-rest-list.sh" ] && . "$_GF_DIR/gh-rest-list.sh"
# shellcheck source=bin/lib/block-gate.sh
[ -r "$_GF_DIR/block-gate.sh" ] && . "$_GF_DIR/block-gate.sh"

# The key normaliser, as a jq def so gf_run, gf_key and the replay share ONE
# implementation (D17). Empty in, empty out: a finding with no screen or flow
# has no group, and the caller records it `invalid`, never files it under "/".
_GF_JQ_KEY='def gfkey: ((. // "") | tostring | gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $k
  | if $k == "" then ""
    elif ($k | startswith("flow:")) then $k
    else ($k | sub("[?#].*$"; "") | sub("@[0-9]+$"; "") | sub("/+$"; "")) as $p
      | (if $p == "" then "/" else $p end) end;'

gf_key() { # gf_key <screen_or_flow>
  jq -rn --arg k "${1:-}" "$_GF_JQ_KEY"' $k | gfkey'
}

# gf_from_observed <board> <observed.json>... — one finding per failing check of
# each screen record, exactly the checks of screenFailures (bin/qa-drive.mjs)
# except the sign-in wall (that is a harness BLOCKED, not an app defect), and
# one high finding per flow with verdict "fail". rc 1 when any file could not
# be read as an observed.json (named on stderr): unreadable is never "0 findings".
gf_from_observed() {
  local board="${1:-}" f rc=0
  [ -n "$board" ] || { echo "gf_from_observed: want <board> <observed.json>..." >&2; return 2; }
  shift
  for f in "$@"; do
    if ! jq -ce --arg b "$board" '
      def rec($k; $s; $t; $r; $c): {board:$b, screen_or_flow:$k, severity:$s, title:$t, repro:$r, cause:$c};
      if (.screens | type) != "array" then error("no screens array") else . end
      | (.screens[] | . as $x
          | ("Open " + ($x.path // "") + " at the " + ($x.viewport // "?") + "px viewport as the QA user.") as $r
          | ( (select($x.error) | rec($x.path; "high"; "Page error at " + $x.viewport; $r; $x.error)),
              (select(($x.status | type) == "number" and $x.status >= 400)
                | rec($x.path; (if $x.status >= 500 then "high" else "medium" end);
                      "HTTP \($x.status) at \($x.viewport)"; $r; "The page answered HTTP \($x.status).")),
              (select(($x.consoleErrors // []) | length > 0)
                | rec($x.path; "medium"; "\($x.consoleErrors | length) console error(s) at \($x.viewport)"; $r; $x.consoleErrors[0])),
              (select(($x.failedRequests // []) | length > 0)
                | rec($x.path; "medium"; "\($x.failedRequests | length) failed request(s) at \($x.viewport)"; $r; $x.failedRequests[0])),
              (select($x.viewport == "375" and $x.horizontalScroll == true)
                | rec($x.path; "low"; "Horizontal body scroll at 375"; $r; "The page is wider than a 375px screen.")),
              (select($x.nativeDialog)
                | rec($x.path; "low"; "Native browser dialog at \($x.viewport)"; $r; $x.nativeDialog)) )),
        ((.flows // [])[] | select(.verdict == "fail")
          | rec("flow:\(.persona)/\(.flow)"; "high"; "Flow \(.persona)/\(.flow) failed";
                "Run flow \(.flow) as persona \(.persona)."; (.reason // "no reason recorded")))
    ' "$f" 2>/dev/null; then
      # -e also fails on a file with no finding at all (last output false/null
      # is impossible here, but an empty stream is rc 4): tell the two apart.
      if jq -e '(.screens | type) == "array"' "$f" >/dev/null 2>&1; then continue; fi
      echo "gf_from_observed: skipped $f (not a readable observed.json)" >&2
      rc=1
    fi
  done
  return "$rc"
}

# --- gf_run internals ---------------------------------------------------------

_gf_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# _gf_row <json-object> — append one ledger row, stamped with run_id and time.
_gf_row() {
  jq -c --arg r "$_GF_RUN" --arg t "$(_gf_now)" '{run_id:$r, ts:$t} + .' <<<"$1" >> "$_GF_LEDGER"
}

# _gf_mark <gk> <action> [extra-json] — one row per finding of group <gk> that
# this call handles, each carrying the finding's own fields.
_gf_mark() {
  local gk="$1" act="$2" extra="${3:-}" row
  [ -n "$extra" ] || extra='{}'
  while IFS= read -r row; do
    _gf_row "$(jq -c --arg a "$act" --argjson x "$extra" \
      '{line, board, group_key:.gk, fp, severity, title, action:$a} + (if .urgent_issue then {urgent_issue} else {} end) + $x' <<<"$row")"
  done < <(jq -c --arg g "$gk" '.[] | select(.gid == $g)' "$_GF_NORM")
}

# _gf_knob <board> <ENV> <default> — the knob for ONE board, in a subshell so
# one board's row never leaks into the next board's read.
_gf_knob() {
  ( if ! command -v lib_env_apply >/dev/null 2>&1 && [ -r "$_GF_DIR/lane-gate.sh" ]; then
      # shellcheck source=bin/lib/lane-gate.sh
      . "$_GF_DIR/lane-gate.sh" 2>/dev/null
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply group-findings "$1" >/dev/null 2>&1
    printf '%s' "${!2:-$3}" )
}

# _gf_post <path> <bodyfile> [title] — POST, then read the number (issue) or the
# url (comment). Prints "ok <number-or-0> <url>" or "fail <http-status>".
# Never "ok" without the field the write must answer (D9).
_gf_post() {
  local p="$1" bf="$2" title="${3:-}" out rc=0 n u
  out=$(mktemp "${TMPDIR:-/tmp}/gf-post.XXXXXX") || { echo "fail 000"; return 0; }
  if [ -n "$title" ]; then
    gh_rest POST "$p" -f "title=$title" -F "body=@$bf" > "$out" || rc=$?
  else
    gh_rest POST "$p" -F "body=@$bf" > "$out" || rc=$?
  fi
  if [ "$rc" != 0 ]; then rm -f "$out"; echo "fail ${GH_REST_STATUS:-000}"; return 0; fi
  n=$(jq -r '.number // empty' "$out" 2>/dev/null)
  u=$(jq -r '.html_url // empty' "$out" 2>/dev/null)
  rm -f "$out"
  if [ -n "$title" ]; then
    case "$n" in ''|*[!0-9]*) echo "fail ${GH_REST_STATUS:-000}"; return 0 ;; esac
  else
    [ -n "$u" ] || { echo "fail ${GH_REST_STATUS:-000}"; return 0; }
    n=0
  fi
  echo "ok $n $u"
}

# _gf_prs — the open PR list, read once per run. rc 75 when it is unknown.
_gf_prs() {
  [ -n "$_GF_PRS" ] && return 0
  local rc=0
  _GF_PRS="$_GF_TMP/prs.json"
  gh_rest_pr_list_all "$_GF_SLUG" open 1000 > "$_GF_PRS" || rc=$?
  if [ "$rc" != 0 ] || [ "$(jq 'length' "$_GF_PRS" 2>/dev/null)" -ge 1000 ] 2>/dev/null \
     || ! jq -e 'type == "array"' "$_GF_PRS" >/dev/null 2>&1; then
    _GF_PRS=""; return 75
  fi
  return 0
}

# _gf_approved_prs <issue> — print the number of each open PR that links the
# issue AND is approved on its head. rc 75 when the PR list is unknown.
# A PR whose reviews or comments cannot be read counts as approved (fail
# closed: never add scope to a PR nobody can read).
_gf_approved_prs() {
  local n="$1" pr head t rc login body
  _gf_prs || return 75
  while IFS=$'\t' read -r pr head; do
    [ -n "$pr" ] || continue
    t="$_GF_TMP/rev-$pr.json"; rc=0
    _gh_rest_list "$_GF_SLUG" "pulls/$pr/reviews" 300 '.' > "$t" || rc=$?
    # A list at its 300-row cap is not the whole list (D12): fail closed.
    if [ "$rc" != 0 ] || ! jq -e 'length < 300' "$t" >/dev/null 2>&1; then echo "$pr"; continue; fi
    if jq -e --arg h "$head" 'any(.[]; .state == "APPROVED" and .commit_id == $h)' "$t" >/dev/null 2>&1; then
      echo "$pr"; continue
    fi
    rc=0
    gh_rest_issue_comments "$_GF_SLUG" "$pr" 300 > "$t" || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'length < 300' "$t" >/dev/null 2>&1 \
       || ! command -v bg_verdict_clears >/dev/null 2>&1; then echo "$pr"; continue; fi
    while IFS=$'\t' read -r login body; do
      body=$(printf '%s' "$body" | base64 -d 2>/dev/null)
      if bg_verdict_clears "$body" "$login" "$head"; then echo "$pr"; break; fi
    done < <(jq -r '.[] | [(.user.login // ""), ((.body // "") | @base64)] | @tsv' "$t" 2>/dev/null)
  done < <(jq -r --argjson n "$n" '
      .[] | select(.state == "open" or .state == null)
      | select(((.body // "") | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?|refs|part of)[[:space:]]+#" + ($n|tostring) + "([^0-9]|$)"))
               or ((.head.ref // "") | test("-" + ($n|tostring) + "(-r[0-9]+)?$")))
      | [.number, (.head.sha // "")] | @tsv' "$_GF_PRS" | sort -n)
  return 0
}

# _gf_items <gk> — the checklist of group <gk>, one item per finding.
_gf_items() {
  jq -r --arg g "$1" '.[] | select(.gid == $g)
    | "- [ ] \(.severity) \(.title)" + (if .urgent_issue then " (filed at once as #\(.urgent_issue))" else "" end),
      "  - Repro: \(.repro)", "  - Cause: \(.cause)"' "$_GF_NORM"
}

# _gf_blocked_by <gk> — "Blocked-by: #<n>" for each EARLIER group of this run
# that lists a file this group lists (a grouped ticket must not become a hub).
_gf_blocked_by() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk -F'\t' -v f="$f" -v g="$1" '$1 == f && $2 != g {print "Blocked-by: " $3; exit}' "$_GF_FILES"
  done < <(jq -r --arg g "$1" '[.[] | select(.gid == $g) | .files[]] | unique[]' "$_GF_NORM") | sort -u
}

# _gf_own_files <gk> <ref> — record this group's files as owned by <ref>.
_gf_own_files() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk -F'\t' -v f="$f" '$1 == f {found=1} END {exit !found}' "$_GF_FILES" \
      || printf '%s\t%s\t%s\n' "$f" "$1" "$2" >> "$_GF_FILES"
  done < <(jq -r --arg g "$1" '[.[] | select(.gid == $g) | .files[]] | unique[]' "$_GF_NORM")
}

_gf_sum() { printf '%s\n' "$1" >> "$_GF_SUMMARY_BODY"; }

# _gf_group <gk> — act on ONE group. Sets _GF_LAST to its action.
_gf_group() {
  local gk="$1" board key n bf res st num url cand target="" approved="" first="" ap blk
  board=$(jq -r --arg g "$gk" '[.[] | select(.gid == $g)][0].board' "$_GF_NORM")
  key=$(jq -r --arg g "$gk" '[.[] | select(.gid == $g)][0].gk' "$_GF_NORM")
  n=$(jq --arg g "$gk" '[.[] | select(.gid == $g)] | length' "$_GF_NORM")
  _GF_LAST=""
  # Idempotency: a terminal row of this run for this group means it is done.
  if jq -e -s --arg g "$gk" 'any(.[]; (.board + "|" + .group_key) == $g
        and (.action == "filed" or .action == "commented" or .action == "followup"))' "$_GF_LEDGER" >/dev/null 2>&1; then
    _GF_LAST=done; _gf_sum "- $key: $n item(s), already acted on in this run"; return 0
  fi
  blk=$(_gf_blocked_by "$gk")
  bf="$_GF_TMP/body"
  # Our own filing from an earlier attempt of this run (the ledger row was lost
  # after the POST): an open issue with this group's AND this run's marker.
  cand=$(jq -r --arg m "<!-- findings-group: $gk -->" --arg r "<!-- findings-run: $_GF_RUN -->" \
    '[.[] | select(.state == "open" and ((.body // "") | contains($m)) and ((.body // "") | contains($r))) | .number] | min // empty' "$_GF_ISSUES")
  if [ -n "$cand" ]; then
    _gf_mark "$gk" filed "{\"issue\":$cand,\"note\":\"own-issue\"}"; _gf_own_files "$gk" "#$cand"
    _GF_LAST=filed; _GF_N_FILED=$((_GF_N_FILED+1)); _gf_sum "- $key: $n item(s), filed #$cand (this run, earlier attempt)"; return 0
  fi
  # Candidates: OPEN issues whose BODY carries this group's marker, lowest first.
  # The open PR list is read once, here in this shell, only when one exists.
  if jq -e --arg m "<!-- findings-group: $gk -->" 'any(.[]; .state == "open" and ((.body // "") | contains($m)))' "$_GF_ISSUES" >/dev/null \
     && ! _gf_prs; then
    _gf_mark "$gk" deferred '{"note":"pr-list-unknown"}'; _GF_LAST=deferred; _GF_N_DEFERRED=$((_GF_N_DEFERRED+1))
    _gf_sum "- $key: $n item(s), deferred (open PR list unknown)"; return 0
  fi
  for cand in $(jq -r --arg m "<!-- findings-group: $gk -->" \
        '.[] | select(.state == "open" and ((.body // "") | contains($m))) | .number' "$_GF_ISSUES" | sort -n); do
    [ -n "$first" ] || first="$cand"
    ap=$(_gf_approved_prs "$cand") || { _gf_mark "$gk" deferred '{"note":"pr-list-unknown"}'; _GF_LAST=deferred; _GF_N_DEFERRED=$((_GF_N_DEFERRED+1)); _gf_sum "- $key: $n item(s), deferred (open PR list unknown)"; return 0; }
    if [ -z "$ap" ]; then target="$cand"; break; fi
    approved="$approved $ap"
  done
  if [ -n "$target" ]; then
    # Scope comment. Already posted by this run? Then record it and stop.
    local ct="$_GF_TMP/comments.json" rc=0
    gh_rest_issue_comments "$_GF_SLUG" "$target" 300 > "$ct" || rc=$?
    if [ "$rc" != 0 ]; then
      _gf_mark "$gk" deferred "{\"issue\":$target,\"note\":\"comments-unreadable\"}"; _GF_LAST=deferred
      _GF_N_DEFERRED=$((_GF_N_DEFERRED+1)); _gf_sum "- $key: $n item(s), deferred (comments of #$target unreadable)"; return 0
    fi
    if jq -e --arg r "<!-- findings-run: $_GF_RUN -->" 'any(.[]; (.body // "") | contains($r))' "$ct" >/dev/null 2>&1; then
      _gf_mark "$gk" commented "{\"issue\":$target,\"note\":\"own-comment\"}"; _gf_own_files "$gk" "#$target"
      _GF_LAST=commented; _GF_N_COMMENTED=$((_GF_N_COMMENTED+1)); _gf_sum "- $key: $n item(s), commented on #$target (this run, earlier attempt)"; return 0
    fi
    { printf '<!-- findings-run: %s -->\n' "$_GF_RUN"
      printf 'New QA findings for `%s` from run %s:\n\n' "$key" "$_GF_RUN"
      _gf_items "$gk"
      [ -n "$blk" ] && printf '\n%s\n' "$blk"
    } > "$bf"
    if [ "$_GF_DRY" = 1 ]; then
      _gf_mark "$gk" would_comment "{\"issue\":$target}"; _gf_own_files "$gk" "#$target"
      _GF_LAST=would_comment; _gf_sum "- $key: $n item(s), would comment on #$target"; return 0
    fi
    res=$(_gf_post "repos/$_GF_SLUG/issues/$target/comments" "$bf"); read -r st num url <<<"$res"
    if [ "$st" = ok ]; then
      _gf_mark "$gk" commented "$(jq -nc --argjson i "$target" --arg u "$url" '{issue:$i, url:$u}')"; _gf_own_files "$gk" "#$target"
      _GF_LAST=commented; _GF_N_COMMENTED=$((_GF_N_COMMENTED+1)); _gf_sum "- $key: $n item(s), commented on #$target"
    else
      _gf_mark "$gk" failed "$(jq -nc --argjson i "$target" --arg h "$num" '{issue:$i, http:$h}')"
      _GF_LAST=failed; _GF_N_FAILED=$((_GF_N_FAILED+1)); _gf_sum "- $key: $n item(s), FAILED to comment on #$target (http $num)"
    fi
    return 0
  fi
  # A new issue: the group's first, or a follow-up of an approved one.
  local act=filed title
  { printf '<!-- findings-group: %s -->\n<!-- findings-run: %s -->\n' "$gk" "$_GF_RUN"
    if [ -n "$first" ]; then act=followup; printf '<!-- findings-followup-of: #%s -->\n' "$first"; fi
    printf 'QA findings for `%s` on %s, from run %s.' "$key" "$board" "$_GF_RUN"
    if [ "$act" = followup ]; then printf ' #%s already has an approved PR, so these items wait here.' "$first"; fi
    printf ' One PR fixes this %s.\n\n' "$(case "$key" in flow:*) echo flow ;; *) echo screen ;; esac)"
    _gf_items "$gk"
    { for ap in $approved; do printf 'Blocked-by: #%s\n' "$ap"; done; [ -n "$blk" ] && printf '%s\n' "$blk"; } | sort -u > "$_GF_TMP/blk"
    [ -s "$_GF_TMP/blk" ] && { printf '\n'; cat "$_GF_TMP/blk"; }
  } > "$bf"
  title="QA findings: $key ($n items)"
  if [ "$_GF_DRY" = 1 ]; then
    local wa=would_file; [ "$act" = followup ] && wa=would_followup
    _gf_mark "$gk" "$wa" '{}'; _gf_own_files "$gk" "(group $key)"
    _GF_LAST="$wa"; _gf_sum "- $key: $n item(s), would file${first:+ a follow-up of #$first}"; return 0
  fi
  res=$(_gf_post "repos/$_GF_SLUG/issues" "$bf" "$title"); read -r st num url <<<"$res"
  if [ "$st" = ok ]; then
    _gf_mark "$gk" "$act" "$(jq -nc --argjson i "$num" --arg u "$url" '{issue:$i, url:$u}')"; _gf_own_files "$gk" "#$num"
    _GF_LAST=$act
    if [ "$act" = followup ]; then _GF_N_FOLLOWUP=$((_GF_N_FOLLOWUP+1)); _gf_sum "- $key: $n item(s), follow-up #$num of #$first"
    else _GF_N_FILED=$((_GF_N_FILED+1)); _gf_sum "- $key: $n item(s), filed #$num"; fi
  else
    _gf_mark "$gk" failed "$(jq -nc --arg h "$num" '{http:$h}')"
    _GF_LAST=failed; _GF_N_FAILED=$((_GF_N_FAILED+1)); _gf_sum "- $key: $n item(s), FAILED to file (http $num)"
  fi
  return 0
}

# _gf_urgent — file each urgent finding at once, before any group. An open
# issue that already carries its marker is reused. Sets .urgent_issue in the
# normalised findings so the group checklist names it.
_gf_urgent() {
  local i fp num st url res bf="$_GF_TMP/ubody" prior
  while IFS=$'\t' read -r i fp; do
    [ -n "$fp" ] || continue
    num=$(jq -r --arg m "<!-- findings-urgent: $fp -->" \
      '[.[] | select(.state == "open" and ((.body // "") | contains($m))) | .number] | min // empty' "$_GF_ISSUES")
    prior=$(jq -rs --arg f "$fp" '[.[] | select(.fp == $f and .action == "urgent") | .issue] | last // empty' "$_GF_LEDGER" 2>/dev/null)
    [ -n "$num" ] || num="$prior"
    if [ -z "$num" ]; then
      { printf '<!-- findings-urgent: %s -->\n<!-- findings-run: %s -->\n' "$fp" "$_GF_RUN"
        jq -r --argjson i "$i" '.[$i] | "Urgent QA finding on `\(.gk)` (\(.board)): \(.severity), \(.class).\n\n- Title: \(.title)\n- Repro: \(.repro)\n- Cause: \(.cause)\n\nIt is also listed in the group issue for this screen or flow."' "$_GF_NORM"
      } > "$bf"
      if [ "$_GF_DRY" = 1 ]; then
        _gf_row "$(jq -c --argjson i "$i" '.[$i] | {line, board, group_key:.gk, fp, severity, title, action:"would_urgent"}' "$_GF_NORM")"
        continue
      fi
      res=$(_gf_post "repos/$_GF_SLUG/issues" "$bf" "QA urgent: $(jq -r --argjson i "$i" '.[$i] | "\(.gk): \(.title)"' "$_GF_NORM")")
      read -r st num url <<<"$res"
      if [ "$st" != ok ]; then
        _gf_row "$(jq -c --argjson i "$i" --arg h "$num" '.[$i] | {line, board, group_key:.gk, fp, severity, title, action:"failed", http:$h, note:"urgent"}' "$_GF_NORM")"
        _GF_N_FAILED=$((_GF_N_FAILED+1)); continue
      fi
      _gf_row "$(jq -c --argjson i "$i" --argjson n "$num" --arg u "$url" '.[$i] | {line, board, group_key:.gk, fp, severity, title, action:"urgent", issue:$n, url:$u}' "$_GF_NORM")"
      _GF_N_URGENT=$((_GF_N_URGENT+1))
    elif [ -z "$prior" ]; then
      _gf_row "$(jq -c --argjson i "$i" --argjson n "$num" '.[$i] | {line, board, group_key:.gk, fp, severity, title, action:"urgent", issue:$n, note:"reused-open-issue"}' "$_GF_NORM")"
    fi
    jq --argjson i "$i" --argjson n "$num" '.[$i].urgent_issue = $n' "$_GF_NORM" > "$_GF_NORM.t" && mv "$_GF_NORM.t" "$_GF_NORM"
  done < <(jq -r '.[] | select(.urgent) | [.idx, .fp] | @tsv' "$_GF_NORM")
}

gf_run() { # gf_run <findings.jsonl> <run_dir> <owner/repo> [--dry-run]
  local in="${1:-}" rd="${2:-}" slug="${3:-}" b on rank g rc=0 total groups invalid boards
  local _GF_RUN _GF_LEDGER _GF_NORM _GF_TMP _GF_ISSUES _GF_SLUG="$slug" _GF_DRY=0 _GF_PRS="" _GF_FILES _GF_LAST
  local _GF_SUMMARY_BODY _GF_N_FILED=0 _GF_N_COMMENTED=0 _GF_N_FOLLOWUP=0 _GF_N_URGENT=0 _GF_N_DEFERRED=0 _GF_N_FAILED=0
  [ "${4:-}" = --dry-run ] && _GF_DRY=1
  if [ ! -r "$in" ] || [ ! -d "$rd" ] || ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "gf_run: want <findings.jsonl> <run_dir> <owner/repo> [--dry-run]" >&2; return 2
  fi
  command -v jq >/dev/null 2>&1 || { echo "gf_run: jq is required" >&2; return 2; }
  _GF_RUN="${GF_RUN_ID:-$(basename "$rd")}"
  _GF_LEDGER="$rd/findings-ledger.jsonl"; touch "$_GF_LEDGER"
  _GF_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gf.XXXXXX") || return 2
  _GF_NORM="$_GF_TMP/norm.json"; _GF_ISSUES="$_GF_TMP/issues.json"; _GF_FILES="$_GF_TMP/files.tsv"
  _GF_SUMMARY_BODY="$_GF_TMP/summary"; : > "$_GF_FILES"; : > "$_GF_SUMMARY_BODY"

  # 1. Parse and normalise once. A line that is not a JSON object, or has no
  #    key, is an `invalid` row: never dropped silently, never filed.
  jq -R -s "$_GF_JQ_KEY"'
    [split("\n") | to_entries[] | select(.value | test("\\S")) | {line:(.key+1), raw:.value, j:(.value | try fromjson catch null)}]
    | map(if (.j | type) != "object" then {line, invalid:"not-json", raw:(.raw[0:200])}
          else .j as $j | ($j.screen_or_flow | gfkey) as $k
            | if $k == "" then {line, invalid:"no-key", raw:(.raw[0:200])}
              else (($j.severity // "") | tostring | ascii_downcase | gsub("^\\s+|\\s+$"; "")) as $s
                | {line, board:(($j.board // "") | tostring), gk:$k,
                   severity:(if ($s | IN("low","medium","high","critical")) then $s else "medium" end),
                   severity_coerced:(($s | IN("low","medium","high","critical")) | not),
                   title:(($j.title // "") | tostring), repro:(($j.repro // "") | tostring), cause:(($j.cause // "") | tostring),
                   class:((($j.class // "") | tostring | ascii_downcase) as $c | if ($c | IN("data-leak","launch-blocker")) then $c else null end),
                   files:(if ($j.files | type) == "array" then [$j.files[] | strings] else [] end)}
              end
          end)' "$in" > "$_GF_TMP/parsed.json" 2>/dev/null \
    || { echo "gf_run: cannot read $in" >&2; rm -rf "$_GF_TMP"; return 2; }
  jq -c '.[] | select(.invalid)' "$_GF_TMP/parsed.json" | while IFS= read -r g; do
    jq -e -s --argjson l "$(jq '.line' <<<"$g")" 'any(.[]; .action == "invalid" and .line == $l)' "$_GF_LEDGER" >/dev/null 2>&1 \
      || _gf_row "$(jq -c '{line, action:"invalid", note:.invalid, raw}' <<<"$g")"
  done
  # 2. fp per finding (sha256 of board|key|title|repro), group id, first-seen index.
  jq -c '[.[] | select(.invalid | not)]' "$_GF_TMP/parsed.json" > "$_GF_NORM"
  local fps="$_GF_TMP/fps"; : > "$fps"
  while IFS= read -r g; do
    printf '%s' "$g" | sha256sum | cut -c1-16 >> "$fps"
  done < <(jq -r '.[] | "\(.board)|\(.gk)|\(.title)|\(.repro)"' "$_GF_NORM")
  jq --rawfile f "$fps" '($f | split("\n") | map(select(length > 0))) as $fp
    | to_entries | map(.value + {idx:.key, fp:$fp[.key], gid:(.value.board + "|" + .value.gk)})' "$_GF_NORM" > "$_GF_NORM.t" \
    && mv "$_GF_NORM.t" "$_GF_NORM"
  total=$(jq 'length' "$_GF_NORM"); invalid=$(jq '[.[] | select(.invalid)] | length' "$_GF_TMP/parsed.json")
  # 3. The ledger FIRST: a pending row for every finding not yet in it, so no
  #    finding is lost when a filing below fails.
  jq -c '.[]' "$_GF_NORM" | while IFS= read -r g; do
    jq -e -s --arg f "$(jq -r '.fp' <<<"$g")" 'any(.[]; .fp == $f)' "$_GF_LEDGER" >/dev/null 2>&1 \
      || _gf_row "$(jq -c '{line, board, group_key:.gk, fp, severity, severity_coerced, title, action:"pending"}' <<<"$g")"
  done
  # 4. The knobs, per board. A board with grouping off: rows `off`, no call.
  boards=$(jq -r '[.[] | .board] | unique[]' "$_GF_NORM")
  local onb="" ranks="{}"
  for b in $boards; do
    on=$(_gf_knob "$b" GROUP_FINDINGS 0)
    rank=$(_gf_knob "$b" GROUP_FINDINGS_URGENT_RANK 3)
    case "$rank" in 1|2|3|4) ;; *) rank=3 ;; esac
    ranks=$(jq -c --arg b "$b" --argjson r "$rank" '. + {($b): $r}' <<<"$ranks")
    if [ "$on" = 1 ]; then onb="$onb $b"; else
      _gf_sum "- grouping is off for $b (lib.group-findings.$b.group_findings)"
      for g in $(jq -r --arg b "$b" '[.[] | select(.board == $b) | .gid] | unique[] | @base64' "$_GF_NORM"); do
        _gf_mark "$(base64 -d <<<"$g")" off '{}'
      done
    fi
  done
  groups=$(jq '[.[] | .gid] | unique | length' "$_GF_NORM")
  if [ -n "$onb" ]; then
    jq --arg on "$onb" --argjson rk "$ranks" '
        ($on | split(" ") | map(select(length > 0))) as $bs
        | map(select(.board as $b | $bs | index($b)))
        | map(. + {urgent:(.class != null and ({"low":1,"medium":2,"high":3,"critical":4}[.severity] >= $rk[.board]))})' \
      "$_GF_NORM" > "$_GF_NORM.t" && mv "$_GF_NORM.t" "$_GF_NORM"
    # 5. The open issues. Unknown (an error, or a list at the 1000 cap) stops
    #    ALL filing for the run: never file blind.
    gh_rest_issue_list "$slug" open "" 1000 > "$_GF_ISSUES" || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array" and length < 1000' "$_GF_ISSUES" >/dev/null 2>&1; then
      for g in $(jq -r '[.[] | .gid] | unique[] | @base64' "$_GF_NORM"); do
        _gf_mark "$(base64 -d <<<"$g")" deferred "$(jq -nc --arg h "${GH_REST_STATUS:-000}" '{note:"issue-list-unknown", http:$h}')"
        _GF_N_DEFERRED=$((_GF_N_DEFERRED+1))
      done
      _gf_sum "- deferred: the open issue list of $slug is unknown (rc $rc, http ${GH_REST_STATUS:-000}) or at its 1000 cap"
      rc=75
    else
      rc=0
      _gf_urgent
      # 6. Each group, in first-seen order.
      for g in $(jq -r 'reduce .[] as $f ([]; if any(.[]; . == $f.gid) then . else . + [$f.gid] end) | .[] | @base64' "$_GF_NORM"); do
        _gf_group "$(base64 -d <<<"$g")"
      done
    fi
  fi
  { printf '# group-findings: run %s\n\n' "$_GF_RUN"
    cat "$_GF_SUMMARY_BODY"
    printf '\ngroup-findings: %s findings, %s groups, filed %s, commented %s, followup %s, urgent %s, deferred %s, failed %s, invalid %s%s\n' \
      "$total" "$groups" "$_GF_N_FILED" "$_GF_N_COMMENTED" "$_GF_N_FOLLOWUP" "$_GF_N_URGENT" "$_GF_N_DEFERRED" "$_GF_N_FAILED" "$invalid" \
      "$([ "$_GF_DRY" = 1 ] && echo ' (dry run, nothing posted)')"
  } > "$rd/group-findings.md"
  rm -rf "$_GF_TMP"
  [ "$_GF_N_FAILED" -gt 0 ] && return 1
  [ "$rc" = 75 ] || [ "$_GF_N_DEFERRED" -gt 0 ] && return 75
  return 0
}
