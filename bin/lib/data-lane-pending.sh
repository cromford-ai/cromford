# bin/lib/data-lane-pending.sh — a review that blocks only on a data-lane
# gh-identity: raw-by-design — sourced only; its one raw call (gh pr ready, which has no REST form) runs inside a lane that has ALREADY armed this repo's identity: LENS_REFUSE in the build lane, and bin/review-rescue.sh per project. A second mint here would override that choice.
# migration keeps its branch as a draft PR until the migration is in prod.
# Sourced, never executed; the root is ${HARNESS:-${H:-}} and nothing else (D43).
# Every function returns and never exits. No token goes on an argv.
#
# The flow: LENS_REFUSE (bin/lib/rb/review.sh) opens the draft and labels it
# data-lane-pending (dlp_block_draft). The open PR owns the ticket, so
# bin/orphan-reconcile.sh launches nothing. A person applies the file and posts
# HUMAN-STEP-DONE naming it; bin/review-rescue.sh shape D probes the app's
# migration ledger (dlp_probe), re-reviews the same head, and marks the PR
# ready and removes the label (dlp_finish).
#
# dlp_only <review.md> [<diff-files>]   rc 0 prints the path, rc 1 nothing,
#                                       rc 2 unreadable
# dlp_pending <record-dir> [project]    rc 0 the record waits on this flow
# dlp_block_draft <project> <slug> <branch> <base> <key> <issue> <build-dir> <diff-files>
#                                       rc 0 prints the PR url, rc 1 no draft
#                                       (why on stderr), rc 3 the create failed
# dlp_at_block <project> <slug> <branch> <base> <key> <issue> <build-dir> <alerts-file>
#                                       LENS_REFUSE's call: the diff list, the
#                                       draft, one pipeline.log line; a failed
#                                       create is one ALERTS line too. rc 0.
# dlp_names_file <done-evidence> <path> rc 0 the text names the file
# dlp_probe <project> <repo-dir> <head> <path>
#                                       prints a word and detail lines: rc 0
#                                       confirmed, 1 missing, 3 not-configured,
#                                       75 unknown
# dlp_marker_head <record-dir>          the marker's head=, else the reviewed
#                                       sha; rc 1 none
# dlp_wait_line <record-dir> <key> <hours>
#                                       rc 0 prints the one wait-alert text when
#                                       the draft waits past <hours> (0 = off)
# dlp_probe_alert_line <record-dir> <project> <key> <probe-rc> <detail> <done-at> <hours>
#                                       rc 0 prints the one probe-alert text: a
#                                       refused token at once; any other unknown
#                                       or a missing row once HUMAN-STEP-DONE is
#                                       older than <hours> (0 = off). rc 1 none
# dlp_missing_comment <slug> <issue> <thread-json> <done-url> <detail>
#                                       rc 0 posted or already there, 1 failed
# dlp_finish <slug> <pr-url>            rc 0 ready and unlabelled, 1 a step failed
# shellcheck shell=bash

[ -n "${_DLP_LIB_LOADED:-}" ] && return 0
_DLP_LIB_LOADED=1

DLP_LABEL=data-lane-pending

_dlp_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/data-lane.sh
[ -r "$_dlp_dir/data-lane.sh" ] && . "$_dlp_dir/data-lane.sh" 2>/dev/null || true
# shellcheck source=bin/lib/needs-human.sh
[ -r "$_dlp_dir/needs-human.sh" ] && . "$_dlp_dir/needs-human.sh" 2>/dev/null || true
if ! command -v gh_rest >/dev/null 2>&1 && [ -r "$_dlp_dir/gh-rest.sh" ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  . "$_dlp_dir/gh-rest.sh" 2>/dev/null || true
fi

dlp_only() {
  local f="${1:-}" diff="${2:-}" lines path paths n val low
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 2
  command -v nh_sd_human_only >/dev/null 2>&1 && command -v _nh_lines >/dev/null 2>&1 \
    && [ -n "${DL_BLOCK_RE:-}" ] && [ -n "${DL_PATH_RE:-}" ] || return 2
  nh_sd_human_only "$f" >/dev/null 2>&1 || return 1
  lines=$(_nh_sd_round "$f" | tr -d '\r' | _nh_lines)
  paths=$(printf '%s\n' "$lines" | sed -nE 's/^DATA_LANE:[[:space:]]*([^[:space:]]+).*$/\1/p')
  [ -n "$paths" ] && [ "$(printf '%s\n' "$paths" | wc -l)" -eq 1 ] || return 1
  path="$paths"
  [[ "$path" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*\.(sql|ts)$ ]] || return 1
  case "$path" in *..*) return 1 ;; esac
  # BH-4926's own paths keep their apply lane.
  grep -qE "$DL_PATH_RE" <<<"DATA_LANE: $path" && return 1
  n=$(printf '%s\n' "$lines" | grep -cE "$DL_BLOCK_RE" || true)
  [ "$n" = 1 ] || return 1
  # A second human step is not "only the data lane".
  while IFS= read -r val; do
    val=$(_nh_clean "$(printf '%s' "$val" | sed -E 's/^NEEDS_HUMAN:[[:space:]]*//')")
    low=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
    case "${low%.}" in ''|none|n/a|na|no|nothing|-|'<'*'>') continue ;; esac
    return 1
  done < <(printf '%s\n' "$lines" | grep -E '^NEEDS_HUMAN:' || true)
  if [ -n "$diff" ]; then
    [ -r "$diff" ] && grep -qxF -- "$path" "$diff" || return 1
  fi
  printf '%s\n' "$path"
}

