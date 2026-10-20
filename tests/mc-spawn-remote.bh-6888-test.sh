#!/bin/bash
# tests/mc-spawn-remote.bh-6888-test.sh — BH-6888 (BH-6881.4, slice C0): on a
# lane-run machine (MC_ON_MACHINE=1) with the settings switch
# conductor_remote_spawn on and a pool app, the conductor's rebase is ONE
# deduped build_queue row (RB-<pr>-<head8>) through the jobs API, and its
# result is read back through the same API on the next tick. Off, or on the
# hub, nothing changes.
#
# Driven through the REAL lib "$DIR/bin/lib/mc/spawn-remote.sh" (sourced by
# bin/lib/mc/rebase.sh), the REAL jobs client and a fake curl that is a small
# stateful jobs worker: GET /api/settings/<key>, GET /api/queue?project=&key=
# and POST /api/queue with the upsert rules of worker/jobs/src/routes/queue.js
# (duplicate over queued/claimed; a put over a terminal row bumps attempt).
#
#   S1  no row: rc 0, one POST of RB-31-<head8>, meta kind/dedup/by, no word
#   S2  the same head again: rc 0, still one POST, the GET ran first
#   S3  claimed: rc 0, no POST
#   S4  done + REBASED / CONFLICT: rc 4, no POST, no word
#   S5  two spawns at once: one row, the second answer is duplicate
#   S6  failed attempt 0, 1, 2: one POST each; attempt 3: terminal, rc 3
#   S7  done + REBASE_SETUP_FAILED: one POST
#   S8  done + empty reason (and an unknown word): terminal, rc 3, no POST
#   S9  switch absent / settings down / project row 0: today's deferral
#   S10 queue GET 500: rc 3, no POST
#   S11 POST 500: rc 3, nothing logged as queued
#   S12 dropped: rc 3, no POST
#   S13 a short head or a PR that is not a number: rc 3, no queue request
#   S14 the production entry mc_rebase under REBASE_ON_POOL: rc 6, one POST,
#       no job file
#   S15 the S1 meta through the real bin/lib/queue-row-job.sh mapping
#   S16 conductor_remote_retry_max=1
#   S17 the hub (MC_ON_MACHINE unset): the local job file, no queue request
#   S18 no pool app: rc 3, no queue request
#   S19 re-review is an RR pool row (BH-7674); deploy-verify still defers
#   S20 rebase_consume reads the result through the API, once per head
#   S21 no file under state/ is written by a machine spawn
#   S22 a queued/claimed row past MC_REBASE_POOL_TIMEOUT_SECS (or with no
#       enqueued_at) is stale: rc 3 + rebase, no POST
#   S23 the tick order (rebase_consume, then the NEEDS_REBASE arm's mark guard
#       of bin/merge-conductor.sh): a failed row is re-put once per tick while
#       the mark stands, then handed back at the cap; empty and stale rows are
#       handed back; a running row keeps the mark and puts nothing
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-spawn-remote.bh-6888-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v flock >/dev/null || { echo "SKIP: jq or flock missing"; exit 0; }
[ -f "$DIR/bin/lib/mc/spawn-remote.sh" ] || { echo "FAIL: bin/lib/mc/spawn-remote.sh is missing"; exit 1; }

export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/env" "$T/h/builds" "$T/fakebin" "$T/store" "$T/settings"
for L in bin/lib/merge-conductor-lib.sh bin/jobs-client.sh bin/lib/queue-row-job.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$T/h" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"

SLUG=example-org/demo-os
PROJ=demo-os
HEAD=3131313131313131313131313131313131313131
NEWSHA=4242424242424242424242424242424242424242
URL="https://github.com/$SLUG/pull/31"
BR=ticket/TK-31
RBKEY=RB-31-31313131
DEDUP=demo-os.31.313131313131.rebase
KEY="$SLUG#31"
REQ="$T/req.txt"; DEF="$T/def.txt"

