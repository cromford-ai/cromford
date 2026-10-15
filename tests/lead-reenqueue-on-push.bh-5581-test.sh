#!/bin/bash
# tests/lead-reenqueue-on-push.bh-5581-test.sh — BH-5581: a re-pushed PR head
# with a prior lead verdict is asked for a lead review AT ONCE, not on the next
# */15 tick. Two production entry points, each run whole against a scratch tree:
#
#   bin/lead-review-enqueue.sh pr <item>... (the per-PR mode), on the fixture of
#   tests/lead-replay-merge-only.bh-5294-test.sh: real git repos, stubs for curl
#   (the jobs worker), gh (REST, every call logged) and bin/lead-verdict.sh.
#   The lead MERGEd head G; the new head HD = G + 12 lines in the PR's file.
#     E1  pr example-org/demo-os#41=pull_request.synchronize, builder APPROVE on
#         HD: ONE POST /api/lead-reviews for HD, one ledger line, one
#         `immediate lead review request (...), trigger=pull_request.synchronize`.
#     E2  the same call again: no POST, `already requested`, no second line.
#     E3  LEAD_REENQUEUE_ON_PUSH=0: no POST, no gh read, the log names the knob;
#         then `tick` asks for HD (one POST).
#     E4  no lead row on the PR: no POST, `no prior lead verdict`; `tick` asks.
#     E4b the only lead row is on HD itself: no POST.
#     E5  a repo not in LEAD_REVIEW_AUTO_REPOS: no list read, no POST.
#     E6  example-org/Demo-OS@<HD12>=check_suite.completed: one POST for HD.
#     E7  pr.lock held: rc 0, no POST, `left to the */15 tick`; a tick still runs.
#     E8  the tick summary still starts `tick repos=` and ends `rung=<n>`; the pr
#         summary starts `pr repos=` and carries trigger_items=.
#     E9  a truncated verdict history: no POST, `verdict history unreadable`.
#     E10 no valid item: rc 0, no gh read, one line.
#     E11 bin/lib/lead-reenqueue.sh missing: rc 0, no POST, one line.
#   bin/wake-loop.sh (the hub's doorbell), on tests/lib/wake-claim-stub.sh, with
#   bin/lead-review-enqueue.sh an argv recorder:
#     W1  hub, one pr row pull_request.synchronize #42: ONE launch, argv
#         `pr example-org/cromford#42=pull_request.synchronize`.
#     W2  hub, pull_request.closed / check_run.completed /
#         pull_request_review.submitted rows: no launch.
#     W3  hub, two synchronize rows for #42 and a check_suite.completed row:
#         ONE launch with two items.
#     W4  the box that owns the repo (not the hub), the same row: no launch.
#   P1-P4 the item parse and match table of bin/lib/lead-reenqueue.sh.
#   M1-M4 (D1) mutants: each goes red on the case that pins it.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-reenqueue-on-push.bh-5581-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd); SRC="$DIR"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review-enqueue.sh bin/wake-loop.sh bin/lib/lead-delta.sh catalog/lanes.d/_lib.lead-delta.json; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
LIB="$DIR/bin/lib/lead-reenqueue.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REENQUEUE_ON_PUSH LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

