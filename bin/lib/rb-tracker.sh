#!/bin/bash
# bin/lib/rb-tracker.sh — the run-build seam onto the tracker contract
# (bin/lib/tracker.sh), BH-7921. The stage modules under bin/lib/rb/ read and
# write a Jira or Linear ticket only through these verbs; a GitHub-issues or
# board project keeps the code it has.
#
# Sourced, never executed: no `set -e`, no `exit`, no output and no write at
# source time, safe under `set -u`. Sourcing it twice is inert. The contract
# lib is sourced on first use: the copy beside this file, else
# $HARNESS/bin/lib/tracker.sh. The root is ${HARNESS:-${H:-}} and nothing else.
#
#   rbt_tracked <project>               rc 0 when tracker_kind is jira or linear.
#                                       Runs in the caller's shell, so the
#                                       kind is cached there; RBT_KIND holds
#                                       the kind, "" when it does not resolve.
#   rbt_kind <project>                  tracker_kind; rc 1 and nothing printed
#                                       when the contract lib does not load or
#                                       the kind does not resolve. The caller
#                                       then runs its own fleet.conf column-4
#                                       code, which is today's rule.
#   rbt_read <project> <key> [<memo>] [fresh]
#                                       the normalized ticket JSON (tracker.sh
#                                       header), jira and linear only (other
#                                       kinds rc 3). With <memo>, a file that
#                                       holds a JSON object is served and no
#                                       request is made, and a good read is
#                                       written there (temp + mv). `fresh`
#                                       always reads, then writes the memo.
#   rbt_fp <json-file> [<own-ledger>]   `trk:<sha256>` of {title, body,
#                                       comments: [[createdAt, body]]}, compact,
#                                       sorted keys. status is not in it: a
#                                       status move is not a thread turn. A
#                                       comment whose ptg_norm_sha is a line of
#                                       <own-ledger> is left out.
#   rbt_own_write <project> <key> <build> -- <cmd...>
#                                       runs <cmd...> (a harness write on the
#                                       ticket) and keeps <build>/ticket-fp
#                                       true to it; see THE FINGERPRINT below.
#                                       Returns the rc of <cmd...>.
#   rbt_meta <json-file>                {title, type: "", labels: [names], body}
#   rbt_comment <project> <key> <bodyfile> <mark> <stamp> <build>
#                                       one comment, deduplicated by the
#                                       bin/lib/comment-mark.sh mark (token:
#                                       the build dir's name; the D1 row, then
#                                       the <stamp> file). Posted inside
#                                       rbt_own_write. rc 0 posted (then
#                                       marked and in the own-post ledger);
#                                       rc 4 the mark says it is already on
#                                       the ticket, nothing sent; else the
#                                       contract's rc, nothing marked.
#   rbt_link_pr <project> <key> <pr-url> <build>
#                                       tracker_link_pr inside rbt_own_write
#                                       (Linear: an attachment; Jira: a `PR:`
#                                       comment), then tracker_transition
#                                       <key> review. rc 0 always.
#   rbt_close_out <project> <key> <bodyfile> <build>
#                                       the merge comment, then done. rc 0
#                                       when the ticket moved.
#
# THE WRITES run tracker_context in a subshell, so no TRK_* value reaches the
# caller's shell. TRK_DRY is always 0 there. TRK_LOG and TRK_ERR are
# <build>/tracker.log. rc 5 is this lib's own: the project has no tracker
# context (no env file, no key, a row that does not parse), nothing was sent.
# One <build>/pipeline.log line per step, in the pipeline's own shape.
#
# THE FINGERPRINT (comment 6522650545 on BH-7921). The plan stage records the
# ticket's fingerprint in <build>/ticket-fp, and a resumed build goes
# PLAN_STALE when the thread no longer matches it. A harness write is a thread
# turn too, so without care a resume stops on the build's own BUILD BLOCKED
# notice. rbt_own_write is a compare-and-swap around the write:
#   1. If <build>/ticket-fp exists, read the ticket: fp0.
#   2. Run the write.
#   3. If it took and fp0 equals the stored fp, read again and store the new
#      fp (temp + mv): the only turn since the plan is ours.
#   4. If fp0 differs, a person moved the thread first: the stored fp stays,
#      so the resume still goes PLAN_STALE on that person's turn.
#   5. A read that fails leaves the stored fp alone.
# The own-post ledger filter in rbt_fp is a cheap first defense; it is not the
# only one, because a Jira ADF copy of a comment may not match its text.
#
# THE MARKS (bin/lib/comment-mark.sh keys, stamp files under $HARNESS/state):
#   link-pr <project> <key> <pr-number>   after a link that took. A later call
#       for the same PR sends nothing. A failed review move keeps the mark.
#   merge-close <project> <key>           after the merge comment took (seen
#       on the ticket). A later close-out only moves the ticket.

