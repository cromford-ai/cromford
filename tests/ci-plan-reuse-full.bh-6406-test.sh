#!/bin/bash
# tests/ci-plan-reuse-full.bh-6406-test.sh — a full-mode run reuses the suites
# whose v2 fingerprint did not move, names each one with its fingerprint, and
# the nightly run never reuses (BH-6406, C1 of BH-6371; ticket T4 and T5).
#
# The real bin/ci-plan.sh, bin/suite-reuse.sh, bin/test-impact.sh and
# bin/test-tiers.sh run in a committed scratch checkout: u1 sources
# tests/lib/h1.sh, which names h2.sh and h3.sh; u2 sources h3.sh; u3 reads
# catalog/c1.json; u4 sources tests/lib/scratch.sh, which the tree's
# catalog/ci-batch-escalate.tsv escalates; tests/lib/orphan.sh is reached by
# nothing; sa is an always suite. The ledger is the 5368 suite's:
# SUITE_REUSE_CURL hands each request to worker.fetch over a file-backed
# node:sqlite, seeded `ok` for the BASE tree's fingerprints as run BASEKEY.
# Each head is the base plus ONE edit.
#
#   T4   head edits h2: an escalated batch plans {u1, sa}, reused=3, and one
#        `reuse: reused <s> from BASEKEY (<d>s) fp <hex>` line each for u2, u3,
#        u4, <hex> = that suite's row in the run's fingerprints.tsv
#   T4b  head edits catalog/c1.json: plans {u3, sa}
#   T4c  head edits tests/lib/orphan.sh: reused=0, every suite runs
#   T4d  head edits tests/lib/scratch.sh: reused=0 (an escalate row, even with
#        CI_BATCH_ESCALATE_TSV pointing at other rules)
#   T4e  a push-to-main corpus after the h2 edit reuses u2, u3, u4
#   T4f  a shard with the T4 reused.tsv: no ledger call, the same fp lines
#   T4g  a shard whose reused.tsv has no fingerprints.tsv beside it: ` fp -`
#   T5   --tier nightly with CI_PLAN_REUSE=1 and credentials: no call, reuse=-
#   T5b  --tier nightly with CI_PLAN_REUSED_FILE naming u2: u2 still runs,
#        reuse=off: nightly never reuses, reused=0
#   T5c  CI_EVENT=schedule with the same file: u2 still runs
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
NOW=2026-10-13T00:00:00Z

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "ci-plan-reuse-full: SKIPPED — needs node with node:sqlite, and jq"
  echo "ci-plan-reuse-full: $PASS passed, $FAIL failed"
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
for s in bin/ci-plan.sh bin/suite-reuse.sh bin/test-impact.sh bin/fast-lints.sh bin/test-tiers.sh \
         bin/lib/ci-batch-escalate.sh bin/lib/suite-fingerprint.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/catalog"
cat > "$R/tests/lib/h1.sh" <<'EOF'
H1_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H1_DIR/h2.sh"
. "$H1_DIR/h3.sh"
h1() { echo v1; }
EOF
printf 'h2() { echo v1; }\n' > "$R/tests/lib/h2.sh"
printf 'h3() { echo v1; }\n' > "$R/tests/lib/h3.sh"
printf 'orphan() { echo v1; }\n' > "$R/tests/lib/orphan.sh"
printf '# scratch v1\n' > "$R/tests/lib/scratch.sh"
printf '{"v":1}\n' > "$R/catalog/c1.json"
printf 'tests/lib/scratch.sh\tescalate\tglobal\n' > "$R/catalog/ci-batch-escalate.tsv"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/h1.sh"\nh1\n' > "$R/tests/u1.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/h3.sh"\nh3\n' > "$R/tests/u2.sh"
printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\ncat "$DIR/catalog/c1.json"\n' > "$R/tests/u3.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh"\necho plain\n' > "$R/tests/u4.sh"
printf '#!/bin/bash\necho always\n' > "$R/tests/sa.sh"
printf 'tests/sa.sh\n' > "$R/catalog/test-impact-always.txt"
# The environment's rules (the batch's, read by ci-plan) match nothing here;
# the fingerprint must read the tree's own file, never this one.
printf 'nothing-here/\tescalate\tno scratch path matches\n' > "$T/rules.tsv"
: > "$T/notiers.tsv"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
G branch -q -M base
BASE=$(G rev-parse HEAD)

