#!/bin/bash
# tests/lead-review-fly-placement.bh-8027-test.sh — BH-8027: a lead review
# runs on a Fly pool machine when the settings row
# lane_placement.lead-review.<project> = fly says so, so project-6-os lead
# reviews stop loading box-project-6-os-1. bin/lead-review.sh runs WHOLE against
# a scratch harness (tests/lib/lead-worklist-fixture.bh-4956.sh); the jobs
# worker's build_queue and routing routes are a stub layer over its curl.
#
#   F1  row set, project pool-routed, a request row: the tick puts ONE pool row
#       LR-<pr>-<head8> (target fly, meta kind leadreview with the request id
#       and the item) and runs nothing here: no job, no claim, no agent call.
#       The summary says pooled=1.
#   F2  a second tick while that row is queued puts nothing and runs nothing.
#   F2b a finished row: LEAD_REVIEWED done|paid|... is not put again; a row
#       that gave no review is put again up to LRP_RETRY_MAX; a request the
#       land lane requeued (a higher reset_count) is put again.
#   F3  the machine half: the row -> queue_row_job_file -> job.json ->
#       fly/builder-runner.sh run_leadreview_job -> bin/lead-review.sh item.
#       ONE claim of the request, ONE agent call, ONE done result for the
#       bound request and head, the lock-holder job file, and RESULT
#       `LEAD_REVIEWED done`.
#   F4  the same job on a fresh machine whose lead-head guard key is paid:
#       the read-only call-guard peek stops it. No agent call, no second
#       result, the claim released.
#   F5  no row: the tick reviews on this box as before (1 agent call) and
#       reads no pool row. A row whose project is not pool-routed is the box
#       too, with one log line.
#   F6  a worklist item (no request row): the pool row carries the item, the
#       box makes no /start; the machine makes the /start and the one review.
#   Q1  bin/lib/queue-row-job.sh refuses an LR key with other meta, leadreview
#       meta on another key, and an item that is not the row's PR and head.
#   P1  result-prefix-ok, the spawn gates and the walk order know LR- rows.
#   R1  bin/fly-pool.sh's reap closes an LR row done on LEAD_REVIEWED and
#       never reads it as a build; a dead LR machine fails the row and never
#       requeues it.
# Every vendor is a stub. Run: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-fly-placement.bh-8027-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
for s in bin/lib/lead-pool.sh bin/lib/lane-placement.sh bin/lib/queue-row-job.sh; do
  [ -r "$DIR/$s" ] || continue
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done

# The build_queue and routing routes, over the fixture's curl. A put writes
# $FX/queue.<key> (status queued); a live row answers duplicate, as the worker does.
mv "$T/fakebin/curl" "$T/fakebin/curl.lwf"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
case "\$m \$p" in
  "GET /api/queue?"*|"POST /api/queue"|"PATCH /api/queue"|"GET /api/routing/"*) ;;
  "GET /api/lead-reviews/"*) rid="\${p#/api/lead-reviews/}"
    case "\$rid" in ''|*/*|*'?'*) exec "$T/fakebin/curl.lwf" "\$@" ;; esac ;;
  *) exec "$T/fakebin/curl.lwf" "\$@" ;;
esac
( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
code=200
case "\$m \$p" in
  "GET /api/queue?"*)
    k=\$(printf '%s' "\$p" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')
    qs=\$(printf '%s' "\$p" | sed -n 's/.*[?&]status=\([^&]*\).*/\1/p')
    if [ -e "$FX/queue.fail" ]; then code=500; out='{"error":"fixture outage"}'
    elif [ -z "\$k" ]; then out=\$(cat "$FX"/queue.LR-* 2>/dev/null | jq -sc --arg s "\$qs" '{queue:[.[] | select(\$s == "" or .status == \$s)]}')
    elif [ -r "$FX/queue.\$k" ]; then out=\$(jq -c '{queue:[.]}' "$FX/queue.\$k")
    else out='{"queue":[]}'; fi ;;
  "PATCH /api/queue")
    k=\$(printf '%s' "\$body" | jq -r '.key')
    if [ -r "$FX/queue.\$k" ]; then
      jq -c --argjson b "\$body" '.status = \$b.status | .reason = (\$b.reason // .reason)' "$FX/queue.\$k" > "$FX/queue.\$k.new" && mv "$FX/queue.\$k.new" "$FX/queue.\$k"
    fi
    out='{"ok":true}' ;;
  "GET /api/lead-reviews/"*)
    out=\$(jq -c --arg i "\$rid" '[.[] | select(.id == \$i)][0] // null | if . == null then {error:"no such lead review request"} else {request:.} end' "$FX/rows.json")
    case "\$out" in '{"error"'*) code=404 ;; esac ;;
  "POST /api/queue")
    k=\$(printf '%s' "\$body" | jq -r '.key')
    st=\$(jq -r '.status // ""' "$FX/queue.\$k" 2>/dev/null)
    if [ "\$st" = queued ] || [ "\$st" = claimed ]; then out=\$(jq -c '{queued:., duplicate:true}' "$FX/queue.\$k")
    else
      printf '%s' "\$body" | jq -c '{project, ticket_key:.key, ticket_id, status:"queued", target, attempt:(.attempt // 0), meta}' > "$FX/queue.\$k"
      out=\$(jq -c '{queued:., duplicate:false}' "$FX/queue.\$k")
    fi ;;
  "GET /api/routing/"*)
    pj="\${p#/api/routing/}"
    out=\$(jq -nc --arg b "\$(cat "$FX/routing.\$pj" 2>/dev/null || echo local)" '{routing:{builder:\$b, halted:0}}') ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
