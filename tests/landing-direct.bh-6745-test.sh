#!/bin/bash
# tests/landing-direct.bh-6745-test.sh — BH-6745 (wave 2 of #6541): the direct
# merge in optimistic landing mode (bin/lib/mc/landing.sh landing_direct and
# the READY-arm hook in bin/merge-conductor.sh).
#
# WHAT IS DRIVEN.
#   U cases source the REAL bin/lib/mc/landing.sh. Only its transports are
#   stubbed: landing_eligible (an answer file), mc_merge, mc_merge_locked,
#   mc_tick_budget_take/give, the attempts ledger, _jobs_req, mc_log, mc_step.
#   U1 landing_direct_on: a typo mode, shadow and queue are off; optimistic on
#   U2 landing_direct_on: provider github and none are off
#   U3 a merge-queue label -> rc 1 queue, no merge, no budget
#   U4 MC_ON_MACHINE=1 -> landing_direct_on is off, landing_direct rc 1, no merge
#   U5 budget knob 0 -> rc 1 queue; a 405 -> rc 4 `405`, landingfail, outcome 405
#   U6 landing_direct_path round-trip over the attempts ledger
#   U7 mc_merge_locked answers 99 -> rc 3 lock, the direct unit goes back
#   U8 the eligibility refusal -> rc 1 queue and one decision row
#   D cases run the REAL bin/merge-conductor.sh over tests/lib/nhv-conductor-fixture.sh
#   with the REST merge lib, a fake merge PUT and a green landing contract:
#   D1 optimistic + eligible -> one merge PUT bound to the head, 0 label POSTs,
#      row MERGED, outcome PUT merged
#   D2 optimistic + tier-high -> one label POST, byte-equal to a queue-mode run,
#      0 merge PUTs, row QUEUED
#   D3 MC_DIRECT_MERGE_BUDGET=1, two eligible PRs -> one MERGED, the other READY
#      with reason budget, outcome budget, 0 label POSTs
#   D4 the merge PUT answers 409 -> row READY, landingfail 409, outcome 409, no
#      mergefail; the next tick -> 1 label POST, 0 merge PUTs
#   D5 mode shadow -> 0 merge PUTs, 1 label POST
#   P1 after D1 the ledger merge PUT has detail `merge-conductor path=direct`;
#      a queue landing (Mergify rc 2) has detail `merge-conductor`
#   K1 the knob fragment, code default = registry default, the key fits 64 chars
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/landing-direct.bh-6745-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

REPO=example-org/landing-os
PROJ=landing
PR=6745
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa6745
URL="https://github.com/$REPO/pull/$PR"
KEY="$REPO#$PR"
MSHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee6745
mkdir -p "$T/u" || exit 1

