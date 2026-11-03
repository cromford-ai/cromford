#!/bin/bash
# tests/migration-lane-apply.bh-8704-test.sh — BH-8704: the hub migration lane
# (bin/migration-lane.sh + bin/lib/migration-lane.sh), two ticks, project selection, CI, apply, merge and main checks.
# The fixture (scratch harness, jobs worker, seams, newp/mkpr/run) is
# tests/lib/migration-lane.bh-8704.sh. The suite is split in two so each file
# ends well inside the fixture worker's 180 s life.
#
#   L2  two ticks on two hubs at once -> 1 batch (lease); on one box -> flock
#   G1  apply_lane mac-batch -> not processed; G2 a no-arg run dispatches per
#       project (pl_dispatch) and only the enabled one runs
#   G3  an env var missing -> 1 warn alert with no env value, 0 pushes, no lease
#   C1  CI red, 3 members -> 1 critical, 0 apply, solo x3; then one solo batch per tick
#   C2  a solo batch red -> red <head>; skipped; a new head clears it
#   C3  CI timeout -> timeout, critical alert, no red rows
#   C4  lease lost during the CI wait -> lost, 0 apply, 0 merge
#   C5  lease lost during the apply command -> lost, 0 merge
#   N3  main holds a concurrent index production lacks -> no batch, 1 warn
#       alert; once production holds it, the batch runs
#   N4  a plain migration on main that production lacks: logged, the batch lands;
#       the lane works in its own clone, not the shared checkout
#   R2  three batches leave at most two apply output files
#   A1  the apply runs main's command, not the PR's
#   A2  the head moved during the CI wait -> dropped, not applied
#   A3  production holds another checksum -> refused, not merged
#   A4  status unreadable -> failed, critical alert, 0 apply
#   A5  apply exits 0 but status lacks b -> no `applied` line for b, b not merged
#   A6  DATABASE_URL reaches the apply env and no file under logs/ or state/;
#       the lane's own tokens do not reach it
#   M2  a merge refused for one member -> the others merge, failed, 1 critical
#   X   every exit path releases the lease; 0 gh calls and only 127.0.0.1 curls
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-lane-apply.bh-8704-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/migration-lane.bh-8704.sh
. "$(dirname "$0")/lib/migration-lane.bh-8704.sh" || exit 1
# The entry point under test (the fixture installs it into $H; this suite names it).
[ -x "$DIR/bin/migration-lane.sh" ] && [ -r "$DIR/bin/lib/migration-lane.sh" ] || { echo "setup: $DIR/bin/migration-lane.sh missing"; exit 1; }

# ============================================================================
echo "L2: two ticks at once -> one batch (the CI read of the tick that won waits for the other's refusal)"
newp l2
mkpr 131 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
H2="$T/h2"; cp -a "$H" "$H2"; scratch_rm "$H2/repos/$P"; git clone -q "$C/origin.git" "$H2/repos/$P"
printf '%s\n' "$H/logs/migration-lane.log" "$H2/logs/migration-lane.log" > "$C/ci_wait"
( HARNESS="$H2" MC_REPOS="$H2/repos" HARNESS_ENV_DIR="$H2/env" FLEET_CONF="$H2/fleet.conf" run "$P" ) &
RP=$!
run "$P"
wait "$RP"
rm -f "$C/ci_wait"
[ "$(calls pr_create)" = 1 ] && ok "L2 two hubs, one batch PR" || bad "L2 pr_create $(calls pr_create)"
# Read both logs into a variable first: `{ grep; grep; } | grep -q` under
# pipefail fails when grep -q exits before the second grep writes (SIGPIPE).
L2LOG=$(grep -hF "[$P] " "$H/logs/migration-lane.log" "$H2/logs/migration-lane.log")
grep -q 'lease held by another tick' <<<"$L2LOG" \
  && ok "L2 the other tick logs lease held" || bad "L2 no lease-held line: $(tail -8 <<<"$L2LOG")"
