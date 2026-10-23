#!/bin/bash
# tests/test-impact-fn-reach.bh-7288-test.sh — BH-7288 (BH-7033.2): A LIBRARY
# CHANGE SELECTS BY THE CHANGED FUNCTIONS, NOT BY EVERY SOURCER.
#
# A diff to one function of a bin/lib/*.sh file selected every suite that
# sources the file. bin/lib/test-impact-fn-reach.sh (fnr_apply, one hook line
# in ti_select_from) narrows the why rows of such a path to the suites that
# reach a CHANGED function: they name it, name a caller of it, run a script
# that calls it, read the file, or scan its directory. Anything it cannot
# prove falls back to today's every-sourcer reach for that path and says why.
#
# Every case drives the real bin/test-impact.sh against a scratch git repo.
#   F1  one function changed in a lib 50 suites source: only its namers
#   F2  callers: same-lib caller, other-lib caller, entry script caller
#   F3/F4/F17  top-level change, top-level comment, indented guard: fallback
#              (F4: comment only, and fallback with TI_COMMENT_ONLY=0)
#   F5/F14  knob 0 and an unknown knob value: today's reach, one off line
#   F6/F7/F8/F10  no base, renamed/added, deleted file, short name, parse
#   F9  a deleted function still selects its namers
#   F11 two libs, one narrowed and one in fallback
#   F12 the why rows keep their format; plain select agrees with --why
#   F13 the merge-queue batch path (--changed + TI_NAMED_BASE)
#   F15 the lib missing next to the script: fallback (lib failed)
#   F16 fnr_eligible: the selector's own lib and non-lib paths
#   F17 an indented guard definition is top-level
#   F18 a tests/lib/ helper that calls a changed function keeps its suites
#   F19 a top-level call of a changed function in the same lib: fallback
#   F20 a top-level call of a caller of a changed function: fallback
#   F21 a helper in another tests/ subfolder is a caller path
#
# Self-contained: no network, no secrets, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
LIB="$DIR/bin/lib/test-impact-fn-reach.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "test-impact-fn-reach-7288: git is required"; exit 2; }

# ── the scratch repository ──────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests"
cat > "$R/bin/lib/wide.sh" <<'SH'
#!/bin/bash
wide_alpha_fn() {
  echo alpha
}
wide_beta_fn() {
  echo beta
}
wide_gamma_fn() {
  wide_alpha_fn
  echo gamma
}
ok() { :; }
SH
cat > "$R/bin/lib/other.sh" <<'SH'
#!/bin/bash
# shellcheck source=bin/lib/wide.sh
. "$(dirname "${BASH_SOURCE[0]}")/wide.sh"
other_wrap_fn() {
  wide_alpha_fn
}
SH
cat > "$R/bin/tool.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/wide.sh"
wide_alpha_fn
SH
for i in $(seq -w 1 50); do
  case "$i" in
    01|02|03) call=wide_alpha_fn ;;
    04|05)    call=wide_beta_fn ;;
    06)       call=wide_gamma_fn ;;
    *)        call="echo src" ;;
  esac
  cat > "$R/tests/src-$i-test.sh" <<SH
#!/bin/bash
DIR=\$(cd "\$(dirname "\$0")/.." && pwd)
. "\$DIR/bin/lib/wide.sh"
$call
SH
done
cat > "$R/tests/tool-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/tool.sh" >/dev/null
SH
cat > "$R/tests/other-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/other.sh"
other_wrap_fn
SH
cat > "$R/tests/scan-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -rn x "$DIR/bin/lib" >/dev/null
SH
cat > "$R/tests/copy-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
cp "$DIR/bin/lib/"*.sh "$T/"
SH
cat > "$R/tests/pin-text-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -c wide "$DIR/bin/lib/wide.sh"
SH
cat > "$R/tests/wide-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
git -C "$DIR" ls-files | wc -l
SH
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

# sel <label> [env...] — plain select and --why over BASE..HEAD, both kept.
sel() {
  local label="$1"; shift
  env "$@" "$TI" --root "$R" select "$BASE..HEAD" > "$T/$label.sel" 2> "$T/$label.err"
  env "$@" "$TI" --root "$R" select "$BASE..HEAD" --why > "$T/$label.why" 2>> "$T/$label.err"
}
has()   { grep -qxF "$2" "$T/$1.sel"; }
srcn()  { grep -c '^tests/src-' "$T/$1.sel"; }
errhas() { grep -qF -- "$2" "$T/$1.err"; }
reset_base() { gitc reset -q --hard "$BASE"; }
commit() { gitc add -A; gitc commit -qm "$1"; }
show() { tr '\n' ' ' < "$T/$1.sel"; echo "| $(tr '\n' ' ' < "$T/$1.err")"; }

