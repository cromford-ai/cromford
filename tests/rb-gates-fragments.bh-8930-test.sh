#!/bin/bash
# tests/rb-gates-fragments.bh-8930-test.sh — BH-8930: a gate in
# bin/lib/rb/gates.sh can live in its own fragment under bin/lib/rb/gates.d/,
# sourced at its old position by one call line `. "$RB_GATES_D/<slug>.sh"`.
#
# What is proved here:
#   F1 every call line names a fragment that exists, passes bash -n, and holds
#      exactly one marked block with nothing after its close marker;
#   F2 every fragment has exactly one call line (no orphan, no duplicate);
#   F3 tests/lib/rb-all.sh puts the moved blocks back at their old positions;
#   F4 rb_all refuses a missing or unclosed fragment (rc 1, no output file);
#   F5 a block inline and the same block as fragment + call line flatten to the
#      same bytes;
#   F6 rb_gates_d_check, DRIVEN: all present is rc 0 and sets RB_GATES_D; a
#      missing fragment or a missing gates.d is BUILD_DEFERRED + rc 3 + one
#      lane-alert with id rb-gates-d-missing-<host>;
#   F7 the real fragments run in the calling function's scope (exit 3 leaves the
#      build, HOTFIX set inside a function survives it);
#   F8 rb_gates_d_check is defined before, and called as the first statement of,
#      rb_gate_prelude;
#   F9 the call-site grammar: both readers (the check and rb_all) agree on
#      which lines are call sites.
# Fragments shipped by this ticket: bin/lib/rb/gates.d/hotfix-detect.sh and
# bin/lib/rb/gates.d/disk-gate.sh.
# Run from anywhere: tests/rb-gates-fragments.bh-8930-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

G="$DIR/bin/lib/rb/gates.sh"
GD="$DIR/bin/lib/rb/gates.d"
CALL_RE='^\. "\$RB_GATES_D/([a-z0-9-]+\.sh)"$'

# A fake hostname, so the alert id and the RESULT text are literals.
mkdir -p "$T/fakebin"
printf '#!/bin/bash\necho fixture-host\n' > "$T/fakebin/hostname"
chmod +x "$T/fakebin/hostname"

# ══ F1 / F2: the fragment files and the call lines ══════════════════════════
CALLS=()
while IFS= read -r l; do
  [[ "$l" =~ $CALL_RE ]] && CALLS+=("${BASH_REMATCH[1]}")
done < "$G"
[ "${#CALLS[@]}" -ge 2 ] && ok || bad "F1 gates.sh must hold at least 2 fragment call lines (got ${#CALLS[@]})"
for want in bin/lib/rb/gates.d/hotfix-detect.sh bin/lib/rb/gates.d/disk-gate.sh; do
  want=${want##*/}
  grep -qx "$want" < <(printf '%s\n' "${CALLS[@]}") && ok || bad "F1 gates.sh has no call line for $want"
done
for f in "${CALLS[@]}"; do
  p="$GD/$f"
  [ -s "$p" ] || { bad "F1 call line names $f but bin/lib/rb/gates.d/$f is missing or empty"; continue; }
  bash -n "$p" 2>/dev/null && ok || bad "F1 gates.d/$f fails bash -n"
  opens=$(grep -c '^# >>> ' "$p"); closes=$(grep -c '^# <<< ' "$p")
  [ "$opens" = 1 ] && [ "$closes" = 1 ] && ok || bad "F1 gates.d/$f must hold exactly one marked pair (opens=$opens closes=$closes)"
  name=$(sed -n 's/^# >>> //p' "$p")
  last=$(grep -v '^[[:space:]]*$' "$p" | tail -1)
  [ "$last" = "# <<< $name" ] && ok || bad "F1 gates.d/$f must end at '# <<< $name' (last line '$last')"
  pre=$(awk '/^# >>> /{exit} {print}' "$p" | grep -cv '^#\|^[[:space:]]*$')
  [ "$pre" = 0 ] && ok || bad "F1 gates.d/$f has $pre non-comment line(s) before its open marker"
done
for p in "$GD"/*.sh; do
  [ -e "$p" ] || { bad "F2 bin/lib/rb/gates.d/ holds no fragment"; break; }
  b=${p##*/}
  n=$(printf '%s\n' "${CALLS[@]}" | grep -cx "$b")
  [ "$n" = 1 ] && ok || bad "F2 gates.d/$b has $n call line(s) in gates.sh (want exactly 1)"
done

