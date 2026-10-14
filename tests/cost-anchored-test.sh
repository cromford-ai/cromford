#!/bin/bash
# tests/cost-anchored-test.sh — the CONSOLE half of meter-anchored cost.
#
# WHY A SECOND SUITE. The worker's arithmetic is driven by node --test in
# worker/jobs/test/cost-anchored.test.js (reached from tests/jobs-worker-test.sh,
# the one door). What that cannot see is the screen: whether the console asks
# the right endpoint, whether it can tell "measured, and the rows were right"
# from "we could not measure this", and whether a dollar figure on screen is
# ever a number the browser invented. Those are this file's claims.
#
# What is proved here, in the order a reader cares about it:
#   1. THE BROWSER NEVER MULTIPLIES. lib/anchored.js contains no arithmetic that
#      could produce a dollar — a second implementation of the factor in a
#      browser is how two screens end up quoting two prices for one PR.
#   2. factor 1.00 and "unmeasured" NEVER render the same. They are opposite
#      claims and the whole point of the feature is keeping them apart.
#   3. every identity cell links, and a cell with nowhere honest to go is null
#      rather than a route that would 404 on a missing project.
#   4. the screen asks for the anchored endpoint, through the same proxy the
#      rest of the console uses, with the window it is showing.
#   5. the tables are the shared SortableTable (sortable headers, aria-sort) and
#      every one of them carries RAW beside ANCHORED — an anchored figure alone
#      is unauditable.
#   6. the kill switch exists on both sides and is documented.
#   7. no secret value is in any of it.
# Run from anywhere: tests/cost-anchored-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/anchored.js"
SCREEN="$DIR/console-ui/src/screens/Costs.js"
API="$DIR/console-ui/src/api.js"
# BH-1195 split the worker into src/lib/ + src/routes/, so every grep below
# reads the whole source tree rather than the one file the route chain used to
# be. Same assertions, asked of the same code in its new home.
WORKER="$DIR/worker/jobs/src"
DOC="$DIR/docs/COST.md"

for f in "$LIB" "$SCREEN" "$API" "$DOC"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
[ -d "$WORKER" ] && ok || bad "missing $WORKER"

