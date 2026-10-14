#!/bin/bash
# tests/ms-split-layout.bh-5242-test.sh — BH-5242: bin/merge-sweep.sh is a
# driver over bin/lib/ms/, the same "one module per function, the driver holds
# no logic" rule tests/mc-split-layout-test.sh and
# tests/br-split-layout.bh-5241-test.sh hold for bin/lib/mc/ and bin/lib/br/.
#
#   M1  every bin/lib/ms/*.sh but load.sh and module-map.sh has a "# module:"
#       header, passes bash -n and sources clean; module-map-build --check is
#       green on bin/lib/ms; load.sh defines every mapped name.
#   M2  no function is defined by two ms modules (runtime declare -F, each
#       module sourced alone in a clean bash).
#   M3  tests/ms/expected-map.tsv both ways: each row's function is defined by
#       the module the row names, and each function a module defines has a row.
#   M4  the driver defines none of the mapped names, and at most the `fns` row
#       of tests/ms/driver-ceiling.tsv column-0 functions. Read from source:
#       sourcing the driver runs a tick. An empty driver is a FAIL.
#   M5  byte for byte. The synthetic self-test always runs. With
#       MS_SPLIT_BASE=<rev> the mapped names' bodies in <rev> (driver plus
#       bin/lib/ms/) are compared with the working tree and the suite prints
#       `bodies: identical` or the difference. Env-gated: a permanent pin would
#       go red on every later PR that edits a body on purpose.
#   M6  the production entry point (D2): the real sweep, in a scratch harness,
#       sources its modules (a canary in the scratch terminal.sh), falls back to
#       $HARNESS/bin/lib/ms (M6b), and refuses the tick when bin/lib/ms/ is
#       missing (M6) or MODULES names a module with no file (M6c).
#   M7  the moved helpers answer through terminal.sh alone, and a cache line
#       the moved writer appends reads back through the driver's own load loop.
# Run from anywhere: tests/ms-split-layout.bh-5242-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SWEEP="$DIR/bin/merge-sweep.sh"
MSD="$DIR/bin/lib/ms"
MAP="$DIR/tests/ms/expected-map.tsv"
CEIL="$DIR/tests/ms/driver-ceiling.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The ms modules: every .sh but the bootstrap and the loader symlink.
ms_modules() {
  local f
  for f in "$1"/*.sh; do
    case "${f##*/}" in load.sh|module-map.sh) continue ;; esac
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}
# The functions a file defines, by runtime declare -F in a clean bash.
# rc 3 when the file does not source clean.
mod_fns() {
  env -i PATH="$PATH" bash -c '. "$1" >/dev/null 2>&1 || exit 3; declare -F | cut -d" " -f3' _ "$1" | LC_ALL=C sort
  return "${PIPESTATUS[0]}"
}
map_rows() { awk -F'\t' '!/^#/ && NF == 2 { print $1 "\t" $2 }' "$MAP"; }
static_defs() { sed -n -E 's/^([A-Za-z_][A-Za-z0-9_]*)[(][)].*/\1/p' "$1"; }
# One line per distinct column-0 function body: <name><TAB><sha256>. The opener
# is matched with bracket classes, never `\(` (gawk reads the escape back as a
# metacharacter). A function moved byte for byte gives the same line.
ms_bodies() {
  local f name body
  for f in "$@"; do [ -r "$f" ] || return 1; done
  awk '
    function esc(s) { gsub(/\\/, "\\\\", s); return s }
    function flush() { printf "%s\t%s\n", name, body; f = 0 }
    FNR == 1 { f = 0 }
    !f && /^[A-Za-z_][A-Za-z0-9_]*[(][)] [{]/ {
      name = $0; sub(/[(].*/, "", name); body = esc($0); f = 1
      if ($0 ~ /[}][[:space:]]*$/) flush()
      next
    }
    f { body = body "\\n" esc($0); if ($0 ~ /^[}]$/) flush() }
  ' "$@" | while IFS=$'\t' read -r name body; do
    printf '%s\t%s\n' "$name" "$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)"
  done | LC_ALL=C sort -u
}
# Only the bodies of the names in the map.
mapped_bodies() { ms_bodies "$@" | awk -F'\t' 'NR == FNR { want[$2] = 1; next } want[$1]' <(map_rows) -; }

