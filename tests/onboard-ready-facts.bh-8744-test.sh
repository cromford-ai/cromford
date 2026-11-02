#!/bin/bash
# tests/onboard-ready-facts.bh-8744-test.sh — BH-8744 (BH-7935.3): the
# ready-facts hub probe, driven through the REAL hp_run of
# bin/lib/hub-probes/common.sh.
#   F1  every fact true: the exact one-line JSON, rc 0
#   F2  no env file, project not in vercel.conf: all false, rc 0
#   F3  vercel.conf near misses (comment, prefix, longer name) are false
#   F4  QA account: placeholder, empty, one key only are false; export prefix is true
#   F5  migration token: a commented key and a _OLD key are false
#   F6  planted secrets never reach stdout or stderr; no set -x in the probe
#   F7  the env file is never sourced (a $(...) value runs nothing)
#   F8  an unreadable env file is `unreadable`, rc 1 (skipped as root);
#       F8b an env path that is not a file is the same answer, as root too
#   F9  no harness root (HARNESS and H unset): `unreadable`, rc 1
#   N1  the worker route and the console files this ticket ships parse, and
#       their node suites run green
#   T1b the suite builds the worker catalogs (tests/lib/worker-catalogs.sh)
#       before N1 imports worker/jobs/src/index.js
# Fixtures live in this suite's own scratch dir. No network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-ready-facts.bh-8744-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# T1b: N1 loads the worker, which reads the git-ignored catalogs; build them.
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "onboard-ready-facts: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

HPD="$DIR/bin/lib/hub-probes"
PROBE="$DIR/bin/lib/hub-probes/ready-facts.sh"
P=project-11

# A fresh harness root and env dir per case: $T/<case>/h and $T/<case>/env.
fresh() { C="$T/$1"; mkdir -p "$C/h" "$C/env"; }
# hp_run ready-facts <project> under the case's root; stdout, stderr, rc kept.
hr() {
  env -u H HARNESS="$C/h" HARNESS_ENV_DIR="$C/env" HPD="$HPD" \
    bash -c '. "$HPD/common.sh" && hp_run ready-facts "$1"' _ "${1:-$P}" > "$C/out" 2> "$C/err"
  echo $? > "$C/rc"
}
out() { cat "$C/out"; }
rc()  { cat "$C/rc"; }
fact() { jq -r ".$1" "$C/out" 2>/dev/null; }
REAL_ENV='QA_CLERK_SECRET_KEY=sk_test_fixture_bh8744
QA_TEST_USER_ID=user_fixture_bh8744
MIGRATION_TOKEN=tok-fixture-bh8744'

check "the probe file parses" 'bash -n "$PROBE"'

# ── F1 ──────────────────────────────────────────────────────────────────────
fresh f1
printf '%s\n' "# project team vercel-project" "$P fixture-team $P" > "$C/h/vercel.conf"
printf '%s\n' "$REAL_ENV" > "$C/env/$P.env"
hr
check "F1 rc 0" '[ "$(rc)" = 0 ]'
check "F1 the exact line" '[ "$(out)" = "{\"vercel\":true,\"qa_account\":true,\"migration_token\":true}" ]'
check "F1 one line" '[ "$(grep -c . "$C/out")" = 1 ]'

# ── F2 ──────────────────────────────────────────────────────────────────────
fresh f2
printf '%s\n' "other-p fixture-team other-p" > "$C/h/vercel.conf"
hr
check "F2 rc 0" '[ "$(rc)" = 0 ]'
check "F2 all false" '[ "$(out)" = "{\"vercel\":false,\"qa_account\":false,\"migration_token\":false}" ]'
fresh f2b
hr
check "F2b no vercel.conf and no env file: all false, rc 0" \
  '[ "$(rc)" = 0 ] && [ "$(out)" = "{\"vercel\":false,\"qa_account\":false,\"migration_token\":false}" ]'

# ── F3 ──────────────────────────────────────────────────────────────────────
for line in "# $P fixture-team $P" "#$P fixture-team" "$P-2 fixture-team x" "x$P fixture-team x" "  # $P"; do
  fresh f3
  printf '%s\n' "$line" > "$C/h/vercel.conf"
  hr
  check "F3 vercel.conf line '$line' is false" '[ "$(rc)" = 0 ] && [ "$(fact vercel)" = false ]'
