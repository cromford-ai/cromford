#!/bin/bash
# tests/bootstrap-machine-pnpm.bh-7715-test.sh — bm_repos in
# bin/bootstrap-machine.sh installs a Node repo with the package manager its
# lockfile names.
#
# WHY (2026-10-21 05:28Z). A `bin/hub-move.sh dry-run` seed on the new Fly hub
# ran `bootstrap-machine project-1 --repos-only`. bm_repos ran `npm install`
# on every repo with a package.json. project-1 is a pnpm repo (pnpm-lock.yaml,
# and a pnpm-only overrides key "@clerk/themes>@clerk/shared"), so npm stopped
# with EINVALIDPACKAGENAME and the seed failed.
#
#   P1  pnpm-lock.yaml: pnpm install --frozen-lockfile runs, npm does not
#   P2  package-lock.json: npm install runs, pnpm does not (as before)
#   P3  yarn.lock: yarn install --frozen-lockfile runs, npm does not
#   P4  pnpm-lock.yaml, no pnpm on PATH: corepack enable pnpm runs, then pnpm
#   P5  pnpm-lock.yaml, no pnpm and no corepack: rc != 0, the error names the
#       project, npm does not run
#
# Driven, not grepped: the REAL script in a scratch root (every /root/ and
# /etc/harness path moved under it), run --repos-only against logging PATH stubs.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/bootstrap-machine-pnpm.bh-7715-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

R="$T/root"; E="$T/etc-harness"
mkdir -p "$R/harness/bin/lib" "$T/fakebin" "$T/origin" "$T/sysbin"
for f in bootstrap-machine.sh fleet-conf.sh gh-token.sh migrate-env-dir.sh box-for.sh harden-state.sh; do
  [ -f "$DIR/bin/$f" ] || continue
  scratch_install_closure "bin/$f" "$R/harness" >/dev/null || { echo "FAIL: closure install of bin/$f"; exit 1; }
done
find "$R/harness/bin" -type f -name '*.sh' -exec sed -i -e "s|/root/|$R/|g" -e "s|/etc/harness|$E|g" {} +
cp "$DIR/fleet.conf" "$R/harness/fleet.conf"
BM="$R/harness/bin/bootstrap-machine.sh"

# Logging stubs. corepack enable pnpm installs a pnpm stub, like the real one.
for c in npm pnpm yarn codegraph crontab node claude; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$c" "$T" > "$T/fakebin/$c"
done
cat > "$T/fakebin/corepack" <<EOF
#!/bin/bash
echo "corepack \$*" >> "$T/calls.log"
if [ "\$1" = enable ]; then cp "$T/pnpm.stub" "$T/fakebin/\${2:-pnpm}"; chmod +x "$T/fakebin/\${2:-pnpm}"; fi
exit 0
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$T/calls.log"
if [ "\$1 \$2" = "repo clone" ]; then git clone -q "$T/origin/\${3##*/}" "\$4"; exit \$?; fi
exit 0
EOF
chmod +x "$T"/fakebin/*
cp "$T/fakebin/pnpm" "$T/pnpm.stub"

# A system PATH with no real npm/pnpm/yarn/corepack, so a stub removed from
# fakebin is really gone (the test host may have a real pnpm).
IFS=: read -ra _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n=${f##*/}
    case "$n" in npm|npx|pnpm|pnpx|yarn|corepack|codegraph) continue ;; esac
    [ -x "$f" ] && [ ! -e "$T/sysbin/$n" ] && ln -s "$f" "$T/sysbin/$n"
  done
done

# origin_with <lockfile>: a fresh local origin with package.json and that lockfile.
origin_with() {
  scratch_rm "$T/origin/cromford" 2>/dev/null; scratch_rm "$R/repos" 2>/dev/null
  git init -q "$T/origin/cromford"
  echo '{"name":"x","version":"1.0.0"}' > "$T/origin/cromford/package.json"
  : > "$T/origin/cromford/$1"
  git -C "$T/origin/cromford" add -A
  git -C "$T/origin/cromford" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  : > "$T/calls.log"
}
run() { ( export PATH="$T/fakebin:$T/sysbin" HARNESS="$R/harness" HOME="$R"; unset GH_TOKEN
          bash "$BM" cromford --repos-only ) > "$T/out" 2>&1; echo $?; }

echo "== P1: pnpm-lock.yaml =="
origin_with pnpm-lock.yaml; RC=$(run)
[ "$RC" = 0 ] && ok || bad "P1 rc $RC, want 0: $(tail -3 "$T/out")"
grep -qx 'pnpm install --frozen-lockfile' "$T/calls.log" && ok || bad "P1 pnpm install --frozen-lockfile did not run: $(cat "$T/calls.log")"
grep -q '^npm ' "$T/calls.log" && bad "P1 npm ran on a pnpm repo: $(grep '^npm ' "$T/calls.log")" || ok

echo "== P2: package-lock.json =="
origin_with package-lock.json; RC=$(run)
[ "$RC" = 0 ] && ok || bad "P2 rc $RC, want 0: $(tail -3 "$T/out")"
grep -qx 'npm install --no-audit --no-fund' "$T/calls.log" && ok || bad "P2 npm install did not run: $(cat "$T/calls.log")"
grep -q '^pnpm ' "$T/calls.log" && bad "P2 pnpm ran on an npm repo" || ok

echo "== P3: yarn.lock =="
origin_with yarn.lock; RC=$(run)
[ "$RC" = 0 ] && ok || bad "P3 rc $RC, want 0: $(tail -3 "$T/out")"
grep -qx 'yarn install --frozen-lockfile' "$T/calls.log" && ok || bad "P3 yarn install did not run: $(cat "$T/calls.log")"
grep -q '^npm ' "$T/calls.log" && bad "P3 npm ran on a yarn repo" || ok

echo "== P4: pnpm-lock.yaml, pnpm missing, corepack present =="
origin_with pnpm-lock.yaml; rm -f "$T/fakebin/pnpm"; RC=$(run)
[ "$RC" = 0 ] && ok || bad "P4 rc $RC, want 0: $(tail -3 "$T/out")"
grep -qx 'corepack enable pnpm' "$T/calls.log" && ok || bad "P4 corepack enable pnpm did not run: $(cat "$T/calls.log")"
grep -qx 'pnpm install --frozen-lockfile' "$T/calls.log" && ok || bad "P4 pnpm did not run after corepack: $(cat "$T/calls.log")"
grep -q '^npm ' "$T/calls.log" && bad "P4 npm ran on a pnpm repo" || ok

echo "== P5: pnpm-lock.yaml, no pnpm, no corepack =="
origin_with pnpm-lock.yaml; rm -f "$T/fakebin/pnpm"; mv "$T/fakebin/corepack" "$T/corepack.off"; RC=$(run)
mv "$T/corepack.off" "$T/fakebin/corepack"
[ "$RC" != 0 ] && ok || bad "P5 rc 0, want a failure when pnpm cannot be found"
grep -qE 'FATAL.*cromford.*pnpm' "$T/out" && ok || bad "P5 the error does not name the project and pnpm: $(tail -3 "$T/out")"
grep -q '^npm ' "$T/calls.log" && bad "P5 npm ran on a pnpm repo" || ok

echo "bootstrap-machine-pnpm.bh-7715: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
