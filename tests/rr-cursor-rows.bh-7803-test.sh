#!/bin/bash
# tests/rr-cursor-rows.bh-7803-test.sh — THE REMOTE-RESULTS CONSUMER CURSOR AS
# LEDGER ROWS (BH-7803, C3 of #4157).
#
# state/remote-results/<p>/ holds the cursor that stops a remote build from
# being staged twice: .handled/<job>.job per staged ledger row, .handled/<KEY>.json
# per consumed relay json, and .since, the ledger-feed watermark. Those files
# live on ONE box. A rebuilt box has none of them, and its first tick re-stages
# every close-out the feed window still holds. bin/lib/rr-cursor.sh writes each
# of them as a `ledgers` row too (rr-handled, rr-consumed, rr-since) and reads
# the row when the file is absent. The file is still written and read first:
# it is the last-good cache for an outage.
#
# Driven, not grepped: the REAL lib, the REAL rt_stage (sourced as
# bin/run-triage.sh does) and the REAL bin/triage-gate.sh. The ledger is a stub
# over a per-test dir (one file per <kind>/<urlencoded key>), the feed a fixture
# TSV. No network.
#
#   L1-L12 the lib          S1-S6 rt_stage          G1-G3 the gate's section 3b
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/rr-cursor-rows.bh-7803-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
unset FULL_SWEEP_SECS TRIAGE_FAIL_CONSUME_AFTER JOBS_BOX

H="$T/h"; P=project-3
RR="$H/state/remote-results/$P"
LEDGER="$T/ledger"; FEED="$T/feed"
export LEDGER FEED

# ── the stub client ──────────────────────────────────────────────────────────
# job_ledger_row / job_ledger_put over $LEDGER/<kind>/<urlencoded key>, one
# {status, detail} JSON per file, the shape bin/lib/jobs/jobs.sh prints.
# $LEDGER/.row-down -> every read rc 1; $LEDGER/.put-down -> every write rc 1.
# Every PUT is appended to $LEDGER/.puts as `<kind>\t<key>\t<status>`.
# job_artifact_feed answers `result` from $FEED/result with the worker's strict
# `since` and the limit, and logs each call to $FEED/calls.
cat > "$T/stub.sh" <<'SH'
_stub_f() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }
job_ledger_get() { return 2; }
job_ledger_row() {
  [ -f "$LEDGER/.row-down" ] && return 1
  local f; f=$(_stub_f "$1" "$2")
  [ -f "$f" ] || return 2
  cat "$f"
}
job_ledger_put() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  [ -f "$LEDGER/.put-down" ] && return 1
  mkdir -p "$LEDGER/$1"
  jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d}' > "$(_stub_f "$1" "$2")"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER/.puts"
}
flag_active() { [ -f "${HARNESS:-/nonexistent}/flags/$1" ]; }
job_artifact_feed() {
  echo "FEED $1 $2 since=${3:-} limit=${4:-}" >> "$FEED/calls"
  [ -f "$FEED/down" ] && return 1
  [ -f "$FEED/$1" ] || return 0
  awk -F'\t' -v s="${3:-}" -v n="${4:-100}" '(s == "" || $5 > s) && c < n { print; c++ }' "$FEED/$1"
}
SH

reset() {
  scratch_rm "$H/builds"; scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$LEDGER"; scratch_rm "$FEED"
  mkdir -p "$H/builds" "$H/logs" "$H/flags" "$H/state" "$LEDGER" "$FEED"
  : > "$T/tick.log"
}
# seed <kind> <key> <status> [detail] — a row already in the DB.
seed() { mkdir -p "$LEDGER/$1"; jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d}' > "$LEDGER/$1/$(printf '%s' "$2" | jq -sRr @uri)"; }
rowf() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }
puts() { local n; n=$(grep -c -- "$1" "$LEDGER/.puts" 2>/dev/null); echo "${n:-0}"; }
plog() { local n; n=$(grep -c -- "$1" "$H/logs/$P.log" 2>/dev/null); echo "${n:-0}"; }

