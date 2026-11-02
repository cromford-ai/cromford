#!/bin/bash
# tests/box-ops-orgo-host.bh-8325-test.sh — `bin/box-ops.sh stop|restart|retire
# <id> --host <name>` (BH-8325): the Orgo host is named, not derived from a box
# id that a second box now shares (BH-8322: the new Fly box keeps the old id).
#
# Runs the REAL bin/box-ops.sh, bin/lib/box-ops-orgo.sh, the Orgo seam,
# bin/fleet-conf.sh and bin/box-for.sh in a scratch repo root ($R, with a git
# origin) and a scratch harness root ($H). Stubbed: curl (plays Orgo and the
# jobs worker's PUT /api/flags), bin/box-name.sh and bin/box-register.sh.
# Every call lands in $T/seq.log in the order it was made.
#   H1  stop --host node-oldbox dry run: names that host's computer, no pause
#   H2  stop --host --apply: POST stop for the --host computer, no flag PUT
#   H3  a state file whose .host is another box is skipped (GET by name)
#   H4  retire --host, no --delete, shared id: exit 2, box-register never runs
#   H5  retire --host, no --delete, id not shared: as without --host
#   H6  retire --host --delete --apply, shared id on origin/main: DELETE sent
#   H7  retire --host --delete --apply, origin/main fleet.conf names the host: WAITING
#   H8  the other box with the id is retired: the cron dir check stays (WAITING)
#   H9  no --host: today's host (the shared id's box) and its projects; a bad
#       --host value is exit 2; --host on resize is a usage error
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2] $(ctx)"; fi; }

R="$T/repo"; H="$T/h"
mkdir -p "$R/bin" "$R/catalog" "$H/env" "$T/fakebin" "$T/orgo"
for s in bin/box-ops.sh bin/lib/box-ops-orgo.sh bin/fleet-conf.sh bin/box-for.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$R" >/dev/null || { echo "FAIL: closure install $s"; exit 1; }
done
: > "$H/env/global.env"
printf '{"accounts": {}}\n' > "$R/catalog/orgo-plans.json"
printf '{"box_aliases": {}, "accounts": {}}\n' > "$R/catalog/cost-accounts.json"
printf '#!/bin/bash\necho node-selfbox\n' > "$R/bin/box-name.sh"
cat > "$R/bin/box-register.sh" <<'EOF'
#!/bin/bash
printf 'REG %s\n' "$*" >> "$STUB_DIR/seq.log"
exit 0
EOF
chmod +x "$R/bin/box-name.sh" "$R/bin/box-register.sh"

# The working tree after the cut-over: pa runs on node-newbox, which keeps the
# box id oldbox; the Orgo computer node-oldbox has no project row.
G() { git -C "$R" -c user.name=fixture -c user.email=fixture@example.com "$@"; }
SHARED='# @boxrole node-newbox oldbox build
pa acme/pa - - 1 node-newbox 192.0.2.77
pc acme/pc - - 1 node-other 192.0.2.78'
printf 'state/\n' > "$R/.gitignore"
printf '%s\n' "$SHARED" > "$R/fleet.conf"
mkdir -p "$R/cron/boxes/oldbox.d" && printf '# the new box list\n' > "$R/cron/boxes/oldbox.d/000-path.cron"
G init -q -b main && G add -A && G commit -qm shared || { echo "FAIL: git fixture"; exit 1; }
for o in shared names retired; do git init -q --bare "$T/origin-$o.git"; done
G push -q "$T/origin-shared.git" main || exit 1
printf '%s\npo acme/po - - 1 node-oldbox 192.0.2.5\n' "$SHARED" > "$R/fleet.conf"
G commit -qam names && G push -q "$T/origin-names.git" main || exit 1
printf '# @boxrole node-newbox oldbox retired\npc acme/pc - - 1 node-other 192.0.2.78\n' > "$R/fleet.conf"
G commit -qam retired && G push -q "$T/origin-retired.git" main || exit 1
G reset -q --hard HEAD~2 || exit 1
G remote add origin "$T/origin-shared.git" || exit 1

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET url="" body="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift ;;
    --data-binary) data=$2; shift ;;
    -m|-H|-w|--connect-timeout) shift ;;
    http*) url=$1 ;;
  esac
  shift
