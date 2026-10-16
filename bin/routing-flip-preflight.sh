#!/bin/bash
# bin/routing-flip-preflight.sh — BH-1627: the checklist the `routing_rows` flip
# waits on (BH-1027). Run it on the hub (and on any box that holds flags/) right
# before the flip. It prints one [PASS]/[FAIL] line per check, and it exits 0
# only when every check passes.
#
#   1  no orphan flags/fly-pool-<p> (no builder-fly-<p>). routing_builder says
#      "pool" only when BOTH files exist (caps_route's test).
#   2  no EMPTY flags/fly-pool-app-<p>. Every client reader treats it as "no pool", and
#      bin/fly-pool.sh spawns nothing for it.
#   3  the installed client reads routing at most once per process (the BH-1627
#      memo), so a resolver tick costs one GET /api/routing, not one per PR.
#   4  the live probe (the BH-1000 rule): GET /api/routing on the deployed worker
#      answers 200 with an array, and no row disagrees with this box's files. A
#      row that disagrees would re-route that project at the flip.
#   5  every fleet project has a row (bin/routing-seed-rows.sh writes them from
#      the files). An empty table would make the flip a silent no-op.
#
# STRICTLY READ-ONLY. GETs only, never a PUT, and nothing under $HARNESS is
# written. The routing readers are never called, because they sync, and a sync
# writes flags/. ROUTING_ROWS=off pins that even if a sourced helper tried.
# JOBS_ALERT=0 keeps a failed probe from touching flags/alerted-jobs-client-<day>,
# and the client's log line goes to stderr instead of logs/jobs-client.log. The
# only file it creates is its own mktemp under $TMPDIR, removed on exit.
#
# Usage: HARNESS=/root/harness bin/routing-flip-preflight.sh
# Exit:  0 ready to flip, 1 a check failed, 2 no jobs client on this box.
set -uo pipefail
H="${HARNESS:-/root/harness}"
F="$H/flags"
export ROUTING_ROWS=off JOBS_ALERT=0
# shellcheck source=/dev/null
{ [ -r "$H/bin/jobs-client.sh" ] && [ -d "$H/bin/lib/jobs" ] && . "$H/bin/jobs-client.sh"; } \
  || { echo "routing-flip-preflight: no jobs client under $H/bin — cannot probe"; exit 2; }
command -v routing_rows_on >/dev/null 2>&1 || { echo "routing-flip-preflight: the client has no routing module"; exit 2; }
# The client's own log line goes to stderr, not to logs/jobs-client.log.
_jobs_log() { printf 'routing-flip-preflight: jobs-client: %s\n' "$*" >&2; }

FAILS=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; FAILS=$((FAILS+1)); }
suffixes() { # suffixes <prefix> -> the <p> of every flags/<prefix><p> file
  local f; for f in "$F/$1"*; do [ -f "$f" ] && printf '%s\n' "${f##*/"$1"}"; done; return 0
}

echo "routing_rows flip preflight — box ${JOBS_BOX:-?}, flags $F"
# Not in $(...): JOBS_HTTP / JOBS_BODY must survive into this shell for the report.
RF=$(mktemp "${TMPDIR:-/tmp}/routing-flip.XXXXXX") || { echo "routing-flip-preflight: mktemp failed"; exit 2; }
trap 'rm -f -- "$RF"' EXIT
# The raw GET rather than setting_get, whose own $(...) would drop JOBS_HTTP.
if _jobs_req GET /api/settings/routing_rows > "$RF"; then KNOB=$(jq -r '.setting.value // "unset (no row)"' "$RF" 2>/dev/null)
else KNOB="unknown (http=${JOBS_HTTP:-none})"; fi
echo "knob: routing_rows=$KNOB"

# 1. orphan fly-pool-<p>
ORPH=""
for p in $(suffixes fly-pool-); do
  case "$p" in app-*) continue ;; esac
  [ -f "$F/builder-fly-$p" ] || ORPH="$ORPH fly-pool-$p"
done
if [ -z "$ORPH" ]; then pass "1 orphan fly-pool files: none"
else fail "1 orphan fly-pool files (no builder-fly-<p>, so routing_builder says NOT pool):$ORPH"; fi