dlp_pending() {
  local r="${1:-}"
  [ -n "$r" ] && [ -d "$r" ] || return 1
  command -v nh_sd_pending >/dev/null 2>&1 || return 1
  nh_sd_pending "$r" "${2:-}" || return 1
  dlp_only "$r/review.md" >/dev/null 2>&1
}

# _dlp_say <build-dir> <text> — one pipeline.log line.
_dlp_say() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" >> "$1/pipeline.log" 2>/dev/null || true; }

dlp_block_draft() {
  local p="${1:-}" slug="${2:-}" br="${3:-}" base="${4:-}" key="${5:-}" n="${6:-}" b="${7:-}" diff="${8:-}"
  local path remote head list url num title bf owner tjob rf lrc
  [ -n "$p" ] && [ -n "$slug" ] && [ -n "$br" ] && [ -n "$base" ] && [ -n "$key" ] && [ -d "$b" ] \
    || { echo "dlp_block_draft: missing argument" >&2; return 1; }
  path=$(dlp_only "$b/review.md" "$diff") || { echo "dlp_block_draft: not a data-lane-only BLOCK" >&2; return 1; }
  case "$n" in ''|*[!0-9]*) echo "dlp_block_draft: no GitHub issue number (not an issues board)" >&2; return 1 ;; esac
  command -v nh_sd_rescue_on >/dev/null 2>&1 && nh_sd_rescue_on "$p" \
    || { echo "dlp_block_draft: shape D is off for $p (RESCUE_HUMAN_STEP)" >&2; return 1; }
  command -v gh_rest >/dev/null 2>&1 || { echo "dlp_block_draft: bin/lib/gh-rest.sh is not loaded" >&2; return 1; }
  head=$(git rev-parse HEAD 2>/dev/null)
  remote=$(git ls-remote origin "refs/heads/$br" 2>/dev/null | cut -f1)
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [ "$remote" = "$head" ] \
    || { echo "dlp_block_draft: the reviewed head ${head:0:12} is not $br on origin (${remote:0:12})" >&2; return 1; }
  owner="${slug%%/*}"
  # Adopt first: an open PR on the branch is the owner already, as it is.
  # gh_rest helpers write to a file, never inside $( ): GH_REST_STATUS must
  # survive for the message (tests/gh-rest-no-subshell-lint.sh).
  rf=$(mktemp "${TMPDIR:-/tmp}/dlp-rest.XXXXXX") || return 3
  lrc=0; gh_rest_pr_list "$slug" open "$owner:$br" > "$rf" 2>/dev/null || lrc=$?
  list=$(cat "$rf" 2>/dev/null)
  [ "$lrc" = 0 ] \
    || { rm -f "$rf"; echo "dlp_block_draft: the open-PR read failed (status ${GH_REST_STATUS:-?})" >&2; return 3; }
  url=$(printf '%s' "$list" | jq -r 'if type == "array" then (.[0].html_url // empty) else empty end' 2>/dev/null)
  if [ -z "$url" ]; then
    title=$(jq -r '.title // empty' "$b/ticket-meta.json" 2>/dev/null)
    [ -n "$title" ] || title=$(grep -m1 '^#' "$b/plan.md" 2>/dev/null | sed 's/^#\{1,\}[[:space:]]*//')
    title=$(printf '%s' "${title:-the change}" | tr -d '\r\n' | cut -c1-80)
    case "$title" in "$key"*) ;; *) title="$key: $title" ;; esac
    bf=$(mktemp "${TMPDIR:-/tmp}/dlp-body.XXXXXX") || return 3
    printf '%s\n' \
      "The review of $key blocked only on one data-lane migration: \`$path\`." \
      "Every other finding passed. This draft waits for that migration in production." \
      "" \
      "Next step: apply $path to production, then post \`HUMAN-STEP-DONE: $path\` on #$n." \
      "" \
      "After that comment, bin/review-rescue.sh reads the app's migration ledger. If the row is there, it re-reviews this head, marks this PR ready and removes the \`$DLP_LABEL\` label. No new build runs." \
      "" \
      "🤖 Generated with [Claude Code](https://claude.com/claude-code)" > "$bf"
    # >>> pr trailers
    if [ -r "$_dlp_dir/pr-trailers.sh" ] && { command -v pr_trailers_apply >/dev/null 2>&1 || . "$_dlp_dir/pr-trailers.sh" 2>/dev/null; }; then
      tjob=$(pr_trailers_job_for "$b" 2>/dev/null)
      pr_trailers_apply "$bf" "$tjob" "$key" 2>/dev/null || true
    fi
    : > "$rf"; gh_rest POST "repos/$slug/pulls" -f "title=$title" -f "head=$br" -f "base=$base" -F draft=true -F "body=@$bf" > "$rf" 2>/dev/null
    # <<< pr trailers
    url=$(jq -r '.html_url // empty' "$rf" 2>/dev/null)
    rm -f "$bf"
    [ -n "$url" ] || { rm -f "$rf"; echo "dlp_block_draft: the draft create failed (status ${GH_REST_STATUS:-?})" >&2; return 3; }
  fi
  rm -f "$rf"
  num="${url##*/}"
  case "$num" in ''|*[!0-9]*) echo "dlp_block_draft: no PR number in '$url'" >&2; return 3 ;; esac
  # A failed label still leaves the PR as the ticket's owner.
  gh_rest POST "repos/$slug/issues/$num/labels" -f "labels[]=$DLP_LABEL" >/dev/null 2>&1 \
    || _dlp_say "$b" "[$p/$key] data-lane: the $DLP_LABEL label was not added to $url (status ${GH_REST_STATUS:-?}); pr-owner-sweep may see the draft as an orphan"
  # The marker is written last, and only with a url (D9).
  printf 'url=%s\nfile=%s\nhead=%s\n' "$url" "$path" "$head" > "$b/data-lane-pending.tmp" \
    && mv -f "$b/data-lane-pending.tmp" "$b/data-lane-pending"
  printf '%s\n' "$url"
}

