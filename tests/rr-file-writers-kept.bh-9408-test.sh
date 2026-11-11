#!/bin/bash
# tests/rr-file-writers-kept.bh-9408-test.sh — THE CURSOR AND RELAY FILES ARE
# KEPT FOR GOOD (BH-9408, the end of #7860 -> #8364 -> #9324 -> #9408).
#
# "Retire the cursor and relay file writers after the rows run in prod" closed
# as won't-do. The rows are lossy copies, the relay json is the staging input,
# and the .handled/<job>.job marker is the only guard against a re-stage on a
# ledger outage. This suite pins each of those reasons against the REAL libs
# (bin/lib/rr-cursor.sh, bin/lib/rr-relay.sh), so a later retire is a
# deliberate change to this file, not a silent drift.
#
# The ledger is a stub over a per-case dir (one file per <kind>/<urlencoded
# key>), the shape tests/rr-cursor-rows.bh-7803-test.sh uses. No network. Each
# case resets its own tree and uses its own keys: no order dependence.
#
#   K1-K4 the cursor files    K5-K7 the consumed json    K6 the relay row
#   K8 the keep decision is recorded in both lib headers
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/rr-file-writers-kept.bh-9408-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset JOBS_BOX

H="$T/h"; P=project-3
RR="$H/state/remote-results/$P"
LEDGER="$T/ledger"
export LEDGER

# ── the stub client ──────────────────────────────────────────────────────────
# $LEDGER/.row-down -> every read rc 1; $LEDGER/.put-down -> every write rc 1.
# Every PUT is appended to $LEDGER/.puts as `<kind>\t<key>\t<status>`.
cat > "$T/stub.sh" <<'SH'
_stub_f() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }
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
SH

reset() {
  scratch_rm "$H"; scratch_rm "$LEDGER"
  mkdir -p "$H/logs" "$H/state" "$LEDGER"
}
rowf() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }

# lib <cmd...> — the REAL libs with the stub client, in a subshell.
lib() {
  ( export HARNESS="$H" LOG="$H/logs/$P.log" STAMP=2026-11-10T00:00:00Z JOBS_BOX=box-k
    . "$T/stub.sh"
    . "$DIR/bin/lib/rr-cursor.sh" || exit 9
    . "$DIR/bin/lib/rr-relay.sh" || exit 9
    "$@" )
}
# bigjson <KEY> <n> — a relay json whose .result is <n> chars.
bigjson() {
  jq -nc --arg k "$1" --arg r "$(head -c "$2" /dev/zero | tr '\0' 'r')" \
    '{key:$k, build_dir:"/root/harness/builds/b-\($k)", result:$r}'
}

# ═════════════════════════════════════════════════════════════════════════════
# K1 — rows up: the marker file and the row are both written; with the row
#      read down, the FILE answers "handled".
# ═════════════════════════════════════════════════════════════════════════════
reset
lib rrc_job_mark "$P" job-k1 KEY-K1 dest; eq "K1: rrc_job_mark rc" "$?" 0
[ -f "$RR/.handled/job-k1.job" ] && ok || bad "K1: the .handled/job-k1.job marker must be written"
[ -f "$(rowf rr-handled "$P/job-k1")" ] && ok || bad "K1: the rr-handled row must be written"
: > "$LEDGER/.row-down"
lib rrc_job_handled "$P" job-k1; eq "K1: row read down, the file answers handled" "$?" 0

# ═════════════════════════════════════════════════════════════════════════════
# K2 — the outage hole the file covers: no marker, row read down -> "not
#      handled" (rc 1), even though the row says staged. Without the file a
#      ledger outage re-stages the result (a second close-out).
# ═════════════════════════════════════════════════════════════════════════════
reset
lib rrc_job_mark "$P" job-k2 KEY-K2 dest >/dev/null
rm -f "$RR/.handled/job-k2.job"; : > "$LEDGER/.row-down"
lib rrc_job_handled "$P" job-k2; eq "K2: no marker, row read down -> not handled" "$?" 1

# ═════════════════════════════════════════════════════════════════════════════
# K3 — the watermark: .since file and rr-since row; row read down, the file
#      answers.
# ═════════════════════════════════════════════════════════════════════════════
reset
lib rrc_since_put "$P" 2026-11-10T00:00:00Z; eq "K3: rrc_since_put rc" "$?" 0
eq "K3: the .since file" "$(cat "$RR/.since" 2>/dev/null)" 2026-11-10T00:00:00Z
[ -f "$(rowf rr-since "$P")" ] && ok || bad "K3: the rr-since row must be written"
: > "$LEDGER/.row-down"
eq "K3: row read down, rrc_since_get answers from the file" "$(lib rrc_since_get "$P")" 2026-11-10T00:00:00Z

