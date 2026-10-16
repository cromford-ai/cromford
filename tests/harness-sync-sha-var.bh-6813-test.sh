#!/bin/bash
# tests/harness-sync-sha-var.bh-6813-test.sh — the worker deploy in
# bin/harness-sync.sh passes `--var HARNESS_SHA:<snapshot sha>` to
# `wrangler deploy` for a worker whose src/ names HARNESS_SHA (BH-6813).
#
# WHY. worker/jobs/src/lib/sentry.js tags every event harness_sha from
# env.HARNESS_SHA, and nothing set it, so every harness-jobs event in Sentry
# (CROMFORD-HARNESS-19) said `unknown` and named no build.
#
#   S0  safety probe: a dirty checkout refuses at rc 30.
#   V1  worker/jobs (src names HARNESS_SHA) deploys with
#       `--var HARNESS_SHA:<snapshot HEAD sha>`, the full 40-char sha.
#   V2  a worker whose src does not name HARNESS_SHA deploys with no --var.
#   V3  a worker with no src/ dir deploys with no --var and no error.
#   V4  a failing deploy still writes the `wrangler deploy FAILED` ALERT and
#       moves no stamp.
#
# Run from anywhere: tests/harness-sync-sha-var.bh-6813-test.sh   (exit 0 = all pass)
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

# A fake npx that RECORDS instead of deploying: one line per call,
# "<worker> | <argv>". It fails `wrangler deploy` when $T/wrangler-fail-<w> exists.
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
T="$T"
EOF
cat >> "$T/fakebin/npx" <<'EOF'
w=$(basename "$PWD")
printf '%s | %s\n' "$w" "$*" >> "$NPX_LOG"
if [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "deploy" ]; then
  [ -f "$T/wrangler-fail-$w" ] && exit 1
fi
exit 0
EOF
chmod +x "$T/fakebin/npx"

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
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" \
         "$T/ck/worker/jobs/src/lib" "$T/ck/worker/plain/src" "$T/ck/worker/nosrc"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"
# worker/jobs: its src names HARNESS_SHA, the way lib/sentry.js does.
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{ "name": "jobs-test", "main": "src/index.js" }
EOF
printf 'export default {};\n' > "$T/ck/worker/jobs/src/index.js"
printf 'export const sha = (env) => env.HARNESS_SHA || "unknown";\n' > "$T/ck/worker/jobs/src/lib/sentry.js"
# worker/plain: src does not name it.
cat > "$T/ck/worker/plain/wrangler.toml" <<'EOF'
name = "plain-test"
main = "src/index.js"
EOF
printf 'export default {};\n' > "$T/ck/worker/plain/src/index.js"
# worker/nosrc: no src/ dir at all.
cat > "$T/ck/worker/nosrc/wrangler.toml" <<'EOF'
name = "nosrc-test"
main = "index.js"
EOF
printf 'export default {};\n' > "$T/ck/worker/nosrc/index.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1
# A commit outside worker/, so the snapshot sha (HEAD) is not the sha of the
# last commit that touched worker/jobs: V1 tells the two apart.
printf 'fleet 2\n' > "$T/ck/fleet.conf"
git -C "$T/ck" commit -qam "outside worker/"
git -C "$T/ck" push -q origin main

sync() {
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; : > "$ULOG"; }
deploy_line() { grep -F "$1 | --yes wrangler deploy" "$NPXLOG" 2>/dev/null; }
push() { git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "$1"; git -C "$T/ck" push -q origin main; }

# ── S0. SAFETY PROBE: a dirty checkout must refuse at rc 30 into
#    $HARNESS/logs/ALERTS.log, or the deploy path below would rsync this
#    fixture over the live /root/harness. ─────────────────────────────────────
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC, nothing in $ALERTS) —"
  echo "      refusing to run the deploy path, which would rsync this fixture over the live /root/harness."
  echo "harness-sync-sha-var.bh-6813-test: $PASS pass, $((FAIL+1)) fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# ── V1. worker/jobs deploys with --var HARNESS_SHA:<snapshot sha> ────────────
SNAP1=$(git -C "$T/ck" rev-parse HEAD)
sync
[ "$RC" = 0 ] && ok || bad "V1: a clean sync must exit 0, got $RC: $(cat "$T/err.txt")"
L=$(deploy_line jobs)
[ "$L" = "jobs | --yes wrangler deploy --var HARNESS_SHA:$SNAP1" ] \
  && ok || bad "V1: jobs must deploy with '--var HARNESS_SHA:$SNAP1', got: '$L' (npx log: $(cat "$NPXLOG"))"
[ "${#SNAP1}" = 40 ] && ok || bad "V1: the snapshot sha must be the full 40-char sha: $SNAP1"
WJOBS=$(git -C "$T/ck" rev-list -1 HEAD -- worker/jobs)
[ "$WJOBS" != "$SNAP1" ] && ok || bad "V1: fixture: the worker/jobs sha must differ from the snapshot sha"
grep -qF "worker jobs deployed at" "$ULOG" && ok || bad "V1: update-runners.log must say 'worker jobs deployed at': $(cat "$ULOG")"
grep -qF "(snapshot of ${SNAP1:0:7})" "$ULOG" && ok || bad "V1: the deploy line must name snapshot ${SNAP1:0:7}: $(cat "$ULOG")"

# ── V2. a worker whose src does not name HARNESS_SHA gets no --var ───────────
L=$(deploy_line plain)
[ "$L" = "plain | --yes wrangler deploy" ] \
  && ok || bad "V2: plain must deploy with no --var, got: '$L'"

# ── V3. a worker with no src/ deploys with no --var and no error ─────────────
L=$(deploy_line nosrc)
[ "$L" = "nosrc | --yes wrangler deploy" ] \
  && ok || bad "V3: nosrc must deploy with no --var, got: '$L'"
grep -qF "worker nosrc deployed at" "$ULOG" && ok || bad "V3: nosrc must log its deploy: $(cat "$ULOG")"
[ ! -s "$ALERTS" ] && ok || bad "V1-V3: a clean pass writes no ALERT: $(cat "$ALERTS")"

# ── V4. a failing deploy alerts, moves no stamp, and still passed the sha ────
reset_run
cp "$T/state/worker-deployed-jobs" "$T/wd.before"
touch "$T/wrangler-fail-jobs"
printf 'export default { v: 2 };\n' > "$T/ck/worker/jobs/src/index.js"
push "move jobs"
SNAP2=$(git -C "$T/ck" rev-parse HEAD)
sync
[ "$RC" = 0 ] && ok || bad "V4: a failed deploy must not fail the sync, got $RC"
L=$(deploy_line jobs)
[ "$L" = "jobs | --yes wrangler deploy --var HARNESS_SHA:$SNAP2" ] \
  && ok || bad "V4: the retry must pass the NEW snapshot sha $SNAP2, got: '$L'"
[ "$(grep -c 'wrangler deploy FAILED' "$ALERTS" 2>/dev/null)" = 1 ] \
  && ok || bad "V4: exactly one 'wrangler deploy FAILED' ALERT: $(cat "$ALERTS")"
cmp -s "$T/state/worker-deployed-jobs" "$T/wd.before" \
  && ok || bad "V4: a failed deploy must not move state/worker-deployed-jobs"
grep -qF "worker jobs deployed at" "$ULOG" && bad "V4: a failed deploy writes no 'deployed' line: $(cat "$ULOG")" || ok
rm -f "$T/wrangler-fail-jobs"

echo "harness-sync-sha-var.bh-6813-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
