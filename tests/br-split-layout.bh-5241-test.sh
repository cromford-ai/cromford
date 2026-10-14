#!/bin/bash
# tests/br-split-layout.bh-5241-test.sh — the per-ticket layout test for the
# bin/lib/br/ split of bin/blocked-resolver.sh (BH-5241, slice C0: the ladder;
# slice C1: the record layer).
# tests/br-split-layout-test.sh is the BH-1176 contract (the map, darkness, the
# refusal); this file adds what each later slice is judged by too.
#
#   B1  every br_* a top-level bin/lib/br/*.sh defines is defined by exactly one
#       of them (runtime `declare -F`, the way the BH-1176 suite measures).
#   B2  no top-level module defines a name an opt/ module defines. Static: an
#       opt/ module needs its lane env to source.
#   B3a the driver is no longer than the `lines` row of tests/br/driver-ceiling.tsv.
#   B3b the driver defines no more column-0 br_* than the `br_fns` row.
#   B3c a br_* the driver defines that a module also defines is a `lib` (dark)
#       row of tests/br/expected-map.tsv: nothing moved is left behind.
#   B4  the driver's literal BR_MODULES names == bin/lib/br/MODULES, in order,
#       and every top-level module carries a `# module:` header.
#   B5  byte for byte: tests/lib/br-bodies.sh gives an equal body set for a pure
#       move and a different one for a changed byte, a dropped function and a
#       renamed one (synthetic, always). With BR_SPLIT_BASE=<rev> it compares
#       that rev's driver + modules with the working tree and prints
#       `bodies: identical` or the difference. Env-gated: a permanent pin would
#       go red on every later PR that edits a br_ body on purpose.
#   B6  the real driver runs a tick from a scratch $HARNESS with rc 0 and
#       sources the scratch ladder.sh (a canary), and the classifier answers
#       through the module alone.
#   B7  the same tick sources the scratch record.sh (a canary), and br_shape and
#       br_fix_cap answer through record.sh alone, as the inline copies did.
#
# Run from anywhere: tests/br-split-layout.bh-5241-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/br-bodies.sh
. "$(dirname "$0")/lib/br-bodies.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

BR="$REPO/bin/blocked-resolver.sh"
BRD="$REPO/bin/lib/br"
MAP="$REPO/tests/br/expected-map.tsv"
CEIL="$REPO/tests/br/driver-ceiling.tsv"

# defs <file> — the names a file defines, by sourcing it in a clean bash. rc 3
# when the source fails, so a module that died never reads as "defines nothing".
cat > "$T/defs.sh" <<'DEFS'
#!/bin/bash
before=$(declare -F | awk '{print $3}')
# shellcheck source=/dev/null
. "$1" >/dev/null 2>&1 || exit 3
comm -13 <(printf '%s\n' "$before" | sort) <(declare -F | awk '{print $3}' | sort)
DEFS
# static_defs <file> — column-0 `br_x() {` names, read off the text.
static_defs() { grep -oE '^br_[A-Za-z0-9_]*[(][)] [{]' "$1" | sed 's/[(].*//' | sort -u; }
# def_count <file> — column-0 `br_x() {` DEFINITIONS (a name defined twice counts twice).
def_count() { grep -cE '^br_[A-Za-z0-9_]*[(][)] [{]' "$1"; }

# ── B1. one top-level module per br_* name ──────────────────────────────────
: > "$T/owners.tsv"; NMOD=0
for f in "$BRD"/*.sh; do
  NMOD=$((NMOD+1))
  if bash "$T/defs.sh" "$f" > "$T/defs.out"; then
    grep '^br_' "$T/defs.out" | sed "s|\$|	${f##*/}|" >> "$T/owners.tsv"
  else
    bad "B1: ${f#"$REPO"/} does not source on its own"
  fi
done
[ "$NMOD" -ge 2 ] && [ -s "$T/owners.tsv" ] && ok || bad "B1: read $NMOD top-level modules and no br_* names — the check would be vacuous"
DUP=$(cut -f1 "$T/owners.tsv" | sort | uniq -d)
[ -z "$DUP" ] && ok || bad "B1: defined by more than one top-level module: $(printf '%s' "$DUP" | tr '\n' ' ')"

