#!/bin/bash
# tests/needs-sweep.bh-9117-test.sh — BH-9117: the daily NEEDS sweep,
# bin/needs-sweep.sh, driven over real curl against one local server
# (tests/lib/needs-sweep-world.bh-9117.mjs) that hosts the REAL Pages endpoint
# console-ui/functions/api/needs-sweep/[[path]].js on a seeded console D1 and
# the REAL jobs worker (settings rows from this PR's seed, the ledger). GitHub
# is a `gh` stub in the `gh api -i` shape gh_rest reads. No call leaves the box.
#
#   U   ns_decide, cases (a)-(o) of the plan, through NS_LIB_ONLY=1
#   S1  dry by default (the seed): every case decided, nothing changed,
#       apply:false bodies, ONE ledger row `dry`, would= from the endpoint
#   S2  console.needs.sweep_dry_run=0: rows move, nothing is deleted,
#       commands expire, ONE ledger row `applied`, a re-run changes nothing
#   S3  --dry-run overrides a 0 row
#   S4  console.needs.max_age_days=30 moves fewer rows than the fallback 14;
#       no settings rows -> fallbacks and DRY; a dead jobs worker -> DRY
#   S5  250 decisions -> 3 apply POSTs (chunks of 100), commands_before on the last
#       and the page-size, apply-chunk and http-timeout settings rows
#   S6  fail-closed reads (500, no rows, a cursor that does not advance): rc 3,
#       no apply POST, ledger `failed`, ONE ALERTS line per failing run
#   S7  an apply refused: rc 0, ledger `partial`, ONE needs-sweep-apply alert
#   S8  changed= is the endpoint's answer, not the decided count
#   S9  no HARNESS_SECRET: rc 0, not-configured, no request
#   S10 GitHub read cap and row cap: INCOMPLETE, rc 0
#   S11 the lane's off flag: no request
#   S13 the settle window: a PR closed 10 s ago is kept (pr_unsettled), one
#       closed a day ago is pr_closed; with no settle.sh every closure is kept
#   S12 sources exist; the three node suites run when console-ui deps exist
#
# Run from anywhere: tests/needs-sweep.bh-9117-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The jobs worker imports the git-ignored catalogs (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/needs-sweep-world.bh-9117.mjs"
SCRIPT_REL=bin/needs-sweep.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

# --- S12 sources --------------------------------------------------------------
for f in "$DIR/bin/needs-sweep.sh" "$DIR/console-ui/functions/api/needs-sweep/[[path]].js" "$SRV" \
         "$DIR/catalog/lanes.d/needs-sweep.json" "$DIR/cron/lanes/779-needs-sweep.cron" \
         "$DIR/worker/jobs/schema.d/202611091634-bh-9117-needs-sweep-settings.sql" \
         "$DIR/console-ui/tests/needs-count.bh-9117.test.js" "$DIR/console-ui/tests/needs-sweep.bh-9117.test.js" \
         "$DIR/console-ui/tests/now-needs-split.bh-9117.test.js"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
grep -q '^35 5 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/needs-sweep.sh ' "$DIR/cron/lanes/779-needs-sweep.cron" \
  && ok "S12 cron: daily 05:35 behind the hub lease" || bad "S12 cron line"
[ "$(jq -r '.script + " " + .switch.name' "$DIR/catalog/lanes.d/needs-sweep.json")" = "bin/needs-sweep.sh lane-off-needs-sweep" ] \
  && ok "S12 lane row" || bad "S12 lane row"

