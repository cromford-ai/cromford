#!/bin/bash
# tests/pr-dep-gate-contract-test.sh — bin/lib/pr-dep-gate.sh as BH-629.0 ships
# it: the CONTRACT four merge lanes import, armed and inert.
#
# WHAT THIS SUITE IS FOR. This is the INTERFACE suite: the four functions the
# lanes import exist, the kill switch passes with no read of any kind, pdg_home
# is read at call time, PDG_DEP_RE matches a declaration and refuses the cheap
# false positives, and a tree without the file leaves pdg_hold undefined so every
# lane behaves exactly as it did. What the gate ANSWERS about a real dependency
# is tests/pr-dep-gate-test.sh's, and lives there.
#
# CASE 2 FLIPPED WITH BH-629.1, AS DESIGNED. It asserted that the contract stub
# PASSED an open `Depends on #N (PR #M)` body and read nothing; the parser landed
# and the same body now HOLDS at the cost of one read. Cases 8 and 10 flipped with
# it: the shim answers an open dependency to the body read, so the body-less
# calls hold too. (BH-994 moved that read from `gh pr view` to the REST pulls
# endpoint; the shim followed, the cases did not change.)
#
# Everything is asserted on artifacts: the return code, the line count and text
# of logs/pr-dep-gate.log, the gh shim's call log, and `command -v`. Nothing
# here greps the library's source. The production entry point is the real one —
# every case sources bin/lib/merge-conductor-lib.sh, which is what arms the gate
# on the six lanes, and nothing is retyped into the fixture.
#
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/pr-dep-gate-contract-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LOG="$T/h/logs/pr-dep-gate.log"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h2/bin/lib" "$T/h3" "$T/fakebin"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"  || exit 1
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h2/bin/lib/" || exit 1
mkdir -p "$T/h2/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h2/bin/lib/mc/" || exit 1
# The gate itself is copied only if it exists: the whole point of case 1 is that
# its ABSENCE is a red test and not a fixture error.
cp "$DIR/bin/lib/pr-dep-gate.sh" "$T/h/bin/lib/" 2>/dev/null

# gh: every call is recorded, and any issues/ read answers "open" — so a parser
# that sneaked into this child would HOLD and case 2 would catch it rather than
# passing by luck on a shim that says nothing.
#
# THE BODY COMES OFF THE REST pulls ENDPOINT (BH-994, 2026-09-19): the gate's
# body fetch moved off `gh pr view` when the App installation's GraphQL budget
# emptied and held every READY row on the hub for four ticks. `pr view` keeps a
# branch here only so a regression to it fails loudly rather than reading an
# empty body and passing.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"issues/"*)  printf 'open -\n' ;;
  *"/pulls/"*)  printf 'Depends on #609 (PR #612)\n' ;;
  *"pr view"*)
    echo 'GraphQL: API rate limit already exceeded for installation ID 161623167' >&2
    exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

BODY_OPEN=$(printf 'Some change.\nDepends on #609 (PR #612) for tests/lib/scratch.sh.\n')

# run_case <shell-code> [VAR=VAL ...] — source the conductor lib in a fresh
# `bash -u` (every lane runs with -u) against $T/h, then run <shell-code>.
# Sets RC, OUT; leaves stderr in $T/stderr. Truncates both artifacts first so a
# case's log-line count is its own.
RC=0; OUT=""
run_case() {
  local code="$1"; shift
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/stderr"
  OUT=$(env HARNESS="$T/h" "$@" bash -u -c \
        ". \"\$HARNESS/bin/lib/merge-conductor-lib.sh\"; $code" 2>"$T/stderr")
  RC=$?
}
logn() { wc -l < "$LOG" 2>/dev/null | tr -d ' '; }

# ══ 1. the contract is defined, through the lane's own entry point ══════════
run_case 'for f in pdg_home pdg_enabled pdg_hold pdg_queue_hold; do command -v "$f" >/dev/null || exit 1; done'
[ "$RC" = 0 ] && ok || bad "sourcing the conductor lib must define pdg_home, pdg_enabled, pdg_hold and pdg_queue_hold (rc=$RC)"

# ══ 2. an open dependency HOLDS, at the cost of one read ═══════════════════
# BH-629.1 landed the parser and turned this case's old answer (pass, no read)
# into this one. The shim answers "open -" to every issues read.
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 "$B"' B="$BODY_OPEN"
[ "$RC" = 0 ] && ok || bad "an open Depends on #609 (PR #612) body must HOLD (rc 0), got rc=$RC"
[ "$(grep -c 'issues/612' "$T/gh-calls.txt")" = 1 ] && ok \
  || bad "the hold costs exactly one read of issues/612: $(cat "$T/gh-calls.txt")"
