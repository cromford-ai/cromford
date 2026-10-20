#!/bin/bash
# tests/mc-remote-rereview.bh-7674-test.sh — BH-7674 (slice C2 of #7635): on a
# lane-run machine (MC_ON_MACHINE=1) with conductor_remote_spawn on and a pool
# app, the conductor's head-bound re-review is ONE deduped build_queue row
# (RR-<pr>-<head8>, meta kind=rereview) and not a `rereview` hand-back to the
# hub. The next Fly tick reads the verdict from the hub job file the C1 reap
# wrote, which rides in the merge-conductor snapshot (.rw). Off, or on the hub,
# nothing changes.
#
# Driven through the REAL lib (bin/lib/mc/spawn-remote.sh, bin/lib/mc/rebase.sh,
# bin/lib/mc/classify.sh), the REAL jobs client and a fake curl that is a small
# stateful jobs worker (the bh-6888 suite's shape: duplicate over
# queued/claimed, a put over a terminal row bumps attempt and resets reason).
#
#   M1  no row: rc 0, one POST of RR-12-<head8>, meta kind/by/reason/url, no word
#   M2  failed attempt 0: one POST
#   M3  done + REREVIEW_LANE_FAILED attempt 1: one POST
#   M4  done + REREVIEW_DEFERRED: one POST
#   M5  done + REREVIEWED, meta reason '' and noverdict wanted: one POST
#   M6  done + REREVIEW_NOVERDICT, meta reason '' and noverdict wanted: one POST
#   M7  queued 60 s: rc 0, no POST, `in flight`
#   M8  claimed 5399 s: rc 0; claimed 5400 s: rc 3 + `rereview` and its key
#   M9  done + REREVIEWED APPROVE, same reason: rc 4, no POST
#   M10 done + REREVIEW_NOVERDICT, meta and wanted noverdict: rc 4, no POST
#   M11 failed at attempt 3 of 3: rc 3, no POST
#   M12 empty / REBASED / REREVIEWEDX / REREVIEW_NOVERDICT2 / dropped / no
#       enqueued_at: rc 3, no POST
#   M13 queue GET 500, PUT 500: rc 3, no `queued` line
#   M14 a head of 11 hex: rc 3, no queue request
#   M15 switch off (no row, row 0, no pool app, settings down): rc 3, no queue
#       request (today's path)
#   M16 the hub (MC_ON_MACHINE unset): the detached job, no queue request
#   M17 `rrjob ... done` row and no job file: rc 4, no queue request
#   M18 a `rereviewretry` mark: the POST carries reason noverdict
#   C1  headbound_review on a machine, row queued: no budget take, no POST,
#       REREVIEWING, the log names the pool row
#   C2  headbound_review on a machine, no row: one take, one POST, no word
#   C3  a pool `done APPROVE` job file whose out_file is a hub path: the done
#       arm hands the overlay .out to hb_approve_bind
#   C4  switch off, row queued: no queue read, rc 3 hand-back
#   C5  a hub `running` job file (hub pid) on a machine, switch on and off:
#       running by age, kept, no retry mark, no take, no queue request
#   C6  the same file past MC_REREVIEW_TIMEOUT_SECS is stale; on the hub a
#       dead pid is stale
#   RT1 the put meta through the real queue_row_job_file
#   RT2 the job files ride in the merge-conductor snapshot (rw), this repo only
#   RT3 the consume's delete may ride back (rw)
#   AC1 a Fly run that hits a rebase and a re-review: 2 pool rows, an empty
#       deferred file, and the real C0 gate takes no hub tick
#   AC2 a failed Fly run still gives the hub the full tick
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-remote-rereview.bh-7674-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v flock >/dev/null || { echo "SKIP: jq or flock missing"; exit 0; }

export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/env" "$T/h/builds" "$T/h/locks" "$T/fakebin" "$T/store" "$T/settings"
for L in bin/lib/merge-conductor-lib.sh bin/jobs-client.sh bin/lib/queue-row-job.sh bin/lib/lane-run-inputs.sh \
         bin/fleet-conf.sh bin/lib/mc/project-placement.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$T/h" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for f in bin/lib/mc/project-placement.sh bin/lib/lane-run-inputs.sh bin/fleet-conf.sh; do
  [ -f "$T/h/$f" ] || { mkdir -p "$(dirname "$T/h/$f")"; cp "$DIR/$f" "$T/h/$f"; }