# --- U: the decision rule -----------------------------------------------------
NOW=$(date -u -d 2026-11-05T22:00:00Z +%s)
iso_ago() { date -u -d "@$((NOW - $1 * 86400))" +%FT%TZ; }
(
  NS_LIB_ONLY=1 . "$DIR/$SCRIPT_REL" || { echo "  FAIL U source"; exit 1; }
  d() { ns_decide "$@" "$NOW" 14; }
  f=0
  chk() { [ "$1" = "$2" ] && echo "  ok   U $3" || { echo "  FAIL U $3: got '$1' want '$2'"; f=1; }; }
  chk "$(d 10 12 "$(iso_ago 1)" none open)" "superseded newer_row" "(a) a newer row of the same ticket"
  chk "$(d 20 20 2026-07-22T10:00:00Z none open)" "stale aged" "(b) older than the window"
  chk "$(d 30 30 "$(iso_ago 1)" merged na)" "pr_merged pr_merged" "(c) PR merged"
  chk "$(d 40 40 "$(iso_ago 1)" closed_unmerged na)" "pr_closed pr_closed" "(d) PR closed unmerged"
  chk "$(d 50 50 "$(iso_ago 1)" none closed)" "stale issue_closed" "(e) young, issue closed"
  chk "$(d 41 41 "$(iso_ago 1)" unsettled na)" "keep pr_unsettled" "(d2) PR closed inside the settle window"
  chk "$(d 60 60 "$(iso_ago 60)" open na)" "keep pr_open" "(f) an open PR is never aged out"
  chk "$(d 70 70 "$(iso_ago 60)" unknown na)" "keep pr_unknown" "(g) PR read unknown/capped"
  chk "$(d 80 "" "$(iso_ago 1)" none na)" "keep live" "(h)/(i) no newer row in the same project, or no key"
  chk "$(d 100 100 2026-11-04T10:00:00.123Z none na)" "keep live" "(k) a fraction, 1 day old"
  chk "$(d 101 101 garbage merged na)" "keep undated" "(k) garbage updated_at"
  chk "$(d 102 102 "$((NOW - 30 * 86400))" none na)" "stale aged" "(k) epoch seconds, 30 days old"
  chk "$(d 110 110 "$(iso_ago 1)" none unknown)" "keep ticket_unknown" "(m) issue read failed"
  chk "$(d 9 9 "$(iso_ago 15)" none open)" "stale aged" "15 days > 14"
  chk "$(d 9 9 "$(iso_ago 13)" none open)" "keep live" "13 days < 14"
  ns_epoch 2026-11-05T10:00:00.5Z >/dev/null && [ "$(ns_epoch 2026-11-05T10:00:00.5Z)" = "$(ns_epoch 2026-11-05T10:00:00Z)" ] \
    && echo "  ok   U fraction is UTC" || { echo "  FAIL U fraction"; f=1; }
  exit "$f"
) && ok "U decision cases" || bad "U decision cases"

# --- the scratch harness ------------------------------------------------------
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/fakebin"
for L in "$SCRIPT_REL" bin/builds-merged-sweep.sh bin/jobs-client.sh bin/alert-line.sh bin/fleet-conf.sh bin/lib/tracker.sh \
         bin/lib/tracker/github-issues.sh bin/lib/tracker/board.sh bin/lib/gh-rest.sh bin/lib/console-pages.sh bin/lib/lane-gate.sh bin/lib/mc/settle.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf 'demo-gh o/gh https://gh.example - 1 hub\ndemo-board o/board https://board.example /api/board 2 hub\n' > "$H/fleet.conf"
