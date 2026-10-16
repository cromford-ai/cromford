#!/bin/bash
# tests/cmd-dispatch-issue.bh-6737-test.sh — BH-6737: the console's
# dispatch_issue command, and the spawn order it buys in bin/fly-pool.sh.
#
# bin/cmd-dispatch-issue.sh <project> <payload-json> <command_id> checks that
# the issue is open, labelled ai-build and not held (hold_check), that nothing
# already builds it (build-key lock, a state/fly-pool record, a claimed queue
# row) and that it is queued for the pool. Then it writes the marker
# state/dispatch-now/<p>/<KEY>, starts one bin/fly-pool.sh tick detached and
# waits a short, bounded time for a pool record that names the key. Any
# refusal writes no marker and starts no tick.
#
# bin/fly-pool.sh's hotfix_first then orders: hot jobs, then marked jobs, then
# the rest. D5/D6 run the REAL functions, extracted from bin/fly-pool.sh, over
# the marker the REAL cmd script wrote in D1.
#
# Stubs (only the external edges): hold_check (bin/lib/hold.sh), the gh auth
# lib, queue_status (bin/jobs-client.sh) and bin/fly-pool.sh.
# Run from anywhere: tests/cmd-dispatch-issue.bh-6737-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/flags" "$H/env" "$H/logs" "$H/locks" "$H/prompts" "$H/state/fly-pool/pa" "$H/state/build-queue/pa"
for s in bin/cmd-dispatch-issue.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "install $s"
done
cat > "$H/fleet.conf" <<'EOF'
# fixture
pa example-org/fixture-pa - - 1 hub
pb example-org/fixture-pb - - 2 hub
inapp example-org/fixture-inapp https://inapp.example /api/board 3 hub
EOF
printf 'Ticket keys look like PA-<issue-number>.\n' > "$H/prompts/pa.md"
printf 'Ticket keys look like TK-<issue-number>.\n' > "$H/prompts/pb.md"
printf 'Ticket keys look like IN-<issue-number>.\n' > "$H/prompts/inapp.md"
: > "$H/flags/fly-pool-pa"; : > "$H/flags/fly-pool-inapp"

# --- stubs over the installed libs (the closure put the real ones there) ---
mkdir -p "$H/bin/lib"
cat > "$H/bin/lib/hold.sh" <<'EOF'
hold_check() {
  printf '%s %s\n' "$1" "$2" >> "$HOLD_LOG"
  printf '%b\n' "${HOLD_VERDICT:-clear\tok}"
  case "${HOLD_VERDICT:-clear}" in clear*) return 0 ;; held*) return 1 ;; *) return 2 ;; esac
}
EOF
cat > "$H/bin/lib/gh-app-auth.sh" <<'EOF'
gh_auth_for() { return 1; }
gh_auth_reset() { printf 'reset\n' >> "$HOLD_LOG"; }
EOF
cat > "$H/bin/jobs-client.sh" <<'EOF'
queue_status() {
  printf '%s %s\n' "$1" "$2" >> "$QS_LOG"
  [ -n "${QS:-}" ] && printf '%s' "$QS"
  return "${QS_RC:-0}"
}
EOF
cat > "$H/bin/fly-pool.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FP_LOG"
[ "${FP_WRITE:-1}" = 1 ] && printf '{"key":"PA-7","machine":"m9abcdef","ticket_id":"7"}\n' > "$HARNESS/state/fly-pool/$1/m9abcdef.json"
exit 0
EOF
chmod 755 "$H/bin/fly-pool.sh"

reset() {
  local f
  for f in "$H/state/dispatch-now" "$H/state/fly-pool/pa/"* "$H/state/build-queue/pa/"*; do
    [ -e "$f" ] && scratch_rm "$f"
  done
  : > "$T/hold.log"; : > "$T/qs.log"; : > "$T/fp.log"
}
# dis <project> <payload> -> OUT RC
dis() {
  OUT=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" HOLD_LOG="$T/hold.log" QS_LOG="$T/qs.log" \
    FP_LOG="$T/fp.log" CMD_DISPATCH_WAIT_S="${WAIT:-10}" \
    bash "$H/bin/cmd-dispatch-issue.sh" "$1" "$2" 61 2>"$T/err"); RC=$?
}
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
markers() { find "$H/state/dispatch-now" -type f 2>/dev/null | wc -l; }
# no_side_effects <label>: no marker, no tick.
no_side_effects() {
  [ "$(markers)" = 0 ] && ok || bad "$1: a marker was written"
  sleep 0.3; [ ! -s "$T/fp.log" ] && ok || bad "$1: fly-pool.sh was started"
}

