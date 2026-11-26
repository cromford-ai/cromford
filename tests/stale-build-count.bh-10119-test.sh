#!/bin/bash
# tests/stale-build-count.bh-10119-test.sh — BH-10119 (item 5 of #10060):
# bin/stale-build-reaper.sh publishes its dead count after each complete tick,
# as harness-jobs ledgers(kind=building_stale, key=fleet), so the kanban's
# `building_stale` uses the detector's own filters (stage, window, live set).
#
# The curl stub plays the console (stale feed, close POST) and the jobs worker
# (/api/queue, /api/machines, /api/jobs, PUT /api/ledger). It records every
# ledger PUT body. 0 network calls. Every case uses its own ticket keys.
# Run from anywhere: tests/stale-build-count.bh-10119-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$T" || exit 1
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/builds" "$T/fakebin" "$T/fx"
for S in bin/stale-build-reaper.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$S" "$T" >/dev/null || { echo "FAIL: scratch_install_closure $S"; exit 1; }
done
printf 'alpha-os Org/alpha https://a.example /api/board 2 local\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
unset FLY_MACHINES_ROWS STALE_REAPER_ACT STALE_REAPER_MINUTES STALE_REAPER_MAX STALE_REAPER_PAGE STALE_REAPER_HTTP_TIMEOUT_S STALE_REAPER_COUNT_TTL_MIN
printf 'CONSOLE_URL=http://console.invalid\nHARNESS_SECRET=fixture-secret-example\n' > "$T/env/global.env"
printf '#!/bin/bash\ntrue\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The stub. fx/QUEUE_DOWN: the queue read fails (curl rc 7). fx/CLOSE_REFUSE_<bkey>:
# the console refuses that close. fx/LEDGER_500: the ledger PUT answers 500.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
X=\$T_FX; MODE=""; URL=""; METHOD=GET; BODY=""; P=0
for a; do
  [ "\$P" = 1 ] && { BODY="\$a"; P=0; }
  [ "\$P" = 2 ] && { METHOD="\$a"; P=0; }
  case "\$a" in -d|--data-binary) P=1;; -X) P=2;; esac
  case "\$a" in
    *api/builds/stale*) MODE=feed;;
    *api/builds/close*) MODE=close;;
    *api/queue*) MODE=queue; URL="\$a";;
    *api/machines*) MODE=machines;;
    *api/ledger*) MODE=ledger; URL="\$a";;
    *api/jobs*) MODE=jobs;;
  esac
done
case "\$MODE" in
  feed) cat \$X/FEED.json; exit 0 ;;
  close)
    printf '%s\n' "\$BODY" >> \$X/POSTS.jsonl
    B=\$(printf '%s' "\$BODY" | jq -r '.closed[0]')
    [ -f "\$X/CLOSE_REFUSE_\$B" ] && { echo '{"ok":false,"error":"nope"}'; exit 0; }
    echo '{"ok":true,"requested":1,"updated":1}'; exit 0 ;;
  queue)
    [ -f \$X/QUEUE_DOWN ] && exit 7
    ST=\$(printf '%s' "\$URL" | sed -n 's/.*status=\([a-z]*\).*/\1/p')
    cat "\$X/QUEUE_\$ST.json" 2>/dev/null || echo '{"queue":[]}'
    printf '\n200\n'; exit 0 ;;
  machines) echo '{"machines":[]}'; printf '\n200\n'; exit 0 ;;
  ledger)
    printf '%s %s\n' "\$METHOD" "\$BODY" >> \$X/LEDGER.log
    [ -f \$X/LEDGER_500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    printf '%s\n200\n' "\$(printf '%s' "\$BODY" | jq -c '{ledger: .}')"; exit 0 ;;
  jobs)
    [ "\$METHOD" = PATCH ] && { printf '{"ok":true}\n200\n'; exit 0; }
    cat \$X/JOBS.json 2>/dev/null || echo '{"jobs":[]}'
    printf '\n200\n'; exit 0 ;;
esac
exit 7
EOF
chmod +x "$T/fakebin/curl"

NOW=1763251200   # pinned clock (2025-11-16T00:00:00Z), passed as --now
ISO() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
ago() { ISO "$((NOW - $1 * 60))"; }   # ago <minutes> -> ISO
row() { # row <bkey> <key> <stage> <updated_at>
  jq -nc --arg b "$1" --arg k "$2" --arg s "$3" --arg u "$4" \
    '{bkey:$b,project:"alpha-os",ticket_key:$k,stage:$s,updated_at:$u,pr_url:""}'; }
