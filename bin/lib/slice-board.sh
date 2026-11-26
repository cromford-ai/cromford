#!/bin/bash
# bin/lib/slice-board.sh — file the rest of a sliced IN-APP BOARD ticket when
# one slice merges (BH-8333). A plan that says `SLICE: C<k> of #<ticket-id>`
# builds one slice and names the others (C<k+1>..C<m>) as list items. On the
# GitHub-Issues lane bin/lib/slice-remainder.sh (BH-5961) files those as child
# issues. On a board nothing did: TK-360 shipped C0, read "This ticket is
# closed", and C1-C4 were filed by hand two days later.
#
# This reads the remainder with the same parser (slice_remainder_parse, which
# takes a board id token since BH-8333) and files one child ticket per slice
# through the board filer (fc_file_board, kind `slice`): `parentId` = the
# master, `dependsOn` from the plan's `after C<j>`. bin/decompose-parent-close.sh
# (BH-815) closes the master when every child is done. Nothing here moves a
# master to `done`.
#
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source
# time. Safe under `set -u`. The root is the caller's argument, else
# ${HARNESS:-${H:-}}, never a literal.
#
#   slice_board_line <plan.md>              <k>\t<token> of the first SLICE line
#                                           (token empty for "The build for THIS
#                                           ticket is C<k>"), rc 1 when none
#   slice_board_token <plan.md> <ticket-id> <KEY>
#       -> <token> rc 0 (a slice of THIS ticket; with no ticket id, a board
#          id token is a candidate the parent read must confirm)
#        | rc 1 no SLICE line | <token> rc 2 (a SLICE line for another ticket)
#   slice_board_marker <plan.md> [pr-title] [ticket-id] [KEY]
#       -> <k> rc 0 (a weak slice marker of THIS ticket: no `SLICE: C<k> of #`
#          line, BH-10080) | rc 1 none. Consulted only when slice_board_token
#          answers rc 1.
#   slice_board_owner                       who files a remainder by hand
#   slice_board_settle <project> <KEY> <pr-url> <record-dir|-> [ticket-id] [park 0|1] [harness]
#       -> filed:<keys> rc 0 | exists:<keys> rc 0 (the parent already has
#          children, nothing filed) | deferred:<why> rc 1 | unknown:<why> rc 2
#          (paged; unknown:covered = the plan maps every row to merged work)
#        | skip:<why> rc 3
#
# THE REST WITH NO C<j> LIST (BH-10080). A strong SLICE line whose rest is
# prose (`none` from the parser), or a weak marker, files ONE child "Rest of
# <KEY>": the rows of the plan's `## Requirements coverage` matrix the merged
# slice did not cover (sco_coverage), else the parent ticket's own scope
# (_sco_scope_items over its description). Every row covered is
# unknown:covered; nothing readable is unknown:none. A hand-opened PR with no
# merged spec uses its own PR body as the plan. A parent that already has
# children answers exists:<keys> and files nothing. With park 1, every
# unknown, exists and file-failed answer posts ONE note on the master that
# says the rest is NOT filed (or where it is), and names who files it: the
# knob SLICE_BOARD_FILE_OWNER. Only fc_file_board, from children it recorded
# with a board id, ever says "We filed".
#
# Ledger: <record>/slice-board/, or $HARNESS/state/slice-board/<project>-<KEY>-pr<n>/
# with no record. token, k, children.json, children.txt, children-board.tsv,
# parent.json, pr-title, filed, exists, unknown-paged, noted, fc-error.txt,
# settle.log. `filed`, `exists` and `unknown-paged` are terminal; `noted`
# says the park-1 note (or the builder close-out's comment) is on the thread.
# A second lock, $HARNESS/state/slice-board/.lock-<project>-<KEY>-pr<n>, keeps a
# record ledger and a state ledger of one merge from filing at once. The
# switch is BH-5961's: lane_switch slice-remainder-off or SLICE_REMAINDER_FILE=0.
# Operator notes: docs/verification-map/entries/BH-8333.md and BH-10080.md.

_SBD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/slice-remainder.sh
command -v slice_remainder_parse >/dev/null 2>&1 || { [ -r "$_SBD_LIB/slice-remainder.sh" ] && . "$_SBD_LIB/slice-remainder.sh"; }

