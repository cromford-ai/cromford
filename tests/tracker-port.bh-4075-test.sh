#!/bin/bash
# tests/tracker-port.bh-4075-test.sh — BH-4075: which tracker a project uses is
# a settings row, and the two child filers moved onto the tracker adapters with
# no behaviour change.
#
#   P1  no settings row: tracker_adapter is fleet.conf column 4 (- = github-issues)
#   P2  a row wins over column 4, both ways
#   P3  a row naming no registered adapter: rc 1, file_children files nothing
#   P4  worker 503, and no HARNESS_SECRET at all: the column-4 fallback, and
#       with no secret not one settings request
#   P5  sourcing bin/lib/tracker.sh twice under set -u: silent, inert
#   B1  the real bin/run-decompose.sh dry run is byte-identical to the BH-982 fixtures
#   B2  the real bin/run-rollout.sh on a board: decompose-board.log, comment.json,
#       move.json and the call sequence byte-identical to pre-port main
#   B3  a real (non-dry) issues split and its complete rerun: the gh call
#       sequence is pre-port main's, with no extra read
#   B4  the move's "did it take" check lives in the adapter now: break it in a
#       scratch copy and the master reads as moved when it was not
#
# The B2/B3 goldens under tests/fixtures/tracker-port/ were captured from the
# pre-port tree by this suite itself:
#   TRACKER_PORT_REGEN=<git ref> HARNESS_TEST_SANDBOX=1 bash tests/tracker-port.bh-4075-test.sh
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-port.bh-4075-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

GOLD="$DIR/tests/fixtures/tracker-port"
TOKEN=tok-FIXTURE-SENTINEL-4075
mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/logs" "$T/h/prompts" "$T/stub" "$T/s"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish   example-org/scoutish   https://scoutish.example  -                               9 box-1 10.0.0.9
ledger-os  example-org/ledger-os  https://ledger.example    /api/accounting/requests-board  3 box-1 10.0.0.3
CONF
cat > "$T/h/env/ledger-os.env" <<CONF
LEDGER_API_BASE=https://ledger.example
LEDGER_INTERNAL_API_TOKEN=$TOKEN
CONF
cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"
BASE="https://ledger.example/api/accounting/requests-board"

# ---- curl: the settings worker and the board ---------------------------------
# Logs `<METHOD> <url>` per call (never the argv: the token rides there) and
# keeps every request body by sequence number.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$STUB_STATE"; m=GET; url=""; data=""; fmt=""; k=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary) data="${2#@}"; shift ;;
    -w) fmt="$2"; shift ;;
    -m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in Idempotency-Key:*) k="${2##*-}" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$m" "$url" >> "$S/curl.log"
seq=$(wc -l < "$S/curl.log" | tr -d ' ')
[ -n "$data" ] && [ -r "$data" ] && cp "$data" "$S/body-$seq.json"
case "$url" in
  https://jobs.example/*)
    key="${url##*/}"; f="$S/setting-$key"
    if [ -r "$f" ]; then code=$(head -1 "$f"); body=$(sed -n '2,$p' "$f"); else code=404; body='{"error":"no route"}'; fi
    printf '%s' "$body"; printf '%s' "$fmt" | sed "s/%{http_code}/$code/g"; exit 0 ;;
esac
case "$m $url" in
  "GET "*/boards) cat "$S/boards.json" ;;
  "GET "*/tickets/*) cat "$S/parent.json" ;;
  "POST "*/boards/*/tickets) printf '{"ticket":{"id":"cmChild0%s","key":"LG-10%s","url":"https://ledger.example/board/LG-10%s"}}\n' "$k" "$k" "$k" ;;
  "POST "*/comments) printf '{"ok":true}\n' ;;
  "POST "*/move)
    if [ -e "$S/move-noecho" ]; then printf '{"ticket":{"status":"todo"}}\n'
    else printf '{"ticket":{"status":"in_progress"}}\n'; fi ;;
  *) exit 22 ;;
