#!/bin/bash
# gh-identity: raw-by-design — same shape as lib/block-gate.sh and for the same reason: its reads run INSIDE a lane that has ALREADY armed the identity that can see this repo, and a second mint here would override the tier-2 sweep's admin-PAT fallback and answer "cannot judge" on exactly the repos the dependency gate exists for.
# bin/lib/pr-dep-gate.sh — BH-629: an open declared dependency holds the merge.
# Sourced by bin/lib/merge-conductor-lib.sh, which every automatic merge lane
# already sources; never executed. Modelled on bin/lib/block-gate.sh.
#
# THE INCIDENT. #615 merged while its own body said "Depends on #459 (PR #609)
# for tests/lib/scratch.sh" and #609 was still open, so main carried a suite
# sourcing a file main did not have and every open PR was red for 7.5 hours.
#
# WHAT pdg_hold DOES (BH-629.1). Kill switch first, before any read. Then scan
# the PR body for declared dependencies, resolve each distinct one ONCE through
# the issues endpoint, and answer: an open dependency holds, a closed one passes
# (merged or not, and the log line says which), a dependency nobody could read
# holds too. A body it was not handed is fetched here with one REST read.
# The memo lives in this shell and, under the conductor, in a per-tick file
# memo (BH-1735) that starts empty every tick, so nothing goes stale between
# lane ticks. The four lane call sites are BH-629.2's
# (bin/merge-conductor.sh READY arm, bin/merge-sweep.sh, the run-build tier-1
# gate and bin/merge-queue.sh), and each calls pdg_hold inside `$(...)`.
#
# THE TICKET HALF (BH-1678). On a GitHub-Issues board (fleet.conf board_prefix
# `-`) a PR whose body links its ticket with `Closes #I` is also held by that
# ISSUE's own `Blocked-by: #N` lines while #N is open, and — when the issue is
# `Part of #P` with `Order: n of m`, n > 1 — while a lower-Order sibling of #P
# has an open PR whose conductor row is READY or QUEUED. The decomposer writes
# those lines on the child issue, never on the PR, which is how the 2026-09-23
# project-5 wave queued contract #3215 beside its own children.
# PR_DEP_GATE_TICKET=0 turns the ticket half off and costs no read.
#
# THE RC CONTRACT the lanes are written against: 0 = HOLD, 1 = pass, 2 = could
# not read; rc 2 HOLDS, fail closed.
#
# WHY IT PASSED, ON REQUEST (BH-4497). A pass prints nothing on stdout, which is
# what three of the four lanes rely on. With PDG_SAY_PASS=1 a pass also prints
# the reason its log line carries, minus the "<slug>#<n> dep gate: " prefix and
# the " — pass" suffix ("dependency landed, closed unmerged #31"), or "dep gate
# OFF" for the kill switch. Only the conductor sets it, for its one RELEASED line
# and its STUCK page; rc and the log line are the same either way.
#
# THE IDENTITY IS THE LANE'S. Every gh call this gate will ever make runs on the
# lane's own token; a second mint here would override the tier-2 sweep's
# admin-PAT fallback and answer "cannot judge" on the repos it exists for.
#
# Line-anchored after markdown noise only — space # * _ backtick — with `>`
# deliberately NOT in that class, as BG_BLOCK_RE has it: a QUOTED line is
# somebody repeating an old body, not declaring one. `(PR #M)` is optional and
# nothing anchors the end — the incident's own line carried prose after it.
# BH-629.1 blanks fenced blocks and paired inline spans BEFORE this regex sees a
# line, so a declaration quoted inside a code sample never holds; an unpaired
# leading backtick is still plain markdown noise, as the class says.
PDG_DEP_RE='^[[:space:]#*_`]*[Dd][Ee][Pp][Ee][Nn][Dd][Ss][[:space:]]+[Oo][Nn][[:space:]]+[*_`]*#[0-9]+([[:space:]]*\([[:space:]]*[Pp][Rr][[:space:]]*#[0-9]+[[:space:]]*\))?'
# pdg_home — the harness root, read at CALL time, bg_home's reason: a lane that
# sets HARNESS after sourcing the lib (every fixture does) writes to its own tree.
pdg_home() { printf '%s' "${HARNESS:-${MC_H:-/root/harness}}"; }
# _pdg_switch — rc 0 when switch.pr-dep-gate-off[.<box>] (no row: the file
# flags/pr-dep-gate-off) is ON, 1 when not, 2 when lane-switch.sh could not
# load. A subshell: the resolver never reaches the caller.
_pdg_switch() {
  ( HARNESS="$(pdg_home)"; . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" >/dev/null 2>&1 || exit 2; lane_switch pr-dep-gate-off file ) >/dev/null 2>&1
}
# pdg_enabled — rc 0 when the gate is on. Absent = on, BLOCK_GATE_ENFORCE's shape.
# PR_DEP_GATE=0 stops it first; then switch.pr-dep-gate-off[.<box>] (see
# _pdg_switch), and the file alone when the resolver cannot load.
pdg_enabled() {
  local rc=0
  [ "${PR_DEP_GATE:-1}" != 0 ] || return 1
  if _pdg_switch; then return 1; else rc=$?; fi
  [ "$rc" = 2 ] && { [ ! -e "$(pdg_home)/flags/pr-dep-gate-off" ]; return $?; }
  return 0
}
# pdg_ticket_enabled — rc 0 unless PR_DEP_GATE_TICKET=0: the ticket half of pdg_hold (BH-1678).
pdg_ticket_enabled() { [ "${PR_DEP_GATE_TICKET:-1}" != 0 ]; }
# pdg_log <text> — the gate's own file and not a lane's $LOG, because the gate
# has no lane context. A failed mkdir or write never aborts the calling lane.
pdg_log() { mkdir -p "$(pdg_home)/logs" 2>/dev/null; printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${1:-}" >> "$(pdg_home)/logs/pr-dep-gate.log" 2>/dev/null; }
# _pdg_scan_lines <body> — the body's lines as PDG_DEP_RE must see them: CRs
# stripped (a body edited in the GitHub web UI comes back CRLF), fenced blocks
# dropped, and PAIRED inline spans blanked. A declaration inside a code sample is
# somebody showing the form, not declaring one, which is the same reason `>` is
# not in the noise class. An unterminated fence swallows the rest of the body:
# conservative on purpose, since nothing inside a code sample should ever hold.
_pdg_scan_lines() {
  printf '%s\n' "${1:-}" | tr -d '\r' | awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    { gsub(/`[^`]*`/, ""); print }'
}
# _pdg_deps <body> — the numbers to check, one per line, first seen first.
# Which lines DECLARE is decided on the line as written; which number the
# declaration names is then read off the line with its emphasis characters
# removed, because `**Depends on #609** (PR #612)` names #612 just as plainly as
# the unbolded form does, and the regex constant is the contract's and is not
# touched here. Only the MATCHED prefix is read either way, so a `#700` in the
# prose after the declaration is never resolved; inside that prefix the LAST
# `#<n>` is the answer, which is M when the line names `(PR #M)` and N when it
# does not.
_pdg_deps() {
  local line m
  _pdg_scan_lines "${1:-}" | grep -E "$PDG_DEP_RE" | while IFS= read -r line; do
    m=$(printf '%s\n' "$line" | tr -d '*_`' | grep -oE "$PDG_DEP_RE" | head -1)
    # The fallback keeps a declared dependency from being dropped in silence if
    # stripping emphasis ever costs the match: an unresolved dep must not vanish.
    [ -n "$m" ] || m=$(printf '%s\n' "$line" | grep -oE "$PDG_DEP_RE" | head -1)
    printf '%s\n' "$m" | sed -E 's/.*#([0-9]+).*/\1/'
  done | awk '!seen[$0]++'
}
# The ticket half's line readers. Same discipline as PDG_DEP_RE: anchored after
# markdown noise (space # * _ backtick) with `>` NOT in the class, and every body
# goes through _pdg_scan_lines first, so a quoted, fenced or inline-code line
# never declares anything. Matched case-insensitively (grep -i).
PDG_BLOCKED_RE='^[[:space:]#*_`]*blocked[- ]by[*_:[:space:]]*#[0-9]+'
PDG_CLOSES_RE='^[[:space:]#*_`]*closes[*_:[:space:]]+#[0-9]+'
# BH-5798: a partial build says `Refs #N` instead (bin/lib/rb/pr.sh). It names
# the same ticket, so the ticket half reads it when no Closes line is there.
PDG_REFS_RE='^[[:space:]#*_`]*refs[*_:[:space:]]+#[0-9]+'
PDG_PART_RE='^[[:space:]#*_`]*part[- ]of[*_:[:space:]]+#[0-9]+'
PDG_ORDER_RE='^[[:space:]#*_`]*order[*_:[:space:]]*[0-9]+[[:space:]]+of[[:space:]]+[0-9]+'
# pdg_ticket_deps <slug> <issue> — THE CONTRACT (BH-1669): the parent issue
# numbers the ISSUE body declares, one per line, first seen first, from
# line-anchored `Blocked-by: #N` lines. Every `#N` on such a line counts
# (`Blocked-by #50, #51`), as bin/unblocked-children.sh reads it; the issue
# itself never does. An unreadable issue answers rc 2 and prints nothing.
# The body is left in _PDG_TBODY and the list in _PDG_TDEPS, in the CALLING
# shell, so pdg_hold reads the Order lines without paying for the body twice.
pdg_ticket_deps() {
  local slug="${1:-}" issue="${2:-}" body
  _PDG_TBODY=""; _PDG_TDEPS=""
  # BH-1735: the same ledgered, per-tick-memoised read _pdg_resolve uses, so
  # the linked issue's body and a Blocked-by lookup of that number share it.
  if command -v gh_rest_var >/dev/null 2>&1; then
    body=$(_pdg_issue_json "$slug" "$issue") || return 2
    body=$(jq -r '.body // ""' <<<"$body" 2>/dev/null) || return 2
  else
    body=$(gh api "repos/$slug/issues/$issue" -q '.body // ""' 2>/dev/null) || return 2
  fi
  _PDG_TBODY="$body"
  _PDG_TDEPS=$(_pdg_scan_lines "$body" | grep -iE "$PDG_BLOCKED_RE" | grep -oE '#[0-9]+' \
               | tr -d '#' | awk -v self="$issue" '$0 != self && !seen[$0]++')
  [ -z "$_PDG_TDEPS" ] || printf '%s\n' "$_PDG_TDEPS"
  return 0
}
# _pdg_first <regex> <body> — the first number on the first scanned line the
# regex matches (for Closes / Part of: the number the declaration names).
_pdg_first() {
  _pdg_scan_lines "${2:-}" | grep -iE -m1 -o "$1" | grep -oE '#[0-9]+' | head -1 | tr -d '#'
}
# _pdg_linked_issue <pr-body> — the ticket a PR closes, from its first
# `Closes #N` line, else (a partial build, BH-5798) its first `Refs #N` line;
# empty when it names neither (the body-only gate then runs).
_pdg_linked_issue() {
  local n
  n=$(_pdg_first "$PDG_CLOSES_RE" "${1:-}")
  [ -n "$n" ] || n=$(_pdg_first "$PDG_REFS_RE" "${1:-}")
  [ -z "$n" ] || printf '%s\n' "$n"
}
# _pdg_order_of <issue-body> — "<P> <n>" when the body carries both `Part of #P`
# and `Order: n of m`; nothing otherwise.
_pdg_order_of() {
  local p n
  p=$(_pdg_first "$PDG_PART_RE" "${1:-}")
  n=$(_pdg_scan_lines "${1:-}" | grep -iE -m1 -o "$PDG_ORDER_RE" | grep -oE '[0-9]+' | head -1)
  [ -n "$p" ] && [ -n "$n" ] && printf '%s %s\n' "$p" "$n"
}
# _pdg_conf — fleet.conf, found in bin/fleet-conf.sh's order with the harness
# root read at call time (so a fixture's $HARNESS wins over the live box).
_pdg_conf() {
  local c
  for c in "${FLEET_CONF:-}" "$(pdg_home)/fleet.conf" "${BASH_SOURCE[0]%/*}/../../fleet.conf"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
# _pdg_issue_board <slug> — rc 0 when the project whose repo is <slug> is a
# GitHub-Issues board: its board_prefix column (fleet-conf.sh's 4th field) is
# `-`, merge-conductor.sh's block-gate guard. A slug fleet.conf does not know is
# not one. Memoised in _PDG_BOARD_MEMO for this shell.
_pdg_issue_board() {
  local slug="${1:-}" ans conf NL=$'\n'
  ans=$(printf '%s\n' "${_PDG_BOARD_MEMO:-}" | awk -v k="$slug" '$1==k { print $2; exit }')
  if [ -z "$ans" ]; then
    ans=no
    conf=$(_pdg_conf) \
      && [ "$(awk -v s="$slug" '!/^[[:space:]]*(#|$)/ && $2==s { print $4; exit }' "$conf")" = - ] && ans=yes
    _PDG_BOARD_MEMO="${_PDG_BOARD_MEMO:+${_PDG_BOARD_MEMO}$NL}$slug $ans"
  fi
  [ "$ans" = yes ]
}
# _pdg_lists <slug> — the two paginated REST lists the Order check reads, each
# at most once per shell per slug: the OPEN ai-build issues (PR entries dropped)
# as "<slug> <n> <base64 body>" in _PDG_ILIST, and the OPEN PRs as
# "<slug> <n> <head ref> <base64 body>" in _PDG_PLIST. rc 1 when either read
# failed; a failure is not memoised, _pdg_resolve's reason. Under a conductor
# tick each list is also read at most once per TICK (BH-1735, _pdg_list_read).
_pdg_lists() {
  local slug="${1:-}" out NL=$'\n'
  if ! printf '%s\n' "${_PDG_ILIST:-}" | awk -v s="$slug" '$1==s { f=1 } END { exit !f }'; then
    out=$(_pdg_list_read pdg-ilist "$slug" "repos/$slug/issues?state=open&labels=ai-build&per_page=100" \
          '.[] | select(.pull_request | not) | "\(.number) \((.body // "") | @base64)"') || return 1
    _PDG_ILIST="${_PDG_ILIST:+${_PDG_ILIST}$NL}$slug -"
    [ -z "$out" ] || _PDG_ILIST="$_PDG_ILIST$NL$(printf '%s\n' "$out" | sed "s#^#$slug #")"
  fi
  if ! printf '%s\n' "${_PDG_PLIST:-}" | awk -v s="$slug" '$1==s { f=1 } END { exit !f }'; then
    out=$(_pdg_list_read pdg-plist "$slug" "repos/$slug/pulls?state=open&per_page=100" \
          '.[] | "\(.number) \(.head.ref) \((.body // "") | @base64)"') || return 1
    _PDG_PLIST="${_PDG_PLIST:+${_PDG_PLIST}$NL}$slug - -"
    [ -z "$out" ] || _PDG_PLIST="$_PDG_PLIST$NL$(printf '%s\n' "$out" | sed "s#^#$slug #")"
  fi
  return 0
}
# _pdg_order_hold <slug> <issue> <P> <n> — the lower-Order siblings of #P that
# are waiting to merge: one "Order <n> behind #<k> (PR #<pr> <STATE>)" line per
# hold in _PDG_OHOLD and the siblings it looked at in _PDG_OCHECKED, both in the
# calling shell (the list memos must outlive the call too). A sibling holds
# only when it has an OPEN PR (branch ticket/<key>-<k>[-rN], or a `Closes #k`
# body) whose conductor row is exactly READY or QUEUED: BLOCKED_*, WAIT_*, no
# row, no open PR or a closed issue never holds, so one stuck sibling cannot
# freeze the wave. The row is read from the conductor's own pr-state.tsv, never
# over the API. rc 1 when a list could not be read.
_pdg_order_hold() {
  local slug="${1:-}" issue="${2:-}" p="${3:-}" n="${4:-}" s k b64 po pn pref pb64 st NL=$'\n'
  local rows="${MC_ROWS:-$(pdg_home)/state/merge-conductor/pr-state.tsv}"
  _PDG_OCHECKED=""; _PDG_OHOLD=""
  _pdg_lists "$slug" || return 1
  while read -r s k b64; do
    [ "$s" = "$slug" ] && [ "$k" != - ] && [ "$k" != "$issue" ] || continue
    po=$(_pdg_order_of "$(printf '%s' "$b64" | base64 -d 2>/dev/null)")
    [ "${po% *}" = "$p" ] && [ "${po#* }" -lt "$n" ] 2>/dev/null || continue
    _PDG_OCHECKED="${_PDG_OCHECKED:+$_PDG_OCHECKED }#$k"
    while read -r s pn pref pb64; do
      [ "$s" = "$slug" ] && [ "$pn" != - ] || continue
      grep -qiE "^ticket/[a-z0-9]+-$k(-r[0-9]+)?\$" <<<"$pref" \
        || [ "$(_pdg_linked_issue "$(printf '%s' "$pb64" | base64 -d 2>/dev/null)")" = "$k" ] || continue
      st=$(awk -F'\t' -v key="$slug#$pn" '$1==key { print $2; exit }' "$rows" 2>/dev/null)
      case "$st" in
        READY|QUEUED) _PDG_OHOLD="${_PDG_OHOLD:+$_PDG_OHOLD$NL}Order $n behind #$k (PR #$pn $st)" ;;
      esac
    done <<<"${_PDG_PLIST:-}"
  done <<<"${_PDG_ILIST:-}"
  return 0
}
# _pdg_resolve <slug> <n> — rc 0 and the state in _PDG_ANS ("<state> <merged_at
# or ->"), rc 1 when the read FAILED. Answered from _PDG_MEMO when this shell has
# already paid for it: the fingerprint is <slug>#<n>, never a URL, so the same
# dependency named by two PRs costs one read.
# _PDG_MEMO is a plain newline-separated string and not an associative array,
# bg_scan's reason: an EMPTY associative array is an unbound variable under
# `set -u` (bash 5.2 still), and every lane that calls in here runs with -u.
# _PDG_ANS is set in the CALLING shell rather than printed, because a memo
# written inside `$(...)` would die with the subshell that wrote it.
# A failed read is deliberately NOT memoised. It is the transient of the two
# (a 5xx, a token still arming), and memoising it would park every PR naming
# that dependency for the whole lane tick.
_pdg_resolve() {
  local slug="${1:-}" n="${2:-}" key ans NL=$'\n'
  key="$slug#$n"
  _PDG_ANS=""
  ans=$(printf '%s\n' "${_PDG_MEMO:-}" | awk -v k="$key" '$1==k { print $2, $3; exit }')
  [ -z "$ans" ] || { _PDG_ANS="$ans"; return 0; }
  if command -v gh_rest_var >/dev/null 2>&1; then
    ans=$(_pdg_issue_json "$slug" "$n") || return 1
    ans=$(jq -r '.state + " " + (.pull_request.merged_at // "-")' <<<"$ans" 2>/dev/null) || return 1
  else
    ans=$(gh api "repos/$slug/issues/$n" -q '.state + " " + (.pull_request.merged_at // "-")' 2>/dev/null) || return 1
  fi
  # An rc-0 read that answers something which is not a state (empty, null, an
  # HTML error page) is a read that failed, never a dependency that closed.
  case "$ans" in
    open\ ?*|closed\ ?*) ;;
    *) return 1 ;;
  esac
  _PDG_MEMO="${_PDG_MEMO:+${_PDG_MEMO}$NL}$key $ans"
  _PDG_ANS="$ans"
  return 0
}
# _pdg_rest_get <outvar> <path> — one GET through gh_rest_var (BH-1735), so the
# read passes the quota gate and lands in the GitHub-call ledger. rc is
# gh_rest's: 0 / 44 / 75. GH_REST_OPTIONAL is shadowed EMPTY: a merge-gate read
# is decision-critical, and the reserve gate must never refuse it even when the
# calling lane exported the optional marker for its own reads.
_pdg_rest_get() {
  local GH_REST_OPTIONAL=
  gh_rest_var "${1:-}" GET "${2:-}"
}
# THE PER-TICK MEMO (BH-1735). Every lane calls pdg_hold inside `$(...)`, so
# the in-shell memos die with each PR. Under a conductor tick (MC_TICK_ID set,
# MC_READ_MEMO != 0, tick_memo_file loaded) a read is also kept in
# tick_memo_file <kind> <key>: a new tick is a new file name, so a dependency
# that closes is seen next tick, and mc_tick_gc collects the files. The
# conductor runs its PR workers concurrently, so read-then-store runs under a
# short per-key flock on a DYNAMIC fd (7/8/9 are the conductor's); a lock that
# cannot be had in 20 s degrades to an unlocked read, never to a failure. A
# failed read is never stored, the same rule as _PDG_MEMO's.
# _pdg_memo_lock <kind> <key> — the memo file in _PDG_MF (empty when the memo
# is off) with its key lock held on _PDG_MFD. Pair with _pdg_memo_unlock.
_pdg_memo_lock() {
  _PDG_MF=""; _PDG_MFD=""
  [ -n "${MC_TICK_ID:-}" ] && [ "${MC_READ_MEMO:-1}" != 0 ] && command -v tick_memo_file >/dev/null 2>&1 || return 0
  _PDG_MF=$(tick_memo_file "${1:-}" "${2:-}")
  mkdir -p "${_PDG_MF%/*}" 2>/dev/null || { _PDG_MF=""; return 0; }
  { exec {_PDG_MFD}>>"$_PDG_MF.lock"; } 2>/dev/null || _PDG_MFD=""
  [ -z "$_PDG_MFD" ] || flock -w 20 "$_PDG_MFD" 2>/dev/null || true
}
_pdg_memo_unlock() { [ -z "${_PDG_MFD:-}" ] || exec {_PDG_MFD}>&-; _PDG_MFD=""; }
# _pdg_memo_put <value> — store a SUCCESSFUL read, whole (tmp + mv).
_pdg_memo_put() {
  [ -n "${_PDG_MF:-}" ] || return 0
  printf '%s\n' "${1:-}" > "$_PDG_MF.tmp.$BASHPID" 2>/dev/null && mv -f "$_PDG_MF.tmp.$BASHPID" "$_PDG_MF" 2>/dev/null
  rm -f "$_PDG_MF.tmp.$BASHPID" 2>/dev/null
  return 0
}
# _pdg_issue_json <slug> <n> — the issue as a JSON object on stdout, rc 0; rc 1
# on any failed read (non-2xx, empty, not an object). Memoised per tick under
# pdg-issue "<slug>#<n>"; a memo file that is not a JSON object is a miss. Only
# called when gh_rest_var is loaded; without it the callers keep their raw
# `gh api` line.
_pdg_issue_json() {
  local slug="${1:-}" n="${2:-}" json="" rc=1
  _pdg_memo_lock pdg-issue "$slug#$n"
  if [ -n "$_PDG_MF" ] && [ -s "$_PDG_MF" ] && jq -e 'type=="object"' "$_PDG_MF" >/dev/null 2>&1; then
    cat "$_PDG_MF"; rc=0
  elif _pdg_rest_get json "repos/$slug/issues/$n" && jq -e 'type=="object"' <<<"$json" >/dev/null 2>&1; then
    _pdg_memo_put "$json"
    printf '%s\n' "$json"; rc=0
  fi
  _pdg_memo_unlock
  return "$rc"
}
# _pdg_list_read <kind> <slug> <path> <jq> — one of _pdg_lists' paginated
# reads, memoised per tick under <kind> "<slug>". When gh_rest_var is loaded the
# read goes through bin/lib/gh-rest-list.sh (gh_rest_issue_list for pdg-ilist,
# gh_rest_pr_list_all for pdg-plist): every page passes the quota gate and lands
# in the GitHub-call ledger, and a page that fails fails the whole read, never
# a partial list. GH_REST_OPTIONAL is shadowed empty, _pdg_rest_get's reason.
# The helper writes to a file, never inside `$(...)` (gh-rest-no-subshell-lint).
# The <path> is used only by the raw `gh api --paginate` fallback, for a tree
# without the library. An empty list is a successful read and is stored; a
# failed one is rc 1 and is not.
_pdg_list_read() {
  local out="" rc=0 tmp="" GH_REST_OPTIONAL=
  _pdg_memo_lock "${1:-}" "${2:-}"
  if [ -n "$_PDG_MF" ] && [ -e "$_PDG_MF" ]; then
    cat "$_PDG_MF"
  else
    if command -v gh_rest_var >/dev/null 2>&1 && ! command -v gh_rest_issue_list >/dev/null 2>&1; then
      # shellcheck source=bin/lib/gh-rest-list.sh
      . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh" 2>/dev/null || true
    fi
    if command -v gh_rest_var >/dev/null 2>&1 && command -v gh_rest_issue_list >/dev/null 2>&1; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/pdg-list.XXXXXX") || tmp=""
      if [ -z "$tmp" ]; then rc=1
      elif [ "${1:-}" = pdg-ilist ]; then gh_rest_issue_list "${2:-}" open ai-build 1000 > "$tmp" || rc=1
      else gh_rest_pr_list_all "${2:-}" open 1000 > "$tmp" || rc=1
      fi
      [ "$rc" != 0 ] || out=$(jq -r "${4:-}" "$tmp" 2>/dev/null) || rc=1
      [ -z "$tmp" ] || rm -f "$tmp"
    else
      out=$(gh api --paginate "${3:-}" -q "${4:-}" 2>/dev/null) || rc=1
    fi
    if [ "$rc" = 0 ]; then
      _pdg_memo_put "$out"
      [ -z "$out" ] || printf '%s\n' "$out"
    fi
  fi
  _pdg_memo_unlock
  return "$rc"
}
# pdg_hold <slug> <num> <url> <body-or-empty> — the signature four merge lanes
# call. rc 0 = HOLD, 1 = pass, 2 = could not read (which the lanes hold on).
# Exactly one log line per call, on every path.
pdg_hold() {
  local slug="${1:-}" num="${2:-}" url="${3:-}" body="${4:-}"
  local deps dep state merged_at open_deps="" unread="" merged="" unmerged=""
  pdg_enabled || { pdg_log "$slug#$num dep gate OFF (PR_DEP_GATE=0 or flags/pr-dep-gate-off) — pass"
                   [ "${PDG_SAY_PASS:-}" != 1 ] || printf 'dep gate OFF'; return 1; }
  if [ -z "$body" ]; then
    # The lanes that have the body already hand it over; the box queue does not.
    # A body nobody can read holds, the same rule as a dependency nobody can
    # read: an unreadable PR merging is the shape of the incident.
    #
    # THE READ IS REST, NEVER `gh pr view` (BH-994, 2026-09-19). `gh pr view` is
    # GraphQL, and GraphQL is the budget that empties first: between 17:53Z and
    # 18:04Z on 2026-09-19 every READY cromford row (#933, #956, #955,
    # #785) was held for four consecutive conductor ticks on
    # "could not read the PR body — HOLD (rc 2)" with merges=0, while CI was
    # green and the same installation token still had 3141 of 6600 REST points.
    # `gh pr view` answered "GraphQL: API rate limit already exceeded for
    # installation ID 161623167"; the window reset at 18:04:42Z and the holds
    # cleared by themselves. With ~55 open PRs, a tick every 5 minutes and 30+
    # overlapping conductor workers, two GraphQL body reads per PR per tick is
    # what emptied it. The $url argument stays in the signature — every lane
    # passes it and the log lines read better for it — but the read is built
    # from the slug and number this call was handed.
    #
    # `.body // ""`, because REST answers a description-less PR with a JSON
    # null and the bare `.body` would hand the parser the four characters
    # "null". An empty body then passes with "no declared dependency", exactly
    # as the GraphQL read's empty string did.
    # BH-1735: through gh_rest when it is loaded, so the read is ledgered.
    if command -v gh_rest_var >/dev/null 2>&1; then
      local pj=""
      { _pdg_rest_get pj "repos/$slug/pulls/$num" && body=$(jq -r '.body // ""' <<<"$pj" 2>/dev/null); } \
        || { pdg_log "$slug#$num dep gate: could not read the PR body — HOLD (rc 2)"; return 2; }
    else
      body=$(gh api "repos/$slug/pulls/$num" -q '.body // ""' 2>/dev/null) \
        || { pdg_log "$slug#$num dep gate: could not read the PR body — HOLD (rc 2)"; return 2; }
    fi
  fi
  deps=$(_pdg_deps "$body")
  # A here-string, so the loop runs in THIS shell and the memo outlives it.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if _pdg_resolve "$slug" "$dep"; then
      state="${_PDG_ANS%% *}"; merged_at="${_PDG_ANS#* }"
      if [ "$state" = open ]; then open_deps="${open_deps:+$open_deps }#$dep"
      elif [ "$merged_at" = - ]; then unmerged="${unmerged:+$unmerged }#$dep"
      else merged="${merged:+$merged }#$dep"
      fi
    else
      unread="${unread:+$unread }#$dep"
    fi
  done <<<"$deps"
  # THE TICKET HALF (BH-1678). Only on a GitHub-Issues board, only for a PR that
  # links its ticket with `Closes #I`, and only with PR_DEP_GATE_TICKET on; any
  # of those missing is exactly the body-only gate above, with no extra read.
  # Blocked-by is read from the ISSUE body and never from the PR body.
  local issue="" tdep ord held="" tclosed="" ochecked="" tran=""
  issue=$(_pdg_linked_issue "$body")
  if [ -n "$issue" ] && pdg_ticket_enabled && _pdg_issue_board "$slug"; then
    tran=1
    if pdg_ticket_deps "$slug" "$issue" >/dev/null; then
      while IFS= read -r tdep; do
        [ -n "$tdep" ] || continue
        if _pdg_resolve "$slug" "$tdep"; then
          if [ "${_PDG_ANS%% *}" = open ]; then held="${held:+$held, }Blocked-by #$tdep"
          else tclosed="${tclosed:+$tclosed }#$tdep"
          fi
        else
          unread="${unread:+$unread }#$tdep"
        fi
      done <<<"${_PDG_TDEPS:-}"
      # Order 1 (or no Order line) never pays for the sibling lists.
      ord=$(_pdg_order_of "${_PDG_TBODY:-}")
      if [ -n "$ord" ] && [ "${ord#* }" -gt 1 ]; then
        if _pdg_order_hold "$slug" "$issue" "${ord% *}" "${ord#* }"; then
          ochecked="${_PDG_OCHECKED:-}"
          [ -z "${_PDG_OHOLD:-}" ] || held="${held:+$held, }$(printf '%s\n' "$_PDG_OHOLD" | awk '{ printf "%s%s", (NR>1 ? ", " : ""), $0 }')"
        else
          unread="${unread:+$unread }the Order siblings of #${ord% *}"
        fi
      fi
    else
      unread="${unread:+$unread }issue #$issue"
    fi
  fi
  # Every declared dependency is resolved before answering, so the one log line
  # names them all. Open beats unreadable beats pass. A ticket-half hold also
  # names itself on stdout, which the lanes print as "it declares <that>"; a
  # body-only hold prints nothing, as it always has.
  if [ -n "$open_deps" ] || [ -n "$held" ]; then
    pdg_log "$slug#$num dep gate: open dependency $open_deps${held:+${open_deps:+ }$held (issue #$issue)} — HOLD"
    [ -z "$held" ] || printf '%s' "$held"
    return 0
  fi
  if [ -n "$unread" ]; then
    pdg_log "$slug#$num dep gate: could not read $unread — HOLD (rc 2)"
    return 2
  fi
  local tnote="" why
  [ -z "$tran" ] || tnote="; issue #$issue${tclosed:+ Blocked-by closed $tclosed}${ochecked:+, lower Order siblings $ochecked not waiting}"
  if [ -z "$deps" ]; then
    why="no declared dependency${tran:+ in the PR body}$tnote"
  else
    why="dependency landed${merged:+, merged $merged}${unmerged:+, closed unmerged $unmerged}$tnote"
  fi
  pdg_log "$slug#$num dep gate: $why — pass"
  [ "${PDG_SAY_PASS:-}" != 1 ] || printf '%s' "$why"
  return 1
}
# pdg_queue_hold <num> — bg_queue_hold's signature (bin/merge-queue.sh) for the
# box queue: the slug comes from the queue's environment, rc 0 = hold the entry.
pdg_queue_hold() { pdg_hold "${SLUG:-}" "${1:-}" "https://github.com/${SLUG:-}/pull/${1:-}" ""; }
