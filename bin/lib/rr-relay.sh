#!/bin/bash
# bin/lib/rr-relay.sh — the remote-results RELAY JSON as a ledger row (BH-7860,
# C3 of #4157). Sourced, never run; defines functions only.
#
# A remote build's result reaches its owning box as a relay json,
# state/remote-results/<p>/<KEY>.json. The json now has a `ledgers` row:
#   rr-relay  key <p>/<KEY>@<build-id>  status parked|staged|duplicate|empty|badjson
#                                       detail the relay payload
# The writer parks it (rrr_park, status parked). The consumer
# (rrc_json_consume in bin/lib/rr-cursor.sh) sets the status to its outcome and
# sends no detail, so the parked payload stays. The key is the key the
# rr-consumed row of the same json carries (rrr_rowkey is that chain).
#
# THE FILE IS STILL WRITTEN AND STILL THE INPUT (#4141, the last-good cache).
# The writer PUTs the row BEFORE it writes or sends the file. A box that
# consumes the file before the parked PUT lands can leave the row at `parked`;
# its rr-consumed row still says consumed, so a reader asks rr-consumed
# (rrr_consumed), not rr-relay.
#
# "Not configured" (no job_ledger_row / job_ledger_put in scope) writes and
# reads nothing. A failed PUT is one $DLOG (else $LOG) line and rc 0.
#
# Ids are checked as rr-cursor checks them: a project outside [A-Za-z0-9._-],
# or `.` / `..`, or no $HARNESS / $H root, is rc 1 and writes nothing.

_rrr_id_ok() {
  [ -n "${HARNESS:-${H:-}}" ] || return 1
  case "${1:-}" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0
}
_rrr_log() { # _rrr_log <project> <line>
  local f="${DLOG:-${LOG:-}}"
  [ -n "$f" ] || return 0
  echo "${STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} [$1] rr-relay: $2" >> "$f" 2>/dev/null
  return 0
}

# rrr_rowkey <json-file> [build-id] — prints <KEY>@<build-id>. rc 1: no file.
#   The chain rrc_json_consume uses: KEY = .key, else the basename less .json;
#   the build id = the arg, else the last segment of .build_dir, else
#   .machine_build_dir, else the first 16 hex of the file's sha256.
rrr_rowkey() {
  local f="${1:-}" bid="${2:-}" key
  [ -f "$f" ] || return 1
  key=$(jq -r '.key // ""' "$f" 2>/dev/null)
  [ -n "$bid" ] || bid=$(jq -r '.build_dir // "" | split("/") | last // ""' "$f" 2>/dev/null)
  [ -n "$bid" ] || bid=$(jq -r '.machine_build_dir // ""' "$f" 2>/dev/null)
  [ -n "$key" ] || { key=$(basename "$f"); key="${key%.json}"; }
  [ -n "$bid" ] || bid=$(sha256sum < "$f" 2>/dev/null | cut -c1-16)
  printf '%s@%s\n' "$key" "$bid"
}

# rrr_park <project> <payload-json> — the rr-relay row, status parked.
#   rc 0, also when the PUT fails or the payload has no .key (nothing written);
#   rc 1 on a bad project id. The payload is written to a temp file exactly as
#   the relay writes it, so the key is the key the consumer computes.
rrr_park() {
  local p="${1:-}" pl="${2:-}" tf rk detail
  _rrr_id_ok "$p" || return 1
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  printf '%s' "$pl" | jq -e '.key // "" | length > 0' >/dev/null 2>&1 || return 0
  tf=$(mktemp "${TMPDIR:-/tmp}/rr-relay.XXXXXX" 2>/dev/null) || { _rrr_log "$p" "rr-relay row NOT written (no temp file)"; return 0; }
  printf '%s\n' "$pl" > "$tf"
  rk=$(rrr_rowkey "$tf")
  detail=$(jq -c . "$tf" 2>/dev/null)
  # The worker keeps 4000 chars of detail. Cut the one long field, not the
  # JSON, so the detail always parses.
  [ "${#detail}" -gt 3500 ] && detail=$(jq -c '.result |= (tostring | .[0:1000])' "$tf" 2>/dev/null)
  rm -f "$tf"
  job_ledger_put rr-relay "$p/$rk" parked "$detail" >/dev/null 2>&1 \
    || _rrr_log "$p" "rr-relay row NOT written for $rk (the relay file stands)"
  return 0
}

# rrr_consumed <project> <json-file> — did the owning box consume this json?
#   rc 0 + prints the rr-consumed status; rc 2 no row; rc 1 could not ask (no
#   client, outage, bad id, no file, a row with no status).
rrr_consumed() {
  local p="${1:-}" f="${2:-}" rk row rc st
  _rrr_id_ok "$p" && [ -f "$f" ] || return 1
  command -v job_ledger_row >/dev/null 2>&1 || return 1
  rk=$(rrr_rowkey "$f") || return 1
  row=$(job_ledger_row rr-consumed "$p/$rk" 2>/dev/null); rc=$?
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 0 ] || return 1
  st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
  [ -n "$st" ] || return 1
  printf '%s\n' "$st"
}
