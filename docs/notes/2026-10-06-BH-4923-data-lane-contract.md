# The data lane's first slice: a DATA_LANE: review line, and a head-bound pre-merge apply (BH-4923)

Doc: LANES, migration-ledger

## What changed

- `bin/lib/data-lane.sh` (new). `dl_prompt_field_note` is one reviewer
  sentence: when a BLOCK exists only because a migration in the diff is not on
  prod yet, write `DATA_LANE: <repo-relative script path>` above `TIER:`, and
  no NEEDS_HUMAN line for that step. `bin/lib/rb/review.sh` sources the lib in
  the `needs-human seam` and puts the sentence after `nh_prompt_field_note` in
  the general review prompt, and before "Write everything to
  $BUILD/merged-review2.md." in the merged re-review prompt (that prompt has no
  needs-human note). Fail-open: without the lib both prompts render as before.
- `dl_candidate <review.md> [<diff-files>]` reads the final round only (the
  `_nh_final` rule) and answers `candidate<TAB><path>` only when there is
  exactly one `DATA_LANE:` line, its path matches
  `scripts/migrations/<x>.sql` or `scripts/migrate-<x>.ts` with no `..`, no
  leading `/` and no `<placeholder>`, the path is in the diff list, the final
  VERDICT is BLOCK, and exactly one line starts with a blocking marker (`B<n>`,
  `BLOCK`, `BLOCKING`, `[BLOCK]`, after optional list, heading or bold
  markers; case-sensitive). No diff list is `none`. NEEDS_HUMAN text is never
  read.
- `dl_reviewed_sha` is the `(head <sha>)` of a final `=== MERGED RE-REVIEW`
  round, else `review-head`. `dl_fp` is the sha1 of the file text.
  `dl_ledger_status` answers present / absent / unknown, and no worker
  configured is unknown. `dl_probe_file` names `<build-dir>/data-lane-probe.md`
  for the sibling that probes.
- `bin/data-lane-apply.sh` (new). Gates in order: lane gate, `paused-<project>`,
  `flock -n locks/data-lane-<project>-<pr>.lock`, the PR head via `gh_rest` and
  the diff from git, `dl_candidate` plus reviewed sha == head,
  `check-migration-appliable.sh` on the file at the head, the apply path, the
  ledger. Then `job_open kind=migration` and one POST of
  `{mode:"pre-merge",repo,pr,head_sha,file,statements,actor:"archie-data-lane"}`.
  Only `ok:true` with a literal `status` of `applied` or `already-applied`
  succeeds. A failure writes `failed apply ...` to the ledger first, then one
  `lane-alert.sh --id data-lane:<project>:<file>:<FP>`, parks the job, and is
  never retried: the next run reads that row and stops before any POST.
- `catalog/lanes.d/data-lane.json` (new): lane `data-lane`, switch
  `lane-off-data-lane`, knobs `DATA_LANE_APP_BASE` and `DATA_LANE_REPO_DIR`.
  No cron line; nothing calls the script yet.

## The outcome contract

Stdout is one word and the rc matches it:

| word | rc |
|---|---|
| `applied`, `already-applied` | 0 |
| `failed` | 1 |
| `flagged` | 2 (bad usage is also 2, with a usage line on stderr) |
| `not-candidate` (includes a same-FP `failed`/`flagged` ledger row) | 3 |
| `no-path` | 5 |
| `busy`, `paused` | 75 |

A lane-off run prints nothing and exits 0, which is `lane_gate_or_exit`'s
contract (`tests/lanes-registry-test.sh` section 5). Callers key on the word
and the ledger row, never on rc 0 alone.

## Why the app base is an env value, not a settings row

The ticket names the settings row `lane.data-lane.<project>.app_base`. The base
is the host `MIGRATION_TOKEN` is sent to, and `tests/lanes-registry-test.sh`
section 17 makes every `*_BASE` knob `settable:false`, so `lane_knob` ignores a
settings row for it. A console row must never be able to re-aim the token at
another host. So `DATA_LANE_APP_BASE` is read from the sealed `env/<project>.env`
next to `MIGRATION_TOKEN`, the same way migration-autopilot reads
`PROJECT_2_APP_BASE`/`PROJECT_3_APP_BASE`. Empty, the lane answers `no-path` and POSTs
nothing. No box sets it today.

## Ledger key vs migration-autopilot

This lane keys `<project> <repo-relative path>`. migration-autopilot keys
`<project> <basename>`, so it does not see this lane's row after the merge. It
falls through to the app's own `migrations/status` and records
`already-per-app-ledger`. That is only safe if the app's pre-merge mode records
the apply in the app's own ledger, which is the endpoint ticket's job (IA
board). The endpoint does not exist yet, and no prod apply has been made by this
slice.
