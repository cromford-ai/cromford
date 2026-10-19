#!/bin/bash
# bin/lib/pr-owner/shipped.sh — the done-ticket close guard of
# bin/pr-owner-sweep.sh. Sourced, never executed. Rules: docs/PR-OWNERSHIP.md §11.
#
# A "done ticket" close is one of: superseded rule 1 (`merged-#N`), superseded
# rule 2 (`ticket-done` / `ticket-rejected`) and the sweep's ORPHAN arm
# `close-duplicate:N`. Each one claims the PR's work already shipped. Superseded
# rule 3 (older duplicate of an open keeper) is not a done-ticket close and is
# not guarded here.
#
# po_done_close_guard <by> — rc 0 = clear to close, rc 2 = keep the PR open.
#   Reads PO_SLUG PO_NUM PO_HEAD PO_MC_STATE, the sweep's NOW, and the PR's
#   labels and updatedAt from the sweep's open list (PO_OPENF, default
#   $TD/open.json). On a skip it appends `#<n>:<word>` to HELD and logs one line
#   `<slug>#<n>: done-ticket close skipped (<by>) — <reason>`. Checks, first
#   match keeps the PR open:
#     1 label:<name>   a label in PR_OWNER_DONE_SKIP_LABELS (case-insensitive)
#       armed:<STATE>  the conductor row is READY, QUEUED or MERGING
#     2 recent:<m>m    updatedAt is less than PR_OWNER_DONE_RECENT_MIN minutes
#                      before NOW (0 = this check off); an unreadable
#                      updatedAt is recent:unreadable
#     3 unshipped:<path> / shipped-unknown:<why>   po_shipped below
#   It only reads, so it runs under PR_OWNER_DRY_RUN=1 too.
#
# po_done_skip_reason <labels> <mc_state> <updatedAt> <now> [recent_min] [skip_labels]
#   Pure: checks 1 and 2. <labels> is newline-separated. Prints the reason and
#   returns 0 for a skip; returns 1 (nothing printed) when neither check fires.
#
# po_shipped <slug> <num> <head> <ref> — is the PR's change already on <ref>?
#   Prints `shipped` (rc 0), `unshipped <path>` (rc 1) or `unknown <why>` (rc 2).
#   "Merging this PR changes nothing" is the test, never "its commits are on
#   main": a squash merge never puts a branch's commits on main. Per entry of
#   GET pulls/<n>/files (one page), main's blob at the path must equal the
#   head's: added|modified|changed|copied|unchanged need the same sha, removed
#   needs a 404, renamed needs the same sha at filename and a 404 at
#   previous_filename. An empty list is shipped. Fail closed: a failed read, a
#   non-array, 100 entries (could be more), more than PR_OWNER_SHIPPED_MAX_FILES,
#   an entry with no sha, a directory where a file is expected, or a status it
#   does not know is `unknown`.
#
# po_main_sha <slug> — the default branch's HEAD sha, cached per repo in $TD.
#
# THE MEMO: state/pr-owners/<owner_repo>.shipped.tsv under ${HARNESS:-${H:-}},
#   rows `num head main verdict detail epoch`. Only `unshipped` is written (a
#   shipped PR is closed at once, and unknown must re-read). A row is reused only
#   when both head and main match, so it never goes stale. The newest 200 rows
#   are kept. No root, or PO_SHIPPED_MEMO=0, means no memo.

_po_sh_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_po_sh_say() { if declare -F say >/dev/null 2>&1; then say "$*"; else echo "$*" >&2; fi; }
_po_sh_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

PO_DONE_SKIP_LABELS_DEFAULT="hold merge-queue queue-solo fix-main-red"
PO_SHIPPED_MEMO_ROWS=200

# The knobs, each read once per call: the sweep's PO_* value, else the env, else
# the documented default.
_po_sh_recent_min() { _po_sh_num "${PO_DONE_RECENT_MIN:-${PR_OWNER_DONE_RECENT_MIN:-}}" 120; }
_po_sh_max_files() { _po_sh_num "${PO_SHIPPED_MAX_FILES:-${PR_OWNER_SHIPPED_MAX_FILES:-}}" 60; }
_po_sh_skip_labels() { printf '%s' "${PO_DONE_SKIP_LABELS:-${PR_OWNER_DONE_SKIP_LABELS:-$PO_DONE_SKIP_LABELS_DEFAULT}}"; }

# The REST helpers, loaded on first use from next to this lib. Never the CLI.
_po_sh_rest() {
  command -v gh_rest >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "${BASH_SOURCE[0]%/*}/../gh-rest.sh" ] && . "${BASH_SOURCE[0]%/*}/../gh-rest.sh"
  command -v gh_rest >/dev/null 2>&1
}

