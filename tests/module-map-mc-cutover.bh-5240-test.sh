#!/bin/bash
# tests/module-map-mc-cutover.bh-5240-test.sh — BH-5240 C1: the shim
# bin/lib/merge-conductor-lib.sh loads bin/lib/mc/ through the module map
# (mc/load.sh -> mm_load), never through a hand-written module list.
#
#   CU-0 load.sh parses and has no "# module:" header.
#   CU-1 the real shim on a closure scratch tree (no MODULES): rc 0, empty
#        stderr, the six modules defined from mc/<module>.sh, the order from
#        the headers, and no headerless mc file loaded as a module
#   CU-2 a MODULES whose valid order differs from the headers: MODULES wins
#   CU-3 a fifth module is one new file plus bin/module-map-build.sh --write:
#        the shim loads it, and the shim, load.sh and the modules are unchanged
#   CU-4 a listed module with no file, and a missing mc/module-map.sh: the shim
#        exits non-zero with a named message and its caller does not continue
#   CU-5 the loader is written once: mc/module-map.sh links ../module-map.sh
#   CU-6 scratch_closure_list of the shim reaches load.sh, the link and the
#        six modules
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIX="log locks classify queue rebase settle"

# tree <name> — a closure-installed scratch harness; sets H and MC.
tree() {
  H="$T/$1"; MC="$H/bin/lib/mc"
  scratch_rm "$H" || exit 1
  mkdir -p "$H/logs" "$H/state" "$H/locks"
  scratch_install_closure bin/lib/merge-conductor-lib.sh "$H" >/dev/null \
    || { bad "$1: scratch_install_closure failed"; return 1; }
}
# fakes — replace the six modules with fakes that keep their real header line
# and append their name to _mc_order when sourced.
fakes() {
  local m hdr
  for m in $SIX; do
    hdr=$(grep -m1 '^# module:' "$DIR/bin/lib/mc/$m.sh")
    printf '#!/bin/bash\n%s\n_mc_order="${_mc_order:-}%s "\n' "$hdr" "$m" > "$MC/$m.sh"
  done
}
# shim <body> — source the real shim of $H in a child bash, then run <body>.
# OUT = stdout, ERR = stderr, RC = rc.
shim() {
  OUT=$(cd "$T" && HARNESS="$H" timeout 60 bash -c '. "$1" || exit 3; '"$1"'; echo CONTINUED' \
    _ "$H/bin/lib/merge-conductor-lib.sh" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
sums() { (cd "$MC" && sha256sum ../merge-conductor-lib.sh load.sh module-map.sh $SIX_SH); }
SIX_SH=$(for m in $SIX; do printf '%s.sh ' "$m"; done)

# ---- CU-0 the bootstrap parses and is not itself a module -------------------
LOAD="$DIR/bin/lib/mc/load.sh"
bash -n "$LOAD" && ok || bad "CU-0 bin/lib/mc/load.sh does not parse"
grep -q '^# module:' "$LOAD" && bad "CU-0 load.sh has a '# module:' header; mm_load would source it as a module" || ok

# ---- CU-1 production entry, header fallback --------------------------------
tree cu1
[ ! -e "$MC/MODULES" ] && ok || bad "CU-1 the closure tree must have no MODULES (header fallback)"
# shellcheck disable=SC2016
shim 'shopt -s extdebug; declare -F mc_slug_of_url | cut -d" " -f3; for f in $(declare -F | cut -d" " -f3); do declare -F "$f"; done | cut -d" " -f3 | grep "/mc/[^.]" | sed "s#.*/mc/##; s#\.sh\$##" | sort -u | tr "\n" " "; echo'
[ "$RC" = 0 ] && ok || bad "CU-1 sourcing the shim: rc $RC (stderr: $ERR)"
[ -z "$ERR" ] && ok || bad "CU-1 a clean load must print nothing on stderr, got: $ERR"
[ "$(sed -n 1p <<<"$OUT")" = "$MC/classify.sh" ] && ok \
  || bad "CU-1 mc_slug_of_url must come from mc/classify.sh, got '$(sed -n 1p <<<"$OUT")'"
# block-ci.sh is the shim's own optional sibling, sourced after the modules.
# spawn-remote.sh (BH-6888) is another optional sibling of the shim.
[ "$(sed -n 2p <<<"$OUT")" = "block-ci classify locks log module-map queue rebase settle spawn-remote " ] && ok \
  || bad "CU-1 mc files that define functions: '$(sed -n 2p <<<"$OUT")'"
grep -qx CONTINUED <<<"$OUT" && ok || bad "CU-1 the caller must continue after a clean load"
fakes
shim 'echo "ORDER=${_mc_order:-}"'
[ "$RC" = 0 ] && grep -qx "ORDER=log locks classify queue rebase settle " <<<"$OUT" && ok \
  || bad "CU-1 header order: rc $RC, out '$OUT', err '$ERR'"

# ---- CU-2 MODULES wins ------------------------------------------------------
tree cu2 && fakes
printf '# test order\nlog\nlocks\nclassify\nqueue\nsettle\nrebase\n' > "$MC/MODULES"
shim 'echo "ORDER=${_mc_order:-}"'
[ "$RC" = 0 ] && grep -qx "ORDER=log locks classify queue settle rebase " <<<"$OUT" && ok \
  || bad "CU-2 the load must follow MODULES: rc $RC, out '$OUT', err '$ERR'"

# ---- CU-3 a fifth module needs no edit -------------------------------------
tree cu3
sums > "$T/before"
printf '#!/bin/bash\n# module: zz after: settle\nMM_ZZ_LOADED=1\n' > "$MC/zz.sh"
timeout 60 "$DIR/bin/module-map-build.sh" --root "$H" --write >"$T/bout" 2>&1 \
  && ok || bad "CU-3 module-map-build --write: $(cat "$T/bout")"
[ "$(grep -v '^#' "$MC/MODULES" 2>/dev/null | tr '\n' ' ')" = "log locks classify queue rebase settle zz " ] && ok \
  || bad "CU-3 the written MODULES: '$(cat "$MC/MODULES" 2>/dev/null)'"
shim 'echo "ZZ=${MM_ZZ_LOADED:-unset}"'
[ "$RC" = 0 ] && grep -qx "ZZ=1" <<<"$OUT" && ok \
  || bad "CU-3 the shim must load zz from MODULES: rc $RC, out '$OUT', err '$ERR'"
sums > "$T/after"
cmp -s "$T/before" "$T/after" && ok || bad "CU-3 the shim, load.sh or a module changed: $(diff "$T/before" "$T/after")"

# ---- CU-4 loud failure ------------------------------------------------------
tree cu4e
printf 'log\nlocks\nclassify\nqueue\nrebase\nsettle\n' > "$MC/MODULES"
rm -f "$MC/queue.sh"
shim 'echo LOADED'
[ "$RC" != 0 ] && ok || bad "CU-4e a listed module with no file must fail, rc $RC"
grep -q 'module queue' <<<"$ERR" && grep -q 'the mc modules did not load' <<<"$ERR" && ok \
  || bad "CU-4e stderr must name the module and the shim's message, got: $ERR"
! grep -q CONTINUED <<<"$OUT" && ok || bad "CU-4e the caller must not continue"
tree cu4g
rm -f "$MC/module-map.sh"
shim 'echo LOADED'
[ "$RC" != 0 ] && ok || bad "CU-4g a missing mc/module-map.sh must fail, rc $RC"
grep -q 'the mc modules did not load' <<<"$ERR" && ok || bad "CU-4g stderr must carry the shim's message, got: $ERR"
! grep -q CONTINUED <<<"$OUT" && ok || bad "CU-4g the caller must not continue"

# ---- CU-5 the loader is written once ----------------------------------------
L="$DIR/bin/lib/mc/module-map.sh"
if [ -L "$L" ]; then
  ok
  [ "$(readlink "$L")" = ../module-map.sh ] && ok || bad "CU-5 $L must link ../module-map.sh, got '$(readlink "$L")'"
  cmp -s "$L" "$DIR/bin/lib/module-map.sh" && ok || bad "CU-5 $L must resolve to bin/lib/module-map.sh"
else
  bad "CU-5 $L must be a symlink"
fi

# ---- CU-6 closure -------------------------------------------------------------
CL=$(cd "$DIR" && scratch_closure_list bin/lib/merge-conductor-lib.sh 2>&1)
for f in load module-map $SIX; do
  grep -qx "bin/lib/mc/$f.sh" <<<"$CL" && ok || bad "CU-6 the shim's closure must list bin/lib/mc/$f.sh"
done

echo "module-map-mc-cutover.bh-5240: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
