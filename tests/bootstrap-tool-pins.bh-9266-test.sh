#!/bin/bash
# tests/bootstrap-tool-pins.bh-9266-test.sh — bin/bootstrap-machine.sh installs
# Bun, Playwright and CodeGraph at pinned versions through
# bin/lib/bootstrap-tool-pins.sh, and a missing pin never stops the bootstrap.
#
# WHY (BH-9266). An outside audit (cromford-ai/cromford#5, #6) found Bun from
# `curl bun.sh/install | bash`, CodeGraph from its `main` install script and
# Playwright with no version. The audit's own fix ran FATAL `exit 1` when a
# box had no jobs credentials, before git identity was set.
#
#   P1  rows present: the installed versions equal the bake.*.version rows, 0 WARN
#   P2  no jobs credentials (the REAL jobs client, empty env): rc 0, the
#       fallback versions install, exactly one WARN line per tool
#   P3  Bun checksum mismatch / asset not listed: ERROR, rc 1, no bun in the
#       destination, the downloaded file never ran, no temp dir left
#   P4  grep: no `curl ... | bash` or `| sh` in bin/bootstrap-machine.sh
#   P5  the `# >>> tool pins` block as shipped, under set -euo pipefail, every
#       download failing: rc 0 and the next line runs; git identity comes first;
#       library absent: WARN and rc 0
#   P6  already at the pin: no download; 1.4.20 vs pin 1.4.2: install runs
#   P7  row edge cases: v1.5.1, latest, 1.4, outage (rc 1), no row (rc 2)
#   P8  Bun asset: aarch64, x64 with avx2, x64 with avx512f only, no flags line
#
# Zero network: curl, npm and npx are PATH stubs. The curl stub serves files
# from the case's fixture dir only and fails any other URL. The jobs worker is
# never called: a stub setting_get, or no credentials at all (P2, P5).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/bootstrap-tool-pins.bh-9266-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/bootstrap-tool-pins.sh"
BM="$DIR/bin/bootstrap-machine.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# unzip and sha256sum are what the library itself needs; a box without them
# cannot run the code under test, so the suite fails rather than skips.
for c in unzip sha256sum; do
  command -v "$c" >/dev/null || { echo "FAIL: $c missing"; exit 1; }
done
# zip_dir <zip> <dir-name> (run in the parent of <dir-name>): zip, or python3's
# zipfile where zip is absent.
zip_dir() {
  if command -v zip >/dev/null; then zip -q -r "$1" "$2"; return; fi
  python3 -I -c 'import sys,os,zipfile
z=zipfile.ZipFile(sys.argv[1],"w")
for r,_,fs in os.walk(sys.argv[2]):
    for f in fs: z.write(os.path.join(r,f))
z.close()' "$1" "$2"
}

# new_case <id> -> sets C (case dir) with fix/ (release fixtures), bin/ (stubs),
# dest/ (BTP_BUN_DEST), npm-prefix/, tmp/ (TMPDIR), hd/ (BTP_HARNESS_DIR).
new_case() {
  C="$T/$1"; mkdir -p "$C/fix" "$C/bin" "$C/dest" "$C/npm-prefix/bin" "$C/tmp" "$C/hd/lib"
  : > "$C/curl.log"; : > "$C/npm.log"; : > "$C/npx.log"
  # curl: -o <file> <url>; the URL must be a file:// under fix/, else rc 22.
  cat > "$C/bin/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac
done
echo "\$url" >> "$C/curl.log"
case "\$url" in file://$C/fix/*) f="\${url#file://}" ;; *) exit 22 ;; esac
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
EOF
  # npm: logs; `prefix -g` prints the case prefix; install -g <pkg>@<v> drops a
  # binary that reports <v>. NPM_FAIL=1 makes every install fail.
  cat > "$C/bin/npm" <<EOF
#!/bin/bash
echo "npm \$*" >> "$C/npm.log"
if [ "\$1" = prefix ]; then echo "$C/npm-prefix"; exit 0; fi
if [ "\$1" = install ]; then
  for a in "\$@"; do
    case "\$a" in
      @colbymchenry/codegraph@*) b=codegraph; v="\${a##*@}" ;;
      playwright@*) b=playwright; v="\${a##*@}" ;;
      *) continue ;;
    esac
    [ -n "\${NPM_FAIL:-}" ] && exit 1
    printf '#!/bin/bash\necho "Version %s"\n' "\$v" > "$C/npm-prefix/bin/\$b"; chmod +x "$C/npm-prefix/bin/\$b"
  done