# ── the unit shell: the real landing.sh, stubbed transports ─────────────────
unset MC_LANDING_MODE MC_DIRECT_MERGE_BUDGET MC_ON_MACHINE
LANDING_LIB="$DIR/bin/lib/mc/landing.sh"
# shellcheck source=bin/lib/mc/landing.sh
. "$LANDING_LIB" || exit 1
unset -f lane_knob 2>/dev/null
U="$T/u"
landing_eligible() {
  echo x >> "$U/elig-calls.txt"
  LANDING_REASON=$(cat "$U/elig" 2>/dev/null || echo ok)
  printf '%s\n' "$LANDING_REASON"; [ "$LANDING_REASON" = ok ]
}
mc_merge() {
  printf '%s %s\n' "$1" "$2" >> "$U/merges.txt"
  case "$(cat "$U/merge-mode" 2>/dev/null || echo 200)" in
    200) printf '%s' "$MSHA"; return 0 ;;
    405) printf 'HTTP refusal (rc 3): Pull Request is not mergeable'; return 1 ;;
    409) printf 'HTTP refusal (rc 4): Head branch was modified'; return 1 ;;
    422) printf 'HTTP refusal (rc 5): Validation failed'; return 1 ;;
    *)   printf 'gh: something broke'; return 1 ;;
  esac
}
mc_merge_locked() {
  local p="$1"; shift
  printf '%s %s\n' "$p" "$1" >> "$U/locked.txt"
  [ -e "$U/lock99" ] && return 99
  "$@"
}
mc_tick_budget_take() { # <p> <kind> <limit>
  local n; n=$(cat "$U/budget-$2" 2>/dev/null || echo 0)
  [ "$n" -lt "$3" ] || return 1
  echo $((n + 1)) > "$U/budget-$2"
}
mc_tick_budget_give() { local n; n=$(cat "$U/budget-$2" 2>/dev/null || echo 0); [ "$n" -gt 0 ] && echo $((n - 1)) > "$U/budget-$2"; return 0; }
MC_ATTEMPTS="$U/attempts.txt"
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
mc_attempt_put_n() { echo "$*" >> "$MC_ATTEMPTS"; }
mc_attempt_count() { awk -v k="$1" -v key="$2" -v h="${3:-}" '$1==k && $2==key && (h=="" || $3==h) {c++} END {print c+0}' "$MC_ATTEMPTS" 2>/dev/null || echo 0; }
mc_log() { echo "$*" >> "$U/mc.log"; }
mc_step() { echo "$1" >> "$U/steps.txt"; }
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$U/jobs.log"
  JOBS_HTTP=200; echo '{"ok":true}'; return 0
}
ureset() {
  scratch_rm "$U"; mkdir -p "$U"; : > "$MC_ATTEMPTS"; : > "$U/mc.log"; : > "$U/jobs.log"
  unset MC_LANDING_MODE MC_DIRECT_MERGE_BUDGET MC_ON_MACHINE
}
# ld [labels] — landing_direct in a subshell, as the conductor calls it.
ld() { LDOUT=$(MC_LANDING_MODE=optimistic landing_direct "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" "${1:-}" "$URL"); LDRC=$?; }
nmerges() { local c; c=$(grep -c . "$U/merges.txt" 2>/dev/null); echo "${c:-0}"; }
outcome_puts() { grep '^PUT /api/landing-decisions/outcome ' "$U/jobs.log" 2>/dev/null | sed 's/^PUT \/api\/landing-decisions\/outcome //'; }

if ! command -v landing_direct >/dev/null 2>&1 || ! command -v landing_direct_on >/dev/null 2>&1; then
  bad "bin/lib/mc/landing.sh defines no landing_direct / landing_direct_on — every U case below is red"
fi

# ── U1 / U2 / U4: the arm guard ─────────────────────────────────────────────
ureset
on() { MC_LANDING_MODE="$1" landing_direct_on "$PROJ" "$2"; }
on optimistic mergify && ok || bad "U1: optimistic + mergify is on"
on ' Optimistic ' mergify && ok || bad "U1: ' Optimistic ' is optimistic"
! on optimstic mergify && ! on shadow mergify && ! on queue mergify && ! on '' mergify && ok || bad "U1: a typo, shadow, queue and empty are off"
! on optimistic github && ! on optimistic none && ! on optimistic '' && ok || bad "U2: provider github / none / empty is off"
MC_ON_MACHINE=1 on optimistic mergify && bad "U4: a lane-run machine is off" || ok
MC_ON_MACHINE=1 ld; [ "$LDRC" = 1 ] && [ "$(nmerges)" = 0 ] && [ ! -s "$U/elig-calls.txt" ] && ok \
  || bad "U4: landing_direct on a lane-run machine is rc 1 and reads nothing (rc $LDRC, merges $(nmerges))"

# ── U3: a PR already in the queue is the queue's ────────────────────────────
ureset
ld "hotfix,merge-queue"
[ "$LDRC" = 1 ] && [ "$(head -1 <<<"$LDOUT")" = queue ] && [ "$(nmerges)" = 0 ] && [ ! -e "$U/budget-direct" ] && ok \
  || bad "U3: merge-queue label -> rc 1 queue, no merge, no budget (rc $LDRC, out '$LDOUT', merges $(nmerges))"
