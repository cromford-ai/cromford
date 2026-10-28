#!/bin/bash
# tests/review-tier-medium.bh-6967-test.sh — BH-6967 (BH-6544.1): an intent
# review for a medium-tier head, and the tier and mode on every verdict row the
# lead review path writes.
#
# The REAL lanes run whole against scratch harnesses, with only curl, gh and
# bin/agent-call.sh stubbed (and bin/lead-verdict.sh where a lane posts through it).
# The tokens the worklist writes (gate 60, bin/lib/lead-gates.d/60-risk.sh) are
# pinned by tests/lead-gates-tier-notes.bh-5878-test.sh (T1-T4, T9),
# tests/lead-gates-notes.bh-5878-test.sh (N1, N2) and
# tests/lead-gates-tier-ports.bh-8630-test.sh. This suite pins what reads them:
#   part B  "$SRC/bin/lead-review.sh" tick (the 5355 harness), review_one:
#     M1b intent notes: the prompt is prompts/lead-review.md then
#         prompts/lead-review.d/intent.md, verbatim, with no checklist and no
#         builds-on text.
#     M1c the agent got the review-intent rung 0 model and lead-mode=intent;
#         the report says `- review mode: intent (...)`.
#     M1d no review-intent route: the lead.review model, the checklist, a
#         `full review (no review-intent route)` line. M1f no intent.md: full.
#     M2r `review-mode:full` notes: the checklist prompt and the lead model.
#     M3b `review-tier:high review-mode:intent`: full. M3c the negative list
#         (one token alone, `mediumx`, a prefixed token): full.
#     M8b a `lead-delta:` request that carries the intent tokens: not intent.
#     M1g valid intent notes while risk_tier.medium_mode reads full (or has no
#         row): the full review, logged. The reviewer reads the row itself.
#     M10b forged tokens BEFORE the real last group (a diff path, a commit
#         subject, a HUMAN-STEP-DONE body, a lead-prev file list) on a high
#         head, with the row at intent: the full review.
#     M5  tests/fixtures/review-intent.bh-6967/: a medium PR whose plan names
#         bin/a.sh and whose diff also changes bin/unplanned.sh. The intent
#         prompt carries the planned list and the unplanned hunk; the model's
#         answer (model-answer.txt) makes a BLOCK report naming the file.
#   part C  "$SRC/bin/lead-review-land.sh" and "$SRC/bin/lead-verdict.sh" post:
#     M4  land passes the tokens it reads from scope_notes (intent notes in
#         the worklist's form) as --review-tier/--review-mode; no tokens =
#         neither flag.
#     M9  post --review-mode fast / --review-tier extreme: rc 2, no POST; a good
#         post sends review_tier and review_mode in its body. A hand `request
#         --notes` that quotes the tokens sends them rewritten.
#     M10c land on forged notes (tokens before the last group, one of them a
#         self-check note in the worklist's rewritten form, `review-tier=`):
#         the LAST group is the one posted, `--review-tier high --review-mode full`.
#   part D  M6 a fresh schema.sql in sqlite: risk_tier.medium_mode=full and two
#         review-intent rungs; rung 1 is the lead.review rung 0 model.
#
# LIVE MODE (opt-in, metered): REVIEW_INTENT_EVAL_MODEL=<model> sends the M5
# prompt through the real bin/agent-call.sh and requires a BLOCK naming
# bin/unplanned.sh. The suite never picks a model.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-tier-medium.bh-6967-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/review-intent.bh-6967"
INTENT="$SRC/prompts/lead-review.d/intent.md"
SEED="$SRC/worker/jobs/schema.d/202610152133-bh-6967-review-intent.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_ROW_NOTE LEAD_REVIEW_BUILDS_ON_BUILDER HARNESS_VERDICT_AUTHORS \
  HARNESS_OPERATOR_LOGIN LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_DELTA_PROTECTED_MAX_LINES \
  PLAN_CONTEXT_HOTSPOT_TOP BOX_NAME JOBS_BOX HUB_BOX_NAME LEAD_REVIEW_OVERDUE_MIN

[ -f "$INTENT" ] && ok || bad "T1 prompts/lead-review.d/intent.md does not exist"
for f in pr-body.md diff.patch model-answer.txt; do [ -f "$FX/$f" ] || { echo "FAIL: fixture $f missing"; exit 1; }; done

