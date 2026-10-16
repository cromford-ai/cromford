#!/bin/bash
# bin/lesson-propose.sh — BH-5807 (BH-5794.2): propose fixes for repeat causes.
# A hub lane, daily at 06:41 (cron/lanes/733-lesson-propose.cron).
#
# WHY. the operator (2026-10-09): "after each Block we learn to see if we need to change
# something in the plan or build process to avoid that block in the future".
# Wave 1 (bin/lesson-classify.sh, #5806) names the category of every BLOCK
# finding. This lane reads those rows and, for a cause that repeats, drafts ONE
# change at the earliest stage that would have stopped it. Wave 3 (#5808)
# measures the effect.
#
# ONE TICK:
#   1. lane_gate_or_exit / lane_env_apply lesson-propose; LESSON_PROPOSE_ENABLED=0
#      stops before any request. flock -n locks/lesson-propose.lock.
#   2. GET /api/lesson-propose/triggers: the categories with
#      lesson_propose.min_blocks or more distinct BLOCK verdicts in the last
#      lesson_propose.since_days days, and the clusters of `other` findings
#      whose raw labels share one slug. Unreadable: one log line, nothing done.
#   3. A cluster with no category row: POST /api/lesson-propose/categories adds one
#      (with a reason) and moves its findings into it; it is then a trigger like
#      a category. A retired slug: one log line, skipped.
#   4. Per trigger, at most LESSON_PROPOSE_MAX_PER_TICK a tick. The fingerprint
#      is the first 16 hex of sha256("<category>|<sorted verdict ids>").
#      DEDUP, before any spend, on the ledger row kind=lesson_proposal
#      key=<category>: a ledger outage stops the whole tick (never file blind);
#      an `open` row is read live on GitHub (still open: skip; merged or closed:
#      recorded); `merged` inside lesson_propose.cooldown_days: skip; `empty` or
#      `closed` on the same evidence: skip; `failed` on the same evidence at
#      lesson_propose.max_attempts: skip. The same evidence is the same
#      fingerprint, or no verdict id outside the row's `seen` list (the window
#      slides, so a verdict that ages out is not new evidence). Then the open issues and PRs of
#      HARNESS_REPO are searched for `[lesson:<category>]` in the title or the
#      body marker; a hit is recorded `open` and skipped. A list that cannot be
#      read skips the trigger.
#   5. `undelivered` or `held` rows deliver their stored draft (no call). An
#      infra category (suggested_stage harness-fix, or infra_false on more than
#      half the findings) gets a harness bug issue built from the evidence (no
#      call). Anything else: job_ledger_claim (drafting), then ONE
#      bin/agent-call.sh call (stage lesson-propose, role lesson.propose, no
#      tools) that answers {"target":"plan-lesson|builder-rule|check|none",...}.
#   6. DELIVER: the draft is written to the ledger `undelivered` FIRST. A
#      plan-lesson is a PR that adds one bullet to plan-contract §10; a
#      builder-rule is a PR that appends one D<n> rule to build-discipline; a
#      check or a harness bug is an `ai-build` issue. A second lesson PR on a
#      prompt file that already has an open one (read live) is `held`. Only a 201 sets the
#      row `open`.
#   7. One line in logs/lesson-propose.log for a tick that had a trigger:
#      <ts> triggers=<n> clusters=<n> categories_added=<n> proposed=<n> filed=<n> held=<n> skipped=<n> failed=<n> calls=<n>
#
# OFF: LESSON_PROPOSE_ENABLED=0, flags/lane-off-lesson-propose, or
# bin/harness-ctl.sh off lesson-propose. Registry: catalog/lanes.d/lesson-propose.json.
# Note: docs/notes/2026-10-15-BH-5807-lesson-propose.md.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/untrusted-input.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-var.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
  . "$SELF/lib/pr-trailers.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || exit 0
command -v _jobs_req >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0

LOG="$H/logs/lesson-propose.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# knob <name> <value> <default> <lo> <hi>: an integer in range, else one warn line and the default.
knob() {
  if [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -ge "$4" ] && [ "$2" -le "$5" ]; then printf '%s' "$2"; return; fi
  log "warn: $1=$2 is not an integer in $4..$5; using the default $3"
  printf '%s' "$3"
}
dash() { sed 's/—/-/g'; }
# rest <out-file> <method> <path> [args...]: one gh_rest call into a file (never
# a $( ), so GH_REST_STATUS survives); RC is its rc.
rest() { RC=0; gh_rest "$2" "$3" "${@:4}" > "$1" 2>/dev/null || RC=$?; }
why() { echo "http ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"; }

REPO="$HARNESS_REPO"
BASE=main
PLAN_FILE=prompts/plan-contract.md
BD_FILE=prompts/build-discipline.md

