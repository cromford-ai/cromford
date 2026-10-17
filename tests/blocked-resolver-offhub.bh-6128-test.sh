#!/bin/bash
# tests/blocked-resolver-offhub.bh-6128-test.sh — BH-6128 (BH-6047 part 5 of
# 5): blocked-resolver runs on a Fly lane machine with the hub's inputs
# fetched through the jobs worker, makes the hub's decisions, and writes back
# through the worker. No ssh.
#
# Driven over real curl against the REAL jobs worker on node:sqlite
# (tests/lib/lane-snapshots-worker.bh-6128.mjs), through the real
# bin/lib/lane-run-inputs.sh, bin/lane-snapshot-publish.sh,
# bin/lane-run-worker.sh, bin/project-lane-run.sh and bin/blocked-resolver.sh.
#
#   O2  lri_member_ok: the accept and refuse table
#   O3  freshness: the _lri_fresh table; a stale, absent, truncated or
#       sha-mismatched snapshot is refused end to end
#   O4  publish -> fetch into an empty root: byte-identical files, identical
#       file and dir mtimes; the live-root guard
#   O6  compare-and-set apply: the apply and keep-hub table; the visit ledger
#       keeps the other projects' rows
#   O1  the seeded row places blocked-resolver on fly; 3 published; 3 fly
#       rows; a second dispatch is 3 already live
#   O9  the hub reference run and the machine run make the same decisions; the
#       machine run reports rc 0; no ssh, scp, rsync or run-build.sh
#   O8  the machine's ladder record reaches the worker as a write-back, a
#       second fetch overlays it, and the hub apply writes it to the hub
#   O10 an alert raised on the machine goes through lane-alert.sh; the
#       publisher appends nothing to the hub's ALERTS.log
#   O5  no snapshot: 3 rows done rc 66, no run started, ONE alert
#   O7  the write-back route answers 500: a run that exited 0 is reported
#       rc 75; a run whose per-candidate write-back fails stops and exits 75
#   O1b hub_only keeps the lane on the hub
#
# Run from anywhere: tests/blocked-resolver-offhub.bh-6128-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-6005: worker/jobs/schema.sql is composed from schema.d/, not committed.
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-6619: worker/jobs/src imports catalog/lanes.json and catalog/llm-sites.json,
# both composed and git-ignored. The worker this suite starts needs them on disk.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SRV="$DIR/tests/lib/lane-snapshots-worker.bh-6128.mjs"
LIB="$DIR/bin/lib/lane-run-inputs.sh"
PUBLISH="$DIR/bin/lane-snapshot-publish.sh"
LANEFRAG="$DIR/catalog/lanes.d/lane-snapshot-publish.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
# ONE clock read for the whole file: every fixture age is derived from it.
NOW=$(date -u +%s)

# ---------------------------------------------------------------------------
# A harness root: the lane, the publisher, the machine loop and their libs.
# The jobs client is the real one, with the queue writes recorded instead of
# sent, so a rebuild rung is a line in $QUEUE_SINK on both sides.
# ---------------------------------------------------------------------------
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
  cat > "$r/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf 'the reasoning\nREJECT\n' > "$5"
exit 0
EOF
  chmod +x "$r/bin/"*.sh
  : > "$r/env/global.env"
  mrs_fixture "$r" p1 p2 p3
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
printf 'gh %s\n' "\$*" >> "$T/gh.log"
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
export BOX_NAME=fixture-box BR_DISPATCH_SPREAD_SECS=0 BR_PER_TICK=4 BR_PER_TICK_P3=1
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
WAITFOR() { local i; for i in $(seq 1 300); do eval "$1" && return 0; sleep 0.2; done; return 1; }
# lib <root> <cmd...> — one call of the lib in a subshell rooted at <root>.
lib() { local r="$1"; shift; ( export HARNESS="$r"; . "$r/bin/lib/lane-run-inputs.sh" && "$@" ); }
# ROWADD <root> <key> <since> <url> — one conductor hand-off row.
MFT="merge-failed-twice: gh pr merge refused"
ROWADD() { mkdir -p "$1/state/merge-conductor"
  printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' "$2" "$3" "$MFT" "$4" >> "$1/state/merge-conductor/pr-state.tsv"; }
# RUNGS <log> [project] — the rungs a log dispatched, stamps stripped, sorted.
RUNGS() { grep -E '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild)|^[0-9-]+ [0-9:]+Z EVENT ' "$1" 2>/dev/null \
          | grep -F "${2:-}" | sed -E 's/^[0-9-]+ [0-9:]+Z //' | LC_ALL=C sort; }

srv wa; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/wa.err")"; exit 1; }
URL_A="http://127.0.0.1:$PORT"
srv wb; URL_B="http://127.0.0.1:$PORT"
srv wc; URL_C="http://127.0.0.1:$PORT"
export JOBS_URL="$URL_B"

# ============================================================================
echo "O2: lri_member_ok — the accept and refuse table"
. "$LIB" || { echo "setup: $LIB did not load"; exit 1; }
for m in "builds/p1-BH-1-20261012/RESULT" "state/blocked-resolver/p1/p1-BH-1.json" \
         "builds/pool-p1-BH-2-x/.blocked-resolver-held" "state/build-notes/p1/BH-1.md" \
         "state/blocked-resolver/rounds/p1-o-p1-31.json" "state/blocked-resolver/.last-visited.tsv"; do
  lri_member_ok p1 "$m" - rw && ok "O2 accept $m" || bad "O2 refused $m"
done
lri_member_ok p1 builds/p1-BH-1-20261012 d && ok "O2 accept a record dir entry" || bad "O2 record dir refused"
for m in "../etc/x" "/root/x" "builds/p1-BH-1-x/sub/file" "builds/p10-BH-1-x/RESULT" "builds/p1-os-BH-1-x/RESULT" \
         "env/global.env" "state/alerts/a.json" "builds/p1-BH-1-x/transcript.txt" "state/blocked-resolver/p2/x.json" \
         "state/blocked-resolver/p1/../../../env/global.env" "logs/ALERTS.log" "builds/p1-bh-1-x/RESULT"; do
  lri_member_ok p1 "$m" && bad "O2 accepted $m" || ok "O2 refuse $m"
