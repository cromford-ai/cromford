#!/bin/bash
# tests/lead-part-review.bh-8533-test.sh — BH-8533: a full lead review over
# LEAD_REVIEW_DIFF_MAX_BYTES that leaves a file unread is reviewed in N parts
# on the SAME head (bin/lib/lead-part-review.sh): one paid call per part, one
# aggregate verdict, one result row. Drives the REAL bin/lead-review.sh tick
# against a scratch harness (scratch_install_closure), with these stubbed:
#   * curl  — the jobs worker, with a file-backed ledger and call-guard peek
#   * gh    — the REST read of pulls/<n> (the live head, $T/livehead)
#   * bin/agent-call.sh — counts calls, keeps each prompt, reads "part k of N"
#     from the prompt, answers $T/answers/<k> (default MERGE), keeps a per-fp
#     paid ledger, and can move the live head after a given part
#   * bin/lane-alert.sh — records each alert line
# The fixture PR 51 has 5 units of ~100 KB (bin/u1.sh..u5.sh, a test that
# names bin/u3.sh, a fixture); LEAD_REVIEW_DIFF_MAX_BYTES=200000.
#
#   R1  ldp_build's LDP_PARTS_TSV holds every non-digest path once, equal to
#       the `## Proposed split` lines; no digest path; unset env = no file
#   P1  a 50 KB diff: one single review, no `## Part review`
#   P2  knob unset, 5 units: 5 calls          P3  log `part review: 5 parts`
#   P4  knob 0: 0 calls, split required, the finding says part review is off
#   P5  LEAD_REVIEW_PART_MAX=4: 0 calls, the finding names it; =5: 5 calls
#   P6  one file over the limit alone: 0 calls, split required
#   P7  knob 'yes' (near miss): off           P8  lib missing: split required
#   Q1  prompt k names part k of 5, #51, the sha, every other part's files,
#       and holds no diff of another part
#   Q2  each prompt's `## Part review`..end is at or under the part limit
#   Q3  LEAD_REVIEW_PART_BYTES=150000 at DIFF_MAX 400000: more parts, each under it
#   D1  each call: model stub-model, role lead.review, stage lead-head
#   D2  5 ledger PUTs, kind lead_part, keys p1of5..p5of5, detail request_id+part
#   D3  parts 1-2 stored (E2 left them), next tick: 3 calls, parts 3-5
#   A1  all MERGE: one /result POST, verdict MERGE, model stub-model, after call 5
#   A2  one MERGE-WITH-NOTES: MERGE-WITH-NOTES
#   A3  part 3 BLOCK: BLOCK, its finding under `## Part 3 of 5`
#   A4  part 2 unreadable twice: outcome failed, no verdict
#   A5  part 4 guard spent, no ledger row: failed part-lost, one alert, no call 4
#   A6  a part that says "VERDICT: MERGE" in a sentence and ends BLOCK: BLOCK;
#       A6b a line-start inner "VERDICT: MERGE" is unknown to lr_verdict: no verdict
#   A7  the report's only `VERDICT:` line is its last line
#   H1  the head moves after part 2: 2 calls, superseded, no verdict
#   E1  the deadline leaves under 60 s a part: release, 0 calls; E1b the
#       floor is LEAD_REVIEW_PART_MIN_LEFT_S
#   E2  agent-call rc 75 on part 3: release, parts 1-2 stay in the ledger
#   E3  the ledger answers 500: 0 calls, release, no verdict
#   E4  a rate limit on a part: no verdict, the request left for a later tick
#   R2  a second tick with all 5 parts stored: 0 calls, the same verdict
#   T1  a stored part answer over the ledger cap (truncated) and no local file:
#       not reused, 0 calls, failed part-lost; T1b the full local file: reused
#   V1  every curl went to jobs.test (no vendor call)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-part-review.bh-8533-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/lead-diff-parts.sh bin/lib/lead-part-review.sh prompts/lead-review.md; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export LEAD_REVIEW_MAX_PER_PR_DAY=200
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DIFF_MAX_BYTES PLAN_CONTEXT_HOTSPOT_TOP \
  LEAD_REVIEW_PART_REVIEW_ENABLED LEAD_REVIEW_PART_MAX LEAD_REVIEW_PART_BYTES LEAD_REVIEW_DEADLINE_S

HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
echo box-demo > "$HB/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$HB/fleet.conf"

