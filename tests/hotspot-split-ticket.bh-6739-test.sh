#!/bin/bash
# tests/hotspot-split-ticket.bh-6739-test.sh — BH-6739 (BH-6543.2): a file
# that crosses the conflict threshold files its own split ticket, once.
#
# The REAL bin/hotspot-split-ticket.sh runs against a scratch $HARNESS. The
# worker is the REAL jobs worker on node:sqlite behind real curl
# (tests/lib/hotspot-worker.bh-6739.mjs), so the lane's GET and PUT go through
# worker/jobs/src/routes/hotspot-tickets.js. `gh` is a stub on PATH that answers
# `gh api -i` with a status line and a body, so the real bin/lib/gh-rest*.sh
# parse it. The issue body comes from the REAL prompts/hotspot-split-ticket.md
# and the list catalog is the REAL catalog/list-files.tsv.
#
#   H1  two rows over threshold 10 (no settings row), one listed: one ai-build
#       issue with the exact title, one row, filed=1 listed=1
#   H2  a second run on the same DB: no create, recorded=1 filed=0
#   H3  hotspots.split_threshold=50: no create, no row
#   H4  the body of H1's issue: PR links, a branch id as plain text, the
#       marker, the fragment pattern, list-files.tsv, no `{{`
#   H5  edges: 9 vs 10 not filed, cron/hub.cron listed, cron/lanes/x.cron
#       filed; 12 eligible rows give at most 10 creates
#   H6  input from the API, not a checkout: the lane GETs
#       /api/conflict-hotspots?project=cromford&limit=10; a contents read
#       that answers 404 is gone=1 and not filed; a `[[path]]` file is read
#       with the encoded URL and filed with the raw title; --hotspots <json>
#       reads a saved copy of the GET answer
#   H7  threshold `abc` and `0`: no create, stopped=threshold, one warn alert
#   H8  create fails then works next run; the row PUT fails, then the next run
#       finds the marker in the open list and records it with no new create
#   H9  the registry entry: id, scope hub, weekly cadence, switch flag, one
#       knob: the HOTSPOT_SPLIT_NOW test seam, not settable
#   H10 flags/lane-off-hotspot-split-ticket: exit 0, no gh call, no worker call
#   H11 the conflict-hotspots GET or the hotspot-tickets GET answers 500, or
#       the issue list fails: stopped, nothing filed
#   H12 last_ok_at 15 days old at max age 14: stopped=stale; 13 days: runs;
#       run null: stopped=never-measured; run.repo another slug:
#       stopped=repo-mismatch; max age `abc`: stopped=max-age; last_ok_at not
#       a time: stopped=bad-output; a contents read
#       that answers 500: failed=1, not filed, the warn alert names it
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/hotspot-split-ticket.bh-6739-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/hotspot-worker.bh-6739.mjs"
LANE_REL=bin/hotspot-split-ticket.sh
SLUG=example-org/cromford
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
done_() { echo "hotspot-split-ticket.bh-6739: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
if ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "hotspot-split-ticket: SKIPPED, this node has no node:sqlite"; exit 0
fi

for f in "$DIR/$LANE_REL" "$DIR/worker/jobs/src/routes/hotspot-tickets.js" "$DIR/prompts/hotspot-split-ticket.md" \
         "$DIR/catalog/lanes.d/hotspot-split-ticket.json" "$DIR/cron/lanes/732-hotspot-split-ticket.cron" \
         "$DIR/worker/jobs/test/route-table.d/bh-6739-hotspot-tickets.txt"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
[ -s "$DIR/$LANE_REL" ] || done_

# core.js imports the generated, git-ignored catalog/lanes.json, and the worker
# test lib composes schema.sql: both are built before the worker loads.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

H="$T/h"; FX="$T/fx"; CALLS="$T/gh-calls.log"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$H/prompts" "$FX" "$T/stubbin"
( cd "$DIR" && scratch_install_closure "$LANE_REL" "$H" ) >/dev/null || bad "setup: closure of $LANE_REL"
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$H" ) >/dev/null || bad "setup: closure of bin/jobs-client.sh"
cp "$DIR/catalog/list-files.tsv" "$H/catalog/" && cp "$DIR/prompts/hotspot-split-ticket.md" "$H/prompts/" \
  || bad "setup: catalog or template"
: > "$H/env/global.env"
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.log"
EOF
chmod +x "$H/bin/"*.sh

# The stub gh: GET issues answers $FX/issues.json (or $FX/issues.status);
# GET contents answers 404 for a path listed in $FX/gone, 500 for one in
# $FX/contents.fail, else 200;
# POST issues answers 500 once when $FX/create.fail exists, else a new number,
# and the new issue joins the open list (it IS open on GitHub).
cat > "$T/stubbin/gh" <<EOF
#!/bin/bash
shift; M=; P=
while [ \$# -gt 0 ]; do case "\$1" in -i) shift ;; -X) M="\$2"; shift 2 ;; *) P="\$1"; shift; break ;; esac; done
printf 'GH %s %s | %s\n' "\$M" "\$P" "\$*" >> "$CALLS"
reply() { printf 'HTTP/2 %s X\r\n\r\n%s\n' "\$1" "\${2:-}"; }
title=; body=
for a in "\$@"; do case "\$a" in title=*) title="\${a#title=}" ;; body=@*) body="\${a#body=@}" ;; esac; done
case "\$M \$P" in
  "GET repos/$SLUG/issues")
    st=\$(cat "$FX/issues.status" 2>/dev/null || echo 200)
    reply "\$st" "\$(cat "$FX/issues.json" 2>/dev/null || echo '[]')" ;;
  "POST repos/$SLUG/issues")
    if [ -f "$FX/create.fail" ]; then rm -f "$FX/create.fail"; reply 500 '{"message":"fixture failure"}'; exit 0; fi
    n=\$(( \$(cat "$FX/next" 2>/dev/null || echo 700) + 1 )); echo "\$n" > "$FX/next"
    cp "\$body" "$FX/body.\$n"; printf '%s\n' "\$title" > "$FX/title.\$n"
    jq -c --argjson n "\$n" --arg t "\$title" --rawfile b "\$body" '. + [{number: \$n, title: \$t, body: \$b, labels: [{name: "ai-build"}]}]' \
      "$FX/issues.json" > "$FX/issues.tmp" && mv "$FX/issues.tmp" "$FX/issues.json"
    reply 201 "{\"number\":\$n,\"labels\":[{\"name\":\"ai-build\"}]}" ;;
  "POST repos/$SLUG/issues/"*/labels) reply 200 '[{"name":"ai-build"}]' ;;
  "GET repos/$SLUG/contents/"*)
    c=\${P#repos/$SLUG/contents/}; c=\${c%%\?ref=main}
    if grep -qxF "\$c" "$FX/gone" 2>/dev/null; then reply 404 '{"message":"Not Found"}'
    elif grep -qxF "\$c" "$FX/contents.fail" 2>/dev/null; then reply 500 '{"message":"fixture failure"}'
    else reply 200 '{"type":"file"}'; fi ;;
  *) reply 500 '{}' ;;
