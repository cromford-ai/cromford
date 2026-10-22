#!/bin/bash
# tests/bootstrap-smoke-no-api-base.bh-7930-test.sh — the bootstrap smoke test
# takes the GitHub-Issues branch when the project env has no *_API_BASE line,
# instead of ending the bootstrap with no message (BH-7930), and every failure
# in the block prints one FATAL line before it ends.
#
# The `# >>> smoke board` / `# <<< smoke board` block is extracted VERBATIM
# from bin/bootstrap-machine.sh and run under `set -euo pipefail`, with a
# scratch HENV, HERE=$T/bin (a silent gh-token.sh stub and a lib/gh-rest.sh
# stub that logs its argv and returns $GH_RC), HARNESS=$T/h and a PATH curl
# stub that logs and prints 200. Nothing reaches the network.
#
#   S1  env FOO=1, gh OK: GitHub-Issues branch, `gh issue access OK`, rc 0, the
#       script goes on, no FATAL, gh_rest argv as shipped, curl not called;
#   S2  env X_API_BASE=https://board.example: board branch, curl gets the URL,
#       gh_rest not called;
#   S3  env X_API_BASE=- : GitHub-Issues branch (near miss);
#   S4  env FOO=1, gh rc 1: rc 1, exactly one FATAL line, it names o/r, stop;
#   S5  no gh-rest.sh on either path: rc 1, exactly one FATAL line;
#   S6  env file that fails when sourced: rc 1, one `smoke test step failed`;
#   S7  after a green block the ERR trap is cleared;
#   S8  the block sits between `echo "== smoke test =="` and `# >>> smoke model`.
# Run from anywhere: tests/bootstrap-smoke-no-api-base.bh-7930-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BOOT="$DIR/bin/bootstrap-machine.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

awk '/^# >>> smoke board/{f=1;next} /^# <<< smoke board/{exit} f' "$BOOT" > "$T/board.sh"
[ -s "$T/board.sh" ] && ok \
  || bad "could not extract the smoke board block from bin/bootstrap-machine.sh — markers missing?"

mkdir -p "$T/bin/lib" "$T/path" "$T/henv" "$T/h"
printf '#!/bin/sh\n' > "$T/bin/gh-token.sh"; chmod +x "$T/bin/gh-token.sh"
cat > "$T/gh-rest.stub" <<'SH'
gh_rest() { echo "$*" >> "$GH_LOG"; return "$GH_RC"; }
SH
cat > "$T/path/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$CURL_LOG"
printf 200
SH
chmod +x "$T/path/curl"

# run <env-file-content> <gh-rc> [nostub] — sets OUT, RC; logs in $T/gh.log, $T/curl.log
run() {
  printf '%s\n' "$1" > "$T/henv/p.env"; : > "$T/henv/global.env"
  : > "$T/gh.log"; : > "$T/curl.log"
  # scratch-closure-allow: the file copied in is this test's gh_rest stub, not a repo bin/lib file
  if [ "${3:-}" = nostub ]; then rm -f "$T/bin/lib/gh-rest.sh"; else cp "$T/gh-rest.stub" "$T/bin/lib/gh-rest.sh"; fi
  OUT=$(cd "$T" && HENV="$T/henv" PROJECT=p HERE="$T/bin" HARNESS="$T/h" REPO_SLUG=o/r \
    GH_RC="$2" GH_LOG="$T/gh.log" CURL_LOG="$T/curl.log" PATH="$T/path:$PATH" \
    bash -c 'set -euo pipefail; . ./board.sh; echo "TRAP[$(trap -p ERR)]"; echo AFTER-BOARD' 2>&1)
  RC=$?
}
nfatal() { grep -c '^FATAL:' <<<"$OUT" || true; }

