# BH-9335 (slice C0) — self-host setup for API key fleets

Doc: OPERATOR-SETUP, SELF-HOST

## What changed

- `bin/selfhost-install.sh` reads a new setting, `SELFHOST_RUNNER_LOCK` (blank
  or `claude`). When `SELFHOST_MODEL_AUTH=api-key` or the lock is `claude`, the
  dry-run prints one `SETTING` line per row and project:
  `claude_auth.<p>`, `runner_lock.<p>` (lock only) and `cost_ceiling.<p>`
  (`SELFHOST_CAP_USD_DAY`, or `skip(caps off)`). With `api-key` it also names
  one Fly secret per project, `ANTHROPIC_API_KEY_<PROJECT>` (upper case, `-` as
  `_`). It never asks for a key value. With `oauth` and no lock the plan is
  byte-identical to the plan before this change
  (`tests/fixtures/selfhost/oauth-plan.bh-9335.golden`).
- `env-templates/lanes/030-llm-runners.env.example` carries two commented
  blocks, OAuth and API key. The operator sets one of the two.
  `env-templates/global.env.example` stays a git-ignored render (BH-1247), so
  the docs say to run `bin/render-env-example.sh --write` before the copy.
- `docs/OPERATOR-SETUP.md`: the Anthropic row lists both paths and says the API
  key is metered and needs a Console spend limit. The global.env block and the
  variable table say "one of the two".
- `bin/fly-idle-check.sh` and `bin/vendor-spend-pull.sh` no longer fall back to
  the `personal` Fly org. Without `FLY_ORG`, fly-idle-check writes one ALERTS
  line that names `FLY_ORG` and exits 1. vendor-spend-pull writes a fly row with
  status `error` and makes no Fly call.
- The public mirror ships `catalog/account-aliases.json` and
  `catalog/cost-accounts.json` as `{}` (overlay files under
  `bin/share/overlay/catalog/`).
- `bin/lib/pool-account.sh` did not change. A new test pins that an empty pool
  (no `accounts.d`, no `tokens.d`, `{}` aliases) answers `name=default` with no
  lease and no alert.

## Not in this slice

These need #9334 and come in slice C1: the console Auth, Runner lock and Daily
ceiling columns, the `api-key` arm of the pool test, and the links to the
"API key projects" section from `docs/SELF-HOST.md` and
`docs/choosing-models.md`.
