# Turn a pre-queue invariant off, or rebudget it, from a settings row (BH-5440, #5429 child 2)

Doc: MERGE-CONDUCTOR

## Why

The pre-queue gate runs every row of `catalog/prequeue-invariants.tsv` from
main (BH-5438). Before this change, the only way to stop one invariant or
change its budget was a PR to the catalog. Now a settings row does it, and the
hub carries the row to the workflow.

## The key

`conf.prequeue-invariants.<id>` for the fleet. `conf.prequeue-invariants.<id>.<box>`
for one box, read before the fleet row (the usual `bin/lib/conf-row.sh` rule).
`<id>` is the catalog's first column, for example `lanes-registry`.

The value is one of:

- `off`: the row does not run.
- a positive whole number: the row's `budget_s`. Over it is reported, never killed.

Any other value (`0`, `-1`, `tests/x.sh 5`, `rm -rf`) is refused. One throttled
line goes to `logs/lane-gate.log` (`conf prequeue-invariants: row ... refused`),
and the catalog value answers. A row for an id that is not in the catalog is
skipped with no line. So a row can never add an invariant or change what runs.

## Where it resolves

1. The merge conductor dispatches `prequeue-gate.yml` with empty suites.
2. `pq_dispatch` calls `pq_invariants_args` (`bin/lib/mc-prequeue.d/invariants.sh`).
3. That runs `bin/prequeue-invariants.sh --overrides --harness $MC_H` on the hub.
   It prints the rows as `id=off|<n>,...`, or nothing.
4. A non-empty list goes out as `-f invariants=<list>`. Anything that is not the
   strict list shape is dropped, and the dispatch goes out as before.
5. The workflow takes the input only as env `PQ_INVARIANTS_IN`. It checks it
   against `^([a-z0-9-]+=(off|[0-9]+))(,[a-z0-9-]+=(off|[0-9]+))*$`. A bad value
   is `could-not-run ... why=bad-invariants`. A good value is passed to
   `bin/prequeue-invariants.sh --run ... --jobs 4 --overrides "$PQ_INVARIANTS_IN"`.

Box rows resolve for the HUB's box name, because the hub reads them. For the
gate, only fleet rows mean anything.

If every row is off, the runner exits 2. The workflow then warns
`prequeue-invariant-catalog` and the verdict is the impact gate's alone. It is
never a green from the invariants.

## See the result

```bash
bin/prequeue-invariants.sh --list --harness /root/harness       # the rows that run, with budgets
bin/prequeue-invariants.sh --overrides --harness /root/harness  # what the hub sends
```

With no `--harness`, `--list` prints the catalog as committed.

## Parallel runs

`--run` takes `--jobs N` (default 4, the `RULES_PACK_JOBS` precedent). The
workflow passes `--jobs 4`. Output lines, `timings.tsv`, `suites.txt` and
`failed.txt` stay in catalog order. The total line's `total` is still the sum
of the rows' seconds. `wall` is now less than that sum.

## Cache

The pre-queue cache key is (PR, head, main). It does not hold the override. A
verdict cached before a row changed stays until the head or main moves.

## Tests

`tests/prequeue-invariant-overrides.bh-5440-test.sh`.
