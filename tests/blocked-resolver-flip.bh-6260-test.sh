#!/bin/bash
# tests/blocked-resolver-flip.bh-6260-test.sh — BH-6260: blocked-resolver is
# placed on Fly by the schema (fragment 0025), the per-file snapshot cap is a
# settings row, and every snapshot skip is logged once on the hub.
#
# Driven over real curl against the REAL jobs worker on node:sqlite
# (tests/lib/lane-snapshots-worker.bh-6128.mjs) with the composed schema, through
# the real bin/lib/lane-run-inputs.sh, bin/lane-snapshot-publish.sh,
# bin/lane-run-worker.sh and bin/blocked-resolver.sh.
#
#   F1  the composed schema seeds lane_placement.blocked-resolver=fly;
#       lp_decide from the schema alone answers fly; lanes-build --check rc 0
#   F4  _lri_file_max: the settings table; a 2,000-byte file is out of the
#       snapshot at 1024 and in it at the default; hub ro and machine rw agree
#   F3  one skip line per file over the cap and per old record dir, once;
#       a skip that ends and recurs logs again; stdout and rc unchanged
#   F2  one project, no operator row: 1 published, placed fly, 1 fly row,
#       the machine row is done rc 0 and takes the hub reference's rungs
#   F5  the kill knob: the row set to hub returns the lane to the hub
#   F6  a file over the cap at checkpoint time but still on the machine is
#       not a hub deletion; a real delete still is
#
# Run from anywhere: tests/blocked-resolver-flip.bh-6260-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-6005: worker/jobs/schema.sql is composed from schema.d/, not committed.
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-snapshots-worker.bh-6128.mjs"
FRAG="$DIR/worker/jobs/schema.d/202610170602-bh-6260-blocked-resolver-flip.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
# ONE clock read for the whole file: every fixture age is derived from it.
NOW=$(date -u +%s)

# A harness root with the lane, the publisher, the machine loop and their libs.
# The jobs client is the real one, with the queue writes recorded instead of
# sent, so a rebuild rung is a line in $QUEUE_SINK on both sides.
INSTALL() {
  local r="$1" L
  mkdir -p "$r/bin/lib" "$r/env" || return 1
  cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
     "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$r/bin/"
  # shellcheck source=tests/lib/br-modules.sh
  . "$DIR/tests/lib/br-modules.sh" || return 1
  br_modules_install "$DIR" "$r" || return 1
  for L in bin/lane-snapshot-publish.sh bin/lane-run-worker.sh bin/lib/lane-run-inputs.sh \
           bin/lib/br/opt/untouched.sh bin/lib/gh-app-auth.sh bin/project-lane-run.sh bin/lib/gh-pr-list.sh \
           bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh bin/lib/hold.sh bin/lib/gh-rest.sh \
           bin/jobs-client.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
    ( cd "$DIR" && scratch_install_closure "$L" "$r" ) >/dev/null || { echo "setup: could not install $L"; return 1; }
  done
  # BH-6719: the lane's inputs are the catalog manifests, not a list in the lib.
  mkdir -p "$r/catalog" && cp -r "$DIR/catalog/lane-run-inputs.d" "$r/catalog/" || return 1
  mv "$r/bin/jobs-client.sh" "$r/bin/jobs-client-real.sh"
  cat > "$r/bin/jobs-client.sh" <<'EOF'
# shellcheck shell=bash
. "$(dirname "${BASH_SOURCE[0]}")/jobs-client-real.sh"
queue_put() { printf '%s\n' "$*" >> "${QUEUE_SINK:-/dev/null}"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
  for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$r/bin/$f"
  done
  printf '#!/bin/bash\nprintf "run-build.sh %%s\\n" "$*" >> "%s/path.log"\nexit 0\n' "$T" > "$r/bin/run-build.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts-%s.txt"\nexit 0\n' "$T" "$(basename "$r")" > "$r/bin/lane-alert.sh"
  printf '#!/bin/bash\nprintf "the reasoning\\nREJECT\\n" > "$5"\nexit 0\n' > "$r/bin/agent-call.sh"
  chmod +x "$r/bin/"*.sh
  : > "$r/env/global.env"
  mrs_fixture "$r" p1
}
# shellcheck source=tests/lib/model-route-stub.sh
. "$DIR/tests/lib/model-route-stub.sh" || exit 1

# The PATH stubs: gh answers the fixture tickets; ssh, scp and rsync only log.
FB="$T/fakebin"; mkdir -p "$FB" "$T/repos"
for s in ssh scp rsync; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "%s/path.log"\nexit 0\n' "$s" "$T" > "$FB/$s"
done
printf '#!/bin/bash\nprintf "ssh %%s\\n" "$*" >> "%s/path.log"\nexit 0\n' "$T" > "$FB/br-ssh"
cat > "$FB/gh" <<EOF
#!/bin/bash
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*)
    jq -nc --argjson n "\$N" '{number:\$n,state:"open",labels:[{name:"ai-build"}],title:("TK-"+(\$n|tostring)+": a parked ticket"),body:"## Scope",created_at:"2026-10-01T00:00:00Z"}' ;;
  *"pr close"*|*"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$FB/"*
