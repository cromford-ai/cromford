#!/bin/bash
# tests/lane-gate-no-root.bh-2613-test.sh — BH-2649 (BH-2613.1): with no root
# (HARNESS, H, MC_H and JOBS_HARNESS all unset), bin/lib/lane-gate.sh,
# bin/lib/jobs/req.sh, bin/lib/endpoints.sh and the three cost libs build no
# path from /root/harness or from "", write nothing, and answer exactly what
# they answer for an unreadable state dir. With a root, they use it. The
# contract is docs/notes/2026-09-26-BH-2613-lib-root-resolution.md, rules 1-6.
#
#   A1  _lg_h: "" with no root, $S under HARNESS=$S, $S under H=$S
#   A2  set -e; lib_env_apply fleet-cooldown: prints ok, rc 0, no file in HOME/cwd
#   A3  the same under xtrace: 0 /root/harness in the trace
#   A4  lane_gate_or_exit with pause files planted in the cwd: returns, writes
#       nothing; a client-reported pause still exits and stamps nothing; with
#       HARNESS=$S and $S/flags/lane-off-x it exits and stamps .paused
#   A5  _lg_harness_commit: no root = rc 1, nothing printed, no /root/harness-checkout
#       read; $S/../harness-checkout/HARNESS_COMMIT with a root; HARNESS_CHECKOUT wins
#   A6  _jobs_log / _jobs_not_configured with JOBS_HARNESS="": rc 0, silent, no file,
#       and sourcing req.sh reads no root-relative /state/box-name
#   A7  _jobs_log with $JOBS_HARNESS/logs not writable (as nobody): rc 0, silent,
#       no ALERTS.log, no flags/ dir
#   A8  endpoint_url with no root: sibling lane-gate, 0 /root/harness in the trace,
#       ENDPOINT_FOO answers
#   A9  _cost_row_root, _cost_rows_root, _CB_H: "" with no root, $S under HARNESS/H
#   A10 cost_parity_alert rc 1 / _cost_rows_log rc 0 / cost_budget_rates_tsv from
#       the sibling catalog, none of them writing a file
#   A11 cost-rows-read.sh run directly resolves its own install root; sourced, it does not
#   A12 cost_transcript_enabled: rc 0 with no root, rc 1 with $S/flags/transcript-cost-off;
#       cost_row_box_id with no root answers COST_ROWS_BOX
#
# Nothing here reaches a worker: every no-root case has no client to load, and
# JOBS_URL points at a closed local port for anything that would.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-gate-no-root.bh-2613-test.sh
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd -P)
LIB="$DIR/bin/lib"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1${3:+ — $3}"; fi; }

