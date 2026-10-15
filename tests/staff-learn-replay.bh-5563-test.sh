#!/bin/bash
# tests/staff-learn-replay.bh-5563-test.sh — BH-5563 (BH-5556.6): a staff
# skill edit goes through the archie-learn replay gate, driven through the
# SHIPPED bin/staff-learn.sh (which runs the unchanged bin/archie-learn.sh on
# the agent's own skills tree).
#
#   L1   an edit whose replays pass is promoted: rc 0, the live staff skill
#        is the new file, under state/staff/<agent>/skills-home
#   L2   an edit with a failing replay is rejected: rc 1, a `rejected` log
#        line, the live SKILL.md and the learned dir are byte-identical
#   L3   a bad agent name, and the Archie-only modes (correct facts, report,
#        unused), are rc 2 and write nothing
#   L4   the gate is per agent: an edit to watchman never touches Archie's
#        orchestrator tree or another agent's tree
#
# MUTATION (D1), tried by hand once: point ARCHIE_SKILLS_SRC at an empty dir
# in bin/staff-learn.sh -> L1 red (no replays to gate on).
#
# The replay model is a stub (ARCHIE_REPLAY_MODEL_CMD): it answers the case's
# expected verdict only when the prompt carries `RULE: GOOD`, so a SKILL.md
# edit really moves a verdict. Nothing reaches a vendor or the worker.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-learn-replay.bh-5563-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-learn-replay: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

