#!/bin/bash
# tests/llm-alert-lanes-offhub.bh-6720-test.sh — BH-6720 (BH-6047.7, C6): the
# three LLM alert lanes (alert-triage, alerts-medic, watchdog-responder) carry
# one input manifest pair each, so a run for one project can happen on a Fly
# lane machine. The manifests:
#   catalog/lane-run-inputs.d/alert-triage.ro, alert-triage.rw
#   catalog/lane-run-inputs.d/alerts-medic.ro, alerts-medic.rw
#   catalog/lane-run-inputs.d/watchdog-responder.ro, watchdog-responder.rw
#
#   A1  for each lane, the REAL bin/lane-snapshot-publish.sh --lane <lane> demo
#       publishes nothing when the lane is placed hub, and with a fly
#       placement it publishes a snapshot whose logs/ALERTS.log holds the
#       four demo lines and none of the six drop lines (other, demo10,
#       demo-old, xdemo, other-demo-ish, no project), and no member of
#       project other.
#   A2  the alert-triage snapshot, fetched onto an empty machine root
#       (lri_fetch), feeds the REAL bin/alert-triage.sh demo: the prompt the
#       agent-call stub records holds demo's inbox alert and not other's. The
#       run's write-back (lri_checkpoint) carries a state/alert-triage/demo/
#       member, and every member passes lri_member_ok ... rw alert-triage.
#   A3  no fixture key reaches a snapshot or a lane machine's env: neither
#       token string and no env/ or accounts.d member is in any snapshot; the
#       REAL fly/lane-run-entrypoint.sh writes neither token nor label into the
#       env it hands the worker or into its env dir. With
#       ACCOUNT_PROJECT_FOR_LANE=alert-triage=demo the label is acct-demo, the
#       read point <env dir>/accounts.d/acct-demo.env gives demo's token only,
#       and with no file there project_account_exports answers rc 3.
#   A4  for each lane, a write-back with a path outside the lane's .rw is
#       refused by lri_member_ok and rejected whole by lri_apply_pending; the
#       hub's files stay byte-identical. A write-back inside .rw is applied.
#
# The jobs client is a stub (bin/jobs-client.sh in the hub root, and the same
# functions in this shell) that keeps the published parts and serves them
# back, so no worker runs. tests/blocked-resolver-offhub.bh-6128-test.sh drives
# the same lib through the real worker.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/llm-alert-lanes-offhub.bh-6720-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO/bin/lib/lane-run-inputs.sh"
MANI="$REPO/catalog/lane-run-inputs.d"
LANES=(alert-triage alerts-medic watchdog-responder)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
NOW=1790000000
# Every root here resolves its env dir inside the scratch dir: never the box's
# HARNESS_ENV_DIR, never /etc/harness/env.
unset HARNESS_ENV_DIR; export ETC_HARNESS_ENV="$T/no-etc-env"

for f in "$MANI/alert-triage.ro" "$MANI/alert-triage.rw" "$MANI/alerts-medic.ro" "$MANI/alerts-medic.rw" \
         "$MANI/watchdog-responder.ro" "$MANI/watchdog-responder.rw"; do
  [ -s "$f" ] && ok "manifest $(basename "$f") is committed" || bad "manifest $(basename "$f") is missing"
done

