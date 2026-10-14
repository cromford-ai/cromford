#!/bin/bash
# tests/pool-hold-yield.bh-6091-test.sh — BH-6091: a running pool build yields
# at its next write point when the ticket is on HOLD.
#
# THE INCIDENT (#5962, 2026-10-11/12). the operator held the ticket at 23:36:14Z and
# again at 00:16:03Z. The pool pushed ticket/bh-5962 at 00:01:29Z, then rebased,
# pushed and opened PR #6089 at 00:25:30Z. Every pool push already re-read the
# hold (BH-2504). Both HOLD comments carried a capital RESUME ("HOLD: the lead
# reversed the RESUME above"), and bin/lib/hold.sh read each one as a LIFT. So
# the push guard said clear.
#
# THE ROWS (red first: C, Y1, Y2 and Y5 fail on main 7a208727):
#   C   a person's comment that OPENS with `HOLD:` or `HOLD —` holds, and one
#       whose first non-empty line is a bare `HOLD` (any case) holds (8 shapes,
#       two of them #6091's real HOLD comments)
#   N   eight shapes that must NOT hold, each the newest over an older HOLD
#       (incl. `HOLD-free` / `HOLD-ing`: the dash needs a word boundary)
#   Y1  ticket case 1: RESUME newest, a push; HOLD lands; the fix-round push
#       yields — exit 3, HOLD_YIELD in pipeline.log and RESULT, origin unchanged,
#       the commit still in the worktree
#   Y2  ticket case 2: the second #5962 HOLD before the pre-PR push — no push,
#       no PR create; and the pr-open gate on its own yields with no create
#   Y3  ticket case 3: RESUME newest — the push happens, no RESULT
#   Y4  ticket case 4: the thread is unreadable — no push, rc 4, no exit; the
#       next write point (readable, RESUME newest) pushes
#   Y5  ticket case 5: hold_check (the fly-pool relaunch gate's reader) is held
#       on both #5962 shapes until a newer RESUME
#   Y7  a push from a subshell (the background E2E lane) returns 3, no RESULT
#   Y8  the pr-body gate: held or unreadable skips `gh pr edit` and keeps the
#       PR_CREATED RESULT; with no hold library it fails closed too
#   Y9  review of e68d8e58: a HOLD landing during the QA fix session, AFTER the
#       PR is open — the qa-fix push yields that push only: no exit, no
#       RESULT from the yield, origin unchanged, a HOLD_YIELD note the
#       PR_CREATED line carries
# The bin/launch-fastpath.sh rows (section F of the plan) live in
# tests/launch-fastpath-test.sh T1.4f, which already has the fixture that runs
# the real script.
# Run from anywhere: bash tests/pool-hold-yield.bh-6091-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ============================================================================
# C / N — bin/lib/hold.sh hold_classify, the shared reader
# ============================================================================
# shellcheck source=bin/lib/hold.sh
. "$DIR/bin/lib/hold.sh" || { echo "FAIL: bin/lib/hold.sh does not source"; exit 1; }
IJ='{"state":"open","title":"t","body":"b","labels":[{"name":"ai-build"}]}'
CM() { # CM <type> <iso> <body> — one REST comment
  jq -nc --arg t "$1" --arg c "$2" --arg b "$3" '{id:1,user:{type:$t},created_at:$c,body:$b}'
}
OLD_HOLD=$(CM User 2026-10-11T23:00:00Z 'HOLD: waiting on the lead')
OLD_RESUME=$(CM User 2026-10-11T23:00:00Z 'RESUME — go ahead')
S1='HOLD: the lead reversed the RESUME above (the two messages crossed).'
S2='HOLD: a Mac agent owns the branch. Please make no pool push until the PR is open and RESUME is posted.'
# R1/R2: the two real HOLD comments on #6091 (2026-10-12 06:29:44Z and
# 10:31:13Z, review of 82abecc2): a bare `HOLD` line, a blank line, then text
# that names RESUME. A bare HOLD line holds in any case; `HOLD:`/`HOLD —` with
# text on the line stays upper case (N7: lower-case "hold:" prose is not one).
R1=$'HOLD\n\nA Mac agent (fix-5462) is fixing the five suites that failed batch #6143 on PR #6112. A RESUME follows when the fix is pushed.\n'
R2=$'HOLD\n\nA Mac agent (fix-5462) is fixing the lead BLOCK on PR #6112 (verdict #1703: a HOLD at the qa-fix push after the PR is open ended the build). A RESUME follows when the fix is pushed.\n'
C_ROWS=(
  "$S1"
  "$S2"
  'HOLD — do not RESUME'
  $'  \nHOLD: x RESUME'
  "$R1"
  "$R2"
  'HOLD'
  $'hold  \r\nuntil the lead says RESUME'
)
i=0
for b in "${C_ROWS[@]}"; do
  i=$((i+1))
  v=$(hold_classify "$IJ" "[$OLD_RESUME,$(CM User 2026-10-12T00:16:03Z "$b")]"); rc=$?
  [ "$rc" = 1 ] && case "$v" in "held	hold:comment"*) true ;; *) false ;; esac \
    && ok || bad "C$i an opening HOLD must hold: rc=$rc '$v' for '$b'"