MC_MERGIFY_LABEL=mq-custom ld "merge-queue"
[ "$LDRC" = 0 ] && ok || bad "U3: only the configured label counts (MC_MERGIFY_LABEL=mq-custom, rc $LDRC)"

# ── U5: budget 0 is off; a 405 ──────────────────────────────────────────────
ureset
MC_DIRECT_MERGE_BUDGET=0 ld
[ "$LDRC" = 1 ] && [ "$(head -1 <<<"$LDOUT")" = queue ] && [ "$(nmerges)" = 0 ] && ok || bad "U5: budget 0 -> rc 1 queue, no merge (rc $LDRC, '$LDOUT')"
[ "$(landing_direct_budget "$PROJ")" = 6 ] && [ "$(MC_DIRECT_MERGE_BUDGET=x landing_direct_budget "$PROJ")" = 6 ] \
  && [ "$(MC_DIRECT_MERGE_BUDGET=2 landing_direct_budget "$PROJ")" = 2 ] && [ "$(MC_DIRECT_MERGE_BUDGET=0 landing_direct_budget "$PROJ")" = 0 ] \
  && ok || bad "U5: landing_direct_budget unset/x/2/0 -> 6/6/2/0"
ureset; echo 405 > "$U/merge-mode"
ld
[ "$LDRC" = 4 ] && [ "$(head -1 <<<"$LDOUT")" = 405 ] && ok || bad "U5: a 405 -> rc 4 405 (rc $LDRC, '$LDOUT')"
grep -qxF "landingfail $KEY $HEAD 405" "$MC_ATTEMPTS" && ok || bad "U5: landingfail written ($(cat "$MC_ATTEMPTS"))"
jq -e --arg h "$HEAD" '.repo=="example-org/landing-os" and .number==6745 and .head==$h and .mode=="optimistic" and .outcome=="405"' <<<"$(outcome_puts)" >/dev/null 2>&1 \
  && ok || bad "U5: outcome PUT 405 ($(outcome_puts))"
grep -qxF "$KEY LANDING_DIRECT outcome=405 head=${HEAD:0:12}" "$U/mc.log" && ok || bad "U5: the LANDING_DIRECT line ($(cat "$U/mc.log"))"
[ "$(cat "$U/budget-direct")" = 1 ] && ok || bad "U5: a refused merge spent its direct unit (a GitHub write was made)"
: > "$U/merges.txt"; : > "$U/elig-calls.txt"; ld
[ "$LDRC" = 1 ] && [ "$(nmerges)" = 0 ] && [ ! -s "$U/elig-calls.txt" ] && grep -qxF "$KEY LANDING_DIRECT fallback=queue head=${HEAD:0:12}" "$U/mc.log" && ok \
  || bad "U5: the next call on that head falls back to the queue with no read (rc $LDRC, merges $(nmerges); $(tail -2 "$U/mc.log"))"
for m in 409:409 422:422 gh:error; do
  ureset; echo "${m%%:*}" > "$U/merge-mode"; ld
  [ "$LDRC" = 4 ] && [ "$(head -1 <<<"$LDOUT")" = "${m#*:}" ] && grep -qxF "landingfail $KEY $HEAD ${m#*:}" "$MC_ATTEMPTS" && ok \
    || bad "U5: merge mode ${m%%:*} -> ${m#*:} (rc $LDRC, '$LDOUT', $(cat "$MC_ATTEMPTS"))"
done