done
fresh f3b
printf '%s\n' "  $P	fixture-team $P" > "$C/h/vercel.conf"
hr
check "F3b a leading-blank, tab-separated line is the project" '[ "$(fact vercel)" = true ]'

# ── F4 ──────────────────────────────────────────────────────────────────────
qa_case() {
  fresh f4
  printf '%s\n' "$2" > "$C/env/$P.env"
  hr
  WANT="$3"
  check "F4 $1: qa_account $3" '[ "$(rc)" = 0 ] && [ "$(fact qa_account)" = "$WANT" ]'
}
qa_case "placeholder secret" $'QA_CLERK_SECRET_KEY=<clerk-secret-key-for-this-apps-instance>\nQA_TEST_USER_ID=user_1' false
qa_case "placeholder user" $'QA_CLERK_SECRET_KEY=sk_fixture\nQA_TEST_USER_ID=<user_...>' false
qa_case "empty user" $'QA_CLERK_SECRET_KEY=sk_fixture\nQA_TEST_USER_ID=' false
qa_case "empty quoted user" $'QA_CLERK_SECRET_KEY=sk_fixture\nQA_TEST_USER_ID=""' false
qa_case "only the secret" 'QA_CLERK_SECRET_KEY=sk_fixture' false
qa_case "only the user" 'QA_TEST_USER_ID=user_1' false
qa_case "export prefix" $'QA_CLERK_SECRET_KEY=sk_fixture\nexport QA_TEST_USER_ID=user_1' true
qa_case "quoted values" $'QA_CLERK_SECRET_KEY="sk_fixture"\nQA_TEST_USER_ID=\'user_1\'' true
qa_case "the first line decides" $'QA_CLERK_SECRET_KEY=\nQA_CLERK_SECRET_KEY=sk_fixture\nQA_TEST_USER_ID=user_1' false
qa_case "a suffixed key" $'QA_CLERK_SECRET_KEY_OLD=sk_fixture\nQA_TEST_USER_ID=user_1' false

# ── F5 ──────────────────────────────────────────────────────────────────────
for body in '#MIGRATION_TOKEN=tok-fixture' 'MIGRATION_TOKEN_OLD=tok-fixture' ' # MIGRATION_TOKEN=tok-fixture' \
            'XMIGRATION_TOKEN=tok-fixture' 'MIGRATION_TOKEN=<token>' 'MIGRATION_TOKEN='; do
  fresh f5
  printf '%s\n' "$body" > "$C/env/$P.env"
  hr
  check "F5 '$body' is false" '[ "$(rc)" = 0 ] && [ "$(fact migration_token)" = false ]'
done
fresh f5b
printf '%s\n' 'MIGRATION_TOKEN=tok-fixture-bh8744' > "$C/env/$P.env"
hr
check "F5b a real token is true" '[ "$(fact migration_token)" = true ]'

# ── F6 ──────────────────────────────────────────────────────────────────────
fresh f6
printf '%s\n' "$P fixture-team $P" > "$C/h/vercel.conf"
printf '%s\n' 'QA_PASSWORD=sekret123-fixture' 'QA_TEST_PASSWORD=sekret123-fixture' 'QA_CLERK_SECRET_KEY=sk_sekret123_fixture' \
  'QA_TEST_USER_ID=user_sekret123_fixture' 'MIGRATION_TOKEN=sekret123-fixture' > "$C/env/$P.env"
hr
check "F6 rc 0, all true" '[ "$(rc)" = 0 ] && [ "$(out)" = "{\"vercel\":true,\"qa_account\":true,\"migration_token\":true}" ]'
check "F6 no planted value in stdout or stderr" '! grep -q sekret123 "$C/out" "$C/err"'
check "F6 stderr is empty" '[ ! -s "$C/err" ]'
check "F6 the probe has no set -x" '! grep -qE "set -[a-z]*x|set -o xtrace" "$PROBE"'
check "F6 the output keys are booleans only" \
  'jq -e "(keys == [\"migration_token\",\"qa_account\",\"vercel\"]) and ([.[] | type] | unique == [\"boolean\"])" "$C/out" >/dev/null'

