#!/bin/bash
# tests/preplan-speculative-test.sh — speculative pre-planning: candidate
# selection, the parallel cap, the staleness discard, the pool relay wiring and
# the kill flag. Run from anywhere: tests/preplan-speculative-test.sh
# (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY. Pre-planning has run since 2026-07-23 and nothing ever
# consumed it — bin/run-build.sh's PLAN checkpoint guards on $BUILD/plan.md,
# which a fresh build dir never has — so the fleet paid for plans it threw away
# and no test noticed, because every script involved exited 0 the whole time.
# That is the failure this suite exists to make unrepeatable: the adopt path is
# asserted by reading the file, and the freshness rule is driven against a real
# git repo, because "the plan was used" and "the plan was still true" are the
# two claims nothing else checks.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
nl_ge() { [ "$(grep -c . "$T/launched.txt" 2>/dev/null)" -ge "$1" ]; }  # BH-6049: at least N pre-plans launched
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/locks" "$T/plans" \
         "$T/state" "$T/prompts" "$T/repos"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" proj || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$T/bin/lib/"
# TEST-CHANGE (BH-782): bin/preplan-candidates.sh reads GitHub through the
# REST contract now. Without the lib beside it every tick answers "launch gate
# UNKNOWN" and prints no candidates, so the suite would be measuring a missing
# library rather than candidate selection.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
for f in preplan-tick.sh preplan-candidates.sh planned-files.sh fleet-conf.sh \
         box-for.sh project-of.sh fleet-projects-or-alert.sh; do cp "$DIR/bin/$f" "$T/bin/"; done
export PATH="$T/bin:$PATH"
. "$T/bin/lib/preplan-lib.sh"

cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
bproj example-org/bproj  https://b.example /api/board  0 local -
CONF
# The only place a GitHub-Issues project's KEY prefix is written down is its
# rendered triage prompt (prompts/TEMPLATE-GH.md's launch line).
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
cat > "$T/bin/box-name.sh" <<'SH'
#!/bin/bash
echo local
SH
chmod +x "$T/bin/box-name.sh"

# ---------- 1. the kill flag resolves, and the default is ON ----------------
[ "$(preplan_speculative "$T")" = 1 ] && ok || bad "default must be speculative ON"
echo 'PREPLAN_SPECULATIVE=0' > "$T/env/global.env"
[ "$(preplan_speculative "$T")" = 0 ] && ok || bad "PREPLAN_SPECULATIVE=0 in global.env must turn it off"
: > "$T/env/global.env"
[ "$(PREPLAN_SPECULATIVE=0 preplan_speculative "$T")" = 0 ] && ok || bad "the env var must turn it off"
touch "$T/flags/preplan-speculative-off"
[ "$(preplan_speculative "$T")" = 0 ] && ok || bad "flags/preplan-speculative-off must turn it off"
rm -f "$T/flags/preplan-speculative-off"
[ "$(preplan_speculative "$T")" = 1 ] && ok || bad "removing the flag must turn it back on"

# ---------- 2. the caps ------------------------------------------------------
[ "$(preplan_parallel "$T")" = 3 ] && ok || bad "PREPLAN_PARALLEL default is 3 (got $(preplan_parallel "$T"))"
[ "$(preplan_ahead "$T")" = 2 ]    && ok || bad "PREPLAN_AHEAD default is 2 (got $(preplan_ahead "$T"))"
printf 'PREPLAN_PARALLEL=5\nPREPLAN_AHEAD=1\n' > "$T/env/global.env"
[ "$(preplan_parallel "$T")" = 5 ] && ok || bad "global.env must set PREPLAN_PARALLEL"
[ "$(preplan_ahead "$T")" = 1 ]    && ok || bad "global.env must set PREPLAN_AHEAD"
printf 'PREPLAN_PARALLEL=nonsense\n' > "$T/env/global.env"
[ "$(preplan_parallel "$T")" = 3 ] && ok || bad "an unreadable cap falls back to 3, never to unlimited"
: > "$T/env/global.env"
# BH-475: the ready bound follows the schedule's switch, and nothing else does.
[ "$(overlap_schedule "$T")" = 1 ] && ok || bad "OVERLAP_SCHEDULE defaults ON"
# A BOUND, NOT A CEILING-SHAPED HOLE (BH-475 review). Every pre-plan is a paid
# model session, so the raise the schedule wants is a small documented number
# with its OWN knob — never "the whole backlog up to gh's --limit 100", and
# never at the cost of a number an operator set on purpose.
[ "$(preplan_ahead_ready "$T")" = 10 ] && ok \
  || bad "with the schedule on and nothing set, the READY bound is 10 (got: $(preplan_ahead_ready "$T"))"
[ "$(PREPLAN_AHEAD_READY=5 preplan_ahead_ready "$T")" = 5 ] && ok \
  || bad "PREPLAN_AHEAD_READY is the knob that moves the ready bound"
[ "$(PREPLAN_AHEAD_READY=nonsense preplan_ahead_ready "$T")" = 10 ] && ok \
  || bad "an unreadable ready bound falls back to 10, never to unlimited"
[ "$(PREPLAN_AHEAD=0 preplan_ahead_ready "$T")" = 0 ] && ok \
  || bad "PREPLAN_AHEAD=0 stays the ready-class kill switch — it is somebody's spend control"
[ "$(PREPLAN_AHEAD=4 preplan_ahead_ready "$T")" = 4 ] && ok \
  || bad "an explicitly set PREPLAN_AHEAD is never widened underneath the operator"
[ "$(PREPLAN_AHEAD=4 PREPLAN_AHEAD_READY=9 preplan_ahead_ready "$T")" = 9 ] && ok \
  || bad "PREPLAN_AHEAD_READY wins when both are set"
printf 'PREPLAN_AHEAD=0\n' > "$T/env/global.env"
[ "$(preplan_ahead_ready "$T")" = 0 ] && ok \
  || bad "PREPLAN_AHEAD=0 in env/global.env must bound the ready class too (got: $(preplan_ahead_ready "$T"))"
: > "$T/env/global.env"
[ "$(OVERLAP_SCHEDULE=0 preplan_ahead_ready "$T")" = 2 ] && ok \
  || bad "with the schedule off, the READY bound is PREPLAN_AHEAD again"
[ "$(OVERLAP_SCHEDULE=0 preplan_ahead "$T")" = 2 ] && ok \
  || bad "the schedule's switch must not move PREPLAN_AHEAD itself"
touch "$T/flags/overlap-schedule-off"
[ "$(overlap_schedule "$T")" = 0 ] && ok || bad "flags/overlap-schedule-off must turn the schedule off"
[ "$(preplan_ahead_ready "$T")" = 2 ] && ok || bad "the flag must restore the PREPLAN_AHEAD bound"
rm -f "$T/flags/overlap-schedule-off"

# ---------- 3. freshness against a real repo --------------------------------
R="$T/repo"; mkdir -p "$R/src/lib" "$R/src/ui"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/src/lib/pay.ts"; echo b > "$R/src/ui/card.tsx"
git -C "$R" add -A; git -C "$R" commit -qm one
BASE0=$(git -C "$R" rev-parse main)

