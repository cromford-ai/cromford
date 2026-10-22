#!/bin/bash
# tests/risk-tier-replay.bh-7041-test.sh — BH-7041: bin/risk-tier-replay.sh,
# the read-only replay of past verdict heads through rt_classify and
# rt_low_small. It runs WHOLE from a scratch harness with its real bin closure.
# Stubbed: curl (a jobs worker: settings 404 = no row, the protected-path rows
# of tests/lib/lpp-stub.sh) and gh (logs every call; a compare answers 500).
# Offline: every compare it needs is in --compare-dir, except in R3. R4 pins
# parity with the first build's tool (38f2d90f) on an 18-head fixture set.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/risk-tier-replay.bh-7041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cmp" "$T/set"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure of bin/jobs-client.sh"
scratch_install_closure bin/risk-tier-replay.sh "$H" >/dev/null || { bad "closure of bin/risk-tier-replay.sh"; }
[ -x "$H/bin/risk-tier-replay.sh" ] && ok || bad "bin/risk-tier-replay.sh is not in the scratch harness"
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
lpp_set "$LPPF" example-org/cromford 'bin/guarded.sh'

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s\n' "\$m" "\$p" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  POST*) code=500; out='{"error":"the replay must not write"}'; echo "\$m \$p" >> "$T/log/writes" ;;
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
  *) printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" GH_ETAG=0

