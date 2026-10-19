#!/bin/bash
# tests/lead-hub-reconcile.bh-7235-test.sh — BH-7235 (BH-5878.1, slice C1):
# the two hub jobs of the lead review enqueue run in "$DIR/bin/pr-state-reconcile.sh",
# driven WHOLE (`tick`) on a scratch harness with its real lib closure, a
# stateful fake jobs worker (curl) and a fake gh. Ported from the first,
# abandoned attempt (origin/ticket/bh-5878, tests/lead-hub-reconcile.bh-5878-test.sh).
#   live probes (BH-5801, "$DIR/bin/lib/live-probes.sh")
#     P1  approved + CI green on the head, no lead verdict, facts written this
#         sweep: the declared catalog probe runs once (GET /api/flags) and one
#         App comment is posted; the done marker is written.
#     P1c the same with the facts already in the db.
#     P2  a second sweep on the same head runs nothing.
#     P3-P7 no probe: draft; held (a thread HOLD); CI not green; the builder
#         APPROVE on an earlier head; a lead verdict on the head.
#     P8  the PR thread is unreadable (held not judged): no probe.
#     P9  no App token: the third failed post raises ONE lane-alert through
#         alert_once (marker state/pr-state-reconcile/alerted-<id>); a fourth
#         sweep raises none. P9b a lane-alert that fails writes no marker.
#   console qa clear (BH-5909, "$DIR/bin/lib/console-qa-gate.sh")
#     Q1  a console-qa-gate BLOCK on the head + `QA: PASS for head <sha>`:
#         exactly one POST /api/lead-reviews/<id>/reset and one log line.
#     Q2  the next sweep: no second reset (marker in state/lead-review-enqueue/).
#     Q3  the PASS names another head: no reset.
#     Q4  the reset POST fails: no marker, one log line; the next sweep resets.
#     Q5  fleet.conf's cromford is another repo: no reset.
#     Q6  no standing verdict on the head: no cqg verdict read, no reset.
#     Q7  a marker the enqueue wrote for this head and PASS: no reset.
#   marker retention (PR_STATE_RECONCILE_MARKER_KEEP_DAYS, default 14)
#     (the knob is required: the suite exports the registry default, 14.)
#     S1  no stamp: a dry-run line counts the 15-day markers, deletes none.
#     S2  the stamp 25 h old: 15-day alerted-*, live-probes/* and qa-reset-*
#         go, 13-day ones stay, one `deleted files=3` line. S3 the stamp 1 h
#         old: no sweep line. S4 keep `abc`: one line, nothing deleted.
#   L1  live-probes.sh missing: one log line, the sweep still exits 0 with its
#       summary.
#   M1  mutation: the APPROVE condition removed, P6 runs a probe. M2 the marker
#       dir pointed at the sweep's temp dir, Q2 resets twice. M3 the
#       lp_run_for_head call removed, P1 runs no probe. M4 the cqg_clear_block
#       call removed, Q1 resets nothing. M5 the stamp check removed, S1
#       deletes on the first sweep.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-hub-reconcile.bh-7235-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }

# A dev shell's token must not decide gh_budget_low's path (as in bh-4950).
unset GH_TOKEN
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$H/catalog" "$T/fakebin" "$T/log" "$T/tmp"
scratch_install_closure bin/pr-state-reconcile.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/pr-state-reconcile.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
for f in bin/lib/live-probes.sh bin/lib/console-qa-gate.sh bin/lib/lead-reviews.sh; do
  [ -r "$H/$f" ] && ok || bad "setup: the closure of bin/pr-state-reconcile.sh does not carry $f"
done
cp "$DIR/catalog/live-probes.tsv" "$H/catalog/live-probes.tsv"
# The App mint, stubbed: an installation token, never a real one.
# $T/noapp = the mint gave the PAT back, so no post counts (P9).
printf 'gh_auth_for() { if [ -e "%s/noapp" ]; then export GH_TOKEN=tok-fixture-pat; else export GH_TOKEN=ghs_fixture_app; fi; }\n' "$T" > "$H/bin/lib/gh-app-auth.sh"
# $T/alertfail = lane-alert.sh exits 1 (P9b).
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log/lane-alert"\n[ -e "%s/alertfail" ] && exit 1\nexit 0\n' "$T" "$T" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
echo tok-fixture-lead > "$T/lead-token"