export PATH="$FB:$PATH" GH_TOKEN="" REPOS_ROOT="$T/repos" BR_SSH="$FB/br-ssh"
export HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
export BOX_NAME=fixture-box BR_DISPATCH_SPREAD_SECS=0 BR_PER_TICK=4
: > "$T/path.log"

PIDS=()
# srv <name> -> PORT, or rc 3 (no node:sqlite)
srv() {
  local n="$1"
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT
hook() { curl -sS -X "$1" "$JOBS_URL/$2" -d "${3:-{\}}" ; }
setting() { hook PUT __setting "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
unsetting() { hook DELETE __setting "$(jq -nc --arg k "$1" '{key:$k}')" >/dev/null; }
sql() { hook POST __sql "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
rows() { curl -sS "$JOBS_URL/__lane_runs"; }
# lib <root> <cmd...> — one call of the lib in a subshell rooted at <root>.
lib() { local r="$1"; shift; ( export HARNESS="$r"; . "$r/bin/lib/lane-run-inputs.sh" && "$@" ); }
# ROWADD <root> <key> <since> <url> — one conductor hand-off row.
ROWADD() { mkdir -p "$1/state/merge-conductor"
  printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\tmerge-failed-twice: gh pr merge refused\t%s\n' "$2" "$3" "$4" >> "$1/state/merge-conductor/pr-state.tsv"; }
# RUNGS <log> — the rungs a log dispatched, stamps stripped, sorted.
RUNGS() { grep -E '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild)|^[0-9-]+ [0-9:]+Z EVENT ' "$1" 2>/dev/null \
          | sed -E 's/^[0-9-]+ [0-9:]+Z //' | LC_ALL=C sort; }
# SKIPS <root> — the skip lines of the publish log, stamps stripped.
SKIPS() { grep -F 'lane-snapshot-publish: skip ' "$1/logs/lane-snapshot-publish.log" 2>/dev/null | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }

srv wa; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/wa.err")"; exit 1; }
URL_A="http://127.0.0.1:$PORT"
srv wb; URL_B="http://127.0.0.1:$PORT"
srv wc; URL_C="http://127.0.0.1:$PORT"

# ============================================================================
echo "F1: the composed schema places blocked-resolver on fly"
export JOBS_URL="$URL_B"
[ -s "$FRAG" ] && ok "F1 fragment 0025 exists" || bad "F1 no fragment $FRAG"
V=$(sql "SELECT value FROM settings WHERE key='lane_placement.blocked-resolver'" | jq -r '.rows[0].value // "absent"')
[ "$V" = fly ] && ok "F1 the composed schema seeds lane_placement.blocked-resolver=fly" || bad "F1 seeded value: $V"
for kv in lane_snapshot.file_max=262144 lane_snapshot.prune_after_s=604800; do
  V=$(sql "SELECT value FROM settings WHERE key='${kv%%=*}'" | jq -r '.rows[0].value // "absent"')
  [ "$V" = "${kv#*=}" ] && ok "F1 seeded $kv" || bad "F1 ${kv%%=*}: $V"
done
P1="$T/p1root"; INSTALL "$P1" || exit 1
D=$( export HARNESS="$P1"; . "$P1/bin/lib/lane-placement.sh"; lp_decide blocked-resolver; printf '%s|%s' "$LP_PLACE" "$LP_WHY")
[ "$D" = "fly|lane_placement.blocked-resolver=fly" ] && ok "F1 lp_decide from the schema alone: $D" || bad "F1 lp_decide: $D"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check ) > "$T/lanes-build.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "F1 bin/lanes-build.sh --check rc 0" || bad "F1 lanes-build --check rc=$rc $(tail -3 "$T/lanes-build.out")"

# ============================================================================
echo "F4: lane_snapshot.file_max — the settings table, and hub and machine agree"
export JOBS_URL="$URL_C"
R="$T/r"; INSTALL "$R" || exit 1
fmax() { ( export HARNESS="$R"; . "$R/bin/lib/lane-run-inputs.sh" && _lri_client && _lri_file_max ); }
unsetting lane_snapshot.file_max
[ "$(fmax)" = 262144 ] && ok "F4 row unset -> 262144" || bad "F4 unset -> $(fmax)"
for v in "" abc 0 -5 2000000 1000001; do
  setting lane_snapshot.file_max "$v"
  [ "$(fmax)" = 262144 ] && ok "F4 row '$v' -> 262144" || bad "F4 row '$v' -> $(fmax)"
done
for v in 1 1024 1000000; do
  setting lane_snapshot.file_max "$v"
  [ "$(fmax)" = "$v" ] && ok "F4 row '$v' -> $v" || bad "F4 row '$v' -> $(fmax)"
done
mkdir -p "$R/builds/p1-BH-4-x" "$R/state/blocked-resolver/p1" "$R/state/build-notes/p1"
printf 'RESULT: BUILT\n' > "$R/builds/p1-BH-4-x/RESULT"
head -c 2000 /dev/zero | tr '\0' 'r' > "$R/builds/p1-BH-4-x/review.md"
head -c 2000 /dev/zero | tr '\0' 'n' > "$R/state/build-notes/p1/BH-4.md"
head -c 2000 /dev/zero | tr '\0' 's' > "$R/state/blocked-resolver/p1/k.json"
LIST() { ( export HARNESS="$R"; . "$R/bin/lib/lane-run-inputs.sh" && _lri_client && _lri_list p1 "$1" 0 ) | awk -F'\t' '$1 == "-" {print $2}'; }
setting lane_snapshot.file_max 1024
LIST ro > "$T/f4-ro-1024"; LIST rw > "$T/f4-rw-1024"
for f in builds/p1-BH-4-x/review.md state/build-notes/p1/BH-4.md state/blocked-resolver/p1/k.json; do
  grep -qx "$f" "$T/f4-ro-1024" && bad "F4 cap 1024: $f is in the hub list" || ok "F4 cap 1024: the 2,000-byte $f is out"
done
grep -qx builds/p1-BH-4-x/RESULT "$T/f4-ro-1024" && ok "F4 cap 1024: a small file stays in" || bad "F4 cap 1024 dropped RESULT"
unsetting lane_snapshot.file_max
LIST ro > "$T/f4-ro-def"; LIST rw > "$T/f4-rw-def"
grep -qx builds/p1-BH-4-x/review.md "$T/f4-ro-def" && grep -qx state/build-notes/p1/BH-4.md "$T/f4-ro-def" \
  && ok "F4 default cap: the 2,000-byte files are in" || bad "F4 default: $(tr '\n' ' ' < "$T/f4-ro-def")"
for c in 1024 def; do
  # The rw list is the subset a write-back may carry; the hub list holds it.
  grep -vxFf "$T/f4-ro-$c" "$T/f4-rw-$c" > "$T/f4-diff-$c"
  [ -s "$T/f4-rw-$c" ] && [ ! -s "$T/f4-diff-$c" ] && ok "F4 cap $c: the machine rw list is inside the hub ro list" \
    || bad "F4 cap $c: rw files missing from ro: $(tr '\n' ' ' < "$T/f4-diff-$c")"
done

# ============================================================================
echo "F3: every snapshot skip is logged once, on the hub"
scratch_rm "$R/builds/p1-BH-4-x"; scratch_rm "$R/state"
mkdir -p "$R/builds/p1-BH-1-x" "$R/builds/p1-BH-2-old" "$R/builds/p1-BH-3-new" "$R/logs"
printf 'RESULT: BUILT\n' > "$R/builds/p1-BH-1-x/RESULT"
head -c 300000 /dev/zero > "$R/builds/p1-BH-1-x/review.md"
head -c 262144 /dev/zero > "$R/builds/p1-BH-1-x/plan.md"
head -c 300000 /dev/zero > "$R/builds/p1-BH-1-x/transcript.txt"
printf 'RESULT: BUILT\n' > "$R/builds/p1-BH-3-new/RESULT"
printf 'old\n' > "$R/builds/p1-BH-2-old/RESULT"
touch -d "@$((NOW - 86400 * 40))" "$R/builds/p1-BH-2-old/RESULT" "$R/builds/p1-BH-2-old"
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$R/fleet.conf"
lib "$R" lri_publish blocked-resolver p1 > "$T/f3-out1" 2> "$T/f3-err1"; rc=$?
[ "$rc" = 0 ] && grep -qxE 'published [0-9a-f]{12} [0-9]+' "$T/f3-out1" && [ "$(grep -c . "$T/f3-out1")" = 1 ] \
  && ok "F3 publish 1 rc 0, one stdout line: $(cat "$T/f3-out1")" || bad "F3 publish 1 rc=$rc out=$(cat "$T/f3-out1")"
[ ! -s "$T/f3-err1" ] && ok "F3 publish 1 writes nothing to stderr" || bad "F3 stderr: $(cat "$T/f3-err1")"
SKIPS "$R" > "$T/f3-skips1"
[ "$(grep -cxF 'lane-snapshot-publish: skip p1 builds/p1-BH-1-x/review.md (300000 bytes > lane_snapshot.file_max=262144)' "$T/f3-skips1")" = 1 ] \
  && ok "F3 exactly 1 skip line names the file over the cap" || bad "F3 file skip lines: $(cat "$T/f3-skips1")"
[ "$(grep -cxF 'lane-snapshot-publish: skip p1 builds/p1-BH-2-old (record dir older than lane_snapshot.builds_days=30)' "$T/f3-skips1")" = 1 ] \
  && ok "F3 exactly 1 skip line names the old record dir" || bad "F3 dir skip lines: $(cat "$T/f3-skips1")"
[ "$(grep -c . "$T/f3-skips1")" = 2 ] && ok "F3 no skip line for a file at the cap, a transcript or a young dir" \
  || bad "F3 skip lines: $(cat "$T/f3-skips1")"
# The member is absent from the snapshot tar the machine reads.
M3="$T/m3"; INSTALL "$M3" || exit 1
lib "$M3" lri_fetch blocked-resolver p1 x > "$T/f3-fetch" 2>&1 || bad "F3 fetch: $(cat "$T/f3-fetch")"
[ ! -e "$M3/builds/p1-BH-1-x/review.md" ] && [ -e "$M3/builds/p1-BH-1-x/plan.md" ] && [ ! -e "$M3/builds/p1-BH-2-old" ] \
  && ok "F3 the snapshot lacks the over-cap file and the old dir and has the file at the cap" \
  || bad "F3 snapshot members: $(cd "$M3" && find builds -type f | tr '\n' ' ')"
lib "$R" lri_publish blocked-resolver p1 > "$T/f3-out2" 2> "$T/f3-err2"; rc=$?
[ "$rc" = 0 ] && grep -qxE 'unchanged [0-9a-f]{12} [0-9]+' "$T/f3-out2" && [ ! -s "$T/f3-err2" ] \
  && ok "F3 publish 2 rc 0: $(cat "$T/f3-out2")" || bad "F3 publish 2 rc=$rc $(cat "$T/f3-out2" "$T/f3-err2")"
[ "$(SKIPS "$R" | grep -c .)" = 2 ] && ok "F3 publish 2 adds no skip line" || bad "F3 after publish 2: $(SKIPS "$R")"
# A skip that ends drops out; the same skip coming back logs again.
mv "$R/builds/p1-BH-1-x/review.md" "$T/review.md.away"
lib "$R" lri_publish blocked-resolver p1 > /dev/null 2>&1
[ "$(SKIPS "$R" | grep -c .)" = 2 ] && ok "F3 a skip that ends logs nothing" || bad "F3 after the end: $(SKIPS "$R")"
mv "$T/review.md.away" "$R/builds/p1-BH-1-x/review.md"
lib "$R" lri_publish blocked-resolver p1 > /dev/null 2>&1
[ "$(SKIPS "$R" | grep -cF 'skip p1 builds/p1-BH-1-x/review.md (300000 bytes')" = 2 ] \
  && ok "F3 the same skip coming back logs a second line" || bad "F3 recurrence: $(SKIPS "$R")"
# The cap in the line is the settings row.
setting lane_snapshot.file_max 1024
printf 'x%.0s' $(seq 1 1500) > "$R/builds/p1-BH-3-new/review.md"
lib "$R" lri_publish blocked-resolver p1 > /dev/null 2>&1
SKIPS "$R" | grep -qxF 'lane-snapshot-publish: skip p1 builds/p1-BH-3-new/review.md (1500 bytes > lane_snapshot.file_max=1024)' \
  && ok "F3 the skip line names the settings cap" || bad "F3 settings cap line: $(SKIPS "$R" | tail -2)"
unsetting lane_snapshot.file_max

# ============================================================================
# F2: one project, the flip from the schema alone.
# ============================================================================
HUB="$T/hub"; INSTALL "$HUB" || exit 1
mkdir -p "$HUB/flags" "$HUB/logs" "$HUB/state" "$HUB/locks" "$HUB/builds"
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$HUB/fleet.conf"
touch "$HUB/flags/fly-pool-p1" "$HUB/flags/builder-fly-p1"
ROWADD "$HUB" "o/p1#31" "$NOW" "https://github.com/o/p1/pull/31"
: > "$HUB/logs/ALERTS.log"
REF="$T/ref"; cp -a "$HUB" "$REF"

echo "F2 (reference): the hub run of p1, against worker A"
: > "$T/queue-ref.txt"
( export HARNESS="$REF" FLEET_CONF="$REF/fleet.conf" JOBS_URL="$URL_A" QUEUE_SINK="$T/queue-ref.txt"
  bash "$REF/bin/blocked-resolver.sh" p1 ) >> "$T/ref-run.log" 2>&1
RUNGS "$REF/logs/blocked-resolver.log" > "$T/rungs-ref"
[ "$(grep -c -- '-> rebuild-fresh' "$T/rungs-ref")" = 1 ] && [ "$(grep -c . "$T/queue-ref.txt")" = 1 ] \
  && ok "F2 the reference run took 1 rung and enqueued 1 rebuild" || bad "F2 reference rungs: $(cat "$T/rungs-ref"); $(tail -5 "$REF/logs/blocked-resolver.log" 2>&1)"

echo "F2: the publisher, the dispatch and the machine, with no operator row"
export JOBS_URL="$URL_B" HARNESS="$HUB" FLEET_CONF="$HUB/fleet.conf"
[ "$(grep -c '^PUT /__setting' "$T/wb.log")" = 0 ] && ok "F2 worker B has no operator settings row" || bad "F2 a setting was written on worker B"
PO=$("$HUB/bin/lane-snapshot-publish.sh"); rc=$?
[ "$rc:$PO" = "0:lane-snapshot-publish: 1 published, 0 unchanged, 0 write-backs applied, 0 conflicts, 0 rejected, 0 failed; blocked-resolver placed fly (lane_placement.blocked-resolver=fly); alert lines: 0 replayed, 0 already applied, ack none" ] \
  && ok "F2 publisher: $PO" || bad "F2 publisher rc=$rc: $PO"
( bash "$HUB/bin/blocked-resolver.sh" --dispatch ) >> "$T/hub-run.log" 2>&1
grep -q 'placed: 1 fly, 0 hub (lane_placement.blocked-resolver=fly)' "$HUB/logs/blocked-resolver.log" \
  && ok "F2 dispatch: placed: 1 fly, 0 hub" || bad "F2 dispatch: $(grep dispatch: "$HUB/logs/blocked-resolver.log")"
[ "$(rows | jq '[.rows[] | select(.lane == "blocked-resolver" and .project == "p1" and .status == "queued")] | length')" = 1 ] \
  && ok "F2 1 queued fly row" || bad "F2 rows: $(rows | jq -c '[.rows[] | {lane,project,status}]')"
[ -z "$(RUNGS "$HUB/logs/blocked-resolver.log")" ] && ok "F2 the hub ran no rung" || bad "F2 hub rungs: $(RUNGS "$HUB/logs/blocked-resolver.log")"
M="$T/m"; INSTALL "$M" || exit 1
: > "$T/path.log"; : > "$T/queue-fly.txt"
( export HARNESS="$M" FLEET_CONF="$M/fleet.conf" QUEUE_SINK="$T/queue-fly.txt" FLY_MACHINE_ID=m1
  "$M/bin/lane-run-worker.sh" --once ) > "$T/m-worker.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "F2 lane-run-worker --once exits 0" || bad "F2 worker rc=$rc $(cat "$T/m-worker.out")"
[ "$(rows | jq '[.rows[] | select(.project == "p1" and .status == "done" and .rc == 0)] | length')" = 1 ] \
  && ok "F2 the row is done rc 0" || bad "F2 rows: $(rows | jq -c '[.rows[] | {project,status,rc,prof_line}]'); $(tail -5 "$M/logs/lane-run-worker.log" 2>&1)"
RUNGS "$M/logs/blocked-resolver.log" > "$T/rungs-fly"
[ -s "$T/rungs-fly" ] && cmp -s "$T/rungs-ref" "$T/rungs-fly" && ok "F2 the machine took the same rungs as the hub reference" \
  || bad "F2 rungs differ: ref=[$(tr '\n' '|' < "$T/rungs-ref")] fly=[$(tr '\n' '|' < "$T/rungs-fly")]"
cmp -s "$T/queue-ref.txt" "$T/queue-fly.txt" && ok "F2 the same rebuild was enqueued" || bad "F2 queue ref=[$(cat "$T/queue-ref.txt")] fly=[$(cat "$T/queue-fly.txt")]"
[ "$(grep -cE '^(ssh|scp|rsync|run-build\.sh) ' "$T/path.log")" = 0 ] && ok "F2 path.log: 0 ssh, scp, rsync or run-build.sh" || bad "F2 path.log: $(cat "$T/path.log")"

# ============================================================================
echo "F5: the kill knob — the row set to hub returns the lane to the hub"
setting lane_placement.blocked-resolver hub
D=$( . "$HUB/bin/lib/lane-placement.sh"; lp_decide blocked-resolver; printf '%s' "$LP_PLACE")
[ "$D" = hub ] && ok "F5 lp_decide: hub" || bad "F5 lp_decide: $D"
PO=$("$HUB/bin/lane-snapshot-publish.sh")
case "$PO" in *"0 published, 0 unchanged"*"blocked-resolver placed hub"*) ok "F5 the publisher publishes nothing: $PO" ;; *) bad "F5 publisher: $PO" ;; esac
N0=$(rows | jq '.rows | length')
( bash "$HUB/bin/blocked-resolver.sh" --dispatch ) >> "$T/hub-run.log" 2>&1
[ "$(rows | jq '.rows | length')" = "$N0" ] && ok "F5 the dispatch enqueues no fly row" || bad "F5 rows: $(rows | jq -c '[.rows[] | {project,status}]')"

