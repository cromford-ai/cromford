# BH-6487: catalog/context-budgets.json is composed from catalog/context-budgets.d/

Doc: docs/CONTEXT-COMPOSITION.md

What changed: every new LLM lane appended one object to the `lanes` array of
`catalog/context-budgets.json`. Two builds that each added a lane both put a
comma on the same closing `    }` line and both inserted before the same
`  ],`. That is a guaranteed conflict on a hunk no ticket is about. This is the
last part of BH-4987 item 4 (the operator, comment 6102470248).

`lanes` is in the middle of the top-level object, so the sources have a head
and a tail. They are in `catalog/context-budgets.d/`:

- `_head.json`: the keys before `lanes` (`_doc`, `_purpose`, `_units`, `_measured`).
- `_tail.json`: the keys after `lanes` (`_key`, `_measured_note`,
  `_unbudgeted_stages`, `_bound_scopes`).
- `0000-base.json`: the first 43 lanes, text verbatim.
- `5561-staff.json`: the `staff` lane (BH-5561), so the first deploy already
  reads a non-base fragment.
- `NNNN-<lane>.json`: one NEW file per added lane, NNNN = the ticket number. It
  is a JSON array. Its first line is `[` and its last line is `]`.

`bin/context-budgets-build.sh` composes `catalog/context-budgets.json` from
them. At the split commit the composition is the old file byte for byte. The
composed file is git-ignored and not committed.

Rules the composer enforces (rc 2, the old file stays, nothing is written):

- `_head.json` or `_tail.json` missing, not a JSON object, with a `lanes` key,
  or without its bare brace line(s).
- `_head.json` and `_tail.json` that share a key.
- A file name that is not `_head.json`, `_tail.json` or
  `^[0-9]{4}-[a-z0-9][a-z0-9._-]*\.json$`.
- A fragment that is not a non-empty array of objects with a string `lane`, or
  does not open with a line `[` and close with a line `]`.
- No fragment, a composition that does not parse, or a lane twice.

`--check` is rc 1 when `catalog/context-budgets.json` is TRACKED while the
directory exists (a hand edit of the composed form), or when two compositions
differ. CI runs it in "the derived docs generate and their gates pass". With no
`catalog/context-budgets.d/` the committed file is the source (legacy mode).

Who composes it, at the same path, so every reader reads it unchanged:

- `bin/harness-sync.sh` default mode, before the `catalog/` rsync. Every hub
  and box sync runs it. A refused compose is one ALERT per box
  (`--id budgets-compose-<host>`); the last good file stays.
- `bin/harness-sync.sh` `deploy_workers`, in the worker snapshot, before
  `wrangler deploy`. The fragments and the composer join the jobs worker's
  change key as `-budgets-<sha>`. A refused compose is one ALERT and no deploy.
- The budget DB sync: its sha is now `git rev-list -1 HEAD -- catalog/context-budgets.d catalog/context-budgets.json`,
  so a fragment-only commit still re-pushes `budget_catalog`.
- `tests/lib/scratch.sh`, once, when a suite sources it. This replaces one
  line in each of about 100 suites. It never exits on a refused compose.
- CI's worker-jobs and tests-shard steps, the nightly shard step,
  `bin/prequeue-worker-schema.sh`, `bin/rules-pack.sh` `rp_lanes_render`,
  `bin/publish-share.sh` and `tests/evals/run-evals.sh` (CI runs that one
  without scratch.sh).

`bin/test-impact.sh` maps a changed `catalog/context-budgets.d/<x>.json` to
`catalog/context-budgets.json`, so the suites that read the manifest are still
selected.

Not changed: `MC_UNION_FILES_DEFAULT` still lists `catalog/context-budgets.json`.
A branch from before the split that edits the old file gets a modify/delete
conflict, the union step declines it, and a fix round moves the lane into a
fragment. Messages that say "add a lane to catalog/context-budgets.json" stay;
this note and `docs/CONTEXT-COMPOSITION.md` say where the lane file goes.

Rollout check (operator): on the hub, `state/worker-deployed-jobs` carries
`-budgets-`, and the last `budget catalog synced` line in
`logs/update-runners.log` names the split sha.

Suite: `tests/context-budgets-fragments.bh-6487-test.sh`.
