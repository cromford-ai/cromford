#!/bin/bash
# tests/execute-empty.bh-5911-test.sh — BH-5911: an EXECUTE_EMPTY build keeps
# its transcript, says why it stopped, and the pool stops relaunching a key
# that ended empty twice in 24 h.
#
# THE INCIDENT (project-6-os, 2026-10-10). TK-16 ran 5 times and TK-17/18/19
# 2-3 times each, every run EXECUTE_EMPTY after 64-90 s of execute, about
# $0.6 each. No transcript reached the build record, the RESULT line said only
# "no changes produced", and reconcile relaunched the keys every ~30 min.
#
# Driven, not grepped, for the behavior:
#   A  the REAL `# >>> execute result` block of bin/lib/rb/execute.sh, run with
#      the REAL bin/lib/execute-empty.sh, bin/transcript-render.sh and
#      bin/transcript-scrub.sh, on an empty branch:
#      A1 a claude session on disk: $BUILD/execute-transcript.md holds the
#         rendered session (scrubbed), $BUILD/stop-reason.txt holds the final
#         message (the envelope's .result, first 200 chars, scrubbed), and the
#         RESULT line is the old fixed text.
#      A2 no session file: the transcript is the stage output, said so.
#      A3 a 300-line stage output: the transcript keeps the last 200 lines,
#         and the reason is taken from the END of the output.
#      A4 no final message: no stop-reason.txt, the old RESULT line.
#      A5 (lead review of #5939) a final message that quotes RUNNER_EXHAUSTED,
#         resets_at= and a pull URL: none of it reaches the RESULT file, so
#         the readers that match RESULT line 1 by substring (bin/fly-pool.sh's
#         account cooldown, bin/postmerge-qa.sh's and bin/deploy-train.sh's
#         first pull URL) have nothing to act on.
#   B  ee_stop_check, the pool's spawn gate, over hub build dirs:
#      B1 one EXECUTE_EMPTY in 24 h: allowed.
#      B2 two in 24 h: refused, one NEEDS_HUMAN hold (bin/needs-human-hold.sh)
#         whose action names the last stop reason, and needs-human.md written.
#      B3 the next tick: refused again, no second hold.
#      B4 one of the two older than the window: allowed.
#      B5 the knobs: MAX=0 is off; MAX=3 allows two.
#      B6 the hold could not be placed: still refused, retried next tick.
#      B7 an in-app board: the ask is a comment through the board adapter
#         (bin/lib/tracker.sh), posted once.
#   C  the wiring: pool_spawn_decision runs the gate before the spawn cap;
#      both relays carry execute-transcript.md; the knobs are registered.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/execute-empty.bh-5911-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/execute-empty.sh"
[ -f "$LIB" ] && ok || bad "missing bin/lib/execute-empty.sh"

# ═════ A: the execute result block ══════════════════════════════════════════
awk 'index($0,"# >>> execute result")==1{f=1;next} index($0,"# <<< execute result")==1{exit} f' \
  "$DIR/bin/lib/rb/execute.sh" > "$T/exec.sh"
[ -s "$T/exec.sh" ] && ok || bad "could not extract the execute result block"

# A token SHAPE built at run time, so no credential-shaped literal sits in this
# file (the share-mirror leakcheck refuses one).
TOKEN="ghp_$(printf 'Q%.0s' $(seq 36))"
mkdir -p "$T/envdir"; : > "$T/envdir/global.env"
# EXEC <build-dir> -> "<rc> <RESULT>"
EXEC() {
  ( set -uo pipefail
    PROJECT=project-6-os; KEY=TK-16; BASE=main; BRANCH=ticket/TK-16; BUILD="$1"
    HARNESS="$DIR" CLAUDE_PROJECTS_DIR="$T/projects" HARNESS_ENV_DIR="$T/envdir" ETC_HARNESS_ENV="$T/envdir"
    export HARNESS CLAUDE_PROJECTS_DIR HARNESS_ENV_DIR ETC_HARNESS_ENV
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    STAGE_LANE_DEFER() { :; }
    CKPT_STOP() { :; }; CKPT_NONWIP_COUNT() { echo 0; }; CKPT_WIP_COUNT() { echo 0; }
    git() { return 0; }   # `git diff --quiet BASE...HEAD`: the branch is empty
    # shellcheck disable=SC1090
    . "$T/exec.sh" ) >/dev/null 2>&1
  echo "$? $(head -1 "$1/RESULT" 2>/dev/null)"
}
FINAL="I stopped: the snapshot branch origin/snap-1 does not exist on the remote, so there is nothing to build from. Token seen: $TOKEN"

