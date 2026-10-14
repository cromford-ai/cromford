#!/bin/bash
# tests/triage-hotfix-order-test.sh — the triage tick launches the EMERGENCY
# line first (BH-645, #643 slice 2 of 5).
#
# THE CASE THIS PINS. A triage tick reads logs/READY-QUEUE.log, caps it at 40
# lines and hands the session that list in file order. A hotfix filed this
# morning sits wherever the file happens to put it — line 43 on a busy box,
# which is to say nowhere, because the cap cuts it off before the session ever
# reads it. The board's "ALSO launchable right now" slice has the same shape.
# So the tick reads the project's open `ai-build` + `hotfix` issue numbers ONCE,
# marks the matching lines `[HOTFIX] ` and stable-sorts each slice hotfix-first
# BEFORE the cap.
#
# WHAT IS ASSERTED IS THE RENDERED PROMPT — the artifact the stubbed
# bin/agent-call.sh receives — never the source of the script. The whole script
# runs against a scratch $HARNESS with only its roots repointed, exactly like
# tests/triage-shards-test.sh: the gate reason, the scope arms, the cap, the
# shard split and the key canonicalisation are all decided by shipped code.
#
# THE NEGATIVES CARRY THE WEIGHT, because every one of them is a promise that
# this feature is free when it cannot answer: the lane off, the `gh` call
# failing, the API budget low and a non-GitHub-Issues board must each render a
# prompt BYTE-IDENTICAL to the one without the feature, and two of them must
# make no GitHub call at all. A rate-limited tick is deliberately
# indistinguishable from "no hotfixes": the ordinary path is today's behaviour.
#
# Run from anywhere: tests/triage-hotfix-order-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" project-5 project-3 || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/catalog" "$H/fixture" "$T/calls" "$T/repos" "$T/fakebin" "$T/fixture"
: > "$H/env/global.env"
# A GitHub-Issues project (fleet.conf board prefix "-"): the label lives on a
# GitHub issue, so this lane is the only board shape the feature acts on.
P=project-5
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
# The in-app board project of the last section, set up here so the fixture is
# one tree: its fingerprint is deliberately NOT the {"issues":...} shape.
PB=project-3
echo "SOP for $PB. Fetch the thread. Do the work." > "$H/prompts/$PB.md"
export FLEET_CONF="$DIR/fleet.conf"

# the scripts under test, with only their roots repointed
for s in run-triage.sh triage-shard.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$H/bin/$s"
  chmod +x "$H/bin/$s"