newp l2b
mkpr 141 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
printf '%s\n' "$H/logs/migration-lane.log" > "$C/ci_wait"
run "$P" & RP=$!
run "$P"; wait "$RP"; rm -f "$C/ci_wait"
[ "$(calls pr_create)" = 1 ] && lg | grep -qE 'already running on this box|lease held by another tick' && ok "L2 one box, two ticks: one batch" || bad "L2b pr_create $(calls pr_create) $(lg)"

# ============================================================================
echo "G1-G3: which projects run"
newp g1
mkpr 151 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
setting "mc_migration_hold.apply_lane.$P" mac-batch
run "$P"
[ ! -s "$C/calls" ] && ok "G1 apply_lane mac-batch: not processed" || bad "G1 calls: $(cat "$C/calls")"
# G2: a no-argument run in a tree whose fleet.conf has one enabled and one
# disabled project.
HG="$T/hg"; mkdir -p "$HG"; cp -a "$H/." "$HG/"; : > "$HG/fleet.conf"
GOFF="$P"
newp g2
scratch_rm "$HG/repos/$P"; git clone -q "$C/origin.git" "$HG/repos/$P"; cp "$H/env/$P.env" "$HG/env/"
mkpr 161 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
printf '%s Fixture/%s - - 2 hub\n%s Fixture/%s - - 2 hub\n' "$GOFF" "$GOFF" "$P" "$P" > "$HG/fleet.conf"
( cd "$T" && HARNESS="$HG" MC_REPOS="$HG/repos" HARNESS_ENV_DIR="$HG/env" FLEET_CONF="$HG/fleet.conf" LANE_GATE_DISABLE=1 bash "$HG/bin/migration-lane.sh" ) >> "$C/run.out" 2>&1
grep -q 'migration dispatch' "$C/run.out" && ok "G2 a no-arg run dispatches through the per-project runner" || bad "G2 no dispatch line: $(cat "$C/run.out")"
# The runs are detached: wait (bounded, 120 s) for the enabled one to finish.
for _ in $(seq 1 1200); do grep -qF "[$P] batch " "$HG/logs/migration-lane.log" 2>/dev/null && grep -qE "\[$P\] batch [^ ]+ (done|failed|red|timeout|lost)$" "$HG/logs/migration-lane.log" && break; sleep 0.1; done
for _ in $(seq 1 300); do pgrep -f "$HG/bin/" >/dev/null || break; sleep 0.1; done
[ "$(merges)" = 161 ] && ok "G2 the enabled project lands" || bad "G2 merges $(merges); $(cat "$HG/logs/migration-lane-cron.log" 2>/dev/null | tail -5)"
GL=$(grep -F "[$GOFF] " "$HG/logs/migration-lane.log" 2>/dev/null)
[ -z "$GL" ] && [ "$("$REALCURL" -sS "$JOBS_URL/__count?lane=migration&project=$GOFF" | jq -r .n)" = 0 ] \
  && ok "G2 the disabled project: no log line, no lease" || bad "G2 disabled project ran: $GL"
# The dispatcher's own switch: no dispatch at all.
touch "$HG/flags/lane-off-migration-lane"; : > "$C/run.out"
( cd "$T" && HARNESS="$HG" MC_REPOS="$HG/repos" HARNESS_ENV_DIR="$HG/env" FLEET_CONF="$HG/fleet.conf" bash "$HG/bin/migration-lane.sh" ) >> "$C/run.out" 2>&1
grep -q 'migration dispatch' "$C/run.out" && bad "G2 lane-off-migration-lane still dispatched" || ok "G2 lane-off-migration-lane: no dispatch"
newp g3
mkpr 171 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
sed -i '/^MIGRATION_LANE_DATABASE_URL=/d' "$H/env/$P.env"
run "$P"
[ "$(calls alert)" = 1 ] && grep -q "^warn	migration-lane-$P-config	.*MIGRATION_LANE_DATABASE_URL" "$C/alerts" && ok "G3 one warn alert names the variable" || bad "G3 alerts: $(cat "$C/alerts")"
grep -qE 'tok-fixture|app.example.invalid|bash scripts' "$C/alerts" && bad "G3 the alert holds an env value" || ok "G3 the alert holds no env value"
[ "$(calls pr_create)" = 0 ] && [ -z "$(git -C "$C/origin.git" for-each-ref refs/heads/migration-lane)" ] && ok "G3 0 pushes" || bad "G3 pushed"
[ "$("$REALCURL" -sS "$JOBS_URL/__count?lane=migration&project=$P" | jq -r .n)" = 0 ] && ok "G3 no lease taken" || bad "G3 lease row exists"