[ -s "$MAP" ] && [ "$(map_rows | wc -l)" -gt 0 ] || { echo "FAIL: $MAP is missing or has no rows"; exit 1; }
MAPPED=$(map_rows | cut -f2 | LC_ALL=C sort)

# ── M1. headers, parse, sources clean, the map check ────────────────────────
for f in "$DIR/bin/lib/ms/load.sh" "$DIR/bin/lib/ms/terminal.sh" "$DIR/bin/lib/ms/module-map.sh"; do
  [ -r "$f" ] && bash -n "$f" && ok || bad "M1: ${f#"$DIR"/} is missing or does not parse"
done
MODS=$(ms_modules "$MSD")
[ -n "$MODS" ] && ok || bad "M1: bin/lib/ms/ holds no module"
for f in $MODS; do
  head -30 "$f" | grep -q '^# module: ' && ok || bad "M1: ${f#"$DIR"/} has no '# module:' header in its first 30 lines"
  bash -n "$f" && ok || bad "M1: ${f#"$DIR"/} does not parse"
  err=$(env -i PATH="$PATH" bash -c '. "$1"' _ "$f" 2>&1) && [ -z "$err" ] && ok || bad "M1: ${f#"$DIR"/} does not source clean: $err"
done
"$DIR/bin/module-map-build.sh" --root "$DIR" --check bin/lib/ms >/dev/null 2>"$T/mmb.err" && ok \
  || bad "M1: module-map-build.sh --check bin/lib/ms failed: $(cat "$T/mmb.err")"
LOADED=$(env -i PATH="$PATH" bash -c '. "$1" || exit 3; declare -F | cut -d" " -f3' _ "$DIR/bin/lib/ms/load.sh" | LC_ALL=C sort)
missing=$(comm -23 <(printf '%s\n' "$MAPPED") <(printf '%s\n' "$LOADED") | tr '\n' ' ')
[ -z "$missing" ] && ok || bad "M1: bin/lib/ms/load.sh does not define: $missing"

# ── M2. no name in two modules ──────────────────────────────────────────────
: > "$T/owners"
for f in $MODS; do
  fns=$(mod_fns "$f") || { bad "M2: ${f#"$DIR"/} does not source alone"; continue; }
  for fn in $fns; do printf '%s\t%s\n' "$fn" "$(basename "$f" .sh)" >> "$T/owners"; done
done
[ -s "$T/owners" ] && ok || bad "M2: the ms modules define no function"
dups=$(cut -f1 "$T/owners" | LC_ALL=C sort | uniq -d | tr '\n' ' ')
[ -z "$dups" ] && ok || bad "M2: defined by two ms modules: $dups"

# ── M3. the map both ways ───────────────────────────────────────────────────
while IFS=$'\t' read -r mod fn; do
  grep -qxF "$fn	$mod" "$T/owners" && ok || bad "M3: map row '$mod $fn': bin/lib/ms/$mod.sh does not define $fn"
done < <(map_rows)
while IFS=$'\t' read -r fn mod; do
  map_rows | grep -qxF "$mod	$fn" && ok || bad "M3: $fn (bin/lib/ms/$mod.sh) has no row in tests/ms/expected-map.tsv"
done < "$T/owners"

# ── M4. the driver holds none of the mapped names ───────────────────────────
DEFS=$(static_defs "$SWEEP" 2>/dev/null)
if [ -s "$SWEEP" ] && [ -n "$DEFS" ]; then
  ok
  inline=$(comm -12 <(printf '%s\n' "$MAPPED") <(printf '%s\n' "$DEFS" | LC_ALL=C sort) | tr '\n' ' ')
  [ -z "$inline" ] && ok || bad "M4: bin/merge-sweep.sh still defines mapped name(s): $inline"
  max=$(awk -F'\t' '$1 == "fns" { print $2 }' "$CEIL")
  n=$(printf '%s\n' "$DEFS" | wc -l)
  case "$max" in ''|*[!0-9]*) bad "M4: tests/ms/driver-ceiling.tsv has no numeric fns row" ;;
    *) [ "$n" -le "$max" ] && ok || bad "M4: bin/merge-sweep.sh defines $n column-0 functions, ceiling $max" ;; esac
