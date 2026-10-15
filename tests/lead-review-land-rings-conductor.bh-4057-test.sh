#!/bin/bash
# tests/lead-review-land-rings-conductor.bh-4057-test.sh — BH-4094 (BH-4057.2):
# bin/lead-review-land.sh rings the merge conductor (kw_conductor,
# bin/lib/keyed-wake.sh) the moment it records a lead row the conductor can act
# on, leaves state/lead-review-land/rerun-owed when the tick lock is held, and
# reruns itself once at the end (lcw_rerun, bin/lib/lead-chain-wake.sh) bounded
# by LEAD_REVIEW_LAND_RERUN_MAX. Red on main: no ring, no marker, no rerun.
#
# The land script runs WHOLE against a scratch harness: the real jobs client,
# lead-verdict.sh, keyed-wake.sh and lead-chain-wake.sh, with curl/gh stubbed
# (the bh-1951 stateful worker shape) and $H/bin/merge-conductor.sh a stub that
# appends its MC_ONLY_PR to $T/log/conductor.
#   D4  a done MERGE -> one keyed conductor launch, `conductor rung`, rung=1
#   D4e the same PR again inside MC_KEYED_WAKE_MIN_S -> no second launch, rung=0
#   D4b a done BLOCK -> no launch, rung=0
#   D4c post rc 5 (status withheld) -> stamped, no launch
#   D4g the stamp-only pass over a withheld row -> stamped, no launch
#   D4d post rc 3 (the PR head moved) -> stamped, no launch
#   D4f MC_KEYED_WAKE=0 -> no launch, rung=0
#   C2  the tick lock is held -> rc 0, nothing called, rerun-owed written
#   R1  rerun-owed + knob 3 -> one detached rerun, marker removed
#   R2  rerun-owed + knob unset -> no rerun, marker kept
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land-rings-conductor.bh-4057-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$H/catalog" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
for s in bin/lead-review-land.sh bin/jobs-client.sh bin/lead-verdict.sh bin/lib/gh-app-auth.sh bin/lib/verdict-status.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
chmod +x "$H/bin/lead-review-land.sh"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf '#!/bin/bash\nprintf "%%s\\n" "${MC_ONLY_PR:-}" >> "%s"\n' "$T/log/conductor" > "$H/bin/merge-conductor.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/merge-conductor.sh" "$H/bin/lane-alert.sh"

