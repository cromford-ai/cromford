#!/usr/bin/env bash
# tests/lead-step-done.bh-7236-test.sh — lsd_answer (bin/lib/lead-step-done.sh):
# a person's HUMAN-STEP-DONE: (or RESUME) comment, newer than the verdict and
# after the newest NEEDS-HUMAN: marker, answers the step; anything else does not.
#   U1-U12 lsd_answer, pure, on thread fixtures.
#   M1     a scratch copy of the lib with its RESUME branch removed makes U4 red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-step-done.bh-7236-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/lead-step-done.sh" ] || { echo "FAIL: no bin/lib/lead-step-done.sh"; exit 1; }

H="$T/h"; mkdir -p "$H/bin"
scratch_install_closure bin/lib/lead-step-done.sh "$H" >/dev/null || exit 1

# cm <login> <User|Bot> <created_at> <body> — one issue comment, on stdout
CMI=0
cm() { CMI=$((CMI + 1)); jq -nc --arg w "$1" --arg t "$2" --arg at "$3" --arg b "$4" --argjson i "$CMI" \
  '{id:$i, html_url:("https://github.com/example-org/demo-os/issues/900#issuecomment-" + ($i|tostring)), user:{login:$w, type:$t}, created_at:$at, body:$b}'; }
MARK='NEEDS-HUMAN: deploy the jobs worker (npx wrangler deploy) before this PR can land.'
DONE='HUMAN-STEP-DONE: deployed worker/jobs at 11:58Z, version 4f1c.'
VAT=2026-10-14T05:43:37Z
LSD_LIB="$H/bin/lib/lead-step-done.sh"
lsd() { ( . "$LSD_LIB" || exit 9; lsd_answer "$@" ); }

# ── U1-U12: lsd_answer ──
M=$(cm cromford[bot] Bot 2026-10-14T05:43:40Z "$MARK")
D=$(cm operator-a5 User 2026-10-14T12:00:47Z "$DONE")
OUT=$(lsd "$(printf '%s\n' "$M" "$D" | jq -sc .)" "$VAT"); URC=$?
[ "$URC" = 0 ] && grep -qx 'kind: done' <<<"$OUT" && grep -qF 'deployed worker/jobs' <<<"$OUT" \
  && grep -q '^comment: https://github.com/example-org/demo-os/issues/900#issuecomment-' <<<"$OUT" \
  && grep -qx 'author: @operator-a5 at 2026-10-14T12:00:47Z' <<<"$OUT" && ok || bad "U1 rc=$URC out=$OUT"
lsd "$(printf '%s\n' "$D" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U2 no marker: want rc 1, got $URC"
lsd "$(printf '%s\n' "$M" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U3 marker, no answer: want rc 1, got $URC"
R=$(cm operator-a5 User 2026-10-14T12:01:00Z 'RESUME')
OUT=$(lsd "$(printf '%s\n' "$M" "$R" | jq -sc .)" "$VAT"); URC=$?
[ "$URC" = 0 ] && grep -qx 'kind: resume' <<<"$OUT" && ok || bad "U4 RESUME: rc=$URC out=$OUT"
D5=$(cm operator-a5 User 2026-10-14T05:43:36Z "$DONE")
# The marker is older than the done, so only the verdict time can refuse it.
M0=$(cm cromford[bot] Bot 2026-10-14T05:00:00Z "$MARK")
lsd "$(printf '%s\n' "$M0" "$D5" | jq -sc .)" "$VAT" >/dev/null; URC5=$?
[ "$URC5" = 1 ] && ok || bad "U5 a done 1 s before the verdict: want rc 1, got $URC5"
D6=$(cm operator-a5 User "$VAT" "$DONE")
lsd "$(printf '%s\n' "$M0" "$D6" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U6 a done at the verdict second: want rc 1, got $URC"
M7=$(cm cromford[bot] Bot 2026-10-14T13:53:00Z "$MARK")
lsd "$(printf '%s\n' "$M" "$D" "$M7" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U7 a newer marker after the done: want rc 1, got $URC"
D8=$(cm some-app Bot 2026-10-14T12:00:47Z "$DONE")
lsd "$(printf '%s\n' "$M" "$D8" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U8 a Bot's done: want rc 1, got $URC"
for b in 'RESUME once #12 merges' 'do not RESUME yet' 'Resume' 'Ok, RESUME it' \
         $'RESUME\n\nActually, do not resume yet: the key is not rotated.' \
         $'Looks fine.\n\n> HUMAN-STEP-DONE: deployed' $'We ran it.\nHUMAN-STEP-DONE: deployed'; do
  X=$(cm operator-a5 User 2026-10-14T12:00:50Z "$b")
  lsd "$(printf '%s\n' "$M" "$X" | jq -sc .)" "$VAT" >/dev/null; URC=$?
  [ "$URC" = 1 ] && ok || bad "U9 '$b' answered the step (rc $URC)"
done
lsd '{"message":"boom"}' "$VAT" >/dev/null; URC=$?
[ "$URC" = 2 ] && ok || bad "U10 a non-array thread: want rc 2, got $URC"
lsd "$(printf '%s\n' "$M" "$D" | jq -sc .)" 2026-10-14 >/dev/null; URC=$?
[ "$URC" = 2 ] && ok || bad "U11 a since that is not ISO: want rc 2, got $URC"
D12=$(cm operator-a5 User 2026-10-14T12:30:00Z 'HUMAN-STEP-DONE: second run, all green.')
OUT=$(lsd "$(printf '%s\n' "$M" "$D" "$D12" | jq -sc .)" "$VAT"); URC=$?
[ "$URC" = 0 ] && grep -qF 'second run, all green' <<<"$OUT" && ! grep -qF 'version 4f1c' <<<"$OUT" \
  && ok || bad "U12 want the newest done: rc=$URC out=$OUT"

# ── M1 (D1): the lib with its RESUME branch removed no longer answers U4 ──
MUT="$H/bin/lib/lead-step-done.mut.sh"
sed '/elif (.first | test("^RESUME/,/kind: "resume"}/d' "$H/bin/lib/lead-step-done.sh" > "$MUT"
if cmp -s "$MUT" "$H/bin/lib/lead-step-done.sh"; then
  bad "M1 the mutation did not change the lib"
else
  OUT=$(LSD_LIB="$MUT"; lsd "$(printf '%s\n' "$M" "$R" | jq -sc .)" "$VAT"); URC=$?
  [ "$URC" = 1 ] && ok || bad "M1 without the RESUME branch U4 must find no answer (rc 1), got rc=$URC out=$OUT"
fi

echo "lead-step-done.bh-7236: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