po_done_skip_reason() {
  local labels="${1:-}" mc="${2:--}" upd="${3:-}" now="${4:-}" rmin skip l w t age
  rmin=$(_po_sh_num "${5:-}" "$(_po_sh_recent_min)")
  skip="${6:-$(_po_sh_skip_labels)}"
  skip=$(printf '%s' "$skip" | tr 'A-Z' 'a-z')
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    l=$(printf '%s' "$l" | tr 'A-Z' 'a-z')
    for w in $skip; do
      [ "$l" = "$w" ] && { printf 'label:%s\n' "$l"; return 0; }
    done
  done <<<"$labels"
  case "$mc" in READY|QUEUED|MERGING) printf 'armed:%s\n' "$mc"; return 0 ;; esac
  [ "$rmin" -gt 0 ] || return 1
  t=""; [ -n "$upd" ] && [ "$upd" != - ] && t=$(date -u -d "$upd" +%s 2>/dev/null)
  if [ -z "$t" ] || [[ ! $now =~ ^[0-9]+$ ]]; then printf 'recent:unreadable\n'; return 0; fi
  age=$(( now - t ))
  if [ "$age" -lt $(( rmin * 60 )) ]; then
    [ "$age" -lt 0 ] && age=0
    printf 'recent:%sm\n' "$(( age / 60 ))"; return 0
  fi
  return 1
}

po_main_sha() {
  local slug="${1:-}" cache="" f sha rc=0
  [ -n "$slug" ] || return 1
  if [ -n "${TD:-}" ] && [ -d "$TD" ]; then
    cache="$TD/po-main-sha-${slug//\//_}"
    [ -s "$cache" ] && { cat "$cache"; return 0; }
  fi
  _po_sh_rest || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/po-main.XXXXXX") || return 1
  gh_rest GET "repos/$slug/commits/HEAD" > "$f" </dev/null || rc=$?
  sha=""; [ "$rc" = 0 ] && sha=$(jq -r 'if type == "object" then .sha // "" else "" end' "$f" 2>/dev/null)
  rm -f "$f"
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || return 1
  [ -n "$cache" ] && printf '%s\n' "$sha" > "$cache"
  printf '%s\n' "$sha"
}

_po_sh_memo_file() {
  local root; root=$(_po_sh_root)
  [ -n "$root" ] && [ "${PO_SHIPPED_MEMO:-1}" != 0 ] || return 1
  printf '%s/state/pr-owners/%s.shipped.tsv' "$root" "${1//\//_}"
}

_po_sh_memo_put() { # <slug> <num> <head> <ref> <detail>
  local mf tmp
  mf=$(_po_sh_memo_file "$1") || return 0
  mkdir -p "${mf%/*}" 2>/dev/null || return 0
  tmp="$mf.tmp.$$"
  { [ -r "$mf" ] && awk -F'\t' -v n="$2" '$1 != n' "$mf"
    printf '%s\t%s\t%s\tunshipped\t%s\t%s\n' "$2" "$3" "$4" "$5" "$(date -u +%s)"
  } | tail -n "$PO_SHIPPED_MEMO_ROWS" > "$tmp" && mv -f "$tmp" "$mf" || rm -f "$tmp"
  return 0
}

# _po_sh_blob <slug> <path> <ref> — prints the blob sha (rc 0), rc 44 = absent,
# rc 2 = unknown (prints why).
_po_sh_blob() {
  local enc f rc=0 out
  enc=$(jq -rn --arg p "$2" '$p | split("/") | map(@uri) | join("/")') || { echo "encode"; return 2; }
  f=$(mktemp "${TMPDIR:-/tmp}/po-blob.XXXXXX") || { echo "tmp"; return 2; }
  gh_rest GET "repos/$1/contents/$enc?ref=$3" > "$f" </dev/null || rc=$?
  case "$rc" in
    0)  out=$(jq -r 'if type == "array" then "!dir" elif type == "object" then (.sha // "!nosha") else "!bad" end' "$f" 2>/dev/null) || out="!bad"
        rm -f "$f"
        case "$out" in '!dir') echo "dir:$2"; return 2 ;; '!'*|'') echo "contents-unreadable:$2"; return 2 ;; esac
        printf '%s\n' "$out"; return 0 ;;
    44) rm -f "$f"; return 44 ;;
    *)  rm -f "$f"; echo "contents-read:$rc:$2"; return 2 ;;
  esac
}

