#!/bin/bash
# tests/e2e-smoke-test.sh — bin/e2e-smoke.sh is a REPORTER, never a blocker.
#
# WHY DRIVEN AND NOT GREPPED. Every claim this stage makes is about what happens
# when the infrastructure is absent: no Vercel lane, no preview for the sha, a
# preview that never became reachable, a playwright that would not resolve. Each
# of those must come out as a RECORDED skip with a reason and rc 3 — not a pass,
# and not a block. `grep -q SKIP bin/e2e-smoke.sh` would pass just as happily on
# a version that exits 1 and stops the build, which is the one bug that could
# stall every UI build in the fleet the day it ships.
#
# The three things proven here are the three the goal names: URL DISCOVERY (the
# resolved preview URL is what the browser is pointed at, and it is a PREVIEW,
# never the prod domain), the SKIP PATH (each absence, honestly recorded), and
# the FAIL PATH (a real defect surfaces as E2E: FAIL, reaches rc 4, and parks a
# PR in merge-sweep). node and wait-preview.sh are stubbed — no network, no
# secrets. The browser's own behaviour lives in bin/e2e-smoke.mjs and is proven
# by the node --check in this suite plus the live run recorded on the PR.
# Run from anywhere: tests/e2e-smoke-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin" "$T/out" "$T/repo"
cp "$DIR/bin/e2e-smoke.sh" "$T/bin/"
cp "$DIR/bin/e2e-smoke.mjs" "$T/bin/"
cp "$DIR/catalog/e2e-smoke-routes.json" "$T/routes.json"
printf 'demo-os team_x prj_x os.demo.example\n' > "$T/vercel.conf"

# --- stubs -------------------------------------------------------------------
# Fake wait-preview.sh: records the argv it was called with, answers per mode.
cat > "$T/bin/wait-preview.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$WP_SINK"
case "${WP_MODE:-ok}" in
  ok)       echo "https://demo-os-git-feat-abc123.vercel.app"; exit 0 ;;
  warming)  echo "warming up, still polling" >&2; echo "https://demo-os-git-feat-abc123.vercel.app"; exit 0 ;;
  none)     echo "no preview deployment for $2 within 300s" >&2; exit 1 ;;
  protected) echo "preview $2 protected (HTTP 401, no usable bypass)" >&2; exit 1 ;;
  garbage)  echo "not-a-url"; exit 0 ;;
esac
EOF
chmod +x "$T/bin/wait-preview.sh"

# Fake node: records the argv + ROUTES it was handed, then behaves per mode.
# It writes e2e.md itself, exactly as the real bin/e2e-smoke.mjs does.
cat > "$T/bin/fakenode" <<'EOF'
#!/bin/bash
OUTD="$3"
printf 'ARGV %s\n' "$*" >> "$NODE_SINK"
printf 'ROUTES %s\n' "$(printf '%s' "${ROUTES:-}" | tr '\n' ',')" >> "$NODE_SINK"
case "${NODE_MODE:-pass}" in
  pass) printf 'ROUTE 200 / console=0 ok\nE2E COVERAGE: routes=1 failed=0\nE2E: PASS\n' > "$OUTD/e2e.md"; exit 0 ;;
  fail) printf 'ROUTE 500 /clients console=2 FAIL\nE2E COVERAGE: routes=2 failed=1\nE2E: FAIL\n' > "$OUTD/e2e.md"; exit 4 ;;
  liar) printf 'nothing here\n' > "$OUTD/e2e.md"; exit 0 ;;
  cantrun) echo "playwright unresolvable" ; exit 3 ;;
  missing) exit 127 ;;
esac
EOF
chmod +x "$T/bin/fakenode"

# run <project> -> sets RC, and leaves the record in $T/out/e2e.md
run() {
  rm -rf "$T/out"; mkdir -p "$T/out"
  : > "$T/wp.log"; : > "$T/node.log"
  HARNESS="$T" VERCEL_CONF="${VC_OVERRIDE:-$T/vercel.conf}" E2E_ROUTES_FILE="$T/routes.json" \
  WAIT_PREVIEW="$T/bin/wait-preview.sh" E2E_NODE="$T/bin/fakenode" \
  WP_SINK="$T/wp.log" NODE_SINK="$T/node.log" \
  WP_MODE="${WP_MODE:-ok}" NODE_MODE="${NODE_MODE:-pass}" \
  bash "$T/bin/e2e-smoke.sh" "${1:-demo-os}" "example-org/demo-os" "abc123def456" "$T/out" "$T/repo" \
    > "$T/stdout.log" 2>&1
  RC=$?
}
LAST() { tail -1 "$T/out/e2e.md" 2>/dev/null; }

