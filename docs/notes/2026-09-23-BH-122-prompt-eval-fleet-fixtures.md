# Prompt evals cover five more projects, and the env scrub covers database keys

Doc: PROMPT-EVALS

## What changed

- **18 new golden scenarios** under `catalog/fixtures/golden/`, each named
  `<project>-<guard>`:
  - `project-1`, `project-3`, `project-4`, `project-8` (board-api): four
    each, for ready-launch, waiting-on-client, duplicate-PR and REVIEW_BLOCKED
    results sweep. Every `expected.txt` cites the line in that project's own
    prompt that makes the answer correct.
  - `project-6` (GitHub Issues): ready-launch and an open `Blocked-by`. These are
    the only two rules `prompts/project-6.md` states.
  People, companies, ticket ids (all 7000 or higher), threads and PR numbers are
  invented. Repo slugs, domains, API prefixes and key prefixes are real.
- **`scrub_env_names`** in `bin/prompt-eval.sh` also removes `*_SERVICE_ROLE_KEY`,
  `*_DB_URL` (and bare `DB_URL`), `POSTGRES_URL*` and `POSTGRES_PRISMA_URL`. The
  keep-list (`ANTHROPIC_*`, `CLAUDE_*`) is unchanged.
- **The two `"${SCRUB[@]}"` expansions** are written `${SCRUB[@]+"${SCRUB[@]}"}`.
  On bash older than 4.4 under `set -u` an empty array is "unbound", so an eval
  on a dev Mac with no credential-shaped vars would stop at the first expansion.
  CI runs bash 5, so the suite pins this with a static check. It does not
  reproduce it.
- `tests/prompt-eval-compose-test.sh` §5 moved its "no fixtures means NO
  SCENARIOS" case from `project-1`, which has fixtures now, to `project-9`.

## What it touches

- The weekly `prompt-eval.sh --cron` lane now makes 18 more metered calls. The
  coverage-debt alert is keyed on the set of uncovered projects, so it pages
  once when that set shrinks. That is by design.
- New projects start at NOBASELINE (record only). No baseline was recorded and no
  live call was made in this change.
- `project-6`'s decisions are keyed `TK-<issue>`, which its prompt never states.
  If the first live run shows MISSING plus a WARN extra there, fix the prompt.

## Tests

`tests/prompt-eval-fixtures.bh-122-test.sh` drives `bin/prompt-eval.sh` with a
recorder: scoping, `--dry-run` composition, grading (perfect answers, launch for
every key, silence), a sanitization lint, the scrub shapes, and the empty-array
guard.
