#!/bin/bash
# tests/conductor-pr-claim.bh-6495-test.sh — BH-6495 (BH-6047.5) AC2: a
# lane-run machine claims a merge-conductor-pr row, runs the per-PR worker
# against a stub PR and writes the terminal state; a second claim of the same
# key + head is refused; a new head is a new row.
#
# Driven through the REAL hub enqueue (mc_fly_enqueue), the REAL
# bin/lane-run-worker.sh --once, bin/project-lane-run.sh,
# bin/merge-conductor-pr.sh and bin/merge-conductor.sh (gh and git stubbed,
# the fixture of tests/conductor-enqueue-only.bh-6495-test.sh), against the
# REAL jobs worker on node:sqlite (tests/lib/lane-runs-worker.bh-6124.mjs).
#
#   C1  the machine run of #31 ends `done` rc 0 with the PROF line of the
#       state the conductor wrote, and a hub keyed tick of the same PR in a
#       twin tree reaches the same state
#   C2  a second enqueue of the same key + head answers 409 (rc 3) while the
#       row is claimed, and a second claim answers 204
#   C3  a new head while the old row is live is skipped (rc 4); after the old
#       row is done, the new head is a new row (rc 0)
#   C4  with actions on, #33 needs a re-review: the machine run ends
#       deferred=rereview, no re-review job file and no CAPFILE line exist,
#       and the hub's next read of the stored row answers machine-deferred
#       (rc 5). The three spawns, the direct merge, the enqueue (direct
#       and through the merge lock) and the settle each defer under
#       MC_ON_MACHINE=1 and write nothing; another call through the merge
#       lock still runs
#   C5  TERM mid-run hands the row back, and a second machine resumes it
#   C6  the entry: a wrong run key exits 2, a moved head prints HEAD_MOVED and
#       runs no conductor, a repo that is not the project's exits 2
#
# Run from anywhere: tests/conductor-pr-claim.bh-6495-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or setsid missing"; exit 0; }

# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || exit 1
[ -f "$DIR/bin/merge-conductor-pr.sh" ] || { echo "FAIL: bin/merge-conductor-pr.sh is missing"; exit 1; }
for L in bin/merge-conductor.sh bin/merge-conductor-pr.sh bin/lib/mc/fly-workers.sh bin/lane-run-worker.sh \
         bin/project-lane-run.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$T/h" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$T/h/bin/"*.sh
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"

# The first 40 characters with a bash substring, not `printf | head -c`: head
# exits early and the writer takes SIGPIPE under pipefail (race-sigpipe-echo).
hd() { local s="$1aaaabbbbccccddddeeeeffff0000111122223333"; printf '%s' "${s:0:40}"; }
for n in 31 32 33 34; do eval "H$n=$(hd "$n")"; done
H31B=$(hd 3b)
# The PR heads the stub serves, one file per PR, so a section moves a head.
mkdir -p "$T/heads"
for n in 31 32 33 34; do eval "echo \$H$n" > "$T/heads/$n"; done

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*)
    echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    printf '['; sep=""
    for n in 31 32 33 34; do
      printf '%s{"number":%s,"url":"https://github.com/example-org/demo-os/pull/%s","headRefOid":"%s","headRefName":"ticket/pb-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}' "\$sep" "\$n" "\$n" "\$(cat "$T/heads/\$n")" "\$n"; sep=","
    done
    printf ']\n' ;;
  *"repos/example-org/demo-os/pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/"[0-9]*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%%[!0-9]*}"
    restpr OPEN "\$(cat "$T/heads/\$n")" "ticket/pb-\$n" main "" ;;
  *"actions/runs?head_sha="*)
    a="\$*"; h="\${a##*head_sha=}"
    printf '%s\n' "\${h:0:2}" >> "$T/worker-reads.txt"
    # With slow34 set, #34's CI read blocks (bounded) so a section can TERM it.
    if [ "\${h:0:2}" = 34 ] && [ -e "$T/slow34" ]; then
      : > "$T/in34"; i=0; while [ -e "$T/slow34" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i+1)); done
    fi
    # #33's CI is green, so its unreviewed head buys a re-review (C4).
    if [ "\${h:0:2}" = 33 ]; then restpr --runs 'completed|success'; else restpr --runs 'in_progress|'; fi ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case "\$*" in
  *--version*) echo "git version 2.45.0" ;;
  *ls-remote*"refs/heads/"*) printf '1111111111111111111111111111111111111111\trefs/heads/main\n' ;;
  *ls-remote*) echo "0000000000000000000000000000000000000000	HEAD" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