esac
EOF
chmod +x "$T/stubbin/gh"

PIDS=()
srv() {
  local n="$1"
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$T/$n.log" "$FX" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
}
stop_all() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT

# fresh — a new worker (empty DB, the seed settings row removed), no issues, no logs.
fresh() {
  stop_all; PIDS=()
  srv w; [ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1; }
  JOBS_URL="http://127.0.0.1:$PORT"
  sql "DELETE FROM settings WHERE key IN ('hotspots.split_threshold','hotspots.split_max_age_days')"
  echo '[]' > "$FX/issues.json"
  rm -f "$FX/next" "$FX/issues.status" "$FX/create.fail" "$FX/put-fail" "$FX/get-fail" "$FX/hot-get-fail" \
    "$FX/gone" "$FX/contents.fail" "$FX"/body.* "$FX"/title.*
  : > "$CALLS"; : > "$T/alerts.log"; : > "$H/logs/hotspot-split-ticket.log"
  scratch_rm "$H/state" && mkdir -p "$H/state"
}
sql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
get() { curl -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
threshold() { sql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('hotspots.split_threshold','$1','fixture','fixture','2026-10-15T00:00:00Z')"; }
max_age() { sql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('hotspots.split_max_age_days','$1','fixture','fixture','2026-10-15T00:00:00Z')"; }
# seed <row>... — store a measurement through the REAL PUT /api/conflict-hotspots,
# the shape bin/conflict-hotspots-fleet.sh sends; each row is
# `path<TAB>conflicts<TAB>rebases<TAB>prs`. last_ok_at is then pinned to
# OK_AT (the worker stamps its own clock) so the lane's HOTSPOT_SPLIT_NOW is fixed.
OK_AT=2024-10-11T03:32:58Z
NOW_FIX=$(date -u -d 2024-10-12T04:53:00Z +%s)
seed() {
  local rows; rows=$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {file: .[0], conflicts: (.[1] | tonumber), rebases: (.[2] | tonumber), prs: .[3]})')
  jq -nc --arg r "${SEED_REPO:-$SLUG}" --argjson rows "$rows" '{project: "cromford", repo: $r, box: "box-small",
    status: "ok", window_days: 30, since: "2024-09-11T03:23:00Z", until: "2024-10-11T03:23:00Z",
    ref_sha: "99fd5865ae56aa0f", files_total: ($rows | length), rows: $rows}' > "$T/seed.json"
  curl -sS -o /dev/null -X PUT -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
    --data-binary @"$T/seed.json" "$JOBS_URL/api/conflict-hotspots"
  sql "UPDATE conflict_hotspot_runs SET last_ok_at='$OK_AT' WHERE project='cromford'"
}
run() {
  env HARNESS="$H" PATH="$T/stubbin:$PATH" JOBS_URL="$JOBS_URL" HOTSPOT_SPLIT_NOW="${RUN_NOW:-$NOW_FIX}" \
    HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 LANE_GATE_CACHE_S=0 \
    JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 GH_TOKEN=tok-fixture-1 GH_ETAG=0 \
    bash "$H/$LANE_REL" "$@" > "$T/run.out" 2>&1
  RC=$?
}
creates() { grep -c "^GH POST repos/$SLUG/issues |" "$CALLS" 2>/dev/null || true; }
ghcalls() { grep -c '^GH ' "$CALLS" 2>/dev/null || true; }
summary() { grep '^[^ ]* hotspot-split-ticket repo=' "$H/logs/hotspot-split-ticket.log" | tail -1; }
rows() { get "SELECT repo, path, issue FROM hotspot_tickets ORDER BY path" | jq -r '.[] | "\(.repo) \(.path) \(.issue)"'; }
has() { case "$(summary)" in *" $1"*) return 0 ;; *) return 1 ;; esac; }