echo "--- D1: an open, queued ai-build issue is marked and a tick starts"
reset; export QS=queued QS_RC=0
dis pa '{"issue":7}'
[ "$RC" = 0 ] && ok || bad "D1 rc $RC (out=$OUT err=$(cat "$T/err"))"
[ "$(jf .result)" = ok ] && ok || bad "D1 .result (out=$OUT)"
[ "$(markers)" = 1 ] && [ -f "$H/state/dispatch-now/pa/PA-7" ] && ok || bad "D1 markers: $(find "$H/state/dispatch-now" -type f 2>/dev/null)"
[ "$(cat "$T/fp.log")" = pa ] && ok || bad "D1 fly-pool calls: '$(cat "$T/fp.log")'"
[ "$(jf .machine_id)" = m9abcdef ] && ok || bad "D1 .machine_id (out=$OUT)"
[ "$(jf .key)" = PA-7 ] && [ "$(jf .issue)" = 7 ] && [ "$(jf .project)" = pa ] && ok || bad "D1 .key/.issue/.project (out=$OUT)"
[ "$(cat "$T/hold.log" | head -1)" = "example-org/fixture-pa 7" ] && ok || bad "D1 hold_check args: $(cat "$T/hold.log")"
grep -qx reset "$T/hold.log" && ok || bad "D1 gh_auth_reset not called"
[ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && ok || bad "D1 more than one stdout line"

echo "--- D5: the real hotfix_first orders hot, then marked, then the rest"
sed -n '/^job_is_hot() {/,/^}/p;/^job_is_now() {/,/^}/p;/^hotfix_first() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$T/order.sh"
grep -q '^job_is_now() {' "$T/order.sh" && ok || bad "D5 job_is_now is not in bin/fly-pool.sh"
Q="$T/q"; mkdir -p "$Q"
printf '{"key":"PA-1"}\n' > "$Q/PA-1.json"
printf '{"key":"PA-2","hotfix":true}\n' > "$Q/PA-2.json"
printf '{"key":"PA-7"}\n' > "$Q/PA-7.json"
printf '{"key":"PA-4"}\n' > "$Q/PA-4.json"
order() { HARNESS="$H" P=pa HOTFIX_ON=1 bash -c '. "$0"; hotfix_first "$@"' "$T/order.sh" "$@" | xargs -n1 basename | tr '\n' ' '; }
GOT=$(order "$Q/PA-1.json" "$Q/PA-2.json" "$Q/PA-7.json" "$Q/PA-4.json")
[ "$GOT" = "PA-2.json PA-7.json PA-1.json PA-4.json " ] && ok || bad "D5 order '$GOT'"
# A marked hotfix is listed once, in the hot group.
touch "$H/state/dispatch-now/pa/PA-2"
GOT=$(order "$Q/PA-1.json" "$Q/PA-2.json" "$Q/PA-7.json" "$Q/PA-4.json")
[ "$GOT" = "PA-2.json PA-7.json PA-1.json PA-4.json " ] && ok || bad "D5 marked hotfix order '$GOT'"
rm -f "$H/state/dispatch-now/pa/PA-2"

echo "--- D6: no marker is today's order"
rm -f "$H/state/dispatch-now/pa/PA-7"
GOT=$(order "$Q/PA-1.json" "$Q/PA-2.json" "$Q/PA-7.json" "$Q/PA-4.json")
[ "$GOT" = "PA-2.json PA-1.json PA-7.json PA-4.json " ] && ok || bad "D6 order '$GOT'"
# Another project's marker does not move this project's job.
mkdir -p "$H/state/dispatch-now/pb"; touch "$H/state/dispatch-now/pb/PA-7"
GOT=$(order "$Q/PA-1.json" "$Q/PA-2.json" "$Q/PA-7.json" "$Q/PA-4.json")
[ "$GOT" = "PA-2.json PA-1.json PA-7.json PA-4.json " ] && ok || bad "D6 other project's marker '$GOT'"

echo "--- D2: a held, closed or unlabelled issue is refused"
for v in 'held\thold:label hold' 'held\tclosed' 'held\tlabel-absent'; do
  reset
  HOLD_VERDICT="$v" dis pa '{"issue":7}'
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "D2 '$v' rc $RC (out=$OUT)"
  jf .reason | grep -qF "$(printf '%b' "$v" | cut -f2)" && ok || bad "D2 '$v' reason (out=$OUT)"
  no_side_effects "D2 '$v'"
done
reset
HOLD_VERDICT='unreadable\tgh down' dis pa '{"issue":7}'
{ [ "$RC" = 1 ] && [ "$(jf .result)" = failed ]; } && ok || bad "D2 unreadable is failed rc $RC (out=$OUT)"
no_side_effects "D2 unreadable"

echo "--- D3: already building is refused"
reset
( exec 9>"$H/locks/build-key-pa-PA-7.lock"; flock -x 9; exec sleep 30 ) & LP=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n "$H/locks/build-key-pa-PA-7.lock" true 2>/dev/null || break; sleep 0.1
done
dis pa '{"issue":7}'
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
{ [ "$RC" = 3 ] && jf .reason | grep -q 'already building'; } && ok || bad "D3 lock held rc $RC (out=$OUT)"
no_side_effects "D3 lock"
reset
printf '{"key":"PA-7","machine":"m5555555"}\n' > "$H/state/fly-pool/pa/m5555555.json"
dis pa '{"issue":7}'
{ [ "$RC" = 3 ] && jf .reason | grep -q 'already building'; } && ok || bad "D3b pool record rc $RC (out=$OUT)"
no_side_effects "D3b"
reset
QS=claimed dis pa '{"issue":7}'
{ [ "$RC" = 3 ] && jf .reason | grep -q 'already building'; } && ok || bad "D3c claimed row rc $RC (out=$OUT)"
no_side_effects "D3c"
# A free lock file left behind by an old build does not count.
reset; : > "$H/locks/build-key-pa-PA-7.lock"
dis pa '{"issue":7}'
[ "$RC" = 0 ] && ok || bad "D3d a free lock file is not building (rc $RC out=$OUT)"
rm -f "$H/locks/build-key-pa-PA-7.lock"

echo "--- D4: not queued, and the queue outage"
reset
QS="" QS_RC=2 dis pa '{"issue":7}'
{ [ "$RC" = 3 ] && jf .reason | grep -q 'not queued'; } && ok || bad "D4 not queued rc $RC (out=$OUT)"
no_side_effects "D4 not queued"
reset
QS="" QS_RC=1 dis pa '{"issue":7}'
{ [ "$RC" = 1 ] && [ "$(jf .result)" = failed ]; } && ok || bad "D4 outage, no file rc $RC (out=$OUT)"
no_side_effects "D4 outage"
reset; printf '{"key":"PA-7"}\n' > "$H/state/build-queue/pa/PA-7.json"
QS="" QS_RC=1 dis pa '{"issue":7}'
{ [ "$RC" = 0 ] && [ -f "$H/state/dispatch-now/pa/PA-7" ]; } && ok || bad "D4 outage with a queue file rc $RC (out=$OUT)"
reset; printf '{"key":"PA-7"}\n' > "$H/state/build-queue/pa/PA-7.json"
QS="" QS_RC=2 dis pa '{"issue":7}'
[ "$RC" = 0 ] && ok || bad "D4 no row but a queue file rc $RC (out=$OUT)"
reset
QS=done dis pa '{"issue":7}'
{ [ "$RC" = 3 ] && jf .reason | grep -q 'not queued'; } && ok || bad "D4 done row is not queued rc $RC (out=$OUT)"

echo "--- D7: no pool record inside the wait -> machine_id null"
reset
FP_WRITE=0 WAIT=1 dis pa '{"issue":7}'
[ "$RC" = 0 ] && ok || bad "D7 rc $RC (out=$OUT)"
[ "$(jq -r '.machine_id == null' <<<"$OUT" 2>/dev/null)" = true ] && ok || bad "D7 .machine_id (out=$OUT)"
jf .reason | grep -q 'no machine yet' && ok || bad "D7 reason (out=$OUT)"
[ -f "$H/state/dispatch-now/pa/PA-7" ] && ok || bad "D7 marker missing"

echo "--- D8: bad input runs nothing"
for case_ in 'pa|{"issue":"7"}' 'pa|{"issue":0}' 'pa|{"issue":7.5}' 'pa|{"issue":-3}' 'pa|{}' 'pa|nope' \
             'zz|{"issue":7}' 'inapp|{"issue":7}' 'pb|{"issue":7}'; do
  reset
  dis "${case_%%|*}" "${case_#*|}"
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "D8 $case_ rc $RC (out=$OUT)"
  [ ! -s "$T/hold.log" ] && ok || bad "D8 $case_ read the issue"
  no_side_effects "D8 $case_"
done

echo "--- D9: a marker older than 24 h is pruned by the next dispatch"
reset; mkdir -p "$H/state/dispatch-now/pa"
touch -d '2 days ago' "$H/state/dispatch-now/pa/PA-99"
dis pa '{"issue":7}'
{ [ "$RC" = 0 ] && [ ! -e "$H/state/dispatch-now/pa/PA-99" ] && [ -f "$H/state/dispatch-now/pa/PA-7" ]; } \
  && ok || bad "D9 prune (rc $RC, left: $(ls "$H/state/dispatch-now/pa"))"

echo "cmd-dispatch-issue: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
