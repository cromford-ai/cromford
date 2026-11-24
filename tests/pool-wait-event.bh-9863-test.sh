#!/bin/bash
# tests/pool-wait-event.bh-9863-test.sh — BH-9863: a pool row held on a
# blocker (bin/lib/defer-after-stop.sh) is checked again on the NEXT tick when
# the blocker changes in local state (bin/lib/wait-sig.sh), not only on the
# 10/20/40 ... 240 min clock.
#
# THE INCIDENT. project-3, 2026-11-20 02:00-13:50Z: 6 ready tickets stayed
# queued with no spawn while 1 build ran. A row deferred on an overlap read the
# open-PR list again only when its clock was due, so a blocker that merged
# between two checks stayed unseen for up to 240 min.
#
#   G1-G9  ws_blocker_sig: each signal moves it, near misses do not
#   W2     the wait line round-trips 7 fields; an old 6-field line reads no sig
#   A1     TK-3660 waits on TK-3659 (OVERLAP_DEFER): A's PR appears at minute 5
#          (forced check, held), A merges at minute 15: TK-3660 spawns at
#          minute 15. The old code re-checks at 10 and 30 only.
#   E1-E5  0 reads on a not-due tick with no change, an unrelated URL, a URL
#          prefix, a TK-36590 record; an old 6-field line stores its sig and
#          does not read
#   V1-V2  out-of-scope files unchanged
#   G0     every gh and fly call is a fake
#
# Driven through bin/fly-pool.sh on the tests/pool-wait-gates.bh-9283 rig.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-wait-event.bh-9863-test.sh
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

P=project-6
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/$P" \
         "$H/state/build-queue/$P" "$H/state/remote-results/$P" \
         "$H/state/pool/$P" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-6=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf '%s example-org/%s - - 0 local\n' "$P" "$P" > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-$P"
printf 'pool-%s\n' "$P" > "$H/flags/fly-pool-app-$P"
printf '{"app":"pool-%s"}\n' "$P" > "$H/state/fly/$P.json"
printf 'registry.fly.io/pool-%s:deploy-01\n' "$P" > "$H/state/fly/$P.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh \
         bin/lib/defer-after-stop.sh bin/lib/plan-blocked.sh bin/lib/tracker.sh bin/lib/gh-rest.sh \
         bin/lib/pool-hold-cache.sh bin/lib/stack-wait.sh bin/lib/wait-sig.sh; do
  [ -f "$DIR/$L" ] || { bad "$L is missing"; continue; }
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
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
# gh: the 8880 fake on example-org/project-6, issues 3577 3578 3659 3660.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
a="\$*"
if [[ "\$a" == *"--paginate"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$a" != *"-i"* ]]; then
  if [[ "\$a" =~ issues/([0-9]+) ]]; then
    echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"MK fixture","body":""}'; exit 0
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
    for n in 3577 3578 3659 3660; do
      jq -nc --argjson n "\$n" --arg u "\$(cat "$T/upd-\$n" 2>/dev/null || echo 2026-10-20T00:00:00Z)" \
        '{number:\$n,updated_at:\$u,comments:0,state:"open",title:"MK fixture",body:"",labels:[{name:"ai-build"}]}'
    done | jq -sc . ;;
  *"issues/"*"/comments?since="*)
    n=\$(sed -nE 's#.*issues/([0-9]+)/comments.*#\\1#p' <<<"\$a")
    printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/comments-\$n.json" 2>/dev/null || echo '[]' ;;
  *"repos/example-org/project-6 "*|*"repos/example-org/project-6") printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-6"}\\n' ;;
  *) echo "\$a" >> "$T/realgh.log"; printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n' ;;
esac
exit 0
GH
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

