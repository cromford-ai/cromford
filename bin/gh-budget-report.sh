#!/bin/bash
# bin/gh-budget-report.sh — who spends the GitHub REST budget (#6545 wave 1).
#
#   bin/gh-budget-report.sh [--window 24h|<n>h|<n>d] [--merged <n>] [--local] [--json]
#
# Prints, for the trailing window: REST calls per lane per hour, per repo, the
# top 10 (lane, endpoint class) pairs and calls per merged PR. Writes the same
# numbers to state/gh-budget/<date>.json (<date>-<window>.json when the window
# is not 24h). Wave 3 of #6545 reads `top` from that file.
#
# WHERE THE NUMBERS COME FROM. The fleet's gh_ledger table (BH-1574): every box
# pushes its hourly aggregates of state/gh-rest-ledger/<hour>.tsv there, and
# GET /api/metrics/gh-ledger?group=lane-hour|lane-class|repo answers each block
# grouped by the worker, REST rows only, with exact totals. When the worker
# does not answer (or answers without the `group` echo, a worker deployed
# before this), the report reads THIS box's hour files and its first line says
# so. --local reads the files and skips the worker.
#
#   "endpoint class"  the ledger's path_class: ids folded to N, shas to SHA
#   REST              resource is not graphql and the class is not graphql;
#                     the GraphQL total prints on its own line, never mixed in
#   ranking           counted (what GitHub charged: a 304 or a 000 is not),
#                     then calls, then the name
#   repo              <owner>/<repo> of a class that starts repos/; any other
#                     class is "(no repo)". Digits in a repo name show folded.
#   calls per PR      the merge count is --merged, else GET /api/metrics/dora
#                     ?days=<ceil(window/24h)> totals.merged, else n/a
#   served            how each REST call was answered (ledger column 15,
#                     BH-8066): `cache` (the gh shim's cache, no request),
#                     `304`, `200` (a full answer, whatever its code) or `-`
#                     (no answer). A `cache` row is not a request, so it is in
#                     no other number here; SERVED prints each share. The fleet
#                     reads it with group=served; a worker without that group
#                     prints `SERVED n/a` and the rest of the report stays fleet.
#
# A lane with no row in the window is ABSENT, never printed as 0.
#
# Retention: state/gh-budget/????-??-??*.json older than GH_BUDGET_KEEP_DAYS
# (env, then the settings row conf.gh-budget-report.keep_days, then 90) are
# deleted after each write, one logs/gh-budget-report.log line per sweep.
#
# It costs no GitHub API call. It makes at most 5 harness-jobs reads, each with
# JOBS_ALERT=0, so an operator's run never spends the fleet's outage alert.
#
# rc 0 = printed (including "no REST calls recorded")
# rc 2 = usage, a bad --window or a bad --merged; nothing written
# rc 3 = the state file could not be written (the text still prints)
set -uo pipefail

H="${HARNESS:-/root/harness}"
LOG="$H/logs/gh-budget-report.log"
USAGE="usage: gh-budget-report.sh [--window 24h|<n>h|<n>d] [--merged <n>] [--local] [--json]"
WINDOW=24h; MERGED=""; MODE=auto; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --window) WINDOW="${2:-}"; shift 2 || { echo "$USAGE" >&2; exit 2; } ;;
    --window=*) WINDOW="${1#*=}"; shift ;;
    --merged) MERGED="${2:-}"; shift 2 || { echo "$USAGE" >&2; exit 2; } ;;
    --merged=*) MERGED="${1#*=}"; shift ;;
    --local) MODE=local; shift ;;
    --json) AS_JSON=1; shift ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done

