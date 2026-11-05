#!/bin/bash
# tests/pool-defer-after-stop.bh-8880-test.sh — BH-8880: the pool spawns no
# machine for a key whose newest hub record waits on another key's open PR.
#
# THE INCIDENT. project-5 TK-3786 waits on TK-3785 (PR #3958, open since
# 2026-10-20). Its queue row had no `after`, so pool_after_gate let it through;
# every tick a machine planned, stood down BUILD_DEFERRED and was destroyed:
# 196 DEFERRED records, 189 spawns, $14.22, 0 builds.
#
#   D1   newest record `After: TK-3785 PR #3958 open`, #3958 open: no machine,
#        one skip line per tick (2 ticks), the queue file kept, no QROW write
#   D2   the blocker PR is gone from the open list (merged or closed): spawns
#   D3   no record / D3b a deferral that names no key / D3c `After:` on a
#        non-deferral line: spawns
#   D4   OVERLAP_DEFER with `; After:` / D4b OVERLAP_DEFER vs <KEY>-r2 with no
#        After: (line says `PR open`): held
#   D5   an older After record under a newer other deferral: spawns
#   D6   a person comment since the record: released, marker, spawns; the next
#        tick reads no comments. D6b a bot comment: held, seen marker, and the
#        next tick with the same listing reads no comments
#   D7   the listing says the issue did not change since the record: held, no
#        comments read
#   D8   the open-PR list answers 502: held with the retry line
#   D9   self key, child key, lower-case `after:`: spawns
#   D10  POOL_DEFER_AFTER_STOP=0: D1's setup spawns
#   D11  two keys wait on TK-3785 in one tick: one open-list read
#   D12  mutual wait: not held here
#   G    every gh and fly call is a fake
#
# Driven through bin/fly-pool.sh against a scratch HARNESS, a fake flyctl, a
# fake gh and a recording jobs client (the tests/pool-after-release.bh-5967 rig).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-defer-after-stop.bh-8880-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_PROJECT_5=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh \
         bin/lib/defer-after-stop.sh bin/lib/plan-blocked.sh bin/lib/tracker.sh bin/lib/gh-rest.sh \
         bin/lib/pool-hold-cache.sh; do
  # A tree without the gate lib (main before BH-8880) still runs every case,
  # so the reproduction is red on D1, not on setup.
  [ -f "$DIR/$L" ] || { bad "$L is missing"; continue; }
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The jobs client RECORDS the queue writes. Executed (a setting read) it
# answers nothing, so every setting falls back.
cat > "$H/bin/jobs-client.sh" <<JC
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
queue_put()  { printf 'put %s\n' "\$*" >> "$T/q.log"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/q.log"; return 0; }
JC
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
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
# gh: every call is logged to $T/gh-calls. The repo is visible; a per-key
# head= read finds no PR; the paged open-PR list is $T/open-prs.json (502 when
# $T/open-prs.502 exists); the ai-build listing gives issues 3785-3787 with
# updated_at from $T/upd-<n>; the comments-since read is $T/comments-<n>.json.
# A call the fake does not know goes to $T/realgh.log (G).
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
a="\$*"
if [[ "\$a" == *"--paginate"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$a" != *"-i"* ]]; then
  if [[ "\$a" =~ issues/([0-9]+) ]]; then
    echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"TS fixture","body":""}'; exit 0
  fi
  echo "\$a" >> "$T/realgh.log"; exit 1
fi
case "\$a" in
  *"pulls?state=open"*"head="*) printf 'HTTP/1.1 200 OK\\n\\n[]\\n' ;;
  *"pulls?state=open"*)
    if [ -e "$T/open-prs.502" ]; then printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n'
    else printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/open-prs.json"; fi ;;
  *"issues?state=open"*"labels=ai-build"*)
    printf 'HTTP/1.1 200 OK\\n\\n'
    for n in 3785 3786 3787; do
      jq -nc --argjson n "\$n" --arg u "\$(cat "$T/upd-\$n" 2>/dev/null || echo 2026-10-20T00:00:00Z)" \
        '{number:\$n,updated_at:\$u,comments:0,state:"open",title:"TS fixture",body:"",labels:[{name:"ai-build"}]}'
    done | jq -sc . ;;
  *"issues/"*"/comments?since="*)
    n=\$(sed -nE 's#.*issues/([0-9]+)/comments.*#\\1#p' <<<"\$a")
    printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/comments-\$n.json" 2>/dev/null || echo '[]' ;;
  *"repos/example-org/project-5 "*|*"repos/example-org/project-5") printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n' ;;
  *) echo "\$a" >> "$T/realgh.log"; printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n' ;;
