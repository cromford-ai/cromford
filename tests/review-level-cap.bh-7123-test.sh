#!/bin/bash
# tests/review-level-cap.bh-7123-test.sh — BH-7123: review strictness scales to
# user impact. bin/lib/review-level.sh's rl_cap demotes a BLOCK that names no
# ALWAYS-BLOCK class to a NOTE and flips a verdict with no standing BLOCK.
#
# The fixtures are real review findings from project-6 and project-5
# (2026-09-25..10-16, docs/REVIEW_SEVERITY_AUDIT_2026-10-16.html), quoted.
#
#   A1  review-prs shape: three nits tagged [BLOCK]/[HIGH]/[MEDIUM] (a request
#       memo, sortable headers, a 2 px padding) -> all three NOTE, verdict
#       REQUEST_CHANGES -> APPROVE, the marker line sits above TIER:
#   A2  a cross-company read tagged [LOW] and an authz hole with no class tag
#       both STAND (the class ERE catches a model that forgot the tag);
#       a tagged [BLOCK tenant-leak] stands; verdict stays REQUEST_CHANGES
#   A3  speed: "+100 ms" with no class -> NOTE; a perf BLOCK the model classed
#       is not this lib's call (loc_cap owns perf tickets) -> stays as tagged
#   A4  in-build shape (VERDICT: BLOCK/APPROVE, appended rounds): only the
#       final round is rewritten; NEEDS_HUMAN "run e2e with the Clerk dev keys"
#       -> NOTE not verified here; NEEDS_HUMAN "add the live Stripe key" stands
#   A5  settings: REVIEW_LEVEL_MODE=strict leaves the file byte-identical and
#       rc 1; shadow logs WOULD, changes nothing, rc 1; a bad mode value falls
#       back to levels
#   A6  idempotent: a second rl_cap on a capped file changes nothing
#   A7  lead shape: `- [BLOCK] path:line:` nits -> NOTE and VERDICT: BLOCK ->
#       MERGE-WITH-NOTES; `- [BLOCK needs-human]` on a Lighthouse run -> NOTE;
#       on a product decision -> stands
#   A8  "CI cancelled" is not red-build: a [HIGH] "ci shows cancelled" demotes
#   A9  mutation: with the always-block catalog emptied, A2's tenant leak
#       would demote (so the catalog is load-bearing, not the regex in code)
#   A10 rl_prompt_note renders the mode and the thresholds, env knob wins
# Run: HARNESS_TEST_SANDBOX=1 bash tests/review-level-cap.bh-7123-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$DIR"
unset REVIEW_LEVEL_MODE REVIEW_LEVEL_PERF_BLOCK_MS REVIEW_LEVEL_PERF_BLOCK_STMT_PCT REVIEW_LEVEL_CORE_FLOWS
# No setting_get in this shell: the lib falls back to its defaults (levels).
. "$DIR/bin/lib/review-level.sh" || { echo "FAIL: cannot source bin/lib/review-level.sh"; exit 1; }
. "$DIR/bin/lib/verdict-parse.sh" 2>/dev/null || true

# ── A1 review-prs nits ────────────────────────────────────────────────────────
cat > "$T/a1.md" <<'EOF'
Static review without build verification. Three findings.

1. **[BLOCK – BH-6946, repeated config read without a request memo]** src/app/os/settings/channels/config-notice.tsx:23: ConfigNoticeBody calls channelLive(id). load.ts:23 reads the same runtime_setting row in the same request. Fix: read once in load.ts and pass it down.
2. **[HIGH] The "What it cost" table headers are plain <th>.** run-body.tsx:40. They do not sort, show no direction and have no aria-sort. Fix: use SortableTable.
3. **[MEDIUM] Card padding is 14 px, the prototype has 16 px.** card.tsx:12. Fix: p-4.

