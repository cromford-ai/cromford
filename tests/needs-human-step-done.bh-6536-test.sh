#!/bin/bash
# tests/needs-human-step-done.bh-6536-test.sh — the pure rules and the stage
# row of bin/lib/needs-human/step-done.sh (BH-6536), loaded the way every lane
# loads it: through bin/lib/needs-human.sh.
#   D1-D4   nh_sd_human_only answers rc 0 (the action is the NEEDS_HUMAN: value,
#           else the first human-step line) for a human-step-only BLOCK: a
#           NEEDS_HUMAN line + a "not applied" B-line, a DATA_LANE path outside
#           scripts/migrations (TK-232's prisma/sql/), a "needs a human" BLOCK
#           with no B-lines, and a human-only final round after a code round
#   D5-D10  the adversarial negatives answer rc 1 (code finding beside the human
#           step, APPROVE, a NEEDS_HUMAN placeholder, a fenced/quoted human line,
#           a non-blocking aside, a human-only EARLIER round), and an APPROVE
#   D11     a missing file is rc 2
#   D12     nh_sd_stage_put -> nh_sd_stage_lines round trip, the dedupe (no
#           second PUT for the same state and reason), the age window
#   D13     the PUT body: kind, key, status, the detail shape the kanban parses,
#           and a token in the reason masked
#   D14     nh_sd_done_after: a person's done and a PASS probe after since are
#           evidence; a Bot's, a quoted one, one AT since, a FAIL probe are not;
#           a non-array thread or a bad since is rc 2
#   D15     nh_sd_pending: the record states it reads
# Run from anywhere: bash tests/needs-human-step-done.bh-6536-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

LIB="$DIR/bin/lib/needs-human.sh"
STEP="$DIR/bin/lib/needs-human/step-done.sh"
[ -r "$STEP" ] || { echo "FAIL: $STEP is missing"; exit 1; }
unset _NH_LIB_LOADED _DL_LIB_LOADED DL_BLOCK_RE RESCUE_HUMAN_STEP
# shellcheck source=bin/lib/needs-human.sh
. "$LIB" || { echo "FAIL: $LIB did not load"; exit 1; }
command -v nh_sd_human_only >/dev/null 2>&1 || { echo "FAIL: needs-human.sh does not load step-done.sh"; exit 1; }

rv() { # rv <name> <text> — write a review fixture, print its path
  printf '%s\n' "$2" > "$T/$1.md"; printf '%s' "$T/$1.md"
}
yes_case() { # yes_case <id> <want action> <review text>
  local out rc
  out=$(nh_sd_human_only "$(rv "$1" "$3")"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "human-step	$2" ] && ok || bad "$1: want rc 0 'human-step<TAB>$2', got rc $rc '$out'"
}
no_case() { # no_case <id> <review text>
  local out rc
  out=$(nh_sd_human_only "$(rv "$1" "$2")"); rc=$?
  [ "$rc" = 1 ] && [ "$out" = none ] && ok || bad "$1: want rc 1 'none', got rc $rc '$out'"
}

# ── D1-D4: human-step-only BLOCKs ──────────────────────────────────────────
yes_case D1 'apply migration 0020 in prod' '## Findings
B1 migration 0020 not applied in prod — the table is read on every load.
NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK'
yes_case D2 'B1 prisma/sql/0020_x.sql must run before this deploys.' 'B1 prisma/sql/0020_x.sql must run before this deploys.
DATA_LANE: prisma/sql/0020_x.sql
TIER: 2
VERDICT: BLOCK'
yes_case D3 'The diff is sound. This needs a human to run the vs_publish probe; the build box cannot.' 'The diff is sound. This needs a human to run the vs_publish probe; the build box cannot.
TIER: 2
VERDICT: BLOCK'
yes_case D4 'apply migration 0020 in prod' 'B1 the guard returns early on empty input.
TIER: 2
VERDICT: BLOCK
=== MERGED RE-REVIEW round 2 (head abcdef1) ===
B1 migration 0020 not applied in prod.
NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK'

# ── D5-D10: adversarial negatives ─────────────────────────────────────────
no_case D5 'B1 migration 0020 not applied in prod.
B2: the guard returns early on empty input
NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK'
no_case D6 'The step needs a human to apply migration 0020, and that is done.
TIER: 2
VERDICT: APPROVE'
no_case D7 'B1 the guard returns early on empty input.
NEEDS_HUMAN: none
TIER: 2
VERDICT: BLOCK'
no_case D8 'The reviewer notes:
```
B1 needs a human to apply migration 0020
```
> needs a human to apply migration 0020
TIER: 2
VERDICT: BLOCK'
no_case D9 'B1 the token is logged in plain text.
non-blocking: needs a human to rotate the key later
TIER: 2
VERDICT: BLOCK'
no_case D10 'B1 migration 0020 not applied in prod.
NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK
=== MERGED RE-REVIEW round 2 (head abcdef1) ===
B1 the guard returns early on empty input.
TIER: 2
VERDICT: BLOCK'
no_case D10b 'B1 migration 0020 not applied in prod.
NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: APPROVE'

