#!/bin/bash
# tests/unblock-contract.bh-7722-test.sh — BH-7722 (UNB-0): the unblock lane's
# contract, driven through the SHIPPED entry point bin/unblock.sh tick, plus
# the catalog files the lane reads.
#
#   C1   staff-kill-tackler / staff-kill-all: rc 0, `killed by`, 0 reads;
#        staff-kill-watchman (another agent) runs
#   C2   lane-off-unblock (the lane gate): 0 reads; C2b staff-off-tackler file
#        the same; staff-off-tackler-x runs
#   C3   unblock.enabled=0 and an unreadable row: 0 collector calls; absent runs
#   C4   the project mode table, read through bin/lib/unblock/scope.sh (the
#        settings cache): shadow, act, " shadow" run; missing, off, Shadow,
#        ACT, 1, actx and no settings cache never call a collector. With no
#        --project the tick runs each project unb_scope_projects lists;
#        --project <p> with mode off is one `mode off` line
#   C5   the collector line filter (non-JSON, an array, the tackler marker, a
#        staff: label) and the record cap; kept records reach ub_rules_eval;
#        the claim evidence is redacted and cut to 8 KB. C5q a quote-heavy
#        record: the evidence is cut by its ENCODED size, the claim body is at
#        most 8192 bytes; a 2 KB record goes through uncut
#   C6   a decision whose seam is not loaded is deferred with 0 claims
#   C7   a second tick over the same fixture: 409 on every claim, 0 seam calls,
#        0 records
#   C8   3 judge decisions and no model route: 3 claims (each before the route
#        read), 3 no-route records naming unblock.judge, 0 judge calls, 1 alert
#   C9   no collector: one log line ending `0 collectors, 0 rows`, 0 ledger
#        calls; one wired collector: collectors=1; C9b an act decision records
#        ub_act's outcome (would)
#   C10  the soul passes bin/staff-core.mjs and its NEVER block refuses merges
#   C11  _cites.json holds G1..G21; every rule file's cite is a key
#   C12  _schema.json's required list; C12b no `--source human` in the lane
#   C13  a seam that answers model_calls 1.0, 1.5 or "1": the record body
#        carries the integer 1 (the route refuses anything else)
#   B    budget (BH-7563): 0 curl calls and 0 gh calls in every case
#
# STUBS. The jobs API, the settings reads, the model route, the rules engine,
# the stage seams and ub_act are functions in the UNBLOCK_FIXTURE file, which
# bin/unblock.sh sources after its libs (sandbox only). Each call is one line
# in $FXT/seq.log. curl and gh on PATH log and exit 7. bin/lane-alert.sh is a
# stub that logs. The kill flags and the lane switch are the REAL libs over
# files in $H/flags (LANE_GATE_DISABLE=1); the lane gate itself is a fixture
# function, so C2 proves the call and its place in the order.
#
# MUTATIONS (D1), each tried once by hand against bin/unblock.sh: drop the 409
# stop -> C7 red; move the claim after the route read -> C8 red; drop the
# staff-kill-tackler check -> C1 red; drop the marker filter -> C5 red;
# measure the evidence before encoding -> C5q red; pass model_calls through
# uncoerced -> C13 red; a fixed project list -> C4 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-contract.bh-7722-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { grep -qF -- "$3" "$2" 2>/dev/null && ok || bad "$1: [$3] not in $2: $(head -c 800 "$2" 2>/dev/null)"; }
hasnt() { grep -qF -- "$3" "$2" 2>/dev/null && bad "$1: [$3] in $2" || ok; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

for SRC in bin/unblock.sh bin/lib/unblock/collect.sh bin/lib/unblock/scope.sh bin/lib/unblock/act.sh \
           catalog/lanes.d/unblock.json cron/lanes/417-unblock.cron prompts/staff/tackler-soul.md \
           catalog/unblock-rules.d/_cites.json catalog/unblock-rules.d/_schema.json \
           catalog/context-budgets.d/7722-unblock.json; do
  [ -e "$REPO/$SRC" ] || bad "missing $SRC"
done
if [ ! -r "$REPO/bin/unblock.sh" ] || [ ! -r "$REPO/bin/lib/unblock/collect.sh" ]; then
  echo "unblock-contract.bh-7722: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"; FB="$T/fakebin"; COL="$T/collectors"
mkdir -p "$H/bin" "$H/env" "$FB" || exit 1
: > "$H/env/global.env"
printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\nproject-3 example-org/project-3 - - 4 hub 192.0.2.11\n' > "$H/fleet.conf"
for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$S" "$H" ) >/dev/null || { echo "setup: closure $S"; exit 1; }
done
[ -f "$H/bin/lib/unblock/collect.sh" ] || bad "setup: the closure lacks bin/lib/unblock/collect.sh"
[ -f "$H/bin/lib/unblock/act.sh" ] || bad "setup: the closure lacks bin/lib/unblock/act.sh"
[ -f "$H/bin/lib/unblock/scope.sh" ] || bad "setup: the closure lacks bin/lib/unblock/scope.sh"
rm -f "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "ALERT %%s\\n" "$*" >> "$FXT/seq.log"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$FB/$b"
  chmod +x "$FB/$b"
done

# The fixture. $FXT/settings/<key> holds a row; $FXT/settings/<key>.fail makes
# it unreadable. $FXT/seen/<key> is a claimed key (the next claim is a 409).
cat > "$T/fx.sh" <<'SH'
seq_log() { printf '%s\n' "$*" >> "$FXT/seq.log"; }
setting_get() {
  seq_log "SETTING $1"
  [ -f "$FXT/settings/$1.fail" ] && return 1
  [ -f "$FXT/settings/$1" ] || return 2
  cat "$FXT/settings/$1"
}
lane_gate_or_exit() { seq_log "GATE $*"; [ -f "$FXT/lane-off" ] && exit 0; return 0; }
lane_env_apply() { seq_log "ENV $*"; return 0; }
_jobs_req() {
  local k n
  seq_log "JOBS $1 $2 ${3:-}"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      [ -f "$FXT/claim.rc" ] && return "$(cat "$FXT/claim.rc")"
      k=$(jq -r .decision_key <<<"$3"); mkdir -p "$FXT/seen"
      if [ -f "$FXT/seen/$k" ]; then printf '{"claimed":false,"id":%s,"outcome":"would","decision":"act"}' "$(cat "$FXT/seen/$k")"; return 9; fi
      n=$(( $(cat "$FXT/id.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/id.n"; echo "$n" > "$FXT/seen/$k"
      printf '{"claimed":true,"id":%s}' "$n"; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
lane_role_model() { seq_log "ROUTE $*"; [ -f "$FXT/route.rc" ] && return "$(cat "$FXT/route.rc")"; printf 'model-fixture\n'; }
if [ -f "$FXT/rules" ]; then
  ub_rules_eval() { cat > "$FXT/rules-in.jsonl"; seq_log "RULES $(grep -c . "$FXT/rules-in.jsonl")"; cat "$FXT/decisions.jsonl" 2>/dev/null; }
fi
# no-judge: bin/unblock.sh loads the real seam from judge.sh (BH-7724); the
# case for "seam not loaded" unloads it.
[ -f "$FXT/no-judge" ] && unset -f ubt_stage_judge
if [ -f "$FXT/seam-judge" ]; then
  ubt_stage_judge() { seq_log "JUDGE $(jq -r .decision_key <<<"$1") $2"; printf '{"outcome":"would","detail":"judge-fixture","model_calls":%s,"cost_usd":0.02}\n' "$(cat "$FXT/judge-calls" 2>/dev/null || echo 1)"; }
fi
# no-card: the shipped card.sh defines ubt_stage_card (BH-8418) and the tick's
# seam loop loads it from the closure, so a card-absent case unsets it.
[ -f "$FXT/no-card" ] && unset -f ubt_stage_card
if [ -f "$FXT/seam-card" ]; then
  ubt_stage_card() { seq_log "CARD $(jq -r .decision_key <<<"$1") $2"; printf '{"outcome":"escalated","detail":"card-fixture","model_calls":1,"cost_usd":0.03,"card":{"id":"u-abc123","options":["a","b"]}}\n'; }
fi
if [ -f "$FXT/act-stub" ]; then
  ub_act() { seq_log "ACT $(jq -c . <<<"$1")"; UB_ACT_OUTCOME=$(cat "$FXT/act-stub"); UB_ACT_DETAIL=WOULD_REQUEUE; printf '%s\t%s\n' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL"; return 0; }
elif [ -f "$FXT/no-act" ]; then
  unset -f ub_act
fi
SH

# The mode rows are read by bin/lib/unblock/scope.sh from the settings cache
# (state/settings-cache.json, the shape _lg_settings_refresh writes), fresh at
# the pinned clock NOW, so no GET /api/settings is made.
NOW=1790000000
# modes [<project>=<value> ...] — the cache holds exactly these mode rows.
modes() {
  local kv args=()
  for kv in "$@"; do args+=("unblock.project.${kv%%=*}.mode" "${kv#*=}"); done
  mkdir -p "$H/state"
  jq -nc --argjson fa "$NOW" '$ARGS.positional as $a
    | {fetched_at: $fa, values: (reduce range(0; $a | length; 2) as $i ({}; .[$a[$i]] = $a[$i + 1])), seeded: {}}' \
    --args "${args[@]}" > "$H/state/settings-cache.json"
}
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT" "$COL" "$T/net.log"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/settings" "$H/flags" "$COL"
  : > "$FXT/seq.log"
  echo 1 > "$FXT/settings/unblock.enabled"
  modes cromford=shadow
}
# collector <family> <file-of-lines>: a wired collector that prints the file.
collector() {
  local fam="$1" fn="${1//-/_}"
  cat > "$COL/$fam.sh" <<SH
ub_collect_$fn() { printf 'COLLECT $fam %s %s\n' "\$1" "\$2" >> "\$FXT/seq.log"; cat "\$FXT/lines-$fam" 2>/dev/null; }
SH
  [ -n "${2:-}" ] && cp "$2" "$FXT/lines-$fam"
  return 0
}
rec() { jq -cn --arg id "$1" '{id: $id, kind: "pr-ejected", pr: 7617, head: ("b" * 40), labels: []}'; }
dec() { # dec <key> <decision> [judge|nojudge]
  jq -cn --arg k "$1" --arg d "$2" --arg j "${3:-nojudge}" '{decision_key: $k, project: "cromford",
    repo: "example-org/cromford", subject_kind: "pr", subject: "example-org/cromford#7617", pr: 7617,
    head: ("b" * 40), stall_class: "pr-ejected", rule_id: (if $d == "escalate" then null else "U2-bystander-requeue" end),
    cites: ["G1", "G12"], class: "queue-requeue", decision: $d,
    action: (if $d == "act" then {name: "requeue", args: {}} else null end),
    judge: (if $j == "judge" then {prompt: "catalog/prompts/unblock-judge.md", question: "weakened?"} else null end),
    evidence: {pr: 7617}}'
}
tick() { # tick [args...] — the shipped entry point, sandboxed
  env HARNESS="$H" FXT="$FXT" UNBLOCK_FIXTURE="$T/fx.sh" UNBLOCK_COLLECTORS_DIR="$COL" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$FB:$PATH" \
    ${UNBLOCK_MAX_RECORDS:+UNBLOCK_MAX_RECORDS=$UNBLOCK_MAX_RECORDS} \
    bash "$H/bin/unblock.sh" tick "$@" >"$T/out.txt" 2>&1
}
LOG="$H/logs/unblock.log"
collects() { cnt '^COLLECT ' "$FXT/seq.log"; }
ledger() { cnt '^JOBS [A-Z]* /api/unblock' "$FXT/seq.log"; }
claims() { cnt '^JOBS POST /api/unblock/decisions/claim' "$FXT/seq.log"; }
records() { grep '^JOBS POST /api/unblock/decisions/record ' "$FXT/seq.log" | sed 's/^JOBS POST [^ ]* //'; }
nrecords() { cnt '^JOBS POST /api/unblock/decisions/record' "$FXT/seq.log"; }
budget() { # B: never a real vendor
  eq "$1 B curl/gh calls" "$( [ -f "$T/net.log" ] && grep -c . "$T/net.log" || echo 0)" 0
}

# ═════ C1: kill flags before any read ════════════════════════════════════════
for F in staff-kill-tackler staff-kill-all; do
  reset; rec a > "$T/one.jsonl"; collector queue "$T/one.jsonl"; touch "$H/flags/$F"
  tick; rc=$?
  eq "C1 $F rc" "$rc" 0
  has "C1 $F log" "$LOG" "killed by $F"
  eq "C1 $F collector calls" "$(collects)" 0
  eq "C1 $F ledger calls" "$(ledger)" 0
  eq "C1 $F settings reads" "$(cnt '^SETTING ' "$FXT/seq.log")" 0
  eq "C1 $F lane gate not reached" "$(cnt '^GATE ' "$FXT/seq.log")" 0
  budget "C1 $F"
done
reset; rec a > "$T/one.jsonl"; collector queue "$T/one.jsonl"; touch "$H/flags/staff-kill-watchman"
tick; eq "C1 near miss staff-kill-watchman rc" "$?" 0
eq "C1 near miss staff-kill-watchman runs the collector" "$(collects)" 1

# ═════ C2: the lane gate and the staff-off switch ════════════════════════════
reset; collector queue "$T/one.jsonl"; touch "$FXT/lane-off"
tick; eq "C2 lane-off rc" "$?" 0
eq "C2 the gate is asked for lane unblock" "$(grep -m1 '^GATE ' "$FXT/seq.log")" "GATE unblock"
eq "C2 lane-off collector calls" "$(collects)" 0
eq "C2 lane-off ledger calls" "$(ledger)" 0
eq "C2 lane-off settings reads" "$(cnt '^SETTING ' "$FXT/seq.log")" 0
reset; collector queue "$T/one.jsonl"; touch "$H/flags/staff-off-tackler"
tick; eq "C2b staff-off-tackler rc" "$?" 0
has "C2b staff-off-tackler log" "$LOG" "killed by staff-off-tackler"
eq "C2b staff-off-tackler collector calls" "$(collects)" 0
eq "C2b staff-off-tackler gate not reached" "$(cnt '^GATE ' "$FXT/seq.log")" 0
reset; collector queue "$T/one.jsonl"; touch "$H/flags/staff-off-tackler-x"
tick; eq "C2b near miss staff-off-tackler-x runs" "$(collects)" 1

# ═════ C3: the unblock.enabled row ═══════════════════════════════════════════
reset; collector queue "$T/one.jsonl"; echo 0 > "$FXT/settings/unblock.enabled"
tick; eq "C3 enabled=0 rc" "$?" 0
eq "C3 enabled=0 collector calls" "$(collects)" 0
eq "C3 enabled=0 ledger calls" "$(ledger)" 0
has "C3 enabled=0 log" "$LOG" "unblock.enabled=0"
reset; collector queue "$T/one.jsonl"; touch "$FXT/settings/unblock.enabled.fail"
tick; eq "C3 unreadable rc" "$?" 0
eq "C3 unreadable collector calls" "$(collects)" 0
has "C3 unreadable log" "$LOG" "unblock.enabled unreadable"
reset; collector queue "$T/one.jsonl"; rm -f "$FXT/settings/unblock.enabled"
tick; eq "C3 absent row runs" "$(collects)" 1

# ═════ C4: the project mode row (scope.sh) and the project list ══════════════
for M in shadow act ' shadow'; do
  reset; collector queue "$T/one.jsonl"; modes "cromford=$M"
  tick; eq "C4 mode [$M] runs" "$(collects)" 1
done
for M in missing off Shadow ACT 1 actx nocache; do
  reset; collector queue "$T/one.jsonl"
  case "$M" in
    missing) modes ;;
    nocache) rm -f "$H/state/settings-cache.json" ;;
    *) modes "cromford=$M" ;;
  esac
  tick; eq "C4 mode [$M] rc" "$?" 0
  eq "C4 mode [$M] no collector" "$(collects)" 0
  eq "C4 mode [$M] no ledger call" "$(ledger)" 0
done
reset; collector queue "$T/one.jsonl"; modes cromford=off
tick --project cromford; has "C4 --project with mode off is one line" "$LOG" "cromford mode off"
eq "C4 --project with mode off: no collector" "$(collects)" 0
reset; collector queue "$T/one.jsonl"; modes cromford=off project-3=act
tick
eq "C4 no --project runs the listed project only" "$(grep '^COLLECT ' "$FXT/seq.log" | cut -d' ' -f3 | tr '\n' ' ')" "project-3 "
has "C4 the listed project's mode is the summary's" "$LOG" "tick project-3 mode=act"
reset; collector queue "$T/one.jsonl"; modes cromford=shadow project-3=act
tick
eq "C4 no --project runs both listed projects" "$(grep '^COLLECT ' "$FXT/seq.log" | cut -d' ' -f3 | sort | tr '\n' ' ')" "cromford project-3 "
reset; collector queue "$T/one.jsonl"; modes cromford=shadow project-3=act
tick --project project-3
eq "C4 --project picks one project" "$(grep '^COLLECT ' "$FXT/seq.log" | cut -d' ' -f3 | tr '\n' ' ')" "project-3 "
# the lock is scope.sh's: a held locks/unblock-cromford.lock skips it
reset; collector queue "$T/one.jsonl"; mkdir -p "$H/locks"
exec 8>"$H/locks/unblock-cromford.lock"; flock -n 8
tick; eq "C4 lock held: no collector" "$(collects)" 0
has "C4 lock held is one line" "$LOG" "lock held"
exec 8>&-

# ═════ C5: the collector line filter, the record cap, the evidence ═══════════
reset; touch "$FXT/rules"
{
  rec keep-1
  echo 'not json at all'
  echo '[1,2]'
  jq -cn '{id: "own", kind: "pr-ejected", nested: {body: "done <!-- tackler:abc123 --> here"}}'
  jq -cn '{id: "lab-1", kind: "pr-ejected", labels: [" Staff:x"]}'
  jq -cn '{id: "lab-2", kind: "pr-ejected", labels: [{name: "STAFF:y"}]}'
  jq -cn '{id: "keep-2", kind: "pr-ejected", labels: ["staffing"]}'
} > "$T/mixed.jsonl"
collector queue "$T/mixed.jsonl"
tick; eq "C5 rc" "$?" 0
eq "C5 kept ids reach ub_rules_eval" "$(jq -r .id "$FXT/rules-in.jsonl" 2>/dev/null | tr '\n' ' ')" "keep-1 keep-2 "
has "C5 the drop counts are logged" "$LOG" "dropped bad=2 own=3"
reset; touch "$FXT/rules"
for i in $(seq 1 12); do rec "r-$i"; done > "$T/twelve.jsonl"
collector queue "$T/twelve.jsonl"
UNBLOCK_MAX_RECORDS=10 tick
eq "C5 the cap keeps 10 records" "$(grep -c . "$FXT/rules-in.jsonl")" 10
has "C5 the cut is logged" "$LOG" "truncated=2"
grep -q 'UNBLOCK_MAX_RECORDS:-200' "$REPO/bin/unblock.sh" && ok || bad "C5 the record cap default is 200 in bin/unblock.sh"
# the evidence: a token shape is redacted, a big record is cut to 8 KB
reset; touch "$FXT/rules" "$FXT/act-stub"; echo would > "$FXT/act-stub"
collector queue "$T/one.jsonl"
jq -c '.evidence = {pr: 7617, note: "token ghp_fixture0000000000000000000000000000000 here", blob: ("x" * 9000)}' <<<"$(dec ev-1 act)" > "$FXT/decisions.jsonl"
tick
CL=$(grep '^JOBS POST /api/unblock/decisions/claim ' "$FXT/seq.log" | sed 's/^JOBS POST [^ ]* //')
eq "C5 evidence cut flag" "$(jq -r .evidence.truncated <<<"$CL" 2>/dev/null)" true
eq "C5 evidence at most 8 KB" "$(jq -r '(.evidence | tojson | length) <= 8192' <<<"$CL" 2>/dev/null)" true
case "$CL" in *ghp_fixture*) bad "C5 the token shape reached the claim body" ;; *) ok ;; esac
# C5q: a 20 KB record, 30% of it quotes. Each quote is 2 bytes once encoded,
# so a cut by the raw length goes over; the cut must hold on the wire.
reset; touch "$FXT/rules"; echo would > "$FXT/act-stub"; collector queue "$T/one.jsonl"
Q=$(printf 'abcdefg"""%.0s' $(seq 1 2000))
jq -c --arg q "$Q" '.evidence = {pr: 7617, blob: $q}' <<<"$(dec ev-q act)" > "$FXT/decisions.jsonl"
tick
CL=$(grep '^JOBS POST /api/unblock/decisions/claim ' "$FXT/seq.log" | sed 's/^JOBS POST [^ ]* //')
eq "C5q one claim" "$(claims)" 1
eq "C5q evidence cut flag" "$(jq -r .evidence.truncated <<<"$CL" 2>/dev/null)" true
eq "C5q encoded evidence at most 8000 bytes" "$(jq -c .evidence <<<"$CL" | tr -d '\n' | wc -c | awk '{print ($1 <= 8000)}')" 1
eq "C5q claim body at most 8192 bytes" "$(printf '%s' "$CL" | wc -c | awk '{print ($1 <= 8192)}')" 1
reset; touch "$FXT/rules"; echo would > "$FXT/act-stub"; collector queue "$T/one.jsonl"
jq -c '.evidence = {pr: 7617, blob: ("y" * 2000)}' <<<"$(dec ev-s act)" > "$FXT/decisions.jsonl"
tick
CL=$(grep '^JOBS POST /api/unblock/decisions/claim ' "$FXT/seq.log" | sed 's/^JOBS POST [^ ]* //')
eq "C5q a 2 KB record goes through uncut" "$(jq -r '(.evidence.truncated // false | tostring) + " " + (.evidence.blob | length | tostring)' <<<"$CL" 2>/dev/null)" "false 2000"

