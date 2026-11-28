#!/bin/bash
# tests/custody-lease.bh-9554-test.sh — BH-9554 (custody C0): the custody
# lease, driven through the REAL jobs client verb `custody` (bin/jobs-client.sh,
# bin/jobs-client.d/bh-9554-custody.sh, bin/lib/jobs/custody.sh) over real curl
# against the REAL jobs worker routes (worker/jobs/src/routes/custody.js) on
# node:sqlite with the composed schema (worker/jobs/schema.d/*-bh-9554-custody.sql),
# through tests/lib/custody.bh-9554.mjs. 0 vendor calls; every ticket key is
# unique to this run.
#
#   L1 a claim sets owner and lease: rc 0, owner pool, lease ~ now+1800 s,
#      deadline now+180 min (building), due_at the earlier of the two
#   L2 a second lane on a live lease: rc 9, error held, owner pool; row unchanged
#   L3 the lease ended 1 s ago: triage's claim takes it, attempt 0
#   L4 release: owner custodian, no lease, deadline set; a release by a lane
#      that is not the owner: rc 9
#   L5 custody row: a released row is owned:false, a live lease owned:true
#   L6 an in-app key (TK-1) and an issues key (BH-1) on two projects both
#      claim; gaps reports no_owner 0, no_deadline 0
#   L7 round trip: a claim with --pr and --evidence reads back field for field;
#      settle merged rc 0; a second settle rc 0 duplicate:true, one settle
#      action row; the settled row is not in custody due
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/custody-lease.bh-9554-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/custody-fixture.bh-9554.sh
. "$(dirname "$0")/lib/custody-fixture.bh-9554.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
custody_fixture_start

P=lease-p
K=$(uniq_key 1)
row() { hook GET "/__row?project=$1&ticket=$2"; }
secs() { # secs <iso> <iso>: $2 - $1 in seconds
  jq -rn --arg a "$1" --arg b "$2" '(($b|fromdate) - ($a|fromdate))' 2>/dev/null
}

# ============================================================================
echo "L1: a claim sets owner and lease"
jc custody claim "$P" "$K" pool building reoffer
R=$(row "$P" "$K")
[ "$RC" = 0 ] && [ "$(jq -r .ok "$T/out")" = true ] && ok "L1 rc 0, ok:true" || bad "L1 rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
[ "$(jq -r .owner_lane <<<"$R")" = pool ] && ok "L1 owner pool" || bad "L1 row $R"
UPD=$(jq -r .updated_at <<<"$R")
[ "$(secs "$UPD" "$(jq -r .lease_expires_at <<<"$R")")" = 1800 ] && ok "L1 lease = now + 1800 s" || bad "L1 lease $R"
[ "$(secs "$UPD" "$(jq -r .deadline_at <<<"$R")")" = 10800 ] && ok "L1 deadline = now + 180 min" || bad "L1 deadline $R"
[ "$(jq -r .due_at <<<"$R")" = "$(jq -r .lease_expires_at <<<"$R")" ] && ok "L1 due_at = the lease (the earlier)" || bad "L1 due_at $R"

# ============================================================================
echo "L2: a second lane on a live lease is refused"
jc custody claim "$P" "$K" triage triaged reoffer
[ "$RC" = 9 ] && [ "$(jq -r .error "$T/out")" = held ] && [ "$(jq -r .owner_lane "$T/out")" = pool ] \
  && ok "L2 rc 9, held, owner pool" || bad "L2 rc=$RC out=$(cat "$T/out")"
[ "$(row "$P" "$K")" = "$R" ] && ok "L2 the row is unchanged" || bad "L2 row changed: $(row "$P" "$K")"

# ============================================================================
echo "L3: an expired lease can be claimed"
hook POST /__age "$(jq -nc --arg p "$P" --arg k "$K" '{project:$p,ticket:$k,set:{lease_expires_at:-1,attempt:2}}')" > /dev/null
jc custody claim "$P" "$K" triage triaged reoffer
R=$(row "$P" "$K")
[ "$RC" = 0 ] && [ "$(jq -r .owner_lane <<<"$R")" = triage ] && ok "L3 rc 0, owner triage" || bad "L3 rc=$RC out=$(cat "$T/out") row $R"
[ "$(jq -r .attempt <<<"$R")" = 0 ] && ok "L3 attempt 0 (the state changed)" || bad "L3 attempt $R"

# ============================================================================
echo "L4: release clears the owner"
jc custody release "$P" "$K" pool retriage
[ "$RC" = 9 ] && [ "$(jq -r .error "$T/out")" = not_owner ] && ok "L4 a release by pool (not the owner): rc 9" || bad "L4 non-owner rc=$RC out=$(cat "$T/out")"
jc custody release "$P" "$K" triage retriage
R=$(row "$P" "$K")
[ "$RC" = 0 ] && ok "L4 the owner's release: rc 0" || bad "L4 rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
[ "$(jq -c '[.owner_lane, .lease_expires_at, .next_action, (.deadline_at != null)]' <<<"$R")" = '["custodian",null,"retriage",true]' ] \
  && ok "L4 owner custodian, no lease, next retriage, deadline set" || bad "L4 row $R"