# ═════════════════════════════════════════════════════════════════════════════
# K4 — PUT down: the marker file is still written and the rc is the file op's.
# ═════════════════════════════════════════════════════════════════════════════
reset
: > "$LEDGER/.put-down"
lib rrc_job_mark "$P" job-k4 KEY-K4 dest; eq "K4: PUT down, rrc_job_mark rc" "$?" 0
[ -f "$RR/.handled/job-k4.job" ] && ok || bad "K4: PUT down, the marker file must still be written"
[ -f "$(rowf rr-handled "$P/job-k4")" ] && bad "K4: PUT down, no row may exist" || ok

# ═════════════════════════════════════════════════════════════════════════════
# K5 — a 5000-char result: the moved .handled/<KEY>.json is the only full copy;
#      the rr-consumed row detail is cut to <= 3500 bytes.
# ═════════════════════════════════════════════════════════════════════════════
reset
mkdir -p "$RR"; bigjson K5 5000 > "$RR/K5.json"
lib rrc_json_consume "$P" "$RR/K5.json" staged; eq "K5: rrc_json_consume rc" "$?" 0
[ -f "$RR/K5.json" ] && bad "K5: the relay json must move out of the inbox" || ok
eq "K5: the moved json keeps all 5000 chars" "$(jq -r '.result | length' "$RR/.handled/K5.json" 2>/dev/null)" 5000
f=$(rowf rr-consumed "$P/K5@b-K5")
[ -f "$f" ] && ok || bad "K5: the rr-consumed row must be written"
n=$(jq -j '.detail' "$f" 2>/dev/null | head -c 100000 | wc -c)
[ "${n:-0}" -gt 0 ] && [ "$n" -le 3500 ] && ok || bad "K5: rr-consumed detail must be cut to <= 3500 bytes (got $n)"

# ═════════════════════════════════════════════════════════════════════════════
# K6 — rrr_park: the rr-relay row cuts .result to 1000 chars (the lossy row),
#      and rrr_park neither writes nor removes a relay file.
# ═════════════════════════════════════════════════════════════════════════════
reset
mkdir -p "$RR"; : > "$RR/OTHER-K6.json"
lib rrr_park "$P" "$(bigjson K6 5000)"; eq "K6: rrr_park rc" "$?" 0
f=$(rowf rr-relay "$P/K6@b-K6")
[ -f "$f" ] && ok || bad "K6: the rr-relay row must be written"
eq "K6: the rr-relay row keeps 1000 chars of .result" "$(jq -r '.detail | fromjson | .result | length' "$f" 2>/dev/null)" 1000
eq "K6: rrr_park writes and removes no relay file" "$(cd "$RR" && ls -A | tr '\n' ' ')" "OTHER-K6.json "

# ═════════════════════════════════════════════════════════════════════════════
# K7 — every outcome still moves the json to .handled/ with today's suffix.
# ═════════════════════════════════════════════════════════════════════════════
for c in duplicate:K7D.json empty:K7E.json.empty badjson:K7B.json.badjson; do
  reset
  oc="${c%%:*}"; want="${c#*:}"; src="${want%%.json*}.json"
  mkdir -p "$RR"
  if [ "$oc" = badjson ]; then printf '{not json' > "$RR/$src"; else bigjson "${src%.json}" 10 > "$RR/$src"; fi
  lib rrc_json_consume "$P" "$RR/$src" "$oc"; eq "K7 $oc: rc" "$?" 0
  [ -f "$RR/.handled/$want" ] && ok || bad "K7 $oc: the json must move to .handled/$want"
  [ -f "$RR/$src" ] && bad "K7 $oc: the json must leave the inbox" || ok
done

# ═════════════════════════════════════════════════════════════════════════════
# K8 — the keep decision is written in both lib headers.
# ═════════════════════════════════════════════════════════════════════════════
eq "K8: rr-cursor.sh records the keep" "$(grep -c 'KEPT FOR GOOD (BH-9408)' "$DIR/bin/lib/rr-cursor.sh")" 1
eq "K8: rr-relay.sh records the keep" "$(grep -c 'KEPT FOR GOOD (BH-9408)' "$DIR/bin/lib/rr-relay.sh")" 1

echo "rr-file-writers-kept K1-K8: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