# ═══════════════════════ setup shared by parts B, C and D ═══════════════════
mkdir -p "$T/log" "$T/tmp" "$T/cfg"
printf 'lead-test-token-fixture\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}

# ═══════════════════════ part B: bin/lead-review.sh review_one ═══════════════════
HB="$T/hb"; mkdir -p "$HB/bin" "$HB/prompts/lead-review.d" "$HB/catalog/lanes.d" "$HB/state" "$HB/env" "$T/brepos" "$T/bbin"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
t=\$(cat "$T/case")
echo x >> "$T/log/calls.\$t"
cp "\${6#@}" "$T/log/prompt.\$t"
printf '%s\n' "\${AGENT_CALL_ROW_NOTE-<unset>}" > "$T/log/note.\$t"
printf '%s\n' "\$3" > "$T/log/model.\$t"
if [ -f "$T/answer" ]; then cat "$T/answer" > "\$5"; else printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"; fi
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$SRC/prompts/lead-review-builds-on.md" "$HB/prompts/"
cp "$INTENT" "$HB/prompts/lead-review.d/" 2>/dev/null
echo box-demo > "$HB/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$HB/fleet.conf"
BLOG="$HB/logs/lead-review.log"

BOR="$T/borigin.git"; BWK="$T/bwork"
git init -q --bare -b main "$BOR"; git init -q -b main "$BWK"; mkdir -p "$BWK/bin"
printf '#!/bin/bash\necho "hello"\n' > "$BWK/bin/a.sh"; printf '#!/bin/bash\necho "unplanned"\n' > "$BWK/bin/unplanned.sh"
git -C "$BWK" add -A; git -C "$BWK" commit -qm base; git -C "$BWK" push -q "$BOR" main
git -C "$BWK" apply --index "$FX/diff.patch" && ok || bad "M5 setup: diff.patch does not apply"
git -C "$BWK" commit -qm "the fixture pr"; BH=$(git -C "$BWK" rev-parse HEAD); BH12=${BH:0:12}
git -C "$BWK" push -q "$BOR" "HEAD:refs/pull/77/head"
git clone -q "$BOR" "$T/brepos/demo-os"

cat > "$T/bbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/settings/risk_tier.medium_mode")
    if [ -f "$T/bmode" ]; then out=\$(jq -nc --arg v "\$(cat "$T/bmode")" '{setting:{key:"risk_tier.medium_mode",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/model-routes/review-intent"*)
    if [ -e "$T/no-intent-route" ]; then out='{"ladder":[],"source":"none"}'
    else out='{"ladder":[{"position":0,"model":"fixture-intent-model","runner":"claude"},{"position":1,"model":"fixture-lead-model","runner":"claude"}],"source":"hub"}'; fi ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"fixture-lead-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/bbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/reviews"*) echo "\$*" >> "$T/log/reviews-reads"; printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$BH" --rawfile b "$FX/pr-body.md" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"BH-9001: fixture greeting",body:\$b}' ;;
esac
exit 0
EOF
chmod +x "$T/bbin/curl" "$T/bbin/gh"