esac
exit 0
GH
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"; : > "$T/gh-calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_PROJECT_5=fixture-fly-token FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H/builds"/* \
           "$T"/comments-*.json "$T"/upd-* "$T/open-prs.502"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"
  return 0
}
# open_prs <key-lower...> — the open-PR list: one PR per ticket/<branch>.
open_prs() {
  local b n=3950
  for b in "$@"; do
    n=$((n + 1))
    jq -nc --arg r "ticket/$b" --argjson n "$n" \
      '{number:$n,title:"fixture",html_url:"https://github.com/example-org/project-5/pull/\($n)",head:{ref:$r,repo:{owner:{login:"example-org"}}}}'
  done | jq -sc . > "$T/open-prs.json"
}
# qrow <key> — a queued row with NO `after` (the TK-3786 shape).
qrow() {
  jq -nc --arg k "$1" --arg t "${1#TK-}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:3,deaths:0,enqueued_at:"2026-10-20T13:00:00Z"}' \
    > "$H/state/build-queue/project-5/$1.json"
}
# rec <key> <stamp> <age-s> <RESULT line 1> — one hub record, mtime NOW-age.
rec() {
  local d="$H/builds/pool-project-5-$1-$2"; mkdir -p "$d"
  printf '%s\n' "$4" > "$d/RESULT"
  touch -d "@$((NOW - $3))" "$d/RESULT"
}
recd() { printf '%s' "$H/builds/pool-project-5-$1-$2"; }
spawned() { local c; c=$(grep -c 'machine run' "$T/fly-calls" 2>/dev/null); echo "${c:-0}"; }
lines() { local c; c=$(grep -cF "$1" "$H/logs/fly-pool.log" 2>/dev/null); echo "${c:-0}"; }
reads() { local c; c=$(grep -cF "$1" "$T/gh-calls" 2>/dev/null); echo "${c:-0}"; }
log_of() { grep -E "$1" "$H/logs/fly-pool.log" | tail -3 | tr '\n' '|'; }
QF="$H/state/build-queue/project-5/TK-3786.json"
AFTER="BUILD_DEFERRED After: TK-3785 PR #3958 open — TK-3786 overlaps it on a non-splittable file and builds after it merges; re-checked each tick before any plan is bought"
SKIP="skipping TK-3786: waits on TK-3785 PR #3958 open — no machine"

# ── D1: the live case, red on main ────────────────────────────────────────
reset_state; open_prs TK-3785; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
for tick in 1 2; do
  run_pool
  [ "$(spawned)" = 0 ] && ok || bad "D1: THE BUG: tick $tick spawned $(spawned) machine(s) for TK-3786 while TK-3785's PR is open"
  [ "$(lines "$SKIP")" = 1 ] && ok || bad "D1: tick $tick wants exactly one skip line, got $(lines "$SKIP"): $(log_of TK-3786)"
  [ -e "$QF" ] && ok || bad "D1: tick $tick: the queue file must stay"
  grep -q 'TK-3786' "$T/q.log" && bad "D1: tick $tick: no QROW write for a held row ($(tr '\n' '|' < "$T/q.log"))" || ok
done

# ── D2: the blocker PR merged or closed: spawns ───────────────────────────
reset_state; open_prs TK-9999; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
run_pool
[ "$(spawned)" = 1 ] && ok || bad "D2: TK-3785 has no open PR, so TK-3786 spawns ($(spawned)): $(log_of TK-3786)"
[ "$(lines 'waits on TK-3785')" = 0 ] && ok || bad "D2: no wait line: $(log_of TK-3786)"