done
lri_member_ok project-4 "builds/project-4-TK-1-x/RESULT" && bad "O2 project-4 accepted project-4's record" || ok "O2 refuse project-4's record for project-4"
lri_member_ok p1 "state/blocked-resolver/p1/x.json" l && bad "O2 accepted a symlink" || ok "O2 refuse a symlink member"
lri_member_ok p1 "state/blocked-resolver/p1/x.json" h && bad "O2 accepted a hardlink" || ok "O2 refuse a hardlink member"
lri_member_ok p1 "state/blocked-resolver/p1" d && bad "O2 accepted a non-record dir" || ok "O2 refuse a non-record dir entry"
for m in "state/build-notes/p1/sub/x.md" "state/blocked-resolver/rounds/p1-x/y.json" "state/blocked-resolver/unmapped/a/b"; do
  lri_member_ok p1 "$m" && bad "O2 accepted a nested $m" || ok "O2 refuse nested $m"
done
lri_member_ok p1 "state/blocked-resolver/unmapped/o-p1-31.merge" - rw && ok "O2 accept an unmapped marker" || bad "O2 unmapped marker refused"
for m in "flags/automerge-disabled" "fleet.conf" "state/merge-conductor/pr-state.tsv" "logs/merge-conductor.log" "state/build-queue/p1/BH-1.json" "plans/p1-BH-1-x/planned-files.txt"; do
  lri_member_ok p1 "$m" - ro && ok "O2 ro accepts $m" || bad "O2 ro refused $m"
  lri_member_ok p1 "$m" - rw && bad "O2 a write-back may carry $m" || ok "O2 rw refuses $m"
done
[ -z "$(lri_paths demo p1 ro)" ] && ok "O2 lri_paths: any other lane has no inputs" || bad "O2 demo paths"
( HARNESS="$T/empty"; lri_fetch demo p1 "$T/x" ) && ok "O2 lri_fetch demo: rc 0, nothing fetched" || bad "O2 lri_fetch demo rc"

# ============================================================================
echo "O3: freshness"
_lri_fresh 0 1200 && ok "O3 age 0 is fresh" || bad "O3 age 0"
_lri_fresh 1200 1200 && ok "O3 age == max is fresh" || bad "O3 age == max"
_lri_fresh 1201 1200 && bad "O3 max+1 accepted" || ok "O3 age max+1 is stale"
_lri_fresh "" 1200 && bad "O3 empty age accepted" || ok "O3 an empty age is stale"

# ============================================================================
echo "O4: publish -> fetch round trip, mtimes, and the live-root guard"
R="$T/r"; INSTALL "$R" || exit 1
mkdir -p "$R/builds/rt-BH-7-20261001" "$R/builds/pool-rt-BH-8-x" "$R/builds/rt-BH-9-old" "$R/builds/rt-os-BH-1-x" \
         "$R/state/blocked-resolver/rt/.looks" "$R/state/build-notes/rt" "$R/flags" "$R/plans/rt-BH-7-x" "$R/state/build-queue/rt"
printf 'RESULT: BUILT\n' > "$R/builds/rt-BH-7-20261001/RESULT"
printf '{"ticket_id":"7"}\n' > "$R/builds/rt-BH-7-20261001/job.json"
printf 'transcript\n' > "$R/builds/rt-BH-7-20261001/transcript.txt"
printf 'old\n' > "$R/builds/rt-BH-9-old/RESULT"
printf 'other project\n' > "$R/builds/rt-os-BH-1-x/RESULT"
: > "$R/builds/pool-rt-BH-8-x/.blocked-resolver-held"
printf '{"rkey":"k"}\n' > "$R/state/blocked-resolver/rt/k.json"
printf 'look\n' > "$R/state/blocked-resolver/rt/.looks/k"
printf 'note\n' > "$R/state/build-notes/rt/BH-7.md"
: > "$R/flags/fly-pool-rt"
printf 'a.sh\n' > "$R/plans/rt-BH-7-x/planned-files.txt"
printf '{"k":1}\n' > "$R/state/build-queue/rt/BH-7.json"
printf 'rt o/rt - - 2 box-rt 192.0.2.7\n' > "$R/fleet.conf"
mkdir -p "$R/logs"; printf '2026-10-12 00:00:00Z x BLOCKED_AGENT y: z handed to bin/blocked-resolver.sh https://github.com/o/rt/pull/1\nnoise\n' > "$R/logs/merge-conductor.log"
head -c 300000 /dev/zero > "$R/builds/rt-BH-7-20261001/review.md"
touch -d "@$((NOW - 3600))" "$R/builds/rt-BH-7-20261001/RESULT" "$R/state/blocked-resolver/rt/k.json"
touch -d "@$((NOW - 7200))" "$R/builds/rt-BH-7-20261001"
touch -d "@$((NOW - 86400 * 40))" "$R/builds/rt-BH-9-old/RESULT" "$R/builds/rt-BH-9-old"
OUT=$(lib "$R" lri_publish blocked-resolver rt); rc=$?
case "$rc:$OUT" in 0:published*) ok "O4 publish: $OUT" ;; *) bad "O4 publish rc=$rc $OUT $(tail -3 "$T/wb.log")" ;; esac
OUT2=$(lib "$R" lri_publish blocked-resolver rt); rc=$?
case "$rc:$OUT2" in 0:unchanged*) ok "O4 a second publish of the same tree uploads no part" ;; *) bad "O4 second publish rc=$rc $OUT2" ;; esac
[ "$(grep -c '^PUT /api/lane-snapshots/blocked-resolver/rt/parts/' "$T/wb.log")" = 1 ] && ok "O4 one part PUT in total" || bad "O4 part PUTs: $(grep -c PUT "$T/wb.log")"
M4="$T/m4"; INSTALL "$M4" || exit 1
FO=$(lib "$M4" lri_fetch blocked-resolver rt "$M4/state/blocked-resolver/rt" 2>&1); rc=$?
[ "$rc" = 0 ] && case "$FO" in "inputs: snapshot "*" + 0 write-backs, age "*) true ;; *) false ;; esac \
  && ok "O4 fetch rc 0: $FO" || bad "O4 fetch rc=$rc $FO"