# compose <tag> <scope notes> [VAR=value ...] — one review_one of PR 77 at $BH.
compose() {
  local tag="$1" sn="$2"; shift 2
  echo "$tag" > "$T/case"
  rm -f "$T/log/calls.$tag" "$T/log/prompt.$tag" "$T/log/note.$tag" "$T/log/model.$tag" "$BLOG" "$T/log/reviews-reads"
  scratch_rm "$HB/state/lead-reviews"; scratch_rm "$HB/state/lead-review"; scratch_rm "$HB/state/model-routes"; mkdir -p "$HB/state/lead-reviews"
  jq -nc --arg s "$BH" --arg n "$sn" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:77,head_sha:$s,
    scope_notes:$n,prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  ( cd "$T" && env PATH="$T/bbin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/brepos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 "$@" bash "$HB/bin/lead-review.sh" tick ) > "$T/out.$tag" 2>&1
  cp "$HB/state/lead-reviews/lr-77-$BH12.md" "$T/log/report.$tag" 2>/dev/null || : > "$T/log/report.$tag"
  cp "$BLOG" "$T/log/lane.$tag" 2>/dev/null || : > "$T/log/lane.$tag"
}
calls() { [ -f "$T/log/calls.$1" ] && wc -l < "$T/log/calls.$1" | tr -d ' ' || echo 0; }
lineof() { grep -nxF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
CKL1=$(sed -n 1p "$SRC/prompts/lead-review-checklist.md")
BOL1=$(sed -n 1p "$SRC/prompts/lead-review-builds-on.md")
# full_check <tag> <case> — a full review: the checklist prompt, the lead model, no intent text
full_check() {
  [ "$(calls "$1")" = 1 ] || { bad "$2 agent called $(calls "$1") time(s): $(cat "$T/out.$1") $(cat "$T/log/lane.$1")"; return; }
  grep -qxF -- "$CKL1" "$T/log/prompt.$1" && ok || bad "$2 a full review without the checklist"
  [ "$(cat "$T/log/model.$1")" = fixture-lead-model ] && ok || bad "$2 model '$(cat "$T/log/model.$1")', want the lead.review model"
  grep -qxF -- "$(sed -n 1p "$INTENT")" "$T/log/prompt.$1" && bad "$2 a full review carries the intent text" || ok
  grep -q '^- review mode: intent' "$T/log/report.$1" && bad "$2 the report claims intent mode" || ok
  [ "$(cat "$T/log/note.$1")" = lead-mode=intent ] && bad "$2 the cost row says lead-mode=intent" || ok
}
INOTES="auto: builder APPROVE on $BH12; review-tier:medium review-mode:intent"
printf ' Intent ' > "$T/bmode"

# ── M1b / M1c: intent notes -> lead-review.md + intent.md, the review-intent model ──
compose m1 "$INOTES"
P="$T/log/prompt.m1"
[ "$(calls m1)" = 1 ] && ok || bad "M1b agent called $(calls m1) time(s): $(cat "$T/out.m1") $(cat "$T/log/lane.m1")"
n=$(wc -l < "$SRC/prompts/lead-review.md")
head -n "$n" "$P" | cmp -s - "$SRC/prompts/lead-review.md" && ok || bad "M1b the prompt does not start with prompts/lead-review.md verbatim"
s=$(lineof "$P" "$(sed -n 1p "$INTENT")"); ni=$(wc -l < "$INTENT")
if [ -n "$s" ]; then
  sed -n "${s},$((s + ni - 1))p" "$P" | cmp -s - "$INTENT" && ok || bad "M1b intent.md is not in the prompt verbatim"
  [ "$s" -le $((n + 2)) ] && ok || bad "M1b intent.md starts at line $s, not right after lead-review.md ($n lines)"
  prl=$(lineof "$P" '## PR'); [ -n "$prl" ] && [ "$s" -lt "$prl" ] && ok || bad "M1b intent.md is not before ## PR"
else
  bad "M1b the prompt lacks intent.md"
fi
grep -q 'Checklist-Version' "$P" && bad "M1b the intent prompt carries the checklist" || ok
grep -qxF -- "$BOL1" "$P" && bad "M1b the intent prompt carries the builds-on text" || ok
grep -qxF '## Builder review (same head)' "$P" && bad "M1b the intent prompt carries a builder section" || ok
[ -s "$T/log/reviews-reads" ] && bad "M1b intent mode read the builder reviews" || ok
grep -qxF '## Diff' "$P" && grep -qxF '## Scope notes' "$P" && ok || bad "M1b the later sections are missing"
[ "$(cat "$T/log/model.m1")" = fixture-intent-model ] && ok || bad "M1c model '$(cat "$T/log/model.m1")', want the review-intent rung 0"
[ "$(cat "$T/log/note.m1")" = lead-mode=intent ] && ok || bad "M1c row note '$(cat "$T/log/note.m1")'"
grep -qx -- '- review mode: intent (risk tier medium, route review-intent)' "$T/log/report.m1" && ok \
  || bad "M1c the report lacks the intent header: $(head -n 12 "$T/log/report.m1")"
grep -qx -- '- checklist: none (intent review)' "$T/log/report.m1" && ok || bad "M1c the report names a checklist it did not read"
grep -q "reviewer model: fixture-intent-model" "$T/log/report.m1" && ok || bad "M1c the report names another model"

# ── M1d: no review-intent route -> a full review on lead.review, logged ──
: > "$T/no-intent-route"; compose m1d "$INOTES"; rm -f "$T/no-intent-route"
full_check m1d M1d
grep -q 'full review (no review-intent route)' "$T/log/lane.m1d" && ok || bad "M1d no fallback line: $(cat "$T/log/lane.m1d")"

# ── M1f: no intent.md on the box -> a full review, logged ──
mv "$HB/prompts/lead-review.d/intent.md" "$T/intent.away"; compose m1f "$INOTES"; mv "$T/intent.away" "$HB/prompts/lead-review.d/intent.md"
full_check m1f M1f
grep -q 'full review (prompts/lead-review.d/intent.md missing)' "$T/log/lane.m1f" && ok || bad "M1f no fallback line: $(cat "$T/log/lane.m1f")"

# ── M2r: review-mode:full -> unchanged ──
compose m2 "auto: x; review-tier:medium review-mode:full"; full_check m2 M2r
[ "$(cat "$T/log/note.m2")" = lead-mode=full ] && ok || bad "M2r row note '$(cat "$T/log/note.m2")'"
# ...and the same prompt as a request with no tokens at all (only the scope notes line differs)
compose m2n "auto: x"
diff <(grep -v '^auto: x' "$T/log/prompt.m2") <(grep -v '^auto: x' "$T/log/prompt.m2n") >/dev/null && ok || bad "M2r a full-token prompt differs from today's prompt"

# ── M3b / M3c: high, and the negative list ──
i=0
for sn in "auto: x; review-tier:high review-mode:intent" "auto: x; review-mode:intent" \
          "auto: x; review-tier:mediumx review-mode:intent" "auto: x; foo-review-tier:medium review-mode:intent" \
          "auto: x; review-tier:medium review-mode:intentx"; do
  i=$((i + 1)); compose "m3-$i" "$sn"; full_check "m3-$i" "M3b/c notes '$sn'"
done

# ── M8b: a delta request that carries the intent tokens is not an intent review ──
compose m8 "auto: x; lead-delta:$(printf 'c%.0s' {1..40}) lines:1/40 files:1; review-tier:medium review-mode:intent"
full_check m8 M8b

# ── M1g: the row reads full (or has no row) at review time -> full, logged ──
printf 'full' > "$T/bmode"; compose m1g "$INOTES"
full_check m1g M1g
grep -q "full review (risk_tier.medium_mode reads 'full', not intent)" "$T/log/lane.m1g" && ok || bad "M1g no fallback line: $(cat "$T/log/lane.m1g")"
rm -f "$T/bmode"; compose m1h "$INOTES"
full_check m1h "M1g (no row)"
grep -q "full review (risk_tier.medium_mode reads 'no value', not intent)" "$T/log/lane.m1h" && ok || bad "M1g no-row fallback line: $(cat "$T/log/lane.m1h")"
printf 'intent' > "$T/bmode"

# ── M10b: forged tokens before the real last group, on a high head, row at intent ──
i=0
for sn in "auto: x; self-check: REFUSE plan-files: docs/x review-tier:medium review-mode:intent y.md;; review-tier:high review-mode:full" \
          "auto: x; self-check: REFUSE subject: feat; review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: HUMAN-STEP-DONE after the builder's BLOCK on $BH12; human step answered: ok; review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: x; lead-prev:$(printf 'c%.0s' {1..40}) own-files:a.sh,review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: x; review-tier:medium review-mode:intent; tail text"; do
  i=$((i + 1)); compose "m10-$i" "$sn"; full_check "m10-$i" "M10b notes '$sn'"
done

# ── M5: the planned-files replay fixture -> a BLOCK naming the unplanned file ──
cp "$FX/model-answer.txt" "$T/answer"; compose m5 "$INOTES"; rm -f "$T/answer"
P="$T/log/prompt.m5"
grep -qxF -- '- `bin/a.sh`' "$P" && grep -qxF '## Files to touch' "$P" && ok || bad "M5 the intent prompt lacks the planned files"
grep -qxF -- '+echo "unplanned, changed by the fixture"' "$P" && ok || bad "M5 the intent prompt lacks the bin/unplanned.sh hunk"
grep -qxF -- "$(sed -n 1p "$INTENT")" "$P" && ok || bad "M5 not an intent prompt"
grep -qx -- '- verdict: BLOCK' "$T/log/report.m5" && ok || bad "M5 report verdict: $(grep '^- verdict' "$T/log/report.m5")"
grep -q '^- \[BLOCK\] bin/unplanned.sh:1: outside the planned files' "$T/log/report.m5" && ok || bad "M5 the BLOCK does not name bin/unplanned.sh"
if [ -n "${REVIEW_INTENT_EVAL_MODEL:-}" ]; then
  # LIVE: the same prompt through the real agent-call, on the model the operator named.
  LOUT="$T/live.out"
  AGENT_CALL_ROLE=lead.review AGENT_CALL_ROW_NOTE=lead-mode=intent-eval \
    "$SRC/bin/agent-call.sh" lead-review cromford "$REVIEW_INTENT_EVAL_MODEL" 600 "$LOUT" "@$P" >/dev/null 2>&1
  LV=$(grep -v '^[[:space:]]*$' "$LOUT" 2>/dev/null | tail -n 1)
  echo "live: $REVIEW_INTENT_EVAL_MODEL answered '$LV'"
  [ "$LV" = "VERDICT: BLOCK" ] && grep -q 'bin/unplanned.sh' "$LOUT" && ok || bad "LIVE $REVIEW_INTENT_EVAL_MODEL did not BLOCK naming bin/unplanned.sh"
fi

# ═══════════════════ part C: bin/lead-review-land.sh, bin/lead-verdict.sh ═══════════════════
HL="$T/hl"; mkdir -p "$HL/state" "$HL/logs" "$T/lbin"
scratch_install_closure bin/jobs-client.sh "$HL" >/dev/null || exit 1
scratch_install_closure bin/lead-review-land.sh "$HL" >/dev/null || exit 1
cat > "$HL/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/landlv"
echo "recorded verdict #9: MERGE"
exit 0
EOF
cat > "$HL/bin/lane-alert.sh" <<EOF
#!/bin/bash
exit 0
EOF
chmod +x "$HL/bin/lead-verdict.sh" "$HL/bin/lane-alert.sh"
cat > "$T/lbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
printf '%s %s\n' "\$m" "\$p" >> "$T/log/lworker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/lrequests.json") ;;
  "GET /api/verdicts?"*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "POST /api/lead-reviews/"*/promoted) out='{"request":{"promoted_verdict_at":"2026-10-15T00:00:00Z"}}' ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/lbin/gh"
