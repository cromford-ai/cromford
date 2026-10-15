#!/bin/bash
# tests/harness-sync-docs-off-path.bh-6806-test.sh — bin/harness-sync.sh never
# waits on a doc index build.
#
# WHY (BH-6806). harness-sync ran bin/verification-map-build.sh in the
# foreground, BEFORE every rsync. On the hub under load that build ran 20+
# minutes, so fleet-propagate's `timeout 300` killed every sync (rc 124) from
# 17:56Z to 23:40Z on 2026-10-14, and merged code and the worker were not live.
# The doc builds now run in bin/docs-sync.sh, launched DETACHED after the
# rsyncs, the worker phase and the success stamp, and skipped when the inputs
# of the index have not changed since the last good build.
#
# Cases:
#   A1  the generator sleeps 600 s; `timeout 60 bin/harness-sync.sh` is rc 0
#   A2  after A1 the worker-phase marker and the success stamp exist
#   A6  after A1 the live tree matches the checkout (bin/, prompts/)
#   A1b after A1 the generator started (detached)
#   A3  changed inputs: the build runs, writes its duration line, stamps the key
#   A4  unchanged inputs: the build is skipped, the generator does not start
#   A5  a failed build writes its rc line, keeps the old stamp, and retries
#   A7  a held docs-sync lock: rc 0, no generator start, no stamp change
#   A8  a missing README forces a build on an unchanged key
#   A10 an uncommitted entry edit forces a build
#   A11 no committed index/ dir: empty key, build, no stamp
#   A12 a generator-only change forces a build
#   A13 docs/LLM_CALL_SITES.md is rendered by the detached helper too
#
# A1-A6, A3-A5, A8, A12 drive bin/harness-sync.sh itself against a scratch
# $HARNESS and a real bare origin + clone. A7, A10, A11 drive bin/docs-sync.sh
# directly (a dirty checkout is a refusal in harness-sync, by design).
#
# Run from anywhere: tests/harness-sync-docs-off-path.bh-6806-test.sh
# (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null && command -v timeout >/dev/null \
  || { echo "harness-sync-docs-off-path.bh-6806-test: SKIPPED — git/flock/timeout missing"; exit 0; }

VCALLS="$T/vmb.calls"; LCALLS="$T/llm.calls"; MODE="$T/vmb.mode"
: > "$VCALLS"; : > "$LCALLS"; echo ok > "$MODE"
RUNLOG="$T/logs/update-runners.log"; DSLOG="$T/logs/docs-sync.log"
LOCK="$T/locks/docs-sync.lock"; KEYSTAMP="$T/state/verification-map-built"

# No sleeper outlives the suite: every stub start line carries its pid.
kill_stubs() {
  local p
  for p in $(awk '{print $2}' "$VCALLS" 2>/dev/null); do kill "$p" 2>/dev/null; done
}
trap 'kill_stubs; __scratch_exit_trap' EXIT

printf 'CLOUDFLARE_ACCOUNT_ID=test-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$T/env/cloudflare.env"

cat > "$T/fakebin/npx" <<'EOF'
#!/bin/bash
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

# ── a real bare origin and a real clone ─────────────────────────────────────
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" \
         "$T/ck/worker/jobs/src" "$T/ck/docs/verification-map/entries" \
         "$T/ck/docs/verification-map/index"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf 'fleet\n' > "$T/ck/fleet.conf"
printf 'docs/verification-map/README.md\ndocs/LLM_CALL_SITES.md\n' > "$T/ck/.gitignore"
printf '| a | b | c |\n' > "$T/ck/docs/verification-map/entries/BH-1.md"
printf '# head\n' > "$T/ck/docs/verification-map/index/head.md"
cp "$DIR/bin/docs-sync.sh" "$T/ck/bin/docs-sync.sh" 2>/dev/null || true

