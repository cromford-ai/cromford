#!/bin/bash
# tests/lead-enqueue-no-builder-gate.bh-5630-test.sh — BH-5630: one review gate.
# bin/lead-review-enqueue.sh requests the lead review for a head with green CI
# even when no builder APPROVE is bound to that head. Before this change a push
# from outside the pipeline left the head unapproved and nothing was requested
# (skipped_no_approve=45 on 2026-10-08).
# bin/lead-review-enqueue.sh runs WHOLE (`tick`) against a scratch harness: the
# script plus its sourced closure (scratch_install_closure, bin/lead-review.sh
# included, whose `lead ci green` block the enqueue reads), a real git fixture
# repo, and stubs for curl (the jobs worker) and gh (REST: the PR, the base
# branch's .mergify.yml, the check runs, the compare).
# The PR is #41. The builder's APPROVE is on head A; the head is now B (or D),
# pushed from outside the pipeline.
#   G1  B with green CI: ONE lead request for B in the tick, scope note
#       `auto: CI green on <B12>`, a full request (no lead verdict before).
#   G2  B with CI pending, then failed: no request (skipped_ci=1).
#   G3  a lead verdict standing on B: no request (skipped_verdict=1).
#   G4  a second tick on B: no second request (the worker answers existing).
#   G5  a lead MERGE on A, and D = A + 30 lines in the PR's own file, green CI:
#       a DELTA request, lead-delta:<A> lines:30/40, prior_verdict_ref the lead
#       row on A.
#   G6  LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1: today's rule, no request for B
#       (skipped_no_approve=1), and no CI read.
#   G7  a builder BLOCK on the current head B (the pipeline is fixing it), CI
#       green: no request (skipped_no_approve=1), no CI read. No builder row at
#       all on B: requested (the gate opens only for "no row" and "APPROVE on
#       an earlier head").
#   G8  example-org/cromford, risk tier ENFORCE, a low-risk (docs-only)
#       head with no builder APPROVE and green CI: the risk tier classifies it
#       but posts no sign-off; the lead review is requested.
# Dispatcher section (BH-5874): gate 1, bin/lib/lead-gates.d/10-builder.sh, on
# the worklist. bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh (LEAD_REVIEW_WORKLIST=1).
#   D1  a builder BLOCK on the head, CI green: no lead_review job, no agent
#       call, one `[skip builder-block]` line naming #101.
#   D1b the same head on a second tick: still one `[skip builder-block]` line.
#   D2  no builder row, the knob unset (reads as 0), CI green: one job.
#   D3  no builder row, CI not green: no job, held=1, one `CI not known green` line.
#   D4  the builder ledger answers 500: no job, held=1.
#   D5  no builder row, LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1: one `[skip
#       no-approve]` line, no job, no check-run read.
#   D6  a builder APPROVE on an earlier head, head-bound reapproved@head: one
#       job, no check-run read. D6b the APPROVE on an earlier head, no rebind,
#       CI green: one job.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-no-builder-gate.bh-5630-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

# ───────────── the fixture repo: A, then B (small) and D (30 lines) ─────────────
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; echo 'pr line' >> "$WK/f.txt"; git -C "$WK" commit -qam "the pr"
A=$(git -C "$WK" rev-parse HEAD)
echo 'fixed outside the pipeline' >> "$WK/f.txt"; git -C "$WK" commit -qam "outside fix"
B=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb thirty "$A"; seq 1 30 | sed 's/^/delta line /' >> "$WK/f.txt"; git -C "$WK" commit -qam "30 lines"
D=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr thirty

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
scratch_install_closure bin/lead-review.sh "$Q" >/dev/null || bad "closure of bin/lead-review.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$Q/catalog/lanes.d/"
cp "$SRC/catalog/lead-protected-paths.tsv" "$Q/catalog/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"
printf 'cromford example-org/cromford https://demo.test /api 3 box-hub\n' >> "$Q/fleet.conf"
git clone -q "$OR" "$T/qrepos/demo-os"
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "CI"\n' | base64 | tr -d '\n' > "$T/mergify.b64"