# The stubs that setup re-installs after the closure copy.
stubs() {
  cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
fp="\${AGENT_CALL_FP:-}"; led="$T/paid/\$(printf '%s' "\$fp" | tr -c 'A-Za-z0-9' '_')"
if [ "\${AGENT_CALL_GUARD_STAGE:-}" = lead-head ] && [ -n "\$fp" ] && [ -e "\$led" ]; then echo "\$fp" >> "$T/log/refused"; exit 74; fi
k=\$(sed -n 's/^This is part \([0-9]*\) of \([0-9]*\) of .*/\1/p' "\${6#@}" | head -n 1); k="\${k:-0}"
[ -e "$T/rc75.\$k" ] && exit 75
echo "\$k" >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count" | tr -d ' ')
echo "CALL \$k" >> "$T/log/seq"
cp "\${6#@}" "$T/log/prompt.\$n"
printf '%s|%s|%s|%s\n' "\$3" "\${AGENT_CALL_ROLE:-}" "\${AGENT_CALL_GUARD_STAGE:-}" "\$fp" >> "$T/log/calls"
mkdir -p "$T/paid"; [ -n "\$fp" ] && : > "\$led"
if [ -e "$T/ratelimit.\$k" ]; then printf 'API Error: 429 rate_limit_error: rate limited\n' > "\$5"; exit 1; fi
if [ -f "$T/answers/\$k" ]; then cp "$T/answers/\$k" "\$5"
else printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"; fi
[ "\$(cat "$T/move.after" 2>/dev/null)" = "\$k" ] && echo 9999999999999999999999999999999999999999 > "$T/livehead"
exit 0
EOF
  cat > "$HB/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
EOF
  chmod +x "$HB/bin/agent-call.sh" "$HB/bin/lane-alert.sh"
}

# fill <file> <bytes> <tag> [first-line] — deterministic text of about <bytes>
fill() {
  mkdir -p "$(dirname "$1")"
  { [ -n "${4:-}" ] && printf '%s\n' "$4"
    awk -v n="$2" -v t="$3" 'BEGIN { l = 0; while (l < n) { s = sprintf("%s row %07d filler\n", t, l); printf "%s", s; l += length(s) } }'; } > "$1"
}
O="$T/origin.git"; W="$T/work"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# cromford fixture\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
# pr <n> <setup-cmd> — commit on a branch from main, push refs/pull/<n>/head; prints the sha
pr() {
  git -C "$W" checkout -q -B "pr$1" main
  eval "$2"
  git -C "$W" add -A; git -C "$W" commit -qm "pr $1"
  git -C "$W" push -q -f "$O" "HEAD:refs/pull/$1/head"
  git -C "$W" rev-parse HEAD
}
UNITS='for i in 1 2 3 4 5; do fill "$W/bin/u$i.sh" 100000 "ZQUNIT${i}Q"; done
  fill "$W/tests/u3-test.sh" 4000 ZQUNIT3Q "bash bin/u3.sh --check"
  fill "$W/tests/fixtures/big.json" 30000 ZQFIXTUREQ'
SHA=$(pr 51 "$UNITS")
SMALL=$(pr 52 'fill "$W/bin/small.sh" 50000 ZQSMALLQ')
OVER=$(pr 53 'fill "$W/bin/huge.sh" 180000 ZQHUGEQ; fill "$W/bin/u1.sh" 100000 ZQUNIT1Q')
git clone -q "$O" "$T/repos/cromford"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
case "\$url" in https://jobs.test/*) ;; *) echo "\$url" >> "$T/log/vendor"; printf '{}\n599'; exit 0 ;; esac
p="\${url#https://jobs.test}"
dec() { local s="\${1//+/ }"; printf '%b' "\${s//%/\\\\x}"; }
( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/conflict-hotspots"*) out='{"hotspots":[],"run":null,"total":0,"limit":10,"truncated":false}' ;;
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/lead-reviews/lr-1/result") echo RESULT >> "$T/log/seq" ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
  "GET /api/call-guard?"*)
    f=\$(dec "\$(printf '%s' "\$p" | sed -n 's/.*[?&]fp=\([^&]*\).*/\1/p')")
    if [ -e "$T/paid/\$(printf '%s' "\$f" | tr -c 'A-Za-z0-9' '_')" ]; then
      out=\$(jq -nc --arg f "\$f" '{rows:[{project:"cromford",stage:"lead-head",fp:\$f,paid:1,refused:0}],hours:24}')
    else out='{"rows":[],"hours":24}'; fi ;;
  "GET /api/ledger?"*)
    k=\$(dec "\$(printf '%s' "\$p" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')")
    kind=\$(dec "\$(printf '%s' "\$p" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')")
    lf="$T/ledger/\$kind.\$(printf '%s' "\$k" | tr -c 'A-Za-z0-9' '_')"
    if [ "\$kind" = lead_part ] && [ -e "$T/ledger.500" ]; then code=500; out='{"error":"boom"}'
    elif [ -f "\$lf" ]; then out=\$(jq -c '{ledger:.}' "\$lf")
    else code=404; out='{"error":"not found"}'; fi ;;
  "PUT /api/ledger")
    mkdir -p "$T/ledger"
    kind=\$(jq -r .kind <<<"\$body"); k=\$(jq -r .key <<<"\$body")
    jq -c '{status, detail}' <<<"\$body" > "$T/ledger/\$kind.\$(printf '%s' "\$k" | tr -c 'A-Za-z0-9' '_')" ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

