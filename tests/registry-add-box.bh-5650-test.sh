#!/bin/bash
# tests/registry-add-box.bh-5650-test.sh — BH-5650 (the ticket's
# registry-add-box-test): bin/registry.sh add-box, drain-box and show, through
# the REAL harness-jobs worker (tests/lib/registry-fixture-curl.bh-5650.mjs over
# SQLite, seeded from this tree's files), and bin/render-cron.sh in db mode.
#
#   A1 add-box box-x --like project-6: x renders the same cron/lanes
#      lines as project-6 (names swapped), 25 or more of them (28 today), with no
#      cron/boxes/x.d (the _template.d fragments)
#   A2 one lane_box audit row per project-6 lane, one box row, one version
#   A3 fleet-conf.sh --tailnet-ip-of-box box-x answers the new IP
#   A4 a second identical add-box is changed=0 and writes no audit row
#   D1 drain-box box-x: x renders no cron/lanes line, rc 0
#   D2 project-6's render is unchanged by that drain
#   D3 drain of box-project-6-1 (it runs projects): rc 1, the projects
#      are named, no audit row
#   D4 a lane with every membership deleted renders on no box (known_lanes),
#      where the file registry still puts it on project-6
#   S1 show prints the version and an x line with its IP
#   T1 render-cron.sh --all writes no _template.cron; rendered_boxes skips it
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
CLI="$DIR/bin/registry.sh"
RC="$DIR/bin/render-cron.sh"
FC="$DIR/bin/fleet-conf.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }
[ -d "$DIR/cron/boxes/project-6.d" ] && [ ! -e "$DIR/cron/boxes/x.d" ] && ok || bad "precondition: project-6.d exists and x.d does not"

audit_n() { rfx_q 'SELECT COUNT(*) AS n FROM registry_audit' | jq '.[0].n'; }
render() { rfx_db "$RC" --root "$DIR" "$1" 2>"$T/render-$1.err"; }
# lane_lines <render> <box-id> — the lines from cron/lanes/ fragments: no
# comment, no PATH=, no line of the _template.d fragments (env lines such as
# DBUS_SESSION_BUS_ADDRESS= every box gets), nothing inside a fleet-managed
# project block, no line of the box's own cron/boxes/<id>.d; the box's names
# swapped for BOX/WATCHER.
lane_lines() {
  local own="$T/own-$2"
  cat "$DIR/cron/boxes/$2.d/"*.cron "$DIR/cron/boxes/_template.d/"*.cron 2>/dev/null \
    | grep -v '^[[:space:]]*\(#\|@fleet\|$\)' > "$own"
  awk '/^# BEGIN fleet-managed/ {skip=1; next} /^# END fleet-managed/ {skip=0; next} !skip' "$1" \
    | grep -v '^[[:space:]]*\(#\|$\)' | grep -v '^PATH=' | grep -vxFf "$own" \
    | sed "s/box-$2\\b/WATCHER/g; s/\\b$2\\b/BOX/g" | LC_ALL=C sort
}

# ---- A1 ----------------------------------------------------------------------
A0=$(audit_n); V0=$(rfx_q 'SELECT version FROM registry_meta' | jq '.[0].version')
OUT=$(rfx_db "$CLI" add-box box-x --ip 192.0.2.13 --like project-6 2>"$T/a1.err"); R=$?
[ "$R" = 0 ] && ok || bad "A1 add-box rc $R: $(cat "$T/a1.err")"
[[ "$OUT" =~ ^registry:\ add-box\ changed=[0-9]+\ version=$((V0+1))$ ]] && ok || bad "A1 output '$OUT'"
render x > "$T/x.cron"; R=$?
[ "$R" = 0 ] && ok || bad "A1 render x rc $R: $(cat "$T/render-x.err")"
render project-6 > "$T/mk.cron" || bad "A1 render project-6 failed: $(cat "$T/render-project-6.err")"
lane_lines "$T/x.cron" x > "$T/x.lanes"
lane_lines "$T/mk.cron" project-6 > "$T/mk.lanes"
N=$(wc -l < "$T/mk.lanes")
[ "$N" -ge 25 ] && ok || bad "A1 vacuous: project-6 renders only $N lane lines"
cmp -s "$T/x.lanes" "$T/mk.lanes" && ok || bad "A1 x and project-6 lane lines differ: $(diff "$T/mk.lanes" "$T/x.lanes" | head -6)"
grep -qx '\*/5 \* \* \* \* /root/harness/bin/watchdog-ping.sh box-x' "$T/x.cron" && ok \
  || bad "A1 x pings the watchdog as box-x (no project names it; the registry does)"