# ============================================================================
echo "C1: CI red on a 3-member batch, then one solo batch per tick"
newp c1
mkpr 181 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
mkpr 182 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"
mkpr 183 prisma/sql/20261028100200_c.sql "CREATE TABLE c (id int);"
for n in 181 182 183; do echo green > "$C/ci/$(headof $n)"; done
echo red > "$C/ci_default"
run "$P"
[ "$(grep -c '^alert critical' "$C/calls")" = 1 ] && ok "C1 one critical alert" || bad "C1 alerts: $(cat "$C/alerts")"
[ ! -e "$C/apply-order" ] && [ "$(calls merge)" = 0 ] && [ "$(calls status_get)" = 0 ] && ok "C1 0 apply, 0 merge" || bad "C1 applied or merged"
for n in 181 182 183; do [ "$(ledger_get migration-lane "pr $P#$n" | cut -d' ' -f1-2)" = "solo $(headof $n)" ] || bad "C1 row #$n: $(ledger_get migration-lane "pr $P#$n")"; done
ok "C1 rows solo x3"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = red ] && ok "C1 ledger batch = red" || bad "C1 batch row"
for t in 1 2 3; do run "$P"; done
[ "$(calls pr_create)" = 4 ] && ok "C1 three solo batches over three ticks" || bad "C1 pr_create $(calls pr_create)"
grep '^pr_create' "$C/calls" | sed -n '2,4p' | grep -c ': #18[123]$' | grep -qx 3 && ok "C1 each solo batch has one member" || bad "C1 solo titles: $(grep pr_create "$C/calls")"
for n in 181 182 183; do [ "$(ledger_get migration-lane "pr $P#$n" | cut -d' ' -f1)" = red ] || bad "C1 row #$n not red"; done
ok "R1 solo rows read by the next tick and turned red"
run "$P"
[ "$(calls pr_create)" = 4 ] && lg | grep -q '#181 skipped: its solo batch was red' && ok "C2 a red (PR, head) is skipped" || bad "C2 skip: $(lg | tail -5)"
lease_free "$P" && ok "C1 lease released" || bad "C1 lease held"

echo "C2: a new head clears the red row"
W="$C/w-181"; echo "-- v2" >> "$W/prisma/sql/20261028100000_a.sql"; git -C "$W" commit -qam v2; git -C "$W" push -q -f origin "HEAD:refs/pull/181/head"
NH=$(git -C "$W" rev-parse HEAD); sed -i "s/^181\t[0-9a-f]*\t/181\t$NH\t/" "$C/prs.tsv"
ledger_put mc-merge-verdict "$(SLUG)#181" clear "$NH clean"; echo green > "$C/ci/$NH"; echo green > "$C/ci_default"
run "$P"
grep -q "^merge 181 $NH$" "$C/calls" && ok "C2 the new head lands" || bad "C2 merges: $(merges) $(lg | tail -5)"

echo "C3: CI timeout"
newp c3
mkpr 191 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
echo green > "$C/ci/$HEAD_191"; echo pending > "$C/ci_default"
setting "lane.migration.$P.ci_timeout_s" 300
run "$P"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = timeout ] && ok "C3 batch = timeout" || bad "C3 batch: $(ledger_get migration-lane "batch $P")"
[ "$(calls sleep)" = 5 ] && ok "C3 the timeout knob bounds the polls (300/60 = 5 sleeps)" || bad "C3 sleeps $(calls sleep)"
grep -q "^alert critical migration-lane-$P-" "$C/calls" && ok "C3 critical alert" || bad "C3 alerts"
[ -z "$(ledger_get migration-lane "pr $P#191" | tr -d ' ')" ] && ok "C3 no red row" || bad "C3 row: $(ledger_get migration-lane "pr $P#191")"
[ "$(calls pr_close)" = 1 ] && [ "$(calls merge)" = 0 ] && ok "C3 closed, nothing merged" || bad "C3 close/merge"

echo "C4: the lease is lost during the CI wait"
newp c4
mkpr 201 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
echo green > "$C/ci/$HEAD_201"; echo pending > "$C/ci_default"
cat > "$C/on_batch_ci" <<EOT
$REALCURL -sS -X POST -d '{"lane":"migration","project":"$P"}' "$JOBS_URL/__expire" >/dev/null
$REALCURL -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' -d '{"lane":"migration","project":"$P","holder":"thief-holder"}' "$JOBS_URL/api/project-leases/acquire" >/dev/null
EOT
run "$P"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = lost ] && ok "C4 batch = lost" || bad "C4 batch: $(ledger_get migration-lane "batch $P") $(lg)"
[ "$(calls status_get)" = 0 ] && [ "$(calls merge)" = 0 ] && [ "$(calls pr_close)" = 1 ] && ok "C4 0 apply, 0 merge, batch PR closed" || bad "C4 calls: $(cat "$C/calls")"

