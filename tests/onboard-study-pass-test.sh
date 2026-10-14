#!/bin/bash
# tests/onboard-study-pass-test.sh — bin/onboard-study.sh, the study pass of
# project onboarding (BH-4074, slice C0).
#
# The study reads a checkout and reports its commands, a DRAFT Verification
# Contract, a readiness grade and whether CodeGraph indexed it. What this suite
# protects is the "never guess" half: a command the checkout does not declare is
# null, a readiness grade that could not run is null plus an error (never 0), a
# contract with no test command is an EMPTY block (never an invented one), and
# deploy config is reported but never put in the contract.
#
# Every case runs the real CLI on a scratch copy of a fixture under $T and
# asserts on values jq pulls out of its output. Nothing greps the script.
# PATH is controlled: a stub dir goes first, and `codegraph` is only reachable
# through CODEGRAPH_BIN, so a box (or CI) with the real binary installed cannot
# change a result.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/onboard-study-pass-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
STUDY="$DIR/bin/onboard-study.sh"
RR="$DIR/bin/readiness-report.sh"
FIX="$DIR/tests/fixtures/onboard"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

mkdir -p "$T/h" "$T/stub"
export HARNESS="$T/h" READINESS_GH=0
unset READINESS_LEVELS

# A model call would land in $T/model-called (A10).
for m in claude agent-call.sh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/model-called"\nexit 0\n' "$m" "$T" > "$T/stub/$m"
  chmod +x "$T/stub/$m"
done
export PATH="$T/stub:$PATH"
# The real codegraph (CI installs it) is never reached: every case points
# CODEGRAPH_BIN at a path that does not exist unless it names a stub itself.
export CODEGRAPH_BIN="$T/absent/codegraph"
# A11's baseline: every fixture file's content, taken before any case runs. A
# hash rather than only `git status`, so it holds before the fixtures are
# committed too.
fixsum() { (cd "$FIX" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum); }
FIXSUM0=$(fixsum)

# mk <name> <fixture> — a scratch copy the case may mutate.
mk() { rm -rf "$T/$1"; mkdir -p "$T/$1"; cp -R "$FIX/$2/." "$T/$1/"; printf '%s' "$T/$1"; }
# study <out> <args...> — JSON (or text) into $T/<out>.out, rc into $RC.
study() { local out="$1"; shift; bash "$STUDY" "$@" >"$T/$out.out" 2>"$T/$out.err"; RC=$?; return 0; }
j() { jq -r "$2" "$T/$1.out" 2>/dev/null; }
# first non-blank line of the first ```bash block of contract_draft (or empty)
first_block() {
  j "$1" '.contract_draft' | awk '
    /^```bash/ && !seen { inb=1; seen=1; next }
    inb && /^```/ { exit }
    inb && NF { print; exit }'
}

# ── A1: the Next.js fixture ──────────────────────────────────────────────────
N=$(mk nx nextjs-app)
study a1 "$N" --json
eq "A1 rc" "$RC" 0
eq "A1 framework" "$(j a1 .framework)" nextjs
eq "A1 install" "$(j a1 .commands.install)" "npm ci"
eq "A1 test" "$(j a1 .commands.test)" "npm test"
eq "A1 build" "$(j a1 .commands.build)" "npm run build"
eq "A1 start" "$(j a1 .commands.start)" "npm start"
eq "A1 lint" "$(j a1 .commands.lint)" "npm run lint"
eq "A1 e2e" "$(j a1 .commands.e2e)" "npm run test:e2e"
eq "A1 deploy" "$(j a1 '.commands.deploy | tojson')" null
eq "A1 schema" "$(j a1 .schema)" 1
eq "A1 contract heading" "$(j a1 '.contract_draft' | grep -c '^## Verification Contract')" 1
eq "A1 contract line" "$(first_block a1)" "npm ci && npm run lint && npm test && npm run build"
eq "A1 e2e in a second block, not the first" \
   "$(j a1 '.contract_draft' | grep -c '^npm run test:e2e$')" 1