chmod +x "$T/fakebin/curl"

S8=${SHA:0:8}; S12=${SHA:0:12}
LRKEY="LR-101-$S8"
fly_on() { echo fly > "$FX/settings/lane_placement.lead-review.demo-os"; echo pool > "$FX/routing.demo-os"; }
puts() { lwf_cnt '^POST /api/queue ' "$T/log/worker"; }
put_meta() { grep '^POST /api/queue ' "$T/log/worker" | tail -1 | sed 's/^POST \/api\/queue //' | jq -r '.meta'; }

# ── F1: the row places the review on the pool; nothing runs here ──
lwf_reset; fly_on
lwf_rows requested 101
lwf_tick
[ "$RC" -eq 0 ] && ok || bad "F1 rc=$RC $(cat "$T/out")"
[ "$(puts)" = 1 ] && ok || bad "F1 pool puts=$(puts) (want 1): $(cat "$L" 2>/dev/null)"
PUT=$(grep '^POST /api/queue ' "$T/log/worker" | tail -1 | sed 's/^POST \/api\/queue //')
[ "$(jq -r '"\(.project) \(.key) \(.target) \(.ticket_id)"' <<<"$PUT" 2>/dev/null)" = "demo-os $LRKEY fly 101" ] && ok || bad "F1 the put names the project, LR key, fly and the PR: $PUT"
M=$(put_meta)
[ "$(jq -r '"\(.kind) \(.slug) \(.pr) \(.head) \(.request) \(.mode) \(.item.id) \(.item.head_sha)"' <<<"$M" 2>/dev/null)" = "leadreview example-org/demo-os 101 $SHA r-101 full r-101 $SHA" ] \
  && ok || bad "F1 the meta carries kind, PR, head, request and the item: $M"
[ "$(lwf_agents)" = 0 ] && ok || bad "F1 THE POINT: no agent call on this box, got $(lwf_agents)"
grep -q '^POST /api/jobs ' "$T/log/worker" && bad "F1 the box opened a lead_review job" || ok
grep -q '^POST /api/lead-reviews/r-101/claim' "$T/log/worker" && bad "F1 the box claimed the request" || ok
grep -q "$LRKEY: queued on the Fly pool (attempt 0, queued, request r-101); no local review" "$L" && ok || bad "F1 no queued line: $(cat "$L")"
[[ "$(lwf_summary)" == *" pooled=1"* ]] && ok || bad "F1 summary: $(lwf_summary)"

