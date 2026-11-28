#!/bin/bash
# tests/curl-bearer-argv-lint.bh-9946-test.sh — the curl-bearer-argv delta lint
# (BH-9946): bin/curl-bearer-argv-lint.sh and its rules-pack row.
#
#   R1-R7  red cases: the bearer on argv (plain, capital A and braces, a quote
#          then $, the old req.sh assignment, a nested bin/lib file, a second
#          hunk of the same file, an array element with lower-case bearer).
#   R8     a here-string elsewhere on the line does not excuse an argv header.
#   P1-P10 clean cases: a printf to a 0600 header file, a curl -K config, an
#          escaped \$ in a message, a comment, a redaction, a line already on
#          the base (delta only), a file in tests/, another header name, the
#          req.sh fd-3 here-string form, a quoted here-string prefix.
#   B1     bad args (rc 2).
#   E1/E2  the production entry point: bin/rules-pack.sh --only
#          curl-bearer-argv on a fixture, red then green.
# Fixture text is assembled from parts so this file holds no bearer-on-argv line.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/curl-bearer-argv-lint.bh-9946-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LINT="$DIR/bin/curl-bearer-argv-lint.sh"
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1

run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
TAG="curl-bearer-argv: secret:"
D='$'                       # a literal dollar sign for fixture lines
AB="authorization: Bearer"  # the header text

