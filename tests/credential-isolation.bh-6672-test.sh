#!/bin/bash
# tests/credential-isolation.bh-6672-test.sh — a suite never sees, and never
# prints, a GitHub credential from the environment it was started in.
#
# WHY (BH-6672). tests/batch-resolve-test.sh printed the pool box's real App
# installation token. tests/lib/scratch.sh did not unset GH_TOKEN, the lane's
# gh_app_only_release put the inherited token back after the train PR, and the
# suite's own failure message printed it in full.
#   C1  the suite the ticket names, run with a fake parent GH_TOKEN, prints no
#       trace of it and passes.
#   C2  tests/lib/scratch.sh unsets the five credential names and points
#       GH_CONFIG_DIR into the scratch tree; GH_APP_RATCHET_OWNER_TOKEN stays.
#   C3  bin/test-trace-safety.sh gives every test a canary GH_TOKEN and records
#       `HIT <test> printed-credential` when the test prints it.
#   C4  a test that prints nothing of the canary, or a different token-shaped
#       string, is no hit.
# Every fake token is built at run time and carries the word "fixture".
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

FAKE="ghs_fixture$(printf 'Q%.0s' $(seq 1 29))"

# ── C2. scratch.sh scrubs the credential names ──────────────────────────────
OUT=$(env GH_TOKEN="$FAKE" GITHUB_TOKEN="$FAKE" GH_ENTERPRISE_TOKEN="$FAKE" \
      GITHUB_ENTERPRISE_TOKEN="$FAKE" MC_GIT_TOKEN="$FAKE" GH_APP_RATCHET_OWNER_TOKEN="$FAKE" \
      bash -c '. "$1" || exit 1
               for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN MC_GIT_TOKEN GH_APP_RATCHET_OWNER_TOKEN; do
                 if [ -n "${!v+set}" ]; then printf "%s=set\n" "$v"; else printf "%s=unset\n" "$v"; fi
               done
               case "${GH_CONFIG_DIR:-}" in "$T"/*) printf "cfg=scratch\n" ;; *) printf "cfg=%s\n" "${GH_CONFIG_DIR:-none}" ;; esac' \
      _ "$DIR/tests/lib/scratch.sh" 2>&1)
for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN MC_GIT_TOKEN; do
  grep -qx "$v=unset" <<<"$OUT" && ok || bad "C2: scratch.sh must unset $v ($(grep "^$v=" <<<"$OUT"))"
done
grep -qx 'GH_APP_RATCHET_OWNER_TOKEN=set' <<<"$OUT" && ok \
  || bad "C2: GH_APP_RATCHET_OWNER_TOKEN is CI's own token for one suite and must stay set"
grep -qx 'cfg=scratch' <<<"$OUT" && ok || bad "C2: GH_CONFIG_DIR must point inside the scratch tree ($(grep '^cfg=' <<<"$OUT"))"
grep -qF "$FAKE" <<<"$OUT" && bad "C2: the probe must never print the fake token" || ok

# ── C3/C4. the trace-safety runner's canary ─────────────────────────────────
mkroot() { # mkroot <name> -> a fixture root with tests/ and tests/lib/scratch.sh
  mkdir -p "$T/$1/tests/lib"
  cp "$DIR/tests/lib/scratch.sh" "$T/$1/tests/lib/scratch.sh"
  printf '%s\n' "$T/$1"
}
RUN="$DIR/bin/test-trace-safety.sh"
TOKSHAPE='gh[pousr]_[A-Za-z0-9]{30,}'

# C3 — a test that prints its GH_TOKEN is a printed-credential hit.
L=$(mkroot leaky)
printf '#!/bin/bash\nprintf "token is %%s\\n" "${GH_TOKEN:-none}"\nexit 0\n' > "$L/tests/leaky-test.sh"
OUT=$("$RUN" "$L" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "C3: a test that prints the canary must make the runner rc 1 (got $RC: $(tail -3 <<<"$OUT"))"
grep -q '^HIT leaky-test.sh printed-credential GH_TOKEN' <<<"$OUT" && ok \
  || bad "C3: the runner must name the hit (got: $(grep '^HIT\|^TRACE' <<<"$OUT"))"
grep -Eq "$TOKSHAPE" <<<"$OUT" && bad "C3: the runner must never print the canary" || ok
# --gate, a failing leaky test: rc 1, the hit, and its output printed redacted.
printf '#!/bin/bash\nprintf "token is %%s\\n" "${GH_TOKEN:-none}"\nexit 1\n' > "$L/tests/leaky-test.sh"
OUT=$("$RUN" --gate "$L" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "C3 --gate: rc must be 1 (got $RC)"
grep -q '^HIT leaky-test.sh printed-credential GH_TOKEN' <<<"$OUT" && ok \
  || bad "C3 --gate: the runner must name the hit (got: $(grep '^HIT\|^GATE' <<<"$OUT"))"
grep -Eq "$TOKSHAPE" <<<"$OUT" && bad "C3 --gate: a failed test's printed output must be redacted" || ok
grep -q '^token is <redacted:github-token>$' <<<"$OUT" && ok \
  || bad "C3 --gate: the failed test's output must still be printed, redacted ($(grep '^token is' <<<"$OUT"))"
grep -q '^GATE: pure-logic fail (1 of 1 failed), trace dirty (1 hit(s))$' <<<"$OUT" && ok \
  || bad "C3 --gate: the verdict must be trace dirty ($(grep '^GATE' <<<"$OUT"))"

# C4 — no hit for a test that sources scratch.sh and prints its GH_TOKEN, nor
# for one that prints a token-shaped string that is not the canary.
C=$(mkroot clean)
printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\nprintf "token is %%s\\n" "${GH_TOKEN:-none}"\n' > "$C/tests/clean-test.sh"
printf '#!/bin/bash\nprintf "shape %%s\\n" "%s"\n' "ghs_fixtureother$(printf 'R%.0s' $(seq 1 24))" > "$C/tests/shape-test.sh"
for mode in plain --gate; do
  if [ "$mode" = plain ]; then OUT=$("$RUN" "$C" 2>&1); RC=$?; else OUT=$("$RUN" --gate "$C" 2>&1); RC=$?; fi
  [ "$RC" = 0 ] && ok || bad "C4 $mode: a clean tree must be rc 0 (got $RC: $(grep '^HIT\|^TRACE\|^EXIT' <<<"$OUT"))"
  grep -q 'printed-credential' <<<"$OUT" && bad "C4 $mode: no printed-credential hit for a test that never printed the canary" || ok
done

# ── C1. the suite the ticket names, with a fake parent token ────────────────
env GH_TOKEN="$FAKE" GITHUB_TOKEN="$FAKE" bash "$DIR/tests/batch-resolve-test.sh" > "$T/br.out" 2>&1; RC=$?
N=$(grep -cF "$FAKE" "$T/br.out")
[ "$N" = 0 ] && ok || bad "C1: the fake parent token must not appear in tests/batch-resolve-test.sh output (found $N lines)"
[ "$RC" = 0 ] && ok || bad "C1: tests/batch-resolve-test.sh must pass with a parent GH_TOKEN (rc $RC: $(grep -v "$FAKE" "$T/br.out" | tail -3))"

echo "credential-isolation.bh-6672-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