# run_pool <minute> [VAR=value...] — one pool tick with the gate clock at
# NOW + minute*60 (a minute may carry seconds as M:S).
run_pool() {
  local m="$1" s=0; shift
  case "$m" in *:*) s="${m#*:}"; m="${m%%:*}" ;; esac
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"; : > "$T/gh-calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-6=fixture-fly-token FLY_BIN_DIR="$T/fakebin" \
           DFS_NOW=$((NOW + m * 60 + s)) "$@"
    bash "$DIR/bin/fly-pool.sh" "$P" >/dev/null 2>&1 )
}
reset_state() {
  local p
  for p in "$H/state/build-queue/$P"/*.json \
           "$H/state/fly-pool/$P"/*.json \
           "$H/state/pool/$P"/* "$H/builds"/* \
           "$T"/comments-*.json "$T"/upd-* "$T/open-prs.502"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"
  return 0
}
# respawnable — drop the machine records so the row is offered again.
respawnable() { local p; for p in "$H/state/fly-pool/$P"/*.json; do [ -e "$p" ] && scratch_rm "$p"; done; return 0; }
open_prs() {
  local b n=3700
  for b in "$@"; do
    n=$((n + 1))
    jq -nc --arg r "ticket/$b" --argjson n "$n" \
      '{number:$n,title:"fixture",html_url:"https://github.com/example-org/project-6/pull/\($n)",head:{ref:$r,repo:{owner:{login:"example-org"}}}}'
  done | jq -sc . > "$T/open-prs.json"
}
qrow() {
  jq -nc --arg k "$1" --arg t "${1#TK-}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:3,deaths:0,enqueued_at:"2026-11-06T13:00:00Z"}' \
    > "$H/state/build-queue/$P/$1.json"
}
# rec <key> <stamp> <age-s> <RESULT line 1> — one hub record, mtime NOW-age
# (a negative age is a record written later in the test).
rec() {
  local d="$H/builds/pool-$P-$1-$2"; mkdir -p "$d"
  printf '%s\n' "$4" > "$d/RESULT"
  touch -d "@$((NOW - $3))" "$d/RESULT"
}
recd() { printf '%s' "$H/builds/pool-$P-$1-$2"; }
spawned() { local c; c=$(grep -c 'machine run' "$T/fly-calls" 2>/dev/null); echo "${c:-0}"; }
lines() { local c; c=$(grep -cF "$1" "$H/logs/fly-pool.log" 2>/dev/null); echo "${c:-0}"; }
LREAD='pulls?state=open&per_page=100&page=1'
reads() { local c; c=$(grep -cF "${1:-$LREAD}" "$T/gh-calls" 2>/dev/null); echo "${c:-0}"; }
alerts() { local c; c=$(grep -cF "${1:-WAIT LIMIT}" "$H/logs/ALERTS.log" 2>/dev/null); echo "${c:-0}"; }
log_of() { grep -E "$1" "$H/logs/fly-pool.log" | tail -3 | tr '\n' '|'; }
WAITF="$H/state/pool/$P/TK-3660.dfs-wait"
HELDF="$H/state/pool/$P/TK-3660.held"
STACK="BUILD_DEFERRED stack-wait: parent branch ticket/TK-3659 is still open and TK-3660 has waited 0h of STACK_WAIT_CAP_H=24h — Blocked-by #3659; the child builds after the parent merges"
SKIP="skipping TK-3660: waits on TK-3659 PR open — no machine"
AFTER="BUILD_DEFERRED After: TK-3578 PR #3597 open — TK-3577 overlaps it on a non-splittable file and builds after it merges"
OVL="BUILD_DEFERRED OVERLAP_DEFER TK-3660 vs TK-3659 files=[app/x.ts]"
AURL="https://github.com/example-org/project-6/pull/3701"
DONE="$H/state/merge-sweep-done.txt"
CW="$H/state/merge-conductor/closed-watch/example-org_project-6"
wipe_world() { local p; for p in "$DONE" "$H/state/merge-conductor" "$H/state/$P.prstates"; do [ -e "$p" ] && scratch_rm "$p"; done; return 0; }

# ── G1-G9: the blocker signature ─────────────────────────────────────────
sig() { ( HARNESS="$H"; . "$DIR/bin/lib/wait-sig.sh" 2>/dev/null; ws_blocker_sig "$H" "$P" TK-3659 example-org/project-6 ) 2>/dev/null; }
gmove() { # gmove <id> <before> <want moved|same> <what>
  local a; a=$(sig)
  case "$3" in
    moved) [ -n "$a" ] && [ "$a" != "$2" ] && ok || bad "$1: $4 must move the sig ('$2' -> '$a')" ;;
    same)  [ -n "$a" ] && [ "$a" = "$2" ] && ok || bad "$1: $4 must not move the sig ('$2' -> '$a')" ;;
  esac
}
reset_state; wipe_world
S0=$(sig)
[[ "$S0" =~ ^[0-9a-f]{16}$ ]] && ok || bad "G1: no record gives a 16-hex sig, got '$S0'"
gmove G1 "$S0" same "a second read of the same world"
rec TK-3659 g2 120 "BUILD_FAILED tests red"; S1=$(sig)
[ "$S1" != "$S0" ] && ok || bad "G2: a first record of the blocker must move the sig"
rec TK-3659 g3 60 "PR_CREATED $AURL"; S2=$(sig)
[ "$S2" != "$S1" ] && ok || bad "G2: a newer record (the build ended with a PR) must move the sig"
: > "$(recd TK-3659 g3)/COMMENTED"; gmove G3 "$S2" moved "COMMENTED on the blocker's record"; S3=$(sig)
echo "https://github.com/example-org/project-6/pull/9999" >> "$DONE"; gmove G6 "$S3" same "an unrelated URL in merge-sweep-done.txt"
echo "https://github.com/example-org/project-6/pull/37010" >> "$DONE"; gmove G7 "$S3" same "a URL that starts with the blocker URL (/pull/37010)"
rec TK-36590 g8 10 "PR_CREATED https://github.com/example-org/project-6/pull/8"; gmove G8 "$S3" same "a record of TK-36590"
echo "$AURL" >> "$DONE"; gmove G4 "$S3" moved "the blocker's URL in merge-sweep-done.txt"; S4=$(sig)
mkdir -p "$CW"; printf 'merged\t1\t%s\tticket/TK-3659\n' "$AURL" > "$CW/3701"; gmove G5 "$S4" moved "a closed-watch memo"; S5=$(sig)
printf '3701\tMERGED\t1\n' > "$H/state/$P.prstates"; gmove G9 "$S5" moved "a prstates entry"; S6=$(sig)
qrow TK-3659; gmove G9 "$S6" moved "the blocker's queue file"

# ── W2: 7 fields round-trip; an old 6-field line ─────────────────────────
reset_state
W=$( ( HARNESS="$H"; . "$DIR/bin/lib/deferral-after.sh"; . "$DIR/bin/lib/defer-after-stop.sh"
       _dfs_wait_put "$P" TK-3660 TK-3659 after 1000 3 4000 1500 abcdef0123456789
       printf '%s|' "$(_dfs_wait_get "$P" TK-3660 | tr '\t' ',')"
       _dfs_wait_load "$P" TK-3660 TK-3659 after 9000
       printf '%s,%s,%s,%s,%s,%s|' "$_DFS_W_SINCE" "$_DFS_W_CHECKS" "$_DFS_W_NEXT" "$_DFS_W_ALERTED" "$_DFS_W_NEW" "${_DFS_W_SIG-unset}"
       _dfs_wait_put "$P" TK-3660 TK-3659 after 1000 3 4000 1500
       _dfs_wait_load "$P" TK-3660 TK-3659 after 9000
       printf '%s,%s,%s' "$_DFS_W_ALERTED" "$_DFS_W_NEW" "${_DFS_W_SIG-unset}" ) 2>&1)
[ "$W" = "TK-3659,after,1000,3,4000,1500,abcdef0123456789|1000,3,4000,1500,0,abcdef0123456789|1500,0," ] && ok \
  || bad "W2: wants 'TK-3659,after,1000,3,4000,1500,abcdef0123456789|1000,3,4000,1500,0,abcdef0123456789|1500,0,', got '$W'"

# ── A1: the blocker's PR merges; the waiting row spawns on the next tick ──
reset_state; wipe_world; open_prs TK-3659; qrow TK-3660; rec TK-3660 a1 600 "$OVL"
run_pool 0
[ "$(spawned)" = 0 ] && [ "$(reads)" = 1 ] && ok || bad "A1: minute 0 holds with 1 read ($(spawned) spawned, $(reads) reads): $(log_of TK-3660)"
rec TK-3659 a1 -300 "PR_CREATED $AURL"
run_pool 5
[ "$(spawned)" = 0 ] && [ "$(reads)" = 1 ] && ok \
  || bad "A1: minute 5, TK-3659's build ended with an open PR: a forced check holds with 1 read ($(spawned) spawned, $(reads) reads): $(log_of TK-3660)"
[ "$(lines 're-check now: TK-3659 changed since the last check')" = 1 ] && ok \
  || bad "A1: minute 5 says 're-check now: TK-3659 changed since the last check': $(log_of TK-3660)"
[ "$(lines 'skipping TK-3660: waits on TK-3659')" = 1 ] && ok || bad "A1: minute 5: the re-check line sits next to the skip line: $(log_of TK-3660)"
run_pool 10
[ "$(spawned)" = 0 ] && [ "$(reads)" = 0 ] && [ "$(lines 're-check now')" = 0 ] && ok \
  || bad "A1: minute 10, nothing changed: held with 0 reads ($(spawned) spawned, $(reads) reads): $(log_of TK-3660)"
open_prs TK-9999; echo "$AURL" >> "$DONE"
run_pool 15
[ "$(reads)" = 1 ] && [ "$(spawned)" = 1 ] && ok \
  || bad "A1: THE BUG: minute 15, TK-3659 merged: TK-3660 must spawn now ($(spawned) spawned, $(reads) reads): $(log_of TK-3660)"
[ ! -e "$WAITF" ] && [ ! -e "$HELDF" ] && ok || bad "A1: the release removes .dfs-wait and .held"
[ ! -e "$T/upd-3660" ] && ok || bad "A1: the TK-3660 board entry is never changed"

# ── E1-E4: no read without a real change ─────────────────────────────────
# e_case <id> <what> <command> — minute 0 reads, then the change, minute 5: 0 reads.
e_case() {
  reset_state; wipe_world; open_prs TK-3659; qrow TK-3660; rec TK-3660 e1 600 "$OVL"
  rec TK-3659 e1 300 "PR_CREATED $AURL"
  run_pool 0
  eval "$3"
  run_pool 5
  [ "$(reads)" = 0 ] && [ "$(spawned)" = 0 ] && [ "$(lines 're-check now')" = 0 ] && ok \
    || bad "$1: $2 on a not-due tick: 0 reads, 0 machines ($(reads) reads, $(spawned) spawned): $(log_of TK-3660)"
}
e_case E1 "no change" ":"
e_case E2 "an unrelated URL in merge-sweep-done.txt" 'echo "https://github.com/example-org/project-6/pull/9999" >> "$DONE"'
e_case E3 "the blocker URL as a prefix (/pull/37010)" 'echo "https://github.com/example-org/project-6/pull/37010" >> "$DONE"'
e_case E4 "a TK-36590 record" 'rec TK-36590 e4 -60 "PR_MERGED https://github.com/example-org/project-6/pull/3701"'

# ── E5: a wait line from before this change (6 fields) ───────────────────
reset_state; wipe_world; open_prs TK-3659; qrow TK-3660; rec TK-3660 e5 600 "$OVL"
mkdir -p "$H/state/pool/$P"
printf 'TK-3659\tafter\t%s\t1\t%s\t\n' "$NOW" "$((NOW + 3600))" > "$WAITF"
run_pool 5
[ "$(reads)" = 0 ] && [ "$(spawned)" = 0 ] && ok || bad "E5: an old 6-field line, not due: 0 reads ($(reads) reads, $(spawned) spawned)"
F7=$(awk -F'\t' '{print $7}' "$WAITF" 2>/dev/null)
[[ "$F7" =~ ^[0-9a-f]{16}$ ]] && [ "$(awk -F'\t' '{print $4}' "$WAITF")" = 1 ] && ok \
  || bad "E5: the old line gets the sig as field 7 and keeps checks=1: [$(tr '\t' ',' < "$WAITF" 2>/dev/null)]"
rec TK-3659 e5 -120 "PR_CREATED $AURL"
run_pool 6
[ "$(reads)" = 1 ] && [ "$(spawned)" = 0 ] && ok || bad "E5: then a blocker change forces 1 read ($(reads) reads, $(spawned) spawned)"

# ── V1-V2: out of scope stays out ────────────────────────────────────────
# Own slice ONLY (the BH-1939 L4/L5 pattern, BH-5684): a later ticket that edits
# these paths for its OWN work, or a merge-queue batch carrying one, must not be
# judged by BH-9863's "untouched" rule. So V1-V2 bite only when this branch
# carries BH-9863's own spec.
VOWN=0; VREF="${GITHUB_HEAD_REF:-$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-9863's own slice
  VFILES=$(git -C "$DIR" diff --name-only origin/main...HEAD 2>/dev/null)
  grep -qE '^\.harness/specs/BH-9863/' <<<"$VFILES" && VOWN=1
  case "$VREF" in mergify/merge-queue/*) VOWN=0 ;; esac
  if [ "$VOWN" = 0 ]; then
    echo "V1-V2: SKIP (scoped) judges only BH-9863's own branch; this diff is another ticket's"
  else
    # pr-scoped: ok slice-gated: runs only when VOWN=1 (this branch carries BH-9863's own spec)
    VD=$(git -C "$DIR" diff --name-only origin/main...HEAD -- worker/jobs/schema.d bin/overlap-guard.sh bin/plan-overlap.sh 2>&1); RC=$?
    ! grep -q '^worker/jobs/schema\.d' <<<"$VD" && [ "$RC" = 0 ] && ok || bad "V1: worker/jobs/schema.d changed (rc=$RC): $VD"
    ! grep -qE '^bin/(overlap-guard|plan-overlap)\.sh$' <<<"$VD" && [ "$RC" = 0 ] && ok \
      || bad "V2: the overlap-guard decision changed (bin/overlap-guard.sh / bin/plan-overlap.sh): $VD"
  fi
else
  echo "note: V1-V2 skipped: no origin/main"
fi

# ── G0: 0 real network ────────────────────────────────────────────────────
[ ! -s "$T/realgh.log" ] && ok || bad "G0: a gh call the fake does not know: $(head -3 "$T/realgh.log" | tr '\n' '|')"

echo "pool-wait-event.bh-9863: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
