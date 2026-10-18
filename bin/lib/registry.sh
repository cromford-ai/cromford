#!/bin/bash
# shellcheck shell=bash
# alert-writer: by-design — its one line reports a harness-jobs outage; bin/alert-line.sh notes the row through that same worker with a 30 s strict beat, which would stall the bin/fleet-conf.sh caller that opened the episode
# bin/lib/registry.sh — BH-5649 (BH-5633.1): the fleet registry read path.
# Sourced by bin/fleet-conf.sh and bin/render-cron.sh ONLY when
# REGISTRY_SOURCE=db; defines functions, runs nothing. The default
# REGISTRY_SOURCE=file never sources this file, so file mode costs nothing.
#
#   registry_conf_path  prints the path of a fleet.conf-format file rendered
#                       from the registry, rc 0. rc 1 = use the committed files.
#   registry_json_path  the same ladder; prints the cached registry.json
#                       (render-cron.sh reads .lane_boxes from it).
#   registry_json_fetched  the same with TTL 0; rc 1 unless THIS call fetched
#                       a usable answer (bin/registry-export.sh --snapshot,
#                       bin/lib/registry-source-seed.sh).
#
# THE LADDER. 1. a cache younger than REGISTRY_CACHE_TTL_S (default 60) is
# served with no HTTP and no jq: render-cron.sh alone calls fleet-conf.sh about
# 30 times per box. 2. not configured (no JOBS_URL or no HARNESS_SECRET): no
# fetch and no alert; the cache at any age, else rc 1, and one registry.log line
# a UTC day. 3. GET /api/registry under flock -n; another refresher holding the
# lock means the cache at any age (with no cache, wait up to 10 s for it).
# 4. a usable answer rewrites the cache (mktemp + mv in the same directory, so
# no reader sees half a file). Anything else — transport failure, non-2xx,
# non-JSON, `{}`, version 0, no projects — is NOT an empty registry: the cache
# is kept byte for byte, the first process of the outage writes ONE ALERTS
# line, and the cache answers at any age, else rc 1 (the committed files).
#
# The registry stores a tailnet IP per BOX. Every box with one also renders as
# `# @box <box> <ip>` (BH-5650), so bin/fleet-conf.sh answers the IP of a box
# that has no project yet (bin/registry.sh add-box). A box with a role renders
# as `# @boxrole <box> <box_id> <role>` (bin/fleet-conf.sh --boxes-with-roles);
# a null role renders nothing and the reader applies its default.
# A fleet.conf row with no IP on a box whose other row has one answers that IP
# here; today's fleet.conf has no such row, and bin/registry-seed.sh refuses two
# different IPs for one box.
#
# State: ${HARNESS}/state/registry/{registry.json,fleet.conf,version,outage}.
# The root is ${HARNESS:-${H:-}} and nothing else (D43): empty means rc 1.

_rg_dir() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s/state/registry' "$root"
}

# _rg_fresh <dir> — rc 0 when both cache files exist and are younger than the TTL.
_rg_fresh() {
  local d="$1" ttl="${REGISTRY_CACHE_TTL_S:-60}" now m
  [ -s "$d/registry.json" ] && [ -s "$d/fleet.conf" ] || return 1
  case "$ttl" in ''|*[!0-9]*) ttl=60 ;; esac
  now=$(date +%s); m=$(stat -c %Y "$d/fleet.conf" 2>/dev/null) || return 1
  [ $((now - m)) -lt "$ttl" ]
}

_rg_have_cache() { [ -s "$1/registry.json" ] && [ -s "$1/fleet.conf" ]; }

