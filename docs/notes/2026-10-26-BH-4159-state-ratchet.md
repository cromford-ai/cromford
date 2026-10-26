# A ratchet on raw state/ writers in bin/, and the state store page (BH-4159 C0)

Doc: STATE-STORES

Slice C0 of #4159 (wave 7 of #4141, "no new file state").

## What changed

- New suite `tests/no-state-files.bh-4159-test.sh`. It is a delta ratchet
  (`tests/lib/ratchet-delta.sh`). It counts raw write sites to `state/<segment>`
  paths per `bin/` shell file at the base and at HEAD. It is red when the diff
  raises a file's count or adds a file with sites. The scanner is the BH-4154
  `flags/` scanner with a new path test: the first segment under `state/`
  decides, and an empty or dynamic first segment is a site.
- The allowlist is every path `catalog/state-paths.json` classes `cache` or
  `box-local`, plus `gh-policy-cache`. A PR allows a new path with a catalog
  row in the same PR. A catalog that cannot be read is red.
- The suite has no baseline. `--strict` and `RATCHET_MODE=strict` answer rc 2.
  `--list` and `--list-segments` print the live writer inventory.
- New page `docs/STATE-STORES.md`: each state family, its store now, and its
  raw writer count at main `63f61c581`.

## What did not change

- No `state/` directory is deleted. At main `63f61c581` every rollout family
  still has raw writers (`state/blocked-resolver` 82, `state/main-red` 28,
  `state/merge-conductor` 26, and more on the page). A delete now loses live
  records. C1 of #4159 is the drain lane: it deletes a family only at 0
  writers, dry-run first, archive before delete.
- The `flags/` half stays `tests/no-flag-files.bh-4154-test.sh`.