echo "--- URL discovery"
WP_MODE=ok NODE_MODE=pass run demo-os
[ "$RC" = 0 ] && [ "$(LAST)" = "E2E: PASS" ] \
  && ok || bad "a resolved preview + a clean smoke must be rc 0 / E2E: PASS (rc=$RC last='$(LAST)')"
# The URL handed to the browser is the one wait-preview resolved, and it is a
# PREVIEW. A regression that pointed this at the prod domain would be silent.
grep -q "https://demo-os-git-feat-abc123.vercel.app" "$T/node.log" \
  && ok || bad "the resolved preview URL never reached the smoke script: $(cat "$T/node.log")"
grep -q "os.demo.example" "$T/node.log" \
  && bad "the stage pointed the browser at the PRODUCTION domain from vercel.conf" || ok
# ...and it asked for THIS sha, so a preview of some other commit cannot answer.
grep -q "example-org/demo-os abc123def456" "$T/wp.log" \
  && ok || bad "wait-preview was not asked for this repo+sha: $(cat "$T/wp.log")"
# wait-preview writes progress to stderr; only the URL line may be used.
WP_MODE=warming NODE_MODE=pass run demo-os
grep -qE "ARGV .*/e2e-smoke\.mjs https://demo-os-git-feat-abc123\.vercel\.app " "$T/node.log" \
  && ok || bad "stderr chatter from wait-preview leaked into the URL: $(cat "$T/node.log")"

echo "--- skip path (recorded, rc 3, never a pass, never a block)"
# 1. project has no Vercel lane at all -> decided from config, no network wait.
WP_MODE=ok run not-a-vercel-project
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "a project absent from vercel.conf must SKIP with rc 3 (rc=$RC last='$(LAST)')"
[ -s "$T/wp.log" ] && bad "it waited on a preview for a project that has no Vercel project" || ok
# 2. no vercel.conf on the box at all.
VC_OVERRIDE="$T/nope.conf" run demo-os; unset VC_OVERRIDE
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "a missing vercel.conf must SKIP, not crash (rc=$RC last='$(LAST)')"
# 3. no preview ever appeared for the sha.
WP_MODE=none run demo-os
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "no preview for the sha must SKIP (rc=$RC last='$(LAST)')"
grep -q "no preview deployment" "$T/out/e2e.md" \
  && ok || bad "the skip did not record WHY: $(cat "$T/out/e2e.md")"
[ -s "$T/node.log" ] && bad "the browser was launched with no preview URL" || ok
# 4. the preview exists but is protected and unusable.
WP_MODE=protected run demo-os
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "a protected preview must SKIP (rc=$RC last='$(LAST)')"
# 5. wait-preview answers something that is not a URL.
WP_MODE=garbage run demo-os
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "a non-URL answer must SKIP rather than be fetched (rc=$RC last='$(LAST)')"
# 6. playwright/chromium could not run -> the stage's own "could not run".
WP_MODE=ok NODE_MODE=cantrun run demo-os
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "an unrunnable smoke must SKIP (rc=$RC last='$(LAST)')"
# 7. the script is not on the box yet (staggered harness-sync) -> degrade.
WP_MODE=ok NODE_MODE=missing run demo-os
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "rc 127 from the runner must degrade to SKIP (rc=$RC last='$(LAST)')"
# 8. EMPTY IS NOT PASS: a smoke that exits 0 without writing a verdict has
#    proven nothing, and must not be allowed to hand the pipeline a green.
WP_MODE=ok NODE_MODE=liar run demo-os
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "exit 0 with no verdict line must NOT read as a pass (rc=$RC last='$(LAST)')"
# Every skip says, in words, that nothing was verified — the line a reviewer
# reads. A skip that only carried a status would be read as "fine".
for M in none protected garbage; do
  WP_MODE=$M run demo-os
  grep -qi "not a pass\|did not run" "$T/out/e2e.md" \
    && ok || bad "the $M skip record does not say nothing was verified: $(cat "$T/out/e2e.md")"
done

