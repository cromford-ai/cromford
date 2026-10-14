#!/bin/bash
# tests/lead-replay-merge-only.bh-5294-test.sh — BH-5294: a PR head that only
# took main in keeps the lead's word with no model call, and a head that changed
# the PR's own files by a few lines gets a DELTA lead review on the same
# lead.review model route. Two production entry points, each run WHOLE (`tick`)
# against a scratch harness: the script plus its sourced closure
# (scratch_install_closure), with bin/lib/lead-delta.sh, real git fixture repos,
# and stubs for curl (the jobs worker), gh (REST), bin/lead-verdict.sh and
# bin/agent-call.sh (both count their calls).
#
#   bin/lead-review-enqueue.sh tick. The lead MERGEd head G; the builder's
#   APPROVE is on G (not on the new head) unless a case says otherwise.
#     R1  H = G + a clean merge of main: the MERGE is posted on H with source
#         lead and note lead-replay:<G12> how:main-merge; no lead review is
#         requested, no agent call. today_replay=1 in the summary.
#     R2  a second tick on R1's H (the post wrote its row): no post, no request.
#     R3  G was BLOCKed: nothing is replayed onto H and nothing is requested.
#     R4  H = G + 12 lines in the PR's own file, the builder approved H: ONE
#         request, scope_notes carrying lead-delta:<G> lines:12/40, and
#         prior_verdict_ref naming the lead row. No post. today_delta=1.
#     R5  the same head with the builder's APPROVE still on G: no request, no
#         post (only the builder's approval asks for a review); the class is
#         cached, and the later approved tick reuses it with no git fetch.
#     R6  H = G + a .github/ file (protected), LEAD_DELTA_PROTECTED_MAX_LINES=0
#         (BH-5582: the knob-off path): a FULL request (no lead-delta), and
#         even a byte-identical patch rule cannot replay it.
#     R7  H = G + 60 lines (over LEAD_DELTA_REVIEW_MAX_LINES=40): a full request.
#   bin/lead-review.sh tick
#     L1  the R4 delta request: ONE agent call on the lead.review route's model
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
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lead-review-enqueue.sh bin/lib/lead-delta.sh bin/lib/patch-same.sh catalog/lanes.d/_lib.lead-delta.json; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

# ───────────── the fixture repo: G, then the heads R1..R7 move to ─────────────
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; printf 'other\n' > "$WK/o.txt"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; echo 'pr line' >> "$WK/f.txt"; git -C "$WK" commit -qam "the pr"
G=$(git -C "$WK" rev-parse HEAD); G12=${G:0:12}
git -C "$WK" checkout -q main; echo 'main moved' >> "$WK/o.txt"; git -C "$WK" commit -qam "main moves"
git -C "$WK" checkout -q pr; git -C "$WK" merge -q --no-edit main; HM=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb small "$G"; seq 1 12 | sed 's/^/small change /' >> "$WK/f.txt"; git -C "$WK" commit -qam "12 lines"
HD=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb prot "$G"; mkdir -p "$WK/.github/workflows"; printf 'on: push\n' > "$WK/.github/workflows/x.yml"
git -C "$WK" add -A; git -C "$WK" commit -qm "touch ci"; HP=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb big "$G"; seq 1 60 | sed 's/^/big change /' >> "$WK/f.txt"; git -C "$WK" commit -qam "60 lines"
HB=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr small prot big
git -C "$WK" push -q "$OR" "$HD:refs/pull/41/head"

# ═══════════════════════ part 1: bin/lead-review-enqueue.sh ═══════════════════
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$Q/catalog/lanes.d" "$T/cfg" "$T/qrepos" "$T/log" "$T/qbin"
# Stubs first: scratch_install_closure never clobbers.
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
# The post records the row as the worker would, so the next tick reads it.
printf '%s\n' "\$*" >> "$T/log/post"
rc=\$(cat "$T/postrc" 2>/dev/null || echo 0)
if [ "\$1" = post ] && [ "\$rc" = 0 ]; then
  note=""; prev=""; for a in "\$@"; do [ "\$prev" = --note ] && note="\$a"; prev="\$a"; done
  jq -c --arg h "\$4" --arg v "\$5" --arg n "\$note" '.rows += [{id:99, head_sha:\$h, source:"lead", verdict:\$v, note:\$n}]' \
    "$T/vrows.json" > "$T/vrows.tmp" && mv "$T/vrows.tmp" "$T/vrows.json"
