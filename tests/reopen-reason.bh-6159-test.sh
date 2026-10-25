#!/bin/bash
# tests/reopen-reason.bh-6159-test.sh — BH-6159: why a ticket reopened.
#
# The reopen lane (bin/reopen-metrics.sh) reads the comments posted around the
# status change and saves them as the ledger row reopen_reason/"<p> <key>"
# (bin/lib/reopen-reason.sh). The build plan prompt and the triage prompt carry
# the saved reason, and the weekly lookback summary counts reopens per project.
#
#   R1  the window: move_at +- 24 h edges, and the D-1..D+1 fallback edges
#   R2  the comment filter: four drop cases, three keep cases
#   R3  size cut and the round trip: rr_save PUT body -> rr_plan_line, rr_triage_note
#   R4  the real reopen lane on an app board: one saved row, no board write
#   R5  the real reopen lane on a GitHub-Issues project
#   R6  a second run reads and writes nothing
#   R7  an unreadable thread: 3 tries, one ALERTS line, then left
#   R8  the plan block from bin/lib/rb/plan.sh, verbatim
#   R9  the plan prompt carries ${REOPEN_REASON_LINE:-} once, before the kind hint
#   R10 the triage note, and the run-triage.sh lines that append it
#   R11 the weekly line, and the real bin/lookback.sh summary
#   R12 REOPEN_REASON=0: no read, no write, CSV unchanged, no plan text
#
# No network: curl and gh are stubs on PATH. No LLM.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/reopen-reason.bh-6159-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/reopen-reason.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1"; else echo 0; fi; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "reopen-reason.bh-6159-test: SKIPPED — jq missing"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB missing"; echo "reopen-reason.bh-6159-test: 0 passed, 1 failed"; exit 1; }

# A fixed clock for the pure sections. 2026-10-10T12:00:00Z.
FIXED_NOW=1791633600
LH="$T/libh"; mkdir -p "$LH/state"

# ============================================================================
# R1 the window
# ============================================================================
M="2026-10-08T12:00:00Z"
cat > "$T/r1.json" <<EOF
{"activity":[{"type":"status_change","toValue":"review","createdAt":"2026-10-07T09:00:00Z"},
             {"type":"status_change","toValue":"paused","createdAt":"2026-10-08T12:00:00.000Z"},
             {"type":"comment","createdAt":"2026-10-08T13:00:00Z"}],
 "comments":[
  {"createdAt":"2026-10-07T11:59:59Z","author":{"name":"c1"},"body":"before edge minus 1s"},
  {"createdAt":"2026-10-07T12:00:00Z","author":{"name":"c2"},"body":"lower edge"},
  {"createdAt":"2026-10-08T12:00:00Z","author":{"name":"c3"},"body":"at the move"},
  {"createdAt":"2026-10-09T12:00:00Z","author":{"name":"c4"},"body":"upper edge"},
  {"createdAt":"2026-10-09T12:00:01Z","author":{"name":"c5"},"body":"upper edge plus 1s"}]}
EOF
W=$(HARNESS="$LH" bash -c '. "$1"; rr_window "$2" paused 20261008' _ "$LIB" "$T/r1.json")
eq "R1 window from the activity" "$W" "$M"$'\t'"2026-10-07T12:00:00Z"$'\t'"2026-10-09T12:00:00Z"
IFS=$'\t' read -r _ WF WT <<<"$W"
GOT=$(HARNESS="$LH" bash -c '. "$1"; rr_pick "$2" "$3" "$4" app' _ "$LIB" "$T/r1.json" "$WF" "$WT" | jq -r '[.[].author] | join(",")')
eq "R1 kept set at the 24 h edges" "$GOT" "c2,c3,c4"
cat > "$T/r1b.json" <<'EOF'
{"ticket":{"comments":[
  {"createdAt":"2026-10-06T23:59:59Z","authorName":"d1","body":"D-2 last second"},
  {"createdAt":"2026-10-07T00:00:00Z","authorName":"d2","body":"D-1 first second"},
  {"createdAt":"2026-10-09T23:59:59Z","authorName":"d3","body":"D+1 last second"},
  {"createdAt":"2026-10-10T00:00:00Z","authorName":"d4","body":"D+2 first second"}]}}
EOF
W=$(HARNESS="$LH" bash -c '. "$1"; rr_window "$2" paused 20261008' _ "$LIB" "$T/r1b.json")
eq "R1 no activity: the day fallback" "$W" "-"$'\t'"2026-10-07T00:00:00Z"$'\t'"2026-10-09T23:59:59Z"
IFS=$'\t' read -r _ WF WT <<<"$W"
GOT=$(HARNESS="$LH" bash -c '. "$1"; rr_pick "$2" "$3" "$4" app' _ "$LIB" "$T/r1b.json" "$WF" "$WT" | jq -r '[.[].author] | join(",")')
eq "R1 kept set at the day edges (project-4 .ticket root)" "$GOT" "d2,d3"
# an activity to another status does not set the window
W=$(HARNESS="$LH" bash -c '. "$1"; rr_window "$2" in_progress 20261008' _ "$LIB" "$T/r1.json")
eq "R1 a move to another status is not this move" "${W%%$'\t'*}" "-"
# REOPEN_REASON_WINDOW_H moves the edges
W=$(HARNESS="$LH" REOPEN_REASON_WINDOW_H=1 bash -c '. "$1"; rr_window "$2" paused 20261008' _ "$LIB" "$T/r1.json")
eq "R1 the window knob" "$W" "$M"$'\t'"2026-10-08T11:00:00Z"$'\t'"2026-10-08T13:00:00Z"