# _rbt_lib — the contract lib in this shell. rc 1 when it does not load.
_rbt_lib() {
  declare -F tracker_kind >/dev/null && return 0
  local d root="${HARNESS:-${H:-}}"
  d=$(dirname "${BASH_SOURCE[0]}")
  if [ -r "$d/tracker.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "$d/tracker.sh" 2>/dev/null || return 1
  elif [ -n "$root" ] && [ -r "$root/bin/lib/tracker.sh" ]; then
    # shellcheck source=/dev/null
    . "$root/bin/lib/tracker.sh" 2>/dev/null || return 1
  else
    return 1
  fi
  declare -F tracker_kind >/dev/null
}

# _rbt_cm — bin/lib/comment-mark.sh in this shell, when it is there. Without
# it cm_has/cm_put answer 127 and the callers use the stamp file alone.
_rbt_cm() {
  declare -F cm_has >/dev/null && return 0
  local d root="${HARNESS:-${H:-}}"
  d=$(dirname "${BASH_SOURCE[0]}")
  if [ -r "$d/comment-mark.sh" ]; then
    # shellcheck source=bin/lib/comment-mark.sh
    . "$d/comment-mark.sh" 2>/dev/null
  elif [ -n "$root" ] && [ -r "$root/bin/lib/comment-mark.sh" ]; then
    # shellcheck source=/dev/null
    . "$root/bin/lib/comment-mark.sh" 2>/dev/null
  fi
  declare -F cm_has >/dev/null
}

# _rbt_ptg — bin/lib/plan-thread.sh (ptg_norm_sha, ptg_own_post) in this shell.
_rbt_ptg() {
  declare -F ptg_own_post >/dev/null && return 0
  local d root="${HARNESS:-${H:-}}"
  d=$(dirname "${BASH_SOURCE[0]}")
  if [ -r "$d/plan-thread.sh" ]; then
    # shellcheck source=bin/lib/plan-thread.sh
    . "$d/plan-thread.sh" 2>/dev/null
  elif [ -n "$root" ] && [ -r "$root/bin/lib/plan-thread.sh" ]; then
    # shellcheck source=/dev/null
    . "$root/bin/lib/plan-thread.sh" 2>/dev/null
  fi
  declare -F ptg_own_post >/dev/null
}

# _rbt_marked <mark> <token> <stamp> — rc 0 when the mark is there.
_rbt_marked() {
  local rc=0
  _rbt_cm
  cm_has "$1" "$2" "$3" 2>/dev/null || rc=$?
  [ "$rc" = 127 ] && { [ -e "$3" ] && rc=0; }
  [ "$rc" = 0 ]
}

# _rbt_mark <mark> <token> <stamp> — the row, else the file.
_rbt_mark() {
  _rbt_cm
  cm_put "$1" "$2" "$3" 2>/dev/null && return 0
  mkdir -p "$(dirname "$3")" 2>/dev/null
  : > "$3" 2>/dev/null
}

# _rbt_say <build> <project> <key> <line> — one pipeline.log line.
_rbt_say() {
  local s
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  if declare -F STAMP >/dev/null; then s=$(STAMP); else s=$(date -u +%Y-%m-%dT%H:%M:%SZ); fi
  printf '%s [%s/%s] %s\n' "$s" "$2" "$3" "$4" >> "$1/pipeline.log" 2>/dev/null
  return 0
}

# _rbt_call <project> <build> <verb> [args…] — the context and one contract
# verb, in a subshell. The adapter's stderr goes to <build>/tracker.log.
_rbt_call() {
  local p="$1" tl=""
  [ -n "$2" ] && [ -d "$2" ] && tl="$2/tracker.log"
  shift 2
  _rbt_lib || return 5
  (
    TRK_DRY=0; TRK_REQ_FILE=""; TRK_LOG="$tl"; TRK_ERR="$tl"
    tracker_context "$p" run-build 2>/dev/null || exit 5
    if [ -n "$tl" ]; then "$@" 2>>"$tl"; else "$@" 2>/dev/null; fi
  )
}

rbt_kind() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  _rbt_lib || return 1
  tracker_kind "$p" 2>/dev/null
}

rbt_tracked() {
  RBT_KIND=""
  [ -n "${1:-}" ] || return 1
  _rbt_lib || return 1
  tracker_kind "$1" >/dev/null 2>&1 || return 1
  RBT_KIND=$(tracker_kind "$1" 2>/dev/null)
  case "$RBT_KIND" in jira|linear) return 0 ;; esac
  return 1
}

