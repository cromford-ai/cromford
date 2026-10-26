#!/bin/bash
# tests/prompt-build-note.bh-7971-test.sh — BH-7971 (BH-7940.3): a build's
# evidence.md ends with seven `PROMPT <kind>: …` lines that name the prompt
# version each kind ran under.
#
# It extracts the `# >>> prompt note` block from bin/lib/rb/result.sh (the
# production writer, right after evidence.md is written) and runs it on a
# sandbox $BUILD with a scratch HARNESS and checkout. No network, no vendor.
#
# Cases: project-head no-sources malformed-lines duplicate-first-wins
# no-repo-file evidence-kept lib-missing-not-fatal mutation-check
# Run from anywhere: tests/prompt-build-note.bh-7971-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "prompt-build-note.bh-7971: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

# The block, cut from the production file. Indented markers are allowed.
awk '/^[[:space:]]*# >>> prompt note/{f=1} f{print} /^[[:space:]]*# <<< prompt note/{exit}' \
  "$DIR/bin/lib/rb/result.sh" > "$T/block.sh"
grep -q 'prompt_note_append' "$T/block.sh" && grep -q '# <<< prompt note' "$T/block.sh" \
  || { bad "bin/lib/rb/result.sh has no '# >>> prompt note' block calling prompt_note_append"; done_; }
# The block sits right after the evidence.md write, inside the EVIDENCE branch.
awk '/printf .%s\\n. "\$EVIDENCE" > "\$BUILD\/evidence.md"/{w=NR} /# >>> prompt note/{if (w && NR == w+1) found=1} END{exit !found}' \
  "$DIR/bin/lib/rb/result.sh" && ok || bad "the prompt note block is not the line after the evidence.md write"

H="$T/h"; CK="$T/ck"
mkdir -p "$H/bin/lib" "$H/prompts/stages" "$H/state/prompts/demo-x" "$CK/rules"
scratch_install_closure bin/lib/prompt-note.sh "$H" >/dev/null || exit 1
printf 'repo rules\n' > "$CK/rules/CLAUDE.md"
printf 'watcher demo-x\n' > "$H/prompts/demo-x.md"
for k in plan execute review fix-round qa; do printf 'stage %s\n' "$k" > "$H/prompts/stages/$k.md"; done
sha12() { git hash-object "$1" | cut -c1-12; }

# run_block <build dir> [harness] — run the extracted block like result.sh does.
run_block() {
  local b=$1 h=${2:-$H}
  ( STAMP() { date -u +%FT%TZ; }; HARNESS="$h"; HARNESS_CHECKOUT="$CK"; BUILD="$b"; PROJECT=demo-x; KEY=BH-1
    # shellcheck disable=SC1090
    . "$T/block.sh" )
}
newbuild() { local b="$T/build-$1"; mkdir -p "$b"; printf '## Evidence\nline one\n\nlast line' > "$b/evidence.md"; printf '%s' "$b"; }
want_repo() { # want_repo <kind> — the repo-default line for one kind
  local f
  case "$1" in rules) f="$CK/rules/CLAUDE.md" ;; watcher) f="$H/prompts/demo-x.md" ;; *) f="$H/prompts/stages/$1.md" ;; esac
  printf 'PROMPT %s: repo default (%s)' "$1" "$(sha12 "$f")"
}

# ── project-head ─────────────────────────────────────────────────────────────
printf 'rules repo v0 -\nwatcher repo v0 -\nplan repo v0 -\nexecute repo v0 -\nreview project v1 7\nfix-round repo v0 -\nqa repo v0 -\n' \
  > "$H/state/prompts/demo-x/sources.tsv"
B=$(newbuild a); run_block "$B"
[ "$(grep -c '^PROMPT ' "$B/evidence.md")" = 7 ] && ok || bad "project-head: $(grep -c '^PROMPT ' "$B/evidence.md") PROMPT lines (want 7)"
grep -qx 'PROMPT review: project v1 (7)' "$B/evidence.md" && ok || bad "project-head: no 'PROMPT review: project v1 (7)'"
for k in rules watcher plan execute fix-round qa; do
  grep -qxF "$(want_repo "$k")" "$B/evidence.md" && ok || bad "project-head: want '$(want_repo "$k")', got '$(grep "^PROMPT $k:" "$B/evidence.md")'"
done
[ "$(grep '^PROMPT ' "$B/evidence.md" | sed 's/^PROMPT \([a-z-]*\):.*/\1/' | tr '\n' ' ')" = "rules watcher plan execute review fix-round qa " ] \
  && ok || bad "project-head: kinds out of order"