echo "C5: the lease is lost while the apply command runs"
newp c5
mkpr 205 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
setting "lane.migration.$P.ci_poll_s" 15
cat > "$C/steal.sh" <<EOT
$REALCURL -sS -X POST -d '{"lane":"migration","project":"$P"}' "$JOBS_URL/__expire" >/dev/null
$REALCURL -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' -d '{"lane":"migration","project":"$P","holder":"thief-holder"}' "$JOBS_URL/api/project-leases/acquire" >/dev/null
# Wait (bounded, 40 s) until the lane's next renew is refused: it writes lease-lost in its tick dir.
for i in \$(seq 1 400); do [ -n "\$(find "\${TMPDIR:-/tmp}" -maxdepth 2 -path '*/ml-$P.*/lease-lost' 2>/dev/null)" ] && break; sleep 0.1; done
EOT
sed -i "s|^MIGRATION_LANE_APPLY_CMD=.*|MIGRATION_LANE_APPLY_CMD=\"bash $C/steal.sh; bash scripts/db/apply.sh\"|" "$H/env/$P.env"
run "$P"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = lost ] && ok "C5 batch = lost" || bad "C5 batch: $(ledger_get migration-lane "batch $P") $(lg | tail -4)"
[ "$(calls merge)" = 0 ] && [ "$(calls pr_close)" = 1 ] && ok "C5 0 merge, batch PR closed" || bad "C5 calls: $(grep -E '^(merge|pr_close)' "$C/calls")"
lg | grep -q 'lost: the lease was lost during the apply' && ok "C5 the log names the apply" || bad "C5 log: $(lg | tail -3)"

echo "N3: main holds a concurrent index that production lacks"
newp n3
git -C "$C/seed" pull -q "$C/origin.git" main
printf 'CREATE INDEX CONCURRENTLY base_i ON base (id);\n' > "$C/seed/prisma/sql/20261027000000_idx.sql"
git -C "$C/seed" add -A && git -C "$C/seed" commit -qm "hand-merged concurrent index" && git -C "$C/seed" push -q "$C/origin.git" main
mkpr 281 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
run "$P"
[ "$(calls pr_create)" = 0 ] && [ ! -e "$C/apply-order" ] && ok "N3 no batch while main's concurrent file is not applied" || bad "N3 batch formed: $(lg | tail -4)"
lg | grep -q 'main holds prisma/sql/20261027000000_idx.sql' && ok "N3 the log names the file" || bad "N3 log: $(lg | tail -3)"
[ "$(grep -c "^alert warn migration-lane-$P-main-concurrent" "$C/calls")" = 1 ] && ok "N3 one warn alert" || bad "N3 alerts: $(cat "$C/alerts")"
SI=$(sha256sum "$C/seed/prisma/sql/20261027000000_idx.sql" | cut -d' ' -f1)
jq --arg s "$SI" '.applied += [{filename: "20261027000000_idx.sql", checksum: $s}]' "$C/status.json" > "$C/st.t" && mv "$C/st.t" "$C/status.json"
run "$P"
[ "$(merges)" = 281 ] && ok "N3 once production holds it, the batch lands" || bad "N3 merges: $(merges) $(lg | tail -4)"

