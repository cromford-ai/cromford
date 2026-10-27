#!/bin/bash
# tests/prompt-resolve.bh-7940-test.sh — BH-7969 (BH-7940.0): bin/prompt-resolve.sh
# resolves a prompt to the project head, else the fleet head, else the repo file.
# It runs over real curl against the REAL jobs worker on 127.0.0.1
# (tests/lib/prompts-worker.bh-7969.mjs, node:sqlite). No call leaves the box.
#
#   project-wins     a project head prints its body byte for byte (no newline
#                    added; a CRLF body too).
#   fleet-wins       a fleet head wins for a project with no project head.
#   repo-wins        no head: watcher and rules print the repo file; plan has no
#                    repo file yet, so rc 4 and empty stdout.
#   project-a-not-b  an override on A; B prints its own repo file.
#   worker-down-rc3  closed port, 503 (table dropped), 401 and a URL with no
#                    secret: rc 3 and empty stdout, never the repo default.
#   no-jobs-url      JOBS_URL set and empty: the repo default, rc 0.
#   usage-rc2        bad arg count, kind, project or flag: rc 2.
#   --source         one line `<kind> <source> v<n> <version_id>`.
#   cache-dir        PROMPT_RESOLVE_CACHE_DIR: two resolves, one list call.
# Run from anywhere: tests/prompt-resolve.bh-7940-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "prompt-resolve.bh-7940: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

R="$DIR/bin/prompt-resolve.sh"
SRV="$DIR/tests/lib/prompts-worker.bh-7969.mjs"
SECRET=sec-fixture-7940
[ -x "$R" ] || { bad "bin/prompt-resolve.sh is missing or not executable"; done_; }

PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# start <name> [--drop <table>] — start a worker; sets URL_<name> and CNT_<name>.
start() {
  local name=$1; shift
  : > "$T/$name.port"; : > "$T/$name.count"
  rm -f "$T/$name.port"
  node "$SRV" "$SECRET" "$T/$name.port" "$T/$name.count" "$@" 2>"$T/$name.err" &
  PIDS+=($!)
  local i
  for i in $(seq 1 100); do
    [ -s "$T/$name.port" ] && break
    kill -0 "${PIDS[-1]}" 2>/dev/null || break
    sleep 0.1
  done
  if [ ! -s "$T/$name.port" ]; then
    wait "${PIDS[-1]}"; local rc=$?
    if [ "$rc" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
    bad "worker $name did not start (rc $rc): $(head -3 "$T/$name.err")"; done_
  fi
  printf -v "URL_$name" 'http://127.0.0.1:%s' "$(cat "$T/$name.port")"
  printf -v "CNT_$name" '%s' "$T/$name.count"
}

# post <url> <scope> <kind> <project|-> <body file> — save a version; prints the JSON answer.
post() {
  local q=""; [ "$4" = - ] || q="?project=$4"
  jq -n --rawfile b "$5" '{body:$b, author:"fixture-author"}' > "$T/post.json"
  curl -sS -H "authorization: Bearer $SECRET" -H 'content-type: application/json' \
    --data-binary @"$T/post.json" "$1/api/prompts/$2/$3$q"
}

# marks <kind> — the kind's catalog markers, one per line (BH-7972: a rules
# save without them is a 422). The fixtures put them before their own text.
marks() { jq -r --arg k "$1" '.[$k][]' "$DIR/catalog/prompt-markers.json"; }

ROOTD="$T/repo"
mkdir -p "$ROOTD/rules" "$ROOTD/prompts"
printf 'repo rules\nline two' > "$ROOTD/rules/CLAUDE.md"

# resolve <url> <project> <kind> [args...] — run the resolver; stdout to $T/out, rc to RC.
resolve() {
  local url=$1; shift
  JOBS_URL="$url" HARNESS_SECRET="${RS_SECRET-$SECRET}" PROMPT_RESOLVE_ROOT="$ROOTD" \
    "$R" "$@" > "$T/out" 2> "$T/err"
  RC=$?
}

start main
start drop --drop prompt_heads

# ── project-wins ─────────────────────────────────────────────────────────────
P=demo-x-projectwins
printf 'repo watcher %s\n' "$P" > "$ROOTD/prompts/$P.md"
printf 'hello' > "$T/hello"
A=$(post "$URL_main" project watcher "$P" "$T/hello")
AID=$(jq -r '.id' <<<"$A"); AVER=$(jq -r '.version' <<<"$A")
[ "$AVER" = 1 ] && ok || bad "project-wins: POST answered $A"
resolve "$URL_main" "$P" watcher
[ "$RC" = 0 ] && ok || bad "project-wins: rc $RC ($(cat "$T/err"))"
cmp -s "$T/out" "$T/hello" && ok || bad "project-wins: printed $(od -c "$T/out" | head -2)"
{ marks rules; printf 'a\r\nb\r\n'; } > "$T/crlf"
post "$URL_main" project rules "$P" "$T/crlf" >/dev/null
resolve "$URL_main" "$P" rules
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/crlf" && ok || bad "project-wins: CRLF body did not round-trip (rc $RC)"

# ── --source ─────────────────────────────────────────────────────────────────
resolve "$URL_main" "$P" watcher --source
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "watcher project v1 $AID" ] && [ "$(wc -l < "$T/out")" = 1 ] \
  && ok || bad "--source project: rc $RC '$(cat "$T/out")' (want 'watcher project v1 $AID')"