# The jobs worker. A second POST for a (pr, head) it already holds answers
# existing:true, the way the real worker's ON CONFLICT does.
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
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true}' ;;
  "POST /api/lead-reviews")
    h=\$(jq -r .head_sha <<<"\$body")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif grep -qxF "\$h" "$T/log/held" 2>/dev/null; then out=\$(jq -c '{existing:true, request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body")
    else echo "\$h" >> "$T/log/held"; printf '%s\n' "\$body" >> "$T/log/created"
      code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/qbin/gh" <<EOF
#!/bin/bash
H=\$(cat "$T/qhead"); SL=\$(cat "$T/slug")
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/"*"/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$H" --arg sl "\$SL" '[{number:41, html_url:("https://github.com/"+\$sl+"/pull/41"), title:"t", draft:false, state:"open",
      user:{login:"operator",type:"User"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' ;;
  *"-X GET repos/example-org/"*"/pulls/41"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$H" --arg u "\$(cat "$T/author" 2>/dev/null || echo operator)" '{head:{sha:\$s},base:{ref:"main"},user:{login:\$u}}' ;;
  *"-X GET repos/example-org/"*"/contents/.mergify.yml"*)
    echo x >> "$T/log/ciread"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg c "\$(cat "$T/mergify.b64")" '{content:\$c, encoding:"base64"}' ;;
  *"-X GET repos/example-org/"*"/commits/"*"/check-runs"*)
    echo x >> "$T/log/ciread"
    st=\$(cat "$T/ci" 2>/dev/null || echo green)
    case "\$st" in
      green)   s=completed; c=success ;;
      pending) s=in_progress; c=null ;;
      *)       s=completed; c=failure ;;
    esac
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$H" --arg s "\$s" --arg c "\$c" '{total_count:1, check_runs:[{name:"CI", head_sha:\$h, status:\$s,
      conclusion:(if \$c == "null" then null else \$c end), app:{slug:"github-actions"}}]}' ;;
  *"-X GET repos/example-org/"*"/compare/"*)
    if [ -f "$T/cmp.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"fix: outside"}}],"files":[]}\n'; fi ;;
esac
exit 0
EOF
chmod +x "$T/qbin/curl" "$T/qbin/gh"

QLOG="$Q/logs/lead-review-enqueue.log"
# reset <head> [lead word on A] [lead word on head]
reset() {
  rm -f "$T/log"/q* "$T/log/post" "$T/log/created" "$T/log/held" "$T/log/ciread" "$T/ci" "$T/author" "$T/cmp.json" "$QLOG"
  echo example-org/demo-os > "$T/slug"; scratch_rm "$T/set"; mkdir -p "$T/set"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$1" > "$T/qhead"
  jq -nc --arg s "$A" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg a "$A" --arg h "$1" --arg wa "${2:-}" --arg wh "${3:-}" '{rows:([{id:4,repo:"example-org/demo-os",pr:41,head_sha:$a,source:"box",verdict:"APPROVE",note:""}]
    + (if $wa == "" then [] else [{id:5,repo:"example-org/demo-os",pr:41,head_sha:$a,source:"lead",verdict:$wa,note:"lead-review:lr-3"}] end)
    + (if $wh == "" then [] else [{id:6,repo:"example-org/demo-os",pr:41,head_sha:$h,source:"lead",verdict:$wh,note:"lead-review:lr-4"}] end)),
    truncated:false}' > "$T/vrows.json"
}
tick() {
  ( cd "$T" && PATH="$T/qbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS="$(cat "$T/slug")" \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 GH_ETAG=0 \
      bash "$Q/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
created() { [ -f "$T/log/created" ] && wc -l < "$T/log/created" | tr -d ' ' || echo 0; }
body1() { head -1 "$T/log/created" 2>/dev/null; }
ciread() { [ -f "$T/log/ciread" ] && wc -l < "$T/log/ciread" | tr -d ' ' || echo 0; }
summ() { grep ' tick repos=' "$QLOG" 2>/dev/null | tail -1; }
hasw() { summ | grep -qw -- "$1"; }

# ── G1: builder APPROVE on A, B pushed from outside, CI green: one request ──
reset "$B"; tick
[ "$RC" -eq 0 ] && ok || bad "G1 rc=$RC out=$(cat "$T/out")"
[ "$(created)" = 1 ] && ok || bad "G1 want one lead request for B, got $(created): $(summ) log: $(tail -5 "$QLOG" 2>/dev/null)"
[ "$(jq -r .head_sha <<<"$(body1)" 2>/dev/null)" = "$B" ] && ok || bad "G1 the request is not on B: $(body1)"
[ "$(jq -r .scope_notes <<<"$(body1)" 2>/dev/null)" = "auto: CI green on ${B:0:12}" ] && ok || bad "G1 scope_notes: $(body1)"
hasw requested=1 && hasw full=1 && hasw skipped_no_approve=0 && ok || bad "G1 summary: $(summ)"
[ "$(cnt=$(grep -c "@${B:0:12}: lead review requested" "$QLOG" 2>/dev/null); echo "${cnt:-0}")" = 1 ] && ok || bad "G1 no requested line"

# ── G4: a second tick on B: the worker already holds it, no second request ──
tick
[ "$(created)" = 1 ] && ok || bad "G4 a second request was created: $(created)"
hasw requested=0 && hasw existing=1 && ok || bad "G4 summary: $(summ)"
grep -q 'SECOND lead review request' "$T/log/qalerts" 2>/dev/null && bad "G4 the repeat alert fired" || ok

# ── G2: CI pending, then failed: nothing requested ──
for st in pending failed; do
  reset "$B"; echo "$st" > "$T/ci"; tick
  [ "$(created)" = 0 ] && ok || bad "G2 $st CI was requested: $(body1)"
  hasw skipped_ci=1 && ok || bad "G2 $st summary: $(summ)"
  grep -q "@${B:0:12}: no builder APPROVE on this head and CI not known green" "$QLOG" && ok || bad "G2 $st no not-green line: $(tail -3 "$QLOG")"
done

# ── G3: a lead verdict already stands on B ──
reset "$B" "" MERGE; tick
[ "$(created)" = 0 ] && ok || bad "G3 requested over a standing lead verdict: $(body1)"
hasw skipped_verdict=1 && ok || bad "G3 summary: $(summ)"

# ── G5: a lead MERGE on A, D = A + 30 lines: a delta request based on A ──
reset "$D" MERGE; tick
[ "$(created)" = 1 ] && ok || bad "G5 want one request, got $(created): $(tail -5 "$QLOG")"
# TEST-CHANGE (BH-6391): the same exact prefix, then the new lead-prev: group naming A.
case "$(jq -r .scope_notes <<<"$(body1)" 2>/dev/null)" in
  "auto: CI green on ${D:0:12}; lead-delta:$A lines:30/40 files:1; lead-prev:$A word:MERGE "*) ok ;;
  *) bad "G5 scope_notes: $(body1)" ;;
