# pr-attribution: who built each merged PR (BH-4016, child of BH-3987)

Doc: VERIFICATION-MAP

## What changed

New read-only operator command:

```
bin/pr-attribution.sh <owner/repo|project> [YYYY-MM-DD] [--json]
```

It lists a repo's PRs merged on or after the date (default: 30 days before
now, UTC) and says who built each one. `<repo>` with a `/` is the slug.
Anything else is a fleet project, resolved through `bin/fleet-conf.sh
<project> repo`. Closed-unmerged PRs are never listed.

## Classes, first match wins

| class | basis | when |
|---|---|---|
| `train` | trailer | `Harness-Train:` present |
| `harness` | trailer | `Harness-Job:` or `Harness-Ticket:` present |
| `train?` | heuristic | head branch `batch/*` |
| `harness?` | heuristic | head branch `ticket/*`, or the author is in `harness_pr_authors` |
| `operator?` | heuristic | head branch `lead/*` |
| `human` | heuristic | anything else |

Trailers are read only through `pr_trailers_read` (`bin/lib/pr-trailers.sh`,
BH-4014), so the last occurrence wins and a `Harness-Job:` line typed higher up
in a body never counts. A `?` class is a guess for PRs older than the trailer or
opened by hand. The author set is `harness_pr_authors`, so `cromford[bot]`
(REST) and `app/cromford` match the same actor. Because of that, a
`lead/*` PR by an author in the set reads `harness?`, not `operator?`.

## Output and exit codes

- TSV by default: the header `number merged_at class basis job ticket author
  head url`, one row per PR (merged_at newest first), and a last line
  `# totals harness=N harness?=N train=N train?=N operator?=N human=N`.
  Heuristic rows show `-` for job and ticket.
- `--json`: the same rows as an array of objects, `-` as `null`, no totals.
- The REST list caps at 1000 PRs. If it comes back full and its oldest PR was
  created on or after the date, older merges inside the window may be missing.
  In that case the totals line ends ` truncated=1`, stderr gets one warning, and
  rc stays 0.
- rc 0 means the table printed. rc 2 means bad arguments (an unknown flag, the
  wrong number of positionals, a date that is not a real `YYYY-MM-DD`, a
  malformed slug, an unknown project). rc 75 means the REST read failed (rate
  limit, 404, network, malformed JSON). On rc 75 stderr gets one line, and
  nothing is printed to stdout.

It writes nothing of its own: no comment, no label, no ALERTS line, no log.
`gh_rest`'s shared quota ledger and ETag cache record the read as usual. The
only GitHub traffic is the paged `GET repos/<slug>/pulls?state=closed` through
`gh_rest`. `PR_ATTRIBUTION_NOW` (epoch digits) pins the clock only under
`HARNESS_TEST_SANDBOX=1`.

Pinned by `tests/pr-attribution.bh-4016-test.sh`.
