# The pre-queue gate renders catalog/lanes.json before its rows share a checkout (BH-5775)

Doc: MERGE-CONDUCTOR

On 2026-10-09 the pre-queue gate failed #4040, #5140, #5659, #4967, #5784, #5776,
#5763 and #5273 with "share-mirror-clean: this suite rendered into the checkout it
was handed: catalog/lanes.json". The same heads passed share-mirror-clean on the Mac
and in CI.

## Cause
`bin/prequeue-invariants.sh --jobs 4` runs every invariant row in one fresh
checkout, four at a time. `catalog/lanes.json` is git-ignored, so that checkout has
none. share-mirror-clean takes a snapshot before its render step and another after
it. In the same slot, lanes-registry, config-inventory and rules-pack-contract
reached `lanes_json_path` with the checkout as root. The first of them rendered the
file inside share-mirror-clean's window. The result depended on timing.

A stale generated file was not the cause: a PR cannot carry `catalog/lanes.json`,
because git ignores it.

## Fix
The runner renders `catalog/lanes.json` once, through `lanes_json_path "$ROOT"`,
before any row starts. Rows then find a current render and write nothing.
share-mirror-clean still fails a suite that renders into its own checkout.

## Test
`tests/prequeue-invariants-render-race.bh-5775-test.sh` runs the real runner with
two rows that FIFOs put in order: a share-mirror-clean window and a loader. It was
red before the fix with the gate's exact message.
