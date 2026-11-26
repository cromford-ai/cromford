#!/bin/bash
# tests/suite-preflight-pm.bh-10128-test.sh — BH-10128: the suite-preflight
# setup attempt uses the package manager that the repo's lock file names.
#
# THE DEFECT THIS PINS. sp_install (bin/lib/suite-preflight.sh) ran `npm ci`
# with a package-lock.json and `npm install --no-package-lock` with any other
# repo. example-org/project-3 has pnpm-lock.yaml and no package-lock.json, so npm
# stopped on it (rc=1) and five project-3 pool builds on 2026-11-25 (18:02-18:26
# UTC) ended `could-not-run: node_modules after one setup attempt (npm install
# --no-audit --no-fund --no-package-lock (rc=1))`.
#
#   U1-U12  sp_install direct: the command per lock file, corepack, a tool that
#           is not on the box (rc 127, the tool named, never npm), two lock files
#   E1-E3   HARNESS_SUITE_RUN's npm arm (lifted VERBATIM by its markers, as the
#           BH-7695 test does): a pnpm repo installs with pnpm and the suite
#           runs; with no pnpm it is could-not-run with the tool in the line and
#           in the one infra alert
#
# No network: npm, pnpm, yarn and corepack are stubs. The real ones are hidden:
# $T/sys holds a link to every other command on PATH, and each case puts only
# the stubs it names in front of it. Nothing is written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset DATABASE_URL SUITE_PREFLIGHT_INSTALL SUITE_PREFLIGHT_SETUP_S SUITE_PREFLIGHT_ENV \
  POOL_TEST_POSTGRES TEST_RC TEST_OUT

LIB="$DIR/bin/lib/suite-preflight.sh"
[ -r "$LIB" ] && ok || bad "$LIB is missing"

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

NOW=1762041600
H="$T/h"; mkdir -p "$H/state"
scratch_install_closure bin/lib/suite-preflight.sh "$H" >/dev/null || bad "cannot install bin/lib/suite-preflight.sh into the scratch harness"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
export LANE_GATE_NOW="$NOW"
cat > "$H/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ALERTS.log"
exit 0
EOF
chmod +x "$H/bin/alert-line.sh"

# $T/sys: every command on PATH except the four package tools, as links.
SYS="$T/sys"; mkdir -p "$SYS"
IFS=: read -r -a _dirs <<<"$PATH"
for _d in "${_dirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _n=${_f##*/}
    case "$_n" in npm|npx|pnpm|pnpx|yarn|yarnpkg|corepack) continue ;; esac
    [ -x "$_f" ] && [ ! -d "$_f" ] && [ ! -e "$SYS/$_n" ] && ln -s "$_f" "$SYS/$_n" 2>/dev/null
  done
done
unset _dirs _d _f _n

# The stubs. Each logs "<tool> <args>" to $T/calls.log. An install exits
# INST_RC and makes node_modules/x only when INST_MAKES=1. `npm run test*`
# exits 0. corepack runs nothing: it logs and acts as the install.
STUBS="$T/stubs"; mkdir -p "$STUBS"
for _t in npm pnpm yarn corepack; do
  cat > "$STUBS/$_t" <<EOF
#!/bin/bash
printf '%s %s\n' "$_t" "\$*" >> "$T/calls.log"
[ "$_t" = npm ] && [ "\$1" = run ] && { echo 'npm stub suite'; exit 0; }
[ "\${INST_MAKES:-0}" = 1 ] && mkdir -p node_modules/x
exit \${INST_RC:-0}
EOF
  chmod +x "$STUBS/$_t"
done
unset _t

# tools <name>... -> a fresh $T/bin with only those stubs; PATH for a case is
# "$T/bin:$SYS".
tools() {
  scratch_rm "$T/bin"; mkdir -p "$T/bin"
  local t
  for t in "$@"; do ln -s "$STUBS/$t" "$T/bin/$t"; done
}

