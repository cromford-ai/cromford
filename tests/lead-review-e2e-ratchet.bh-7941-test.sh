#!/bin/bash
# tests/lead-review-e2e-ratchet.bh-7941-test.sh — BH-7941: in the lead review,
# E2E is a ratchet. Drives the REAL bin/lead-review.sh tick against a scratch
# harness (scratch_install_closure), with these stubbed (0 network):
#   * curl  — the jobs worker
#   * gh    — the REST read of pulls/<n>, and the Actions runs, jobs and job
#             logs that bin/lib/e2e-main-baseline.sh reads (fixture files; an
#             unknown Actions path exits 1 with no output)
#   * bin/agent-call.sh — keeps each prompt and answers the canned review in
#             $T/answer
#
#   P1  the prompt has `## Main E2E` after `## Live probes` and before
#       `## Conflict hotspots`, with the fixture's pre-existing and regression
#       spec ids; the log says `main e2e yes`
#   P2  the prompt carries the checklist's Checklist-Version (11 or later) and
#       item 17; the report says `- checklist: v<N>`
#   R1  acceptance 1, the red-first replay: the only failure is also red on
#       main -> the posted verdict is MERGE-WITH-NOTES and the report carries
#       the demoted line with `follow-up`
#   R2  acceptance 2: a test green on main and red on the head -> BLOCK
#   R3  acceptance 3: one full run, an ask for 3 full runs and a per-spec
#       table -> MERGE-WITH-NOTES
#   L1  bin/lib/e2e-main-baseline.sh is not on the box: the section says so,
#       the libs.d fragment logs it, the tick still posts a verdict
#   L2  the libs.d fragment is not on the box either: the section says so and
#       the tick still posts a verdict
#   M1  mutation: no `## Main E2E` print in bin/lead-review.sh -> P1 red
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-e2e-ratchet.bh-7941-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows.
export LEAD_REVIEW_MAX_PER_PR_DAY=50
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/e2e-main-baseline.sh bin/lib/review-level.sh catalog/review-e2e-ratchet.tsv prompts/lead-review-checklist.md; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PLAN_CONTEXT_HOTSPOT_TOP AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_MAX_PER_TICK REVIEW_LEVEL_MODE REVIEW_LEVEL_E2E_RATCHET

HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log" "$T/fx"
# Stubs first: scratch_install_closure never clobbers.
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
cp "\${6#@}" "$T/log/prompt.\$(wc -l < "$T/log/agent-count" | tr -d ' ')"
cat "$T/answer" > "\$5"
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
[ -f "$HB/bin/lib/e2e-main-baseline.sh" ] && ok || bad "the closure of bin/lead-review.sh does not carry bin/lib/e2e-main-baseline.sh"
cp "$SRC"/catalog/review-*.tsv "$HB/catalog/"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
echo box-demo > "$HB/state/box-name"
cat > "$HB/fleet.conf" <<'EOF'
cromford example-org/cromford https://bh.test    /api/board 1 box-demo
other-os      example-org/other         https://other.test /api/board 2 box-demo
EOF

mk_repo() { # mk_repo <project> <pr> -> prints the PR head sha
  local p="$1" pr="$2" o="$T/origin/$1.git" w="$T/work/$1"
  git init -q --bare -b main "$o"; git init -q -b main "$w"
  printf '# %s\n' "$p" > "$w/CLAUDE.md"; echo one > "$w/a.txt"
  git -C "$w" add -A; git -C "$w" commit -qm base; git -C "$w" push -q "$o" main
  echo pr-line-marker >> "$w/a.txt"; git -C "$w" commit -qam "pr change"
  git -C "$w" push -q "$o" "HEAD:refs/pull/$pr/head"
  git clone -q "$o" "$T/repos/$p"
  git -C "$w" rev-parse HEAD
}
SHA=$(mk_repo cromford 41)
OSHA=$(mk_repo other-os 5)

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
  "GET /api/conflict-hotspots"*)
    case "\$(cat "$T/hsmode")" in
      fail) code=502; out='{"error":"bad gateway"}' ;;
      *) out=\$(cat "$T/hotspots.json") ;;
    esac ;;
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
p=""; prev=""
for a in "\$@"; do [ "\$prev" = GET ] && p="\$a"; prev="\$a"; done
case "\$p" in
  *"/actions/"*)
    echo "\$p" >> "$T/log/gh-actions"
    k=\$(printf '%s' "\$p" | sed 's|^repos/[^/]*/[^/]*/actions/||' | tr -c 'A-Za-z0-9' '_')
    [ -f "$T/fx/\$k" ] || exit 1
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/fx/\$k"; exit 0 ;;
esac
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"


# Actions fixtures: main's nightly E2E run 4411 failed with checkout + login;
# the head's run 5001 failed with checkout (pre-existing) + settings (regression).
fxk() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
fx() { cat > "$T/fx/$(fxk "$1")"; }
jq -nc '{workflow_runs:[{id:4400,name:"CI",event:"push",head_sha:"aaaaaaaaaaaa",conclusion:"success",created_at:"2026-10-21T03:00:00Z",path:".github/workflows/ci.yml"},
  {id:4411,name:"E2E Tests",event:"schedule",head_sha:"aaaaaaaaaaaa",conclusion:"failure",created_at:"2026-10-21T03:00:00Z",path:".github/workflows/e2e.yml"}]}' \
  | fx 'runs?branch=main&status=completed&per_page=50'