fi
exit 0
EOF
  # npx: logs; `npx --yes playwright@<v> --version` prints "Version <v>".
  cat > "$C/bin/npx" <<EOF
#!/bin/bash
echo "npx \$*" >> "$C/npx.log"
pkg=""; for a in "\$@"; do case "\$a" in playwright@*) pkg="\$a" ;; esac; done
for a in "\$@"; do [ "\$a" = --version ] && echo "Version \${pkg##*@}"; done
exit 0
EOF
  chmod +x "$C/bin/"*
  # The real readers, behind a stub jobs client (rows_client writes it).
  ln -sf "$DIR/bin/lib/cli-version.sh" "$C/hd/lib/cli-version.sh"
  ln -sf "$DIR/bin/lib/bake-deps.sh" "$C/hd/lib/bake-deps.sh"
  printf 'flags\t\t: fpu sse sse2 avx avx2\n' > "$C/cpuinfo"
  export BTP_BUN_RELEASE_BASE="file://$C/fix"
  export BTP_BUN_DEST="$C/dest"
  export TMPDIR="$C/tmp"
  export BTP_BUN_ARCH=x64          # never the box's own arch
  export BTP_CPUINFO="$C/cpuinfo"  # never the box's own cpuinfo
  export BTP_HARNESS_DIR="$C/hd"
}

# make_bun <version> [<sums-mode: good|bad|absent>] [<asset>] -> a release fixture
make_bun() {
  local v="$1" mode="${2:-good}" a="${3:-bun-linux-x64}" d="$C/fix/bun-v$1" s="$C/stage-$1"
  mkdir -p "$d" "$s/$a"
  printf '#!/bin/bash\ntouch "%s/ran"\necho "%s"\n' "$C" "$v" > "$s/$a/bun"
  chmod +x "$s/$a/bun"
  (cd "$s" && zip_dir "$d/$a.zip" "$a")
  case "$mode" in
    good)   (cd "$d" && sha256sum "$a.zip" >> SHASUMS256.txt) ;;
    bad)    echo "0000000000000000000000000000000000000000000000000000000000000000  $a.zip" > "$d/SHASUMS256.txt" ;;
    absent) echo "$(printf '1%.0s' $(seq 64))  bun-darwin-x64.zip" > "$d/SHASUMS256.txt" ;;
  esac
}

# rows_client <bun> <codegraph> <playwright> [rc] -> the stub jobs client in
# hd/. A value "-" means no row (rc 2); a non-empty rc overrides every answer.
rows_client() {
  cat > "$C/hd/jobs-client.sh" <<EOF
setting_get() {
  [ -n "${4:-}" ] && return ${4:-0}
  local v=""
  case "\$1" in
    bake.bun.version) v='$1' ;;
    bake.codegraph.version) v='$2' ;;
    bake.playwright.version) v='$3' ;;
  esac
  [ "\$v" = - ] && return 2
  printf '%s' "\$v"
}
EOF
}

# run_lib <cmd...> -> runs the library in a clean bash with the case's PATH;
# out in $C/out, err in $C/err, rc in RC.
run_lib() {
  PATH="$C/dest:$C/bin:$C/npm-prefix/bin:/usr/bin:/bin" bash -c '. "$1" || exit 99; shift; "$@"' _ "$LIB" "$@" \
    > "$C/out" 2> "$C/err"; RC=$?
}

[ -f "$LIB" ] || bad "bin/lib/bootstrap-tool-pins.sh does not exist"

