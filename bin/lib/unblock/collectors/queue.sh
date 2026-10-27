#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/collectors/queue.sh — the queue family's stall collector for
# the unblock agent (BH-7723, UNB-1). Sourced, never run; nothing runs on source.
#
# It READS and prints JSONL stall records. It makes 0 writes and 0 model calls.
# Every GitHub call is `gh_rest GET` (the caller sources bin/lib/gh-rest.sh and
# arms the identity). The other inputs are read through functions the caller
# may have loaded: vd_standing (bin/lib/verdicts.sh), mc_attempt_has and
# mc_requeued_mark (bin/lib/mc/), setting_get (bin/lib/jobs/settings.sh). A
# function that is not loaded makes its field null (unknown), never false.
#
#   ub_collect_queue <project> <owner/repo>
#     The UNB-0 collector entry: bin/lib/unblock/collect.sh (ubc_collect)
#     sources this file in a subshell and calls ub_collect_<family> with these
#     two args. When gh_rest or vd_standing is not loaded yet it sources
#     $HARNESS/bin/lib/gh-rest.sh and bin/lib/verdicts.sh (the tick loads
#     neither). Prints the stall records of one repo, then rc 0. rc 1 only with no
#     $HARNESS/$H (D43) or a bad slug. A list that was not read prints one
#     {kind:"queue-unreadable", project, repo, input} record: an unread list is
#     never "nothing stalled". Two record kinds:
#
#     pr-ejected (U1, U2, U3): one per member of a merge batch draft that
#       failed (batch_state "failed" or "dead_shards") inside the window, while
#       the member is open and unmerged now. Fields: kind, project, repo, pr,
#       subject ("<repo>#<n>"), head (now), draft, batch_state, culprit (the one
#       culprit when the batch failed with exactly one, else null),
#       culprit_count, failed_paths, fail_lines (at most 40), own_ci
#       (green|red|running|none, from the tool's head_ci), verdict_on_head
#       (the standing word, "none" when nothing stands, null unread),
#       mergeable_state, ejected_on_head, requeued_on_head (bool, null
#       unknown), labels, stall_at (the draft's closed_at), truncated,
#       inputs_unreadable.
#     pr-approved-idle (U4): one per open, non-draft PR outside the queue
#       (no merge-queue, queued or checking label) with a MERGE or
#       MERGE-WITH-NOTES row standing on its head. Fields: kind, project,
#       repo, pr, subject, head, verdict_on_head, verdict_at,
#       verdict_has_notes, idle_min, approved_idle_min, standing_approval (the
#       row's value, "none" with no row, null unread), mergeable_state, checks
#       (green|running|red|none), changes_requested_open, touches_tests,
#       labels, stall_at (verdict_at), truncated, inputs_unreadable.
#
#     BH-8390 (UNB-7), three more:
#     pr-ejected on a FAILED batch also carries (bin/lib/unblock/signals.sh):
#       signals [{class, check, tokens}] (reg cat map pdb trace suite unread),
#       owned, signal (the first owned class), owns_failure (true, false only
#       when the whole diff was read and every signal is decidable, else
#       null), owners (the listed PRs that own a signal), owner_count,
#       trace_own_new, fix_brief, ticket (BH-<n> from ticket/bh-<n>),
#       fixrounds (pr_attempt_count kind fixrounds, null unread) and
#       fixround_max (UNBLOCK_FIXROUND_MAX). Per listed PR it reads
#       pulls/<n> and pulls/<n>/files (with the patches), and greps the hub
#       checkout's copy of each failing suite for the PR's file names.
#     pr-empty-block (U13-EMPTY, U13-EMPTY-CARD): one per open PR that
#       logs/lead-review-land.log says got a BLOCK report with no `- [BLOCK`
#       line. Fields: pr, head (now), logged_head12, head_current,
#       request_id (the newest), empty_blocks (lines for that PR and head),
#       verdict_on_head, priority (UNBLOCK_RERQ_PRIORITY), notes and
#       empty_block_max (UNBLOCK_EMPTY_BLOCK_MAX).
#     pr-verdict-old-head (U13-RESTAMP): an open PR outside the queue with
#       nothing standing on its head while its newest lead/human verdict is a
#       MERGE or MERGE-WITH-NOTES on an older head. Fields: old_head,
#       old_verdict, lead_request_open (null unread), idle_min (since the head
#       commit), restamp_idle_min (UNBLOCK_RESTAMP_IDLE_MIN), request_id
#       "none" (act.sh: no reset, a new request), priority.
#
#     A sub-read that fails sets its field to null and names it in
#     inputs_unreadable. Open PRs whose verdict was not read print one
#     {kind:"queue-unreadable", input:"verdicts", prs:[...]} record. A full page of 100 sets truncated:true on every
#     record of that list; a capped per-PR read is null, never "none found".
#
#   ubq_batch_drafts <owner/repo> <tmpdir>
#     The closed, unmerged mergify[bot] drafts on mergify/merge-queue/* closed
#     inside the window, as JSONL {draft, closed_at, truncated}. rc 1 unread.
#   ubq_batch_failure <owner/repo> <draft>
#     THE ONE SEAM to the #7714 batch_failure MCP tool: runs its handler from
#     $HARNESS/mcp/tools/batch-failure.mjs with node and prints its
#     structuredContent. rc 1 when the tool file, node or the console config is
#     missing, the answer isError, or it does not parse as an object.
#   ubq_drop_own < JSONL
#     Drops every record that carries a `<!-- tackler:` marker in any string,
#     or a `staff:` label: the agent never acts on its own trail.
#
# Knobs (env, set from the lane registry; code defaults are the fallbacks):
#   UNBLOCK_BATCH_WINDOW_H (6)      the drafts read, in hours
#   UNBLOCK_APPROVED_IDLE_MIN (20)  copied into approved_idle_min for U4
#   UNBLOCK_FIXROUND_MAX (2)        copied into fixround_max (U13 fix rounds)
#   UNBLOCK_LEAD_LOG_LINES (2000)   the lead-review-land.log lines read
#   UNBLOCK_RERQ_PRIORITY (900)     the lead request priority U13 asks for
#   UNBLOCK_RESTAMP_IDLE_MIN (20)   copied into restamp_idle_min
#   UNBLOCK_EMPTY_BLOCK_MAX (1)     copied into empty_block_max (U13-EMPTY re-requests)
#   UNBLOCK_SIGNAL_LINES (8)        failure lines kept per signal and in a brief
#   UNBLOCK_BRIEF_MAX_CHARS (1800)  the longest fix_brief
#   UNBLOCK_PATCH_MAX_CHARS (20000) the patch text kept per file for ownership
# Clock seam: UNBLOCK_NOW (epoch seconds).
# gh-rest: no-graphql