bash "$RR" "$N" --json --no-run >"$T/rr.json" 2>/dev/null
eq "A1 readiness.level is an integer" "$(j a1 '.readiness.level | type')" number
eq "A1 readiness.max_level is an integer" "$(j a1 '.readiness.max_level | type')" number
eq "A1 readiness.level matches readiness-report" "$(j a1 .readiness.level)" "$(jq -r .level "$T/rr.json")"
eq "A1 readiness.max_level matches readiness-report" "$(j a1 .readiness.max_level)" "$(jq -r .max_level "$T/rr.json")"
eq "A1 no readiness_error" "$(j a1 'has("readiness_error")')" false
eq "A1 no package_json_error" "$(j a1 'has("package_json_error")')" false

# ── A10: no model was called during A1 ──────────────────────────────────────
if [ -e "$T/model-called" ]; then bad "A10 a model stub was called: $(cat "$T/model-called")"; else ok; fi

# ── A2: codegraph ───────────────────────────────────────────────────────────
eq "A2 not available -> skipped" "$(j a1 .codegraph)" skipped
printf '#!/bin/bash\necho "$*" > "%s/cg-argv"; pwd > "%s/cg-cwd"\nexit 0\n' "$T" "$T" > "$T/cg-ok"
printf '#!/bin/bash\nexit 1\n' > "$T/cg-bad"
chmod +x "$T/cg-ok" "$T/cg-bad"
N=$(mk cg nextjs-app)
CODEGRAPH_BIN="$T/cg-ok" study a2ok "$N" --json
eq "A2 stub rc 0 -> indexed" "$(j a2ok .codegraph)" indexed
eq "A2 argv" "$(cat "$T/cg-argv" 2>/dev/null)" "init -i"
eq "A2 cwd is the checkout" "$(cat "$T/cg-cwd" 2>/dev/null)" "$(cd "$N" && pwd)"
CODEGRAPH_BIN="$T/cg-bad" study a2bad "$N" --json
eq "A2 stub rc 1 -> failed" "$(j a2bad .codegraph)" failed
eq "A2 failed codegraph still rc 0" "$RC" 0
# The default binary is `codegraph` on PATH: a stub first on PATH is found.
mkdir -p "$T/cgpath"; cp "$T/cg-ok" "$T/cgpath/codegraph"; rm -f "$T/cg-argv"
PATH="$T/cgpath:$PATH" CODEGRAPH_BIN= study a2path "$N" --json
eq "A2 codegraph on PATH -> indexed" "$(j a2path .codegraph)" indexed
eq "A2 PATH stub argv" "$(cat "$T/cg-argv" 2>/dev/null)" "init -i"

# ── A3: bare checkout ───────────────────────────────────────────────────────
B=$(mk bare bare)
study a3 "$B" --json
eq "A3 rc" "$RC" 0
eq "A3 framework" "$(j a3 '.framework | tojson')" null
eq "A3 every command null" "$(j a3 '[.commands[]] | map(. == null) | all')" true
eq "A3 command keys" "$(j a3 '.commands | keys | sort | join(",")')" "build,deploy,e2e,install,lint,start,test"
eq "A3 says no test command" "$(j a3 '.contract_draft | contains("no test command was detected")')" true
eq "A3 first block is empty" "$(first_block a3)" ""
eq "A3 first block exists" "$(j a3 '.contract_draft' | grep -c '^```bash$')" 1
eq "A3 no package_json_error" "$(j a3 'has("package_json_error")')" false

# ── A4: no lockfile ─────────────────────────────────────────────────────────
N=$(mk nolock nextjs-app); rm -f "$N/package-lock.json"
study a4 "$N" --json
eq "A4 install null" "$(j a4 '.commands.install | tojson')" null
eq "A4 test" "$(j a4 .commands.test)" "npm test"
eq "A4 contract line has no install" "$(first_block a4)" "npm run lint && npm test && npm run build"