# ---- P1 rows present --------------------------------------------------------
new_case P1; rows_client 1.4.3 1.5.1 1.49.0; make_bun 1.4.3
run_lib btp_ensure_all
[ "$RC" = 0 ] && ok || bad "P1 rc $RC"
[ "$("$C/dest/bun" --version 2>/dev/null)" = 1.4.3 ] && ok || bad "P1 bun in dest is not 1.4.3"
[ "$(readlink "$C/dest/bunx" 2>/dev/null)" = bun ] && ok || bad "P1 bunx does not link to bun"
grep -q 'install -g @colbymchenry/codegraph@1.5.1' "$C/npm.log" && ok || bad "P1 codegraph@1.5.1 not installed: $(cat "$C/npm.log")"
grep -q 'install -g playwright@1.49.0' "$C/npm.log" && ok || bad "P1 playwright@1.49.0 not installed"
grep -q 'playwright@1.49.0 install --with-deps chromium' "$C/npx.log" && ok || bad "P1 browsers not installed at 1.49.0: $(cat "$C/npx.log")"
[ "$(cat "$C/out" "$C/err" | grep -c WARN)" = 0 ] && ok || bad "P1 WARN lines: $(cat "$C/err")"
for t in "bun 1.4.3" "codegraph 1.5.1" "playwright 1.49.0"; do
  grep -q "bootstrap pin: $t installed" "$C/out" && ok || bad "P1 no '$t installed' line"
done
echo "P1 done"

# ---- P2 no jobs credentials (real jobs client) ------------------------------
new_case P2; make_bun 1.4.2
mkdir -p "$C/harness" "$C/envdir"
unset BTP_HARNESS_DIR   # the library's own bin/: the real jobs client
PATH="$C/dest:$C/bin:$C/npm-prefix/bin:/usr/bin:/bin" env -u HARNESS_SECRET -u HARNESS_SECRET_FILE \
  HARNESS="$C/harness" HARNESS_ENV_DIR="$C/envdir" JOBS_URL= \
  bash -c '. "$1" || exit 99; btp_ensure_all' _ "$LIB" > "$C/out" 2> "$C/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "P2 rc $RC"
[ "$("$C/dest/bun" --version 2>/dev/null)" = 1.4.2 ] && ok || bad "P2 bun fallback 1.4.2 not installed"
grep -q '@colbymchenry/codegraph@1.5.0' "$C/npm.log" && ok || bad "P2 codegraph fallback 1.5.0 not installed"
grep -q 'playwright@1.48.2' "$C/npm.log" && ok || bad "P2 playwright fallback 1.48.2 not installed"
[ "$(grep -c 'WARN: bootstrap pin:' "$C/err")" = 3 ] && ok || bad "P2 want 3 WARN lines, got: $(cat "$C/err")"
for n in bun codegraph playwright; do
  [ "$(grep -c "WARN: bootstrap pin: bake.$n.version" "$C/err")" = 1 ] && ok || bad "P2 not one WARN for $n"
done
grep -q . <<<"$(grep -v "^file://$C/fix/" "$C/curl.log")" && bad "P2 a URL outside the fixtures: $(cat "$C/curl.log")" || ok
echo "P2 done"

# ---- P3 Bun checksum mismatch -----------------------------------------------
for mode in bad absent; do
  new_case "P3-$mode"; make_bun 1.4.2 "$mode"
  run_lib btp_install_bun 1.4.2 "$C/dest"
  [ "$RC" = 1 ] && ok || bad "P3 $mode rc $RC (want 1)"
  grep -q 'ERROR: bun' "$C/err" && grep -q 'sha256' "$C/err" && ok || bad "P3 $mode no ERROR sha256 line: $(cat "$C/err")"
  [ -z "$(ls -A "$C/dest")" ] && ok || bad "P3 $mode files in dest: $(ls -A "$C/dest")"
  [ ! -e "$C/ran" ] && ok || bad "P3 $mode the downloaded bun ran"
  [ -z "$(ls -A "$C/tmp")" ] && ok || bad "P3 $mode temp left: $(ls -A "$C/tmp")"
  # Through btp_ensure the mismatch is a WARN and rc 0.
  rows_client 1.4.2 1.5.0 1.48.2
  run_lib btp_ensure bun
  [ "$RC" = 0 ] && [ "$(grep -c 'WARN: bootstrap pin: bun 1.4.2 not installed' "$C/err")" = 1 ] && ok \
    || bad "P3 $mode btp_ensure rc $RC: $(cat "$C/err")"
  [ ! -e "$C/ran" ] && [ ! -e "$C/dest/bun" ] && ok || bad "P3 $mode btp_ensure ran or installed the bad bun"
