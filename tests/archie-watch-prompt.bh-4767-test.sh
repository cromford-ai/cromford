#!/bin/bash
# tests/archie-watch-prompt.bh-4767-test.sh — BH-4767 (slice 4 of #4760): the
# whole-factory watch prompt catalog/prompts/archie-watch.md, its six
# archie.watch.* threshold seeds, and its replay cases.
#
#   W1a  the prompt names each of the six archie.watch.<key> thresholds
#   W1b  schema.sql seeds each key in exactly one settings statement, with a
#        non-empty value and note
#   W1c  the seed block sits after the stage.archie seed and above BH-4065, in
#        schema.sql and in its fragment schema.d/0002-base-rest.sql
#   W2a  the first line is the prompt's title
#   W2b  the output format and its fixed words are present
#   W2c  the rule for an absent threshold key is present
#   W2d  no checklist line carries a bare number besides its list index
#   W2e  the unreadable line names check.metric_unreadable and an archie-check
#        heading that exists
#   R    bin/archie-skill-replay.sh passes the three archie-watch cases
#   V1   no em or en dash in the prompt or the recorded replies
#
# The replay case DRIVES bin/archie-skill-replay.sh with its default recorded
# replayer. Nothing here calls a vendor.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-watch-prompt.bh-4767-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PROMPT="$REPO/catalog/prompts/archie-watch.md"
CHECK="$REPO/catalog/prompts/archie-check.md"
SCHEMA="$REPO/worker/jobs/schema.sql"
FRAG="$REPO/worker/jobs/schema.d/0002-base-rest.sql"
SKILL="$REPO/catalog/prompts/replays/archie-watch"
KEYS="approved_idle_min build_fail_pct build_fail_min_n lane_silent_cadences spend_pace_pct quota_repeat_n"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -s "$PROMPT" ] || bad "W0 ${PROMPT#"$REPO"/} is missing"

# --- W1a the prompt names the six thresholds ----------------------------------
for k in $KEYS; do
  if grep -qF "archie.watch.$k" "$PROMPT"; then ok; else bad "W1a prompt does not name archie.watch.$k"; fi
done

