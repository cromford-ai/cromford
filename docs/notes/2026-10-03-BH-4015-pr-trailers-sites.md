# Every harness PR carries the Harness-Job / Harness-Ticket trailer (BH-4015, BH-3987 slice 2)

Doc: RUN-BUILD-GRAPH

## What changed

The tracer (BH-4014) trailered build PRs in `bin/lib/rb/pr.sh`. Every other
place the harness opens a PR now applies the same block through
`pr_trailers_apply` (`bin/lib/pr-trailers.sh`), inside its own
`# >>> pr trailers (BH-3987)` / `# <<< pr trailers` pair:

| Site | Job | Ticket |
|---|---|---|
| `bin/pr-url-reconcile.sh` restack | the build's own (its `pr-body.md` trailer, else its `job.json`) | the build's key |
| `bin/review-rescue.sh` rescue | the build's own, same rule | the build's key |
| `bin/batch-resolve.sh` merge train | `train:<branch>`, plus `Harness-Train: <branch> #n #n ...` | `none` |
| `bin/lib/mrb-act.sh` revert | `lane:main-red-bisect` | the culprit's `KEY:` title prefix, else `none` |
| `bin/deploy-train.sh` rollback | `lane:deploy-train` | `none` |
| `bin/rule-miner.sh` lint and judgement PRs | `lane:rule-miner` | `none` |
| `bin/guardrail-promote.sh` | `lane:guardrail-promote` | `none` |
| `bin/flaky-quarantine.sh` | `lane:flaky-detect` (the lane that runs it) | `none` |
| `bin/mergify-sync.sh` | `lane:mergify-sync` | `none` |
| `bin/feature-map-draft.sh` | `lane:feature-map-draft` | `none` |
| `bin/qa-personas.sh` | `lane:qa-personas` | `none` |

The restack and the rescue blank `JOB_ID` before falling back to `job.json`,
because `bin/orc-job.sh` exports the running lane's own claim under that name
and the PR belongs to the build, not to the lane that reopened it.

The rescue, the rollback and the quarantine used to pass `--body "<string>"`.
They now write the body to a file, trailer it and create with `--body-file`.
If the file can't be written, the same create reads the plain body from stdin
(`--body-file -`) and one log line says it opened without trailers.

A failed apply never stops a create: it logs one line in the site's own log
(`pr trailers: could not write <file> — PR opened without trailers`) and the PR
opens untrailered. With the lib absent nothing is logged and the PR opens as
before.

`bin/lib/gh-pr-create.sh` only gained `# pr-trailers: receives an
already-trailered body` comments on its create lines; it posts the body file
its caller hands it. `bin/lib/gh-shim/pr-write.sh` is unchanged.

## The census

`tests/pr-trailers-sites.bh-4015-test.sh` T8 scans every shell file under
`bin/` (`bin/lib/gh-shim/` excluded) for a create: `gh pr create` at a line
start or after `$(` / `&&`, a `POST` to `repos/<x>/pulls`, or a
`$(_gpc_rung_create ` call. Each one must sit inside a `# >>> pr trailers`
pair, carry a same-line `# pr-trailers: <reason>`, or follow a code line that
calls `pr_trailers_apply` / `_pr_trailers_*`. A new create site that skips the
trailer is red there, named by `file:line`.