eq "C5 cites joined as the route takes them" "$(jq -c .rule_cites <<<"$CL" 2>/dev/null)" '["G1","G12"]'
eq "C5 the claim mode is shadow" "$(jq -r .mode <<<"$CL" 2>/dev/null)" shadow
budget "C5"

# ═════ C6: a decision whose seam is not loaded is deferred, never claimed ════
seam_case() { # seam_case <name> <decision> <judge|nojudge> <files...> -> want claims
  local name="$1" d="$2" j="$3" want="$4"; shift 4
  reset; touch "$FXT/rules"; collector queue "$T/one.jsonl"
  for f in "$@"; do case "$f" in act-stub) echo would > "$FXT/act-stub" ;; *) touch "$FXT/$f" ;; esac; done
  dec "c6-$name" "$d" "$j" > "$FXT/decisions.jsonl"
  tick
  eq "C6 $name claims" "$(claims)" "$want"
  if [ "$want" = 0 ]; then
    has "C6 $name deferred line" "$LOG" "deferred"
    eq "C6 $name no route read" "$(cnt '^ROUTE ' "$FXT/seq.log")" 0
    eq "C6 $name no act call" "$(cnt '^ACT ' "$FXT/seq.log")" 0
  fi
}
seam_case judge-absent act judge 0 no-judge act-stub
seam_case card-absent escalate nojudge 0 no-card seam-judge act-stub
seam_case act-absent act nojudge 0 no-act seam-judge seam-card
seam_case judge-present act judge 1 seam-judge
seam_case card-present escalate nojudge 1 seam-card
seam_case act-present act nojudge 1 act-stub
eq "C6 act-present acted once" "$(cnt '^ACT ' "$FXT/seq.log")" 1

