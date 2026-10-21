#!/bin/bash
# tests/share-upstream-ci.bh-7536-test.sh — the publisher leaves the upstream CI
# fragments out of the mirror (BH-7536).
#
# BH-7536 split .github/workflows/harness-ci.yml into fragments under
# config/harness-ci/, rendered by bin/render-ci-workflow.sh. The rendered
# workflow was already dropped (DROP_FILES: it needs the CI_RUNNER variable, the
# merge queue and secrets), but the fragments shipped. Merge batch run
# 39578967883 went red on tests/share-publish-clean.bh-795: gitleaks read the
# gitleaks cache key in config/harness-ci/160-tests-shard/000-job.yml as a key,
# the same line .gitleaksignore waives on the rendered workflow. This suite
# drives the sanitizer over a scratch tree that carries the real fragments, the
# renderer and its suite, plus a control file, and checks what reaches the
# mirror.
#
# Run from anywhere: tests/share-upstream-ci.bh-7536-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SHARE="$DIR/bin/share"
export PYTHONDONTWRITEBYTECODE=1

if [ ! -f "$SHARE/sanitize.py" ]; then
  # The mirror does not carry bin/share: the publisher is upstream-only.
  echo "SKIP share-upstream-ci.bh-7536: no bin/share in this copy"
  exit 0
fi
if [ ! -d "$DIR/config/harness-ci" ]; then
  bad "this checkout has no config/harness-ci/ to drive the sanitizer with"
  echo "share-upstream-ci.bh-7536: $PASS pass, $FAIL fail, $SKIP skip"
  exit 1
fi

# ── a scratch source tree the sanitizer will accept ─────────────────────────
# sanitize.py applies its PATCHES after the rewrite and fails if a target is
# missing, so every patched file is copied in from this checkout.
SRC="$T/src"; M="$T/mirror"
mkdir -p "$SRC"
while IFS= read -r rel; do
  mkdir -p "$SRC/$(dirname "$rel")"
  cp "$DIR/$rel" "$SRC/$rel"
done < <(cd "$SHARE" && python3 -B -c '
import sanitize
for rel, _, _ in sanitize.PATCHES: print(rel)' | sort -u)
mkdir -p "$SRC/config" "$SRC/bin" "$SRC/tests"
cp -R "$DIR/config/harness-ci" "$SRC/config/harness-ci"
cp "$DIR/bin/render-ci-workflow.sh" "$SRC/bin/render-ci-workflow.sh"
cp "$DIR/tests/harness-ci-split.bh-7452-test.sh" "$SRC/tests/harness-ci-split.bh-7452-test.sh"
printf 'keep: 1\n' > "$SRC/config/keep.yml"
mkdir -p "$SRC/config/harness-cix"
printf 'keep: 1\n' > "$SRC/config/harness-cix/keep.yml"

# U1. sanitize runs clean over the tree.
python3 -B "$SHARE/sanitize.py" "$SRC" "$M" > "$T/sanitize.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok; else
  bad "U1 sanitize.py exited $rc"
  sed -n '1,30p' "$T/sanitize.out"
  echo "share-upstream-ci.bh-7536: $PASS pass, $FAIL fail, $SKIP skip"
  exit 1
fi

# U2. nothing at or under config/harness-ci reaches the mirror.
surv=$(find "$M" \( -path "$M/config/harness-ci" -o -path "$M/config/harness-ci/*" \) 2>/dev/null | head -1)
[ -z "$surv" ] && ok || bad "U2 the mirror carries ${surv#"$M"/} — upstream CI fragments must not ship"

# U3. the renderer and its suite stay out with their input.
for rel in bin/render-ci-workflow.sh tests/harness-ci-split.bh-7452-test.sh; do
  [ ! -e "$M/$rel" ] && ok || bad "U3 the mirror carries $rel — it needs config/harness-ci/"
done

# U4. the rule does not over-match: the controls ship.
for rel in config/keep.yml config/harness-cix/keep.yml; do
  [ -f "$M/$rel" ] && ok || bad "U4 $rel is missing from the mirror — the drop over-matched"
done

# U5. each drop is reported with its upstream-CI reason.
grep -F 'drop config/harness-ci/160-tests-shard/000-job.yml' "$T/sanitize.out" | grep -qF 'upstream CI fragments' \
  && ok || bad "U5 sanitize.out does not report the fragment dropped as upstream CI"
grep -F 'drop bin/render-ci-workflow.sh' "$T/sanitize.out" | grep -qF 'upstream CI renderer' \
  && ok || bad "U5 sanitize.out does not report the renderer dropped as upstream CI"

# U6. dropped() on the exact paths, with the near-miss controls.
D6=$(cd "$SHARE" && python3 -B -c '
import sanitize
for p in ("config/harness-ci", "config/harness-ci/160-tests-shard/000-job.yml",
          "config/harness-cix/a.yml", "config/mergify/x.conf", "docs/config/harness-ci/a.md"):
    print(p, "->", "drop" if sanitize.dropped(p) else "None")')
for want in "config/harness-ci -> drop" \
            "config/harness-ci/160-tests-shard/000-job.yml -> drop" \
            "config/harness-cix/a.yml -> None" "config/mergify/x.conf -> None" \
            "docs/config/harness-ci/a.md -> None"; do
  grep -qxF -- "$want" <<<"$D6" && ok || bad "U6 dropped(): expected '$want', got: $(echo $D6)"
done

echo "share-upstream-ci.bh-7536: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
