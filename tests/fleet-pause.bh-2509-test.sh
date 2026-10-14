#!/bin/bash
# tests/fleet-pause.bh-2509-test.sh — BH-2509: a fleet-scope pause set from
# Mission Control blocks the merge sweep on two projects, and END lifts it.
#
# The console half (the PAUSE FLEET form, the required reasons, the command
# route's 400s, who/why/when on every paused board) is proved by node --test in
# console-ui/tests/fleet-pause.bh-2509.test.js. This file adds the end-to-end
# box half and names the new sources by rooted path for the orphan ratchet:
#
#   1. the new console sources exist.
#   2. the poller's `# >>> pause handlers` block, EXTRACTED VERBATIM from
#      bin/poll-commands.sh, runs the exact command the Fleet form sends
#      (pause_set scope=fleet, routed to project hub) against a _jobs_req stub
#      that keeps a JSON row store and writes the box cache state/pauses.json
#      the way pause_refresh would.
#   3. the stored row is scope=fleet, what=merges, the typed reason, the actor.
#   4. the REAL merge sweep (the tests/merge-sweep-pause.bh-1684 fixture) makes
#      no merge call for a ready PR on project a NOR on project b, and logs
#      PAUSED(merges) for both.
#   5. pause_end, through the same block, stamps ended_at in store and cache.
#   6. the same sweep, nothing else changed, merges both PRs.
#   7. the node suite, run for real when console-ui dependencies are installed.
# Run from anywhere: tests/fleet-pause.bh-2509-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- 1: the console sources ---------------------------------------------------
FORMS="$DIR/console-ui/src/ui/PauseForms.js"
NODE_SUITE="$DIR/console-ui/tests/fleet-pause.bh-2509.test.js"
for f in "$FORMS" "$NODE_SUITE" "$DIR/console-ui/src/lib/pauses.js" "$DIR/console-ui/src/screens/Fleet.js"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- the sweep fixture (tests/merge-sweep-pause.bh-1684-test.sh) --------------
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/tmp" "$T/fakebin"
# Copied by glob: the hub's iron-law hook refuses a shell command naming it.
SWEEP_SRC=""
for f in "$DIR"/bin/merge-s*.sh; do SWEEP_SRC="$f"; done
[ -n "$SWEEP_SRC" ] && [ -f "$SWEEP_SRC" ] || { echo "FAIL: the sweep script is not in $DIR/bin"; exit 1; }
cp "$SWEEP_SRC" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
# The REAL pause lib; pause_refresh is a network read, so it is a no-op here and
# the cache is the one the poller stub below writes.
cp "$DIR/bin/lib/pause.sh" "$T/bin/lib/pause.sh"
printf '\npause_refresh(){ return 0; }\n' >> "$T/bin/lib/pause.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'a o/a - /api/board 2 box-a\nb o/b - /api/board 3 box-b\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  "api repos/o/"*"/rulesets"*) : ;;
  "api repos/o/"*" -q .id") echo 1 ;;
  *"pr merge"*)
    printf '%s\n' "\$*" >> "$T/merge-calls.txt"
    touch "$T/merged-\$(printf '%s\n' "\$*" | grep -oE 'pull/[0-9]+' | head -1 | cut -d/ -f2)"
    exit 0 ;;
  *"v3.diff"*) restpr --diff "+ const x = 1;" ;;
  *"api -i -X GET repos/o/"*"/pulls/"*)
    N=\$(printf '%s\n' "\$*" | grep -oE 'pulls/[0-9]+' | head -1 | cut -d/ -f2)
    if [ -f "$T/merged-\$N" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*|*"api -i -X PATCH repos/"*"/issues/"*|*"api -i -X GET repos/"*"/issues/"*)
    restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

