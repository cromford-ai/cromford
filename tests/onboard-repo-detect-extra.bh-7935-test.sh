#!/bin/bash
# tests/onboard-repo-detect-extra.bh-7935-test.sh — BH-7998 (BH-7935.1): the
# four extra repo facts (bin/lib/hub-probes/repo-detect-extra.sh) and the
# clone in the GitHub seam (og_clone, bin/lib/onboard-github.sh).
#   E1-E12 each fixture under tests/fixtures/onboard-github-extra/ gives its
#          ci_workflow, package_manager and test_runner (near misses and nulls)
#   K1     a clone failure gives readiness_level:null, the other facts unchanged
#   K2     the level equals bin/readiness-report.sh run directly on the clone
#   K3     no onb-clone.* temp dir is left after pass, failed reads, clone failure
#   K4     og_clone refuses a bad slug or a non-empty dest: rc 2, no call
#   K5     real-mode og_clone on an unarmed box: rc 4, no process
#   K6     real-mode og_clone (stubbed mint): the token rides GIT_CONFIG_VALUE_0,
#          never argv; --depth 1; the timeout knob; origin removed; released
#   K7     the seam call log, in order
#   K8     the extra calls no vendor client; the seam holds the clone
#   K9     the stranger's test command never runs (--no-run)
#   K10    a report that prints no JSON gives readiness_level:null
# Every case copies its fixture dir into its own scratch dir. A recording curl
# and gh are first on PATH; tests/onboard-github-vendor-budget.bh-7935-test.sh
# runs this suite with VENDOR_LOG and asserts they never ran.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-repo-detect-extra.bh-7935-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "onboard-repo-detect-extra: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SEAM="$DIR/bin/lib/onboard-github.sh"
EXTRA="$DIR/bin/lib/hub-probes/repo-detect-extra.sh"
HPD="$DIR/bin/lib/hub-probes"
REPORT="$DIR/bin/readiness-report.sh"
FXE="$DIR/tests/fixtures/onboard-github-extra"
for f in "$SEAM" "$EXTRA" "$HPD/repo-detect.sh"; do
  if [ -f "$f" ] && bash -n "$f" 2>/dev/null; then ok; else bad "missing or unparseable $f"; fi
done

VLOG="${VENDOR_LOG:-$T/vendor.log}"
: >> "$VLOG"
mkdir -p "$T/fakebin" "$T/gitbin" "$T/env" "$T/h" "$T/tmp"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 7\n' "$b" "$VLOG" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
export PATH="$T/fakebin:$PATH"
unset GH_APP_SLUG GH_APP_NAME GH_TOKEN HUB_PROBE_REPO_CLONE_TIMEOUT_S 2>/dev/null || true

# fxe <case>: a fresh copy of one fixture dir at $T/fx; prints the path.
# bun.lockb and main.go are written here, not committed: the share mirror's
# leakcheck refuses a .lockb or .go file as un-auditable (BH-3860).
fxe() {
  rm -rf "$T/fx"; mkdir -p "$T/fx"; cp -R "$FXE/$1"/. "$T/fx/"
  case "$1" in
    bun-playwright) printf '{"fixture":true}\n' > "$T/fx/clone__o__r/bun.lockb" ;;
    no-package) printf 'package main\n' > "$T/fx/clone__o__r/main.go" ;;
  esac
  printf '%s' "$T/fx"
}
calls() { cat "$T/fx/.calls" 2>/dev/null; }
leftover() { ls -d "$T/tmp"/onb-clone.* 2>/dev/null | wc -l | tr -d ' '; }