done
printf 'mk example-org/mk https://mk.example /api/board 2 box-mk\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"

SLUG=example-org/mk
PROJ=mk
HEAD=b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1
H8=b1b1b1b1
HEADA=a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2
URL="https://github.com/$SLUG/pull/12"
# A PR url in another case: the row's url must be built from the slug.
URLIN="https://github.com/example-org/MK/pull/12"
RRKEY=RR-12-$H8
DEDUP=mk.12.${HEAD:0:12}.rereview
KEY="$SLUG#12"
REC="$T/h/builds/none"
REQ="$T/req.txt"; DEF="$T/def.txt"; DEFK="$T/defk.txt"

# --- the fake curl: a stateful jobs worker (the bh-6888 suite's) -------------
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
    f="$T/store/\$(q project)__\$(q key).json"
    if [ -f "\$f" ]; then out=\$(jq -c '{queue:[.]}' "\$f"); else out='{"queue":[]}'; fi
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

export PATH="$T/fakebin:$PATH" HARNESS_SECRET=fixture-harness-secret JOBS_URL="https://jobs.example"
export JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_SETTINGS_CACHE_S=0 ROUTING_ROWS=off
printf 'harness-pool-mk-fixture\n' > "$T/h/flags/fly-pool-app-$PROJ"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$T/h/bin/jobs-client.sh"; set +o pipefail
# The pinned clock (D60): the in-flight bound is read against it, never the wall.
NOW=1900000000
mc_now() { echo "$NOW"; }