R=example-org/cromford
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
touch "$T/events.jsonl"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1 | sed 's/%2F/\//g'; }
code=200; out='{}'
case "\$m \$p" in
  "POST /api/pr-state-events")
    printf '%s\n' "\$body" >> "$T/events.jsonl"; code=201; out='{"recorded":true,"duplicate":false}' ;;
  "GET /api/pr-state/gate?"*)
    r=\$(qp repo)
    out=\$(jq -sc --arg r "\$r" '[.[] | select(.repo == \$r)] | group_by(.number)
      | map(. as \$e | reduce ("head","draft","closed","held","hotfix","ci_green_sha","builder_approved_sha","lead_verdict_sha","lead_verdict_word") as \$f
          ({repo: \$r, number: \$e[0].number}; .[\$f] = ([\$e[] | .[\$f] | select(. != null)] | last)))
      | {rows: ., as_of: "now"}' "$T/events.jsonl") ;;
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}') ;;
  "GET /api/flags")
    out='{"flags":[{"name":"fixture-flag","active":0}]}' ;;
  "POST /api/lead-reviews/"*/reset)
    if [ -e "$T/reset500" ]; then code=500; out='{"error":"boom"}'; else out='{"status":"requested"}'; fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/$R/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/$R/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/head/\$n")" --arg b "\$(cat "$T/body/\$n" 2>/dev/null)" '{state:"open",head:{sha:\$s},base:{ref:"main"},body:\$b}' ;;
  *"-X PATCH repos/$R/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n{}\n' ;;
  *"-X POST repos/$R/issues/"*"/comments"*)
    printf 'HTTP/2 201\r\n\r\n{"id":9,"user":{"login":"cromford[bot]","type":"Bot"}}\n' ;;
  *"-X GET repos/$R/issues/"*"/comments"*)
    a="\$*"; n="\${a##*/issues/}"; n="\${n%%/*}"
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/comments/\$n.json" 2>/dev/null || echo '[]' ;;
  *"actions/runs"*)
    a="\$*"; s="\${a##*head_sha=}"; s="\${s%%&*}"
    if [ -f "$T/ci/\$s" ]; then jq -nc --arg c "\$(cat "$T/ci/\$s")" '{workflow_runs:[{name:"Harness CI",status:"completed",conclusion:\$c,run_started_at:"2026-10-07T00:00:00Z"}]}'
    else echo '{"workflow_runs":[]}'; fi ;;
  *"check-runs"*)
    echo '{"check_runs":[]}' ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=$R \
  PR_STATE_RECONCILE_MAX_PER_SWEEP=30 PR_STATE_RECONCILE_MARKER_KEEP_DAYS=14 LEAD_VERDICT_TOKEN_FILE="$T/lead-token" FLEET_CONF="$H/fleet.conf"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME PR_SNAPSHOT LIVE_PROBES LIVE_PROBES_TRIES LIVE_PROBES_TICK_BUDGET_S