# ============================================================================
echo "F6: a file still on the machine is never a hub deletion"
# The cap is read again at each step. A file over the cap at checkpoint time
# (the row went down, or the run grew the file) stays out of the write-back,
# and the hub copy stays. A real delete still reaches the hub.
srv wd; export JOBS_URL="http://127.0.0.1:$PORT"
H6="$T/h6"; INSTALL "$H6" || exit 1
mkdir -p "$H6/logs" "$H6/state/build-notes/p1"
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H6/fleet.conf"
N6="state/build-notes/p1"
head -c 300000 /dev/zero | tr '\0' 'b' > "$H6/$N6/BIG-1.md"
printf 'small\n' > "$H6/$N6/SMALL-1.md"
printf 'grow\n' > "$H6/$N6/GROW-1.md"
printf 'del\n' > "$H6/$N6/DEL-1.md"
cp "$H6/$N6/BIG-1.md" "$T/f6-big.orig"
setting lane_snapshot.file_max 500000
PO=$(lib "$H6" lri_publish blocked-resolver p1 2>&1); rc=$?
case "$rc:$PO" in 0:published*) ok "F6 publish at cap 500000: $PO" ;; *) bad "F6 publish rc=$rc $PO" ;; esac
M6="$T/m6"; INSTALL "$M6" || exit 1
FO=$(lib "$M6" lri_fetch blocked-resolver p1 x 2>&1); rc=$?
[ "$rc" = 0 ] && cmp -s "$M6/$N6/BIG-1.md" "$T/f6-big.orig" && ok "F6 the machine fetched the 300,000-byte BIG-1.md" \
  || bad "F6 fetch rc=$rc $FO"
