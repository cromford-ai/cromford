#!/bin/bash
# tests/blocked-resolver-merged-memo.bh-9897-test.sh — BH-9897 item 5: the
# blocked-resolver's conductor discovery skips a row whose PR the closed-watch
# memo says is merged. The conductor's off-list settle moves that row to
# MERGED; the resolver must not count it as a candidate first.
#
# WHAT THIS PINS.
#   R1 brmm_merged truth table: rc 0 only for a regular memo file whose first
#      tab field is exactly `merged`, under the key's own slug.
#   R2 br_from_conductor, cut from the REAL driver and run with stubbed
#      helpers: BLOCKED_HUMAN+merged and RED_TWICE+merged are skipped,
#      BLOCKED_HUMAN+closed and BLOCKED_HUMAN with no memo are emitted. A
#      merged-memo hand-off is skipped before its row field is read.
#   R3 brmm_say: one say line with the count, nothing at 0, scratch removed.
#   R4 mutation: the same cut with the brmm_merged lines deleted emits all four.
#   L1 the real fragment loader block sources the fragment; BR_OPT_OFF=
#      bh-9897-merged-memo-skip skips it.
#
# Run from anywhere: tests/blocked-resolver-merged-memo.bh-9897-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
DRIVER="$REPO/bin/blocked-resolver.sh"
FRAG="$REPO/bin/blocked-resolver.d/bh-9897-merged-memo-skip.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3], got [$2])"; fi; }