esac
exit 0
SH
# ---- gh: the issues lane -----------------------------------------------------
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
S="$STUB_STATE"
send() { printf 'HTTP/2.0 %s\r\n\r\n%s\n' "$1" "$2"; exit 0; }
if [ "$1 $2" = "api -i" ]; then
  printf 'api %s %s\n' "$4" "$5" >> "$S/gh.log"
  case "$4 $5" in
    "GET repos/example-org/scoutish/issues/552") send 200 '{"labels":[{"name":"ai-build"},{"name":"hotfix"}]}' ;;
    "GET repos/example-org/scoutish/issues/"*)
      n="${5##*/}"; send 200 "$(jq -nc --arg t "$(sed -n "${n#70}p" "$S/titles")" '{title:$t}')" ;;
    "POST "*/comments) send 201 '{"id":1}' ;;
    "DELETE "*) send 200 '[]' ;;
  esac
  send 404 '{}'
fi
if [ "$1 $2" = "issue create" ]; then
  t=""; while [ $# -gt 0 ]; do case "$1" in --title) t="$2"; shift ;; esac; shift; done
  printf 'issue create %s\n' "$t" >> "$S/gh.log"
  n=$(grep -nxF -- "$t" "$S/titles" | cut -d: -f1)
  echo "https://github.com/example-org/scoutish/issues/70$n"; exit 0
fi
exit 0
SH
chmod +x "$T/stub/curl" "$T/stub/gh"
printf 'TK-552.0: contract — metrics table + read API\nTS-552.1: dashboard tile\n' > "$T/s/titles"
jq -n '{ticket: {id: "cmParent01", key: "LG-9", priority: "high", status: "todo",
  description: "<p>Ship the ledger export.</p>\n\n## Rollout\n\n### Wave 1: Schema\nAdd the export table.\n\n### Wave 2: API\nafter: Schema\nServe the export.\n\n### Wave 3: UI\nafter: Schema, API\nShow it & <b>bold</b>.\n"}}' > "$T/s/parent.json"
printf '[{"id":"rb-1","capabilities":["dependencies"]}]\n' > "$T/s/boards.json"

run_env() { # run_env [VAR=v …] cmd … — the scratch harness, the stubs, no secret
  env -u HARNESS_SECRET HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH" STUB_STATE="$T/s" \
      AGENT_LOG="$T/agent.log" GH_ETAG=0 JOBS_URL=https://jobs.example JOBS_RETRIES=0 "$@"
}
reset_stub() { rm -f "$T/s/curl.log" "$T/s/gh.log" "$T/s"/body-*.json "$T/s"/setting-* "$T/s/move-noecho"; }
norm() { sed "s#$2#<BUILD>#g" "$1"; }

# drive_board <checkout> <build> [VAR=v …] — the real bin/run-rollout.sh
drive_board() {
  local co="$1" b="$2"; shift 2
  reset_stub; scratch_rm "$b"; mkdir -p "$b"
  run_env "$@" "$co/bin/run-rollout.sh" ledger-os cmParent01 LG-9 "$b" >/dev/null 2>&1
}
# drive_issues <checkout> <build> — the real bin/run-decompose.sh, not a dry run
SPEC='[{"title":"metrics table + read API","contract":"src/db/metrics.ts: MetricRow","after":[],"body":"Create the table.\n\nFiles: src/db/metrics.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile.\n\nFiles: src/app/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."}]'
drive_issues() {
  local co="$1" b="$2"
  mkdir -p "$b"; printf '%s\n' "$SPEC" > "$b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$b/size-gate.txt"
  run_env "$co/bin/run-decompose.sh" scoutish 552 TK-552 "$b" 300 12 >/dev/null 2>&1
}
# The two B3 runs into one call sequence: a fresh split, then its complete rerun.
issues_calls() {
  local co="$1" b="$2"
  reset_stub; scratch_rm "$b"; drive_issues "$co" "$b"; cp "$T/s/gh.log" "$T/gh.first"
  reset_stub; drive_issues "$co" "$b"
  { cat "$T/gh.first"; echo '-- rerun'; cat "$T/s/gh.log"; }
}
capture_board() { # capture_board <checkout> <outdir>
  local co="$1" o="$2"
  mkdir -p "$o/real" "$o/dry"
  drive_board "$co" "$T/bb"
  norm "$T/bb/decompose-board.log" "$T/bb" > "$o/real/decompose-board.log"
  cp "$T/bb/children/comment.json" "$T/bb/children/move.json" "$o/real/"
  cp "$T/s/curl.log" "$o/real/calls.txt"
  drive_board "$co" "$T/bb" FILE_CHILDREN_DRY_RUN=1
  norm "$T/bb/decompose-board.log" "$T/bb" > "$o/dry/decompose-board.log"
  cp "$T/bb/children/comment.json" "$T/bb/children/move.json" "$o/dry/"
}

