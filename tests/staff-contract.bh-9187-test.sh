#!/bin/bash
# tests/staff-contract.bh-9187-test.sh — BH-9187 (C0): the staff agent
# contract on the box side. bin/lib/staff-contract.sh is driven directly
# (S1-S2, S9-S10); the level gate and the day cap are driven through the SHIPPED
# bin/staff.sh tick (S3-S8), and the tripwire count through the shipped
# bin/archie-overlook.sh (S3).
#
#   S1  staff_level: no row, an outage and a bad value print observe (rc 3);
#       ` FILE ` prints file (rc 0)
#   S2  staff_knob: a positive integer row is used; 0, -1, abc and no row use
#       the fallback
#   S3  three ticks on one item: ONE acted file; archie-overlook with a loop
#       limit of 2 does not trip (no staff-off-<agent> flag, no beat)
#   S4  level observe, model says `file a ticket`: 0 GitHub POSTs, one digest
#       line verdict=level, acted outcome digested, contract_level=observe
#   S5  level file, 3 acted `filed` files today: 0 GitHub POSTs, verdict=file-cap
#   S6  level file, 3 `filed` files yesterday and a digested one today: 1 POST
#   S7  a held filing at level observe, then at the day cap: no GitHub call,
#       the held file stays, no acted file, no digest line, one log line
#       `held filing <fp12> waits: contract level|file-cap` (r3)
#   S8  the S7 held file, next tick at level file with room: 1 POST, acted
#       outcome filed, the held file removed (r3)
#   S9  staff_filed_today counts only `filed` acted files in the UTC day
#   S10 staff_action_post / staff_metric_post pass the worker rc through
#
# MUTATIONS (D1), each tried once by hand against the shipped files: make
# staff_level accept any value -> S1 red; drop the level gate in staff.sh ->
# S4 red; compare the day count with -gt -> S5 red; count every outcome in
# staff_filed_today -> S6/S9 red; skip the gate on the held path -> S7 red;
# add rm -f "$hf" to the held refusal -> S7 red.
#
# The worker, gh and the model are stubs in the STAFF_FIXTURE file (sourced by
# bin/staff.sh after its libs, sandbox only). curl and gh on PATH log and fail.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-contract.bh-9187-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-contract: jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "staff-contract: node is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

LIB="$DIR/bin/lib/staff-contract.sh"
[ -r "$LIB" ] || bad "missing $LIB"

# A fixed clock: Fri 2026-11-06T12:00:00Z. Yesterday is 2026-11-05.
NOW_E=1793966400
TODAY=2026-11-06T09:00:00Z
YESTERDAY=2026-11-05T09:00:00Z

# ═════ S1, S2, S9, S10: the lib, with a stubbed setting_get ═══════════════════
lib_run() { # lib_run <bash snippet> — a subshell with the lib and the stubs
  (
    setting_get() { # $FXL/<key> holds the value; $FXL/<key>.rc an rc
      local f="$FXL/$1"
      [ -f "$f.rc" ] && return "$(cat "$f.rc")"
      [ -f "$f" ] || return 2
      cat "$f"
    }
    _jobs_req_file() { printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXL/req.log"; cat "$FXL/answer" 2>/dev/null; return "$(cat "$FXL/rc" 2>/dev/null || echo 0)"; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 99
    eval "$1"
  )
}
FXL="$T/fxl"; mkdir -p "$FXL"
lv() { # lv <value|--none|--rc N> -> "<printed> rc=<rc>"
  rm -f "$FXL"/staff.inspector.level*
  case "$1" in
    --none) ;;
    --rc) echo "$2" > "$FXL/staff.inspector.level.rc" ;;
    *) printf '%s' "$1" > "$FXL/staff.inspector.level" ;;
  esac
  FXL="$FXL" lib_run 'out=$(staff_level inspector); rc=$?; printf "%s rc=%s" "$out" "$rc"'
}
export FXL LIB
eq "S1 no row"         "$(lv --none)"    "observe rc=3"
eq "S1 outage"         "$(lv --rc 1)"    "observe rc=3"
eq "S1 observe row"    "$(lv observe)"   "observe rc=0"
eq "S1 padded FILE"    "$(lv ' FILE ')"  "file rc=0"
eq "S1 act"            "$(lv act)"       "act rc=0"
for v in files 'act;rm' '' automation 'fi le' 'File it'; do
  eq "S1 bad value [$v]" "$(lv "$v")" "observe rc=3"
done

kn() { # kn <value|--none> -> printed knob
  rm -f "$FXL"/staff.clerk.file_max_day*
  [ "$1" = --none ] || printf '%s' "$1" > "$FXL/staff.clerk.file_max_day"
  lib_run 'staff_knob clerk file_max_day 3'
}
eq "S2 row 5"   "$(kn 5)" 5
for v in 0 -1 abc '' 2.5 --none; do eq "S2 fallback [$v]" "$(kn "$v")" 3; done