# ============================================================================
echo "L5: owned is a live lane lease"
jc custody row "$P" "$K"
[ "$RC" = 0 ] && [ "$(jq -r .owned "$T/out")" = false ] && ok "L5 released row: owned false" || bad "L5 released rc=$RC out=$(cat "$T/out")"
K5=$(uniq_key 5)
jc custody claim "$P" "$K5" pool building reoffer
jc custody row "$P" "$K5"
[ "$RC" = 0 ] && [ "$(jq -r .owned "$T/out")" = true ] && ok "L5 live lease: owned true" || bad "L5 live rc=$RC out=$(cat "$T/out")"
hook POST /__age "$(jq -nc --arg p "$P" --arg k "$K5" '{project:$p,ticket:$k,set:{lease_expires_at:-5}}')" > /dev/null
jc custody row "$P" "$K5"
[ "$(jq -r .owned "$T/out")" = false ] && ok "L5 expired lease: owned false" || bad "L5 expired out=$(cat "$T/out")"

# ============================================================================
echo "L6: in-app and issues projects both claim"
jc custody claim project-3 "TK-$$-1" pool planned reoffer; R1=$RC
jc custody claim cromford "BH-$$-1" pool planned reoffer; R2=$RC
[ "$R1" = 0 ] && [ "$R2" = 0 ] && ok "L6 FR and BH keys both claim" || bad "L6 rc $R1 $R2 err=$(cat "$T/err")"
jc custody gaps
[ "$RC" = 0 ] && [ "$(jq -c '[.no_owner, .no_deadline]' "$T/out")" = '[0,0]' ] && ok "L6 gaps 0 0" || bad "L6 gaps rc=$RC out=$(cat "$T/out")"
jc custody gaps project-3
[ "$RC" = 0 ] && [ "$(jq -r .project "$T/out")" = project-3 ] && ok "L6 gaps per project" || bad "L6 gaps project rc=$RC out=$(cat "$T/out")"

# ============================================================================
echo "L7: round trip, settle, duplicate settle"
K7=$(uniq_key 7)
jc custody claim "$P" "$K7" pool pr_open resolver --pr 4242 --evidence "PR opened" --lease-s 600 --deadline-min 45
[ "$RC" = 0 ] || bad "L7 claim rc=$RC out=$(cat "$T/out") err=$(cat "$T/err")"
jc custody row "$P" "$K7"
R=$(jq -c .row "$T/out")
UPD=$(jq -r .updated_at <<<"$R")
[ "$(jq -c '[.project,.ticket,.state,.owner_lane,.next_action,.pr_number,.last_evidence,.attempt,.ladder_rung,.settled_at]' <<<"$R")" \
  = "[\"$P\",\"$K7\",\"pr_open\",\"pool\",\"resolver\",4242,\"PR opened\",0,0,null]" ] \
  && ok "L7 every field set reads back" || bad "L7 row $R"
[ "$(secs "$UPD" "$(jq -r .lease_expires_at <<<"$R")")" = 600 ] && [ "$(secs "$UPD" "$(jq -r .deadline_at <<<"$R")")" = 2700 ] \
  && ok "L7 --lease-s 600 and --deadline-min 45" || bad "L7 times $R"
jc custody settle "$P" "$K7" conductor merged
[ "$RC" = 0 ] && [ "$(jq -r '.duplicate // false' "$T/out")" = false ] && ok "L7 settle merged: rc 0" || bad "L7 settle rc=$RC out=$(cat "$T/out")"
jc custody settle "$P" "$K7" conductor merged
[ "$RC" = 0 ] && [ "$(jq -r .duplicate "$T/out")" = true ] && ok "L7 a second settle: rc 0 duplicate:true" || bad "L7 settle 2 rc=$RC out=$(cat "$T/out")"
N=$(hook GET "/__actions?project=$P&ticket=$K7" | jq '[.[] | select(.action == "settle")] | length')
[ "$N" = 1 ] && ok "L7 one settle action row" || bad "L7 settle rows $N"
hook POST /__age "$(jq -nc --arg p "$P" --arg k "$K7" '{project:$p,ticket:$k,set:{deadline_at:-60}}')" > /dev/null
jc custody due
[ "$RC" = 0 ] && [ "$(jq --arg k "$K7" '[.rows[] | select(.ticket == $k)] | length' "$T/out")" = 0 ] \
  && ok "L7 the settled row is not due" || bad "L7 due rc=$RC out=$(cat "$T/out")"
[ "$(jq --arg k "$K" '[.rows[] | select(.ticket == $k)] | length' "$T/out")" = 0 ] && ok "L7 a row inside its deadline is not due" || bad "L7 due has $K"

# ============================================================================
echo "U: the verb's argument checks"
jc custody claim "$P" "$K" pool building
[ "$RC" = 3 ] && grep -q '^usage: custody claim' "$T/err" && ok "U a missing argument: rc 3, usage" || bad "U rc=$RC err=$(cat "$T/err")"
jc custody claim "$P" "$K" pool building reoffer --pr x
[ "$RC" = 3 ] && ok "U --pr x: rc 3" || bad "U --pr x rc=$RC"
jc custody claim "$P" "$K" pool building reoffer --bogus 1
[ "$RC" = 3 ] && ok "U an unknown option: rc 3" || bad "U --bogus rc=$RC"
jc custody frob
[ "$RC" = 3 ] && ok "U an unknown sub-verb: rc 3" || bad "U frob rc=$RC"
jc no-such-verb-9554
grep -q 'custody <claim|renew|release|next|settle|act|due|row|gaps>' "$T/err" && ok "U the verb is in the client usage line" || bad "U usage: $(tail -c 300 "$T/err")"

echo "custody-lease: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
