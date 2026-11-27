#!/bin/bash
# gh-identity: raw-by-design — sourced only into bin/pipeline-health.sh; its two raw calls (the open-PR list in ph_open_github, the combined status in ph_status_github) are that lane's reads, moved verbatim. They run on the identity the lane armed for the repo. A second mint here would override that choice.
# bin/lib/prr-shadow.d/pipeline-health.sh — the prr-shadow seam of lane pipeline-health (BH-9926 wave 6, BH-9938).
# Sourced by prr_seam_load pipeline-health (bin/lib/prr-shadow.sh), never executed.
#
# The knob GH_SOURCE (settings row lane.pipeline-health.gh_source) picks the
# step: off, shadow or record. bin/pipeline-health.sh calls
# prr_read pipeline-health <key> <file> ph_<x>_record ph_<x>_github ph_<x>_norm
# through ph_prr below. Each <x>_record makes jobs reads only (never a GitHub
# call), writes the format its <x>_github writes, and on a miss prints one miss
# word and returns 1. Each <x>_norm prints a JSON array keyed on .n.
#
#   ph_prr <key> <x> [args...]
#       prr_read pipeline-health <key> <tmp> ph_<x>_record ph_<x>_github
#       ph_<x>_norm [args...], then the value on stdout. rc is prr_read's.
#
# The open-PR list (ph_open_list, ph_open_rows). Key <slug>#open or
# <slug>#open:<max>.
#   ph_open_record <file> <slug> <window>
#       pr_record_list <slug> open <tmp> - <window> (no window when empty),
#       mapped to the REST pulls shape: number title html_url draft body
#       mergeable_state created_at updated_at user.login head.{ref,sha}
#       base.ref labels[].name, through pr_record_open_rest
#       (bin/lib/pr-record.sh). BH-9938 C1: the record has no default branch,
#       so a hit needs the repo's default-branch memo to say main, and the
#       rows then carry base.repo.default_branch main. Miss: pr_record_list's
#       word, field:default_branch, malformed; no lib is `unreadable`.
#   ph_open_github <file> <slug> <window> <list|rows>
#       list: the raw `pulls?state=open&per_page=100` page, or the snapshot
#       list (prs_open_list) when HPL_SNAPSHOT=1. rows: gh_rest_pr_list_all
#       <slug> open <window>, or the first <window> snapshot rows. rc is the
#       read's. A good read writes the default-branch memo.
#   ph_open_norm <file>
#       [{n, head: .head.sha, labels: sorted names}] sorted by n.
#
# 13c, the merge-queue label list. Key <slug>#labels:merge-queue.
#   ph_sdl_record <file> <slug>
#       pr_record_label_list <slug> merge-queue, mapped to the issue-list
#       shape [{number, pull_request: {}, labels: [{name}]}]. Miss: its word.
#   ph_sdl_github <file> <slug>
#       ph_sdl_list <slug> > <file>. ph_sdl_list is the lane's own read,
#       defined in the stale-dequeue block of bin/pipeline-health.sh. rc 75
#       when it is not defined.
#   ph_sdl_norm <file>
#       [{n}] of the PRs the block judges (a pull request, no queued or
#       checking label), sorted by n.
#
# 13c, the Mergify payload. Key <slug>#<n>:payload.
#   ph_payload_record <file> <slug> <n>
#       pr_record_mergify: one line `state<TAB>epoch<TAB>comment_id`, the
#       line sdq_payload_last prints. epoch is .at as epoch seconds. Miss:
#       the reader's PRR_MISS_WHY (unreadable, unknown, none), or malformed
#       when state, at or comment_id does not parse.
#   ph_payload_github <file> <slug> <n>
#       sdq_payload_last <slug> <n> > <file>. rc 1 no payload, rc 2 unread;
#       rc 2 when sdq_payload_last is not defined.
#   ph_payload_note <file> <github-rc> <why> <slug> <n>   (BH-10213)
#       Called by prr_read once after a record-step miss (prr_note_payload):
#       GitHub rc 0 writes the chosen comment (<file>.comment, kept by
#       ph_payload_github under PRR_NOTE) back into the record; rc 1 (no
#       payload comment) writes the "checked, empty" marker; any other rc
#       writes nothing. It always removes <file>.comment. A fresh marker
#       makes ph_payload_record print `hit-rc:1` (prr_read answers rc 1).
#   ph_payload_norm <file>
#       [{n: "payload", state, cid}]. The epoch is not compared: GitHub uses
#       the comment's updated_at, the record its created_at.
#
# 13c, the head commit time. Key <slug>#<n>@<sha12>:hct.
#   ph_hct_record <file> <slug> <n> <head>
#       pr_record_peek's head_commit.at as epoch seconds, only when
#       head_commit.sha is <head> (any case). Never a GitHub read. Miss:
#       unreadable (peek rc 1), field:head_commit (null), sha (another sha),
#       malformed (at does not parse).
#   ph_hct_github <file> <slug> <n> <head>
#       sdq_head_pushed_epoch <slug> <head> > <file>. rc 2 when it is not
#       defined.
#   ph_hct_norm <file>
#       [{n: "hct", v: <epoch>}].
#
# 13d, the combined status of a head. Key <slug>#<n>@<sha12>:status.
#   ph_status_record <file> <slug> <n> <head>
#       pr_record_statuses <slug> <n> <head>, mapped to the combined-status
#       shape {"statuses": [{context, state, updated_at: at}]}. Miss: the
#       reader's PRR_MISS_WHY (unreadable, unknown, no-head, none).
#   ph_status_github <file> <slug> <n> <head>
#       gh api repos/<slug>/commits/<head>/status > <file>.
#   ph_status_note <file> <github-rc> <why> <slug> <n> <head>   (BH-10213)
#       After a record-step miss (prr_note_statuses): GitHub rc 0 with a
#       .statuses array writes the list for <head> back into the record (an
#       empty list is the "checked, empty" marker, which ph_status_record
#       then serves as {"statuses": []} while it is fresh). Else nothing.
#   ph_status_norm <file>
#       [{n: <context>, v: <state>}] for lead-verdict and harness-verdict, the
#       first entry of each context.
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

