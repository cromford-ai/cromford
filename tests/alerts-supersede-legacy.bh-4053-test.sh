#!/bin/bash
# tests/alerts-supersede-legacy.bh-4053-test.sh — rows opened under the old
# alert:auto-<row_key> scheme are not orphaned once the condition declares its
# own id (BH-4053). bin/alerts-supersede.py resolves an open alert:auto-* row
# when an open explicit alert:<id> row has the same condition shape
# (bin/alert_family.py shape(): the PR list folded to one #N), and never
# resolves the explicit row.
#
# The real script runs under --dry against a local http.server that serves the
# fixture as GET /api/alerts/open, so the decisions it prints are the ones it
# would post.
#
#   U1 two legacy rows + one explicit row of one shape -> both legacy resolved
#   U2 a legacy row of another shape is left alone by this pass
#   U3 no explicit row -> nothing resolved by this pass
#   U4 shape() folds the PR list, stamp, still-firing suffix; family() does not
#   U5 alert_family missing -> rc 0, one stderr line, other passes still run
#   U6 no --dry but HUB_MOVE_NOWRITE=1 (the hub-move no-write tick, BH-7715)
#      -> the same decisions print and the server sees no POST
#
# Run from anywhere: tests/alerts-supersede-legacy.bh-4053-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

mkdir -p "$T/bin" "$T/www/api/alerts"
cp "$DIR/bin/alerts-supersede.py" "$DIR/bin/alert_family.py" "$T/bin/"
printf '#!/bin/bash\necho ts project-3\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
( cd "$T/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>"$T/srv.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 50); do
  python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:$PORT/')" 2>/dev/null && break
  sleep 0.1
done

NOWISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOURAGO=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
TWOHAGO=$(date -u -d '-2 hour' +%Y-%m-%dT%H:%M:%SZ)
SP='[pipeline-health] ts: harness PR(s) %s open >12h awaiting merge — built work aging into the next watchdog owed-tickets alert'
# shellcheck disable=SC2059
LA=$(printf "$SP" '#50'); LB=$(printf "$SP" '#50,#51'); LC=$(printf "$SP" '#50,#51,#52')
row() { # row <id> <akey> <line> <createdAt>
  jq -nc --arg i "$1" --arg k "$2" --arg l "$3" --arg c "$4" '{id:$i,akey:$k,line:$l,createdAt:$c}'
}
serve() { jq -s '{alerts: .}' > "$T/www/api/alerts/open"; }
run() { # run [bin-dir] — prints stdout, stderr to $T/err.txt, rc to $T/rc.txt
  ( export CONSOLE_URL="http://127.0.0.1:$PORT" HARNESS_SECRET=x
    python3 "${1:-$T/bin}/alerts-supersede.py" --dry ) 2>"$T/err.txt"
  echo $? > "$T/rc.txt"
}
LEG='legacy auto key, BH-4053'

echo "--- U1: legacy rows of the explicit row's shape resolve; the explicit row does not"
{ row A alert:auto-aaaa-1111 "$LA" "$TWOHAGO"
  row B alert:auto-bbbb-2222 "$LB" "$HOURAGO"
  row C alert:ph-stalepr_ts "$LC" "$TWOHAGO"; } | serve
OUT=$(run)
grep -qxF "resolve A: superseded by alert:ph-stalepr_ts ($LEG)" <<<"$OUT" && ok || bad "U1: A not resolved as legacy: $OUT $(cat "$T/err.txt")"
grep -qxF "resolve B: superseded by alert:ph-stalepr_ts ($LEG)" <<<"$OUT" && ok || bad "U1: B not resolved as legacy: $OUT"
! grep -q '^resolve C:' <<<"$OUT" && ok || bad "U1: the explicit row was resolved: $OUT"
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "U1: rc $(cat "$T/rc.txt")"

