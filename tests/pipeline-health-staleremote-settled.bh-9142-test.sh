#!/bin/bash
# tests/pipeline-health-staleremote-settled.bh-9142-test.sh — BH-9142. The
# staleremote section of bin/pipeline-health.sh, extracted VERBATIM between
# `# >>> staleremote` and `# <<< staleremote`, driven with the REAL
# bin/lib/remote-results-ledger.sh, a recording alert(), a recording
# _jobs_req stub, a recording rrr_consumed stub that answers "no row" and a
# gh stub that records and fails.
#
# THE BUG THIS PINS. project-6-os TK-832..TK-860 hub jsons, 3 weeks old, paged
# "unconsumed >30m" every 2 hours. TK-860.json records
# `PR_CREATED https://github.com/example-org/project-6/pull/877`: the record
# itself proves the PR exists. The build folder was still present with no
# RELAYED, so the block paged on file presence and mtime alone. Now a json
# whose result line names a GitHub pull and is older than
# STALEREMOTE_PR_SETTLED_DAYS, or that the retention rule retired, does not
# page, and costs no ledger read.
#
#   L1-L16  rr_json_pr_settled, the decision table
#   S1-S13  the block: alerts, reads, summary lines, the knob
#   K1      the knob row and its fallback comment
#   M1      a mutant lib (rr_json_pr_settled always rc 1) turns S1 red
#
# Run from anywhere: tests/pipeline-health-staleremote-settled.bh-9142-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/remote-results-ledger.sh"
KNOB="$DIR/catalog/lanes.d/pipeline-health.knobs.d/STALEREMOTE_PR_SETTLED_DAYS.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }
awk '/^# >>> staleremote/{f=1;next} /^# <<< staleremote/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/sr.sh"
[ -s "$T/sr.sh" ] && ok || { echo "FAIL: could not extract the staleremote block — markers missing?"; exit 1; }

NOW=1760000000   # pinned clock (D60)
DAY=86400
P=mk
SRD="$T/state/remote-results/$P"
TCD="$T/state/remote-results-terminal"
mkdir -p "$T/logs" "$T/bin"

reset() {
  scratch_rm "$T/state"; scratch_rm "$T/builds"
  mkdir -p "$SRD" "$T/builds"
  : > "$T/alerts.txt"; : > "$T/calls.txt"; : > "$T/rrc.txt"; : > "$T/gh.txt"
  : > "$T/logs/pipeline-health.log"
}
# mkjson <key> <age-seconds> [result] — the shape fly-pool writes
# (config/fly-pool.d/3400-pool-listing-and-reap.sh). No result arg = no field.
mkjson() {
  if [ "$#" -ge 3 ]; then
    jq -nc --arg k "$1" --arg r "$3" --arg d "$T/builds/pool-$P-$1-202610160452" \
      '{key:$k,ticket_id:$k,build_dir:$d,result:$r,machine_build_dir:"/root/harness/builds/x"}' > "$SRD/$1.json"
  else
    printf '{"key":"%s"}\n' "$1" > "$SRD/$1.json"
  fi
  touch -d "@$((NOW - $2))" "$SRD/$1.json"
}
folder() { mkdir -p "$T/builds/pool-$P-$1-202610160452"; }
PRC='PR_CREATED https://github.com/example-org/project-6/pull/877'

STUBS='
_jobs_req() { echo "$2" >> "$T/calls.txt"; printf "{\"jobs\":[]}"; }
rrr_consumed() { echo "$2" >> "$T/rrc.txt"; return 1; }
gh() { echo "$*" >> "$T/gh.txt"; return 1; }'