: > "$T/gh-writes.txt"; : > "$T/c-alerts.txt"
cp -a "$T/h" "$T/h2"   # the twin tree a hub keyed tick runs in (C1)

PIDS=()
srv() {
  local n="w${#PIDS[@]}"
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  JOBS_URL="http://127.0.0.1:$PORT"; SLOG="$T/$n.log"
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
srv; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T"/w0.err)"; exit 1; }
export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-harness-secret JOBS_URL
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 MC_PR_PARALLEL=0 MC_KEYED_WAKE_MIN_S=0
api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
          ${3:+-d "$3"} "$JOBS_URL$2"; }
rows() { curl -sS "$JOBS_URL/__lane_runs"; }
rowof() { rows | jq -c --arg p "$1" '[.rows[] | select(.project == $p)] | last'; }
# hub <fn> [args] — a function of the hub's lib in a subshell of the hub tree.
hub() { ( . "$T/h/bin/jobs-client.sh" && . "$T/h/bin/lib/mc/fly-workers.sh" && "$@" ); }
enq() { hub mc_fly_enqueue demo-os example-org/demo-os "$1" "$2"; }
machine() { "$T/h/bin/lane-run-worker.sh" --once --machine "$1" > "$T/machine-$1.out" 2>&1; }
WAITFOR() { local i; for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
rowstate() { awk -F'\t' -v k="example-org/demo-os#$2" '$1 == k { r = $2 } END { print r }' "$1/state/merge-conductor/pr-state.tsv" 2>/dev/null; }

# ============================================================================
echo "C1: a machine runs #31 to the hub's terminal state"
K31="demo-os.31.${H31:0:12}"
enq 31 "$H31"; rc=$?
[ "$rc" = 0 ] && ok "C1 the hub enqueue answers 0" || bad "C1 enqueue rc=$rc"
: > "$T/worker-reads.txt"
machine m1; rc=$?
[ "$rc" = 0 ] && ok "C1 the machine loop exits 0" || bad "C1 rc=$rc $(cat "$T/machine-m1.out"; tail -5 "$T/h/logs/lane-run-worker.log")"
R=$(rowof "$K31")
S31=$(rowstate "$T/h" 31)
[ -n "$S31" ] && ok "C1 the conductor on the machine wrote #31's row ($S31)" || bad "C1 no pr-state row; cron log: $(tail -5 "$T/h/logs/merge-conductor-pr-cron.log")"
[ "$(jq -r .status <<<"$R")" = done ] && [ "$(jq -r .rc <<<"$R")" = 0 ] && ok "C1 the row is done rc 0" || bad "C1 row: $R"
grep -qx "PROF mc-pr state=$S31 reason=[^ ]* deferred=-" <<<"$(jq -r .prof_line <<<"$R")" \
  && ok "C1 the stored PROF line carries the state the conductor wrote" || bad "C1 prof: $(jq -r .prof_line <<<"$R")"
grep -qx 31 "$T/worker-reads.txt" && ok "C1 the worker read #31's CI on the machine" || bad "C1 reads: $(cat "$T/worker-reads.txt")"
grep -q "keyed tick: 1 key(s) — example-org/demo-os#31" "$T/h/logs/merge-conductor.log" && ok "C1 it was today's keyed tick for #31" \
  || bad "C1 conductor log: $(tail -3 "$T/h/logs/merge-conductor.log")"
( cd "$T" && setsid -w env HARNESS="$T/h2" MC_ONLY_PR="example-org/demo-os#31" MC_FANIN_SOLO_RUN=1 \
    bash "$T/h2/bin/merge-conductor.sh" >/dev/null 2>&1 )
[ -n "$S31" ] && [ "$(rowstate "$T/h2" 31)" = "$S31" ] && ok "C1 a hub keyed tick of #31 reaches the same state" \
  || bad "C1 hub state '$(rowstate "$T/h2" 31)' vs machine '$S31'"

# ============================================================================
echo "C2: a second enqueue and a second claim of the same key + head"
K32="demo-os.32.${H32:0:12}"
enq 32 "$H32"; rc1=$?
C=$(api POST /api/lane-runs/claim '{"machine":"m1"}')
enq 32 "$H32"; rc2=$?
[ "$rc1" = 0 ] && [ "$rc2" = 3 ] && ok "C2 first enqueue rc 0, second rc 3 (409 already live)" || bad "C2 rcs $rc1 $rc2"
grep -q 'POST /api/lane-runs 409' "$SLOG" && ok "C2 the worker answered 409" || bad "C2 server log"
L0=$(grep -c . "$SLOG")
api POST /api/lane-runs/claim '{"machine":"m2"}' >/dev/null
tail -n +"$((L0 + 1))" "$SLOG" | grep -q 'POST /api/lane-runs/claim 204' && ok "C2 the second claim answers 204" || bad "C2 claim: $(tail -2 "$SLOG")"
[ "$(rows | jq --arg p "$K32" '[.rows[] | select(.project == $p)] | length')" = 1 ] && ok "C2 one row for the key" || bad "C2 rows"
ID32=$(jq -r .id <<<"$C")

# ============================================================================
echo "C3: a new head is a new row"
echo "$H31B" > "$T/heads/31"
enq 31 "$H31B"; rc=$?
[ "$rc" = 0 ] && ok "C3 #31's new head enqueues (old row done)" || bad "C3 rc=$rc"
[ "$(rows | jq '[.rows[] | select(.project | startswith("demo-os.31."))] | length')" = 2 ] && ok "C3 two #31 rows, one per head" || bad "C3 rows"
H32B=$(hd 3c)
enq 32 "$H32B"; rc=$?
[ "$rc" = 4 ] && ok "C3 a new #32 head while the old row is claimed: rc 4, skipped" || bad "C3 live other head rc=$rc"
api POST "/api/lane-runs/$ID32/report" '{"machine":"m1","rc":0}' >/dev/null
enq 32 "$H32B"; rc=$?
[ "$rc" = 0 ] && ok "C3 after the old row is done, the new head enqueues" || bad "C3 rc=$rc"
machine m1 >/dev/null 2>&1   # drain C3's rows: #31 runs at its new head, #32's stale head says HEAD_MOVED
R=$(rowof "demo-os.32.${H32B:0:12}")
[ "$(jq -r .prof_line <<<"$R")" = "PROF mc-pr state=HEAD_MOVED reason=head-moved deferred=-" ] \
  && ok "C3 a row whose head the PR no longer has ends HEAD_MOVED" || bad "C3 prof: $R"

# ============================================================================
echo "C4: a re-review on a machine is deferred to the hub"
api PUT /api/flags '{"name":"merge-conductor-actions","active":1,"actor":"fixture"}' >/dev/null
K33="demo-os.33.${H33:0:12}"
enq 33 "$H33" || bad "C4 setup: enqueue"
: > "$T/worker-reads.txt"
machine m1
R=$(rowof "$K33")
P33=$(jq -r .prof_line <<<"$R")
grep -q ' deferred=rereview$' <<<"$P33" && ok "C4 the run ends deferred=rereview" \
  || bad "C4 prof: $P33; log: $(grep 'demo-os#33' "$T/h/logs/merge-conductor.log" | tail -4)"
[ -z "$(find "$T/h/state/merge-conductor/rereview" -name '*.json' 2>/dev/null)" ] && ok "C4 no re-review job file" \
  || bad "C4 job files: $(find "$T/h/state/merge-conductor/rereview" -name '*.json')"
! grep -q 'demo-os#33' "$T/h/state/merge-conductor/"rereviews-*.txt 2>/dev/null && ok "C4 no CAPFILE line" \
  || bad "C4 capfile: $(cat "$T/h/state/merge-conductor/"rereviews-*.txt)"
grep -q 'demo-os#33 REREVIEW_QUEUED' "$T/h/logs/merge-conductor.log" && ok "C4 the conductor logged it as deferred" \
  || bad "C4 log: $(grep 'demo-os#33' "$T/h/logs/merge-conductor.log" | tail -3)"
enq 33 "$H33"; rc=$?
[ "$rc" = 5 ] && ok "C4 the hub reads the stored row: rc 5, machine-deferred" || bad "C4 hub rc=$rc"
# The four guards, one call each, under MC_ON_MACHINE=1.
G=$( ( export HARNESS="$T/h" MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$T/def.txt"; : > "$T/def.txt"
       . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
       mc_rebase_spawn example-org/demo-os 31 demo-os ticket/TK-31 "$H31" u; echo "rb=$?"
       mc_rereview_spawn example-org/demo-os 31 demo-os u "$H31" "$H31" -; echo "rr=$?"
       mc_dv_spawn demo-os example-org/demo-os "$H31" -; echo "dv=$?"
       mc_merge_locked demo-os mc_merge u "$H31"; echo "mg=$?"
       mc_merge_locked demo-os mc_enqueue u "$H31"; echo "lq=$?"
       mc_enqueue https://github.com/example-org/demo-os/pull/31 "$H31" >/dev/null; echo "eq=$?"
       conductor_settle example-org/demo-os#31 https://github.com/example-org/demo-os/pull/31 demo-os example-org/demo-os \
         ticket/TK-31 "" - "$H31" "$H31" APPROVE CLEAN by:fixture; echo "st=$?"
       mc_merge_locked demo-os echo other-ran; echo "ot=$?" ) 2>/dev/null | tr '\n' ' ')
[ "$G" = "rb=3 rr=3 dv=3 mg=99 lq=99 eq=99 st=0 other-ran ot=0 " ] \
  && ok "C4 rebase/rereview/dv answer 3, a merge or an enqueue 99, a settle 0, another locked call runs" || bad "C4 guards: $G"
[ "$(sort "$T/def.txt" | tr '\n' ' ')" = "dv enqueue enqueue merge rebase rereview settle " ] && ok "C4 each guard writes its word" || bad "C4 words: $(cat "$T/def.txt")"
[ "$(rowstate "$T/h" 31)" != MERGED ] && ! grep -rqs "deployreq example-org/demo-os#31" "$T/h/state/merge-conductor" \
  && ok "C4 the machine settle wrote no MERGED row and no deployreq line" \
  || bad "C4 settle wrote: row $(rowstate "$T/h" 31), $(grep -rs deployreq "$T/h/state/merge-conductor")"
[ -z "$(find "$T/h/state/merge-conductor/rebase" "$T/h/state/merge-conductor/deploy-verify" -name '*.json' 2>/dev/null)" ] \
  && ok "C4 no rebase or deploy-verify job file" || bad "C4 files: $(find "$T/h/state/merge-conductor" -name '*.json')"

# ============================================================================
echo "C5: TERM mid-run, resumed by a second machine"
K34="demo-os.34.${H34:0:12}"
enq 34 "$H34" || bad "C5 setup: enqueue"
: > "$T/slow34"; rm -f "$T/in34"
"$T/h/bin/lane-run-worker.sh" --once --machine m1 > "$T/c5.out" 2>&1 & W=$!
WAITFOR '[ -e "$T/in34" ]' 300 || bad "C5 setup: #34's worker never reached its CI read"
kill -TERM "$W"; wait "$W"; rc=$?
R=$(rowof "$K34")
[ "$rc" = 0 ] && [ "$(jq -r .status <<<"$R")" = queued ] && [ "$(jq -r .attempts <<<"$R")" = 1 ] \
  && ok "C5 TERM: exit 0, the row is queued with attempts 1" || bad "C5 rc=$rc row: $R"
rm -f "$T/slow34"
machine m2
R=$(rowof "$K34")
[ "$(jq -r .status <<<"$R")" = done ] && [ "$(jq -r .rc <<<"$R")" = 0 ] && [ "$(jq -r .claimed_by <<<"$R")" = m2 ] \
  && [ "$(jq -r .attempts <<<"$R")" = 2 ] && grep -q '^PROF mc-pr state=' <<<"$(jq -r .prof_line <<<"$R")" \
  && ok "C5 m2 resumes it: done rc 0, attempts 2, a PROF mc-pr line" || bad "C5 row: $R"

# ============================================================================
echo "C6: the entry's own checks"
E="$T/h/bin/merge-conductor-pr.sh"
"$E" demo-os "example-org/demo-os#31" "$H31B" demo-os.31.000000000000 > "$T/c6.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "C6 a run key that is not this row's exits 2" || bad "C6 key rc=$rc"
"$E" demo-os "Other/repo#31" "$H31B" > "$T/c6.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "C6 a repo that is not the project's exits 2" || bad "C6 repo rc=$rc"
: > "$T/worker-reads.txt"
OUT=$("$E" demo-os "example-org/demo-os#31" "$H31" "$K31" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$OUT" = "PROF mc-pr state=HEAD_MOVED reason=head-moved deferred=-" ] && [ ! -s "$T/worker-reads.txt" ] \
  && ok "C6 a moved head prints HEAD_MOVED, exits 0 and runs no conductor" || bad "C6 rc=$rc out=$OUT reads=$(cat "$T/worker-reads.txt")"
[ ! -s "$T/gh-writes.txt" ] && ok "C6 no GitHub write in the whole suite" || bad "writes: $(cat "$T/gh-writes.txt")"

echo "conductor-pr-claim: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
