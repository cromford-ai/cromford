#!/bin/bash
# tests/mc-rereview-scratch-cwd.bh-8103-test.sh — BH-8103: the conductor's
# re-review agent starts in a private, empty scratch dir, never in the cwd the
# detached job inherited (on 2026-10-23 that agent moved the hub's deploy
# checkout).
#
# Driven through the REAL mc_rereview (bin/lib/merge-conductor-lib.sh and
# bin/lib/mc/*.sh in a scratch $HARNESS) with a stub bin/agent-call.sh that
# records its cwd, and a stub gh.
#   R1  the agent-call cwd is $MC_RR_SCRATCH_ROOT/demo-os-51-<head12>, not the
#       caller's cwd; unset, the root is $TMPDIR/mc-rereview-<uid>
#   R2  a RELATIVE out file still gives APPROVE rc 0
#   R3  a scratch root that cannot be made: rc 2, <out>.lanefail names the dir,
#       agent-call.sh was not run
#   R4  the scratch dir is gone after the call
#   R5  the caller's cwd is unchanged after mc_rereview returns
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-rereview-scratch-cwd.bh-8103-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset MC_RR_SCRATCH_ROOT
# The default root is under TMPDIR: point it into the scratch tree, so parallel
# runs of this suite never share a dir.
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"

H="$T/h"; export HARNESS="$H"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$T/fakebin"
for L in bin/lib/merge-conductor-lib.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
# review_model answers from the resolver's cache of the model_routes table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" demo-os
# MC_RB_OVERRIDE: the red run points this at origin/main's rebase.sh.
# scratch-closure-allow: the red run swaps origin/main's copy of a file the closure already installed
[ -n "${MC_RB_OVERRIDE:-}" ] && cp "$MC_RB_OVERRIDE" "$H/bin/lib/mc/rebase.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
export PATH="$T/fakebin:$PATH"

cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
# stage project model timeout OUT @prompt
pwd > "$CWD_SEEN"
printf '%s\n' "$5" > "$CWD_SEEN.out"
printf 'VERDICT: APPROVE\n' > "$5"; printf 'claude\n' > "$5.runner"; printf 'claude-fable-5-1\n' > "$5.model"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.sh
+++ b/x.sh
+echo a
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/51"*) restpr OPEN "$HEADSHA" ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

export MC_H="$H" MC_RR_LIVE_CI=0 CWD_SEEN="$T/cwd-seen"
export HEADSHA=0123456789abcdef0123456789abcdef01234567
# shellcheck source=/dev/null
. "$H/bin/lib/merge-conductor-lib.sh"; mc_init

URL=https://github.com/example-org/demo-os/pull/51
CALLER="$T/harness-checkout"; mkdir -p "$CALLER"
rr() { mc_rereview example-org/demo-os 51 demo-os "$URL" - "$HEADSHA" "" "$1"; }

# ── R1, R2, R4, R5 ──────────────────────────────────────────────────────────
echo "--- R1"
export MC_RR_SCRATCH_ROOT="$T/rr-scratch"
cd "$CALLER" || exit 1
rm -f "$CWD_SEEN"
V=$(rr rr.out); RC=$?
WANT="$MC_RR_SCRATCH_ROOT/demo-os-51-${HEADSHA:0:12}"
[ "$(cat "$CWD_SEEN" 2>/dev/null)" = "$WANT" ] && ok \
  || bad "R1 agent-call.sh ran in '$(cat "$CWD_SEEN" 2>/dev/null)', want $WANT"
[ "$(cat "$CWD_SEEN" 2>/dev/null)" != "$CALLER" ] && ok || bad "R1 agent-call.sh ran in the caller's cwd"
echo "--- R2"
[ "$RC" = 0 ] && [ "$V" = APPROVE ] && ok || bad "R2 a relative out file must still read APPROVE rc 0 (rc=$RC v='$V')"
[ "$(cat "$CWD_SEEN.out" 2>/dev/null)" = "$CALLER/rr.out" ] && ok \
  || bad "R2 agent-call.sh must get the out file as an absolute path (got '$(cat "$CWD_SEEN.out" 2>/dev/null)')"
echo "--- R4"
[ -e "$WANT" ] && bad "R4 the scratch dir $WANT is still there" || ok
echo "--- R5"
[ "$PWD" = "$CALLER" ] && ok || bad "R5 mc_rereview changed the caller's cwd to $PWD"

# The default root ($TMPDIR/mc-rereview-<uid>), with an absolute out file.
unset MC_RR_SCRATCH_ROOT
rm -f "$CWD_SEEN"
V=$(rr "$T/rr2.out"); RC=$?
[ "$(cat "$CWD_SEEN" 2>/dev/null)" = "$TMPDIR/mc-rereview-$(id -u)/demo-os-51-${HEADSHA:0:12}" ] && ok \
  || bad "R1 the default scratch root is \$TMPDIR/mc-rereview-<uid> (got '$(cat "$CWD_SEEN" 2>/dev/null)')"
[ "$RC" = 0 ] && [ "$V" = APPROVE ] && ok || bad "R2 absolute out file (rc=$RC v='$V')"

# ── R3 ──────────────────────────────────────────────────────────────────────
echo "--- R3"
: > "$T/afile"
export MC_RR_SCRATCH_ROOT="$T/afile/sub"      # a file in the path: mkdir fails, even as root
rm -f "$CWD_SEEN" "$T/rr3.out.lanefail"
V=$(rr "$T/rr3.out"); RC=$?
[ "$RC" = 2 ] && ok || bad "R3 a scratch dir that cannot be made is a lane failure, rc 2 (rc=$RC v='$V')"
[ -z "$V" ] && ok || bad "R3 a lane failure prints no verdict (got '$V')"
grep -qF "$T/afile/sub/demo-os-51-" "$T/rr3.out.lanefail" 2>/dev/null && ok \
  || bad "R3 <out>.lanefail must name the scratch dir: $(cat "$T/rr3.out.lanefail" 2>/dev/null)"
[ -e "$CWD_SEEN" ] && bad "R3 agent-call.sh ran with no scratch dir" || ok

cd "$DIR" || exit 1
echo "mc-rereview-scratch-cwd: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