PD="$T/plans/proj-AB-1"; mkdir -p "$PD"
printf '## Scope\nTouch src/lib/pay.ts and nothing else.\nSIZE: S\n' > "$PD/plan.md"
preplan_record "$PD" "$R" main
[ "$(cat "$PD/base-sha")" = "$BASE0" ] && ok || bad "preplan_record must pin the base sha"
grep -qx 'src/lib/pay.ts' "$PD/planned-files.txt" && ok || bad "preplan_record must extract the planned files"

preplan_check "$PD" "$R" main >/dev/null && ok || bad "an unmoved base must be FRESH"

echo c >> "$R/src/ui/card.tsx"; git -C "$R" add -A; git -C "$R" commit -qm two
preplan_check "$PD" "$R" main >/dev/null && ok \
  || bad "main moving OUTSIDE the planned files must not make a pre-plan stale"

echo d >> "$R/src/lib/pay.ts"; git -C "$R" add -A; git -C "$R" commit -qm three
OUT=$(preplan_check "$PD" "$R" main); RC=$?
[ "$RC" -eq 1 ] && ok || bad "main moving IN a planned file must be STALE (rc=$RC)"
grep -q 'src/lib/pay.ts' <<<"$OUT" && ok || bad "the stale reason must name the file (got: $OUT)"

rm -f "$PD/base-sha"; preplan_check "$PD" "$R" main >/dev/null; RC=$?
[ "$RC" -eq 2 ] && ok || bad "no base sha must be UNVERIFIABLE (rc 2), never fresh (rc=$RC)"
echo 0000000000000000000000000000000000000000 > "$PD/base-sha"
preplan_check "$PD" "$R" main >/dev/null; RC=$?
[ "$RC" -eq 2 ] && ok || bad "an unreachable base sha must be UNVERIFIABLE, never fresh (rc=$RC)"
printf '%s\n' "$BASE0" > "$PD/base-sha"; : > "$PD/planned-files.txt"
preplan_check "$PD" "$R" main >/dev/null; RC=$?
[ "$RC" -eq 2 ] && ok || bad "no planned-files list must be UNVERIFIABLE, never fresh (rc=$RC)"

echo 'src/lib' > "$PD/planned-files.txt"
preplan_check "$PD" "$R" main >/dev/null; RC=$?
[ "$RC" -eq 1 ] && ok || bad "a directory scope must go stale when a file under it moves (rc=$RC)"

# ---------- 4. preplan_find, and the reused-machine guard -------------------
unset PREPLAN_RELAY_DIR
[ "$(preplan_find "$T" proj AB-1)" = "$PD" ] && ok || bad "the hub dir must be found"
preplan_find "$T" proj AB-9 >/dev/null && bad "a key with no plan must rc 1" || ok

RELAY="$T/relay"; mkdir -p "$RELAY"; export PREPLAN_RELAY_DIR="$RELAY"
cp "$PD/plan.md" "$RELAY/plan.md"
[ "$(preplan_find "$T" proj AB-1)" = "$PD" ] && ok \
  || bad "a relay dir with NO key file must be ignored (a half-pushed pre-plan)"
echo AB-2 > "$RELAY/key"
[ "$(preplan_find "$T" proj AB-1)" = "$PD" ] && ok \
  || bad "a relay dir for ANOTHER key must be ignored — a pool machine is reused between jobs"
echo AB-1 > "$RELAY/key"
[ "$(preplan_find "$T" proj AB-1)" = "$RELAY" ] && ok \
  || bad "a matching relay dir must WIN — a fly builder has no hub plans/ dir"
unset PREPLAN_RELAY_DIR

# ---------- 5. the lock census (what the parallel cap counts) ---------------
preplan_held "$T/locks/nope.lock" && bad "a missing lock file is not held" || ok
: > "$T/locks/preplan-proj-AB-1.lock"
preplan_held "$T/locks/preplan-proj-AB-1.lock" && bad "a free lock must not read as held" || ok
flock "$T/locks/preplan-proj-AB-1.lock" sleep 4 & HOLDER=$!
wait_holder "$HOLDER"
preplan_held "$T/locks/preplan-proj-AB-1.lock" && ok || bad "a HELD lock must read as held"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -f "$T/locks/preplan-proj-AB-1.lock"

# ---------- 6. candidate selection, GitHub-Issues lane ----------------------
# TEST-CHANGE (BH-782): the lane's two GitHub reads go through the REST
# contract now (`gh api -i`), so the shim peels the flags, answers a status line
# + blank line + body, and the fixtures below carry the REST field names
# (lowercase `state`, `head.ref`, `labels` as objects). GH_FAIL=1 is a real 403,
# which is the case the lane must now answer with no candidates rather than
# with an empty list.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
INC=0; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) INC=1; shift ;;
    -X|-f|-F|-H) shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
ST=200; BODY=""
if [ "${GH_FAIL:-}" = 1 ]; then ST=403; BODY='{"message":"forbidden"}'; fi
if [ "$ST" = 200 ]; then
  case "$P" in
    */issues*) BODY=$(cat "$HARNESS/issues.json" 2>/dev/null || echo '[]') ;;
    */pulls*)  BODY=$(cat "$HARNESS/prs.json" 2>/dev/null || echo '[]') ;;
    *) exit 1 ;;
  esac
fi
[ "$INC" = 1 ] && printf 'HTTP/2.0 %s\r\n\r\n' "$ST"
[ -n "$BODY" ] && printf '%s\n' "$BODY"
case "$ST" in 2*) exit 0 ;; *) exit 1 ;; esac
SH
chmod +x "$T/bin/gh"
cat > "$T/issues.json" <<'JSON'
[
 {"number":10,"state":"CLOSED","title":"parent merged","body":""},
 {"number":11,"state":"OPEN","title":"parent with an open PR","body":""},
 {"number":12,"state":"OPEN","title":"parent nobody started","body":""},
 {"number":20,"state":"OPEN","title":"child of a merged parent","body":"Blocked-by: #10"},
 {"number":21,"state":"OPEN","title":"child of an open-PR parent","body":"Blocked-by: #11"},
 {"number":22,"state":"OPEN","title":"child of a not-started parent","body":"Blocked-by: #12"},
 {"number":30,"state":"OPEN","title":"untouched ready one","body":"no blockers here"},
 {"number":31,"state":"OPEN","title":"untouched ready two","body":""},
 {"number":40,"state":"CLOSED","title":"already done","body":""}
]
JSON
echo '[{"number":99,"title":"fix #11 parent","head":{"ref":"ticket/pr-11","sha":"s99"},"body":"","state":"open","merged_at":null,"user":{"login":"operator","type":"User"}}]' > "$T/prs.json"

CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -qP '^AB-20\t20\tchild$' <<<"$CAND" && ok || bad "a child of a CLOSED parent must be a candidate (got: $CAND)"
grep -qP '^AB-21\t21\tchild$' <<<"$CAND" && ok || bad "a child of an OPEN-PR parent must be a candidate (got: $CAND)"
# W2-G: a child of a not-started parent IS planned now, as the `blocked` class.
# Not because the plan is trusted against an unknown parent, but because the
# plan's own file list is the evidence bin/dep-verify.sh reads to decide whether
# that Blocked-by line is a real code dependency at all — and evidence that does
# not exist by the time the question is asked is a verdict of UNKNOWN, which is
# obeyed exactly like a hard blocker.
grep -qP '^AB-22\t22\tblocked$' <<<"$CAND" && ok || bad "a child of a not-started parent must ride as 'blocked' (got: $CAND)"
[ "$(DEP_VERIFY=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c blocked)" = 0 ] && ok   || bad "DEP_VERIFY=0 must remove the blocked class entirely"
touch "$T/flags/dep-verify-off"
[ "$("$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c blocked)" = 0 ] && ok   || bad "flags/dep-verify-off must remove the blocked class entirely"
rm -f "$T/flags/dep-verify-off"
# it is LAST: the most speculative class is the first one the cap drops
[ "$(sed -n '$p' <<<"$CAND" | cut -f3)" = blocked ] && ok   || bad "'blocked' must sort below every other class (got: $CAND)"
grep -q '^AB-11' <<<"$CAND" && bad "an issue a PR already carries must NOT be planned (got: $CAND)" || ok
grep -q '^AB-40' <<<"$CAND" && bad "a CLOSED issue must NOT be planned (got: $CAND)" || ok
grep -q '^AB-10' <<<"$CAND" && bad "a CLOSED parent must NOT be planned (got: $CAND)" || ok
# children rank above the ahead class: when the cap bites, the ticket that
# becomes buildable soonest must be the one that gets the session.
[ "$(sed -n 1p <<<"$CAND" | cut -f3)" = child ] && [ "$(sed -n 2p <<<"$CAND" | cut -f3)" = child ] \
  && ok || bad "children must sort above 'ahead' (got: $CAND)"
# THE `ahead` BOUND NOW HAS TWO SETTINGS (BH-475). With bin/overlap-schedule.sh
# on — the default — the ready class is deliberately unbounded here, because a
# graph over 2 of 30 ready tickets cannot say which ones are independent; the
# per-tick SPEND stays capped by PREPLAN_PARALLEL, which section 8 drives. So
# the PREPLAN_AHEAD assertions run with the scheduler off, which is the setting
# they were written for, and the default gets its own assertion below.
CAND2=$(OVERLAP_SCHEDULE=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -qP '^AB-12\t12\tahead$' <<<"$CAND2" && ok || bad "the first untouched ready ticket must ride (got: $CAND2)"
grep -qP '^AB-30\t30\tahead$' <<<"$CAND2" && ok || bad "the second untouched ready ticket must ride (got: $CAND2)"
grep -q '^AB-31' <<<"$CAND2" && bad "OVERLAP_SCHEDULE=0 + PREPLAN_AHEAD=2 must stop at two ahead tickets (got: $CAND2)" || ok
[ "$(OVERLAP_SCHEDULE=0 PREPLAN_AHEAD=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c ahead)" = 0 ] && ok \
  || bad "PREPLAN_AHEAD=0 must disable the ahead class entirely"
[ "$(PREPLAN_AHEAD=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c blocked)" = 0 ] && ok \
  || bad "PREPLAN_AHEAD also bounds the blocked class, so 0 disables it too"
# ...and an explicitly set PREPLAN_AHEAD still bounds the ready class with the
# scheduler on (BH-475 review): a box that set 0 to control spend keeps getting
# what it asked for, schedule or no schedule.
[ "$(PREPLAN_AHEAD=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c ahead)" = 0 ] && ok \
  || bad "PREPLAN_AHEAD=0 must disable the ahead class with the scheduler on as well"
[ "$(PREPLAN_AHEAD=1 "$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c ahead)" = 1 ] && ok \
  || bad "an explicit PREPLAN_AHEAD still bounds the ready class with the scheduler on"
# default (scheduler on): the third ready ticket rides too, which is the whole
# point — the overlap graph needs the backlog, not the next two.
grep -qP '^AB-31\t31\tahead$' <<<"$CAND" && ok \
  || bad "with OVERLAP_SCHEDULE on (default) the ready backlog must not stop at PREPLAN_AHEAD (got: $CAND)"

# the READY-QUEUE lines stay at the head — 2026-07-23 behaviour keeps priority
printf 'AB-7 tkt-7 — something ready project=proj\n' > "$T/logs/READY-QUEUE.log"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-7\ttkt-7\tqueued')" ] && ok \
  || bad "queued lines must come FIRST (got: $(sed -n 1p <<<"$CAND"))"
: > "$T/logs/READY-QUEUE.log"

# no key prefix in the prompt -> no candidates, rather than a key nothing reads
mv "$T/prompts/proj.md" "$T/prompts/proj.md.off"
[ -z "$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)" ] && ok \
  || bad "an unresolvable KEY prefix must yield NO candidates"
mv "$T/prompts/proj.md.off" "$T/prompts/proj.md"

# a dead gh is silent and rc 0 — this is an optimisation, never a tick killer
OUT=$(GH_FAIL=1 "$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "a dead gh must be silent exit 0 (rc=$RC out=$OUT)"

# ---------- 7. candidate selection, in-app board lane -----------------------
cat > "$T/bin/internal-token-for.sh" <<'SH'
#!/bin/bash
echo tok
SH
chmod +x "$T/bin/internal-token-for.sh"
echo '[{"id":"b1"}]' > "$T/boards.json"
cat > "$T/tickets.json" <<'JSON'
[
 {"key":"TK-1","id":"i1","status":"done","title":"parent shipped","description":""},
 {"key":"TK-2","id":"i2","status":"todo","title":"parent not started","description":""},
 {"key":"TK-3","id":"i3","status":"todo","title":"child of a shipped parent","description":"Blocked-by: TK-1"},
 {"key":"TK-4","id":"i4","status":"todo","title":"child of a live parent","description":"Blocked-by: TK-2"},
 {"key":"TK-5","id":"i5","status":"todo","title":"waiting on the client","description":"","triageVerdict":"needs_clarification","waitingOn":"client"},
 {"key":"TK-6","id":"i6","status":"in_progress","title":"already building","description":""},
 {"key":"TK-7","id":"i7","status":"todo","title":"plain ready one","description":""},
 {"key":"TK-8","id":"i8","status":"todo","title":"plain ready two","description":""},
 {"key":"TK-9","id":"i9","status":"todo","title":"plain ready three","description":""}
]
JSON
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
for a in "$@"; do case "$a" in
  */boards)            cat "$HARNESS/boards.json"; exit 0 ;;
  */boards/b1/tickets) cat "$HARNESS/tickets.json"; exit 0 ;;