done
case "$data" in "") ;; @-) body=$(cat) ;; *) body=$data ;; esac
O="$STUB_DIR/orgo"
case "$url" in
  https://jobs.fixture/*)
    n=$(jq -r '.name // empty' <<< "$body" 2>/dev/null)
    printf '%s /%s %s\n' "$m" "${url#https://jobs.fixture/}" "$n" >> "$STUB_DIR/seq.log"
    printf '%s\n%s' "$(jq -nc --arg n "$n" '{flag:{name:$n, active:true, updated_at:"2026-10-10T00:00:00Z"}}')" 200
    exit 0 ;;
esac
p=${url#https://orgo.fixture/api}
printf '%s %s\n' "$m" "$p" >> "$STUB_DIR/seq.log"
case "$m $p" in
  "GET /computers") printf '%s\n%s' "$(cat "$O"/c-*.json | jq -sc .)" 200 ;;
  "GET /computers/"*)
    f="$O/${p#/computers/}.json"
    if [ -f "$f" ]; then printf '%s\n%s' "$(cat "$f")" 200; else printf '%s\n%s' '{"error":"not found"}' 404; fi ;;
  "POST /computers/"*/stop|"POST /computers/"*/restart)
    i=${p#/computers/}; i=${i%/*}; s=stopped; [ "${p##*/}" = restart ] && s=running
    jq --arg s "$s" '.status = $s' "$O/$i.json" > "$O/t" && mv "$O/t" "$O/$i.json"
    printf '%s\n%s' '{"ok":true}' 200 ;;
  "DELETE /computers/"*) rm -f "$O/${p#/computers/}.json"; printf '%s\n%s' '{"ok":true}' 200 ;;
  *) printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_BOX_PREFIX=node- \
       ORGO_API_BASE=https://orgo.fixture/api BOX_LAUNCH_POLL_S=1 BOX_LAUNCH_DEADLINE_S=5 \
       JOBS_URL=https://jobs.fixture HARNESS_SECRET=fixture-jobs-secret JOBS_RETRIES=0 \
       ORGO_API_KEY=sk-fixture-8325
unset REGISTRY_SOURCE FLEET_CONF
SEQ="$T/seq.log"

