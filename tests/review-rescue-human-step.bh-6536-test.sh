#!/bin/bash
# tests/review-rescue-human-step.bh-6536-test.sh — a REVIEW_BLOCKED build whose
# only BLOCK was a human step, after the person posted HUMAN-STEP-DONE.
#
# THE DEFECT (BH-6536). TK-232 (project-6-os, 2026-10-13) ended REVIEW_BLOCKED
# on "migration 0020 not applied in prod". The migration was applied and
# HUMAN-STEP-DONE was posted, but bin/review-rescue.sh skips every record whose
# review.md has a verdict, so the built branch was never re-reviewed and no PR
# opened. The ticket was in no kanban column; a person opened the PR by hand.
#
# WHAT THIS SUITE PINS — the REAL lane (its closure installed by
# scratch_install_closure) against a scratch hub, a stub gh, a stub review
# agent, a stub jobs worker and a REAL bare origin + clone:
#   T1  human-only BLOCK + a person's HUMAN-STEP-DONE after the RESULT: one tick
#       re-reviews the branch head with the evidence in the prompt, opens the PR
#       (body has "## Human step evidence"), RESULT -> PR_CREATED, stage row
#       rereview-approve, and nothing is queued or built.
#   T2  same, the re-review BLOCKs on code: the PR opens, the round is posted as
#       a signed COMMENT review (VERDICT: REQUEST_CHANGES, footer on the 40-hex
#       head), RESULT -> PR_CREATED, stage rereview-block, nothing queued.
#   T2b that posted body is what bin/blocked-resolver.sh's review source picks
#       and reads as REQUEST_CHANGES, and br_action sends it to fix-round.
#   T3  a second tick after T2 buys no review and makes no gh write.
#   N1  a human-step line next to a code BLOCK is not shape D.
#   N2  no done comment: no attempt, no marker, stage human-step-waiting; the
#       tick after a done comment arrives behaves as T1.
#   N3  a Bot's HUMAN-STEP-DONE is not evidence.
#   N4  the thread read fails: no attempt, no marker, no stage write.
#   N5  the review post and the comment fallback both fail: RESULT stays
#       REVIEW_BLOCKED, one ALERTS line, stage handed-to-resolver; a second tick
#       adds no alert.
#   N6  RESCUE_HUMAN_STEP=0: no review, no gh write.
#   N7  knobs unset: 3 A-shape records keep their 3 slots and 5 of 7 waiting
#       human-step records are read.
#   N8  an open PR already exists: no PR create, the review goes on that PR.
#   N9  the re-review writes no verdict: the record stays shape D, the stage
#       reason says so, attempt 2 runs on the next tick, and after 2 failures
#       the stage row is rereview-gave-up and .review-rescued exists. No PR
#       review, no build.
#   N10 an in-app board record (no GitHub thread) is not offered: with one
#       human-step slot per tick, an older in-app record must not take the slot
#       a GitHub-issues record with a done comment needs (lead review NOTE a).
#   N11 a code-BLOCK record is parsed once: .human-step-none is written and is
#       newer than review.md; a human-only record gets no such marker
#       (lead review NOTE b).
#
# Run from anywhere: bash tests/review-rescue-human-step.bh-6536-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required"; exit 1; }
unset JOB_ID JOB_PHASE_ID REVIEW_MODEL RESCUE_ONLY RESCUE_PER_TICK RESCUE_HUMAN_STEP RESCUE_HUMAN_STEP_PER_TICK GH_TOKEN
export GH_TOKEN=""