# ── fleet-wins ───────────────────────────────────────────────────────────────
F=demo-x-fleetwins
{ marks rules; printf 'fleet rules body\n'; } > "$T/fleet"
FA=$(post "$URL_main" fleet rules - "$T/fleet")
FID=$(jq -r '.id' <<<"$FA")
resolve "$URL_main" "$F" rules
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/fleet" && ok || bad "fleet-wins: rc $RC '$(cat "$T/out")'"
resolve "$URL_main" "$F" rules --source
[ "$(cat "$T/out")" = "rules fleet v1 $FID" ] && ok || bad "--source fleet: '$(cat "$T/out")' (want 'rules fleet v1 $FID')"
# The project head still beats the fleet head for P.
resolve "$URL_main" "$P" rules
cmp -s "$T/out" "$T/crlf" && ok || bad "fleet-wins: the fleet head beat P's project head"

# ── repo-wins (a separate worker with no fleet head) ─────────────────────────
start empty
G=demo-x-repowins
printf 'repo watcher for %s\n' "$G" > "$ROOTD/prompts/$G.md"
resolve "$URL_empty" "$G" watcher
[ "$RC" = 0 ] && cmp -s "$T/out" "$ROOTD/prompts/$G.md" && ok || bad "repo-wins watcher: rc $RC '$(cat "$T/out")'"
resolve "$URL_empty" "$G" rules
[ "$RC" = 0 ] && cmp -s "$T/out" "$ROOTD/rules/CLAUDE.md" && ok || bad "repo-wins rules: rc $RC '$(cat "$T/out")'"
resolve "$URL_empty" "$G" plan
[ "$RC" = 4 ] && [ ! -s "$T/out" ] && grep -q 'prompts/stages/plan.md' "$T/err" && ok \
  || bad "repo-wins plan: want rc 4, empty stdout, the path in stderr; rc $RC '$(cat "$T/out")' '$(cat "$T/err")'"
resolve "$URL_empty" "$G" watcher --source
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "watcher repo v0 -" ] && ok || bad "--source repo: rc $RC '$(cat "$T/out")'"

# ── project-a-not-b ──────────────────────────────────────────────────────────
PA=demo-x-anotb; PB=demo-y-anotb
printf 'repo %s\n' "$PB" > "$ROOTD/prompts/$PB.md"
printf 'only for A' > "$T/a"
post "$URL_empty" project watcher "$PA" "$T/a" >/dev/null
resolve "$URL_empty" "$PA" watcher
cmp -s "$T/out" "$T/a" && ok || bad "project-a-not-b: A does not print its override"
resolve "$URL_empty" "$PB" watcher
[ "$RC" = 0 ] && cmp -s "$T/out" "$ROOTD/prompts/$PB.md" && ok || bad "project-a-not-b: B printed '$(cat "$T/out")' rc $RC"

