#!/bin/bash
# tests/agent-call-no-tools-lint.bh-7276-test.sh — the agent-call-no-tools
# delta lint (BH-7276): bin/agent-call-no-tools-lint.sh and its rules-pack row.
#
#   A1-A5  red cases: an added unflagged call, a short marker reason, the flag
#          removed from bin/lib/sentry-triage.sh, flag near misses, scope near
#          misses.
#   N1-N15 clean cases: the flag inline / on a continuation / exported in the
#          function or at top level, a valid marker, delta only, non-calls,
#          out of the scan set, a deleted file, a moved call, bad args (rc 2),
#          a second hunk and a second file still judged, this checkout's diff.
#   P1/P2  the production entry point: bin/rules-pack.sh --only
#          agent-call-no-tools on a fixture, red then green.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/agent-call-no-tools-lint.bh-7276-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LINT="$DIR/bin/agent-call-no-tools-lint.sh"
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1

# run <cmd...> — sets RC, OUT, ERR
run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
lint() { run bash "$LINT" "$@"; }
TAG="agent-call-no-tools: auth-bypass:"

# --- the fixture ----------------------------------------------------------
R="$T/r"
mkdir -p "$R/bin/lib" "$R/tests"
cat > "$R/bin/x.sh" <<'EOF'
#!/bin/bash
H=/opt/h
prompt=/tmp/p

classify() {
  local a=1
  echo "$a"
}
EOF
cat > "$R/bin/lib/y.sh" <<'EOF'
#!/bin/bash
# y lib
old_call() {
  out=$("$H/bin/agent-call.sh" --stage old < "$prompt")
  echo "$out"
}
EOF
cat > "$R/bin/lib/z.sh" <<'EOF'
#!/bin/bash
flagged() {
  out=$(AGENT_CALL_NO_TOOLS=1 "$H/bin/agent-call.sh" --stage z < "$prompt")
  echo "$out"
}
EOF
# scratch-closure-allow: fixture data for ticket test 4 (the flag removed from sentry-triage.sh); the copy is linted, never sourced
cp "$DIR/bin/lib/sentry-triage.sh" "$R/bin/lib/sentry-triage.sh"
echo 'echo tests' > "$R/tests/x.sh"
echo 'print(1)' > "$R/bin/x.py"
echo '#!/bin/bash' > "$R/bin/agent-call.sh"
rd_fixture_repo "$R" || { echo "FAIL: cannot build the fixture repo"; exit 1; }
rd_git "$R" config gc.auto 0; rd_git "$R" config maintenance.auto false
B0=$(rd_git "$R" rev-parse HEAD)
reset_fx() { rd_git "$R" checkout -qf -B work "$B0"; rd_git "$R" clean -fdxq; }
commit() { rd_git "$R" add -A && rd_git "$R" commit -qm "$1"; }
# append <file> <text...> — append lines to the fixture file
append() { local f="$R/$1"; shift; printf '%s\n' "$@" >> "$f"; }
# expect_red <case> [line] — rc 1; with a line, stdout names bin/x.sh:<line>
expect_red() {
  [ "$RC" -eq 1 ] && ok || bad "$1 rc $RC (want 1): $OUT $ERR"
  if [ -n "${2:-}" ]; then
    case "$OUT" in "bin/x.sh:$2: $TAG "*) ok ;; *) bad "$1 stdout [$OUT] (want bin/x.sh:$2: $TAG ...)" ;; esac
  fi
}
expect_clean() {
  [ "$RC" -eq 0 ] && ok || bad "$1 rc $RC (want 0): $OUT $ERR"
  [ -z "$OUT" ] && ok || bad "$1 stdout [$OUT] (want empty)"
}
CALL='out=$(bin/agent-call.sh --stage x < "$prompt")'

# --- A1 an added unflagged call -------------------------------------------
reset_fx
append bin/x.sh "$CALL"; commit A1
N=$(wc -l < "$R/bin/x.sh")
lint --base "$B0" "$R"
expect_red A1 "$N"
[ "$(grep -c . <<<"$OUT")" -eq 1 ] && ok || bad "A1 want 1 finding: $OUT"
case "$ERR" in *"1 finding"*) ok ;; *) bad "A1 stderr has no count: $ERR" ;; esac

# --- A2 a marker with a short reason --------------------------------------
reset_fx
append bin/x.sh '# agent-call-tools: ok' "$CALL"; commit A2
N=$(wc -l < "$R/bin/x.sh")
lint --base "$B0" "$R"
expect_red A2 "$N"
case "$OUT" in *'"ok"'*'under 10'*) ok ;; *) bad "A2 why does not name the short reason: $OUT" ;; esac