# ── U6: landing_direct_path ─────────────────────────────────────────────────
ureset
landing_direct_path "$KEY" "$HEAD" && bad "U6: no mark -> not direct" || ok
ld
[ "$LDRC" = 0 ] && [ "$(sed -n 1p <<<"$LDOUT")" = merged ] && [ "$(sed -n 2p <<<"$LDOUT")" = "$MSHA" ] && ok || bad "U6: merged + sha on line 2 (rc $LDRC, '$LDOUT')"
grep -qxF "landingdirect $KEY $HEAD" "$MC_ATTEMPTS" && ok || bad "U6: the intent mark ($(cat "$MC_ATTEMPTS"))"
landing_direct_path "$KEY" "$HEAD" && ok || bad "U6: a direct landing reads as direct"
landing_direct_path "$KEY" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb6745" && bad "U6: another head is not direct" || ok
mc_attempt_put_n landingfail "$KEY" "$HEAD" 409
landing_direct_path "$KEY" "$HEAD" && bad "U6: a landingfail on the head is not direct" || ok
jq -e '.outcome=="merged"' <<<"$(outcome_puts)" >/dev/null 2>&1 && ok || bad "U6: outcome merged ($(outcome_puts))"
[ "$(grep -c '^POST /api/landing-decisions ' "$U/jobs.log")" = 1 ] && jq -e '.would=="direct" and .reason=="ok" and .mode=="optimistic"' \
  <<<"$(sed -n 's/^POST \/api\/landing-decisions //p' "$U/jobs.log")" >/dev/null 2>&1 && ok || bad "U6: one decision row would=direct ($(cat "$U/jobs.log"))"
grep -qxF "landing $KEY $HEAD optimistic" "$MC_ATTEMPTS" && ok || bad "U6: the decision mark is wave 1's ($(cat "$MC_ATTEMPTS"))"

# ── U7: the merge lock ──────────────────────────────────────────────────────
ureset; touch "$U/lock99"
ld
[ "$LDRC" = 3 ] && [ "$(head -1 <<<"$LDOUT")" = lock ] && [ "$(nmerges)" = 0 ] && ok || bad "U7: lock 99 -> rc 3 lock, no merge (rc $LDRC, '$LDOUT')"
[ "$(cat "$U/budget-direct")" = 0 ] && ok || bad "U7: the direct unit went back ($(cat "$U/budget-direct"))"
grep -q "^$PROJ " "$U/locked.txt" && ok || bad "U7: the merge ran under mc_merge_locked for the project ($(cat "$U/locked.txt"))"
jq -e '.outcome=="lock"' <<<"$(outcome_puts)" >/dev/null 2>&1 && ok || bad "U7: outcome lock ($(outcome_puts))"
landing_direct_path "$KEY" "$HEAD" && bad "U7: a lock refusal leaves no direct mark" || ok

# ── U8: ineligible, and the budget refusal ──────────────────────────────────
ureset; echo tier-high > "$U/elig"
ld
[ "$LDRC" = 1 ] && [ "$(nmerges)" = 0 ] && [ ! -e "$U/budget-direct" ] && ok || bad "U8: ineligible -> rc 1, no merge, no budget (rc $LDRC)"
grep -qxF "$KEY LANDING would=queue reason=tier-high mode=optimistic head=${HEAD:0:12}" "$U/mc.log" && ok || bad "U8: the decision line ($(cat "$U/mc.log"))"
[ -z "$(outcome_puts)" ] && ok || bad "U8: no outcome for a queued PR ($(outcome_puts))"
MC_LANDING_MODE=optimistic landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" ""
[ "$(grep -c '^POST /api/landing-decisions ' "$U/jobs.log")" = 1 ] && ok || bad "U8: landing_shadow after the fall-through adds no second row"
ureset; echo 0 > "$U/budget-direct"
MC_DIRECT_MERGE_BUDGET=1 ld; A1=$LDRC
LDOUT=$(MC_DIRECT_MERGE_BUDGET=1 MC_LANDING_MODE=optimistic landing_direct "$PROJ" "$REPO" 6746 "$HEAD" "$REPO#6746" "" "https://github.com/$REPO/pull/6746"); A2=$?
[ "$A1" = 0 ] && [ "$A2" = 2 ] && [ "$(head -1 <<<"$LDOUT")" = budget ] && [ "$(nmerges)" = 1 ] && ok \
  || bad "U8: budget 1 -> the first merges, the second rc 2 budget (rc $A1/$A2, '$LDOUT', merges $(nmerges))"
