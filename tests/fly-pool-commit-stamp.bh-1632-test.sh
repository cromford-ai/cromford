#!/bin/bash
# tests/fly-pool-commit-stamp.bh-1632-test.sh — every harness tarball a Fly
# machine receives carries HARNESS_COMMIT = the source checkout's full HEAD sha
# (BH-1632). Pool machines run from /data/harness with no .git, so without the
# stamp they can never report which harness they run.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }
W="$T"

REPO="$W/checkout"; mkdir -p "$REPO"/{bin,prompts,rules,catalog,fly}
echo x > "$REPO/bin/a"; : > "$REPO/fleet.conf"; : > "$REPO/vercel.conf"
git -C "$REPO" init -q && git -C "$REPO" -c user.email=t@t -c user.name=t add -A \
  && git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

# 1. the pool push helper (bin/fly-pool.sh uses it) stamps the full sha
. "$ROOT/bin/lib/harness-tarball.sh" || exit 1
TB="$W/pool.tgz"
harness_tarball "$TB" "$REPO" bin prompts rules catalog fleet.conf fly
got=$(tar xzOf "$TB" ./HARNESS_COMMIT 2>/dev/null || tar xzOf "$TB" HARNESS_COMMIT 2>/dev/null)
[ "$got" = "$HEAD_SHA" ] && ok "pool tarball HARNESS_COMMIT = HEAD" || bad "pool tarball HARNESS_COMMIT='$got' want $HEAD_SHA"
tar tzf "$TB" | grep -q '^bin/a$' && ok "pool tarball still carries bin/" || bad "pool tarball lost bin/"

# 1b. no git -> no stamp, tree still shipped, rc 2 so the caller can say so
NOGIT="$W/nogit"; cp -r "$REPO" "$NOGIT"; scratch_rm "$NOGIT/.git"
harness_tarball "$W/ng.tgz" "$NOGIT" bin fleet.conf; rc=$?
[ "$rc" = 2 ] && ok "no-git returns rc 2" || bad "no-git rc=$rc want 2"
grep -q HARNESS_COMMIT <<<"$(tar tzf "$W/ng.tgz")" && bad "no-git tarball has a stamp" || ok "no-git tarball has no stamp"
tar tzf "$W/ng.tgz" | grep -q '^bin/a$' && ok "no-git tarball still carries bin/" || bad "no-git tarball lost bin/"

# 2. bin/fly-sync-harness.sh end to end with a stubbed fly capturing the sftp'd tarball
H="$W/harness"; mkdir -p "$H/env" "$H/state/fly" "$W/stub"
echo 'FLY_API_TOKEN_DEMO=tok' > "$H/env/fly.env"; echo '{"app":"demo-app"}' > "$H/state/fly/demo.json"
cat > "$W/stub/fly" <<STUB
#!/bin/bash
case "\$*" in
  "ssh sftp put"*) cp "\$6" "$W/captured.tgz" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$W/stub/fly"
out=$(HARNESS="$H" HARNESS_ENV_DIR="$H/env" HARNESS_REPO="$REPO" PATH="$W/stub:$PATH" bash "$ROOT/bin/fly-sync-harness.sh" demo 2>&1); rc=$?
[ "$rc" = 0 ] && ok "fly-sync-harness rc 0" || bad "fly-sync-harness rc=$rc: $out"
got=$(tar xzOf "$W/captured.tgz" ./HARNESS_COMMIT 2>/dev/null || tar xzOf "$W/captured.tgz" HARNESS_COMMIT 2>/dev/null)
[ "$got" = "$HEAD_SHA" ] && ok "sync tarball HARNESS_COMMIT = HEAD" || bad "sync tarball HARNESS_COMMIT='$got' want $HEAD_SHA"
grep -q "harness@${HEAD_SHA:0:7}" <<<"$out" && ok ".sync-sha stays short" || bad "sync output: $out"

# 3. bin/fly-pool.sh push site goes through the helper
grep -q 'harness_tarball "\$TB" /root/harness-checkout' "$ROOT/bin/fly-pool.sh" && ok "fly-pool.sh uses harness_tarball" || bad "fly-pool.sh push does not use harness_tarball"

[ "$FAIL" = 0 ] && echo "PASS fly-pool-commit-stamp" || { echo "FAILED fly-pool-commit-stamp"; exit 1; }