H1_ROWS=("bin/a.sh	14	20	#2388,#2402,ticket/bh-77" "worker/jobs/src/index.js	12	30	#2390" "bin/b.sh	3	5	#2391")

# ── H1 ───────────────────────────────────────────────────────────────────────
fresh; seed "${H1_ROWS[@]}"
run
[ "$RC" = 0 ] && ok "H1 rc 0" || bad "H1 rc $RC: $(cat "$T/run.out")"
[ "$(creates)" = 1 ] && ok "H1 exactly one issue create" || bad "H1 creates=$(creates): $(cat "$CALLS")"
grep -q "^GH POST repos/$SLUG/issues | .*title=Split bin/a.sh: 14 conflicts in 30 days" "$CALLS" \
  && ok "H1 the exact title" || bad "H1 title: $(cat "$CALLS")"
grep "^GH POST repos/$SLUG/issues |" "$CALLS" | grep -qF 'labels[]=ai-build' && ok "H1 labels[]=ai-build on the create" || bad "H1 no ai-build label"
[ "$(rows)" = "$SLUG bin/a.sh 701" ] && ok "H1 one row: bin/a.sh #701" || bad "H1 rows: $(rows)"
has "filed=1" && has "listed=1" && has "threshold=10" && has "over=2" \
  && ok "H1 summary filed=1 listed=1 threshold=10 over=2" || bad "H1 summary: $(summary)"
grep -q 'listed: worker/jobs/src/index.js' "$H/logs/hotspot-split-ticket.log" && ok "H1 logs the listed path" \
  || bad "H1 log: $(cat "$H/logs/hotspot-split-ticket.log")"