setting() { printf '%s' "$2" > "$T/settings/$1"; }
unsetting() { rm -f "$T/settings/$1"; }
reset() { rm -f "$T/store/"*.json "$T/qget-500" "$T/qpost-500" "$T/settings-down" "$T/takes.txt" "$T/trans.txt" \
            "$T/bind.txt" "$T/bind-out.txt" "$T/setsid.txt"
          rm -f "$MC_RR_DIR"/*.json "$MC_RR_DIR"/*.out "$MC_RR_DIR"/*.out.* 2>/dev/null
          : > "$REQ"; : > "$DEF"; : > "$DEFK"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; }
# seed <status> <attempt> <reason> [age-s|none] [meta-reason] — the RR row of
#   HEAD as the worker stores it (meta is a JSON string, as D1 returns it).
seed() { jq -nc --arg s "$1" --argjson a "$2" --arg r "$3" --arg k "$RRKEY" --arg age "${4:-60}" --arg mr "${5:-}" \
           --argjson now "$NOW" \
  '{project:"mk",ticket_key:$k,ticket_id:"12",status:$s,target:"fly",attempt:$a,
    enqueued_at:(if $age == "none" then null else ($now - ($age | tonumber) | todate) end),
    reason:(if $r == "" then null else $r end),
    meta:({kind:"rereview",slug:"example-org/mk",pr:12,reason:$mr} | tojson)}' > "$T/store/${PROJ}__$RRKEY.json"; }
qposts() { grep -c '^POST /api/queue ' "$REQ"; }
qreqs()  { grep -c ' /api/queue' "$REQ"; }
qbody()  { grep '^POST /api/queue ' "$REQ" | tail -1 | cut -d' ' -f3-; }
qmeta()  { qbody | jq -r .meta | jq -r "$1"; }
# rr [head] — the production spawn of #12 on a machine; prints its rc.
rr() { ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF" MC_PR_DEFERRED_KEYS_FILE="$DEFK"
         mc_rereview_spawn "$SLUG" 12 "$PROJ" "$URLIN" - "${1:-$HEAD}" "$REC" ) >/dev/null 2>&1; echo $?; }
words() { tr '\n' ' ' < "$DEF" | sed 's/ $//'; }
mark() { echo "$1" >> "$MC_ATTEMPTS"; }

setting conductor_remote_spawn 1

# ── M1 ──────────────────────────────────────────────────────────────────────
reset
RC=$(rr)
[ "$RC" = 0 ] && ok || bad "M1 no row: rc 0 (got $RC; log: $(cat "$MC_LOG"))"
[ "$(qposts)" = 1 ] && ok || bad "M1 exactly one POST /api/queue (got $(qposts))"
B=$(qbody)
[ "$(jq -r .key <<<"$B" 2>/dev/null)" = "$RRKEY" ] && ok || bad "M1 the row key is $RRKEY (got $(jq -r .key <<<"$B" 2>/dev/null))"
[ "$(jq -r .target <<<"$B" 2>/dev/null)" = fly ] && ok || bad "M1 target fly"
[ "$(jq -r .ticket_id <<<"$B" 2>/dev/null)" = 12 ] && ok || bad "M1 ticket_id is the PR number"
[ "$(qmeta .kind 2>/dev/null)" = rereview ] && ok || bad "M1 meta.kind rereview"
[ "$(qmeta .by 2>/dev/null)" = machine ] && ok || bad "M1 meta.by machine"
[ "$(qmeta .reason 2>/dev/null)" = "" ] && [ "$(qmeta 'has("reason")' 2>/dev/null)" = true ] && ok || bad "M1 meta.reason is ''"
[ "$(qmeta .url 2>/dev/null)" = "$URL" ] && ok || bad "M1 meta.url is built from the slug (got $(qmeta .url 2>/dev/null))"
[ "$(qmeta .slug 2>/dev/null)" = "$SLUG" ] && ok || bad "M1 meta.slug"
[ "$(qmeta .head 2>/dev/null)" = "$HEAD" ] && ok || bad "M1 meta.head is the full head"
[ "$(qmeta .reviewed 2>/dev/null)" = "-" ] && ok || bad "M1 meta.reviewed is -"
[ "$(qmeta .dedup 2>/dev/null)" = "$DEDUP" ] && ok || bad "M1 meta.dedup $DEDUP"
[ -z "$(words)" ] && [ ! -s "$DEFK" ] && ok || bad "M1 no deferred word or key (got '$(words)')"
grep -q "remote rereview queued $DEDUP as $RRKEY (attempt 0)" "$MC_LOG" && ok || bad "M1 the log says queued ($(cat "$MC_LOG"))"
M1META=$(qbody | jq -r .meta)

# ── M2-M6: a terminal row that owes a new read is re-put ────────────────────
reset; seed failed 0 "the pool machine died"
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && [ -z "$(words)" ] && ok || bad "M2 failed attempt 0: rc 0, one POST (rc $RC, posts $(qposts), '$(words)')"
grep -q "remote rereview queued $DEDUP as $RRKEY (attempt 1)" "$MC_LOG" && ok || bad "M2 attempt 1 logged ($(cat "$MC_LOG"))"
reset; seed done 1 "REREVIEW_LANE_FAILED x"
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && ok || bad "M3 REREVIEW_LANE_FAILED: rc 0, one POST (rc $RC, posts $(qposts))"
reset; seed done 0 "REREVIEW_DEFERRED x"
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && ok || bad "M4 REREVIEW_DEFERRED: rc 0, one POST (rc $RC, posts $(qposts))"
reset; seed done 0 "REREVIEWED BLOCK" 60 ""; mark "rereviewretry $KEY $HEAD"
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && [ "$(qmeta .reason)" = noverdict ] && ok \
  || bad "M5 REREVIEWED under '' and noverdict wanted: a new read (rc $RC, posts $(qposts))"
reset; seed done 0 "REREVIEW_NOVERDICT" 60 ""; mark "rereviewretry $KEY $HEAD"
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && [ "$(qmeta .reason)" = noverdict ] && ok \
  || bad "M6 REREVIEW_NOVERDICT under '' and noverdict wanted: one POST (rc $RC, posts $(qposts))"

# ── M7-M8: in flight ────────────────────────────────────────────────────────
reset; seed queued 0 "" 60
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "M7 queued 60s: rc 0, no POST (rc $RC, posts $(qposts))"
grep -q "remote rereview $DEDUP in flight (queued)" "$MC_LOG" && ok || bad "M7 the log says in flight ($(cat "$MC_LOG"))"
reset; seed claimed 0 "" 5399
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 0 ] && ok || bad "M8 claimed 5399s: rc 0, no POST (rc $RC, posts $(qposts))"
reset; seed claimed 0 "" 5400
RC=$(rr); [ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rereview ] && [ "$(cat "$DEFK")" = "rereview $KEY" ] && ok \
  || bad "M8 claimed 5400s: rc 3, word and key (rc $RC, posts $(qposts), '$(words)', keys '$(cat "$DEFK")')"

# ── M9-M10: a result on record for this head and reason ─────────────────────
reset; seed done 0 "REREVIEWED APPROVE" 60 ""
RC=$(rr); [ "$RC" = 4 ] && [ "$(qposts)" = 0 ] && [ -z "$(words)" ] && ok || bad "M9 REREVIEWED same reason: rc 4, no POST (rc $RC, posts $(qposts))"
reset; seed done 0 "REREVIEW_NOVERDICT" 60 noverdict; mark "rereviewretry $KEY $HEAD"
RC=$(rr); [ "$RC" = 4 ] && [ "$(qposts)" = 0 ] && ok || bad "M10 NOVERDICT under noverdict: rc 4, no POST (rc $RC, posts $(qposts))"

# ── M11-M14: the hand-back ──────────────────────────────────────────────────
reset; seed failed 3 "the pool machine died"
RC=$(rr); [ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rereview ] && ok || bad "M11 failed 3 of 3: rc 3, no POST (rc $RC, posts $(qposts), '$(words)')"
grep -q "remote rereview $DEDUP deferred to the hub (failed 3 of 3 times" "$MC_LOG" && ok || bad "M11 the log names the cap ($(cat "$MC_LOG"))"
for c in "done||60" "done|REBASED abc|60" "done|REREVIEWEDX APPROVE|60" "done|REREVIEW_NOVERDICT2|60" "dropped||60" "queued||none"; do
  IFS='|' read -r st rs age <<<"$c"
  reset; seed "$st" 0 "$rs" "$age"
  RC=$(rr); [ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rereview ] && ok || bad "M12 $c: rc 3, no POST (rc $RC, posts $(qposts), '$(words)')"
done
reset; : > "$T/qget-500"
RC=$(rr); [ "$RC" = 3 ] && [ "$(qposts)" = 0 ] && [ "$(words)" = rereview ] && ok || bad "M13 GET 500: rc 3, no POST (rc $RC, posts $(qposts))"
reset; : > "$T/qpost-500"
RC=$(rr); [ "$RC" = 3 ] && [ "$(words)" = rereview ] && ! grep -q 'remote rereview queued' "$MC_LOG" && ok \
  || bad "M13 PUT 500: rc 3, no queued line (rc $RC, log $(cat "$MC_LOG"))"
reset
RC=$(rr b1b1b1b1b1b); [ "$RC" = 3 ] && [ "$(qreqs)" = 0 ] && [ "$(words)" = rereview ] && ok || bad "M14 head of 11 hex: rc 3, no queue request (rc $RC, reqs $(qreqs))"

# ── M15: switch off ─────────────────────────────────────────────────────────
for c in none zero noapp down; do
  reset
  case "$c" in
    none) unsetting conductor_remote_spawn ;;
    zero) setting conductor_remote_spawn 0 ;;
    noapp) mv "$T/h/flags/fly-pool-app-$PROJ" "$T/pool-app.off" ;;
    down) : > "$T/settings-down" ;;
  esac
  RC=$(rr); [ "$RC" = 3 ] && [ "$(qreqs)" = 0 ] && [ "$(words)" = rereview ] && ok || bad "M15 $c: rc 3, word, no queue request (rc $RC, reqs $(qreqs), '$(words)')"
  setting conductor_remote_spawn 1; [ -f "$T/pool-app.off" ] && mv "$T/pool-app.off" "$T/h/flags/fly-pool-app-$PROJ"
done

# ── M16: the hub ────────────────────────────────────────────────────────────
reset
RC=$( ( unset MC_ON_MACHINE; MC_PR_DEFERRED_FILE="$DEF"
        setsid() { printf '%s\n' "$*" >> "$T/setsid.txt"; }
        mc_rereview_spawn "$SLUG" 12 "$PROJ" "$URL" - "$HEAD" "$REC" ) >/dev/null 2>&1; echo $?)
i=0; while [ ! -s "$T/setsid.txt" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done  # determinism: ok — a bounded wait for the backgrounded setsid stub's argv; no assertion reads the time
[ "$RC" = 0 ] && [ "$(qreqs)" = 0 ] && [ -z "$(words)" ] && ok || bad "M16 hub: rc 0, no queue request (rc $RC, reqs $(qreqs))"
[ "$(mc_rr_field "$(mc_rr_file "$SLUG" 12 "$HEAD")" status)" = running ] && ok || bad "M16 hub: the job file is running"
grep -q mc_rereview_run "$T/setsid.txt" 2>/dev/null && ok || bad "M16 hub: the detached job was started"

# ── M17-M18 ─────────────────────────────────────────────────────────────────
reset; mark "rrjob $KEY $HEAD done"
RC=$( ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF"; mc_rows_twin_on() { return 0; }
        mc_rereview_spawn "$SLUG" 12 "$PROJ" "$URL" - "$HEAD" "$REC" ) >/dev/null 2>&1; echo $?)
[ "$RC" = 4 ] && [ "$(qreqs)" = 0 ] && ok || bad "M17 rrjob done: rc 4, no queue request (rc $RC, reqs $(qreqs))"
reset; mark "rereviewretry $KEY $HEAD"
RC=$(rr); [ "$RC" = 0 ] && [ "$(qposts)" = 1 ] && [ "$(qmeta .reason)" = noverdict ] && ok || bad "M18 rereviewretry: POST with reason noverdict (rc $RC, posts $(qposts))"

# ── RT1: the meta through the real C1 reader ────────────────────────────────
( . "$T/h/bin/lib/queue-row-job.sh"
  queue_row_job_file "$PROJ" "$T/job-rt1.json" "$RRKEY" 12 0 "$M1META" ) >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .rereview.slug "$T/job-rt1.json" 2>/dev/null)" = "$SLUG" ] \
  && [ "$(jq -r .rereview.pr "$T/job-rt1.json" 2>/dev/null)" = 12 ] && [ "$(jq -r .rereview.head "$T/job-rt1.json" 2>/dev/null)" = "$HEAD" ] \
  && [ "$(jq -r .rereview.reason "$T/job-rt1.json" 2>/dev/null)" = "" ] && ok \
  || bad "RT1 queue_row_job_file of the M1 meta: rc $RC, $(cat "$T/job-rt1.json" 2>/dev/null)"

# ── C: headbound_review on a machine ────────────────────────────────────────
# hb [tick] — one headbound_review of #12 with its neighbours stubbed; the
#   daily cap take is counted in $T/takes.txt.
hb() {
  ( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF" MC_PR_DEFERRED_KEYS_FILE="$DEFK"
    CAPFILE="$T/cap.txt"; REREVIEW_CAP=5; REREVIEW_BUDGET=5; MC_TICK_ID="c-${1:-1}"
    mc_job_running() { return 1; }
    mc_lane_next_review_account() { echo fixture-acct; }
    mc_lane_down_for_account() { return 1; }
    mc_ap_consumed() { return 0; }
    mc_rb_load() { return 1; }
    vd_block_line() { return 1; }
    mc_day_budget_take() { echo take >> "$T/takes.txt"; echo 2026-10-20; return 0; }
    mc_day_budget_give() { echo give >> "$T/takes.txt"; }
    mc_transition() { printf '%s\n' "$3" >> "$T/trans.txt"; }
    hb_approve_bind() { printf '%s\n' "${11:-}" > "$T/bind-out.txt"; return 1; }
    headbound_review moved "$KEY" "$SLUG" 12 "$PROJ" "$URL" "$REC" "$HEAD" - "" CLEAN green ) >/dev/null 2>&1
}
: > "$T/cap.txt"
reset; seed queued 0 "" 60; hb 1
[ ! -s "$T/takes.txt" ] && ok || bad "C1 no daily cap take while the row is in flight ($(cat "$T/takes.txt" 2>/dev/null | tr '\n' ' '))"
[ "$(qposts)" = 0 ] && ok || bad "C1 no POST (got $(qposts))"
grep -qx "REREVIEWING $H8 (detached re-review running)" "$T/trans.txt" 2>/dev/null && ok || bad "C1 transition REREVIEWING (got $(cat "$T/trans.txt" 2>/dev/null))"
grep -q "REREVIEWING $H8 — pool row $RRKEY" "$MC_LOG" && ok || bad "C1 the log names the pool row ($(cat "$MC_LOG"))"
reset; hb 2
[ "$(grep -c take "$T/takes.txt" 2>/dev/null)" = 1 ] && ! grep -q give "$T/takes.txt" && ok || bad "C2 one take, no give ($(cat "$T/takes.txt" 2>/dev/null | tr '\n' ' '))"
[ "$(qposts)" = 1 ] && ok || bad "C2 one POST (got $(qposts))"
grep -q "$KEY REREVIEW_SPAWNED" "$MC_LOG" && [ -z "$(words)" ] && ok || bad "C2 REREVIEW_SPAWNED, no word ('$(words)'; log $(cat "$MC_LOG"))"
# C3: the C1 reap's job file, carried to the machine with a hub out_file path.
reset; seed queued 0 "" 60
printf 'REREVIEWED APPROVE\nPR: %s\nHEAD: %s\nREVIEWED: -\nMODEL: fixture-model\n--- review ---\nThe review text of C3.\n' "$URL" "$HEAD" > "$T/rr-result"
mc_pool_rereview_apply "$PROJ" "$RRKEY" "$T/rr-result" >/dev/null 2>&1
JF=$(mc_rr_file "$SLUG" 12 "$HEAD")
jq -c '.out_file = "/nonexistent/hub/state/merge-conductor/rereview/x.out"' "$JF" > "$JF.tmp" && mv "$JF.tmp" "$JF"
hb 3
[ "$(cat "$T/bind-out.txt" 2>/dev/null)" = "${JF%.json}.out" ] && grep -q 'The review text of C3.' "${JF%.json}.out" && ok \
  || bad "C3 the done arm hands the overlay .out to hb_approve_bind (got '$(cat "$T/bind-out.txt" 2>/dev/null)')"
[ "$(qposts)" = 0 ] && [ ! -s "$T/takes.txt" ] && ok || bad "C3 a done job file is never overridden by a queued row (posts $(qposts))"
# C4: the switch off keeps today's path and reads no queue.
reset; unsetting conductor_remote_spawn; seed queued 0 "" 60; hb 4
[ "$(qreqs)" = 0 ] && [ "$(words)" = rereview ] && ok || bad "C4 switch off: no queue read, the word rereview (reqs $(qreqs), '$(words)')"
setting conductor_remote_spawn 1
# C5-C6: a hub `running` job file in the snapshot. Its pid is a hub pid, dead
#   on the machine; the file reads as running by age, so the machine fails no
#   live hub job, writes no retry mark and buys no second read of the head.
hubrun() { mc_rr_write "$(mc_rr_file "$SLUG" 12 "$HEAD")" running 999999 "$((NOW - $1))" 0 - "$HEAD" - \
             "/nonexistent/hub/state/merge-conductor/rereview/x.out"; }
for sw in on off; do
  reset; [ "$sw" = on ] || unsetting conductor_remote_spawn; hubrun 300
  JF=$(mc_rr_file "$SLUG" 12 "$HEAD")
  [ "$(MC_ON_MACHINE=1 mc_rr_state "$JF")" = running ] && ok || bad "C5 $sw: a hub running file reads running on a machine"
  hb 5; hb 6
  [ -f "$JF" ] && [ "$(mc_rr_field "$JF" status)" = running ] && ok || bad "C5 $sw: the hub job file is kept ($(cat "$JF" 2>/dev/null))"
  ! grep -q rereviewretry "$MC_ATTEMPTS" && ok || bad "C5 $sw: no rereviewretry mark ($(cat "$MC_ATTEMPTS"))"
  [ "$(qreqs)" = 0 ] && [ ! -s "$T/takes.txt" ] && [ -z "$(words)" ] && ok \
    || bad "C5 $sw: no queue request, no take, no word (reqs $(qreqs), takes $(cat "$T/takes.txt" 2>/dev/null | tr '\n' ' '), '$(words)')"
  ! grep -q 'LANE FAILED\|is gone' "$MC_LOG" && grep -qx "REREVIEWING $H8 (detached re-review running)" "$T/trans.txt" && ok \
    || bad "C5 $sw: REREVIEWING, not failed ($(cat "$MC_LOG"))"
  # C6: past MC_REREVIEW_TIMEOUT_SECS the age bound still makes it stale.
  reset; hubrun 2700
  [ "$(MC_ON_MACHINE=1 mc_rr_state "$(mc_rr_file "$SLUG" 12 "$HEAD")")" = stale ] && ok || bad "C6 $sw: past the timeout a hub file is stale"
  setting conductor_remote_spawn 1
done
# The hub keeps its pid check: the same dead pid is stale there.
reset; hubrun 300
[ "$(mc_rr_state "$(mc_rr_file "$SLUG" 12 "$HEAD")")" = stale ] && ok || bad "C6 the hub reads a dead pid as stale"

# ── RT2-RT3: the job files ride in the snapshot ─────────────────────────────
reset
mc_pool_rereview_apply "$PROJ" "$RRKEY" "$T/rr-result" >/dev/null 2>&1
REL="state/merge-conductor/rereview/$(basename "$(mc_rr_file "$SLUG" 12 "$HEAD")")"
lri() { ( export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" LRI_MANIFEST_DIR="$DIR/catalog/lane-run-inputs.d"
          . "$T/h/bin/lib/lane-run-inputs.sh" || exit 99; lri_member_ok "$@" ) 2>/dev/null; }
[ -f "$T/h/$REL" ] && [ -f "$T/h/${REL%.json}.out" ] && ok || bad "RT2 the apply wrote $REL and its .out"
lri "$PROJ" "$REL" - rw merge-conductor && ok || bad "RT2 rw carries $REL"
lri "$PROJ" "${REL%.json}.out" - rw merge-conductor && ok || bad "RT2 rw carries the .out"
lri "$PROJ" "${REL%.json}.out" - ro merge-conductor && ok || bad "RT2 the ro snapshot carries the .out"
lri "$PROJ" "state/merge-conductor/rereview/example-org_other_12_$HEAD.json" - rw merge-conductor \
  && bad "RT2 rw refuses another repo's job file" || ok
lri "$PROJ" "state/merge-conductor/rereview/.lock" - rw merge-conductor && bad "RT2 rw refuses the lock file" || ok
# RT3: the lanefail arm deletes the file; the delete is a member of rw.
lri "$PROJ" "state/merge-conductor/rereview/example-org_mk_12_$HEADA.json" - rw merge-conductor && ok || bad "RT3 a deleted job file of this repo may ride back"

# ── AC1: a Fly run with a rebase and a re-review ────────────────────────────
reset
( MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF" MC_PR_DEFERRED_KEYS_FILE="$DEFK"
  mc_rebase_spawn "$SLUG" 14 "$PROJ" ticket/x "$HEADA" "https://github.com/$SLUG/pull/14"
  mc_rereview_spawn "$SLUG" 12 "$PROJ" "$URL" - "$HEAD" "$REC" ) >/dev/null 2>&1
KEYS=$(grep '^POST /api/queue ' "$REQ" | cut -d' ' -f3- | jq -r .key 2>/dev/null | sort | paste -sd, -)
[ "$(qposts)" = 2 ] && [ "$KEYS" = "RB-14-${HEADA:0:8},$RRKEY" ] && ok || bad "AC1 two pool rows RB-14 and RR-12 (posts $(qposts), keys '$KEYS'; log $(cat "$MC_LOG"))"
[ ! -s "$DEF" ] && [ ! -s "$DEFK" ] && ok || bad "AC1 the deferred words and keys files are empty ('$(words)', '$(cat "$DEFK")')"
# The PROF line the run prints (bin/merge-conductor-project.sh finish()).
DEFW=$(sort -u "$DEF" | tr -cd 'a-z\n' | grep . | paste -sd, -)
DPRS=$( ( . "$T/h/bin/lib/mc/project-placement.sh"; mc_proj_defer_field "$DEFK" "$SLUG" ) 2>/dev/null)
[ "${DEFW:--}" = - ] && [ "$DPRS" = - ] && ok || bad "AC1 deferred=${DEFW:--} deferred_prs=$DPRS (want - and -)"
PROF="PROF mc-project state=TICKED landed=0 queued=0 deferred=${DEFW:--} fence=4 deferred_prs=$DPRS"
# The real C0 gate, with the bh-7635 suite's stub set.
G="$T/gate"; mkdir -p "$G"
printf '#!/usr/bin/env bash\n[ "$1" = mk ] && [ "$2" = repo ] && { echo example-org/mk; exit 0; }\nexit 1\n' > "$T/h/bin/fleet-conf.sh"
chmod +x "$T/h/bin/fleet-conf.sh"
cat > "$G/stubs.sh" <<EOF
lp_decide() { LP_PLACE=fly; LP_WHY="row fly"; }
_lp_client() { return 0; }
_setting_key_ok() { return 0; }
setting_get() { cat "$G/settings/\$1" 2>/dev/null; }
lp_enqueue() { echo "enqueue \$2" >> "$G/enqueues.txt"; return 0; }
lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; return 0; }
lri_publish() { echo "published 0 0"; return 0; }
mc_proj_publish() { return 0; }
_jobs_req() {
  [ "\$1" = GET ] && { cat "$G/rows.json"; return 0; }
  JOBS_HTTP=200; JOBS_BODY='{}'; return 0
}
EOF
mkdir -p "$G/settings"
grow() { jq -nc --argjson id "$1" --arg s "$2" --arg pl "$3" --arg rc "$4" --arg at "$(date -u -d "@$(( $(date -u +%s) - 30 ))" +%FT%TZ)" \
  '{rows:[{id:$id, project:"mk", status:$s, prof_line:$pl, rc:($rc|tonumber? // null), enqueued_at:$at}]}' > "$G/rows.json"; }
gate() {
  : > "$G/gate.log"; rm -f "$G/enqueues.txt"; scratch_rm "$T/h/state/merge-conductor/project-fly"
  ( unset MC_ON_MACHINE; HARNESS="$T/h" bash -c ". \"$T/h/bin/lib/mc/project-placement.sh\"; . \"$G/stubs.sh\"; mc_proj_gate mk 600; rc=\$?; echo \"keys=\${MC_PROJ_TAKEBACK_KEYS:-}\" > \"$G/gate.keys\"; exit \$rc" ) >>"$G/gate.log" 2>&1
  GRC=$?
}
grow 71 done "$PROF" 0; gate
[ "$GRC" = 0 ] && [ "$(cat "$G/gate.keys")" = "keys=" ] && ! grep -q 'hub keyed\|hub full tick\|fallback=' "$G/gate.log" && [ -s "$G/enqueues.txt" ] && ok \
  || bad "AC1 the gate takes no hub tick, keyed or full (rc $GRC, $(cat "$G/gate.keys"), log $(cat "$G/gate.log"))"

# ── AC2: a failed Fly run still gives the tick to the hub ───────────────────
grow 72 done "$PROF" 1; gate
[ "$GRC" = 2 ] && grep -q 'fallback=machine-failed (row 72: rc=1)' "$G/gate.log" && ok \
  || bad "AC2 a failed row: rc 2, machine-failed (rc $GRC, log $(cat "$G/gate.log"))"

# The machine spawn never reaches git or gh.
[ ! -s "$T/git-argv.txt" ] && [ ! -s "$T/gh-argv.txt" ] && ok || bad "no git or gh call ($(cat "$T/git-argv.txt" "$T/gh-argv.txt" 2>/dev/null))"

echo "mc-remote-rereview.bh-7674: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
