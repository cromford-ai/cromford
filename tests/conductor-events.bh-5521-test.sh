#!/bin/bash
# tests/conductor-events.bh-5521-test.sh — BH-5521: the merge conductor reacts
# to PR events, and the full tick is an hourly, bounded, single safety sweep.
#
# WAKE HALF (E1-E12, S5b). The REAL bin/wake-loop.sh runs as the hub
# (BOX_NAME=box-hub) on the tests/lib/wake-claim-stub.sh worker, with
# WAKE_CONDUCTOR_KEYED=1 (the live row). The conductor is a recorder writing
# `argv1 TAB MC_ONLY_PR=… TAB argv`. A `gh` stub answers the sha -> open PR
# lookup (GET repos/<repo>/commits/<sha>/pulls) from $H/fx/pulls-<sha>.json,
# fails it when $H/fx/pulls-<sha>.fail exists, and logs every lookup to
# $H/calls/gh-lookups. Under WAKE_CONDUCTOR_FULL=0 (the default) the loop never
# launches an unkeyed conductor run.
#
# SWEEP HALF (S1, S3-S5). S1 drives bin/lib/cadence-backstop.sh with no row.
# S3-S5 drive the WHOLE bin/merge-conductor.sh over two projects, a (#7) and
# b (#3), on the bh-5463 fixture (fx_mc_harness + fx_conductor_tick + the
# closure), with the real flock.
#
# Fields asserted per case are named in each case's comment.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/conductor-events.bh-5521-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

# ════════════════════════════════════════════════════════════════════════════
# WAKE HALF
# ════════════════════════════════════════════════════════════════════════════
H="$T/h"
export HARNESS="$H"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/locks" "$H/state" "$H/calls" "$H/fx"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
scratch_install_closure bin/wake-loop.sh "$H" >/dev/null || { echo "FAIL: scratch_install_closure bin/wake-loop.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
# The two fleet readers the loop EXECUTES (not sources), so no closure names them.
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/box-for.sh"
printf 'demo example-org/demo https://d.example /api/board 2 local\n' > "$H/fleet.conf"
printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/flock"
for s in run-triage.sh deploy-train.sh postmerge-qa.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; done
printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
chmod +x "$H/bin/setsid" "$H/bin/flock" "$H/bin/run-triage.sh" "$H/bin/deploy-train.sh" \
         "$H/bin/postmerge-qa.sh" "$H/bin/unblocked-children.sh"
wcs_install "$H/bin"
wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE \
      WAKE_CONDUCTOR_PER_TICK WAKE_CONDUCTOR_KEYED WAKE_CONDUCTOR_FULL WAKE_CONDUCTOR_SHA_LOOKUPS \
      WAKE_COOLDOWN_S WAKE_LOOP_CYCLES MC_ONLY_PR
cat > "$H/bin/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\n'; exit 0 ;;
  *"/commits/"*"/pulls"*)
    p=""; prev=""; for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
    printf '%s\n' "$p" >> "$HARNESS/calls/gh-lookups"
    s="${p#*/commits/}"; s="${s%%/*}"
    if [ -e "$HARNESS/fx/pulls-$s.fail" ]; then
      printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1
    fi
    printf 'HTTP/2 200\r\n\r\n'; cat "$HARNESS/fx/pulls-$s.json" 2>/dev/null || echo '[]'; exit 0 ;;
esac
echo ""; exit 0
SH
chmod +x "$H/bin/gh"

SHA_KNOWN=3f1a9c0d5e7b2a4f6c8e0d1b3a5f7c9e1d3b5a70     # #7's head in pr-state.tsv
SHA_NEW=9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c      # #9's head, not in pr-state.tsv
SHA_MAIN=0123456789abcdef0123456789abcdef01234567     # a main-branch merge commit
OWED="$H/state/wake-conductor-owed"
PRS="$H/state/merge-conductor/pr-state.tsv"
NOTLAUNCHED='not launched; the hourly sweep covers them'

W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-10-11T12:00:00Z"}' "$1" "$2" "$3" "$4" "${5:-ev}"; }
wakes() { printf '{"wakes":[%s]}\n' "$(printf '%s,' "$@" | sed 's/,$//')" > "$H/wakes.json"; }
pulls() { # pulls <sha> <json>
  printf '%s\n' "$2" > "$H/fx/pulls-$1.json"; }
openpr() { jq -nc --argjson n "$1" --arg h "$2" '[{number:$n,state:"open",head:{sha:$h}}]'; }

