# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9905-verdict-block.sh — BH-9905: a standing BLOCK
# verdict row on the live head of an open harness PR starts a fix round.
#
# WHY. A human or lead BLOCK row (bin/lead-verdict.sh post ... BLOCK) stops
# every merge lane on its head, but before this file only a GitHub review in
# state CHANGES_REQUESTED made a fix-round candidate (br_from_reviews). A PR
# with a BLOCK row and no such review had no consumer: project-3 #1286, #1295,
# #1249 and #1246 waited 3 hours (2026-11-22) until a person posted the same
# text as a review. #1249 had only the review autopilot's box BLOCK and sat for
# 2 days.
#
# THE SOURCE (bvb_candidates, one line in _br_sources after br_from_reviews).
# Per project and per tick:
#   1. ONE batch read: bin/lib/verdicts.sh vd_repo_blocks (GET
#      /api/verdict-blocks) — the repo's BLOCK rows of the last
#      BR_VERDICT_BLOCK_LOOKBACK_DAYS, at most BR_VERDICT_BLOCK_LIMIT. No rows,
#      no further read. It is not one read per open PR.
#   2. The open-PR list the tick already holds (br_open_prs). A PR is kept only
#      when a batch row is on its LIVE head, it is not a draft and not retired.
#      BR_REVIEW_LOOKBACK_SECS does not apply here: it keeps its meaning for
#      reviews only.
#   3. For a kept PR only, the standing answer on that head (vd_standing_note):
#        - a lead/human BLOCK whose note has no [BLOCK needs-human] line ->
#          source word `verdict-block`;
#        - a MERGE / MERGE-WITH-NOTES stands -> nothing (the conductor's);
#        - nothing stands and a batch row is a box row -> vd_box_word must be
#          BLOCK, the conductor must not already park the head as review-block
#          (BH-9260 offers it as head-not-reapproved), and the newest
#          harness-review-autopilot comment by the harness on the PR must be
#          for this head and carry a [BLOCK <class>] finding line that is not
#          needs-human or console-qa -> source word `autopilot-block`.
#   4. The row is emitted with REASON review-changes-requested, the review
#      family's word, and the same rkey and ticket key br_from_reviews derives.
#      So every review rule applies unchanged: the one round per (PR, head)
#      (review_fix_heads), TICK_DONE, the fix-round queue dedupe, the review
#      cap (review.fix_rounds_max, BR_REVIEW_FIX_ROUNDS) and the terminal
#      (br_fix_terminal). A CHANGES_REQUESTED review and a BLOCK row on one
#      head are one park. The log line reads
#      `<p>/<rkey> [verdict-block/review-changes-requested] -> fix-round`.
#   A push moves the head; the row on the old head no longer matches, so the
#   source stops offering it, and the conductor's re-review judges the new
#   head. This file writes and retracts no verdict row.
#
# THE BRIEF (bvb_brief, one line in br_fix_round after bdn_brief, for the
# review reason). A lead/human BLOCK standing on the head adds its note, framed
# with $BR_LEAD_HDR (so the BH-2200 lead gate applies), plus the body of the
# comment or review it links to when that link is on THIS PR (any other link
# stays a text line, never fetched). Else a qualifying autopilot comment is
# added under `AUTOPILOT REVIEW FINDINGS (harness-review-autopilot on <h12>)`.
# A block already in the findings is not added again. A read that fails adds
# nothing, so an empty brief reaches br_fix_round's "retried next tick" line.
#
# Knobs (catalog/lanes.d/blocked-resolver.knobs.d/, settings rows
# lane.blocked-resolver.<lower-case name>):
#   BR_VERDICT_BLOCK                 1    0 = no source and no brief addition
#   BR_VERDICT_BLOCK_LOOKBACK_DAYS   30   the batch read's window (1..365)
#   BR_VERDICT_BLOCK_LIMIT           500  the batch read's row limit (1..1000;
#                                         the worker clamps it to the settings
#                                         row verdict_blocks.max_rows)
# BR_OPT_OFF=bh-9905-verdict-block does not source this file; both call sites
# then do what they did before.