SD="$T/s9/state"; mkdir -p "$SD/acted"
mk_acted() { # mk_acted <dir> <name> <outcome> <mtime ISO>
  jq -cn --arg o "$3" '{outcome: $o, class: "fixture", recommendation: "Fixture finding"}' > "$1/acted/$2.json"
  touch -d "$4" "$1/acted/$2.json"
}
mk_acted "$SD" t1 filed "$TODAY"; mk_acted "$SD" t2 filed "$TODAY"; mk_acted "$SD" t3 digested "$TODAY"
mk_acted "$SD" y1 filed "$YESTERDAY"
eq "S9 filed today" "$(lib_run "staff_filed_today '$SD' $NOW_E")" 2
eq "S9 no acted dir" "$(lib_run "staff_filed_today '$T/nowhere' $NOW_E")" 0

echo '{"ok":true}' > "$FXL/answer"; echo 0 > "$FXL/rc"
printf '{"agent":"inspector"}' > "$T/act.json"
lib_run "staff_action_post '$T/act.json' >/dev/null"; eq "S10 action rc 0" "$?" 0
grep -q '^POST /api/staff/levers/actions ' "$FXL/req.log" && ok || bad "S10: no POST /api/staff/levers/actions"
echo 2 > "$FXL/rc"
lib_run "staff_metric_post '$T/act.json' >/dev/null"; eq "S10 metric rc passed through" "$?" 2
grep -q '^POST /api/staff/levers/metric ' "$FXL/req.log" && ok || bad "S10: no POST /api/staff/levers/metric"

# ═════ the scratch harness for staff.sh and archie-overlook.sh ════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$T/fakebin"
for s in bin/staff.sh bin/jobs-client.sh bin/archie-overlook.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "scratch_install_closure $s failed"
done
cp "$DIR/bin/staff-core.mjs" "$H/bin/"
cp -r "$DIR/agent-core" "$H/agent-core"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp "$DIR/catalog/prompts/staff-tick.md" "$H/catalog/prompts/" 2>/dev/null
cp -r "$DIR/prompts/staff" "$H/prompts/" 2>/dev/null
: > "$H/env/global.env"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${STAFF_AGENT:-}" >> "$FXT/ac.log"
pf="${6#@}"
printf '{"type":"result","subtype":"success","total_cost_usd":0.1}' > "$5.json"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture finding title", body: "Seen at the fixture source."}]}' > "$5"
exit 0
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/beats.log"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
mkdir -p "$H/bin/staff"
printf '#!/bin/bash\ncat "$FXT/items.jsonl" 2>/dev/null\n' > "$H/bin/staff/inspector-collect.sh"
chmod +x "$H/bin/staff/inspector-collect.sh"

