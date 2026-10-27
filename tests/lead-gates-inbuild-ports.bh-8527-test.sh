#!/bin/bash
# tests/lead-gates-inbuild-ports.bh-8527-test.sh — BH-8527 (BH-8496.3): the
# gate-70 cases of tests/inbuild-grace-outside-push.bh-5740-test.sh and
# tests/medium-tier-inbuild-review.bh-5023-test.sh that have no worklist twin,
# ported from the retired enqueue tick to the worklist gate
# bin/lib/lead-gates.d/70-inbuild-grace.sh. Every case drives
# bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh plus
# tests/lib/lead-gates-fixture.bh-5875.sh). PR 104, live head HB, medium (one
# bin/lib file, 50 lines) under risk_tier.mode enforce unless a case says otherwise.
# A test-local curl sits in front of the fixture's for GET /api/verdict?: it
# counts each read in $T/log/vcount, answers 404 when $FX/jv.404 exists, and
# answers 500 from read N on when $T/v500-from holds N.
#   IG1   (bh-5740 G1) a 404 verdict: a job, no marker, one skipped line `no job recorded the PR`.
#   IG3   (G3) a build done on the older head HA: a job, `is done`.
#   IG4   (G4) a build running bound to HA: a job, `is bound to <HA12>`.
#   IG5   (G5) a provisional running build on HB: held.
#   IG5b  (G5b) queued_for_retry on HB: held.
#   IG6   (G6) a build done on HB: a job, `is done`.
#   IG6b  (G6b) a review job running on HB: a job, `not a build`.
#   IG7   (G7) the gate-70 job read answers 500: held, one `read failed` line.
#   IG8   (bh-5740 G8, bh-5023 G8) grace 0 and a future-dated marker: a job, no skipped line, no awaiting line.
#   IG9   (G9) two medium PRs with no .job: one skipped line per PR.
#   IH3   (bh-5023 G3) a high head (.mergify.yml) under enforce: a job, no marker.
#   IR5   (bh-5023 G5) risk_tier.inbuild_grace_s 60, a 2-minute marker: a job, `grace spent (60 s`.
#   IR5c  the same marker under the default grace (no row): held.
#   IGS   no secret in the logs.
#   M1    the skipped return line removed from the gate: IG3's head is held (D1).
#   M2    queued_for_retry removed from the live statuses: IG5b's head gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-inbuild-ports.bh-8527-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
GATE=bin/lib/lead-gates.d/70-inbuild-grace.sh
[ -r "$LWF_SRC/$GATE" ] && [ -r "$LWF_SRC/bin/lead-review.sh" ] && ok || bad "setup: $GATE or bin/lead-review.sh missing in $LWF_SRC"
[ -r "$H/$GATE" ] && ok || bad "setup: the closure did not install $GATE"

mv "$T/fakebin/curl" "$T/fakebin/curl.lgf"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\${url#https://jobs.test}" in
  "/api/verdict?"*)
    ( flock 9; echo r >> "$T/log/vcount" ) 9>"$T/vcount.lock"
    k=\$(wc -l < "$T/log/vcount")
    if [ -e "$FX/jv.404" ]; then printf '{"error":"no job has recorded this PR"}\n404'; exit 0; fi
    if [ -r "$T/v500-from" ] && [ "\$k" -ge "\$(cat "$T/v500-from")" ]; then printf '{"error":"fixture outage"}\n500'; exit 0; fi ;;
esac
exec "$T/fakebin/curl.lgf" "\$@"
EOF
chmod +x "$T/fakebin/curl"

HA=$(printf 'a%.0s' {1..40}); A12=${HA:0:12}
HB=$(printf 'b%.0s' {1..40}); B12=${HB:0:12}
HC=$(printf 'c%.0s' {1..40})
ST="$H/state/lead-review-enqueue"
MARK="$ST/inbuild-wait-example-org_cromford-104-$B12"
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
HIGHF='[[".mergify.yml","modified",1,1,"@@ -1 +1 @@\n+x: 1"]]'

