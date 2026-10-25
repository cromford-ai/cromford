#!/bin/bash
# tests/pr-owner-enroll.bh-3929-test.sh — BH-3933 (BH-3929.1): every open PR gets
# an owner. bin/pr-owner-sweep.sh enrolls an ownerless PR into the merge
# conductor (po_enroll), counts what is still ownerless on its lane tick, pages
# ONCE when that count has stayed above zero for pr_owner.ownerless_alert_hours
# (ph_streak), reads conductor ownership from D1 (pr_state) and fails closed when
# it cannot, and a keyed conductor run evaluates an enrolled PR whose author
# harness_pr_list filters out.
#
# DRIVEN, NOT GREPPED. Every E case runs bin/pr-owner-sweep.sh whole against a
# stub gh (REST status lines through bin/lib/gh-rest.sh) and a file-backed jobs
# worker behind a curl shim that logs every write in order; E9 runs
# bin/merge-conductor.sh whole. The U cases call ph_streak against the same
# worker. No network, no secrets, no wall clock: NOW is pinned.
# Run from anywhere: tests/pr-owner-enroll.bh-3929-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

NOW=1790000000                      # 2026-09-21T14:13:20Z, pinned
OLD=2026-09-01T00:00:00Z            # every PR moved long before the grace window
A=example-org/demo-os;  PA=demo-os
B=example-org/demo2-os; PB=demo2-os
sha() { printf "$1%.0s" $(seq 40); }
H41=$(sha a); H51=$(sha c); HOLD=$(sha b)

H="$T/h"; W="$H/w"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/flags" "$H/state" "$H/env" "$H/fx" "$W" "$T/fakebin"
export HARNESS="$H"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf '%s %s https://demo.example - 2 box-demo\n%s %s https://demo2.example - 2 box-demo2\n' \
  "$PA" "$A" "$PB" "$B" > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
export GH_TOKEN=defaulttok GH_BUDGET_TTL_S=0 GH_ETAG=0 PR_OWNER_NOW="$NOW"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.log"\nexit "$(cat "$HARNESS/w/alert-rc" 2>/dev/null || echo 0)"\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\necho "MC_ONLY_PR=${MC_ONLY_PR:-}" >> "$HARNESS/spawns.log"\n' > "$H/bin/merge-conductor.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "${FAKE_BOX:-local}"\n' > "$H/bin/box-for.sh"
chmod +x "$H/bin/lane-alert.sh" "$H/bin/merge-conductor.sh" "$H/bin/box-for.sh"
# The stubs above are written FIRST: the closure install never overwrites (D46).
for s in bin/pr-owner-sweep.sh bin/merge-conductor-backstop.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed: $s"; exit 1; }
done
[ -f "$H/bin/lib/jobs/queue.sh" ] || { echo "fixture: bin/lib/jobs/*.sh missing beside the installed jobs-client.sh"; exit 1; }
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1; export BOX_NAME=box-hub HUB_BOX_NAME=box-hub  # TEST-CHANGE: BH-5124 — the conductor file is read only on the conductor's box (env, not state/box-name: reset wipes state/)

# ---- the gh stub: CLI lists from fixtures, REST answers with status lines ----
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
FX="$HARNESS/fx"
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
case "$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":2000000000},"graphql":{"remaining":4000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  *"pr merge"*) printf 'GH %s\n' "$*" >> "$HARNESS/writes.log"; exit 1 ;;
  *"pr list -R "*"--state open"*) s=$(sed -nE 's/.*-R ([^ ]+).*/\1/p' <<<"$*"); cat "$FX/${s//\//_}.open.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
  *"api -i -X POST repos/"*|*"api -i -X PATCH repos/"*)
    printf 'GH %s\n' "$*" >> "$HARNESS/writes.log"
    case "$*" in *"-X PATCH repos/"*"/pulls/"*) n=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*"); touch "$FX/closed-$n" ;; esac
    restpr --raw 200 '{}'; exit 0 ;;
  *"api -i -X GET repos/"*"/actions/runs?head_sha="*)
    h=$(sed -nE 's/.*head_sha=([0-9a-f]+).*/\1/p' <<<"$*")
    [ -f "$FX/runs-$h.status" ] && { restpr --raw "$(cat "$FX/runs-$h.status")" '{"message":"x"}'; exit 0; }
    restpr --runs - < "$FX/runs-$h" 2>/dev/null || restpr --runs; exit 0 ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    n=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")
    if [ -f "$FX/pull-$n.status" ]; then restpr --raw "$(cat "$FX/pull-$n.status")" '{"message":"API rate limit exceeded"}'; exit 0; fi
    if [ -f "$FX/closed-$n" ]; then restpr --raw 200 '{"state":"closed","merged_at":null}'; exit 0; fi
    restpr --raw 200 "$(cat "$FX/pull-$n.json")"; exit 0 ;;
esac
exit 1
SH
chmod +x "$T/fakebin/gh"

# ---- the jobs worker: one file per row, every write logged in order ---------
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
W="$HARNESS/w"; URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
P="${URL#https://jobs.test}"
ans() { printf '%s\n%s\n' "$2" "$1"; exit 0; }
if [ "$M" != GET ]; then
  printf 'JOBS %s %s %s\n' "$M" "${P%%\?*}" "$BODY" >> "$HARNESS/writes.log"
  case "$P" in
    /api/settings) [ -f "$W/settings-down" ] && ans 500 '{"error":"down"}'
      k=$(jq -r .key <<<"$BODY"); mkdir -p "$W/settings"; jq -r .value <<<"$BODY" > "$W/settings/$k"; ans 200 '{"ok":true}' ;;
    /api/pr-attempts) [ -f "$W/attempt-put-fail" ] && ans 500 '{"error":"down"}'
      mkdir -p "$W/attempts"; touch "$W/attempts/$(jq -r '"\(.repo|gsub("/";"_"))-\(.number)-\(.kind)-\(.sha)"' <<<"$BODY")"; ans 200 '{"ok":true}' ;;
    /api/pr-owners*) ans 200 '{"ok":true,"as_of":"2026-09-21T14:13:20Z"}' ;;
  esac
  ans 200 '{"ok":true}'
fi
printf 'JOBS GET %s\n' "$P" >> "$HARNESS/reads.log"
dec() { printf '%b' "${1//%/\\x}"; }
case "$P" in
  /api/settings/*) [ -f "$W/settings-down" ] && ans 500 '{"error":"down"}'
    k="${P#/api/settings/}"; [ -f "$W/settings/$k" ] || ans 404 '{"error":"no such setting"}'
    ans 200 "$(jq -nc --arg k "$k" --arg v "$(cat "$W/settings/$k")" '{setting:{key:$k,value:$v}}')" ;;
  /api/pr-attempts\?*) q=$(dec "${P#*\?}")
    r=$(sed -nE 's/.*repo=([^&]+).*/\1/p' <<<"$q"); n=$(sed -nE 's/.*number=([0-9]+).*/\1/p' <<<"$q")
    k=$(sed -nE 's/.*kind=([^&]+).*/\1/p' <<<"$q"); s=$(sed -nE 's/.*sha=([0-9a-f]+).*/\1/p' <<<"$q")
    [ -f "$W/attempts-down" ] && ans 500 '{"error":"down"}'
    [ -f "$W/attempts/${r//\//_}-$n-$k-$s" ] && ans 200 '{"rows":[{}]}'; ans 404 '{"error":"no rows"}' ;;
  /api/pr-state\?*) q=$(dec "${P#*\?}"); r=$(sed -nE 's/.*repo=([^&]+).*/\1/p' <<<"$q")
    [ -n "$r" ] || ans 404 '{"error":"no rows"}'
    [ -f "$W/prstate-down-${r//\//_}" ] && ans 500 '{"error":"down"}'
    [ -s "$W/prstate-${r//\//_}.json" ] && ans 200 "$(cat "$W/prstate-${r//\//_}.json")"; ans 404 '{"error":"no rows"}' ;;
  /api/verdict\?*) [ -f "$W/verdict-down" ] && ans 500 '{"error":"down"}'
    n=$(sed -nE 's/.*pull%2F([0-9]+).*/\1/p' <<<"$P")
    [ -f "$W/verdict-$n.json" ] && ans 200 "$(cat "$W/verdict-$n.json")"; ans 404 '{"error":"no verdict"}' ;;
  /api/verdicts\?*) ans 200 '{"standing":null}' ;;
  /api/jobs*) ans 200 '{"jobs":[]}' ;;
  /api/queue*) ans 200 '{"queue":[]}' ;;
