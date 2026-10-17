#!/bin/bash
# tests/lead-review-stamp-note.bh-6842-test.sh — BH-6842: the lead review does
# not BLOCK on a rules-pack schema-fragment-name line whose only fault is the
# stamp order. The merge conductor's pre-queue step restamps the fragment
# (bin/lib/mc-prequeue.d/restamp.sh), so that line is a NOTE and the review goes
# on to the model. Every other schema-fragment-name line is still a BLOCK.
#
# Drives the REAL bin/lead-review.sh tick against a scratch harness
# (scratch_install_closure), with these stubbed:
#   * curl  — the jobs worker
#   * gh    — the REST read of pulls/<n>
#   * bin/agent-call.sh — counts calls, keeps each prompt
#   * bin/rules-pack.sh — prints $T/pack.stdout, exits $T/pack.rc
# The finding lines are the REAL rp_schema_fragment_name output
# (bin/lib/rules-pack-checks.sh) on fixture trees, with the component prefix
# bin/rules-pack.sh puts on every line.
#
#   L1  only a stamp-order line: no rules-pack BLOCK, one agent call, the
#       prompt's ## Rules pack names the stamp order and the merge-path restamp
#   L2  two stamp-order lines: as L1
#   L3  an NNNN-taken line: a rules-pack BLOCK, no agent call
#   L4  a malformed-name line: a rules-pack BLOCK, no agent call
#   L5  a stamp-order line and an index-on-create-table line: a BLOCK on the
#       index line, the stamp line a [NOTE]
#   M1  mutation: the split call removed, L1 is a rules-pack BLOCK again
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-stamp-note.bh-6842-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/schema-restamp.sh bin/lib/rules-pack-checks.sh; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAD_REVIEW_MAX_PER_PR_DAY=50
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DIFF_MAX_BYTES PLAN_CONTEXT_HOTSPOT_TOP

# ── the finding lines, from the real rules-pack check ──
# shellcheck source=bin/lib/rules-pack-checks.sh
. "$SRC/bin/lib/rules-pack-checks.sh" || exit 1
F="$T/fx"
# fx <pr-fragment...> — base: 0000-base + 202610150259-bh-1-a; the tree adds each
fx() {
  scratch_rm "$F" 2>/dev/null; mkdir -p "$F/worker/jobs/schema.d"; git -C "$F" init -q -b main
  # TEST-CHANGE (BH-7229): the base fragment creates table a and each PR
  # fragment uses it. A stale stamp alone is clean now; the use of a later base
  # table is the stamp-order line this suite needs.
  echo x > "$F/worker/jobs/schema.d/0000-base.sql"; echo 'CREATE TABLE a (id INTEGER);' > "$F/worker/jobs/schema.d/202610150259-bh-1-a.sql"
  git -C "$F" add -A; git -C "$F" commit -qm base
  local f; for f in "$@"; do echo 'INSERT INTO a VALUES (1);' > "$F/worker/jobs/schema.d/$f"; done
  git -C "$F" add -A; git -C "$F" commit -qm pr
  rp_schema_fragment_name "$F" HEAD~1 | sed 's/^/schema-fragment-name: /'
}
STAMP1=$(fx 202610142106-bh-2-b.sql)
STAMP2=$(fx 202610142106-bh-2-b.sql 202610142107-bh-2-c.sql)
TAKEN=$(fx 0000-bh-2-b.sql)
MAL=$(fx 1-bh-2-b.sql)
INDEX='index-on-create-table: worker/jobs/schema.d/202610142106-bh-2-b.sql: CREATE TABLE b has no CREATE INDEX in this diff'
[ "$(grep -c 'at the base creates and which sorts after this fragment' <<<"$STAMP1")" = 1 ] && [ "$(grep -c 'at the base creates and which sorts after this fragment' <<<"$STAMP2")" = 2 ] \
  && grep -q 'is already taken' <<<"$TAKEN" && grep -q 'never a picked number' <<<"$MAL" \
  && ok || bad "setup: the real rules-pack lines are not the expected shapes: [$STAMP1] [$STAMP2] [$TAKEN] [$MAL]"

HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
cp "\${6#@}" "$T/log/prompt.\$(wc -l < "$T/log/agent-count" | tr -d ' ')"
printf 'Findings\n- [NOTE] stamp order is fixed by the merge path\n\nVERDICT: MERGE-WITH-NOTES\n' > "\$5"
exit 0
EOF
cat > "$T/rules-pack.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/pack"
cat "$T/pack.stdout"
exit "\$(cat "$T/pack.rc")"
EOF
chmod +x "$HB/bin/agent-call.sh" "$T/rules-pack.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
[ -f "$HB/bin/lib/schema-restamp.sh" ] && ok || bad "the closure of bin/lead-review.sh does not carry bin/lib/schema-restamp.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
echo box-demo > "$HB/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$HB/fleet.conf"

O="$T/origin.git"; W="$T/work"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# cromford fixture\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" commit -qam "pr change"; git -C "$W" push -q "$O" HEAD:refs/pull/41/head
SHA=$(git -C "$W" rev-parse HEAD)
git clone -q "$O" "$T/repos/cromford"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/conflict-hotspots"*) out='{"hotspots":[],"run":null,"total":0,"limit":10,"truncated":false}' ;;
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$SHA" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