[ ! -e "$DIR/cron/boxes/x.d" ] && ok || bad "A1 a cron/boxes/x.d appeared"
head -n "$(grep -vc '^@fleet' "$DIR/cron/boxes/_template.d/000-path.cron")" "$T/x.cron" | cmp -s - <(grep -v '^@fleet' "$DIR/cron/boxes/_template.d/000-path.cron") && ok \
  || bad "A1 x does not start with the _template.d PATH fragment"

# ---- A2 ----------------------------------------------------------------------
NL=$(rfx_q "SELECT COUNT(*) AS n FROM registry_lane_boxes WHERE box_id='project-6'" | jq '.[0].n')
rfx_q "SELECT entity, key, version FROM registry_audit WHERE version=$((V0+1)) ORDER BY id" > "$T/a2.json"
[ "$(jq '[.[] | select(.entity == "lane_box")] | length' "$T/a2.json")" = "$NL" ] && [ "$NL" -ge 10 ] && ok \
  || bad "A2 lane_box audit rows $(jq '[.[] | select(.entity == "lane_box")] | length' "$T/a2.json"), project-6 has $NL lanes"
[ "$(jq '[.[] | select(.entity == "lane_box") | .key | split("/")[0]] | (length == (unique | length))' "$T/a2.json")" = true ] && ok \
  || bad "A2 a lane has more than one audit row"
[ "$(jq '[.[] | select(.entity == "box")] | length' "$T/a2.json")" = 1 ] && ok || bad "A2 box audit rows != 1"
[ "$(rfx_q "SELECT COUNT(DISTINCT version) AS n FROM registry_audit WHERE id > $A0" | jq '.[0].n')" = 1 ] && ok \
  || bad "A2 the add-box audit rows carry more than one version"

# ---- A3 ----------------------------------------------------------------------
OUT=$(REGISTRY_CACHE_TTL_S=0 rfx_db "$FC" --tailnet-ip-of-box box-x 2>/dev/null)
[ "$OUT" = 192.0.2.13 ] && ok || bad "A3 --tailnet-ip-of-box box-x = '$OUT'"

# ---- A4 ----------------------------------------------------------------------
A1N=$(audit_n)
OUT=$(rfx_db "$CLI" add-box box-x --ip 192.0.2.13 --like project-6 2>&1); R=$?
[ "$R" = 0 ] && [[ "$OUT" == *"changed=0 version=$((V0+1))"* ]] && ok || bad "A4 retry rc $R '$OUT'"
[ "$(audit_n)" = "$A1N" ] && ok || bad "A4 the retry wrote audit rows"

# ---- S1 ----------------------------------------------------------------------
OUT=$(rfx_db "$CLI" show 2>&1); R=$?
[ "$R" = 0 ] && ok || bad "S1 show rc $R"
head -1 <<<"$OUT" | grep -q "^registry: version=$((V0+1)) " && ok || bad "S1 no version line: $(head -1 <<<"$OUT")"
grep -qE '^box-x x 192\.0\.2\.13 projects=- lanes=[1-9]' <<<"$OUT" && ok || bad "S1 no x line: $OUT"

