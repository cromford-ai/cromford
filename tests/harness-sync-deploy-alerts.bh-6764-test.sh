#!/bin/bash
# tests/harness-sync-deploy-alerts.bh-6764-test.sh — every worker-deploy
# failure path alerts once, then at most once per interval while it keeps
# failing, and a context-budget-only commit redeploys the worker that bundles
# the manifest (BH-6764, the follow-ups of the BH-6687 review).
#
# WHY. #6733 (BH-6687) put `wrangler deploy` failures through deploy_fail_note.
# A stuck `npm ci`, a failed schema compose, a failed llm-sites compose and a
# failed budget compose still wrote one ALERTS line on EVERY update-runners
# pass (694 lines in 4 days is the class BH-6687 fixed for the deploy).
#
#   B1  a commit that changes only catalog/context-budgets.d/ redeploys the
#       worker that imports catalog/context-budgets.json (-budgets-<sha>), and
#       not a worker that does not
#   N1  three failed `npm ci` passes inside the window: one ALERT, the other
#       two are held (one update-runners.log line each)
#   N2  a failed pass at or past the window alerts again with the count (4)
#   N3  `npm ci` passes: the npm-ci failing state is removed and the recovery
#       is logged (4 failed attempts: K1 and S1 stop at the schema compose)
#   S1  two failed schema-compose passes inside the window: one ALERT
#   L1  two failed llm-sites-compose passes inside the window: one ALERT
#   G1  two failed budget-compose passes inside the window: one ALERT
#   K1  the state is per worker AND per stage: a held npm-ci failure does not
#       hold the first schema-compose alert
#
# The clock is pinned with HARNESS_SYNC_NOW; HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S
# is 3600 (the default).
# Run from anywhere: tests/harness-sync-deploy-alerts.bh-6764-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null \
  || { echo "git/flock missing — skipping"; exit 0; }

ALERTS="$T/logs/ALERTS.log"
ULOG="$T/logs/update-runners.log"
NPXLOG="$T/npx.log"
printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$T/env/cloudflare.env"

# npx records `wrangler deploy` per worker dir. npm fails `ci` while
# $T/npm-fail-<w> exists.
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
printf '%s | %s\n' "\$PWD" "\$*" >> "$NPXLOG"
exit 0
EOF
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
[ "\$1" = ci ] && [ -f "$T/npm-fail-\$(basename "\$PWD")" ] && { echo "npm ERR! fixture" >&2; exit 1; }
exit 0
EOF
chmod +x "$T/fakebin/npx" "$T/fakebin/npm"
if ! command -v rsync >/dev/null; then
  cat > "$T/fakebin/rsync" <<'EOF'
#!/bin/bash
paths=()
for a in "$@"; do case "$a" in -*) ;; *) paths+=("$a") ;; esac; done
SRC="${paths[0]:-}"; DST="${paths[1]:-}"
[ -d "$SRC" ] && [ -n "$DST" ] || exit 0
mkdir -p "$DST" && cp -a "$SRC". "$DST" 2>/dev/null
exit 0
EOF
  chmod +x "$T/fakebin/rsync"
fi

git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog/context-budgets.d" "$T/ck/catalog/llm-sites.d" \
         "$T/ck/worker/jobs/src" "$T/ck/worker/jobs/schema.d" "$T/ck/worker/plain/src"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf 'fleet\n' > "$T/ck/fleet.conf"
printf '{"lane":"a","budget":1}\n' > "$T/ck/catalog/context-budgets.d/a.json"
printf '{"site":"a"}\n' > "$T/ck/catalog/llm-sites.d/a.json"
printf 'CREATE TABLE IF NOT EXISTS t (id INTEGER);\n' > "$T/ck/worker/jobs/schema.d/0001-t.sql"
# Composers in the checkout, archived into the snapshot. Each fails while its
# $T/<name>-fail flag exists.
for c in context-budgets-build llm-sites-build schema-build; do
  cat > "$T/ck/bin/$c.sh" <<EOF
#!/bin/bash
[ -f "$T/$c-fail" ] && { echo "$c: fixture refusal" >&2; exit 1; }
exit 0
EOF
  chmod +x "$T/ck/bin/$c.sh"
done
# worker/jobs bundles both catalogs and has a lockfile; worker/plain neither.
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{ "name": "jobs-test", "main": "src/index.js" }
EOF
printf 'import b from "../../../catalog/context-budgets.json";\nimport s from "../../../catalog/llm-sites.json";\nexport default {};\n' \
  > "$T/ck/worker/jobs/src/index.js"
printf '{"lockfileVersion":3}\n' > "$T/ck/worker/jobs/package-lock.json"
cat > "$T/ck/worker/plain/wrangler.toml" <<'EOF'
name = "plain-test"
main = "src/index.js"
EOF
printf 'export default {};\n' > "$T/ck/worker/plain/src/index.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() {
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; : > "$ULOG"; }
deployed() { local n; n=$(grep -cF "/worker/$1 |" "$NPXLOG" 2>/dev/null) || n=0; printf '%s' "$n"; }
push() { git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "$1"; git -C "$T/ck" push -q origin main; }
count() { local n; n=$(grep -cF -- "$1" "$ALERTS" 2>/dev/null) || n=0; printf '%s' "$n"; }
last_has() { case "$(grep -F -- "$1" "$ALERTS" 2>/dev/null | tail -1)" in *"$2"*) return 0 ;; esac; return 1; }

# ── S0. SAFETY PROBE: a dirty checkout must refuse at rc 30 ─────────────────
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — refusing to run the deploy path."
  echo "harness-sync-deploy-alerts.bh-6764-test: $PASS pass, $((FAIL+1)) fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# A clean first pass deploys both workers.
