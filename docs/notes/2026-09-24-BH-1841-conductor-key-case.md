# The keyed conductor launch folds case on both sides

Doc: MERGE-CONDUCTOR

## What changed

Item 3 of BH-1831. GitHub slugs are case-insensitive, and a webhook's repo name
doesn't have to match fleet.conf's spelling. `bin/wake-loop.sh` built each
`MC_ONLY_PR` key from the raw webhook repo, and the conductor compared it
case-sensitively against fleet.conf. A key that differed only in case skipped
the project and filtered out the PR. The keyed launch did nothing, but it still
spent the per-tick cap and the `pr fleet` cooldown.

Three touch points, folded the same way:

- **Write:** `bin/wake-loop.sh` `drain` builds the key from the lowercased repo
  (the same `tr` that `repo_project` already uses), and dedupes on that form.
  `example-org/A 7` and `example-org/a 7` are one key: `example-org/a#7`.
- **Parse:** `bin/merge-conductor.sh` lowercases each `MC_ONLY_PR` token after
  the regex check and dedupes on the lowercased token. The `keyed tick: N key(s)`
  line shows each key the way the caller first spelled it, so an exact-case run
  logs the same thing it did before.
- **Match:** `mc_only_has` and `mc_only_slug` in `bin/lib/mc/classify.sh`
  lowercase the probe. The padded `" key "` and `" slug#"` shapes are unchanged,
  so folding can't turn into prefix matching.

Only the comparison folds. `$SLUG`, the `pr-state.tsv` keys, the closed-watch
memo paths and `gh -R` all keep fleet.conf's spelling, so no duplicate lowercase
rows appear.

## Spec change

`tests/conductor-wake-keyed.bh-1387-test.sh` case 5e now expects the lowercased
key `example-org/a#7` in `MC_ONLY_PR` and in the `pr/checks[...]` launch label.
Nothing parses that label.

## Tests

`tests/conductor-key-case.bh-1841-test.sh` drives the real `wake-loop.sh` (case A)
and `merge-conductor.sh` (cases B–F: a mismatched case ticks the PR under
fleet.conf's spelling, exact case matches #1387 case 6, no prefix matching,
two spellings count as one key, and inverse case).