slice_board_line() {
  [ -r "${1:-}" ] || return 1
  local l
  # The guard regex of issue_close_guard, with the board token class.
  l=$(awk '
    { sub(/\r$/, "") }
    $0 ~ /^[ \t*_>]*SLICE:[ \t*_]*C[0-9]+[ \t]+of[ \t]+#[A-Za-z0-9]/ {
      s = $0; match(s, /SLICE:[ \t*_]*C[0-9]+/); k = substr(s, RSTART, RLENGTH); sub(/^.*C/, "", k)
      match(s, /[ \t]of[ \t]+#[A-Za-z0-9][A-Za-z0-9_-]*/); t = substr(s, RSTART, RLENGTH); sub(/^.*#/, "", t)
      printf "%d\t%s\n", k + 0, t; exit
    }
    $0 ~ /^[ \t*_>]*The build for THIS ticket is C[0-9]+/ {
      match($0, /is C[0-9]+/); printf "%d\t\n", substr($0, RSTART + 4, RLENGTH - 4) + 0; exit
    }' "$1" 2>/dev/null)
  [ -n "$l" ] || return 1
  printf '%s\n' "$l"
}

slice_board_token() {
  local plan="${1:-}" tid="${2:-}" key="${3:-}" l t
  l=$(slice_board_line "$plan") || return 1
  t="${l#*$'\t'}"
  # "The build for THIS ticket is C<k>" names no ticket: the plan is this
  # build's own, so it is this ticket's.
  if [ -z "$t" ]; then printf '%s\n' "${tid:-$key}"; return 0; fi
  if { [ -n "$tid" ] && [ "$t" = "$tid" ]; } \
     || { [ -n "$key" ] && [ "$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')" = "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" ]; }; then
    printf '%s\n' "$t"; return 0
  fi
  printf '%s\n' "$t"
  # No ticket id to compare (the conductor knows only the KEY): a board id
  # token is a CANDIDATE, and the parent read in slice_board_settle decides,
  # because the board's answer must carry <KEY>. A KEY-shaped token that is
  # not <KEY> is another ticket's line.
  if [ -z "$tid" ] && [ -n "$key" ] && ! [[ "$t" =~ ^[A-Za-z]+-[0-9]+$ ]]; then return 0; fi
  return 2
}

# slice_board_marker — the weak slice marker (BH-10080). TK-618 merged C0 with
# a plan that had no `SLICE: C<k> of #` line, so nothing knew a rest existed.
# Rules, case-insensitive, fenced code skipped:
#   M1  a line `SLICE: C<k>` (or `**Slice:** C<k> (...)`) with no `of #`
#   M2  a line `SLICE-REASON:`; k is the first `slice C<k>` / `C<k> slice`
#       in the plan that names no other ticket, else 0
#   M3  `this (plan|build|pr) (builds|is|delivers|ships) (slice )?C<k>`, unless
#       ` of #<token>` (or ` of <KEY-shaped>`) follows and names another ticket
#   M4  the PR title only: `slice C<k>`, `<KEY>: C<k>` / `[<KEY>] C<k>`, `(C<k>)`
# M1 wins, then M3, then M2, then M4. A C<k> must end at a non-word character,
# so `C0FFEE` is no slice.
slice_board_marker() {
  local plan="${1:-}" title="${2:-}" tid key k
  tid=$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')
  key=$(printf '%s' "${4:-}" | tr '[:upper:]' '[:lower:]')
  [[ "$tid" =~ ^[a-z0-9_-]+$ ]] || tid=""
  [[ "$key" =~ ^[a-z0-9-]+$ ]] || key=""
  [ -r "$plan" ] || plan=/dev/null
  k=$(awk -v TITLE="$title" -v TID="$tid" -v KEY="$key" '
    function lead(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # other(rest): rest opens with " of #<token>" (or " of <KEY-shaped>") that
    # is not this ticket. " of the plan" names no ticket.
    function other(rest,   t, hash) {
      if (!match(rest, /^[ \t]+of[ \t]+#?[a-z0-9][a-z0-9_-]*/)) return 0
      t = substr(rest, RSTART, RLENGTH); sub(/^[ \t]+of[ \t]+/, "", t)
      hash = (substr(t, 1, 1) == "#"); sub(/^#/, "", t)
      if (!hash && t !~ /^[a-z]+-[0-9]+$/) return 0
      return !((TID != "" && t == TID) || (KEY != "" && t == KEY))
    }
    function cnum(r) { match(r, /c[0-9]+$/); return substr(r, RSTART + 1) + 0 }
    # sliceno(s): the first `slice C<k>` or `C<k> slice` of this ticket, else -1.
    function sliceno(s,   r, rest) {
      while (match(s, /slice[ \t:#*_-]*c[0-9]+/)) {
        r = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH); s = rest
        if (rest ~ /^[a-z0-9_]/ || other(rest)) continue
        return cnum(r)
      }
      return -1
    }
    function sliceno2(s,   r, rest) {
      while (match(s, /(^|[^a-z0-9_])c[0-9]+[ \t]+slice/)) {
        r = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/[ \t]+slice$/, "", r)
        return cnum(r)
      }
      return -1
    }
    function titlek(s,   r, rest, re) {
      if (match(s, /slice[ \t:#-]*c[0-9]+/)) {
        r = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH)
        if (rest !~ /^[a-z0-9_]/) return cnum(r)
      }
      if (KEY != "") {
        re = "^[ \t]*\\[?" KEY "\\]?[ \t:.-]+c[0-9]+"
        if (match(s, re)) {
          r = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH)
          if (rest !~ /^[a-z0-9_]/) return cnum(r)
        }
      }
      if (match(s, /\(c[0-9]+\)/)) return substr(s, RSTART + 2, RLENGTH - 3) + 0
      return -1
    }
    BEGIN { fch = ""; m1 = -1; m2 = 0; m3 = -1; ks = -1 }
    { sub(/\r$/, ""); l = tolower($0); t = l; sub(/^[ \t]+/, "", t) }
    {
      if (fch != "") { if (lead(t, fch) >= flen && trim(substr(t, lead(t, fch) + 1)) == "") fch = ""; next }
      if (lead(t, "`") >= 3) { fch = "`"; flen = lead(t, "`"); next }
      if (lead(t, "~") >= 3) { fch = "~"; flen = lead(t, "~"); next }
    }
    m1 < 0 && match(l, /^[ \t*_>]*slice:[ \t*_]*c[0-9]+/) {
      r = substr(l, RSTART, RLENGTH); rest = substr(l, RSTART + RLENGTH)
      if (rest !~ /^[a-z0-9_]/ && rest !~ /^[ \t]+of[ \t]+#/) m1 = cnum(r)
    }
    l ~ /^[ \t*_>-]*slice-reason:/ { m2 = 1 }
    ks < 0 { ks = sliceno(l); if (ks < 0) ks = sliceno2(l) }
    m3 < 0 && match(l, /this[ \t]+(plan|build|pr)[ \t]+(builds|is|delivers|ships)[ \t]+(slice[ \t]+)?c[0-9]+/) {
      r = substr(l, RSTART, RLENGTH); rest = substr(l, RSTART + RLENGTH)
      if (rest !~ /^[a-z0-9_]/ && !other(rest)) m3 = cnum(r)
    }
    END {
      k = -1
      if (m1 >= 0) k = m1
      else if (m3 >= 0) k = m3
      else if (m2) k = (ks >= 0) ? ks : 0
      else if (TITLE != "") k = titlek(tolower(TITLE))
      if (k >= 0) print k
    }' "$plan" 2>/dev/null)
  [ -n "$k" ] || return 1
  printf '%s\n' "$k"
}

# _sbd_need_sco — slice-closeout.sh (sco_coverage, _sco_scope_items, sco_knob),
# sourced once, only by the paths that read it.
_sbd_need_sco() {
  command -v sco_coverage >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/slice-closeout.sh
  [ -r "$_SBD_LIB/slice-closeout.sh" ] && . "$_SBD_LIB/slice-closeout.sh" 2>/dev/null
  command -v sco_coverage >/dev/null 2>&1
}

# slice_board_owner — who files a remainder the harness could not file. The
# knob SLICE_BOARD_FILE_OWNER (settings row lib.slice-closeout.slice_board_file_owner,
# catalog/lanes.d/_lib.slice-closeout.knobs.d/SLICE_BOARD_FILE_OWNER.json).
slice_board_owner() {
  local v=""
  _sbd_need_sco && v=$(sco_knob SLICE_BOARD_FILE_OWNER 2>/dev/null)
  [ -n "${v//[[:space:]]/}" ] || v="${SLICE_BOARD_FILE_OWNER:-}"
  # the operator: the documented fallback of the row above (he filed TK-638..641).
  [ -n "${v//[[:space:]]/}" ] || v="the operator"
  printf '%s\n' "$v"
}

_sbd_esc() { printf '%s' "${1:-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# _sbd_text <parent.json> — the parent's description as text: block tags to
# line breaks and markdown headings, every other tag dropped, entities undone.
_sbd_text() {
  jq -r '(.ticket // .) | (.description // .body // "") | tostring
    | gsub("<br\\s*/?>"; "\n"; "i") | gsub("</p\\s*>"; "\n"; "i") | gsub("<li[^>]*>"; "\n- "; "i")
    | gsub("</li\\s*>"; "\n"; "i") | gsub("<h1[^>]*>"; "\n# "; "i") | gsub("<h2[^>]*>"; "\n## "; "i")
    | gsub("<h[3-6][^>]*>"; "\n### "; "i") | gsub("</h[1-6]\\s*>"; "\n"; "i")
    | gsub("<[^>]*>"; "") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"")
    | gsub("&#0*39;"; "'"'"'") | gsub("&nbsp;"; " ") | gsub("&amp;"; "&")' "$1" 2>/dev/null
}

# _sbd_rest_spec <plan> <k> <KEY> <pr> <parent.json> <out.json> — ONE "Rest of
# <KEY>" child. Prints ok rc 0 | covered rc 2 | none rc 2.
_sbd_rest_spec() {
  local plan="$1" k="$2" key="$3" pr="$4" praw="$5" out="$6" cov rc=0 verdict lead items first title tf
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  _sbd_need_sco || { printf 'none\n'; return 2; }
  cov=$(sco_coverage "$plan" "$k") || rc=$?
  verdict=$(head -1 <<<"$cov")
  case "$rc:$verdict" in
    0:covered*)
      printf 'covered\n'; return 2 ;;
    2:uncovered*)
      lead="The plan of the merged slice did not map these items to merged work:"
      items=$(sed 1d <<<"$cov" | sed -e '/^[[:space:]]*$/d' -e 's/^/- /') ;;
    3:undecided*rows:*)
      lead="The plan of the merged slice could not prove these items were built:"
      items=$(sed 1d <<<"$cov" | sed -e '/^[[:space:]]*$/d' -e 's/^/- /') ;;
    *)
      lead="The plan of the merged slice does not list what it left for later. The scope of $key, as written:"
      tf=$(mktemp "${TMPDIR:-/tmp}/sbd-scope.XXXXXX") || { printf 'none\n'; return 2; }
      _sbd_text "$praw" > "$tf"
      items=$(_sco_scope_items "$tf" "$(slr_exclude_headings)" | sed -e '/^[[:space:]]*$/d')
      rm -f "$tf" ;;
  esac
  first=$(printf '%s\n' "$items" | grep -v '^[[:space:]]*#' | sed -E 's/^[[:space:]]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)?//' | grep -m1 '[[:alnum:]]')
  [ -n "$first" ] || { printf 'none\n'; return 2; }
  title="Rest of $key: $(_slr_title "$first")"
  jq -nc --argjson o "$((k + 1))" --arg t "$title" --arg b "Slice C$k of $key merged in $pr. This ticket carries the rest of $key. $lead

$items

Read the thread of $key for later decisions." '[{ordinal: $o, title: $t, body: $b, after: []}]' > "$out" 2>/dev/null \
    || { printf 'none\n'; return 2; }
  printf 'ok\n'; return 0
}

# _sbd_why <why> — the unknown reason in plain words, for the note.
_sbd_why() {
  case "${1:-}" in
    covered) printf 'the plan maps every item to merged work, so a person must decide what is left' ;;
    none)    printf 'we could not read them from the plan or from this ticket' ;;
    *)       printf 'the list of slices in the plan could not be read (%s)' "$(_sbd_esc "$1")" ;;
  esac
}

# _sbd_note <ledger> <master-id> <word> <k> <pr-url> — the park-1 note (BH-10080):
# ONE comment on the master per ledger, which says what the filing step
# returned. Only after the board answers with a comment object is `noted`
# written; a failed note is retried by the next settle of the ledger. Never
# for unknown:parent (the id names another ticket) and never for filed:*
# (fc_file_board posts that one, from the children it recorded).
_sbd_note() {
  local d="$1" id="$2" word="$3" k="$4" pr="$5" own spr msg resp
  [ -e "$d/noted" ] && return 0
  case "$k" in ''|*[!0-9]*) k=$(head -1 "$d/k" 2>/dev/null); case "$k" in ''|*[!0-9]*) k=0 ;; esac ;; esac
  own=$(_sbd_esc "$(slice_board_owner)")
  spr="<a href=\"$(_sbd_esc "$pr")\">$(_sbd_esc "$pr")</a>"
  case "$word" in
    unknown:parent*) return 0 ;;
    unknown:*)  msg="<p>Slice C$k is merged: $spr. The remaining slices are NOT filed: $(_sbd_why "${word#unknown:}"). $own files them by hand. This ticket stays open until they land.</p>" ;;
    exists:*)   msg="<p>Slice C$k is merged: $spr. The remaining work already has its own tickets: $(_sbd_esc "${word#exists:}"). We added no new ticket.</p>" ;;
    deferred:file-failed) msg="<p>Slice C$k is merged: $spr. The remaining slices are NOT filed yet: the board refused a create. We retry, and if it does not finish $own files them by hand.</p>" ;;
    *) return 0 ;;
  esac
  printf '%s' "$msg" > "$d/note.html"
  resp=$(TRK_DRY=0 TRK_LOG="" TRK_ERR="" TRK_REQ_FILE="" trk_board_comment "$id" "$d/note.html" 2>/dev/null) || return 1
  printf '%s' "$resp" | jq -e '(.comment // .id // .data) != null' >/dev/null 2>&1 || return 1
  printf '%s\n' "$word" > "$d/noted"
}

