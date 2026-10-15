#!/bin/bash
# tests/main-red-state-rows.bh-4156-test.sh — BH-4156 (C2): the main-red lanes
# keep their records as rows, not as files under state/main-red/.
#
# The REAL bin/main-red-detector.sh, bin/main-red-pr-pair.sh and
# bin/main-red-recheck.sh run with their real lib closure and the REAL
# bin/jobs-client.sh. A fake `curl` on PATH hands each request to the REAL
# worker (worker/jobs/src/index.js) over one file-backed node:sqlite DB built
# from the composed schema (the tests/conflict-hotspots-fleet.bh-5267-test.sh
# pattern). Only gh and lane-alert.sh are stubs.
#   L1-L6  the client verbs in bin/lib/main-red-state.sh: upsert last-wins,
#          write-once errors and the guarded '##[' rewrite, one open pair per
#          hash and an append-only resolve, the ledger rows, rc 2 for an
#          undeployed route, rc 1 for an outage or a refused request, and
#          mrs_on's three "no coordination DB here" answers.
#   D1-D4  the detector: verdict and published rows, no state/main-red file,
#          the OFF self-heal from the row, an unreadable marker row does not act.
#   P1-P8  the PR-pair lane: pr_errors and pairs rows, no state/main-red file,
#          one alert per pair, resolve stamps and keeps, an unreadable verdict
#          or ledger does not act, an undeployed route falls back to the files.
#   R1-R3  the recheck lane: the stamp is a ledger row, it gates the next run,
#          and an unreadable stamp starts no detector.
# Also runs worker/jobs/test/main-red-state.bh-4156.test.js (the route suite).
# Every timestamp is a literal. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/main-red-state-rows.bh-4156-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "main-red-state-rows.bh-4156: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
for c in jq python3 flock; do command -v "$c" >/dev/null 2>&1 || { echo "FAIL: $c is required"; exit 1; }; done

LIB="$DIR/bin/lib/main-red-state.sh"
ROUTE="$DIR/worker/jobs/src/routes/main-red-state.js"
FRAG="$DIR/worker/jobs/test/route-table.d/774-main-red-state.txt"
SCHEMA="$DIR/worker/jobs/schema.d/0026-bh-4156-main-red-state.sql"
for f in "$LIB" "$ROUTE" "$FRAG" "$SCHEMA"; do [ -f "$f" ] && ok || bad "missing $f"; done

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "main-red-state-rows: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  done_
fi

# core.js imports the generated, git-ignored catalog/lanes.json (BH-5921).
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
if (cd "$DIR/worker/jobs" && node --test test/main-red-state.bh-4156.test.js >"$T/route.out" 2>&1); then ok
else
  bad "worker route suite: $(grep -E 'not ok' "$T/route.out" | head -5)"
  grep -E 'Error|AssertionError|expected|actual' "$T/route.out" | head -30 | sed 's/^/  route: /'
fi

