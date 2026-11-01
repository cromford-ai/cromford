#!/bin/bash
# tests/execute-transcript.bh-8868-test.sh — BH-8868: an execute session that
# was stopped keeps its turn-by-turn transcript.
#
# THE INCIDENT (project-6-os TK-3225). The execute session ran 3510 s and was
# killed at its context ceiling. A killed session writes no CLI envelope, so
# $OUT.json had no session_id, and the account's CLAUDE_CONFIG_DIR was not
# $HOME/.claude. ee_transcript read the id only from the envelope and searched
# only $HOME/.claude/projects, so execute-transcript.md said "no claude session
# file was found for this attempt" and held only the final output.
# bin/agent-call.sh already wrote the id and the config dir to $OUT.session.
#
# Driven, not grepped: the REAL bin/lib/execute-empty.sh (ee_on_empty), with the
# REAL bin/transcript-render.sh and bin/transcript-scrub.sh.
#   1 killed-session shape: empty $OUT.json, $OUT.session = <sid>\t<cfg>, the
#     jsonl under <cfg>/projects (cfg is NOT $HOME/.claude): source session_jsonl.
#   2 the envelope's session_id still wins when it is present.
#   3 a sid with `/` or `..` in $OUT.session is refused: source stage_output.
#   4 no session file at all: source stage_output and the NOTE (old behavior).
#   5 the label: ee_on_empty <dir> EXECUTE_NO_PROGRESS titles the file with it;
#     no label keeps the old EXECUTE_EMPTY title.
#   6 vendor budget: no network stub was called.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/execute-transcript.bh-8868-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

# A network stub on PATH: any curl or wget call is recorded (case 6).
mkdir -p "$T/fakebin" "$T/home/.claude/projects"
for v in curl wget; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$v" "$T" > "$T/fakebin/$v"
  chmod +x "$T/fakebin/$v"
done
: > "$T/net.log"

# session <cfg-dir> <sid> <text> — a real-shaped claude session jsonl.
session() {
  mkdir -p "$1/projects/-work"
  {
    printf '{"type":"user","timestamp":"2026-10-31T10:00:00.000Z","message":{"role":"user","content":"Execute the plan"}}\n'
    printf '{"type":"assistant","timestamp":"2026-10-31T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$3"
  } > "$1/projects/-work/$2.jsonl"
}
# EE <build-dir> [label] — ee_on_empty in a subshell with this suite's env.
EE() {
  ( export HARNESS="$DIR" HOME="$T/home" PATH="$T/fakebin:$PATH"
    unset CLAUDE_PROJECTS_DIR CLAUDE_CONFIG_DIR
    # shellcheck disable=SC1091
    . "$DIR/bin/lib/execute-empty.sh" || exit 9
    ee_on_empty "$@" ) >/dev/null 2>&1
}
SID="00000000-0000-0000-0000-000000008861"
CFG="$T/accounts/acct-2/claude"   # the account's CLAUDE_CONFIG_DIR, not $HOME/.claude

# 1: the killed-session shape
B1="$T/b1"; mkdir -p "$B1"
session "$CFG" "$SID" "Reading the plan before the first edit."
printf 'CONTEXT KILL: execute/project-6-os session stopped by the harness\n' > "$B1/execute-run.txt"
: > "$B1/execute-run.txt.json"
printf '%s\t%s\n' "$SID" "$CFG" > "$B1/execute-run.txt.session"
EE "$B1"
grep -q "source: session_jsonl" "$B1/execute-transcript.md" 2>/dev/null \
  && ok || bad "1 a killed session with \$OUT.session must render the session jsonl: $(sed -n 2,3p "$B1/execute-transcript.md" 2>/dev/null)"
grep -q "Reading the plan before the first edit." "$B1/execute-transcript.md" 2>/dev/null \
  && ok || bad "1 the rendered assistant turn is not in execute-transcript.md"
grep -q "session: $SID" "$B1/execute-transcript.md" 2>/dev/null \
  && ok || bad "1 the header must name the session id"
grep -q "no claude session file was found" "$B1/execute-transcript.md" 2>/dev/null \
  && bad "1 the NOTE for a missing session file was written although the file exists" || ok

# 2: the envelope's session_id still wins
B2="$T/b2"; mkdir -p "$B2"
SID2="00000000-0000-0000-0000-000000008862"
session "$T/home/.claude" "$SID2" "Envelope session turn."
session "$CFG" "$SID" "Reading the plan before the first edit."
printf 'done\n' > "$B2/execute-run.txt"
jq -nc --arg s "$SID2" '{session_id:$s, result:"done"}' > "$B2/execute-run.txt.json"
printf '%s\t%s\n' "$SID" "$CFG" > "$B2/execute-run.txt.session"
EE "$B2"
grep -q "Envelope session turn." "$B2/execute-transcript.md" 2>/dev/null \
  && ok || bad "2 the envelope's session_id must win over \$OUT.session: $(sed -n 2p "$B2/execute-transcript.md" 2>/dev/null)"
grep -q "source: session_jsonl" "$B2/execute-transcript.md" 2>/dev/null && ok || bad "2 source must be session_jsonl"

# 3: an unsafe sid in $OUT.session is refused
i3=0
for bad_sid in "../$SID" "a/b"; do
  i3=$((i3+1))
  B3="$T/b3-$i3"; mkdir -p "$B3"
  printf 'final output\n' > "$B3/execute-run.txt"
  printf '%s\t%s\n' "$bad_sid" "$CFG" > "$B3/execute-run.txt.session"
  EE "$B3"
  grep -q "source: stage_output" "$B3/execute-transcript.md" 2>/dev/null \
    && ok || bad "3 sid '$bad_sid' must be refused (want stage_output): $(sed -n 2p "$B3/execute-transcript.md" 2>/dev/null)"
  grep -qF "session: $bad_sid" "$B3/execute-transcript.md" 2>/dev/null \
    && bad "3 the refused sid '$bad_sid' was used: $(sed -n 2p "$B3/execute-transcript.md" 2>/dev/null)" || ok
done

# 4: no session file at all: the old behavior
B4="$T/b4"; mkdir -p "$B4"
printf 'final output only\n' > "$B4/execute-run.txt"
EE "$B4"
grep -q "source: stage_output" "$B4/execute-transcript.md" 2>/dev/null && ok || bad "4 want source: stage_output"
grep -q "no claude session file was found" "$B4/execute-transcript.md" 2>/dev/null && ok || bad "4 the NOTE line is missing"
[ "$(head -1 "$B4/execute-transcript.md" 2>/dev/null)" = "# execute transcript (EXECUTE_EMPTY)" ] \
  && ok || bad "4/5 no label must keep the old title: $(head -1 "$B4/execute-transcript.md" 2>/dev/null)"

# 5: the label
B5="$T/b5"; mkdir -p "$B5"
printf 'final output only\n' > "$B5/execute-run.txt"
EE "$B5" EXECUTE_NO_PROGRESS
[ "$(head -1 "$B5/execute-transcript.md" 2>/dev/null)" = "# execute transcript (EXECUTE_NO_PROGRESS)" ] \
  && ok || bad "5 the label must title the file: $(head -1 "$B5/execute-transcript.md" 2>/dev/null)"

# 6: vendor budget
[ ! -s "$T/net.log" ] && ok || bad "6 a network call was made: $(cat "$T/net.log")"

echo "execute-transcript.bh-8868-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