# --- the fake curl: a stateful jobs worker -----------------------------------
# One JSON file per (project, key) under $T/store. Faults by marker file:
#   settings-down  every /api/settings read is a transport failure (exit 7)
#   qget-500       GET /api/queue answers 500
#   qpost-500      POST /api/queue answers 500
#   barrier        each GET /api/queue reads the row, then waits (bounded)
#                  until two reads have arrived
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
U="\${!#}"; M=GET; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
P="/\${U#*://*/}"
printf '%s %s %s\n' "\$M" "\$P" "\$BODY" >> "$REQ"
q() { local v="\${P#*\?}"; v="&\$v"; v="\${v#*&\$1=}"; [ "\$v" = "&\$P" ] && return; printf '%s' "\${v%%&*}"; }
case "\$M \$P" in
  "GET /api/settings/"*)
    [ -e "$T/settings-down" ] && exit 7
    k="\${P#/api/settings/}"
    if [ -f "$T/settings/\$k" ]; then jq -nc --arg k "\$k" --arg v "\$(cat "$T/settings/\$k")" '{setting:{key:\$k,value:\$v}}'; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET /api/queue?"*)
    [ -e "$T/qget-500" ] && { printf '{"error":"fixture"}\n500\n'; exit 0; }
    # The row is read BEFORE the barrier, so neither spawn can put until both have read.
    f="$T/store/\$(q project)__\$(q key).json"
    if [ -f "\$f" ]; then out=\$(jq -c '{queue:[.]}' "\$f"); else out='{"queue":[]}'; fi
    if [ -e "$T/barrier" ]; then
      echo x >> "$T/barrier-count"; i=0
      while [ "\$(wc -l < "$T/barrier-count")" -lt 2 ] && [ "\$i" -lt 200 ]; do sleep 0.05; i=\$((i+1)); done  # determinism: ok — a bounded barrier so two spawns both read before either writes (S5); no assertion reads the time
    fi
    printf '%s\n200\n' "\$out" ;;
  "POST /api/queue")
    [ -e "$T/qpost-500" ] && { printf '{"error":"fixture"}\n500\n'; exit 0; }
    p=\$(jq -r .project <<<"\$BODY"); k=\$(jq -r .key <<<"\$BODY"); f="$T/store/\${p}__\${k}.json"
    exec 9>>"$T/store/.lock"; flock 9
    if [ -f "\$f" ] && jq -e '.status == "queued" or .status == "claimed"' "\$f" >/dev/null; then
      jq -c '{queued:., duplicate:true}' "\$f"; printf '200\n'; exit 0
    fi
    prev=-1; [ -f "\$f" ] && prev=\$(jq -r '.attempt // 0' "\$f")
    jq -c --argjson prev "\$prev" '{project, ticket_key:.key, ticket_id, status:"queued", target,
        attempt:(if .attempt != null then .attempt elif \$prev >= 0 then \$prev + 1 else 0 end),
        enqueued_at:(1900000000 | todate), reason:null, meta}' <<<"\$BODY" > "\$f.tmp" && mv "\$f.tmp" "\$f"
    jq -c '{queued:., duplicate:false}' "\$f"; printf '201\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
# git and gh fail loudly: a machine spawn must never reach either.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/git-argv.txt"\nexit 1\n' "$T" > "$T/fakebin/git"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-argv.txt"\nexit 1\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/git" "$T/fakebin/gh"
: > "$T/git-argv.txt"; : > "$T/gh-argv.txt"

export PATH="$T/fakebin:$PATH" HARNESS_SECRET=fixture-harness-secret JOBS_URL="https://jobs.example"
export JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_SETTINGS_CACHE_S=0 ROUTING_ROWS=off
printf 'harness-pool-demo-os-fixture\n' > "$T/h/flags/fly-pool-app-$PROJ"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$T/h/bin/jobs-client.sh"; set +o pipefail
RBDIR="$MC_RB_DIR"
P="$PROJ"
# The pinned clock (D60): the stale bound is read against it, never the wall.
NOW=1900000000
mc_now() { echo "$NOW"; }