done
# bin/run-triage.sh's stage bodies (BH-479) live in bin/lib/rt/*.sh, not inline
# — without these the RT_STAGE loop hits its own "TRIAGE STAGE MISSING" refusal
# for every stage and the tick renders no prompt at all, exactly like a box
# whose bin/ half-synced.
mkdir -p "$H/bin/lib/rt"; for s in "$DIR"/bin/lib/rt/*.sh; do sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"; done
# THE CONTROL SCRIPT: main's copy of the same file, repointed the same way. It
# is what "byte-identical to today's prompt" is measured against — a control
# built from the branch under test could only ever prove the feature agrees
# with itself. A checkout with no `main` ref (a shallow CI clone) says so out
# loud and the four negatives fall back to comparing against each other.
MAIN_CTL=0
if git -C "$DIR" show main:bin/run-triage.sh > "$T/main-run-triage.raw" 2>/dev/null \
   && [ -s "$T/main-run-triage.raw" ]; then
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$T/main-run-triage.raw" > "$H/bin/run-triage-main.sh"
  chmod +x "$H/bin/run-triage-main.sh"
  MAIN_CTL=1
else
  echo "NOTE: no main:bin/run-triage.sh in this checkout — the byte-identical control is the feature's own no-hotfix run, not main's"
fi
# the real decision-makers
# BH-425: triage_hot_load reads through bin/lib/gh-rest.sh now, not `gh issue
# list` — without the file here `command -v gh_rest` is false and every tick
# reads as "no hotfixes" before the fake gh below is ever asked.
cp "$DIR/bin/lib/triage-shards-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/triage-hotfix-lib.sh" "$H/bin/lib/"
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs: the gate, the deterministic pass, the model call, the console -----
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
PP="\$1"; MODE="\${2:-}"
cp "$H/fixture/pending-\$PP.json" "$H/state/\$PP.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
[ "\$MODE" = "--buildable" ] && { echo OK; exit 0; }
echo "RUN queue-pending"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
# rc 2 = "the board is verified unchanged", which is the arm that renders the
# ALSO-launchable slice this change marks.
printf '#!/bin/sh\nexit 2\n' > "$H/bin/gate-diff.sh"; chmod +x "$H/bin/gate-diff.sh"
cat > "$H/bin/unblocked-children.sh" <<STUB
#!/bin/sh
cat "$T/fixture/unblocked" 2>/dev/null
exit 0
STUB
chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"

# --- the fake gh: every invocation recorded, the hotfix issue read answered
# from a fixture. BH-425 moved triage_hot_load off "gh issue list" onto REST
# (bin/lib/gh-rest.sh judges the HTTP status line gh api -i prints, not gh's
# exit code), so the arm below answers "gh api -i -X GET repos/.../issues?
# labels=..." with a real status line, built from the same bare-number fixture
# file the CLI form used to print one-per-line.
cat > "$T/fakebin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls"
case "\$*" in
  *"api -i -X GET repos/"*"/issues?labels="*)
    RC=\$(cat "$T/fixture/gh-issue-rc" 2>/dev/null || echo 0)
    if [ "\$RC" = 0 ]; then
      printf 'HTTP/1.1 200 OK\r\n\r\n'
      jq -R -s -c 'split("\n") | map(select(length>0)) | map({number:(.|tonumber), pull_request:null})' \
        "$T/fixture/hotfix-numbers" 2>/dev/null || printf '[]'
    else
      printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n{"message":"boom"}'
    fi ;;
  *"api rate_limit"*) cat "$T/fixture/rate_limit.json" 2>/dev/null ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/fakebin/gh"

FP_GH='{"issues":[{"number":9043,"state":"OPEN","title":"a"},{"number":9102,"state":"OPEN","title":"b"}],"prs":[]}'
# The in-app board's fingerprint shape: cuids under "tickets", never {"issues":.
FP_BOARD='{"tickets":[{"id":"ckabc123","status":"open"}]}'
RATE_OK='{"resources":{"core":{"remaining":4900,"limit":5000,"reset":0},"graphql":{"remaining":4900,"limit":5000,"reset":0}}}'
RATE_LOW='{"resources":{"core":{"remaining":3,"limit":5000,"reset":0},"graphql":{"remaining":3,"limit":5000,"reset":0}}}'

# 45 READY-QUEUE lines, the 43rd a hotfix key: the cap is 40, so a sort that
# runs after it would drop the emergency entirely.
queue_45() {
  local i n
  : > "$H/logs/READY-QUEUE.log"
  for i in $(seq 1 45); do
    n=$(printf '90%02d' "$i")
    echo "BH-$n tid-$n — ready to build, waiting on PR #12 project=project-5" >> "$H/logs/READY-QUEUE.log"
  done
}

reset() { # reset <project> <fingerprint> <hotfix-numbers> [unblocked-lines]
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  model_routes_fixture "$H" project-5 project-3 || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/flags/hotfix-lane-off" "$H/flags/triage-shards-off"
  printf '%s' "$2" > "$H/fixture/pending-$1.json"
  printf '%s' "$2" > "$H/state/$1.gate.json"
  printf '%s\n' "$3" | grep -v '^$' > "$T/fixture/hotfix-numbers" || : > "$T/fixture/hotfix-numbers"
  printf '%s' "${4:-}" > "$T/fixture/unblocked"
  printf '%s' "$RATE_OK" > "$T/fixture/rate_limit.json"
  echo 0 > "$T/fixture/gh-issue-rc"
  : > "$T/gh-calls"
  : > "$H/logs/READY-QUEUE.log"
}
run() { # run <project> [VAR=VAL ...] — one tick of the shipped script
  local proj="$1"; shift
  CALLDIR="$T/calls" PATH="$T/fakebin:$PATH" \
    env TRIAGE_SHARDS=0 "$@" bash "$H/bin/${SCRIPT:-run-triage.sh}" "$proj" >/dev/null 2>&1
}
prompt_file() { ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1; }
qblock() { # the rendered READY-QUEUE slice of the captured prompt
  awk '/^READY-QUEUE lines:$/{f=1;next} /^Queued launch requests for /{f=0} f' "$(prompt_file)"
}
bblock() { # the rendered ALSO-launchable slice, minus its header sentence
  awk '/^ALSO launchable right now/{f=1;next} f && (NF==0 || /^If the queue state/){exit} f' "$(prompt_file)"
}
# BH-425: the hotfix issue read is REST now, not the CLI "issue list" form.
issue_list_calls() { grep -c 'issues?labels=' "$T/gh-calls" 2>/dev/null | tr -d ' '; }
SOP_LINE='Lines marked [HOTFIX] are launched before any other line.'

UNBLOCKED2='board issues: UNBLOCKED 9101 "plain child" (parent PR merged)
board issues: UNBLOCKED 9102 "the emergency" (parent PR merged)'

# ---------------------------------------------------------------------------
# 0. THE CONTROL: no hotfix among the open issues. This prompt is what every
#    negative below must reproduce byte for byte.
# ---------------------------------------------------------------------------
reset "$P" "$FP_GH" "" "$UNBLOCKED2"
queue_45
run "$P"
CTL="$T/control.prompt"
[ -n "$(prompt_file)" ] && cp "$(prompt_file)" "$CTL" || { bad "0: the control tick rendered no prompt at all"; : > "$CTL"; }
[ -s "$CTL" ] && ok || bad "0: the control prompt is empty — the fixture never reached the agent call"
grep -q '\[HOTFIX\]' "$CTL" && bad "0a: a tick with no hotfix issue must carry no [HOTFIX] marker" || ok
grep -qF "$SOP_LINE" "$CTL" && bad "0b: the SOP sentence must be ABSENT when nothing is marked" || ok
[ "$(qblock | grep -c .)" = 40 ] && ok || bad "0c: the control queue block must hold exactly 40 lines (got $(qblock | grep -c .))"

if [ "$MAIN_CTL" = 1 ]; then
  reset "$P" "$FP_GH" "" "$UNBLOCKED2"
  queue_45
  SCRIPT=run-triage-main.sh run "$P"
  if [ -n "$(prompt_file)" ] && diff -q "$CTL" "$(prompt_file)" >/dev/null 2>&1; then ok
  else bad "0d: with no hotfix the prompt must be byte-identical to main's own render ($(diff "$CTL" "$(prompt_file)" 2>&1 | head -5))"; fi
fi

# ---------------------------------------------------------------------------
# 1. §queue-prefix / §cap — the 43rd line is the first line
# ---------------------------------------------------------------------------
reset "$P" "$FP_GH" "9043
9102" "$UNBLOCKED2"
queue_45
run "$P"
FIRSTQ=$(qblock | head -1)
case "$FIRSTQ" in
  '[HOTFIX] BH-9043 '*) ok ;;
  *) bad "1a: the hotfix queue line must be the FIRST rendered queue line (got: $FIRSTQ)" ;;
esac
[ "$(qblock | grep -c .)" = 40 ] && ok || bad "1b: the cap still binds — exactly 40 queue lines (got $(qblock | grep -c .))"
[ "$(qblock | grep -c '\[HOTFIX\] ')" = 1 ] && ok || bad "1c: exactly one queue line may be marked (got $(qblock | grep -c '\[HOTFIX\] '))"
# STABILITY: the 39 plain survivors keep the file's own order. A sort without
# -s re-orders a tie by the whole line, which turns oldest-first into
# alphabetical and says nothing about it.
PLAIN=$(qblock | grep -v '\[HOTFIX\] ' | awk '{print $1}')
EXPECT=$(head -39 "$H/logs/READY-QUEUE.log" | awk '{print $1}')
[ "$PLAIN" = "$EXPECT" ] && ok || bad "1d: the plain queue lines must keep READY-QUEUE order (got: $(head -3 <<<"$PLAIN" | tr '\n' ' '))"
grep -qF "$SOP_LINE" "$(prompt_file)" && ok || bad "1e: the SOP sentence must appear once something is marked"
[ "$(grep -cF "$SOP_LINE" "$(prompt_file)")" = 1 ] && ok || bad "1f: the SOP sentence must appear exactly once (got $(grep -cF "$SOP_LINE" "$(prompt_file)"))"

# §board-prefix — the launchable board slice is marked and sorted too
BFIRST=$(bblock | head -1)
case "$BFIRST" in
  '[HOTFIX] board issues: UNBLOCKED 9102 '*) ok ;;
  *) bad "1g: the hotfix board line must be marked and first in the ALSO-launchable slice (got: $BFIRST)" ;;
esac
bblock | grep -q '^board issues: UNBLOCKED 9101 ' && ok || bad "1h: the plain board line must still be listed, unmarked (got: $(bblock | tr '\n' '|'))"
# NOTHING IS DROPPED BY THE ORDERING. bin/unblocked-children.sh's last line
# carries no trailing newline, and a read loop that ignores that reads a
# launchable ticket and throws it away — a reorder that loses a line is worse
# than no reorder at all.
[ "$(bblock | grep -c .)" = 2 ] && ok || bad "1h2: both launchable board lines must survive the sort (got: $(bblock | tr '\n' '|'))"

# §gh-called-once — both slices are marked off ONE read
[ "$(issue_list_calls)" = 1 ] && ok || bad "1i: the hotfix set must be read exactly once per tick (got $(issue_list_calls) issue list calls)"

# ---------------------------------------------------------------------------
# 2. §gh-fails — a failed read is "no hotfixes", never a fatal and never a guess
# ---------------------------------------------------------------------------
reset "$P" "$FP_GH" "9043
9102" "$UNBLOCKED2"
queue_45
echo 1 > "$T/fixture/gh-issue-rc"
run "$P"
if [ -n "$(prompt_file)" ] && diff -q "$CTL" "$(prompt_file)" >/dev/null 2>&1; then ok
else bad "2a: a failing gh issue list must render the control prompt byte for byte ($(diff "$CTL" "$(prompt_file)" 2>&1 | head -5))"; fi

# ---------------------------------------------------------------------------
# 3. §lane-off — the kill switch removes the READ, not just the prefix
# ---------------------------------------------------------------------------
reset "$P" "$FP_GH" "9043
9102" "$UNBLOCKED2"
queue_45
touch "$H/flags/hotfix-lane-off"
run "$P"
[ "$(issue_list_calls)" = 0 ] && ok || bad "3a: flags/hotfix-lane-off must make ZERO issue list calls (got $(issue_list_calls))"
if [ -n "$(prompt_file)" ] && diff -q "$CTL" "$(prompt_file)" >/dev/null 2>&1; then ok
else bad "3b: with the lane off the prompt must be byte-identical to the control ($(diff "$CTL" "$(prompt_file)" 2>&1 | head -5))"; fi
rm -f "$H/flags/hotfix-lane-off"

# HOTFIX_LANE=0 is the same switch by the other door.
reset "$P" "$FP_GH" "9043
9102" "$UNBLOCKED2"
queue_45
run "$P" HOTFIX_LANE=0
[ "$(issue_list_calls)" = 0 ] && ok || bad "3c: HOTFIX_LANE=0 must make ZERO issue list calls (got $(issue_list_calls))"

# ---------------------------------------------------------------------------
# 4. §budget-low — the read rides the EXISTING gh-budget bucket
# ---------------------------------------------------------------------------
reset "$P" "$FP_GH" "9043
9102" "$UNBLOCKED2"
queue_45
printf '%s' "$RATE_LOW" > "$T/fixture/rate_limit.json"
run "$P"
[ "$(issue_list_calls)" = 0 ] && ok || bad "4a: a low API budget must skip the hotfix read (got $(issue_list_calls) issue list calls)"
if [ -n "$(prompt_file)" ] && diff -q "$CTL" "$(prompt_file)" >/dev/null 2>&1; then ok
else bad "4b: a budget-low tick renders today's prompt ($(diff "$CTL" "$(prompt_file)" 2>&1 | head -5))"; fi

# ---------------------------------------------------------------------------
# 5. §board-project — an in-app board has no such label, so it never asks
# ---------------------------------------------------------------------------
reset "$PB" "$FP_BOARD" "9043
9102" "$UNBLOCKED2"
queue_45
run "$PB"
[ "$(issue_list_calls)" = 0 ] && ok || bad "5a: a non-GitHub-Issues board must make ZERO issue list calls (got $(issue_list_calls))"
BCTL="$T/board-control.prompt"
[ -n "$(prompt_file)" ] && cp "$(prompt_file)" "$BCTL" || : > "$BCTL"
grep -q '\[HOTFIX\]' "$BCTL" && bad "5b: an in-app board must render no [HOTFIX] marker" || ok
if [ "$MAIN_CTL" = 1 ]; then
  reset "$PB" "$FP_BOARD" "9043
9102" "$UNBLOCKED2"
  queue_45
  SCRIPT=run-triage-main.sh run "$PB"
  if [ -n "$(prompt_file)" ] && diff -q "$BCTL" "$(prompt_file)" >/dev/null 2>&1; then ok
  else bad "5c: the in-app board's prompt must be byte-identical to main's ($(diff "$BCTL" "$(prompt_file)" 2>&1 | head -5))"; fi
fi

# ---------------------------------------------------------------------------
# 6. §already-prefixed — the marker is ours, and it is never doubled
# ---------------------------------------------------------------------------
# A line that already carries the text is not a second emergency, and it must
# not become `[HOTFIX] [HOTFIX] board issues: …` — which would also make the key
# unreadable to every downstream consumer. The BOARD slice is where this can
# actually happen: the queue slice is filtered by the existing key-anchored
# `grep -E '^[A-Z]+-[0-9]'` first, which drops such a line before any of this
# runs — today's behaviour, and unchanged here (asserted below).
reset "$P" "$FP_GH" "9102" 'board issues: UNBLOCKED 9101 "plain child" (parent PR merged)
[HOTFIX] board issues: UNBLOCKED 9102 "the emergency" (parent PR merged)'
printf '[HOTFIX] BH-9043 tid-9043 — ready to build project=project-5\nBH-9044 tid-9044 — ready to build project=project-5\n' > "$H/logs/READY-QUEUE.log"
run "$P"
grep -q '\[HOTFIX\] \[HOTFIX\]' "$(prompt_file)" && bad "6a: a line that already carried the marker was double-prefixed" || ok
bblock | head -1 | grep -q '^\[HOTFIX\] board issues: UNBLOCKED 9102 ' && ok \
  || bad "6b: the already-marked board line must render once-marked and first (got: $(bblock | head -1))"
[ "$(bblock | grep -c .)" = 2 ] && ok || bad "6c: neither board line may be dropped (got: $(bblock | tr '\n' '|'))"
grep -q 'BH-9043' <<<"$(qblock)" && bad "6d: the key-anchored queue grep drops a marked line today — that must not change" || ok

# ---------------------------------------------------------------------------
# 7. §sharding-survives — the prefix must not disarm per-ticket triage sharding
# ---------------------------------------------------------------------------
# bin/lib/triage-shards-lib.sh's key regexes anchor at the start of the line, so
# a raw `[HOTFIX] ` prefix makes triage_shard_key return 1, which makes
# shard_collect abandon the split and silently run the single session for every
# tick that has a hotfix. A reorder with a side effect that big is not a
# reorder.
reset "$P" "$FP_GH" "9043" "$UNBLOCKED2"
printf 'BH-9043 tid-9043 — ready to build project=project-5\nBH-9044 tid-9044 — ready to build project=project-5\n' > "$H/logs/READY-QUEUE.log"
CALLDIR="$T/calls" PATH="$T/fakebin:$PATH" env TRIAGE_SHARDS=1 \
  bash "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1
# the detached shards land in their own time; wait for the calls, then the locks
i=0
while [ "$i" -lt 60 ]; do
  BUSY=0
  for L in "$H"/locks/triage-key-*.lock; do
    [ -e "$L" ] || continue
    ( exec 9>"$L" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null || BUSY=1
  done
  [ "$BUSY" = 0 ] && [ -n "$(ls "$T/calls"/prompt-* 2>/dev/null)" ] && break
  i=$((i+1)); sleep 0.25
done
sleep 1
grep -q 'could not place' "$H/logs/$P.log" && bad "7a: the marker must not make the dispatcher abandon the split ($(grep 'could not place' "$H/logs/$P.log"))" || ok
grep -q 'dispatched [1-9][0-9]* shards:' "$H/logs/$P.log" && ok || bad "7b: the tick must still dispatch shards (log: $(tail -2 "$H/logs/$P.log"))"
grep -l 'Work ONLY ticket 9043 this tick' "$T/calls"/prompt-*.txt >/dev/null 2>&1 && ok \
  || bad "7c: the hotfix key must still get its own shard session"
# and the shard's own scope line is the clean line, not a marked one: a shard
# already knows which ticket it is.
SF=$(grep -l 'Work ONLY ticket 9043 this tick' "$T/calls"/prompt-*.txt 2>/dev/null | head -1)
[ -n "$SF" ] && ! grep -q '\[HOTFIX\]' "$SF" && ok || bad "7d: a per-ticket shard prompt must carry no ordering marker"

echo "triage-hotfix-order-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