PROBE_BODY=$'Fixture PR.\n\n```live-probes\nprobe: flags\n```\n'
# pr <n> <head> [draft] — an open PR on $R at <head>, whose body declares the flags probe
pr() {
  jq -c --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" '. + [{number:$n, html_url:("https://github.com/'"$R"'/pull/"+($n|tostring)),
    title:"t", draft:$d, state:"open", user:{login:"operator",type:"User"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"},
    updated_at:"2026-10-07T00:00:00Z"}]' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"; printf '%s' "$PROBE_BODY" > "$T/body/$1"
}
approve() {
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
green() { echo success > "$T/ci/$1"; }
seed() { jq -nc --arg r "$R" --argjson n "$1" --argjson f "$2" '{repo:$r, number:$n, state:"gate", since:"seed", reason:"seed"} + $f' >> "$T/events.jsonl"; }
qa_block() { # qa_block <n> — a standing console-qa-gate BLOCK naming request lr-<n>-fixture
  jq -nc --arg id "lr-$1-fixture" '{verdict:"BLOCK", source:"lead", id:3, created_at:"x", reviewer_model:"console-qa-gate", note:("lead-review:" + $id)}' > "$T/standing/$1"
}
qa_pass() { # qa_pass <n> <sha> — a member's QA PASS comment naming <sha>
  jq -nc --arg s "$2" '[{author_association:"MEMBER", html_url:"https://github.com/x/y/pull/7#issuecomment-1", created_at:"2026-10-07T00:00:00Z",
    user:{type:"User", login:"operator"}, body:("QA: PASS for head " + $s + "\nQA COVERAGE: screens=2 shots=2")}]' > "$T/comments/$1.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{reset500,events.jsonl,noapp,alertfail} "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing head body comments ci; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo box-hub > "$H/state/box-name"
  printf 'cromford %s\n' "$R" > "$H/fleet.conf"
  echo '[]' > "$T/prs.json"; : > "$T/events.jsonl"
}
SCRIPT="$H/bin/pr-state-reconcile.sh"
tick() { ( cd "$T" && bash "$SCRIPT" tick ) > "$T/out" 2>&1; RC=$?; }
LOGF="$H/logs/pr-state-reconcile.log"
cnt() { grep -cF -- "$1" "$2" 2>/dev/null || true; }
probes() { grep -cx 'GET /api/flags ' "$T/log/worker" 2>/dev/null || true; }
posts() { cnt "-X POST repos/$R/issues/7/comments" "$T/log/gh"; }
resets() { cnt 'POST /api/lead-reviews/lr-7-fixture/reset' "$T/log/worker"; }
DONE="$H/state/live-probes/example-org_cromford-7-${A:0:12}.done"
QMARK="$H/state/lead-review-enqueue/qa-reset-example-org_cromford-7-${A:0:12}"

# ── P1: approved + green, written this sweep: one probe run, one App comment ──
reset; pr 7 "$A"; approve 7 "$A"; green "$A"; tick
[ "$RC" = 0 ] && ok || bad "P1 rc=$RC $(cat "$T/out")"
[ "$(probes)" = 1 ] && ok || bad "P1 probe runs=$(probes): $(cat "$T/log/worker" 2>/dev/null)"
[ "$(posts)" = 1 ] && ok || bad "P1 comment posts=$(posts): $(cat "$T/log/gh")"
[ -e "$DONE" ] && ok || bad "P1 no done marker; live-probes.log: $(cat "$H/logs/live-probes.log" 2>/dev/null)"
grep -q 'flags: rc 0' "$H/logs/live-probes.log" 2>/dev/null && ok || bad "P1 no probe line: $(cat "$H/logs/live-probes.log" 2>/dev/null)"
grep -q ' checked=1 ' "$LOGF" && ok || bad "P1 summary: $(cat "$LOGF")"

# ── P2: the same head next sweep: nothing more ──
tick
[ "$(probes)" = 1 ] && [ "$(posts)" = 1 ] && ok || bad "P2 a second run on the same head: probes=$(probes) posts=$(posts)"

# ── P1c: the facts already in the db ──
reset; pr 7 "$A"; seed 7 "{\"head\":\"$A\",\"draft\":0,\"builder_approved_sha\":\"$A\",\"ci_green_sha\":\"$A\"}"; tick
[ "$(probes)" = 1 ] && [ "$(posts)" = 1 ] && ok || bad "P1c db facts: probes=$(probes) posts=$(posts)"