setting() { printf '%s' "$2" > "$T/settings/$1"; }
unsetting() { rm -f "$T/settings/$1"; }
reset() { rm -f "$T/store/"*.json "$T/qget-500" "$T/qpost-500" "$T/settings-down" "$T/barrier" "$T/barrier-count"
          : > "$REQ"; : > "$DEF"; : > "$MC_LOG"; }
# seed <status> <attempt> <reason> [age-s] — the queue row of this head, as the
#   worker stores it, enqueued [age-s] (default 60) before the pinned clock.
#   An age of `none` stores no enqueued_at.
seed() { jq -nc --arg s "$1" --argjson a "$2" --arg r "$3" --arg k "$RBKEY" --arg age "${4:-60}" --argjson now "$NOW" \
  '{project:"demo-os",ticket_key:$k,ticket_id:"31",status:$s,target:"fly",attempt:$a,
    enqueued_at:(if $age == "none" then null else ($now - ($age | tonumber) | todate) end),
    reason:(if $r == "" then null else $r end),meta:null}' > "$T/store/${PROJ}__$RBKEY.json"; }
row_attempt() { jq -r .attempt "$T/store/${PROJ}__$RBKEY.json" 2>/dev/null; }
qposts() { grep -c '^POST /api/queue ' "$REQ"; }
qreqs()  { grep -c ' /api/queue' "$REQ"; }
qbody()  { grep '^POST /api/queue ' "$REQ" | head -1 | cut -d' ' -f3-; }
spawn() { ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"
            mc_rebase_spawn "$SLUG" "${1:-31}" "$PROJ" "$BR" "${2:-$HEAD}" "$URL" ) >/dev/null 2>&1; echo $?; }
words() { tr '\n' ' ' < "$DEF" | sed 's/ $//'; }
statefiles() { find "$T/h/state" -type f -exec md5sum {} + 2>/dev/null | sort; }

setting conductor_remote_spawn 1
STATE0=$(statefiles)

# ── S1 ──────────────────────────────────────────────────────────────────────
reset
RC=$(spawn)
[ "$RC" = 0 ] && ok || bad "S1 no row: rc 0 (got $RC; log: $(cat "$MC_LOG"))"
[ "$(qposts)" = 1 ] && ok || bad "S1 exactly one POST /api/queue (got $(qposts))"
B=$(qbody)
[ "$(jq -r .key <<<"$B")" = "$RBKEY" ] && ok || bad "S1 the row key is $RBKEY (got $(jq -r .key <<<"$B" 2>/dev/null))"
[ "$(jq -r .target <<<"$B")" = fly ] && ok || bad "S1 target fly (got $(jq -r .target <<<"$B" 2>/dev/null))"
[ "$(jq -r .ticket_id <<<"$B")" = 31 ] && ok || bad "S1 ticket_id is the PR number"
[ "$(jq -r .meta <<<"$B" | jq -r .kind)" = rebase ] && ok || bad "S1 meta.kind rebase"
[ "$(jq -r .meta <<<"$B" | jq -r .dedup)" = "$DEDUP" ] && ok || bad "S1 meta.dedup $DEDUP (got $(jq -r .meta <<<"$B" 2>/dev/null | jq -r .dedup 2>/dev/null))"
[ "$(jq -r .meta <<<"$B" | jq -r .by)" = machine ] && ok || bad "S1 meta.by machine"
[ "$(jq -r .meta <<<"$B" | jq -r .head)" = "$HEAD" ] && ok || bad "S1 meta.head is the full head"
[ "$(jq -r 'has("attempt")' <<<"$B")" = false ] && ok || bad "S1 the first put sends no attempt"
[ -z "$(words)" ] && ok || bad "S1 no deferred word (got '$(words)')"
grep -q "remote rebase queued $DEDUP as $RBKEY (attempt 0)" "$MC_LOG" && ok || bad "S1 the log names the dedup key ($(cat "$MC_LOG"))"
S1META=$(jq -r .meta <<<"$B")