# ── F2: a second tick while the row is queued puts nothing, runs nothing ──
: > "$T/log/worker"
lwf_tick
[ "$(puts)" = 0 ] && ok || bad "F2 a second put: $(grep '^POST /api/queue' "$T/log/worker")"
[ "$(lwf_agents)" = 0 ] && ok || bad "F2 agent calls=$(lwf_agents) (want 0)"
grep -q "$LRKEY: on the Fly pool (queued); no local review" "$L" && ok || bad "F2 no in-flight line: $(tail -5 "$L")"

cp "$FX/queue.$LRKEY" "$T/row-f3.json" 2>/dev/null
# ── F2b: a finished row is put again only when it gave no review ──
rowset() { # rowset <status> <attempt> <reason> [reset_count of the stored item]
  jq -c --arg s "$1" --argjson a "$2" --arg r "$3" --argjson rc "${4:-0}" \
    '.status = $s | .attempt = $a | .reason = $r | .meta = (.meta | fromjson | .item.reset_count = $rc | tojson)' "$T/row-f3.json" > "$FX/queue.$LRKEY"
}
f2b() { : > "$T/log/worker"; rowset "$@"; lwf_tick; }
f2b done 0 "LEAD_REVIEWED paid"
[ "$(puts)" = 0 ] && grep -q "$LRKEY: the Fly pool reviewed this head (paid); not queued again" "$L" && ok || bad "F2b a reviewed head is not put again: puts=$(puts) $(tail -3 "$L")"
f2b done 0 "LEAD_REVIEWED failed"
[ "$(puts)" = 1 ] && [ "$(jq -r .attempt "$FX/queue.$LRKEY")" = 1 ] && ok || bad "F2b a failed review is put again with attempt 1: puts=$(puts) $(cat "$FX/queue.$LRKEY")"
f2b failed 3 "lead-review machine m1 died"
[ "$(puts)" = 0 ] && grep -q "$LRKEY: the Fly pool ran it 4 times with no review" "$L" && ok || bad "F2b the retry bound holds: puts=$(puts) $(tail -3 "$L")"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "F2b a bounded row counts as held: $(lwf_summary)"
jq -c '.[0].reset_count = 1' "$FX/rows.json" > "$FX/rows.json.new" && mv "$FX/rows.json.new" "$FX/rows.json"
f2b done 0 "LEAD_REVIEWED done" 0
[ "$(puts)" = 1 ] && ok || bad "F2b a request the land lane requeued (reset_count 1 > 0) is put again: puts=$(puts) $(tail -3 "$L")"
[ "$(lwf_agents)" = 0 ] && ok || bad "F2b no agent call on the box, got $(lwf_agents)"
lwf_rows requested 101; cp "$T/row-f3.json" "$FX/queue.$LRKEY"
# ── F3: the machine runs the row ──
QMETA=$(jq -r '.meta' "$T/row-f3.json" 2>/dev/null)
awk '/^run_leadreview_job\(\) \{/,/^\}/; /^leadreview_setup_result\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/runner-fns.sh"
machine() { # machine <case> <key> <meta> — queue_row_job_file then run_leadreview_job, as on a pool machine
  local d="$T/m/$1"; mkdir -p "$d"
  ( . "$H/bin/lib/queue-row-job.sh"; HARNESS="$H" queue_row_job_file demo-os "$d/job.json" "$2" 101 0 "$3" >/dev/null ) || return 1
  ( JOB="$d/job.json" RESULT_FILE="$d/RESULT" HARNESS="$H" PROJECT=demo-os REPO="$T/repos/demo-os" ENVDIR="$T/env" SINK="$d/sink"
    export SINK FLEET_CONF="$H/fleet.conf"
    log() { :; }; beat() { printf 'beat %s\n' "$*" >> "$SINK"; }; warm_up() { printf 'warm_up\n' >> "$SINK"; return 0; }
    # shellcheck source=/dev/null
    . "$T/runner-fns.sh"
    cd "$T" && run_leadreview_job "$2" )
  MD="$d"
}
: > "$T/log/worker"
machine f3 "$LRKEY" "$QMETA"
[ "$(head -1 "$MD/RESULT" 2>/dev/null)" = "LEAD_REVIEWED done" ] && ok || bad "F3 RESULT: $(cat "$MD/RESULT" 2>/dev/null) log: $(tail -5 "$L")"
grep -qx "HEAD: $SHA" "$MD/RESULT" 2>/dev/null && ok || bad "F3 the HEAD: line"
[ "$(lwf_agents)" = 1 ] && ok || bad "F3 agent calls=$(lwf_agents) (want 1)"
[ "$(lwf_cnt '^POST /api/lead-reviews/r-101/claim ' "$T/log/worker")" = 1 ] && ok || bad "F3 claims of r-101=$(lwf_cnt '^POST /api/lead-reviews/r-101/claim ' "$T/log/worker")"
[ "$(lwf_cnt "^POST /api/lead-reviews/r-101/result .*\"head_sha\":\"$SHA\".*\"outcome\":\"done\"" "$T/log/worker")" = 1 ] && ok \
  || bad "F3 THE POINT: one done result for the bound request and head: $(grep 'r-101/result' "$T/log/worker")"
