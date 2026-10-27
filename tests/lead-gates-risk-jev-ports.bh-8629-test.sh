#!/bin/bash
# tests/lead-gates-risk-jev-ports.bh-8629-test.sh — the rules-text and JEV
# halves of the risk gate (bin/lib/lead-gates.d/60-risk.sh) on the worklist.
# Every case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh plus
# tests/lib/lead-gates-fixture.bh-5875.sh), with the risk tier on enforce.
#   RJ1 a lead-authored rules-text low with no builder APPROVE: signed off as
#       risk-tier:rules-text:box-demo, no job, no refusal line.
#   RJ2 a lead-authored rules-text + bin head: the lead skip line, `lead` in
#       risk.tsv, a job, no post; a second tick on the head reuses the risk.tsv
#       line (no second compare read) and logs the skip line again.
#   RJ3 a non-lead rules-text low with no builder APPROVE: the "no reviewer
#       approved this head" refusal, no post, a job.
#   RJ4 a medium and a high head: Jev on (answering the opposite tier) leaves
#       the same record as Jev off.
#   RJ5 a Jev that hangs past jev_risk.timeout_s: the tick ends inside the
#       gate's timeout bound, `jev shadow no answer`, the same record.
#   RJ6 only `shadow` (trimmed, any case) asks Jev; a 500 on the row does not
#       ask and the tick goes on.
#   RJ7 mode `off` or no row: no ask, and no max_per_tick or timeout_s read.
#   RJ8 no fixture secret in the worklist log or the Jev log.
#   M1-M3 the exemption, its author half and the risk.tsv reuse, each broken
#       once in the scratch copy of the gate: RJ1, RJ3 and RJ2 go red (D1).
# The Jev client is a stub bin/jev-risk.sh: the real client and its ledger are
# pinned by tests/jev-risk-shadow.bh-5024-test.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-risk-jev-ports.bh-8629-test.sh
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
GD="$H/bin/lib/lead-gates.d"
SRC="$LWF_SRC"
for f in "$SRC/bin/lib/lead-gates.d/60-risk.sh" "$SRC/bin/lib/risk-tier.sh" "$SRC/bin/lib/rules-render-head.sh" "$SRC/bin/lib/ticket-ownership.sh"; do
  [ -r "$H/${f#"$SRC"/}" ] && ok || bad "setup: the closure did not install ${f#"$SRC"/}"