# ============================================================================
# R2 the comment filter
# ============================================================================
cat > "$T/r2.json" <<'EOF'
[
 {"created_at":"2026-10-08T10:00:00Z","user":{"login":"ci-bot","type":"Bot"},"body":"bot says hi"},
 {"createdAt":"2026-10-08T10:01:00Z","author":{"name":"Harness","isSystem":true},"body":"system note"},
 {"createdAt":"2026-10-08T10:02:00Z","author":{"name":"Dana"},"body":"<p> </p>"},
 {"createdAt":"2026-10-08T10:03:00Z","author":{"name":"Triage"},"body":"[AI Triage] questions for you"},
 {"createdAt":"2026-10-08T10:04:00Z","authorType":"system","body":"typed system"},
 {"createdAt":"2026-10-08T10:05:00Z","author":{"name":"Ops","role":"system"},"body":"role system"},
 {"createdAt":"2026-10-08T10:06:00Z","author":{"name":"Dana"},"body":"The discount toggle is still there"},
 {"createdAt":"2026-10-08T10:07:00Z","body":"no author at all"},
 {"created_at":"2026-10-08T10:08:00Z","user":{"login":"client-a","type":"User"},"body":"<div>Fix   <b>this</b>\n please</div>"}
]
EOF
P2=$(HARNESS="$LH" bash -c '. "$1"; rr_pick "$2" 2026-10-08T00:00:00Z 2026-10-08T23:59:59Z gh' _ "$LIB" "$T/r2.json")
eq "R2 three kept" "$(jq 'length' <<<"$P2")" 3
eq "R2 kept texts" "$(jq -r '[.[].text] | join("|")' <<<"$P2")" "The discount toggle is still there|no author at all|Fix this please"
eq "R2 kept authors" "$(jq -r '[.[].author] | join("|")' <<<"$P2")" "Dana|unknown|client-a"
hasnt "R2 bot dropped" "$P2" "bot says hi"
hasnt "R2 system dropped" "$P2" "system note"
hasnt "R2 [AI Triage] dropped" "$P2" "AI Triage"
hasnt "R2 typed system dropped" "$P2" "typed system"
# an author given as a plain string is kept, not an error
P2S=$(printf '[{"createdAt":"2026-10-08T10:00:00Z","author":"Lee","body":"string author"}]' > "$T/r2s.json"
      HARNESS="$LH" bash -c '. "$1"; rr_pick "$2" 2026-10-08T00:00:00Z 2026-10-08T23:59:59Z app' _ "$LIB" "$T/r2s.json")
eq "R2 a string author is kept" "$(jq -r '.[0].author + ":" + .[0].text' <<<"$P2S")" "Lee:string author"

# ============================================================================
# shared stubs: curl records "METHOD URL BODY" and answers from $T/rules
# (first matching substring wins, else 200 {}); gh answers from $T/gh.rules.
# ============================================================================
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
TD=__T__
m=GET; url=""; body=""; w=0; f=0
while [ $# -gt 0 ]; do case "$1" in
  -X) m="$2"; shift 2 ;;
  --data-binary|-d|--data) body="$2"; shift 2 ;;
  -w) w=1; shift 2 ;;
  -m|--connect-timeout|-H|-o) shift 2 ;;
  -sf|-fs|-f|-sSf|-fsS) f=1; shift ;;
  http*) url="$1"; shift ;;
  *) shift ;;
esac; done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
printf '%s\t%s\t%s\n' "$m" "$url" "$body" >> "$TD/curl.log"
line="$m $url $body"; code=200; resp='{}'
if [ -r "$TD/rules" ]; then
  while IFS=$'\t' read -r pat c r; do
    [ -n "$pat" ] || continue
    case "$line" in *"$pat"*) code="$c"; resp="$r"; break ;; esac
  done < "$TD/rules"
fi
if [ "$w" = 1 ]; then printf '%s\n%s' "$resp" "$code"; exit 0; fi
[ "$f" = 1 ] && [ "$code" -ge 400 ] && exit 22
printf '%s' "$resp"
EOF
cat > "$T/stub/gh" <<'EOF'
#!/bin/bash
TD=__T__
printf '%s\n' "$*" >> "$TD/gh.log"
if [ -r "$TD/gh.rules" ]; then
  while IFS=$'\t' read -r pat file; do
    [ -n "$pat" ] || continue
    case "$*" in *"$pat"*) [ "$file" = FAIL ] && exit 1; cat "$file"; exit 0 ;; esac
  done < "$TD/gh.rules"