po_shipped() {
  local slug="${1:-}" num="${2:-}" head="${3:--}" ref="${4:-}" mf row f rc=0 n max st path sha prev b brc memo=0
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$ref" ] && [ "$ref" != - ] || { echo "unknown args"; return 2; }
  [ -n "$head" ] && [ "$head" != - ] && memo=1
  if [ "$memo" = 1 ] && mf=$(_po_sh_memo_file "$slug") && [ -r "$mf" ]; then
    row=$(awk -F'\t' -v n="$num" -v h="$head" -v m="$ref" '$1==n && $2==h && $3==m && $4=="unshipped" {d=$5} END {if (d != "") print d}' "$mf")
    [ -n "$row" ] && { printf 'unshipped %s\n' "$row"; return 1; }
  fi
  _po_sh_rest || { echo "unknown no-rest-lib"; return 2; }
  max=$(_po_sh_max_files)
  f=$(mktemp "${TMPDIR:-/tmp}/po-files.XXXXXX") || { echo "unknown tmp"; return 2; }
  gh_rest GET "repos/$slug/pulls/$num/files?per_page=100" > "$f" </dev/null || rc=$?
  [ "$rc" = 0 ] || { rm -f "$f"; echo "unknown files-read:$rc"; return 2; }
  n=$(jq -r 'if type == "array" then length else "!" end' "$f" 2>/dev/null) || n="!"
  [[ $n =~ ^[0-9]+$ ]] || { rm -f "$f"; echo "unknown files-not-a-list"; return 2; }
  [ "$n" -ge 100 ] && { rm -f "$f"; echo "unknown files:100+"; return 2; }
  [ "$n" -gt "$max" ] && { rm -f "$f"; echo "unknown files:$n>$max"; return 2; }
  while IFS=$'\t' read -r st path sha prev; do
    [ -n "$path" ] || { rm -f "$f"; echo "unknown entry-no-filename"; return 2; }
    case "$st" in
      removed)
        b=$(_po_sh_blob "$slug" "$path" "$ref"); brc=$?
        case "$brc" in
          44) ;;
          0)  _po_sh_unshipped "$slug" "$num" "$head" "$ref" "$path" "$memo"; rm -f "$f"; return 1 ;;
          *)  rm -f "$f"; echo "unknown $b"; return 2 ;;
        esac ;;
      added|modified|changed|copied|unchanged|renamed)
        [ -n "$sha" ] || { rm -f "$f"; echo "unknown no-sha:$path"; return 2; }
        b=$(_po_sh_blob "$slug" "$path" "$ref"); brc=$?
        case "$brc" in
          0)  [ "$b" = "$sha" ] || { _po_sh_unshipped "$slug" "$num" "$head" "$ref" "$path" "$memo"; rm -f "$f"; return 1; } ;;
          44) _po_sh_unshipped "$slug" "$num" "$head" "$ref" "$path" "$memo"; rm -f "$f"; return 1 ;;
          *)  rm -f "$f"; echo "unknown $b"; return 2 ;;
        esac
        if [ "$st" = renamed ]; then
          [ -n "$prev" ] || { rm -f "$f"; echo "unknown no-previous:$path"; return 2; }
          b=$(_po_sh_blob "$slug" "$prev" "$ref"); brc=$?
          case "$brc" in
            44) ;;
            0)  _po_sh_unshipped "$slug" "$num" "$head" "$ref" "$prev" "$memo"; rm -f "$f"; return 1 ;;
            *)  rm -f "$f"; echo "unknown $b"; return 2 ;;
          esac
        fi ;;
      *) rm -f "$f"; echo "unknown status:${st:-none}:$path"; return 2 ;;
    esac
  done < <(jq -r '.[] | [(.status // ""), (.filename // ""), (.sha // ""), (.previous_filename // "")] | @tsv' "$f" 2>/dev/null)
  rm -f "$f"
  echo shipped
}

_po_sh_unshipped() { # <slug> <num> <head> <ref> <path> <memo 0|1>
  [ "$6" = 1 ] && _po_sh_memo_put "$1" "$2" "$3" "$4" "$5"
  printf 'unshipped %s\n' "$5"
}

po_done_close_guard() {
  local by="${1:-?}" openf="${PO_OPENF:-${TD:-}/open.json}" labels="" upd="" now reason="" out rc ref
  now="${NOW:-$(date -u +%s)}"
  if [ -r "$openf" ]; then
    labels=$(jq -r --argjson n "${PO_NUM:-0}" '.[] | select(.number == $n) | (.labels // [])[] | .name // empty' "$openf" 2>/dev/null)
    upd=$(jq -r --argjson n "${PO_NUM:-0}" 'first(.[] | select(.number == $n) | .updatedAt // empty)' "$openf" 2>/dev/null)
  fi
  if ! reason=$(po_done_skip_reason "$labels" "${PO_MC_STATE:--}" "$upd" "$now"); then
    reason=""
    if ! ref=$(po_main_sha "$PO_SLUG"); then
      reason="shipped-unknown:main-sha-unreadable"
    else
      out=$(po_shipped "$PO_SLUG" "$PO_NUM" "${PO_HEAD:--}" "$ref"); rc=$?
      case "$rc" in
        0) ;;
        1) reason="unshipped:${out#unshipped }" ;;
        *) reason="shipped-unknown:${out#unknown }" ;;
      esac
    fi
  fi
  [ -n "$reason" ] || return 0
  HELD="${HELD:+$HELD,}#$PO_NUM:${reason%%:*}"
  _po_sh_say "$PO_SLUG#$PO_NUM: done-ticket close skipped ($by) — $reason"
  return 2
}