# bvb_knob <name> <value> <default> <lo> <hi> — a whole number in [lo, hi];
#   empty is the default, a non-number is the default with one line.
bvb_knob() {
  local name="$1" v="$2" d="$3" lo="$4" hi="$5"
  case "$v" in
    '') printf '%s' "$d"; return 0 ;;
    *[!0-9]*) say "knob $name='$v' is not a number — using the default $d (BH-9905)"; printf '%s' "$d"; return 0 ;;
  esac
  v=$((10#$v))
  [ "$v" -lt "$lo" ] && v=$lo
  [ "$v" -gt "$hi" ] && v=$hi
  printf '%s' "$v"
}

# bvb_on — rc 0 when the knob is on.
bvb_on() {
  # BR_VERDICT_BLOCK: catalog/lanes.d/blocked-resolver.knobs.d/BR_VERDICT_BLOCK.json (fallback 1)
  [ "$(bvb_knob BR_VERDICT_BLOCK "${BR_VERDICT_BLOCK:-1}" 1 0 1)" = 1 ]
}

# bvb_needs_human <text> — rc 0 when the text carries a [BLOCK needs-human]
#   line: a person's step, which no code change answers (br_lead_pick's rule).
bvb_needs_human() { grep -qiF '[BLOCK needs-human]' <<<"${1:-}"; }

# bvb_block_findings <body> — rc 0 when the body has at least one finding line
#   that starts (after an optional list marker) with [BLOCK] or [BLOCK <class>]
#   whose class is not needs-human or console-qa. Lines inside ``` fences and
#   a [BLOCK ...] in the middle of a line (a [NOTE] that quotes one) do not count.
bvb_block_findings() {
  printf '%s\n' "${1:-}" | tr -d '\r' | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      sub(/^[[:space:]]*([-*+]|[0-9]+[.)])?[[:space:]]*/, "", line)
      sub(/^\*\*/, "", line)
      if (match(line, /^\[BLOCK( [A-Za-z0-9-]+)?\]/)) {
        c = (RLENGTH > 7) ? substr(line, 8, RLENGTH - 8) : ""
        if (c != "needs-human" && c != "console-qa") found = 1
      }
    }
    END { exit !found }'
}

# bvb_conductor_owns <slug> <num> <head> — rc 0 when the conductor's row for
#   this PR (pr-state.tsv: key state since head reviewed alerted reason url) is
#   BLOCKED_HUMAN with a `review-block:` reason on this head (BH-9260).
bvb_conductor_owns() {
  local rows="${MC_ROWS:-$H/state/merge-conductor/pr-state.tsv}"
  [ -r "$rows" ] || return 1
  awk -F'\t' -v k="$1#$2" -v h="$3" '$1 == k && $2 == "BLOCKED_HUMAN" && index($7, "review-block:") == 1 && tolower($4) == h { f = 1 } END { exit !f }' "$rows"
}

