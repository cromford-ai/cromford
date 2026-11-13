#!/bin/bash
# tests/call-guard-gh401.bh-9354-test.sh — a triage tick whose gh got 401 on
# every credential does not spend a call-guard slot (BH-9354).
#
#   (a) round trip: call_guard_precall exports GH_SESSION_AUTH_FAIL_FILE, the
#       real bin/gh-session/gh touches it on the all-401 path, and
#       call_guard_finish on a subscription runner settles `unbilled` even
#       though the session ended rc 0 with output
#   (b) the same marker on a METERED runner settles `ok`: cash stays capped
#   (c) no marker: `ok`, as before
#   (d) precall names the file after the call id and removes a stale one
#   (e) finish removes the marker
# The worker side (`unbilled` is not in PAID, so the fp's paid count does not
# move) is pinned by worker/jobs/test/call-guard.k3.test.js.
# Nothing touches the network: the claim, the settle, gh-token.sh and gh are stubs.
# Run from anywhere: bash tests/call-guard-gh401.bh-9354-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/env" "$H/flags" "$H/logs" "$H/state" "$T/real" "$T/tmp"
for s in bin/gh-session/gh bin/lib/gh-session-token.sh bin/lib/call-guard.sh bin/lib/gh-app-default.sh; do
  if [ -f "$DIR/$s" ]; then scratch_install_closure "$s" "$H" >/dev/null || bad "fixture: closure of $s"; fi
done
# every mint fails, every credential is refused, no env/gh-pat
printf '#!/bin/bash\nexit 1\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
echo '{"message":"Bad credentials"}'; echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1
STUB
chmod +x "$T/real/gh"
TOK="ghs_fixturesessiontoken000000000000000"

export HARNESS="$H" TMPDIR="$T/tmp" JOBS_URL="http://jobs.test" AGENT_CALL_FP="BH-1:thfixture:m000000000000"
# shellcheck source=bin/lib/call-guard.sh
. "$H/bin/lib/call-guard.sh" || { echo "FAIL: cannot source call-guard.sh"; exit 1; }
call_guard_claim()  { printf '{"allowed":true,"count":0}'; }
call_guard_settle() { printf '%s\n' "$2" >> "$T/settled"; }
cost_row_uuid()     { printf 'fixture-call-%s' "${CALL_N:-1}"; }
outcome() { tail -n 1 "$T/settled" 2>/dev/null; }
echo "the agent's answer" > "$T/out.txt"

# ── (d) precall exports the marker path and removes a stale file ────────────
CALL_N=1; touch "$T/tmp/cg-gh401.fixture-call-1"
call_guard_precall triage-shard fixproj claude abc123 || bad "(d) precall must allow"
[ "$CG_STATE" = allowed ] && ok || bad "(d) CG_STATE=allowed, got $CG_STATE"
[ "${GH_SESSION_AUTH_FAIL_FILE:-}" = "$T/tmp/cg-gh401.fixture-call-1" ] && ok \
  || bad "(d) GH_SESSION_AUTH_FAIL_FILE names the call id, got '${GH_SESSION_AUTH_FAIL_FILE:-}'"
env | grep -q '^GH_SESSION_AUTH_FAIL_FILE=' && ok || bad "(d) the marker path is EXPORTED, so the runner inherits it"
[ ! -e "$T/tmp/cg-gh401.fixture-call-1" ] && ok || bad "(d) precall removes a stale marker"

# ── (a) the real wrapper writes the marker, finish settles unbilled ────────
if [ -x "$H/bin/gh-session/gh" ]; then
  env PATH="$H/bin/gh-session:$T/real:/usr/bin:/bin" HARNESS_ENV_DIR="$H/env" GH_TOKEN="$TOK" GH_SESSION_SLUG=example-org/x GH_SESSION_PROJECT=fixproj \
      GH_SESSION_TOKEN_FP="$(printf '%s' "$TOK" | sha256sum | cut -c1-16)" GH_SESSION_REMINT=1 \
      gh pr view 2 -R example-org/x >/dev/null 2>"$T/wrap.err"
  wrc=$?
  [ "$wrc" = 1 ] && ok || bad "(a) the wrapper returns gh's rc on the all-401 path, got $wrc"
else
  bad "(a) bin/gh-session/gh is not shipped"
fi
[ -e "${GH_SESSION_AUTH_FAIL_FILE:-$T/no-marker}" ] && ok || bad "(a) the wrapper touched GH_SESSION_AUTH_FAIL_FILE"
CG_RAN_RUNNERS="claude"
call_guard_finish 0 1 "$T/out.txt"
[ "$(outcome)" = unbilled ] && ok || bad "(a) marker + subscription runner settles unbilled, got '$(outcome)'"
grep -q 'settled UNBILLED: triage-shard .*401 on every credential' "$H/logs/call-guard.log" 2>/dev/null && ok \
  || bad "(a) one call-guard.log line says why the slot is not spent"
# ── (e) ─────────────────────────────────────────────────────────────────────
[ ! -e "$T/tmp/cg-gh401.fixture-call-1" ] && ok || bad "(e) finish removes the marker"

# ── (b) metered runner: paid as before ─────────────────────────────────────
CALL_N=2; call_guard_precall triage-shard fixproj openrouter abc123 >/dev/null
touch "${GH_SESSION_AUTH_FAIL_FILE:-$T/no-marker}"
CG_RAN_RUNNERS="claude openrouter"
call_guard_finish 0 1 "$T/out.txt"
[ "$(outcome)" = ok ] && ok || bad "(b) marker + a metered runner that ran settles ok (paid), got '$(outcome)'"
[ ! -e "$T/tmp/cg-gh401.fixture-call-2" ] && ok || bad "(b) the marker is removed on the metered path too"

# ── (c) no marker: ok ───────────────────────────────────────────────────────
CALL_N=3; call_guard_precall triage-shard fixproj claude abc123 >/dev/null
CG_RAN_RUNNERS="claude"
call_guard_finish 0 1 "$T/out.txt"
[ "$(outcome)" = ok ] && ok || bad "(c) no marker settles ok, got '$(outcome)'"

# a failed call with the marker is unbilled too (it is not `failed`)
CALL_N=4; call_guard_precall triage-shard fixproj claude abc123 >/dev/null
touch "${GH_SESSION_AUTH_FAIL_FILE:-$T/no-marker}"
call_guard_finish 1 1 "$T/out.txt"
[ "$(outcome)" = unbilled ] && ok || bad "(a2) marker + rc 1 on a subscription runner settles unbilled, got '$(outcome)'"

echo "call-guard-gh401.bh-9354: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