# ── D3: no such record: spawns as today ───────────────────────────────────
d3() { # d3 <id> <RESULT line or empty>
  reset_state; open_prs TK-3785; qrow TK-3786
  [ -n "$2" ] && rec TK-3786 s1 600 "$2"
  run_pool
  [ "$(spawned)" = 1 ] && ok || bad "$1: spawns ($(spawned)): $(log_of TK-3786)"
  [ "$(lines 'waits on')" = 0 ] && ok || bad "$1: not read as a wait: $(log_of TK-3786)"
}
d3 D3 ""
d3 D3b "BUILD_DEFERRED slot held on this machine"
d3 D3c "PR_CREATED https://github.com/example-org/project-5/pull/4001 After: TK-3785"

# ── D4: OVERLAP_DEFER shapes: held ────────────────────────────────────────
reset_state; open_prs TK-3785; qrow TK-3786
rec TK-3786 s1 600 "BUILD_DEFERRED OVERLAP_DEFER TK-3786 vs TK-3785 files=[bin/x.sh]; After: TK-3785 — held until it merges (not before 2026-11-04 10:00:00Z), then the next triage tick re-offers TK-3786 to any free box"
run_pool
[ "$(spawned)" = 0 ] && [ "$(lines 'skipping TK-3786: waits on TK-3785 PR open — no machine')" = 1 ] && ok \
  || bad "D4: OVERLAP_DEFER with After: on an open PR is held ($(spawned) spawned): $(log_of TK-3786)"
reset_state; open_prs TK-3785-r2; qrow TK-3786
rec TK-3786 s1 600 "BUILD_DEFERRED OVERLAP_DEFER TK-3786 vs TK-3785-r2 files=[bin/x.sh]; not before 2026-11-04 10:00:00Z, then the next triage tick re-offers TK-3786 to any free box"
run_pool
[ "$(spawned)" = 0 ] && [ "$(lines 'skipping TK-3786: waits on TK-3785 PR open — no machine')" = 1 ] && ok \
  || bad "D4b: OVERLAP_DEFER vs TK-3785-r2 with its -r2 PR open is held ($(spawned) spawned): $(log_of TK-3786)"

# ── D5: only the newest record counts ─────────────────────────────────────
reset_state; open_prs TK-3785; qrow TK-3786
rec TK-3786 s1 1200 "$AFTER"
rec TK-3786 s2 300 "BUILD_DEFERRED factory-stop at plan — the factory is stopped"
run_pool
[ "$(spawned)" = 1 ] && ok || bad "D5: the newest record is not an After deferral, so TK-3786 spawns ($(spawned)): $(log_of TK-3786)"

# ── D6: a person comment since the record releases the key ───────────────
reset_state; open_prs TK-3785; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
iso $((NOW - 60)) > "$T/upd-3786"
jq -nc --arg c "$(iso $((NOW - 60)))" '[{user:{login:"client-fixture",type:"User"},created_at:$c,updated_at:$c,body:"go"}]' > "$T/comments-3786.json"
run_pool
[ "$(spawned)" = 1 ] && ok || bad "D6: a person comment releases TK-3786 ($(spawned) spawned): $(log_of TK-3786)"
[ -e "$(recd TK-3786 s1)/defer-after.released" ] && ok || bad "D6: the released marker is written"
[ "$(lines 'RELEASED TK-3786: waits on TK-3785 PR #3958 open, but a person commented on #3786 since the stand-down')" = 1 ] && ok \
  || bad "D6: one RELEASED line: $(log_of TK-3786)"