jq -se 'map(.outcome) == ["merged","budget"]' <<<"$(outcome_puts)" >/dev/null 2>&1 && ok || bad "U8: outcomes merged, budget ($(outcome_puts))"

# ── K1 ──────────────────────────────────────────────────────────────────────
KD="$DIR/catalog/lanes.d/merge-conductor.knobs.d"
jq -e '.env=="MC_DIRECT_MERGE_BUDGET" and .type=="int" and .default==6 and .min==0 and .max==50 and .zero_means=="off" and .read_in=="bin/lib/mc/landing.sh"' \
  "$KD/MC_DIRECT_MERGE_BUDGET.json" >/dev/null 2>&1 && ok || bad "K1: MC_DIRECT_MERGE_BUDGET.json (int, default 6, min 0, max 50, zero_means off, read_in landing.sh)"
[ "$(landing_direct_budget "$PROJ")" = "$(jq -r .default "$KD/MC_DIRECT_MERGE_BUDGET.json" 2>/dev/null)" ] && ok || bad "K1: the code fallback equals the registry default"
K=$( . "$DIR/bin/lib/lane-gate.sh" >/dev/null 2>&1; _lg_setting_key merge-conductor MC_DIRECT_MERGE_BUDGET project-8 ); KRC=$?
[ "$KRC" = 0 ] && [ "$K" = lane.merge-conductor.project-8.mc_direct_merge_budget ] && [ "${#K}" -le 64 ] && ok || bad "K1: the longest per-project key fits (rc $KRC, '$K')"

# ── D: the real conductor tick ──────────────────────────────────────────────
unset MC_ATTEMPTS
unset -f landing_eligible mc_merge mc_merge_locked mc_tick_budget_take mc_tick_budget_give mc_attempt_has mc_attempt_put \
  mc_attempt_put_n mc_attempt_count mc_log mc_step _jobs_req
if ! command -v flock >/dev/null; then
  echo "flock missing — D cases skipped"
  echo "landing-direct.bh-6745: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]; exit
