#!/bin/bash
# tests/risk-tier-evidence.bh-6968-test.sh — BH-6968 (BH-6544.2): rule 2c of
# "$DIR/bin/lib/risk-tier.sh", a head that is low by EVIDENCE and not only by
# path, and the two writers of that evidence.
#   E1-E4, N1-N13  rt_classify with RT_EVIDENCE_* from rt_evidence_load, the
#                  lib sourced as it is (real lead-authority and queue-risk libs
#                  beside it). setting_get, gh_rest and pr_attempt_count are
#                  stubs; the protected-path rows are tests/lib/lpp-stub.sh.
#   L1-L9          rt_evidence_load: which RT_EVIDENCE_* it sets on each input.
#   G1-G4          HARNESS_IMPACT_GATE_RUN (bin/lib/rb/gates.sh, extracted)
#                  writes HARNESS_HEAD; bin/evidence-summary.sh turns it into
#                  the builder-gate marker that rt_evidence_load reads back.
#   E5, W1, W2     bin/lead-review-enqueue.sh tick, run WHOLE on a scratch
#                  harness (the tests/lead-review-enqueue-risk.bh-5022-test.sh
#                  stubs): risk.tsv column 8 names the rule.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/risk-tier-evidence.bh-6968-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SHA=$(printf 'a%.0s' {1..40})
OLD=$(printf 'c%.0s' {1..40})

# ════════════════ part 1: the lib, sourced ════════════════
mkdir -p "$T/set" "$T/cmp" "$T/tmp" "$T/log" "$T/pac"
export TMPDIR="$T/tmp"
unset HARNESS H MC_TICK_ID MC_TICK_DIR
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_set "$LPPF" example-org/demo-os 'bin/guarded.sh'
_jobs_req() { lpp_jobs_req "$LPPF" "$DOWNF" "$@"; }
setting_get() {
  [ -e "$T/set/$1.rc1" ] && return 1
  [ -f "$T/set/$1" ] || return 2
  cat "$T/set/$1"
}
# gh_rest GET repos/<slug>/commits/<head>/status — $T/status.json, or a 404.
# Like the real helper, it sets GH_REST_STATUS in the CALLING shell.
gh_rest() {
  printf '%s\n' "$*" >> "$T/log/ghrest"
  [ -e "$T/status.down" ] && { GH_REST_STATUS=503; return 75; }
  [ -f "$T/status.json" ] || return 44
  cat "$T/status.json"
}
# pr_attempt_count <repo> <n> <kind> — $T/pac/<kind>, else a measured 0 (rc 2).
pr_attempt_count() {
  printf '%s\n' "$*" >> "$T/log/pac.log"
  [ -e "$T/pac.down" ] && return 1
  if [ -f "$T/pac/$3" ]; then cat "$T/pac/$3"; return 0; fi
  printf 0; return 2
}

# shellcheck source=/dev/null
. "$DIR/bin/lib/risk-tier.sh" || bad "bin/lib/risk-tier.sh did not source"
for f in rt_classify rt_evidence_load rt_low_rule; do
  command -v "$f" >/dev/null 2>&1 && ok || bad "$f does not exist"
done