esac; done
exit 22
SH
chmod +x "$T/bin/curl"
CAND=$("$T/bin/preplan-candidates.sh" bproj 2>/dev/null)
grep -qP '^TK-3\ti3\tchild$' <<<"$CAND" && ok || bad "a board child whose parent is done must be a candidate (got: $CAND)"
# The blocked class is a GitHub-Issues one: bin/dep-verify.sh reads Blocked-by
# lines, which in-app boards do not have, so a blocked board child's plan would
# have no consumer and is not worth a session.
grep -q '^TK-4' <<<"$CAND" && bad "a board child whose parent is still todo must NOT be planned (got: $CAND)" || ok
grep -q '^TK-5' <<<"$CAND" && bad "needs_clarification + waitingOn=client must NEVER be pre-planned (an early engagement)" || ok
grep -q '^TK-6' <<<"$CAND" && bad "an in_progress ticket must NOT be pre-planned (got: $CAND)" || ok
grep -qP '^TK-2\ti2\tahead$' <<<"$CAND" && ok || bad "a plain ready board ticket must ride as 'ahead' (got: $CAND)"
[ "$(grep -c ahead <<<"$(OVERLAP_SCHEDULE=0 "$T/bin/preplan-candidates.sh" bproj 2>/dev/null)")" = 2 ] && ok \
  || bad "OVERLAP_SCHEDULE=0 + PREPLAN_AHEAD=2 must bound the board lane too (got: $CAND)"
[ "$(grep -c ahead <<<"$CAND")" -gt 2 ] && ok \
  || bad "with the scheduler on the board lane's ready class must not stop at PREPLAN_AHEAD (got: $CAND)"
[ "$(sed -n 1p <<<"$CAND" | cut -f3)" = child ] && ok || bad "the board lane must sort children first too (got: $CAND)"
rm -f "$T/bin/curl" "$T/bin/internal-token-for.sh"

# ---------- 8. the tick: cap, flag-off, staleness, no double launch ---------
# run-preplan.sh is a recorder so the tick can be driven with no model call.
cat > "$T/bin/run-preplan.sh" <<'SH'
#!/bin/bash
echo "$1 $2 $3" >> "$HARNESS/launched.txt"
SH
chmod +x "$T/bin/run-preplan.sh"
mkdir -p "$T/repos/proj"
( cd "$T/repos/proj" && git init -q -b main && git config user.email t@t && git config user.name t \
  && mkdir -p src/lib && echo x > src/lib/pay.ts && git add -A && git commit -qm base \
  && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1

: > "$T/launched.txt"
PREPLAN_PARALLEL=2 "$T/bin/preplan-tick.sh"; wait_for 10 nl_ge 2; sleep 0.5   # extra-launch window
N=$(grep -c . "$T/launched.txt")
[ "$N" = 2 ] && ok || bad "PREPLAN_PARALLEL=2 must launch exactly 2 pre-plans (got $N: $(cat "$T/launched.txt"))"
# and they are the CHILDREN, because those sort first
[ "$(cut -d' ' -f3 "$T/launched.txt" | sort | tr '\n' ' ')" = "AB-20 AB-21 " ] && ok \
  || bad "the cap must spend its slots on the children (got: $(cat "$T/launched.txt"))"

# a pre-plan already in flight eats a slot
: > "$T/launched.txt"; : > "$T/locks/preplan-proj-AB-20.lock"
flock "$T/locks/preplan-proj-AB-20.lock" sleep 4 & HOLDER=$!
wait_holder "$HOLDER"
PREPLAN_PARALLEL=2 "$T/bin/preplan-tick.sh"; wait_for 10 nl_ge 1; sleep 0.5   # extra-launch window
[ "$(grep -c . "$T/launched.txt")" = 1 ] && ok \
  || bad "a held pre-plan lock must consume one of the parallel slots (got: $(cat "$T/launched.txt"))"
# ...and the slot that is left goes to the NEXT key, never to a phantom relaunch
# of the one already running (04:42-04:46Z 09-14: the relaunch exits 0 on its
# flock, but the launch line and the slot were spent)
grep -q ' AB-20$' "$T/launched.txt" && bad "a key whose pre-plan lock is held must not be relaunched (got: $(cat "$T/launched.txt"))" || ok
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -f "$T/locks/preplan-proj-AB-20.lock"

# a key whose build-key flock is held is already building — never pre-planned
: > "$T/launched.txt"; : > "$T/locks/build-key-proj-AB-20.lock"
flock "$T/locks/build-key-proj-AB-20.lock" sleep 4 & HOLDER=$!
wait_holder "$HOLDER"
PREPLAN_PARALLEL=1 "$T/bin/preplan-tick.sh"; wait_for 10 nl_ge 1; sleep 0.5   # extra-launch window
[ "$(cut -d' ' -f3 "$T/launched.txt")" = "AB-21" ] && ok \
  || bad "a key already building must be skipped (got: $(cat "$T/launched.txt"))"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -f "$T/locks/build-key-proj-AB-20.lock"

# a key that already has a FRESH pre-plan is not re-planned
: > "$T/launched.txt"; mkdir -p "$T/plans/proj-AB-20"
printf 'plan\nsrc/lib/pay.ts\n' > "$T/plans/proj-AB-20/plan.md"
git -C "$T/repos/proj" rev-parse origin/main > "$T/plans/proj-AB-20/base-sha"
echo 'src/lib/pay.ts' > "$T/plans/proj-AB-20/planned-files.txt"
PREPLAN_PARALLEL=1 "$T/bin/preplan-tick.sh"; wait_for 10 nl_ge 1; sleep 0.5   # extra-launch window
[ "$(cut -d' ' -f3 "$T/launched.txt")" = "AB-21" ] && ok \
  || bad "a FRESH pre-plan must not be re-planned (got: $(cat "$T/launched.txt"))"

# ...but a STALE one is dropped, logged, and re-planned
: > "$T/launched.txt"; : > "$T/logs/preplan.log"
( cd "$T/repos/proj" && echo y >> src/lib/pay.ts && git add -A && git commit -qm moved \
  && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
PREPLAN_PARALLEL=1 "$T/bin/preplan-tick.sh"; wait_for 10 nl_ge 1; sleep 0.5   # extra-launch window
grep -q 'PREPLAN_STALE' "$T/logs/preplan.log" && ok || bad "a stale pre-plan must log PREPLAN_STALE"
[ ! -d "$T/plans/proj-AB-20" ] && ok || bad "a stale pre-plan directory must be dropped"
[ "$(cut -d' ' -f3 "$T/launched.txt")" = "AB-20" ] && ok \
  || bad "a stale pre-plan must be re-planned fresh (got: $(cat "$T/launched.txt"))"

# ---------- 9. flag off is 2026-07-23 behaviour, byte for byte --------------
# THE LEGACY PATH ASKS THE PROCESS TABLE, so the process table is the fixture.
# A real `pgrep -f 'bin/run-preplan.sh'` matches ANY process whose cmdline
# mentions the path — an agent session quoting it is enough — which is both why
# the assertion below needs a mock and why the speculative path counts flocks
# instead (bin/lib/preplan-lib.sh:preplan_held).
cat > "$T/bin/pgrep" <<'SH'
#!/bin/bash
PAT=""; SHOW=0
for a in "$@"; do
  case "$a" in -*) case "$a" in *a*) SHOW=1 ;; esac ;; *) PAT="$a" ;; esac
done
n=0
while IFS= read -r l; do
  [ -n "$l" ] || continue
  grep -qF -- "$PAT" <<<"$l" || continue
  n=$((n+1))
  if [ "$SHOW" = 1 ]; then echo "$((1000+n)) $l"; else echo "$((1000+n))"; fi
done < "$HARNESS/procs.txt"
[ "$n" -gt 0 ]
SH
chmod +x "$T/bin/pgrep"
: > "$T/procs.txt"