# ── F1: one function in a lib 50 suites source ─────────────────────────────
reset_base
sed -i 's/echo beta/echo beta changed/' "$R/bin/lib/wide.sh"; commit F1
sel F1
printf '%s\n' tests/pin-text-test.sh tests/scan-test.sh tests/src-04-test.sh tests/src-05-test.sh tests/wide-test.sh > "$T/F1.want"
cmp -s "$T/F1.want" "$T/F1.sel" && ok || bad "F1: a wide_beta_fn change must select exactly src-04, src-05, pin-text, scan, wide (got: $(show F1))"
has F1 tests/copy-test.sh && bad "F1: a copy-only directory row (cp bin/lib/*.sh) must not keep copy-test" || ok
errhas F1 'fn-reach: bin/lib/wide.sh: kept' && errhas F1 wide_beta_fn && ok \
  || bad "F1: stderr must say 'fn-reach: bin/lib/wide.sh: kept … wide_beta_fn' (got: $(cat "$T/F1.err"))"
N1=$(grep -c . "$T/F1.sel")
grep -qE "^impact: $N1 of [0-9]+ suites" "$T/F1.err" && ok || bad "F1: the impact: N must equal the plain select count $N1 (got: $(grep '^impact:' "$T/F1.err"))"
sel F1off TI_FN_REACH=0
[ "$(srcn F1off)" -ge 50 ] && ok || bad "F1: with TI_FN_REACH=0 the same diff must select all 50 sourcers (got $(srcn F1off))"

# ── F12: the why format round-trip, on F1 ───────────────────────────────────
BADROW=$(awk -F'\t' 'NF != 3 || $2 !~ /^(self|reads|named|source|learned|closure|always|regression)$/' "$T/F1.why")
[ -z "$BADROW" ] && [ -s "$T/F1.why" ] && ok || bad "F12: malformed --why rows after the filter: $(head -3 <<<"$BADROW")"
cut -f1 "$T/F1.why" | LC_ALL=C sort -u > "$T/F1.whysuites"
cmp -s "$T/F1.whysuites" "$T/F1.sel" && ok || bad "F12: plain select and --why disagree ($(diff "$T/F1.whysuites" "$T/F1.sel" | tr '\n' ' '))"

# ── F2: callers ─────────────────────────────────────────────────────────────
reset_base
sed -i 's/echo alpha/echo alpha changed/' "$R/bin/lib/wide.sh"; commit F2
sel F2
for s in 01 02 03 06; do has F2 "tests/src-$s-test.sh" && ok || bad "F2: src-$s must be kept (a wide_alpha_fn caller) (got: $(show F2))"; done
has F2 tests/tool-test.sh && ok || bad "F2: tool-test runs bin/tool.sh, which calls wide_alpha_fn (got: $(show F2))"
has F2 tests/other-test.sh && ok || bad "F2: other-test calls other_wrap_fn, which calls wide_alpha_fn (got: $(show F2))"
for s in 04 05 07 30 50; do has F2 "tests/src-$s-test.sh" && bad "F2: src-$s reaches no changed function and must be dropped" || ok; done

# ── F3 / F4: a top-level change falls back, byte-equal to the knob-off run ──
fallback_equal() { # <label> <what>
  cmp -s "$T/$1.why" "$T/$1off.why" && ok || bad "$2: the --why output must equal the TI_FN_REACH=0 run ($(diff "$T/$1.why" "$T/$1off.why" | head -4 | tr '\n' ' '))"
}
reset_base
sed -i 's/^ok() { :; }$/WIDE_X=1\nok() { :; }/' "$R/bin/lib/wide.sh"; commit F3
sel F3; sel F3off TI_FN_REACH=0
errhas F3 'fn-reach: fallback (top-level change at head:' && ok || bad "F3: a top-level line must fall back (got: $(cat "$T/F3.err"))"
fallback_equal F3 F3
[ "$(srcn F3)" -ge 50 ] && ok || bad "F3: the fallback keeps all 50 sourcers (got $(srcn F3))"

reset_base
sed -i 's/^wide_beta_fn() {$/# note\nwide_beta_fn() {/' "$R/bin/lib/wide.sh"; commit F4
# BH-8099: rule P skips an inert comment line, so a comment-only diff is
# `comment only`; with TI_COMMENT_ONLY=0 the old fallback holds.
sel F4
errhas F4 'fn-reach: comment only (bin/lib/wide.sh)' && ok || bad "F4: a top-level comment alone must be comment only (got: $(cat "$T/F4.err"))"
sel F4c TI_COMMENT_ONLY=0; sel F4coff TI_COMMENT_ONLY=0 TI_FN_REACH=0
errhas F4c 'fn-reach: fallback (top-level change at head:' && ok || bad "F4: with TI_COMMENT_ONLY=0 a top-level comment must fall back (got: $(cat "$T/F4c.err"))"
fallback_equal F4c F4

