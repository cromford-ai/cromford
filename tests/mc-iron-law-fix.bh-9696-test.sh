#!/bin/bash
# tests/mc-iron-law-fix.bh-9696-test.sh — BH-9696 (BH-9427.4, reason
# `iron-law`): the block names the rule and the lines, and a REJECT carries
# that text to the fresh rebuild. Iron-law still never gets a fix round and no
# person is paged on it (BH-9437; plan ASSUMPTIONS A1, A2).
#   §R1 ilr_rules on a fixture diff: one rule word and file:line per hit,
#       the mc_iron_law_lines filters kept, a checks-run.sh CHECK-HIT mapped
#   §R2 ilr_why: every case of the plan's decision rule, exact output
#   §R3 round-trip: the new reason through bin/human-block-report.sh (class
#       iron-law), br_reason_of (iron-law) and mc_resolver_owns (rc 0)
#   §R4 the driver: bash -n, and the two call sites sit in the right order
#   §R5 brlad_ila_hold REJECT: the build note has a RULES: line; a failed diff
#       read or BR_ILA_NOTE_HITS=0 gives no RULES: line; 0 fix rounds, 1 rebuild
#   §R6 the knob rows MC_ILR_MAX and BR_ILA_NOTE_HITS; mc_ilr_max clamps
#   §R7 self-scan: the new product files carry no iron-law literal
#   §R8 the WHOLE bin/merge-conductor.sh on one PR whose diff has a model id:
#       the BLOCKED_HUMAN reason in the hold comment names the rule and line
#   §Z  0 vendor calls (gh, curl, claude, agent-call.sh)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-iron-law-fix.bh-9696-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-iron-law-fix.bh-9696: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/ironlaw-rules.sh"
FRAG="$DIR/bin/merge-conductor.d/bh-9696-ironlaw-rules.sh"
[ -r "$LIB" ] && ok || bad "R0 $LIB is missing"
[ -r "$FRAG" ] && ok || bad "R0 $FRAG is missing"
. "$DIR/tests/lib/br-9437.sh" || exit 1
bl9_tripwire "$T" || exit 1
printf '#!/bin/bash\nprintf "claude %%s\\n" "$*" >> "%s/vendor.txt"\nexit 99\n' "$T" > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
export PATH="$T/fakebin:$PATH"

# fn_of <file> <fn> — one function's source, lifted by its first line.
fn_of() { awk -v f="$2() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$1"; }
fn_of "$DIR/bin/lib/mc/classify.sh" mc_iron_law_lines > "$T/mcl.sh"
fn_of "$DIR/bin/lib/mc/classify.sh" mc_resolver_owns >> "$T/mcl.sh"
fn_of "$DIR/bin/lib/mc/classify.sh" mc_iron_law_scan >> "$T/mcl.sh"
fn_of "$DIR/bin/lib/br/ladder.sh" br_reason_of >> "$T/mcl.sh"
grep -c '() {$' "$T/mcl.sh" | grep -qx 4 && ok || bad "R0 could not lift mc_iron_law_lines, mc_resolver_owns, mc_iron_law_scan and br_reason_of"

# The fixture diff: three hits in src/, three near misses, and one hunk each.
M1="claude-""sonnet-4-5"; V1="VERCEL""_URL"; D1="window.""confirm("
cat > "$T/fx.diff" <<EOF
diff --git a/src/ui.js b/src/ui.js
--- a/src/ui.js
+++ b/src/ui.js
@@ -10,3 +10,4 @@ function a() {
 const x = 1;
 const y = 2;
+if (${D1}"sure?")) go();
 const z = 3;
diff --git a/src/agent.ts b/src/agent.ts
--- a/src/agent.ts
+++ b/src/agent.ts
@@ -1,2 +1,3 @@
 import x from "y";
+const model = "${M1}";
-const old = "${M1}";
 export default x;
diff --git a/web/fetch.ts b/web/fetch.ts
new file mode 100644
--- /dev/null
+++ b/web/fetch.ts
@@ -0,0 +1,3 @@
+// the base is ${V1}, never used
+const a = 1;
+const base = process.env.${V1};
diff --git a/tests/x.test.ts b/tests/x.test.ts
--- a/tests/x.test.ts
+++ b/tests/x.test.ts
@@ -1,1 +1,2 @@
 test("a");