# ── F7 ──────────────────────────────────────────────────────────────────────
fresh f7
# shellcheck disable=SC2016  # the $(...) is the payload a sourcing reader would run
printf '%s\n' "MIGRATION_TOKEN=\$(touch $C/pwned)" "QA_TEST_USER_ID=\`touch $C/pwned2\`" > "$C/env/$P.env"
hr
check "F7 rc 0" '[ "$(rc)" = 0 ]'
check "F7 the env file was not sourced" '[ ! -e "$C/pwned" ] && [ ! -e "$C/pwned2" ]'

# ── F8 ──────────────────────────────────────────────────────────────────────
fresh f8
printf '%s\n' "$REAL_ENV" > "$C/env/$P.env"
chmod 000 "$C/env/$P.env"
if [ "$(id -u)" = 0 ]; then
  echo "skip: F8 runs as root, and root reads a mode-000 file"
else
  hr
  check "F8 unreadable, rc 1" '[ "$(rc)" = 1 ] && [ "$(out)" = unreadable ]'
fi
chmod 600 "$C/env/$P.env"
# The same answer as root: the env path is there but is not a readable file.
fresh f8b
mkdir "$C/env/$P.env"
hr
check "F8b an env path that is a directory: unreadable, rc 1" '[ "$(rc)" = 1 ] && [ "$(out)" = unreadable ]'

# ── F9 ──────────────────────────────────────────────────────────────────────
fresh f9
env -u H -u HARNESS HARNESS_ENV_DIR="$C/env" HPD="$HPD" \
  bash -c '. "$HPD/common.sh" && hp_run ready-facts "$1"' _ "$P" > "$C/out" 2> "$C/err"
echo $? > "$C/rc"
check "F9 no harness root: unreadable, rc 1" '[ "$(rc)" = 1 ] && [ "$(out)" = unreadable ]'

# The hub lane passes its root as H (bin/hub-probe.sh), not HARNESS.
fresh f9b
printf '%s\n' "$P fixture-team $P" > "$C/h/vercel.conf"
env -u HARNESS H="$C/h" HARNESS_ENV_DIR="$C/env" HPD="$HPD" \
  bash -c '. "$HPD/common.sh" && hp_run ready-facts "$1"' _ "$P" > "$C/out" 2> "$C/err"
echo $? > "$C/rc"
check "F9b H alone is the root" '[ "$(rc)" = 0 ] && [ "$(fact vercel)" = true ]'

# ── N1 ──────────────────────────────────────────────────────────────────────
ROUTE="$DIR/worker/jobs/src/routes/onboarding-ready.js"
CARDS="$DIR/console-ui/src/lib/ready-cards.js"
SCREEN="$DIR/console-ui/src/screens/ProjectReady.js"
CSS="$DIR/console-ui/src/project-ready.css"
DRIVE="$DIR/console-ui/tests/drive/project-ready.bh-8744-drive.mjs"
SEED="$DIR/worker/jobs/schema.d/202611020040-bh-8744-onboarding-ready-knobs.sql"
for f in "$ROUTE" "$CARDS" "$SCREEN" "$CSS" "$DRIVE" "$SEED"; do
  check "N1 $f exists" '[ -s "$f" ]'
done
check "N1 project-ready.css has no colour literal" '! grep -qE "#[0-9a-fA-F]{3,8}\b" "$CSS"'
check "N1 main.js imports project-ready.css" 'grep -qx "import '"'"'./project-ready.css'"'"';" "$DIR/console-ui/src/main.js"'
if command -v node >/dev/null 2>&1; then
  for f in "$ROUTE" "$CARDS" "$DRIVE"; do check "N1 $f parses" 'node --check "$f"'; done
  if [ -d "$DIR/worker/jobs/node_modules" ] || [ -z "$(jq -r '.dependencies // {} | keys[]' "$DIR/worker/jobs/package.json" 2>/dev/null)" ]; then
    (cd "$DIR/worker/jobs" && node --test test/onboarding-ready.bh-8744.test.js) > "$T/node-w.out" 2>&1; NRC=$?
    check "N1 worker node suite green" '[ "$NRC" = 0 ] || { tail -30 "$T/node-w.out"; false; }'
  fi
  if [ -d "$DIR/console-ui/node_modules" ]; then
    (cd "$DIR/console-ui" && node --test tests/ready-cards.bh-8744.test.js) > "$T/node-c.out" 2>&1; NRC=$?
    check "N1 console node suite green" '[ "$NRC" = 0 ] || { tail -30 "$T/node-c.out"; false; }'
  fi
fi

echo "onboard-ready-facts: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