if [ -n "${TRACKER_PORT_REGEN:-}" ]; then
  mkdir -p "$T/ref"
  git -C "$DIR" archive "$TRACKER_PORT_REGEN" bin | tar -x -C "$T/ref" || { echo "cannot archive $TRACKER_PORT_REGEN"; exit 1; }
  # Captured into the scratch tree, then copied over the fixtures (no rm
  # outside $T): every golden name is fixed, so nothing stale can survive.
  mkdir -p "$T/gold/issues"
  capture_board "$T/ref" "$T/gold/board"
  issues_calls "$T/ref" "$T/bi" > "$T/gold/issues/gh-calls.txt"
  mkdir -p "$GOLD" && cp -R "$T/gold/." "$GOLD/"
  echo "regenerated $GOLD from $(git -C "$DIR" rev-parse "$TRACKER_PORT_REGEN")"
  exit 0
fi

LIB="$DIR/bin/lib/tracker.sh"
adapter() { # adapter <project> [VAR=v …] — tracker_adapter's stdout, then `rc=N`
  local p="$1"; shift
  run_env "$@" bash -c 'set -u; . "$1" || exit 9; tracker_adapter "$2"; echo "rc=$?"' _ "$LIB" "$p" 2>"$T/adapter.err"
}
row() { printf '200\n{"setting":{"key":"tracker_adapter.%s","value":"%s"}}\n' "$1" "$2" > "$T/s/setting-tracker_adapter.$1"; }
settings_calls() { cat "$T/s/curl.log" 2>/dev/null | grep -c 'jobs.example/api/settings/'; }

# --- P1 -------------------------------------------------------------------
reset_stub
[ "$(adapter scoutish HARNESS_SECRET=x | tr '\n' ' ')" = "github-issues rc=0 " ] && ok || bad "P1 no row, '-' project: $(adapter scoutish HARNESS_SECRET=x)"
[ "$(adapter ledger-os HARNESS_SECRET=x | tr '\n' ' ')" = "board rc=0 " ] && ok || bad "P1 no row, prefix project: $(adapter ledger-os HARNESS_SECRET=x)"
[ "$(settings_calls)" -ge 2 ] && ok || bad "P1 the row was never asked for: $(cat "$T/s/curl.log" 2>/dev/null)"
[ "$(adapter nowhere HARNESS_SECRET=x | tr '\n' ' ')" = "rc=1 " ] && ok || bad "P1 an unknown project is rc 1 with nothing printed"

# --- P2 -------------------------------------------------------------------
reset_stub; row scoutish board; row ledger-os github-issues
[ "$(adapter scoutish HARNESS_SECRET=x | tr '\n' ' ')" = "board rc=0 " ] && ok || bad "P2 row board on a '-' project: $(adapter scoutish HARNESS_SECRET=x)"
[ "$(adapter ledger-os HARNESS_SECRET=x | tr '\n' ' ')" = "github-issues rc=0 " ] && ok || bad "P2 row github-issues on a prefix project: $(adapter ledger-os HARNESS_SECRET=x)"