reset() {
  for d in calls state flags fx; do scratch_rm "$H/$d"; done; rm -f "$H/wakes.json"
  mkdir -p "$H/calls" "$H/state/wcs" "$H/state/merge-conductor" "$H/fx"
  : > "$H/logs/wake-loop.log"
  printf 'example-org/demo#7\tready\t0\t%s\t-\t-\t-\thttps://x/7\n' "$SHA_KNOWN" > "$PRS"
  cat > "$H/bin/merge-conductor.sh" <<'SH'
#!/bin/bash
printf '%s\tMC_ONLY_PR=%s\t%s\n' "${1:-}" "${MC_ONLY_PR:-}" "$*" >> "$HARNESS/calls/merge-conductor"
SH
  chmod +x "$H/bin/merge-conductor.sh"
  wakes
}
run() {
  PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=box-hub \
    WAKE_LOOP_CYCLES="${WAKE_LOOP_CYCLES:-1}" WAKE_LOOP_INTERVAL_S=0 \
    WAKE_COOLDOWN_S="${WAKE_COOLDOWN_S:-0}" FLEET_CONF="$H/fleet.conf" \
    WAKE_CONDUCTOR_KEYED="${WAKE_CONDUCTOR_KEYED:-1}" \
    bash "$H/bin/wake-loop.sh" >/dev/null 2>&1 || true
  local prev="" cur i
  for i in 1 2 3 4 5 6; do
    sleep 0.25
    cur=$(cat "$H/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
launches() { cnt . "$H/calls/merge-conductor"; }
only() { awk -F'\t' -v n="${1:-1}" 'NR==n {sub(/^MC_ONLY_PR=/,"",$2); print $2; exit}' "$H/calls/merge-conductor" 2>/dev/null; }
lookups() { cnt . "$H/calls/gh-lookups"; }
cooltakes() { cnt 'POST /api/wakes/cooldown/take' "$H/state/wcs/curl.log"; }
wlog() { cat "$H/logs/wake-loop.log"; }

# E1. WAKE_CONDUCTOR_FULL=2 is read as 0 with one line. Fields: the log line,
# launches (0 for the E6 row, i.e. FULL=0 behaviour).
reset; wakes "$(W 1 example-org/demo checks "$SHA_MAIN" status)"
pulls "$SHA_MAIN" '[{"number":40,"state":"closed","head":{"sha":"'"$SHA_MAIN"'"}}]'
WAKE_CONDUCTOR_FULL=2 run
[ "$(grep -c "WAKE_CONDUCTOR_FULL='2' is not 0 or 1 — using 0" "$H/logs/wake-loop.log")" = 1 ] && ok \
  || bad "E1: expected one 'WAKE_CONDUCTOR_FULL='2' is not 0 or 1' line: $(wlog)"
[ "$(launches)" = 0 ] && ok || bad "E1: FULL=2 must behave as 0 (no unkeyed launch), got $(launches)"
# ...and unset says nothing about it.
reset; wakes "$(W 1 example-org/demo pr 7)"
run
grep -q 'WAKE_CONDUCTOR_FULL' "$H/logs/wake-loop.log" && bad "E1: the knob unset must say nothing about it" || ok

# E2 (control, ticket AT-1 wake half). A lead-verdict status for #7's head
# (in pr-state.tsv). Fields: launches, MC_ONLY_PR, no lookup.
reset; wakes "$(W 1 example-org/demo checks "$SHA_KNOWN" status)"
run
[ "$(launches)" = 1 ] && ok || bad "E2: one launch expected (got $(launches))"
[ "$(only)" = "example-org/demo#7" ] && ok || bad "E2: MC_ONLY_PR must be example-org/demo#7 (got '$(only)')"
[ "$(lookups)" = 0 ] && ok || bad "E2: a sha pr-state.tsv knows needs no GitHub lookup (got $(lookups))"

# E3. The W1 worker row (kind=pr key=12 event=workflow_run.completed). Fields:
# launches, MC_ONLY_PR.
reset; wakes "$(W 1 example-org/demo pr 12 workflow_run.completed)"
run
[ "$(launches)" = 1 ] && ok || bad "E3: one launch expected (got $(launches))"
[ "$(only)" = "example-org/demo#12" ] && ok || bad "E3: MC_ONLY_PR must be example-org/demo#12 (got '$(only)')"

# E4 (control). pull_request.synchronize on #7. Fields: MC_ONLY_PR.
reset; wakes "$(W 1 example-org/demo pr 7 pull_request.synchronize)"
run
[ "$(only)" = "example-org/demo#7" ] && ok || bad "E4: MC_ONLY_PR must be example-org/demo#7 (got '$(only)')"

# E5. A lead-verdict status for a head pr-state.tsv does not know; GitHub says
# open PR #9 has that head. Fields: launches, MC_ONLY_PR, one lookup, its path.
reset; wakes "$(W 1 example-org/demo checks "$SHA_NEW" status)"
pulls "$SHA_NEW" "$(openpr 9 "$SHA_NEW")"
run
[ "$(launches)" = 1 ] && ok || bad "E5: one launch expected (got $(launches))"
[ "$(only)" = "example-org/demo#9" ] && ok || bad "E5: MC_ONLY_PR must be example-org/demo#9 from the lookup (got '$(only)')"
[ "$(lookups)" = 1 ] && ok || bad "E5: exactly one lookup (got $(lookups))"
grep -qx "repos/example-org/demo/commits/$SHA_NEW/pulls" "$H/calls/gh-lookups" 2>/dev/null && ok \
  || bad "E5: the lookup path (got $(cat "$H/calls/gh-lookups" 2>/dev/null))"

# E6. A main-branch sha: the lookup answers only a CLOSED PR. Fields: launches,
# the not-launched line with miss=1, owed file, cooldown takes.
reset; wakes "$(W 1 example-org/demo checks "$SHA_MAIN" check_suite.completed)"
pulls "$SHA_MAIN" '[{"number":40,"state":"closed","head":{"sha":"'"$SHA_MAIN"'"}}]'
run
[ "$(launches)" = 0 ] && ok || bad "E6: a sha that names no open PR must launch nothing (got $(launches): $(cat "$H/calls/merge-conductor" 2>/dev/null))"
grep -q 'lookups=1 miss=1 unread=0 skipped=0' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok \
  || bad "E6: expected the not-launched line with miss=1: $(wlog)"
[ ! -e "$OWED" ] && ok || bad "E6: nothing may be owed (got $(cat "$OWED" 2>/dev/null))"
[ "$(cooltakes)" = 0 ] && ok || bad "E6: no cooldown may be taken (got $(cooltakes))"
grep -q 'no conductor run; the hourly sweep covers them' "$H/logs/wake-loop.log" && ok \
  || bad "E6: the no-run line: $(wlog)"

# E7. The lookup answers an open PR whose head is another sha. Fields:
# launches, miss=1.
reset; wakes "$(W 1 example-org/demo checks "$SHA_NEW" status)"
pulls "$SHA_NEW" "$(openpr 9 "$SHA_MAIN")"
run
[ "$(launches)" = 0 ] && ok || bad "E7: a moved head must launch nothing (got $(launches))"
grep -q 'miss=1' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok || bad "E7: expected miss=1: $(wlog)"

# E8. The lookup is rate limited. Fields: launches, unread=1, no owed line.
reset; wakes "$(W 1 example-org/demo checks "$SHA_NEW" status)"
touch "$H/fx/pulls-$SHA_NEW.fail"
run
[ "$(launches)" = 0 ] && ok || bad "E8: an unreadable lookup must launch nothing (got $(launches))"
grep -q 'lookups=1 miss=0 unread=1 skipped=0' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok \
  || bad "E8: expected unread=1: $(wlog)"
[ ! -e "$OWED" ] && ok || bad "E8: nothing may be owed (got $(cat "$OWED" 2>/dev/null))"

# E9. Six unknown shas in one drain, WAKE_CONDUCTOR_SHA_LOOKUPS=5. Fields:
# lookups, skipped=1.
reset
rows=(); for i in 1 2 3 4 5 6; do rows+=("$(W "$i" example-org/demo checks "$(printf "e%039d" "$i")" status)"); done
wakes "${rows[@]}"
WAKE_CONDUCTOR_SHA_LOOKUPS=5 run
[ "$(lookups)" = 5 ] && ok || bad "E9: exactly 5 lookups (got $(lookups))"
grep -q '6 checks sha(s) named no open PR (lookups=5 miss=5 unread=0 skipped=1)' <<<"$(grep "$NOTLAUNCHED" "$H/logs/wake-loop.log")" && ok \
  || bad "E9: expected 6 shas, skipped=1: $(wlog)"
[ "$(launches)" = 0 ] && ok || bad "E9: no launch (got $(launches))"

# E10. An owed file with `*` only. Fields: launches, owed file gone, the
# dropped line, cooldown takes.
reset; printf '*\n' > "$OWED"
run
[ "$(launches)" = 0 ] && ok || bad "E10: a * debt must launch nothing (got $(launches))"
[ ! -e "$OWED" ] && ok || bad "E10: the owed file must be gone (got $(cat "$OWED" 2>/dev/null))"
grep -q 'pr/checks owed: 1 unkeyed line(s) dropped — the hourly sweep covers them' "$H/logs/wake-loop.log" && ok \
  || bad "E10: the dropped line: $(wlog)"
[ "$(cooltakes)" = 0 ] && ok || bad "E10: an empty debt must not take the cooldown (got $(cooltakes))"
grep -q '^wake-conductor-owed\.taking\.' <<<"$(ls "$H/state/")" && bad "E10: a taking file was left behind" || ok

# E10b. `*` plus two keys -> one keyed launch of the two. Fields: MC_ONLY_PR.
reset; printf 'example-org/demo#7\n*\nexample-org/demo#8\n' > "$OWED"
run
[ "$(launches)" = 1 ] && ok || bad "E10b: one launch (got $(launches))"
[ "$(only)" = "example-org/demo#7,example-org/demo#8" ] && ok || bad "E10b: keyed on the two keys (got '$(only)')"

# E11. 51 distinct owed keys -> one keyed launch carrying exactly 50, the 51st
# stays owed. Fields: launches, key count, owed lines, the put-back line.
reset; for i in $(seq 1 51); do printf 'example-org/demo#%s\n' "$i"; done > "$OWED"
run
[ "$(launches)" = 1 ] && ok || bad "E11: one launch (got $(launches))"
[ "$(only | tr ',' '\n' | grep -c .)" = 50 ] && ok || bad "E11: the launch must carry exactly 50 keys (got $(only | tr ',' '\n' | grep -c .))"
[ "$(cat "$OWED" 2>/dev/null)" = "example-org/demo#51" ] && ok || bad "E11: the 51st key stays owed (got '$(cat "$OWED" 2>/dev/null)')"
grep -q 'pr/checks owed: 1 key(s) past 50 put back' "$H/logs/wake-loop.log" && ok || bad "E11: the put-back line: $(wlog)"
# E11b. Exactly 50 -> one launch, nothing owed.
reset; for i in $(seq 1 50); do printf 'example-org/demo#%s\n' "$i"; done > "$OWED"
run
[ "$(only | tr ',' '\n' | grep -c .)" = 50 ] && [ ! -e "$OWED" ] && ok || bad "E11b: 50 keys launch whole, owed empty"

# E12 (rollback). FULL=1 + no lookups with the E6 row -> today's unkeyed launch.
# Fields: launches, MC_ONLY_PR empty, no lookup.
reset; wakes "$(W 1 example-org/demo checks "$SHA_MAIN" status)"
WAKE_CONDUCTOR_FULL=1 WAKE_CONDUCTOR_SHA_LOOKUPS=0 run
[ "$(launches)" = 1 ] && ok || bad "E12: FULL=1 launches once (got $(launches))"
[ "$(only)" = "" ] && ok || bad "E12: FULL=1 launches unkeyed (got '$(only)')"
[ "$(lookups)" = 0 ] && ok || bad "E12: LOOKUPS=0 makes no lookup (got $(lookups))"
grep -q 'checks sha(s) named no open PR' <<<"$(grep "launched unkeyed" "$H/logs/wake-loop.log")" && ok || bad "E12: the FULL=1 tail: $(wlog)"
# E12b. FULL=1: a `*` debt is today's unkeyed pay.
reset; printf '*\n' > "$OWED"
WAKE_CONDUCTOR_FULL=1 run
[ "$(launches)" = 1 ] && [ "$(only)" = "" ] && ok || bad "E12b: FULL=1 pays * unkeyed (launches $(launches), '$(only)')"

# E13. A pr row with no usable key (and nothing else) under FULL=0 -> no launch.
reset; wakes "$(W 1 example-org/demo pr -)"
run
[ "$(launches)" = 0 ] && ok || bad "E13: a keyless pr row must launch nothing under FULL=0 (got $(launches))"
grep -q 'pr/checks: 1 wake(s) named no PR — no conductor run; the hourly sweep covers them' "$H/logs/wake-loop.log" && ok \
  || bad "E13: the no-run line: $(wlog)"
# ...and held by a refused cooldown it owes nothing.
reset; wakes "$(W 1 example-org/demo pr -)"
COOL_MODE=false run
[ ! -e "$OWED" ] && ok || bad "E13: a keyless batch held by the cooldown owes nothing (got '$(cat "$OWED" 2>/dev/null)')"

# S5b (ticket AT-3, wake side). E2+E5+E6+E10 in one batch under the default
# knobs -> every recorded launch is keyed. Fields: launches, each MC_ONLY_PR.
reset; printf '*\n' > "$OWED"
wakes "$(W 1 example-org/demo checks "$SHA_KNOWN" status)" "$(W 2 example-org/demo checks "$SHA_NEW" status)" \
      "$(W 3 example-org/demo checks "$SHA_MAIN" check_suite.completed)"
pulls "$SHA_NEW" "$(openpr 9 "$SHA_NEW")"
WAKE_CONDUCTOR_PER_TICK=0 run
[ "$(launches)" -ge 1 ] && ok || bad "S5b: the batch must launch (got $(launches))"
grep -q . <<<"$(awk -F'\t' '$2 == "MC_ONLY_PR="' "$H/calls/merge-conductor" 2>/dev/null)" \
  && bad "S5b: a wake launched a full tick: $(cat "$H/calls/merge-conductor")" || ok
v=$(only)
case ",$v," in *,example-org/demo#7,*) ok ;; *) bad "S5b: missing #7 (got '$v')" ;; esac
case ",$v," in *,example-org/demo#9,*) ok ;; *) bad "S5b: missing #9 (got '$v')" ;; esac

# ════════════════════════════════════════════════════════════════════════════
# SWEEP HALF
# ════════════════════════════════════════════════════════════════════════════
# S1. The backstop default is 60 min: 1800 s -> skip (rc 3), 3570 s -> run.
GATE="$DIR/bin/lib/cadence-backstop.sh"
G="$T/g"; mkdir -p "$G/logs" "$G/state/cadence-backstop"
gate() { env -i PATH="/usr/bin:/bin" HARNESS="$G" bash "$GATE" merge-conductor >/dev/null 2>&1; }
printf '%s\n' "$((NOW - 1800))" > "$G/state/cadence-backstop/merge-conductor.last"
gate; [ $? = 3 ] && ok || bad "S1: 30 min into the 60 min sweep must skip (rc 3)"
printf '%s\n' "$((NOW - 3570))" > "$G/state/cadence-backstop/merge-conductor.last"
gate; [ $? = 0 ] && ok || bad "S1: 59m30s is inside the 30 s jitter slack and must run"

# S3-S5: the whole conductor (bh-5463 fixture).
command -v flock >/dev/null || { echo "flock missing — S3-S5 skipped"; echo "conductor-events.bh-5521: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
unset HARNESS
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
CT="$T/cx"; C="$CT/h"; FB="$CT/fakebin"
fx_mc_harness "$DIR" "$CT" && fx_conductor_tick "$DIR" "$CT" || { echo "FAIL: conductor fixture"; exit 1; }
scratch_install_closure bin/merge-conductor.sh "$C" >/dev/null || { echo "FAIL: closure install failed for bin/merge-conductor.sh"; exit 1; }
mkdir -p "$C/tmp" "$T/repos/a/.git" "$T/repos/b/.git"
printf 'a example-org/a https://a.example /api/board 2 local\nb example-org/b https://b.example /api/board 2 local\n' > "$C/fleet.conf"
: > "$C/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$C/bin/agent-call.sh"; chmod +x "$C/bin/agent-call.sh"
cat > "$FB/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
printf '#!/bin/bash\nexit 0\n' > "$FB/git"
chmod +x "$FB/curl" "$FB/git"
sha() { printf "$1%.0s" {1..40}; }
pr_list() {
  jq -nc --arg r "$1" --argjson n "$2" --arg h "$(sha "$2")" '[{number:$n,
    html_url:("https://github.com/"+$r+"/pull/"+($n|tostring)), title:"t", draft:false, state:"open",
    updated_at:"2026-10-08T00:00:00Z", created_at:"2026-10-01T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]'
}
pr_one() {
  jq -nc --arg r "$1" --argjson n "$2" --arg h "$(sha "$2")" '{number:$n, state:"open", merged_at:null, draft:false,
    html_url:("https://github.com/"+$r+"/pull/"+($n|tostring)), user:{login:"operator"}, labels:[],
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}},
    mergeable:true, mergeable_state:"behind", updated_at:"2026-10-08T00:00:00Z"}'
}
mkdir -p "$T/fx"
pr_list example-org/a 7 > "$T/fx/list-a.json"; pr_one example-org/a 7 > "$T/fx/a-7.json"
pr_list example-org/b 3 > "$T/fx/list-b.json"; pr_one example-org/b 3 > "$T/fx/b-3.json"
cat > "$FB/gh" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$$" "$*" >> "$GHT/gh-calls.txt"
[ -n "${MC_WORKERS_DONE_BY:-}${MC_WINDOW_NEXT:-}" ] && printf '%s\n' "$*" >> "$GHT/gh-env-leak"
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
pg=1; [[ " $* " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
case "$*" in
  *"auth token"*) echo fixture-token; exit 0 ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  *"pr merge"*|*"pr edit"*|*"pr close"*|*"api -i -X PATCH"*|*"api -i -X POST"*|*"api -X PATCH"*) exit 1 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