# The gh stub: `gh api -i -X GET <path>` answers $T/gh/<path, / as _>.{status,json};
# no status file is a 404, a status of `net` prints nothing (gh_rest rc 75).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
p=""
for a; do case "\$a" in repos/*) p="\$a" ;; esac; done
k=\$(printf '%s' "\$p" | tr '/' '_')
st=\$(cat "$T/gh/\$k.status" 2>/dev/null || echo 404)
[ "\$st" = net ] && exit 1
printf 'HTTP/2.0 %s\r\n\r\n' "\$st"
[ -f "$T/gh/\$k.json" ] && cat "$T/gh/\$k.json" || printf '{"message":"Not Found"}'
[ "\$st" = 200 ]
EOF
chmod +x "$T/fakebin/gh"
mkdir -p "$T/gh"
ghfix() { printf '%s\n' "$2" > "$T/gh/$1.status"; [ -n "${3:-}" ] && printf '%s\n' "$3" > "$T/gh/$1.json"; return 0; }
ghfix repos_o_r_pulls_30 200 '{"state":"closed","merged":true,"merged_at":"2026-11-01T10:00:00Z"}'
ghfix repos_o_r_pulls_40 200 '{"state":"closed","merged":false,"merged_at":null}'
# 42 closed 10 s before the clock (a CI kick can reopen it); 43 closed a day ago.
ghfix repos_o_r_pulls_42 200 "{\"state\":\"closed\",\"merged\":false,\"merged_at\":null,\"closed_at\":\"$(date -u -d "@$((NOW - 10))" +%FT%TZ)\"}"
ghfix repos_o_r_pulls_43 200 "{\"state\":\"closed\",\"merged\":false,\"merged_at\":null,\"closed_at\":\"$(iso_ago 1)\"}"
ghfix repos_o_r_pulls_60 200 '{"state":"open","merged":false,"merged_at":null}'
ghfix repos_o_r_pulls_71 net
ghfix repos_o_r_pulls_72 200 '{"state":"closed","merged":true,"merged_at":null}'
ghfix repos_o_gh_issues_5 200 '{"number":5,"state":"closed"}'
ghfix repos_o_gh_issues_6 200 '{"number":6,"state":"open"}'
ghfix repos_o_gh_issues_11 500 '{"message":"boom"}'

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" PATH="$T/fakebin:$PATH"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=fixture-gh-token
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 NS_NOW="$NOW" BOX_NAME=hub
export LANE_GATE_DISABLE=1 GH_ETAG=0
unset CONSOLE_URL MC_CLOSED_SETTLE

# The seed: one row per decision case, plus 510 young board rows so the
# candidates come in two pages, and row 2000 (aged) on page 2 (o).
seed_main() {
  local f="$T/seed-main.sql" i
  {
    echo "INSERT INTO builds (id,bkey,project,ticket_key,stage,pr_url,merged,updated_at) VALUES"
    echo " (10,'k10','demo-board','TK-1','plan_blocked','',0,'$(iso_ago 1)'),"
    echo " (12,'k12','demo-board','TK-1','plan_deferred','',0,'$(iso_ago 1)'),"
    echo " (20,'k20','demo-board','TK-2','plan_deferred','',0,'2026-07-22T10:00:00Z'),"
    echo " (30,'k30','demo-board','TK-3','pr_created','https://github.com/o/r/pull/30',0,'$(iso_ago 1)'),"
    echo " (40,'k40','demo-board','TK-4','pr_created','https://github.com/o/r/pull/40',0,'$(iso_ago 1)'),"
    echo " (42,'k42','demo-board','TK-42','pr_created','https://github.com/o/r/pull/42',0,'$(iso_ago 1)'),"
    echo " (43,'k43','demo-board','TK-43','pr_created','https://github.com/o/r/pull/43',0,'$(iso_ago 1)'),"
    echo " (50,'k50','demo-gh','GH-5','plan_blocked','',0,'$(iso_ago 1)'),"
    echo " (51,'k51','demo-gh','GH-6','plan_blocked','',0,'$(iso_ago 1)'),"
    echo " (60,'k60','demo-board','TK-6','pr_created','https://github.com/o/r/pull/60',0,'$(iso_ago 60)'),"
    echo " (70,'k70','demo-board','TK-7','pr_created','https://github.com/o/r/pull/70',0,'$(iso_ago 60)'),"
    echo " (71,'k71','demo-board','TK-71','pr_created','https://github.com/o/r/pull/71',0,'$(iso_ago 60)'),"
    echo " (72,'k72','demo-board','TK-72','pr_created','https://github.com/o/r/pull/72',0,'$(iso_ago 60)'),"
    echo " (80,'k80','demo-board','TK-8','plan_blocked','',0,'$(iso_ago 1)'),"
    echo " (81,'k81','demo-gh','TK-8','executing','',0,'$(iso_ago 1)'),"
    echo " (90,'k90','demo-board','','plan_blocked','',0,'$(iso_ago 1)'),"
    echo " (91,'k91','demo-board','','plan_blocked','',0,'$(iso_ago 1)'),"
    echo " (100,'k100','demo-board','TK-10','plan_stale','',0,'2026-11-04T10:00:00.123Z'),"
    echo " (101,'k101','demo-board','TK-11','plan_stale','',0,'garbage'),"
    echo " (102,'k102','demo-board','TK-12','plan_malformed','',0,'$((NOW - 30 * 86400))'),"
    echo " (110,'k110','demo-gh','GH-11','plan_blocked','',0,'$(iso_ago 1)'),"
    echo " (120,'k120','demo-board','TK-20','plan_blocked','https://github.com/o/r/issues/5',0,'$(iso_ago 40)'),"
    echo " (130,'k130','demo-board','TK-30','plan_deferred','',0,'$(iso_ago 20)'),"
    echo " (140,'k140','demo-board','TK-40','executing','',0,'$(iso_ago 90)'),"
    echo " (141,'k141','demo-board','TK-41','plan_blocked','',1,'$(iso_ago 90)'),"
    for i in $(seq 1000 1509); do echo " ($i,'k$i','demo-board','FL-$i','plan_blocked','',0,'$(iso_ago 1)'),"; done
    echo " (2000,'k2000','demo-board','TK-2000','plan_deferred','',0,'$(iso_ago 50)');"
    echo "INSERT INTO commands (id,ckey,type,project,status,created_at,updated_at) VALUES"
    echo " (1,'c1','run_triage','demo-gh','dead_letter','$(iso_ago 20)','$(iso_ago 20)'),"
    echo " (2,'c2','run_triage','demo-gh','dead_letter','$(iso_ago 2)','$(iso_ago 2)'),"
    echo " (3,'c3','run_triage','demo-gh','failed','$(iso_ago 20)','$(iso_ago 20)');"
  } > "$f"
  printf '%s' "$f"
}
seed_many() { # seed_many <n> — n aged board rows with no PR
  local f="$T/seed-many.sql" i
  { echo "INSERT INTO builds (id,bkey,project,ticket_key,stage,pr_url,merged,updated_at) VALUES"
    for i in $(seq 1 "$1"); do printf " (%s,'k%s','demo-board','TK-%s','plan_blocked','',0,'%s')%s\n" "$i" "$i" "$i" "$(iso_ago 30)" \
      "$([ "$i" = "$1" ] && echo ';' || echo ',')"; done; } > "$f"
  printf '%s' "$f"
}

PIDS=()
srv() { # srv <name> <seed.sql>
  local n="$1"
  : > "$T/$n.log"; : > "$T/$n.port"; : > "$T/$n.bodies"
  node "$SRV" "$T/$n.log" "$2" "$T/$n.bodies" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$PORT" CONSOLE_PAGES_URL="http://127.0.0.1:$PORT"
  W="$n"
  # The tracker kinds: tracker_adapter.<project> settings rows.
  jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES
    ('tracker_adapter.demo-gh','github-issues','t','test','2026-11-05T00:00:00Z'),
    ('tracker_adapter.demo-board','board','t','test','2026-11-05T00:00:00Z')"
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
jsql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
jget() { curl -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
cget() { curl -sS -X POST "$JOBS_URL/__cget" --data-binary "$1"; }
mode() { curl -sS -X POST "$JOBS_URL/__mode" --data-binary "$1" >/dev/null; }
stage_of() { cget "SELECT stage || ':' || merged AS s FROM builds WHERE id = $1" | jq -r '.[0].s'; }
setk() { jsql "UPDATE settings SET value='$2' WHERE key='$1'"; }
RESET() { : > "$H/logs/ALERTS.log"; : > "$H/logs/needs-sweep.log"; : > "$T/gh-calls.txt"; scratch_rm "$H/state/alerts"; scratch_rm "$H/state/alert-line-sent"; }
# Each run is one second later, so each run has its own ledger key run:<stamp>.
RUNSEQ=0
run() { RUNSEQ=$((RUNSEQ+1)); NS_NOW=$((NOW + RUNSEQ)) "$H/$SCRIPT_REL" "$@" > "$T/run.out" 2>&1; RC=$?; }
summary() { grep ' summary ' "$H/logs/needs-sweep.log" | tail -1; }
ledger_rows() { jget "SELECT status, detail FROM ledgers WHERE kind='needs_sweep' ORDER BY rowid"; }
posts() { grep -c '^POST /api/needs-sweep/apply' "$T/$W.log"; }

srv main "$(seed_main)"; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: server did not start: $(cat "$T/main.err")"; exit 1; }
[ "$(jget "SELECT value FROM settings WHERE key='console.needs.sweep_dry_run'" | jq -r '.[0].value')" = 1 ] \
  && ok "seed: console.needs.sweep_dry_run is 1 in the composed jobs schema" || bad "seed row missing"
[ "$(jget "SELECT COUNT(*) n FROM settings WHERE key LIKE 'console.needs.%'" | jq -r '.[0].n')" = 7 ] \
  && ok "seed: the seven console.needs.* rows" || bad "seed rows: $(jget "SELECT key FROM settings WHERE key LIKE 'console.needs.%'")"

# --- S1: dry by default -------------------------------------------------------
RESET; run
L="$H/logs/needs-sweep.log"
[ "$RC" = 0 ] && ok "S1 rc 0" || bad "S1 rc $RC: $(cat "$T/run.out")"
for want in "dry 10 demo-board TK-1 plan_blocked -> superseded (newer_row)" \
            "dry 20 demo-board TK-2 plan_deferred -> stale (aged)" \
            "dry 30 demo-board TK-3 pr_created -> pr_merged (pr_merged)" \
            "dry 40 demo-board TK-4 pr_created -> pr_closed (pr_closed)" \
            "dry 43 demo-board TK-43 pr_created -> pr_closed (pr_closed)" \
            "dry 50 demo-gh GH-5 plan_blocked -> stale (issue_closed)" \
            "dry 102 demo-board TK-12 plan_malformed -> stale (aged)" \
            "dry 120 demo-board TK-20 plan_blocked -> stale (aged)" \
            "dry 130 demo-board TK-30 plan_deferred -> stale (aged)" \
            "dry 2000 demo-board TK-2000 plan_deferred -> stale (aged)"; do
  grep -qF " $want" "$L" && ok "S1 $want" || bad "S1 missing '$want'"
done
for id in 12 42 51 60 70 71 72 80 90 91 100 101 110 140 141 1000; do
  grep -qE " dry $id " "$L" && bad "S1 row $id must be kept: $(grep -E " dry $id " "$L")" || ok "S1 keeps $id"
done
SUM=$(summary)
grep -qF "mode=dry candidates=533 superseded=1 stale_aged=5 stale_issue_closed=1 pr_merged=1 pr_closed=2 kept=523 would=10 commands=1 reads=" <<<"$SUM" \
  && ok "S1 summary from the endpoint's would-counts" || bad "S1 summary: $SUM"
grep -q INCOMPLETE <<<"$SUM" && bad "S1 must be complete: $SUM" || ok "S1 complete"
[ "$(stage_of 10)" = "plan_blocked:0" ] && [ "$(stage_of 30)" = "pr_created:0" ] && ok "S1 nothing changed" || bad "S1 a row changed on a dry run"
[ "$(cget "SELECT status FROM commands WHERE id=1" | jq -r '.[0].status')" = dead_letter ] && ok "S1 no command expired" || bad "S1 command expired"
[ "$(jq -s 'map(.apply) | unique' "$T/main.bodies" | jq -c .)" = "[false]" ] && ok "S1 apply bodies say apply:false" || bad "S1 bodies: $(head -c 300 "$T/main.bodies")"
jq -e -s '.[0].builds[] | select(.id == 10) | .to == "superseded" and .updated_at != null and .why == "newer_row"' "$T/main.bodies" >/dev/null \
  && ok "S1 body fields id,to,updated_at,why" || bad "S1 body shape"
LR=$(ledger_rows)
[ "$(jq 'length' <<<"$LR")" = 1 ] && [ "$(jq -r '.[0].status' <<<"$LR")" = dry ] && ok "S1 one ledger row, dry" || bad "S1 ledger: $LR"
[ "$(jq -r '.[0].detail' <<<"$LR")" = "${SUM#*summary }" ] && ok "S1 ledger detail = summary" || bad "S1 ledger detail: $LR"
[ "$(grep -c '^GET /api/needs-sweep/candidates' "$T/main.log")" = 2 ] && ok "S1 (o) candidates read in 2 pages" || bad "S1 pages: $(grep candidates "$T/main.log")"
grep -q 'pulls/30' "$T/gh-calls.txt" && grep -q 'repos/o/gh/issues/5' "$T/gh-calls.txt" && ok "S1 reads the repo: pulls and issues" || bad "S1 gh calls: $(cat "$T/gh-calls.txt")"
grep -q 'board' "$T/gh-calls.txt" && bad "S1 (l) a board project got a GitHub issue read" || ok "S1 (l) no tracker read for a board project"
[ "$(grep -c 'pulls/30' "$T/gh-calls.txt")" = 1 ] && ok "S1 reads are deduped" || bad "S1 dedupe"
[ ! -s "$H/logs/ALERTS.log" ] && ok "S1 no alert" || bad "S1 alerted: $(cat "$H/logs/ALERTS.log")"
# Every GitHub read went through the gh stub, and the summary counts them.
NREADS=$(sed -n 's/.* reads=\([0-9]*\).*/\1/p' <<<"$SUM")
[ -n "$NREADS" ] && [ "$NREADS" -gt 0 ] && [ "$(grep -c . "$T/gh-calls.txt")" = "$NREADS" ] \
  && ok "S1 reads=$NREADS, all through the gh stub" || bad "S1 reads=$NREADS vs stub calls $(grep -c . "$T/gh-calls.txt")"

