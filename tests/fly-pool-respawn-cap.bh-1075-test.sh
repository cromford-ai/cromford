#!/bin/bash
# tests/fly-pool-respawn-cap.bh-1075-test.sh — Fly pool stops re-spawning a
# ticket whose push was rejected, and gates every new spawn on HOLD, an existing
# open PR, a terminal push-rejected state, and a per-key spawn cap.
#
# The file anchors wall-clock time in $NOW; every fixture timestamp is derived
# from that one value so the suite does not flake on calendar drift.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_PROJECT_5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/hold.sh"
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"

cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

# run_pool_keep: same tick, but ALERTS.log survives — a page that repeats every
# tick is only visible across two of them, and "one ALERTS line" is what the
# ticket asked for.
run_pool_keep() {
  : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_PROJECT_5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_PROJECT_5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

# Fly stub: supports reap reads, machine run, and a no-op ssh console / sftp.
write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}

# gh stub: REST reads (-i) for branch head and PR list; plain reads for hold;
# a GraphQL `gh issue comment` lands in ${T}/gh-sink.txt and a REST comment POST
# in ${T}/gh-post.txt (its body in ${T}/gh-post-body.txt). The two sinks are
# separate on purpose: the assertions below want the REST one written and the
# GraphQL one to stay empty, and one shared sink could not tell them apart.
# $5 is a file of comment JSON to serve instead of the `hold` fixture.
# $6 is the issue BODY the hold gate reads (BH-1461: a body decides only when no
# comment does, and only an explicit HOLD line in it counts). $7 is the TITLE,
# which still takes the word anywhere in it — the arm case s2 drives. Keep
# fixture bodies and titles free of `"` and `\` — both are interpolated into a
# JSON literal here.
write_gh_stub() {
  local head_sha="${1:-}" pr_count="${2:-0}" issue_state="${3:-open}" hold="${4:-0}" comments="${5:-}" \
        issue_body="${6:-}" issue_title="${7:-}"
  cat > "$T/fakebin/gh" <<GH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in issue) echo "\$*" >> "${T}/gh-sink.txt"; exit 0 ;; esac
done
if [[ "\$*" == *"issues/"*"/comments"* ]] && [[ "\$*" == *"body=@"* ]]; then
  for a in "\$@"; do
    case "\$a" in body=@*) cp "\${a#body=@}" "${T}/gh-post-body.txt" 2>/dev/null ;; esac
  done
  echo "\$*" >> "${T}/gh-post.txt"
  echo '{"id":1}'
  exit 0
fi
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then
  if [ -n "$comments" ] && [ -f "$comments" ]; then
    cat "$comments"
  elif [ "$hold" = 1 ]; then
    echo '[{"created_at":"$(date -u -d @$((NOW+1)) '+%Y-%m-%dT%H:%M:%SZ')","body":"HOLD — do not build","user":{"type":"User"}}]'
  else
    echo '[]'
  fi
  exit 0