# bvb_autopilot_comment <slug> <num> <head> — the newest harness-review-autopilot
#   comment the harness posted on the PR, when it qualifies: it is for THIS
#   head (mc_rbp_trusted: the harness identity and the head12 marker) and it
#   has a BLOCK finding (bvb_block_findings).
#   rc 0 + the body | rc 1 none qualifies | rc 2 unreadable.
#   Reads: the issue (its comment count) and the last page of comments (the
#   page before it too, when the last page holds no autopilot comment). Read
#   once per PR and head per tick: the answer is kept in the tick's scratch
#   directory, which the lane's EXIT trap removes.
bvb_autopilot_comment() {
  local slug="$1" num="$2" head="$3" h12 dir f tf j n page pg rc=0 b64 c login body found="" TRK_SLUG="$1"
  h12="${head:0:12}"
  command -v mc_rbp_trusted >/dev/null 2>&1 && command -v harness_own_review_match >/dev/null 2>&1 || return 1
  command -v gh_rest >/dev/null 2>&1 || return 2
  # The issue and its comments are read through the tracker seam (BH-7919).
  command -v trk_gh_issue_raw >/dev/null 2>&1 || . "$H/bin/lib/tracker/github-issues.sh" 2>/dev/null || return 2
  dir="${TMPDIR:-/tmp}/br-open-prs.$$"; f="$dir/bvb-${slug//[^A-Za-z0-9]/_}-$num-$h12"
  if [ -s "$f.rc" ]; then
    rc=$(cat "$f.rc"); [ "$rc" = 0 ] && cat "$f.body"
    return "$rc"
  fi
  # The seam call runs as a plain command into a temp file (never inside $( )), so
  # GH_REST_STATUS / GH_REST_REASON stay in this shell (gh-rest-no-subshell-lint).
  tf=$(mktemp) || return 2
  if ! trk_gh_issue_raw "$num" </dev/null > "$tf"; then rm -f "$tf"; return 2; fi
  j=$(cat "$tf")
  n=$(jq -r '.comments // empty' <<<"$j" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) rm -f "$tf"; return 2 ;; esac
  rc=1
  if [ "$n" -gt 0 ]; then
    page=$(( (n + 99) / 100 ))
    for pg in "$page" $((page - 1)); do
      [ "$pg" -ge 1 ] || break
      trk_gh_comments_page "$num" "$pg" </dev/null > "$tf" || { rc=2; break; }
      j=$(cat "$tf")
      jq -e 'type == "array"' <<<"$j" >/dev/null 2>&1 || { rc=2; break; }
      # The marked comments of the page, newest first; the first one the
      # harness posted is the newest autopilot comment.
      while IFS= read -r b64; do
        c=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || continue
        login=$(jq -r '.user.login // ""' <<<"$c" 2>/dev/null)
        harness_own_review_match "$login" || continue
        body=$(jq -r '.body // ""' <<<"$c" 2>/dev/null)
        found=1; break
      done < <(jq -r '[.[] | select((.body // "") | contains("<!-- harness-review-autopilot "))] | reverse | .[] | @base64' <<<"$j" 2>/dev/null)
      [ -n "$found" ] && break
    done
    if [ -n "$found" ]; then
      rc=1
      mc_rbp_trusted "$login" "$body" "$head" && bvb_block_findings "$body" && rc=0
    fi
  fi
  rm -f "$tf"
  [ "$rc" = 2 ] && return 2
  if mkdir -p "$dir" 2>/dev/null; then
    [ "$rc" = 0 ] && printf '%s' "$body" > "$f.body"
    printf '%s' "$rc" > "$f.rc"
  fi
  [ "$rc" = 0 ] && printf '%s' "$body"
  return "$rc"
}

# bvb_word <p> <slug> <num> <head> <batch-rows-on-this-head> — the source word
#   for this PR: prints verdict-block or autopilot-block (rc 0), or nothing
#   (rc 1). Every unreadable read is one line and no candidate this tick.
bvb_word() {
  local p="$1" slug="$2" num="$3" head="$4" mine="$5" rc=0 out l1 v vid vsrc note="" bw
  out=$(vd_standing_note "$slug" "$num" "$head" </dev/null) || rc=$?
  case "$rc" in
    0) l1="${out%%$'\n'*}"
       [[ "$out" == *$'\n'* ]] && note="${out#*$'\n'}"
       IFS=$'\t' read -r v vid vsrc _ <<<"$l1"
       [ "$v" = BLOCK ] || return 1
       case "$vsrc" in human|lead) ;; *) return 1 ;; esac
       if bvb_needs_human "$note"; then
         say "$p/$slug#$num: BLOCK verdict #$vid ($vsrc) on ${head:0:12} names a [BLOCK needs-human] step — not a fix round"
         return 1
       fi
       printf 'verdict-block'; return 0 ;;
    1) ;;
    *) say "$p/$slug#$num: the standing verdict on ${head:0:12} could not be read (vd_standing_note rc $rc) — no verdict-block candidate this tick"
       return 1 ;;
  esac
  awk -F'\t' '$4 == "box" { f = 1 } END { exit !f }' <<<"$mine" || return 1
  rc=0; bw=$(vd_box_word "$slug" "$num" "$head" </dev/null) || rc=$?
  case "$rc" in
    0) ;;
    2) say "$p/$slug#$num: the box verdict on ${head:0:12} could not be read — no autopilot-block candidate this tick"; return 1 ;;
    *) return 1 ;;
  esac
  [ "$bw" = BLOCK ] || return 1
  if bvb_conductor_owns "$slug" "$num" "$head"; then
    say "$p/$slug#$num: the conductor parks ${head:0:12} as review-block (BH-9260) — it offers the round, not this source"
    return 1
  fi
  rc=0; bvb_autopilot_comment "$slug" "$num" "$head" >/dev/null || rc=$?
  case "$rc" in
    0) printf 'autopilot-block'; return 0 ;;
    2) say "$p/$slug#$num: the PR comments could not be read for the autopilot BLOCK on ${head:0:12} — no autopilot-block candidate this tick" ;;
  esac
  return 1
}