ph_prr() {
  local key="${1:-}" x="${2:-}" f rc=0
  shift 2 2>/dev/null || return 2
  f=$(mktemp "${TMPDIR:-/tmp}/ph-prr.XXXXXX") || return 75
  prr_read pipeline-health "$key" "$f" "ph_${x}_record" "ph_${x}_github" "ph_${x}_norm" "$@" || rc=$?
  [ "$rc" = 0 ] && cat "$f"
  rm -f "$f" "$f.comment"
  return "$rc"
}

# ── open-PR list ─────────────────────────────────────────────────────────────
ph_open_record() {
  local f="${1:-}" slug="${2:-}" win="${3:-}"
  [ -n "$f" ] || return 2
  # BH-9938 C1: the shared mapping of bin/lib/pr-record.sh, which also holds
  # the default-branch rule (a hit only when the repo's memo says main).
  command -v pr_record_open_rest >/dev/null 2>&1 || { echo unreadable; return 1; }
  pr_record_open_rest "$slug" "$f" "$win"
}

ph_open_github() {
  local rc=0
  _ph_open_github_read "$@" || rc=$?
  # BH-9938 C1: the GitHub rows carry base.repo.default_branch; keep it for
  # the record side (pr_record_open_rest), which has no default branch.
  [ "$rc" = 0 ] && command -v pr_record_default_branch_note >/dev/null 2>&1 \
    && pr_record_default_branch_note "${2:-}" "${1:-}"
  return "$rc"
}

_ph_open_github_read() {
  local out="${1:-}" slug="${2:-}" win="${3:-}" shape="${4:-list}" f rc=0
  [ -n "$out" ] || return 2
  if [ "$shape" = rows ]; then
    if [ "${HPL_SNAPSHOT:-}" != 1 ]; then gh_rest_pr_list_all "$slug" open "$win" > "$out"; return; fi
    f=$(mktemp "${TMPDIR:-/tmp}/ph-open.XXXXXX") || return 75
    prs_open_list "$slug" "$f" || rc=$?
    [ "$rc" = 0 ] && { jq -c --argjson m "$win" '.[:$m]' "$f" > "$out" || rc=75; }
    rm -f "$f"
    return "$rc"
  fi
  if [ "${HPL_SNAPSHOT:-}" != 1 ]; then gh api "repos/$slug/pulls?state=open&per_page=100" > "$out"; return; fi
  f=$(mktemp "${TMPDIR:-/tmp}/ph-open.XXXXXX") || return 75
  prs_open_list "$slug" "$f" || rc=$?
  [ "$rc" = 0 ] && cat "$f" > "$out"
  rm -f "$f"
  return "$rc"
}