feed() { if [ $# -eq 0 ]; then echo '{"ok":true,"count":0,"builds":[]}'; else printf '%s\n' "$@" | jq -sc '{ok:true,count:length,builds:.}'; fi > "$T/fx/FEED.json"; }
reset_fx() { rm -f "$T/fx/"*; rm -rf "$T/builds/"*; }
run() { # run [args] — env passes through; prints the true rc
  : > "$T/fx/POSTS.jsonl"; : > "$T/fx/LEDGER.log"; : > "$T/logs/stale-build-reaper.log"
  HARNESS="$T" T_FX="$T/fx" PATH="$T/fakebin:$PATH" HARNESS_SECRET=fixture-secret-example FLY_MACHINES_ROWS=off \
    JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
    bash "$DIR/bin/stale-build-reaper.sh" --now "$NOW" "$@" >/dev/null 2>&1; echo $?; }
nputs()  { grep -c '^PUT ' "$T/fx/LEDGER.log" 2>/dev/null || true; }
put()    { grep '^PUT ' "$T/fx/LEDGER.log" | tail -1 | cut -d' ' -f2-; }   # the last PUT body
pf()     { put | jq -r "$1"; }                                            # a field of it
df()     { put | jq -r '.detail' | jq -r "$1"; }                          # a field of its detail
logged() { cat "$T/logs/stale-build-reaper.log" 2>/dev/null; }

# ---------- 1. observe: only the detector's dead rows are counted ----------
reset_fx
feed "$(row bD1 CT-1 executing "$(ago 61)")" "$(row bD2 CT-2 planning "$(ago 90)")" \
     "$(row bQ1 CT-3 executing "$(ago 61)")" "$(row bF1 CT-4 executing "$(ago 61)")" \
     "$(row bJ1 CT-5 executing "$(ago 61)")" "$(row bM1 CT-6 pr_merged "$(ago 300)")" \
     "$(row bY1 CT-7 executing "$(ago 59)")" "$(row '' CT-8 executing "$(ago 61)")"
echo '{"queue":[{"project":"alpha-os","ticket_key":"CT-3","status":"claimed","target":"fly"}]}' > "$T/fx/QUEUE_claimed.json"
mkdir -p "$T/builds/alpha-os-CT-4-202511160000"
echo '{"jobs":[{"id":"j5","project":"alpha-os","kind":"build","stage":"execute","box":"hub","ticket_id":"CT-5","activity_age_s":120}]}' > "$T/fx/JOBS.json"
RC=$(run)
[ "$RC" = 0 ] && [ "$(nputs)" = 1 ] && ok || bad "1 rc 0 and one ledger PUT (rc=$RC puts=$(nputs)): $(cat "$T/fx/LEDGER.log")"
[ "$(pf .kind)" = building_stale ] && [ "$(pf .key)" = fleet ] && [ "$(pf .status)" = 2 ] && ok || bad "1 PUT kind=building_stale key=fleet status=2: $(put)"
[ "$(df .stale)" = 2 ] && [ "$(df .held)" = 3 ] && [ "$(df .candidates)" = 5 ] && [ "$(df .window_min)" = 60 ] && [ "$(df .mode)" = observe ] \
  && ok || bad "1 detail stale=2 held=3 candidates=5 window_min=60 mode=observe: $(pf .detail)"
[ "$(df .at)" = "$(ISO "$NOW")" ] && [ "$(df .valid_until)" = "$(ISO $((NOW + 30 * 60)))" ] && ok || bad "1 default TTL 30: valid_until = now + 30 min: $(pf .detail)"
# The round-trip: the reader's fixture has exactly the keys the reaper sends.
FIX_KEYS=$(jq -r '.detail | fromjson | keys | join(",")' "$DIR/console-ui/tests/fixtures/building-stale-ledger.bh-10119.json")
[ "$(put | jq -r '.detail | fromjson | keys | join(",")')" = "$FIX_KEYS" ] && ok || bad "1 detail keys match the reader fixture ($FIX_KEYS): $(pf .detail)"
logged | grep -q "count published stale=2 held=3 valid_until=$(ISO $((NOW + 30 * 60)))" && ok || bad "1 log line count published: $(logged)"
[ "$(grep -c . "$T/fx/POSTS.jsonl")" = 0 ] && ok || bad "1 observe makes 0 close POSTs"

# ---------- 2. the TTL knob sets valid_until ----------
reset_fx
feed "$(row bT1 CT-11 executing "$(ago 61)")"
RC=$(STALE_REAPER_COUNT_TTL_MIN=45 run)
[ "$RC" = 0 ] && [ "$(df .at)" = "$(ISO "$NOW")" ] && [ "$(df .valid_until)" = "$(ISO $((NOW + 45 * 60)))" ] && [ "$(pf .status)" = 1 ] \
  && ok || bad "2 TTL 45: at = now, valid_until = now + 45 min (rc=$RC): $(put)"

# ---------- 3. act: survivors minus reaped; a refused row still counts ----------
reset_fx
feed "$(row bA1 CT-21 executing "$(ago 61)")" "$(row bA2 CT-22 executing "$(ago 61)")" "$(row bA3 CT-23 planning "$(ago 61)")"
: > "$T/fx/CLOSE_REFUSE_bA2"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(grep -c . "$T/fx/POSTS.jsonl")" = 3 ] && ok || bad "3 act: 3 close POSTs (rc=$RC)"
[ "$(pf .status)" = 1 ] && [ "$(df .stale)" = 1 ] && [ "$(df .mode)" = act ] && [ "$(df .candidates)" = 3 ] && ok || bad "3 act: status=1 (3 survivors, 2 reaped, 1 refused): $(put)"

# ---------- 4. empty feed: a true zero is published ----------
reset_fx
feed
RC=$(run)
[ "$RC" = 0 ] && [ "$(nputs)" = 1 ] && [ "$(pf .status)" = 0 ] && [ "$(df .candidates)" = 0 ] && ok || bad "4 empty feed: one PUT status=0 (rc=$RC): $(put)"

# ---------- 5. a refused tick publishes nothing ----------
reset_fx
feed "$(row bR1 CT-41 executing "$(ago 61)")"
: > "$T/fx/QUEUE_DOWN"
RC=$(run)
[ "$RC" = 3 ] && [ "$(nputs)" = 0 ] && ok || bad "5 queue down: rc 3 and 0 ledger PUTs (rc=$RC puts=$(nputs))"
grep -q 'count published' <<<"$(logged)" && bad "5 no count line on a refused tick: $(logged)" || ok

# ---------- 6. TTL 0 turns the publish off ----------
reset_fx
feed "$(row bO1 CT-51 executing "$(ago 61)")"
RC=$(STALE_REAPER_COUNT_TTL_MIN=0 run)
[ "$RC" = 0 ] && [ "$(nputs)" = 0 ] && ok || bad "6 TTL 0: 0 PUTs (rc=$RC puts=$(nputs))"
logged | grep -q 'count publish off (STALE_REAPER_COUNT_TTL_MIN=0)' && ok || bad "6 log line count publish off: $(logged)"
RC=$(STALE_REAPER_COUNT_TTL_MIN=abc run)
[ "$RC" = 0 ] && [ "$(df .valid_until)" = "$(ISO $((NOW + 30 * 60)))" ] && ok || bad "6 TTL abc falls back to 30: $(put)"

# ---------- 7. a failed PUT changes no rc and no close ----------
reset_fx
feed "$(row bP1 CT-61 executing "$(ago 61)")"
: > "$T/fx/LEDGER_500"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(nputs)" = 1 ] && ok || bad "7 PUT 500: rc 0, one PUT tried (rc=$RC puts=$(nputs))"
logged | grep -q 'count publish failed (jobs worker), the row expires at its valid_until' && ok || bad "7 log line count publish failed: $(logged)"
grep -q 'count published' <<<"$(logged)" && bad "7 no published line after a failed PUT" || ok
[ "$(jq -r '.closed[]' "$T/fx/POSTS.jsonl")" = bP1 ] && logged | grep -q 'REAPED bP1' && ok || bad "7 the close POST and REAPED line as before: $(logged)"
logged | grep -q 'mode=act candidates=1 held=0 skipped=0 reaped=1 deferred=0 refused=0' && ok || bad "7 summary line unchanged: $(logged)"

# ---------- 8. the reader: the node suite, driven ----------
# console-ui/tests/building-stale-overlay.bh-10119.test.js drives the reader
# and onRequest. It runs here when node and the console-ui deps are installed.
OVERLAY="$DIR/console-ui/functions/_lib/stale-overlay.js"
[ -f "$OVERLAY" ] && ok || bad "8 the reader $OVERLAY exists"
if command -v node >/dev/null 2>&1 && [ -d "$DIR/console-ui/node_modules" ]; then
  NOUT=$(cd "$DIR/console-ui" && node --test tests/building-stale-overlay.bh-10119.test.js 2>&1); NRC=$?
  [ "$NRC" = 0 ] && ok || bad "8 node suite rc=$NRC: $(grep -E '^not ok|^# fail' <<<"$NOUT")"
else
  echo "stale-build-count.bh-10119: node suite SKIPPED — node or console-ui/node_modules missing"
fi

echo "stale-build-count.bh-10119: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