# A1: a session on disk
B1="$T/b1"; mkdir -p "$B1" "$T/projects/-data-repo"
printf '%s\n' "$FINAL" > "$B1/execute-run.txt"
jq -nc --arg r "$FINAL" '{session_id:"sess-5911", result:$r}' > "$B1/execute-run.txt.json"
{
  printf '{"type":"user","timestamp":"2026-10-10T10:00:00.000Z","message":{"role":"user","content":"Execute the plan"}}\n'
  printf '{"type":"assistant","timestamp":"2026-10-10T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Looking for the snapshot branch before editing. export GH_TOKEN=%s"}]}}\n' "$TOKEN"
  printf '{"type":"assistant","timestamp":"2026-10-10T10:01:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"The branch is missing; stopping."}]}}\n'
} > "$T/projects/-data-repo/sess-5911.jsonl"
OUT=$(EXEC "$B1")
[ "$OUT" = "5 EXECUTE_EMPTY no changes produced" ] && ok || bad "A1 the RESULT line must stay the fixed text (got: $OUT)"
grep -q "^I stopped: the snapshot branch origin/snap-1 does not exist" "$B1/stop-reason.txt" 2>/dev/null \
  && ok || bad "A1 stop-reason.txt must hold the final message: $(cat "$B1/stop-reason.txt" 2>/dev/null)"
R1R=$(head -1 "$B1/stop-reason.txt" 2>/dev/null)
[ "${#R1R}" -le 200 ] && ok || bad "A1 the reason is cut at 200 chars (got ${#R1R})"
grep -q "$TOKEN" "$B1/stop-reason.txt" 2>/dev/null && bad "A1 stop-reason.txt leaked a token" || ok
grep -q "^stop reason: I stopped: the snapshot branch" "$B1/execute-transcript.md" 2>/dev/null && ok || bad "A1 the transcript must show the stop reason at the top"
[ -s "$B1/execute-transcript.md" ] && ok || bad "A1 no execute-transcript.md in the build record"
grep -q "Looking for the snapshot branch" "$B1/execute-transcript.md" 2>/dev/null && ok || bad "A1 the transcript is not the rendered session: $(head -5 "$B1/execute-transcript.md" 2>/dev/null)"
grep -q "source: session_jsonl" "$B1/execute-transcript.md" 2>/dev/null && ok || bad "A1 the header must say source: session_jsonl"
grep -q "$TOKEN" "$B1/execute-transcript.md" 2>/dev/null && bad "A1 the transcript leaked a token" || ok
grep -q "REDACTED" "$B1/execute-transcript.md" 2>/dev/null && ok || bad "A1 the scrubber did not run on the transcript"

# A2: no session file -> the stage output
B2="$T/b2"; mkdir -p "$B2"
printf '%s\n' "$FINAL" > "$B2/execute-run.txt"
OUT=$(EXEC "$B2")
[ "$OUT" = "5 EXECUTE_EMPTY no changes produced" ] && ok || bad "A2 RESULT (got: $OUT)"
[ -s "$B2/stop-reason.txt" ] && ok || bad "A2 no stop-reason.txt from the stage output"
grep -q "source: stage_output" "$B2/execute-transcript.md" 2>/dev/null && ok || bad "A2 the header must say source: stage_output"
grep -q "snapshot branch origin/snap-1" "$B2/execute-transcript.md" 2>/dev/null && ok || bad "A2 the stage output is not in the transcript"