# --- P3 -------------------------------------------------------------------
for v in jira-server Board; do
  reset_stub; row scoutish "$v"
  [ "$(adapter scoutish HARNESS_SECRET=x | tr '\n' ' ')" = "rc=1 " ] && ok || bad "P3 row '$v' must be rc 1 with nothing printed: $(adapter scoutish HARNESS_SECRET=x)"
  grep -q "tracker_adapter.scoutish is '$v'" "$T/adapter.err" && ok || bad "P3 row '$v': one stderr line naming the row: $(cat "$T/adapter.err")"
  B="$T/p3-$v"; scratch_rm "$B"; mkdir -p "$B"; printf '%s\n' "$SPEC" > "$B/children.json"
  reset_stub; row scoutish "$v"
  run_env HARNESS_SECRET=x bash -c '. "$1" || exit 9; file_children scoutish 552 TK-552 "$2" "$2/children.json"' _ "$DIR/bin/lib/file-children.sh" "$B" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && ok || bad "P3 row '$v': file_children rc=$rc, want 1"
  grep -q 'FILE_CHILDREN tracker adapter unresolved for scoutish' "$B/pipeline.log" 2>/dev/null && ok || bad "P3 row '$v': pipeline.log: $(cat "$B/pipeline.log" 2>/dev/null)"
  [ ! -s "$T/s/gh.log" ] && [ "$(grep -vc 'jobs.example' "$T/s/curl.log")" = 0 ] && ok || bad "P3 row '$v': a tracker was called: $(cat "$T/s/gh.log" "$T/s/curl.log" 2>/dev/null)"
  [ ! -e "$B/children.txt" ] && ok || bad "P3 row '$v': children.txt written"
done

# --- P4 -------------------------------------------------------------------
reset_stub; printf '503\n{"error":"down"}\n' > "$T/s/setting-tracker_adapter.scoutish"
[ "$(adapter scoutish HARNESS_SECRET=x | tr '\n' ' ')" = "github-issues rc=0 " ] && ok || bad "P4 worker 503 must fall back to column 4: $(adapter scoutish HARNESS_SECRET=x)"
[ "$(settings_calls)" -ge 1 ] && ok || bad "P4 the 503 arm never reached the worker"
reset_stub; row scoutish board
[ "$(adapter scoutish | tr '\n' ' ')" = "github-issues rc=0 " ] && ok || bad "P4 no secret must fall back to column 4: $(adapter scoutish)"
[ "$(settings_calls)" = 0 ] && ok || bad "P4 no secret, yet the worker was asked: $(cat "$T/s/curl.log")"

# --- P5 -------------------------------------------------------------------
mkdir -p "$T/p5"
OUT=$(cd "$T/p5" && env -u HARNESS -u H bash -c 'set -u; . "$1"; . "$1"; declare -F tracker_read >/dev/null && echo READY' _ "$LIB" 2>&1)
[ "$OUT" = READY ] && ok || bad "P5 sourcing twice must print nothing and define tracker_read: [$OUT]"
[ -z "$(ls -A "$T/p5")" ] && ok || bad "P5 sourcing wrote a file: $(ls -A "$T/p5")"
grep -nE '^[[:space:]]*(set -e|exit)([[:space:]]|$)' "$LIB" "$DIR/bin/lib/tracker/"*.sh && bad "P5 a sourced lib may never exit or set -e" || ok

