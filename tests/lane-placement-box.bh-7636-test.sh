#!/bin/bash
# tests/lane-placement-box.bh-7636-test.sh — BH-7636: the placement value
# `box:<name>` (bin/lib/lane-placement.sh lp_decide / lp_box_parse).
#
# Every row of tests/fixtures/bh-7636/box-placement-cases.tsv runs through the
# REAL lp_decide in a fresh process. Only the settings I/O is a stub:
# setting_get reads $T/settings/<key> (rc 2 when the file is absent),
# _setting_key_ok is the jobs client's charset rule, _jobs_req is never
# called. The same table is read by worker/jobs/test/lane-runs-box.bh-7636.test.js,
# so the shell and the worker parse one value one way.
#
#   T1  each row: LP_PLACE, LP_BOX and a substring of LP_WHY
#   T2  lp_box_parse: the name rule alone (trim, lowercase, 1..64 chars)
#   T3  a box placement leaves LP_BOX empty on the next hub/fly read
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-placement-box.bh-7636-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
CASES="$DIR/tests/fixtures/bh-7636/box-placement-cases.tsv"
[ -r "$CASES" ] || { echo "FAIL: no case table $CASES"; exit 1; }

cat > "$T/stubs.sh" <<EOF
_lp_client() { return 0; }
_jobs_req() { echo "_jobs_req \$*" >> "$T/jobs-calls.txt"; return 1; }
_setting_key_ok() { case "\${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "\${#1}" -le 64 ]; }
setting_get() { [ -e "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
EOF

# decide <lane> <project> — prints `<place>|<box>|<why>` from a fresh shell.
decide() {
  bash -c '. "$1/bin/lib/lane-placement.sh" || exit 9; . "$2" || exit 9
    LP_BOX=stale-from-before
    lp_decide "$3" "$4"; printf "%s|%s|%s" "$LP_PLACE" "${LP_BOX:-}" "$LP_WHY"' _ "$DIR" "$T/stubs.sh" "$1" "$2"
}

echo "T1: every row of the case table"
n=0
while IFS=$'\t' read -r lane proj key val hub place box why; do
  case "$lane" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  scratch_rm "$T/settings"; mkdir -p "$T/settings"
  printf '%b' "$val" > "$T/settings/$key"
  [ "$hub" = - ] || printf '%s' "$hub" > "$T/settings/lane_placement.$lane.hub_only"
  [ "$proj" = - ] && proj=""
  [ "$box" = - ] && box=""
  got=$(decide "$lane" "$proj")
  gp=${got%%|*}; rest=${got#*|}; gb=${rest%%|*}; gw=${rest#*|}
  label="row $n: $key='$val' (lane $lane, project ${proj:-none})"
  if [ "$gp" = "$place" ] && [ "$gb" = "$box" ] && [[ "$gw" == *"$why"* ]]; then
    ok "$label -> $place${box:+ $box}"
  else
    bad "$label -> got place=$gp box=$gb why=$gw; want place=$place box=$box why~$why"
  fi
done < "$CASES"
[ "$n" -ge 20 ] && ok "T1 read $n rows" || bad "T1 read only $n rows"
[ ! -s "$T/jobs-calls.txt" ] && ok "T1 no jobs request" || bad "T1 jobs calls: $(cat "$T/jobs-calls.txt")"

echo "T2: lp_box_parse"
pb() { bash -c '. "$1/bin/lib/lane-placement.sh" || exit 9; lp_box_parse "$2"' _ "$DIR" "$1"; }
[ "$(pb 'box:box-project-6-os-1')" = box-project-6-os-1 ] && ok "T2 plain name" || bad "T2 plain: $(pb 'box:box-project-6-os-1')"
[ "$(pb $'\tBOX:box.MKOS_1 \n')" = box.mkos_1 ] && ok "T2 trim + lowercase, . and _ kept" || bad "T2 trim: $(pb $'\tBOX:box.MKOS_1 \n')"
for v in 'box:' 'box:a/b' 'box:_a' 'fly' 'box' "box:$(printf 'b%.0s' {1..65})"; do
  out=$(pb "$v" 2>&1); rc=$?
  if [ "$rc" = 1 ] && [ -z "$out" ]; then ok "T2 '${v:0:20}' is not a box value (rc 1)"; else bad "T2 '$v' rc $rc out '$out'"; fi
done

echo "T3: LP_BOX is reset on every read"
scratch_rm "$T/settings"; mkdir -p "$T/settings"
printf 'box:project-6-os' > "$T/settings/lane_placement.merge-conductor.p1"
printf 'fly' > "$T/settings/lane_placement.merge-conductor.p2"
got=$(bash -c '. "$1/bin/lib/lane-placement.sh"; . "$2"
  lp_decide merge-conductor p1; a="$LP_PLACE:$LP_BOX"; lp_decide merge-conductor p2; printf "%s %s:%s" "$a" "$LP_PLACE" "${LP_BOX:-}"' _ "$DIR" "$T/stubs.sh")
[ "$got" = "box:project-6-os fly:" ] && ok "T3 box then fly: LP_BOX empty after the fly read" || bad "T3 got '$got'"

echo
echo "lane-placement-box.bh-7636: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
