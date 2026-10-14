#!/bin/bash
# tests/model-literal-strict.bh-1510-4-test.sh — BH-1510.4: the model-id
# literal lint is an ERROR, the repo carries 0 of them, and CI runs it on every
# PR whatever bin/test-impact.sh selects.
#
# What is pinned, in the order it breaks:
#   1. the lint over this repo: rc 0, "0 model-id literal line(s)"
#   2. a literal planted in a scratch bin/ is rc 1 and names file:line;
#      --warn on the same tree lists it and exits 0
#   3. bin/update-model-prices.sh carries no bash MAP='{…}' table
#   4. harness-ci.yml runs the lint as its own step, without --warn
#   5. every *_MODEL knob in catalog/lanes.d has default "" (#1507 folded into roles)
#   6. the bootstrap smoke block, run as shipped: the routed model reaches
#      bin/agent-call.sh as its model argument (BH-2535); no route is FATAL and
#      agent-call is never called
#   7. negatives: a literal under tests/ or in worker/jobs/schema.sql is not a hit
#
# No network, no real box: everything lives under one scratch dir.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/model-literal-strict.bh-1510-4-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null && command -v python3 >/dev/null \
  || { echo "jq/git/python3 missing"; exit 1; }
LINT="$DIR/tests/model-literal-lint.sh"

# ── 1. this repo is at 0 ─────────────────────────────────────────────────────
OUT=$(bash "$LINT" "$DIR" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "1 the lint over the repo must exit 0, got $RC: $(printf '%s\n' "$OUT" | tail -5)"
grep -qF 'model-literal-lint: 0 model-id literal line(s)' <<<"$OUT" \
  && ok || bad "1 the lint must report 0 literal lines: $(printf '%s\n' "$OUT" | tail -3)"

# ── scratch tree: the two vocabulary files plus whatever a case plants ──────
mktree() { # mktree <dir> — a git tree the lint can scan, with no literal in it
  scratch_rm "$1" || return 1; mkdir -p "$1/catalog" "$1/bin" "$1/tests" "$1/worker/jobs"
  cp "$DIR/catalog/model-prices.json" "$DIR/catalog/model-slugs.json" "$1/catalog/"
  printf '#!/bin/bash\necho clean\n' > "$1/bin/clean.sh"
  git -C "$1" init -q 2>/dev/null
}
commit_tree() { git -C "$1" add -A >/dev/null 2>&1; }

# ── 2. strict by default; --warn lists without failing ──────────────────────
TR="$T/tree2"; mktree "$TR"
printf '#!/bin/bash\n# nothing here\nclaude -p --model claude-opus-5-5 "hi"\n' > "$TR/bin/x.sh"
commit_tree "$TR"
OUT=$(bash "$LINT" "$TR" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "2 a planted literal must fail the lint by default (rc 1), got $RC"
grep -q "bin/x.sh:3:" <<<"$OUT" && ok || bad "2 the failure must name bin/x.sh:3: $OUT"
OUT=$(bash "$LINT" --warn "$TR" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "2 --warn must list and exit 0, got $RC"
grep -q "bin/x.sh:3:" <<<"$OUT" && ok || bad "2 --warn must still list bin/x.sh:3: $OUT"
bash "$LINT" --strict "$TR" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "2 --strict stays an accepted alias for the default, got $RC"
# A clean tree is green with no flag at all.
TC="$T/treec"; mktree "$TC"; commit_tree "$TC"
bash "$LINT" "$TC" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "2 a clean tree must pass the strict default, got $RC"

# ── 3. no bash slug table in update-model-prices ────────────────────────────
N=$(grep -c "^MAP='" "$DIR/bin/update-model-prices.sh")
[ "$N" = 0 ] && ok || bad "3 bin/update-model-prices.sh still carries a MAP='{…}' literal table ($N)"

# ── 4. CI runs the lint as its own step, strict ─────────────────────────────
STEPS=$(python3 - "$DIR/.github/workflows/harness-ci.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for name, j in d.get("jobs", {}).items():
    for s in j.get("steps", []) or []:
        r = str(s.get("run", ""))
        if "tests/model-literal-lint.sh" in r:
            print(f"{name}\t{s.get('if', '')}\t{r.strip()}")
PY
); RC=$?
[ "$RC" = 0 ] && ok || bad "4 could not parse harness-ci.yml"
[ -n "$STEPS" ] && ok || bad "4 no harness-ci.yml step runs tests/model-literal-lint.sh"
grep -q -- '--warn' <<<"$STEPS" && bad "4 the CI step must not pass --warn: $STEPS" || ok

# ── 5. #1507's *_MODEL knobs are folded into roles ──────────────────────────
KNOBS=$(python3 - "$DIR/catalog/lanes.d" <<'PY'
import json, glob, sys
bad, n = [], 0
def walk(o, f):
    global n
    if isinstance(o, dict):
        if str(o.get("env", "")).endswith("_MODEL"):
            n += 1
            if o.get("default") != "":
                bad.append(f"{f}:{o['env']}={o.get('default')!r}")
        for v in o.values(): walk(v, f)
    elif isinstance(o, list):
        for v in o: walk(v, f)
for f in sorted(glob.glob(sys.argv[1] + "/*.json")):
    walk(json.load(open(f)), f.rsplit("/", 1)[-1])
print(n); print("\n".join(bad))
PY
)
[ "$(head -1 <<<"$KNOBS")" -gt 0 ] 2>/dev/null && ok || bad "5 found no *_MODEL knobs in catalog/lanes.d — the walk read nothing"
[ -z "$(printf '%s\n' "$KNOBS" | sed 1d | grep .)" ] && ok || bad "5 *_MODEL knobs with a model default: $(printf '%s\n' "$KNOBS" | sed 1d)"

# ── 6. the bootstrap smoke block, as shipped ────────────────────────────────
BOOT="$DIR/bin/bootstrap-machine.sh"
grep -q 'claude-haiku' "$BOOT" && bad "6 bin/bootstrap-machine.sh still names a haiku id" || ok
BLOCK=$(sed -n '/^# >>> smoke model/,/^# <<< smoke model/p' "$BOOT")
[ -n "$BLOCK" ] && ok || bad "6 no '# >>> smoke model' / '# <<< smoke model' block in bin/bootstrap-machine.sh"
S="$T/smoke"; mkdir -p "$S/bin/lib" "$S/logs" "$S/state" "$S/fakebin"
cp "$DIR/bin/lib/model-route.sh" "$S/bin/lib/"
cat > "$S/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf 'model=%s\n' "$3" >> "$CLAUDE_SINK"
echo OK > "$5"
SH
chmod +x "$S/bin/agent-call.sh"
# A bare `claude` on PATH is a trap: the smoke must never reach it directly.
printf '#!/bin/bash\necho "claude $*" >> "$CLAUDE_SINK"\nexit 99\n' > "$S/fakebin/claude"
chmod +x "$S/fakebin/claude"
# The worker, stubbed at the transport the resolver calls (_jobs_req).
# WORKER_ANSWER=route|none|down.
{ cat <<'SH'
#!/bin/bash
_jobs_req() {
  echo "$*" >> "$REQ_SINK"
  # Only the smoke role has a route: a block that asks for any other role is
  # told "no route", so reading the wrong role cannot pass.
  local ans="$WORKER_ANSWER"
  [ "$ans" = route ] && [ "$2" != /api/model-routes/bootstrap.smoke ] && ans=none
  case "$ans" in
    route) printf '{"role":"bootstrap.smoke","source":"hub","ladder":[{"position":0,"model":"%s","runner":"claude"}]}\n' "$ROUTED" ;;
    none)  printf '{"role":"bootstrap.smoke","source":"none","ladder":[]}\n' ;;
    *)     return 1 ;;
  esac
}
set -euo pipefail   # bin/bootstrap-machine.sh runs under this
HERE="$HARNESS/bin"
SH
  printf '%s\n' "$BLOCK"
  echo 'echo SMOKE_DONE'
} > "$S/run-smoke.sh"
run_smoke() { # run_smoke <answer> -> rc in RC, output in OUT
  : > "$S/claude.args"; : > "$S/req.log"; scratch_rm "$S/state/model-routes"
  OUT=$(env HARNESS="$S" HARNESS_SECRET=x PATH="$S/fakebin:$PATH" CLAUDE_SINK="$S/claude.args" REQ_SINK="$S/req.log" \
        WORKER_ANSWER="$1" ROUTED="routed-model-xyz" bash "$S/run-smoke.sh" 2>&1); RC=$?
}
run_smoke route
[ "$RC" = 0 ] && ok || bad "6 with a route the smoke block must pass, got $RC: $OUT"
grep -qx 'model=routed-model-xyz' "$S/claude.args" \
  && ok || bad "6 agent-call must be called with the routed model, got: $(cat "$S/claude.args")"