# S1
run 'FOO=1' 0
eq "S1 rc" "$RC" 0
grep -qF 'board: GitHub Issues (no app API base) — checking gh instead' <<<"$OUT" && ok || bad "S1 no GitHub-Issues line: $OUT"
grep -qF 'gh issue access OK (GH_TOKEN from gh-token.sh)' <<<"$OUT" && ok || bad "S1 no gh OK line: $OUT"
grep -q '^AFTER-BOARD$' <<<"$OUT" && ok || bad "S1 the bootstrap did not go on: $OUT"
eq "S1 FATAL lines" "$(nfatal)" 0
eq "S1 gh_rest argv" "$(cat "$T/gh.log")" "GET repos/o/r/issues -F per_page=1"
eq "S1 curl calls" "$(wc -l < "$T/curl.log" | tr -d ' ')" 0
# S7 (same run)
grep -q '^TRAP\[\]$' <<<"$OUT" && ok || bad "S7 the ERR trap leaked out of the block: $(grep '^TRAP' <<<"$OUT")"

# S2
run 'X_API_BASE=https://board.example' 0
eq "S2 rc" "$RC" 0
grep -q '^board reachable: 200$' <<<"$OUT" && ok || bad "S2 no board branch: $OUT"
grep -qF 'https://board.example' "$T/curl.log" && ok || bad "S2 curl not called with the base: $(cat "$T/curl.log")"
eq "S2 gh_rest calls" "$(wc -l < "$T/gh.log" | tr -d ' ')" 0
grep -q '^TRAP\[\]$' <<<"$OUT" && ok || bad "S2/S7 the ERR trap leaked out of the block"

# S3
run 'X_API_BASE=-' 0
eq "S3 rc" "$RC" 0
grep -qF 'gh issue access OK' <<<"$OUT" && ok || bad "S3 X_API_BASE=- must take the gh branch: $OUT"
eq "S3 curl calls" "$(wc -l < "$T/curl.log" | tr -d ' ')" 0

# S4
run 'FOO=1' 1
eq "S4 rc" "$RC" 1
eq "S4 FATAL lines" "$(nfatal)" 1
grep -q '^FATAL:.*o/r' <<<"$OUT" && ok || bad "S4 the FATAL must name the repo: $OUT"
grep -qF 'gh issue access OK' <<<"$OUT" && bad "S4 a failed read must not print OK" || ok
grep -q '^AFTER-BOARD$' <<<"$OUT" && bad "S4 the bootstrap must stop" || ok

# S5
run 'FOO=1' 0 nostub
eq "S5 rc" "$RC" 1
eq "S5 FATAL lines" "$(nfatal)" 1
grep -q '^AFTER-BOARD$' <<<"$OUT" && bad "S5 the bootstrap must stop" || ok

# S6
run 'false' 0
eq "S6 rc" "$RC" 1
eq "S6 FATAL lines" "$(nfatal)" 1
grep -q '^FATAL: smoke test step failed' <<<"$OUT" && ok || bad "S6 no ERR-trap line: $OUT"
grep -q '^AFTER-BOARD$' <<<"$OUT" && bad "S6 the bootstrap must stop" || ok

# S8 order pin on the shipped file
L_SMOKE=$(grep -m1 -n '^echo "== smoke test =="$' "$BOOT" | cut -d: -f1)
L_OPEN=$(grep -m1 -n '^# >>> smoke board' "$BOOT" | cut -d: -f1)
L_CLOSE=$(grep -m1 -n '^# <<< smoke board' "$BOOT" | cut -d: -f1)
L_MODEL=$(grep -m1 -n '^# >>> smoke model' "$BOOT" | cut -d: -f1)
if [ -n "$L_SMOKE" ] && [ -n "$L_OPEN" ] && [ -n "$L_CLOSE" ] && [ -n "$L_MODEL" ]; then
  eq "S8 board block opens right after the smoke echo" "$L_OPEN" "$((L_SMOKE+1))"
  eq "S8 smoke model block follows the board block" "$L_MODEL" "$((L_CLOSE+1))"
else
  bad "S8 a marker is missing (smoke=$L_SMOKE open=$L_OPEN close=$L_CLOSE model=$L_MODEL)"
fi

echo "bootstrap-smoke-no-api-base.bh-7930-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