sync
[ "$RC" = 0 ] && [ "$(deployed jobs)" = 1 ] && [ "$(deployed plain)" = 1 ] && ok \
  || bad "setup: the first pass deploys both workers (rc $RC): $(cat "$NPXLOG") $(cat "$T/err.txt")"

# ── B1. a context-budget fragment-only commit redeploys jobs only ───────────
reset_run
printf '{"lane":"a","budget":2}\n' > "$T/ck/catalog/context-budgets.d/a.json"
push "budget fragment only"
sync
[ "$(deployed jobs)" = 1 ] && ok || bad "B1: a context-budgets.d-only commit redeploys jobs: $(cat "$NPXLOG")"
[ "$(deployed plain)" = 0 ] && ok || bad "B1: it does not redeploy plain: $(cat "$NPXLOG")"
BSHA=$(git -C "$T/ck" rev-list -1 HEAD -- catalog/context-budgets.d)
case "$(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" in
  *"-budgets-$BSHA"*) ok ;;
  *) bad "B1: the jobs stamp carries -budgets-$BSHA: $(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" ;;
esac

# ── N1. three failed npm ci passes inside the window: one ALERT ─────────────
reset_run
touch "$T/npm-fail-jobs"
printf 'export default { v: 2 };\n' >> "$T/ck/worker/jobs/src/index.js"
push "move jobs"
HARNESS_SYNC_NOW=2000000 sync
HARNESS_SYNC_NOW=2000600 sync
HARNESS_SYNC_NOW=2001200 sync
[ "$(count 'npm ci FAILED')" = 1 ] && ok || bad "N1: 3 failed npm ci passes in 20 min write one ALERT: $(cat "$ALERTS")"
last_has 'npm ci FAILED' '(1 failed attempt(s))' && ok || bad "N1: the ALERT carries the count 1: $(cat "$ALERTS")"
[ "$(grep -c 'npm-ci FAILED again' "$ULOG")" = 2 ] && ok || bad "N1: the two held failures are one log line each: $(cat "$ULOG")"
[ "$(deployed jobs)" = 0 ] && ok || bad "N1: no deploy while npm ci fails: $(cat "$NPXLOG")"
[ -s "$T/state/worker-npm-ci-failing-jobs" ] && ok || bad "N1: the npm-ci failing state is kept per worker"

# ── N2. a failed pass at the window alerts again with the count ─────────────
reset_run
HARNESS_SYNC_NOW=2003600 sync
[ "$(count 'npm ci FAILED')" = 1 ] && last_has 'npm ci FAILED' '(4 failed attempt(s))' && ok \
  || bad "N2: a failure at the window alerts again with the count 4: $(cat "$ALERTS")"

# ── K1. a held npm-ci failure does not hold the first schema-compose alert ──
reset_run
touch "$T/schema-build-fail"
HARNESS_SYNC_NOW=2003700 sync
[ "$(count 'schema.sql could NOT be composed')" = 1 ] && ok \
  || bad "K1: the first schema-compose failure alerts while npm ci is held: $(cat "$ALERTS")"

# ── S1. a second schema-compose failure inside the window is held ───────────
reset_run
HARNESS_SYNC_NOW=2004300 sync
[ "$(count 'schema.sql could NOT be composed')" = 0 ] && ok || bad "S1: the second schema-compose failure is held: $(cat "$ALERTS")"
grep -q 'schema-compose FAILED again' "$ULOG" && ok || bad "S1: the held failure is one log line: $(cat "$ULOG")"
rm -f "$T/schema-build-fail"

# ── N3. npm ci passes: the state goes, the recovery is logged ───────────────
reset_run
rm -f "$T/npm-fail-jobs"
HARNESS_SYNC_NOW=2005000 sync
[ "$(deployed jobs)" = 1 ] && ok || bad "N3: jobs deploys once npm ci passes: $(cat "$NPXLOG")"
[ ! -e "$T/state/worker-npm-ci-failing-jobs" ] && ok || bad "N3: the npm-ci failing state is removed: $(cat "$T/state/worker-npm-ci-failing-jobs")"
[ ! -e "$T/state/worker-schema-compose-failing-jobs" ] && ok || bad "N3: the schema-compose failing state is removed once it composes"
grep -q 'worker jobs npm-ci recovered after 4 failed attempt(s)' "$ULOG" && ok || bad "N3: the recovery is logged: $(cat "$ULOG")"
[ ! -s "$ALERTS" ] && ok || bad "N3: recovery writes no ALERT: $(cat "$ALERTS")"

# ── L1. two failed llm-sites compose passes: one ALERT ──────────────────────
reset_run
touch "$T/llm-sites-build-fail"
printf 'export default { v: 3 };\n' >> "$T/ck/worker/jobs/src/index.js"
push "move jobs again"
HARNESS_SYNC_NOW=2010000 sync
HARNESS_SYNC_NOW=2010600 sync
[ "$(count 'catalog/llm-sites.json could NOT be composed')" = 1 ] && ok \
  || bad "L1: 2 failed llm-sites compose passes write one ALERT: $(cat "$ALERTS")"
rm -f "$T/llm-sites-build-fail"

# ── G1. two failed budget compose passes: one ALERT per worker ──────────────
reset_run
touch "$T/context-budgets-build-fail"
HARNESS_SYNC_NOW=2020000 sync
HARNESS_SYNC_NOW=2020600 sync
[ "$(count 'worker/jobs catalog/context-budgets.json could NOT be composed')" = 1 ] && ok \
  || bad "G1: 2 failed budget compose passes write one worker ALERT: $(cat "$ALERTS")"
rm -f "$T/context-budgets-build-fail"

echo "harness-sync-deploy-alerts.bh-6764-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
