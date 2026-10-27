# Prompt markers, version history, restore and drop head (BH-7972, BH-7940.4)

Doc: PROMPTS

## What changed

- `catalog/prompt-markers.json` has markers for `review` (`TIER:`,
  `VERDICT:`), `plan` (`## Requirements coverage`, `## ASSUMPTIONS`) and
  `rules` (the first `## ` line of each `rules/topics/NN-*.md`). A save of
  those kinds without its markers is now a 422 `missing_marker`. The other
  four kinds take any body.
- `worker/jobs/src/routes/prompt-history.js` adds `GET …/versions`,
  `POST …/restore?version=<n>` and `DELETE …/head`. Its fragment
  `test/route-table.d/bh-7940-prompt-history.txt` sorts before the contract's
  `bh-7940-prompts.txt`, so `…/versions` is not read as a version number.
- The retention fragment `retention.d/bh-7972-prompt-versions.js` archives a
  version outside the newest `prompts.retention.keep_versions` of its key,
  older than `retention.prompt_versions.days` (new row, 30), and not pointed at
  by a head. `ARCHIVE_TABLES` has a `prompt_versions` entry.
- New settings rows: `prompts.versions_list_max` (200) and
  `retention.prompt_versions.days` (30), in
  `worker/jobs/schema.d/202610270710-bh-7972-prompt-history-knobs.sql`.
- The console proxy admits the three new shapes. `PromptVersionsSheet` and
  `UseLevelAboveButton` are real components now.

## Why the age floor

The retention framework binds a days cutoff for every rule and writes it to
the audit row. The ticket asked only for "rank above keep_versions and not a
head". The 30 day floor also stops a burst of saves from archiving a version
that is minutes old.

## A topic heading change needs a catalog edit

A rules body must hold every topic heading. A PR that renames a heading in
`rules/topics/` must edit the `rules` list in `catalog/prompt-markers.json`
too. `rules-markers-match-topics` in
`worker/jobs/test/prompt-history.bh-7972.test.js` fails until it does.