for p in "$H/state/fly-pool/project-5"/*.json; do [ -e "$p" ] && scratch_rm "$p"; done
qrow TK-3786; run_pool
[ "$(spawned)" = 1 ] && [ "$(reads 'comments?since=')" = 0 ] && ok \
  || bad "D6: the next tick spawns on the marker with no comments read ($(spawned) spawned, $(reads 'comments?since=') reads)"

# D6b: a bot comment does not release.
reset_state; open_prs TK-3785; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
iso $((NOW - 60)) > "$T/upd-3786"
jq -nc --arg c "$(iso $((NOW - 60)))" '[{user:{login:"ci-bot",type:"Bot"},created_at:$c,updated_at:$c,body:"x"}]' > "$T/comments-3786.json"
run_pool
[ "$(spawned)" = 0 ] && [ "$(lines "$SKIP")" = 1 ] && ok || bad "D6b: a bot comment holds ($(spawned) spawned): $(log_of TK-3786)"
[ "$(reads 'comments?since=')" = 1 ] && ok || bad "D6b: one comments read ($(reads 'comments?since='))"
[ "$(head -1 "$(recd TK-3786 s1)/defer-after.seen" 2>/dev/null)" = "$(cat "$T/upd-3786")" ] && ok || bad "D6b: the seen marker holds the listing's updated_at"
run_pool
[ "$(spawned)" = 0 ] && [ "$(reads 'comments?since=')" = 0 ] && ok \
  || bad "D6b: the same listing reads no comments on the next tick ($(spawned) spawned, $(reads 'comments?since=') reads)"

# ── D7: the listing says the issue did not change: no comments read ──────
reset_state; open_prs TK-3785; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
iso $((NOW - 3600)) > "$T/upd-3786"
run_pool
[ "$(spawned)" = 0 ] && [ "$(reads 'comments?since=')" = 0 ] && [ "$(lines "$SKIP")" = 1 ] && ok \
  || bad "D7: held with no comments read ($(spawned) spawned, $(reads 'comments?since=') reads): $(log_of TK-3786)"

# ── D8: an unreadable open-PR list holds the row ──────────────────────────
reset_state; open_prs TK-3785; : > "$T/open-prs.502"; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
run_pool
[ "$(spawned)" = 0 ] && ok || bad "D8: no machine on an unreadable list ($(spawned))"
[ "$(lines 'skipping TK-3786: waits on TK-3785, and the open-PR list did not answer — retried next tick, no machine')" = 1 ] && ok \
  || bad "D8: the retry line: $(log_of TK-3786)"
[ "$(lines 'PR #3958 open')" = 0 ] && ok || bad "D8: an unreadable list never says the PR is open"

# ── D9: self, child and lower-case keys are not blockers ─────────────────
d3 D9a "BUILD_DEFERRED After: TK-3786 PR #3958 open — x"
d3 D9b "BUILD_DEFERRED After: TK-3785.2 PR #3958 open — x"
d3 D9c "BUILD_DEFERRED waits; after: TK-3785 PR #3958 open — x"

# ── D10: the knob turns the gate off ──────────────────────────────────────
reset_state; open_prs TK-3785; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
run_pool POOL_DEFER_AFTER_STOP=0
[ "$(spawned)" = 1 ] && [ "$(lines 'waits on TK-3785')" = 0 ] && ok \
  || bad "D10: POOL_DEFER_AFTER_STOP=0 spawns as before ($(spawned)): $(log_of TK-3786)"

# ── D11: one open-list read for two waiting keys ─────────────────────────
reset_state; open_prs TK-3785; qrow TK-3786; qrow TK-3787
rec TK-3786 s1 600 "$AFTER"
rec TK-3787 s1 600 "BUILD_DEFERRED After: TK-3785 PR #3958 open — TK-3787 overlaps it"
run_pool
[ "$(spawned)" = 0 ] && [ "$(lines 'waits on TK-3785 PR #3958 open — no machine')" = 2 ] && ok \
  || bad "D11: both keys are held ($(spawned) spawned): $(log_of 'TK-378[67]')"
[ "$(reads 'pulls?state=open&per_page=100&page=1')" = 1 ] && ok \
  || bad "D11: one open-list read in the tick, got $(reads 'pulls?state=open&per_page=100&page=1')"

# ── D12: a mutual wait is not held here ──────────────────────────────────
reset_state; open_prs TK-3785 TK-3786; qrow TK-3786; rec TK-3786 s1 600 "$AFTER"
rec TK-3785 s1 600 "BUILD_DEFERRED After: TK-3786 PR #3999 open — TK-3785 overlaps it"
run_pool
[ "$(lines 'TK-3786: waits on TK-3785, and TK-3785 waits on TK-3786 — not held here')" = 1 ] && ok \
  || bad "D12: the mutual line: $(log_of TK-3786)"
[ "$(lines 'skipping TK-3786: waits on')" = 0 ] && [ "$(spawned)" = 1 ] && ok \
  || bad "D12: a mutual wait is not held by this gate ($(spawned) spawned): $(log_of TK-3786)"

# ── G: 0 real network ─────────────────────────────────────────────────────
[ ! -s "$T/realgh.log" ] && ok || bad "G: a gh call the fake does not know: $(head -3 "$T/realgh.log" | tr '\n' '|')"

echo "pool-defer-after-stop.bh-8880: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
