# BH-851 — the depth-1 split-child guard also reads the ticket body, and logs its decision

Doc: RUN-BUILD-GRAPH

## What changed

The size gate's depth-1 guard used to decide "is this ticket already a split
child?" from one thing: `.title` in `$BUILD/ticket-meta.json`, matched against
`<KEY>-<n>.<m>`. When the title didn't match (the meta file never arrived, or
someone edited the title), the ticket was treated as top-level. An oversized
child then went back to `bin/run-decompose.sh`.

The check now lives in its own marked block, `# >>> split child check`, inside
`# >>> size gate` in `bin/run-build.sh`. The same block, byte for byte, is in
`bin/lib/rb/plan.sh`. In order:

1. The title regex, unchanged. A match is `source=meta`.
2. Otherwise the body: `.body` in `ticket-meta.json`, else `$BUILD/ticket-body.md`.
   If the body has the filer's own footer line (`Split child (depth 1): ...`,
   written by `fc_child_footer`) the ticket is a child with `source=body`. The
   line has to start at column 0 and sit outside ``` / ~~~ fences. A ticket that
   only quotes the line, indents it or `> `-quotes it still splits.
3. Neither: `source=none`. That's the same fail-open as before.

No network call is made. Both sources are files already in the build dir.

## The new log line

Every build that reaches the size gate writes one line to `pipeline.log`, even
when nothing would split and even under the kill flag:

```
SIZE: child check: title=<title, control chars stripped, max 120 chars> source=<meta|body|none>
```

`title=unread` means `ticket-meta.json` was missing or empty. That's different
from a readable title that just isn't a child's. To see why a build did or
didn't split:

```
grep 'SIZE: child check:' /root/harness/builds/<project>-<KEY>-*/pipeline.log
```

## What this does not fix

On 2026-09-18, BH-375, BH-682 and BH-567 (twice) ended DECOMPOSE_FAILED because
the meta fetch failed outright. In that case nothing writes `ticket-body.md`
either, since the rollout hook writes it from the same `.body`. So this change
alone doesn't catch that exact shape. The REST fallback for the meta fetch
(PR #1664) is the fix for it. What changes here is that the log now says
`title=unread source=none` instead of nothing, and a meta file with an edited or
non-child title is still recognised by its body.

Tests: `tests/size-gate-split-child.bh-851-test.sh`.