esac
[ "$(jq -r .prior_verdict_ref <<<"$(body1)" 2>/dev/null)" = "lead MERGE on ${A:0:12} (verdict row #5)" ] && ok || bad "G5 prior_verdict_ref: $(body1)"
hasw delta=1 && hasw full=0 && ok || bad "G5 summary: $(summ)"
[ ! -s "$T/log/post" ] && ok || bad "G5 a 30-line change was replayed: $(cat "$T/log/post")"

# ── G6: the knob restores the builder gate ──
reset "$B"; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 tick
[ "$(created)" = 0 ] && ok || bad "G6 requested with the builder gate on: $(body1)"
hasw skipped_no_approve=1 && ok || bad "G6 summary: $(summ)"
[ "$(ciread)" = 0 ] && ok || bad "G6 read CI with the builder gate on ($(ciread) reads)"

# ── G7: a builder BLOCK on the current head: skipped; no builder row: requested ──
reset "$B"
jq -c --arg s "$B" '.verdict = "BLOCK" | .reviewed_sha = $s' "$T/jv/41.json" > "$T/jv/x" && mv "$T/jv/x" "$T/jv/41.json"
tick
[ "$(created)" = 0 ] && ok || bad "G7 a head the builder BLOCKed was requested: $(body1)"
hasw skipped_no_approve=1 && ok || bad "G7 summary: $(summ)"
[ "$(ciread)" = 0 ] && ok || bad "G7 read CI for a BLOCKed head ($(ciread) reads)"
reset "$B"; rm -f "$T/jv/41.json"; tick
[ "$(created)" = 1 ] && [ "$(jq -r .head_sha <<<"$(body1)" 2>/dev/null)" = "$B" ] && ok || bad "G7 no builder row: want one request for B, got $(created): $(summ)"

