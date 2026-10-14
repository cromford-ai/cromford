#!/bin/bash
# tests/suite-reuse.bh-5366-test.sh — bin/suite-reuse.sh plan|record against the
# real suite-ledger worker routes (BH-5354.0 / BH-5366).
#
# SUITE_REUSE_CURL points at a stub that hands each request to worker.fetch
# (worker/jobs/src/index.js) over a file-backed node:sqlite database with
# schema.sql applied, so plan and record talk to the SQL the worker ships. The
# checkout is a committed scratch repo with the real bin/test-impact.sh,
# bin/fast-lints.sh and the helper's closure installed.
#
#   R1  record a ok 7s, b ok 3s; plan over a, b and the always-suite c reuses
#       a and b (`reused tests/a.sh from <K> (7s)`, `ran 1 reused 2 of 3
#       (saved ~10s)`), --run is c only, --reused is 2 rows of 4 fields
#   R2  a committed edit to a's input: a runs again, b is still reused
#   R3  from a gate log: rc 1 -> fail, rc 0 with a HIT -> fail, a TIMEOUT line
#       -> fail (each prints MISS over its earlier green); no TRACE: line, or
#       one that does not close the log (TRACE:, or TRACE: then GATE:) ->
#       nothing written; a path with two `---` lines -> fail
#   R4  stub exits 7 / answers 500 / answers non-JSON, no credential, no URL,
#       a --class the credential does not carry, a dirty tree: rc 0, --run is
#       the input, exactly one `suite-reuse: off (` line naming why
#   R5  a record write failure: rc 0, one stderr `record failed` line; a MISS
#       under GITHUB_ACTIONS=true is a ::warning::
#   R6  SUITE_REUSE=off and a server settings row off: everything runs
#   R7  the worker's own node suites for the ledger, run for real
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
NOW=2026-10-08T00:00:00Z

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

SR="$DIR/bin/suite-reuse.sh"
SFP="$DIR/bin/lib/suite-fingerprint.sh"
LIB_JS="$DIR/worker/jobs/src/lib/suite-results.js"
ROUTES_JS="$DIR/worker/jobs/src/routes/suite-results.js"
for f in "$SR" "$SFP" "$LIB_JS" "$ROUTES_JS"; do [ -f "$f" ] && ok "present: ${f#"$DIR"/}" || bad "missing $f"; done

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "suite-reuse: SKIPPED — needs node with node:sqlite, and jq"
  echo "suite-reuse: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write > /dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json the worker imports"
fi

# ── the scratch checkout ────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/suite-reuse.sh bin/test-impact.sh bin/fast-lints.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/bin/lib" "$R/catalog"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
printf '#!/bin/bash\nlib_a() { echo a1; }\n' > "$R/bin/lib/a.sh"
printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n. "$DIR/bin/lib/a.sh"\n' > "$R/tests/a.sh"
printf '#!/bin/bash\necho b\n' > "$R/tests/b.sh"
printf '#!/bin/bash\necho c\n' > "$R/tests/c.sh"
printf 'tests/c.sh\n' > "$R/catalog/test-impact-always.txt"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm init || { echo "cannot build the scratch checkout"; exit 1; }
printf '%s\n' tests/a.sh tests/b.sh tests/c.sh > "$T/in"

# ── the stub: worker.fetch over a file-backed node:sqlite D1 ───────────────
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
  http500) printf '{"error":"boom"}\n500\n'; exit 0 ;;
  notjson) printf 'not json\n200\n'; exit 0 ;;
  wrongfp) printf '{"reuse":"on","max_age_h":72,"hits":[{"suite":"tests/b.sh","fingerprint":"%s","run_id":"X9","duration_s":1,"class":"builder"}]}\n200\n' "\$(printf '0%.0s' \$(seq 64))"; exit 0 ;;
esac
exec node "$T/driver.mjs" "$DIR" "$T/ledger.db" "\$@"
EOF
chmod +x "$T/stub.sh"
sql() { node "$T/driver.mjs" "$DIR" "$T/ledger.db" SQL "$1" > /dev/null; }
q() { node "$T/driver.mjs" "$DIR" "$T/ledger.db" Q "$1"; }

export SUITE_REUSE_CURL="$T/stub.sh" JOBS_URL=https://jobs.invalid HARNESS_SECRET=x
unset SUITE_LEDGER_URL SUITE_LEDGER_TOKEN SUITE_REUSE GITHUB_ACTIONS STUB_MODE