# ── the real worker over one sqlite file ─────────────────────────────────────
export MRS_T="$T" MRS_DB="$T/d1.sqlite" NODE_OPTIONS=--no-warnings
SECRET=tok-fixture-bh4156
cat >"$T/init.mjs" <<EOF
import { readFileSync, rmSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
rmSync(process.env.MRS_DB, { force: true });
const db = new DatabaseSync(process.env.MRS_DB);
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
EOF
cat >"$T/drv.mjs" <<EOF
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync(process.env.MRS_DB);
const [method, url, body] = process.argv.slice(2);
const res = await worker.fetch(new Request(url, {
  method, headers: { authorization: 'Bearer $SECRET', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: '$SECRET' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
fresh_db() { node "$T/init.mjs" || { echo "FAIL: schema.sql did not apply"; exit 1; }; }
sql() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.env.MRS_DB);
  const r = db.prepare(process.argv[1]).all();
  for (const row of r) console.log(Object.values(row).map((v) => v === null ? "NULL" : v).join("\t"));' "$1"; }
sqlx() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  new DatabaseSync(process.env.MRS_DB).exec(process.argv[1]);' "$1"; }

mkdir -p "$T/fakebin"
# The fake curl. $MRS_T/outage: every request is a transport failure (rc 7).
# $MRS_T/outage-<word>: only a path that holds "/<word>" fails.
# $MRS_T/outage-put-<word>: only a PUT to such a path fails.
# $MRS_T/junk-<word>: a path that holds "/<word>" answers 200 with `{}`.
# $MRS_T/trunc-pairs: the open-pairs read answers a truncated (capped) list.
# $MRS_T/absent: a worker deployed before this ticket (the /api/main-red-state
# family answers the router's unknown-endpoint 404).
cat >"$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL=""; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary|-d|--data) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; http*://*) URL="$1"; shift ;; *) shift ;; esac
done
case "$URL" in https://jobs.test*) ;; *) exit 22 ;; esac
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
P="${URL#https://jobs.test}"
printf '%s %s\n' "$M" "$P" >> "$MRS_T/req.log"
[ -e "$MRS_T/outage" ] && exit 7
for f in "$MRS_T"/outage-*; do
  [ -e "$f" ] || continue
  w=${f##*/outage-}
  case "$w" in put-*) [ "$M" = PUT ] || continue; w=${w#put-} ;; esac
  case "$P" in *"/$w"*) exit 7 ;; esac
done
[ -e "$MRS_T/trunc-pairs" ] && case "$M $P" in "GET /api/main-red-state/pairs"*)
  printf '{"repo":"o/r","pairs":[{"hash":"abc","job":"j","first_error":"e","prs":"#1","opened_at":"t"}],"truncated":true}\n200'; exit 0 ;; esac
for f in "$MRS_T"/junk-*; do
  [ -e "$f" ] || continue
  case "$P" in *"/${f##*/junk-}"*) printf '{}\n200'; exit 0 ;; esac
done
if [ -e "$MRS_T/absent" ]; then
  case "$P" in /api/main-red-state/*) printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404'; exit 0 ;; esac
fi
exec flock "$MRS_DB.lock" node "$MRS_T/drv.mjs" "$M" "$URL" "$BODY"
STUB
chmod +x "$T/fakebin/curl"

# gh: one stub for both lanes (the tests/main-red-pair-suspected.bh-1451-test.sh
# shape). Open PRs from $T/pulls.json, a head's runs from $T/runs-<sha>.json,
# main's runs from $T/mainruns.json, a run's failing job from $T/jobs-<id>.txt,
# a job log from $T/joblog-<id>.txt. No fixture file = the read failed.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
PROJ='[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]'
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 echo "[]" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           case "$A" in
                                *"branch=main"*)
                                  [ -s "$T/mainruns.json" ] || exit 1
                                  jq -c "$PROJ" "$T/mainruns.json" ;;
                                *)
                                  sha=${A##*head_sha=}; sha=${sha%% *}
                                  [ -s "$T/runs-$sha.json" ] || exit 1
                                  jq -c "$PROJ" "$T/runs-$sha.json" ;;
                              esac ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env"
: > "$H/env/global.env"
cat > "$H/bin/lane-alert.sh" <<'LA'
#!/bin/bash
printf '%s\n' "$*" >> "$MRS_T/alerts.log"
LA
chmod +x "$H/bin/lane-alert.sh"
for s in bin/main-red-detector.sh bin/main-red-pr-pair.sh bin/main-red-recheck.sh bin/jobs-client.sh bin/project-of.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "closure: $s"
done
[ -f "$H/bin/lib/main-red-state.sh" ] && ok || bad "the lanes' closure does not carry bin/lib/main-red-state.sh"

export PATH="$T/fakebin:$PATH" GH_SINK="$T/gh.log" T
unset GH_TOKEN
lane_env() { env HARNESS="$H" HARNESS_ENV_DIR="$H/env" HARNESS_SECRET="$SECRET" JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=60 JOBS_ALERT=0 JOBS_BOX=box-fixture \
  LANE_GATE_CACHE_S=0 MC_MAIN_RED_LABEL=fix-main-red HARNESS_PR_AUTHORS=fixture-operator "$@"; }
detect() { lane_env bash "$H/bin/main-red-detector.sh" o/r >"$T/lane.out" 2>"$T/lane.err"; }
pair()   { lane_env bash "$H/bin/main-red-pr-pair.sh" o/r >"$T/lane.out" 2>"$T/lane.err"; }
recheck() { lane_env MAIN_RED_RECHECK_MIN=5 MAIN_RED_REPOS=o/r bash "$H/bin/main-red-recheck.sh" >"$T/lane.out" 2>"$T/lane.err"; }
# lib <shell text> — the client verbs, sourced the way a lane sources them.
lib() { lane_env bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/main-red-state.sh"; '"$1"; }
# The record files a lane may not leave: anything under state/main-red but body/.
files_left() { find "$H/state/main-red" -type f -not -path "*/body/*" 2>/dev/null | sed "s#^$H/##" | sort | tr '\n' ' '; }
reset_case() {
  fresh_db
  rm -f "$T"/outage* "$T"/junk-* "$T/trunc-pairs" "$T/absent" "$T/req.log" "$T/alerts.log" "$T/gh.log" "$T"/runs-*.json \
        "$T"/jobs-*.txt "$T"/joblog-*.txt "$T/mainruns.json" "$T/pulls.json" "$H"/flags/main-red-*
  scratch_rm "$H/state/main-red"
  : > "$H/logs/main-red.log"; : > "$H/logs/main-red-pr-pair.log"
}
reqs() { grep -c -- "$1" "$T/req.log" 2>/dev/null || true; }

CI=".github/workflows/harness-ci.yml"
mainruns() { # mainruns <name|path|conclusion|created_at|sha[|status]>... (newest first)
  local out='{"workflow_runs":[' first=1 spec n p c t s sha id=7000
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}; id=$((id + 1))
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" --arg c "$c" --argjson id "$id" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end),
        created_at:$t, head_sha:$sha, html_url:("https://github.com/o/r/actions/runs/"+($id|tostring)), id:$id}')
  done
  printf '%s]}' "$out" > "$T/mainruns.json"
}
pulls() { # pulls <number:head-sha:updatedAt>...
  local out='[' first=1 spec num sha upd
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)), title:"t", body:"",
        head:{sha:$sha, ref:("b"+($n|tostring))}, base:{ref:"main"}, draft:false,
        user:{login:"fixture-operator", type:"User"}, created_at:$u, updated_at:$u,
        merged_at:null, closed_at:null, labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}
head_runs() { # head_runs <sha> <name|path|conclusion|created_at|run-id[|status]>...
  local sha="$1" out='{"workflow_runs":[' first=1 spec n p c t id s; shift
  for spec in "$@"; do
    IFS='|' read -r n p c t id s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --argjson id "$id" --arg c "$c" --arg sha "$sha" \
      '{name:$n, path:$p, status:$s, head_sha:$sha, conclusion:(if $c=="null" then null else $c end),
        created_at:$t, html_url:("https://github.com/o/r/actions/runs/"+($id|tostring)), id:$id}')
  done
  printf '%s]}' "$out" > "$T/runs-$sha.json"
}
HA=aaaa111aaaa111aaaa111aaaa111aaaa111aaaa1
HB=bbbb222bbbb222bbbb222bbbb222bbbb222bbbb2
HC=cccc333cccc333cccc333cccc333cccc333cccc3
HD=dddd444dddd444dddd444dddd444dddd444dddd4
ERRTEXT="FAIL: clock-rolling-window worker/jobs/test/burn.test.js"
pair_fixture() {
  pulls "1:$HA:2026-09-22T12:35:00Z" "2:$HB:2026-09-22T12:36:00Z"
  head_runs "$HA" "Harness CI|$CI|failure|2026-09-22T12:30:00Z|9001"
  head_runs "$HB" "Harness CI|$CI|failure|2026-09-22T12:30:35Z|9002"
  printf '%s\t%s\n' "Test determinism lint" 8001 > "$T/jobs-9001.txt"
  printf '%s\t%s\n' "Test determinism lint" 8002 > "$T/jobs-9002.txt"
  printf '%s\n' "2026-09-22T12:31:02.1234567Z $ERRTEXT" > "$T/joblog-8001.txt"
  printf '%s\n' "2026-09-22T12:31:40.7654321Z $ERRTEXT" > "$T/joblog-8002.txt"
}
green_fixture() {
  pulls "1:$HC:2026-09-22T12:50:00Z" "2:$HD:2026-09-22T12:51:00Z"
  head_runs "$HC" "Harness CI|$CI|success|2026-09-22T12:45:00Z|9003"
  head_runs "$HD" "Harness CI|$CI|success|2026-09-22T12:46:00Z|9004"
}
put_verdict() { lib "mrs_verdict_put o/r '$1' '$2' '${3:-}'" || bad "setup: verdict row $1 not written"; }

# ── L: the client verbs ──────────────────────────────────────────────────────
reset_case
lib 'mrs_on' && ok || bad "L6: mrs_on must be rc 0 with a client, a URL and a secret"
lane_env HARNESS_SECRET= bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/main-red-state.sh"; mrs_on' \
  && bad "L6: no secret must be 'no coordination DB here' (rc 1)" || ok
lane_env JOBS_URL= bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/main-red-state.sh"; mrs_on' \
  && bad "L6: an empty JOBS_URL must be 'no coordination DB here' (rc 1)" || ok
lane_env bash -c '. "$HARNESS/bin/lib/main-red-state.sh"; mrs_on' \
  && bad "L6: no _jobs_req must be 'no coordination DB here' (rc 1)" || ok

lib 'mrs_verdict_put o/r red tip f1f1f1f1 && mrs_verdict_put o/r none no-runs ""'; RC=$?
[ "$RC" = 0 ] && ok || bad "L1: two verdict PUTs rc=$RC"
OUT=$(lib 'mrs_verdict_get o/r'); RC=$?
[ "$RC" = 0 ] && [ "$(cut -f1-3 <<<"$OUT")" = "$(printf 'none\tno-runs\t')" ] && ok \
  || bad "L1: last verdict must win: rc=$RC out=$OUT"
[ "$(sql "SELECT COUNT(*) FROM main_red_verdicts")" = 1 ] && ok || bad "L1: one verdict row per repo"
lib 'mrs_verdict_get o/none' >/dev/null; RC=$?
[ "$RC" = 3 ] && ok || bad "L1: no verdict row must be rc 3 (a measured none), got $RC"

lib "mrs_pr_error_put o/r $HA 'lint' 'FAIL: one' t1 && mrs_pr_error_put o/r $HA 'lint' 'FAIL: two' t2"; RC=$?
[ "$RC" = 0 ] && [ "$(sql "SELECT error FROM main_red_pr_errors WHERE head='$HA'")" = "FAIL: one" ] && ok \
  || bad "L2: pr_errors must be write-once: rc=$RC row=$(sql "SELECT error FROM main_red_pr_errors")"
sqlx "INSERT INTO main_red_pr_errors (repo, head, job, error, run_at, at) VALUES ('o/r','$HB','lint','##[group]Run FAIL=0','t','2026-09-22T12:40:00Z')"
lib "mrs_pr_error_put o/r $HB 'lint' 'FAIL: real' t3" || bad "L2: the stale rewrite PUT failed"
[ "$(sql "SELECT error FROM main_red_pr_errors WHERE head='$HB'")" = "FAIL: real" ] && ok \
  || bad "L2: a '##[' row must be replaced once: $(sql "SELECT error FROM main_red_pr_errors WHERE head='$HB'")"
lib "mrs_pr_errors_get o/r '$T/got.tsv' $HA $HB $HC"; RC=$?
[ "$RC" = 0 ] && [ "$(cut -f1,3 "$T/got.tsv" | sort | tr '\t\n' '| ')" = "$HA|FAIL: one $HB|FAIL: real " ] && ok \
  || bad "L2: pr_errors read: rc=$RC got=$(cat "$T/got.tsv" 2>/dev/null)"

lib "mrs_pair_open o/r abc123def456 lint 'FAIL: x' '#1, #2' && mrs_pair_open o/r abc123def456 lint 'FAIL: x' '#1, #2, #3'"; RC=$?
[ "$RC" = 0 ] && [ "$(sql "SELECT COUNT(*) FROM main_red_pairs")" = 1 ] && ok \
  || bad "L3: one open pair per hash: rc=$RC rows=$(sql "SELECT COUNT(*) FROM main_red_pairs")"
lib "mrs_pairs_open o/r '$T/open.tsv'"; RC=$?
[ "$RC" = 0 ] && [ "$(cut -f1,4 "$T/open.tsv")" = "$(printf 'abc123def456\t#1, #2')" ] && ok \
  || bad "L3: the open pair read: rc=$RC got=$(cat "$T/open.tsv" 2>/dev/null)"
lib "mrs_pair_resolve o/r abc123def456" || bad "L3: resolve failed"
lib "mrs_pairs_open o/r '$T/open.tsv'"
{ [ ! -s "$T/open.tsv" ] && [ "$(sql "SELECT COUNT(*) FROM main_red_pairs WHERE resolved_at IS NOT NULL")" = 1 ]; } && ok \
  || bad "L3: a resolve stamps and keeps the row: open=$(cat "$T/open.tsv") rows=$(sql "SELECT * FROM main_red_pairs")"

lib 'mrs_published_set main-red-o-r on' || bad "L4: published on failed"
lib 'mrs_published_get main-red-o-r'; RC=$?
[ "$RC" = 0 ] && ok || bad "L4: a published row on must be rc 0, got $RC"
lib 'mrs_published_set main-red-o-r off && mrs_published_get main-red-o-r'; RC=$?
[ "$RC" = 3 ] && ok || bad "L4: a published row off must be rc 3, got $RC"
lib 'mrs_published_get main-red-never'; RC=$?
[ "$RC" = 3 ] && ok || bad "L4: no published row must be rc 3, got $RC"
lib 'mrs_recheck_set 1760000000'; OUT=$(lib 'mrs_recheck_get'); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = 1760000000 ] && ok || bad "L4: the recheck stamp row: rc=$RC out=$OUT"

touch "$T/absent"
lib 'mrs_verdict_get o/r' >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "L5: an undeployed route must be rc 2, got $RC"
lib 'mrs_verdict_put o/r green green a2'; RC=$?
[ "$RC" = 2 ] && ok || bad "L5: an undeployed route PUT must be rc 2, got $RC"
rm -f "$T/absent"; touch "$T/outage"
lib 'mrs_verdict_get o/r' >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L5: an outage must be rc 1 (unreadable), got $RC"
lib 'mrs_published_get main-red-o-r'; RC=$?
[ "$RC" = 1 ] && ok || bad "L5: an outage on the marker row must be rc 1, got $RC"
rm -f "$T/outage"
lib 'mrs_verdict_put "o/r x" red tip a1'; RC=$?
[ "$RC" = 1 ] && ok || bad "L5: a refused (400) write must be rc 1, got $RC"
# L7 — a 200 that does not carry the answer is unreadable, never "no row".
touch "$T/junk-verdict" "$T/junk-pr-errors" "$T/junk-pairs"
lib 'mrs_verdict_get o/r' >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L7: a verdict 200 with no verdict key must be rc 1, got $RC"
lib "mrs_pr_errors_get o/r '$T/got.tsv' $HA"; RC=$?
[ "$RC" = 1 ] && ok || bad "L7: a pr-errors 200 with no rows array must be rc 1, got $RC"
lib "mrs_pairs_open o/r '$T/open.tsv'"; RC=$?
[ "$RC" = 1 ] && ok || bad "L7: a pairs 200 with no pairs array must be rc 1, got $RC"
rm -f "$T"/junk-*
touch "$T/trunc-pairs"
lib "mrs_pairs_open o/r '$T/open.tsv'"; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/open.tsv" ] && ok || bad "L7: a truncated open-pairs list must be rc 1 and no list, got $RC: $(cat "$T/open.tsv")"
rm -f "$T/trunc-pairs"

# ── D: the detector ──────────────────────────────────────────────────────────
reset_case
mainruns "Harness CI|$CI|failure|2026-09-22T11:00:00Z|f1f1f1f1"
detect
[ "$(sql "SELECT decision, reason, sha FROM main_red_verdicts WHERE repo='o/r'")" = "$(printf 'red\ttip\tf1f1f1f1')" ] && ok \
  || bad "D1: the red tick must write its verdict row: $(sql "SELECT * FROM main_red_verdicts") log=$(tail -3 "$H/logs/main-red.log")"
[ -f "$H/flags/main-red-o-r" ] && ok || bad "D1: the red tick raised no flag"
[ "$(sql "SELECT status FROM ledgers WHERE kind='main_red_published' AND key='main-red-o-r'")" = on ] && ok \
  || bad "D1: the published marker must be a ledger row: $(sql "SELECT kind, key, status FROM ledgers")"
[ -z "$(files_left)" ] && ok || bad "D1: the detector left record files: $(files_left)"

mainruns "Harness CI|$CI|success|2026-09-22T12:00:00Z|a2a2a2a2" "Harness CI|$CI|failure|2026-09-22T11:00:00Z|f1f1f1f1"
detect
[ "$(sql "SELECT decision FROM main_red_verdicts WHERE repo='o/r'")" = green ] && ok \
  || bad "D2: the green tick must replace the verdict row: $(sql "SELECT * FROM main_red_verdicts")"
[ "$(sql "SELECT COUNT(*) FROM main_red_verdicts")" = 1 ] && ok || bad "D2: still one verdict row"
[ ! -f "$H/flags/main-red-o-r" ] && ok || bad "D2: the green tick must clear the flag"
[ "$(sql "SELECT status FROM ledgers WHERE kind='main_red_published' AND key='main-red-o-r'")" = off ] && ok \
  || bad "D2: the landed OFF must turn the marker row off: $(sql "SELECT kind, key, status FROM ledgers")"
[ -z "$(files_left)" ] && ok || bad "D2: the detector left record files: $(files_left)"

# D3 — the OFF self-heal reads the ROW: no flag file, the marker row still on.
lib 'mrs_published_set main-red-o-r on' || bad "D3: setup"
: > "$T/req.log"
detect
[ "$(reqs 'PUT /api/flags')" -ge 1 ] && ok || bad "D3: a marker row still on must republish OFF: $(cat "$T/req.log")"
[ "$(sql "SELECT status FROM ledgers WHERE kind='main_red_published' AND key='main-red-o-r'")" = off ] && ok \
  || bad "D3: and the row goes off once the OFF lands"

# D4 — an unreadable marker row does not act: no republish, one log line.
lib 'mrs_published_set main-red-o-r on' || bad "D4: setup"
touch "$T/outage-ledger"; : > "$T/req.log"
detect
[ "$(reqs 'PUT /api/flags')" = 0 ] && ok || bad "D4: an unreadable marker row must not republish: $(cat "$T/req.log")"
grep -q 'published marker row is unreadable' "$H/logs/main-red.log" && ok \
  || bad "D4: the log must say the marker was unreadable: $(tail -3 "$H/logs/main-red.log")"
rm -f "$T/outage-ledger"

# D5 — a leftover verdict file goes once the row lands; D6 — a marker row that
# cannot be written falls back to the file, and the file alone still says ON.
reset_case
mkdir -p "$H/state/main-red"
printf 'decision=none\nreason=old\nsha=\nat=2026-09-22 12:40:00Z\n' > "$H/state/main-red/o-r.verdict"
mainruns "Harness CI|$CI|failure|2026-09-22T11:00:00Z|f1f1f1f1"
touch "$T/outage-put-ledger"
detect
[ ! -e "$H/state/main-red/o-r.verdict" ] && ok || bad "D5: a landed verdict row must remove the leftover file"
[ -f "$H/state/main-red/main-red-o-r.published" ] && ok \
  || bad "D6: a marker row that cannot be written must leave the file: $(files_left)"
grep -q 'published marker row not written' "$H/logs/main-red.log" && ok || bad "D6: and say so in the log"
rm -f "$T/outage-put-ledger" "$H/flags/main-red-o-r"
mainruns "Harness CI|$CI|success|2026-09-22T12:00:00Z|a2a2a2a2" "Harness CI|$CI|failure|2026-09-22T11:00:00Z|f1f1f1f1"
: > "$T/req.log"
detect
[ "$(reqs 'PUT /api/flags')" -ge 1 ] && ok || bad "D6: the fallback file alone must still republish OFF: $(cat "$T/req.log")"
[ -z "$(files_left)" ] && ok || bad "D6: the landed OFF row must remove the file: $(files_left)"

# ── P: the PR-pair lane ──────────────────────────────────────────────────────
reset_case
put_verdict none no-required
pair_fixture
pair
[ -f "$H/flags/main-red-o-r" ] && ok || bad "P1: a pair against a verdict row none must freeze: $(tail -3 "$H/logs/main-red-pr-pair.log")"
[ "$(sql "SELECT COUNT(*) FROM main_red_pairs WHERE repo='o/r' AND resolved_at IS NULL")" = 1 ] && ok \
  || bad "P1: the pair must be an open row: $(sql "SELECT * FROM main_red_pairs")"
[ "$(sql "SELECT job FROM main_red_pairs")" = "Test determinism lint" ] && ok || bad "P1: the pair row carries the job"
[ "$(sql "SELECT COUNT(*) FROM main_red_pr_errors WHERE repo='o/r'")" = 2 ] && ok \
  || bad "P1: both heads must be pr_errors rows: $(sql "SELECT head, error FROM main_red_pr_errors")"
[ "$(sql "SELECT status FROM ledgers WHERE kind='main_red_published' AND key='main-red-o-r'")" = on ] && ok \
  || bad "P1: the freeze's published marker must be the ledger row"
[ "$(grep -c -- '--severity critical' "$T/alerts.log" 2>/dev/null)" = 1 ] && ok || bad "P1: one critical alert: $(cat "$T/alerts.log" 2>/dev/null)"
[ -z "$(files_left)" ] && ok || bad "P1: the PR-pair lane left record files: $(files_left)"

# P2 — the same pair next tick: no second send, no second row, no GitHub reads for known heads.
: > "$T/gh.log"; : > "$T/alerts.log"
pair
[ ! -s "$T/alerts.log" ] && ok || bad "P2: an open pair row must stop a second send: $(cat "$T/alerts.log")"
[ "$(sql "SELECT COUNT(*) FROM main_red_pairs")" = 1 ] && ok || bad "P2: still one pair row"
grep -q "head_sha=$HA" "$T/gh.log" && bad "P2: a head with a row must not be read again: $(cat "$T/gh.log")" || ok

# P3 — a complete look with no pair: resolve stamps, keeps, and lifts the freeze.
green_fixture
pair
[ "$(sql "SELECT COUNT(*) FROM main_red_pairs WHERE resolved_at IS NOT NULL")" = 1 ] && ok \
  || bad "P3: the resolve must stamp resolved_at: $(sql "SELECT * FROM main_red_pairs")"
[ "$(sql "SELECT COUNT(*) FROM main_red_pairs")" = 1 ] && ok || bad "P3: a resolve never deletes"
grep -q -- '--resolve --id main-red-prs:o-r:' "$T/alerts.log" && ok || bad "P3: one resolve send: $(cat "$T/alerts.log")"
[ ! -f "$H/flags/main-red-o-r" ] && ok || bad "P3: the freeze this lane raised must come down"
[ -z "$(files_left)" ] && ok || bad "P3: the PR-pair lane left record files: $(files_left)"

# P4 — an unreadable verdict row is not a decision: the pair alerts, nothing freezes.
reset_case
put_verdict none no-required
pair_fixture
touch "$T/outage-verdict"
pair
[ ! -f "$H/flags/main-red-o-r" ] && ok || bad "P4: an unreadable verdict must not freeze"
[ "$(grep -c -- '--severity critical' "$T/alerts.log" 2>/dev/null)" = 1 ] && ok || bad "P4: the pair still alerts: $(cat "$T/alerts.log" 2>/dev/null)"
grep -q 'verdict row is unreadable' "$H/logs/main-red-pr-pair.log" && ok \
  || bad "P4: the log must say the verdict was unreadable: $(tail -3 "$H/logs/main-red-pr-pair.log")"

# P8 — no verdict row (the detector never looked): no freeze.
reset_case
pair_fixture
pair
[ ! -f "$H/flags/main-red-o-r" ] && ok || bad "P8: no verdict row must not freeze"
grep -q 'no verdict row' "$H/logs/main-red-pr-pair.log" && ok || bad "P8: the log names the missing verdict row: $(tail -3 "$H/logs/main-red-pr-pair.log")"

# P7 — the pr_errors read fails: do not act (no GitHub reads, no alert, no row).
reset_case
put_verdict none no-required
pair_fixture
touch "$T/outage-pr-errors"
pair
[ ! -s "$T/alerts.log" ] && ok || bad "P7: an unreadable pr_errors read must send nothing: $(cat "$T/alerts.log")"
grep -q "head_sha=" "$T/gh.log" 2>/dev/null && bad "P7: and must read no head runs: $(cat "$T/gh.log")" || ok
[ ! -f "$H/flags/main-red-o-r" ] && ok || bad "P7: and must not freeze"

# P6 — a '##[' row in the table is asked again, and the guarded UPDATE replaces it.
reset_case
put_verdict green green
pair_fixture
sqlx "INSERT INTO main_red_pr_errors (repo, head, job, error, run_at, at) VALUES ('o/r','$HA','Test determinism lint','##[group]Run FAIL=0','2026-09-22T12:30:00Z','2026-09-22T12:40:00Z')"
pair
[ "$(sql "SELECT error FROM main_red_pr_errors WHERE head='$HA'")" = "$ERRTEXT" ] && ok \
  || bad "P6: the stale row must be replaced: $(sql "SELECT error FROM main_red_pr_errors WHERE head='$HA'")"

# P9 — the files from before the rows: a pair marker is opened as its row and
# removed (so the still-firing pair sends nothing new), the head ledger dir goes.
reset_case
put_verdict green green
pair_fixture
HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha1(("%s|%s" % (sys.argv[1], sys.argv[2])).encode()).hexdigest()[:12])' "Test determinism lint" "$ERRTEXT")
mkdir -p "$H/state/main-red/pairs/o-r" "$H/state/main-red/pr-errors/o-r"
printf 'job=Test determinism lint\nfirst_error=%s\nprs=#1, #2\ndetected=2026-09-22 12:40:00Z\n' "$ERRTEXT" > "$H/state/main-red/pairs/o-r/$HASH"
printf 'lint\tFAIL: old\t2026-09-01T00:00:00Z\n' > "$H/state/main-red/pr-errors/o-r/$HC.tsv"
pair
[ "$(sql "SELECT hash, job FROM main_red_pairs WHERE resolved_at IS NULL")" = "$(printf '%s\tTest determinism lint' "$HASH")" ] && ok \
  || bad "P9: the leftover marker must become the open row: $(sql "SELECT * FROM main_red_pairs")"
[ ! -s "$T/alerts.log" ] && ok || bad "P9: an imported open pair must not send again: $(cat "$T/alerts.log")"
[ -z "$(files_left)" ] && ok || bad "P9: the leftover files must be gone: $(files_left)"

# P10 — a head file from before the rows becomes its row before it goes: that
# head is not read from GitHub again (its run logs may have expired).
reset_case
put_verdict green green
pair_fixture
mkdir -p "$H/state/main-red/pr-errors/o-r"
printf '%s\t%s\t%s\n' "Test determinism lint" "$ERRTEXT" "2026-09-22T12:30:35Z" > "$H/state/main-red/pr-errors/o-r/$HB.tsv"
pair
[ "$(sql "SELECT job, error, run_at FROM main_red_pr_errors WHERE head='$HB'")" = "$(printf 'Test determinism lint\t%s\t2026-09-22T12:30:35Z' "$ERRTEXT")" ] && ok \
  || bad "P10: the legacy head file must become its row: $(sql "SELECT * FROM main_red_pr_errors")"
grep -q "head_sha=$HB" "$T/gh.log" && bad "P10: an imported head must not be read from GitHub again: $(cat "$T/gh.log")" || ok
[ "$(sql "SELECT COUNT(*) FROM main_red_pairs WHERE resolved_at IS NULL")" = 1 ] && ok \
  || bad "P10: the imported head still pairs with the fresh one: $(sql "SELECT * FROM main_red_pairs")"
[ -z "$(files_left)" ] && ok || bad "P10: the imported file must be gone: $(files_left)"
# P10b — a PUT that fails keeps the file for the next tick.
reset_case
put_verdict green green
pair_fixture
mkdir -p "$H/state/main-red/pr-errors/o-r"
printf '%s\t%s\t%s\n' "Test determinism lint" "$ERRTEXT" "2026-09-22T12:30:35Z" > "$H/state/main-red/pr-errors/o-r/$HB.tsv"
touch "$T/outage-put-pr-errors"
pair
[ -f "$H/state/main-red/pr-errors/o-r/$HB.tsv" ] && ok || bad "P10b: a failed import must keep the file: $(files_left)"

# P5 — a worker without the new routes: today's files decide, and are written.
reset_case
touch "$T/absent"
pair_fixture
mkdir -p "$H/state/main-red"
printf 'decision=none\nreason=no-required\nsha=\nat=2026-09-22 12:40:00Z\n' > "$H/state/main-red/o-r.verdict"
pair
[ -f "$H/flags/main-red-o-r" ] && ok || bad "P5: an undeployed route must fall back to the verdict file: $(tail -3 "$H/logs/main-red-pr-pair.log")"
[ -n "$(ls -A "$H/state/main-red/pairs/o-r" 2>/dev/null)" ] && ok || bad "P5: and to the pair marker files"
[ "$(sql "SELECT COUNT(*) FROM main_red_pairs")" = 0 ] && ok || bad "P5: no row is written through an absent route"
reset_case
touch "$T/absent"
pair_fixture
pair
[ ! -f "$H/flags/main-red-o-r" ] && ok || bad "P5: an undeployed route with no verdict file must not freeze"

# ── R: the recheck lane ──────────────────────────────────────────────────────
reset_case
mainruns "Harness CI|$CI|failure|2026-09-22T11:00:00Z|f1f1f1f1"
printf 'sha=f1f1f1f1\nworkflow=Harness CI\nreason=tip\n' > "$H/flags/main-red-o-r"
recheck
[ -n "$(sql "SELECT status FROM ledgers WHERE kind='main_red_recheck' AND key='last'")" ] && ok \
  || bad "R1: the recheck stamp must be a ledger row: $(sql "SELECT kind, key, status FROM ledgers")"
[ -z "$(files_left)" ] && ok || bad "R1: the recheck lane left record files: $(files_left)"
N1=$(grep -c ' recheck: [0-9]' "$H/logs/main-red.log" 2>/dev/null || true)
[ "${N1:-0}" -ge 1 ] && ok || bad "R1: the detector must have run --flagged-only: $(tail -3 "$H/logs/main-red.log")"
recheck
N2=$(grep -c ' recheck: [0-9]' "$H/logs/main-red.log" 2>/dev/null || true)
[ "$N2" = "$N1" ] && ok || bad "R2: a fresh stamp row must stop the next run ($N1 -> $N2)"
lib 'mrs_recheck_set 1000' || bad "R3: setup"
touch "$T/outage-ledger"
recheck
N3=$(grep -c ' recheck: [0-9]' "$H/logs/main-red.log" 2>/dev/null || true)
[ "$N3" = "$N2" ] && ok || bad "R3: an unreadable stamp row must start no detector ($N2 -> $N3)"
grep -q 'recheck stamp row is unreadable' "$H/logs/main-red.log" && ok \
  || bad "R3: the log must say why: $(tail -3 "$H/logs/main-red.log")"
rm -f "$T/outage-ledger"
# R4 — a stamp row that cannot be written still runs the check, writes no
# file, and says so; a leftover file is not read while the row answers.
lib 'mrs_recheck_set 1000' || bad "R4: setup"
mkdir -p "$H/state/main-red"; echo 9999999999 > "$H/state/main-red/recheck.last"
touch "$T/outage-put-ledger"
recheck
N4=$(grep -c ' recheck: [0-9]' "$H/logs/main-red.log" 2>/dev/null || true)
[ "$N4" -gt "$N3" ] && ok || bad "R4: an old stamp row must run the check whatever the leftover file says ($N3 -> $N4)"
grep -q 'recheck stamp row was not written' "$H/logs/main-red.log" && ok || bad "R4: the failed stamp write must be logged"
rm -f "$T/outage-put-ledger"

done_