# lib <cmd...> — run the lib with the stub client in a subshell (NOSTUB=1: none).
lib() {
  ( export HARNESS="$H" LOG="$H/logs/$P.log" STAMP=2026-10-21T00:00:00Z JOBS_BOX=box-a
    [ "${NOSTUB:-0}" = 1 ] || . "$T/stub.sh"
    . "$DIR/bin/lib/rr-cursor.sh" || exit 9
    "$@" )
}

# ═════════════════════════════════════════════════════════════════════════════
# L1-L4, L6, L7 — rrc_job_handled
# ═════════════════════════════════════════════════════════════════════════════
reset
mkdir -p "$RR/.handled"; : > "$RR/.handled/J1.job"; : > "$LEDGER/.row-down"
lib rrc_job_handled "$P" J1; eq "L1: a file marker answers handled even when the row read fails" "$?" 0

reset
seed rr-handled "$P/J2" staged '{"key":"TK-2"}'
lib rrc_job_handled "$P" J2; eq "L2: no file, row staged -> handled" "$?" 0
[ -f "$RR/.handled/J2.job" ] && ok || bad "L2: the row must heal the file marker"

reset
seed rr-handled "$P/J3" staged; : > "$LEDGER/.row-down"
lib rrc_job_handled "$P" J3; eq "L3: no file, row read rc 1 -> not handled" "$?" 1

reset
lib rrc_job_handled "$P" J4; eq "L4: no file, no row (rc 2) -> not handled" "$?" 1
seed rr-handled "$P/J4" other
lib rrc_job_handled "$P" J4; eq "L4: no file, row status other -> not handled" "$?" 1
[ -f "$RR/.handled/J4.job" ] && bad "L4: a non-staged row must not heal a marker" || ok

reset
seed rr-handled "other-p/J6" staged
lib rrc_job_handled "$P" J6; eq "L6: another project's row for the same job -> not handled" "$?" 1

reset
NOSTUB=1 lib rrc_job_handled "$P" J7; eq "L7: no client, no file -> not handled" "$?" 1
mkdir -p "$RR/.handled"; : > "$RR/.handled/J7.job"
NOSTUB=1 lib rrc_job_handled "$P" J7; eq "L7: no client, file -> handled" "$?" 0

# ═════════════════════════════════════════════════════════════════════════════
# L5 — rrc_json_consume
# ═════════════════════════════════════════════════════════════════════════════
reset
mkdir -p "$RR"
printf '{"key":"TK-1","result":"PR_CREATED x","build_dir":"/hub/builds/pool-project-3-TK-1-a"}\n' > "$RR/TK-1.json"
lib rrc_json_consume "$P" "$RR/TK-1.json" staged pool-project-3-TK-1-a; eq "L5: consume staged rc" "$?" 0
F=$(rowf rr-consumed "$P/TK-1@pool-project-3-TK-1-a")
eq "L5: the rr-consumed row status" "$(jq -r .status "$F" 2>/dev/null)" staged
eq "L5: the row detail carries the json" "$(jq -r '.detail | fromjson | .key' "$F" 2>/dev/null)" TK-1
[ -f "$RR/.handled/TK-1.json" ] && [ ! -e "$RR/TK-1.json" ] && ok || bad "L5: staged json must move to .handled/TK-1.json"
printf '{"key":"TK-5","result":"","machine_build_dir":"project-3-TK-5-m"}\n' > "$RR/TK-5.json"
lib rrc_json_consume "$P" "$RR/TK-5.json" empty
eq "L5: empty row keyed on machine_build_dir" "$(jq -r .status "$(rowf rr-consumed "$P/TK-5@project-3-TK-5-m")" 2>/dev/null)" empty
[ -f "$RR/.handled/TK-5.json.empty" ] && ok || bad "L5: empty json must move to .handled/TK-5.json.empty"
printf 'not json {' > "$RR/TK-9.json"
SHA=$(sha256sum "$RR/TK-9.json" | cut -c1-16)
lib rrc_json_consume "$P" "$RR/TK-9.json" badjson
eq "L5: badjson row keyed on the basename and the sha" "$(jq -r .status "$(rowf rr-consumed "$P/TK-9@$SHA")" 2>/dev/null)" badjson
[ -f "$RR/.handled/TK-9.json.badjson" ] && ok || bad "L5: bad json must move to .handled/TK-9.json.badjson"
printf '{"key":"TK-8"}\n' > "$RR/TK-8.json"
lib rrc_json_consume "$P" "$RR/TK-8.json" bogus; eq "L5: an unknown outcome is refused" "$?" 1
[ -f "$RR/TK-8.json" ] && ok || bad "L5: a refused outcome must not move the json"

