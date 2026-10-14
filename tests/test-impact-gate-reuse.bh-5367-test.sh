#!/bin/bash
# tests/test-impact-gate-reuse.bh-5367-test.sh — the builder gate reuses suite
# ledger greens (BH-5354.1 / BH-5367): bin/test-impact-gate.sh asks
# bin/suite-reuse.sh plan --class builder which selected suites already passed
# at the same input fingerprint, does not re-run them, and records what it ran.
#
# The real gate, the real selector and the real helper in a committed scratch
# repo (origin https://github.com/acme/widget.git), with SUITE_REUSE_CURL
# pointed at the same worker.fetch-over-node:sqlite stub
# tests/suite-reuse.bh-5366-test.sh uses, so the ledger is the SQL the worker
# ships. tests/target-test.sh is the diff's own suite and counts its runs in
# $MARK_DIR; tests/always-test.sh is an always suite (never reused).
#
#   G1   run 1 runs both, records an ok builder row, says `reused 0 of N`; run 2
#        prints `impact-gate: reused tests/target-test.sh from <run_id> (<d>s)`,
#        no `done` line for it, does not execute it, still runs the always
#        suite, keeps the summary line's shape, adds `reused 1 of N ...`, tags
#        the --table row `(reused <run_id>)`, leaves its duration row alone
#   G1b  a helper whose answer does not match its input is treated as off:
#        `suite-reuse: off (helper answer did not match its input)`, all run
#   G2   ledger unreachable: every suite runs, one `suite-reuse: off (` line,
#        verdict and rc equal the helper-less run's, green and red
#   G3   no credential: `suite-reuse: off (no credential)`, the plan lines are
#        byte-identical to the helper-less run's, `reused 0 of N`
#   G4   record: the run key is SUITE_REUSE_RUN_KEY when set, builder-<host>-...
#        when not; a suite the budget never started is not recorded
#   G5   no helper in the checkout: no `suite-reuse:` and no `reused` output;
#        --runner plan with the helper present makes no ledger call
#   G6   bin/lib/rb/gates.sh exports SUITE_REUSE_RUN_KEY before the gate runs
#   G7   CLAUDE.md and the map entry say what to look for
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=2026-10-08T00:00:00Z
PASS=0 FAIL=0
TAB=$(printf '\t')
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 \
   || ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "test-impact-gate-reuse: SKIPPED — needs git, jq and node with node:sqlite"
  echo "test-impact-gate-reuse: $PASS passed, $FAIL failed"
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
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/suite-reuse.sh bin/fast-lints.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/catalog"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
cat > "$R/tests/target-test.sh" <<'SH'
#!/bin/bash
n=$(cat "$MARK_DIR/target" 2>/dev/null || echo 0); echo $((n + 1)) > "$MARK_DIR/target"
sleep "${TARGET_SLEEP:-0}"
echo "target: 1 passed, 0 failed"
exit "${TARGET_RC:-0}"
SH
cat > "$R/tests/always-test.sh" <<'SH'
#!/bin/bash
n=$(cat "$MARK_DIR/always" 2>/dev/null || echo 0); echo $((n + 1)) > "$MARK_DIR/always"
echo "always: 1 passed, 0 failed"
SH
printf 'tests/always-test.sh\n' > "$R/catalog/test-impact-always.txt"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/tests/target-test.sh"
G commit -qam "touch the target suite" || exit 1
G remote add origin https://github.com/acme/widget.git
# R0: the same commits with no helper, the shape of every checkout before this.
git clone -q "$R" "$T/r0" && rm "$T/r0/bin/suite-reuse.sh" || { echo "cannot build the helper-less copy"; exit 1; }
R0="$T/r0"

# ── the stub ledger: worker.fetch over a file-backed node:sqlite D1 ────────
cat > "$T/driver.mjs" <<'EOF'
import { readFileSync, existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const [, , dir, dbfile, method, path, bodyf, cls] = process.argv;
const fresh = !existsSync(dbfile);
const db = new DatabaseSync(dbfile);
if (fresh) db.exec(readFileSync(dir + '/worker/jobs/schema.sql', 'utf8'));
if (method === 'SQL') { db.exec(path); process.exit(0); }
if (method === 'Q') { console.log(JSON.stringify(db.prepare(path).all())); process.exit(0); }
const { d1 } = await import(dir + '/worker/jobs/test/lib/d1-sqlite.bh-1030.js');
const worker = (await import(dir + '/worker/jobs/src/index.js')).default;
const headers = { 'content-type': 'application/json',
  ...(cls === 'ci' ? { 'x-suite-ledger-token': 'tok' } : { authorization: 'Bearer SECRET' }) };
const res = await worker.fetch(new Request('https://jobs.test' + path, { method, headers, body: readFileSync(bodyf) }),
  { DB: d1(db), HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: 'tok' });
process.stdout.write((await res.text()) + '\n' + res.status + '\n');
EOF
cat > "$T/stub.sh" <<EOF
#!/bin/bash
echo "\$1 \$2" >> "$T/calls"
case "\${STUB_MODE:-}" in
  exit7) exit 7 ;;