# ═════ C7: a second tick over the same fixture spends nothing ════════════════
reset; touch "$FXT/rules" "$FXT/seam-judge" "$FXT/seam-card"; echo would > "$FXT/act-stub"
collector queue "$T/one.jsonl"
{ dec c7-a act; dec c7-j act judge; dec c7-e escalate; } > "$FXT/decisions.jsonl"
tick
eq "C7 first tick claims" "$(claims)" 3
eq "C7 first tick records" "$(nrecords)" 3
cp -r "$FXT/seen" "$T/seen.keep"; cp "$FXT/id.n" "$T/id.keep"
: > "$FXT/seq.log"
tick; eq "C7 second tick rc" "$?" 0
eq "C7 second tick claims (all 409)" "$(claims)" 3
eq "C7 second tick records" "$(nrecords)" 0
eq "C7 second tick seam calls" "$(cnt '^\(ACT\|JUDGE\|CARD\|ROUTE\) ' "$FXT/seq.log")" 0
has "C7 second tick summary" "$LOG" "claimed=0 rows=0"
budget "C7"

# ═════ C8: no model route ════════════════════════════════════════════════════
reset; touch "$FXT/rules" "$FXT/seam-judge"; echo 75 > "$FXT/route.rc"
collector queue "$T/one.jsonl"
{ dec c8-1 act judge; dec c8-2 act judge; dec c8-3 act judge; } > "$FXT/decisions.jsonl"
tick; eq "C8 rc" "$?" 0
eq "C8 claims" "$(claims)" 3
eq "C8 records" "$(nrecords)" 3
eq "C8 every record is no-route" "$(records | jq -r .outcome | sort -u)" no-route
eq "C8 every record names the role" "$(records | jq -r '.outcome_detail | test("unblock.judge")' | sort -u)" true
eq "C8 every record has 0 model calls" "$(records | jq -r .model_calls | sort -u)" 0
eq "C8 judge calls" "$(cnt '^JUDGE ' "$FXT/seq.log")" 0
eq "C8 one alert" "$(cnt '^ALERT ' "$FXT/seq.log")" 1
has "C8 the alert id names the role" "$FXT/seq.log" "--id unblock-no-route-unblock.judge"
has "C8 the alert is a warn" "$FXT/seq.log" "--severity warn"
# each claim comes before its route read (claim before spend)
ORDER=$(grep -E '^(JOBS POST /api/unblock/decisions/claim|ROUTE )' "$FXT/seq.log" | awk '{print ($1=="ROUTE") ? "R" : "C"}' | tr -d '\n')
eq "C8 claim before each route read" "$ORDER" CRCRCR
budget "C8"

