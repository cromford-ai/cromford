#!/bin/bash
# tests/sql-ident-sites.bh-6525-test.sh — the route files that sort after
# lanes.js (BH-6525, BH-6514.4), plus retention.js, carry a sql-ident marker on
# every run-time `prepare(` site and no baseline fragment. S1 --print over the
# 30 files is rc 0 with 48+ rows, every one `marked`. S2 each marker holds a
# reason with a word of 3+ letters. S3 none of the 30 files has a fragment.
# S4 the lint over the whole checkout is rc 0, 0 over.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
LINT="$REPO/bin/sql-ident-lint.sh"
FRAG="$REPO/tests/fixtures/sql-ident-baseline"
M="sql-ident""-ok:"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }

NAMES="lead-protected-paths llm-site-rows main-red merge-queue-live merge-queue-reconcile
model-routes model-watch outcomes pauses pr-owners preplans product-proposals queue
queue-batch-minutes queue-risk reconcile-owner retention risk-tiers route-rules
split-watchdog staff-screen staff steer suite-results suite-reuse-saved transcripts
usage utilization verdicts wakes"

[ -x "$LINT" ] || { echo "FAIL bin/sql-ident-lint.sh is missing"; exit 1; }

# ── S1 every site in the 30 files is marked ─────────────────────────────────
FILES=()
for n in $NAMES; do FILES+=("worker/jobs/src/routes/$n.js"); done
OUT=$("$LINT" --root "$REPO" --print "${FILES[@]}" 2>&1); RC=$?
ROWS=$(printf '%s\n' "$OUT" | grep $'^worker/jobs/src/routes/[a-z-]*\\.js:[0-9]*\t')
rows=$(grep -c . <<<"$ROWS")
marked=$(grep -c $'\tmarked\t' <<<"$ROWS")
if [ "$RC" != 0 ]; then
  bad "S1 --print rc $RC, want 0" "$(printf '%s\n' "$OUT" | grep -v $'\tmarked\t' | tail -n 60)"
elif [ "$rows" -lt 48 ]; then
  bad "S1 only $rows sites, want 48+" "$OUT"
elif [ "$marked" != "$rows" ]; then
  bad "S1 $((rows - marked)) unmarked" "$(grep $'\tunmarked\t' <<<"$ROWS")"
else
  ok "S1 --print rc 0, all $rows sites in the 30 files marked"
fi

# ── S2 each marked site's marker has a reason word of 3+ letters ────────────
S2=$(cut -f1 <<<"$ROWS" | python3 -I -c '
import re, sys
repo, mark = sys.argv[1], sys.argv[2]
bad = []
for site in sys.stdin.read().split():
    path, line = site.rsplit(":", 1)
    lines = open(f"{repo}/{path}").read().split("\n")
    i = int(line) - 1
    block = [lines[i]]
    j = i - 1
    while j >= 0 and lines[j].lstrip().startswith("//"):
        block.append(lines[j]); j -= 1
    found = [l.split(mark, 1)[1] for l in block if mark in l]
    if not found or not re.search(r"[A-Za-z]{3,}", found[0]):
        bad.append(site)
print("\n".join(bad))
' "$REPO" "$M" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$S2" ] && ok "S2 every marker names a reason" || bad "S2 no reason (rc $RC)" "$S2"

# ── S3 none of the 30 files has a baseline fragment ─────────────────────────
left=""
for n in $NAMES; do
  [ -e "$FRAG/worker__jobs__src__routes__$n.js.count.txt" ] && left="$left $n.js"
done
[ -z "$left" ] && ok "S3 no fragment for the 30 files" || bad "S3 fragments left:$left"

# ── S4 the lint on this checkout is rc 0, 0 over ────────────────────────────
OUT=$("$LINT" --root "$REPO" 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$(printf '%s\n' "$OUT" | tail -n 1)" == *", 0 over" ]]; then
  ok "S4 lint rc 0, 0 over"
else
  bad "S4 lint rc $RC" "$(printf '%s\n' "$OUT" | grep -v '^NOTE' | tail -n 20)"
fi

echo "sql-ident-sites: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
