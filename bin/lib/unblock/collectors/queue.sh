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

_ubq_ejected() { # _ubq_ejected <project> <slug> <tmpdir> <draft json>
  local proj="$1" slug="$2" d="$3" dj="$4" draft bf n pf h head mstate labels open v vword ej rq unread
  draft=$(jq -r .draft <<< "$dj")
  bf="$d/bf-$draft.json"
  ubq_batch_failure "$slug" "$draft" > "$bf" || { _ubq_unreadable "$proj" "$slug" "batch_failure:$draft"; return 0; }
  jq -e '.batch_state == "failed" or .batch_state == "dead_shards"' "$bf" >/dev/null 2>&1 || return 0
  for n in $(jq -r '.prs[]?.pr | numbers' "$bf"); do
    unread=()
    pf="$d/pull-$n.json"
    head=null mstate=null labels=null
    if gh_rest GET "repos/$slug/pulls/$n" > "$pf" && jq -e 'type == "object"' "$pf" >/dev/null 2>&1; then
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
    jq -c --arg proj "$proj" --arg slug "$slug" --argjson n "$n" --argjson head "$head" --argjson dj "$dj" \
      --argjson mstate "$mstate" --argjson labels "$labels" --argjson v "$vword" --argjson ej "$ej" --argjson rq "$rq" \
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
         stall_at: $dj.closed_at, truncated: $dj.truncated, inputs_unreadable: $unread}' "$bf"
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

ub_collect_queue() {
  local proj="${1:-}" slug="${2:-}" d dj root
  root=$(_ubq_root)
  [ -n "$root" ] || return 1
  # shellcheck disable=SC1091
  declare -F gh_rest >/dev/null || . "$root/bin/lib/gh-rest.sh" 2>/dev/null || true
  # shellcheck disable=SC1091
  declare -F vd_standing >/dev/null || . "$root/bin/lib/verdicts.sh" 2>/dev/null || true
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
  } | ubq_drop_own
  rm -rf "$d"
  return 0
}