: > "$T/launched.txt"
PREPLAN_SPECULATIVE=0 "$T/bin/preplan-tick.sh"; sleep 0.5
[ ! -s "$T/launched.txt" ] && ok \
  || bad "flag off + no build running must launch NOTHING: $(cat "$T/launched.txt")"

# ...and with a build in flight it pre-plans exactly the next QUEUED ticket
echo '/root/harness/bin/run-build.sh proj x AB-9' > "$T/procs.txt"
printf 'AB-7 tkt-7 — ready project=proj\n' > "$T/logs/READY-QUEUE.log"
: > "$T/launched.txt"
PREPLAN_SPECULATIVE=0 "$T/bin/preplan-tick.sh"; wait_for 10 nl_ge 1; sleep 0.5   # extra-launch window
[ "$(grep -c . "$T/launched.txt")" = 1 ] && [ "$(cut -d' ' -f3 "$T/launched.txt")" = AB-7 ] && ok \
  || bad "legacy path must pre-plan exactly the next queued ticket (got: $(cat "$T/launched.txt"))"

# ...but a key the pre-plan ledger has already settled is not launched at all,
# and the reason is written ONCE (#1014 review). Before this the legacy tick
# spent its single pre-plan on a key the lane would immediately refuse, and
# PREPLAN_SKIP piled up in the log every two minutes forever.
printf 'AB-7 tkt-7 — ready project=proj\nAB-8 tkt-8 — ready project=proj\n' > "$T/logs/READY-QUEUE.log"
mkdir -p "$T/plans/proj-AB-7"
printf 'empty\n' > "$T/plans/proj-AB-7/outcome"
printf '1\n' > "$T/plans/proj-AB-7/attempts"
: > "$T/launched.txt"; : > "$T/logs/preplan.log"
PREPLAN_SPECULATIVE=0 "$T/bin/preplan-tick.sh"; wait_for 10 nl_ge 1; sleep 0.5   # extra-launch window
grep -q ' AB-7$' "$T/launched.txt" \
  && bad "a terminal key must not be launched by the legacy tick (got: $(cat "$T/launched.txt"))" || ok
[ "$(cut -d' ' -f3 "$T/launched.txt")" = AB-8 ] && ok \
  || bad "the legacy tick must spend its one slot on the next queue line (got: $(cat "$T/launched.txt"))"