done
N_ROWS=(
  'RESUME: the pool is building; the HOLD above is withdrawn'
  'HOLD lifted, go ahead'
  'UNHOLD: go'
  'hold: lower case prose, RESUME'
  'Notes on the HOLD: RESUME now'
  'HOLD-free comment: RESUME now'
  'HOLD-ing is over, RESUME'
)
i=4
for b in "${N_ROWS[@]}"; do
  i=$((i+1)); [ "$i" = 8 ] && i=9   # row 8 is the bot row below
  v=$(hold_classify "$IJ" "[$OLD_HOLD,$(CM User 2026-10-12T00:16:03Z "$b")]"); rc=$?
  [ "$rc" = 0 ] && ok || bad "N$i must stay clear when newest: rc=$rc '$v' for '$b'"
done
v=$(hold_classify "$IJ" "[$OLD_RESUME,$(CM Bot 2026-10-12T00:16:03Z 'HOLD: x')]"); rc=$?
[ "$rc" = 0 ] && ok || bad "N8 a bot's opening HOLD is not heard: rc=$rc '$v'"

# ============================================================================
# Y — the real RB_PUSH / RB_HOLD_GATE / RB_HOLD_YIELD against a bare origin
# ============================================================================
ISO() { printf '2026-10-12T00:%02d:00Z' "$1"; }
mkdir -p "$T/fakebin" "$T/gh" "$T/h/bin/lib" "$T/build"
export HARNESS="$T/h"
# FIXTURE fleet: tproj is a GitHub-Issues lane (board prefix "-").
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
# The fake GitHub: $T/gh/issue-<n>.json, $T/gh/comments-<n>.json; $T/gh/fail
# makes every call fail. Every call is logged to $T/gh.log.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
[ -f "$T/gh/fail" ] && { echo "API rate limit already exceeded (FIXTURE)" >&2; exit 1; }
N=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p' | head -1)
case "\$*" in
  *"/issues/"*"/comments"*) cat "$T/gh/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"/issues/"*) cat "$T/gh/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
jq -nc '{number:9,state:"open",title:"BH-9: a FIXTURE ticket",body:"## Scope",labels:[{name:"ai-build"}]}' > "$T/gh/issue-9.json"
THREAD() { # THREAD [<body> <minute>]... — the REST comments array, oldest first
  local rows=()
  while [ $# -ge 2 ]; do
    rows+=("$(jq -nc --arg b "$1" --arg c "$(ISO "$2")" '{body:$b,created_at:$c,user:{type:"User"}}')")
    shift 2
  done
  local IFS=,; printf '[%s]\n' "${rows[*]}" > "$T/gh/comments-9.json"
}

# The push library laid out as it ships, with its closure.
scratch_install_closure bin/lib/hold-push.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }

# The run-build functions under test, lifted by name from the real files.
fn() { awk -v f="$1(){" 'index($0, f) == 1 {on=1} on {print} on && /^}/ {exit}' "$DIR/bin/lib/rb/gates.sh"; }
blk() { awk -v b="# >>> $2" -v e="# <<< $2" 'index($0, b) {on=1} on {print} index($0, e) {exit}' "$DIR/$1"; }
{ fn RB_HOLD_YIELD; fn RB_HOLD_GATE; fn RB_PUSH; } > "$T/rb-fns.sh"
for f in RB_HOLD_YIELD RB_HOLD_GATE RB_PUSH; do
  grep -q "^$f(){" "$T/rb-fns.sh" && ok || bad "bin/lib/rb/gates.sh has no $f"
