#!/bin/bash
# tests/schema-compose-deploy.bh-6005-0-test.sh — the deploy path composes
# worker/<w>/schema.sql from worker/<w>/schema.d/ (BH-6005.0, ticket BH-6007).
#
# WHY. worker/jobs/schema.sql is composed from schema.d/ fragments (BH-4987) and
# is leaving git (BH-6005). bin/harness-sync.sh applied and deployed the
# COMMITTED file, so once it is untracked the D1 apply would read nothing and
# the deploy would ship code with no schema. This suite pins the tracer:
#
#   B1-B6  bin/schema-build.sh --ref <rev>: compose one worker's schema.d/ as it
#          was at a git revision (print or --to only, needs --worker, rc 2 when
#          the rev has no schema.d/).
#   H1-H5b bin/harness-sync.sh: the snapshot carries bin/schema-build.sh, the
#          `# >>> schema compose (BH-6005)` block writes schema.sql into the
#          snapshot before the apply and the deploy, a failed compose is one
#          ALERT and no apply/deploy/stamp, and `hash-object -w` puts the
#          applied blob in the object store so the next run computes a delta.
#
# Run from anywhere: tests/schema-compose-deploy.bh-6005-0-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/git-history-full.bh-9733.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null \
  || { echo "git/flock missing — skipping"; exit 0; }

SB="$DIR/bin/schema-build.sh"
gitc() { git -c user.email=t@t -c user.name=t "$@"; }

# ============================================================================
# B. bin/schema-build.sh --ref <rev>
# ============================================================================

# B1. real repo, byte parity: --ref at a commit that tracks worker/jobs/schema.sql
#     prints that commit's file, byte for byte. Read-only on the real repo.
#     A shallow clone or the gate's snapshot cannot hold that commit: B1 prints
#     a NOTE there and fails only on full history (ghf_full, BH-9733).
REV=""
if git -C "$DIR" cat-file -e HEAD:worker/jobs/schema.sql 2>/dev/null; then
  REV=HEAD
else
  DEL=$(git -C "$DIR" log -1 --diff-filter=D --format=%H -- worker/jobs/schema.sql 2>/dev/null)
  [ -n "$DEL" ] && REV="$DEL^"
fi
if [ -z "$REV" ]; then
  if ghf_full "$DIR"; then
    bad "B1: no commit in this repo tracks worker/jobs/schema.sql"
  else
    echo "NOTE: B1 not run (history is shallow or a snapshot: the commit that deleted worker/jobs/schema.sql is not in it)"
  fi
elif cmp -s <("$SB" --root "$DIR" --ref "$REV" --worker jobs) <(git -C "$DIR" show "$REV:worker/jobs/schema.sql"); then
  ok
else
  bad "B1: --ref $REV --worker jobs must print $REV:worker/jobs/schema.sql byte for byte"
fi

# A fixture repo: C1 has no schema.d/, C2 adds two workers that both have one.
B="$T/brepo"
git init -q "$B"
mkdir -p "$B/worker/jobs" "$B/worker/other"
printf 'x\n' > "$B/worker/jobs/code.js"
printf 'x\n' > "$B/worker/other/code.js"
gitc -C "$B" add -A >/dev/null; gitc -C "$B" commit -qm c1
C1=$(git -C "$B" rev-parse HEAD)
mkdir -p "$B/worker/jobs/schema.d" "$B/worker/other/schema.d"
printf 'CREATE TABLE IF NOT EXISTS j_a (id INTEGER PRIMARY KEY);\n' > "$B/worker/jobs/schema.d/0000-a.sql"
printf 'CREATE TABLE IF NOT EXISTS j_b (id INTEGER PRIMARY KEY);\n' > "$B/worker/jobs/schema.d/0001-b.sql"
printf 'CREATE TABLE IF NOT EXISTS o_a (id INTEGER PRIMARY KEY);\n' > "$B/worker/other/schema.d/0000-a.sql"
gitc -C "$B" add -A >/dev/null; gitc -C "$B" commit -qm c2