echo "--- fail path"
WP_MODE=ok NODE_MODE=fail run demo-os
[ "$RC" = 4 ] \
  && ok || bad "a route that 5xx'd must exit 4, not 0 (rc=$RC)"
[ "$(LAST)" = "E2E: FAIL" ] \
  && ok || bad "the FAIL verdict must survive to the record (last='$(LAST)')"
grep -q "ROUTE 500 /clients" "$T/out/e2e.md" \
  && ok || bad "the record does not name the route that failed: $(cat "$T/out/e2e.md")"

echo "--- routes"
# Declared project routes reach the browser.
jq '.projects = {"demo-os": ["/", "/clients"]}' "$T/routes.json" > "$T/r2" && mv "$T/r2" "$T/routes.json"
WP_MODE=ok NODE_MODE=pass run demo-os
grep -qx "ROUTES /,/clients" "$T/node.log" \
  && ok || bad "declared routes did not reach the smoke: $(grep ROUTES "$T/node.log")"
# A project with no entry falls back to "/" rather than to nothing.
WP_MODE=ok NODE_MODE=pass run demo-os >/dev/null
jq '.projects = {}' "$T/routes.json" > "$T/r2" && mv "$T/r2" "$T/routes.json"
WP_MODE=ok NODE_MODE=pass run demo-os
grep -qx "ROUTES /" "$T/node.log" \
  && ok || bad "a project with no declared routes must still smoke '/': $(grep ROUTES "$T/node.log")"

# Routes the DIFF adds are smoked too — otherwise the stage only ever loads a
# home page that the change never touched. Static segments only: a [id] route
# needs a real record, and previews share the production database.
git -C "$T/repo" init -q 2>/dev/null
git -C "$T/repo" config user.email t@t; git -C "$T/repo" config user.name t
mkdir -p "$T/repo/src"; echo base > "$T/repo/src/a.txt"
git -C "$T/repo" add -A >/dev/null; git -C "$T/repo" commit -qm base
BASEREF=$(git -C "$T/repo" rev-parse HEAD)
mkdir -p "$T/repo/src/app/(app)/reports" "$T/repo/src/app/clients/[id]"
echo x > "$T/repo/src/app/(app)/reports/page.tsx"
echo x > "$T/repo/src/app/clients/[id]/page.tsx"
git -C "$T/repo" add -A >/dev/null; git -C "$T/repo" commit -qm feat
rm -rf "$T/out"; mkdir -p "$T/out"; : > "$T/node.log"; : > "$T/wp.log"
HARNESS="$T" VERCEL_CONF="$T/vercel.conf" E2E_ROUTES_FILE="$T/routes.json" \
  WAIT_PREVIEW="$T/bin/wait-preview.sh" E2E_NODE="$T/bin/fakenode" \
  WP_SINK="$T/wp.log" NODE_SINK="$T/node.log" WP_MODE=ok NODE_MODE=pass \
  E2E_BASE_REF="$BASEREF" \
  bash "$T/bin/e2e-smoke.sh" demo-os example-org/demo-os abc123def456 "$T/out" "$T/repo" >/dev/null 2>&1
grep -q "/reports" "$T/node.log" \
  && ok || bad "a page added by the diff was never smoked: $(grep ROUTES "$T/node.log")"
grep -q "clients" "$T/node.log" \
  && bad "a dynamic [id] route was smoked — it has no real record to load" || ok

echo "--- merge-sweep refuses to merge over a RECORDED e2e failure"
# Driven against the real sweep with a fake gh, the same shape harness-ci uses:
# gh being called at all is the failure, because the decision happens before it.
MS=$T/ms; mkdir -p "$MS/builds/pool-demo-os-K-1" "$MS/logs" "$MS/state" "$MS/locks" "$MS/flags" "$T/fakebin"
printf '#!/bin/sh\ntouch %s/gh-called\nexit 1\n' "$T" > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
D="$MS/builds/pool-demo-os-K-1"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/7" > "$D/RESULT"
echo "VERDICT: APPROVE" > "$D/review.md"
printf 'ROUTE 500 /clients console=2 FAIL\nE2E: FAIL\n' > "$D/e2e.md"
rm -f "$T/gh-called"
PATH="$T/fakebin:$PATH" HARNESS="$MS" bash "$DIR/bin/merge-sweep.sh" >/dev/null 2>&1
[ -f "$MS/state/merge-sweep-done.txt" ] \
  && ok || bad "the sweep never ran against the fixture — this check was testing nothing"