echo "N4: a plain migration on main that production lacks is named before the apply"
newp n4
git -C "$C/seed" pull -q "$C/origin.git" main
printf 'CREATE TABLE hand (id int);\n' > "$C/seed/prisma/sql/20261027000000_hand.sql"
git -C "$C/seed" add -A && git -C "$C/seed" commit -qm "hand-merged plain migration" && git -C "$C/seed" push -q "$C/origin.git" main
mkpr 285 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
run "$P"
lg | grep -q "main's 20261027000000_hand.sql is not in production yet; this apply runs it too" && ok "N4 the log names main's pending file" || bad "N4 log: $(lg | tail -4)"
[ "$(merges)" = 285 ] && ok "N4 the batch still lands" || bad "N4 merges: $(merges)"
grep -q "main's 0001_base.sql" <<<"$(lg)" && bad "N4 an applied main file was named" || ok "N4 an applied main file is not named"
[ -d "$H/state/migration-lane/$P/repo/objects" ] && [ -z "$(git -C "$H/repos/$P" worktree list | sed 1d)" ] \
  && [ "$(git -C "$H/repos/$P" remote get-url origin)" = "$C/origin.git" ] && ok "N4 the lane works in its own clone; the shared checkout has no lane worktree" || bad "N4 shared checkout touched: $(git -C "$H/repos/$P" worktree list)"

echo "R2: the apply output files stay bounded"
newp r2
mkpr 291 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
for t in 1 2 3; do run "$P"; done
[ "$(calls pr_create)" = 3 ] && ok "R2 three batches ran" || bad "R2 pr_create $(calls pr_create)"
NO=$(find "$H/state/migration-lane/$P" -maxdepth 1 -name '*.out' | wc -l)
[ "$NO" -le 2 ] && ok "R2 at most two apply output files ($NO)" || bad "R2 $NO output files: $(ls "$H/state/migration-lane/$P")"

# ============================================================================
echo "A1: the apply runs main's command"
newp a1
mkpr 211 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);" scripts/db/apply.sh '#!/bin/bash
echo pr > "$ML_FX/apply-marker"'
run "$P"
[ "$(cat "$C/apply-marker" 2>/dev/null)" = main ] && ok "A1 main's apply command ran" || bad "A1 marker: $(cat "$C/apply-marker" 2>/dev/null) $(lg)"

echo "A2: the head moved during the CI wait"
newp a2
mkpr 221 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
mkpr 222 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"
printf 'echo 1111111111111111111111111111111111111111 > "%s/headnow/221"\n' "$C" > "$C/on_batch_ci"
run "$P"
lg | grep -q '#221 dropped: the head moved' && ok "A2 #221 dropped" || bad "A2: $(lg)"
[ "$(merges)" = 222 ] && ! grep -q 20261028100000_a "$C/apply-order" && ok "A2 #221 not applied, #222 lands" || bad "A2 merges $(merges)"