fi
exit "\$rc"
EOF
cat > "$Q/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/qalerts"
EOF
cat > "$Q/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
exit 1
EOF
chmod +x "$Q/bin/lead-verdict.sh" "$Q/bin/lane-alert.sh" "$Q/bin/agent-call.sh"
scratch_install_closure bin/lead-review-enqueue.sh "$Q" >/dev/null || bad "closure of bin/lead-review-enqueue.sh"
scratch_install_closure bin/jobs-client.sh "$Q" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$Q/catalog/lanes.d/"
cp "$SRC/catalog/lead-protected-paths.tsv" "$Q/catalog/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"
git clone -q "$OR" "$T/qrepos/demo-os"
# Every git fetch the enqueue makes is counted (R5's cache check).
mkdir -p "$T/gitbin"; REALGIT=$(command -v git)
cat > "$T/gitbin/git" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = fetch ] && { echo x >> "$T/log/fetches"; break; }; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/gitbin/git"

cat > "$T/qbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/qworker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*standing_only=1*)
    h=\$(printf '%s' "\$p" | tr '&?' '\n\n' | sed -n 's/^head_sha=//p')
    out=\$(jq -c --arg h "\$h" '{standing:([.rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | last // null),
      rows:[], truncated:false}' "$T/vrows.json") ;;
  "GET /api/verdicts?"*) out=\$(cat "$T/vrows.json") ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/qbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$(cat "$T/qhead")" '[{number:41, html_url:"https://github.com/example-org/demo-os/pull/41", title:"t", draft:false, state:"open",
      user:{login:"operator",type:"User"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' ;;
  *"-X GET repos/example-org/demo-os/pulls/41"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/qhead")" '{head:{sha:\$s},base:{ref:"main"},user:{login:"operator"}}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}],"files":[]}\n' ;;
esac
exit 0
EOF
chmod +x "$T/qbin/curl" "$T/qbin/gh"

QLOG="$Q/logs/lead-review-enqueue.log"
# reset <head> <builder-approved sha> <lead word on G>
reset() {
  rm -f "$T/log"/q* "$T/log/post" "$T/log/fetches" "$T/postrc" "$QLOG"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$1" > "$T/qhead"
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg g "$G" --arg w "$3" '{rows:[{id:4,repo:"example-org/demo-os",pr:41,head_sha:$g,source:"box",verdict:"APPROVE",note:""},
    {id:5,repo:"example-org/demo-os",pr:41,head_sha:$g,source:"lead",verdict:$w,note:"lead-review:lr-3"}],truncated:false}' > "$T/vrows.json"
}
tick() {
  ( cd "$T" && PATH="$T/qbin:$T/gitbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 GH_ETAG=0 \
      bash "$Q/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
reqs() { grep -c '^POST /api/lead-reviews ' "$T/log/qworker" 2>/dev/null || true; }
reqbody() { grep '^POST /api/lead-reviews ' "$T/log/qworker" | head -1 | sed 's/^POST \/api\/lead-reviews //; s/ lead=[01]$//'; }
postn() { [ -f "$T/log/post" ] && wc -l < "$T/log/post" | tr -d ' ' || echo 0; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
fetches() { [ -f "$T/log/fetches" ] && wc -l < "$T/log/fetches" | tr -d ' ' || echo 0; }
summ() { grep ' tick repos=' "$QLOG" 2>/dev/null | tail -1; }
hasw() { summ | grep -qw -- "$1"; }

# ── R1: only main merged in, builder APPROVE still on G: the lead MERGE is replayed ──
reset "$HM" "$G" MERGE; tick
[ "$RC" -eq 0 ] && ok || bad "R1 rc=$RC out=$(cat "$T/out")"
WANT="post example-org/demo-os 41 $HM MERGE --source lead --reviewer box:box-hub --note lead-replay:$G12 how:main-merge"
[ "$(cat "$T/log/post" 2>/dev/null)" = "$WANT" ] && ok || bad "R1 lead-verdict argv: '$(cat "$T/log/post" 2>/dev/null)' want '$WANT'"
[ "$(reqs)" = 0 ] && ok || bad "R1 a lead review was requested on a main-merge head: $(reqbody)"
[ "$(agents)" = 0 ] && ok || bad "R1 an agent was called $(agents) time(s)"
hasw replayed=1 && hasw requested=0 && hasw today_replay=1 && ok || bad "R1 summary: $(summ) log: $(cat "$QLOG")"
[ "$(awk -F'\t' '$3 == "replay"' "$Q/state/lead-review-enqueue/modes.tsv" | wc -l | tr -d ' ')" = 1 ] && ok || bad "R1 modes.tsv: $(cat "$Q/state/lead-review-enqueue/modes.tsv")"

# ── R2: idempotent: the next tick sees its own row and does nothing ──
rm -f "$T/log/post" "$T/log/qworker"; tick
[ "$(postn)" = 0 ] && ok || bad "R2 posted again: $(cat "$T/log/post")"
[ "$(reqs)" = 0 ] && ok || bad "R2 requested a review: $(reqbody)"
[ "$(agents)" = 0 ] && ok || bad "R2 an agent call"
grep -q "example-org/demo-os#41 @${HM:0:12}: lead word already replayed onto this head" "$QLOG" && ok || bad "R2 no already-replayed line: $(cat "$QLOG")"
[ "$(awk -F'\t' '$3 == "replay"' "$Q/state/lead-review-enqueue/modes.tsv" | wc -l | tr -d ' ')" = 1 ] && ok || bad "R2 a second replay row was counted"

# ── R3: a lead BLOCK on G is never replayed, and nothing is requested ──
# TEST-CHANGE (BH-5630): R3 and R5's first tick pin "only the builder's approval
# asks for a review", which is LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 since
# BH-5630, so they tick with the builder gate on. No case removed.
reset "$HM" "$G" BLOCK; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 tick
[ "$RC" -eq 0 ] && ok || bad "R3 rc=$RC"
[ "$(postn)" = 0 ] && ok || bad "R3 a BLOCK was replayed: $(cat "$T/log/post")"
[ "$(reqs)" = 0 ] && ok || bad "R3 requested: $(reqbody)"
hasw replayed=0 && hasw skipped_no_approve=1 && ok || bad "R3 summary: $(summ)"

# ── R4: 12 changed lines, builder approved H: one delta-mode request ──
reset "$HD" "$HD" MERGE; tick
[ "$(postn)" = 0 ] && ok || bad "R4 a changed patch was replayed: $(cat "$T/log/post")"
[ "$(reqs)" = 1 ] && ok || bad "R4 want one request, got $(reqs)"
B=$(reqbody)
# TEST-CHANGE (BH-6391): a re-review now also carries the lead-prev: group after the
# lead-delta: note; the old prefix is matched exactly, then the new group's head.
case "$(jq -r .scope_notes <<<"$B" 2>/dev/null)" in
  "auto: builder APPROVE on ${HD:0:12}; lead-delta:$G lines:12/40 files:1; lead-prev:$G word:MERGE "*) ok ;;
  *) bad "R4 scope_notes: $B" ;;
esac
[ "$(jq -r .prior_verdict_ref <<<"$B" 2>/dev/null)" = "lead MERGE on $G12 (verdict row #5)" ] && ok || bad "R4 prior_verdict_ref: $B"
jq -e 'has("model") or has("reviewer_model")' <<<"$B" >/dev/null 2>&1 && bad "R4 the request names a model: $B" || ok
hasw delta=1 && hasw full=0 && hasw today_delta=1 && ok || bad "R4 summary: $(summ)"
[ "$(agents)" = 0 ] && ok || bad "R4 the enqueue called an agent"

# ── R5: the same head, builder APPROVE still on G: nothing asked; cached for later ──
reset "$HD" "$G" MERGE; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 tick
[ "$(reqs)" = 0 ] && [ "$(postn)" = 0 ] && ok || bad "R5 requests=$(reqs) posts=$(postn)"
hasw skipped_no_approve=1 && ok || bad "R5 summary: $(summ)"
grep -q "	$G	$HD	40	delta 12 40 1$" "$Q/state/lead-review-enqueue/delta.tsv" && ok || bad "R5 no cached class: $(cat "$Q/state/lead-review-enqueue/delta.tsv")"
F1=$(fetches)
[ "$F1" -ge 1 ] && ok || bad "R5 the first look fetched nothing"
# the builder now approves H: the cached class is reused, no second fetch
jq -c --arg s "$HD" '.reviewed_sha = $s' "$T/jv/41.json" > "$T/jv/x" && mv "$T/jv/x" "$T/jv/41.json"
rm -f "$T/log/qworker"; tick
[ "$(fetches)" = "$F1" ] && ok || bad "R5 fetched again ($(fetches) vs $F1) for a cached head pair"
case "$(jq -r .scope_notes <<<"$(reqbody)" 2>/dev/null)" in *"lead-delta:$G lines:12/40"*) ok ;; *) bad "R5 the approved tick did not ask in delta mode: $(reqbody)" ;; esac