[ "$(grep -c PREPLAN_SKIP "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "the legacy tick must say why it skipped (got: $(cat "$T/logs/preplan.log"))"
: > "$T/launched.txt"
PREPLAN_SPECULATIVE=0 "$T/bin/preplan-tick.sh"; sleep 0.5
[ "$(grep -c PREPLAN_SKIP "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "the reason is written ONCE, not every tick (got: $(grep -c PREPLAN_SKIP "$T/logs/preplan.log") lines)"
scratch_rm "$T/plans/proj-AB-7"
printf 'AB-7 tkt-7 — ready project=proj\n' > "$T/logs/READY-QUEUE.log"

# the legacy path never touches the speculative classes: the queue is the whole
# candidate list, and the ticket the running build is on is skipped
echo '/root/harness/bin/run-build.sh proj x AB-7' > "$T/procs.txt"
: > "$T/launched.txt"
PREPLAN_SPECULATIVE=0 "$T/bin/preplan-tick.sh"; sleep 0.5
[ ! -s "$T/launched.txt" ] && ok \
  || bad "legacy path must skip the key the running build is on (got: $(cat "$T/launched.txt"))"

# a pre-plan already running stands the legacy tick down entirely
echo '/root/harness/bin/run-build.sh proj x AB-9' > "$T/procs.txt"
echo '/root/harness/bin/run-preplan.sh proj tkt-7 AB-7' >> "$T/procs.txt"
: > "$T/launched.txt"
PREPLAN_SPECULATIVE=0 "$T/bin/preplan-tick.sh"; sleep 0.5
[ ! -s "$T/launched.txt" ] && ok \
  || bad "legacy path is ONE pre-plan at a time (got: $(cat "$T/launched.txt"))"
rm -f "$T/bin/pgrep"; : > "$T/logs/READY-QUEUE.log"

# ---------- 10. the consumers are wired, and the flag reaches them ----------
grep -q '>>> preplan adopt' "$RB_ALL" \
  && ok || bad "bin/run-build.sh must carry the preplan adopt block"
grep -q 'cp -f "$PP_DIR/plan.md" "$BUILD/plan.md"' "$RB_ALL" \
  && ok || bad "the adopt must land the plan where the PLAN checkpoint reads it"
grep -q 'cp -f "$PP_DIR/ticket-fp" "$BUILD/ticket-fp"' "$RB_ALL" \
  && ok || bad "the adopt must carry ticket-fp, or it deletes the thread-stability gate"
grep -q 'preplan_speculative "$HARNESS"' "$RB_ALL" \
  && ok || bad "the adopt must be behind the kill flag"
grep -q 'PREPLAN_STALE' "$RB_ALL" \
  && ok || bad "the adopt must log PREPLAN_STALE when it discards a plan"
python3 - "$RB_ALL" <<'PY' && ok || bad "the adopt must sit BEFORE the PLAN checkpoint, or it can never fire"
import sys
s = open(sys.argv[1]).read()
sys.exit(0 if s.index('>>> preplan adopt') < s.index('# Checkpoint: a valid non-BLOCKED plan') else 1)
PY
grep -q 'push_preplan' "$DIR/bin/fly-pool.sh" \
  && ok || bad "bin/fly-pool.sh must relay the pre-plan to the builder"
[ "$(grep -c 'push_preplan "$MID"' "$DIR/bin/fly-pool.sh")" = 2 ] \
  && ok || bad "both the SPAWN and the REUSE path must relay (a reused machine gets new work too)"
grep -q 'rm -rf /run/harness/preplan' "$DIR/bin/fly-pool.sh" \
  && ok || bad "a reused machine must have the previous job's relayed pre-plan cleared"
grep -q '/run/harness/preplan/key' "$DIR/bin/fly-pool.sh" \
  && ok || bad "the relay must write the key file the adopt guard checks"
grep -q 'preplan_record' "$DIR/bin/run-preplan.sh" \
  && ok || bad "bin/run-preplan.sh must record the base sha + planned files, or nothing can judge freshness"
grep -q 'PLANDIR/key' "$DIR/bin/run-preplan.sh" \
  && ok || bad "the pre-plan dir must name its key for the relay guard"
# One worktree PER KEY in speculative mode: two same-project pre-plans in one
# tick (project-1 TK-265 + TK-266) collided on the per-project path's index.lock.
grep -q 'WT="${REPOS_ROOT:-/root/repos}/.preplan-$PROJECT-$KEY"' "$DIR/bin/run-preplan.sh" \
  && ok || bad "speculative pre-plans must each get their own worktree (per key)"
grep -q 'worktree remove --force "$WT"' "$DIR/bin/run-preplan.sh" \
  && ok || bad "per-key worktrees must be removed when the pre-plan ends"
grep -q 'preplan_held "$HARNESS/locks/preplan-$P-$KEY.lock" && continue' "$DIR/bin/preplan-tick.sh" \
  && ok || bad "the tick must skip a key whose pre-plan is already running"
grep -q 'PLANDIR/ticket-fp' "$DIR/bin/run-preplan.sh" \
  && ok || bad "the pre-plan must record the thread fingerprint the adopt hands to the stale gate"

# The cost row is agent-call.sh's, with stage=preplan — ASSERTED, never
# duplicated: a second writer would double-count the spend in logs/cost.csv.
grep -q 'agent-call.sh" preplan ' "$DIR/bin/run-preplan.sh" \
  && ok || bad "a pre-plan must run through agent-call.sh with stage=preplan so logs/cost.csv shows the spend"
grep -q 'preplan' <<<"$(grep -m1 'r\["stage"\] in (' "$DIR/bin/cost-rollup.sh")" \
  && ok || bad "the nightly rollup must still count the preplan stage"

# ---------- 11. the MID-BUILD parent (2026-09-16) ---------------------------
# THE GAP. Until today a blocker counted as "clearing" only when it was CLOSED
# or when some open PR already claimed it — both facts about GitHub, and both
# LATE. A parent's build runs 45-70 minutes before its PR exists, and for that
# whole hour its children looked exactly like children of work nobody had
# started: they fell to the `blocked` class, which PREPLAN_AHEAD bounds and
# which sits last in the cap, so in a real wave most of them were never planned.
# That is precisely the hour bin/dep-verify.sh needs a child's planned-files
# list in, and a child with no plan is UNKNOWN, which every caller obeys like a
# hard blocker. So a sibling that shares no file with its parent waited out the
# parent's entire build for want of a read-only $1-2 plan.
#
# Driven, not grepped: the three signals are a directory, a flock and a ledger
# row, and a grep for "midbuild" passes just as happily on a version that calls
# every ticket on the board mid-build.
mkdir -p "$T/builds" "$T/locks"

# 1. A BUILD DIRECTORY WITH NO RESULT. RESULT is what bin/run-build.sh writes
#    when the pipeline ENDS, whatever the ending — so its absence is an event
#    and never a stopwatch (the operator, 2026-09-16: no rule may turn on elapsed time).
mkdir -p "$T/builds/proj-AB-12-202609160900"
[ "$(preplan_midbuild_keys "$T" proj)" = AB-12 ] && ok \
  || bad "a build dir with no RESULT is a build that has not ended (got: $(preplan_midbuild_keys "$T" proj))"
echo 'PR_CREATED x' > "$T/builds/proj-AB-12-202609160900/RESULT"
[ -z "$(preplan_midbuild_keys "$T" proj)" ] && ok \
  || bad "RESULT is the ending: a finished build must stop counting (got: $(preplan_midbuild_keys "$T" proj))"
# ...and the pool/fly spellings of the same directory count too, or a fly build
# is invisible to the box that is supposed to plan its children.
mkdir -p "$T/builds/pool-proj-AB-13-202609160901" "$T/builds/fly-proj-AB-14-202609160902"
OUT=$(preplan_midbuild_keys "$T" proj | tr '\n' ' ')
[ "$OUT" = "AB-13 AB-14 " ] && ok || bad "pool- and fly- build dirs must count as well (got: '$OUT')"
# another project's build dir is not this project's
mkdir -p "$T/builds/bproj-CD-99-202609160903"
grep -q CD-99 <<<"$(preplan_midbuild_keys "$T" proj)" \
  && bad "a build dir belonging to another project must not leak in" || ok
rm -rf "$T/builds/proj-AB-12-202609160900" "$T/builds/pool-proj-AB-13-202609160901" \
       "$T/builds/fly-proj-AB-14-202609160902" "$T/builds/bproj-CD-99-202609160903"

# 2. THE PER-TICKET BUILD LOCK, HELD. The same flock bin/run-build.sh takes for
#    dedupe, read the way preplan_held reads every other lock here — a file that
#    merely EXISTS is a finished build's leftover, not a running one.
touch "$T/locks/build-key-proj-AB-15.lock"
[ -z "$(preplan_midbuild_keys "$T" proj)" ] && ok \
  || bad "an unheld lock file is a leftover, not a running build (got: $(preplan_midbuild_keys "$T" proj))"
( exec 8>"$T/locks/build-key-proj-AB-15.lock"; flock -n 8 || exit 1
  [ "$(preplan_midbuild_keys "$T" proj)" = AB-15 ] && exit 0 || exit 1 ) \
  && ok || bad "a HELD build-key lock must read as mid-build"
rm -f "$T/locks/build-key-proj-AB-15.lock"

# 3. THE JOBS LEDGER — every other box. A fly builder has no directory and no
#    lock on this machine; its `running` row is the only place it is visible.
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
[ "$1" = stale ] || exit 0
[ "${JOBS_FAIL:-}" = 1 ] && exit 1
printf 'j1\tproj\tbuild\texecute\tbox-a\tAB-16\t30\t0\t0\t-\t1\n'
printf 'j2\tproj\ttriage\ttriage\tbox-a\tAB-17\t30\t0\t0\t-\t1\n'
printf 'j3\tother\tbuild\texecute\tbox-b\tAB-18\t30\t0\t0\t-\t1\n'
printf 'j4\tproj\tbuild\texecute\tbox-b\t-\t30\t0\t0\t-\t1\n'
SH
chmod +x "$T/bin/jobs-client.sh"
OUT=$(preplan_midbuild_keys "$T" proj | tr '\n' ' ')
[ "$OUT" = "AB-16 " ] && ok \
  || bad "only this project's BUILD rows with a real ticket may count (got: '$OUT')"
[ -z "$(JOBS_FAIL=1 preplan_midbuild_keys "$T" proj)" ] && ok \
  || bad "a ledger outage must drop that source silently, never fail the census"

# 4. AND IT RELEASES THE CHILD. #12 is the parent nobody had started in section
#    6 — it rode as `blocked`, at the bottom of the cap. With its build running
#    its child #22 is a `child-building` candidate instead, which is where the
#    hour bin/dep-verify.sh needs comes from.
mkdir -p "$T/builds/proj-AB-12-202609161000"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -qP '^AB-22\t22\tchild-building$' <<<"$CAND" && ok \
  || bad "a child whose parent is MID-BUILD must be a child candidate (got: $CAND)"
grep -qP '^AB-22\t22\tblocked$' <<<"$CAND" \
  && bad "and it must no longer be the speculative blocked class (got: $CAND)" || ok
# it ranks with the children and above `ahead`, because it becomes buildable
# when the parent's build ENDS — not when a triage tick gets round to it
[ "$(grep -n 'child-building' <<<"$CAND" | cut -d: -f1)" -lt "$(grep -n 'ahead' <<<"$CAND" | head -1 | cut -d: -f1)" ] \
  && ok || bad "child-building must sort above the ahead class (got: $CAND)"
# ...but BELOW a child whose parent already has a PR: a running build is the
# weaker of the two signals and the cap must drop it first.
[ "$(grep -n 'child-building' <<<"$CAND" | cut -d: -f1)" -gt "$(grep -cP '\tchild$' <<<"$CAND")" ] \
  && ok || bad "a parent with a PR is a stronger signal than a parent still building (got: $CAND)"
# the parent itself is mid-build, so nothing pre-plans it: its own build writes
# its own plan, and a pre-plan launched now would spend a session to lose a race
grep -q '^AB-12' <<<"$CAND" \
  && bad "a ticket whose own build is running must never be pre-planned (got: $CAND)" || ok

# THE KILL FLAG IS STILL DEP_VERIFY's, because this class exists to feed
# bin/dep-verify.sh: with it off, #22 goes back to not being planned at all.
[ "$(DEP_VERIFY=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c 'child-building')" = 1 ] && ok \
  || bad "child-building is a CHILD class, not the blocked one — DEP_VERIFY=0 must not remove it"
# an unreadable census is simply the old behaviour, never a dead tick
rm -f "$T/bin/jobs-client.sh"; rm -rf "$T/builds/proj-AB-12-202609161000"
OUT=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok || bad "no jobs-client at all must still exit 0 (rc=$RC)"
grep -qP '^AB-22\t22\tblocked$' <<<"$OUT" && ok \
  || bad "with no mid-build signal the child falls back to exactly what it was before (got: $OUT)"

# ---------- 12. the pre-plan attempt ledger: ok / empty / failed ------------
# A PRE-PLAN SESSION IS A BILLABLE MODEL CALL (BH-475 review). The
# "produced no plan.md" path in bin/run-preplan.sh deleted the directory and
# left nothing behind, so the next tick bought the same key again — every ~10
# minutes, for as long as it stayed in the ready set, with no cap and no
# terminal state. The fleet's metered rule is three outcomes, and the check runs
# BEFORE the call:
#   ok      plan.md written. The freshness dedup above already covers it.
#   empty   the session exited 0 and returned nothing. Billed. TERMINAL.
#   failed  the session died. Retried to PREPLAN_MAX_ATTEMPTS (3), then terminal.
# Driven against the REAL bin/run-preplan.sh with a stub agent-call.sh that
# counts its invocations, because "did we buy it again?" is the only question
# that matters here.
RP="$T/rp"
mkdir -p "$RP/bin/lib" "$RP/env" "$RP/flags" "$RP/logs" "$RP/plans" "$RP/locks" "$RP/repos/proj"
model_routes_fixture "$RP" proj || exit 1  # BH-1510.2: this root runs a converted lane too
cp "$DIR/bin/run-preplan.sh" "$RP/bin/"
cp "$DIR/bin/lib/preplan-lib.sh" "$RP/bin/lib/"
: > "$RP/env/global.env"
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt>
cat > "$RP/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo "$2 $1" >> "$HARNESS/calls.txt"
[ "${STUB_PLAN:-0}" = 1 ] && printf 'plan\ncode/x.ts\n' > "$(dirname "$5")/plan.md"
# The ONE thing that says a session really ran: agent-call.sh appends a row to
# logs/cost.csv for every attempt, and writes none for a refusal.
[ "${STUB_COST:-0}" = 1 ] && printf 'stamp,box,proj,preplan,runner,model,%s\n' "${STUB_RC:-0}" >> "$HARNESS/logs/cost.csv"
printf 'refusal or answer\n' > "$5"
exit "${STUB_RC:-0}"
STUB
cat > "$RP/bin/git" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$RP/bin/agent-call.sh" "$RP/bin/git"
lane() { # lane <KEY> — one real pre-plan run against the scratch tree
  ( export PATH="$RP/bin:$PATH" HARNESS="$RP" REPOS_ROOT="$RP/repos"
    bash "$RP/bin/run-preplan.sh" proj 1 "$1" >/dev/null 2>&1 )
}
calls() { grep -c . "$RP/calls.txt" 2>/dev/null || echo 0; }

# empty: one call, a terminal record, and never a second call.
: > "$RP/calls.txt"
STUB_RC=0 lane AB-1
[ "$(calls)" = 1 ] && ok || bad "the first pre-plan of a key must actually run (calls: $(calls))"
[ "$(cat "$RP/plans/proj-AB-1/outcome" 2>/dev/null)" = empty ] && ok \
  || bad "a session that exited 0 with no plan.md must record 'empty' (got: $(ls "$RP/plans/proj-AB-1" 2>/dev/null))"
STUB_RC=0 lane AB-1
[ "$(calls)" = 1 ] && ok \
  || bad "'empty' is billed and terminal — the key must never be bought again (calls: $(calls))"
# ...and no plan directory that anything downstream could adopt
[ ! -s "$RP/plans/proj-AB-1/plan.md" ] && ok || bad "a terminal record must never look like a pre-plan"

# failed: retried to the cap, then terminal.
: > "$RP/calls.txt"
for _i in 1 2 3 4 5; do STUB_RC=1 lane AB-2; done
[ "$(calls)" = 3 ] && ok \
  || bad "a failing pre-plan must stop at PREPLAN_MAX_ATTEMPTS=3, not retry forever (calls: $(calls))"
[ "$(cat "$RP/plans/proj-AB-2/outcome" 2>/dev/null)" = failed ] && ok \
  || bad "a dead session must record 'failed' (got: $(cat "$RP/plans/proj-AB-2/outcome" 2>/dev/null))"
[ "$(cat "$RP/plans/proj-AB-2/attempts" 2>/dev/null)" = 3 ] && ok \
  || bad "the attempt count must be persisted, or the cap cannot be enforced across ticks"

# A CALL THAT NEVER HAPPENED IS NOT A FAILED ATTEMPT (#1014 review 2).
# bin/agent-call.sh's own header reserves five exit codes for refusals taken
# BEFORE any model call: 75 (lock), 76 (no account of the vendor had headroom),
# 77 (the hub runs no agent build work), 78 (no-tools refusal) and 79 (an
# argv-only lane refused the prompt, or a grok call was cliff-routed). Nothing
# was called and nothing was billed, so counting them against the cap turns a
# six-minute account outage into a day with no pre-plans — the opposite of what
# a spend guard is for. They leave the ledger exactly as they found it.
for RCC in 75 76 77 78 79; do
  : > "$RP/calls.txt"
  ( export STUB_RC="$RCC"; lane "AB-rc$RCC"; lane "AB-rc$RCC"; lane "AB-rc$RCC" )
  [ "$(calls)" = 3 ] && ok \
    || bad "rc $RCC is not a spent session — all three attempts must still run (calls: $(calls))"
  [ ! -e "$RP/plans/proj-AB-rc$RCC/outcome" ] && [ ! -e "$RP/plans/proj-AB-rc$RCC/attempts" ] && ok \
    || bad "rc $RCC must write no attempt record (got: $(ls "$RP/plans/proj-AB-rc$RCC" 2>/dev/null))"
done
# ...and a key that already HAS history keeps it: a refusal must not wipe the
# ledger that was governing the key.
: > "$RP/calls.txt"
STUB_RC=1 lane AB-5
[ "$(cat "$RP/plans/proj-AB-5/attempts" 2>/dev/null)" = 1 ] && ok \
  || bad "fixture: the first real failure must count (got: $(cat "$RP/plans/proj-AB-5/attempts" 2>/dev/null))"
STUB_RC=76 lane AB-5
[ "$(cat "$RP/plans/proj-AB-5/attempts" 2>/dev/null)" = 1 ] && \
  [ "$(cat "$RP/plans/proj-AB-5/outcome" 2>/dev/null)" = failed ] && ok \
  || bad "a not-billed refusal must leave an existing record untouched (got: $(cat "$RP/plans/proj-AB-5/attempts" 2>/dev/null))"
# THE RC ALONE CANNOT ANSWER "WAS THIS BILLED" (#1073 review, carried here).
# bin/agent-call.sh exits with the LAST RUNG's rc (`exit "$RC"`, :2108), and the
# refusal codes are produced by particular rungs: 76 by the claude/codex account
# picker, 79 by the grok cliff route. So a billed claude session that dies (rc 1)
# and then descends to a codex rung with no headroom exits 76 — a session that
# ran, cost money, and would read as "nothing was called". Recording nothing for
# it is the runaway shape this whole PR exists to stop, one layer down.
#
# The evidence is the cost row: agent-call appends one per attempt that ran
# (:1644) and none for a refusal. So the record is skipped only when the rc is a
# refusal code AND logs/cost.csv did not grow.
: > "$RP/calls.txt"; : > "$RP/logs/cost.csv"
( export STUB_RC=76 STUB_COST=1; lane AB-b1 )
[ "$(cat "$RP/plans/proj-AB-b1/outcome" 2>/dev/null)" = failed ] && ok \
  || bad "a billed session that ends on a refusal rc must still record failed (got: $(cat "$RP/plans/proj-AB-b1/outcome" 2>/dev/null))"
[ "$(cat "$RP/plans/proj-AB-b1/attempts" 2>/dev/null)" = 1 ] && ok \
  || bad "a billed session must count against the cap whatever rc the ladder ended on"
# ...and the same rc with no cost row is still a refusal nobody paid for
( export STUB_RC=76; lane AB-b2 )
[ ! -e "$RP/plans/proj-AB-b2/outcome" ] && [ ! -e "$RP/plans/proj-AB-b2/attempts" ] && ok \
  || bad "rc 76 with no cost row must still write no record (got: $(ls "$RP/plans/proj-AB-b2" 2>/dev/null))"
# ...and an outage says so ONCE per key, not once per tick, and leaves no
# half-written plan output behind.
: > "$RP/logs/preplan.log"
( export STUB_RC=76; lane AB-b3; lane AB-b3; lane AB-b3 )
[ "$(grep -c 'refused before billing' "$RP/logs/preplan.log")" = 1 ] && ok \
  || bad "the refusal must be logged once per key (got: $(grep -c 'refused before billing' "$RP/logs/preplan.log") lines)"
[ ! -e "$RP/plans/proj-AB-b3/plan-run.txt" ] && ok \
  || bad "a refusal must not leave its agent output behind"

# ...while a REAL non-zero exit still counts, so the cap still bites.
: > "$RP/calls.txt"
for _i in 1 2 3 4; do STUB_RC=2 lane AB-rc2; done
[ "$(calls)" = 3 ] && ok || bad "an ordinary non-zero exit must still hit the cap (calls: $(calls))"
[ "$(cat "$RP/plans/proj-AB-rc2/outcome" 2>/dev/null)" = failed ] && ok \
  || bad "an ordinary non-zero exit must still record failed (got: $(cat "$RP/plans/proj-AB-rc2/outcome" 2>/dev/null))"

# the cap is a knob, resolved like every other PREPLAN_* one
: > "$RP/calls.txt"
( export PREPLAN_MAX_ATTEMPTS=1; STUB_RC=1 lane AB-3; STUB_RC=1 lane AB-3 )
[ "$(calls)" = 1 ] && ok || bad "PREPLAN_MAX_ATTEMPTS=1 must make one failure terminal (calls: $(calls))"
printf 'PREPLAN_MAX_ATTEMPTS=1\n' > "$RP/env/global.env"
: > "$RP/calls.txt"
STUB_RC=1 lane AB-6; STUB_RC=1 lane AB-6
[ "$(calls)" = 1 ] && ok || bad "PREPLAN_MAX_ATTEMPTS in env/global.env must bound it too (calls: $(calls))"
: > "$RP/env/global.env"

# ok: a plan clears the record, and the key is buyable again afterwards
: > "$RP/calls.txt"
STUB_RC=1 lane AB-4
[ "$(cat "$RP/plans/proj-AB-4/attempts" 2>/dev/null)" = 1 ] && ok \
  || bad "the first failure must count (got: $(cat "$RP/plans/proj-AB-4/attempts" 2>/dev/null))"
( export STUB_PLAN=1 STUB_RC=0; lane AB-4 )
[ -s "$RP/plans/proj-AB-4/plan.md" ] && ok || bad "a successful pre-plan must still write plan.md"
[ ! -e "$RP/plans/proj-AB-4/outcome" ] && [ ! -e "$RP/plans/proj-AB-4/attempts" ] && ok \
  || bad "a successful pre-plan must clear the attempt record — the next failure starts from zero"
[ "$(calls)" = 2 ] && ok || bad "the ok path must not be blocked by the ledger (calls: $(calls))"

# ---------- 12b. the tick and the classifier honour the terminal record -----
# The lane's own guard is the one that saves the money; these two save the SLOT
# (PREPLAN_PARALLEL) and the ready-class budget, and say why in the log.
: > "$T/launched.txt"; : > "$T/logs/preplan.log"
mkdir -p "$T/plans/proj-AB-20"
printf 'empty\n' > "$T/plans/proj-AB-20/outcome"
printf '1\n' > "$T/plans/proj-AB-20/attempts"
PREPLAN_PARALLEL=1 "$T/bin/preplan-tick.sh"; sleep 0.5
grep -q ' AB-20$' "$T/launched.txt" \
  && bad "a terminal key must not be relaunched by the tick (got: $(cat "$T/launched.txt"))" || ok
grep -q 'PREPLAN_SKIP' "$T/logs/preplan.log" && ok \
  || bad "the tick must say WHY it skipped, where its other reasons already are (got: $(cat "$T/logs/preplan.log"))"
[ "$(cut -d' ' -f3 "$T/launched.txt")" = "AB-21" ] && ok \
  || bad "the freed slot must go to the next key (got: $(cat "$T/launched.txt"))"
scratch_rm "$T/plans/proj-AB-20"

# and the classifier drops a terminal SPECULATIVE row, so it stops eating one of
# the PREPLAN_AHEAD_READY slots for the next 24h. A `child` row stays: the
# overlap schedule needs it as a candidate, and the tick's guard above is what
# keeps it from costing anything.
mkdir -p "$T/plans/proj-AB-31" "$T/plans/proj-AB-20"
printf 'empty\n' > "$T/plans/proj-AB-31/outcome"
printf 'failed\n' > "$T/plans/proj-AB-20/outcome"
printf '3\n' > "$T/plans/proj-AB-20/attempts"
CANDT=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q '^AB-31' <<<"$CANDT" \
  && bad "a terminal ahead key must not spend a ready-class slot (got: $CANDT)" || ok
grep -q '^AB-20' <<<"$CANDT" && ok \
  || bad "a terminal CHILD must stay a candidate — the overlap schedule needs it (got: $CANDT)"
scratch_rm "$T/plans/proj-AB-31"; scratch_rm "$T/plans/proj-AB-20"

echo "preplan-speculative: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