command -v node >/dev/null 2>&1 || { echo "cost-anchored: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1..3: the lib, DRIVEN ---------------------------------------------------
# Imported and called for real. Every assertion below is a behaviour a grep
# would pass on a version that gets it wrong.
OUT=$(node --input-type=module -e "
import { fmtFactor, isAnchored, anchorState, anchorHeadline, prLink, ticketLink, boxLink, stageLine, tableTotals, ANCHOR_WINDOWS }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

// A multiplier nobody could measure is a dash. '1.00x' would claim the rows
// were checked against a meter and found right, which is the opposite claim.
eq('factor-metered',    fmtFactor(3.42, 'metered'), '3.42x');
eq('factor-unmeasured', fmtFactor(1, 'unmeasured'), '—');
eq('factor-nologin',    fmtFactor(1, 'no-login'),   '—');
eq('factor-null',       fmtFactor(null, 'metered'), '—');
eq('factor-nan',        fmtFactor('abc', 'metered'), '—');

// factor 1 means the anchored column is a COPY of the raw one, and the screen
// mutes it rather than letting it read as confirmation.
eq('anchored-yes', isAnchored({ factor: 3.4 }), true);
eq('anchored-one', isAnchored({ factor: 1 }),   false);
eq('anchored-nul', isAnchored(null),            false);

// Three states, three different sentences. 'metered' is the only one that ever
// multiplied anything.
eq('state-metered',  anchorState({ state: 'metered', factor_capped: false }).label, 'METERED');
eq('state-capped',   anchorState({ state: 'metered', factor_capped: true  }).label, 'METERED (CAPPED)');
eq('state-unmeas',   anchorState({ state: 'unmeasured' }).label, 'UNMEASURED');
eq('state-nologin',  anchorState({ state: 'no-login' }).label,   'NO METER');
eq('state-missing',  anchorState(null).label, 'NO METER');
// The reason the endpoint gave is shown, never replaced by a house sentence.
eq('state-reason',   anchorState({ state: 'unmeasured', reason: 'the meter did not move' }).note, 'the meter did not move');
// An account with no reason still gets English, not an empty cell.
eq('state-nodefault', anchorState({ state: 'no-login' }).note.length > 0, true);

// The headline. 'off' is not 'empty' and neither is an error.
eq('head-null',     anchorHeadline(null).ready, false);
eq('head-disabled', anchorHeadline({ disabled: true, reason: 'r' }).disabled, true);
const h = anchorHeadline({
  window: '24h', accounts: [{ state: 'metered' }, { state: 'no-login' }],
  totals: { rows_usd: 100, rows_anchored_usd: 342, meter_delta_usd: 342 },
});
eq('head-ready',   h.ready, true);
eq('head-metered', h.metered, 1);
eq('head-any',     h.anyAnchored, true);
eq('head-uplift',  Number(h.uplift.toFixed(2)), 3.42);
// NOTHING METERED is the common case and it is a state, not an error.
const q = anchorHeadline({ accounts: [{ state: 'no-login' }], totals: { rows_usd: 10, rows_anchored_usd: 10 } });
eq('head-none-any',   q.anyAnchored, false);
eq('head-none-ready', q.ready, true);
// A zero raw total must not mint an uplift of Infinity/NaN on screen.
const z = anchorHeadline({ accounts: [], totals: { rows_usd: 0, rows_anchored_usd: 0 } });
eq('head-zero-uplift', z.uplift, null);

// Identity cells. A PR with a fleet project goes to the PR screen; one without
// falls back to the REAL github url; one with neither is null, not a route that
// would 404 on a null project.
eq('pr-route', prLink({ project: 'project-3', number: '12' }), { kind: 'route', to: '/pr/project-3/12' });
eq('pr-ext',   prLink({ pr_url: 'https://github.com/a/b/pull/3' }), { kind: 'external', to: 'https://github.com/a/b/pull/3' });
eq('pr-none',  prLink({ pr_url: 'not-a-url' }), null);
eq('pr-null',  prLink(null), null);
// A project with a slash or space cannot be allowed to break out of the route.
eq('pr-encoded', prLink({ project: 'a/b', number: '1' }).to, '/pr/a%2Fb/1');
// A ticket drills into the build that spent the money.
eq('ticket-link', ticketLink({ build_dir: 'project-3-TK-109-202607241459' }), { kind: 'route', to: '/builds/project-3-TK-109-202607241459' });
eq('ticket-none', ticketLink({}), null);
eq('box-link',    boxLink().to, '/machines');

// The stage line is biggest-first so the dominant stage is the first thing read.
eq('stages', stageLine({ review: 10, execute: 65 }, (v) => '\$' + v.toFixed(2)), 'execute \$65.00, review \$10.00');
eq('stages-empty', stageLine({}, String), null);
eq('stages-null',  stageLine(null, String), null);

// Page totals are a SUM of what is on the page — never a re-derivation.
eq('totals', tableTotals([{ raw_usd: 1.5, anchored_usd: 5 }, { raw_usd: 2, anchored_usd: 6 }]),
   { n: 2, raw_usd: 3.5, anchored_usd: 11 });
eq('totals-junk', tableTotals([{ raw_usd: null, anchored_usd: undefined }]), { n: 1, raw_usd: 0, anchored_usd: 0 });
eq('windows', ANCHOR_WINDOWS.map((w) => w.key), ['24h', '7d']);
" 2>&1)
NODE_RC=$?
[ "$NODE_RC" -eq 0 ] || bad "the anchored lib did not import/run: $OUT"
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok ;;
    "no "*) bad "lib: ${line#no }" ;;
  esac
done <<< "$OUT"

# THE BROWSER NEVER MULTIPLIES. The factor is money arithmetic and it lives in
# exactly one place (the worker). A `*` or `/` against a usd field here is a
# second implementation waiting to disagree with the endpoint.
grep -nE '(raw_usd|anchored_usd|meter_delta_usd|rows_usd)[[:space:]]*[*/]|[*/][[:space:]]*(factor|raw_usd)' "$LIB" \
  | grep -vE '^[0-9]+:[[:space:]]*(//|\*)' > /tmp/ca-mul.$$ 2>/dev/null
[ ! -s /tmp/ca-mul.$$ ] && ok || bad "lib/anchored.js does arithmetic on dollars: $(cat /tmp/ca-mul.$$)"
rm -f /tmp/ca-mul.$$

# --- 4: the screen asks the right endpoint -----------------------------------
grep -q "costAnchored" "$API" && ok || bad "api.js has no costAnchored helper"
grep -q "/api/coord/metrics/cost-anchored" "$API" && ok || bad "costAnchored does not call the anchored endpoint"
# Through the coord proxy, like every other coord read — not a bare worker URL.
grep -q "costAnchored:.*=>" "$API" && ok || bad "costAnchored is not a function"
grep -q "api.costAnchored" "$SCREEN" && ok || bad "Costs.js never calls costAnchored"
# The window the user picked must reach the request, or the switcher is a lie.
grep -q "api.costAnchored({ window: win })" "$SCREEN" && ok || bad "Costs.js does not pass its selected window to the endpoint"
grep -q "\[win\]" "$SCREEN" && ok || bad "the anchored fetch does not re-run when the window changes"
grep -q "AnchoredSection" "$SCREEN" && ok || bad "Costs.js defines no AnchoredSection"
# Defined AND mounted: a component nobody renders ships nothing.
[ "$(grep -c 'AnchoredSection' "$SCREEN")" -ge 2 ] && ok || bad "AnchoredSection is defined but never mounted"

# --- 5: the tables ------------------------------------------------------------
# The shared component, which is what carries click-to-sort, the direction
# indicator and aria-sort. A hand-rolled <table> here would ship none of them.
grep -q "SortableTable" "$SCREEN" && ok || bad "the anchored tables are not SortableTable"
grep -q "ANCHOR_WINDOWS" "$SCREEN" && ok || bad "the window switcher does not come from the lib"
# RAW beside ANCHORED, in every table. An anchored figure alone cannot be
# checked against the ledger it came from.
grep -q "label: 'RAW'" "$SCREEN" && ok || bad "no RAW column"
grep -q "label: 'ANCHORED'" "$SCREEN" && ok || bad "no ANCHORED column"
# Per TABLE, not per file: the column array itself is sliced out and checked, so
# a table that quietly dropped its RAW column cannot pass on another table's.
coldef() { awk "/^const $1 = \\[/{f=1} f{print} f&&/^\\];/{exit}" "$SCREEN"; }
for t in prColumns ticketColumns boxColumns; do
  block=$(coldef "$t")
  [ -n "$block" ] && ok || bad "$t is missing — \$/PR, \$/ticket and \$/box are all required"
  grep -q "rawCol" <<<"$block" && ok || bad "$t carries no RAW column"
  grep -q "anchoredCol" <<<"$block" && ok || bad "$t carries no ANCHORED column"
done
# Totals, and they are the WINDOW's totals rather than the page's.
grep -q "TOTAL" "$SCREEN" && ok || bad "the anchored tables carry no totals row"
grep -q "SHOWING TOP" "$SCREEN" && ok || bad "a truncated table does not say its total covers more than the page"
# Empty and unmeasured are explicit states with sentences, not blank tables.
grep -q "Nothing is metered in this window" "$SCREEN" && ok || bad "no explicit unmeasured state"
grep -q "no meter for this account" "$LIB" && ok || bad "no 'no meter for this account' copy"
# No native dialogs, ever.
grep -nE '(^|[^.[:alnum:]_])(confirm|alert|prompt)\(' "$SCREEN" > /tmp/ca-dlg.$$ 2>/dev/null
[ ! -s /tmp/ca-dlg.$$ ] && ok || bad "Costs.js uses a native browser dialog: $(cat /tmp/ca-dlg.$$)"
rm -f /tmp/ca-dlg.$$

# --- 6: the kill switch, both sides + documented -----------------------------
grep -rq 'ANCHOR_OFF_FLAG = "cost-anchor-off"' "$WORKER" && ok || bad "the worker has no cost-anchor-off flag"
grep -rq "COST_ANCHOR_OFF" "$WORKER" && ok || bad "the worker has no COST_ANCHOR_OFF env kill switch"
grep -rq "COST_ANCHOR_MAX_FACTOR" "$WORKER" && ok || bad "the clamp is not an env knob"
grep -rq "COST_ANCHOR_ACCOUNT_MAP" "$WORKER" && ok || bad "the account map is not an env knob"
# Off answers EMPTY lists, never raw dollars wearing an anchored name.
grep -rq "disabled: true" "$WORKER" && ok || bad "the off path does not report disabled:true"
grep -q "head.disabled" "$SCREEN" && ok || bad "the screen ignores disabled:true"
# Every knob is documented where an operator would look.
for k in COST_ANCHOR_OFF COST_ANCHOR_MAX_FACTOR COST_ANCHOR_ACCOUNT_MAP cost-anchor-off; do
  grep -q "$k" "$DOC" && ok || bad "docs/COST.md does not document $k"
done
grep -qi "factor" "$DOC" && ok || bad "docs/COST.md does not carry the formula"

# --- 7: no secrets ------------------------------------------------------------
# Env var NAMES are expected here; a VALUE is not. Long opaque strings and the
# known credential prefixes are what a leak looks like.
# The pattern is ASSEMBLED rather than written out, so this scanner cannot match
# its own source and report itself as a leak.
SECRET_RE="(gh""p_|gh""s_|github""_pat_|sk-""ant-|sk-[A-Za-z0-9]{20,}|Bea""rer [A-Za-z0-9._-]{20,})"
for f in "$LIB" "$SCREEN" "$DOC" "$DIR/tests/cost-anchored-test.sh"; do
  grep -nE "$SECRET_RE" "$f" > /tmp/ca-sec.$$ 2>/dev/null
  [ ! -s /tmp/ca-sec.$$ ] && ok || bad "possible secret in $f"
  rm -f /tmp/ca-sec.$$
done

echo "cost-anchored: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