# The generator stub. Its mode is a file in $T, so a case changes it without a
# commit. "sleep" is the hung generator of the ticket: 600 s in 1 s steps, so
# a kill of the recorded pid ends it within a second.
cat > "$T/ck/bin/verification-map-build.sh" <<EOF
#!/bin/bash
VCALLS="$VCALLS"; MODE="$MODE"
EOF
cat >> "$T/ck/bin/verification-map-build.sh" <<'EOF'
REPO=.; [ "${1:-}" = --repo ] && REPO="$2"
echo "start $$" >> "$VCALLS"
case "$(cat "$MODE")" in
  sleep) for _ in $(seq 1 600); do sleep 1; done ;;
  fail)  exit 3 ;;
  *)     printf 'index\n' > "$REPO/docs/verification-map/README.md"; exit 0 ;;
esac
EOF
cat > "$T/ck/bin/llm-sites-build.sh" <<EOF
#!/bin/bash
LCALLS="$LCALLS"
EOF
cat >> "$T/ck/bin/llm-sites-build.sh" <<'EOF'
REPO=.; [ "${1:-}" = --repo ] && REPO="$2"
echo "start $$" >> "$LCALLS"
printf 'sites\n' > "$REPO/docs/LLM_CALL_SITES.md"
EOF
chmod +x "$T/ck/bin/"*.sh