esac
case "$p" in
  repos/example-org/[ab]/pulls|repos/example-org/[ab]/pulls\?state=open*)
    r="${p#repos/example-org/}"; r="${r%%/*}"
    if [ "$r" = a ]; then printf '%s\n' "$$" > "$GHT/gh-pid-a"; sleep "${GH_SLOW:-0}"; fi
    printf 'HTTP/2 200\r\n\r\n'; [ "$pg" = 1 ] && cat "$GHT/fx/list-$r.json" || echo '[]' ;;
  repos/example-org/[ab]/pulls\?state=closed*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/example-org/[ab]/pulls/*/files*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/example-org/[ab]/pulls/[0-9]*)
    r="${p#repos/example-org/}"; r="${r%%/*}"; n="${p##*/pulls/}"; n="${n%%[!0-9]*}"
    if [ -f "$GHT/fx/$r-$n.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/fx/$r-$n.json"
    else printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; fi ;;
  repos/example-org/[ab]/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$(printf 'f%.0s' {1..40})" '{ref:"refs/heads/main", object:{sha:$s}}' ;;
  *"actions/runs"*) restpr --runs 'in_progress|' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
chmod +x "$FB/gh"

LOG="$C/logs/merge-conductor.log"
SKIP_A="TICK a skipped: another full tick of a is still running"
WIN='full tick: worker window'
creset() {
  scratch_rm "$C/state/merge-conductor"
  mkdir -p "$C/state/merge-conductor"
  : > "$LOG"; : > "$T/gh-calls.txt"; rm -f "$T/gh-pid-a" "$T/gh-env-leak" "$T"/tick*.err
}
tick() { # tick <tag> [VAR=value...]
  local tag="$1"; shift
  ( cd "$T" && env -u MC_WORKERS_DONE_BY -u MC_FULL_TICK_BUDGET_S PATH="$FB:$PATH" HARNESS="$C" GHT="$T" HARNESS_SECRET=x TMPDIR="$C/tmp" \
      MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_PR_PARALLEL=1 \
      MC_TICK_SECS=0 MC_HEAD_LAG_MINS=0 MC_MAIN_RED_DETECT=0 MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 \
      FLEET_CONF="$C/fleet.conf" "$@" bash "$C/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.$tag.err"
    echo "$?" > "$T/rc.$tag" )
}
waitfile() { local i; for i in $(seq 1 120); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }
mclog() { tail -20 "$LOG" 2>/dev/null; }