# ---------------------------------------------------------------------------
# The jobs client stub. $JS/req.log holds one line per request. A PUT part is
# kept as $JS/srv/<lane>/<p>/part-<n>.json, a commit as commit.json; a GET of
# the snapshot answers from them (404 before a commit). A posted write-back is
# $JS/srv/<lane>/<p>/wbpost.json. GET .../writebacks answers wblist.json.
JS="$T/js"; mkdir -p "$JS/srv"; : > "$JS/req.log"; : > "$JS/settings"
export JS
cat > "$T/jobs-stub.sh" <<'STUB'
# shellcheck shell=bash
_js_dir() { local s="${1#/api/lane-snapshots/}"; s="${s%%\?*}"; printf '%s/srv/%s/%s' "$JS" "$(cut -d/ -f1 <<<"$s")" "$(cut -d/ -f2 <<<"$s")"; }
_js() {
  local m="$1" p="$2" body="$3" file="$4" d n
  printf '%s %s\n' "$m" "$p" >> "$JS/req.log"
  d=$(_js_dir "$p"); mkdir -p "$d"; JOBS_HTTP=200
  case "$m $p" in
    "PUT "*/parts/*) n="${p##*/}"; cp "$file" "$d/part-$n.json"; echo '{}' ;;
    "POST "*/commit) printf '%s' "$body" > "$d/commit.json"; echo '{}' ;;
    "POST "*/writebacks/ack) printf '%s' "$body" > "$d/ack.json"; echo '{}' ;;
    "POST "*/writebacks) cp "$file" "$d/wbpost.json"; echo '{"id":7}' ;;
    "GET "*/writebacks) cat "$d/wblist.json" 2>/dev/null || echo '{"writebacks":[]}' ;;
    "GET "*/writebacks/*) cat "$d/wb-${p##*/}.json" ;;
    "GET "*/parts/*) n="${p%%\?*}"; n="${n##*/}"; cat "$d/part-$n.json" ;;
    "GET "*)
      [ -s "$d/commit.json" ] || { JOBS_HTTP=404; return 2; }
      jq -c '{sha, parts, applied_through, age_s: 5, truncated: false, writebacks: []}' "$d/commit.json" ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
}
_jobs_req() { _js "$1" "$2" "${3:-}" ""; }
_jobs_req_file() { _js "$1" "$2" "" "$3"; }
setting_get() { local v; v=$(grep -m1 "^$1=" "$JS/settings" 2>/dev/null) || return 2; printf '%s\n' "${v#*=}"; }
_setting_key_ok() { case "${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "${#1}" -le 64 ]; }
_jobs_box_name() { echo fixture-box; }
STUB
# shellcheck source=/dev/null
. "$T/jobs-stub.sh" || exit 1
# L <root> <cmd...> — one call of the lib in a subshell rooted at <root>.
L() { local r="$1"; shift; ( export HARNESS="$r"; . "$LIB" || exit 99; "$@" ); }
# PUTS <lane> — the PUT requests logged for <lane>/demo.
PUTS() { local n; n=$(grep -c "^PUT /api/lane-snapshots/$1/demo/" "$JS/req.log"); printf '%s' "${n:-0}"; }
# SNAP <lane> <out.tgz> — the stored snapshot of <lane>/demo, reassembled.
SNAP() { local f; : > "$2"
  for f in $(ls "$JS/srv/$1/demo"/part-*.json 2>/dev/null | sort -V); do jq -j .b64 "$f" | base64 -d >> "$2"; done; }

# ---------------------------------------------------------------------------
# The hub: a scratch root with the real publisher's closure, the stub client
# as its bin/jobs-client.sh, the committed manifests (the hub syncs catalog/),
# two projects' state and two projects' account files.
HB="$T/hub"
( cd "$REPO" && scratch_install_closure bin/lane-snapshot-publish.sh "$HB" ) >/dev/null || { echo "setup: closure"; exit 1; }
cp "$T/jobs-stub.sh" "$HB/bin/jobs-client.sh"
mkdir -p "$HB/catalog" && cp -r "$MANI" "$HB/catalog/" || exit 1
mkdir -p "$HB"/{logs,flags,locks,env/accounts.d} \
         "$HB"/state/{alert-triage,alerts-medic,watchdog-responder}/{demo,other} "$HB/state/responder" || exit 1
KEEP=$(cat <<'EOF'
2026-10-14 10:00:00Z [alert-triage] demo: keep-1 the demo subsystem is unhappy
2026-10-14 10:00:01Z [demo] keep-2 build stalled
2026-10-14 10:00:02Z keep-3 project demo; queue is deep
2026-10-14 10:00:03Z keep-4 the line ends in demo
EOF
)
DROP=$(cat <<'EOF'
2026-10-14 10:00:04Z [alert-triage] other: drop-1 the other subsystem is unhappy
2026-10-14 10:00:05Z drop-2 project demo10 is red
2026-10-14 10:00:06Z drop-3 demo-old was retired
2026-10-14 10:00:07Z drop-4 xdemo is a prefix decoy
2026-10-14 10:00:08Z drop-5 other-demo-ish is a decoy
2026-10-14 10:00:09Z drop-6 a line that names no project
EOF
)
{ sed -n 1,2p <<<"$KEEP"; sed -n 1,3p <<<"$DROP"; sed -n 3,4p <<<"$KEEP"; sed -n 4,6p <<<"$DROP"; } > "$HB/logs/ALERTS.log"
cat > "$HB/fleet.conf" <<'EOF'
demo o/demo - - 2 box-a 192.0.2.1
other o/other - - 2 box-b 192.0.2.2
EOF
touch "$HB/flags/triage-registry-off" "$HB/flags/triage-close-off"
q() { printf 'hub\t%s\t{"kind":"fleet_alert","project":"%s","akey":"akey-%s","line":"the %s subsystem is unhappy"}\n' "$NOW" "$1" "$2" "$2"; }
q demo demo-only > "$HB/state/alert-triage/demo/inbox.tsv"
q other other-only > "$HB/state/alert-triage/other/inbox.tsv"
for p in demo other; do
  echo "seen-$p" > "$HB/state/alerts-medic/$p/medic-seen.txt"
  echo "{\"$p\":1}" > "$HB/state/watchdog-responder/$p/stale-history.json"
done
echo '{"other:k1":1}' > "$HB/state/responder/handled.json"
echo '{"demo":{"count":1},"other":{"count":2}}' > "$HB/state/stale-owed.json"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-fixture-demo\n' > "$HB/env/accounts.d/acct-demo.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-fixture-other\n' > "$HB/env/accounts.d/acct-other.env"
cp "$HB/logs/ALERTS.log" "$T/alerts.before"; cp "$HB/state/responder/handled.json" "$T/handled.before"
# PUB <lane> — the real publisher, for demo, as its cron runs it but named.
PUB() { HARNESS="$HB" LANE_GATE_DISABLE=1 bash "$HB/bin/lane-snapshot-publish.sh" --lane "$1" demo 2>&1; }

# ============================================================================
echo "A1: each lane's demo snapshot holds demo's ALERTS lines only"
for lane in "${LANES[@]}"; do
  OUT=$(PUB "$lane"); rc=$?
  [ "$rc" = 0 ] && [ "$(PUTS "$lane")" = 0 ] && ok "A1 $lane placed hub: no PUT ($OUT)" || bad "A1 $lane hub: rc=$rc puts=$(PUTS "$lane") $OUT"
  printf 'lane_placement.%s=fly\n' "$lane" >> "$JS/settings"
  OUT=$(PUB "$lane"); rc=$?
  case "$rc:$OUT" in
    "0:lane-snapshot-publish: 1 published,"*) ok "A1 $lane placed fly: published" ;;
    *) bad "A1 $lane fly: rc=$rc $OUT" ;;
  esac
  SNAP "$lane" "$T/$lane.tgz"
  MEM=$(tar -tzf "$T/$lane.tgz" 2>/dev/null)
  GOT=$(tar -xzOf "$T/$lane.tgz" logs/ALERTS.log 2>/dev/null)
  [ "$GOT" = "$KEEP" ] && ok "A1 $lane logs/ALERTS.log holds the 4 keep lines, in order, and nothing else" \
    || bad "A1 $lane ALERTS.log: $(diff <(printf '%s\n' "$KEEP") <(printf '%s\n' "$GOT") | head -12)"
  for m in drop-1 drop-2 drop-3 drop-4 drop-5 drop-6; do
    grep -q -- "$m" <<<"$GOT" && bad "A1 $lane ALERTS.log holds $m" || ok "A1 $lane ALERTS.log drops $m"
  done
  grep -q '/other/' <<<"$MEM" && bad "A1 $lane holds a member of project other: $(grep /other/ <<<"$MEM")" \
    || ok "A1 $lane holds no member of project other"
  grep -qx 'fleet.conf' <<<"$MEM" && ok "A1 $lane carries fleet.conf" || bad "A1 $lane lacks fleet.conf: $MEM"