# <n>h / <n>d -> hours, the same parse as bin/dora-digest.sh.
case "$WINDOW" in
  *h) N="${WINDOW%h}"; case "$N" in ''|*[!0-9]*) N="" ;; esac; HOURS="$N" ;;
  *d) N="${WINDOW%d}"; case "$N" in ''|*[!0-9]*) N="" ;; esac; [ -n "$N" ] && HOURS=$((10#$N * 24)) || HOURS="" ;;
  *)  HOURS="" ;;
esac
if [ -z "${HOURS:-}" ] || [ "$((10#$HOURS))" -le 0 ]; then
  echo "gh-budget-report.sh: --window must be <n>h or <n>d (got '$WINDOW')" >&2; echo "$USAGE" >&2; exit 2
fi
HOURS=$((10#$HOURS))
case "$MERGED" in
  '') : ;;
  *[!0-9]*) echo "gh-budget-report.sh: --merged must be a non-negative integer (got '$MERGED')" >&2; echo "$USAGE" >&2; exit 2 ;;
  *) MERGED=$((10#$MERGED)) ;;
esac
command -v jq >/dev/null 2>&1 || { echo "gh-budget-report.sh: jq is required" >&2; exit 2; }

# ONE clock read; every hour below is an offset from it. GH_BUDGET_NOW (epoch)
# is the test seam.
NOW="${GH_BUDGET_NOW:-$(date -u +%s)}"
utc() { date -u -d "@$1" "$2" 2>/dev/null || date -u -r "$1" "$2"; }
SINCE_HOUR=$(utc $((NOW - HOURS * 3600)) +%Y-%m-%dT%H)
DATE_TAG=$(utc "$NOW" +%F)
GENERATED=$(utc "$NOW" +%Y-%m-%dT%H:%M:%SZ)
DAYS=$(( (HOURS + 23) / 24 ))
STATE_DIR="$H/state/gh-budget"
case "$WINDOW" in 24h) STATE_FILE="$STATE_DIR/$DATE_TAG.json" ;; *) STATE_FILE="$STATE_DIR/$DATE_TAG-$WINDOW.json" ;; esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-budget-report.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# ── the fleet, from D1 ──────────────────────────────────────────────────────
if [ "$MODE" != local ]; then
  # The same rule as bin/gh-quota-report.sh: only a client with its modules
  # beside it (jobs-client.sh EXITS the shell that sources it otherwise).
  for JC in "$H/bin/jobs-client.sh" "$(dirname "$0")/jobs-client.sh"; do
    # shellcheck source=bin/jobs-client.sh
    [ -r "$JC" ] && [ -r "${JC%/*}/lib/jobs/req.sh" ] && { . "$JC"; break; }
  done
  MODE=local
  [ -n "${HARNESS_SECRET:-}" ] && command -v _jobs_req >/dev/null 2>&1 && MODE=fleet
fi

# fleet_read — the three grouped reads, to files. rc 1 sets FLEET_WHY.
fleet_read() {
  local g
  for g in lane-hour lane-class repo; do
    # To a FILE, not `$( )`: JOBS_HTTP is set in the shell that ran the request.
    if ! JOBS_ALERT=0 _jobs_req GET "/api/metrics/gh-ledger?since=$SINCE_HOUR&group=$g" > "$WORK/$g.json" 2>/dev/null; then
      FLEET_WHY="http=${JOBS_HTTP:-none}"; return 1
    fi
    jq -e '.rows | type == "array"' "$WORK/$g.json" >/dev/null 2>&1 || { FLEET_WHY="unparseable answer"; return 1; }
    jq -e --arg g "$g" '.group == $g' "$WORK/$g.json" >/dev/null 2>&1 || { FLEET_WHY="no group echo"; return 1; }
  done
  jq -n --slurpfile a "$WORK/lane-hour.json" --slurpfile b "$WORK/lane-class.json" --slurpfile c "$WORK/repo.json" '
    { lane_hour: $a[0].rows, lane_class: $b[0].rows, repo: $c[0].rows,
      truncated: { lane_hour: ($a[0].truncated == true), lane_class: ($b[0].truncated == true), repo: ($c[0].truncated == true) },
      totals: $b[0].totals }' > "$WORK/raw.json" || { FLEET_WHY="unparseable answer"; return 1; }
  return 0
}

# fleet_served — the optional group=served read, into $WORK/served.json as
# {cache, "304", "200", "-"}. rc 1 sets SERVED_WHY; the report stays fleet.
fleet_served() {
  if ! JOBS_ALERT=0 _jobs_req GET "/api/metrics/gh-ledger?since=$SINCE_HOUR&group=served" > "$WORK/served-raw.json" 2>/dev/null; then
    case "${JOBS_HTTP:-}" in
      400) SERVED_WHY="worker has no served group" ;;
      *)   SERVED_WHY="served read failed (http=${JOBS_HTTP:-none})" ;;
    esac
    return 1
  fi
  jq -e '.group == "served" and (.rows | type == "array")' "$WORK/served-raw.json" >/dev/null 2>&1 \
    || { SERVED_WHY="worker has no served group"; return 1; }
  jq '{cache: 0, "304": 0, "200": 0, "-": 0} + (reduce .rows[] as $r ({}; .[$r.served | tostring] += ($r.calls // 0)))' \
    "$WORK/served-raw.json" > "$WORK/served.json" 2>/dev/null || { SERVED_WHY="unparseable served answer"; return 1; }
  return 0
}