SAME=1
for f in builds/rt-BH-7-20261001/RESULT builds/rt-BH-7-20261001/job.json builds/pool-rt-BH-8-x/.blocked-resolver-held \
         state/blocked-resolver/rt/k.json state/blocked-resolver/rt/.looks/k state/build-notes/rt/BH-7.md flags/fly-pool-rt \
         plans/rt-BH-7-x/planned-files.txt state/build-queue/rt/BH-7.json fleet.conf; do
  cmp -s "$R/$f" "$M4/$f" && [ "$(stat -c %Y "$R/$f")" = "$(stat -c %Y "$M4/$f")" ] || { SAME=0; bad "O4 $f differs (bytes or mtime)"; }
done
[ "$SAME" = 1 ] && ok "O4 every file is byte-identical with the same mtime"
[ "$(stat -c %Y "$R/builds/rt-BH-7-20261001")" = "$(stat -c %Y "$M4/builds/rt-BH-7-20261001")" ] \
  && ok "O4 the record dir keeps its mtime" || bad "O4 dir mtime $(stat -c %Y "$R/builds/rt-BH-7-20261001") vs $(stat -c %Y "$M4/builds/rt-BH-7-20261001")"
[ ! -e "$M4/builds/rt-BH-7-20261001/transcript.txt" ] && [ ! -e "$M4/builds/rt-BH-7-20261001/review.md" ] \
  && ok "O4 a transcript and a file over 256 KB stay on the hub" || bad "O4 unlisted or oversize record file fetched"
[ ! -e "$M4/builds/rt-BH-9-old" ] && ok "O4 a record older than builds_days stays on the hub" || bad "O4 old record fetched"
[ ! -e "$M4/builds/rt-os-BH-1-x" ] && ok "O4 another project's record (rt-os) stays out" || bad "O4 rt-os record fetched"
[ "$(cat "$M4/logs/merge-conductor.log")" = "$(grep 'handed to' "$R/logs/merge-conductor.log")" ] \
  && ok "O4 the conductor log carries only its hand-off lines" || bad "O4 conductor log: $(cat "$M4/logs/merge-conductor.log")"
[ ! -e "$M4/env/global.env" ] || [ ! -s "$M4/env/global.env" ] && ok "O4 env/ never rides" || bad "O4 env fetched"
# The live-root guard: a populated builds/ with no .managed is a live harness.
G="$T/g"; mkdir -p "$G/builds/p-BH-1-x"; cp -r "$M4/bin" "$M4/catalog" "$G/"
FO=$(lib "$G" lri_fetch blocked-resolver rt x 2>&1); rc=$?
[ "$rc" = 2 ] && ok "O4 a populated root without .managed is refused rc 2" || bad "O4 guard rc=$rc $FO"
[ ! -e "$G/fleet.conf" ] && ok "O4 the refused root is unchanged" || bad "O4 guard wrote into the root"
G2="$T/g2"; mkdir -p "$G2/builds"; cp -r "$M4/bin" "$G2/"
lib "$G2" lri_fetch blocked-resolver rt x >/dev/null 2>&1 && ok "O4 an empty builds/ is fetched into" || bad "O4 empty builds refused"
G3="$T/g3"; mkdir -p "$G3"; cp -r "$M4/bin" "$G3/"
lib "$G3" lri_fetch blocked-resolver rt x >/dev/null 2>&1 && ok "O4 an absent builds/ is fetched into" || bad "O4 absent builds refused"
lib "$M4" lri_fetch blocked-resolver rt x >/dev/null 2>&1 && ok "O4 a root with .managed is fetched into again" || bad "O4 .managed root refused"

echo "O3: a stale, absent, truncated or sha-mismatched snapshot is refused"
sql "UPDATE lane_snapshots SET published_at='2026-01-01T00:00:00Z' WHERE project='rt'" >/dev/null
lib "$M4" lri_fetch blocked-resolver rt x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "O3 a stale snapshot is refused rc 2" || bad "O3 stale rc=$rc"
setting lane_snapshot.max_age_s 99999999
lib "$M4" lri_fetch blocked-resolver rt x >/dev/null 2>&1 && ok "O3 lane_snapshot.max_age_s is read from settings" || bad "O3 setting not read"
unsetting lane_snapshot.max_age_s
lib "$R" lri_publish blocked-resolver rt >/dev/null
lib "$M4" lri_fetch blocked-resolver nosuch x >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "O3 no snapshot (404) is rc 1" || bad "O3 404 rc=$rc"
setting lane_snapshot.max_pending 1
for i in 1 2; do sql "INSERT INTO lane_snapshot_writebacks (lane,project,run_id,machine,sha,b64,created_at) VALUES ('blocked-resolver','rt','r$i','m','$(printf '%064d' "$i")','eA==','2026-10-12T00:00:00Z')" >/dev/null; done
lib "$M4" lri_fetch blocked-resolver rt x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "O3 a truncated write-back list is refused rc 2" || bad "O3 truncated rc=$rc"
unsetting lane_snapshot.max_pending
lib "$M4" lri_fetch blocked-resolver rt x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "O3 a write-back whose sha does not match is refused rc 2" || bad "O3 wb sha rc=$rc"
sql "DELETE FROM lane_snapshot_writebacks WHERE project='rt'" >/dev/null
sql "UPDATE lane_snapshots SET sha='$(printf '%064d' 7)' WHERE project='rt'" >/dev/null
sql "UPDATE lane_snapshot_parts SET sha='$(printf '%064d' 7)' WHERE project='rt'" >/dev/null
cp "$M4/fleet.conf" "$T/fleet.before"
lib "$M4" lri_fetch blocked-resolver rt x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "O3 a snapshot whose parts do not match its sha is refused rc 2" || bad "O3 sha rc=$rc"
cmp -s "$T/fleet.before" "$M4/fleet.conf" && [ -e "$M4/state/blocked-resolver/rt/k.json" ] \
  && ok "O3 a refused fetch leaves the previous overlay in place" || bad "O3 refused fetch changed the root"

