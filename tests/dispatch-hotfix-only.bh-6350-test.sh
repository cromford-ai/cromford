#!/bin/bash
# tests/dispatch-hotfix-only.bh-6350-test.sh — the per-project dispatch mode
# (BH-6350): normal | hotfix-only (with an allow-list) | paused.
#
# RED FIRST. On main e70ca5fc5 D1 launches BH-902 (no mode exists), G1 finds
# no `# >>> dispatch mode gate` block in the pipeline, P1 spawns the plain job
# and F1 picks it. The observed red run is saved in the build dir as red.txt.
#
#   A1-A12  dm_parse / dm_admit_ticket / dm_job_admit / dm_meta_admit tables
#   N1      no client, no file, no row -> normal, DM_SRC=default
#   R2/R3   queue_row_job_file -> rebuild:true -> admitted; the since-file round trip
#   D1      fastpath, hotfix-only: the hotfix launches, the plain ticket waits,
#           ONE DISPATCH-MODE line, no label or comment write
#   D2      fastpath, the allow-listed plain ticket launches
#   D3      a ticket with an open PR keeps its paths: a resume and a pool
#           machine pass the run-build gate; a rebase job and a blocked-resolver
#           rebuild spawn in the pool
#   D4      paused wins: the fastpath declines with `project paused`
#   D5      back to normal: the waiting ticket launches on the next run
#   D6      dm_age_alert: 25 h -> one alert, no repeat; 23 h -> none; normal ->
#           resolved; a 48 h knob row -> none at 25 h
#   G1-G3   the run-build gate: BUILD_DEFERRED + rc 3; unknown label admits; hotfix admits
#   P1/P2   fly-pool tick: hotfix-only holds the plain job (it stays queued); normal spawns it
#   F1/F2   fly-dispatch file pick and rows pick skip the plain job
#   T1/T2   triage: one log line + the launch directive in hotfix-only; nothing in normal
#
# Drives the REAL bin/launch-fastpath.sh and bin/fly-pool.sh against scratch
# harnesses (the scaffolds of tests/launch-fastpath-stack.bh-3684-test.sh and
# tests/fly-pool-overlap-defer-uncounted.bh-5912-test.sh); the run-build gate,
# the triage block and the fly-dispatch regions are lifted by their markers and
# run. Run from anywhere: bash tests/dispatch-hotfix-only.bh-6350-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v flock   >/dev/null || { echo "flock missing — skipping"; exit 0; }
unset HOTFIX HOTFIX_LANE HF_RC RESUME_BUILD BUILDER_EXEC DISPATCH_MODE_ALERT_H DM_NOW JOBS_URL HARNESS_SECRET
NOW=$(date -u +%s)
DMLIB="$DIR/bin/lib/dispatch-mode.sh"

