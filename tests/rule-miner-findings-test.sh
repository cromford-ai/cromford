#!/bin/bash
# tests/rule-miner-findings-test.sh — the fifth incident source: recurring
# review-finding families out of logs/findings.log.
#
# Drives rule-miner.sh in RULE_MINER_DRY=1 mode (gather + bundle + print the
# inventory, stop before the agent call), so the promotion THRESHOLD is proven
# on fixtures with no network, no secrets, and no LLM call. flock is stubbed
# because macOS has none and the script's `flock -n 9 || exit 0` would otherwise
# make this suite pass by doing nothing — a silent skip is exactly the shape
# these tests exist to catch.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs" "$T/state/rule-mining" "$T/flags" "$T/env" "$T/locks" "$T/stub"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1  # BH-1510.2: lanes read models from model_routes
: > "$T/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
# gh must never be reached in dry mode; if it is, the run fails loudly here
printf '#!/bin/sh\necho "gh called in dry mode" >&2\nexit 1\n' > "$T/stub/gh"
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

TODAY=$(date -u +%Y-%m-%d)
OLD=$(date -u -d '90 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-90d +%Y-%m-%d)
FL="$T/logs/findings.log"

row() { # row <date> <project> <ticket> <family> <text>
  printf '%s 12:00:00Z [%s] ticket=%s lens=general verdict=BLOCK rule=D14 family=%s :: %s\n' \
    "$1" "$2" "$3" "$4" "$5" >> "$FL"
}
: > "$FL"
# aaaaaaaaaaaa: 3 occurrences, 2 projects -> crosses the default PROMOTE_MIN=3
row "$TODAY" project-2 TK-1 aaaaaaaaaaaa "authz: PATCH never re-validates the target row against the resolved org"
row "$TODAY" project-2 TK-2 aaaaaaaaaaaa "authz: PATCH never re-validates the target row against the resolved org"
row "$TODAY" project-3       TK-3 aaaaaaaaaaaa "authz: PATCH never re-validates the target row against the resolved org"
# bbbbbbbbbbbb: only 2 occurrences -> below threshold, not an incident
row "$TODAY" project-4 TK-4 bbbbbbbbbbbb "a test that passes at the merge base proves nothing"
row "$TODAY" project-4 TK-5 bbbbbbbbbbbb "a test that passes at the merge base proves nothing"
# cccccccccccc: 4 occurrences but all outside the 30-day window
for i in 6 7 8 9; do
  row "$OLD" project-1 "TK-$i" cccccccccccc "ancient finding that should not resurface"
done

run() { RULE_MINER_DRY=1 HARNESS="$T" "$@" bash "$DIR/bin/rule-miner.sh" 2>/dev/null; }

OUT=$(run)
RC=$?
[ "$RC" = 0 ] && ok || bad "dry run exited $RC"

# 1. a family at or above PROMOTE_MIN becomes an incident
grep -q 'findings:aaaaaaaaaaaa' <<<"$OUT" && ok \
  || bad "family crossing PROMOTE_MIN not bundled (out: $OUT)"
# 2. the summary carries the count and the projects, so the miner can weigh it
grep -qE 'findings:aaaaaaaaaaaa.*|recurred 3x in 30d' <<<"$OUT" && ok \
  || bad "incident summary missing the 30d count"
grep -q 'project-2,project-3\|project-3,project-2' <<<"$OUT" && ok \
  || bad "incident summary missing the distinct project list"
# 3. below-threshold families are NOT incidents
grep -q 'findings:bbbbbbbbbbbb' <<<"$OUT" && bad "a 2x family crossed PROMOTE_MIN=3" || ok
# 4. the 30-day window is real: 4 old occurrences do not count
grep -q 'findings:cccccccccccc' <<<"$OUT" && bad "findings older than 30d were counted" || ok

# 5. PROMOTE_MIN is env-tunable
OUT2=$(run env PROMOTE_MIN=2)
grep -q 'findings:bbbbbbbbbbbb' <<<"$OUT2" && ok \
  || bad "PROMOTE_MIN=2 should promote the 2x family"

# 6. the bundle body is real evidence, not just a count
# The family is named in the grep: by this point the PROMOTE_MIN=2 run above has
# also written the bbbb bundle, and `grep -rl ... | head -1` picked whichever the
# directory happened to list first.
B=$(grep -rl 'FAMILY: aaaaaaaaaaaa' "$T/state/rule-mining" 2>/dev/null | head -1)
[ -n "$B" ] && ok || bad "no recurring-finding bundle written"
if [ -n "$B" ]; then
  grep -q 'COUNT_30D: 3' "$B" && ok || bad "bundle missing COUNT_30D"
  grep -q 'RULES CITED: D14' "$B" && ok || bad "bundle missing the cited rules"
  grep -q 're-validates the target row' "$B" && ok || bad "bundle carries no real occurrences"
fi

# 7. seen.txt one-shot: a family already mined is never bundled again
echo "findings:aaaaaaaaaaaa" > "$T/state/rule-mining/seen.txt"
rm -rf "$T/state/rule-mining/$(date -u +%Y%m%d)"
OUT3=$(run)
grep -q 'findings:aaaaaaaaaaaa' <<<"$OUT3" && bad "seen.txt did not suppress a mined family" || ok

# 8. no findings.log at all -> the lane is simply absent, run still clean
rm -f "$FL" "$T/state/rule-mining/seen.txt"
rm -rf "$T/state/rule-mining/$(date -u +%Y%m%d)"
run >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "run with no findings.log exited $RC"

# ══ Round 2: findings from the adversarial review of PR #114 ═══════════════

# 9. FAMILY KEY POISONED BY BODY TEXT. The awk took the LAST family= token from
#    ALL fields, so a finding whose PROSE quotes `family=` reassigned the row —
#    the parser reading its own payload as metadata. Only the fields BEFORE the
#    `::` separator are metadata; everything after it is a reviewer's sentence.
: > "$FL"
for i in 1 2 3; do
  printf '%s 12:00:00Z [project-4] ticket=TK-%s lens=general verdict=BLOCK rule=D9 family=1111aaaa2222 :: the dedup keys on family=deadbeefcafe which is a tokenized URL, so it never fires\n' \
    "$TODAY" "$i" >> "$FL"
done
rm -rf "$T/state/rule-mining/$(date -u +%Y%m%d)" "$T/state/rule-mining/seen.txt"
OUT9=$(run)
grep -q 'findings:1111aaaa2222' <<<"$OUT9" && ok \
  || bad "the real family= field must win (out: $OUT9)"
grep -q 'findings:deadbeefcafe' <<<"$OUT9" \
  && bad "a family= quoted in the finding TEXT reassigned the row" || ok

# 10. family=- is the import-failure fallback, not a real family. Counting it
#     merges every unkeyed finding into one giant fake pattern.
: > "$FL"
for i in 1 2 3 4 5; do
  printf '%s 12:00:00Z [project-3] ticket=TK-%s lens=general verdict=BLOCK rule=- family=- :: unrelated finding number %s\n' \
    "$TODAY" "$i" "$i" >> "$FL"
done
rm -rf "$T/state/rule-mining/$(date -u +%Y%m%d)" "$T/state/rule-mining/seen.txt"
OUT10=$(run)
grep -q 'findings:-' <<<"$OUT10" \
  && bad "family=- (unkeyed fallback) counted as a real recurring family" || ok

# 11. TOPOLOGY: findings.log accumulates per-BOX, but the miner reads only the
#     hub's file. Source (c) harvests review.md from state/cost/remote-builds
#     mirrors; source (e) read a feed that structurally could not fill from
#     them — the dead-feed smell. The miner must findings-log the mirrors too.
: > "$FL"
MIRROR="$T/state/cost/remote-builds/project-3-TK-77-202608261200"
mkdir -p "$MIRROR"
cat > "$MIRROR/review.md" <<'EOF'
- **BLOCKING (D14):** the PATCH handler in `src/app/api/x/route.ts` resolves the caller's role but never re-validates the target row against the resolved org.
VERDICT: BLOCK
EOF
rm -rf "$T/state/rule-mining/$(date -u +%Y%m%d)" "$T/state/rule-mining/seen.txt"
run >/dev/null 2>&1
grep -q 'lens=general' "$FL" 2>/dev/null && ok \
  || bad "remote-build mirrors were never findings-logged (feed cannot fill)"
grep -q 'ticket=TK-77' "$FL" 2>/dev/null && ok \
  || bad "mirror harvest did not carry the ticket key"
grep -q '\[project-3\]' "$FL" 2>/dev/null && ok \
  || bad "mirror harvest did not carry the project"

# 12. the miner hands mechanizable drafts to guardrail-promote.sh, and that
#    script is the only thing that opens check PRs (never rule-miner itself)
grep -q 'guardrail-promote.sh' "$DIR/bin/rule-miner.sh" && ok \
  || bad "rule-miner.sh does not call the promotion lane"
grep -q 'gh pr merge' "$DIR/bin/guardrail-promote.sh" \
  && bad "the promotion lane has a merge path" || ok

# 13. THE OPTIONAL fraud= FIELD (2026-08-26). findings-log.sh now writes
#     `fraud=<class>` between rule= and family= when a reviewer tagged the
#     finding as one of the six fraud classes. The field walk above keys on
#     prefixes and stops at `::`, so it should ignore an unknown field — and
#     the failure if it does not is silent, not loud: tagged rows would stop
#     counting toward their family and the miner would simply mine less.
#
#     The `grep -aF "family=$FAM "` that fills the OCCURRENCES block is the
#     other half of the parse, and it is asserted here too: a bundle whose
#     evidence block came back empty would still look like a healthy bundle.
: > "$FL"
frow() { # frow <ticket> <fraud-class>
  printf '%s 12:00:00Z [project-3] ticket=TK-%s lens=general verdict=BLOCK rule=D1 fraud=%s family=9999bbbb8888 :: the acceptance test was replaced with an assertion that cannot fail\n' \
    "$TODAY" "$1" "$2" >> "$FL"
}
frow 30 weakened-tests
frow 31 false-completion
frow 32 weakened-tests
rm -rf "$T/state/rule-mining/$(date -u +%Y%m%d)" "$T/state/rule-mining/seen.txt"
OUT13=$(run)
grep -q 'findings:9999bbbb8888' <<<"$OUT13" && ok \
  || bad "fraud-tagged rows must still count toward their family (out: $OUT13)"
grep -q 'findings:weakened-tests\|findings:D1' <<<"$OUT13" \
  && bad "a fraud class (or rule) was read as the family key" || ok
B13=$(grep -rl 'FAMILY: 9999bbbb8888' "$T/state/rule-mining" 2>/dev/null | head -1)
[ -n "$B13" ] && ok || bad "no bundle written for the fraud-tagged family"
if [ -n "$B13" ]; then
  grep -q 'COUNT_30D: 3' "$B13" && ok || bad "fraud-tagged rows undercounted in the bundle"
  grep -q 'assertion that cannot fail' "$B13" && ok \
    || bad "the OCCURRENCES grep must still match a row carrying fraud= (family=<key><space> intact)"
fi

# ══ Round 3: REFUTED acceptance claims are an incident (source (c2), #548) ═══
# The evidence contract (bin/lib/evidence.sh, #527) scores a plan's acceptance
# claims into <build>/evidence.json. A REFUTED claim is the build saying one
# thing and its own artifacts saying another — the same shape as a review BLOCK,
# so it is mined the same way and keyed the same way (<kind>:<build>, seen.txt).
mkdir -p "$T/builds/p-K-1-202609160000" "$T/builds/p-K-2-202609160000" \
         "$T/builds/p-K-4-202609160000" "$T/builds/p-K-5-202609160000" \
         "$T/state/cost/remote-builds/q-K-3-202609160000"
printf '%s\n' '{"total":2,"confirmed":1,"refuted":1,"inconclusive":0,"claims":[{"n":2,"verdict":"REFUTED","claim":"x","artifact":"validate.txt:9","note":"exit 1","proposed":""}]}' \
  > "$T/builds/p-K-1-202609160000/evidence.json"
# refuted=0: a build whose claims all held is not an incident.
printf '%s\n' '{"total":1,"confirmed":1,"refuted":0,"inconclusive":0,"claims":[{"n":1,"verdict":"CONFIRMED","claim":"ok","artifact":"validate.txt:1","note":"exit 0","proposed":""}]}' \
  > "$T/builds/p-K-2-202609160000/evidence.json"
# A STRING count must not fire. jq sorts every string above every number, so a
# bare `.refuted > 0` reads "1" > 0 as true and mines a file it never parsed.
printf '%s\n' '{"refuted":"1","total":1,"confirmed":0,"inconclusive":0,"claims":[]}' \
  > "$T/state/cost/remote-builds/q-K-3-202609160000/evidence.json"
printf '%s\n' '{not json' > "$T/builds/p-K-4-202609160000/evidence.json"
# Mixed verdicts + a real RESULT: only the REFUTED rows belong in the bundle, and
# the terminal is the build's own first RESULT line.
printf '%s\n' '{"total":2,"confirmed":1,"refuted":1,"inconclusive":0,"claims":[{"n":1,"verdict":"CONFIRMED","claim":"ok","artifact":"validate.txt:1","note":"exit 0","proposed":""},{"n":2,"verdict":"REFUTED","claim":"z","artifact":"validate.txt:12","note":"exit 2","proposed":""}]}' \
  > "$T/builds/p-K-5-202609160000/evidence.json"
printf 'REVIEW_BLOCKED at 2026-09-16\n' > "$T/builds/p-K-5-202609160000/RESULT"

DAY="$T/state/rule-mining/${TODAY//-/}"
scratch_rm "$DAY"; rm -f "$T/state/rule-mining/seen.txt"
OUT14=$(run); RC=$?
[ "$RC" = 0 ] && ok || bad "the dry run over evidence.json fixtures exited $RC"
grep -q 'refuted:p-K-1-202609160000' <<<"$OUT14" && ok \
  || bad "a build with refuted=1 was not mined (out: $OUT14)"
grep -q 'acceptance claim(s) REFUTED in build p-K-1-202609160000' <<<"$OUT14" && ok \
  || bad "the inventory summary does not say what the incident is (out: $OUT14)"
grep -q 'refuted:p-K-2' <<<"$OUT14" \
  && bad "a build whose claims all held was mined as an incident" || ok
grep -q 'refuted:q-K-3' <<<"$OUT14" \
  && bad "a string-typed refuted count fired an incident" || ok
grep -q 'refuted:p-K-4' <<<"$OUT14" \
  && bad "an unparseable evidence.json fired an incident" || ok

# The bundle is evidence, not a count: the file it came from, the terminal, and
# the REFUTED claims themselves.
# TEST-CHANGE (BH-1763 x BH-1764): since BH-1764 the run also writes digest.md
# (and digest-ids.txt) into the same day dir, and since BH-1763 the digest
# quotes each incident's excerpt, "BUILD: <id>" included. `grep -rl | head -1`
# then picked the digest instead of the incident's own bundle. The lookups
# exclude the digest files; every assertion on the bundle is unchanged.
B14=$(grep -rl --exclude='digest*' 'BUILD: p-K-1-202609160000' "$DAY" 2>/dev/null | head -1)
[ -n "$B14" ] && ok || bad "no refuted-claim bundle was written"
if [ -n "$B14" ]; then
  grep -q '^TYPE: refuted-claim' "$B14" && ok || bad "the bundle carries no TYPE line"
  grep -qF "FILE: $T/builds/p-K-1-202609160000/evidence.json" "$B14" && ok \
    || bad "the bundle does not name the evidence.json it was mined from"
  grep -q '^RESULT: (no RESULT file)' "$B14" && ok \
    || bad "a build with no RESULT must say so, not render an empty terminal"
  grep -qF 'CLAIM 2: x :: validate.txt:9 :: exit 1' "$B14" && ok \
    || bad "the bundle carries no REFUTED claim rows: $(cat "$B14")"
fi
B14M=$(grep -rl --exclude='digest*' 'BUILD: p-K-5-202609160000' "$DAY" 2>/dev/null | head -1)
[ -n "$B14M" ] && ok || bad "the mixed-verdict build was not mined"
if [ -n "$B14M" ]; then
  [ "$(grep -c '^CLAIM ' "$B14M")" = 1 ] && ok \
    || bad "the bundle lists claims that were not REFUTED: $(grep '^CLAIM ' "$B14M")"
  grep -qF 'CLAIM 2: z :: validate.txt:12 :: exit 2' "$B14M" && ok \
    || bad "the REFUTED row of a mixed build is missing: $(cat "$B14M")"
  grep -q '^RESULT: REVIEW_BLOCKED at 2026-09-16' "$B14M" && ok \
    || bad "the bundle does not carry the build's own RESULT line: $(cat "$B14M")"
fi
# This source mines; it does not write findings.log (that is findings-log.sh's).
grep -q 'refuted' "$FL" 2>/dev/null \
  && bad "source (c2) wrote a row into findings.log" || ok

# seen.txt one-shot, exactly as every other incident here.
echo 'refuted:p-K-1-202609160000' >> "$T/state/rule-mining/seen.txt"
scratch_rm "$DAY"
OUT14B=$(run)
grep -q 'refuted:p-K-1' <<<"$OUT14B" \
  && bad "seen.txt did not suppress an already-mined REFUTED build" || ok

echo "rule-miner-findings-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