[ -f "$FRAG" ] || { bad "fragment $FRAG exists"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# The real mc_safe_name, from the lib that defines it.
SAFE_DEF=$(grep -m1 '^mc_safe_name()' "$REPO/bin/lib/mc/locks.sh")
[ -n "$SAFE_DEF" ] || bad "mc_safe_name found in bin/lib/mc/locks.sh"

CW="$T/state/merge-conductor/closed-watch"
memo() { # memo <slug> <num> <content>
  local d; d="$CW/${1//[^A-Za-z0-9._-]/_}"; mkdir -p "$d"; printf '%b' "$3" > "$d/$2"
}

# ---- R1: truth table -------------------------------------------------------
echo "R1 brmm_merged truth table"
memo example-org/demo 1 'merged\t1763800000\thttps://x/1\tb\n'
memo example-org/demo 2 'closed\t1763800000\thttps://x/2\tb\n'
memo example-org/demo 3 'gone\t1763800000\thttps://x/3\tb\n'
memo example-org/demo 4 'open\t1763800000\thttps://x/4\tb\n'
memo example-org/demo 5 'open\t0\n'
memo example-org/demo 6 'open 0\n'
mkdir -p "$CW/example-org_demo/7"
memo example-org/other 8 'merged\t1763800000\thttps://x/8\tb\n'
memo example-org/demo 9 'mergedX\t1763800000\thttps://x/9\tb\n'
memo example-org/demo 10 'merged\n'
memo example-org/demo 11 'merged 1763800000\n'
memo example-org/demo 12 'merged\t1\n'; chmod 000 "$CW/example-org_demo/12"

r1() { # r1 <key> — prints brmm_merged's rc in a clean shell
  ( unset MC_CLOSED_WATCH_DIR; MC_STATE_DIR="$T/state/merge-conductor"; TMPDIR="$T/tmp1"; mkdir -p "$TMPDIR"
    eval "$SAFE_DEF"; say() { :; }; . "$FRAG"; brmm_merged "$1"; echo $? )
}
chk "merged memo -> skip"                 "$(r1 'example-org/demo#1')" 0
chk "merged, field alone -> skip"         "$(r1 'example-org/demo#10')" 0
chk "closed memo -> keep"                 "$(r1 'example-org/demo#2')" 1
chk "gone memo -> keep"                   "$(r1 'example-org/demo#3')" 1
chk "open memo -> keep"                   "$(r1 'example-org/demo#4')" 1
chk "open<TAB>0 memo -> keep"             "$(r1 'example-org/demo#5')" 1
chk "'open 0' memo -> keep"               "$(r1 'example-org/demo#6')" 1
chk "memo is a directory -> keep"         "$(r1 'example-org/demo#7')" 1
chk "same num, other repo's memo -> keep" "$(r1 'example-org/demo#8')" 1
chk "no memo -> keep"                     "$(r1 'example-org/demo#99')" 1
chk "mergedX field -> keep"               "$(r1 'example-org/demo#9')" 1
chk "'merged 1763...' (no tab) -> keep"   "$(r1 'example-org/demo#11')" 1
chk "key with no # -> keep"               "$(r1 'example-org/demo')" 1
chk "non-numeric num -> keep"             "$(r1 'example-org/demo#1x')" 1
chk "empty num -> keep"                   "$(r1 'example-org/demo#')" 1
if [ "$(id -u)" != 0 ]; then
  chk "unreadable memo -> keep"           "$(r1 'example-org/demo#12')" 1
else
  ok "unreadable memo: skipped as root (root reads mode 000)"
fi
chmod 644 "$CW/example-org_demo/12"
# MC_CLOSED_WATCH_DIR overrides the state dir.
r1b=$( MC_CLOSED_WATCH_DIR="$CW"; MC_STATE_DIR="$T/nowhere"; TMPDIR="$T/tmp1"
       eval "$SAFE_DEF"; say() { :; }; . "$FRAG"; brmm_merged 'example-org/demo#1'; echo $? )
chk "MC_CLOSED_WATCH_DIR is honoured" "$r1b" 0
# A hit writes one scratch line under the process's own pid; a miss writes none.
r1c=$( MC_STATE_DIR="$T/state/merge-conductor"; TMPDIR="$T/tmp2"; mkdir -p "$TMPDIR"
       eval "$SAFE_DEF"; say() { :; }; . "$FRAG"
       brmm_merged 'example-org/demo#1'; brmm_merged 'example-org/demo#2'; brmm_merged 'example-org/demo#10'
       wc -l < "$TMPDIR/br-mm.$$" | tr -d ' ' )
chk "two hits, one miss -> 2 scratch lines" "$r1c" 2

# ---- R2/R4: br_from_conductor cut ------------------------------------------
cut_fn() { awk '/^br_from_conductor\(\) \{/{on=1} on{print} on&&/^\}/{exit}' "$DRIVER"; }
cut_fn > "$T/bfc.sh"
grep -q '^br_from_conductor() {' "$T/bfc.sh" || bad "br_from_conductor cut from the driver"
n_calls=$(grep -c 'brmm_merged "\$key" && continue' "$T/bfc.sh")
chk "two brmm_merged call lines in br_from_conductor" "$n_calls" 2
chk "one brmm_say call line in br_from_conductor" "$(grep -c 'command -v brmm_say' "$T/bfc.sh")" 1
grep -v 'brmm_merged "\$key" && continue' "$T/bfc.sh" > "$T/bfc-mut.sh"

# Rows: BLOCKED_HUMAN+merged (#1), RED_TWICE+merged (#10), BLOCKED_HUMAN+closed
# (#2), BLOCKED_HUMAN no memo (#99). key st since head rev al why url
NOW=$(date -u +%s)
{
  printf 'example-org/demo#1\tBLOCKED_HUMAN\t%s\taaaaaaaa\t-\t-\tci-red\thttps://github.com/example-org/demo/pull/1\n' "$((NOW-100))"
  printf 'example-org/demo#10\tRED_TWICE\t%s\tbbbbbbbb\t-\t-\tci-red\thttps://github.com/example-org/demo/pull/10\n' "$((NOW-200))"
  printf 'example-org/demo#2\tBLOCKED_HUMAN\t%s\tcccccccc\t-\t-\tci-red\thttps://github.com/example-org/demo/pull/2\n' "$((NOW-300))"
  printf 'example-org/demo#99\tBLOCKED_HUMAN\t%s\tdddddddd\t-\t-\tci-red\thttps://github.com/example-org/demo/pull/99\n' "$((NOW-400))"
} > "$T/rows.tsv"

# run_bfc <cut file> <handoff mode: none|merged> — runs the cut in a clean
# shell; EMIT holds the emitted keys (sorted), SAYS the say lines, ROWF the
# keys whose row field the hand-off loop read.
BFC_N=0
run_bfc() {
  BFC_N=$((BFC_N+1)); local cut=$1 mode=$2 d="$T/run-$BFC_N"
  mkdir -p "$d/tmp"
  cat > "$d/runner.sh" <<'EOF'
set -uo pipefail
D=$1; CUT=$2; FRAG=$3; MODE=$4; SAFE_DEF=$5; ROWS=$6; MCS=$7
MC_ROWS="$ROWS"; MC_STATE_DIR="$MCS"; TMPDIR="$D/tmp"; OBSERVE=1
eval "$SAFE_DEF"
say() { echo "$*" >> "$D/say"; }
br_key_in_only() { return 0; }
mc_ttl() { echo 3600; }
br_reason_of() { echo ci-red; }
br_rereview_inflight() { return 1; }
br_conductor_emit() { echo "$1" >> "$D/emit"; return 0; }
br_unmapped() { echo "UNMAPPED $1" >> "$D/emit"; }
br_prov_promote() { return 1; }
br_handoff_lines() { return 0; }
br_handoff_rows() {
  if [ "$MODE" = merged ]; then
    printf 'example-org/demo#1\tci-red\thttps://github.com/example-org/demo/pull/1\taaaaaaaa\t1\n'
    printf 'example-org/demo#2\tci-red\thttps://github.com/example-org/demo/pull/2\tcccccccc\t1\n'
    return 0
  fi
  return 2
}
mc_row_field() { echo "$1" >> "$D/rowf"; echo WAIT_CI; }
br_pr_field() { echo "closed -"; }
mc_handoff_file() { echo "$D/none"; }
. "$FRAG"
. "$CUT"
br_from_conductor; echo "RC $?" >> "$D/rc"
EOF
  env -i PATH="$PATH" LC_ALL=C bash --norc --noprofile "$d/runner.sh" "$d" "$cut" "$FRAG" "$mode" "$SAFE_DEF" "$T/rows.tsv" "$T/state/merge-conductor" 2>"$d/err"
  EMIT=$(sort "$d/emit" 2>/dev/null | tr '\n' ' ')
  SAYS=$(cat "$d/say" 2>/dev/null)
  ROWF=$(sort "$d/rowf" 2>/dev/null | tr '\n' ' ')
  BRC=$(cat "$d/rc" 2>/dev/null)
  LEFT=$(find "$d/tmp" -name 'br-mm.*' | wc -l | tr -d ' ')
  ERR=$(cat "$d/err")
}

echo "R2 br_from_conductor skips merged-memo rows"
run_bfc "$T/bfc.sh" none
chk "emits only the closed-memo and no-memo rows" "$EMIT" 'example-org/demo#2 example-org/demo#99 '
chk "function rc unchanged (0)" "$BRC" "RC 0"
chk "no stderr" "$ERR" ""
chk "scratch removed after the run" "$LEFT" 0
echo "R3 brmm_say (through the real call site)"
chk "one say line, count 2" "$SAYS" "discovery: 2 conductor row(s) skipped, PR memo'd merged (the conductor's off-list settle moves them)"
echo "R2b hand-off loop skips a merged memo before the row read"
run_bfc "$T/bfc.sh" merged
chk "hand-off row read only for the closed-memo key" "$ROWF" 'example-org/demo#2 '
# example-org/demo#1 is skipped by the row loop and again by the hand-off loop:
# it counts once, so the say line names the 2 distinct keys (BH-9897 review).
chk "say count is distinct keys, the hand-off repeat counts once (2)" "$(grep -c 'discovery: 2 conductor row(s) skipped' <<<"$SAYS")" 1
chk "say count never double-counts a key (no 3)" "$(grep -c 'discovery: 3 conductor row(s) skipped' <<<"$SAYS")" 0

echo "R3 brmm_say direct"
r3=$( MC_STATE_DIR="$T/state/merge-conductor"; TMPDIR="$T/tmp3"; mkdir -p "$TMPDIR"
      eval "$SAFE_DEF"; say() { echo "SAY $*"; }; . "$FRAG"
      brmm_say; echo "rc0=$?"
      brmm_merged 'example-org/demo#1'; brmm_merged 'example-org/demo#10'
      brmm_say; echo "rc2=$?"
      [ -e "$TMPDIR/br-mm.$$" ] && echo LEFT || echo GONE
      brmm_say; echo "rc-after=$?" )
chk "0 hits: nothing printed" "$(sed -n 1p <<<"$r3")" "rc0=0"
chk "2 hits: one say line" "$(sed -n 2p <<<"$r3")" "SAY discovery: 2 conductor row(s) skipped, PR memo'd merged (the conductor's off-list settle moves them)"
chk "rc 0 after the say" "$(sed -n 3p <<<"$r3")" "rc2=0"
chk "scratch file removed" "$(sed -n 4p <<<"$r3")" GONE
chk "second call: nothing printed" "$(sed -n 5p <<<"$r3")" "rc-after=0"

echo "R4 mutation: the call lines deleted"
run_bfc "$T/bfc-mut.sh" none
chk "all four rows emitted without the skip" "$EMIT" 'example-org/demo#1 example-org/demo#10 example-org/demo#2 example-org/demo#99 '
chk "no say line without the skip" "$SAYS" ""

# ---- L1: the real loader ---------------------------------------------------
echo "L1 the real fragment loader"
OPEN='# blocked-resolver.d (BH-7450)'; CLOSE='done; unset _br_frags'
awk -v o="$OPEN" -v c="$CLOSE" 'index($0,o)==1{on=1} on{print} on&&index($0,c)==1{on=0}' "$DRIVER" > "$T/loader.sh"
mkdir -p "$T/h/bin/blocked-resolver.d"; cp "$FRAG" "$T/h/bin/blocked-resolver.d/"
l1() { env -i PATH="$PATH" bash --norc --noprofile -c 'set -uo pipefail; H=$1; BR_OPT_OFF=$2; say() { echo "SAY $*"; }; . "$3"; command -v brmm_merged >/dev/null && echo LOADED || echo ABSENT' _ "$T/h" "$1" "$T/loader.sh"; }
chk "loader sources the fragment" "$(l1 '')" LOADED
chk "BR_OPT_OFF=bh-9897-merged-memo-skip skips it" "$(l1 'x,bh-9897-merged-memo-skip')" ABSENT
src_out=$(env -i PATH="$PATH" bash --norc --noprofile -c 'set -uo pipefail; . "$1"; compgen -v | grep -i brmm' _ "$FRAG" 2>&1)
chk "no output and no variable at source time" "$src_out" ""

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
