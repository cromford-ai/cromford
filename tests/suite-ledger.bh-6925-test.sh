#!/bin/bash
# tests/suite-ledger.bh-6925-test.sh — one suite-result ledger across gates
# (BH-6925): the prequeue-shaped gate (bin/test-impact-gate.sh --runner traced,
# SUITE_REUSE_CLASS=ci) reads and writes the same ledger rows the merge-queue
# batch reads (bin/suite-reuse.sh plan --class ci, the call bin/ci-plan.sh
# makes), and the runner image id is part of the fingerprint.
#
# The real gate, selector, tracer and helper in a committed scratch repo, with
# SUITE_REUSE_CURL pointed at worker.fetch over a file-backed node:sqlite D1
# built from the composed schema (the BH-5367 pattern). The stub forwards the
# helper's own SUITE_LEDGER_TOKEN as the x-suite-ledger-token header, so the
# worker's credential check is the real one. tests/s-test.sh reads bin/s-input.sh
# and counts its runs in $MARK_DIR/s.
#
#   L1  the same suite and the same inputs in two gates: it runs once; the second
#       gate prints `impact-gate: reused tests/s-test.sh from <first run key>`
#   L2  a committed change to a file the suite reads: the next gate runs it
#   L3  a committed change to an unrelated file: reused
#   L4  SUITE_IMAGE_ID custom-a, again custom-a, then custom-b: run, reused, run;
#       the plan output names each image (and an `os:` one by default)
#   L5  a never.tsv `flake:` row, an out-of-tree suite and an unknown suite: run
#       in every gate and in the batch-shaped plan, never written to the ledger
#   L6  sfp_image_id: the override, the GitHub image pair, the os form
#   L7  a red in one gate: the next gate runs it again
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=2026-10-15T00:00:00Z
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
finish() { echo "suite-ledger.bh-6925: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 \
   || ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "suite-ledger.bh-6925: SKIPPED — needs git, jq and node with node:sqlite"
  finish
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write > /dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json the worker imports"
fi
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

# Nothing from the box: no GitHub image variables, no override, no builder credential.
unset ImageOS ImageVersion SUITE_IMAGE_ID HARNESS_SECRET JOBS_URL SUITE_REUSE GITHUB_ACTIONS \
  SUITE_LEDGER_TOKEN_FD SUITE_REUSE_RUN_KEY TEST_IMPACT_GATE_FRESH_MAIN HARNESS_CHECKOUT CI_BATCH_ESCALATE_TSV

# ── the scratch checkout ────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/suite-reuse.sh bin/fast-lints.sh \
         bin/test-trace-safety.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/catalog"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
printf '#!/bin/bash\necho s-input v1\n' > "$R/bin/s-input.sh"
printf '#!/bin/bash\necho f-input v1\n' > "$R/bin/f-input.sh"
# count <name> — the line every fixture suite uses to count its runs.
COUNT='n=$(cat "$MARK_DIR/$1" 2>/dev/null || echo 0); echo $((n + 1)) > "$MARK_DIR/$1"'
cat > "$R/tests/s-test.sh" <<SH
#!/bin/bash
ROOTD=\$(cd "\$(dirname "\$0")/.." && pwd)
bash "\$ROOTD/bin/s-input.sh" > /dev/null
set -- s; $COUNT
echo "s: 1 passed, 0 failed"
exit "\${S_RC:-0}"
SH
cat > "$R/tests/flaky-test.sh" <<SH
#!/bin/bash
ROOTD=\$(cd "\$(dirname "\$0")/.." && pwd)
bash "\$ROOTD/bin/f-input.sh" > /dev/null
set -- flaky; $COUNT
echo "flaky: 1 passed, 0 failed"
SH
cat > "$R/tests/oot-test.sh" <<SH
#!/bin/bash
# reads another ref, so no tree id can see what it reads
REF=origin/main
set -- oot; $COUNT
echo "oot: 1 passed, 0 failed"
SH
cat > "$R/tests/always-test.sh" <<SH
#!/bin/bash
set -- always; $COUNT
echo "always: 1 passed, 0 failed"
SH
chmod +x "$R"/tests/*.sh "$R"/bin/*.sh
printf 'tests/always-test.sh\n' > "$R/catalog/test-impact-always.txt"
printf '# suite\twhy\ntests/flaky-test.sh\tflake: fixture flake, fails one run in ten\n' > "$R/catalog/suite-reuse-never.tsv"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
B0=$(git -C "$R" rev-parse HEAD)
# The diff the gates see: s-test reads bin/s-input.sh, flaky reads bin/f-input.sh, oot is itself.
printf '# c1\n' >> "$R/bin/s-input.sh"; printf '# c1\n' >> "$R/bin/f-input.sh"; printf '# c1\n' >> "$R/tests/oot-test.sh"
G commit -qam c1 || exit 1
G remote add origin https://github.com/acme/widget.git
# commit <file> <tag> — one line appended to <file>, committed.
commit() { printf '# %s\n' "$2" >> "$R/$1"; G add -A && G commit -qm "$2" || { echo "commit failed: $2"; exit 1; }; }

# ── the stub ledger: worker.fetch over a file-backed node:sqlite D1 ────────
cat > "$T/driver.mjs" <<'EOF'
import { readFileSync, existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const [, , dir, dbfile, method, path, bodyf, cls] = process.argv;
const fresh = !existsSync(dbfile);
const db = new DatabaseSync(dbfile);
if (fresh) db.exec(readFileSync(dir + '/worker/jobs/schema.sql', 'utf8'));
if (method === 'Q') { console.log(JSON.stringify(db.prepare(path).all())); process.exit(0); }
const { d1 } = await import(dir + '/worker/jobs/test/lib/d1-sqlite.bh-1030.js');
const worker = (await import(dir + '/worker/jobs/src/index.js')).default;
const headers = { 'content-type': 'application/json',
  ...(cls === 'ci' ? { 'x-suite-ledger-token': process.env.SUITE_LEDGER_TOKEN || '' } : { authorization: 'Bearer SECRET' }) };
const res = await worker.fetch(new Request('https://jobs.test' + path, { method, headers, body: readFileSync(bodyf) }),
  { DB: d1(db), HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: 'tok-fixture-1' });
process.stdout.write((await res.text()) + '\n' + res.status + '\n');
EOF
cat > "$T/stub.sh" <<EOF
#!/bin/bash
echo "\$1 \$2 \$4" >> "$T/calls"
exec node "$T/driver.mjs" "$DIR" "$T/ledger.db" "\$@" 2>/dev/null
EOF
chmod +x "$T/stub.sh"
q() { node "$T/driver.mjs" "$DIR" "$T/ledger.db" Q "$1" 2>/dev/null; }

CTX=ubuntu-latest
export SUITE_REUSE_CURL="$T/stub.sh" SUITE_LEDGER_URL=https://ledger.invalid SUITE_LEDGER_TOKEN=tok-fixture-1
export SUITE_REUSE_CLASS=ci SUITE_REUSE_CTX="$CTX" SUITE_REUSE_REPO=acme/widget
export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
: > "$T/fast.empty"; : > "$T/calls"; mkdir -p "$T/mark"

# gate <tag> [VAR=value ...] — a prequeue-shaped gate: the real gate, traced,
# class ci, run key prequeue-<tag>. Output $T/<tag>.out, rc GRC.
gate() {
  local tag="$1"; shift
  ( cd "$R" && env "$@" MARK_DIR="$T/mark" SUITE_REUSE_RUN_KEY="prequeue-$tag" \
      bin/test-impact-gate.sh --base "$B0" --runner traced --trace-hits "$T/$tag.hits" --failed "$T/$tag.failed" ) > "$T/$tag.out" 2>&1
  GRC=$?
}
marks() { cat "$T/mark/$1" 2>/dev/null || echo 0; }
reused() { grep -qE "^impact-gate: reused $1 from $2 \([0-9]+s\)$" "$T/$3.out"; }
# batch <tag> <suite>... — the call bin/ci-plan.sh makes, on the current tree.
batch() {
  local tag="$1"; shift
  printf '%s\n' "$@" > "$T/$tag.in"
  ( cd "$R" && HARNESS_CHECKOUT="$R" bin/suite-reuse.sh plan --class ci --repo acme/widget --ctx "$CTX" --suites "$T/$tag.in" \
      --run "$T/$tag.run" --reused "$T/$tag.reused" --fingerprints "$T/$tag.fp" ) > "$T/$tag.out" 2>&1
}

# ── L1: two gates, the same inputs ──────────────────────────────────────────
gate l1a
[ "$GRC" = 0 ] && ok "L1 gate 1 rc 0" || { bad "L1 gate 1 rc=$GRC: $(tail -8 "$T/l1a.out")"; finish; }
[ "$(marks s)" = 1 ] && ok "L1 gate 1 runs the suite" || bad "L1 gate 1 s marks $(marks s)"
[ "$(q "SELECT status, class, ctx FROM suite_results WHERE suite='tests/s-test.sh' AND run_id='prequeue-l1a'")" \
  = "[{\"status\":\"ok\",\"class\":\"ci\",\"ctx\":\"$CTX\"}]" ] \
  && ok "L1 gate 1 wrote an ok ci row at the shared ctx" || bad "L1 rows: $(q 'SELECT suite, status, class, ctx, run_id FROM suite_results') out: $(tail -5 "$T/l1a.out")"
gate l1b
[ "$GRC" = 0 ] && ok "L1 gate 2 rc 0" || bad "L1 gate 2 rc=$GRC: $(tail -8 "$T/l1b.out")"
[ "$(marks s)" = 1 ] && ok "L1 gate 2 does not run it again (mark count 1)" || bad "L1 gate 2 s marks $(marks s)"
reused tests/s-test.sh prequeue-l1a l1b && ok "L1 gate 2 prints reused tests/s-test.sh from prequeue-l1a" \
  || bad "L1 no reused line: $(grep -E 'reuse' "$T/l1b.out")"
grep -qE '^suite-reuse: image os:' "$T/l1a.out" && ok "L4 the default image id is the os: form, named in the plan output" \
  || bad "L4 no image line: $(grep 'suite-reuse' "$T/l1a.out")"

# ── L2: a file the suite reads changes ──────────────────────────────────────
commit bin/s-input.sh l2
gate l2
[ "$(marks s)" = 2 ] && ok "L2 a change to bin/s-input.sh runs the suite again" || bad "L2 s marks $(marks s): $(grep reuse "$T/l2.out")"
reused tests/s-test.sh '[^ ]+' l2 && bad "L2 the suite must not be reused" || ok "L2 no reused line"

# ── L3: an unrelated file changes ───────────────────────────────────────────
mkdir -p "$R/docs"; commit docs/unrelated.md l3
gate l3
[ "$(marks s)" = 2 ] && ok "L3 an unrelated change keeps the reuse (mark stays 2)" || bad "L3 s marks $(marks s)"
reused tests/s-test.sh prequeue-l2 l3 && ok "L3 reused from the L2 gate" || bad "L3 out: $(grep reuse "$T/l3.out")"

# ── L4: the image id is in the key ─────────────────────────────────────────
gate l4a SUITE_IMAGE_ID=custom-a
[ "$(marks s)" = 3 ] && ok "L4 a new image id runs the suite" || bad "L4 custom-a s marks $(marks s)"
grep -qxF 'suite-reuse: image custom-a' "$T/l4a.out" && ok "L4 the plan names image custom-a" || bad "L4 a: $(grep 'suite-reuse' "$T/l4a.out")"
gate l4a2 SUITE_IMAGE_ID=custom-a
{ [ "$(marks s)" = 3 ] && reused tests/s-test.sh prequeue-l4a l4a2; } && ok "L4 the same image id again reuses it" \
  || bad "L4 custom-a again s marks $(marks s): $(grep reuse "$T/l4a2.out")"
gate l4b SUITE_IMAGE_ID=custom-b
[ "$(marks s)" = 4 ] && ok "L4 a different image id runs it again" || bad "L4 custom-b s marks $(marks s)"
grep -qxF 'suite-reuse: image custom-b' "$T/l4b.out" && ok "L4 the plan names image custom-b" || bad "L4 b: $(grep 'suite-reuse' "$T/l4b.out")"
gate l4x "SUITE_IMAGE_ID=a b"
{ [ "$(marks s)" = 5 ] && grep -qxF 'suite-reuse: off (fingerprint failed)' "$T/l4x.out" && [ "$GRC" = 0 ]; } \
  && ok "L4 a bad image id turns reuse off and the suite runs" || bad "L4 bad id s marks $(marks s) rc=$GRC: $(grep 'suite-reuse' "$T/l4x.out")"

# ── L5: never reused, never written ─────────────────────────────────────────
N=8  # l1a l1b l2 l3 l4a l4a2 l4b l4x
{ [ "$(marks flaky)" = "$N" ] && [ "$(marks oot)" = "$N" ]; } \
  && ok "L5 the flake-listed and the out-of-tree suite ran in all $N gates" || bad "L5 flaky=$(marks flaky) oot=$(marks oot), want $N"
[ "$(q "SELECT COUNT(*) AS n FROM suite_results WHERE suite IN ('tests/flaky-test.sh','tests/oot-test.sh','tests/always-test.sh')")" = '[{"n":0}]' ] \
  && ok "L5 none of them is ever written to the ledger" || bad "L5 rows: $(q "SELECT suite, run_id FROM suite_results")"
batch l5 tests/s-test.sh tests/flaky-test.sh tests/oot-test.sh tests/zz-missing-test.sh
{ grep -qxF tests/s-test.sh <(cut -f1 "$T/l5.reused") \
  && [ "$(grep -c . "$T/l5.run")" = 3 ] && ! grep -qxF tests/s-test.sh "$T/l5.run"; } \
  && ok "L5 the batch plan reuses s and runs the three others" || bad "L5 batch run: $(cat "$T/l5.run") out: $(cat "$T/l5.out")"
row() { awk -F'\t' -v s="$2" '$1 == s { print $2 "|" $3 }' "$1"; }
{ [ "$(row "$T/l5.fp" tests/flaky-test.sh)" = "-|never.tsv: flake: fixture flake, fails one run in ten" ] \
  && [ "$(row "$T/l5.fp" tests/oot-test.sh)" = "-|out-of-tree: origin/main" ] \
  && [ "$(row "$T/l5.fp" tests/zz-missing-test.sh)" = "-|unknown suite" ]; } \
  && ok "L5 fp '-' with the reason: flake, out-of-tree, unknown suite" || bad "L5 fps: $(cat "$T/l5.fp")"

# ── L6: sfp_image_id ───────────────────────────────────────────────────────
img() { ( unset ImageOS ImageVersion SUITE_IMAGE_ID; for a in "$@"; do export "${a?}"; done
          . "$DIR/bin/lib/suite-fingerprint.sh" && sfp_image_id ) 2> "$T/img.err"; }
L6_OS=$(img); L6_RC=$?
[ "$L6_RC" = 0 ] && [[ "$L6_OS" =~ ^os:[A-Za-z0-9._:@+/-]+:[A-Za-z0-9._:@+/-]*:[A-Za-z0-9._:@+/-]+$ ]] \
  && ok "L6 neither set: os:<id>:<version>:<arch> ($L6_OS)" || bad "L6 os form rc=$L6_RC '$L6_OS'"
[ "$(img SUITE_IMAGE_ID=custom-a)" = custom-a ] && ok "L6 SUITE_IMAGE_ID verbatim" || bad "L6 override '$(img SUITE_IMAGE_ID=custom-a)'"
[ "$(img SUITE_IMAGE_ID=reg.example/img@sha256:ab12 ImageOS=ubuntu24 ImageVersion=20261012.1)" = reg.example/img@sha256:ab12 ] \
  && ok "L6 SUITE_IMAGE_ID wins over the GitHub pair" || bad "L6 override vs pair"
img "SUITE_IMAGE_ID=a b" > /dev/null; L6_RC=$?
{ [ "$L6_RC" = 2 ] && grep -q SUITE_IMAGE_ID "$T/img.err"; } && ok "L6 SUITE_IMAGE_ID with a space: rc 2, named" || bad "L6 space rc=$L6_RC"
img "SUITE_IMAGE_ID=$(printf 'a%.0s' $(seq 129))" > /dev/null; L6_RC=$?
[ "$L6_RC" = 2 ] && ok "L6 SUITE_IMAGE_ID of 129 chars: rc 2" || bad "L6 129 chars rc=$L6_RC"
[ "$(img "SUITE_IMAGE_ID=$(printf 'a%.0s' $(seq 128))")" = "$(printf 'a%.0s' $(seq 128))" ] && ok "L6 128 chars is kept" || bad "L6 128 chars"
[ "$(img ImageOS=ubuntu24 ImageVersion=20261012.1)" = gh:ubuntu24:20261012.1 ] && ok "L6 the GitHub pair: gh:<os>:<version>" \
  || bad "L6 pair '$(img ImageOS=ubuntu24 ImageVersion=20261012.1)'"
[ -n "$L6_OS" ] && [ "$(img ImageOS=ubuntu24)" = "$L6_OS" ] && ok "L6 only ImageOS: the os form" || bad "L6 only ImageOS '$(img ImageOS=ubuntu24)'"
[ -n "$L6_OS" ] && [ "$(img ImageVersion=20261012.1)" = "$L6_OS" ] && ok "L6 only ImageVersion: the os form" || bad "L6 only ImageVersion"
[ -n "$L6_OS" ] && [ "$(img ImageOS=ubuntu24 "ImageVersion=x y")" = "$L6_OS" ] && ok "L6 a bad ImageVersion: the os form" || bad "L6 bad ImageVersion '$(img ImageOS=ubuntu24 "ImageVersion=x y")'"
[ -n "$L6_OS" ] && [ "$(img "ImageOS=ubu:ntu" ImageVersion=1)" = "$L6_OS" ] && ok "L6 a bad ImageOS: the os form" || bad "L6 bad ImageOS"

# ── L7: a red is never reused ───────────────────────────────────────────────
commit bin/s-input.sh l7
before=$(marks s)
gate l7a S_RC=1
{ [ "$GRC" = 1 ] && [ "$(marks s)" = $((before + 1)) ]; } && ok "L7 gate 1 runs it and goes red" || bad "L7 gate 1 rc=$GRC marks $(marks s)"
[ "$(q "SELECT status FROM suite_results WHERE run_id='prequeue-l7a' AND suite='tests/s-test.sh'")" = '[{"status":"fail"}]' ] \
  && ok "L7 the red is written fail" || bad "L7 rows: $(q "SELECT suite, status, run_id FROM suite_results WHERE run_id='prequeue-l7a'")"
gate l7b
{ [ "$(marks s)" = $((before + 2)) ] && ! reused tests/s-test.sh '[^ ]+' l7b; } && ok "L7 gate 2 runs it again" \
  || bad "L7 gate 2 marks $(marks s): $(grep reuse "$T/l7b.out")"

finish
