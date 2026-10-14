# Repo readiness — grading a checkout before it is enrolled

Enrolling a project is a row in `fleet.conf`, a rendered prompt and five cron
lines. None of that asks whether the repo can actually be built, tested,
reviewed, QA'd and shipped by machines with nobody watching — so until now the
gaps were discovered by the first failed build, one at a time, on someone's
board.

`bin/readiness-report.sh` answers that question up front. It reads a checkout,
optionally runs the repo's own test command under a timeout, asks GitHub two
read-only questions, and prints a level 0–5 with every gap named. It is
deterministic: no model is called, and the same checkout grades the same way on
every box.

```bash
bin/readiness-report.sh <repo-dir>                  # the table
bin/readiness-report.sh <repo-dir> --json           # the object below
bin/readiness-report.sh <repo-dir> --no-run         # never execute the suite
bin/readiness-report.sh --print-levels              # the resolved level table
```

## The checks

Each check answers one of five statuses, and **only `pass` earns a level**:

| status | means |
|---|---|
| `pass` | the probe ran and found the thing |
| `fail` | the probe ran and the thing is not there |
| `unknown` | **the probe could not run** — `gh` unauthed, `npm` absent, `node_modules` missing. Never blocks, never passes. |
| `skipped` | you turned it off (`--no-run`, `READINESS_GH=0`) |
| `na` | the question does not apply (no migrations directory) |

`unknown` is the whole point of the third column. A readiness report whose
failure mode is a quiet yes would hand the fleet exactly the repos it cannot
build, so a probe that did not run says so and the level is computed without it.