done
for f in state/alert-triage/demo/inbox.tsv:alert-triage state/alerts-medic/demo/medic-seen.txt:alerts-medic \
         state/watchdog-responder/demo/stale-history.json:watchdog-responder state/stale-owed.json:watchdog-responder; do
  grep -qx "${f%:*}" <<<"$(tar -tzf "$T/${f#*:}.tgz" 2>/dev/null)" && ok "A1 ${f#*:} carries ${f%:*}" || bad "A1 ${f#*:} lacks ${f%:*}"
done

# ============================================================================
echo "A2: an alert-triage run on a machine root fed from the snapshot"
M="$T/m"
for s in bin/alert-triage.sh bin/triage-spool-retire.sh bin/fleet-conf.sh; do
  ( cd "$REPO" && scratch_install_closure "$s" "$M" ) >/dev/null || { echo "setup: closure $s"; exit 1; }
done
# shellcheck source=tests/lib/triage-tick.sh
. "$REPO/tests/lib/triage-tick.sh" || exit 1
triage_tick_setup "$M" || exit 1
# The model route the worker answers on a lane machine, as the box cache.
# shellcheck source=tests/lib/model-route-stub.sh
. "$REPO/tests/lib/model-route-stub.sh" || exit 1
model_routes_fixture "$M" || exit 1
mkdir -p "$M/catalog" "$M/logs" "$M/env" "$T/fakebin" "$T/calls" && cp -r "$MANI" "$M/catalog/" || exit 1
# The splitter imports it; the lane image bakes all of bin/.
cp "$REPO/bin/alert_family.py" "$M/bin/alert_family.py" || exit 1
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/ssh"
printf '#!/bin/sh\nexit 7\n' > "$T/fakebin/curl"
printf '#!/bin/sh\necho "=== HARNESS ORIENTATION (fixture)"\n' > "$M/bin/triage-map.sh"
cat > "$M/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" >> "$T/calls/prompt.txt"
printf '%s\n' "\${ACCOUNT_PROJECT_FOR_LANE:-none}" > "$T/calls/acct"
echo "handled=1 escalated=0 noise=0" > "\$5"
EOF
chmod +x "$T/fakebin/"* "$M/bin/triage-map.sh" "$M/bin/agent-call.sh"
OUT=$(L "$M" lri_fetch alert-triage demo "$M" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$M/state/alert-triage/demo/inbox.tsv" ] && ok "A2 lri_fetch overlaid the snapshot ($OUT)" \
  || bad "A2 lri_fetch rc=$rc: $OUT"
[ ! -e "$M/state/alert-triage/other" ] && ok "A2 the machine root has no state of project other" || bad "A2 other's state reached the machine"
touch "$T/marker"
( export HARNESS="$M" FLEET_CONF="$M/fleet.conf" JOBS_URL="" CONSOLE_URL="" TRIAGE_NOW="$NOW" \
         GH_TOKEN=tok-fixture-gh PATH="$T/fakebin:$PATH"
  bash "$M/bin/alert-triage.sh" demo ) > "$T/a2.out" 2>&1; rc=$?
PR=$(cat "$T/calls/prompt.txt" 2>/dev/null)
grep -q 'demo-only subsystem' <<<"$PR" && ! grep -q 'other-only subsystem' <<<"$PR" \
  && ok "A2 prompt holds demo only" || bad "A2 prompt (rc=$rc): $(head -c 300 <<<"$PR") $(tail -5 "$T/a2.out")"
[ "$(cat "$T/calls/acct" 2>/dev/null)" = alert-triage=demo ] && ok "A2 the model call reads demo's account map" \
  || bad "A2 ACCOUNT_PROJECT_FOR_LANE: $(cat "$T/calls/acct" 2>/dev/null)"
# The run's own file list, for the note (LRI_INVENTORY_OUT=<file>).
[ -n "${LRI_INVENTORY_OUT:-}" ] && { echo "rc=$rc"; find "$M" -newer "$T/marker" -type f | sed "s#^$M/##" | LC_ALL=C sort; } > "$LRI_INVENTORY_OUT"
OUT=$(LANE_RUN_ID=run-fixture-1 FLY_MACHINE_ID=m-fixture L "$M" lri_checkpoint alert-triage demo 2>&1); rc=$?
WBP="$JS/srv/alert-triage/demo/wbpost.json"
jq -j .b64 "$WBP" 2>/dev/null | base64 -d > "$T/wb.tgz" 2>/dev/null
WBM=$(tar -tvzf "$T/wb.tgz" 2>/dev/null | awk '{print substr($1,1,1) "\t" $NF}')
[ "$rc" = 0 ] && [ -n "$WBM" ] && ok "A2 lri_checkpoint posted a write-back ($OUT)" || bad "A2 checkpoint rc=$rc: $OUT"
grep -q $'\tstate/alert-triage/demo/' <<<"$WBM" && ok "A2 the write-back carries a state/alert-triage/demo/ member" \
  || bad "A2 no state/alert-triage/demo/ member: $WBM"
NBAD=0
while IFS=$'\t' read -r t n; do
  n="${n%/}"; case "$n" in .lri|.lri/*|'') continue ;; esac
  L "$M" lri_member_ok demo "$n" "$t" rw alert-triage || { NBAD=$((NBAD+1)); echo "    outside: $t $n"; }
done <<<"$WBM"
[ -n "$WBM" ] && [ "$NBAD" = 0 ] && ok "A2 write-back inside alert-triage.rw" || bad "A2 $NBAD member(s) outside alert-triage.rw"
( export HARNESS="$HB"; . "$LIB" || exit 99; LRI_LANE=alert-triage _lri_validate demo "$T/wb.tgz" writeback ) \
  && ok "A2 the hub validator accepts the write-back" || bad "A2 the hub validator refuses the write-back"

# ============================================================================
echo "A3: no other project's key in a snapshot or the machine env"
for lane in "${LANES[@]}"; do
  RAW=$(gzip -dc "$T/$lane.tgz" 2>/dev/null | tr -d '\0')
  ! grep -q -e tok-fixture-other -e tok-fixture-demo <<<"$RAW" && ok "A3 $lane snapshot holds no token string" \
    || bad "A3 $lane snapshot holds a token"
  grep -q -e '^env/' -e 'accounts\.d' <<<"$(tar -tzf "$T/$lane.tgz" 2>/dev/null)" && bad "A3 $lane snapshot holds an env member" \
    || ok "A3 $lane snapshot holds no env/ or accounts.d member"
done
# The entrypoint, with a worker stub that dumps what it was handed.
# $E/env exists before the entrypoint runs and ETC_HARNESS_ENV names no dir,
# so harness_env_dir resolves inside the scratch root, never /etc/harness/env.
E="$T/e"; mkdir -p "$E/bin/lib" "$E/env"
( cd "$REPO" && scratch_install_closure fly/lane-run-entrypoint.sh "$E" ) >/dev/null || { echo "setup: closure entrypoint"; exit 1; }
cat > "$E/bin/lane-run-worker.sh" <<EOF
#!/bin/bash
env > "$T/e.env"
EOF
chmod +x "$E/bin/lane-run-worker.sh"
( env -i PATH="$PATH" HOME="$T" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc-env" JOBS_URL=https://jobs.invalid HARNESS_SECRET=secret-fixture-1 \
    FLY_MACHINE_ID=m-fixture GH_APP_ID=1 GH_APP_PRIVATE_KEY=pem-fixture-1 GH_APP_INSTALLATION_DEMO=2 \
    bash "$E/fly/lane-run-entrypoint.sh" ) > "$T/e.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -s "$T/e.env" ] && [ -s "$E/env/global.env" ] && ok "A3 the entrypoint ran the worker stub" \
  || bad "A3 entrypoint rc=$rc: $(cat "$T/e.out")"
HITS=$(grep -rl -e tok-fixture-other -e acct-other -e tok-fixture-demo -e acct-demo "$T/e.env" "$E/env" 2>/dev/null)
[ -z "$HITS" ] && ok "A3 no fixture token or label in the worker env or the env dir" || bad "A3 key material in: $HITS"
# The read point: the label from demo's pin, the token from accounts.d.
PA() { ( export HARNESS="$1" ACCOUNT_PROJECT_FOR_LANE=alert-triage=demo ACCOUNT_OWN_PROJECTS=demo=acct-demo,other=acct-other \
         LANE_GATE_DISABLE=1 JOBS_URL=""
         . "$REPO/bin/lib/project-account.sh" || exit 99; "${@:2}" ); }
[ "$(PA "$E" account_for_project alert-triage)" = "label=acct-demo source=env" ] \
  && ok "A3 account_for_project alert-triage answers label=acct-demo" || bad "A3 label: $(PA "$E" account_for_project alert-triage)"
OUT=$(PA "$E" project_account_exports alert-triage 2>&1); rc=$?
[ "$rc" = 3 ] && [ -z "$OUT" ] && ok "A3 no accounts.d file on the machine: rc 3, nothing printed" || bad "A3 absent: rc=$rc $OUT"
mkdir -p "$E/env/accounts.d" && cp "$HB/env/accounts.d/acct-demo.env" "$E/env/accounts.d/"
OUT=$(PA "$E" project_account_exports alert-triage 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$OUT" = "export CLAUDE_CODE_OAUTH_TOKEN='tok-fixture-demo'" ] \
  && ok "A3 accounts.d/acct-demo.env present: demo's token only" || bad "A3 present: rc=$rc $OUT"

# ============================================================================
echo "A4: a write-back outside the lane's .rw is rejected"
# WB <lane> <id> <relpath...> — a write-back tgz of <relpath>s (absent base),
# served as write-back <id> of <lane>/demo.
WB() { local lane="$1" id="$2" w="$T/wb-$1-$2" rel d; shift 2
  d="$JS/srv/$lane/demo"; mkdir -p "$w/.lri" "$d"; : > "$w/.lri/base.tsv"; : > "$w/.lri/deletions"
  for rel in "$@"; do mkdir -p "$w/$(dirname "$rel")"; echo machine > "$w/$rel"; printf '%s\t-\n' "$rel" >> "$w/.lri/base.tsv"; done
  tar --owner=0 --group=0 --numeric-owner --format=gnu -czf "$w.tgz" -C "$w" "$@" .lri/base.tsv .lri/deletions || return 1
  jq -n --rawfile b <(base64 -w0 "$w.tgz") '{b64:$b}' > "$d/wb-$id.json"
  jq -n --argjson i "$id" --arg s "$(sha256sum "$w.tgz" | cut -d' ' -f1)" '{writebacks:[{id:$i, sha:$s}]}' > "$d/wblist.json"
}
declare -A INSIDE=([alert-triage]=state/alert-triage/demo/work.tsv [alerts-medic]=state/alerts-medic/demo/medic-parked.json
                   [watchdog-responder]=state/watchdog-responder/demo/.wedgekeys)
OUTSIDE=(logs/ALERTS.log state/alert-triage/other/inbox.tsv state/responder/handled.json env/accounts.d/acct-demo.env)
id=10
for lane in "${LANES[@]}"; do
  for o in "${OUTSIDE[@]}"; do
    L "$HB" lri_member_ok demo "$o" - rw "$lane" && bad "A4 $lane lri_member_ok accepts $o" || ok "A4 $lane refuses $o"
  done
  L "$HB" lri_member_ok demo "${INSIDE[$lane]}" - rw "$lane" && ok "A4 $lane accepts ${INSIDE[$lane]}" \
    || bad "A4 $lane refuses its own ${INSIDE[$lane]}"
  for o in "${OUTSIDE[@]}"; do
    id=$((id + 1)); cp "$HB/${INSIDE[$lane]}" "$T/inside.before" 2>/dev/null || : > "$T/inside.before"
    WB "$lane" "$id" "${INSIDE[$lane]}" "$o" || exit 1
    AP=$(L "$HB" lri_apply_pending "$lane" demo); rc=$?
    [ "$AP" = "applied=0 conflicts=0 rejected=1" ] && ok "A4 $lane write-back with $o: $AP" || bad "A4 $lane $o: rc=$rc $AP"
  done
  cmp -s "$HB/logs/ALERTS.log" "$T/alerts.before" && cmp -s "$HB/state/responder/handled.json" "$T/handled.before" \
    && [ "$(cat "$HB/env/accounts.d/acct-demo.env")" = "CLAUDE_CODE_OAUTH_TOKEN=tok-fixture-demo" ] \
    && [ "$(cat "$HB/state/alert-triage/other/inbox.tsv")" = "$(q other other-only)" ] \
    && ok "A4 $lane the hub's outside files are byte-identical" || bad "A4 $lane an outside file changed"
  [ "$(cat "$HB/${INSIDE[$lane]}" 2>/dev/null)" != machine ] && ok "A4 $lane a rejected write-back applies no part" \
    || bad "A4 $lane the inside path of a rejected write-back was applied"
  id=$((id + 1)); WB "$lane" "$id" "${INSIDE[$lane]}" || exit 1
  AP=$(L "$HB" lri_apply_pending "$lane" demo); rc=$?
  [ "$rc" = 0 ] && [ "$AP" = "applied=1 conflicts=0 rejected=0" ] && [ "$(cat "$HB/${INSIDE[$lane]}" 2>/dev/null)" = machine ] \
    && ok "A4 $lane a write-back inside .rw is applied" || bad "A4 $lane inside: rc=$rc $AP"
done

echo
echo "llm-alert-lanes-offhub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