dlp_at_block() {
  local p="${1:-}" slug="${2:-}" br="${3:-}" base="${4:-}" key="${5:-}" n="${6:-}" b="${7:-}" alerts="${8:-}"
  local d ref url rc=0 now
  [ -d "$b" ] || return 0
  d="$b/data-lane-diff.txt"; ref="origin/$base"
  git rev-parse -q --verify "$ref" >/dev/null 2>&1 || ref="$base"
  git diff --name-only "$ref...HEAD" > "$d" 2>/dev/null || return 0
  url=$(dlp_block_draft "$p" "$slug" "$br" "$base" "$key" "$n" "$b" "$d" 2>>"$b/pipeline.log") || rc=$?
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  case "$rc" in
    0) printf '%s [%s/%s] data-lane draft opened %s — the PR owns %s until the migration is applied\n' "$now" "$p" "$key" "$url" "$key" >> "$b/pipeline.log" ;;
    3) [ -n "$alerts" ] && printf '%s [%s/%s] data-lane draft not opened for %s; reconcile may relaunch it (see %s/pipeline.log)\n' "$now" "$p" "$key" "$key" "$b" >> "$alerts" ;;
  esac
  return 0
}

dlp_names_file() {
  local ev="${1:-}" path="${2:-}" base pat
  [ -n "$ev" ] && [ -n "$path" ] || return 1
  base="${path##*/}"
  for pat in "$path" "$base"; do
    pat=$(printf '%s' "$pat" | sed -E 's/[][\.*^$(){}+?|]/\\&/g')
    grep -qE "(^|[^A-Za-z0-9_./-])$pat\.?([^A-Za-z0-9_./-]|$)" <<<"$ev" && return 0
  done
  return 1
}