# ─────────────── P1-P4: the item table of bin/lib/lead-reenqueue.sh ───────────────
S40=0123456789abcdef0123456789abcdef01234567
P=$(
  log() { :; }
  # shellcheck source=/dev/null
  . "$LIB" 2>/dev/null || { echo "lib missing"; exit 1; }
  # P1: wake rows -> items (yes, yes, yes, edge 7-hex; no x5, edge 6-hex)
  lre_wake_row pr pull_request.synchronize example-org/cromford 42
  lre_wake_row pr pull_request.ready_for_review example-org/cromford 43
  lre_wake_row checks check_suite.completed example-org/cromford "${S40^^}"
  lre_wake_row checks check_suite.completed example-org/cromford abcdef1
  lre_wake_row pr pull_request.synchronize example-org/cromford 42
  lre_wake_row pr pull_request.closed example-org/cromford 44
  lre_wake_row pr pull_request_review.submitted example-org/cromford 45
  lre_wake_row checks check_run.completed example-org/cromford "$S40"
  lre_wake_row pr pull_request.synchronize example-org/cromford -
  lre_wake_row checks check_suite.completed example-org/cromford abcdef
  printf 'Q=%s\n' "${LRE_Q[*]}"
  # P2: parse: a malformed item is dropped, the repo is case-folded
  lre_parse 'example-org/Cromford#7=pull_request.synchronize' 'example-org/cromford@abcdef1=check_suite.completed' \
    'junk' 'example-org/cromford#x=pull_request.synchronize' 'example-org/cromford@abcdef=check_suite.completed' && echo "parse=ok"
  printf 'N=%s BAD=%s\n' "$LRE_N" "$LRE_BAD"
  lre_parse 'junk' || echo "parse-none=rc1"
  lre_parse 'example-org/Cromford#7=pull_request.synchronize' 'example-org/cromford@abcdef1=check_suite.completed'
  # P3: repo and row match
  lre_repo_wanted example-org/cromford && echo "repo=yes"
  lre_repo_wanted example-org/project-3 || echo "other-repo=no"
  lre_row_wanted example-org/cromford 7 "$S40" && echo "row7=$LRE_TRIG"
  lre_row_wanted example-org/cromford 8 "abcdef1${S40:7}" && echo "sha-prefix=$LRE_TRIG"
  lre_row_wanted example-org/cromford 9 "$S40" || echo "row9=no"
  lre_row_wanted example-org/project-3 7 "abcdef1${S40:7}" || echo "other-repo-sha=no"
  # P4: a 6-hex sha never matches, even as a prefix
  lre_parse 'example-org/cromford@abcdef=check_suite.completed' || echo "six-hex=refused"
)
grep -qx "Q=example-org/cromford#42=pull_request.synchronize example-org/cromford#43=pull_request.ready_for_review example-org/cromford@$S40=check_suite.completed example-org/cromford@abcdef1=check_suite.completed" <<<"$P" \
  && ok || bad "P1 wake rows -> items: $P"
grep -qx 'parse=ok' <<<"$P" && grep -qx "N=2 BAD=junk example-org/cromford#x=pull_request.synchronize example-org/cromford@abcdef=check_suite.completed" <<<"$P" \
  && grep -qx 'parse-none=rc1' <<<"$P" && ok || bad "P2 parse: $P"
grep -qx 'repo=yes' <<<"$P" && grep -qx 'other-repo=no' <<<"$P" && grep -qx 'row7=pull_request.synchronize' <<<"$P" \
  && grep -qx 'sha-prefix=check_suite.completed' <<<"$P" && grep -qx 'row9=no' <<<"$P" && grep -qx 'other-repo-sha=no' <<<"$P" \
  && ok || bad "P3 match: $P"
grep -qx 'six-hex=refused' <<<"$P" && ok || bad "P4 6-hex: $P"

# ───────────── the fixture repo: G, then HD = G + 12 lines ─────────────
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; printf 'other\n' > "$WK/o.txt"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; echo 'pr line' >> "$WK/f.txt"; git -C "$WK" commit -qam "the pr"
G=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb small "$G"; seq 1 12 | sed 's/^/small change /' >> "$WK/f.txt"; git -C "$WK" commit -qam "12 lines"
HD=$(git -C "$WK" rev-parse HEAD); HD12=${HD:0:12}
git -C "$WK" push -q "$OR" main pr small

