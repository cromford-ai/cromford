#!/bin/bash
# tests/lead-gates-perf-ticket.bh-8362-test.sh — the perf trigger of the
# pre-review self-check (bin/lib/pr-self-check.sh `_psc_perf`, the row
# catalog/pr-self-check.d/bh-6372-outcome-replay.tsv) as the worklist's gate 75
# holds it. bin/lib/lead-gates-selfcheck.sh `lgsc_run` passes the linked
# issue's title, labels, repo and number to psc_check, so a ticket that is perf
# by its label, or by its one parent hop, is held like the enqueue held it.
# Every case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh,
# lead-gates-fixture.bh-5876.sh) on a real head in the clone.
#   PT0  issue 41 labelled perf, a body with a full `## Outcome replay`
#        section: one job, no comment names body-outcome-replay.
#   PT1  the same issue, no section: no job, ONE comment that names
#        body-outcome-replay, only issue 41 read.
#   PT2  the #5454 body, ticket #5368 (`BH-5354.2:`), parent #5354: no job,
#        the comment names the rule, unique issue reads `5368 5354`, 5354 once.
#   PT3  ticket #6049 (not perf), no section: one job, no such comment.
#   PT4  the issue read answers 500, no section: one job, no such comment.
#   M1   the lib without the 4 PSC_TICKET_* vars: PT1's PR gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-perf-ticket.bh-8362-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset PR_SELF_CHECK PR_SELF_CHECK_MAX_WAIT_MIN PR_SELF_CHECK_CATALOG PERF_TICKET_CATALOG
unset PSC_TICKET_FILE PSC_TICKET_TITLE PSC_TICKET_LABELS PSC_TICKET_REPO PSC_TICKET_N
lwf_setup
lgf_setup
lg6_setup
LIB="$H/bin/lib/lead-gates-selfcheck.sh"
SRCFX="$LWF_SRC/tests/fixtures/bh-6372"
for f in bin/lib/lead-gates-selfcheck.sh bin/lib/pr-self-check.sh bin/lib/perf-ticket.sh; do
  [ -r "$LWF_SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
for n in 5354 5368 6049; do [ -r "$SRCFX/issue-$n.json" ] || bad "setup: fixture issue-$n.json missing"; done
cp "$LWF_SRC/catalog/perf-ticket.tsv" "$H/catalog/"

# This suite's own files ($FX is the fixture's dir).
P="$T/perf"; mkdir -p "$P"
# A gh layer for the linked issues: GET issues/<n> answers $P/issue.<n>.json
# whole (title, labels, body), 404 when absent, 500 when $P/issuefail.<n>
# exists; each read appends <n> to $T/log/issue-reads.
mv "$T/fakebin/gh" "$T/fakebin/gh.5876"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/issues/([0-9]+)(\ |\$) ]]; then
  n="\${BASH_REMATCH[1]}"
  printf '%s\n' "\$a" >> "$T/log/gh"
  echo "\$n" >> "$T/log/issue-reads"
  if [ -e "$P/issuefail.\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  if [ -r "$P/issue.\$n.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$P/issue.\$n.json"; exit 0; fi
  printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; exit 1
fi
exec "$T/fakebin/gh.5876" "\$@"
EOF
chmod +x "$T/fakebin/gh"

TGT='Target metric: mq-full-share from 0.92 to 0.30'
jq -nc '{number:41, title:"Speed up the batch", body:"## Done when\n- the suite passes\n", labels:[{name:"perf"}]}' > "$P/issue.41.json"
cp "$SRCFX/issue-5368.json" "$P/issue.5368.json"
cp "$SRCFX/issue-5354.json" "$P/issue.5354.json"
cp "$SRCFX/issue-6049.json" "$P/issue.6049.json"
B_NONE=$(printf 'Closes #41\n\n%s' "$LG6_BODY")
B_FULL=$(printf 'Closes #41\n\n%s\n## Outcome replay\n%s\nmeasured 0.31\n' "$LG6_BODY" "$TGT")
B_5454=$(jq -r '.body // ""' "$SRCFX/pr-5454.json")
B_6049=$(printf 'Closes #6049\n\n%s' "$LG6_BODY")

# one <pr> <head> <body> — PR <pr> on <head>, titled BH-41, with both catalogs
one() {
  lg6_reset none; lgf_needs "$1:$2"
  rm -f "$T/log/issue-reads" "$P"/issuefail.*
  printf '%s' "$3" > "$FX/body.$1"; echo "BH-41: the batch" > "$FX/title.$1"
  lg6_catalog; cp -r "$LWF_SRC/catalog/pr-self-check.d" "$H/catalog/"
}
named() { grep -qF 'body-outcome-replay' "$T/log/comments.$1" 2>/dev/null; }
ureads() { awk '!s[$0]++' "$T/log/issue-reads" 2>/dev/null | paste -sd' ' -; }
headfor() {
  local p
  p=$(lg6_head "$1" .harness/specs/BH-41/plan.md $'# plan\n\n## Files to touch\n- `bin/a.sh`\n\n## Acceptance tests\n- a test') || return 1
  lg6_head "$1" bin/a.sh a "$p"
}
for n in 150 151 152 153 154 155; do
  eval "H$n=\$(headfor $n)" || bad "setup: the head of PR $n"
done

# ── PT0: perf by label, a full section: a job, no hold ──
one 150 "$H150" "$B_FULL"
lwf_tick
[ "$(lgf_jobs 150)" = 1 ] && ok || bad "PT0 no job for a perf PR with the section: $(cat "$L") $(cat "$T/log/comments.150" 2>/dev/null)"
named 150 && bad "PT0 a comment names body-outcome-replay: $(cat "$T/log/comments.150")" || ok

# ── PT1: perf by label, no section: held, one comment names the rule ──
one 151 "$H151" "$B_NONE"
lwf_tick
[ "$(lgf_jobs 151)" = 0 ] && ok || bad "PT1 a job for a perf PR with no section: $(cat "$L")"
[ "$(lg6_comments 151)" = 1 ] && named 151 && ok \
  || bad "PT1 want one comment naming body-outcome-replay, got $(lg6_comments 151): $(cat "$T/log/comments.151" 2>/dev/null)"
[ "$(ureads)" = 41 ] && ok || bad "PT1 want only issue 41 read, got '$(ureads)'"

# ── PT2: the #5454 body, #5368 ticket, #5354 parent: held after one hop ──
one 152 "$H152" "$B_5454"
lwf_tick
[ "$(lgf_jobs 152)" = 0 ] && ok || bad "PT2 a job for the #5454 body: $(cat "$L")"
named 152 && ok || bad "PT2 no comment names body-outcome-replay: $(cat "$T/log/comments.152" 2>/dev/null)"
[ "$(ureads)" = "5368 5354" ] && ok || bad "PT2 want unique issue reads '5368 5354', got '$(ureads)'"
[ "$(grep -cx 5354 "$T/log/issue-reads" 2>/dev/null)" = 1 ] && ok \
  || bad "PT2 want 5354 read once, got $(grep -cx 5354 "$T/log/issue-reads" 2>/dev/null)"

# ── PT3: a real non-perf ticket, no section: a job, no hold ──
one 153 "$H153" "$B_6049"
lwf_tick
[ "$(lgf_jobs 153)" = 1 ] && ok || bad "PT3 no job for the non-perf #6049: $(cat "$L") $(cat "$T/log/comments.153" 2>/dev/null)"
named 153 && bad "PT3 a comment names body-outcome-replay: $(cat "$T/log/comments.153")" || ok

# ── PT4: the issue read fails: no ticket text is a NOTE, never a hold ──
one 154 "$H154" "$B_NONE"
: > "$P/issuefail.41"
lwf_tick
[ "$(lgf_jobs 154)" = 1 ] && ok || bad "PT4 no job on a failed issue read: $(cat "$L") $(cat "$T/log/comments.154" 2>/dev/null)"
named 154 && bad "PT4 a comment names body-outcome-replay: $(cat "$T/log/comments.154")" || ok
rm -f "$P/issuefail.41"

# ── M1: the lib passes no ticket title, labels, repo or number: PT1 gets a job ──
cp "$LIB" "$T/lgsc.keep"
sed -i -E 's/PSC_TICKET_(TITLE|LABELS|REPO|N)="[^"]*" ?//g' "$LIB"
grep -q 'PSC_TICKET_' "$LIB" && bad "M1 the mutation left a PSC_TICKET_ assignment"
one 155 "$H155" "$B_NONE"
lwf_tick
[ "$(lgf_jobs 155)" = 1 ] && ok || bad "M1 no job with the PSC_TICKET_* vars gone: $(cat "$L")"
cp "$T/lgsc.keep" "$LIB"

echo "lead-gates-perf-ticket.bh-8362: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
