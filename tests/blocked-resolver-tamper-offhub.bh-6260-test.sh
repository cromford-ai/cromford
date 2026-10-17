#!/bin/bash
# tests/blocked-resolver-tamper-offhub.bh-6260-test.sh — BH-6260: a test-tamper
# block adjudicated ACCEPT on a Fly lane machine carries its TEST-CHANGE to the
# next build of the ticket.
#
# The machine holds a COPY of the build record, so the ACCEPT takes the
# pool-copy arm of bin/blocked-resolver.sh: the justification goes into
# state/build-notes/<p>/<KEY>.md and the ticket is rebuilt fresh. That note is
# in the write-back allow-list, so it reaches the hub through the jobs worker,
# and the next build's plan stage reads it there (bin/lib/rb/plan.sh,
# CARRIED_NOTE_SRC). Driven through the real bin/blocked-resolver.sh and
# bin/lib/lane-run-inputs.sh against the REAL jobs worker on node:sqlite
# (tests/lib/lane-snapshots-worker.bh-6128.mjs).
#
#   T1  the machine run: the note has a TEST-CHANGE line, 1 rebuild queued,
#       no run-build.sh
#   T2  the write-back: the hub's state/build-notes/p1/TK-9.md is
#       byte-identical to the machine's
#
# Run from anywhere: tests/blocked-resolver-tamper-offhub.bh-6260-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-6005: worker/jobs/schema.sql is composed from schema.d/, not committed.
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-snapshots-worker.bh-6128.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }
# ONE clock read for the whole file: every fixture age is derived from it.
NOW=$(date -u +%s)

# The adjudicator stub answers ACCEPT.
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
  printf '#!/bin/bash\nprintf "the reasoning\\nACCEPT\\n" > "$5"\nexit 0\n' > "$r/bin/agent-call.sh"
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
# lib <root> <cmd...> — one call of the lib in a subshell rooted at <root>.
lib() { local r="$1"; shift; ( export HARNESS="$r"; . "$r/bin/lib/lane-run-inputs.sh" && "$@" ); }
srv wb; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/wb.err")"; exit 1; }
export JOBS_URL="http://127.0.0.1:$PORT"

# The hub: one REVIEW_BLOCKED test-tamper record of p1 (the shape of
# tests/resolver-hold-test.sh section 8), nothing else to do.
HUB="$T/hub"; INSTALL "$HUB" || exit 1
mkdir -p "$HUB/flags" "$HUB/logs" "$HUB/state" "$HUB/locks" "$HUB/builds"
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$HUB/fleet.conf"
touch "$HUB/flags/fly-pool-p1" "$HUB/flags/builder-fly-p1"
REC="builds/p1-TK-9-202610140001"
mkdir -p "$HUB/$REC"
printf 'REVIEW_BLOCKED test-tamper: two test cases removed\nTICKET_ID: 9\n' > "$HUB/$REC/RESULT"
printf '# the plan\n' > "$HUB/$REC/plan.md"
printf 'removed: two cases\n' > "$HUB/$REC/test-tamper.txt"
: > "$HUB/$REC/.review-rescued"
touch -d "@$((NOW - 10800))" "$HUB/$REC/RESULT"
touch -d "@$((NOW - 10800))" "$HUB/$REC"
OUT=$(lib "$HUB" lri_publish blocked-resolver p1 2>&1); rc=$?
case "$rc:$OUT" in 0:published*) ok "setup: the hub published p1: $OUT" ;; *) bad "setup: publish rc=$rc $OUT"; exit 1 ;; esac

echo "T1: the ACCEPT on the lane machine"
M="$T/m"; INSTALL "$M" || exit 1
FO=$(lib "$M" lri_fetch blocked-resolver p1 x 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$M/$REC/test-tamper.txt" ] && ok "T1 the machine fetched the record: $FO" || bad "T1 fetch rc=$rc $FO"
[ ! -e "$M/state/build-notes/p1/TK-9.md" ] && ok "T1 the machine has no build note before the run" || bad "T1 a note was there before the run"
: > "$T/path.log"; : > "$T/queue-m.txt"
( export HARNESS="$M" FLEET_CONF="$M/fleet.conf" QUEUE_SINK="$T/queue-m.txt" LANE_RUN_ID=701 FLY_MACHINE_ID=m1
  bash "$M/bin/blocked-resolver.sh" p1 ) > "$T/m-run.log" 2>&1
NOTE="$M/state/build-notes/p1/TK-9.md"
grep -q 'ADJUDICATED ACCEPT' "$M/logs/blocked-resolver.log" && ok "T1 the run adjudicated ACCEPT" \
  || bad "T1 no ACCEPT: $(tail -5 "$M/logs/blocked-resolver.log" 2>&1) $(tail -5 "$T/m-run.log")"
grep -q '^TEST-CHANGE: adjudicated ACCEPT' "$NOTE" 2>/dev/null && ok "T1 the machine's build note has the TEST-CHANGE line" \
  || bad "T1 build note: $(cat "$NOTE" 2>&1)"
[ "$(grep -c '^p1 TK-9 ' "$T/queue-m.txt")" = 1 ] && ok "T1 exactly 1 rebuild of TK-9 queued" || bad "T1 queue: $(cat "$T/queue-m.txt")"
[ "$(grep -c '^run-build\.sh ' "$T/path.log")" = 0 ] && ok "T1 the machine started no run-build.sh" || bad "T1 path.log: $(cat "$T/path.log")"

echo "T2: the note reaches the hub through the write-back"
[ ! -e "$HUB/state/build-notes/p1/TK-9.md" ] && ok "T2 before the apply the hub has no note" || bad "T2 the hub had a note before the apply"
CO=$(LANE_RUN_ID=701 lib "$M" lri_checkpoint blocked-resolver p1 2>&1); rc=$?
[ "$rc" = 0 ] && ok "T2 the final checkpoint rc 0 ${CO:+($CO)}" || bad "T2 checkpoint rc=$rc $CO"
AP=$(lib "$HUB" lri_apply_pending blocked-resolver p1); rc=$?
case "$rc:$AP" in "0:applied="[1-9]*" conflicts=0 rejected=0") ok "T2 hub apply: $AP" ;; *) bad "T2 hub apply rc=$rc $AP" ;; esac
cmp -s "$NOTE" "$HUB/state/build-notes/p1/TK-9.md" && ok "T2 the hub's state/build-notes/p1/TK-9.md is byte-identical to the machine's" \
  || bad "T2 hub note: $(cat "$HUB/state/build-notes/p1/TK-9.md" 2>&1)"
grep -q '^TEST-CHANGE: adjudicated ACCEPT' "$HUB/state/build-notes/p1/TK-9.md" 2>/dev/null \
  && ok "T2 the hub note is the file the next build's plan stage reads (CARRIED_NOTE_SRC)" || bad "T2 no TEST-CHANGE on the hub"

echo "blocked-resolver-tamper-offhub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