# local_read — this box's hour files whose name is >= SINCE_HOUR, one awk pass.
# Columns (bin/lib/gh-rest-ledger.sh gh_ledger_append): 1 ts, 2 lane, 5 path
# class, 6 status, 7 counted, 11 resource ("-" on a line written before column
# 11), 15 served (derived from the status on a line written before column 15).
# A REST row with status `cache` is counted in `served` and nowhere else.
local_read() {
  local dir="$H/state/gh-rest-ledger" f files=() first="" last=""
  for f in "$dir"/*.tsv; do
    [ -f "$f" ] || continue
    f="${f##*/}"; f="${f%.tsv}"
    [[ "$f" < "$SINCE_HOUR" ]] && continue
    files+=("$dir/$f.tsv")
    [ -z "$first" ] && first="$f"; last="$f"
  done
  if [ "${#files[@]}" = 0 ]; then
    LOCAL_NOTE="no hour file in $dir since $SINCE_HOUR"
    : > "$WORK/local.tsv"
  else
    LOCAL_NOTE="local files cover $first..$last"
    awk -F'\t' '
      NF >= 7 {
        c = $7 + 0
        res = (NF >= 11 && $11 != "" ? $11 : "-")
        pc = $5; bare = pc; sub(/^\//, "", bare)
        if (res == "graphql" || bare == "graphql") { gc++; gk += c; next }
        st = $6
        sv = (NF >= 15 && $15 != "") ? $15 : (st == "cache" ? "cache" : (st == "304" ? "304" : ((st == "000" || st == "") ? "-" : "200")))
        svc[sv]++
        if (st == "cache") next
        rc++; rk += c
        lh = substr($1, 1, 13) "\t" $2; lhc[lh]++; lhk[lh] += c
        lc = $2 "\t" pc; lcc[lc]++; lck[lc] += c
        repo = "(no repo)"
        if (substr(bare, 1, 6) == "repos/") {
          n = split(substr(bare, 7), seg, "/")
          if (n >= 2 && seg[1] != "" && seg[2] != "") repo = seg[1] "/" seg[2]
        }
        rpc[repo]++; rpk[repo] += c
      }
      END {
        printf "TOT\t%d\t%d\t%d\t%d\n", rc, rk, gc, gk
        for (k in lhc) printf "LH\t%s\t%d\t%d\n", k, lhc[k], lhk[k]
        for (k in lcc) printf "LC\t%s\t%d\t%d\n", k, lcc[k], lck[k]
        for (k in rpc) printf "RP\t%s\t%d\t%d\n", k, rpc[k], rpk[k]
        for (k in svc) printf "SV\t%s\t%d\n", k, svc[k]
      }' "${files[@]}" > "$WORK/local.tsv" || return 1
  fi
  jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) as $l
    | { lane_hour: [ $l[] | select(.[0] == "LH") | {hour: .[1], lane: .[2], calls: (.[3] | tonumber), counted: (.[4] | tonumber)} ],
        lane_class: [ $l[] | select(.[0] == "LC") | {lane: .[1], path_class: .[2], calls: (.[3] | tonumber), counted: (.[4] | tonumber)} ],
        repo: [ $l[] | select(.[0] == "RP") | {repo: .[1], calls: (.[2] | tonumber), counted: (.[3] | tonumber)} ],
        served: ({cache: 0, "304": 0, "200": 0, "-": 0}
                 + (reduce ($l[] | select(.[0] == "SV")) as $s ({}; .[$s[1]] += ($s[2] | tonumber)))),
        truncated: {lane_hour: false, lane_class: false, repo: false},
        totals: ( [ $l[] | select(.[0] == "TOT") ][0] // ["TOT", "0", "0", "0", "0"]
                  | {rest_calls: (.[1] | tonumber), rest_counted: (.[2] | tonumber),
                     graphql_calls: (.[3] | tonumber), graphql_counted: (.[4] | tonumber)} ) }' \
    "$WORK/local.tsv" > "$WORK/raw.json"
}

SOURCE=local; FIRST_LINE=""; SOURCE_NOTE=""; LOCAL_NOTE=""; SERVED_WHY=""
if [ "$MODE" = fleet ]; then
  FLEET_WHY=""
  if fleet_read; then
    SOURCE=fleet; SOURCE_NOTE="fleet (D1) gh_ledger via GET /api/metrics/gh-ledger?group="
    if fleet_served; then
      jq --slurpfile s "$WORK/served.json" '.served = $s[0]' "$WORK/raw.json" > "$WORK/raw2.json" && mv -f "$WORK/raw2.json" "$WORK/raw.json"
    fi
  else
    FIRST_LINE="gh-budget-report: fleet read failed (${FLEET_WHY:-worker unreachable}) — this box's ledger only"
  fi