esac
exec node "$T/driver.mjs" "$DIR" "\${LEDGER_DB:-$T/ledger.db}" "\$@" 2>/dev/null
EOF
chmod +x "$T/stub.sh"
q() { node "$T/driver.mjs" "$DIR" "${LEDGER_DB:-$T/ledger.db}" Q "$1" 2>/dev/null; }

export SUITE_REUSE_CURL="$T/stub.sh" JOBS_URL=https://jobs.invalid HARNESS_SECRET=x
export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
unset SUITE_LEDGER_URL SUITE_LEDGER_TOKEN SUITE_REUSE GITHUB_ACTIONS STUB_MODE SUITE_REUSE_RUN_KEY SUITE_REUSE_REPO
: > "$T/fast.empty"; : > "$T/calls"

# gate <tag> <repo> [args...] — stdout+stderr in $T/<tag>.out, table $T/<tag>.md,
# failed list $T/<tag>.failed, rc in GRC; markers counted in $T/mark-<tag>.
gate() {
  local tag="$1" repo="$2"; shift 2
  mkdir -p "$T/mark-$tag"
  ( cd "$repo" && MARK_DIR="$T/mark-$tag" bin/test-impact-gate.sh --base "$BASE" --runner local \
      --table "$T/$tag.md" --failed "$T/$tag.failed" "$@" ) > "$T/$tag.out" 2>&1
  GRC=$?
}
marks() { cat "$T/mark-$1/$2" 2>/dev/null || echo 0; }
SUMMARY_RE='^impact-gate: ran [0-9]+ of [0-9]+ selected suites via local: passed \(left to CI: [0-9]+ by the cap, [0-9]+ by the budget\)$'
verdict() { grep '^impact-gate: ran [0-9]* of [0-9]* selected suites via ' "$T/$1.out" | sed 's/^impact-gate: ran [0-9]* of /ran ? of /'; }

# ── G1: two runs on the unchanged tree ──────────────────────────────────────
export LEDGER_DB="$T/g1.db"
export SUITE_REUSE_RUN_KEY=g1-run1
gate g1a "$R"
[ "$GRC" = 0 ] && ok "G1 run 1 rc 0" || bad "G1 run 1 rc=$GRC: $(tail -5 "$T/g1a.out")"
[ "$(marks g1a target)" = 1 ] && [ "$(marks g1a always)" = 1 ] && ok "G1 run 1 runs both suites" \
  || bad "G1 run 1 markers target=$(marks g1a target) always=$(marks g1a always)"
[ "$(q "SELECT suite, status, class FROM suite_results WHERE run_id='g1-run1'")" = '[{"suite":"tests/target-test.sh","status":"ok","class":"builder"}]' ] \
  && ok "G1 run 1 recorded an ok builder row for the target suite" || bad "G1 ledger: $(q 'SELECT * FROM suite_results') out: $(cat "$T/g1a.out")"
grep -qE '^impact-gate: reused 0 of 2 selected suites from the suite ledger \(~0s not re-run\)$' "$T/g1a.out" \
  && ok "G1 run 1 says reused 0 of 2" || bad "G1 run 1 no reused-0 line: $(grep 'impact-gate: r' "$T/g1a.out")"

# A planted duration for the target: a run that reuses it must not touch it.
printf 'tests/always-test.sh\t0\ntests/target-test.sh\t77\n' > "$T/dur.tsv"
export SUITE_REUSE_RUN_KEY=g1-run2
gate g1b "$R"
[ "$GRC" = 0 ] && ok "G1 run 2 rc 0" || bad "G1 run 2 rc=$GRC: $(tail -5 "$T/g1b.out")"
grep -qxE 'impact-gate: reused tests/target-test.sh from g1-run1 \([0-9]+s\)' "$T/g1b.out" \
  && ok "G1 run 2 prints the reused line" || bad "G1 run 2 no reused line: $(cat "$T/g1b.out")"