# B2. --ref with no --worker, two workers with a schema.d/ → rc 2, names --worker.
"$SB" --root "$B" --ref HEAD >"$T/b.out" 2>"$T/b.err"; rc=$?
[ "$rc" = 2 ] && ok || bad "B2: --ref with no --worker must be rc 2, got $rc: $(cat "$T/b.err")"
grep -q -- '--worker' "$T/b.err" && ok || bad "B2: the refusal must name --worker: $(cat "$T/b.err")"
[ ! -s "$T/b.out" ] && ok || bad "B2: a refusal prints no composition: $(cat "$T/b.out")"

# B3. --ref at a commit with no schema.d/ → rc 2, names the rev.
"$SB" --root "$B" --ref "$C1" --worker jobs >"$T/b.out" 2>"$T/b.err"; rc=$?
[ "$rc" = 2 ] && ok || bad "B3: --ref <rev with no schema.d> must be rc 2, got $rc"
grep -qF "schema-build.sh: $C1 has no worker/jobs/schema.d" "$T/b.err" \
  && ok || bad "B3: the error must name the rev and the path: $(cat "$T/b.err")"

# B4. an unresolvable rev → rc 2, names it.
"$SB" --root "$B" --ref no-such-rev --worker jobs >"$T/b.out" 2>"$T/b.err"; rc=$?
[ "$rc" = 2 ] && ok || bad "B4: --ref no-such-rev must be rc 2, got $rc"
grep -qF 'no-such-rev' "$T/b.err" && ok || bad "B4: the error must name no-such-rev: $(cat "$T/b.err")"

# B5. --ref with --check / --write → rc 2, and the working tree is untouched.
for m in --check --write; do
  "$SB" --root "$B" --ref HEAD --worker jobs "$m" >"$T/b.out" 2>"$T/b.err"; rc=$?
  [ "$rc" = 2 ] && ok || bad "B5: --ref with $m must be rc 2, got $rc: $(cat "$T/b.err")"
done
[ -z "$(git -C "$B" status --porcelain)" ] \
  && ok || bad "B5: a refused --ref must not touch the working tree: $(git -C "$B" status --porcelain)"

# B6. --ref composes the COMMITTED fragments, not the working tree.
printf 'CREATE TABLE IF NOT EXISTS j_WORKTREE (id INTEGER PRIMARY KEY);\n' > "$B/worker/jobs/schema.d/0001-b.sql"
"$SB" --root "$B" --ref HEAD --worker jobs --to "$T/b6.sql" 2>"$T/b.err"; rc=$?
[ "$rc" = 0 ] && ok || bad "B6: --ref HEAD --worker jobs --to must be rc 0, got $rc: $(cat "$T/b.err")"
cmp -s "$T/b6.sql" <(git -C "$B" show HEAD:worker/jobs/schema.d/0000-a.sql; git -C "$B" show HEAD:worker/jobs/schema.d/0001-b.sql) \
  && ok || bad "B6: --ref HEAD must give the committed bytes, got: $(cat "$T/b6.sql" 2>/dev/null)"
git -C "$B" checkout -q -- worker/jobs/schema.d/0001-b.sql

# ============================================================================
# H. bin/harness-sync.sh deploy composes schema.sql in the snapshot
# ============================================================================
ALERTS="$T/logs/ALERTS.log"
ULOG="$T/logs/update-runners.log"
NPXLOG="$T/npx.log"
printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$T/env/cloudflare.env"

# A fake npx that RECORDS instead of deploying. On `wrangler deploy` it copies
# the schema.sql the deploy cwd holds (the snapshot is dropped after the pass)
# and says whether the snapshot carries bin/schema-build.sh (H4).
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
T="$T"
EOF
cat >> "$T/fakebin/npx" <<'EOF'
args=$(printf '%s ' "$@" | tr '\n\t' '  ')
printf '%s | %s\n' "$PWD" "$args" >> "$NPX_LOG"
if [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "deploy" ]; then
  w=$(basename "$PWD")
  [ -f "$PWD/schema.sql" ] && cp "$PWD/schema.sql" "$T/deployed-$w.sql"
  [ -f "$PWD/../../bin/schema-build.sh" ] && echo yes > "$T/snap-has-sb"
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
mkdir -p "$T/ck/bin/lib" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" \
         "$T/ck/worker/jobs/schema.d" "$T/ck/worker/plain" "$T/ck/worker/bare"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