dlp_probe() {
  local p="${1:-}" repo="${2:-}" head="${3:-}" path="${4:-}" root envd envf base tok sum t code body bn row
  root="${HARNESS:-${H:-}}"
  [ -n "$p" ] && [ -n "$repo" ] && [ -n "$head" ] && [ -n "$path" ] || { echo unknown; echo "probe: missing argument"; return 75; }
  envd="${HENV:-}"
  if [ -z "$envd" ] && [ -n "$root" ]; then
    if command -v harness_env_dir >/dev/null 2>&1; then envd=$(harness_env_dir "$root"); else envd="$root/env"; fi
  fi
  envf="${envd:+$envd/$p.env}"
  base=$(sed -n 's/^DATA_LANE_APP_BASE=//p' "$envf" 2>/dev/null | sed -n '$p' | tr -d "\"' ")
  tok=$(sed -n 's/^MIGRATION_TOKEN=//p' "$envf" 2>/dev/null | sed -n '$p' | tr -d "\"' ")
  if [ -z "$base" ] || [ -z "$tok" ]; then
    echo not-configured; echo "probe: DATA_LANE_APP_BASE or MIGRATION_TOKEN is not set in env/$p.env"; return 3
  fi
  if ! git -C "$repo" cat-file -e "$head:$path" 2>/dev/null; then
    git -C "$repo" fetch -q origin 2>/dev/null || true
  fi
  sum=$(git -C "$repo" show "$head:$path" 2>/dev/null | sha256sum | cut -c1-64)
  git -C "$repo" cat-file -e "$head:$path" 2>/dev/null && [[ "$sum" =~ ^[0-9a-f]{64}$ ]] \
    || { echo unknown; echo "probe: $path is not readable at ${head:0:12}"; return 75; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/dlp-probe.XXXXXX") || { echo unknown; echo "probe: no temp dir"; return 75; }
  ( umask 077; printf 'Authorization: Bearer %s\n' "$tok" > "$t/auth" )
  code=$(curl -sS -m 30 -H @"$t/auth" -o "$t/body" -w '%{http_code}' "${base%/}/api/internal/migrations/status" 2>/dev/null) || code=000
  body=$(cat "$t/body" 2>/dev/null)
  rm -rf "$t"
  case "$code" in
    2??) ;;
    401|403) echo unknown; echo "probe: the migration token was refused (HTTP $code)"; return 75 ;;
    *) echo unknown; echo "probe: migrations/status answered HTTP $code"; return 75 ;;
  esac
  printf '%s' "$body" | jq -e 'type == "object" and (.applied | type == "array")' >/dev/null 2>&1 \
    || { echo unknown; echo "probe: migrations/status did not answer a JSON applied list"; return 75; }
  bn="${path##*/}"
  row=$(printf '%s' "$body" | jq -r --arg f "$bn" --arg c "$sum" \
    'first(.applied[] | select(type == "object" and .filename == $f and .checksum == $c)) | "\(.appliedAt // .applied_at // "?") by \(.actor // .appliedBy // .applied_by // "?")"' 2>/dev/null)
  if [ -n "$row" ]; then
    echo confirmed; echo "ledger: $bn applied at $row"; return 0
  fi
  row=$(printf '%s' "$body" | jq -r --arg f "$bn" 'first(.applied[] | select(type == "object" and .filename == $f)) | (.checksum // "") | tostring' 2>/dev/null)
  if printf '%s' "$body" | jq -e --arg f "$bn" 'any(.applied[]; type == "object" and .filename == $f)' >/dev/null 2>&1; then
    echo missing; echo "ledger: $bn is applied at checksum ${row:0:12}, the PR's file is ${sum:0:12}"; return 1
  fi
  echo missing; echo "ledger: no schema_migration row for $bn at sha256 ${sum:0:12}"; return 1
}

dlp_marker_head() {
  local h
  h=$(sed -n 's/^head=//p' "${1:-}/data-lane-pending" 2>/dev/null | sed -n 1p)
  if ! [[ "$h" =~ ^[0-9a-f]{40}$ ]]; then
    command -v dl_reviewed_sha >/dev/null 2>&1 && h=$(dl_reviewed_sha "${1:-}") || return 1
  fi
  printf '%s\n' "$h"
}

# The marker's age is the draft's age: it is written once, when the PR opened.
dlp_wait_line() {
  local r="${1:-}" k="${2:-}" h="${3:-}" url path
  case "$h" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -f "$r/data-lane-pending" ] && [ ! -e "$r/.dlp-wait-alerted" ] || return 1
  [ -n "$(find "$r/data-lane-pending" -maxdepth 0 -mmin +$((h * 60)) 2>/dev/null)" ] || return 1
  url=$(sed -n 's/^url=//p' "$r/data-lane-pending" | sed -n 1p)
  path=$(sed -n 's/^file=//p' "$r/data-lane-pending" | sed -n 1p)
  printf '%s draft %s waits %sh on the apply of %s: apply it to production, then post HUMAN-STEP-DONE: %s on the ticket\n' \
    "$k" "$url" "$h" "$path" "$path"
}

