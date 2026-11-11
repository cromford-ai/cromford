#!/bin/bash
# tests/plan-size-gate-not-needed.bh-8739-test.sh — BH-8739: when the slice gate
# merges a split down to one child (bin/run-decompose.sh rc 4,
# DECOMPOSE_NOT_NEEDED), the size gate builds the parent whole: no RESULT, no
# exit, the build goes on. rc 0 and rc 3 keep their RESULT lines.
#
# The shipped `# >>> size gate` block is extracted verbatim from the composed
# run-build (tests/lib/rb-all.sh) and driven with a stub decomposer.
# No network. Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-size-gate-not-needed.bh-8739-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "plan-size-gate-not-needed.bh-8739: jq is required"; exit 1; }

mkdir -p "$T/h/bin" "$T/h/state" "$T/h/logs" "$T/h/flags" "$T/h/catalog" "$T/stub"
for S in size-gate.sh size-scope.sh size-threshold.sh planned-files.sh fleet-conf.sh; do
  [ -f "$DIR/bin/$S" ] && cp "$DIR/bin/$S" "$T/h/bin/"
done
awk '/^# >>> size gate/{f=1;next} /^# <<< size gate/{exit} f' "$RB_ALL" > "$T/sizeblock.sh"
[ -s "$T/sizeblock.sh" ] && ok || bad "could not extract the size-gate block"
awk '/^# >>> size enforce switch/{f=1;next} /^# <<< size enforce switch/{exit} f' "$RB_ALL" > "$T/switch.sh"
[ -s "$T/switch.sh" ] && ok || bad "could not extract the size enforce switch"
# The stub decomposer answers $DEC_RC and writes what the real one writes.
cat > "$T/h/bin/run-decompose.sh" <<'EOS'
#!/bin/bash
case "$DEC_RC" in
  0) printf 'WD-9.1\nWD-9.2\n' > "$4/children.txt" ;;
  3) echo "DECOMPOSE_HELD: awaiting a reply to the proposed split into 6 children" >> "$4/decompose-run.txt" ;;
  4) echo "DECOMPOSE_NOT_NEEDED: no slice has a reason to stand alone (12 slices fit one build)" >> "$4/decompose-run.txt" ;;
esac
exit "$DEC_RC"
EOS
chmod +x "$T/h/bin/run-decompose.sh"
for S in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 1\n' "$S" "$T" > "$T/stub/$S"; chmod +x "$T/stub/$S"
done
PLAN=$(printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n## Size\nFILES: 30\nLINES: 2400\n\nKIND: feature\nSIZE: L\n')

drive() { # drive <decompose-rc> — prints the block's output; sets RC
  rm -rf "$T/b"; mkdir -p "$T/b"; printf '%s\n' "$PLAN" > "$T/b/plan.md"
  OUT=$( env PATH="$T/stub:$PATH" HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 SIZE_GATE_ENFORCE=1 DEC_RC="$1" SWITCHBLOCK="$T/switch.sh" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { echo "BB=$1"; }
             job_artifact_put() { :; }
             . "$SWITCHBLOCK"
             . "$0"; echo "CONTINUED"' "$T/sizeblock.sh" 2>&1 ); RC=$?
}

drive 4
grep -q CONTINUED <<<"$OUT" && ok || bad "N1: rc 4 must fall through and build whole (got: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "N1: rc 4 writes no RESULT: $OUT" || ok
grep -q 'SIZE: DECOMPOSE_NOT_NEEDED — no slice has a reason to stand alone, building whole' "$T/b/pipeline.log" \
  && ok || bad "N1: the log line: $(cat "$T/b/pipeline.log")"
drive 0
grep -q 'RESULT=DECOMPOSED WD-9.1,WD-9.2' <<<"$OUT" && ok || bad "N2: rc 0 is DECOMPOSED: $OUT"
grep -q CONTINUED <<<"$OUT" && bad "N2: rc 0 must stop the build" || ok
[ "$RC" = 0 ] && ok || bad "N2: rc 0 exits 0, got $RC"
drive 3
grep -q 'RESULT=BUILD_DEFERRED held at split — DECOMPOSE_HELD: awaiting a reply' <<<"$OUT" && ok || bad "N3: rc 3 is BUILD_DEFERRED: $OUT"
[ "$RC" = 3 ] && ok || bad "N3: rc 3 exits 3, got $RC"
drive 1
grep -q 'RESULT=DECOMPOSE_FAILED' <<<"$OUT" && ok || bad "N4: rc 1 is DECOMPOSE_FAILED: $OUT"
grep -q CONTINUED <<<"$OUT" && bad "N4: a failed split must stop the build" || ok

echo "plan-size-gate-not-needed.bh-8739: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