# bvb_candidates — the source. Candidate TSV rows on stdout (see the header).
bvb_candidates() {
  command -v harness_pr_list >/dev/null 2>&1 || return 0
  command -v vd_repo_blocks >/dev/null 2>&1 && command -v vd_standing_note >/dev/null 2>&1 || return 0
  bvb_on || return 0
  local days lim since p slug blocks brc list rows row num head brn url draft mine rkey tkey esc esc_rkey word
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low blocked-resolver >/dev/null 2>&1; then
    say "the verdict-block source is skipped this tick — the GitHub API budget is low"
    return 0
  fi
  # BR_VERDICT_BLOCK_LOOKBACK_DAYS: catalog/lanes.d/blocked-resolver.knobs.d/BR_VERDICT_BLOCK_LOOKBACK_DAYS.json (fallback 30)
  days=$(bvb_knob BR_VERDICT_BLOCK_LOOKBACK_DAYS "${BR_VERDICT_BLOCK_LOOKBACK_DAYS:-30}" 30 1 365)
  # BR_VERDICT_BLOCK_LIMIT: catalog/lanes.d/blocked-resolver.knobs.d/BR_VERDICT_BLOCK_LIMIT.json (fallback 500)
  lim=$(bvb_knob BR_VERDICT_BLOCK_LIMIT "${BR_VERDICT_BLOCK_LIMIT:-500}" 500 1 1000)
  since=$(date -u -d "@$(( $(date -u +%s) - days * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')
  while read -r p; do
    [ -n "${p:-}" ] || continue
    [ -z "$ONLY" ] || [ "$ONLY" = "$p" ] || continue
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    [ -n "$slug" ] && [ "$slug" != "-" ] || continue
    brc=0; blocks=$(vd_repo_blocks "$slug" "$since" "$lim" </dev/null) || brc=$?
    case "$brc" in
      0) ;;
      1) continue ;;
      *) say "$p: the standing-BLOCK read failed for $slug (vd_repo_blocks rc $brc) — no verdict-block candidate this tick, nothing spent"
         continue ;;
    esac
    [ -n "$blocks" ] || continue
    br_use_token "$slug"
    list=$(br_open_prs "$slug" </dev/null) || list=""
    if [ -z "$list" ]; then
      say "$p: the open-PR list of $slug would not read — no verdict-block candidate this tick"
      br_reset_token; continue
    fi
    rows=()
    mapfile -t rows < <(printf '%s' "$list" \
      | jq -r '.[]? | [((.number // "") | tostring), ((.headRefOid // "") | ascii_downcase), (.headRefName // ""), (.url // ""), ((.isDraft // false) | tostring)] | @tsv' 2>/dev/null)
    for row in "${rows[@]:-}"; do
      [ -n "${row:-}" ] || continue
      IFS=$'\t' read -r num head brn url draft <<<"$row"
      [ -n "${num:-}" ] && [ -n "${head:-}" ] || continue
      mine=$(awk -F'\t' -v n="$num" -v h="$head" '$1 == n && $2 == h' <<<"$blocks")
      [ -n "$mine" ] || continue
      [ -n "${url:-}" ] || url="https://github.com/$slug/pull/$num"
      command -v bdi_url_retired >/dev/null 2>&1 && bdi_url_retired "$url" && continue
      [ "${draft:-false}" = true ] && continue
      rkey=$(br_rkey "$slug#$num")
      tkey=$(br_ticket_key "$p" "-" "${brn:-}" "" 2>/dev/null </dev/null); tkey="${tkey%%	*}"
      # A legacy ESCALATED record stays terminal for its PR, as in br_from_reviews.
      esc=$(br_load "$p" "$(br_cap_key "$p" "$rkey" "$tkey")" \
            | jq -r '(.outcome // "") + "|" + (.escalated_rkey // "")' 2>/dev/null)
      if [ "${esc%%|*}" = ESCALATED ]; then
        esc_rkey="${esc#*|}"
        case "$esc_rkey" in ''|-|"$rkey") continue ;; esac
      fi
      word=$(bvb_word "$p" "$slug" "$num" "$head" "$mine") || continue
      printf '%s\t%s\t%s\treview-changes-requested\t%s\t-\t%s\t-\n' "$word" "$p" "$rkey" "$url" "${tkey:--}"
    done
    br_reset_token
  done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
  return 0
}