# ── A5: pnpm ────────────────────────────────────────────────────────────────
N=$(mk pnpm nextjs-app); rm -f "$N/package-lock.json"; printf "lockfileVersion: '9.0'\n" > "$N/pnpm-lock.yaml"
study a5 "$N" --json
eq "A5 install" "$(j a5 .commands.install)" "pnpm install --frozen-lockfile"
eq "A5 test" "$(j a5 .commands.test)" "pnpm test"
eq "A5 build" "$(j a5 .commands.build)" "pnpm run build"

# ── A6: deploy is detected, never used ──────────────────────────────────────
N=$(mk dep nextjs-app); echo '{}' > "$N/vercel.json"; mkdir -p "$N/scripts"
printf '#!/bin/bash\necho deploy\n' > "$N/scripts/deploy.sh"
study a6 "$N" --json
eq "A6 deploy" "$(j a6 '.commands.deploy | tojson')" '{"detected":["vercel.json","scripts/deploy.sh"],"used":false}'
eq "A6 contract has no deploy" "$(j a6 '.contract_draft | ascii_downcase | (contains("deploy") or contains("vercel"))')" false
eq "A6 contract line unchanged" "$(first_block a6)" "npm ci && npm run lint && npm test && npm run build"

# ── A7: a readiness grade that cannot run is null + error, never 0 ──────────
N=$(mk rfail nextjs-app)
READINESS_LEVELS="$T/missing.json" study a7 "$N" --json
eq "A7 rc" "$RC" 0
eq "A7 readiness null" "$(j a7 '.readiness | tojson')" null
eq "A7 readiness_error non-empty" "$(j a7 '(.readiness_error // "") | length > 0')" true

# ── A8: malformed package.json ──────────────────────────────────────────────
N=$(mk badpkg nextjs-app); printf '{' > "$N/package.json"
study a8 "$N" --json
eq "A8 rc" "$RC" 0
eq "A8 package_json_error non-empty" "$(j a8 '(.package_json_error // "") | length > 0')" true
eq "A8 every package command null" \
   "$(j a8 '[.commands.install, .commands.test, .commands.build, .commands.start, .commands.lint, .commands.e2e] | map(. == null) | all')" true

# ── A9: usage ───────────────────────────────────────────────────────────────
study a9a; eq "A9 no arg" "$RC" 2
study a9b "$T/does-not-exist" --json; eq "A9 missing dir" "$RC" 2
study a9c "$B" --bogus; eq "A9 unknown flag" "$RC" 2
study a9d "$B" "$B"; eq "A9 two dirs" "$RC" 2
: > "$T/plainfile"; study a9e "$T/plainfile"; eq "A9 not a directory" "$RC" 2

# ── A12: human mode's last line ─────────────────────────────────────────────
N=$(mk human nextjs-app)
study a12 "$N"
eq "A12 rc" "$RC" 0
last=$(tail -n 1 "$T/a12.out")
if grep -Eq '^READINESS LEVEL: [0-9]+/[0-9]+$' <<<"$last"; then ok; else bad "A12 last line: [$last]"; fi
READINESS_LEVELS="$T/missing.json" study a12u "$N"
eq "A12 unknown last line" "$(tail -n 1 "$T/a12u.out")" "READINESS LEVEL: unknown"

# ── A10 again, over every case ──────────────────────────────────────────────
if [ -e "$T/model-called" ]; then bad "A10 a model stub was called: $(cat "$T/model-called")"; else ok; fi

# ── A11: the committed fixtures were never touched ──────────────────────────
eq "A11 fixture content unchanged" "$(fixsum)" "$FIXSUM0"
eq "A11 no tracked fixture modified" "$(git -C "$DIR" status --porcelain -- tests/fixtures/onboard | grep -v '^??')" ""

echo "onboard-study-pass-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