# plan <tag> [ctx] [class] — outputs in $T/<tag>.{run,reused,fp,out,err}, rc in PRC
plan() {
  ( cd "$R" && "$SR" plan --class "${3:-builder}" --repo scratch/repo --ctx "${2:-isolated}" --suites "$T/in" \
      --run "$T/$1.run" --reused "$T/$1.reused" --fingerprints "$T/$1.fp" ) > "$T/$1.out" 2> "$T/$1.err"
  PRC=$?
}
record() { # record <tag> <ctx> <key> <fp> <args...>
  local tag="$1" ctx="$2" key="$3" fpf="$4"; shift 4
  ( cd "$R" && "$SR" record --repo scratch/repo --ctx "$ctx" --run-key "$key" --fingerprints "$fpf" "$@" ) \
    > "$T/$tag.out" 2> "$T/$tag.err"
  RRC=$?
}
offs() { grep -c '^suite-reuse: off (' "$T/$1.out"; }

# ── R1 ──────────────────────────────────────────────────────────────────────
plan p0
{ [ "$PRC" = 0 ] && cmp -s "$T/p0.run" "$T/in" && [ ! -s "$T/p0.reused" ]; } && ok "R1 cold ledger: everything runs" \
  || bad "R1 cold plan rc=$PRC out=$(cat "$T/p0.out" "$T/p0.err")"
[ "$(awk -F'\t' '$2 ~ /^[0-9a-f]{64}$/' "$T/p0.fp" | wc -l | tr -d ' ')" = 2 ] && ok "R1 a and b are fingerprinted" \
  || bad "R1 fingerprints: $(cat "$T/p0.fp")"
printf 'tests/a.sh\tok\t7\ntests/b.sh\tok\t3\ntests/c.sh\tok\t1\n' > "$T/res1"
record r1 isolated K1 "$T/p0.fp" --results "$T/res1"
{ [ "$RRC" = 0 ] && [ ! -s "$T/r1.err" ]; } && ok "R1 record rc 0" || bad "R1 record rc=$RRC err=$(cat "$T/r1.err")"
plan p1
grep -qxF 'suite-reuse: reused tests/a.sh from K1 (7s)' "$T/p1.out" && ok "R1 reused a line" || bad "R1 out: $(cat "$T/p1.out" "$T/p1.err")"
grep -qxF 'suite-reuse: reused tests/b.sh from K1 (3s)' "$T/p1.out" && ok "R1 reused b line" || bad "R1 no b line"
grep -qxF 'suite-reuse: ran 1 reused 2 of 3 (saved ~10s)' "$T/p1.out" && ok "R1 summary line" || bad "R1 no summary line"
[ "$(cat "$T/p1.run")" = tests/c.sh ] && ok "R1 --run holds only the always-suite" || bad "R1 --run: $(cat "$T/p1.run")"
[ "$(awk -F'\t' 'NF == 4' "$T/p1.reused" | wc -l | tr -d ' ')" = 2 ] && ok "R1 --reused is 2 rows of 4 fields" \
  || bad "R1 --reused: $(cat "$T/p1.reused")"
grep -q $'^tests/a.sh\tK1\t7\tbuilder$' "$T/p1.reused" && ok "R1 --reused row shape" || bad "R1 --reused a row"
[ "$PRC" = 0 ] && ok "R1 plan rc 0" || bad "R1 plan rc=$PRC"
[ "$(q "SELECT ran, reused, total, saved_s, class FROM suite_reuse_runs WHERE run_key='K1'")" = '[{"ran":3,"reused":0,"total":3,"saved_s":0,"class":"builder"}]' ] \
  && ok "R1 record wrote its run row" || bad "R1 run row: $(q "SELECT * FROM suite_reuse_runs")"
[ "$(q "SELECT count(*) AS n FROM suite_results WHERE run_id='K1'")" = '[{"n":2}]' ] && ok "R1 only the two fingerprinted suites were written" \
  || bad "R1 rows: $(q "SELECT suite FROM suite_results")"

# ── R2 ──────────────────────────────────────────────────────────────────────
printf '#!/bin/bash\nlib_a() { echo a2; }\n' > "$R/bin/lib/a.sh"; G commit -qam r2
plan p2
[ "$(cat "$T/p2.run")" = "$(printf 'tests/a.sh\ntests/c.sh')" ] && ok "R2 the edited input reruns a" || bad "R2 --run: $(cat "$T/p2.run")"
grep -q $'^tests/b.sh\tK1\t' "$T/p2.reused" && ok "R2 b is still reused" || bad "R2 --reused: $(cat "$T/p2.reused")"

STUB_MODE=wrongfp plan p2w
{ [ ! -s "$T/p2w.reused" ] && cmp -s "$T/p2w.run" "$T/in"; } && ok "R2 a hit whose fingerprint is not ours is not reused" \
  || bad "R2 wrong-fp hit reused: $(cat "$T/p2w.reused")"