# bvb_linked <slug> <num> <link> — the text the brief carries for the link in
#   a BLOCK row: the body of a comment or review on THIS PR (read with
#   gh_rest), else the link as one text line. Never fetches another URL.
bvb_linked() {
  local slug="$1" num="$2" link="$3" pc="https://github.com/$1/pull/$2#issuecomment-" pr="https://github.com/$1/pull/$2#pullrequestreview-" id path j="" body tf
  case "$link" in
    "$pc"*) id="${link#"$pc"}"; path="repos/$slug/issues/comments/$id" ;;
    "$pr"*) id="${link#"$pr"}"; path="repos/$slug/pulls/$num/reviews/$id" ;;
    *) printf 'Linked report: %s\n' "$link"; return 0 ;;
  esac
  case "$id" in ''|*[!0-9]*) printf 'Linked report: %s\n' "$link"; return 0 ;; esac
  # gh_rest into a temp file, never inside $( ) (gh-rest-no-subshell-lint).
  if tf=$(mktemp); then
    gh_rest GET "$path" </dev/null > "$tf" && j=$(cat "$tf")
    rm -f "$tf"
  fi
  if [ -n "$j" ] && body=$(jq -er '.body // empty' <<<"$j" 2>/dev/null); then
    printf 'Linked comment (%s):\n%s\n' "$link" "$body"
  else
    printf 'Linked comment: %s (could not be read this tick)\n' "$link"
  fi
}

# bvb_brief <pr-url> <head> <findings> <reason> — the findings, plus the BLOCK
#   row's note (and what it links to) or the autopilot comment. Always rc 0.
bvb_brief() {
  local url="${1:--}" head findings="${3:-}" reason="${4:-}" slug num h12 rc=0 out l1 v vid vsrc rurl note="" add="" mark hdr body link
  head=$(printf '%s' "${2:-}" | tr 'A-F' 'a-f')
  if [ "$reason" != review-changes-requested ] || ! bvb_on || ! [[ "$head" =~ ^[0-9a-f]{40}$ ]] \
     || ! command -v vd_standing_note >/dev/null 2>&1 || ! slug=$(br_slug_of_url "$url"); then
    printf '%s' "$findings"; return 0
  fi
  num=$(mc_num_of_url "$url")
  [ -n "$num" ] || { printf '%s' "$findings"; return 0; }
  h12="${head:0:12}"
  out=$(vd_standing_note "$slug" "$num" "$head" </dev/null) || rc=$?
  if [ "$rc" = 0 ]; then
    l1="${out%%$'\n'*}"
    [[ "$out" == *$'\n'* ]] && note="${out#*$'\n'}"
    IFS=$'\t' read -r v vid vsrc rurl <<<"$l1"
    if [ "$v" = BLOCK ] && { [ "$vsrc" = human ] || [ "$vsrc" = lead ]; } && ! bvb_needs_human "$note"; then
      mark="(BLOCK verdict #$vid by $vsrc on $h12)"
      case "$findings" in
        *"$mark"*) ;;
        *) case "$rurl" in https://*) link="$rurl" ;; *) link=$(grep -oE 'https://[^][:space:]<>"()]+' <<<"$note" | head -1) ;; esac
           add=$(printf '%s%s\n\n%s\n' "${BR_LEAD_HDR:+$BR_LEAD_HDR$'\n'}" "$mark" "${note:-(the row carries no note)}")
           [ -n "$link" ] && add=$(printf '%s\n\n%s' "$add" "$(bvb_linked "$slug" "$num" "$link")") ;;
      esac
    fi
  elif [ "$rc" = 1 ] && [ "$(vd_box_word "$slug" "$num" "$head" </dev/null)" = BLOCK ]; then
    hdr="AUTOPILOT REVIEW FINDINGS (harness-review-autopilot on $h12)"
    case "$findings" in
      *"$hdr"*) ;;
      *) body=$(bvb_autopilot_comment "$slug" "$num" "$head") && add=$(printf '%s\n\n%s' "$hdr" "$body") ;;
    esac
  fi
  if [ -n "$add" ]; then br_findings_join "$findings" "$add"; else printf '%s' "$findings"; fi
  return 0
}
