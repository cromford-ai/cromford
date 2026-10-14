#!/bin/bash
# tests/untriaged-digest.bh-2756-test.sh — bin/untriaged-digest.sh, the daily
# "N open tickets with no triage verdict older than Xh" line per project
# (BH-2756, ask 4 of BH-2751), and the in-app board read it shares with
# bin/untriaged-sweep.sh (bin/lib/untriaged-board-read.sh).
#
# The SHIPPED lane runs against a scratch $HARNESS with the REAL lane-alert.sh,
# alert-state, lane-gate, gh-rest, board-creds, fleet-conf and untriaged libs
# underneath. Only the edges are stubs: `gh` replays queued HTTP fixtures,
# `curl` answers the in-app boards from per-host files (a missing file is
# curl's --fail exit 22), `beat.sh` records, and `claude` records any call
# (there must be none).
#
# The scratch registry names two in-app projects that are NOT in the real
# fleet (alpha-app, beta-app). The lane can only find them through fleet.conf,
# which is the point: it carries no project table of its own (the #2852 red).
#
# Run from anywhere: bash tests/untriaged-digest.bh-2756-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 34 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

DIGEST="$DIR/bin/untriaged-digest.sh"
BOARDREAD="$DIR/bin/lib/untriaged-board-read.sh"
H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/flags" "$H/logs" "$H/state" "$H/catalog" "$T/shim" "$T/fx" "$T/cx" "$T/tmp"
cp -r "$DIR/bin/lib" "$H/bin/lib"
cp "$DIGEST" "$DIR/bin/untriaged-sweep.sh" "$DIR/bin/lane-alert.sh" "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board-prefix offset
cromford example-org/cromford - - 0
alpha-app example-org/alpha-app https://alpha.example /api/board 1
beta-app example-org/beta-app https://beta.example /api/feature-board 2
EOF
: > "$H/env/global.env"
ENV_A='ALPHA_APP_BASE=https://alpha.example\nALPHA_INTERNAL_API_TOKEN=tok-a\n'
printf "$ENV_A" > "$H/env/alpha-app.env"
printf 'BETA_API_BASE=https://beta.example\nBETA_INTERNAL_API_TOKEN=tok-b\n' > "$H/env/beta-app.env"
# the sweep still loads its four env files by name and reads all four under
# set -u (out of scope here); only project-1 is answered by the curl stub
printf 'PROJECT_1_API_BASE=https://m.example\nproject-1_INTERNAL_API_TOKEN=tok-m\n' > "$H/env/project-1.env"
printf 'PROJECT_2_APP_BASE=https://t.example\nTA_INTERNAL_API_TOKEN=tok-t\n' > "$H/env/project-2.env"
printf 'PROJECT_3_APP_BASE=https://o.example\nproject-3_INTERNAL_API_TOKEN=tok-o\n' > "$H/env/project-3.env"
printf 'PROJECT_4_API_BASE=https://c.example\nproject-4_INTERNAL_API_TOKEN=tok-c\n' > "$H/env/project-4.env"

cat > "$T/shim/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/gh-calls.txt"
[ -f "$STUB_DIR/gh-exit" ] && exit "$(cat "$STUB_DIR/gh-exit")"
f=$(find "$STUB_DIR/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
cat "$f"; rm -f "$f"; exit 0
STUB
cat > "$T/shim/curl" <<'STUB'
#!/bin/bash
url=""; for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
printf '%s\n' "$url" >> "$STUB_DIR/curl-calls.txt"
host=$(sed -E 's#^https?://([^/.]+).*#\1#' <<<"$url")
case "$url" in */tickets) f="$STUB_DIR/cx/$host-tickets" ;; */boards) f="$STUB_DIR/cx/$host-boards" ;; *) exit 22 ;; esac
[ -f "$f" ] || exit 22
cat "$f"
STUB
cat > "$T/shim/claude" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/claude-all.txt"
STUB
cat > "$H/bin/beat.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/beat.txt"
STUB
chmod +x "$T/shim/"* "$H/bin/"*.sh

