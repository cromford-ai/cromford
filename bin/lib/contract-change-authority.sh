#!/bin/bash
# bin/lib/contract-change-authority.sh — who may clear a contract-change step
# (BH-9929, T10 and T11). Sourced, never executed. No side effect at source time.
#
# THE RULE (Scope 4). A contract step whose SQL drops a table, drops a column
# or merges two tables needs the owner's HUMAN verdict, in lane mode and in
# client mode alike. The PR stage (bin/lib/rb/pr.sh) marks such a PR with the
# label `contract-change:human`; a constraint or CHECK-list step has no such
# label and takes the normal path.
#
#   cc_needs_human <owner/repo> <pr>
#     rc 0  the PR carries the label `contract-change:human`, or its body has
#           the line `CONTRACT-HUMAN-VERDICT: required` (the label write can fail)
#     rc 1  neither
#     rc 2  the labels could not be read (REST failure, not a PR object)
#     One conditional REST read of pulls/<pr> (bin/lib/gh-rest.sh with its
#     ETag cache, never GraphQL). A PR
#     object with no `labels` key reads as no labels (GitHub always sends the
#     key; a test fake may not).
#
#   cc_la_gate <owner/repo> <pr> <head> <lead|conductor>
#     The body of the la_decide hook (bin/lib/lead-authority.sh). Sets LA_REASON
#     when it answers anything but 0.
#     rc 0  not a human-class contract step: la_decide goes on as before
#     rc 1  a human-class step with no human verdict on this head: withheld
#     rc 2  the labels or the verdict could not be read: publish nothing
#     rc 3  a --source human MERGE / MERGE-WITH-NOTES stands on THIS head
#           (conductor only): la_decide answers rc 0
#     It writes no ALERTS line and no beat.
#
#   cc_autopilot_approver <project> <owner/repo> <pr> <sql-file>
#     The T11 question of bin/migration-autopilot.sh for a FLAGGED file. The
#     <sql-file> is the file the autopilot will apply (read at the merge commit):
#     the approver judges THAT SQL, never only the PR metadata, because a fix
#     round can push new SQL after pr.sh marked the PR (BH-9929 review). rc 0 and
#     prints `<approver>\t<parent>\t<step>\t<head>\t<verdict>` only when ALL hold:
#       - cc_enabled <project> is rc 0 (the switch is on)
#       - the file has at least one contract statement (cc_classify_sql), and
#         every other statement (cc_residue_sql) passes
#         bin/check-migration-appliable.sh: no DELETE, TRUNCATE, UPDATE, GRANT
#         or DO rides along with a contract statement
#       - no contract statement carries a rider ACTION (cc_riders_sql): every
#         action of it is a contract action or an additive one, so a
#         `DISABLE ROW LEVEL SECURITY` or `OWNER TO anon` inside the same
#         ALTER TABLE parks the file
#       - the PR has exactly one label `contract-step:contract` and its body line
#         `CONTRACT STEP: contract of #<parent>`. An expand or migrate step is
#         additive by the gate's rules, so a FLAGGED file there is never applied
#       - the jobs worker row (project, parent, contract) exists, its pr_url is
#         this PR, and backup_ref and restore_ref are non-empty
#       - the standing verdict on the PR's head is MERGE or MERGE-WITH-NOTES,
#         by the SAME rule as the merge (cc_la_gate, Scope 4): a --source
#         human verdict when the file drops a table, drops a column or merges
#         tables (cc_human_class); the normal verdict (any standing source)
#         for a constraint, nullability or rename class. One rule for
#         merge and apply, so a step the lane may merge is a step it applies
#         (BH-9929 review: a constraint step merged on the lane's MERGE and
#         then parked forever at the apply).
#     <approver> is the verdict row's reviewer (else its source), never a string
#     from the PR body.
#     rc 3  every check passed except the verdict: no standing verdict on the
#           head yet, not MERGE, a lane verdict on a human class, or the verdict
#           read failed. The caller re-asks on a later tick (the autopilot keeps
#           the file `contract-pending`), so a verdict posted after the merge
#           is read.
#     rc 1  any other answer (an unreadable piece too): the caller keeps
#           today's FLAGGED path.
#
# Bash 3.2 safe (the lead's Mac sources lead-authority.sh): no arrays, no
# mapfile, no ${x,,}.
# gh-rest: no-graphql

