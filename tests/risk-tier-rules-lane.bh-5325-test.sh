#!/bin/bash
# tests/risk-tier-rules-lane.bh-5325-test.sh — BH-5325: the risk tier's
# rules-text lane. A PR that only edits rules/topics/<name>.md and its render
# rules/CLAUDE.md, whose render check passes on the head, under the line limit
# and with no line deleted from 01-iron-guardrails.md, is low. The hub signs it
# (also for a lead-authored PR) with reviewer risk-tier:rules-text:<box>, and
# the lead-PR merge fence lets exactly that reviewer through.
#   C1-C10  the classifier, "$DIR/bin/lib/risk-tier.sh", on compare answers.
#   G1-G4   the head render check, "$DIR/bin/lib/rules-render-head.sh", on a
#           real scratch origin and clone with the real bin/render-rules.sh.
#   The worklist half is tests/lead-gates-risk-jev-ports.bh-8629-test.sh
#           RJ1-RJ3 and tests/lead-gates-risk.bh-5875-test.sh R3, R7-R9.
#   F1-F3   to_lead_merge_hold from the real bin/lib/ticket-ownership.sh.
#   Q1      a rules diff does not escalate the merge-queue batch.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/risk-tier-rules-lane.bh-5325-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REVIEW_REQUIRE_BUILDER_APPROVE RT_RULES_RENDER
SLUG=example-org/cromford
GR=rules/topics/01-iron-guardrails.md

# ════════════════════════════════════════════════════════════════════════════
# C: the classifier
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/set" "$T/cmp" "$T/tmp"
export TMPDIR="$T/tmp"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture); the in-shell classifier reads
# them through _jobs_req, the curl stubs below through lpp-answer.
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
_jobs_req() { lpp_jobs_req "$LPPF" "$LPPDOWN" "$@"; }
setting_get() {
  [ -e "$T/set/$1.rc1" ] && return 1
  [ -f "$T/set/$1" ] || return 2
  cat "$T/set/$1"
}
# shellcheck source=/dev/null
. "$DIR/bin/lib/risk-tier.sh" || bad "bin/lib/risk-tier.sh did not source"
command -v rt_classify >/dev/null 2>&1 || { echo "risk-tier-rules-lane.bh-5325: rt_classify missing"; exit 1; }

