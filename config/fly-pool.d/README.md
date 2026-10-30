# config/fly-pool.d/ — the fragments of bin/fly-pool.sh (BH-7454)

`bin/fly-pool.sh` is a committed render. Do not edit it by hand. Edit the
fragments here, then run `bin/fly-pool-build.sh --write` and commit the
fragments and the render together.

## Format

- Each fragment is verbatim shell. The generator adds no banner and trims
  nothing.
- The render is the `cat` of every `[0-9][0-9][0-9][0-9]-*.sh` file here, in
  `LC_ALL=C` name order. The generator sets `LC_ALL=C` itself, so the order is
  the same in every caller locale (`x-y.sh` sorts before `x.sh`).
- A fragment name must match `^[0-9]{4}-[a-z0-9][a-z0-9-]*\.sh$`. `README.md`
  is the only other file allowed here. Any other name, a dotfile or a
  subdirectory is refused (rc 2).
- Each fragment must pass `bash -n` alone, must not be empty and must end in a
  newline.

## The fragments

`0100-head.sh` is line 1 up to the line before the
`# <<< pool terminal / spawn cap / hold gate` line. The tail is 20 fine
fragments, one per top-level unit (BH-8740). Each one starts at its
`# >>>` marker, or at the `#` block above its function:

| fragment | holds |
|---|---|
| `2000-qrow-and-machine-io.sh` | `QROW()` (queue done, failed or requeue) |
| `2100-mput-error-note.sh` | the mput error note (BH-7174) |
| `2200-machine-destroy.sh` | machine destroy (BH-660) |
| `2300-pool-cost-rows.sh` | the pool cost rows |
| `2400-fly-cost-row.sh` | the fly cost row (BH-3989) |
| `2500-preplan-relay.sh` | the preplan relay |
| `2600-reroute-relay.sh` | the reroute relay (BH-584) |
| `2700-build-note-relay.sh` | the build-note relay |
| `2800-bake-evidence-relay.sh` | the bake-evidence relay (BH-6259) |
| `2900-app-token-rotation.sh` | App-token rotation and `mq_touch()` |
| `3000-pool-full-push.sh` | the pool full push (BH-1041) |
| `3100-pool-relay-retry.sh` | the pool relay retry (BH-1041) |
| `3200-pool-custody-sweep.sh` | the pool custody sweep (BH-5006) |
| `3300-next-job-or-destroy.sh` | `next_job_or_destroy()` |
| `3400-pool-listing-and-reap.sh` | the pool listing (BH-660) and the whole REAP loop |
| `3500-dead-machine-sweep.sh` | the dead-machine sweep (BH-660) and the SPAWN preamble |
| `3600-bundle-reason.sh` | the bundle reason (BH-4859) |
| `3700-warmup-note.sh` | the warmup note (BH-7215) and the machine pull (BH-7430) |
| `3800-spawn-one.sh` | `spawn_one()` |
| `3900-spawn-loop.sh` | the second `# >>> machines rows (BH-1035)` block to EOF |

## Adoption state

The set is complete since BH-8740. `bin/fly-pool.sh` is edited only through
the fragments. `catalog/list-files.tsv` holds a `rendered config/fly-pool.d/`
row for it, so `bin/list-file-lint.sh` refuses a PR that changes
`bin/fly-pool.sh` with no change under `config/fly-pool.d/`.

## A new entry

Name it `NNNN-bh-<n>-<name>.sh`, where `<n>` is the ticket number and NNNN
sits between the two fragments the code must go between. Example: a function
that must render after `3700-warmup-note.sh` and before `3800-spawn-one.sh` is
`3750-bh-9001-alpha.sh`. Then run `bin/fly-pool-build.sh --write`.

`bin/state-paths-guard.sh` does not check a new fragment here (BH-7542): a
fragment is a source of `bin/fly-pool.sh`, an existing writer, and the guard
does not check an edit of an existing writer. A reviewer must read a new
`state/` write in a fragment as an edit to `bin/fly-pool.sh`.

## Verbs

- `bin/fly-pool-build.sh --check`: validate the names and `bash -n`, then
  compare the render with `bin/fly-pool.sh`. rc 0 equal, rc 1 stale or a
  `bash -n` failure, rc 2 a bad name, no dir or no fragment.
- `bin/fly-pool-build.sh --write`: the same validation, then the merge guard
  seam (`bin/lib/fly-pool-build-guard.sh`, owner BH-7454.2, issue #7543; today
  it lets every write through), then a temp file in `bin/`, `chmod 755` and
  `mv` over `bin/fly-pool.sh`.
- `bin/fly-pool-build.sh --absorb`: move a hand edit of `bin/fly-pool.sh` into
  the fragments (`bin/lib/fly-pool-build-absorb.sh`, owner BH-7454.3, issue
  #7544). It is not built yet: today it prints
  `fly-pool-build: --absorb is not built yet (BH-7454.3)` and returns rc 2.

## A hand edit of bin/fly-pool.sh, before --absorb exists

Move the edit into the fragment that holds those lines:

1. Find the fragment: `grep -lF '<a line next to the edit>' config/fly-pool.d/*.sh`.
2. Make the same edit in that fragment.
3. Run `bin/fly-pool-build.sh --write`.
4. Run `bin/fly-pool-build.sh --check`. It must print nothing and return rc 0.
