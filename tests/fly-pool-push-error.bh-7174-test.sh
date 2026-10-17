#!/bin/bash
# tests/fly-pool-push-error.bh-7174-test.sh — BH-7174: a failed mput in
# bin/fly-pool.sh writes flyctl's error text to fly-pool.log, once per machine.
#
# Until BH-7174 mexec sent flyctl's stderr to /dev/null and mput sent stdout
# there too, so a failed env/job push logged "FAILED" with no reason (the
# project-6-os pool, 2026-10-16 21:35Z-21:42Z).
#
# PINNED (the REAL mexec/mput/mput_fail_note, lifted from bin/fly-pool.sh by the
# `# >>> mput error note` markers; FLY is a fake flyctl, `say` is the real shape):
#   T1  a failed push logs `<MID>: push of <path> FAILED rc=1: <flyctl stderr>`.
#   T2  a push that works logs nothing and leaves no marker.
#   T3  4 failed pushes on one machine log exactly 1 line.
#   T4  a timeout (rc 124) says rc=124 and (timeout 90s).
#   T5  two machines that fail log one line each.
#   T6  flyctl that prints nothing: (flyctl printed nothing).
#   T7  rc passes through (0 and 1); no temp error file is left behind.
#   T8  the machine's cleanup line (lifted from the file) removes the marker.
#   T9  the line matches the pool-builders regex in catalog/components.tsv.
#   T10 any other mexec caller: stdout is data, stderr still goes nowhere.
#   T11 no $POOL dir: rc 1, no crash.
#   F1-F4 the secret filter: a credential withholds the text, a 40+ base64 run
#         is replaced, a 39-char run and a plain error are kept.
# Run against another fly-pool.sh: FLY_POOL_SRC=<file> bash tests/fly-pool-push-error.bh-7174-test.sh
# Run from anywhere: bash tests/fly-pool-push-error.bh-7174-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRCF="${FLY_POOL_SRC:-$DIR/bin/fly-pool.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SRCTXT=$(cat "$SRCF")
BLOCK=$(printf '%s\n' "$SRCTXT" | sed -n '/^# >>> mput error note/,/^# <<< mput error note/p')
if [ -n "$BLOCK" ]; then ok; else
  bad "the '# >>> mput error note' block is not in $SRCF (lifting the bare mexec/mput instead)"
  BLOCK=$(printf '%s\n' "$SRCTXT" | awk 'index($0,"mexec() {")==1||index($0,"mput() {")==1{f=1} f{print} f&&$0=="}"{f=0}')
fi
grep -q '^mexec() {' <<<"$BLOCK" && grep -q '^mput() {' <<<"$BLOCK" && ok \
  || bad "mexec/mput not found in $SRCF"

# fake flyctl: stderr FAKE_ERR, stdout FAKE_OUT, rc FAKE_RC
cat > "$T/flyctl" <<'FAKE'
#!/bin/bash
[ -n "${FAKE_ERR:-}" ] && printf '%s\n' "$FAKE_ERR" >&2
[ -n "${FAKE_OUT:-}" ] && printf '%s\n' "$FAKE_OUT"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/flyctl"

printf '%s\n' "$BLOCK" > "$T/block.sh"
cat > "$T/run.sh" <<EOF
set -uo pipefail
FLY="$T/flyctl" APP=pool-fixture P=fixture
POOL="\${POOL_DIR:-$T/pool}" LOG="$T/fly-pool.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "\$(STAMP) [pool/\$P] \$*" >> "\$LOG"; }
[ "\${FAKE_TIMEOUT:-0}" = 1 ] && timeout() { shift; "\$@"; return 124; }
. "$T/block.sh"
"\$@"
EOF
printf 'payload\n' > "$T/job.json"
export TMPDIR="$T/tmp"
reset() { rm -rf "$T/pool" "$TMPDIR"; mkdir -p "$T/pool" "$TMPDIR"; : > "$T/fly-pool.log"; }
# put <mid> [VAR=value ...] -> RC
put() { local mid="$1"; shift
  env "$@" bash "$T/run.sh" mput "$mid" "$T/job.json" /run/harness/job.json 2>"$T/run.err"; RC=$?; }