rbt_read() {
  local p="${1:-}" key="${2:-}" memo="${3:-}" mode="${4:-}" k out rc=0 tmp
  [ -n "$p" ] && [ -n "$key" ] || return 1
  if [ -n "$memo" ] && [ "$mode" != fresh ] && [ -s "$memo" ] \
     && jq -e 'type == "object"' "$memo" >/dev/null 2>&1; then
    cat "$memo"
    return 0
  fi
  k=$(rbt_kind "$p") || return 1
  case "$k" in jira|linear) ;; *) return 3 ;; esac
  out=$(_rbt_call "$p" "" tracker_read "$key") || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  if [ -n "$memo" ]; then
    tmp="$memo.tmp.$$"
    { printf '%s\n' "$out" > "$tmp" && mv -f "$tmp" "$memo"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  printf '%s\n' "$out"
}

rbt_fp() {
  local f="${1:-}" own="${2:-}" j drop='[]' i n b tmp
  [ -r "$f" ] || return 1
  if [ -n "$own" ] && [ -s "$own" ] && _rbt_ptg && declare -F ptg_norm_sha >/dev/null; then
    n=$(jq -r '(.comments // []) | length' "$f" 2>/dev/null) || n=0
    tmp=$(mktemp "${TMPDIR:-/tmp}/rbt-fp.XXXXXX") || return 1
    for ((i = 0; i < ${n:-0}; i++)); do
      jq -j --argjson i "$i" '.comments[$i].body // ""' "$f" > "$tmp" 2>/dev/null || continue
      b=$(ptg_norm_sha "$tmp")
      grep -qx "$b" "$own" 2>/dev/null && drop=$(jq -c --argjson i "$i" '. + [$i]' <<<"$drop")
    done
    rm -f "$tmp"
  fi
  j=$(jq -cS --argjson drop "$drop" '{title: (.title // ""), body: (.body // ""),
        comments: [(.comments // []) | to_entries[] | select(.key as $k | $drop | index($k) | not)
                   | .value | [(.createdAt // null), (.body // "")]]}' "$f" 2>/dev/null) || return 1
  [ -n "$j" ] || return 1
  printf 'trk:%s\n' "$(printf '%s' "$j" | sha256sum | cut -d' ' -f1)"
}

# _rbt_fp_now <project> <key> <build> — the fingerprint TICKET_FP would print
# now, from a fresh read. rc != 0 when the read fails.
_rbt_fp_now() {
  local t rc=0 fp
  t=$(mktemp "${TMPDIR:-/tmp}/rbt-read.XXXXXX") || return 1
  rbt_read "$1" "$2" > "$t" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] && { fp=$(rbt_fp "$t" "$3/own-comments.sha256") || rc=1; }
  rm -f "$t"
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$fp"
}

rbt_own_write() {
  local p="${1:-}" key="${2:-}" b="${3:-}" stored="" fp0="" fp1 rc=0 rrc=0 tmp
  shift 3 2>/dev/null || return 1
  [ "${1:-}" = -- ] && shift
  [ $# -gt 0 ] || return 1
  if [ -n "$b" ] && [ -s "$b/ticket-fp" ]; then
    stored=$(cat "$b/ticket-fp" 2>/dev/null)
    fp0=$(_rbt_fp_now "$p" "$key" "$b") || { rrc=$?; fp0=""
      _rbt_say "$b" "$p" "$key" "ticket-fp kept: the read before this harness write failed (rc $rrc)"; }
  fi
  "$@" || rc=$?
  [ "$rc" = 0 ] && [ -n "$stored" ] && [ -n "$fp0" ] || return "$rc"
  if [ "$fp0" != "$stored" ]; then
    _rbt_say "$b" "$p" "$key" "ticket-fp kept: the thread moved before this harness write ($stored -> $fp0), so a resume re-plans"
    return 0
  fi
  if fp1=$(_rbt_fp_now "$p" "$key" "$b"); then
    tmp="$b/ticket-fp.tmp.$$"
    if printf '%s\n' "$fp1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$b/ticket-fp" 2>/dev/null; then
      _rbt_say "$b" "$p" "$key" "ticket-fp refreshed after own write ($stored -> $fp1)"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  else
    _rbt_say "$b" "$p" "$key" "ticket-fp kept: the read after this harness write failed (rc $?)"
  fi
  return 0
}

rbt_meta() {
  local f="${1:-}"
  [ -r "$f" ] || return 1
  jq -ce 'select(type == "object") | {title: (.title // ""), type: "",
          labels: [(.labels // [])[] | if type == "object" then (.name // "") else tostring end],
          body: (.body // "")}' "$f" 2>/dev/null
}

# _rbt_post <project> <key> <bodyfile> <build> — tracker_comment, then the
# own-post ledger line (before the fingerprint refresh reads the thread).
_rbt_post() {
  _rbt_call "$1" "$4" tracker_comment "$2" "$3" || return $?
  _rbt_ptg && ptg_own_post "$4" "$3" 2>/dev/null
  return 0
}

rbt_comment() {
  local p="${1:-}" key="${2:-}" f="${3:-}" mk="${4:-}" stamp="${5:-}" b="${6:-}" tok rc=0
  [ -n "$p" ] && [ -n "$key" ] && [ -r "$f" ] && [ -n "$mk" ] && [ -n "$stamp" ] && [ -d "$b" ] || return 1
  tok=$(basename "$b")
  _rbt_marked "$mk" "$tok" "$stamp" && return 4
  rbt_own_write "$p" "$key" "$b" -- _rbt_post "$p" "$key" "$f" "$b" || rc=$?
  if [ "$rc" != 0 ]; then
    _rbt_say "$b" "$p" "$key" "could not comment on $key (rc $rc) — nothing marked; a later attempt retries it"
    return "$rc"
  fi
  _rbt_mark "$mk" "$tok" "$stamp"
  _rbt_say "$b" "$p" "$key" "commented on $key ($mk)"
  return 0
}

rbt_link_pr() {
  local p="${1:-}" key="${2:-}" url="${3:-}" b="${4:-}" n mk stamp k rc=0 root="${HARNESS:-${H:-}}"
  [ -n "$p" ] && [ -n "$key" ] && [ -n "$root" ] || return 0
  k=$(rbt_kind "$p" 2>/dev/null) || k="?"
  n=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)$#\1#p')
  [ -n "$n" ] || { _rbt_say "$b" "$p" "$key" "could not link PR $url on $key: not a GitHub PR url — nothing sent"; return 0; }
  mk="link-pr $p $key $n"
  stamp="$root/state/link-pr-$p-$key-$n"
  if _rbt_marked "$mk" - "$stamp"; then
    _rbt_say "$b" "$p" "$key" "PR $url is already linked on $key (mark $mk) — nothing sent"
    return 0
  fi
  rbt_own_write "$p" "$key" "$b" -- _rbt_call "$p" "$b" tracker_link_pr "$key" "$url" || rc=$?
  if [ "$rc" != 0 ]; then
    _rbt_say "$b" "$p" "$key" "could not link PR $url on $key (rc $rc) — nothing marked; the build goes on"
    return 0
  fi
  _rbt_mark "$mk" - "$stamp"
  _rbt_say "$b" "$p" "$key" "linked PR $url on $key ($k)"
  rc=0
  _rbt_call "$p" "$b" tracker_transition "$key" review || rc=$?
  if [ "$rc" = 0 ]; then _rbt_say "$b" "$p" "$key" "moved $key to review"
  else _rbt_say "$b" "$p" "$key" "could not move $key to review (rc $rc) — the PR link stands; the build goes on"; fi
  return 0
}

# _rbt_has_comment <project> <key> <bodyfile> — rc 0 when a fresh read shows a
# comment with that text (whitespace folded); rc 1 when not, or the read failed.
_rbt_has_comment() {
  local j
  j=$(rbt_read "$1" "$2") || return 1
  printf '%s' "$j" | jq -e --rawfile b "$3" '
    def n: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    ($b | n) as $want | any((.comments // [])[]?; ((.body // "") | n) == $want)' >/dev/null 2>&1
}

rbt_close_out() {
  local p="${1:-}" key="${2:-}" f="${3:-}" b="${4:-}" mk stamp rc=0 root="${HARNESS:-${H:-}}"
  [ -n "$p" ] && [ -n "$key" ] && [ -r "$f" ] && [ -n "$root" ] || return 1
  mk="merge-close $p $key"
  stamp="$root/state/merge-close-commented-$p-$key"
  if _rbt_marked "$mk" - "$stamp"; then
    # The merge comment is on the ticket already: only the move is left.
    _rbt_call "$p" "$b" tracker_transition "$key" done || rc=$?
    if [ "$rc" = 0 ]; then
      _rbt_say "$b" "$p" "$key" "closed out $key after merge (the comment was already on the ticket; moved to done)"
      return 0
    fi
    _rbt_say "$b" "$p" "$key" "could not move $key to done after merge (rc $rc); the merge comment is on the ticket"
    return 1
  fi
  _rbt_call "$p" "$b" tracker_close_out "$key" "$f" || rc=$?
  if [ "$rc" = 0 ]; then
    _rbt_mark "$mk" - "$stamp"
    _rbt_say "$b" "$p" "$key" "closed out $key after merge (comment, then done)"
    return 0
  fi
  if [ "$rc" != 5 ] && _rbt_has_comment "$p" "$key" "$f"; then
    _rbt_mark "$mk" - "$stamp"
    _rbt_say "$b" "$p" "$key" "commented on $key after merge but could not move it to done (rc $rc) — marked, so a retry only moves it"
  else
    _rbt_say "$b" "$p" "$key" "could not close out $key after merge (rc $rc) — no merge comment is on the ticket"
  fi
  return 1
}