printf 'small, edited\n' > "$M6/$N6/SMALL-1.md"
head -c 270000 /dev/zero | tr '\0' 'g' >> "$M6/$N6/GROW-1.md"
rm -f "$M6/$N6/DEL-1.md"
unsetting lane_snapshot.file_max
CO=$(LANE_RUN_ID=801 lib "$M6" lri_checkpoint blocked-resolver p1 2>&1); rc=$?
[ "$rc" = 0 ] && ok "F6 checkpoint at cap 262144 rc 0 ($CO)" || bad "F6 checkpoint rc=$rc $CO"
AP=$(lib "$H6" lri_apply_pending blocked-resolver p1); rc=$?
[ "$rc:$AP" = "0:applied=1 conflicts=0 rejected=0" ] && ok "F6 hub apply: $AP" || bad "F6 hub apply rc=$rc $AP"
cmp -s "$H6/$N6/BIG-1.md" "$T/f6-big.orig" && ok "F6 the cap went down: the hub BIG-1.md stays, unchanged" \
  || bad "F6 the hub BIG-1.md is gone or changed"
[ "$(cat "$H6/$N6/GROW-1.md" 2>&1)" = grow ] && ok "F6 the run grew GROW-1.md past the cap: the hub copy stays" \
  || bad "F6 the hub GROW-1.md: $(head -c 40 "$H6/$N6/GROW-1.md" 2>&1)"