# S3. The full-tick window line. Fields: the `full tick: worker window <B>s` line.
creset; tick s3a MC_FULL_TICK_BUDGET_S=1500
grep -q "$WIN 1500s (MC_FULL_TICK_BUDGET_S)" "$LOG" && ok || bad "S3: an unkeyed tick must set a 1500s window: $(mclog)"
creset; tick s3d
grep -q "$WIN 1500s" "$LOG" && ok || bad "S3: the knob unset is the 1500s default: $(mclog)"
creset; tick s3b MC_ONLY_PR=example-org/a#7 MC_FULL_TICK_BUDGET_S=1500
grep -q "$WIN" "$LOG" && bad "S3: a keyed tick must set no full-tick window: $(mclog)" || ok
creset; tick s3c MC_FULL_TICK_BUDGET_S=0
grep -q "$WIN" "$LOG" && bad "S3: MC_FULL_TICK_BUDGET_S=0 must set no window" || ok
creset; tick s3e MC_FULL_TICK_BUDGET_S=abc
grep -q "$WIN 1500s" "$LOG" && ok || bad "S3: a garbage budget reads as 1500: $(mclog)"
creset; tick s3f MC_FULL_TICK_BUDGET_S=1500 MC_WORKERS_DONE_BY=$((NOW + 100000))
grep -q "$WIN" "$LOG" && bad "S3: the caller's MC_WORKERS_DONE_BY wins (no full-tick window)" || ok
grep -q 'WINDOW_DEFERRED' "$LOG" && bad "S3: a wide window defers nothing: $(mclog)" || ok