# ============================================================================
echo "O6: compare-and-set apply"
lib "$R" lri_publish blocked-resolver rt >/dev/null
M6="$T/m6"; INSTALL "$M6" || exit 1
printf 'pa\tx\n' > "$R/state/blocked-resolver/.last-visited.tsv"
printf 'rt\t1\t1\t0\n' >> "$R/state/blocked-resolver/.last-visited.tsv"
printf 'zz\t5\t5\t0\n' >> "$R/state/blocked-resolver/.last-visited.tsv"
mkdir -p "$R/state/blocked-resolver/rt"
for f in a b d e; do printf 'base %s\n' "$f" > "$R/state/blocked-resolver/rt/$f.json"; done
lib "$R" lri_publish blocked-resolver rt >/dev/null
lib "$M6" lri_fetch blocked-resolver rt x >/dev/null 2>&1 || bad "O6 fetch failed"
S="$M6/state/blocked-resolver/rt"
printf 'machine a\n' > "$S/a.json"          # hub untouched         -> applied
printf 'machine b\n' > "$S/b.json"          # hub changed too       -> conflict
printf 'machine c\n' > "$S/c.json"          # new, hub absent       -> applied
rm -f "$S/d.json"                           # deleted, hub == base  -> deleted
rm -f "$S/e.json"                           # deleted, hub changed  -> conflict
printf 'machine f\n' > "$S/f.json"          # new, hub created too  -> conflict
printf 'rt\t9\t1\t0\n' >> "$M6/state/blocked-resolver/.last-visited.tsv"
awk -F'\t' '!($1 == "rt" && $2 == 1)' "$M6/state/blocked-resolver/.last-visited.tsv" > "$T/lv" && cat "$T/lv" > "$M6/state/blocked-resolver/.last-visited.tsv"
CO=$(LANE_RUN_ID=601 lib "$M6" lri_checkpoint blocked-resolver rt 2>&1); rc=$?
[ "$rc" = 0 ] && ok "O6 checkpoint posted: $CO" || bad "O6 checkpoint rc=$rc $CO"
CO2=$(LANE_RUN_ID=601 lib "$M6" lri_checkpoint blocked-resolver rt 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$CO2" ] && ok "O6 a second checkpoint with nothing changed sends nothing" || bad "O6 second checkpoint rc=$rc '$CO2'"
printf 'hub b\n' > "$R/state/blocked-resolver/rt/b.json"
printf 'hub e\n' > "$R/state/blocked-resolver/rt/e.json"
printf 'hub f\n' > "$R/state/blocked-resolver/rt/f.json"
printf 'zz\t6\t5\t0\n' > "$T/zz"; awk -F'\t' '$1 != "zz"' "$R/state/blocked-resolver/.last-visited.tsv" > "$T/lv"; cat "$T/lv" "$T/zz" > "$R/state/blocked-resolver/.last-visited.tsv"
AP=$(lib "$R" lri_apply_pending blocked-resolver rt); rc=$?
[ "$rc" = 0 ] && [ "$AP" = "applied=1 conflicts=3 rejected=0" ] && ok "O6 apply: $AP" || bad "O6 apply rc=$rc '$AP'"
H6="$R/state/blocked-resolver/rt"
[ "$(cat "$H6/a.json")" = "machine a" ] && ok "O6 hub == base: the machine's copy is applied" || bad "O6 a: $(cat "$H6/a.json")"
[ "$(cat "$H6/c.json")" = "machine c" ] && ok "O6 absent on both sides: the new file is applied" || bad "O6 c: $(cat "$H6/c.json" 2>&1)"
[ ! -e "$H6/d.json" ] && ok "O6 a machine delete with hub == base deletes" || bad "O6 d still there"
[ "$(cat "$H6/b.json")" = "hub b" ] && ok "O6 hub changed since base: the hub keeps its copy" || bad "O6 b: $(cat "$H6/b.json")"
[ "$(cat "$H6/e.json")" = "hub e" ] && ok "O6 a machine delete with hub changed keeps the hub file" || bad "O6 e: $(cat "$H6/e.json" 2>&1)"
[ "$(cat "$H6/f.json")" = "hub f" ] && ok "O6 base absent and hub now present: the hub keeps its file" || bad "O6 f: $(cat "$H6/f.json")"
LV="$R/state/blocked-resolver/.last-visited.tsv"
[ "$(awk -F'\t' '$1 == "rt"' "$LV")" = "$(printf 'rt\t9\t1\t0')" ] && ok "O6 the project's visit row is the machine's" || bad "O6 rt row: $(cat "$LV")"
[ "$(awk -F'\t' '$1 == "zz"' "$LV")" = "$(printf 'zz\t6\t5\t0')" ] && grep -q '^pa' "$LV" && ok "O6 the other projects' rows stay the hub's" || bad "O6 other rows: $(cat "$LV")"
AP2=$(lib "$R" lri_apply_pending blocked-resolver rt); rc=$?
[ "$rc" = 0 ] && [ "$AP2" = "applied=0 conflicts=0 rejected=0" ] && ok "O6 the acked write-back is not applied twice" || bad "O6 re-apply '$AP2'"
# A write-back carrying a path outside the rw allow-list is rejected, and the
# hub file it names is not touched.
printf 'secret-fixture\n' > "$R/env/global.env"
mkdir -p "$T/evil/.lri"; printf 'env/global.env\tx\n' > "$T/evil/.lri/base.tsv"; printf 'env/global.env\n' > "$T/evil/.lri/deletions"
( cd "$T/evil" && tar -czf "$T/evil.tgz" .lri/base.tsv .lri/deletions )
sql "INSERT INTO lane_snapshot_writebacks (lane,project,run_id,machine,sha,b64,created_at) VALUES ('blocked-resolver','rt','evil','m','$(sha256sum "$T/evil.tgz" | cut -d' ' -f1)','$(base64 -w0 "$T/evil.tgz")','2026-10-12T00:00:00Z')" >/dev/null
AP3=$(lib "$R" lri_apply_pending blocked-resolver rt)
[ "$AP3" = "applied=0 conflicts=0 rejected=1" ] && [ "$(cat "$R/env/global.env")" = "secret-fixture" ] \
  && ok "O6 a write-back naming env/global.env is rejected and the file stays" || bad "O6 evil: '$AP3' $(cat "$R/env/global.env" 2>&1)"
# WBROW <run_id> <archive> — one write-back row, straight into D1.
WBROW() { sql "INSERT INTO lane_snapshot_writebacks (lane,project,run_id,machine,sha,b64,created_at) VALUES ('blocked-resolver','rt','$1','m','$(sha256sum "$2" | cut -d' ' -f1)','$(base64 -w0 "$2")','2026-10-12T00:00:00Z')" >/dev/null; }
# A base.tsv line that starts with a TAB once read as an empty path in the
# validator and as a real path in the apply (security review). It names a hub
# file by its true sha and carries no copy, so the old apply deleted it.
mkdir -p "$R/flags"; printf 'off\n' > "$R/flags/lane-off-fixture"
mkdir -p "$T/tab/.lri"; printf '\tflags/lane-off-fixture\t%s\n' "$(sha256sum "$R/flags/lane-off-fixture" | cut -d' ' -f1)" > "$T/tab/.lri/base.tsv"; : > "$T/tab/.lri/deletions"
( cd "$T/tab" && tar -czf "$T/tab.tgz" .lri/base.tsv .lri/deletions )
lib "$R" _lri_validate rt "$T/tab.tgz" writeback && bad "O6 a leading-TAB base.tsv line passed validation" || ok "O6 a leading-TAB base.tsv line fails validation"
WBROW tab "$T/tab.tgz"
AP4=$(lib "$R" lri_apply_pending blocked-resolver rt)
[ "$AP4" = "applied=0 conflicts=0 rejected=1" ] && [ "$(cat "$R/flags/lane-off-fixture" 2>&1)" = off ] \
  && ok "O6 a leading-TAB write-back is rejected and the hub flag stays" || bad "O6 tab: '$AP4' $(cat "$R/flags/lane-off-fixture" 2>&1)"
# The one parser both sides use: the accept and refuse table.
SHA64=$(printf '%064d' 0 | tr 0 a)
lib "$R" _lri_base_line rt "$(printf 'state/blocked-resolver/rt/a.json\t%s' "$SHA64")" && ok "O6 base line: path TAB sha accepted" || bad "O6 base line: a good line refused"
lib "$R" _lri_base_line rt "$(printf 'state/blocked-resolver/rt/a.json\t-')" && ok "O6 base line: path TAB - accepted" || bad "O6 base line: a '-' base refused"
for L in "$(printf '\tstate/blocked-resolver/rt/a.json\t%s' "$SHA64")" "$(printf 'state/blocked-resolver/rt/a.json\t%s\tx' "$SHA64")" \
         "$(printf 'state/blocked-resolver/rt/a.json\tx')" "$(printf 'state/blocked-resolver/rt/../../../bin/x.sh\t%s' "$SHA64")" \
         "$(printf 'flags/lane-off-fixture\t%s' "$SHA64")" "$(printf 'state/blocked-resolver/.last-visited.tsv\t%s' "$SHA64")" \
         "state/blocked-resolver/rt/a.json" ""; do
  lib "$R" _lri_base_line rt "$L" && bad "O6 base line accepted: $(printf '%q' "$L")" || ok "O6 base line refused: $(printf '%q' "$L")"
done
# Log bytes: the hub caps them at LRI_LOG_APPEND_MAX, and a re-apply after a
# lost ack does not append them twice.
mkdir -p "$T/lg/.lri" "$R/logs"; : > "$T/lg/.lri/base.tsv"; : > "$T/lg/.lri/deletions"
head -c 300000 /dev/zero | tr '\0' 'L' > "$T/lg/.lri/log-append"
( cd "$T/lg" && tar -czf "$T/lg.tgz" .lri/base.tsv .lri/deletions .lri/log-append )
WBROW logdup "$T/lg.tgz"
L0=$(stat -c %s "$R/logs/blocked-resolver.log" 2>/dev/null || echo 0)
AP5=$(lib "$R" lri_apply_pending blocked-resolver rt)
L1=$(stat -c %s "$R/logs/blocked-resolver.log")
[ "$AP5" = "applied=1 conflicts=0 rejected=0" ] && [ "$((L1 - L0))" = 262144 ] \
  && ok "O6 the hub appends at most LRI_LOG_APPEND_MAX log bytes" || bad "O6 log cap: '$AP5' grew $((L1 - L0))"
sql "UPDATE lane_snapshot_writebacks SET applied_at = NULL WHERE run_id = 'logdup'" >/dev/null
AP6=$(lib "$R" lri_apply_pending blocked-resolver rt)
L2=$(stat -c %s "$R/logs/blocked-resolver.log")
[ "$AP6" = "applied=1 conflicts=0 rejected=0" ] && [ "$L2" = "$L1" ] \
  && ok "O6 a re-apply after a lost ack does not append the log bytes twice" || bad "O6 log re-apply: '$AP6' grew $((L2 - L1))"

# ============================================================================
# The fixture hub for O1, O9, O8, O10: three projects, each with conductor
# hand-off parks (merge-failed-twice -> a rebuild-fresh rung); p3 has two
# three-hour-old parks and a one-rung share, so one waits and pages UNTOUCHED.
# ============================================================================
HUB="$T/hub"; INSTALL "$HUB" || exit 1
mkdir -p "$HUB/flags" "$HUB/logs" "$HUB/state" "$HUB/locks" "$HUB/builds"
for I in 1 2 3; do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$I" "$I" "$I" "$I"; touch "$HUB/flags/fly-pool-p$I" "$HUB/flags/builder-fly-p$I"; done > "$HUB/fleet.conf"
ROWADD "$HUB" "o/p1#31" "$NOW" "https://github.com/o/p1/pull/31"
ROWADD "$HUB" "o/p2#41" "$NOW" "https://github.com/o/p2/pull/41"
ROWADD "$HUB" "o/p3#44" "$((NOW - 10800))" "https://github.com/o/p3/pull/44"
ROWADD "$HUB" "o/p3#45" "$((NOW - 10800))" "https://github.com/o/p3/pull/45"
: > "$HUB/logs/ALERTS.log"
REF="$T/ref"; cp -a "$HUB" "$REF"

echo "O9 (reference): the hub run of each project, against worker A"
: > "$T/queue-ref.txt"
for p in p1 p2 p3; do
  ( export HARNESS="$REF" FLEET_CONF="$REF/fleet.conf" JOBS_URL="$URL_A" QUEUE_SINK="$T/queue-ref.txt"
    bash "$REF/bin/blocked-resolver.sh" "$p" ) >> "$T/ref-run.log" 2>&1
done
RUNGS "$REF/logs/blocked-resolver.log" > "$T/rungs-ref"
[ "$(grep -c -- '-> rebuild-fresh' "$T/rungs-ref")" = 3 ] && [ "$(grep -c . "$T/queue-ref.txt")" = 3 ] \
  && ok "O9 the reference run took 3 rungs and enqueued 3 rebuilds" || bad "O9 reference rungs: $(cat "$T/rungs-ref"); $(tail -5 "$REF/logs/blocked-resolver.log" 2>&1)"

# ============================================================================
echo "O1: with no placement row blocked-resolver stays on the hub; the row places it on fly"
export HARNESS="$HUB" FLEET_CONF="$HUB/fleet.conf"
# BH-6260 seeds the flip (schema.d/0025); tests/blocked-resolver-flip.bh-6260-test.sh
# pins that. The row is removed here to model the state before the flip.
unsetting lane_placement.blocked-resolver
D=$( . "$HUB/bin/lib/lane-placement.sh"; lp_decide blocked-resolver; printf '%s' "$LP_PLACE")
[ "$D" = hub ] && ok "O1 lp_decide blocked-resolver with no placement row: hub" || bad "O1 lp_decide with no row: $D"
PO=$("$HUB/bin/lane-snapshot-publish.sh")
case "$PO" in *"0 published, 0 unchanged"*"blocked-resolver placed hub"*) ok "O1 the publisher publishes nothing before the flip" ;; *) bad "O1 publisher before the flip: $PO" ;; esac
setting lane_placement.blocked-resolver fly
D=$( . "$HUB/bin/lib/lane-placement.sh"; lp_decide blocked-resolver; printf '%s|%s' "$LP_PLACE" "$LP_WHY")
[ "$D" = "fly|lane_placement.blocked-resolver=fly" ] && ok "O1 lp_decide blocked-resolver: $D (operator row)" || bad "O1 lp_decide: $D"
[ "$(jq -r .cadence "$LANEFRAG")" = "2,12,22,32,42,52 * * * *" ] && [ "$(jq -r '.boxes|join(",")' "$LANEFRAG")" = hub ] \
  && ok "O1 the publisher runs on the hub 2 minutes before each dispatch" || bad "O1 lane fragment: $(jq -c '{cadence,boxes}' "$LANEFRAG")"