# cmpf <name> <json array of [filename, additions, deletions, previous_filename?, status?]>
cmpf() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[], files:[$f[] | {filename:.[0], additions:.[1], deletions:.[2],
    status:(.[4] // (if (.[3] // null) == null then "modified" else "renamed" end))}
    + (if (.[3] // null) == null then {} else {previous_filename:.[3]} end)]}' > "$T/cmp/$1.json"
}
# cls <cmp> — sets TIER and WHY. RT_RULES_LOADED is cleared so a row change is read.
cls() {
  local out
  RT_RULES_LOADED=""
  out=$(rt_classify "$T/cmp/$1.json" "$SLUG")
  TIER=$(cut -f1 <<<"$out"); WHY=$(cut -f2 <<<"$out")
}
reset_set() { scratch_rm "$T/set"; mkdir -p "$T/set"; }
C1='["rules/topics/12-x.md",12,0,null,"added"],["rules/CLAUDE.md",8,0]'
export RT_RULES_RENDER=$'ok\trender check passed'

# C1: a new topic plus its render, 20 lines -> low, reason rules-text:
cmpf c1 "[$C1]"; cls c1
[ "$TIER" = low ] && ok || bad "C1 topic+render: '$TIER' ($WHY)"
case "$WHY" in rules-text:*) ok ;; *) bad "C1 reason does not start rules-text: '$WHY'" ;; esac
command -v rt_rules_low >/dev/null 2>&1 && rt_rules_low "$TIER" "$WHY" && ok || bad "C1 rt_rules_low does not accept it"
command -v rt_rules_low >/dev/null 2>&1 && rt_rules_low withheld "$WHY" && ok || bad "C1 rt_rules_low refuses withheld"
command -v rt_rules_low >/dev/null 2>&1 && ! rt_rules_low medium "$WHY" && ! rt_rules_low low "docs, screens or new tests only, 3 lines" && ok \
  || bad "C1 rt_rules_low accepts a medium or a docs low"
command -v rt_rules_shape >/dev/null 2>&1 && rt_rules_shape "$T/cmp/c1.json" && ok || bad "C1 rt_rules_shape refuses topic+render"

# C2: plus a bin/ script -> not low
cmpf c2 "[$C1,[\"bin/foo.sh\",1,0]]"; cls c2
[ "$TIER" = medium ] || [ "$TIER" = high ] && ok || bad "C2 topic+render+bin: '$TIER' ($WHY)"
command -v rt_rules_shape >/dev/null 2>&1 && ! rt_rules_shape "$T/cmp/c2.json" && ok || bad "C2 rt_rules_shape takes a bin path"
cmpf c2b "[$C1,[\"docs/x.md\",1,0]]"; cls c2b
[ "$TIER" != low ] && ok || bad "C2b topic+render+docs read low ($WHY)"

# C3: an edited guardrail line (+1 -1) -> medium; removed -> not low; renamed away -> not low
cmpf c3 "[$C1,[\"$GR\",1,1]]"; cls c3
[ "$TIER" = medium ] && ok || bad "C3 guardrail deletion: '$TIER' ($WHY)"
case "$WHY" in *01-iron-guardrails*) ok ;; *) bad "C3 reason does not name the guardrails file: $WHY" ;; esac
cmpf c3a "[$C1,[\"$GR\",3,0]]"; cls c3a
[ "$TIER" = low ] && ok || bad "C3a a purely additive guardrail edit: '$TIER' ($WHY)"
cmpf c3b "[$C1,[\"$GR\",0,0,null,\"removed\"]]"; cls c3b
[ "$TIER" != low ] && ok || bad "C3b guardrails removed read low ($WHY)"
cmpf c3c "[$C1,[\"rules/topics/01-x.md\",0,0,\"$GR\"]]"; cls c3c
[ "$TIER" != low ] && ok || bad "C3c guardrails renamed away read low ($WHY)"

# C4: rules/settings.json -> high (a lead protected path); rules/RTK.md -> not low
cmpf c4 "[$C1,[\"rules/settings.json\",1,0]]"; cls c4
[ "$TIER" = high ] && ok || bad "C4 rules/settings.json: '$TIER' ($WHY)"
cmpf c4b "[$C1,[\"rules/RTK.md\",1,0]]"; cls c4b
[ "$TIER" != low ] && ok || bad "C4b rules/RTK.md read low ($WHY)"

# C5: the line limit, default 80, strictly under
for n in 81:medium 80:medium 79:low; do
  cmpf c5 "[[\"rules/topics/12-x.md\",$(( ${n%%:*} - 8 )),0,null,\"added\"],[\"rules/CLAUDE.md\",8,0]]"; cls c5
  [ "$TIER" = "${n#*:}" ] && ok || bad "C5 ${n%%:*} lines: '$TIER' want ${n#*:} ($WHY)"
done

# C6: a topic with no render in the diff -> medium
cmpf c6 '[["rules/topics/12-x.md",12,0,null,"added"]]'; cls c6
[ "$TIER" = medium ] && ok || bad "C6 topic without render: '$TIER' ($WHY)"

# C7: a nested topic, a non-md topic -> not low
cmpf c7 '[["rules/topics/sub/x.md",5,0,null,"added"],["rules/CLAUDE.md",5,0]]'; cls c7
[ "$TIER" != low ] && ok || bad "C7 rules/topics/sub/x.md read low ($WHY)"
cmpf c7b '[["rules/topics/x.txt",5,0,null,"added"],["rules/CLAUDE.md",5,0]]'; cls c7b
[ "$TIER" != low ] && ok || bad "C7b rules/topics/x.txt read low ($WHY)"