# S4. A 1 s budget: every PR is deferred, not started. Fields: the
# WINDOW_DEFERRED tail, FANIN has no `missing`, deferred:window, the deferred
# PR's pr-state row byte-identical.
creset
printf 'example-org/a#7\tready\t0\t%s\t-\t-\t-\thttps://github.com/example-org/a/pull/7\n' "$(sha 7)" > "$C/state/merge-conductor/pr-state.tsv"
grep -F 'example-org/a#7' "$C/state/merge-conductor/pr-state.tsv" > "$T/row.before"
tick s4 MC_FULL_TICK_BUDGET_S=1
[ "$(grep -c 'WINDOW_DEFERRED: .*the next hourly sweep or a wake for this PR takes it' "$LOG")" = 2 ] && ok \
  || bad "S4: both PRs must be deferred with the sweep tail: $(mclog)"
grep -q 'example-org/a#7 WINDOW_DEFERRED' "$LOG" && grep -q 'example-org/b#3 WINDOW_DEFERRED' "$LOG" && ok || bad "S4: each PR named: $(mclog)"
grep -q 'the next backstop fire takes it first' "$LOG" && bad "S4: the full tick must not name the backstop as next owner" || ok
grep -q 'FANIN merge-conductor' "$LOG" && ok || bad "S4: a FANIN line is expected: $(mclog)"
grep -q 'missing' <<<"$(grep 'FANIN' "$LOG")" && bad "S4: a deferral is accounted, never missing: $(grep FANIN "$LOG")" || ok
grep -q 'deferred:window' <<<"$(grep 'FANIN' "$LOG")" && ok || bad "S4: FANIN counts deferred:window: $(grep FANIN "$LOG")"
grep -F 'example-org/a#7' "$C/state/merge-conductor/pr-state.tsv" | cmp -s - "$T/row.before" && ok \
  || bad "S4: the deferred PR's pr-state row changed: $(grep -F 'example-org/a#7' "$C/state/merge-conductor/pr-state.tsv")"