# ═════════════════════════════════════════════════════════════════════════════
# L8-L10 — rrc_since_get
# ═════════════════════════════════════════════════════════════════════════════
reset
mkdir -p "$RR"; printf '2026-09-10T02:01:00Z' > "$RR/.since"
seed rr-since "$P" at 2026-09-11T00:00:00Z
eq "L8: a non-empty .since file wins over the row" "$(lib rrc_since_get "$P")" 2026-09-10T02:01:00Z
reset
seed rr-since "$P" at 2026-09-11T00:00:00Z
eq "L9: no file -> the row value" "$(lib rrc_since_get "$P")" 2026-09-11T00:00:00Z
eq "L9: the row heals the .since file" "$(cat "$RR/.since" 2>/dev/null)" 2026-09-11T00:00:00Z
reset
seed rr-since "other-p" at 2026-09-11T00:00:00Z
eq "L10: no file, no row -> empty" "$(lib rrc_since_get "$P")" ""
lib rrc_since_put "$P" 'bad ts;rm'; eq "L10: a watermark outside the filter is refused" "$?" 1
[ -e "$RR/.since" ] && bad "L10: a refused watermark must write no file" || ok

# ═════════════════════════════════════════════════════════════════════════════
# L11, L12 — rrc_job_mark
# ═════════════════════════════════════════════════════════════════════════════
reset
: > "$LEDGER/.put-down"
lib rrc_job_mark "$P" J11 TK-11 project-3-TK-11-remote1; eq "L11: a failed PUT keeps the file rc" "$?" 0
[ -f "$RR/.handled/J11.job" ] && ok || bad "L11: the file marker must stand when the PUT fails"
eq "L11: one rr-cursor log line" "$(plog 'rr-cursor: rr-handled row NOT written for J11')" 1
rm -f "$LEDGER/.put-down"
lib rrc_job_mark "$P" J11b TK-11 project-3-TK-11-remote2
eq "L11: a good PUT writes the staged row" "$(jq -r .status "$(rowf rr-handled "$P/J11b")" 2>/dev/null)" staged
eq "L11: the row detail names the key" "$(jq -r '.detail | fromjson | .key' "$(rowf rr-handled "$P/J11b")" 2>/dev/null)" TK-11
eq "L11: a good PUT logs nothing" "$(plog 'NOT written for J11b')" 0

reset
lib rrc_job_mark "$P" ../x TK-1 d; eq "L12: job id ../x is refused" "$?" 1
lib rrc_job_mark "$P" a/b TK-1 d; eq "L12: job id a/b is refused" "$?" 1
lib rrc_job_mark "$P" .. TK-1 d; eq "L12: job id .. is refused" "$?" 1
lib rrc_job_handled "$P" ../x; eq "L12: rrc_job_handled refuses ../x" "$?" 1
lib rrc_job_mark "a/b" J12 TK-1 d; eq "L12: project a/b is refused" "$?" 1
( unset HARNESS H; . "$T/stub.sh"; . "$DIR/bin/lib/rr-cursor.sh"; rrc_job_mark "$P" J12 TK-1 d ); eq "L12: no HARNESS root is refused" "$?" 1
[ -z "$(find "$H/state" -name '*.job' 2>/dev/null)" ] && ok || bad "L12: a refused id wrote a marker: $(find "$H/state" -name '*.job')"
[ ! -s "$LEDGER/.puts" ] && ok || bad "L12: a refused id wrote a row: $(cat "$LEDGER/.puts")"

