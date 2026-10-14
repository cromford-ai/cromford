# gh wrapper, ledger, gate-self, hotfix and model-prices switches read as rows (BH-2442)

Doc: CONFIG

BH-2442 is slice 2 of BH-2408. It moves six more kill switches from a bare `flags/<name>` read to
`lane_switch <name> file` (`bin/lib/lane-switch.sh`):

| switch | reader | root the read uses |
|---|---|---|
| `gate-self-absorb-off` | `bin/lib/gate-self-comments.sh` (`_gsc_is_on`) | its `<harness>` argument |
| `gh-ledger-off` | `bin/gh-ledger/gh` | `$HARNESS`, else the harness the wrapper sits in |
| `gh-ledger-push-off` | `bin/gh-ledger-push.sh` | `$HARNESS` |
| `gh-shim-off` | `bin/gh-rest-shim` | `$HARNESS` |
| `hotfix-lane-off` | `bin/lib/hotfix-lib.sh` (`hotfix_lane_on`) | its `[harness]` argument |
| `model-prices-sync-off` | `bin/model-prices-sync.sh` | `$HARNESS` |

Each one is settled by the settings row `switch.<name>.<box>`, then `switch.<name>`, and only
with no row by the file. Every one of them has a `catalog/switches.d/<name>.json`, so
`bin/switch-migrate.sh --dry-run` lists it.

**Nothing changes on any box until a `switch.*` row exists.** The six reads use `file` mode: with
no row, a read answers `[ -f flags/<name> ]` and nothing else. It never asks `/api/flags` and
`pause_flags` does not drive it. Before, four of these reads were `[ -e`. They differ only for a
directory named `flags/<name>`, and nothing creates one.

Where the lib is missing, each file's loader line defines a fallback `lane_switch` that reads the
file. So a copy without `bin/lib/lane-switch.sh` answers what it answered before, and never exits.

`_gsc_is_on` called with no argument still answers "enabled" and reads nothing. The old read
checked `/nonexistent/flags/...`, which is never there.

**The two gh wrappers stay off the network.** `bin/gh-ledger/gh` and `bin/gh-rest-shim` run on
every `gh` call, so they call `lane_switch` with `LANE_GATE_CACHE_S=2147483647` for that one call.
Any `state/settings-cache.json` answers, whatever its age, with no `GET /api/settings`. The
wrappers see a new row once some other reader on the box has refreshed that shared cache. Every
lane that calls `lane_env_apply` does that, at most once per 60 s. One gap is left: a box with no
cache and no `.settings-miss` stamp sends ONE settings GET on its first wrapper call. That GET writes the cache or the stamp, and the calls after it read
those.

The ratchet drop is `tests/switch-ratchet.d/BH-2442.drop` = 5. `bin/gh-ledger/gh`'s `[ ! -e` was
never counted. The suite is `tests/switch-convert.bh-2408-gh-wrappers-test.sh`.