TIER: 2
VERDICT: REQUEST_CHANGES
EOF
out=$(rl_cap "$T/a1.md" project-6-os --approve APPROVE --block REQUEST_CHANGES --lens prs 2>"$T/a1.err"); rc=$?
[ "$rc" = 0 ] && ok || bad "A1 rl_cap rc $rc: $(cat "$T/a1.err")"
grep -q 'mode=levels demoted=3 standing=0 verdict=APPROVE' <<<"$out" && ok || bad "A1 summary: $out"
grep -qE '^VERDICT: APPROVE$' "$T/a1.md" && ok || bad "A1 verdict line not flipped: $(grep -n VERDICT "$T/a1.md")"
[ "$(grep -c 'NOTE demoted from' "$T/a1.md")" = 3 ] && ok || bad "A1 expected 3 demoted lines: $(grep -c 'NOTE demoted from' "$T/a1.md")"
grep -q '^1\. \*\*\[NOTE demoted from BLOCK – BH-6946' "$T/a1.md" && ok || bad "A1 the bracketed BLOCK tag was not rewritten in place"
grep -q '^2\. \*\*\[NOTE demoted from HIGH\]' "$T/a1.md" && ok || bad "A1 the [HIGH] tag was not rewritten"
# The marker sits above TIER:, the verdict stays the last line.
awk '/^Review level \(BH-7123\)/{m=NR} /^TIER:/{t=NR} /^VERDICT:/{v=NR} END{exit !(m && t && v && m<t && t<v)}' "$T/a1.md" && ok || bad "A1 marker/TIER/VERDICT order wrong: $(tail -4 "$T/a1.md")"
if command -v verdict_parse >/dev/null 2>&1; then
  [ "$(verdict_parse -w 'APPROVE|REQUEST_CHANGES' "$T/a1.md" 2>/dev/null)" = APPROVE ] && ok || bad "A1 verdict_parse does not read APPROVE from the capped file"
fi

# ── A2 real harm stands, tag or no tag ───────────────────────────────────────
cat > "$T/a2.md" <<'EOF'
Static review.

1. **[LOW] Any company request can read every company's spend.** supabase/sql/0031.sql:4: the function is SECURITY DEFINER and granted to the app role. Fix: scope by company_id.
2. **[HIGH] A client can still read company data through the API.** 26 API routes gate only on requireMember(). Fix: requireRole('owner') on the write routes.
3. **[BLOCK tenant-leak]** src/lib/clients.ts:88: listClients() has no companyId filter.
4. **[MEDIUM] The comments in two files now contradict the code.** load.ts:3.

TIER: 2
VERDICT: REQUEST_CHANGES
EOF
out=$(rl_cap "$T/a2.md" project-6-os --approve APPROVE --block REQUEST_CHANGES --lens prs 2>/dev/null); rc=$?
grep -q 'demoted=1 standing=3 verdict=REQUEST_CHANGES' <<<"$out" && ok || bad "A2 summary: $out"
grep -qE '^VERDICT: REQUEST_CHANGES$' "$T/a2.md" && ok || bad "A2 verdict must stay REQUEST_CHANGES"
grep -q '^1\. \*\*\[LOW\] Any company request' "$T/a2.md" && ok || bad "A2 the LOW-tagged tenant leak was rewritten"
grep -q '^4\. \*\*\[NOTE demoted from MEDIUM\]' "$T/a2.md" && ok || bad "A2 the comment nit was not demoted"
rl_line_blocks '2. **[HIGH]** Grants outlive membership: authz' && ok || bad "A2 'authz' alone must stand"
rl_line_blocks '1. **[HIGH]** The user erase is per company, but it deletes data from every company' && ok || bad "A2 'deletes data from every company' must stand"
rl_line_blocks '1. **[HIGH]** 4xx refusals become fake spend and trip the spend limit' && ok || bad "A2 money must stand"
rl_line_blocks '1. **[BLOCKER]** Typecheck OOM: build is red' && ok || bad "A2 red build must stand"
rl_line_blocks '1. **[HIGH]** Publish can delete a newer draft that nobody published' && ok || bad "A2 data loss must stand"
rl_line_blocks '7. **[NIT]** clock() writes 8:00, but the UTC labels write 08:00. Pick one format.' && bad "A2 a NIT about time format must not stand" || ok

# ── A3 speed with no class is a note ─────────────────────────────────────────
cat > "$T/a3.md" <<'EOF'
1. **[HIGH] Library is +100 ms on the second run.** The replay table shows +0.02 to +0.04 s on Home and Drafts and +100 ms on Library.
2. **BLOCK (performance iron law: speed claim without numbers): the PR has no "after" numbers.** The body gives "before" numbers only.

