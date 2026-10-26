#!/bin/bash
# tests/load-project-env-exists.bh-7930-test.sh — load-project's env stub adds
# the missing <PREFIX>_API_BASE and BASE_BRANCH keys to an env file that
# already exists, and says so, instead of leaving the file as found (BH-7930).
#
# The `# >>> env stub` / `# <<< env stub` block is extracted VERBATIM from the
# REMOTE heredoc in bin/lib/onboard-stations.sh (obs_box). Only the literal
# /root/harness/bin/harden-state.sh is rewritten, to a scratch stub that logs
# its argv, so the box's real harden-state never runs. The block runs under
# `set -euo pipefail` with PROJECT=cro PREFIX=CRO PROD=- BASE=main.
#
#   E1  credentials only: both keys appended, bytes kept, `env: added ...`,
#       harden stub --release then --rearm;
#   E2  both keys present: byte-identical, harden never called, no env: line;
#   E3  BASE_BRANCH=dev only: only CRO_API_BASE appended;
#   E4  LIN_APP_BASE only (other prefix, APP): only BASE_BRANCH appended;
#   E5  near misses (#CRO_API_BASE, XBASE_BRANCH): both keys appended;
#   E6  no trailing newline: the last line stays its own line;
#   E7  no file: the 6-line stub, mode 600, `env stub written:`;
#   E8  empty file: both keys, no leading blank line;
#   E9  mode 640 stays 640;
#   E10 the E1 result sources cleanly with set -a and sets all three keys.
# Run from anywhere: tests/load-project-env-exists.bh-7930-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

mkdir -p "$T/env" "$T/stub"
cat > "$T/stub/harden-state.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HS_LOG"
SH
chmod +x "$T/stub/harden-state.sh"
awk '/^# >>> env stub/{f=1;next} /^# <<< env stub/{exit} f' "$DIR/bin/lib/onboard-stations.sh" \
  | sed "s#/root/harness/bin/harden-state.sh#$T/stub/harden-state.sh#g" > "$T/stub.sh"
[ -s "$T/stub.sh" ] && ok || bad "could not extract the env stub block from bin/lib/onboard-stations.sh — markers missing?"
grep -q '/root/harness' "$T/stub.sh" && bad "the extracted block still names /root/harness" || ok

F="$T/env/cro.env"
# run — runs the block on $F; sets OUT, RC; harden log in $T/hs.log
run() {
  : > "$T/hs.log"
  OUT=$(ENVF="$F" PROJECT=cro PREFIX=CRO PROD=- BASE=main HS_LOG="$T/hs.log" \
    bash -c 'set -euo pipefail; . "$1"' _ "$T/stub.sh" 2>&1)
  RC=$?
}
setf() { rm -f "$F"; printf "$1" > "$F"; }

# E1
setf 'LINEAR_API_KEY=fixture-key\n'; chmod 600 "$F"
run
eq "E1 rc" "$RC" 0
eq "E1 file" "$(cat "$F")" "$(printf 'LINEAR_API_KEY=fixture-key\nCRO_API_BASE=-\nBASE_BRANCH=main')"
eq "E1 output" "$OUT" "env: added CRO_API_BASE=- BASE_BRANCH=main"
eq "E1 harden calls" "$(cat "$T/hs.log")" "$(printf -- '--release %s\n--rearm %s' "$F" "$F")"
cp "$F" "$T/e1.env"

# E2
setf 'LINEAR_API_KEY=fixture-key\nCRO_API_BASE=-\nBASE_BRANCH=main\n'; cp "$F" "$T/e2.orig"
run
eq "E2 rc" "$RC" 0
cmp -s "$F" "$T/e2.orig" && ok || bad "E2 the file changed"
eq "E2 harden calls" "$(wc -l < "$T/hs.log" | tr -d ' ')" 0
grep -q '^env' <<<"$OUT" && bad "E2 no env line expected: $OUT" || ok

# E3
setf 'BASE_BRANCH=dev\n'
run
eq "E3 file" "$(cat "$F")" "$(printf 'BASE_BRANCH=dev\nCRO_API_BASE=-')"
eq "E3 output" "$OUT" "env: added CRO_API_BASE=-"

# E4
setf 'LIN_APP_BASE=https://x.example\n'
run
eq "E4 file" "$(cat "$F")" "$(printf 'LIN_APP_BASE=https://x.example\nBASE_BRANCH=main')"
eq "E4 output" "$OUT" "env: added BASE_BRANCH=main"

# E5
setf '#CRO_API_BASE=-\nXBASE_BRANCH=1\n'
run
eq "E5 file" "$(cat "$F")" "$(printf '#CRO_API_BASE=-\nXBASE_BRANCH=1\nCRO_API_BASE=-\nBASE_BRANCH=main')"

# E6
setf 'FOO=1'
run
eq "E6 file" "$(cat "$F")" "$(printf 'FOO=1\nCRO_API_BASE=-\nBASE_BRANCH=main')"

# E7
rm -f "$F"
run
eq "E7 rc" "$RC" 0
eq "E7 line count" "$(wc -l < "$F" | tr -d ' ')" 6
eq "E7 line 2" "$(sed -n 2p "$F")" "CRO_API_BASE=-"
eq "E7 line 3" "$(sed -n 3p "$F")" "BASE_BRANCH=main"
eq "E7 mode" "$(stat -c %a "$F")" 600
eq "E7 output" "$OUT" "env stub written: $F"
eq "E7 harden calls" "$(cat "$T/hs.log")" "$(printf -- '--release %s\n--rearm %s' "$F" "$F")"

# E8
setf ''
run
eq "E8 file" "$(cat "$F")" "$(printf 'CRO_API_BASE=-\nBASE_BRANCH=main')"
eq "E8 first line" "$(head -1 "$F")" "CRO_API_BASE=-"

# E9
setf 'FOO=1\n'; chmod 640 "$F"
run
eq "E9 mode" "$(stat -c %a "$F")" 640

# E10
GOT=$(bash -c 'set -euo pipefail; set -a; . "$1"; set +a; echo "$CRO_API_BASE|$BASE_BRANCH|$LINEAR_API_KEY"' _ "$T/e1.env" 2>&1)
eq "E10 sourced keys" "$GOT" "-|main|fixture-key"

echo "load-project-env-exists.bh-7930-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
