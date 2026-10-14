# An infra-only red on main is re-run once, not raised as main-red

Doc: main-red-freeze

On 2026-09-24 Harness CI runs 36029556164 and 36029663354 failed on main
because apt could not install packages. No test ran. `bin/main-red-detector.sh`
only saw two red runs of a required workflow, so the streak arm froze every
merge lane. #2159 (BH-2128) names the apt steps `infra: install PyYAML (apt)`
and `infra: install age, zstd, rsync (apt)`. This change reads those names.

## What changed, in `bin/main-red-detector.sh`

After the arms have picked a run to freeze on, and after the BH-1927
confirming re-read, the detector reads that run's jobs over REST
(`actions/runs/<id>/jobs?per_page=100`). `mr_infra_only` calls the failure
infra-only when every failed job (`failure` or `timed_out`) has at least one
failed step and every failed step's name starts with the literal, case-sensitive
`infra:`. A failed read, non-JSON, an empty `jobs` list, a truncated list
(`total_count` above what came back), or any other failed step means it is not
infra, and the detector raises exactly as it did before. That raise names the
failing job from the same body (`read_jobs` reuses it), so a raise tick still
costs one jobs read. `read_jobs` only falls back to its own `-q` read when the
body is not jobs JSON.

On an infra-only red, `mr_infra`:

- at `run_attempt` 1 POSTs `rerun-failed-jobs` once, records the ledger row
  `rerun=requested attempt=1`, writes `decision=infra reason=rerun` and logs an
  `INFRA:` line. No flag, no pause row, no alert. A later tick that still reads
  attempt 1 with that row in place does not POST again (`reason=rerun-pending`).
- if GitHub refuses the POST, writes `rerun=refused attempt=1` and sends ONE
  non-critical alert asking for a manual rerun. The next tick POSTs again but
  does not re-alert.
- at `run_attempt` 2 or more (the rerun failed on infra again) sends ONE
  non-critical alert, `alerted attempt=<n>`, and still writes no flag.

Both alerts say "Merges are NOT frozen" only when no flag is on disk. With a
freeze already up on an earlier sha they say merges stay frozen on that red.

The alert dedupe is the `ledgers` row `kind=main_red_infra`, key
`<owner>/<repo>#<run-id>`, written before the send. "Rerun once" is GitHub's own
`run_attempt`, which moves the moment a rerun is accepted.

The check runs only where the detector would write or rewrite the flag. A flag
already on the same sha keeps its republish, and a flag on an older sha is left
exactly as it is: an infra failure says nothing about whether the real red was
fixed. `--explain` reads the jobs but POSTs and writes nothing (`WOULD RERUN`).

`bin/main-red-pr-pair.sh` reads `decision=infra` as "the detector looked", so it
does not raise its sha-less freeze from PRs failing alike on apt either.

## Knob

`MAIN_RED_INFRA_RERUN` (default 1). Only the literal 0 disarms it, and then the
decision is byte-for-byte the pre-BH-2165 one: no jobs read, no POST.

## Until #2159 merges

No step on main carries the `infra:` prefix yet, so every red is classified
"not infra" and the detector behaves exactly as before.

Test: `tests/main-red-infra-rerun.bh-2165-test.sh`.