# ── G8: risk tier enforce, a low-risk head nobody approved: requested, not signed ──
reset "$B"; echo example-org/cromford > "$T/slug"
printf 'enforce' > "$T/set/risk_tier.mode.example-org.cromford"; printf 'operator' > "$T/set/lead_pr_authors"
echo 'cromford[bot]' > "$T/author"
jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"docs: a note"}}], files:[{filename:"docs/a.md", additions:30, deletions:12}]}' > "$T/cmp.json"
tick
[ "$RC" -eq 0 ] && ok || bad "G8 rc=$RC out=$(cat "$T/out")"
grep -q -- '--source risk-tier' "$T/log/post" 2>/dev/null && bad "G8 the risk tier signed off a head nobody reviewed: $(cat "$T/log/post")" || ok
[ "$(created)" = 1 ] && [ "$(jq -r .head_sha <<<"$(body1)" 2>/dev/null)" = "$B" ] && ok || bad "G8 want one lead request for B, got $(created): $(tail -5 "$QLOG")"
hasw risk_low=1 && hasw risk_signed=0 && hasw requested=1 && ok || bad "G8 summary: $(summ)"
grep -q "@${B:0:12}: risk tier low, but no reviewer approved this head" "$QLOG" && ok || bad "G8 no line naming the skipped sign-off: $(tail -5 "$QLOG")"