chmod +x "$T/lbin/curl" "$T/lbin/gh"
# land <scope notes> — one done MERGE request on example-org/demo-os#41 with those notes, one land tick
land() {
  rm -f "$T/log/landlv" "$T/log/lworker"; scratch_rm "$HL/state/lead-review-land"; echo box-hub > "$HL/state/box-name"
  jq -nc --arg s "$SHA" --arg n "$1" '{requests:[{id:"lr-1", repo:"example-org/demo-os", pr:41, head_sha:$s, status:"done",
    verdict:"MERGE", reviewer_model:"fixture-intent-model", report_ref:"state/lead-reviews/lr-41-aaaaaaaaaaaa.md",
    promoted_verdict_at:null, detail:null, scope_notes:$n, created_at:"2026-10-15T00:00:00Z", updated_at:"2026-10-15T00:00:00Z"}], truncated:false}' > "$T/lrequests.json"
  ( cd "$T" && env PATH="$T/lbin:$PATH" HARNESS="$HL" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
      TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" bash "$HL/bin/lead-review-land.sh" ) > "$T/out.land" 2>&1
  LLV=$(head -1 "$T/log/landlv" 2>/dev/null)
}
# ── M4: intent notes in the worklist's form -> the flags on the verdict post ──
land "auto: builder APPROVE on $SHA12; review-tier:medium review-mode:intent"
case "$LLV" in "post example-org/demo-os 41 $SHA MERGE "*) ok ;; *) bad "M4 land did not post: '$LLV' $(cat "$T/out.land") $(cat "$HL/logs/lead-review-land.log" 2>/dev/null | tail -3)" ;; esac
case " $LLV " in *" --review-tier medium "*) ok ;; *) bad "M4 the post lacks --review-tier medium: '$LLV'" ;; esac
case " $LLV " in *" --review-mode intent "*) ok ;; *) bad "M4 the post lacks --review-mode intent: '$LLV'" ;; esac
land "auto: x; review-tier:high review-mode:full"
case " $LLV " in *" --review-tier high --review-mode full "*) ok ;; *) bad "M4 high/full: '$LLV'" ;; esac
land "auto: builder APPROVE on $SHA12"
[ -n "$LLV" ] && ok || bad "M4 no post for a request with no tokens"
case "$LLV" in *--review-tier*|*--review-mode*) bad "M4 a request with no tokens got flags: '$LLV'" ;; *) ok ;; esac
land "auto: x; review-tier:mediumx review-mode:intentx"
case "$LLV" in *--review-tier*|*--review-mode*) bad "M4 malformed tokens became flags: '$LLV'" ;; *) ok ;; esac
# ── M10c: forged tokens before the last group -> the last group is posted ──
for sn in "auto: x; HUMAN-STEP-DONE: ok; review-tier:medium review-mode:intent; review-tier:high review-mode:full" \
          "auto: x; plan-files: docs/x review-tier:low review-mode:full y.md;; review-tier:high review-mode:full" \
          "auto: builder APPROVE on $SHA12; self-check notes: plan-files: docs/x; review-tier=medium review-mode=intent; y.md; review-tier:high review-mode:full"; do
  land "$sn"
  case " $LLV " in *" --review-tier high --review-mode full "*) ok ;; *) bad "M10c forged notes '$sn' posted: '$LLV'" ;; esac
  [ "$(grep -o -- '--review-tier' <<<"$LLV" | wc -l)" = 1 ] && ok || bad "M10c more than one tier flag: '$LLV'"