LANE=bin/review-rescue.sh
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in -k) shift 2 ;; -*) shift ;; [0-9]*) shift; break ;; *) break ;; esac
done
exec "$@"
EOF
# The stub gh. REST reads go to the shared stub (the issue state and the
# thread); pr list/create/review/comment are answered and recorded here.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
S="$STUBHUB"
printf '%s\n' "$*" >> "$S/gh-calls.log"
bodyf=""; prev=""
for a in "$@"; do [ "$prev" = --body-file ] && bodyf="$a"; prev="$a"; done
case "$*" in
  *"-i -X "*) GHT="$S"; T="$S"; . "$REPO_DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "$@"; exit 0 ;;
  "pr list"*"--search"*) cat "$S/prlist.out" 2>/dev/null; exit 0 ;;
  "pr list"*"--head"*) [ -s "$S/prlist.out" ] && awk '{print $3}' "$S/prlist.out"; exit 0 ;;
  "pr create"*)
    printf 'create %s\n' "$*" >> "$S/gh-writes.log"
    if [ -n "$bodyf" ] && [ "$bodyf" != - ]; then cat "$bodyf" > "$S/prcreate-body.txt"; else cat > "$S/prcreate-body.txt"; fi
    echo "https://github.com/o/tproj/pull/$(cat "$S/prnum" 2>/dev/null || echo 289)"; exit 0 ;;
  "pr review"*)
    printf 'review %s\n' "$*" >> "$S/gh-writes.log"
    cat "$bodyf" > "$S/review-body.txt" 2>/dev/null
    exit "$(cat "$S/review-rc" 2>/dev/null || echo 0)" ;;
  "pr comment"*)
    printf 'comment %s\n' "$*" >> "$S/gh-writes.log"
    cat "$bodyf" > "$S/comment-body.txt" 2>/dev/null
    exit "$(cat "$S/comment-rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
# The stub jobs worker: every request is recorded with its body; the ledger and
# settings reads answer 404 (none), every write answers 200.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$STUBHUB/req.txt"
case "$METHOD" in PUT|POST) printf '{"ok":true}\n200\n'; exit 0 ;; esac
printf '{}\n404\n'
EOF
chmod +x "$T/fakebin/"*
export PATH="$T/fakebin:$PATH" REPO_DIR="$REPO"

# ── one origin: main, and a pushed branch per ticket number given ─────────────
mkorigin() { # mkorigin <name> <n>...
  local o="$T/$1.git" w="$T/$1-work" n
  git init -q --bare "$o"
  mkdir -p "$w"
  (
    cd "$w" || exit 1
    git -c init.defaultBranch=main init -q .
    git config user.email t@t; git config user.name t
    echo src > app.js; git add -A; git commit -qm init; git branch -M main
    git remote add origin "$o"; git push -q -u origin main
    shift
    for n in "$@"; do
      git checkout -q main; git checkout -q -b "ticket/tp-$n"
      echo "feature $n" > "f$n.js"; git add -A
      git commit -qm "TP-$n: the feature"; git push -q -u origin "ticket/tp-$n"
    done
  ) >/dev/null 2>&1
  git -C "$o" symbolic-ref HEAD refs/heads/main
  mkdir -p "$T/repos-$1"
  git clone -q "$o" "$T/repos-$1/tproj"
}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkorigin o 232 301 302 303 304 305 306 307
HEAD232=$(git -C "$T/o.git" rev-parse refs/heads/ticket/tp-232)

# ── a scratch hub per case, never reused ─────────────────────────────────────
mkhub() { # mkhub <name>
  H="$T/$1"
  mkdir -p "$H/builds" "$H/logs" "$H/flags" "$H/locks" "$H/env"
  # The lane, and every script it runs or sources by path, each with its closure.
  for s in "$LANE" bin/jobs-client.sh bin/alert-line.sh bin/fleet-projects-or-alert.sh bin/fleet-conf.sh bin/project-of.sh; do
    scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install for $s"; exit 1; }
  done
  printf 'tproj o/tproj - - 2 box-tproj\n' > "$H/fleet.conf"
  : > "$H/env/global.env"; : > "$H/req.txt"; : > "$H/gh-calls.log"; : > "$H/gh-writes.log"; : > "$H/prlist.out"
  # Nothing in this flow may start a build: both doors are recorders.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/run-build.log"\nexit 0\n' "$H" > "$H/bin/run-build.sh"
  : > "$H/run-build.log"
  # The review agent: counts its calls, records the HEAD it ran on (its cwd is
  # the rescue's worktree) and its prompt, and APPENDS the round the mode names.
  cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$1" "$(git rev-parse HEAD 2>/dev/null)" >> "$HARNESS/agent-calls.log"
printf '%s\n----\n' "${6:-}" >> "$HARNESS/prompts.log"
RM=$(printf '%s' "${6:-}" | grep -oE '/[^ ]*/review\.md' | head -1)
case "$(cat "$HARNESS/agent-mode" 2>/dev/null || echo approve)" in
  approve) [ -n "$RM" ] && printf 'The migration is applied; the diff is sound.\nTIER: 2\nVERDICT: APPROVE\n' >> "$RM" ;;
  block)   [ -n "$RM" ] && printf 'B2 the handler ignores an empty org id (D11)\nTIER: 2\nVERDICT: BLOCK\n' >> "$RM" ;;
  none) ;;