# The real composer and its bin/lib closure (bin/lib/d1-schema.sh), committed
# into the fixture so the deploy snapshot carries them (H4).
scratch_install_closure bin/schema-build.sh "$T/ck" >/dev/null \
  || { echo "FAIL: cannot install bin/schema-build.sh into the fixture"; exit 1; }
chmod 755 "$T/ck/bin/schema-build.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{
  "name": "jobs-test",
  "main": "src/index.js",
  "d1_databases": [
    { "binding": "DB", "database_name": "jobs-test-db", "database_id": "0000" }
  ]
}
EOF
printf 'CREATE TABLE IF NOT EXISTS t_a (id INTEGER PRIMARY KEY);\n' > "$T/ck/worker/jobs/schema.d/0000-a.sql"
printf 'CREATE TABLE IF NOT EXISTS t_b (id INTEGER PRIMARY KEY);\nINSERT OR IGNORE INTO t_b (id) VALUES (1);\n' > "$T/ck/worker/jobs/schema.d/0001-b.sql"
printf 'export default {};\n' > "$T/ck/worker/jobs/code.js"
# worker/plain: a committed schema.sql, no schema.d/.
cat > "$T/ck/worker/plain/wrangler.toml" <<'EOF'
name = "plain-test"
main = "src/index.js"
compatibility_date = "2026-07-01"
EOF
cat > "$T/ck/worker/plain/wrangler.jsonc" <<'EOF'
{
  "name": "plain-test",
  "d1_databases": [
    { "binding": "DB", "database_name": "plain-test-db", "database_id": "0001" }
  ]
}
EOF
printf 'CREATE TABLE IF NOT EXISTS p_one (id INTEGER PRIMARY KEY);\n' > "$T/ck/worker/plain/schema.sql"
# worker/bare: no schema at all, no D1 binding.
cat > "$T/ck/worker/bare/wrangler.toml" <<'EOF'
name = "bare-test"
main = "src/index.js"
EOF
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
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; rm -f "$T"/deployed-*.sql "$T/snap-has-sb"; }
d1_lines() { grep -F 'd1 execute' "$NPXLOG" 2>/dev/null; }
deployed() { grep -F 'wrangler deploy' "$NPXLOG" 2>/dev/null | grep -cF "/worker/$1 "; }
push() { git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "$1"; git -C "$T/ck" push -q origin main; }

# ── S0. SAFETY PROBE (from harness-sync-d1.bh-1000): a dirty checkout must
#    refuse at rc 30 into $HARNESS/logs/ALERTS.log, or the deploy path below
#    would rsync this fixture over the live /root/harness. ─────────────────────
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC, nothing in $ALERTS) —"
  echo "      refusing to run the deploy path, which would rsync this fixture over the live /root/harness."
  echo "schema-compose-deploy.bh-6005-0-test: $PASS pass, $((FAIL+1)) fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# ── H1. fragments, NO schema.sql: the composed file is applied and deployed ──
sync
[ "$RC" = 0 ] && ok || bad "H1: a clean deploy must exit 0, got $RC: $(cat "$T/err.txt")"
if [ -f "$T/deployed-jobs.sql" ] \
   && cmp -s "$T/deployed-jobs.sql" <("$SB" --root "$T/ck" --worker jobs 2>/dev/null); then
  ok
else
  bad "H1: worker jobs must deploy with a schema.sql byte-equal to the composition (deployed-jobs.sql $( [ -f "$T/deployed-jobs.sql" ] && echo differs || echo missing))"