# C8: a rename from bin/ into rules/topics/ -> not low
cmpf c8 '[["rules/topics/12-x.md",0,0,"bin/x.sh"],["rules/CLAUDE.md",5,0]]'; cls c8
[ "$TIER" != low ] && ok || bad "C8 rename from bin/x.sh read low ($WHY)"

# C9: the render check not passed -> medium each time
for r in $'drift\tDRIFT rules/CLAUDE.md' $'unread\trc 2' "okay" UNSET; do
  if [ "$r" = UNSET ]; then unset RT_RULES_RENDER; else RT_RULES_RENDER="$r"; fi
  cls c1
  [ "$TIER" = medium ] && ok || bad "C9 render '${r%%$'\t'*}': '$TIER' ($WHY)"
done
export RT_RULES_RENDER=$'ok\trender check passed'

# C10: the row risk_tier.rules_low_lines
reset_set; printf '10' > "$T/set/risk_tier.rules_low_lines"; cls c1
[ "$TIER" = medium ] && ok || bad "C10 row 10, 20 lines: '$TIER' ($WHY)"
RT_RULES_LOADED=""; rt_rules_load; SIG10=$RT_RULES_SIG
reset_set; : > "$T/set/risk_tier.rules_low_lines.rc1"; cls c1
[ "$TIER" = medium ] && ok || bad "C10 row unreadable: '$TIER' ($WHY)"
case "$WHY" in "rules unreadable"*) ok ;; *) bad "C10 unreadable reason: $WHY" ;; esac
reset_set; printf '0' > "$T/set/risk_tier.rules_low_lines"; cls c1
[ "$TIER" = medium ] && ok || bad "C10 row 0 (lane off): '$TIER' ($WHY)"
reset_set; printf '1000' > "$T/set/risk_tier.rules_low_lines"
cmpf c10 '[["rules/topics/12-x.md",290,0,null,"added"],["rules/CLAUDE.md",9,0]]'; cls c10
[ "$TIER" = low ] && ok || bad "C10 row 1000, 299 lines: '$TIER' ($WHY)"
cmpf c10 '[["rules/topics/12-x.md",291,0,null,"added"],["rules/CLAUDE.md",9,0]]'; cls c10
[ "$TIER" = medium ] && ok || bad "C10 row 1000 caps at 300, 300 lines: '$TIER' ($WHY)"
reset_set; RT_RULES_LOADED=""; rt_rules_load
[ -n "$SIG10" ] && [ "$SIG10" != "$RT_RULES_SIG" ] && ok || bad "C10 the row does not change RT_RULES_SIG"
# protected paths unreadable: never low
# TEST-CHANGE BH-4148: unreadable was a missing TSV (LA_CATALOG, no longer read);
# it is now the rows read failing (500) with no fresh cache.
( printf 500 > "$LPPDOWN"; rm -f "${HARNESS:-$T/no-harness}/state/lead-authority/"globs-*.cache
  cls c1; [ "$TIER" = medium ] ) && ok || bad "C10 protected paths unreadable read low"
rm -f "$LPPDOWN"

# ════════════════════════════════════════════════════════════════════════════
# The rules fixture repo: main, a clean topic head, a stale-render head and a
# symlinked-topic head.
# ════════════════════════════════════════════════════════════════════════════
OR="$T/origin/bh.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
mkdir -p "$WK/rules/topics"
printf '# Fleet rules\n\nPreamble.\n' > "$WK/rules/topics/00-intro.md"
printf '## Iron guardrails\n\n1. Never merge.\n' > "$WK/rules/topics/$(basename "$GR")"
"$DIR/bin/render-rules.sh" --root "$WK" --write || bad "fixture render failed"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb clean
printf '## A new topic\n\nOne rule.\n' > "$WK/rules/topics/12-x.md"
"$DIR/bin/render-rules.sh" --root "$WK" --write || bad "fixture render failed"
git -C "$WK" add -A; git -C "$WK" commit -qm "rules: a new topic"
HC=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb stale main
printf '## A new topic\n\nOne rule.\n' > "$WK/rules/topics/12-x.md"
echo 'hand edit' >> "$WK/rules/CLAUDE.md"
git -C "$WK" add -A; git -C "$WK" commit -qm "rules: stale render"
HS=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb link clean
printf '## secret line\n' > "$T/outside.txt"; ln -s "$T/outside.txt" "$WK/rules/topics/13-link.md"
git -C "$WK" add -A; git -C "$WK" commit -qm "rules: a symlinked topic"
HL=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main clean stale link
mkdir -p "$T/repos"; git clone -q "$OR" "$T/repos/cromford"