[ "$(lwf_cnt '/result ' "$T/log/worker")" = 1 ] && ok || bad "F3 result posts=$(lwf_cnt '/result ' "$T/log/worker") (want 1)"
[ "$(cat "$H/locks/lead-review-lr-101-$S12.job" 2>/dev/null)" = "job-lr-101-$S12" ] && ok || bad "F3 the lock-holder job file: $(cat "$H/locks/lead-review-lr-101-$S12.job" 2>/dev/null)"
grep -q '"stage":"leadreview_done"' "$MD/sink" 2>/dev/null && ok || bad "F3 the runner beats leadreview_done: $(cat "$MD/sink" 2>/dev/null)"
grep -q "item demo-os example-org/demo-os#101@$S12: done" "$L" && ok || bad "F3 no item line: $(tail -3 "$L")"
# F3 ran `item` through the module "$DIR/bin/lib/lead-review/item.sh" (lr_item_run),
# loaded by bin/lib/lead-review/load.sh; the host keeps only the dispatch line.
grep -q '^lr_item_run() {' "$DIR/bin/lib/lead-review/item.sh" && grep -qx 'item' "$DIR/bin/lib/lead-review/MODULES" && ok || bad "F3 the item module and its MODULES row"
grep -q 'if \[ "\$MODE" = item \]; then lr_item_run; exit \$?; fi' "$DIR/bin/lead-review.sh" && ok || bad "F3 bin/lead-review.sh dispatches item to lr_item_run"

# ── F4: a fresh machine on a paid head: the call-guard stops it ──
FP=$(awk '$1 == "lead-head" {print $2; exit}' "$T/log/agent-fps" 2>/dev/null)
scratch_rm "$H/state/lead-reviews"; rm -f "$H/locks"/lead-review-*
echo 1 > "$FX/callguard.paid"; : > "$T/log/worker"
machine f4 "$LRKEY" "$QMETA"
[ "$(lwf_agents)" = 1 ] && ok || bad "F4 THE POINT: no second agent call, total=$(lwf_agents)"
grep -q "lead-head call-guard paid 1/1 on $FP" "$L" && ok || bad "F4 no guard line for $FP: $(tail -5 "$L")"
grep -q '/result ' "$T/log/worker" && bad "F4 a second result was posted: $(grep '/result ' "$T/log/worker")" || ok
grep -q '^POST /api/lead-reviews/r-101/release ' "$T/log/worker" && ok || bad "F4 the claim was not released"
case "$(head -1 "$MD/RESULT" 2>/dev/null)" in "LEAD_REVIEWED "*) ok ;; *) bad "F4 RESULT: $(head -1 "$MD/RESULT" 2>/dev/null)" ;; esac

