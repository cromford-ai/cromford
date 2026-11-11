#!/bin/bash
# bin/lib/slice-gate.sh — the fewest children a decompose spec can file
# (BH-8739, the operator 2026-10-28; rules/topics/12-qa-findings.md). Sourced, never
# executed: no `set -e`, no `exit`, nothing written at source time, safe under
# the caller's `set -u`.
#
# THE RULE. A parent is sliced only for one of three reasons:
#   file-overlap     the slice edits a path the open child, or child 2 or a
#                    later one, edits, so the two must not build at the same
#                    time (a path only child 1 owns is no reason: every later
#                    child waits on child 1, and the child that takes the slice
#                    stays blocked on it)
#   context-ceiling  the slice would push one child past the build-execute
#                    context ceiling (catalog/context-budgets.json)
#   ordering         the slice imports code of an earlier sibling (`after`)
# No reason, no slice: every other slice joins the child before it, and each
# filed child's body opens with `Slice reason: <class>: <why>`.
#
#   sr_ceiling_tokens [project]          the build-execute ceiling_tokens
#   sr_expected <build-dir>              SIZE_SLICES_EXPECTED of size-gate.txt, or 0
#   sr_coalesce <in> <out> <ceiling> <tokens-per-line>
#        rc 0 written; rc 2 legacy (no slice has est_lines, <out> = <in>);
#        rc 1 bad (some slices have a numeric est_lines, some do not)
#   sr_proposal_body <KEY> <merged.json> <expected> <confirm-over>
#   sr_proposal_state <KEY> <thread.json> <issues|board>
#        prints none | waiting | confirmed; rc 2 (prints unreadable) when the
#        thread cannot be read. Sets SR_HOLD to the hold verdict (issues lane).
#   sr_knob <project> <ENV> <default>    a slice-gate knob, digits only
#   sr_gate <project> <KEY> <issues|board> <build> <spec> <slug> <issue> <ticket> <dry>
#        what bin/run-decompose.sh calls: coalesce, then ask before a split
#        above SLICE_CONFIRM_OVER (rc table above the function). Its reads and
#        writes: sr_thread (DECOMPOSE_THREAD_FILE is the test seam), sr_post
#        (one comment on the parent) and sr_hold (bin/needs-human-hold.sh).
#        A dry run prints each write as a DRYRUN line.
#
# Knobs (catalog/lanes.d/_lib.slice-gate.json, per project through
# lib_env_apply slice-gate <project>): SLICE_GATE, SLICE_TOKENS_PER_LINE,
# SLICE_CONFIRM_OVER, SLICE_CEILING_TOKENS.
if [ -n "${SLICE_GATE_LIB:-}" ]; then return 0 2>/dev/null; fi
SLICE_GATE_LIB=1
_SR_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=bin/lib/hold.sh
command -v hold_classify >/dev/null 2>&1 || { [ -r "$_SR_DIR/hold.sh" ] && . "$_SR_DIR/hold.sh"; }

# sr_knob <project> <ENV> <default> — in a subshell so one project's row never
# leaks into the caller. A value that is not digits is the default.
sr_knob() {
  local v
  v=$( if ! command -v lib_env_apply >/dev/null 2>&1 && [ -r "$_SR_DIR/lane-gate.sh" ]; then
         # shellcheck source=bin/lib/lane-gate.sh
         . "$_SR_DIR/lane-gate.sh" 2>/dev/null
       fi
       command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply slice-gate "${1:-}" >/dev/null 2>&1
       printf '%s' "${!2:-}" )
  case "$v" in ''|*[!0-9]*) v="$3" ;; esac
  printf '%s' "$v"
}

