# BH-4987: catalog/llm-sites.json is composed from catalog/llm-sites.d/

Doc: docs/verification-map/llm-choke-point.md

What changed: `catalog/llm-sites.json` was a conflict hotspot (8 PRs in
`docs/CONFLICT_HOTSPOTS.md`, BH-4986). Every new site appended to one JSON
array. Two builds that each added a site both put a comma on the same last
element line and both inserted before the same `  ]`. The merge conductor could
settle that only with a union merge over JSON.

The sources are now in `catalog/llm-sites.d/`:

- `_head.json`: the top-level object without `sites` (`version`, `note`).
- `0000-base.json`: the 49 sites the catalog had at the split, text verbatim.
- `NNNN-<id>.json`: one NEW file per added site. It is a JSON array. Its first
  line is `[` and its last line is `]`.

`bin/llm-sites-build.sh --compose` builds `catalog/llm-sites.json` from them.
At the split commit the composition is the old file byte for byte. The
composed file is git-ignored and not committed (BH-1175 rule).

Rules the composer enforces (rc 2, the old catalog stays):

- A file name that is not `_head.json` or `^[0-9]{4}-[a-z0-9][a-z0-9._-]*\.json$`.
- A fragment that is not a non-empty array of objects with a string `id`, or
  does not open with a line `[` and close with a line `]`.
- Two fragments with the same `id`.

`--check` is rc 1 when `catalog/llm-sites.json` is TRACKED while
`catalog/llm-sites.d/` exists (a hand edit of the composed form), or when two
compositions differ. With no `catalog/llm-sites.d/` the committed file is the
source, as before (legacy mode, used by the ratchet suite's scratch repos).

Who composes it, at the same path, so every reader reads it unchanged:

- `bin/llm-sites-build.sh` in its default mode (harness-sync and publish-share
  call it), before it renders `docs/LLM_CALL_SITES.md`.
- `bin/harness-sync.sh` `deploy_workers`, in the worker snapshot, before
  `wrangler deploy`. The fragments and the composer join the jobs worker's
  change key as `-sites-<sha>`. A failed compose is one ALERT and no deploy.
- CI's worker-jobs step, next to `bin/lanes-build.sh --write`.
- Each `tests/*.sh` suite that reads the file or loads the worker, one line
  after `DIR=`.

`bin/test-impact.sh` maps a changed `catalog/llm-sites.d/<x>.json` to
`catalog/llm-sites.json`, so the suites that read the catalog are still selected.

Not changed: `MC_UNION_FILES_DEFAULT` still lists `catalog/llm-sites.json`. A
branch from before the split that edits the old file gets a modify/delete
conflict, the union step declines it, and the PR goes to a normal fix round.
There the site moves into a fragment.

Proof: `tests/llm-sites-fragments.bh-4987-test.sh`.