[ "$(logn)" = 1 ] && ok || bad "pdg_hold writes exactly one log line (got $(logn)): $(cat "$LOG" 2>/dev/null)"

# ══ 3. the kill switch, as an env var ══════════════════════════════════════
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 "$B"' B="$BODY_OPEN" PR_DEP_GATE=0
[ "$RC" = 1 ] && ok || bad "PR_DEP_GATE=0 passes (rc=$RC)"
[ "$(logn)" = 1 ] && ok || bad "PR_DEP_GATE=0 writes exactly one log line (got $(logn))"
grep -q 'OFF' "$LOG" 2>/dev/null && ok || bad "the PR_DEP_GATE=0 log line must say the gate is OFF: $(cat "$LOG" 2>/dev/null)"

# ══ 4. the kill switch, as a flag file ═════════════════════════════════════
touch "$T/h/flags/pr-dep-gate-off"
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 "$B"' B="$BODY_OPEN"
[ "$RC" = 1 ] && ok || bad "flags/pr-dep-gate-off passes (rc=$RC)"
[ "$(logn)" = 1 ] && ok || bad "flags/pr-dep-gate-off writes exactly one log line (got $(logn))"
grep -q 'OFF' "$LOG" 2>/dev/null && ok || bad "the flag's log line must say the gate is OFF: $(cat "$LOG" 2>/dev/null)"
rm -f "$T/h/flags/pr-dep-gate-off"

# ══ 5. PDG_DEP_RE matches a real declaration ═══════════════════════════════
# Including the incident's own line, verbatim from #615's body.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  run_case 'grep -qE "$PDG_DEP_RE" <<<"$L"' L="$line"
  [ "$RC" = 0 ] && ok || bad "PDG_DEP_RE must match: [$line]"
done <<'POS'
Depends on #609 (PR #612)
depends on #609
**Depends on #609** (PR #612)
Depends on #459 (PR #609) for tests/lib/scratch.sh, which both suites source.
POS

# ══ 6. PDG_DEP_RE refuses the cheap false positives ════════════════════════
# `>` is not in the noise class: a quoted line is somebody repeating an old
# body, not declaring a dependency. Fixes/Closes is what the harness writes into
# every PR body it creates — matching it would hold the whole fleet for ever.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  run_case 'grep -qE "$PDG_DEP_RE" <<<"$L"' L="$line"
  [ "$RC" != 0 ] && ok || bad "PDG_DEP_RE must NOT match: [$line]"
done <<'NEG'
> Depends on #609 (PR #612)
Fixes #629
Closes #629
Blocked-by: #609
Depends-on: 3a7fd3a
NEG

# ══ 7. a tree WITHOUT the file leaves every lane exactly as it was ══════════
: > "$T/stderr2"
HARNESS="$T/h2" bash -u -c '. "$HARNESS/bin/lib/merge-conductor-lib.sh"; command -v pdg_hold >/dev/null && exit 9; exit 0' 2>"$T/stderr2"
RC=$?
[ "$RC" = 0 ] && ok || bad "a tree with no bin/lib/pr-dep-gate.sh must source the conductor lib cleanly and leave pdg_hold undefined (rc=$RC)"
[ ! -s "$T/stderr2" ] && ok || bad "the absent-file branch must be silent: $(cat "$T/stderr2")"

# ══ 8. the box queue's wrapper ═════════════════════════════════════════════
run_case 'pdg_queue_hold 41' SLUG=o/r
[ "$RC" = 0 ] && ok || bad "pdg_queue_hold holds (rc 0) when the fetched body declares an open dependency (rc=$RC)"
[ "$(logn)" = 1 ] && ok || bad "pdg_queue_hold writes exactly one log line (got $(logn))"
grep -q 'o/r#41' "$LOG" 2>/dev/null && ok || bad "pdg_queue_hold's log line names o/r#41: $(cat "$LOG" 2>/dev/null)"

# ══ 9. the harness root is read at CALL time ═══════════════════════════════
run_case 'HARNESS="$H3" pdg_home' H3="$T/h3"
[ "$OUT" = "$T/h3" ] && ok || bad "pdg_home must read HARNESS at call time (got [$OUT], wanted [$T/h3])"

# ══ 10. nothing here is unbound under set -u ═══════════════════════════════
run_case 'pdg_hold o/r 41 https://github.com/o/r/pull/41 ""'
grep -q 'unbound variable' "$T/stderr" 2>/dev/null && bad "pdg_hold with an empty body is not set -u clean: $(cat "$T/stderr")" || ok
# The empty body is the box queue's path: the gate fetches it, and the shim's
# answer declares an open dependency, so this holds.
[ "$RC" = 0 ] && ok || bad "pdg_hold with an empty body fetches it and holds on the open dependency (rc=$RC)"

echo "pr-dep-gate-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