# ── worker-down-rc3 ──────────────────────────────────────────────────────────
D=demo-x-down
printf 'repo %s\n' "$D" > "$ROOTD/prompts/$D.md"
CLOSED=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
resolve "http://127.0.0.1:$CLOSED" "$D" watcher
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && ok || bad "worker-down: closed port rc $RC '$(cat "$T/out")'"
resolve "$URL_drop" "$D" watcher
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && ok || bad "worker-down: 503 rc $RC '$(cat "$T/out")'"
RS_SECRET=wrong-fixture resolve "$URL_main" "$D" watcher
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && ok || bad "worker-down: 401 rc $RC '$(cat "$T/out")'"
RS_SECRET='' resolve "$URL_main" "$D" watcher
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && grep -q 'no HARNESS_SECRET' "$T/err" && ok || bad "worker-down: no secret rc $RC '$(cat "$T/err")'"
# A cached list names the next three rc-3 paths: a head whose version read is
# 404, a list with no row for the kind, and a list jq cannot read.
mkdir -p "$T/plant"
printf '{"project":"%s","prompts":[{"kind":"watcher","source":"project","version":9,"version_id":99}]}' "$D" > "$T/plant/list-$D.json"
PROMPT_RESOLVE_CACHE_DIR="$T/plant" resolve "$URL_main" "$D" watcher
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && ok || bad "worker-down: a 404 version read rc $RC '$(cat "$T/out")'"
PROMPT_RESOLVE_CACHE_DIR="$T/plant" resolve "$URL_main" "$D" rules
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && ok || bad "worker-down: no row for the kind rc $RC '$(cat "$T/out")'"
printf '{not json' > "$T/plant/list-$D.json"
PROMPT_RESOLVE_CACHE_DIR="$T/plant" resolve "$URL_main" "$D" watcher
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && ok || bad "worker-down: unreadable list rc $RC '$(cat "$T/out")'"

# ── no-jobs-url ──────────────────────────────────────────────────────────────
resolve "" "$D" watcher
[ "$RC" = 0 ] && cmp -s "$T/out" "$ROOTD/prompts/$D.md" && ok || bad "no-jobs-url: rc $RC '$(cat "$T/out")'"

# ── usage-rc2 ────────────────────────────────────────────────────────────────
for args in "" "only-one" "a b c" "$D deploy" "../x watcher" "$D watcher --bogus" "_fleet watcher"; do
  # shellcheck disable=SC2086
  resolve "$URL_main" $args
  [ "$RC" = 2 ] && [ ! -s "$T/out" ] && ok || bad "usage-rc2: '$args' rc $RC"
done

# ── cache-dir ────────────────────────────────────────────────────────────────
C=demo-x-cache
printf 'cache body' > "$T/c"
post "$URL_main" project watcher "$C" "$T/c" >/dev/null
mkdir -p "$T/cache"
before=$(wc -l < "$CNT_main")
PROMPT_RESOLVE_CACHE_DIR="$T/cache" resolve "$URL_main" "$C" watcher
r1=$RC; cmp -s "$T/out" "$T/c"; s1=$?
PROMPT_RESOLVE_CACHE_DIR="$T/cache" resolve "$URL_main" "$C" rules
after=$(wc -l < "$CNT_main")
[ "$r1" = 0 ] && [ "$s1" = 0 ] && [ "$RC" = 0 ] && [ $((after - before)) = 1 ] && ok \
  || bad "cache-dir: rc $r1/$RC, list calls $((after - before)) (want 1)"
[ -s "$T/cache/list-$C.json" ] && ok || bad "cache-dir: no list-$C.json in the cache dir"
# Without the cache dir every resolve makes its own list call.
before=$(wc -l < "$CNT_main")
resolve "$URL_main" "$C" watcher; resolve "$URL_main" "$C" rules
after=$(wc -l < "$CNT_main")
[ $((after - before)) = 2 ] && ok || bad "cache-dir: unset made $((after - before)) list calls (want 2)"

done_