esac
ans 404 '{"error":"no rows"}'
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# ---- fixtures ---------------------------------------------------------------
# pr_open <slug> <num> <author> <branch> [draft] — appends to the open list
pr_open() {
  local f="$H/fx/${1//\//_}.open.json"; [ -s "$f" ] || echo '[]' > "$f"
  jq --argjson n "$2" --arg a "$3" --arg b "$4" --arg s "$1" --arg h "$5" --argjson d "${6:-false}" --arg t "$OLD" \
    '. + [{number:$n,title:"scratch tool",headRefName:$b,headRefOid:$h,author:{login:$a},labels:[],body:"",
           mergeable:"MERGEABLE",updatedAt:$t,createdAt:$t,url:("https://github.com/"+$s+"/pull/"+($n|tostring)),isDraft:$d}]' \
    "$f" > "$f.t" && mv "$f.t" "$f"
}
# pr_rest <slug> <num> <head> <mergeable_state> [draft] — the REST pull object
pr_rest() {
  jq -nc --arg s "$1" --argjson n "$2" --arg h "$3" --arg ms "$4" --argjson d "${5:-false}" \
    '{number:$n,state:"open",merged_at:null,html_url:("https://github.com/"+$s+"/pull/"+($n|tostring)),draft:$d,
      mergeable_state:$ms,mergeable:true,labels:[],updated_at:"2026-09-01T00:00:00Z",
      head:{sha:$h,ref:"feature/x",repo:{full_name:$s}},base:{ref:"main",repo:{full_name:$s}}}' > "$H/fx/pull-$2.json"
}
approve() { # approve <num> <sha>
  jq -nc --arg s "$2" '{verdict:"APPROVE",artifacts:[{artifact_kind:"verdict",detail:({reviewed_sha:$s,settled:true}|tojson)}]}' > "$W/verdict-$1.json"
}
green() { printf 'completed|success\n' > "$H/fx/runs-$1"; }
prstate() { # prstate <slug> <num> <state> <reason> [head] [since-iso] — one D1 pr_state view row
  jq -nc --arg r "$1" --argjson n "$2" --arg s "$3" --arg w "$4" --arg h "${5:-$H41}" --arg t "${6:-$OLD}" \
    '{rows:[{id:7,repo:$r,number:$n,state:$s,reason:$w,head:$h,since:$t}]}' > "$W/prstate-${1//\//_}.json"
}
prstate_add() { # prstate_add <slug> <num> <state> <reason> <head> <since-iso> — one more view row
  local f="$W/prstate-${1//\//_}.json"; [ -s "$f" ] || echo '{"rows":[]}' > "$f"
  jq -c --arg r "$1" --argjson n "$2" --arg s "$3" --arg w "$4" --arg h "$5" --arg t "$6" \
    '.rows += [{id:(7+(.rows|length)),repo:$r,number:$n,state:$s,reason:$w,head:$h,since:$t}]' "$f" > "$f.t" && mv "$f.t" "$f"
}
# move_head <num> <sha> — the PR got a new head: the open list and the REST pull say so
move_head() {
  local f="$H/fx/${A//\//_}.open.json"
  jq --argjson n "$1" --arg h "$2" 'map(if .number == $n then .headRefOid = $h else . end)' "$f" > "$f.t" && mv "$f.t" "$f"
  jq -c --arg h "$2" '.head.sha = $h' "$H/fx/pull-$1.json" > "$H/fx/pull-$1.t" && mv "$H/fx/pull-$1.t" "$H/fx/pull-$1.json"
}
backstop() { "$H/bin/merge-conductor-backstop.sh" 2>&1; } # the real */5 backstop over the sweep's row file
tsvrow() { awk -F'\t' -v k="$1" '$1==k' "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null; } # tsvrow <key> — the backstop's row
reset() {
  scratch_rm "$H/fx"; scratch_rm "$W"; scratch_rm "$H/logs"; scratch_rm "$H/state"; scratch_rm "$H/locks"
  mkdir -p "$H/fx" "$W" "$H/logs" "$H/state" "$H/locks"
  rm -f "$H/writes.log" "$H/gh-calls.log" "$H/alerts.log" "$H/spawns.log"
  touch "$H/flags/pr-state-rows"
}
# e1 <slug> <num> <author> — the E1 shape: approved on its head, CI green, clean
e1() { local h="$H41"; [ "$2" = 51 ] && h="$H51"
  pr_open "$1" "$2" "$3" "$3/scratch-tool" "$h"; pr_rest "$1" "$2" "$h" clean; approve "$2" "$h"; green "$h"; }
# The sweep runs in CI's shape: CI's traced shards never set HARNESS_TEST_SANDBOX,
# so neither does its child here (BH-3933 r3, the r2 merge-queue ejection).
sweep() { env -u HARNESS_TEST_SANDBOX "$H/bin/pr-owner-sweep.sh" "$@" >/dev/null 2>&1; }
waitspawn() { local i; for i in $(seq 50); do [ -s "$H/spawns.log" ] && return 0; sleep 0.1; done; return 1; } # determinism: ok bounded wait for the detached keyed-conductor child the sweep spawns
W_() { cat "$H/writes.log" 2>/dev/null; }
# TEST-CHANGE (BH-3933 merged with BH-3936): the sweep now also flushes its
# per-repo health rollup, a `pr_health` ledger row, on every run. That is not
# an enroll write, so the "writes no enroll row" checks below read the writes
# without it. Every check still refuses any pr-attempts, conductor-ledger or
# settings write.
enroll_writes() { grep -v '"kind":"pr_health"' "$H/writes.log" 2>/dev/null; }
LOG() { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
tick() { jq -r '.note // empty' "$H"/state/heartbeat/pr-owner-sweep.*.json 2>/dev/null | tail -1; }
attempt_put() { grep -n 'JOBS PUT /api/pr-attempts' "$H/writes.log" 2>/dev/null | grep "\"number\":$1" | grep '"kind":"enrolled"' | head -1 | cut -d: -f1; }
ledger_put()  { grep -n 'JOBS PUT /api/ledger' "$H/writes.log" 2>/dev/null | grep "#$1\"" | grep "\"status\":\"$2\"" | head -1 | cut -d: -f1; }

# ============================================================================
# S. ph_streak — the ownerless clock, a settings row and nothing else
# ============================================================================
reset
touch "$T/marker"
# JOBS_ALERT=0: the jobs client's own once-a-day outage flag (flags/alerted-jobs-client-<day>)
# is the client's, not ph_streak's, and S4 drives an outage on purpose.
U() { ( export JOBS_URL=https://jobs.test HARNESS_SECRET=s3cret JOBS_RETRIES=0 JOBS_ALERT=0
        . "$H/bin/jobs-client.sh" 2>/dev/null; . "$H/bin/lib/pr-owner/enroll.sh"; "$@" ) 2>/dev/null; }
KEY=streak.u1
mkdir -p "$W/settings"
echo $((NOW - 24*3600 + 60)) > "$W/settings/$KEY"
PH_NOW=$NOW U ph_streak u1 1 24; rc=$?
[ "$rc" = 1 ] && ok || bad "S1: a 23h59m streak must not fire (rc $rc)"
[ "$(cat "$W/settings/$KEY")" = $((NOW - 24*3600 + 60)) ] && ok || bad "S1: the row must be unchanged: $(cat "$W/settings/$KEY")"
echo $((NOW - 24*3600)) > "$W/settings/$KEY"
PH_NOW=$NOW U ph_streak u1 1 24; rc=$?
[ "$rc" = 0 ] && ok || bad "S1: a streak at exactly 24h must fire (rc $rc)"
PH_NOW=$NOW U ph_streak_fired u1
[ "$(cat "$W/settings/$KEY")" = "$((NOW - 24*3600)):fired" ] && ok || bad "S2: ph_streak_fired must stamp :fired: $(cat "$W/settings/$KEY")"
PH_NOW=$NOW U ph_streak u1 1 24; rc=$?
[ "$rc" = 1 ] && ok || bad "S2: a fired streak must not fire twice (rc $rc)"
# a fresh row starts the clock at PH_NOW
rm -f "$W/settings/streak.u0"; PH_NOW=$NOW U ph_streak u0 1 24; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$W/settings/streak.u0" 2>/dev/null)" = "$NOW" ] && ok || bad "S2: no row = the clock starts at PH_NOW (rc $rc, row $(cat "$W/settings/streak.u0" 2>/dev/null))"
# S3: the clear resolves once, and only a delivered resolve clears the row
echo 1 > "$W/alert-rc"
PH_NOW=$NOW U ph_streak u1 0 24
[ "$(cat "$W/settings/$KEY")" = "$((NOW - 24*3600)):fired" ] && ok || bad "S3: a failed resolve must leave the row :fired: $(cat "$W/settings/$KEY")"
rm -f "$W/alert-rc"; : > "$H/alerts.log"
PH_NOW=$NOW U ph_streak u1 0 24
[ "$(grep -c -- '--resolve --id u1 ' "$H/alerts.log")" = 1 ] && ok || bad "S3: exactly one --resolve --id u1: $(cat "$H/alerts.log")"
[ "$(cat "$W/settings/$KEY")" = 0 ] && ok || bad "S3: a delivered resolve clears the row to 0: $(cat "$W/settings/$KEY")"
PH_NOW=$NOW U ph_streak u1 0 24
[ "$(grep -c -- '--resolve' "$H/alerts.log")" = 1 ] && ok || bad "S3: a cleared row resolves nothing again: $(cat "$H/alerts.log")"
# S4: outage and no clock
echo $((NOW - 30*3600)) > "$W/settings/$KEY"; touch "$W/settings-down"; : > "$H/writes.log"
PH_NOW=$NOW U ph_streak u1 1 24; rc=$?
[ "$rc" = 1 ] && ok || bad "S4: a settings outage must not fire (rc $rc)"
grep -q 'PUT /api/settings' "$H/writes.log" && bad "S4: a settings outage must write nothing: $(W_)" || ok
rm -f "$W/settings-down"
U ph_streak u1 1 24; rc=$?
[ "$rc" = 1 ] && ok || bad "S4: no PH_NOW must not fire (rc $rc)"
PH_NOW=$NOW U ph_streak u1 1 0; rc=$?
[ "$rc" = 1 ] && ok || bad "S4: hours=0 is off (rc $rc)"
# a long id is hashed down to a legal settings key
PH_NOW=$NOW U ph_streak "pr-owner-ownerless:example-org/a-very-long-repository-name-that-goes-on-and-on" 1 24
LK=$(ls "$W/settings" | grep -v '^streak\.u' | head -1)
[ -n "$LK" ] && [ "${#LK}" -le 64 ] && [[ "$LK" =~ ^[a-z0-9_.-]+$ ]] && ok || bad "U: a long id must make a legal key <= 64 chars: '$LK'"
# S4: no file under state/ or flags/
NEW=$(find "$H/state" "$H/flags" -newer "$T/marker" -type f 2>/dev/null)
[ -z "$NEW" ] && ok || bad "S4: ph_streak must write no file under state/ or flags/: $NEW"

# ============================================================================
# E1. ORPHAN, approved on its head, CI green, clean: attempt row FIRST, READY,
#     one keyed spawn, tick body counts it, no merge.
# ============================================================================
reset; e1 "$A" 41 operator
touch "$T/marker2"
sweep "$PA"
AP=$(attempt_put 41); LP=$(ledger_put 41 READY)
[ -n "$AP" ] && ok || bad "E1: an enrolled attempt row on the head must be PUT: $(W_)"
grep 'PUT /api/pr-attempts' "$H/writes.log" | grep -q "\"sha\":\"$H41\"" && ok || bad "E1: the attempt is keyed to the REST head"
[ -n "$LP" ] && ok || bad "E1: a READY pr_state ledger row must be written: $(W_)"
[ -n "$AP" ] && [ -n "$LP" ] && [ "$AP" -lt "$LP" ] && ok || bad "E1: the attempt row must come BEFORE READY (attempt line $AP, ledger line $LP)"
grep 'PUT /api/ledger' "$H/writes.log" | grep "#41\"" | grep -q 'enrolled-by-owner-sweep' && ok || bad "E1: the READY reason is enrolled-by-owner-sweep"
grep -q "pulls/41" "$H/gh-calls.log" && grep -q "actions/runs?head_sha=$H41" "$H/gh-calls.log" && ok || bad "E1: head, mergeable and CI are read over REST"
waitspawn
[ "$(grep -c 'MC_ONLY_PR=' "$H/spawns.log" 2>/dev/null)" = 1 ] && ok || bad "E1: exactly one keyed conductor spawn: $(cat "$H/spawns.log" 2>/dev/null)"
grep -qx "MC_ONLY_PR=$A#41" "$H/spawns.log" 2>/dev/null && ok || bad "E1: the spawn names the key: $(cat "$H/spawns.log" 2>/dev/null)"
grep -q "keyed conductor run spawned: $A#41" "$H/logs/pr-owner-sweep.log" && ok || bad "E1: the spawn is logged: $(LOG | tail -3)"
TB=$(tick)
grep -q 'enrolled=1' <<<"$TB" && grep -q 'ownerless=0' <<<"$TB" && ok || bad "E1: the tick body must say enrolled=1 ownerless=0: '$TB'"
for c in repos= open= owned= external= superseded= stale_rungs=; do grep -q "$c" <<<"$TB" || bad "E1: the tick body must carry $c: '$TB'"; done
grep -q 'GH .*merge' "$H/writes.log" && bad "E1: the sweep must never merge: $(W_)" || ok
grep -qi 'claude\|agent-call' "$H/gh-calls.log" && bad "E1: no model call" || ok
grep -q 'owner-source=d1' "$H/logs/pr-owner-sweep.log" && ok || bad "E1: the owner source is logged: $(LOG | head -3)"
NEW=$(find "$H/state" "$H/flags" -newer "$T/marker2" -type f 2>/dev/null \
      | grep -vE "/state/(pr-owners|merge-conductor|heartbeat|lane-gate|gh-etag|gh-rest-ledger|gh-budget)/|/state/pr-owner-sweep/[^/]+/(openlist|mergedlist)\.(json|meta)$")
[ -z "$NEW" ] && ok || bad "E1: no new file under state/ or flags/ outside the lanes' own stores: $NEW"

# ============================================================================
# E2/E2b. EXTERNAL: enrolled when pr_owner.enroll_external=1, recorded only at 0
# ============================================================================
reset; e1 "$A" 41 collaborator-1; mkdir -p "$W/settings"; echo 1 > "$W/settings/pr_owner.enroll_external"
sweep "$PA"
[ -n "$(attempt_put 41)" ] && [ -n "$(ledger_put 41 READY)" ] && ok || bad "E2: an EXTERNAL PR is enrolled under knob 1: $(W_)"
waitspawn; grep -qx "MC_ONLY_PR=$A#41" "$H/spawns.log" 2>/dev/null && ok || bad "E2: …and spawned"
reset; e1 "$A" 41 collaborator-1; mkdir -p "$W/settings"; echo 0 > "$W/settings/pr_owner.enroll_external"
sweep "$PA"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger' <(enroll_writes) && bad "E2b: knob 0 must write no attempt and no ledger row: $(W_)" || ok
[ ! -s "$H/spawns.log" ] && ok || bad "E2b: knob 0 must not spawn"
grep -q "enroll-recorded-only $A#41" "$H/logs/pr-owner-sweep.log" && ok || bad "E2b: knob 0 logs enroll-recorded-only: $(LOG | tail -3)"
grep -q 'external=1' <<<"$(tick)" && grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "E2b: knob 0 counts external=1 ownerless=0: '$(tick)'"

# ============================================================================
# E3. unapproved: WAIT_CI, no attempt row, no spawn; a rerun over that row writes nothing
# ============================================================================
reset; e1 "$A" 41 operator; rm -f "$W/verdict-41.json"
sweep "$PA"
[ -n "$(ledger_put 41 WAIT_CI)" ] && ok || bad "E3: an unapproved PR is enrolled WAIT_CI: $(W_)"
[ -z "$(attempt_put 41)" ] && ok || bad "E3: WAIT_CI writes no attempt row"
[ -z "$(ledger_put 41 READY)" ] && ok || bad "E3: never READY without an APPROVE"
sleep 0.3; [ ! -s "$H/spawns.log" ] && ok || bad "E3: WAIT_CI spawns nothing" # determinism: ok a negative wait for a spawn that must not happen
grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "E3: a PR enrolled WAIT_CI is owned: '$(tick)'"
prstate "$A" 41 WAIT_CI enrolled-by-owner-sweep; : > "$H/writes.log"
sweep "$PA"
grep -q 'PUT /api/ledger\|PUT /api/pr-attempts' <(enroll_writes) && bad "E3: a row we parked is left as it is: $(W_)" || ok
# …and an approval later promotes it (A7)
approve 41 "$H41"; : > "$H/writes.log"
sweep "$PA"
[ -n "$(ledger_put 41 READY)" ] && ok || bad "E3: a WAIT_CI row we parked is promoted once approved: $(W_)"

# ============================================================================
# E4. the cap: PR_OWNER_MAX_ACTIONS=0 defers, writes nothing, still ownerless
# ============================================================================
reset; e1 "$A" 41 operator
PR_OWNER_MAX_ACTIONS=0 sweep "$PA"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger' <(enroll_writes) && bad "E4: a capped enroll writes nothing: $(W_)" || ok
grep -q "enroll-deferred $A#41 cap=0" "$H/logs/pr-owner-sweep.log" && ok || bad "E4: enroll-deferred is logged: $(LOG | tail -3)"
grep -q 'ownerless=1' <<<"$(tick)" && ok || bad "E4: the tick says ownerless=1: '$(tick)'"

# ============================================================================
# E5. ownerless 25h: ONE alert naming the PR, row stamped :fired, none on a rerun
# ============================================================================
SK="streak.pr-owner-ownerless.example-org.demo-os"
reset; e1 "$A" 41 operator; mkdir -p "$W/settings"; echo $((NOW - 25*3600)) > "$W/settings/$SK"
PR_OWNER_MAX_ACTIONS=0 sweep "$PA"
[ "$(grep -c -- "--id pr-owner-ownerless:$A " "$H/alerts.log" 2>/dev/null)" = 1 ] && ok || bad "E5: exactly one ownerless alert: $(cat "$H/alerts.log" 2>/dev/null)"
grep -- "--id pr-owner-ownerless:$A " "$H/alerts.log" 2>/dev/null | grep -q '#41' && ok || bad "E5: the alert names #41"
[ "$(cat "$W/settings/$SK")" = "$((NOW - 25*3600)):fired" ] && ok || bad "E5: the row is stamped :fired: $(cat "$W/settings/$SK")"
PR_OWNER_MAX_ACTIONS=0 sweep "$PA"
[ "$(grep -c -- "--id pr-owner-ownerless:$A " "$H/alerts.log")" = 1 ] && ok || bad "E5: a rerun sends no second alert: $(cat "$H/alerts.log")"
# 23h does not page
reset; e1 "$A" 41 operator; mkdir -p "$W/settings"; echo $((NOW - 23*3600)) > "$W/settings/$SK"
PR_OWNER_MAX_ACTIONS=0 sweep "$PA"
grep -q -- '--id pr-owner-ownerless' "$H/alerts.log" 2>/dev/null && bad "E5: 23h must not page" || ok
# ownerless_alert_hours=0 is off
reset; e1 "$A" 41 operator; mkdir -p "$W/settings"; echo $((NOW - 25*3600)) > "$W/settings/$SK"; echo 0 > "$W/settings/pr_owner.ownerless_alert_hours"
PR_OWNER_MAX_ACTIONS=0 sweep "$PA"
grep -q -- '--id pr-owner-ownerless' "$H/alerts.log" 2>/dev/null && bad "E5: ownerless_alert_hours=0 must not page" || ok
# a repo that is owned again resolves the open id
reset; e1 "$A" 41 operator; mkdir -p "$W/settings"; echo "$((NOW - 25*3600)):fired" > "$W/settings/$SK"
sweep "$PA"
grep -q -- "--resolve --id pr-owner-ownerless:$A " "$H/alerts.log" 2>/dev/null && ok || bad "E5: an enrolled repo resolves its open ownerless id: $(cat "$H/alerts.log" 2>/dev/null)"
[ "$(cat "$W/settings/$SK")" = 0 ] && ok || bad "E5: …and clears the row: $(cat "$W/settings/$SK")"

# ============================================================================
# E15 (r3). PR_OWNER_NOW is the sweep's clock with HARNESS_TEST_SANDBOX unset,
#     as in CI's traced shards: the r2 seam was gated on that flag, so CI read
#     the wall clock against these pinned rows and E5/E10c went red in the queue.
# ============================================================================
# The row starts 30 days AFTER the wall clock and the pin is 25h past it, so
# only the pin can page: a sweep reading the wall clock sees a streak that has
# not started yet.
REAL=$(date -u +%s); FUT=$((REAL + 30*86400))
reset; e1 "$A" 41 operator; mkdir -p "$W/settings"; echo "$FUT" > "$W/settings/$SK"
PR_OWNER_MAX_ACTIONS=0 PR_OWNER_NOW=$((FUT + 25*3600)) env -u HARNESS_TEST_SANDBOX "$H/bin/pr-owner-sweep.sh" "$PA" >/dev/null 2>&1
[ "$(grep -c -- "--id pr-owner-ownerless:$A " "$H/alerts.log" 2>/dev/null)" = 1 ] && ok || bad "E15: the pinned clock (25h past the row) must page once with the flag unset: $(cat "$H/alerts.log" 2>/dev/null)"
[ "$(cat "$W/settings/$SK")" = "$FUT:fired" ] && ok || bad "E15: …stamped against the pinned clock: $(cat "$W/settings/$SK")"
# a non-number never becomes 0: the real clock answers instead
reset; e1 "$A" 41 operator; mkdir -p "$W/settings"; echo $((REAL - 25*3600)) > "$W/settings/$SK"
PR_OWNER_MAX_ACTIONS=0 PR_OWNER_NOW=soon env -u HARNESS_TEST_SANDBOX "$H/bin/pr-owner-sweep.sh" "$PA" >/dev/null 2>&1
[ "$(grep -c -- "--id pr-owner-ownerless:$A " "$H/alerts.log" 2>/dev/null)" = 1 ] && ok || bad "E15: PR_OWNER_NOW=soon falls back to the real clock: $(cat "$H/alerts.log" 2>/dev/null) row $(cat "$W/settings/$SK")"

# ============================================================================
# E6. REST 429 on the pull read: no writes, the streak row byte-identical
# ============================================================================
reset; e1 "$A" 41 operator; echo 429 > "$H/fx/pull-41.status"; mkdir -p "$W/settings"; echo $((NOW - 25*3600)) > "$W/settings/$SK"
cp "$W/settings/$SK" "$T/sk.before"
sweep "$PA"
grep -q 'PUT ' <<<"$(enroll_writes | grep -v '/api/pr-owners')" && bad "E6: an unreadable PR writes nothing: $(W_)" || ok
cmp -s "$T/sk.before" "$W/settings/$SK" && ok || bad "E6: the streak row must be untouched: $(cat "$W/settings/$SK")"
grep -q -- '--id pr-owner-ownerless' "$H/alerts.log" 2>/dev/null && bad "E6: an unreadable repo must not page" || ok

# ============================================================================
# E7. D1 pr_state outage on repo A: A swept nothing, B enrolled
# ============================================================================
reset; e1 "$A" 41 operator; e1 "$B" 51 operator; touch "$W/prstate-down-${A//\//_}"
sweep "$PA" "$PB"
grep -q 'demo-os' <<<"$(grep 'PUT \|POST \|PATCH ' "$H/writes.log" 2>/dev/null)" && bad "E7: nothing may be written for the repo whose owners are unreadable: $(W_)" || ok
grep -q "$A: conductor rows unreadable (D1 pr_state)" "$H/logs/pr-owner-sweep.log" && ok || bad "E7: the outage is logged: $(LOG | tail -4)"
[ -n "$(attempt_put 51)" ] && [ -n "$(ledger_put 51 READY)" ] && ok || bad "E7: the readable repo is still swept: $(W_)"
[ ! -f "$H/state/pr-owners/${A//\//_}.json" ] && ok || bad "E7: the unreadable repo records nothing"

# ============================================================================
# E1c. the attempt PUT fails: no READY, no spawn
# ============================================================================
reset; e1 "$A" 41 operator; touch "$W/attempt-put-fail"
sweep "$PA"
[ -z "$(ledger_put 41 READY)" ] && ok || bad "E1c: no READY without its attempt row: $(W_)"
sleep 0.3; [ ! -s "$H/spawns.log" ] && ok || bad "E1c: no spawn" # determinism: ok a negative wait for a spawn that must not happen
grep -q "enroll-failed attempt-row $A#41" "$H/logs/pr-owner-sweep.log" && ok || bad "E1c: the failure is logged: $(LOG | tail -3)"

# ============================================================================
# A. the adversarial set: none of these goes READY or spawns
# ============================================================================
e11() { # e11 <label> <setup...>
  local lbl="$1"; shift
  reset; e1 "$A" 41 operator; "$@"
  sweep "$PA"
  [ -z "$(ledger_put 41 READY)" ] && [ -z "$(attempt_put 41)" ] && ok || bad "A $lbl: must not go READY: $(W_)"
  [ ! -s "$H/spawns.log" ] && ok || bad "A $lbl: must not spawn"
}
# E3b. an approved draft: WAIT_CI, never READY
e11 E3b-draft pr_rest "$A" 41 "$H41" clean true
[ -n "$(ledger_put 41 WAIT_CI)" ] && ok || bad "E3b: an approved draft gets WAIT_CI: $(W_)"
for ms in blocked unstable dirty unknown; do e11 "mergeable_state=$ms" pr_rest "$A" 41 "$H41" "$ms"; done
for ci in pending none red; do
  case $ci in pending) L='in_progress|' ;; none) L='' ;; red) L='completed|failure' ;; esac
  e11 "ci=$ci" eval "printf '%s\n' '$L' > '$H/fx/runs-$H41'"
