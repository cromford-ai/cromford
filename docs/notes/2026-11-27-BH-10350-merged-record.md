# BH-10350: the resolver's merged-PR lookup reads the PR record

## What moved

`br_merged_prs_for` (bin/blocked-resolver.sh) answers the park check of
`br_already_merged`: "does this ticket have a PR merged after the park?".
Before this change it made two `search/issues` reads plus one `pulls/<n>` read
per hit on every call.

Now its first line calls `brmr_read`
(bin/blocked-resolver.d/bh-10350-merged-record.sh). That goes through
`prr_read blocked-resolver` on the lane's step `GH_SOURCE` (settings row
`lane.blocked-resolver.gh_source`, default `shadow`):

| step | GitHub calls per park check (fixture) | jobs GETs | reason line |
|---|---|---|---|
| off | 2 search + 1 pulls (today) | 0 | `reason=step-off` |
| shadow | 2 search + 1 pulls (today) | 1 | `reason=step-shadow` |
| record, hit | 0 | 1 | none |
| record, miss | 2 search + 1 pulls (today) | 1 | `reason=record-miss:<why>, rc <n>` |

The record read is one GET: the repo's merged rows updated since the park,
`/api/pr-records?repo=&state=merged&need=head_ref,merged_at,url,title&since=<park>`
(`pr_record_list` 7th arg, served by `idx_pr_records_repo_state_upd`).
A row counts when it merged after the park and names the ticket: head ref
`ticket/<lk>` or `ticket/<lk>-*`, a branch path segment `<lk>` or `<lk>-r<k>`
(for example `mac/bh-10215`), or the whole key in the title.

## Miss words

`no-since` (no park time), `unknown` (a bad key), `unreadable`, `malformed`
(also a url of another repo), `no-sync`, `stale`, `truncated`, `field:<f>`
(also a null `merged_at` the worker did not name), `too-old`, `window-unread`. Each miss writes one
`PRR_MISS lane=blocked-resolver key=<slug>#<KEY>@merged` line and runs the
search.

## The retention window

The worker deletes a merged or closed PR record once its `refreshed_at` is
older than `retention.pr_records.closed_days` (fallback 14) or any record past
`retention.pr_records.days` (fallback 90). The list stamp stays fresh, so an
old park could read "no merged PR" for a merge whose row is gone. So
`brs_merged_record` misses `too-old` when the park is at or before now minus
the smaller non-zero window minus 1 day, and `window-unread` when it cannot
read a row. Both rows at 0 = no window. A merge after the park has
`refreshed_at` after the park, so inside the window its row is still there.

A lost merge webhook can still give a false "not merged" until the hourly
prr-sweep (the 60-minute safety sweep, #10220) or the next merged-list sync
writes the row: at most about 60 minutes.

## pipeline-health

The HOLD search (`stall_hold_candidates`) is an issue search over comment
text. No record holds issue comments (the issue record is BH-10199), so it
still runs. Each tick with at least one HOLD search writes one line to
logs/pipeline-health.log:
`stall hold: <n> HOLD search read(s), reason=issue-comment-text ...`.

## Numbers

Before: hub hour 06 of 2026-11-27, 304 `search/issues` reads. 203 came from
blocked-resolver and 59 from pipeline-health (#9926 comment 7212436767).

After (fixture, tests/br-merged-record.bh-10350-test.sh): a record hit makes
0 GitHub calls per park check, against 3 before. Steps off and shadow and a
record miss make the 3 calls of today.

Hub after: the next 24 hours of blocked-resolver search rows in
`state/gh-rest-ledger/`, once the step is `record`:

    awk -F'\t' '$2=="blocked-resolver" && $5 ~ /search/' state/gh-rest-ledger/<hour>.tsv | wc -l

## Moving to record

On the hub the lane step `lane.blocked-resolver.gh_source` is already `record`
(since 2026-11-26 21:16Z, BH-10157 wave 5), so this read moves at deploy. To
watch it, count the misses and their words:

    grep 'PRR_MISS lane=blocked-resolver key=.*@merged' logs/prr-shadow.log | sed 's/.*why=//' | sort | uniq -c

A PR that only the record finds (a `mac/<key>` branch with no key in the
title) shows as `only_record=1` in step shadow.

## Switch off

`BR_OPT_OFF=bh-10350-merged-record` does not source the fragment. The lookup
is then the search alone, in every step.
