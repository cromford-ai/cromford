# shellcheck shell=bash
# bin/blocked-resolver.d/bh-10198-read-after-change.sh — BH-10198: the
# resolver reads a quiet park again only after a change.
#
# WHY. bin/lib/br/opt/unchanged.sh skips a row that ended on a quiet exit
# (held, escalated, stalled, needs-human, ...) only for BR_UNCHANGED_RECHECK_S
# (1800 s). After that the row is read again from GitHub (the hold issue, its
# comment pages, the merged-PR search, the PR), and it ends on the same exit.
# On the hub, hour 16 of 2026-11-26, the lane made 1,662 GitHub calls, most of
# them on these rows. A RESUME comment is also seen up to 30 minutes late.
#
# WHAT. The unchanged ledger line stores two more columns at the quiet exit,
# both taken by br_rac_pre BEFORE the row's GitHub reads:
#   wm  the wakes watermark (wakes.wm of bin/lib/pr-snapshot-wakes.sh, the
#       highest worker wake id read into the box's mirror). A wake that lands
#       during the reads has a higher id, so it wakes the next tick. Ids are
#       assigned by the worker: no box clock is compared with a worker clock.
#   rv  the PR record version `<content sha1>|<head_sha>`: a hash of the
#       record fields a park depends on (state, draft, head and base sha,
#       mergeable_state, labels, checks, statuses, reviews, review_decision,
#       queue_state, mergify_queue, last_comment_id, merged_at), from
#       pr_record_peek. A write that changes no such field (refreshed_at
#       alone) is not a change. `-` for a row with no PR.
# The skip asks br_rac_due, only past the 1800 s window, which prints one word:
#   changed  a wake row with an id above wm for the ticket issue (kind
#            issue), the PR (kind pr) or the PR head (kind checks), or a
#            record version that is not rv. The row is read now.
#   quiet    every source answered and nothing changed. The skip holds until
#            BR_RAC_BACKSTOP_S (default 21600 = 6 hours), the full read
#            backstop. The local fingerprint must still be equal.
#   unknown  a source could not answer (the mirror is not complete and fresh,
#            its watermark is below wm, no record row, a jobs error), the row
#            has no PR (an App comment or a label change on the issue can make
#            no wake), the PR is in another repo, the class is job-abandoned
#            (a newer job row makes no wake and moves no record), the tracker
#            is not GitHub Issues, or the ledger line is from before this
#            change. The skip is today's: 1800 s, then a GitHub read.
#
# The wakes come from the read-only mirror of the worker's wakes table
# (bin/lib/pr-snapshot-wakes.sh: prs_changed, prs_feed_fresh, its wakes.wm and
# changed.tsv); the record from pr_record_peek (bin/lib/pr-record.sh), one
# jobs GET, only for a row that is read or is past the window. Neither is a
# GitHub call. The mirror is primed once per repo per run.
#
# Off: BR_RAC_BACKSTOP_S=0, or BR_OPT_OFF=bh-10198-read-after-change (then
# the skip is today's). Functions only; no `exit`; the root is ${H:-}.

