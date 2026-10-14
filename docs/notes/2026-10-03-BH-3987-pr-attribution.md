# Build PRs carry a Harness-Job / Harness-Ticket trailer (BH-3987, slice C0)

Doc: RUN-BUILD-GRAPH

## What changed

Every PR a box build or a Fly pool build opens now ends in a machine-readable
block, after the 🤖 footer:

```
Harness-Job: <job_id | lane:<lane-id> | train:<branch> | none>
Harness-Ticket: <KEY | none>
Harness-Train: <train-branch> <#n> <#n> ...     (only when a train is given)
```

`bin/lib/pr-trailers.sh` is the one helper, and the other parts of BH-3987
reuse it. It is sourced only and has four functions:

- `pr_trailers_text <job> <ticket> [train]` prints the block.
- `pr_trailers_apply <body-file> <job> <ticket> [train]` removes every
  existing `Harness-Job:`/`Harness-Ticket:`/`Harness-Train:` line and the blank
  line above it, then appends one blank line and a fresh block. It rewrites
  the file through a tmp file and `mv`. It answers rc 0 when it wrote, and rc 1
  with the file untouched when the file is missing, is not a regular file, is
  not readable or writable, or the write fails.
- `pr_trailers_job_for <build-dir>` prints `$JOB_ID`, else `.job_id` from
  `<build-dir>/job.json`, else `none`.
- `pr_trailers_read <body-file|->` prints `job<TAB>ticket<TAB>train`, with an
  empty field when a key is absent.

## Value rules

- A value keeps only `[A-Za-z0-9._:/#@+-]`. The train list also keeps spaces.
  Values are cut to 200 chars, and empty means `none`. Newlines are not in the
  set, so a ticket title can't start a trailer line of its own.
- **The last occurrence wins.** The reader keeps the last value of each key, and
  apply always puts its block last. A `Harness-Job:` line typed into a ticket
  body higher up never reads back. apply also removes it from the body.
- `lane:<lane-id>` and `train:<branch>` are the job values for PRs a lane or a
  train opens. Those sites belong to the sibling parts. This part only wires
  build PRs, whose job is the job id or `none`.
- If body plus block would be over 65000 bytes, the body is cut above the block
  so the block survives. The cut is byte-wise, so a multibyte char at the cut
  can split.

## Where it runs

It runs in the `# >>> pr trailers (BH-3987)` block of `bin/lib/rb/pr.sh`, inside
`# >>> pr create call`. Both branches of the create ladder now write
`$BUILD/pr-body.md`, trailer it, and create from that file. The no-ladder branch
used to pass `--body` inline and now passes `--body-file`. The pool runs the
same `bin/run-build.sh` under `BUILDER_EXEC=1`, so the same block covers it. Only
the job id's source differs: `$JOB_ID` on a box, `job.json` on the pool.

A missing trailer never fails a build. If the lib is absent, the body opens as
it always did and nothing is logged. If apply answers rc 1, the PR opens
without trailers and `pipeline.log` gets one line:
`pr trailers: could not write <file> — PR opened without trailers`.
`PR_BODY_FOR` is unchanged.

Pinned by `tests/pr-trailers.bh-3987-test.sh`.