# ── R3 ──────────────────────────────────────────────────────────────────────
plan p3 r3
printf 'tests/a.sh\tok\t2\ntests/b.sh\tok\t2\n' > "$T/res3"
record r3a r3 G1 "$T/p3.fp" --results "$T/res3"
cat > "$T/gate1.log" <<'EOF'
--- tests/a.sh rc=1 2s
--- tests/b.sh rc=0 3s
HIT b.sh write /root/harness/state/x (tests/b.sh:2, cwd /x)  echo > /root/harness/state/x
EXIT 1 a.sh
TRACE: 2 tests, 1 nonzero exit(s), 1 hit(s)
EOF
record r3b r3 G2 "$T/p3.fp" --from-gate-log "$T/gate1.log"
grep -qxF 'suite-reuse: MISS tests/a.sh was ok in G1, failed in G2' "$T/r3b.out" && ok "R3 rc 1 -> fail (MISS)" || bad "R3 out: $(cat "$T/r3b.out" "$T/r3b.err")"
grep -qxF 'suite-reuse: MISS tests/b.sh was ok in G1, failed in G2' "$T/r3b.out" && ok "R3 rc 0 with a HIT -> fail (MISS)" || bad "R3 no b MISS"
plan p3b r3
[ ! -s "$T/p3b.reused" ] && cmp -s "$T/p3b.run" "$T/in" && ok "R3 nothing red is reused" || bad "R3 reused: $(cat "$T/p3b.reused")"
plan p3t r3t
record r3t1 r3t T1 "$T/p3t.fp" --results "$T/res3"
printf -- '--- tests/a.sh rc=0 5s\nTIMEOUT a.sh (killed after 5s)\n--- tests/b.sh rc=0 2s\nTRACE: 2 tests, 0 nonzero exit(s), 0 hit(s)\n' > "$T/gate2.log"
record r3t2 r3t T2 "$T/p3t.fp" --from-gate-log "$T/gate2.log"
grep -qxF 'suite-reuse: MISS tests/a.sh was ok in T1, failed in T2' "$T/r3t2.out" && ok "R3 TIMEOUT -> fail" || bad "R3 timeout out: $(cat "$T/r3t2.out" "$T/r3t2.err")"
plan p3t2 r3t
[ "$(cut -f1 "$T/p3t2.reused")" = tests/b.sh ] && ok "R3 the clean suite of that log is still reused" || bad "R3 r3t reused: $(cat "$T/p3t2.reused")"
plan p3n r3n
printf -- '--- tests/a.sh rc=0 2s\n--- tests/b.sh rc=0 2s\n' > "$T/gate3.log"
: > "$T/calls"
record r3n r3n N1 "$T/p3n.fp" --from-gate-log "$T/gate3.log"
{ [ "$RRC" = 0 ] && grep -qxF 'suite-reuse: record skipped (no TRACE: summary)' "$T/r3n.out" && [ ! -s "$T/calls" ]; } \
  && ok "R3 no TRACE: line -> nothing sent" || bad "R3 no-trace rc=$RRC out=$(cat "$T/r3n.out") calls=$(cat "$T/calls")"
plan p3n2 r3n
[ ! -s "$T/p3n2.reused" ] && ok "R3 ... and nothing is reused after it" || bad "R3 no-trace reused: $(cat "$T/p3n2.reused")"
# A TRACE: line that is not the log's closing summary came out of a dumped
# nested log: the outer scan did not finish, so nothing is sent.
printf -- '--- tests/a.sh rc=0 2s\n--- tests/b.sh rc=1 2s\nTRACE: 1 tests, 0 nonzero exit(s), 0 hit(s)\ntest-trace-safety: died\n' > "$T/gate4.log"
: > "$T/calls"
record r3d r3n N2 "$T/p3n.fp" --from-gate-log "$T/gate4.log"
{ [ "$RRC" = 0 ] && grep -qxF 'suite-reuse: record skipped (no TRACE: summary)' "$T/r3d.out" && [ ! -s "$T/calls" ]; } \
  && ok "R3 a TRACE: line that does not close the log -> nothing sent" || bad "R3 nested-trace rc=$RRC out=$(cat "$T/r3d.out") calls=$(cat "$T/calls")"
printf -- '--- tests/a.sh rc=0 2s\n--- tests/b.sh rc=0 2s\nTRACE: 2 tests, 0 nonzero exit(s), 0 hit(s)\nGATE: pure-logic pass (0 of 2 failed), trace clean (0 hit(s))\n' > "$T/gate5.log"
record r3g r3n N3 "$T/p3n.fp" --from-gate-log "$T/gate5.log"
plan p3g r3n
[ "$(cut -f1 "$T/p3g.reused" | sort | tr '\n' ' ')" = "tests/a.sh tests/b.sh " ] && ok "R3 TRACE: then GATE: closes the log" \
  || bad "R3 gate-closed reused: $(cat "$T/p3g.reused" "$T/r3g.out" "$T/r3g.err")"
