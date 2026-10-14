#!/bin/bash
# tests/archie-learning.bh-4066-test.sh — BH-4066 (BH-3966.5): Archie's
# learning loop, driven through the SHIPPED entry points:
#   bin/archie-learn.sh         edit | correct | propose | adopt | unused | report
#   bin/archie-replay-model.sh  the metered live replay model (agent-call)
#   bin/sync-skills.sh          skips a skill learned on the hub
#   bin/orchestrate.sh          compose_v2_prompt carries facts.md
# The ticket names this suite tests/archie-learning-test.sh; harness convention
# is one new suite per ticket, so it lives here.
#
# WHAT IS STUBBED. A scratch harness $H (a symlink tree of the repo's bin/ and
# a copy of catalog/lanes.d) with these shims:
#   bin/agent-call.sh  counts calls, records argv and env, answers $T/ac.text
#                      (blank with $T/ac.blank, rc $T/ac.rc, or with
#                      $T/ac.judge a verdict read from the prompt);
#   bin/beat.sh        appends its payload to $T/beats.jsonl, exits $T/beat.rc;
#   bin/orc-context.sh prints a fixed history.
# ARCHIE_LEARN_FIXTURE=$T/fx.sh replaces _jobs_req (the llm-spend reads, from
# $T/spend.<lane>.json, or down with $T/spend.down) and lane_role_model (a
# fixed test-model, rc 75 with $T/noroute). The stub replay model $T/stubs/judge
# answers `VERDICT: silent` when the prompt carries `ALL GREEN IS NEWS` and the
# case's recorded.txt otherwise, so a SKILL.md edit really moves a verdict. The
# skill fixture is a copy of the shipped orchestrator/skills/brief-operator with
# its replays (D4). Nothing reaches a vendor, Telegram or the worker.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-learning.bh-4066-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "archie-learning: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-learn.sh" "$DIR/bin/archie-replay-model.sh" \
         "$DIR/catalog/lanes.d/archie-learn.json" "$DIR/cron/lanes/725-archie-learn.cron"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
if [ ! -f "$DIR/bin/archie-learn.sh" ] || [ ! -f "$DIR/bin/archie-replay-model.sh" ]; then
  echo "archie-learning: $PASS passed, $FAIL failed"; exit 1
fi
GIT_BEFORE=$(git -C "$DIR" status --porcelain 2>/dev/null)

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; ORC="$T/orc"; SRC="$T/src"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$H/state" "$T/stubs" "$T/tx" "$SRC"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/orc-context.sh" "$H/bin/alert-line.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s|%s|%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_FP:-}" "${AGENT_CALL_BUDGET_USD_ARCHIE_REPLAY:-}" \
  "${AGENT_CALL_GUARD_STAGE:-}" "${AGENT_CALL_TICKET:-}" >> "$FXT/agentcalls"
rc=$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
p="${6#@}"
if [ -f "$FXT/ac.judge" ]; then
  if grep -q 'ALL GREEN IS NEWS' "$p" || grep -q 'Nothing is waiting on the operator' "$p"; then echo "VERDICT: silent" > "$5"
  else printf 'I would send this.\nVERDICT: send\n' > "$5"; fi
elif [ -f "$FXT/ac.blank" ]; then printf '  \n' > "$5"
else cat "$FXT/ac.text" > "$5"; fi
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FXT/beats.jsonl"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
# BH-4779: Archie's Telegram transport, captured where the beats were.
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/beats.jsonl"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
printf '#!/bin/bash\necho "(recent history)"\n' > "$H/bin/orc-context.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/alerts.log"\n' > "$H/bin/alert-line.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/orc-context.sh" "$H/bin/alert-line.sh"

cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" lane
  JOBS_HTTP=""; JOBS_BODY=""
  printf '%s %s\n' "$m" "$p" >> "$FXT/reqlog"
  case "$p" in
    /api/settings*) printf '{"settings":[]}'; JOBS_HTTP=200; return 0 ;;
    /api/metrics/llm-spend*)
      [ -f "$FXT/spend.down" ] && { JOBS_HTTP=503; return 1; }
      lane=$(printf '%s' "$p" | sed -n 's/.*[?&]lane=\([^&]*\).*/\1/p')
      [ -f "$FXT/spend.$lane.json" ] || { JOBS_HTTP=404; return 2; }
      JOBS_HTTP=200; JOBS_BODY=$(cat "$FXT/spend.$lane.json"); printf '%s' "$JOBS_BODY"; return 0 ;;
  esac
  JOBS_HTTP=404; return 2
}
lane_role_model() { [ -f "$FXT/noroute" ] && return 75; [ "$1" = stage.archie-replay ] || return 75; echo test-model; }
SH

cat > "$T/stubs/judge" <<'SH'
#!/bin/bash
if grep -q 'ALL GREEN IS NEWS' "$1"; then echo "VERDICT: silent"; else cat "$2/recorded.txt"; fi
SH
printf '#!/bin/bash\necho "VERDICT: send"\nexit 1\n' > "$T/stubs/exit1"
chmod +x "$T/stubs/"*

NOW=1791374400   # Wed 2026-10-07T12:00:00Z; the last closed ISO week is 2026-W40
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
export HARNESS="$H" FXT="$T" HARNESS_TEST_SANDBOX=1 JOBS_URL=https://jobs.invalid HARNESS_SECRET=test LANE_GATE_DISABLE=1
unset ARCHIE_REPLAY_MODEL_CMD ARCHIE_LEARN_ENABLED ARCHIE_SKILL_UNUSED_DAYS ARCHIE_REPLAY_MAX_USD \
  ARCHIE_REPLAY_MAX_ATTEMPTS ARCHIE_LEARN_TIMED BEAT_STRICT 2>/dev/null || true
LEARN() { env ARCHIE_ORC_DIR="$ORC" ARCHIE_SKILLS_SRC="$SRC" ARCHIE_NOW="$NOW" ARCHIE_LEARN_FIXTURE="$T/fx.sh" \
  ARCHIE_TRANSCRIPTS_DIR="$T/tx" "$H/bin/archie-learn.sh" "$@"; }
