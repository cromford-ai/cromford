#!/bin/bash
# tests/publish-cromford-append.bh-4901-test.sh — the public repo grows by one
# commit per publish, pushed without --force (BH-4901).
#
# bin/publish-share.sh used to commit the sanitized tree with no parent and
# force-push it, so the public repo had no history and every fork broke on each
# update. It now clones the published main, commits the new tree on top of its
# head only when the tree changed, and pushes a plain fast-forward.
#
# The real publisher runs from a scratch upstream repo. sanitize and the two
# guards are stubbed (the stubs log their argv), and the https URL of the
# public repo is rerouted with url.insteadOf to a local bare repo with
# receive.denyNonFastForwards on, so any force-push is refused by the remote.
#
#   A0  --dry-run names the published head it would build on and pushes nothing
#   A1  first publish onto existing history: parent is the seed, nothing upstream travels
#   A2  a second publish adds exactly one fast-forward commit
#   A3  an unchanged tree adds no commit
#   A4  no force anywhere: the remote refuses non-fast-forwards, and the script has no force push
#   A5  the message is "Cromford <date> (upstream <sha12>)", and both guards ran on it
#   A6  an empty remote gets one root commit
#   A7  an unreadable remote refuses a real publish; --dry-run goes on
#   A8  --force on an unchanged tree adds one commit with the same tree, with --summary
#   A9  a --summary with forbidden wording refuses before anything is pushed
#
# Run from anywhere: tests/publish-cromford-append.bh-4901-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -f "$DIR/bin/publish-share.sh" ] || [ ! -d "$DIR/bin/share" ]; then
  echo "SKIP publish-cromford-append: no bin/publish-share.sh or bin/share/ in this copy"
  exit 0
fi

unset SHARE_MIRROR_REPO
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=dummy-not-used
mkdir -p "$T/stub"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"
URL="https://github.com/cromford-ai/cromford.git"
# aim <path> — where the public repo's https URL really goes.
aim() {
  printf '[init]\n\tdefaultBranch = main\n[url "file://%s"]\n\tinsteadOf = %s\n' "$1" "$URL" > "$GIT_CONFIG_GLOBAL"
}
gc() { git -c user.name=t -c user.email=t@example.com "$@"; }

# ── the scratch upstream ─────────────────────────────────────────────────────
UP="$T/up"
mkdir -p "$UP/bin/share" "$UP/catalog" "$UP/tests"
cp "$DIR/bin/publish-share.sh" "$UP/bin/"
cp "$DIR/bin/share/mapping.py" "$UP/bin/share/"
[ -f "$DIR/bin/share/release_message.py" ] && cp "$DIR/bin/share/release_message.py" "$UP/bin/share/"
cp "$DIR/catalog/share-publish-targets.conf" "$UP/catalog/"
cat > "$UP/bin/share/sanitize.py" <<'PY'
import os, shutil, sys
src, out = sys.argv[1], sys.argv[2]
shutil.rmtree(out, ignore_errors=True)
def skip(d, names):
    rel = os.path.relpath(d, src)
    return [n for n in names if n == ".git" or (rel == "bin" and n in ("share", "publish-share.sh"))]
shutil.copytree(src, out, ignore=skip)
PY
# registry_guard: the publisher runs it first (BH-6494); this suite is about
# the append, so the scratch upstream carries no fleet registry and it is a stub.
for g in leakcheck gitleaks-gate registry_guard; do
  cat > "$UP/bin/share/$g.py" <<PY
import sys
open("$T/guard.calls", "a").write("$g " + " ".join(sys.argv[1:]) + "\n")
PY
done
printf '#!/bin/bash\nexit 0\n' > "$UP/tests/no-client-identifiers-test.sh"
echo "first content" > "$UP/content.txt"
gc -C "$UP" init -q -b main >/dev/null 2>&1
gc -C "$UP" add -A && gc -C "$UP" commit -qm "upstream one" || { bad "fixture: cannot commit the upstream"; }

