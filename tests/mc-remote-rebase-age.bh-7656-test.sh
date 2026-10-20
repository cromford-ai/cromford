#!/bin/bash
# tests/mc-remote-rebase-age.bh-7656-test.sh — BH-7656: a pool rebase row's
# stale bound counts from the claim (the gate just before the machine starts),
# not from the enqueue, and a live machine for the key blocks the hand-back to
# the hub. Lane-run half: mc_remote_rebase_row / mc_rebase_spawn
# (bin/lib/mc/spawn-remote.sh) over the REAL jobs client and a fake curl that is
# a small jobs worker (GET /api/settings/<key>, GET /api/queue, POST /api/queue,
# GET /api/machines with the project, key and live=1 filters of
# worker/jobs/src/routes/machines.js). Hub half: the REAL mc_rb_state over a
# scratch state/fly-pool/ tree.
#
#   R1-R8c  the age clock (DR1); R1 also through mc_rebase_spawn (D2)
#   M1-M9   the live-machine guard on a row past the bound (DR2); M1 also
#           through mc_rebase_spawn
#   H1-H5   the hub: a pool job file past the bound with a pool machine json
#   P1      replay 2026-10-20 01:54Z: RB-1957 and RB-1975, two ticks in the
#           conductor's order, 0 hand-backs; P1b the same rows with no
#           claimed_at and no registry rows hand both back (today's rule)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-remote-rebase-age.bh-7656-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v flock >/dev/null || { echo "SKIP: jq or flock missing"; exit 0; }

export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/env" "$T/h/builds" "$T/fakebin" "$T/store" "$T/settings" "$T/machines"
for L in bin/lib/merge-conductor-lib.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$T/h" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"

SLUG=example-org/demo-os
PROJ=demo-os
HEAD=3131313131313131313131313131313131313131
URL="https://github.com/$SLUG/pull/31"
BR=ticket/TK-31
RBKEY=RB-31-31313131
REQ="$T/req.txt"; DEF="$T/def.txt"

# --- the fake curl: a stateful jobs worker -----------------------------------
# Queue rows are one JSON file per (project, key) under $T/store; registry rows
# one JSON file per machine under $T/machines. Faults by marker file:
#   machines-down  GET /api/machines is a transport failure (exit 7)
#   machines-404   GET /api/machines answers 404 (an older worker)
#   machines-bad   GET /api/machines answers 200 with no machines array
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
U="\${!#}"; M=GET; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
P="/\${U#*://*/}"
printf '%s %s %s\n' "\$M" "\$P" "\$BODY" >> "$REQ"
q() { local v="\${P#*\?}"; v="&\$v"; v="\${v#*&\$1=}"; [ "\$v" = "&\$P" ] && return; printf '%s' "\${v%%&*}"; }
case "\$M \$P" in
  "GET /api/settings/"*)
    k="\${P#/api/settings/}"
    if [ -f "$T/settings/\$k" ]; then jq -nc --arg k "\$k" --arg v "\$(cat "$T/settings/\$k")" '{setting:{key:\$k,value:\$v}}'; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET /api/queue?"*)
    f="$T/store/\$(q project)__\$(q key).json"
    if [ -f "\$f" ]; then out=\$(jq -c '{queue:[.]}' "\$f"); else out='{"queue":[]}'; fi
    printf '%s\n200\n' "\$out" ;;
  "POST /api/queue")
    p=\$(jq -r .project <<<"\$BODY"); k=\$(jq -r .key <<<"\$BODY"); f="$T/store/\${p}__\${k}.json"
    if [ -f "\$f" ] && jq -e '.status == "queued" or .status == "claimed"' "\$f" >/dev/null; then
      jq -c '{queued:., duplicate:true}' "\$f"; printf '200\n'; exit 0
    fi
    jq -c '{project, ticket_key:.key, ticket_id, status:"queued", target, attempt:0,
        enqueued_at:(1900000000 | todate), reason:null, meta}' <<<"\$BODY" > "\$f"
    jq -c '{queued:., duplicate:false}' "\$f"; printf '201\n' ;;
  "GET /api/machines?"*)
    [ -e "$T/machines-down" ] && exit 7
    [ -e "$T/machines-404" ] && { printf '{"error":"not found"}\n404\n'; exit 0; }
    [ -e "$T/machines-bad" ] && { printf '{"rows":[]}\n200\n'; exit 0; }
    jq -sc --arg p "\$(q project)" --arg k "\$(q key)" --arg live "\$(q live)" \
      '{machines: [ .[] | select(\$p == "" or .project == \$p) | select(\$k == "" or .key == \$k)
                         | select(\$live != "1" or ((.state == "destroyed" or .state == "gone") | not)) ]
                  | sort_by(.updated_at) | reverse}' $T/machines/*.json 2>/dev/null \
      || printf '{"machines":[]}'
    printf '\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/git"; printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin/git" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS_SECRET=fixture-harness-secret JOBS_URL="https://jobs.example"
export JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_SETTINGS_CACHE_S=0 ROUTING_ROWS=off
printf 'harness-pool-demo-os-fixture\n' > "$T/h/flags/fly-pool-app-$PROJ"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$T/h/bin/jobs-client.sh"; set +o pipefail
P="$PROJ"
# The pinned clock (D60).
NOW=1900000000
mc_now() { echo "$NOW"; }
printf '1' > "$T/settings/conductor_remote_spawn"

reset() { rm -f "$T/store/"*.json "$T/machines/"*.json "$T/machines-down" "$T/machines-404" "$T/machines-bad"
          : > "$REQ"; : > "$DEF"; : > "$MC_LOG"; : > "$T/h/logs/ALERTS.log"; }
# seedrow <key> <status> <enqueued-age|none> <claimed-age|none|raw:<text>>
seedrow() { jq -nc --arg k "$1" --arg s "$2" --arg e "$3" --arg c "$4" --argjson now "$NOW" \
  '{project:"demo-os",ticket_key:$k,ticket_id:"31",status:$s,target:"fly",attempt:0,
    enqueued_at:(if $e == "none" then null else ($now - ($e | tonumber) | todate) end),
    claimed_at:(if $c == "none" then null elif ($c | startswith("raw:")) then ($c | ltrimstr("raw:"))
                else ($now - ($c | tonumber) | todate) end),
    reason:null,meta:null}' > "$T/store/${PROJ}__$1.json"; }
seed() { seedrow "$RBKEY" "$@"; }
# machine <id> <key> <state> — one registry row, as PUT /api/machines stores it.
machine() { jq -nc --arg m "$1" --arg k "$2" --arg s "$3" --argjson now "$NOW" \
  '{machine_id:$m,project:"demo-os",app:"harness-pool-demo-os-fixture",role:"pool",key:$k,state:$s,updated_at:($now|todate)}' \
  > "$T/machines/$1.json"; }
row() { mc_remote_rebase_row "$PROJ" 31 "$HEAD" 2>/dev/null; }
outc() { local r; r=$(row); printf '%s' "${r%%$'\t'*}"; }
mreqs() { grep -c '^GET /api/machines' "$REQ"; }
qposts() { grep -c '^POST /api/queue ' "$REQ"; }
words() { tr '\n' ' ' < "$DEF" | sed 's/ $//'; }
alerts() { grep -c . "$T/h/logs/ALERTS.log"; }
spawn() { ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"
            mc_rebase_spawn "$SLUG" 31 "$PROJ" "$BR" "$HEAD" "$URL" ) >/dev/null 2>&1; echo $?; }