# cmpf <name> <json array of [filename, additions, deletions, status?]>
cmpf() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[], files:[$f[] | {filename:.[0], additions:.[1],
    deletions:.[2], status:(.[3] // "modified")}]}' > "$T/cmp/$1.json"
}
# body <text...> — the PR object rt_evidence_load reads (.body only).
body() { jq -nc --arg b "$*" '{number:41, body:$b, user:{login:"cromford[bot]"}}' > "$T/pr.json"; }
marker() { printf '<!-- builder-gate: head=%s green=%s -->' "$1" "$2"; }
# pq <state> <description> — the combined status with one prequeue-verdict entry.
pq() {
  jq -nc --arg s "$1" --arg d "$2" '{state:$s, statuses:[{context:"ci/other", state:"success", description:"x"},
    {context:"prequeue-verdict", state:$s, description:$d}]}' > "$T/status.json"
}
# on — the lane on, the E1 inputs: 12 green suites on $SHA, prequeue green.
on() {
  scratch_rm "$T/set"; scratch_rm "$T/pac"; mkdir -p "$T/set" "$T/pac"
  rm -f "$T/status.json" "$T/status.down" "$T/pac.down" "$T/log"/*
  printf 25 > "$T/set/risk_tier.low_score_max"; printf 12 > "$T/set/risk_tier.low_min_suites"
  body "## Evidence" "$(marker "$SHA" 12)"
  pq success "green on main abc123def456"
}
# cls <cmp> [head] — loads the rules and the evidence, classifies; sets TIER WHY.
cls() {
  local out
  RT_RULES_LOADED=""; rt_rules_load
  rt_evidence_load example-org/demo-os 41 "${2:-$SHA}" "$T/cmp/$1.json" "$T/pr.json"
  out=$(rt_classify "$T/cmp/$1.json" example-org/demo-os)
  TIER=$(cut -f1 <<<"$out"); WHY=$(cut -f2 <<<"$out")
}

# ── E1: a bin/ change, score 0, 12 green suites, prequeue green -> low (evidence) ──
on; cmpf foo '[["bin/foo.sh",30,10]]'; cls foo
[ "$TIER" = low ] && ok || bad "E1 bin/foo.sh read '$TIER' ($WHY)"
[ "$WHY" = "evidence: score 0 under 25, 12 suites green on head, prequeue-verdict green, 40 lines" ] && ok || bad "E1 reasons: $WHY"
[ "$(rt_low_rule "$TIER" "$WHY")" = evidence ] && ok || bad "E1 rt_low_rule: $(rt_low_rule "$TIER" "$WHY")"
grep -q "commits/$SHA/status" "$T/log/ghrest" 2>/dev/null && ok || bad "E1 the status was not read: $(cat "$T/log/ghrest" 2>/dev/null)"
grep -q 'example-org/demo-os 41 bejculprit' "$T/log/pac.log" 2>/dev/null && ok || bad "E1 the culprit history was not read"
# ── N1: the edges that are still low: 13 suites, score 24 ──
on; body "$(marker "$SHA" 13)"; printf 24 > "$T/set/queue_risk.weight.shared_lib"
cmpf lib '[["bin/lib/x.sh",5,5]]'; cls lib
[ "$TIER" = low ] && ok || bad "N1 score 24, 13 suites read '$TIER' ($WHY)"
case "$WHY" in "evidence: score 24 under 25, 13 suites"*) ok ;; *) bad "N1 reasons: $WHY" ;; esac

# ── E2: E1 plus a high glob -> high; E2b plus a lead-protected row -> high ──
on; cmpf e2 '[["bin/foo.sh",30,10],["bin/lib/risk-tier.sh",1,0]]'; cls e2
[ "$TIER" = high ] && ok || bad "E2 a high glob read '$TIER' ($WHY)"
on; cmpf e2b '[["bin/foo.sh",30,10],["bin/guarded.sh",1,0]]'; cls e2b
[ "$TIER" = high ] && ok || bad "E2b a lead-protected glob read '$TIER' ($WHY)"
on; cmpf e2c '[["bin/foo.sh",30,10],["bin/x-secret.sh",1,0]]'; cls e2c
[ "$TIER" = high ] && ok || bad "E2c a sensitive glob read '$TIER' ($WHY)"

# ── E3: bin/lib/x.sh scores 30 (shared_lib) -> medium ──
on; cls lib
[ "$TIER" = medium ] && ok || bad "E3 score 30 read '$TIER' ($WHY)"
case "$WHY" in *"no evidence low: queue-risk score 30, not under 25"*) ok ;; *) bad "E3 reasons: $WHY" ;; esac
# ── N2: a score of exactly the max -> medium ──
on; printf 25 > "$T/set/queue_risk.weight.shared_lib"; cls lib
[ "$TIER" = medium ] && ok || bad "N2 score 25 = max read '$TIER' ($WHY)"
# ...and a culprit verdict (history read through pr_attempt_count) scores 25
on; printf 1 > "$T/pac/bejculprit"; cls foo
[ "$TIER" = medium ] && ok || bad "N2b one culprit verdict read '$TIER' ($WHY)"

# ── E4: no prequeue-verdict status -> medium ──
on; jq -nc '{state:"success", statuses:[{context:"ci/other", state:"success", description:"x"}]}' > "$T/status.json"; cls foo
[ "$TIER" = medium ] && ok || bad "E4 no prequeue-verdict read '$TIER' ($WHY)"
case "$WHY" in *"no evidence low: prequeue-verdict not green"*) ok ;; *) bad "E4 reasons: $WHY" ;; esac
# ── N3: success states that ran no green suites -> medium each ──
for d in "gate off" "no-selection on main abc123def456" "conflict on main abc123def456" \
         "could-not-run (timeout): enqueued without it" "no red pre-queue verdict on this head: ready" \
         "proceed on main abc123def456" "no pre-queue workflow"; do
  on; pq success "$d"; cls foo
  [ "$TIER" = medium ] && ok || bad "N3 prequeue '$d' read '$TIER' ($WHY)"
done
# ── N4: prequeue failure -> medium ──
on; pq failure "green on main abc123def456"; cls foo
[ "$TIER" = medium ] && ok || bad "N4 prequeue failure read '$TIER' ($WHY)"
# ── N5: 11 suites -> medium ──
on; body "$(marker "$SHA" 11)"; cls foo
[ "$TIER" = medium ] && ok || bad "N5 11 suites read '$TIER' ($WHY)"
case "$WHY" in *"11 suites green on head, under 12"*) ok ;; *) bad "N5 reasons: $WHY" ;; esac
# ── N6: a marker for another (older) head -> medium ──
on; body "$(marker "$OLD" 40)"; cls foo
[ "$TIER" = medium ] && ok || bad "N6 an older head's marker read '$TIER' ($WHY)"
# ── N7: two different markers -> medium; the same marker twice is one ──
on; body "$(marker "$SHA" 12)" "$(marker "$SHA" 40)"; cls foo
[ "$TIER" = medium ] && ok || bad "N7 two markers read '$TIER' ($WHY)"
on; body "$(marker "$SHA" 12)" "$(marker "$SHA" 12)"; cls foo
[ "$TIER" = low ] && ok || bad "N7b the same marker twice read '$TIER' ($WHY)"
# an upper-case head in the marker still binds (lowercased)
on; body "$(marker "$(printf 'A%.0s' {1..40})" 12)"; cls foo
[ "$TIER" = low ] && ok || bad "N7c an upper-case marker head read '$TIER' ($WHY)"
# ── N8: 300 lines (the low ceiling) -> medium; 299 is low ──
on; cmpf big '[["bin/foo.sh",200,100]]'; cls big
[ "$TIER" = medium ] && ok || bad "N8 300 lines read '$TIER' ($WHY)"
on; cmpf big2 '[["bin/foo.sh",200,99]]'; cls big2
[ "$TIER" = low ] && ok || bad "N8b 299 lines read '$TIER' ($WHY)"
# ...and a low_lines row lowers the line ceiling for 2c too
on; printf 30 > "$T/set/risk_tier.low_lines"; cls foo
[ "$TIER" = medium ] && ok || bad "N8c 40 lines over low_lines 30 read '$TIER' ($WHY)"
# ── N9: an edit to an existing test file -> medium ──
on; cmpf t9 '[["bin/foo.sh",10,0],["tests/x-test.sh",3,0]]'; cls t9
[ "$TIER" = medium ] && ok || bad "N9 an existing test edit read '$TIER' ($WHY)"
# ...and a rules-text shaped diff stays with rule 2b
on; cmpf r9 '[["rules/CLAUDE.md",3,0],["rules/topics/05-x.md",3,0]]'; cls r9
[ "$TIER" = medium ] && ok || bad "N9b a rules-text diff with no render check read '$TIER' ($WHY)"
# ── N10: no low_score_max row -> lane off, and the sig is today's ──
on; rm -f "$T/set/risk_tier.low_score_max"; cls foo
[ "$TIER" = medium ] && ok || bad "N10 lane off read '$TIER' ($WHY)"
case "$WHY" in *evidence*) bad "N10 lane off still names evidence: $WHY" ;; *) ok ;; esac
OLDSIG=$(printf '%s\n' "$RT_HIGH_GLOBS" "$RT_SENSITIVE_GLOBS" "$RT_LOW_GLOBS" "$RT_HIGH_LINES" "$RT_HIGH_FILES" "$RT_LOW_LINES" "$RT_RULES_LOW_LINES" "" | cksum | cut -d' ' -f1)
[ "$RT_RULES_SIG" = "$OLDSIG" ] && ok || bad "N10 the lane-off sig moved: $RT_RULES_SIG, today $OLDSIG"
on; RT_RULES_LOADED=""; rt_rules_load
[ "$RT_RULES_SIG" != "$OLDSIG" ] && ok || bad "N10b the lane-on sig equals the lane-off sig"
on; printf 0 > "$T/set/risk_tier.low_score_max"; cls foo
[ "$TIER" = medium ] && ok || bad "N10c low_score_max 0 read '$TIER' ($WHY)"
# ── N11: a row unreadable -> medium "rules unreadable" ──
on; : > "$T/set/risk_tier.high_lines.rc1"; cls foo
[ "$TIER" = medium ] && ok || bad "N11 rules unreadable read '$TIER' ($WHY)"
case "$WHY" in "rules unreadable; evidence:"*) ok ;; *) bad "N11 reasons: $WHY" ;; esac
on; : > "$T/set/risk_tier.low_min_suites.rc1"; cls foo
[ "$TIER" = medium ] && ok || bad "N11b low_min_suites unreadable read '$TIER' ($WHY)"
on; printf abc > "$T/set/risk_tier.low_score_max"; cls foo
[ "$TIER" = medium ] && ok || bad "N11c low_score_max 'abc' read '$TIER' ($WHY)"
# ── N12: the attempt history is down -> score unreadable -> medium ──
on; : > "$T/pac.down"; cls foo
[ "$TIER" = medium ] && ok || bad "N12 history outage read '$TIER' ($WHY)"
case "$WHY" in *"queue-risk score unreadable"*) ok ;; *) bad "N12 reasons: $WHY" ;; esac
# ...and a queue_risk row outage is unreadable too, never a score
on; : > "$T/set/queue_risk.weight.size.rc1"; cls foo
[ "$TIER" = medium ] && ok || bad "N12b queue_risk row outage read '$TIER' ($WHY)"
# ── N13: no evidence loaded at all (the in-build caller) -> medium ──
on; RT_RULES_LOADED=""; rt_rules_load
unset RT_EVIDENCE_SCORE RT_EVIDENCE_SUITES RT_EVIDENCE_PREQUEUE RT_EVIDENCE_WHY
out=$(rt_classify "$T/cmp/foo.json" example-org/demo-os); TIER=$(cut -f1 <<<"$out"); WHY=$(cut -f2 <<<"$out")
[ "$TIER" = medium ] && ok || bad "N13 no evidence read '$TIER' ($WHY)"
# ...and inputs a caller set by hand still need a green prequeue
on; RT_RULES_LOADED=""; rt_rules_load
RT_EVIDENCE_SCORE=0; RT_EVIDENCE_SUITES=12; RT_EVIDENCE_PREQUEUE=""; RT_EVIDENCE_WHY=""
out=$(rt_classify "$T/cmp/foo.json" example-org/demo-os); TIER=$(cut -f1 <<<"$out"); WHY=$(cut -f2 <<<"$out")
[ "$TIER" = medium ] && ok || bad "N13b no prequeue input read '$TIER' ($WHY)"
# ── path lows are unchanged, and named `path` ──
on; cmpf docs '[["docs/a.md",8,2]]'; cls docs
[ "$TIER" = low ] && [ "$(rt_low_rule "$TIER" "$WHY")" = path ] && ok || bad "P1 docs: '$TIER' rule $(rt_low_rule "$TIER" "$WHY")"
[ "$(rt_low_rule withheld "evidence: score 0 under 25")" = evidence ] && ok || bad "P2 withheld evidence"
[ "$(rt_low_rule withheld "docs, screens or new tests only, 4 lines")" = path ] && ok || bad "P2 withheld path"
[ "$(rt_low_rule low "rules-text: 4 lines, render check passed")" = path ] && ok || bad "P2 rules-text is path"
[ "$(rt_low_rule medium "x; no evidence low: y")" = - ] && ok || bad "P2 medium is -"
[ "$(rt_low_rule high "evidence: forged")" = - ] && ok || bad "P2 high is -"

# ── L: rt_evidence_load, input by input (body, then status, then score) ──
lchk() { # lchk <name> <score> <suites> <prequeue> <why-glob>
  [ "${RT_EVIDENCE_SCORE:-}|${RT_EVIDENCE_SUITES:-}|${RT_EVIDENCE_PREQUEUE:-}" = "$2|$3|$4" ] && ok \
    || bad "$1 vars: score='${RT_EVIDENCE_SCORE:-}' suites='${RT_EVIDENCE_SUITES:-}' pq='${RT_EVIDENCE_PREQUEUE:-}' why='${RT_EVIDENCE_WHY:-}'"
  # shellcheck disable=SC2254
  case "${RT_EVIDENCE_WHY:-}" in $5) ok ;; *) bad "$1 why: '${RT_EVIDENCE_WHY:-}'" ;; esac
}
ld() { rt_evidence_load example-org/demo-os 41 "${1:-$SHA}" "$T/cmp/foo.json" "$T/pr.json"; LRC=$?; }
on; ld; lchk L1 0 12 green ""
[ "$LRC" = 0 ] && ok || bad "L1 rc $LRC"
on; body "no marker here"; ld; lchk L2 "" "" "" "no builder-gate marker for this head"
[ -s "$T/log/ghrest" ] && bad "L2 the status was read with no marker" || ok
on; body "$(marker "$OLD" 12)"; ld; lchk L3 "" "" "" "no builder-gate marker for this head"
on; body "$(marker "$SHA" 12)$(marker "$OLD" 12)"; ld; lchk L4 "" "" "" "*builder-gate markers*"
on; : > "$T/status.down"; ld; lchk L5 "" 12 "" "prequeue-verdict not green*"
# L5h: the HTTP status reaches the reason (a gh_rest inside $( ) would lose it: HTTP 000).
case "${RT_EVIDENCE_WHY:-}" in *"HTTP 503"*) ok ;; *) bad "L5h the reason lost the HTTP status: '${RT_EVIDENCE_WHY:-}'" ;; esac
[ -s "$T/log/pac.log" ] && bad "L5 the score was read after a failed status" || ok
on; rm -f "$T/status.json"; ld; lchk L6 "" 12 "" "prequeue-verdict not green*"
on; pq success "gate off"; ld; lchk L7 "" 12 "" "prequeue-verdict not green*"
on; : > "$T/pac.down"; ld; lchk L8 "" 12 green "queue-risk score unreadable*"
# the PR object unreadable, and a head that is not a sha
on; ld; echo 'not json' > "$T/pr.json"; ld; lchk L9 "" "" "" "no builder-gate marker for this head"
on; ld "not-a-sha"; lchk L9b "" "" "" "*head*"
# carry-over: a second load clears the first head's inputs
on; ld; body "nothing"; ld; lchk L9c "" "" "" "no builder-gate marker for this head"

# ════════════════ part 2: the builder gate's evidence (G1-G4) ════════════════
awk '/^HARNESS_IMPACT_GATE_RUN\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DIR/bin/lib/rb/gates.sh" > "$T/gate-fn.sh"
W="$T/wt"; mkdir -p "$W/bin"
git -C "$W" init -q 2>/dev/null; git -C "$W" config user.email t@example.test; git -C "$W" config user.name t
cat > "$W/bin/test-impact-gate.sh" <<'EOF'
#!/bin/bash
echo "impact-gate: ran 12 of 14 selected suites via local: passed (left to CI: 2 by the cap, 0 by the budget)"
echo "impact-gate: reused 3 of 14 selected suites from the suite ledger (~40s not re-run)"
exit "${GATE_RC:-0}"
EOF
chmod +x "$W/bin/test-impact-gate.sh"
git -C "$W" add -A; git -C "$W" commit -qm init
WHEAD=$(git -C "$W" rev-parse HEAD)
# grun <build dir> — the extracted gate function in the worktree, stub gate.
grun() {
  mkdir -p "$1"
  ( cd "$W" && BUILD="$1" BASE=bbb PROJECT=cromford KEY=K-1
    STAMP() { echo TS; }; RB_TOKEN_REDACT() { :; }
    # shellcheck source=/dev/null
    . "$T/gate-fn.sh"; HARNESS_IMPACT_GATE_RUN harness-suite.txt lenses ) > /dev/null 2>&1
}
B1="$T/b1"; grun "$B1"
grep -qx "HARNESS_HEAD: $WHEAD" "$B1/harness-suite.txt" && ok || bad "G1 no HARNESS_HEAD line: $(cat "$B1/harness-suite.txt")"
grep -qx 'HARNESS_EXIT: 0' "$B1/harness-suite.txt" && ok || bad "G1 HARNESS_EXIT: $(cat "$B1/harness-suite.txt")"
ES=$(bash "$DIR/bin/evidence-summary.sh" "$B1" 2 "" provisional)
grep -qx "<!-- builder-gate: head=$WHEAD green=12 -->" <<<"$ES" && ok || bad "G1 no marker in the evidence block"
# G2: the round trip — the block as the PR body, read back for this head
on; jq -nc --arg b "$ES" '{body:$b}' > "$T/pr.json"
rt_evidence_load example-org/demo-os 41 "$WHEAD" "$T/cmp/foo.json" "$T/pr.json"
[ "${RT_EVIDENCE_SUITES:-}" = 12 ] && [ "${RT_EVIDENCE_PREQUEUE:-}" = green ] && ok || bad "G2 round trip: suites='${RT_EVIDENCE_SUITES:-}' why='${RT_EVIDENCE_WHY:-}'"
# ...and the newest suite file wins (harness-suite-head.txt over harness-suite.txt)
printf 'HARNESS_SUITE: x\nHARNESS_HEAD: %s\nimpact-gate: ran 20 of 20 selected suites via local: passed (x)\nHARNESS_EXIT: 0\n' "$OLD" > "$B1/harness-suite-head.txt"
ES=$(bash "$DIR/bin/evidence-summary.sh" "$B1" 2 "" provisional); grep -qx "<!-- builder-gate: head=$OLD green=20 -->" <<<"$ES" && ok || bad "G2b the head re-run did not win"
# G3: a red gate -> no marker
B3="$T/b3"; GATE_RC=1 grun "$B3"
ES=$(bash "$DIR/bin/evidence-summary.sh" "$B3" 2 "" provisional); grep -q 'builder-gate' <<<"$ES" && bad "G3 a red gate has a marker" || ok
# G4: a dirty tree -> HARNESS_HEAD: dirty, no marker
echo x > "$W/untracked.txt"; B4="$T/b4"; grun "$B4"; rm -f "$W/untracked.txt"
grep -qx 'HARNESS_HEAD: dirty' "$B4/harness-suite.txt" && ok || bad "G4 a dirty tree: $(grep HARNESS_HEAD "$B4/harness-suite.txt")"
ES=$(bash "$DIR/bin/evidence-summary.sh" "$B4" 2 "" provisional); grep -q 'builder-gate' <<<"$ES" && bad "G4 a dirty head has a marker" || ok
# G4c: outside a git work tree -> no HARNESS_HEAD line at all
NW="$T/nogit"; mkdir -p "$NW/bin"; cp "$W/bin/test-impact-gate.sh" "$NW/bin/"; B6="$T/b6"
( W="$NW"; grun "$B6" )
grep -qx 'HARNESS_EXIT: 0' "$B6/harness-suite.txt" && ok || bad "G4c the gate did not run outside git"
grep -q '^HARNESS_HEAD:' "$B6/harness-suite.txt" && bad "G4c a HARNESS_HEAD line outside git: $(cat "$B6/harness-suite.txt")" || ok
# G4b: an old suite file with no HARNESS_HEAD line renders as before (no marker)
B5="$T/b5"; mkdir -p "$B5"; printf 'impact-gate: ran 12 of 14 selected suites via local: passed (x)\nHARNESS_EXIT: 0\n' > "$B5/harness-suite.txt"
ES=$(bash "$DIR/bin/evidence-summary.sh" "$B5" 2 "" provisional); grep -q 'builder-gate' <<<"$ES" && bad "G4b no HARNESS_HEAD has a marker" || ok

# ════════════════ part 3: the enqueue tick, whole (E5, W1, W2) ════════════════
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/elog" "$T/cfg" "$T/repos"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1
[ -f "$H/bin/lib/queue-risk.sh" ] && ok || bad "bin/lib/queue-risk.sh is not in the lane's closure"
LPPF2="$T/lpp2.json"; DOWNF2="$T/lpp2-down"
lpp_install "$T/fakebin" "$LPPF2" "$DOWNF2"
set -f; lpp_set "$LPPF2" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
printf 'lead-test-token-fixture\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'cromford example-org/cromford https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"
E=$T/e; mkdir -p "$E"
cat > "$T/fakebin/curl" <<EOF
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
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/elog/worker"
[ -f "$E/lrrows.json" ] || echo '[]' > "$E/lrrows.json"
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/settings/risk_tier.mode.example-org.cromford")
    if [ -f "$E/mode" ]; then out=\$(jq -nc --arg v "\$(cat "$E/mode")" '{setting:{key:"risk_tier.mode.example-org.cromford",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$E/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$E/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/pr-attempts?"*)
    if [ -e "$E/pa500" ]; then code=500; out='{"error":"boom"}'; else out='{"count":0}'; fi ;;
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$E/jv/\$n.json" ]; then out=\$(cat "$E/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    out='{"standing":null, "rows":[], "truncated":false}' ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true,"id":1}' ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      n=\$(jq length "$E/lrrows.json")
      row=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested"}' <<<"\$body")
      jq -c --argjson r "\$row" '. + [\$r]' "$E/lrrows.json" > "$E/lrrows.tmp" && mv "$E/lrrows.tmp" "$E/lrrows.json"
      code=201; out=\$(jq -c '{request:.}' <<<"\$row")
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/elog/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/"*"/commits/"*"/status"|*"-X GET repos/example-org/"*"/commits/"*"/status "*)
    a="\$*"; h="\${a##*/commits/}"; h="\${h%%/*}"
    printf 'HTTP/2 200\r\n\r\n'
    if [ -f "$E/status/\$h.json" ]; then cat "$E/status/\$h.json"; else echo '{"state":"pending","statuses":[]}'; fi ;;
  *"-X GET repos/example-org/"*"/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$E/prs.json" ;;
  *"-X GET repos/example-org/"*"/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$E/head/\$n")" --arg b "\$(cat "$E/body/\$n" 2>/dev/null)" \
      '{head:{sha:\$s},base:{ref:"main"},user:{login:"cromford[bot]"},body:\$b}' ;;
  *"-X GET repos/example-org/"*"/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    printf 'HTTP/2 200\r\n\r\n'; cat "$E/cmp/\$h.json" ;;
  *"-X POST repos/example-org/"*"/statuses/"*)
    printf 'HTTP/2 201\r\n\r\n{"state":"success"}\n' ;;
esac
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/elog/lv"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; printf '#!/bin/bash\nexit 0\n' > "$H/bin/agent-call.sh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lead-verdict.sh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

etick() {
  ( cd "$T" && unset BOX_NAME JOBS_BOX HUB_BOX_NAME && PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
    JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
    FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/cromford \
    LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 REPOS_ROOT="$T/repos" \
    bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/eout" 2>&1; ERC=$?
}
ereset() {
  rm -f "$T/elog"/* "$E/lrrows.json" "$E/pa500" "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv head cmp set body status; do scratch_rm "$E/$d"; mkdir -p "$E/$d"; done
  printf 'operator' > "$E/set/lead_pr_authors"
  printf 25 > "$E/set/risk_tier.low_score_max"
  echo box-hub > "$H/state/box-name"
  echo "${1:-enforce}" > "$E/mode"
  jq -nc --arg h "$SHA" '[{number:41, html_url:"https://github.com/example-org/cromford/pull/41", title:"t", draft:false,
    state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' > "$E/prs.json"
  echo "$SHA" > "$E/head/41"
  jq -nc --arg s "$SHA" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    job:{id:"job-1", kind:"build", status:"running"},
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$E/jv/41.json"
  jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}],
    files:[{filename:"bin/foo.sh", additions:30, deletions:10, status:"modified"}]}' > "$E/cmp/$SHA.json"
  printf '## Evidence\n%s\n' "$(marker "$SHA" 12)" > "$E/body/41"
  jq -nc '{state:"success", statuses:[{context:"prequeue-verdict", state:"success", description:"green on main abc123def456"}]}' > "$E/status/$SHA.json"
}
RISKF="$H/state/lead-review-enqueue/risk.tsv"
col() { awk -F'\t' -v c="$1" -v h="$SHA" '$4 == h {v = $c} END {print v}' "$RISKF" 2>/dev/null; }
wn() { grep -c "^$1" "$T/elog/worker" 2>/dev/null; }

# ── E5: an evidence-low head through the real tick -> risk.tsv names `evidence` ──
ereset; etick
[ "$ERC" = 0 ] && ok || bad "E5 rc=$ERC $(cat "$T/eout")"
[ "$(col 5)" = low ] && ok || bad "E5 risk.tsv tier: '$(col 5)' ($(col 6)) — $(cat "$RISKF" 2>/dev/null)"
[ "$(col 8)" = evidence ] && ok || bad "E5 risk.tsv column 8: '$(col 8)'"
case "$(col 6)" in "evidence: score 0 under 25, 12 suites green on head, prequeue-verdict green, 40 lines") ok ;; *) bad "E5 reasons: $(col 6)" ;; esac
grep -q "post example-org/cromford 41 $SHA MERGE --source risk-tier .*--note low risk: evidence: " "$T/elog/lv" 2>/dev/null && ok || bad "E5 sign-off argv: $(cat "$T/elog/lv" 2>/dev/null)"
# ── W2: the next tick reuses the line: no second classify, no second status read ──
RP=$(wn 'POST /api/risk-tiers'); SR=$(grep -c '/status' "$T/elog/gh")
etick
[ "$(wn 'POST /api/risk-tiers')" = "$RP" ] && ok || bad "W2 the head was classified again: $RP -> $(wn 'POST /api/risk-tiers')"
[ "$(grep -c '/status' "$T/elog/gh")" = "$SR" ] && ok || bad "W2 the status was read again"
# ── a docs-only head -> column 8 `path` ──
ereset; jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}],
  files:[{filename:"docs/a.md", additions:3, deletions:0, status:"modified"}]}' > "$E/cmp/$SHA.json"; etick
[ "$(col 5)" = low ] && [ "$(col 8)" = path ] && ok || bad "E5b docs-only: tier '$(col 5)' column 8 '$(col 8)'"
# ── W1: no marker in the body -> medium, column 8 `-`, requested as today ──
ereset shadow; printf 'no marker\n' > "$E/body/41"; etick
[ "$(col 5)" = medium ] && [ "$(col 8)" = - ] && ok || bad "W1 tier '$(col 5)' column 8 '$(col 8)' ($(col 6))"
[ "$(wn 'POST /api/lead-reviews')" -ge 1 ] && ok || bad "W1 the medium head was not requested: $(cat "$T/elog/worker" | cut -c1-120)"
[ -s "$T/elog/lv" ] && bad "W1 a medium head was signed off" || ok
# ── W1b: the lane off (no row) -> no status read at all ──
ereset; rm -f "$E/set/risk_tier.low_score_max"; etick
grep -q '/status' "$T/elog/gh" 2>/dev/null && bad "W1b the lane is off but the status was read" || ok
[ "$(col 5)" = medium ] && ok || bad "W1b lane off read '$(col 5)'"
# ── W1c: the attempt history down -> medium ──
ereset; : > "$E/pa500"; etick
[ "$(col 5)" = medium ] && ok || bad "W1c history outage read '$(col 5)' ($(col 6))"

# ════════════════ part 4: lg_gate_risk (60-risk.sh), sourced (V1-V3) ════════════════
# The worklist twin of the enqueue's risk block, with the same in-shell stubs
# as part 1 plus the gate's own seams.
VH="$T/vh"; mkdir -p "$VH/bin" "$VH/state" "$T/vlog"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexit 0\n' "$T/vlog/lv" > "$VH/bin/lead-verdict.sh"; chmod +x "$VH/bin/lead-verdict.sh"
printf 'cromford example-org/cromford https://demo.test /api 3 hub\n' > "$VH/fleet.conf"
lpp_set "$LPPF" example-org/cromford 'bin/guarded.sh'
# shellcheck source=/dev/null
. "$DIR/bin/lib/lead-gates.d/60-risk.sh" || bad "60-risk.sh did not source"
_lgt_log() { printf '%s\n' "$*" >> "$T/vlog/log"; }
local_box_name() { echo hub; }
lgc_compare() { LGC_FILE="$T/cmp/foo.json"; LGC_SELF=false; LGC_RC=0; return 0; }
gh_rest() {
  printf '%s\n' "$*" >> "$T/log/ghrest"
  case "$2" in
    */pulls/*) cat "$T/pr.json" ;;
    */status) [ -f "$T/status.json" ] || return 44; cat "$T/status.json" ;;
    *) return 44 ;;
  esac
}
vrun() { # vrun — one lg_gate_risk on PR 41 @ $SHA; sets VRC
  _lgr_mode=(); unset TO_LEAD_AUTHORS TO_LEAD_RC
  printf enforce > "$T/set/risk_tier.mode.example-org.cromford"; printf operator > "$T/set/lead_pr_authors"
  scratch_rm "$VH/state"; mkdir -p "$VH/state"; rm -f "$T/vlog/lv"
  HARNESS="$VH" FLEET_CONF="$VH/fleet.conf"
  lg_gate_risk example-org/cromford 41 "$SHA"; VRC=$?
  unset HARNESS FLEET_CONF
}
VRISK="$VH/state/lead-review-enqueue/risk.tsv"
vcol() { awk -F'\t' -v c="$1" '{v = $c} END {print v}' "$VRISK" 2>/dev/null; }
# V1: the E1 head -> signed off (rc 12), risk.tsv column 8 `evidence`
on; vrun
[ "$VRC" = 12 ] && ok || bad "V1 rc $VRC: $(cat "$T/vlog/log" 2>/dev/null)"
[ "$(vcol 5)" = low ] && [ "$(vcol 8)" = evidence ] && ok || bad "V1 risk.tsv: $(cat "$VRISK" 2>/dev/null)"
grep -q 'note low risk: evidence: score 0 under 25' "$T/vlog/lv" 2>/dev/null && ok || bad "V1 sign-off argv: $(cat "$T/vlog/lv" 2>/dev/null)"
# V2: no prequeue-verdict -> medium, column 8 `-`, rc 0
on; rm -f "$T/status.json"; vrun
[ "$VRC" = 0 ] && [ "$(vcol 5)" = medium ] && [ "$(vcol 8)" = - ] && ok || bad "V2 rc $VRC risk.tsv: $(cat "$VRISK" 2>/dev/null)"
[ -s "$T/vlog/lv" ] && bad "V2 a medium head was signed off" || ok
# V3: the lane off -> no status read, medium
on; rm -f "$T/set/risk_tier.low_score_max"; vrun
grep -q '/status' "$T/log/ghrest" 2>/dev/null && bad "V3 the lane is off but the status was read" || ok
[ "$(vcol 5)" = medium ] && ok || bad "V3 lane off: $(cat "$VRISK" 2>/dev/null)"

echo "risk-tier-evidence.bh-6968: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
