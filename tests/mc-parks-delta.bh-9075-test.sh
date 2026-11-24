#!/bin/bash
# tests/mc-parks-delta.bh-9075-test.sh — BH-9075 (BH-9067.3): the merge
# conductor's parks delta (bin/lib/mc/parks-delta.sh, the two hook lines in
# tick_project, the bin/merge-conductor.d/bh-9075-parks.sh loader). Every case
# runs the REAL bin/merge-conductor.sh tick from a scratch $HARNESS. A walk is
# the tick's open-PR list read (a GitHub call); a skip makes none.
#
#   M1  no knob row (mode off): the walk runs and 0 parks calls
#   M2  on, no changed parks row, no wake: the walk is SKIPPED, with the
#       `TICK <p> held: ... (decision=parks-quiet)` line and no metrics write
#   M3-M11 each WALKS: one changed row; a parks read failure; a wake id above
#       the watermark; a wake read failure; no wake watermark; a keyed tick;
#       a pre-queue file newer than the walk; a stamp older than max-skip;
#       shadow mode (with the would-skip line)
#   M12 the tick end writes the walk stamp and syncs the conductor parks
#
# No network: gh and curl are stubs; the jobs worker answers from files here.
# Run from anywhere: tests/mc-parks-delta.bh-9075-test.sh   (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
[ -f "$DIR/bin/lib/mc/parks-delta.sh" ] || { echo "FAIL: bin/lib/mc/parks-delta.sh is missing"; exit 1; }   # impact: the delta lib under test (fx_mc_harness copies bin/lib/mc/)
mkdir -p "$T/h/bin/merge-conductor.d" || exit 1
cp "$DIR/bin/merge-conductor.d/bh-9075-parks.sh" "$T/h/bin/merge-conductor.d/" || exit 1
scratch_install_closure bin/lib/parks-write.sh "$T/h" >/dev/null || exit 1
[ -f "$T/h/bin/lib/mc/parks-delta.sh" ] && [ -f "$T/h/bin/lib/jobs/parks.sh" ] || { echo "the parks libs did not ride the fixture"; exit 1; }
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*) exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*) echo '[]' ;;
  *"pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# The jobs worker: the parks changed read answers $T/parks-answer (or the
# status in $T/parks-status), the wake take answers $T/wake-answer.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s %s\n' "\$M" "\${URL#*jobs.test}" "\$BODY" >> "$T/jobs-calls.txt"
case "\$M \$URL" in
  "GET "*/api/parks/changed*)
    st=\$(cat "$T/parks-status" 2>/dev/null || echo 200); printf '%s\n%s\n' "\$(cat "$T/parks-answer")" "\$st" ;;
  "POST "*/api/lane-wakes/take)
    st=\$(cat "$T/wake-status" 2>/dev/null || echo 200); printf '%s\n%s\n' "\$(cat "$T/wake-answer")" "\$st" ;;
  "PUT "*/api/parks) printf '{"upserted":1,"as_of":1}\n200\n' ;;
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

tick() { # tick [VAR=value ...]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test \
      MC_MAIN_RED_DETECT=0 env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>>"$T/tick.err" ) || true
}
PD="$T/h/state/merge-conductor/parks-delta"
QUIET='{"rows":[],"next":"0","truncated":false,"as_of":1}'
fresh() { # a project whose last walk was 60 s ago, a wake watermark 50, a quiet worker
  rm -rf "$T/h/state" "$T/h/logs" "$T/h/locks"
  mkdir -p "$T/h/state" "$T/h/logs" "$T/h/locks" "$PD"
  : > "$T/gh-calls.txt"; : > "$T/jobs-calls.txt"; rm -f "$T/parks-status" "$T/wake-status"
  printf '%s\n' "$((NOW - 60))" > "$PD/demo-os.walk"; printf '50\n' > "$PD/demo-os.wake"
  touch -d "@$((NOW - 60))" "$PD/demo-os.walk"   # the stamp was written by a walk 60 s ago
  printf '%s' "$QUIET" > "$T/parks-answer"
  printf '{"taken":[],"webhook_max_id":50,"as_of":1}' > "$T/wake-answer"
}
walked() { grep -q -- 'example-org/demo-os' "$T/gh-calls.txt"; }
jcalls() { grep -c -- "$1" "$T/jobs-calls.txt" 2>/dev/null || true; }
LOGM="$T/h/logs/merge-conductor.log"

# ── M1 ──────────────────────────────────────────────────────────────────────
fresh; tick
walked && ok || bad "M1 with no knob row the per-PR walk must run (gh: $(head -3 "$T/gh-calls.txt"))"
[ "$(jcalls '/api/parks/changed')" = 0 ] && [ "$(jcalls 'lane-wakes')" = 0 ] && ok || bad "M1 mode off makes 0 parks/wake calls ($(cat "$T/jobs-calls.txt"))"

