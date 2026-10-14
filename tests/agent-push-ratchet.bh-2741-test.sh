#!/bin/bash
# tests/agent-push-ratchet.bh-2741-test.sh — BH-2741: no agent prompt tells the
# agent to push.
#
# WHY. BH-2504 put every harness push to a PR branch behind bin/lib/hold-push.sh,
# which re-reads the ticket's HOLD at the push. An agent session that pushes by
# itself walks past that check, so BH-2741 took `git push` away from the guarded
# lanes (bin/iron-law-guard.sh, rule `agent-push`) and the harness pushes after
# the session. A prompt that still says "Commit AND push" sends the agent
# straight into that refusal, and a prompt is where the instruction comes back
# first. This ratchet keeps the prompts in line with the guard.
#
# WHAT IS SCANNED: every file under prompts/, and the inline `CC <stage> …`
# agent prompts in bin/lib/rb/*.sh (the QA-fix prompt that started this lives
# there). A line OFFENDS when it matches OFFEND_RE and does not match NEGATE_RE
# (case-insensitive): "Do NOT push" and "never push to main" are instructions
# NOT to push, and "push back" or "prompt push" are not about git at all.
# It is line-level on purpose: a ratchet that holds the line, not a parser.
#
#   R1  the matcher, watched failing first on synthetic lines
#   R2  bin/lib/rb/pr.sh's QA-fix prompt says "Do NOT push", not "Commit AND push"
#   R3  zero offenders over the repo; each one printed as path:line
#   bash tests/agent-push-ratchet.bh-2741-test.sh     exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

OFFEND_RE='git push|commit (and|&) push|\b(you|then|and) push\b|push (it|to origin|the branch|your )|MUST-ALLOWED:.*push'
NEGATE_RE="(do not|don't|never|not|must-not)[^.]{0,40}push"

# offends <line> — rc 0 when the line instructs a push.
offends() {
  grep -qiE "$OFFEND_RE" <<<"$1" || return 1
  grep -qiE "$NEGATE_RE" <<<"$1" && return 1
  return 0
}

# scan <root> — "path:line" for every offending line, sorted.
scan() {
  local root="$1" f rel n line
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n+1))
      offends "$line" && printf '%s:%s\n' "$rel" "$n"
    done < "$f"
  done < <(find "$root/prompts" -type f 2>/dev/null | sort)
  for f in "$root"/bin/lib/rb/*.sh; do
    [ -f "$f" ] || continue
    rel="${f#"$root"/}"
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n+1))
      [[ "$line" =~ ^[[:space:]]*CC[[:space:]]+[a-z] ]] || continue
      offends "$line" && printf '%s:%s\n' "$rel" "$n"
    done < "$f"
  done
  return 0
}

# ── R1. the matcher, on lines built to trip it (and lines built not to) ──────
while IFS='|' read -r WANT LINE; do
  [ -n "$LINE" ] || continue
  if offends "$LINE"; then GOT=flag; else GOT=clean; fi
  [ "$GOT" = "$WANT" ] && ok || bad "R1 '$LINE' should be $WANT, got $GOT"
done <<'LINES'
flag|Commit AND push to origin x.
flag|then push the branch
flag|- MUST-ALLOWED: `git rebase` and `git push --force-with-lease` on a branch
flag|run the selector before you push: bin/test-impact-gate.sh
clean|Commit your work. Do NOT push: the harness pushes x after this session.
clean|PRs only (never push to main)
clean|Push back when warranted
clean|any manual step (migration apply, env var, prompt push, republish)
LINES

# ...and the scanner walks both places, on a synthetic tree.
S="$T/syn"; mkdir -p "$S/prompts/stages" "$S/bin/lib/rb"
printf 'line one\nCommit AND push to origin x.\n' > "$S/prompts/stages/a.md"
printf 'Do NOT push.\n' > "$S/prompts/b.md"
printf '    CC fix "$M" 60 "$B/x.txt" "Fix it. Commit AND push to origin $BRANCH."\n' > "$S/bin/lib/rb/x.sh"
printf '    echo "Commit AND push" # not a CC line\n' > "$S/bin/lib/rb/y.sh"
GOT=$(scan "$S" | tr '\n' ' ')
[ "$GOT" = "prompts/stages/a.md:2 bin/lib/rb/x.sh:1 " ] \
  && ok || bad "R1 the scanner must flag exactly prompts/stages/a.md:2 and bin/lib/rb/x.sh:1 (got: $GOT)"

# ── R2. the QA-fix prompt that started this ──────────────────────────────────
QA=$(grep -F 'qa-fix-run.txt' "$DIR/bin/lib/rb/pr.sh" | grep -E '^[[:space:]]*CC ')
[ -n "$QA" ] && ok || bad "R2 no CC line writing qa-fix-run.txt in bin/lib/rb/pr.sh — the QA-fix prompt moved"
case "$QA" in *"Do NOT push"*) ok ;; *) bad "R2 the QA-fix prompt must say 'Do NOT push': $QA" ;; esac
case "$QA" in *"Commit AND push"*) bad "R2 the QA-fix prompt still says 'Commit AND push'" ;; *) ok ;; esac

# ── R3. the repo ─────────────────────────────────────────────────────────────
[ -d "$DIR/prompts" ] && ok || bad "R3 no prompts/ directory to scan"
OFF=$(scan "$DIR")
if [ -z "$OFF" ]; then ok
else
  while IFS= read -r o; do bad "R3 a prompt tells the agent to push: $o"; done <<<"$OFF"
fi

echo "agent-push-ratchet (BH-2741): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