fi
if [ "$SOURCE" = local ]; then
  local_read || { echo "gh-budget-report.sh: cannot read $H/state/gh-rest-ledger" >&2; exit 2; }
  SOURCE_NOTE="$LOCAL_NOTE"
fi

# ── the merge count ─────────────────────────────────────────────────────────
M_COUNT=null; M_SOURCE=absent
if [ -n "$MERGED" ]; then
  M_COUNT="$MERGED"; M_SOURCE="--merged (caller)"
elif [ "$SOURCE" = fleet ]; then
  if JOBS_ALERT=0 _jobs_req GET "/api/metrics/dora?days=$DAYS" > "$WORK/dora.json" 2>/dev/null \
     && v=$(jq -er '.totals.merged | select(type == "number")' "$WORK/dora.json" 2>/dev/null); then
    M_COUNT="$v"; M_SOURCE="GET /api/metrics/dora?days=$DAYS totals.merged"
  fi
fi

# ── the document ────────────────────────────────────────────────────────────
jq -n --slurpfile raw "$WORK/raw.json" --arg gen "$GENERATED" --arg warg "$WINDOW" \
  --argjson hours "$HOURS" --arg since "$SINCE_HOUR" --arg source "$SOURCE" \
  --arg note "$SOURCE_NOTE" --argjson mcount "$M_COUNT" --arg msource "$M_SOURCE" \
  --argjson days "$DAYS" --arg file "$STATE_FILE" --arg swhy "$SERVED_WHY" '
  def r1: (. * 10 | round) / 10;
  $raw[0] as $r
  | ($r.totals // {}) as $t
  | ($r.lane_class | map(select(.calls > 0 or .counted > 0))
       | sort_by(-.counted, -.calls, .lane, .path_class)) as $lc
  | { generated_at: $gen,
      window: {arg: $warg, hours: $hours, since_hour: $since},
      source: $source, source_note: $note, state_file: $file,
      truncated: $r.truncated,
      totals: {rest_calls: ($t.rest_calls // 0), rest_counted: ($t.rest_counted // 0),
               graphql_calls: ($t.graphql_calls // 0), graphql_counted: ($t.graphql_counted // 0)},
      merged: {count: $mcount, source: $msource, days: $days},
      served: ($r.served // null),
      served_why: (if $r.served == null then (if $swhy == "" then "served read failed" else $swhy end) else null end),
      per_merged_pr: (if ($mcount // 0) > 0
                      then {calls: (($t.rest_calls // 0) / $mcount | r1), counted: (($t.rest_counted // 0) / $mcount | r1)}
                      else {calls: null, counted: null} end),
      per_merged_pr_why: (if $mcount == null then "merge count absent"
                          elif $mcount == 0 then "no merges in window" else null end),
      top: ($lc[:10] | map({lane, path_class, calls, counted})),
      repos: ($r.repo | map(select(.calls > 0 or .counted > 0) | {repo, calls, counted})
                | sort_by(-.counted, -.calls, .repo)),
      lane_hour: ($r.lane_hour | map(select(.calls > 0 or .counted > 0) | {hour, lane, calls, counted})
                    | sort_by(.hour, .lane)),
      notes: ([ "a repo name with digits shows folded (Org/appN): the ledger folds digits before a row is stored" ]
              + (if ($hours % 24) != 0 and $mcount != null and $msource != "--merged (caller)"
                 then ["the merge count covers \($days * 24)h (dora days=\($days)); the window is \($hours)h"] else [] end)) }' \
  > "$WORK/doc.json" || { echo "gh-budget-report.sh: could not build the report" >&2; exit 2; }

# ── write (temp + mv in the same dir: never a partial file) ────────────────
WRITE_RC=0
if mkdir -p "$STATE_DIR" 2>/dev/null && TMPF=$(mktemp "$STATE_DIR/.gh-budget.XXXXXX" 2>/dev/null); then
  if cp "$WORK/doc.json" "$TMPF" && mv -f "$TMPF" "$STATE_FILE"; then :; else rm -f "$TMPF"; WRITE_RC=3; fi
else
  WRITE_RC=3
fi
[ "$WRITE_RC" = 0 ] || echo "gh-budget-report.sh: could not write $STATE_FILE" >&2

# ── print ───────────────────────────────────────────────────────────────────
if [ "$AS_JSON" = 1 ]; then
  cat "$WORK/doc.json"
else
  [ -n "$FIRST_LINE" ] && echo "$FIRST_LINE"
  jq -r '
    def pad($n): tostring | if length >= $n then . else . + (" " * ($n - length)) end;
    def lpad($n): tostring | if length >= $n then . else (" " * ($n - length)) + . end;
    def trunc($k): if .truncated[$k] then "  TRUNCATED at 5000 rows" else "" end;
    "gh-budget-report: \(if .source == "fleet" then "fleet (D1)" else "this box'"'"'s ledger only" end) \(.window.arg) — since \(.window.since_hour) UTC (\(.source_note))",
    "TOTAL rest calls=\(.totals.rest_calls) counted=\(.totals.rest_counted) (graphql calls=\(.totals.graphql_calls) not counted here)",
    (if .per_merged_pr.counted != null
     then "CALLS PER MERGED PR calls=\(.per_merged_pr.calls) counted=\(.per_merged_pr.counted) merged=\(.merged.count) (\(.merged.source))"
     else "CALLS PER MERGED PR n/a (\(.per_merged_pr_why))" end),
    (if .served == null then "SERVED n/a (\(.served_why))"
     else (.served as $s | ([$s[]] | add) as $n
           | def share($k): "\($k)=\($s[$k]) (\(if $n > 0 then ($s[$k] * 1000 / $n | round) / 10 else 0 end)%)";
           "SERVED \(share("cache")) \(share("304")) \(share("200"))\(if ($s["-"] // 0) > 0 then " " + share("-") else "" end)")
     end),
    (if (.lane_hour | length) == 0 and (.top | length) == 0 then "no REST calls recorded in \(.window.arg)" else empty end),
    "",
    "TOP 10 (lane, endpoint class)\(trunc("lane_class"))",
    "\("COUNTED" | lpad(8)) \("CALLS" | lpad(8))  \("LANE" | pad(28)) CLASS",
    (.top[] | "\(.counted | lpad(8)) \(.calls | lpad(8))  \(.lane | pad(28)) \(.path_class)"),
    "",
    "CALLS PER REPO\(trunc("repo"))",
    "\("COUNTED" | lpad(8)) \("CALLS" | lpad(8))  REPO",
    (.repos[] | "\(.counted | lpad(8)) \(.calls | lpad(8))  \(.repo)"),
    "",
    "CALLS PER LANE PER HOUR\(trunc("lane_hour"))",
    "\("HOUR" | pad(14)) \("LANE" | pad(28)) \("CALLS" | lpad(8)) \("COUNTED" | lpad(8))",
    (.lane_hour[] | "\(.hour | pad(14)) \(.lane | pad(28)) \(.calls | lpad(8)) \(.counted | lpad(8))")
  ' "$WORK/doc.json"
fi

# ── retention of the state files ────────────────────────────────────────────
if [ "$WRITE_RC" = 0 ]; then
  mkdir -p "$H/logs" 2>/dev/null
  KEEP="${GH_BUDGET_KEEP_DAYS:-}"
  if [ -z "$KEEP" ]; then
    # shellcheck source=bin/lib/conf-row.sh
    . "$(dirname "$0")/lib/conf-row.sh" 2>/dev/null || true
    command -v conf_row >/dev/null 2>&1 && KEEP=$(conf_row gh-budget-report keep_days "$H" 2>/dev/null) || KEEP=""
    KEEP_SRC="conf.gh-budget-report.keep_days"
  else
    KEEP_SRC="GH_BUDGET_KEEP_DAYS"
  fi
  case "$KEEP" in
    '') KEEP=90 ;;
    *[!0-9]*) KEEP_BAD="$KEEP" ;;
    *) [ "$((10#$KEEP))" -gt 0 ] && KEEP=$((10#$KEEP)) || KEEP_BAD="$KEEP" ;;
  esac
  if [ -n "${KEEP_BAD+x}" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $KEEP_SRC='$KEEP_BAD' is not a positive integer — using 90" >> "$LOG"; KEEP=90
  fi
  SWEPT=$(find "$STATE_DIR" -maxdepth 1 -type f -name '????-??-??*.json' -mtime +"$KEEP" -print -delete 2>/dev/null | wc -l)
  [ "${SWEPT:-0}" -gt 0 ] && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') swept $SWEPT file(s) older than ${KEEP}d from $STATE_DIR" >> "$LOG"
fi
exit "$WRITE_RC"
