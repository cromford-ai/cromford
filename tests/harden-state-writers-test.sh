#!/bin/bash
# tests/harden-state-writers-test.sh — the writers that rewrite a hardened file
# must survive the flag being ON (BH-420 / #390 slice 2).
#
# THE PROPERTY: once bin/harden-state.sh arms a box, `logs/READY-QUEUE.log` is
# `+a` and `logs/cost.csv` is `+a`. Every rewriter of those files replaces the
# INODE (`mv`), and rename over an append-only file is EPERM. Unwrapped, the
# triage queue stops being consumed and the cost header upgrade never applies —
# silently, because both callers swallow the failure. So each rewriter now runs
# release -> rewrite -> rearm, and this suite drives the real scripts with the
# flag actually set.
#
# MUTATION CHECK (D1), performed once and reverted:
#   - delete the `--rearm` line from bin/queue-line-drop.sh -> A7's
#     "READY-QUEUE.log is armed again after the drop" goes red.
#   - delete the `--release` line from bin/queue-line-drop.sh -> A7's
#     "dropped 1 line(s)" goes red (the mv fails EPERM, rc 1).
#   - delete the `--release` line from bin/lib/cost-row.sh -> A9's "header now
#     23 columns" goes red.
#
# A7 and A9 drive the production entry points (the script as copied, the
# function extracted verbatim by its markers). A8/A8b are SOURCE PINS and say
# so: fly-provision, fly-pool-rollout and load-project cannot be driven without
# a Fly org or a real box, so all this proves is that the call is written — the
# count is pinned at exactly 2 so a removed call fails instead of passing.
#
# Run from anywhere: tests/harden-state-writers-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
H="$T/harness"
# An armed scratch file survives `rm -rf` and leaks into /tmp forever (D19), so
# the flags come off before the teardown, never after.
trap 'chattr -ia "$H"/logs/* "$H"/env/* 2>/dev/null; scratch_cleanup 2>/dev/null' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

has_i() { lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q 'i'; }
has_a() { lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q 'a'; }

# ---------- A0: real chattr probe (rc, never `id -u`) ----------
probe=$(mktemp)
if ! chattr +i "$probe" 2>/dev/null; then
  rm -f "$probe"
  echo "SKIP: chattr unsupported here (no privileges or unsupported fs)"
  echo "harden-state-writers-test: 0 pass, 0 fail (SKIPPED)"
  exit 0
fi
chattr -i "$probe" 2>/dev/null || true
rm -f "$probe"

