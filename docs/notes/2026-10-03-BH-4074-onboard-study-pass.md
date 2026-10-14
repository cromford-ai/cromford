# Onboarding study pass: `bin/onboard-study.sh` (BH-4074, slice C0)

Doc: READINESS

## What changed

- New `bin/onboard-study.sh <repo-dir> [--json]`. It reads a checkout's root and
  reports:
  - `framework`: `nextjs` or null.
  - `commands`: `install`, `test`, `build`, `start`, `lint`, `e2e` and `deploy`.
    Install comes from the lockfile only (`npm ci`, `pnpm install
    --frozen-lockfile`, `yarn --frozen-lockfile`). With no lockfile it is null.
    The rest are the package.json scripts, run through that package manager. A
    command the checkout does not declare is null, not a guess.
  - `deploy`: config files it found (`vercel.json`, `fly.toml`,
    `wrangler.toml`, `scripts/deploy.sh`), always `"used": false`.
  - `contract_draft`: a `## Verification Contract` section. The first line of
    its first `bash` block is `install && lint && test && build`, which is the
    line `bin/batch-resolve.sh` reads. e2e goes in a second block. Deploy is
    never in the draft. With no test command the first block is empty, and the
    prose says no test command was detected.
  - `readiness`: `{level, max_level}` from `bin/readiness-report.sh --json
    --no-run`. If the grade fails, times out (300 s) or doesn't parse, you get
    null plus `readiness_error`, never 0.
  - `codegraph`: `indexed`, `failed` or `skipped`.
- Without `--json` it prints a summary, and the last line is
  `READINESS LEVEL: <n>/<max>` or `READINESS LEVEL: unknown`.
- It calls no model and runs none of the repo's own code (`--no-run`).
- Its one write is CodeGraph's: `codegraph init -i` creates `.codegraph/` in the
  checkout when the binary exists (`CODEGRAPH_BIN`, default `codegraph` on
  PATH).
- Exit 0 whenever it produced a report. Exit 2 on usage errors.

## Why

Step (2) of BH-4074: before a new project is enrolled, someone has to work out
how to install, test and build it, and what its verify line should be. This
does that reading the same way every time, and it leaves blanks blank.

## Scope

This is slice C0 of #4074, and nothing calls it yet. These are still pending,
each its own PR:

- C1: the onboarding state store and the console state chip.
- C2: the goals interview gate.
- C3: the rules render.
- C4: `bin/load-project.sh --onboard` wiring this command in, plus the project-15
  leakcheck patterns.

Test: `tests/onboard-study-pass-test.sh`, fixtures under
`tests/fixtures/onboard/`.