# lp_put <category> <status> <detail-json>: the ledger row, rc of the PUT.
# PUT /api/ledger cuts a detail at LP_DETAIL_MAX chars with no error
# (worker/jobs/src/routes/ledger.js), and a cut detail is no JSON: the row
# would lose fp, attempts, number and draft. So the size is checked here, in
# bytes (never fewer than the worker's UTF-16 units). Over it, `seen` becomes
# `seen_max` (its largest id), with one log line; still over, no write, rc 1.
LP_DETAIL_MAX=4000
lp_len() { local LC_ALL=C; printf '%s' "${#1}"; }
lp_put() {
  local d="$3" n
  if [ "$(lp_len "$d")" -gt "$LP_DETAIL_MAX" ] && jq -e '.seen | type == "array" and length > 0' <<<"$d" >/dev/null 2>&1; then
    n=$(jq '.seen | length' <<<"$d")
    d=$(jq -c '.seen_max = (.seen | max) | del(.seen)' <<<"$d")
    log "$1: the $2 detail is over $LP_DETAIL_MAX chars; seen ($n ids) is stored as seen_max"
  fi
  if [ "$(lp_len "$d")" -gt "$LP_DETAIL_MAX" ]; then
    log "$1: the $2 detail is $(lp_len "$d") chars, over the $LP_DETAIL_MAX the ledger keeps; not written"
    return 1
  fi
  job_ledger_put lesson_proposal "$1" "$2" "$d"
}
# lp_det <detail-json> <jq-update>: the detail with fields set.
lp_det() { local d="${1:-}"; [ -n "$d" ] || d='{}'; jq -c "$2" <<<"$d"; }