# A fleet head and a missing line (rc 4 at render) on top.
printf 'rules fleet v12 40\nreview project v3 9\n' > "$H/state/prompts/demo-x/sources.tsv"
B=$(newbuild a2); run_block "$B"
grep -qx 'PROMPT rules: fleet v12 (40)' "$B/evidence.md" && ok || bad "project-head: no 'PROMPT rules: fleet v12 (40)'"
grep -qxF "$(want_repo watcher)" "$B/evidence.md" && ok || bad "project-head: a kind with no line is not repo default"

# ── no-sources ───────────────────────────────────────────────────────────────
rm -f "$H/state/prompts/demo-x/sources.tsv"
B=$(newbuild b); run_block "$B"
[ "$(grep -c '^PROMPT [a-z-]*: repo default$' "$B/evidence.md")" = 7 ] && ok || bad "no-sources: $(grep '^PROMPT' "$B/evidence.md")"

# ── malformed-lines ──────────────────────────────────────────────────────────
printf 'review project 1 7\nplan project v1\nbogus project v1 7\nexecute project v1 x\nqa project v1 5\r\nrules weird v1 3\n' \
  > "$H/state/prompts/demo-x/sources.tsv"
B=$(newbuild c); run_block "$B"
for k in review plan execute qa rules; do
  grep -qxF "$(want_repo "$k")" "$B/evidence.md" && ok || bad "malformed-lines: $k gave '$(grep "^PROMPT $k:" "$B/evidence.md")'"
done
[ "$(grep -c '^PROMPT ' "$B/evidence.md")" = 7 ] && ok || bad "malformed-lines: not seven lines"

# ── duplicate-first-wins ─────────────────────────────────────────────────────
printf 'review project v1 7\nreview project v2 8\n' > "$H/state/prompts/demo-x/sources.tsv"
B=$(newbuild d); run_block "$B"
grep -qx 'PROMPT review: project v1 (7)' "$B/evidence.md" && [ "$(grep -c '^PROMPT review:' "$B/evidence.md")" = 1 ] && ok \
  || bad "duplicate-first-wins: $(grep '^PROMPT review' "$B/evidence.md")"

# ── no-repo-file ─────────────────────────────────────────────────────────────
mv "$H/prompts/demo-x.md" "$T/watcher.bak"
B=$(newbuild e); run_block "$B"
grep -qx 'PROMPT watcher: repo default (no file)' "$B/evidence.md" && ok || bad "no-repo-file: $(grep '^PROMPT watcher' "$B/evidence.md")"
mv "$T/watcher.bak" "$H/prompts/demo-x.md"

# ── evidence-kept ────────────────────────────────────────────────────────────
B=$(newbuild f); cp "$B/evidence.md" "$T/ev.before"; run_block "$B"
N=$(wc -c < "$T/ev.before")
cmp -s <(head -c "$N" "$B/evidence.md") "$T/ev.before" && ok || bad "evidence-kept: the text before the block changed"
[ "$(tail -c +"$((N+1))" "$B/evidence.md" | head -c 1 | od -An -c | tr -d ' ')" = '\n' ] && ok || bad "evidence-kept: the PROMPT lines are glued to the last evidence line"

# ── lib-missing-not-fatal ────────────────────────────────────────────────────
mkdir -p "$T/h-nolib"
B=$(newbuild g); cp "$B/evidence.md" "$T/ev.before"
run_block "$B" "$T/h-nolib"; RC=$?
[ "$RC" = 0 ] && cmp -s "$B/evidence.md" "$T/ev.before" && ok || bad "lib-missing-not-fatal: rc $RC or evidence.md changed"
grep -q 'prompt note' "$B/pipeline.log" 2>/dev/null && ok || bad "lib-missing-not-fatal: no pipeline.log line"

# ── mutation-check ───────────────────────────────────────────────────────────
# The block with its call line removed must fail the "seven lines" assert.
grep -v 'prompt_note_append "\$BUILD"' "$T/block.sh" > "$T/block.mut"
if ! cmp -s "$T/block.sh" "$T/block.mut"; then
  cp "$T/block.mut" "$T/block.sh"
  B=$(newbuild m); run_block "$B"
  [ "$(grep -c '^PROMPT ' "$B/evidence.md")" != 7 ] && ok || bad "mutation-check: seven PROMPT lines with the call removed"
else
  bad "mutation-check: no call line to remove"
fi

done_