grep -q '^impact-gate: done tests/target-test.sh' "$T/g1b.out" \
  && bad "G1 run 2 printed a done line for the reused suite" || ok "G1 run 2 prints no done line for it"
grep -q '^suite-reuse: reused ' "$T/g1b.out" && bad "G1 the helper's own reused lines must be dropped" || ok "G1 the helper's reused lines are not repeated"
[ "$(marks g1b target)" = 0 ] && ok "G1 run 2 did not execute the reused suite" || bad "G1 run 2 target marker $(marks g1b target)"
grep -qxF 'impact-gate: done tests/always-test.sh rc=0' "$T/g1b.out" && [ "$(marks g1b always)" = 1 ] \
  && ok "G1 run 2 still runs the always suite" || bad "G1 run 2 always: $(marks g1b always)"
SL=$(grep -nE "$SUMMARY_RE" "$T/g1b.out" | cut -d: -f1)
{ [ -n "$SL" ] && sed -n "${SL}p" "$T/g1b.out" | grep -q '^impact-gate: ran 1 of 2 selected suites via local: passed'; } \
  && ok "G1 the summary line keeps its shape and counts only what ran" || bad "G1 summary: $(grep 'impact-gate: ran' "$T/g1b.out")"
[ -n "$SL" ] && sed -n "$((SL + 1))p" "$T/g1b.out" | grep -qxE 'impact-gate: reused 1 of 2 selected suites from the suite ledger \(~[0-9]+s not re-run\)' \
  && ok "G1 the next line is the reused summary" || bad "G1 line after summary: $([ -n "$SL" ] && sed -n "$((SL + 1))p" "$T/g1b.out")"
grep -qF '| `tests/target-test.sh` | (reused g1-run1) ' "$T/g1b.md" && ok "G1 the --table row is tagged (reused <run_id>)" \
  || bad "G1 table: $(cat "$T/g1b.md")"
grep -qF 'Reused from the suite ledger (not re-run here): 1.' "$T/g1b.md" && ok "G1 the table header says how many were reused" \
  || bad "G1 table header: $(head -2 "$T/g1b.md")"
grep -qxF "tests/target-test.sh${TAB}77" "$T/dur.tsv" && ok "G1 the reused suite's duration row is untouched" \
  || bad "G1 durations: $(cat "$T/dur.tsv")"
[ ! -s "$T/g1b.failed" ] && ok "G1 --failed is empty" || bad "G1 --failed: $(cat "$T/g1b.failed")"
[ "$(q "SELECT ran, reused, total FROM suite_reuse_runs WHERE run_key='g1-run2'")" = '[{"ran":1,"reused":1,"total":2}]' ] \
  && ok "G1 run 2's run row counts 1 ran, 1 reused" || bad "G1 run row: $(q "SELECT * FROM suite_reuse_runs")"

