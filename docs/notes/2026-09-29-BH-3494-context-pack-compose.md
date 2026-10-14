# Decompose composes and publishes one context pack per child (BH-3494)

Doc: RUN-BUILD-GRAPH

Part of BH-3478 (Order 3 of 5). It builds on the wire from BH-3492
(`bin/lib/context-pack.sh`, `cp_put`).

## What changed

- New `bin/lib/context-pack-compose.sh`. It is sourced, never run, and makes
  no model call and no network call. It has one public function:
  `cp_compose <parent-plan.md> <parent-planned-files> <child-body-file-or-empty> <child-key> <parent-key> <n> <N>`.
  It prints the pack as markdown in a fixed order:
  1. `# Context pack: <CHILD> (<n> of <N>), split from <PARENT>`.
  2. `## Child scope`: the child's spec body. On the board lane there is no
     body, so it is the one line `read the ticket thread`.
  3. `## Parent file inventory`: the parent's `planned-files.txt`. When the body
     names at least one of its paths (fixed-string match), only those paths are
     listed, plus `filtered: k of m`. Otherwise the whole list is listed, plus
     `unfiltered`. An empty or missing list prints `unfiltered (0 paths)`.
  4. The parent plan's `##` sections whose heading starts (case-insensitively)
     with `System invariants`, `ASSUMPTIONS`, `Files to touch`, `Edge cases` or
     `Regression`, copied verbatim with their `###` sub-headings. Headings
     inside a ``` or ~~~ fence are not boundaries. A heading at any level that
     starts with `Sibling claims` ends the copy, so a claims list is never
     copied, even when it is nested.
- The cap is `CP_MAX_BYTES`, default 64000 bytes: the worker's 413 limit, so
  it is an env override for tests, not a settings row. Over the cap, sections
  are dropped in this order: Regression, Edge cases, Files to touch,
  ASSUMPTIONS. Each dropped section leaves `omitted: <section> (pack cap)` in
  its place. Scope, inventory and System invariants are never dropped. If the
  pack is still over the cap, it prints nothing and returns rc 3. Bad args or
  an unreadable plan give rc 1.
- `bin/run-decompose.sh` has a new `# >>> context packs (BH-3478)` block with
  `dcp_publish`. It is called on the issues lane after `file_children`
  returns 0, and on the board lane right after `# <<< board child keys`. That
  is after the label re-map and before `decomposed into:` and the parking
  POST. The board lane's DEC_FAIL arm exits before it, so no pack is written
  for an unmapped label.
  - For each line n of `children.txt`, with body `.[n-1].body` of
    `children.json` on the issues lane, it writes
    `$BUILD/context-packs/<CHILD>.md` and then calls `cp_put` with the base
    sha: `git rev-parse HEAD` in the cwd (the build worktree), or empty.
  - It writes one `pipeline.log` line per child: `context pack published|REFUSED|unreachable for <CHILD>`,
    `context pack unreachable (context-pack.sh missing) for <CHILD>`, or
    `context pack not composed (<why>) for <CHILD>`. The reasons are
    `bad child key`, `no spec entry <n>`, `compose lib missing`,
    `over the pack cap`, `compose rc=<rc>` and `write failed`.
  - `DECOMPOSE_DRY_RUN=1` still composes the files. It prints
    `would POST /api/context-packs <CHILD>` and logs
    `context pack dry-run for <CHILD>` instead of calling.
  - It never changes the script's exit code. `cp_put` runs with
    `JOBS_ALERT=0` and a closed stdin, so an unreachable worker is a log line
    and not a page. A missing pack only means the child plans cold, the way
    it does today.

## Known gap

`bin/planned-files.sh` keeps only paths under `src|prisma|scripts|e2e|tests|app|lib|components|pages|public|docs|content|middleware`.
So on cromford the inventory lists `tests/` and `docs/` paths and never
`bin/`, `worker/` or `catalog/`. The copied `Files to touch` section still
carries those paths verbatim. Widening the prefixes would change every
build's claim set, so it is out of scope here.

## Until #3493 deploys

The worker route `POST /api/context-packs` is BH-3493. Until it is live, each
child logs `REFUSED` (a 4xx such as 404) or `unreachable`, and the split
itself is unaffected.

Test: `tests/context-pack.bh-3494-test.sh`.