# --- A3 the flag deleted from bin/lib/sentry-triage.sh --------------------
reset_fx
N=$(grep -n 'AGENT_CALL_NO_TOOLS=1 AGENT_CALL_RUNNERS' "$R/bin/lib/sentry-triage.sh" | cut -d: -f1)
[ -n "$N" ] || bad "A3 the fixture copy of sentry-triage.sh has no flagged call"
sed -i 's/ AGENT_CALL_NO_TOOLS=1 AGENT_CALL_RUNNERS/ AGENT_CALL_RUNNERS/' "$R/bin/lib/sentry-triage.sh"; commit A3
lint --base "$B0" "$R"
[ "$RC" -eq 1 ] && ok || bad "A3 rc $RC (want 1): $OUT $ERR"
[ "$(grep -c "^bin/lib/sentry-triage.sh:$N: $TAG " <<<"$OUT")" -eq 2 ] && ok \
  || bad "A3 want 2 findings at bin/lib/sentry-triage.sh:$N (the call and the removal): $OUT"
case "$OUT" in *"removes AGENT_CALL_NO_TOOLS=1 (1 removed, 0 added)"*) ok ;; *) bad "A3 no removal finding: $OUT" ;; esac

# --- A4 near misses on the flag -------------------------------------------
for v in 'AGENT_CALL_NO_TOOLS=0 "$H/bin/agent-call.sh" x' \
         'AGENT_CALL_NO_TOOLS=10 "$H/bin/agent-call.sh" x' \
         'XAGENT_CALL_NO_TOOLS=1 "$H/bin/agent-call.sh" x' \
         'AGENT_CALL_NO_TOOLS=${NT} "$H/bin/agent-call.sh" x' \
         '"$H/bin/agent-call.sh" x  # AGENT_CALL_NO_TOOLS=1'; do
  reset_fx
  append bin/x.sh "$v"; commit "A4 $v"
  N=$(wc -l < "$R/bin/x.sh")
  lint --base "$B0" "$R"
  expect_red "A4 [$v]" "$N"
done

# --- A5 scope near misses -------------------------------------------------
# A5a a plain (non-export) assignment earlier in the function
reset_fx
append bin/x.sh 'f5() {' '  AGENT_CALL_NO_TOOLS=1' '  "$H/bin/agent-call.sh" x' '}'; commit A5a
lint --base "$B0" "$R"; expect_red "A5a non-export" "$(( $(wc -l < "$R/bin/x.sh") - 1 ))"
# A5b an export in a different, earlier function
reset_fx
append bin/x.sh 'g5() {' '  export AGENT_CALL_NO_TOOLS=1' '}' 'f5() {' '  "$H/bin/agent-call.sh" x' '}'; commit A5b
lint --base "$B0" "$R"; expect_red "A5b other function" "$(( $(wc -l < "$R/bin/x.sh") - 1 ))"
# A5c the marker two lines above with a blank line between
reset_fx
append bin/x.sh '# agent-call-tools: lane edits files in its own worktree' '' '"$H/bin/agent-call.sh" x'; commit A5c
lint --base "$B0" "$R"; expect_red "A5c blank line" "$(wc -l < "$R/bin/x.sh")"
# A5d a 9-character reason
reset_fx
append bin/x.sh '# agent-call-tools:  123456789  ' '"$H/bin/agent-call.sh" x'; commit A5d
lint --base "$B0" "$R"; expect_red "A5d 9 chars" "$(wc -l < "$R/bin/x.sh")"
# A5e a removed export while the call line is unchanged
reset_fx
cat > "$R/bin/lib/w.sh" <<'EOF'
w() {
  export AGENT_CALL_NO_TOOLS=1
  "$H/bin/agent-call.sh" w
}
EOF
commit A5e-base; B5=$(rd_git "$R" rev-parse HEAD)
sed -i '/export AGENT_CALL_NO_TOOLS=1/d' "$R/bin/lib/w.sh"; commit A5e
lint --base "$B5" "$R"
[ "$RC" -eq 1 ] && ok || bad "A5e removed export rc $RC (want 1): $OUT $ERR"
[ "$OUT" = "bin/lib/w.sh:2: $TAG removes AGENT_CALL_NO_TOOLS=1 (1 removed, 0 added)" ] && ok \
  || bad "A5e stdout [$OUT] (want bin/lib/w.sh:2: ... removes ...)"

# --- N1 the flag inline (ticket test 2) -----------------------------------
reset_fx
append bin/x.sh 'out=$(AGENT_CALL_NO_TOOLS=1 bin/agent-call.sh --stage x < "$prompt")'; commit N1
lint --base "$B0" "$R"; expect_clean N1

# --- N2 a valid marker (ticket test 3) ------------------------------------
reset_fx
append bin/x.sh '# agent-call-tools: lane edits files in its own worktree' "$CALL"; commit N2
lint --base "$B0" "$R"; expect_clean N2