# sr_ceiling_tokens [project] — ceiling_tokens of lane build-execute: the
# composed manifest ($CONTEXT_BUDGETS, then $HARNESS/catalog/context-budgets.json),
# then its fragments ($HARNESS/catalog/context-budgets.d), then the knob
# SLICE_CEILING_TOKENS (fallback 500000 = build-execute.ceiling_tokens in
# catalog/context-budgets.d/0000-base.json).
sr_ceiling_tokens() {
  local root="${HARNESS:-${H:-}}" f v=""
  for f in "${CONTEXT_BUDGETS:-}" "${root:+$root/catalog/context-budgets.json}"; do
    [ -n "$f" ] && [ -r "$f" ] || continue
    v=$(jq -r 'first(.lanes[]? | select(.lane == "build-execute") | .ceiling_tokens | numbers) // empty' "$f" 2>/dev/null)
    [ -n "$v" ] && break
  done
  if [ -z "$v" ] && [ -n "$root" ] && [ -d "$root/catalog/context-budgets.d" ]; then
    v=$(cat "$root"/catalog/context-budgets.d/[0-9]*.json 2>/dev/null \
      | jq -rs 'first(.[][]? | select(.lane? == "build-execute") | .ceiling_tokens | numbers) // empty' 2>/dev/null)
  fi
  v="${v%%.*}"
  case "$v" in ''|*[!0-9]*|0) v=$(sr_knob "${1:-}" SLICE_CEILING_TOKENS 500000) ;; esac
  printf '%s' "$v"
}

