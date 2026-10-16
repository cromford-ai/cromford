#!/bin/bash
# tests/sql-ident-sites.bh-6524-test.sh — the route files of slice `a` (BH-6524,
# BH-6514.3) carry a sql-ident marker on every run-time `prepare(` site and no
# baseline fragment. S1 every --print row for the 26 files is `marked`, MIN_SITES+
# rows, and each file outside NOSITE has a row. S2 none of the 26 fragments
# exists. S3 the lint on this checkout is rc 0.
# S4 call-guard.js with one marker stripped, and no fragment, is rc 1.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LINT="$REPO/bin/sql-ident-lint.sh"
FRAG="$REPO/tests/fixtures/sql-ident-baseline"
M="sql-ident""-ok:"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }

NAMES="alerts archie-actions archie-autonomy archie-research block-findings call-guard
ci-batches ci-durations cli-versions closeout-aged conflict-hotspots context-packs
cooldowns cost-live cost deploy-queue-actions file-claims fly-idle gh-ledger
initiatives job-abandon lane-fleet lane-runs-metrics lane-snapshots lane-spend lanes"
# Files in NAMES with no run-time `prepare(` site on purpose. S1 skips only the
# "has a row" check for them; every other check still covers them.
#   lane-spend: BH-7035 C0 (519270d0d) moved its one site, the cost_rows read,
#   into a `sql` string passed to readHistory (lib/archive-read.js).
NOSITE="lane-spend"
# The S1 floor is the real site count on main. Since this suite was written:
#   BH-7035 C0 (519270d0d) moved the lane-spend.js site into readHistory (-1),
#   BH-7059 (ad46e35d1) moved 2 cost.js sites the same way (-2),
#   BH-6974 (118b9babb) added 1 gh-ledger.js site (+1). 64 - 1 - 2 + 1 = 62.
# A PR that removes a site on purpose lowers this number and says why.
MIN_SITES=62

[ -x "$LINT" ] || { echo "FAIL bin/sql-ident-lint.sh is missing"; exit 1; }

# ── S1 every site in the 26 files is marked ─────────────────────────────────
FILES=()
for n in $NAMES; do FILES+=("worker/jobs/src/routes/$n.js"); done
OUT=$("$LINT" --root "$REPO" --print "${FILES[@]}" 2>"$T/err"); RC=$?
if [ "$RC" = 2 ]; then
  bad "S1 lint rc 2" "$(cat "$T/err")"
else
  rows=$(printf '%s\n' "$OUT" | grep -c $'^worker/jobs/src/routes/[a-z-]*\\.js:[0-9]*\t')
  marked=$(printf '%s\n' "$OUT" | grep -c $'^worker/jobs/src/routes/[a-z-]*\\.js:[0-9]*\tmarked\t')
  [ "$rows" -ge "$MIN_SITES" ] && ok "S1 $rows sites in the 26 files" || bad "S1 only $rows sites, want $MIN_SITES+" "$OUT"
  [ "$marked" = "$rows" ] && ok "S1 every site is marked" \
    || bad "S1 $((rows - marked)) unmarked" "$(printf '%s\n' "$OUT" | grep $'\tunmarked\t')"
  for n in $NAMES; do
    case " $NOSITE " in *" $n "*) continue ;; esac
    grep -q "^worker/jobs/src/routes/$n\\.js:[0-9]*"$'\t' <<<"$OUT" || bad "S1 no site row for $n.js"
  done
fi

# ── S2 none of the 26 files has a baseline fragment ─────────────────────────
left=""
for n in $NAMES; do
  [ -e "$FRAG/worker__jobs__src__routes__$n.js.count.txt" ] && left="$left $n.js"
done
[ -z "$left" ] && ok "S2 no fragment for the 26 files" || bad "S2 fragments left:$left"

# ── S3 the lint on this checkout is rc 0, 0 over ────────────────────────────
OUT=$("$LINT" --root "$REPO" 2>"$T/err"); RC=$?
if [ "$RC" = 0 ] && [[ "$(printf '%s\n' "$OUT" | tail -n 1)" == *", 0 over" ]]; then
  ok "S3 lint rc 0, 0 over"
else
  bad "S3 lint rc $RC" "$(printf '%s\n' "$OUT" | grep -v '^NOTE' | tail -n 20)"$'\n'"$(cat "$T/err")"
fi

# ── S4 a stripped marker in call-guard.js is red with no fragment ───────────
R="$T/s4"
mkdir -p "$R/worker/jobs/src/routes" && git -C "$R" init -q
cp "$REPO/worker/jobs/src/routes/call-guard.js" "$R/worker/jobs/src/routes/call-guard.js"
git -C "$R" add -A
OUT=$("$LINT" --root "$R" --baseline "$FRAG" worker/jobs/src/routes/call-guard.js 2>&1); RC=$?
[ "$RC" = 0 ] && ok "S4 call-guard.js as committed is rc 0" || bad "S4 control rc $RC" "$OUT"
python3 -I - "$R/worker/jobs/src/routes/call-guard.js" "$M" <<'PY'
import sys
p, m = sys.argv[1], sys.argv[2]
lines = open(p).read().split("\n")
for i, l in enumerate(lines):
    if m in l:
        # Drop a whole marker line; cut a trailing marker off a code line.
        if l.strip().startswith("//"):
            del lines[i]
        else:
            lines[i] = l[:l.index("//")].rstrip()
        break
else:
    sys.exit("no marker in " + p)
open(p, "w").write("\n".join(lines))
PY
OUT=$("$LINT" --root "$R" --baseline "$FRAG" worker/jobs/src/routes/call-guard.js 2>&1); RC=$?
[ "$RC" = 1 ] && ok "S4 one stripped marker is rc 1" || bad "S4 stripped rc $RC, want 1" "$OUT"
grep -q "worker/jobs/src/routes/call-guard.js:[0-9]*: unmarked" <<<"$OUT" \
  && ok "S4 names the call-guard.js site" || bad "S4 site not named" "$OUT"

echo "sql-ident-sites: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
