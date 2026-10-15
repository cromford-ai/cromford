#!/bin/bash
# tests/console-qa-run.bh-6923-test.sh — bin/console-qa-run.mjs tells a known
# preview binding gap from a defect (BH-6923). A same-origin /api/ response
# that answers 503 with the Pages Function's own "<binding> is not set|bound on
# this Pages project" error is a gap: it prints one PREVIEW GAP: line, and the
# 503 resource error it caused does not fail the screen. Anything else stays a
# defect.
#
#   G1 HARNESS_SECRET 503 under /api/coord/whoami: a gap
#   G2 CONSOLE_DB 503 under /api/cockpit/now: a gap (method passed through)
#   G3 a 503 with another error text: not a gap
#   G4 a 500 with the gap text: not a gap
#   G5 a cross-origin 503, and a 503 outside /api/: not a gap
#   G6 a body that is not JSON: not a gap
#   G7 dropGapErrors drops only 503 resource errors, at most n; a TypeError
#      still fails the screen; n = 0 changes nothing
#   G8 a screen whose only errors are the gap's 503s passes; the line format
#   G9 the real CLI (node bin/console-qa-run.mjs) with a fake playwright under
#      the resolve root: a gap screen prints the PREVIEW GAP: line once, before
#      QA COVERAGE, and is QA: PASS; observed.json lists the gap
#   G10 the real CLI: a 503 with another error text is QA: FAIL, no gap line
#   G11 the real CLI: a gap whose body read fails is QA: FAIL (fail closed)
#
# Run: bash tests/console-qa-run.bh-6923-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
[ -f "$DIR/bin/console-qa-run.mjs" ] || { echo "FAIL: bin/console-qa-run.mjs does not exist"; exit 1; }