fi
echo '[]'
EOF
sed -i "s|__T__|$T|" "$T/stub/curl" "$T/stub/gh"
chmod +x "$T/stub/curl" "$T/stub/gh"
export PATH="$T/stub:$PATH"
rules() { printf '%s\n' "$@" > "$T/rules"; }
JENV=(HARNESS_SECRET=test-fixture-secret JOBS_URL=http://jobs.test JOBS_RETRIES=0)
rr_puts() { awk -F'\t' '$1=="PUT" && $2 ~ /\/api\/ledger$/ {print $3}' "$T/curl.log" | jq -c 'select(.kind=="reopen_reason")' 2>/dev/null; }

# ============================================================================
# R3 size cut and round trip
# ============================================================================
BIG=$(printf 'x%.0s' $(seq 1 2000))
jq -n --arg b "$BIG" '[range(6) | {createdAt: "2026-10-08T1\(.):00:00Z", author: {name: "a\(.)"}, body: "c\(.) \($b)"}]' > "$T/r3.json"
P3=$(HARNESS="$LH" bash -c '. "$1"; rr_pick "$2" 2026-10-08T00:00:00Z 2026-10-08T23:59:59Z app' _ "$LIB" "$T/r3.json")
eq "R3 the newest five kept" "$(jq -r '[.[].author] | join(",")' <<<"$P3")" "a1,a2,a3,a4,a5"
eq "R3 each text cut to 500" "$(jq '[.[].text | length] | max' <<<"$P3")" 500
C6=$(jq -n --arg b "${BIG:0:1000}" '[range(6) | {at: "2026-10-08T1\(.):00:00Z", author: "a\(.)", text: "c\(.) \($b)"}]')
E3=$(HARNESS="$LH" RR_NOW=$FIXED_NOW bash -c '. "$1"; rr_encode alpha-os AL-1 20261008 review paused - 2026-10-07T00:00:00Z 2026-10-09T23:59:59Z app ok "$2" 1' _ "$LIB" "$C6")
[ "$(printf '%s' "$E3" | LC_ALL=C wc -c)" -le 3800 ] && ok || bad "R3 the encoded detail must be <= 3800 bytes (got $(printf '%s' "$E3" | wc -c))"
jq -e . <<<"$E3" >/dev/null 2>&1 && ok || bad "R3 the encoded detail must be valid JSON"
eq "R3 the oldest comments dropped first" "$(jq -r '[.comments[].author] | join(",")' <<<"$E3")" "a3,a4,a5"
eq "R3 v1 fields" "$(jq -r '[.v, .project, .key, .day, .from, .to, (.move_at|tostring), .source, .read, .attempts, .at] | map(tostring) | join(",")' <<<"$E3")" \
  "1,alpha-os,AL-1,20261008,review,paused,null,app,ok,1,2026-10-10T12:00:00Z"

# rr_save through the REAL jobs client, then the PUT body fed back as the row.
R3H="$T/r3h"; mkdir -p "$R3H/env"
: > "$T/curl.log"; rules
D3J=$(HARNESS="$LH" RR_NOW=$FIXED_NOW bash -c '. "$1"; rr_encode alpha-os AL-1 20261008 review paused 2026-10-08T12:00:00Z 2026-10-07T12:00:00Z 2026-10-09T12:00:00Z app ok "$2" 1' \
  _ "$LIB" '[{"at":"2026-10-08T13:00:00Z","author":"Dana","text":"The discount toggle is still there"}]')
env HARNESS="$R3H" HARNESS_ENV_DIR="$R3H/env" "${JENV[@]}" bash -c '. "$1" >/dev/null 2>&1 || exit 99; . "$2"; rr_save alpha-os AL-1 saved "$3"' jc "$DIR/bin/jobs-client.sh" "$LIB" "$D3J"
eq "R3 rr_save rc on a 200" "$?" 0
PUT=$(rr_puts)
eq "R3 one reopen_reason PUT" "$(grep -c . <<<"$PUT")" 1
eq "R3 PUT key and status" "$(jq -r '.key + "|" + .status' <<<"$PUT")" "alpha-os AL-1|saved"
eq "R3 mirror says ledger:true" "$(jq -r '.status + "|" + (.ledger|tostring)' "$R3H/state/reopen-reasons/alpha-os/AL-1.json" 2>/dev/null)" "saved|true"
ROW=$(jq -c '{ledger: {kind, key, status, detail, updated_at: "2026-10-10T04:15:02Z"}}' <<<"$PUT")
PAGE=$(jq -c '{ledgers: [{kind, key, status, detail, updated_at: "2026-10-10T04:15:02Z"}]}' <<<"$PUT")
scratch_rm "$R3H/state"   # the reader must get it from the row, not the mirror
rules "kind=reopen_reason&key=alpha-os%20AL-1	200	$ROW" "kind=reopen_reason&limit=200	200	$PAGE"
OUT=$(env HARNESS="$R3H" HARNESS_ENV_DIR="$R3H/env" "${JENV[@]}" RR_NOW=$FIXED_NOW bash -c \
  '. "$1" >/dev/null 2>&1 || exit 99; . "$2"; rr_plan_line alpha-os AL-1 >/dev/null; printf "%s\n%s" "$RR_LOG" "$RR_LINE"' jc "$DIR/bin/jobs-client.sh" "$LIB")
has "R3 plan line: from/to" "$OUT" "moved from review back to paused"
has "R3 plan line: day" "$OUT" "On 20261008"
has "R3 plan line: author and text" "$OUT" "Dana (2026-10-08T13:00:00Z): The discount toggle is still there"
eq "R3 plan line source" "$(head -1 <<<"$OUT")" "saved from ledger (1 comments, day 20261008)"
NOTE=$(env HARNESS="$R3H" HARNESS_ENV_DIR="$R3H/env" "${JENV[@]}" RR_NOW=$FIXED_NOW bash -c \
  '. "$1" >/dev/null 2>&1 || exit 99; . "$2"; rr_triage_note alpha-os' jc "$DIR/bin/jobs-client.sh" "$LIB")
has "R3 triage note: the row" "$NOTE" "AL-1 (review -> paused, 20261008, saved): Dana: The discount toggle is still there"
# a failed PUT: rc 1, mirror kept with ledger:false
rules '"kind":"reopen_reason"	500	{"error":"boom"}'
env HARNESS="$R3H" HARNESS_ENV_DIR="$R3H/env" "${JENV[@]}" bash -c '. "$1" >/dev/null 2>&1 || exit 99; . "$2"; rr_save alpha-os AL-1 saved "$3"' jc "$DIR/bin/jobs-client.sh" "$LIB" "$D3J"
eq "R3 rr_save rc on a 500" "$?" 1
eq "R3 mirror says ledger:false" "$(jq -r '.ledger|tostring' "$R3H/state/reopen-reasons/alpha-os/AL-1.json" 2>/dev/null)" "false"

# ============================================================================
# R4-R7, R12: the real bin/reopen-metrics.sh
# ============================================================================
# determinism: ok the lane dates its CSV rows and snapshots by the wall-clock day; the fixture must use the same day
TODAY=$(date -u +%Y%m%d)
YDAY=$(date -u -d "$TODAY -1 day" +%Y%m%d)
TISO="${TODAY:0:4}-${TODAY:4:2}-${TODAY:6:2}"
YISO="${YDAY:0:4}-${YDAY:4:2}-${YDAY:6:2}"

app_fixture() { # app_fixture <dir> — a scratch harness with one app board, alpha-os
  local R="$1"
  scratch_rm "$R"; mkdir -p "$R/env" "$R/logs" "$R/state/board-snapshots/alpha-os" "$R/builds" "$R/bin"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$R/bin/"
  echo 'alpha-os   Acme/alpha-os   https://alpha.example  /api/board  2' > "$R/fleet.conf"
  echo 'ALPHA_INTERNAL_API_TOKEN=tok-fixture-1' > "$R/env/alpha-os.env"
  echo '[{"key":"AL-1","status":"review","waitingOn":null}]' > "$R/state/board-snapshots/alpha-os/$YDAY.json"
}
DETAIL_OK=$(jq -nc --arg t "$TISO" --arg y "$YISO" '{ticket:{id:"t1",key:"AL-1",
  activity:[{type:"status_change",toValue:"in_progress",createdAt:"\($t)T00:30:00Z"}],
  comments:[{createdAt:"\($y)T23:00:00Z",author:{name:"Dana"},body:"The export still drops the last row"},
            {createdAt:"\($t)T00:40:00Z",author:{name:"Dana"},body:"<p>Also the total is off by one</p>"},
            {createdAt:"2020-01-01T00:00:00Z",author:{name:"Dana"},body:"an old comment"}]}}')