# ═══════════════════ part 1: bin/lead-review-enqueue.sh pr ═══════════════════
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$Q/catalog/lanes.d" "$T/cfg" "$T/qrepos" "$T/log" "$T/qbin"
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/post"
exit 0
EOF
cat > "$Q/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/qalerts"
EOF
chmod +x "$Q/bin/lead-verdict.sh" "$Q/bin/lane-alert.sh"
scratch_install_closure bin/lead-review-enqueue.sh "$Q" >/dev/null || bad "closure of bin/lead-review-enqueue.sh"
scratch_install_closure bin/jobs-client.sh "$Q" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$Q/catalog/lanes.d/"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/qbin" "$LPPF" "$LPPDOWN"
printf 'lead-test-token-fixture\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"
git clone -q "$OR" "$T/qrepos/demo-os"

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
lead=0; grep -q '^x-lead-verdict-token: lead-test-token-fixture' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/qworker"
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
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
    elif grep -qx "\$(jq -r .head_sha <<<"\$body")" "$T/log/created" 2>/dev/null; then
      out=\$(jq -c '{existing:true, request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body")
    else jq -r .head_sha <<<"\$body" >> "$T/log/created"
      code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/qbin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/qgh"
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
LEDGER="$Q/state/lead-review-enqueue/requested.tsv"
# reset <lead word> <lead row head> — PR 41 at HD, the builder's APPROVE on HD,
# a box APPROVE row and (unless the word is `none`) one lead row.
reset() {
  rm -f "$T/log"/q* "$T/log/post" "$T/log/created" "$QLOG"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$HD" > "$T/qhead"
  jq -nc --arg s "$HD" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg g "$G" --arg hd "$HD" --arg w "$1" --arg lh "${2:-$G}" '{rows:([{id:4,repo:"example-org/demo-os",pr:41,head_sha:$hd,source:"box",verdict:"APPROVE",note:""}]
    + (if $w == "none" then [] else [{id:5,repo:"example-org/demo-os",pr:41,head_sha:$lh,source:"lead",verdict:$w,note:"lead-review:lr-3"}] end)),truncated:false}' > "$T/vrows.json"
}
run() { # run <mode> [items...] — the real script, with the registry's knob values
  ( cd "$T" && PATH="$T/qbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret-fixture JOBS_RETRIES=0 GH_ETAG=0 \
      bash "$Q/bin/lead-review-enqueue.sh" "$@" ) > "$T/out" 2>&1; RC=$?
}
reqs() { cat "$T/log/qworker" 2>/dev/null | grep -c '^POST /api/lead-reviews '; }
reqheads() { grep '^POST /api/lead-reviews ' "$T/log/qworker" 2>/dev/null | sed 's/^POST \/api\/lead-reviews //; s/ lead=[01]$//' | jq -r .head_sha; }
ghn() { cat "$T/log/qgh" 2>/dev/null | grep -vc 'api rate_limit'; }
listn() { cat "$T/log/qgh" 2>/dev/null | grep -c 'pulls?'; }
ledn() { awk -F'\t' -v h="$HD" '$4 == h' "$LEDGER" 2>/dev/null | wc -l | tr -d ' '; }
imm() { cat "$QLOG" 2>/dev/null | grep -c 'immediate lead review request'; }
summ() { grep -E ' (tick|pr) repos=' "$QLOG" 2>/dev/null | tail -1 | sed 's/^[0-9-]* [0-9:]*Z //'; }
SYNC="example-org/demo-os#41=pull_request.synchronize"

case_E1() {
  reset MERGE; run pr "$SYNC"
  [ "$RC" -eq 0 ] || { echo "E1 rc=$RC out=$(cat "$T/out") log=$(cat "$QLOG" 2>/dev/null)"; return 1; }
  [ "$(reqs)" = 1 ] && [ "$(reqheads)" = "$HD" ] || { echo "E1 want one request for $HD12, got $(reqs): $(reqheads) log=$(cat "$QLOG")"; return 1; }
  [ "$(ledn)" = 1 ] || { echo "E1 ledger: $(cat "$LEDGER" 2>/dev/null)"; return 1; }
  grep -q "example-org/demo-os#41 @$HD12: immediate lead review request (lr-9), trigger=pull_request.synchronize\$" "$QLOG" \
    && [ "$(imm)" = 1 ] || { echo "E1 log: $(cat "$QLOG")"; return 1; }
  ! grep -q ' tick repos=' "$QLOG" || { echo "E1 a tick ran"; return 1; }
}
case_E2() {
  case_E1 || return 1
  rm -f "$T/log/qworker"; run pr "$SYNC"
  [ "$(reqs)" = 0 ] || { echo "E2 a second POST: $(reqheads)"; return 1; }
  [ "$(ledn)" = 1 ] || { echo "E2 ledger: $(cat "$LEDGER")"; return 1; }
  grep -q "example-org/demo-os#41 @$HD12: already requested; nothing to do" "$QLOG" || { echo "E2 log: $(cat "$QLOG")"; return 1; }
  [ "$(imm)" = 1 ] || { echo "E2 a second immediate line: $(cat "$QLOG")"; return 1; }
}
case_E3() {
  reset MERGE; LEAD_REENQUEUE_ON_PUSH=0 run pr "$SYNC"
  [ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ] || { echo "E3 rc=$RC requests=$(reqs)"; return 1; }
  [ "$(ghn)" = 0 ] || { echo "E3 gh was read: $(cat "$T/log/qgh")"; return 1; }
  grep -q 'pr: LEAD_REENQUEUE_ON_PUSH=0; nothing requested, the \*/15 tick covers it' "$QLOG" || { echo "E3 log: $(cat "$QLOG")"; return 1; }
  [ ! -s "$LEDGER" ] || { echo "E3 a ledger line: $(cat "$LEDGER")"; return 1; }
  LEAD_REENQUEUE_ON_PUSH=0 run tick
  [ "$(reqs)" = 1 ] && [ "$(reqheads)" = "$HD" ] || { echo "E3 the tick did not ask: $(reqs) log=$(cat "$QLOG")"; return 1; }
  [ "$(imm)" = 0 ] || { echo "E3 the tick wrote an immediate line"; return 1; }
}
case_E4() {
  reset none; run pr "$SYNC"
  [ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ] || { echo "E4 rc=$RC requests=$(reqs): $(cat "$QLOG")"; return 1; }
  grep -q "example-org/demo-os#41 @$HD12: no prior lead verdict; left to the \*/15 tick" "$QLOG" || { echo "E4 log: $(cat "$QLOG")"; return 1; }
  run tick
  [ "$(reqs)" = 1 ] && [ "$(reqheads)" = "$HD" ] || { echo "E4 the tick did not ask: $(reqs) log=$(cat "$QLOG")"; return 1; }
}
case_E4b() {
  reset MERGE "$HD"; run pr "$SYNC"
  [ "$(reqs)" = 0 ] || { echo "E4b requested on a head whose only lead row is its own: $(reqheads)"; return 1; }
  grep -q 'no prior lead verdict' "$QLOG" || { echo "E4b log: $(cat "$QLOG")"; return 1; }
}
case_E5() {
  reset MERGE; run pr "example-org/other-os#41=pull_request.synchronize"
  [ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ] && [ "$(listn)" = 0 ] || { echo "E5 rc=$RC requests=$(reqs) list reads=$(listn)"; return 1; }
}
case_E6() {
  reset MERGE; run pr "example-org/Demo-OS@$HD12=check_suite.completed"
  [ "$(reqs)" = 1 ] && [ "$(reqheads)" = "$HD" ] || { echo "E6 want one request, got $(reqs): $(cat "$QLOG")"; return 1; }
  grep -q "@$HD12: immediate lead review request (lr-9), trigger=check_suite.completed\$" "$QLOG" || { echo "E6 log: $(cat "$QLOG")"; return 1; }
}
case_E7() {
  local r=0
  reset MERGE; mkdir -p "$Q/state/lead-review-enqueue"
  exec 7>"$Q/state/lead-review-enqueue/pr.lock"; flock 7
  run pr "$SYNC"
  { [ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ]; } || { echo "E7 rc=$RC requests=$(reqs)"; r=1; }
  grep -q "another pr run holds pr.lock; $SYNC left to the \*/15 tick" "$QLOG" || { echo "E7 log: $(cat "$QLOG")"; r=1; }
  run tick
  grep -q ' tick repos=' "$QLOG" && [ "$(reqs)" = 1 ] || { echo "E7 a tick beside a pr run did not run: $(cat "$QLOG")"; r=1; }
  exec 7>&-
  return "$r"
}
case_E8() {
  reset MERGE; run tick
  [[ "$(summ)" =~ ^tick\ repos=1\ prs=1\ .*\ skipped_rebase=[0-9]+\ rung=[0-9]+$ ]] || { echo "E8 tick summary: $(summ)"; return 1; }
  reset MERGE; run pr "$SYNC"
  [[ "$(summ)" =~ ^pr\ repos=1\ prs=1\ .*\ trigger_items=1\ rung=[0-9]+$ ]] || { echo "E8 pr summary: $(summ)"; return 1; }
}
case_E9() {
  reset MERGE; jq -c '.truncated = true' "$T/vrows.json" > "$T/v.tmp" && mv "$T/v.tmp" "$T/vrows.json"
  run pr "$SYNC"
  [ "$(reqs)" = 0 ] || { echo "E9 requested on a truncated history"; return 1; }
  grep -q "@$HD12: verdict history unreadable; left to the \*/15 tick" "$QLOG" || { echo "E9 log: $(cat "$QLOG")"; return 1; }
}
case_E10() {
  reset MERGE; run pr 'not-an-item'
  [ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ] && [ "$(ghn)" = 0 ] || { echo "E10 rc=$RC requests=$(reqs) gh=$(ghn)"; return 1; }
  grep -q 'pr: no valid item (not-an-item); nothing requested' "$QLOG" || { echo "E10 log: $(cat "$QLOG")"; return 1; }
}
case_E11() {
  local r=0
  reset MERGE; mv "$Q/bin/lib/lead-reenqueue.sh" "$T/lre.away" 2>/dev/null || { echo "E11 the closure did not install bin/lib/lead-reenqueue.sh"; return 1; }
  run pr "$SYNC"
  { [ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ]; } || { echo "E11 rc=$RC requests=$(reqs)"; r=1; }
  grep -q 'pr: missing bin/lib/lead-reenqueue.sh; nothing requested' "$QLOG" || { echo "E11 log: $(cat "$QLOG")"; r=1; }
  mv "$T/lre.away" "$Q/bin/lib/lead-reenqueue.sh"
  return "$r"
}

check() { local out; if out=$("$1" 2>&1); then ok; else bad "$1 — $out"; fi; }
# E7 holds a lock on fd 7 of THIS shell, so it runs here, not in check's subshell.
for c in E1 E2 E3 E4 E4b E5 E6; do check "case_$c"; done
if out=$(case_E7 2>&1); then ok; else bad "case_E7 — $out"; fi
for c in E8 E9 E10 E11; do check "case_$c"; done

# ─── D1 on the enqueue: mutate the script or the lib, and the pinning case goes red ───
emutant() { # emutant <name> <case> <repo-rel file> <sed-expr>
  local f="$3" keep="$T/mut.keep"
  [ -f "$SRC/$f" ] || { bad "$1: $f does not exist"; return; }
  sed -e "$4" "$SRC/$f" > "$T/mut.sh"
  if cmp -s "$T/mut.sh" "$SRC/$f"; then bad "$1: the sed did not change $f (the mutation point moved)"; return; fi
  cp -p "$Q/$f" "$keep"; cp "$T/mut.sh" "$Q/$f"
  if "$2" >/dev/null 2>&1; then bad "$1: $2 stayed GREEN on the mutant"; else ok; fi
  cp -p "$keep" "$Q/$f"
}
# M1: no prior-lead gate -> a head with no lead verdict is asked at once.
emutant M1 case_E4 bin/lead-review-enqueue.sh '/lre_row_go "\$SLUG"/d'
# M3: the knob is ignored.
emutant M3 case_E3 bin/lead-review-enqueue.sh 's/LEAD_REENQUEUE_ON_PUSH:-1}" = 0/LEAD_REENQUEUE_ON_PUSH:-1}" = never/'
# M4: no ledger dedup in the lib -> the second trigger re-POSTs.
emutant M4 case_E2 bin/lib/lead-reenqueue.sh '/already requested; nothing to do/s/return 1/:/'

# ═════════════════════ part 2: bin/wake-loop.sh on the hub ═════════════════════
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
WH="$T/wh"
LOOP_SRC="$DIR/bin/wake-loop.sh"
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train lead-review lead-review-land"
fresh() {
  scratch_rm "$WH"
  mkdir -p "$WH/bin/lib/jobs" "$WH/env" "$WH/logs" "$WH/locks" "$WH/state/wcs" "$WH/flags" "$WH/calls"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$WH/env/global.env"
  scratch_install_closure bin/wake-loop.sh "$WH" >/dev/null || { echo "FAIL: scratch_install_closure bin/wake-loop.sh"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$WH" >/dev/null || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
  cp "$LOOP_SRC" "$WH/bin/wake-loop.sh"
  wcs_install "$WH/bin"
  HARNESS="$WH" wcs_identity "$WH/bin" || { echo "wcs_identity failed"; exit 1; }
  cat > "$WH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'cromford\nproject-1\n'; exit 0; }
case "$1/$2" in
  cromford/repo) echo example-org/cromford ;;
  project-1/repo)   echo example-org/project-1 ;;
  cromford/box)  echo box-small ;;
  project-1/box)    echo local ;;
  */board_prefix)     echo /api/board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES lead-review-enqueue; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$WH/bin/$s.sh"
  done
  printf '#!/bin/bash\nexit 1\n' > "$WH/bin/unblocked-children.sh"
  printf '#!/bin/bash\necho "[]"\n' > "$WH/bin/gh"
  printf '#!/bin/bash\nexec "$@"\n' > "$WH/bin/setsid"
  chmod +x "$WH/bin/"*.sh "$WH/bin/gh" "$WH/bin/setsid"
  : > "$T/wakes.json"
}
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <repo> <kind> <key> <event>
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-10-11T03:00:00Z"}' "$1" "$2" "$3" "$4" "$5"
}
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    cur=$(cat "$WH/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 3 ] && return 0
    prev="$cur"
  done
}
run_as() {
  ( export HARNESS="$WH" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 WCS_WAKES="$T/wakes.json" PATH="$WH/bin:$PATH"
    unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
    BOX_NAME="$1" "$WH/bin/wake-loop.sh" ); settle
}
calls() { if [ -f "$WH/calls/$1" ]; then wc -l < "$WH/calls/$1" | tr -d " "; else echo 0; fi; }
WLOG() { cat "$WH/logs/wake-loop.log" 2>/dev/null; }
BH=example-org/cromford