# extra <case>: hp_repo_detect_extra o/r, loaded the way the probe loads it
# (repo-detect.sh sources the seam and the extra). stdout -> $T/out.
extra() {
  local f; f=$(fxe "$1")
  env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" JOBS_URL="" HARNESS_SECRET="" TMPDIR="$T/tmp" \
    ONBOARD_GITHUB_FAKE="$f" HPD="$HPD" bash -c '. "$HPD/repo-detect.sh" && hp_repo_detect_extra o/r' \
    > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
fact() { jq -c ".$1" "$T/out" 2>/dev/null; }

# ── E1-E12: the decision table ──────────────────────────────────────────────
# case | ci_workflow | package_manager | test_runner
while IFS='|' read -r c ci pm tr; do
  extra "$c"
  check "E $c rc 0, one line" '[ "$(cat "$T/rc")" = 0 ] && [ "$(grep -c . "$T/out")" = 1 ]'
  check "E $c exactly the four keys" \
    '[ "$(jq -c "keys" "$T/out" 2>/dev/null)" = "[\"ci_workflow\",\"package_manager\",\"readiness_level\",\"test_runner\"]" ]'
  check "E $c ci_workflow=$ci" '[ "$(fact ci_workflow)" = "$ci" ]'
  check "E $c package_manager=$pm" '[ "$(fact package_manager)" = "$pm" ]'
  check "E $c test_runner=$tr" '[ "$(fact test_runner)" = "$tr" ]'
  check "E $c readiness_level is an integer" 'jq -e ".readiness_level | type == \"number\" and . == floor" "$T/out" >/dev/null'
  check "E $c leaves no temp dir" '[ "$(leftover)" = 0 ]'
done <<'TABLE'
npm-vitest|true|"npm"|"vitest"
pnpm-jest|false|"pnpm"|"jest"
yarn-node-test|true|"yarn"|"node --test"
bun-playwright|true|"bun"|"playwright"
bun-text|true|"bun"|"none"
multi-lock|true|"npm"|"vitest"
no-package|true|"none"|"none"
near-miss|true|"none"|"none"
reads-fail|null|null|null
bad-pkg|true|"npm"|null
bad-json|true|"npm"|null
TABLE

# The test-script matcher on strings scripts.test really holds.
tr_of() { bash -c '. "$1" && _hp_rdx_test_runner "$2"' _ "$EXTRA" "$1"; }
while IFS='|' read -r s want; do
  check "E12 scripts.test '$s' -> $want" '[ "$(tr_of "$s")" = "$want" ]'
done <<'TABLE'
vitest run|vitest
npx vitest --run|vitest
jest --ci|jest
NODE_ENV=test jest|jest
majestic|none
jest-junit-report|none
node --test test/|node --test
node --experimental-test-coverage --test|node --test
node test.js|none
nodemon --test|none
playwright test|playwright
npx playwright test --project=chromium|playwright
vitest && playwright test|vitest
mocha|none
echo "Error: no test specified" && exit 1|none
|none
TABLE

# ── K1: a clone failure ─────────────────────────────────────────────────────
extra clone-fail
check "K1 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "K1 readiness_level is null" '[ "$(fact readiness_level)" = null ]'
check "K1 the other three facts are unchanged" \
  '[ "$(fact ci_workflow)" = true ] && [ "$(fact package_manager)" = "\"npm\"" ] && [ "$(fact test_runner)" = "\"vitest\"" ]'

# ── K2: the level is the report's own answer on the clone ───────────────────
# The fake clone is a git checkout, as a real clone is (og_clone commits the
# fixture into a fresh repo), so build the same thing by hand and ask the report.
mkdir -p "$T/k2"; cp -R "$FXE/npm-vitest/clone__o__r"/. "$T/k2/"
( cd "$T/k2" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && git init -q && git add -A \
  && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture ) >/dev/null 2>&1
WANT=$(HARNESS="$T/h" JOBS_URL="" READINESS_GH=0 bash "$REPORT" "$T/k2" --json --no-run 2>/dev/null | jq '.level')
extra npm-vitest
check "K2 the direct report gives an integer" '[[ "$WANT" =~ ^[0-9]+$ ]]'
check "K2 readiness_level equals the direct report ($WANT)" '[ "$(fact readiness_level)" = "$WANT" ]'
check "K2 the fixture earns level 1 (a git checkout with CLAUDE.md)" '[ "$WANT" = 1 ]'

# ── K3: the temp dir is gone on every exit path ─────────────────────────────
for c in npm-vitest reads-fail clone-fail; do
  extra "$c"
  check "K3 no onb-clone.* after $c" '[ "$(leftover)" = 0 ]'
done
check "K3 the extra did use TMPDIR (a clone landed there)" 'grep -q "^clone repos/o/r$" "$T/fx/.calls"'

# ── K4: og_clone refusals ───────────────────────────────────────────────────
og() { # og <fake dir> <dest> <slug...>: og_clone in a clean bash; rc -> $T/rc
  local f="$1" dest="$2"; shift 2
  env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" ONBOARD_GITHUB_FAKE="$f" SEAM="$SEAM" DEST="$dest" \
    bash -c '. "$SEAM"; og_clone "$@" "$DEST"' _ "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
for s in 'a/../b' 'a b/c' 'a/b?x' 'https://github.com/a/b' '/b' "$(printf 'o%.0s' {1..40})/r" 'a/.' 'a/..' 'o_x/r' 'a/b/c' ''; do
  F=$(fxe npm-vitest); rm -rf "$T/dest"; mkdir -p "$T/dest"
  og "$F" "$T/dest" "$s"
  check "K4 slug '$s' is rc 2" '[ "$(cat "$T/rc")" = 2 ]'
  check "K4 slug '$s' records no call, writes nothing" '[ ! -e "$F/.calls" ] && [ -z "$(ls -A "$T/dest")" ]'
done
F=$(fxe npm-vitest); rm -rf "$T/dest"; mkdir -p "$T/dest"; touch "$T/dest/keep"
og "$F" "$T/dest" o/r
check "K4 a non-empty dest is rc 2, no call" '[ "$(cat "$T/rc")" = 2 ] && [ ! -e "$F/.calls" ] && [ "$(ls -A "$T/dest")" = keep ]'
F=$(fxe npm-vitest)
og "$F" "$T/no-such-dir" o/r
check "K4 a missing dest is rc 2, no call" '[ "$(cat "$T/rc")" = 2 ] && [ ! -e "$F/.calls" ] && [ ! -e "$T/no-such-dir" ]'
F=$(fxe npm-vitest); rm -rf "$T/dest"; mkdir -p "$T/dest"
env ONBOARD_GITHUB_FAKE="$F" SEAM="$SEAM" bash -c '. "$SEAM"; og_clone o/r' > /dev/null 2>&1; echo $? > "$T/rc"
check "K4 one argument is rc 2" '[ "$(cat "$T/rc")" = 2 ] && [ ! -e "$F/.calls" ]'
F=$(fxe npm-vitest); rm -rf "$T/dest"; mkdir -p "$T/dest"
og "$F" "$T/dest" o/r
check "K4 accepted: o/r is rc 0 and the dest is a git checkout with the fixture" \
  '[ "$(cat "$T/rc")" = 0 ] && [ -f "$T/dest/package.json" ] && [ -f "$T/dest/.github/workflows/ci.yml" ] && git -C "$T/dest" rev-parse --verify -q HEAD >/dev/null'
check "K4 the fake checkout has no remote" '[ -z "$(git -C "$T/dest" remote)" ]'
F=$(fxe npm-vitest); rm -rf "$T/dest"; mkdir -p "$T/dest"
og "$F" "$T/dest" a-b/c.d_e
check "K4 accepted: a-b/c.d_e passes the regex (no fixture -> rc 3, call recorded)" \
  '[ "$(cat "$T/rc")" = 3 ] && [ "$(calls)" = "clone repos/a-b/c.d_e" ]'

# ── K5: real mode, unarmed ──────────────────────────────────────────────────
GLOG="$T/git.log"; : > "$GLOG"
cat > "$T/gitbin/git" <<SH
#!/bin/bash
echo "argv \$*" >> "$GLOG"
echo "env count=\${GIT_CONFIG_COUNT:-} key=\${GIT_CONFIG_KEY_0:-} value=\${GIT_CONFIG_VALUE_0:-} prompt=\${GIT_TERMINAL_PROMPT:-}" >> "$GLOG"
if [ "\$1" = clone ]; then dest="\${@: -1}"; [ "\${GITRC:-0}" = 0 ] || exit "\$GITRC"; echo x > "\$dest/README.md"; fi
exit 0
SH
cat > "$T/gitbin/timeout" <<SH
#!/bin/bash
echo "timeout \$1" >> "$GLOG"
shift
exec "\$@"
SH
chmod +x "$T/gitbin/git" "$T/gitbin/timeout"
rm -rf "$T/dest"; mkdir -p "$T/dest"
env -u ONBOARD_GITHUB_FAKE HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" PATH="$T/gitbin:$PATH" SEAM="$SEAM" DEST="$T/dest" \
  bash -c '. "$SEAM"; og_clone example-org/project-11 "$DEST"' > "$T/out" 2>&1; echo $? > "$T/rc"
check "K5 an unarmed box is rc 4" '[ "$(cat "$T/rc")" = 4 ]'
check "K5 no git and no vendor process ran" '[ ! -s "$GLOG" ] && [ ! -s "$VLOG" ] && [ -z "$(ls -A "$T/dest")" ]'

# ── K6: real mode, armed (stubbed mint), recording git and timeout ──────────
ARMED='gh_auth_armed() { return 0; }
gh_app_only_for() { echo "mint $1" >> "$L"; [ "${MINT:-0}" = 0 ] || return 1; export GH_TOKEN=ghs_fixture_tok; }
gh_app_only_release() { echo release >> "$L"; export GH_TOKEN=prior; }
. "$SEAM"; GH_TOKEN=prior; og_clone example-org/project-11 "$DEST"; r=$?
echo "after token=$GH_TOKEN count=${GIT_CONFIG_COUNT:-unset}" >> "$L"; exit $r'
export L="$T/armed.log"
k6() { : > "$L"; : > "$GLOG"; rm -rf "$T/dest"; mkdir -p "$T/dest"
  env -u ONBOARD_GITHUB_FAKE HARNESS="$T/h" PATH="$T/gitbin:$PATH" SEAM="$SEAM" DEST="$T/dest" L="$L" "$@" \
    bash -c "$ARMED" > "$T/out" 2>&1; echo $? > "$T/rc"; }
k6
HDR="Authorization: Basic $(printf '%s' 'x-access-token:ghs_fixture_tok' | base64 | tr -d '\n')"
check "K6 armed clone is rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "K6 argv: a depth-1 single-branch clone of the https url into the dest" \
  'grep -qxF "argv clone -q --depth 1 --single-branch --no-tags -- https://github.com/example-org/project-11.git $T/dest" "$GLOG"'
check "K6 the token is in GIT_CONFIG_VALUE_0 as an extraHeader" \
  'grep -qxF "env count=1 key=http.extraHeader value=$HDR prompt=0" "$GLOG"'
ARGV=$(grep "^argv" "$GLOG")
check "K6 the token is never in argv" '[ -n "$ARGV" ] && [[ "$ARGV" != *ghs_fixture* && "$ARGV" != *"${HDR#Authorization: Basic }"* && "$ARGV" != *x-access-token* ]]'
check "K6 the clone runs under the default timeout 60" 'grep -qx "timeout 60" "$GLOG"'
check "K6 origin is removed after the clone" 'grep -qxF "argv -C $T/dest remote remove origin" "$GLOG"'
check "K6 mint for the slug, then release" '[ "$(sed -n 1p "$L")" = "mint example-org/project-11" ] && [ "$(sed -n 2p "$L")" = release ]'
check "K6 the caller's token is restored and no GIT_CONFIG leaks" 'grep -qx "after token=prior count=unset" "$L"'
k6 HUB_PROBE_REPO_CLONE_TIMEOUT_S=45
check "K6 the knob sets the timeout (45)" 'grep -qx "timeout 45" "$GLOG"'
for v in 4 601 abc 1e2 ''; do
  k6 HUB_PROBE_REPO_CLONE_TIMEOUT_S="$v"
  check "K6 knob '$v' out of range falls back to 60" 'grep -qx "timeout 60" "$GLOG"'
done
k6 HUB_PROBE_REPO_CLONE_TIMEOUT_S=5
check "K6 knob 5 (the minimum) is used" 'grep -qx "timeout 5" "$GLOG"'
k6 GITRC=128
check "K6 a failed clone is rc 75, released, origin not touched" \
  '[ "$(cat "$T/rc")" = 75 ] && grep -qx release "$L" && ! grep -q "remote remove" "$GLOG" && grep -qx "after token=prior count=unset" "$L"'
k6 MINT=1
check "K6 a refused mint is rc 44 and runs no git" '[ "$(cat "$T/rc")" = 44 ] && [ ! -s "$GLOG" ]'

# ── K7: the call log, in order ──────────────────────────────────────────────
extra npm-vitest
check "K7 npm-vitest: four seam calls in order" \
  '[ "$(calls)" = "$(printf "%s\n" repos/o/r/actions/workflows repos/o/r/contents repos/o/r/contents/package.json "clone repos/o/r")" ]'
extra no-package
check "K7 no-package: no package.json read" \
  '[ "$(calls)" = "$(printf "%s\n" repos/o/r/actions/workflows repos/o/r/contents "clone repos/o/r")" ]'

# ── K8: the extra reaches GitHub only through the seam ──────────────────────
CODE=$(grep -v "^[[:space:]]*#" "$EXTRA")
check "K8 the extra calls og_get and og_clone" '[[ "$CODE" == *"og_get "* && "$CODE" == *"og_clone "* ]]'
check "K8 the extra names no vendor client" '! [[ "$CODE" =~ curl|gh_rest|gh\ api|git\ clone|api\.github\.com|gh_app_only_for|gh_auth_for ]]'
SCODE=$(grep -v "^[[:space:]]*#" "$SEAM")
check "K8 the seam holds the clone" '[[ "$SCODE" == *"git clone"* ]]'

# ── K9: the stranger's tests never run ──────────────────────────────────────
# The report's tests/*.sh runner needs nothing on PATH but bash, so without
# --no-run this suite WOULD run and leave the marker.
F=$(fxe no-package)
mkdir -p "$F/clone__o__r/tests"
printf '#!/bin/bash\ntouch "%s"\n' "$T/ran-marker" > "$F/clone__o__r/tests/run.sh"
env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" JOBS_URL="" TMPDIR="$T/tmp" ONBOARD_GITHUB_FAKE="$F" HPD="$HPD" \
  bash -c '. "$HPD/repo-detect.sh" && hp_repo_detect_extra o/r' > "$T/out" 2>/dev/null
check "K9 a level is read" 'jq -e ".readiness_level | type == \"number\"" "$T/out" >/dev/null'
check "K9 the repo's test command did not run" '[ ! -e "$T/ran-marker" ]'

# ── K10: a report that prints no JSON is null, never a guess ────────────────
F=$(fxe npm-vitest)
env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" JOBS_URL="" TMPDIR="$T/tmp" ONBOARD_GITHUB_FAKE="$F" HPD="$HPD" \
  READINESS_LEVELS="$T/no-such-levels.json" bash -c '. "$HPD/repo-detect.sh" && hp_repo_detect_extra o/r' > "$T/out" 2>/dev/null
check "K10 a report that exits 2 with no JSON gives readiness_level:null" '[ "$(fact readiness_level)" = null ]'
check "K10 the other facts are still read" '[ "$(fact package_manager)" = "\"npm\"" ] && [ "$(leftover)" = 0 ]'

check "the recording vendor binaries never ran" '[ ! -s "$VLOG" ] || { cat "$VLOG"; false; }'

echo "onboard-repo-detect-extra: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
