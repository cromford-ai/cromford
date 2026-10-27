#!/bin/bash
# tests/lead-replay-merge-only.bh-5294-test.sh — BH-5294: a PR head that only
# took main in keeps the lead's word with no model call, and a head that changed
# the PR's own files by a few lines gets a DELTA lead review on the same
# lead.review model route. bin/lead-review.sh runs WHOLE (`tick`) against a
# scratch harness: the script plus its sourced closure (scratch_install_closure),
# with bin/lib/lead-delta.sh, a real git fixture repo, and stubs for curl (the
# jobs worker), gh (REST) and bin/agent-call.sh (it counts its calls). The lead
# MERGEd head G; HD = G + 12 lines in the PR's own file.
#
#   ld_protected on its own (bin/lib/lead-delta.sh): .mergify.yml, schema and a
#   catalog glob of the harness repo are protected; an unreadable rows read is rc 2.
#   gate 50's over-max class and the reuse of a plain cached delta row are in
#   tests/lead-gates-delta-class.bh-8496-test.sh (DC1, DC1b, DC3).
#   bin/lead-review.sh tick
#     L1  a delta request on HD: ONE agent call on the lead.review route's model
#         (stub-model), the prompt carries the prior report, the inter-diff and
#         DELTA REVIEW, and not G's own branch lines; the report says
#         `- review mode: delta from <G>`.
#     L2  the same head as a full request: ONE agent call on the SAME model, the
#         prompt carries the whole branch diff, and no delta header.
#     L3  a delta request whose prior report is not on the box: a full review,
#         logged, same model.
# Dispatcher section (BH-5874): gate 3, bin/lib/lead-gates.d/50-replay-delta.sh,
# on the worklist, and the ticket's observable outcome. bin/lead-review.sh tick
# runs WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh; bin/lead-verdict.sh
# is the real script. G is the PR commit $SHA, H1 = G + a main merge (#201).
#   R1  the lead token is on the box; the lead MERGEd G; the builder's APPROVE
#       is on G (H1 unapproved, CI green); #202 is builder-BLOCKed. One tick:
#       one POST /api/verdicts (MERGE, head H1, note lead-replay:<G12>
#       how:main-merge), no lead_review job for 201 or 202, one
#       `[skip builder-block]` naming #202, one 7-column modes.tsv `replay` row.
#   R2  the verdict post answers 500: no job for 201, held=1, the log names the rc.
#   R3  the lead BLOCKed G (H1 unapproved): no POST /api/verdicts, no replay result.
#   R4  the only lead row on G is itself a replay: no POST /api/verdicts.
#   R5  no lead token: no POST /api/verdicts; review_one's own replay posts
#       the /result (reviewer_model lead-replay), as before.
#   R6  a human row on H1 and H1 unapproved: `[skip verdict]`, no job.
#   R7  a truncated verdict history: a full review (one job), logged.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-replay-merge-only.bh-5294-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/lead-delta.sh bin/lib/patch-same.sh catalog/lanes.d/_lib.lead-delta.json; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

# ───────────── the fixture repo: G, then the head HD ─────────────
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; printf 'other\n' > "$WK/o.txt"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; echo 'pr line' >> "$WK/f.txt"; git -C "$WK" commit -qam "the pr"
G=$(git -C "$WK" rev-parse HEAD); G12=${G:0:12}
git -C "$WK" checkout -q main; echo 'main moved' >> "$WK/o.txt"; git -C "$WK" commit -qam "main moves"
git -C "$WK" checkout -qb small "$G"; seq 1 12 | sed 's/^/small change /' >> "$WK/f.txt"; git -C "$WK" commit -qam "12 lines"
HD=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr small
git -C "$WK" push -q "$OR" "$HD:refs/pull/41/head"

# ═══════════════════ the libs ld_protected sources ═══════════════════
Q="$T/hq"; mkdir -p "$Q/state" "$T/log"
scratch_install_closure bin/lib/lead-delta.sh "$Q" >/dev/null || bad "closure of bin/lib/lead-delta.sh"
scratch_install_closure bin/lib/lead-authority.sh "$Q" >/dev/null || bad "closure of bin/lib/lead-authority.sh"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$SRC/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"

