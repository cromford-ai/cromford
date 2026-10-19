#!/bin/bash
# tests/lane-move-watchdog-responder.bh-7426-test.sh — BH-7426 (part of #7397):
# watchdog-responder stays on the hub. It writes the fleet-wide
# state/responder/handled.json cooldown (not in the lane-run write-back),
# launches /root/harness/bin/run-build.sh by hub path, and reads the board
# token from env/<p>.env. So the build seeds the
# lane_placement.watchdog-responder.hub_only row and adds no lane-move module
# (docs/notes/2026-10-19-BH-7426-watchdog-responder-hub-only.md).
#
#   W1  the composed worker/jobs/schema.sql seeds the hub_only row exactly once:
#       INSERT OR IGNORE INTO settings, actor seed, value 1-120 characters that
#       names handled.json
#   W2  no schema statement seeds lane_placement.watchdog-responder[.<p>] = fly,
#       and bin/lib/lane-move/watchdog-responder.sh does not exist. A later
#       move removes the seed row and this case in the same PR.
#   W3  the real bin/lib/lane-placement.sh lp_decide, over a stub settings
#       table that holds the SEEDED value: fly + hub_only -> hub; fly and no
#       hub_only -> fly (near miss); project fly + hub_only -> hub;
#       hub + hub_only -> hub
#   W4  lp_hub_only_reason prints the seeded value; rc 1 with no row
#
# Run from anywhere: tests/lane-move-watchdog-responder.bh-7426-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

SCHEMA="$DIR/worker/jobs/schema.sql"
KEY=lane_placement.watchdog-responder.hub_only

# Every `;`-terminated statement of schema.sql, one per line, comments cut.
stmts() {
  sed 's/--.*$//' "$SCHEMA" | tr '\n' ' ' | awk 'BEGIN{ RS=";" } { gsub(/^ +| +$/, ""); gsub(/ +/, " "); if ($0 != "") print }'
}
# Every settings tuple ('key','value','note','actor',...), one per line.
tuples() {
  stmts | grep '^INSERT OR IGNORE INTO settings ' | sed 's/^[^(]*([^)]*) VALUES //' \
    | sed "s/''/\x01/g" | grep -o "('[^']*','[^']*','[^']*','[^']*','[^']*')" | sed "s/\x01/''/g"
}

# ── W1 the seed row ──────────────────────────────────────────────────────────
HIT=$(stmts | grep -F "'$KEY'")
eq "W1 one schema statement names $KEY" "$(printf '%s' "$HIT" | grep -c .)" "1"
case "$HIT" in
  "INSERT OR IGNORE INTO settings "*) ok ;;
  *) bad "W1 the $KEY statement is not INSERT OR IGNORE INTO settings: ${HIT:0:80}" ;;
esac
ROW=$(tuples | grep -F "('$KEY',")
VAL=$(printf '%s' "$ROW" | awk -F "','" '{ print $2 }')
ACTOR=$(printf '%s' "$ROW" | awk -F "','" '{ print $4 }')
eq "W1 actor" "$ACTOR" "seed"
[ -n "$VAL" ] && [ "${#VAL}" -le 120 ] && ok || bad "W1 value must be 1-120 characters, got ${#VAL}: '$VAL'"
case "$VAL" in *handled.json*) ok ;; *) bad "W1 value must name handled.json: '$VAL'" ;; esac

# ── W2 no fly seed, no module ────────────────────────────────────────────────
FLY=$(tuples | grep -E "^\('lane_placement\.watchdog-responder(\.[^.']+)?','[[:space:]]*[Ff][Ll][Yy][[:space:]]*'")
eq "W2 no fly seed for watchdog-responder" "$FLY" ""
[ ! -e "$DIR/bin/lib/lane-move/watchdog-responder.sh" ] && ok \
  || bad "W2 bin/lib/lane-move/watchdog-responder.sh exists while the hub_only row is seeded"

# ── W3 / W4 the real lane-placement lib over a stub settings table ──────────
H="$T/h"; mkdir -p "$H/bin"
: > "$T/settings.tsv"
cat > "$H/bin/jobs-client.sh" <<EOF
_setting_key_ok() { [[ "\$1" =~ ^[A-Za-z0-9._-]+\$ ]]; }
_jobs_req() { return 1; }
setting_get() {
  local v
  v=\$(awk -F '\t' -v k="\$1" '\$1 == k { print \$2; f = 1 } END { exit f ? 0 : 1 }' "$T/settings.tsv") || return 2
  printf '%s' "\$v"
}
EOF
rows() { printf '%s' "$1" > "$T/settings.tsv"; }
# decide <project> — prints "LP_PLACE|LP_WHY" from a cold shell.
decide() {
  env HARNESS="$H" bash -c '. "$1/bin/lib/lane-placement.sh" || exit 9; lp_decide watchdog-responder "$2"; printf "%s|%s" "$LP_PLACE" "$LP_WHY"' \
    _ "$DIR" "${1:-}" 2>/dev/null
}
reason() {
  env HARNESS="$H" bash -c '. "$1/bin/lib/lane-placement.sh" || exit 9; lp_hub_only_reason watchdog-responder' _ "$DIR" 2>/dev/null
}
SEEDED=${VAL:-<no seed>}

rows "lane_placement.watchdog-responder	fly
$KEY	$SEEDED
"
eq "W3 lane fly + hub_only -> hub" "$(decide)" "hub|hub_only: $SEEDED"

rows "lane_placement.watchdog-responder	fly
"
eq "W3 lane fly, no hub_only -> fly (near miss)" "$(decide)" "fly|lane_placement.watchdog-responder=fly"

rows "lane_placement.watchdog-responder.demo	fly
$KEY	$SEEDED
"
eq "W3 project fly + hub_only -> hub" "$(decide demo)" "hub|hub_only: $SEEDED"

rows "lane_placement.watchdog-responder	hub
$KEY	$SEEDED
"
eq "W3 lane hub + hub_only -> hub" "$(decide | cut -d'|' -f1)" "hub"

rows "$KEY	$SEEDED
"
OUT=$(reason); RC=$?
eq "W4 lp_hub_only_reason rc with the row" "$RC" "0"
eq "W4 lp_hub_only_reason prints the seeded value" "$OUT" "$SEEDED"
rows ""
OUT=$(reason); RC=$?
eq "W4 lp_hub_only_reason rc with no row" "$RC" "1"
eq "W4 lp_hub_only_reason prints nothing with no row" "$OUT" ""

echo "lane-move-watchdog-responder.bh-7426: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