fi
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/nhv-conductor-fixture.sh
. "$DIR/tests/lib/nhv-conductor-fixture.sh" || exit 1
nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
# The REST merge ladder mc_merge uses on the hub.
( cd "$DIR" && scratch_install_closure bin/lib/gh-pr-merge.sh "$T/h" ) >/dev/null || { echo "setup: could not install gh-pr-merge.sh"; exit 1; }
# The landing contract's inputs this fixture does not carry, answered green:
# no main-red flag, one fast check (lint), no lead-protected globs.
cat >> "$T/h/bin/lib/verdict-status.sh" <<'EOF'
main_red_flag() { return 1; }
ae_mergify_admit_checks() { printf 'lint\n'; }
la_globs() { :; }
_la_files() { :; }
_la_match() { return 1; }
EOF
# The fake gh: the merge PUT answers per $T/merge-mode and is recorded; the
# check-runs read also carries a green `lint`; the rest is the fixture's.
mv "$T/fakebin/gh" "$T/fakebin/gh.nhv"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api -i -X PUT repos/"*"/pulls/"*"/merge"*)
    printf '%s\n' "\$*" >> "$T/merge-puts.txt"
    case "\$(cat "$T/merge-mode" 2>/dev/null || echo 200)" in
      200) restpr --raw 200 '{"merged":true,"sha":"$MSHA","message":"Pull Request successfully merged"}' ;;
      409) restpr --raw 409 '{"message":"Head branch was modified. Review and try the merge again."}' ;;
      405) restpr --raw 405 '{"message":"Pull Request is not mergeable"}' ;;
    esac
    exit 0 ;;
  *"api -i -X GET repos/example-org/mgfy-os/pulls/"[0-9]*)
    N=\$(printf '%s\n' "\$*" | grep -oE 'pulls/[0-9]+' | head -1 | grep -oE '[0-9]+')
    case "\$*" in *pulls/\$N/*) ;; *)
      if [ -e "$T/merged-\$N" ]; then restpr MERGED "\$(cat "$T/head-\$N")" "ticket/mg-\$N" main "" MERGEABLE CLEAN operator "$MSHA"; exit 0; fi ;;
    esac ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    if [ "\$(cat "$T/checkmode" 2>/dev/null)" = running ]; then
      restpr --raw 200 '{"total_count":2,"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""},"started_at":"2026-10-16T00:00:00Z"},{"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-16T00:00:00Z"}]}'
    else
      restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-16T00:00:00Z"}]}'
    fi
    exit 0 ;;
esac
exec "$T/fakebin/gh.nhv" "\$@"
EOF
chmod +x "$T/fakebin/gh"
# The jobs transport: record the landing POST/PUT and ledger PUT bodies, answer
# the risk-tier read from $T/tier-<n>, hand the rest to the fixture's curl.
mv "$T/fakebin/curl" "$T/fakebin/curl.nhv"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; B=""
for ((i=1; i<=\$#; i++)); do
  a="\${!i}"; j=\$((i+1))
  case "\$a" in -X) M="\${!j}" ;; --data-binary) B="\${!j}" ;; esac
done
case "\$M \$URL" in
  "POST "*/api/landing-decisions) printf '%s\n' "\$B" >> "$T/ld-posts.txt"; printf '{"ok":true,"id":1}\n201\n'; exit 0 ;;
  "PUT "*/api/landing-decisions/outcome) printf '%s\n' "\$B" >> "$T/ld-outcomes.txt"; printf '{"ok":true}\n200\n'; exit 0 ;;
  "PUT "*/api/ledger) printf '%s\n' "\$B" >> "$T/ledger-puts.txt" ;;
  "GET "*/api/risk-tiers*)
    N=\$(printf '%s' "\$URL" | sed -n 's/.*[?&]pr=\([0-9]*\).*/\1/p')
    printf '{"rows":[{"head_sha":"%s","tier":"%s"}]}\n200\n' "\$(cat "$T/head-\$N" 2>/dev/null)" "\$(cat "$T/tier-\$N" 2>/dev/null || echo low)"; exit 0 ;;
esac
exec "$T/fakebin/curl.nhv" "\$@"
EOF
chmod +x "$T/fakebin/curl"
export JOBS_URL=https://jobs.example.test
H61=dddddddddddddddddddddddddddddddddddd0061
H62=dddddddddddddddddddddddddddddddddddd0062
nhvf_pr 61 "$H61"
SD="$T/h/state/merge-conductor"
# pq_green <n> — a green pre-queue verdict for PR <n>'s head, dispatched now.
pq_green() { mkdir -p "$SD/prequeue"; printf 'green %s run-fixture s1\n' "$(date +%s)" > "$SD/prequeue/example-org_mgfy-os_$1_$(cat "$T/head-$1")_cccccccccccccccccccccccccccccccccccc0000"; }
# d_run <mode> [env…] — a fresh READY row per PR, a green contract, one tick.
d_run() {
  local mode="$1" n; shift
  nhvf_reset
  nhvf_la 0 "no protected path"; echo success > "$T/status-mode"
  for n in $(cat "$T/prs"); do pq_green "$n"; done
  : > "$T/ld-posts.txt"; : > "$T/ld-outcomes.txt"; : > "$T/ledger-puts.txt"; : > "$T/merge-puts.txt"; nhvf_clear
  ( export MC_LANDING_MODE="$mode"; for n in "$@"; do export "${n?}"; done; nhvf_tick )
}
nput() { local c; c=$(grep -c . "$T/merge-puts.txt" 2>/dev/null); echo "${c:-0}"; }
nadd() { local c; c=$(grep -c . "$T/label-adds.txt" 2>/dev/null); echo "${c:-0}"; }
ATT="$SD/attempts.txt"