# The backstop's own text is unchanged when no MC_WINDOW_NEXT is set.
grep -qF '${MC_WINDOW_NEXT:-the next backstop fire takes it first}' "$DIR/bin/lib/fanin.sh" && ok \
  || bad "S4: mc_window_defer keeps today's text as the default"
# The window is never exported: no child process of the tick (every gh call)
# sees MC_WORKERS_DONE_BY or MC_WINDOW_NEXT in its environment.
grep -q 'WINDOW_DEFERRED' "$LOG" && [ -s "$T/gh-calls.txt" ] && [ ! -s "$T/gh-env-leak" ] && ok \
  || bad "S4: a child of the full tick inherited the window: $(head -3 "$T/gh-env-leak" 2>/dev/null)"

# S5 (ticket AT-3). Two unkeyed ticks at once, with the window on: one skip, one
# list read of a. Fields: skip line count, list read count.
creset
tick one GH_SLOW=3 &
P1=$!
waitfile "$T/gh-pid-a" || bad "S5: the first tick never read a's list: $(mclog)"
tick two
wait "$P1"
[ "$(grep -c "$SKIP_A" "$LOG")" = 1 ] && ok || bad "S5: expected one '$SKIP_A' line: $(mclog)"
[ "$(grep -cE 'repos/example-org/a/pulls(\?state=open| |$)' "$T/gh-calls.txt")" = 1 ] && ok \
  || bad "S5: a's open-PR list must be read once: $(grep -c 'example-org/a/pulls' "$T/gh-calls.txt")"


