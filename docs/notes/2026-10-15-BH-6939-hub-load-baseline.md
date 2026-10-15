# Hub load baseline, posted once after 24 h (BH-6939, rest of #6882)

Doc: OPERATING

## What changed

`bin/hub-load-baseline.sh` is new. `bin/hub-load-sample.sh` calls it once per
run, after its own summary line. There is no new lane and no new cron line.
The sampler's switch (`lane-off-hub-load-sample`) turns it off too.

It replaces the hand `awk` in the "The 24 h baseline (#6881)" section of
`docs/notes/2026-10-15-BH-6882-hub-load-sample.md`. That note is not edited
(D37). Use this command instead:

```bash
/root/harness/bin/hub-load-baseline.sh --print
```

`--print` writes nothing and calls nothing. Before T0 + 24 h it prints
`baseline=waiting(<n>h left)`. With no tsv file it prints `baseline=no-data`.

## The numbers

T0 is the time of the earliest line in `state/hub-load/????-??-??.tsv`: the
first sample after the deploy. The window is `T0 <= time < T0 + 24 h`. Lines
with a time that does not parse are skipped. For `runnable`, `steal` and
`forks_s` the report gives p50, p90 and mean (linear interpolation, the rule
of the sampler's p90 alert), `n` (values used) and `na` (values that are `NA`
or not a number). A field with no value is `NA`, never `0`.

```
window <T0> to <T0 + 24 h>
lines <n>/144
runnable p50=<x> p90=<x> mean=<x> n=<n> na=<n>
steal p50=<x> p90=<x> mean=<x> n=<n> na=<n>
forks_s p50=<x> p90=<x> mean=<x> n=<n> na=<n>
```

## The post

Once NOW >= T0 + 24 h, one run does this:

1. If `state/hub-load/baseline.state` says `posted` or `gave-up`, it stops.
   No tsv read, no network.
2. It writes the report to `state/hub-load/baseline.txt` (tmp + mv), before
   any send.
3. As the App (`gh_auth_for $HARNESS_REPO`), it reads the comments of the
   issue in settings row `hub_load.baseline_issue` (default 6881). A comment
   that holds `<!-- hub-load-baseline:<T0> -->` means the report is there:
   state `posted <ts> found`, no post.
4. Else it posts the report as one comment (a table and the marker). rc 0
   gives state `posted <ts> <issue>`.
5. A failed read or post writes `attempts <n>`. The 6th failure (one hour of
   10-min ticks) writes `gave-up <ts> <reason>` and one
   `bin/lane-alert.sh --log-only hub-load-sample` line that names the issue and
   `state/hub-load/baseline.txt`. No page.

Log: `logs/hub-load-baseline.log`, one line per run:
`<ts> baseline=<no-data|waiting(<n>h left)|not-configured|read-failed|post-failed|posted|gave-up|skipped (running)> issue=<n>(row|default)`.
The sampler's own summary line does not change.

To post again, delete `state/hub-load/baseline.state`. The marker read stops a
second comment for the same T0. After day 14 the sampler deletes the oldest
tsv files, so T0 moves and the marker changes: then only the `posted` state
stops a second post.

## Knob

| Key | Default | Meaning |
|---|---|---|
| `hub_load.baseline_issue` | 6881 | The issue that gets the comment. Settings row (`worker/jobs/schema.d/202610151900-bh-6939-hub-load-baseline-knob.sql`). |

The attempt cap (6) is a code constant.