done
e11 "ci=unavailable" eval "echo 500 > '$H/fx/runs-$H41.status'"
e11 "approve-on-old-head" approve 41 "$HOLD"
e11 "verdict-outage" touch "$W/verdict-down"
grep -q 'enroll-skipped verdict-unreadable' "$H/logs/pr-owner-sweep.log" && ok || bad "A: a verdict outage is logged: $(LOG | tail -3)"
[ -z "$(ledger_put 41 WAIT_CI)" ] && ok || bad "A: a verdict outage writes no WAIT_CI either: $(W_)"
e11 "owned-by-live-row" prstate "$A" 41 QUEUED enqueued
e11 "dry-run" export PR_OWNER_DRY_RUN=1; unset PR_OWNER_DRY_RUN
grep -q "DRY-RUN would: enroll $A#41 READY" "$H/logs/pr-owner-sweep.log" && ok || bad "A: dry run says what it would enroll: $(LOG | tail -3)"
e11 "parked" eval "jq '.[0].labels=[{\"name\":\"parked\"}]' '$H/fx/${A//\//_}.open.json' > '$T/p.json' && mv '$T/p.json' '$H/fx/${A//\//_}.open.json'"
grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "A: PARKED is not ownerless: '$(tick)'"

# ============================================================================
# E1b. two repos, one E1 PR each: ONE spawn naming both keys
# ============================================================================
reset; e1 "$A" 41 operator; e1 "$B" 51 operator
sweep "$PA" "$PB"
waitspawn
[ "$(grep -c 'MC_ONLY_PR=' "$H/spawns.log" 2>/dev/null)" = 1 ] && ok || bad "E1b: exactly one spawn per tick: $(cat "$H/spawns.log" 2>/dev/null)"
grep -q "MC_ONLY_PR=.*$A#41" "$H/spawns.log" && grep -q "MC_ONLY_PR=.*$B#51" "$H/spawns.log" && ok || bad "E1b: the spawn names both keys: $(cat "$H/spawns.log")"
grep -q 'repos=2' <<<"$(tick)" && grep -q 'enrolled=2' <<<"$(tick)" && ok || bad "E1b: tick totals across repos: '$(tick)'"