# ══ F3: the real flatten puts the blocks back in order ══════════════════════
ALL="$T/real.all"
rb_all "$DIR" "$ALL" >/dev/null || bad "F3 rb_all on the repo failed"
ln() { grep -nxF -- "$1" "$ALL" | head -1 | cut -d: -f1; }
cnt() { grep -cxF -- "$1" "$ALL"; }
left=$(grep -cE "$CALL_RE" "$ALL")
[ "$left" = 0 ] && ok || bad "F3 the flatten still holds $left fragment call line(s)"
for m in '# >>> hotfix detect' '# <<< hotfix detect' '# >>> disk gate' '# <<< disk gate'; do
  [ "$(cnt "$m")" = 1 ] && ok || bad "F3 '$m' must appear once in the flatten (got $(cnt "$m"))"
done
before() { # before <a> <b> — line of a < line of b, both present
  local a b; a=$(ln "$1"); b=$(ln "$2")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok || bad "F3 '$1' (line ${a:-none}) must come before '$2' (line ${b:-none})"
}
before '# <<< ticket identity guard' '# >>> hotfix detect'
before '# <<< hotfix detect' '# >>> closed issue skip'
before '# <<< hub-no-build' '# >>> disk gate'
before '# <<< disk gate' '# >>> overlap not-before'
grep -qxF 'if [ "${BUILDER_EXEC:-}" != 1 ]; then' "$ALL" && ok || bad "F3 the disk gate body is not in the flatten"
grep -qxF 'HOTFIX="${HOTFIX:-}"' "$ALL" && ok || bad "F3 the hotfix detect body is not in the flatten"

# A scratch repo: driver + one gates module whose one stage body is <body-file>.
mkrepo() { # mkrepo <dir> <body-file>
  mkdir -p "$1/bin/lib/rb/gates.d"
  printf 'RB_MODULES="gates"\necho pre\nrb_gate_prelude\necho post\n' > "$1/bin/run-build.sh"
  { echo '# shellcheck shell=bash'; echo 'rb_gate_prelude() {'; cat "$2"; echo '} # end rb_gate_prelude'; } > "$1/bin/lib/rb/gates.sh"
}

# ══ F4: rb_all refuses a missing or an unclosed fragment ════════════════════
printf 'echo a\n. "$RB_GATES_D/gone.sh"\necho b\n' > "$T/f4.body"
mkrepo "$T/f4" "$T/f4.body"
rb_all "$T/f4" "$T/f4.all" >/dev/null 2>"$T/f4.err"; rc=$?
[ "$rc" = 1 ] && ok || bad "F4 a missing fragment must make rb_all rc 1 (got $rc)"
grep -q 'gates.d/gone.sh' "$T/f4.err" && ok || bad "F4 stderr must name gates.d/gone.sh (got '$(cat "$T/f4.err")')"
[ ! -e "$T/f4.all" ] && ok || bad "F4 rb_all must remove its half-written output on a missing fragment"
printf '# shellcheck shell=bash\n# >>> gone\necho in\n' > "$T/f4/bin/lib/rb/gates.d/gone.sh"
rb_all "$T/f4" "$T/f4.all" >/dev/null 2>"$T/f4.err"; rc=$?
[ "$rc" = 1 ] && ok || bad "F4 an unclosed fragment must make rb_all rc 1 (got $rc)"
[ ! -e "$T/f4.all" ] && ok || bad "F4 rb_all must remove its output on an unclosed fragment"

# ══ F5: inline and fragment flatten to the same bytes ═══════════════════════
printf 'echo a\n\n# >>> blk\n# the block\nX=1\n# <<< blk\n\necho b\n' > "$T/f5i.body"
printf 'echo a\n\n. "$RB_GATES_D/blk.sh"\n\necho b\n' > "$T/f5f.body"
mkrepo "$T/f5i" "$T/f5i.body"; mkrepo "$T/f5f" "$T/f5f.body"
printf '# shellcheck shell=bash\n# Sourced by rb_gate_prelude at its call site, never run.\n# >>> blk\n# the block\nX=1\n# <<< blk\n' \
  > "$T/f5f/bin/lib/rb/gates.d/blk.sh"
rb_all "$T/f5i" "$T/f5i.all" >/dev/null; rb_all "$T/f5f" "$T/f5f.all" >/dev/null
cmp -s "$T/f5i.all" "$T/f5f.all" && ok || bad "F5 inline and fragment flatten differ: $(diff "$T/f5i.all" "$T/f5f.all" | head -5)"