_ubq_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_ubq_now() { printf '%s' "${UNBLOCK_NOW:-$(date -u +%s)}"; }
_ubq_int() { # _ubq_int <value> <default>
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

ubq_batch_drafts() {
  local slug="$1" d="$2" f win
  f="$d/closed.json"
  gh_rest GET "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" > "$f" || return 1
  jq -e 'type == "array"' "$f" >/dev/null 2>&1 || return 1
  win=$(_ubq_int "${UNBLOCK_BATCH_WINDOW_H:-}" 6)
  jq -c --argjson now "$(_ubq_now)" --argjson win "$win" '
    (length >= 100) as $t
    | .[] | select(.user.login == "mergify[bot]" and ((.head.ref // "") | startswith("mergify/merge-queue/"))
                   and .merged_at == null and (.closed_at | type) == "string"
                   and ((.closed_at | fromdateiso8601) >= ($now - $win * 3600)))
    | {draft: .number, closed_at, truncated: $t}' "$f"
}

# node gets the tool path, the repo and the draft as arguments, never inside
# the program text. The tool's own console config comes from the environment
# (mcp/lib/config.mjs), as it does for the MCP server.
_UBQ_BF_JS='
import { pathToFileURL } from "node:url";
import { dirname, join } from "node:path";
const [tool, repo, draft] = process.argv.slice(1);
const mod = await import(pathToFileURL(tool).href);
const { loadConfig } = await import(pathToFileURL(join(dirname(tool), "..", "lib", "config.mjs")).href);
const t = (mod.tools || []).find((x) => x.name === "batch_failure");
if (!t) process.exit(1);
const args = { repo, draft: Number(draft) };
const ctx = { cfg: loadConfig(process.env) };
if (t.precheck && (await t.precheck(args, ctx))) process.exit(1);
const r = await t.handler(args, ctx);
if (!r || r.isError || !r.structuredContent) process.exit(1);
process.stdout.write(JSON.stringify(r.structuredContent));
'

ubq_batch_failure() {
  local h tool out
  h=$(_ubq_root); [ -n "$h" ] || return 1
  tool="$h/mcp/tools/batch-failure.mjs"
  [ -r "$tool" ] && command -v node >/dev/null 2>&1 || return 1
  out=$(node --input-type=module -e "$_UBQ_BF_JS" "$tool" "$1" "$2" 2>/dev/null) || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<< "$out" || return 1
  printf '%s\n' "$out"
}

ubq_drop_own() {
  jq -c 'select(([.. | strings | select(contains("<!-- tackler:"))] | length) == 0
                and ([(.labels // [])[] | strings | select(startswith("staff:"))] | length) == 0)'
}

# _ubq_verdict <slug> <num> <head>: prints "<word>\t<created_at>"; "none" when
# nothing stands; rc 1 (unknown) when the read failed or no reader is loaded.
_ubq_verdict() {
  local line rc=0
  type vd_standing >/dev/null 2>&1 || return 1
  line=$(vd_standing "$1" "$2" "$3") || rc=$?
  case "$rc" in
    0) printf '%s\t%s\n' "$(cut -f1 <<< "$line")" "$(cut -f4 <<< "$line")" ;;
    1) printf 'none\t\n' ;;
    *) return 1 ;;
  esac
}

# _ubq_mc <kind> <key> <head>: true|false|null.
_ubq_mc() {
  local rc=0 v
  case "$1" in
    ejected)
      type mc_attempt_has >/dev/null 2>&1 || { echo null; return; }
      mc_attempt_has "ejected $2 $3" >/dev/null 2>&1 || rc=$?
      case "$rc" in 0) echo true ;; 1) echo false ;; *) echo null ;; esac ;;
    requeued)
      type mc_requeued_mark >/dev/null 2>&1 || { echo null; return; }
      v=$(mc_requeued_mark "$2" "$3" 2>/dev/null) || { echo null; return; }
      if [ -n "$v" ]; then echo true; else echo false; fi ;;
  esac
}