# ============================================================================
# E7b. pr-state-rows off: the TSV is the owner source and a READY row owns the PR
# ============================================================================
reset; e1 "$A" 41 operator; rm -f "$H/flags/pr-state-rows"
mkdir -p "$H/state/merge-conductor"
printf '%s#41\tREADY\t1757000000\t%s\t%s\t-\tapproved\thttps://x\n' "$A" "$H41" "$H41" > "$H/state/merge-conductor/pr-state.tsv"
sweep "$PA"
grep -q 'owner-source=tsv' "$H/logs/pr-owner-sweep.log" && ok || bad "E7b: the TSV source is logged: $(LOG | head -3)"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger' <(enroll_writes) && bad "E7b: an owned PR is not enrolled: $(W_)" || ok
grep -q 'owned=1' <<<"$(tick)" && grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "E7b: the TSV row owns it: '$(tick)'"

# ============================================================================
# E15. a --repo (box-scoped) run records only: no enroll, no spawn, no streak
# ============================================================================
reset; e1 "$A" 41 operator
sweep --repo "$A"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger\|PUT /api/settings' <(enroll_writes) && bad "E15: a box-scoped run writes no enroll and no streak: $(W_)" || ok
sleep 0.3; [ ! -s "$H/spawns.log" ] && ok || bad "E15: a box-scoped run spawns nothing" # determinism: ok a negative wait for a spawn that must not happen
grep -q "enroll-skipped $A#41 repo-scoped" "$H/logs/pr-owner-sweep.log" && ok || bad "E15: the skip is logged: $(LOG | tail -3)"