grep -q -- '--resolve --id hotspot-split-ticket' "$T/alerts.log" && ! grep -q -- '--severity warn' "$T/alerts.log" \
  && ok "H1 a clean run resolves the alert" || bad "H1 alerts: $(cat "$T/alerts.log")"

# ── H4 (the body H1 filed) ───────────────────────────────────────────────────
B="$FX/body.701"
if [ -s "$B" ]; then
  grep -qF '[#2388](https://github.com/example-org/cromford/pull/2388)' "$B" \
    && grep -qF '[#2402](https://github.com/example-org/cromford/pull/2402)' "$B" \
    && ok "H4 the PR list links #2388 and #2402" || bad "H4 PR links: $(cat "$B")"
  grep -q '^- `ticket/bh-77`$' "$B" && ok "H4 a branch id stays plain text" || bad "H4 branch id: $(cat "$B")"
  grep -qF '<!-- harness-hotspot-split: bin/a.sh -->' "$B" && ok "H4 the marker" || bad "H4 no marker"
  grep -qF 'bin/a.d/<ticket-key>-<name>.sh' "$B" && ok "H4 the fragment pattern for bin/a.sh" || bad "H4 fragment pattern: $(cat "$B")"
  grep -qF 'list-files.tsv' "$B" && ok "H4 names list-files.tsv" || bad "H4 no list-files.tsv"
  grep -qF 'worker/jobs/src/routes/' "$B" && ok "H4 lists an existing catalog pair" || bad "H4 no catalog pair"
  grep -qF 'tests/<area>.bh-<n>-test.sh' "$B" && ok "H4 the acceptance test shape" || bad "H4 no test shape"
  grep -qF '14 replayed conflicts in 30 days' "$B" && ok "H4 the facts line" || bad "H4 facts: $(head -5 "$B")"
  grep -q '{{' "$B" && bad "H4 a placeholder is left: $(grep '{{' "$B")" || ok "H4 no placeholder left"
else bad "H4 no body was filed"; fi

# ── H2 ───────────────────────────────────────────────────────────────────────
: > "$CALLS"
run
[ "$(creates)" = 0 ] && ok "H2 a second run files nothing" || bad "H2 creates=$(creates)"
has "recorded=1" && has "filed=0" && ok "H2 summary recorded=1 filed=0" || bad "H2 summary: $(summary)"
[ "$(rows | wc -l | tr -d ' ')" = 1 ] && ok "H2 still one row" || bad "H2 rows: $(rows)"

# ── H3 ───────────────────────────────────────────────────────────────────────
fresh; threshold 50; seed "${H1_ROWS[@]}"
run
[ "$(creates)" = 0 ] && [ -z "$(rows)" ] && ok "H3 threshold 50: no create, no row" || bad "H3 creates=$(creates) rows=$(rows)"
has "threshold=50" && has "over=0" && ok "H3 summary threshold=50 over=0" || bad "H3 summary: $(summary)"
[ "$(ghcalls)" = 0 ] && ok "H3 no candidate: no GitHub call" || bad "H3 gh calls: $(cat "$CALLS")"

# ── H5 ───────────────────────────────────────────────────────────────────────
fresh
seed "bin/nine.sh	9	9	#1" "bin/ten.sh	10	9	#2" "cron/hub.cron	15	9	#3" "cron/lanes/x.cron	12	9	#4"
run
grep -q 'title=Split bin/ten.sh: 10 conflicts' "$CALLS" && ok "H5 10 vs 10 is filed" || bad "H5 bin/ten.sh not filed: $(cat "$CALLS")"
grep -q 'title=Split bin/nine.sh' "$CALLS" && bad "H5 9 vs 10 was filed" || ok "H5 9 vs 10 is not filed"
grep -q 'title=Split cron/hub.cron' "$CALLS" && bad "H5 cron/hub.cron was filed" || ok "H5 cron/hub.cron is listed"
grep -q 'title=Split cron/lanes/x.cron' "$CALLS" && ok "H5 cron/lanes/x.cron is filed (* never crosses /)" || bad "H5 cron/lanes/x.cron not filed"
has "listed=1" && has "filed=2" && ok "H5 summary listed=1 filed=2" || bad "H5 summary: $(summary)"
fresh
R12=(); for i in 01 02 03 04 05 06 07 08 09 10 11 12; do R12+=("bin/f$i.sh	20	1	#$i"); done
seed "${R12[@]}"
run
[ "$(creates)" = 10 ] && ok "H5 12 eligible rows: 10 creates (top 10)" || bad "H5 creates=$(creates)"
has "rows=10" && ok "H5 summary rows=10" || bad "H5 summary: $(summary)"