+const m = "${M1}";
EOF

# ── §R1 ilr_rules ─────────────────────────────────────────────────────────
HR1="$T/r1"; mkdir -p "$HR1/bin"
cat > "$HR1/bin/checks-run.sh" <<'EOF'
#!/bin/bash
echo "CHECK-HIT no-raw-sql src/db.ts:7 raw SQL"
echo "checks: 1 hit"
exit 1
EOF
chmod +x "$HR1/bin/checks-run.sh"
out=$( . "$T/mcl.sh"; . "$LIB"; MC_H="$HR1"; ilr_rules "$T/fx.diff" ); rc=$?
want=$(printf '%s\n' "native-dialog src/ui.js:12" "model-id src/agent.ts:2" "vercel-url web/fetch.ts:3" "no-raw-sql src/db.ts:7")
[ "$rc" = 0 ] && ok || bad "R1 ilr_rules rc 0, got $rc"
[ "$out" = "$want" ] && ok || bad "R1 ilr_rules names 4 hits, rule and file:line; got:
$out"
# the window prompt form and a missing checks-run.sh
printf '+++ b/src/p.js\n@@ -0,0 +1,1 @@\n+window.''prompt("x")\n' > "$T/p.diff"
out=$( . "$T/mcl.sh"; . "$LIB"; MC_H="$T/none"; ilr_rules "$T/p.diff" ); rc=$?
[ "$rc" = 0 ] && [ "$out" = "native-dialog src/p.js:1" ] && ok || bad "R1 the prompt form is native-dialog, no checks-run.sh is no error (rc $rc): $out"
# no @@ hunk header (A4): no line numbers, no rules
printf '+++ b/src/agent.ts\n+const model = "%s";\n' "$M1" > "$T/nohunk.diff"
out=$( . "$T/mcl.sh"; . "$LIB"; MC_H="$T/none"; ilr_rules "$T/nohunk.diff" ); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "R1 a diff with no @@ hunk gives no rule (A4), rc $rc: $out"
# no mc_iron_law_lines in scope, and an absent diff: no error, no rule
out=$( . "$LIB"; MC_H="$T/none"; ilr_rules "$T/fx.diff"; ilr_rules "$T/absent.diff" ); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "R1 no scanner and no diff: rc 0, empty (rc $rc): $out"

# ── §R2 ilr_why ───────────────────────────────────────────────────────────
R1L=$'model-id src/a.ts:12'
R12=$(for i in $(seq 1 12); do printf 'model-id src/f%s.ts:%s\n' "$i" "$i"; done)
why() { ( . "$LIB"; ilr_why "$@" ); }
[ "$(why BLOCKED_HUMAN 'iron-law (1 hit(s))' "$R1L" 10)" = "iron-law (1 hit(s)): model-id src/a.ts:12" ] && ok \
  || bad "R2 one rule is named: $(why BLOCKED_HUMAN 'iron-law (1 hit(s))' "$R1L" 10)"
W12="iron-law (12 hit(s)): $(for i in $(seq 1 10); do printf 'model-id src/f%s.ts:%s; ' "$i" "$i"; done)+2 more"
[ "$(why BLOCKED_HUMAN 'iron-law (12 hit(s))' "$R12" 10)" = "$W12" ] && ok \
  || bad "R2 12 rules, max 10: 10 named and +2 more: $(why BLOCKED_HUMAN 'iron-law (12 hit(s))' "$R12" 10)"
[ "$(why BLOCKED_HUMAN 'iron-law (2 hit(s))' "$(printf 'a x:1\nb y:2')" 2)" = "iron-law (2 hit(s)): a x:1; b y:2" ] && ok \
  || bad "R2 exactly max rules: no +0 more"