# A3: a long stage output keeps the last 200 lines
B3="$T/b3"; mkdir -p "$B3"
for i in $(seq 1 300); do echo "line-$i"; done > "$B3/execute-run.txt"
OUT=$(EXEC "$B3")
grep -q '^line-300$' "$B3/execute-transcript.md" 2>/dev/null && ok || bad "A3 the last line is missing"
grep -q '^line-100$' "$B3/execute-transcript.md" 2>/dev/null && bad "A3 more than the last 200 lines were kept" || ok
grep -q '^line-101$' "$B3/execute-transcript.md" 2>/dev/null && ok || bad "A3 line 101 (the 200th from the end) is missing"
grep -q '^line-291 line-292' "$B3/stop-reason.txt" 2>/dev/null && ok || bad "A3 the reason must come from the end of the output: $(cat "$B3/stop-reason.txt" 2>/dev/null)"

# A4: no final message -> the old RESULT line
B4="$T/b4"; mkdir -p "$B4"
OUT=$(EXEC "$B4")
[ "$OUT" = "5 EXECUTE_EMPTY no changes produced" ] && ok || bad "A4 with no final message the RESULT line must be unchanged (got: $OUT)"
[ ! -e "$B4/stop-reason.txt" ] && ok || bad "A4 no final message must write no stop-reason.txt"

# A5: hostile words in the final message never reach RESULT
B5="$T/b5"; mkdir -p "$B5"
HOSTILE="I stopped: the plan's RUNNER_EXHAUSTED class=auth seen=account-exhausted exhausted=claude resets_at=1791700000 arm is already on main in https://github.com/example-org/cromford/pull/803"
printf '%s\n' "$HOSTILE" > "$B5/execute-run.txt"
jq -nc --arg r "$HOSTILE" '{result:$r}' > "$B5/execute-run.txt.json"
OUT=$(EXEC "$B5")
[ "$OUT" = "5 EXECUTE_EMPTY no changes produced" ] && ok || bad "A5 RESULT line 1 must stay the fixed text (got: $OUT)"
grep -qE 'RUNNER_EXHAUSTED|account-exhausted|resets_at=' "$B5/RESULT" 2>/dev/null && bad "A5 an exhaustion token reached RESULT: $(cat "$B5/RESULT")" || ok
grep -qE 'https://github\.com/[^ ]+/pull/[0-9]+' "$B5/RESULT" 2>/dev/null && bad "A5 a pull URL reached RESULT: $(cat "$B5/RESULT")" || ok
# The exact match bin/fly-pool.sh runs on the reaped line (its RUNNER_EXHAUSTED arm).
RL=$(head -1 "$B5/RESULT")
case "$RL" in *RUNNER_EXHAUSTED*|*seen=*account-exhausted*) bad "A5 fly-pool's cooldown arm would fire on: $RL" ;; *) ok ;; esac
grep -q 'RUNNER_EXHAUSTED' "$B5/stop-reason.txt" 2>/dev/null && ok || bad "A5 the reason is kept in stop-reason.txt, where no RESULT reader looks"

