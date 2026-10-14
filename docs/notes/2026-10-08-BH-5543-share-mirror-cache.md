# The share suites read one mirror build per tree (BH-5543)

Doc: TEST-DETERMINISM

## What changed

- New library `tests/lib/share-mirror.sh`. It builds the public mirror the
  way `bin/publish-share.sh` does: export HEAD, plant the BH-5055 build record,
  build the verification-map index, run the three BH-1247 renders, then run
  `bin/share/sanitize.py`. It caches the result in `$SHARE_MIRROR_CACHE`
  (default `$TMPDIR/bh-share-mirror`).
- The cache key is the committed tree, every file under `bin/share/` as on
  disk, the library itself and the python3 on PATH. A python3 that cannot
  give its version gets a private build that is never cached.
- `tests/share-publish-clean.bh-795-test.sh`, `tests/share-mirror-clean-test.sh`,
  `tests/publish-cromford-brand.bh-4901-test.sh` and B7 of
  `tests/port-to-cromford.bh-5227-test.sh` read that build. Before, these four
  suites ran 5 full-tree sanitizes of the same tree per run, two of them in
  bh-795. Their assertions did not change.
- `tests/public-ci-green.bh-4083-test.sh` still builds its own tree, through
  `bin/publish-share.sh --dry-run`. That is a 6th full-tree build. Its subject
  is the real publisher end to end (gitleaks, guard, push decision), so a
  shared build made by this library would not test it.
- bh-795 arms 1-4 now also scan the index and the 12 renders, because the
  shared build is the publisher's tree. publish-cromford-brand reads the HEAD
  build on a clean checkout and makes a private build from the working tree on
  a dirty one.
- Each call writes one line to stderr and to `<cache>/share-mirror.log`:
  `built` (with the sanitize time alone), `reused`, `failed` or
  `private (<reason>)`. A failed sanitize is never stored.

## Knobs

`SHARE_MIRROR_CACHE`, `SHARE_MIRROR_LOCK_WAIT_S` (default 600: the longest
wait for another suite's build, then a private build) and
`SHARE_MIRROR_CACHE_KEEP` (default 2 builds kept).

## Not changed

CI shards suites by duration, so the two heavy share suites can land on
different runners. Each runner has its own `$TMPDIR`, so reuse across those
suites happens only on one machine: the builder gate, the pool suite run,
local runs and a shard that holds 2 or more of them.