done
echo "P3 done"

# ---- P4 grep: no pipe-to-shell installers -----------------------------------
if grep -nE 'curl[^#]*\|[[:space:]]*(ba)?sh\b' "$BM" "$LIB"; then bad "P4 curl | sh remains"; else ok; fi
grep -n 'bun.sh/install' "$BM" "$LIB" && bad "P4 bun.sh/install remains" || ok
grep -n 'codegraph/main/install.sh' "$BM" "$LIB" && bad "P4 codegraph install.sh remains" || ok
grep -nE 'npm install -g playwright([[:space:]]|$)' "$BM" && bad "P4 unpinned playwright remains" || ok
c=$(grep -cw exit "$LIB" 2>/dev/null); [ "$c" = 0 ] && ok || bad "P4 the library has $c exit line(s)"
echo "P4 done"

# ---- P5 the block as shipped ------------------------------------------------
new_case P5
blk=$(sed -n '/^# >>> tool pins/,/^# <<< tool pins/p' "$BM")
[ -n "$blk" ] && ok || bad "P5 no '# >>> tool pins' block in bootstrap-machine.sh"
mline=$(grep -n '^# >>> tool pins' "$BM" | head -1 | cut -d: -f1)
gline=$(grep -n 'gi_ensure_global' "$BM" | head -1 | cut -d: -f1)
[ -n "$mline" ] && [ -n "$gline" ] && [ "$gline" -lt "$mline" ] && ok || bad "P5 git identity (line $gline) is not before the pins (line $mline)"
printf '%s\necho AFTER\n' "$blk" > "$C/block.sh"
unset BTP_HARNESS_DIR
# Every download fails (no fixture), every npm install fails.
PATH="$C/bin:$C/npm-prefix/bin:/usr/bin:/bin" NPM_FAIL=1 env -u HARNESS_SECRET -u HARNESS_SECRET_FILE \
  HARNESS="$C" HARNESS_ENV_DIR="$C" JOBS_URL= HERE="$DIR/bin" \
  bash -c 'set -euo pipefail; . "$1"' _ "$C/block.sh" > "$C/out" 2> "$C/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "P5 block rc $RC: $(cat "$C/err")"
grep -q '^AFTER$' "$C/out" && ok || bad "P5 the line after the block did not run"
[ "$(grep -c 'WARN: bootstrap pin: .* not installed' "$C/err")" = 3 ] && ok || bad "P5 want 3 'not installed' WARN lines: $(cat "$C/err")"
# Library absent.
mkdir -p "$C/nolib"
PATH="$C/bin:/usr/bin:/bin" HERE="$C/nolib" bash -c 'set -euo pipefail; . "$1"' _ "$C/block.sh" > "$C/out2" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q '^AFTER$' "$C/out2" && grep -q 'WARN: bin/lib/bootstrap-tool-pins.sh not found' "$C/out2" && ok \
  || bad "P5 library absent rc $RC: $(cat "$C/out2")"
echo "P5 done"