# ── D1 + P1 ─────────────────────────────────────────────────────────────────
rm -f "$T/merge-mode" "$T/tier-61"
d_run optimistic
[ "$(nput)" = 1 ] && grep -q "repos/example-org/mgfy-os/pulls/61/merge .*sha=$H61" "$T/merge-puts.txt" && ok \
  || bad "D1: exactly one merge PUT bound to H61 ($(cat "$T/merge-puts.txt"); $(grep -F '#61' "$CLOG" | tail -6))"
[ "$(nadd)" = 0 ] && ok || bad "D1: no label POST ($(cat "$T/label-adds.txt"))"
[ "$(nhvf_field 61 2)" = MERGED ] && ok || bad "D1: the row is MERGED (got '$(nhvf_field 61 2)'; $(grep -F '#61' "$CLOG" | tail -4))"
jq -se --arg h "$H61" 'length==1 and .[0].outcome=="merged" and .[0].head==$h and .[0].number==61 and .[0].mode=="optimistic"' "$T/ld-outcomes.txt" >/dev/null 2>&1 \
  && ok || bad "D1: one outcome PUT merged ($(cat "$T/ld-outcomes.txt"))"
jq -se 'length==1 and .[0].would=="direct" and .[0].reason=="ok"' "$T/ld-posts.txt" >/dev/null 2>&1 && ok || bad "D1: one decision row would=direct ($(cat "$T/ld-posts.txt"))"
grep -qF "example-org/mgfy-os#61 LANDING_DIRECT outcome=merged head=${H61:0:12}" "$CLOG" && ok || bad "D1: the LANDING_DIRECT line ($(grep LANDING "$CLOG"))"
jq -se 'map(select(.kind=="merge")) | length==1 and .[0].status=="merged" and .[0].detail=="merge-conductor path=direct"' "$T/ledger-puts.txt" >/dev/null 2>&1 \
  && ok || bad "P1: the ledger merge row says path=direct ($(cat "$T/ledger-puts.txt"))"

# ── D2: ineligible -> the queue, byte-equal to queue mode ───────────────────
echo high > "$T/tier-61"
d_run queue; cp "$T/label-adds.txt" "$T/d2-adds-queue.txt"
d_run optimistic; cp "$T/label-adds.txt" "$T/d2-adds-opt.txt"
[ "$(nadd)" = 1 ] && cmp -s "$T/d2-adds-queue.txt" "$T/d2-adds-opt.txt" && ok || bad "D2: one label POST, byte-equal to queue mode ($(cat "$T/d2-adds-opt.txt"))"
[ "$(nput)" = 0 ] && ok || bad "D2: no merge PUT ($(cat "$T/merge-puts.txt"))"
[ "$(nhvf_field 61 2)" = QUEUED ] && ok || bad "D2: the row is QUEUED (got '$(nhvf_field 61 2)')"
jq -se 'length==1 and .[0].would=="queue" and .[0].reason=="tier-high"' "$T/ld-posts.txt" >/dev/null 2>&1 && ok || bad "D2: one row would=queue tier-high ($(cat "$T/ld-posts.txt"))"
[ ! -s "$T/ld-outcomes.txt" ] && ok || bad "D2: no outcome PUT ($(cat "$T/ld-outcomes.txt"))"

# ── P1 (queue half): a queue landing keeps detail merge-conductor ─────────
# D2 left #61 QUEUED. GitHub now says it merged: the QUEUED pass settles it.
# A PR merged out of a queue leaves the open list.
touch "$T/merged-61"; : > "$T/ledger-puts.txt"; nhvf_clear; : > "$T/prs"
MC_LANDING_MODE=optimistic nhvf_tick
rm -f "$T/merged-61"; echo 61 > "$T/prs"
[ "$(nhvf_field 61 2)" = MERGED ] && ok || bad "P1: the queued PR settled MERGED (got '$(nhvf_field 61 2)'; $(grep -F '#61' "$CLOG" | tail -4))"
jq -se 'map(select(.kind=="merge")) | length==1 and .[0].detail=="merge-conductor"' "$T/ledger-puts.txt" >/dev/null 2>&1 \
  && ok || bad "P1: a queued landing's ledger merge row says merge-conductor ($(cat "$T/ledger-puts.txt"))"