[ ! -f "$T/gh-called" ] \
  && ok || bad "merge-sweep reached gh for a build with a recorded E2E: FAIL"
grep -q "E2E smoke FAILED" "$MS/logs/merge-sweep.log" 2>/dev/null \
  && ok || bad "the sweep parked the PR without saying why: $(cat "$MS/logs/merge-sweep.log" 2>/dev/null)"

# ...and the asymmetry: SILENCE IS NOT FAILURE. A build with no e2e.md (non-UI
# diff, older box, dropped relay) must still be swept, or shipping this would
# park the whole fleet. It gets past the e2e check and on to gh.
rm -f "$D/e2e.md" "$T/gh-called" "$MS/state/merge-sweep-done.txt"
PATH="$T/fakebin:$PATH" HARNESS="$MS" bash "$DIR/bin/merge-sweep.sh" >/dev/null 2>&1
[ -f "$T/gh-called" ] \
  && ok || bad "a build with no e2e record was parked — absence must not read as failure"
# A SKIP is not a failure either, for the same reason.
printf 'E2E smoke did not run: no preview.\nE2E: SKIP\n' > "$D/e2e.md"
rm -f "$T/gh-called" "$MS/state/merge-sweep-done.txt"
PATH="$T/fakebin:$PATH" HARNESS="$MS" bash "$DIR/bin/merge-sweep.sh" >/dev/null 2>&1
[ -f "$T/gh-called" ] \
  && ok || bad "a recorded SKIP parked the PR — only a FAIL may do that"

echo "--- wiring (a stage nothing calls is not a stage)"
RB="$RB_ALL"
grep -q 'bin/e2e-smoke.sh' "$RB" \
  && ok || bad "run-build.sh never invokes bin/e2e-smoke.sh"
# It must run BEFORE the reviewer, or its verdict cannot reach REVIEW_PROMPT.
# Anchored on the ASSEMBLY of REVIEW_PROMPT rather than on the call that sends
# it: the lenses run concurrently since 2026-09-12, so the general review is
# dispatched from a shared LENS_CALL rather than from a literal `CC review …
# review-run.txt` line — and the prompt assignment is the stricter anchor
# anyway, since that is the line which interpolates ${GATES_NOTE}.
E2ELN=$(grep -n 'bin/e2e-smoke.sh' "$RB" | head -1 | cut -d: -f1)
# TEST-CHANGE (BH-7970): REVIEW_PROMPT is now assembled by `sp_render review REVIEW_PROMPT` from prompts/stages/review.md (which interpolates ${GATES_NOTE}).
REVLN=$(grep -n '^sp_render review REVIEW_PROMPT' "$RB" | head -1 | cut -d: -f1)
{ [ -n "$E2ELN" ] && [ -n "$REVLN" ] && [ "$E2ELN" -lt "$REVLN" ]; } \
  && ok || bad "the e2e stage does not run before the review call (e2e=$E2ELN review=$REVLN)"
# ...and its note must actually be spliced into what the reviewer reads.
grep -qF 'GATES_NOTE="$GATES_NOTE"' "$RB" && grep -qF '"$E2E_NOTE"' "$RB" \
  && ok || bad "the e2e note is never appended to GATES_NOTE — the reviewer would never see it"
# The phase is opened on the build's own claim, by name.
grep -q 'job_phase_open e2e' "$RB" \
  && ok || bad "the e2e stage opens no phase in the jobs ledger"
grep -q 'job_phase_close "\$E2E_RC"' "$RB" \
  && ok || bad "the e2e phase is opened but never closed with its real rc"
# A FAIL must not auto-merge on the tier-1 path, which never reaches merge-sweep.
grep -q 'E2E_VERDICT:-not-run.* = "fail"' "$RB" \
  && ok || bad "a failed e2e smoke can still tier-1 auto-merge"
# The record has to reach the hub or the sweep gate above cannot see it.
grep -q 'pipeline.log cost.csv gh-stderr.log e2e.md' "$DIR/bin/fly-results-ingest.sh" \
  && ok || bad "e2e.md is not relayed off Fly builders — merge-sweep would never see a FAIL"
