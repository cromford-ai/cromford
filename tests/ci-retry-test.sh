#!/bin/bash
# tests/ci-retry-test.sh — a CI tool install that meets a transient index
# failure is retried, bounded, and a real failure still turns the job red.
#
# WHY. Run 36408393883 (shard 0) failed in `install semgrep`: pip answered
# "Could not find a version that satisfies the requirement
# semantic-version~=2.10.0 (from semgrep)" / "No matching distribution found" —
# a PyPI index hiccup, one attempt, under `set -e`. A merge-queue batch of up to
# eight PRs went red on it and paid a bisect and a retest. bin/ci-retry.sh runs
# the install up to CI_RETRY_ATTEMPTS times (default 3) with a doubling back-off
# from CI_RETRY_DELAY_S (default 15 s), and exits with the command's OWN rc
# when every attempt fails — never 0, never a skip.
#
#   R1  a clean command runs once, rc 0, no annotation
#   R2  fail-then-pass is rc 0 after two calls, with a ::warning and the back-off
#   R3  fail x3 is the command's own rc, exactly three calls (bounded, never a
#       loop), a ::error, and the command's stderr stays visible
#   R4  the back-off doubles: delays d, 2d
#   R5  a bad CI_RETRY_ATTEMPTS / CI_RETRY_DELAY_S, or no command, is rc 2 and
#       the command is never run — a typo must not become 0 attempts or 0 s
#   R6  the defaults are 3 attempts, 15 s then 30 s
#   W1  every pip install in the `install semgrep` step goes through
#       bin/ci-retry.sh, with --no-cache-dir (a retry must re-read the index,
#       not pip's cached copy of the page that just failed)
#   W2  after the install, the step still ends UNGUARDED on `semgrep --version`
#       and `bin/ci-tool-present.sh semgrep <pin>`: a failed install fails the
#       job and never falls through to the suite's skip
#
# Stubs on PATH for the command and for sleep; no network, no real pip.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$DIR/bin/ci-retry.sh"
WF="$DIR/.github/workflows/harness-ci.yml"
BASH_BIN=$(command -v bash)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# stubs <dir> <failures before success> — `flaky` fails that many times with
# pip's own words and rc 1, then succeeds; `sleep` only records its argument.
stubs() {
  mkdir -p "$1"; : > "$1/calls.log"; : > "$1/sleep.log"; echo 0 > "$1/n"
  cat > "$1/flaky" <<SH
#!$BASH_BIN
printf '%s\n' "\$*" >> "$1/calls.log"
n=\$(( \$(cat "$1/n") + 1 )); echo "\$n" > "$1/n"
if [ "\$n" -le $2 ]; then
  echo "ERROR: Could not find a version that satisfies the requirement semantic-version~=2.10.0 (from semgrep)" >&2
  echo "ERROR: No matching distribution found for semantic-version~=2.10.0" >&2
  exit 1
fi
exit 0
SH
  printf '#!%s\nprintf "%%s\\n" "$*" >> "%s/sleep.log"\n' "$BASH_BIN" "$1" > "$1/sleep"
  chmod +x "$1/flaky" "$1/sleep"
}
run_helper() { # run_helper <dir> [env assignments...] -> rc on stdout
  local d="$1"; shift
  env -u CI_RETRY_ATTEMPTS -u CI_RETRY_DELAY_S "$@" PATH="$d:$PATH" \
    "$BASH_BIN" "$HELPER" semgrep flaky install "semgrep==1.176.1" >"$d/out" 2>&1; echo $?
}
calls() { wc -l < "$1/calls.log" | tr -d ' '; }

[ -x "$HELPER" ] && ok || bad "R0: $HELPER must exist and be executable"

stubs "$T/r1" 0
RC=$(run_helper "$T/r1")
[ "$RC" = 0 ] && ok || bad "R1: a clean command must be rc 0 (got $RC: $(cat "$T/r1/out"))"
[ "$(calls "$T/r1")" = 1 ] && ok || bad "R1: a clean command runs exactly once (got $(calls "$T/r1"))"
grep -qx 'install semgrep==1.176.1' "$T/r1/calls.log" \
  && ok || bad "R1: the command must get its arguments unchanged (calls: $(cat "$T/r1/calls.log"))"
grep -q '::' "$T/r1/out" && bad "R1: a clean run must not annotate ($(cat "$T/r1/out"))" || ok
[ -s "$T/r1/sleep.log" ] && bad "R1: a clean run must not sleep" || ok

stubs "$T/r2" 1
RC=$(run_helper "$T/r2" CI_RETRY_DELAY_S=0)
[ "$RC" = 0 ] && ok || bad "R2: fail-then-pass must be rc 0 (got $RC: $(cat "$T/r2/out"))"
[ "$(calls "$T/r2")" = 2 ] && ok || bad "R2: fail-then-pass is exactly two calls (got $(calls "$T/r2"))"
grep -q '^::warning title=CI infra (semgrep)::' "$T/r2/out" \
  && ok || bad "R2: a retried attempt must print a '::warning title=CI infra (semgrep)::' line (got: $(cat "$T/r2/out"))"
grep -qx 0 "$T/r2/sleep.log" && ok || bad "R2: the back-off must use CI_RETRY_DELAY_S (sleep got: $(cat "$T/r2/sleep.log"))"