# --- the fixture ----------------------------------------------------------
R="$T/r"
mkdir -p "$R/bin/lib" "$R/tests"
printf '%s\n' '#!/bin/bash' 'U=https://x.invalid' '' 'f() {' '  echo f' '}' '' 'g() {' '  echo g' '}' > "$R/bin/x.sh"
printf '%s\n' '#!/bin/bash' 'echo y' > "$R/bin/lib/y.sh"
printf '%s\n' 'echo tests' > "$R/tests/x.sh"
rd_fixture_repo "$R" || { echo "FAIL: cannot build the fixture repo"; exit 1; }
rd_git "$R" config gc.auto 0; rd_git "$R" config maintenance.auto false
B0=$(rd_git "$R" rev-parse HEAD)
reset_fx() { rd_git "$R" checkout -qf -B work "$B0"; rd_git "$R" clean -fdxq; }
commit() { rd_git "$R" add -A && rd_git "$R" commit -qm "$1"; }
append() { local f="$R/$1"; shift; printf '%s\n' "$@" >> "$f"; }
lint() { run bash "$LINT" --base "$B0" "$R"; }
# expect_red <case> <path:line>... — rc 1, exactly those findings
expect_red() {
  local c=$1; shift
  [ "$RC" -eq 1 ] && ok || bad "$c rc $RC (want 1): $OUT $ERR"
  [ "$(grep -c . <<<"$OUT")" -eq $# ] && ok || bad "$c want $# finding(s): [$OUT]"
  local w; for w in "$@"; do
    grep -q "^$w: $TAG " <<<"$OUT" && ok || bad "$c stdout [$OUT] has no '$w: $TAG ...'"
  done
}
expect_green() {
  [ "$RC" -eq 0 ] && ok || bad "$1 rc $RC (want 0): $OUT $ERR"
  [ -z "$OUT" ] && ok || bad "$1 stdout [$OUT] (want empty)"
}

# R1 — the ticket's refuse fixture: the header as an argument.
reset_fx; append bin/x.sh "curl -sS -H \"$AB ${D}HARNESS_SECRET\" \"${D}U\""; commit R1
lint; expect_red R1 bin/x.sh:11
# R2 — capital A, braces.
reset_fx; append bin/x.sh "curl -H \"Authorization: Bearer ${D}{TOK}\" \"${D}U\""; commit R2
lint; expect_red R2 bin/x.sh:11
# R3 — a single-quoted prefix, then a double-quoted variable.
reset_fx; append bin/x.sh "curl --header '$AB '\"${D}T\" \"${D}U\""; commit R3
lint; expect_red R3 bin/x.sh:11
# R4 — the old req.sh shape: an assignment that goes to -H later.
reset_fx; append bin/x.sh "  local auth=\"$AB ${D}HARNESS_SECRET\" hf=\"\""; commit R4
lint; expect_red R4 bin/x.sh:11
# R5 — a nested bin/lib file.
reset_fx; append bin/lib/y.sh "curl -H \"$AB ${D}K\" x"; commit R5
lint; expect_red R5 bin/lib/y.sh:3
# R7 — an array element, lower-case bearer.
LB=bearer; reset_fx; append bin/x.sh "AUTH=(-H \"authorization: ${LB} ${D}S\")"; commit R7
lint; expect_red R7 bin/x.sh:11
# R6 — two hunks of one file: both judged.
reset_fx
sed -i "5a\\  curl -H \"$AB ${D}A\" x" "$R/bin/x.sh"
append bin/x.sh "curl -H \"$AB ${D}B\" y"; commit R6
lint; expect_red R6 bin/x.sh:6 bin/x.sh:12
# R8 — a here-string elsewhere on the line does not excuse an argv header:
# the `<<<` must sit directly before `authorization:`.
reset_fx; append bin/x.sh "curl -H \"$AB ${D}S\" \"${D}URL\" 3<<<\"x\""; commit R8
lint; expect_red R8 bin/x.sh:11

# P1 — the ticket's pass fixture: printf to a 0600 file, then -H @file.
reset_fx
append bin/x.sh "hf=${D}(umask 077; mktemp)" "printf '$AB %s\\n' \"${D}S\" > \"${D}hf\"" "curl -H \"@${D}hf\" \"${D}U\""; commit P1
lint; expect_green P1
# P2 — a curl -K config on a process substitution.
reset_fx; append bin/x.sh "curl -K <(printf 'header = \"$AB %s\"\\n' \"${D}S\") \"${D}U\""; commit P2
lint; expect_green P2
# P3 — an escaped \$ inside a message (the child-plan-tripwire shape).
reset_fx; append bin/x.sh "echo \"send -H '$AB \\${D}HARNESS_SECRET' by hand\""; commit P3
lint; expect_green P3
# P4 — a whole-line comment and a trailing comment.
reset_fx; append bin/x.sh "# curl -H \"$AB ${D}X\"" "echo ok # -H \"$AB ${D}X\""; commit P4
lint; expect_green P4
# P5 — a redaction: no variable after Bearer.
reset_fx; append bin/x.sh "sed 's/Bearer .*/Bearer <redacted>/'"; commit P5
lint; expect_green P5
# P6 — the bad line is already on the base: delta only.
reset_fx
rd_main_commit "$R" "base has it" sh -c "printf '%s\n' 'curl -H \"$AB ${D}OLD\" x' >> \"\$1/bin/lib/y.sh\"" _ >/dev/null 2>&1
MB=$(rd_git "$R" rev-parse origin/main)
rd_git "$R" checkout -qf -B work "$MB"; append bin/x.sh "echo unrelated"; commit P6
run bash "$LINT" --base "$MB" "$R"; expect_green P6
grep -q 'OLD' "$R/bin/lib/y.sh" && ok || bad "P6 fixture: the base line is not there"
rd_git "$R" update-ref refs/remotes/origin/main "$B0"
# P7 — out of the scan set: tests/.
reset_fx; append tests/x.sh "curl -H \"$AB ${D}T\" x"; commit P7
lint; expect_green P7
# P8 — another header name.
reset_fx; append bin/x.sh "curl -H \"x-suite-ledger-token: ${D}T\" \"${D}U\""; commit P8
lint; expect_green P8
# P9 — the req.sh form: the header on fd 3 from a here-string, not argv.
reset_fx; append bin/x.sh "curl -sS -H @/dev/fd/3 \"${D}URL\" 3<<<\"$AB ${D}HARNESS_SECRET\""; commit P9
lint; expect_green P9
# P10 — a here-string with a single-quoted prefix and spaces.
reset_fx; append bin/x.sh "curl -H @- x <<< '$AB '\"${D}S\""; commit P10
lint; expect_green P10

# B1 — bad args.
run bash "$LINT" --base nosuchref "$R"
[ "$RC" -eq 2 ] && ok || bad "B1 --base nosuchref rc $RC (want 2)"
run bash "$LINT" --bogus
[ "$RC" -eq 2 ] && ok || bad "B1 --bogus rc $RC (want 2)"

# --- E1/E2 the production entry point -------------------------------------
# The fixture is this checkout's HEAD with the lint's working files laid over it.
F="$T/fx"
mkdir -p "$F"
git -C "$DIR" archive HEAD | tar -x -C "$F" || { echo "FAIL: cannot archive HEAD"; exit 1; }
for p in bin/curl-bearer-argv-lint.sh bin/rules-pack.sh catalog/rules-pack.tsv; do
  [ -f "$DIR/$p" ] && cp -p "$DIR/$p" "$F/$p"
done
rd_fixture_repo "$F" || { echo "FAIL: cannot build the E1 fixture"; exit 1; }
rd_git "$F" config gc.auto 0; rd_git "$F" config maintenance.auto false
FB=$(rd_git "$F" rev-parse HEAD)
printf '%s\n' "curl -sS -H \"$AB ${D}HARNESS_SECRET\" \"${D}JOBS_URL/x\"" >> "$F/bin/lib/jobs/req.sh"
N=$(wc -l < "$F/bin/lib/jobs/req.sh")
rd_git "$F" add -A && rd_git "$F" commit -qm E1
mkdir -p "$T/nolg"
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only curl-bearer-argv --runner local --out "$T/o1"
[ "$RC" -eq 1 ] && ok || bad "E1 rules-pack rc $RC (want 1): $OUT $ERR"
case "$OUT" in "curl-bearer-argv: bin/lib/jobs/req.sh:$N: $TAG "*) ok ;;
  *) bad "E1 stdout [$OUT] (want curl-bearer-argv: bin/lib/jobs/req.sh:$N: $TAG ...)" ;; esac
[ "$(jq -r '.components[0].id + " " + .components[0].state' "$T/o1/summary.json" 2>/dev/null)" = "curl-bearer-argv red" ] && ok \
  || bad "E1 summary.json components[0] $(jq -c '.components[0]' "$T/o1/summary.json" 2>/dev/null) (want curl-bearer-argv red)"

rd_git "$F" reset -q --hard "$FB"
printf '%s\n' "printf '$AB %s\\n' \"${D}HARNESS_SECRET\" > \"${D}hf\"" "curl -sS -H \"@${D}hf\" \"${D}JOBS_URL/x\"" >> "$F/bin/lib/jobs/req.sh"
rd_git "$F" add -A && rd_git "$F" commit -qm E2
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only curl-bearer-argv --runner local --out "$T/o2"
[ "$RC" -eq 0 ] && ok || bad "E2 rules-pack rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "E2 stdout [$OUT] (want empty)"
[ "$(jq -r '.components[0].id + " " + .components[0].state' "$T/o2/summary.json" 2>/dev/null)" = "curl-bearer-argv green" ] && ok \
  || bad "E2 summary.json components[0] $(jq -c '.components[0]' "$T/o2/summary.json" 2>/dev/null) (want curl-bearer-argv green)"

echo "curl-bearer-argv-lint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
