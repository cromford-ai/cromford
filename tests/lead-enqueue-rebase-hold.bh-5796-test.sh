#!/bin/bash
# tests/lead-enqueue-rebase-hold.bh-5796-test.sh — BH-5796: the lead-review
# enqueue never asks for a review of a head that conflicts with its base.
#
# WHY. 8 review BLOCKs found by hand that main had rewritten lines the PR also
# changed (#5693, #5395, #5140, #5138): the PR was DIRTY and the review could
# only say so. Now bin/lead-review-enqueue.sh holds such a head
# (`skipped_rebase`), says NEEDS_REBASE, and asks nothing:
#
#   E1  main rewrote a line the PR changes (a real `git merge-tree` conflict on
#       the hub clone): no request, a NEEDS_REBASE line naming f.txt
#   E2  a head that merges clean: requested
#   E3  the conductor's row has this head NEEDS_REBASE: no request
#   E4  LEAD_REVIEW_REBASE_HOLD=0: E1's head is requested
#   E5  (BH-5802) a head that re-adds a file main already shipped merges clean.
#       It is NOT held (nothing rebases a CLEAN head, so a hold would wait
#       forever: lead BLOCK on ddb6e4664). It is requested, and the request's
#       scope notes say `possible duplicate of <sha> (g.sh)` for checklist item 12
#
# The rig is tests/lead-enqueue-no-builder-gate.bh-5630-test.sh's: the script
# runs WHOLE against a scratch harness, a real git origin and hub clone, and
# stubs for curl (the jobs worker) and gh (REST). The builder's APPROVE is on
# the head, so only the new gate decides.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-rebase-hold.bh-5796-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

# ───────────── the fixture repo ─────────────
# main: f.txt (20 lines). PR head C changes line 5, then main REWRITES line 5
# (E1: a real conflict). K is a PR head that changes line 18 only (clean).
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; sed -i.bak 's/^base line 5$/the PR changed line 5/' "$WK/f.txt"; rm -f "$WK/f.txt.bak"
git -C "$WK" commit -qam "the pr"; C=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb clean main; sed -i.bak 's/^base line 18$/the PR changed line 18/' "$WK/f.txt"; rm -f "$WK/f.txt.bak"
git -C "$WK" commit -qam "a clean pr"; K=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -q main; sed -i.bak 's/^base line 5$/main rewrote line 5/' "$WK/f.txt"; rm -f "$WK/f.txt.bak"
git -C "$WK" commit -qam "main rewrites line 5"
# BH-5802: main then ships g.sh, and the PR head DUP (from the base) re-adds the
# same file. It merges CLEAN, so only the duplicate check can see it (E5).
printf 'guard_check() {\n  local path="$1"\n  case "$path" in /root/*) return 1 ;; esac\n  printf "guard ok for %%s\\n" "$path"\n}\n' > "$WK/g.sh"
git -C "$WK" add -A; git -C "$WK" commit -qm "main ships g.sh"; GSHIP=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb dup "$(git -C "$WK" rev-list --max-parents=0 main)"; git -C "$WK" show main:g.sh > "$WK/g.sh"
git -C "$WK" add -A; git -C "$WK" commit -qm "the pr re-adds g.sh"; DUP=$(git -C "$WK" rev-parse HEAD); git -C "$WK" checkout -q main
git -C "$WK" push -q "$OR" main pr clean dup
A="$C"
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
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$SRC/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/qbin" "$LPPF" "$LPPDOWN"
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
$(lpp_curl_case m url body)
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


# approve <head> — the builder's APPROVE bound to <head>, no lead verdict.
approve() {
  reset "$1"
  jq -nc --arg s "$1" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg h "$1" '{rows:[{id:4,repo:"example-org/demo-os",pr:41,head_sha:$h,source:"box",verdict:"APPROVE",note:""}],truncated:false}' > "$T/vrows.json"
}