# ── D11: unreadable ───────────────────────────────────────────────────────
OUT=$(nh_sd_human_only "$T/absent.md"); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "D11: a missing file is rc 2 with no output, got rc $RC '$OUT'"

# ── D12/D13: the stage row, local copy and ledger PUT ─────────────────────
mkdir -p "$T/fakebin" "$T/h"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$STUBREQ"
printf '{"ok":true}\n200\n'
EOF
chmod +x "$T/fakebin/curl"
STAGE_OUT=$(
  export PATH="$T/fakebin:$PATH" STUBREQ="$T/req.txt" HARNESS="$T/h" HARNESS_SECRET=test-secret-fixture \
         JOBS_URL=https://jobs.invalid JOBS_BOX=test-box AGENT_CALL_LANE=review-rescue
  : > "$T/req.txt"
  # shellcheck source=bin/jobs-client.sh
  . "$DIR/bin/jobs-client.sh" >/dev/null 2>&1
  nh_sd_stage_put project-6-os 232 TK-232 rereview-block "findings posted on https://github.com/o/r/pull/289 by ghp_fixture0123456789abcdefXYZ"
  echo "puts1=$(grep -c '^PUT ' "$T/req.txt")"
  nh_sd_stage_put project-6-os 232 TK-232 rereview-block "findings posted on https://github.com/o/r/pull/289 by ghp_fixture0123456789abcdefXYZ"
  echo "puts2=$(grep -c '^PUT ' "$T/req.txt")"
  nh_sd_stage_put project-6-os 233 TK-233 human-step-waiting "waits for a person"
  nh_sd_stage_put project-6-os 234 TK-234 not-a-state "x"
  printf 'TK-1\treview\thuman-step-done\t%s\told row\n' "$(ISO 700000)" >> "$T/h/state/ticket-stage/project-6-os.tsv"
  echo "lines:"; nh_sd_stage_lines project-6-os
)
[ "$(sed -n 's/^puts1=//p' <<<"$STAGE_OUT")" = 1 ] && ok || bad "D12: the first put must PUT once: $STAGE_OUT"
[ "$(sed -n 's/^puts2=//p' <<<"$STAGE_OUT")" = 1 ] && ok || bad "D12: the same state and reason again must not PUT: $STAGE_OUT"
LINES=$(sed -n '/^lines:$/,$p' <<<"$STAGE_OUT" | sed 1d)
L232=$(awk -F'\t' '$1=="TK-232"' <<<"$LINES")
[ "$(cut -f2 <<<"$L232")" = review ] && [ "$(cut -f3 <<<"$L232")" = rereview-block ] && ok || bad "D12: TK-232 must read back review/rereview-block: '$L232'"
[ "$(cut -f5 <<<"$L232")" = "findings posted on https://github.com/o/r/pull/289 by ghp_[masked]" ] && ok || bad "D12/D13: the reason reads back with the token masked: '$(cut -f5 <<<"$L232")'"
[ "$(awk -F'\t' '$1=="TK-233" {print $3}' <<<"$LINES")" = human-step-waiting ] && ok || bad "D12: TK-233 must read back human-step-waiting"
grep -q 'TK-234' <<<"$LINES" && bad "D12: an unknown state must write nothing" || ok
grep -q 'TK-1	' <<<"$LINES" && bad "D12: a row older than NH_SD_STAGE_MAX_AGE_S must not be printed" || ok
PUT=$(grep -m1 '^PUT ' "$T/req.txt" | sed 's/^PUT [^ ]* //')
[ "$(jq -r '.kind' <<<"$PUT")" = ticket_stage ] && [ "$(jq -r '.key' <<<"$PUT")" = 'project-6-os#232' ] && [ "$(jq -r '.status' <<<"$PUT")" = review ] && ok \
  || bad "D13: the PUT must be kind ticket_stage, key project-6-os#232, status review: $PUT"
DET=$(jq -r '.detail' <<<"$PUT")
[[ "$DET" =~ ^rereview-block\ by\ review-rescue\ at\ [0-9T:Z-]+:\ findings\ posted ]] && ok || bad "D13: the detail must be '<state> by <lane> at <iso>: <reason>', got '$DET'"
grep -q 'ghp_fixture0123456789' "$T/req.txt" && bad "D13: the token must never reach the ledger" || ok
grep -q 'ghp_fixture0123456789' "$T/h/state/ticket-stage/project-6-os.tsv" && bad "D13: the token must never reach the local copy" || ok