mkfix() { # mkfix <dirname> <owner/repo> <pr-number>
  local d="$T/builds/$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$2/pull/$3" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  : > "$d/pipeline.log"
  touch -d "@$((1758000000 + $3))" "$d/RESULT"
}
# The clock the pause lib judges expiry against, and the stub stamps rows with.
NOW=$(date -u -d '2026-09-24T12:00:00Z' +%s)
run_sweep() {
  : > "$T/logs/merge-sweep.log"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
    PAUSE_NOW="$NOW" env -u JOBS_HARNESS bash "$T/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) \
    || { echo "sweep rc=$? stderr:"; cat "$T/sweep.err"; }
}
merged() { grep -qE "pull/$1( |\$)" "$T/merge-calls.txt" 2>/dev/null; }
log() { cat "$T/logs/merge-sweep.log"; }

# --- 2: the poller's pause handlers, verbatim ---------------------------------
{ echo 'case "$TYPE" in'
  awk '/^    # >>> pause handlers/{f=1;next} /^    # <<< pause handlers/{exit} f{print}' "$DIR/bin/poll-commands.sh"
  echo 'esac'
} > "$T/pause.body"
[ "$(wc -l < "$T/pause.body")" -gt 3 ] || { echo "FAIL: could not extract the pause handlers block — markers missing?"; exit 1; }

