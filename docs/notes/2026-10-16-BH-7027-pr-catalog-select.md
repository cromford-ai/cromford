# BH-7027: a PR select narrows catalog/ paths through their reader rows

Doc: none

## What changed

- `bin/test-impact.sh`: `ti_infra_re` (the infra list of a plain select, used by
  PR CI, the builder gate and `bin/gate.sh`) no longer has `^catalog/`. A new
  function, `ti_pr_catalog`, decides each `catalog/` path in a plain select:
  - It is `full: infra change (<p>)` when `cbe_reason`
    (`bin/lib/ci-batch-escalate.sh`) escalates it. These are the catalogs the
    selection reads: `catalog/ci-batch-escalate.tsv`, `catalog/test-tiers.tsv`,
    `catalog/test-impact-always.txt` and the others in that file, plus
    `CI_FULL_TRIGGERS`.
  - It is `full: infra change (<p>)` when the map has no specific row for it
    (`ti_specific`), or when the rules lib cannot be sourced, or when the rules
    file is unreadable.
  - Any other `catalog/` path selects through its map rows. A `catalog/*.md`
    selects only through its specific rows, as in the batch (BH-6059).
- `tests/lib/`, `.github/workflows/` and the runner and selector scripts stay
  infra in a plain select. The merge-queue batch select (`TI_BATCH_SELECT=1`)
  does not change.
- An unmapped catalog path keeps the words `infra change`, not the batch's
  `unmapped path`. `tests/ci-batch-escalate-narrow.bh-6059-test.sh` N6 pins those
  words, and log readers match them.
- New `bin/test-impact-fallback-rate.sh`: replays a directory of changed-path
  lists through a plain select and prints the full-mode rate.

## Test changed

`tests/mc/requeue-after-foreign-red.bh-3776-test.sh` N1-contract pinned the old
premise: the real select answered corpus for
`catalog/lanes.d/merge-conductor.json`. `bin/lib/mc-foreign-red.sh` asks the same
plain select that PR CI uses. After this change PR CI runs only the selection
for that path, so `selected` is the true answer. The case now pins
`catalog/lanes.d/merge-conductor.json selected`, and keeps a catalog corpus case
with `catalog/test-tiers.tsv` (an escalated selector catalog). No case was
removed.

## The ticket's three cases (plain select, map of this tree, 2392 suites)

| Case | Before | After | Failing suite in the set |
|---|---|---|---|
| #7007 `catalog/lanes.d/repair-on-push.json` | full, 2392 | 169 | `factory-stop-merge-deploy-tags.bh-3687` |
| #6988 `catalog/lanes.d/merge-conductor.knobs.d/MC_LANDING_MODE.json`, `worker/jobs/src/routes/retention.js`, `worker/jobs/test/route-table.d/bh-6971-alert-components.txt` | full, 2392 | 235 | `d1-retention.bh-6750`, `worker-routes-render.bh-4607` |
| #7012 `catalog/components.tsv` + the route-table.d txt | full, 2392 | full, 2392 on this tree | none: no suite on main names `catalog/components.tsv` |

`catalog/components.tsv` arrives with #7012. On that tree two suites name it
(`tests/component-of.bh-6971-test.sh`, `tests/alerts-groom-component.bh-6971-test.sh`),
so the map gets a specific row with no extra code. The acceptance suite P3 adds
one such row to this tree's map. An existing suite stands in for
`component-of.bh-6971`, because a row that names a missing suite file trips the
`ti_why_rows` defect below. The select is not full and holds
`worker-routes-render.bh-4607` and `route-keyed-merge.bh-5788`.

## Fallback-rate replay, last 50 merged PRs

The build stage had no GitHub access (egress denied `api.github.com:443`). So
the lists come from local git history: the last 50 first-parent
`Merge pull request #N` commits on `origin/main` (50a43f68), PRs #6846 to
#7077. Each list is the merge commit's diff from its first parent:

```bash
L=/tmp/bh7027-lists; mkdir -p $L
git log --first-parent --merges --format='%H %s' origin/main | grep 'Merge pull request #' | head -50 |
  while read -r h _ _ _ num _; do git diff --name-only "$h^1" "$h" > "$L/${num#\#}.txt"; done
```

With GitHub access the same lists come from
`gh pr list -R example-org/cromford --state merged --base main --limit 50 --json number`
and then `gh api repos/example-org/cromford/pulls/<n>/files --paginate -q '.[].filename'` per PR.

The commands (from the script's header), from the repo root:

```bash
B=$(mktemp -d); mkdir -p "$B/bin"; git show origin/main:bin/test-impact.sh > "$B/bin/test-impact.sh"
bin/test-impact.sh map --out "$B/map"
bin/test-impact-fallback-rate.sh --lists /tmp/bh7027-lists --impact "$B/bin/test-impact.sh" --map "$B/map"
bin/test-impact-fallback-rate.sh --lists /tmp/bh7027-lists --map "$B/map"
```

`bin/test-impact.sh` on `origin/main` is the same file as on this branch's base
(b1db381e), so the before run measures main.

Before (origin/main's `bin/test-impact.sh`), rc 0:

```
fallback: 26 of 50 (52%)
fallback-why: 14	infra change	catalog/lanes.d
fallback-why: 4	infra change	tests/lib
fallback-why: 3	infra change	catalog/lane-run-inputs.d
fallback-why: 2	infra change	.github/workflows
fallback-why: 1	infra change	catalog/context-budgets.d
fallback-why: 1	infra change	catalog/llm-sites.d
fallback-why: 1	infra change	catalog/switches.d
```

After (this tree), rc 0:

```
fallback: 9 of 50 (18%)
fallback-why: 7	infra change	tests/lib
fallback-why: 2	infra change	.github/workflows
```

The after-rate is 18%, under the 20% target. The ticket's "about 90%" came from
another sample. On this sample main was at 52%. All 9 PRs that still go full
touch true infra: 7 add a per-ticket `tests/lib/*.bh-NNNN.mjs` worker helper, and
2 change a workflow file.

## Follow-up (not in this change)

- `tests/lib/` helpers: 7 of the 9 remaining full runs. The batch already
  selects a helper through its closure (BH-6371). A plain select could use the
  same rule, with `tests/lib/scratch.sh` kept escalated.
- `ti_why_rows` fails open on a map row that names a suite file that is not in
  the tree. awk prints `cannot open`, the select still exits 0, and the set is
  partial. In one probe two paths selected 74 suites, and one of the two alone
  selected 149. This only occurs with a
  `--map` built from another tree.