# sr_expected <build-dir> — the last SIZE_SLICES_EXPECTED of size-gate.txt, or 0.
sr_expected() {
  local v
  v=$(sed -n 's/^SIZE_SLICES_EXPECTED:[[:space:]]*//p' "${1:-}/size-gate.txt" 2>/dev/null | tail -1)
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# The coalesce program. Greedy, in spec order; slice 1 opens child 1. A slice
# opens a new child only with a reason (ordering, then file-overlap, then the
# context ceiling); otherwise it joins the open child.
_SR_JQ='
def pnum: tostring | (split(":")[0] | gsub("\\s"; "")) as $p
  | if ($p | test("^[0-9]+$")) then ($p | tonumber) else null end;
def psym: tostring | if test(":") then sub("^[^:]*:\\s*"; "") else "" end;
def npath: tostring | sub("^(\\./)+"; "");
def uniq: reduce .[] as $v ([]; if index([$v]) then . else . + [$v] end);
. as $s
| reduce range(0; $s | length) as $i ({g: [], of: []};
    $s[$i] as $x | ($i + 1) as $n
    | if $i == 0 then .g = [{m: [0], est: $x.est_lines, refs: [], reason: null}] | .of = [0]
      else
        . as $st
        | [($x.after // [])[] | {p: pnum, sym: psym} | select(.p != null and .p >= 2 and .p < $n)] as $ord
        | [($x.owns // [])[] | npath] as $mine
        | ((.g | length) - 1) as $open
        | [range(0; $i) as $j | ($s[$j].owns // [])[] | npath as $q
            | select($mine | index([$q])) | {j: $j, path: $q, g: $st.of[$j]}] as $all
        # A path child 1 owns is no reason while child 1 is closed: every later
        # child is blocked on child 1 anyway (the seam pattern). The child that
        # takes such a slice is kept blocked on child 1 (c1).
        | [$all[] | select(.g == $open or .g > 0)] as $ovl
        | ([$all[] | select(.g == 0)] | length > 0) as $c1
        | (($st.g[-1].est + $x.est_lines) * $tpl) as $tok
        | (if ($ord | length) > 0 then
             "ordering: must merge after \"\($s[$ord[0].p - 1].title)\""
               + (if $ord[0].sym != "" then " (\($ord[0].sym))" else "" end)
           elif ($ovl | length) > 0 then
             "file-overlap: \($ovl[0].path) is also edited by \"\($s[$ovl[0].j].title)\""
           elif $tok > $ceil then
             "context-ceiling: \($tok) tokens would pass the build-execute ceiling of \($ceil)"
           else null end) as $why
        | if $why == null then
            .g[-1].m += [$i] | .g[-1].est += $x.est_lines | .of += [(.g | length) - 1]
            | if $c1 then .g[-1].c1 = true else . end
          else
            ([$ord[] | {g: $st.of[.p - 1], a: .sym}] + [$ovl[] | {g, a: "same file \(.path)"}]) as $refs
            | .g += [{m: [$i], est: $x.est_lines, refs: $refs, reason: $why, c1: $c1}] | .of += [(.g | length) - 1]
          end
      end)
| .g as $G
| ([$G[1:][] | .reason | split(":")[0]] | uniq) as $classes
| [range(0; $G | length) as $k | $G[$k] as $grp
    | [$grp.m[] | $s[.]] as $mem
    | (if $k > 0 then $grp.reason
       elif ($G | length) == 1 then "none: one child"
       else "first slice: lands first; the rest split off for \($classes | join(", "))" end) as $r
    | {title: ($mem[0].title + (if ($mem | length) > 1 then " (+\(($mem | length) - 1) more)" else "" end))}
      + (if $k == 0 and ($s[0] | has("contract")) then {contract: $s[0].contract} else {} end)
      + {owns: ([$mem[] | (.owns // [])[]] | uniq),
         est_lines: ($mem | map(.est_lines) | add),
         after: ([$grp.refs[] | select(.g > 0 and .g != $k) | "\(.g + 1)" + (if .a != "" then ": \(.a)" else "" end)] | uniq),
         reason: $r}
      + (if $k > 0 and all($mem[]; .imports_contract == false) and all($grp.refs[]; .g > 0) and (($grp.c1 // false) | not)
         then {imports_contract: false} else {} end)
      + {body: ("Slice reason: " + $r + "\n\n"
                + ([$mem[] | "### " + .title + "\n\n" + (.body // "")] | join("\n\n---\n\n")))}]
'

# sr_coalesce <in.json> <out.json> <ceiling> <tokens-per-line>
sr_coalesce() {
  local in="${1:-}" out="${2:-}" ceil="${3:-}" tpl="${4:-}" have total
  case "$ceil" in ''|*[!0-9]*) return 1 ;; esac
  case "$tpl" in ''|*[!0-9]*) return 1 ;; esac
  jq -e 'type == "array" and length > 0' "$in" >/dev/null 2>&1 || return 1
  total=$(jq 'length' "$in")
  have=$(jq '[.[] | select((.est_lines | type) == "number" and .est_lines >= 0)] | length' "$in")
  if [ "$have" = 0 ] && jq -e 'all(.[]; has("est_lines") | not)' "$in" >/dev/null 2>&1; then
    [ "$in" = "$out" ] || cp "$in" "$out" || return 1
    return 2
  fi
  [ "$have" = "$total" ] || return 1
  # Already coalesced (every child carries its reason): unchanged, so the
  # gate is idempotent on its own output.
  if jq -e 'all(.[]; ((.reason | type) == "string") and ((.body // "") | startswith("Slice reason: ")))' "$in" >/dev/null 2>&1; then
    [ "$in" = "$out" ] || cp "$in" "$out" || return 1
    return 0
  fi
  jq --argjson ceil "$ceil" --argjson tpl "$tpl" "$_SR_JQ" "$in" > "$out.tmp" 2>/dev/null \
    && jq -e 'type == "array" and length > 0' "$out.tmp" >/dev/null 2>&1 \
    && mv -f "$out.tmp" "$out" || { rm -f "$out.tmp"; return 1; }
  return 0
}

# sr_marker <KEY> — the first line of a proposal comment.
sr_marker() { printf '<!-- decompose-proposal: %s -->' "${1:-}"; }

# sr_proposal_body <KEY> <merged.json> <expected> <confirm-over>
sr_proposal_body() {
  local key="$1" spec="$2" exp="${3:-0}" over="${4:-5}" n
  n=$(jq 'length' "$spec" 2>/dev/null) || return 1
  sr_marker "$key"; printf '\n'
  printf 'Hi! This one is bigger than we build in one go, so we want your OK on the split before we file anything.\n\n'
  printf 'The size estimate is %s slices. Merged to the fewest tickets, the split is %s tickets:\n\n' "$exp" "$n"
  jq -r 'to_entries[] | "\(.key + 1). **\(.value.title)**. Why it stands alone: \(.value.reason // "not stated"). Files: \((.value.owns // []) | join(", ") | if . == "" then "not listed" else . end)"' "$spec"
  printf '\nWe file more than %s tickets for one ask only after a person says yes. ' "$over"
  printf 'Reply on this ticket with a line that starts `HUMAN-STEP-DONE:` (add any change to the grouping on the same comment) and we file the children.\n'
}

# sr_proposal_state <KEY> <thread.json> <issues|board>
#   issues: the thread is {issue: <REST issue>, comments: [<REST comment>]};
#           confirmed when bin/lib/hold.sh lifts the hold (lifted-by-human-step
#           or lifted-by-comment) AFTER the newest proposal comment.
#   board:  the thread is a normalized ticket ({comments: [{author, body,
#           createdAt}]}); confirmed when a comment after the newest proposal
#           carries no marker and (when both have one) another author.
sr_proposal_state() {
  local key="$1" th="$2" lane="${3:-issues}" mk at verdict tail lat
  SR_HOLD=""
  jq -e 'type == "object" and ((.comments // null) | type) == "array"' "$th" >/dev/null 2>&1 \
    || { echo unreadable; return 2; }
  mk=$(sr_marker "$key")
  # The newest comment whose FIRST line is the marker for this KEY, exactly.
  at=$(jq -r --arg m "$mk" '
    [.comments | to_entries[] | select(((.value.body // "") | split("\n")[0] | sub("\\s+$"; "")) == $m)]
    | if length == 0 then "" else (last | "\(.key)\t\(.value.created_at // .value.createdAt // "")") end' "$th" 2>/dev/null)
  [ -n "$at" ] || { echo none; return 0; }
  if [ "$lane" = board ]; then
    if jq -e --arg m "$mk" --argjson i "${at%%	*}" '
        def who: (.author // .user.login // null) | if type == "object" then (.name // .login // null) else . end;
        .comments[$i] as $p
        | any(.comments[$i + 1:][]; ((.body // "") | contains($m) | not)
              and (((who) == null) or (($p | who) == null) or ((who) != ($p | who))))' "$th" >/dev/null 2>&1; then
      echo confirmed
    else
      echo waiting
    fi
    return 0
  fi
  command -v hold_classify >/dev/null 2>&1 || { echo unreadable; return 2; }
  verdict=$(hold_classify "$(jq -c '.issue // {}' "$th")" "$(jq -c '.comments' "$th")" 2>/dev/null)
  SR_HOLD="$verdict"
  tail="${verdict#*	}"
  case "$verdict" in
    clear*lifted-by-human-step*|clear*lifted-by-comment*)
      lat=$(printf '%s' "$tail" | awk '{print $2}')
      # ISO-8601 UTC sorts as text: the lift must come after the proposal.
      if [ -n "$lat" ] && [ -n "${at#*	}" ] && [[ "$lat" > "${at#*	}" ]]; then echo confirmed; else echo waiting; fi ;;
    unreadable*) echo unreadable; return 2 ;;
    *) echo waiting ;;
  esac
  return 0
}

# --- the gate the decomposer calls --------------------------------------------
# sr_thread <project> <lane> <slug> <issue> <ticket> — the parent thread on
# stdout, in the shape sr_proposal_state reads. DECOMPOSE_THREAD_FILE is the
# dry-run and test seam. rc 1 when it cannot be read whole.
sr_thread() {
  local p="$1" lane="$2" slug="$3" n="$4" tid="$5" i c rc=0
  if [ -n "${DECOMPOSE_THREAD_FILE:-}" ]; then cat "$DECOMPOSE_THREAD_FILE"; return; fi
  if [ "$lane" = board ]; then
    ( command -v tracker_context >/dev/null 2>&1 || . "$_SR_DIR/tracker.sh" 2>/dev/null
      tracker_context "$p" run-decompose >/dev/null 2>&1 && tracker_read "$tid" )
    return
  fi
  command -v gh_rest >/dev/null 2>&1 || . "$_SR_DIR/gh-rest.sh" 2>/dev/null
  command -v gh_rest_issue_comments >/dev/null 2>&1 || . "$_SR_DIR/gh-rest-list.sh" 2>/dev/null
  command -v gh_rest_issue_comments >/dev/null 2>&1 || return 1
  i=$(mktemp "${TMPDIR:-/tmp}/sr-th.XXXXXX") || return 1
  c=$(mktemp "${TMPDIR:-/tmp}/sr-th.XXXXXX") || { rm -f "$i"; return 1; }
  gh_rest GET "repos/$slug/issues/$n" > "$i" || rc=1
  [ "$rc" = 0 ] && { gh_rest_issue_comments "$slug" "$n" 200 > "$c" || rc=1; }
  # A thread at the cap is not the whole thread: never decide on it.
  [ "$rc" = 0 ] && { jq -e 'type == "array" and length < 200' "$c" >/dev/null 2>&1 || rc=1; }
  [ "$rc" = 0 ] && jq -n --slurpfile i "$i" --slurpfile c "$c" '{issue: $i[0], comments: $c[0]}'
  rm -f "$i" "$c"
  return "$rc"
}

# sr_post <project> <lane> <slug> <issue> <ticket> <bodyfile> <dry> — one
# comment on the parent; a dry run prints it instead. rc 0 only when posted.
sr_post() {
  local p="$1" lane="$2" slug="$3" n="$4" tid="$5" f="$6" dry="${7:-0}"
  if [ "$lane" = board ]; then
    [ "$dry" = 1 ] && { printf 'DRYRUN board comment on %s (body %s)\n' "$tid" "$f"; return 0; }
    ( command -v tracker_context >/dev/null 2>&1 || . "$_SR_DIR/tracker.sh" 2>/dev/null
      tracker_context "$p" run-decompose >/dev/null 2>&1 && tracker_comment "$tid" "$f" >/dev/null 2>&1 )
    return
  fi
  [ "$dry" = 1 ] && { printf 'DRYRUN gh api -X POST repos/%s/issues/%s/comments -F body=@%s\n' "$slug" "$n" "$f"; return 0; }
  command -v trk_gh_comment >/dev/null 2>&1 || . "$_SR_DIR/tracker/github-issues.sh" 2>/dev/null
  command -v trk_gh_comment >/dev/null 2>&1 || return 1
  TRK_SLUG="$slug" TRK_LOG="" TRK_DRY=0 trk_gh_comment "$n" "$f" >/dev/null 2>&1
}

# sr_hold <project> <issue> <action> <dry> — the NEEDS-HUMAN hold on an issues
# parent (bin/needs-human-hold.sh dedupes on the fingerprint). rc of the script.
sr_hold() {
  local p="$1" n="$2" act="$3" dry="${4:-0}" root="${HARNESS:-${H:-}}" fp
  command -v nh_fingerprint >/dev/null 2>&1 || . "$_SR_DIR/needs-human.sh" 2>/dev/null
  fp=$(nh_fingerprint "$act" 2>/dev/null) || fp=""
  case "$fp" in ''|*[!0-9a-f]*) fp=$(printf '%s' "$act" | sha1sum | cut -c1-12) ;; esac
  [ "$dry" = 1 ] && { printf 'DRYRUN needs-human-hold.sh %s %s %s %s decompose\n' "$p" "$n" "$fp" "$act"; return 0; }
  [ -n "$root" ] && [ -x "$root/bin/needs-human-hold.sh" ] || return 1
  "$root/bin/needs-human-hold.sh" "$p" "$n" "$fp" "$act" decompose >/dev/null 2>&1 </dev/null
}

# sr_gate <project> <KEY> <issues|board> <build> <spec> <slug> <issue> <ticket> <dry>
# Coalesces <spec> in place (the model's copy stays in children.proposed.json),
# then asks before a split above SLICE_CONFIRM_OVER. SR_LOG_FN names the
# caller's log function. rc:
#   0 file the spec; SR_UPPER is the most children the caller may file
#   1 refuse (SR_MSG says why)          3 held (SR_MSG is the DECOMPOSE_HELD line)
#   4 one child: build the parent whole (SR_MSG is the DECOMPOSE_NOT_NEEDED line)
#   5 the gate is off (SLICE_GATE=0): file as before
sr_gate() {
  local p="$1" key="$2" lane="$3" b="$4" spec="$5" slug="$6" n="$7" tid="$8" dry="${9:-0}"
  local log="${SR_LOG_FN:-:}" prop="$4/children.proposed.json" root="${HARNESS:-${H:-}}"
  local ceil tpl over pn cn rc exp count merged=0 th st body act
  SR_MSG=""; SR_UPPER=5; SR_N=""
  if [ "$(sr_knob "$p" SLICE_GATE 1)" = 0 ]; then
    "$log" "SLICE_GATE: off (SLICE_GATE=0), the spec files as written"; return 5
  fi
  [ -s "$prop" ] || cp "$spec" "$prop" 2>/dev/null || { SR_MSG="could not keep the proposed spec as $prop"; return 1; }
  tpl=$(sr_knob "$p" SLICE_TOKENS_PER_LINE 400); [ "$tpl" -gt 0 ] || tpl=400
  over=$(sr_knob "$p" SLICE_CONFIRM_OVER 5)
  ceil=$(sr_ceiling_tokens "$p")
  pn=$(jq 'length' "$prop" 2>/dev/null)
  sr_coalesce "$prop" "$spec" "$ceil" "$tpl"; rc=$?
  case "$rc" in
    0) merged=1 ;;
    2) "$log" "SLICE_GATE: legacy spec (no est_lines), not coalesced" ;;
    *) SR_MSG="every slice needs est_lines, or none"; return 1 ;;
  esac
  cn=$(jq 'length' "$spec" 2>/dev/null); SR_N="$cn"
  [ "$merged" = 1 ] && "$log" "SLICE_GATE: $pn slices -> $cn children ($(jq -r '[.[] | .reason // "none" | split(":")[0]] | group_by(.) | map("\(length) \(.[0])") | join(", ")' "$spec" 2>/dev/null); ceiling $ceil tokens at $tpl per line)"
  exp=$(sr_expected "$b"); count="$cn"; [ "$exp" -gt "$count" ] && count="$exp"
  if { [ "$merged" = 1 ] || [ "$exp" -gt "$over" ]; } && [ "$count" -gt "$over" ]; then
    th="$b/decompose-thread.json"
    sr_thread "$p" "$lane" "$slug" "$n" "$tid" > "$th" 2>/dev/null || : > "$th"
    # In this shell, not in $( ): SR_HOLD must reach the waiting arm below.
    SR_HOLD=""; sr_proposal_state "$key" "$th" "$lane" > "$th.state"; st=$(cat "$th.state" 2>/dev/null)
    act="confirm the proposed split of $key into $count tickets (see the proposal comment)"
    SR_MSG="DECOMPOSE_HELD: awaiting a reply to the proposed split into $count children"
    case "$st" in
      confirmed)
        "$log" "SLICE_GATE: the proposed split into $count children is confirmed on the thread, filing $cn"
        SR_MSG=""; [ "$cn" -gt "$SR_UPPER" ] && SR_UPPER="$cn" ;;
      none)
        body="$b/decompose-proposal.md"
        sr_proposal_body "$key" "$spec" "$exp" "$over" > "$body" \
          || { SR_MSG="could not write the proposal comment"; return 1; }
        sr_post "$p" "$lane" "$slug" "$n" "$tid" "$body" "$dry" \
          || { SR_MSG="the proposed split did not post on the parent"; return 1; }
        "$log" "SLICE_GATE: posted the proposed split into $count children on the parent"
        if [ "$lane" = issues ] && ! sr_hold "$p" "$n" "$act" "$dry"; then
          "$log" "WARN: the needs-human hold was not placed on #$n; the next run places it again"
          [ -n "$root" ] && [ -x "$root/bin/alert-line.sh" ] \
            && "$root/bin/alert-line.sh" --project "$p" "$key: the needs-human hold for the proposed split did not place on #$n" >/dev/null 2>&1 </dev/null
        fi
        return 3 ;;
      waiting)
        if [ "$lane" = issues ]; then
          case "$SR_HOLD" in clear*no-hold*)
            "$log" "SLICE_GATE: the proposal is on #$n but its hold is not; placing it again"
            sr_hold "$p" "$n" "$act" "$dry" || "$log" "WARN: the needs-human hold was not placed on #$n" ;;
          esac
        fi
        return 3 ;;
      *)
        SR_MSG="$SR_MSG (thread unreadable)"; return 3 ;;
    esac
  fi
  if [ "$merged" = 1 ] && [ "$cn" = 1 ]; then
    SR_MSG="DECOMPOSE_NOT_NEEDED: no slice has a reason to stand alone ($pn slices fit one build)"
    return 4
  fi
  return 0
}