cmp -s "$PUBLISH" "$HUB/bin/lane-snapshot-publish.sh" && ok "O1 the hub runs the publisher this tree ships" || bad "O1 publisher not installed"
cp "$HUB/logs/ALERTS.log" "$T/alerts-before"
PO=$("$HUB/bin/lane-snapshot-publish.sh"); rc=$?
case "$rc:$PO" in "0:lane-snapshot-publish: 3 published, 0 unchanged, 0 write-backs applied, 0 conflicts, 0 rejected, 0 failed; blocked-resolver placed fly"*) ok "O1 publisher: 3 published" ;; *) bad "O1 publisher rc=$rc: $PO" ;; esac
( bash "$HUB/bin/blocked-resolver.sh" --dispatch ) >> "$T/hub-run.log" 2>&1
grep -q 'placed: 3 fly, 0 hub (lane_placement.blocked-resolver=fly)' "$HUB/logs/blocked-resolver.log" \
  && ok "O1 dispatch: placed: 3 fly, 0 hub" || bad "O1 dispatch: $(grep dispatch: "$HUB/logs/blocked-resolver.log")"
[ "$(rows | jq '[.rows[] | select(.lane == "blocked-resolver" and .status == "queued")] | length')" = 3 ] \
  && ok "O1 3 queued rows" || bad "O1 rows: $(rows | jq -c '[.rows[] | {lane,project,status}]')"