done
blk bin/lib/rb/pr.sh 'pr-open hold gate' > "$T/pr-open.sh"
grep -q 'RB_HOLD_GATE pr-open' "$T/pr-open.sh" && ok || bad "bin/lib/rb/pr.sh has no pr-open hold gate block"
# The pr-body gate and the edit it guards: the marker block through the `fi`
# that closes the `gh pr edit` arm.
awk 'index($0, "# >>> pr-body hold gate") {on=1} on {print} on && /gh pr edit/ {e=1} e && /^    fi$/ {exit}' \
  "$DIR/bin/lib/rb/result.sh" > "$T/pr-body.sh"
grep -q 'gh pr edit' "$T/pr-body.sh" && grep -q 'pr-body hold gate' "$T/pr-body.sh" \
  && ok || bad "bin/lib/rb/result.sh has no pr-body hold gate block before its gh pr edit"

# --- a real origin and the build's worktree ----------------------------------
G="$T/git"; mkdir -p "$G"
git init -q --bare "$G/origin.git"
git clone -q "$G/origin.git" "$G/wt" 2>/dev/null
gitc() { git -C "$1" -c user.name=FIXTURE -c user.email=fixture@example.invalid -c commit.gpgsign=false "${@:2}"; }
( cd "$G/wt" && echo base > f.txt && git add f.txt ) && gitc "$G/wt" commit -qm base
git -C "$G/wt" push -q origin HEAD:refs/heads/main
BR=ticket/bh-9
git -C "$G/wt" checkout -qb "$BR"
remote_tip() { git -C "$G/origin.git" rev-parse "refs/heads/$BR" 2>/dev/null; }
COMMIT() { echo "$1" >> "$G/wt/pr.txt"; git -C "$G/wt" add pr.txt; gitc "$G/wt" commit -qm "$1"; git -C "$G/wt" rev-parse HEAD; }

# The driver: a fresh bash per case, so an `exit` is observable as its rc.
cat > "$T/drive.sh" <<EOF
#!/bin/bash
PROJECT=tproj KEY=BH-9 BRANCH=$BR BUILD="$T/build"
STAMP() { printf '2026-10-12T00:00:00Z'; }
RESULT() { echo "\$*" > "\$BUILD/RESULT"; }
track_pushed() { git update-ref "refs/remotes/origin/\$BRANCH" "\$(git rev-parse HEAD)"; }
. "$T/h/bin/lib/hold-push.sh" 2>/dev/null
. "$T/rb-fns.sh"
cd "$G/wt" || exit 98
eval "\$1"
EOF
DRIVE() { rm -f "$T/build/RESULT"; : > "$T/build/pipeline.log"; : > "$T/gh.log"; bash "$T/drive.sh" "$1" >"$T/drive.out" 2>&1; }

# A first push with RESUME newest: the branch is on origin, as after execute.
THREAD 'RESUME — go ahead' 0
DRIVE 'RB_PUSH -u execute && track_pushed'; RC=$?
BASE_TIP=$(remote_tip)
[ "$RC" = 0 ] && [ -n "$BASE_TIP" ] && ok || bad "setup: the first push must land (rc $RC: $(cat "$T/build/pipeline.log"))"

# Y1 — case 1: RESUME newest at the start; the #5962 HOLD lands mid-build;
# the fix-round push yields.
NEW=$(COMMIT "refute finding 1")
THREAD 'RESUME — go ahead' 0 "$S1" 36
DRIVE 'RB_PUSH -u "the refuter fix round"; echo "returned $?"'; RC=$?
[ "$RC" = 3 ] && ok || bad "Y1 a held fix-round push must exit the build 3 (got $RC: $(cat "$T/drive.out"))"
grep -q 'returned' "$T/drive.out" && bad "Y1 RB_PUSH returned to its caller under a HOLD — the build went on" || ok
[ "$(head -c 14 "$T/build/RESULT" 2>/dev/null)" = BUILD_DEFERRED ] && ok || bad "Y1 RESULT must start BUILD_DEFERRED: '$(cat "$T/build/RESULT" 2>/dev/null)'"
grep -q '^BUILD_DEFERRED HOLD_YIELD BH-9 at the refuter fix round' "$T/build/RESULT" 2>/dev/null \
  && ok || bad "Y1 RESULT must name HOLD_YIELD BH-9 at the refuter fix round: '$(cat "$T/build/RESULT" 2>/dev/null)'"
