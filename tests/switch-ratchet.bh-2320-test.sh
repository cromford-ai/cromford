#!/bin/bash
# tests/switch-ratchet.bh-2320-test.sh — the bare `[ -f flags/<x>-off ]` kill
# switch reads may only go DOWN (BH-2320).
#
# A switch read as a bare file cannot be flipped without ssh and is lost with
# its box; bin/lib/lane-switch.sh's lane_switch reads the settings row first.
# The children of BH-2320 convert the readers; this ratchet stops new ones.
#
#   R0 every tests/switch-ratchet.d/*.drop holds a non-negative integer, and
#      their sum leaves the effective floor EFF (FLOOR minus that sum) >= 0;
#   R1 the count of bare reads in bin/ and fly/ is <= EFF, and every
#      `lane_switch <literal>` in bin/ has catalog/switches.d/<literal>.json
#      whose name matches;
#   R2 the tree sits exactly AT EFF, and a copy of it with one bare reader
#      added counts over it.
#
# NEVER EDIT FLOOR. When you convert readers, add your own
# tests/switch-ratchet.d/<KEY>.drop holding the number of bare reads you
# removed (BH-2407, BH-2426): one file per ticket, so parallel conversions never
# meet on one line. FLOOR is 102, the count when this landed (101 in bin/ plus
# fly/'s 2, less bin/dora-digest.sh, measured on the tree with `bare_count`).
#
# TWO MODES (tests/lib/ratchet-delta.sh). The default, delta, is what every PR
# and merge-queue run uses: R1 counts bare reads PER FILE at the base (the
# newest main this HEAD contains) and at HEAD, and is red only when THIS diff
# raised a file's count or added a file with one. The .drop floor is not read
# in delta mode, so parallel conversions can never sum over it in a batch (the
# floor moved with every conversion PR and dequeued batches twice). A base that
# does not resolve is red. strict (RATCHET_MODE=strict or --strict), for a
# scheduled or post-merge run, is the absolute check below, unchanged: R1
# N <= EFF over the whole tree, and R2 the tree sits exactly AT EFF.
#   D  hermetic git repos: main drift the PR never touched is green in delta
#      mode, a PR that adds a bare read is red, drift or no drift, no base is
#      red, and strict still sees the drift.
# Run from anywhere: tests/switch-ratchet.bh-2320-test.sh [--strict]  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FLOOR=102
BARE_RE='\[ -[ef] [^]]*flags/[a-z0-9-]+-(off|disabled)'

# bare_count <root> — every bare switch read under <root>/bin and <root>/fly.
bare_count() {
  local d n=0 c
  for d in "$1/bin" "$1/fly"; do
    [ -d "$d" ] || continue
    c=$(grep -rhoE "$BARE_RE" "$d" 2>/dev/null | wc -l | tr -d ' ')
    n=$((n + c))
  done
  printf '%s' "$n"
}

# bare_rows <root> — "<path under root>\t<n>" for every file under bin/ and fly/
# with n > 0 bare reads: the per-file counts delta mode compares.
bare_rows() {
  local d
  for d in bin fly; do
    [ -d "$1/$d" ] || continue
    (cd "$1" && grep -roE "$BARE_RE" "$d" 2>/dev/null) | sed 's/:.*//'
  done | sort | uniq -c | awk '{ c = $1; sub(/^ *[0-9]+ /, ""); print $0 "\t" c }'
}

MODE=$(rd_mode "$@") || { echo "FAIL: $MODE"; exit 1; }