# ── F5: no row = this box, as before; a row on a box-routed project = this box ──
lwf_reset
lwf_rows requested 101
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "F5 agent calls=$(lwf_agents) (want 1)"
grep -q '/api/queue' "$T/log/worker" && bad "F5 THE POINT: no pool row is read or put with no placement row" || ok
grep -q "done lr-101-$S12: VERDICT MERGE" "$L" && ok || bad "F5 no local done line: $(grep "lr-101" "$L")"
[[ "$(lwf_summary)" == *"pooled="* ]] && bad "F5 the summary names no pool: $(lwf_summary)" || ok
lwf_reset; echo fly > "$FX/settings/lane_placement.lead-review.demo-os"
lwf_rows requested 101
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "F5b a project that is not pool-routed is reviewed here: agent calls=$(lwf_agents)"
[ "$(puts)" = 0 ] && ok || bad "F5b no pool put for a box-routed project"
grep -q "demo-os: lane_placement.lead-review.demo-os=fly, but its routing is 'local|0', not pool|0; reviews run on this box" "$L" && ok || bad "F5b no routing line: $(grep routing "$L")"

# ── F6: a worklist item rides the pool; the machine makes the /start ──
lwf_reset; fly_on
lwf_needs example-org/demo-os 1
LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick
WKEY="LR-1-$S8"
[ "$(puts)" = 1 ] && ok || bad "F6 pool puts=$(puts) (want 1): $(cat "$L")"
M=$(put_meta)
[ "$(jq -r '"\(.request)|\(.item.src)|\(.item.pr)"' <<<"$M" 2>/dev/null)" = "|worklist|1" ] && ok || bad "F6 the meta carries the worklist item with no request: $M"
grep -q '^POST /api/lead-reviews/start ' "$T/log/worker" && bad "F6 the box made a /start" || ok
[ "$(lwf_agents)" = 0 ] && ok || bad "F6 agent calls on the box=$(lwf_agents)"
: > "$T/log/worker"
machine f6 "$WKEY" "$M"
[ "$(lwf_cnt '^POST /api/lead-reviews/start ' "$T/log/worker")" = 1 ] && ok || bad "F6 the machine /start count=$(lwf_cnt '^POST /api/lead-reviews/start ' "$T/log/worker")"
[ "$(lwf_agents)" = 1 ] && ok || bad "F6 machine agent calls=$(lwf_agents) (want 1)"
[ "$(head -1 "$MD/RESULT" 2>/dev/null)" = "LEAD_REVIEWED done" ] && ok || bad "F6 RESULT: $(head -1 "$MD/RESULT" 2>/dev/null) $(tail -3 "$L")"

# ── M1 (review BLOCK 2): a request row with 4000-char scope_notes and detail ──
# The worker cuts meta at 4000 chars, so the meta must carry the item's identity
# only, and stay valid JSON under that cut. The machine reads the row again by id.
lwf_reset; fly_on
lwf_rows requested 101
BIG=$(head -c 4000 /dev/zero | tr '\0' 'x')
jq -c --arg b "$BIG" '.[0].scope_notes = $b | .[0].detail = $b' "$FX/rows.json" > "$FX/rows.json.new" && mv "$FX/rows.json.new" "$FX/rows.json"
lwf_tick
[ "$(puts)" = 1 ] && ok || bad "M1 pool puts=$(puts) (want 1): $(tail -5 "$L")"
M=$(put_meta)
[ "${#M}" -lt 4000 ] && ok || bad "M1 THE POINT: meta is ${#M} chars (want < 4000)"
jq -e . >/dev/null 2>&1 <<<"${M:0:4000}" && ok || bad "M1 meta cut at 4000 chars is not valid JSON"
[ "$(jq -r '.item | keys | join(",")' <<<"$M" 2>/dev/null)" = "head_sha,id,pr,repo,reset_count" ] && ok || bad "M1 the item carries identity fields only: $(jq -c .item <<<"$M" 2>/dev/null | head -c 300)"
: > "$T/log/worker"
machine m1 "$LRKEY" "$M"
grep -q '^GET /api/lead-reviews/r-101 ' "$T/log/worker" && ok || bad "M1 the machine reads the request row by id: $(grep 'lead-reviews' "$T/log/worker" | head -5)"
[ "$(head -1 "$MD/RESULT" 2>/dev/null)" = "LEAD_REVIEWED done" ] && ok || bad "M1 RESULT: $(head -1 "$MD/RESULT" 2>/dev/null) $(tail -3 "$L")"
[ "$(lwf_agents)" = 1 ] && ok || bad "M1 machine agent calls=$(lwf_agents) (want 1)"
# A row the machine cannot read is a word, never a review of the slim item.
lwf_rows requested 101; scratch_rm "$H/state/lead-reviews"; rm -f "$H/locks"/lead-review-*; : > "$T/log/worker"
echo '[]' > "$FX/rows.json"
machine m1b "$LRKEY" "$M"
[ "$(head -1 "$MD/RESULT" 2>/dev/null)" = "LEAD_REVIEWED unreadable" ] && ok || bad "M1b a request the machine cannot read: $(head -1 "$MD/RESULT" 2>/dev/null)"
grep -q '/claim ' "$T/log/worker" && bad "M1b no claim of a request it could not read" || ok