# ── D14: nh_sd_done_after ─────────────────────────────────────────────────
SINCE=$(ISO 7200)
C() { jq -nc --arg b "$1" --arg c "$2" --arg t "${3:-User}" --arg l "${4:-operator}" \
  '{body:$b, created_at:$c, html_url:"https://github.com/o/r/issues/232#issuecomment-9", user:{login:$l, type:$t}}'; }
TH() { jq -sc . <<<"$*"; }
da() { nh_sd_done_after "$1" "$2" >/dev/null 2>&1; echo $?; }
[ "$(da "$(TH "$(C 'HUMAN-STEP-DONE: applied 0020' "$(ISO 3600)")")" "$SINCE")" = 0 ] && ok || bad "D14: a person's done after since is evidence"
OUT=$(nh_sd_done_after "$(TH "$(C 'old' "$(ISO 9000)")" "$(C $'\n  HUMAN-STEP-DONE: applied 0020\nSELECT 1 fixture' "$(ISO 3600)")")" "$SINCE")
[ "$(sed -n 2p <<<"$OUT")" = "author: @operator at $(ISO 3600)" ] && grep -q '^SELECT 1 fixture$' <<<"$OUT" && ok || bad "D14: the evidence names the author, the time and the body: '$OUT'"
[ "$(da "$(TH "$(C '## Hub probe app-status-write PASS' "$(ISO 3600)")")" "$SINCE")" = 0 ] && ok || bad "D14: a PASS hub probe after since is evidence"
[ "$(da "$(TH "$(C 'HUMAN-STEP-DONE: done' "$(ISO 3600)" Bot 'cromford[bot]')")" "$SINCE")" = 1 ] && ok || bad "D14: a Bot's done is not evidence"
[ "$(da "$(TH "$(C $'I read the docs.\nHUMAN-STEP-DONE: is the marker' "$(ISO 3600)")")" "$SINCE")" = 1 ] && ok || bad "D14: a quoted done mid-body is not evidence"
[ "$(da "$(TH "$(C 'HUMAN-STEP-DONE: done' "$SINCE")")" "$SINCE")" = 1 ] && ok || bad "D14: a done AT since is not after it"
[ "$(da "$(TH "$(C 'HUMAN-STEP-DONE: done' "$(ISO 9000)")")" "$SINCE")" = 1 ] && ok || bad "D14: a done before the RESULT is not evidence"
[ "$(da "$(TH "$(C '## Hub probe x PASS then FAIL' "$(ISO 3600)")")" "$SINCE")" = 1 ] && ok || bad "D14: a probe with FAIL is not evidence"
[ "$(da '{"message":"x"}' "$SINCE")" = 2 ] && ok || bad "D14: a non-array thread is rc 2"
[ "$(da '' "$SINCE")" = 2 ] && ok || bad "D14: an empty thread read is rc 2"
[ "$(da '[]' 'yesterday')" = 2 ] && ok || bad "D14: a since that is not ISO is rc 2"
[ "$(da '[]' "$SINCE")" = 1 ] && ok || bad "D14: an empty array is no evidence (rc 1)"

# ── D15: nh_sd_pending ────────────────────────────────────────────────────
mkrec() { local r="$T/rec-$1"; mkdir -p "$r"; printf '%s\n' "$2" > "$r/RESULT"; cp "$3" "$r/review.md"; printf '%s' "$r"; }
R=$(mkrec a 'REVIEW_BLOCKED review.md' "$T/D1.md")
nh_sd_pending "$R" && ok || bad "D15: a REVIEW_BLOCKED human-only record is pending"
( RESCUE_HUMAN_STEP=0; nh_sd_pending "$R" ) && bad "D15: RESCUE_HUMAN_STEP=0 is never pending" || ok
: > "$R/.review-rescued"; nh_sd_pending "$R" && bad "D15: .review-rescued is not pending" || ok
R=$(mkrec b 'PR_CREATED https://github.com/o/r/pull/1' "$T/D1.md"); nh_sd_pending "$R" && bad "D15: PR_CREATED is not pending" || ok
R=$(mkrec c 'REVIEW_BLOCKED review.md' "$T/D5.md"); nh_sd_pending "$R" && bad "D15: a code BLOCK is not pending" || ok
R=$(mkrec d 'REVIEW_BLOCKED review.md' "$T/D1.md"); : > "$R/.blocked-resolver-superseded"; nh_sd_pending "$R" && bad "D15: a superseded record is not pending" || ok

echo "needs-human-step-done.bh-6536-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