# ═════ C9: no collector, one wired collector, the act record ═════════════════
reset
tick; eq "C9 no collector rc" "$?" 0
eq "C9 one log line" "$(grep -c . "$LOG")" 1
case "$(tail -n1 "$LOG")" in *"0 collectors, 0 rows") ok ;; *) bad "C9 line: $(tail -n1 "$LOG")" ;; esac
eq "C9 no ledger call" "$(ledger)" 0
# TEST-CHANGE (BH-7723): #7752 ships bin/lib/unblock/rules.sh, so the closure
# now holds the real engine and the tick is wired. The "rules not loaded" arm
# is still checked: the file is moved away for this one tick, then restored.
reset; collector queue "$T/one.jsonl"; : > "$COL/review.sh"
[ -f "$H/bin/lib/unblock/rules.sh" ] && mv "$H/bin/lib/unblock/rules.sh" "$T/rules.sh.away"
tick
[ -f "$T/rules.sh.away" ] && mv "$T/rules.sh.away" "$H/bin/lib/unblock/rules.sh"
has "C9 one wired collector" "$LOG" "collectors=1"
has "C9 the unwired family is named" "$LOG" "unwired review"
has "C9 rules not loaded is named" "$LOG" "rules=unwired"
reset; touch "$FXT/rules"; echo would > "$FXT/act-stub"; collector queue "$T/one.jsonl"
dec c9b act > "$FXT/decisions.jsonl"
tick
eq "C9b the record carries ub_act's outcome" "$(records | jq -r .outcome)" would
eq "C9b ub_act got act.sh's input shape" "$(grep '^ACT ' "$FXT/seq.log" | sed 's/^ACT //' | jq -r '.action.name + " " + .decision_key + " " + (.pr|tostring)')" "requeue c9b 7617"
has "C9b the summary counts the row" "$LOG" "rows=1"
budget "C9"