# --- N3 delta only (ticket test 5) ----------------------------------------
reset_fx
sed -i 's/^  echo "\$out"$/  echo "out: $out"/' "$R/bin/lib/y.sh"; commit N3
[ "$(rd_git "$R" diff --stat "$B0" | grep -c y.sh)" -eq 1 ] || bad "N3 the fixture edit did not touch y.sh"
lint --base "$B0" "$R"; expect_clean N3

# --- N4 env / timeout / quoted value --------------------------------------
reset_fx
append bin/x.sh 'env A=1 AGENT_CALL_NO_TOOLS=1 "$H/bin/agent-call.sh" x' \
  "AGENT_CALL_NO_TOOLS=\"1\" timeout 9 \"\$H/bin/agent-call.sh\" x" \
  "AGENT_CALL_NO_TOOLS='1' \"\$H/bin/agent-call.sh\" x"; commit N4
lint --base "$B0" "$R"; expect_clean N4

# --- N5 the flag on an earlier continuation line --------------------------
reset_fx
append bin/x.sh 'if AGENT_CALL_LANE=box-chat AGENT_CALL_NO_TOOLS=1 \' \
  '    "$H/bin/agent-call.sh" chat p m \' '    900 "$TMP" "$TEXT"; then :; fi'; commit N5
lint --base "$B0" "$R"; expect_clean N5

# --- N6 an export earlier in the same function ----------------------------
reset_fx
append bin/x.sh 'f6() {' '  export AGENT_CALL_NO_TOOLS=1' '  local x=1' '  "$H/bin/agent-call.sh" x' '}' \
  'function g6 {' '  export AGENT_CALL_RUNNERS=claude AGENT_CALL_NO_TOOLS=1' '  "$H/bin/agent-call.sh" y' '}'; commit N6
lint --base "$B0" "$R"; expect_clean N6

# --- N7 a top-level call under a column-0 export --------------------------
reset_fx
append bin/x.sh 'export AGENT_CALL_NO_TOOLS=1' 'x=1' '"$H/bin/agent-call.sh" top'; commit N7
lint --base "$B0" "$R"; expect_clean N7

# --- N8 non-calls ---------------------------------------------------------
reset_fx
append bin/x.sh '# bin/agent-call.sh x runs here' 'echo "never run agent-call.sh or run-build.sh"' \
  'AC="$H/bin/agent-call.sh"' 'AGENT_CALL="${X:-$SELF/agent-call.sh}"'; commit N8
lint --base "$B0" "$R"; expect_clean N8

# --- N9 out of the scan set -----------------------------------------------
reset_fx
append tests/x.sh "$CALL"; append bin/x.py "$CALL"; append bin/agent-call.sh "$CALL"; commit N9
lint --base "$B0" "$R"; expect_clean N9

# --- N10 a deleted file that held a flagged call --------------------------
reset_fx
rm "$R/bin/lib/z.sh"; commit N10
lint --base "$B0" "$R"; expect_clean N10

# --- N11 a flagged call moved inside its file -----------------------------
reset_fx
cat > "$R/bin/lib/z.sh" <<'EOF'
#!/bin/bash
flagged() {
  echo before
  out=$(AGENT_CALL_NO_TOOLS=1 "$H/bin/agent-call.sh" --stage z < "$prompt")
}
EOF
commit N11
lint --base "$B0" "$R"; expect_clean N11

# --- N12 the flag removed and a valid marker added ------------------------
reset_fx
cat > "$R/bin/lib/z.sh" <<'EOF'
#!/bin/bash
flagged() {
  # agent-call-tools: this lane must write files in its worktree
  out=$("$H/bin/agent-call.sh" --stage z < "$prompt")
  echo "$out"
}
EOF
commit N12
lint --base "$B0" "$R"; expect_clean N12

# --- N13 a second hunk and a second file are judged -----------------------
reset_fx
for i in $(seq 1 200); do echo "echo filler $i" >> "$R/bin/x.sh"; done
commit N13-base; B13=$(rd_git "$R" rev-parse HEAD)
awk -v c="$CALL" '{ print } $0 == "echo filler 3" { print c }' "$R/bin/x.sh" > "$T/x13" && cat "$T/x13" > "$R/bin/x.sh"
append bin/x.sh '"$H/bin/agent-call.sh" late'
NA=$(grep -nF "$CALL" "$R/bin/x.sh" | cut -d: -f1); NB=$(wc -l < "$R/bin/x.sh")
append bin/lib/y.sh '"$H/bin/agent-call.sh" y2'; NY=$(wc -l < "$R/bin/lib/y.sh")
commit N13
[ "$(rd_git "$R" diff -U0 "$B13" -- bin/x.sh | grep -c '^@@')" -eq 2 ] || bad "N13 the fixture diff of bin/x.sh is not 2 hunks"
lint --base "$B13" "$R"
[ "$RC" -eq 1 ] && ok || bad "N13 rc $RC (want 1): $OUT $ERR"
for want in "bin/x.sh:$NA: $TAG" "bin/x.sh:$NB: $TAG" "bin/lib/y.sh:$NY: $TAG"; do
  grep -qF "$want " <<<"$OUT" && ok || bad "N13 stdout does not name [$want]: $OUT"