| id | group | pass when |
|---|---|---|
| `tests.present` | tests | `package.json` `scripts.test` (npm's `no test specified` placeholder does not count), or `tests/*.sh`, or a pytest config, or `go.mod` with `*_test.go` |
| `tests.green` | tests | that runner exits 0 within `READINESS_TEST_TIMEOUT`. A timeout is a **fail**, not an unknown |
| `ci.workflow` | ci | a `.github/workflows/*.yml` that triggers on `pull_request` **and** invokes a test command inside a `run:` step. A `paths: ['tests/**']` trigger, an upload-artifact `path:` or a checkout path is not a command and does not count |
| `ci.branch_protection` | ci | `gh api repos/<slug>/branches/<default>/protection` answers. Only GitHub's `Branch not protected` is `fail`; a bare `Not Found` (the token cannot see the repo) and anything else that goes wrong are `unknown` |
| `ci.required_check` | ci | Report-only (no level reads it). `pass` when the protection rule has `required_status_checks`, or `gh api repos/<slug>/rules/branches/<default>` lists a `required_status_checks` rule. `fail` with `OWED: required status check` when both reads answer and neither requires a check. A read that fails is `unknown` |
| `preview.config` | preview | `vercel.json`, `.vercel/project.json`, `wrangler.toml`, `netlify.toml`, or a documented `preview … https://…` line in README/CLAUDE/AGENTS |
| `board.source` | board | an `/api/board` route dir, or `ai-build` in `.github/labels.*` or an issue template, or (when `gh` answers) the live `ai-build` label |
| `migrations.appliable` | migrations | a migrations dir whose `scripts/migrations/*.sql` pass `bin/check-migration-appliable.sh`. No migrations dir at all is `na`; a dir holding only shapes the linter cannot read (`prisma/migrations`, `supabase/migrations`) is `unknown`, never `pass` |
| `context.agents` | context | `AGENTS.md` or `CLAUDE.md`, non-empty |
| `context.arch` | context | `AGENT_ARCHITECTURE.md`, non-empty |
| `context.vmap` | context | `docs/verification-map/README.md`, non-empty — **or**, for a repo that generates its index and does not commit it (BH-1175), `docs/verification-map/index/head.md` plus at least one `docs/verification-map/entries/*.md` |
| `context.codegraph` | context | `.codegraph/` exists — **info only**, no level requires it |
| `context.conventions` | context | `.factory/` or `.agents/` — **info only** |
| `secrets.env_example` | secrets | `.env.example` / `.env.sample` / `.env.template` |
| `secrets.no_committed_env` | secrets | no `.env` and no `.env.<anything>` in the tree — `.env.vercel` and `.env.staging` leak exactly as `.env.production` does — except the declaring siblings `.env.example` / `.env.sample` / `.env.template`, which `secrets.env_example` requires. Tracked files when the dir is a repo root, every file otherwise; the detail names the **paths**, never the contents |
| `secrets.gitignore` | secrets | `.gitignore` carries a line covering `.env` itself: `.env`, `/.env`, `**/.env`, `.env*` or `*.env`. `.env.local` does **not** count — it covers a sibling, not `.env` — and neither does `.env.*`: git reads that dot literally, so it ignores `.env.local` and leaves the bare `.env` committable |

`stack` is reported and gates nothing: file count, primary language, framework
(`next`, `django`, `rails`, `go`, `cloudflare`, `unknown`) and whether the QA and
deploy-verify adapters cover that stack (`supported` for Next.js, `not-yet`
otherwise — that is a statement about what has been written, not about the repo).

## The levels

| level | adds (must `pass`) | must not `fail` | unlocks |
|---|---|---|---|
| 0 | — | — | any directory |
| 1 | `context.agents`, `secrets.no_committed_env` | — | a watcher can read the repo's own instructions, and enrolling it leaks no committed env file |
| 2 | `tests.present`, `secrets.env_example`, `secrets.gitignore` | — | a build can prove itself with a test run instead of a claim |
| 3 | `ci.workflow` | — | a PR carries a check the merge lanes can read |
| 4 | `preview.config`, `board.source` | `tests.green`, `ci.branch_protection`, `migrations.appliable` | eligible for tier-1 automerge — **policy only, see below** |
| 5 | `context.vmap`, `context.arch` | same | the planner's primer and the architecture contract render from the repo itself |

Levels are cumulative: level 4 means every requirement of 1–3 also passed.

**Level 4 is not wired to anything.** Nothing in `bin/run-build.sh` or
`bin/merge-conductor.sh` reads a readiness level today, and tiering is decided
where it always was. "Eligible for tier-1 automerge" is the sentence an operator
uses when deciding a tier by hand. Changing an enrolled project's tier was
explicitly out of scope for the ticket that built this, and writing it here as if
the machinery existed would be the kind of forward-written claim this repo blocks
PRs over.

## The gate

```bash
bin/load-project.sh <owner/repo> --require-readiness 4 --repo-dir <checkout>
```

Default is `0`: the gate block is skipped entirely, so nothing changes for any
project loaded without the flag. Above 0 it runs **before** `== validate repo ==`
— before the first `gh` call, the `fleet.conf` row, the prompt, the commit, the
push and the box bootstrap. A refusal therefore leaves the registry and the box
exactly as it found them, and says so.

It grades with `--no-run`: onboarding never executes the target repo's suite.
Run the report by hand first if you want `tests.green` graded.

It grades **once**, reads `--json`, and prints the checks from that same object.
The terminal and the verdict therefore cannot disagree, and the read-only `gh`
probes are asked once rather than twice.

Exit codes: `0` continued, `2` usage (`--repo-dir` missing, a non-integer level,
a level above the table's `max_level`), `3` refused. The refusal prints every gap
at or below the level you asked for.

The accepted range is `0`–`max_level` **as the level table states it**, not a
number written into `load-project.sh`: add a level 6 to
`catalog/readiness-levels.json` and `--require-readiness 6` starts working. `5`
is the fallback for a box whose catalog cannot be read at all.

## The JSON

```json
{
  "schema": 1,
  "repo": "/root/repos/<name>",
  "slug": "example-org/cromford",
  "level": 4,
  "max_level": 5,
  "levels_source": "/root/harness/catalog/readiness-levels.json",
  "ran_tests": false,
  "checks": [{"id": "tests.present", "group": "tests", "status": "pass", "detail": "…"}],
  "gaps":   [{"level": 5, "check": "context.vmap", "status": "fail", "detail": "…"}],
  "stack":  {"files": 412, "language": "ts", "framework": "next", "adapters": "supported"}
}
```

`gaps` is ascending by level and deduplicated, so the first line is the cheapest
thing to fix. `status` is one of the five above. `ran_tests` says whether the
repo's suite was actually executed. `slug` is the **graded checkout's own**
`origin` remote (empty when the directory is not a repo root or has no
github.com origin); `bin/load-project.sh` compares it with the repo it was asked
to enrol and refuses a mismatch, so a level computed from a sibling checkout can
never be read as this repo's.

## Knobs

| knob | default | what it does |
|---|---|---|
| `READINESS_TEST_TIMEOUT` | `600` | seconds the repo's suite may take. Over it: `tests.green fail`, detail `timed out after Ns` |
| `READINESS_GH` | unset (on) | `0` asks GitHub nothing; `ci.branch_protection` and `ci.required_check` read `skipped` |
| `READINESS_LEVELS` | unset | a level table, **used as given** — an unreadable path is rc 2, never a fallback |

Level tables resolve in the order every other catalog knob uses:
`$READINESS_LEVELS` → `$HARNESS/flags/readiness-levels.json` →
`<script-dir>/../catalog/readiness-levels.json` → `$HARNESS/catalog/readiness-levels.json`
→ the builtin copy inside the script. The builtin is the documented fallback for
a box that has `bin/` and not `catalog/`; `tests/readiness-report-test.sh` A1
pins it to `catalog/readiness-levels.json`, because a drifted fallback means a
repo's level depends on which box read it. A level table naming a check id that
does not exist is rc 2 — a typo must never silently relax a gate.

## Exit codes

`0` a report was produced. **The level is data, not an exit code**: the caller
decides what bar it wants, and a level-0 repo is a successful report about an
unready repo. `2` is usage: no repo dir, an unreadable one, an unknown flag, an
unreadable `$READINESS_LEVELS`, a level table naming an unknown check.

## Honest limits

- **A fresh clone grades `tests.green unknown`**, because dependencies are
  declared and `node_modules/` is not there. The detail says `run npm ci and
  re-run`. It does not block anything below level 4.
- **`--no-run` means nothing was executed.** `tests.green skipped` is not a green
  suite, and the gate uses `--no-run`, so passing `--require-readiness 4` never
  proves the tests run.
- **`ci.branch_protection` fails open.** An unauthed, rate-limited or offline
  `gh` is `unknown`, and an unknown never costs a level — the report must not
  refuse a repo for the state of the machine running it. That is also why a bare
  `Not Found` reads as `unknown`: GitHub returns 404 both for an unprotected
  branch and for a repo the token cannot see, and only the explicit `Branch not
  protected` distinguishes the first.
- **Pattern checks read text, not intent.** `preview.config` looks for `preview`
  and an `https://` on one line of README/CLAUDE/AGENTS, and `secrets.gitignore`
  matches whole `.gitignore` lines. A repo that writes either in an unusual way
  can grade `fail` on something it has; the gaps list names the check and the
  detail, so the fix is to add the ordinary form, not to argue with the report.
- **Only `scripts/migrations/*.sql` is linted.** That is the one shape
  `bin/check-migration-appliable.sh` understands. A Prisma or Supabase migrations
  directory therefore grades `unknown` — its SQL was never opened — which
  reports the limit instead of passing over it. `unknown` does not block, so the
  level is the same as it was; what changed is that the table no longer says the
  SQL is appliable when nothing looked at it.
- **Grading a subdirectory grades that subdirectory.** `git` questions are asked
  only when the directory is a repo root, so a path inside some other checkout is
  never graded against that checkout's remote.
- **The level is a floor, not a verdict.** It says the machinery is present. It
  cannot say the tests are good.