# ═════ C10-C12: the soul, the cites, the rule schema ═════════════════════════
if command -v node >/dev/null 2>&1; then
  S=$(node "$REPO/bin/staff-core.mjs" soul "$REPO/prompts/staff/tackler-soul.md" 2>/dev/null)
  eq "C10 soul ok" "$(jq -r .ok <<<"$S")" true
  eq "C10 NEVER has merge a pull request" "$(jq -r '[.never[] | test("merge a pull request")] | any' <<<"$S")" true
  eq "C10 NEVER has deploy" "$(jq -r '[.never[] | test("deploy")] | any' <<<"$S")" true
else
  bad "C10 node missing"
fi
CITES="$REPO/catalog/unblock-rules.d/_cites.json"
eq "C11 keys G1..G21" "$(jq -r 'keys_unsorted | join(",")' "$CITES")" "$(seq -s, -f 'G%g' 1 21)"
eq "C11 every cite has source and text" "$(jq -r '[.[] | (.source | type == "string" and length > 0) and (.text | type == "string" and length > 0)] | all' "$CITES")" true
for f in "$REPO"/catalog/unblock-rules.d/*.json; do
  case "${f##*/}" in _*) continue ;; esac
  for c in $(jq -r '.cites[]?' "$f"); do
    jq -e --arg c "$c" 'has($c)' "$CITES" >/dev/null && ok || bad "C11 ${f##*/} cites $c, not in _cites.json"
  done
done
SCH="$REPO/catalog/unblock-rules.d/_schema.json"
eq "C12 required" "$(jq -c .required "$SCH")" '["id","priority","family","class","cites","match","action","key"]'
eq "C12 draft 2020-12" "$(jq -r '."$schema"' "$SCH")" "https://json-schema.org/draft/2020-12/schema"
eq "C12b --source human absent" "$(cat "$REPO/bin/unblock.sh" "$REPO/bin/lib/unblock/collect.sh" | grep -c -- '--source human')" 0

# ═════ C13: model_calls goes out as an integer ═══════════════════════════════
for MC in 1.0 1.5 '"1"'; do
  reset; touch "$FXT/rules" "$FXT/seam-judge"; collector queue "$T/one.jsonl"
  printf '%s' "$MC" > "$FXT/judge-calls"
  dec "c13" act judge > "$FXT/decisions.jsonl"
  tick
  eq "C13 model_calls [$MC] outcome" "$(records | jq -r .outcome)" would
  eq "C13 model_calls [$MC] is the integer 1" "$(records | jq -c .model_calls)" 1
  eq "C13 model_calls [$MC] cost is a number" "$(records | jq -r '.cost_usd | type')" number
done
budget "C13"

echo "unblock-contract.bh-7722: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
