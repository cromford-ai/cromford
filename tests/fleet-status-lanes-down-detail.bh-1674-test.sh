#!/bin/bash
# tests/fleet-status-lanes-down-detail.bh-1674-test.sh — BH-1689 (BH-1674.3):
# the fleet-status snapshot's `lanes_down_detail`, built from the lane-down
# records bin/lib/lane-down.sh writes to state/lane-down/<box>-<lane>. Driven
# through the real bin/fleet-status-push.sh with curl and beat.sh replaced by
# capture stubs, so nothing leaves the machine.
#   F1  records → {box:{lane:{since,age_s,last_probe,last_error,standing}}},
#       last_error capped at 120 chars, standing a boolean, lanes_down untouched
#   F2a no records → {}
#   F2b a payload over 60000 bytes sheds lanes_down_detail
#   F3  a lib that defines nothing still builds the field (inline fallback)
#   F4  malformed, foreign and in-flight .tmp. records are skipped, never zeroed
# Run from anywhere: tests/fleet-status-lanes-down-detail.bh-1674-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state/lane-down" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
cp "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 hub
EOF

run() { rm -f "$T/PUSH.json" "$T/BEAT.json"; PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh"; }
q()   { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }

TODAY=$(date -u +%Y%m%d)
NOW=$(date +%s)
LD="$T/state/lane-down"
rec() {  # rec <file> <box> <lane> <since> <last_probe> <last_error> <standing_at>
  printf 'box=%s\nlane=%s\naddr=\nsince=%s\nlast_probe=%s\nlast_error=%s\nstanding_at=%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$LD/$1"
}
LONGERR="credit limit reached \"quoted\"	tab $(printf 'x%.0s' $(seq 1 200))"
valid() {
  rec hub-grok   hub  grok  $((NOW - 180000)) $((NOW - 60)) "$LONGERR" $((NOW - 100))
  rec project-4-codex project-4 codex $((NOW - 600))    $((NOW - 30)) "401 unauthorized" ""
}

# ── F1: two records, today's flag for one of them ────────────────────────────
valid
touch "$T/flags/lanedown-hub-grok-$TODAY"
run
[ -s "$T/PUSH.json" ] && ok || bad "F1: nothing was pushed"
AGE=$(q '.lanes_down_detail.hub.grok.age_s')
[[ $AGE =~ ^[0-9]+$ ]] && [ "$AGE" -ge 180000 ] && ok || bad "F1: hub.grok age_s must be >= 180000, got '$AGE'"
[ "$(q '.lanes_down_detail.hub.grok.since')" = "$((NOW - 180000))" ] && ok || bad "F1: since must be the record's since, got $(q '.lanes_down_detail.hub.grok.since')"
[ "$(q '.lanes_down_detail.hub.grok.last_probe')" = "$((NOW - 60))" ] && ok || bad "F1: last_probe must be the record's, got $(q '.lanes_down_detail.hub.grok.last_probe')"
[ "$(q '.lanes_down_detail.hub.grok.last_error | contains("credit limit")')" = true ] && ok || bad "F1: last_error must carry the record's error"
[ "$(q '.lanes_down_detail.hub.grok.last_error | length')" = 120 ] && ok || bad "F1: last_error must be capped at 120, got $(q '.lanes_down_detail.hub.grok.last_error | length')"
[ "$(q '.lanes_down_detail.hub.grok.standing')" = true ] && ok || bad "F1: standing_at set must be standing:true"
[ "$(q '.lanes_down_detail.project-4.codex.standing')" = false ] && ok || bad "F1: empty standing_at must be standing:false"
[ "$(q '[.lanes_down_detail.hub.grok.standing, .lanes_down_detail.project-4.codex.standing] | map(type) | unique | tojson')" = '["boolean"]' ] \
  && ok || bad "F1: standing must be a boolean"
[ "$(q '.lanes_down_detail.hub.grok | keys | tojson')" = '["age_s","last_error","last_probe","since","standing"]' ] \
  && ok || bad "F1: keys must be exactly the five, got $(q '.lanes_down_detail.hub.grok | keys | tojson')"
[ "$(q '.lanes_down_detail.project-4.codex.last_error')" = "401 unauthorized" ] && ok || bad "F1: project-4.codex must be present with its error"
[ "$(q '.lanes_down | tojson')" = '{"hub":["grok"]}' ] && ok || bad "F1: lanes_down must stay today's flags only, got $(q '.lanes_down | tojson')"
[ -s "$T/BEAT.json" ] && [ "$(jq -c 'del(.kind,.rkey)' "$T/BEAT.json")" = "$(jq -c . "$T/PUSH.json")" ] \
  && ok || bad "F1: the beat must carry the same snapshot as the push"
[ "$(grep -c flock "$DIR/bin/fleet-status-push.sh")" = 0 ] && ok || bad "F1: the reader must take no lock"

# ── F2a: no records ──────────────────────────────────────────────────────────
rm -f "$LD"/*
run
[ "$(q '.lanes_down_detail | tojson')" = '{}' ] && ok || bad "F2a: no records must be {}, got $(q '.lanes_down_detail | tojson')"
scratch_rm "$LD"
run
[ "$(q '.lanes_down_detail | tojson')" = '{}' ] && ok || bad "F2a: a missing state/lane-down must be {}, got $(q '.lanes_down_detail | tojson')"
mkdir -p "$LD"

# ── F2b: the 60000-byte backstop sheds it ────────────────────────────────────
valid
jq -n --arg k "$(printf 'p%.0s' $(seq 1 61000))" '{($k):{count:3}}' > "$T/state/stale-owed.json"
run
[ "$(q '.snapshot_trimmed')" = size ] && ok || bad "F2b: an oversized payload must be trimmed, got $(q 'keys|tojson')"
[ "$(q 'has("lanes_down_detail")')" = false ] && ok || bad "F2b: lanes_down_detail must be shed"
scratch_rm "$T/state/stale-owed.json"; rm -f "$T/state/stale-owed-reported.json"

# ── F3: fail-open when the lib in $H defines nothing ─────────────────────────
mkdir -p "$T/bin/lib"
printf '# stub: defines no functions\n' > "$T/bin/lib/lane-down.sh"
run
[ "$(q '.lanes_down_detail.hub.grok.last_probe')" = "$((NOW - 60))" ] && ok || bad "F3: an empty lib must fall back to the inline reader, got $(q '.lanes_down_detail | tojson')"
# Unreadable only when not root (root reads a mode-000 file); either way the
# stub defines nothing and the field must still build.
chmod 000 "$T/bin/lib/lane-down.sh"
run
jq -e . "$T/PUSH.json" >/dev/null 2>&1 && ok || bad "F3: an unreadable lib must still push valid JSON"
[ "$(q '.lanes_down_detail.project-4.codex.standing')" = false ] && ok || bad "F3: an unreadable lib must still build the field"
scratch_rm "$T/bin/lib"

# ── F4: malformed, foreign and in-flight records are skipped ─────────────────
valid
rec hub-bad          hub   bad   abc                $((NOW - 60)) "bad since" ""
rec hub-future       hub   future $((NOW + 9999))   $((NOW - 60)) "future" ""
rec hub-noprobe      hub   noprobe $((NOW - 500))   ""            "no probe" ""
rec hub-grok.tmp.999 hub   grok  $((NOW - 5))       $((NOW - 5))  "tmp write" ""
rec project-4-codex       other codex $((NOW - 600))     $((NOW - 30)) "foreign" ""
mkdir "$LD/hub-dir"
run
jq -e . "$T/PUSH.json" >/dev/null 2>&1 && ok || bad "F4: the payload must stay valid JSON"
[ "$(q '.lanes_down_detail.hub | keys | tojson')" = '["grok"]' ] && ok || bad "F4: only hub.grok may survive, got $(q '.lanes_down_detail | tojson')"
[ "$(q '.lanes_down_detail.hub.grok.last_error | contains("credit limit")')" = true ] && ok || bad "F4: the .tmp. file must not stand in for hub.grok"
[ "$(q 'has("lanes_down_detail") and (.lanes_down_detail | has("project-4") | not) and (.lanes_down_detail | has("other") | not)')" = true ] \
  && ok || bad "F4: a record whose box does not match its name must be skipped"
[ "$(q '[.lanes_down_detail[][] | select(.age_s == 0 or .since == 0 or .last_probe == 0)] | length')" = 0 ] \
  && ok || bad "F4: nothing may be zero-filled"

echo "fleet-status-lanes-down-detail: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
