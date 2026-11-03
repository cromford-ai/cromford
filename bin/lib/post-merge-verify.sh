#!/bin/bash
# shellcheck shell=bash
# gh-identity: app-token
# bin/lib/post-merge-verify.sh — BH-3690: does prod serve the sha we merged?
# Sourced by bin/post-merge-verify.sh, never run.
#
#   pmv_judge <merged> <served> <compare-status>  -> match | mismatch | unreadable
#   pmv_key <project> <target> <merged>           -> <project>:<target>@<merged>, lowercase
#   pmv_act <project> <target> <merged> <served> <verdict> <log-file> [note]
#
# pmv_act's side effects, per verdict:
#   match       ledger(post_merge_verify, key) = verified, one log line. No page, no gh.
#   unreadable  ledger = unreadable, one log line. Never paged as a mismatch (D11).
#   mismatch    page once through bin/alert-line.sh, then stamp `paged`; then find
#               or file one ticket on the harness repo (infra, never ai-build) and
#               stamp `ticketed` only from a parsed issue number. A key that is
#               already ticketed does nothing; one that is paged only retries the
#               ticket. The local marker state/post-merge-verify/<sha1 of key> is
#               the dedup fallback when the ledger is unreachable.
# The root is HARNESS, then H (BH-2613). No root is no answer: pmv_act returns 1.

# BH-8962: the ticket is filed over REST, never `gh issue create` (GraphQL).
# Without the helper no ticket is filed and the next run retries.
# shellcheck source=bin/lib/tracker/gh-issue-create.sh
[ -r "$(dirname "${BASH_SOURCE[0]}")/tracker/gh-issue-create.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/tracker/gh-issue-create.sh"

pmv_norm() { printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }

pmv_judge() {
  local m s c
  m=$(pmv_norm "${1:-}"); s=$(pmv_norm "${2:-}"); c=$(pmv_norm "${3:-}")
  if ! [[ "$s" =~ ^[0-9a-f]{7,40}$ ]] || ! [[ "$m" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo unreadable; return 0
  fi
  # Equal, or one is a short form of the other.
  if [ "${m#"$s"}" != "$m" ] || [ "${s#"$m"}" != "$s" ]; then echo match; return 0; fi
  # compare/<merged>...<served>: ahead or identical means the served commit
  # contains the merge (deploy-train's ancestry rule), so it is a match.
  case "$c" in
    identical|ahead) echo match ;;
    behind|diverged) echo mismatch ;;
    *) echo unreadable ;;
  esac
}

pmv_key() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  printf '%s:%s@%s\n' "$(pmv_norm "$1")" "$(pmv_norm "$2")" "$(pmv_norm "$3")"
}

# _pmv_ledger row <key> | put <key> <status> [detail] — the jobs client in a
# subshell, because bin/jobs-client.sh exits the shell that sources it when a
# module is missing. rc as job_ledger_row / job_ledger_put: 0, 2 no row, 1 outage.
_pmv_ledger() {
  local h="${HARNESS:-${H:-}}" verb="$1"; shift
  [ -n "$h" ] || return 1
  (
    [ -r "$h/bin/jobs-client.sh" ] || exit 1
    # shellcheck source=/dev/null
    . "$h/bin/jobs-client.sh" 2>/dev/null || exit 1
    case "$verb" in
      row) declare -F job_ledger_row >/dev/null 2>&1 || exit 1
           job_ledger_row post_merge_verify "$1" ;;
      put) declare -F job_ledger_put >/dev/null 2>&1 || exit 1
           job_ledger_put post_merge_verify "$1" "$2" "${3:-}" >/dev/null ;;
      *) exit 1 ;;
    esac
  )
}

# A key's progress: ticketed > paged > anything else. Returns the further one.
_pmv_rank() { case "$1" in ticketed) echo 2 ;; paged) echo 1 ;; *) echo 0 ;; esac; }