# ── R: the age clock (no live machine: the registry answers []) ─────────────
reset; seed claimed 6000 600
[ "$(outc)" = running ] && ok || bad "R1 claimed: enqueued 6000s, claimed 600s -> running (got $(row))"
[ "$(row)" = "running	0	claimed 600s ago" ] && ok || bad "R1 the detail names the claim and its age (got $(row))"
[ "$(mreqs)" = 0 ] && ok || bad "R1 a row inside the bound reads no registry (got $(mreqs))"
reset; seed claimed 6000 600
RC=$(spawn)
[ "$RC" = 0 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "R1 through mc_rebase_spawn: rc 0, no put, no hand-back (rc $RC, '$(words)')"
grep -q "in flight (claimed 600s ago)" "$MC_LOG" && ok || bad "R1 the in-flight line names the claim age ($(cat "$MC_LOG"))"
reset; seed claimed 9000 5399
[ "$(outc)" = running ] && ok || bad "R2 claimed 5399s -> running (got $(row))"
reset; seed claimed 60 none
[ "$(outc)" = running ] && ok || bad "R3 claimed, no claimed_at, enqueued 60s -> running (got $(row))"
reset; seed queued 5399 none
[ "$(outc)" = running ] && ok || bad "R4 queued 5399s -> running (got $(row))"
reset; seedrow "$RBKEY" claimed 6000 "raw:$(jq -nr --argjson n "$((NOW - 600))" '$n | todate | sub("Z$"; ".123Z")')"
[ "$(outc)" = running ] && ok || bad "R5 claimed_at with fractional seconds -> running (got $(row))"
reset; seed claimed 9000 5400
[ "$(row)" = "stale	0	claimed 5400s" ] && ok || bad "R6 claimed 5400s, no machine -> stale (got $(row))"
[ "$(mreqs)" = 1 ] && ok || bad "R6 a row past the bound reads the registry once (got $(mreqs))"
reset; seed claimed 5400 none
[ "$(outc)" = stale ] && ok || bad "R7 claimed, no claimed_at, enqueued 5400s -> stale (got $(row))"
reset; seed queued 6000 none
[ "$(outc)" = stale ] && ok || bad "R8 queued 6000s -> stale (got $(row))"
reset; seed claimed none none
[ "$(row)" = "stale	0	claimed no enqueued_at" ] && ok || bad "R8b no time at all -> stale (got $(row))"
reset; seedrow "$RBKEY" claimed 6000 raw:garbage
[ "$(row)" = "stale	0	claimed 6000s" ] && ok || bad "R8c an unparseable claimed_at falls back to the enqueue -> stale (got $(row))"

# ── M: the live-machine guard, on a row past the bound ──────────────────────
reset; seed claimed 9000 6000; machine m-started-fixture "$RBKEY" started
[ "$(row)" = "running	0	claimed past the bound, machine m-started-fixture live (started)" ] && ok || bad "M1 a started machine holds the row (got $(row))"
grep -q "GET /api/machines?project=demo-os&key=$RBKEY&live=1 " "$REQ" && ok || bad "M1 the registry read names project, key and live=1 ($(grep machines "$REQ"))"
: > "$REQ"; RC=$(spawn)
[ "$RC" = 0 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "M1 through mc_rebase_spawn: rc 0, no hand-back (rc $RC, '$(words)')"
grep -q "in flight (claimed past the bound, machine m-started-fixture live (started))" "$MC_LOG" && ok || bad "M1 the in-flight line names the machine and its state ($(cat "$MC_LOG"))"
reset; seed claimed 9000 6000; machine m-stopped-fixture "$RBKEY" stopped
[ "$(row)" = "running	0	claimed past the bound, machine m-stopped-fixture live (stopped)" ] && ok || bad "M2 an autostopped, unreaped machine holds the row (got $(row))"
reset; seed claimed 9000 6000; machine m-df-fixture "$RBKEY" destroy_failed
[ "$(outc)" = running ] && ok || bad "M3 destroy_failed holds the row (got $(row))"
reset; seed claimed 9000 6000; : > "$T/machines-down"
[ "$(row)" = "running	0	claimed past the bound, machine lookup failed" ] && ok || bad "M4 a registry transport failure holds the row (got $(row))"
reset; seed claimed 9000 6000; : > "$T/machines-down"; RC=$(spawn)
[ "$RC" = 0 ] && [ -z "$(words)" ] && [ "$(alerts)" = 0 ] && ok || bad "M4 no hand-back and 0 ALERTS lines (rc $RC, '$(words)', alerts $(alerts))"
reset; seed claimed 9000 6000; : > "$T/machines-bad"
[ "$(row)" = "running	0	claimed past the bound, machine lookup failed" ] && ok || bad "M5 a body with no machines array holds the row (got $(row))"
reset; seed claimed 9000 6000
[ "$(outc)" = stale ] && ok || bad "M6 {\"machines\":[]} -> stale (got $(row))"
reset; seed claimed 9000 6000; : > "$T/machines-404"
[ "$(outc)" = stale ] && ok || bad "M7 a 404 (older worker) -> stale (got $(row))"
reset; seed claimed 9000 6000; machine m-other-fixture RB-31-42424242 started
[ "$(outc)" = stale ] && ok || bad "M8 a live machine for another head of the PR does not hold (got $(row))"
reset; seed claimed 9000 6000; machine m-gone-fixture "$RBKEY" destroyed
[ "$(outc)" = stale ] && ok || bad "M9 a destroyed machine does not hold (got $(row))"
reset; seed claimed 9000 6000; RC=$(spawn)
[ "$RC" = 3 ] && [ "$(words)" = rebase ] && ok || bad "M6 through mc_rebase_spawn: no machine -> the hand-back (rc $RC, '$(words)')"

# ── H: the hub, mc_rb_state over state/fly-pool/ ────────────────────────────
POOLD="$T/h/state/fly-pool/$PROJ"
hubfile() { # hubfile <age-s> -> the job file path, a pool job started <age-s> ago
  local f; f=$(mc_rb_file "$SLUG" 31 "$HEAD")
  mc_rb_write "$f" pool 0 "$((NOW - $1))" 0 - "$HEAD" - "${f%.json}.out"; printf '%s' "$f"; }
hreset() { rm -rf "$T/h/state/fly-pool"; mkdir -p "$POOLD"; rm -f "$MC_RB_DIR"/*.json; }
hreset; F=$(hubfile 6000)
printf '{"machine":"m1-fixture","key":"%s","ticket_id":"31"}\n' "$RBKEY" > "$POOLD/m1-fixture.json"
[ "$(mc_rb_state "$F")" = running ] && ok || bad "H1 past the bound with a pool json for the key -> running (got $(mc_rb_state "$F"))"
hreset; F=$(hubfile 6000)
[ "$(mc_rb_state "$F")" = stale ] && ok || bad "H2 past the bound, no pool json -> stale (got $(mc_rb_state "$F"))"
hreset; F=$(hubfile 6000)
printf '{"machine":"m2-fixture","key":"RB-31-42424242","ticket_id":"31"}\n' > "$POOLD/m2-fixture.json"
[ "$(mc_rb_state "$F")" = stale ] && ok || bad "H3 a pool json for another head8 -> stale (got $(mc_rb_state "$F"))"
hreset; F=$(hubfile 6000)
printf 'not json' > "$POOLD/a-bad-fixture.json"
printf '{"machine":"m1-fixture","key":"%s","ticket_id":"31"}\n' "$RBKEY" > "$POOLD/m1-fixture.json"
[ "$(mc_rb_state "$F")" = running ] && ok || bad "H4 an unreadable json next to a matching one -> running (got $(mc_rb_state "$F"))"
hreset; F=$(hubfile 60)
[ "$(mc_rb_state "$F")" = running ] && ok || bad "H5 a pool file 60s old -> running (got $(mc_rb_state "$F"))"
hreset

# ── P1: replay 2026-10-20 01:54Z ────────────────────────────────────────────
# RB-1957 and RB-1975 were queued 23:49Z the day before, claimed 01:23:16Z, and
# their machines (8e100ec7349e98 started, 7812062b647718 stopped) still ran at
# 01:54Z, when the conductor handed both back to the hub.
NOW=$(jq -nr '"2026-10-20T01:54:00Z" | fromdateiso8601')
ENQ=$(( NOW - $(jq -nr '"2026-10-19T23:49:00Z" | fromdateiso8601') ))
CLM=$(( NOW - $(jq -nr '"2026-10-20T01:23:16Z" | fromdateiso8601') ))
H1957=1957195719571957195719571957195719571957
H1975=1975197519751975197519751975197519751975
K1957="RB-1957-${H1957:0:8}"; K1975="RB-1975-${H1975:0:8}"
# tick <pr> <head> — one conductor tick in bin/merge-conductor.sh order:
# rebase_consume, then the NEEDS_REBASE arm's mark guard and the spawn.
tick() { local n="$1" h="$2" k="$SLUG#$1"
         ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"
           rebase_consume "$k" "$SLUG" "$n" "https://github.com/$SLUG/pull/$n" - "$h" - - DIRTY && exit 0
           mc_attempt_has "rebase $k $h" 2>/dev/null && exit 0
           mc_rebase_spawn "$SLUG" "$n" "$PROJ" "ticket/pb-$n" "$h" "https://github.com/$SLUG/pull/$n"; rc=$?
           [ "$rc" = 0 ] && mc_attempt_put "rebase $k $h"
           exit 0 ) >/dev/null 2>&1; }
marked() { ( mc_attempt_has "rebase $SLUG#$1 $2" ) 2>/dev/null; }
replay() { # replay <claimed-age|none> <registry 1|0>
  reset
  seedrow "$K1957" claimed "$ENQ" "$1"; seedrow "$K1975" claimed "$ENQ" "$1"
  if [ "$2" = 1 ]; then machine 8e100ec7349e98 "$K1957" started; machine 7812062b647718 "$K1975" stopped; fi
}
# The marks stand, as they do after the spawn that queued the rows.
replay "$CLM" 1
mc_attempt_put "rebase $SLUG#1957 $H1957"; mc_attempt_put "rebase $SLUG#1975 $H1975"
tick 1957 "$H1957"; tick 1975 "$H1975"
[ -z "$(words)" ] && [ "$(qposts)" = 0 ] && ok || bad "P1 marks standing: 0 hand-backs, 0 puts ('$(words)', posts $(qposts))"
marked 1957 "$H1957" && marked 1975 "$H1975" && ok || bad "P1 both marks stand"
# No marks: the spawn runs and reads the rows as in flight.
replay "$CLM" 1
mc_attempt_clear rebase "$SLUG#1957" "$H1957"; mc_attempt_clear rebase "$SLUG#1975" "$H1975"
tick 1957 "$H1957"; tick 1975 "$H1975"
[ -z "$(words)" ] && [ "$(qposts)" = 0 ] && ok || bad "P1 no marks: 0 hand-backs, 0 puts ('$(words)', posts $(qposts))"
[ "$(grep -c 'in flight' "$MC_LOG")" = 2 ] && ok || bad "P1 exactly 2 in-flight lines ($(cat "$MC_LOG"))"
[ "$(alerts)" = 0 ] && ok || bad "P1 0 ALERTS lines ($(cat "$T/h/logs/ALERTS.log"))"
# The guard alone saves them: no claimed_at (today's enqueue clock) + live machines.
replay none 1
mc_attempt_clear rebase "$SLUG#1957" "$H1957"; mc_attempt_clear rebase "$SLUG#1975" "$H1975"
tick 1957 "$H1957"; tick 1975 "$H1975"
[ -z "$(words)" ] && ok || bad "P1 enqueue clock, live machines: 0 hand-backs ('$(words)')"
grep -q "machine 8e100ec7349e98 live (started)" "$MC_LOG" && grep -q "machine 7812062b647718 live (stopped)" "$MC_LOG" \
  && ok || bad "P1 the lines name both machines ($(cat "$MC_LOG"))"
# P1b: no claimed_at and no registry rows -> today's rule hands both back.
replay none 0
mc_attempt_put "rebase $SLUG#1957 $H1957"; mc_attempt_put "rebase $SLUG#1975 $H1975"
tick 1957 "$H1957"; tick 1975 "$H1975"
[ "$(words)" = "rebase rebase" ] && ok || bad "P1b no claim time, no machine: both handed back ('$(words)')"
mc_attempt_clear rebase "$SLUG#1957" "$H1957"; mc_attempt_clear rebase "$SLUG#1975" "$H1975"

echo "mc-remote-rebase-age.bh-7656: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
