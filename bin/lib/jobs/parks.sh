# shellcheck shell=bash
# bin/lib/jobs/parks.sh — the jobs-worker client of the D1 `parks` table
# (BH-9075, BH-9067.3; worker/jobs/src/routes/parks.js, docs/events-bh-9067/3-parks.md).
# SOURCED, never run. No side effect at source time. Not a jobs-client module
# (JC_MODULES is unchanged): bin/lib/parks-write.sh, bin/lib/br/opt/parks.sh
# and bin/lib/mc/parks-delta.sh source it on demand. It loads _jobs_req
# through bin/jobs-client.sh when the caller did not.
#
# THE ONE RULE: a failure is never "no changes". Every verb prints NOTHING and
# answers rc 1 on any failure (no client, no answer, a non-200, bad JSON, a
# missing field), so a caller can never read an outage as an empty table.
#
#   parks_put <tsv-file>
#       One PUT /api/parks of every line of the file. A line is 12 TSV columns:
#         project ck source state head reason url rec ticket updated_at writer parked_at
#       `-` is "keep the stored value" for the text columns, and parked_at `-`
#       is null. rc 0 and `upserted=<n>` only on a 200 whose .upserted is a
#       number. JOBS_HTTP stays set for the caller (400 = a bad row).
#   parks_changed <project> <since> [limit] [hotfix 0|1]
#       One GET /api/parks/changed page. <since> is `<ts>` or `<ts>:<ck>`.
#       Output, only after the whole answer parsed:
#         row\t<12 columns>      one per changed row, done rows included
#         hotfix\t<12 columns>   one per hotfix row (hotfix=1 only)
#         next\t<token>\t<0|1>   the last line: the next cursor, truncated
#       Tabs and newlines in values become spaces; an empty value prints `-`.
#   parks_prune
#       One POST /api/parks/prune {}. rc 0 and
#       `dry=<0|1> counted=<n> removed=<n> backlog=<0|1>` on a parsed 200.
#
# Knob (catalog/lanes.d/_lib.parks.knobs.d/): PARKS_TIMEOUT_S (5).

# _pk_root — the harness root, or rc 1 (never a literal default).
_pk_root() { _PK_H="${HARNESS:-${H:-}}"; [ -n "$_PK_H" ]; }

# _pk_client — _jobs_req, or rc 1.
_pk_client() {
  command -v _jobs_req >/dev/null 2>&1 && return 0
  _pk_root || return 1
  # shellcheck source=../../jobs-client.sh
  . "$_PK_H/bin/jobs-client.sh" >/dev/null 2>&1 || return 1
  command -v _jobs_req >/dev/null 2>&1
}

# pk_knob <ENV> <fallback> <min> <max> — a whole-number lib knob of `parks` in
# bounds, else the fallback. The env value wins (an operator or a test), then
# the settings row lib.parks.<env lowercased> through lane_knob, then the
# fallback, which is the registry default kept here as the documented code
# fallback.
pk_knob() {
  local v="${!1:-}" _LG_KIND=libs
  if [ -z "$v" ] && command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob parks "$1" 2>/dev/null); fi
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  { [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } 2>/dev/null || v=$2
  printf '%s' "$v"
}

# _pk_req <method> <path> [body] — the answer body in $_PK_OUT; rc 0 only on 200.
_pk_req() {
  local tmp rc=0
  _PK_OUT=""
  _pk_client || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/parks.XXXXXX" 2>/dev/null) || return 1
  # Settings row lib.parks.parks_timeout_s; code fallback 5.
  JOBS_TIMEOUT=$(pk_knob PARKS_TIMEOUT_S 5 1 30) JOBS_ALERT=0 \
    _jobs_req "$@" > "$tmp" 2>/dev/null || rc=$?
  _PK_OUT=$(cat "$tmp" 2>/dev/null); rm -f "$tmp"
  [ "$rc" -eq 0 ] && [ "${JOBS_HTTP:-}" = 200 ]
}

parks_put() {
  local f="${1:-}" body n
  [ -s "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  body=$(jq -Rsc '
      [ split("\n")[] | select(length > 0) | split("\t") | select(length == 12)
        | { project: .[0], ck: .[1], source: .[2], state: .[3], head: .[4], reason: .[5],
            url: .[6], rec: .[7], ticket: .[8], updated_at: (.[9] | tonumber), writer: .[10],
            parked_at: (if .[11] == "-" or .[11] == "" then null else (.[11] | tonumber) end) } ]
      | if length == 0 then error("no rows") else {rows: .} end' "$f" 2>/dev/null) || return 1
  _pk_req PUT /api/parks "$body" || return 1
  n=$(jq -er '.upserted | numbers' <<<"$_PK_OUT" 2>/dev/null) || return 1
  printf 'upserted=%s\n' "$n"
}

parks_changed() {
  local p="${1:-}" since="${2:-}" limit="${3:-}" hf="${4:-0}" q out
  case "$p" in ''|*[!a-z0-9._-]*) return 1 ;; esac
  [[ $since =~ ^[0-9]+(:[A-Za-z0-9._-]+)?$ ]] || return 1
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  command -v jq >/dev/null 2>&1 || return 1
  q="project=$p&since=$since${limit:+&limit=$limit}"
  [ "$hf" = 1 ] && q="$q&hotfix=1"
  _pk_req GET "/api/parks/changed?$q" || return 1
  # The whole answer is checked first: every row an object with the 12 keys,
  # next a string, truncated a boolean. Only then is anything printed.
  out=$(jq -r --arg hf "$hf" '
      def cols: [.project, .ck, .source, .state, .head, .reason, .url, .rec, .ticket,
                 .updated_at, .writer, .parked_at]
        | map(if . == null or . == "" then "-" else (tostring | gsub("[\t\r\n]"; " ")) end) | join("\t");
      def okrow: type == "object" and (.project | type) == "string" and (.ck | type) == "string"
        and (.state | type) == "string" and (.updated_at | type) == "number";
      if (.rows | type) == "array" and all(.rows[]; okrow)
         and (.next | type) == "string" and (.truncated | type) == "boolean"
         and ($hf != "1" or ((.hotfix | type) == "array" and all(.hotfix[]; okrow)))
      then (.rows[] | "row\t" + cols),
           (if $hf == "1" then (.hotfix[] | "hotfix\t" + cols) else empty end),
           "next\t\(.next)\t\(if .truncated then 1 else 0 end)"
      else error("bad answer") end' <<<"$_PK_OUT" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

parks_prune() {
  local out
  command -v jq >/dev/null 2>&1 || return 1
  _pk_req POST /api/parks/prune '{}' || return 1
  out=$(jq -er 'if (.dry_run | type) == "boolean" and (.counted | type) == "number"
                   and (.removed | type) == "number" and (.backlog | type) == "boolean"
                then "dry=\(if .dry_run then 1 else 0 end) counted=\(.counted) removed=\(.removed) backlog=\(if .backlog then 1 else 0 end)"
                else error("bad answer") end' <<<"$_PK_OUT" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}