else
  bad "M4: bin/merge-sweep.sh is empty or unreadable, or defines no function (a vacuous pass is a FAIL)"
fi

# ── M5. byte for byte ───────────────────────────────────────────────────────
S="$T/m5"; mkdir -p "$S/before" "$S/after"
cat > "$S/before/driver.sh" <<'EOF'
keep_fn() {
  echo keep
}
move_fn() { # moves
  echo "a\\b	tab"
}
one_fn() { echo one; }
EOF
printf 'dark_fn() {\n  :\n}\n' > "$S/before/mod.sh"
printf 'keep_fn() {\n  echo keep\n}\ndark_fn() {\n  :\n}\n' > "$S/after/driver.sh"
{ printf 'dark_fn() {\n  :\n}\n'; sed -n '/^move_fn/,/^}/p; /^one_fn/p' "$S/before/driver.sh"; } > "$S/after/mod.sh"
bset() { ms_bodies "$1/driver.sh" "$1/mod.sh"; }
BEFORE=$(bset "$S/before")
[ "$(printf '%s\n' "$BEFORE" | wc -l)" = 4 ] && ok || bad "M5: the fixture should give 4 bodies, got: $BEFORE"
[ "$BEFORE" = "$(bset "$S/after")" ] && ok || bad "M5: a pure move gave a different body set"
MUT=0
mutate() { MUT=$((MUT+1)); cp -r "$S/after" "$S/m$MUT"; sed -i "$1" "$S/m$MUT/mod.sh"; R=$(bset "$S/m$MUT"); [ "$R" != "$BEFORE" ]; }
mutate 's/a\\\\b/a\\\\c/' && ok || bad "M5: one changed byte gave the same body set"
mutate '/^one_fn/d' && ok || bad "M5: a dropped function gave the same body set"
mutate 's/^move_fn()/moved_fn()/' && ok || bad "M5: a renamed function gave the same body set"
if [ -n "${MS_SPLIT_BASE:-}" ]; then
  mkdir -p "$S/base/bin/lib/ms"
  if git -C "$DIR" show "$MS_SPLIT_BASE:bin/merge-sweep.sh" > "$S/base/driver.sh" 2>/dev/null; then
    for m in $(git -C "$DIR" ls-tree --name-only "$MS_SPLIT_BASE" bin/lib/ms/ | grep '\.sh$'); do
      git -C "$DIR" show "$MS_SPLIT_BASE:$m" > "$S/base/$m"
    done
    # shellcheck disable=SC2046 # the module list is word-split on purpose
    mapped_bodies "$S/base/driver.sh" $(ms_modules "$S/base/bin/lib/ms") > "$T/base.set"
    # shellcheck disable=SC2086
    mapped_bodies "$SWEEP" $MODS > "$T/head.set"
    if [ "$(wc -l < "$T/head.set")" = "$(map_rows | wc -l)" ] && cmp -s "$T/base.set" "$T/head.set"; then
      ok; echo "bodies: identical ($(wc -l < "$T/head.set") bodies, $MS_SPLIT_BASE vs working tree)"
    else
      bad "M5: the mapped body set differs from $MS_SPLIT_BASE (or misses a mapped name)"
      diff "$T/base.set" "$T/head.set" | head -20
    fi
  else
    bad "M5: MS_SPLIT_BASE=$MS_SPLIT_BASE has no bin/merge-sweep.sh"
  fi
fi