# ── ld_protected on its own ──
(
  HARNESS="$Q"; . "$Q/bin/lib/lead-authority.sh"; . "$Q/bin/lib/lead-delta.sh"
  setting_get() { return 2; }
  _jobs_req() { lpp_jobs_req "$LPPF" "$LPPDOWN" "$@"; }   # TEST-CHANGE BH-4148: the rows, not the TSV
  printf 'a.txt\n.mergify.yml\n' | ld_protected example-org/demo-os >/dev/null || exit 11
  printf 'worker/jobs/schema.sql\n' | ld_protected example-org/demo-os >/dev/null || exit 12
  printf 'bin/lead-verdict.sh\n' | ld_protected example-org/cromford >/dev/null || exit 13
  printf 'bin/lead-verdict.sh\n' | ld_protected example-org/demo-os >/dev/null && exit 14
  # TEST-CHANGE BH-4148: the unreadable case was an unreadable extras setting,
  # which this PR removes; it is now an unreadable rows read with no fresh cache.
  printf 500 > "$LPPDOWN"; rm -f "$Q/state/lead-authority/"globs-*.cache
  printf 'x\n' | ld_protected example-org/cromford >/dev/null; [ $? = 2 ] || exit 15
  exit 0
); PRC=$?; rm -f "$LPPDOWN"
[ "$PRC" = 0 ] && ok || bad "R6 ld_protected unit check failed at exit $PRC"

# ═════════════════════════ part 2: bin/lead-review.sh ═════════════════════════
B2="$T/hb"; mkdir -p "$B2/bin/lib/jobs" "$B2/prompts" "$B2/catalog/lanes.d" "$B2/state/lead-reviews" "$T/repos" "$T/tmp" "$T/fakebin"
cat > "$B2/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/lr-agent-count"
printf '%s\n' "\$3" >> "$T/log/lr-models"
cp "\${6#@}" "$T/log/prompt.\$(wc -l < "$T/log/lr-agent-count" | tr -d ' ')"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$B2/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$B2" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$B2" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$B2/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$B2/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$B2/prompts/"
echo box-demo > "$B2/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$B2/fleet.conf"
git clone -q "$OR" "$T/repos/demo-os"

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
$(lpp_curl_case m url body)
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$HD" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
LLOG="$B2/logs/lead-review.log"
GREPORT="$B2/state/lead-reviews/lr-41-$G12.md"
# setup2 <scope notes> — one request for HD; a clean slate of reports but G's
setup2() {
  rm -f "$T/log"/lr-* "$T/log"/prompt.* "$T/log/worker" "$LLOG"
  scratch_rm "$B2/state/lead-reviews"; mkdir -p "$B2/state/lead-reviews"
  printf '# Lead review lr-41-%s (example-org/demo-os#41 at %s)\n\n- verdict: MERGE\n- reviewer model: stub-model\n\nFindings\n- [NOTE] f.txt:21: the earlier finding\n\nVERDICT: MERGE\n' \
    "$G12" "$G" > "$GREPORT"
  jq -nc --arg s "$HD" --arg n "$1" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,scope_notes:$n,
    prior_verdict_ref:"v",status:"requested",requested_by:"lead-review-enqueue:box-hub"}],truncated:false}' > "$T/requests.json"
}
tick2() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$B2" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$B2/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$B2/bin/lead-review.sh" tick ) > "$T/out2" 2>&1; RC=$?
}
lragents() { [ -f "$T/log/lr-agent-count" ] && wc -l < "$T/log/lr-agent-count" | tr -d ' ' || echo 0; }
HKEY="lr-41-${HD:0:12}"

# ── L1: the delta request: one call, same model, the delta and not the branch ──
setup2 "auto: builder APPROVE on ${HD:0:12}; lead-delta:$G lines:12/40 files:1"; tick2
[ "$RC" -eq 0 ] && ok || bad "L1 rc=$RC out=$(cat "$T/out2")"
[ "$(lragents)" = 1 ] && ok || bad "L1 agent called $(lragents) time(s): $(cat "$LLOG")"
[ "$(cat "$T/log/lr-models" 2>/dev/null)" = stub-model ] && ok || bad "L1 model: '$(cat "$T/log/lr-models" 2>/dev/null)'"
P1="$T/log/prompt.1"
grep -q '^DELTA REVIEW' "$P1" 2>/dev/null && ok || bad "L1 no delta header in the prompt"
grep -q 'the earlier finding' "$P1" 2>/dev/null && ok || bad "L1 the prior report is not in the prompt"
grep -q '^+small change 12$' "$P1" 2>/dev/null && ok || bad "L1 the inter-diff is not in the prompt"
grep -q '^+pr line$' "$P1" 2>/dev/null && bad "L1 the prompt carries G's own branch lines (a full diff)" || ok
grep -q "$HKEY: delta review from $G12" "$LLOG" && ok || bad "L1 no delta log line: $(cat "$LLOG")"
grep -qx -- "- review mode: delta from $G" "$B2/state/lead-reviews/$HKEY.md" 2>/dev/null && ok \
  || bad "L1 the report does not name delta mode: $(head -12 "$B2/state/lead-reviews/$HKEY.md" 2>/dev/null)"