# ── the ledger: worker.fetch over a file-backed node:sqlite D1 (from 5368) ──
cat > "$T/driver.mjs" <<'EOF'
import { readFileSync, existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const [, , dir, dbfile, method, path, bodyf, cls] = process.argv;
const fresh = !existsSync(dbfile);
const db = new DatabaseSync(dbfile);
if (fresh) db.exec(readFileSync(dir + '/worker/jobs/schema.sql', 'utf8'));
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
exec node "$T/driver.mjs" "$DIR" "$T/ledger.db" "\$@"
EOF
chmod +x "$T/stub.sh"
: > "$T/calls"
export SUITE_REUSE_CURL="$T/stub.sh"
unset SUITE_LEDGER_URL SUITE_LEDGER_TOKEN JOBS_URL HARNESS_SECRET SUITE_REUSE GITHUB_ACTIONS GITHUB_STEP_SUMMARY \
  CI_PLAN_REUSE CI_PLAN_REUSED_FILE CI_PLAN_REUSE_DIR CI_REUSE_CTX CI_QUARANTINE CI_PLAN_ESCALATION TI_PR_LABELS \
  HARNESS_CHECKOUT CI_BATCH_ESCALATE_TSV

# Seed: every base suite ok in run BASEKEY; u2 for 7 s.
printf '%s\n' tests/u1.sh tests/u2.sh tests/u3.sh tests/u4.sh tests/sa.sh > "$T/all"
( cd "$R" && . bin/lib/suite-fingerprint.sh && sfp_compute HEAD "$T/all" "$T/base.fp" ) \
  || { echo "cannot fingerprint the base"; exit 1; }
printf 'tests/u1.sh\tok\t4\ntests/u2.sh\tok\t7\ntests/u3.sh\tok\t5\ntests/u4.sh\tok\t6\ntests/sa.sh\tok\t1\n' > "$T/base.res"
( cd "$R" && SUITE_LEDGER_URL=https://ledger.test SUITE_LEDGER_TOKEN=tok "$R/bin/suite-reuse.sh" record \
    --repo scratch/repo --ctx ctx1 --run-key BASEKEY --fingerprints "$T/base.fp" --results "$T/base.res" ) \
  > "$T/seed.out" 2>&1
grep -q '^suite-reuse: recorded 4 result' "$T/seed.out" && ok "seed: four fingerprinted base suites recorded" \
  || bad "seed: $(cat "$T/seed.out")"

# head <path> — a branch off the base with one line appended to <path>.
head_edit() {
  G checkout -q -B "h-$(printf '%s' "$1" | tr '/.' '__')" base || { echo "checkout failed"; exit 1; }
  printf '# head edit\n' >> "$R/$1"
  G commit -qam "edit $1" || { echo "commit failed: $1"; exit 1; }
  G diff --no-renames --name-only "$BASE" HEAD > "$T/changed"
}

# cplan <tag> [args...] [-- VAR=val ...] — one ci-plan run in the scratch
# checkout; list in $T/<tag>.list, outputs in $T/<tag>.go, reuse dir $T/<tag>.rd
cplan() {
  local tag="$1" args=() vars=(); shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; vars=("$@")
  rm -rf "$T/$tag".*
  ( cd "$R" && env CI_PLAN_CHANGED_FILE="$T/changed" TI_BASE="$BASE" CI_BATCH_ESCALATE_TSV="$T/rules.tsv" \
      CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_REPO=scratch/repo CI_REUSE_CTX=ctx1 \
      GITHUB_OUTPUT="$T/$tag.go" CI_PLAN_REUSE_DIR="$T/$tag.rd" \
      ${vars[@]+"${vars[@]}"} "$R/bin/ci-plan.sh" --out "$T/$tag.list" ${args[@]+"${args[@]}"} ) \
    > "$T/$tag.out" 2> "$T/$tag.err"
  RC=$?
}
out() { sed -n "s/^$2=//p" "$T/$1.go" 2>/dev/null | tail -1; }
lst() { LC_ALL=C sort "$T/$1.list" 2>/dev/null | paste -sd' ' -; }
ncalls() { grep -c . "$T/calls"; }
fpof() { awk -F'\t' -v s="$2" '$1 == s { print $2 }' "$1"; }
CREDS=(SUITE_LEDGER_URL=https://ledger.test SUITE_LEDGER_TOKEN=tok)
BATCH=(CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/x)
ESC=(CI_PLAN_ESCALATION='selection input: catalog/x')
dump() { echo "rc=$RC list=$(lst "$1") go=$(tr '\n' ' ' < "$T/$1.go" 2>&1) out=$(cat "$T/$1.out" "$T/$1.err" 2>&1)"; }

# reused_lines <tag> <fp-file> <suite:secs>... — rc 0 when the run printed
# exactly these reused lines, each ending in the suite's fp from <fp-file>.
reused_lines() {
  local tag="$1" fpf="$2" want="" s x f; shift 2
  for x in "$@"; do
    s="${x%:*}"; f=$(fpof "$fpf" "$s")
    grep -qE '^[0-9a-f]{64}$' <<<"$f" || return 1
    want="${want}reuse: reused $s from BASEKEY (${x#*:}s) fp $f"$'\n'
  done
  [ "$(grep '^reuse: reused ' "$T/$tag.out")"$'\n' = "$want" ]
}

# ── T4: a helper edit reuses every suite that does not reach the helper ────
head_edit tests/lib/h2.sh
: > "$T/calls"
cplan t4 -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 "${ESC[@]}"
[ "$RC" = 0 ] && ok "T4 rc 0" || bad "T4 $(dump t4)"
[ "$(out t4 mode)" = full ] && ok "T4 mode=full" || bad "T4 mode=$(out t4 mode)"
[ "$(lst t4)" = "tests/sa.sh tests/u1.sh" ] && ok "T4 planned exactly {u1, sa}" || bad "T4 list: $(dump t4)"
{ [ "$(out t4 reuse)" = on ] && [ "$(out t4 reused)" = 3 ] && [ "$(out t4 saved_s)" = 18 ]; } \
  && ok "T4 reuse=on reused=3 saved_s=18" || bad "T4 outputs: $(dump t4)"
reused_lines t4 "$T/t4.rd/fingerprints.tsv" tests/u2.sh:7 tests/u3.sh:5 tests/u4.sh:6 \
  && ok "T4 one reused line per suite, each with its fp from fingerprints.tsv" \
  || bad "T4 reused lines: $(grep '^reuse:' "$T/t4.out") fps=$(cat "$T/t4.rd/fingerprints.tsv" 2>&1)"
[ "$(fpof "$T/t4.rd/fingerprints.tsv" tests/u2.sh)" = "$(fpof "$T/base.fp" tests/u2.sh)" ] \
  && ok "T4 u2's head fp is its base fp" || bad "T4 u2 fp moved"
grep -qxF 'reuse: on — ran 2 reused 3 of 5 (saved ~18s)' "$T/t4.out" && ok "T4 reuse summary line" \
  || bad "T4 summary: $(cat "$T/t4.out")"
[ "$(ncalls)" -ge 1 ] && ok "T4 looked up" || bad "T4 made no ledger call"
T4N=$(out t4 n)

# ── T4f / T4g: a shard takes the fp from the file beside the reused list ───
: > "$T/calls"
cplan t4f --expect-n "$T4N" -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 "${ESC[@]}" CI_PLAN_REUSED_FILE="$T/t4.rd/reused.tsv"
{ [ "$RC" = 0 ] && cmp -s "$T/t4.list" "$T/t4f.list" && [ "$(ncalls)" = 0 ]; } \
  && ok "T4f shard: same list, no ledger call" || bad "T4f calls=$(ncalls) $(dump t4f)"
reused_lines t4f "$T/t4.rd/fingerprints.tsv" tests/u2.sh:7 tests/u3.sh:5 tests/u4.sh:6 \
  && ok "T4f shard lines carry the plan job's fps" || bad "T4f lines: $(grep '^reuse:' "$T/t4f.out")"
mkdir -p "$T/nofp" && cp "$T/t4.rd/reused.tsv" "$T/nofp/reused.tsv"
cplan t4g --expect-n "$T4N" -- "${BATCH[@]}" "${ESC[@]}" CI_PLAN_REUSED_FILE="$T/nofp/reused.tsv"
{ [ "$RC" = 0 ] && [ "$(grep -c '^reuse: reused .* fp -$' "$T/t4g.out")" = 3 ] && [ "$(out t4g reused)" = 3 ]; } \
  && ok "T4g no fingerprints.tsv beside the list: three lines end in ' fp -'" || bad "T4g $(dump t4g)"

# ── T4b-T4e ────────────────────────────────────────────────────────────────
head_edit catalog/c1.json
cplan t4b -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 "${ESC[@]}"
{ [ "$RC" = 0 ] && [ "$(lst t4b)" = "tests/sa.sh tests/u3.sh" ] && [ "$(out t4b reused)" = 3 ]; } \
  && ok "T4b catalog/c1.json: planned {u3, sa}" || bad "T4b $(dump t4b)"
head_edit tests/lib/orphan.sh
cplan t4c -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 "${ESC[@]}"
{ [ "$RC" = 0 ] && [ "$(grep -c . "$T/t4c.list")" = 5 ] && [ "$(out t4c reused)" = 0 ] && [ "$(out t4c reuse)" = on ]; } \
  && ok "T4c an orphan helper moves every fp: reused=0, all 5 run" || bad "T4c $(dump t4c)"
head_edit tests/lib/scratch.sh
cplan t4d -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 "${ESC[@]}"
{ [ "$RC" = 0 ] && [ "$(grep -c . "$T/t4d.list")" = 5 ] && [ "$(out t4d reused)" = 0 ]; } \
  && ok "T4d tests/lib/scratch.sh (escalate row) moves every fp: reused=0" || bad "T4d $(dump t4d)"
head_edit tests/lib/h2.sh
cplan t4e -- CI_EVENT=push CI_ACTOR=someone "${CREDS[@]}" CI_PLAN_REUSE=1
{ [ "$RC" = 0 ] && [ "$(lst t4e)" = "tests/sa.sh tests/u1.sh" ] && [ "$(out t4e reused)" = 3 ] \
  && reused_lines t4e "$T/t4e.rd/fingerprints.tsv" tests/u2.sh:7 tests/u3.sh:5 tests/u4.sh:6; } \
  && ok "T4e push corpus: u2, u3, u4 reused with their fps" || bad "T4e $(dump t4e)"

# ── T5: the nightly run never reuses ───────────────────────────────────────
printf 'tests/u2.sh\tnightly\t9\t-\tslow\ntests/u3.sh\tnightly\t9\t-\tslow\n' > "$T/tiers-n.tsv"
printf 'tests/u2.sh\tBASEKEY\t7\tci\n' > "$T/u2-reused.tsv"
: > "$T/calls"
cplan t5 --tier nightly -- CI_EVENT=schedule "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_TIER_FILE="$T/tiers-n.tsv"
{ [ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(out t5 reuse)" = - ] && [ "$(out t5 reused)" = 0 ] \
  && [ "$(lst t5)" = "tests/u2.sh tests/u3.sh" ]; } \
  && ok "T5 nightly with credentials: no call, reuse=-, the whole nightly tier" || bad "T5 calls=$(ncalls) $(dump t5)"
cplan t5b --tier nightly -- CI_EVENT=workflow_dispatch CI_PLAN_TIER_FILE="$T/tiers-n.tsv" CI_PLAN_REUSED_FILE="$T/u2-reused.tsv"
{ [ "$RC" = 0 ] && [ "$(lst t5b)" = "tests/u2.sh tests/u3.sh" ] && [ "$(out t5b reuse)" = "off: nightly never reuses" ] \
  && [ "$(out t5b reused)" = 0 ] && grep -qxF 'reuse: off: nightly never reuses' "$T/t5b.out" \
  && ! grep -q '^reuse: reused' "$T/t5b.out"; } \
  && ok "T5b --tier nightly ignores a reused file: u2 runs, reuse=off: nightly never reuses" || bad "T5b $(dump t5b)"
cplan t5c -- CI_EVENT=schedule CI_PLAN_REUSED_FILE="$T/u2-reused.tsv"
{ [ "$RC" = 0 ] && grep -qxF tests/u2.sh "$T/t5c.list" && [ "$(out t5c reuse)" = "off: nightly never reuses" ] \
  && [ "$(out t5c reused)" = 0 ]; } \
  && ok "T5c CI_EVENT=schedule ignores a reused file: u2 runs" || bad "T5c $(dump t5c)"

echo "ci-plan-reuse-full: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