fi
JOBS_D1=$(d1_lines | grep -F 'jobs-test-db' | tr '\n' ' ')
case "$JOBS_D1" in
  *"CREATE TABLE IF NOT EXISTS t_a"*"CREATE TABLE IF NOT EXISTS t_b"*"INSERT OR IGNORE INTO t_b"*) ok ;;
  *) bad "H1: the d1 execute calls for jobs-test-db must carry t_a, t_b, the INSERT, in order: ${JOBS_D1:-<none>}" ;;
esac
[ "$(printf '%s' "$JOBS_D1" | grep -oE 'CREATE |INSERT ' | grep -c .)" = 3 ] \
  && ok || bad "H1: exactly the composition's 3 statements go to jobs-test-db: ${JOBS_D1:-<none>}"
L_APPLIED=$(grep -nF 'worker jobs schema.sql applied' "$ULOG" | head -1 | cut -d: -f1)
L_DEPLOYED=$(grep -nF 'worker jobs deployed at' "$ULOG" | head -1 | cut -d: -f1)
[ -n "$L_APPLIED" ] && [ -n "$L_DEPLOYED" ] && [ "$L_APPLIED" -lt "$L_DEPLOYED" ] \
  && ok || bad "H1: 'schema.sql applied' (line ${L_APPLIED:-none}) must precede 'deployed at' (line ${L_DEPLOYED:-none})"
grep -q 'could NOT be composed' "$ALERTS" && bad "H1: a clean compose writes no ALERT: $(cat "$ALERTS")" || ok

# ── H4. the snapshot the deploy runs from carries bin/schema-build.sh ────────
[ "$(cat "$T/snap-has-sb" 2>/dev/null)" = yes ] \
  && ok || bad "H4: the deploy snapshot must carry bin/schema-build.sh"

# ── H5. worker/plain (committed schema.sql, no schema.d/) applies as today ───
PLAIN_D1=$(d1_lines | grep -F 'plain-test-db' | tr '\n' ' ')
case "$PLAIN_D1" in *"CREATE TABLE IF NOT EXISTS p_one"*) ok ;;
  *) bad "H5: worker plain's committed statement must go to plain-test-db: ${PLAIN_D1:-<none>}" ;; esac
cmp -s "$T/deployed-plain.sql" <(git -C "$T/ck" show HEAD:worker/plain/schema.sql) \
  && ok || bad "H5: worker plain must deploy with its committed schema.sql"
grep -q plain <<<"$(grep 'could NOT be composed' "$ALERTS" 2>/dev/null)" \
  && bad "H5: no compose ALERT may name plain: $(cat "$ALERTS")" || ok

# ── H5b. worker/bare (no schema, no schema.d/) deploys with no d1 and no ALERT
[ "$(deployed bare)" = 1 ] && ok || bad "H5b: worker bare must deploy: $(cat "$NPXLOG")"
[ "$(d1_lines | grep -cF '/worker/bare ')" = 0 ] && ok || bad "H5b: worker bare runs no d1 execute"
[ ! -s "$ALERTS" ] && ok || bad "H5b: the first pass must write no ALERT: $(cat "$ALERTS")"

# ── H2. round trip: the applied blob is in the object store, so the next
#    schema change is a delta, not a full apply ─────────────────────────────────
SHA1=$(git -C "$T/ck" hash-object "$T/deployed-jobs.sql" 2>/dev/null)
[ "$(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)" = "$SHA1 jobs-test-db" ] \
  && ok || bad "H2: the stamp must be '<deployed blob sha> jobs-test-db': $(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)"
git -C "$T/ck" cat-file -e "$SHA1" 2>/dev/null \
  && ok || bad "H2: the applied blob $SHA1 must be in the checkout's object store (hash-object -w)"
reset_run
printf 'CREATE INDEX IF NOT EXISTS ix_c ON t_a(id);\n' > "$T/ck/worker/jobs/schema.d/0002-c.sql"
push "a third fragment"
sync
grep -qF "worker jobs schema.sql applied (1 statements; 1 round trip(s); delta vs ${SHA1:0:7}) to jobs-test-db" "$ULOG" \
  && ok || bad "H2: the next change must be a delta vs ${SHA1:0:7}: $(grep 'worker jobs schema.sql' "$ULOG" | tail -1)"