# ══ F6: rb_gates_d_check, driven ═══════════════════════════════════════════
mkcheck() { # mkcheck <harness> — the real gates.sh and gates.d, stub lane-alert
  mkdir -p "$1/bin/lib/rb"
  cp "$G" "$1/bin/lib/rb/"
  [ -d "$GD" ] && cp -r "$GD" "$1/bin/lib/rb/"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.argv"\n' > "$1/bin/lane-alert.sh"
  chmod +x "$1/bin/lane-alert.sh"
}
runcheck() { # runcheck <harness> <gates.sh> — prints rc=<n> and RB_GATES_D=<v>; RESULT text to <harness>/result
  env PATH="$T/fakebin:$PATH" HARNESS="$1" KEY=BH-1 PROJECT=fixture-proj BUILD="$1/build" \
    bash -c 'RESULT() { printf "%s\n" "$1" >> "$HARNESS/result"; }
             . "$0" || exit 9
             rb_gates_d_check; echo "rc=$?"; echo "RB_GATES_D=${RB_GATES_D:-}"' "$2" 2>"$1/check.err"
}
mkcheck "$T/c1"
out=$(runcheck "$T/c1" "$T/c1/bin/lib/rb/gates.sh")
grep -qx 'rc=0' <<<"$out" && ok || bad "F6 all fragments present must be rc 0 (got '$out' $(cat "$T/c1/check.err"))"
grep -qxF "RB_GATES_D=$T/c1/bin/lib/rb/gates.d" <<<"$out" && ok || bad "F6 RB_GATES_D must be the tree's gates.d (got '$out')"
[ ! -e "$T/c1/alerts.argv" ] && [ ! -e "$T/c1/result" ] && ok || bad "F6 a passing check must alert nothing and write no RESULT"

mkcheck "$T/c2"; rm -f "$T/c2/bin/lib/rb/gates.d/disk-gate.sh"
out=$(runcheck "$T/c2" "$T/c2/bin/lib/rb/gates.sh")
grep -qx 'rc=3' <<<"$out" && ok || bad "F6 a missing fragment must be rc 3 (got '$out')"
res=$(cat "$T/c2/result" 2>/dev/null)
[[ "$res" == "BUILD_DEFERRED "* ]] && ok || bad "F6 RESULT must start BUILD_DEFERRED (got '$res')"
[[ "$res" == *"gates.d/disk-gate.sh"* && "$res" == *"fixture-host"* ]] && ok || bad "F6 RESULT must name gates.d/disk-gate.sh and the host (got '$res')"
n=$(wc -l < "$T/c2/alerts.argv" 2>/dev/null || echo 0)
[ "$n" = 1 ] && ok || bad "F6 a missing fragment must fire exactly one lane-alert (got $n)"
a=$(cat "$T/c2/alerts.argv" 2>/dev/null)
[[ "$a" == *"--id rb-gates-d-missing-fixture-host"* && "$a" == *"gates.d/disk-gate.sh"* ]] && ok || bad "F6 the alert must carry id rb-gates-d-missing-fixture-host and the file (got '$a')"

mkcheck "$T/c3"; rm -rf "$T/c3/bin/lib/rb/gates.d"
out=$(runcheck "$T/c3" "$T/c3/bin/lib/rb/gates.sh")
grep -qx 'rc=3' <<<"$out" && ok || bad "F6 a missing gates.d must be rc 3 (got '$out')"
res=$(cat "$T/c3/result" 2>/dev/null)
[[ "$res" == "BUILD_DEFERRED "*"gates.d/"*"fixture-host"* ]] && ok || bad "F6 a missing gates.d must defer naming a fragment and the host (got '$res')"

# ══ F7: the real fragments run in the calling function's scope ═════════════
F7="$T/f7"
mkdir -p "$F7/bin/lib" "$F7/build"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.argv"\n' > "$F7/bin/lane-alert.sh"; chmod +x "$F7/bin/lane-alert.sh"
printf 'disk_build_refuse_reason() { echo "disk 95%%"; return 0; }\n' > "$F7/bin/lib/disk-guard.sh"
cat > "$F7/bin/lib/hotfix-lib.sh" <<'SH'
hotfix_lane_on() { echo 1; }
hotfix_key_is() { return 0; }
hotfix_label() { echo fixture-hotfix; }
hotfix_announce() { return 0; }
SH
f7run() { # f7run <shell text> — run with the real gates.d as RB_GATES_D, $0 = the scratch driver
  env -u HOTFIX -u BUILDER_EXEC PATH="$T/fakebin:$PATH" HARNESS="$F7" KEY=BH-1 PROJECT=fixture-proj BUILD="$F7/build" RB_GATES_D="$GD" \
    bash -c 'STAMP() { echo 2026-11-02T00:00:00Z; }; RESULT() { printf "%s\n" "$1" > "$HARNESS/result"; }; '"$1" "$F7/bin/run-build.sh" 2>/dev/null
}
rm -f "$F7/result"
out=$(f7run 'g() { . "$RB_GATES_D/disk-gate.sh"; echo after-gate; }; g; echo after-func'); rc=$?
[ "$rc" = 3 ] && ok || bad "F7 disk-gate.sh at 95% must exit 3 from the build (got rc $rc)"
[ -z "$out" ] && ok || bad "F7 disk-gate.sh exit must leave the build, not a subshell (got '$out')"
[ "$(cat "$F7/result" 2>/dev/null)" = "BUILD_DEFERRED disk 95%" ] && ok || bad "F7 RESULT must be 'BUILD_DEFERRED disk 95%' (got '$(cat "$F7/result" 2>/dev/null)')"
rm -f "$F7/result"
out=$(env -u HOTFIX PATH="$T/fakebin:$PATH" HARNESS="$F7" KEY=BH-1 PROJECT=fixture-proj BUILD="$F7/build" RB_GATES_D="$GD" BUILDER_EXEC=1 \
  bash -c 'STAMP() { echo x; }; RESULT() { echo "$1" > "$HARNESS/result"; }; g() { . "$RB_GATES_D/disk-gate.sh"; echo after-gate; }; g' "$F7/bin/run-build.sh" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = after-gate ] && [ ! -e "$F7/result" ] && ok || bad "F7 BUILDER_EXEC=1 must pass the disk gate (rc $rc, out '$out')"