# registry_valid <file> — rc 0 when the file is a usable registry answer.
registry_valid() {
  jq -e '
    def tok: type == "string" and length > 0 and (test("[\\s[:cntrl:]]") | not);
    (.version | type == "number" and . >= 1)
    and (.projects | type == "array" and length > 0)
    and (.boxes | type == "array") and (.lane_boxes | type == "array")
    and (.box_accounts | type == "array")
    and all(.projects[]; (.project | tok) and (.repo | tok)
          and (.prod | tok) and (.board_prefix | tok)
          and (.cron_offset | type == "number" and . == floor and . >= 0 and . <= 9)
          and (.box == null or (.box | tok)))
    and all(.boxes[]; (.box | tok) and (.tailnet_ip == null or (.tailnet_ip | tok)))' "$1" >/dev/null 2>&1
}

# _rg_render <registry.json> — the fleet.conf text bin/fleet-conf.sh reads.
_rg_render() {
  jq -r '
    (.boxes | map({key: .box, value: .}) | from_entries) as $b
    | "# GENERATED from harness-jobs /api/registry v\(.version) — do not edit; source: REGISTRY_SOURCE=db",
      (.boxes | sort_by(.box)[] | select(.standby_hub_name != null and .standby_hub_id != null)
        | "# @standby \(.box) \(.standby_hub_name) \(.standby_hub_id)"),
      (.boxes | sort_by(.box)[] | select(.tailnet_ip != null) | "# @box \(.box) \(.tailnet_ip)"),
      (.boxes | sort_by(.box)[] | select((.role // null) != null) | "# @boxrole \(.box) \(.box_id) \(.role)"),
      (.projects | sort_by(.position, .project)[] | select(.status == "retired")
        | "# @retired \(.project) \(.box // "-")"),
      (.projects | sort_by(.position, .project)[] | select((.status // "active") == "active")
        | [.project, .repo, .prod, .board_prefix, (.cron_offset | tostring)]
          + (if .box == null then [] else [.box] + ([$b[.box].tailnet_ip // empty]) end)
        | join(" "))' "$1"
}

# _rg_put <dir> <name> <src-file> — atomic replace inside <dir>.
_rg_put() {
  local tmp
  tmp=$(mktemp "$1/.$2.XXXXXX") || return 1
  cat "$3" > "$tmp" && mv -f "$tmp" "$1/$2" || { rm -f "$tmp"; return 1; }
}

_rg_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

_rg_log() { # _rg_log <root> <message>
  mkdir -p "$1/logs" 2>/dev/null && { echo "$(_rg_stamp) [registry] $2" >> "$1/logs/registry.log"; } 2>/dev/null
  return 0
}

# _rg_outage <root> <dir> <reason> — open the episode; only the creator alerts.
_rg_outage() {
  local root="$1" d="$2" why="$3" tail v age
  ( set -C; : > "$d/outage" ) 2>/dev/null || return 0
  if _rg_have_cache "$d"; then
    v=$(cat "$d/version" 2>/dev/null); age=$(( $(date +%s) - $(stat -c %Y "$d/fleet.conf" 2>/dev/null || date +%s) ))
    tail="reading the cached registry v${v:-?} (${age}s old)"
  else
    tail="no cache, reading the committed fleet.conf/lanes.d"
  fi
  mkdir -p "$root/logs" 2>/dev/null
  { echo "$(_rg_stamp) [registry] harness-jobs /api/registry unusable ($why) — $tail; builds and crons continue. Check the worker/jobs deploy and HARNESS_SECRET." \
    >> "$root/logs/ALERTS.log"; } 2>/dev/null
  return 0
}

# _rg_fetch <root> <dir> — one GET; rc 0 = the cache now holds a usable answer.
_rg_fetch() {
  local root="$1" d="$2" body st rc why conf v
  body=$(mktemp "$d/.fetch.XXXXXX") || return 1
  st=$(mktemp "$d/.status.XXXXXX") || { rm -f "$body"; return 1; }
  JOBS_HARNESS="$root" JOBS_ALERT=0 JOBS_RETRIES=0 JOBS_TIMEOUT="${REGISTRY_API_TIMEOUT_S:-5}" \
    JOBS_STATUS_FILE="$st" _jobs_req GET /api/registry > "$body"
  rc=$?
  why=$(cat "$st" 2>/dev/null); rm -f "$st"
  if [ "$rc" -eq 0 ] && registry_valid "$body"; then
    conf=$(mktemp "$d/.conf.XXXXXX") || { rm -f "$body"; return 1; }
    v=$(jq -r '.version' "$body")
    if _rg_render "$body" > "$conf" && _rg_put "$d" registry.json "$body" && _rg_put "$d" fleet.conf "$conf"; then
      printf '%s\n' "$v" > "$conf" && _rg_put "$d" version "$conf"
      rm -f "$conf" "$body"
      if [ -e "$d/outage" ]; then rm -f "$d/outage"; _rg_log "$root" "registry API usable again (v$v)"; fi
      return 0
    fi
    rm -f "$conf"
    why="cache write failed"
  elif [ "$rc" -eq 0 ]; then
    why="${why:-http=2xx}, not a registry"
  fi
  rm -f "$body"
  _rg_outage "$root" "$d" "${why:-no answer}"
  return 1
}

# _rg_ladder — rc 0 when the cache in $(_rg_dir) may be served.
_rg_ladder() {
  local root="${HARNESS:-${H:-}}" d fd day
  d=$(_rg_dir) || return 1
  _rg_fresh "$d" && return 0
  mkdir -p "$d" 2>/dev/null || return 1
  # shellcheck source=bin/lib/jobs/req.sh
  . "${BASH_SOURCE[0]%/*}/jobs/req.sh" 2>/dev/null || { _rg_have_cache "$d"; return; }
  if [ -z "${JOBS_URL:-}" ] || [ -z "${HARNESS_SECRET:-}" ]; then
    day=$(date -u +%Y%m%d)
    if [ ! -e "$root/flags/registry-not-configured-$day" ]; then
      mkdir -p "$root/flags" 2>/dev/null && touch "$root/flags/registry-not-configured-$day" 2>/dev/null
      _rg_log "$root" "REGISTRY_SOURCE=db but harness-jobs is not configured (JOBS_URL or HARNESS_SECRET empty) — reading the cache, else the committed fleet.conf"
    fi
    _rg_have_cache "$d"; return
  fi
  exec {fd}>"$d/.refresh.lock" || { _rg_have_cache "$d"; return; }
  if ! flock -n "$fd"; then
    if _rg_have_cache "$d"; then exec {fd}>&-; return 0; fi
    flock -w 10 "$fd" || { exec {fd}>&-; return 1; }
    # The holder may have just written it.
    if _rg_have_cache "$d"; then exec {fd}>&-; return 0; fi
  fi
  _rg_fetch "$root" "$d"
  exec {fd}>&-
  _rg_have_cache "$d"
}

registry_conf_path() {
  local d
  _rg_ladder || return 1
  d=$(_rg_dir) || return 1
  printf '%s\n' "$d/fleet.conf"
}

registry_json_path() {
  local d
  _rg_ladder || return 1
  d=$(_rg_dir) || return 1
  printf '%s\n' "$d/registry.json"
}

# registry_json_fetched — the ladder with TTL 0, rc 0 and the path ONLY when
# this call wrote registry.json from a fresh usable answer (BH-5651). A cache
# served through an outage, a held refresh lock or a box with no JOBS_URL is
# rc 1. _rg_put always installs a new file, so a new inode is the proof.
registry_json_fetched() {
  local d before after
  d=$(_rg_dir) || return 1
  before=$(stat -c %i "$d/registry.json" 2>/dev/null)
  REGISTRY_CACHE_TTL_S=0 _rg_ladder || return 1
  after=$(stat -c %i "$d/registry.json" 2>/dev/null) || return 1
  [ "$after" != "$before" ] && [ ! -e "$d/outage" ] || return 1
  printf '%s\n' "$d/registry.json"
}