( bash "$HUB/bin/blocked-resolver.sh" --dispatch ) >> "$T/hub-run.log" 2>&1
grep -q 'placed: 0 fly, 0 hub (lane_placement.blocked-resolver=fly), 3 already live' "$HUB/logs/blocked-resolver.log" \
  && ok "O1 a second dispatch: 3 already live" || bad "O1 second dispatch: $(grep dispatch: "$HUB/logs/blocked-resolver.log" | tail -1)"
[ "$(rows | jq '.rows | length')" = 3 ] && ok "O1 no second row" || bad "O1 rows: $(rows | jq '.rows | length')"
[ -z "$(RUNGS "$HUB/logs/blocked-resolver.log")" ] && [ ! -d "$HUB/state/blocked-resolver/p1" ] \
  && ok "O1 the hub ran no rung" || bad "O1 hub rungs: $(RUNGS "$HUB/logs/blocked-resolver.log")"

# ============================================================================
echo "O9: the machine run in an empty scratch root, against worker B"
M="$T/m"; INSTALL "$M" || exit 1
[ ! -e "$M/builds" ] && [ ! -e "$M/state/blocked-resolver" ] && [ ! -e "$M/logs" ] && ok "O9 the machine root has no builds/, state/ or logs/" || bad "O9 machine root not empty"
: > "$T/path.log"; : > "$T/queue-fly.txt"
( export HARNESS="$M" FLEET_CONF="$M/fleet.conf" QUEUE_SINK="$T/queue-fly.txt" FLY_MACHINE_ID=m1
  "$M/bin/lane-run-worker.sh" --once ) > "$T/m-worker.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "O9 lane-run-worker --once exits 0" || bad "O9 worker rc=$rc $(cat "$T/m-worker.out")"
R9=$(rows)
[ "$(jq '[.rows[] | select(.status == "done" and .rc == 0)] | length' <<<"$R9")" = 3 ] \
  && ok "O9 3 rows done rc 0" || bad "O9 rows: $(jq -c '[.rows[] | {project,status,rc,prof_line}]' <<<"$R9"); $(cat "$M/logs/lane-run-worker.log" 2>&1 | tail -5)"
grep -q 'inputs: snapshot [0-9a-f]\{12\} + 0 write-backs, age [0-9]*s' "$M/logs/lane-run-worker.log" \
  && ok "O9 the worker logs what it fetched" || bad "O9 worker log: $(cat "$M/logs/lane-run-worker.log")"
RUNGS "$M/logs/blocked-resolver.log" > "$T/rungs-fly"
[ -s "$T/rungs-fly" ] && cmp -s "$T/rungs-ref" "$T/rungs-fly" && ok "O9 the machine took the same rungs as the hub reference" \
  || bad "O9 rungs differ: ref=[$(tr '\n' '|' < "$T/rungs-ref")] fly=[$(tr '\n' '|' < "$T/rungs-fly")]"
[ -s "$T/queue-fly.txt" ] && cmp -s <(LC_ALL=C sort "$T/queue-ref.txt") <(LC_ALL=C sort "$T/queue-fly.txt") \
  && ok "O9 the same rebuilds were enqueued" || bad "O9 queue ref=[$(cat "$T/queue-ref.txt")] fly=[$(cat "$T/queue-fly.txt")]"
