# C2: every fleet cron lane defaults to the GitHub App, not the operator's PAT

Doc: GH-REST

## What changed

- `bin/lib/gh-app-default.sh` (new) names the repo a `gh` invocation targets
  (`-R`/`--repo`/`GH_REPO`, a `repos/<o>/<r>` path, a github.com URL, GraphQL
  `owner=`/`name=` or `repository(owner:,name:)`, `gh repo <verb> o/r`, else
  the cwd's origin) and mints a cached installation token for it through
  `bin/gh-token.sh --min-life <knob>`. Only a `ghs_` answer is used: a mint that
  fell back to the PAT leaves the call on today's credential.
- `bin/gh-ledger/gh`, the first `gh` on every cron PATH, calls it before the
  real binary whenever `GH_TOKEN` and `GITHUB_TOKEN` are empty. Not for local
  commands (`gh auth token` stays the PAT ladder's last rung), not for nested
  calls, not for `gh_rest`'s own `api -i -X`. The ledger row then names
  `app-<installation>` instead of `pat-default`.
- `gh_rest` does the same for its one call: `_gh_quota_gate`
  (`bin/lib/gh-rest-ledger.sh`) now receives the path and picks the identity
  before it reads the bucket, so the reserve check and the ledger row name the
  bucket the request really spends. The token lands on a `GH_TOKEN` that
  `gh_rest` declares local (on its existing `local` line: `bin/lib/gh-rest.sh`
  stays at its 113-code-line ceiling), so the caller's shell has no token
  afterwards.
- `gh_ci_api` (`bin/lib/gh-ci-read.sh`): when both App reads failed and the
  caller holds no token, one last read goes out under `GH_USE_PAT=1`.
- Escape hatch: `GH_USE_PAT=1` never mints. With the keyring logged out it
  reads `env/gh-pat` (mode 600, one line: the PAT, `GH_TOKEN=`/`GH_PAT=`
  prefixes allowed). `bin/gh-token.sh`'s PAT fallback reads the same file after
  `gh auth token`.
- A failed mint is bounded and remembered: `timeout` of
  `GH_APP_DEFAULT_MINT_TIMEOUT_S` (15) around the mint, `curl -m 10` on the
  minter's JWT and rate-log calls, and a per-slug failure stamp
  (`state/gh-app-default.fail/`, `GH_APP_DEFAULT_FAIL_TTL_S`, 60) that sends
  that repo's calls straight to today's credential.
- `GH_LEDGER_OFF`, `flags/gh-ledger-off` and a caller's `GH_DEBUG` switch off
  the ledger, NOT the identity (which has its own switches).
- `bin/gh-token.sh --pat <slug>`: the PAT ladder only, never a mint.
- Keyring consumers switched to `bin/gh-token.sh`: `bin/fly-envbundle.sh` (the
  owning box's `gh-token.sh --pat <slug>`, see below; failure names the script
  and the repo), `bin/fly-image-build.sh` (`--fresh`), `bin/load-project.sh`
  (box preflight), `bin/publish-share.sh` (`--pat`: the mirror's owner is
  outside the App), `mc_git_auth` in `bin/lib/mc/rebase.sh` (`--min-life 600`,
  before the keyring), `gh_authed` in `bin/triage-map.sh` (an armed App route
  counts as authenticated).
- **The fly bundle stays on a PAT, on purpose.** `bin/fly-dispatch.sh` ships the
  bundle as-is with no token rotation, so a 1-hour installation token would 401
  the last push of any dispatch build past ~60 min, and a hub-App-authored PR
  cannot be APPROVEd by the same App in review-prs. The pool route replaces the
  line per machine with a rotated builders-App token (`bin/fly-pool.sh`), so
  pool builds are off the PAT already. On the hub (read-only check, 2026-09-24)
  every project has `flags/fly-pool-<p>` except `harness-console` (and a stale
  `state/fly/project-9.json`): harness-console is the one project still on the
  dispatch route. Moving the dispatch route to the builders App needs rotation
  in fly-dispatch first.
- Cadence as rows: `bin/lib/cadence-backstop.sh` sits in the conductor's */5
  and the resolver's */10 cron lines and lets a tick through once
  `lib.cadence-backstop.cadence_backstop_min_<lane>` minutes have passed (15 and
  30), or at once when `--wake-dir` holds a newer file (the resolver watches
  `state/merge-conductor/handoff`; the conductor's hourly `*.logged` markers are
  ignored). 0 = every tick. Fail-open.
- Tick-counted knobs stretch with the backstop and are documented, not
  rescaled: `BR_SATURATED_TICKS=12` (2h at */10, up to 6h), `BR_PER_TICK=4`
  (24 rungs/h → ~8/h plus wake runs; `lane.blocked-resolver.br_per_tick=12`
  keeps the old throughput), `MC_UNVERIFIABLE_ALERT_TICKS=6` (30 min → up to
  90 min with no webhook wakes).
- Known drift: `gh_token_identity` (`bin/lib/gh-push-identity.sh`) with no
  GH_TOKEN names the keyring login, while a example-org call from the same shell
  runs on the App.

## Knobs (catalog/lanes.d/_lib.gh-app-default.json, _lib.cadence-backstop.json)

| row | default | 0 means |
|---|---|---|
| `lib.gh-app-default.gh_app_default` | 1 | every call is the pre-C2 call |
| `lib.gh-app-default.gh_app_default_owners` | example-org | — |
| `lib.gh-app-default.gh_app_default_min_life_s` | 600 | — |
| `lib.gh-app-default.gh_app_default_mint_timeout_s` | 15 | — |
| `lib.gh-app-default.gh_app_default_fail_ttl_s` | 60 | no negative cache |
| `lib.cadence-backstop.cadence_backstop_min_merge_conductor` | 15 | every */5 tick |
| `lib.cadence-backstop.cadence_backstop_min_blocked_resolver` | 30 | every */10 tick |

No-DB kill switch for the identity change: `flags/gh-app-default-off`.
`flags/gh-app-tokens-off` and `GH_APP_TOKENS=0` still stop every mint.

## Rollout (an ops step after merge, not part of the PR)

1. Merge; `bin/fleet-propagate.sh` puts `bin/` on every box. The code is live
   with the keyring still logged in: nothing breaks if a mint fails.
2. Watch one hour of `state/gh-rest-ledger/*.tsv` per box: the cron callers
   (blocked-resolver, tickets-snapshot-push, wake-loop, pipeline-health,
   review-prs, run-preplan, triage) should move from `pat-default` to
   `app-<id>`. Whatever still reads `pat-default` has a target the lib cannot
   name; fix it before step 4.
3. Put the PAT in `env/gh-pat` (mode 600) on every box that lacks it:
   project-1, project-3-2, project-5, project-6, small, project-9. Use `fleet.conf`
   (`bin/fleet-conf.sh --projects`) for the box list; `env/fleet.env` is stale.
4. Per box: `bin/ensure-box-gh-app-default.sh <project>` (snippet, git
   credential helper, then the keyring logout).
5. Rollback, fastest first: `lib.gh-app-default.gh_app_default=0` (or touch
   `flags/gh-app-default-off`); `gh auth login --with-token < env/gh-pat` on a
   box that needs the keyring back; cadence rows to 0.

## Tests

`tests/gh-app-default.c2-test.sh`, `tests/fly-envbundle-app-token.c2-test.sh`,
`tests/cadence-backstop.c2-test.sh`. All three were red on origin/main before
the change.
