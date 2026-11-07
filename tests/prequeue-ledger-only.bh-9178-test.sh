#!/bin/bash
# tests/prequeue-ledger-only.bh-9178-test.sh — BH-9178 (C2 of #9063): the
# prequeue workflow's impact step reads the suite ledger only. The 17
# invariants still run; bin/prequeue-ledger.sh selects the gate's list
# (bin/test-impact-gate.sh --runner plan), asks the ledger about it through
# bin/suite-reuse.sh plan, and runs no suite. The hub sends `-f impact=ledger`
# behind the knob MC_PREQUEUE_IMPACT_LEDGER (default 1).
#
#   L1  4 selected, 1 ci green at its fingerprint: rc 0, green=1 unverified=3, no suite ran
#   L2  every fingerprinted suite green: green=3, the always suite (never
#       reused) unverified=1; a helper `off (would run nothing)`: green=4
#   L3  no credential: rc 0, ledger=off:no credential, green=0
#   L4  a helper red in the list: rc 1, --failed names it, red=1
#   L5  a red outside the list and a malformed red line: rc 0, red=0, reds_bad=1
#   L6  a helper that rejects --reds: 2 calls, rc 0, reds=unsupported
#   L7  an empty list or a plan runner rc 2: rc 2; a plan runner rc 125: rc 125
#   L8  520 selected: all 520 asked, in 2 lookups
#   L9  the token on fd 9: the helper's env has it, the plan runner's has neither name
#   W1  impact empty: the gate runs --runner local as today, no prequeue-ledger notice
#   W2  impact=ledger: the script runs once, the gate only with --runner plan; green
#   W3  impact Ledger / run / "ledger " / 1: could-not-run why=bad-impact, no fetch
#   W4  invariants first; an invariant red + a ledger red: why=invariant:<ids>;
#       the notice equals the script's summary file
#   W5  the token reaches the helper only, through fd 9; an untrusted dispatch gets none
#   W6  a ledger red: red suites=tests/a.sh why=ledger-red; pq_parse_verdict reads it
#   W7  script missing: could-not-run why=no-ledger-script; rc 2: no-selection;
#       unverified=5: green and the notice says unverified=5
#   H1  knob unset, MC_H carries the script: pq_impact_args prints -f impact=ledger
#   H2  knob 0, MC_H without the script, MC_H unset: nothing
#   H3  MC_PREQUEUE_GATE stays 1 with no row; the knob fragment is registered, default 1
#   H4  pq_dispatch: empty suites ends -f impact=ledger; named suites carry no impact=
#   H5  pq_group_flush carries -f impact=ledger; the group workflow passes impact through
#
# The real gate, selector and helper in a committed scratch repo, the helper's
# SUITE_REUSE_CURL pointed at worker.fetch over node:sqlite (the BH-6925
# pattern), or a stub helper where a case needs a shape the worker cannot give.
# The workflow's verdict step is extracted with PyYAML and run as the runner
# runs it. 0 network calls.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-ledger-only.bh-9178-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/prequeue-gate.yml"
GROUP_WF="$DIR/.github/workflows/prequeue-group-gate.yml"
SCRIPT="$DIR/bin/prequeue-ledger.sh"
NOW=2026-11-06T00:00:00Z
TOK=tok-fixture-1
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
finish() { echo "prequeue-ledger-only.bh-9178: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 \
   || ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1 || ! command -v flock > /dev/null 2>&1; then
  echo "prequeue-ledger-only.bh-9178: SKIPPED — needs git, jq, flock and node with node:sqlite"
  finish
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { bad "PyYAML missing on a CI runner"; finish; }
  echo "prequeue-ledger-only.bh-9178: SKIPPED — PyYAML missing on this dev machine"; finish
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write > /dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json the worker imports"
fi
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$SCRIPT" ] || bad "setup: bin/prequeue-ledger.sh is missing"

unset ImageOS ImageVersion HARNESS_SECRET JOBS_URL SUITE_REUSE GITHUB_ACTIONS SUITE_LEDGER_TOKEN \
  SUITE_LEDGER_TOKEN_FD SUITE_REUSE_RUN_KEY SUITE_REUSE_CLASS SUITE_REUSE_CTX TEST_IMPACT_GATE_FRESH_MAIN \
  HARNESS_CHECKOUT CI_BATCH_ESCALATE_TSV SUITE_LEDGER_URL MC_PREQUEUE_IMPACT_LEDGER MC_PREQUEUE_GATE
export SUITE_IMAGE_ID=fixture-image

# ── the stub ledger: worker.fetch over node:sqlite ──────────────────────────
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
  ...(cls === 'ci' ? { 'x-suite-ledger-token': process.env.SUITE_LEDGER_TOKEN || '' } : { authorization: 'Bearer SECRET' }) };
const res = await worker.fetch(new Request('https://jobs.test' + path, { method, headers, body: readFileSync(bodyf) }),
  { DB: d1(db), HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: 'tok-fixture-1' });
process.stdout.write((await res.text()) + '\n' + res.status + '\n');
EOF
cat > "$T/stub.sh" <<EOF
#!/bin/bash
echo "\$1 \$2 \$4 token=\${SUITE_LEDGER_TOKEN:-none}" >> "$T/calls"
exec node "$T/driver.mjs" "$DIR" "$T/ledger.db" "\$@" 2>/dev/null
EOF
chmod +x "$T/stub.sh"

