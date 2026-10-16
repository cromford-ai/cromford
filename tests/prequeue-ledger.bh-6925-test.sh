#!/bin/bash
# tests/prequeue-ledger.bh-6925-test.sh — the prequeue gate joins the suite
# ledger (BH-6925): .github/workflows/prequeue-gate.yml hands
# bin/test-impact-gate.sh the ledger token on a file descriptor, class ci and
# the batch's ctx; the gate keeps the token out of every suite's environment,
# records a ci row only from a traced run, and records a trace hit as fail; and
# the merge-queue batch then skips a suite prequeue already passed.
#
# The real gate, selector, tracer and helper in a committed scratch repo, and
# SUITE_REUSE_CURL pointed at worker.fetch over node:sqlite (the BH-5367
# pattern). The stub forwards the helper's own SUITE_LEDGER_TOKEN as the
# x-suite-ledger-token header and logs whether it had one.
#
#   P1  SUITE_LEDGER_TOKEN_FD=9 9<<<token: the ledger calls carry the token; a
#       suite's env has no SUITE_LEDGER_TOKEN(_FD), no token value, no fd 9
#   P2  SUITE_LEDGER_TOKEN in the env: the same
#   P3  class ci on the local runner: it reads (reuse works) but records
#       nothing: `suite-reuse: record skipped (class ci records traced runs only)`
#   P4  traced: a suite with a trace hit is written fail (the real tracer's hit,
#       and a tracer that marks the verdict dirty but exits 0)
#   P5  a bad class, ctx or token fd, and no credential: one `suite-reuse: off`
#       line, every suite runs, the rc is the gate's own
#   P6  no new env: class builder, ctx = the runner, as before
#   P7  the workflow: the secret only in the credential step, the verdict
#       step's five keys, the batch's ctx expression, the token file removed
#       before any fetch or suite; and the verdict step run dry with a stub gate
#       (the gate gets fd 9 and no token in its env) and with the real gate (a
#       prequeue-<run_id>-<attempt> ci row). An untrusted dispatch (actor or
#       triggering actor not vars.PREQUEUE_LEDGER_ACTOR, or the variable unset)
#       gets an empty credential file: the gate gets no fd and no token
#   P8  the batch fixture: S passed on main+A in prequeue; the batch tree
#       main+A+B (B touches nothing S reads) reuses S; main+A+B' (B' edits a
#       file S reads) runs it
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/prequeue-gate.yml"
CI_WF="$DIR/.github/workflows/harness-ci.yml"
NOW=2026-10-15T00:00:00Z
TOK=tok-fixture-1
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
finish() { echo "prequeue-ledger.bh-6925: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 \
   || ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "prequeue-ledger.bh-6925: SKIPPED — needs git, jq and node with node:sqlite"
  finish
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { bad "PyYAML missing on a CI runner"; finish; }
  echo "prequeue-ledger.bh-6925: SKIPPED — PyYAML missing on this dev machine"; finish
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write > /dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json the worker imports"
fi
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

unset ImageOS ImageVersion SUITE_IMAGE_ID HARNESS_SECRET JOBS_URL SUITE_REUSE GITHUB_ACTIONS SUITE_LEDGER_TOKEN \
  SUITE_LEDGER_TOKEN_FD SUITE_REUSE_RUN_KEY SUITE_REUSE_CLASS SUITE_REUSE_CTX TEST_IMPACT_GATE_FRESH_MAIN \
  HARNESS_CHECKOUT CI_BATCH_ESCALATE_TSV SUITE_LEDGER_URL

# ── the stub ledger ─────────────────────────────────────────────────────────
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
echo "\$1 \$2 \$4 token=\${SUITE_LEDGER_TOKEN:-none}" >> "$T/calls"
exec node "$T/driver.mjs" "$DIR" "\${LEDGER_DB:-$T/ledger.db}" "\$@" 2>/dev/null
EOF
chmod +x "$T/stub.sh"
q() { node "$T/driver.mjs" "$DIR" "${LEDGER_DB:-$T/ledger.db}" Q "$1" 2>/dev/null; }

# ── a seed tree: the real lanes and four fixture suites ─────────────────────
# seed <dir> — s-test reads bin/s-input.sh and bin/s-lib.sh; env-test dumps its
# environment and open fds; leak-test hands bash -c a redirect to an absolute
# path outside the temp roots (a trace hit; nothing is written).
COUNT='n=$(cat "$MARK_DIR/$1" 2>/dev/null || echo 0); echo $((n + 1)) > "$MARK_DIR/$1"'
seed() {
  local d="$1" s
  mkdir -p "$d/tests/lib" "$d/catalog" "$d/docs"
  for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/suite-reuse.sh bin/fast-lints.sh \
           bin/test-trace-safety.sh; do
    scratch_install_closure "$s" "$d" > /dev/null || { echo "cannot install $s"; exit 1; }
  done
  printf '# scratch lib\n' > "$d/tests/lib/scratch.sh"
  printf '#!/bin/bash\necho s-input v1\n' > "$d/bin/s-input.sh"
  printf '#!/bin/bash\necho s-lib v1\n' > "$d/bin/s-lib.sh"
  printf '#!/bin/bash\necho e-input v1\n' > "$d/bin/e-input.sh"
  printf '# docs\n' > "$d/docs/b.md"
  cat > "$d/tests/s-test.sh" <<SH
#!/bin/bash
ROOTD=\$(cd "\$(dirname "\$0")/.." && pwd)
bash "\$ROOTD/bin/s-input.sh" > /dev/null; bash "\$ROOTD/bin/s-lib.sh" > /dev/null
set -- s; $COUNT
echo "s: 1 passed, 0 failed"
exit "\${S_RC:-0}"
SH
  cat > "$d/tests/env-test.sh" <<SH
#!/bin/bash
ROOTD=\$(cd "\$(dirname "\$0")/.." && pwd)
bash "\$ROOTD/bin/e-input.sh" > /dev/null
set -- env; $COUNT
env > "\$MARK_DIR/env.\$(cat "\$MARK_DIR/env")"
for n in 3 4 5 6 7 8 9; do timeout 2 cat "/proc/self/fd/\$n" 2>/dev/null; done > "\$MARK_DIR/fds.\$(cat "\$MARK_DIR/env")"
ls /proc/self/fd > "\$MARK_DIR/fdn.\$(cat "\$MARK_DIR/env")" 2>/dev/null
echo "env: 1 passed, 0 failed"
SH
  cat > "$d/tests/always-test.sh" <<SH
#!/bin/bash
set -- always; $COUNT
echo "always: 1 passed, 0 failed"
SH
  printf 'tests/always-test.sh\n' > "$d/catalog/test-impact-always.txt"
  chmod +x "$d"/tests/*.sh "$d"/bin/*.sh
}

R="$T/repo"; seed "$R"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
B0=$(git -C "$R" rev-parse HEAD)
printf '# c1\n' >> "$R/bin/s-input.sh"; printf '# c1\n' >> "$R/bin/e-input.sh"
G commit -qam c1 || exit 1
G remote add origin https://github.com/acme/widget.git
commit() { printf '# %s\n' "$2" >> "$R/$1"; G add -A && G commit -qm "$2" || { echo "commit failed: $2"; exit 1; }; }

export SUITE_REUSE_CURL="$T/stub.sh" SUITE_REUSE_REPO=acme/widget
export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
: > "$T/fast.empty"; : > "$T/calls"; mkdir -p "$T/mark"
CI_ENV=(SUITE_LEDGER_URL=https://ledger.invalid SUITE_REUSE_CLASS=ci SUITE_REUSE_CTX=ubuntu-latest)

# gate <tag> <runner> [VAR=value ...] — the real gate in $R, run key <tag>.
# A non-empty FD9 (a shell variable, never exported) is handed to it on fd 9,
# or on fd 7 when FD9_NO=7.
# Output $T/<tag>.out, rc GRC.
gate() {
  local tag="$1" runner="$2"; shift 2
  local extra=(); [ "$runner" = traced ] && extra=(--trace-hits "$T/$tag.hits")
  if [ -n "$FD9" ] && [ "${FD9_NO:-9}" = 7 ]; then
    ( cd "$R" && env "$@" MARK_DIR="$T/mark" SUITE_REUSE_RUN_KEY="$tag" \
        bin/test-impact-gate.sh --base "$B0" --runner "$runner" "${extra[@]}" 7<<<"$FD9" ) > "$T/$tag.out" 2>&1
  elif [ -n "$FD9" ]; then
    ( cd "$R" && env "$@" MARK_DIR="$T/mark" SUITE_REUSE_RUN_KEY="$tag" \
        bin/test-impact-gate.sh --base "$B0" --runner "$runner" "${extra[@]}" 9<<<"$FD9" ) > "$T/$tag.out" 2>&1
  else
    ( cd "$R" && env "$@" MARK_DIR="$T/mark" SUITE_REUSE_RUN_KEY="$tag" \
        bin/test-impact-gate.sh --base "$B0" --runner "$runner" "${extra[@]}" ) > "$T/$tag.out" 2>&1
  fi
  GRC=$?
}
FD9=""
marks() { cat "$T/mark/$1" 2>/dev/null || echo 0; }
rows() { q "SELECT suite, status, class, ctx FROM suite_results WHERE run_id='$1' ORDER BY suite"; }
# envclean <n> — env-test's n-th dump has no token name and no token value, and
# nothing it can read on fds 3-9 holds the token. (Its fd 9 is open: the gate's
# segment loop reads its list on 9, so the check is the content, not the number.)
envclean() {
  local e="$T/mark/env.$1" f="$T/mark/fds.$1"
  [ -s "$e" ] && [ -e "$f" ] && ! grep -q '^SUITE_LEDGER_TOKEN' "$e" && ! grep -qF "$TOK" "$e" && ! grep -qF "$TOK" "$f"
}

# ── P1: the token on fd 9 ───────────────────────────────────────────────────
: > "$T/calls"
FD9="$TOK"; gate p1 traced "${CI_ENV[@]}" SUITE_LEDGER_TOKEN_FD=9; FD9=""
[ "$GRC" = 0 ] && ok "P1 rc 0" || { bad "P1 rc=$GRC: $(tail -6 "$T/p1.out")"; finish; }
{ grep -q "^POST /api/suite-results/lookup ci token=$TOK$" "$T/calls" && grep -q "^PUT /api/suite-results ci token=$TOK$" "$T/calls"; } \
  && ok "P1 the lookup and the write carry the token from fd 9" || bad "P1 calls: $(cat "$T/calls")"
[ "$(rows p1 | jq -r '.[] | select(.suite == "tests/s-test.sh") | .status + " " + .class')" = "ok ci" ] \
  && ok "P1 the worker accepted it: an ok ci row" || bad "P1 rows: $(rows p1)"
envclean "$(marks env)" && ok "P1 the suite's env has no SUITE_LEDGER_TOKEN(_FD) and no token; no fd it can read holds it" \
  || bad "P1 env dump: $(grep -E 'SUITE_LEDGER|tok-' "$T/mark/env.$(marks env)" "$T/mark/fds.$(marks env)")"
# The same on fd 7, which no loop of the gate reuses: the gate itself must close it.
commit bin/e-input.sh p1b; : > "$T/calls"
FD9="$TOK"; FD9_NO=7 gate p1b traced "${CI_ENV[@]}" SUITE_LEDGER_TOKEN_FD=7; FD9=""
{ [ "$GRC" = 0 ] && grep -q "^PUT /api/suite-results ci token=$TOK$" "$T/calls" && envclean "$(marks env)" \
  && [ -s "$T/mark/fdn.$(marks env)" ] && ! grep -qx 7 "$T/mark/fdn.$(marks env)"; } \
  && ok "P1 fd 7: the ledger gets the token; the suite cannot read it and has no fd 7" \
  || bad "P1 fd 7 rc=$GRC calls $(cat "$T/calls") fds $(tr '\n' ' ' < "$T/mark/fdn.$(marks env)") dump: $(grep -E 'SUITE_LEDGER|tok-' "$T/mark/env.$(marks env)" "$T/mark/fds.$(marks env)")"

# ── P2: the token in the env ────────────────────────────────────────────────
commit bin/s-input.sh p2; : > "$T/calls"
gate p2 traced "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK"
{ [ "$GRC" = 0 ] && grep -q "^PUT /api/suite-results ci token=$TOK$" "$T/calls"; } && ok "P2 the env token reaches the ledger calls" \
  || bad "P2 rc=$GRC calls: $(cat "$T/calls")"
envclean "$(marks env)" && ok "P2 the suite's env has no SUITE_LEDGER_TOKEN and no token value" \
  || bad "P2 env dump: $(grep -E 'SUITE_LEDGER|tok-' "$T/mark/env.$(marks env)")"

# ── P3: class ci on an untraced runner reads, never writes ─────────────────
commit bin/s-input.sh p3
gate p3-traced traced "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK"
s0=$(marks s)
gate p3-local local "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK"
{ [ "$GRC" = 0 ] && [ "$(marks s)" = "$s0" ] && grep -qE '^impact-gate: reused tests/s-test.sh from p3-traced ' "$T/p3-local.out"; } \
  && ok "P3 class ci + local reads the traced green" || bad "P3 read: rc=$GRC marks $(marks s) vs $s0: $(grep reuse "$T/p3-local.out")"
grep -qxF 'suite-reuse: record skipped (class ci records traced runs only)' "$T/p3-local.out" \
  && ok "P3 it says record skipped" || bad "P3 no skip line: $(grep 'suite-reuse' "$T/p3-local.out")"
commit bin/s-input.sh p3b
gate p3-local2 local "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK"
{ [ "$(marks s)" = $((s0 + 1)) ] && [ "$(rows p3-local2)" = '[]' ] && [ "$(rows p3-local)" = '[]' ] \
  && [ "$(q "SELECT COUNT(*) AS n FROM suite_reuse_runs WHERE run_key LIKE 'p3-local%'")" = '[{"n":0}]' ]; } \
  && ok "P3 a suite it ran is not written, no run row" || bad "P3 write: marks $(marks s) rows $(rows p3-local2) runs $(q 'SELECT run_key FROM suite_reuse_runs')"

# ── P4: a trace hit is written fail ─────────────────────────────────────────
# In a copy, so the leak never reaches the later cases' selection.
cp -a "$R" "$T/r4a"; RS="$R"; R="$T/r4a"
cat > "$R/tests/leak-test.sh" <<'SH'
#!/bin/bash
bash -c 'exit 0; echo x >> /var/lib/bh-6925-fixture-nowhere/x.log'
echo "leak: 1 passed, 0 failed"
SH
chmod +x "$R/tests/leak-test.sh"
commit tests/leak-test.sh p4
gate p4 traced "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK"
{ grep -qxF tests/leak-test.sh "$T/p4.hits" \
  && [ "$(rows p4 | jq -r '.[] | select(.suite == "tests/leak-test.sh") | .status')" = fail ]; } \
  && ok "P4 the real tracer's hit: leak-test written fail" || bad "P4 hits '$(cat "$T/p4.hits" 2>/dev/null)' rows $(rows p4) out: $(tail -5 "$T/p4.out")"
# A tracer that marks a verdict dirty and still exits 0: the hit decides.
R="$T/r4b"; cp -a "$RS" "$R"
cat > "$R/bin/test-trace-safety.sh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in --gate) ;; --only-file) f=$2; shift ;; --verdict) v=$2; shift ;; *) root=$1 ;; esac
  shift
done
cd "$root" || exit 2
bash bin/test-suite-run.sh --only-file "$f" tests tests/mc > /dev/null 2>&1
t=clean; grep -qx tests/s-test.sh "$f" && t=dirty
echo "trace=$t" > "$v"
exit 0
SH
G add -A && G commit -qm "dirty-but-0 tracer" || exit 1
gate p4b traced "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK"
{ grep -qxF tests/s-test.sh "$T/p4b.hits" && grep -qxF 'impact-gate: done tests/s-test.sh rc=0' "$T/p4b.out" \
  && [ "$(rows p4b | jq -r '.[] | select(.suite == "tests/s-test.sh") | .status')" = fail ] \
  && [ "$(rows p4b | jq -r '.[] | select(.suite == "tests/env-test.sh") | .status')" = ok ]; } \
  && ok "P4 a hit with rc 0 is written fail; a clean rc 0 stays ok" || bad "P4b rows $(rows p4b) out: $(tail -5 "$T/p4b.out")"
R="$RS"

# ── P5: a bad input is off, never a fallback ────────────────────────────────
commit bin/s-input.sh p5
p5() { # p5 <tag> <want off reason> [VAR=value ...]
  local tag="$1" why="$2"; shift 2
  local s0; s0=$(marks s); : > "$T/calls"
  gate "$tag" traced "$@"
  { [ "$GRC" = "${P5_RC:-0}" ] && [ "$(marks s)" = $((s0 + 1)) ] && [ "$(grep -c '^suite-reuse: off (' "$T/$tag.out")" = 1 ] \
    && grep -qxF "suite-reuse: off ($why)" "$T/$tag.out" && [ ! -s "$T/calls" ] && [ "$(rows "$tag")" = '[]' ]; } \
    && ok "P5 $tag: one 'off ($why)' line, the suite runs, rc ${P5_RC:-0}, no ledger call" \
    || bad "P5 $tag rc=$GRC marks $(marks s) vs $s0 calls $(wc -l < "$T/calls"): $(grep 'suite-reuse' "$T/$tag.out")"
}
p5 p5-bogus "bad SUITE_REUSE_CLASS" "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK" SUITE_REUSE_CLASS=bogus
p5 p5-upper "bad SUITE_REUSE_CLASS" "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK" SUITE_REUSE_CLASS=CI
p5 p5-ctx "bad SUITE_REUSE_CTX" "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK" "SUITE_REUSE_CTX=a b"
p5 p5-fd12 "bad SUITE_LEDGER_TOKEN_FD" "${CI_ENV[@]}" SUITE_LEDGER_TOKEN_FD=12
p5 p5-fdx "bad SUITE_LEDGER_TOKEN_FD" "${CI_ENV[@]}" SUITE_LEDGER_TOKEN_FD=x
p5 p5-fd8 "ledger token fd unreadable" "${CI_ENV[@]}" SUITE_LEDGER_TOKEN_FD=8
p5 p5-nocred "no credential" "${CI_ENV[@]}"
P5_RC=1 p5 p5-red "bad SUITE_REUSE_CLASS" "${CI_ENV[@]}" SUITE_LEDGER_TOKEN="$TOK" SUITE_REUSE_CLASS=bogus S_RC=1
grep -q 'FAILED (rc 1)' "$T/p5-red.out" && ok "P5 a red suite is still FAILED (rc 1) with reuse off" || bad "P5 red verdict: $(grep 'impact-gate: ran' "$T/p5-red.out")"

# ── P6: no new env is today's builder call ──────────────────────────────────
: > "$T/calls"
gate p6 local JOBS_URL=https://jobs.invalid HARNESS_SECRET=x
{ [ "$GRC" = 0 ] && grep -q '^POST /api/suite-results/lookup builder ' "$T/calls" \
  && [ "$(rows p6 | jq -r '.[] | select(.suite == "tests/s-test.sh") | .class + " " + .ctx')" = "builder local" ]; } \
  && ok "P6 no SUITE_REUSE_CLASS/CTX: class builder, ctx local" || bad "P6 rc=$GRC calls $(cat "$T/calls") rows $(rows p6)"

# ── P7: the workflow ────────────────────────────────────────────────────────
python3 - "$WF" "$CI_WF" "$T/w" > "$T/p7.py.out" 2>&1 <<'PY'
import sys, os, re, yaml
wf_path, ci_path, out = sys.argv[1:4]
text = open(wf_path).read()
wf = yaml.safe_load(text)
ci = yaml.safe_load(open(ci_path).read())
os.makedirs(out, exist_ok=True)
steps = wf["jobs"]["gate"]["steps"]
problems = []
cred = [i for i, s in enumerate(steps) if str(s.get("name", "")).startswith("ledger credential")]
ver = [i for i, s in enumerate(steps) if s.get("id") == "verdict"]
if len(cred) != 1 or len(ver) != 1 or cred[0] > ver[0]:
    problems.append(f"want one credential step before verdict: cred={cred} verdict={ver}")
else:
    c, v = steps[cred[0]], steps[ver[0]]
    if (c.get("env") or {}).get("SUITE_LEDGER_TOKEN") != "${{ secrets.SUITE_LEDGER_TOKEN }}":
        problems.append("credential step env SUITE_LEDGER_TOKEN is not the secret")
    ce = c.get("env") or {}
    for k, w in {"PQ_LEDGER_ACTOR": "${{ vars.PREQUEUE_LEDGER_ACTOR }}", "PQ_ACTOR": "${{ github.actor }}",
                 "PQ_TRIGGERING_ACTOR": "${{ github.triggering_actor }}"}.items():
        if ce.get(k) != w: problems.append(f"credential env {k}={ce.get(k)!r}, want {w!r}")
    if text.count("secrets.SUITE_LEDGER_TOKEN") != 1:
        problems.append(f"secrets.SUITE_LEDGER_TOKEN appears {text.count('secrets.SUITE_LEDGER_TOKEN')} times")
    ve = v.get("env") or {}
    want = {"SUITE_LEDGER_URL": "${{ vars.SUITE_LEDGER_URL }}", "SUITE_REUSE_CLASS": "ci",
            "SUITE_REUSE_REPO": "${{ github.repository }}",
            "SUITE_REUSE_RUN_KEY": "prequeue-${{ github.run_id }}-${{ github.run_attempt }}"}
    for k, w in want.items():
        if ve.get(k) != w: problems.append(f"verdict env {k}={ve.get(k)!r}, want {w!r}")
    ci_ctx = {s.get("env", {}).get("CI_REUSE_CTX") for j in ci["jobs"].values() for s in (j.get("steps") or [])} - {None}
    if len(ci_ctx) != 1 or ve.get("SUITE_REUSE_CTX") not in ci_ctx:
        problems.append(f"verdict SUITE_REUSE_CTX {ve.get('SUITE_REUSE_CTX')!r} vs harness-ci CI_REUSE_CTX {ci_ctx}")
    if any("SUITE_LEDGER_TOKEN" in k for k in ve): problems.append("the verdict step env names the token")
    run = v["run"]
    rm = run.find('rm -f "$RUNNER_TEMP/.suite-ledger"')
    firsts = [run.find("pq_fetch -q"), run.find("bash bin/prequeue-invariants.sh"), run.find("bin/test-impact-gate.sh"),
              run.find("bin/test-suite-run.sh")]
    if rm < 0 or any(f < 0 or f < rm for f in firsts):
        problems.append(f"token file removal at {rm}, first fetch/invariants/gate/suite at {firsts}")
    open(out + "/cred.sh", "w").write(c["run"])
    open(out + "/run.sh", "w").write(run)
for p in problems: print("PROBLEM", p)
sys.exit(1 if problems else 0)
PY
[ $? = 0 ] && ok "P7 the workflow shape: secret in the credential step only, five verdict keys, the batch's ctx, removal first" \
  || bad "P7 shape: $(cat "$T/p7.py.out")"
bash -n "$T/w/run.sh" 2>/dev/null && bash -n "$T/w/cred.sh" 2>/dev/null && ok "P7 both run blocks parse" || bad "P7 bash -n"

# mkorigin <seed> — a bare origin for the seed's history: main = its HEAD~1,
# pull/41/head = its HEAD. Prints "<main> <head>".
mkorigin() {
  local s="$1" m h
  m=$(git -C "$s" rev-parse HEAD~1) && h=$(git -C "$s" rev-parse HEAD) || return 1
  git init -q --bare "$s.git" && git -C "$s" push -q "$s.git" "$m:refs/heads/main" "$h:refs/pull/41/head" || return 1
  echo "$m $h"
}
# dry <case> <origin> <main> <head> <token> [VAR=value ...] — the credential step
# then the verdict step, in a fresh clone at <main>, with the workflow's env.
# The dispatch is the hub's (actor = triggering actor = the variable) unless
# DRY_LA / DRY_A / DRY_TA set the variable, the actor or the triggering actor.
dry() {
  local c="$1" o="$2" m="$3" h="$4" tok="$5"; shift 5
  git clone -q "$o" "$T/wd-$c" 2>/dev/null; git -C "$T/wd-$c" checkout -q "$m" 2>/dev/null
  mkdir -p "$T/rt-$c" "$T/mark-$c"
  ( cd "$T/wd-$c" && env SUITE_LEDGER_TOKEN="$tok" PQ_LEDGER_ACTOR="${DRY_LA-hub[bot]}" PQ_ACTOR="${DRY_A-hub[bot]}" \
      PQ_TRIGGERING_ACTOR="${DRY_TA-hub[bot]}" RUNNER_TEMP="$T/rt-$c" bash "$T/w/cred.sh" ) > "$T/cred-$c" 2>&1
  ls -l "$T/rt-$c/.suite-ledger" > "$T/credmode-$c" 2>&1
  ( cd "$T/wd-$c" && env PQ_PR=41 PQ_HEAD="$h" PQ_MAIN="$m" PQ_SUITES_IN="" PQ_INVARIANTS_IN="" PQ_LEARNED_IN="" PQ_TRACE_IN=1 \
      SUITE_LEDGER_URL=https://ledger.invalid SUITE_REUSE_CLASS=ci SUITE_REUSE_CTX=ubuntu-latest \
      SUITE_REUSE_REPO=acme/widget SUITE_REUSE_RUN_KEY="prequeue-$c-1" RUNNER_TEMP="$T/rt-$c" \
      MARK_DIR="$T/mark-$c" "$@" bash "$T/w/run.sh" ) > "$T/out-$c" 2>&1
  echo "rc=$?" >> "$T/out-$c"
}
verdict() {
  awk '/^::stop-commands::/ { tok = substr($0, 18); off = 1; next }
       off && $0 == "::" tok "::" { off = 0; next }
       !off { print }' "$T/out-$1" | sed -n 's/^::notice title=prequeue-verdict:://p'
}

# P7 dry, stub gate: what the gate process is handed.
SG="$T/sg"; mkdir -p "$SG/tests"
scratch_install_closure bin/test-suite-run.sh "$SG" > /dev/null || bad "P7 setup: install test-suite-run"
cat > "$SG/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
env > "$MARK_DIR/gate.env"
{ [ -e "$RUNNER_TEMP/.suite-ledger" ] && echo present || echo absent; } > "$MARK_DIR/gate.file"
if [ -n "${SUITE_LEDGER_TOKEN_FD:-}" ]; then IFS= read -r t <&"$SUITE_LEDGER_TOKEN_FD"; printf '%s' "$t" > "$MARK_DIR/gate.fd"; fi
exit 0
SH
chmod +x "$SG/bin/test-impact-gate.sh"
git -C "$SG" init -q && git -C "$SG" add -A && git -C "$SG" -c user.email=t@example.com -c user.name=t commit -qm base \
  && echo y > "$SG/y.txt" && git -C "$SG" add -A && git -C "$SG" -c user.email=t@example.com -c user.name=t commit -qm head \
  || bad "P7 setup: stub seed"
read -r SM SH_ <<<"$(mkorigin "$SG")"
dry p7s "$SG.git" "$SM" "$SH_" "$TOK"
{ [ "$(verdict p7s)" = "green main=$SM head=$SH_ suites=" ] && [ "$(cat "$T/mark-p7s/gate.fd" 2>/dev/null)" = "$TOK" ] \
  && grep -qx SUITE_LEDGER_TOKEN_FD=9 "$T/mark-p7s/gate.env" && ! grep -qF "$TOK" "$T/mark-p7s/gate.env" \
  && [ "$(cat "$T/mark-p7s/gate.file")" = absent ]; } \
  && ok "P7 dry: the gate reads the token on fd 9, its env has no token, the file is gone" \
  || bad "P7 dry stub: verdict '$(verdict p7s)' fd '$(cat "$T/mark-p7s/gate.fd" 2>/dev/null)' file $(cat "$T/mark-p7s/gate.file" 2>/dev/null) env: $(grep -E 'SUITE_LEDGER|tok-' "$T/mark-p7s/gate.env" 2>/dev/null) out: $(tail -4 "$T/out-p7s")"
grep -q -- '-rw-------' "$T/credmode-p7s" && ok "P7 the credential file is 0600" || bad "P7 mode: $(cat "$T/credmode-p7s")"
grep -qF "$TOK" "$T/out-p7s" "$T/cred-p7s" && bad "P7 the token is in the step output" || ok "P7 the token is never printed"
dry p7n "$SG.git" "$SM" "$SH_" ""
{ [ "$(verdict p7n)" = "green main=$SM head=$SH_ suites=" ] && ! grep -q '^SUITE_LEDGER_TOKEN_FD=' "$T/mark-p7n/gate.env" \
  && [ ! -e "$T/mark-p7n/gate.fd" ]; } && ok "P7 dry, no secret: no fd is handed to the gate" \
  || bad "P7 no secret: verdict '$(verdict p7n)' env $(grep SUITE_LEDGER "$T/mark-p7n/gate.env" 2>/dev/null)"
# An untrusted dispatch: the secret is set, but the token never reaches the gate.
# untrusted <case> <why> — DRY_* already set by the caller.
untrusted() {
  local c="$1" why="$2"
  dry "$c" "$SG.git" "$SM" "$SH_" "$TOK"
  { [ "$(verdict "$c")" = "green main=$SM head=$SH_ suites=" ] && ! grep -q '^SUITE_LEDGER_TOKEN_FD=' "$T/mark-$c/gate.env" \
    && [ ! -e "$T/mark-$c/gate.fd" ] && ! grep -qF "$TOK" "$T/mark-$c/gate.env" "$T/out-$c" "$T/cred-$c" \
    && grep -q '^suite-reuse: credential withheld (' "$T/cred-$c" && [ "$(cat "$T/mark-$c/gate.file")" = absent ]; } \
    && ok "P7 untrusted dispatch ($why): no fd, no token anywhere, one withheld line" \
    || bad "P7 untrusted ($why): verdict '$(verdict "$c")' fd '$(cat "$T/mark-$c/gate.fd" 2>/dev/null)' cred '$(cat "$T/cred-$c")' env $(grep SUITE_LEDGER "$T/mark-$c/gate.env" 2>/dev/null)"
}
DRY_A=someone untrusted p7u-actor "another actor"
DRY_TA=someone untrusted p7u-rerun "a re-run by another triggering actor"
DRY_LA="" untrusted p7u-unset "PREQUEUE_LEDGER_ACTOR unset"
DRY_LA="" DRY_A="" DRY_TA="" untrusted p7u-empty "all three empty"

# ── P8: the batch fixture, on the real gate under the real workflow step ────
# Seed: main M; PR A edits bin/s-input.sh (S reads it). Prequeue runs on M+A.
S8="$T/s8"; seed "$S8"
G8() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$S8" -c user.email=t@example.com -c user.name=t "$@"; }
G8 init -q -b main && G8 add -A && G8 commit -qm M || bad "P8 setup: M"
printf '# A\n' >> "$S8/bin/s-input.sh"; G8 commit -qam A || bad "P8 setup: A"
read -r M8 A8 <<<"$(mkorigin "$S8")"
export LEDGER_DB="$T/p8.db"; : > "$T/calls"
dry p8 "$S8.git" "$M8" "$A8" "$TOK" HARNESS="$T/empty"
[ "$(verdict p8)" = "green main=$M8 head=$A8 suites=" ] && ok "P8 the prequeue run on M+A is green" \
  || { bad "P8 prequeue verdict '$(verdict p8)': $(tail -12 "$T/out-p8")"; finish; }
{ [ "$(marks_in() { cat "$T/mark-p8/s" 2>/dev/null || echo 0; }; marks_in)" = 1 ] \
  && [ "$(rows prequeue-p8-1 | jq -r '.[] | select(.suite == "tests/s-test.sh") | .status + " " + .class + " " + .ctx')" = "ok ci ubuntu-latest" ]; } \
  && ok "P8 prequeue ran S and wrote an ok ci row, run key prequeue-<run>-<attempt>" || bad "P8 rows $(rows prequeue-p8-1) calls $(cat "$T/calls")"
# The batch tree: M+A+B, B edits docs/b.md only; the control B' edits bin/s-lib.sh.
G8 checkout -q -b b "$M8" && printf '# B\n' >> "$S8/docs/b.md" && G8 commit -qam B || bad "P8 setup: B"
G8 checkout -q -b bp "$M8" && printf "# B'\n" >> "$S8/bin/s-lib.sh" && G8 commit -qam "B'" || bad "P8 setup: B'"
# batchplan <tag> <branch> — merge A then <branch> onto M in a clone, then the call bin/ci-plan.sh makes.
batchplan() {
  local tag="$1" br="$2" w="$T/batch-$1"
  git clone -q "$S8" "$w" && git -C "$w" checkout -q "$M8" \
    && git -C "$w" -c user.email=t@example.com -c user.name=t merge -q --no-edit "$A8" \
    && git -C "$w" -c user.email=t@example.com -c user.name=t merge -q --no-edit "origin/$br" || { echo "merge failed" > "$T/$tag.out"; return 1; }
  printf 'tests/s-test.sh\ntests/always-test.sh\n' > "$T/$tag.in"
  ( cd "$w" && HARNESS_CHECKOUT="$w" SUITE_LEDGER_URL=https://ledger.invalid SUITE_LEDGER_TOKEN="$TOK" \
      bin/suite-reuse.sh plan --class ci --repo acme/widget --ctx ubuntu-latest --suites "$T/$tag.in" \
      --run "$T/$tag.run" --reused "$T/$tag.reused" --fingerprints "$T/$tag.fp" ) > "$T/$tag.out" 2>&1
}
batchplan p8b b
{ [ "$(cut -f1,2 "$T/p8b.reused")" = "tests/s-test.sh$(printf '\t')prequeue-p8-1" ] && ! grep -qxF tests/s-test.sh "$T/p8b.run"; } \
  && ok "P8 the batch M+A+B reuses S from the prequeue run" || bad "P8 batch: reused '$(cat "$T/p8b.reused")' run '$(cat "$T/p8b.run")' out: $(cat "$T/p8b.out")"
batchplan p8c bp
{ grep -qxF tests/s-test.sh "$T/p8c.run" && [ ! -s "$T/p8c.reused" ]; } \
  && ok "P8 control: M+A+B' (B' edits a file S reads) runs S" || bad "P8 control: reused '$(cat "$T/p8c.reused")' out: $(cat "$T/p8c.out")"
unset LEDGER_DB

finish