# ── K1 (review BLOCK 1): the retry bound is the settings row ──
lwf_reset; fly_on
lwf_rows requested 101
cp "$T/row-f3.json" "$FX/queue.$LRKEY"
echo 1 > "$FX/settings/lib.lead-pool.lead_pool_retry_max"
f2b failed 1 "lead-review machine m1 died"
[ "$(puts)" = 0 ] && grep -q "$LRKEY: the Fly pool ran it 2 times with no review.*lib.lead-pool.lead_pool_retry_max=1" "$L" && ok || bad "K1 the row bounds the retries: puts=$(puts) $(tail -3 "$L")"
[ "$(grep -c "$LRKEY.*held" "$T/log/alerts" 2>/dev/null)" = 1 ] && ok || bad "K1 one ALERTS line when the row is first held: $(cat "$T/log/alerts" 2>/dev/null)"
f2b failed 1 "lead-review machine m1 died"
[ "$(grep -c "$LRKEY.*held" "$T/log/alerts" 2>/dev/null)" = 1 ] && ok || bad "K1 a second held tick writes no second ALERTS line: $(grep -c "$LRKEY" "$T/log/alerts" 2>/dev/null)"
rm -f "$FX/settings/lib.lead-pool.lead_pool_retry_max"
f2b failed 1 "lead-review machine m1 died"
[ "$(puts)" = 1 ] && ok || bad "K1 no row = the fallback 3, so attempt 1 is put again: puts=$(puts) $(tail -3 "$L")"
f2b done 0 "LEAD_REVIEWED paid"
[[ "$(lwf_summary)" == *" paid=0 "* && "$(lwf_summary)" == *" poolreviewed=1"* ]] && ok || bad "K1 a reviewed head is not counted as paid: $(lwf_summary)"

# ── S1 (review NOTE): a queued row for a replaced head is closed, not spawned ──
lwf_reset; fly_on
OLD="LR-101-0000aaaa"
jq -nc --arg k "$OLD" '{project:"demo-os", ticket_key:$k, ticket_id:"101", status:"queued", target:"fly", attempt:0, meta:"{}"}' > "$FX/queue.$OLD"
lwf_rows requested 101
lwf_tick
[ "$(jq -r .status "$FX/queue.$OLD")" = done ] && [[ "$(jq -r .reason "$FX/queue.$OLD")" == "LEAD_REVIEWED superseded"* ]] && ok || bad "S1 the stale-head row is closed superseded: $(cat "$FX/queue.$OLD")"
[ "$(jq -r .status "$FX/queue.$LRKEY")" = queued ] && ok || bad "S1 the new head is queued: $(cat "$FX/queue.$LRKEY" 2>/dev/null)"

# ── Q1: the row mapping refuses what it cannot run ──
qrj() { # qrj <dest> <key> <meta> -> rc
  ( mkdir -p "$T/hq/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/qalerts"\n' "$T" > "$T/hq/bin/alert-line.sh"; chmod +x "$T/hq/bin/alert-line.sh"
    queue_done() { printf '%s\n' "$*" >> "$T/qdone"; }
    . "$DIR/bin/lib/queue-row-job.sh"
    HARNESS="$T/hq" queue_row_job_file demo-os "$1" "$2" 101 0 "$3" >/dev/null )
}
mkdir -p "$T/q"
qrj "$T/q/ok.json" "$LRKEY" "$QMETA"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.leadreview | "\(.kind) \(.pr) \(.url) \(.item.id)"' "$T/q/ok.json" 2>/dev/null)" = "leadreview 101 https://github.com/example-org/demo-os/pull/101 r-101" ] \
  && ok || bad "Q1 a good LR row is a leadreview job: rc $rc $(cat "$T/q/ok.json" 2>/dev/null)"