esac
[ -n "${5:-}" ] && : > "$5"
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh"
  echo '[]' > "$H/comments-232.json"
}
HUMAN_REVIEW='## Findings

B1 migration 0020 not applied in prod — the new table is read on every load.

NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK'
# mkrec <n> <review text> [age-s] — a REVIEW_BLOCKED record of TP-<n>.
mkrec() {
  local r="$H/builds/tproj-TP-$1-202610131800"
  mkdir -p "$r"
  printf 'REVIEW_BLOCKED review.md\nTICKET_ID: %s\nJOB_ID: job-%s\n' "$1" "$1" > "$r/RESULT"
  printf '%s\n' "$2" > "$r/review.md"
  printf '# TP-%s plan\n' "$1" > "$r/plan.md"
  touch -d "@$((NOW - ${3:-7200}))" "$r/RESULT"
  printf '%s' "$r"
}
# done_cmt <n> <age-s> [type] [body] — append a comment to the TP-<n> thread.
done_cmt() {
  local f="$H/comments-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq -c --arg b "${4:-HUMAN-STEP-DONE: applied migration 0020 in prod; SELECT count(*) from org_fixture returned 0}" \
        --arg c "$(ISO "$2")" --arg t "${3:-User}" --arg l "$([ "${3:-User}" = Bot ] && echo 'cromford[bot]' || echo operator)" \
    '. + [{body:$b, created_at:$c, html_url:"https://github.com/o/tproj/issues/232#issuecomment-1", user:{login:$l, type:$t}}]' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
run_lane() {
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" REPOS_ROOT="$T/repos-o" \
           HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.invalid JOBS_BOX=test-box REVIEW_MODEL=stub
    [ -n "${PER_TICK:-}" ] && export RESCUE_PER_TICK="$PER_TICK"
    [ -n "${HS:-}" ] && export RESCUE_HUMAN_STEP="$HS"
    bash "$H/bin/review-rescue.sh" ) >>"$H/stdout.txt" 2>&1
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null) || n=0; printf '%s' "$n"; }
calls() { cnt . "$H/agent-calls.log"; }
writes() { cnt . "$H/gh-writes.log"; }
stage() { awk -F'\t' -v k="$1" '$1==k {print $3}' "$H/state/ticket-stage/tproj.tsv" 2>/dev/null; }
no_build() { # no_build <case>
  [ -s "$H/run-build.log" ] && bad "$1: run-build.sh must not run: $(cat "$H/run-build.log")" || ok
  grep -E '^(PUT|POST) [^ ]*/api/queue' "$H/req.txt" >/dev/null 2>&1 && bad "$1: nothing may be enqueued: $(grep /api/queue "$H/req.txt")" || ok
}

# ══ T1 — the human step is done; the re-review APPROVEs ════════════════════
mkhub t1
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
run_lane
[ "$(calls)" = 1 ] && ok || bad "T1: the re-review must run exactly once, got $(calls). log: $(tail -5 "$H/logs/review-rescue.log" 2>/dev/null)"
[ "$(awk '{print $2}' "$H/agent-calls.log" 2>/dev/null | head -1)" = "$HEAD232" ] && ok \
  || bad "T1: the review must run on the branch head $HEAD232, ran on '$(awk '{print $2}' "$H/agent-calls.log" 2>/dev/null)'"
