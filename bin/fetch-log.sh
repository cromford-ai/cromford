#!/bin/bash
# bin/fetch-log.sh <project> <which> <command_id> [match] [since] [until]
#   Resolve one WHITELISTED log, read its newest part, and print the `log_tail`
#   beat JSON on stdout. Called by poll-commands.sh (through bcx_run) for the
#   console's fetch_log command so Mission Control can read a box's logs
#   without anyone SSH-ing into it. An empty argument is "not set".
#
#   No filter: the window is the newest FETCH_LOG_TAIL_BYTES of the file.
#   With a filter, the whole file is filtered first and the window applies to
#   the filtered result:
#     match  a fixed string (grep -F), or an ERE when written /.../ (no
#            back-references). Printable ASCII only. Case-sensitive.
#     since  lines at or after: <n>s|m|h|d (before now) or an ISO date/time
#            (no zone = UTC).
#     until  lines BEFORE (exclusive), same forms.
#   A line's time is the stamp it starts with ([?YYYY-MM-DD[T ]HH:MM[:SS]); a
#   line with none takes the stamp of the line before it.
#   The beat is then fitted to FETCH_LOG_RESPONSE_BYTES: the newest whole lines
#   that fit are sent, omitted_bytes/omitted_lines count the rest, and `more`
#   holds the fetch_log arguments that return the left-out lines.
#
# bin/fetch-log.sh --path <which> [project]
#   Print just the resolved path (the pure resolver the tests exercise).
#
# SECURITY: `which` is a closed set of literals and NOTHING from the request is
# ever interpolated into a path. `triage` is the one variant whose filename
# depends on the request, so its project is matched against fleet.conf rather
# than trusted — a project the fleet does not run cannot address a file.
#
# A log that does not exist yet (cost.csv on a box that has never built,
# pipeline-health.log before the first finding) is reported as empty with
# missing:true, never as a failed command: an honestly empty pane beats an
# error the console has to guess about.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# THE TWO SIZES ARE KNOBS (BH-10102), resolved through lib_env_apply fetch-log
# (catalog/lanes.d/_lib.fetch-log.json): row > env > code fallback. It runs in
# a SUBSHELL (the bin/lib/gh-budget.sh pattern), so a fail-closed exit inside
# the gate never stops this read; the EXIT trap hands back on fd 3 every knob
# that did resolve. The registry is $HARNESS's, else this checkout's own.
_FL_KV=$(
  exec 3>&1
  _FL_R=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
  . "$_FL_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_FL_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_FL_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _FL_K in FETCH_LOG_TAIL_BYTES FETCH_LOG_RESPONSE_BYTES; do printf "%s\t%s\n" "$_FL_K" "${!_FL_K:-}" >&3; done' EXIT
  lib_env_apply fetch-log >/dev/null 2>&1)
while IFS=$'\t' read -r _FL_K _FL_V; do
  if [ -n "$_FL_V" ]; then printf -v "$_FL_K" '%s' "$_FL_V"; fi
done <<<"$_FL_KV"
unset _FL_KV _FL_K _FL_V
# Fallbacks: the rows lib.fetch-log.fetch_log_tail_bytes (5 MiB) and
# lib.fetch-log.fetch_log_response_bytes (96 KiB, worker/jobs/schema.d/
# 202611251523-bh-10102-fetch-log-knobs.sql). The response size stays under
# the 131072-byte argv limit: the beat travels as ONE argv string to beat.sh
# and to curl -d. The ceilings are the registry max of each knob.
FL_TAIL_FALLBACK=5242880;  FL_TAIL_CEIL=16777216
FL_RESP_FALLBACK=98304;    FL_RESP_CEIL=122880
TAIL_MAX="${FETCH_LOG_TAIL_BYTES:-}"
case "$TAIL_MAX" in ''|*[!0-9]*|0*) TAIL_MAX=$FL_TAIL_FALLBACK ;; esac
[ "${#TAIL_MAX}" -gt 9 ] || [ "$TAIL_MAX" -gt "$FL_TAIL_CEIL" ] && TAIL_MAX=$FL_TAIL_CEIL
RESP_MAX="${FETCH_LOG_RESPONSE_BYTES:-}"
case "$RESP_MAX" in ''|*[!0-9]*|0*) RESP_MAX=$FL_RESP_FALLBACK ;; esac
[ "${#RESP_MAX}" -gt 9 ] || [ "$RESP_MAX" -gt "$FL_RESP_CEIL" ] && RESP_MAX=$FL_RESP_CEIL