cmp -s "$H6/$N6/SMALL-1.md" "$M6/$N6/SMALL-1.md" && ok "F6 the edit of SMALL-1.md reached the hub" || bad "F6 SMALL-1.md: $(cat "$H6/$N6/SMALL-1.md" 2>&1)"
[ ! -e "$H6/$N6/DEL-1.md" ] && ok "F6 a real delete of DEL-1.md reached the hub" || bad "F6 the hub still has DEL-1.md"
for f in "BIG-1.md (300000 bytes)" "GROW-1.md (270005 bytes)"; do
  [ "$(grep -cF "checkpoint: blocked-resolver/p1 $N6/$f is over lane_snapshot.file_max=262144; not in the write-back, the hub copy stays" "$H6/logs/blocked-resolver.log")" = 1 ] \
    && ok "F6 the hub log names $f once" || bad "F6 hub log for $f: $(grep -F checkpoint: "$H6/logs/blocked-resolver.log" 2>&1)"
done
CO=$(LANE_RUN_ID=801 lib "$M6" lri_checkpoint blocked-resolver p1 2>&1); rc=$?
[ "$rc:$CO" = "0:" ] && ok "F6 the next checkpoint has nothing to send" || bad "F6 checkpoint 2 rc=$rc $CO"

echo "blocked-resolver-flip: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