# K1 / S2: ONE READY PR, the WHOLE conductor (the tier2-autoenqueue AT-25 shape):
# an approved build record on the head, green checks, a green lead-verdict
# status, a green pre-queue cache entry for (head, main), Mergify's queue check
# as the witness, flags merge-conductor-actions + merge-conductor-merge. The
# fleet has a second repo, example-org/other-os, with no PRs.
KT="$T/k"; KH="$KT/h"; KB="$KT/fakebin"
mkdir -p "$KH/bin/lib" "$KH/logs" "$KH/state" "$KH/flags" "$KH/locks" "$KH/builds" "$KH/env" "$KH/tmp" "$KB"
scratch_install_closure bin/merge-conductor.sh "$KH" >/dev/null || { echo "closure failed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$KH/bin/fleet-conf.sh"
# BH-4148 (#4614): the lead's protected paths are worker rows now, not
# catalog/lead-protected-paths.tsv. The fake worker answers the route
# (tests/lib/lpp-stub.sh) with no rows for this repo, as the deleted TSV did.
mkdir -p "$KH/catalog"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_install "$KB" "$KT/lpp-rows.json" "$KT/lpp-down"
scratch_install_closure bin/jobs-client.sh "$KH" >/dev/null || { echo "closure jobs failed"; exit 1; }
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$KH/bin/$s.sh"; done
chmod +x "$KH/bin/"*.sh
cp "$DIR/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
KSLUG=example-org/mgfy-os; KHEAD=$(printf 'a%.0s' {1..40}); KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
printf 'mgfy %s - - 2 box-m\nother example-org/other-os - - 2 box-m\n' "$KSLUG" > "$KH/fleet.conf"
: > "$KH/env/global.env"
REC="$KH/builds/pool-mgfy-MG-31-202610110001"; mkdir -p "$REC"
echo "PR_CREATED $KU/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$KHEAD" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
cat > "$KT/list.json" <<J
[{"number":31,"url":"$KU/31","headRefOid":"$KHEAD","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
jq -nc --arg r "$KSLUG" --arg h "$KHEAD" '[{number:31, html_url:("https://github.com/"+$r+"/pull/31"), title:"t", draft:false, state:"open",
  updated_at:"2026-10-11T00:00:00Z", created_at:"2026-10-10T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
  head:{sha:$h, ref:"ticket/mg-31", repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]' > "$KT/rest-list.json"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$KB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$KT/calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *"api -i -X GET repos/$KSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$KSLUG/commits/main"*|*"api -i -X GET repos/$KSLUG/git/ref/heads/main"*) restpr --raw 200 '{"sha":"$KMAIN","object":{"sha":"$KMAIN"}}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":2,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"},{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":"In merge queue"},"app":{"slug":"mergify"}}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X POST repos/"*"/statuses/"*) printf '%s\n' "\$*" >> "$KT/statuses.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*|*"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$KT/cmds.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$KT/cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$KT/merges.txt"; exit 1 ;;
  *"api -i -X GET repos/$KSLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*|*"api --paginate repos/"*"/reviews"*) echo '[]' ;;
  *"api repos/"*"/comments --paginate"*) : ;;
  *"api repos/$KSLUG/issues/31"*) printf '{"number":31,"state":"open","labels":[],"body":""}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*) restpr OPEN "$KHEAD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls?state=open"*) restpr --raw 200 "\$(cat "$KT/rest-list.json")" ;;
  *"api -i -X GET repos/"*"/pulls?state=open"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*|*"api -i -X GET repos/"*"/pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api repos/$KSLUG -q .id"*) echo 1 ;;
  *"pr list -R $KSLUG --state open"*) cat "$KT/list.json" ;;
  *"pr list"*) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$KB/gh"