# ══ A. the lib's decision tables ═══════════════════════════════════════════
L="$T/lib"; mkdir -p "$L/flags" "$L/state"
lib() { ( HARNESS="$L"; . "$DMLIB" || exit 9; eval "$1" ); }
parse() { lib "dm_parse $(printf '%q' "$1"); printf '%s|%s|%s' \"\$DM_MODE\" \"\$DM_ALLOW\" \"\$DM_BAD\""; }
[ "$(parse 'hotfix-only')" = "hotfix-only||0" ] && ok || bad "A1 'hotfix-only' -> '$(parse 'hotfix-only')'"
[ "$(parse 'hotfix-only:6291, 6292')" = "hotfix-only|6291 6292|0" ] && ok || bad "A2 allow-list -> '$(parse 'hotfix-only:6291, 6292')'"
[ "$(parse 'hotfix-only:abc')" = "hotfix-only||1" ] && ok || bad "A3 unparseable -> '$(parse 'hotfix-only:abc')'"
[ "$(parse 'hotfix')" = "hotfix-only||1" ] && ok || bad "A4 'hotfix' -> '$(parse 'hotfix')'"
[ "$(parse 'normal')" = "normal||0" ] && ok || bad "A5 'normal' -> '$(parse 'normal')'"
[ "$(parse '')" = "hotfix-only||0" ] && ok || bad "A6 ON with no value -> '$(parse '')'"
adm() { lib "DM_MODE=$1; DM_ALLOW='$2'; dm_admit_ticket $3 $4 && echo admit || echo hold"; }
[ "$(adm hotfix-only '' 902 1)" = admit ] && ok || bad "A7 hotfix=1 admits"
[ "$(adm hotfix-only '' 902 2)" = admit ] && ok || bad "A7 hotfix=2 (unknown) admits"
[ "$(adm hotfix-only '' 902 0)" = hold ] && ok || bad "A8 plain, no allow-list holds"
[ "$(adm hotfix-only '902' 902 0)" = admit ] && ok || bad "A8 allow-listed plain admits"
[ "$(adm hotfix-only '901' 902 0)" = hold ] && ok || bad "A9 another number on the list holds"
[ "$(adm hotfix-only '6291' 62910 0)" = hold ] && ok || bad "A9 6291 vs 62910 is a hold (whole-number match)"
[ "$(adm hotfix-only '62910' 6291 0)" = hold ] && ok || bad "A9 62910 on the list does not admit 6291 (whole-number match)"
[ "$(adm hotfix-only '6291 6292' 06292 0)" = admit ] && ok || bad "A9 a leading zero still matches"
[ "$(adm normal '' 902 0)" = admit ] && ok || bad "A10 normal admits"
[ "$(adm paused '' 902 0)" = admit ] && ok || bad "A10 paused admits (the pause is the existing gates' call)"
job() { printf '%s\n' "$2" > "$L/$1.json"; lib "DM_MODE=hotfix-only; DM_ALLOW='${3:-}'; dm_job_admit '$L/$1.json' && echo admit || echo hold"; }
[ "$(job j1 '{"key":"BH-904","ticket_id":"904"}')" = hold ] && ok || bad "A11 a plain fresh job holds"
[ "$(job j2 '{"key":"BH-905","ticket_id":"905","hotfix":true}')" = admit ] && ok || bad "A11 a hotfix job admits"
[ "$(job j3 '{"key":"RB-77-abc","ticket_id":"77","rebase":{"kind":"rebase","pr":77}}')" = admit ] && ok || bad "A11 a rebase job admits"
[ "$(job j4 '{"key":"BH-906","ticket_id":"906","rebuild":true}')" = admit ] && ok || bad "A11 a rebuild job admits"
[ "$(job j5 '{"key":"BH-907","ticket_id":"907","deaths":1}')" = admit ] && ok || bad "A11 a death requeue admits"
[ "$(job j6 '{"key":"BH-908","ticket_id":"908"}' '908')" = admit ] && ok || bad "A11 an allow-listed job admits"
meta() { lib "DM_MODE=hotfix-only; DM_ALLOW='${3:-}'; dm_meta_admit $1 '$2' && echo admit || echo hold"; }
[ "$(meta 904 '{}')" = hold ] && ok || bad "A12 a plain row holds"
[ "$(meta 905 '{"hotfix":true}')" = admit ] && ok || bad "A12 a hotfix row admits"
[ "$(meta 77 '{"kind":"rebase","pr":77}')" = admit ] && ok || bad "A12 a rebase row admits"
[ "$(meta 906 '{"blocked_resolver":"red-ci"}')" = admit ] && ok || bad "A12 a blocked-resolver row admits"
[ "$(meta 908 '' 908)" = admit ] && ok || bad "A12 an allow-listed row with no meta admits"

# N1: no client, no file, no row.
[ "$(lib 'dm_read cromford; printf "%s|%s" "$DM_MODE" "$DM_SRC"')" = "normal|default" ] && ok \
  || bad "N1 nothing set reads normal/default"
printf 'hotfix-only:5\n' > "$L/flags/dispatch-mode-cromford"
[ "$(lib 'dm_read cromford; printf "%s|%s|%s" "$DM_MODE" "$DM_ALLOW" "$DM_SRC"')" = "hotfix-only|5|file" ] && ok \
  || bad "N1 the no-worker file is the value ($(lib 'dm_read cromford; echo "$DM_MODE|$DM_ALLOW|$DM_SRC"'))"