# _sbd_ctx <project> <harness> — the board context in this shell, rc 1 without.
_sbd_ctx() {
  # shellcheck source=bin/lib/tracker.sh
  command -v tracker_context >/dev/null 2>&1 || . "$_SBD_LIB/tracker.sh" 2>/dev/null
  command -v tracker_context >/dev/null 2>&1 \
    && HARNESS="$2" tracker_context "$1" slice-board 2>/dev/null \
    && [ "${TRK_ADAPTER:-}" = board ]
}

# _sbd_body_plan <fetch-word> <slug> <prn> <ledger> <ticket-id> <KEY> — a
# hand-opened PR (TK-604 #913) has no merged spec: its PR body, which
# sco_plan_fetch saved, stands in for the plan. With no KEY in the title the
# body must name the ticket (`Closes|Refs|Fixes <KEY>` or `#<ticket-id>`). The
# title goes to pr-title for slice_board_marker (one extra pull read).
_sbd_body_plan() {
  local w="$1" slug="$2" prn="$3" d="$4" tid="$5" key="$6" out
  [ -s "$d/pr-body.md" ] || return 1
  if [ "$w" = none:no-key ]; then
    [ -n "$tid" ] || return 1
    grep -qiE "(close[sd]?|refs?|fix(es|ed)?|resolves?)[[:space:]:]+#?${key}([^A-Za-z0-9_-]|$)" "$d/pr-body.md" \
      || grep -qF "#$tid" "$d/pr-body.md" || return 1
  fi
  cp "$d/pr-body.md" "$d/plan.md" 2>/dev/null || return 1
  out=$(_sco_arm "$slug"; gh_rest GET "repos/$slug/pulls/$prn" 2>/dev/null) \
    && printf '%s' "$out" | jq -r '.title // ""' > "$d/pr-title" 2>/dev/null
  return 0
}