app_rules() { # app_rules <detail code> <detail body>
  rules "/api/board/boards/b1/tickets	200	{\"tickets\":[{\"id\":\"t1\",\"key\":\"AL-1\",\"status\":\"in_progress\",\"waitingOn\":null}]}" \
        "/api/board/tickets/t1	$1	$2" \
        "/api/board/boards	200	{\"boards\":[{\"id\":\"b1\"}]}"
}
lane() { # lane <dir> [VAR=v ...] -> rc; stdout in $T/lane.out
  local R="$1"; shift
  : > "$T/curl.log"; : > "$T/gh.log"
  env HARNESS="$R" HARNESS_ENV_DIR="$R/env" FLEET_CONF="$R/fleet.conf" "${JENV[@]}" "$@" \
    bash "$DIR/bin/reopen-metrics.sh" > "$T/lane.out" 2>&1
  echo $?
}
detail_gets() { grep -c $'^GET\thttps://alpha.example/api/board/tickets/' "$T/curl.log"; }

# --- R4 app board end to end ---
R4="$T/r4"; app_fixture "$R4"; app_rules 200 "$DETAIL_OK"
eq "R4 lane rc" "$(lane "$R4")" 0
eq "R4 CSV row unchanged in shape" "$(grep -c "^$TODAY,alpha-os,AL-1,review,in_progress$" "$R4/logs/reopens.csv")" 1
PUT=$(rr_puts)
eq "R4 exactly one reopen_reason PUT" "$(grep -c . <<<"$PUT")" 1
eq "R4 PUT key/status" "$(jq -r '.key + "|" + .status' <<<"$PUT")" "alpha-os AL-1|saved"
eq "R4 two comments in the window" "$(jq -r '.detail | fromjson | [.comments[].text] | join("|")' <<<"$PUT")" \
  "The export still drops the last row|Also the total is off by one"
eq "R4 detail fields" "$(jq -r '.detail | fromjson | [.day, .from, .to, .move_at, .source, .read] | join(",")' <<<"$PUT")" \
  "$TODAY,review,in_progress,${TISO}T00:30:00Z,app,ok"
[ -s "$R4/state/reopen-reasons/alpha-os/AL-1.json" ] && ok || bad "R4 the mirror file must exist"
eq "R4 one detail GET" "$(detail_gets)" 1
eq "R4 no write to a board route" "$(grep -cE $'^(POST|PUT|PATCH|DELETE)\thttps://alpha.example' "$T/curl.log")" 0
has "R4 the run line" "$(cat "$T/lane.out")" "reopen reasons: 1 saved, 0 no-comment, 0 unreadable, 0 left for the next run (cap 20)"
hasnt "R4 the token is not in the mirror" "$(cat "$R4/state/reopen-reasons/alpha-os/AL-1.json")" "tok-fixture-1"
grep -q '"id":"t1"' "$R4/state/board-snapshots/alpha-os/$TODAY.json" && ok || bad "R4 the snapshot keeps the ticket id"
cp "$R4/logs/reopens.csv" "$T/r4.csv"

# --- R6 a second run reads and writes nothing ---
eq "R6 lane rc" "$(lane "$R4")" 0
eq "R6 no reopen_reason PUT" "$(rr_puts | grep -c .)" 0
eq "R6 no detail GET" "$(detail_gets)" 0
has "R6 the run line" "$(cat "$T/lane.out")" "reopen reasons: 0 saved, 0 no-comment, 0 unreadable, 0 left"

# --- R6b a ledger miss is re-put from the mirror, without a board read ---
jq -c '.ledger = false' "$R4/state/reopen-reasons/alpha-os/AL-1.json" > "$T/m.json" && cp "$T/m.json" "$R4/state/reopen-reasons/alpha-os/AL-1.json"
lane "$R4" >/dev/null
eq "R6b one re-put" "$(rr_puts | jq -r '.key + "|" + .status')" "alpha-os AL-1|saved"
eq "R6b no detail GET" "$(detail_gets)" 0
eq "R6b mirror back to ledger:true" "$(jq -r '.ledger|tostring' "$R4/state/reopen-reasons/alpha-os/AL-1.json")" true