: > "$F7/build/pipeline.log"
out=$(f7run 'g() { . "$RB_GATES_D/hotfix-detect.sh"; }; g; echo "HOTFIX=${HOTFIX:-}"'); rc=$?
[ "$rc" = 0 ] && [ "$out" = "HOTFIX=1" ] && ok || bad "F7 HOTFIX set inside a function by hotfix-detect.sh must survive it (rc $rc, out '$out')"
grep -q 'HOTFIX: this ticket carries the fixture-hotfix label' "$F7/build/pipeline.log" && ok || bad "F7 pipeline.log must carry the HOTFIX line (got '$(cat "$F7/build/pipeline.log")')"

# ══ F8: the check is defined before, and runs first in, rb_gate_prelude ════
def=$(grep -n '^rb_gates_d_check() {' "$G" | head -1 | cut -d: -f1)
pre=$(grep -n '^rb_gate_prelude() {$' "$G" | head -1 | cut -d: -f1)
[ -n "$def" ] && [ -n "$pre" ] && [ "$def" -lt "$pre" ] && ok || bad "F8 rb_gates_d_check (line ${def:-none}) must be defined before rb_gate_prelude (line ${pre:-none})"
first=$(awk -v s="${pre:-0}" 'NR>s && NF {print; exit}' "$G")
[ "$first" = 'rb_gates_d_check || exit 3' ] && ok || bad "F8 the first statement of rb_gate_prelude must be 'rb_gates_d_check || exit 3' (got '$first')"

# ══ F9: the call-site grammar, through both readers ════════════════════════
# The real check function, lifted out of gates.sh into each scratch module.
awk '/^rb_gates_d_check\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$G" > "$T/check.fn"
[ -s "$T/check.fn" ] && ok || bad "F9 could not lift rb_gates_d_check out of gates.sh"
i=0
while IFS='|' read -r want row; do
  i=$((i+1)); R="$T/f9-$i"
  printf 'echo a\n%s\necho b\n' "$row" > "$R.body"
  mkrepo "$R" "$R.body"
  { cat "$T/check.fn"; cat "$R/bin/lib/rb/gates.sh"; } > "$R/g.tmp" && mv "$R/g.tmp" "$R/bin/lib/rb/gates.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.argv"\n' > "$R/bin/lane-alert.sh"; chmod +x "$R/bin/lane-alert.sh"
  out=$(runcheck "$R" "$R/bin/lib/rb/gates.sh")
  rb_all "$R" "$R.all" >/dev/null 2>&1; arc=$?
  if [ "$want" = match ]; then
    grep -qx 'rc=3' <<<"$out" && ok || bad "F9 check must treat [$row] as a call site (got '$out')"
    [ "$arc" = 1 ] && ok || bad "F9 rb_all must treat [$row] as a call site (rc $arc)"
  else
    grep -qx 'rc=0' <<<"$out" && ok || bad "F9 check must NOT treat [$row] as a call site (got '$out')"
    [ "$arc" = 0 ] && grep -qxF -- "$row" "$R.all" && ok || bad "F9 rb_all must copy [$row] through untouched (rc $arc)"
  fi
done <<'ROWS'
match|. "$RB_GATES_D/disk-gate.sh"
match|. "$RB_GATES_D/hotfix-detect.sh"
nomatch|  . "$RB_GATES_D/disk-gate.sh"
nomatch|# . "$RB_GATES_D/disk-gate.sh"
nomatch|. "$RB_GATES_D/disk-gate.sh" 2>/dev/null
nomatch|. '$RB_GATES_D/disk-gate.sh'
nomatch|. "$RB_GATES_D/../plan.sh"
nomatch|. "$HARNESS/bin/lib/disk-guard.sh"
nomatch|. "$RB_GATES_D/Disk-Gate.sh"
nomatch|. "$RB_GATES_D/.sh"
ROWS

echo "rb-gates-fragments (BH-8930): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