for c in "READY|iron-law (1 hit(s))|$R1L|10" "BLOCKED_AGENT|iron-law (1 hit(s))|$R1L|10" \
         "BLOCKED_HUMAN|static-guards-red|$R1L|10" "BLOCKED_HUMAN|iron-lawyer (x)|$R1L|10" \
         "BLOCKED_HUMAN|iron-law: 2 file(s) not scanned|$R1L|10" "BLOCKED_HUMAN|iron-law (1 hit(s))||10" \
         "BLOCKED_HUMAN|iron-law (1 hit(s))|$R1L|0" "BLOCKED_HUMAN|iron-law (1 hit(s))|$R1L|x"; do
  IFS='|' read -r s w r m <<<"$c"
  [ "$(why "$s" "$w" "$r" "$m")" = "$w" ] && ok || bad "R2 ($s, $w, rules '${r}', max $m) must not append: $(why "$s" "$w" "$r" "$m")"
done

# ── §R3 round-trip ────────────────────────────────────────────────────────
NEWWHY="iron-law (2 hit(s)): model-id src/agent.ts:2; native-dialog src/ui.js:12"
[ "$( . "$T/mcl.sh"; br_reason_of "$NEWWHY" )" = iron-law ] && ok || bad "R3 br_reason_of reads iron-law from the new reason"
( . "$T/mcl.sh"; mc_resolver_owns "$NEWWHY" ) && ok || bad "R3 mc_resolver_owns owns the new reason (no page)"
HB="$T/hbr"; mkdir -p "$HB/bin" "$HB/logs"
if scratch_install_closure bin/human-block-report.sh "$HB" >/dev/null; then
  cat > "$T/hbr.log" <<EOF
2026-11-11 10:00:00Z example-org/cromford#9696 READY -> BLOCKED_HUMAN head=c0009696 reviewed=c0009696 merge=CLEAN reason=$NEWWHY
2026-11-11 10:30:00Z example-org/cromford#9696 BLOCKED_HUMAN -> READY head=c0009696 reviewed=c0009696 merge=CLEAN reason=clean
EOF
  HARNESS="$HB" bash "$HB/bin/human-block-report.sh" --now 2026-11-12T06:40:00Z --log "$T/hbr.log" > "$T/hbr.out" 2> "$T/hbr.err"; rc=$?
  cls=$(awk -F'\t' 'p && $1 == "TOTAL" { exit } p { print $1 "/" $2 } $1 == "class" { p = 1 }' "$T/hbr.out" | paste -sd' ' -)
  [ "$rc" = 0 ] && [ "$cls" = "iron-law/1" ] && ok || bad "R3 human-block-report: one block of class iron-law (rc $rc, classes '$cls'): $(cat "$T/hbr.err")"
else bad "R3 scratch_install_closure bin/human-block-report.sh"; fi

# ── §R4 the driver ────────────────────────────────────────────────────────
MCS="$DIR/bin/merge-conductor.sh"
bash -n "$MCS" && ok || bad "R4 bash -n bin/merge-conductor.sh"
ln_of() { grep -nF -- "$1" "$MCS" | head -1 | cut -d: -f1; }
L_RULES=$(ln_of 'MC_HIT_RULES=$(ilr_rules "$DF")')
L_RM=$(grep -nE '^ +\[ -n "\$DF" \] && rm -f "\$DF"; DF=""$' "$MCS" | head -1 | cut -d: -f1)
L_CARRY=$(ln_of 'ILC_OUT=$(ilc_covered "$URL" "$SCAN" "$DF")')
L_CLASS=$(ln_of 'IFS=$'"'"'\t'"'"' read -r STATE WHY <<<"$(mc_classify "$PSTATE" "$EFF" "$MGABLE" "$HEAD" "$REVIEWED" "$VERDICT" "$PROV" "$CI" "$REDS" "$TIGHT" "$SCAN"')
L_WHY=$(ln_of 'WHY=$(ilr_why "$STATE" "$WHY"')
if [ -n "$L_RULES" ] && [ -n "$L_RM" ] && [ -n "$L_CARRY" ] && [ -n "$L_CLASS" ] && [ -n "$L_WHY" ]; then
  [ "$L_CARRY" -lt "$L_RULES" ] && [ "$L_RULES" -lt "$L_RM" ] && ok || bad "R4 ilr_rules runs after the carry read ($L_CARRY) and before the rm of the diff ($L_RM), at $L_RULES"
  [ "$L_CLASS" -lt "$L_WHY" ] && [ $((L_WHY - L_CLASS)) -le 2 ] && ok || bad "R4 ilr_why runs right after the final mc_classify read ($L_CLASS), at $L_WHY"
