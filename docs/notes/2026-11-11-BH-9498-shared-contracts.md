# Shared contracts: a per-repo fragment dir, carried to the plan by the primer, checked at the plan gate (BH-9498)

Doc: PLAN-CONTRACT

## Why

Some rules come with a kind of path, not with a ticket. A new project-6
migration needs a `-- tenancy:` header (project-6#3802). A new cromford
cron lane needs its `catalog/lanes.d` fragment. Each rule had a CI check, but no
plan named it, so the build learned it from a red CI run and paid a fix round.
This is slice C1 of BH-9441 (scope item 2).

## What changed

1. A repo declares its contracts in `catalog/shared-contracts.d/*.tsv`. One
   row per contract, 5 TAB-separated fields:
   `<id> <when: new|any> <path-glob> <requires> <enforced-by>`.
   `#` lines and blank lines are skipped. A bad row, or a duplicate id (the
   C-order first file wins), is not used and shows as `BAD: <file>:<line> <why>`.
2. `bin/verification-map.sh render` prints a `--- SHARED CONTRACTS` section in
   the primer (after AGENT ARCHITECTURE, before CONFLICT HOTSPOTS), one line per
   contract with its citation, then a PLAN and an EXECUTE instruction. The
   `Sources:` line gets `shared-contracts=<yes|no|bad|unknown>` before
   `conflict-hotspots=`. With `--contracts-out <file>` it writes the build file:
   `# repo: <abs path>`, then one 6-field row per contract.
3. `bin/lib/rb/plan.sh` passes `--contracts-out "$BUILD/shared-contracts.tsv"`.
4. `bin/plan-gate.sh` reads `shared-contracts.tsv` beside the plan, or
   `PLAN_GATE_CONTRACTS=<file>`. A contract is triggered by a plan path that
   matches its glob (`*` crosses `/`); for `new`, the path must also be absent
   from the repo. Paths in fences, under `## Sibling claims`, under `## Verify`
   and on VALIDATE lines do not trigger. An id is listed when it is a whole token
   (any case) under a heading that starts "Shared contracts". An unlisted id
   prints `  UNTRACED: shared contract — <id>: <requires> (triggered by <path>)...`
   and `PLAN_CONTRACTS: unlisted`, rc 2. The existing repair pass gets the line.
   No file: no line. A file or repo it cannot read: `PLAN_CONTRACTS: unread`, no
   refusal.
5. cromford declares `lane-registry` (any `cron/*.cron`) and
   `schema-fragment` (a new `worker/*/schema.d/*.sql`) in
   `catalog/shared-contracts.d/bh-9498-cromford.tsv`.

`prompts/stages/*.md` do not change: the stage prompts already tell every stage
to read the primer first.

## Knob

`SHARED_CONTRACTS_ENFORCE` (`catalog/lanes.d/_lib.shared-contracts.json`, lib id
`shared-contracts`): 1 (default) refuses; 0 prints a `NOTE: shared contract`
line and `PLAN_CONTRACTS: unlisted (not enforced, SHARED_CONTRACTS_ENFORCE=0)`.
The code fallback is `SC_DEFAULT_ENFORCE=1`.

## How a repo adds a contract

Add a new file `catalog/shared-contracts.d/<key>-<slug>.tsv` in that repo. Do
not append to another ticket's file. project-6 should add:

    migration-tenancy-header	new	prisma/sql/*.sql	every new migration starts with a -- tenancy: <class> header	the tenancy-class check (DT-1)

That row belongs to the project-6 repo; this PR does not write there.

Test: `tests/shared-contracts.bh-9498-test.sh`.