# G1b: a helper that answers for a suite it was never asked about.
cp -a "$R" "$T/rb"
cat > "$T/rb/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
[ "$1" = plan ] || exit 0
while [ $# -gt 0 ]; do case "$1" in --suites) in=$2 ;; --run) run=$2 ;; --reused) re=$2 ;; --fingerprints) fp=$2 ;; esac; shift; done
cp "$in" "$run"; printf 'tests/ghost-test.sh\tX1\t9\tbuilder\n' > "$re"; printf 'tests/ghost-test.sh\tabc\t-\n' > "$fp"
SH
gate g1x "$T/rb"
{ grep -qxF 'suite-reuse: off (helper answer did not match its input)' "$T/g1x.out" \
  && [ "$(marks g1x target)" = 1 ] && [ "$(marks g1x always)" = 1 ] && [ "$GRC" = 0 ] \
  && ! grep -q '^impact-gate: reused tests/' "$T/g1x.out"; } \
  && ok "G1b an incoherent helper answer is off, everything runs" || bad "G1b rc=$GRC out: $(cat "$T/g1x.out")"
# ... and so is one that reuses a suite but leaves it in --run as well.
cat > "$T/rb/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
[ "$1" = plan ] || exit 0
while [ $# -gt 0 ]; do case "$1" in --suites) in=$2 ;; --run) run=$2 ;; --reused) re=$2 ;; esac; shift; done
cp "$in" "$run"; printf 'tests/target-test.sh\tX1\t9\tbuilder\n' > "$re"
SH
gate g1y "$T/rb"
{ grep -qxF 'suite-reuse: off (helper answer did not match its input)' "$T/g1y.out" && [ "$(marks g1y target)" = 1 ]; } \
  && ok "G1b a suite in both --run and --reused is off" || bad "G1b overlap out: $(cat "$T/g1y.out")"
# ... and a helper that crashes before writing anything.
printf '#!/bin/bash\nexit 3\n' > "$T/rb/bin/suite-reuse.sh"
gate g1z "$T/rb"
{ grep -qxF 'suite-reuse: off (helper answer did not match its input)' "$T/g1z.out" && [ "$(marks g1z target)" = 1 ] && [ "$GRC" = 0 ]; } \
  && ok "G1b a crashed helper is off, everything runs" || bad "G1b crash rc=$GRC out: $(cat "$T/g1z.out")"

# ── G2: the ledger does not answer ──────────────────────────────────────────
export LEDGER_DB="$T/g2.db" SUITE_REUSE_RUN_KEY=g2
STUB_MODE=exit7 gate g2 "$R"; G2RC=$GRC
gate g2n "$R0"; G2NRC=$GRC
{ [ "$(marks g2 target)" = 1 ] && [ "$(marks g2 always)" = 1 ]; } && ok "G2 every planned suite runs" \
  || bad "G2 markers target=$(marks g2 target) always=$(marks g2 always)"
[ "$(grep -c '^suite-reuse: off (' "$T/g2.out")" = 1 ] && grep -qxF 'suite-reuse: off (ledger unreachable)' "$T/g2.out" \
  && ok "G2 one suite-reuse: off line" || bad "G2 off lines: $(grep suite-reuse "$T/g2.out")"
{ [ "$G2RC" = "$G2NRC" ] && [ "$(verdict g2)" = "$(verdict g2n)" ]; } && ok "G2 verdict and rc equal the helper-less run's" \
  || bad "G2 rc $G2RC vs $G2NRC, '$(verdict g2)' vs '$(verdict g2n)'"
STUB_MODE=exit7 TARGET_RC=1 gate g2r "$R"; G2RC=$GRC
TARGET_RC=1 gate g2rn "$R0"; G2NRC=$GRC
{ [ "$G2RC" = 1 ] && [ "$G2NRC" = 1 ] && [ "$(verdict g2r)" = "$(verdict g2rn)" ] && grep -q 'FAILED (rc 1)' "$T/g2r.out"; } \
  && ok "G2 a red suite is FAILED (rc 1) with and without the helper" || bad "G2 red rc $G2RC vs $G2NRC, '$(verdict g2r)' vs '$(verdict g2rn)'"

# ── G3: no credential ───────────────────────────────────────────────────────
export LEDGER_DB="$T/g3.db"
HARNESS_SECRET='' gate g3 "$R"
gate g3n "$R0"
grep -qxF 'suite-reuse: off (no credential)' "$T/g3.out" && ok "G3 says off (no credential)" || bad "G3 out: $(cat "$T/g3.out")"
{ [ "$(grep -E '^(plan:|impact-gate: running up to)' "$T/g3.out")" = "$(grep -E '^(plan:|impact-gate: running up to)' "$T/g3n.out")" ] \
  && [ -n "$(grep '^plan:' "$T/g3.out")" ]; } && ok "G3 the plan lines are byte-identical to the helper-less run's" \
  || bad "G3 plan lines differ"
[ "$(verdict g3)" = "$(verdict g3n)" ] && ok "G3 same verdict" || bad "G3 '$(verdict g3)' vs '$(verdict g3n)'"
grep -qE '^impact-gate: reused 0 of 2 selected suites from the suite ledger' "$T/g3.out" && ok "G3 says reused 0 of 2" \
  || bad "G3 no reused-0 line"

# ── G4: what record sends ───────────────────────────────────────────────────
export LEDGER_DB="$T/g4.db" SUITE_REUSE_RUN_KEY=g4-key
gate g4 "$R"
[ "$(q "SELECT run_key, ran, reused FROM suite_reuse_runs")" = '[{"run_key":"g4-key","ran":2,"reused":0}]' ] \
  && ok "G4 the run row carries SUITE_REUSE_RUN_KEY and both suites that ran" || bad "G4 runs: $(q 'SELECT * FROM suite_reuse_runs')"
[ "$(q "SELECT suite, status, run_id FROM suite_results")" = '[{"suite":"tests/target-test.sh","status":"ok","run_id":"g4-key"}]' ] \
  && ok "G4 the fingerprinted suite is written with its status" || bad "G4 results: $(q 'SELECT * FROM suite_results')"
export LEDGER_DB="$T/g4r.db" SUITE_REUSE_RUN_KEY=g4-red
TARGET_RC=1 gate g4r "$R"
[ "$(q "SELECT status FROM suite_results WHERE run_id='g4-red'")" = '[{"status":"fail"}]' ] \
  && ok "G4 a red suite is recorded fail" || bad "G4 red: $(q 'SELECT * FROM suite_results')"
export LEDGER_DB="$T/g4u.db"; unset SUITE_REUSE_RUN_KEY
gate g4u "$R"
q "SELECT run_key FROM suite_reuse_runs" | grep -qE '^\[\{"run_key":"builder-[^"]+-[0-9]+-[0-9]+"\}\]$' \
  && ok "G4 with no SUITE_REUSE_RUN_KEY the key is builder-<host>-<epoch>-<pid>" || bad "G4 default key: $(q 'SELECT run_key FROM suite_reuse_runs')"
# The target sleeps past a 1 s budget, so the always suite is never started.
export LEDGER_DB="$T/g4b.db" SUITE_REUSE_RUN_KEY=g4-budget
TARGET_SLEEP=2 gate g4b "$R" --budget 1
{ grep -q 'not started, left to CI' "$T/g4b.out" \
  && [ "$(q "SELECT ran, reused FROM suite_reuse_runs WHERE run_key='g4-budget'")" = '[{"ran":1,"reused":0}]' ]; } \
  && ok "G4 a suite the budget never started is not recorded" || bad "G4 budget: $(q 'SELECT * FROM suite_reuse_runs') out: $(cat "$T/g4b.out")"

# ── G5: no helper, or a runner that runs nothing ───────────────────────────
export LEDGER_DB="$T/g5.db" SUITE_REUSE_RUN_KEY=g5
gate g5 "$R0"
{ ! grep -q 'suite-reuse:' "$T/g5.out" && ! grep -qi 'reused' "$T/g5.out" && ! grep -qi 'reused' "$T/g5.md" && [ "$GRC" = 0 ]; } \
  && ok "G5 a checkout with no helper prints and tags nothing new" || bad "G5 out: $(cat "$T/g5.out" "$T/g5.md")"
: > "$T/calls"
gate g5p "$R" --runner plan
{ [ ! -s "$T/calls" ] && ! grep -q 'suite-reuse:' "$T/g5p.out"; } && ok "G5 --runner plan never calls the ledger" \
  || bad "G5 plan calls: $(cat "$T/calls")"

# ── G6: the run key per gate invocation ─────────────────────────────────────
awk '/^HARNESS_IMPACT_GATE_RUN\(\) \{/ { f = 1 } f && /^}/ { exit }
     f && /^[[:space:]]*export SUITE_REUSE_RUN_KEY="\$\(basename "\$BUILD"\)-gate-\$phase-\$\(date \+%s\)"/ { k = NR }
     f && /timeout 1500 bin\/test-impact-gate\.sh/ { g = NR }
     END { exit !(k && g && k < g) }' "$DIR/bin/lib/rb/gates.sh" \
  && ok "G6 HARNESS_IMPACT_GATE_RUN exports SUITE_REUSE_RUN_KEY before the gate" || bad "G6 no export before the gate line"

# ── G7: docs ────────────────────────────────────────────────────────────────
SEC=$(awk '/^## Builder gate \(BH-1524\)/ { f = 1; next } f && /^## / { exit } f' "$DIR/CLAUDE.md")
{ grep -qF 'suite-reuse: off' <<< "$SEC" && grep -qF 'impact-gate: reused' <<< "$SEC"; } \
  && ok "G7 CLAUDE.md's builder gate section describes reuse" || bad "G7 CLAUDE.md section lacks reuse"
grep -qF 'tests/test-impact-gate-reuse.bh-5367-test.sh' "$DIR/docs/verification-map/entries/BH-5354.1.md" 2>/dev/null \
  && ok "G7 the map entry names this suite" || bad "G7 no map entry"

echo "test-impact-gate-reuse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