# After HUMAN-STEP-DONE the resolver holds the record and the draft keeps
# reconcile away, so a probe that never confirms must page once (BH-6467 B1).
# The caller writes .dlp-probe-alerted before it writes the alert.
dlp_probe_alert_line() {
  local r="${1:-}" p="${2:-}" k="${3:-}" rc="${4:-}" d="${5:-}" at="${6:-}" h="${7:-}" url path ts fix
  [ -f "$r/data-lane-pending" ] && [ ! -e "$r/.dlp-probe-alerted" ] || return 1
  url=$(sed -n 's/^url=//p' "$r/data-lane-pending" | sed -n 1p)
  path=$(sed -n 's/^file=//p' "$r/data-lane-pending" | sed -n 1p)
  case "$rc:$d" in
    75:*"token was refused"*)
      fix="set a MIGRATION_TOKEN the app accepts in env/$p.env" ;;
    75:*|1:*)
      case "$h" in ''|*[!0-9]*|0) return 1 ;; esac
      [ -n "$at" ] || return 1
      ts=$(date -u -d "$at" +%s 2>/dev/null) || return 1
      [ $(( $(date -u +%s) - ts )) -ge $((h * 3600)) ] || return 1
      if [ "$rc" = 1 ]; then
        fix="apply $path at the draft's head to production, then post HUMAN-STEP-DONE: $path"
      else
        fix="check DATA_LANE_APP_BASE in env/$p.env and the app's /api/internal/migrations/status route"
      fi ;;
    *) return 1 ;;
  esac
  printf '%s draft %s: HUMAN-STEP-DONE at %s, but the prod probe for %s answers: %s. Nothing re-reviews it until the ledger confirms: %s\n' \
    "$k" "$url" "$at" "$path" "$d" "$fix"
}

dlp_missing_comment() {
  local slug="${1:-}" n="${2:-}" thread="${3:-}" done_url="${4:-}" detail="${5:-}" fp bf rc=0
  [ -n "$slug" ] && [ -n "$n" ] && [ -n "$detail" ] || return 1
  fp=$(printf '%s %s' "$done_url" "$detail" | sha1sum | cut -c1-40)
  if printf '%s' "$thread" | jq -e --arg t "<!-- dlp-missing:$fp -->" \
       'type == "array" and any(.[]; type == "object" and ((.body // "") | tostring | contains($t)))' >/dev/null 2>&1; then
    return 0
  fi
  command -v gh_rest_comment >/dev/null 2>&1 || return 1
  bf=$(mktemp "${TMPDIR:-/tmp}/dlp-missing.XXXXXX") || return 1
  printf '%s\n' \
    "Thanks for the HUMAN-STEP-DONE. I checked the production migration ledger and did not find the migration yet." \
    "" \
    "- What the probe read: $detail" \
    "" \
    "Next step: apply the file at the PR's head to production, then post a new \`HUMAN-STEP-DONE:\` comment that names it. The re-review runs after the ledger shows the row." \
    "" \
    "<!-- dlp-missing:$fp -->" > "$bf"
  gh_rest_comment "$slug" "$n" "$bf" || rc=1
  rm -f "$bf"
  return "$rc"
}

dlp_finish() {
  local slug="${1:-}" url="${2:-}" num draft rf rc=0
  num="${url##*/}"
  [ -n "$slug" ] && case "$num" in ''|*[!0-9]*) false ;; *) true ;; esac || return 1
  command -v gh_rest >/dev/null 2>&1 || return 1
  # An unreadable draft flag tries the ready call; a ready PR is never touched.
  draft=""; rf=$(mktemp "${TMPDIR:-/tmp}/dlp-rest.XXXXXX") 2>/dev/null \
    && { gh_rest GET "repos/$slug/pulls/$num" > "$rf" 2>/dev/null
         draft=$(jq -r '.draft | tostring' "$rf" 2>/dev/null); rm -f "$rf"; }
  if [ "$draft" != false ]; then
    gh pr ready "$url" >/dev/null 2>&1 || rc=1
  fi
  local lrc=0
  gh_rest DELETE "repos/$slug/issues/$num/labels/$DLP_LABEL" >/dev/null 2>&1 || lrc=$?
  case "$lrc" in 0|44) ;; *) rc=1 ;; esac
  return "$rc"
}