grep -q 'HOLD_YIELD BH-9 at the refuter fix round' "$T/build/pipeline.log" && ok || bad "Y1 pipeline.log must carry the HOLD_YIELD line"
[ "$(remote_tip)" = "$BASE_TIP" ] && ok || bad "Y1 origin moved under a HOLD"
[ "$(git -C "$G/wt" rev-parse HEAD)" = "$NEW" ] && ok || bad "Y1 the fix-round commit must stay in the worktree"

# Y2 — case 2: the second #5962 HOLD is newest before the pre-PR push.
THREAD 'RESUME — go ahead' 0 "$S1" 36 'RESUME' 50 "$S2" 56
DRIVE "{ RB_PUSH -u pr-push && track_pushed; } || { RESULT 'BUILD_DEFERRED push rejected'; exit 3; }
$(cat "$T/pr-open.sh")
gh pr create --head \"\$BRANCH\""; RC=$?
[ "$RC" = 3 ] && ok || bad "Y2 a held pre-PR push must exit 3 (got $RC)"
grep -q '^BUILD_DEFERRED HOLD_YIELD BH-9 at pr-push' "$T/build/RESULT" 2>/dev/null \
  && ok || bad "Y2 RESULT must name HOLD_YIELD at pr-push: '$(cat "$T/build/RESULT" 2>/dev/null)'"
[ "$(remote_tip)" = "$BASE_TIP" ] && ok || bad "Y2 origin moved under a HOLD"
grep -qE 'pr create|pulls' "$T/gh.log" && bad "Y2 a PR was created under a HOLD: $(cat "$T/gh.log")" || ok
# ...and the pr-open gate alone: the push answered 0, the HOLD landed after it.
DRIVE "RB_PUSH() { return 0; }
$(cat "$T/pr-open.sh")
gh pr create --head \"\$BRANCH\""; RC=$?
[ "$RC" = 3 ] && ok || bad "Y2 the pr-open gate must exit 3 under a HOLD (got $RC)"
grep -q '^BUILD_DEFERRED HOLD_YIELD BH-9 at pr-open' "$T/build/RESULT" 2>/dev/null \
  && ok || bad "Y2 RESULT must name HOLD_YIELD at pr-open: '$(cat "$T/build/RESULT" 2>/dev/null)'"
grep -qE 'pr create|pulls' "$T/gh.log" && bad "Y2 the pr-open gate let a create through" || ok
# ...and unreadable at pr-open: no create, deferred.
touch "$T/gh/fail"
DRIVE "$(cat "$T/pr-open.sh")
gh pr create --head \"\$BRANCH\""; RC=$?
rm -f "$T/gh/fail"
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED hold unreadable at pr-open' "$T/build/RESULT" 2>/dev/null \
  && ok || bad "Y2 an unreadable hold at pr-open must defer (rc $RC, '$(cat "$T/build/RESULT" 2>/dev/null)')"
grep -q 'pr create' "$T/gh.log" && bad "Y2 an unreadable hold let a create through" || ok

# Y3 — case 3: RESUME newest, the push happens and nothing is deferred.
THREAD "$S1" 36 'RESUME — the Mac agent is done' 58
DRIVE 'RB_PUSH -u pr-push && track_pushed'; RC=$?
[ "$RC" = 0 ] && ok || bad "Y3 an unheld push must answer 0 (got $RC: $(cat "$T/build/pipeline.log"))"
[ "$(remote_tip)" = "$NEW" ] && ok || bad "Y3 origin must hold the local head"
[ -e "$T/build/RESULT" ] && bad "Y3 an unheld push wrote a RESULT: $(cat "$T/build/RESULT")" || ok
# ...and the pr-open gate lets the create through.
DRIVE "$(cat "$T/pr-open.sh")
gh pr create --head \"\$BRANCH\""; RC=$?
[ "$RC" = 0 ] && grep -q 'pr create' "$T/gh.log" && ok || bad "Y3 the pr-open gate must let an unheld create through (rc $RC)"