# ── H7 ───────────────────────────────────────────────────────────────────────
for v in abc 0; do
  fresh; threshold "$v"; seed "${H1_ROWS[@]}"
  run
  [ "$RC" = 0 ] && [ "$(creates)" = 0 ] && [ -z "$(rows)" ] && ok "H7 threshold '$v': rc 0, no create, no row" \
    || bad "H7 '$v': rc=$RC creates=$(creates) rows=$(rows)"
  has "stopped=threshold" && ok "H7 '$v': stopped=threshold" || bad "H7 '$v' summary: $(summary)"
  [ "$(grep -c -- '--severity warn --id hotspot-split-ticket' "$T/alerts.log")" = 1 ] && ok "H7 '$v': one warn alert" \
    || bad "H7 '$v' alerts: $(cat "$T/alerts.log")"
done

# ── H8 ───────────────────────────────────────────────────────────────────────
H8_ROW="bin/a.sh	14	20	#2388"; fresh; seed "$H8_ROW"
: > "$FX/create.fail"
run
has "failed=1" && has "filed=0" && [ -z "$(rows)" ] && ok "H8 create fails: failed=1, no row" || bad "H8a summary: $(summary) rows=$(rows)"
grep -q -- '--severity warn --id hotspot-split-ticket' "$T/alerts.log" && ok "H8 a failed path sends the warn alert" || bad "H8a alerts: $(cat "$T/alerts.log")"
: > "$CALLS"; run
[ "$(creates)" = 1 ] && [ "$(rows)" = "$SLUG bin/a.sh 701" ] && has "filed=1" && ok "H8 the next run files once and records" \
  || bad "H8b creates=$(creates) rows=$(rows) summary=$(summary)"
fresh; seed "$H8_ROW"; : > "$FX/put-fail"
run
[ "$(creates)" = 1 ] && [ -z "$(rows)" ] && has "failed=1" && ok "H8 the row PUT fails: issue made, no row, failed=1" \
  || bad "H8c creates=$(creates) rows=$(rows) summary=$(summary)"
grep -q 'row write failed' "$H/logs/hotspot-split-ticket.log" && ok "H8 logs the row failure" || bad "H8c log: $(cat "$H/logs/hotspot-split-ticket.log")"
: > "$CALLS"; run
[ "$(creates)" = 0 ] && [ "$(rows)" = "$SLUG bin/a.sh 701" ] && has "reused=1" \
  && ok "H8 the next run reuses the marker issue #701 with no create" || bad "H8d creates=$(creates) rows=$(rows) summary=$(summary)"
# A marker that is only a prefix of another path's marker is not a match.
fresh; seed "$H8_ROW"
jq -n '[{number: 9, title: "x", body: "<!-- harness-hotspot-split: bin/a.sh.bak -->", labels: []}]' > "$FX/issues.json"
run
[ "$(creates)" = 1 ] && has "reused=0" && ok "H8 bin/a.sh.bak's marker does not match bin/a.sh" || bad "H8e creates=$(creates) summary=$(summary)"

# ── H11 ──────────────────────────────────────────────────────────────────────
fresh; seed "$H8_ROW"; : > "$FX/hot-get-fail"
run
[ "$(creates)" = 0 ] && [ "$(ghcalls)" = 0 ] && has "stopped=measure-unreadable" \
  && ok "H11 conflict-hotspots GET 500: stopped=measure-unreadable, no gh call" || bad "H11m creates=$(creates) summary=$(summary)"
grep -q -- '--severity warn --id hotspot-split-ticket' "$T/alerts.log" && ok "H11 measure-unreadable sends the warn alert" \
  || bad "H11m alerts: $(cat "$T/alerts.log")"