grep -q 'SELECT count(\*) from org_fixture returned 0' "$H/prompts.log" 2>/dev/null && ok || bad "T1: the prompt must carry the person's evidence"
grep -q 'Do not re-block on that finding' "$H/prompts.log" 2>/dev/null && ok || bad "T1: the prompt must be the human-step variant"
grep -q "^=== human-step re-review ${HEAD232:0:8}" "$R/review.md" && ok || bad "T1: review.md must carry the human-step re-review header: $(grep '^===' "$R/review.md")"
[ "$(cnt '^create ' "$H/gh-writes.log")" = 1 ] && ok || bad "T1: gh pr create must run once: $(cat "$H/gh-writes.log")"
grep -q '^## Human step evidence' "$H/prcreate-body.txt" 2>/dev/null && ok || bad "T1: the PR body must carry ## Human step evidence: $(cat "$H/prcreate-body.txt" 2>/dev/null)"
grep -q '^> HUMAN-STEP-DONE: applied migration 0020' "$H/prcreate-body.txt" 2>/dev/null && ok || bad "T1: the evidence is quoted in the PR body"
[ "$(head -1 "$R/RESULT")" = "PR_CREATED https://github.com/o/tproj/pull/289" ] && ok || bad "T1: RESULT line 1 must be PR_CREATED <url>, got '$(head -1 "$R/RESULT")'"
grep -q '^RESCUED: human-step re-review' "$R/RESULT" && ok || bad "T1: RESULT must carry RESCUED: human-step re-review"
grep -qx 'JOB_ID: job-232' "$R/RESULT" && ok || bad "T1: the additive rewrite keeps JOB_ID:"
[ -f "$R/.review-rescued" ] && ok || bad "T1: .review-rescued must be written"
[ "$(stage TP-232)" = rereview-approve ] && ok || bad "T1: stage must be rereview-approve, got '$(stage TP-232)'"
grep -q 'PUT https://jobs.invalid/api/ledger .*"kind":"ticket_stage","key":"tproj#232","status":"review"' "$H/req.txt" && ok \
  || bad "T1: a ticket_stage ledger row must be written: $(grep ledger "$H/req.txt")"
no_build T1

# ══ T2 — the re-review BLOCKs on code: PR + signed review for the fix round ═
mkhub t2
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
echo block > "$H/agent-mode"
run_lane
[ "$(calls)" = 1 ] && ok || bad "T2: one re-review, got $(calls)"
[ "$(cnt '^create ' "$H/gh-writes.log")" = 1 ] && ok || bad "T2: the PR must still be opened: $(cat "$H/gh-writes.log")"
[ "$(cnt '^review pr review 289 -R o/tproj --comment' "$H/gh-writes.log")" = 1 ] && ok || bad "T2: one gh pr review --comment on #289: $(cat "$H/gh-writes.log")"
grep -qx 'VERDICT: REQUEST_CHANGES' "$H/review-body.txt" 2>/dev/null && ok || bad "T2: the posted body must carry VERDICT: REQUEST_CHANGES: $(cat "$H/review-body.txt" 2>/dev/null)"
grep -q 'B2 the handler ignores an empty org id' "$H/review-body.txt" 2>/dev/null && ok || bad "T2: the posted body must carry the new round's findings"
grep -q 'migration 0020 not applied' "$H/review-body.txt" 2>/dev/null && bad "T2: the posted body must be the NEW round only" || ok
[ "$(tail -1 "$H/review-body.txt" 2>/dev/null)" = "_Automated harness review (Fable) of $HEAD232. Human-step re-review by bin/review-rescue.sh; the harness fix round consumes this verdict._" ] && ok \
  || bad "T2: the body must end with the signed footer for the 40-hex head: '$(tail -1 "$H/review-body.txt" 2>/dev/null)'"
[ "$(head -1 "$R/RESULT")" = "PR_CREATED https://github.com/o/tproj/pull/289" ] && ok || bad "T2: RESULT line 1 must be PR_CREATED, got '$(head -1 "$R/RESULT")'"
[ -f "$R/.review-rescued" ] && ok || bad "T2: .review-rescued must be written"
[ "$(stage TP-232)" = rereview-block ] && ok || bad "T2: stage must be rereview-block, got '$(stage TP-232)'"
no_build T2
T2BODY="$H/review-body.txt"

# ══ T2b — the resolver's review source reads that body as a fix round ═══════
OUT=$(
  export HARNESS="$H" HARNESS_VERDICT_AUTHORS="operator app/cromford"
  . "$REPO/bin/lib/gh-pr-list.sh" >/dev/null 2>&1
  for fn in br_review_harness_pick br_review_verdict; do
    awk -v f="^$fn\\\\(\\\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$REPO/bin/blocked-resolver.sh"
  done > "$T/t2b-fns.sh"
  eval "$(grep -m1 '^BR_REVIEW_FOOTER=' "$REPO/bin/blocked-resolver.sh")"
  . "$T/t2b-fns.sh"
  ROWS=$(jq -nc --rawfile b "$T2BODY" --arg c "$HEAD232" '[{l:"cromford[bot]",t:"Bot",a:"NONE",c:$c,s:"COMMENTED",b:$b}]')
  B64=$(br_review_harness_pick "$HEAD232" "$ROWS") || { echo "no-pick"; exit 0; }
  V=$(br_review_verdict "$(printf '%s' "$B64" | base64 -d)")
  . "$REPO/bin/lib/br/ladder.sh" >/dev/null 2>&1
  echo "$V $(br_action review-changes-requested)")
