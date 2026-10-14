#!/bin/bash
# tests/ci-plan-reuse.bh-5368-test.sh — bin/ci-plan.sh asks the suite ledger
# which planned suites already went green at the same input fingerprint, and a
# merge-queue batch runs only the rest (BH-5354.2 / BH-5368).
#
# The real bin/ci-plan.sh, bin/suite-reuse.sh, bin/test-impact.sh and
# bin/test-tiers.sh run in a committed scratch checkout: suites tests/s1..s3
# source bin/lib/area1..3.sh, tests/sa.sh is an always suite. The ledger is the
# contract suite's: SUITE_REUSE_CURL hands each request to worker.fetch
# (worker/jobs/src/index.js) over a file-backed node:sqlite with schema.sql, and
# logs `<method> <path>` to $T/calls. It is seeded by `bin/suite-reuse.sh
# record` with ok `ci` rows for the BASE tree's fingerprints; the head is base +
# PR1 (area1) + PR2 (area2), so only s3's fingerprint still matches.
#
#   C1  an escalated batch (`selection input:`) plans {s1, s2, sa}: s3 reused,
#       outputs reuse=on reused=1 saved_s=6, the `reuse:` lines, the SUMMARY
#       shape, the reuse dir's reused.tsv, the ::notice; batch-selected too
#   C2  a shard with CI_PLAN_REUSED_FILE plans the same list with NO ledger
#       call (credentials present), --expect-n agrees; a wrong n is rc 1
#   C3  the `full` label (draft, member), `unmapped:`, `member labels
#       unreadable`, workflow_dispatch, an ordinary PR and --tier nightly never
#       look up: no call, reuse=-
#   C4  no token: same list and n as without reuse, reuse=off: no credential
#   C5  a reused list that would empty the plan is dropped (shard and plan)
#   C6  a push-to-main corpus reuses; a quarantined suite is never reused
#   C7  an unreadable CI_PLAN_REUSED_FILE is rc 2, never the full list
#   C8  the corpus=0 path still writes reused=0 saved_s=0 reuse=-
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
NOW=2026-10-08T00:00:00Z

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "ci-plan-reuse: SKIPPED — needs node with node:sqlite, and jq"
  echo "ci-plan-reuse: $PASS passed, $FAIL failed"
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
         bin/lib/ci-batch-escalate.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/bin/lib" "$R/catalog"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
for i in 1 2 3; do
  printf '#!/bin/bash\narea%s() { echo v1; }\n' "$i" > "$R/bin/lib/area$i.sh"
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n. "$DIR/bin/lib/area%s.sh"\narea%s\n' "$i" "$i" > "$R/tests/s$i.sh"
done
printf '#!/bin/bash\necho always\n' > "$R/tests/sa.sh"
printf 'tests/sa.sh\n' > "$R/catalog/test-impact-always.txt"
# The escalation rules carry one row that no path here matches, so a batch of
# area edits stays batch-selected (a file with no escalate row fails closed).
printf 'nothing-here/\tescalate\tno scratch path matches\n' > "$T/rules.tsv"
: > "$T/notiers.tsv"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
BASE=$(G rev-parse HEAD)

# ── the ledger: worker.fetch over a file-backed node:sqlite D1 ─────────────
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
  HARNESS_CHECKOUT

# Seed: every base suite ok in run BASEKEY, s3 for 6 s.
printf '%s\n' tests/s1.sh tests/s2.sh tests/s3.sh tests/sa.sh > "$T/all"
( cd "$R" && . bin/lib/suite-fingerprint.sh && sfp_compute HEAD "$T/all" "$T/base.fp" ) \
  || { echo "cannot fingerprint the base"; exit 1; }
printf 'tests/s1.sh\tok\t4\ntests/s2.sh\tok\t5\ntests/s3.sh\tok\t6\ntests/sa.sh\tok\t1\n' > "$T/base.res"
( cd "$R" && SUITE_LEDGER_URL=https://ledger.test SUITE_LEDGER_TOKEN=tok "$R/bin/suite-reuse.sh" record \
    --repo scratch/repo --ctx ctx1 --run-key BASEKEY --fingerprints "$T/base.fp" --results "$T/base.res" ) \
  > "$T/seed.out" 2>&1