_ubq_unreadable() { jq -nc --arg p "$1" --arg r "$2" --arg i "$3" '{kind: "queue-unreadable", project: $p, repo: $r, input: $i,
  subject_kind: "lane", subject: ("queue:" + $r + ":" + $i)}'; }
# _ubq_unreadable_pr <project> <slug> <input> <num>: the same marker for one
# PR (subject_kind pr), so a read that failed is a stall record, never silence.
_ubq_unreadable_pr() {
  jq -nc --arg p "$1" --arg r "$2" --arg i "$3" --argjson n "$4" \
    '{kind: "queue-unreadable", project: $p, repo: $r, input: $i, pr: $n, subject: "\($r)#\($n)", subject_kind: "pr"}'
}

_ubq_ejected() { # _ubq_ejected <project> <slug> <tmpdir> <draft json>
  local proj="$1" slug="$2" d="$3" dj="$4" draft bf n pf h head mstate labels open v vword ej rq unread
  draft=$(jq -r .draft <<< "$dj")
  bf="$d/bf-$draft.json"
  ubq_batch_failure "$slug" "$draft" > "$bf" || { _ubq_unreadable "$proj" "$slug" "batch_failure:$draft"; return 0; }
  jq -e '.batch_state == "failed" or .batch_state == "dead_shards"' "$bf" >/dev/null 2>&1 || return 0
  # BH-8390: on a red batch, what failed and which member owns it.
  local sigf="$d/sig-$draft.json" ownf ownj owners fr frmax
  echo null > "$sigf"
  if jq -e '.batch_state == "failed"' "$bf" >/dev/null 2>&1 && declare -F ub_signals_classify >/dev/null; then
    if ! { ub_signals_classify "$(_ubq_int "${UNBLOCK_SIGNAL_LINES:-}" 8)" < "$bf" > "$sigf" 2>/dev/null \
           && jq -e 'type == "array"' "$sigf" >/dev/null 2>&1; }; then
      echo null > "$sigf"; _ubq_unreadable "$proj" "$slug" "signals:$draft"
    fi
  fi
  owners=null
  if [ "$(cat "$sigf")" != null ]; then
    _ubq_owners "$slug" "$d" "$bf" "$sigf" "$draft"
    owners=$(jq -sc '[.[] | select(.owns == true) | .pr]' "$d"/own-"$draft"-*.json 2>/dev/null) || owners=null
  fi
  frmax=$(_ubq_int "${UNBLOCK_FIXROUND_MAX:-}" 2)
  for n in $(jq -r '.prs[]?.pr | numbers' "$bf"); do
    unread=()
    pf="$d/pull-$n.json"
    head=null mstate=null labels=null
    if { [ -s "$pf" ] || gh_rest GET "repos/$slug/pulls/$n" > "$pf"; } && jq -e 'type == "object"' "$pf" >/dev/null 2>&1; then
      open=$(jq -r '.state == "open" and (.merged // false) == false' "$pf")
      [ "$open" = true ] || continue
      head=$(jq -c '.head.sha // null' "$pf"); mstate=$(jq -c '.mergeable_state // null' "$pf")
      labels=$(jq -c '[.labels[]?.name]' "$pf")
    else
      unread+=(pull)
    fi
    vword=null ej=null rq=null
    if [ "$head" != null ]; then
      h=$(jq -r . <<< "$head")
      if v=$(_ubq_verdict "$slug" "$n" "$h"); then vword=$(jq -Rc 'split("\t")[0]' <<< "$v"); else unread+=(verdict); fi
      ej=$(_ubq_mc ejected "$slug#$n" "$h"); rq=$(_ubq_mc requeued "$slug#$n" "$h")
    fi
    jq -e '.complete == true' "$bf" >/dev/null 2>&1 || unread+=(batch_failure)
    ownf="$d/own-$draft-$n.json"; ownj=null; fr=null
    if [ -s "$ownf" ]; then
      ownj=$(jq -c '{owned, signal, owns_failure: .owns, trace_own_new, fix_brief: .brief, ticket}' "$ownf" 2>/dev/null) || ownj=null
      [ "$(jq -r '.files_read' "$ownf" 2>/dev/null)" = true ] || unread+=(files)
      fr=$(_ubq_fixrounds "$slug" "$n")
      [ "$fr" = null ] && unread+=(fixrounds)
    fi
    jq -c --arg proj "$proj" --arg slug "$slug" --argjson n "$n" --argjson head "$head" --argjson dj "$dj" \
      --argjson mstate "$mstate" --argjson labels "$labels" --argjson v "$vword" --argjson ej "$ej" --argjson rq "$rq" \
      --argjson sig "$(cat "$sigf")" --argjson own "$ownj" --argjson owners "$owners" --argjson fr "$fr" --argjson frmax "$frmax" \
      --argjson unread "$(printf '%s\n' "${unread[@]+"${unread[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
      def ci: if type == "object" then (.state // .conclusion) else . end | ascii_downcase? // null
        | if . == null or . == "" or . == "none" then "none"
          elif IN("success", "green", "passed") then "green"
          elif IN("pending", "running", "in_progress", "queued", "expected", "waiting") then "running"
          else "red" end;
      def num: if type == "object" then .pr // .number else . end;
      (.complete == true) as $ok
      | ((.culprits // []) | map(num)) as $cul
      | (.prs[] | select(.pr == $n)) as $m
      | {kind: "pr-ejected", project: $proj, repo: $slug, pr: $n, subject: "\($slug)#\($n)", head: $head,
         draft: $dj.draft,
         batch_state: (if $ok then .batch_state else null end),
         culprit: (if $ok and .batch_state == "failed" and ($cul | length) == 1 then $cul[0] else null end),
         culprit_count: (if $ok then ($cul | length) else null end),
         failed_paths: ([.failed_checks[]?.paths[]?] | unique),
         fail_lines: ([.failed_checks[]?.lines[]?] | .[0:40]),
         own_ci: (if $ok then ($m.head_ci | ci) else null end),
         verdict_on_head: $v, mergeable_state: $mstate,
         ejected_on_head: $ej, requeued_on_head: $rq, labels: $labels,
         stall_at: $dj.closed_at, truncated: $dj.truncated, inputs_unreadable: $unread}
      + (if $sig == null then {} else
          ($own // {owned: null, signal: null, owns_failure: null, trace_own_new: null, fix_brief: null, ticket: null}) as $o
          | {signals: [$sig[] | {class, check, tokens}], owned: $o.owned, signal: $o.signal,
             owns_failure: $o.owns_failure, owners: $owners,
             owner_count: (if $owners == null then null else ($owners | length) end),
             trace_own_new: $o.trace_own_new, fix_brief: $o.fix_brief,
             ticket: $o.ticket, fixrounds: $fr, fixround_max: $frmax} end)' "$bf"
  done
}

# _ubq_fixrounds <slug> <num>: the PR's fix rounds across every head
# (pr_attempt_count, kind fixrounds), or null when not loaded or unread.
_ubq_fixrounds() {
  local n rc=0
  type pr_attempt_count >/dev/null 2>&1 || { echo null; return; }
  n=$(pr_attempt_count "$1" "$2" fixrounds 2>/dev/null) || rc=$?
  case "$rc:$n" in 0:[0-9]*|2:[0-9]*) echo "$n" ;; *) echo null ;; esac
}

# _ubq_suite_reads <signals-file> <files-file>: {<suite>: [member files its
# text names]} for each `suite` signal token the hub checkout carries (the
# suite's inputs). {} when the files were not read.
_ubq_suite_reads() {
  local root suite f out='{}' hit
  root=$(_ubq_root)
  jq -e 'type == "array"' "$2" >/dev/null 2>&1 || { echo '{}'; return; }
  while IFS= read -r suite; do
    [ -n "$suite" ] && [[ $suite =~ ^tests/[A-Za-z0-9._/-]+\.sh$ ]] && [ -r "$root/$suite" ] || continue
    hit='[]'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -qF -- "$f" "$root/$suite" 2>/dev/null && hit=$(jq -c --arg f "$f" '. + [$f]' <<< "$hit")
    done < <(jq -r '.[].filename // empty' "$2")
    out=$(jq -c --arg s "$suite" --argjson h "$hit" '. + {($s): $h}' <<< "$out")
  done < <(jq -r '.[] | select(.class == "suite") | .tokens[]' "$1" | sort -u)
  printf '%s\n' "$out"
}

# _ubq_owners <slug> <tmpdir> <bf-file> <signals-file> <draft>: one
# own-<draft>-<n>.json per listed PR (ub_signals_own plus pr, ticket and
# files_read). The pull is read into pull-<n>.json, which _ubq_ejected reuses.
_ubq_owners() {
  local slug="$1" d="$2" bf="$3" sigf="$4" draft="$5" n pf ff mf ticket files complete
  for n in $(jq -r '.prs[]?.pr | numbers' "$bf"); do
    pf="$d/pull-$n.json"; ff="$d/files-$n.json"; mf="$d/member-$draft-$n.json"
    gh_rest GET "repos/$slug/pulls/$n" > "$pf" 2>/dev/null || : > "$pf"
    ticket=$(jq -r '(.head.ref // "") | capture("^ticket/bh-(?<n>[0-9]+([.][0-9]+)?)(-r[0-9]+)?$") | "BH-\(.n)"' "$pf" 2>/dev/null)
    files=false complete=false
    if gh_rest GET "repos/$slug/pulls/$n/files?per_page=100" > "$ff" 2>/dev/null && jq -e 'type == "array"' "$ff" >/dev/null 2>&1; then
      files=true; complete=$(jq 'length < 100' "$ff")
    else
      echo null > "$ff"
    fi
    jq -n --argjson n "$n" --argjson draft "$draft" --arg t "$ticket" --argjson complete "$complete" \
      --argjson pmax "$(_ubq_int "${UNBLOCK_PATCH_MAX_CHARS:-}" 20000)" \
      --slurpfile bf "$bf" --slurpfile f "$ff" --argjson reads "$(_ubq_suite_reads "$sigf" "$ff")" '
      ($bf[0]) as $b | ($f[0]) as $files
      | {pr: $n, draft: $draft, ticket: (if $t == "" then null else $t end), complete: $complete, reads: $reads,
         files: (if ($files | type) == "array" then [$files[] | {filename, status, patch: ((.patch // "") | .[0:$pmax])}] else null end),
         culprit_checks: [$b.failed_checks[]? | select(((.culprits // []) | map(if type == "object" then (.pr // .number) else . end) | index($n)) != null) | .name]}' \
      > "$mf" 2>/dev/null || continue
    ub_signals_own "$sigf" "$mf" "$(_ubq_int "${UNBLOCK_BRIEF_MAX_CHARS:-}" 1800)" "$(_ubq_int "${UNBLOCK_SIGNAL_LINES:-}" 8)" 2>/dev/null \
      | jq -c --argjson n "$n" --arg t "$ticket" --argjson fr "$files" \
          '. + {pr: $n, ticket: (if $t == "" then null else $t end), files_read: $fr}' > "$d/own-$draft-$n.json" \
      || rm -f "$d/own-$draft-$n.json"
  done
}

_ubq_checks() { # _ubq_checks <check-runs file>: green|running|red|none, or null (capped)
  jq -c '(.check_runs // []) as $c
    | if (.total_count // 0) > ($c | length) then null
      elif any($c[]; .status == "completed" and ((.conclusion // "") | IN("success", "neutral", "skipped") | not)) then "red"
      elif any($c[]; .status != "completed") then "running"
      elif ($c | length) == 0 then "none" else "green" end' "$1"
}

_ubq_approved() { # _ubq_approved <project> <slug> <tmpdir>
  local proj="$1" slug="$2" d="$3" f t n head labels v word at idle knob sa rc mstate checks cr tt unread
  local -a vunread=()
  f="$d/open.json"
  if ! gh_rest GET "repos/$slug/pulls?state=open&per_page=100" > "$f" || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    _ubq_unreadable "$proj" "$slug" open-pulls; return 0
  fi
  t=$(jq 'length >= 100' "$f")
  knob=$(_ubq_int "${UNBLOCK_APPROVED_IDLE_MIN:-}" 20)
  sa=null
  if type setting_get >/dev/null 2>&1; then
    rc=0; v=$(setting_get "unblock.standing_approval.$proj") || rc=$?
    case "$rc" in 0) sa=$(jq -Rc . <<< "$v") ;; 2) sa='"none"' ;; esac
  fi
  while IFS=$'\t' read -r n head labels; do
    [ -n "$n" ] || continue
    v=$(_ubq_verdict "$slug" "$n" "$head") || { vunread+=("$n"); continue; }
    word=${v%%$'\t'*}; at=${v#*$'\t'}
    if [ "$word" = none ]; then _ubq_old_head "$proj" "$slug" "$d" "$n" "$head" "$labels"; continue; fi
    case "$word" in MERGE|MERGE-WITH-NOTES) ;; *) continue ;; esac
    unread=()
    [ "$sa" = null ] && unread+=(standing_approval)
    idle=$(jq -n --arg at "$at" --argjson now "$(_ubq_now)" '(try ($at | fromdateiso8601) catch null) as $e | if $e == null then null else (($now - $e) / 60 | floor) end')
    [ "$idle" = null ] && unread+=(verdict_at)
    mstate=null checks=null cr=null tt=null
    if gh_rest GET "repos/$slug/pulls/$n" > "$d/pull-$n.json"; then mstate=$(jq -c '.mergeable_state // null' "$d/pull-$n.json"); else unread+=(pull); fi
    if gh_rest GET "repos/$slug/commits/$head/check-runs?per_page=100" > "$d/checks-$n.json" && checks=$(_ubq_checks "$d/checks-$n.json"); then
      [ "$checks" = null ] && unread+=(checks)
    else checks=null; unread+=(checks); fi
    if gh_rest GET "repos/$slug/pulls/$n/reviews?per_page=100" > "$d/reviews-$n.json" \
       && cr=$(jq -c 'if length >= 100 then null else
                 [.[] | select(.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))]
                 | group_by(.user.login) | map(sort_by(.submitted_at) | last) | any(.state == "CHANGES_REQUESTED") end' "$d/reviews-$n.json"); then
      [ "$cr" = null ] && unread+=(reviews)
    else cr=null; unread+=(reviews); fi
    if gh_rest GET "repos/$slug/pulls/$n/files?per_page=100" > "$d/files-$n.json" \
       && tt=$(jq -c 'any(.[].filename; test("(^|/)tests?/|\\.test\\.|\\.spec\\.|_test\\.")) as $hit
                 | if $hit then true elif length >= 100 then null else false end' "$d/files-$n.json"); then
      [ "$tt" = null ] && unread+=(files)
    else tt=null; unread+=(files); fi
    jq -nc --arg proj "$proj" --arg slug "$slug" --argjson n "$n" --arg head "$head" --arg word "$word" --arg at "$at" \
      --argjson idle "$idle" --argjson knob "$knob" --argjson sa "$sa" --argjson mstate "$mstate" --argjson checks "$checks" \
      --argjson cr "$cr" --argjson tt "$tt" --argjson labels "$labels" --argjson t "$t" \
      --argjson unread "$(printf '%s\n' "${unread[@]+"${unread[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
      {kind: "pr-approved-idle", project: $proj, repo: $slug, pr: $n, subject: "\($slug)#\($n)", head: $head,
       verdict_on_head: $word, verdict_at: $at, verdict_has_notes: ($word == "MERGE-WITH-NOTES"),
       idle_min: $idle, approved_idle_min: $knob, standing_approval: $sa, mergeable_state: $mstate,
       checks: $checks, changes_requested_open: $cr, touches_tests: $tt, labels: $labels,
       stall_at: $at, truncated: $t, inputs_unreadable: $unread}'
  done < <(jq -r '.[] | select((.draft // false) == false)
                 | [.labels[]?.name] as $l
                 | select(($l | index("merge-queue") or index("queued") or index("checking")) | not)
                 | (.head.sha // "") as $h | select($h != "")
                 | [.number, $h, ($l | tojson)] | @tsv' "$f")
  # An open PR whose verdict was not read is not "not approved": name them.
  if [ "${#vunread[@]}" -gt 0 ]; then
    _ubq_unreadable "$proj" "$slug" verdicts | jq -c --argjson prs "$(printf '%s\n' "${vunread[@]}" | jq -sc .)" '. + {prs: $prs}'
  fi
}

# THE TWO JOBS SEAMS (BH-8390), each rc 1 when unread or not loaded:
#   ubq_verdict_rows <slug> <num>  GET /api/verdicts?repo=&pr= (the PR's
#                                  verdict history, newest first)
#   ubq_lead_open <slug>           GET /api/lead-reviews?status=requested,running&repo=
ubq_verdict_rows() {
  type _jobs_req >/dev/null 2>&1 || return 1
  JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$1&pr=$2" 2>/dev/null
}
ubq_lead_open() {
  type _jobs_req >/dev/null 2>&1 || return 1
  JOBS_ALERT=0 _jobs_req GET "/api/lead-reviews?status=requested,running&repo=$1" 2>/dev/null
}

# _ubq_old_head <project> <slug> <tmpdir> <num> <head> <labels-json>: one
# pr-verdict-old-head record when nothing stands on the head, the PR's newest
# lead or human verdict is a MERGE or MERGE-WITH-NOTES on an OLDER head (a
# restamp or a main merge moved the head), and no lead request is open for
# this head. A verdict history that is unread or does not parse is one
# queue-unreadable record for the PR (subject_kind pr), never silence.
_ubq_old_head() {
  local proj="$1" slug="$2" d="$3" n="$4" head="$5" labels="$6" rows old lo=null cdate idle=null knob pri
  local -a unread=()
  rows=$(ubq_verdict_rows "$slug" "$n") || { _ubq_unreadable_pr "$proj" "$slug" verdict-history "$n"; return 0; }
  old=$(jq -c --arg h "$head" '[(if type == "object" then .rows else . end)[]? | select(type == "object" and ((.source // "") | IN("lead", "human")))]
      | first // null | if . == null or .head_sha == $h then null else {verdict, head_sha, id, created_at} end' <<< "$rows" 2>/dev/null) \
    || { _ubq_unreadable_pr "$proj" "$slug" verdict-history "$n"; return 0; }
  [ -n "$old" ] && [ "$old" != null ] || return 0
  case "$(jq -r '.verdict // ""' <<< "$old")" in MERGE|MERGE-WITH-NOTES) ;; *) return 0 ;; esac
  if [ ! -s "$d/lead-open.json" ]; then ubq_lead_open "$slug" > "$d/lead-open.json" || echo null > "$d/lead-open.json"; fi
  lo=$(jq -c --argjson n "$n" --arg h "$head" 'if type == "object" and (.requests | type) == "array" and (.truncated // false) == false
        then any(.requests[]; .pr == $n and .head_sha == $h) else null end' "$d/lead-open.json" 2>/dev/null) || lo=null
  [ "$lo" = null ] && unread+=(lead_requests)
  if gh_rest GET "repos/$slug/commits/$head" > "$d/commit-$n.json" 2>/dev/null; then
    cdate=$(jq -r '.commit.committer.date // ""' "$d/commit-$n.json" 2>/dev/null)
    idle=$(jq -n --arg at "$cdate" --argjson now "$(_ubq_now)" '(try ($at | fromdateiso8601) catch null) as $e | if $e == null then null else (($now - $e) / 60 | floor) end')
  fi
  [ "$idle" = null ] && unread+=(head_commit)
  knob=$(_ubq_int "${UNBLOCK_RESTAMP_IDLE_MIN:-}" 20)
  pri=$(_ubq_int "${UNBLOCK_RERQ_PRIORITY:-}" 900)
  jq -nc --arg proj "$proj" --arg slug "$slug" --argjson n "$n" --arg head "$head" --argjson old "$old" --argjson lo "$lo" \
    --argjson idle "$idle" --argjson knob "$knob" --argjson pri "$pri" --argjson labels "$labels" \
    --argjson unread "$(printf '%s\n' "${unread[@]+"${unread[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
    {kind: "pr-verdict-old-head", project: $proj, repo: $slug, pr: $n, subject: "\($slug)#\($n)", head: $head,
     verdict_on_head: "none", old_head: $old.head_sha, old_verdict: $old.verdict, old_verdict_id: $old.id,
     old_verdict_at: $old.created_at, lead_request_open: $lo, idle_min: $idle, restamp_idle_min: $knob,
     request_id: "none", priority: $pri, labels: $labels, stall_at: $old.created_at, truncated: false,
     inputs_unreadable: $unread}'
}

# _ubq_empty_block <project> <slug> <tmpdir>: one pr-empty-block record per
# open PR that bin/lead-review-land.sh logged "BLOCK report has no finding
# line" for, in the last UNBLOCK_LEAD_LOG_LINES lines of
# logs/lead-review-land.log. empty_blocks counts those lines for the PR and
# head; request_id is the newest one. No log file = no record; a log that
# exists and cannot be read = one queue-unreadable record.
_ubq_empty_block() {
  local proj="$1" slug="$2" d="$3" root log nl ev pr h12 rid cnt pf head open labels v vword pri ebmax
  local -a unread=()
  root=$(_ubq_root); log="$root/logs/lead-review-land.log"
  [ -e "$log" ] || return 0
  [ -r "$log" ] || { _ubq_unreadable "$proj" "$slug" lead-review-land-log; return 0; }
  nl=$(_ubq_int "${UNBLOCK_LEAD_LOG_LINES:-}" 2000)
  pri=$(_ubq_int "${UNBLOCK_RERQ_PRIORITY:-}" 900)
  ebmax=$(_ubq_int "${UNBLOCK_EMPTY_BLOCK_MAX:-}" 1)
  while IFS=$'\t' read -r pr h12 rid cnt; do
    [ -n "$pr" ] || continue
    unread=()
    pf="$d/eb-pull-$pr.json"
    gh_rest GET "repos/$slug/pulls/$pr" > "$pf" 2>/dev/null && jq -e 'type == "object"' "$pf" >/dev/null 2>&1 \
      || { _ubq_unreadable "$proj" "$slug" "pull:$pr"; continue; }
    open=$(jq -r '.state == "open" and (.merged // false) == false' "$pf")
    [ "$open" = true ] || continue
    head=$(jq -r '.head.sha // ""' "$pf"); labels=$(jq -c '[.labels[]?.name]' "$pf")
    vword=null
    if v=$(_ubq_verdict "$slug" "$pr" "$head"); then vword=$(jq -Rc 'split("\t")[0]' <<< "$v"); else unread+=(verdict); fi
    jq -nc --arg proj "$proj" --arg slug "$slug" --argjson n "$pr" --arg head "$head" --arg h12 "$h12" --arg rid "$rid" \
      --argjson cnt "$cnt" --argjson v "$vword" --argjson pri "$pri" --argjson labels "$labels" --argjson ebmax "$ebmax" \
      --argjson unread "$(printf '%s\n' "${unread[@]+"${unread[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
      {kind: "pr-empty-block", project: $proj, repo: $slug, pr: $n, subject: "\($slug)#\($n)", head: $head,
       logged_head12: $h12, head_current: ($head | startswith($h12)), request_id: $rid, empty_blocks: $cnt,
       empty_block_max: $ebmax,
       verdict_on_head: $v, priority: $pri, notes: "write each finding as a - [BLOCK <class>] line",
       labels: $labels, truncated: false, inputs_unreadable: $unread}'
  done < <(tail -n "$nl" "$log" 2>/dev/null | jq -Rnr --arg slug "$slug" '
      [inputs | capture("(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(?<pr>[0-9]+) @(?<h12>[0-9a-f]{12}) lead review (?<id>[A-Za-z0-9_-]+): BLOCK report has no finding line")
       | select(.repo == $slug)]
      | group_by(.pr + " " + .h12) | .[] | [.[0].pr, .[0].h12, (last | .id), length] | @tsv')
}

ub_collect_queue() {
  local proj="${1:-}" slug="${2:-}" d dj root
  root=$(_ubq_root)
  [ -n "$root" ] || return 1
  # shellcheck disable=SC1091
  declare -F gh_rest >/dev/null || . "$root/bin/lib/gh-rest.sh" 2>/dev/null || true
  # shellcheck disable=SC1091
  declare -F vd_standing >/dev/null || . "$root/bin/lib/verdicts.sh" 2>/dev/null || true
  # shellcheck source=bin/lib/unblock/signals.sh
  declare -F ub_signals_classify >/dev/null || . "$root/bin/lib/unblock/signals.sh" 2>/dev/null || true
  [ -n "$proj" ] && [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  d=$(mktemp -d "${TMPDIR:-/tmp}/ubq.XXXXXX") || return 1
  {
    if ubq_batch_drafts "$slug" "$d" > "$d/drafts.jsonl"; then
      while IFS= read -r dj; do
        [ -n "$dj" ] && _ubq_ejected "$proj" "$slug" "$d" "$dj"
      done < "$d/drafts.jsonl"
    else
      _ubq_unreadable "$proj" "$slug" closed-pulls
    fi
    _ubq_approved "$proj" "$slug" "$d"
    _ubq_empty_block "$proj" "$slug" "$d"
  } | ubq_drop_own
  rm -rf "$d"
  return 0
}