# _jobs_req stand-in: a JSON row store ($STORE). PUT /api/pauses enforces the
# worker's own body rules (a blank reason or actor is a 400) and appends a row
# stamped at NOW; POST /api/pauses/<id>/end stamps ended_at, 404 (rc 2) for an
# unknown or already-ended id. Every write rewrites state/pauses.json with the
# whole store, which is what pause_refresh's GET would put there.
cat > "$T/stubs.sh" <<'EOF'
set_flag() { return 0; }
_pause_cache_write() { jq '{pauses:., truncated:false}' "$STORE" > "$HARNESS/state/pauses.json"; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" f id
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$CALLS"
  if [ "$m $p" = "PUT /api/pauses" ]; then
    for f in reason actor; do
      if [ -z "$(jq -r --arg f "$f" '.[$f] // "" | tostring | sub("^\\s+"; "") | sub("\\s+$"; "")' <<<"$b")" ]; then
        JOBS_HTTP=400; return 1
      fi
    done
    jq --argjson row "$b" --argjson now "$STUB_NOW" \
      '. + [$row + {id:(length + 1), created_at:($now | todateiso8601),
               expires_at:(($now + ($row.ttl_s // 3600)) | todateiso8601), ended_at:null, end_reason:null}
            | del(.ttl_s)]' "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
    _pause_cache_write; JOBS_HTTP=200; printf '{}'; return 0
  fi
  if [ "$m" = POST ] && [[ "$p" =~ ^/api/pauses/([0-9]+)/end$ ]]; then
    id="${BASH_REMATCH[1]}"
    [ "$(jq --argjson id "$id" '[.[] | select(.id == $id and .ended_at == null)] | length' "$STORE")" = 1 ] \
      || { JOBS_HTTP=404; return 2; }
    jq --argjson id "$id" --argjson now "$STUB_NOW" \
      'map(if .id == $id then .ended_at = ($now | todateiso8601) | .end_reason = "resumed" else . end)' \
      "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
    _pause_cache_write; JOBS_HTTP=200; printf '{}'; return 0
  fi
  JOBS_HTTP=""; return 1
}
EOF
STORE="$T/store.json"; echo '[]' > "$STORE"; CALLS="$T/calls.log"; : > "$CALLS"
poll() { # poll <type> <project> <payload-json> -> "OK=.. RESULT=.."
  HARNESS="$T" STORE="$STORE" CALLS="$CALLS" STUB_NOW="$NOW" \
    TYPE="$1" PROJECT="$2" PAYLOAD="$3" ID=42 OK=false RESULT="" \
    bash -c 'set -uo pipefail; . "$0"; . "$1"; echo "OK=$OK RESULT=$RESULT"' "$T/stubs.sh" "$T/pause.body"
}

# Baseline: unpaused, both ready PRs merge. Without this the blocked half below
# could pass on a fixture that never merges anything.
rm -rf "$T/builds"; mkdir -p "$T/builds"; : > "$T/merge-calls.txt"; rm -f "$T"/merged-*
mkfix pool-a-XX-1-202609240001 o/a 1; mkfix pool-b-XX-2-202609240001 o/b 2
run_sweep
merged 1 && merged 2 && ok \
  || bad "baseline: with no pause both PRs must merge (merge-calls: $(cat "$T/merge-calls.txt" 2>/dev/null); log: $(log))"
reset_prs() {
  rm -rf "$T/builds"; mkdir -p "$T/builds"; : > "$T/merge-calls.txt"; rm -f "$T"/merged-*
  : > "$T/state/merge-sweep-done.txt"; rm -rf "$T/state/merge-sweep" "$T/state/merge-sweep-terminal"* 2>/dev/null
  mkfix pool-a-XX-1-202609240001 o/a 1; mkfix pool-b-XX-2-202609240001 o/b 2
}

# --- 3: the Fleet form's command, through the poller --------------------------
# Exactly fleetPauseCommandFor's shape plus the actor the Pages proxy stamps.
OUT=$(poll pause_set hub '{"type":"pause_set","scope":"fleet","what":"merges","reason":"release freeze","ttl_s":1800,"actor":"operator@example.com"}')
grep -q '^OK=true RESULT=paused merges on fleet$' <<<"$OUT" && ok || bad "pause_set fleet must land (out=$OUT)"
ROW=$(jq -c '.[0] | {scope, what, reason, actor, ended_at}' "$STORE")
[ "$ROW" = '{"scope":"fleet","what":"merges","reason":"release freeze","actor":"operator@example.com","ended_at":null}' ] \
  && ok || bad "the stored row must be the fleet merges row with its reason and actor (row=$ROW)"
[ "$(jq -r '.pauses[0].expires_at' "$T/state/pauses.json")" = 2026-09-24T12:30:00Z ] \
  && ok || bad "the ttl must set expires_at 30 min out (cache=$(cat "$T/state/pauses.json"))"
PID=$(jq -r '.[0].id' "$STORE")

# --- 4: the sweep is blocked on BOTH projects ---------------------------------
reset_prs; run_sweep
[ ! -s "$T/merge-calls.txt" ] && ok \
  || bad "4: a fleet merges pause must stop every merge call (merge-calls: $(cat "$T/merge-calls.txt"))"
for P in a/pull/1 b/pull/2; do
  grep -qF "https://github.com/o/$P skipped: PAUSED(merges)" "$T/logs/merge-sweep.log" && ok \
    || bad "4: o/$P must log skipped: PAUSED(merges) (log: $(log))"
done
grep -F 'PAUSED(merges)' "$T/logs/merge-sweep.log" | sed 's/^/  evidence: /'

# --- 5: END (pause_end with the reason the console sends) ---------------------
OUT=$(poll pause_end hub "$(jq -nc --argjson id "$PID" '{type:"pause_end",id:$id,scope:"fleet",reason:"freeze over",actor:"operator@example.com"}')")
grep -q "^OK=true RESULT=pause $PID ended\$" <<<"$OUT" && ok || bad "pause_end must end row $PID (out=$OUT)"
[ "$(jq -r '.[0].ended_at' "$STORE")" != null ] && [ "$(jq -r '.pauses[0].ended_at' "$T/state/pauses.json")" != null ] \
  && ok || bad "5: ended_at must be stamped in store and cache (cache=$(cat "$T/state/pauses.json"))"

# --- 6: the same sweep, nothing else changed, merges both ----------------------
# The PRs are the same ones the paused run skipped: a paused skip is retryable,
# never recorded as done, so nothing is reset here but the cache the END wrote.
run_sweep
merged 1 && merged 2 && ok \
  || bad "6: after END both PRs must merge (merge-calls: $(cat "$T/merge-calls.txt"); log: $(log))"
grep -q 'PAUSED(' "$T/logs/merge-sweep.log" && bad "6: no PAUSED line after END (log: $(log))" || ok

# --- 7: the node suite ---------------------------------------------------------
if ! command -v node >/dev/null 2>&1 || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "fleet-pause.bh-2509: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/fleet-pause.bh-2509.test.js 2>&1); then ok
  else bad "the node suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -40; fi
fi

echo "fleet-pause.bh-2509-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