# --- B1 -------------------------------------------------------------------
FIX="$DIR/tests/fixtures/fc-issues"
for SET in two-plain two-after five-plain five-after; do
  B="$T/b1"; scratch_rm "$B"; mkdir -p "$B"; cp "$FIX/$SET/children.json" "$B/"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$B/size-gate.txt"
  reset_stub
  run_env DECOMPOSE_DRY_RUN=1 "$DIR/bin/run-decompose.sh" scoutish 552 TK-552 "$B" 300 12 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && ok || bad "B1 $SET: dry run rc=$rc: $(tail -3 "$B/pipeline.log" 2>/dev/null)"
  for F in "$FIX/$SET"/child-*.md; do
    cmp -s "$B/children/${F##*/}" "$F" && ok || bad "B1 $SET ${F##*/} drifted: $(diff "$F" "$B/children/${F##*/}" 2>&1 | head -5)"
  done
  norm "$B/decompose-gh.log" "$B" > "$T/b1.gh"
  cmp -s "$T/b1.gh" "$FIX/$SET/gh.log" && ok || bad "B1 $SET decompose-gh.log drifted: $(diff "$FIX/$SET/gh.log" "$T/b1.gh" 2>&1 | head -5)"
  [ ! -s "$T/s/gh.log" ] && ok || bad "B1 $SET: a dry run called gh: $(cat "$T/s/gh.log")"
done

# --- B2 -------------------------------------------------------------------
capture_board "$DIR" "$T/b2"
for f in real/decompose-board.log real/comment.json real/move.json real/calls.txt dry/decompose-board.log dry/comment.json dry/move.json; do
  [ -s "$GOLD/board/$f" ] || { bad "B2 golden $f is missing"; continue; }
  cmp -s "$T/b2/$f" "$GOLD/board/$f" && ok || bad "B2 $f drifted from pre-port main: $(diff "$GOLD/board/$f" "$T/b2/$f" 2>&1 | head -8)"
done
LEAK=$(grep -rlF -- "$TOKEN" "$T/bb" "$T/b2" "$T/s" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "B2 the token reached: $LEAK"

# --- B3 -------------------------------------------------------------------
issues_calls "$DIR" "$T/b3" > "$T/b3.calls"
if [ -s "$GOLD/issues/gh-calls.txt" ]; then
  cmp -s "$T/b3.calls" "$GOLD/issues/gh-calls.txt" && ok || bad "B3 the gh call sequence drifted from pre-port main: $(diff "$GOLD/issues/gh-calls.txt" "$T/b3.calls" 2>&1 | head -10)"
else
  bad "B3 golden gh-calls.txt is missing"
fi
# fc_parent_labels is the single issue GET: the adapter's full read would also
# page the thread, and that is a call (and quota) main never spent.
[ "$(sed -n '1,/^-- rerun$/p' "$T/b3.calls" | grep -c '^api GET repos/example-org/scoutish/issues/552$')" = 1 ] && ok || bad "B3 a fresh split reads the parent once: $(cat "$T/b3.calls")"
grep -q '^api GET .*/comments$' "$T/b3.calls" && bad "B3 a comment list was read: $(cat "$T/b3.calls")" || ok
grep -q 'unlabelled (master of split)' "$T/b3/pipeline.log" && ok || bad "B3 the parent was not parked: $(tail -5 "$T/b3/pipeline.log")"

# --- B4 -------------------------------------------------------------------
# The real adapter against a board that answers 200 without moving the master.
reset_stub; touch "$T/s/move-noecho"; scratch_rm "$T/b4"; mkdir -p "$T/b4"
run_env "$DIR/bin/run-rollout.sh" ledger-os cmParent01 LG-9 "$T/b4" >/dev/null 2>&1
grep -q 'WARN: children are filed but the move of the master cmParent01 to in_progress did not take (curl rc=0)' "$T/b4/pipeline.log" \
  && ok || bad "B4 a 200 that did not move the master must WARN naming curl rc=0: $(grep -i move "$T/b4/pipeline.log")"
grep -q 'moved to in_progress' "$T/b4/pipeline.log" && bad "B4 the master read as moved" || ok
# The same run with the adapter's check broken: if fc-board still made the call
# itself, this copy would change nothing.
mkdir -p "$T/mut"; cp -R "$DIR/bin" "$T/mut/"
sed -i 's/\[ "\$TRK_CURL_RC" = 0 \] && grep -q "\\"\$s\\"" <<<"\$resp" || return 1/true/' "$T/mut/bin/lib/tracker/board.sh"
cmp -s "$T/mut/bin/lib/tracker/board.sh" "$DIR/bin/lib/tracker/board.sh" && bad "B4 the mutation did not apply" || ok
reset_stub; touch "$T/s/move-noecho"; scratch_rm "$T/b4m"; mkdir -p "$T/b4m"
run_env "$T/mut/bin/run-rollout.sh" ledger-os cmParent01 LG-9 "$T/b4m" >/dev/null 2>&1
grep -q 'master cmParent01 moved to in_progress' "$T/b4m/pipeline.log" && ok || bad "B4 with the adapter's check broken the master must read as moved: $(grep -i move "$T/b4m/pipeline.log")"

echo "tracker-port.bh-4075: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