# ---- D1-D3 -------------------------------------------------------------------
OUT=$(rfx_db "$CLI" drain-box box-x 2>&1); R=$?
[ "$R" = 0 ] && [[ "$OUT" == *"changed=$NL "* ]] && ok || bad "D1 drain rc $R '$OUT'"
render x > "$T/x2.cron"; R=$?
[ "$R" = 0 ] && ok || bad "D1 render of the drained x rc $R: $(cat "$T/render-x.err")"
[ -z "$(lane_lines "$T/x2.cron" x)" ] && ok || bad "D1 drained x still renders lane lines: $(lane_lines "$T/x2.cron" x | head -3)"
grep -q '^PATH=' "$T/x2.cron" && ok || bad "D1 drained x lost its _template.d fragments"
render project-6 > "$T/mk2.cron"
cmp -s "$T/mk.cron" "$T/mk2.cron" && ok || bad "D2 project-6's render changed: $(diff "$T/mk.cron" "$T/mk2.cron" | head -4)"
A2N=$(audit_n)
ERR=$(rfx_db "$CLI" drain-box box-project-6-1 2>&1 >/dev/null); R=$?
[ "$R" = 1 ] && ok || bad "D3 drain of a box with projects rc $R"
[[ "$ERR" == *409* && "$ERR" == *project-6* && "$ERR" == *project-7* ]] && ok || bad "D3 the refusal does not name 409 and the projects: $ERR"
[ "$(audit_n)" = "$A2N" ] && ok || bad "D3 the refused drain wrote audit rows"

# ---- D4 a lane drained to zero boxes renders nowhere (known_lanes) -----------
# Pick a project-6 lane whose fragment renders a plain line, delete EVERY
# membership of it, and the line must be gone: with no known_lanes marker the
# overlay would fall back to the file .boxes and keep it.
. "$DIR/bin/lib/lanes-registry.sh" || exit 1
LJ=$(lanes_json_path "$DIR")
LANE=""; LINE=""
for L in $(rfx_q "SELECT lane FROM registry_lane_boxes WHERE box_id='project-6' ORDER BY lane" | jq -r '.[].lane'); do
  for F in "$DIR"/cron/lanes/[0-9][0-9][0-9]-"$L".cron; do
    [ -f "$F" ] || continue
    C=$(grep -v '^#' "$F" | grep -v '@' | grep -m1 '[^[:space:]]') || continue
    grep -qxF "$C" "$T/mk.cron" || continue
    LANE="$L"; LINE="$C"; break 2
  done
done
if [ -z "$LANE" ]; then
  bad "D4 found no project-6 lane with a plain fragment line"
else
  jq -e --arg l "$LANE" '.lanes[] | select(.id == $l) | .boxes | index("project-6") != null' "$LJ" >/dev/null && ok \
    || bad "D4 vacuous: the file registry does not put $LANE on project-6"
  printf 'authorization: Bearer fixture-secret\nx-registry-admin-token: fixture-admin-token\n' > "$T/d4.headers"
  for B in $(rfx_q "SELECT box_id FROM registry_lane_boxes WHERE lane='$LANE'" | jq -r '.[].box_id'); do
    "$T/bin/curl" -sS -X DELETE -H "@$T/d4.headers" "https://jobs.test/api/registry/lane-boxes/$LANE/$B" >/dev/null
  done
  [ "$(rfx_q "SELECT COUNT(*) AS n FROM registry_lane_boxes WHERE lane='$LANE'" | jq '.[0].n')" = 0 ] && ok || bad "D4 $LANE still has rows"
  REGISTRY_CACHE_TTL_S=0 rfx_db "$FC" --projects >/dev/null 2>&1
  render project-6 > "$T/mk4.cron"
  grep -qxF "$LINE" "$T/mk4.cron" && bad "D4 lane $LANE has no registry row left but project-6 still renders: $LINE" || ok
fi

# ---- T1 ----------------------------------------------------------------------
mkdir -p "$T/all"
env HARNESS="$T/hf" "$RC" --root "$DIR" --out-dir "$T/all" >/dev/null 2>"$T/all.err" || bad "T1 render --all failed: $(head -3 "$T/all.err")"
[ -s "$T/all/project-6.cron" ] && ok || bad "T1 render --all wrote no project-6.cron"
[ ! -e "$T/all/_template.cron" ] && ok || bad "T1 render --all wrote a _template.cron"
env HARNESS="$T/hf" "$RC" --root "$DIR" _template >/dev/null 2>&1; R=$?
[ "$R" = 2 ] && ok || bad "T1 render-cron.sh _template rc $R, want 2 (not a box)"
. "$DIR/tests/lib/rendered.sh" || exit 1
grep -q '^_' <<<"$(rendered_boxes)" && bad "T1 rendered_boxes lists a _ directory" || ok

echo "registry-add-box: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
