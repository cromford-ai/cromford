#!/bin/bash
# tests/roadmap-import.bh-7243-test.sh — BH-7264 (BH-7243.1): the operator CLI
# bin/roadmap-import.sh and its route POST /api/roadmap/import
# (worker/jobs/src/routes/roadmap-import.js).
#
# The CLI runs over real curl against the REAL jobs worker
# (tests/lib/roadmap-import-worker.bh-7264.mjs, node:sqlite, clock pinned),
# on the trimmed project-6 roadmap tests/fixtures/roadmap/project-6-roadmap.html.
#
#   P3 --dry-run prints the counts, sends 0 requests, and the DB stays empty
#   P1 an import: counts per section match the fixture, lanes, links, decisions,
#      created_by starts with operator:
#   P2 a second run inserts 0, and the DB counts do not change
#   P4 tldr, risks and sources are skipped and named; an <h2 id="nowhere">
#      row and an <h3 id="next"> do not become a section; an <h2> with no id
#      falls back to its first word; a long title is cut, the full text leads
#      the note; a bare "#1024" is not a link
#   P5 usage errors are rc 2 and send nothing
#   P6 an unknown project is rc 1 with the worker's error; an empty JOBS_URL
#      is rc 1 "JOBS_URL is not set"
#   P7 more than 500 rows go in calls of at most 500
#   S  the BH-7264 sources exist
#
# Run from anywhere: tests/roadmap-import.bh-7243-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/roadmap-import-worker.bh-7264.mjs"
FIX="$REPO/tests/fixtures/roadmap/project-6-roadmap.html"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qE -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no /$3/ in [$2]"; fi; }
hasnt() { if grep -qE -- "$3" <<<"$2"; then bad "$1: unexpected /$3/ in [$2]"; else ok "$1"; fi; }

command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, python3 or curl missing"; exit 0; }
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' \
  || { echo "SKIP: node $(node -v) is older than 22 (no node:sqlite)"; exit 0; }

echo "S: the BH-7264 sources exist"
for f in \
  "$REPO/bin/roadmap-import.sh" \
  "$REPO/worker/jobs/src/routes/roadmap-import.js" \
  "$REPO/console-ui/src/lib/roadmap.js" \
  "$REPO/console-ui/functions/_lib/coord-writes.d/7243-roadmap-ideas-manage.js" \
  "$REPO/tests/lib/roadmap-import-worker.bh-7264.mjs" \
  "$REPO/tests/fixtures/roadmap/project-6-roadmap.html"; do
  [ -f "$f" ] && ok "S exists: ${f#"$REPO"/}" || bad "S missing: ${f#"$REPO"/}"
done

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/env"
for L in bin/roadmap-import.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
CLI="$H/bin/roadmap-import.sh"
[ -x "$CLI" ] && ok "closure installs bin/roadmap-import.sh" || bad "closure lacks bin/roadmap-import.sh"
[ -f "$H/bin/lib/jobs/req.sh" ] && ok "closure installs bin/lib/jobs/req.sh" || bad "closure lacks bin/lib/jobs/req.sh"

NOW=1792411200   # 2026-10-19T00:00:00Z
export HARNESS="$H" HARNESS_ENV_DIR="$H/env" HARNESS_SECRET=fixture-harness-secret
export BOX_NAME=fixture-box JOBS_BOX=fixture-box JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=20
unset ROADMAP_IMPORT_ACTOR JOBS_AUTH_VIA_FILE HARNESS_SECRET_FILE

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
LOG="$T/w.log"; : > "$LOG"
node "$SRV" "$LOG" "$NOW" > "$T/w.port" 2> "$T/w.err" &
PIDS+=("$!")
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "${PIDS[0]}" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
[ -n "$PORT" ] || { echo "SKIP: the fixture worker did not start ($(head -3 "$T/w.err"))"; exit 0; }
export JOBS_URL="http://127.0.0.1:$PORT"