reset() {
  for d in "$H/state" "$H/logs" "$H/locks" "$H/flags" "$SEQ" "$T/orgo"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$H/state/box-launch" "$H/logs" "$T/orgo"
  printf '{"id":"c-old","name":"node-oldbox","status":"running"}\n' > "$T/orgo/c-old.json"
  printf '{"id":"c-wrong","name":"node-newbox-orgo","status":"running"}\n' > "$T/orgo/c-wrong.json"
  G remote set-url origin "$T/origin-shared.git"
  G checkout -q -- . && G clean -qfd -e state/
}
run() { bash "$R/bin/box-ops.sh" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
n() { [ -f "$2" ] || { echo 0; return; }; grep -cE "$1" "$2"; return 0; }
lastl() { tail -n 1 "$T/out"; }
ctx() { echo "rc=${RC:-} out=[$(cat "$T/out" 2>/dev/null)] err=[$(cat "$T/err" 2>/dev/null)] seq=[$(tr '\n' ';' 2>/dev/null < "$SEQ")]"; }

# --- H1 stop --host dry run ----------------------------------------------------
reset
run stop oldbox --host node-oldbox
check H1-rc "$RC" 0
check H1-plan "$(n '^PLAN stop POST /computers/c-old/stop$' "$T/out")" 1
check H1-no-pause "$(n 'paused-' "$T/out")" 0
check H1-no-project "$(n '^stop: no project on oldbox$' "$T/out")" 1
check H1-no-post "$(n '^POST ' "$SEQ")" 0

# --- H2 stop --host --apply -----------------------------------------------------
reset
run stop oldbox --host node-oldbox --apply
check H2-rc "$RC" 0
check H2-post "$(n '^POST /computers/c-old/stop$' "$SEQ")" 1
check H2-no-flag-put "$(n '^PUT /api/flags' "$SEQ")" 0
check H2-no-pause-file "$(ls "$H/flags" 2>/dev/null | grep -c paused-)" 0
check H2-stopped "$(jq -r .status "$T/orgo/c-old.json")" stopped
check H2-summary "$(lastl)" "box-ops: verb=stop box=oldbox orgo=c-old result=OK stopped"

# --- H3 a state file with another host is skipped -------------------------------
reset
printf '{"id":"oldbox","orgo_id":"c-wrong","host":"node-newbox"}\n' > "$H/state/box-launch/oldbox.json"
run stop oldbox --host node-oldbox --apply
check H3-rc "$RC" 0
check H3-get-list "$(n '^GET /computers$' "$SEQ")" 1
check H3-right-computer "$(n '^POST /computers/c-old/stop$' "$SEQ")" 1
check H3-not-wrong "$(n 'c-wrong/stop' "$SEQ")" 0
check H3-note "$(n 'names host node-newbox, not node-oldbox; skipped' "$T/out")" 1
# The same file with the --host name is used (no list read).
reset
printf '{"id":"oldbox","orgo_id":"c-old","host":"node-oldbox"}\n' > "$H/state/box-launch/oldbox.json"
run restart oldbox --host node-oldbox --apply
check H3-restart-rc "$RC" 0
check H3-state-used "$(n '^GET /computers$' "$SEQ")" 0
check H3-restart-post "$(n '^POST /computers/c-old/restart$' "$SEQ")" 1

# --- H4 retire --host, no --delete, shared id ------------------------------------
reset
for a in "" --apply; do
  run retire oldbox --host node-oldbox $a
  check "H4-rc$a" "$RC" 2
  check "H4-says$a" "$(n 'box id oldbox also belongs to node-newbox' "$T/err")" 1
done
check H4-no-register "$(n '^REG ' "$SEQ")" 0
check H4-tree-clean "$(G status --porcelain -- fleet.conf cron | wc -l)" 0

# --- H5 retire --host, no --delete, id not shared ---------------------------------
reset
printf '# @boxrole node-newbox oldbox retired\npc acme/pc - - 1 node-other 192.0.2.78\n' > "$R/fleet.conf"
run retire oldbox --host node-oldbox --apply
check H5-rc "$RC" 0
check H5-register "$(n '^REG --retire oldbox ' "$SEQ")" 1
check H5-state-host "$(jq -r .host "$H/state/box-ops/oldbox.json")" node-oldbox

# --- H6 --delete --apply, shared id on origin/main --------------------------------
reset
run retire oldbox --host node-oldbox --delete --apply
check H6-rc "$RC" 0
check H6-delete "$(n '^DELETE /computers/c-old$' "$SEQ")" 1
check H6-note "$(n 'retire: box id oldbox belongs to node-newbox on origin/main; cron/boxes/oldbox.d is its list, not checked' "$T/out")" 1
check H6-no-waiting "$(n 'WAITING' "$T/out")" 0
check H6-summary "$(lastl)" "box-ops: verb=retire box=oldbox orgo=c-old result=OK deleted"

# --- H7 --delete --apply, origin/main still names the host ------------------------
reset; G remote set-url origin "$T/origin-names.git"
run retire oldbox --host node-oldbox --delete --apply
check H7-rc "$RC" 4
check H7-waiting "$(n '^WAITING: origin/main still has the box \(fleet.conf names node-oldbox\)' "$T/out")" 1
check H7-no-delete "$(n '^DELETE ' "$SEQ")" 0

# --- H8 the other box with the id is retired: cron dir check stays ----------------
reset; G remote set-url origin "$T/origin-retired.git"
# origin-retired has no cron dir commit of its own: it carries the shared one.
run retire oldbox --host node-oldbox --delete --apply
check H8-rc "$RC" 4
check H8-waiting "$(n '^WAITING: origin/main still has the box \(cron/boxes/oldbox.d exists\)' "$T/out")" 1
check H8-no-delete "$(n '^DELETE ' "$SEQ")" 0

# --- H9 no --host: today's behavior; bad values -----------------------------------
reset
# A dry run with no key reads no computer list (today's dry run).
unset ORGO_API_KEY
run stop oldbox
check H9-rc "$RC" 0
check H9-today-pause "$(n '^PLAN pause paused-pa$' "$T/out")" 1
run retire oldbox --delete
check H9-retire-dry-rc "$RC" 0
check H9-retire-dry "$(n '^PLAN delete DELETE /computers/<orgo-id> after origin/main no longer names node-newbox$' "$T/out")" 1
check H9-retire-dry-register "$(n '^PLAN retire bin/box-register.sh --retire oldbox ' "$T/out")" 1
export ORGO_API_KEY=sk-fixture-8325
run stop oldbox --host 'Bad Host'
check H9-bad-host "$RC" 2
run stop oldbox --host
check H9-empty-host "$RC" 2
run resize oldbox --account x --mem-gb 8 --host node-oldbox
check H9-resize-usage "$RC" 2
check H9-resize-says "$(n '^usage: ' "$T/err")" 1

echo "box-ops-orgo-host: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