# _br_rac_int <value> — prints the value as digits, rc 1 when it is not digits.
_br_rac_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$((10#$1))" ;; esac; }

# br_rac_backstop — the knob BR_RAC_BACKSTOP_S
# (catalog/lanes.d/blocked-resolver.knobs.d/BR_RAC_BACKSTOP_S.json). The code
# fallback 21600 applies only when the value is not digits.
br_rac_backstop() { _br_rac_int "${BR_RAC_BACKSTOP_S:-}" || printf 21600; }

# _br_rac_load — source the wakes mirror and the record reader once. rc 1 when
# either is missing; the caller then answers unknown.
_br_rac_load() {
  if [ "$(type -t prs_wake_seen)" != function ] && [ -r "${H:-}/bin/lib/pr-snapshot.sh" ]; then
    # shellcheck source=bin/lib/pr-snapshot.sh
    . "${H:-}/bin/lib/pr-snapshot.sh" >/dev/null 2>&1
  fi
  if [ "$(type -t pr_record_peek)" != function ] && [ -r "${H:-}/bin/lib/pr-record.sh" ]; then
    # shellcheck source=bin/lib/pr-record.sh
    . "${H:-}/bin/lib/pr-record.sh" >/dev/null 2>&1
  fi
  [ "$(type -t prs_wake_seen)" = function ] && [ "$(type -t pr_record_peek)" = function ]
}

# _br_rac_conf <p> <field> — fleet-conf.sh, memoised for the run (the repo).
_br_rac_conf() {
  local k="$1:$2" v
  case "${_BR_RAC_CONF:-}" in *$'\n'"$k="*)
    v="${_BR_RAC_CONF#*$'\n'"$k="}"; printf '%s' "${v%%$'\n'*}"; return 0 ;;
  esac
  v=$("${H:-}/bin/fleet-conf.sh" "$1" "$2" 2>/dev/null) || v=""
  _BR_RAC_CONF="${_BR_RAC_CONF:-}"$'\n'"$k=$v"$'\n'
  printf '%s' "$v"
}

# br_rac_begin <p> — called at the top of the skip for EVERY row. Primes the
# repo's wakes mirror once per run and warms tracker_kind's per-process cache
# in this shell (br_rac_due runs in a command substitution, where a cache
# write is lost).
br_rac_begin() {
  local slug
  slug=$(_br_rac_conf "${1:-}" repo)
  if [ -n "$slug" ] && [ "$slug" != - ]; then
    case " ${_BR_RAC_PRIMED:-} " in
      *" $slug "*) ;;
      *) _BR_RAC_PRIMED="${_BR_RAC_PRIMED:-} $slug"
         _br_rac_load && prs_changed "$slug" >/dev/null 2>&1 ;;
    esac
  fi
  if [ "$(type -t tracker_kind)" != function ] && [ -r "${H:-}/bin/lib/tracker.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "${H:-}/bin/lib/tracker.sh" >/dev/null 2>&1
  fi
  [ "$(type -t tracker_kind)" = function ] && tracker_kind "${1:-}" >/dev/null 2>&1
  return 0
}

# _br_rac_wm <owner/repo> — the mirror's watermark (digits), rc 1 when the
# mirror is not complete and fresh: then no mark is taken and no answer given.
_br_rac_wm() {
  local d v
  [ "$(type -t _prs_dir)" = function ] || return 1
  prs_changed "${1:-}" >/dev/null 2>&1 || return 1
  prs_feed_fresh "${1:-}" >/dev/null 2>&1 || return 1
  d=$(_prs_dir "${1:-}" 2>/dev/null) || return 1
  v=$(tr -dc '0-9' 2>/dev/null < "$d/wakes.wm")
  _br_rac_int "$v"
}

# br_rac_pre <p> <rkey> <url> — the row will be read: take its change mark now,
# before any GitHub read. Sets BR_RAC_MARK to `<rkey> TAB <wm|-> TAB <rv>` (rv
# empty when the record did not answer).
br_rac_pre() {
  local slug wm rv
  slug=$(_br_rac_conf "${1:-}" repo)
  if _br_rac_load && wm=$(_br_rac_wm "$slug"); then :; else wm=-; fi
  rv=$(br_rac_version "${3:--}") || rv=""
  BR_RAC_MARK="${2:-}"$'\t'"$wm"$'\t'"$rv"
  return 0
}

# br_rac_mark <rkey> — `<wm> TAB <rv>` of this row's br_rac_pre, or `- TAB`
# (unknown) when br_rac_pre did not run for this row.
br_rac_mark() {
  local r="${BR_RAC_MARK:-}" k wm rv
  IFS=$'\t' read -r k wm rv <<<"$r"
  if [ -n "${1:-}" ] && [ "$k" = "$1" ]; then printf '%s\t%s' "${wm:--}" "$rv"
  else printf -- '-\t'; fi
}

# _br_rac_pr <url> — `<owner/repo> <number>` of a PR url, rc 1 for any other url.
_br_rac_pr() {
  [[ "${1:-}" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+) ]] || return 1
  printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# br_rac_version <url> — the PR record version `<content sha1>|<head_sha>` (see
