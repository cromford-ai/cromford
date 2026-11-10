#!/bin/bash
# tests/suite-ledger-gates.bh-9177-test.sh — both gates read and write the
# suite ledger (BH-9177, slice C1 of #9063; acceptance test 1 of #9063, AT1: G1, G2, G5, S1, S2, S4).
#
# The REAL bin/test-impact-gate.sh and the REAL bin/selection-gate.sh, each in
# a committed scratch repo (origin https://github.com/acme/widget.git) with the
# real helper and its closure. SUITE_REUSE_CURL points at worker.fetch over a
# file-backed node:sqlite database, so the ledger is the SQL the worker ships
# (trust row: image). The selection gate gets a stub planner and a stub runner
# that answers `--image-id` and prints remote-gate's IMAGE/PASS/FAIL/TIME lines.
# tests/target-test.sh is S; tests/always-test.sh is an always suite.
#
#   G1  test-impact-gate, SUITE_IMAGE_ID=img-i: run 1 runs S and records ok;
#       run 2 prints `impact-gate: reused S from <run_id>` and does not run S
#   G2  run 3 with SUITE_IMAGE_ID=img-i2: S runs
#   G3  a fail row for S at img-i, TEST_IMPACT_GATE_RERUN_RED=0: S does not run,
#       `impact-gate: red from the suite ledger S (run <id>)`, FAILED, rc 1,
#       --failed lists S, --table tags `(red in ledger <id>)`
#   G4  the same with S the only suite: rc 1, the runner runs nothing
#   G5  the same row with --rerun-red, and with the knob unset (fallback 1): S runs, rc 0
#   G6  a helper whose reds are not a partition of its input: off, all run
#   G7  ledger down: verdict and rc equal a helper-less run's
#   G8  on a Fly machine (FLY_IMAGE_REF, no SUITE_IMAGE_ID): image fly:<ref>
#   G9  no curl, flyctl, ssh or wget call on the whole G path
#   S1  selection-gate, SELECTION_GATE_SUITE_REUSE=1: run 1 sends S and writes an
#       ok row with the TIME duration; run 2 does not send S, gate.txt
#       `reuse: ran 1 reused 1 green, 0 red of 2 (image fly:...+rg:<12hex>) ...`, rc 0
#   S2  run 3 with the runner's image testhost-2: S is sent
#   S3  a fail row for S, SELECTION_GATE_RERUN_RED=0: S is not sent, red: S, rc 1;
#       S3b S quarantined: noted: S, rc 0
#   S4  the same row, SELECTION_GATE_RERUN_RED=1: S is sent; a PASS is rc 0
#   S5  record rules: PASS ok, FAIL rc 1 fail, rc 127 no row, BLIND no row,
#       a host-noted red no row, a quarantined red fail
#   S6  the run's IMAGE differs from the probe's, or is absent: no row,
#       `record skipped (image moved)`, verdict unchanged
#   S7  probe rc 125 / `IMAGE -` / an id over 128 chars: `reuse: off (<why>)`,
#       everything sent, verdict equals the knob-0 run's
#   S8  wrong tenant: a green for S in acme/other: S is sent for acme/widget
#   S9  knob unset: the 10-line gate.txt, one runner call, no probe; each new
#       knob's registry default equals its code fallback; no network
#   S10 the other off reasons: no reuse lib (no probe), an incoherent helper
#       answer, the ledger down (`off (ledger unreachable); record failed`)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/suite-ledger-gates.bh-9177-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=2026-11-06T00:00:00Z
PASS=0 FAIL=0
TAB=$(printf '\t')
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 \
   || ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "suite-ledger-gates: SKIPPED — needs git, jq and node with node:sqlite"
  echo "suite-ledger-gates: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write > /dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json the worker imports"
fi
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

# ── the scratch checkout ────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/suite-reuse.sh bin/fast-lints.sh \
         bin/selection-gate.sh bin/remote-gate.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/catalog/selection-gate-host-notes.d"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
cat > "$R/tests/target-test.sh" <<'SH'
#!/bin/bash
n=$(cat "$MARK_DIR/target" 2>/dev/null || echo 0); echo $((n + 1)) > "$MARK_DIR/target"
echo "target: 1 passed, 0 failed"
exit "${TARGET_RC:-0}"
SH
cat > "$R/tests/always-test.sh" <<'SH'
#!/bin/bash
n=$(cat "$MARK_DIR/always" 2>/dev/null || echo 0); echo $((n + 1)) > "$MARK_DIR/always"
echo "always: 1 passed, 0 failed"
SH
for s in p f1 f127 bl hn qr; do printf '#!/bin/bash\nexit 0\n' > "$R/tests/$s-test.sh"; done
printf 'tests/hn-test.sh\thost-timing\tFAIL: H1 host clock\ta wall-clock bound on a shared host (fixture)\n' \
  > "$R/catalog/selection-gate-host-notes.d/fixture.tsv"