ago() { # 7h | 45min -> that long before now, ISO-8601 UTC
  local s; case "$1" in *min) s=$(( ${1%min} * 60 )) ;; *h) s=$(( ${1%h} * 3600 )) ;; esac
  date -u -d "@$(( $(date +%s) - s ))" +%Y-%m-%dT%H:%M:%SZ
}
FXN=0
fx() { FXN=$((FXN+1)); printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2" > "$(printf '%s/fx/%02d' "$T" "$FXN")"; }
issue() { # number age comments
  jq -nc --argjson n "$1" --arg c "$(ago "$2")" --argjson k "$3" \
    '{number:$n, title:"t\($n)", body:"b", comments:$k, created_at:$c, user:{login:"x"}, labels:[]}'
}
ticket() { # id number status verdict ts [reporter]
  jq -nc --arg i "$1" --argjson n "$2" --arg s "$3" --arg v "$4" --arg t "$5" --arg r "${6:-client}" \
    '{id:$i, number:$n, title:"title \($n)", status:$s, triageVerdict:(if $v == "" then null else $v end),
      createdAt:$t, reporter:{userId:$r}}'
}
boards() { for h in alpha beta m; do printf '[{"id":"b-%s"}]' "$h" > "$T/cx/$h-boards"; printf '[]' > "$T/cx/$h-tickets"; done; }
reset() { # fresh alert state, logs and stubs; the fixtures are set per section
  rm -rf "$T"/fx/* "$H/state/alerts" "$H/state/lane-gate" "$T/gh-exit" "$H/flags"/*
  rm -f "$H/state/untriaged-alerted.txt"
  : > "$H/logs/ALERTS.log"; : > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"; : > "$T/beat.txt"; 
  : > "$H/env/global.env"; printf "$ENV_A" > "$H/env/alpha-app.env"
  FXN=0; boards
}
run() { env PATH="$T/shim:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$H/fleet.conf" \
          STUB_DIR="$T" TMPDIR="$T/tmp" GH_ETAG=0 bash "$H/bin/${1:-untriaged-digest.sh}" >/dev/null 2>&1; }
lines() { grep -cF -- "$1" "$H/logs/ALERTS.log"; }

# ══ L. the lib, sourced on its own ═════════════════════════════════════════
lib() { # base -> rows on stdout, rc in $T/lib-rc
  env PATH="$T/shim:$PATH" STUB_DIR="$T" TMPDIR="$T/tmp" bash -c \
    '. "$1"; ut_inapp_untriaged alpha-app "$2" tok /api/board 3600; echo $? > "$3"' _ "$BOARDREAD" "$1" "$T/lib-rc"
}
reset
printf '%s' "[$(ticket l1 401 todo "" "$(ago 3h)"),$(ticket l2 402 todo build "$(ago 3h)"),$(ticket l3 403 in_progress "" "$(ago 3h)"),$(ticket l4 404 todo "" "$(ago 3h)" system),$(ticket l5 405 todo "" 2026-07-01T00:00:00Z)]" > "$T/cx/alpha-tickets"
OUT=$(lib https://alpha.example)
[ "$(cat "$T/lib-rc")" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] \
  && [ "$(printf '%s' "$OUT" | awk -F'\t' '{print NF" "$1" "$2" "$4}')" = "4 l1 401 title 401" ] && ok \
  || bad "L1: want one 4-field row for l1, got rc=$(cat "$T/lib-rc") [$OUT]"
rm -f "$T/cx/alpha-tickets"; OUT=$(lib https://alpha.example)
[ "$(cat "$T/lib-rc")" = 1 ] && [ -z "$OUT" ] && ok || bad "L2: failed tickets fetch gave rc=$(cat "$T/lib-rc") [$OUT]"
printf '{}' > "$T/cx/alpha-boards"; printf '[]' > "$T/cx/alpha-tickets"; OUT=$(lib https://alpha.example)
[ "$(cat "$T/lib-rc")" = 1 ] && [ -z "$OUT" ] && ok || bad "L2: null board id gave rc=$(cat "$T/lib-rc") [$OUT]"
boards; OUT=$(lib https://alpha.example)
[ "$(cat "$T/lib-rc")" = 0 ] && [ -z "$OUT" ] && ok || bad "L3: empty board gave rc=$(cat "$T/lib-rc") [$OUT]"

GH_ABC="[$(issue 11 7h 0),$(issue 12 9h 0),$(issue 13 8h 0),$(issue 14 2h 0),$(issue 15 10h 2)]"
T_OLD=$(ago 8h); T_MS="$(ago 7h | sed 's/Z$/.123Z/')"
A_ABC="[$(ticket a1 101 todo "" "$T_OLD"),$(ticket a2 102 todo "" "$T_MS"),$(ticket a3 103 todo build "$(ago 9h)"),$(ticket a4 104 in_progress "" "$(ago 9h)"),$(ticket a5 105 todo "" "$(ago 9h)" system)]"

# ══ D1 + D2. one run: GH counts 3 (not the young one, not the commented one);
#    alpha-app counts 2 (not verdict-set, in_progress or system-filed) ════════
reset; fx 200 "$GH_ABC"; printf '%s' "$A_ABC" > "$T/cx/alpha-tickets"
run; RC=$?
[ "$RC" = 0 ] && ok || bad "D1: lane exited $RC"
[ "$(lines '[cromford] 3 open tickets with no triage verdict older than 6h (oldest #12, 9h)')" = 1 ] && ok \
  || bad "D1: want one exact cromford line, ALERTS.log: $(cat "$H/logs/ALERTS.log")"
[ "$(lines '[cromford]')" = 1 ] && ok || bad "D1: cromford line count $(lines '[cromford]')"
# --id untriaged-digest:cromford:<day>, as alert-state sanitises it (: -> _)
[ -f "$H/state/alerts/untriaged-digest_cromford_$(date -u +%Y%m%d).json" ] && ok \
  || bad "D1: no alert-state row keyed untriaged-digest:cromford:<today>: $(ls "$H/state/alerts" 2>/dev/null)"
[ "$(lines '[alpha-app] 2 open tickets with no triage verdict older than 6h (oldest #101, 8h)')" = 1 ] && ok \
  || bad "D2: want one exact alpha-app line, ALERTS.log: $(cat "$H/logs/ALERTS.log")"
[ "$(lines '[alpha-app]')" = 1 ] && ok || bad "D2: alpha-app line count $(lines '[alpha-app]')"
# ══ D2b. beta-app is in fleet.conf only, and it was read (and its prefix used) ══
grep -qx 'https://beta.example/api/feature-board/boards/b-beta/tickets' "$T/curl-calls.txt" && ok \
  || bad "D2b: the registry-only project beta-app was not read: $(cat "$T/curl-calls.txt")"
[ "$(lines '[beta-app]')" = 0 ] && ok || bad "D2b: beta-app has an empty board and still got a line"
grep -q "untriaged-digest after=6h counted=3 sent=2 failed=0" "$H/logs/untriaged-digest.log" && ok \
  || bad "D1: summary log line wrong: $(cat "$H/logs/untriaged-digest.log" 2>/dev/null)"

# ══ D3. the same fixtures again, same UTC day: no new line ═════════════════
BEFORE=$(wc -l < "$H/logs/ALERTS.log")
fx 200 "$GH_ABC"
run
AFTER=$(wc -l < "$H/logs/ALERTS.log")
[ "$BEFORE" = "$AFTER" ] && [ "$BEFORE" -ge 2 ] && ok || bad "D3: second run moved ALERTS.log from $BEFORE to $AFTER lines"

# ══ D12. a read that hit the 500-issue cap prints N+, not a firm count ═════
reset
OLD=$(ago 8h)
for pg in 0 1 2 3 4; do
  fx 200 "$(jq -nc --argjson f "$((pg*100+1000))" --arg c "$OLD" \
    '[range(100) | {number: (. + $f), title: "t", body: "b", comments: 0, created_at: $c, user: {login: "x"}, labels: []}]')"
done
run
grep -qF '[cromford] 500+ open tickets with no triage verdict older than 6h (oldest #' "$H/logs/ALERTS.log" && ok \
  || bad "D12: a capped read did not print 500+: $(grep cromford "$H/logs/ALERTS.log")"

# ══ D4 / D5. GH read declined (gh exit 75, then a 403): could not count, never 0 ══
reset; echo 75 > "$T/gh-exit"
run
grep -qE '\[cromford\] could not count untriaged tickets \(.+\)' "$H/logs/ALERTS.log" && ok \
  || bad "D4 exit 75: no could-not-count line: $(cat "$H/logs/ALERTS.log")"
grep -q ' 0 open tickets' "$H/logs/ALERTS.log" && bad "D4 exit 75: a failed read was reported as 0" || ok
reset; fx 403 '{"message":"Resource not accessible by integration"}'
run
grep -qE '\[cromford\] could not count untriaged tickets \(.+\)' "$H/logs/ALERTS.log" && ok \
  || bad "D5 403: no could-not-count line: $(cat "$H/logs/ALERTS.log")"
grep -q ' 0 open tickets' "$H/logs/ALERTS.log" && bad "D5 403: a failed read was reported as 0" || ok
# an issue the count cannot read (a created_at that is not a date) fails the count
reset; fx 200 "[$(issue 31 8h 0),$(issue 32 9h 0 | jq -c '.created_at = "not-a-date"')]"
run
[ "$(lines '[cromford] could not count untriaged tickets (count failed)')" = 1 ] && ok \
  || bad "D5 bad date: a count that could not be computed was not reported: $(cat "$H/logs/ALERTS.log")"

# ══ D6. in-app read fails: tickets endpoint down, error body, token missing ══
reset; fx 200 "[]"; rm -f "$T/cx/alpha-tickets"
run
[ "$(lines '[alpha-app] could not count untriaged tickets (board read failed)')" = 1 ] && ok \
  || bad "D6: no in-app could-not-count line: $(cat "$H/logs/ALERTS.log")"
grep -q ' 0 open tickets' "$H/logs/ALERTS.log" && bad "D6: a failed read was reported as 0" || ok
reset; fx 200 "[]"; printf '{"error":"boom"}' > "$T/cx/alpha-tickets"
run
[ "$(lines '[alpha-app] could not count untriaged tickets (board read failed)')" = 1 ] && ok \
  || bad "D6: an error body was not a failed read: $(cat "$H/logs/ALERTS.log")"
reset; fx 200 "[]"; printf 'ALPHA_APP_BASE=https://alpha.example\n' > "$H/env/alpha-app.env"
run
[ "$(lines '[alpha-app] could not count untriaged tickets (no board token)')" = 1 ] && ok \
  || bad "D6: a missing token was not a could-not-count line: $(cat "$H/logs/ALERTS.log")"
grep -q 'alpha.example' "$T/curl-calls.txt" && bad "D6: curled alpha-app with no token" || ok

# ══ D7. nothing qualifies anywhere: no line, rc 0 ═════════════════════════
reset; fx 200 "[$(issue 21 2h 0),$(issue 22 10h 1)]"
printf '%s' "[$(ticket b1 201 todo "" "$(ago 2h)"),$(ticket b2 202 todo "" "$(ago 9h)" system)]" > "$T/cx/alpha-tickets"
run; RC=$?
[ "$RC" = 0 ] && ok || bad "D7: lane exited $RC"
[ -s "$H/logs/ALERTS.log" ] && bad "D7: nothing qualifies but ALERTS.log got: $(cat "$H/logs/ALERTS.log")" || ok

# ══ D8. flags/lane-off-untriaged-digest: nothing read, nothing sent ═══════
reset; fx 200 "$GH_ABC"; printf '%s' "$A_ABC" > "$T/cx/alpha-tickets"
: > "$H/flags/lane-off-untriaged-digest"
run; RC=$?
[ "$RC" = 0 ] && ok || bad "D8: gated lane exited $RC"
[ -s "$H/logs/ALERTS.log" ] && bad "D8: lane-off still wrote: $(cat "$H/logs/ALERTS.log")" || ok
[ -s "$T/gh-calls.txt" ] && bad "D8: lane-off still called gh" || ok
[ -s "$T/curl-calls.txt" ] && bad "D8: lane-off still curled: $(cat "$T/curl-calls.txt")" || ok

# ══ D10. the knob: a bad value is refused; 2h moves the cut ═══════════════
reset; fx 200 "$GH_ABC"; printf 'UNTRIAGED_ALERT_AFTER_H=abc\n' > "$H/env/global.env"
run
[ "$(lines "UNTRIAGED_ALERT_AFTER_H='abc' is not a whole number of hours >= 1")" = 1 ] && ok \
  || bad "D10: knob abc was not refused: $(cat "$H/logs/ALERTS.log")"
[ -s "$T/gh-calls.txt" ] && bad "D10: a refused knob still read boards" || ok
reset; printf 'UNTRIAGED_ALERT_AFTER_H=0\n' > "$H/env/global.env"
run
grep -q "UNTRIAGED_ALERT_AFTER_H='0' is not a whole number" "$H/logs/ALERTS.log" && ok \
  || bad "D10: knob 0 was not refused: $(cat "$H/logs/ALERTS.log")"
reset; fx 200 "[$(issue 41 3h 0),$(issue 42 1h 0)]"; printf 'UNTRIAGED_ALERT_AFTER_H=2\n' > "$H/env/global.env"
run
[ "$(lines '[cromford] 1 open tickets with no triage verdict older than 2h (oldest #41, 3h)')" = 1 ] && ok \
  || bad "D10: knob 2h not honoured: $(cat "$H/logs/ALERTS.log")"

# ══ S1 / S2. untriaged-sweep through the shared lib: legacy text, 1h, dedupe ══
reset
printf '%s' "[$(ticket f1 301 todo "" "$(ago 2h)"),$(ticket f2 302 todo "" "$(ago 45min)")]" > "$T/cx/m-tickets"
run untriaged-sweep.sh; RC=$?
[ "$RC" = 0 ] && ok || bad "S1: sweep exited $RC"
[ "$(grep -c '^[0-9-]* [0-9:]*Z \[project-1\] ticket #301 untriaged >1h (app triage may be silently failing): title 301$' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "S1: legacy sweep line missing: $(cat "$H/logs/ALERTS.log")"
grep -q '#302' "$H/logs/ALERTS.log" && bad "S1: a 45-minute-old ticket was alerted" || ok
[ "$(wc -l < "$T/beat.txt")" = 1 ] && [ "$(jq -r .akey "$T/beat.txt")" = "untriaged:project-1:f1" ] && ok \
  || bad "S1: want one beat with akey untriaged:project-1:f1, got: $(cat "$T/beat.txt")"
run untriaged-sweep.sh
[ "$(wc -l < "$H/logs/ALERTS.log")" = 1 ] && [ "$(wc -l < "$T/beat.txt")" = 1 ] && ok \
  || bad "S2: second sweep was not deduped"

# ══ D9. no LLM, ever ════════════════════════════════════════════════════
[ -s "$T/claude-all.txt" ] && bad "D9: claude was invoked: $(cat "$T/claude-all.txt")" || ok
grep -qiE '(^|[^a-z_-])claude([^a-z_.-]|$)|anthropic' "$DIGEST" "$BOARDREAD" \
  && bad "D9: the lane names an LLM" || ok

echo "untriaged-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