[ "$(grep -cE '^(ssh|scp|rsync|run-build\.sh) ' "$T/path.log")" = 0 ] && ok "O9 path.log: 0 ssh, scp, rsync or run-build.sh" || bad "O9 path.log: $(cat "$T/path.log")"
SAMEREC=1
for p in p1 p2 p3; do
  [ "$(cd "$M/state/blocked-resolver/$p" 2>/dev/null && ls -- *.json)" = "$(cd "$REF/state/blocked-resolver/$p" 2>/dev/null && ls -- *.json)" ] \
    || { SAMEREC=0; bad "O9 $p ladder records: machine $(ls "$M/state/blocked-resolver/$p/" 2>&1) ref $(ls "$REF/state/blocked-resolver/$p/" 2>&1)"; }
done
[ "$SAMEREC" = 1 ] && ok "O9 the machine wrote the same ladder record files"

# ============================================================================
echo "O8: the machine's writes reach the hub through the worker"
NWB=$(sql "SELECT COUNT(*) AS n FROM lane_snapshot_writebacks WHERE lane='blocked-resolver' AND project='p1'" | jq '.rows[0].n')
[ "${NWB:-0}" -ge 1 ] && ok "O8 p1 has $NWB write-back row(s)" || bad "O8 write-backs: $NWB"
CK=$(cd "$M/state/blocked-resolver/p1" && ls -- *.json | head -1)
[ -n "$CK" ] && [ ! -e "$HUB/state/blocked-resolver/p1/$CK" ] && ok "O8 before the apply the hub has no p1/$CK" || bad "O8 hub already has '$CK'"
M8="$T/m8"; INSTALL "$M8" || exit 1
lib "$M8" lri_fetch blocked-resolver p1 x > "$T/m8.out" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$M/state/blocked-resolver/p1/$CK" "$M8/state/blocked-resolver/p1/$CK" \
  && ok "O8 a second fetch before the apply overlays the write-back: $(cat "$T/m8.out")" || bad "O8 second fetch rc=$rc $(cat "$T/m8.out")"
AP=$(lib "$HUB" lri_apply_pending blocked-resolver p1); rc=$?
case "$rc:$AP" in "0:applied="[1-9]*" conflicts=0 rejected=0") ok "O8 hub apply: $AP" ;; *) bad "O8 hub apply rc=$rc $AP" ;; esac
cmp -s "$M/state/blocked-resolver/p1/$CK" "$HUB/state/blocked-resolver/p1/$CK" && ok "O8 the hub's p1/$CK equals the machine's" || bad "O8 hub file differs"
grep -q -- '-> rebuild-fresh' "$HUB/logs/blocked-resolver.log" && ok "O8 the machine's log lines reached the hub's log" || bad "O8 hub log: $(tail -3 "$HUB/logs/blocked-resolver.log")"

echo "O8: a hub run of one project applies that project's write-backs first"
CK2=$(cd "$M/state/blocked-resolver/p2" && ls -- *.json | head -1)
[ -n "$CK2" ] && [ ! -e "$HUB/state/blocked-resolver/p2/$CK2" ] && ok "O8 before the hub run the hub has no p2/$CK2" || bad "O8 hub already has p2 '$CK2'"
HLOG0=$(grep -c . "$HUB/logs/blocked-resolver.log")
( bash "$HUB/bin/blocked-resolver.sh" p2 ) >> "$T/hub-run.log" 2>&1
[ "$(sql "SELECT COUNT(*) AS n FROM lane_snapshot_writebacks WHERE project='p2' AND applied_at IS NULL" | jq '.rows[0].n')" = 0 ] \
  && ok "O8 p2's write-backs are applied and acked" || bad "O8 p2 write-backs still pending"
# The machine already spent rebuild 1 of 3 on TK-41. A hub run that read the
# machine's ladder record counts it; one that did not would say 1 of 3 again.
tail -n +"$((HLOG0 + 1))" "$HUB/logs/blocked-resolver.log" > "$T/hub-p2.log"
grep -q 'EVENT resolver_rung p2/p2-TK-41 .*rebuild 2 of 3' "$T/hub-p2.log" \
  && ok "O8 the hub run of p2 counted the machine's rebuild (rebuild 2 of 3)" || bad "O8 hub p2 run: $(grep 'p2' "$T/hub-p2.log" | tail -4)"

# ============================================================================
echo "O10: an alert raised on the machine goes through lane-alert.sh"
grep -q 'UNTOUCHED' "$T/alerts-m.txt" 2>/dev/null && grep 'UNTOUCHED' "$T/alerts-m.txt" | grep -q -- '--id br-untouched-p3' \
  && ok "O10 the machine's UNTOUCHED alert went through lane-alert.sh with its id" || bad "O10 machine alerts: $(cat "$T/alerts-m.txt" 2>&1)"
PO=$("$HUB/bin/lane-snapshot-publish.sh"); rc=$?
case "$PO" in *" 0 failed"*) ok "O10 publisher after the run: $PO" ;; *) bad "O10 publisher rc=$rc $PO" ;; esac
cmp -s "$T/alerts-before" "$HUB/logs/ALERTS.log" && ok "O10 nothing was appended to the hub's ALERTS.log" || bad "O10 hub ALERTS.log: $(cat "$HUB/logs/ALERTS.log")"

# ============================================================================
echo "O5: no snapshot -> rc 66, no run, ONE alert"
export JOBS_URL="$URL_C"
setting lane_placement.blocked-resolver fly
( bash "$HUB/bin/blocked-resolver.sh" --dispatch ) >> "$T/hub-run.log" 2>&1
M5="$T/m5"; INSTALL "$M5" || exit 1
( export HARNESS="$M5" FLEET_CONF="$M5/fleet.conf" QUEUE_SINK="$T/queue-m5.txt" FLY_MACHINE_ID=m5
  "$M5/bin/lane-run-worker.sh" --once ) > "$T/m5-worker.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "O5 the worker exits 0" || bad "O5 worker rc=$rc"
R5=$(rows)
[ "$(jq '[.rows[] | select(.status == "done" and .rc == 66 and (.prof_line | startswith("PROF lri_fetch rc=1 blocked-resolver/")))] | length' <<<"$R5")" = 3 ] \
  && ok "O5 3 rows done rc 66 with the lri_fetch PROF line" || bad "O5 rows: $(jq -c '[.rows[] | {project,status,rc,prof_line}]' <<<"$R5")"
