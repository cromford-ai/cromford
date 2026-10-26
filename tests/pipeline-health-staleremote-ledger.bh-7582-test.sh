#!/bin/bash
# tests/pipeline-health-staleremote-ledger.bh-7582-test.sh — BH-7582. The
# staleremote section of bin/pipeline-health.sh, extracted VERBATIM between
# `# >>> staleremote` and `# <<< staleremote`, driven with the REAL
# bin/lib/remote-results-ledger.sh, a recording alert() and a stubbed jobs
# ledger (_jobs_req answers from per-key fixture files and records each call).
#
# THE BUG THIS PINS. A hub backup json state/remote-results/<p>/<KEY>.json was
# skipped only when a build folder beside it held RELAYED. A pruned folder took
# the marker with it, and 3,057 jsons of finished builds paged
# "unconsumed >30m" every 2 hours (711 staleremote lines in ALERTS.log on
# 2026-10-19). Now a json with no folder asks the ledger: terminal is no page,
# no row is a page (a real lost result), unreadable is no page and one count.
# The block writes nothing under state/remote-results: its cache and its stamp
# live in state/remote-results-terminal/ (a cache-class path).
#
#   G1      the lane sources the lib; the block asks the ledger
#   L1-L20  rr_build_state, the decision table
#   S1-S12  the block: alerts, alert key, ledger calls, summary line, cap, stamp
#   M1      a mutant lib (terminal read as open) turns S2 red
#
# Run from anywhere: tests/pipeline-health-staleremote-ledger.bh-7582-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/remote-results-ledger.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }
awk '/^# >>> staleremote/{f=1;next} /^# <<< staleremote/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/sr.sh"
[ -s "$T/sr.sh" ] && ok || { echo "FAIL: could not extract the staleremote block — markers missing?"; exit 1; }
# ── G1: the lane sources the lib (a non-comment line); the block asks it ─────
grep -q 'rr_build_state' "$T/sr.sh" && ok || bad "G1 the extracted block never asks the ledger (no rr_build_state)"
grep -qE '^[^#]*\. "\$H/bin/lib/remote-results-ledger\.sh"' "$DIR/bin/pipeline-health.sh" \
  && ok || bad "G1 bin/pipeline-health.sh does not source bin/lib/remote-results-ledger.sh"

NOW=1760000000   # pinned clock (D60)
P=ts
SRD="$T/state/remote-results/$P"
TCD="$T/state/remote-results-terminal"
mkdir -p "$T/logs" "$T/bin" "$T/ledger"
# The retention verb, as a recorder: S12 counts how often the block runs it.
printf '#!/bin/bash\necho "$*" >> "%s/ret-calls.txt"\nexit 0\n' "$T" > "$T/bin/remote-results-retention.sh"
chmod +x "$T/bin/remote-results-retention.sh"

reset() {
  scratch_rm "$T/state"; scratch_rm "$T/builds"; scratch_rm "$T/ledger"
  mkdir -p "$SRD" "$T/builds" "$T/ledger"
  : > "$T/alerts.txt"; : > "$T/calls.txt"; : > "$T/logs/pipeline-health.log"; : > "$T/ret-calls.txt"
}
# mkjson <key> <age-seconds>
mkjson() { printf '{"key":"%s"}\n' "$1" > "$SRD/$1.json"; touch -d "@$((NOW - $2))" "$SRD/$1.json"; }
# ledger <key> <body> [rc] — what _jobs_req answers for this key.
ledger() { printf '%s' "$2" > "$T/ledger/$1"; [ -n "${3:-}" ] && printf '%s' "$3" > "$T/ledger/$1.rc"; return 0; }
# row <key> <status> <meta> [kind] [project] — a one-row jobs body, the shape
# GET /api/jobs answers (worker/jobs/src/routes/jobs.js).
row() {
  jq -nc --arg k "$1" --arg s "$2" --arg m "$3" --arg kind "${4:-build}" --arg p "${5:-ts}" \
    '{jobs:[{id:"job-fixture-1",project:$p,ticket_id:$k,kind:$kind,status:$s,meta:$m}],as_of:"x"}'
}

STUBS='
_jobs_req() {
  echo "$2" >> "$T/calls.txt"
  local k; k=$(printf "%s" "$2" | sed -n "s/.*ticket_id=\([^&]*\).*/\1/p")
  [ -f "$T/ledger/$k.rc" ] && return "$(cat "$T/ledger/$k.rc")"
  if [ -f "$T/ledger/$k" ]; then cat "$T/ledger/$k"; else printf "{\"jobs\":[]}"; fi
}'