# ── L2: the same head as a full request: one call, the SAME model, the whole diff ──
setup2 "auto: builder APPROVE on ${HD:0:12}"; tick2
[ "$(lragents)" = 1 ] && ok || bad "L2 agent called $(lragents) time(s)"
[ "$(cat "$T/log/lr-models" 2>/dev/null)" = stub-model ] && ok || bad "L2 model: '$(cat "$T/log/lr-models" 2>/dev/null)'"
grep -q '^+pr line$' "$T/log/prompt.1" 2>/dev/null && ok || bad "L2 the full prompt lacks the branch diff"
grep -q '^DELTA REVIEW' "$T/log/prompt.1" 2>/dev/null && bad "L2 a full request was reviewed in delta mode" || ok
grep -q 'review mode' "$B2/state/lead-reviews/$HKEY.md" 2>/dev/null && bad "L2 a full report names a review mode" || ok

# ── L3: delta asked, but G's report is not on this box: a full review, logged ──
setup2 "auto: builder APPROVE on ${HD:0:12}; lead-delta:$G lines:12/40 files:1"; rm -f "$GREPORT"; tick2
[ "$(lragents)" = 1 ] && ok || bad "L3 agent called $(lragents) time(s)"
[ "$(cat "$T/log/lr-models" 2>/dev/null)" = stub-model ] && ok || bad "L3 model: '$(cat "$T/log/lr-models" 2>/dev/null)'"
grep -q '^+pr line$' "$T/log/prompt.1" 2>/dev/null && ok || bad "L3 the fallback is not the full diff"
grep -q "delta review from $G12 not possible (the lead report for $G12 is not on this box); full review" "$LLOG" && ok \
  || bad "L3 no fallback line: $(cat "$LLOG")"

# ═══════════ dispatcher section (BH-5874): gate 3 on the worklist ═══════════
T="$T/disp"; mkdir -p "$T"
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
[ -r "$H/bin/lib/lead-gates.d/50-replay-delta.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/50-replay-delta.sh"
lwf_main_merge
SG=${SHA:0:12}
djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
vposts() { grep '^POST /api/verdicts ' "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/verdicts //'; }
nvposts() { local n; n=$(vposts | grep -c .); echo "${n:-0}"; }
# rset <lead word on G> [note] — the setup R1-R5 share
rset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
  jq -nc --arg a "$H1" --arg b "$SHA" '[
    {repo:"example-org/demo-os", number:201, url:"https://github.com/example-org/demo-os/pull/201", head:$a, hotfix:0, nudged:0, approved_at:"2026-10-10T03:00:00Z"},
    {repo:"example-org/demo-os", number:202, url:"https://github.com/example-org/demo-os/pull/202", head:$b, hotfix:0, nudged:0, approved_at:"2026-10-10T03:00:01Z"}]' \
    > "$FX/needs.example-org_demo-os.json"
  echo "$H1" > "$FX/head.201"
  lwf_bv 201 APPROVE "$SHA"; lwf_bv 202 BLOCK "$SHA"; lwf_ci_green "$H1" "$SHA"
  jq -nc --arg g "$SHA" --arg w "$1" --arg n "${2:-report:state/lead-reviews/x.md}" \
    '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:$w, note:$n}], truncated:false}' > "$FX/verdicts.json"
}
MODES="$H/state/lead-review-enqueue/modes.tsv"

# ── R1: the observable outcome ──
rset MERGE; printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
lwf_tick
[ "$(nvposts)" = 1 ] && ok || bad "R1 POST /api/verdicts=$(nvposts) (want 1): $(cat "$L")"
v=$(vposts | head -1)
[ "$(jq -r '.verdict' <<<"$v")" = MERGE ] && [ "$(jq -r '.head_sha' <<<"$v")" = "$H1" ] && [ "$(jq -r '.source' <<<"$v")" = lead ] \
  && [[ "$(jq -r '.note' <<<"$v")" == "lead-replay:$SG how:main-merge"* ]] && ok || bad "R1 the replay post: $v"
