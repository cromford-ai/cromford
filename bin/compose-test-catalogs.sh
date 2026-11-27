#!/bin/bash
# bin/compose-test-catalogs.sh — compose the catalogs the worker suites import,
# before they run (BH-9268).
#
# worker/jobs/src/lib/core.js imports catalog/lanes.json, llm-sites-catalog.js
# imports catalog/llm-sites.json and routes/llm-sites.js imports
# catalog/context-budgets.json, each with a STATIC import at that fixed path.
# All three are git-ignored renders, so a fresh clone (the public copy, a fork)
# has none of them and `npm test` in worker/jobs or worker/otp-inbox (whose
# tests import the jobs test lib) fails on load. Upstream CI composes them in a
# workflow step; this script is that step as the suites' own `pretest`, so it
# runs wherever `npm test` runs.
#
# It composes all three into a private mktemp folder first. If any builder
# fails, it names that builder, exits 1 and writes NOTHING in catalog/: no
# partial or stale-mixed set. Then each file moves into catalog/ only when its
# bytes differ (cmp -s), with a mv on the same file system as the target, so a
# concurrent reader sees the old file or the new one, never half of one, and an
# unchanged run writes nothing.
#
# usage: bin/compose-test-catalogs.sh          (the repo is this script's ../)
# exit:  0 composed (or already current) | 1 a builder failed
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
TMP=$(mktemp -d) || { echo "compose-test-catalogs: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

"$ROOT/bin/lanes-build.sh" --root "$ROOT" --to "$TMP/lanes.json" >/dev/null \
  || { echo "compose-test-catalogs: bin/lanes-build.sh failed; catalog/ not changed" >&2; exit 1; }
"$ROOT/bin/llm-sites-build.sh" --repo "$ROOT" --compose --to "$TMP/llm-sites.json" >/dev/null \
  || { echo "compose-test-catalogs: bin/llm-sites-build.sh failed; catalog/ not changed" >&2; exit 1; }
"$ROOT/bin/context-budgets-build.sh" --repo "$ROOT" --compose --to "$TMP/context-budgets.json" >/dev/null \
  || { echo "compose-test-catalogs: bin/context-budgets-build.sh failed; catalog/ not changed" >&2; exit 1; }

for f in lanes.json llm-sites.json context-budgets.json; do
  [ -s "$TMP/$f" ] || { echo "compose-test-catalogs: $f came out empty; catalog/ not changed" >&2; exit 1; }
done

for f in lanes.json llm-sites.json context-budgets.json; do
  cmp -s "$TMP/$f" "$ROOT/catalog/$f" && continue
  # The temp copy sits beside the target, so the mv is a rename, not a copy.
  cp "$TMP/$f" "$ROOT/catalog/.$f.$$" && chmod 644 "$ROOT/catalog/.$f.$$" \
    && mv -f "$ROOT/catalog/.$f.$$" "$ROOT/catalog/$f" \
    || { rm -f "$ROOT/catalog/.$f.$$"; echo "compose-test-catalogs: could not write catalog/$f" >&2; exit 1; }
done
exit 0