# ── P3-P7: no probe ──
reset; pr 7 "$A" true; approve 7 "$A"; green "$A"; tick
[ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "P3 draft ran a probe"
reset; pr 7 "$A"; approve 7 "$A"; green "$A"
echo '[{"body":"HOLD: wait","created_at":"2026-10-07T00:00:00Z","user":{"type":"User","login":"operator"}}]' > "$T/comments/7.json"; tick
[ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "P4 held ran a probe"
reset; pr 7 "$A"; approve 7 "$A"; tick
[ "$(probes)" = 0 ] && ok || bad "P5 CI not green ran a probe"
reset; pr 7 "$A"; approve 7 "$B"; green "$A"; tick
[ "$(probes)" = 0 ] && ok || bad "P6 an APPROVE on an earlier head ran a probe"
reset; pr 7 "$A"; approve 7 "$A"; green "$A"
echo '{"verdict":"MERGE","source":"lead","id":3,"created_at":"x"}' > "$T/standing/7"; tick
[ "$(probes)" = 0 ] && ok || bad "P7 a lead verdict on the head ran a probe"

# ── P8: the thread is unreadable: held is not judged, so no probe ──
reset; pr 7 "$A"; approve 7 "$A"; green "$A"; echo '{"message":"not a list"}' > "$T/comments/7.json"; tick
[ "$RC" = 0 ] && ok || bad "P8 rc=$RC"
grep -q 'the PR thread is unreadable; held not judged' "$LOGF" && ok || bad "P8 no unreadable line: $(cat "$LOGF")"
[ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "P8 an unreadable thread ran a probe: probes=$(probes) posts=$(posts)"

# ── P9: no App token: the third failed post alerts once, through alert_once ──
AID="live-probes-example-org_cromford-7-${A:0:12}"
AMARK="$H/state/pr-state-reconcile/alerted-$AID"
alerts() { local c; c=$(cnt "--id $AID " "$T/log/lane-alert"); echo "${c:-0}"; }
reset; pr 7 "$A"; approve 7 "$A"; green "$A"; : > "$T/noapp"
tick; tick
[ "$(alerts)" = 0 ] && ok || bad "P9 an alert before the third try: $(cat "$T/log/lane-alert" 2>/dev/null)"
tick
[ "$(alerts)" = 1 ] && ok || bad "P9 alerts=$(alerts) after the third try: $(cat "$T/log/lane-alert" 2>/dev/null); live-probes.log: $(cat "$H/logs/live-probes.log" 2>/dev/null)"
grep -q -- '--severity warn' "$T/log/lane-alert" 2>/dev/null && grep -q ' pr-state-reconcile ' "$T/log/lane-alert" 2>/dev/null \
  && ok || bad "P9 alert argv: $(cat "$T/log/lane-alert" 2>/dev/null)"
[ -e "$AMARK" ] && ok || bad "P9 no alert marker at $AMARK"
[ "$(posts)" = 0 ] && ok || bad "P9 a post with no App token"
tick
[ "$(alerts)" = 1 ] && ok || bad "P9 a fourth sweep alerted again: $(alerts)"
# P9b: a lane-alert that fails writes no marker.
reset; pr 7 "$A"; approve 7 "$A"; green "$A"; : > "$T/noapp"; : > "$T/alertfail"
export LIVE_PROBES_TRIES=1; tick; unset LIVE_PROBES_TRIES
[ "$(alerts)" = 1 ] && ok || bad "P9b alerts=$(alerts)"
[ ! -e "$AMARK" ] && ok || bad "P9b a failed lane-alert wrote the marker"

# ── Q1: a console-qa-gate BLOCK and a PASS on the head: one reset ──
reset; pr 7 "$A"; qa_block 7; qa_pass 7 "$A"; tick
[ "$RC" = 0 ] && ok || bad "Q1 rc=$RC"
[ "$(resets)" = 1 ] && ok || bad "Q1 resets=$(resets): $(cat "$T/log/worker")"
[ "$(cnt 'lead review lr-7-fixture reset' "$LOGF")" = 1 ] && ok || bad "Q1 log: $(cat "$LOGF")"
[ -s "$QMARK" ] && ok || bad "Q1 no marker at $QMARK"
# ── Q2: the next sweep resets nothing ──
tick
[ "$(resets)" = 1 ] && ok || bad "Q2 resets=$(resets) after a second sweep"
# ── Q3: the PASS names another head ──
reset; pr 7 "$A"; qa_block 7; qa_pass 7 "$B"; tick
[ "$(resets)" = 0 ] && ok || bad "Q3 a PASS for another head reset"
# ── Q4: a failed reset leaves no marker; the next sweep resets ──
reset; pr 7 "$A"; qa_block 7; qa_pass 7 "$A"; touch "$T/reset500"; tick
[ ! -e "$QMARK" ] && ok || bad "Q4 a failed reset wrote the marker"
[ "$(cnt 'reset of lead review lr-7-fixture failed' "$LOGF")" = 1 ] && ok || bad "Q4 no failure line: $(cat "$LOGF")"
rm -f "$T/reset500"; tick
[ -s "$QMARK" ] && [ "$(resets)" = 2 ] && ok || bad "Q4 retry: resets=$(resets) marker=$(cat "$QMARK" 2>/dev/null)"
# ── Q5: not the cromford repo ──
reset; pr 7 "$A"; qa_block 7; qa_pass 7 "$A"; printf 'cromford example-org/other-repo\n' > "$H/fleet.conf"; tick
[ "$(resets)" = 0 ] && ok || bad "Q5 another repo reset"
# ── Q6: no standing verdict on the head: the QA job does not read ──
reset; pr 7 "$A"; qa_pass 7 "$A"; tick
[ "$(resets)" = 0 ] && ok || bad "Q6 a reset with no standing verdict"
[ "$(grep -c '^GET /api/verdicts?' "$T/log/worker")" = 1 ] && ok \
  || bad "Q6 verdict reads=$(grep -c '^GET /api/verdicts?' "$T/log/worker") (want the reconcile's one): $(grep verdicts "$T/log/worker")"
# ── Q7: a marker the enqueue wrote for this head: no second reset ──
reset; pr 7 "$A"; qa_block 7; qa_pass 7 "$A"
mkdir -p "${QMARK%/*}"; printf '%s\n' 'https://github.com/x/y/pull/7#issuecomment-1' > "$QMARK"; tick
[ "$(resets)" = 0 ] && ok || bad "Q7 reset a head the enqueue already reset: $(resets)"

# ── S1-S4: the marker sweep ──
age() { touch -d "@$(( $(date +%s) - $2 * 3600 ))" "$1"; }
seed_markers() {
  mkdir -p "$H/state/pr-state-reconcile" "$H/state/live-probes" "$H/state/lead-review-enqueue"
  for d in "pr-state-reconcile/alerted-x" "live-probes/example-org_cromford-9-aaaaaaaaaaaa" "lead-review-enqueue/qa-reset-x"; do
    : > "$H/state/$d-old"; age "$H/state/$d-old" 360
    : > "$H/state/$d-new"; age "$H/state/$d-new" 312
  done
  : > "$H/state/lead-review-enqueue/requested.tsv"; age "$H/state/lead-review-enqueue/requested.tsv" 360
}
olds() { local f n=0; for f in "$H"/state/pr-state-reconcile/alerted-x-old "$H"/state/live-probes/*-old "$H"/state/lead-review-enqueue/qa-reset-x-old; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
news() { local f n=0; for f in "$H"/state/pr-state-reconcile/alerted-x-new "$H"/state/live-probes/*-new "$H"/state/lead-review-enqueue/qa-reset-x-new; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
STAMPF="$H/state/pr-state-reconcile/marker-sweep.stamp"
reset; seed_markers; tick
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC"
[ "$(cnt 'marker-sweep: dry-run files=3 keep=14d' "$LOGF")" = 1 ] && ok || bad "S1 no dry-run line: $(cat "$LOGF")"
[ "$(olds)" = 3 ] && [ "$(news)" = 3 ] && ok || bad "S1 the dry run deleted: olds=$(olds) news=$(news)"
[ -e "$STAMPF" ] && ok || bad "S1 no stamp"
age "$STAMPF" 25; rm -f "$LOGF"; tick
[ "$(cnt 'marker-sweep: deleted files=3 keep=14d' "$LOGF")" = 1 ] && ok || bad "S2 no delete line: $(cat "$LOGF")"
[ "$(olds)" = 0 ] && ok || bad "S2 15-day markers left: $(olds)"
[ "$(news)" = 3 ] && ok || bad "S2 13-day markers deleted: $(news) of 3 left"
[ -e "$H/state/lead-review-enqueue/requested.tsv" ] && ok || bad "S2 deleted requested.tsv (not a qa-reset marker)"
rm -f "$LOGF"; tick
[ "$(cnt 'marker-sweep' "$LOGF")" = 0 ] && ok || bad "S3 a second sweep inside 24 h: $(cat "$LOGF")"
reset; seed_markers; : > "$STAMPF"; age "$STAMPF" 25
PR_STATE_RECONCILE_MARKER_KEEP_DAYS=abc; tick; PR_STATE_RECONCILE_MARKER_KEEP_DAYS=14
[ "$(cnt "PR_STATE_RECONCILE_MARKER_KEEP_DAYS='abc' is not a whole number; no marker sweep" "$LOGF")" = 1 ] && ok || bad "S4 no knob line: $(cat "$LOGF")"
[ "$(olds)" = 3 ] && ok || bad "S4 a bad knob deleted markers"
PR_STATE_RECONCILE_MARKER_KEEP_DAYS=0; rm -f "$LOGF"; tick; PR_STATE_RECONCILE_MARKER_KEEP_DAYS=14
[ "$(olds)" = 3 ] && [ "$(cnt 'marker-sweep' "$LOGF")" = 0 ] && ok || bad "S4 keep 0 swept: olds=$(olds) $(cat "$LOGF")"

# ── L1: the probe lib missing: one line, the sweep still ends with its summary ──
reset; pr 7 "$A"; approve 7 "$A"; green "$A"
mv "$H/bin/lib/live-probes.sh" "$T/live-probes.sh.kept"; tick
mv "$T/live-probes.sh.kept" "$H/bin/lib/live-probes.sh"
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC"
[ "$(cnt 'live-probes.sh missing' "$LOGF")" = 1 ] && grep -q ' checked=1 ' "$LOGF" && ok || bad "L1 log: $(cat "$LOGF")"
[ "$(probes)" = 0 ] && ok || bad "L1 ran a probe with no lib"

# ── M1-M5: mutations of the real script go red ──
cp "$H/bin/pr-state-reconcile.sh" "$T/real.sh"
sed 's/ && \[ "\$E_APP" = 1 \]//' "$T/real.sh" > "$H/bin/pr-state-reconcile.sh"
cmp -s "$T/real.sh" "$H/bin/pr-state-reconcile.sh" && bad "M1 the mutation did not apply" || ok
reset; pr 7 "$A"; approve 7 "$B"; green "$A"; tick
[ "$(probes)" = 1 ] && ok || bad "M1 with no APPROVE condition P6 still ran no probe (the case cannot see the condition)"
sed 's#cqg_clear_block "\$SLUG" "\$N" "\$HEAD" "\$H/state/lead-review-enqueue"#cqg_clear_block "$SLUG" "$N" "$HEAD" "$WORK"#' "$T/real.sh" > "$H/bin/pr-state-reconcile.sh"
cmp -s "$T/real.sh" "$H/bin/pr-state-reconcile.sh" && bad "M2 the mutation did not apply" || ok
reset; pr 7 "$A"; qa_block 7; qa_pass 7 "$A"; tick; tick
[ "$(resets)" = 2 ] && ok || bad "M2 with the marker in a temp dir Q2 still saw one reset: $(resets)"
sed 's/^\( *\)lp_run_for_head "\$SLUG".*$/\1:/' "$T/real.sh" > "$H/bin/pr-state-reconcile.sh"
cmp -s "$T/real.sh" "$H/bin/pr-state-reconcile.sh" && bad "M3 the mutation did not apply" || ok
reset; pr 7 "$A"; approve 7 "$A"; green "$A"; tick
[ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "M3 with no lp_run_for_head call P1 still ran a probe: probes=$(probes)"
sed 's/^\( *\)CQL=\$(cqg_clear_block .*$/\1CQL=""/' "$T/real.sh" > "$H/bin/pr-state-reconcile.sh"
cmp -s "$T/real.sh" "$H/bin/pr-state-reconcile.sh" && bad "M4 the mutation did not apply" || ok
reset; pr 7 "$A"; qa_block 7; qa_pass 7 "$A"; tick
[ "$(resets)" = 0 ] && ok || bad "M4 with no cqg_clear_block call Q1 still reset: $(resets)"
sed 's/if \[ ! -e "\$stamp" \]; then mode=dry-run/if false; then mode=dry-run/' "$T/real.sh" > "$H/bin/pr-state-reconcile.sh"
cmp -s "$T/real.sh" "$H/bin/pr-state-reconcile.sh" && bad "M5 the mutation did not apply" || ok
reset; seed_markers; tick
[ "$(olds)" = 0 ] && ok || bad "M5 with no dry-run rule S1 still deleted nothing: olds=$(olds)"
cp "$T/real.sh" "$H/bin/pr-state-reconcile.sh"

echo "lead-hub-reconcile.bh-7235: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