echo "A3: production holds another checksum"
newp a3
mkpr 231 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
mkpr 232 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"
jq '.applied += [{filename: "20261028100000_a.sql", checksum: "deadbeef"}]' "$C/status.json" > "$C/st.t" && mv "$C/st.t" "$C/status.json"
run "$P"
lg | grep -q '#231 refused prisma/sql/20261028100000_a.sql: changed since staging' && ok "A3 refused: changed since staging" || bad "A3: $(lg)"
[ "$(merges)" = 232 ] && ok "A3 #231 not merged, #232 merged" || bad "A3 merges: $(merges)"
[ "$(ledger_get migration-lane "pr $P#231" | cut -d' ' -f1)" = changed ] && ok "A3 row changed" || bad "A3 row"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = failed ] && ok "A3 batch = failed" || bad "A3 batch"

echo "A4: status unreadable"
newp a4
mkpr 241 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
touch "$C/status_fail"
run "$P"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = failed ] && ok "A4 batch = failed" || bad "A4 batch"
grep -q '^alert critical' "$C/calls" && [ ! -e "$C/apply-order" ] && [ "$(calls merge)" = 0 ] && ok "A4 critical alert, 0 apply, 0 merge" || bad "A4: $(cat "$C/calls")"
[ "$(calls pr_close)" = 1 ] && [ -z "$(git -C "$C/origin.git" for-each-ref refs/heads/migration-lane)" ] && ok "M3 batch PR closed and branch deleted on failure" || bad "M3 failure close"
lease_free "$P" && ok "A4 lease released" || bad "A4 lease held"

echo "A5: the apply exits 0 but status lacks b"
newp a5
mkpr 251 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
mkpr 252 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"
mkpr 253 prisma/sql/20261028100200_c.sql "CREATE TABLE c (id int);"
echo _b.sql > "$C/skip"
run "$P"
grep -q '#252 applied' <<<"$(lg)" && bad "A5 an applied line for b" || ok "A5 no applied line for b"
[ "$(merges)" = "251 253" ] && ok "A5 a and c merged, b not" || bad "A5 merges: $(merges)"
grep -q "^alert critical migration-lane-$P-" "$C/calls" && ok "A5 critical alert" || bad "A5 alerts"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = failed ] && ok "A5 batch = failed" || bad "A5 batch"

echo "A6: DATABASE_URL reaches the apply env and no file"
newp a6
mkpr 261 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
run "$P"
DBURL="postgres://fixture-user:fixture-pass@db.example.invalid/$P"
[ "$(cat "$C/dburl" 2>/dev/null)" = "$DBURL" ] && ok "A6 the apply env has DATABASE_URL" || bad "A6 dburl: $(cat "$C/dburl" 2>/dev/null)"
[ "$(cat "$C/creds" 2>/dev/null)" = 0 ] && ok "A6 the apply env has no MIGRATION_TOKEN or HARNESS_SECRET" || bad "A6 creds in the apply env: $(cat "$C/creds" 2>/dev/null)"
LEAK=$(grep -rlF "fixture-pass" "$H/logs" "$H/state" 2>/dev/null)
[ -n "$LEAK" ] && bad "A6 the credential is in $(grep -rlF fixture-pass "$H/logs" "$H/state")" || ok "A6 the credential is in no log or state file"
grep -qF fixture-pass "$C/run.out" && bad "A6 the credential is in the lane output" || ok "A6 not in the lane output"

echo "M2: one merge refused"
newp m2
mkpr 271 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
mkpr 272 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"
mkpr 273 prisma/sql/20261028100200_c.sql "CREATE TABLE c (id int);"
echo 5 > "$C/merge_rc/272"
run "$P"
lg | grep -q '#272 merge refused' && lg | grep -q '#273 merged' && ok "M2 #272 refused, #273 still merged" || bad "M2: $(lg)"
[ "$(grep -c '^alert critical' "$C/calls")" = 1 ] && ok "M2 one critical alert" || bad "M2 alerts: $(cat "$C/alerts")"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = failed ] && ok "M2 batch = failed" || bad "M2 batch"

# ============================================================================
echo "X: no vendor call"
[ ! -s "$T/gh.log" ] && ok "X 0 gh calls" || bad "X gh calls: $(head -3 "$T/gh.log")"
OFFBOX=$(grep -vE '^https?://127\.0\.0\.1:' "$T/curl-hosts.log")
[ -n "$OFFBOX" ] && bad "X a curl left 127.0.0.1: $(grep -vE '127\.0\.0\.1' "$T/curl-hosts.log" | head -3)" || ok "X every curl went to 127.0.0.1"

echo "migration-lane-apply.bh-8704: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