sql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$(python3 -I -c 'import json,sys; print(json.dumps({"sql": sys.argv[1], "params": sys.argv[2:]}))' "$@")"; }
api_calls() { grep -c '^POST /api/roadmap/import ' "$LOG"; }
sql "INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('cromford','o/cromford',0,'2026-10-19T00:00:00Z','2026-10-19T00:00:00Z')"
sql "INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('proj-b','o/proj-b',0,'2026-10-19T00:00:00Z','2026-10-19T00:00:00Z')"
sql "INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('proj-c','o/proj-c',0,'2026-10-19T00:00:00Z','2026-10-19T00:00:00Z')"
eq "setup: 3 projects" "$(sql "SELECT COUNT(*) FROM projects")" 3

echo "P3: --dry-run"
OUT=$("$CLI" --project cromford --file "$FIX" --dry-run 2>&1); rc=$?
eq "P3 rc 0" "$rc" 0
has "P3 now ideas=3" "$OUT" '^roadmap-import: now ideas=3$'
has "P3 next ideas=3" "$OUT" '^roadmap-import: next ideas=3$'
has "P3 later ideas=3" "$OUT" '^roadmap-import: later ideas=3$'
has "P3 shipped ideas=3" "$OUT" '^roadmap-import: shipped ideas=3$'
has "P3 decisions decisions=2" "$OUT" '^roadmap-import: decisions decisions=2$'
has "P3 open decisions=2" "$OUT" '^roadmap-import: open decisions=2$'
has "P3 says nothing written" "$OUT" '^roadmap-import: dry run, nothing written$'
hasnt "P3 prints no inserted line" "$OUT" 'inserted'
eq "P3 0 requests to the worker" "$(api_calls)" 0
eq "P3 the DB has no idea" "$(sql "SELECT COUNT(*) FROM roadmap_ideas" 2>/dev/null || echo 0)" 0
OUT=$(JOBS_URL='' "$CLI" --project cromford --file "$FIX" --dry-run 2>&1); rc=$?
eq "P3 a dry run needs no JOBS_URL" "$rc" 0

echo "P4: skipped sections"
for s in tldr risks sources; do
  has "P4 skipped section $s" "$OUT" "^roadmap-import: skipped section $s\$"
done
hasnt "P4 no other section is skipped" "$OUT" 'skipped section (now|next|later|shipped|decisions|open)$'

echo "P1: the import"
OUT=$("$CLI" --project cromford --file "$FIX" 2>&1); rc=$?
eq "P1 rc 0" "$rc" 0
has "P1 the inserted line" "$OUT" '^roadmap-import: inserted ideas=12 links=10 decisions=4 skipped ideas=0 decisions=0$'
eq "P1 one request" "$(api_calls)" 1
eq "P1 ideas by lane" "$(sql "SELECT lane, COUNT(*) FROM roadmap_ideas WHERE project='cromford' GROUP BY lane ORDER BY lane" | tr '\t\n' '=;')" "ideas=3;next=9"
eq "P1 every idea has source import" "$(sql "SELECT COUNT(*) FROM roadmap_ideas WHERE source='import' AND source_ref IS NOT NULL")" 12
eq "P1 created_by starts with operator:" "$(sql "SELECT COUNT(*) FROM roadmap_ideas WHERE created_by LIKE 'operator:%'")" 12
eq "P1 created_by is operator:<unix user>" "$(sql "SELECT DISTINCT created_by FROM roadmap_ideas")" "operator:$(id -un)"
eq "P1 one imported event per idea" "$(sql "SELECT COUNT(*) FROM roadmap_idea_events WHERE kind='imported'")" 12
eq "P1 the epic row has no link and a sha256 source_ref" \
  "$(sql "SELECT lane, link, substr(source_ref,1,7) FROM roadmap_ideas WHERE title LIKE 'Dedicated-database tenancy%'" | tr '\t' ' ')" "ideas NULL sha256:"
eq "P1 the plain-text #1027 row has no link" \
  "$(sql "SELECT COUNT(*) FROM roadmap_ideas WHERE title='Company Brain placement' AND link IS NULL AND source_ref LIKE 'sha256:%'")" 1
eq "P1 links: 10 rows, issue numbers" "$(sql "SELECT group_concat(issue, ',') FROM (SELECT issue FROM roadmap_links ORDER BY issue)")" \
  "761,1001,1009,1017,1020,1035,1039,1042,1043,1045"