# _sbd_alert <harness> <id> <msg> — one critical page through bin/lane-alert.sh.
_sbd_alert() {
  if [ -n "$1" ] && [ -x "$1/bin/lane-alert.sh" ]; then
    "$1/bin/lane-alert.sh" --severity critical --id "$2" slice-board "$3" >/dev/null 2>&1 || true
  else
    echo "slice-board: $3 (no bin/lane-alert.sh to page with)" >&2
  fi
}

# _sbd_word <dir> <word> <rc> — print the word, log it, return rc.
_sbd_word() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" >> "$1/settle.log" 2>/dev/null
  printf '%s\n' "$2"
  return "$3"
}

slice_board_settle() {
  local project="${1:-}" key="${2:-}" pr="${3:-}" rec="${4:-}" tid="${5:-}" park="${6:-1}" h="${7:-${HARNESS:-${H:-}}}"
  local d prn rc=0 sl=""
  [ "$rec" = - ] && rec=""
  [ -n "$project" ] && [ -n "$key" ] && [[ "$pr" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+ ]] \
    || { printf 'skip:bad-args\n'; return 3; }
  case "$park" in 0|1) ;; *) park=1 ;; esac
  # The switch is BH-5961's, so one row turns both lanes off.
  # shellcheck source=bin/lib/lane-switch.sh
  command -v lane_switch >/dev/null 2>&1 || . "$_SBD_LIB/lane-switch.sh" 2>/dev/null
  if [ -n "$h" ] && command -v lane_switch >/dev/null 2>&1 && HARNESS="$h" lane_switch slice-remainder-off file; then
    printf 'skip:off\n'; return 3
  fi
  case "$(_slr_env "$h" SLICE_REMAINDER_FILE 1)" in 0|no|off|false) printf 'skip:off\n'; return 3 ;; esac
  prn="${pr##*/pull/}"; prn="${prn%%[!0-9]*}"
  if [ -n "$rec" ] && [ -d "$rec" ]; then d="$rec/slice-board"
  elif [ -n "$h" ]; then d="$h/state/slice-board/$project-$key-pr$prn"
  else printf 'skip:no-record\n'; return 3; fi
  mkdir -p "$d" 2>/dev/null || { printf 'deferred:record-write\n'; return 1; }
  # The merge's own lock beside the ledgers (BH-10080): a record ledger and a
  # state ledger of ONE merge never file at once.
  [ -n "$h" ] && mkdir -p "$h/state/slice-board" 2>/dev/null && sl="$h/state/slice-board/.lock-$project-$key-pr$prn"
  # A DEDUPE, not a queue: the builder close-out and the conductor spawn share
  # this ledger, and the second one is answered by `filed`.
  if command -v flock >/dev/null 2>&1 && [ -n "$sl" ]; then
    _sbd_settle_locked "$project" "$key" "$pr" "$rec" "$tid" "$park" "$h" "$d" "$prn" "$sl" 9>"$d/.lock" 8>"$sl" || rc=$?
  elif command -v flock >/dev/null 2>&1; then
    _sbd_settle_locked "$project" "$key" "$pr" "$rec" "$tid" "$park" "$h" "$d" "$prn" "" 9>"$d/.lock" || rc=$?
  else
    _sbd_settle_locked "$project" "$key" "$pr" "$rec" "$tid" "$park" "$h" "$d" "$prn" "" || rc=$?
  fi
  # A skip that decided nothing leaves no ledger behind: the conductor settles
  # every board merge, and most of them are not slices. Nor its lock file.
  if [ "$rc" = 3 ] && [ ! -s "$d/children.json" ]; then rm -rf "$d"; [ -n "$sl" ] && rm -f "$sl"; fi
  return "$rc"
}