qref() { # qref <case> <key> <meta> <field>
  local rc; rm -f "$T/qdone" "$T/q/r.json"
  qrj "$T/q/r.json" "$2" "$3"; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$T/q/r.json" ] && grep -q "failed leadreview meta rejected ($4)" "$T/qdone" 2>/dev/null && ok \
    || bad "$1 refused (rc 3, no file, row failed naming $4): rc $rc $(cat "$T/qdone" 2>/dev/null)"
}
qref "Q1 build meta on an LR key" "$LRKEY" '{"hotfix":true}' kind
qref "Q1 rebase meta on an LR key" "$LRKEY" '{"kind":"rebase"}' kind
qref "Q1 leadreview meta on a build key" "DEMO-7" "$QMETA" key
qref "Q1 an item of another PR" "$LRKEY" "$(jq -c '.item.pr = 102' <<<"$QMETA")" item
qref "Q1 a bad request id" "$LRKEY" "$(jq -c '.request = "r;x"' <<<"$QMETA")" request

# ── P1: the pool arms know LR- rows ──
export HARNESS="$T/hq"
RPO="$DIR/bin/result-prefix-ok.sh"
bash "$RPO" "LEAD_REVIEWED done" && ok || bad "P1 LEAD_REVIEWED is a RESULT"
bash "$RPO" "LEAD_REVIEW_SETUP_FAILED warm-up failed" && ok || bad "P1 LEAD_REVIEW_SETUP_FAILED is a RESULT"
bash "$RPO" "LEAD_REVIEWX" && bad "P1 LEAD_REVIEWX is not a RESULT" || ok
awk '/^pool_spawn_decision\(\) \{/,/^\}/' "$DIR/bin/fly-pool.sh" > "$T/psd.sh"
P1OUT=$( SINK="$T/p1sink"; export SINK
  say() { printf '%s\n' "$*"; }
  for f in pool_tick_budget_spent psr_marker_has psr_marker_put psr_marker_clear hold_check pool_hold_check pool_spawn_cap_check; do
    eval "$f() { printf '%s\n' $f >> \"\$SINK\"; return 1; }"
  done
  _POOL_ROWS_DECIDED=1; . "$T/psd.sh"; pool_spawn_decision "$T/q/ok.json" "$LRKEY" 101; echo "rc=$?" )
case "$P1OUT" in *"lead-review row"*"rc=0"*) ok ;; *) bad "P1 an LR row passes the ticket spawn gates: $P1OUT" ;; esac
[ -s "$T/p1sink" ] && bad "P1 no ticket gate is asked of an LR row: $(tr '\n' ' ' < "$T/p1sink")" || ok
( . "$DIR/bin/lib/ticket-ownership.sh" 2>/dev/null; to_build_hold demo-os 101 "$LRKEY" >/dev/null ); [ "$?" = 1 ] && ok || bad "P1 an LR row is no ticket to hold"
( . "$DIR/bin/lib/docker-pool-host.sh" >/dev/null 2>&1; dph_key_ok "$LRKEY" ) && bad "P1 dph_key_ok refuses LR-*" || ok

# ── R1: bin/fly-pool.sh's reap and death arms on an LR row ──
H="$T/p"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$H/state/fly" \
         "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" "$H/state/build-queue/tproj" "$T/pbin" "$T/relay"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/psink"; return 0; }