# Y4 — case 4: the thread cannot be read at push time.
NEW2=$(COMMIT "fix round 2")
touch "$T/gh/fail"
DRIVE 'RB_PUSH -u "the merged fix round"; echo "returned $?"'; RC=$?
rm -f "$T/gh/fail"
[ "$RC" = 0 ] && grep -q 'returned 4' "$T/drive.out" && ok || bad "Y4 an unreadable hold must return 4, not exit (rc $RC: $(cat "$T/drive.out"))"
[ "$(remote_tip)" = "$NEW" ] && ok || bad "Y4 origin moved on an unreadable hold"
[ -e "$T/build/RESULT" ] && bad "Y4 an unreadable hold wrote a RESULT" || ok
# ...retried at the next write point, now readable with RESUME newest.
DRIVE 'RB_PUSH -u pr-push && track_pushed'; RC=$?
[ "$RC" = 0 ] && [ "$(remote_tip)" = "$NEW2" ] && ok || bad "Y4 the next write point must push (rc $RC)"

# Y5 — case 5: the relaunch gate's reader (bin/fly-pool.sh pool_hold_check ->
# hold_check) stays held on both #5962 shapes until a newer RESUME.
for s in "$S1" "$S2" "$R2"; do
  THREAD 'RESUME — go ahead' 0 "$s" 36
  ( . "$T/h/bin/lib/hold.sh"; hold_check o/tproj 9 ) >/dev/null 2>&1; RC=$?
  [ "$RC" = 1 ] && ok || bad "Y5 hold_check must be held after '$s' (rc $RC)"
  THREAD 'RESUME — go ahead' 0 "$s" 36 'RESUME' 40
  ( . "$T/h/bin/lib/hold.sh"; hold_check o/tproj 9 ) >/dev/null 2>&1; RC=$?
  [ "$RC" = 0 ] && ok || bad "Y5 a newer RESUME must clear hold_check (rc $RC)"
done

# Y7 — a push from a subshell (the background E2E lane) returns 3.
COMMIT "e2e round" >/dev/null
THREAD 'RESUME' 0 "$S1" 36
DRIVE '( RB_PUSH -u e2e ); echo "sub $?"'; RC=$?
[ "$RC" = 0 ] && grep -q 'sub 3' "$T/drive.out" && ok || bad "Y7 a subshell push must return 3 (rc $RC: $(cat "$T/drive.out"))"
grep -q 'HOLD_YIELD BH-9 at e2e' "$T/build/pipeline.log" && ok || bad "Y7 pipeline.log must carry HOLD_YIELD at e2e"
[ -e "$T/build/RESULT" ] && bad "Y7 a subshell yield wrote a RESULT" || ok
[ "$(remote_tip)" = "$NEW2" ] && ok || bad "Y7 origin moved under a HOLD"

# Y8 — the PR body edit, after the PR is open.
Y8() { # Y8 <label> — under the current thread/fail state
  DRIVE "PR_URL=https://github.com/o/tproj/pull/77; EVIDENCE_SECTION=x
PR_BODY_FOR() { echo body; }
echo 'PR_CREATED https://github.com/o/tproj/pull/77' > \"\$BUILD/RESULT\"
$(cat "$T/pr-body.sh")
echo 'went on'"; RC=$?
  [ "$RC" = 0 ] && grep -q 'went on' "$T/drive.out" && ok || bad "Y8/$1 the pr-body gate must not exit (rc $RC)"
  grep -q 'pr edit' "$T/gh.log" && bad "Y8/$1 gh pr edit ran: $(cat "$T/gh.log")" || ok
  grep -q 'HOLD_YIELD BH-9 at pr-body-edit' "$T/build/pipeline.log" && ok || bad "Y8/$1 pipeline.log must carry HOLD_YIELD at pr-body-edit"
  [ "$(cat "$T/build/RESULT")" = 'PR_CREATED https://github.com/o/tproj/pull/77' ] && ok || bad "Y8/$1 RESULT must keep PR_CREATED"
}
rm -f "$T/build/RESULT"
Y8 held
touch "$T/gh/fail"; Y8 unreadable; rm -f "$T/gh/fail"
THREAD 'RESUME' 0
DRIVE "PR_URL=https://github.com/o/tproj/pull/77; EVIDENCE_SECTION=x
PR_BODY_FOR() { echo body; }
$(cat "$T/pr-body.sh")"; RC=$?
grep -q 'pr edit https://github.com/o/tproj/pull/77' "$T/gh.log" && ok || bad "Y8/clear an unheld ticket must get its body edit (rc $RC: $(cat "$T/gh.log"))"

