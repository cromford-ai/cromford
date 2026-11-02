#!/bin/bash
# tests/queue-scopes-evidence.bh-8052-test.sh — BH-8052 slice C0: the seeded
# queue_partition.mode=enforce row, the conductor's log line on a successful
# scopes upload, and the read-only probe bin/queue-scopes-evidence.sh that the
# live-probe lane runs as `queue-scopes-uploads`.
#
#   S1     a fresh worker/jobs/schema.sql seeds queue_partition.mode=enforce
#   L1-L3  the real mc_enqueue_mergify on the committed (serial) conf with a
#          stub curl: a 200 logs `scopes uploaded … (HTTP 200)`, a 500 logs
#          `scopes not uploaded`, both still label; the probe reads the same
#          log; the key reaches neither the log nor the probe output
#   P1-P8  the probe's decision table, on fixture logs in the format
#          qp_enqueue_step writes
#   P9     the probe writes no file and calls no curl
#   C1     lp_catalog returns the queue-scopes-uploads row unrefused
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/queue-scopes-evidence.bh-8052-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PROBE="$DIR/bin/queue-scopes-evidence.sh"
SLUG=example-org/cromford
HEAD1=aaaaaaaa11111111111111111111111111111111
KEY='fixture-mergify-key-8052'

# ---------- S1 the seeded mode row ---------------------------------------------
python3 -I - "$DIR/worker/jobs/schema.sql" "$T/hub.sqlite" > "$T/s1.err" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[2])
db.executescript(open(sys.argv[1]).read())
db.commit()
r = db.execute("SELECT value FROM settings WHERE key='queue_partition.mode'").fetchone()
print(r[0] if r else "<no row>")
PY
S1=$(tail -1 "$T/s1.err")
[ "$S1" = enforce ] && ok || bad "S1 a fresh schema seeds queue_partition.mode='$S1', want enforce ($(head -3 "$T/s1.err"))"

# ---------- the scratch harness for L and P -------------------------------------
# H is the harness root the conductor and the probe both read.
H="$T/h"; mkdir -p "$H/logs" "$H/state/merge-conductor" "$H/config/mergify/repos" "$T/tmp" "$T/fakebin"
cp "$DIR/config/mergify/repos/cromford.conf" "$H/config/mergify/repos/cromford.conf"
grep -qx 'queue_mode=serial' "$H/config/mergify/repos/cromford.conf" && ok \
  || bad "L0 premise: the committed conf is queue_mode=serial (C1 flips it, not C0)"