[ -r "$DIR/bin/staff-learn.sh" ] || { bad "missing $DIR/bin/staff-learn.sh"; echo "staff-learn-replay: $PASS passed, $FAIL failed"; exit 1; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; CK="$T/checkout"; ORC="$T/orc"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$H/state" "$T/stubs" "$ORC"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
: > "$H/env/global.env"

# The staff skill as a checkout carries it: SKILL.md plus 2 replay cases.
SK="$CK/prompts/staff/skills/watchman/leak-triage"
mkdir -p "$SK/replays/01-public-key" "$SK/replays/02-test-fixture"
skill_md() { # skill_md <rule line>
  printf -- '---\nname: leak-triage\nverdicts: file|skip\n---\n# Leak triage\n\n%s\n' "$1"
}
skill_md 'RULE: GOOD. File a live key; skip a fixture.' > "$SK/SKILL.md"
printf 'A live-looking key in a public gist.\n' > "$SK/replays/01-public-key/input.md"
echo 'VERDICT: file' > "$SK/replays/01-public-key/expected"
printf 'It is live.\nVERDICT: file\n' > "$SK/replays/01-public-key/recorded.txt"
printf 'tok-fixture-1 in a test file.\n' > "$SK/replays/02-test-fixture/input.md"
echo 'VERDICT: skip' > "$SK/replays/02-test-fixture/expected"
printf 'A fixture.\nVERDICT: skip\n' > "$SK/replays/02-test-fixture/recorded.txt"
# The live staff skill, as a deploy would leave it (SKILL.md only).
LIVE="$H/state/staff/watchman/skills-home/.claude/skills/leak-triage"
mkdir -p "$LIVE"; cp "$SK/SKILL.md" "$LIVE/SKILL.md"

skill_md 'RULE: GOOD. File a live key; skip a fixture; name the repo.' > "$T/v2.md"
skill_md 'RULE: BAD. File everything.' > "$T/v3.md"
cat > "$T/stubs/judge" <<'SH'
#!/bin/bash
# <prompt-file> <case-dir>: the expected verdict only for a RULE: GOOD skill.
if grep -q 'RULE: GOOD' "$1"; then cat "$2/expected"; else echo 'VERDICT: file'; fi
SH
chmod +x "$T/stubs/judge"

LEARN() {
  env HARNESS="$H" HARNESS_CHECKOUT="$CK" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 JOBS_URL= \
    ARCHIE_ORC_DIR="$ORC" ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" bash "$H/bin/staff-learn.sh" "$@"
}
LLOG="$H/logs/archie-learning.log"
LSK="$H/state/staff/watchman/skills-home/learned/skills"
sha() { sha256sum "$1" 2>/dev/null | cut -c1-64; }
tree_sum() { find "$@" -type f 2>/dev/null | sort | xargs -r md5sum | md5sum; }
ORC_SUM=$(tree_sum "$ORC")

# ═════ L1: a passing edit is promoted to the live staff skill ═══════════════
OUT=$(LEARN edit watchman leak-triage "$T/v2.md" --why "name the repo" 2>&1); RC=$?
eq "L1 rc ($OUT)" "$RC" 0
eq "L1 the live staff SKILL.md is v2" "$(sha "$LIVE/SKILL.md")" "$(sha "$T/v2.md")"
[ -f "$LSK/leak-triage/replays/01-public-key/expected" ] && ok || bad "L1 the learned copy keeps the replays"
grep -qE '^[0-9TZ:-]+ promoted leak-triage kind=edit ' "$LLOG" && ok || bad "L1 promoted line: $(cat "$LLOG" 2>/dev/null)"

# ═════ L2: a failing replay is rejected and the old skill stays live ═══════
LIVE_SHA=$(sha "$LIVE/SKILL.md"); LSK_SUM=$(tree_sum "$LSK")
OUT=$(LEARN edit watchman leak-triage "$T/v3.md" --why "file everything" 2>&1); RC=$?
eq "L2 rc" "$RC" 1
eq "L2 the live SKILL.md is still v2" "$(sha "$LIVE/SKILL.md")" "$LIVE_SHA"
eq "L2 the live SKILL.md is v2 by content" "$LIVE_SHA" "$(sha "$T/v2.md")"
eq "L2 the learned dir is byte-identical" "$(tree_sum "$LSK")" "$LSK_SUM"
grep -qE '^[0-9TZ:-]+ rejected leak-triage kind=edit .*leak-triage/02-test-fixture expected=skip got=file' "$LLOG" \
  && ok || bad "L2 rejected line: $(tail -1 "$LLOG" 2>/dev/null)"
grep -q 'old skill stays live' <<<"$OUT" && ok || bad "L2 the operator is told: $OUT"

# ═════ L3: refusals are rc 2 and write nothing ═══════════════════════════════
LOG_N=$(wc -l < "$LLOG")
for args in "edit Watch-man leak-triage $T/v2.md --why x" "edit 'watch man' leak-triage $T/v2.md --why x" \
            "correct watchman facts --why x" "report watchman" "unused watchman" "edit" "nonsense watchman"; do
  eval "set -- $args"
  LEARN "$@" >/dev/null 2>&1; RC=$?
  eq "L3 rc for [$args]" "$RC" 2
done
eq "L3 nothing logged" "$(wc -l < "$LLOG")" "$LOG_N"
# A bad name refuses even when a tree exists under it: the name check, not a
# missing directory, is what stops it.
mkdir -p "$CK/prompts/staff/skills/Watchman" "$H/state/staff/Watchman/skills-home/.claude/skills/leak-triage"
cp -r "$SK" "$CK/prompts/staff/skills/Watchman/"
BADLIVE="$H/state/staff/Watchman/skills-home/.claude/skills/leak-triage/SKILL.md"
cp "$SK/SKILL.md" "$BADLIVE"; BAD_SHA=$(sha "$BADLIVE")
LEARN edit Watchman leak-triage "$T/v2.md" --why x >/dev/null 2>&1; RC=$?
eq "L3 rc for an uppercase agent with a tree" "$RC" 2
eq "L3 the uppercase tree's SKILL.md is unchanged" "$(sha "$BADLIVE")" "$BAD_SHA"
eq "L3 still nothing logged" "$(wc -l < "$LLOG")" "$LOG_N"
eq "L3 the live SKILL.md is still v2" "$(sha "$LIVE/SKILL.md")" "$LIVE_SHA"

# ═════ L4: the tree is the agent's own ═══════════════════════════════════════
eq "L4 Archie's orchestrator tree is untouched" "$(tree_sum "$ORC")" "$ORC_SUM"
[ ! -e "$H/state/staff/inspector" ] && ok || bad "L4 another agent's tree was created"

echo "staff-learn-replay: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
