#!/bin/bash
# tests/builder-gate-topred.bh-9559-test.sh — the builder gate runs the top
# GATE_RED suites as tier `topred` (BH-9583, BH-9559 part D item 10).
#
# The real gate and the real selector in a committed scratch repo. The jobs
# client is a fake (TEST_IMPACT_GATE_JOBS_CLIENT): it answers setting-get from
# FAKE_<KEY> env (rc 2 when unset, rc 1 when FAKE_SETTINGS_DOWN=1) and
# gate-red-top by printing worker/jobs/test/fixtures/gate-red-top.bh-9559.json
# (or FAKE_TOPRED_JSON, or rc 1 when FAKE_TOPRED_DOWN=1). It logs each call.
# The diff touches bin/lib/widget.sh and the self suite tests/aa-self-test.sh.
#
#   V1  the verb builds GET /api/gate-red/top?repo=o%2Fr-fixture&n=5&days=14 and
#       refuses an empty or non-integer arg with rc 1
#   T1  flag 0: `topred: off (builder_gate.topred.enabled=0)`, run list = map only
#   T2  knobs absent (fallbacks 5, 14): the top GATE_RED suite runs, the --table
#       row says `topred 3 GATE_RED build(s) in 14d`, the call is `<repo> 5 14`
#   T3  --cap 2: the self suite, then the top topred suite; the rest left to CI
#   T4  flag 0 makes no gate-red-top call, and the run list equals T1's
#   T5  a read failure: `topred: off (read failed rc 1)`, rc 0, run list = T1's
#   T6  settings down, a bad flag, --runner plan, the sandbox with no fake
#   T7  a ranked suite this checkout lacks is dropped by name; a non-tests path too
#   T8  builder_gate.topred_n=1: the call asks for 1
#   T9  a fake bin/suite-reuse.sh sees one plan call whose list holds the topred suite
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
if ! command -v git > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "builder-gate-topred: SKIPPED — needs git and jq"
  echo "builder-gate-topred: $PASS passed, $FAIL failed"; exit 0
fi
FIXTURE="$DIR/worker/jobs/test/fixtures/gate-red-top.bh-9559.json"
FIX=tests/fixround-closure-lint.bh-5064-test.sh

# ── V1: the jobs-client verb, against a stub _jobs_req ─────────────────────
VERB="$DIR/bin/jobs-client.d/bh-9583-gate-red-top.sh"
OUT=$(
  _jobs_req() { printf '%s %s\n' "$1" "$2"; }
  # shellcheck source=/dev/null
  . "$VERB" 2>/dev/null || { echo "no verb"; exit 9; }
  jc_verb_gate_red_top o/r-fixture 5 14; echo "rc=$?"
  jc_verb_gate_red_top "" 5 14; echo "rc=$?"
  jc_verb_gate_red_top o/r-fixture x 14; echo "rc=$?"
  jc_verb_gate_red_top o/r-fixture 5; echo "rc=$?"
)
if grep -qxF 'GET /api/gate-red/top?repo=o%2Fr-fixture&n=5&days=14' <<< "$OUT" \
   && [ "$(grep -c '^rc=' <<< "$OUT")" = 4 ] && [ "$(grep -c '^rc=1$' <<< "$OUT")" = 3 ] \
   && [ "$(grep -c '^GET ' <<< "$OUT")" = 1 ]; then ok "V1 the verb builds the route path and refuses bad args"
else bad "V1 verb: $OUT"; fi

# ── the scratch checkout ────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/bin/lib" "$R/tests/lib" "$R/catalog"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
printf '#!/bin/bash\nwidget_close_all() { echo closed; }\n' > "$R/bin/lib/widget.sh"
stub() { printf '#!/bin/bash\necho "%s: 1 passed, 0 failed"\n' "$1" > "$R/$1"; chmod +x "$R/$1"; }
for s in tests/aa-self-test.sh "$FIX" tests/b-test.sh tests/c-test.sh; do stub "$s"; done
cat > "$R/tests/widget-reads-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'widget_close_all()' "$DIR/bin/lib/widget.sh" || exit 1
echo "widget-reads: 1 passed, 0 failed"
SH
G() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"
echo '# touched' >> "$R/tests/aa-self-test.sh"
G commit -qam touch || exit 1
G remote add origin https://github.com/acme/r-fixture.git

cat > "$T/fake-jc.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$JC_LOG"
case "$1" in
  setting-get)
    [ "${FAKE_SETTINGS_DOWN:-0}" = 1 ] && exit 1
    v=$(printf '%s' "$2" | tr 'a-z.' 'A-Z_'); v="FAKE_$v"
    [ -n "${!v+x}" ] || exit 2
    printf '%s\n' "${!v}" ;;
  gate-red-top)
    [ "${FAKE_TOPRED_DOWN:-0}" = 1 ] && exit 1
    cat "${FAKE_TOPRED_JSON:-$FAKE_FIXTURE}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fake-jc.sh"