# ── M6. the production entry point ──────────────────────────────────────────
H6="$T/h6"
mkdir -p "$H6/logs" "$H6/state" "$H6/flags" "$H6/locks" "$H6/builds" "$H6/env" "$H6/fakebin" "$T/alt"
scratch_install_closure bin/merge-sweep.sh "$H6" >/dev/null || exit 1
scratch_install_closure bin/alert-line.sh "$H6" >/dev/null || exit 1
# bin/iron-law-guard.sh denies an agent session that runs the sweep by name, so
# the fixture runs it as sweep.sh, as tests/merge-sweep-async-test.sh does.
mv "$H6/bin/merge-sweep.sh" "$H6/bin/sweep.sh"
# cp -rL: MODULES rides along, and the loader symlink becomes a real file.
cp -rL "$DIR/bin/lib/ms" "$H6/bin/lib/" || exit 1
cp -rL "$DIR/bin/lib/ms" "$T/ms.pristine" || exit 1
for stub in notify.sh heartbeat.sh; do printf '#!/bin/bash\nexit 0\n' > "$H6/bin/$stub"; chmod +x "$H6/bin/$stub"; done
printf '#!/bin/bash\nexit 0\n' > "$H6/bin/fleet-conf.sh"; chmod +x "$H6/bin/fleet-conf.sh"
cat > "$H6/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
exit 0
SH
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$H6/fakebin/curl"
chmod +x "$H6/fakebin/gh" "$H6/fakebin/curl"
canary() { echo "echo ms-canary >> '$T/canary'" >> "$H6/bin/lib/ms/terminal.sh"; }
reset6() { : > "$H6/logs/merge-sweep.log"; : > "$H6/logs/ALERTS.log"; : > "$T/gh.txt"; rm -f "$T/canary"; }
# tick <script> — one sweep tick; prints its rc.
tick() {
  ( export PATH="$H6/fakebin:$H6/bin:$PATH" HARNESS="$H6" HARNESS_ENV_DIR="$H6/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b GH_SINK="$T/gh.txt"
    unset GH_TOKEN
    bash "$1" >/dev/null 2>"$T/err.txt"; echo $? )
}
alerts() { grep -c 'SWEEP MODULE MISSING' "$H6/logs/ALERTS.log" 2>/dev/null || true; }

# M6: the modules next to the script load.
reset6; canary
rc=$(tick "$H6/bin/sweep.sh")
[ "$rc" = 0 ] && ok || bad "M6: a tick with its modules exited $rc (stderr: $(tail -3 "$T/err.txt"))"
grep -qx ms-canary "$T/canary" 2>/dev/null && ok || bad "M6: the sweep did not source bin/lib/ms/terminal.sh"
grep -q 'refusing the tick' "$H6/logs/merge-sweep.log" && bad "M6: a tick that loaded its modules logged a refusal" || ok
[ "$(alerts)" = 0 ] && ok || bad "M6: a tick that loaded its modules raised SWEEP MODULE MISSING"

# M6b: no lib/ms next to the script: it falls back to $HARNESS/bin/lib/ms.
reset6
cp "$H6/bin/sweep.sh" "$T/alt/sweep.sh"
rc=$(tick "$T/alt/sweep.sh")
[ "$rc" = 0 ] && ok || bad "M6b: a tick that falls back to \$HARNESS/bin/lib/ms exited $rc"
grep -qx ms-canary "$T/canary" 2>/dev/null && ok || bad "M6b: the fallback did not source \$HARNESS/bin/lib/ms/terminal.sh"

# M6: bin/lib/ms/ is gone: the tick refuses, once, before any GitHub call.
reset6; scratch_rm "$H6/bin/lib/ms" || exit 1
rc=$(tick "$H6/bin/sweep.sh")
[ "$rc" = 1 ] && ok || bad "M6: a tick with no bin/lib/ms/ exited $rc, want 1"
grep -q 'bin/lib/ms/ is missing or unusable — refusing the tick' "$H6/logs/merge-sweep.log" && ok \
  || bad "M6: the refusal is not in logs/merge-sweep.log"
[ "$(alerts)" = 1 ] && ok || bad "M6: want exactly one SWEEP MODULE MISSING line, got $(alerts)"
[ ! -s "$T/gh.txt" ] && ok || bad "M6: a refused tick called gh: $(head -3 "$T/gh.txt")"