# The fixture. The claim keeps the worker's one-row-per-fingerprint rule: the
# first claim is 200, every later one 409 already_claimed with the status the
# last record set. The level row is $FXT/level (absent = no row, rc 2).
cat > "$T/fx.sh" <<'SH'
fx_fp() { printf '%s' "$1" | sha256sum | cut -c1-64; }
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name="*)
      jq -cn --arg n "${2#*name=}" '{agent: {name: $n, role: "x", autonomy: "augmentation", cap: "augmentation",
        status: "active", soul: ("prompts/staff/" + $n + "-soul.md"), lanes: []}}'; return 0 ;;
    "GET /api/staff/agents") cat "$FXT/agents.json"; return 0 ;;
    "GET /api/settings/staff.inspector.level")
      [ -f "$FXT/level" ] || return 2
      jq -cn --arg v "$(cat "$FXT/level")" '{setting: {key: "staff.inspector.level", value: $v}}'; return 0 ;;
    "GET /api/settings/"*) return 2 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  local id fp st
  case "$2" in
    /api/staff/findings/claim)
      id=$(jq -r .item.id "$3"); fp=$(fx_fp "$id"); mkdir -p "$FXT/claims"
      if [ -f "$FXT/claims/$fp" ]; then
        st=$(cat "$FXT/claims/$fp")
        printf '{"claimed":false,"error":"already_claimed","fingerprint":"%s","finding":{"id":1,"agent":"inspector","status":"%s"}}' "$fp" "$st"
        return 9
      fi
      echo claimed > "$FXT/claims/$fp"
      printf '{"claimed":true,"fingerprint":"%s","finding":{"id":1,"agent":"inspector","status":"claimed"}}' "$fp"; return 0 ;;
    /api/staff/findings/record)
      jq -r .outcome "$3" > "$FXT/claims/$(jq -r .fingerprint "$3")"
      printf '{"ok":true}'; return 0 ;;
    /api/staff/chat/take) printf '{"notes":[],"failed":[]}'; return 0 ;;
  esac
  return 1
}
job_ledger_get() { [ -f "$FXT/ledger/$1__$2" ] || return 2; head -1 "$FXT/ledger/$1__$2"; }
job_ledger_put() { mkdir -p "$FXT/ledger"; printf '%s\n' "$3" > "$FXT/ledger/$1__$2"; }
flag_active() { [ -e "$HARNESS/flags/$1" ]; }
flag_set() { printf 'FLAGSET %s\n' "$*" >> "$FXT/flags.log"; mkdir -p "$HARNESS/flags"; : > "$HARNESS/flags/$1"; }
gh_rest() {
  local m=$1 p=$2; shift 2
  printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"
  GH_REST_STATUS=$(cat "$FXT/create.status" 2>/dev/null || echo 201)
  case "$GH_REST_STATUS" in 2*) ;; *) return 75 ;; esac
  printf '{"number":7,"html_url":"https://github.com/example-org/cromford/issues/7"}\n'
}
gh_rest_issue_list() { printf 'LIST %s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/gh.log"; GH_REST_STATUS=200; echo '[]'; }
lane_role_model() { printf 'stub-model\n'; }
SH

item() { jq -cn --arg id "$1" '{item: {id: $id}, title: ("Fixture finding " + $id),
  source: {kind: "fixture", url: ("https://example.com/fx/" + $id), labels: []}, observedAt: "2026-11-06T00:00:00Z"}'; }
fp() { printf '%s' "$1" | sha256sum | cut -c1-64; }
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT" "$T/net.log"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/claims" "$H/flags" "$H/logs" "$H/state/staff/inspector/acted"
  : > "$FXT/req.log"; : > "$FXT/gh.log"; : > "$FXT/beats.log"; : > "$FXT/ac.log"
  jq -cn '{agents: [{name: "inspector", role: "x", accountable: "operator@example.com", status: "active"}]}' > "$FXT/agents.json"
}
tick() {
  env HARNESS="$H" FXT="$FXT" STAFF_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 STAFF_NOW="$NOW_E" \
    LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= PATH="$T/fakebin:$PATH" \
    bash "$H/bin/staff.sh" tick inspector >"$T/tick.txt" 2>&1
}
ov() {
  env HARNESS="$H" FXT="$FXT" ARCHIE_OVERLOOK_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 JOBS_URL= ARCHIE_NOW="$NOW_E" STAFF_OVERLOOK_FAMILY_MAX=2 STAFF_OVERLOOK_REPORT_DOW=7 \
    PATH="$T/fakebin:$PATH" bash "$H/bin/archie-overlook.sh" >"$T/ov.txt" 2>&1
}
posts() { grep -c '^POST repos/' "$FXT/gh.log"; }
ghcalls() { lines "$FXT/gh.log"; }
digests() { local n; n=$(grep -c "verdict=$1 " "$H/logs/staff-digest.log" 2>/dev/null); echo "${n:-0}"; }
acted_n() { find "$H/state/staff/inspector/acted" -maxdepth 1 -name '*.json' | grep -c .; }
outcome() { jq -r .outcome "$H/state/staff/inspector/acted/$(fp "$1").json" 2>/dev/null; }
# The ticks write acted files at the real time: move them into the fixed day.
pin_acted() { find "$H/state/staff/inspector/acted" -maxdepth 1 -name '*.json' -exec touch -d "$TODAY" {} +; }

# ═════ S3: three ticks on one item, one acted file, no trip ═══════════════════
reset; echo file > "$FXT/level"; item s3 > "$FXT/items.jsonl"
tick; tick; tick
eq "S3 claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 3
eq "S3 model calls" "$(lines "$FXT/ac.log")" 1
eq "S3 acted files" "$(acted_n)" 1
eq "S3 one issue" "$(posts)" 1
pin_acted; ov
[ -e "$H/flags/staff-off-inspector" ] && bad "S3: the overlook paused inspector on a repeated item" || ok
eq "S3 beats" "$(lines "$FXT/beats.log")" 0
# The negative control: two different items in one family DO trip at limit 2.
item s3b > "$FXT/items.jsonl"; tick; pin_acted; ov
[ -e "$H/flags/staff-off-inspector" ] && ok || bad "S3 control: two items in one family did not trip the loop wire ($(cat "$T/ov.txt"))"

