#!/bin/bash
# tests/worker-sentry.bh-5618-test.sh — BH-5618: harness-jobs reports
# exceptions to Sentry when HARNESS_SENTRY_DSN is bound, and does nothing when
# it is not. (The Cloud worker moved to example-org/cromford-web, BH-5239.)
# Runs worker/jobs/test/sentry.bh-5618.test.js unless WORKER_JOBS_CI_JOB=1 (the
# Jobs worker CI job runs it there with `npm test`, same rule as
# jobs-worker-test).
# @sentry/cloudflare is the worker's one runtime dependency. When it is not
# installed this runs `npm ci` there first, and a failed install FAILS the
# suite: it never takes a skip path.
# Plus:
#   X2 the jobs wrangler config sets compatibility_flags nodejs_compat
#   X3 the worker-jobs CI job runs npm ci in worker/jobs before npm test
#   X4 the `# >>> worker npm ci (BH-5618)` block of bin/harness-sync.sh, run
#      VERBATIM with a fake npm: installs on a lockfile, alerts and skips the
#      deploy on a failed install, does nothing without a lockfile
#   X5 no real DSN under worker/
# Run: HARNESS_TEST_SANDBOX=1 bash tests/worker-sentry.bh-5618-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "worker-sentry.bh-5618-test: SKIPPED — node is not installed on this box"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

JOBS_LIB="$DIR/worker/jobs/src/lib/sentry.js"
SYNC="$DIR/bin/harness-sync.sh"
WF="$DIR/.github/workflows/harness-ci.yml"
# The sources this suite exercises, named by path so bin/test-impact.sh maps a
# change to any of them onto this suite.
for SRC in "$JOBS_LIB" "$SYNC" "$WF" \
           "$DIR/worker/jobs/src/index.js" \
           "$DIR/worker/jobs/package.json" "$DIR/worker/jobs/package-lock.json" "$DIR/worker/jobs/.npmrc" \
           "$DIR/worker/jobs/wrangler.jsonc" \
           "$DIR/worker/jobs/test/sentry.bh-5618.test.js"; do
  [ -r "$SRC" ] || { echo "FAIL: worker-sentry.bh-5618-test: missing $SRC"; exit 1; }
done

# ── X2 ──────────────────────────────────────────────────────────────────────
CFG="$DIR/worker/jobs/wrangler.jsonc"
if grep -qE '^[[:space:]]*"compatibility_flags":[[:space:]]*\[[^]]*"nodejs_compat"' "$CFG"; then ok
else bad "X2: $CFG does not set compatibility_flags [\"nodejs_compat\"]"; fi

# ── X3 ──────────────────────────────────────────────────────────────────────
# The worker-jobs job block, comment lines dropped: an explanation that says
# "npm ci" must not pass for the command.
JOB=$(awk '/^  worker-jobs:/{on=1; next} on && /^  [A-Za-z0-9_-]+:/{exit} on' "$WF" | grep -v '^[[:space:]]*#')
CI_LINE=$(printf '%s\n' "$JOB" | grep -n 'run: npm ci' | head -1 | cut -d: -f1)
TEST_LINE=$(printf '%s\n' "$JOB" | grep -n 'npm test' | head -1 | cut -d: -f1)
if [ -n "$CI_LINE" ] && [ -n "$TEST_LINE" ] && [ "$CI_LINE" -lt "$TEST_LINE" ] \
   && printf '%s\n' "$JOB" | sed -n "$((CI_LINE-1))p" | grep -q 'working-directory: worker/jobs'; then ok
else bad "X3: the worker-jobs job does not run 'npm ci' in worker/jobs before 'npm test' (npm ci line=${CI_LINE:-none}, npm test line=${TEST_LINE:-none})"; fi

# ── X4 ──────────────────────────────────────────────────────────────────────
BLK=$(sed -n '/# >>> worker npm ci (BH-5618)/,/# <<< worker npm ci/p' "$SYNC")
if [ -z "$BLK" ]; then
  bad "X4: no '# >>> worker npm ci (BH-5618)' block in bin/harness-sync.sh"