grep -qx 'GET /api/model-routes/bootstrap.smoke' "$S/req.log" \
  && ok || bad "6 the block must ask the worker for bootstrap.smoke, asked: $(cat "$S/req.log")"
for ans in none down; do
  run_smoke "$ans"
  [ "$RC" = 1 ] && ok || bad "6 ($ans) no route must be FATAL rc 1, got $RC: $OUT"
  grep -q 'no model route for bootstrap.smoke' <<<"$OUT" \
    && ok || bad "6 ($ans) the FATAL must name bootstrap.smoke: $OUT"
  [ ! -s "$S/claude.args" ] && ok || bad "6 ($ans) agent-call must never run without a routed model: $(cat "$S/claude.args")"
  grep -q SMOKE_DONE <<<"$OUT" && bad "6 ($ans) the block must stop the bootstrap" || ok
done

# ── 7. negatives: tests/ and the seed migration are not call sites ──────────
TN="$T/tree7"; mktree "$TN"
printf 'm=claude-opus-5-5\n' > "$TN/tests/foo.sh"
printf "INSERT OR IGNORE INTO x VALUES ('claude-opus-5-5');\n" > "$TN/worker/jobs/schema.sql"
commit_tree "$TN"
OUT=$(bash "$LINT" "$TN" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "7 a literal in tests/ or worker/jobs/schema.sql must not fail the lint, got $RC: $OUT"

echo "model-literal-strict.bh-1510-4-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