valid_project() { # EXACT membership in fleet.conf, or the literal "hub"
  # Exact, because fleet-conf.sh's own row lookup is a REGEX: `project-1.os` would
  # match the project-1 row there and box-for.sh would happily route to that
  # box. Rejecting it here, before anything downstream sees it, closes that.
  # "hub" is the one non-project caller: the hub owns no project of its own but
  # holds the decisions log, the cost roll-up and pipeline-health.
  [ "$1" = hub ] && return 0
  [ -n "$1" ] || return 1
  "$(dirname "$0")/fleet-conf.sh" --projects 2>/dev/null | grep -qxF "$1"
}

resolve() { # resolve <which> <project> -> path on stdout, rc 1 if refused
  local which="$1" project="${2:-}"
  # The project is validated for EVERY which, not just the one that puts it in a
  # filename: it also picks the box the request is forwarded to and it lands in
  # the journal, so an unregistered project is a refusal either way.
  valid_project "$project" || return 1
  case "$which" in
    alerts)    echo "$HARNESS/logs/ALERTS.log" ;;
    pipeline)  echo "$HARNESS/logs/pipeline-health.log" ;;
    cost)      echo "$HARNESS/logs/cost.csv" ;;
    decisions) echo "$HARNESS/logs/decisions.log" ;;
    run_script) echo "$HARNESS/logs/run-script.log" ;;
    triage)
      [ "$project" = hub ] && return 1
      echo "$HARNESS/logs/$project.log" ;;
    *) return 1 ;;
  esac
}

if [ "${1:-}" = "--path" ]; then
  resolve "${2:-}" "${3:-}"
  exit $?
fi

PROJECT="${1:-}"; WHICH="${2:-}"; CID="${3:-}"

# Terminal beat for a request that will never produce a tail. The console pane
# is keyed on log:<cid>, and "the owning box is down" is exactly the moment
# someone is watching it — silence there is indistinguishable from a hung fetch.
if [ "$PROJECT" = "--error" ]; then
  shift; jq -nc --arg p "${1:-}" --arg w "${2:-}" --arg cid "${3:-}" --arg e "${4:-error}" \
    --arg ts "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
    '{kind:"log_tail",rkey:("log:"+$cid),command_id:$cid,project:$p,which:$w,
      content:"",truncated:false,missing:true,bytes:0,error:$e,ts:$ts}'
  exit 0
fi

JLOG="$HARNESS/logs/console-commands.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# Journal fields are sanitised, not quoted: these arrive from the console and a
# newline in one of them would let a caller forge whole journal lines.
jsafe() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9_.:/-' | head -c 64; }
journal() { mkdir -p "$HARNESS/logs"
  echo "$(STAMP) fetch_log id=$(jsafe "$CID") project=$(jsafe "$PROJECT") which=$(jsafe "$WHICH") -> $1" >> "$JLOG"; }

[ -n "$CID" ] || { journal "refused: no command id"; exit 1; }
F=$(resolve "$WHICH" "$PROJECT") || { journal "REFUSED: not a whitelisted log/project"; exit 1; }