fresh; seed "$H8_ROW"; : > "$FX/get-fail"
run
[ "$(creates)" = 0 ] && has "stopped=rows-unreadable" && ok "H11 GET 500: stopped=rows-unreadable, no create" \
  || bad "H11a creates=$(creates) summary=$(summary)"
fresh; seed "$H8_ROW"; echo 403 > "$FX/issues.status"
run
[ "$(creates)" = 0 ] && has "stopped=issue-search" && [ -z "$(rows)" ] && ok "H11 issue list 403: stopped=issue-search, no create" \
  || bad "H11b creates=$(creates) summary=$(summary)"
fresh; seed "$H8_ROW"
jq -n '[range(1001) | {number: (. + 1), title: "x", body: "", labels: []}]' > "$FX/issues.json"
run
[ "$(creates)" = 0 ] && has "stopped=issue-search" && ok "H11 1000 open issues (the cap): stopped, no create" \
  || bad "H11c creates=$(creates) summary=$(summary)"

# ── H10 ──────────────────────────────────────────────────────────────────────
fresh; seed "${H1_ROWS[@]}"; : > "$H/flags/lane-off-hotspot-split-ticket"
run
[ "$RC" = 0 ] && [ "$(ghcalls)" = 0 ] && ok "H10 off flag: rc 0, no gh call" || bad "H10 rc=$RC gh=$(cat "$CALLS")"
grep -qE '^GET /api/(conflict-hotspots|hotspot-tickets)' "$T/w.log" && bad "H10 the worker was called: $(cat "$T/w.log")" || ok "H10 no worker call"
rm -f "$H/flags/lane-off-hotspot-split-ticket"

# ── H9 ───────────────────────────────────────────────────────────────────────
REG="$DIR/catalog/lanes.d/hotspot-split-ticket.json"
jq -e '.id == "hotspot-split-ticket" and .scope == "hub" and .switch.name == "lane-off-hotspot-split-ticket"
  and .cadence == "53 4 * * 1" and ([.knobs[].env] == ["HOTSPOT_SPLIT_NOW"])
  and .knobs[0].settable == false' "$REG" >/dev/null 2>&1 \
  && ok "H9 registry: id, scope hub, cadence 53 4 * * 1, switch flag, one knob HOTSPOT_SPLIT_NOW not settable" || bad "H9 registry: $(cat "$REG" 2>/dev/null | head -20)"

# ── H6: the stored measurement is the input ──────────────────────────────────
fresh
printf '%s\n' bin/gone.sh > "$FX/gone"
seed "bin/hot.sh	20	9	#11" "bin/gone.sh	18	9	#12" "console-ui/functions/api/coord/[[path]].js	16	9	#13"
run
[ "$RC" = 0 ] && ok "H6 rc 0" || bad "H6 rc $RC: $(cat "$T/run.out")"
grep -qxF 'GET /api/conflict-hotspots?project=cromford&limit=10 200' "$T/w.log" \
  && ok "H6 the lane GETs /api/conflict-hotspots?project=cromford&limit=10" || bad "H6 worker log: $(cat "$T/w.log")"
grep -q 'title=Split bin/hot.sh: 20 conflicts in 30 days' "$CALLS" && ok "H6 bin/hot.sh filed from the stored rows" \
  || bad "H6 creates: $(cat "$CALLS") log: $(cat "$H/logs/hotspot-split-ticket.log")"
grep -q 'title=Split bin/gone.sh' "$CALLS" && bad "H6 bin/gone.sh was filed" || ok "H6 a 404 contents read is not filed"
grep -qF "GH GET repos/$SLUG/contents/console-ui/functions/api/coord/%5B%5Bpath%5D%5D.js?ref=main |" "$CALLS" \
  && ok "H6 the [[path]] file is read with the encoded URL" || bad "H6 contents reads: $(grep contents "$CALLS")"
grep -qF 'title=Split console-ui/functions/api/coord/[[path]].js: 16 conflicts in 30 days' "$CALLS" \
  && ok "H6 the [[path]] file is filed with the raw title" || bad "H6 [[path]] title: $(cat "$CALLS")"
has "gone=1" && has "filed=2" && has "ref=99fd5865ae56" && has "failed=0" \
  && ok "H6 summary gone=1 filed=2 ref=99fd5865ae56" || bad "H6 summary: $(summary)"
