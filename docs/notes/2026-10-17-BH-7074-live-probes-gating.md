# The self-check refuses a gating PR with no fenced live-probes block (BH-7074)

Doc: LEAD-REVIEW

Nine lead BLOCKs in 14 days had one cause. A PR that gates a lane reached review with no
lane-run probe, or with a probe in prose. The pre-review self-check now has the rule
`body-live-probes-gating` (`bin/lib/pr-self-check-gating.sh`, row in
`catalog/pr-self-check.d/bh-7074-live-probes-gating.tsv`).

**What is gating.** An added line of the diff (`git diff -U0`) does one of these:

| kind | where | what |
|---|---|---|
| settings | `worker/jobs/schema.d/*.sql`, not a `--` comment | a quoted key `'lane_placement.<x>'` or `'<x>.require_<y>'` |
| cron | `cron/*.cron`, `cron/lanes/*.cron`, `cron/boxes/<box>/*.cron`, not a `#` comment | more `&&` than a removed line with the same final command |
| route | `bin/**`, not a `#` comment | the path of a `jobs-get` row of the head's `catalog/live-probes.tsv` (query cut), or the URL of an `https-get` row |

The final command of a cron line is the text after its last `&&`, or after the schedule when
it has no `&&`. Removed lines count across all cron files of the diff. A line moved to another
fragment is not gating, and a brand-new lane line is not gating.

**What the body must carry.** A fenced block, read by `lp_declared`:

````
```live-probes
probe: hub-lease
probe: hub-request bin/<script>.sh <literal args>
KILL KNOB: <the setting or line that turns the gate off>
```
````

1. One or more `probe:` lines. Each is a catalog probe that `lp_resolve` accepts, or
   `probe: hub-request bin/<script>.sh <args>` with no write verb, no shell metacharacter and no `..`.
2. One or more `KILL KNOB:` lines with text, inside the fence.

A `## Live probes` section in prose does not count. The live-probe lane still runs only catalog
probes. It lists a `hub-request` line as refused in its comment.

**Where it runs.** The builder pre-push self-check, gate 78 of the lead-review enqueue (a
`REFUSE body-*` line holds the review request, bound `LGK_PSCMAX`), and the CI report-only step.
The rule prints nothing in a repo whose head has no `catalog/live-probes.tsv`.

**The off switch.** Set the row mode to `note` or `off` in the fragment.