LLOG="$H/logs/archie-learning.log"
LIVE="$ORC/.claude/skills"
LSK="$ORC/learned/skills"
sha() { sha256sum "$1" 2>/dev/null | cut -c1-64; }
tree_sum() { find "$@" -type f 2>/dev/null | sort | xargs -r md5sum | md5sum; }

# The hub as a deploy leaves it: the source tree carries the replays, the live
# dir holds only SKILL.md (bin/sync-skills.sh excludes replays/).
reset_hub() {
  scratch_rm "$ORC" || exit 1; scratch_rm "$SRC" || exit 1; scratch_rm "$LLOG" || exit 1
  mkdir -p "$SRC" "$LIVE"
  cp -r "$DIR/orchestrator/skills/brief-operator" "$SRC/"
  mkdir -p "$LIVE/brief-operator"; cp "$DIR/orchestrator/skills/brief-operator/SKILL.md" "$LIVE/brief-operator/"
}
reset_hub
STAMP0="$T/stamp0"; : > "$STAMP0"

# The correction: the operator said a merge he asked for is not news. The patched
# SKILL.md adds the rule; the new case replays the correction itself.
sed '/"All green" is noise\.$/a A merge the operator asked for, green and with nothing to decide, is `silent` too.' \
  "$DIR/orchestrator/skills/brief-operator/SKILL.md" > "$T/patched.md"
check "fixture: the patched SKILL.md differs" '! cmp -s "$T/patched.md" "$DIR/orchestrator/skills/brief-operator/SKILL.md"'
mkdir -p "$T/cases/04-correction"
printf 'PR #4120 (BH-4070), which the operator asked for, merged green. Nothing is waiting on the operator.\n' > "$T/cases/04-correction/input.md"
echo 'VERDICT: silent' > "$T/cases/04-correction/expected"
printf 'Merged and green, nothing for him to decide.\nVERDICT: silent\n' > "$T/cases/04-correction/recorded.txt"
# A bad edit: the rule it inserts flips every send case to silent.
sed '/^## Decide first$/a ALL GREEN IS NEWS: report it.' "$DIR/orchestrator/skills/brief-operator/SKILL.md" > "$T/bad.md"

# ═════ L1: a correction becomes a skill diff and a new replay case ═══════════
OUT=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN correct brief-operator "$T/patched.md" --case "$T/cases/04-correction" \
  --why "the operator: a merge he asked for is not news"); RC=$?
eq "L1 rc" "$RC" 0
check "L1 stdout carries the diff hunk ($OUT)" 'grep -qxF "+A merge the operator asked for, green and with nothing to decide, is \`silent\` too." <<<"$OUT"'
check "L1 the new case is a replay of the learned skill" 'ls "$LSK"/brief-operator/replays/04-*/expected >/dev/null 2>&1'
check "L1 the learned copy keeps the old cases" '[ -f "$LSK/brief-operator/replays/01-merge-decision/recorded.txt" ]'
eq "L1 the live SKILL.md is the patched file" "$(sha "$LIVE/brief-operator/SKILL.md")" "$(sha "$T/patched.md")"
check "L1 the learned marker" '[ -f "$LIVE/brief-operator/.archie-learned" ]'
check "L1 promoted log line ($(cat "$LLOG" 2>/dev/null))" 'grep -qE "^[0-9TZ:-]+ promoted brief-operator kind=correction cases=\+1 why=the operator: a merge he asked for is not news$" "$LLOG"'
check "L1 the correction is logged before the outcome" '[ "$(grep -c " correction brief-operator " "$LLOG")" = 1 ]'
check "L1 history diff written" 'ls "$ORC"/learned/history/*-brief-operator.diff >/dev/null 2>&1 && grep -q "^+A merge the operator asked" "$ORC"/learned/history/*-brief-operator.diff'
check "L1 no replays/ in the live dir" '[ ! -e "$LIVE/brief-operator/replays" ]'

# ═════ L2: an edit that breaks a replay is rejected; the old skill stays ═════
LIVE_SHA=$(sha "$LIVE/brief-operator/SKILL.md"); LSK_SUM=$(tree_sum "$LSK"); MK_BEFORE=$(stat -c %Y "$LIVE/brief-operator/.archie-learned")
OUT=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN edit brief-operator "$T/bad.md" --why "report the green days"); RC=$?
eq "L2 rc" "$RC" 1
eq "L2 the live SKILL.md is byte-identical" "$(sha "$LIVE/brief-operator/SKILL.md")" "$LIVE_SHA"
eq "L2 the learned dir is byte-identical" "$(tree_sum "$LSK")" "$LSK_SUM"
eq "L2 the marker did not move" "$(stat -c %Y "$LIVE/brief-operator/.archie-learned")" "$MK_BEFORE"
check "L2 rejected log line names the failed case ($(tail -1 "$LLOG"))" \
  'grep -qE "^[0-9TZ:-]+ rejected brief-operator kind=edit why=report the green days failed=.*brief-operator/01-merge-decision expected=send got=silent" "$LLOG"'
check "L2 the FAIL lines are printed" 'grep -q "^FAIL brief-operator/03-initiative-moved expected=send got=silent" <<<"$OUT"'
check "L2 no promoted line for it" '! grep -q "promoted brief-operator kind=edit" "$LLOG"'

# ═════ L2b: a promote killed between its learned-dir mvs loses nothing ═══════
# The only learned copy (with the 04 correction case) is left at .brief-operator.old.
mv "$LSK/brief-operator" "$LSK/.brief-operator.old"
ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN edit brief-operator "$T/bad.md" --why "report the green days" >/dev/null 2>&1
eq "L2b the learned copy is put back, correction case included" "$(tree_sum "$LSK")" "$LSK_SUM"
check "L2b no .old left behind" '[ ! -e "$LSK/.brief-operator.old" ]'