SHA=$(printf 'a%.0s' {1..40})
SHA2=$(printf 'b%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/vrows.json" ] || echo '[]' > "$T/vrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-10-03T00:00:00Z"}}'; fi ;;
  "POST /api/verdicts")
    n=\$(jq length "$T/vrows.json")
    row=\$(jq -c --argjson id "\$((n + 1))" '. + {id:\$id, created_at:"2026-10-03T00:00:00Z"}' <<<"\$body")
    jq -c --argjson r "\$row" '. + [\$r]' "$T/vrows.json" > "$T/vrows.tmp" && mv "$T/vrows.tmp" "$T/vrows.json"
    code=201; out=\$(jq -c '{verdict:.}' <<<"\$row") ;;
  "GET /api/verdicts?"*)
    out=\$(jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
      [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
      | {repo:\$r, pr:\$pr, head:(if \$h == "" then null else \$h end),
         standing:([\$rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | first),
         rows:\$rows, truncated:false}' "$T/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
# GitHub: PR 41 is at $SHA, or at $SHA2 once $T/moved exists (post exits 3).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/41/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"-X POST repos/"*"/pulls/41/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"id":1}\n' ;;
  *"-X GET repos/"*"/pulls/41"*)
    if [ -e "$T/moved" ]; then printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA2"}}\n'
    else printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n'; fi ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token"
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME MC_H MC_KEYED_WAKE MC_KEYED_WAKE_MIN_S \
  LEAD_REVIEW_LAND_RERUN_MAX LEAD_CHAIN_RERUN_DEPTH LEAD_REVIEW_SPOTCHECK_PCT

# wait_for <secs> <cmd...> — rc 0 once <cmd> succeeds, 1 after <secs>.
wait_for() {
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
req() {
  jq -nc --arg i "$1" --arg v "$2" --arg h "$SHA" \
    '{id:$i, repo:"example-org/demo-os", pr:41, head_sha:$h, status:"done", verdict:$v,
      reviewer_model:"stub-model", report_ref:"state/lead-reviews/lr-41-aaaaaaaaaaaa.md",
      promoted_verdict_at:null, detail:null, created_at:"2026-10-03T00:00:00Z", updated_at:"2026-10-03T00:00:00Z"}'
}
# setreqs [request-json...] — no argument = an empty list.
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
# reset [keep-kw] — keep-kw leaves state/merge-conductor (the keyed-wake stamp).
reset() {
  rm -f "${T:?}"/log/* "${T:?}/vrows.json" "${T:?}/moved" "$H/logs/lead-review-land.log"
  scratch_rm "$H/state/lead-review-land"
  [ "${1:-}" = keep-kw ] || scratch_rm "$H/state/merge-conductor"
  scratch_rm "$H/state/lead-authority"
  echo box-hub > "$H/state/box-name"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
LOGF() { cat "$H/logs/lead-review-land.log" 2>/dev/null; }
summary() { grep -E ' seen=[0-9]+ ' "$H/logs/lead-review-land.log" 2>/dev/null | tail -1; }
launches() { [ -f "$T/log/conductor" ] && grep -c . "$T/log/conductor" || echo 0; }
stamps() { grep -c '^POST /api/lead-reviews/lr-1/promoted ' "$T/log/worker" 2>/dev/null || echo 0; }
lists() { grep -c '^GET /api/lead-reviews?' "$T/log/worker" 2>/dev/null || echo 0; }
has_launch() { [ "$(launches)" -ge 1 ]; }

# ── D4: a done MERGE -> the conductor is rung for exactly that PR ──
reset; setreqs "$(req lr-1 MERGE)"; tick
[ "$RC" -eq 0 ] && ok || bad "D4 rc=$RC out=$(cat "$T/out")"
wait_for 5 has_launch && ok || bad "D4 no conductor launch: $(LOGF)"
sleep 0.5
[ "$(launches)" = 1 ] && ok || bad "D4 want exactly one launch, got $(launches)"
[ "$(head -1 "$T/log/conductor" 2>/dev/null)" = "example-org/demo-os#41" ] && ok || bad "D4 the launch is not keyed to example-org/demo-os#41: $(cat "$T/log/conductor" 2>/dev/null)"
LOGF | grep -q 'lead review lr-1: conductor rung' && ok || bad "D4 no 'conductor rung' line: $(LOGF)"
summary | grep -qE 'rung=1$' && ok || bad "D4 the summary does not end rung=1: $(summary)"
[ "$(stamps)" = 1 ] && ok || bad "D4 want one stamp, got $(stamps)"
[ -f "$H/state/merge-conductor/keyed-wake/example-org_demo-os#41" ] && ok || bad "D4 no keyed-wake stamp for the PR"

# ── D4e: again within MC_KEYED_WAKE_MIN_S -> kw_conductor dedupes, rung=0 ──
reset keep-kw; setreqs "$(req lr-1 MERGE)"; tick
[ "$RC" -eq 0 ] && ok || bad "D4e rc=$RC"
sleep 1
[ "$(launches)" = 0 ] && ok || bad "D4e a second launch inside the dedupe window: $(cat "$T/log/conductor" 2>/dev/null)"
summary | grep -qE 'rung=0$' && ok || bad "D4e the summary does not end rung=0: $(summary)"
grep -q 'conductor rung' <<<"$(LOGF)" && bad "D4e logged 'conductor rung' for a deduped ring" || ok
[ "$(stamps)" = 1 ] && ok || bad "D4e the request was not stamped: $(stamps)"

# ── D4b: a done BLOCK -> no ring (the resolver owns it) ──
reset; setreqs "$(req lr-1 BLOCK)"; tick
[ "$RC" -eq 0 ] && ok || bad "D4b rc=$RC"
sleep 1.5
[ "$(launches)" = 0 ] && ok || bad "D4b a BLOCK rang the conductor"
summary | grep -qE 'rung=0$' && ok || bad "D4b the summary does not end rung=0: $(summary)"
[ "$(stamps)" = 1 ] && ok || bad "D4b the BLOCK was not stamped (so the ring point was never reached): $(LOGF)"

# ── D4c: post rc 5 (recorded as advice, status withheld) -> stamped, no ring ──
reset; setreqs "$(req lr-1 MERGE)"
mv "$H/bin/lead-verdict.sh" "$H/bin/lead-verdict.sh.real"
printf '#!/bin/bash\necho "lead-verdict: status withheld on %s a protected path; a human verdict publishes it"\nexit 5\n' "${SHA:0:12}" > "$H/bin/lead-verdict.sh"
chmod +x "$H/bin/lead-verdict.sh"
tick
mv "$H/bin/lead-verdict.sh.real" "$H/bin/lead-verdict.sh"
[ "$RC" -eq 0 ] && ok || bad "D4c rc=$RC"
LOGF | grep -q 'recorded as advice; lead-verdict status withheld' && ok || bad "D4c the withheld path did not run: $(LOGF)"
sleep 1.5
[ "$(launches)" = 0 ] && ok || bad "D4c a withheld row rang the conductor"
grep -q 'conductor rung' <<<"$(LOGF)" && bad "D4c logged 'conductor rung'" || ok
[ "$(stamps)" = 1 ] && ok || bad "D4c not stamped (so the ring point was never reached): $(LOGF)"

# ── D4g: stamp-only pass over a withheld row (authority:human-required) -> stamped, no ring ──
reset; setreqs "$(req lr-1 MERGE)"
jq -nc --arg h "$SHA" '[{id:1, repo:"example-org/demo-os", pr:41, head_sha:$h, verdict:"MERGE", source:"lead",
  note:"lead-review:lr-1 authority:human-required", created_at:"2026-10-03T00:00:00Z"}]' > "$T/vrows.json"
tick
[ "$RC" -eq 0 ] && ok || bad "D4g rc=$RC"
LOGF | grep -q 'its lead row is already recorded; stamping only' && ok || bad "D4g the stamp-only path did not run: $(LOGF)"
sleep 1.5
[ "$(launches)" = 0 ] && ok || bad "D4g a withheld row on the stamp-only path rang the conductor"
[ "$(stamps)" = 1 ] && ok || bad "D4g not stamped (so the ring point was never reached): $(LOGF)"

# ── D4d: post rc 3 (the PR head moved off the reviewed sha) -> stamped, no ring ──
reset; setreqs "$(req lr-1 MERGE)"; : > "$T/moved"; tick
[ "$RC" -eq 0 ] && ok || bad "D4d rc=$RC"
LOGF | grep -q 'but the PR head moved; not posted' && ok || bad "D4d post did not exit 3: $(LOGF)"
sleep 1.5
[ "$(launches)" = 0 ] && ok || bad "D4d a dead head rang the conductor"
summary | grep -qE 'rung=0$' && ok || bad "D4d the summary does not end rung=0: $(summary)"
[ "$(stamps)" = 1 ] && ok || bad "D4d not stamped: $(stamps)"

# ── D4f: MC_KEYED_WAKE=0 -> no ring ──
reset; setreqs "$(req lr-1 MERGE)"
( export MC_KEYED_WAKE=0; tick; echo "$RC" > "$T/rc" )
sleep 1.5
[ "$(cat "$T/rc")" = 0 ] && ok || bad "D4f rc=$(cat "$T/rc")"
[ "$(launches)" = 0 ] && ok || bad "D4f MC_KEYED_WAKE=0 still rang the conductor"
summary | grep -qE 'rung=0$' && ok || bad "D4f the summary does not end rung=0: $(summary)"
[ "$(stamps)" = 1 ] && ok || bad "D4f not stamped: $(stamps)"

# ── C2: the tick lock is held -> skip, leave rerun-owed for the holder ──
reset; setreqs "$(req lr-1 MERGE)"
mkdir -p "$H/state/lead-review-land"
( exec 9>"$H/state/lead-review-land/tick.lock"; flock 9; exec sleep 30 ) & LP=$!
held() { ! flock -n "$H/state/lead-review-land/tick.lock" true; }
wait_for 5 held || bad "C2 the background holder never took the lock"
tick
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
[ "$RC" -eq 0 ] && ok || bad "C2 rc=$RC"
[ ! -s "$T/log/worker" ] && ok || bad "C2 a skipped tick called the worker: $(cat "$T/log/worker")"
[ -e "$H/state/lead-review-land/rerun-owed" ] && ok || bad "C2 no rerun-owed marker after a lock refusal"
LOGF | grep -q 'skipped (rerun owed)' && ok || bad "C2 log: $(LOGF)"

# ── R1: rerun-owed + LEAD_REVIEW_LAND_RERUN_MAX=3 -> one detached rerun ──
reset; setreqs
mkdir -p "$H/state/lead-review-land"; : > "$H/state/lead-review-land/rerun-owed"
( export LEAD_REVIEW_LAND_RERUN_MAX=3; tick; echo "$RC" > "$T/rc" )
[ "$(cat "$T/rc")" = 0 ] && ok || bad "R1 rc=$(cat "$T/rc")"
LOGF | grep -q 'rerun owed (depth 1/3)' && ok || bad "R1 no 'rerun owed (depth 1/3)': $(LOGF)"
two_lists() { [ "$(lists)" -ge 2 ]; }
two_sums() { [ "$(grep -cE ' seen=[0-9]+ ' "$H/logs/lead-review-land.log" 2>/dev/null)" -ge 2 ]; }
wait_for 10 two_lists && ok || bad "R1 the rerun child never asked the worker (lists=$(lists))"
wait_for 10 two_sums && ok || bad "R1 the rerun child never finished: $(LOGF)"
[ ! -e "$H/state/lead-review-land/rerun-owed" ] && ok || bad "R1 the marker was not consumed"
sleep 0.5
[ "$(lists)" = 2 ] && ok || bad "R1 want exactly one rerun (2 list calls), got $(lists)"

# ── R2: rerun-owed + knob unset -> no rerun, marker kept ──
reset; setreqs
mkdir -p "$H/state/lead-review-land"; : > "$H/state/lead-review-land/rerun-owed"
tick
[ "$RC" -eq 0 ] && ok || bad "R2 rc=$RC"
LOGF | grep -q "rerun owed but off (max='')" && ok || bad "R2 no 'rerun owed but off': $(LOGF)"
wait_for 2 two_lists && bad "R2 a rerun ran with the knob off (lists=$(lists))" || ok
[ "$(lists)" = 1 ] && ok || bad "R2 want one list call (no rerun), got $(lists)"
[ -e "$H/state/lead-review-land/rerun-owed" ] && ok || bad "R2 the marker was removed with the knob off"

echo "lead-review-land-rings-conductor: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