# lp_open_lists: the open issues and PRs of REPO, read once a tick into
# $TMPD/open-issues.json and $TMPD/open-prs.json. rc 1 when either cannot be
# read, or hit the 1000-row cap (an incomplete list is never "no hit").
OPEN_STATE=""
lp_open_lists() {
  case "$OPEN_STATE" in ok) return 0 ;; bad) return 1 ;; esac
  OPEN_STATE=bad
  gh_rest_issue_list "$REPO" open "" 1000 > "$TMPD/open-issues.json" 2>/dev/null || { log "the open issues of $REPO could not be read ($(why)); no trigger is drafted this tick"; return 1; }
  gh_rest_pr_list_all "$REPO" open 1000 > "$TMPD/open-prs.json" 2>/dev/null || { log "the open PRs of $REPO could not be read ($(why)); no trigger is drafted this tick"; return 1; }
  if [ "$(jq 'length' "$TMPD/open-issues.json")" -ge 1000 ] || [ "$(jq 'length' "$TMPD/open-prs.json")" -ge 1000 ]; then
    log "the open lists of $REPO hit the 1000-row cap; no trigger is drafted this tick"; return 1
  fi
  OPEN_STATE=ok
}
# lp_marker_hit <category>: the lowest-numbered open issue or PR with the title
# tag or the body marker of this category, as {kind, number, url, fp, path}.
lp_marker_hit() {
  jq -cn --arg c "$1" --slurpfile i "$TMPD/open-issues.json" --slurpfile p "$TMPD/open-prs.json" '
    def hit: ((.title // "") | contains("[lesson:" + $c + "]")) or ((.body // "") | contains("<!-- lesson-propose: " + $c + " "));
    def fpof: ((.body // "") | capture("<!-- lesson-propose: [^ ]+ fp=(?<f>[0-9a-f]+)")? | .f) // null;
    def pathof: ((.body // "") | capture("Prompt file: `(?<p>[^`]+)`")? | .p) // null;
    ([$i[0][] | select(hit) | {kind: "issue", number, url: .html_url, fp: fpof, path: null}]
     + [$p[0][] | select(hit) | {kind: "pr", number, url: .html_url, fp: fpof, path: pathof}])
    | sort_by(.number) | first // empty'
}
# lp_live <kind> <number>: the live state of a lesson PR or issue. Sets
# LIVE_STATE (open|merged|closed) and LIVE_AT. rc 1 when it cannot be read. A
# PR merged, or an issue closed as completed, is `merged`.
lp_live() {
  local f="$TMPD/live.json"
  LIVE_STATE=""; LIVE_AT=""
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  if [ "$1" = pr ]; then rest "$f" GET "repos/$REPO/pulls/$2"; else rest "$f" GET "repos/$REPO/issues/$2"; fi
  if [ "$RC" = 44 ]; then LIVE_STATE=closed; LIVE_AT="$NOW_ISO"; return 0; fi
  [ "$RC" = 0 ] || return 1
  LIVE_STATE=$(jq -r --arg k "$1" '
    if .state == "open" then "open"
    elif $k == "pr" and .merged_at != null then "merged"
    elif $k == "issue" and .state_reason == "completed" then "merged"
    elif .state == "closed" then "closed" else "" end' "$f" 2>/dev/null)
  LIVE_AT=$(jq -r '.merged_at // .closed_at // empty' "$f" 2>/dev/null)
  [ -n "$LIVE_STATE" ] || return 1
  [ -n "$LIVE_AT" ] || LIVE_AT="$NOW_ISO"
}
# lp_contents <path> <out-file>: the decoded file on BASE. rc 1 when unreadable.
lp_contents() {
  rest "$TMPD/contents.json" GET "repos/$REPO/contents/$1?ref=$BASE"
  [ "$RC" = 0 ] || return 1
  jq -er '.content' "$TMPD/contents.json" 2>/dev/null | base64 -d > "$2" 2>/dev/null && [ -s "$2" ]
}

# lp_body <trigger-json> <draft-json> <fp> <kind> <path>: the PR or issue body.
lp_body() {
  local tr="$1" d="$2" fp="$3" kind="$4" path="$5"
  {
    jq -r '"This change comes from a cause that repeats in code-review BLOCKs. bin/lesson-propose.sh drafted it from the evidence below.\n\nCategory: `\(.id)` (\(.name // .id))"' <<<"$tr"
    [ -n "$path" ] && printf 'Prompt file: `%s`\n' "$path"
    jq -r '"Target: \(.target)\n\n### The change\n\n**\(.title)**\n\n\(.text)\n" + (if (.why // "") != "" then "\nWhy: \(.why)\n" else "" end)' <<<"$d"
    if jq -e '(.acceptance_tests // []) | length > 0' <<<"$d" >/dev/null; then
      printf '\n#### Acceptance tests\n\n'
      jq -r '.acceptance_tests[] | "- \(.)"' <<<"$d"
    fi
    jq -r --argjson sd "$SINCE_DAYS" '"\n### Evidence\n\nBLOCKs in the window: \(.blocks) BLOCK verdicts in the last \($sd) days (verdict ids \(.verdict_ids | map(tostring) | join(", "))), \(.findings) findings.\n\nEvidence PRs:\n"
      + ([.prs[]? | "- \(.repo)#\(.pr)" + (if .report_url then " (report: \(.report_url))" else "" end) + (if .ticket then " \(.ticket)" else "" end)] | join("\n"))
      + "\n\nExpected BLOCKs avoided: up to \(.blocks) in \($sd) days (the BLOCKs that triggered this)\n"' <<<"$tr"
    printf '\n<!-- lesson-propose: %s fp=%s -->\n' "$(jq -r .id <<<"$tr")" "$fp"
    [ "$kind" = pr ] && printf '\nOpened by bin/lesson-propose.sh. It never merges.\n'
  } | dash
}

# lp_edit <target> <category> <draft-json> <in-file> <out-file>: the prompt
# file with the lesson in it. rc 1 when the plan-contract anchor is missing.
lp_edit() {
  local target="$1" cat="$2" d="$3" in="$4" out="$5" line n title
  if [ "$target" = plan-lesson ]; then
    line="- $(jq -r '.text' <<<"$d" | tr '\n' ' ' | sed -E 's/ +$//') (lesson-propose: $cat)"
    # Above the last §10 bullet that starts `- docs/OPERATING`; else above `## 11.`.
    # ENVIRON, never -v: awk -v reads backslash escapes in the model text.
    LP_LINE="$line" awk '
      BEGIN { L = ENVIRON["LP_LINE"] }
      { a[NR] = $0 }
      /^## 10\./ { s = 1; next }
      /^## / && s { s = 0 }
      s && /^- docs\/OPERATING/ { anchor = NR }
      /^## 11\./ && !h11 { h11 = NR }
      END {
        at = anchor ? anchor : h11
        if (!at) exit 1
        for (i = 1; i <= NR; i++) {
          if (i == at) { print L; if (!anchor) print "" }
          print a[i]
        }
      }' "$in" > "$out"
    return
  fi
  n=$(grep -oE '\*\*D[0-9]+' "$in" | tr -d '*D' | sort -n | tail -1)
  n=$(( ${n:-0} + 1 ))
  title=$(jq -r '.title' <<<"$d" | sed -E 's/[. ]+$//')
  { cat "$in"; [ -n "$(tail -c1 "$in")" ] && echo
    printf '\n## Added %s (lesson-propose: %s)\n- **D%s %s.** %s\n' "${NOW_ISO:0:10}" "$cat" "$n" "$title" "$(jq -r '.text' <<<"$d" | tr '\n' ' ' | sed -E 's/ +$//')"
  } > "$out"
}

# lp_open_pr <category> <trigger> <draft> <fp> <path>: the REST-only PR. Sets
# DELIVER_STEP on failure, DELIVER_NUM / DELIVER_URL on a 201.
lp_open_pr() {
  local cat="$1" tr="$2" d="$3" fp="$4" path="$5" br head bsha url rc
  br="harness/lesson-$cat-${fp:0:8}"
  if ! lp_contents "$path" "$TMPD/orig"; then DELIVER_STEP="contents-read ($(why))"; return 1; fi
  if ! lp_edit "$(jq -r .target <<<"$d")" "$cat" "$d" "$TMPD/orig" "$TMPD/new"; then DELIVER_STEP=anchor; return 2; fi
  rest "$TMPD/head.json" GET "repos/$REPO/git/ref/heads/$BASE"
  if [ "$RC" != 0 ] || ! head=$(jq -er '.object.sha' "$TMPD/head.json" 2>/dev/null); then DELIVER_STEP="head ($(why))"; return 1; fi
  jq -nc --arg r "refs/heads/$br" --arg s "$head" '{ref:$r, sha:$s}' > "$TMPD/ref.in"
  rest "$TMPD/ref.out" POST "repos/$REPO/git/refs" --input "$TMPD/ref.in"
  if [ "$RC" != 0 ]; then
    # gh_rest drops non-2xx bodies, so "already exists" is proven by reading the ref back.
    rc="${GH_REST_STATUS:-000}"
    [ "$rc" = 422 ] && rest "$TMPD/ref2.json" GET "repos/$REPO/git/ref/heads/$br"
    if [ "$rc" != 422 ] || [ "$RC" != 0 ]; then DELIVER_STEP="ref (http $rc)"; return 1; fi
  fi
  rest "$TMPD/blob.json" GET "repos/$REPO/contents/$path?ref=$br"
  if [ "$RC" != 0 ] || ! bsha=$(jq -er '.sha' "$TMPD/blob.json" 2>/dev/null); then DELIVER_STEP="contents-branch ($(why))"; return 1; fi
  jq -nc --arg m "lesson-propose: $(jq -r .title <<<"$d") ($cat)" --arg c "$(base64 -w0 < "$TMPD/new")" --arg s "$bsha" --arg b "$br" \
    '{message:$m, content:$c, sha:$s, branch:$b}' > "$TMPD/put.in"
  rest "$TMPD/put.out" PUT "repos/$REPO/contents/$path" --input "$TMPD/put.in"
  if [ "$RC" != 0 ]; then DELIVER_STEP="contents ($(why))"; return 1; fi
  # >>> pr trailers (BH-3987)
  # The lane opened this PR, and no ticket owns its branch.
  lp_body "$tr" "$d" "$fp" pr "$path" > "$TMPD/body.md"
  command -v pr_trailers_apply >/dev/null 2>&1 && { pr_trailers_apply "$TMPD/body.md" lane:lesson-propose none \
    || echo "lesson-propose: pr trailers: could not write $TMPD/body.md, PR opened without trailers" >&2; }
  jq -nc --arg t "$(jq -r '"Lesson: \(.title) [lesson:"' <<<"$d" | dash)$cat]" --arg h "$br" --arg b "$BASE" --rawfile body "$TMPD/body.md" \
    '{title:$t, head:$h, base:$b, body:$body}' > "$TMPD/pr.in"
  rest "$TMPD/pr.out" POST "repos/$REPO/pulls" --input "$TMPD/pr.in"
  # <<< pr trailers
  if [ "$RC" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ] \
     && url=$(jq -er '.html_url | select(type == "string" and startswith("https://"))' "$TMPD/pr.out" 2>/dev/null); then
    DELIVER_NUM=$(jq -r '.number // empty' "$TMPD/pr.out"); DELIVER_URL="$url"; return 0
  fi
  DELIVER_STEP="pulls ($(why)$( [ "$RC" = 0 ] && echo ' no html_url'))"; return 1
}
# lp_open_issue <category> <trigger> <draft> <fp>: the ai-build issue (the
# lookback filer's shape: only a 201 with a number counts).
lp_open_issue() {
  local cat="$1" tr="$2" d="$3" fp="$4" num
  lp_body "$tr" "$d" "$fp" issue "" > "$TMPD/body.md"
  jq -nc --arg t "$(jq -r '"Lesson: \(.title) [lesson:"' <<<"$d" | dash)$cat]" --rawfile b "$TMPD/body.md" \
    '{title:$t, body:$b, labels:["ai-build"]}' > "$TMPD/issue.in"
  rest "$TMPD/issue.out" POST "repos/$REPO/issues" --input "$TMPD/issue.in"
  num=$(jq -e '.number | numbers' "$TMPD/issue.out" 2>/dev/null) || num=""
  if [ "$RC" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ] && [ -n "$num" ]; then
    DELIVER_NUM="$num"; DELIVER_URL=$(jq -r '.html_url // ""' "$TMPD/issue.out"); return 0
  fi
  DELIVER_STEP="issues ($(why))"; return 1
}

# lp_deliver <category> <trigger> <draft> <fp> <attempts>: store the draft
# (undelivered), apply the held rule, then open the PR or the issue.
lp_deliver() {
  local cat="$1" tr="$2" d="$3" fp="$4" att="$5" target kind path det open_on rc o ok od on held
  target=$(jq -r .target <<<"$d")
  case "$target" in
    plan-lesson) kind=pr; path="$PLAN_FILE" ;;
    builder-rule) kind=pr; path="$BD_FILE" ;;
    *) kind=issue; path="" ;;
  esac
  det=$(jq -nc --arg fp "$fp" --arg t "$target" --arg k "$kind" --arg p "$path" --argjson a "$att" \
    --argjson b "$(jq '.blocks' <<<"$tr")" --argjson d "$d" --argjson s "$SEEN" \
    '{fp:$fp, target:$t, kind:$k, path:(if $p == "" then null else $p end), number:null, url:null, at:null, attempts:$a, blocks:$b, seen:$s, draft:$d}')
  if ! lp_put "$cat" undelivered "$det" >/dev/null; then
    log "$cat: the draft could not be stored (http ${JOBS_HTTP:-none}); not delivered"
    FAILED=$((FAILED + 1)); return
  fi
  if [ "$kind" = pr ]; then
    # Two lesson PRs on one prompt file is a guaranteed conflict: hold this one.
    # Each other `open` row on the path is read live first: its category can
    # be out of the trigger set, so no lp_one ever reads it again, and a stale
    # `open` row would hold every later lesson on this file for good.
    open_on=$(_jobs_req GET "/api/ledger?kind=lesson_proposal&limit=1000") || {
      log "$cat: the lesson_proposal list could not be read; left undelivered"; FAILED=$((FAILED + 1)); return; }
    held=""
    while IFS=$'\t' read -r o od; do
      [ -n "$o" ] || continue
      if ! lp_live "$(jq -r '.kind // "pr"' <<<"$od")" "$(jq -r '.number // ""' <<<"$od")"; then
        log "$cat: the open lesson of $o could not be read ($(why)); held"; held="$o"; continue
      fi
      if [ "$LIVE_STATE" = open ]; then held="$o"; continue; fi
      on=$(lp_det "$od" ".at = \"$LIVE_AT\"")
      lp_put "$o" "$LIVE_STATE" "$on" >/dev/null || { log "$o: the $LIVE_STATE status could not be written; $cat held"; held="$o"; }
    done < <(jq -r --arg c "$cat" --arg p "$path" '.ledgers[]? | select(.key != $c and .status == "open")
         | [.key, ((.detail // "") | fromjson? // {})] | select(.[1].path == $p) | [.[0], (.[1] | tojson)] | @tsv' <<<"$open_on" 2>/dev/null)
    if [ -n "$held" ]; then
      lp_put "$cat" held "$det" >/dev/null || log "$cat: the held status could not be written; the row stays undelivered"
      log "$cat: held; the lesson PR of $held is open on $path"
      HELD=$((HELD + 1)); return
    fi
  fi
  DELIVER_STEP=""; DELIVER_NUM=""; DELIVER_URL=""; rc=0
  if [ "$kind" = pr ]; then lp_open_pr "$cat" "$tr" "$d" "$fp" "$path" || rc=$?
  else lp_open_issue "$cat" "$tr" "$d" "$fp" || rc=$?; fi
  if [ "$rc" = 2 ]; then
    # No §10 anchor and no `## 11.` heading: the same draft fails the same way,
    # so it counts as an attempt.
    log "$cat: $path has no §10 '- docs/OPERATING' bullet and no '## 11.' heading; failed, no PR"
    lp_put "$cat" failed "$(lp_det "$det" ".attempts += 1 | .error = \"anchor missing in $path\"")" >/dev/null \
      || log "$cat: the failed status could not be written"
    FAILED=$((FAILED + 1)); return
  fi
  if [ "$rc" != 0 ]; then
    log "$cat: delivery failed at $DELIVER_STEP; the draft stays undelivered"
    FAILED=$((FAILED + 1)); return
  fi
  if [ "$kind" = pr ]; then PROPOSED=$((PROPOSED + 1)); else FILED=$((FILED + 1)); fi
  lp_put "$cat" open "$(lp_det "$det" ".number = ${DELIVER_NUM:-null} | .url = \"$DELIVER_URL\" | .at = \"$NOW_ISO\"")" >/dev/null \
    || log "$cat: opened $DELIVER_URL but the ledger write failed; the marker search heals it next tick"
}

# lp_bug_draft <trigger>: the harness bug draft of an infra category, built
# from the evidence with no model call.
lp_bug_draft() {
  jq -c '{target: "harness-bug",
    title: ("Fix the harness cause of: " + (.name // .id))[0:120],
    text: ((["The category `\(.id)` is an infra or false BLOCK: the PR did not cause it. \(.infra_false) of \(.findings) findings say infra_false, and the category stage is \(.suggested_stage // "none"). The causes:"]
            + ([.evidence[]? | .cause | select(. != null)] | unique | .[0:5] | map("- " + .))) | join("\n"))[0:1200],
    acceptance_tests: [], why: "infra category: a harness fix, not a prompt lesson"}' <<<"$1"
}

# lp_prompt <trigger> <out-file>: the drafting prompt. rc 1 when a prompt file
# cannot be read from BASE.
lp_prompt() {
  local tr="$1" out="$2" p repo pr
  lp_contents "$PLAN_FILE" "$TMPD/pc.md" || return 1
  lp_contents "$BD_FILE" "$TMPD/bd.md" || return 1
  {
    cat <<'EOF'
You draft ONE change that would have stopped a cause of code-review BLOCKs that keeps coming back. Pick the EARLIEST stage that would have stopped it:
- plan-lesson: one bullet for §10 of prompts/plan-contract.md, the rules the planner follows.
- builder-rule: one rule for prompts/build-discipline.md, the rules the builder follows.
- check: a mechanical check (a lint or a test) the harness runs. Give 1 to 5 acceptance tests.
- none: nothing a rule would fix, or the rule already exists below.

Do not repeat a lesson or a rule that is already in the lists below. Write plain English: one idea per sentence, active voice, no em dashes. title is at most 120 characters. text is at most 1200 characters and states ONE rule.

Answer with exactly one line of JSON and nothing else:
{"target":"plan-lesson|builder-rule|check|none","title":"...","text":"...","acceptance_tests":["..."],"why":"..."}

EOF
    jq -r --argjson sd "$SINCE_DAYS" '"CATEGORY: \(.id): \(.name // .id). \(.description // "")\nSuggested stage: \(.suggested_stage // "none"). \(.blocks) BLOCK verdicts in \($sd) days, \(.findings) findings, \(.infra_false) infra or false.\n"' <<<"$tr"
    echo "CURRENT PLAN LESSONS (§10 of prompts/plan-contract.md):"
    awk '/^## 10\./{s=1;next} /^## /{s=0} s && /^- /' "$TMPD/pc.md"
    echo
    echo "CURRENT BUILDER RULES (prompts/build-discipline.md):"
    grep -oE '^- \*\*D[0-9]+ [^*]+\*\*' "$TMPD/bd.md" | sed -E 's/^- \*\*//; s/\*\*$//'
    echo
    echo "EVIDENCE (the findings, then the diffs of up to 5 evidence PRs):"
    {
      jq -r '.evidence | to_entries[] | "\(.key + 1). \(.value.repo)#\(.value.pr) cause: \(.value.cause // "none"). files: \(.value.files | join(", ")). \(.value.text | gsub("\n"; " "))"' <<<"$tr"
      while IFS=$'\t' read -r repo pr; do
        [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$pr" =~ ^[0-9]+$ ]] || continue
        printf '\n### %s#%s\n' "$repo" "$pr"
        rest "$TMPD/files.json" GET "repos/$repo/pulls/$pr/files"
        if [ "$RC" = 0 ]; then
          jq -r '.[]? | "--- \(.filename)\n\(.patch // "")"' "$TMPD/files.json" 2>/dev/null | head -c 3000; echo
        else
          echo "(the diff could not be read: $(why))"
        fi
      done < <(jq -r '.prs[0:5][] | [.repo, (.pr | tostring)] | @tsv' <<<"$tr")
    } | if command -v ui_wrap >/dev/null 2>&1; then ui_wrap fetched-page; else cat; fi
  } > "$out"
}

# lp_one <trigger-json>: dedup, then draft and deliver one trigger.
lp_one() {
  local tr="$1" cat ids fp row rc st det at_s att=0 hit d run ans prompt infra same h0
  cat=$(jq -r .id <<<"$tr")
  ids=$(jq -r '.verdict_ids | sort | map(tostring) | join(",")' <<<"$tr")
  fp=$(printf '%s|%s' "$cat" "$ids" | sha256sum | cut -c1-16)

  # 1. The ledger row. An outage stops the whole tick: never file blind.
  row=$(job_ledger_row lesson_proposal "$cat"); rc=$?
  case "$rc" in
    0) ;;
    2) row='{"status":"","detail":""}' ;;
    *) log "the lesson_proposal ledger could not be read (rc=$rc); the tick stops, nothing filed"; STOP=1; return ;;
  esac
  st=$(jq -r '.status // ""' <<<"$row")
  det=$(jq -c '(.detail // "") | fromjson? // {}' <<<"$row"); [ -n "$det" ] || det='{}'
  if [ "$det" = '{}' ] && [ -n "$(jq -r '.detail // ""' <<<"$row")" ]; then
    log "$cat: the $st ledger detail is no JSON; read as empty"
  fi
  # The evidence already acted on: `seen` holds the verdict ids of the window
  # the row was last written in. The window slides, so a verdict that ages out
  # changes the fp but is not new evidence; only a verdict id outside `seen` is
  # (SAME=0). An aged-out id never comes back, so `seen` keeps only the current
  # window's ids. A window too large for the ledger stores `seen_max` instead
  # (lp_put): then only an id above it is new evidence.
  same=$(jq -r --argjson v "$(jq -c '.verdict_ids' <<<"$tr")" --arg fp "$fp" \
    'if .fp == $fp then 1
     elif ((.seen // []) | length) > 0 and ($v - .seen | length) == 0 then 1
     elif (.seen_max | type) == "number" then (.seen_max as $m | if ($v | all(. <= $m)) then 1 else 0 end)
     else 0 end' <<<"$det")
  SEEN=$(jq -c '.verdict_ids | unique' <<<"$tr")

  # 2. An open lesson is read live. An open row with no number (a lost
  # detail) is not read live: the marker search (step 4) heals it.
  if [ "$st" = open ] && ! [[ "$(jq -r '.number // ""' <<<"$det")" =~ ^[0-9]+$ ]]; then
    log "$cat: the open row has no lesson number; the marker search decides"
    st=""
  fi
  if [ "$st" = open ]; then
    if ! lp_live "$(jq -r '.kind // "pr"' <<<"$det")" "$(jq -r '.number // ""' <<<"$det")"; then
      log "$cat: the open lesson $(jq -r '.url // .number // "?"' <<<"$det") could not be read ($(why)); skipped"
      SKIPPED=$((SKIPPED + 1)); return
    fi
    if [ "$LIVE_STATE" = open ]; then SKIPPED=$((SKIPPED + 1)); return; fi
    st="$LIVE_STATE"; det=$(lp_det "$det" ".at = \"$LIVE_AT\"")
    lp_put "$cat" "$st" "$det" >/dev/null || log "$cat: the $st status could not be written"
  fi
  # 3. The cooldown and the terminal answers for this evidence.
  if [ "$st" = merged ]; then
    at_s=$(date -u -d "$(jq -r '.at // ""' <<<"$det")" +%s 2>/dev/null || echo 0)
    if [ $((NOW_S - at_s)) -lt $((COOLDOWN_DAYS * 86400)) ]; then SKIPPED=$((SKIPPED + 1)); return; fi
  fi
  if [ "$same" = 1 ]; then
    att=$(jq -r '.attempts // 0 | tonumber? // 0' <<<"$det")
    case "$st" in
      empty|closed) SKIPPED=$((SKIPPED + 1)); return ;;
      failed) if [ "$att" -ge "$MAX_ATTEMPTS" ]; then SKIPPED=$((SKIPPED + 1)); return; fi ;;
    esac
  fi
  # 4. An existing ticket is never re-filed: the marker search.
  if ! lp_open_lists; then SKIPPED=$((SKIPPED + 1)); return; fi
  hit=$(lp_marker_hit "$cat")
  if [ -n "$hit" ]; then
    det=$(jq -c --argjson h "$hit" --arg now "$NOW_ISO" '. + {kind: $h.kind, number: $h.number, url: $h.url, fp: ($h.fp // .fp), path: ($h.path // .path), at: $now}' <<<"$det")
    lp_put "$cat" open "$det" >/dev/null || log "$cat: found open #$(jq -r .number <<<"$hit") but the ledger write failed"
    SKIPPED=$((SKIPPED + 1)); return
  fi

  # 5. A stored draft is delivered with no new call.
  if { [ "$st" = undelivered ] || [ "$st" = held ]; } && jq -e '.draft.target' <<<"$det" >/dev/null 2>&1; then
    SLOTS=$((SLOTS + 1)); h0=$HELD
    lp_deliver "$cat" "$tr" "$(jq -c .draft <<<"$det")" "$(jq -r '.fp // ""' <<<"$det")" "$(jq -r '.attempts // 0' <<<"$det")"
    # A stored draft held again cost no call and no GitHub write: no slot.
    [ "$HELD" = "$h0" ] || SLOTS=$((SLOTS - 1))
    return
  fi
  # 6. An infra category: a harness bug, built with no call.
  infra=$(jq -r 'if .suggested_stage == "harness-fix" or (2 * .infra_false > .findings) then 1 else 0 end' <<<"$tr")
  if [ "$infra" = 1 ]; then
    SLOTS=$((SLOTS + 1))
    lp_deliver "$cat" "$tr" "$(lp_bug_draft "$tr")" "$fp" "$att"
    return
  fi
  # 7. Claim, then ONE call.
  if [ -z "$MODEL" ]; then
    [ "$NO_MODEL_LOGGED" = 1 ] || log "no lesson.propose model route; nothing claimed, no model call"
    NO_MODEL_LOGGED=1; SKIPPED=$((SKIPPED + 1)); return
  fi
  job_ledger_claim lesson_proposal "$cat" drafting 3600 open,held >/dev/null; rc=$?
  case "$rc" in
    0) ;;
    3) SKIPPED=$((SKIPPED + 1)); return ;;
    *) log "$cat: the claim failed (rc=$rc); not drafted"; SKIPPED=$((SKIPPED + 1)); return ;;
  esac
  SLOTS=$((SLOTS + 1))
  det=$(jq -nc --arg fp "$fp" --argjson a "$att" --argjson b "$(jq '.blocks' <<<"$tr")" --argjson s "$SEEN" '{fp:$fp, attempts:$a, blocks:$b, seen:$s}')
  prompt="$TMPD/prompt.md"
  if ! lp_prompt "$tr" "$prompt"; then
    log "$cat: the prompt files could not be read from $BASE ($(why)); failed, no call"
    lp_put "$cat" failed "$(lp_det "$det" '.error = "prompt files unreadable"')" >/dev/null || log "$cat: the failed status could not be written"
    FAILED=$((FAILED + 1)); return
  fi
  run="$TMPD/run.txt"; : > "$run"; rc=0
  CALLS=$((CALLS + 1))
  AGENT_CALL_LANE=lesson-propose AGENT_CALL_ROLE=lesson.propose AGENT_CALL_FP="lesson-propose:$fp" AGENT_CALL_NO_TOOLS=1 \
    "$H/bin/agent-call.sh" lesson-propose fleet "$MODEL" "$TIMEOUT" "$run" "@$prompt" </dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    # rc 74-79: refused before the vendor, nothing billed, the attempt is free.
    if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then d="$att"; else d=$((att + 1)); fi
    lp_put "$cat" failed "$(lp_det "$det" ".attempts = $d | .error = \"agent-call rc=$rc\"")" >/dev/null || log "$cat: the failed status could not be written"
    FAILED=$((FAILED + 1)); return
  fi
  if [ -z "$(tr -d '[:space:]' < "$run")" ]; then
    lp_put "$cat" empty "$(lp_det "$det" '.error = "blank answer"')" >/dev/null || log "$cat: the empty status could not be written"
    return
  fi
  ans=$(grep -E '^[[:space:]]*\{' "$run" | tail -1)
  d=$(jq -c 'select((.target | type) == "string" and (.target | IN("plan-lesson", "builder-rule", "check", "none")))
      | {target, title: ((.title // "") | tostring | gsub("—"; "-") | gsub("[\r\n]+"; " ") | .[0:120]),
         text: ((.text // "") | tostring | gsub("—"; "-") | .[0:1200]),
         acceptance_tests: ([(.acceptance_tests // [])[]? | select(type == "string" and . != "") | gsub("—"; "-") | .[0:200]] | .[0:5]),
         why: ((.why // "") | tostring | gsub("—"; "-") | .[0:300])}' <<<"$ans" 2>/dev/null)
  if [ -z "$d" ]; then
    lp_put "$cat" failed "$(lp_det "$det" ".attempts = $((att + 1)) | .error = \"unparseable answer\"")" >/dev/null || log "$cat: the failed status could not be written"
    FAILED=$((FAILED + 1)); return
  fi
  if [ "$(jq -r .target <<<"$d")" = none ]; then
    lp_put "$cat" empty "$(lp_det "$det" '.error = "target none"')" >/dev/null || log "$cat: the empty status could not be written"
    return
  fi
  if ! jq -e '.title != "" and .text != "" and (.target != "check" or (.acceptance_tests | length) > 0)' <<<"$d" >/dev/null; then
    lp_put "$cat" failed "$(lp_det "$det" ".attempts = $((att + 1)) | .error = \"incomplete draft\"")" >/dev/null || log "$cat: the failed status could not be written"
    FAILED=$((FAILED + 1)); return
  fi
  lp_deliver "$cat" "$tr" "$d" "$fp" "$((att + 1))"
}

# lp_cluster <cluster-json>: add the category row of a cluster. Writes the
# trigger it becomes to $TMPD/cluster.json (rc 0), or nothing (rc 1). Run in
# this shell, never in $( ), so ADDED survives.
lp_cluster() {
  local c="$1" id body resp rc
  rm -f "$TMPD/cluster.json"
  id=$(jq -r .id <<<"$c")
  if [ "$(jq -r '.exists // ""' <<<"$c")" = retired ]; then log "cluster $id: the category is retired; skipped"; return 1; fi
  body=$(jq -c --arg since "$SINCE" --argjson sd "$SINCE_DAYS" '{
    id, name: .raw_labels[0][0:120],
    description: ([.evidence[]? | .cause | select(. != null and . != "")] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end) | .[0:3] | join("; "))[0:1000],
    reason: ("\(.blocks) BLOCK verdicts in \($sd) days (\(.verdict_ids | map(tostring) | join(", "))) had other findings labelled " + (.raw_labels | map("\"" + . + "\"") | join(", ")) + ". Added by bin/lesson-propose.sh (BH-5807).")[0:500],
    raw_labels, since: $since}' <<<"$c")
  resp=$(_jobs_req POST /api/lesson-propose/categories "$body"); rc=$?
  case "$rc" in
    0) [ "$(jq -r '.created' <<<"$resp" 2>/dev/null)" = true ] && ADDED=$((ADDED + 1)) ;;
    9) log "cluster $id: the category is retired; skipped"; return 1 ;;
    *) log "cluster $id: the category row could not be added (http ${JOBS_HTTP:-none}); skipped"; return 1 ;;
  esac
  jq -c --argjson b "$body" '. + {name: $b.name, description: $b.description, suggested_stage: null, grp: "Lesson-propose"}' <<<"$c" > "$TMPD/cluster.json"
}

tick() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lesson-propose
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lesson-propose
  case "${LESSON_PROPOSE_ENABLED:-1}" in
    0) exit 0 ;;
    1) ;;
    *) log "warn: LESSON_PROPOSE_ENABLED=${LESSON_PROPOSE_ENABLED} is not 0 or 1; using the default 1" ;;
  esac
  exec 9>"$H/locks/lesson-propose.lock" || exit 0
  flock -n 9 || exit 0
  mkdir -p "$H/state/lesson-propose" 2>/dev/null
  TMPD=$(mktemp -d "$H/state/lesson-propose/tick.XXXXXX") || exit 0
  # shellcheck disable=SC2064
  trap "case '$TMPD' in '$H/state/lesson-propose/'?*) rm -rf '$TMPD' ;; esac" EXIT

  local max resp rc n trs c t
  max=$(knob LESSON_PROPOSE_MAX_PER_TICK "${LESSON_PROPOSE_MAX_PER_TICK:-3}" 3 1 20)
  TIMEOUT=$(knob LESSON_PROPOSE_TIMEOUT_S "${LESSON_PROPOSE_TIMEOUT_S:-300}" 300 60 1200)
  NOW_ISO="${LESSON_PROPOSE_NOW:-}"
  if [ -n "$NOW_ISO" ] && ! NOW_S=$(date -u -d "$NOW_ISO" +%s 2>/dev/null); then
    log "warn: LESSON_PROPOSE_NOW=$NOW_ISO is not a time; using the clock"; NOW_ISO=""
  fi
  [ -n "$NOW_ISO" ] || { NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ); NOW_S=$(date -u -d "$NOW_ISO" +%s); }
  PROPOSED=0; FILED=0; HELD=0; SKIPPED=0; FAILED=0; CALLS=0; ADDED=0; SLOTS=0; STOP=0; NO_MODEL_LOGGED=0; SEEN='[]'

  resp=$(_jobs_req GET /api/lesson-propose/triggers); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.categories | type) == "array" and (.clusters | type) == "array" and (.settings | type) == "object"' <<<"$resp" >/dev/null 2>&1; then
    log "could not read GET /api/lesson-propose/triggers (rc=$rc http ${JOBS_HTTP:-none}); nothing proposed"
    exit 0
  fi
  SINCE_DAYS=$(jq -r '.settings.since_days' <<<"$resp")
  COOLDOWN_DAYS=$(jq -r '.settings.cooldown_days' <<<"$resp")
  MAX_ATTEMPTS=$(jq -r '.settings.max_attempts' <<<"$resp")
  SINCE=$(jq -r '.since' <<<"$resp")
  n=$(jq '.clusters | length' <<<"$resp")
  [ "$(jq '.categories | length' <<<"$resp")" -gt 0 ] || [ "$n" -gt 0 ] || exit 0

  MODEL=""
  if command -v lane_role_model >/dev/null 2>&1; then MODEL=$(lane_role_model lesson.propose 2>/dev/null) || MODEL=""; fi

  # Clusters first: at most MAX_PER_TICK new rows a tick, and never one for an
  # id that is already a category trigger.
  trs=$(jq -c '.categories' <<<"$resp")
  while IFS= read -r c; do
    [ "$ADDED" -lt "$max" ] || break
    jq -e --arg i "$(jq -r .id <<<"$c")" 'any(.[]; .id == $i)' <<<"$trs" >/dev/null && continue
    lp_cluster "$c" && trs=$(jq -c --slurpfile t "$TMPD/cluster.json" '. + $t' <<<"$trs")
  done < <(jq -c '.clusters[]' <<<"$resp")
  trs=$(jq -c 'sort_by(-.blocks, .id)' <<<"$trs")

  while IFS= read -r t; do
    [ "$SLOTS" -lt "$max" ] || break
    lp_one "$t"
    [ "$STOP" = 0 ] || break
  done < <(jq -c '.[]' <<<"$trs")
  log "triggers=$(jq 'length' <<<"$trs") clusters=$n categories_added=$ADDED proposed=$PROPOSED filed=$FILED held=$HELD skipped=$SKIPPED failed=$FAILED calls=$CALLS"
}

case "${1:-}" in
  '') tick ;;
  *) echo "usage: lesson-propose.sh" >&2; exit 2 ;;
esac
exit 0