# ── S2 ──────────────────────────────────────────────────────────────────────
: > "$MC_LOG"
RC=$(spawn)
[ "$RC" = 0 ] && ok || bad "S2 the same head again: rc 0 (got $RC)"
[ "$(qposts)" = 1 ] && ok || bad "S2 still one POST (got $(qposts))"
[ "$(grep ' /api/queue' "$REQ" | head -1 | cut -d' ' -f1)" = GET ] && ok || bad "S2 the dedup read ran before the put"
[ -z "$(words)" ] && ok || bad "S2 no deferred word"
grep -q "remote rebase $DEDUP in flight (queued)" "$MC_LOG" && ok || bad "S2 the log says in flight ($(cat "$MC_LOG"))"

# ── S3 ──────────────────────────────────────────────────────────────────────
reset; seed claimed 0 ""
RC=$(spawn)
[ "$RC" = 0 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "S3 claimed: rc 0, no POST (rc $RC, posts $(qposts))"

# ── S4 ──────────────────────────────────────────────────────────────────────
reset; seed done 0 "REBASED $NEWSHA
PR: $URL
HEAD: $HEAD"
RC=$(spawn)
[ "$RC" = 4 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "S4a done + REBASED: rc 4, no POST, no word (rc $RC, posts $(qposts), '$(words)')"
grep -q "remote rebase $DEDUP result on record (REBASED)" "$MC_LOG" && ok || bad "S4a the log names the result ($(cat "$MC_LOG"))"
reset; seed done 0 "CONFLICT a.txt"
RC=$(spawn)
[ "$RC" = 4 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "S4b done + CONFLICT: rc 4, no POST (rc $RC, posts $(qposts))"

# ── S5 ──────────────────────────────────────────────────────────────────────
reset; : > "$T/barrier"
spawn > "$T/s5a" & spawn > "$T/s5b" & wait
[ "$(cat "$T/s5a")" = 0 ] && [ "$(cat "$T/s5b")" = 0 ] && ok || bad "S5 both spawns rc 0 ($(cat "$T/s5a") $(cat "$T/s5b"))"
[ "$(find "$T/store" -name '*.json' | wc -l)" = 1 ] && ok || bad "S5 the store holds one row"
[ "$(qposts)" = 2 ] && ok || bad "S5 both read none, so both put (posts $(qposts))"
grep -q "remote rebase queued $DEDUP as $RBKEY (attempt 0, duplicate)" "$MC_LOG" && ok || bad "S5 the second answer is duplicate ($(cat "$MC_LOG"))"

# ── S6 ──────────────────────────────────────────────────────────────────────
reset
for a in 0 1 2; do
  seed failed "$a" "REBASE_SETUP_FAILED fixture"; : > "$REQ"
  RC=$(spawn)
  [ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && ok || bad "S6 failed attempt $a: one re-put, rc 0 (rc $RC, posts $(qposts))"
  [ "$(row_attempt)" = $((a+1)) ] && ok || bad "S6 the worker bumped attempt to $((a+1)) (got $(row_attempt))"
  [ "$(jq -r 'has("attempt")' <<<"$(qbody)")" = false ] && ok || bad "S6 a re-put sends no attempt"
done
seed failed 3 "REBASE_SETUP_FAILED fixture"; : > "$REQ"; : > "$MC_LOG"
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S6 failed attempt 3: terminal, rc 3 + rebase, no POST (rc $RC, posts $(qposts), '$(words)')"
grep -q "remote rebase $DEDUP deferred to the hub (failed" "$MC_LOG" && ok || bad "S6 the log says deferred ($(cat "$MC_LOG"))"

# ── S7 ──────────────────────────────────────────────────────────────────────
reset; seed done 0 "REBASE_SETUP_FAILED no token
PR: $URL"
RC=$(spawn)
[ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && [ "$(row_attempt)" = 1 ] && ok || bad "S7 done + REBASE_SETUP_FAILED: one re-put (rc $RC, posts $(qposts))"

# ── S8 ──────────────────────────────────────────────────────────────────────
for r in "" "SOMETHING_ELSE fixture"; do
  reset; seed done 0 "$r"
  RC=$(spawn)
  [ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S8 done + '$r': empty is terminal (rc $RC, posts $(qposts), '$(words)')"
  grep -q "remote rebase $DEDUP deferred to the hub (empty" "$MC_LOG" && ok || bad "S8 the log says empty ($(cat "$MC_LOG"))"
  RC=$(spawn)
  [ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && ok || bad "S8 a second call still puts nothing"
done

# ── S9 ──────────────────────────────────────────────────────────────────────
reset; unsetting conductor_remote_spawn
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(words)" = rebase ] && [ "$(qreqs)" = 0 ] && ok || bad "S9a no switch row: today's deferral (rc $RC, '$(words)', queue reqs $(qreqs))"
reset; setting conductor_remote_spawn 1; : > "$T/settings-down"
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(words)" = rebase ] && [ "$(qreqs)" = 0 ] && ok || bad "S9b settings unreadable: off (rc $RC, queue reqs $(qreqs))"
reset; setting "conductor_remote_spawn.$PROJ" 0
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(qreqs)" = 0 ] && ok || bad "S9c the project row 0 wins over the fleet row 1 (rc $RC, queue reqs $(qreqs))"
reset; setting conductor_remote_spawn 0; setting "conductor_remote_spawn.$PROJ" 1
RC=$(spawn)
[ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && ok || bad "S9d the project row 1 wins over the fleet row 0 (rc $RC, posts $(qposts))"
unsetting "conductor_remote_spawn.$PROJ"; setting conductor_remote_spawn 1

# ── S10 / S11 / S12 ─────────────────────────────────────────────────────────
reset; : > "$T/qget-500"
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S10 queue read 500: rc 3 + rebase, no POST (rc $RC, posts $(qposts))"
reset; : > "$T/qpost-500"
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(words)" = rebase ] && ok || bad "S11 put 500: rc 3 + rebase (rc $RC, '$(words)')"
grep -q 'remote rebase queued' "$MC_LOG" && bad "S11 nothing is logged as queued without a 2xx" || ok
reset; seed dropped 0 ""
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S12 dropped: rc 3, no POST (rc $RC, posts $(qposts))"

# ── S13 ─────────────────────────────────────────────────────────────────────
reset
RC=$(spawn 31 abc)
[ "$RC" = 3 ] && [ "$(qreqs)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S13 head abc: rc 3, no queue request (rc $RC, reqs $(qreqs))"
reset
RC=$(spawn x31)
[ "$RC" = 3 ] && [ "$(qreqs)" = 0 ] && ok || bad "S13 PR x31: rc 3, no queue request (rc $RC, reqs $(qreqs))"

# ── S14: the production entry ───────────────────────────────────────────────
reset
RC=$( ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF" REBASE_ON_POOL=1
        mc_rebase "$SLUG" "$PROJ" "$BR" "$HEAD" "$URL" ) >/dev/null 2>&1; echo $?)
[ "$RC" = 6 ] && ok || bad "S14 mc_rebase on a machine answers 6 (got $RC; log: $(cat "$MC_LOG"))"
[ "$(qposts)" = 1 ] && [ "$(jq -r .meta <<<"$(qbody)" | jq -r .dedup)" = "$DEDUP" ] && ok || bad "S14 one machine POST (posts $(qposts))"
ls "$RBDIR"/*.json >/dev/null 2>&1 && bad "S14 no job file in $RBDIR ($(ls "$RBDIR"))" || ok
[ -s "$T/git-argv.txt" ] && bad "S14 no git ran ($(head -3 "$T/git-argv.txt"))" || ok
RC=$( ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF" REBASE_ON_POOL=1; : > "$T/qget-500"
        mc_rebase "$SLUG" "$PROJ" "$BR" "$HEAD" "$URL" ) >/dev/null 2>&1; echo $?)
[ "$RC" = 7 ] && ok || bad "S14 a failed queue read answers 7 (got $RC)"
STATE14=$(statefiles)

# ── S15 ─────────────────────────────────────────────────────────────────────
( . "$T/h/bin/lib/queue-row-job.sh"
  queue_row_job_file "$PROJ" "$T/job15.json" "$RBKEY" 31 0 "$S1META" ) >/dev/null 2>&1
[ "$(jq -r .rebase.kind "$T/job15.json" 2>/dev/null)" = rebase ] && ok || bad "S15 the job maps to kind rebase ($(cat "$T/job15.json" 2>/dev/null))"
[ "$(jq -r .rebase.head "$T/job15.json" 2>/dev/null)" = "$HEAD" ] && ok || bad "S15 the job carries the head"
[ "$(jq -r .rebase.branch "$T/job15.json" 2>/dev/null)" = "$BR" ] && ok || bad "S15 the job carries the branch"

# ── S16 ─────────────────────────────────────────────────────────────────────
setting conductor_remote_retry_max 1
reset; seed failed 1 "REBASE_SETUP_FAILED fixture"
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && ok || bad "S16 cap 1, attempt 1: terminal (rc $RC, posts $(qposts))"
reset; seed failed 0 "REBASE_SETUP_FAILED fixture"
RC=$(spawn)
[ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && ok || bad "S16 cap 1, attempt 0: one retry (rc $RC, posts $(qposts))"
unsetting conductor_remote_retry_max

# ── S17: the hub ────────────────────────────────────────────────────────────
reset
RC=$( ( unset MC_ON_MACHINE; MC_PR_DEFERRED_FILE="$DEF"
        setsid() { :; }   # the detached job itself is not under test here
        mc_rebase_spawn "$SLUG" 31 "$PROJ" "$BR" "$HEAD" "$URL" ) >/dev/null 2>&1; echo $?)
[ "$RC" = 0 ] && ok || bad "S17 the hub spawns as today (rc $RC)"
[ -f "$(mc_rb_file "$SLUG" 31 "$HEAD")" ] && ok || bad "S17 the hub job file is written"
[ "$(qreqs)" = 0 ] && ok || bad "S17 the hub makes no /api/queue request ($(qreqs))"
rm -f "$RBDIR"/*.json "$RBDIR"/*.out

# ── S18 ─────────────────────────────────────────────────────────────────────
reset; mv "$T/h/flags/fly-pool-app-$PROJ" "$T/pool-app.off"
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(qreqs)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S18 no pool app: rc 3, no queue request (rc $RC, reqs $(qreqs))"
mv "$T/pool-app.off" "$T/h/flags/fly-pool-app-$PROJ"

# ── S19 ─────────────────────────────────────────────────────────────────────
reset
RC=$( ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"
        mc_rereview_spawn "$SLUG" 31 "$PROJ" "$URL" - "$HEAD" "$T/h/builds/none" ) >/dev/null 2>&1; echo $?)
# BH-7674: with the switch on, the re-review is an RR-* pool row now (its own
# cases are in tests/mc-remote-rereview.bh-7674-test.sh); deploy-verify still
# defers.
[ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && [ "$(jq -r .key <<<"$(qbody)")" = "RR-31-${HEAD:0:8}" ] && ok \
  || bad "S19 re-review on a machine is one RR pool row (rc $RC, posts $(qposts))"
: > "$REQ"
RC=$( ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"
        mc_dv_spawn "$PROJ" "$SLUG" "$NEWSHA" "$T/h/builds/none" ) >/dev/null 2>&1; echo $?)
[ "$RC" = 3 ] && ok || bad "S19 deploy-verify on a machine still rc 3 (got $RC)"
[ "$(words)" = "dv" ] && [ "$(qreqs)" = 0 ] && ok || bad "S19 word dv and no queue request for it ('$(words)', reqs $(qreqs))"

# ── S20: the next tick reads the result through the API ─────────────────────
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$MC_ROWS"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$MC_ROWS"; }
consume() { ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"
              rebase_consume "$KEY" "$SLUG" 31 "$URL" - "$HEAD" - - DIRTY ) >/dev/null 2>&1; echo $?; }
reset; seed done 0 "CONFLICT a.txt b.txt
PR: $URL"
RC=$(consume)
[ "$RC" = 0 ] && ok || bad "S20 a CONFLICT on record is applied: rc 0 (got $RC; log: $(cat "$MC_LOG"))"
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "S20 the row is BLOCKED_HUMAN (got '$(state_of "$KEY")')"
case "$(reason_of "$KEY")" in *a.txt*b.txt*) ok ;; *) bad "S20 the reason names the paths (got '$(reason_of "$KEY")')" ;; esac
[ "$(grep -c '^GET /api/queue' "$REQ")" = 1 ] && ok || bad "S20 the result came from one queue read ($(grep -c '^GET /api/queue' "$REQ"))"
ls "$RBDIR"/*.json >/dev/null 2>&1 && bad "S20 no job file was read or written" || ok
RC=$(consume)
[ "$RC" = 1 ] && ok || bad "S20 the same head is applied once (second rc $RC)"
reset; seed done 0 "REBASED $NEWSHA
PR: $URL"
RC=$(consume)
[ "$RC" = 1 ] && ok || bad "S20 REBASED on record: rc 1, the classifier reads the listed head (got $RC)"
grep -q "remote rebase of ${HEAD:0:8} pushed $NEWSHA" "$MC_LOG" && ok || bad "S20 one log line with the new sha ($(cat "$MC_LOG"))"
reset; seed done 0 "CONFLICT a.txt"
RC=$( ( unset MC_ON_MACHINE; rebase_consume "$KEY" "$SLUG" 31 "$URL" - "$HEAD" - - DIRTY ) >/dev/null 2>&1; echo $?)
[ "$RC" = 1 ] && [ "$(qreqs)" = 0 ] && ok || bad "S20 the hub never reads the queue in rebase_consume (rc $RC, reqs $(qreqs))"
reset; unsetting conductor_remote_spawn; seed done 0 "CONFLICT a.txt"
RC=$(consume)
[ "$RC" = 1 ] && [ "$(qreqs)" = 0 ] && ok || bad "S20 switch off: no queue read in rebase_consume (rc $RC, reqs $(qreqs))"
setting conductor_remote_spawn 1

# ── S22: the stale bound ────────────────────────────────────────────────────
for st in queued claimed; do
  reset; seed "$st" 0 "" 5400
  RC=$(spawn)
  [ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S22 $st at 5400s: stale, rc 3 + rebase, no POST (rc $RC, posts $(qposts), '$(words)')"
  grep -q "remote rebase $DEDUP deferred to the hub (row is $st 5400s old" "$MC_LOG" && ok || bad "S22 the log names the age ($(cat "$MC_LOG"))"
  reset; seed "$st" 0 "" 5399
  RC=$(spawn)
  [ "$RC" = 0 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "S22 $st at 5399s: still in flight (rc $RC, posts $(qposts), '$(words)')"
done
reset; seed claimed 0 "" none
RC=$(spawn)
[ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S22 claimed with no enqueued_at: no bound, so stale (rc $RC, '$(words)')"
reset; seed claimed 0 "" 600
RC=$( ( MC_REBASE_POOL_TIMEOUT_SECS=300; spawn ) )
[ "$RC" = 3 ] && ok || bad "S22 the bound is MC_REBASE_POOL_TIMEOUT_SECS (rc $RC)"

# ── S23: two ticks through the production order ────────────────────────────
# One tick of the machine run, in bin/merge-conductor.sh order: rebase_consume
# (line 789), then the NEEDS_REBASE arm, whose detached branch calls
# mc_rebase_spawn only when `rebase <key> <head>` is not on record and writes
# that mark on rc 0. The mark lives in the attempts ledger of this tree, so it
# outlives each tick the way the pr-state row outlives a machine.
tick() { ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"
           rebase_consume "$KEY" "$SLUG" 31 "$URL" - "$HEAD" - - DIRTY && exit 0
           mc_attempt_has "rebase $KEY $HEAD" 2>/dev/null && exit 0
           mc_rebase_spawn "$SLUG" 31 "$PROJ" "$BR" "$HEAD" "$URL"; rc=$?
           [ "$rc" = 0 ] && mc_attempt_put "rebase $KEY $HEAD"
           exit 0 ) >/dev/null 2>&1; }
marked() { ( mc_attempt_has "rebase $KEY $HEAD" ) 2>/dev/null; }
reset; mc_attempt_clear rebase "$KEY" "$HEAD"
tick
[ "$(qposts)" = 1 ] && marked && ok || bad "S23 tick 1, no row: one put, the mark is written (posts $(qposts))"
tick
[ "$(qposts)" = 1 ] && marked && [ -z "$(words)" ] && ok || bad "S23 tick 2, row queued: no put, the mark stays (posts $(qposts), '$(words)')"
for a in 0 1 2; do
  seed failed "$a" "REBASE_SETUP_FAILED fixture"; : > "$REQ"
  tick
  [ "$(qposts)" = 1 ] && [ "$(row_attempt)" = $((a+1)) ] && marked && [ -z "$(words)" ] && ok \
    || bad "S23 failed attempt $a with the mark on record: one re-put this tick (posts $(qposts), attempt $(row_attempt), '$(words)')"
done
grep -q "remote rebase of ${HEAD:0:8} reads failed" "$MC_LOG" && ok || bad "S23 the reopen is logged ($(cat "$MC_LOG"))"
seed failed 3 "REBASE_SETUP_FAILED fixture"; : > "$REQ"
tick
[ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ! marked && ok || bad "S23 failed at the cap: no put, the rebase word (posts $(qposts), '$(words)')"
: > "$DEF"; tick
[ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S23 the next tick hands back again, it is not silent ('$(words)')"
for r in empty stale; do
  reset; mc_attempt_put "rebase $KEY $HEAD"
  if [ "$r" = empty ]; then seed done 0 ""; else seed claimed 0 "" 9000; fi
  tick
  [ "$(qposts)" = 0 ] && [ "$(words)" = rebase ] && ok || bad "S23 $r with the mark on record: handed back this tick (posts $(qposts), '$(words)')"
done
reset; mc_attempt_put "rebase $KEY $HEAD"; seed claimed 0 "" 60
tick
[ "$(qposts)" = 0 ] && [ -z "$(words)" ] && marked && ok || bad "S23 a running row keeps the mark and puts nothing (posts $(qposts), '$(words)')"
mc_attempt_clear rebase "$KEY" "$HEAD"

# ── S21 ─────────────────────────────────────────────────────────────────────
[ "$STATE0" = "$STATE14" ] && ok || bad "S21 no file under state/ was written by S1-S14: $(diff <(echo "$STATE0") <(echo "$STATE14") | head -5)"
[ -s "$T/gh-argv.txt" ] && bad "S21 no gh ran ($(head -3 "$T/gh-argv.txt"))" || ok

echo "mc-spawn-remote.bh-6888: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