TIER: 2
VERDICT: REQUEST_CHANGES
EOF
out=$(rl_cap "$T/a3.md" project-5 --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'demoted=2 standing=0 verdict=APPROVE' <<<"$out" && ok || bad "A3 summary: $out"
grep -q '^2\. \*\*NOTE demoted from BLOCK (performance iron law' "$T/a3.md" && ok || bad "A3 the unbracketed BLOCK tag was not rewritten"

# ── A4 in-build shape: final round only, NEEDS_HUMAN split ───────────────────
cat > "$T/a4.md" <<'EOF'
## Review — TK-900
- [BLOCK] src/x.ts:1: a real earlier finding
TIER: 2
VERDICT: BLOCK
=== Re-review after fixes
Findings:
- [BLOCK] src/app/library/page.tsx:40: the second run measured +0.02 to +0.04 s on Home and Drafts; the perf proof table is missing.
- [BLOCK] the design-guard did not run on this box.
NEEDS_HUMAN: On a host with Chromium and the Clerk dev keys, run npm run build && npm run design-guard and npm run e2e -- tests/e2e/settings-polish.TK-594.spec.ts
NEEDS_HUMAN: add the live Stripe key on Vercel before go-live
TIER: 2
VERDICT: BLOCK
EOF
out=$(rl_cap "$T/a4.md" project-6-os --approve APPROVE --block BLOCK --lens inbuild 2>/dev/null)
grep -q 'demoted=3 standing=1 verdict=BLOCK' <<<"$out" && ok || bad "A4 summary: $out"
grep -q '^- \[BLOCK\] src/x.ts:1' "$T/a4.md" && ok || bad "A4 the earlier round was rewritten"
grep -q '^NOTE not verified here (demoted, BH-7123): On a host with Chromium' "$T/a4.md" && ok || bad "A4 the Clerk-keys verification was not demoted"
grep -q '^NEEDS_HUMAN: add the live Stripe key' "$T/a4.md" && ok || bad "A4 the go-live step was demoted"
[ "$(grep -c '^VERDICT: BLOCK$' "$T/a4.md")" = 2 ] && ok || bad "A4 a verdict changed with a go-live step standing"
# The same file without the go-live line flips.
grep -v 'live Stripe key' "$T/a4.md" | grep -v '^Review level' | sed 's/NOTE not verified here (demoted, BH-7123): /NEEDS_HUMAN: /; s/\[NOTE demoted from BLOCK\]/[BLOCK]/' > "$T/a4b.md"
out=$(rl_cap "$T/a4b.md" project-6-os --approve APPROVE --block BLOCK --lens inbuild 2>/dev/null)
grep -q 'standing=0 verdict=APPROVE' <<<"$out" && ok || bad "A4b summary: $out"
[ "$(sed -n '$p' "$T/a4b.md")" = "VERDICT: APPROVE" ] && ok || bad "A4b last line: $(sed -n '$p' "$T/a4b.md")"
if command -v verdict_is >/dev/null 2>&1; then
  verdict_is APPROVE -L "$T/a4b.md" && ok || bad "A4b verdict_is -L does not read APPROVE"
fi

# ── A5 modes ─────────────────────────────────────────────────────────────────
cp "$T/a1.md" "$T/a5.md"; sed -i.bak '/^Review level (BH-7123)/d; s/NOTE demoted from /BLOCK /; s/^VERDICT: APPROVE$/VERDICT: REQUEST_CHANGES/' "$T/a5.md" 2>/dev/null || sed -i '' '/^Review level (BH-7123)/d; s/NOTE demoted from /BLOCK /; s/^VERDICT: APPROVE$/VERDICT: REQUEST_CHANGES/' "$T/a5.md"
rm -f "$T/a5.md.bak"; cp "$T/a5.md" "$T/a5.orig"
out=$(REVIEW_LEVEL_MODE=strict rl_cap "$T/a5.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null); rc=$?
[ "$rc" = 1 ] && cmp -s "$T/a5.md" "$T/a5.orig" && ok || bad "A5 strict must not rewrite (rc $rc)"
out=$(REVIEW_LEVEL_MODE=shadow rl_cap "$T/a5.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>"$T/a5.err"); rc=$?
[ "$rc" = 1 ] && cmp -s "$T/a5.md" "$T/a5.orig" && ok || bad "A5 shadow must not rewrite (rc $rc)"
grep -q 'WOULD demote 3 finding(s), 0 standing, verdict REQUEST_CHANGES -> APPROVE (shadow' "$T/a5.err" && ok || bad "A5 shadow log: $(cat "$T/a5.err")"
grep -q 'mode=shadow demoted=3' <<<"$out" && ok || bad "A5 shadow summary: $out"
[ "$(REVIEW_LEVEL_MODE=bogus rl_mode project-6-os)" = levels ] && ok || bad "A5 a bad mode value must fall back to levels"
[ "$(REVIEW_LEVEL_MODE=cowboy rl_mode x)" = cowboy ] && ok || bad "A5 env knob not read"
out=$(REVIEW_LEVEL_MODE=cowboy rl_cap "$T/a5.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'mode=cowboy demoted=3 standing=0 verdict=APPROVE' <<<"$out" && ok || bad "A5 cowboy: $out"
# cowboy never demotes the floor.
cp "$T/a2.md" "$T/a5c.md"; sed -i.bak '/^Review level (BH-7123)/d' "$T/a5c.md" 2>/dev/null || sed -i '' '/^Review level (BH-7123)/d' "$T/a5c.md"; rm -f "$T/a5c.md.bak"
out=$(REVIEW_LEVEL_MODE=cowboy rl_cap "$T/a5c.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'standing=3 verdict=REQUEST_CHANGES' <<<"$out" && ok || bad "A5 cowboy demoted the floor: $out"

# ── A6 idempotent ────────────────────────────────────────────────────────────
cp "$T/a1.md" "$T/a6.before"
out=$(rl_cap "$T/a1.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null); rc=$?
[ "$rc" = 0 ] && cmp -s "$T/a1.md" "$T/a6.before" && ok || bad "A6 a second rl_cap changed the file (rc $rc)"
grep -q 'demoted=3 standing=0 verdict=APPROVE' <<<"$out" && ok || bad "A6 second summary: $out"

# ── A7 lead shape ────────────────────────────────────────────────────────────
cat > "$T/a7.md" <<'EOF'
Findings

- [BLOCK] worker/jobs/src/routes/x.js:12: the comment says 60 s but the cache window is 90 s
- [BLOCK] docs/notes/2026-10-16.md:3: the change note is missing the knob name
- [BLOCK needs-human] tests/perf.md:1: run Lighthouse mobile 3x on main and 3x on this branch with the audit seed
- [BLOCK needs-human] src/flow.ts:9: the operator must decide the Fireflies auth before this ships
- [NOTE] bin/x.sh:4: the log line could name the pr

VERDICT: BLOCK
EOF
out=$(rl_cap "$T/a7.md" cromford --approve MERGE-WITH-NOTES --block BLOCK --lens lead 2>/dev/null)
grep -q 'demoted=3 standing=1 verdict=BLOCK' <<<"$out" && ok || bad "A7 summary: $out"
grep -q '^- \[NOTE not verified here, demoted from BLOCK needs-human\] tests/perf.md:1: run Lighthouse' "$T/a7.md" && ok || bad "A7 the Lighthouse human step was not demoted"
grep -q '^- \[BLOCK needs-human\] src/flow.ts:9: the operator must decide' "$T/a7.md" && ok || bad "A7 the product decision was demoted"
# Same report without the decision line, tags restored: now nothing stands.
sed -i.bak '/operator must decide/d; /^Review level/d; s/\[NOTE demoted from BLOCK\]/[BLOCK]/' "$T/a7.md" 2>/dev/null || sed -i '' '/operator must decide/d; /^Review level/d; s/\[NOTE demoted from BLOCK\]/[BLOCK]/' "$T/a7.md"; rm -f "$T/a7.md.bak"
out=$(rl_cap "$T/a7.md" cromford --approve MERGE-WITH-NOTES --block BLOCK --lens lead 2>/dev/null)
[ "$(sed -n '$p' "$T/a7.md")" = "VERDICT: MERGE-WITH-NOTES" ] && ok || bad "A7 lead verdict not flipped: $(sed -n '$p' "$T/a7.md")"
awk '/^Review level \(BH-7123\)/{m=NR} /^VERDICT:/{v=NR} END{exit !(m && v && m<v)}' "$T/a7.md" && ok || bad "A7 marker must sit above the verdict"

# ── A8 cancelled CI is not red ───────────────────────────────────────────────
printf '1. **[HIGH] No CI test run on head 36f816f.** The ci workflow and its ci check both show cancelled (run 38495976410).\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$T/a8.md"
out=$(rl_cap "$T/a8.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'demoted=1 standing=0 verdict=APPROVE' <<<"$out" && ok || bad "A8 cancelled CI must demote: $out"
printf '1. **[HIGH] CI is red on this head: the typecheck fails in src/x.ts.**\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$T/a8b.md"
out=$(rl_cap "$T/a8b.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'standing=1 verdict=REQUEST_CHANGES' <<<"$out" && ok || bad "A8b a failing typecheck must stand: $out"

# ── A9 mutation: the catalog is load-bearing ─────────────────────────────────
M="$T/mut"; mkdir -p "$M/catalog"
scratch_install_closure bin/lib/review-level.sh "$M" >/dev/null || bad "A9 closure install of bin/lib/review-level.sh"
cp "$DIR/catalog/review-golive.tsv" "$DIR/catalog/review-nits.tsv" "$M/catalog/"
printf '# emptied\n' > "$M/catalog/review-always-block.tsv"
# With the always-block catalog emptied there are no classes either: the
# model's `[BLOCK model-id]` is no longer a recognised tag, so the grammar
# guard sees no class and every untagged BLOCK-word line STANDS (the fail-safe:
# with no catalog the demoter can only drop known noise, never a real bug). The
# padding line is known noise and still demotes; the verdict stays.
printf '1. **[HIGH] A client can still read company data through the API.** 26 API routes gate only on requireMember().\n2. **[BLOCK model-id]** src/x.ts:3: a hardcoded claude-opus-4-8 string.\n3. **[MEDIUM]** card.tsx:12: 2 px of padding.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$T/a9.md"
out=$(HARNESS="$M" bash -c '. "$0/bin/lib/review-level.sh"; rl_cap "$1" p --approve APPROVE --block REQUEST_CHANGES 2>/dev/null' "$M" "$T/a9.md")
grep -q 'demoted=1 standing=2 verdict=REQUEST_CHANGES untagged=2' <<<"$out" && ok || bad "A9 with an empty catalog the untagged lines must stand (fail-safe) and only the nit demotes: $out"
printf '1. **[HIGH] A client can still read company data through the API.** 26 API routes gate only on requireMember().\n2. **[BLOCK model-id]** src/x.ts:3: a hardcoded claude-opus-4-8 string.\n3. **[MEDIUM]** card.tsx:12: 2 px of padding.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$T/a9b.md"
out=$(rl_cap "$T/a9b.md" p --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'demoted=1 standing=2 verdict=REQUEST_CHANGES' <<<"$out" && ok || bad "A9b with the real catalog the leak and the classed line stand, the padding demotes: $out"

# ── A10 prompt note ──────────────────────────────────────────────────────────
note=$(rl_prompt_note project-6-os)
grep -q '## Review level (BH-7123)' <<<"$note" && ok || bad "A10 no heading"
grep -q 'mode: levels' <<<"$note" && ok || bad "A10 default mode missing: $note"
grep -q 'over 300 ms or over 20% more DB statements' <<<"$note" && ok || bad "A10 default thresholds missing: $note"
note=$(REVIEW_LEVEL_PERF_BLOCK_MS=50 REVIEW_LEVEL_CORE_FLOWS='sign-in, scan' rl_prompt_note project-5)
grep -q 'over 50 ms' <<<"$note" && grep -q 'Core flows of this project (project-5): sign-in, scan' <<<"$note" && ok || bad "A10 env knobs not rendered: $note"

# ── A11 the grammar guard: an untagged real bug stands when the model used no tags ─
cat > "$T/a11.md" <<'EOF'
1. **[HIGH] The describe form changes a stored weekday time on save.** src/forms/describe.tsx:88: the local time is written back as UTC.
2. **[MEDIUM] Card padding is 14 px, the prototype has 16 px.** card.tsx:12.

TIER: 2
VERDICT: REQUEST_CHANGES
EOF
out=$(rl_cap "$T/a11.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'demoted=1 standing=1 verdict=REQUEST_CHANGES untagged=1' <<<"$out" && ok || bad "A11 grammar guard: $out"
grep -q '^1\. \*\*\[HIGH\] The describe form' "$T/a11.md" && ok || bad "A11 the untagged real bug was rewritten"
grep -q '1 untagged finding(s) kept (grammar not used)' "$T/a11.md" && ok || bad "A11 marker does not report the untagged line"
# A12 a [NOTE] alone is NOT grammar evidence (the lead lane wrote [BLOCK]/[NOTE]
# before the classes existed): the untagged real bug stands and, with nothing
# demoted, the file is byte-identical.
cat > "$T/a12.md" <<'EOF'
1. **[HIGH] The describe form changes a stored weekday time on save.** src/forms/describe.tsx:88.
2. **[NOTE] Card padding is 14 px, the prototype has 16 px.** card.tsx:12.

TIER: 2
VERDICT: REQUEST_CHANGES
EOF
cp "$T/a12.md" "$T/a12.orig"
out=$(rl_cap "$T/a12.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null); rc=$?
grep -q 'demoted=0 standing=1 verdict=REQUEST_CHANGES untagged=1' <<<"$out" && ok || bad "A12 NOTE alone is not grammar: $out"
[ "$rc" = 0 ] && cmp -s "$T/a12.md" "$T/a12.orig" && ok || bad "A12 nothing demoted must leave the file byte-identical (rc $rc)"
# A12b the model used a class tag once: the untagged [HIGH] is its own call
# and demotes; the classed line stands. This is the designed trade-off; the
# prompt makes the model tag every finding, and the floor catches a forgotten
# tag on tenant, auth, money, data and build.
cat > "$T/a12b.md" <<'EOF'
1. **[HIGH] The describe form changes a stored weekday time on save.** src/forms/describe.tsx:88.
2. **[BLOCK tenant-leak]** src/lib/clients.ts:88: listClients() has no companyId filter.

TIER: 2
VERDICT: REQUEST_CHANGES
EOF
out=$(rl_cap "$T/a12b.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'demoted=1 standing=1 verdict=REQUEST_CHANGES untagged=0' <<<"$out" && ok || bad "A12b grammar used: $out"
# A15 a verdict with no recognisable finding lines is the model's: untouched.
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$T/a15.md"; cp "$T/a15.md" "$T/a15.orig"
out=$(rl_cap "$T/a15.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null); rc=$?
[ "$rc" = 0 ] && cmp -s "$T/a15.md" "$T/a15.orig" && grep -q 'demoted=0 standing=0 verdict=REQUEST_CHANGES' <<<"$out" && ok || bad "A15 a findings-less REQUEST_CHANGES must stand untouched (rc $rc): $out"
# A13 the same bug the model tagged with its class stands whatever else it wrote.
printf '1. **[BLOCK wrong-data]** src/forms/describe.tsx:88: the describe form changes a stored weekday time on save.\n2. **[NOTE]** card.tsx:12: padding.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$T/a13.md"
out=$(rl_cap "$T/a13.md" project-6-os --approve APPROVE --block REQUEST_CHANGES 2>/dev/null)
grep -q 'demoted=0 standing=1 verdict=REQUEST_CHANGES' <<<"$out" && ok || bad "A13 a classed BLOCK must stand: $out"
# A14 known noise demotes even with no grammar: the nit catalog is load-bearing.
rl_line_nit '2. **[MEDIUM] Two migration files share the number 0032.**' && ok || bad "A14 migration number is noise"
rl_line_nit '8. **[MEDIUM] No EXPLAIN proof for the new queries (iron law).**' && ok || bad "A14 EXPLAIN proof is noise"
rl_line_nit '1. **[HIGH] CI did not run to completion on 56009b0c.** the ci check shows cancelled' && ok || bad "A14 cancelled CI is noise"
rl_line_nit '1. **[HIGH] A client can still read company data through the API.**' && bad "A14 a tenant leak is not noise" || ok

echo "review-level-cap.bh-7123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