else
  # $1 case name, $2 fake npm exit code, $3 1 = the worker has a lockfile
  x4_run() {
    local W="$T/x4-$1"
    mkdir -p "$W/wdir" "$W/h/bin" "$W/fakebin"
    [ "$3" = 1 ] && echo '{"lockfileVersion":3}' > "$W/wdir/package-lock.json"
    printf '#!/bin/bash\necho "npm $*" >> "%s/npm.calls"\nexit %s\n' "$W" "$2" > "$W/fakebin/npm"
    printf '#!/bin/bash\necho "$*" >> "%s/alerts"\n' "$W" > "$W/h/bin/alert-line.sh"
    chmod +x "$W/fakebin/npm" "$W/h/bin/alert-line.sh"
    { echo 'for WNAME in jobs; do'
      echo 'WSHA=0123456789abcdef'
      printf '%s\n' "$BLK"
      echo 'echo deploy-reached >> "$W/after"'
      echo 'done'; } > "$W/run.sh"
    PATH="$W/fakebin:$PATH" W="$W" WDIR="$W/wdir" HARNESS="$W/h" LOG="$W/log" bash "$W/run.sh"
  }
  x4_run ok 0 1
  W="$T/x4-ok"
  if [ "$(grep -c '^npm ci --omit=dev ' "$W/npm.calls" 2>/dev/null)" = 1 ] && [ -s "$W/after" ] && [ ! -e "$W/alerts" ]; then ok
  else bad "X4a: lockfile + npm exit 0 must run one 'npm ci --omit=dev' and reach the deploy (calls: $(cat "$W/npm.calls" 2>/dev/null))"; fi
  x4_run fail 1 1
  W="$T/x4-fail"
  if grep -q 'npm ci FAILED' "$W/alerts" 2>/dev/null && [ ! -e "$W/after" ]; then ok
  else bad "X4b: a failed npm ci must write one 'npm ci FAILED' alert and skip the deploy (alerts: $(cat "$W/alerts" 2>/dev/null); deploy reached: $([ -e "$W/after" ] && echo yes || echo no))"; fi
  x4_run nolock 0 0
  W="$T/x4-nolock"
  if [ ! -e "$W/npm.calls" ] && [ -s "$W/after" ]; then ok
  else bad "X4c: no lockfile must mean no npm call and an unchanged deploy path"; fi
fi

# ── X5 ──────────────────────────────────────────────────────────────────────
# A real DSN is https://<key>@<org>.ingest.sentry.io/<id>. Every DSN-shaped
# string under worker/ must be the sentry.test fixture.
HITS=$(git -C "$DIR" grep --untracked -nE 'https?://[^/@"'"'"' ]+@[^/"'"'"' ]*sentry' -- worker/ 2>/dev/null | grep -v 'sentry\.test/')
REAL=$(git -C "$DIR" grep --untracked -n 'ingest\.sentry\.io' -- worker/ 2>/dev/null)
if [ -z "$HITS" ] && [ -z "$REAL" ]; then ok; else bad "X5: a DSN-shaped string under worker/ is not the sentry.test fixture: $HITS $REAL"; fi

# ── node files ──────────────────────────────────────────────────────────────
npm_ensure() { # $1 = worker name
  [ -r "$DIR/worker/$1/node_modules/@sentry/cloudflare/package.json" ] && return 0
  (cd "$DIR/worker/$1" && npm_config_cache="$T/npm-cache" npm ci --no-audit --no-fund) >"$T/npm-$1.log" 2>&1
  local rc=$?
  [ "$rc" = 0 ] || { cat "$T/npm-$1.log"; bad "npm ci failed (rc=$rc) in worker/$1"; return 1; }
}
node_file() { # $1 = worker name
  local LOG="$T/node-$1.log" RC PASSED SKIPPED
  (cd "$DIR/worker/$1" && node --test --test-reporter=spec test/sentry.bh-5618.test.js) >"$LOG" 2>&1
  RC=$?
  PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$LOG"; bad "worker/$1 sentry.bh-5618.test.js: node --test rc=$RC"; return; fi
  if [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; bad "worker/$1: no test summary — node's reporter changed shape"; return; fi
  [ "$PASSED" -gt 0 ] || { bad "worker/$1: 0 tests passed — the file did not run"; return; }
  [ "$SKIPPED" = 0 ] || { cat "$LOG"; bad "worker/$1: $SKIPPED test(s) SKIPPED"; return; }
  ok; echo "worker/$1 sentry.bh-5618.test.js: $PASSED passed, 0 skipped"
}

if [ "${WORKER_JOBS_CI_JOB:-}" = 1 ]; then
  echo "worker/jobs sentry.bh-5618.test.js: not repeated here — the Jobs worker CI job runs it with npm test"
else
  # worker/jobs imports the generated catalog/lanes.json statically; render it
  # the way tests/jobs-worker-test.sh does (git-ignored, canonical path).
  if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
    "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
      || bad "catalog/lanes.json could not be composed — worker/jobs cannot load"
  fi
  npm_ensure jobs && node_file jobs
fi

echo "worker-sentry.bh-5618-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