JOBS_D1=$(d1_lines | grep -F 'jobs-test-db')
[ "$(printf '%s\n' "$JOBS_D1" | grep -c .)" = 1 ] \
  && ok || bad "H2: exactly one d1 execute for jobs-test-db: ${JOBS_D1:-<none>}"
case "$JOBS_D1" in *ix_c*) ok ;; *) bad "H2: the delta must carry ix_c: ${JOBS_D1:-<none>}" ;; esac
case "$JOBS_D1" in *t_b*) bad "H2: the delta must not re-send t_b: $JOBS_D1" ;; *) ok ;; esac

# ── H1b. a TRACKED schema.sql equal to the composition: the stamp says unchanged
reset_run
"$SB" --root "$T/ck" --worker jobs --to "$T/ck/worker/jobs/schema.sql"
printf 'export default { v: 2 };\n' > "$T/ck/worker/jobs/code.js"
push "track the composed schema.sql, move the code"
sync
grep -qF 'worker jobs schema.sql unchanged (' "$ULOG" \
  && [ "$(grep 'worker jobs schema.sql' "$ULOG" | tail -1 | grep -c unchanged)" = 1 ] \
  && ok || bad "H1b: tracked bytes equal to the composition must log 'unchanged': $(grep 'worker jobs schema.sql' "$ULOG" | tail -1)"
[ "$(d1_lines | grep -cF 'jobs-test-db')" = 0 ] \
  && ok || bad "H1b: no d1 execute may name jobs-test-db: $(d1_lines)"
[ "$(deployed jobs)" = 1 ] && ok || bad "H1b: the code still deploys: $(cat "$NPXLOG")"

# ── H3. the exit path: a compose that fails stops THIS worker only ───────────
reset_run
cp "$T/state/worker-deployed-jobs" "$T/wd.before"
cp "$T/state/worker-schema-applied-jobs" "$T/wsa.before"
printf 'stray\n' > "$T/ck/worker/jobs/schema.d/README"
printf 'export default { v: 3 };\n' > "$T/ck/worker/jobs/code.js"
printf 'CREATE TABLE IF NOT EXISTS p_two (id INTEGER PRIMARY KEY);\n' >> "$T/ck/worker/plain/schema.sql"
push "a stray README in schema.d/"
sync
[ "$RC" = 0 ] && ok || bad "H3: one worker's failed compose must not fail the sync, got $RC"
[ "$(grep -c 'could NOT be composed' "$ALERTS")" = 1 ] \
  && ok || bad "H3: exactly one 'could NOT be composed' ALERT, got $(grep -c 'could NOT be composed' "$ALERTS"): $(cat "$ALERTS")"
grep -q 'worker/jobs schema.sql could NOT be composed from schema.d at .* deploy of jobs SKIPPED' "$ALERTS" \
  && ok || bad "H3: the ALERT must name worker/jobs and say the deploy was skipped: $(cat "$ALERTS")"
[ "$(deployed jobs)" = 0 ] && ok || bad "H3: worker jobs must NOT deploy: $(cat "$NPXLOG")"
[ "$(d1_lines | grep -cF 'jobs-test-db')" = 0 ] && ok || bad "H3: no d1 execute may name jobs-test-db: $(d1_lines)"
cmp -s "$T/state/worker-deployed-jobs" "$T/wd.before" \
  && ok || bad "H3: state/worker-deployed-jobs must not change"
cmp -s "$T/state/worker-schema-applied-jobs" "$T/wsa.before" \
  && ok || bad "H3: state/worker-schema-applied-jobs must not change"
[ "$(deployed plain)" = 1 ] && ok || bad "H3: the other worker still deploys in the same pass: $(cat "$NPXLOG")"

echo "schema-compose-deploy.bh-6005-0-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