lines() { grep -c 'push of .* FAILED rc=' "$T/fly-pool.log"; }

# ── T1 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=1 FAKE_ERR='Error: tunnel unavailable for org project-6'
[ "$RC" = 1 ] && ok || bad "T1: mput must return 1, got $RC ($(cat "$T/run.err"))"
[ "$(lines)" = 1 ] && grep -q '\[pool/fixture\] m1: push of /run/harness/job.json FAILED rc=1: Error: tunnel unavailable for org project-6$' "$T/fly-pool.log" && ok \
  || bad "T1: one line with the flyctl error, got: $(cat "$T/fly-pool.log")"

# ── T2 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=0 FAKE_ERR='Connecting to fdaa::1... complete'
[ "$RC" = 0 ] && ok || bad "T2: mput must return 0, got $RC"
[ ! -s "$T/fly-pool.log" ] && ok || bad "T2: a push that works must log nothing, got: $(cat "$T/fly-pool.log")"
[ ! -e "$T/pool/.m1.puterr" ] && ok || bad "T2: a push that works must leave no marker"

# ── T3 ──────────────────────────────────────────────────────────────────────
reset; for _ in 1 2 3 4; do put m1 FAKE_RC=1 FAKE_ERR='Error: boom'; done
[ "$(lines)" = 1 ] && ok || bad "T3: 4 failures on one machine must log 1 line, got $(lines)"

# ── T4 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_TIMEOUT=1 FAKE_ERR='Connecting to fdaa::2...'
[ "$RC" = 124 ] && ok || bad "T4: mput must return 124, got $RC"
grep -q 'FAILED rc=124: Connecting to fdaa::2\.\.\. (timeout 90s)$' "$T/fly-pool.log" && ok \
  || bad "T4: the line must say rc=124 and (timeout 90s), got: $(cat "$T/fly-pool.log")"

# ── T5 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=1 FAKE_ERR='Error: a'; put m2 FAKE_RC=1 FAKE_ERR='Error: b'
[ "$(lines)" = 2 ] && grep -q ' m1: push of .* FAILED rc=1: Error: a$' "$T/fly-pool.log" && grep -q ' m2: push of .* FAILED rc=1: Error: b$' "$T/fly-pool.log" && ok \
  || bad "T5: one line per machine, got: $(cat "$T/fly-pool.log")"

# ── T6 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=1
grep -q 'm1: push of /run/harness/job.json FAILED rc=1: (flyctl printed nothing)$' "$T/fly-pool.log" && ok \
  || bad "T6: an empty stderr must say (flyctl printed nothing), got: $(cat "$T/fly-pool.log")"

# ── T7 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=0; R0=$RC; put m2 FAKE_RC=1 FAKE_ERR=x; R1=$RC
[ "$R0" = 0 ] && [ "$R1" = 1 ] && ok || bad "T7: rc must pass through (0,1), got ($R0,$R1)"
[ -z "$(ls -A "$TMPDIR")" ] && ok || bad "T7: no temp file may stay in TMPDIR, got: $(ls -A "$TMPDIR")"

# ── T8 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=1 FAKE_ERR='Error: one'
RMLINES=$(printf '%s\n' "$SRCTXT" | grep -E '^[[:space:]]*rm -f "\$MF" "\$POOL/\.\$MID\.snapmt"' )
[ "$(printf '%s\n' "$RMLINES" | grep -c 'puterr')" = 2 ] && ok \
  || bad "T8: both 'rm -f \"\$MF\" ...snapmt' cleanup lines must remove .\$MID.puterr, got: $RMLINES"