echo "--- U2: a legacy row of another shape is not this pass's"
LO='[pipeline-health] project-3: harness PR(s) #70 open >12h awaiting merge — built work aging into the next watchdog owed-tickets alert'
LX='[pipeline-health] ts: queue row TK-9 stranded 3h'
{ row C alert:ph-stalepr_ts "$LC" "$NOWISO"
  row D alert:auto-dddd-4444 "$LO" "$HOURAGO"
  row E alert:auto-eeee-5555 "$LX" "$HOURAGO"; } | serve
OUT=$(run)
DE=$(grep -E '^resolve (D|E):' <<<"$OUT" || true)
! grep -qF "$LEG" <<<"$DE" && ok || bad "U2: another shape resolved by the legacy pass: $OUT"

echo "--- U3: without an explicit row the legacy pass resolves nothing"
{ row A alert:auto-aaaa-1111 "$LA" "$HOURAGO"
  row B alert:auto-bbbb-2222 "$LB" "$NOWISO"; } | serve
OUT=$(run)
! grep -qF "$LEG" <<<"$OUT" && ok || bad "U3: legacy pass acted with no explicit row: $OUT"

echo "--- U4: shape folds the PR list, the stamp and the still-firing suffix; family does not"
SA=$(python3 "$DIR/bin/alert_family.py" shape "$LA")
SB=$(python3 "$DIR/bin/alert_family.py" shape "$(printf "$SP" '#50, #51')")
SS=$(python3 "$DIR/bin/alert_family.py" shape "2026-10-02 10:00:00Z $LB (still firing, n=3)")
[ -n "$SA" ] && [ "$SA" = "$SB" ] && [ "$SA" = "$SS" ] && ok || bad "U4: shapes differ: '$SA' '$SB' '$SS'"
[ "$(python3 "$DIR/bin/alert_family.py" family "$LA")" != "$(python3 "$DIR/bin/alert_family.py" family "$LB")" ] \
  && ok || bad "U4: family() of #50 and #50,#51 now agree — family must stay untouched"
[ "$(python3 "$DIR/bin/alert_family.py" shape "$LO")" != "$SA" ] && ok || bad "U4: two projects share a shape"

echo "--- U5: no alert_family beside the script: the pass is skipped, the groom is not"
mkdir -p "$T/bin5"; cp "$T/bin/alerts-supersede.py" "$T/bin/fleet-conf.sh" "$T/bin5/"
{ row A alert:auto-aaaa-1111 "$LA RESOLVED" "$HOURAGO"
  row C alert:ph-stalepr_ts "$LC" "$NOWISO"; } | serve
OUT=$(run "$T/bin5")
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "U5: rc $(cat "$T/rc.txt"): $(cat "$T/err.txt")"
[ "$(grep -c . "$T/err.txt")" = 1 ] && ok || bad "U5: want one stderr line: $(cat "$T/err.txt")"
grep -qx 'resolve A: informational / already declared settled' <<<"$OUT" && ok || bad "U5: the other passes did not run: $OUT"

echo "--- U6: HUB_MOVE_NOWRITE=1 is --dry: decisions print, nothing is posted"
{ row A alert:auto-aaaa-1111 "$LA" "$TWOHAGO"
  row C alert:ph-stalepr_ts "$LC" "$TWOHAGO"; } | serve
: > "$T/srv.log"
OUT=$( export CONSOLE_URL="http://127.0.0.1:$PORT" HARNESS_SECRET=x HUB_MOVE_NOWRITE=1
  python3 "$T/bin/alerts-supersede.py" 2>"$T/err.txt" )
grep -qxF "resolve A: superseded by alert:ph-stalepr_ts ($LEG)" <<<"$OUT" && ok || bad "U6: A not decided: $OUT $(cat "$T/err.txt")"
grep -q 'GET /api/alerts/open' "$T/srv.log" && ok || bad "U6: the server log saw no read: $(cat "$T/srv.log")"
! grep -q '"POST ' "$T/srv.log" && ok || bad "U6: posted under HUB_MOVE_NOWRITE=1: $(grep POST "$T/srv.log")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