# ---- P6 already installed ---------------------------------------------------
new_case P6; rows_client 1.4.2 1.5.0 1.48.2; make_bun 1.4.2
printf '#!/bin/bash\necho 1.4.2\n' > "$C/dest/bun"; chmod +x "$C/dest/bun"
run_lib btp_ensure bun
[ "$RC" = 0 ] && grep -q 'bootstrap pin: bun 1.4.2 already installed' "$C/out" && ok || bad "P6 no skip line: $(cat "$C/out" "$C/err")"
[ -s "$C/curl.log" ] && bad "P6 curl ran for an installed pin: $(cat "$C/curl.log")" || ok
printf '#!/bin/bash\necho 1.4.20\n' > "$C/dest/bun"
run_lib btp_ensure bun
[ "$("$C/dest/bun" --version)" = 1.4.2 ] && grep -q 'bootstrap pin: bun 1.4.2 installed' "$C/out" && ok || bad "P6 1.4.20 was not replaced by 1.4.2"
# npm tools at the pin: no npm install, browsers still ensured.
printf '#!/bin/bash\necho 1.5.0\n' > "$C/npm-prefix/bin/codegraph"; printf '#!/bin/bash\necho "Version 1.48.2"\n' > "$C/npm-prefix/bin/playwright"
chmod +x "$C/npm-prefix/bin/"*; : > "$C/npm.log"; : > "$C/npx.log"
run_lib btp_ensure codegraph; run_lib btp_ensure playwright
grep -q 'install' "$C/npm.log" && bad "P6 npm install ran for pinned tools: $(cat "$C/npm.log")" || ok
grep -q 'playwright@1.48.2 install --with-deps chromium' "$C/npx.log" && ok || bad "P6 browsers not ensured when playwright is at the pin"
echo "P6 done"

# ---- P7 row edge cases ------------------------------------------------------
new_case P7
chk() { # <bun-row> <rc-override> <want-version> <want-warn-substring or ->
  rows_client "$1" 1.5.0 1.48.2 "$2"
  run_lib btp_version bun
  [ "$RC" = 0 ] && [ "$(cat "$C/out")" = "$3" ] && ok || bad "P7 row '$1' rc '$2': got '$(cat "$C/out")' rc $RC, want $3"
  if [ "$4" = - ]; then
    grep -q WARN "$C/err" && bad "P7 row '$1': unexpected WARN $(cat "$C/err")" || ok
  else
    grep -q "WARN: bootstrap pin: bake.bun.version $4; using fallback 1.4.2" "$C/err" && ok || bad "P7 row '$1' rc '$2': want WARN '$4', got $(cat "$C/err")"
  fi
}
chk 1.4.3 "" 1.4.3 -
chk v1.5.1 "" 1.5.1 -
chk latest "" 1.4.2 "not a version"
chk 1.4 "" 1.4.2 "not a version"
chk 1.4.3 1 1.4.2 "unreachable"
chk - "" 1.4.2 "no row"
rm -f "$C/hd/jobs-client.sh"
run_lib btp_version bun
[ "$(cat "$C/out")" = 1.4.2 ] && grep -q 'WARN: bootstrap pin: bake.bun.version jobs client not loadable' "$C/err" && ok \
  || bad "P7 client not loadable: $(cat "$C/out" "$C/err")"
echo "P7 done"

# ---- P8 Bun asset -----------------------------------------------------------
asset_case() { # <id> <arch> <cpuinfo line or -> <want asset>
  new_case "P8-$1"; rows_client 1.4.2 1.5.0 1.48.2; make_bun 1.4.2 good "$4"
  export BTP_BUN_ARCH="$2"
  if [ "$3" = - ]; then : > "$C/cpuinfo"; else printf '%s\n' "$3" > "$C/cpuinfo"; fi
  run_lib btp_ensure bun
  grep -q "/bun-v1.4.2/$4.zip\$" "$C/curl.log" && ok || bad "P8 $1 want $4.zip, curl got: $(cat "$C/curl.log")"
  [ "$("$C/dest/bun" --version 2>/dev/null)" = 1.4.2 ] && ok || bad "P8 $1 bun not installed from $4: $(cat "$C/err")"
}
asset_case aarch64 aarch64 - bun-linux-aarch64
asset_case avx2 x64 'flags		: sse avx2' bun-linux-x64
asset_case avx512 x64 'flags		: sse avx512f' bun-linux-x64-baseline
asset_case noflags x64 - bun-linux-x64-baseline
echo "P8 done"

echo "bootstrap-tool-pins.bh-9266: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