else bad "R4 a call site is missing (rules '$L_RULES', rm '$L_RM', carry '$L_CARRY', classify '$L_CLASS', why '$L_WHY')"; fi

# ── §R5 brlad_ila_hold REJECT ─────────────────────────────────────────────
bl9_extract "$DIR" "$T" br_fix_round br_fix_cap br_cap_key br_rkey br_file br_load br_save br_record br_num \
  br_json_edit br_set_field br_slug_of_url br_pr_field || exit 1
H5="$T/h5"; mkdir -p "$H5/bin/lib" "$H5/state/blocked-resolver/tproj" "$H5/state/build-notes"
cp "$LIB" "$H5/bin/lib/"
HA=$(printf 'a%.0s' {1..40}); URL=https://github.com/o/r/pull/9
cat > "$T/drv.sh" <<EOF
set -u
PATH="$T/fakebin:\$PATH"
H="$H5"; MC_H="$H5"; ST="$H5/state/blocked-resolver"; NOTES="$H5/state/build-notes"; LOG="$T/say.txt"; OBSERVE=0
GH_REST_STATUS=000; GH_REST_REASON=""
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a record stamp; no assertion reads it
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
gh_rest() {
  case "\$*" in
    "GET repos/o/r/pulls/9 -H Accept: application/vnd.github.v3.diff")
       echo read >> "$T/diffreads.txt"; [ -f "$T/diff-fail" ] && return 1; cat "$T/fx.diff"; return 0 ;;
    "GET repos/o/r/pulls/9") jq -nc --arg h "$HA" '{state:"open", head:{sha:\$h}}'; return 0 ;;
  esac
  printf 'unexpected gh_rest %s\n' "\$*" >> "$T/vendor.txt"; return 1
}
br_quiet() { :; }
br_cap_rows() { [ "\$6" = fixround ] && { printf 'FIXROUND\n' >> "$T/fixround.txt"; printf 99; return 0; }; printf '%s' "\$4"; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { :; }
br_rebuild_fresh() { printf '%s\n' "\$*" >> "$T/rebuild.txt"; }
bn_put() { return 0; }
. "$T/mcl.sh"
. "$T/fns.sh"
for f in "$DIR"/bin/blocked-resolver.d/bh-9437-*.sh; do [ -r "\$f" ] && . "\$f"; done
EOF
NOTE="$H5/state/build-notes/tproj/TP-9.md"
R5() { scratch_rm "$H5/state/build-notes/tproj"; rm -f "$T/rebuild.txt" "$T/fixround.txt" "$T/say.txt" "$T/diffreads.txt"
  jq -nc --arg h "$HA" --arg u "$URL" '{project:"tproj",rkey:"o-r-9",adjudications:1,fixrounds:0,outcome:"",attempts:[],ila_ruled:[{head:$h,verdict:"REJECT",url:$u}]}' \
    > "$H5/state/blocked-resolver/tproj/o-r-9.json"
  ( . "$T/drv.sh"; br_fix_round tproj o-r-9 iron-law "$URL" - TP-9 ); }
cnt() { cat "$T/$1.txt" 2>/dev/null | grep -c .; }
R5
grep -q 'REJECTED' "$NOTE" 2>/dev/null && ok || bad "R5 the REJECT note is written: $(cat "$NOTE" 2>/dev/null)"
grep -qx 'RULES: native-dialog src/ui.js:12; model-id src/agent.ts:2; vercel-url web/fetch.ts:3' "$NOTE" 2>/dev/null && ok \
  || bad "R5 the note names the rules and lines: $(cat "$NOTE" 2>/dev/null)"
[ "$(cnt fixround)" = 0 ] && [ "$(cnt rebuild)" = 1 ] && ok || bad "R5 0 fix rounds ($(cnt fixround)), 1 rebuild ($(cnt rebuild))"
[ "$(cnt diffreads)" = 1 ] && ok || bad "R5 one diff read for the RULES line, got $(cnt diffreads)"
BR_ILA_NOTE_HITS=1 R5
grep -qx 'RULES: native-dialog src/ui.js:12; +2 more' "$NOTE" 2>/dev/null && ok || bad "R5 BR_ILA_NOTE_HITS=1 caps the RULES line: $(grep RULES "$NOTE" 2>/dev/null)"
touch "$T/diff-fail"; R5; rm -f "$T/diff-fail"
grep -q 'REJECTED' "$NOTE" 2>/dev/null && ! grep -q '^RULES:' "$NOTE" && ok || bad "R5 a failed diff read: the note is written with no RULES line: $(cat "$NOTE" 2>/dev/null)"
grep -q 'diff could not be read' "$T/say.txt" 2>/dev/null && ok || bad "R5 a failed diff read says one line: $(cat "$T/say.txt")"
[ "$(cnt fixround)" = 0 ] && [ "$(cnt rebuild)" = 1 ] && ok || bad "R5 failed read: 0 fix rounds ($(cnt fixround)), 1 rebuild ($(cnt rebuild))"
BR_ILA_NOTE_HITS=0 R5
grep -q 'REJECTED' "$NOTE" 2>/dev/null && ! grep -q '^RULES:' "$NOTE" && ok || bad "R5 BR_ILA_NOTE_HITS=0: no RULES line: $(cat "$NOTE" 2>/dev/null)"
[ "$(cnt diffreads)" = 0 ] && ok || bad "R5 BR_ILA_NOTE_HITS=0: no diff read, got $(cnt diffreads)"
[ "$(cnt fixround)" = 0 ] && [ "$(cnt rebuild)" = 1 ] && ok || bad "R5 knob 0: 0 fix rounds ($(cnt fixround)), 1 rebuild ($(cnt rebuild))"

# ── §R6 knobs ─────────────────────────────────────────────────────────────
K1="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_ILR_MAX.json"
K2="$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_ILA_NOTE_HITS.json"
[ "$(jq -r '[.env,.type,.default,.min,.max,.zero_means,.read_in] | map(tostring) | join(" ")' "$K1" 2>/dev/null)" = \
  "MC_ILR_MAX int 10 0 50 off bin/merge-conductor.d/bh-9696-ironlaw-rules.sh" ] && ok || bad "R6 the MC_ILR_MAX knob row"
[ "$(jq -r '[.env,.type,.default,.min,.max,.zero_means,.read_in] | map(tostring) | join(" ")' "$K2" 2>/dev/null)" = \
  "BR_ILA_NOTE_HITS int 20 0 100 off bin/blocked-resolver.d/bh-9437-ironlaw-adj.sh" ] && ok || bad "R6 the BR_ILA_NOTE_HITS knob row"
mx() { ( H="$T/none"; . "$FRAG"; MC_ILR_MAX="$1"; mc_ilr_max ) 2>/dev/null; }
[ "$(mx abc)" = 10 ] && [ "$(mx 99)" = 50 ] && [ "$(mx '')" = 10 ] && [ "$(mx 0)" = 0 ] && [ "$(mx 7)" = 7 ] && ok \
  || bad "R6 mc_ilr_max: abc->10 ($(mx abc)), 99->50 ($(mx 99)), ''->10 ($(mx '')), 0->0 ($(mx 0)), 7->7 ($(mx 7))"

# ── §R7 self-scan ─────────────────────────────────────────────────────────
: > "$T/self.diff"
for f in bin/lib/ironlaw-rules.sh bin/merge-conductor.d/bh-9696-ironlaw-rules.sh \
         catalog/lanes.d/merge-conductor.knobs.d/MC_ILR_MAX.json catalog/lanes.d/blocked-resolver.knobs.d/BR_ILA_NOTE_HITS.json; do
  [ -r "$DIR/$f" ] || continue
  printf '+++ b/%s\n' "$f" >> "$T/self.diff"; sed 's/^/+/' "$DIR/$f" >> "$T/self.diff"
done
[ "$( . "$T/mcl.sh"; MC_H="$T/none"; mc_iron_law_scan "$T/self.diff" )" = 0 ] && ok || bad "R7 the new product files carry an iron-law literal (the PR would park itself)"

# ── §R8 the whole conductor ───────────────────────────────────────────────
# The conductor's own closure (scratch_install_closure), with the stub gh of
# tests/conductor-hold-comment-sites.bh-3456-test.sh Part 2: one CLEAN, green,
# reviewed PR whose diff adds a model id at src/agent.ts:2; the hold comment's
# reason is the trace.
SLUG=example-org/mgfy-os
H1=$(printf 'a%.0s' $(seq 40)); U="https://github.com/$SLUG/pull"; TR="$T/trace"
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
CH="$T/ch"; FX="$T/cfx"
mkdir -p "$CH/bin/lib/mc" "$CH/bin/lib/jobs" "$CH/bin/merge-conductor.d" "$CH/logs" "$CH/state" "$CH/flags" "$CH/locks" "$CH/builds" "$CH/env" "$FX"
scratch_install_closure bin/merge-conductor.sh "$CH" >/dev/null || bad "R8 scratch_install_closure bin/merge-conductor.sh"
# The driver sources merge-conductor.d/*.sh by glob, which the closure does
# not follow: this ticket's fragment is installed as its own closure (it pulls
# bin/lib/ironlaw-rules.sh in), and no other fragment is in the tree.
scratch_install_closure bin/merge-conductor.d/bh-9696-ironlaw-rules.sh "$CH" >/dev/null || bad "R8 scratch_install_closure of the fragment"
scratch_install_closure bin/jobs-client.sh "$CH" >/dev/null || bad "R8 scratch_install_closure bin/jobs-client.sh"
cp "$DIR/bin/fleet-conf.sh" "$CH/bin/" || bad "R8 cp bin/fleet-conf.sh"
# As in tests/mc-sat-fresh-handoff.bh-9467-test.sh: no PR snapshot, no limit logger.
: > "$CH/bin/lib/pr-snapshot.sh"; scratch_rm "$CH/bin/lib/gh-limit-logger.sh"
[ -r "$CH/bin/lib/ironlaw-rules.sh" ] && [ -r "$CH/bin/merge-conductor.d/bh-9696-ironlaw-rules.sh" ] && ok \
  || bad "R8 the conductor's closure carries the fragment and bin/lib/ironlaw-rules.sh"
printf 'to_lane_hold() { return 1; }\nto_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }\n' > "$CH/bin/lib/ticket-ownership.sh"
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
REC="$CH/builds/pool-mgfy-MG-31-202609120001"; mkdir -p "$REC"
echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$T/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo tok-fixture ;;
  *"pr diff"*) cat "$FX/diff" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-09-29T10:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*) : ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) restpr --diff "\$(cat "$FX/diff")" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "$H1" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