[ "$(djobs 201)" = 0 ] && [ "$(djobs 202)" = 0 ] && ok || bad "R1 lead_review jobs 201=$(djobs 201) 202=$(djobs 202) (want 0 and 0)"
[ "$(lwf_agents)" = 0 ] && ok || bad "R1 agent calls=$(lwf_agents)"
[ "$(lwf_cnt "\[skip builder-block\] example-org/demo-os#202 @$SG " "$L")" = 1 ] && ok || bad "R1 [skip builder-block] for #202: $(grep skip "$L")"
grep -q "example-org/demo-os#201 @${H1:0:12}: lead MERGE replayed from $SG (how:main-merge, post rc 0); no review" "$L" && ok || bad "R1 no replay line: $(cat "$L")"
[ "$(awk -F'\t' '$3 == "replay" && $4 == "example-org/demo-os" && $5 == 201' "$MODES" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && ok || bad "R1 modes.tsv: $(cat "$MODES" 2>/dev/null)"
[ "$(awk -F'\t' '$3 == "replay" {print NF}' "$MODES" 2>/dev/null)" = 7 ] && ok || bad "R1 the modes.tsv row is not 7 columns"
[ "$(awk -F'\t' '$3 == "replay" {print $6 " " $7}' "$MODES" 2>/dev/null)" = "$H1 from=$SG how=main-merge" ] && ok || bad "R1 modes.tsv head/detail: $(cat "$MODES" 2>/dev/null)"
[[ "$(lwf_summary)" == *" skipped=2 "* ]] && ok || bad "R1 summary: $(lwf_summary)"

# ── R2: the post fails: held, never a replay ──
rset MERGE; printf 'tok-fixture-lead\n' > "$FX/lead-token"; : > "$FX/verdictpost.fail"
lwf_tick
[ "$(djobs 201)" = 0 ] && ok || bad "R2 jobs for 201=$(djobs 201)"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "R2 summary: $(lwf_summary)"
grep -q "example-org/demo-os#201 @${H1:0:12}: lead MERGE replay from $SG not recorded (post rc 1: " "$L" && ok || bad "R2 no post-rc line: $(cat "$L")"
[ -s "$MODES" ] && bad "R2 a modes.tsv row for a failed post: $(cat "$MODES")" || ok

# ── R3: a lead BLOCK on G is never replayed onto an unapproved head ──
rset BLOCK; printf 'tok-fixture-lead\n' > "$FX/lead-token"
lwf_tick
[ "$(nvposts)" = 0 ] && ok || bad "R3 POST /api/verdicts=$(nvposts): $(vposts)"
grep -q 'lead-replay' "$T/log/worker" && bad "R3 a lead-replay result: $(grep lead-replay "$T/log/worker")" || ok
[ "$(djobs 201)" = 1 ] && ok || bad "R3 jobs for 201=$(djobs 201) (want 1: a review)"

# ── R4: a replay row is never the source of a replay ──
rset MERGE "lead-replay:aaaaaaaaaaaa how:main-merge"; printf 'tok-fixture-lead\n' > "$FX/lead-token"
lwf_tick
[ "$(nvposts)" = 0 ] && ok || bad "R4 POST /api/verdicts=$(nvposts): $(vposts)"

# ── R5: no lead token: review_one's own replay ──
rset MERGE
lwf_tick
[ "$(nvposts)" = 0 ] && ok || bad "R5 POST /api/verdicts=$(nvposts) without a token"
grep -q "^POST /api/lead-reviews/s-201-${H1:0:12}/result .*\"reviewer_model\":\"lead-replay\"" "$T/log/worker" && ok || bad "R5 no /result replay: $(grep result "$T/log/worker")"
grep -q "example-org/demo-os#201 @${H1:0:12}: since $SG: replay main-merge; no lead token on this box, so review_one's own replay decides" "$L" && ok || bad "R5 no no-token line: $(cat "$L")"

# ── R6: an unapproved head with a human row on it ──
rset MERGE; printf 'tok-fixture-lead\n' > "$FX/lead-token"
jq --arg h "$H1" '.rows += [{id:8, source:"human", repo:"example-org/demo-os", pr:201, head_sha:$h, verdict:"MERGE", note:""}]' "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
lwf_tick
[ "$(djobs 201)" = 0 ] && [ "$(nvposts)" = 0 ] && ok || bad "R6 jobs=$(djobs 201) posts=$(nvposts) (want 0 0)"
[ "$(lwf_cnt "\[skip verdict\] example-org/demo-os#201 @${H1:0:12} " "$L")" = 1 ] && ok || bad "R6 no [skip verdict]: $(grep skip "$L")"

# ── R7: a truncated history is a full review ──
rset MERGE; printf 'tok-fixture-lead\n' > "$FX/lead-token"
jq '.truncated = true' "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
lwf_tick
[ "$(nvposts)" = 0 ] && [ "$(djobs 201)" = 1 ] && ok || bad "R7 posts=$(nvposts) jobs=$(djobs 201) (want 0 1)"
grep -q "example-org/demo-os#201 @${H1:0:12}: verdicts read failed; full review" "$L" && ok || bad "R7 no line: $(cat "$L")"

echo "lead-replay-merge-only.bh-5294: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