ph_open_norm() {
  jq -c '[.[] | {n: .number, head: .head.sha, labels: ([.labels[]?.name] | sort)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

# ── 13c merge-queue label list ───────────────────────────────────────────────
ph_sdl_record() {
  local f="${1:-}" slug="${2:-}" tmp why rc
  [ -n "$f" ] || return 2
  command -v pr_record_label_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/ph-sdl.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_label_list "$slug" merge-queue "$tmp"); rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.sync"
    echo "${why:-unreadable}"; return 1
  fi
  if ! jq -c '[.[] | {number, pull_request: {}, labels: [(.labels // [])[] | {name: .}]}]' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"
    echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

ph_sdl_github() {
  local f="${1:-}"
  [ -n "$f" ] || return 2
  command -v ph_sdl_list >/dev/null 2>&1 || return 75
  ph_sdl_list "${2:-}" > "$f"
}

ph_sdl_norm() {
  jq -c '[.[] | select(.pull_request != null)
    | select([.labels[]?.name] | any(. == "queued" or . == "checking") | not) | {n: .number}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

# ── 13c Mergify payload ──────────────────────────────────────────────────────
ph_payload_record() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" tmp rc line
  [ -n "$f" ] || return 2
  command -v pr_record_mergify >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/ph-pl.XXXXXX") || { echo unreadable; return 1; }
  # A plain command with `> file`: PRR_MISS_WHY must reach this shell.
  PRR_MISS_WHY=""
  pr_record_mergify "$slug" "$n" > "$tmp"; rc=$?
  # BH-10213: a fresh "checked, empty" marker is GitHub's "no payload" (rc 1).
  if [ "$rc" != 0 ] && [ "$PRR_MISS_WHY" = empty ]; then rm -f "$tmp"; : > "$f"; echo hit-rc:1; return 0; fi
  if [ "$rc" != 0 ]; then rm -f "$tmp"; echo "${PRR_MISS_WHY:-unreadable}"; return 1; fi
  # BH-9938 C1: the epoch is the comment's updated_at, the time
  # sdq_payload_last reads from GitHub. A row written before C1 has no such
  # key: a miss, never the created time.
  if ! jq -e '.updated_at | strings' "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; echo field:updated_at; return 1; fi
  line=$(jq -r 'select((.state | type) == "string" and .state != "" and (.comment_id | type) == "number"
      and ((.at | strings | sub("\\.[0-9]+"; "") | fromdateiso8601?) != null))
    | [.state, (.updated_at | strings | sub("\\.[0-9]+"; "") | fromdateiso8601 | tostring), (.comment_id | tostring)] | @tsv' "$tmp" 2>/dev/null)
  rm -f "$tmp"
  [[ "$line" =~ ^[^[:space:]]+$'\t'[0-9]+$'\t'[0-9]+$ ]] || { echo malformed; return 1; }
  printf '%s\n' "$line" > "$f"
}

ph_payload_github() {
  local f="${1:-}"
  [ -n "$f" ] || return 2
  command -v sdq_payload_last >/dev/null 2>&1 || return 2
  # BH-10213: under PRR_NOTE (a record-step miss) keep the chosen comment for ph_payload_note.
  SDQ_PAYLOAD_COMMENT_OUT="${PRR_NOTE:+$f.comment}" sdq_payload_last "${2:-}" "${3:-}" > "$f"
}

ph_payload_note() {
  local c="${1:-}.comment"
  [ -n "${1:-}" ] || return 0
  prr_note_payload "$c" "${2:-}" "${4:-}" "${5:-}"
  rm -f "$c"
  return 0
}

ph_payload_norm() {
  local s e c
  IFS=$'\t' read -r s e c < "${1:-}" 2>/dev/null || return 0
  [ -n "$s" ] || return 0
  jq -nc --arg s "$s" --arg c "$c" '[{n: "payload", state: $s, cid: $c}]'
}

# ── 13c head commit time ─────────────────────────────────────────────────────
ph_hct_record() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" head row hc e
  [ -n "$f" ] || return 2
  head=$(printf '%s' "${4:-}" | tr 'A-F' 'a-f')
  command -v pr_record_peek >/dev/null 2>&1 || { echo unreadable; return 1; }
  row=$(pr_record_peek "$slug" "$n") || { echo unreadable; return 1; }
  # BH-9938 C1: the row's age is checked like every other record read.
  command -v _prr_row_fresh >/dev/null 2>&1 && ! _prr_row_fresh "$row" && { echo stale; return 1; }
  hc=$(jq -c '.head_commit | objects' <<<"$row" 2>/dev/null)
  [ -n "$hc" ] || { echo field:head_commit; return 1; }
  [ -n "$head" ] && [ "$(jq -r '.sha // "" | ascii_downcase' <<<"$hc" 2>/dev/null)" = "$head" ] || { echo sha; return 1; }
  e=$(jq -r '.at | strings | sub("\\.[0-9]+"; "") | fromdateiso8601' <<<"$hc" 2>/dev/null)
  [[ "$e" =~ ^[0-9]+$ ]] || { echo malformed; return 1; }
  printf '%s' "$e" > "$f"
}