# ── R6: a protected path in the inter-diff: a full review ──
reset "$HP" "$HP" MERGE; LEAD_DELTA_PROTECTED_MAX_LINES=0 tick
[ "$(postn)" = 0 ] && ok || bad "R6 a protected change was replayed: $(cat "$T/log/post")"
[ "$(reqs)" = 1 ] && ok || bad "R6 want one request, got $(reqs)"
case "$(jq -r .scope_notes <<<"$(reqbody)" 2>/dev/null)" in *lead-delta*) bad "R6 delta mode on a protected path: $(reqbody)" ;; *) ok ;; esac
grep -q "full protected:.github/workflows/x.yml" "$QLOG" && ok || bad "R6 no protected line: $(cat "$QLOG")"
hasw full=1 && hasw delta=0 && ok || bad "R6 summary: $(summ)"
# ld_protected on its own: .mergify.yml, schema, a catalog glob of the harness repo
(
  HARNESS="$Q"; . "$Q/bin/lib/lead-authority.sh"; . "$Q/bin/lib/lead-delta.sh"
  setting_get() { return 2; }
  printf 'a.txt\n.mergify.yml\n' | ld_protected example-org/demo-os >/dev/null || exit 11
  printf 'worker/jobs/schema.sql\n' | ld_protected example-org/demo-os >/dev/null || exit 12
  printf 'bin/lead-verdict.sh\n' | ld_protected example-org/cromford >/dev/null || exit 13
  printf 'bin/lead-verdict.sh\n' | ld_protected example-org/demo-os >/dev/null && exit 14
  setting_get() { return 1; }
  printf 'x\n' | ld_protected example-org/cromford >/dev/null; [ $? = 2 ] || exit 15
  exit 0
); PRC=$?
[ "$PRC" = 0 ] && ok || bad "R6 ld_protected unit check failed at exit $PRC"

# ── R7: over LEAD_DELTA_REVIEW_MAX_LINES: a full review ──
reset "$HB" "$HB" MERGE; tick
[ "$(reqs)" = 1 ] && ok || bad "R7 want one request, got $(reqs)"
case "$(jq -r .scope_notes <<<"$(reqbody)" 2>/dev/null)" in *lead-delta*) bad "R7 delta mode over the threshold: $(reqbody)" ;; *) ok ;; esac
grep -q "full over-max:60" "$QLOG" && ok || bad "R7 no over-max line: $(cat "$QLOG")"

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
