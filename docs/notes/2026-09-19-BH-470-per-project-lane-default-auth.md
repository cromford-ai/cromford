# Eleven per-project lanes default to the App identity, and `--status` stops printing `?/?`

Doc: OPERATOR-SETUP

**What changed.** #424 order 2 of 3. Two things, both from the issue body.

- **Eleven lanes wired.** `bin/run-triage.sh`, `bin/run-build.sh`,
  `bin/run-product.sh`, `bin/review-prs.sh`, `bin/rebase-train.sh`,
  `bin/deploy-train.sh`, `bin/check-migration-prs.sh`,
  `bin/tier2-merge-sweep.sh`, `bin/wake-loop.sh`, `bin/claude-auth-check.sh` and
  `bin/fly-pool.sh` each source `bin/lib/gh-app-auth.sh` and
  `bin/lib/gh-limit-logger.sh` behind `[ -r … ] &&` guards and call
  `gh_default_auth_for_project "$PROJECT" || true`. Every region is delimited
  `# >>> gh default auth` … `# <<< gh default auth` (`run-triage.sh` keeps its
  older `# >>> triage github auth` name), and the three lanes that arm per row —
  `tier2-merge-sweep`, `wake-loop`, `claude-auth-check` — put the process default
  back in a `# >>> gh default auth reset` region straight afterwards.
- **`bin/gh-token.sh --status` never prints `?/?`.** A new `rate_pair` helper
  reads `.rate` OR `.resources.core`; on this installation only the second is
  populated, which is why every line read `?/?`. An unparseable or
  unauthenticated body prints `remaining=0/0` plus ONE stderr line naming the
  slug. One line per cache file, output shape otherwise unchanged.

**Why the call is guarded.** `gh_default_auth_for_project` is slice 1's (#469,
PR #911) and is NOT on main: `grep -rn gh_default_auth_for bin/` found nothing
and `bin/lib/gh-limit-logger.sh` does not exist. The issue quotes a bare call,
which would print `command not found` on every tick until #469 merges — so every
site is `command -v`-guarded and, where a lane already armed through
`gh_auth_for` / `gh_auth_for_url`, that call survives as the else-branch. On this
merge base the new lines are inert: no guard passes, nothing forks, and each lane
behaves byte for byte as it did. When #469 lands they take over with no second
edit. `--status` works today either way.

**The one lane edit that is not additive.** `bin/run-triage.sh`'s auth block
MOVED from line 9 to just below `set -a; . global.env; set +a`, comment included.
It sat above the env load, and `env/global.env` carries a `GH_TOKEN=` line — so
the load could overwrite the App token the block had just exported, and
`gh-app-auth.sh` snapshots "the token this shell started with" AT SOURCE TIME,
which on an unarmed box was an unset `GH_TOKEN` that a later
`gh_default_auth_reset` would have restored over the PAT. The issue's "after the
env-loading block" is read literally.

**Where the call sits when placement matters.**

- `review-prs.sh`: BELOW the `bin/lib/gh-ci-read.sh` source, so that lib's
  fallback rung still captures the PAT as `GH_CI_READ_TOKEN=default`.
- `fly-pool.sh`: BELOW the `bin/lib/gh-repo-token.sh` source, for the same
  reason — that lib captures the caller's token when it is sourced, and its
  ladder needs the box PAT as a rung. Per-machine minting in `spawn_one`, the
  `POOL_GH_TOKEN_*` rotation and the env-bundle swap read FILES, not this
  variable, and are untouched.
- `claude-auth-check.sh`: AFTER `HOW=$(gh_repo_pat_for "$SLUG")` inside
  `gh_visibility_canary`. That canary's question is PAT-only by design (BH-765);
  arming above the probe would change no answer but would let #469's logger tag a
  rate-limited PAT call `app:<slug>` — a tag that lies. This lane has no `gh`
  consumer of its own today, and the call is kept anyway because the issue's
  own acceptance grep names all eleven files.
- `run-build.sh`: `gh_default_auth_for_project "$PROJECT" || gh_auth_for
  "$GH_AUTH_SLUG" || true`. rc 1 means fleet.conf has no row for the project — a
  pool builder carrying only `REPO_SLUG`, or a box mid-sync — and the
  remote-derived slug is what that build used before #469.

**What it touches.**

- State: nothing new. The only store read is `state/gh-app-tokens/<slug>.json`,
  owned by `bin/gh-token.sh`. Eleven lanes on one project buy ONE token.
  `GH_LIMIT_IDENTITY` is process-scoped.
- Knobs: none new. `env/github-app.env`, `GH_APP_TOKENS=0` and
  `flags/gh-app-tokens-off` are the same three offs as the rest of #425.
- Ratchet: `check-migration-prs.sh` now names a token helper, so
  `tests/gh-app-ratchet-test.sh` reads it as ARMED and its line is removed from
  `tests/gh-app-ratchet-baseline/part5-metrics.txt` (the count only goes down).
  `run-product.sh` and `claude-auth-check.sh` become textually armed too; neither
  was ever baselined.
- `rate_log()` in `bin/gh-token.sh` (lines ~202-210, the per-MINT
  `logs/gh-rate.log` line) has the same `.rate`-only parse and KEEPS its `?`
  placeholders. The ticket names `do_status`, nothing reads `gh-rate.log`
  programmatically, and changing a log line's shape is its own decision.
  `do_status` has no programmatic consumer either — `grep -rn -- '--status' bin/
  checks/ cron/ console-ui/src` finds only the script's own usage string — so
  the `?/?` → `0/0` swap can break nothing but an operator's expectation, which
  the map entry and this note record.
- Log lines: no new class. `run-triage.sh`'s existing `triage github auth: App
  installation token for <slug>` line is unchanged and still fires on a `ghs_*`
  token. `--status` gains its one stderr note.

**How it is proven.** `tests/gh-default-auth-lanes-test.sh` extracts each lane's
marked region VERBATIM from the shipped script and runs it in a scratch shell
against a stubbed GitHub, then asserts on values, not on source text: `GH_TOKEN`
equals the cached App token, `GH_LIMIT_IDENTITY=app:<slug>`, the logger path was
sourced, eleven lanes = one mint, an unarmed box keeps its own token, a box with
neither library still exits 0, the three per-row lanes come back to the process
default, and no token value reaches a log. The `--status` half drives the real
`bin/gh-token.sh` CLI on four `/rate_limit` bodies. The suite says on stdout when
it has had to stand in for #469's helper, which it does on this merge base.

**Still owed.** #469 itself — until it merges, the eleven guarded calls are
inert and the real `bin/lib/gh-limit-logger.sh` does not exist, so no
`gh-limit identity=` line can appear on a box yet. When the train rebases this
branch behind #469, any suite that asserts mint ORDER around `bin/fly-pool.sh`
deserves a re-read: the tick-level arming then runs before `spawn_one`'s
per-machine mint, and the cache makes it one mint rather than two.