# ...and vercel.conf has to reach the boxes, or the stage skips everywhere on a
# missing file. It was hub-only until this stage needed it.
grep -q 'CHECKOUT/vercel.conf' "$DIR/bin/harness-sync.sh" \
  && ok || bad "vercel.conf is not synced to boxes — every box would skip the e2e stage"
grep -q 'fleet.conf vercel.conf fly' "$DIR/bin/fly-sync-harness.sh" \
  && ok || bad "vercel.conf is not shipped to Fly builders — they would skip the e2e stage"

echo "--- the push the stage adds must survive the pre-PR rebase"
# THE BUG THIS PINS. The e2e stage pushes the branch before review so Vercel has
# something to build a preview from. The pipeline then rebases onto latest main
# before opening the PR, which REWRITES those commits — so the PR-time push is a
# non-fast-forward and a plain `git push` is REJECTED, deferring the build with
# no PR on every UI build where main moved mid-build. Driven against real git
# repos, because that is a claim about git's behaviour, not about our strings.
G=$T/git; mkdir -p "$G"
( set -e
  git init -q --bare "$G/origin.git"
  git clone -q "$G/origin.git" "$G/work" 2>/dev/null
  cd "$G/work"; git config user.email t@t; git config user.name t
  echo base > a.txt; git add -A; git commit -qm base; git push -q origin HEAD:main
  git checkout -qb feat; echo feat > b.txt; git add -A; git commit -qm feat
) >/dev/null 2>&1
cd "$G/work"
git push -q -u origin feat 2>/dev/null            # the e2e stage's push
( cd "$G/work" && git checkout -q main && echo moved > c.txt && git add -A \
  && git commit -qm moved && git push -q origin main && git checkout -q feat ) >/dev/null 2>&1
git rebase -q origin/main >/dev/null 2>&1          # the pre-PR rebase
# The old plain push: this MUST fail, or the fix below is guarding nothing.
if git push -u origin feat --quiet >/dev/null 2>&1; then
  bad "a plain push after the rebase succeeded — this check no longer reproduces the bug it guards"
else
  ok
fi
git push -u origin feat --force-with-lease --quiet >/dev/null 2>&1 \
  && ok || bad "--force-with-lease could not land the rebased branch — the PR would never open"
cd "$DIR"
# ...and run-build.sh must actually use it at the PR-time push.
# BH-2504: the PR-time push is RB_PUSH, which pushes through bin/lib/hold-push.sh
# under an explicit --force-with-lease — both halves are pinned.
grep -q '{ RB_PUSH -u pr-push && track_pushed; }' "$RB" \
  && ok || bad "the PR-time push is not RB_PUSH — the rebase would reject it and defer the build"
grep -q -- '--force-with-lease=\$br:\$lease' "$DIR/bin/lib/hold-push.sh" \
  && ok || bad "bin/lib/hold-push.sh does not push --force-with-lease — the rebase would reject it and defer the build"

echo "--- the browser half, driven for real against a localhost fixture"
# The shell driver above is proven with stubs; these prove the ASSERTIONS —
# what actually counts as a failure — by running chromium against a server that
# serves each shape on purpose. The driver refuses anything but an https:// URL
# (previews are https, and that guard is the reason it is not reused here), so
# bin/e2e-smoke.mjs is invoked directly.
PW_ROOT=""
for R in "$DIR" "$(npm root -g 2>/dev/null)" /usr/lib/node_modules /usr/local/lib/node_modules; do
  [ -n "$R" ] && [ -d "$R/playwright" ] && { PW_ROOT="$R"; break; }
done
if ! command -v node >/dev/null 2>&1 || [ -z "$PW_ROOT" ]; then
  # Loud, not silent: a suite that quietly skips the only section exercising a
  # browser would report green having proven nothing about the browser.
  echo "SKIPPED (NOT PASSED): playwright/node unavailable — the live browser assertions did not run"
else
  PORT=$(( 20000 + RANDOM % 20000 ))
  cat > "$T/srv.mjs" <<'SRV'