# ── E1: main rewrote the PR's line: held, NEEDS_REBASE, no request ──
approve "$C"; tick
[ "$RC" -eq 0 ] && ok || bad "E1 rc=$RC out=$(cat "$T/out")"
[ "$(created)" = 0 ] && ok || bad "E1 a head that conflicts with main was requested: $(body1)"
grep -q "@${C:0:12}: .*NEEDS_REBASE.*f.txt" "$QLOG" && ok || bad "E1 no NEEDS_REBASE line naming f.txt: $(tail -4 "$QLOG")"
hasw skipped_rebase=1 && ok || bad "E1 summary: $(summ)"

# ── E2: a head that merges clean: requested ──
approve "$K"; tick
[ "$(created)" = 1 ] && ok || bad "E2 a clean head must be requested: $(summ) $(tail -4 "$QLOG")"
hasw skipped_rebase=0 && ok || bad "E2 summary: $(summ)"

# ── E3: the conductor's row says NEEDS_REBASE on this head ──
approve "$K"; mkdir -p "$Q/state/merge-conductor"
printf 'example-org/demo-os#41\tNEEDS_REBASE\t1\t%s\t%s\t0\tmergeState DIRTY\thttps://github.com/example-org/demo-os/pull/41\n' "$K" "$K" > "$Q/state/merge-conductor/pr-state.tsv"
tick
[ "$(created)" = 0 ] && ok || bad "E3 a head the conductor has NEEDS_REBASE was requested"
grep -q "@${K:0:12}: .*NEEDS_REBASE" "$QLOG" && ok || bad "E3 no NEEDS_REBASE line: $(tail -4 "$QLOG")"

# ── E4: the knob off: E1's head is requested ──
approve "$C"; LEAD_REVIEW_REBASE_HOLD=0 tick
[ "$(created)" = 1 ] && ok || bad "E4 LEAD_REVIEW_REBASE_HOLD=0 must request as before: $(summ)"

# ── E5 (BH-5802): the head re-adds a file main already shipped. It merges
# CLEAN, so it is requested (never held), and the note names main's commit ──
approve "$DUP"; tick
[ "$RC" -eq 0 ] && ok || bad "E5 rc=$RC out=$(cat "$T/out")"
[ "$(created)" = 1 ] && ok || bad "E5 a CLEAN head that may duplicate main must still be requested: $(summ)"
jq -er '.scope_notes' <<<"$(body1)" 2>/dev/null | grep -qF "possible duplicate of ${GSHIP:0:12} (g.sh)" && ok \
  || bad "E5 the request notes lack 'possible duplicate of ${GSHIP:0:12} (g.sh)': $(body1)"
hasw skipped_rebase=1 && bad "E5 a CLEAN head was held: $(summ)" || ok
grep -q "@${DUP:0:12}: .*possible duplicate of ${GSHIP:0:12} (g.sh)" "$QLOG" && ok \
  || bad "E5 no log line names the possible duplicate: $(tail -4 "$QLOG")"
# A duplicate note alone is not a delta review (lead review lr-5881-09c79da3a41e
# NOTE): the request is logged and counted as full. Only lead-delta: is delta.
grep -q "@${DUP:0:12}: lead review requested.* in delta mode" "$QLOG" && bad "E5 a duplicate-only note was logged as delta mode: $(grep "@${DUP:0:12}: lead review requested" "$QLOG" | tail -1)" || ok
awk -F'\t' -v h="$DUP" '$6 == h' "$Q"/state/lead-review-enqueue/modes.tsv 2>/dev/null | tail -1 | cut -f3 | grep -qx full && ok \
  || bad "E5 the modes row for a duplicate-only note must be full: $(cat "$Q"/state/lead-review-enqueue/modes.tsv 2>/dev/null | tail -2)"
# E5b: the knob off asks for it as before
approve "$DUP"; LEAD_REVIEW_REBASE_HOLD=0 tick
[ "$(created)" = 1 ] && ok || bad "E5b LEAD_REVIEW_REBASE_HOLD=0 must request the duplicate as before: $(summ)"

echo "lead-enqueue-rebase-hold.bh-5796: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