# --- S2: apply ----------------------------------------------------------------
BEFORE=$(cget "SELECT COUNT(*) n FROM builds" | jq -r '.[0].n')
setk console.needs.sweep_dry_run 0
RESET; : > "$T/main.bodies"; run
[ "$RC" = 0 ] && ok "S2 rc 0" || bad "S2 rc $RC"
for pair in 10:superseded:0 20:stale:0 30:pr_merged:1 40:pr_closed:0 42:pr_created:0 43:pr_closed:0 50:stale:0 102:stale:0 120:stale:0 130:stale:0 2000:stale:0 \
            12:plan_deferred:0 60:pr_created:0 80:plan_blocked:0 101:plan_stale:0 140:executing:0 141:plan_blocked:1; do
  id=${pair%%:*}; want=${pair#*:}
  [ "$(stage_of "$id")" = "$want" ] && ok "S2 row $id -> $want" || bad "S2 row $id is $(stage_of "$id"), want $want"
done
[ "$(cget "SELECT COUNT(*) n FROM builds" | jq -r '.[0].n')" = "$BEFORE" ] && ok "S2 no row deleted" || bad "S2 rows deleted"
[ "$(cget "SELECT group_concat(id || ':' || status) s FROM (SELECT * FROM commands ORDER BY id)" | jq -r '.[0].s')" = "1:expired,2:dead_letter,3:failed" ] \
  && ok "S2 the old dead_letter command expired, the others stay" || bad "S2 commands: $(cget 'SELECT id, status FROM commands')"
grep -qF "mode=apply candidates=533 superseded=1 stale_aged=5 stale_issue_closed=1 pr_merged=1 pr_closed=2 kept=523 changed=10 commands=1 " <<<"$(summary)" \
  && ok "S2 summary changed=10 commands=1" || bad "S2 summary: $(summary)"
grep -qF " apply 10 demo-board TK-1 plan_blocked -> superseded (newer_row)" "$L" && ok "S2 per-row apply line" || bad "S2 log"
LR=$(ledger_rows)
[ "$(jq 'length' <<<"$LR")" = 2 ] && [ "$(jq -r '.[1].status' <<<"$LR")" = applied ] && ok "S2 one more ledger row, applied" || bad "S2 ledger: $LR"
RESET; run
grep -qF " changed=0 commands=0 " <<<"$(summary)" && ok "S2 a re-run changes nothing" || bad "S2 re-run: $(summary)"

# --- S3: --dry-run wins over a 0 row ------------------------------------------
srv s3 "$(seed_main)"
setk console.needs.sweep_dry_run 0
RESET; run --dry-run
grep -q '^mode=dry ' <<<"$(summary | sed 's/.* summary //')" && [ "$(stage_of 20)" = "plan_deferred:0" ] \
  && ok "S3 --dry-run: dry, nothing changed" || bad "S3: $(summary) row20=$(stage_of 20)"
run --bogus
[ "$RC" = 2 ] && ok "S3 an unknown argument is rc 2" || bad "S3 bad arg rc $RC"

# --- S4: the window and the fallbacks -----------------------------------------
RESET; setk console.needs.max_age_days 30; run --dry-run
grep -qF " dry 130 " "$L" && bad "S4 a 20-day row must stay with a 30-day window" || ok "S4 window 30 keeps the 20-day row"
grep -qF " dry 2000 demo-board TK-2000 plan_deferred -> stale (aged)" "$L" && ok "S4 window 30 still moves the 50-day row" || bad "S4 50-day row"
jsql "DELETE FROM settings WHERE key LIKE 'console.needs.%'"
RESET; run
grep -qF " dry 130 demo-board TK-30 plan_deferred -> stale (aged)" "$L" && ok "S4 no row: fallback 14 days" || bad "S4 fallback window"
grep -q '^mode=dry ' <<<"$(summary | sed 's/.* summary //')" && [ "$(stage_of 130)" = "plan_deferred:0" ] && ok "S4 no row: fallback DRY" || bad "S4 fallback dry: $(summary)"
RESET; JOBS_URL="http://127.0.0.1:9" "$H/$SCRIPT_REL" >/dev/null 2>&1
grep -q '^mode=dry ' <<<"$(summary | sed 's/.* summary //')" && ok "S4 a dead jobs worker: DRY" || bad "S4 outage: $(summary)"
grep -q 'ledger needs_sweep run:.* not written' "$L" && ok "S4 a failed ledger put is one log line" || bad "S4 ledger line: $(cat "$L" | tail -3)"

# --- S5: chunks of 100 --------------------------------------------------------
srv s5 "$(seed_many 250)"
RESET; run
[ "$(posts)" = 3 ] && ok "S5 250 decisions -> 3 apply POSTs" || bad "S5 posts: $(posts)"
[ "$(jq -s -c 'map(.builds | length)' "$T/s5.bodies")" = "[100,100,50]" ] && ok "S5 100/100/50" || bad "S5 sizes: $(jq -s -c 'map(.builds|length)' "$T/s5.bodies")"
[ "$(jq -s -c 'map(.commands_before != null)' "$T/s5.bodies")" = "[false,false,true]" ] && ok "S5 commands_before on the last call only" || bad "S5 commands_before"
grep -qF "would=250 " <<<"$(summary)" && ok "S5 would=250" || bad "S5 summary: $(summary)"
grep -q 'candidates?after=0&limit=500 ' "$T/s5.log" && ok "S5 no row: page size fallback 500" || bad "S5 page size: $(grep candidates "$T/s5.log" | head -2)"
# The transport knobs: page size and apply chunk come from settings rows.
jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES
  ('console.needs.sweep_page_size','120','t','test','2026-11-09T00:00:00Z'),
  ('console.needs.sweep_apply_chunk','90','t','test','2026-11-09T00:00:00Z'),
  ('console.needs.sweep_http_timeout_s','0','t','test','2026-11-09T00:00:00Z')"
: > "$T/s5.log"; : > "$T/s5.bodies"; RESET; run
[ "$(jq -s -c 'map(.builds | length)' "$T/s5.bodies")" = "[90,90,70]" ] && ok "S5 apply chunk row 90: 90/90/70" || bad "S5 chunk knob: $(jq -s -c 'map(.builds|length)' "$T/s5.bodies")"
[ "$(grep -c 'candidates?after=[0-9]*&limit=120 ' "$T/s5.log")" = 3 ] && ok "S5 page size row 120: 3 pages" || bad "S5 page knob: $(grep candidates "$T/s5.log")"
grep -qF "would=250 " <<<"$(summary)" && ok "S5 http timeout row 0 falls back, the run still reads" || bad "S5 timeout 0: $(summary)"
jsql "DELETE FROM settings WHERE key IN ('console.needs.sweep_page_size','console.needs.sweep_apply_chunk','console.needs.sweep_http_timeout_s')"

# --- S6: fail closed ----------------------------------------------------------
RESET
for m in cand500 badjson samecursor; do
  mode "$m"; : > "$T/s5.bodies"; run
  [ "$RC" = 3 ] && ok "S6 $m: rc 3" || bad "S6 $m: rc $RC"
  [ ! -s "$T/s5.bodies" ] && ok "S6 $m: no apply POST" || bad "S6 $m: an apply was POSTed"
done
[ "$(grep -c 'candidates read failed' "$H/logs/ALERTS.log")" = 3 ] && [ "$(wc -l < "$H/logs/ALERTS.log")" = 3 ] \
  && ok "S6 one ALERTS line per failing run, no other" || bad "S6 alerts: $(cat "$H/logs/ALERTS.log")"
[ "$(ledger_rows | jq -r '[.[] | select(.status == "failed")] | length')" = 3 ] && ok "S6 ledger row failed per run" || bad "S6 ledger: $(ledger_rows)"
[ "$(stage_of 1)" = "plan_blocked:0" ] && ok "S6 nothing changed" || bad "S6 changed"

# --- S7: an apply refused -----------------------------------------------------
RESET; mode apply500; setk console.needs.sweep_dry_run 0; run
[ "$RC" = 0 ] && ok "S7 rc 0" || bad "S7 rc $RC"
[ "$(ledger_rows | jq -r '.[-1].status')" = partial ] && ok "S7 ledger partial" || bad "S7 ledger: $(ledger_rows | jq -c '.[-1]')"
[ "$(grep -c 'needs-sweep' "$H/logs/ALERTS.log")" = 1 ] && grep -q 'apply call' "$H/logs/ALERTS.log" && ok "S7 one apply alert" || bad "S7 alerts: $(cat "$H/logs/ALERTS.log")"
grep -qF " changed=0 " <<<"$(summary)" && ok "S7 changed=0 from refused calls" || bad "S7 summary: $(summary)"

# --- S8: changed= comes from the answer ---------------------------------------
srv s8 "$(seed_many 5)"; setk console.needs.sweep_dry_run 0
RESET; mode changed3; run
grep -qF "stale_aged=5 " <<<"$(summary)" && grep -qF " changed=3 " <<<"$(summary)" && ok "S8 5 decided, the endpoint said 3: changed=3" || bad "S8 summary: $(summary)"

# --- S9: not configured -------------------------------------------------------
RESET; : > "$T/s8.log"
( unset HARNESS_SECRET; "$H/$SCRIPT_REL" ) >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'not-configured (no HARNESS_SECRET)' "$L" && ok "S9 not-configured" || bad "S9 rc=$RC $(cat "$L")"
grep -q 'needs-sweep' "$T/s8.log" && bad "S9 a request was sent" || ok "S9 no request"
[ ! -s "$H/logs/ALERTS.log" ] && ok "S9 no alert" || bad "S9 alerted"

# --- S10: the caps ------------------------------------------------------------
srv s10 "$(seed_main)"
setk console.needs.sweep_max_reads 1
RESET; run
grep -q ' reads=1 INCOMPLETE' <<<"$(summary)" && [ "$RC" = 0 ] && ok "S10 read cap: reads=1 INCOMPLETE, rc 0" || bad "S10 read cap: rc=$RC $(summary)"
grep -qF " dry 40 " "$L" && bad "S10 a capped PR read must keep its row" || ok "S10 a capped PR read keeps the row"
setk console.needs.sweep_max_reads 300; setk console.needs.sweep_max_rows 2
RESET; run
grep -q 'would=2 .*INCOMPLETE' <<<"$(summary)" && [ "$(grep -c ' dry [0-9]* .* -> ' "$L")" = 2 ] && ok "S10 row cap: 2 decided, INCOMPLETE" || bad "S10 row cap: $(summary)"

# --- S11: the off flag --------------------------------------------------------
RESET; : > "$T/s10.log"; : > "$H/flags/lane-off-needs-sweep"
( unset LANE_GATE_DISABLE; "$H/$SCRIPT_REL" ) >/dev/null 2>&1
grep -q 'needs-sweep/' "$T/s10.log" && bad "S11 the lane ran with its off flag" || ok "S11 no request with the off flag"
rm -f "$H/flags/lane-off-needs-sweep"

# --- S13: the settle window -----------------------------------------------------
srv s13 "$(seed_main)"
RESET; run
grep -qF " dry 42 " "$L" && bad "S13 a closure 10 s old must be kept: $(grep -F ' dry 42 ' "$L")" || ok "S13 a closure 10 s old is kept"
grep -qF " dry 43 demo-board TK-43 pr_created -> pr_closed (pr_closed)" "$L" && ok "S13 a closure 1 day old is pr_closed" || bad "S13 row 43"
RESET; MC_CLOSED_SETTLE=5 run
grep -qF " dry 42 demo-board TK-42 pr_created -> pr_closed (pr_closed)" "$L" && ok "S13 MC_CLOSED_SETTLE=5 settles the 10 s closure" || bad "S13 knob: $(grep -F ' 42 ' "$L")"
mv "$H/bin/lib/mc/settle.sh" "$T/settle.sh.off"
RESET; run
grep -qE " dry (40|42|43) " "$L" && bad "S13 no settle.sh must keep every closed PR: $(grep -E ' dry (40|42|43) ' "$L")" || ok "S13 no settle.sh: every closed PR is kept (fail closed)"
mv "$T/settle.sh.off" "$H/bin/lib/mc/settle.sh"

# --- S12: the node suites -----------------------------------------------------
if [ -d "$DIR/console-ui/node_modules" ]; then
  ( cd "$DIR/console-ui" && node --test tests/needs-count.bh-9117.test.js tests/needs-sweep.bh-9117.test.js \
      tests/now-needs-split.bh-9117.test.js ) > "$T/node.out" 2>&1 \
    && ok "S12 the three node suites" || bad "S12 node suites: $(grep -E '^not ok|# fail' "$T/node.out")"
else
  echo "  note S12 console-ui/node_modules missing: the node suites run in CI"
fi

echo "needs-sweep.bh-9117: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