cat > "$T/unit.mjs" <<UNIT
import * as m from "$DIR/bin/console-qa-run.mjs";
const { previewGap, previewGapLine, dropGapErrors, consoleFailures } = m;
const base = "https://ticket-bh-6923.mission-fixture.example.invalid";
const j = (x) => JSON.stringify(x);
const say = (k, v) => console.log(k + "=" + j(v));
if (typeof previewGap !== "function" || typeof dropGapErrors !== "function" || typeof previewGapLine !== "function") {
  console.log("missing-exports"); process.exit(0);
}
// The texts are the 503 bodies of main's Pages Functions (console-ui/functions/api).
say("g1", previewGap(503, base + "/api/coord/whoami", base, j({ error: "HARNESS_SECRET is not set on this Pages project — the console cannot reach the coordination API" })));
say("g2", previewGap(503, base + "/api/cockpit/now?x=1", base, j({ error: "CONSOLE_DB is not bound on this Pages project" }), "POST"));
say("g3", previewGap(503, base + "/api/coord/whoami", base, j({ error: "upstream timeout" })));
say("g4", previewGap(500, base + "/api/coord/whoami", base, j({ error: "HARNESS_SECRET is not set on this Pages project" })));
say("g5a", previewGap(503, "https://harness-console.fixture.workers.dev/api/coord/whoami", base, j({ error: "HARNESS_SECRET is not set on this Pages project" })));
say("g5b", previewGap(503, base + "/assets/x.js", base, j({ error: "HARNESS_SECRET is not set on this Pages project" })));
say("g6", previewGap(503, base + "/api/coord/whoami", base, "<html>503</html>"));
const E503 = "Failed to load resource: the server responded with a status of 503 ()";
const rec = { path: "/", viewport: "1440", url: null, status: 200, landedOnAuthWall: false, consoleErrors: [E503, "TypeError: x is undefined", E503], failedRequests: [], horizontalScroll: false, nativeDialog: null, shot: "x.png", error: null };
const r1 = dropGapErrors(rec, 1);
say("g7a", r1.consoleErrors);
say("g7a-fail", consoleFailures(r1).length);
say("g7b", consoleFailures(dropGapErrors(rec, 2)).length);
say("g7b-left", dropGapErrors(rec, 5).consoleErrors);
say("g7c", dropGapErrors(rec, 0).consoleErrors);
say("g7-orig", rec.consoleErrors.length);
const only = { ...rec, consoleErrors: [E503, E503] };
say("g8a", consoleFailures(dropGapErrors(only, 2)));
say("g8b", consoleFailures(dropGapErrors(only, 1)).length);
console.log("line=" + previewGapLine(previewGap(503, base + "/api/coord/whoami", base, j({ error: "HARNESS_SECRET is not set on this Pages project" }))));
UNIT
OUT=$(node "$T/unit.mjs" 2>&1)
grep -qx 'missing-exports' <<<"$OUT" && { echo "FAIL: previewGap, previewGapLine or dropGapErrors is not exported"; echo "console-qa-run.bh-6923: 0 passed, 1 failed"; exit 1; }
v() { sed -n "s/^$1=//p" <<<"$OUT"; }
[ "$(v g1 | jq -r '.key + "|" + .binding')" = 'GET /api/coord/whoami|HARNESS_SECRET' ] && ok || bad "G1 $(v g1) ($OUT)"
[ "$(v g2 | jq -r '.key + "|" + .binding')" = 'POST /api/cockpit/now|CONSOLE_DB' ] && ok || bad "G2 $(v g2)"
[ "$(v g3)" = null ] && ok || bad "G3 other 503 text is a defect: $(v g3)"
[ "$(v g4)" = null ] && ok || bad "G4 a 500 is a defect: $(v g4)"
[ "$(v g5a)" = null ] && ok || bad "G5 cross-origin is a defect: $(v g5a)"
[ "$(v g5b)" = null ] && ok || bad "G5 outside /api/ is a defect: $(v g5b)"
[ "$(v g6)" = null ] && ok || bad "G6 a non-JSON body is a defect: $(v g6)"
[ "$(v g7a | jq -r 'length')" = 2 ] && v g7a | jq -e '.[0] | startswith("TypeError")' >/dev/null && ok || bad "G7 n=1 drops one 503: $(v g7a)"
[ "$(v g7a-fail)" -ge 1 ] && ok || bad "G7 n=1 still fails"
[ "$(v g7b)" -ge 1 ] && ok || bad "G7 a TypeError still fails the screen"
[ "$(v g7b-left)" = '["TypeError: x is undefined"]' ] && ok || bad "G7 n=5 drops only 503 errors: $(v g7b-left)"
[ "$(v g7c | jq -r 'length')" = 3 ] && ok || bad "G7 n=0 changes nothing: $(v g7c)"
[ "$(v g7-orig)" = 3 ] && ok || bad "G7 the record passed in is not changed"
[ "$(v g8a)" = '[]' ] && ok || bad "G8 a gap-only screen passes: $(v g8a)"
[ "$(v g8b)" = 1 ] && ok || bad "G8 one gap does not cover two 503s: $(v g8b)"
[ "$(v line)" = 'PREVIEW GAP: GET /api/coord/whoami — HARNESS_SECRET not bound in the preview environment' ] && ok || bad "G8 line: $(sed -n 's/^line=//p' <<<"$OUT")"