# ============================================================================
# E16. an enrolled ORPHAN with a ticket key is not also handed back
# ============================================================================
reset; e1 "$A" 41 operator
jq '.[0].headRefName="ticket/TK-41" | .[0].title="TK-41: the thing"' "$H/fx/${A//\//_}.open.json" > "$T/k.json" && mv "$T/k.json" "$H/fx/${A//\//_}.open.json"
sweep "$PA"
[ -n "$(ledger_put 41 READY)" ] && ok || bad "E16: the keyed ORPHAN is enrolled: $(W_)"
grep -q 'blocked demo-os TK-41' "$H/writes.log" && bad "E16: an enrolled PR's key must not also be handed back: $(W_)" || ok

# ============================================================================
# E10. review F1: a READY row never stays on a head that is not the PR's head
# ============================================================================
HB=$(sha d)
reset; e1 "$A" 41 operator
sweep "$PA"
[ "$(tsvrow "$A#41" | cut -f2,4,5)" = "READY	$H41	$H41" ] && ok || bad "E10: precondition, enrolled READY on head A: $(tsvrow "$A#41")"
move_head 41 "$HB"; green "$HB"                       # the APPROVE stays on head A
prstate "$A" 41 READY enrolled-by-owner-sweep "$H41"; : > "$H/writes.log"; rm -f "$H/spawns.log"
sweep "$PA"
[ "$(tsvrow "$A#41" | cut -f2,4,5)" = "WAIT_CI	$HB	-" ] && ok || bad "E10: a moved, unapproved head is WAIT_CI on head B, reviewed -: $(tsvrow "$A#41")"
[ -n "$(ledger_put 41 WAIT_CI)" ] && ok || bad "E10: the WAIT_CI move is mirrored to the ledger: $(W_)"
backstop | grep -q '0 candidates' && ok || bad "E10: the backstop no longer selects the PR: $(backstop)"
# E10b: the conductor's OWN READY row (reason approved) stranded on head A, the PR
# re-approved on head B: rewritten onto head B, attempt row on B, one spawn.
reset; e1 "$A" 41 operator; move_head 41 "$HB"; approve 41 "$HB"; green "$HB"
mkdir -p "$H/state/merge-conductor"
printf '%s#41\tREADY\t1757000000\t%s\t%s\t-\tapproved\thttps://x\n' "$A" "$H41" "$H41" > "$H/state/merge-conductor/pr-state.tsv"
prstate "$A" 41 READY approved "$H41"
sweep "$PA"
[ "$(tsvrow "$A#41" | cut -f2,4,5)" = "READY	$HB	$HB" ] && ok || bad "E10b: a stranded READY is rewritten onto head B: $(tsvrow "$A#41")"
grep 'PUT /api/pr-attempts' "$H/writes.log" 2>/dev/null | grep -q "\"sha\":\"$HB\"" && ok || bad "E10b: the attempt row is on head B: $(W_)"
waitspawn; grep -qx "MC_ONLY_PR=$A#41" "$H/spawns.log" 2>/dev/null && ok || bad "E10b: one keyed spawn: $(cat "$H/spawns.log" 2>/dev/null)"
# E10c: a head that moved inside the grace window is the conductor's, not ours
reset; e1 "$A" 41 operator; move_head 41 "$HB"; approve 41 "$HB"; green "$HB"
prstate "$A" 41 READY approved "$H41" "$(date -u -d "@$((NOW - 60))" +%Y-%m-%dT%H:%M:%SZ)"
sweep "$PA"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger' <(enroll_writes) && bad "E10c: a head that moved a minute ago is left alone: $(W_)" || ok

# ============================================================================
# E11. review F2: the switch thrown withdraws an external READY row; back on re-enrolls
# ============================================================================
reset; e1 "$A" 41 collaborator-1; mkdir -p "$W/settings"; echo 1 > "$W/settings/pr_owner.enroll_external"
sweep "$PA"
[ "$(tsvrow "$A#41" | cut -f2)" = READY ] && ok || bad "E11: precondition, the external PR is enrolled READY: $(tsvrow "$A#41")"
prstate "$A" 41 READY enrolled-by-owner-sweep "$H41"; echo 0 > "$W/settings/pr_owner.enroll_external"
: > "$H/writes.log"; rm -f "$H/spawns.log"
sweep "$PA"
[ "$(tsvrow "$A#41" | cut -f2,5,7)" = "WAIT_CI	-	enroll-withdrawn" ] && ok || bad "E11: switch 0 withdraws the row to WAIT_CI enroll-withdrawn, reviewed -: $(tsvrow "$A#41")"
grep 'PUT /api/ledger' "$H/writes.log" | grep "#41\"" | grep -q 'enroll-withdrawn' && ok || bad "E11: the withdraw is mirrored: $(W_)"
[ -z "$(attempt_put 41)" ] && ok || bad "E11: a withdraw writes no attempt row"
sleep 0.3; [ ! -s "$H/spawns.log" ] && ok || bad "E11: a withdraw spawns nothing" # determinism: ok a negative wait for a spawn that must not happen
grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "E11: a withdrawn external PR is not ownerless: '$(tick)'"
backstop | grep -q '0 candidates' && ok || bad "E11: the backstop no longer selects it: $(backstop)"
prstate "$A" 41 WAIT_CI enroll-withdrawn "$H41"; : > "$H/writes.log"
sweep "$PA"
grep -q 'PUT /api/ledger' <(enroll_writes) && bad "E11: switch 0 leaves a withdrawn row as it is: $(W_)" || ok
echo 1 > "$W/settings/pr_owner.enroll_external"; : > "$H/writes.log"
sweep "$PA"
[ -n "$(ledger_put 41 READY)" ] && ok || bad "E11: switch back to 1 re-enrolls it: $(W_)"
waitspawn; grep -qx "MC_ONLY_PR=$A#41" "$H/spawns.log" 2>/dev/null && ok || bad "E11: …and spawns it: $(cat "$H/spawns.log" 2>/dev/null)"

# ============================================================================
# E17. the merged owner rule (BH-3933 on main's BH-3936): an EXTERNAL PR with a
#      live conductor row is owned by the shell override, one the switch
#      withdrew is not, and an internal PR is owned by the classifier's own
#      conductor:<state> path, never by the override.
# ============================================================================
POS() { jq -r --arg n "$1" '.prs[$n] | "\(.state)|\(.reason)"' "$H/state/pr-owners/${A//\//_}.json" 2>/dev/null; }
reset; e1 "$A" 41 collaborator-1; mkdir -p "$W/settings"; echo 0 > "$W/settings/pr_owner.enroll_external"
prstate "$A" 41 WAIT_CI ci-pending "$H41"
sweep "$PA"
grep -q 'owned=1' <<<"$(tick)" && grep -q 'external=1' <<<"$(tick)" && grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "E17a: an EXTERNAL PR with a live conductor row is owned: '$(tick)'"
[ "$(POS 41 | cut -d'|' -f1)" = EXTERNAL ] && ok || bad "E17a: the recorded class stays EXTERNAL (review-prs owns the review): $(POS 41)"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger' <(enroll_writes) && bad "E17a: an owned EXTERNAL PR is not enrolled: $(W_)" || ok
reset; e1 "$A" 41 collaborator-1; mkdir -p "$W/settings"; echo 0 > "$W/settings/pr_owner.enroll_external"
prstate "$A" 41 WAIT_CI enroll-withdrawn "$H41"
sweep "$PA"
grep -q 'owned=0' <<<"$(tick)" && grep -q 'external=1' <<<"$(tick)" && grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "E17b: a withdrawn EXTERNAL row owns nothing: '$(tick)'"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger' <(enroll_writes) && bad "E17b: switch 0 leaves the withdrawn row as it is: $(W_)" || ok
reset; e1 "$A" 41 operator
prstate "$A" 41 WAIT_CI ci-pending "$H41"
sweep "$PA"
[ "$(POS 41)" = "OWNED|conductor:WAIT_CI" ] && ok || bad "E17c: an internal PR is OWNED by the classifier's conductor path: $(POS 41)"
grep -q 'owned=1' <<<"$(tick)" && grep -q 'external=0' <<<"$(tick)" && grep -q 'ownerless=0' <<<"$(tick)" && ok || bad "E17c: …and counted owned: '$(tick)'"
grep -q 'PUT /api/pr-attempts\|PUT /api/ledger' <(enroll_writes) && bad "E17c: an owned internal PR is not enrolled: $(W_)" || ok

# ============================================================================
# E13. never rewrite a harness ticket/* row on a head mismatch, nor a hand-off
# ============================================================================
reset
pr_open "$A" 61 operator ticket/bh-1 "$HB"; pr_rest "$A" 61 "$HB" clean; approve 61 "$HB"
pr_open "$A" 62 operator feat/y "$HB"; pr_rest "$A" 62 "$HB" clean; approve 62 "$HB"; green "$HB"
prstate_add "$A" 61 READY approved "$H41" "$OLD"
prstate_add "$A" 62 BLOCKED_HUMAN head-not-reapproved "$H41" "$OLD"
sweep "$PA"
grep -q '"number":6[12]\|#6[12]"' <<<"$(grep 'PUT /api/pr-attempts\|PUT /api/ledger' "$H/writes.log" 2>/dev/null)" \
  && bad "E13: a ticket/* READY row and a BLOCKED_HUMAN row are never rewritten: $(W_)" || ok
[ -z "$(tsvrow "$A#61")$(tsvrow "$A#62")" ] && ok || bad "E13: no conductor row written for either: $(tsvrow "$A#61") $(tsvrow "$A#62")"

# ============================================================================
# E8. the hub cron: */30, gated on hub-lease.sh check, on the hub only
# ============================================================================
FR="$DIR/cron/lanes/412-pr-owner-sweep.cron"
grep -qx '# @hub-lanes' "$FR" 2>/dev/null && ok || bad "E8: the fragment must carry # @hub-lanes"
grep -v '^#' "$FR" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -q '^\*/30 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/pr-owner-sweep.sh' \
  && ok || bad "E8: the fragment's job line must start */30 … hub-lease.sh check && …pr-owner-sweep.sh: $(grep -v '^#' "$FR" 2>/dev/null)"
CR="$T/cron"; mkdir -p "$CR"
if bash "$DIR/bin/render-cron.sh" --root "$DIR" --out-dir "$CR" >/dev/null 2>&1; then
  grep -qF '*/30 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/pr-owner-sweep.sh' "$CR/hub.cron" && ok \
    || bad "E8: the hub cron must run the sweep every 30 min behind hub-lease.sh check: $(grep pr-owner "$CR/hub.cron")"
  OTHER=$(grep -l 'pr-owner-sweep.sh' "$CR"/*.cron 2>/dev/null | grep -v '/hub.cron$')
  [ -z "$OTHER" ] && ok || bad "E8: no box but the hub runs the sweep: $OTHER"
else
  bad "E8: bin/render-cron.sh --root --out-dir failed"
fi

# ============================================================================
# E9. a keyed conductor run evaluates an enrolled PR harness_pr_list filters out
# ============================================================================
C="$T/c"; CS=example-org/demo-os; CH=$(sha e); CHOLD=$(sha f); C88=$(sha 9)
mkdir -p "$C/bin" "$C/logs" "$C/state" "$C/flags" "$C/locks" "$C/builds" "$C/env" "$C/w"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/jobs-client.sh" "$C/bin/"; cp -R "$DIR/bin/lib" "$C/bin/"
[ -f "$C/bin/lib/jobs/queue.sh" ] || { echo "fixture: bin/lib/jobs/*.sh missing beside the copied jobs-client.sh"; exit 1; }
# gh-limit-logger.sh defines its own gh() wrapper, which would shadow the list bridge
# sourced below; tests/conductor-block-gate-test.sh does not carry it either.
rm -f "$C/bin/lib/gh-limit-logger.sh"
ln -sf "$DIR/bin/fleet-conf.sh" "$C/bin/fleet-conf.sh"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$C/bin/agent-call.sh"; chmod +x "$C/bin/agent-call.sh"
: > "$C/env/global.env"
printf 'demo-os %s https://demo.example - 2 box-demo\n' "$CS" > "$C/fleet.conf"
mkdir -p "$T/cbin"; cp "$T/fakebin/restpr" "$T/fakebin/curl" "$T/cbin/"
cat > "$T/cbin/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$C/gh-calls.log"
case "\$*" in
  *"pr merge"*|*"api -i -X PATCH"*|*"api -i -X POST"*|*"pr edit"*|*"pr comment"*) printf '%s\n' "\$*" >> "$C/gh-writes.log"; restpr --raw 500 '{"message":"refused"}'; exit 0 ;;
  *"api -i -X GET repos/$CS/pulls/77/"*) restpr --raw 200 '[]'; exit 0 ;;
  *"api -i -X GET repos/$CS/pulls/77"*)
    restpr --raw 200 '{"number":77,"state":"open","merged_at":null,"html_url":"https://github.com/$CS/pull/77","draft":false,"mergeable_state":"clean","mergeable":true,"labels":[],"title":"t","body":"an outside contribution","user":{"login":"collaborator-1","type":"User"},"updated_at":"2026-09-01T00:00:00Z","head":{"sha":"$CH","ref":"feature/x","repo":{"full_name":"$CS"}},"base":{"ref":"main","repo":{"full_name":"$CS"}}}'; exit 0 ;;
  *"api -i -X GET repos/$CS/pulls/88/"*) restpr --raw 200 '[]'; exit 0 ;;
  *"api -i -X GET repos/$CS/pulls/88"*)
    restpr --raw 200 '{"number":88,"state":"open","merged_at":null,"html_url":"https://github.com/$CS/pull/88","draft":false,"mergeable_state":"clean","mergeable":true,"labels":[],"title":"t","body":"a hand-made branch, no marker","user":{"login":"operator","type":"User"},"updated_at":"2026-09-01T00:00:00Z","head":{"sha":"$C88","ref":"feat/x","repo":{"full_name":"$CS"}},"base":{"ref":"main","repo":{"full_name":"$CS"}}}'; exit 0 ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success'; exit 0 ;;
  *"pr list -R $CS --state open"*) cat "$C/open.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
echo ""; exit 0
SH
chmod +x "$T/cbin/gh"
OPEN88='{"number":88,"url":"https://github.com/'"$CS"'/pull/88","headRefOid":"'"$C88"'","headRefName":"feat/x","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}'
echo "[$OPEN88]" > "$C/open.json"
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
ctick() {
  scratch_rm "$C/state/merge-conductor"; scratch_rm "$C/logs"; scratch_rm "$C/locks"; mkdir -p "$C/logs" "$C/locks"; rm -f "$C/gh-writes.log" "$C/reads.log"
  ( cd "$T" && PATH="$T/cbin:$PATH" HARNESS="$C" HARNESS_SECRET=s3cret JOBS_URL=https://jobs.test \
      MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_ONLY_PR="${CT_ONLY-$CS#77}" HARNESS_PR_AUTHORS=operator \
      timeout 120 bash "$C/bin/merge-conductor.sh" >/dev/null 2>"$T/ctick.err" ) || true
}
CML="$C/logs/merge-conductor.log"
# with the enrolled attempt row on the head
scratch_rm "$C/w/attempts"; mkdir -p "$C/w/attempts"; touch "$C/w/attempts/${CS//\//_}-77-enrolled-$CH"
ctick
grep -q "$CS#77 .*->" "$CML" 2>/dev/null && ok || bad "E9: an enrolled PR must reach the classifier in a keyed run: $(grep -i '#77\|keyed' "$CML" 2>/dev/null | tail -5) $(tail -3 "$T/ctick.err")"
grep -q "$CS#77 not a harness PR" "$CML" 2>/dev/null && bad "E9: an enrolled PR is not rejected as not-harness: $(grep '#77' "$CML")" || ok
grep -q "$CS#77 enrolled by pr-owner-sweep on ${CH:0:7}: evaluated as ours" "$CML" 2>/dev/null && ok || bad "E14a: pr_worker's pre-check accepts the enrolled external PR: $(grep '#77' "$CML" | head -5)"
[ ! -s "$C/gh-writes.log" ] || ! grep -q 'pr merge' "$C/gh-writes.log" && ok || bad "E9: the keyed run in observe mode merges nothing"
# the kill switch thrown AFTER enrollment: the row is still there, the PR is not
# evaluated (review r1: pr_owner.enroll_external=0 must stop the merge, too)
mkdir -p "$C/w/settings"; echo 0 > "$C/w/settings/pr_owner.enroll_external"
ctick
grep -q "$CS#77" <<<"$(grep -v "keyed tick\|external enrollment off" "$CML" 2>/dev/null)" && bad "E9: with pr_owner.enroll_external=0 an enrolled PR is not evaluated: $(grep '#77' "$CML")" || ok
grep -q "pr_owner.enroll_external=0 (row)" "$CML" 2>/dev/null && ok || bad "E9: the conductor logs the switch it read: $(grep -i enroll_external "$CML")"
# E12: the keyed run injects nothing for an EXTERNAL author under switch 0, and says why
grep -q "$CS#77: .*external enrollment off" "$CML" 2>/dev/null && ok || bad "E12: switch 0 logs external enrollment off for the external key: $(grep -i '#77' "$CML" | tail -3)"
# a settings outage reads the switch as off, not as the default. A whole tick
# cannot show it: an outage stands the repo down earlier (provider UNKNOWN), so
# mc_enroll_external_load is driven directly, over the real ph_knob.
rm -f "$C/w/settings/pr_owner.enroll_external"
# eel <setting_get rc> <row value> — prints what the conductor would read.
eel() { ( EEL_RC="$1"; EEL_V="$2"; MC_LOG="$T/eel.log"; : > "$MC_LOG"
          . "$DIR/bin/lib/pr-health.sh" || exit 9; . "$DIR/bin/lib/mc/classify.sh" || exit 9
          mc_log() { echo "$*" >> "$MC_LOG"; }
          setting_get() { printf '%s' "$EEL_V"; return "$EEL_RC"; }
          PR_OWNER_ENROLL_EXTERNAL=1 mc_enroll_external_load; echo "$MC_ENROLL_EXTERNAL" ) 2>/dev/null; }
[ "$(eel 1 '')" = 0 ] && ok || bad "E9: a settings outage must read the switch as off, env 1 notwithstanding: $(eel 1 '')"
grep -q "pr_owner.enroll_external=0 (outage)" "$T/eel.log" && ok || bad "E9: the outage is named as such: $(cat "$T/eel.log")"
[ "$(eel 2 '')" = 1 ] && ok || bad "E9: no row falls to the env/default like the sweep: $(eel 2 '')"
[ "$(eel 0 0)" = 0 ] && ok || bad "E9: a row of 0 wins over env 1: $(eel 0 0)"
[ "$(MC_ENROLL_EXTERNAL=1 _MC_EE_READ=1 eel 0 0)" = 0 ] && ok || bad "E9: an inherited MC_ENROLL_EXTERNAL must not stand in for the read"
# the switch back on: evaluated again
echo 1 > "$C/w/settings/pr_owner.enroll_external"
ctick
grep -q "$CS#77 .*->" "$CML" 2>/dev/null && ok || bad "E9: pr_owner.enroll_external=1 evaluates the enrolled PR: $(grep -i '#77\|enroll_external' "$CML" | tail -5)"
rm -f "$C/w/settings/pr_owner.enroll_external"
# without the row: never injected, no line for the key
scratch_rm "$C/w/attempts"; mkdir -p "$C/w/attempts"
ctick
grep -q "$CS#77" <<<"$(grep -v "keyed tick" "$CML" 2>/dev/null)" && bad "E9: without the attempt row the PR is not evaluated at all: $(grep '#77' "$CML")" || ok
# the row on an OLD head: ignored
touch "$C/w/attempts/${CS//\//_}-77-enrolled-$CHOLD"
ctick
grep -q "$CS#77" <<<"$(grep -v "keyed tick" "$CML" 2>/dev/null)" && bad "E9: an attempt row on an old head is ignored: $(grep '#77' "$CML")" || ok

# E9b. review F3: a harness-author ORPHAN on feat/x, enrolled on its head, switch 0,
# is accepted by the ordinary UNKEYED tick (not only a keyed one)
mkdir -p "$C/w/settings"; echo 0 > "$C/w/settings/pr_owner.enroll_external"
scratch_rm "$C/w/attempts"; mkdir -p "$C/w/attempts"; touch "$C/w/attempts/${CS//\//_}-88-enrolled-$C88"
CT_ONLY="" ctick
grep -q "$CS#88" "$CML" 2>/dev/null && ok || bad "E9b: the unkeyed tick must see #88 at all: $(tail -5 "$CML" 2>/dev/null) $(tail -3 "$T/ctick.err")"
grep -q "$CS#88 not a harness PR" "$CML" 2>/dev/null && bad "E9b: an enrolled ORPHAN must not be ignored as not-harness under switch 0: $(grep '#88' "$CML")" || ok
# …and without its attempt row it is (the line above is not vacuous)
scratch_rm "$C/w/attempts"; mkdir -p "$C/w/attempts"
CT_ONLY="" ctick
grep -q "$CS#88 not a harness PR" "$CML" 2>/dev/null && ok || bad "E9b: without the attempt row #88 is not a harness PR: $(grep '#88' "$CML" | tail -3)"
rm -f "$C/w/settings/pr_owner.enroll_external"

# ============================================================================
# E14 (r3). pr_worker's enrolled pre-check wraps the harness pr probe: a
#     ticket/* PR never pays the attempt read, a feature PR does, and a miss
#     falls through to the unchanged probe.
# ============================================================================
C99=$(sha 8)
echo "[$OPEN88,"'{"number":99,"url":"https://github.com/'"$CS"'/pull/99","headRefOid":"'"$C99"'","headRefName":"ticket/bh-1","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]' > "$C/open.json"
scratch_rm "$C/w/attempts"; mkdir -p "$C/w/attempts"
touch "$C/w/attempts/${CS//\//_}-88-enrolled-$C88" "$C/w/attempts/${CS//\//_}-99-enrolled-$C99"
CT_ONLY="" ctick
grep -q "$CS#88 enrolled by pr-owner-sweep on ${C88:0:7}" "$CML" 2>/dev/null && ok || bad "E14a: an enrolled feature PR is evaluated as ours: $(grep '#88' "$CML" | head -3) $(tail -3 "$T/ctick.err")"
grep -q "$CS#99" "$CML" 2>/dev/null && ok || bad "E14b: the ticket/* PR must reach pr_worker at all: $(tail -5 "$CML" 2>/dev/null)"
grep -q "$CS#99 enrolled by\|$CS#99 not a harness PR" "$CML" 2>/dev/null && bad "E14b: a ticket/* PR is ours by branch, never by enrollment: $(grep '#99' "$CML")" || ok
grep -q 'number=99' <<<"$(grep 'pr-attempts' "$C/reads.log" 2>/dev/null)" && bad "E14b: a ticket/* PR must not read /api/pr-attempts: $(grep 'number=99' "$C/reads.log")" || ok
grep 'pr-attempts' "$C/reads.log" 2>/dev/null | grep 'number=88' | grep -q 'enrolled' && ok || bad "E14b: …while the feature PR's pre-check does read it (the line above is not vacuous): $(grep pr-attempts "$C/reads.log" 2>/dev/null | head -3)"
# (c) the same feature PR with no attempt row: the probe runs unchanged
scratch_rm "$C/w/attempts"; mkdir -p "$C/w/attempts"
CT_ONLY="" ctick
grep -q "$CS#88 not a harness PR" "$CML" 2>/dev/null && ok || bad "E14c: without the attempt row the probe says not a harness PR: $(grep '#88' "$CML" | tail -3)"
grep -q "$CS#88 enrolled by" "$CML" 2>/dev/null && bad "E14c: no row, no enrollment line: $(grep '#88' "$CML")" || ok
echo "[$OPEN88]" > "$C/open.json"

echo "pr-owner-enroll: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