# ═════ B: the pool's stop gate ══════════════════════════════════════════════
H="$T/h"; mkdir -p "$H/bin" "$H/builds" "$H/state/pool/mk" "$H/logs"
cat > "$H/bin/needs-human-hold.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOLDLOG"
exit "$(cat "$HOLDRC" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTLOG"
exit 0
SH
chmod +x "$H/bin/needs-human-hold.sh" "$H/bin/alert-line.sh"
NOW=1791640000
# empty_dir <name> <age-seconds> [reason]
empty_dir() {
  mkdir -p "$H/builds/$1"
  printf 'EXECUTE_EMPTY no changes produced\n' > "$H/builds/$1/RESULT"
  printf '%s\n' "${3:-the branch is missing}" > "$H/builds/$1/stop-reason.txt"
  touch -d "@$((NOW - $2))" "$H/builds/$1/RESULT"
}
reset_b() {
  for d in "$H"/builds/*/; do [ -d "$d" ] && scratch_rm "${d%/}"; done
  rm -f "$H"/state/pool/mk/* "$T/hold.log" "$T/alert.log" "$T/hold.rc"
}
GATE() { # GATE [VAR=value ...] -> rc of ee_stop_check mk TK-16 4242 (a GitHub-Issues board)
  ( for kv in "$@"; do export "${kv?}"; done
    export HARNESS="$H" EE_NOW="${EE_NOW_T:-$NOW}" HOLDLOG="$T/hold.log" HOLDRC="$T/hold.rc" ALERTLOG="$T/alert.log"
    say() { :; }
    # BH-7919: the GitHub arms resolve the issue through trk_gh_issue_number,
    # so the tracker lib is loaded before its adapter answer is stubbed.
    # shellcheck disable=SC1090
    . "$DIR/bin/lib/tracker.sh"
    tracker_adapter() { echo github-issues; }
    # bin/lib/hold.sh's reading of the ticket, stubbed: $T/holdv is its verdict line.
    hold_check() { local v; v=$(cat "$T/holdv" 2>/dev/null); printf '%s\n' "$v"
      case "$v" in clear*) return 0 ;; held*) return 1 ;; esac; return 2; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 9
    ee_stop_check mk TK-16 4242 )
}
holds() { local c; c=$(grep -c . "$T/hold.log" 2>/dev/null); echo "${c:-0}"; }

reset_b; empty_dir pool-mk-TK-16-202610101000 3600
GATE; [ $? = 0 ] && ok || bad "B1 one EXECUTE_EMPTY in the window must be allowed"
[ "$(holds)" = 0 ] && ok || bad "B1 no hold expected"

reset_b; empty_dir pool-mk-TK-16-202610100900 7200 "first reason"
empty_dir pool-mk-TK-16-202610101000 600 "the snapshot branch is missing"
empty_dir pool-mk-TK-17-202610101000 600 "another key"
GATE; [ $? = 1 ] && ok || bad "B2 two EXECUTE_EMPTY in 24 h must refuse the relaunch"
[ "$(holds)" = 1 ] && ok || bad "B2 want exactly one NEEDS_HUMAN hold, got $(holds)"
HL=$(head -1 "$T/hold.log" 2>/dev/null)
[[ "$HL" == "mk 4242 "* ]] && ok || bad "B2 the hold names project mk and issue 4242: $HL"
grep -q "Last stop reason: the snapshot branch is missing" <<<"$HL" && ok || bad "B2 the hold action must name the newest stop reason: $HL"
[[ "$HL" == *" execute-empty" ]] && ok || bad "B2 the hold source must be execute-empty: $HL"
grep -q "NEEDS_HUMAN" "$H/builds/pool-mk-TK-16-202610101000/needs-human.md" 2>/dev/null && ok || bad "B2 no needs-human.md in the newest build record"
grep -q "execute-transcript.md" "$H/builds/pool-mk-TK-16-202610101000/needs-human.md" 2>/dev/null && ok || bad "B2 the body must point at execute-transcript.md"

[ -e "$H/builds/pool-mk-TK-16-202610101000/needs-human.posted" ] && ok || bad "B2 the episode marker belongs in the newest build record"
[ -z "$(ls -A "$H/state/pool/mk" 2>/dev/null)" ] && ok || bad "B2 the gate wrote under state/pool, the pool_state rows' path: $(ls -A "$H/state/pool/mk")"
GATE; [ $? = 1 ] && ok || bad "B3 the next tick must still refuse"
[ "$(holds)" = 1 ] && ok || bad "B3 a second hold was posted ($(holds))"

reset_b; empty_dir pool-mk-TK-16-202610090900 90000
empty_dir pool-mk-TK-16-202610101000 600
GATE; [ $? = 0 ] && ok || bad "B4 an EXECUTE_EMPTY older than 24 h must not count"
GATE POOL_EXECUTE_EMPTY_WINDOW_S=100000; [ $? = 1 ] && ok || bad "B4 a wider window (the settings row) must count it"

reset_b; empty_dir pool-mk-TK-16-202610100900 7200; empty_dir pool-mk-TK-16-202610101000 600
GATE POOL_EXECUTE_EMPTY_MAX=0; [ $? = 0 ] && ok || bad "B5 MAX=0 is off"
GATE POOL_EXECUTE_EMPTY_MAX=3; [ $? = 0 ] && ok || bad "B5 MAX=3 allows two"
GATE POOL_EXECUTE_EMPTY_MAX=junk; [ $? = 1 ] && ok || bad "B5 a junk MAX falls back to the default 2"

reset_b; empty_dir pool-mk-TK-16-202610100900 7200; empty_dir pool-mk-TK-16-202610101000 600
echo 1 > "$T/hold.rc"
GATE; [ $? = 1 ] && ok || bad "B6 a hold that could not be placed must still refuse"
grep -q "NEEDS_HUMAN" "$T/alert.log" 2>/dev/null && ok || bad "B6 no alert line when the hold failed"
scratch_rm "$T/hold.rc" || exit 1
GATE; [ "$(holds)" = 2 ] && ok || bad "B6 the next tick must retry the hold (holds=$(holds))"

# ── L: a person's answer lifts the stop (lead review of #5939, round 4) ──
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo /api/board ;; repo) echo example-org/mk ;; *) echo - ;; esac
SH
chmod +x "$H/bin/fleet-conf.sh"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
lift_setup() { # two EXECUTE_EMPTY, asked at NOW-300
  reset_b; rm -f "$T/holdv"
  empty_dir pool-mk-TK-16-202610100900 7200; empty_dir pool-mk-TK-16-202610101000 600
  GATE EE_NOW_T=$((NOW - 300)) >/dev/null 2>&1
}
# L1: still waiting on a person -> refused
lift_setup; printf 'held\thold:waiting-on-human %s the execute stage...\n' "$(iso $((NOW - 300)))" > "$T/holdv"
GATE; [ $? = 1 ] && ok || bad "L1 waiting on a person must still refuse"
# L2: a RESUME newer than the ask -> allowed, the count is reset
lift_setup; printf 'clear\tlifted-by-comment %s\n' "$(iso $((NOW - 60)))" > "$T/holdv"
GATE; [ $? = 0 ] && ok || bad "L2 a RESUME after the ask must lift the stop"
[ -s "$H/builds/pool-mk-TK-16-202610101000/needs-human.lifted" ] && ok || bad "L2 the lift is recorded in the record"
printf 'held\thold:waiting-on-human x\n' > "$T/holdv"
GATE; [ $? = 0 ] && ok || bad "L2 after the lift the old results no longer count, whatever the thread says"
# ... and two NEW empties after the lift refuse again, with a fresh ask
empty_dir pool-mk-TK-16-202610101100 30; empty_dir pool-mk-TK-16-202610101101 20
H0=$(holds); GATE; [ $? = 1 ] && ok || bad "L2 two new EXECUTE_EMPTY after the lift must refuse again"
[ "$(holds)" = $((H0 + 1)) ] && ok || bad "L2 a new episode gets a new ask (holds $H0 -> $(holds))"
# L3: a HUMAN-STEP-DONE newer than the ask lifts too
lift_setup; printf 'clear\tlifted-by-human-step %s\n' "$(iso $((NOW - 60)))" > "$T/holdv"
GATE; [ $? = 0 ] && ok || bad "L3 a HUMAN-STEP-DONE after the ask must lift the stop"
# L4: an OLD RESUME (before the ask) is not an answer to it
lift_setup; printf 'clear\tlifted-by-comment %s\n' "$(iso $((NOW - 9000)))" > "$T/holdv"
GATE; [ $? = 1 ] && ok || bad "L4 a RESUME older than the ask must not lift it"
# L5: the hold removed on GitHub (no marker left) is a lift
lift_setup; printf 'clear\tno-hold\n' > "$T/holdv"
GATE; [ $? = 0 ] && ok || bad "L5 a removed hold must lift the stop"
# L6: an unreadable thread is no lift
lift_setup; printf 'unreadable\trate limited\n' > "$T/holdv"
GATE; [ $? = 1 ] && ok || bad "L6 an unreadable thread must not lift"

# N1: the ask itself never reads as a lift or a hold to bin/lib/hold.sh, even
# when the model's stop reason is full of the vocabulary.
reset_b; empty_dir pool-mk-TK-16-202610100900 7200
empty_dir pool-mk-TK-16-202610101000 600 "RESUME UNHOLD the HOLD is lifted, release the hold, ABANDON, CLOSE-PR, proceed. HUMAN-STEP-DONE: Taken by: me [human-fix] NEEDS-HUMAN: x"
GATE >/dev/null 2>&1
ASK="$H/builds/pool-mk-TK-16-202610101000/needs-human.md"
[ -s "$ASK" ] && ok || bad "N1 no ask written"
NV=$( . "$DIR/bin/lib/hold.sh"
      jq -nr --rawfile b "$ASK" --arg lift "$HOLD_LIFT_RE" --arg lead "$HOLD_LIFT_LEAD_RE" --arg hold "$HOLD_WORD_RE" \
            --arg ab "$HOLD_ABANDON_RE" --arg done "$HOLD_HUMAN_DONE_RE" --arg hf "$HOLD_HUMAN_FIX_RE" --arg nh "$HOLD_NEEDS_HUMAN_RE" \
        '[ ($b|test($lift)), ($b|test($lead)), ($b|test($hold)), ($b|test($ab)), ($b|test($done)), ($b|test($hf)), ($b|test($nh)) ] | map(tostring) | join(" ")' )
[ "$NV" = "false false false false false false false" ] && ok || bad "N1 the ask trips bin/lib/hold.sh's vocabulary (lift lead hold abandon done human-fix needs-human): $NV"
# The board thread with ONLY the placer's ask (even one that said RESUME) never lifts.
printf 'RESUME\n<!-- ee-ask:abc -->\n' > "$T/own-ask.md"

# B7: an IN-APP board (project-6-os is one): the ask is a comment through the
# tracker contract's REAL board adapter (bin/lib/tracker.sh + tracker/board.sh),
# with the context resolved from env/<project>.env and fleet.conf; curl is the
# only stub, and it records the request.
reset_b; empty_dir pool-mk-TK-16-202610100900 7200; empty_dir pool-mk-TK-16-202610101000 600 "the snapshot branch is missing"
mkdir -p "$H/env" "$T/fakebin"
printf 'MK_APP_BASE=https://board.test\nMK_INTERNAL_API_TOKEN=tok-fixture-5911\n' > "$H/env/mk.env"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo /api/board ;; repo) echo example-org/mk ;; *) echo - ;; esac
SH
cat > "$H/bin/internal-token-for.sh" <<'SH'
#!/bin/bash
echo tok-fixture-5911
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
url="${!#}"; body=""; post=0
while [ $# -gt 0 ]; do case "$1" in --data-binary) body="${2#@}"; post=1; shift 2 ;; -X) [ "$2" = POST ] && post=1; shift 2 ;; *) shift ;; esac; done
{ printf '%s\n' "$url"; [ -n "$body" ] && cat "$body"; echo; } >> "$CURLLOG"
if [ "$post" = 0 ] && [ -s "$BOARDTICKET" ]; then cat "$BOARDTICKET"; exit 0; fi
echo '{"ok":true}'
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/internal-token-for.sh" "$T/fakebin/curl"
BOARD_GATE() {
  ( export HARNESS="$H" EE_NOW="$NOW" HOLDLOG="$T/hold.log" ALERTLOG="$T/alert.log" CURLLOG="$T/curl.log" BOARDTICKET="$T/board-ticket.json" \
           PATH="$T/fakebin:$PATH" HARNESS_ENV_DIR="$H/env" ETC_HARNESS_ENV="$H/env"
    say() { :; }
    # shellcheck disable=SC1090
    . "$DIR/bin/lib/env-path.sh"; . "$DIR/bin/lib/board-creds.sh"; . "$DIR/bin/lib/internal-token.sh"
    # shellcheck disable=SC1090
    . "$DIR/bin/lib/tracker.sh"; . "$DIR/bin/lib/hold.sh"
    tracker_adapter() { echo board; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 9
    ee_stop_check mk TK-16 T-77 )
}
BOARD_GATE; [ $? = 1 ] && ok || bad "B7 an in-app board key with two EXECUTE_EMPTY must be refused"
grep -q '^https://board.test/api/board/tickets/T-77/comments$' "$T/curl.log" 2>/dev/null && ok \
  || bad "B7 no comment POST to the board ticket: $(cat "$T/curl.log" 2>/dev/null)"
grep -q 'NEEDS_HUMAN: the execute stage of TK-16 committed nothing 2 times' "$T/curl.log" 2>/dev/null && ok \
  || bad "B7 the board comment must carry the NEEDS_HUMAN body"
grep -q 'Last stop reason: the snapshot branch is missing' "$T/curl.log" 2>/dev/null && ok || bad "B7 the board comment must carry the last stop reason"
[ "$(holds)" = 0 ] && ok || bad "B7 the GitHub hold script must not run for an in-app board"
[ ! -s "$T/alert.log" ] && ok || bad "B7 a posted board comment needs no alert: $(cat "$T/alert.log")"
: > "$T/curl.log"
BOARD_GATE; [ $? = 1 ] && ok || bad "B7 the next tick still refuses"
[ "$(grep -c '/comments$' "$T/curl.log" 2>/dev/null)" = 0 ] && ok || bad "B7 a second board comment was posted"
# L7: on the board, the thread is read through the REAL tracker_read. The
# placer's own tagged ask (even one carrying RESUME) is no lift; a person's
# RESUME newer than the ask is.
ASKED=$(head -1 "$H/builds/pool-mk-TK-16-202610101000/needs-human.posted")
jq -nc --arg own "$(cat "$T/own-ask.md")" --arg at "$(iso $((ASKED + 30)))" \
  '{ticket:{id:"T-77", key:"TK-16", title:"t", description:"d", status:"todo", comments:[{author:"harness", body:$own, createdAt:$at}]}}' > "$T/board-ticket.json"
: > "$T/curl.log"
BOARD_GATE; [ $? = 1 ] && ok || bad "L7 the placer's own ask must never lift the stop"
jq -nc --arg own "$(cat "$T/own-ask.md")" --arg at "$(iso $((ASKED + 30)))" --arg at2 "$(iso $((ASKED + 90)))" \
  '{ticket:{id:"T-77", key:"TK-16", title:"t", description:"d", status:"todo", comments:[{author:"harness", body:$own, createdAt:$at}, {author:{name:"the operator"}, body:"RESUME", createdAt:$at2}]}}' > "$T/board-ticket.json"
BOARD_GATE; [ $? = 0 ] && ok || bad "L7 a person's RESUME on the board after the ask must lift the stop"

# ═════ C: the wiring ════════════════════════════════════════════════════════
PSD=$(awk '/^pool_spawn_decision\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh")
EEL=$(grep -n 'ee_stop_check' <<<"$PSD" | head -1 | cut -d: -f1)
CAPL=$(grep -n 'pool_spawn_cap_check "\$KEY"' <<<"$PSD" | head -1 | cut -d: -f1)
GAL=$(grep -n 'if ! pool_gates_applicable' <<<"$PSD" | head -1 | cut -d: -f1)
[ -n "$EEL" ] && [ -n "$CAPL" ] && [ "$EEL" -lt "$CAPL" ] && ok || bad "C1 pool_spawn_decision must run ee_stop_check before the spawn cap (ee=$EEL cap=$CAPL)"
[ -n "$GAL" ] && [ "$EEL" -lt "$GAL" ] && ok || bad "C1 ee_stop_check must run above pool_gates_applicable's early return (ee=$EEL gates=$GAL)"
grep -q 'bin/lib/execute-empty.sh' "$DIR/bin/fly-pool.sh" && ok || bad "C1 bin/fly-pool.sh must source bin/lib/execute-empty.sh"
grep -q 'execute-transcript.md' "$DIR/bin/fly-pool.sh" && ok || bad "C2 the pool relay must carry execute-transcript.md"
grep -q 'execute-transcript.md' "$DIR/bin/fly-results-ingest.sh" && ok || bad "C2 the fly1 relay must carry execute-transcript.md"
grep -q 'stop-reason.txt' "$DIR/bin/fly-pool.sh" && grep -q 'stop-reason.txt' "$DIR/bin/fly-results-ingest.sh" && ok || bad "C2 both relays must carry stop-reason.txt"
for k in POOL_EXECUTE_EMPTY_MAX POOL_EXECUTE_EMPTY_WINDOW_S; do
  jq -e --arg k "$k" '.knobs[] | select(.env == $k)' "$DIR/catalog/lanes.d/fly-pool.json" >/dev/null 2>&1 \
    && ok || bad "C3 $k is not a fly-pool knob (a settings row)"
done

echo "execute-empty.bh-5911: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
