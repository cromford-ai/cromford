# env-diff masks a credential inside a value, and the bootstrap smoke model comes from model_routes

Doc: MODEL-ROUTES

## What changed

- **`bin/env-diff.sh` judges the value, not only the key name.** `value_is_secret`
  masks a value that holds URL userinfo, a credential query parameter
  (`token`, `access_token`, `api_key`, `apikey`, `key`, `secret`, `password`,
  `pass`, `sig`, `signature`, `auth`, also after `_`/`-` joined words such as
  `auth_token`, `client_secret` or `x-api-key`), a token prefix (`sk-`, `sk-or-`, `ghp_`,
  `ghs_`, `gho_`, `ghu_`, `github_pat_`, `xai-`) or a 32+ character run of
  `[A-Za-z0-9_+=-]` holding both letters and digits. A masked value is stored as
  `sha256:<12 hex>`, the same form a secret-named key already used, and the item
  reads `<KEY> changed (value redacted)` in the beat, `logs/env-diff.log` and
  the ALERTS.log fallback.
- **The old snapshot is masked as it is read.** A box that ran the #1972 script
  before this fix can hold a raw credential in `state/env-diff/snapshot.tsv`. It
  is never echoed: a changed value reads `(value redacted)`, an unchanged one
  sends nothing, and the snapshot is rewritten masked on that tick. The same
  goes for the rows of an env file the tick cannot read: they carry forward
  masked, so a raw pre-fix row there is not written back and does not beat.
- **`bin/bootstrap-machine.sh` smoke test has no model literal.** BH-1510.4
  landed the same fix on main first: the `# >>> smoke model` block takes the
  `bootstrap.smoke` route from model_routes, and no route is FATAL. This
  branch's own `triage.light` fallback block was dropped in the merge with main
  in favor of that one; `tests/bootstrap-smoke-model.bh-1993-test.sh` now pins
  the shipped block.

## Why

BH-1993, the review follow-ups to #1972 and #1979. `RUNNER_URL=https://user:tok@host`
went out raw in a triaged fleet_alert because only the key name was checked.
`--model claude-haiku-4-5-20251001` would have broken bootstrap the day that id
retired.

## Choices a reviewer may want to revisit

- The masked form stays `sha256:<12 hex>` rather than a new
  `redacted:sha256:` marker. A new prefix would change every secret-named row
  already in every box's snapshot, and the first tick after deploy would send a
  spurious "changed" beat from every box.
- 40- and 64-character hex (git SHAs, sha256 digests) is masked too. A masked
  hash costs a lookup, an unmasked token is a leak.
- `triage.light` is the role, because `triage.floor` does not exist. No role
  was seeded.
- Not in this change: item 3 of BH-1993 (kanban `closedIssueKeys` paging). That
  code is only on the open PR #1987 (`ticket/bh-938`), not on main.