RM1=$(sed -n 1p <<<"$RMLINES")
( MID=m1 MF="$T/pool/m1.json" POOL="$T/pool"; eval "$RM1" )
put m1 FAKE_RC=1 FAKE_ERR='Error: two'
[ "$(lines)" = 2 ] && grep -q 'FAILED rc=1: Error: two$' "$T/fly-pool.log" && ok \
  || bad "T8: after the cleanup line the next failure must log again, got: $(cat "$T/fly-pool.log")"
AFTER_DESTROY=$(grep -A1 'destroy_machine "\$MID" "env/job push failed for \$KEY"' <<<"$SRCTXT")
grep -q 'rm -f "\$POOL/\.\$MID\.puterr"' <<<"$AFTER_DESTROY" && ok \
  || bad "T8: the env/job failure branch must remove the marker after destroy_machine"

# ── T9 ──────────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=1 FAKE_ERR='Error: x'
RX=$(awk -F'\t' '$1=="pool-builders"{print $2}' "$DIR/catalog/components.tsv")
STRIPPED=$(sed -E 's/^[0-9-]+ [0-9:]+Z //' "$T/fly-pool.log")
[ -n "$RX" ] && grep -Eq "$RX" <<<"$STRIPPED" && ok \
  || bad "T9: the line must match the pool-builders regex '$RX', got: $(cat "$T/fly-pool.log")"

# ── T10 ─────────────────────────────────────────────────────────────────────
reset
RES=$(FAKE_RC=0 FAKE_OUT='RESULT=ok' FAKE_ERR='Connecting...' bash "$T/run.sh" mexec m1 'cat x' 2>"$T/caller.err")
[ "$RES" = 'RESULT=ok' ] && ok || bad "T10: mexec stdout must be only flyctl's stdout, got: '$RES'"
[ ! -s "$T/caller.err" ] && ok || bad "T10: mexec stderr must stay discarded for other callers, got: $(cat "$T/caller.err")"
[ ! -s "$T/fly-pool.log" ] && ok || bad "T10: a plain mexec must log nothing"

# ── T11 ─────────────────────────────────────────────────────────────────────
reset; put m1 POOL_DIR="$T/no-such-pool" FAKE_RC=1 FAKE_ERR='Error: x'
[ "$RC" = 1 ] && ok || bad "T11: no POOL dir must still return 1, got $RC ($(cat "$T/run.err"))"

# ── F1-F4 ───────────────────────────────────────────────────────────────────
reset; put m1 FAKE_RC=1 FAKE_ERR="Error: auth ghp_$(printf 'a%.0s' $(seq 36)) rejected"
grep -q 'FAILED rc=1: reason withheld: flyctl output looked like a credential$' "$T/fly-pool.log" && ! grep -q 'ghp_' "$T/fly-pool.log" && ok \
  || bad "F1: a credential must withhold the text, got: $(cat "$T/fly-pool.log")"
reset; put m1 FAKE_RC=1 FAKE_ERR='Error: ssh: handshake failed: EOF'
grep -q 'FAILED rc=1: Error: ssh: handshake failed: EOF$' "$T/fly-pool.log" && ok \
  || bad "F2: a plain error must be kept, got: $(cat "$T/fly-pool.log")"
B60=$(printf 'QUJD%.0s' $(seq 15))
reset; put m1 FAKE_RC=1 FAKE_ERR="sh: echo $B60 | base64 -d: not found"
grep -q 'FAILED rc=1: sh: echo <base64 withheld> | base64 -d: not found$' "$T/fly-pool.log" && ! grep -Eq '[A-Za-z0-9+/=]{40,}' "$T/fly-pool.log" && ok \
  || bad "F3: a 40+ base64 run must be replaced, got: $(cat "$T/fly-pool.log")"
B39=$(printf 'QUJD%.0s' $(seq 9))QUJ
reset; put m1 FAKE_RC=1 FAKE_ERR="Error: $B39 end"
grep -q "FAILED rc=1: Error: $B39 end\$" "$T/fly-pool.log" && ok \
  || bad "F4: a 39-char run must be kept, got: $(cat "$T/fly-pool.log")"

echo "fly-pool-push-error (BH-7174): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