eq "P1 links: the repo" "$(sql "SELECT DISTINCT repo FROM roadmap_links")" "example-org/project-6"
eq "P1 shipped links are closed_completed" \
  "$(sql "SELECT group_concat(issue, ',') FROM (SELECT issue FROM roadmap_links WHERE issue_state='closed_completed' ORDER BY issue)")" "1001,1042,1043"
eq "P1 no link is closed_other" "$(sql "SELECT COUNT(*) FROM roadmap_links WHERE issue_state='closed_other'")" 0
eq "P1 a shipped title and its PR link" \
  "$(sql "SELECT lane, link FROM roadmap_ideas WHERE title='ci: run CI on MonkCI runners (CI_RUNNER repo variable)'" | tr '\t' ' ')" \
  "next https://github.com/example-org/project-6/pull/1042"
eq "P1 decisions by kind and status" \
  "$(sql "SELECT kind, status, COUNT(*) FROM roadmap_decisions GROUP BY kind, status ORDER BY kind" | tr '\t\n' ' ;')" "log decided 2;open open 2"
eq "P1 a log decision: title, body, decided_at" \
  "$(sql "SELECT title, body, decided_at FROM roadmap_decisions WHERE kind='log' AND decided_at='2026-10-16'" | tr '\t' '|')" \
  "Each department keeps its own side menu. This overrides the designer's note.|Source: #951 / PR #954|2026-10-16"
eq "P1 an open decision: Topic, Question Where" \
  "$(sql "SELECT title, body FROM roadmap_decisions WHERE kind='open' AND title='Agent library layout'" | tr '\t' '|')" \
  "Agent library layout|The designer's design shows a card grid. the operator's browse rule says a table. Pick one for #1024. Where: #1024"
eq "P1 decision ids are imp- + 32 hex" "$(sql "SELECT COUNT(*) FROM roadmap_decisions WHERE id GLOB 'imp-[0-9a-f]*' AND length(id)=36")" 4

echo "P2: a second run"
OUT=$("$CLI" --project cromford --file "$FIX" 2>&1); rc=$?
eq "P2 rc 0" "$rc" 0
has "P2 inserts 0" "$OUT" '^roadmap-import: inserted ideas=0 links=0 decisions=0 skipped ideas=12 decisions=4$'
eq "P2 counts unchanged" \
  "$(sql "SELECT (SELECT COUNT(*) FROM roadmap_ideas)||' '||(SELECT COUNT(*) FROM roadmap_idea_events)||' '||(SELECT COUNT(*) FROM roadmap_links)||' '||(SELECT COUNT(*) FROM roadmap_decisions)")" \
  "12 12 10 4"

echo "P4: section edge cases"
V="$T/variant.html"
LONG=$(printf 'Long title word %.0s' $(seq 1 20))
LONG=${LONG% }
{
  sed 's#</main>##' "$FIX"
  cat <<HTML
<h2 id="nowhere">Nowhere</h2>
<h3 id="next">Not a section</h3>
<table class="sortable"><thead><tr><th>Issue</th><th>Item</th><th>Notes</th></tr></thead><tbody>
<tr><td><a href="https://github.com/o/r/issues/77">#77</a></td><td>Nowhere row</td><td></td></tr>
</tbody></table>
<h2>Later: a month or more (again)</h2>
<table class="sortable"><thead><tr><th>Issue</th><th>Item</th><th>Notes</th></tr></thead><tbody>
<tr><td>#1024</td><td>$LONG</td><td>Short note.</td></tr>
<tr><td><a href="https://github.com/o/r/blob/main/x.md">x.md</a></td><td>Blob row</td><td></td></tr>
</tbody></table>
<h2>Open decisions for the operator, part 2</h2>
<table class="sortable"><thead><tr><th>Topic</th><th>Question</th><th>Where</th></tr></thead><tbody>
<tr><td>Extra topic</td><td>Extra question?</td><td>Here</td></tr>
</tbody></table>
</main>
HTML
} > "$V"
OUT=$("$CLI" --project proj-b --file "$V" 2>&1); rc=$?
eq "P4 rc 0" "$rc" 0
has "P4 nowhere is skipped and named" "$OUT" '^roadmap-import: skipped section nowhere$'
has "P4 an h2 with no id falls back to later (3 + 2)" "$OUT" '^roadmap-import: later ideas=5$'
has "P4 an h2 with no id falls back to open (2 + 1)" "$OUT" '^roadmap-import: open decisions=3$'
has "P4 inserted line" "$OUT" '^roadmap-import: inserted ideas=14 links=10 decisions=5 '
eq "P4 the nowhere row is not imported" "$(sql "SELECT COUNT(*) FROM roadmap_ideas WHERE title='Nowhere row' OR link LIKE '%/issues/77'")" 0
eq "P4 the h3 id=next is not a section: no extra next idea" \
  "$(sql "SELECT COUNT(*) FROM roadmap_ideas WHERE project='proj-b' AND lane='next'")" 9