# --- W1b one settings statement per key, value and note non-empty -------------
# A statement is one line here: INSERT OR IGNORE INTO settings (...) VALUES ('k','v','note',...);
for k in $KEYS; do
  n=$(grep -c "^INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie\.watch\.$k'," "$SCHEMA")
  any=$(grep -c "'archie\.watch\.$k'" "$SCHEMA")
  if [ "$n" != 1 ] || [ "$any" != 1 ]; then bad "W1b archie.watch.$k: $n statements, $any mentions in schema.sql (want 1, 1)"; continue; fi
  tuple=$(grep "^INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('archie\.watch\.$k'," "$SCHEMA" \
    | python3 -c '
import re, sys
line = sys.stdin.read()
m = re.search(r"VALUES \((.*)\);\s*$", line)
vals = re.findall(r"\x27((?:[^\x27]|\x27\x27)*)\x27", m.group(1)) if m else []
print("\t".join(vals))')
  IFS=$'\t' read -r key val note actor _ <<<"$tuple"
  if [ "$key" = "archie.watch.$k" ] && [ -n "$val" ] && [ -n "$note" ] && [[ $note == BH-4760:* ]] && [ "$actor" = seed ]; then ok
  else bad "W1b archie.watch.$k tuple: key=$key val=$val actor=$actor note=$note"; fi
done

# --- W1c block position: after stage.archie, above BH-4065 --------------------
for f in "$SCHEMA" "$FRAG"; do
  lb=$(grep -n '^-- ── BH-4760: Archie watch thresholds' "$f" | head -1 | cut -d: -f1)
  la=$(grep -n "AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.archie');" "$f" | head -1 | cut -d: -f1)
  lr=$(grep -n '^-- ── BH-4065' "$f" | head -1 | cut -d: -f1)
  if [ -n "$lb" ] && [ -n "$la" ] && [ -n "$lr" ] && [ "$lb" -gt "$la" ] && [ "$lb" -lt "$lr" ]; then ok
  else bad "W1c $(basename "$f"): block=${lb:-none} stage.archie=${la:-none} BH-4065=${lr:-none}"; fi
  # every seed line follows the block comment and precedes BH-4065
  for k in $KEYS; do
    lk=$(grep -n "'archie\.watch\.$k'" "$f" | head -1 | cut -d: -f1)
    if [ -n "$lk" ] && [ -n "$lb" ] && [ -n "$lr" ] && [ "$lk" -gt "$lb" ] && [ "$lk" -lt "$lr" ]; then ok
    else bad "W1c $(basename "$f"): archie.watch.$k at ${lk:-none}, outside the block"; fi
  done
done

# --- W2a title ----------------------------------------------------------------
if [ "$(head -1 "$PROMPT")" = '# Archie whole-factory watch (BH-4760)' ]; then ok
else bad "W2a first line: $(head -1 "$PROMPT")"; fi

# --- W2b output format words --------------------------------------------------
for w in 'FINDING:' 'CAUSE:' 'LEVER:' 'TICKET:' 'SAY: none|beat|report' 'CAUSE: unknown' 'LEVER: probe' 'NONE'; do
  if grep -qF -- "$w" "$PROMPT"; then ok; else bad "W2b prompt lacks '$w'"; fi
done

# --- W2c absent threshold: not judged, no number of your own -------------------
if grep -qiF 'is not judged' "$PROMPT" && grep -qiF 'never use a number of your own' "$PROMPT"; then ok
else bad "W2c the absent-threshold rule is missing"; fi

# --- W2d the checklist names keys, never a bare number -------------------------
# The checklist is the numbered list under "## Checklist".
sed -n '/^## Checklist/,/^## /p' "$PROMPT" | grep -E '^[0-9]+\. ' > "$T/checklist"
if [ "$(wc -l < "$T/checklist")" = 10 ]; then ok; else bad "W2d checklist has $(wc -l < "$T/checklist") items, want 10"; fi
if sed -E 's/^[0-9]+\. //' "$T/checklist" | grep -q '[0-9]'; then
  bad "W2d a checklist line carries a bare number: $(sed -E 's/^[0-9]+\. //' "$T/checklist" | grep '[0-9]')"
else ok; fi

# --- W2e unreadable metric line points at archie-check's section ---------------
if grep -F 'check.metric_unreadable' "$T/checklist" | grep -qF '## When the metric is unreadable' \
   && grep -qx '## When the metric is unreadable' "$CHECK"; then ok
else bad "W2e the unreadable line or the archie-check heading is missing"; fi

# --- R the replay cases pass through the real runner --------------------------
"$REPO/bin/archie-skill-replay.sh" --root "$REPO/catalog/prompts/replays" > "$T/out" 2>"$T/err"; RC=$?
if [ "$RC" = 0 ] && grep -qx 'PASS archie-watch/01-fixed-silently none' "$T/out" \
   && grep -qx 'PASS archie-watch/02-main-red-beat beat' "$T/out" \
   && grep -qx 'PASS archie-watch/03-unknown-cause-probe probe' "$T/out" \
   && tail -1 "$T/out" | grep -q ' 0 failed$'; then ok
else bad "R replay root: rc=$RC $(cat "$T/out" "$T/err")"; fi
if grep -qx 'prompt: prompts/archie-soul.d catalog/prompts/archie-watch.md' "$SKILL/SKILL.md" 2>/dev/null; then ok
else bad "R SKILL.md prompt: line"; fi

# --- V1 no em or en dash ------------------------------------------------------
for f in "$PROMPT" "$SKILL"/replays/*/recorded.txt; do
  [ -f "$f" ] || { bad "V1 $f is missing"; continue; }
  if grep -qP '[\x{2013}\x{2014}]' "$f"; then bad "V1 em or en dash in ${f#"$REPO"/}"; else ok; fi
done

echo "archie-watch-prompt: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
