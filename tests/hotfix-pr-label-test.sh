#!/bin/bash
# tests/hotfix-pr-label-test.sh — the label follows the work (#368, hotfix lane
# 1/3): the PR a hotfix build opens carries the `hotfix` label and says so on
# its first body line, and announces itself once.
#
# WHY IT MATTERS THAT THIS IS DRIVEN. Child #2 of this lane keys its merge rule
# on the LABEL, not on the issue — so a PR that opens without it is a hotfix
# that queues behind every ordinary PR with nothing anywhere saying why. The
# label goes on by a follow-up REST write rather than `gh pr create --label`,
# because a --label naming a label the repo does not have fails the CREATE and
# loses the PR entirely; that choice is only safe if a failed write is loud and
# harmless, which is what §4 asserts.
#
# The PR-open region and the evidence block are lifted out of bin/run-build.sh
# by their markers and executed, the same way tests/pr-body-closes-test.sh and
# tests/run-build-gates-test.sh drive theirs.
# Run from anywhere: tests/hotfix-pr-label-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1  # BH-6091: the pr-open HOLD gate for a pipeline slice
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin/lib" "$T/build" "$T/fakebin" "$T/repo" "$T/logs" "$T/env" \
         "$T/flags" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset HOTFIX HOTFIX_LANE HOTFIX_LABEL 2>/dev/null || true

awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB_ALL" > "$T/block.sh"
awk '/^# >>> merge note fn/{f=1;next} /^# <<< merge note fn/{exit} f' "$RB_ALL" > "$T/mergenote.sh"
awk '/^# >>> pr open/{f=1;next} /^# <<< pr open/{exit} f' "$RB_ALL" > "$T/propen.sh"
[ -s "$T/propen.sh" ] && ok || bad "could not extract the PR-open region — # >>> pr open markers missing?"
grep -q 'gh pr create' "$T/propen.sh" && ok || bad "the extracted region does not contain the PR create"
hold_gate_prepend "$RB_ALL" "$T/propen.sh"   # BH-6091: the real gate, a no-HOLD ticket read
cp "$DIR/bin/lib/hotfix-lib.sh" "$T/bin/lib/" 2>/dev/null || bad "bin/lib/hotfix-lib.sh does not exist"

( cd "$T/repo" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && echo one > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "TK-9: the subject" ) >/dev/null 2>&1
printf '#!/bin/bash\n[ "${2:-}" = board_prefix ] && echo "-"\nexit 0\n' > "$T/bin/fleet-conf.sh"
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEAT_SINK"
exit 0
SH
chmod +x "$T/bin/fleet-conf.sh" "$T/bin/beat.sh"
# BH-7919: the Closes line (bin/lib/rb/pr.sh) now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$T" >/dev/null || exit 1
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *"issues/"*"/labels"*) exit "${LABEL_RC:-0}" ;;
esac
case "$1 ${2:-}" in
  "pr create") echo "https://github.com/o/r/pull/77" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