# ════════════════════════════════════════════════════════════════════════════
# G: the head render check
# ════════════════════════════════════════════════════════════════════════════
if [ -f "$DIR/bin/lib/rules-render-head.sh" ]; then
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/rules-render-head.sh" || bad "bin/lib/rules-render-head.sh did not source"
fi
tmpn() { find "$T/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }
rrh() { local b; b=$(tmpn); OUT=$(rrh_check "$@"); RRC=$?; TMPD=$(( $(tmpn) - b )); }
if command -v rrh_check >/dev/null 2>&1; then
  rrh "$T/repos/cromford" "$HC" "$DIR/bin/render-rules.sh"
  [ "$RRC" = 0 ] && [ "${OUT%%$'\t'*}" = ok ] && ok || bad "G1 a clean render: rc=$RRC '$OUT'"
  [ "$TMPD" = 0 ] && ok || bad "G1 left $TMPD scratch entries"
  rrh "$T/repos/cromford" "$HS" "$DIR/bin/render-rules.sh"
  [ "$RRC" = 0 ] && [ "${OUT%%$'\t'*}" = drift ] && ok || bad "G2 a stale render: rc=$RRC '$OUT'"
  [ "$TMPD" = 0 ] && ok || bad "G2 left $TMPD scratch entries"
  case "${OUT#*$'\t'}" in "< "*|"> "*) ok ;; *) bad "G2 the drift detail is not a diff line: '$OUT'" ;; esac
  # G5: a symlink in the head's rules/ tree is unread, and its target never shows
  rrh "$T/repos/cromford" "$HL" "$DIR/bin/render-rules.sh"
  [ "$RRC" = 0 ] && [ "${OUT%%$'\t'*}" = unread ] && ok || bad "G5 a symlinked topic: rc=$RRC '$OUT'"
  case "$OUT" in *"secret line"*) bad "G5 the symlink target leaked: '$OUT'" ;; *) ok ;; esac
  [ "$TMPD" = 0 ] && ok || bad "G5 left $TMPD scratch entries"
  rrh "$T/repos/cromford" 1234567890123456789012345678901234567890 "$DIR/bin/render-rules.sh"
  [ "$RRC" = 0 ] && [ "${OUT%%$'\t'*}" = unread ] && ok || bad "G3 an unknown sha: rc=$RRC '$OUT'"
  [ "$TMPD" = 0 ] && ok || bad "G3 left $TMPD scratch entries"
  rrh "$T/repos/nothing-here" "$HC" "$DIR/bin/render-rules.sh"
  [ "$RRC" = 0 ] && [ "${OUT%%$'\t'*}" = unread ] && ok || bad "G4 no checkout: rc=$RRC '$OUT'"
  rrh "$T/repos/cromford" "${HC:0:12}" "$DIR/bin/render-rules.sh"
  [ "${OUT%%$'\t'*}" = unread ] && ok || bad "G4 a short sha: '$OUT'"
  rrh "$T/repos/cromford" "$HC" "$T/no-renderer.sh"
  [ "${OUT%%$'\t'*}" = unread ] && ok || bad "G4 no renderer: '$OUT'"
  # the fetch wrote no ref and no FETCH_HEAD in the shared checkout
  [ ! -e "$T/repos/cromford/.git/FETCH_HEAD" ] && ok || bad "G1 the fetch wrote FETCH_HEAD"