# ═════════════════════════════════════════════════════════════════════════════
# S1-S6 — rt_stage, exactly as bin/run-triage.sh calls it
# ═════════════════════════════════════════════════════════════════════════════
# row <job> <ref> <box> <ticket> <ts> <detail-json> — one ledger artifact row.
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$FEED/result"; }
tick() {
  ( export HARNESS="$H" PROJECT="$P" LOG="$H/logs/$P.log" ALERTS="$H/logs/ALERTS.log" \
           STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" JOBS_BOX=box-hub
    [ "${NOSTUB:-0}" = 1 ] || . "$T/stub.sh"
    # NOLEDGER=1: the feed only, no ledger rows at all (today's client shape).
    [ "${NOLEDGER:-0}" = 1 ] && unset -f job_ledger_row job_ledger_put
    . "$DIR/bin/lib/rt/staging.sh" || exit 1
    rt_stage ) >>"$T/tick.log" 2>&1
}
dirs() { ls -d "$H/builds/$P-$1-remote"* 2>/dev/null | wc -l | tr -d ' '; }

# S1 — rebuilt box. Tick 1 stages J1. Then the box loses its disk: the cursor
# dir AND the staged build dir (a rebuild, or builds-retention after the
# sweep). Tick 2 reads the same feed and must stage nothing.
s1_fixture() {
  reset
  row J1 'PR_CREATED https://github.com/o/r/pull/1' pool-m1 1 2026-09-11T02:00:00Z '{"key":"TK-1","build_dir":"project-3-TK-1-m1"}'
  tick
}
s1_fixture
eq "S1: tick 1 stages J1" "$(dirs TK-1)" 1
eq "S1: tick 1 writes the rr-handled row" "$(jq -r .status "$(rowf rr-handled "$P/J1")" 2>/dev/null)" staged
eq "S1: tick 1 writes the rr-since row" "$(jq -r .detail "$(rowf rr-since "$P")" 2>/dev/null)" 2026-09-11T02:00:00Z
scratch_rm "$RR"; scratch_rm "$H/builds"; mkdir -p "$H/builds"
tick
eq "S1: a wiped box stages nothing twice" "$(dirs TK-1)" 0
eq "S1: the .since file comes back from the row" "$(cat "$RR/.since" 2>/dev/null)" 2026-09-11T02:00:00Z
grep -q "since=2026-09-11T02:00:00Z" "$FEED/calls" && ok || bad "S1: tick 2 must ask the feed from the row's watermark: $(cat "$FEED/calls")"

# S3 — the mutation guard for S1: the same wipe with no ledger rows re-stages,
# so S1 passes because of the rows and nothing else.
s1_fixture
scratch_rm "$RR"; scratch_rm "$H/builds"; mkdir -p "$H/builds"
NOLEDGER=1 tick
eq "S3: without the rows the wiped box re-stages J1 (S1 can fail)" "$(dirs TK-1)" 1

# S2 — no file marker, no watermark, an rr-handled row for J1, a new J2.
reset
seed rr-handled "$P/J1" staged
row J2 'PR_CREATED https://github.com/o/r/pull/2' pool-m2 2 2026-09-11T03:00:00Z '{"key":"TK-2","build_dir":"project-3-TK-2-m2"}'
row J1 'PR_CREATED https://github.com/o/r/pull/1' pool-m1 1 2026-09-11T02:00:00Z '{"key":"TK-1","build_dir":"project-3-TK-1-m1"}'
tick
eq "S2: the handled row stops J1" "$(dirs TK-1)" 0
eq "S2: the new J2 is staged" "$(dirs TK-2)" 1
[ -f "$RR/.handled/J1.job" ] && ok || bad "S2: the J1 marker must be healed from the row"
# ...and its mutation: the same fixture with the row read down stages J1.
scratch_rm "$H/builds"; scratch_rm "$RR"; mkdir -p "$H/builds"; : > "$LEDGER/.row-down"
tick
eq "S2: with the row unreadable J1 is staged (the row is what stopped it)" "$(dirs TK-1)" 1
rm -f "$LEDGER/.row-down"