done
[ "$(grep -c . <<<"$OUT")" -eq 3 ] && ok || bad "N13 want 3 findings: $OUT"

# --- N14 bad args ---------------------------------------------------------
reset_fx
lint --base nosuchref "$R"
[ "$RC" -eq 2 ] && ok || bad "N14 --base nosuchref rc $RC (want 2)"
case "$ERR" in *nosuchref*) ok ;; *) bad "N14 stderr does not name nosuchref: $ERR" ;; esac
mkdir -p "$T/nogit/bin"; echo "$CALL" > "$T/nogit/bin/x.sh"
lint "$T/nogit"
[ "$RC" -eq 2 ] && ok || bad "N14 non-git root rc $RC (want 2): $OUT $ERR"
lint --bogus "$R"
[ "$RC" -eq 2 ] && ok || bad "N14 --bogus rc $RC (want 2)"

# --- N15 this checkout's own diff -----------------------------------------
if git -C "$DIR" rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null; then
  lint --base origin/main "$DIR"
  [ "$RC" -eq 0 ] && ok || bad "N15 this checkout against origin/main rc $RC (want 0): $OUT $ERR"
else
  echo "N15 skipped: origin/main does not resolve in $DIR"
fi

# --- P1/P2 the production entry point -------------------------------------
# The fixture is this checkout's HEAD with the lint's working files laid over
# it, so the case means the same thing before and after the commit.
F="$T/fx"
mkdir -p "$F"
git -C "$DIR" archive HEAD | tar -x -C "$F" || { echo "FAIL: cannot archive HEAD"; exit 1; }
for p in bin/agent-call-no-tools-lint.sh bin/rules-pack.sh catalog/rules-pack.tsv; do
  [ -f "$DIR/$p" ] && cp -p "$DIR/$p" "$F/$p"
done
rd_fixture_repo "$F" || { echo "FAIL: cannot build the P1 fixture"; exit 1; }
rd_git "$F" config gc.auto 0; rd_git "$F" config maintenance.auto false
FB=$(rd_git "$F" rev-parse HEAD)
append_f() { printf '%s\n' "$1" >> "$F/bin/lib/sentry-triage.sh"; }
append_f '"$H/bin/agent-call.sh" p1 fleet m 30 "$raw" "@$pf"'
N=$(wc -l < "$F/bin/lib/sentry-triage.sh")
rd_git "$F" add -A && rd_git "$F" commit -qm P1
mkdir -p "$T/nolg"
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only agent-call-no-tools --runner local --out "$T/o1"
[ "$RC" -eq 1 ] && ok || bad "P1 rules-pack rc $RC (want 1): $OUT $ERR"
case "$OUT" in "agent-call-no-tools: bin/lib/sentry-triage.sh:$N: $TAG "*) ok ;;
  *) bad "P1 stdout [$OUT] (want agent-call-no-tools: bin/lib/sentry-triage.sh:$N: $TAG ...)" ;; esac
[ "$(grep -c . <<<"$OUT")" -eq 1 ] && ok || bad "P1 want exactly 1 routed line: $OUT"
grep -qiE 'auth(z|orization|entication)?[- ]?bypass' <<<"$OUT" && ok || bad "P1 stdout does not match the auth-bypass ERE"
[ "$(jq -r '.components[0].id + " " + .components[0].state' "$T/o1/summary.json" 2>/dev/null)" = "agent-call-no-tools red" ] && ok \
  || bad "P1 summary.json components[0] $(jq -c '.components[0]' "$T/o1/summary.json" 2>/dev/null) (want agent-call-no-tools red)"

rd_git "$F" reset -q --hard "$FB"
append_f 'AGENT_CALL_NO_TOOLS=1 "$H/bin/agent-call.sh" p2 fleet m 30 "$raw" "@$pf"'
rd_git "$F" add -A && rd_git "$F" commit -qm P2
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only agent-call-no-tools --runner local --out "$T/o2"
[ "$RC" -eq 0 ] && ok || bad "P2 rules-pack rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "P2 stdout [$OUT] (want empty)"
[ "$(jq -r '.components[0].id + " " + .components[0].state' "$T/o2/summary.json" 2>/dev/null)" = "agent-call-no-tools green" ] && ok \
  || bad "P2 summary.json components[0] $(jq -c '.components[0]' "$T/o2/summary.json" 2>/dev/null) (want agent-call-no-tools green)"

echo "agent-call-no-tools-lint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