else
  bad "G1-G4 bin/lib/rules-render-head.sh has no rrh_check"
fi

# ════════════════════════════════════════════════════════════════════════════
# F: the lead-PR fence
# ════════════════════════════════════════════════════════════════════════════
FH="$T/fence/h"; FX="$T/fence/fx"; mkdir -p "$FH/state" "$FH/logs" "$FX" "$T/fence/fakebin"
lpp_install "$T/fence/fakebin" "$LPPF" "$LPPDOWN"   # TEST-CHANGE BH-4148: the same rows for the fence
scratch_install_closure bin/jobs-client.sh "$FH" >/dev/null || bad "closure of bin/jobs-client.sh (fence)"
scratch_install_closure bin/lib/ticket-ownership.sh "$FH" >/dev/null || bad "closure of bin/lib/ticket-ownership.sh"
scratch_install_closure bin/lib/verdicts.sh "$FH" >/dev/null || bad "closure of bin/lib/verdicts.sh"
cat > "$T/fence/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL body)
  "GET "*/api/verdicts\?*) printf '%s\n200\n' "\$(jq -nc --argjson s "\$(cat "$FX/standing")" '{standing:\$s,rows:[]}')" ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
printf '#!/bin/bash\necho ""\nexit 0\n' > "$T/fence/fakebin/gh"
chmod +x "$T/fence/fakebin/curl" "$T/fence/fakebin/gh"
# fence <reviewer> [verdict] — prints `<rc>\t<kind>\t<reason>`
fence() {
  jq -nc --arg r "$1" --arg v "${2:-MERGE}" '{verdict:$v,source:"risk-tier",id:9,created_at:"2026-10-09T00:00:00Z",report_url:null,reviewer:$r}' > "$FX/standing"
  ( cd "$T/fence" && PATH="$T/fence/fakebin:$PATH" HARNESS="$FH" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_BOX=box-l \
      bash -c '. "$HARNESS/bin/lib/ticket-ownership.sh"; out=$(to_lead_merge_hold '"$SLUG"' 41 '"$HC"' operator); rc=$?; printf "%s\t%s\n" "$rc" "$out"' ) 2>/dev/null | tail -1
}
F=$(fence risk-tier:rules-text:hub)
[ "${F%%$'\t'*}" = 1 ] && [[ "$F" == *$'\tcleared\t'* ]] && ok || bad "F1 a rules-text MERGE did not clear the lead PR: $F"
F=$(fence risk-tier:rules-text:hub BLOCK)
[ "${F%%$'\t'*}" = 0 ] && ok || bad "F1b a rules-text BLOCK cleared the lead PR: $F"
F=$(fence risk-tier:hub)
[ "${F%%$'\t'*}" = 0 ] && [[ "$F" == *"a risk-tier sign-off never clears a lead PR"* ]] && ok || bad "F2 a plain risk-tier MERGE: $F"
for r in xrisk-tier:rules-text:hub risk-tier:rules-textX - ""; do
  F=$(fence "$r")
  [ "${F%%$'\t'*}" = 0 ] && [[ "$F" == *$'\theld\t'* ]] && ok || bad "F3 reviewer '$r' was not held: $F"
done

# ════════════════════════════════════════════════════════════════════════════
# Q: a rules diff does not escalate the merge-queue batch
# ════════════════════════════════════════════════════════════════════════════
# shellcheck source=/dev/null
. "$DIR/bin/lib/ci-batch-escalate.sh" || bad "Q1 bin/lib/ci-batch-escalate.sh did not source"
for p in rules/topics/11-x.md rules/CLAUDE.md; do
  cbe_reason "$p" >/dev/null && bad "Q1 $p escalates the batch" || ok
done
grep -q 'pull_request (ordinary)   FAST CHECKS ONLY' "$DIR/.github/workflows/harness-ci.yml" && ok || bad "Q1 harness-ci.yml no longer says an ordinary PR runs fast checks only"

echo "risk-tier-rules-lane.bh-5325: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