# ── the public bare repo, seeded with one unrelated commit S ────────────────
PUB="$T/public.git"
git init -q --bare -b main "$PUB"
git -C "$PUB" config receive.denyNonFastForwards true
SEEDW="$T/seed"
git init -q -b main "$SEEDW"
echo "already public" > "$SEEDW/old.txt"
gc -C "$SEEDW" add -A && gc -C "$SEEDW" commit -qm "seed" && git -C "$SEEDW" push -q "$PUB" main:main
S=$(git -C "$PUB" rev-parse main)
aim "$PUB"

pub() { # <args…> — run the real publisher; rc to stdout, output in $T/last.out
  bash "$UP/bin/publish-share.sh" --repo cromford-ai/cromford --ref HEAD "$@" > "$T/last.out" 2>&1
  echo $?
}
show() { tail -8 "$T/last.out" | tr '\n' ' '; }

# A0 dry-run
rc=$(pub --dry-run)
if [ "$rc" = 0 ] && grep -q "would push .* to cromford-ai/cromford main as one new commit on ${S:0:12}" "$T/last.out" \
   && [ "$(git -C "$PUB" rev-parse main)" = "$S" ]; then ok
else bad "A0 --dry-run should name the head it builds on and push nothing (rc=$rc): $(show)"; fi

# A1 first publish onto existing history
: > "$T/guard.calls"
rc=$(pub)
H1=$(git -C "$PUB" rev-parse main)
if [ "$rc" = 0 ] && [ "$(git -C "$PUB" rev-parse 'main^' 2>/dev/null)" = "$S" ] \
   && [ "$(git -C "$PUB" rev-list --count main)" = 2 ] \
   && git -C "$PUB" merge-base --is-ancestor "$S" main; then ok
else bad "A1 first publish must land one commit on top of the seed (rc=$rc, count=$(git -C "$PUB" rev-list --count main)): $(show)"; fi
UP1=$(git -C "$UP" rev-parse HEAD)
git -C "$PUB" cat-file -e "$UP1" 2>/dev/null && bad "A1 the upstream commit $UP1 reached the public repo" || ok
[ "$(git -C "$PUB" show main:content.txt 2>/dev/null)" = "first content" ] && ok || bad "A1 the published tree lacks the upstream content"
grep -q "pushed ${H1:0:12} on ${S:0:12} to cromford-ai/cromford main (fast-forward)" "$T/last.out" && ok \
  || bad "A1 the success line should name the new commit and its parent: $(show)"

# A5 the message, and the guards on it
MSG=$(git -C "$PUB" log -1 --format=%B main)
if grep -qxE "Cromford [0-9]{4}\.[0-9]{2}\.[0-9]{2} \(upstream ${UP1:0:12}\)" <<<"$MSG" \
   && [ "$(grep -c . <<<"$MSG")" = 1 ]; then ok
else bad "A5 the pushed message is not 'Cromford <date> (upstream ${UP1:0:12})': $MSG"; fi
grep -qE '^leakcheck .*/msg$' "$T/guard.calls" && grep -qE '^gitleaks-gate .*/msg$' "$T/guard.calls" && ok \
  || bad "A5 leakcheck and gitleaks-gate must each run on the message dir: $(tr '\n' '|' < "$T/guard.calls")"
[ "$(grep -c '^leakcheck ' "$T/guard.calls")" = 2 ] && [ "$(grep -c '^gitleaks-gate ' "$T/guard.calls")" = 2 ] && ok \
  || bad "A5 each guard must run on the tree AND on the message: $(tr '\n' '|' < "$T/guard.calls")"

# A2 a second publish appends one commit
echo "second content" > "$UP/content.txt"
gc -C "$UP" commit -qam "upstream two"
rc=$(pub)
H2=$(git -C "$PUB" rev-parse main)
if [ "$rc" = 0 ] && [ "$(git -C "$PUB" rev-parse 'main^')" = "$H1" ] \
   && [ "$(git -C "$PUB" rev-list --count main)" = 3 ] \
   && git -C "$PUB" merge-base --is-ancestor "$H1" main; then ok