DEPS='{"scripts":{"test":"vitest run"},"dependencies":{"a":"1"},"devDependencies":{"vitest":"1"}}'
DEPS_PM='{"packageManager":"pnpm@9.15.0","scripts":{"test":"vitest run"},"dependencies":{"a":"1"}}'
REPO="$T/repo"; BUILD="$T/build"
# fx <package.json text> [pnpm|yarn|npm|berry]... -> a fresh $REPO
fx() {
  scratch_rm "$REPO"; mkdir -p "$REPO"
  printf '%s\n' "$1" > "$REPO/package.json"; shift
  local a
  for a in "$@"; do
    case "$a" in
      pnpm)  echo 'lockfileVersion: 9.0' > "$REPO/pnpm-lock.yaml" ;;
      yarn)  echo '# yarn lockfile v1' > "$REPO/yarn.lock" ;;
      npm)   echo '{}' > "$REPO/package-lock.json" ;;
      berry) echo 'nodeLinker: node-modules' > "$REPO/.yarnrc.yml" ;;
    esac
  done
}

# inst -> "<SP_SETUP>|<rc>" from sp_install on $REPO under PATH=$T/bin:$SYS
inst() {
  : > "$T/calls.log"; : > "$T/inst.log"
  ( export HARNESS="$H" PATH="$T/bin:$SYS"
    # shellcheck source=/dev/null
    . "$H/bin/lib/suite-preflight.sh" || exit 9
    sp_install "$REPO" "$T/inst.log"; rc=$?
    printf '%s|%s' "$SP_SETUP" "$rc" ) 2>"$T/inst.err"
}
want() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', want '$3'"; }
no_npm_install() { grep -qE '^npm (ci|install|i)( |$)' "$T/calls.log" && bad "$1 npm install ran on a non-npm repo: $(cat "$T/calls.log")" || ok; }

# ── U1-U12: sp_install ──
# U1: pnpm-lock.yaml only, pnpm on PATH, no packageManager: pnpm, never npm.
tools npm pnpm yarn; fx "$DEPS" pnpm
want U1 "$(inst)" "pnpm install --frozen-lockfile (rc=0)|0"
grep -qx 'pnpm install --frozen-lockfile' "$T/calls.log" && ok || bad "U1 pnpm call: $(cat "$T/calls.log")"
no_npm_install U1
# U2: the real rc of the pnpm install is the rc.
tools npm pnpm; fx "$DEPS" pnpm
got=$(INST_RC=1 inst); want U2 "$got" "pnpm install --frozen-lockfile (rc=1)|1"
no_npm_install U2
# U3: packageManager in package.json and corepack on PATH: through corepack.
tools npm pnpm corepack; fx "$DEPS_PM" pnpm
want U3 "$(inst)" "corepack pnpm install --frozen-lockfile (rc=0)|0"
grep -qx 'corepack pnpm install --frozen-lockfile' "$T/calls.log" && ok || bad "U3 corepack call: $(cat "$T/calls.log")"
grep -q '^pnpm ' "$T/calls.log" && bad "U3 pnpm ran outside corepack: $(cat "$T/calls.log")" || ok
# U4: packageManager but no corepack: the pnpm on PATH.
tools npm pnpm; fx "$DEPS_PM" pnpm
want U4 "$(inst)" "pnpm install --frozen-lockfile (rc=0)|0"
# U5: no pnpm on PATH, corepack on PATH: through corepack.
tools npm corepack; fx "$DEPS" pnpm
want U5 "$(inst)" "corepack pnpm install --frozen-lockfile (rc=0)|0"
no_npm_install U5
# U6: no pnpm and no corepack: rc 127, the tool named, npm never runs.
tools npm yarn; fx "$DEPS" pnpm
want U6 "$(inst)" "pnpm install --frozen-lockfile (rc=127) [pnpm not found on this box]|127"
no_npm_install U6
[ -s "$T/calls.log" ] && bad "U6 a tool ran: $(cat "$T/calls.log")" || ok
grep -q 'pnpm not found on this box' "$T/inst.log" && ok || bad "U6 the setup log must name the tool: $(cat "$T/inst.log")"
# U7: yarn.lock (classic): yarn install --frozen-lockfile.
tools npm yarn; fx "$DEPS" yarn
want U7 "$(inst)" "yarn install --frozen-lockfile (rc=0)|0"
no_npm_install U7
# U8: yarn.lock and .yarnrc.yml (berry): yarn install --immutable.
tools npm yarn; fx "$DEPS" yarn berry
want U8 "$(inst)" "yarn install --immutable (rc=0)|0"
# U9: yarn.lock, no yarn, no corepack: rc 127, yarn named.
tools npm; fx "$DEPS" yarn
want U9 "$(inst)" "yarn install --frozen-lockfile (rc=127) [yarn not found on this box]|127"
no_npm_install U9
# U10: package-lock.json: npm ci, byte for byte as before BH-10128.
tools npm pnpm yarn; fx "$DEPS" npm
want U10 "$(inst)" "npm ci --no-audit --no-fund (rc=0)|0"
grep -qx 'npm ci --no-audit --no-fund' "$T/calls.log" && ok || bad "U10 npm ci call: $(cat "$T/calls.log")"
# U11: no lock file: npm install with no lockfile written, as before.
tools npm pnpm yarn; fx "$DEPS"
want U11 "$(inst)" "npm install --no-audit --no-fund --no-package-lock (rc=0)|0"
# U12: more than one lock file: pnpm, then yarn, then npm, and the line says so.
tools npm pnpm yarn; fx "$DEPS" pnpm yarn npm
want U12 "$(inst)" "pnpm install --frozen-lockfile (rc=0) [pnpm-lock.yaml chosen over yarn.lock package-lock.json]|0"
no_npm_install U12
tools npm pnpm yarn; fx "$DEPS" yarn npm
want U12b "$(inst)" "yarn install --frozen-lockfile (rc=0) [yarn.lock chosen over package-lock.json]|0"