# --- R6c the ledger is down: mirror written, one ALERTS line names the key ---
R6C="$T/r6c"; app_fixture "$R6C"; app_rules 200 "$DETAIL_OK"
printf '%s\n' '"kind":"reopen_reason"	500	{"error":"boom"}' >> "$T/rules"
# the PUT rule must win over the board rules: move it first
{ grep '"kind":"reopen_reason"' "$T/rules"; grep -v '"kind":"reopen_reason"' "$T/rules"; } > "$T/rules.n" && mv "$T/rules.n" "$T/rules"
lane "$R6C" >/dev/null
eq "R6c mirror says ledger:false" "$(jq -r '.status + "|" + (.ledger|tostring)' "$R6C/state/reopen-reasons/alpha-os/AL-1.json" 2>/dev/null)" "saved|false"
has "R6c the run line names it" "$(cat "$T/lane.out")" "(1 not in the ledger)"
eq "R6c one ALERTS line" "$(grep -c 'reopen reason saved on the hub only' "$R6C/logs/ALERTS.log" 2>/dev/null)" 1
has "R6c the line names the key" "$(grep 'reopen reason saved on the hub only' "$R6C/logs/ALERTS.log" 2>/dev/null)" "alpha-os AL-1"

# --- R7 unreadable: 3 tries, one ALERTS line, then left ---
R7="$T/r7"; app_fixture "$R7"; app_rules 500 '{"error":"down"}'
for i in 1 2 3; do
  lane "$R7" >/dev/null
  eq "R7 run $i status/attempts" "$(jq -r '.status + "|" + (.attempts|tostring) + "|" + .read' "$R7/state/reopen-reasons/alpha-os/AL-1.json" 2>/dev/null)" "unreadable|$i|unreadable"
  eq "R7 run $i one detail GET" "$(detail_gets)" 1
  [ "$i" -lt 3 ] && eq "R7 run $i no ALERTS line yet" "$(count "$R7/logs/ALERTS.log" 'not saved after 3 tries')" 0
done
eq "R7 one ALERTS line after run 3" "$(grep -c 'reopen reason not saved after 3 tries' "$R7/logs/ALERTS.log")" 1
has "R7 the line names the key" "$(grep 'not saved after 3 tries' "$R7/logs/ALERTS.log")" "alpha-os AL-1"
has "R7 the run line" "$(cat "$T/lane.out")" "0 saved, 0 no-comment, 1 unreadable"
lane "$R7" >/dev/null
eq "R7 run 4 no detail GET" "$(detail_gets)" 0
eq "R7 run 4 no new ALERTS line" "$(grep -c 'not saved after 3 tries' "$R7/logs/ALERTS.log")" 1
eq "R7 never the reopen_rate wording" "$(count "$R7/logs/ALERTS.log" 'reopen_rate rows')" 0

# --- R7b the cap: rows over REOPEN_REASON_MAX_PER_RUN are left, and said ---
R7B="$T/r7b"; app_fixture "$R7B"; app_rules 200 "$DETAIL_OK"
lane "$R7B" REOPEN_REASON_MAX_PER_RUN=0 >/dev/null
eq "R7b no detail GET at cap 0" "$(detail_gets)" 0
has "R7b the run line" "$(cat "$T/lane.out")" "0 saved, 0 no-comment, 0 unreadable, 1 left for the next run (cap 0)"

# --- R12 the off switch ---
R12="$T/r12"; app_fixture "$R12"; app_rules 200 "$DETAIL_OK"
eq "R12 lane rc" "$(lane "$R12" REOPEN_REASON=0)" 0
eq "R12 no reopen_reason PUT" "$(rr_puts | grep -c .)" 0
eq "R12 no detail GET" "$(detail_gets)" 0
cmp -s "$R12/logs/reopens.csv" "$T/r4.csv" && ok || bad "R12 the CSV must be byte-identical to the R4 run's CSV"
hasnt "R12 no run line" "$(cat "$T/lane.out")" "reopen reasons:"
[ ! -e "$R12/state/reopen-reasons" ] && ok || bad "R12 no mirror may be written"