# ═════ S4: level observe files nothing ════════════════════════════════════════
for L in observe --none; do
  reset; [ "$L" = --none ] || echo "$L" > "$FXT/level"; item s4 > "$FXT/items.jsonl"
  tick
  eq "S4[$L] model calls" "$(lines "$FXT/ac.log")" 1
  eq "S4[$L] GitHub calls" "$(ghcalls)" 0
  eq "S4[$L] digest verdict=level" "$(digests level)" 1
  eq "S4[$L] outcome" "$(outcome s4)" digested
  grep -q 'contract_level=observe' "$H/logs/staff.log" && ok || bad "S4[$L]: no contract_level=observe in the summary: $(tail -2 "$H/logs/staff.log")"
done

# ═════ S5: the day cap ════════════════════════════════════════════════════════
reset; echo file > "$FXT/level"; item s5 > "$FXT/items.jsonl"
for i in 1 2 3; do mk_acted "$H/state/staff/inspector" "f$i" filed "$TODAY"; done
tick
eq "S5 GitHub POSTs" "$(posts)" 0
eq "S5 digest verdict=file-cap" "$(digests file-cap)" 1
eq "S5 outcome" "$(outcome s5)" digested
# Two filed today with the cap 3: the first item files, the second meets the cap.
reset; echo file > "$FXT/level"; { item s5a; item s5b; } > "$FXT/items.jsonl"
for i in 1 2; do mk_acted "$H/state/staff/inspector" "f$i" filed "$TODAY"; done
tick
eq "S5 2 of 3: POSTs" "$(posts)" 1
eq "S5 2 of 3: capped" "$(digests file-cap)" 1

# ═════ S6: yesterday's filings and today's digests do not count ══════════════
reset; echo act > "$FXT/level"; item s6 > "$FXT/items.jsonl"
for i in 1 2 3; do mk_acted "$H/state/staff/inspector" "y$i" filed "$YESTERDAY"; done
mk_acted "$H/state/staff/inspector" d1 digested "$TODAY"
mk_acted "$H/state/staff/inspector" d2 digested "$TODAY"
mk_acted "$H/state/staff/inspector" d3 digested "$TODAY"
tick
eq "S6 GitHub POSTs" "$(posts)" 1
eq "S6 outcome" "$(outcome s6)" filed

# ═════ S7: a held filing the gate stops STAYS held (r3) ══════════════════════
# The held retry is a check only: no GitHub call, no acted file, no digest
# line, no state write. The held file is the record until the gate allows it.
hold_s7() { # a refused filing at level file leaves a held file
  reset; echo file > "$FXT/level"; item s7 > "$FXT/items.jsonl"
  echo 502 > "$FXT/create.status"
  tick
  [ -s "$H/state/staff/inspector/held/$F7.json" ] && ok || bad "S7 setup: the refused filing was not held"
  rm -f "$FXT/create.status"; : > "$FXT/gh.log"; : > "$FXT/ac.log"; : > "$H/logs/staff-digest.log"
}
F7=$(fp s7)
held_waits() { # held_waits <tag> <want reason>
  eq "S7[$1] GitHub calls" "$(ghcalls)" 0
  eq "S7[$1] model calls" "$(lines "$FXT/ac.log")" 0
  [ -s "$H/state/staff/inspector/held/$F7.json" ] && ok || bad "S7[$1]: the held file is gone"
  [ -e "$H/state/staff/inspector/acted/$F7.json" ] && bad "S7[$1]: an acted file was written for the held filing" || ok
  eq "S7[$1] digest lines" "$(lines "$H/logs/staff-digest.log")" 0
  grep -q "held filing ${F7:0:12} waits: contract $2" "$H/logs/staff.log" && ok \
    || bad "S7[$1]: no 'held filing ${F7:0:12} waits: contract $2' in the log: $(tail -3 "$H/logs/staff.log")"
  grep -q 'held=1 ' "$H/logs/staff.log" && ok || bad "S7[$1]: the summary does not count the held filing"
}
hold_s7; echo observe > "$FXT/level"; : > "$H/logs/staff.log"
tick; held_waits observe level
hold_s7; for i in 1 2 3; do mk_acted "$H/state/staff/inspector" "c$i" filed "$TODAY"; done
: > "$H/logs/staff.log"; tick; held_waits cap file-cap

# ═════ S8: the S7 held file files on a later tick with level file and room ═══
rm -f "$H"/state/staff/inspector/acted/c?.json; : > "$H/logs/staff.log"
tick
eq "S8 GitHub POSTs" "$(posts)" 1
eq "S8 model calls" "$(lines "$FXT/ac.log")" 0
eq "S8 outcome" "$(outcome s7)" filed
[ -e "$H/state/staff/inspector/held/$F7.json" ] && bad "S8: the held file is still there after the filing" || ok

[ -s "$T/net.log" ] && bad "a stub reached curl or gh: $(cat "$T/net.log")"
echo "staff-contract.bh-9187: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