# S4 — a RESULT write fails for a row: no rr-since PUT in that pass.
reset
row J4 'PR_CREATED https://github.com/o/r/pull/4' pool-m4 4 2026-09-11T04:00:00Z '{"key":"TK-4","build_dir":"project-3-TK-4-m4"}'
scratch_rm "$H/builds"; : > "$H/builds"   # a FILE where the dir goes: mkdir fails for every uid
tick
rm -f "$H/builds"; mkdir -p "$H/builds"
eq "S4: a failed staging records no rr-since PUT" "$(puts 'rr-since')" 0
eq "S4: ...and no rr-handled PUT" "$(puts 'rr-handled')" 0
tick
eq "S4: the next tick stages it" "$(dirs TK-4)" 1
eq "S4: ...and then writes the watermark row" "$(puts 'rr-since')" 1

# S5 — every PUT down: the stage output is byte-identical to a run with no
# ledger functions at all.
s5_run() {
  reset
  mkdir -p "$RR"
  printf '{"key":"TK-6","ticket_id":"6","result":"PR_CREATED https://github.com/o/r/pull/6","build_dir":"pool-project-3-TK-6-a"}\n' > "$RR/TK-6.json"
  printf 'nope' > "$RR/TK-7.json"
  row J5 'PR_CREATED https://github.com/o/r/pull/5' pool-m5 5 2026-09-11T05:00:00Z '{"key":"TK-5","build_dir":"project-3-TK-5-m5"}'
  [ "${1:-}" = down ] && : > "$LEDGER/.put-down"
  if [ "${1:-}" = none ]; then NOLEDGER=1 tick; else tick; fi
  ( cd "$H" && find builds state -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$(printf '%s' "$f" | sed 's/remote[0-9]\{14\}/remoteTS/')" "$(sha256sum < "$f" | cut -c1-16)"
    done )
}
A=$(s5_run down); B=$(s5_run none)
eq "S5: PUT down is byte-identical to no ledger client" "$A" "$B"
[ -n "$A" ] && grep -q '.handled/J5.job' <<<"$A" && grep -q '.since' <<<"$A" && ok || bad "S5: the fixture staged nothing, so the compare proves nothing: $A"

# S6 — the relay loop writes rr-consumed rows: staged, then duplicate.
reset
mkdir -p "$RR"
printf '{"key":"TK-3","ticket_id":"3","result":"PR_CREATED https://github.com/o/r/pull/3","build_dir":"pool-project-3-TK-3-a"}\n' > "$RR/TK-3.json"
tick
eq "S6: a staged relay json writes an rr-consumed staged row" \
   "$(jq -r .status "$(rowf rr-consumed "$P/TK-3@pool-project-3-TK-3-a")" 2>/dev/null)" staged
S6D=$(ls -d "$H/builds/$P-TK-3-remote"* | head -1); mv "$S6D" "$H/builds/$P-TK-3-remote20260911000000"
printf '{"key":"TK-3","ticket_id":"3","result":"PR_CREATED https://github.com/o/r/pull/3","build_dir":"pool-project-3-TK-3-a"}\n' > "$RR/TK-3.json"
tick
eq "S6: the second json of one build is a duplicate row" \
   "$(jq -r .status "$(rowf rr-consumed "$P/TK-3@pool-project-3-TK-3-a")" 2>/dev/null)" duplicate
eq "S6: still one staged dir" "$(dirs TK-3)" 1

