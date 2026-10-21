#!/bin/bash
# bin/lib/rr-cursor.sh — the remote-results CONSUMER CURSOR as ledger rows
# (BH-7803, C3 of #4157). Sourced, never run; defines functions only.
#
# state/remote-results/<p>/ carries the cursor that stops one remote build from
# being staged twice: .handled/<job>.job per staged ledger row,
# .handled/<KEY>.json[.empty|.badjson] per consumed relay json, and .since, the
# ledger-feed watermark. Those files live on ONE box, so a rebuilt or restored
# box has none of them and its first tick re-stages every close-out the feed
# window still holds: one comment per ticket on a client's board, again.
#
# Each file now has a `ledgers` row beside it:
#   rr-handled   key <p>/<job_id>            status staged   detail {key,dest,box}
#   rr-since     key <p>                     status at       detail the watermark
#   rr-consumed  key <p>/<KEY>@<build-id>    status staged|duplicate|empty|badjson
#                                            detail the relay json (cut to 3500 bytes)
#
# THE FILE IS READ FIRST AND STILL WRITTEN (#4141: "DB-first with a last-good
# cache for outages"). A reader answers from the file when it is there, so a box
# that has its files makes no extra read. Only a missing file asks the row, and
# a row that answers heals the file. A writer does the file op first (its rc is
# the function's rc), then the PUT. A failed PUT is one $LOG line and nothing
# else: it is not a staging failure and never freezes the watermark.
#
# "Not configured" (no job_ledger_row / job_ledger_put in scope) is the
# file-only behaviour exactly. An unreadable row with no file reads "not
# handled", which is the answer a missing file gave before this lib.
#
# Ids are checked: a project or job id outside [A-Za-z0-9._-], or `.` / `..`,
# is rc 1 and writes nothing, so no id can reach outside .handled/.

# The root is $HARNESS (or $H) and nothing else: with neither set, every
# function answers as if the id were bad (rc 1, nothing written, "" read).
_rrc_id_ok() {
  [ -n "${HARNESS:-${H:-}}" ] || return 1
  case "${1:-}" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0
}
_rrc_dir() { printf '%s/state/remote-results/%s' "${HARNESS:-${H:-}}" "$1"; }
_rrc_log() { # _rrc_log <project> <line>
  [ -n "${LOG:-}" ] || return 0
  echo "${STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} [$1] rr-cursor: $2" >> "$LOG" 2>/dev/null
  return 0
}
_rrc_put() { # _rrc_put <project> <what> <kind> <key> <status> [detail]
  local p="$1" what="$2"; shift 2
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  job_ledger_put "$@" >/dev/null 2>&1 && return 0
  _rrc_log "$p" "$1 row NOT written for $what (the file marker stands)"
  return 0
}

# rrc_job_handled <project> <job_id> — rc 0 handled, rc 1 not handled.
rrc_job_handled() {
  local p="${1:-}" job="${2:-}" d row
  _rrc_id_ok "$p" && _rrc_id_ok "$job" || return 1
  d=$(_rrc_dir "$p")
  [ -f "$d/.handled/$job.job" ] && return 0
  command -v job_ledger_row >/dev/null 2>&1 || return 1
  row=$(job_ledger_row rr-handled "$p/$job" 2>/dev/null) || return 1
  [ "$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)" = staged ] || return 1
  mkdir -p "$d/.handled" 2>/dev/null && : > "$d/.handled/$job.job" 2>/dev/null
  return 0
}

# rrc_job_mark <project> <job_id> <key> <dest-name> — the marker, then the row.
rrc_job_mark() {
  local p="${1:-}" job="${2:-}" key="${3:-}" dest="${4:-}" d rc detail
  _rrc_id_ok "$p" && _rrc_id_ok "$job" || return 1
  d=$(_rrc_dir "$p")
  mkdir -p "$d/.handled" 2>/dev/null
  : > "$d/.handled/$job.job"; rc=$?
  detail=$(jq -nc --arg k "$key" --arg d "$dest" --arg b "${JOBS_BOX:-}" '{key:$k,dest:$d,box:$b}' 2>/dev/null)
  _rrc_put "$p" "$job" rr-handled "$p/$job" staged "$detail"
  return "$rc"
}

# rrc_since_get <project> — prints the watermark: the file, else the row, else "".
rrc_since_get() {
  local p="${1:-}" d v row
  _rrc_id_ok "$p" || return 0
  d=$(_rrc_dir "$p")
  v=$(tr -dc '0-9A-Za-z:.-' 2>/dev/null < "$d/.since")
  if [ -z "$v" ] && command -v job_ledger_row >/dev/null 2>&1 \
     && row=$(job_ledger_row rr-since "$p" 2>/dev/null); then
    v=$(printf '%s' "$row" | jq -r '.detail // "" | tostring' 2>/dev/null | tr -dc '0-9A-Za-z:.-')
    [ -n "$v" ] && mkdir -p "$d" 2>/dev/null && printf '%s' "$v" > "$d/.since" 2>/dev/null
  fi
  printf '%s' "$v"
  return 0
}

# rrc_since_put <project> <ts> — the .since file, then the rr-since row.
rrc_since_put() {
  local p="${1:-}" ts="${2:-}" d rc
  _rrc_id_ok "$p" || return 1
  [ -n "$ts" ] && [ "$(printf '%s' "$ts" | tr -dc '0-9A-Za-z:.-')" = "$ts" ] || return 1
  d=$(_rrc_dir "$p")
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$ts" > "$d/.since"; rc=$?
  _rrc_put "$p" "the watermark" rr-since "$p" at "$ts"
  return "$rc"
}

# rrc_json_consume <project> <json-path> <staged|duplicate|empty|badjson> [build-id]
#   The rr-consumed row, then exactly the move staging always made.
rrc_json_consume() {
  local p="${1:-}" f="${2:-}" outcome="${3:-}" bid="${4:-}" base key detail target
  _rrc_id_ok "$p" && [ -f "$f" ] || return 1
  base=$(basename "$f")
  case "$outcome" in
    staged|duplicate) target="$base" ;;
    empty)            target="$base.empty" ;;
    badjson)          target="$base.badjson" ;;
    *) return 1 ;;
  esac
  if [ "$outcome" = badjson ]; then
    key="${base%.json}"
    detail=$(head -c 3500 "$f" 2>/dev/null | tr -d '\000')
  else
    key=$(jq -r '.key // ""' "$f" 2>/dev/null)
    [ -n "$bid" ] || bid=$(jq -r '.build_dir // "" | split("/") | last // ""' "$f" 2>/dev/null)
    [ -n "$bid" ] || bid=$(jq -r '.machine_build_dir // ""' "$f" 2>/dev/null)
    detail=$(jq -c . "$f" 2>/dev/null | head -c 3500)
  fi
  [ -n "$key" ] || key="${base%.json}"
  [ -n "$bid" ] || bid=$(sha256sum < "$f" 2>/dev/null | cut -c1-16)
  _rrc_put "$p" "$base" rr-consumed "$p/$key@$bid" "$outcome" "$detail"
  mkdir -p "$(dirname "$f")/.handled" 2>/dev/null
  mv -f "$f" "$(dirname "$f")/.handled/$target"
}