done
RISKF="$H/state/lead-review-enqueue/risk.tsv"
RULESF='[["rules/topics/12-x.md","added",12,0,"@@ -0,0 +1 @@\n+rule"],["rules/CLAUDE.md","modified",8,0,"@@ -1 +1 @@\n+rule"]]'
RULESBINF='[["rules/topics/12-x.md","added",12,0,"@@ -0,0 +1 @@\n+rule"],["rules/CLAUDE.md","modified",8,0,"@@ -1 +1 @@\n+rule"],["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
HIGHF='[[".mergify.yml","modified",2,1,"@@ -1 +1 @@\n+x: 1"]]'
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
# A real rules-text head, so rrh_check's fetch and archive run on it.
mkdir -p "$W/rules/topics"; echo rule > "$W/rules/topics/12-x.md"; echo rule > "$W/rules/CLAUDE.md"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm rules
HR=$(git -C "$W" rev-parse HEAD); R12=${HR:0:12}
git -C "$W" push -q "$O" "HEAD:refs/pull/151/head" "HEAD:refs/pull/153/head"
# The Jev client: argv to $T/log/jev; sleeps $FX/jev.sleep; answers the tier in $FX/jev.tier.
cat > "$H/bin/jev-risk.sh" <<EOF
#!/bin/bash
printf '%s|%s\n' "\$JEV_CALLER" "\$*" >> "$T/log/jev"
[ -r "$FX/jev.sleep" ] && sleep "\$(cat "$FX/jev.sleep")"
printf 'ok\t%s\t0.99\t-\tfixture\n' "\$(cat "$FX/jev.tier" 2>/dev/null || echo low)"
EOF
chmod +x "$H/bin/jev-risk.sh"
# Every tick's worklist log and Jev log, for RJ8 (lwf_reset clears both).
ALL_L="$T/all.log"; ALL_J="$T/all.jev"; : > "$ALL_L"; : > "$ALL_J"
tick() { lwf_tick; cat "$L" >> "$ALL_L" 2>/dev/null; cat "$T/log/jev" >> "$ALL_J" 2>/dev/null; return 0; }
asks() { lwf_cnt . "$T/log/jev"; }
jlines() { lwf_cnt 'jev shadow' "$L"; }
refusal() { lwf_cnt "#$1 @$2: risk tier low, but no reviewer approved this head" "$L"; }
skipline() { lwf_cnt "#$1 @$2: risk tier skipped (lead-authored (lead-bot): a risk-tier row never clears a lead PR); reviewed as before" "$L"; }
col() { awk -F'\t' -v h="$1" -v c="$2" '$4 == h {print $c}' "$RISKF" 2>/dev/null | tail -1; }
# one <pr> <head> <files json> [author]: one enforce worklist head, no builder APPROVE when an author is given
one() {
  lgf_reset enforce; lgf_needs "$1:$2"; lgf_cmp "$2" "$3"
  [ -n "${4:-}" ] && echo "$4" > "$FX/author.$1"
  printf 'lead-token-fixture-8629\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
  return 0
}
# record <file> <pr> <head>: what the verdict path did with the head
record() {
  { echo "== lv"; cat "$T/log/lv" 2>/dev/null
    echo "== jobs $(lgf_jobs "$2")"
    echo "== risk-tiers"; sed -n 's#^POST /api/risk-tiers ##p' "$T/log/worker" | jq -c '[.tier,.action,.mode]'
    echo "== risk.tsv $(col "$3" 5) $(col "$3" 8)"; } > "$1"
}

H2=$(printf '%040d' 152); C12=${H2:0:12}
rj1() { one 151 "$HR" "$RULESF" lead-bot; rm -f "$FX/jv.approve"; tick; }
rj2() { one 152 "$H2" "$RULESBINF" lead-bot; tick; }
rj3() { one 153 "$HR" "$RULESF"; rm -f "$FX/jv.approve"; tick; }
# rj2_again: the head is new to the worklist again, the gate state stays
rj2_again() {
  rm -f "$L"; scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; scratch_rm "$T/run"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/lead-review"
  rm -f "$FX"/start.152.*
  tick
}

# ── RJ1: a lead-authored rules-text low, no builder APPROVE: signed as rules-text ──
rj1
grep -q "^post example-org/cromford 151 $HR MERGE --source risk-tier --reviewer risk-tier:rules-text:box-demo --note low risk: rules-text:" "$T/log/lv" \
  && ok || bad "RJ1 lead-verdict argv: $(cat "$T/log/lv" 2>/dev/null) :: $(cat "$L")"
