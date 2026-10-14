# Cost and lane caps as settings seed rows (BH-4155)

Doc: COST, verification-map

Slice C0 of BH-4141.3 ("runtime config catalogs to settings rows").

## What changed

- `worker/jobs/schema.sql` seeds every row of `catalog/cost-caps.conf` and
  `catalog/lane-caps.conf` as a `registry-seed` settings row, one
  `INSERT OR IGNORE` per statement (`conf.cost-caps.budget.<p>`,
  `conf.cost-caps.default`, `conf.cost-caps.ceiling`, `conf.lane-caps.lane.<l>`,
  `conf.lane-caps.noise.<l>`, `conf.lane-caps.default`). The values are the
  ones `bin/cost-caps-seed.sh --dry-run` derives from the files, and
  `tests/caps-seed-rows.bh-4155-test.sh` S1 holds the two equal. A re-apply
  never moves a row an operator, or an earlier seed run, wrote. The seed writes
  no audit row, the same rule as `POST /api/cost-caps/seed`.
- Because a seed row binds above the catalog file and INSERT OR IGNORE never
  moves one, the catalog would stop being the lever after the first deploy.
  So `bin/harness-sync.sh` now runs `bin/cost-caps-seed-sync.sh` on the hub
  (where `cloudflare.env` is), after the deploy stamp. When the two catalog
  files' bytes differ from the last seed that landed
  (`state/cost-caps-seeded`), it runs `bin/cost-caps-seed.sh`. That moves
  `registry-seed` rows only, never an operator's. The answer (changed and
  pruned keys) is appended to `logs/cost-caps-seed-sync.log`. A failure stamps
  nothing, retries on every sync, and writes one ALERTS line per catalog
  content. A reviewed catalog edit therefore reaches the running cap on the
  hub's next deploy (S7).
- `bin/lib/conf-row.sh` has a new reader, `conf_rows_seeded <file>`, for the
  cache's `seeded` map. `conf_rows` is unchanged, so the seven other resolvers
  still ignore seed rows.
- `bin/lib/cost-budget.sh` and `bin/lib/lane-caps.sh` now layer, lowest to
  highest: built-in defaults, the catalog file (only when no `flags/<file>` is
  readable), the seed rows, `flags/<file>` line by line, the operator rows. A
  refused seed row binds nothing and is named `seed:<key>` in the legacy-rows
  list. `cost_budget_source` / `lane_caps_source` join the layers that answered
  with ` + `; with no seed rows the string is what it was.
- `bin/pipeline-health.sh` writes one line per cost check to
  `logs/pipeline-health.log`:
  `<stamp> cost budget: source <layers>; ceiling $<n>; <p> $<rate>/PR <win> vs $<bud>/PR <TRIP|ok>; …`
  (`<p> n/e` when no window had enough PRs). `TRIP` is the costrate alert's
  predicate. ` halt=<done|fail|already|rearm|off:…>` follows it only when the
  rate also reached `COST_AUTOHALT_MULTIPLE` × budget and the pause was tried,
  so a bare `TRIP` is an alert, not a pause.

- Worker tests: `worker/jobs/test/cost-caps-schema-seed.bh-4155.test.js` pins
  the seed on a real schema.sql database (every row passes the cap grammar,
  `POST /api/cost-caps/seed` with the same rows changes and prunes nothing, an
  operator edit survives a re-apply, `GET /api/settings` serves the rows as
  `registry-seed`). Five older worker fixtures were written for a settings
  table with no cap row; they now call `clearCapSeeds(db)`
  (`worker/jobs/test/lib/d1-sqlite.bh-1030.js`) right after the schema to start
  from that table. No assertion in them changed.

## Behaviour on merge day

Unchanged, provided D1 holds no older `registry-seed` cap row from a hand run
of `bin/cost-caps-seed.sh`. INSERT OR IGNORE keeps such a row, and it now
binds. The first hub deploy re-seeds from the catalog anyway
(`state/cost-caps-seeded` starts empty), so any such row is pulled back to the
file on that deploy. The PR still asks for the per-key check before merge.
The seed values equal the file values, so every cap reads the same
number whichever layer answers. A box-local `flags/cost-caps.conf` or
`flags/lane-caps.conf` used to replace the catalog wholesale; it now applies
line by line above the seed rows, so a project it does not list gets its seeded
budget rather than the built-in default.

## Not in this slice

- C1 deletes the two catalog files and `bin/cost-caps-seed.sh`, drops the
  catalog layer from both readers, and rewrites the operator strings that name
  the files. Precondition: evidence the seed rows are in D1.
- C2-C6 move the other catalogs, `switches.d/*` and
  `lead-protected-paths.tsv`.