[ "$(nput)" = 0 ] && ok || bad "P1: the queue landing made no merge PUT"
rm -f "$T/tier-61"

# ── D3: the direct budget ───────────────────────────────────────────────────
nhvf_pr 62 "$H62"
d_run optimistic MC_DIRECT_MERGE_BUDGET=1
S61=$(nhvf_field 61 2); S62=$(nhvf_field 62 2)
{ [ "$S61/$S62" = MERGED/READY ] || [ "$S61/$S62" = READY/MERGED ]; } && ok || bad "D3: one MERGED, one READY (61 $S61, 62 $S62; $(grep -E 'LANDING|budget' "$CLOG" | tail -6))"
[ "$(nput)" = 1 ] && [ "$(nadd)" = 0 ] && ok || bad "D3: one merge PUT, no label POST (puts $(nput), adds $(nadd))"
jq -se 'map(.outcome) | sort == ["budget","merged"]' "$T/ld-outcomes.txt" >/dev/null 2>&1 && ok || bad "D3: outcomes budget + merged ($(cat "$T/ld-outcomes.txt"))"
WAIT=61; [ "$S62" = READY ] && WAIT=62
WHY=$(cat "$SD/ready-why/"* 2>/dev/null | awk -F'\t' -v h="$(cat "$T/head-$WAIT")" '$2==h {print $3}')
[ "$WHY" = budget ] && ok || bad "D3: the waiting PR's ready-why reason is budget (got '$WHY')"
# One PR again for D4/D5.
scratch_rm "$T/h/builds/pool-mgfy-MG-62-2026100100"; echo 61 > "$T/prs"

# ── D4: a 409 falls back to the queue next tick ─────────────────────────────
echo 409 > "$T/merge-mode"
d_run optimistic
[ "$(nput)" = 1 ] && [ "$(nadd)" = 0 ] && ok || bad "D4: one merge PUT, no label (puts $(nput), adds $(nadd))"
[ "$(nhvf_field 61 2)" = READY ] && ok || bad "D4: the row stays READY (got '$(nhvf_field 61 2)'; $(grep -F '#61' "$CLOG" | tail -4))"
grep -qxF "landingfail example-org/mgfy-os#61 $H61 409" "$ATT" && ok || bad "D4: landingfail 409 ($(grep landing "$ATT"))"
! grep -q "^mergefail " "$ATT" && ok || bad "D4: no mergefail strike ($(grep mergefail "$ATT"))"
jq -se 'length==1 and .[0].outcome=="409"' "$T/ld-outcomes.txt" >/dev/null 2>&1 && ok || bad "D4: outcome 409 ($(cat "$T/ld-outcomes.txt"))"
! grep -q '"merged"' "$T/ld-outcomes.txt" && ok || bad "D4: never outcome merged on a 409"
: > "$T/merge-puts.txt"; : > "$T/ld-outcomes.txt"; nhvf_clear
MC_LANDING_MODE=optimistic nhvf_tick
[ "$(nadd)" = 1 ] && [ "$(nput)" = 0 ] && ok || bad "D4: the next tick enqueues (adds $(nadd), puts $(nput); $(grep -F '#61' "$CLOG" | tail -4))"
grep -qF "LANDING_DIRECT fallback=queue head=${H61:0:12}" "$CLOG" && ok || bad "D4: the fallback line ($(grep LANDING "$CLOG"))"

# ── D5: shadow never merges directly ────────────────────────────────────────
rm -f "$T/merge-mode"
d_run shadow
[ "$(nput)" = 0 ] && [ "$(nadd)" = 1 ] && ok || bad "D5: shadow -> no merge PUT, one label POST (puts $(nput), adds $(nadd))"
[ "$(nhvf_field 61 2)" = QUEUED ] && ok || bad "D5: the row is QUEUED (got '$(nhvf_field 61 2)')"

echo "landing-direct.bh-6745: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