# S7 — a tree without bin/lib/rr-cursor.sh: staging logs one line and runs on
# the file-only shims, the way it ran before the lib.
reset
S7="$T/s7"; scratch_rm "$S7"; mkdir -p "$S7"
scratch_install_closure bin/lib/rt/staging.sh "$S7" >/dev/null || bad "S7: cannot install the staging closure"
rm -f "$S7/bin/lib/rr-cursor.sh"
mkdir -p "$RR"
printf '{"key":"TK-6","ticket_id":"6","result":"PR_CREATED https://github.com/o/r/pull/6","build_dir":"pool-project-3-TK-6-a"}\n' > "$RR/TK-6.json"
printf 'nope' > "$RR/TK-7.json"
row J7 'PR_CREATED https://github.com/o/r/pull/7' pool-m7 7 2026-09-11T07:00:00Z '{"key":"TK-7b","build_dir":"project-3-TK-7b-m7"}'
( export HARNESS="$H" PROJECT="$P" LOG="$H/logs/$P.log" ALERTS="$H/logs/ALERTS.log" STAMP=2026-10-21T00:00:00Z JOBS_BOX=box-hub
  . "$T/stub.sh"; . "$S7/bin/lib/rt/staging.sh" || exit 1; rt_stage ) >>"$T/tick.log" 2>&1
eq "S7: one 'not found' line" "$(plog 'rr-cursor: bin/lib/rr-cursor.sh not found')" 1
eq "S7: the relay json is staged" "$(dirs TK-6)" 1
eq "S7: the ledger row is staged" "$(dirs TK-7b)" 1
[ -f "$RR/.handled/TK-6.json" ] && [ -f "$RR/.handled/TK-7.json.badjson" ] \
  && [ -f "$RR/.handled/J7.job" ] && ok || bad "S7: the shims must write today's .handled files: $(ls -A "$RR/.handled" 2>/dev/null)"
eq "S7: the shim writes the .since file" "$(cat "$RR/.since" 2>/dev/null)" 2026-09-11T07:00:00Z
[ ! -s "$LEDGER/.puts" ] && ok || bad "S7: no lib must mean no rows: $(cat "$LEDGER/.puts")"
( export HARNESS="$H" PROJECT="$P" LOG="$H/logs/$P.log" ALERTS="$H/logs/ALERTS.log" STAMP=2026-10-21T00:00:01Z JOBS_BOX=box-hub
  . "$T/stub.sh"; . "$S7/bin/lib/rt/staging.sh" || exit 1; rt_stage ) >>"$T/tick.log" 2>&1
eq "S7: the shim's .handled marker stops a second stage" "$(dirs TK-7b)" 1

