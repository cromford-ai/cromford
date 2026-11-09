#!/bin/bash
# tests/rr-relay-readers.bh-8364-test.sh — THE RR-RELAY ROW: THE POOL WRITER AND
# FOUR READERS (BH-8364, slice C0).
#
# bin/lib/rr-relay.sh (BH-7860) gives each relay json an `rr-relay` ledger row,
# key <p>/<KEY>@<build-id>, and the owning box's consume writes `rr-consumed`.
# This slice adds the writer in pool_push_full (config/fly-pool.d/
# 3000-pool-full-push.sh, rendered into bin/fly-pool.sh) and four readers:
# pipeline-health's staleremote block, builds-retention, the staging relay loop
# and fleet-slo. The files stay written and stay the input: a row read can only
# remove a false page, stop a second staging, or keep a build dir longer.
#
# Driven, not grepped: the REAL pool_push_full (extracted from its fragment),
# the REAL lib, the REAL staleremote block, the REAL bin/builds-retention.sh,
# the REAL rt_stage and the REAL bin/fleet-slo.sh. The ledger is a stub over a
# per-test dir (one file per <kind>/<urlencoded key>). ssh is a PATH stub. No
# network.
#
#   W1-W6 the pool writer     L1-L12 rrr_open / rrr_list   P1-P7 staleremote
#   B1-B9 builds-retention    S1-S8 the staging relay loop  F1-F9 fleet-slo
#   R1 the round trip         C1 the catalog row
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/rr-relay-readers.bh-8364-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v jq >/dev/null && command -v flock >/dev/null || { echo "jq/flock missing — skipping"; exit 0; }
unset JOBS_BOX DLOG FULL_SWEEP_SECS TRIAGE_FAIL_CONSUME_AFTER SLO_RELAY_ROWS_LIMIT

LIB="$DIR/bin/lib/rr-relay.sh"
LEDGER="$T/ledger"
export LEDGER