# cmpo <head> <json array of {f, a, d, s?, p?}>
cmpo() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[],
    files:[$f[] | {filename:.f, additions:.a, deletions:.d, status:(.s // "modified")} + (if has("p") then {patch:.p} else {} end)]}' > "$T/cmp/$1.json"
}
HA=$(printf 'a%.0s' {1..40}); HB=$(printf 'b%.0s' {1..40}); HC=$(printf 'c%.0s' {1..40}); HD=$(printf 'd%.0s' {1..40})
cmpo "$HA" '[{"f":"bin/foo.sh","a":150,"d":30},{"f":".harness/specs/BH-1/plan.md","a":200,"d":0,"s":"added"}]'
cmpo "$HB" '[{"f":"bin/bar.sh","a":90,"d":10}]'
cmpo "$HC" '[{"f":".mergify.yml","a":2,"d":1}]'
R=example-org/cromford
printf '%s\t41\t%s\tMERGE\n%s\t42\t%s\tBLOCK\tmain\n%s\t43\t%s\tBLOCK\n' "$R" "$HA" "$R" "$HB" "$R" "$HC" > "$T/heads.tsv"
run() { "$H/bin/risk-tier-replay.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }

# ── R1: three heads, all in the compare dir ──
run "$T/heads.tsv" --compare-dir "$T/cmp"
[ "$RC" = 0 ] && ok || bad "R1 rc $RC: $(cat "$T/err")"
grep -q "^$R#41	${HA:0:12}	MERGE	medium	yes	180 code lines" "$T/out" && ok || bad "R1 row 41: $(grep '#41' "$T/out")"
grep -q "^$R#42	${HB:0:12}	BLOCK	medium	yes	" "$T/out" && ok || bad "R1 row 42: $(grep '#42' "$T/out")"
grep -q "^$R#43	${HC:0:12}	BLOCK	high	n/a	" "$T/out" && ok || bad "R1 row 43: $(grep '#43' "$T/out")"
SUM=$(grep '^replay: ' "$T/out")
[ "$SUM" = "replay: heads=3 low_before=0 low_small=2 blocks=2 blocks_low_small=1 unreadable=0" ] && ok || bad "R1 summary: '$SUM'"
[ "$(grep -c '^BLOCK low-small: ' "$T/out")" = 1 ] && grep -q "^BLOCK low-small: $R#42 @${HB:0:12} " "$T/out" && ok || bad "R1 BLOCK lines: $(grep '^BLOCK' "$T/out")"

# ── R2: no GitHub call when every compare is in the dir, and nothing written ──
[ -s "$T/log/gh" ] && grep -qv 'rate_limit' "$T/log/gh" && bad "R2 gh was called: $(cat "$T/log/gh")" || ok
[ -s "$T/log/writes" ] && bad "R2 the replay wrote to the worker: $(cat "$T/log/writes")" || ok

# ── R3: a missing compare with GitHub failing is unreadable, never low-small ──
printf '%s\t44\t%s\tBLOCK\tmain\n' "$R" "$HD" >> "$T/heads.tsv"
run "$T/heads.tsv" --compare-dir "$T/cmp"
[ "$RC" = 0 ] && ok || bad "R3 rc $RC: $(cat "$T/err")"
grep -q "compare/main...$HD" "$T/log/gh" 2>/dev/null && ok || bad "R3 the missing compare was not asked of GitHub: $(cat "$T/log/gh" 2>/dev/null)"
grep -q "^$R#44	${HD:0:12}	BLOCK	unreadable	no	" "$T/out" && ok || bad "R3 row 44: $(grep '#44' "$T/out")"
SUM=$(grep '^replay: ' "$T/out")
[ "$SUM" = "replay: heads=4 low_before=0 low_small=2 blocks=3 blocks_low_small=1 unreadable=1" ] && ok || bad "R3 summary: '$SUM'"
[ -f "$T/cmp/$HD.json" ] && bad "R3 a failed read was saved to the compare dir" || ok
# ...a malformed input line is rc 2
printf 'not a heads line\n' > "$T/bad.tsv"
run "$T/bad.tsv" --compare-dir "$T/cmp"
[ "$RC" = 2 ] && ok || bad "R3 a malformed line: rc $RC"
run --help; [ "$RC" = 0 ] && grep -q 'risk-tier-replay.sh <heads.tsv>' "$T/out" && ok || bad "--help: rc $RC $(cat "$T/out")"

# ── R4: parity with the first build (38f2d90f, the tool the operator replayed on the
# hub): the same fixture set gives the same tier and low-small answer per head.
# EXPECT4 was copied from the 38f2d90f tool's output over these fixtures.
P4="$T/cmp4"; mkdir -p "$P4"
c4() { jq -nc --argjson f "$2" '{total_commits:1, commits:[],
    files:[$f[] | {filename:.f, additions:.a, deletions:.d, status:(.s // "modified")} + (if has("p") then {patch:.p} else {} end)]}' > "$P4/$1.json"; }
h4() { printf '%040x' "$1"; }
SPEC='{"f":".harness/specs/BH-1/plan.md","a":200,"d":0,"s":"added"}'
c4 "$(h4 1)" "[{\"f\":\"bin/foo.sh\",\"a\":150,\"d\":30},$SPEC]"
c4 "$(h4 2)" '[{"f":"bin/a.sh","a":100,"d":0},{"f":"bin/b.sh","a":100,"d":0},{"f":"bin/c.sh","a":40,"d":9}]'
c4 "$(h4 3)" '[{"f":"bin/a.sh","a":100,"d":0},{"f":"bin/b.sh","a":100,"d":0},{"f":"bin/c.sh","a":40,"d":10}]'
c4 "$(h4 4)" '[{"f":"bin/a.sh","a":10,"d":0},{"f":"tests/a-test.sh","a":0,"d":1,"p":"@@ -1,2 +1,1 @@\n x=1\n-ok \"x\""}]'
c4 "$(h4 5)" '[{"f":"tests/a-test.sh","a":1,"d":1,"p":"@@ -1 +1 @@\n-eq \"x\" \"$a\" medium\n+eq \"x\" \"$a\" low"}]'
c4 "$(h4 6)" '[{"f":"tests/a-test.sh","a":2,"d":1,"p":"@@ -1,2 +1,3 @@\n x=1\n-# old comment\n+# new comment\n+y=2"}]'
c4 "$(h4 7)" '[{"f":"tests/a-test.sh","a":1,"d":0,"p":"@@ -1 +1,2 @@\n x=1\n+exit 0"}]'
c4 "$(h4 8)" '[{"f":"tests/a-test.sh","a":1,"d":0,"p":"@@ -1 +1,2 @@\n x=1\n+  skip \"slow\""}]'
c4 "$(h4 9)" '[{"f":"tests/a-test.sh","a":0,"d":10,"s":"removed","p":"@@ -1,10 +0,0 @@\n-x"}]'
c4 "$(h4 10)" '[{"f":"tests/lib/scratch.sh","a":2,"d":0,"p":"@@ -1 +1,3 @@\n x\n+y\n+z"}]'
c4 "$(h4 11)" '[{"f":"catalog/lanes.d/x.json","a":3,"d":0}]'
c4 "$(h4 12)" '[{"f":"bin/guarded.sh","a":3,"d":0}]'
c4 "$(h4 13)" "[$SPEC]"
c4 "$(h4 14)" '[{"f":"tests/new-test.sh","a":40,"d":0,"s":"added"},{"f":"bin/foo.sh","a":100,"d":0}]'
c4 "$(h4 15)" '[{"f":"docs/a.md","a":5,"d":0}]'
c4 "$(h4 16)" '[{"f":"rules/topics/05-x.md","a":3,"d":0}]'
c4 "$(h4 17)" '[{"f":"bin/a.sh","a":700,"d":0}]'
c4 "$(h4 18)" '[{"f":"cron/hub.cron","a":1,"d":0}]'
: > "$T/heads4.tsv"
for i in $(seq 1 18); do printf '%s\t%s\t%s\tMERGE\tmain\n' "$R" "$((500 + i))" "$(h4 "$i")" >> "$T/heads4.tsv"; done
EXPECT4='501 medium yes
502 medium yes
503 medium no
504 medium no
505 medium no
506 medium yes
507 medium no
508 medium no
509 medium no
510 medium no
511 medium no
512 high n/a
513 medium no
514 medium yes
515 low n/a
516 medium no
517 high n/a
518 medium no'
rm -f "$T/log/gh"
run "$T/heads4.tsv" --compare-dir "$P4"
[ "$RC" = 0 ] && ok || bad "R4 rc $RC: $(cat "$T/err")"
GOT4=$(awk -F'\t' '/^example-org\/cromford#/ {sub(/.*#/, "", $1); print $1, $4, $5}' "$T/out")
[ "$GOT4" = "$EXPECT4" ] && ok || bad "R4 parity with 38f2d90f: got
$GOT4"
[ "$(grep '^replay: ' "$T/out")" = "replay: heads=18 low_before=1 low_small=4 blocks=0 blocks_low_small=0 unreadable=0" ] && ok || bad "R4 summary: $(grep '^replay: ' "$T/out")"
[ -s "$T/log/gh" ] && grep -qv 'rate_limit' "$T/log/gh" && bad "R4 gh was called: $(cat "$T/log/gh")" || ok

echo "risk-tier-replay.bh-7041: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