# setp [mode] [files json] — PR 104 on HB alone; no verdict answer of this suite's
setp() {
  lgf_reset "${1:-enforce}"; lgf_needs "104:$HB"; lgf_cmp "$HB" "${2:-$MEDF}"
  rm -f "$FX/jv.json" "$FX/jv.404" "$T/v500-from" "$T/log/vcount"
}
# jvx <reviewed_sha|""> <kind> <status> [settled true|false] — PR 104's
# /api/verdict answer in the shape worker/jobs/src/routes/verdict.js returns
# (.job the ledger's build-first jobs row, .reviewed_sha the verdict detail's head).
jvx() {
  jq -nc --arg s "$1" --arg k "$2" --arg st "$3" --argjson se "${4:-true}" '{pr:"https://github.com/example-org/cromford/pull/104",
    job_id:"job-b", job:{id:"job-b", kind:$k, status:$st, project:"cromford"},
    verdict:"APPROVE", tier:"2", provenance:"claude", reviewed_sha:(if $s == "" then null else $s end),
    artifacts:[{artifact_kind:"verdict", artifact_ref:"APPROVE", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:$se}|tojson)}]}' > "$FX/jv.json"
}
mark() { [ -e "$MARK" ]; }
skipped() { lwf_cnt "inbuild-grace skipped #$1 head=" "$L"; }
skipline() { grep "inbuild-grace skipped #$1 head=" "$L" 2>/dev/null | head -1; }
awaiting() { grep -Eq "@$B12: awaiting the in-build lead-grade review \(3[0-9]{3}s left\)" "$L"; }
# req <label> <why>: one job for PR 104, no marker, one skipped line naming <why>
req() {
  [ "$RC" -eq 0 ] && ok || bad "$1 rc=$RC out=$(cat "$T/out")"
  [ "$(lgf_jobs 104)" = 1 ] && ok || bad "$1 want one job for PR 104, got $(lgf_jobs 104): $(cat "$L")"
  mark && bad "$1 an in-build wait marker for a head no build reviews" || ok
  [ "$(skipped 104)" = 1 ] && ok || bad "$1 want one skipped line, got $(skipped 104): $(cat "$L")"
  case "$(skipline 104)" in *"head=$B12: no build job for this head"*"$2"*) ok ;; *) bad "$1 the skipped line does not say '$2': $(skipline 104)" ;; esac
}
# held <label>: no job, the marker, one awaiting line, no skipped line, held=1
held() {
  [ "$RC" -eq 0 ] && ok || bad "$1 rc=$RC out=$(cat "$T/out")"
  [ "$(lgf_jobs 104)" = 0 ] && ok || bad "$1 a job for a head a live build reviews: $(cat "$L")"
  mark && ok || bad "$1 no in-build wait marker"
  awaiting && ok || bad "$1 no awaiting line: $(cat "$L")"
  [ "$(skipped 104)" = 0 ] && ok || bad "$1 a skipped line on a held head: $(skipline 104)"
  [[ "$(lwf_summary)" == *" held=1"* ]] && ok || bad "$1 summary: $(lwf_summary)"
}

# ── IG1: no job recorded the PR (404) ──
setp; : > "$FX/jv.404"; lwf_tick; req IG1 "no job recorded the PR"

# ── IG3: a build done on the older head HA ──
setp; jvx "$HA" build done; lwf_tick; req IG3 "is done"

# ── IG4: a build still running, bound to HA ──
setp; jvx "$HA" build running; lwf_tick; req IG4 "is bound to $A12"

# ── IG5: a provisional build row on HB; IG5b queued_for_retry on HB ──
setp; jvx "$HB" build running false; lwf_tick; held IG5
setp; jvx "$HB" build queued_for_retry; lwf_tick; held IG5b

# ── IG6: a build done on HB; IG6b a review job running on HB ──
setp; jvx "$HB" build done; lwf_tick; req IG6 "is done"
setp; jvx "$HB" review running; lwf_tick; req IG6b "not a build"