grep -q '^suite-reuse: recorded 3 result' "$T/seed.out" && ok "seed: three fingerprinted base suites recorded" \
  || bad "seed: $(cat "$T/seed.out")"

# The batch head: PR1 moves area1, PR2 moves area2.
printf '#!/bin/bash\narea1() { echo v2; }\n' > "$R/bin/lib/area1.sh"; G commit -qam pr1
printf '#!/bin/bash\narea2() { echo v2; }\n' > "$R/bin/lib/area2.sh"; G commit -qam pr2
G diff --no-renames --name-only "$BASE" HEAD > "$T/changed"
: > "$T/calls"

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
CREDS=(SUITE_LEDGER_URL=https://ledger.test SUITE_LEDGER_TOKEN=tok)
BATCH=(CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/x)

# ── C1 ──────────────────────────────────────────────────────────────────────
cplan c1 -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_ESCALATION='selection input: catalog/x' \
  GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$T/c1.sum"
[ "$RC" = 0 ] && ok "C1 rc 0" || bad "C1 rc=$RC err=$(cat "$T/c1.err")"
[ "$(lst c1)" = "tests/s1.sh tests/s2.sh tests/sa.sh" ] && ok "C1 planned exactly {s1, s2, sa}" \
  || bad "C1 list: $(lst c1) out=$(cat "$T/c1.out" "$T/c1.err")"
{ [ "$(out c1 reuse)" = on ] && [ "$(out c1 reused)" = 1 ] && [ "$(out c1 saved_s)" = 6 ] && [ "$(out c1 count)" = 3 ]; } \
  && ok "C1 outputs reuse=on reused=1 saved_s=6 count=3" || bad "C1 outputs: $(cat "$T/c1.go")"
# BH-6406: the line ends in the fingerprint, the s3 row of the run's own fingerprints.tsv.
C1FP=$(awk -F'\t' '$1 == "tests/s3.sh" { print $2 }' "$T/c1.rd/fingerprints.tsv" 2>/dev/null)
{ grep -qxE 'reuse: reused tests/s3\.sh from BASEKEY \(6s\) fp [0-9a-f]{64}' "$T/c1.out" \
  && grep -qxF "reuse: reused tests/s3.sh from BASEKEY (6s) fp $C1FP" "$T/c1.out"; } \
  && ok "C1 names s3, the run it came from and its fingerprint" || bad "C1 no reused line: $(cat "$T/c1.out")"
grep -qxF 'reuse: on — ran 3 reused 1 of 4 (saved ~6s)' "$T/c1.out" && ok "C1 reuse summary line" \
  || bad "C1 no reuse summary: $(cat "$T/c1.out")"
grep -qE '^impact: 3 of 4 suites \(full: selection input: catalog/x; tiers: .*\) — 1 shard\(s\), mode=full$' "$T/c1.out" \
  && ok "C1 SUMMARY keeps its shape, N is the reduced count" || bad "C1 summary: $(cat "$T/c1.out")"
[ "$(out c1 summary)" = "$(grep '^impact: ' "$T/c1.out")" ] && ok "C1 summary output is the SUMMARY line" || bad "C1 summary output"
grep -qF '::notice title=ci-plan reuse::reuse: on — ran 3 reused 1 of 4' "$T/c1.out" && ok "C1 ::notice under Actions" \
  || bad "C1 no notice"
grep -qF 'reuse: on — ran 3 reused 1 of 4' "$T/c1.sum" && ok "C1 step summary carries the reuse line" || bad "C1 step summary"
{ [ "$(cut -f1 "$T/c1.rd/reused.tsv")" = tests/s3.sh ] && grep -q $'^tests/s3.sh\tBASEKEY\t6\tci$' "$T/c1.rd/reused.tsv"; } \
  && ok "C1 reuse dir reused.tsv names s3" || bad "C1 reused.tsv: $(cat "$T/c1.rd/reused.tsv" 2>&1)"
[ "$(awk -F'\t' '$2 ~ /^[0-9a-f]{64}$/' "$T/c1.rd/fingerprints.tsv" | wc -l | tr -d ' ')" = 3 ] \
  && ok "C1 reuse dir fingerprints.tsv for record" || bad "C1 fingerprints.tsv: $(cat "$T/c1.rd/fingerprints.tsv" 2>&1)"
[ "$(ncalls)" -ge 1 ] && ok "C1 looked up" || bad "C1 made no ledger call"
C1N=$(out c1 n)

cplan c1b -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_ESCALATION=-
{ [ "$RC" = 0 ] && [ "$(lst c1b)" = "tests/s1.sh tests/s2.sh tests/sa.sh" ] && [ "$(out c1b mode)" = batch-selected ] \
  && [ "$(out c1b reuse)" = on ] && [ "$(out c1b reused)" = 0 ]; } \
  && ok "C1 batch-selected: {s1, s2, sa}, nothing left to reuse" \
  || bad "C1 batch-selected rc=$RC list=$(lst c1b) go=$(cat "$T/c1b.go" 2>&1) err=$(cat "$T/c1b.err")"

# ── C2: the shard subtracts the plan's list, with no network ───────────────
: > "$T/calls"
cplan c2 --expect-n "$C1N" -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_ESCALATION='selection input: catalog/x' \
  CI_PLAN_REUSED_FILE="$T/c1.rd/reused.tsv"
[ "$RC" = 0 ] && ok "C2 shard rc 0, --expect-n agrees" || bad "C2 rc=$RC err=$(cat "$T/c2.err")"
{ cmp -s "$T/c1.list" "$T/c2.list" && [ "$(lst c2)" = "tests/s1.sh tests/s2.sh tests/sa.sh" ]; } \
  && ok "C2 identical list, s3 subtracted" || bad "C2 list: $(lst c2)"
{ [ "$(out c2 reused)" = 1 ] && [ "$(out c2 reuse)" = on ]; } && ok "C2 reused=1" || bad "C2 outputs: $(cat "$T/c2.go")"
[ "$(ncalls)" = 0 ] && ok "C2 zero ledger calls" || bad "C2 calls: $(cat "$T/calls")"
cplan c2x --expect-n 99 -- "${BATCH[@]}" CI_PLAN_ESCALATION='selection input: catalog/x' CI_PLAN_REUSED_FILE="$T/c1.rd/reused.tsv"
[ "$RC" = 1 ] && ok "C2 a disagreeing --expect-n is rc 1" || bad "C2 expect-n 99 rc=$RC"

# ── C3: never looks up ─────────────────────────────────────────────────────
printf 'tests/s3.sh\tnightly\t9\t-\tslow\n' > "$T/tiers-n.tsv"
c3() { # c3 <tag> <args/vars for cplan...>
  local tag="$1"; shift
  : > "$T/calls"
  cplan "$tag" "$@"
  { [ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(out "$tag" reuse)" = - ] && [ "$(out "$tag" reused)" = 0 ] \
    && ! grep -q '^reuse:' "$T/$tag.out"; } \
    && ok "C3 $tag: no lookup, reuse=-" \
    || bad "C3 $tag rc=$RC calls=$(ncalls) go=$(cat "$T/$tag.go" 2>&1) err=$(cat "$T/$tag.err")"
}
c3 full-draft -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 TI_PR_LABELS=full
[ "$(out full-draft count)" = 4 ] && ok "C3 full-draft runs every suite" || bad "C3 full-draft count $(out full-draft count)"
c3 unmapped -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_ESCALATION='unmapped: x'
c3 full-member -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_ESCALATION="the 'full' label on #12"
c3 unreadable -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_ESCALATION='member labels unreadable (x)'
c3 dispatch -- CI_EVENT=workflow_dispatch "${CREDS[@]}" CI_PLAN_REUSE=1
c3 ordinary -- CI_EVENT=pull_request TI_PR_HEAD_REF=ticket/x TI_PR_LABELS=full "${CREDS[@]}" CI_PLAN_REUSE=1
for t in unmapped full-member unreadable dispatch ordinary; do
  [ "$(out "$t" count)" = 4 ] && ok "C3 $t runs every suite" || bad "C3 $t count $(out "$t" count)"
done
c3 nightly --tier nightly -- CI_EVENT=schedule "${CREDS[@]}" CI_PLAN_REUSE=1 CI_PLAN_TIER_FILE="$T/tiers-n.tsv"
grep -qxF tests/s3.sh "$T/nightly.list" && ok "C3 nightly runs its tier whole" || bad "C3 nightly list: $(lst nightly)"

# ── C4: no token is the run without reuse ──────────────────────────────────
: > "$T/calls"
cplan c4 -- "${BATCH[@]}" SUITE_LEDGER_URL=https://ledger.test CI_PLAN_REUSE=1 CI_PLAN_ESCALATION='selection input: catalog/x'
cplan c4ref -- "${BATCH[@]}" CI_PLAN_ESCALATION='selection input: catalog/x'
{ [ "$RC" = 0 ] && cmp -s "$T/c4.list" "$T/c4ref.list" && [ "$(out c4 n)" = "$(out c4ref n)" ] && [ "$(lst c4)" = "$(lst c4ref)" ] \
  && [ "$(grep -c . "$T/c4.list")" = 4 ]; } && ok "C4 same list and n as a run without reuse" \
  || bad "C4 list=$(lst c4) ref=$(lst c4ref)"
{ [ "$(out c4 reuse)" = "off: no credential" ] && [ "$(out c4 reused)" = 0 ] && [ "$(out c4 saved_s)" = 0 ]; } \
  && ok "C4 reuse=off: no credential, reused=0" || bad "C4 outputs: $(cat "$T/c4.go")"
grep -qxF 'reuse: off: no credential' "$T/c4.out" && ok "C4 says why" || bad "C4 out: $(cat "$T/c4.out")"
grep -qE '^(reuse|reused|saved_s)=' "$T/c4ref.go" && bad "C4 CI_PLAN_REUSE unset must keep the old output keys: $(cat "$T/c4ref.go")" \
  || ok "C4 CI_PLAN_REUSE unset: no reuse output keys"
[ "$(ncalls)" = 0 ] && ok "C4 no ledger call" || bad "C4 calls: $(cat "$T/calls")"

# ── C5: a reuse that would run nothing is dropped ──────────────────────────
printf 'tests/%s.sh\tBASEKEY\t1\tci\n' s1 s2 s3 sa > "$T/every.tsv"
cplan c5a -- "${BATCH[@]}" CI_PLAN_ESCALATION='selection input: catalog/x' CI_PLAN_REUSED_FILE="$T/every.tsv"
{ [ "$RC" = 0 ] && [ "$(grep -c . "$T/c5a.list")" = 4 ] && [ "$(out c5a reuse)" = "off: would run nothing" ] \
  && [ "$(out c5a reused)" = 0 ] && [ ! -s "$T/c5a.rd/reused.tsv" ]; } \
  && ok "C5 shard: full list, reuse=off: would run nothing" || bad "C5a rc=$RC list=$(lst c5a) go=$(cat "$T/c5a.go" 2>&1)"
# Every non-always suite of the head green in ctx2, and a selection with no
# always suite in it (the real test-impact's answer minus tests/sa.sh): the
# lookup hits the whole list, so the helper itself refuses.
printf '%s\n' tests/s1.sh tests/s2.sh tests/s3.sh > "$T/three"
( cd "$R" && . bin/lib/suite-fingerprint.sh && sfp_compute HEAD "$T/three" "$T/head.fp" ) || bad "C5 cannot fingerprint the head"
printf 'tests/s1.sh\tok\t4\ntests/s2.sh\tok\t5\ntests/s3.sh\tok\t6\n' > "$T/head.res"
( cd "$R" && SUITE_LEDGER_URL=https://ledger.test SUITE_LEDGER_TOKEN=tok "$R/bin/suite-reuse.sh" record \
    --repo scratch/repo --ctx ctx2 --run-key HEADKEY --fingerprints "$T/head.fp" --results "$T/head.res" ) > /dev/null 2>&1
cat > "$T/no-always.sh" <<EOF
#!/bin/bash
"$R/bin/test-impact.sh" "\$@" || exit
o=; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && o="\$2"; shift; done
grep -vxF tests/sa.sh "\$o" > "\$o.x" && mv "\$o.x" "\$o"
EOF
chmod +x "$T/no-always.sh"
cplan c5b -- "${BATCH[@]}" "${CREDS[@]}" CI_PLAN_REUSE=1 CI_REUSE_CTX=ctx2 CI_PLAN_ESCALATION='selection input: catalog/x' \
  CI_PLAN_IMPACT="$T/no-always.sh"
{ [ "$RC" = 0 ] && [ "$(lst c5b)" = "tests/s1.sh tests/s2.sh tests/s3.sh" ] && [ "$(out c5b reuse)" = "off: would run nothing" ] \
  && [ "$(out c5b reused)" = 0 ]; } && ok "C5 plan: full list, reuse=off: would run nothing" \
  || bad "C5b rc=$RC list=$(lst c5b) go=$(cat "$T/c5b.go" 2>&1) out=$(cat "$T/c5b.out" "$T/c5b.err")"

# ── C6: a push-to-main corpus reuses; a quarantined suite never ────────────
cplan c6 -- CI_EVENT=push CI_ACTOR=someone "${CREDS[@]}" CI_PLAN_REUSE=1
{ [ "$RC" = 0 ] && [ "$(lst c6)" = "tests/s1.sh tests/s2.sh tests/sa.sh" ] && [ "$(out c6 reused)" = 1 ]; } \
  && ok "C6 push corpus: s3 reused" || bad "C6 rc=$RC list=$(lst c6) go=$(cat "$T/c6.go" 2>&1) err=$(cat "$T/c6.err")"
cplan c6q -- CI_EVENT=push CI_ACTOR=someone "${CREDS[@]}" CI_PLAN_REUSE=1 CI_QUARANTINE=tests/s3.sh
{ [ "$RC" = 0 ] && grep -qxF tests/s3.sh "$T/c6q.list" && [ "$(out c6q reused)" = 0 ] && [ ! -s "$T/c6q.rd/reused.tsv" ]; } \
  && ok "C6 a quarantined suite runs, never reused" || bad "C6q list=$(lst c6q) go=$(cat "$T/c6q.go" 2>&1)"

# ── C7: an unreadable reused list is a refusal ─────────────────────────────
cplan c7 -- "${BATCH[@]}" CI_PLAN_ESCALATION='selection input: catalog/x' CI_PLAN_REUSED_FILE=/nonexistent/reused.tsv
{ [ "$RC" = 2 ] && grep -qF 'CI_PLAN_REUSED_FILE' "$T/c7.err" && [ ! -s "$T/c7.list" ]; } \
  && ok "C7 rc 2, stderr names CI_PLAN_REUSED_FILE" || bad "C7 rc=$RC err=$(cat "$T/c7.err")"

# ── C8: the corpus=0 path writes the reuse outputs too ─────────────────────
TREE=$(G rev-parse 'HEAD^{tree}')
cat > "$T/fake-gh" <<EOF
#!/bin/bash
case "\$*" in
  *"actions/runs?event=pull_request&status=success"*)
    printf '{"workflow_runs":[{"name":"Harness CI","conclusion":"success","head_sha":"b1","head_branch":"mergify/merge-queue/x"}]}\n' ;;
  *"git/commits/b1"*) echo "$TREE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fake-gh"
cplan c8 -- CI_EVENT=push CI_ACTOR='mergify[bot]' CI_PLAN_GH="$T/fake-gh" CI_SHA=s0 CI_PLAN_SETTLE_S=0 \
  CI_PLAN_MAIN_HEAD_CMD="echo s0" "${CREDS[@]}" CI_PLAN_REUSE=1
{ [ "$RC" = 0 ] && [ "$(out c8 corpus)" = 0 ] && [ "$(out c8 reused)" = 0 ] && [ "$(out c8 saved_s)" = 0 ] \
  && [ "$(out c8 reuse)" = - ]; } && ok "C8 corpus=0 writes reused=0 saved_s=0 reuse=-" \
  || bad "C8 rc=$RC go=$(cat "$T/c8.go" 2>&1) err=$(cat "$T/c8.err")"

echo "ci-plan-reuse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