# M6c: MODULES names a module with no file: the tick refuses and sources nothing.
reset6; cp -r "$T/ms.pristine" "$H6/bin/lib/ms"; canary; echo ghost >> "$H6/bin/lib/ms/MODULES"
rc=$(tick "$H6/bin/sweep.sh")
[ "$rc" = 1 ] && ok || bad "M6c: a MODULES entry with no file exited $rc, want 1"
[ "$(alerts)" = 1 ] && ok || bad "M6c: want exactly one SWEEP MODULE MISSING line, got $(alerts)"
[ ! -e "$T/canary" ] && ok || bad "M6c: a bad MODULES still sourced terminal.sh"
[ ! -s "$T/gh.txt" ] && ok || bad "M6c: a refused tick called gh"

# ── M7. the moved helpers through terminal.sh alone ─────────────────────────
M7="$T/m7"; mkdir -p "$M7/rec"; echo "PR_CREATED https://github.com/o/r/pull/1" > "$M7/rec/RESULT"
OUT=$(env -i PATH="$PATH" M7="$M7" MOD="$DIR/bin/lib/ms/terminal.sh" bash -c '
  set -u
  . "$MOD" || exit 3
  declare -A _TERM; NOW=100; PR=https://github.com/o/r/pull/1; TERM_CACHE="$M7/tc"; : > "$TERM_CACHE"; D="$M7/rec"
  FP=$(sweep_record_fp "$M7/rec"); echo "fp=$FP"
  _ITER_CLASS=; sweep_terminal "e2e fail"
  echo "class=$_ITER_CLASS"; echo "term=${_TERM["$PR|$FP"]:-}"
  echo "relog=$(sweep_relog_line e2e-fail)"; echo "relog2=[$(sweep_relog_line no-approve-record)]"
  FP=""; sweep_terminal "e2e fail"; echo "lines=$(wc -l < "$TERM_CACHE")"
')
FP=$(sed -n 's/^fp=//p' <<<"$OUT")
case "$FP" in RESULT:*) ok ;; *) bad "M7: sweep_record_fp gave '$FP', want RESULT:..." ;; esac
grep -qx 'class=terminal-new' <<<"$OUT" && ok || bad "M7: sweep_terminal did not set _ITER_CLASS=terminal-new"
grep -qx 'term=100 e2e_fail' <<<"$OUT" && ok || bad "M7: sweep_terminal did not set _TERM"
[ "$(cat "$M7/tc" 2>/dev/null)" = "100 e2e_fail https://github.com/o/r/pull/1 $FP" ] && ok \
  || bad "M7: the cache line is '$(cat "$M7/tc" 2>/dev/null)'"
grep -qx 'lines=1' <<<"$OUT" && ok || bad "M7: sweep_terminal with FP='' appended a line"
grep -qxF "relog=https://github.com/o/r/pull/1 skipped: E2E smoke FAILED on the build's preview deployment (see $M7/rec/e2e.md)" <<<"$OUT" && ok \
  || bad "M7: sweep_relog_line e2e-fail printed the wrong line"
grep -qx 'relog2=\[\]' <<<"$OUT" && ok || bad "M7: sweep_relog_line no-approve-record printed a line"
# The round trip: the driver's own load loop reads the line the moved writer wrote.
LOOP=$(sed -n '/^declare -A _TERM$/,/^done < "\$TERM_CACHE"$/p' "$SWEEP")
if grep -q '_TERM\["\$_TPR|\$_TFP"\]' <<<"$LOOP"; then
  ok
  printf '%s\n' "$LOOP" > "$T/loop.sh"
  RT=$(env -i PATH="$PATH" TERM_CACHE="$M7/tc" K="https://github.com/o/r/pull/1|$FP" \
    bash -c '. "$1"; echo "${_TERM["$K"]:-}"' _ "$T/loop.sh")
  [ "$RT" = "100 e2e_fail" ] && ok || bad "M7: the driver's load loop read back '$RT', want '100 e2e_fail'"
else
  bad "M7: the _TERM load loop is not in bin/merge-sweep.sh"
fi

echo "ms-split-layout.bh-5242: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