# drops <root> — sum the .drop files under <root>/tests/switch-ratchet.d into
# DROPS (R0: `#` comment lines and blank lines allowed, otherwise exactly one
# non-negative integer; anything else fails naming the file and adds 0).
drops() {
  local d body
  DROPS=0
  for d in "$1"/tests/switch-ratchet.d/*.drop; do
    [ -f "$d" ] || continue
    body=$(grep -vE '^[[:space:]]*(#|$)' "$d")
    if [ "$(grep -c . <<<"$body")" -eq 1 ] && [[ "$body" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      DROPS=$((DROPS + 10#${BASH_REMATCH[1]})); ok
    else
      bad "R0 ${d#"$1"/}: drop must be one non-negative integer, got '$(printf '%s' "$body" | tr '\n' ' ')'"
    fi
  done
}

# strict_r1 <root> — the absolute check: every bare read in the tree against
# the effective floor. Prints the offending reads, rc 1 when over.
strict_r1() {
  local n; n=$(bare_count "$1")
  [ "$n" -le "$EFF" ] && return 0
  echo "R1 $n bare flags/*-off|-disabled reads in bin/ + fly/, effective floor $EFF (FLOOR $FLOOR less $DROPS dropped) — read the switch with lane_switch (bin/lib/lane-switch.sh) instead:"
  grep -rnoE "$BARE_RE" "$1/bin" "$1/fly" 2>/dev/null | sed "s|^$1/|  |"
  return 1
}

# delta_r1 <repo> <base> — red when THIS diff adds a bare read: a file whose
# count at HEAD (the working tree) is above its count at <base>. Prints one
# line per such file, rc 1 if any.
delta_r1() {
  local repo="$1" ref="$2" w p n b bad=0
  w=$(mktemp -d "$T/delta-base.XXXXXX") || return 1
  rd_tree "$repo" "$ref" "$w" bin fly || return 1
  bare_rows "$w" > "$w.base"; bare_rows "$repo" > "$w.head"
  while IFS=$'\t' read -r p n b; do
    echo "R1 $p: $n bare flags/*-off|-disabled read(s), $b at base ${ref:0:12} — read the switch with lane_switch (bin/lib/lane-switch.sh) instead:"
    grep -noE "$BARE_RE" "$repo/$p" | sed "s|^|  $p:|"
    bad=1
  done < <(rd_delta "$w.head" "$w.base")
  return "$bad"
}

# r1 <root> — the check the run makes, by mode.
r1() {
  local base
  case "$MODE" in
    strict) strict_r1 "$1" ;;
    delta)  base=$(rd_base "$1") || { echo "R1 $base"; return 1; }
            delta_r1 "$1" "$base" ;;
  esac
}

drops "$DIR"
EFF=$((FLOOR - DROPS))
[ "$EFF" -ge 0 ] || bad "R0 the .drop files sum to $DROPS, over FLOOR $FLOOR"

# R1 — the tree.
N=$(bare_count "$DIR")
OUT=$(r1 "$DIR"); RC=$?
if [ "$RC" = 0 ]; then ok; else bad "$OUT"; fi
[ "$N" -gt 0 ] && ok || bad "R1 counted nothing — the pattern no longer matches the tree"

# Code lines only: a comment that says "lane_switch is ..." names no switch.
NAMES=$(grep -rhE 'lane_switch [a-z0-9_-]+' "$DIR/bin" 2>/dev/null | grep -vE '^[[:space:]]*#' \
  | grep -oE 'lane_switch [a-z0-9_-]+' | awk '{print $2}' | sort -u)
[ -n "$NAMES" ] && ok || bad "R1 no lane_switch reader found in bin/ (the dora-digest pilot is one)"
for n in $NAMES; do
  f="$DIR/catalog/switches.d/$n.json"
  if [ "$(jq -r '.name // empty' "$f" 2>/dev/null)" = "$n" ]; then ok
  else bad "R1 lane_switch $n has no catalog/switches.d/$n.json with name \"$n\""; fi
done

# R2 — one more bare reader in a copy is caught.
mkdir -p "$T/r"
cp -r "$DIR/bin" "$DIR/fly" "$T/r/"
N0=$(bare_count "$T/r")
bare_rows "$T/r" > "$T/r.rows0"
printf '#!/bin/bash\n[ -f "$H/flags/new-thing-off" ] && exit 0\n' > "$T/r/bin/new-thing.sh"
N1=$(bare_count "$T/r")
[ "$N1" -eq $((N0 + 1)) ] && ok || bad "R2 an added bare reader moved the count $N0 -> $N1"
if [ "$MODE" = strict ]; then
  # The tree sits AT the effective floor (every conversion adds its drop file),
  # so one more reader is exactly the tree R1 refuses.
  if [ "$N0" -eq "$EFF" ] && [ "$N1" -gt "$EFF" ]; then ok
  elif [ "$N0" -lt "$EFF" ]; then
    bad "R2 tree at $N0, effective floor $EFF (FLOOR $FLOOR less $DROPS dropped): add tests/switch-ratchet.d/<KEY>.drop holding $((EFF - N0)) so one more reader fails R1; never edit FLOOR"
  else bad "R2 tree at $N0, over effective floor $EFF: convert the new bare reads (R1 names them)"; fi
else
  # Delta mode compares per-file rows: the added reader must be the one row red.
  bare_rows "$T/r" > "$T/r.rows1"
  got=$(rd_delta "$T/r.rows1" "$T/r.rows0" | cut -f1)
  [ "$got" = bin/new-thing.sh ] && ok || bad "R2 delta over a copy with one added reader named '$got', want bin/new-thing.sh"
fi

# D — the drift cases, in hermetic repos (the reason delta mode exists). B has
# bin/a.sh with one bare read and a .drop that puts the tree AT the floor.
dmk() {
  local R="$1"
  scratch_rm "$R" || return 1
  mkdir -p "$R/bin" "$R/tests/switch-ratchet.d"
  printf '#!/bin/bash\n[ -f "$H/flags/a-off" ] && exit 0\n' > "$R/bin/a.sh"
  printf '#!/bin/bash\ntrue\n' > "$R/bin/b.sh"
  printf '%s\n' "$((FLOOR - 1))" > "$R/tests/switch-ratchet.d/fixture.drop"
  rd_fixture_repo "$R"
}
d_main_bare()  { printf '[ -e "$H/flags/b-disabled" ] && exit 0\n' >> "$1/bin/b.sh"; }
d_pr_docs()    { echo more >> "$1/README"; rd_git "$1" commit -qam 'pr: docs'; }
d_pr_bare()    { printf '[ -f "$H/flags/c-off" ] && exit 0\n' >> "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: a.sh gains a read'; }
d_pr_newfile() { printf '[ -f "$H/flags/n-off" ] && :\n' > "$1/bin/n.sh"; rd_git "$1" add -A; rd_git "$1" commit -qm 'pr: new reader'; }
d_pr_convert() { printf '#!/bin/bash\nlane_switch a-off && exit 0\n' > "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: convert'; }
d_drift()      { rd_main_commit "$1" 'main: b.sh gains a read' d_main_bare; }
d_merge()      { rd_git "$1" merge -q --no-edit refs/remotes/origin/main; }
d_nomain()     { rd_git "$1" update-ref -d refs/remotes/origin/main; }
dcase() {  # <name> <want_rc> <RATCHET_BASE: main|B|none|bogus> <mode> <steps...>
  local name="$1" want="$2" rb="$3" mode="$4" R="$T/d-$1" b step out rc
  shift 4
  dmk "$R" || { bad "D($name): repo setup failed"; return; }
  b=$(rd_git "$R" rev-parse HEAD)
  for step in "$@"; do "$step" "$R" >/dev/null || { bad "D($name): step $step failed"; return; }; done
  case "$rb" in
    main)  rb=$(rd_git "$R" rev-parse refs/remotes/origin/main) ;;
    B)     rb="$b" ;;
    none)  rb="" ;;
    bogus) rb=0123456789abcdef0123456789abcdef01234567 ;;
  esac
  out=$(MODE="$mode"; drops "$R" >/dev/null; EFF=$((FLOOR - DROPS)); RATCHET_BASE="$rb" TI_BASE= r1 "$R" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "D($name) rc=$rc want $want:"$'\n'"$out"; fi
}
dcase main-drift-pr-base      0 main  delta d_drift d_pr_docs d_merge
dcase main-drift-queue-draft  0 main  delta d_pr_docs d_drift d_merge
dcase main-drift-stale-base   0 B     delta d_drift d_pr_docs d_merge
dcase main-drift-local        0 none  delta d_drift d_pr_docs d_merge
dcase pr-adds-read            1 main  delta d_pr_bare
dcase pr-adds-read-after-drift 1 main delta d_drift d_pr_bare d_merge
dcase pr-adds-new-file        1 main  delta d_drift d_pr_newfile d_merge
dcase pr-converts             0 main  delta d_pr_convert
dcase bogus-base              1 bogus delta d_pr_docs
dcase no-base-at-all          1 none  delta d_pr_docs d_nomain
dcase strict-sees-drift       1 main  strict d_drift d_pr_docs d_merge
dcase strict-clean            0 main  strict d_pr_docs

echo "switch-ratchet.bh-2320 ($MODE): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