# ── F5 / F14: the knob ──────────────────────────────────────────────────────
reset_base
sed -i 's/echo beta/echo beta changed/' "$R/bin/lib/wide.sh"; commit F5
sel F5 TI_FN_REACH=0
errhas F5 'fn-reach: off (TI_FN_REACH=0)' && [ "$(srcn F5)" -ge 50 ] && ok \
  || bad "F5: TI_FN_REACH=0 must say off and keep all 50 sourcers (got $(srcn F5): $(cat "$T/F5.err"))"
sel F14 TI_FN_REACH=yes
errhas F14 'fn-reach: off (TI_FN_REACH=yes)' && [ "$(srcn F14)" -ge 50 ] && ok \
  || bad "F14: an unknown knob value is off, with all sourcers (got $(srcn F14): $(cat "$T/F14.err"))"
sel F1unset TI_FN_REACH=
[ "$(srcn F1unset)" -eq 2 ] && ok || bad "F14: an empty knob is on (got $(srcn F1unset) src suites)"

# ── F6: no base (a --changed list without TI_NAMED_BASE) ────────────────────
printf 'bin/lib/wide.sh\n' > "$T/F6.changed"
"$TI" --root "$R" select --changed "$T/F6.changed" > "$T/F6.sel" 2> "$T/F6.err"
errhas F6 'fn-reach: fallback (no base: bin/lib/wide.sh)' && [ "$(srcn F6)" -ge 50 ] && ok \
  || bad "F6: --changed with no base must fall back with all sourcers (got $(srcn F6): $(cat "$T/F6.err"))"

# ── F13: the batch path ─────────────────────────────────────────────────────
TI_BATCH_SELECT=1 TI_NAMED_BASE="$BASE" "$TI" --root "$R" select --changed "$T/F6.changed" > "$T/F13.sel" 2> "$T/F13.err"
cmp -s "$T/F1.want" "$T/F13.sel" && ok || bad "F13: the batch select must give F1's 5-suite set (got: $(show F13))"
grep -q '^impact: 5 of [0-9]* suites (selected:' "$T/F13.err" && ok || bad "F13: the reason must be selected:, not full (got: $(grep '^impact:' "$T/F13.err"))"

# ── F7: rename / delete ─────────────────────────────────────────────────────
reset_base
gitc mv bin/lib/wide.sh bin/lib/wide2.sh
sed -i 's#bin/lib/wide.sh#bin/lib/wide2.sh#; s#lib/wide.sh#lib/wide2.sh#; s#/wide.sh"#/wide2.sh"#' \
  "$R"/tests/src-*-test.sh "$R/bin/tool.sh" "$R/bin/lib/other.sh"
commit F7
sel F7
errhas F7 'fn-reach: fallback (no base copy: bin/lib/wide2.sh)' && [ "$(srcn F7)" -ge 50 ] && ok \
  || bad "F7: a renamed lib must fall back (no base copy) with all sourcers (got $(srcn F7): $(grep fn-reach "$T/F7.err"))"
reset_base
gitc rm -q bin/lib/wide.sh; commit F7d
sel F7d
errhas F7d 'fn-reach: fallback (deleted file: bin/lib/wide.sh)' && ok || bad "F7: a deleted lib must fall back (got: $(grep fn-reach "$T/F7d.err"))"

# ── F8: a short name ────────────────────────────────────────────────────────
reset_base
sed -i 's/^ok() { :; }$/ok() { : changed; }/' "$R/bin/lib/wide.sh"; commit F8
sel F8
errhas F8 'fn-reach: fallback (short name ok' && [ "$(srcn F8)" -ge 50 ] && ok \
  || bad "F8: a changed short-named function must fall back (got $(srcn F8): $(grep fn-reach "$T/F8.err"))"

# ── F9: a deleted function ──────────────────────────────────────────────────
reset_base
sed -i '/^wide_beta_fn() {$/,/^}$/d' "$R/bin/lib/wide.sh"; commit F9
sel F9
has F9 tests/src-04-test.sh && has F9 tests/src-05-test.sh && ok || bad "F9: a deleted wide_beta_fn must still select its namers (got: $(show F9))"
[ "$(srcn F9)" -eq 2 ] && ok || bad "F9: only the 2 namers of the deleted function (got $(srcn F9): $(show F9))"