# ── M2 ──────────────────────────────────────────────────────────────────────
fresh; tick MC_PARKS_DELTA_MODE=on
walked && bad "M2 THE CLAIM: on, no change and no wake must SKIP the walk (gh: $(head -3 "$T/gh-calls.txt"))" || ok
grep -q 'TICK demo-os held: no parks change and no pr/checks wake since .*(decision=parks-quiet)' "$LOGM" && ok || bad "M2 the skip line (log: $(tail -2 "$LOGM"))"
[ ! -e "$T/h/state/merge-conductor/tick-demo-os.json" ] && ok || bad "M2 a skip writes no tick metrics"
[ "$(jcalls '/api/parks/changed')" = 1 ] && [ "$(jcalls 'lane-wakes/take')" = 1 ] && ok || bad "M2 one parks read and one wake read"
grep -q '"lane":"mc-parks-delta".*"kinds":\["pr","checks"\].*"repo":"example-org/demo-os","after_id":50' "$T/jobs-calls.txt" && ok \
  || bad "M2 the take names the lane, kinds, repo and watermark ($(grep lane-wakes "$T/jobs-calls.txt"))"

# ── M3-M11 ──────────────────────────────────────────────────────────────────
fresh; printf '{"rows":[{"project":"demo-os","ck":"x","source":"queue","state":"parked","head":"-","reason":"-","url":"-","rec":"-","ticket":"-","updated_at":%s,"writer":"fly-pool","parked_at":null}],"next":"1:x","truncated":false,"as_of":1}' "$NOW" > "$T/parks-answer"
tick MC_PARKS_DELTA_MODE=on
walked && ok || bad "M3 one changed parks row must walk"
[ "$(jcalls 'lane-wakes')" = 0 ] && ok || bad "M3 the wake read is skipped when the parks read already says walk"

fresh; echo 500 > "$T/parks-status"; tick MC_PARKS_DELTA_MODE=on
walked && ok || bad "M4 a parks read failure must walk (fail-open)"

fresh; printf '{"taken":[],"webhook_max_id":77,"as_of":1}' > "$T/wake-answer"; tick MC_PARKS_DELTA_MODE=on
walked && ok || bad "M5 a wake id above the watermark must walk"
[ "$(cat "$PD/demo-os.wake")" = 77 ] && ok || bad "M5 the watermark moves to 77 after the parsed answer"

fresh; echo 500 > "$T/wake-status"; tick MC_PARKS_DELTA_MODE=on
walked && ok || bad "M6 a wake read failure must walk"
[ "$(cat "$PD/demo-os.wake")" = 50 ] && ok || bad "M6 a failed take never moves the watermark"

fresh; rm -f "$PD/demo-os.wake"; tick MC_PARKS_DELTA_MODE=on
walked && ok || bad "M7 no wake watermark must walk"
[ "$(cat "$PD/demo-os.wake" 2>/dev/null)" = 50 ] && ok || bad "M7 the first take writes the watermark"

fresh; tick MC_PARKS_DELTA_MODE=on MC_ONLY_PR=example-org/demo-os#5
[ "$(jcalls '/api/parks')" = 0 ] && ok || bad "M8 a keyed tick never asks the delta ($(cat "$T/jobs-calls.txt"))"
grep -q 'decision=parks-quiet' "$LOGM" && bad "M8 a keyed tick is never held by the delta" || ok

fresh; mkdir -p "$T/h/state/merge-conductor/prequeue"; touch "$T/h/state/merge-conductor/prequeue/example-org_demo-os_5_abc_x"
tick MC_PARKS_DELTA_MODE=on
walked && ok || bad "M9 a pre-queue file newer than the walk must walk"

fresh; printf '%s\n' "$((NOW - 4000))" > "$PD/demo-os.walk"; tick MC_PARKS_DELTA_MODE=on MC_PARKS_DELTA_MAX_SKIP_S=1800
walked && ok || bad "M10 a walk stamp older than MC_PARKS_DELTA_MAX_SKIP_S must walk"

fresh; tick MC_PARKS_DELTA_MODE=shadow
walked && ok || bad "M11 shadow must walk"
grep -q 'TICK demo-os would skip: .*(decision=parks-quiet-shadow)' "$LOGM" && ok || bad "M11 shadow logs the would-skip line"

fresh; rm -f "$PD/demo-os.walk"; tick MC_PARKS_DELTA_MODE=on
walked && ok || bad "M12 no walk stamp must walk"

# ── M12: the tick end ───────────────────────────────────────────────────────
fresh; rm -f "$PD/demo-os.walk"
printf 'example-org/demo-os#9\tBLOCKED_HUMAN\t1700000000\tabc\tabc\t-\tred-twice\thttps://github.com/example-org/demo-os/pull/9\n' > "$T/h/state/merge-conductor/pr-state.tsv"
tick
W=$(cat "$PD/demo-os.walk" 2>/dev/null)
[ -n "$W" ] && [ "$W" -ge "$((NOW - 5))" ] && ok || bad "M12 a full tick writes the walk stamp (got '$W')"
grep -q 'PUT /api/parks .*"ck":"example-org-demo-os-9".*"state":"parked"' "$T/jobs-calls.txt" && ok \
  || bad "M12 the tick end notes the BLOCKED_HUMAN row as a park ($(grep 'PUT /api/parks' "$T/jobs-calls.txt"))"
grep -q $'^example-org-demo-os-9\t' "$T/h/state/parks-conductor/demo-os.tsv" 2>/dev/null && ok || bad "M12 the fingerprint file holds the park"

echo "mc-parks-delta.bh-9075: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