stubs "$T/r3" 99
RC=$(run_helper "$T/r3" CI_RETRY_DELAY_S=0)
[ "$RC" = 1 ] && ok || bad "R3: every attempt failing must exit with the command's own rc 1 (got $RC: $(cat "$T/r3/out"))"
[ "$(calls "$T/r3")" = 3 ] && ok || bad "R3: the default is exactly three attempts, never a loop (got $(calls "$T/r3"))"
grep -q '^::error title=CI infra (semgrep)::' "$T/r3/out" \
  && ok || bad "R3: the last failure must print a '::error title=CI infra (semgrep)::' line (got: $(cat "$T/r3/out"))"
grep -q 'No matching distribution found' "$T/r3/out" \
  && ok || bad "R3: the command's own stderr must stay visible (got: $(cat "$T/r3/out"))"
stubs "$T/r3b" 99
RC=$(run_helper "$T/r3b" CI_RETRY_DELAY_S=0 CI_RETRY_ATTEMPTS=1)
[ "$RC" = 1 ] && [ "$(calls "$T/r3b")" = 1 ] && ok \
  || bad "R3: CI_RETRY_ATTEMPTS=1 is one call and the command's rc (got rc $RC, $(calls "$T/r3b") calls)"

stubs "$T/r4" 99
RC=$(run_helper "$T/r4" CI_RETRY_DELAY_S=4 CI_RETRY_ATTEMPTS=3)
[ "$(tr '\n' ' ' < "$T/r4/sleep.log")" = "4 8 " ] \
  && ok || bad "R4: the back-off must double, 4 then 8, and not sleep after the last attempt (sleep got: $(tr '\n' ' ' < "$T/r4/sleep.log"))"

for BADV in abc '' -5 1.5 '20 '; do
  stubs "$T/r5" 0
  RC=$(run_helper "$T/r5" "CI_RETRY_DELAY_S=$BADV")
  [ "$RC" = 2 ] && [ "$(calls "$T/r5")" = 0 ] && ok \
    || bad "R5: CI_RETRY_DELAY_S='$BADV' must be rc 2 with the command never run (got rc $RC, $(calls "$T/r5") calls)"
done
for BADV in abc '' 0 -1 '3 '; do
  stubs "$T/r5" 0
  RC=$(run_helper "$T/r5" "CI_RETRY_ATTEMPTS=$BADV")
  [ "$RC" = 2 ] && [ "$(calls "$T/r5")" = 0 ] && ok \
    || bad "R5: CI_RETRY_ATTEMPTS='$BADV' must be rc 2 with the command never run (got rc $RC, $(calls "$T/r5") calls)"
done
RC=$("$BASH_BIN" "$HELPER" semgrep >/dev/null 2>&1; echo $?)
[ "$RC" = 2 ] && ok || bad "R5: a label with no command must be rc 2 (got $RC)"

stubs "$T/r6" 99
RC=$(run_helper "$T/r6")
[ "$(calls "$T/r6")" = 3 ] && [ "$(tr '\n' ' ' < "$T/r6/sleep.log")" = "15 30 " ] \
  && ok || bad "R6: the defaults must be 3 attempts and 15 s then 30 s (got $(calls "$T/r6") calls, sleep: $(tr '\n' ' ' < "$T/r6/sleep.log"))"

# ── the workflow ────────────────────────────────────────────────────────────
# The `install semgrep` step's run: body, comments dropped, continuations
# joined — what runs, not how it is wrapped.
STEP=$(awk '
  /^      - name: install semgrep[[:space:]]*$/ { on = 1; next }
  on && /^      - / { exit }
  on' "$WF" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*run: |[[:space:]]*$' | awk '
  { line = $0; sub(/^[[:space:]]+/, "", line)
    if (held != "") { line = held " " line; held = "" }
    if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, "", line); held = line; next }
    if (line != "") print line }')
[ -n "$STEP" ] && ok || bad "W0: found no 'install semgrep' step in $WF"
PIPS=$(printf '%s\n' "$STEP" | grep 'pip install' | grep -v -- 'pip install --help')
NPIP=$(printf '%s\n' "$PIPS" | grep -c .)
[ "$NPIP" -ge 2 ] && ok || bad "W1: expected both PEP 668 branches' pip installs in the step (found $NPIP)"
UNWRAPPED=$(printf '%s\n' "$PIPS" | grep -v '^bin/ci-retry\.sh semgrep ')
[ -z "$UNWRAPPED" ] && ok || bad "W1: every semgrep pip install must run through 'bin/ci-retry.sh semgrep' (unwrapped: $UNWRAPPED)"
NOCACHE=$(printf '%s\n' "$PIPS" | grep -vc -- '--no-cache-dir')
[ "$NOCACHE" = 0 ] && ok || bad "W1: every semgrep pip install must pass --no-cache-dir ($NOCACHE do not)"
LAST2=$(printf '%s\n' "$STEP" | tail -2 | tr '\n' '|')
case "$LAST2" in
  "semgrep --version|bin/ci-tool-present.sh semgrep "[0-9]*"|") ok ;;
  *) bad "W2: the step must END unguarded on 'semgrep --version' then 'bin/ci-tool-present.sh semgrep <pin>' (got: $LAST2)" ;;
esac
head -1 <<<"$STEP" | grep -qx 'set -euo pipefail' \
  && ok || bad "W2: the step must start with 'set -euo pipefail' so a failed install stops it"

echo "ci-retry: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