# ── F10: a parse failure ────────────────────────────────────────────────────
reset_base
sed -i '0,/^}$/s//  echo unclosed/' "$R/bin/lib/wide.sh"; commit F10
sel F10; sel F10off TI_FN_REACH=0
errhas F10 'fn-reach: fallback (parse:' && [ "$(srcn F10)" -ge 50 ] && ok \
  || bad "F10: an unclosed function must fall back as parse (got $(srcn F10): $(grep fn-reach "$T/F10.err"))"
fallback_equal F10 F10

# ── F11: two libs, one narrowed and one in fallback ─────────────────────────
reset_base
sed -i 's/echo beta/echo beta changed/' "$R/bin/lib/wide.sh"
echo 'OTHER_X=1' >> "$R/bin/lib/other.sh"; commit F11
sel F11
errhas F11 'fn-reach: bin/lib/wide.sh: kept' && errhas F11 'fn-reach: fallback (top-level change at head:' && errhas F11 'bin/lib/other.sh)' && ok \
  || bad "F11: wide.sh narrows and other.sh falls back (got: $(grep fn-reach "$T/F11.err"))"
has F11 tests/other-test.sh && ok || bad "F11: other-test sources the fallback lib and must stay (got: $(show F11))"
[ "$(srcn F11)" -eq 2 ] && ok || bad "F11: wide.sh's rows still narrow to its 2 namers (got $(srcn F11))"

# ── F15: the lib missing next to the script ─────────────────────────────────
reset_base
sed -i 's/echo beta/echo beta changed/' "$R/bin/lib/wide.sh"; commit F15
# scratch-closure-allow: F15 needs bin/test-impact.sh WITHOUT its fn-reach lib, to prove the lib-failed fallback
mkdir -p "$T/nolib/bin"; cp "$TI" "$T/nolib/bin/test-impact.sh"
"$T/nolib/bin/test-impact.sh" --root "$R" select "$BASE..HEAD" > "$T/F15.sel" 2> "$T/F15.err"
TI_FN_REACH=0 "$TI" --root "$R" select "$BASE..HEAD" > "$T/F15off.sel" 2>/dev/null
errhas F15 'fn-reach: fallback (lib failed)' && cmp -s "$T/F15.sel" "$T/F15off.sel" && ok \
  || bad "F15: a missing lib must say 'lib failed' and select what knob-off selects (got: $(grep fn-reach "$T/F15.err"); $(diff "$T/F15.sel" "$T/F15off.sel" | head -3 | tr '\n' ' '))"

# ── F16: eligibility ────────────────────────────────────────────────────────
elig() ( # <path> [env...] — rc of fnr_eligible in a clean shell
  p="$1"; shift
  env "$@" bash -c '. "$1" || exit 9; fnr_eligible "$2"' _ "$LIB" "$p"
)
elig bin/lib/test-impact-fn-reach.sh TI_NAMED_BASE=x; [ $? -eq 1 ] && ok || bad "F16: the selector's own lib must not be eligible"
elig bin/tool.sh TI_NAMED_BASE=x; [ $? -eq 1 ] && ok || bad "F16: a non-lib path must not be eligible"
elig bin/lib/mc/x.sh TI_NAMED_BASE=x; [ $? -eq 0 ] && ok || bad "F16: bin/lib/mc/x.sh with a base and the knob on is eligible"
elig bin/lib/x.md TI_NAMED_BASE=x; [ $? -eq 1 ] && ok || bad "F16: a non-.sh lib path must not be eligible"
reset_base
sed -i 's/^wide_alpha_fn$/wide_alpha_fn; echo more/' "$R/bin/tool.sh"; commit F16
sel F16
errhas F16 'fn-reach:' && bad "F16: a bin/tool.sh change must print no fn-reach: line (got: $(grep fn-reach "$T/F16.err"))" || ok

# ── F17: an indented definition in a top-level guard ────────────────────────
reset_base
cat >> "$R/bin/lib/wide.sh" <<'SH'
if ! command -v wide_guard_fn >/dev/null; then
  wide_guard_fn() { echo guard; }
fi
SH
commit F17base
B17=$(git -C "$R" rev-parse HEAD)
sed -i 's/echo guard/echo guard changed/' "$R/bin/lib/wide.sh"; commit F17
"$TI" --root "$R" select "$B17..HEAD" > "$T/F17.sel" 2> "$T/F17.err"
errhas F17 'fn-reach: fallback (top-level change at' && [ "$(srcn F17)" -ge 50 ] && ok \
  || bad "F17: a change to an indented guard definition is top-level (got $(srcn F17): $(grep fn-reach "$T/F17.err"))"