[ "$(lgf_jobs 151)" = 0 ] && ok || bad "RJ1 a lead_review job for 151"
[ "$(refusal 151 "$R12")" = 0 ] && ok || bad "RJ1 the refusal line: $(cat "$L")"
[ "$(lwf_cnt "#151 @$R12: risk tier skipped" "$L")" = 0 ] && ok || bad "RJ1 a skip line: $(cat "$L")"

# ── RJ2: a lead-authored rules-text + bin head: skipped, `lead`, reviewed; a second tick reuses risk.tsv ──
rj2
[ "$(skipline 152 "$C12")" = 1 ] && ok || bad "RJ2 skip lines=$(skipline 152 "$C12"): $(cat "$L")"
[ "$(lgf_lv)" = 0 ] && ok || bad "RJ2 a lead-verdict call: $(cat "$T/log/lv")"
[ "$(lgf_rt_posts)" = 0 ] && ok || bad "RJ2 a risk-tiers POST for a lead PR"
[ "$(col "$H2" 5)" = lead ] && ok || bad "RJ2 risk.tsv: $(cat "$RISKF" 2>/dev/null)"
[ "$(lgf_jobs 152)" = 1 ] && ok || bad "RJ2 lead_review jobs=$(lgf_jobs 152): $(cat "$L")"
# Gate 15 reads the compare itself on every tick; gates 30 and 60 share one
# lgc_compare read. So tick 1 reads it twice, and tick 2 only once (gate 15)
# when gate 60 reuses its risk.tsv line (M3 is the same tick without the reuse).
[ "$(lgf_cmp_reads "$H2")" = 2 ] && ok || bad "RJ2 compare reads=$(lgf_cmp_reads "$H2")"
rj2_again
[ "$(skipline 152 "$C12")" = 1 ] && ok || bad "RJ2 second tick skip lines=$(skipline 152 "$C12"): $(cat "$L")"
[ "$(lgf_cmp_reads "$H2")" = 3 ] && ok || bad "RJ2 the second tick read the compare again: reads=$(lgf_cmp_reads "$H2") (want 3)"
[ "$(lgf_lv)" = 0 ] && [ "$(lgf_rt_posts)" = 0 ] && ok || bad "RJ2 the second tick posted: lv=$(lgf_lv) risk-tiers=$(lgf_rt_posts)"
[ "$(awk -F'\t' -v h="$H2" '$4 == h' "$RISKF" | wc -l | tr -d ' ')" = 1 ] && ok || bad "RJ2 risk.tsv lines: $(cat "$RISKF")"

# ── RJ3: a non-lead rules-text low, no builder APPROVE: refused, reviewed ──
rj3
[ "$(lgf_lv)" = 0 ] && ok || bad "RJ3 a lead-verdict call: $(cat "$T/log/lv")"
[ "$(lgf_jobs 153)" = 1 ] && ok || bad "RJ3 lead_review jobs=$(lgf_jobs 153): $(cat "$L")"
[ "$(refusal 153 "$R12")" = 1 ] && ok || bad "RJ3 refusal lines=$(refusal 153 "$R12"): $(cat "$L")"
case "$(col "$HR" 6)" in rules-text:*) ok ;; *) bad "RJ3 risk.tsv column 6 is not a rules-text low: $(cat "$RISKF" 2>/dev/null)" ;; esac