# 2. empty fly-pool-app-<p>
EMPTY=""
for p in $(suffixes fly-pool-app-); do [ -s "$F/fly-pool-app-$p" ] || EMPTY="$EMPTY fly-pool-app-$p"; done
if [ -z "$EMPTY" ]; then pass "2 empty fly-pool-app files: none"
else fail "2 empty fly-pool-app files (no pool anywhere; fly-pool.sh refuses to spawn):$EMPTY"; fi

# 3. the per-process routing read budget
SA=$(declare -f routing_sync_all); SO=$(declare -f routing_sync)
if [[ "$SA" == *_ROUTING_ALL_RC* ]] && [[ "$SO" == *_routing_memo_get* ]]; then
  pass "3 request budget: at most 1 GET /api/routing per process (per project without a sync_all); blocked-resolver syncs once per tick = 6/h, 144/day"
else
  fail "3 request budget: the installed client has no per-process routing memo — deploy BH-1627 to this box first (each reader call would send its own GET)"
fi

# 4. the live probe, then row-vs-file drift
_jobs_req GET /api/routing > "$RF"; RC=$?
RESP=$(cat "$RF")
if [ "$RC" -ne 0 ] || ! printf '%s' "$RESP" | jq -e '.routing | type == "array"' >/dev/null 2>&1; then
  fail "4 live probe: GET ${JOBS_URL}/api/routing rc=$RC http=${JOBS_HTTP:-none} $(head -c 120 < <(printf '%s' "${JOBS_BODY:-}"))"
else
  N=$(printf '%s' "$RESP" | jq '.routing | length')
  pass "4 live probe: GET ${JOBS_URL}/api/routing http=${JOBS_HTTP} rows=$N as_of=$(printf '%s' "$RESP" | jq -r '.as_of // "-"')"
  # `|`, not a tab: read collapses adjacent whitespace separators, so an empty
  # pool_app would shift `halted` into its place.
  DRIFT=$(printf '%s' "$RESP" | jq -r '.routing[] | [.project, .builder, (.pool_app // ""), (if .halted == 1 or .halted == true then 1 else 0 end | tostring)] | join("|")' 2>/dev/null \
    | while IFS='|' read -r p b a h; do
        [ -n "$p" ] || continue
        _routing_name_ok "$p" || { echo "$p: unusable project name"; continue; }
        routing_row_drift "$p" "$b" "$a" "$h"
      done | paste -sd';' -)
  if [ -z "$DRIFT" ]; then pass "4 row drift: none — the flip changes no file on this box"
  else fail "4 row drift (the flip would re-route): $DRIFT"; fi
  # Projects the files route that have no row keep file routing after the flip.
  ROW_SET=" $(printf '%s' "$RESP" | jq -r '[.routing[].project] | join(" ")') "
  FILEONLY=""
  for p in $(suffixes builder-fly-); do case "$ROW_SET" in *" $p "*) ;; *) FILEONLY="$FILEONLY $p" ;; esac; done
  [ -z "$FILEONLY" ] || echo "note: routed by files with no row:$FILEONLY"
  # 5. one row per fleet project. The table was empty at the 2026-09-24 probe:
  #    flipped like that, every row read is a 404 and the files alone keep
  #    routing, so the flip would do nothing. bin/routing-seed-rows.sh --apply
  #    writes the rows from these files first.
  MISSING=""
  for p in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
    case "$ROW_SET" in *" $p "*) ;; *) MISSING="$MISSING $p" ;; esac
  done
  NP=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null | grep -c .)
  if [ "${NP:-0}" = 0 ]; then fail "5 one row per fleet project: fleet-conf.sh --projects listed nothing"
  elif [ -z "$MISSING" ]; then pass "5 one row per fleet project: $NP/$NP"
  else fail "5 one row per fleet project: missing$MISSING — seed first: HARNESS=$H $H/bin/routing-seed-rows.sh --apply"; fi
fi

if [ "$FAILS" = 0 ]; then
  echo "RESULT: READY — flip:     HARNESS=$H $H/bin/jobs-client.sh setting-set routing_rows on"
  echo "                 rollback: HARNESS=$H $H/bin/jobs-client.sh setting-set routing_rows off"
  echo "        (no note: the row keeps its description. Read once per process, so each lane picks the value up on its next start)"
  exit 0
fi
echo "RESULT: NOT READY — $FAILS check(s) failed; the knob stays as it is"
exit 1