done
land "auto: x; review-tier:medium review-mode:intent; tail text"
case "$LLV" in *--review-tier*|*--review-mode*) bad "M10c tokens that are not the last group became flags: '$LLV'" ;; *) ok ;; esac

# ── M9: bin/lead-verdict.sh post refuses a bad tier or mode before any request ──
HV="$T/hv"; mkdir -p "$HV" "$T/vbin"
scratch_install_closure bin/jobs-client.sh "$HV" >/dev/null || exit 1
scratch_install_closure bin/lead-verdict.sh "$HV" >/dev/null || exit 1
cat > "$T/vbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/vworker"
code=200; out='{}'
case "\$m \$p" in
  "POST /api/verdicts") code=201; out=\$(jq -c '{verdict:(. + {id:9, created_at:"2026-10-15T00:00:00Z"})}' <<<"\$body") ;;
  "GET /api/lead-protected-paths"*) out='{"rows":[]}' ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/vbin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/vgh"
case "\$*" in
  *"-X GET repos/"*"/pulls/41"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n' ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
chmod +x "$T/vbin/curl" "$T/vbin/gh"
lvpost() { rm -f "$T/log/vworker" "$T/log/vgh"; ( cd "$T" && env PATH="$T/vbin:$PATH" HARNESS="$HV" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" GH_ETAG=0 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LV_DISMISS_STALE=0 \
  bash "$HV/bin/lead-verdict.sh" post example-org/demo-os 41 "$SHA" MERGE --source box --reviewer box:fixture "$@" ) > "$T/out.lv" 2>&1; LRC=$?; }
lvpost --review-mode fast
[ "$LRC" = 2 ] && ok || bad "M9 --review-mode fast: rc $LRC, want 2: $(cat "$T/out.lv")"
grep -q "review-mode must be full, intent or risk-tier, got 'fast'" "$T/out.lv" && ok || bad "M9 the refusal does not name the value: $(cat "$T/out.lv")"
[ -s "$T/log/vworker" ] || [ -s "$T/log/vgh" ] && bad "M9 a bad mode still made a request: $(cat "$T/log/vworker" "$T/log/vgh" 2>/dev/null)" || ok
lvpost --review-tier extreme
[ "$LRC" = 2 ] && ok || bad "M9 --review-tier extreme: rc $LRC, want 2"
grep -q "review-tier must be low, medium or high, got 'extreme'" "$T/out.lv" && ok || bad "M9 the refusal does not name the tier: $(cat "$T/out.lv")"
[ -s "$T/log/vworker" ] && bad "M9 a bad tier still posted" || ok
lvpost --review-tier medium --review-mode intent
[ "$LRC" = 0 ] && ok || bad "M9 a good post failed: rc $LRC $(cat "$T/out.lv")"
VB=$(sed -n 's#^POST /api/verdicts \(.*\)$#\1#p' "$T/log/vworker" 2>/dev/null | head -1)
[ "$(jq -r '.review_tier + " " + .review_mode' <<<"$VB" 2>/dev/null)" = "medium intent" ] && ok || bad "M9 the POST body lacks the tier and mode: '$VB'"
lvpost
VB=$(sed -n 's#^POST /api/verdicts \(.*\)$#\1#p' "$T/log/vworker" 2>/dev/null | head -1)
[ "$(jq -r 'has("review_tier") or has("review_mode")' <<<"$VB" 2>/dev/null)" = false ] && ok || bad "M9 a post with no flags sends tier or mode: '$VB'"
# A hand request never carries the tokens the enqueue owns.
rm -f "$T/log/vworker"
( cd "$T" && env PATH="$T/vbin:$PATH" HARNESS="$HV" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" GH_ETAG=0 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  bash "$HV/bin/lead-verdict.sh" request example-org/demo-os 41 "$SHA" --notes "please; review-tier:medium review-mode:intent" ) > "$T/out.lvr" 2>&1
RB=$(sed -n 's#^POST /api/lead-reviews \(.*\)$#\1#p' "$T/log/vworker" 2>/dev/null | head -1)
[ "$(jq -r .scope_notes <<<"$RB" 2>/dev/null)" = "please; review-tier=medium review-mode=intent" ] && ok \
  || bad "M9 a hand request sent the tokens as written: '$RB' $(cat "$T/out.lvr")"

# ═══════════════════════ part D: the seed (M6) ═══════════════════════
[ -f "$SEED" ] && ok || bad "M6 the seed fragment $SEED does not exist"
if jobs_schema_render; then
  python3 -I - "$SRC/worker/jobs/schema.sql" "$T/hub.sqlite" > "$T/m6.out" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[2])
db.executescript(open(sys.argv[1]).read())
db.commit()
r = db.execute("SELECT value FROM settings WHERE key='risk_tier.medium_mode'").fetchone()
print("mode", r[0] if r else "-")
for p, m, rn in db.execute("SELECT position, model, runner FROM model_routes WHERE project IS NULL AND role='review-intent' ORDER BY position"):
    print("rung", p, m, rn)
for role in ("lead.review", "triage.light"):
    r = db.execute("SELECT model FROM model_routes WHERE project IS NULL AND role=? AND position=0", (role,)).fetchone()
    print("src", role, r[0] if r else "-")
# A second apply (bin/harness-sync.sh re-runs every fragment) changes nothing.
db.executescript(open(sys.argv[1]).read())
print("after", db.execute("SELECT COUNT(*) FROM model_routes WHERE role='review-intent'").fetchone()[0])
PY
  [ "$?" = 0 ] && ok || bad "M6 the schema did not apply: $(head -3 "$T/m6.out")"
  grep -qx 'mode full' "$T/m6.out" && ok || bad "M6 risk_tier.medium_mode is not seeded full: $(grep mode "$T/m6.out")"
  LEADM=$(sed -n 's/^src lead.review //p' "$T/m6.out"); LIGHTM=$(sed -n 's/^src triage.light //p' "$T/m6.out")
  grep -qx "rung 0 $LIGHTM claude" "$T/m6.out" && ok || bad "M6 rung 0 is not the triage.light rung 0 ($LIGHTM): $(grep rung "$T/m6.out")"
  grep -qx "rung 1 $LEADM claude" "$T/m6.out" && ok || bad "M6 rung 1 is not the lead.review rung 0 ($LEADM): $(grep rung "$T/m6.out")"
  [ "$(grep -c '^rung ' "$T/m6.out")" = 2 ] && grep -qx 'after 2' "$T/m6.out" && ok || bad "M6 want 2 rungs, idempotent: $(cat "$T/m6.out")"
else
  bad "M6 jobs_schema_render failed"
fi
# No model literal enters the seed: every model value is copied from a row.
grep -qiE "'(claude|gpt|gemini)-" "$SEED" 2>/dev/null && bad "M6 the seed carries a model literal" || ok

echo "review-tier-medium.bh-6967: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