mkdir -p "$T/home" "$T/cwd" "$T/h"
S="$T/h"
# nr <cmd…> — a no-root process: HOME and cwd are scratch dirs, every root var unset.
nr() {
  ( cd "$T/cwd" && env -u HARNESS -u H -u MC_H -u JOBS_HARNESS -u HARNESS_CHECKOUT \
      -u LANE_REGISTRY -u HARNESS_SECRET -u MODEL_PRICES -u COST_CAPS_CONF \
      HOME="$T/home" JOBS_URL=http://127.0.0.1:9 JOBS_RETRIES=0 "$@" )
}
snap() { find "$T/home" "$T/cwd" 2>/dev/null | sort; }

# ---------- A1 _lg_h ------------------------------------------------------------
out=$(nr bash -c '. "$1/lane-gate.sh"; printf "[%s]" "$(_lg_h)"' _ "$LIB" 2>&1)
chk "A1 _lg_h with no root is empty" "$([ "$out" = "[]" ]; echo $?)" "got $out"
out=$(nr env HARNESS="$S" bash -c '. "$1/lane-gate.sh"; _lg_h' _ "$LIB" 2>&1)
chk "A1 _lg_h under HARNESS=\$S" "$([ "$out" = "$S" ]; echo $?)" "got $out"
out=$(nr env H="$S" bash -c '. "$1/lane-gate.sh"; _lg_h' _ "$LIB" 2>&1)
chk "A1 _lg_h under H=\$S" "$([ "$out" = "$S" ]; echo $?)" "got $out"

# ---------- A2 lib_env_apply under set -e ---------------------------------------
before=$(snap)
out=$(nr bash -c 'set -e; . "$1/lane-gate.sh"; lib_env_apply fleet-cooldown; echo ok' _ "$LIB" 2>&1); rc=$?
chk "A2 lib_env_apply under set -e prints ok, rc 0" "$([ "$rc" = 0 ] && [ "$out" = ok ]; echo $?)" "rc=$rc out=[$out]"
chk "A2 lib_env_apply creates no file in HOME or cwd" "$([ "$(snap)" = "$before" ]; echo $?)"

# ---------- A3 xtrace -----------------------------------------------------------
nr bash -c 'exec 9>"$2"; BASH_XTRACEFD=9; set -x; set -e; . "$1/lane-gate.sh"; lib_env_apply fleet-cooldown; echo ok' \
  _ "$LIB" "$T/a3.trace" >/dev/null 2>&1
n=$(grep -c '/root/harness' "$T/a3.trace"); [ -s "$T/a3.trace" ] || n="empty trace"
chk "A3 lib_env_apply xtrace has 0 /root/harness" "$([ "$n" = 0 ]; echo $?)" "count=$n"

# ---------- A4 the gate with pause files planted in the cwd ---------------------
mkdir -p "$T/cwd/flags" "$T/cwd/state/lane-gate"
touch "$T/cwd/flags/all-off" "$T/cwd/flags/lane-off-x"
printf '{"active":1,"fetched_at":%s}\n' "$(date -u +%s)" > "$T/cwd/state/lane-gate/lane-off-x.json"
before=$(snap)
out=$(nr bash -c '. "$1/lane-gate.sh"; lane_gate_or_exit x; echo returned' _ "$LIB" 2>&1); rc=$?
chk "A4 no root: lane_gate_or_exit returns (cwd flags are never read)" "$([ "$rc" = 0 ] && [ "$out" = returned ]; echo $?)" "rc=$rc out=[$out]"
chk "A4 no root: nothing written in HOME or cwd" "$([ "$(snap)" = "$before" ] && [ ! -e "$T/home/state" ]; echo $?)"
rm -rf "$T/cwd/flags" "$T/cwd/state"
# A pause the client reports (flag_active) still stops the lane with no root, and
# stamps nothing: not in HOME, not in the cwd, not as a root-relative /state.
had_state=0; [ -e /state ] && had_state=1
before=$(snap)
out=$(nr bash -c 'flag_active() { [ "$1" = lane-off-x ]; }; . "$1/lane-gate.sh"; lane_gate_or_exit x; echo returned' _ "$LIB" 2>&1); rc=$?
chk "A4 no root, client says paused: exits 0 before the body" "$([ "$rc" = 0 ] && [ -z "$out" ]; echo $?)" "rc=$rc out=[$out]"
chk "A4 no root, client says paused: no stamp anywhere" "$([ "$(snap)" = "$before" ] && { [ "$had_state" = 1 ] || [ ! -e /state ]; }; echo $?)"
mkdir -p "$S/flags"; touch "$S/flags/lane-off-x"
out=$(nr env HARNESS="$S" bash -c '. "$1/lane-gate.sh"; lane_gate_or_exit x; echo returned' _ "$LIB" 2>&1); rc=$?
chk "A4 control: HARNESS=\$S with lane-off-x exits 0 before the body" "$([ "$rc" = 0 ] && [ -z "$out" ]; echo $?)" "rc=$rc out=[$out]"
chk "A4 control: the .paused stamp lands under \$S" "$([ -s "$S/state/lane-gate/x.paused" ]; echo $?)"
scratch_rm "$S/flags"; scratch_rm "$S/state"; scratch_rm "$S/logs"

# ---------- A5 _lg_harness_commit -----------------------------------------------
SHA1=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
out=$(nr bash -c 'exec 9>"$2"; BASH_XTRACEFD=9; set -x; . "$1/lane-gate.sh"; _lg_harness_commit' _ "$LIB" "$T/a5.trace" 2>/dev/null); rc=$?
chk "A5 no root, no HARNESS_CHECKOUT: rc 1, no sha" "$([ "$rc" = 1 ] && [ -z "$out" ]; echo $?)" "rc=$rc out=[$out]"
n=$(grep -c '/root/harness' "$T/a5.trace")
chk "A5 no root: /root/harness-checkout is never read" "$([ "$n" = 0 ]; echo $?)" "count=$n"
mkdir -p "$T/harness-checkout"; printf '%s\n' "$SHA1" > "$T/harness-checkout/HARNESS_COMMIT"
out=$(nr env HARNESS="$S" bash -c '. "$1/lane-gate.sh"; _lg_harness_commit' _ "$LIB" 2>&1); rc=$?
chk "A5 HARNESS=\$S: \$S/../harness-checkout answers" "$([ "$rc" = 0 ] && [ "$out" = "$SHA1" ]; echo $?)" "rc=$rc out=[$out]"
mkdir -p "$T/co"; printf '%s\n' "$SHA2" > "$T/co/HARNESS_COMMIT"
out=$(nr env HARNESS="$S" HARNESS_CHECKOUT="$T/co" bash -c '. "$1/lane-gate.sh"; _lg_harness_commit' _ "$LIB" 2>&1); rc=$?
chk "A5 HARNESS_CHECKOUT wins over the root's sibling" "$([ "$rc" = 0 ] && [ "$out" = "$SHA2" ]; echo $?)" "rc=$rc out=[$out]"

# ---------- A6 jobs/req.sh with an empty JOBS_HARNESS ---------------------------
before=$(snap)
err=$(nr env JOBS_HARNESS= bash -c 'exec 9>"$2"; BASH_XTRACEFD=9; set -x; . "$1/jobs/req.sh"; _jobs_log "probe message"; a=$?; _jobs_not_configured; b=$?; set +x; [ "$a$b" = 00 ]' \
  _ "$LIB" "$T/a6.trace" 2>&1 >/dev/null); rc=$?
chk "A6 _jobs_log and _jobs_not_configured: rc 0, empty stderr" "$([ "$rc" = 0 ] && [ -z "$err" ]; echo $?)" "rc=$rc err=[$err]"
chk "A6 no file created in HOME or cwd" "$([ "$(snap)" = "$before" ]; echo $?)"
n=$(grep -cE "(^|[ \"'<])/(logs|flags|state)/" "$T/a6.trace")
chk "A6 no root-relative /logs, /flags or /state path is built" "$([ "$n" = 0 ]; echo $?)" "count=$n"

# ---------- A7 jobs/req.sh with an unwritable logs/ -----------------------------
# root ignores modes, so as root the case runs as nobody from a world-readable copy.
mkdir -p "$T/pub/jh/logs"; cp "$LIB/jobs/req.sh" "$T/pub/req.sh"
a7='. "$1"; _jobs_log "probe message"'
if [ "$(id -u)" -eq 0 ]; then
  if command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    chmod 755 "$T" "$T/pub"; chmod 644 "$T/pub/req.sh"
    chown -R nobody "$T/pub/jh"; chmod 555 "$T/pub/jh/logs"
    err=$(cd / && runuser -u nobody -- env -u HARNESS -u H JOBS_HARNESS="$T/pub/jh" JOBS_URL=http://127.0.0.1:9 \
          bash -c "$a7" _ "$T/pub/req.sh" 2>&1 >/dev/null); rc=$?
    a7run=1
  else
    echo "SKIP A7: running as root and no runuser/nobody to drop to"; a7run=0
  fi
else
  chmod 555 "$T/pub/jh/logs"
  err=$(JOBS_HARNESS="$T/pub/jh" JOBS_URL=http://127.0.0.1:9 bash -c "$a7" _ "$T/pub/req.sh" 2>&1 >/dev/null); rc=$?
  a7run=1
fi
if [ "$a7run" = 1 ]; then
  chk "A7 unwritable logs/: _jobs_log rc 0, empty stderr" "$([ "$rc" = 0 ] && [ -z "$err" ]; echo $?)" "rc=$rc err=[$err]"
  chk "A7 unwritable logs/: no ALERTS.log and no flags/ dir" "$([ ! -e "$T/pub/jh/logs/ALERTS.log" ] && [ ! -e "$T/pub/jh/flags" ]; echo $?)"
fi
chmod 755 "$T/pub/jh/logs" 2>/dev/null

# ---------- A8 endpoint_url -----------------------------------------------------
out=$(nr env ENDPOINT_FOO=https://x bash -c 'exec 9>"$2"; BASH_XTRACEFD=9; set -x; . "$1/endpoints.sh"; endpoint_url foo' \
  _ "$LIB" "$T/a8.trace" 2>/dev/null); rc=$?
chk "A8 endpoint_url foo answers ENDPOINT_FOO with no root" "$([ "$rc" = 0 ] && [ "$out" = https://x ]; echo $?)" "rc=$rc out=[$out]"
n=$(grep -c '/root/harness' "$T/a8.trace")
chk "A8 endpoint_url xtrace has 0 /root/harness" "$([ "$n" = 0 ]; echo $?)" "count=$n"
chk "A8 the sibling lane-gate is the one sourced" "$(grep -qF ". $LIB/lane-gate.sh" "$T/a8.trace"; echo $?)"

# ---------- A9 the cost resolvers -----------------------------------------------
res='. "$1/cost-row.sh"; . "$1/cost-rows-read.sh"; . "$1/cost-budget.sh"
     printf "[%s][%s][%s]" "$(_cost_row_root)" "$(_cost_rows_root)" "$_CB_H"'
out=$(nr bash -c "$res" _ "$LIB" 2>&1)
chk "A9 no root: every cost resolver is empty" "$([ "$out" = "[][][]" ]; echo $?)" "got $out"
out=$(nr env HARNESS="$S" bash -c "$res" _ "$LIB" 2>&1)
chk "A9 HARNESS=\$S: every cost resolver is \$S" "$([ "$out" = "[$S][$S][$S]" ]; echo $?)" "got $out"
out=$(nr env H="$S" bash -c "$res" _ "$LIB" 2>&1)
chk "A9 H=\$S: every cost resolver is \$S" "$([ "$out" = "[$S][$S][$S]" ]; echo $?)" "got $out"

# ---------- A10 the cost writers ------------------------------------------------
before=$(snap)
out=$(nr bash -c 'exec 9>"$2"; BASH_XTRACEFD=9; set -x; . "$1/cost-row.sh"; cost_parity_alert r m s 0 "" ""' _ "$LIB" "$T/a10p.trace" 2>&1); rc=$?
chk "A10 cost_parity_alert with no root: rc 1, silent" "$([ "$rc" = 1 ] && [ -z "$out" ]; echo $?)" "rc=$rc out=[$out]"
out=$(nr bash -c 'exec 9>"$2"; BASH_XTRACEFD=9; set -x; . "$1/cost-rows-read.sh"; _cost_rows_log x' _ "$LIB" "$T/a10l.trace" 2>&1); rc=$?
chk "A10 _cost_rows_log with no root: rc 0, silent" "$([ "$rc" = 0 ] && [ -z "$out" ]; echo $?)" "rc=$rc out=[$out]"
# The trace, not the rc, is the proof: a leftover root-relative daily flag would
# make an unguarded writer answer rc 1 too.
n=$(cat "$T/a10p.trace" "$T/a10l.trace" | grep -cE "(^|[ \"'<>=])/(logs|flags)/")
chk "A10 no root-relative /logs or /flags path is built" "$([ "$n" = 0 ]; echo $?)" "count=$n"
out=$(nr bash -c 'exec 9>"$2"; BASH_XTRACEFD=9; set -x; . "$1/cost-budget.sh"; cost_budget_rates_tsv' _ "$LIB" "$T/a10.trace" 2>/dev/null); rc=$?
chk "A10 cost_budget_rates_tsv with no root reads the sibling catalog" "$([ "$rc" = 0 ] && grep -q '^__MAX__	' <<<"$out"; echo $?)" "rc=$rc"
n=$(grep -cE '/root/harness|(^|[ "])/(state|catalog)/model-prices' "$T/a10.trace")
chk "A10 cost_budget_rates_tsv tries no root candidate" "$([ "$n" = 0 ]; echo $?)" "count=$n"
chk "A10 no file created in HOME or cwd" "$([ "$(snap)" = "$before" ]; echo $?)"

# ---------- A11 cost-rows-read.sh run directly ----------------------------------
S2="$T/s2"; mkdir -p "$S2"; cp -R "$DIR/bin" "$S2/bin"
S2P=$(cd "$S2" && pwd -P)
nr bash -c 'bash -x "$1/bin/lib/cost-rows-read.sh"' _ "$S2" 2>"$T/a11.trace" >/dev/null
chk "A11 run directly: _CRR_SELF is the copy's install root" "$(grep -qxF "+ _CRR_SELF=$S2P" "$T/a11.trace"; echo $?)"
out=$(nr bash -c '. "$1/bin/lib/cost-rows-read.sh"; printf "[%s][%s]" "${_CRR_SELF:-}" "$(_cost_rows_root)"' _ "$S2" 2>&1)
chk "A11 sourced: _CRR_SELF stays empty and the root with it" "$([ "$out" = "[][]" ]; echo $?)" "got $out"

# ---------- A12 the cost switches -----------------------------------------------
nr bash -c '. "$1/cost-row.sh"; cost_transcript_enabled' _ "$LIB" >/dev/null 2>&1; rc=$?
chk "A12 cost_transcript_enabled with no root: rc 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
mkdir -p "$S/flags"; touch "$S/flags/transcript-cost-off"
nr env HARNESS="$S" bash -c '. "$1/cost-row.sh"; cost_transcript_enabled' _ "$LIB" >/dev/null 2>&1; rc=$?
chk "A12 HARNESS=\$S with transcript-cost-off: rc 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
scratch_rm "$S/flags"
out=$(nr env COST_ROWS_BOX=b1 bash -c '. "$1/cost-row.sh"; cost_row_box_id' _ "$LIB" 2>&1)
chk "A12 cost_row_box_id with no root answers COST_ROWS_BOX" "$([ "$out" = b1 ]; echo $?)" "got [$out]"

echo "lane-gate-no-root.bh-2613: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