LLOG="$HB/logs/lead-review.log"
# setup <pr> <sha> [keep] — one request and the real lane; keep = leave the part ledger and the paid marks
setup() {
  rm -f "$T/log"/* "$LLOG" "$T/move.after" "$T/ledger.500" "$T"/rc75.* "$T"/ratelimit.*
  rm -rf "$T/answers"; mkdir -p "$T/answers"
  [ "${3:-}" = keep ] || rm -rf "$T/ledger" "$T/paid"
  scratch_rm "$HB/state/lead-reviews"
  cp "$SRC/bin/lead-review.sh" "$HB/bin/"
  scratch_install_closure bin/lead-review.sh "$HB" >/dev/null
  stubs
  echo "$2" > "$T/livehead"
  jq -nc --argjson p "$1" --arg s "$2" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:$p,head_sha:$s,
    scope_notes:"only the lane",prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
}
tick() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_DIFF_MAX_BYTES=${DMAX:-200000} env "$@" bash "$HB/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
}
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
results() { grep -c '^POST /api/lead-reviews/lr-1/result ' "$T/log/worker" 2>/dev/null || true; }
result() { grep '^POST /api/lead-reviews/lr-1/result ' "$T/log/worker" 2>/dev/null | tail -n 1 | cut -d' ' -f3-; }
rep() { echo "$HB/state/lead-reviews/lr-$1-${2:0:12}.md"; }
# split_block <case> <pr> <sha> <reason-ERE> — no call, split-required BLOCK whose finding matches
split_block() {
  [ "$(agents)" = 0 ] && ok || bad "$1 the agent was called $(agents) time(s)"
  jq -e '.outcome == "done" and .verdict == "BLOCK" and .reviewer_model == "none:split-required"' <<<"$(result)" >/dev/null 2>&1 \
    && ok || bad "$1 result: $(result)"
  grep -qE -- "^- \\[BLOCK split-required\\] .*$4" "$(rep "$2" "$3")" 2>/dev/null && ok \
    || bad "$1 finding does not match /$4/: $(grep -F '[BLOCK' "$(rep "$2" "$3")" 2>/dev/null)"
}
answer() { printf "$2" > "$T/answers/$1"; }

# ── R1: the machine-readable partition equals the proposed split ──
(
  . "$SRC/bin/lib/lead-diff-parts.sh" || exit 9
  WT="$T/r1wt"; git -C "$T/repos/cromford" fetch -q origin "+refs/pull/51/head:refs/r1" 2>/dev/null
  git -C "$T/repos/cromford" worktree add -q --detach "$WT" "$SHA" >/dev/null 2>&1 || exit 8
  LDP_PARTS_TSV="$T/r1.tsv" ldp_build "$WT" origin/main "$SHA" 200000 "$T/r1.parts" "$T/r1.split" any; echo "rc=$?" > "$T/r1.rc"
  ldp_build "$WT" origin/main "$SHA" 200000 "$T/r1b.parts" "$T/r1b.split" any; echo "rc=$?" >> "$T/r1.rc"
  cmp -s "$T/r1.split" "$T/r1b.split" && echo same >> "$T/r1.rc"
)
[ "$(cat "$T/r1.rc" 2>/dev/null | paste -sd' ')" = "rc=2 rc=2 same" ] && ok || bad "R1 ldp_build rc/split: $(cat "$T/r1.rc" 2>/dev/null)"
[ "$(cut -f4 "$T/r1.tsv" 2>/dev/null | sort | paste -sd' ')" = "bin/u1.sh bin/u2.sh bin/u3.sh bin/u4.sh bin/u5.sh tests/u3-test.sh" ] \
  && ok || bad "R1 the TSV paths: $(cat "$T/r1.tsv" 2>/dev/null)"
[ "$(cut -f4 "$T/r1.tsv" | sort | uniq -d | grep -c .)" = 0 ] && ok || bad "R1 a path in two parts"
grep -qF 'tests/fixtures/big.json' "$T/r1.tsv" && bad "R1 the digest file is in the TSV" || ok
# Each `- Part k (...)` line names exactly the TSV rows of part k.
r1ok=1
for k in 1 2 3 4 5; do
  want=$(awk -F'\t' -v k="$k" '$1 == k { print $4 }' "$T/r1.tsv" | sort | paste -sd' ')
  got=$(grep -E "^- Part $k \\(" "$T/r1.split" | sed 's/^- Part [0-9]* ([0-9]* bytes): //' | grep -oE '[A-Za-z0-9_./-]+ \([0-9]+ bytes\)' | sed 's/ (.*//' | sort | paste -sd' ')
  [ -n "$want" ] && [ "$want" = "$got" ] || { r1ok=0; bad "R1 part $k: TSV '$want' split '$got'"; }
done
[ "$r1ok" = 1 ] && ok
grep -qE '^- Part 6 ' "$T/r1.split" && bad "R1 a 6th part" || ok
[ ! -e "$T/r1b.tsv" ] && ok || bad "R1 unset env wrote a file"

# ── A1 / P2 / P3 / Q1 / Q2 / D1 / D2 / A7: 5 parts, all MERGE ──
setup 51 "$SHA"; tick
[ "$RC" -eq 0 ] && ok || bad "A1 rc=$RC out=$(tail -5 "$T/out")"
[ "$(agents)" = 5 ] && ok || bad "P2 want 5 agent calls, got $(agents): $(grep -iE 'part|split' "$LLOG" | tail -5)"
[ "$(paste -sd' ' "$T/log/agent-count" 2>/dev/null)" = "1 2 3 4 5" ] && ok || bad "A1 part order: $(paste -sd' ' "$T/log/agent-count" 2>/dev/null)"
grep -q 'part review: 5 parts' "$LLOG" 2>/dev/null && ok || bad "P3 log: $(grep -i 'part' "$LLOG" | head -3)"
[ "$(results)" = 1 ] && ok || bad "A1 want one /result POST, got $(results)"
jq -e '.outcome == "done" and .verdict == "MERGE" and .reviewer_model == "stub-model"' <<<"$(result)" >/dev/null 2>&1 \
  && ok || bad "A1 result: $(result)"
[ "$(paste -sd' ' "$T/log/seq" 2>/dev/null)" = "CALL 1 CALL 2 CALL 3 CALL 4 CALL 5 RESULT" ] && ok || bad "A1 the result must follow the 5th call: $(paste -sd' ' "$T/log/seq")"
REP=$(rep 51 "$SHA")
grep -qE "^- review mode: part review, 5 parts \\([0-9a-f]{8}\\), parts: 1 MERGE, 2 MERGE, 3 MERGE, 4 MERGE, 5 MERGE$" "$REP" 2>/dev/null \
  && ok || bad "A1 report header: $(grep 'review mode' "$REP" 2>/dev/null)"
grep -q 'none:split-required' "$REP" 2>/dev/null && bad "A1 the report is still split-required" || ok
# A7: the only VERDICT line is the last line.
[ "$(grep -v '^[[:space:]]*$' "$REP" | tail -n 1)" = "VERDICT: MERGE" ] && ok || bad "A7 last line: $(tail -n 1 "$REP")"
[ "$(grep -ciE '^[#>* ]*VERDICT[*]*:' "$REP")" = 1 ] && ok || bad "A7 part VERDICT lines left: $(grep -inE '^[#>* ]*VERDICT' "$REP")"
# Q1 / Q2: each prompt names its part, the PR, the sha and the other parts' files.
for n in 1 2 3 4 5; do
  P="$T/log/prompt.$n"
  grep -qxF "## Part review" "$P" 2>/dev/null && grep -qF "This is part $n of 5 of example-org/cromford#51 at $SHA." "$P" \
    && ok || bad "Q1 prompt $n does not name part $n of 5, #51 and the sha"
  for j in 1 2 3 4 5; do
    [ "$j" = "$n" ] && continue
    grep -qxF -- "- part $j: bin/u$j.sh ($(git -C "$W" diff "main...$SHA" -- "bin/u$j.sh" | wc -c | tr -d ' ') bytes)" "$P" \
      && ok || bad "Q1 prompt $n does not list bin/u$j.sh of part $j: $(sed -n '/^The other parts/,/^## Diff coverage/p' "$P" | head -8)"
    grep -qF "ZQUNIT${j}Q" "$P" && bad "Q1 prompt $n holds part $j's diff" || ok
  done
  grep -qF "ZQUNIT${n}Q" "$P" && ok || bad "Q1 prompt $n lacks its own diff"
  grep -qF "ZQFIXTUREQ" "$P" && bad "Q2 prompt $n holds the fixture's content" || ok
  sz=$(sed -n '/^## Part review$/,$p' "$P" | wc -c | tr -d ' ')
  [ "$sz" -le 200000 ] && ok || bad "Q2 prompt $n part section is $sz bytes, over 200000"
  [ "$(grep -cx '## Diff' "$P")" = 1 ] && ok || bad "Q2 prompt $n has $(grep -cx '## Diff' "$P") ## Diff sections"
done
grep -qF -- '- tests/u3-test.sh (' "$T/log/prompt.3" && grep -qF 'ZQUNIT3Q row' "$T/log/prompt.3" && ok || bad "Q1 the test of bin/u3.sh is not in part 3"
# D1: the routed model, the role and the stage, on per-part guard keys.
[ "$(cut -d'|' -f1-3 "$T/log/calls" | sort -u)" = "stub-model|lead.review|lead-head" ] && ok || bad "D1 calls: $(cut -d'|' -f1-3 "$T/log/calls" | sort -u)"
[ "$(cut -d'|' -f4 "$T/log/calls" | grep -cE "^lead:example-org/cromford#51@$SHA~p[1-5]of5x[0-9a-f]{8}$")" = 5 ] && ok || bad "D1 guard keys: $(cut -d'|' -f4 "$T/log/calls")"
grep -q 'claude-' "$SRC/bin/lib/lead-part-review.sh" && bad "D1 a claude- model id in the lib" || ok
# D2: one ledger PUT per part, keyed by pr, head, part and partition, with the request id.
puts=$(grep '^PUT /api/ledger ' "$T/log/worker" | cut -d' ' -f3- | jq -c 'select(.kind == "lead_part")')
[ "$(grep -c . <<<"$puts")" = 5 ] && ok || bad "D2 want 5 lead_part PUTs: $puts"
for k in 1 2 3 4 5; do
  jq -e --arg k "$k" --arg s "$SHA" 'select(.key | test("^example-org/cromford#51@" + $s + "/p" + $k + "of5/[0-9a-f]{8}$"))
    | .status == "MERGE" and ((.detail | fromjson) as $d | $d.request_id == "lr-1" and $d.part == ($k | tonumber) and $d.of == 5 and $d.model == "stub-model")' <<<"$puts" >/dev/null 2>&1 \
    && ok || bad "D2 part $k PUT: $(grep "p${k}of5" <<<"$puts" | head -c 300)"
done
[ "$(grep -c '^PUT /api/jobs/job-7/artifacts .*"artifact_kind":"lead_review_part"' "$T/log/worker")" = 5 ] && ok || bad "D2 want 5 lead_review_part artifacts"
[ "$(ls "$HB/state/lead-reviews/parts/" 2>/dev/null | grep -c "^example-org_cromford-51-${SHA:0:12}-p[1-5]of5\\.md$")" = 5 ] && ok || bad "D2 local part files: $(ls "$HB/state/lead-reviews/parts/" 2>/dev/null)"

# ── R2: the same head again, all 5 parts stored: 0 calls, the same verdict ──
setup 51 "$SHA" keep; tick
[ "$(agents)" = 0 ] && ok || bad "R2 a stored part was bought again: $(agents) calls"
jq -e '.outcome == "done" and .verdict == "MERGE"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "R2 result: $(result)"
[ "$(grep -c 'stored in the part ledger; no agent call' "$LLOG")" = 5 ] && ok || bad "R2 log: $(grep -c 'stored in the part ledger' "$LLOG")"

# ── A2: one MERGE-WITH-NOTES ──
setup 51 "$SHA"; answer 4 'Findings\n- [NOTE] a small thing\n\nVERDICT: MERGE-WITH-NOTES\n'; tick
jq -e '.verdict == "MERGE-WITH-NOTES"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "A2 result: $(result)"

# ── A3: part 3 BLOCK ──
setup 51 "$SHA"; answer 3 'Findings\n- [BLOCK wrong-data] x is wrong in bin/u3.sh\n\nVERDICT: BLOCK\n'; tick
[ "$(agents)" = 5 ] && ok || bad "A3 the parts after a BLOCK must still run: $(agents) calls"
jq -e '.outcome == "done" and .verdict == "BLOCK" and .reviewer_model == "stub-model"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "A3 result: $(result)"
REP=$(rep 51 "$SHA")
awk '/^## Part 3 of 5: BLOCK$/ { f = 1; next } /^## Part 4 of 5/ { f = 0 } f && /^- \[BLOCK wrong-data\] x is wrong in bin\/u3.sh$/ { h = 1 } END { exit !h }' "$REP" \
  && ok || bad "A3 the finding is not under ## Part 3 of 5: $(grep -n 'Part\|BLOCK' "$REP" | head -20)"
grep -qE '^- review mode: part review, 5 parts \([0-9a-f]{8}\), parts: 1 MERGE, 2 MERGE, 3 BLOCK, 4 MERGE, 5 MERGE$' "$REP" && ok || bad "A3 header: $(grep 'review mode' "$REP")"

# ── A6: a part that says "VERDICT: MERGE" before it ends BLOCK is BLOCK ──
setup 51 "$SHA"; answer 2 'Findings\n- [BLOCK wrong-data] y\n\nI first thought VERDICT: MERGE, but y is wrong.\n\nVERDICT: BLOCK\n'; tick
jq -e '.verdict == "BLOCK"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "A6 result: $(result)"
REP=$(rep 51 "$SHA")
[ "$(grep -ciE '^[#>* ]*VERDICT[*]*:' "$REP")" = 1 ] && [ "$(grep -v '^[[:space:]]*$' "$REP" | tail -n 1)" = "VERDICT: BLOCK" ] \
  && ok || bad "A6/A7 verdict lines: $(grep -inE 'VERDICT' "$REP")"
# A6b: a line-start "VERDICT: MERGE" inside the part is a disagreement that
# lr_verdict reads as unknown: that part has no verdict, so the head has none.
setup 51 "$SHA"; answer 2 'Findings\n- [BLOCK wrong-data] y\n\nThe template says:\nVERDICT: MERGE\n\nVERDICT: BLOCK\n'; tick
jq -e '.outcome == "failed" and (has("verdict") | not)' <<<"$(result)" >/dev/null 2>&1 && ok || bad "A6b result: $(result)"

# ── A4: part 2 unreadable twice: failed, no verdict ──
setup 51 "$SHA"; answer 2 'I looked at it.\n'; tick
[ "$(agents)" = 3 ] && ok || bad "A4 want calls 1, 2, 2 (retry) = 3, got $(agents): $(paste -sd' ' "$T/log/agent-count")"
jq -e '.outcome == "failed" and .detail == "empty" and (has("verdict") | not)' <<<"$(result)" >/dev/null 2>&1 && ok || bad "A4 result: $(result)"
[ "$(cut -d'|' -f4 "$T/log/calls" | grep -cE '~p2of5[xn][0-9a-f]{8}$')" = 2 ] && ok || bad "A4 the retry is not on the n key: $(cut -d'|' -f4 "$T/log/calls")"

# ── A5: part 4 paid with no stored answer: lost, one alert, no call for part 4 ──
setup 51 "$SHA"; tick   # a first full run to learn the part 4 key
fp4=$(cut -d'|' -f4 "$T/log/calls" | grep '~p4of5x')
setup 51 "$SHA"; mkdir -p "$T/paid"; : > "$T/paid/$(printf '%s' "$fp4" | tr -c 'A-Za-z0-9' '_')"; tick
[ "$(paste -sd' ' "$T/log/agent-count" 2>/dev/null)" = "1 2 3" ] && ok || bad "A5 calls: $(paste -sd' ' "$T/log/agent-count" 2>/dev/null)"
jq -e '.outcome == "failed" and .detail == "part-lost" and (has("verdict") | not)' <<<"$(result)" >/dev/null 2>&1 && ok || bad "A5 result: $(result)"
[ "$(grep -c . "$T/log/alerts" 2>/dev/null)" = 1 ] && grep -qF -- "--id lead-part-lost-example-org_cromford-51-${SHA:0:12} lead-review" "$T/log/alerts" \
  && grep -qF "call-guard-reset cromford lead-head \"$fp4\"" "$T/log/alerts" && ok || bad "A5 alert: $(cat "$T/log/alerts" 2>/dev/null)"

# ── H1: the head moves after part 2: superseded, no verdict ──
setup 51 "$SHA"; echo 2 > "$T/move.after"; tick
[ "$(agents)" = 2 ] && ok || bad "H1 calls after the move: $(agents)"
[ "$(results)" = 1 ] && jq -e '.outcome == "superseded" and (has("verdict") | not) and (.detail | test("head moved to 999999999999 during part review"))' <<<"$(result)" >/dev/null 2>&1 \
  && ok || bad "H1 result: $(result)"

# ── E1: under 60 s a part: release, nothing bought ──
setup 51 "$SHA"; tick LEAD_REVIEW_DEADLINE_S=200
[ "$(agents)" = 0 ] && ok || bad "E1 calls: $(agents)"
[ "$(results)" = 0 ] && grep -q '^POST /api/lead-reviews/lr-1/release ' "$T/log/worker" && ok || bad "E1 want a release and no result: $(result)"
grep -q 'claim released' "$LLOG" && ok || bad "E1 log: $(tail -3 "$LLOG")"
# E1b: the floor is the knob LEAD_REVIEW_PART_MIN_LEFT_S: 1000 s / 5 parts = 200 s, under 300.
setup 51 "$SHA"; tick LEAD_REVIEW_DEADLINE_S=1000 LEAD_REVIEW_PART_MIN_LEFT_S=300
[ "$(agents)" = 0 ] && [ "$(results)" = 0 ] && grep -qE '(1[0-9]{2}|200)s left for part 1 of 5, under 300s' "$LLOG" && ok || bad "E1b knob floor: $(agents) calls, $(grep 'left for part' "$LLOG")"

# ── E2 then D3: rc 75 on part 3 releases; the next tick buys parts 3-5 only ──
setup 51 "$SHA"; : > "$T/rc75.3"; tick
[ "$(paste -sd' ' "$T/log/agent-count" 2>/dev/null)" = "1 2" ] && ok || bad "E2 calls: $(paste -sd' ' "$T/log/agent-count" 2>/dev/null)"
[ "$(results)" = 0 ] && grep -q '^POST /api/lead-reviews/lr-1/release ' "$T/log/worker" && ok || bad "E2 want a release, no result: $(result)"
[ "$(ls "$T/ledger" 2>/dev/null | grep -c '^lead_part\.')" = 2 ] && ok || bad "E2 the parts 1-2 ledger rows: $(ls "$T/ledger" 2>/dev/null)"
setup 51 "$SHA" keep; tick
[ "$(paste -sd' ' "$T/log/agent-count" 2>/dev/null)" = "3 4 5" ] && ok || bad "D3 want parts 3 4 5 only, got: $(paste -sd' ' "$T/log/agent-count" 2>/dev/null)"
jq -e '.verdict == "MERGE"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "D3 result: $(result)"

# ── T1: a stored part answer over the 4000-unit ledger cap, no local file ──
# The ledger row is cut (truncated:true). Reusing it would drop the late BLOCK
# finding, so the part is not reused: paid with no full answer = part-lost.
longans='Findings\n'
for i in $(seq 1 60); do longans="$longans- [NOTE] filler note $i about bin/u3.sh, long enough to push the answer past the ledger cap.\n"; done
longans="$longans- [BLOCK wrong-data] the late finding in bin/u3.sh\n\nVERDICT: BLOCK\n"
setup 51 "$SHA"; answer 3 "$longans"; tick
jq -e '.verdict == "BLOCK"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "T1 first tick result: $(result)"
jq -e '.detail | fromjson | .truncated == true' "$T/ledger/lead_part.$(ls "$T/ledger" | sed -n 's/^lead_part\.\(.*p3of5.*\)$/\1/p')" >/dev/null 2>&1 \
  && ok || bad "T1 the part 3 ledger row is not cut: $(ls "$T/ledger")"
cp "$HB/state/lead-reviews/parts/example-org_cromford-51-${SHA:0:12}-p3of5.md" "$T/p3.full"
setup 51 "$SHA" keep; tick
[ "$(agents)" = 0 ] && ok || bad "T1 calls: $(agents)"
jq -e '.outcome == "failed" and .detail == "part-lost" and (has("verdict") | not)' <<<"$(result)" >/dev/null 2>&1 && ok || bad "T1 a cut part was reused: $(result)"
grep -q 'part 3 of 5: BLOCK in the part ledger, but the stored answer is cut' "$LLOG" && grep -q 'with no full stored answer (its stored answer is cut' "$T/log/alerts" \
  && ok || bad "T1 log/alert: $(grep 'part 3' "$LLOG"; cat "$T/log/alerts" 2>/dev/null)"
# T1b: the same cut row with the full local file present: reused in full.
setup 51 "$SHA" keep; mkdir -p "$HB/state/lead-reviews/parts"; cp "$T/p3.full" "$HB/state/lead-reviews/parts/example-org_cromford-51-${SHA:0:12}-p3of5.md"; tick
[ "$(agents)" = 0 ] && ok || bad "T1b calls: $(agents)"
jq -e '.outcome == "done" and .verdict == "BLOCK"' <<<"$(result)" >/dev/null 2>&1 && ok || bad "T1b result: $(result)"
grep -qF -- '- [BLOCK wrong-data] the late finding in bin/u3.sh' "$(rep 51 "$SHA")" && ok || bad "T1b the late finding is not in the report"

# ── E3: the ledger answers 500: no call, release ──
setup 51 "$SHA"; : > "$T/ledger.500"; tick
[ "$(agents)" = 0 ] && ok || bad "E3 a call with the ledger unreadable: $(agents)"
[ "$(results)" = 0 ] && grep -q '^POST /api/lead-reviews/lr-1/release ' "$T/log/worker" && ok || bad "E3 want a release, no result: $(result)"

# ── E4: a rate limit on part 2: no verdict, the request left for a later tick ──
setup 51 "$SHA"; : > "$T/ratelimit.2"; tick
[ "$(results)" = 0 ] && ok || bad "E4 result posted: $(result)"
grep -q 'hit a rate or concurrency limit' "$LLOG" && ok || bad "E4 log: $(tail -3 "$LLOG")"

# ── P1: a 50 KB diff: one single review ──
setup 52 "$SMALL"; tick
[ "$(agents)" = 1 ] && ok || bad "P1 calls: $(agents)"
grep -q '^## Part review$' "$T/log/prompt.1" && bad "P1 part mode under the limit" || ok

# ── P4 / P7: knob off ──
setup 51 "$SHA"; tick LEAD_REVIEW_PART_REVIEW_ENABLED=0
split_block P4 51 "$SHA" 'Part review did not run: part review is off \(LEAD_REVIEW_PART_REVIEW_ENABLED=0\)'
setup 51 "$SHA"; tick LEAD_REVIEW_PART_REVIEW_ENABLED=yes
split_block P7 51 "$SHA" 'part review is off \(LEAD_REVIEW_PART_REVIEW_ENABLED=yes\)'

# ── P5: part_max ──
setup 51 "$SHA"; tick LEAD_REVIEW_PART_MAX=4
split_block P5 51 "$SHA" '5 parts, over LEAD_REVIEW_PART_MAX=4'
setup 51 "$SHA"; tick LEAD_REVIEW_PART_MAX=5
[ "$(agents)" = 5 ] && ok || bad "P5 the edge part_max=5: $(agents) calls"

# ── P6: one file over the limit alone ──
setup 53 "$OVER"; tick
split_block P6 53 "$OVER" 'bin/huge.sh is over the part limit of 200000 bytes alone'

# ── P8: the lib is missing ──
setup 51 "$SHA"; rm -f "$HB/bin/lib/lead-part-review.sh"; tick
split_block P8 51 "$SHA" 'bin/lib/lead-part-review.sh is not loaded'

# ── Q3: a smaller part limit gives more parts, each under it ──
setup 51 "$SHA"; DMAX=400000 tick
q3a=$(agents)
setup 51 "$SHA"; DMAX=400000 tick LEAD_REVIEW_PART_BYTES=150000
q3b=$(agents)
[ "$q3a" -ge 2 ] && [ "$q3b" -gt "$q3a" ] && ok || bad "Q3 parts at 400000: $q3a, at 150000: $q3b"
q3ok=1
for n in $(seq 1 "$q3b"); do
  sz=$(sed -n '/^## Part review$/,$p' "$T/log/prompt.$n" | wc -c | tr -d ' ')
  [ "$sz" -le 150000 ] || { q3ok=0; bad "Q3 prompt $n is $sz bytes, over 150000"; }
done
[ "$q3ok" = 1 ] && ok

# ── V1: no vendor call ──
[ ! -s "$T/log/vendor" ] && ok || bad "V1 a curl to another host: $(cat "$T/log/vendor")"

echo "lead-part-review.bh-8533: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