# --- R5 GitHub-Issues end to end ---
R5="$T/r5"; scratch_rm "$R5"; mkdir -p "$R5/env" "$R5/logs" "$R5/state" "$R5/builds" "$R5/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$R5/bin/"
echo 'gamma      Acme/gamma      https://gamma.example  -           6 box-small' > "$R5/fleet.conf"
# determinism: ok the lane windows the events to 14 days before the wall clock
D3=$(date -u -d '3 days ago' +%Y-%m-%d); D3C=${D3//-/}
D4=$(date -u -d "$D3 -1 day" +%Y-%m-%d)
cat > "$T/r5.events.json" <<EOF
[{"event":"closed","created_at":"${D3}T09:00:00Z","issue":{"number":11}},
 {"event":"reopened","created_at":"${D3}T10:00:00Z","issue":{"number":11}}]
EOF
cat > "$T/r5.comments.json" <<EOF
[{"created_at":"${D3}T10:05:00Z","user":{"login":"client-a","type":"User"},"body":"The chart still shows last week"},
 {"created_at":"${D3}T10:06:00Z","user":{"login":"helper[bot]","type":"Bot"},"body":"Thanks for the report"}]
EOF
printf '%s\t%s\n' "issues/11/comments" "$T/r5.comments.json" "issues/events?per_page=100&page=1" "$T/r5.events.json" > "$T/gh.rules"
eq "R5 lane rc" "$(lane "$R5")" 0
eq "R5 CSV row" "$(grep -c "^$D3C,gamma,#11,done,open$" "$R5/logs/reopens.csv")" 1
PUT=$(rr_puts)
eq "R5 PUT key/status" "$(jq -r '.key + "|" + .status' <<<"$PUT")" "gamma #11|saved"
eq "R5 the user comment only" "$(jq -r '.detail | fromjson | [.comments[] | .author + ":" + .text] | join("|")' <<<"$PUT")" \
  "client-a:The chart still shows last week"
eq "R5 source gh, no move_at" "$(jq -r '.detail | fromjson | .source + "|" + (.move_at|tostring)' <<<"$PUT")" "gh|null"
has "R5 the comments call carries since=D-1" "$(cat "$T/gh.log")" "repos/Acme/gamma/issues/11/comments?since=${D4}T00:00:00Z&per_page=100"
[ -s "$R5/state/reopen-reasons/gamma/_11.json" ] && ok || bad "R5 mirror at gamma/_11.json"
rm -f "$T/gh.rules"

# ============================================================================
# R8 the plan block, verbatim from bin/lib/rb/plan.sh
# ============================================================================
awk '/^# >>> reopen reason \(BH-6159\)/{f=1} f; /^# <<< reopen reason \(BH-6159\)/{exit}' "$DIR/bin/lib/rb/plan.sh" > "$T/block.sh"
grep -q 'rr_plan_line' "$T/block.sh" && ok || bad "R8 could not extract the reopen reason block from bin/lib/rb/plan.sh"
H8="$T/h8"; scratch_rm "$H8"; mkdir -p "$H8/bin" "$H8/build"
scratch_install_closure bin/lib/reopen-reason.sh "$H8" >/dev/null || bad "R8 could not install the lib closure"
cp "$DIR/bin/fleet-conf.sh" "$H8/bin/"
printf '%s\n' 'alpha-os Acme/alpha-os https://alpha.example /api/board 2' 'gamma Acme/gamma - - 6' > "$H8/fleet.conf"
mkrow() { # mkrow <key> <at-epoch> <comments-json> -> a job_ledger_row line
  local d; d=$(jq -nc --arg k "$1" --argjson at "$2" --argjson c "$3" '{v:1,project:"alpha-os",key:$k,day:"20261008",at:($at|todate),
    from:"review",to:"paused",move_at:null,window:["a","b"],source:"app",read:"ok",attempts:1,comments:$c}')
  jq -nc --arg d "$d" '{status:"saved",detail:$d}'
}
C1='[{"at":"2026-10-08T13:00:00Z","author":"Dana","text":"The discount toggle is still there"}]'
block() { # block <project> <key> <row-key-that-exists> <row-line|404|500> [VAR=v ...] -> REOPEN_REASON_LINE; pipeline.log in $H8/build
  local p="$1" k="$2" rk="$3" row="$4"; shift 4
  rm -f "$H8/build/pipeline.log"
  env HARNESS="$H8" FLEET_CONF="$H8/fleet.conf" BUILD="$H8/build" PROJECT="$p" KEY="$k" RR_NOW=$FIXED_NOW STUB_RK="$rk" STUB_ROW="$row" "$@" bash -c '
    STAMP() { echo TS; }
    job_ledger_row() { [ "$1" = reopen_reason ] || return 1
      case "$STUB_ROW" in 500) return 1 ;; 404) return 2 ;; esac
      [ "$2" = "$STUB_RK" ] || return 2
      printf "%s" "$STUB_ROW"; }
    . "$0"; printf "%s" "$REOPEN_REASON_LINE"' "$T/block.sh" 2>/dev/null
}
plog() { cat "$H8/build/pipeline.log" 2>/dev/null; }
L=$(block alpha-os AL-1 "alpha-os AL-1" "$(mkrow AL-1 $FIXED_NOW "$C1")")
has "R8 saved: from/to" "$L" "moved from review back to paused"
has "R8 saved: the comment" "$L" "Dana (2026-10-08T13:00:00Z): The discount toggle is still there"
O=$(grep -o 'UNTRUSTED INPUT rr-[0-9a-f]\{8\}' <<<"$L" | sort -u)
[ "$(grep -c . <<<"$O")" = 1 ] && [ "$(grep -o '=== UNTRUSTED INPUT rr-[0-9a-f]\{8\} ===' <<<"$L" | grep -c .)" = 1 ] \
  && [ "$(grep -o '=== END UNTRUSTED INPUT rr-[0-9a-f]\{8\} ===' <<<"$L" | grep -c .)" = 1 ] && ok \
  || bad "R8 one open and one close marker with the same id (got '$L')"
has "R8 saved: pipeline.log" "$(plog)" "REOPEN REASON: saved from ledger (1 comments, day 20261008)"
L=$(block alpha-os AL-1 "alpha-os AL-1" "$(mkrow AL-1 $FIXED_NOW '[]')")
has "R8 no-comment: reason not known" "$L" "the reason is not known"
hasnt "R8 no-comment: no marker" "$L" "UNTRUSTED INPUT"
has "R8 no-comment: pipeline.log" "$(plog)" "REOPEN REASON: no-comment from ledger"
L=$(block alpha-os AL-1 "alpha-os AL-1" "$(mkrow AL-1 $((FIXED_NOW - 30 * 86400)) "$C1")")
has "R8 exactly 30 d: used" "$L" "THIS TICKET WAS REOPENED"
L=$(block alpha-os AL-1 "alpha-os AL-1" "$(mkrow AL-1 $((FIXED_NOW - 30 * 86400 - 1)) "$C1")")
eq "R8 30 d + 1 s: empty" "$L" ""
has "R8 30 d + 1 s: too old" "$(plog)" "REOPEN REASON: too old (30 d)"
L=$(block alpha-os AL-1 "alpha-os AL-1" "$(mkrow AL-1 $((FIXED_NOW - 90 * 86400)) "$C1")")
eq "R8 90 d: empty" "$L" ""
L=$(block alpha-os AL-1 - 404)
eq "R8 no row: empty" "$L" ""
has "R8 no row: none" "$(plog)" "REOPEN REASON: none"
L=$(block alpha-os AL-1 - 500)
eq "R8 outage: empty" "$L" ""
has "R8 outage: said" "$(plog)" "REOPEN REASON: none (ledger unreadable)"
L=$(block gamma BH-11 "gamma #11" "$(mkrow '#11' $FIXED_NOW "$C1")")
has "R8 GitHub key BH-11 finds the #11 row" "$L" "The discount toggle is still there"
L=$(block alpha-os AL-11 "alpha-os #11" "$(mkrow '#11' $FIXED_NOW "$C1")")
eq "R8 an app board never maps AL-11 to #11" "$L" ""
L=$(block alpha-os AL-1 "alpha-os AL-1" "$(mkrow AL-1 $FIXED_NOW "$C1")" REOPEN_REASON=0)
eq "R12 REOPEN_REASON=0: the plan block prints nothing" "$L" ""