export HARNESS="$T/empty" HARNESS_TEST_SANDBOX=1 SUITE_REUSE=off JC_LOG="$T/jc.log" FAKE_FIXTURE="$FIXTURE"
export TEST_IMPACT_GATE_JOBS_CLIENT="$T/fake-jc.sh"
unset SUITE_REUSE_REPO
gate() { : > "$JC_LOG"; ( cd "$R" && TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv" bin/test-impact-gate.sh --base "$BASE" --runner local "$@" 2>&1 ); }
ran()  { grep '^impact-gate: done ' <<< "$1" | sed 's/^impact-gate: done //; s/ rc=.*//'; }

# ── T1: flag 0 is the map selection only ───────────────────────────────────
OUT1=$(FAKE_BUILDER_GATE_TOPRED_ENABLED=0 gate); RC1=$?
RUN1=$(ran "$OUT1")
if [ "$RC1" = 0 ] && grep -qxF 'topred: off (builder_gate.topred.enabled=0)' <<< "$OUT1" \
   && [ "$RUN1" = "$(printf 'tests/aa-self-test.sh\ntests/widget-reads-test.sh')" ]; then ok "T1 flag 0: off, map selection only"
else bad "T1 rc=$RC1 run=[$RUN1]: $OUT1"; fi
# T4: no ranking call with the flag at 0.
JCL=$(cat "$JC_LOG")
if ! grep -q '^gate-red-top' <<< "$JCL"; then ok "T4 flag 0 makes no gate-red-top call"; else bad "T4 jc.log: $JCL"; fi

# ── T2: the observable ─────────────────────────────────────────────────────
OUT2=$(gate --table "$T/t2.md"); RC2=$?
JCL=$(cat "$JC_LOG"); TBL=$(cat "$T/t2.md" 2>/dev/null)
if [ "$RC2" = 0 ] && grep -qxF "impact-gate: done $FIX rc=0" <<< "$OUT2" \
   && grep -qF "| \`$FIX\` | topred 3 GATE_RED build(s) in 14d |" <<< "$TBL" \
   && grep -qxF 'gate-red-top acme/r-fixture 5 14' <<< "$JCL" \
   && grep -qxF "topred: 2 suite(s) from the GATE_RED ranking (14d, top 5): $FIX tests/b-test.sh" <<< "$OUT2"; then
  ok "T2 the top GATE_RED suite runs as tier topred, and the table names the tier"
else bad "T2 rc=$RC2 jc=[$JCL] table=[$TBL]: $OUT2"; fi
RUN2=$(ran "$OUT2")
if [ "$RUN2" = "$(printf 'tests/aa-self-test.sh\n%s\ntests/b-test.sh\ntests/widget-reads-test.sh' "$FIX")" ]; then
  ok "T2 order: self, then topred in ranking order, then reads"
else bad "T2 order: [$RUN2]"; fi
H1=$(grep '^| suite' "$T/t2.md")
[ "$H1" = "| suite | why |" ] && ok "T2 the table header is unchanged" || bad "T2 header: $H1"

# ── T3: inside the cap ─────────────────────────────────────────────────────
printf '{"suites":[{"suite":"tests/b-test.sh","count":4,"last_at":"x"},{"suite":"%s","count":3,"last_at":"x"},{"suite":"tests/c-test.sh","count":1,"last_at":"x"}]}\n' "$FIX" > "$T/three.json"
OUT3=$(FAKE_TOPRED_JSON="$T/three.json" gate --cap 2); RC3=$?
RUN3=$(ran "$OUT3")
LEFT3=$(awk '/^impact-gate: left to CI by the cap \(/ { on = 1; next } on && /^plan:   / { sub(/^plan:   /, ""); print; next } { on = 0 }' <<< "$OUT3")
if [ "$RC3" = 0 ] && grep -q 'running up to 2 of 5 selected' <<< "$OUT3" \
   && [ "$RUN3" = "$(printf 'tests/aa-self-test.sh\ntests/b-test.sh')" ] \
   && [ "$LEFT3" = "$(printf '%s\ntests/c-test.sh\ntests/widget-reads-test.sh' "$FIX")" ]; then
  ok "T3 the cap holds: self, then the top topred suite; the rest left to CI"
else bad "T3 rc=$RC3 run=[$RUN3] left=[$LEFT3]: $OUT3"; fi

# ── T5: a read failure is today's gate ─────────────────────────────────────
OUT5=$(FAKE_TOPRED_DOWN=1 gate); RC5=$?
if [ "$RC5" = 0 ] && grep -qxF 'topred: off (read failed rc 1)' <<< "$OUT5" && [ "$(ran "$OUT5")" = "$RUN1" ]; then
  ok "T5 a read failure: off, rc 0, the flag-off run list"
else bad "T5 rc=$RC5: $OUT5"; fi

# ── T6: the other off paths ────────────────────────────────────────────────
OUT=$(FAKE_SETTINGS_DOWN=1 gate)
if grep -qxF 'topred: off (settings unreadable)' <<< "$OUT" && [ "$(ran "$OUT")" = "$RUN1" ]; then ok "T6 settings down: off"; else bad "T6 settings down: $OUT"; fi
OUT=$(FAKE_BUILDER_GATE_TOPRED_ENABLED=yes gate)
if grep -qxF 'topred: off (bad builder_gate.topred.enabled)' <<< "$OUT" && [ "$(ran "$OUT")" = "$RUN1" ]; then ok "T6 bad flag: off"; else bad "T6 bad flag: $OUT"; fi
OUT=$(FAKE_BUILDER_GATE_TOPRED_N=0 gate)
if grep -qxF 'topred: off (bad builder_gate.topred_n)' <<< "$OUT"; then ok "T6 bad n: off"; else bad "T6 bad n: $OUT"; fi
: > "$JC_LOG"
OUT=$( cd "$R" && bin/test-impact-gate.sh --base "$BASE" --runner plan 2>&1 ); JCL=$(cat "$JC_LOG")
if grep -qxF 'topred: off (runner plan)' <<< "$OUT" && [ -z "$JCL" ]; then ok "T6 --runner plan: off, no client call"; else bad "T6 plan jc=[$JCL]: $OUT"; fi
OUT=$( cd "$R" && env -u TEST_IMPACT_GATE_JOBS_CLIENT TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv" bin/test-impact-gate.sh --base "$BASE" --runner local 2>&1 )
if grep -qxF 'topred: off (test sandbox, no fake client)' <<< "$OUT" && [ "$(ran "$OUT")" = "$RUN1" ]; then ok "T6 sandbox, no fake: off"; else bad "T6 sandbox: $OUT"; fi

# ── T7: a suite this checkout lacks, and a path that is not a suite ────────
printf '{"suites":[{"suite":"tests/gone-test.sh","count":2,"last_at":"x"},{"suite":"bin/x.sh","count":2,"last_at":"x"},{"suite":"%s","count":1,"last_at":"x"}]}\n' "$FIX" > "$T/gone.json"
OUT=$(FAKE_TOPRED_JSON="$T/gone.json" gate); RC=$?
if [ "$RC" = 0 ] && grep -qxF 'topred: dropped tests/gone-test.sh (not in this checkout)' <<< "$OUT" \
   && grep -qxF 'topred: dropped bin/x.sh (not a tests/[mc/]*.sh path)' <<< "$OUT" \
   && grep -qxF "impact-gate: done $FIX rc=0" <<< "$OUT" && ! grep -q 'gone-test' <<< "$(ran "$OUT")"; then
  ok "T7 dropped by name; the rest still run"
else bad "T7 rc=$RC: $OUT"; fi

# ── T8: the n row ──────────────────────────────────────────────────────────
OUT=$(FAKE_BUILDER_GATE_TOPRED_N=1 FAKE_BUILDER_GATE_TOPRED_WINDOW_DAYS=30 gate); JCL=$(cat "$JC_LOG")
if grep -qxF 'gate-red-top acme/r-fixture 1 30' <<< "$JCL"; then ok "T8 the rows reach the call"; else bad "T8 jc=[$JCL]"; fi

# ── T9: no reuse path of its own ───────────────────────────────────────────
cat > "$R/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$SR_LOG"
while [ $# -gt 0 ]; do
  case "$1" in --suites) in=$2; shift ;; --run) run=$2; shift ;; --reused) ru=$2; shift ;;
    --fingerprints) fp=$2; shift ;; --reds) rd=$2; shift ;; esac; shift
done
[ -n "${in:-}" ] && { cp "$in" "$SR_LOG.in"; cp "$in" "$run"; : > "$ru"; : > "$fp"; : > "$rd"; }
exit 0
SH
chmod +x "$R/bin/suite-reuse.sh"
OUT=$(SR_LOG="$T/sr.log" SUITE_REUSE=on gate); SRL=$(cat "$T/sr.log" 2>/dev/null); SRIN=$(cat "$T/sr.log.in" 2>/dev/null)
if [ "$(grep -c '^plan ' <<< "$SRL")" = 1 ] && grep -qxF "$FIX" <<< "$SRIN" \
   && [ "$(grep -vc '^plan \|^record ' <<< "$SRL")" = 0 ]; then
  ok "T9 one plan call, the topred suite in its list, no other reuse call"
else bad "T9 sr.log=[$SRL] in=[$SRIN]: $OUT"; fi

echo "builder-gate-topred: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