# ── G9-G11: the real CLI, with a fake playwright under the resolve root ──────
FR="$T/fakeroot"; mkdir -p "$FR/node_modules/playwright"
cat > "$FR/node_modules/playwright/index.js" <<'FAKE'
// A fake playwright: one context, pages whose goto() fires the scenario's
// responses at the context and its console errors at the page.
const sc = process.env.FAKE_PW_SCENARIO || "gap";
const E503 = "Failed to load resource: the server responded with a status of 503 ()";
function resp(base, status, path, body, bodyFails) {
  return { status: () => status, url: () => base + path, request: () => ({ method: () => "GET" }),
           text: () => (bodyFails ? Promise.reject(new Error("closed")) : Promise.resolve(body)) };
}
exports.chromium = {
  launch: async () => ({
    close: async () => {},
    newContext: async () => {
      const rl = [];
      const ctx = {
        on: (ev, fn) => { if (ev === "response") rl.push(fn); },
        request: { get: async () => ({ status: () => 200 }) },
        newPage: async () => {
          const pl = {}; let cur = "about:blank";
          return {
            setViewportSize: () => {},
            on: (ev, fn) => { (pl[ev] = pl[ev] || []).push(fn); },
            goto: async (u) => {
              cur = u; const base = new URL(u).origin;
              if (u.includes("/qa-login/")) return { status: () => 200 };
              const who = JSON.stringify({ error: "HARNESS_SECRET is not set on this Pages project" });
              const list = sc === "defect" ? [resp(base, 503, "/api/coord/whoami", JSON.stringify({ error: "upstream timeout" }))]
                : [resp(base, 200, "/", "<html>"), resp(base, 503, "/api/coord/whoami", who, sc === "bodyfail"),
                   resp(base, 503, "/api/coord/whoami", who, sc === "bodyfail")];
              for (const r of list) for (const fn of rl) fn(r);
              const n = list.filter((r) => r.status() === 503).length;
              for (let i = 0; i < n; i++) for (const fn of pl.console || []) fn({ type: () => "error", text: () => E503 });
              return { status: () => 200 };
            },
            waitForTimeout: async () => {},
            url: () => cur,
            evaluate: async () => false,
            screenshot: async () => {},
            close: async () => {},
          };
        },
      };
      return ctx;
    },
  }),
};
FAKE
QAT="1791700000.$(printf 'ef%.0s' $(seq 1 32))"
cli() { mkdir -p "$T/o-$1"; RC=0; OUT=$(FAKE_PW_SCENARIO="$1" CONSOLE_QA_TOKEN="$QAT" CONSOLE_QA_WIDTHS="" \
  node "$DIR/bin/console-qa-run.mjs" https://ticket-bh-6923.mission-fixture.example.invalid "$FR" "$T/o-$1" / 2>&1) || RC=$?; }
cli gap
[ "$RC" = 0 ] && grep -qx 'QA: PASS' <<<"$OUT" && ok || bad "G9 a gap-only screen is QA: PASS (rc=$RC): $OUT"
[ "$(grep -c '^PREVIEW GAP: ' <<<"$OUT")" = 1 ] && grep -qx 'PREVIEW GAP: GET /api/coord/whoami — HARNESS_SECRET not bound in the preview environment' <<<"$OUT" \
  && ok || bad "G9 want one deduped PREVIEW GAP line: $OUT"
[ "$(grep -nE '^(PREVIEW GAP|QA COVERAGE)' <<<"$OUT" | head -1 | cut -d: -f2)" = 'PREVIEW GAP' ] && ok || bad "G9 the gap line comes before QA COVERAGE: $OUT"
grep -qx 'SCREEN / 1440 ok' <<<"$OUT" && grep -qx 'SCREEN / 390 ok' <<<"$OUT" && ok || bad "G9 screens: $OUT"
jq -e '.gaps | length == 1 and (.[0] | startswith("PREVIEW GAP: GET /api/coord/whoami"))' "$T/o-gap/observed.json" >/dev/null 2>&1 \
  && ok || bad "G9 observed.json gaps: $(cat "$T/o-gap/observed.json" 2>/dev/null | head -c 400)"
cli defect
[ "$RC" = 1 ] && grep -qx 'QA: FAIL' <<<"$OUT" && ok || bad "G10 another 503 text is QA: FAIL (rc=$RC): $OUT"
grep -q '^PREVIEW GAP: ' <<<"$OUT" && bad "G10 a defect printed a gap line: $OUT" || ok
cli bodyfail
[ "$RC" = 1 ] && grep -qx 'QA: FAIL' <<<"$OUT" && ok || bad "G11 an unreadable gap body is QA: FAIL (rc=$RC): $OUT"

echo "console-qa-run.bh-6923: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