# ── B2. no top-level / opt overlap (report it; never hide it by moving code) ─
: > "$T/opt.txt"
for f in "$BRD"/opt/*.sh; do
  grep -oE '^[[:space:]]*(function[[:space:]]+)?br_[A-Za-z0-9_]*[[:space:]]*[(][)]' "$f" \
    | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*[(][)]$//' >> "$T/opt.txt"
done
[ -s "$T/opt.txt" ] && ok || bad "B2: read no br_* definitions in bin/lib/br/opt/ — the check would be vacuous"
OVER=$(comm -12 <(cut -f1 "$T/owners.tsv" | sort -u) <(sort -u "$T/opt.txt"))
[ -z "$OVER" ] && ok || bad "B2: defined by a top-level module AND an opt/ module: $(printf '%s' "$OVER" | tr '\n' ' ')"

# ── B3. the ceiling, and nothing moved left behind ──────────────────────────
ceil() { awk -F'\t' -v k="$1" '$1==k && $2 ~ /^[0-9]+$/ {print $2; f=1} END{exit !f}' "$CEIL"; }
# check_ceiling <driver> — prints one line per breach; an absent row is a breach.
check_ceiling() {
  local lines fns max
  lines=$(wc -l < "$1"); fns=$(def_count "$1")
  max=$(ceil lines) || { echo "no numeric 'lines' row in tests/br/driver-ceiling.tsv"; max=-1; }
  [ "$max" -ge 0 ] && [ "$lines" -gt "$max" ] && echo "lines: the driver has $lines lines, the ceiling is $max"
  max=$(ceil br_fns) || { echo "no numeric 'br_fns' row in tests/br/driver-ceiling.tsv"; max=-1; }
  [ "$max" -ge 0 ] && [ "$fns" -gt "$max" ] && echo "br_fns: the driver defines $fns br_* functions, the ceiling is $max"
  return 0
}
OUT=$(check_ceiling "$BR")
L=$(printf '%s\n' "$OUT" | grep "^lines\|'lines' row"); [ -z "$L" ] && ok || bad "B3a: $L"
L=$(printf '%s\n' "$OUT" | grep "^br_fns\|'br_fns' row"); [ -z "$L" ] && ok || bad "B3b: $L"
# The ceiling must bite: one line over it, and one br_* over it, are red.
max_l=$(ceil lines); max_f=$(ceil br_fns)
cp "$BR" "$T/over.sh"
for _ in $(seq $((max_l - $(wc -l < "$BR") + 1))); do echo >> "$T/over.sh"; done
OVER_OUT=$(check_ceiling "$T/over.sh"); grep -q '^lines:' <<<"$OVER_OUT" && ok || bad "B3a: a driver one line over the ceiling ($max_l) was not caught"
cp "$BR" "$T/over.sh"
for i in $(seq $((max_f - $(def_count "$BR") + 1))); do printf 'br_ceiling_probe_%s() {\n  :\n}\n' "$i" >> "$T/over.sh"; done
OVER_OUT=$(check_ceiling "$T/over.sh"); grep -q '^br_fns:' <<<"$OVER_OUT" && ok || bad "B3b: a driver one br_* over the ceiling ($max_f) was not caught"
# B3c
LEFT=""
while read -r n; do
  grep -q "^$n	" "$T/owners.tsv" || continue
  awk -F'\t' -v n="$n" '$2==n && $3=="lib" {f=1} END{exit !f}' "$MAP" || LEFT="$LEFT $n"
done < <(static_defs "$BR")
[ -z "$LEFT" ] && ok || bad "B3c: defined in the driver AND a module, and not a 'lib' (dark) row of tests/br/expected-map.tsv:$LEFT"

# ── B4. BR_MODULES == MODULES, and every module has a header ────────────────
LIT=$(sed -n 's/^BR_MODULES="\(.*\)"$/\1/p' "$BR" | head -1)
GEN=$(grep -v '^#' "$BRD/MODULES" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
[ -n "$LIT" ] && [ "$LIT" = "$GEN" ] && ok \
  || bad "B4: the driver's BR_MODULES=\"$LIT\" is not bin/lib/br/MODULES (\"$GEN\")"
for f in "$BRD"/*.sh; do
  head -30 "$f" | grep -q '^# module: ' && ok || bad "B4: ${f#"$REPO"/} has no '# module:' header in its first 30 lines"
done

# ── B5. byte for byte ───────────────────────────────────────────────────────
S="$T/b5"; mkdir -p "$S/before" "$S/after"
cat > "$S/before/driver.sh" <<'EOF'
br_keep() {
  echo keep
}
br_move() { # moves
  echo "a\\b	tab"
}
br_one() { echo one; }
EOF
printf 'br_dark() {\n  :\n}\n' > "$S/before/mod.sh"
printf 'br_keep() {\n  echo keep\n}\nbr_dark() {\n  :\n}\n' > "$S/after/driver.sh"
{ printf 'br_dark() {\n  :\n}\n'; sed -n '/^br_move/,/^}/p; /^br_one/p' "$S/before/driver.sh"; } > "$S/after/mod.sh"
bset() { br_bodies "$1/driver.sh" "$1/mod.sh"; }
BEFORE=$(bset "$S/before")
[ "$(printf '%s\n' "$BEFORE" | wc -l)" = 4 ] && ok || bad "B5: the fixture should give 4 bodies, got: $BEFORE"
[ "$BEFORE" = "$(bset "$S/after")" ] && ok || bad "B5: a pure move gave a different body set"
MUT=0
mutate() { MUT=$((MUT+1)); cp -r "$S/after" "$S/m$MUT"; sed -i "$1" "$S/m$MUT/mod.sh"; R=$(bset "$S/m$MUT"); [ "$R" != "$BEFORE" ]; }
mutate 's/a\\\\b/a\\\\c/' && ok || bad "B5: one changed byte gave the same body set"
mutate '/^br_one/d' && ok || bad "B5: a dropped function gave the same body set"
mutate 's/^br_move()/br_moved()/' && ok || bad "B5: a renamed function gave the same body set"
if [ -n "${BR_SPLIT_BASE:-}" ]; then
  mkdir -p "$S/base/bin/lib/br"
  if git -C "$REPO" show "$BR_SPLIT_BASE:bin/blocked-resolver.sh" > "$S/base/bin/blocked-resolver.sh"; then
    for m in $(git -C "$REPO" ls-tree --name-only "$BR_SPLIT_BASE" bin/lib/br/ | grep '\.sh$'); do
      git -C "$REPO" show "$BR_SPLIT_BASE:$m" > "$S/base/$m"
    done
    br_bodies "$S/base/bin/blocked-resolver.sh" "$S/base/bin/lib/br/"*.sh > "$T/base.set"
    br_bodies "$BR" "$BRD"/*.sh > "$T/head.set"
    if [ -s "$T/base.set" ] && cmp -s "$T/base.set" "$T/head.set"; then
      ok; echo "bodies: identical ($(wc -l < "$T/head.set") bodies, $BR_SPLIT_BASE vs working tree)"
      moved=$(comm -23 <(static_defs "$S/base/bin/blocked-resolver.sh") <(static_defs "$BR") | tr '\n' ' ')
      echo "moved out of the driver: ${moved:-none}"
    else
      bad "B5: the br_* body set differs from $BR_SPLIT_BASE (or is empty)"
      diff "$T/base.set" "$T/head.set" | head -20
    fi
  else
    bad "B5: BR_SPLIT_BASE=$BR_SPLIT_BASE has no bin/blocked-resolver.sh"
  fi
fi

# ── B6. the production entry point ──────────────────────────────────────────
H="$T/h"
mkdir -p "$H/logs" "$H/state/merge-conductor" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
for s in bin/blocked-resolver.sh bin/fleet-conf.sh bin/project-of.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "B6: could not install $s into the scratch harness"
done
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin/gh" "$T/fakebin/flock"
printf 'printf %%s canary > "%s/ladder-sourced"\n' "$T" >> "$H/bin/lib/br/ladder.sh"
printf 'printf %%s canary > "%s/record-sourced"\n' "$T" >> "$H/bin/lib/br/record.sh"
: > "$H/logs/ALERTS.log"
( unset HARNESS; export PATH="$T/fakebin:$PATH" GH_TOKEN=""
  HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/blocked-resolver.sh" nosuchproject ) > "$T/lane.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "B6: the driver tick exited $RC: $(tail -3 "$T/lane.out" | tr '\n' ' ')"
[ -s "$T/ladder-sourced" ] && ok || bad "B6: the driver tick never sourced bin/lib/br/ladder.sh"
grep -q 'RESOLVER MODULE MISSING' "$H/logs/ALERTS.log" && bad "B6: a tick with every module present wrote a refusal" || ok
GOT=$(bash -c '. "$0"; br_action "$(br_reason_of "red-ci-twice: x")"' "$BRD/ladder.sh" 2>&1)
[ "$GOT" = ladder ] && ok || bad "B6: br_action(br_reason_of red-ci-twice) through bin/lib/br/ladder.sh answered '$GOT', want ladder"

# ── B7. the record layer through the same tick ──────────────────────────────
[ "$RC" -eq 0 ] && [ -s "$T/record-sourced" ] && ok || bad "B7: the driver tick (rc=$RC) never sourced bin/lib/br/record.sh"
GOT=$(bash -c '. "$0"; br_shape "{\"conflict_lines\":10}"; br_shape "{}"; MAX_FIXROUNDS_SMALL=5 br_fix_cap "{\"conflict_lines\":10}"' "$BRD/record.sh" 2>&1 | tr '\n' ' ')
[ "$GOT" = "small large 5 " ] && ok || bad "B7: br_shape/br_fix_cap through bin/lib/br/record.sh answered '$GOT', want 'small large 5 '"

echo "br-split-layout.bh-5241: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