jq -nc --arg s "$SHA" '{workflow_runs:[{id:5001,name:"E2E Tests",event:"pull_request",head_sha:$s,conclusion:"failure",created_at:"2026-10-22T01:00:00Z",path:".github/workflows/e2e.yml"}]}' \
  | fx "runs?head_sha=$SHA&status=completed&per_page=50"
echo '{"jobs":[{"id":9001,"name":"e2e","conclusion":"failure"}]}' | fx 'runs/4411/jobs'
echo '{"jobs":[{"id":9101,"name":"e2e","conclusion":"failure"}]}' | fx 'runs/5001/jobs'
printf '%s\n' '2026-10-21T03:02:00.0000000Z   1) [chromium] › e2e/checkout.spec.ts:40:5 › Checkout › pays ──────' \
  '2026-10-21T03:02:00.0000000Z   2) [chromium] › e2e/login.spec.ts:8:3 › Login › signs in ──────' | fx 'jobs/9001/logs'
printf '%s\n' '2026-10-22T01:02:00.0000000Z   1) [chromium] › e2e/checkout.spec.ts:40:5 › Checkout › pays ──────' \
  '2026-10-22T01:02:00.0000000Z   2) [chromium] › e2e/settings.spec.ts:30:3 › Settings › saves ──────' | fx 'jobs/9101/logs'