pmv_act() {
  local project="${1:-}" target="${2:-}" merged="${3:-}" served="${4:-}" verdict="${5:-}" log="${6:-}" note="${7:-}"
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -n "$project" ] && [ -n "$target" ] && [ -n "$merged" ] || return 1
  local key marker s7 m7 detail
  key=$(pmv_key "$project" "$target" "$merged") || return 1
  [ -n "$log" ] || log="$h/logs/post-merge-verify.log"
  marker="$h/state/post-merge-verify/$(printf '%s' "$key" | sha1sum | cut -c1-40)"
  served=$(pmv_norm "$served"); s7="${served:0:7}"; m7=$(pmv_norm "$merged"); m7="${m7:0:7}"
  detail=$(jq -nc --arg s "$served" '{served:$s}' 2>/dev/null)
  _pmv_log() { printf '%s [%s] post-merge-verify %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$project" "$*" >> "$log" 2>/dev/null; }

  case "$verdict" in
    match)
      _pmv_ledger put "$key" verified "$detail" || true
      _pmv_log "OK: $key serves ${s7}"
      return 0 ;;
    mismatch) ;;
    *)
      _pmv_ledger put "$key" unreadable "$detail" || true
      _pmv_log "UNREADABLE: $key served='${served:-}'${note:+ ($note)}; not paged"
      return 0 ;;
  esac

  # 1. How far has this key got? The ledger, and the marker for when it is down.
  local row rc state="" mstate=""
  row=$(_pmv_ledger row "$key"); rc=$?
  [ "$rc" = 0 ] && state=$(printf '%s' "$row" | jq -r '.status // empty' 2>/dev/null)
  mstate=$(awk 'NR==1{print $1}' "$marker" 2>/dev/null)
  [ "$(_pmv_rank "$mstate")" -gt "$(_pmv_rank "$state")" ] && state="$mstate"
  if [ "$state" = ticketed ]; then
    _pmv_log "MISMATCH: $key already ticketed; nothing new"
    return 0
  fi

  # 2. Page: send first, stamp second. A crash between costs a duplicate page, never a missed one.
  if [ "$state" != paged ]; then
    "$h/bin/alert-line.sh" --severity warn --project "$project" \
      "POST-MERGE VERIFY MISMATCH $key: prod serves $s7, merged $m7${note:+ ($note)}. A ticket follows on the harness repo." >/dev/null 2>&1 || true
    _pmv_ledger put "$key" paged "$detail" || true
    mkdir -p "$(dirname "$marker")" 2>/dev/null && printf 'paged\n' > "$marker" 2>/dev/null
    _pmv_log "MISMATCH: $key serves $s7, not $m7; paged"
  fi

  # 3. Ticket: find one, or file one. Only a parsed issue number is `ticketed`.
  local slug num body
  slug=$("$h/bin/fleet-conf.sh" cromford repo 2>/dev/null)
  if [ -z "$slug" ]; then
    _pmv_log "MISMATCH: $key ticket not filed: fleet.conf has no cromford repo; status stays paged"
    return 0
  fi
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" >/dev/null 2>&1 || true; }
  # REST search, not `gh issue list` (the BH-1585 GraphQL ratchet). A failed
  # search is no answer, so we still file: the ledger and marker above are the
  # dedup guard, and search indexing lags a fresh issue anyway.
  num=$(timeout 30 gh api -X GET search/issues -f q="repo:$slug in:title \"$key\"" -q '.items[0].number // empty' 2>/dev/null)
  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    num=""
    body=$(mktemp 2>/dev/null) || { _pmv_log "MISMATCH: $key ticket not filed: no temp file; status stays paged"; return 0; }
    cat > "$body" <<EOF
Post-merge verify (BH-3690) found prod not serving a merged commit.

- key: \`$key\`
- project: $project, target: $target
- merged: \`$(pmv_norm "$merged")\`
- served: \`$served\`
- log: \`$log\`

The alert already went out once through alert-line.sh. This ticket carries no ai-build label on purpose: a person or the precision lane decides the fix.
EOF
    if command -v gh_issue_create >/dev/null 2>&1 \
      && GH_ISSUE_CREATE_TIMEOUT_S=60 gh_issue_create "$slug" "post-merge verify: $key not served" "$body" infra > /dev/null 2>&1; then
      num="$GH_ISSUE_NUMBER"
    fi
    rm -f "$body"
  fi
  if [ -z "$num" ]; then
    _pmv_log "MISMATCH: $key ticket not filed on $slug (gh issue create gave no issue number); status stays paged, the next run retries"
    return 0
  fi
  _pmv_ledger put "$key" ticketed "$(jq -nc --arg s "$served" --arg i "$num" '{served:$s,issue:($i|tonumber)}' 2>/dev/null)" || true
  mkdir -p "$(dirname "$marker")" 2>/dev/null && printf 'ticketed %s\n' "$num" > "$marker" 2>/dev/null
  _pmv_log "MISMATCH: $key ticketed $slug#$num"
  return 0
}