else bad "A2 the second publish must add exactly one commit on $H1 (rc=$rc, count=$(git -C "$PUB" rev-list --count main)): $(show)"; fi
LEAKED=0
for c in $(git -C "$UP" rev-list HEAD); do
  git -C "$PUB" cat-file -e "$c" 2>/dev/null && LEAKED=$((LEAKED+1))
done
[ "$LEAKED" = 0 ] && ok || bad "A2 $LEAKED upstream commit(s) reached the public repo"

# A3 unchanged tree: no commit
rc=$(pub)
if [ "$rc" = 0 ] && grep -q 'already identical' "$T/last.out" \
   && [ "$(git -C "$PUB" rev-parse main)" = "$H2" ] && [ "$(git -C "$PUB" rev-list --count main)" = 3 ]; then ok
else bad "A3 an unchanged tree must add no commit (rc=$rc): $(show)"; fi

# A4 no force: the remote refuses non-fast-forwards and A1/A2 got through it;
# the script has no force push in it.
[ "$(git -C "$PUB" config receive.denyNonFastForwards)" = true ] && ok || bad "A4 fixture lost denyNonFastForwards"
if grep -nE 'push[^|]*(--force|-f\b|\+main)' "$DIR/bin/publish-share.sh"; then
  bad "A4 bin/publish-share.sh still has a force push (above)"
else ok; fi

# A8 --force with an unchanged tree, plus --summary
rc=$(pub --force --summary "Faster triage")
if [ "$rc" = 0 ] && [ "$(git -C "$PUB" rev-parse 'main^')" = "$H2" ] \
   && [ "$(git -C "$PUB" rev-parse 'main^{tree}')" = "$(git -C "$PUB" rev-parse "$H2^{tree}")" ] \
   && [ "$(git -C "$PUB" log -1 --format=%B main | sed -n 3p)" = "Faster triage" ]; then ok
else bad "A8 --force must add one same-tree commit carrying the summary (rc=$rc): $(show)"; fi
H3=$(git -C "$PUB" rev-parse main)

# A9 a summary the message guard refuses
rc=$(pub --force --summary "regenerated mirror")
if [ "$rc" = 1 ] && [ "$(git -C "$PUB" rev-parse main)" = "$H3" ]; then ok
else bad "A9 a forbidden summary must refuse rc 1 and push nothing (rc=$rc): $(show)"; fi

# A6 an empty remote gets a root commit
EMPTY="$T/empty.git"
git init -q --bare -b main "$EMPTY"
git -C "$EMPTY" config receive.denyNonFastForwards true
aim "$EMPTY"
rc=$(pub --dry-run)
[ "$rc" = 0 ] && grep -q 'would push .* main as the first commit' "$T/last.out" && ok \
  || bad "A6 --dry-run onto an empty remote should say it would push the first commit (rc=$rc): $(show)"
rc=$(pub)
if [ "$rc" = 0 ] && [ "$(git -C "$EMPTY" rev-list --count main 2>/dev/null)" = 1 ] \
   && [ -z "$(git -C "$EMPTY" rev-list --min-parents=1 main 2>/dev/null)" ]; then ok
else bad "A6 an empty remote must get one root commit (rc=$rc): $(show)"; fi

# A7 an unreadable remote
aim "$T/does-not-exist.git"
rc=$(pub)
if [ "$rc" = 1 ] && grep -q 'cannot read the published head' "$T/last.out" && [ ! -e "$T/does-not-exist.git" ]; then ok
else bad "A7 a real publish onto an unreadable remote must refuse rc 1 (rc=$rc): $(show)"; fi
rc=$(pub --dry-run)
if [ "$rc" = 0 ] && grep -q 'treating as unpublished' "$T/last.out" && grep -q 'would push .* main, but the published head could not be read, so a real publish would refuse' "$T/last.out"; then ok
else bad "A7 --dry-run onto an unreadable remote must go on (rc=$rc): $(show)"; fi

echo "publish-cromford-append.bh-4901-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