# ═════ L3: the model fails -> rejected, old kept ═════════════════════════════
OUT=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/exit1" LEARN edit brief-operator "$T/patched.md" --why "same text again"); RC=$?
eq "L3 rc" "$RC" 1
eq "L3 the live SKILL.md is untouched" "$(sha "$LIVE/brief-operator/SKILL.md")" "$LIVE_SHA"
check "L3 got=none rejection" 'grep -qE " rejected brief-operator kind=edit why=same text again failed=.*got=none" "$LLOG"'

# ═════ L4: refusals are rc 2 with no write ═══════════════════════════════════
mkdir -p "$T/cases/09-maybe"; cp "$T/cases/04-correction/"* "$T/cases/09-maybe/"; echo 'VERDICT: maybe' > "$T/cases/09-maybe/expected"
mkdir -p "$T/cases/08-short"; cp "$T/cases/04-correction/input.md" "$T/cases/08-short/"
sed 's/^name: brief-operator$/name: brief-larry/' "$T/patched.md" > "$T/renamed.md"
grep -v '^name:' "$T/patched.md" > "$T/noname.md"
BEFORE=$(tree_sum "$ORC" "$H/logs" "$H/state")
l4() { # l4 <label> <args…>
  local lbl="$1"; shift
  OUT=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN "$@" 2>&1); RC=$?
  [ "$RC" = 2 ] && [ -n "$OUT" ] && ok || bad "L4 $lbl: want rc 2 and a reason, got rc=$RC [$OUT]"
}
l4 "unknown skill"     correct nope "$T/patched.md" --case "$T/cases/04-correction" --why x
check "L4 unknown skill says propose" 'grep -q propose <<<"$OUT"'
l4 "correct, no case"  correct brief-operator "$T/patched.md" --why x
l4 "../ name"          correct ../brief-operator "$T/patched.md" --case "$T/cases/04-correction" --why x
l4 "expected outside verdicts" correct brief-operator "$T/patched.md" --case "$T/cases/09-maybe" --why x
l4 "case missing files" edit brief-operator "$T/patched.md" --case "$T/cases/08-short" --why x
l4 "renamed skill"     edit brief-operator "$T/renamed.md" --why x
l4 "no name:"          edit brief-operator "$T/noname.md" --why x
l4 "no why"            edit brief-operator "$T/patched.md"
l4 "why over 300"      edit brief-operator "$T/patched.md" --why "$(printf 'x%.0s' $(seq 1 301))"
l4 "missing file"      edit brief-operator "$T/nope.md" --why x
l4 "unknown verb"      frobnicate
eq "L4 nothing was written by a refusal" "$(tree_sum "$ORC" "$H/logs" "$H/state")" "$BEFORE"
# A skill with no replays anywhere is refused, never promoted ungated.
mkdir -p "$LIVE/orphan"; printf -- '---\nname: orphan\ndescription: x\nverdicts: a | b\n---\n# o\n' > "$LIVE/orphan/SKILL.md"
l4 "no replays to gate on" edit orphan "$LIVE/orphan/SKILL.md" --why x
check "L4 says no replays" 'grep -q "no replays" <<<"$OUT"'
scratch_rm "$LIVE/orphan" || exit 1
# The dedupe lock: another edit is running -> rc 3, no wait.
mkdir -p "$H/locks"
( exec 8>"$H/locks/archie-learn.lock"; flock -n 8; exec sleep 5 ) &
LPID=$!; wait_holder "$LPID"
S0=$(date +%s)
ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN edit brief-operator "$T/patched.md" --why x >/dev/null 2>&1; RC=$?
eq "L4 a held lock is rc 3" "$RC" 3
check "L4 the held lock is not waited on" '[ $(( $(date +%s) - S0 )) -lt 3 ]'
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null

# A promote that cannot write is promote-failed, never promoted (D9).
reset_hub
mkdir -p "$ORC/learned"; : > "$ORC/learned/skills"
OUT=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN edit brief-operator "$T/patched.md" --why "cannot land"); RC=$?
eq "L4 promote failure rc" "$RC" 1
check "L4 promote-failed logged, not promoted" 'grep -q " promote-failed brief-operator " "$LLOG" && ! grep -q " promoted brief-operator " "$LLOG"'
eq "L4 the live SKILL.md is untouched on a failed promote" "$(sha "$LIVE/brief-operator/SKILL.md")" "$(sha "$DIR/orchestrator/skills/brief-operator/SKILL.md")"
check "L4 no marker on a failed promote" '[ ! -e "$LIVE/brief-operator/.archie-learned" ]'

# ═════ L5: the production model path, end to end through agent-call ═════════
reset_hub; scratch_rm "$T/agentcalls" || exit 1; : > "$T/ac.judge"
OUT=$(LEARN correct brief-operator "$T/patched.md" --case "$T/cases/04-correction" --why "through the metered model"); RC=$?
eq "L5 rc ($OUT)" "$RC" 0
eq "L5 one metered call per case" "$(wc -l < "$T/agentcalls" 2>/dev/null | tr -d ' ')" 4
check "L5 stage archie-replay on the routed model, lane archie-learn" \
  '[ "$(cut -d"|" -f1 "$T/agentcalls" | cut -d" " -f1-4 | sort -u)" = "archie-replay fleet test-model 180" ] && [ "$(cut -d"|" -f2 "$T/agentcalls" | sort -u)" = archie-learn ]'
eq "L5 the live SKILL.md is the patched file" "$(sha "$LIVE/brief-operator/SKILL.md")" "$(sha "$T/patched.md")"
OUT=$(LEARN edit brief-operator "$T/bad.md" --why "bad through the metered model"); RC=$?
eq "L5 the bad edit is rejected through the live model" "$RC" 1
eq "L5 the live SKILL.md is still the patched file" "$(sha "$LIVE/brief-operator/SKILL.md")" "$(sha "$T/patched.md")"
N5=$(wc -l < "$T/agentcalls" | tr -d ' ')
LEARN edit brief-operator "$T/bad.md" --why "the same bad edit again" >/dev/null; RC=$?
eq "L5 a retried edit is rejected again" "$RC" 1
eq "L5 a retried edit pays nothing (the ledger answers)" "$(wc -l < "$T/agentcalls" | tr -d ' ')" "$N5"
rm -f "$T/ac.judge"