# ── E1-E3: the build arm ──
calm() { rm -f "$T/ALERTS.log"; scratch_rm "$H/state/suite-preflight"; }
run() {
  scratch_rm "$BUILD"; mkdir -p "$BUILD"; : > "$T/calls.log"
  ( cd "$REPO" || exit 1
    export PATH="$T/bin:$SYS" HARNESS="$H" BUILD PROJECT=project-3 KEY=K-1 TEST_SELECT=0 SUITE_PREFLIGHT_TODAY=20261125
    STAMP() { echo 2026-11-25T00:00:00Z; }
    STAGE_START() { echo 1; }
    STAGE_END() { :; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
  return 0
}
F="$BUILD/harness-suite.txt"
last() { tail -n 1 "$F"; }
# E1: an project-3-shaped repo (pnpm-lock.yaml only) on a box with pnpm.
calm; tools npm pnpm; fx "$DEPS" pnpm; INST_MAKES=1 run
grep -qx 'HARNESS_PREFLIGHT: setup pnpm install --frozen-lockfile (rc=0)' "$F" && ok || bad "E1 setup line: $(cat "$F")"
grep -q '^npm run test' "$T/calls.log" && ok || bad "E1 the suite must run after the pnpm install: $(cat "$T/calls.log")"
no_npm_install E1
[ "$(last)" = 'HARNESS_EXIT: 0' ] && ok || bad "E1 last line: $(last)"
[ -s "$T/ALERTS.log" ] && bad "E1 a ready box alerted: $(cat "$T/ALERTS.log")" || ok
# E2: the same repo on a box with no pnpm and no corepack.
calm; tools npm; fx "$DEPS" pnpm; INST_MAKES=1 run
no_npm_install E2
grep -qx 'HARNESS_PREFLIGHT: setup pnpm install --frozen-lockfile (rc=127) \[pnpm not found on this box\]' "$F" && ok || bad "E2 setup line: $(cat "$F")"
[ "$(last)" = 'HARNESS_EXIT: could-not-run: node_modules' ] && ok || bad "E2 last line: $(last)"
grep -q 'project-3/K-1.*could-not-run: node_modules.*pnpm not found on this box.*Infra, not a PR finding' "$T/ALERTS.log" 2>/dev/null && ok || bad "E2 the alert must name the tool and say infra: $(cat "$T/ALERTS.log" 2>/dev/null)"
grep -q 'preflight: setup pnpm install --frozen-lockfile (rc=127) \[pnpm not found on this box\]' "$BUILD/pipeline.log" && ok || bad "E2 pipeline.log: $(cat "$BUILD/pipeline.log")"
# E3: a package-lock.json repo: the BH-7695 bytes.
calm; tools npm pnpm; fx "$DEPS" npm; INST_MAKES=1 run
grep -qx 'HARNESS_PREFLIGHT: setup npm ci --no-audit --no-fund (rc=0)' "$F" && ok || bad "E3 setup line: $(cat "$F")"
[ "$(last)" = 'HARNESS_EXIT: 0' ] && ok || bad "E3 last line: $(last)"

echo "suite-preflight-pm.bh-10128: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