# ═══════════ dispatcher section (BH-5874): gate 1 on the worklist ═══════════
T="$T/disp"; mkdir -p "$T"
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
[ -r "$H/bin/lib/lead-gates.d/05-skip-ledger.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/05-skip-ledger.sh"
[ -r "$H/bin/lib/lead-gates.d/10-builder.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/10-builder.sh"
djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
dskip() { lwf_cnt "\[skip $1\] example-org/demo-os#$2 @${SHA:0:12} " "$L"; }
dchecks() { lwf_cnt "commits/.*/check-runs" "$T/log/gh"; }

# ── D1 / D1b: a builder BLOCK with CI green does not start a review ──
lwf_reset; lwf_needs example-org/demo-os 101; lwf_ci_green "$SHA"; lwf_bv 101 BLOCK "$SHA"
lwf_tick
[ "$(djobs 101)" = 0 ] && ok || bad "D1 lead_review jobs for 101=$(djobs 101) (want 0): $(cat "$L")"
[ "$(lwf_agents)" = 0 ] && ok || bad "D1 agent calls=$(lwf_agents)"
[ "$(dskip builder-block 101)" = 1 ] && ok || bad "D1 [skip builder-block] lines=$(dskip builder-block 101): $(cat "$L")"
[[ "$(lwf_summary)" == *" skipped=1 "* ]] && ok || bad "D1 summary: $(lwf_summary)"
lwf_tick
[ "$(dskip builder-block 101)" = 1 ] && ok || bad "D1b [skip builder-block] lines after 2 ticks=$(dskip builder-block 101)"
[ "$(djobs 101)" = 0 ] && ok || bad "D1b jobs=$(djobs 101)"

# ── D2: no builder row, knob unset, CI green: one review ──
lwf_reset; lwf_needs example-org/demo-os 102; lwf_ci_green "$SHA"; : > "$FX/bv.102.none"
lwf_tick
[ "$(djobs 102)" = 1 ] && ok || bad "D2 jobs for 102=$(djobs 102) (want 1): $(cat "$L")"
[ "$(dchecks)" -ge 1 ] && ok || bad "D2 no check-run read"

# ── D3: no builder row, CI not green: held ──
lwf_reset; lwf_needs example-org/demo-os 103; : > "$FX/bv.103.none"
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "Tests"\n' > "$FX/mergify.yml"
lwf_tick
[ "$(djobs 103)" = 0 ] && ok || bad "D3 jobs for 103=$(djobs 103) (want 0)"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "D3 summary: $(lwf_summary)"
[ "$(lwf_cnt "example-org/demo-os#103 @${SHA:0:12}: no builder APPROVE on this head and CI not known green (required not green: Tests); held" "$L")" = 1 ] \
  && ok || bad "D3 no CI-not-green line: $(cat "$L")"

# ── D4: the builder ledger unreadable: held, never 'no builder row' ──
lwf_reset; lwf_needs example-org/demo-os 104; lwf_ci_green "$SHA"; : > "$FX/bv.104.fail"
lwf_tick
[ "$(djobs 104)" = 0 ] && ok || bad "D4 jobs for 104=$(djobs 104) (want 0)"
[[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "D4 summary: $(lwf_summary)"
grep -q "example-org/demo-os#104 @${SHA:0:12}: builder verdict unreadable (rc 1); held" "$L" && ok || bad "D4 no unreadable line: $(cat "$L")"

# ── D5: the builder gate on (REQB=1): skipped, no CI read ──
lwf_reset; lwf_needs example-org/demo-os 105; lwf_ci_green "$SHA"; : > "$FX/bv.105.none"
LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 lwf_tick
[ "$(djobs 105)" = 0 ] && ok || bad "D5 jobs for 105=$(djobs 105) (want 0)"
[ "$(dskip no-approve 105)" = 1 ] && ok || bad "D5 [skip no-approve] lines=$(dskip no-approve 105): $(cat "$L")"
[ "$(dchecks)" = 0 ] && ok || bad "D5 check-run reads=$(dchecks) (want 0)"

# ── D6 / D6b: an APPROVE on an earlier head ──
OLD=$(printf '%040d' 5)
lwf_reset; lwf_needs example-org/demo-os 106; lwf_bv 106 APPROVE "$OLD" "reapproved@$SHA"
lwf_tick
[ "$(djobs 106)" = 1 ] && ok || bad "D6 jobs for 106=$(djobs 106) (want 1): $(cat "$L")"
[ "$(dchecks)" = 0 ] && ok || bad "D6 a rebound head read check runs ($(dchecks))"
lwf_reset; lwf_needs example-org/demo-os 106; lwf_bv 106 APPROVE "$OLD"; lwf_ci_green "$SHA"
lwf_tick
[ "$(djobs 106)" = 1 ] && ok || bad "D6b jobs for 106=$(djobs 106) (want 1): $(cat "$L")"
lwf_reset; lwf_needs example-org/demo-os 106; lwf_bv 106 APPROVE "$OLD"
lwf_tick
[ "$(djobs 106)" = 0 ] && [[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "D6c an earlier APPROVE without green CI started: $(lwf_summary)"

echo "lead-enqueue-no-builder-gate.bh-5630: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