grep -q 'gone: bin/gone.sh' "$H/logs/hotspot-split-ticket.log" && ok "H6 logs the gone path" || bad "H6 log: $(cat "$H/logs/hotspot-split-ticket.log")"
# --hotspots <json>: a saved copy of the GET answer; the worker GET is not made.
curl -sS -H "authorization: Bearer fixture-harness-secret" "$JOBS_URL/api/conflict-hotspots?project=cromford&limit=10" > "$T/saved.json"
fresh
run --hotspots "$T/saved.json"
grep -q '^GET /api/conflict-hotspots' "$T/w.log" && bad "H6 --hotspots still GETs the worker" || ok "H6 --hotspots reads the saved copy, no conflict-hotspots GET"
[ "$(creates)" = 3 ] && has "filed=3" && ok "H6 --hotspots files from the saved copy" || bad "H6 --hotspots creates=$(creates) summary=$(summary)"

# ── H12: freshness and identity of the stored run ────────────────────────────
fresh; seed "$H8_ROW"
RUN_NOW=$(date -u -d 2024-10-26T03:32:59Z +%s) run
[ "$RC" = 0 ] && [ "$(ghcalls)" = 0 ] && has "stopped=stale" && ok "H12 15 days old at max age 14: stopped=stale, no gh call" \
  || bad "H12a rc=$RC gh=$(ghcalls) summary=$(summary)"
grep -q -- '--severity warn --id hotspot-split-ticket' "$T/alerts.log" && ok "H12 stale sends the warn alert" || bad "H12a alerts: $(cat "$T/alerts.log")"
RUN_NOW=$(date -u -d 2024-10-24T03:32:58Z +%s) run
[ "$(creates)" = 1 ] && has "filed=1" && ok "H12 13 days old at max age 14: runs and files" || bad "H12b creates=$(creates) summary=$(summary)"
fresh; seed "$H8_ROW"; max_age 30
RUN_NOW=$(date -u -d 2024-10-26T03:32:59Z +%s) run
[ "$(creates)" = 1 ] && ok "H12 max age 30 reads the settings row: 15 days runs" || bad "H12c creates=$(creates) summary=$(summary)"
fresh; seed "$H8_ROW"; max_age abc
run
[ "$(creates)" = 0 ] && has "stopped=max-age" && ok "H12 max age 'abc': stopped=max-age" || bad "H12d summary=$(summary)"
fresh
run
[ "$(ghcalls)" = 0 ] && has "stopped=never-measured" && ok "H12 run null: stopped=never-measured" || bad "H12e summary=$(summary)"
fresh; seed "$H8_ROW"; sql "UPDATE conflict_hotspot_runs SET last_ok_at='not-a-time' WHERE project='cromford'"
run
[ "$(ghcalls)" = 0 ] && has "stopped=bad-output" && ok "H12 last_ok_at not a time: stopped=bad-output" || bad "H12h summary=$(summary)"
fresh; SEED_REPO=example-org/other-repo seed "$H8_ROW"
run
[ "$(ghcalls)" = 0 ] && has "stopped=repo-mismatch" && ok "H12 run.repo another slug: stopped=repo-mismatch" || bad "H12f summary=$(summary)"
fresh; seed "$H8_ROW" "bin/c.sh	12	3	#5"; printf '%s\n' bin/a.sh > "$FX/contents.fail"
run
[ "$(creates)" = 1 ] && grep -q 'title=Split bin/c.sh' "$CALLS" && has "failed=1" && has "filed=1" \
  && ok "H12 contents read 500: failed=1, that path not filed, the other filed" || bad "H12g creates=$(creates) summary=$(summary)"
grep -q -- '--severity warn --id hotspot-split-ticket .*bin/a.sh' "$T/alerts.log" && ok "H12 the warn alert names bin/a.sh" \
  || bad "H12g alerts: $(cat "$T/alerts.log")"
[ -z "$(get "SELECT path FROM hotspot_tickets WHERE path='bin/a.sh'" | jq -r '.[].path')" ] && ok "H12 no row for the unread path" || bad "H12g rows: $(rows)"

done_