case_W1() {
  fresh; wakes "$(W 1 $BH pr 42 pull_request.synchronize)"
  run_as box-hub
  [ "$(calls lead-review-enqueue)" = 1 ] || { echo "W1 launched $(calls lead-review-enqueue) time(s): $(WLOG)"; return 1; }
  [ "$(cat "$WH/calls/lead-review-enqueue")" = "pr $BH#42=pull_request.synchronize" ] || { echo "W1 argv: $(cat "$WH/calls/lead-review-enqueue")"; return 1; }
  grep -q 'lead-enqueue: launched lead-review-enqueue.sh pr' <<<"$(WLOG)" || { echo "W1 log: $(WLOG)"; return 1; }
}
case_W2() {
  fresh; wakes "$(W 1 $BH pr 42 pull_request.closed)" "$(W 2 $BH checks "$S40" check_run.completed)" \
    "$(W 3 $BH pr 42 pull_request_review.submitted)"
  run_as box-hub
  [ "$(calls lead-review-enqueue)" = 0 ] || { echo "W2 launched: $(cat "$WH/calls/lead-review-enqueue")"; return 1; }
}
case_W3() {
  fresh; wakes "$(W 1 $BH pr 42 pull_request.synchronize)" "$(W 2 $BH pr 42 pull_request.synchronize)" \
    "$(W 3 $BH checks "$S40" check_suite.completed)"
  run_as box-hub
  [ "$(calls lead-review-enqueue)" = 1 ] || { echo "W3 launched $(calls lead-review-enqueue) time(s): $(WLOG)"; return 1; }
  [ "$(cat "$WH/calls/lead-review-enqueue")" = "pr $BH#42=pull_request.synchronize $BH@$S40=check_suite.completed" ] \
    || { echo "W3 argv: $(cat "$WH/calls/lead-review-enqueue")"; return 1; }
}
case_W4() {
  fresh; wakes "$(W 1 $BH pr 42 pull_request.synchronize)"
  run_as box-small
  [ "$(calls lead-review-enqueue)" = 0 ] || { echo "W4 a build box launched: $(cat "$WH/calls/lead-review-enqueue")"; return 1; }
}
for c in W1 W2 W3 W4; do check "case_$c"; done

# M2: the wake-loop hook line is gone -> W1 goes red.
sed -e '/lre_wake_row "\$kind"/d' "$DIR/bin/wake-loop.sh" > "$T/wl-mutant.sh"
if cmp -s "$T/wl-mutant.sh" "$DIR/bin/wake-loop.sh"; then bad "M2: the sed did not change the loop (the mutation point moved)"
else LOOP_SRC="$T/wl-mutant.sh"; if case_W1 >/dev/null 2>&1; then bad "M2: case_W1 stayed GREEN on the mutant"; else ok; fi; LOOP_SRC="$DIR/bin/wake-loop.sh"; fi

echo "lead-reenqueue-on-push.bh-5581: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