eq "P4 a long title is cut to 197 + ..." \
  "$(sql "SELECT length(title), substr(title, -3) FROM roadmap_ideas WHERE project='proj-b' AND title LIKE 'Long title word%'" | tr '\t' ' ')" "200 ..."
eq "P4 the full title leads the note" \
  "$(sql "SELECT note = ?1 FROM roadmap_ideas WHERE project='proj-b' AND title LIKE 'Long title word%'" "$LONG"$'\n\n''Short note.')" 1
eq "P4 a bare #1024 and a blob URL make no link" \
  "$(sql "SELECT COUNT(*) FROM roadmap_ideas i JOIN roadmap_links l ON l.idea_id=i.id WHERE i.project='proj-b' AND (i.title LIKE 'Long title word%' OR i.title='Blob row')")" 0

echo "P5: usage errors"
CALLS=$(api_calls)
"$CLI" --project cromford >/dev/null 2>&1; eq "P5 missing --file is rc 2" "$?" 2
"$CLI" --file "$FIX" >/dev/null 2>&1; eq "P5 missing --project is rc 2" "$?" 2
"$CLI" >/dev/null 2>&1; eq "P5 no arguments is rc 2" "$?" 2
"$CLI" --project cromford --file "$T/no-such.html" >/dev/null 2>&1; eq "P5 a missing file is rc 2" "$?" 2
"$CLI" --project cromford --file "$FIX" --bogus >/dev/null 2>&1; eq "P5 an unknown flag is rc 2" "$?" 2
"$CLI" --project 'bad project' --file "$FIX" >/dev/null 2>&1; eq "P5 a bad project name is rc 2" "$?" 2
eq "P5 usage errors send nothing" "$(api_calls)" "$CALLS"

echo "P6: the worker refuses"
OUT=$("$CLI" --project no-such-project --file "$FIX" 2>&1); rc=$?
eq "P6 an unknown project is rc 1" "$rc" 1
has "P6 prints the worker's error" "$OUT" 'project no-such-project is not a known project'
hasnt "P6 prints no inserted line as if it worked" "$OUT" '^roadmap-import: inserted'
OUT=$(JOBS_URL='' "$CLI" --project cromford --file "$FIX" 2>&1); rc=$?
eq "P6 an empty JOBS_URL is rc 1" "$rc" 1
has "P6 says JOBS_URL is not set" "$OUT" 'JOBS_URL is not set'

echo "P7: calls of at most 500 rows"
B="$T/big.html"
{
  echo '<html><body><h2 id="later">Later</h2><table class="sortable"><thead><tr><th>Issue</th><th>Item</th><th>Notes</th></tr></thead><tbody>'
  for i in $(seq 1 501); do printf '<tr><td>—</td><td>Big row %s</td><td></td></tr>\n' "$i"; done
  echo '</tbody></table></body></html>'
} > "$B"
CALLS=$(api_calls)
OUT=$("$CLI" --project proj-c --file "$B" 2>&1); rc=$?
eq "P7 rc 0" "$rc" 0
eq "P7 two calls" "$(( $(api_calls) - CALLS ))" 2
has "P7 the counts are summed over the calls" "$OUT" '^roadmap-import: inserted ideas=501 links=0 decisions=0 skipped ideas=0 decisions=0$'
eq "P7 501 rows in the DB" "$(sql "SELECT COUNT(*) FROM roadmap_ideas WHERE project='proj-c'")" 501

echo
echo "roadmap-import: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