# ── the stub client ──────────────────────────────────────────────────────────
# $LEDGER/<kind>/<urlencoded key> holds {key, status, detail, created_at}. A PUT
# with no detail keeps the stored one (the worker's COALESCE) and keeps
# created_at. job_ledger_row prints {status, detail}, the shape
# bin/lib/jobs/jobs.sh prints. $LEDGER/.row-down -> every read rc 1;
# $LEDGER/.row-down.<kind> -> reads of that kind rc 1; $LEDGER/.put-down ->
# every write rc 1. Reads are logged to $LEDGER/.reads, writes to
# $LEDGER/.puts, and the order of PUTs and ssh calls to $T/order.
# _jobs_req answers the rr-relay list from the stored rows (or from
# $LEDGER/.list when that file exists) and /api/jobs with an empty jobs body.
cat > "$T/stub.sh" <<'SH'
_stub_f() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }
job_ledger_get() { return 2; }
job_ledger_row() {
  printf '%s\t%s\n' "$1" "$2" >> "$LEDGER/.reads"
  [ -f "$LEDGER/.row-down" ] && return 1
  [ -f "$LEDGER/.row-down.$1" ] && return 1
  local f; f=$(_stub_f "$1" "$2")
  [ -f "$f" ] || return 2
  jq -c '{status, detail}' "$f"
}
job_ledger_put() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  echo "PUT $1" >> "${ORDER:-/dev/null}"
  [ -f "$LEDGER/.put-down" ] && return 1
  local f d="${4:-}" c="2026-11-04T10:00:00Z"; f=$(_stub_f "$1" "$2")
  mkdir -p "$LEDGER/$1"
  [ -z "$d" ] && [ -f "$f" ] && d=$(jq -r '.detail // ""' "$f")
  [ -f "$f" ] && c=$(jq -r '.created_at' "$f")
  jq -nc --arg k "$2" --arg s "$3" --arg d "$d" --arg c "$c" '{key:$k, status:$s, detail:$d, created_at:$c, updated_at:$c}' > "$f"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER/.puts"
}
_jobs_req() {
  echo "$1 $2" >> "$LEDGER/.reqs"
  case "$2" in
    /api/ledger\?kind=rr-relay\&limit=*)
      if [ -f "$LEDGER/.list" ]; then cat "$LEDGER/.list"; return 0; fi
      if [ -d "$LEDGER/rr-relay" ]; then jq -sc '{ledgers: .}' "$LEDGER"/rr-relay/*; else echo '{"ledgers":[]}'; fi ;;
    /api/jobs*) echo '{"jobs":[]}' ;;
    *) return 1 ;;
  esac
}
flag_active() { [ -f "${HARNESS:-/nonexistent}/flags/$1" ]; }
job_artifact_feed() { return 0; }
SH

lreset() { scratch_rm "$LEDGER"; mkdir -p "$LEDGER"; }
# seed <kind> <key> <status> [detail] [created_at] — a row already in the DB.
seed() {
  mkdir -p "$LEDGER/$1"
  jq -nc --arg k "$2" --arg s "$3" --arg d "${4:-}" --arg c "${5:-2026-11-04T10:00:00Z}" \
    '{key:$k, status:$s, detail:$d, created_at:$c, updated_at:$c}' > "$LEDGER/$1/$(printf '%s' "$2" | jq -sRr @uri)"
}
rowf() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

# ═════════════════════════════════════════════════════════════════════════════
# W1-W6 — pool_push_full parks the rr-relay row before the push
# ═════════════════════════════════════════════════════════════════════════════
FRAG="$DIR/config/fly-pool.d/3000-pool-full-push.sh"
awk '/^pool_push_full\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$FRAG" > "$T/ppf.sh"
grep -q '^pool_push_full() {' "$T/ppf.sh" && ok || { echo "FAIL: could not extract pool_push_full from $FRAG"; exit 1; }
WH="$T/wh"; WP=demo; WBD="pool-demo-BH-1-20261104"
mkdir -p "$T/fake"
# ssh: the order file, stdin read (the payload), $T/ssh-fail -> rc 255. The json
# push saves its payload to $T/box/<p>/<KEY>.json, the box's relay dir.
cat > "$T/fake/ssh" <<'SH'
#!/bin/bash
echo ssh >> "${ORDER:-/dev/null}"
cmd="${*: -1}"
case "$cmd" in
  *state/remote-results/*) j="${cmd##*cat > /root/harness/state/remote-results/}"
                           mkdir -p "$BOXRR/$(dirname "$j")"; cat > "$BOXRR/$j" ;;
  *) cat >/dev/null ;;
esac
[ -f "$T/ssh-fail" ] && exit 255
exit 0
SH
chmod +x "$T/fake/ssh"
wreset() {
  lreset; scratch_rm "$WH"; scratch_rm "$T/box"; rm -f "$T/ssh-fail"
  mkdir -p "$WH/logs" "$WH/bin" "$WH/builds/$WBD" "$WH/state/remote-results/$WP" "$T/box"
  printf 'PR_CREATED https://github.com/o/r/pull/1\nBUILD_DIR: demo-BH-1-m1\n' > "$WH/builds/$WBD/RESULT"
  echo '{"key":"BH-1"}' > "$WH/state/remote-results/$WP/BH-1.json"
  printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\n' "$T" > "$WH/bin/alert-line.sh"; chmod +x "$WH/bin/alert-line.sh"
  : > "$T/order"; : > "$T/alert-calls"
}
# push [NOPUT=1] — pool_push_full for demo/BH-1, as the reap calls it.
push() {
  ( export HARNESS="$WH" LOG="$WH/logs/fly-pool.log" PATH="$T/fake:$PATH" ORDER="$T/order" BOXRR="$T/box" T
    P="$WP"
    STAMP() { echo 2026-11-04T10:00:00Z; }
    say() { echo "SAY $*" >> "$LOG"; }
    . "$T/stub.sh"
    [ "${NOPUT:-0}" = 1 ] && unset -f job_ledger_put
    . "$LIB" || exit 9
    . "$T/ppf.sh"
    pool_push_full "$WP" BH-1 42 "$WH/builds/$WBD" box-fixture https://github.com/o/r/pull/1 2 )
}
WROW=$(rowf rr-relay "$WP/BH-1@$WBD")

wreset; push; RC=$?
eq "W1: a good push is rc 0" "$RC" 0
eq "W1: the row is parked" "$(jq -r .status "$WROW" 2>/dev/null)" parked
eq "W1: the detail is the payload (key)" "$(jq -r '.detail | fromjson | .key' "$WROW" 2>/dev/null)" BH-1
eq "W1: the detail is the payload (source)" "$(jq -r '.detail | fromjson | .source' "$WROW" 2>/dev/null)" pool
eq "W1: exactly one PUT" "$(cnt rr-relay "$LEDGER/.puts")" 1
eq "W2: the PUT comes before the first ssh" "$(head -2 "$T/order" | tr '\n' ' ')" "PUT rr-relay ssh "

wreset; : > "$T/ssh-fail"; push; RC=$?
eq "W3: a failed ssh is rc 1" "$RC" 1
eq "W3: the row stays parked" "$(jq -r .status "$WROW" 2>/dev/null)" parked
[ -f "$WH/state/remote-results/$WP/BH-1.json" ] && ok || bad "W3: the hub json must be kept"
[ ! -f "$WH/builds/$WBD/RELAYED" ] && ok || bad "W3: RELAYED must not be stamped"
eq "W3: one alert-line call" "$(grep -c . "$T/alert-calls")" 1

wreset; : > "$LEDGER/.put-down"; push; RC=$?
eq "W4: a failed PUT leaves the rc at 0" "$RC" 0
[ ! -f "$WH/state/remote-results/$WP/BH-1.json" ] && ok || bad "W4: the hub json must be removed"
[ -f "$WH/builds/$WBD/RELAYED" ] && ok || bad "W4: RELAYED must be stamped"
eq "W4: one log line for the failed PUT" "$(cnt 'rr-relay row NOT written' "$WH/logs/fly-pool.log")" 1
[ ! -f "$WROW" ] && ok || bad "W4: no row on a failed PUT"

wreset; NOPUT=1 push; RC=$?
eq "W5: no client is rc 0" "$RC" 0
[ ! -f "$WROW" ] && ok || bad "W5: no client writes no row"
[ -f "$WH/builds/$WBD/RELAYED" ] && ok || bad "W5: no client still stamps RELAYED"
eq "W5: no client still pushes (json + RESULT ssh calls)" "$(cnt ssh "$T/order")" 2

if cmp -s <(LC_ALL=C cat "$DIR"/config/fly-pool.d/[0-9]*.sh) "$DIR/bin/fly-pool.sh"; then ok; else bad "W6: bin/fly-pool.sh is not the render of config/fly-pool.d/"; fi
[ "$(grep -c rrr_park "$DIR/bin/fly-pool.sh")" -ge 1 ] && ok || bad "W6: bin/fly-pool.sh does not call rrr_park"
grep -qE '^[^#]*rr-relay\.sh' "$FRAG" && ok || bad "W6: the fragment does not source bin/lib/rr-relay.sh"

# ═════════════════════════════════════════════════════════════════════════════
# L1-L12 — rrr_open and rrr_list
# ═════════════════════════════════════════════════════════════════════════════
LH="$T/lh"; mkdir -p "$LH"
lib() { ( export HARNESS="$LH"; [ "${NOSTUB:-0}" = 1 ] || . "$T/stub.sh"; . "$LIB" || exit 9; "$@" ); }
ro() { lib rrr_open "$@" >/dev/null 2>&1; echo $?; }
K="ts/TK-1@pool-ts-TK-1-a"
lreset; seed rr-relay "$K" parked
eq "L1: parked + no rr-consumed -> rc 0" "$(ro ts TK-1 pool-ts-TK-1-a)" 0
[ -z "$(lib rrr_open ts TK-1 pool-ts-TK-1-a)" ] && ok || bad "L1: rrr_open prints nothing"
seed rr-consumed "$K" staged
eq "L2: parked + rr-consumed staged -> rc 2" "$(ro ts TK-1 pool-ts-TK-1-a)" 2
lreset; seed rr-relay "$K" staged
eq "L3: rr-relay staged -> rc 2" "$(ro ts TK-1 pool-ts-TK-1-a)" 2
lreset
eq "L4: no rr-relay row -> rc 2" "$(ro ts TK-1 pool-ts-TK-1-a)" 2
lreset; seed rr-relay "$K" parked; : > "$LEDGER/.row-down.rr-relay"
eq "L5: rr-relay outage -> rc 1" "$(ro ts TK-1 pool-ts-TK-1-a)" 1
lreset; seed rr-relay "$K" parked; : > "$LEDGER/.row-down.rr-consumed"
eq "L6: parked + rr-consumed outage -> rc 1" "$(ro ts TK-1 pool-ts-TK-1-a)" 1
lreset; seed rr-relay "$K" parked
eq "L7: project a/b -> rc 1" "$(ro a/b TK-1 pool-ts-TK-1-a)" 1
eq "L7: KEY ../x -> rc 1" "$(ro ts ../x pool-ts-TK-1-a)" 1
eq "L7: empty build id -> rc 1" "$(ro ts TK-1 '')" 1
eq "L7: build id a/b -> rc 1" "$(ro ts TK-1 a/b)" 1
eq "L7: no reads on a bad id" "$(cnt . "$LEDGER/.reads")" 0
eq "L8: no client -> rc 1" "$(NOSTUB=1 ro ts TK-1 pool-ts-TK-1-a)" 1
lreset; mkdir -p "$LEDGER/rr-relay"; echo '{"status":"","detail":""}' > "$(rowf rr-relay "$K")"
eq "L8: a row with no status -> rc 1" "$(ro ts TK-1 pool-ts-TK-1-a)" 1

lreset
seed rr-relay "ts/TK-1@pool-ts-TK-1-a" parked '{"key":"TK-1","result":"BUILD_FAILED x\nline2"}' 2026-11-04T09:00:00Z
seed rr-relay "ts/TK-2@project-3-x" staged 'not json {' 2026-11-04T09:30:00Z
seed rr-relay "ts/TK-3-noat" parked '{"result":"PR_CREATED"}'
seed rr-relay "noslash@x" parked '{"result":"PR_CREATED"}'
OUT=$(lib rrr_list 50); RC=$?
eq "L9: rrr_list rc 0" "$RC" 0
grep -qxF "$(printf 'ts\tPB-1\tpool-ts-TK-1-a\tparked\t2026-11-04T09:00:00Z\tBUILD_FAILED x')" <<<"$OUT" && ok || bad "L9: the TSV fields: $OUT"
grep -q "$(printf '\t2026-11-04T09:30:00Z\t')" <<<"$OUT" && ok || bad "L10: created_at passes through: $OUT"
eq "L10: a key with no @ or no / is skipped (2 rows)" "$(grep -c . <<<"$OUT")" 2
grep -qxF "$(printf 'ts\tPB-2\tproject-3-x\tstaged\t2026-11-04T09:30:00Z\t')" <<<"$OUT" && ok || bad "L11: detail not json -> empty result: $OUT"
grep -q 'limit=50$' "$LEDGER/.reqs" && ok || bad "L12: the limit rides the request: $(cat "$LEDGER/.reqs")"
lreset; lib rrr_list abc >/dev/null
grep -q 'kind=rr-relay&limit=200$' "$LEDGER/.reqs" && ok || bad "L12: limit abc -> 200: $(cat "$LEDGER/.reqs")"
lreset; lib rrr_list 5000 >/dev/null
grep -q 'limit=200$' "$LEDGER/.reqs" && ok || bad "L12: limit 5000 -> 200: $(cat "$LEDGER/.reqs")"
lreset; echo '{"jobs":[]}' > "$LEDGER/.list"
OUT=$(lib rrr_list 10); RC=$?
eq "L12: a jobs body -> rc 1" "$RC" 1
eq "L12: a jobs body prints nothing" "$OUT" ""
OUT=$(NOSTUB=1 lib rrr_list 10); RC=$?
eq "L12: no _jobs_req -> rc 1" "$RC" 1

# ═════════════════════════════════════════════════════════════════════════════
# P1-P7 — pipeline-health staleremote: a json the box consumed does not page
# ═════════════════════════════════════════════════════════════════════════════
awk '/^# >>> staleremote/{f=1;next} /^# <<< staleremote/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/sr.sh"
[ -s "$T/sr.sh" ] && ok || { echo "FAIL: could not extract the staleremote block"; exit 1; }
grep -qE '^[^#]*\. "\$H/bin/lib/rr-relay\.sh"' "$DIR/bin/pipeline-health.sh" && ok || bad "P0: bin/pipeline-health.sh does not source bin/lib/rr-relay.sh"
PH="$T/ph"; SRD="$PH/state/remote-results/ts"; NOWP=1760000000
preset() {
  lreset; scratch_rm "$PH"; mkdir -p "$SRD" "$PH/logs" "$PH/builds" "$PH/bin"
  : > "$T/alerts.txt"; : > "$PH/logs/pipeline-health.log"
}
# pjson <KEY> [folder] — a hub json 2 h old; folder=1 also makes its hub dir (no RELAYED).
pjson() {
  printf '{"key":"%s","build_dir":"pool-ts-%s-20261104"}\n' "$1" "$1" > "$SRD/$1.json"
  touch -d "@$((NOWP - 7200))" "$SRD/$1.json"
  [ "${2:-0}" = 1 ] && mkdir -p "$PH/builds/pool-ts-$1-20261104"
  return 0
}
pdrive() { # pdrive [NORR=1] [STALEREMOTE_LEDGER_READS=n]
  ( export T PH NOWP LEDGER RRLIB="$LIB" RLLIB="$DIR/bin/lib/remote-results-ledger.sh"
    env "$@" bash -c '
      set -uo pipefail
      H="$PH"; NOW="$NOWP"; PROJECTS="ts"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$T/stub.sh"; . "$RLLIB"
      [ "${NORR:-0}" = 1 ] || . "$RRLIB"
      . "$0"' "$T/sr.sh" 2>>"$T/err.txt" )
}
nal() { grep -c . "$T/alerts.txt"; }
preset; pjson TK-1; seed rr-consumed "ts/TK-1@pool-ts-TK-1-20261104" staged
pdrive
eq "P1: a consumed json does not page" "$(nal)" 0
eq "P2: one consumed line" "$(grep -cxF "TS ts staleremote: consumed 1 (the owning box's rr-consumed row; not paged)" "$PH/logs/pipeline-health.log")" 1
preset; pjson TK-1; seed rr-consumed "ts/TK-1@pool-ts-TK-1-20261104" badjson
pdrive
eq "P2: any rr-consumed status is consumed" "$(nal)" 0
preset; pjson TK-2
pdrive
eq "P3: no row pages" "$(nal)" 1
grep -q 'staleremote:ts:TK-2.json' "$T/alerts.txt" && ok || bad "P3: the alert key: $(cat "$T/alerts.txt")"
[ "$(cnt consumed "$PH/logs/pipeline-health.log")" = 0 ] && ok || bad "P3: no consumed line when nothing was consumed"
preset; pjson TK-3; seed rr-relay "ts/TK-3@pool-ts-TK-3-20261104" parked
pdrive
eq "P4: an rr-relay row alone still pages" "$(nal)" 1
preset; pjson TK-4; seed rr-consumed "ts/TK-4@pool-ts-TK-4-20261104" staged; : > "$LEDGER/.row-down"
pdrive
eq "P5: an outage pages as today" "$(nal)" 1
preset; pjson TK-5 1; pjson TK-6 1
seed rr-consumed "ts/TK-5@pool-ts-TK-5-20261104" staged; seed rr-consumed "ts/TK-6@pool-ts-TK-6-20261104" staged
pdrive STALEREMOTE_LEDGER_READS=1
eq "P6: cap 1 -> one rr-consumed read" "$(cnt rr-consumed "$LEDGER/.reads")" 1
eq "P6: the json past the cap pages" "$(nal)" 1
preset; pjson TK-1; seed rr-consumed "ts/TK-1@pool-ts-TK-1-20261104" staged
pdrive NORR=1
eq "P7: no lib -> the page as today" "$(nal)" 1
[ ! -s "$PH/logs/pipeline-health.log" ] && ok || bad "P7: no lib writes no new line: $(cat "$PH/logs/pipeline-health.log")"
eq "P7: no lib reads nothing" "$(cnt rr-consumed "$LEDGER/.reads")" 0
preset; pjson TK-7; mkdir -p "$PH/builds/pool-ts-TK-7-20261104"; : > "$PH/builds/pool-ts-TK-7-20261104/RELAYED"
pdrive
eq "P7: a RELAYED sibling costs 0 reads" "$(cnt rr-consumed "$LEDGER/.reads")" 0

# ═════════════════════════════════════════════════════════════════════════════
# B1-B9 — builds-retention keeps a pool dir whose sent json is still owed
# ═════════════════════════════════════════════════════════════════════════════
NOWB=1792000000; DAY=86400
BH="$T/bh"
breset() {
  lreset; scratch_rm "$BH"
  mkdir -p "$BH/builds" "$BH/logs" "$BH/locks" "$BH/state" "$BH/flags" "$BH/env"
  ( cd "$DIR" && scratch_install_closure bin/builds-retention.sh "$BH" ) >/dev/null || { echo "setup: could not install builds-retention"; exit 1; }
  # The jobs client is the stub plus a settings reader over $BH/state/settings.json.
  { cat "$T/stub.sh"
    printf 'setting_get() { jq -er --arg k "$1" '"'"'.[$k] // empty'"'"' "%s/state/settings.json" 2>/dev/null; }\n' "$BH"
  } > "$BH/bin/jobs-client.sh"
  printf '#!/bin/bash\nexit 0\n' > "$BH/bin/lane-alert.sh"; chmod +x "$BH/bin/lane-alert.sh"
  printf 'alpha-os  Org/alpha  https://alpha.example  /api/board  2 box-alpha\n' > "$BH/fleet.conf"
  bset '{"builds_retention.dry_run":"0"}'
}
bset() { printf '%s\n' "$1" > "$BH/state/settings.json"; }
bstamp() { date -u -d "@$(( NOWB - $1 * DAY ))" +%Y%m%d%H%M; }
S30=$(bstamp 30); S40=$(bstamp 40)
# bmk <name> <age-days> <result1> — a swept build dir (COMMENTED).
bmk() {
  local d="$BH/builds/$1"; mkdir -p "$d"
  printf '%s\n' "$3" > "$d/RESULT"; printf '{"ticket_id":"t-%s"}\n' "$1" > "$d/job.json"; : > "$d/COMMENTED"
  touch -d "@$(( NOWB - $2 * DAY ))" "$d"/* "$d"
}
brun() {
  ( export HARNESS="$BH" FLEET_CONF="$BH/fleet.conf" BUILDS_RETENTION_NOW="$NOWB" LANE_GATE_NOW="$NOWB" \
      LEDGER BOX_NAME=hub BUILDS_RETENTION_TICKET_STATE_FILE="$BH/state/tks.tsv"
    "$BH/bin/builds-retention.sh" ) > "$T/brun.out" 2>&1
}
kept() { [ -d "$BH/builds/$1" ]; }
rline() { grep ' relay ' "$BH/logs/builds-retention.log" | tail -1; }
rfield() { rline | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
MERGED="PR_MERGED https://github.com/o/alpha/pull/1"

breset; bmk "pool-alpha-os-TK-1-$S30" 30 "$MERGED"; seed rr-relay "alpha-os/TK-1@pool-alpha-os-TK-1-$S30" parked
brun
kept "pool-alpha-os-TK-1-$S30" && ok || bad "B1: parked + no rr-consumed must keep the dir: $(cat "$T/brun.out")"
eq "B1: kept relay-parked" "$(rfield relay-parked)" 1
eq "B1: one relay read" "$(rfield relay_reads)" 1
tail -1 "$BH/logs/builds-retention.log" | grep -q ' run ' && ok || bad "B1: the run line stays the last line"

breset; bmk "pool-alpha-os-TK-2-$S30" 30 "$MERGED"
seed rr-relay "alpha-os/TK-2@pool-alpha-os-TK-2-$S30" parked; seed rr-consumed "alpha-os/TK-2@pool-alpha-os-TK-2-$S30" staged
brun
kept "pool-alpha-os-TK-2-$S30" && bad "B2: parked + consumed staged must move" || ok
breset; bmk "pool-alpha-os-TK-3-$S30" 30 "$MERGED"; seed rr-relay "alpha-os/TK-3@pool-alpha-os-TK-3-$S30" staged
brun
kept "pool-alpha-os-TK-3-$S30" && bad "B3: rr-relay staged must move" || ok
breset; bmk "pool-alpha-os-TK-4-$S30" 30 "$MERGED"
brun
kept "pool-alpha-os-TK-4-$S30" && bad "B4: no row must move" || ok
breset; bmk "alpha-os-TK-5-$S30" 30 "$MERGED"; seed rr-relay "alpha-os/TK-5@alpha-os-TK-5-$S30" parked
brun
kept "alpha-os-TK-5-$S30" && bad "B5: a non-pool dir with a parked row must move" || ok
eq "B5: a non-pool dir costs 0 reads" "$(cnt . "$LEDGER/.reads")" 0
breset; bmk "pool-alpha-os-TK-6-$S30" 30 "$MERGED"; seed rr-relay "alpha-os/TK-6@pool-alpha-os-TK-6-$S30" parked; : > "$LEDGER/.row-down"
brun
kept "pool-alpha-os-TK-6-$S30" && bad "B6: an outage must move (today's answer)" || ok
breset; bset '{"builds_retention.dry_run":"0","builds_retention.relay_reads_max":"1"}'
bmk "pool-alpha-os-TK-7-$S40" 40 "$MERGED"; seed rr-relay "alpha-os/TK-7@pool-alpha-os-TK-7-$S40" parked
bmk "pool-alpha-os-TK-8-$S30" 30 "$MERGED"; seed rr-relay "alpha-os/TK-8@pool-alpha-os-TK-8-$S30" parked
brun
kept "pool-alpha-os-TK-7-$S40" && ok || bad "B7: the first group (oldest) is kept"
kept "pool-alpha-os-TK-8-$S30" && bad "B7: the group past the cap must move" || ok
eq "B7: relay_deferred=1" "$(rfield relay_deferred)" 1
eq "B7: relay_reads=1" "$(rfield relay_reads)" 1
breset; bmk "pool-alpha-os-TK-9-$S40" 40 "FAILED build died"; seed rr-relay "alpha-os/TK-9@pool-alpha-os-TK-9-$S40" parked
bmk "pool-alpha-os-TK-10-$S40" 40 "FAILED build died"
brun
kept "pool-alpha-os-TK-9-$S40" && ok || bad "B8: rule 2 (settled) keeps on B1's facts: $(tail -2 "$BH/logs/builds-retention.log")"
kept "pool-alpha-os-TK-10-$S40" && bad "B8: rule 2 with no row moves (all-terminal)" || ok
breset; bset '{"builds_retention.dry_run":"0","builds_retention.relay_reads_max":"0"}'
bmk "pool-alpha-os-TK-11-$S30" 30 "$MERGED"; seed rr-relay "alpha-os/TK-11@pool-alpha-os-TK-11-$S30" parked
brun
kept "pool-alpha-os-TK-11-$S30" && bad "B9: relay_reads_max=0 reads nothing and keeps nothing" || ok
eq "B9: cap 0 reads nothing" "$(cnt . "$LEDGER/.reads")" 0

# ═════════════════════════════════════════════════════════════════════════════
# S1-S8 — the staging relay loop: a json this project consumed is not staged twice
# ═════════════════════════════════════════════════════════════════════════════
SH_="$T/sh"; SP=project-3; SRR="$SH_/state/remote-results/$SP"
sreset() {
  lreset; scratch_rm "$SH_"; mkdir -p "$SH_/builds" "$SH_/logs" "$SH_/flags" "$SRR"
}
# sjson <KEY> <build_dir> [result] — the relay json the pool push delivers.
sjson() {
  jq -nc --arg k "$1" --arg bd "$2" --arg r "${3:-PR_CREATED https://github.com/o/r/pull/1}" \
    '{key:$k,ticket_id:"1",result:$r,pr_url:"",tier:"",build_dir:$bd,machine_build_dir:"",ingested_at:"2026-11-04 10:00:00Z",source:"pool"}' > "$SRR/$1.json"
}
tick() {
  ( export HARNESS="$SH_" PROJECT="$SP" LOG="$SH_/logs/$SP.log" ALERTS="$SH_/logs/ALERTS.log" \
           STAMP=2026-11-04T10:00:00Z JOBS_BOX=box-fixture
    . "$T/stub.sh"
    . "$DIR/bin/lib/rt/staging.sh" || exit 1
    rt_stage ) >>"$T/tick.log" 2>&1
}
sdirs() { ls -d "$SH_/builds/$SP-$1-remote"* 2>/dev/null | wc -l | tr -d ' '; }
SBD=pool-project-3-TK-1-20261104
s_case() { # s_case <name> <want staged dirs> — TK-1 json, then a tick
  tick
  eq "$1: staged dirs" "$(sdirs TK-1)" "$2"
  [ -f "$SRR/.handled/TK-1.json" ] && ok || bad "$1: the json must be consumed into .handled/"
}
sreset; sjson TK-1 "$SBD"; seed rr-consumed "$SP/TK-1@$SBD" staged
s_case "S1 consumed staged" 0
eq "S1: the log line" "$(cnt "relay json for TK-1 (build $SBD) was already consumed on staged per its rr-consumed row — consumed, not staged twice (BH-8364)" "$SH_/logs/$SP.log")" 1
sreset; sjson TK-1 "$SBD"; seed rr-consumed "$SP/TK-1@$SBD" duplicate
s_case "S2 consumed duplicate" 0
sreset; sjson TK-1 "$SBD"; seed rr-consumed "$SP/TK-1@$SBD" empty
s_case "S3 consumed empty" 1
sreset; sjson TK-1 "$SBD"; seed rr-consumed "$SP/TK-1@$SBD" badjson
s_case "S4 consumed badjson" 1
sreset; sjson TK-1 "$SBD"
s_case "S5 no row" 1
[ "$(cnt 'rr-consumed row' "$SH_/logs/$SP.log")" = 0 ] && ok || bad "S5: no consumed line when nothing was consumed"
sreset; sjson TK-1 "$SBD"; seed rr-consumed "$SP/TK-1@$SBD" staged; : > "$LEDGER/.row-down"
s_case "S6 outage" 1
sreset; sjson TK-1 "pool-project-3-TK-1-20261105"; seed rr-consumed "$SP/TK-1@$SBD" staged
s_case "S7 same KEY other build" 1
sreset; sjson TK-1 "$SBD"; seed rr-consumed "other-os/TK-1@$SBD" staged
s_case "S8 another project's row" 1

# ═════════════════════════════════════════════════════════════════════════════
# F1-F9 — fleet-slo counts the remote lanes the hub lost both copies of
# ═════════════════════════════════════════════════════════════════════════════
FH="$T/fh"
NOWF=$(date +%s)   # fleet-slo reads the wall clock; every row is placed relative to it
iso() { date -u -d "@$(( NOWF - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
freset() {
  lreset; scratch_rm "$FH"
  mkdir -p "$FH/logs" "$FH/flags" "$FH/builds" "$FH/state/remote-results/demo"
  ( cd "$DIR" && scratch_install_closure bin/fleet-slo.sh "$FH" ) >/dev/null || { echo "setup: could not install fleet-slo"; exit 1; }
  cp "$DIR/bin/result-prefix-ok.sh" "$FH/bin/"
  { cat "$T/stub.sh"; echo 'lanes_list() { return 1; }'; } > "$FH/bin/jobs-client.sh"
  printf '#!/bin/bash\nexit 0\n' > "$FH/bin/lane-alert.sh"; chmod +x "$FH/bin"/*.sh
  printf 'SLO_REFUSAL_MIN_LAUNCHES 4\n' > "$FH/flags/slo.conf"
}
frun() { ( export HARNESS="$FH" SLO_CONF="$FH/flags/slo.conf" LEDGER; env "$@" bash "$FH/bin/fleet-slo.sh" ) >/dev/null 2>&1; }
fdet() { jq -r --arg s "$1" '.slos[] | select(.slo==$s) | .detail' "$FH/state/slo/status.json" 2>/dev/null; }
# frow <key> <created-ago-s> <result> [updated-ago-s]
frow() {
  local c; c=$(iso "$2")
  seed rr-relay "$1" parked "$(jq -nc --arg r "$3" '{result:$r}')" "$c"
  [ -n "${4:-}" ] && { local f; f=$(rowf rr-relay "$1"); jq -c --arg u "$(iso "$4")" '.updated_at=$u' "$f" > "$f.t" && mv "$f.t" "$f"; }
  return 0
}
freset; frow "demo/BH-1@pool-demo-BH-1-20261104" 600 "BUILD_FAILED died"
frun
case "$(fdet lane_death)" in "1 of 1 lanes"*) ok ;; *) bad "F1: lane_death detail: $(fdet lane_death)" ;; esac
grep -q 'BH-1(row)' <<<"$(fdet lane_death)" && ok || bad "F1: the death is named <KEY>(row): $(fdet lane_death)"
case "$(fdet build_refusal)" in "0 of 1 build attempts"*) ok ;; *) bad "F1: SLO 1 counts the launch: $(fdet build_refusal)" ;; esac
grep -q 'kind=rr-relay&limit=200$' "$LEDGER/.reqs" && ok || bad "F1: one list call with the default limit: $(cat "$LEDGER/.reqs" 2>/dev/null)"
freset; frow "demo/BH-2@pool-demo-BH-2-20261104" 600 "BUILD_FAILED died"; mkdir -p "$FH/builds/pool-demo-BH-2-20261104"
frun
case "$(fdet lane_death)" in "0 of 0 lanes"*) ok ;; *) bad "F2: a hub dir means the file loop owns it: $(fdet lane_death)" ;; esac
freset; frow "demo/BH-3@pool-demo-BH-3-20261104" 600 "BUILD_FAILED died"
echo '{"key":"BH-3"}' > "$FH/state/remote-results/demo/BH-3.json"; touch -d "@$(( NOWF - 30 * 86400 ))" "$FH/state/remote-results/demo/BH-3.json"
frun
case "$(fdet lane_death)" in "0 of 0 lanes"*) ok ;; *) bad "F3: a hub json means the file loop owns it: $(fdet lane_death)" ;; esac
freset; frow "demo/BH-4@pool-demo-BH-4-20261104" $(( 400 * 60 )) "BUILD_FAILED died" 60
frun
case "$(fdet lane_death)" in "0 of 0 lanes"*) ok ;; *) bad "F4: created before the cut, updated after: $(fdet lane_death)" ;; esac
freset; frow "demo/BH-5-noat" 600 "BUILD_FAILED died"
frun
case "$(fdet lane_death)" in "0 of 0 lanes"*) ok ;; *) bad "F5: a key with no @: $(fdet lane_death)" ;; esac
freset; frow "demo/BH-6@pool-demo-BH-6-20261104" 600 "BUILD_FAILED died"
frun SLO_RELAY_ROWS_LIMIT=0
[ "$(cnt 'kind=rr-relay' "$LEDGER/.reqs")" = 0 ] && ok || bad "F6: SLO_RELAY_ROWS_LIMIT=0 must send no ledger request"
case "$(fdet lane_death)" in "0 of 0 lanes"*) ok ;; *) bad "F6: no read counts nothing: $(fdet lane_death)" ;; esac
freset; frow "demo/BH-7@pool-demo-BH-7-20261104" 600 "BUILD_FAILED died"; echo '{"jobs":[]}' > "$LEDGER/.list"
frun
case "$(fdet lane_death)" in "0 of 0 lanes"*) ok ;; *) bad "F7: a jobs body counts nothing: $(fdet lane_death)" ;; esac
freset; frow "demo/BH-8@pool-demo-BH-8-20261104" 600 "PR_CREATED https://github.com/o/r/pull/8"
frun
case "$(fdet lane_death)" in "0 of 1 lanes"*) ok ;; *) bad "F8: PR_CREATED is a lane, not a death: $(fdet lane_death)" ;; esac
freset; frow "demo/BH-9@pool-demo-BH-9-20261104" $(( 120 * 60 )) "PR_CREATED x"
frun
case "$(fdet lane_death)" in "0 of 1 lanes"*) ok ;; *) bad "F9: inside the lane window: $(fdet lane_death)" ;; esac
case "$(fdet build_refusal)" in "0 of 0 build attempts"*) ok ;; *) bad "F9: outside the 60m launch window: $(fdet build_refusal)" ;; esac
freset; frow "demo/BH-10@pool-demo-BH-10-20261104" 600 "BUILD_FAILED died"
F10F=$(rowf rr-relay "demo/BH-10@pool-demo-BH-10-20261104"); jq -c 'del(.created_at)' "$F10F" > "$F10F.t" && mv "$F10F.t" "$F10F"
# A lane window wide enough that today's 00:00Z (what `date -d ""` or `-d -` answers) is inside it.
frun SLO_LANE_WINDOW_MIN=5000
case "$(fdet lane_death)" in "0 of 0 lanes"*) ok ;; *) bad "F10: a row with no created_at is not counted: $(fdet lane_death)" ;; esac

# ═════════════════════════════════════════════════════════════════════════════
# R1 — the round trip: park through pool_push_full, consume through rt_stage
# ═════════════════════════════════════════════════════════════════════════════
SP="$WP"; SRR="$SH_/state/remote-results/$SP"
sreset; wreset; push >/dev/null
DELIV="$T/box/$WP/BH-1.json"
[ -s "$DELIV" ] && ok || bad "R1: the push delivered no json"
cp "$DELIV" "$SRR/BH-1.json"; cp "$DELIV" "$T/r1-copy.json"
tick
eq "R1: the box stages the json once" "$(sdirs BH-1)" 1
eq "R1: rrr_consumed on the delivered json = staged" "$(lib rrr_consumed "$WP" "$T/r1-copy.json")" staged
eq "R1: rrr_open on the hub dir name -> rc 2" "$(ro "$WP" BH-1 "$WBD")" 2
grep -q "^$WP"$'\t'"BH-1"$'\t'"$WBD"$'\t'"staged"$'\t' <<<"$(lib rrr_list 10)" && ok || bad "R1: rrr_list: $(lib rrr_list 10)"
cp "$DELIV" "$SRR/BH-1.json"
tick
eq "R1: a re-push of the same json is not staged twice" "$(sdirs BH-1)" 1

# ═════════════════════════════════════════════════════════════════════════════
# C1 — catalog/state-paths.json names the rows. The catalog is a git-ignored
# render of catalog/state-paths.d/ (BH-8986), so compose it into the scratch
# tree; a fresh checkout has no catalog/state-paths.json.
# ═════════════════════════════════════════════════════════════════════════════
if "$DIR/bin/state-paths-build.sh" --repo "$DIR" --compose --to "$T/sp.json" >/dev/null 2>>"$T/err.txt"; then
  jq -e '.paths[] | select(.path=="remote-results") | (.class=="rows") and (.authority|test("rr-relay")) and (.authority|test("rr-consumed"))' \
    "$T/sp.json" >/dev/null && ok || bad "C1: the remote-results row must name rr-relay and rr-consumed"
else
  bad "C1: bin/state-paths-build.sh --compose failed"
fi

[ -s "$T/err.txt" ] && grep -v '^$' "$T/err.txt" | head -5 | sed 's/^/stderr: /'
echo "rr-relay-readers.bh-8364: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