# ── F18: a tests/lib/ helper is a caller path ───────────────────────────────
# A suite that sources the lib and a helper, and calls only the helper, which
# calls the changed lib function: the suite must stay (the rcache_install ->
# _rg_render shape of tests/account-routing-test.sh).
reset_base
mkdir -p "$R/tests/lib"
cat > "$R/tests/lib/wide-helper.sh" <<'SH'
#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/../../bin/lib/wide.sh"
helper_install_fix() {
  wide_beta_fn > /dev/null
}
SH
cat > "$R/tests/helper-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/wide.sh"
. "$DIR/tests/lib/wide-helper.sh"
helper_install_fix
SH
commit F18base
B18=$(git -C "$R" rev-parse HEAD)
sed -i 's/echo beta/echo beta changed/' "$R/bin/lib/wide.sh"; commit F18
"$TI" --root "$R" select "$B18..HEAD" > "$T/F18.sel" 2> "$T/F18.err"
errhas F18 'fn-reach: bin/lib/wide.sh: kept' && ok || bad "F18: wide.sh must narrow (got: $(grep fn-reach "$T/F18.err"))"
has F18 tests/helper-test.sh && ok || bad "F18: helper-test reaches wide_beta_fn through tests/lib/wide-helper.sh and must stay (got: $(show F18))"
[ "$(srcn F18)" -eq 2 ] && ok || bad "F18: the src suites still narrow to the 2 namers (got $(srcn F18))"

# ── F19: the lib calls its changed function at load time ────────────────────
# A top-level call runs every time a script sources the lib, so every sourcer
# depends on the function (the _pr_source_stages shape of
# bin/lib/prebuild-repro.sh). The path must fall back to every sourcer.
reset_base
printf 'wide_beta_fn >/dev/null\n' >> "$R/bin/lib/wide.sh"
commit F19base
B19=$(git -C "$R" rev-parse HEAD)
sed -i 's/echo beta/echo beta changed/' "$R/bin/lib/wide.sh"; commit F19
"$TI" --root "$R" select "$B19..HEAD" > "$T/F19.sel" 2> "$T/F19.err"
errhas F19 'fn-reach: fallback (top-level call of wide_beta_fn: bin/lib/wide.sh)' && ok \
  || bad "F19: a top-level call of the changed function must fall back (got: $(grep fn-reach "$T/F19.err"))"
[ "$(srcn F19)" -ge 50 ] && ok || bad "F19: every sourcer runs the top-level call and must stay (got $(srcn F19))"

# ── F20: the lib calls a CALLER of the changed function at load time ────────
reset_base
printf 'wide_gamma_fn >/dev/null\n' >> "$R/bin/lib/wide.sh"
commit F20base
B20=$(git -C "$R" rev-parse HEAD)
sed -i 's/echo alpha/echo alpha changed/' "$R/bin/lib/wide.sh"; commit F20
"$TI" --root "$R" select "$B20..HEAD" > "$T/F20.sel" 2> "$T/F20.err"
errhas F20 'fn-reach: fallback (top-level call of wide_gamma_fn: bin/lib/wide.sh)' && ok \
  || bad "F20: a top-level call of a caller of the changed function must fall back (got: $(grep fn-reach "$T/F20.err"))"
[ "$(srcn F20)" -ge 50 ] && ok || bad "F20: every sourcer reaches wide_alpha_fn at load time and must stay (got $(srcn F20))"

# ── F21: a helper in another tests/ subfolder is a caller path ──────────────
reset_base
mkdir -p "$R/tests/helpers"
cat > "$R/tests/helpers/wide-helper.sh" <<'SH'
#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/../../bin/lib/wide.sh"
helper_other_fix() {
  wide_beta_fn > /dev/null
}
SH
cat > "$R/tests/helper2-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/wide.sh"
. "$DIR/tests/helpers/wide-helper.sh"
helper_other_fix
SH
commit F21base
B21=$(git -C "$R" rev-parse HEAD)
sed -i 's/echo beta/echo beta changed/' "$R/bin/lib/wide.sh"; commit F21
"$TI" --root "$R" select "$B21..HEAD" > "$T/F21.sel" 2> "$T/F21.err"
errhas F21 'fn-reach: bin/lib/wide.sh: kept' && ok || bad "F21: wide.sh must narrow (got: $(grep fn-reach "$T/F21.err"))"
has F21 tests/helper2-test.sh && ok || bad "F21: helper2-test reaches wide_beta_fn through tests/helpers/wide-helper.sh and must stay (got: $(show F21))"

echo "test-impact-fn-reach-7288: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