# ---------- Fixture ----------
# harden-state.sh sources bin/lib/env-path.sh relative to ITSELF, so the lib
# rides along or the script dies on its first line.
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env"
cp "$DIR/bin/harden-state.sh"    "$H/bin/harden-state.sh"
cp "$DIR/bin/queue-line-drop.sh" "$H/bin/queue-line-drop.sh"
cp "$DIR/bin/lib/env-path.sh"    "$H/bin/lib/env-path.sh"
chmod +x "$H/bin/harden-state.sh" "$H/bin/queue-line-drop.sh"
HS="$H/bin/harden-state.sh"
hs() { HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" "$@"; }

# ===========================================================================
# A6. the classifier releases the flag the file actually carries
# ===========================================================================
# --release existed only for the immutable set: it answered rc 2 "not in the
# immutable set" for every ledger, so no ledger rewriter could ever be wrapped.
printf 'GLOBAL=1\n' > "$H/env/global.env"
: > "$H/logs/cost.csv"
: > "$H/logs/READY-QUEUE.log"
: > "$H/logs/extra-usage.csv"
: > "$H/logs/merge-sweep.log"

chattr +a "$H/logs/cost.csv" 2>/dev/null
hs --release "$H/logs/cost.csv" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6 --release on an append-only ledger must be rc 0 (got $RC)"
has_a "$H/logs/cost.csv" && bad "A6 --release must clear the a flag on cost.csv" || ok
hs --rearm "$H/logs/cost.csv" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6 --rearm on cost.csv rc 0 (got $RC)"
has_a "$H/logs/cost.csv" && ok || bad "A6 --rearm must restore the a flag on cost.csv"

# The immutable side is unchanged by this slice; pinned so the new branch cannot
# quietly start clearing the wrong flag.
chattr +i "$H/env/global.env" 2>/dev/null
hs --release "$H/env/global.env" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6 --release on an env file rc 0 (got $RC)"
has_i "$H/env/global.env" && bad "A6 --release must clear the i flag on env/global.env" || ok
hs --rearm "$H/env/global.env" >/dev/null 2>&1
has_i "$H/env/global.env" && ok || bad "A6 --rearm must restore the i flag on env/global.env"
chattr -i "$H/env/global.env" 2>/dev/null

# The two ledgers this slice's writers rewrite must be IN the set, or every wrap
# around them answers rc 2 and arms nothing.
hs --rearm "$H/logs/READY-QUEUE.log" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6 --rearm READY-QUEUE.log rc 0 (got $RC)"
has_a "$H/logs/READY-QUEUE.log" && ok || bad "A6 READY-QUEUE.log must be an append-only ledger"
hs --rearm "$H/logs/extra-usage.csv" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6 --rearm extra-usage.csv rc 0 (got $RC)"
has_a "$H/logs/extra-usage.csv" && ok || bad "A6 extra-usage.csv must be an append-only ledger"

# NEGATIVE: the set did not get widened to "anything under logs/".
hs --rearm "$H/logs/merge-sweep.log" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "A6 --rearm on an out-of-set log must stay rc 2 (got $RC)"
has_a "$H/logs/merge-sweep.log" && bad "A6 merge-sweep.log must not be flagged" || ok
hs --release /etc/passwd >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "A6 --release /etc/passwd must stay rc 2 (got $RC)"
has_i /etc/passwd && bad "A6 /etc/passwd must remain unflagged" || ok

chattr -a "$H/logs/cost.csv" "$H/logs/READY-QUEUE.log" "$H/logs/extra-usage.csv" 2>/dev/null

# ===========================================================================
# A7. bin/queue-line-drop.sh against an armed READY-QUEUE.log (D2: the real script)
# ===========================================================================
Q="$H/logs/READY-QUEUE.log"
arm_queue() {
  chattr -a "$Q" 2>/dev/null
  printf 'TK-1 one\nTS-2 two\n' > "$Q"
  chattr +a "$Q" 2>/dev/null
}

arm_queue
OUT=$(HARNESS="$H" bash "$H/bin/queue-line-drop.sh" TK-2 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A7 drop against an armed queue must be rc 0 (got $RC: $OUT)"
[ "$OUT" = "dropped 1 line(s) for: TK-2" ] && ok || bad "A7 drop output (got: $OUT)"
[ "$(cat "$Q")" = "TK-1 one" ] && ok || bad "A7 the queue must keep exactly TK-1 (got: $(cat "$Q"))"
has_a "$Q" && ok || bad "A7 READY-QUEUE.log must be armed again after the drop"

# The refusal path exits BEFORE the release, so the file is untouched and still
# armed — a rejected key must never leave the queue writable.
arm_queue
OUT=$(HARNESS="$H" bash "$H/bin/queue-line-drop.sh" 'TK-2; rm -rf /' 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "A7 a non-ticket key must still be refused rc 2 (got $RC)"
[ "$(cat "$Q")" = "$(printf 'TK-1 one\nTS-2 two')" ] && ok || bad "A7 a refused key must not edit the queue"
has_a "$Q" && ok || bad "A7 a refused key must leave the queue armed"

# A7n NEGATIVE: armed, but no harden-state.sh to release it. The guard must not
# pretend the drop happened — rc 1, and the queue is byte-identical.
arm_queue
cp "$Q" "$T/queue.before"
mv "$H/bin/harden-state.sh" "$T/harden-state.sh.hidden"
OUT=$(HARNESS="$H" bash "$H/bin/queue-line-drop.sh" TK-2 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "A7n an unreleasable armed queue must fail rc 1 (got $RC: $OUT)"
cmp -s "$T/queue.before" "$Q" && ok || bad "A7n the queue must be byte-identical after a failed drop"
case "$OUT" in *"dropped "*) bad "A7n a failed drop must not print a dropped count (got: $OUT)" ;; *) ok ;; esac

# A7g: the [ -x ] guard — no harden-state.sh and nothing armed is the state of
# every scratch-tree suite in this repo, and the drop must just work there.
chattr -a "$Q" 2>/dev/null
printf 'TK-1 one\nTS-2 two\n' > "$Q"
OUT=$(HARNESS="$H" bash "$H/bin/queue-line-drop.sh" TK-2 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A7g drop with no harden-state.sh present must be rc 0 (got $RC: $OUT)"
[ "$(cat "$Q")" = "TK-1 one" ] && ok || bad "A7g the unguarded path must still drop the line"
mv "$T/harden-state.sh.hidden" "$H/bin/harden-state.sh"

# ===========================================================================
# A9. cost_append's header upgrade against an armed cost.csv
# ===========================================================================
awk '/^# >>> cost_append/{f=1;next} /^# <<< cost_append/{exit} f' \
  "$DIR/bin/lib/cost-row.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] && ok || bad "A9 could not extract cost_append — markers missing?"

HDR13="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd"
HDR23="$HDR13,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id"
HDR24="$HDR23,note"
# TEST-CHANGE BH-2537: 25 -> 26. A 13-column header now upgrades to 26 names
# (lane_id, BH-2303, then guard_fp); this pin still read 24 and was already red
# on main since BH-2303.
HDR26="$HDR24,lane_id,guard_fp"
COST="$H/logs/cost.csv"
LEGACY="old,legacy,row,x,claude,m,0,1,1,1,0,0,1.00"
ROW23="new,row,x,y,claude,m,0,1,1,1,0,0,2.00,subscription,fp1,acct-x,sess-1,transcript,1.90,BH-420,job7,https://pr/1,build-2"
arm_cost() {
  chattr -a "$COST" 2>/dev/null
  printf '%s\n%s\n' "$HDR13" "$LEGACY" > "$COST"
  chattr +a "$COST" 2>/dev/null
}
append_row() {
  ( HARNESS="$H" COST="$COST" bash -c '. "$0"; cost_append "$1"' "$T/fn.sh" "$1" >/dev/null 2>&1 )
}
rows() { local n; n=$(grep -c . "$COST" 2>/dev/null || echo 1); echo $((n - 1)); }

arm_cost
append_row "$ROW23"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A9 cost_append rc 0 against an armed ledger (got $RC)"
[ "$(head -1 "$COST")" = "$HDR26" ] && ok || bad "A9 the header upgrade must apply under +a (got: $(head -1 "$COST"))"
grep -q '^old,legacy,row' "$COST" && ok || bad "A9 the legacy row must survive the upgrade"
grep -q 'sess-1,transcript' "$COST" && ok || bad "A9 the new row must land after the upgrade"
[ "$(rows)" = 2 ] && ok || bad "A9 exactly two rows after the upgrade (rows=$(rows))"
has_a "$COST" && ok || bad "A9 cost.csv must be armed again after the header upgrade"

# A9n NEGATIVE: no harden-state.sh, so the upgrade CANNOT apply — and the row
# lands anyway. Losing a cost row is the one failure cost_append exists to
# prevent; a failed header rewrite must never become a lost row.
arm_cost
mv "$H/bin/harden-state.sh" "$T/harden-state.sh.hidden"
append_row "$ROW23"; RC=$?
mv "$T/harden-state.sh.hidden" "$H/bin/harden-state.sh"
[ "$RC" -eq 0 ] && ok || bad "A9n cost_append must still report success (got $RC)"
[ "$(head -1 "$COST")" = "$HDR13" ] && ok || bad "A9n the upgrade must be skipped, not forced (got: $(head -1 "$COST"))"
[ "$(rows)" = 2 ] && ok || bad "A9n the row must land even when the upgrade cannot (rows=$(rows))"
grep -q 'sess-1,transcript' "$COST" && ok || bad "A9n the row content must be the one we passed"
chattr -a "$COST" 2>/dev/null

# ===========================================================================
# A8. source pins (NOT behavioural proof — see the header)
# ===========================================================================
# fly-provision and fly-pool-rollout need a Fly org and a real token mint;
# load-project's block (bin/lib/onboard-stations.sh obs_box) runs inside an ssh
# heredoc on a remote box. None can be
# driven from a fixture, so the pin is the call being present, counted exactly:
# `= 2` (release + rearm), so a deleted call fails rather than passing (D3).
for f in bin/fly-provision.sh bin/fly-pool-rollout.sh bin/lib/onboard-stations.sh; do
  N=$(grep -c 'harden-state.sh --re' "$DIR/$f" 2>/dev/null || true)
  [ "${N:-0}" = 2 ] && ok || bad "A8 $f must carry exactly 2 harden-state.sh --re calls (got ${N:-0})"
done
N=$(grep -c 'harden-state.sh --re' "$DIR/bin/extra-usage-track.sh" 2>/dev/null || true)
[ "${N:-0}" = 2 ] && ok || bad "A8b bin/extra-usage-track.sh must carry exactly 2 harden-state.sh --re calls (got ${N:-0})"

echo "harden-state-writers-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