# ═════════════════════════════════════════════════════════════════════════════
# G1-G3 — the gate's section 3b reads the rows (tests/triage-gate-db-first shape)
# ═════════════════════════════════════════════════════════════════════════════
GP=boardA
GH="$T/g"
GRR="$GH/state/remote-results/$GP"
mkdir -p "$GH/bin" "$GH/state" "$GH/flags" "$GH/logs" "$GH/env" "$GH/builds" "$T/fakebin"
cp "$T/stub.sh" "$GH/bin/jobs-client.sh"
scratch_install_closure bin/triage-gate.sh "$GH" >/dev/null || { echo "FAIL: cannot install the gate closure"; exit 1; }
cat > "$GH/bin/fleet-conf.sh" <<'SH'
case "${2:-}" in board_prefix) echo "-" ;; repo) echo "o/r" ;; *) exit 1 ;; esac
SH
printf '#!/bin/sh\nexit 0\n' > "$GH/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$GH/bin/decision-log.sh"
chmod +x "$GH/bin/"*.sh
cat > "$T/fakebin/gh" <<'SH'
[ "${1:-}" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) P="$1"; break ;; esac; done
case "$P" in
  repos/o/r/issues/*/comments*) BODY='[]' ;;
  repos/o/r/issues*) BODY='[{"number":7,"state":"open","title":"Add sort","comments":1,"updated_at":"2026-09-24T11:00:00Z","body":"b","labels":[{"name":"ai-build"}],"assignees":[],"milestone":null}]' ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
chmod +x "$T/fakebin/gh"
gate() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$GH" JOBS_BOX=hub
    "$GH/bin/triage-gate.sh" "$GP" "$@" 2>>"$T/err.txt" )
}
greset() {
  scratch_rm "$FEED"; scratch_rm "$LEDGER"; scratch_rm "$GH/builds"; scratch_rm "$GH/state/remote-results"
  scratch_rm "$GH/state/$GP.remotefp"
  mkdir -p "$FEED" "$LEDGER" "$GH/builds"
}
grow() { printf '%s\tPR_CREATED https://github.com/o/r/pull/1\t%s\t-\t%s\t{"build_dir":"%s","key":"%s"}\n' "$@" >> "$FEED/result"; }

greset
OUT=$(gate --seed); grep -q '^SEEDED' <<<"$OUT" && ok || bad "G setup: seed '$OUT' err=$(tail -3 "$T/err.txt")"
OUT=$(gate); [ "${OUT%% *}" = SKIP ] && ok || bad "G setup: an empty ledger must SKIP, got '$OUT'"
BASE_SKIP="$OUT"

greset
grow J1 w2 2026-09-25T10:00:00.000Z "$GP-BH-1-a" BH-1
seed rr-handled "$GP/J1" staged
OUT=$(gate); eq "G1: no .handled file, row staged -> no wake" "$OUT" "$BASE_SKIP"
greset
grow J1 w2 2026-09-25T10:00:00.000Z "$GP-BH-1-a" BH-1
OUT=$(gate); eq "G1: no file and no row -> wake" "$OUT" "RUN remote-results-pending"

greset
grow J1 w2 2026-09-25T10:00:00.000Z "$GP-BH-1-a" BH-1
seed rr-since "$GP" at 2026-09-25T10:00:00.000Z
OUT=$(gate); eq "G2: a row at the rr-since watermark does not wake" "$OUT" "$BASE_SKIP"
grep -q "FEED result $GP since=2026-09-25T10:00:00.000Z limit=50" "$FEED/calls" 2>/dev/null && ok \
  || bad "G2: the rr-since row was not passed to the feed: $(cat "$FEED/calls" 2>/dev/null)"

greset
grow J1 w2 2026-09-25T10:00:00.000Z "$GP-BH-1-a" BH-1
seed rr-handled "other-p/J1" staged
seed rr-since "other-p" at 2026-09-25T10:00:00.000Z
OUT=$(gate); eq "G3: another project's rows do not hold the wake" "$OUT" "RUN remote-results-pending"

# G4 — a tree without bin/lib/rr-cursor.sh: the gate reads the files only.
mv "$GH/bin/lib/rr-cursor.sh" "$T/rr-cursor.sh.off"
greset
grow J1 w2 2026-09-25T10:00:00.000Z "$GP-BH-1-a" BH-1
seed rr-handled "$GP/J1" staged
OUT=$(gate); eq "G4: no lib -> the row is not read, the gate wakes" "$OUT" "RUN remote-results-pending"
greset
grow J1 w2 2026-09-25T10:00:00.000Z "$GP-BH-1-a" BH-1
mkdir -p "$GRR/.handled"; : > "$GRR/.handled/J1.job"
OUT=$(gate); eq "G4: no lib -> the .handled file still holds the wake" "$OUT" "$BASE_SKIP"
greset
grow J1 w2 2026-09-25T10:00:00.000Z "$GP-BH-1-a" BH-1
mkdir -p "$GRR"; printf '2026-09-25T10:00:00.000Z' > "$GRR/.since"
OUT=$(gate); eq "G4: no lib -> the .since file still holds the wake" "$OUT" "$BASE_SKIP"
mv "$T/rr-cursor.sh.off" "$GH/bin/lib/rr-cursor.sh"

echo "rr-cursor-rows: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