# ── IG7: the gate-70 job read (the last verdict read of a held tick) answers 500 ──
setp; jvx "$HB" build running; lwf_tick
N=$(lwf_cnt . "$T/log/vcount")
[ "$N" -ge 1 ] && ok || bad "IG7 a held tick read no verdict: $(cat "$L")"
setp; jvx "$HB" build running; echo "$N" > "$T/v500-from"; lwf_tick; held IG7
grep -Eq "@$B12: build job read failed \(rc [0-9]+\); the in-build grace holds as before" "$L" && ok \
  || bad "IG7 no read-failed line (the 500 hit read $N): $(cat "$L")"

# ── IG8: a grace row of 0 holds nothing, even with a marker newer than the tick ──
setp; jvx "$HB" build running; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
mkdir -p "$ST"; : > "$MARK"; touch -d '+1 minute' "$MARK"; lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "IG8 a 0 s grace held the head: $(cat "$L")"
[ "$(skipped 104)" = 0 ] && ok || bad "IG8 a skipped line with the grace off: $(skipline 104)"
grep -q 'awaiting the in-build' "$L" && bad "IG8 an awaiting line with the grace off" || ok

# ── IG9: two medium PRs, no .job in the verdict answer: one skipped line each ──
setp; lgf_needs "104:$HB" "105:$HC"; lgf_cmp "$HC" "$MEDF"; lwf_tick
[ "$(skipped 104)" = 1 ] && [ "$(skipped 105)" = 1 ] && ok || bad "IG9 want a skipped line per PR: $(grep 'inbuild-grace skipped' "$L")"
case "$(skipline 104)|$(skipline 105)" in *"no job row"*"|"*"no job row"*) ok ;; *) bad "IG9 the skipped lines do not say 'no job row': $(grep 'inbuild-grace skipped' "$L")" ;; esac

# ── IH3: a high head is never held ──
setp enforce "$HIGHF"; jvx "$HB" build running; lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "IH3 no job for a high head: $(cat "$L")"
mark && bad "IH3 a high head waited" || ok
grep -q 'awaiting the in-build' "$L" && bad "IH3 an awaiting line on a high head" || ok

# ── IR5: a 60 s grace row overrides the 3600 s default; IR5c the control ──
setp; jvx "$HB" build running; printf 60 > "$FX/settings/risk_tier.inbuild_grace_s"
mkdir -p "$ST"; : > "$MARK"; touch -d '-2 minutes' "$MARK"; lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "IR5 a 60 s grace row did not override 3600: $(cat "$L")"
grep -q "@$B12: in-build grace spent (60 s" "$L" && ok || bad "IR5 no grace-spent line: $(cat "$L")"
setp; jvx "$HB" build running; mkdir -p "$ST"; : > "$MARK"; touch -d '-2 minutes' "$MARK"; lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "IR5c a 2-minute marker under the 3600 s default got a job"
grep -Eq "@$B12: awaiting the in-build lead-grade review \([0-9]+s left\)" "$L" && ok || bad "IR5c no awaiting line: $(cat "$L")"

# ── IGS: secrets stay out of the logs ──
grep -rqE 'test-secret' "$H/logs" "$T/out" && bad "a secret reached a log" || ok

# ── M1: no skipped return: IG3's head (no live build) is held ──
sed -i '/inbuild-grace skipped/d' "$H/$GATE"
cmp -s "$LWF_SRC/$GATE" "$H/$GATE" && bad "M1 the mutation changed nothing" || ok
setp; jvx "$HA" build done; lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && mark && ok || bad "M1 the mutated gate still started IG3's head: jobs $(lgf_jobs 104)"
cp "$LWF_SRC/$GATE" "$H/$GATE"; cmp -s "$LWF_SRC/$GATE" "$H/$GATE" && ok || bad "M1 the gate was not restored"

# ── M2: queued_for_retry not live: IG5b's head gets a job ──
sed -i 's/"queued_for_retry", //' "$H/$GATE"
cmp -s "$LWF_SRC/$GATE" "$H/$GATE" && bad "M2 the mutation changed nothing" || ok
setp; jvx "$HB" build queued_for_retry; lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "M2 the mutated gate still held IG5b's head: $(cat "$L")"
cp "$LWF_SRC/$GATE" "$H/$GATE"; cmp -s "$LWF_SRC/$GATE" "$H/$GATE" && ok || bad "M2 the gate was not restored"

echo "lead-gates-inbuild-ports.bh-8527: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