cat > "$T/ck/worker/jobs/wrangler.toml" <<'EOF'
name = "jobs-test"
main = "src/index.js"
compatibility_date = "2026-07-01"
EOF
printf 'export default { fetch: () => new Response("ok") };\n' > "$T/ck/worker/jobs/src/index.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() { # sync -> rc in $RC; harness-sync itself, under the ticket's 60 s bound
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    timeout 60 bash "$DIR/bin/harness-sync.sh" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
docs_sync() { # the helper directly, in the foreground -> rc in $RC
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    timeout 60 bash "$T/ck/bin/docs-sync.sh" ) >>"$DSLOG" 2>&1
  RC=$?
}
commit_push() {
  git -C "$T/ck" add -A >/dev/null
  git -C "$T/ck" commit -qm "$1"
  git -C "$T/ck" push -q origin main
}
starts() { grep -c '^start ' "$VCALLS" 2>/dev/null || true; }
wait_for() { # wait_for <file> <fixed string> — up to 10 s
  local i
  for i in $(seq 1 50); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
wait_starts() { # wait_starts <n> — up to 10 s for the n-th generator start
  local i
  for i in $(seq 1 50); do
    [ "$(starts)" -ge "$1" ] && return 0
    sleep 0.2
  done
  return 1
}
wait_idle() { # up to 15 s for the detached helper to release its lock
  local i
  for i in $(seq 1 75); do
    flock -n "$LOCK" true 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
wait_stamp() { # up to 30 s for the stamp to hold the key of HEAD (a good build ended)
  local i
  for i in $(seq 1 150); do
    [ "$(cat "$KEYSTAMP" 2>/dev/null)" = "$(key_now)" ] && return 0
    sleep 0.2
  done
  return 1
}
key_now() {
  printf '%s %s %s' "$(git -C "$T/ck" rev-parse HEAD:docs/verification-map/entries)" \
    "$(git -C "$T/ck" rev-parse HEAD:docs/verification-map/index)" \
    "$(git -C "$T/ck" rev-parse HEAD:bin/verification-map-build.sh)"
}

# ── S0. SAFETY PROBE: a dirty checkout refuses at rc 30 inside $T ────────────
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$T/logs/ALERTS.log" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — refusing to run the deploy path."
  echo "harness-sync-docs-off-path.bh-6806-test: 0 pass, 1 fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
: > "$T/logs/ALERTS.log"

# ============================================================================
# A1/A2/A6/A1b. THE TICKET: a generator that sleeps 600 s holds back nothing.
# ============================================================================
echo sleep > "$MODE"
sync
[ "$RC" = 0 ] && ok || bad "A1: harness-sync must exit 0 under timeout 60 with a 600 s doc build, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ -s "$T/state/worker-deployed-jobs" ] && ok || bad "A2: the worker-phase marker state/worker-deployed-jobs must be written"
[ -e "$T/state/harness-sync-last-success" ] && ok || bad "A2: state/harness-sync-last-success must be stamped"
cmp -s "$T/ck/bin/x.sh" "$T/bin/x.sh" && ok || bad "A6: live bin/x.sh must match the checkout"
cmp -s "$T/ck/prompts/p.md" "$T/prompts/p.md" && ok || bad "A6: live prompts/p.md must match the checkout"
cmp -s "$T/ck/bin/docs-sync.sh" "$T/bin/docs-sync.sh" && ok || bad "A6: live bin/docs-sync.sh must match the checkout"
wait_starts 1 && ok || bad "A1b: the doc build must start (detached) within 10 s of the sync's return: $(cat "$VCALLS")"
[ ! -s "$KEYSTAMP" ] && ok || bad "A1b: a build still running must stamp nothing: $(cat "$KEYSTAMP")"
kill_stubs
wait_idle && ok || bad "A1b: the helper must release its lock when the generator dies"
echo ok > "$MODE"

# ============================================================================
# A3. Changed inputs: the build runs and writes its duration line and stamp.
# ============================================================================
printf '| d | e | f |\n' > "$T/ck/docs/verification-map/entries/BH-2.md"
commit_push "a new entry"
N0=$(starts)
sync
[ "$RC" = 0 ] && ok || bad "A3: sync must exit 0, got $RC"
wait_for "$RUNLOG" "verification-map index built in" \
  && ok || bad "A3: update-runners.log must carry the duration line: $(tail -5 "$RUNLOG")"
wait_idle
KEY3=$(key_now)
[ "$(starts)" -gt "$N0" ] && ok || bad "A3: the generator must start on changed inputs"
grep -q "verification-map index built in [0-9]*s (inputs ${KEY3:0:12})" "$RUNLOG" \
  && ok || bad "A3: the duration line must name the seconds and the key: $(grep 'built in' "$RUNLOG")"
[ "$(cat "$KEYSTAMP" 2>/dev/null)" = "$KEY3" ] \
  && ok || bad "A3: the stamp must hold the new key '$KEY3', got '$(cat "$KEYSTAMP" 2>/dev/null)'"
[ -s "$T/ck/docs/verification-map/README.md" ] && ok || bad "A3: the README must exist after a good build"

# ============================================================================
# A13. docs/LLM_CALL_SITES.md is rendered by the detached helper.
# ============================================================================
[ -s "$LCALLS" ] && ok || bad "A13: llm-sites-build.sh must run from the detached helper"
[ -s "$T/ck/docs/LLM_CALL_SITES.md" ] && ok || bad "A13: docs/LLM_CALL_SITES.md must be rendered"

# ============================================================================
# A4. Unchanged inputs: skipped, no generator start, no duration line.
# ============================================================================
N0=$(starts); V0=$(grep -c 'verification-map index' "$RUNLOG")
: > "$DSLOG"
sync
[ "$RC" = 0 ] && ok || bad "A4: sync must exit 0, got $RC"
wait_for "$DSLOG" "skipped (inputs unchanged ${KEY3:0:12})" \
  && ok || bad "A4: docs-sync.log must carry the skip line: $(cat "$DSLOG")"
wait_idle
[ "$(starts)" = "$N0" ] && ok || bad "A4: an unchanged key must not start the generator: $(cat "$VCALLS")"
[ "$(grep -c 'verification-map index' "$RUNLOG")" = "$V0" ] \
  && ok || bad "A4: a skip must be silent in update-runners.log: $(tail -3 "$RUNLOG")"

# ============================================================================
# A12. A generator-only change forces a build.
# ============================================================================
printf '# generator moved\n' >> "$T/ck/bin/verification-map-build.sh"
commit_push "the generator changes"
N0=$(starts)
sync
wait_starts $((N0+1)) && ok || bad "A12: a changed generator must start a build"
wait_idle
[ "$(cat "$KEYSTAMP" 2>/dev/null)" = "$(key_now)" ] && ok || bad "A12: the stamp must follow the new generator key"

# ============================================================================
# A5. A failed build: one rc line, the old stamp kept, retried next sync.
# ============================================================================
KEYOK=$(cat "$KEYSTAMP")
echo fail > "$MODE"
printf '| g | h | i |\n' > "$T/ck/docs/verification-map/entries/BH-3.md"
commit_push "another entry"
N0=$(starts)
sync
[ "$RC" = 0 ] && ok || bad "A5: a failing doc build must not fail the sync, got $RC"
wait_for "$RUNLOG" "verification-map index could not be regenerated rc=3 after" \
  && ok || bad "A5: update-runners.log must carry the rc=3 line: $(tail -5 "$RUNLOG")"
wait_idle
[ "$(cat "$KEYSTAMP")" = "$KEYOK" ] && ok || bad "A5: a failed build must not move the stamp"
grep -q "built in [0-9]*s (inputs $(key_now | cut -c1-12))" "$RUNLOG" \
  && bad "A5: a failed build must write no 'built in' line" || ok
N1=$(starts)
sync
wait_starts $((N1+1)) && ok || bad "A5: the next sync must retry the failed build"
wait_idle
echo ok > "$MODE"
sync
# The detached helper of this sync can start after a first wait_idle looks
# (batch #6839: it took the lock late, read its key after A7's commit, stamped
# that key and held the lock through A7). So A7 starts only after this build
# stamped the key of HEAD and released the lock: bounded polls, no fixed sleep.
wait_stamp && ok || bad "A5: the sync after the fix must build and stamp $(key_now | cut -c1-12), got '$(cat "$KEYSTAMP" 2>/dev/null)'"
wait_idle && ok || bad "A5: the helper must release its lock after the build"

# ============================================================================
# A7. A held lock: rc 0, no generator start, no stamp change.
# ============================================================================
printf '| j | k | l |\n' > "$T/ck/docs/verification-map/entries/BH-4.md"
commit_push "an entry while the lock is held"
STAMP0=$(cat "$KEYSTAMP"); N0=$(starts)
exec 5>"$LOCK"
flock -w 30 5 && ok || bad "A7: premise — the suite must hold the docs-sync lock"
docs_sync
[ "$RC" = 0 ] && ok || bad "A7: a busy lock must exit 0, got $RC"
[ "$(starts)" = "$N0" ] && ok || bad "A7: a busy lock must not start the generator"
[ "$(cat "$KEYSTAMP")" = "$STAMP0" ] && ok || bad "A7: a busy lock must not move the stamp"
exec 5>&-
docs_sync
[ "$(starts)" -gt "$N0" ] && ok || bad "A7: the run after the lock frees must build"

# ============================================================================
# A8. README missing on an unchanged key forces a build.
# ============================================================================
docs_sync; N0=$(starts)
[ "$(cat "$KEYSTAMP")" = "$(key_now)" ] && ok || bad "A8: premise — the key must be stamped"
rm -f "$T/ck/docs/verification-map/README.md"
docs_sync
[ "$(starts)" -gt "$N0" ] && ok || bad "A8: a missing README must force a build"
[ -s "$T/ck/docs/verification-map/README.md" ] && ok || bad "A8: the build must restore the README"

# ============================================================================
# A10. An uncommitted entry edit forces a build on an unchanged key.
# ============================================================================
N0=$(starts)
printf '| edit |\n' >> "$T/ck/docs/verification-map/entries/BH-1.md"
docs_sync
[ "$(starts)" -gt "$N0" ] && ok || bad "A10: an uncommitted entry edit must force a build"
git -C "$T/ck" checkout -q -- docs/verification-map/entries/BH-1.md

# ============================================================================
# A11. No committed index/ dir: the key is empty, the build runs, no stamp.
# ============================================================================
git -C "$T/ck" rm -rq docs/verification-map/index
git -C "$T/ck" commit -qm "no index dir"
STAMP0=$(cat "$KEYSTAMP"); N0=$(starts)
docs_sync
[ "$RC" = 0 ] && ok || bad "A11: rc must be 0, got $RC"
[ "$(starts)" -gt "$N0" ] && ok || bad "A11: an empty key must build"
[ "$(cat "$KEYSTAMP")" = "$STAMP0" ] && ok || bad "A11: an empty key must never be stamped: $(cat "$KEYSTAMP")"
N0=$(starts)
docs_sync
[ "$(starts)" -gt "$N0" ] && ok || bad "A11: an empty key must build again on the next run"

echo "harness-sync-docs-off-path.bh-6806-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