LLOG="$HB/logs/lead-review.log"
FRAG="$HB/bin/lib/lead-review/libs.d/202610230549-bh-7941-e2e-main-baseline.sh"
[ -f "$FRAG" ] && ok || bad "the closure of bin/lead-review.sh does not carry the BH-7941 libs.d fragment"
REPORT="$HB/state/lead-reviews/lr-41-${SHA:0:12}.md"
# setup <answer-finding-line> — one request; a clean slate
setup() {
  rm -f "$T/log"/* "$LLOG"
  scratch_rm "$HB/state/lead-reviews"
  cp "$SRC/bin/lead-review.sh" "$HB/bin/"
  [ -f "$T/emb.aside" ] && mv "$T/emb.aside" "$HB/bin/lib/e2e-main-baseline.sh"
  [ -f "$T/frag.aside" ] && mv "$T/frag.aside" "$FRAG"
  echo ok > "$T/hsmode"
  echo '{"hotspots":[],"run":null,"total":0,"limit":10,"truncated":false}' > "$T/hotspots.json"
  printf 'Findings\n%s\n\nVERDICT: %s\n' "$1" "${2:-BLOCK}" > "$T/answer"
  echo "$SHA" > "$T/livehead"
  jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:41,head_sha:$s,scope_notes:"only the lane",
    prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
}
tick() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HB/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
}
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
P1="$T/log/prompt.1"
section() { awk -v a="$1" -v b="$2" '$0 == a {f=1; next} $0 == b {f=0} f' "$P1" 2>/dev/null; }
lno() { grep -nx -- "$1" "$P1" 2>/dev/null | head -n 1 | cut -d: -f1; }
posted() { wlog | grep -qE "^POST /api/lead-reviews/lr-1/result .*\"outcome\":\"done\".*\"verdict\":\"$1\""; }

PRE='- [BLOCK red-build] e2e/checkout.spec.ts:40: fails on the head; also fails on main run 4411'

# ── P1 + R1: the section, and the red-first replay ──
setup "$PRE"; tick
[ "$RC" -eq 0 ] && ok || bad "P1 rc=$RC out=$(cat "$T/out")"
[ "$(agents)" = 1 ] && ok || bad "P1 agent called $(agents) time(s): $(cat "$LLOG" 2>/dev/null)"
lp=$(lno '## Live probes'); me=$(lno '## Main E2E'); ch=$(lno '## Conflict hotspots')
[ -n "$lp" ] && [ -n "$me" ] && [ -n "$ch" ] && [ "$me" -gt "$lp" ] && [ "$ch" -gt "$me" ] \
  && ok || bad "P1 order: ## Live probes=$lp ## Main E2E=$me ## Conflict hotspots=$ch"
S=$(section '## Main E2E' '## Conflict hotspots')
grep -q '^main: E2E Tests run 4411 (schedule, aaaaaaaa, ' <<<"$S" && ok || bad "P1 main line: $S"
grep -q '^head: E2E Tests run 5001 (pull_request, ' <<<"$S" && ok || bad "P1 head line: $S"
awk '/^pre-existing/{f=1;next} /^[a-z]/{f=0} f' <<<"$S" | grep -qxF '  - e2e/checkout.spec.ts › Checkout › pays' && ok || bad "P1 pre-existing: $S"
awk '/^regression/{f=1;next} /^[a-z]/{f=0} f' <<<"$S" | grep -qxF '  - e2e/settings.spec.ts › Settings › saves' && ok || bad "P1 regression: $S"
grep -q 'main e2e yes$' "$LLOG" 2>/dev/null && ok || bad "P1 no state log line: $(grep -i e2e "$LLOG" 2>/dev/null)"
[ -s "$T/log/gh-actions" ] && [ "$(wc -l < "$T/log/gh-actions" | tr -d ' ')" -le 6 ] && ok || bad "P1 Actions calls: $(cat "$T/log/gh-actions")"
# P2
CKV=$(sed -n '1s/^Checklist-Version: *\([0-9][0-9]*\)$/\1/p' "$SRC/prompts/lead-review-checklist.md")
[ -n "$CKV" ] && [ "$CKV" -ge 11 ] && ok || bad "P2 checklist version is '$CKV', want 11 or later"
grep -qx "Checklist-Version: $CKV" "$P1" && ok || bad "P2 the prompt lacks Checklist-Version: $CKV"
grep -q '^17\. E2E is a ratchet (BH-7941)\.' "$P1" && ok || bad "P2 the prompt lacks item 17"
grep -qx -- "- checklist: v$CKV" "$REPORT" 2>/dev/null && ok || bad "P2 report lacks '- checklist: v$CKV'"
# R1
posted MERGE-WITH-NOTES && ok || bad "R1 verdict: $(wlog | grep result)"
grep -qF -- '- [NOTE demoted from BLOCK red-build, e2e ratchet (BH-7941): pre-existing on main; follow-up] e2e/checkout.spec.ts:40' "$REPORT" 2>/dev/null \
  && ok || bad "R1 report: $(cat "$REPORT" 2>/dev/null)"

# ── R2: a regression blocks ──
setup '- [BLOCK red-build] e2e/settings.spec.ts:30: passes on main run 4411 and fails on this head'; tick
posted BLOCK && ok || bad "R2 verdict: $(wlog | grep result)"
grep -qF -- '- [BLOCK red-build] e2e/settings.spec.ts:30: passes on main run 4411' "$REPORT" 2>/dev/null && ok || bad "R2 report: $(cat "$REPORT" 2>/dev/null)"

# ── R3: one full run is enough evidence ──
setup '- [BLOCK weakened-test] one full E2E run only; needs 3 full runs and a per-spec table'; tick
posted MERGE-WITH-NOTES && ok || bad "R3 verdict: $(wlog | grep result)"
grep -qF 'e2e ratchet (BH-7941): one full E2E run is enough evidence]' "$REPORT" 2>/dev/null && ok || bad "R3 report: $(cat "$REPORT" 2>/dev/null)"

# ── L1: the lib is not on this box ──
setup "$PRE"; mv "$HB/bin/lib/e2e-main-baseline.sh" "$T/emb.aside"; tick
[ "$RC" -eq 0 ] && ok || bad "L1 rc=$RC"
S=$(section '## Main E2E' '## Conflict hotspots')
grep -q '^COULD NOT READ: bin/lib/e2e-main-baseline.sh is not loaded' <<<"$S" && ok || bad "L1 section: $S"
grep -q 'bin/lib/e2e-main-baseline.sh missing' "$LLOG" 2>/dev/null && ok || bad "L1 no missing-lib log line"
[ -s "$T/log/gh-actions" ] && bad "L1 an Actions read happened with no lib" || ok
[ "$(agents)" = 1 ] && wlog | grep -q '^POST /api/lead-reviews/lr-1/result .*"outcome":"done"' && ok || bad "L1 review did not complete"

# ── L2: neither the lib nor its libs.d fragment ──
setup "$PRE"; mv "$HB/bin/lib/e2e-main-baseline.sh" "$T/emb.aside"; mv "$FRAG" "$T/frag.aside"; tick
[ "$RC" -eq 0 ] && ok || bad "L2 rc=$RC"
S=$(section '## Main E2E' '## Conflict hotspots')
grep -q '^COULD NOT READ: bin/lib/e2e-main-baseline.sh is not loaded' <<<"$S" && ok || bad "L2 section: $S"
[ -s "$T/log/gh-actions" ] && bad "L2 an Actions read happened with no lib" || ok
[ "$(agents)" = 1 ] && wlog | grep -q '^POST /api/lead-reviews/lr-1/result .*"outcome":"done"' && ok || bad "L2 review did not complete"

# ── M1: no section heading in bin/lead-review.sh = P1 red ──
setup "$PRE"
sed "/printf '\\\\n## Main E2E\\\\n'/d" "$SRC/bin/lead-review.sh" > "$T/mut.sh"
if cmp -s "$T/mut.sh" "$SRC/bin/lead-review.sh"; then
  bad "M1 the mutation anchor printf '\\n## Main E2E\\n' is missing"
else
  cp "$T/mut.sh" "$HB/bin/lead-review.sh"; tick
  [ -z "$(lno '## Main E2E')" ] && ok || bad "M1 the heading survived the mutation"
fi
cp "$SRC/bin/lead-review.sh" "$HB/bin/"

echo "lead-review-e2e-ratchet.bh-7941: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