# Y8/no-lib — the pr-body gate fails CLOSED when the hold library is missing.
THREAD 'RESUME' 0
DRIVE "unset -f hold_push_verdict; PR_URL=https://github.com/o/tproj/pull/77; EVIDENCE_SECTION=x
PR_BODY_FOR() { echo body; }
echo 'PR_CREATED https://github.com/o/tproj/pull/77' > \"\$BUILD/RESULT\"
$(cat "$T/pr-body.sh")
echo 'went on'"; RC=$?
[ "$RC" = 0 ] && grep -q 'went on' "$T/drive.out" && ok || bad "Y8/no-lib the pr-body gate must not exit (rc $RC)"
grep -q 'pr edit' "$T/gh.log" && bad "Y8/no-lib gh pr edit ran with no hold library (fails open): $(cat "$T/gh.log")" || ok
grep -q 'HOLD_YIELD BH-9 at pr-body-edit' "$T/build/pipeline.log" && ok || bad "Y8/no-lib pipeline.log must carry HOLD_YIELD at pr-body-edit"

# Y9 — the QA fix session ends after the PR is open; the HOLD landed during it.
# The qa-fix push yields that push only, and the build goes on to PR_CREATED.
QA_BASE=$(remote_tip)
QAFIX=$(COMMIT "qa fix")
THREAD 'RESUME — go ahead' 0 "$S1" 40
DRIVE 'RB_PR_OPEN=1
{ RB_PUSH qa-fix 2>/dev/null && track_pushed; } || true
echo "went on note=${HOLD_YIELD_NOTE:-}"'; RC=$?
[ "$RC" = 0 ] && grep -q '^went on' "$T/drive.out" && ok || bad "Y9 a held qa-fix push after the PR is open must not end the build (rc $RC: $(cat "$T/drive.out"))"
[ -e "$T/build/RESULT" ] && bad "Y9 the qa-fix yield wrote a RESULT: '$(cat "$T/build/RESULT")'" || ok
grep -q 'note= | HOLD_YIELD BH-9 at qa-fix' "$T/drive.out" && ok || bad "Y9 HOLD_YIELD_NOTE must name the qa-fix yield: $(cat "$T/drive.out")"
grep -q 'HOLD_YIELD BH-9 at qa-fix' "$T/build/pipeline.log" && ok || bad "Y9 pipeline.log must carry the HOLD_YIELD line"
[ "$(remote_tip)" = "$QA_BASE" ] && ok || bad "Y9 origin moved under a HOLD"
[ "$(git -C "$G/wt" rev-parse HEAD)" = "$QAFIX" ] && ok || bad "Y9 the qa-fix commit must stay in the worktree"
# ...and the wiring: the flag is set once the create block has a URL, and every
# PR_CREATED line carries the note.
awk 'index($0, "# <<< pr create call") {on=1} on && /RB_PR_OPEN=1/ {print; exit}' "$DIR/bin/lib/rb/pr.sh" | grep -q 'PR_URL' \
  && ok || bad "Y9 bin/lib/rb/pr.sh must set RB_PR_OPEN=1 (on a PR_URL) after the pr create call block"
N=$(grep -c 'RESULT "PR_CREATED \$PR_URL' "$DIR/bin/lib/rb/result.sh"); M=$(grep 'RESULT "PR_CREATED \$PR_URL' "$DIR/bin/lib/rb/result.sh" | grep -c 'HOLD_YIELD_NOTE')
[ "$N" -ge 1 ] && [ "$M" = "$N" ] && ok || bad "Y9 every PR_CREATED RESULT in result.sh must carry \${HOLD_YIELD_NOTE:-} ($M of $N)"

echo "pool-hold-yield.bh-6091: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