# the header). `-` for a url that is not a PR; rc 1 (prints nothing) when the
# record cannot answer.
br_rac_version() {
  local pr row h c
  pr=$(_br_rac_pr "${1:-}") || { printf -- -; return 0; }
  _br_rac_load || return 1
  row=$(pr_record_peek "${pr% *}" "${pr#* }" 2>/dev/null) || return 1
  c=$(jq -cS 'select(type == "object" and (.state | type) == "string")
        | {state, draft, head_sha, base_sha, mergeable_state, labels, checks, statuses, reviews,
           review_decision, queue_state, mergify_queue, last_comment_id, merged_at}' <<<"$row" 2>/dev/null)
  [ -n "$c" ] || return 1
  h=$(jq -r '(.head_sha // "") | ascii_downcase' <<<"$row" 2>/dev/null)
  printf '%s|%s' "$(printf '%s' "$c" | sha1sum | cut -c1-40)" "$h"
}

# _br_rac_wake <owner/repo> <kind> <key> <wm> — changed (a wake row of that
# kind and key with an id above wm), quiet, or unknown (the mirror is not
# complete and fresh, or its watermark is below wm: it was reset).
_br_rac_wake() {
  local now d
  now=$(_br_rac_wm "$1") || { printf unknown; return 0; }
  [ "$now" -ge "$4" ] || { printf unknown; return 0; }
  d=$(_prs_dir "$1" 2>/dev/null) || { printf unknown; return 0; }
  [ -r "$d/changed.tsv" ] || { printf quiet; return 0; }
  # shellcheck disable=SC2016 # awk program, not shell
  if awk -F'\t' -v k="$2" -v y="$3" -v m="$4" '$1 == k && $2 == y && ($3 + 0) > (m + 0) { f = 1; exit } END { exit f ? 0 : 1 }' \
       "$d/changed.tsv" 2>/dev/null; then printf changed; else printf quiet; fi
}

# br_rac_due <p> <tkey> <url> <wm> <rv> <class> — one word: changed, quiet or
# unknown (see the header). Makes no GitHub call.
br_rac_due() {
  local p="${1:-}" tkey="${2:--}" url="${3:--}" wm="${4:-}" rv="${5:-}" slug issue pr ps pn cur w head unk=0
  [ "$(br_rac_backstop)" -gt 0 ] || { echo unknown; return 0; }
  # A newer job row of an abandoned ticket makes no wake and moves no record.
  [ "${6:-}" != job-abandoned ] || { echo unknown; return 0; }
  wm=$(_br_rac_int "$wm") || { echo unknown; return 0; }
  [ -n "$rv" ] || { echo unknown; return 0; }
  slug=$(_br_rac_conf "$p" repo)
  [ -n "$slug" ] && [ "$slug" != - ] || { echo unknown; return 0; }
  _br_rac_load || { echo unknown; return 0; }
  # A tracker off GitHub Issues takes its answers (RESUME, a person's reply)
  # where no wake is made: today's window for its rows. trk_gh_issue_number
  # (bin/lib/tracker.sh): rc 0 the issue number, rc 1 GitHub Issues but no
  # issue key, rc 3 (or no lib) another tracker.
  if [ "$(type -t trk_gh_issue_number)" != function ] && [ -r "${H:-}/bin/lib/tracker.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "${H:-}/bin/lib/tracker.sh" >/dev/null 2>&1
  fi
  [ "$(type -t trk_gh_issue_number)" = function ] || { echo unknown; return 0; }
  w=0; issue=$(trk_gh_issue_number "$p" "$tkey" 2>/dev/null) || w=$?
  case "$w" in 0) ;; 1) issue="" ;; *) echo unknown; return 0 ;; esac
  # A park with no PR has no record version, and the issue wakes alone are not
  # enough: an issue_comment from the fleet's own Apps, an unlabeled event and
  # most labels make no wake. Such a park is unknown (today's window).
  pr=$(_br_rac_pr "$url") || { echo unknown; return 0; }
  ps="${pr% *}"; pn="${pr#* }"
  # One watermark per repo: a PR in another repo is unknown.
  [ "${ps,,}" = "${slug,,}" ] || { echo unknown; return 0; }
  if [ -n "${issue:-}" ]; then
    w=$(_br_rac_wake "$slug" issue "$issue" "$wm")
    case "$w" in changed) echo changed; return 0 ;; unknown) unk=1 ;; esac
  fi
  w=$(_br_rac_wake "$slug" pr "$pn" "$wm")
  case "$w" in changed) echo changed; return 0 ;; unknown) unk=1 ;; esac
  if cur=$(br_rac_version "$url"); then
    [ "$cur" = "$rv" ] || { echo changed; return 0; }
    head="${cur##*|}"
    if [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
      w=$(_br_rac_wake "$slug" checks "$head" "$wm")
      case "$w" in changed) echo changed; return 0 ;; unknown) unk=1 ;; esac
    else unk=1; fi
  else unk=1; fi
  if [ "$unk" = 1 ]; then echo unknown; else echo quiet; fi
}