tick() {
  : > "$TR"; : > "$CH/logs/merge-conductor.log"; scratch_rm "$CH/state/merge-conductor"
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$CH" FLEET_CONF="$CH/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN="" \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_HOLD_COMMENT_TRACE="$TR" "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }
}
printf 'diff --git a/src/agent.ts b/src/agent.ts\n--- a/src/agent.ts\n+++ b/src/agent.ts\n@@ -1,2 +1,3 @@\n import x from "y";\n+const model = "%s";\n export default x;\n' "$M1" > "$FX/diff"
tick
grep -q "^$SLUG#31	$H1	iron-law	iron-law (1 hit(s)): model-id src/agent.ts:2\$" "$TR" && ok \
  || bad "R8 the conductor's park names the rule and line (trace: $(cat "$TR"); log: $(grep '#31' "$CH/logs/merge-conductor.log" | tail -3); stderr: $(tail -5 "$T/tick.err"); log tail: $(tail -5 "$CH/logs/merge-conductor.log"))"
grep -q "BLOCKED_HUMAN.*reason=iron-law (1 hit(s)): model-id src/agent.ts:2" "$CH/logs/merge-conductor.log" && ok \
  || bad "R8 the transition line carries the named reason (log: $(grep '#31' "$CH/logs/merge-conductor.log" | tail -3))"
tick MC_ILR_MAX=0
grep -q "	iron-law	iron-law (1 hit(s))\$" "$TR" && ok || bad "R8 MC_ILR_MAX=0 keeps the bare reason (trace: $(cat "$TR"))"

# ── §Z vendor tripwire ────────────────────────────────────────────────────
[ "$(bl9_vendor_calls "$T")" = 0 ] && ok || bad "Z vendor calls: $(cat "$T/vendor.txt")"

echo "mc-iron-law-fix.bh-9696: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