M="$T/mergify"; G="$T/gh"; mkdir -p "$M" "$G"
# The stub curl answers $M/code (default 200) and counts its calls in $M/n.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
n=\$(( \$(cat "$M/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$M/n"
cat > /dev/null
printf '%s' "\$(cat "$M/code" 2>/dev/null || echo 200)"
EOF
chmod +x "$T/fakebin/curl"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The stub gh: the PR read is a 404 (the lane is serial, files-unavailable, and
# the upload is the all_scopes barrier), the status POST and the label POST.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"-X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"-X POST repos/"*"/labels"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
calls() { cat "$M/n" 2>/dev/null || echo 0; }
LOG="$H/logs/merge-conductor.log"
ereset() { rm -f "$G"/* "$M"/*; scratch_rm "$H/state/merge-conductor/queue-partition"; : > "$LOG"; }
labelled() { grep -q -- "-X POST repos/$SLUG/issues/41/labels" "$G/calls" 2>/dev/null; }
# enq <head> — the real conductor lib and the real mc_enqueue_mergify, the mode
# row answering enforce. Only Mergify's own answers are replaced.
enq() { (
  export PATH="$T/fakebin:$PATH" HARNESS="$H" TMPDIR="$T/tmp" GH_APP_TOKENS=0 MERGIFY_API_URL=https://mergify.test/v1 MERGIFY_CI_KEY="$KEY"
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }
  mc_queue_state() { printf 'queued'; }
  mc_mergify_witness() { return 0; }
  setting_get() { [ "$1" = queue_partition.mode ] && { printf enforce; return 0; }; return 2; }
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify "$SLUG" "https://github.com/$SLUG/pull/41" "$1"
) 2>"$T/enq.err"; }
# probe [args] — the probe as the live-probe lane runs it: from the root.
probe() { ( cd "$H" && HARNESS="$H" PATH="$T/fakebin:$PATH" bash "$PROBE" "${@:-cromford}" ) 2>"$T/probe.err"; }

# ---------- L1 a 200 PUT through the real enqueue ------------------------------
ereset
OUT=$(enq "$HEAD1"); RC=$?
[ "$RC" = 0 ] && labelled && ok || bad "L1 enforce on a serial conf + 200 enqueues and labels (rc $RC, out $OUT, err $(head -3 "$T/enq.err"))"
[ "$(calls)" = 1 ] && ok || bad "L1 one PUT (calls $(calls))"
grep -q "PARTITION $SLUG#41: scopes uploaded on ${HEAD1:0:12} (HTTP 200)$" "$LOG" && ok \
  || bad "L1 the conductor logs the successful upload with its HTTP code: $(cat "$LOG")"
P=$(probe); PRC=$?
[ "$PRC" = 0 ] && ok || bad "L1 the probe exits 0 after a 200 (rc $PRC): $P $(cat "$T/probe.err")"
L1=$(head -1 <<<"$P")
[[ "$L1" == "queue-scopes $SLUG: queue_mode=serial ok=1 failed=0 ledger=1 newest=ok" ]] && ok || bad "L1 probe line 1: $L1"
grep -q "scopes uploaded on ${HEAD1:0:12} (HTTP 200)" <<<"$P" && ok || bad "L1 the probe prints the log line: $P"
# a re-enqueue on the same head is a ledger hit: one more ok line, no new PUT
enq "$HEAD1" >/dev/null
grep -q "scopes uploaded on ${HEAD1:0:12} (already uploaded)" "$LOG" && [ "$(calls)" = 1 ] && ok \
  || bad "L1 a ledger hit logs 'already uploaded' and makes no PUT (calls $(calls)): $(cat "$LOG")"
P=$(probe); PRC=$?
[ "$PRC" = 0 ] && grep -q 'ok=2 failed=0 ledger=1 newest=ok$' <<<"$(head -1 <<<"$P")" && ok || bad "L1 a ledger hit after a 2xx is still ok (rc $PRC): $(head -1 <<<"$P")"

# ---------- L2 a 500 PUT through the real enqueue ------------------------------
ereset; echo 500 > "$M/code"
OUT=$(enq "$HEAD1"); RC=$?
[ "$RC" = 0 ] && labelled && ok || bad "L2 a 500 on a serial conf still enqueues and labels (rc $RC, out $OUT)"
grep -q "scopes uploaded on" "$LOG" && bad "L2 a 500 logs no success line: $(cat "$LOG")" || ok
grep -q "scopes not uploaded on ${HEAD1:0:12} (HTTP 500)" "$LOG" && ok || bad "L2 the failure line: $(cat "$LOG")"
P=$(probe); PRC=$?
[ "$PRC" = 1 ] && ok || bad "L2 the probe exits 1 after a 500 (rc $PRC): $P"
[ "$(head -1 <<<"$P")" = "queue-scopes $SLUG: queue_mode=serial ok=0 failed=1 ledger=0 newest=failed" ] && ok || bad "L2 probe line 1: $(head -1 <<<"$P")"

# ---------- L3 the key stays out of the log and the probe output --------------
grep -q -- "$KEY" <<<"$(cat "$LOG" "$T/enq.err"; probe)" && bad "L3 the key reached the log or the probe output" || ok

# ---------- P1-P8 the decision table -------------------------------------------
# plog <line>... — a fixture log in the shape mc_log writes: "<stamp> <msg>".
plog() { : > "$LOG"; local l; for l in "$@"; do printf '2026-11-02 14:00:00Z %s\n' "$l" >> "$LOG"; done; }
U="PARTITION $SLUG#41: scopes uploaded on ${HEAD1:0:12}"
N="PARTITION $SLUG#41: scopes not uploaded on ${HEAD1:0:12}"
NS="the queue is serial, enqueue proceeds"
# case <id> <want-rc> <want-newest> <line>...
case_() {
  local id="$1" wrc="$2" wn="$3"; shift 3
  plog "$@"; local out rc
  out=$(probe); rc=$?
  [ "$rc" = "$wrc" ] && ok || bad "$id exit $rc, want $wrc: $out"
  [ -z "$wn" ] && return 0
  grep -q " newest=$wn\$" <<<"$(head -1 <<<"$out")" && ok || bad "$id newest, want $wn: $(head -1 <<<"$out")"
}
case_ P1  0 ok "$U (HTTP 200)"
case_ P2  0 ok "$N (HTTP 403); $NS" "$U (HTTP 204)"
case_ P3  1 failed "$U (HTTP 200)" "$N (HTTP 500); $NS"
case_ P4a 1 ok-unproven "$U (already uploaded)"
case_ P4b 0 ok "$U (HTTP 200)" "$U (already uploaded)"
case_ P5  1 failed "$N (MERGIFY_CI_KEY not set); $NS"
case_ P6a 1 none "PARTITION $SLUG#41@${HEAD1:0:12} lane=scoped scopes=1 reason=1 impact suite(s)"
case_ P6b 1 none "PARTITION example-org/project-5#4: scopes uploaded on ${HEAD1:0:12} (HTTP 200)"
case_ P6c 1 none "PARTITION example-org/cromford-x#4: scopes uploaded on ${HEAD1:0:12} (HTTP 200)"
case_ P7  0 ok "ERROR example-org/project-3#9: something else broke" "$U (HTTP 200)" "ERROR another lane"
case_ P8a 1 failed "$U (HTTP 2000)"
case_ P8b 1 failed "$U (HTTP 20)"
case_ P8c 1 failed "$U (HTTP 302)"
# P6b also counts: another slug's lines are not ours
plog "PARTITION example-org/project-5#4: scopes uploaded on ${HEAD1:0:12} (HTTP 200)"
[ "$(probe | head -1)" = "queue-scopes $SLUG: queue_mode=serial ok=0 failed=0 ledger=0 newest=none" ] && ok || bad "P6 another slug counts nothing: $(probe | head -1)"
# exit 2: no log, a conf with no slug=, no conf, a bad argument
scratch_rm "$LOG"
probe >/dev/null; [ "$?" = 2 ] && ok || bad "P8 an absent log is exit 2"
: > "$LOG"
cp "$H/config/mergify/repos/cromford.conf" "$T/conf.bak"
grep -v '^slug=' "$T/conf.bak" > "$H/config/mergify/repos/cromford.conf"
probe >/dev/null; [ "$?" = 2 ] && ok || bad "P8 a conf with no slug= is exit 2"
cp "$T/conf.bak" "$H/config/mergify/repos/cromford.conf"
probe no-such-repo >/dev/null; [ "$?" = 2 ] && ok || bad "P8 a missing conf is exit 2"
probe ../cromford >/dev/null; [ "$?" = 2 ] && ok || bad "P8 a repo argument with a / is exit 2"

# ---------- P9 the probe writes nothing and calls nothing ----------------------
plog "$U (HTTP 200)"
rm -f "$M/n"
touch -d '2026-01-01 00:00:00' "$T/marker"
find "$H" -exec touch -d '2025-12-31 00:00:00' {} +
probe >/dev/null
[ "$(calls)" = 0 ] && ok || bad "P9 the probe called curl ($(calls) calls)"
NEWER=$(find "$H" -newer "$T/marker")
[ -z "$NEWER" ] && ok || bad "P9 the probe changed files: $NEWER"

# ---------- C1 the catalog row ---------------------------------------------------
CAT=$( ( . "$DIR/bin/lib/live-probes.sh"; lp_catalog "$DIR/catalog/live-probes.tsv" ) 2>"$T/cat.err")
grep -qxF "queue-scopes-uploads$(printf '\t')cmd$(printf '\t')bin/queue-scopes-evidence.sh cromford" <<<"$CAT" && ok \
  || bad "C1 lp_catalog returns the queue-scopes-uploads row: $(grep queue-scopes <<<"$CAT")"
grep -q 'queue-scopes-uploads' "$T/cat.err" && bad "C1 lp_catalog refused the row: $(cat "$T/cat.err")" || ok
[ -x "$PROBE" ] && ok || bad "C1 the lane runs ./bin/queue-scopes-evidence.sh, so it must be executable"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