# ── RJ4: a medium and a high head: Jev answering the opposite tier changes nothing ──
for s in 154:medium 155:high; do
  n=${s%%:*}; t=${s#*:}; h=$(printf '%040d' "$n")
  files=$MEDF; [ "$t" = high ] && files=$HIGHF
  one "$n" "$h" "$files"; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"; tick
  [ "$(asks)" = 0 ] && ok || bad "RJ4 $t: no mode row asked Jev ($(asks))"
  record "$T/rec-off" "$n" "$h"
  one "$n" "$h" "$files"; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
  echo shadow > "$FX/settings/jev_risk.mode"; echo low > "$FX/jev.tier"; tick
  [ "$(asks)" = 1 ] && ok || bad "RJ4 $t: shadow asks=$(asks), so the comparison proves nothing"
  grep -qF "#$n @${h:0:12}: jev shadow ok low 0.99 fixture (rule tier $t); shadow only, nothing changed" "$L" && ok || bad "RJ4 $t: jev line: $(cat "$L")"
  record "$T/rec-on" "$n" "$h"
  cmp -s "$T/rec-off" "$T/rec-on" && ok || bad "RJ4 $t: Jev answering low changed the record: $(diff "$T/rec-off" "$T/rec-on")"
  grep -qx '== jobs 1' "$T/rec-on" && ok || bad "RJ4 $t: record: $(cat "$T/rec-on")"
  grep -qx "== risk.tsv $t -" "$T/rec-on" && ok || bad "RJ4 $t: risk.tsv in the record: $(cat "$T/rec-on")"
done

# ── RJ5: a Jev that hangs: the tick is bounded, the outcome is the same ──
H6=$(printf '%040d' 156)
one 156 "$H6" "$LOWF"; tick; record "$T/rec-off" 156 "$H6"
one 156 "$H6" "$LOWF"; echo shadow > "$FX/settings/jev_risk.mode"; echo 1 > "$FX/settings/jev_risk.timeout_s"
echo 30 > "$FX/jev.sleep"; echo high > "$FX/jev.tier"
T0=$(date +%s); tick; T1=$(date +%s)   # determinism: ok — RJ5 measures the tick's wall time against the gate's timeout bound
record "$T/rec-on" 156 "$H6"
[ $((T1 - T0)) -lt 25 ] && ok || bad "RJ5 a hanging Jev held the tick $((T1 - T0))s"
[ "$(asks)" = 1 ] && ok || bad "RJ5 Jev asks=$(asks)"
grep -qF "#156 @${H6:0:12}: jev shadow no answer (rule tier low); shadow only, nothing changed" "$L" && ok || bad "RJ5 jev line: $(cat "$L")"
cmp -s "$T/rec-off" "$T/rec-on" && ok || bad "RJ5 a hanging Jev changed the record: $(diff "$T/rec-off" "$T/rec-on")"
[ "$(lgf_signed 156)" = 1 ] && ok || bad "RJ5 the head was not signed off: $(cat "$T/log/lv" 2>/dev/null)"

# ── RJ6: only `shadow`, trimmed and in any case, asks Jev ──
H7=$(printf '%040d' 157)
rj6() { one 157 "$H7" "$MEDF"; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"; printf '%s' "$1" > "$FX/settings/jev_risk.mode"; tick; }
rj6 'Shadow '
[ "$(asks)" = 1 ] && ok || bad "RJ6 'Shadow ' asks=$(asks)"
[ "$(jlines)" = 1 ] && ok || bad "RJ6 'Shadow ' jev lines=$(jlines)"
# the control for RJ7: a mode that is on reads both rows
[ "$(lwf_cnt '^GET /api/settings/jev_risk.max_per_tick ' "$T/log/worker")" = 1 ] && [ "$(lwf_cnt '^GET /api/settings/jev_risk.timeout_s ' "$T/log/worker")" = 1 ] \
  && ok || bad "RJ6 'Shadow ' did not read max_per_tick and timeout_s: $(grep jev_risk "$T/log/worker")"
for v in on enforce 1 true ''; do
  rj6 "$v"
  [ "$(asks)" = 0 ] && [ "$(jlines)" = 0 ] && ok || bad "RJ6 mode '$v': asks=$(asks) jev lines=$(jlines)"
done
rj6 FAIL
[ "$(asks)" = 0 ] && [ "$(jlines)" = 0 ] && ok || bad "RJ6 a 500 on the mode row: asks=$(asks) jev lines=$(jlines)"
[ "$(lgf_jobs 157)" = 1 ] && ok || bad "RJ6 a 500 on the mode row broke the tick: jobs=$(lgf_jobs 157) $(cat "$L")"

# ── RJ7: mode off or no row: no ask, and the cap and timeout rows are not read ──
H8=$(printf '%040d' 158)
for v in off -; do
  one 158 "$H8" "$MEDF"; printf 0 > "$FX/settings/risk_tier.inbuild_grace_s"
  [ "$v" = off ] && printf off > "$FX/settings/jev_risk.mode"
  echo 2 > "$FX/settings/jev_risk.max_per_tick"; echo 5 > "$FX/settings/jev_risk.timeout_s"
  tick
  [ "$(asks)" = 0 ] && [ "$(jlines)" = 0 ] && ok || bad "RJ7 mode $v: asks=$(asks) jev lines=$(jlines)"
  grep -q '^GET /api/settings/jev_risk.mode ' "$T/log/worker" && ok || bad "RJ7 mode $v: the mode row was not read, so the check below proves nothing"
  grep -q '^GET /api/settings/jev_risk\.\(max_per_tick\|timeout_s\) ' "$T/log/worker" \
    && bad "RJ7 mode $v read the cap or timeout row: $(grep jev_risk "$T/log/worker")" || ok
  [ "$(lgf_jobs 158)" = 1 ] && ok || bad "RJ7 mode $v: jobs=$(lgf_jobs 158)"
done

# ── RJ8: no fixture secret in the worklist log or the Jev log ──
[ -s "$ALL_L" ] && [ -s "$ALL_J" ] && ok || bad "RJ8 the logs are empty, so the check proves nothing"
grep -qF "$HARNESS_SECRET" "$ALL_L" "$ALL_J" && bad "RJ8 HARNESS_SECRET reached a log" || ok
grep -qF "lead-token-fixture-8629" "$ALL_L" "$ALL_J" && bad "RJ8 the lead token reached a log" || ok

# ── M1: the exemption gone: the RJ1 head is refused ──
mv "$GD/60-risk.sh" "$T/60-risk.keep"
sed 's/&& { \[ "\$rtxt" = 0 \] || \[ "\$_LGR_RLAUTH" != 1 \]; }; then/\&\& true; then/' "$T/60-risk.keep" > "$GD/60-risk.sh"
grep -q '&& true; then' "$GD/60-risk.sh" && ok || bad "M1 the mutation did not apply"
rj1
[ "$(lgf_lv)" = 0 ] && ok || bad "M1 lead-verdict calls=$(lgf_lv) with the exemption gone (want 0: RJ1 does not pin it)"
[ "$(refusal 151 "$R12")" = 1 ] && ok || bad "M1 no refusal line: $(cat "$L")"
mv "$T/60-risk.keep" "$GD/60-risk.sh"
cmp -s "$SRC/bin/lib/lead-gates.d/60-risk.sh" "$GD/60-risk.sh" && ok || bad "M1 restore"

# ── M2: the author half gone: the RJ3 head is signed ──
mv "$GD/60-risk.sh" "$T/60-risk.keep"
sed 's/|| \[ "\$_LGR_RLAUTH" != 1 \]; }; then/|| false; }; then/' "$T/60-risk.keep" > "$GD/60-risk.sh"
grep -q '|| false; }; then' "$GD/60-risk.sh" && ok || bad "M2 the mutation did not apply"
rj3
[ "$(lgf_lv)" = 1 ] && ok || bad "M2 lead-verdict calls=$(lgf_lv) with the author half gone (want 1: RJ3 does not pin it)"
mv "$T/60-risk.keep" "$GD/60-risk.sh"
cmp -s "$SRC/bin/lib/lead-gates.d/60-risk.sh" "$GD/60-risk.sh" && ok || bad "M2 restore"

# ── M3: the risk.tsv read never matches: the RJ2 second tick reads the compare again ──
mv "$GD/60-risk.sh" "$T/60-risk.keep"
sed 's/&& \$7 == g {/\&\& $7 == "no-such-sig" {/' "$T/60-risk.keep" > "$GD/60-risk.sh"
grep -q '\$7 == "no-such-sig"' "$GD/60-risk.sh" && ok || bad "M3 the mutation did not apply"
rj2; rj2_again
[ "$(lgf_cmp_reads "$H2")" = 4 ] && ok || bad "M3 compare reads=$(lgf_cmp_reads "$H2") with the reuse gone (want 4: RJ2 does not pin it)"
mv "$T/60-risk.keep" "$GD/60-risk.sh"
cmp -s "$SRC/bin/lib/lead-gates.d/60-risk.sh" "$GD/60-risk.sh" && ok || bad "M3 restore"

echo "lead-gates-risk-jev-ports.bh-8629: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