_cca_here() {
  local f="${BASH_SOURCE[0]:-}"
  case "$f" in */*) printf '%s' "${f%/*}" ;; *) printf '.' ;; esac
}

# _cca_pr <owner/repo> <pr> — the PR object (pulls/<pr>) on stdout; rc 2 when it
# cannot be read as a PR object.
_cca_pr() {
  local f grc=0
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  case "${2:-}" in ''|*[!0-9]*) return 2 ;; esac
  if ! command -v gh_rest >/dev/null 2>&1 && [ -r "$(_cca_here)/gh-rest.sh" ]; then
    # shellcheck source=bin/lib/gh-rest.sh
    . "$(_cca_here)/gh-rest.sh" 2>/dev/null
  fi
  command -v gh_rest >/dev/null 2>&1 || return 2
  f=$(mktemp "${TMPDIR:-/tmp}/cc-authority.XXXXXX") || return 2
  # ETag on (the gh_rest default): la_decide asks this on every decision, and
  # an unchanged PR answers 304, which GitHub does not count against the rate
  # limit. A label or body edit changes the ETag, so the answer is never stale.
  gh_rest GET "repos/$1/pulls/$2" > "$f" 2>/dev/null || grc=$?
  if [ "$grc" != 0 ] || ! jq -e 'type == "object" and ((.head.sha // "") | type == "string" and length > 0)
        and ((.labels // []) | type == "array")' "$f" >/dev/null 2>&1; then
    rm -f "$f"; return 2
  fi
  cat "$f"; rm -f "$f"
}

# _cca_labels <pr-json> — the label names, one per line.
_cca_labels() {
  printf '%s' "$1" | jq -r '(.labels // [])[] | if type == "object" then (.name // "") else tostring end' 2>/dev/null
}

# _cca_human_marked <pr-json> — rc 0 on the label `contract-change:human` OR a
# body line `CONTRACT-HUMAN-VERDICT: required` (pr.sh writes the line before the
# PR opens, so a failed label write never lets the hold fail open).
_cca_human_marked() {
  _cca_labels "$1" | grep -qxF 'contract-change:human' && return 0
  printf '%s' "$1" | jq -r '.body // ""' 2>/dev/null | tr -d '\r' \
    | grep -qE '^CONTRACT-HUMAN-VERDICT:[[:space:]]*required[[:space:]]*$'
}

cc_needs_human() {
  local pr
  pr=$(_cca_pr "${1:-}" "${2:-}") || return 2
  _cca_human_marked "$pr"
}

# _cca_verdict <owner/repo> <pr> <head> — the standing verdict line (vd_standing:
# verdict, source, id, created_at, report_url, reviewer). rc 1 none, rc 2 unreadable.
_cca_verdict() {
  local line rc=0
  if ! command -v vd_standing >/dev/null 2>&1 && [ -r "$(_cca_here)/verdicts.sh" ]; then
    # shellcheck source=bin/lib/verdicts.sh
    . "$(_cca_here)/verdicts.sh" 2>/dev/null
  fi
  command -v vd_standing >/dev/null 2>&1 || return 1
  line=$(vd_standing "$1" "$2" "$3" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

cc_la_gate() {
  local slug="${1:-}" pr="${2:-}" head="${3:-}" source="${4:-}" rc=0 line
  cc_needs_human "$slug" "$pr" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) LA_REASON="the labels of $slug#$pr could not be read (contract-change:human check)"; return 2 ;;
  esac
  if [ "$source" = conductor ]; then
    rc=0; line=$(_cca_verdict "$slug" "$pr" "$head") || rc=$?
    if [ "$rc" = 2 ]; then LA_REASON="the standing verdict of $slug#$pr could not be read (contract-change:human check)"; return 2; fi
    if [ "$rc" = 0 ] && [ "$(printf '%s' "$line" | cut -f2)" = human ]; then
      case "$(printf '%s' "$line" | cut -f1)" in
        MERGE|MERGE-WITH-NOTES) LA_REASON="a human verdict stands on ${head:0:12} (contract step)"; return 3 ;;
      esac
    fi
  fi
  LA_REASON="contract step drops a table/column or merges tables: needs a --source human verdict"
  return 1
}

cc_autopilot_approver() {
  local project="${1:-}" slug="${2:-}" num="${3:-}" sql="${4:-}" pr step n parent head row line who src v
  local classes res rc
  if { ! command -v cc_enabled >/dev/null 2>&1 || ! command -v cc_residue_sql >/dev/null 2>&1; } && [ -r "$(_cca_here)/contract-change.sh" ]; then
    # shellcheck source=bin/lib/contract-change.sh
    . "$(_cca_here)/contract-change.sh" 2>/dev/null
  fi
  command -v cc_enabled >/dev/null 2>&1 || return 1
  cc_enabled "$project" || return 1
  # The SQL itself: a contract class, nothing else that is not additive.
  [ -n "$sql" ] && [ -r "$sql" ] || return 1
  command -v cc_classify_sql >/dev/null 2>&1 && command -v cc_residue_sql >/dev/null 2>&1 || return 1
  classes=$(cc_classify_sql "$sql") || return 1
  [ -n "$classes" ] || return 1
  res=$(mktemp "${TMPDIR:-/tmp}/cc-residue.XXXXXX") || return 1
  rc=0; cc_residue_sql "$sql" > "$res" || rc=1
  if [ "$rc" = 0 ] && [ -s "$res" ]; then
    if [ -x "$(_cca_here)/../check-migration-appliable.sh" ]; then
      "$(_cca_here)/../check-migration-appliable.sh" "$project" "${res%/*}" "$res" >/dev/null 2>&1 || rc=1
    else
      rc=1
    fi
  fi
  rm -f "$res"
  [ "$rc" = 0 ] || return 1
  # Per ACTION too: no rider inside a contract statement (cc_riders_sql).
  command -v cc_riders_sql >/dev/null 2>&1 || return 1
  res=$(cc_riders_sql "$sql") || return 1
  [ -z "$res" ] || return 1
  pr=$(_cca_pr "$slug" "$num") || return 1
  step=$(_cca_labels "$pr" | sed -nE 's/^contract-step:(expand|migrate|contract)$/\1/p')
  n=$(printf '%s' "$step" | grep -c .)
  [ "$n" = 1 ] || return 1
  [ "$step" = contract ] || return 1
  parent=$(printf '%s' "$pr" | jq -r '.body // ""' 2>/dev/null \
    | sed -nE "s/^[[:space:]]*CONTRACT STEP: $step of #([0-9]+)[[:space:]]*\$/\\1/p" | head -1)
  [ -n "$parent" ] || return 1
  head=$(printf '%s' "$pr" | jq -r '.head.sha // ""' | tr 'A-F' 'a-f')
  if ! command -v _jobs_req >/dev/null 2>&1 && [ -r "$(_cca_here)/contract-change-record.sh" ]; then
    # shellcheck source=bin/lib/contract-change-record.sh
    . "$(_cca_here)/contract-change-record.sh" 2>/dev/null && _cc_rec_client
  fi
  command -v _jobs_req >/dev/null 2>&1 || return 1
  row=$(_jobs_req GET "/api/contract-changes?project=$project&parent_ticket=$parent&step=$step" 2>/dev/null) || return 1
  row=$(printf '%s' "$row" | jq -c --arg p "$project" --arg s "$step" --argjson t "$parent" --arg n "$num" '
      [(.rows // [])[] | select(.project == $p and (.parent_ticket | tostring) == ($t | tostring) and .step == $s)
       | select((.pr_url // "") | test("/pull/" + $n + "$"))] | first // empty' 2>/dev/null)
  [ -n "$row" ] || return 1
  printf '%s' "$row" | jq -e '((.backup_ref // "") | length > 0) and ((.restore_ref // "") | length > 0)' >/dev/null 2>&1 || return 1
  line=$(_cca_verdict "$slug" "$num" "$head") || return 3
  v=$(printf '%s' "$line" | cut -f1)
  case "$v" in MERGE|MERGE-WITH-NOTES) ;; *) return 3 ;; esac
  src=$(printf '%s' "$line" | cut -f2)
  # Scope 4, the same rule as cc_la_gate at the merge: a drop-table,
  # drop-column, merge or type class needs a --source human verdict (a
  # person confirms the self-attested BACKUP and RESTORE-TESTED lines before
  # rows can be lost; a type cast can lose every value as a drop does). A constraint, nullability or rename class needs the
  # normal review only.
  if cc_human_class "$classes"; then
    [ "$src" = human ] || return 3
  fi
  who=$(printf '%s' "$line" | cut -f6)
  case "$who" in ''|-) who="$src" ;; esac
  who=$(printf '%s' "$who" | tr -c 'A-Za-z0-9_.@:-' '_')
  [ -n "$who" ] || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$who" "$parent" "$step" "$head" "$v"
}
