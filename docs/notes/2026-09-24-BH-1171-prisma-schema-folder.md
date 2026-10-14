# The harness regenerates the Prisma client on the prisma/schema/ folder layout too

Doc: MERGE-CONDUCTOR

## What changed

Prisma 7.5 can split the schema into a `prisma/schema/` folder, and project-5
#2744 moves project-5 onto it. Two harness guards ran `npx prisma generate`
only when `prisma/schema.prisma` existed, so on a folder-layout repo they
skipped the generate without a word and the typecheck after them read a stale
or missing generated client (`@/generated/prisma/client`).

- `bin/edit-feedback-hook.sh`: the background typecheck now runs
  `{ [ -f prisma/schema.prisma ] || [ -d prisma/schema ]; } && npx prisma generate`.
- `bin/rebase-train.sh`: the pre-verify regenerate has the same guard, inside a
  new `# >>> prisma regenerate (BH-1171)` marker block.
- `bin/draft-proposal.sh` (PRD prompt) and `prompts/product-stages/map.md`
  (company-map stage) tell the model to read `prisma/schema.prisma` or the
  `prisma/schema/` folder.

The generate stays bare, with no `--schema`, so Prisma resolves the path from
`prisma.config.ts` or `package.json` as before. A repo with neither layout
still runs no prisma at all.

`tests/prisma-schema-layout.bh-1171-test.sh` pins it. It drives the hook
through its stdin entry point and runs the train's marked line, both with a
stub `npx` that records its argv.

## What needed no change

| `schema.prisma` hit | Why it stays |
|---|---|
| `bin/rebase-train.sh` rebased-tree and baseline-worktree `npx prisma generate` | unconditional, already layout-agnostic |
| `fly/warm-env/{project-4,project-3}-os.env` (warm bake) | unconditional `prisma generate`; there is no project-5 warm env |
| `bin/lib/migration-files.sh` (migration apply path) | already lists `prisma/schema/*.prisma` (BH-1355) |
| `bin/lib/test-select.sh` | its pattern already matches the whole `prisma/` tree |
| `prompts/product-{project-4,project-3,project-1,project-2}-os.md` | describe those repos, which still use the single file |

## Known gap, left as is

The review-tier and lens risk regexes (`bin/lib/review-tier.sh`,
`bin/run-build.sh`, `bin/lib/rb/review.sh`, `bin/lib/rb/pr.sh`) match
`schema\.prisma`. A diff that touches only `prisma/schema/<domain>.prisma`,
with no migration or `.sql`, does not hit them. Widening them changes which PRs
auto-merge fleet-wide and their copies are byte-pinned by
`tests/review-tier-test.sh`, so that belongs to a follow-up ticket.

`bin/rebase-train.sh` is not wired for project-5 today (see the MERGE-CONDUCTOR
lane table), so the train half matters once it is, or for any other repo that
moves to the folder.

## Not verified here

The ticket's live check runs on the first project-5 build with
`EDIT_FEEDBACK=1` after #2744 and this change are both on main: the generated
client that `@/generated/prisma/client` resolves to is rewritten after the first
`.ts` edit, and neither the hook's delivered diags (`/tmp/edit-feedback-*/diags.txt`)
nor the build's tsc has an error on `@/generated/prisma/client`. The hook's own
`/tmp/edit-feedback-*/log` records only delivered feedback, not generate runs
(the generate's output goes to `/dev/null`), so it can't show the generate.