: > "$L/flags/paused-cromford"
[ "$(lib 'dm_read cromford; echo "$DM_MODE"')" = paused ] && ok || bad "N1 paused wins over hotfix-only"
rm -f "$L/flags"/*

# R2: queue_row_job_file carries rebuild:true from a blocked-resolver row meta.
mkdir -p "$L/q"
( HARNESS="$L"; . "$DIR/bin/lib/queue-row-job.sh"
  queue_row_job_file cromford "$L/q/BH-909.json" BH-909 909 0 '{"blocked_resolver":"red-ci"}' )
[ "$(jq -r '.rebuild // "absent"' "$L/q/BH-909.json" 2>/dev/null)" = true ] && ok || bad "R2 job.json carries rebuild:true ($(cat "$L/q/BH-909.json" 2>/dev/null))"
[ "$(lib "DM_MODE=hotfix-only; dm_job_admit '$L/q/BH-909.json' && echo admit || echo hold")" = admit ] && ok || bad "R2 that job is admitted"
( HARNESS="$L"; . "$DIR/bin/lib/queue-row-job.sh"
  queue_row_job_file cromford "$L/q/BH-910.json" BH-910 910 0 '{}' )
[ "$(jq -r '.rebuild // "absent"' "$L/q/BH-910.json" 2>/dev/null)" = absent ] && ok || bad "R2 a plain row writes no rebuild field"

# R3: the since file: seeded from set_at, kept across an allow-list edit, removed on normal.
S1=$(lib "DM_MODE=hotfix-only; DM_SET_AT=$(date -u -d "@$((NOW-3600))" +%Y-%m-%dT%H:%M:%SZ); DM_NOW=$NOW; dm_since_s bh")
[ "$S1" = "$((NOW-3600))" ] && ok || bad "R3 seeded from set_at ($S1)"
S2=$(lib "DM_MODE=hotfix-only; DM_SET_AT=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ); DM_NOW=$NOW; dm_since_s bh")
[ "$S2" = "$((NOW-3600))" ] && ok || bad "R3 a newer set_at (allow-list edit) does not restart the clock ($S2)"
lib "DM_MODE=normal; dm_age_alert bh"
[ -e "$L/state/dispatch-mode/bh.since" ] && bad "R3 normal removes the since file" || ok

# ══ D6. the age alert, with the real bin/lane-alert.sh ════════════════════
A="$T/alert"; mkdir -p "$A/logs" "$A/state" "$A/flags" "$A/env" "$A/bin"
scratch_install_closure bin/lane-alert.sh "$A" >/dev/null || bad "D6 closure install of bin/lane-alert.sh failed"
scratch_install_closure bin/lib/dispatch-mode.sh "$A" >/dev/null || bad "D6 closure install of the lib failed"
printf '#!/bin/bash\nexit 0\n' > "$A/bin/beat.sh"; chmod +x "$A/bin/beat.sh"
: > "$A/env/global.env"
age() { # age <hours-ago> [env...]
  local h="$1"; shift
  ( export HARNESS="$A" LANE_GATE_DISABLE=1 "$@"; . "$A/bin/lib/dispatch-mode.sh"
    DM_MODE=hotfix-only; DM_SET_AT=$(date -u -d "@$((NOW - h*3600))" +%Y-%m-%dT%H:%M:%SZ); DM_NOW=$NOW
    dm_age_alert cromford ) </dev/null >/dev/null 2>&1
}
nalert() { local n; n=$(grep -c 'dispatch mode hotfix-only has been on for' "$A/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
age 25
[ "$(nalert)" = 1 ] && ok || bad "D6 25 h raises exactly one alert (got $(nalert): $(cat "$A/logs/ALERTS.log" 2>/dev/null))"
grep -q 'dispatch mode hotfix-only has been on for 25 h' "$A/logs/ALERTS.log" 2>/dev/null && ok || bad "D6 the line names 25 h"
age 25
[ "$(nalert)" = 1 ] && ok || bad "D6 a second tick adds no line (got $(nalert))"
ASF="$A/state/alerts/dispatch-mode-hotfix-only_cromford.json"
[ -f "$ASF" ] && [ "$(jq -r '.resolved_at // "open"' "$ASF" 2>/dev/null)" = open ] && ok \
  || bad "D6 the alert id is open while hotfix-only stands ($(ls "$A/state/alerts/" 2>/dev/null))"
[ "$(jq -r '.severity // ""' "$ASF" 2>/dev/null)" = warn ] && ok || bad "D6 the alert is warn (digest), not a page ($(jq -c . "$ASF" 2>/dev/null))"
( export HARNESS="$A"; . "$A/bin/lib/dispatch-mode.sh"; DM_MODE=normal; dm_age_alert cromford ) </dev/null >/dev/null 2>&1
[ -e "$A/state/dispatch-mode/cromford.since" ] && bad "D6 normal removes the since file" || ok
[ "$(jq -r '.resolved_at // "open"' "$ASF" 2>/dev/null)" != open ] && ok \
  || bad "D6 the alert id is resolved after normal ($(cat "$ASF" 2>/dev/null))"
scratch_rm "$A/state" && mkdir -p "$A/state"; : > "$A/logs/ALERTS.log"
age 23
[ "$(nalert)" = 0 ] && ok || bad "D6 23 h raises none"
scratch_rm "$A/state" && mkdir -p "$A/state"; : > "$A/logs/ALERTS.log"
age 25 DISPATCH_MODE_ALERT_H=48
[ "$(nalert)" = 0 ] && ok || bad "D6 a 48 h line raises none at 25 h (env)"
scratch_rm "$A/state" && mkdir -p "$A/state"; : > "$A/logs/ALERTS.log"
scratch_install_closure bin/lib/lane-gate.sh "$A" >/dev/null
REG=$( . "$DIR/bin/lib/lanes-registry.sh" && lanes_json_path "$DIR" 2>/dev/null )
[ -r "$REG" ] || bad "D6 the lane registry did not compose ($REG)"
jq -nc --argjson f "$NOW" '{fetched_at:$f, values:{"lib.dispatch-mode.dispatch_mode_alert_h":"48"}}' > "$A/state/settings-cache.json"
age 25 LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW"
[ "$(nalert)" = 0 ] && ok || bad "D6 the settings row lib.dispatch-mode.dispatch_mode_alert_h=48 raises none at 25 h"

# ══ FASTPATH: the real script ══════════════════════════════════════════════
H="$T/h"; P=cromford
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$H/prompts" "$H/fixture" "$T/fakebin"
scratch_install_closure bin/launch-fastpath.sh "$H" >/dev/null || { echo "closure install of bin/launch-fastpath.sh failed"; exit 1; }
[ -e "$H/bin/jobs-client.sh" ] || scratch_install_closure bin/jobs-client.sh "$H" >/dev/null
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
printf 'cromford example-org/cromford https://bh.example - 9 box-bh 192.0.2.9\n' > "$H/fleet.conf"
printf '%s\n' '  `setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > /root/harness/logs/cromford.bh-<issue-number>-build.out 2>&1 &`' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret-fixture\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf 'argv=%s\n' "$*" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
A="$*"
PAGE=$(printf '%s' "$A" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$A" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*) [ "$PAGE" = 1 ] || SEND 200 '[]'; SEND 200 '[]' ;;
  *"/issues/"*)
    n=$(printf '%s' "$A" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(cat "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*) SEND 200 '[]' ;;
  *"/pulls"*)  SEND 200 '[]' ;;
  *"api repos/"*) echo 12345 ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
row() { jq -nc --arg n "$1" --arg v "$2" '{flag:{name:$n,scope:"fleet",value:(if $v == "" then null else $v end),set_at:"2026-10-13T00:00:00Z",cleared_at:null}}'; }
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  */api/flags/dispatch-mode-*)
    if [ -f "$HARNESS/fixture/dm-value" ]; then printf '%s\n200\n' "$(row "dispatch-mode-${URL##*/dispatch-mode-}" "$(cat "$HARNESS/fixture/dm-value")")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  */api/flags/paused-*)
    if [ -f "$HARNESS/fixture/paused" ]; then printf '%s\n200\n' "$(row "paused-${URL##*/paused-}" "")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"
chmod +x "$T/fakebin"/*
BODY=$'## Scope\nx\n\n## Acceptance tests\n- y\n'
mkissue() { # mkissue <n> <labels-json>
  jq -n --argjson n "$1" --argjson lb "$2" --arg b "$BODY" \
    '{number:$n,state:"open",title:("BH-\($n) fixture"),body:$b,labels:$lb,comments:0}' > "$H/fixture/issue-$1.json"
}
fpreset() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"
  mkdir -p "$H/state" "$H/locks" "$H/logs"
  rm -f "$H/launches.log" "$H/gh-calls.log" "$H/fixture/dm-value" "$H/fixture/paused"
  mkissue 901 '[{"name":"ai-build"},{"name":"hotfix"}]'
  mkissue 902 '[{"name":"ai-build"}]'
}
fp() { OUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 \
          bash "$H/bin/launch-fastpath.sh" "$P" "$@" 2>/dev/null); RC=$?; }
launched() { grep -qxF "argv=$P $1 BH-$1" "$H/launches.log" 2>/dev/null; }
reason() { grep -F "FASTPATH-DECLINED $1 ::" "$H/logs/$P.log" 2>/dev/null | tail -1 | sed 's/.*:: //'; }
ndm() { local n; n=$(grep -c 'DISPATCH-MODE hotfix-only' "$H/logs/$P.log" 2>/dev/null); echo "${n:-0}"; }
writes902() { grep -E 'issues/902' "$H/gh-calls.log" 2>/dev/null | grep -ciE -- '(-X|--method)[ =]?(POST|DELETE|PATCH|PUT)|/labels'; }

# D1
fpreset; printf 'hotfix-only' > "$H/fixture/dm-value"
fp BH-901 BH-902
launched 901 && ok || bad "D1 the hotfix BH-901 launches ($(reason BH-901))"
launched 902 && bad "D1 BH-902 (no hotfix label) must not launch" || ok
grep -qx 'BH-902' <<<"$OUT" && ok || bad "D1 BH-902 is on stdout as declined (stdout: $OUT)"
[ "$(ndm)" = 1 ] && ok || bad "D1 exactly ONE DISPATCH-MODE line per run (got $(ndm): $(cat "$H/logs/$P.log" 2>/dev/null))"
grep 'DISPATCH-MODE hotfix-only' "$H/logs/$P.log" 2>/dev/null | grep -q 'BH-902' && ok || bad "D1 the line names BH-902"
grep 'DISPATCH-MODE hotfix-only' "$H/logs/$P.log" 2>/dev/null | grep -q 'allow-list: none' && ok || bad "D1 the line names the allow-list"
grep -q 'FASTPATH-DECLINED BH-902' "$H/logs/$P.log" 2>/dev/null && bad "D1 no per-key decline line for a mode hold" || ok
[ "$(writes902)" = 0 ] && ok || bad "D1 no label or comment write on #902"
[ -e "$H/state/orphan-reconcile/$P/BH-902.enqueued" ] && bad "D1 no launch marker for BH-902" || ok
[ "$RC" = 1 ] && ok || bad "D1 rc 1 (a key declined), got $RC"

# D2
fpreset; printf 'hotfix-only:902' > "$H/fixture/dm-value"
fp BH-901 BH-902
launched 902 && ok || bad "D2 the allow-listed BH-902 launches ($(reason BH-902))"
launched 901 && ok || bad "D2 the hotfix still launches"
[ "$(ndm)" = 0 ] && ok || bad "D2 nothing waits, so no DISPATCH-MODE line"

# D4
fpreset; printf 'hotfix-only' > "$H/fixture/dm-value"; : > "$H/fixture/paused"
fp BH-901
launched 901 && bad "D4 paused: the hotfix does not launch" || ok
[ "$(reason BH-901)" = "project paused" ] && ok || bad "D4 the reason is the existing 'project paused' (got '$(reason BH-901)')"

# D5 + N1 at the entry point: the D1 tree, then the row cleared.
fpreset; printf 'hotfix-only' > "$H/fixture/dm-value"
fp BH-902
launched 902 && bad "D5 setup: BH-902 waits in hotfix-only" || ok
rm -f "$H/fixture/dm-value"; : > "$H/logs/$P.log"
fp BH-902
launched 902 && ok || bad "D5 back to normal: BH-902 launches on the next run ($(reason BH-902))"
[ "$(ndm)" = 0 ] && ok || bad "D5 no DISPATCH-MODE line in normal"
[ "$(writes902)" = 0 ] && ok || bad "D5 the labels on #902 were never written"

# ══ G. the run-build gate, lifted from the flattened pipeline ══════════════
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }
awk '/^# >>> dispatch mode gate/{f=1} f{print} /^# <<< dispatch mode gate/{exit}' "$RB_ALL" > "$T/dmgate.sh"
[ -s "$T/dmgate.sh" ] && ok || bad "G0 no '# >>> dispatch mode gate' block in the pipeline"
TG=$(grep -n '^# <<< tripwire paused skip' "$RB_ALL" | head -1 | cut -d: -f1)
DG=$(grep -n '^# >>> dispatch mode gate' "$RB_ALL" | head -1 | cut -d: -f1)
BG=$(grep -n '^# >>> budget launch gate' "$RB_ALL" | head -1 | cut -d: -f1)
FG=$(grep -n '^# >>> fly enqueue\|routing_builder "\$PROJECT"' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$DG" ] && [ -n "$TG" ] && [ -n "$BG" ] && [ "$TG" -lt "$DG" ] && [ "$DG" -lt "$BG" ] && ok \
  || bad "G0 the gate sits after the tripwire skip and before the budget gate (tw=$TG dm=$DG budget=$BG)"
[ -n "$DG" ] && [ -n "$FG" ] && [ "$DG" -lt "$FG" ] && ok || bad "G0 the gate sits before the Fly enqueue (dm=$DG fly=$FG)"
G="$T/g"; mkdir -p "$G/flags" "$G/logs" "$G/state" "$G/b"
scratch_install_closure bin/lib/dispatch-mode.sh "$G" >/dev/null
gate() { # gate <value|-> [env...] -> GRC, GRES
  local v="$1"; shift
  rm -f "$G/b/RESULT" "$G/flags/dispatch-mode-$P"
  [ "$v" = - ] || printf '%s' "$v" > "$G/flags/dispatch-mode-$P"
  ( export HARNESS="$G" PROJECT="$P" KEY=BH-902 TICKET=902 BUILD="$G/b" "$@"
    STAMP() { echo 2026-10-13T01:00:00Z; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    . "$T/dmgate.sh"; exit 0 ) >/dev/null 2>&1
  GRC=$?; GRES=$(cat "$G/b/RESULT" 2>/dev/null)
}
gate hotfix-only HOTFIX= HF_RC=1
[ "$GRC" = 3 ] && ok || bad "G1 rc 3 (got $GRC)"
case "$GRES" in "BUILD_DEFERRED dispatch mode hotfix-only: BH-902 waits"*) ok ;; *) bad "G1 RESULT is the BUILD_DEFERRED line (got '$GRES')" ;; esac
[ -e "$G/state/claims/$P/BH-902" ] && bad "G1 no claim file" || ok
grep -q 'dispatch mode hotfix-only' "$G/logs/$P.log" 2>/dev/null && ok || bad "G1 the hold is logged in logs/<p>.log"
gate hotfix-only HOTFIX= HF_RC=2
[ "$GRC" = 0 ] && [ -z "$GRES" ] && ok || bad "G2 an unknown label read admits (rc=$GRC res='$GRES')"
gate hotfix-only HOTFIX=1
[ "$GRC" = 0 ] && [ -z "$GRES" ] && ok || bad "G3 a hotfix admits (rc=$GRC res='$GRES')"
gate hotfix-only:902 HOTFIX= HF_RC=1
[ "$GRC" = 0 ] && [ -z "$GRES" ] && ok || bad "G3 an allow-listed ticket admits (rc=$GRC res='$GRES')"
gate - HOTFIX= HF_RC=1
[ "$GRC" = 0 ] && [ -z "$GRES" ] && ok || bad "N1 no row: the gate admits (rc=$GRC res='$GRES')"
gate hotfix-only HOTFIX= HF_RC=1 RESUME_BUILD="$G/b"
[ "$GRC" = 0 ] && [ -z "$GRES" ] && ok || bad "D3a a resumed build (fix round) passes (rc=$GRC res='$GRES')"
gate hotfix-only HOTFIX= HF_RC=1 BUILDER_EXEC=1
[ "$GRC" = 0 ] && [ -z "$GRES" ] && ok || bad "D3b a pool machine passes (rc=$GRC res='$GRES')"

# ══ POOL: the real bin/fly-pool.sh ═════════════════════════════════════════
Q="$T/pool"; PP=project-5
mkdir -p "$Q/bin" "$Q/logs" "$Q/flags" "$Q/locks" "$Q/env" "$Q/fly" "$Q/state/fly" "$Q/state/fly-pool/$PP" \
         "$Q/state/build-queue/$PP" "$Q/state/remote-results/$PP" "$Q/state/pool/$PP" "$Q/builds" "$T/qbin"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$Q/env/fly.env"
: > "$Q/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$Q/fleet.conf"
printf '3\n' > "$Q/flags/fly-pool-$PP"
printf 'pool-project-5\n' > "$Q/flags/fly-pool-app-$PP"
printf '{"app":"pool-project-5"}\n' > "$Q/state/fly/$PP.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$Q/state/fly/$PP.image"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$Q/bin/"
scratch_install_closure bin/fly-pool.sh "$Q" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$Q/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$Q/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/qbin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/qbin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/qbin/sleep"
cat > "$T/qbin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) cat "$T/fly-result" 2>/dev/null ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) n=\$(( \$(cat "$T/fly-n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/fly-n"; printf 'Machine ID: 1234567890a%03d\n' "\$n" ;;
esac
exit 0
FLY
cat > "$T/qbin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  if [[ "$*" == *"git/ref/heads/"* ]]; then printf 'HTTP/1.1 200 OK\n\n{}\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/"* ]]; then echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0; fi
exit 0
GH
chmod +x "$Q/bin"/*.sh "$T/qbin"/*
poolreset() {
  local p
  for p in "$Q/state/build-queue/$PP"/*.json "$Q/state/fly-pool/$PP"/*.json "$Q/state/pool/$PP"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  rm -f "$Q/flags/dispatch-mode-$PP" "$T/fly-calls" "$T/fly-result"
}
pooltick() {
  : > "$Q/logs/fly-pool.log"
  ( export PATH="$T/qbin:$PATH" HARNESS="$Q" FLEET_CONF="$Q/fleet.conf" FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/qbin"
    bash "$DIR/bin/fly-pool.sh" "$PP" >/dev/null 2>&1 )
}
spawned() { grep -lsh "\"key\": *\"$1\"" "$Q/state/fly-pool/$PP"/*.json >/dev/null 2>&1; }
queued() { [ -f "$Q/state/build-queue/$PP/$1.json" ]; }
plainjob() { jq -nc '{ticket_id:"904",key:"BH-904",attempt:0,deferrals:0,enqueued_at:"2026-10-13 00:00:00Z"}' > "$Q/state/build-queue/$PP/BH-904.json"; }

# P1
poolreset; plainjob; printf 'hotfix-only' > "$Q/flags/dispatch-mode-$PP"
pooltick
spawned BH-904 && bad "P1 hotfix-only: the plain BH-904 must not spawn" || ok
queued BH-904 && ok || bad "P1 the held job stays queued"
grep -q 'DISPATCH-MODE hotfix-only: held 1 queued job(s) (BH-904)' "$Q/logs/fly-pool.log" && ok \
  || bad "P1 one DISPATCH-MODE held line (log: $(grep -i 'dispatch\|spawn' "$Q/logs/fly-pool.log" | head -5))"
[ "$(grep -c 'DISPATCH-MODE' "$Q/logs/fly-pool.log")" = 1 ] && ok || bad "P1 exactly one line per tick"
# P2
poolreset; plainjob
pooltick
spawned BH-904 && ok || bad "P2 normal: BH-904 spawns (log: $(tail -5 "$Q/logs/fly-pool.log"))"
grep -q 'DISPATCH-MODE' "$Q/logs/fly-pool.log" && bad "P2 no DISPATCH-MODE line in normal" || ok
# D3c: a rebase job (an open PR's conductor rebase) spawns; the plain job waits.
poolreset; plainjob; printf 'hotfix-only' > "$Q/flags/dispatch-mode-$PP"
jq -nc '{ticket_id:"77",key:"RB-77-abc",attempt:0,deferrals:0,enqueued_at:"2026-10-13 00:00:00Z",source:"db",
         rebase:{kind:"rebase",slug:"example-org/project-5",url:"https://github.com/example-org/project-5/pull/77",pr:77,branch:"ticket/bh-903",head:"abc",base:"main"}}' \
  > "$Q/state/build-queue/$PP/RB-77-abc.json"
pooltick
spawned RB-77-abc && ok || bad "D3c the rebase job spawns in hotfix-only (log: $(tail -5 "$Q/logs/fly-pool.log"))"
spawned BH-904 && bad "D3c the plain job does not" || ok
# D3d: a blocked-resolver rebuild (job.json from the real queue_row_job_file) spawns.
poolreset; printf 'hotfix-only' > "$Q/flags/dispatch-mode-$PP"
( HARNESS="$Q"; . "$DIR/bin/lib/queue-row-job.sh"
  queue_row_job_file "$PP" "$Q/state/build-queue/$PP/BH-911.json" BH-911 911 0 '{"blocked_resolver":"red-ci"}' )
pooltick
spawned BH-911 && ok || bad "D3d the rebuild job spawns in hotfix-only (log: $(tail -5 "$Q/logs/fly-pool.log"))"

# D3e: the reuse handoff (next_job_or_destroy) applies the same filter. A
# reaped machine that deferred is handed the hotfix job, never the plain one.
reuse() { # reuse <queued-key> [hot|normal] -> the key on the reaped machine after the tick
  poolreset
  [ "${2:-}" = normal ] || printf 'hotfix-only' > "$Q/flags/dispatch-mode-$PP"
  printf 'BUILD_DEFERRED REFUSED box :: box max 1 already running\n' > "$T/fly-result"
  jq -nc '{machine:"m-reuse",key:"BH-1015",ticket_id:"1015",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-13T00:00:00Z"}' \
    > "$Q/state/fly-pool/$PP/m-reuse.json"
  jq -nc --arg k "$1" --arg t "${1#BH-}" --argjson h "$([ "${2:-}" = hot ] && echo true || echo false)" \
    '{ticket_id:$t,key:$k,attempt:0,deferrals:0,enqueued_at:"2026-10-13 00:00:00Z"} + (if $h then {hotfix:true} else {} end)' \
    > "$Q/state/build-queue/$PP/$1.json"
  : > "$Q/logs/fly-pool.log"
  ( export PATH="$T/qbin:$PATH" HARNESS="$Q" FLEET_CONF="$Q/fleet.conf" FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/qbin" POOL_SPAWN=0
    bash "$DIR/bin/fly-pool.sh" "$PP" >/dev/null 2>&1 )
  jq -r '.key // ""' "$Q/state/fly-pool/$PP/m-reuse.json" 2>/dev/null
}
RK=$(reuse BH-914 hot)
[ "$RK" = BH-914 ] && ok || bad "D3e control: a hotfix job is handed to the reaped machine in hotfix-only (got '$RK'; log: $(tail -4 "$Q/logs/fly-pool.log"))"
RK=$(reuse BH-904 normal)
[ "$RK" = BH-904 ] && ok || bad "D3e control: normal hands the plain job over (got '$RK')"
RK=$(reuse BH-904)
[ "$RK" != BH-904 ] && ok || bad "D3e hotfix-only: the plain job is not handed to the reaped machine"
queued BH-904 && ok || bad "D3e the plain job stays queued"

# ══ FLY-DISPATCH: the file pick and the rows pick regions ═════════════════
F="$T/disp"; mkdir -p "$F/q" "$F/h/flags" "$F/h/bin/lib" "$F/h/state/fly-pool/$P" "$F/st"
scratch_install_closure bin/lib/dispatch-mode.sh "$F/h" >/dev/null
scratch_install_closure bin/lib/hotfix-lib.sh "$F/h" >/dev/null
scratch_install_closure bin/lib/queue-row-job.sh "$F/h" >/dev/null
awk '/^  # >>> next job pick/{f=1;next} /^  # <<< next job pick/{exit} f' "$DIR/bin/fly-dispatch.sh" > "$F/pick.sh"
awk '/^  local next_job/{print; exit}' "$DIR/bin/fly-dispatch.sh" > "$F/decl.sh"
awk '/^  # >>> rows pick/{f=1;next} /^  # <<< rows pick/{exit} f' "$DIR/bin/fly-dispatch.sh" > "$F/rows.sh"
grep -q '^[[:space:]]*local[[:space:]]' "$F/pick.sh" && bad "F0 the pick region declares no \`local\`" || ok
pick() { ( set -uo pipefail; qdir="$F/q"; HARNESS="$F/h"; p="$P"; : > "$F/say.log"
           say() { echo "$2" >> "$F/say.log"; }
           . "$F/h/bin/lib/hotfix-lib.sh"; . "$F/h/bin/lib/dispatch-mode.sh"
           _pick() { . "$F/decl.sh"; . "$F/pick.sh"; basename "${next_job:-none}"; }
           _pick ) }
jq -nc '{key:"BH-904",ticket_id:"904"}' > "$F/q/BH-904.json"
jq -nc '{key:"BH-901",ticket_id:"901",hotfix:true}' > "$F/q/BH-901.json"
rm -f "$F/q/BH-901.json"; jq -nc '{key:"BH-912",ticket_id:"912",hotfix:true}' > "$F/q/BH-912.json"
printf 'hotfix-only' > "$F/h/flags/dispatch-mode-$P"
[ "$(pick)" = BH-912.json ] && ok || bad "F1 hotfix-only picks the hotfix job (got $(pick))"
rm -f "$F/q/BH-912.json"
[ "$(pick)" = none ] && ok || bad "F1 with only the plain job nothing is picked (got $(pick))"
[ "$(grep -c 'DISPATCH-MODE hotfix-only' "$F/say.log" 2>/dev/null)" = 1 ] && grep -q 'BH-904' "$F/say.log" && ok \
  || bad "F1 one skip line naming BH-904 ($(cat "$F/say.log" 2>/dev/null))"
[ -f "$F/q/BH-904.json" ] && ok || bad "F1 the plain job stays queued"
rm -f "$F/h/flags/dispatch-mode-$P"
[ "$(pick)" = BH-904.json ] && ok || bad "F1 normal picks the plain job (got $(pick))"
# F2: the rows pick (build_queue_rows_only) applies the same rule to rows.
rows() { ( set -uo pipefail; qdir="$F/q"; HARNESS="$F/h"; p="$P"; STATE_DIR="$F/st"; rows_only=1; hf_on=1; : > "$F/say.log"
           say() { echo "$2" >> "$F/say.log"; }
           . "$F/h/bin/lib/hotfix-lib.sh"; . "$F/h/bin/lib/dispatch-mode.sh"; . "$F/h/bin/lib/queue-row-job.sh"
           _rows() { local next_job="" rlist; DM_MODE=normal; dm_read "$p"
             rlist=$(printf 'r\tBH-904\t904\tx\tx\t0\tx\tx\tx\t{}\nr\tBH-913\t913\tx\tx\t0\tx\tx\tx\t%s\n' "$1")
             . "$F/rows.sh"; basename "${next_job:-none}"; }
           _rows "${1:-}" ) }
printf 'hotfix-only' > "$F/h/flags/dispatch-mode-$P"
[ "$(rows '{"hotfix":true}')" = BH-913.json ] && ok || bad "F2 rows pick in hotfix-only takes the hotfix row (got $(rows '{"hotfix":true}'))"
[ "$(rows '{}')" = none ] && ok || bad "F2 rows pick with two plain rows picks nothing (got $(rows '{}'))"
printf 'hotfix-only:904' > "$F/h/flags/dispatch-mode-$P"
[ "$(rows '{}')" = BH-904.json ] && ok || bad "F2 an allow-listed row is picked (got $(rows '{}'))"
rm -f "$F/h/flags/dispatch-mode-$P"
[ "$(rows '{}')" = BH-904.json ] && ok || bad "F2 normal picks the oldest row (got $(rows '{}'))"

# ══ TRIAGE: rt_dispatch_mode ═══════════════════════════════════════════════
R="$T/rt"; mkdir -p "$R/h/flags" "$R/h/logs" "$R/h/state"
scratch_install_closure bin/lib/dispatch-mode.sh "$R/h" >/dev/null
awk '/^# >>> dispatch mode \(BH-6350\)/{f=1} f{print} /^# <<< dispatch mode/{exit}' "$DIR/bin/lib/rt/gate.sh" > "$R/rt.sh"
[ -s "$R/rt.sh" ] && ok || bad "T0 no '# >>> dispatch mode (BH-6350)' block in bin/lib/rt/gate.sh"
awk '/^rt_pause_builds( |$)/{a=NR} /^rt_dispatch_mode( |$)/{b=NR} /^SHARD_SOP=/{c=NR} END{exit !(a && b && c && a<b && b<c)}' "$DIR/bin/run-triage.sh" \
  && ok || bad "T0 bin/run-triage.sh calls rt_dispatch_mode after rt_pause_builds and before SHARD_SOP"
tri() { ( export HARNESS="$R/h"; PROJECT="$P"; STAMP=2026-10-13T01:00:00Z; LOG="$R/h/logs/$P.log"; PROMPT_TEXT="SOP"
          . "$R/rt.sh"; rt_dispatch_mode >/dev/null 2>&1; printf '%s' "$PROMPT_TEXT" ) </dev/null; }
: > "$R/h/logs/$P.log"; printf 'hotfix-only:6291' > "$R/h/flags/dispatch-mode-$P"
PT=$(tri)
case "$PT" in *"DISPATCH MODE hotfix-only (BH-6350)"*"6291"*) ok ;; *) bad "T1 the directive is appended with the allow-list (got: $PT)" ;; esac
[ "$(grep -c 'DISPATCH-MODE hotfix-only' "$R/h/logs/$P.log")" = 1 ] && ok || bad "T1 one log line ($(cat "$R/h/logs/$P.log"))"
: > "$R/h/logs/$P.log"; rm -f "$R/h/flags/dispatch-mode-$P"
[ "$(tri)" = SOP ] && ok || bad "T2 normal appends nothing (got: $(tri))"
[ -s "$R/h/logs/$P.log" ] && bad "T2 normal logs nothing" || ok

# ══ Mission Control: the console sources and their node suite (D41) ════════
for f in "$DIR/console-ui/src/lib/dispatch-mode.js" "$DIR/console-ui/src/lib/flagrows.js" "$DIR/console-ui/src/screens/Fleet.js"; do
  [ -f "$f" ] && ok || bad "C0 missing $f"
done
if command -v node >/dev/null 2>&1 && [ -d "$DIR/console-ui/node_modules" ]; then
  ( cd "$DIR/console-ui" && node --test tests/dispatch-mode.bh-6350.test.js >/dev/null 2>&1 ) && ok || bad "C the console node suite failed"
else
  echo "skip: console-ui node suite (no node or no console-ui/node_modules)"
fi

echo "dispatch-hotfix-only.bh-6350: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