# ═════ M: the replay model's spend ledger ════════════════════════════════════
# As Archie runs it: inside an orchestrator turn, whose guard family and ticket are in the env.
RM() { env ARCHIE_LEARN_FIXTURE="$T/fx.sh" AGENT_CALL_GUARD_STAGE=orchestrator AGENT_CALL_TICKET=turn-1 "$H/bin/archie-replay-model.sh" "$@"; }
calls() { wc -l < "$T/agentcalls" 2>/dev/null | tr -d ' ' || echo 0; }
CACHE="$H/state/archie-learn/replay-cache"
scratch_rm "$T/agentcalls" || exit 1; : > "$T/agentcalls"
mkdir -p "$T/m"; C1="$DIR/orchestrator/skills/brief-operator/replays/01-merge-decision"
printf 'prompt one\n' > "$T/m/p1"; printf 'prompt two\n' > "$T/m/p2"; printf 'prompt three\n' > "$T/m/p3"
printf 'Send it.\nVERDICT: send\n' > "$T/ac.text"
R1=$(RM "$T/m/p1" "$C1"); RC=$?
eq "M1 rc" "$RC" 0; eq "M1 one call" "$(calls)" 1; eq "M1 the reply" "$R1" $'Send it.\nVERDICT: send'
check "M1 ledger ok" '[ "$(jq -r .outcome "$CACHE"/*.json 2>/dev/null | sort -u)" = ok ]'
printf 'a different answer\n' > "$T/ac.text"
R1b=$(RM "$T/m/p1" "$C1"); RC=$?
eq "M1 rerun: no call" "$(calls)" 1; eq "M1 rerun: the stored reply" "$R1b" "$R1"; eq "M1 rerun rc" "$RC" 0
: > "$T/ac.blank"
R2=$(RM "$T/m/p2" "$C1"); RC=$?
eq "M2 blank: rc 0" "$RC" 0; eq "M2 blank: empty stdout" "$R2" ""; eq "M2 one call" "$(calls)" 2
check "M2 ledger empty" 'grep -l "\"empty\"" "$CACHE"/*.json >/dev/null 2>&1'
RM "$T/m/p2" "$C1" >/dev/null; eq "M2 rerun: no call" "$(calls)" 2
rm -f "$T/ac.blank"
echo 75 > "$T/ac.rc"
RM "$T/m/p3" "$C1" >/dev/null; RC=$?
check "M3 refusal: rc != 0" '[ "$RC" != 0 ]'
P3F=$(grep -l '"failed"' "$CACHE"/*.json 2>/dev/null | head -1)
eq "M3 refusal hands the attempt back" "$(jq -r .attempts "$P3F" 2>/dev/null)" 0
echo 1 > "$T/ac.rc"
RM "$T/m/p3" "$C1" >/dev/null; RM "$T/m/p3" "$C1" >/dev/null
eq "M3 two billed failures" "$(jq -r .attempts "$P3F" 2>/dev/null)" 2
N3=$(calls)
RM "$T/m/p3" "$C1" >/dev/null; RC=$?
eq "M3 at the cap: rc 1" "$RC" 1; eq "M3 at the cap: no call" "$(calls)" "$N3"
rm -f "$T/ac.rc"
: > "$T/noroute"; printf 'prompt four\n' > "$T/m/p4"
RM "$T/m/p4" "$C1" >/dev/null; RC=$?
eq "M4 no route: rc 75" "$RC" 75; eq "M4 no route: no call" "$(calls)" "$N3"
rm -f "$T/noroute"
ARCHIE_REPLAY_MAX_USD=0 RM "$T/m/p4" "$C1" >/dev/null; RC=$?
eq "M4 USD 0 is off: rc 75" "$RC" 75; eq "M4 USD 0: no call" "$(calls)" "$N3"
check "M4 argv: stage archie-replay, routed model, lane, fp, budget; the turn's guard stage and ticket reset" \
  'head -1 "$T/agentcalls" | grep -qE "^archie-replay fleet test-model 180 [^ ]+ @[^|]+\|archie-learn\|archie-replay:[0-9a-f]{64}\|0\.05\|archie-replay\|$"'
NC=$(grep -v '^[[:space:]]*#' "$DIR/bin/archie-replay-model.sh" | grep -c 'claude-')
eq "M4 no claude- literal in the replay model" "$NC" 0
check "M4 the guard reads a real file" '[ -s "$DIR/bin/archie-replay-model.sh" ] && grep -q "lane_role_model stage.archie-replay" "$DIR/bin/archie-replay-model.sh"'

# ═════ S1: a deploy never reverts a learned skill ════════════════════════════
mkdir -p "$T/s1/brief-operator" "$T/s1/cost-watch"
echo "learned on the hub" > "$T/s1/brief-operator/SKILL.md"; : > "$T/s1/brief-operator/.archie-learned"
echo "stale" > "$T/s1/cost-watch/SKILL.md"
OUT=$(HARNESS_CHECKOUT="$DIR" SKILLS_SUBDIR=orchestrator/skills CLAUDE_SKILLS_DIR="$T/s1" HARNESS_LOG_DIR="$T" "$DIR/bin/sync-skills.sh" 2>&1)
eq "S1 learned SKILL.md kept" "$(cat "$T/s1/brief-operator/SKILL.md")" "learned on the hub"
check "S1 says skip (learned here) ($OUT)" 'grep -qx "skip (learned here): brief-operator" <<<"$OUT"'
eq "S1 an unmarked skill is still deployed" "$(sha "$T/s1/cost-watch/SKILL.md")" "$(sha "$DIR/orchestrator/skills/cost-watch/SKILL.md")"
check "S1 logged" 'grep -q "SKIP skill brief-operator — learned on this box" "$T/agent-rules.log"'

# ═════ S2: an upstreamed learned skill takes repo deploys again ══════════════
mkdir -p "$T/s2/brief-operator"; cp "$DIR/orchestrator/skills/brief-operator/SKILL.md" "$T/s2/brief-operator/"; : > "$T/s2/brief-operator/.archie-learned"
SYNC2() { HARNESS_CHECKOUT="$T/s2src" SKILLS_SUBDIR=skills CLAUDE_SKILLS_DIR="$T/s2" HARNESS_LOG_DIR="$T" "$DIR/bin/sync-skills.sh" "$@" 2>&1; }
mkdir -p "$T/s2src/skills"; cp -r "$DIR/orchestrator/skills/brief-operator" "$T/s2src/skills/"
OUT=$(SYNC2 --check)
check "S2 --check: would deploy, marker untouched ($OUT)" 'grep -qx "would deploy (upstreamed, learned marker cleared): brief-operator" <<<"$OUT" && [ -f "$T/s2/brief-operator/.archie-learned" ]'
OUT=$(SYNC2)
check "S2 the repo matches the learned copy: marker cleared ($OUT)" '[ ! -e "$T/s2/brief-operator/.archie-learned" ] && grep -qx "upstreamed: brief-operator" <<<"$OUT" && grep -qx "deployed: brief-operator" <<<"$OUT"'
check "S2 logged" 'grep -q "skill brief-operator upstreamed" "$T/agent-rules.log"'
echo "A later repo fix." >> "$T/s2src/skills/brief-operator/SKILL.md"
SYNC2 >/dev/null
eq "S2 a later repo change deploys" "$(sha "$T/s2/brief-operator/SKILL.md")" "$(sha "$T/s2src/skills/brief-operator/SKILL.md")"

# ═════ P: propose, then adopt ════════════════════════════════════════════════
reset_hub
mkskill() { # mkskill <dir> <name> <ncases>
  mkdir -p "$1/replays"
  printf -- '---\nname: %s\ndescription: Close out a rollout once every box reports the new sha.\nverdicts: yes | no\n---\n\n# %s\n\nSay yes.\n' "$2" "$2" > "$1/SKILL.md"
  local i; for i in $(seq 1 "$3"); do
    mkdir -p "$1/replays/0$i-c"; echo "case $i" > "$1/replays/0$i-c/input.md"
    echo "VERDICT: yes" > "$1/replays/0$i-c/expected"; printf 'Yes.\nVERDICT: yes\n' > "$1/replays/0$i-c/recorded.txt"
  done
}
mkskill "$T/p/demo-skill" demo-skill 2
OUT=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN propose demo-skill "$T/p/demo-skill"); RC=$?
eq "P1 rc" "$RC" 0
check "P1 the proposal is staged" '[ -f "$ORC/learned/proposals/demo-skill/SKILL.md" ] && [ -d "$ORC/learned/proposals/demo-skill/replays/02-c" ]'
check "P1 proposing never installs" '[ ! -e "$LIVE/demo-skill" ] && [ ! -e "$LSK/demo-skill" ]'
check "P1 asks the operator ($OUT)" 'grep -qx "Proposed skill demo-skill: Close out a rollout once every box reports the new sha. Say yes and I'"'"'ll adopt it." <<<"$OUT"'
check "P1 logged" 'grep -qE " proposed demo-skill cases=2$" "$LLOG"'
mkskill "$T/p/demo-one" demo-one 1
LEARN propose demo-one "$T/p/demo-one" >/dev/null 2>&1; RC=$?
eq "P1 one case: rc 1" "$RC" 1
check "P1 one case: nothing staged, rejection logged" '[ ! -e "$ORC/learned/proposals/demo-one" ] && grep -q " proposal-rejected demo-one " "$LLOG"'
LEARN propose brief-operator "$T/p/demo-skill" >/dev/null 2>&1; eq "P1 an existing name is refused" "$?" 2
OUT=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" LEARN adopt demo-skill); RC=$?
eq "P2 rc ($OUT)" "$RC" 0
check "P2 installed live with the marker" '[ -f "$LIVE/demo-skill/SKILL.md" ] && [ -f "$LIVE/demo-skill/.archie-learned" ] && [ ! -e "$LIVE/demo-skill/replays" ]'
check "P2 in the learned store with its replays" '[ -f "$LSK/demo-skill/replays/01-c/expected" ]'
check "P2 the proposal is consumed" '[ ! -e "$ORC/learned/proposals/demo-skill" ]'
check "P2 logged" 'grep -qE " adopted demo-skill cases=2$" "$LLOG"'
LEARN adopt nothing-here >/dev/null 2>&1; eq "P2 adopting no proposal is refused" "$?" 2
# X1 (part): edits and adoptions write nothing under the harness or the repo.
check "X1 nothing new under \$H/bin" '[ -z "$(find "$H/bin" -newer "$STAMP0" ! -type d 2>/dev/null)" ]'

# ═════ C2: a corrected fact is logged, no gate ═══════════════════════════════
OUT=$(LEARN correct facts --why "the operator prefers one decision per message"); RC=$?
eq "C2 rc" "$RC" 0
check "C2 log line" 'grep -qE "^[0-9TZ:-]+ correction facts why=the operator prefers one decision per message$" "$LLOG"'
check "C2 the soul tells Archie to use it" '[ "$(grep -c "archie-learn.sh correct" <(cat "$DIR"/prompts/archie-soul.d/*.md))" -ge 1 ]'
check "C2 the soul keeps STATE.md short" 'grep -q "STATE.md" <(cat "$DIR"/prompts/archie-soul.d/*.md) && grep -q "facts.md" <(cat "$DIR"/prompts/archie-soul.d/*.md)'

# ═════ F1: facts.md rides in the turn briefing ═══════════════════════════════
FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$DIR/bin/orchestrate.sh")
mkdir -p "$T/f1"
v2() { env HARNESS="$H" ARCHIE_ORC_DIR="$T/f1" TEXT=hi META_TRANSPORT=telegram ORIGIN="" bash -c "$FN"$'\n''compose_v2_prompt' 2>/dev/null; }
echo "the operator hates bullet walls" > "$T/f1/facts.md"
P=$(v2)
FL=$(grep -n '^=== FACTS (facts.md, yours to edit) ===$' <<<"$P" | cut -d: -f1)
SL=$(grep -n '^=== STATE.md (working memory) ===$' <<<"$P" | cut -d: -f1)
RL=$(grep -n '^=== RECENT CONVERSATION' <<<"$P" | cut -d: -f1)
check "F1 the facts header sits after STATE.md and before the conversation ($FL/$SL/$RL)" '[ -n "$FL" ] && [ -n "$SL" ] && [ -n "$RL" ] && [ "$FL" -gt "$SL" ] && [ "$FL" -lt "$RL" ]'
check "F1 the fact text follows the header" '[ "$(sed -n "$((FL+1))p" <<<"$P")" = "the operator hates bullet walls" ]'
check "F1 no cut line for a short file" '! grep -q "cut at 8000 bytes" <<<"$P"'
rm -f "$T/f1/facts.md"; P=$(v2)
check "F1 absent file: no FACTS section" '! grep -q "=== FACTS" <<<"$P" && grep -q "=== STATE.md" <<<"$P"'
head -c 9000 /dev/zero | tr '\0' 'f' > "$T/f1/facts.md"; P=$(v2)
check "F1 a 9000-byte file is cut, visibly" 'grep -qx "\[facts.md cut at 8000 bytes\]" <<<"$P" && [ "$(grep -o "f*" <<<"$P" | awk "length > 7000" | head -1 | wc -c)" = 8001 ]'

# ═════ U: unused skills ══════════════════════════════════════════════════════
reset_hub
for s in cost-watch steward-initiative rollout-review; do mkdir -p "$LIVE/$s"; cp "$DIR/orchestrator/skills/$s/SKILL.md" "$LIVE/$s/"; done
UL="$H/state/archie-learn/skill-usage.tsv"; mkdir -p "$(dirname "$UL")"
printf 'brief-operator\t%s\t\ncost-watch\t%s\t\nsteward-initiative\t%s\t\n' \
  "$(iso $((NOW - 40*86400)))" "$(iso $((NOW - 40*86400)))" "$(iso $((NOW - 3*86400)))" > "$UL"
tu() { # tu <type> <ts> <tool name> <skill> — one transcript line
  jq -nc --arg ty "$1" --arg t "$2" --arg n "$3" --arg s "$4" \
    '{type: $ty, timestamp: $t, message: {role: "assistant", content: [{type: "text", text: "ok"}, {type: "tool_use", id: "x", name: $n, input: {skill: $s}}]}}'
}
{
  tu assistant "$(date -u -d "@$((NOW - 5*86400))" +%Y-%m-%dT%H:%M:%S.123Z)" Skill brief-operator
  # A user line that carries the raw "name":"Skill" text, and a non-Skill tool with a skill field.
  jq -nc --arg t "$(iso $((NOW - 2*86400)))" '{type: "user", timestamp: $t, toolUseResult: {name: "Skill", input: {skill: "cost-watch"}}, message: {role: "user", content: "please use skill cost-watch"}}'
  tu assistant "$(iso $((NOW - 2*86400)))" Bash cost-watch
  # One message, two tool_uses: the Skill call passes the cheap grep, so only
  # the name filter keeps the Bash call's skill field from counting.
  jq -nc --arg t "$(iso $((NOW - 6*86400)))" '{type: "assistant", timestamp: $t, message: {content: [
    {type: "tool_use", name: "Skill", input: {skill: "brief-operator"}}, {type: "tool_use", name: "Bash", input: {skill: "cost-watch"}}]}}'
  echo '{"type":"assistant","name":"Skill", this line is not json'
  tu assistant "$(iso $((NOW - 20*86400)))" Skill brief-operator
} > "$T/tx/session-a.jsonl"
OUT=$(LEARN unused); RC=$?
eq "U rc" "$RC" 0
eq "U1/U2/U3 only cost-watch is flagged" "$OUT" "UNUSED cost-watch last_used=never"
eq "U2 last_used is the newest Skill invocation" "$(awk -F'\t' '$1=="brief-operator"{print $3}' "$UL")" "$(iso $((NOW - 5*86400)))"
eq "U3 a newly seen skill gets first_seen now" "$(awk -F'\t' '$1=="rollout-review"{print $2}' "$UL")" "$(iso "$NOW")"
eq "U a user line or a Bash tool is not an invocation" "$(awk -F'\t' '$1=="cost-watch"{print $3}' "$UL")" ""
check "U nothing deleted" '[ -f "$LIVE/cost-watch/SKILL.md" ]'
# The settings row is honoured: a 10-day-old invocation is fresh at 30, stale at 7.
printf 'brief-operator\t%s\t%s\n' "$(iso $((NOW - 40*86400)))" "$(iso $((NOW - 10*86400)))" > "$UL"
scratch_rm "$T/tx" || exit 1; mkdir -p "$T/tx"
OUT=$(LEARN unused); check "U days=30: a 10-day-old invocation is not flagged ($OUT)" '! grep -q "UNUSED brief-operator" <<<"$OUT"'
OUT=$(ARCHIE_SKILL_UNUSED_DAYS=7 LEARN unused)
check "U days=7: the same invocation is flagged ($OUT)" 'grep -qx "UNUSED brief-operator last_used=$(iso $((NOW - 10*86400)))" <<<"$OUT"'
OUT=$(ARCHIE_SKILL_UNUSED_DAYS=0 LEARN unused)
check "U days=0 is out of range: the default, with a warn line" '! grep -q "UNUSED brief-operator" <<<"$OUT" && grep -q "warn: ARCHIE_SKILL_UNUSED_DAYS=0" "$LLOG"'
mkdir -p "$H/locks"
( flock -n 8 || exit 9; LEARN unused >/dev/null 2>&1; echo $? > "$T/u.rc" ) 8>"$H/locks/archie-learning.lock"
eq "U shares the report's lock: held = rc 3" "$(cat "$T/u.rc" 2>/dev/null)" 3

# ═════ W: the weekly report ══════════════════════════════════════════════════
reset_hub
for s in cost-watch; do mkdir -p "$LIVE/$s"; cp "$DIR/orchestrator/skills/$s/SKILL.md" "$LIVE/$s/"; done
# brief-operator was learned here and differs from the repo; cost-watch carries a
# marker but the repo already has its SKILL.md byte for byte (upstreamed), so
# the report must not call it "not in the repo yet".
: > "$LIVE/brief-operator/.archie-learned"; echo "Learned on the hub." >> "$LIVE/brief-operator/SKILL.md"
mkdir -p "$SRC/cost-watch"; cp "$DIR/orchestrator/skills/cost-watch/SKILL.md" "$SRC/cost-watch/"; : > "$LIVE/cost-watch/.archie-learned"
printf 'brief-operator\t%s\t%s\ncost-watch\t%s\t\n' "$(iso $((NOW - 60*86400)))" "$(iso $((NOW - 1*86400)))" "$(iso $((NOW - 40*86400)))" > "$UL"
cat > "$H/logs/outcome-rework-rollup.csv" <<'EOF'
week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source
2026-W39,cromford,40,7,17.5,4,1,25.0,0,weekly
2026-W40,cromford,50,9,18.0,5,0,0.0,0,weekly
2026-W40,project-3,3,0,0.0,0,0,-,0,weekly
EOF
cat > "$H/logs/archie.log" <<'EOF'
2026-09-27T23:45:00Z due=5 checked=9 beats=0 model_calls=0 skipped=0
2026-09-29T07:00:01Z due=4 checked=4 beats=1 model_calls=1 skipped=0
2026-10-02T07:00:01Z due=4 checked=4 beats=0 model_calls=0 skipped=0
2026-10-02T07:15:00Z warn: ARCHIE_MAX_PER_TICK=99 is outside 1..20; using the default 3
2026-10-05T07:00:01Z due=1 checked=1 beats=0 model_calls=0 skipped=0
EOF
cat > "$LLOG" <<'EOF'
2026-09-27T10:00:00Z correction facts why=outside the week
2026-09-29T10:00:00Z correction facts why=the operator prefers numbers
2026-09-30T10:00:00Z correction brief-operator why=a merge he asked for is not news
2026-09-30T10:00:01Z promoted brief-operator kind=correction cases=+1 why=a merge he asked for is not news
2026-10-01T10:00:00Z rejected brief-operator kind=edit why=report green days failed=FAIL brief-operator/01-merge-decision expected=send got=silent
2026-10-05T10:00:00Z correction facts why=next week
EOF
echo '{"usd":3.10,"calls":20}' > "$T/spend.orc-monitor.json"
echo '{"usd":0.40,"calls":2}' > "$T/spend.archie.json"
scratch_rm "$T/beats.jsonl" || exit 1; scratch_rm "$T/reqlog" || exit 1
WK="$H/state/archie-learn/weekly"
LEARN report >/dev/null 2>&1; RC=$?
eq "W1 rc" "$RC" 0
eq "W1 one beat" "$(wc -l < "$T/beats.jsonl" 2>/dev/null | tr -d ' ')" 1
B=$(head -1 "$T/beats.jsonl" 2>/dev/null); L=$(jq -r .line <<<"$B" 2>/dev/null)
check "W1 an Archie Telegram message keyed by the week, not a fleet_alert ($B)" 'jq -e ".akey == \"archie-learning:2026-W40\" and (has(\"kind\") | not)" <<<"$B" >/dev/null'
check "W1 names the week" 'grep -q "2026-W40 (2026-09-28 to 2026-10-04)" <<<"$L"'
check "W1 rework rate ($L)" 'grep -qx "Rework rate 18.0% (cromford, week 2026-W40)" <<<"$L"'
check "W1 overrule rate" 'grep -qx "Overrule rate 10% (2 of 20 turns)" <<<"$L"'
check "W1 cost per check" 'grep -qx "Cost per check \$0.05 (8 checks)" <<<"$L"'
check "W1 skill counts" 'grep -qx "Skills: 1 promoted, 1 rejected, 0 proposed, 0 adopted" <<<"$L"'
check "W1 prune candidates" 'grep -qx "Unused 30+ days, prune candidates: cost-watch" <<<"$L"'
check "W1 diverged skills, the upstreamed one left out" 'grep -qx "Learned here, not in the repo yet: brief-operator" <<<"$L"'
check "W1 the usage source is visible" 'grep -qE "^Skill usage: [0-9]+ invocations parsed" <<<"$L"'
check "W1 no em dash" '! grep -q "—" <<<"$L"'
check "W1 the spend reads cover the week" 'grep -q "lane=orc-monitor&since=2026-09-28T00:00:00Z&until=2026-10-04T23:59:59Z" "$T/reqlog" && grep -q "lane=archie&stage=archie&since=2026-09-28T00:00:00Z&until=2026-10-04T23:59:59Z" "$T/reqlog"'
check "W1 the report file and the sent marker" '[ -s "$WK/2026-W40.md" ] && [ -f "$WK/2026-W40.sent" ] && [ "$(cat "$WK/2026-W40.md")" = "$L" ]'
check "W1 logged" 'grep -q " report 2026-W40 sent" "$LLOG"'
LEARN report >/dev/null 2>&1
eq "W2 a rerun the same week sends nothing" "$(wc -l < "$T/beats.jsonl" | tr -d ' ')" 1
scratch_rm "$WK" || exit 1; echo 1 > "$T/beat.rc"
LEARN report >/dev/null 2>&1
check "W3 a failed beat: no .sent" '[ ! -e "$WK/2026-W40.sent" ] && [ "$(wc -l < "$T/beats.jsonl" | tr -d " ")" = 2 ] && grep -q " report 2026-W40 not sent" "$LLOG"'
rm -f "$T/beat.rc"
LEARN report >/dev/null 2>&1
check "W3 the next run sends" '[ -f "$WK/2026-W40.sent" ] && [ "$(wc -l < "$T/beats.jsonl" | tr -d " ")" = 3 ]'
scratch_rm "$WK" || exit 1; : > "$T/spend.down"; rm -f "$H/logs/outcome-rework-rollup.csv"
LEARN report >/dev/null 2>&1
L=$(tail -1 "$T/beats.jsonl" | jq -r .line)
check "W4 spend unreadable: not measured, never \$0 ($L)" 'grep -q "^Overrule rate not measured" <<<"$L" && grep -q "^Cost per check not measured" <<<"$L" && ! grep -q "\$0" <<<"$L"'
check "W4 rework file missing: not measured" 'grep -q "^Rework rate not measured" <<<"$L"'
rm -f "$T/spend.down"; echo '{"usd":0,"calls":0}' > "$T/spend.orc-monitor.json"; scratch_rm "$WK" || exit 1
LEARN report >/dev/null 2>&1; L=$(tail -1 "$T/beats.jsonl" | jq -r .line)
check "W4 zero turns: not measured, never 0% ($L)" 'grep -q "^Overrule rate not measured (no answered turns" <<<"$L"'
scratch_rm "$WK" || exit 1; N=$(wc -l < "$T/beats.jsonl" | tr -d ' ')
ARCHIE_LEARN_ENABLED=0 LEARN report >/dev/null 2>&1
eq "W ARCHIE_LEARN_ENABLED=0 sends nothing" "$(wc -l < "$T/beats.jsonl" | tr -d ' ')" "$N"

# ═════ registrations ═════════════════════════════════════════════════════════
check "R the lane registry entry" 'jq -e ".id == \"archie-learn\" and .script == \"bin/archie-learn.sh\" and .scope == \"hub\" and .wired == true" "$DIR/catalog/lanes.d/archie-learn.json" >/dev/null'
check "R the unused-days knob is a settings row" 'jq -e "[.knobs[] | select(.env == \"ARCHIE_SKILL_UNUSED_DAYS\" and .default == 30 and .settable == true)] | length == 1" "$DIR/catalog/lanes.d/archie-learn.json" >/dev/null'
check "R the cron line runs the report behind the hub lease" 'grep -qE "^35 6 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/archie-learn.sh report" "$DIR/cron/lanes/725-archie-learn.cron"'
check "R the llm site" 'jq -e "[.sites[] | select(.id == \"archie-replay\" and .stage == \"archie-replay\" and .lane == \"archie-learn\" and .script == \"bin/archie-replay-model.sh\")] | length == 1" "$DIR/catalog/llm-sites.json" >/dev/null'
check "R the stage route seed carries no model literal" 'grep -A6 "SELECT .hub., NULL, .stage.archie-replay." "$DIR/worker/jobs/schema.sql" | grep -q "role = .stage.execute." && ! grep -A6 "stage.archie-replay" "$DIR/worker/jobs/schema.sql" | grep -q "claude-"'

# ═════ X: mutations of the shipped scripts (D1) ══════════════════════════════
# X-gate: without the gate's verdict, L2's bad edit would go live.
reset_hub
sed 's/^  if \[ "\$grc" != 0 \]; then$/  if false; then/' "$DIR/bin/archie-learn.sh" > "$H/bin/archie-learn-x.sh"
check "X-gate the gate line exists" '! cmp -s "$H/bin/archie-learn-x.sh" "$DIR/bin/archie-learn.sh"'
chmod +x "$H/bin/archie-learn-x.sh"
env ARCHIE_ORC_DIR="$ORC" ARCHIE_SKILLS_SRC="$SRC" ARCHIE_NOW="$NOW" ARCHIE_LEARN_FIXTURE="$T/fx.sh" ARCHIE_REPLAY_MODEL_CMD="$T/stubs/judge" \
  "$H/bin/archie-learn-x.sh" edit brief-operator "$T/bad.md" --why mutant >/dev/null 2>&1
check "X-gate the mutant promotes the bad edit (so L2 is a real guard)" '[ "$(sha "$LIVE/brief-operator/SKILL.md")" = "$(sha "$T/bad.md")" ]'
# X-ledger: without the ledger read, M1's rerun would pay again.
sed '/^# >>> ledger read/,/^# <<< ledger read/d' "$DIR/bin/archie-replay-model.sh" > "$H/bin/archie-replay-model-x.sh"
check "X-ledger the ledger-read markers exist" '! cmp -s "$H/bin/archie-replay-model-x.sh" "$DIR/bin/archie-replay-model.sh"'
chmod +x "$H/bin/archie-replay-model-x.sh"; : > "$T/agentcalls"; printf 'prompt x\n' > "$T/m/px"
for _ in 1 2; do env ARCHIE_LEARN_FIXTURE="$T/fx.sh" "$H/bin/archie-replay-model-x.sh" "$T/m/px" "$C1" >/dev/null 2>&1; done
eq "X-ledger the mutant calls twice (so M1 is a real guard)" "$(calls)" 2
# X-sync: without the marker skip, S1's learned skill would be overwritten.
sed '/^  # >>> archie learned/,/^  # <<< archie learned/d' "$DIR/bin/sync-skills.sh" > "$T/sync-x.sh"
check "X-sync the marker-skip markers exist" '! cmp -s "$T/sync-x.sh" "$DIR/bin/sync-skills.sh"'
HARNESS_CHECKOUT="$DIR" SKILLS_SUBDIR=orchestrator/skills CLAUDE_SKILLS_DIR="$T/s1" HARNESS_LOG_DIR="$T" bash "$T/sync-x.sh" >/dev/null 2>&1
check "X-sync the mutant overwrites the learned skill (so S1 is a real guard)" '[ "$(cat "$T/s1/brief-operator/SKILL.md")" != "learned on the hub" ]'
rm -f "$H/bin/archie-learn-x.sh" "$H/bin/archie-replay-model-x.sh"

# ═════ X1: no repo or harness code was written ═══════════════════════════════
eq "X1 the repo's git status is unchanged" "$(git -C "$DIR" status --porcelain 2>/dev/null)" "$GIT_BEFORE"

echo "archie-learning: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