fi
if [[ "\$*" == *"issues/1016"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"$issue_state","labels":[{"name":"ai-build"}],"title":"$issue_title","body":"$issue_body"}'
  exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'
    exit 0
  fi
  if [[ "\$*" == *"git/ref/heads/ticket/bh-1016"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'
    [ -n "$head_sha" ] && echo "{\"object\":{\"sha\":\"$head_sha\"}}" || echo '{}'
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"head="* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'
    if [ "$pr_count" = 0 ]; then echo '[]'; else
      echo '[{"number":55,"state":"open","html_url":"https://github.com/example-org/project-5/pull/55","head":{"ref":"ticket/bh-1016","repo":{"full_name":"example-org/project-5"}}}]'
    fi
    exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'
  exit 0
fi
exit 0
GH
  chmod +x "$T/fakebin/gh"
}

# Reset the fixture state between cases. EVERY removal goes through the scratch
# library's scratch_rm, which refuses any path that does not realpath under
# $SCRATCH — so checks/tests-scratch-only/check.sh can prove by reading the text
# that nothing outside the scratch tree is ever recursively removed. A bare
# `rm -rf "$H/..."` reads identically at runtime and is exactly the shape that
# wiped a live harness on 2026-09-15; it is an R2 hit here for that reason.
reset_state() { # reset_state [builds]
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  if [ "${1:-}" = builds ]; then
    for p in "$H/builds"/*; do [ -e "$p" ] && scratch_rm "$p"; done
  fi
  return 0
}

queue_bh1016() {
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/build-queue/project-5/BH-1016.json"
}

# ── a: push-rejected BUILD_DEFERRED becomes terminal, not requeued ───────────
{
  write_fly_stub "BUILD_DEFERRED push of ticket/bh-1016 rejected TIER: 2 (lease fail)"
  write_gh_stub "" 0
  # NO QUEUED ROW, on purpose: the spawn that produced the machine below already
  # consumed it, and what this case asserts is that the reap does not put one
  # BACK. Seeding one made the assertion ambiguous the moment the terminal gate
  # started KEEPING the row it skips (case h) — a present file would then mean
  # either "requeued" or "never consumed", which is not an assertion.
  jq -nc --arg m "m-abc123" --arg k "BH-1016" --arg t "1016" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/fly-pool/project-5/m-abc123.json"
  run_pool
  [ -f "$H/state/pool/project-5/BH-1016.terminal" ] \
    && ok "a: terminal file written" || bad "a: no terminal file written"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && bad "a: queue file was re-created" || ok "a: queue file not re-created"
  grep -q 'terminal BH-1016: push rejected' "$H/logs/fly-pool.log" \
    && ok "a: terminal reason logged" || bad "a: terminal reason missing from log"
  BD=$(ls -d "$H/builds/pool-project-5-BH-1016-"* 2>/dev/null | head -1)
  [ -n "$BD" ] && [ -f "$BD/TERMINAL" ] && [ -f "$BD/COMMENTED" ] \
    && ok "a: build-dir sentinels written" || bad "a: missing TERMINAL/COMMENTED sentinel"
}

# ── b: a changed remote head re-arms exactly once ──────────────────────────
{
  reset_state
  write_fly_stub ""
  write_gh_stub "newsha456" 0
  queue_bh1016
  jq -nc --arg sha "oldsha123" --arg ts "$(date -u -d @$((NOW-86400)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/bh-1016",head_sha:$sha,reason:"push rejected",created_at:$ts}' \
    > "$H/state/pool/project-5/BH-1016.terminal"
  run_pool
  N1=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N1" = 1 ] && ok "b: exactly one spawn on changed head" || bad "b: expected 1 spawn, got $N1"
  grep -q 'terminal BH-1016: remote head changed' "$H/logs/fly-pool.log" \
    && ok "b: re-arm logged" || bad "b: re-arm not logged"
  [ ! -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "b: queue file consumed by the re-armed spawn" || bad "b: queue file still present after spawn"
  # second tick: no queued row -> no new spawn
  : > "$H/logs/fly-pool.log"
  write_gh_stub "newsha456" 0
  run_pool
  N2=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N2" = 1 ] && ok "b: no second spawn when head is unchanged" || bad "b: expected 1 machine, got $N2"
}

# ── c: an open PR for the branch comments once and parks the row ───────────
{
  reset_state
  write_fly_stub ""
  write_gh_stub "prheadsha" 1
  queue_bh1016
  rm -f "$T/gh-sink.txt" "$T/gh-post.txt" "$T/gh-post-body.txt"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "c: no machine spawned when open PR exists" || bad "c: expected 0 spawns, got $N"
  [ ! -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "c: queue file removed" || bad "c: queue file not removed"
  # THE COMMENT IS REST, NEVER `gh issue comment`. That subcommand resolves the
  # issue and posts through the GraphQL addComment mutation — two calls on the
  # 5000/hr bucket this whole file was moved off (BH-709, the pr_state_rest
  # comment above gh_rest_read). The GraphQL sink must stay EMPTY.
  [ -s "$T/gh-post.txt" ] \
    && ok "c: comment posted over REST" || bad "c: no REST comment POST recorded"
  grep -q 'repos/example-org/project-5/issues/1016/comments' "$T/gh-post.txt" 2>/dev/null \
    && ok "c: REST comment went to the ticket's comments endpoint" \
    || bad "c: REST comment path wrong: $(cat "$T/gh-post.txt" 2>/dev/null)"
  [ ! -s "$T/gh-sink.txt" ] \
    && ok "c: no GraphQL gh issue comment" || bad "c: gh issue comment (GraphQL) was used: $(cat "$T/gh-sink.txt")"
  # ...and it names the PR, in words a client reading their own board can use.
  grep -q '#55' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "c: the comment names the PR number" || bad "c: comment body does not name the PR: $(cat "$T/gh-post-body.txt" 2>/dev/null)"
  grep -q 'https://github.com/example-org/project-5/pull/55' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "c: the comment carries the PR link" || bad "c: comment body has no PR link"
  [ -f "$H/state/pool/project-5/BH-1016.pr-noted" ] \
    && ok "c: pr-noted sentinel written" || bad "c: no pr-noted sentinel"
  grep -q 'skipping BH-1016: open PR exists' "$H/logs/fly-pool.log" \
    && ok "c: open-PR skip logged" || bad "c: open-PR skip missing from log"
}

# ── c2: an unreadable PR-list REST read skips spawn and retries next tick ───
{
  reset_state
  write_fly_stub ""
  cat > "$T/fakebin/gh" <<'GC'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/1016"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'
  exit 0
fi
if [[ "$*" == *"-i"* ]] && [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"pulls"* ]] && [[ "$*" != *"git/ref"* ]]; then
  printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'
  exit 0
fi
if [[ "$*" == *"-i"*"git/ref/heads/ticket/bh-1016"* ]]; then
  printf 'HTTP/1.1 200 OK\n\n{"object":{"sha":"somehead"}}\n'
  exit 0
fi
if [[ "$*" == *"-i"*"pulls?state=open"*"head="* ]]; then
  printf 'HTTP/1.1 403 Forbidden\n\n{"message":"API rate limit exceeded"}\n'
  exit 0
fi
exit 0
GC
  chmod +x "$T/fakebin/gh"
  queue_bh1016
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "c2: no machine spawned when PR check is unreadable" || bad "c2: expected 0 spawns, got $N"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "c2: queue file left for retry" || bad "c2: queue file unexpectedly removed"
  grep -q 'skipping BH-1016: PR check unreadable' "$H/logs/fly-pool.log" \
    && ok "c2: unreadable PR skip logged" || bad "c2: unreadable PR skip missing from log"
}

# ── d: per-key spawn cap keeps the row queued with one ALERTS line ─────────
# BH-4859: the cap is a timed retry, not a park. The row used to be removed
# here and closed `failed … deferred to a human`, which nothing ever read.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "" 0
  queue_bh1016
  # two timestamps inside the window, one outside it
  { echo "$((NOW-3600))"; echo "$((NOW-1800))"; echo "$((NOW-90000))"; } > "$H/state/pool/project-5/BH-1016.spawns"
  run_pool POOL_SPAWN_CAP_PER_KEY=2 POOL_SPAWN_CAP_WINDOW_S=86400
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "d: no spawn when cap reached" || bad "d: expected 0 spawns, got $N"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "d: queue file kept at cap" || bad "d: queue file removed at cap"
  grep -q 'POOL_SPAWN_CAP_WAIT' "$H/logs/ALERTS.log" \
    && ok "d: ALERTS line written" || bad "d: no ALERTS line"
  [ -f "$H/state/pool/project-5/BH-1016.defer-to-human" ] \
    && ok "d: defer-to-human sentinel written" || bad "d: no defer-to-human sentinel"
  grep -q 'skipping BH-1016: spawn cap reached' "$H/logs/fly-pool.log" \
    && ok "d: cap skip logged" || bad "d: cap skip missing from log"
  # ONE ALERTS LINE, not one per tick. The queue row comes back whenever the
  # ledger watchdog requeues a claimed-and-abandoned row, and the cap refuses it
  # again; a page written on every refusal is the alert lane's own respawn loop.
  # The .defer-to-human sentinel is what makes the page once — it is written
  # here, so it must also be READ here.
  queue_bh1016
  run_pool_keep POOL_SPAWN_CAP_PER_KEY=2 POOL_SPAWN_CAP_WINDOW_S=86400
  AL=$(grep -c 'POOL_SPAWN_CAP_WAIT' "$H/logs/ALERTS.log")
  [ "$AL" = 1 ] && ok "d: exactly one ALERTS page across two capped ticks" \
    || bad "d: expected 1 POOL_SPAWN_CAP_WAIT line over two ticks, got $AL"
  grep -q 'skipping BH-1016: spawn cap reached' "$H/logs/fly-pool.log" \
    && ok "d: the second capped tick still logs the refusal" \
    || bad "d: second capped tick did not log its refusal"
  # ...and the page must come BACK once the key is under the cap again, or the
  # sentinel is a permanent mute rather than a one-shot.
  scratch_rm "$H/state/pool/project-5/BH-1016.spawns"
  queue_bh1016
  run_pool_keep POOL_SPAWN_CAP_PER_KEY=2 POOL_SPAWN_CAP_WINDOW_S=86400
  [ ! -f "$H/state/pool/project-5/BH-1016.defer-to-human" ] \
    && ok "d: the page sentinel clears once the key is under the cap again" \
    || bad "d: defer-to-human sentinel survived a spawn-allowed tick"
  # The spawn-allowed tick left a machine json for this key, and the loop skips
  # a key that is already running long before the decision gate; clear it so the
  # next tick reaches the cap.
  for p in "$H/state/fly-pool/project-5"/*.json; do [ -e "$p" ] && scratch_rm "$p"; done
  echo "$((NOW-60))" >> "$H/state/pool/project-5/BH-1016.spawns"
  echo "$((NOW-30))" >> "$H/state/pool/project-5/BH-1016.spawns"
  queue_bh1016
  run_pool_keep POOL_SPAWN_CAP_PER_KEY=2 POOL_SPAWN_CAP_WINDOW_S=86400
  AL2=$(grep -c 'POOL_SPAWN_CAP_WAIT' "$H/logs/ALERTS.log")
  [ "$AL2" = 2 ] && ok "d: a later cap trip pages again" \
    || bad "d: expected a second page after the cap re-armed, total was $AL2"
}

# ── e: a HOLD comment stops the next spawn even while a machine is live ─────
{
  reset_state
  write_fly_stub ""
  write_gh_stub "" 0 open 1
  queue_bh1016
  # A live machine for ANOTHER key (BH-1015) plus the queued BH-1016 row. It has
  # to be another key: the spawn loop skips a key that is already running long
  # before the decision gate (`grep -ls "key": "$KEY" "$POOL"/*.json`), so a
  # same-key machine would prove the running-key skip, not the HOLD gate. What
  # this case pins is that HOLD refuses a NEW spawn while the pool is busy.
  jq -nc --arg m "m-live123" --arg k "BH-1015" --arg t "1015" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/fly-pool/project-5/m-live123.json"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "e: no second machine spawned while ticket is held" || bad "e: expected 1 machine, got $N"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "e: queue file left in place for retry" || bad "e: queue file unexpectedly removed"
  grep -q 'skipping BH-1016: HOLD' "$H/logs/fly-pool.log" \
    && ok "e: HOLD skip logged" || bad "e: HOLD skip missing from log"
}

# ── negative: a non-push deferral still requeues as before ─────────────────
{
  reset_state builds
  DEFER='BUILD_DEFERRED REFUSED box :: box max 1 already running'
  write_fly_stub "$DEFER"
  write_gh_stub "" 0
  queue_bh1016
  jq -nc --arg m "m-ref123" --arg k "BH-1016" --arg t "1016" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/fly-pool/project-5/m-ref123.json"
  run_pool POOL_SPAWN=0
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "negative: queue file re-created" || bad "negative: queue file not re-created"
  [ ! -f "$H/state/pool/project-5/BH-1016.terminal" ] \
    && ok "negative: no terminal file for non-push deferral" || bad "negative: unexpected terminal file"
  grep -q 'DEFERRED BH-1016.*requeued' "$H/logs/fly-pool.log" \
    && ok "negative: deferral requeue logged" || bad "negative: requeue not logged"
}

# ── mutation: lowering the cap to one causes the d fixture to cap earlier ───
{
  reset_state
  write_fly_stub ""
  write_gh_stub "" 0
  queue_bh1016
  echo "$((NOW-3600))" > "$H/state/pool/project-5/BH-1016.spawns"
  run_pool POOL_SPAWN_CAP_PER_KEY=1 POOL_SPAWN_CAP_WINDOW_S=86400
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "mutation: cap=1 blocks after one spawn" || bad "mutation: expected 0 spawns with cap=1, got $N"
}

# ── mutation: cached REST reads do not call gh twice per tick ───────────────
{
  reset_state
  write_fly_stub ""
  write_gh_stub "samehead" 0
  # an unchanged terminal keeps the spawn blocked so the PR check is the only REST call
  jq -nc --arg sha "samehead" --arg ts "$(date -u -d @$((NOW-86400)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/bh-1016",head_sha:$sha,reason:"push rejected",created_at:$ts}' \
    > "$H/state/pool/project-5/BH-1016.terminal"
  queue_bh1016
  cp "$H/state/build-queue/project-5/BH-1016.json" "$H/state/build-queue/project-5/BH-1016.dup.json"
  PR_CALLS="$T/pr-calls.txt"; export PR_CALLS; rm -f "$PR_CALLS"
  cat > "$T/fakebin/gh" <<'GC'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/1016"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'
  exit 0
fi
if [[ "$*" == *"-i"* ]] && [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"pulls"* ]] && [[ "$*" != *"git/ref"* ]]; then
  printf 'HTTP/1.1 200 OK

{"full_name":"example-org/project-5"}
'
  exit 0
fi
if [[ "$*" == *"-i"*"git/ref/heads/ticket/bh-1016"* ]]; then
  printf 'HTTP/1.1 200 OK

{"object":{"sha":"samehead"}}
'
  exit 0
fi
if [[ "$*" == *"-i"*"pulls?state=open"*"head="* ]]; then
  echo "$*" >> "$PR_CALLS"
  printf 'HTTP/1.1 200 OK

[]
'
  exit 0
fi
exit 0
GC
  chmod +x "$T/fakebin/gh"
  run_pool
  CALLS=$(wc -l < "$PR_CALLS" 2>/dev/null | tr -d ' ')
  [ "$CALLS" = 1 ] && ok "mutation: open-PR REST cached (one call for two duplicate queue rows)" || bad "mutation: expected 1 PR-list call, got $CALLS"
}

# ── f: a gh that answers NOTHING is a gate that does not apply, not a freeze ─
# A REST read that came back 403 is a read; a `gh` that cannot produce an HTTP
# status line at all (not installed, not logged in, no network) never made one.
# Blocking on the second freezes every spawn on every project the moment the
# client is unconfigured — a fleet outage dressed as a safety gate, and the way
# tests/gh-token-rotate-test.sh caught this on CI (54/6) while passing locally
# on an image with no gh at all.
{
  reset_state
  write_fly_stub ""
  printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
  chmod +x "$T/fakebin/gh"
  queue_bh1016
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "f: a mute gh client does not block the spawn" \
    || bad "f: expected the spawn to proceed with an unusable gh client, got $N"
  grep -q 'spawn gates inactive' "$H/logs/fly-pool.log" \
    && ok "f: the inactive gate says so once" || bad "f: no gates-inactive line"
}

# ── g: a pool REBASE row is not a ticket and none of the four gates apply ───
# bin/merge-conductor.sh enqueues RB-<pr>-<head8> rows whose ticket_id is a PR
# NUMBER. Read as an ISSUE that number carries no `ai-build` label, and
# hold_classify answers `held label-absent` for anything without it — which is
# every harness PR. Gate the rebase row on that and the conductor's pool-rebase
# lane never spawns a machine again: the row is skipped every tick with its
# queue file left in place until MC_REBASE_POOL_TIMEOUT_SECS fails it. The open
# PR is the POINT of a rebase, and the cap would delete the row without failing
# it, so all four are refused for RB-*.
{
  reset_state
  write_fly_stub ""
  rm -f "$T/gh-post.txt"
  cat > "$T/fakebin/gh" <<'GRB'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
# the PR read as an issue: open, and NO ai-build label — `held label-absent`
if [[ "$*" == *"issues/55"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[],"title":"BH-1016: something","body":""}'
  exit 0
fi
if [[ "$*" == *"-i"* ]] && [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"pulls"* ]] && [[ "$*" != *"git/ref"* ]]; then
  printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'
  exit 0
fi
if [[ "$*" == *"-i"*"pulls?state=open"*"head="* ]]; then
  printf 'HTTP/1.1 200 OK\n\n[{"number":55,"state":"open","html_url":"https://github.com/example-org/project-5/pull/55","head":{"ref":"ticket/bh-1016"}}]\n'
  exit 0
fi
printf 'HTTP/1.1 200 OK\n\n{}\n'
exit 0
GRB
  chmod +x "$T/fakebin/gh"
  # exactly the row bin/fly-dispatch.sh writes for a pool rebase
  # the key is passed as --arg: a literal key:"RB-55-…" on this line reads as a
  # generic-api-key to the public mirror's gitleaks gate (red publisher, 2026-09-21)
  jq -nc --arg key RB-55-abcdef12 '{ticket_id:"55",key:$key,attempt:1,deferrals:0,deaths:0,
           rebase:{pr:55,branch:"ticket/bh-1016",base:"main",head:"abcdef12"}}' \
    > "$H/state/build-queue/project-5/RB-55-abcdef12.json"
  # ...and a spawn ledger already at cap, to prove the cap is not applied either
  { echo "$((NOW-600))"; echo "$((NOW-300))"; } > "$H/state/pool/project-5/RB-55-abcdef12.spawns"
  run_pool POOL_SPAWN_CAP_PER_KEY=2 POOL_SPAWN_CAP_WINDOW_S=86400
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "g: the rebase row spawns a machine" || bad "g: expected 1 spawn for the rebase row, got $N"
  [ ! -f "$H/state/build-queue/project-5/RB-55-abcdef12.json" ] \
    && ok "g: the rebase queue file was consumed" || bad "g: rebase queue file still queued — the lane is stalled"
  grep -q 'HOLD' "$H/logs/fly-pool.log" \
    && bad "g: the rebase row was refused as HOLD" || ok "g: no HOLD refusal for the rebase row"
  grep -q 'skipping RB-55-abcdef12' "$H/logs/fly-pool.log" \
    && bad "g: the rebase row was skipped by a ticket gate" || ok "g: no ticket gate skipped the rebase row"
  [ ! -s "$T/gh-post.txt" ] \
    && ok "g: no board comment for a rebase row" || bad "g: a rebase row commented on the PR: $(cat "$T/gh-post.txt")"
  grep -q 'POOL_SPAWN_CAP_WAIT' "$H/logs/ALERTS.log" \
    && bad "g: the cap paged on a rebase row" || ok "g: the cap did not page on a rebase row"
}

# ── h: an unchanged terminal SKIPS the row, it does not delete it ───────────
# Deleting it made the re-arm unreachable through the pool's own state: nothing
# in this file re-creates a queue file, so "a changed head re-arms one attempt"
# could only ever fire if the ledger watchdog happened to requeue the claimed
# row first. Skip-and-keep is what makes the next tick able to see the new head.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "samehead" 0
  queue_bh1016
  jq -nc --arg sha "samehead" --arg ts "$(date -u -d @$((NOW-86400)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/bh-1016",head_sha:$sha,reason:"push rejected",created_at:$ts}' \
    > "$H/state/pool/project-5/BH-1016.terminal"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "h: no spawn while the terminal head is unchanged" || bad "h: expected 0 spawns, got $N"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "h: the queue row is kept for the next tick" || bad "h: the terminal path deleted the queue row"
  grep -q 'skipping BH-1016: terminal head unchanged' "$H/logs/fly-pool.log" \
    && ok "h: the terminal skip is logged" || bad "h: terminal skip missing from log"
  # next tick, head moved, and NOTHING re-created the row: the re-arm is
  # reachable through the pool's own state.
  write_gh_stub "movedhead" 0
  run_pool
  N2=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N2" = 1 ] && ok "h: the kept row re-arms itself when the head moves" \
    || bad "h: expected the kept row to spawn on the changed head, got $N2"
}

# ── i: a terminal written with head_sha=unknown does not re-arm ─────────────
# The reap writes `unknown` when the head read failed at that moment. Reading
# that back as "the head changed" buys a machine that will be push-rejected
# again — for free, on nothing but an unreadable read. Record the head instead.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "realsha789" 0
  queue_bh1016
  jq -nc --arg ts "$(date -u -d @$((NOW-86400)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/bh-1016",head_sha:"unknown",reason:"push rejected",created_at:$ts}' \
    > "$H/state/pool/project-5/BH-1016.terminal"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "i: an unknown head does not re-arm" || bad "i: expected 0 spawns on head_sha=unknown, got $N"
  [ -f "$H/state/pool/project-5/BH-1016.terminal" ] \
    && ok "i: the terminal survives" || bad "i: the terminal was removed on an unknown head"
  REC=$(jq -r '.head_sha // ""' "$H/state/pool/project-5/BH-1016.terminal" 2>/dev/null)
  [ "$REC" = realsha789 ] && ok "i: the real head is recorded in the terminal" \
    || bad "i: expected head_sha=realsha789 recorded, got '$REC'"
  # and the next tick, reading the same head back, still does not spawn
  run_pool
  N2=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N2" = 0 ] && ok "i: the recorded head keeps the row terminal" || bad "i: expected 0 spawns on the second tick, got $N2"
}

# ── j: only an EXPLICIT human re-arm re-arms; harness prose does not ────────
# Every comment this harness posts with the PAT is `user.type: "User"`, so a
# bot filter alone hands the harness its own re-arm — the incident hold.sh's
# lift vocabulary exists to prevent, in a lane that spends a machine for it.
{
  reset_state
  write_fly_stub ""
  PROSE="$T/comments-prose.json"
  jq -nc --arg at "$(date -u -d @$((NOW-60)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '[{created_at:$at,body:"Rebuilt this ticket fresh against current main; the earlier attempt was parked by the blocked-resolver.",user:{type:"User"}}]' \
    > "$PROSE"
  write_gh_stub "samehead" 0 open 0 "$PROSE"
  queue_bh1016
  jq -nc --arg sha "samehead" --arg ts "$(date -u -d @$((NOW-86400)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/bh-1016",head_sha:$sha,reason:"push rejected",created_at:$ts}' \
    > "$H/state/pool/project-5/BH-1016.terminal"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "j: the harness's own PAT comment does not re-arm" \
    || bad "j: harness prose re-armed a terminal, got $N spawns"
  # ...and a human saying it in the vocabulary DOES.
  SAYS="$T/comments-retry.json"
  jq -nc --arg at "$(date -u -d @$((NOW-30)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '[{created_at:$at,body:"branch protection is off now — RETRY this one",user:{type:"User"}}]' \
    > "$SAYS"
  write_gh_stub "samehead" 0 open 0 "$SAYS"
  run_pool
  N2=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N2" = 1 ] && ok "j: an explicit human RETRY re-arms one attempt" \
    || bad "j: expected the explicit re-arm to spawn, got $N2"
  grep -q 'explicit human re-arm' "$H/logs/fly-pool.log" \
    && ok "j: the re-arm is logged" || bad "j: re-arm not logged"
  # a NEGATED instruction is not one
  reset_state
  NEG="$T/comments-neg.json"
  jq -nc --arg at "$(date -u -d @$((NOW-30)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '[{created_at:$at,body:"do not RETRY this until the branch protection is off",user:{type:"User"}}]' \
    > "$NEG"
  write_gh_stub "samehead" 0 open 0 "$NEG"
  queue_bh1016
  jq -nc --arg sha "samehead" --arg ts "$(date -u -d @$((NOW-86400)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/bh-1016",head_sha:$sha,reason:"push rejected",created_at:$ts}' \
    > "$H/state/pool/project-5/BH-1016.terminal"
  run_pool
  N3=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N3" = 0 ] && ok "j: a negated RETRY does not re-arm" || bad "j: a negated RETRY spawned $N3 machines"
}

# ── k: the machine-reuse handoff is gated too ──────────────────────────────
# next_job_or_destroy hands a queued row straight to the machine it just
# reaped, without passing the spawn loop — so every gate above is bypassed on
# that path. That is a BUILD, metered exactly like a spawned one, and once the
# terminal path keeps its queue file (case h) the reuse loop is the one place
# that could still pick a terminal row up and run it.
{
  reset_state builds
  write_fly_stub "BUILD_DEFERRED REFUSED box :: box max 1 already running"
  write_gh_stub "samehead" 0
  # the reaped machine is BH-1015; BH-1016 is queued and terminal-parked
  jq -nc --arg m "m-reuse1" --arg k "BH-1015" --arg t "1015" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/fly-pool/project-5/m-reuse1.json"
  queue_bh1016
  jq -nc --arg sha "samehead" --arg ts "$(date -u -d @$((NOW-86400)) '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/bh-1016",head_sha:$sha,reason:"push rejected",created_at:$ts}' \
    > "$H/state/pool/project-5/BH-1016.terminal"
  run_pool POOL_SPAWN=0
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "k: the terminal row was not handed to the reused machine" \
    || bad "k: the reuse handoff consumed a terminal row"
}

# ── l: the gate's reads run on the credential that can SEE the repo ─────────
# BH-765's ladder (app -> default -> admin) exists because the hub's default PAT
# 404s on example-org/project-5 — the 2026-09-12 shape where "an empty answer" and
# "this token cannot see the repo" were the same sentence and six approved PRs
# sat for days. The reap gate in this same file already asks it. The SPAWN gates
# did not: they read on whatever GH_TOKEN the tick carried, so on such a repo the
# PR list 404s, every row is skipped as "PR check unreadable — will retry", and
# the project's pool freezes for ever with nothing paging. The two auth libs are
# copied into the scratch harness on purpose: without them every read in every
# other case runs on one identity and this class is invisible to the suite.
{
  reset_state
  write_fly_stub ""
  cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
  printf 'GH_APP_ID=1\nGH_APP_INSTALL_ID=2\nGH_APP_PRIVATE_KEY_FILE=%s/env/app.pem\n' "$H" > "$H/env/github-app.env"
  : > "$H/env/app.pem"
  printf '#!/bin/bash\nprintf "apptok\\n"\n' > "$H/bin/gh-token.sh"
  chmod +x "$H/bin/gh-token.sh"
  # Armed, the spawn mints for the bundle's REPO_SLUG, which the real
  # fly-envbundle.sh always writes, and since BH-4798 refuses a machine left with
  # neither an App token nor a PAT. The shared stub writes an empty project env,
  # so this case gets a bundle with the slug, as a real one has.
  printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; printf "REPO_SLUG=example-org/%%s\\n" "$1" > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
  GHCALLS="$T/gh-calls-l.txt"; export GHCALLS; rm -f "$GHCALLS"
  cat > "$T/fakebin/gh" <<'GL'
#!/bin/bash
TOK="${GH_TOKEN:-nothing}"
echo "$TOK :: $*" >> "$GHCALLS"
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
# EVERY read answers on the App token only; the box default PAT cannot see this
# repo at all — a 404 with -i, a non-zero exit without.
if [ "$TOK" != apptok ]; then
  if [[ "$*" == *"-i"* ]]; then printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0; fi
  exit 1
fi
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/1016"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'
  exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  if [[ "$*" == *"git/ref/heads/"* ]]; then printf 'HTTP/1.1 200 OK\n\n{"object":{"sha":"lsha"}}\n'; exit 0; fi
  printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'
  exit 0
fi
exit 0
GL
  chmod +x "$T/fakebin/gh"
  queue_bh1016
  run_pool GH_TOKEN=defaultpat
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "l: a repo only the App token can see still spawns" \
    || bad "l: expected 1 spawn on a repo visible to the ladder, got $N"
  grep -q 'PR check unreadable' "$H/logs/fly-pool.log" \
    && bad "l: the gate read on an identity that cannot see the repo and froze the row" \
    || ok "l: no unreadable-PR freeze on a repo the ladder can see"
  grep -q '^apptok :: .*pulls?state=open' "$GHCALLS" \
    && ok "l: the PR-list read ran on the ladder's token" \
    || bad "l: the PR-list read did not run on the ladder's token: $(grep 'pulls?state=open' "$GHCALLS" 2>/dev/null | head -2)"
  grep -q '^defaultpat :: .*pulls?state=open' "$GHCALLS" \
    && bad "l: the PR-list read ran on the box default PAT" \
    || ok "l: no PR-list read on the box default PAT"
  scratch_rm "$H/bin/lib/gh-app-auth.sh"; scratch_rm "$H/bin/lib/gh-repo-token.sh"
  scratch_rm "$H/env/github-app.env"; scratch_rm "$H/env/app.pem"; scratch_rm "$H/bin/gh-token.sh"
  printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
}

# ── m: a repo NO credential can see is a PAGE, not a silent frozen project ──
# gh-repo-token.sh's own rule. Failing every gate closed on such a repo skips
# every row of the project on every tick behind one log line — the exact silence
# that library was written to end.
{
  reset_state
  write_fly_stub ""
  cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
  cat > "$T/fakebin/gh" <<'GM'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"-i"* ]]; then printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0; fi
exit 1
GM
  chmod +x "$T/fakebin/gh"
  queue_bh1016
  run_pool GH_TOKEN=defaultpat
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "m: an invisible repo does not freeze the project's spawns" \
    || bad "m: expected the spawn to proceed on an invisible repo, got $N"
  grep -q 'is INVISIBLE to the default gh token' "$H/logs/ALERTS.log" \
    && ok "m: the invisible repo pages once" || bad "m: no ALERTS line for an invisible repo"
  scratch_rm "$H/bin/lib/gh-app-auth.sh"; scratch_rm "$H/bin/lib/gh-repo-token.sh"
  for p in "$H"/flags/alerted-repo-invisible-*; do [ -e "$p" ] && scratch_rm "$p"; done
}

# ── n: the reuse handoff judges the cap the OPERATOR set, not the default ──
# pool_spawn_cap_load used to run after the reap loop, so next_job_or_destroy's
# handoff read POOL_SPAWN_CAP unset and fell back to 2/86400 whatever was in D1:
# a cap raised to 5 refused a row at 2, deleted its queue file and paged for a
# key under the operator's own cap.
{
  reset_state builds
  write_fly_stub "BUILD_DEFERRED REFUSED box :: box max 1 already running"
  write_gh_stub "samehead" 0
  jq -nc --arg m "m-reuse2" --arg k "BH-1015" --arg t "1015" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/fly-pool/project-5/m-reuse2.json"
  queue_bh1016
  { echo "$((NOW-3600))"; echo "$((NOW-1800))"; } > "$H/state/pool/project-5/BH-1016.spawns"
  run_pool POOL_SPAWN=0 POOL_SPAWN_CAP_PER_KEY=5 POOL_SPAWN_CAP_WINDOW_S=86400
  RK=$(jq -r '.key // ""' "$H/state/fly-pool/project-5/m-reuse2.json" 2>/dev/null)
  [ "$RK" = "BH-1016" ] && ok "n: the handoff honours a cap raised to 5" \
    || bad "n: expected the reaped machine to take BH-1016 under cap=5, key is '$RK'"
  grep -q 'POOL_SPAWN_CAP_WAIT' "$H/logs/ALERTS.log" \
    && bad "n: the handoff paged for a key under the operator's cap" \
    || ok "n: no page for a key under the operator's cap"
}

# ── o: a handoff is a BUILD, so it counts against the per-key cap ───────────
# The gate CHECKED the cap on this path and nothing recorded against it, so a
# key handed from reaped machine to reaped machine built for ever with the
# ledger frozen at zero.
{
  reset_state builds
  write_fly_stub "BUILD_DEFERRED REFUSED box :: box max 1 already running"
  write_gh_stub "samehead" 0
  jq -nc --arg m "m-reuse3" --arg k "BH-1015" --arg t "1015" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/fly-pool/project-5/m-reuse3.json"
  queue_bh1016
  run_pool POOL_SPAWN=0 POOL_SPAWN_CAP_PER_KEY=2 POOL_SPAWN_CAP_WINDOW_S=86400
  RK=$(jq -r '.key // ""' "$H/state/fly-pool/project-5/m-reuse3.json" 2>/dev/null)
  [ "$RK" = "BH-1016" ] && ok "o: the row was handed to the reaped machine" \
    || bad "o: expected the handoff to happen, machine key is '$RK'"
  SP=$(cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null | wc -l | tr -d ' ')
  [ "${SP:-0}" = 1 ] && ok "o: the handoff recorded one entry against the cap" \
    || bad "o: expected 1 spawn-ledger entry after a handoff, got '${SP:-0}'"
}

# ── p: a removed queue file closes its ledger row ──────────────────────────
# The gate deleted the queue FILE on the open-PR arm (and, before BH-4859, the
# cap arm, which now keeps it), and the reap
# wrote a terminal, while the ledger row stayed `claimed` — two views of one row
# disagreeing until the watchdog requeued the claim into the same refusal.
{
  reset_state builds
  QSINK="$T/qrow.txt"; export QSINK; rm -f "$QSINK"
  cat > "$H/bin/jobs-client.sh" <<'JC'
#!/bin/bash
queue_done() { echo "done $*" >> "$QSINK"; }
queue_put()  { echo "put $*" >> "$QSINK"; }
if [ "${1:-}" = setting-get ]; then exit 1; fi
JC
  chmod +x "$H/bin/jobs-client.sh"
  # (1) open PR
  write_fly_stub ""
  write_gh_stub "prheadsha" 1
  queue_bh1016
  run_pool
  grep -q '^done project-5 BH-1016 failed' "$QSINK" 2>/dev/null \
    && ok "p: the open-PR arm closes the ledger row" \
    || bad "p: open-PR arm left the row claimed: $(cat "$QSINK" 2>/dev/null)"
  # (2) cap — BH-4859: the cap arm keeps its queue file, so it must NOT close
  # the ledger row; a row closed `failed` here was a park nothing read.
  reset_state; rm -f "$QSINK"
  write_gh_stub "" 0
  queue_bh1016
  { echo "$((NOW-3600))"; echo "$((NOW-1800))"; } > "$H/state/pool/project-5/BH-1016.spawns"
  run_pool POOL_SPAWN_CAP_PER_KEY=2 POOL_SPAWN_CAP_WINDOW_S=86400
  grep -q 'skipping BH-1016: spawn cap reached' "$H/logs/fly-pool.log" \
    && ok "p: the cap arm was reached" || bad "p: the cap arm was not reached: $(cat "$H/logs/fly-pool.log")"
  grep -q '^done project-5 BH-1016 failed' "$QSINK" 2>/dev/null \
    && bad "p: the cap arm closed the ledger row: $(cat "$QSINK" 2>/dev/null)" \
    || ok "p: the cap arm leaves the ledger row open"
  # (3) the reap's push-rejected terminal
  reset_state builds; rm -f "$QSINK"
  write_fly_stub "BUILD_DEFERRED push of ticket/bh-1016 rejected TIER: 2 (lease fail)"
  write_gh_stub "" 0
  jq -nc --arg m "m-term1" --arg k "BH-1016" --arg t "1016" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-09-19T21:28:00Z"}' \
    > "$H/state/fly-pool/project-5/m-term1.json"
  run_pool
  grep -q '^done project-5 BH-1016 failed' "$QSINK" 2>/dev/null \
    && ok "p: the push-rejected terminal closes the ledger row" \
    || bad "p: terminal reap left the row claimed: $(cat "$QSINK" 2>/dev/null)"
  scratch_rm "$H/bin/jobs-client.sh"
}

# ── q: a ticket that is closed (or de-labelled) parks its row ──────────────
# `held closed` and `held label-absent` are verdicts nothing in the pool can
# ever lift, so retrying them is two REST reads per row per tick for ever behind
# a log line nobody reads.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "" 0 closed
  queue_bh1016
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "q: a closed ticket does not spawn" || bad "q: expected 0 spawns, got $N"
  [ ! -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "q: the closed ticket's row is parked, not retried for ever" \
    || bad "q: a closed ticket's row was kept for a retry that can never succeed"
  grep -q 'parking the row' "$H/logs/fly-pool.log" \
    && ok "q: the park is logged" || bad "q: park missing from log"
}

# ── r: a BOARD ticket spawns — the hold gate reads GitHub issues only ───────
# The in-app boards (project-3, project-1, project-2, project-4, project-8)
# enqueue rows whose ticket_id is the board's own row id (a cuid), never an
# issue number. hold_check answers `unreadable / no issue number to read` for
# it, and reading that as "retry next tick" froze every board project's pool
# from 2026-09-20 23:58Z (seven rows, four projects, fifteen hours, one log
# line per tick). A board ticket's holds live on the board; the gate does not
# apply, the row spawns, and the log says why.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "newsha456" 0
  jq -nc '{ticket_id:"cmu8xkn7z001204i90paasmc9",key:"TK-187",attempt:0,deferrals:0,deaths:0,enqueued_at:"2026-09-21T04:20:00Z"}' \
    > "$H/state/build-queue/project-5/TK-187.json"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "r: a board ticket (cuid ticket_id) spawns" || bad "r: expected 1 spawn for a board ticket, got $N"
  grep -q 'skipping TK-187: hold check unreadable' "$H/logs/fly-pool.log" \
    && bad "r: a board ticket must not be skipped as an unreadable hold" \
    || ok "r: no unreadable-hold skip for a board ticket"
  [ ! -f "$H/state/build-queue/project-5/TK-187.json" ] \
    && ok "r: the board ticket's queue file was consumed by the spawn" \
    || bad "r: the board ticket's queue file is still waiting"
}

# ── s: a HOLD skip is SAID ON THE TICKET, once, and marked for the fleet page ─
# BH-1461. Before this, a held row was a single log line per tick on the hub:
# BH-1325/#1381/#1419 were skipped for four hours and their authors had no way
# to know. The skip now writes a `<KEY>.held` marker (what the fleet page counts
# separately) and posts ONE comment naming the matched line and the lift word.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "" 0 open 1
  queue_bh1016
  rm -f "$T/gh-sink.txt" "$T/gh-post.txt" "$T/gh-post-body.txt"
  run_pool
  [ -f "$H/state/pool/project-5/BH-1016.held" ] \
    && ok "s: held marker written" || bad "s: no held marker for a skipped-as-held row"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "s: queue file left in place" || bad "s: queue file removed by a hold skip"
  grep -q 'repos/example-org/project-5/issues/1016/comments' "$T/gh-post.txt" 2>/dev/null \
    && ok "s: the hold skip was said on the ticket over REST" \
    || bad "s: no REST comment for the hold skip: $(cat "$T/gh-post.txt" 2>/dev/null)"
  [ ! -s "$T/gh-sink.txt" ] \
    && ok "s: no GraphQL gh issue comment" || bad "s: gh issue comment (GraphQL) was used"
  grep -q 'HOLD — do not build' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "s: the comment quotes the matched line" \
    || bad "s: comment does not name the matched line: $(cat "$T/gh-post-body.txt" 2>/dev/null)"
  grep -q 'RESUME' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "s: the comment names the lift word" || bad "s: comment does not name RESUME"
  # AND THE REMEDY MATCHES THE ARM THAT DECIDED (review of PR #1478). This row
  # was held by a COMMENT, so "re-word the body" is the wrong instruction —
  # editing the ticket cannot lift a comment hold.
  grep -q 'is a COMMENT' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "s: the comment names the comment remedy" \
    || bad "s: comment-arm remedy missing: $(cat "$T/gh-post-body.txt" 2>/dev/null)"
  grep -q 'BEGINS with' "$T/gh-post-body.txt" 2>/dev/null \
    && bad "s: a comment hold was sent to re-word the body" \
    || ok "s: no body remedy on a comment hold"
  [ -f "$H/state/pool/project-5/BH-1016.hold-noted" ] \
    && ok "s: hold-noted sentinel written" || bad "s: no hold-noted sentinel"
  # ...and ONCE. A comment per tick on a four-hour hold is 120 comments.
  N1=$(grep -c 'issues/1016/comments' "$T/gh-post.txt" 2>/dev/null | tr -dc '0-9'); N1=${N1:-0}
  write_gh_stub "" 0 open 1
  run_pool
  N2=$(grep -c 'issues/1016/comments' "$T/gh-post.txt" 2>/dev/null | tr -dc '0-9'); N2=${N2:-0}
  [ "$N1" = 1 ] && [ "$N2" = 1 ] \
    && ok "s: exactly one comment across two held ticks" \
    || bad "s: expected 1 comment on both ticks, got $N1 then $N2"
  # A LIFT CLEARS BOTH. The marker is what the fleet page counts and the
  # sentinel is what keeps the pool quiet; a row that is no longer held must
  # stop being counted as held, and must be able to speak again if re-held.
  write_gh_stub "" 0 open 0
  queue_bh1016
  run_pool
  [ ! -f "$H/state/pool/project-5/BH-1016.held" ] \
    && ok "s: the marker is removed once the hold is clear" \
    || bad "s: held marker survived a clear verdict"
  [ ! -f "$H/state/pool/project-5/BH-1016.hold-noted" ] \
    && ok "s: the once-sentinel is removed with the marker" \
    || bad "s: hold-noted sentinel survived a clear verdict"
}

# ── s2: a TITLE hold is told to retitle, not to re-word the body ───────────
# Review of PR #1478. The body/title asymmetry is deliberate — `Compliance P7
# (HOLD): EU residency` is the real title idiom — but the one-time comment was
# body-shaped for EVERY verdict, so a title hold sent its author to edit a body
# that was never the problem. The tail names the arm; the remedy follows it.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "newsha456" 0 open 0 "" "" 'BH-1016 the thing (HOLD)'
  queue_bh1016
  rm -f "$T/gh-sink.txt" "$T/gh-post.txt" "$T/gh-post-body.txt"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "s2: a HOLD in the title refuses the spawn" || bad "s2: expected 0 spawns, got $N"
  grep -q 'is the TITLE' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "s2: the comment names the title remedy" \
    || bad "s2: title-arm remedy missing: $(cat "$T/gh-post-body.txt" 2>/dev/null)"
  grep -q 'Retitle' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "s2: it says to retitle" || bad "s2: the comment does not say to retitle"
  grep -q 'BEGINS with' "$T/gh-post-body.txt" 2>/dev/null \
    && bad "s2: a title hold was sent to re-word the body" \
    || ok "s2: no body remedy on a title hold"
}

# ── t: a body that only DESCRIBES a hold builds ────────────────────────────
# The incident itself: BH-1419's body says "A per-project HOLD row for hub
# lanes". That is prose about the mechanism, not an instruction, so the row
# must spawn — no skip, no marker, no comment.
{
  reset_state
  write_fly_stub ""
  write_gh_stub "newsha456" 0 open 0 "" '1. A per-project HOLD row for hub lanes.'
  queue_bh1016
  rm -f "$T/gh-sink.txt" "$T/gh-post.txt" "$T/gh-post-body.txt"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && ok "t: a prose HOLD in the body still spawns" || bad "t: expected 1 spawn, got $N"
  grep -q 'skipping BH-1016: HOLD' "$H/logs/fly-pool.log" \
    && bad "t: a prose HOLD in the body was read as a hold" \
    || ok "t: no HOLD skip for a prose mention"
  [ ! -f "$H/state/pool/project-5/BH-1016.held" ] \
    && ok "t: no held marker for a prose mention" || bad "t: held marker written for a prose mention"
  [ ! -s "$T/gh-post.txt" ] \
    && ok "t: nothing said on the ticket" || bad "t: a comment was posted for a prose mention"
}

# ── u: an explicit HOLD: line in the body IS a hold ────────────────────────
{
  reset_state
  write_fly_stub ""
  write_gh_stub "newsha456" 0 open 0 "" 'HOLD: waiting on the client'
  queue_bh1016
  rm -f "$T/gh-sink.txt" "$T/gh-post.txt" "$T/gh-post-body.txt"
  run_pool
  N=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] && ok "u: a HOLD: body line refuses the spawn" || bad "u: expected 0 spawns, got $N"
  grep -q 'skipping BH-1016: HOLD' "$H/logs/fly-pool.log" \
    && ok "u: the hold skip is logged" || bad "u: no HOLD skip logged for a HOLD: body line"
  grep -q 'HOLD: waiting on the client' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "u: the comment quotes the body line that held it" \
    || bad "u: comment does not quote the body line: $(cat "$T/gh-post-body.txt" 2>/dev/null)"
  # The BODY arm is the one case where "re-word it" is the right remedy, and it
  # is still the default branch (review of PR #1478).
  grep -q 'BEGINS with' "$T/gh-post-body.txt" 2>/dev/null \
    && ok "u: the comment names the body remedy" \
    || bad "u: body-arm remedy missing: $(cat "$T/gh-post-body.txt" 2>/dev/null)"
}

echo "fly-pool-respawn-cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