# ── THE FILTER INPUTS (BH-10102), checked before any read ───────────────────
# They arrive from the console: never eval'd, never in a path, never in the
# journal (only filter=1). A bad one answers the --error envelope with
# error:"bad_<field>", rc 0, so the pane says why instead of hanging.
export LC_ALL=C
MATCH="${4:-}"; SINCE_IN="${5:-}"; UNTIL_IN="${6:-}"
# FETCH_LOG_NOW (epoch seconds) is a test seam: the "now" of 6h/24h inputs.
NOW_S="${FETCH_LOG_NOW:-}"; case "$NOW_S" in ''|*[!0-9]*) NOW_S=$(date -u +%s) ;; esac
refuse_input() { # <field>
  journal "REFUSED: bad $1"
  "$0" --error "$PROJECT" "$WHICH" "$CID" "bad_$1"
  exit 0
}
# norm_time <value> -> YYYY-MM-DDTHH:MM:SS (UTC) on stdout, rc 1 when refused
FL_REL_RE='^([0-9]{1,9})([smhd])$'
FL_ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?Z?)?$'
norm_time() {
  local v="$1" n u
  if [[ "$v" =~ $FL_REL_RE ]]; then
    n=$((10#${BASH_REMATCH[1]}))
    case "${BASH_REMATCH[2]}" in s) u=1 ;; m) u=60 ;; h) u=3600 ;; *) u=86400 ;; esac
    date -u -d "@$(( NOW_S - n * u ))" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null
    return
  fi
  [[ "$v" =~ $FL_ISO_RE ]] || return 1
  v=${v/T/ }; v=${v%Z}
  [ -n "$v" ] || return 1
  date -u -d "$v" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null
}
SINCE=""; UNTIL=""; MMODE=""; FL_RE=""
if [ -n "$MATCH" ]; then
  case "$MATCH" in *[![:print:]]*) refuse_input match ;; esac
  if [ "${#MATCH}" -ge 2 ] && [ "${MATCH:0:1}" = / ] && [ "${MATCH: -1}" = / ]; then
    # /.../ is an ERE, run by awk from ENVIRON (no escape processing). A
    # back-reference has no place in a line filter, and one that does not
    # compile is refused here rather than read as "no match".
    MMODE=E; FL_RE=${MATCH:1:${#MATCH}-2}
    FL_BACKREF_RE='\\[1-9]'
    [ -n "$FL_RE" ] || refuse_input match
    [[ "$FL_RE" =~ $FL_BACKREF_RE ]] && refuse_input match
    FL_RE="$FL_RE" awk 'BEGIN { if ("" ~ ENVIRON["FL_RE"]) {} }' </dev/null >/dev/null 2>&1 || refuse_input match
  else
    # A fixed string: awk index(), so a leading - or a ( is plain text.
    MMODE=F; FL_RE=$MATCH
  fi
fi
if [ -n "$SINCE_IN" ]; then SINCE=$(norm_time "$SINCE_IN") && [ -n "$SINCE" ] || refuse_input since; fi
if [ -n "$UNTIL_IN" ]; then UNTIL=$(norm_time "$UNTIL_IN") && [ -n "$UNTIL" ] || refuse_input until; fi
FILTER=0; [ -n "$MMODE$SINCE$UNTIL" ] && FILTER=1

# REHYDRATE THE DECISIONS LOG (BH-436). It is a hub artifact that the wipe on
# 2026-09-15 (#388) took with it, and an empty pane is indistinguishable from a
# quiet week. Here in the main flow rather than inside resolve(), which is the
# pure --path resolver the tests call and which runs in a $(...) subshell — so
# --path stays a path lookup and never touches the network. No request when the
# file is already on disk; an outage leaves missing:true exactly as today.
if [ "$WHICH" = decisions ] && [ -r "$HARNESS/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
  log_rehydrate decisions "$F" 30 >/dev/null 2>&1 || true
fi

SIZE=0; MISSING=true
if [ -f "$F" ]; then MISSING=false; SIZE=$(wc -c < "$F" | tr -dc '0-9'); fi
SIZE=${SIZE:-0}

WD=$(mktemp -d "${TMPDIR:-/tmp}/fetch-log.XXXXXX") || { journal "fetch failed: no temp dir"; exit 1; }
trap 'rm -rf "$WD"' EXIT
R="$WD/window"; K="$WD/window.keys"; RF="$WD/result"; KF="$WD/result.keys"; C="$WD/content"
: > "$R"; : > "$K"; : > "$RF"; : > "$KF"; : > "$C"

# A line's key: its leading stamp, normalized to YYYY-MM-DDTHH:MM:SS; a line
# with none takes the key of the line before it; before the first stamp the
# key is empty. One awk pass writes the kept lines (rf, filter only) and the
# key of every kept line (kf), 1:1.
KEYAWK='
function key(line,   t) {
  if (match(line, /^\[?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9](:[0-9][0-9])?/)) {
    t = substr(line, RSTART, RLENGTH); sub(/^\[/, "", t)
    t = substr(t, 1, 10) "T" substr(t, 12)
    if (length(t) == 16) t = t ":00"
    cur = t
  }
  return cur
}
{ k = key($0) }
filter && since != "" && (k == "" || k < since) { next }
filter && until != "" && k != "" && k >= until { next }
filter && mmode == "F" && index($0, ENVIRON["FL_RE"]) == 0 { next }
filter && mmode == "E" && $0 !~ ENVIRON["FL_RE"] { next }
{ if (filter) print > rf; print k > kf }'

# lines <file>: the newline count, plus a last line that has no newline.
lines() { local n; n=$(wc -l < "$1"); [ -s "$1" ] && [ "$(tail -c1 "$1" | od -An -tx1 | tr -d ' ')" != 0a ] && n=$((n+1)); echo "$n"; }
# tail_whole <file> <n> <size>: the whole lines inside the last n bytes.
tail_whole() {
  if [ "$2" -ge "$3" ]; then cat "$1"
  elif [ "$2" -le 0 ]; then :
  else tail -c "$(( $2 + 1 ))" "$1" | sed '1d'; fi
}

# snap <file> <n>: the last n bytes of the first $SIZE bytes of <file>. Every
# read of the log goes through the SIZE snapshot, so a line appended during
# the call (alert-line.sh writes ALERTS.log all the time) is in no read: the
# key pass, the window and the counts all see the same bytes.
snap() {
  local n=$2; [ "$n" -gt "$SIZE" ] && n=$SIZE
  [ "$n" -le 0 ] && return 0
  tail -c "+$(( SIZE - n + 1 ))" "$1" | head -c "$n"
}

MATCHED_BYTES=0; MATCHED_LINES=0; TOTAL_BYTES=0; TOTAL_LINES=0; WL=0; WCUT=false
if [ "$MISSING" = false ]; then
  head -c "$SIZE" "$F" | FL_RE="$FL_RE" awk -v filter="$FILTER" -v since="$SINCE" -v until="$UNTIL" -v mmode="$MMODE" \
    -v rf="$RF" -v kf="$KF" "$KEYAWK" 2>/dev/null \
    || { journal "fetch failed: read"; exit 1; }
  # The window: the newest TAIL_MAX bytes of the file (no filter) or of the
  # filtered result, whole lines only.
  if [ "$FILTER" = 1 ]; then
    MATCHED_BYTES=$(wc -c < "$RF"); MATCHED_LINES=$(lines "$RF")
    TOTAL_BYTES=$MATCHED_BYTES; TOTAL_LINES=$MATCHED_LINES
    tail_whole "$RF" "$TAIL_MAX" "$TOTAL_BYTES" > "$R"
    if [ ! -s "$R" ] && [ "$TOTAL_BYTES" -gt 0 ]; then
      # The newest line alone is larger than the window: its last bytes.
      tail -c "$TAIL_MAX" "$RF" > "$R"; WCUT=true
    fi
  else
    TOTAL_BYTES=$SIZE; TOTAL_LINES=$(lines "$KF")
    if [ "$TAIL_MAX" -ge "$SIZE" ]; then snap "$F" "$SIZE" > "$R"
    elif [ "$TAIL_MAX" -gt 0 ]; then snap "$F" $(( TAIL_MAX + 1 )) | sed '1d' > "$R"; fi
    if [ ! -s "$R" ] && [ "$TOTAL_BYTES" -gt 0 ]; then
      snap "$F" "$TAIL_MAX" > "$R"; WCUT=true
    fi
  fi
  WL=$(lines "$R")
  [ "$WL" -gt 0 ] && tail -n "$WL" "$KF" > "$K"
fi
WB=$(wc -c < "$R")
# The key of the line just before the window, when there is one.
PREVKEY=""; HASPREV=0
if [ "$TOTAL_LINES" -gt "$WL" ]; then HASPREV=1; PREVKEY=$(sed -n "$(( TOTAL_LINES - WL ))p" "$KF"); fi

TS=$(STAMP)
# beat — the beat JSON for the current $C and counts. jq does the string
# encoding: quotes, backslashes, newlines and tabs all live in real log lines.
beat() {
  jq -nc --rawfile c "$C" --arg cid "$CID" --arg p "$PROJECT" --arg w "$WHICH" \
    --argjson t "$TRUNC" --argjson m "$MISSING" --argjson b "$SIZE" --arg ts "$TS" \
    --arg fm "$MATCH" --arg fs "$SINCE" --arg fu "$UNTIL" --argjson filt "$FILTER" \
    --argjson wb "$WB" --argjson mb "$MATCHED_BYTES" --argjson ml "$MATCHED_LINES" \
    --argjson rb "$RET_B" --argjson rl "$RET_L" --argjson ob "$OMIT_B" --argjson ol "$OMIT_L" \
    --argjson rmax "$RESP_MAX" --argjson tmax "$TAIL_MAX" --argjson lc "$LINE_CUT" --argjson bs "$BSPLIT" \
    --arg mu "$FIRSTKEY" --arg note "$NOTE" '
    def n: if . == "" then null else . end;
    {kind:"log_tail",rkey:("log:"+$cid),command_id:$cid,project:$p,which:$w,
     content:$c,truncated:$t,missing:$m,bytes:$b,ts:$ts,
     filter:{match:($fm|n),since:($fs|n),until:($fu|n)},
     window_bytes:$wb,
     matched_bytes:(if $filt == 1 then $mb else null end),
     matched_lines:(if $filt == 1 then $ml else null end),
     returned_bytes:$rb,returned_lines:$rl,omitted_bytes:$ob,omitted_lines:$ol,
     response_max_bytes:$rmax,tail_max_bytes:$tmax,line_cut:$lc,boundary_split:$bs,
     more:(if $ob == 0 then null else
       {which:$w,project:$p,match:($fm|n),since:($fs|n),until:($mu|n),note:$note} end)}'
}

# THE RESPONSE FIT: the newest whole lines whose ENCODED beat is at most
# RESP_MAX bytes. N strictly falls each round, so the loop ends; at N = 0 the
# content is empty and the counts still say what was left out.
N=$WB; [ "$N" -gt "$RESP_MAX" ] && N=$RESP_MAX
while :; do
  LINE_CUT=$WCUT; BSPLIT=false; FIRSTKEY=""
  tail_whole "$R" "$N" "$WB" > "$C"
  if [ ! -s "$C" ] && [ "$N" -gt 0 ] && [ "$WB" -gt 0 ]; then
    # The newest line alone is larger than N: ship its last N bytes.
    tail -c "$N" "$R" > "$C"; LINE_CUT=true
  fi
  RET_L=$(lines "$C"); RET_B=$(wc -c < "$C"); I=$(( WL - RET_L + 1 ))
  if [ $(( TOTAL_BYTES - RET_B )) -gt 0 ] && [ "$RET_L" -gt 0 ]; then
    FIRSTKEY=$(sed -n "${I}p" "$K")
    if [ "$I" -gt 1 ]; then LASTLEFT=$(sed -n "$(( I - 1 ))p" "$K"); HASLEFT=1
    else LASTLEFT=$PREVKEY; HASLEFT=$HASPREV; fi
    # THE TIME BOUNDARY: when the last left-out line and the first returned
    # line share a second, the returned lines of that second move to the
    # left-out side, so `until` (exclusive) reaches every left-out line. When
    # the whole returned part is that one second, nothing moves: boundary_split.
    if [ "$HASLEFT" = 1 ] && [ -n "$FIRSTKEY" ] && [ "$LASTLEFT" = "$FIRSTKEY" ]; then
      J=$(tail -n "+$I" "$K" | awk -v k="$FIRSTKEY" '$0 != k { exit } { c++ } END { print c + 0 }')
      if [ "$J" -ge "$RET_L" ]; then BSPLIT=true
      else
        tail -n "+$(( J + 1 ))" "$C" > "$C.m" && mv "$C.m" "$C"
        RET_L=$(( RET_L - J )); RET_B=$(wc -c < "$C")
        FIRSTKEY=$(sed -n "$(( I + J ))p" "$K")
      fi
    fi
  fi
  OMIT_B=$(( TOTAL_BYTES - RET_B )); OMIT_L=$(( TOTAL_LINES - RET_L ))
  TRUNC=false; [ "$OMIT_B" -gt 0 ] && TRUNC=true
  if [ -z "$FIRSTKEY" ]; then
    NOTE="no timestamp on the first returned line: the left-out lines are older than it and cannot be addressed by time"
  elif [ "$BSPLIT" = true ]; then
    NOTE="call fetch_log with these arguments for the left-out lines; the returned part is all one second, so left-out lines stamped at until itself are not reachable by time"
  else
    NOTE="call fetch_log with these arguments for the left-out lines (until is exclusive; a line stamped out of order, later than until, is not reachable by time)"
  fi
  OUT=$(beat) || { journal "fetch failed: beat encode"; exit 1; }
  LEN=${#OUT}
  [ "$LEN" -le "$RESP_MAX" ] && break
  [ "$N" -le 0 ] && break
  N=$(( N * RESP_MAX / LEN - 1 )); [ "$N" -lt 0 ] && N=0
done

printf '%s\n' "$OUT"
journal "ok ${SIZE}b truncated=$TRUNC missing=$MISSING returned=${RET_B}b omitted=${OMIT_B}b filter=$FILTER"
exit 0