# drive [lib] [VAR=VAL ...] — run the extracted block once.
drive() {
  local lib="$LIB"
  case "${1:-}" in /*) lib="$1"; shift ;; esac
  ( export T NOW_PIN="$NOW" LIBF="$lib" STUBS
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW="$NOW_PIN"; PROJECTS="ts"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      [ "${NOJOBS:-0}" = 1 ] || eval "$STUBS"
      . "$LIBF"
      . "$0"' "$T/sr.sh" 2>>"$T/err.txt" )
}
nalerts() { grep -c . "$T/alerts.txt"; }
ncalls()  { grep -c . "$T/calls.txt"; }
listing() { (cd "$SRD" && ls -A | LC_ALL=C sort); }

# lstate <body> [rc] — "<word> <rc>" from rr_build_state for key TK-12.
lstate() {
  reset; ledger TK-12 "$1" "${2:-}"
  ( export T STUBS; bash -c '
      eval "$STUBS"; . "'"$LIB"'"
      w=$(rr_build_state ts TK-12); rc=$?; echo "${w:--} $rc"' )
}
# ── L1-L20: the decision table ───────────────────────────────────────────────
[ "$(lstate "$(row TK-12 done 'PR_MERGED https://x.example/pr/1')")" = "terminal 0" ] && ok || bad "L1 done -> terminal"
[ "$(lstate "$(row TK-12 failed 'REVIEW_BLOCKED fixture')")" = "terminal 0" ] && ok || bad "L2 failed -> terminal"
[ "$(lstate "$(row TK-12 abandoned '')")" = "terminal 0" ] && ok || bad "L3 abandoned -> terminal"
[ "$(lstate "$(row TK-12 budget_stopped '')")" = "terminal 0" ] && ok || bad "L4 budget_stopped -> terminal"
[ "$(lstate "$(row TK-12 parked 'PLAN_BLOCKED needs an answer')")" = "terminal 0" ] && ok || bad "L5 parked PLAN_BLOCKED -> terminal"
[ "$(lstate "$(row TK-12 parked '{"result":"PR_MERGED https://x.example/pr/2","pr_url":null}')")" = "terminal 0" ] && ok || bad "L6 parked JSON meta PR_MERGED -> terminal"
[ "$(lstate "$(row TK-12 parked 'DECOMPOSED 3 children')")" = "terminal 0" ] && ok || bad "L7 parked DECOMPOSED -> terminal"
for r in PR_CREATED PR_CLOSED PLAN_MALFORMED PLAN_STALE EXECUTE_EMPTY REVIEW_BLOCKED; do
  [ "$(lstate "$(row TK-12 parked "$r fixture")")" = "terminal 0" ] && ok || bad "L8 parked $r -> terminal"
done
[ "$(lstate "$(row TK-12 parked 'QUEUED_FLY pool')")" = "open 0" ] && ok || bad "L9 parked QUEUED_FLY -> open (near miss)"
[ "$(lstate "$(row TK-12 parked 'BUILD_DEFERRED slots')")" = "open 0" ] && ok || bad "L10 parked BUILD_DEFERRED -> open (near miss)"
[ "$(lstate "$(row TK-12 parked 'XPLAN_BLOCKED fixture')")" = "open 0" ] && ok || bad "L11 parked XPLAN_BLOCKED -> open (prefix must anchor)"
[ "$(lstate "$(row TK-12 parked '{"result":"not PR_MERGED"}')")" = "open 0" ] && ok || bad "L12 parked meta 'not PR_MERGED' -> open"
for s in running queued_for_retry orphaned weird; do
  [ "$(lstate "$(row TK-12 "$s" '')")" = "open 0" ] && ok || bad "L13 $s -> open"
done
[ "$(lstate '{"jobs":[]}')" = "absent 0" ] && ok || bad "L14 no row -> absent"
[ "$(lstate "$(row TK-123 done 'PR_MERGED x')")" = "- 1" ] && ok || bad "L15 a row about TK-123 when TK-12 was asked -> unknown rc 1"
[ "$(lstate "$(row TK-12 done 'PR_MERGED x' review)")" = "- 1" ] && ok || bad "L16 a kind=review row -> unknown rc 1"
[ "$(lstate "$(row TK-12 done 'PR_MERGED x' build other-os)")" = "- 1" ] && ok || bad "L17 a row of another project -> unknown rc 1"
[ "$(lstate '' 1)" = "- 1" ] && ok || bad "L18 _jobs_req rc 1 -> unknown rc 1"
[ "$(lstate 'not json')" = "- 1" ] && ok || bad "L19 non-JSON body -> unknown rc 1"
[ "$(lstate '{"error":"x"}')" = "- 1" ] && ok || bad "L19 no jobs array -> unknown rc 1"
L20=$(bash -c '. "'"$LIB"'"; w=$(rr_build_state ts TK-12); echo "${w:--} $?"')
[ "$L20" = "- 3" ] && ok || bad "L20 no _jobs_req -> rc 3 (got $L20)"

# ── S1: RELAYED sibling -> no alert, no ledger call ──────────────────────────
reset; mkjson TK-5 7200; mkdir -p "$T/builds/pool-ts-TK-5-202610190000"; : > "$T/builds/pool-ts-TK-5-202610190000/RELAYED"
drive
[ "$(nalerts)" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "S1 RELAYED: alerts=$(nalerts) calls=$(ncalls)"

# ── S2: no folder, terminal row -> no alert, cached under the cache path ────
reset; mkjson TK-1 7200; ledger TK-1 "$(row TK-1 done 'PR_MERGED https://x.example/pr/1')"
drive
[ "$(nalerts)" = 0 ] && ok || bad "S2 terminal row paged: $(cat "$T/alerts.txt")"
[ "$(ncalls)" = 1 ] && ok || bad "S2 want 1 ledger call, got $(ncalls)"
grep -q "^TK-1	$((NOW-7200))	0\$" "$TCD/ts.tsv" 2>/dev/null && ok || bad "S2 terminal answer not cached in state/remote-results-terminal/ts.tsv"

# ── S3: no folder, no row -> one alert, today's key and text ────────────────
reset; mkjson TK-2 7200
drive
[ "$(nalerts)" = 1 ] && ok || bad "S3 want 1 alert, got $(nalerts)"
grep -q '^7200|staleremote:ts:TK-2.json|ts remote-result TK-2.json unconsumed >30m' "$T/alerts.txt" && ok || bad "S3 alert key/text: $(cat "$T/alerts.txt")"
[ -s "$T/logs/pipeline-health.log" ] && bad "S3 wrote a summary line with nothing to count" || ok
# an open row pages too
reset; mkjson TK-2 7200; ledger TK-2 "$(row TK-2 parked 'QUEUED_FLY pool')"
drive
[ "$(nalerts)" = 1 ] && ok || bad "S3 open row: want 1 alert, got $(nalerts)"

# ── S4: unreadable ledger -> no alert, one summary line with the count ──────
reset; mkjson TK-3 7200; ledger TK-3 '' 1
drive
[ "$(nalerts)" = 0 ] && ok || bad "S4 unreadable ledger paged: $(cat "$T/alerts.txt")"
[ "$(grep -c 'staleremote:' "$T/logs/pipeline-health.log")" = 1 ] && ok || bad "S4 want exactly 1 summary line: $(cat "$T/logs/pipeline-health.log")"
grep -q 'unknown 1 (not paged, ledger unreadable)' "$T/logs/pipeline-health.log" && ok || bad "S4 summary does not count 1 unknown"
[ -s "$TCD/ts.tsv" ] && bad "S4 cached an unknown answer" || ok

# ── S5: folder present, no RELAYED -> alert, no ledger call ─────────────────
reset; mkjson TK-6 7200; mkdir -p "$T/builds/ts-TK-6-202610190000"; ledger TK-6 "$(row TK-6 done 'PR_MERGED x')"
drive
[ "$(nalerts)" = 1 ] && [ "$(ncalls)" = 0 ] && ok || bad "S5 folder present: alerts=$(nalerts) calls=$(ncalls)"

# ── S6: age 1799 s -> not evaluated; 1801 s -> evaluated ───────────────────
reset; mkjson TK-7 1799
drive
[ "$(nalerts)" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "S6 1799 s: alerts=$(nalerts) calls=$(ncalls)"
reset; mkjson TK-7 1801
drive
[ "$(nalerts)" = 1 ] && [ "$(ncalls)" = 1 ] && ok || bad "S6 1801 s: alerts=$(nalerts) calls=$(ncalls)"

# ── S7: the cache — a second run costs 0 reads; a new mtime is asked again ──
reset; mkjson TK-8 7200; ledger TK-8 "$(row TK-8 done 'PR_MERGED x')"
drive
: > "$T/calls.txt"; : > "$T/logs/pipeline-health.log"
drive
[ "$(nalerts)" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "S7 cache hit: alerts=$(nalerts) calls=$(ncalls)"
grep -q 'ledger-terminal 0, cached 1,' "$T/logs/pipeline-health.log" && ok || bad "S7 summary does not count the cache hit"
touch -d "@$((NOW - 3600))" "$SRD/TK-8.json"; ledger TK-8 '{"jobs":[]}'
drive
[ "$(ncalls)" = 1 ] && [ "$(nalerts)" = 1 ] && ok || bad "S7 a new mtime must be asked again (no row -> page): calls=$(ncalls) alerts=$(nalerts)"

# ── S8: no jobs client -> pages as before ───────────────────────────────────
reset; mkjson TK-13 7200
drive NOJOBS=1
[ "$(nalerts)" = 1 ] && ok || bad "S8 no jobs client: want 1 alert, got $(nalerts)"

# ── S9 + S10: read cap -> deferred, not paged; the summary line ─────────────
reset
for k in TK-10 TK-11 TK-12; do mkjson "$k" 7200; ledger "$k" "$(row "$k" done 'PR_MERGED x')"; done
drive STALEREMOTE_LEDGER_READS=1
[ "$(ncalls)" = 1 ] && ok || bad "S9 want 1 call under cap 1, got $(ncalls)"
[ "$(nalerts)" = 0 ] && ok || bad "S9 a deferred json paged: $(cat "$T/alerts.txt")"
grep -qx 'TS ts staleremote: ledger-terminal 1, cached 0, unknown 0 (not paged, ledger unreadable), deferred 2 (read cap 1)' \
  "$T/logs/pipeline-health.log" && ok || bad "S10 summary line: $(cat "$T/logs/pipeline-health.log")"

# ── S11: nothing written under state/remote-results ─────────────────────────
reset; mkjson TK-1 7200; ledger TK-1 "$(row TK-1 done 'PR_MERGED x')"
mkjson TK-2 7200; mkjson TK-3 7200; ledger TK-3 '' 1
BEFORE=$(listing; find "$T/state/remote-results" -printf '%P %s %T@\n' | LC_ALL=C sort)
drive; drive
AFTER=$(listing; find "$T/state/remote-results" -printf '%P %s %T@\n' | LC_ALL=C sort)
[ "$BEFORE" = "$AFTER" ] && ok || bad "S11 the block wrote under state/remote-results: $(diff <(echo "$BEFORE") <(echo "$AFTER"))"

# ── S12: the retention call runs once per stamp window ──────────────────────
reset; mkjson TK-9 7200; ledger TK-9 "$(row TK-9 done 'PR_MERGED x')"
drive; drive
[ "$(grep -c . "$T/ret-calls.txt")" = 1 ] && ok || bad "S12 retention ran $(grep -c . "$T/ret-calls.txt") times inside one window"
grep -qx -- '--project ts' "$T/ret-calls.txt" && ok || bad "S12 retention args: $(cat "$T/ret-calls.txt")"
[ -f "$TCD/ts.stamp" ] && ok || bad "S12 no stamp at state/remote-results-terminal/ts.stamp"
touch -d "@$((NOW - 3601))" "$TCD/ts.stamp"
drive
[ "$(grep -c . "$T/ret-calls.txt")" = 2 ] && ok || bad "S12 retention did not run again after the stamp aged"

# ── M1: the suite catches a lib that reads terminal as open ─────────────────
sed 's/then "terminal"/then "open"/g' "$LIB" > "$T/mutant-lib.sh"
cmp -s "$LIB" "$T/mutant-lib.sh" && bad "M1 the mutation changed nothing"
reset; mkjson TK-1 7200; ledger TK-1 "$(row TK-1 done 'PR_MERGED https://x.example/pr/1')"
drive "$T/mutant-lib.sh"
[ "$(nalerts)" = 1 ] && ok || bad "M1 S2 stayed green on the mutant lib (alerts=$(nalerts))"

[ -s "$T/err.txt" ] && grep -v '^$' "$T/err.txt" | head -5 | sed 's/^/stderr: /'
echo "pipeline-health-staleremote-ledger.bh-7582: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