drive() { # drive <key> [env...]
  local key="$1"; shift
  : > "$T/gh.txt"; : > "$T/beat.txt"; : > "$T/logs/ALERTS.log"
  : > "$T/build/pipeline.log"; : > "$T/body.txt"; rm -rf "$T/state/hotfix-announced"
  ( cd "$T/repo" || exit 1
    env PATH="$T/fakebin:$PATH" HARNESS="$T" BUILD="$T/build" GH_SINK="$T/gh.txt" \
        BEAT_SINK="$T/beat.txt" KEY="$key" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      GH_LIVE() { :; }
      STAGE_END() { :; }
      T_PR=0
      ALERTS="$HARNESS/logs/ALERTS.log"
      PROJECT=tproj; SLUG=o/r; BASE=main; BRANCH=ticket/TK-9; TIER=1
      QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      job_artifact_put() { return 0; }
      . "$0"          # bin/lib/hotfix-lib.sh
      . "$1"          # merge note fn
      . "$2"          # evidence block -> PR_BODY_FOR
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$3"
      . "$4"          # the PR-open region
    ' "$T/bin/lib/hotfix-lib.sh" "$T/mergenote.sh" "$T/block.sh" "$T/body.txt" "$T/propen.sh" 2>"$T/err.txt" )
}

# ══ 1. A HOTFIX BUILD LABELS ITS PR ════════════════════════════════════════
drive TK-9 HOTFIX=1
grep -q 'api -X POST repos/o/r/issues/77/labels' "$T/gh.txt" && ok \
  || bad "no label write for a hotfix PR: gh=$(cat "$T/gh.txt") err=$(cat "$T/err.txt")"
grep -q 'labels\[\]=hotfix' "$T/gh.txt" && ok \
  || bad "the label write does not carry labels[]=hotfix: $(cat "$T/gh.txt")"
# `gh pr create --label` would fail the whole CREATE when the repo has no such
# label, and example-org/cromford does not have it yet.
grep -q 'pr create.*--label' "$T/gh.txt" \
  && bad "the label must NOT ride the create: $(cat "$T/gh.txt")" || ok
grep -q "labelled https://github.com/o/r/pull/77 'hotfix'" "$T/build/pipeline.log" && ok \
  || bad "a successful label write must say so in the build log: $(cat "$T/build/pipeline.log")"

# ══ 2. A PLAIN BUILD DOES NOT ══════════════════════════════════════════════
drive TK-9 HOTFIX=""
grep -q 'labels' "$T/gh.txt" && bad "a plain build wrote a label: $(cat "$T/gh.txt")" || ok
grep -q 'pr create' "$T/gh.txt" && ok || bad "the plain path must still create the PR: $(cat "$T/gh.txt")"
[ ! -s "$T/beat.txt" ] && ! grep -q 'HOTFIX pr_open' "$T/logs/ALERTS.log" && ok \
  || bad "a plain build must not announce: beat=$(cat "$T/beat.txt") alerts=$(cat "$T/logs/ALERTS.log")"

# ══ 3. THE FIRST BODY LINE NAMES IT ════════════════════════════════════════
drive TK-9 HOTFIX=1
head -1 "$T/body.txt" | grep -q '^HOTFIX: Ticket TK-9 — ' && ok \
  || bad "the hotfix body's first line must start with 'HOTFIX: Ticket TK-9 — ' (got: $(head -1 "$T/body.txt"))"
[ "$(sed -n 2p "$T/body.txt")" = "Closes #9" ] && ok \
  || bad "the Closes line must still be line 2 for a hotfix (got: $(sed -n 2p "$T/body.txt"))"
drive TK-9 HOTFIX=""
head -1 "$T/body.txt" | grep -q '^Ticket TK-9 — ' && ok \
  || bad "a plain body's first line must be unchanged (got: $(head -1 "$T/body.txt"))"
[ "$(sed -n 2p "$T/body.txt")" = "Closes #9" ] && ok \
  || bad "the Closes line must still be line 2 for a plain build (got: $(sed -n 2p "$T/body.txt"))"

# ══ 4. IT ANNOUNCES ITSELF, AND A FAILED LABEL WRITE IS LOUD BUT HARMLESS ══
drive TK-9 HOTFIX=1
# BH-2381: pr_open is a notice; the ALERTS line below is the announcement.
[ ! -s "$T/beat.txt" ] && ok || bad "pr_open must not beat (no alert row): $(cat "$T/beat.txt")"
[ "$(grep -c 'HOTFIX pr_open' "$T/logs/ALERTS.log")" = 1 ] && ok \
  || bad "exactly one pr_open ALERTS line: $(cat "$T/logs/ALERTS.log")"
grep -q 'HOTFIX pr_open: PR opened https://github.com/o/r/pull/77' "$T/logs/ALERTS.log" && ok \
  || bad "the ALERTS line must name the PR: $(cat "$T/logs/ALERTS.log")"
[ -f "$T/state/hotfix-announced/tproj/TK-9.pr_open" ] && ok \
  || bad "the pr_open announcement must write its dedupe marker"

drive TK-9 HOTFIX=1 LABEL_RC=1
grep -q 'gh label create' "$T/logs/ALERTS.log" && ok \
  || bad "a failed label write must page with the command that fixes it: $(cat "$T/logs/ALERTS.log")"
grep -q 'gh label create hotfix -R o/r' "$T/logs/ALERTS.log" && ok \
  || bad "the fix command must name the label and the repo: $(cat "$T/logs/ALERTS.log")"
[ ! -f "$T/build/RESULT" ] && ok || bad "a failed label write must not touch the RESULT: $(cat "$T/build/RESULT" 2>/dev/null)"
grep -q 'HOTFIX pr_open: PR opened https://github.com/o/r/pull/77' "$T/logs/ALERTS.log" && ok \
  || bad "a failed label write must not swallow the announcement: $(cat "$T/logs/ALERTS.log")"

# ══ 5. THE KILL FLAG ═══════════════════════════════════════════════════════
# HOTFIX_LANE=0 puts the PR back to what it was before #368, label and body.
drive TK-9 HOTFIX=1 HOTFIX_LANE=0
grep -q 'labels' "$T/gh.txt" && bad "HOTFIX_LANE=0 still wrote a label: $(cat "$T/gh.txt")" || ok
[ ! -s "$T/beat.txt" ] && ! grep -q 'HOTFIX pr_open' "$T/logs/ALERTS.log" && ok \
  || bad "HOTFIX_LANE=0 must silence the announcement: beat=$(cat "$T/beat.txt") alerts=$(cat "$T/logs/ALERTS.log")"
head -1 "$T/body.txt" | grep -q '^Ticket TK-9 — ' && ok \
  || bad "HOTFIX_LANE=0 must render the pre-#368 body (got: $(head -1 "$T/body.txt"))"

# ══ 6. ticket-meta.json IS THE SECOND OPINION ══════════════════════════════
# A RESUME_BUILD, or a build whose early detection ran while gh was down,
# reaches this point with HOTFIX empty and the label sitting in the issue this
# pipeline already fetched. No API call is owed for an answer we hold.
printf '{"labels":[{"name":"hotfix"}]}\n' > "$T/build/ticket-meta.json"
drive TK-9 HOTFIX=""
grep -q 'api -X POST repos/o/r/issues/77/labels' "$T/gh.txt" && ok \
  || bad "ticket-meta.json must be read as the second opinion: $(cat "$T/gh.txt")"
grep -q 'issue view' "$T/gh.txt" \
  && bad "the second opinion must cost no API call: $(cat "$T/gh.txt")" || ok
# ...and an ordinary ticket's meta must not trip it
printf '{"labels":[{"name":"hotfix-candidate"}]}\n' > "$T/build/ticket-meta.json"
drive TK-9 HOTFIX=""
grep -q 'labels' "$T/gh.txt" && bad "hotfix-candidate is not the label: $(cat "$T/gh.txt")" || ok
rm -f "$T/build/ticket-meta.json"

# ══ 7. THE MERGED ANNOUNCE: WHERE IT SITS, AND WHO IT FIRES FOR ════════════
# Two different failures, so two different kinds of assertion.
#
# POSITION answers "does it announce a merge that happened": the enclosing
# region runs `gh pr merge` against a real repo, so the call's placement inside
# the tier-1 direct-merge `if` and before the terminal is pinned by line number.
#
# But position cannot see the failure that matters more. hotfix_announce checks
# the kill flag and its dedupe marker and NOTHING ELSE — it never asks whether
# the ticket is a hotfix, by design; the caller decides. So a call sitting in
# exactly the right place, guarded only by `command -v`, pages the console and
# Telegram with `HOTFIX merged` for every ORDINARY tier-1 merge on every box in
# the fleet, and every position pin here still passes. That one is DRIVEN:
# the announce carries its own marker pair so the guard can be executed with
# HOTFIX empty, which is the state a plain build reaches this line in.
SRC="$RB_ALL"
MERGED_N=$(grep -n 'hotfix_announce "\$HARNESS" "\$PROJECT" "\$KEY" merged' "$SRC" | cut -d: -f1)
[ "$(printf '%s\n' "$MERGED_N" | grep -c .)" = 1 ] && ok \
  || bad "expected exactly one tier-1 merged announce, got: '$MERGED_N'"
IF_N=$(grep -n 'if \[ "\$TIER" = "1" \] && \[ -n "\$PR_URL" \] && \[ -z "\${BUILDER_NO_MERGE:-}" \]' "$SRC" | cut -d: -f1 | head -1)
RESULT_N=$(grep -n 'RESULT "PR_MERGED \$PR_URL"' "$SRC" | cut -d: -f1 | head -1)
[ -n "$IF_N" ] && [ -n "$RESULT_N" ] && ok \
  || bad "could not locate the tier-1 merged branch (if=$IF_N result=$RESULT_N)"
[ -n "$MERGED_N" ] && [ -n "$IF_N" ] && [ -n "$RESULT_N" ] \
  && [ "$MERGED_N" -gt "$IF_N" ] && [ "$MERGED_N" -lt "$RESULT_N" ] && ok \
  || bad "the merged announce must sit inside the tier-1 merge branch, before RESULT PR_MERGED (if=$IF_N announce=$MERGED_N result=$RESULT_N)"

awk '/^# >>> hotfix merged announce/{f=1;next} /^# <<< hotfix merged announce/{exit} f' "$SRC" > "$T/merged.sh"
[ -s "$T/merged.sh" ] && ok \
  || bad "could not extract the merged announce — # >>> hotfix merged announce markers missing?"
grep -q 'hotfix_announce "\$HARNESS" "\$PROJECT" "\$KEY" merged' "$T/merged.sh" && ok \
  || bad "the extracted region does not contain the merged announce: $(cat "$T/merged.sh")"

: > "$T/merr.txt"   # accumulates every drive_merged stderr; asserted empty below
drive_merged() { # drive_merged [env...]
  : > "$T/beat.txt"; : > "$T/logs/ALERTS.log"; rm -rf "$T/state/hotfix-announced"
  env HARNESS="$T" BEAT_SINK="$T/beat.txt" "$@" \
  bash -c '
    set -uo pipefail
    PROJECT=tproj; KEY=TK-9; PR_URL=https://github.com/o/r/pull/77
    . "$0"          # bin/lib/hotfix-lib.sh
    . "$1"          # the merged-announce region
  ' "$T/bin/lib/hotfix-lib.sh" "$T/merged.sh" 2>>"$T/merr.txt"
}

# A hotfix merge announces, once, on the same channel as the other two events.
drive_merged HOTFIX=1
# BH-2381: merged is a notice; the ALERTS line is the announcement.
[ ! -s "$T/beat.txt" ] && ok || bad "a hotfix merge must not beat (no alert row): $(cat "$T/beat.txt")"
[ "$(grep -c 'HOTFIX merged' "$T/logs/ALERTS.log")" = 1 ] && ok \
  || bad "a hotfix merge must write exactly one merged ALERTS line: $(cat "$T/logs/ALERTS.log")"
grep -q 'HOTFIX merged: https://github.com/o/r/pull/77 merged' "$T/logs/ALERTS.log" && ok \
  || bad "the merged ALERTS line must name the PR: $(cat "$T/logs/ALERTS.log")"
[ -f "$T/state/hotfix-announced/tproj/TK-9.merged" ] && ok \
  || bad "the merged announcement must write its dedupe marker"

# THE REGRESSION THIS EXISTS FOR: a plain tier-1 build reaches this line with
# HOTFIX empty and must be silent. Unguarded, every ordinary merge in the fleet
# writes a pre-triaged `HOTFIX merged` alert to ALERTS.log and the console.
drive_merged HOTFIX=""
[ ! -s "$T/beat.txt" ] && ok \
  || bad "a plain tier-1 merge must not beat a HOTFIX announcement: $(cat "$T/beat.txt")"
[ ! -s "$T/logs/ALERTS.log" ] && ok \
  || bad "a plain tier-1 merge must not write a HOTFIX ALERTS line: $(cat "$T/logs/ALERTS.log")"
[ ! -e "$T/state/hotfix-announced/tproj/TK-9.merged" ] && ok \
  || bad "a plain tier-1 merge must not write an announcement marker"
# ...and HOTFIX unset at all (not merely empty) is the same plain answer: the
# region runs under `set -u` on a build whose detection never assigned it.
( unset HOTFIX; drive_merged )
[ ! -s "$T/beat.txt" ] && [ ! -s "$T/logs/ALERTS.log" ] && ok \
  || bad "HOTFIX unset must be as silent as HOTFIX empty: beat=$(cat "$T/beat.txt") alerts=$(cat "$T/logs/ALERTS.log")"
[ ! -s "$T/merr.txt" ] && ok || bad "the merged announce must run clean under set -u: $(cat "$T/merr.txt")"

# The kill flag puts the merged event back to pre-#368 silence too.
drive_merged HOTFIX=1 HOTFIX_LANE=0
[ ! -s "$T/beat.txt" ] && [ ! -s "$T/logs/ALERTS.log" ] && ok \
  || bad "HOTFIX_LANE=0 must silence the merged announcement: beat=$(cat "$T/beat.txt") alerts=$(cat "$T/logs/ALERTS.log")"

# ══ 8. F6: THE BACKSTOP STATES THE RUNG IT HAS ═════════════════════════════
# Ticket-mandated source pins. Guarded: the "queued for build" count must be
# exactly 1, so deleting the line fails here rather than passing by absence.
[ "$(grep -c 'is being built now' "$SRC")" = 0 ] && ok \
  || bad "the backstop must not claim a build that has not started ($(grep -c 'is being built now' "$SRC") hits)"
[ "$(grep -c 'queued for build' "$SRC")" = 1 ] && ok \
  || bad "expected exactly one 'queued for build' backstop line, got $(grep -c 'queued for build' "$SRC")"

echo "hotfix-pr-label: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