LLOG="$HB/logs/lead-review.log"
REPORT="$HB/state/lead-reviews/lr-41-${SHA:0:12}.md"
# setup <rc> <line...> — a clean slate, the real lane, the pack's answer
setup() {
  rm -f "$T/log"/* "$LLOG"
  scratch_rm "$HB/state/lead-reviews"
  cp "$SRC/bin/lead-review.sh" "$HB/bin/"
  cp "$T/rules-pack.sh" "$HB/bin/rules-pack.sh"
  echo "$1" > "$T/pack.rc"; shift; printf '%s\n' "$@" > "$T/pack.stdout"
  jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:41,head_sha:$s,
    scope_notes:"only the lane",prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
}
tick() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HB/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
}
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
result() { grep '^POST /api/lead-reviews/lr-1/result ' "$T/log/worker" 2>/dev/null | tail -n 1 | cut -d' ' -f3-; }
P1="$T/log/prompt.1"
rp_section() { awk '$0 == "## Rules pack" {f=1; next} /^## / {f=0} f' "$P1" 2>/dev/null; }
rpblock() { jq -e '.verdict == "BLOCK" and .reviewer_model == "rules-pack"' <<<"$(result)" >/dev/null 2>&1; }

# note_case <name> <line...> — the stamp lines alone: reviewed, not blocked
note_case() {
  local name="$1"; shift
  setup 1 "$@"; tick
  [ "$RC" -eq 0 ] && ok || bad "$name rc=$RC out=$(cat "$T/out")"
  rpblock && bad "$name a stamp-order line alone must not be a rules-pack BLOCK: $(result)" || ok
  [ "$(agents)" = 1 ] && ok || bad "$name the review must reach the model once, agent count $(agents) (log: $(tail -n 5 "$LLOG" 2>/dev/null))"
  rp_section | grep -q 'stamp order' && ok || bad "$name the prompt's ## Rules pack must name the stamp order: $(rp_section)"
  rp_section | grep -qF 'the merge conductor restamps' && ok || bad "$name the prompt must say the merge path restamps: $(rp_section)"
  rp_section | grep -qF 'at the base creates and which sorts after this fragment' && ok || bad "$name the prompt must carry the stamp line itself"
  jq -e '.outcome == "done" and .verdict == "MERGE-WITH-NOTES"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "$name result: $(result)"
}
# block_case <name> <line...> — a rules-pack BLOCK, no model
block_case() {
  local name="$1"; shift
  setup 1 "$@"; tick
  rpblock && ok || bad "$name must be a rules-pack BLOCK: $(result)"
  [ "$(agents)" = 0 ] && ok || bad "$name the agent was called $(agents) time(s) on a rules-pack BLOCK"
}

note_case L1 "$STAMP1"
grep -qx -- '- rules pack: clean except schema stamp order (NOTE, the merge conductor restamps before queueing)' "$REPORT" 2>/dev/null \
  && ok || bad "L1 report header: $(grep 'rules pack' "$REPORT" 2>/dev/null)"
note_case L2 "$STAMP2"

block_case L3 "$TAKEN"
grep -qxF -- "- [BLOCK] $TAKEN" "$REPORT" 2>/dev/null && ok || bad "L3 report lacks the NNNN BLOCK: $(grep -F '[' "$REPORT" 2>/dev/null)"
block_case L4 "$MAL"
grep -qxF -- "- [BLOCK] $MAL" "$REPORT" 2>/dev/null && ok || bad "L4 report lacks the malformed-name BLOCK"

block_case L5 "$STAMP1" "$INDEX"
grep -qxF -- "- [BLOCK] $INDEX" "$REPORT" 2>/dev/null && ok || bad "L5 the index line must be the BLOCK: $(grep -F '[' "$REPORT" 2>/dev/null)"
grep -qxF -- "- [NOTE] stamp order, the merge path restamps: $STAMP1" "$REPORT" 2>/dev/null && ok || bad "L5 the stamp line must be a NOTE: $(grep -F '[' "$REPORT" 2>/dev/null)"
blocks=$(grep -F -- '- [BLOCK]' "$REPORT" 2>/dev/null)
grep -qF 'at the base creates and which sorts after' <<<"$blocks" && bad "L5 the stamp line was reported as a BLOCK" || ok

# ── M1: without the split call the stamp line is a BLOCK again ──
sed 's/^\( *\)command -v sr_stamp_split >\/dev\/null 2>&1 && sr_stamp_split /\1false \&\& sr_stamp_split /' "$SRC/bin/lead-review.sh" > "$T/mut.sh"
if cmp -s "$T/mut.sh" "$SRC/bin/lead-review.sh"; then
  bad "M1 the mutation anchor 'command -v sr_stamp_split ... && sr_stamp_split' is missing from bin/lead-review.sh"
else
  setup 1 "$STAMP1"; cp "$T/mut.sh" "$HB/bin/lead-review.sh"; tick
  rpblock && ok || bad "M1 with the split removed L1 must be a rules-pack BLOCK (L1 would go red), got: $(result)"
fi

echo "lead-review-stamp-note: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
