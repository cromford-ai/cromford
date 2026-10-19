#!/bin/bash
# tests/lane-move-review-autopilot.bh-7427-test.sh — BH-7427: review-autopilot
# stays on the hub. Its project run needs the hub's repo clone for the free
# verdict replay, and it writes no per-project "run done" line for
# bin/lane-move.sh to count. So the seeds carry a
# lane_placement.review-autopilot.hub_only row with that reason, and no module
# or placement row moves the lane.
#
#   H1  exactly one schema.d line holds 'lane_placement.review-autopilot.hub_only',
#       in the BH-7427 fragment: INSERT OR IGNORE, actor seed, value starts
#       "BH-7427:"
#   H2  no fragment seeds 'lane_placement.review-autopilot' itself, and
#       bin/lib/lane-move/review-autopilot.sh does not exist
#   H3  the REAL lp_decide (bin/lib/lane-placement.sh) with a stub settings
#       store: lane row fly + the seeded reason -> hub "hub_only: BH-7427...";
#       fly + "x" -> hub; fly + empty -> fly; fly + no row -> fly; no lane
#       row (default hub) -> hub
#   H4  this ticket's commits touch neither bin/lane-move.sh nor any
#       bin/lib/lane-move/ module (skip when the branch holds none)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-move-review-autopilot.bh-7427-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

FRAG="$REPO/worker/jobs/schema.d/202610191522-bh-7427-review-autopilot-hub-only.sql"
KEY="'lane_placement.review-autopilot.hub_only'"

# ── H1: the seed row ────────────────────────────────────────────────────────
echo "H1: the hub_only seed row"
HITS=$(grep -lF "$KEY" "$REPO"/worker/jobs/schema.d/*.sql 2>/dev/null)
N=$(cat "$REPO"/worker/jobs/schema.d/*.sql 2>/dev/null | grep -cF "$KEY")
[ "$N" = 1 ] && ok "H1: one schema.d line holds $KEY" || bad "H1: $N schema.d lines hold $KEY"
[ "$HITS" = "$FRAG" ] && ok "H1: the line is in the BH-7427 fragment" || bad "H1: the line is in '${HITS:-no file}', want $FRAG"
LINE=$(grep -F "$KEY" "$FRAG" 2>/dev/null | head -1)
# value: the SQL string after the key, with doubled quotes undone.
VAL=$(sed -nE "s/.*$KEY[[:space:]]*,[[:space:]]*'(([^']|'')*)'.*/\1/p" <<<"$LINE" | sed "s/''/'/g")
[[ $VAL == BH-7427:?* ]] && ok "H1: the value starts 'BH-7427:' and has a reason" || bad "H1: value = '$VAL'"
grep -qE "'seed'[[:space:]]*,[[:space:]]*'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'\)" <<<"$LINE" \
  && ok "H1: actor seed" || bad "H1: no actor 'seed' on the row: $LINE"
grep -vE '^[[:space:]]*--' "$FRAG" 2>/dev/null | tr '\n' ' ' | grep -qE "INSERT OR IGNORE INTO settings[^;]*$KEY" \
  && ok "H1: the statement is INSERT OR IGNORE INTO settings" || bad "H1: not an INSERT OR IGNORE INTO settings statement"

# ── H2: nothing moves the lane ──────────────────────────────────────────────
echo "H2: no placement row and no module"
if cat "$REPO"/worker/jobs/schema.d/*.sql 2>/dev/null | grep -qF "'lane_placement.review-autopilot'"; then
  bad "H2: a fragment seeds 'lane_placement.review-autopilot'"
else ok "H2: no fragment seeds 'lane_placement.review-autopilot'"; fi
[ ! -e "$REPO/bin/lib/lane-move/review-autopilot.sh" ] && ok "H2: no bin/lib/lane-move/review-autopilot.sh" \
  || bad "H2: bin/lib/lane-move/review-autopilot.sh exists"

# ── H3: the real lp_decide reads the row ────────────────────────────────────
echo "H3: lp_decide review-autopilot"
( cd "$REPO" && scratch_install_closure bin/lib/lane-placement.sh "$T" ) >/dev/null \
  || { bad "H3: setup: closure of bin/lib/lane-placement.sh"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
# decide <lane-row|-> <hub_only|-|rc2> — runs lp_decide in a subshell over a
# stub settings store and prints "<LP_PLACE>|<LP_WHY>". '-' = no row.
decide() {
  ( LANE_ROW="$1" HO_ROW="$2"
    _jobs_req() { return 0; }
    _setting_key_ok() { [[ "$1" =~ ^[a-z0-9_.-]{1,64}$ ]]; }
    setting_get() {
      case "$1" in
        lane_placement.default)                [ "${DEF_ROW:-hub}" = - ] && return 2; printf '%s' "${DEF_ROW:-hub}" ;;
        lane_placement.review-autopilot)       [ "$LANE_ROW" = - ] && return 2; printf '%s' "$LANE_ROW" ;;
        lane_placement.review-autopilot.hub_only) [ "$HO_ROW" = - ] && return 2; printf '%s' "$HO_ROW" ;;
        *) return 2 ;;
      esac
    }
    HARNESS="$T"
    # shellcheck source=bin/lib/lane-placement.sh
    . "$T/bin/lib/lane-placement.sh" || exit 1
    lp_decide review-autopilot
    printf '%s|%s' "$LP_PLACE" "$LP_WHY" )
}
R=$(decide fly "$VAL")
[ -n "$VAL" ] && [ "$R" = "hub|hub_only: $VAL" ] && ok "H3: fly + the seeded reason -> hub, LP_WHY 'hub_only: BH-7427...'" \
  || bad "H3: fly + seeded reason -> '$R'"
R=$(decide fly x);  [ "$R" = "hub|hub_only: x" ] && ok "H3: fly + 'x' -> hub" || bad "H3: fly + 'x' -> '$R'"
R=$(decide fly ""); [ "${R%%|*}" = fly ] && ok "H3: fly + empty hub_only -> fly" || bad "H3: fly + empty -> '$R'"
R=$(decide fly -);  [ "${R%%|*}" = fly ] && ok "H3: fly + no hub_only row -> fly" || bad "H3: fly + no row -> '$R'"
R=$(decide - "$VAL"); [ "$R" = "hub|lane_placement.default='hub' is not fly" ] \
  && ok "H3: no lane row, default hub -> hub, hub_only not needed" || bad "H3: no lane row -> '$R'"

# ── H4: this ticket's commits leave lane-move alone ─────────────────────────
echo "H4: no edit to bin/lane-move.sh or a lane-move module"
# Scoped to this ticket's own commits (D57): on main after the merge, or with
# no origin/main, the range holds none of them and the case is a skip note.
if git -C "$REPO" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  OWN=$(git -C "$REPO" log --format=%H --grep='BH-7427' origin/main..HEAD 2>/dev/null)
  if [ -n "$OWN" ]; then
    CH=$(for c in $OWN; do git -C "$REPO" show --format= --name-only "$c"; done | sort -u)
    if grep -qE '^bin/lane-move\.sh$|^bin/lib/lane-move/' <<<"$CH"; then
      bad "H4: a BH-7427 commit edits: $(grep -E '^bin/lane-move\.sh$|^bin/lib/lane-move/' <<<"$CH" | tr '\n' ' ')"
    else ok "H4: BH-7427 commits touch neither bin/lane-move.sh nor bin/lib/lane-move/"; fi
  else
    echo "note: H4 skip, this branch holds no BH-7427 commit"
  fi
else
  echo "note: H4 skip, no origin/main"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