# drive [lib] [VAR=VAL ...] — run the extracted block once.
drive() {
  local lib="$LIB"
  case "${1:-}" in /*) lib="$1"; shift ;; esac
  ( export T NOW_PIN="$NOW" LIBF="$lib" STUBS
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW="$NOW_PIN"; PROJECTS="mk"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      eval "$STUBS"
      . "$LIBF"
      . "$0"' "$T/sr.sh" 2>>"$T/err.txt" )
}
nalerts() { grep -c . "$T/alerts.txt"; }
ncalls()  { grep -c . "$T/calls.txt"; }
nrrc()    { grep -c . "$T/rrc.txt"; }
ngh()     { grep -c . "$T/gh.txt"; }

# settled <age-s> <window-s> [result] — rc of rr_json_pr_settled on a fresh json.
settled() {
  reset
  if [ "$#" -ge 3 ]; then mkjson TK-1 "$1" "$3"; else mkjson TK-1 "$1"; fi
  bash -c '. "'"$LIB"'"; command -v rr_json_pr_settled >/dev/null || exit 9
    rr_json_pr_settled "$1" "$2" "$3" "$4"' _ "$SRD/TK-1.json" "$((NOW - $1))" "$NOW" "$2"
}
W=$((7*DAY))
# ── L1-L16: the decision table ───────────────────────────────────────────────
settled $((21*DAY)) $W "$PRC";                                         [ $? = 0 ] && ok || bad "L1 PR_CREATED pull url, 21d, window 7d -> settled"
settled $((8*DAY)) $W $'PR_MERGED https://github.com/o/r/pull/12\nBUILD_DIR: x'; [ $? = 0 ] && ok || bad "L2 multi-line PR_MERGED, 8d -> settled"
settled $((W+1)) $W 'PR_CLOSED https://github.com/o/r/pull/3';          [ $? = 0 ] && ok || bad "L3 PR_CLOSED at window+1 s -> settled"
settled $((21*DAY)) $W 'PR_CREATED https://github.com/o/r/pull/9 (draft)'; [ $? = 0 ] && ok || bad "L4 trailing text after a space -> settled"
settled $((6*DAY)) $W "$PRC";                                          [ $? = 1 ] && ok || bad "L5 6d (younger than the window) -> not settled"
settled $W $W "$PRC";                                                  [ $? = 1 ] && ok || bad "L6 age exactly the window -> not settled"
settled $((21*DAY)) $W 'PR_CREATED';                                   [ $? = 1 ] && ok || bad "L7 PR_CREATED with no url -> not settled"
settled $((21*DAY)) $W 'PR_CREATED https://github.com/o/r/issues/5';    [ $? = 1 ] && ok || bad "L8 an issue url -> not settled"
settled $((21*DAY)) $W 'PR_CREATE_FAILED: gh error';                   [ $? = 1 ] && ok || bad "L9 PR_CREATE_FAILED -> not settled"
settled $((21*DAY)) $W ' PR_CREATED https://github.com/o/r/pull/1';     [ $? = 1 ] && ok || bad "L10 leading space -> not settled"
settled $((21*DAY)) $W 'NOT PR_CREATED https://github.com/o/r/pull/1';  [ $? = 1 ] && ok || bad "L10 negation -> not settled"
settled $((21*DAY)) $W 'PLAN_BLOCKED see plan';                        [ $? = 1 ] && ok || bad "L11 PLAN_BLOCKED -> not settled"
settled $((21*DAY)) $W;                                                [ $? = 1 ] && ok || bad "L12 no result field -> not settled"
reset; printf '{"key":"TK-1","result":{"a":"%s"}}\n' "$PRC" > "$SRD/TK-1.json"
bash -c '. "'"$LIB"'"; rr_json_pr_settled "$1" "$2" "$3" "$4"' _ "$SRD/TK-1.json" "$((NOW-21*DAY))" "$NOW" "$W"
                                                                       [ $? = 1 ] && ok || bad "L13 result is an object -> not settled"
reset; printf 'not json %s\n' "$PRC" > "$SRD/TK-1.json"
bash -c '. "'"$LIB"'"; rr_json_pr_settled "$1" "$2" "$3" "$4"' _ "$SRD/TK-1.json" "$((NOW-21*DAY))" "$NOW" "$W" 2>/dev/null
                                                                       [ $? = 1 ] && ok || bad "L14 not JSON -> not settled"
settled $((21*DAY)) 0 "$PRC";                                          [ $? = 1 ] && ok || bad "L15 min age 0 (knob off) -> not settled"
settled $((21*DAY)) $W 'PR_CREATED https://github.com.evil/o/r/pull/1'; [ $? = 1 ] && ok || bad "L16 host near miss -> not settled"

# ── S1: the ticket's case — 21d PR_CREATED, folder present, no RELAYED ──────
reset; mkjson TK-860 $((21*DAY)) "$PRC"; folder TK-860
drive
[ "$(nalerts)" = 0 ] && ok || bad "S1 a consumed 3-week-old result paged: $(cat "$T/alerts.txt")"

# ── S2: same json, folder gone, ledger answers no row ───────────────────────
reset; mkjson TK-860 $((21*DAY)) "$PRC"
drive
[ "$(nalerts)" = 0 ] && ok || bad "S2 folder gone: paged: $(cat "$T/alerts.txt")"

# ── S3: S1+S2 together -> 0 ledger reads, 0 rr-consumed reads, 0 gh calls ──
reset; mkjson TK-860 $((21*DAY)) "$PRC"; folder TK-860; mkjson TK-859 $((21*DAY)) "$PRC"
drive
[ "$(nalerts)" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(nrrc)" = 0 ] && [ "$(ngh)" = 0 ] && ok \
  || bad "S3 alerts=$(nalerts) ledger=$(ncalls) rrc=$(nrrc) gh=$(ngh)"

# ── S4: a cap of 1 still serves the one unsettled json ──────────────────────
reset; mkjson TK-1 $((21*DAY)) "$PRC"; mkjson TK-2 $((21*DAY)) "$PRC"; mkjson TK-3 7200
drive STALEREMOTE_LEDGER_READS=1
[ "$(ncalls)" = 1 ] && [ "$(nalerts)" = 1 ] && grep -q 'staleremote:mk:TK-3.json' "$T/alerts.txt" && ok \
  || bad "S4 cap 1: ledger=$(ncalls) alerts=$(cat "$T/alerts.txt")"

# ── S5-S8: the retention rule's retired mark ────────────────────────────────
# mark <key> <mtime> <marked>
mark() { mkdir -p "$TCD"; printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TCD/$P.tsv"; }
reset; mkjson TK-5 7200; folder TK-5; mark TK-5 $((NOW-7200)) 1
drive
[ "$(nalerts)" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(nrrc)" = 0 ] && ok || bad "S5 R1 retired, folder present: alerts=$(nalerts) ledger=$(ncalls) rrc=$(nrrc)"
reset; mkjson TK-5 7200; mark TK-5 $((NOW-7200)) 1
drive
[ "$(nalerts)" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "S6 R2 retired, folder gone: alerts=$(nalerts) ledger=$(ncalls)"
reset; mkjson TK-5 7200; folder TK-5; mark TK-5 $((NOW-9999)) 1
drive
[ "$(nalerts)" = 1 ] && ok || bad "S7 R3 marked with another mtime must page, alerts=$(nalerts)"
reset; mkjson TK-5 7200; folder TK-5; mark TK-5 $((NOW-7200)) 0
drive
[ "$(nalerts)" = 1 ] && ok || bad "S8 R4 marked=0, folder present must page, alerts=$(nalerts)"
reset; mkjson TK-5 7200; folder TK-5; mark TK-6 $((NOW-7200)) 1
drive
[ "$(nalerts)" = 1 ] && ok || bad "S8 R5 a mark for another key must page, alerts=$(nalerts)"

# ── S9: the summary line ────────────────────────────────────────────────────
reset; mkjson TK-860 $((21*DAY)) "$PRC"; folder TK-860; mkjson TK-5 7200; folder TK-5; mark TK-5 $((NOW-7200)) 1
drive
grep -qx 'TS mk staleremote: settled 2 (pr older than 7d 1, retired 1; not paged)' "$T/logs/pipeline-health.log" && ok \
  || bad "S9 summary line: $(cat "$T/logs/pipeline-health.log")"
[ "$(grep -c . "$T/logs/pipeline-health.log")" = 1 ] && ok || bad "S9 want exactly 1 log line: $(cat "$T/logs/pipeline-health.log")"

# ── S10: no settled json -> no settled line; the BH-7582 line is unchanged ──
reset; mkjson TK-7 7200
drive STALEREMOTE_LEDGER_READS=0
grep -q 'settled' "$T/logs/pipeline-health.log" && bad "S10 a settled line with nothing settled" || ok
grep -qx 'TS mk staleremote: ledger-terminal 0, cached 0, unknown 0 (not paged, ledger unreadable), deferred 1 (read cap 0)' \
  "$T/logs/pipeline-health.log" && ok || bad "S10 the BH-7582 line changed: $(cat "$T/logs/pipeline-health.log")"

# ── S11: a 2-hour PR_CREATED json, folder present, still pages ──────────────
reset; mkjson TK-11 7200 'PR_CREATED https://github.com/o/r/pull/11'; folder TK-11
drive
[ "$(nalerts)" = 1 ] && grep -q '^7200|staleremote:mk:TK-11.json|mk remote-result TK-11.json unconsumed >30m' "$T/alerts.txt" && ok \
  || bad "S11 a fresh PR json must page: $(cat "$T/alerts.txt")"

# ── S12: knob 0 -> the ticket's json pages again ────────────────────────────
reset; mkjson TK-860 $((21*DAY)) "$PRC"; folder TK-860
drive STALEREMOTE_PR_SETTLED_DAYS=0
[ "$(nalerts)" = 1 ] && ok || bad "S12 knob 0 must restore paging, alerts=$(nalerts)"

# ── S13: knob abc -> falls back to 7 ────────────────────────────────────────
reset; mkjson TK-860 $((21*DAY)) "$PRC"; folder TK-860
drive STALEREMOTE_PR_SETTLED_DAYS=abc
[ "$(nalerts)" = 0 ] && ok || bad "S13 knob abc must fall back to 7, alerts=$(nalerts)"
reset; mkjson TK-860 $((8*DAY)) "$PRC"; folder TK-860
drive STALEREMOTE_PR_SETTLED_DAYS=999
[ "$(nalerts)" = 0 ] && ok || bad "S13 knob 999 (> 365) must fall back to 7, alerts=$(nalerts)"
reset; mkjson TK-860 $((8*DAY)) "$PRC"; folder TK-860
drive STALEREMOTE_PR_SETTLED_DAYS=10
[ "$(nalerts)" = 1 ] && ok || bad "S13 knob 10 must page an 8d json, alerts=$(nalerts)"

# ── K1: the knob row and the fallback comment that names it ─────────────────
grep -q '# fallback of the pipeline-health knob STALEREMOTE_PR_SETTLED_DAYS' "$DIR/bin/pipeline-health.sh" && ok \
  || bad "K1 bin/pipeline-health.sh has no fallback comment naming STALEREMOTE_PR_SETTLED_DAYS"
[ "$(jq -r '.env+" "+(.default|tostring)' "$KNOB" 2>/dev/null)" = "STALEREMOTE_PR_SETTLED_DAYS 7" ] && ok \
  || bad "K1 $KNOB missing or default is not 7"

# ── M1: a lib whose rr_json_pr_settled always says no turns S1 red ─────────
sed 's/^rr_json_pr_settled() {$/rr_json_pr_settled() { return 1;/' "$LIB" > "$T/mutant-lib.sh"
cmp -s "$LIB" "$T/mutant-lib.sh" && bad "M1 the mutation changed nothing"
reset; mkjson TK-860 $((21*DAY)) "$PRC"; folder TK-860
drive "$T/mutant-lib.sh"
[ "$(nalerts)" = 1 ] && ok || bad "M1 S1 stayed green on the mutant lib (alerts=$(nalerts))"

[ -s "$T/err.txt" ] && grep -v '^$' "$T/err.txt" | head -5 | sed 's/^/stderr: /'
echo "pipeline-health-staleremote-settled.bh-9142: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