import http from "http";
const port = Number(process.argv[2]);
http.createServer((req, res) => {
  if (req.url.startsWith("/boom"))   { res.writeHead(500, {"content-type":"text/html"}); return res.end("<h1>500</h1>"); }
  if (req.url.startsWith("/noisy"))  { res.writeHead(200, {"content-type":"text/html"}); return res.end("<html><body><script>console.error('kaboom from the app')</script></body></html>"); }
  if (req.url.startsWith("/throws")) { res.writeHead(200, {"content-type":"text/html"}); return res.end("<html><body><script>null.x.y</script></body></html>"); }
  if (req.url.startsWith("/gone"))   { res.writeHead(404, {"content-type":"text/html"}); return res.end("nope"); }
  res.writeHead(200, {"content-type":"text/html"}); res.end("<html><body><h1>ok</h1></body></html>");
}).listen(port);
SRV
  node "$T/srv.mjs" "$PORT" & SRVPID=$!
  UP=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && { UP=yes; break; }; sleep 0.5
  done
  live() { # live <routes> -> LIVE_RC, record in $T/live/e2e.md
    rm -rf "$T/live"; mkdir -p "$T/live"
    ROUTES="$1" node "$DIR/bin/e2e-smoke.mjs" "http://127.0.0.1:$PORT" "$T/live" "$PW_ROOT" \
      > "$T/live/out.txt" 2>&1
    LIVE_RC=$?
  }
  # A dead fixture server must say so once, not produce six mystery failures
  # about the browser that are really about this test's own setup.
  [ -n "$UP" ] || bad "the fixture server never came up on port $PORT — the live browser assertions below are meaningless"
  live "/"
  { [ "$LIVE_RC" = 0 ] && [ "$(tail -1 "$T/live/e2e.md")" = "E2E: PASS" ]; } \
    && ok || bad "a healthy page must PASS (rc=$LIVE_RC): $(cat "$T/live/out.txt")"
  # The three shapes that ARE failures.
  live "/boom"
  { [ "$LIVE_RC" = 4 ] && grep -q "5xx=\[500" "$T/live/e2e.md"; } \
    && ok || bad "a 500 route was not caught (rc=$LIVE_RC): $(cat "$T/live/out.txt")"
  live "/noisy"
  { [ "$LIVE_RC" = 4 ] && grep -q "kaboom from the app" "$T/live/e2e.md"; } \
    && ok || bad "an app console.error was not caught (rc=$LIVE_RC): $(cat "$T/live/out.txt")"
  live "/throws"
  { [ "$LIVE_RC" = 4 ] && grep -q "uncaught:" "$T/live/e2e.md"; } \
    && ok || bad "an uncaught exception was not caught (rc=$LIVE_RC): $(cat "$T/live/out.txt")"
  # ...and the one that is NOT. The browser logs "Failed to load resource: 404"
  # as a console error for every missing favicon, image and beacon. Counting
  # those would fail the smoke on noise unrelated to the diff, and a gate that
  # cries wolf is a gate someone switches off.
  live "/gone"
  { [ "$LIVE_RC" = 0 ] && [ "$(tail -1 "$T/live/e2e.md")" = "E2E: PASS" ]; } \
    && ok || bad "a 404 route failed the smoke — resource-load noise is not an app defect: $(cat "$T/live/out.txt")"
  # Counted work, not an asserted verdict: routes that never loaded cannot pass.
  live "/"
  grep -q "E2E COVERAGE: routes=1 failed=0" "$T/live/e2e.md" \
    && ok || bad "the coverage line does not count what was really loaded: $(cat "$T/live/e2e.md")"
  # EMPTY IS NOT PASS, in the browser half too. A run with nothing to load has
  # zero failures by arithmetic, and "no failures" must never be laundered into
  # a green — it is the same shape as the four boot-only SMOKEs of 2026-08-13.
  live " "
  { [ "$LIVE_RC" = 4 ] && grep -q "E2E COVERAGE: routes=0" "$T/live/e2e.md"; } \
    && ok || bad "a run that loaded zero routes reported a pass (rc=$LIVE_RC): $(cat "$T/live/e2e.md")"
  kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null
fi

echo "--- the browser script parses and refuses to run without arguments"
if command -v node >/dev/null 2>&1; then
  node --check "$DIR/bin/e2e-smoke.mjs" 2>/dev/null \
    && ok || bad "bin/e2e-smoke.mjs is not valid JavaScript"
  OUT=$(node "$DIR/bin/e2e-smoke.mjs" 2>&1); RC2=$?
  { [ "$RC2" = 3 ] && grep -q "could not run" <<<"$OUT"; } \
    && ok || bad "the smoke with no args must exit 3 'could not run', got rc=$RC2: $OUT"
else
  echo "node missing — skipping the .mjs checks (NOT counted as passed)"
fi

echo "e2e-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