ph_hct_github() {
  local f="${1:-}"
  [ -n "$f" ] || return 2
  command -v sdq_head_pushed_epoch >/dev/null 2>&1 || return 2
  sdq_head_pushed_epoch "${2:-}" "${4:-}" > "$f"
}

ph_hct_norm() {
  local e
  e=$(head -c 32 "${1:-}" 2>/dev/null)
  [[ "$e" =~ ^[0-9]+$ ]] || return 0
  printf '[{"n":"hct","v":%s}]\n' "$e"
}

# ── 13d combined status ──────────────────────────────────────────────────────
ph_status_record() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" head="${4:-}" tmp rc ctx
  [ -n "$f" ] || return 2
  command -v pr_record_statuses >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/ph-st.XXXXXX") || { echo unreadable; return 1; }
  # A plain command with `> file`: PRR_MISS_WHY must reach this shell.
  PRR_MISS_WHY=""
  pr_record_statuses "$slug" "$n" "$head" row-head > "$tmp"; rc=$?
  # BH-10213: a fresh "checked, empty" marker is GitHub's empty status list.
  if [ "$rc" != 0 ] && [ "$PRR_MISS_WHY" = empty ]; then rm -f "$tmp"; printf '{"statuses":[]}\n' > "$f"; return 0; fi
  if [ "$rc" != 0 ]; then rm -f "$tmp"; echo "${PRR_MISS_WHY:-unreadable}"; return 1; fi
  # BH-9938 C1: a hit needs the verdict context itself for this head. Other
  # contexts alone are a miss, never "no verdict" (the GitHub read decides).
  ctx=$(vs_context 2>/dev/null) || ctx=""; ctx="${ctx:-lead-verdict}"
  if ! jq -e --arg c "$ctx" 'has($c)' "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; echo "field:$ctx"; return 1; fi
  if ! jq -c '{statuses: [to_entries[] | {context: .key, state: .value.state, updated_at: .value.at}]}' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp"; : > "$f"
    echo malformed; return 1
  fi
  rm -f "$tmp"
}

ph_status_github() {
  local f="${1:-}"
  [ -n "$f" ] || return 2
  gh api "repos/${2:-}/commits/${4:-}/status" > "$f" 2>/dev/null
}

ph_status_note() {
  prr_note_statuses "${1:-}" "${2:-}" "${4:-}" "${5:-}" "${6:-}"
  return 0
}

ph_status_norm() {
  jq -c '[.statuses[]? | select(.context == "lead-verdict" or .context == "harness-verdict") | {n: .context, v: .state}]
    | unique_by(.n)' "${1:-}" 2>/dev/null
}