[ ! -e "$M5/logs/blocked-resolver.log" ] && [ ! -e "$M5/logs/blocked-resolver-cron.log" ] && ok "O5 no lane process started" || bad "O5 a run started: $(cat "$M5/logs/blocked-resolver-cron.log" 2>&1)"
[ "$(grep -c 'lane-inputs-blocked-resolver' "$T/alerts-m5.txt" 2>/dev/null)" = 1 ] && grep -q 'blocked-resolver/p' "$T/alerts-m5.txt" \
  && ok "O5 exactly 1 lane-alert line for 3 failed fetches, naming a project" || bad "O5 alerts: $(cat "$T/alerts-m5.txt" 2>&1)"
[ "$(jq '[.rows[] | select(.attempts != 1)] | length' <<<"$R5")" = 0 ] && ok "O5 attempts unchanged by the report" || bad "O5 attempts"

# ============================================================================
echo "O7: the write-back route answers 500"
export JOBS_URL="$URL_B"
# O7a. A run that exits 0 and whose final write-back fails is reported 75,
# never 0. The row's command is a stand-in that writes one log line and exits
# 0, so the final checkpoint is the only write-back of the run.
printf '#!/bin/bash\necho "fixture line from a run that exits 0" >> "$HARNESS/logs/blocked-resolver.log"\nexit 0\n' > "$M/bin/fake-wb-lane.sh"
chmod +x "$M/bin/fake-wb-lane.sh"
"$HUB/bin/lane-snapshot-publish.sh" > /dev/null
curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
  -d '{"lane":"blocked-resolver","project":"p1","args":["bin/fake-wb-lane.sh"]}' "$JOBS_URL/api/lane-runs" > /dev/null
hook PUT __fail '{"method":"POST","match":"/writebacks","status":500}' >/dev/null
( export HARNESS="$M" FLEET_CONF="$M/fleet.conf" FLY_MACHINE_ID=m1
  "$M/bin/lane-run-worker.sh" --once ) > "$T/m7a-worker.out" 2>&1
R7=$(rows)
P1=$(jq -c '[.rows[] | select(.project == "p1")] | last' <<<"$R7")
[ "$(jq -r .rc <<<"$P1")" = 75 ] && [ "$(jq -r .status <<<"$P1")" = done ] && grep -q 'blocked-resolver/p1 rc 0: the final write-back failed (checkpoint: write-back not accepted (http 500))' "$M/logs/lane-run-worker.log" \
  && ok "O7 a run that exited 0 with a failed final write-back is done rc 75" || bad "O7 p1: $P1 $(grep p1 "$M/logs/lane-run-worker.log" | tail -2)"
[ "$(jq -r .prof_line <<<"$P1")" = "PROF lri_checkpoint failed blocked-resolver/p1" ] && ok "O7 the PROF line names the write-back" || bad "O7 prof: $(jq -r .prof_line <<<"$P1")"
# O7b. The real lane: p2's write-back after its first candidate fails, so the
# run stops there, says why, and exits 75; its second new park waits.
ROWADD "$HUB" "o/p2#61" "$NOW" "https://github.com/o/p2/pull/61"
ROWADD "$HUB" "o/p2#62" "$NOW" "https://github.com/o/p2/pull/62"
hook DELETE __fail >/dev/null
"$HUB/bin/lane-snapshot-publish.sh" > /dev/null
( bash "$HUB/bin/blocked-resolver.sh" --dispatch ) >> "$T/hub-run.log" 2>&1
hook PUT __fail '{"method":"POST","match":"/writebacks","status":500}' >/dev/null
MLOG0=$(grep -c . "$M/logs/blocked-resolver.log")
: > "$T/queue-fly.txt"
( export HARNESS="$M" FLEET_CONF="$M/fleet.conf" QUEUE_SINK="$T/queue-fly.txt" FLY_MACHINE_ID=m1
  "$M/bin/lane-run-worker.sh" --once ) > "$T/m7b-worker.out" 2>&1
hook DELETE __fail >/dev/null
R7=$(rows)
P2RC=$(jq -r '[.rows[] | select(.project == "p2")] | last | .rc' <<<"$R7")
[ "$P2RC" = 75 ] && grep -q 'blocked-resolver/p2 rc 75: the final write-back failed' "$M/logs/lane-run-worker.log" \
  && ok "O7 p2's run itself exited 75 and its row is done rc 75" || bad "O7 p2 rc=$P2RC $(grep p2 "$M/logs/lane-run-worker.log" | tail -2)"
tail -n +"$((MLOG0 + 1))" "$M/logs/blocked-resolver.log" > "$T/m7b.log"
grep -q 'p2/.*the write-back to the hub failed' "$T/m7b.log" && grep 'tick: candidates=' "$T/m7b.log" | grep 'visited=\[p2\]' | grep -q 'reason=writeback-failed' \
  && ok "O7 p2's run says why it stopped and its tick line says reason=writeback-failed" || bad "O7 p2 log: $(grep -E 'p2|tick:' "$T/m7b.log" | tail -4)"
N2=$(grep -cE 'p2/o-p2-6[12] .*-> ' "$T/m7b.log")
[ "$N2" -le 1 ] && ok "O7 no rung ran after the failed write-back ($N2 of the 2 new parks dispatched)" || bad "O7 p2 rungs after the failure: $(grep -E 'p2/o-p2-6[12] .*-> ' "$T/m7b.log")"

# ============================================================================
echo "O1b: hub_only keeps the lane on the hub"
setting lane_placement.blocked-resolver.hub_only "fixture: reads the hub's builds/"
D=$( . "$HUB/bin/lib/lane-placement.sh"; lp_decide blocked-resolver; printf '%s|%s' "$LP_PLACE" "$LP_WHY")
[ "$D" = "hub|hub_only: fixture: reads the hub's builds/" ] && ok "O1b lp_decide: $D" || bad "O1b lp_decide: $D"
PO=$("$HUB/bin/lane-snapshot-publish.sh"); rc=$?
case "$PO" in *"0 published, 0 unchanged"*"blocked-resolver placed hub"*) ok "O1b the publisher publishes nothing for a hub lane" ;; *) bad "O1b publisher: $PO" ;; esac

echo "blocked-resolver-offhub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