# A path with two `---` lines (one from a dumped nested log) is fail, whichever comes first.
plan p3x r3x
record r3x1 r3x X1 "$T/p3x.fp" --results "$T/res3"
printf -- '--- tests/a.sh rc=0 2s\n--- tests/b.sh rc=1 2s\n--- tests/a.sh rc=0 2s\n--- tests/b.sh rc=0 2s\nTRACE: 2 tests, 1 nonzero exit(s), 0 hit(s)\n' > "$T/gate6.log"
record r3x2 r3x X2 "$T/p3x.fp" --from-gate-log "$T/gate6.log"
{ grep -qxF 'suite-reuse: MISS tests/a.sh was ok in X1, failed in X2' "$T/r3x2.out" \
  && grep -qxF 'suite-reuse: MISS tests/b.sh was ok in X1, failed in X2' "$T/r3x2.out"; } \
  && ok "R3 a duplicated --- line is fail" || bad "R3 dup out: $(cat "$T/r3x2.out" "$T/r3x2.err")"

# ── R4 ──────────────────────────────────────────────────────────────────────
r4() { # r4 <label> <want-why> — the plan p4 just ran
  if [ "$PRC" = 0 ] && cmp -s "$T/p4.run" "$T/in" && [ ! -s "$T/p4.reused" ] && [ "$(offs p4)" = 1 ] \
     && grep -qF "suite-reuse: off ($2" "$T/p4.out"; then ok "$1"
  else bad "$1: rc=$PRC run=$(tr '\n' ' ' < "$T/p4.run") out=$(cat "$T/p4.out")"; fi
}
STUB_MODE=exit7 plan p4; r4 "R4 curl failure" "ledger unreachable)"
STUB_MODE=http500 plan p4; r4 "R4 http 500" "ledger http 500)"
STUB_MODE=notjson plan p4; r4 "R4 non-JSON answer" "bad ledger answer)"
HARNESS_SECRET='' plan p4; r4 "R4 no credential" "no credential)"
JOBS_URL='' plan p4; r4 "R4 no URL" "no ledger url)"
plan p4 isolated ci; r4 "R4 class mismatch" "credential is builder, not ci)"
echo '# dirt' >> "$R/tests/b.sh"
plan p4; r4 "R4 dirty tree" "dirty tree)"
[ ! -s "$T/p4.fp" ] && ok "R4 a dirty tree leaves no fingerprints to record" || bad "R4 dirty fp: $(cat "$T/p4.fp")"
G checkout -q -- tests/b.sh

# ── R5 ──────────────────────────────────────────────────────────────────────
STUB_MODE=http500 record r5 isolated K5 "$T/p2.fp" --results "$T/res1"
{ [ "$RRC" = 0 ] && [ "$(grep -c 'record failed' "$T/r5.err")" = 1 ] && [ ! -s "$T/r5.out" ]; } \
  && ok "R5 write failure: rc 0, one stderr line" || bad "R5 rc=$RRC err=$(cat "$T/r5.err") out=$(cat "$T/r5.out")"
plan p5 r5
record r5a r5 W1 "$T/p5.fp" --results "$T/res3"
printf 'tests/a.sh\tfail\t2\n' > "$T/res5"
GITHUB_ACTIONS=true record r5b r5 W2 "$T/p5.fp" --results "$T/res5"
grep -qxF '::warning::suite-reuse: MISS tests/a.sh was ok in W1, failed in W2' "$T/r5b.out" && ok "R5 MISS is a ::warning:: under Actions" \
  || bad "R5 out: $(cat "$T/r5b.out" "$T/r5b.err")"

# ── R6 ──────────────────────────────────────────────────────────────────────
SUITE_REUSE=off plan p4; r4 "R6 SUITE_REUSE=off" "knob off)"
[ -s "$T/p4.fp" ] && ok "R6 knob off still leaves fingerprints for record" || bad "R6 no fingerprints under knob off"
SUITE_REUSE=maybe plan p4; r4 "R6 SUITE_REUSE=maybe" "bad SUITE_REUSE)"
sql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('lib.suite-reuse.suite_reuse','off','t','t','$NOW')"
plan p4; r4 "R6 server settings row off" "server knob off: settings row off)"
sql "DELETE FROM settings WHERE key='lib.suite-reuse.suite_reuse'"
plan p6
[ -s "$T/p6.reused" ] && ok "R6 the row removed: reuse is back" || bad "R6 after the row: $(cat "$T/p6.out")"

# ── R7 the worker suites ────────────────────────────────────────────────────
if OUT=$(cd "$DIR/worker/jobs" && node --test test/suite-results.bh-5366.test.js test/suite-results-schema.bh-5366.test.js test/route-table.test.js 2>&1); then
  ok "R7 worker node suites"
else bad "R7 worker node suites:"; printf '%s\n' "$OUT" | grep -E '^not ok|Error' | head -20; fi

echo "suite-reuse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