cat > "$KB/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
m=GET; prev=""; for a in "$@"; do [ "$prev" = -X ] && m="$a"; prev="$a"; done
case "$URL" in
  */api/lead-protected-paths*) "$(dirname "$0")/lpp-answer" "$m" "$URL"; exit 0 ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$KB/curl"
touch "$KH/flags/merge-conductor-actions" "$KH/flags/merge-conductor-merge"
ktick() {
  ( cd "$KT" && env PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-fixture \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$KH/fleet.conf" "$@" \
    bash "$KH/bin/merge-conductor.sh" >/dev/null 2>"$KT/tick.err" ); }
kreset() {
  scratch_rm "$KH/state/merge-conductor"
  mkdir -p "$KH/state/merge-conductor/prequeue"
  printf 'green %s 1 -\n' "$NOW" > "$KH/state/merge-conductor/prequeue/example-org_mgfy-os_31_${KHEAD}_${KMAIN}"
  : > "$KH/logs/merge-conductor.log"; : > "$KT/calls.txt"; rm -f "$KT/cmds.txt"
}
KLOG="$KH/logs/merge-conductor.log"
klog() { tail -12 "$KLOG" 2>/dev/null; }

# K1 (ticket AT-1, conductor half). The keyed run the E2 wake launches
# (MC_ONLY_PR=example-org/mgfy-os#31). Fields: the keyed-tick line, the enqueue
# line, the QUEUED transition, no tick-mgfy.json, no window line, no list read
# of the other fleet repo.
kreset
ktick MC_ONLY_PR=example-org/mgfy-os#31
grep -q 'keyed tick: 1 key(s) — example-org/mgfy-os#31' "$KLOG" && ok || bad "K1: the keyed-tick line: $(klog)"
grep -q "example-org/mgfy-os#31 enqueued in the mergify merge queue at ${KHEAD:0:8}" "$KLOG" && ok || bad "K1: the PR must be enqueued in one keyed run: $(klog) $(tail -3 "$KT/tick.err")"
grep -q "example-org/mgfy-os#31 READY -> QUEUED head=${KHEAD:0:8}" "$KLOG" && ok || bad "K1: the QUEUED transition: $(klog)"
[ ! -e "$KH/state/merge-conductor/tick-mgfy.json" ] && ok || bad "K1: a keyed run must not write the full tick's tick-mgfy.json"
grep -q "$WIN" "$KLOG" && bad "K1: a keyed run sets no full-tick window" || ok
grep -q 'repos/example-org/other-os/pulls' "$KT/calls.txt" && bad "K1: a keyed run read another repo's open-PR list: $(grep other-os "$KT/calls.txt")" || ok

# S2 (ticket AT-2). The same READY PR, no wake ever written: the unkeyed sweep
# enqueues it. Fields: the enqueue line, the QUEUED transition, the window line,
# the other repo's list read (a full tick).
kreset
ktick
grep -q "example-org/mgfy-os#31 enqueued in the mergify merge queue at ${KHEAD:0:8}" "$KLOG" && ok || bad "S2: the sweep must enqueue a missed READY PR: $(klog)"
grep -q "example-org/mgfy-os#31 READY -> QUEUED head=${KHEAD:0:8}" "$KLOG" && ok || bad "S2: the QUEUED transition: $(klog)"
grep -q "$WIN 1500s" "$KLOG" && ok || bad "S2: the sweep is bounded: $(klog)"
grep -q 'repos/example-org/other-os/pulls' "$KT/calls.txt" && ok || bad "S2: a full tick reads every fleet repo"

echo "conductor-events.bh-5521: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