[ "$OUT" = "REQUEST_CHANGES fix-round" ] && ok || bad "T2b: the resolver must pick the posted review and send it to fix-round, got '$OUT'"

# ══ T3 — the tick after T2 is free ════════════════════════════════════════
touch -d "@$((NOW - 7200))" "$R/RESULT"
W0=$(writes)
run_lane
[ "$(calls)" = 1 ] && ok || bad "T3: a second tick must not review again, got $(calls)"
[ "$(writes)" = "$W0" ] && ok || bad "T3: a second tick must make no gh write: $(cat "$H/gh-writes.log")"

# ══ N1 — a human-step line next to a code BLOCK is not shape D ═════════════
mkhub n1
R=$(mkrec 232 '## Findings

B1 migration 0020 not applied in prod.
B2 the guard returns early on empty input.

NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK')
done_cmt 232 3600
run_lane
[ "$(calls)" = 0 ] && ok || bad "N1: a code BLOCK must not be re-reviewed by shape D, got $(calls)"
[ "$(writes)" = 0 ] && ok || bad "N1: no gh write: $(cat "$H/gh-writes.log")"
[ -e "$H/state/ticket-stage/tproj.tsv" ] && bad "N1: no stage row for a code BLOCK: $(cat "$H/state/ticket-stage/tproj.tsv")" || ok
[ -e "$R/.rescue-attempts" ] && bad "N1: no attempt spent" || ok

# ══ N2 — no done comment yet: wait, spend nothing; then the comment lands ═══
mkhub n2
R=$(mkrec 232 "$HUMAN_REVIEW")
run_lane
[ "$(calls)" = 0 ] && ok || bad "N2: no review without a done comment, got $(calls)"
[ -e "$R/.rescue-attempts" ] && bad "N2: no attempt may be spent: $(cat "$R/.rescue-attempts")" || ok
[ -e "$R/.review-rescued" ] && bad "N2: no marker while waiting" || ok
[ "$(stage TP-232)" = human-step-waiting ] && ok || bad "N2: stage must be human-step-waiting, got '$(stage TP-232)'"
grep -q 'waits for a person' "$H/state/ticket-stage/tproj.tsv" && ok || bad "N2: the waiting reason must say what it waits for: $(cat "$H/state/ticket-stage/tproj.tsv" 2>/dev/null)"
[ "$(writes)" = 0 ] && ok || bad "N2: no gh write while waiting"
done_cmt 232 600
run_lane
[ "$(calls)" = 1 ] && ok || bad "N2: the tick after the done comment re-reviews once, got $(calls)"
[ "$(head -1 "$R/RESULT")" = "PR_CREATED https://github.com/o/tproj/pull/289" ] && ok || bad "N2: …and opens the PR, got '$(head -1 "$R/RESULT")'"

# ══ N3 — a Bot's HUMAN-STEP-DONE is not evidence ═══════════════════════════
mkhub n3
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600 Bot
run_lane
[ "$(calls)" = 0 ] && ok || bad "N3: a Bot's done comment buys no review, got $(calls)"
[ -e "$R/.rescue-attempts" ] && bad "N3: no attempt" || ok
[ "$(stage TP-232)" = human-step-waiting ] && ok || bad "N3: stage human-step-waiting, got '$(stage TP-232)'"

# ══ N4 — the thread cannot be read ═════════════════════════════════════════
mkhub n4
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
echo 500 > "$H/st-comments"
run_lane
[ "$(calls)" = 0 ] && ok || bad "N4: an unreadable thread buys no review, got $(calls)"
[ -e "$R/.rescue-attempts" ] || [ -e "$R/.review-rescued" ] && bad "N4: no attempt and no marker on an unreadable thread" || ok
[ -e "$H/state/ticket-stage/tproj.tsv" ] && bad "N4: no stage write on an unreadable thread" || ok
grep -q 'human-step thread unreadable' "$H/logs/review-rescue.log" && ok || bad "N4: the log must say the thread was unreadable"

# ══ N5 — BLOCK, and neither the review nor the comment would post ═══════════
mkhub n5
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
echo block > "$H/agent-mode"; echo 1 > "$H/review-rc"; echo 1 > "$H/comment-rc"
run_lane
[ "$(head -1 "$R/RESULT")" = "REVIEW_BLOCKED review.md" ] && ok || bad "N5: RESULT must stay REVIEW_BLOCKED when nothing posted, got '$(head -1 "$R/RESULT")'"
[ -f "$R/.review-rescued" ] && ok || bad "N5: .review-rescued hands the record to the resolver"
[ "$(cnt 'could not be posted' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "N5: exactly one ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(stage TP-232)" = handed-to-resolver ] && ok || bad "N5: stage handed-to-resolver, got '$(stage TP-232)'"
touch -d "@$((NOW - 7200))" "$R/RESULT"
run_lane
[ "$(cnt 'could not be posted' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "N5: a second tick adds no ALERTS line"
[ "$(calls)" = 1 ] && ok || bad "N5: a second tick buys no second review, got $(calls)"

# ══ N6 — the kill switch ═══════════════════════════════════════════════════
mkhub n6
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
HS=0 run_lane
[ "$(calls)" = 0 ] && ok || bad "N6: RESCUE_HUMAN_STEP=0 buys no review, got $(calls)"
[ "$(writes)" = 0 ] && ok || bad "N6: RESCUE_HUMAN_STEP=0 makes no gh write"
[ -e "$H/state/ticket-stage/tproj.tsv" ] && bad "N6: RESCUE_HUMAN_STEP=0 writes no stage row" || ok

# ══ N7 — separate caps: A/B keep their slots, shape D has its own ═════════
mkhub n7
for n in 301 302 303 304 305 306 307; do mkrec "$n" "$HUMAN_REVIEW" $((9000 + n)) >/dev/null; echo '[]' > "$H/comments-$n.json"; done
for n in 401 402 403; do mkrec "$n" 'draft, the session died here' 8000 >/dev/null; done
run_lane
A=0; for n in 401 402 403; do [ -f "$H/builds/tproj-TP-$n-202610131800/.review-rescued" ] && A=$((A+1)); done
[ "$A" = 3 ] && ok || bad "N7: all 3 A-shape records must be offered (RESCUE_PER_TICK=3), got $A"
RD=$(grep -cE 'GET .*/issues/3[0-9]{2}/comments' "$H/gh-calls.log" 2>/dev/null) || RD=0
[ "$RD" = 5 ] && ok || bad "N7: 5 human-step threads read (RESCUE_HUMAN_STEP_PER_TICK default 5), got $RD"
[ "$(grep -c 'human-step-waiting' "$H/state/ticket-stage/tproj.tsv" 2>/dev/null)" = 5 ] && ok || bad "N7: 5 waiting stage rows: $(cat "$H/state/ticket-stage/tproj.tsv" 2>/dev/null)"
[ "$(calls)" = 0 ] && ok || bad "N7: no review is bought for a waiting record, got $(calls)"

# ══ N8 — the PR is already open: review it, do not open another ═══════════
mkhub n8
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
echo block > "$H/agent-mode"
printf '289 ticket/tp-232 https://github.com/o/tproj/pull/289\n' > "$H/prlist.out"
run_lane
[ "$(cnt '^create ' "$H/gh-writes.log")" = 0 ] && ok || bad "N8: no second PR may be created: $(cat "$H/gh-writes.log")"
[ "$(cnt '^review pr review 289 ' "$H/gh-writes.log")" = 1 ] && ok || bad "N8: the review goes on the existing #289: $(cat "$H/gh-writes.log")"
[ "$(head -1 "$R/RESULT")" = "PR_CREATED https://github.com/o/tproj/pull/289" ] && ok || bad "N8: RESULT PR_CREATED on the existing url, got '$(head -1 "$R/RESULT")'"

# ══ N9 — the re-review dies with no verdict: retry, then give up ═══════════
mkhub n9
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
echo none > "$H/agent-mode"
run_lane
[ "$(calls)" = 1 ] && ok || bad "N9: tick 1 buys one re-review, got $(calls)"
[ "$(cat "$R/.rescue-attempts" 2>/dev/null)" = 1 ] && ok || bad "N9: tick 1 spends attempt 1, got '$(cat "$R/.rescue-attempts" 2>/dev/null)'"
[ -e "$R/.review-rescued" ] && bad "N9: no marker after one no-verdict attempt" || ok
[ "$(head -1 "$R/RESULT")" = "REVIEW_BLOCKED review.md" ] && ok || bad "N9: RESULT stays REVIEW_BLOCKED, got '$(head -1 "$R/RESULT")'"
(. "$REPO/bin/lib/needs-human.sh"; nh_sd_human_only "$R/review.md" >/dev/null 2>&1) && ok \
  || bad "N9: the empty re-review round must not hide the human-step BLOCK above it: $(cat "$R/review.md")"
[ "$(stage TP-232)" = human-step-done ] && ok || bad "N9: stage human-step-done after attempt 1, got '$(stage TP-232)'"
grep -q 'attempt 1 produced no verdict' "$H/state/ticket-stage/tproj.tsv" && ok \
  || bad "N9: the stage reason must say attempt 1 produced no verdict: $(cat "$H/state/ticket-stage/tproj.tsv" 2>/dev/null)"
touch -d "@$((NOW - 7200))" "$R/RESULT"
run_lane
[ "$(calls)" = 2 ] && ok || bad "N9: tick 2 runs attempt 2, got $(calls) calls"
[ "$(cat "$R/.rescue-attempts" 2>/dev/null)" = 2 ] && ok || bad "N9: attempt 2 is counted, got '$(cat "$R/.rescue-attempts" 2>/dev/null)'"
touch -d "@$((NOW - 7200))" "$R/RESULT"
run_lane
[ "$(calls)" = 2 ] && ok || bad "N9: tick 3 buys no third review, got $(calls)"
[ -f "$R/.review-rescued" ] && ok || bad "N9: after 2 failures .review-rescued hands the record on"
[ "$(stage TP-232)" = rereview-gave-up ] && ok || bad "N9: stage rereview-gave-up after 2 failures, got '$(stage TP-232)'"
[ "$(cnt '^review ' "$H/gh-writes.log")" = 0 ] && ok || bad "N9: no PR review is posted without a verdict: $(cat "$H/gh-writes.log")"
no_build N9

# ══ N10 — an in-app board record never takes a shape D slot ═════════════════
mkhub n10
printf 'iproj o/iproj https://iproj.test /api/internal 3 box-iproj\n' >> "$H/fleet.conf"
RI="$H/builds/iproj-IP-5-202610131700"
mkdir -p "$RI"
printf 'REVIEW_BLOCKED review.md\nTICKET_ID: 5\nJOB_ID: job-5\n' > "$RI/RESULT"
printf '%s\n' "$HUMAN_REVIEW" > "$RI/review.md"
touch -d "@$((NOW - 14400))" "$RI/RESULT"
R=$(mkrec 232 "$HUMAN_REVIEW")
done_cmt 232 3600
( export RESCUE_HUMAN_STEP_PER_TICK=1; run_lane )
[ "$(calls)" = 1 ] && ok || bad "N10: the GitHub-issues record gets the one slot, got $(calls) review calls: $(tail -3 "$H/stdout.txt")"
[ -e "$RI/.human-step-checked" ] && bad "N10: the in-app record is not offered at all" || ok
[ "$(cnt 'needs a GitHub-issues board' "$H/logs/review-rescue.log")" = 0 ] && ok \
  || bad "N10: no 'needs a GitHub-issues board' line per tick: $(grep 'GitHub-issues board' "$H/logs/review-rescue.log")"

# ══ N11 — a code BLOCK is parsed once, then remembered ══════════════════════
mkhub n11
RC=$(mkrec 232 '## Findings

B2 the guard returns early on empty input.

TIER: 2
VERDICT: BLOCK')
run_lane
[ -f "$RC/.human-step-none" ] && [ "$RC/.human-step-none" -nt "$RC/review.md" ] && ok \
  || bad "N11: a code BLOCK leaves .human-step-none newer than review.md"
[ "$(calls)" = 0 ] && ok || bad "N11: no review for a code BLOCK, got $(calls)"
mkhub n11b
RH=$(mkrec 232 "$HUMAN_REVIEW")
run_lane
[ -e "$RH/.human-step-none" ] && bad "N11: a human-only BLOCK gets no .human-step-none" || ok

echo "review-rescue-human-step.bh-6536-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