# _sbd_ledger_note <project> <harness> <ledger> <ticket-id> <park> <word> <pr> —
# a ledger answer retries a park-1 note that did not post.
_sbd_ledger_note() {
  local id
  [ "$5" = 1 ] && [ ! -e "$3/noted" ] || return 0
  id="${4:-$(head -1 "$3/token" 2>/dev/null)}"
  [ -n "$id" ] && _sbd_ctx "$1" "$2" && _sbd_note "$3" "$id" "$6" "" "$7"
  return 0
}

_sbd_settle_locked() {
  local project="$1" key="$2" pr="$3" rec="$4" tid="$5" park="$6" h="$7" d="$8" prn="$9" sl="${10:-}"
  local plan="" w slug tok id raw prc=0 pkey why lib frc=0 want got keys base trc=0 k="" weak=0 kids
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { printf 'deferred:locked\n'; return 1; }
    if [ -n "$sl" ]; then flock -n 8 || { printf 'deferred:locked\n'; return 1; }; fi
  fi
  # LEDGER FIRST: a second settle is answered before any read or write.
  if [ -s "$d/filed" ]; then printf 'filed:%s\n' "$(head -1 "$d/filed")"; return 0; fi
  if [ -e "$d/unknown-paged" ]; then
    w="unknown:$(head -1 "$d/unknown-paged")"
    _sbd_ledger_note "$project" "$h" "$d" "$tid" "$park" "$w" "$pr"
    printf '%s\n' "$w"; return 2
  fi
  if [ -s "$d/exists" ]; then
    w="exists:$(head -1 "$d/exists")"
    _sbd_ledger_note "$project" "$h" "$d" "$tid" "$park" "$w" "$pr"
    printf '%s\n' "$w"; return 0
  fi

  # ---- the plan: the record's, else the merged spec on main --------------
  if [ -n "$rec" ] && [ -r "$rec/plan.md" ]; then plan="$rec/plan.md"
  elif [ -s "$d/plan.md" ]; then plan="$d/plan.md"
  else
    # shellcheck source=bin/lib/slice-closeout.sh
    command -v sco_plan_fetch >/dev/null 2>&1 || { [ -r "$_SBD_LIB/slice-closeout.sh" ] && . "$_SBD_LIB/slice-closeout.sh"; }
    command -v sco_plan_fetch >/dev/null 2>&1 || { _sbd_word "$d" deferred:no-plan-reader 1; return 1; }
    slug="${pr#https://github.com/}"; slug="${slug%%/pull/*}"
    # An empty record makes sco_plan_fetch read the PR and its merged
    # .harness/specs/<KEY>/plan.md, never a local plan.
    w=$(sco_plan_fetch "$slug" "${key##*-}" "$pr" "" "$d" 2>/dev/null)
    case "$w" in
      ok:*) [ "$(printf '%s' "${w#ok:}" | tr '[:lower:]' '[:upper:]')" = "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" ] \
              || { rm -f "$d/plan.md"; _sbd_word "$d" skip:other-ticket 3; return 3; }
            plan="$d/plan.md" ;;
      # A hand-opened PR has no merged spec: its body is the plan (BH-10080).
      none:spec-404|none:no-key)
            _sbd_body_plan "$w" "$slug" "$prn" "$d" "$tid" "$key" || { _sbd_word "$d" skip:no-plan 3; return 3; }
            plan="$d/plan.md" ;;
      none:*) _sbd_word "$d" skip:no-plan 3; return 3 ;;
      *)      _sbd_word "$d" deferred:plan-read 1; return 1 ;;
    esac
  fi

  # ---- is it a slice of THIS ticket ----------------------------------------
  tok=$(slice_board_token "$plan" "$tid" "$key") || trc=$?
  case "$trc" in
    0) k=$(slice_board_line "$plan" | cut -f1) ;;
    2) _sbd_word "$d" skip:other-ticket 3; return 3 ;;
    *) # No strong SLICE line: a weak marker (BH-10080), else no slice.
       k=$(slice_board_marker "$plan" "$(head -1 "$d/pr-title" 2>/dev/null)" "$tid" "$key") \
         || { printf 'skip:no-slice\n'; return 3; }
       weak=1; tok="${tid:-$key}" ;;
  esac
  printf '%s\n' "$tok" > "$d/token"
  printf '%s\n' "$k" > "$d/k"
  id="${tid:-$tok}"

  # ---- the parent: it must be the ticket the KEY names ---------------------
  if ! _sbd_ctx "$project" "$h"; then
    _sbd_alert "$h" "slice-board-failed:$project:$key:$prn" \
      "slice-board-failed $project/$key: PR $pr merged slice C$k but there is no board context (${TRK_CTX_MISSING:-adapter}); rerun bin/slice-board-settle.sh $project $key $pr ${rec:--} once it is fixed"
    _sbd_word "$d" deferred:board-context 1; return 1
  fi
  raw=$(TRK_DRY=0 TRK_LOG="" TRK_ERR="" trk_board_ticket_raw "$id") || prc=$?
  # curl -f answers 22 for an HTTP error: the id names no readable ticket.
  # Anything else is the transport, and the next tick reads it again.
  if [ "$prc" != 0 ] && [ "$prc" != 22 ]; then _sbd_word "$d" deferred:parent-read 1; return 1; fi
  pkey=$(printf '%s' "$raw" | jq -r '(.ticket // .) | .key // empty | tostring' 2>/dev/null)
  why=""
  if [ "$prc" = 22 ] || [ -z "$pkey" ]; then why="parent"
  elif [ "$(printf '%s' "$pkey" | tr '[:lower:]' '[:upper:]')" != "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" ]; then why="parent"; fi
  [ -z "$why" ] && printf '%s' "$raw" > "$d/parent.json"

  # ---- dedupe on the board: the parent already has children (BH-10080) ------
  # Not when this ledger filed some of them itself: that is a resume.
  if [ -z "$why" ] && [ ! -s "$d/children.txt" ]; then
    kids=$(jq -r '[((.ticket // .) | .children // [])[]? | select(type == "object") | (.key // .id // empty | tostring)] | join(",")' "$d/parent.json" 2>/dev/null)
    if [ -n "$kids" ]; then
      printf '%s\n' "$kids" > "$d/exists"
      [ "$park" = 1 ] && _sbd_note "$d" "$id" "exists:$kids" "$k" "$pr"
      _sbd_word "$d" "exists:$kids" 0; return 0
    fi
  fi

  # ---- the spec, decided once per ledger ------------------------------------
  # A C<j> list files one child per slice. A strong line with a prose rest
  # (`none`) or a weak marker files ONE "Rest of <KEY>" child (BH-10080).
  if [ -z "$why" ] && [ ! -s "$d/children.json" ]; then
    w=""
    [ "$weak" = 0 ] && w=$(slice_remainder_parse "$plan" "${tok:-$id}" "$d/children.json.tmp" "$pr" 2>>"$d/parse.log")
    if [ "${w%%:*}" = ok ]; then mv -f "$d/children.json.tmp" "$d/children.json"
    elif [ "$weak" = 1 ] || [ "$w" = none ]; then
      rm -f "$d/children.json.tmp"
      w=$(_sbd_rest_spec "$plan" "$k" "$key" "$pr" "$d/parent.json" "$d/children.json.tmp" 2>>"$d/parse.log")
      if [ "$w" = ok ]; then mv -f "$d/children.json.tmp" "$d/children.json"
      else rm -f "$d/children.json.tmp"; why="${w:-none}"; fi
    else rm -f "$d/children.json.tmp"; why="${w:-bad:parse}"; fi
  fi
  if [ -n "$why" ]; then
    # The page goes BEFORE the marker: a crash between them pages twice, and
    # the --id collapses that. It is never silent.
    _sbd_alert "$h" "slice-board-unknown:$project:$key:$prn" \
      "SLICE_BOARD_UNKNOWN $project/$key: PR $pr merged a slice but the remaining slices cannot be filed ($why${pkey:+, parent key $pkey}); file them as child tickets by hand"
    printf '%s\n' "$why" > "$d/unknown-paged"
    [ "$park" = 1 ] && _sbd_note "$d" "$id" "unknown:$why" "$k" "$pr"
    _sbd_word "$d" "unknown:$why" 2; return 2
  fi

  # ---- file the children ----------------------------------------------------
  lib="$_SBD_LIB"
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-board.sh" ] || lib="$h/bin/lib"
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-board.sh" ] || { _sbd_word "$d" skip:no-filer 3; return 3; }
  base=$(( $(jq '.[0].ordinal' "$d/children.json") - 1 ))
  # A SUBSHELL: the filer sources its own libs and sets FC_* and TRK_*, and
  # none of that may leak into the lane that called this.
  (
    # shellcheck source=bin/lib/file-children.sh
    . "$lib/file-children.sh" || exit 1
    # shellcheck source=bin/lib/fc-board.sh
    . "$lib/fc-board.sh" || exit 1
    HARNESS="$h" FC_PROJECT="$project" FC_PARENT="$id" FC_KEY="$key" FC_BUILD="$d" \
      FC_SPEC="$d/children.json" FC_KIND=slice FC_LANE=board
    FC_SLICE_BASE="$base" FC_SLICE_PR="$pr" FC_BOARD_PARK="$park"
    export HARNESS FC_SLICE_BASE FC_SLICE_PR FC_BOARD_PARK
    fc_file_board || { printf '%s\n' "${FC_ERROR:-fc_file_board failed}" > "$d/fc-error.txt"; exit 1; }
    fc_dry && exit 10
    exit 0
  ) >>"$d/fc-out.txt" 2>&1 || frc=$?
  [ "$frc" = 10 ] && { _sbd_word "$d" skip:dry-run 3; return 3; }
  want=$(jq 'length' "$d/children.json" 2>/dev/null)
  got=$(grep -cE '^[A-Za-z]+-[0-9]+$' "$d/children.txt" 2>/dev/null)
  if [ "$frc" = 0 ] && [ -n "$want" ] && [ "${got:-0}" = "$want" ]; then
    keys=$(grep -E '^[A-Za-z]+-[0-9]+$' "$d/children.txt" | paste -sd, -)
    printf '%s\n' "$keys" > "$d/filed"
    _sbd_word "$d" "filed:$keys" 0; return 0
  fi
  [ -s "$d/fc-error.txt" ] || printf 'the filer filed %s of %s children (rc %s)\n' "${got:-0}" "${want:-?}" "$frc" > "$d/fc-error.txt"
  _sbd_alert "$h" "slice-board-failed:$project:$key:$prn" \
    "slice-board-failed $project/$key: filing the remaining slices of PR $pr did not finish ($(head -c 300 "$d/fc-error.txt")); rerun bin/slice-board-settle.sh $project $key $pr ${rec:--} --ticket $id, it resumes from $d"
  [ "$park" = 1 ] && _sbd_note "$d" "$id" "deferred:file-failed" "$k" "$pr"
  _sbd_word "$d" deferred:file-failed 1
  return 1
}