# ============================================================================
# R9 the prompt seam
# ============================================================================
PS="$DIR/bin/lib/rb/plan.sh"
# TEST-CHANGE (BH-6159, merge-queue batch #6288): the line sits BEFORE
# $KIND_HINT_LINE, because tests/prebuild-repro-contract.bh-2039 A13e pins
# `$KIND_HINT_LINE$CARRIED_NOTE_LINE${REPRO_BRIEF_LINE:-} IF KIND IS BUG` as one
# run. The old R9 pinned it between those two, which A13e forbids.
# TEST-CHANGE (BH-7970): the prompt text moved to prompts/stages/plan.md, where each token is written ${NAME}.
eq "R9 the prompt carries the line once" "$(grep -c '${REOPEN_REASON_LINE}${KIND_HINT_LINE}${CARRIED_NOTE_LINE}' "$DIR/prompts/stages/plan.md")" 1
a=$(grep -n '^# <<< carried note' "$PS" | cut -d: -f1); b=$(grep -n '^# >>> reopen reason (BH-6159)' "$PS" | cut -d: -f1); c=$(grep -n '^# <<< ticket meta' "$PS" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && ok \
  || bad "R9 the block must sit after '# <<< carried note' and before '# <<< ticket meta' (lines '$a' '$b' '$c')"

# ============================================================================
# R10 the triage note
# ============================================================================
H10="$T/h10"; scratch_rm "$H10"; mkdir -p "$H10/state"
page() { # page <n alpha rows in window> -> a ledger page; the rows are 1 h apart, newest last
  jq -nc --argjson now $FIXED_NOW --argjson n "$1" '
    def row($p; $k; $at; $txt): {kind:"reopen_reason", key:"\($p) \($k)", status:"saved",
      detail: ({v:1,project:$p,key:$k,day:"20261009",at:($at|todate),from:"review",to:"in_progress",move_at:null,
                window:["a","b"],source:"app",read:"ok",attempts:1,comments:[{at:"x",author:"Dana",text:$txt}]} | tojson)};
    {ledgers: ([range($n) | row("alpha-os"; "AL-\(.)"; $now - 86400 - (($n - .) * 3600); "alpha says \(.)")]
              + [row("beta-os"; "BE-1"; $now - 3600; "beta says")]
              + [row("alpha-os"; "AL-OLD"; $now - 15 * 86400; "too old")])}'
}
note() { # note -> the note for alpha-os; ledger_page calls in $T/lp.calls
  env HARNESS="$H10" RR_NOW=$FIXED_NOW STUB_PAGE="${STUB_PAGE:-}" LP_CALLS="$T/lp.calls" bash -c '
    ledger_page() { echo "$*" >> "$LP_CALLS"; [ -n "$STUB_PAGE" ] || return 1; printf "%s" "$STUB_PAGE"; }
    . "$0"; rr_triage_note alpha-os' "$LIB" 2>/dev/null
}
CACHE="$H10/state/reopen-reasons/triage-alpha-os.txt"
rm -f "$CACHE" "$T/lp.calls"; STUB_PAGE=$(page 3)
N=$(STUB_PAGE="$STUB_PAGE" note)
eq "R10 one ledger read" "$(cat "$T/lp.calls")" "reopen_reason 200"
eq "R10 this project's in-window rows, newest first" "$(grep -o 'AL-[0-9A-Z]* (' <<<"$N" | tr -d ' (' | paste -sd, -)" "AL-2,AL-1,AL-0"
hasnt "R10 another project's row" "$N" "BE-1"
hasnt "R10 a 15-day-old row" "$N" "AL-OLD"
has "R10 the row text" "$N" "AL-2 (review -> in_progress, 20261009, saved): Dana: alpha says 2"
O=$(grep -o 'UNTRUSTED INPUT rrt-[0-9a-f]\{8\}' <<<"$N" | sort -u | grep -c .)
eq "R10 one marker id, open and close" "$O" 1
has "R10 the close marker" "$N" "=== END UNTRUSTED INPUT rrt-"
rm -f "$CACHE"; N=$(STUB_PAGE="$(page 12)" note)
eq "R10 12 rows -> 10 listed" "$(grep -c '^AL-' <<<"$N")" 10
[ "${#N}" -le 2000 ] && ok || bad "R10 the note must be <= 2000 chars (got ${#N})"
# the cache: fresh -> no read; an outage with a 2 h cache -> the cache; with a 25 h cache -> nothing
rm -f "$T/lp.calls"; touch -d "@$((FIXED_NOW - 600))" "$CACHE"
N2=$(STUB_PAGE="" note)
eq "R10 a 10-minute cache is reused" "$N2" "$N"
[ ! -s "$T/lp.calls" ] && ok || bad "R10 a fresh cache must not read the ledger"
touch -d "@$((FIXED_NOW - 7200))" "$CACHE"
eq "R10 outage, 2 h cache -> the cached note" "$(STUB_PAGE="" note)" "$N"
grep -q 'reopen_reason 200' "$T/lp.calls" && ok || bad "R10 a stale cache must try the ledger first"
touch -d "@$((FIXED_NOW - 25 * 3600))" "$CACHE"
eq "R10 outage, 25 h cache -> empty" "$(STUB_PAGE="" note)" ""
rm -f "$CACHE"
eq "R10 outage, no cache -> empty" "$(STUB_PAGE="" note)" ""
# the run-triage.sh lines, verbatim: a note is appended; no note leaves the prompt byte-identical
awk '/^# BH-6159: the saved reasons/{f=1;next} f{print} f && /^\$RR_NOTE"$/{exit}' "$DIR/bin/run-triage.sh" > "$T/triage.sh"
grep -q 'rr_triage_note' "$T/triage.sh" && ok || bad "R10 could not extract the run-triage.sh lines"
H10B="$T/h10b"; scratch_rm "$H10B"; mkdir -p "$H10B/state"
scratch_install_closure bin/lib/reopen-reason.sh "$H10B" >/dev/null || bad "R10 could not install the lib closure"
tri() { env HARNESS="$H10B" PROJECT=alpha-os RR_NOW=$FIXED_NOW STUB_PAGE="$1" bash -c '
  ledger_page() { [ -n "$STUB_PAGE" ] || return 1; printf "%s" "$STUB_PAGE"; }
  PROMPT_TEXT="THE SOP"; . "$0"; printf "%s" "$PROMPT_TEXT"' "$T/triage.sh" 2>/dev/null; }
OUTP=$(tri "$(page 1)")
has "R10 run-triage appends the note" "$OUTP" "REOPENED TICKETS (deterministic, BH-6159)"
eq "R10 the SOP stays first" "${OUTP%%$'\n'*}" "THE SOP"
scratch_rm "$H10B/state/reopen-reasons"
eq "R10 no rows: the prompt is byte-identical" "$(tri '{"ledgers":[]}')" "THE SOP"

# ============================================================================
# R11 the weekly line
# ============================================================================
H11="$T/h11"; scratch_rm "$H11"; mkdir -p "$H11/state"
bundle() { # bundle <out> <ok true|false> <project:ticket>...
  local out="$1" okv="$2"; shift 2
  printf '%s\n' "$@" | jq -R 'split(":") | {id:"x", source:"reopen", at:"2026-10-09T00:00:00Z", project:.[0], ticket:.[1], pr:"",
      files:[], lane:"reopen", reason:"reopened: review -> in_progress"}' \
    | jq -s --argjson ok "$okv" '{items:(. + [{id:"y",source:"alerts",project:"cromford",ticket:null,lane:"rebase",reason:"r"}]),
        sources:{reopen:{ok:$ok,n:(length),truncated:false}}, incomplete:false}' > "$out"
}
ITEMS=(project-2:TA-1 project-2:TA-2 project-2:TA-3 project-4:TK-1 project-4:TK-2 project-3:TK-1 project-3:TK-2 "cromford:#9")
bundle "$T/b11.json" true "${ITEMS[@]}"
for pk in project-2:TA-1 project-2:TA-2 project-4:TK-1 project-4:TK-2 project-3:TK-1 "cromford:#9"; do
  p=${pk%%:*}; k=${pk#*:}; sk=$(printf '%s' "$k" | tr -c 'A-Za-z0-9._-' '_')
  mkdir -p "$H11/state/reopen-reasons/$p"
  st=saved; [ "$k" = TK-2 ] && st=no-comment
  echo "{\"status\":\"$st\"}" > "$H11/state/reopen-reasons/$p/$sk.json"
done
echo '{"status":"unreadable"}' > "$H11/state/reopen-reasons/project-3/TK-2.json"
wl() { HARNESS="$H11" bash -c '. "$0"; rr_week_line "$1" 7' "$LIB" "$1" 2>/dev/null; }
eq "R11 the line" "$(wl "$T/b11.json")" "reopens 7d: project-2 3, project-4 2, project-3 2, cromford 1 (6 of 8 with a saved reason)"
bundle "$T/b11n.json" true; jq '.items |= map(select(.lane != "reopen"))' "$T/b11n.json" > "$T/b11n2.json"
eq "R11 no reopen items" "$(wl "$T/b11n2.json")" "reopens 7d: none"
bundle "$T/b11f.json" false "${ITEMS[@]}"
eq "R11 source not ok" "$(wl "$T/b11f.json")" "reopens 7d: source not ok"

# the real bin/lookback.sh: the line reaches the one summary sent to lane-alert
if command -v flock >/dev/null 2>&1; then
  H11L="$T/h11l"; scratch_rm "$H11L"; mkdir -p "$H11L/logs" "$H11L/env" "$H11L/locks" "$H11L/flags"
  : > "$H11L/env/global.env"
  scratch_install_closure bin/lookback.sh "$H11L" >/dev/null || bad "R11 could not install the lookback closure"
  rm -f "$H11L"/bin/lib/lookback-{followup,cluster,file,board}.sh
  cp "$T/b11.json" "$T/b11l.json"
  cp -r "$H11/state" "$H11L/state"
  cat > "$H11L/bin/lookback-collect.sh" <<SH
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
mkdir -p "\$(dirname "\$out")"; cp "$T/b11l.json" "\$out"
SH
  printf '_jobs_req() { echo %s; }\n' "'{\"ledgers\":[]}'" > "$H11L/bin/jobs-client.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.lane-alert"\n' "$T" > "$H11L/bin/lane-alert.sh"
  chmod +x "$H11L/bin/lookback-collect.sh" "$H11L/bin/lane-alert.sh"
  rm -f "$T/calls.lane-alert"
  env -i PATH="$PATH" HOME="$T" HARNESS="$H11L" HARNESS_ENV_DIR="$H11L/env" bash "$H11L/bin/lookback.sh" > "$T/lb.out" 2>&1
  eq "R11 lookback rc" "$?" 0
  has "R11 the lookback summary carries the line" "$(cat "$T/calls.lane-alert" 2>/dev/null)" \
    "reopens 7d: project-2 3, project-4 2, project-3 2, cromford 1 (6 of 8 with a saved reason)"
else
  echo "R11 lookback drive SKIPPED — flock missing"
fi

echo "reopen-reason.bh-6159-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
