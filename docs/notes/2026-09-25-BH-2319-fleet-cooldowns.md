# Fleet cooldowns: the worker store (BH-2353, part of BH-2319)

Doc: DB-COORDINATION-SPEC

A 429 cooldown used to live only on the box that got refused, so every other box kept sending work to the refused account. This slice makes the `fleet_cooldowns` table real, so a cooldown written on one box can be read on every box. Nothing reads or writes it yet. The pickers and writers that will use it are later slices of BH-2319.

- **Table.** `fleet_cooldowns`, keyed `(kind, vendor, subject)`, is the contract's DDL from `worker/jobs/schema.sql`. `CREATED_TABLES.fleet_cooldowns` in `worker/jobs/src/lib/core.js` creates it the first time a route is called after `wrangler deploy`. There is no hand step.
- **Keys.** `kind` is `account`, `model` or `lane` (`COOLDOWN_KINDS`). Vendor and subject follow the `laneName` rule (`[A-Za-z0-9._-]{1,64}`). Only kind `model` may add one `/<account>` to the subject. Keys match exactly, so `account codex/default` never cools `account claude/default`.
- **Upsert** (`COOLDOWN_PUT_SQL`, one statement). `account` and `model` keep the later until, so a shorter write never shortens a cooldown. `lane` takes the new until. `since` keeps the first value it saw. reason, box and set_at take the new values. `until_at` is a TEXT column, so every comparison CASTs it to an integer.
- **Routes**, all behind the bearer:
  - `POST /api/cooldowns {kind,vendor,subject,until,since?,reason?,box?}` answers `{ok:true,row}`. An `until` more than 8 days out (`COOLDOWN_MAX_S = 691200`) is a 400 and is never clamped. `reason` is cut to 160 characters. Before the upsert, the route deletes at most 500 rows that expired more than 24 hours ago.
  - `POST /api/cooldowns/clear {kind,vendor,subject}` answers `{cleared:n}`.
  - `GET /api/cooldowns[?kind=]` returns live rows only (`until > now`), ordered by kind, vendor and subject, at most 500 of them. `truncated:true` means the cap came back full. Leave out `kind` to get every kind. An unknown kind is a 400.
  - All times are epoch seconds.
- **Shell.** `cooldown_put`, `cooldown_clear` and `cooldown_list` sit in `bin/lib/jobs/machines.sh`. `JC_MODULES` is unchanged. The worker branch of `bin/lib/fleet-cooldown.sh` calls them, loading `bin/jobs-client.sh` on the first call. It checks every module first and puts the caller's shell options back afterwards. `fcd_live` and `fcd_list` make one GET per kind per process, and a put or clear in that process drops that kind's memo. No client, no worker, or a truncated list reads as unknown (rc 2), never as "not cooling". A put the worker did not record adds one line to `logs/agent-rules.log` (`fleet-cooldown: put <kind>/<vendor>/<subject> not recorded (rc N)`) and still returns 0. The seam reads only the worker, never another box over ssh.
- **Write order for the writer slices.** Write the local cooldown file first, then call `fcd_put`. That way a worker outage never loses the local cooldown, and the row is a fleet-wide copy of a fact the box already holds.

Pinned by `worker/jobs/test/cooldowns.bh-2353.test.js`, `tests/fleet-cooldown.bh-2353-test.sh`, `tests/fleet-cooldown-contract.bh-2352-test.sh` and `worker/jobs/test/route-table.d/435-cooldowns.txt`.