printf 'tests/always-test.sh\n' > "$R/catalog/test-impact-always.txt"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
G "$R" init -q -b main && G "$R" add -A && G "$R" commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
BASE=$(git -C "$R" rev-parse HEAD)
G "$R" checkout -q -b ticket/bh-1
echo '# touched' >> "$R/tests/target-test.sh"
G "$R" commit -qam "touch the target suite" || exit 1
G "$R" remote add origin https://github.com/acme/widget.git
RG_BLOB=$(git -C "$R" rev-parse HEAD:bin/remote-gate.sh)
# R0: no helper (the shape before BH-5354).
git clone -q "$R" "$T/r0" && rm "$T/r0/bin/suite-reuse.sh" || { echo "cannot build the helper-less copy"; exit 1; }
R0="$T/r0"

# ── the stub ledger: worker.fetch over a file-backed node:sqlite D1 ────────
cat > "$T/driver.mjs" <<'EOF'
import { readFileSync, existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const [, , dir, dbfile, method, path, bodyf, cls] = process.argv;
const fresh = !existsSync(dbfile);
const db = new DatabaseSync(dbfile);
if (fresh) {
  db.exec(readFileSync(dir + '/worker/jobs/schema.sql', 'utf8'));
  db.exec("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('lib.suite-reuse.suite_reuse_trust','image','t','t','2026-11-06T00:00:00Z')");
}
if (method === 'SQL') { db.exec(path); process.exit(0); }
if (method === 'Q') { console.log(JSON.stringify(db.prepare(path).all())); process.exit(0); }
const { d1 } = await import(dir + '/worker/jobs/test/lib/d1-sqlite.bh-1030.js');
const worker = (await import(dir + '/worker/jobs/src/index.js')).default;
const headers = { 'content-type': 'application/json',
  ...(cls === 'ci' ? { 'x-suite-ledger-token': 'tok-fixture' } : { authorization: 'Bearer SECRET-fixture' }) };
const res = await worker.fetch(new Request('https://jobs.test' + path, { method, headers, body: readFileSync(bodyf) }),
  { DB: d1(db), HARNESS_SECRET: 'SECRET-fixture', SUITE_LEDGER_TOKEN: 'tok-fixture' });
process.stdout.write((await res.text()) + '\n' + res.status + '\n');
EOF
cat > "$T/stub.sh" <<EOF
#!/bin/bash
echo "\$1 \$2" >> "$T/calls"
[ "\${STUB_MODE:-}" = exit7 ] && exit 7
exec node "$T/driver.mjs" "$DIR" "\${LEDGER_DB:-$T/ledger.db}" "\$@" 2>/dev/null
EOF
chmod +x "$T/stub.sh"
q() { node "$T/driver.mjs" "$DIR" "${LEDGER_DB:-$T/ledger.db}" Q "$1" 2>/dev/null; }

# Every network tool on PATH is a trap that logs the call (G9, S9).
mkdir -p "$T/trap"
for c in curl wget flyctl ssh; do printf '#!/bin/bash\necho "%s $*" >> "%s/net-calls"\nexit 99\n' "$c" "$T" > "$T/trap/$c"; done
chmod +x "$T/trap"/*
: > "$T/net-calls"
export PATH="$T/trap:$PATH"

export SUITE_REUSE_CURL="$T/stub.sh" JOBS_URL=https://jobs.invalid HARNESS_SECRET=SECRET-fixture
export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
unset SUITE_LEDGER_URL SUITE_LEDGER_TOKEN SUITE_REUSE GITHUB_ACTIONS STUB_MODE SUITE_REUSE_RUN_KEY SUITE_REUSE_REPO \
  SUITE_REUSE_CLASS SUITE_REUSE_CTX FLY_IMAGE_REF ImageOS ImageVersion SUITE_IMAGE_ID TEST_IMPACT_GATE_RERUN_RED \
  TEST_IMPACT_GATE_FRESH_MAIN SELECTION_GATE_SUITE_REUSE SELECTION_GATE_RERUN_RED SELECTION_GATE_IMAGE_PROBE_S \
  SELECTION_GATE_BASELINE_RUN CI_QUARANTINE REPO_SLUG HARNESS_CHECKOUT
: > "$T/fast.empty"; : > "$T/calls"

# gate <tag> <repo> [args...] — the builder gate; out $T/<tag>.out, table
# $T/<tag>.md, failed list $T/<tag>.failed, rc GRC, markers $T/mark-<tag>.
gate() {
  local tag="$1" repo="$2"; shift 2
  mkdir -p "$T/mark-$tag"
  ( cd "$repo" && MARK_DIR="$T/mark-$tag" bin/test-impact-gate.sh --base "$BASE" --runner local \
      --table "$T/$tag.md" --failed "$T/$tag.failed" "$@" ) > "$T/$tag.out" 2>&1
  GRC=$?
}
marks() { cat "$T/mark-$1/$2" 2>/dev/null || echo 0; }
verdict() { grep '^impact-gate: ran [0-9]* of [0-9]* selected suites via ' "$T/$1.out" | sed 's/^impact-gate: ran [0-9]* of /ran ? of /'; }
S=tests/target-test.sh

# ── G1 / G2 ─────────────────────────────────────────────────────────────────
export LEDGER_DB="$T/g1.db" SUITE_IMAGE_ID=img-i
SUITE_REUSE_RUN_KEY=g1-run1 gate g1a "$R"
{ [ "$GRC" = 0 ] && [ "$(marks g1a target)" = 1 ]; } && ok "G1 run 1 runs S, rc 0" || bad "G1 run 1 rc=$GRC: $(cat "$T/g1a.out")"
[ "$(q "SELECT status FROM suite_results WHERE run_id='g1-run1' AND suite='$S'")" = '[{"status":"ok"}]' ] \
  && ok "G1 run 1 records an ok row for S" || bad "G1 rows: $(q 'SELECT suite, status, run_id FROM suite_results')"
SUITE_REUSE_RUN_KEY=g1-run2 gate g1b "$R"
{ [ "$GRC" = 0 ] && [ "$(marks g1b target)" = 0 ] && grep -qE "^impact-gate: reused $S from g1-run1 \([0-9]+s\)$" "$T/g1b.out"; } \
  && ok "G1 run 2 on tree T, image I: S is reused, not run" || bad "G1 run 2 rc=$GRC marks=$(marks g1b target): $(cat "$T/g1b.out")"
SUITE_IMAGE_ID=img-i2 SUITE_REUSE_RUN_KEY=g2 gate g2 "$R"
{ [ "$GRC" = 0 ] && [ "$(marks g2 target)" = 1 ] && grep -qxF 'suite-reuse: image img-i2' "$T/g2.out"; } \
  && ok "G2 image I2: S runs" || bad "G2 marks=$(marks g2 target): $(cat "$T/g2.out")"

# ── G3 / G4 / G5: a red row ─────────────────────────────────────────────────
export LEDGER_DB="$T/g3.db"
TARGET_RC=1 SUITE_REUSE_RUN_KEY=g3-red gate g3a "$R"
[ "$(q "SELECT status FROM suite_results WHERE suite='$S'")" = '[{"status":"fail"}]' ] && ok "G3 a red run records a fail row" \
  || bad "G3 seed: $(q 'SELECT * FROM suite_results') out: $(cat "$T/g3a.out")"
TEST_IMPACT_GATE_RERUN_RED=0 SUITE_REUSE_RUN_KEY=g3-b gate g3 "$R"
[ "$(marks g3 target)" = 0 ] && ok "G3 knob 0: S does not run" || bad "G3 S ran $(marks g3 target) time(s): $(cat "$T/g3.out")"
grep -qxF "impact-gate: red from the suite ledger $S (run g3-red)" "$T/g3.out" && ok "G3 the red line names S and its run" \
  || bad "G3 no red line: $(cat "$T/g3.out")"
{ [ "$GRC" = 1 ] && grep -qE '^impact-gate: ran 1 of 2 selected suites via local: FAILED \(rc 1\)' "$T/g3.out"; } \
  && ok "G3 verdict FAILED (rc 1), rc 1" || bad "G3 rc=$GRC verdict: $(verdict g3)"
[ "$(cat "$T/g3.failed")" = "$S" ] && ok "G3 --failed lists S" || bad "G3 --failed: $(cat "$T/g3.failed")"
grep -qF "| \`$S\` | (red in ledger g3-red) " "$T/g3.md" && ok "G3 the --table row is tagged (red in ledger <id>)" || bad "G3 table: $(cat "$T/g3.md")"
[ "$(marks g3 always)" = 1 ] && ok "G3 the other suite still runs" || bad "G3 always marks $(marks g3 always)"
[ "$(q "SELECT count(*) AS n FROM suite_results WHERE run_id='g3-b'")" = '[{"n":0}]' ] && ok "G3 a red without a run is not recorded" \
  || bad "G3 rows of g3-b: $(q "SELECT * FROM suite_results WHERE run_id='g3-b'")"

# G4: --skip-suites drops the always suite, so S is the whole run list.
printf 'tests/always-test.sh\n' > "$T/skip.always"
TEST_IMPACT_GATE_RERUN_RED=0 SUITE_REUSE_RUN_KEY=g4-b gate g4 "$R" --skip-suites "$T/skip.always"
{ [ "$GRC" = 1 ] && [ "$(marks g4 target)" = 0 ] && [ "$(marks g4 always)" = 0 ] \
  && grep -qE '^impact-gate: ran 0 of [0-9]+ selected suites via local: FAILED \(rc 1\)' "$T/g4.out"; } \
  && ok "G4 S the only suite and red in the ledger: rc 1, nothing ran" || bad "G4 rc=$GRC: $(cat "$T/g4.out")"

TEST_IMPACT_GATE_RERUN_RED=0 SUITE_REUSE_RUN_KEY=g5a gate g5a "$R" --rerun-red
{ [ "$GRC" = 0 ] && [ "$(marks g5a target)" = 1 ] && ! grep -q 'red from the suite ledger' "$T/g5a.out"; } \
  && ok "G5 --rerun-red: S runs, a pass is rc 0" || bad "G5a rc=$GRC: $(cat "$T/g5a.out")"
SUITE_REUSE_RUN_KEY=g5b gate g5b "$R"
{ [ "$GRC" = 0 ] && [ "$(marks g5b target)" = 1 ]; } && ok "G5 knob unset (fallback 1): S runs" || bad "G5b rc=$GRC: $(cat "$T/g5b.out")"

# ── G6: an incoherent reds answer ───────────────────────────────────────────
cp -a "$R" "$T/rb"
cat > "$T/rb/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
[ "$1" = plan ] || exit 0
while [ $# -gt 0 ]; do case "$1" in --suites) in=$2 ;; --run) run=$2 ;; --reused) re=$2 ;; --reds) rd=$2 ;; esac; shift; done
cp "$in" "$run"; : > "$re"; printf 'tests/target-test.sh\tX1\tbuilder\n' > "$rd"
SH
gate g6 "$T/rb"
{ grep -qxF 'suite-reuse: off (helper answer did not match its input)' "$T/g6.out" && [ "$(marks g6 target)" = 1 ] \
  && [ "$GRC" = 0 ] && ! grep -q 'red from the suite ledger' "$T/g6.out"; } \
  && ok "G6 a suite in both --run and --reds: off, everything runs" || bad "G6 rc=$GRC: $(cat "$T/g6.out")"

# ── G7: the ledger does not answer ──────────────────────────────────────────
STUB_MODE=exit7 TARGET_RC=1 gate g7 "$R"; G7RC=$GRC
TARGET_RC=1 gate g7n "$R0"; G7NRC=$GRC
{ [ "$G7RC" = "$G7NRC" ] && [ "$(verdict g7)" = "$(verdict g7n)" ] && [ "$(marks g7 target)" = 1 ]; } \
  && ok "G7 ledger down: the verdict and rc of a helper-less run" || bad "G7 rc $G7RC vs $G7NRC, '$(verdict g7)' vs '$(verdict g7n)'"

# ── G8: a Fly machine's image id ────────────────────────────────────────────
export LEDGER_DB="$T/g8.db"
env -u SUITE_IMAGE_ID FLY_IMAGE_REF=registry.fly.io/x:dep-1 bash -c 'cd "$1" && MARK_DIR="$2" bin/test-impact-gate.sh --base "$3" --runner local' _ \
  "$R" "$T/mark-g8" "$BASE" > "$T/g8.out" 2>&1
grep -qxF 'suite-reuse: image fly:registry.fly.io/x:dep-1' "$T/g8.out" && ok "G8 on a Fly machine the image id is fly:<ref>" \
  || bad "G8: $(grep 'suite-reuse' "$T/g8.out")"

# ── G9 ──────────────────────────────────────────────────────────────────────
[ ! -s "$T/net-calls" ] && ok "G9 no network tool was called by the builder gate" || bad "G9 network calls: $(cat "$T/net-calls")"

# ── the selection gate ──────────────────────────────────────────────────────
unset SUITE_IMAGE_ID
IMG1=registry.fly.io/bh-testhost-fixture:testhost-1
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' ${STUB_SUITES:-tests/target-test.sh tests/always-test.sh} > "$out"; echo "mode=batch-selected" >> "$GITHUB_OUTPUT"; exit 0
SH
# The runner: `--image-id` answers STUB_IMAGE (STUB_PROBE_RC fails it). A run
# prints `IMAGE <STUB_RUN_IMAGE, else STUB_IMAGE>` (none with STUB_NO_IMAGE),
# then per suite PASS/FAIL/BLIND and `TIME 7 <suite>` the way remote-gate's
# job does, then the sections and the summary. A suite's rc is
# $STUB_DIR/rc/<basename> (default 0); $STUB_DIR/blind/<basename> makes it BLIND.
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$STUB_DIR/calls"
if [ "$1" = --image-id ]; then
  [ -n "${STUB_PROBE_RC:-}" ] && exit "$STUB_PROBE_RC"
  echo "IMAGE ${STUB_IMAGE:--}"; exit 0
fi
shift
[ -n "${STUB_NO_IMAGE:-}" ] || echo "IMAGE ${STUB_RUN_IMAGE:-${STUB_IMAGE:--}}"
f=0
for s in "$@"; do
  b=$(basename "$s"); rc=$(cat "$STUB_DIR/rc/$b" 2>/dev/null || echo 0)
  if [ -f "$STUB_DIR/blind/$b" ]; then echo "BLIND $s (printed no merge base, rc $rc)"
  elif [ "$rc" = 0 ]; then echo "PASS $s"; else echo "FAIL $s (rc $rc)"; fi
  echo "TIME 7 $s"
  { [ "$rc" != 0 ] || [ -f "$STUB_DIR/blind/$b" ]; } && f=$((f + 1))
done
for s in "$@"; do
  b=$(basename "$s"); rc=$(cat "$STUB_DIR/rc/$b" 2>/dev/null || echo 0)
  [ "$rc" != 0 ] || continue
  echo; echo "===== $s (rc $rc) ====="
  if [ "$b" = hn-test.sh ]; then echo "FAIL: H1 host clock"; echo "hn: 0 passed, 1 failed"; else echo "FAIL: it broke"; fi
done
echo; echo "remote-gate: $# suites, $f failing"
exit "$f"
SH
chmod +x "$T/plan.sh" "$T/runner.sh"

# sg <case> [VAR=value...] — one selection-gate run into $T/<case>/out, the
# runner's state in $T/<case>/stub; rc SRC. Knobs come from the arguments only.
sg() {
  local c="$1"; shift
  mkdir -p "$T/$c/stub/rc" "$T/$c/stub/blind" "$T/$c/tmp" "$T/$c/h"
  env -u CI_QUARANTINE -u SELECTION_GATE_SUITE_REUSE -u SELECTION_GATE_RERUN_RED -u SELECTION_GATE_IMAGE_PROBE_S \
    HARNESS="$T/$c/h" TMPDIR="$T/$c/tmp" STUB_DIR="$T/$c/stub" STUB_IMAGE="$IMG1" \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- MARK_DIR="$T/$c" "$@" \
    bash "$R/bin/selection-gate.sh" --tree "$R" --base main --out "$T/$c/out" > "$T/$c/stdout" 2>&1
  SRC=$?
}
pre() { mkdir -p "$T/$1/stub/rc" "$T/$1/stub/blind"; }   # pre <case> — make the stub dirs before setting rc files
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
sent() { grep -v -e '^--image-id' "$T/$1/stub/calls" 2>/dev/null | tr ' ' '\n' | grep -cxF "$2"; }
gdump() { cat "$T/$1/out/gate.txt" "$T/$1/stdout" "$T/$1/stub/calls" 2>/dev/null; }
ID1="fly:$IMG1+rg:${RG_BLOB:0:12}"

# ── S1 / S2 ─────────────────────────────────────────────────────────────────
export LEDGER_DB="$T/s1.db"
sg s1a SELECTION_GATE_SUITE_REUSE=1 SUITE_REUSE_RUN_KEY=s1-run1
{ [ "$SRC" = 0 ] && [ "$(sent s1a $S)" = 1 ]; } && ok "S1 run 1 sends S, rc 0" || bad "S1 run 1 rc=$SRC: $(gdump s1a)"
[ "$(q "SELECT status, duration_s, class, ctx FROM suite_results WHERE run_id='s1-run1' AND suite='$S'")" = '[{"status":"ok","duration_s":7,"class":"builder","ctx":"fly-testhost"}]' ] \
  && ok "S1 run 1 writes an ok row with the TIME duration" || bad "S1 rows: $(q 'SELECT suite, status, duration_s, run_id FROM suite_results') $(gdump s1a)"
sg s1b SELECTION_GATE_SUITE_REUSE=1 SUITE_REUSE_RUN_KEY=s1-run2
{ [ "$SRC" = 0 ] && [ "$(sent s1b $S)" = 0 ] && [ "$(sent s1b tests/always-test.sh)" = 1 ]; } \
  && ok "S1 run 2 on tree T, image I: S is not sent" || bad "S1 run 2 rc=$SRC: $(gdump s1b)"
[ "$(gv s1b reuse | sed 's/; recorded.*//')" = "ran 1 reused 1 green, 0 red of 2 (image $ID1)" ] \
  && ok "S1 gate.txt reuse: names the counts and the image" || bad "S1 reuse: '$(gv s1b reuse)' want image $ID1"
[ "$( . "$DIR/bin/lib/selection-gate.sh" && _sg_field "$T/s1b/out/gate.txt" reuse | cut -c1-30)" = "ran 1 reused 1 green, 0 red of" ] \
  && ok "S1 _sg_field reads the reuse: field" || bad "S1 _sg_field: '$( . "$DIR/bin/lib/selection-gate.sh" && _sg_field "$T/s1b/out/gate.txt" reuse)'"
[ "$(gv s1b suites)" = 2 ] && ok "S1 suites: is still the whole selection" || bad "S1 suites: $(gv s1b suites)"
sg s2 SELECTION_GATE_SUITE_REUSE=1 STUB_IMAGE=registry.fly.io/bh-testhost-fixture:testhost-2 SUITE_REUSE_RUN_KEY=s2
{ [ "$SRC" = 0 ] && [ "$(sent s2 $S)" = 1 ]; } && ok "S2 the host's image testhost-2: S is sent" || bad "S2: $(gdump s2)"

# ── S3 / S4: a red row ──────────────────────────────────────────────────────
export LEDGER_DB="$T/s3.db"
pre s3a; echo 1 > "$T/s3a/stub/rc/target-test.sh"
sg s3a SELECTION_GATE_SUITE_REUSE=1 SUITE_REUSE_RUN_KEY=s3-red
[ "$(q "SELECT status FROM suite_results WHERE suite='$S'")" = '[{"status":"fail"}]' ] && ok "S3 a red run writes a fail row" \
  || bad "S3 seed: $(q 'SELECT * FROM suite_results') $(gdump s3a)"
sg s3 SELECTION_GATE_SUITE_REUSE=1 SELECTION_GATE_RERUN_RED=0 SUITE_REUSE_RUN_KEY=s3-b
{ [ "$SRC" = 1 ] && [ "$(gv s3 rc)" = 1 ] && [ "$(gv s3 red)" = "$S" ] && [ "$(sent s3 $S)" = 0 ]; } \
  && ok "S3 knob 0: S is not sent, red: S, rc 1" || bad "S3 rc=$SRC: $(gdump s3)"
grep -qF ', 1 red of 2' <<<"$(gv s3 reuse)" && ok "S3 reuse: counts the red" || bad "S3 reuse: $(gv s3 reuse)"
sg s3b SELECTION_GATE_SUITE_REUSE=1 SELECTION_GATE_RERUN_RED=0 CI_QUARANTINE="$S" SUITE_REUSE_RUN_KEY=s3-c
{ [ "$SRC" = 0 ] && [ "$(gv s3b noted)" = "$S" ] && [ "$(gv s3b red)" = - ]; } && ok "S3b a quarantined ledger red is noted, rc 0" \
  || bad "S3b rc=$SRC: $(gdump s3b)"
pre s3x; echo 1 > "$T/s3x/stub/rc/always-test.sh"
sg s3x SELECTION_GATE_SUITE_REUSE=1 SELECTION_GATE_RERUN_RED=0 SUITE_REUSE_RUN_KEY=s3-x
{ [ "$SRC" = 1 ] && [ "$(gv s3x red)" = "tests/always-test.sh,$S" ]; } && ok "S3 a ledger red and a run red: both in red:" \
  || bad "S3x: $(gdump s3x)"
STUB_SUITES="$S" sg s3o SELECTION_GATE_SUITE_REUSE=1 SELECTION_GATE_RERUN_RED=0 SUITE_REUSE_RUN_KEY=s3-o
{ [ "$SRC" = 1 ] && [ "$(gv s3o red)" = "$S" ] && [ "$(grep -vc '^--image-id' "$T/s3o/stub/calls")" = 0 ]; } \
  && ok "S3 the only suite red in the ledger: the runner is not called, rc 1" || bad "S3o rc=$SRC: $(gdump s3o)"
grep -qF 'record skipped (nothing ran)' <<<"$(gv s3o reuse)" && ok "S3o reuse: says record skipped (nothing ran)" || bad "S3o reuse: $(gv s3o reuse)"
sg s4 SELECTION_GATE_SUITE_REUSE=1 SELECTION_GATE_RERUN_RED=1 SUITE_REUSE_RUN_KEY=s4
{ [ "$SRC" = 0 ] && [ "$(sent s4 $S)" = 1 ] && [ "$(gv s4 red)" = - ]; } && ok "S4 knob 1: S is sent; a PASS is rc 0" || bad "S4: $(gdump s4)"
sg s4u SELECTION_GATE_SUITE_REUSE=1 SUITE_REUSE_RUN_KEY=s4u
{ [ "$SRC" = 0 ] && [ "$(sent s4u $S)" = 1 ]; } && ok "S4 knob unset (fallback 1): S is sent" || bad "S4u: $(gdump s4u)"

# ── S5: what is written ─────────────────────────────────────────────────────
export LEDGER_DB="$T/s5.db"
pre s5
echo 1 > "$T/s5/stub/rc/f1-test.sh"; echo 127 > "$T/s5/stub/rc/f127-test.sh"; : > "$T/s5/stub/blind/bl-test.sh"
echo 1 > "$T/s5/stub/rc/hn-test.sh"; echo 1 > "$T/s5/stub/rc/qr-test.sh"
STUB_SUITES="tests/p-test.sh tests/f1-test.sh tests/f127-test.sh tests/bl-test.sh tests/hn-test.sh tests/qr-test.sh" \
  sg s5 SELECTION_GATE_SUITE_REUSE=1 CI_QUARANTINE=tests/qr-test.sh SUITE_REUSE_RUN_KEY=s5
[ "$(gv s5 host-noted)" = "tests/hn-test.sh=host-timing" ] && ok "S5 the fixture host note matches" || bad "S5 host-noted: $(gdump s5)"
[ "$(q "SELECT suite, status FROM suite_results WHERE run_id='s5' ORDER BY suite")" = '[{"suite":"tests/f1-test.sh","status":"fail"},{"suite":"tests/p-test.sh","status":"ok"},{"suite":"tests/qr-test.sh","status":"fail"}]' ] \
  && ok "S5 PASS ok, FAIL fail, quarantined fail; no row for rc 127, BLIND or a host-noted red" \
  || bad "S5 rows: $(q "SELECT suite, status FROM suite_results WHERE run_id='s5'") $(gdump s5)"
grep -qF '; recorded 3 result(s)' <<<"$(gv s5 reuse)" && ok "S5 reuse: says recorded 3" || bad "S5 reuse: $(gv s5 reuse)"

# ── S6: the run's image moved ───────────────────────────────────────────────
export LEDGER_DB="$T/s6.db"
pre s6; echo 1 > "$T/s6/stub/rc/target-test.sh"
sg s6 SELECTION_GATE_SUITE_REUSE=1 STUB_RUN_IMAGE=registry.fly.io/bh-testhost-fixture:testhost-9 SUITE_REUSE_RUN_KEY=s6
{ [ "$SRC" = 1 ] && [ "$(gv s6 red)" = "$S" ] && [ "$(q "SELECT count(*) AS n FROM suite_results")" = '[{"n":0}]' ]; } \
  && ok "S6 another image ran it: verdict red as before, no row" || bad "S6 rc=$SRC rows=$(q 'SELECT * FROM suite_results'): $(gdump s6)"
grep -qF 'record skipped (image moved)' <<<"$(gv s6 reuse)" && ok "S6 reuse: says record skipped (image moved)" || bad "S6 reuse: $(gv s6 reuse)"
sg s6b SELECTION_GATE_SUITE_REUSE=1 STUB_NO_IMAGE=1 SUITE_REUSE_RUN_KEY=s6b
{ [ "$SRC" = 0 ] && [ "$(q "SELECT count(*) AS n FROM suite_results")" = '[{"n":0}]' ] && grep -qF 'record skipped (image moved)' <<<"$(gv s6b reuse)"; } \
  && ok "S6 a run with no IMAGE line: no row" || bad "S6b: $(gdump s6b)"

# ── S7: no image, no reuse ──────────────────────────────────────────────────
export LEDGER_DB="$T/s7.db"
pre s7k; echo 1 > "$T/s7k/stub/rc/target-test.sh"; sg s7k; K0RC=$SRC
LONGREF=registry.fly.io/$(printf 'x%.0s' $(seq 100))
for c in "s7a STUB_PROBE_RC=125|image probe rc 125" "s7b STUB_IMAGE=-|the test host has no image ref" "s7c STUB_IMAGE=$LONGREF|image id too long"; do
  tag=${c%% *}; rest=${c#* }; var=${rest%%|*}; why=${rest#*|}
  pre "$tag"; echo 1 > "$T/$tag/stub/rc/target-test.sh"
  sg "$tag" SELECTION_GATE_SUITE_REUSE=1 "$var" SUITE_REUSE_RUN_KEY="$tag"
  { [ "$(gv "$tag" reuse)" = "off ($why)" ] && [ "$(sent "$tag" $S)" = 1 ] && [ "$SRC" = "$K0RC" ] \
    && [ "$(gv "$tag" red)" = "$(gv s7k red)" ]; } && ok "S7 $why: reuse off, everything sent, the knob-0 verdict" \
    || bad "S7 $tag rc=$SRC vs $K0RC reuse='$(gv "$tag" reuse)': $(gdump "$tag")"
done
[ "$(q "SELECT count(*) AS n FROM suite_results")" = '[{"n":0}]' ] && ok "S7 with no image id nothing is written" || bad "S7 rows: $(q 'SELECT * FROM suite_results')"

# ── S8: wrong tenant ────────────────────────────────────────────────────────
export LEDGER_DB="$T/s8.db"
sg s8a SELECTION_GATE_SUITE_REUSE=1 SUITE_REUSE_REPO=acme/other SUITE_REUSE_RUN_KEY=s8-other
[ "$(q "SELECT repo, status FROM suite_results WHERE suite='$S'")" = '[{"repo":"acme/other","status":"ok"}]' ] && ok "S8 a green for S in acme/other" \
  || bad "S8 seed: $(q 'SELECT repo, suite, status FROM suite_results')"
sg s8 SELECTION_GATE_SUITE_REUSE=1 SUITE_REUSE_RUN_KEY=s8
[ "$(sent s8 $S)" = 1 ] && ok "S8 acme/widget does not reuse acme/other's green" || bad "S8: $(gdump s8)"

# ── S9: knob unset, the registry, no network ────────────────────────────────
sg s9
{ [ "$(wc -l < "$T/s9/out/gate.txt" | tr -d ' ')" = 10 ] && ! grep -q '^reuse:' "$T/s9/out/gate.txt" \
  && [ "$(grep -c . "$T/s9/stub/calls")" = 1 ] && ! grep -q -- '--image-id' "$T/s9/stub/calls"; } \
  && ok "S9 knob unset: the 10-line gate.txt, one runner call, no probe" || bad "S9: $(gdump s9)"
kd() { jq -r '.default' "$DIR/catalog/lanes.d/fly-pool.knobs.d/$1.json" 2>/dev/null; }
[ "$(kd SELECTION_GATE_SUITE_REUSE)" = 1 ] && grep -qE '_sg_knob SELECTION_GATE_SUITE_REUSE 1\)' "$DIR/bin/lib/selection-gate.sh" \
  && ok "S9 SELECTION_GATE_SUITE_REUSE: registry 1 = the lib's fallback" || bad "S9 SUITE_REUSE default '$(kd SELECTION_GATE_SUITE_REUSE)'"
[ "$(kd SELECTION_GATE_RERUN_RED)" = 1 ] && grep -qE '_sg_knob SELECTION_GATE_RERUN_RED 1\)' "$DIR/bin/lib/selection-gate.sh" \
  && grep -qE 'SELECTION_GATE_RERUN_RED:-1\}' "$DIR/bin/lib/selection-gate-reuse.sh" \
  && ok "S9 SELECTION_GATE_RERUN_RED: registry 1 = both fallbacks" || bad "S9 RERUN_RED default '$(kd SELECTION_GATE_RERUN_RED)'"
[ "$(kd SELECTION_GATE_IMAGE_PROBE_S)" = 60 ] && grep -qE '_sg_knob SELECTION_GATE_IMAGE_PROBE_S 60\)' "$DIR/bin/lib/selection-gate.sh" \
  && grep -qE 'SELECTION_GATE_IMAGE_PROBE_S:-60\}' "$DIR/bin/lib/selection-gate-reuse.sh" \
  && ok "S9 SELECTION_GATE_IMAGE_PROBE_S: registry 60 = both fallbacks" || bad "S9 PROBE_S default '$(kd SELECTION_GATE_IMAGE_PROBE_S)'"
[ "$(kd TEST_IMPACT_GATE_RERUN_RED)" = 1 ] && grep -qE 'gate_knob TEST_IMPACT_GATE_RERUN_RED 1\)' "$DIR/bin/test-impact-gate.sh" \
  && ok "S9 TEST_IMPACT_GATE_RERUN_RED: registry 1 = the gate's fallback" || bad "S9 TIG RERUN_RED default '$(kd TEST_IMPACT_GATE_RERUN_RED)'"
[ ! -s "$T/net-calls" ] && ok "S9 no network tool was called by either gate" || bad "S9 network calls: $(cat "$T/net-calls")"

# ── S10: the other reasons reuse is off ─────────────────────────────────────
export LEDGER_DB="$T/s10.db"
# A tree with no reuse lib: off (no reuse lib), everything sent, verdict as knob 0.
cp -a "$R" "$T/rnolib" || bad "S10 cannot copy the scratch repo"
NOLIB="$T/rnolib/bin/lib/selection-gate-reuse.sh"; rm "$NOLIB"
mkdir -p "$T/s10a/stub/rc" "$T/s10a/stub/blind" "$T/s10a/tmp" "$T/s10a/h"
env -u CI_QUARANTINE HARNESS="$T/s10a/h" TMPDIR="$T/s10a/tmp" STUB_DIR="$T/s10a/stub" STUB_IMAGE="$IMG1" \
  SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- SELECTION_GATE_SUITE_REUSE=1 \
  bash "$T/rnolib/bin/selection-gate.sh" --tree "$R" --base main --out "$T/s10a/out" > "$T/s10a/stdout" 2>&1; SRC=$?
{ [ "$SRC" = 0 ] && [ "$(gv s10a reuse)" = "off (no reuse lib)" ] && [ "$(sent s10a $S)" = 1 ] && ! grep -q -- '--image-id' "$T/s10a/stub/calls"; } \
  && ok "S10 no reuse lib: off (no reuse lib), no probe, everything sent" || bad "S10a rc=$SRC: $(gdump s10a)"
# A helper whose reds and run overlap: off, everything sent, nothing recorded.
cp -a "$R" "$T/rbad"
cat > "$T/rbad/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
[ "$1" = plan ] || { echo "suite-reuse: recorded 9 result(s) for X (ran 9, reused 0)"; exit 0; }
while [ $# -gt 0 ]; do case "$1" in --suites) in=$2 ;; --run) run=$2 ;; --reused) re=$2 ;; --reds) rd=$2 ;; --fingerprints) fp=$2 ;; esac; shift; done
cp "$in" "$run"; : > "$re"; printf 'tests/target-test.sh\tX1\tbuilder\n' > "$rd"; printf 'tests/target-test.sh\t%064d\t-\n' 0 > "$fp"
SH
G "$T/rbad" commit -qam "a helper that answers badly" || bad "S10 cannot commit the bad helper"
mkdir -p "$T/s10b/stub/rc" "$T/s10b/stub/blind" "$T/s10b/tmp" "$T/s10b/h"
env -u CI_QUARANTINE HARNESS="$T/s10b/h" TMPDIR="$T/s10b/tmp" STUB_DIR="$T/s10b/stub" STUB_IMAGE="$IMG1" \
  SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- SELECTION_GATE_SUITE_REUSE=1 \
  bash "$T/rbad/bin/selection-gate.sh" --tree "$T/rbad" --base main --out "$T/s10b/out" > "$T/s10b/stdout" 2>&1; SRC=$?
{ [ "$SRC" = 0 ] && [ "$(gv s10b reuse)" = "off (helper answer did not match its input)" ] && [ "$(sent s10b $S)" = 1 ]; } \
  && ok "S10 an incoherent helper answer: off, everything sent, no record claimed" || bad "S10b rc=$SRC: $(gdump s10b)"
# The ledger down: the helper's own why, everything sent, the record says failed.
STUB_MODE=exit7 sg s10c SELECTION_GATE_SUITE_REUSE=1 SUITE_REUSE_RUN_KEY=s10c
{ [ "$SRC" = 0 ] && [ "$(sent s10c $S)" = 1 ] && [ "$(gv s10c reuse)" = "off (ledger unreachable); record failed" ]; } \
  && ok "S10 ledger down: off (ledger unreachable), everything sent, record failed" || bad "S10c rc=$SRC: $(gdump s10c)"

echo "suite-ledger-gates: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