# ── L: bin/prequeue-ledger.sh in a committed scratch repo ───────────────────
# seed <dir> — the real gate, selector and helper; three suites that read
# bin/x-input.sh and one always suite (the fingerprint needs an always set),
# each counting its runs in $MARK_DIR.
COUNT='n=$(cat "$MARK_DIR/$1" 2>/dev/null || echo 0); echo $((n + 1)) > "$MARK_DIR/$1"'
seed() {
  local d="$1" s
  mkdir -p "$d/tests/lib" "$d/catalog" "$d/docs"
  for s in bin/prequeue-ledger.sh bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/suite-reuse.sh \
           bin/fast-lints.sh; do
    [ -f "$DIR/$s" ] || continue
    scratch_install_closure "$s" "$d" > /dev/null || { echo "cannot install $s"; exit 1; }
  done
  printf '# scratch lib\n' > "$d/tests/lib/scratch.sh"
  printf '#!/bin/bash\necho x-input v1\n' > "$d/bin/x-input.sh"
  printf '# docs\n' > "$d/docs/only.md"
  printf 'tests/always-test.sh\n' > "$d/catalog/test-impact-always.txt"
  for s in a b c always; do
    cat > "$d/tests/$s-test.sh" <<SH
#!/bin/bash
ROOTD=\$(cd "\$(dirname "\$0")/.." && pwd)
bash "\$ROOTD/bin/x-input.sh" > /dev/null
set -- $s; $COUNT
echo "$s: 1 passed, 0 failed"
SH
  done
  chmod +x "$d"/tests/*.sh "$d"/bin/*.sh
}
R="$T/repo"; seed "$R"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "${GR:-$R}" -c user.email=t@example.com -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm base || { echo "cannot build the scratch checkout"; exit 1; }
B0=$(git -C "$R" rev-parse HEAD)
printf ': c1\n' >> "$R/bin/x-input.sh"
G commit -qam c1 || exit 1
G remote add origin https://github.com/acme/widget.git

export SUITE_REUSE_CURL="$T/stub.sh"
export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
: > "$T/fast.empty"; : > "$T/calls"; mkdir -p "$T/mark"
CI_ENV=(SUITE_LEDGER_URL=https://ledger.invalid SUITE_REUSE_CLASS=ci SUITE_REUSE_CTX=ubuntu-latest)

# pql <tag> <repo dir> [VAR=value ...] — the script in <repo dir>, base B0. A
# non-empty FD9 (a shell variable, never exported) is handed to it on fd 9.
# Output $T/<tag>.out, summary $T/<tag>.sum, failed $T/<tag>.failed, rc PRC.
pql() {
  local tag="$1" d="$2"; shift 2
  mkdir -p "$T/mark-$tag"
  if [ -n "$FD9" ]; then
    ( cd "$d" && env "$@" MARK_DIR="$T/mark-$tag" bash bin/prequeue-ledger.sh --base "$B0" --head HEAD \
        --failed "$T/$tag.failed" --summary "$T/$tag.sum" 9<<<"$FD9" ) > "$T/$tag.out" 2>&1
  else
    ( cd "$d" && env "$@" MARK_DIR="$T/mark-$tag" bash bin/prequeue-ledger.sh --base "$B0" --head HEAD \
        --failed "$T/$tag.failed" --summary "$T/$tag.sum" ) > "$T/$tag.out" 2>&1
  fi
  PRC=$?
}
FD9=""
sum() { cat "$T/$1.sum" 2>/dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
noruns() { [ -z "$(ls -A "$T/mark-$1" 2>/dev/null)" ]; }
# green <repo dir> <repo slug> <suite>... — a ci ok row for each suite at its
# fingerprint at HEAD, written by the real helper's record through the worker.
green() {
  local d="$1" slug="$2"; shift 2
  printf '%s\n' "$@" > "$T/g.list"
  ( cd "$d" && bash -c '. bin/lib/suite-fingerprint.sh && sfp_compute HEAD "$1" "$2"' _ "$T/g.list" "$T/g.fp" ) \
    || { bad "setup: sfp_compute"; return 1; }
  printf '%s\tok\t3\n' "$@" > "$T/g.res"
  ( cd "$d" && SUITE_LEDGER_URL=https://ledger.invalid SUITE_LEDGER_TOKEN="$TOK" bin/suite-reuse.sh record --repo "$slug" \
      --ctx ubuntu-latest --run-key "seed-$slug" --fingerprints "$T/g.fp" --results "$T/g.res" ) > "$T/g.out" 2>&1
}

if [ -f "$R/bin/prequeue-ledger.sh" ]; then
  # L1
  green "$R" acme/l1 tests/b-test.sh
  FD9="$TOK"; pql l1 "$R" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l1 SUITE_LEDGER_TOKEN_FD=9; FD9=""
  { [ "$PRC" = 0 ] && has "$(sum l1)" "selected=4 green=1 red=0 unverified=3" && has "$(sum l1)" "ledger=on" && noruns l1 \
    && grep -qxF 'prequeue-ledger: selected 4, green 1, red 0, unverified 3 (left to the batch)' "$T/l1.out"; } \
    && ok "L1 one ci green of 4: rc 0, green=1 unverified=3, no suite ran" \
    || bad "L1 rc=$PRC sum '$(sum l1)' marks '$(ls "$T/mark-l1")' out: $(tail -8 "$T/l1.out")"
  [ ! -s "$T/l1.failed" ] && ok "L1 --failed is empty" || bad "L1 failed: $(cat "$T/l1.failed")"

  # L2
  green "$R" acme/l2 tests/a-test.sh tests/b-test.sh tests/c-test.sh tests/always-test.sh
  pql l2 "$R" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l2 SUITE_LEDGER_TOKEN="$TOK"
  { [ "$PRC" = 0 ] && has "$(sum l2)" "selected=4 green=3 red=0 unverified=1" && noruns l2; } \
    && ok "L2 every fingerprinted suite green: green=3, the always suite unverified" || bad "L2 rc=$PRC sum '$(sum l2)' out: $(tail -6 "$T/l2.out")"

  # L3
  pql l3 "$R" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l2
  { [ "$PRC" = 0 ] && has "$(sum l3)" "selected=4 green=0 red=0 unverified=4" && has "$(sum l3)" "ledger=off:no credential" && noruns l3; } \
    && ok "L3 no credential: rc 0, ledger=off:no credential, green=0" || bad "L3 rc=$PRC sum '$(sum l3)' out: $(tail -6 "$T/l3.out")"
fi

# A copy of R with a stub helper (and optionally a stub gate) that logs its
# argv and env. STUB_REDS is written to --reds when the helper is given one;
# STUB_NOREDS=1 rejects --reds the way today's helper does.
stubrepo() {
  local d="$1"
  cp -a "$R" "$d"
  cat > "$d/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$MARK_DIR/../helper.argv.$(basename "$MARK_DIR")"
printf 'token=%s fd=%s\n' "${SUITE_LEDGER_TOKEN:-none}" "${SUITE_LEDGER_TOKEN_FD:-none}" >> "$MARK_DIR/../helper.env.$(basename "$MARK_DIR")"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --suites) in=$2; shift ;; --run) run=$2; shift ;; --reused) re=$2; shift ;; --fingerprints) fp=$2; shift ;;
    --reds) [ "${STUB_NOREDS:-0}" = 1 ] && { echo "suite-reuse: plan: unknown argument --reds" >&2; exit 2; }; reds=$2; shift ;;
    *) shift ;;
  esac
  shift
done
cp "$in" "$run"; : > "$re"; : > "$fp"
[ -n "${reds:-}" ] && printf '%b' "${STUB_REDS:-}" > "$reds"
if [ -n "${STUB_OFF:-}" ]; then echo "suite-reuse: off ($STUB_OFF)"
else echo "suite-reuse: ran $(grep -c . "$in") reused 0 of $(grep -c . "$in") (saved ~0s)"; fi
exit 0
SH
  chmod +x "$d/bin/suite-reuse.sh"
}
stubgate() {
  cat > "$1/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$MARK_DIR/../gate.argv.$(basename "$MARK_DIR")"
printf 'token=%s fd=%s\n' "${SUITE_LEDGER_TOKEN:-none}" "${SUITE_LEDGER_TOKEN_FD:-none}" >> "$MARK_DIR/../gate.env.$(basename "$MARK_DIR")"
while [ $# -gt 0 ]; do case "$1" in --list) l=$2; shift ;; esac; shift; done
[ -n "${l:-}" ] && { if [ -n "${STUB_N:-}" ]; then seq -f 'tests/n%g-test.sh' 1 "$STUB_N"; else printf '%s\n' tests/a-test.sh tests/b-test.sh tests/c-test.sh; fi; } > "$l"
exit "${STUB_GATE_RC:-0}"
SH
  chmod +x "$1/bin/test-impact-gate.sh"
}

if [ -f "$R/bin/prequeue-ledger.sh" ]; then
  S="$T/rs"; stubrepo "$S"
  # L4
  pql l4 "$S" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l4 SUITE_LEDGER_TOKEN="$TOK" STUB_REDS='tests/b-test.sh\tfail\t9\n'
  { [ "$PRC" = 1 ] && [ "$(cat "$T/l4.failed")" = tests/b-test.sh ] && has "$(sum l4)" "selected=4 green=0 red=1 unverified=3" \
    && has "$(sum l4)" "reds=on" && noruns l4; } \
    && ok "L4 a helper red in the list: rc 1, --failed names it, red=1" || bad "L4 rc=$PRC failed '$(cat "$T/l4.failed")' sum '$(sum l4)' out: $(tail -5 "$T/l4.out")"
  # L2b, L3b: the helper's off line decides the green count.
  pql l2b "$S" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l2b SUITE_LEDGER_TOKEN="$TOK" STUB_OFF='would run nothing'
  { [ "$PRC" = 0 ] && has "$(sum l2b)" "selected=4 green=4 red=0 unverified=0 ledger=on"; } \
    && ok "L2 the helper would run nothing: every suite green" || bad "L2b rc=$PRC sum '$(sum l2b)'"
  pql l3b "$S" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l3b SUITE_LEDGER_TOKEN="$TOK" STUB_OFF='ledger unreachable'
  { [ "$PRC" = 0 ] && has "$(sum l3b)" "selected=4 green=0 red=0 unverified=4 ledger=off:ledger unreachable"; } \
    && ok "L3 any other off reason: green 0, ledger=off:<why>" || bad "L3b rc=$PRC sum '$(sum l3b)'"
  # L5
  pql l5 "$S" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l5 SUITE_LEDGER_TOKEN="$TOK" \
    STUB_REDS='tests/zz-test.sh\tfail\n../tests/a-test.sh\tfail\ntests/a-test.sh.bak\tfail\n'
  { [ "$PRC" = 0 ] && [ ! -s "$T/l5.failed" ] && has "$(sum l5)" "red=0" && has "$(sum l5)" "reds_bad=2"; } \
    && ok "L5 a red outside the list is ignored; malformed red lines are counted bad" || bad "L5 rc=$PRC failed '$(cat "$T/l5.failed")' sum '$(sum l5)'"
  # L6
  pql l6 "$S" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l6 SUITE_LEDGER_TOKEN="$TOK" STUB_NOREDS=1 STUB_REDS='tests/b-test.sh\tfail\n'
  { [ "$PRC" = 0 ] && [ "$(grep -c . "$T/helper.argv.mark-l6")" = 2 ] && grep -q -- '--reds' <<<"$(head -1 "$T/helper.argv.mark-l6")" \
    && ! grep -q -- '--reds' <<<"$(tail -1 "$T/helper.argv.mark-l6")" && has "$(sum l6)" "reds=unsupported" && has "$(sum l6)" "red=0"; } \
    && ok "L6 a helper that rejects --reds: 2 calls, the second without it, reds=unsupported" \
    || bad "L6 rc=$PRC argv $(cat "$T/helper.argv.mark-l6" 2>/dev/null) sum '$(sum l6)'"
  grep -q -- '--rerun-red' "$T"/helper.argv.mark-l* && bad "L6 --rerun-red is never passed" || ok "L6 --rerun-red is never passed"
  # L7 (stub gate): rc 125 from the plan runner.
  S7="$T/rs7"; stubrepo "$S7"; stubgate "$S7"
  pql l7b "$S7" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l7 STUB_GATE_RC=125
  [ "$PRC" = 125 ] && ok "L7 a plan runner rc 125: rc 125" || bad "L7b rc=$PRC out: $(tail -5 "$T/l7b.out")"
  pql l7c "$S7" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l7 STUB_GATE_RC=2
  [ "$PRC" = 2 ] && [ ! -s "$T/helper.argv.mark-l7c" ] && ok "L7 a plan runner rc 2: rc 2, no ledger call" || bad "L7c rc=$PRC"
  pql l7d "$S7" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l7 STUB_N=0
  [ "$PRC" = 2 ] && [ ! -s "$T/helper.argv.mark-l7d" ] && ok "L7 an empty list: rc 2, no ledger call" || bad "L7d rc=$PRC"
  grep -q -- '--runner plan' "$T/gate.argv.mark-l7b" && ok "L7 the gate is asked only for a plan" || bad "L7 gate argv: $(cat "$T/gate.argv.mark-l7b")"
  # L9: the token on fd 9 reaches the helper only.
  FD9="$TOK"; pql l9 "$S7" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l9 SUITE_LEDGER_TOKEN_FD=9; FD9=""
  { [ "$PRC" = 0 ] && grep -qx "token=$TOK fd=none" "$T/helper.env.mark-l9" && grep -qx 'token=none fd=none' "$T/gate.env.mark-l9" \
    && ! grep -qF "$TOK" "$T/l9.out" "$T/l9.sum"; } \
    && ok "L9 fd 9: the helper's env has the token, the plan runner's has neither name, nothing prints it" \
    || bad "L9 rc=$PRC helper '$(cat "$T/helper.env.mark-l9" 2>/dev/null)' gate '$(cat "$T/gate.env.mark-l9" 2>/dev/null)'"
  pql l9b "$S7" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l9 SUITE_LEDGER_TOKEN="$TOK"
  grep -qx 'token=none fd=none' "$T/gate.env.mark-l9b" && grep -qx "token=$TOK fd=none" "$T/helper.env.mark-l9b" \
    && ok "L9 env token: the plan runner's env does not have it" || bad "L9b gate '$(cat "$T/gate.env.mark-l9b" 2>/dev/null)'"

  # L8: 520 suites, the real helper, 2 lookups.
  S8="$T/rs8"; cp -a "$R" "$S8"; stubgate "$S8"
  for i in $(seq 1 520); do printf '#!/bin/bash\necho ok\n' > "$S8/tests/n$i-test.sh"; done
  GR="$S8"; G add -A && G commit -qm many; GR=""
  : > "$T/calls"
  pql l8 "$S8" "${CI_ENV[@]}" SUITE_REUSE_REPO=acme/l8 SUITE_LEDGER_TOKEN="$TOK" STUB_N=520
  { [ "$PRC" = 0 ] && has "$(sum l8)" "selected=520 green=0 red=0 unverified=520" && has "$(sum l8)" "ledger=on" \
    && [ "$(grep -c '^POST /api/suite-results/lookup ci ' "$T/calls")" = 2 ]; } \
    && ok "L8 520 selected: all asked, 2 lookups" || bad "L8 rc=$PRC sum '$(sum l8)' calls $(grep -c lookup "$T/calls") out: $(tail -5 "$T/l8.out")"
fi

# ── W: the workflow's verdict step, run as the runner runs it ───────────────
python3 - "$WF" "$T/w" > "$T/w.py.out" 2>&1 <<'PY'
import sys, os, yaml
wf = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]; os.makedirs(out, exist_ok=True)
on = wf.get("on", wf.get(True))
steps = wf["jobs"]["gate"]["steps"]
cred = [s for s in steps if str(s.get("name", "")).startswith("ledger credential")][0]
ver = [s for s in steps if s.get("id") == "verdict"][0]
open(out + "/cred.sh", "w").write(cred["run"])
open(out + "/run.sh", "w").write(ver["run"])
for t in ("workflow_dispatch", "workflow_call"):
    i = on[t]["inputs"].get("impact")
    print(f"{t} impact={None if i is None else (bool(i.get('required')), i.get('default'), i.get('type'))}")
print("env", (ver.get("env") or {}).get("PQ_IMPACT_IN"))
PY
[ $? = 0 ] && [ "$(grep -c "impact=(False, '', 'string')" "$T/w.py.out")" = 2 ] && grep -qx 'env ${{ inputs.impact }}' "$T/w.py.out" \
  && ok "W the input impact on both triggers (optional, '' default) reaches the step as PQ_IMPACT_IN" || bad "W shape: $(cat "$T/w.py.out")"

# mkorigin <seed> — a bare origin: main = HEAD~1, pull/41/head = HEAD. Prints "<main> <head>".
mkorigin() {
  local s="$1" m h
  m=$(git -C "$s" rev-parse HEAD~1) && h=$(git -C "$s" rev-parse HEAD) || return 1
  git init -q --bare "$s.git" && git -C "$s" push -q "$s.git" "$m:refs/heads/main" "$h:refs/pull/41/head" || return 1
  echo "$m $h"
}
# dry <case> <origin> <main> <head> <token> [VAR=value ...] — the credential
# step then the verdict step, in a fresh clone at <main>, with the workflow's env.
dry() {
  local c="$1" o="$2" m="$3" h="$4" tok="$5"; shift 5
  git clone -q "$o" "$T/wd-$c" 2>/dev/null; git -C "$T/wd-$c" checkout -q "$m" 2>/dev/null
  mkdir -p "$T/rt-$c" "$T/wm/$c"
  ( cd "$T/wd-$c" && env SUITE_LEDGER_TOKEN="$tok" PQ_LEDGER_ACTOR="${DRY_LA-hub[bot]}" PQ_ACTOR="${DRY_A-hub[bot]}" \
      PQ_TRIGGERING_ACTOR="hub[bot]" RUNNER_TEMP="$T/rt-$c" bash "$T/w/cred.sh" ) > "$T/cred-$c" 2>&1
  ( cd "$T/wd-$c" && env PQ_PR=41 PQ_HEAD="$h" PQ_MAIN="$m" PQ_SUITES_IN="" PQ_INVARIANTS_IN="" PQ_LEARNED_IN="" PQ_TRACE_IN="" \
      PQ_IMPACT_IN="" SUITE_LEDGER_URL=https://ledger.invalid SUITE_REUSE_CLASS=ci SUITE_REUSE_CTX=ubuntu-latest \
      SUITE_REUSE_REPO=acme/widget SUITE_REUSE_RUN_KEY="prequeue-$c-1" RUNNER_TEMP="$T/rt-$c" \
      MARK_DIR="$T/wm/$c" "$@" bash "$T/w/run.sh" ) > "$T/out-$c" 2>&1
  echo "rc=$?" >> "$T/out-$c"
}
# outside <case> <title> — a notice printed while workflow commands are on.
outside() {
  awk '/^::stop-commands::/ { tok = substr($0, 18); off = 1; next }
       off && $0 == "::" tok "::" { off = 0; next }
       !off { print }' "$T/out-$1" | sed -n "s/^::notice title=$2:://p"
}
verdict() { outside "$1" prequeue-verdict; }
wsum() { cat "$T/rt-$1/ledger.sum" 2>/dev/null; }

# The workflow tree: the REAL bin/prequeue-ledger.sh; a stub gate and a stub
# helper (logging argv and env); a stub invariants runner (STUB_INV_RED=1 = one
# red invariant) and main's invariant catalog.
SG="$T/sg"; mkdir -p "$SG/tests" "$SG/catalog" "$SG/bin"
[ -f "$SCRIPT" ] && { scratch_install_closure bin/prequeue-ledger.sh "$SG" > /dev/null || bad "W setup: install the script"; }
stubrepo_w() {
  local d="$1"
  cat > "$d/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$MARK_DIR/gate.argv"
env > "$MARK_DIR/gate.env.$(grep -c . "$MARK_DIR/gate.argv")"
l=""; f=""
while [ $# -gt 0 ]; do case "$1" in --list) l=$2; shift ;; --failed) f=$2; shift ;; esac; shift; done
[ -n "$l" ] && { if [ -n "${STUB_N:-}" ]; then seq -f 'tests/n%g.sh' 1 "$STUB_N"; else printf '%s\n' tests/a.sh tests/b.sh; fi; } > "$l"
exit "${STUB_GATE_RC:-0}"
SH
  cat > "$d/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$MARK_DIR/helper.argv"
printf 'token=%s fd=%s\n' "${SUITE_LEDGER_TOKEN:-none}" "${SUITE_LEDGER_TOKEN_FD:-none}" >> "$MARK_DIR/helper.env"
shift
while [ $# -gt 0 ]; do
  case "$1" in --suites) in=$2; shift ;; --run) run=$2; shift ;; --reused) re=$2; shift ;; --fingerprints) fp=$2; shift ;;
    --reds) reds=$2; shift ;; *) shift ;; esac
  shift
done
cp "$in" "$run"; : > "$re"; : > "$fp"
[ -n "${reds:-}" ] && printf '%b' "${STUB_REDS:-}" > "$reds"
exit 0
SH
  cat > "$d/bin/prequeue-invariants.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$MARK_DIR/inv.argv"
while [ $# -gt 0 ]; do case "$1" in --out) o=$2; shift ;; esac; shift; done
mkdir -p "$o/fail"; : > "$o/timings.tsv"; : > "$o/suites.txt"
if [ "${STUB_INV_RED:-0}" = 1 ]; then echo inv1 > "$o/failed.txt"; echo "prequeue-invariants: total 1 ran, 1 red"; exit 1; fi
: > "$o/failed.txt"; echo "prequeue-invariants: total 1 ran, 0 red"; exit 0
SH
  printf 'inv1\t5\ttests/inv1.sh\n' > "$d/catalog/prequeue-invariants.tsv"
  chmod +x "$d"/bin/*.sh
}
stubrepo_w "$SG"
GR="$SG"; G init -q && G add -A && G commit -qm base && echo y > "$SG/y.txt" && G add -A && G commit -qm head || bad "W setup: seed"; GR=""
read -r SM SH_ <<<"$(mkorigin "$SG")"
# The same tree with no bin/prequeue-ledger.sh on main or head.
SN="$T/sn"; mkdir -p "$SN/bin" "$SN/catalog"; stubrepo_w "$SN"
GR="$SN"; G init -q && G add -A && G commit -qm base && echo y > "$SN/y.txt" && G add -A && G commit -qm head || bad "W setup: seed2"; GR=""
read -r NM NH <<<"$(mkorigin "$SN")"

# W1
dry w1 "$SG.git" "$SM" "$SH_" "$TOK"
{ [ "$(verdict w1)" = "green main=$SM head=$SH_ suites=" ] && [ "$(grep -c . "$T/wm/w1/gate.argv")" = 1 ] \
  && grep -q -- '--runner local' "$T/wm/w1/gate.argv" && ! grep -q -- '--runner plan' "$T/wm/w1/gate.argv" \
  && [ ! -e "$T/wm/w1/helper.argv" ] && [ -z "$(outside w1 prequeue-ledger)" ] && [ ! -e "$T/rt-w1/ledger.sum" ]; } \
  && ok "W1 impact empty: the gate runs --runner local once, as today; no ledger step, no notice" \
  || bad "W1 verdict '$(verdict w1)' gate '$(cat "$T/wm/w1/gate.argv" 2>/dev/null)' out: $(tail -4 "$T/out-w1")"

# W2
dry w2 "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger
{ [ "$(verdict w2)" = "green main=$SM head=$SH_ suites=" ] && [ "$(grep -c . "$T/wm/w2/gate.argv")" = 1 ] \
  && grep -q -- '--runner plan' "$T/wm/w2/gate.argv" && ! grep -q -- '--runner local' "$T/wm/w2/gate.argv" \
  && [ "$(grep -c . "$T/wm/w2/helper.argv")" = 1 ] && grep -q -- '--class ci --repo acme/widget --ctx ubuntu-latest' "$T/wm/w2/helper.argv" \
  && [ -s "$T/wm/w2/inv.argv" ]; } \
  && ok "W2 impact=ledger: the invariants run, the gate only plans, the ledger is asked once; green" \
  || bad "W2 verdict '$(verdict w2)' gate '$(cat "$T/wm/w2/gate.argv" 2>/dev/null)' helper '$(cat "$T/wm/w2/helper.argv" 2>/dev/null)' out: $(tail -6 "$T/out-w2")"
[ "$(outside w2 prequeue-ledger)" = "$(wsum w2)" ] && has "$(wsum w2)" "selected=2 green=0 red=0 unverified=2" \
  && ok "W2 the prequeue-ledger notice is the script's summary" || bad "W2 notice '$(outside w2 prequeue-ledger)' sum '$(wsum w2)'"

# W3
for v in Ledger run 'ledger ' 1; do
  c="w3-${v// /_}"
  dry "$c" "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN="$v"
  { [ "$(verdict "$c")" = "could-not-run main=$SM head=$SH_ suites= why=bad-impact" ] && [ ! -e "$T/wm/$c/gate.argv" ] \
    && [ ! -e "$T/wm/$c/inv.argv" ] && [ -z "$(git -C "$T/wd-$c" rev-parse -q --verify FETCH_HEAD 2>/dev/null)" ]; } \
    && ok "W3 impact '$v': could-not-run why=bad-impact, no fetch, nothing ran" \
    || bad "W3 '$v' verdict '$(verdict "$c")' out: $(tail -4 "$T/out-$c")"
done

# W4
dry w4 "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger STUB_INV_RED=1 STUB_REDS='tests/a.sh\tfail\n'
{ [ "$(verdict w4)" = "red main=$SM head=$SH_ suites=tests/inv1.sh,tests/a.sh why=invariant:inv1" ] \
  && [ -n "$(wsum w4)" ] && [ "$(outside w4 prequeue-ledger)" = "$(wsum w4)" ] && has "$(wsum w4)" "red=1"; } \
  && ok "W4 an invariant red leads a ledger red; the notice equals the summary file" \
  || bad "W4 verdict '$(verdict w4)' notice '$(outside w4 prequeue-ledger)' sum '$(wsum w4)'"
[ "$(awk 'FNR == 1 { print FILENAME }' "$T/wm/w4/inv.argv" "$T/wm/w4/gate.argv" 2>/dev/null | wc -l)" = 2 ] \
  && [ "$(stat -c %Y "$T/wm/w4/inv.argv")" -le "$(stat -c %Y "$T/wm/w4/gate.argv")" ] && ok "W4 the invariants ran, before the plan" || bad "W4 inv/gate order"

# W5
dry w5 "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger
{ grep -qx "token=$TOK fd=none" "$T/wm/w5/helper.env" && ! grep -q '^SUITE_LEDGER_TOKEN' "$T/wm/w5/gate.env.1" \
  && ! grep -qF "$TOK" "$T/wm/w5/gate.env.1" "$T/out-w5" && [ ! -e "$T/rt-w5/.suite-ledger" ]; } \
  && ok "W5 the token reaches the helper (fd 9 to the script), never the plan runner's env or the output" \
  || bad "W5 helper '$(cat "$T/wm/w5/helper.env" 2>/dev/null)' gate env: $(grep -E 'SUITE_LEDGER|tok-' "$T/wm/w5/gate.env.1" 2>/dev/null)"
DRY_A=someone dry w5u "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger
{ grep -qx 'token=none fd=none' "$T/wm/w5u/helper.env" && [ "$(verdict w5u)" = "green main=$SM head=$SH_ suites=" ] \
  && ! grep -qF "$TOK" "$T/out-w5u" "$T/cred-w5u"; } \
  && ok "W5 an untrusted dispatch: no token, still a verdict" || bad "W5u helper '$(cat "$T/wm/w5u/helper.env" 2>/dev/null)' verdict '$(verdict w5u)'"

# W6
dry w6 "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger STUB_REDS='tests/a.sh\tfail\n'
W6V=$(verdict w6)
[ "$W6V" = "red main=$SM head=$SH_ suites=tests/a.sh why=ledger-red" ] && ok "W6 a ledger red: red suites=tests/a.sh why=ledger-red" \
  || bad "W6 verdict '$W6V' out: $(tail -5 "$T/out-w6")"
W6P=$( mc_log() { :; }; . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1; pq_parse_verdict "$W6V" "$SH_" "$SM" )
[ "$W6P" = "red tests/a.sh ledger-red" ] && ok "W6 pq_parse_verdict reads it: red tests/a.sh ledger-red" || bad "W6 parse '$W6P'"

# W7
dry w7 "$SN.git" "$NM" "$NH" "$TOK" PQ_IMPACT_IN=ledger
{ [ "$(verdict w7)" = "could-not-run main=$NM head=$NH suites= why=no-ledger-script" ] && [ ! -e "$T/wm/w7/gate.argv" ]; } \
  && ok "W7 the script missing in the merged tree: could-not-run why=no-ledger-script, nothing run" \
  || bad "W7 verdict '$(verdict w7)' gate '$(cat "$T/wm/w7/gate.argv" 2>/dev/null)'"
dry w7b "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger STUB_GATE_RC=2
[ "$(verdict w7b)" = "no-selection main=$SM head=$SH_ suites=" ] && ok "W7 script rc 2: no-selection" || bad "W7b verdict '$(verdict w7b)'"
dry w7c "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger STUB_N=5
{ [ "$(verdict w7c)" = "green main=$SM head=$SH_ suites=" ] && has "$(outside w7c prequeue-ledger)" "unverified=5"; } \
  && ok "W7 5 unverified: green, the notice says unverified=5" || bad "W7c verdict '$(verdict w7c)' notice '$(outside w7c prequeue-ledger)'"
dry w7d "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger STUB_GATE_RC=125
[ "$(verdict w7d)" = "could-not-run main=$SM head=$SH_ suites= why=rc-125" ] && ok "W7 a plan runner rc 125: could-not-run why=rc-125" || bad "W7d verdict '$(verdict w7d)'"
dry w7e "$SG.git" "$SM" "$SH_" "$TOK" PQ_IMPACT_IN=ledger PQ_SUITES_IN=tests/a.sh
[ ! -e "$T/wm/w7e/helper.argv" ] && ! grep -q -- '--runner' "$T/wm/w7e/gate.argv" 2>/dev/null \
  && ok "W7 named suites win over impact=ledger (the suites branch, no ledger)" || bad "W7e helper '$(cat "$T/wm/w7e/helper.argv" 2>/dev/null)'"

# ── H: the hub hook ─────────────────────────────────────────────────────────
PS_=example-org/demo-os; PH=$(printf 'a%.0s' $(seq 40)); M2=$(printf 'c%.0s' $(seq 40))
export PS_ PH M2 DIR
# pq <name> <body> — the real bin/lib/mc-prequeue.sh and its hooks, gh stubbed.
pq() {
  ( export MC_STATE_DIR="$T/pq-$1/state" GH_ARGV="$T/pq-$1/gh.argv" W="$T/pq-$1"
    [ "${PQ_H-x}" = "" ] && unset MC_H || export MC_H="${PQ_H:-$T/pq-$1/h}"
    mkdir -p "$MC_STATE_DIR" "$W/bin" "$T/pq-$1/h/locks"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_ARGV"\n' > "$W/bin/gh"; chmod +x "$W/bin/gh"
    PATH="$W/bin:$PATH"
    mc_rest_var() { printf -v "$1" '{}'; return 0; }
    mc_log() { printf '%s\n' "$*" >> "$W/log"; }; mc_use_token() { :; }; mc_safe_name() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
    . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 9
    eval "$2" ) > "$T/pq-$1.out" 2>&1
}
HH="$T/hh"; mkdir -p "$HH/bin" "$HH/locks"; : > "$HH/bin/prequeue-ledger.sh"
HN="$T/hn"; mkdir -p "$HN/bin" "$HN/locks"
PQ_H="$HH" pq h1 'pq_impact_args'
[ "$(cat "$T/pq-h1.out")" = "-f impact=ledger" ] && ok "H1 knob unset, the script in MC_H: -f impact=ledger" || bad "H1 got '$(cat "$T/pq-h1.out")'"
PQ_H="$HH" MC_PREQUEUE_IMPACT_LEDGER=0 pq h2a 'pq_impact_args; echo "rc=$?"'
PQ_H="$HN" pq h2b 'pq_impact_args; echo "rc=$?"'
PQ_H="" pq h2c 'pq_impact_args; echo "rc=$?"'
{ [ "$(cat "$T/pq-h2a.out")" = rc=0 ] && [ "$(cat "$T/pq-h2b.out")" = rc=0 ] && [ "$(cat "$T/pq-h2c.out")" = rc=0 ]; } \
  && ok "H2 knob 0, MC_H without the script, MC_H unset: nothing, rc 0" \
  || bad "H2 got '$(cat "$T/pq-h2a.out")' '$(cat "$T/pq-h2b.out")' '$(cat "$T/pq-h2c.out")'"
PQ_H="$HH" MC_PREQUEUE_IMPACT_LEDGER=x pq h2d 'pq_impact_args'
[ "$(cat "$T/pq-h2d.out")" = "-f impact=ledger" ] && ok "H2 a bad knob value falls back to 1" || bad "H2d got '$(cat "$T/pq-h2d.out")'"
PQ_H="$HH" pq h3 'pq_knob MC_PREQUEUE_GATE'
KF="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_IMPACT_LEDGER.json"
{ [ "$(cat "$T/pq-h3.out")" = 1 ] && [ "$(jq -r '"\(.env) \(.default) \(.min) \(.max) \(.read_in)"' "$KF" 2>/dev/null)" \
    = "MC_PREQUEUE_IMPACT_LEDGER 1 0 1 bin/lib/mc-prequeue.d/impact-ledger.sh" ]; } \
  && ok "H3 MC_PREQUEUE_GATE stays 1; the knob fragment is registered, default 1" || bad "H3 gate '$(cat "$T/pq-h3.out")' fragment: $(cat "$KF" 2>/dev/null)"
PQ_H="$HH" pq h4 'pq_dispatch "$PS_" 7 "$PH" "$M2"'
A=$(cat "$T/pq-h4/gh.argv" 2>/dev/null)
[[ "$A" == "workflow run prequeue-gate.yml -R $PS_ --ref main -f pr=7 -f head=$PH -f main=$M2"*" -f impact=ledger" ]] \
  && ok "H4 pq_dispatch: the argv ends -f impact=ledger" || bad "H4 argv '$A' out: $(cat "$T/pq-h4.out")"
PQ_H="$HH" pq h4b 'pq_dispatch "$PS_" 7 "$PH" "$M2" tests/x.sh fp1'
A=$(cat "$T/pq-h4b/gh.argv" 2>/dev/null); [ -n "$A" ] && ! has "$A" impact= && ok "H4 named suites carry no impact=" || bad "H4b argv '$A'"
PQ_H="$HN" pq h4c 'pq_dispatch "$PS_" 7 "$PH" "$M2"'
[ "$(cat "$T/pq-h4c/gh.argv" 2>/dev/null)" = "workflow run prequeue-gate.yml -R $PS_ --ref main -f pr=7 -f head=$PH -f main=$M2" ] \
  && ok "H4 a hub without the script: today's argv exactly" || bad "H4c argv '$(cat "$T/pq-h4c/gh.argv" 2>/dev/null)'"

# H5: pq_group_flush, the conductor's own call (the BH-8327 load pattern).
SLUG=example-org/demo
FB="$T/fakebin"; mkdir -p "$FB"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_LOG"\nexit 0\n' > "$FB/gh"; chmod +x "$FB/gh"
h5() { # h5 <case> <harness dir>
  ( C="$T/$1"; mkdir -p "$C/tmp" "$C/h"; cp -a "$2/." "$C/h/"; : > "$C/gh.log"
    MAIN=$(printf 'ee%038d' 0); export PATH="$FB:$PATH" GH_LOG="$C/gh.log"
    MC_H="$C/h"; HARNESS="$C/h"
    . "$DIR/bin/lib/mc/queue.sh"; . "$DIR/bin/lib/mc-prequeue.sh"
    MC_STATE_DIR="$C/state"; MC_TICK_ID=t1; MC_TICK_DIR="$C/tick"; TMPDIR="$C/tmp"
    mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
    mc_log() { printf '%s\n' "$*" >> "$C/log"; }
    mc_use_token() { :; }; mc_defer_word() { :; }; pq_status_gate() { :; }; pq_restamp() { :; }
    pq_impact_reuse() { _pq_ir=none; }
    gh_rest() {
      case "$2" in
        */commits/main) printf '{"sha":"%s"}' "$MAIN" ;;
        */actions/workflows/prequeue-gate.yml) printf '{"path":".github/workflows/prequeue-gate.yml"}' ;;
        */actions/workflows/prequeue-group-gate.yml) printf '{"id":9,"path":".github/workflows/prequeue-group-gate.yml"}' ;;
        */actions/workflows/*/runs\?*) printf '{"workflow_runs":[]}' ;;
        *) return 44 ;;
      esac
    }
    for i in 1 2; do pq_gate "$SLUG" $((100 + i)) "https://github.com/$SLUG/pull/$((100 + i))" "$(printf '%02x%038d' "$i" 0)" main >/dev/null; done
    pq_group_flush "$SLUG" ) > "$T/$1.out" 2>&1
}
h5 h5 "$HH"
A=$(grep '^workflow run prequeue-group-gate.yml ' "$T/h5/gh.log" 2>/dev/null)
[ "$(grep -c . <<<"$A")" = 1 ] && [[ "$A" == *" -f members="*" -f impact=ledger" ]] \
  && ok "H5 pq_group_flush: one group dispatch, its argv ends -f impact=ledger" || bad "H5 gh: $(cat "$T/h5/gh.log" 2>/dev/null) out: $(tail -3 "$T/h5.out")"
h5 h5n "$HN"
A=$(grep '^workflow run prequeue-group-gate.yml ' "$T/h5n/gh.log" 2>/dev/null)
[ -n "$A" ] && ! has "$A" impact= && ok "H5 a hub without the script: no impact=" || bad "H5n gh: $(cat "$T/h5n/gh.log" 2>/dev/null)"
python3 - "$GROUP_WF" > "$T/h5.py.out" 2>&1 <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); on = w.get("on", w.get(True))
i = on["workflow_dispatch"]["inputs"].get("impact") or {}
print(bool(i.get("required")), repr(i.get("default")), w["jobs"]["gate"]["with"].get("impact"))
PY
[ "$(cat "$T/h5.py.out")" = "False '' \${{ inputs.impact }}" ] && ok "H5 the group workflow takes impact and passes it to each head's gate" \
  || bad "H5 group workflow: $(cat "$T/h5.py.out")"

finish