queue_put() { printf 'put %s\n' "\$*" >> "$T/psink"; echo queued; return 0; }
queue_status() { echo claimed; return 0; }
_jobs_req() { printf 'req %s\n' "\$*" >> "$T/psink"; cat "$T/prow.json" 2>/dev/null; }
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
printf 'HARNESS_SECRET=fixture-secret\n' > "$H/env/global.env"
printf 'FLY_API_TOKEN_TPROJ=tok-fixture-1\n' > "$H/env/fly.env"
printf 'tproj example-org/mk - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-tproj"; printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/pbeat"\nexit 0\n' "$T" > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/pbin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/pbin/flock"; printf '#!/bin/bash\nexit 0\n' > "$T/pbin/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/pgh"\nexit 1\n' "$T" > "$T/pbin/gh"
cat > "$T/pbin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/pfly"
case "\$*" in
  *"machine status"*) echo "State: \$(cat "$T/pmstate" 2>/dev/null || echo started)"; exit 0 ;;
  *"ssh console"*"head"*"RESULT"*) head -1 "$T/relay/RESULT" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*"RESULT"*) [ -s "$T/relay/RESULT" ] && base64 -w0 "$T/relay/RESULT"; exit 0 ;;
  *"ssh console"*) exit 0 ;;
  *"machines list"*) echo '[]' ;;
esac
exit 0
FLY
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$T/pbin"/*
# The R1 row name is the LR-<pr>-<head8> queue key of a fixture PR, not a credential.
LRROW="LR-12-abcdef01"
jq -nc --arg k "$LRROW" '{queue:[{project:"tproj",ticket_key:$k,ticket_id:"12",status:"claimed",target:"fly",attempt:0,meta:"{}"}]}' > "$T/prow.json"
preap() { # preap <key> <result-file-or-empty> [machine-state]
  local p
  for p in "$H/builds"/* "$H/state/build-queue/tproj"/* "$H/logs/ALERTS.log" \
           "$T/psink" "$T/pbeat" "$T/pgh" "$T/pfly" "$T/relay/RESULT" "$T/pmstate"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  [ -n "$2" ] && cp "$2" "$T/relay/RESULT"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$T/pmstate"
  : > "$H/logs/fly-pool.log"
  jq -nc --arg k "$1" '{machine:"m1",key:$k,ticket_id:"12",attempt:0}' > "$H/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/pbin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_API_TOKEN_TPROJ=tok-fixture-1 \
           FLY_BIN_DIR="$T/pbin" POOL_SPAWN=0 GH_TOKEN="" POOL_PR_VERIFY_SLEEP=0
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  PLOCAL=$(ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1)
}
printf 'LEAD_REVIEWED done\nPR: https://github.com/example-org/mk/pull/12\nHEAD: abcdef01aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$T/r1"
preap "$LRROW" "$T/r1"
grep -q "^done tproj $LRROW done LEAD_REVIEWED done" "$T/psink" 2>/dev/null && ok || bad "R1 THE POINT: the row is closed done: $(cat "$T/psink" 2>/dev/null) $(tail -5 "$H/logs/fly-pool.log")"
ls "$H/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R1 a lead-review RESULT is never a remote result" || ok
grep -E 'pulls|issues|comments' "$T/pgh" 2>/dev/null && bad "R1 no PR read and no board comment: $(cat "$T/pgh")" || ok
grep -q "pool lead review reaped for $LRROW" "$H/logs/fly-pool.log" && ok || bad "R1 the reap line: $(tail -5 "$H/logs/fly-pool.log")"
[ -f "$PLOCAL/COMMENTED" ] && ok || bad "R1 the dir owes no board close-out"
printf 'PR_CREATED https://github.com/example-org/mk/pull/55\n' > "$T/r2"
preap "$LRROW" "$T/r2"
grep -q "^done tproj $LRROW failed" "$T/psink" 2>/dev/null && ok || bad "R1 a build word on an LR key fails the row: $(cat "$T/psink" 2>/dev/null)"
ls "$H/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R1 a build word on an LR key is never read as a build" || ok
preap "$LRROW" "" stopped
grep -q "^done tproj $LRROW failed" "$T/psink" 2>/dev/null && ok || bad "R1 a dead LR machine fails the row: $(cat "$T/psink" 2>/dev/null)"
grep -q "^put tproj $LRROW" "$T/psink" 2>/dev/null && bad "R1 a dead LR row is never requeued" || ok
grep -qE "^done tproj $LRROW failed .*(died|deferred) [0-9]+ times" "$T/psink" 2>/dev/null && bad "R1 the reason is no blocked-resolver trigger" || ok

echo "lead-review-fly-placement.bh-8027: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
