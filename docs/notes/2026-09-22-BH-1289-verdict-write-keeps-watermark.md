# The review lane's verdict write keeps the `.ledger_sha` watermark

Doc: MERGE-CONDUCTOR

## Why

`bin/review-prs.sh` writes the ledger row for a PR in two places on the same
tick. The dismissal pass writes `ledger_sha` — BH-989's watermark, the free
answer to "has a dismissal pass already finished at this head?" — and the
verdict write, a few hundred lines later, recorded the judgement. The verdict
write was the one wholesale assignment left in the file
(`.[$n] = {sha:$s, verdict:$v, tier:$t, served:$sv}`); every other write to a
row merges. So on a harness-authored, non-pipeline PR — a hand PR this lane
reviews itself — the verdict landed on top of the watermark and erased it.

The cost was one paginated `pulls/N/reviews` read per reviewed hand PR per
head, for ever: the next tick saw `DONE == SHA` but an empty `LEDGER_SHA`, read
the dismissal list again, rewrote the watermark, and only the tick after that
skipped. Free reads, not money — but this lane's whole BH-989 half exists to
stop exactly that read from running twice.

## What changed

**`bin/review-prs.sh`**, the verdict `rp_state_write`: the object literal is now
the first operand of a merge that carries four keys forward off the existing
row —

```
.[$n] = {sha:$s, verdict:$v, tier:$t, served:$sv}
        + ((.[$n] // {}) | {ledger_sha, deferred_sha, deferred_at, ci_alerted_sha}
           | with_entries(select(.value != null)))
```

Those four are the row's cross-tick caches: `ledger_sha` (BH-989) plus the
CI-debounce bookkeeping that G7d of `tests/review-prs-gh-dedup-test.sh` already
declares a survivor of the sibling merged write (`rp_rehydrate_record`). They
are keyed on a head and inert under a verdict, so carrying them can only save a
read. Everything else on the row is bookkeeping for the attempt that just ended
— the in-flight marker, the no-verdict counter, the merge-retry counters, a
frozen head's flag — and is dropped exactly as before; G11 of the same suite
pins that the in-flight marker must not outlive the verdict.

`with_entries(select(.value != null))` is load-bearing and not tidiness:
`{a,b}` over an object missing those keys yields nulls, and a row that never had
a watermark must not come out of the verdict write carrying one. A budget-low
tick still defers its dismissal pass, still buys the review through the ledger
gate, and still leaves no watermark, so the next healthy tick reads and
dismisses (BH-989 case 6b's guarantee).

Two reasons the operand ORDER is fixed rather than incidental: the four carried
keys can never collide with the literal, and
`tests/review-prs-state.bh-977-test.sh`'s jq fault injector intercepts this
write by the literal substring `.[$n] = {sha:$s, verdict:$v`. A `del(...)`-shaped
variant took that substring away and turned eight of that suite's assertions
red.

A second hunk corrects a stale comment above the dismissal read (`#891` left it
saying the read "answers both questions — what to dismiss, and whether this head
was already reviewed"). Since BH-989 it answers one: `RP_REVIEWS` has a single
consumer, `rp_dismiss_own`. Whether the head was already reviewed is the local
row's `.sha`, and on a cache miss `rp_rehydrate` makes its own read.

## Red before green

`tests/review-prs-ledger-merge.bh-1289-test.sh` is new and is the reproduction.
Against the unpatched script it was **18 passed, 7 failed** — case 1 red on all
three of its watermark assertions (`ledger_sha` empty after tick 1; tick 2
`list_reads` and `reads` both 1), case 3 red on the carried old-head keys, case
4 red on the APPROVE path's watermark and its tick-2 read. With the hunk applied
it is 25/25.

Two further mutations, each confirmed red (D1): dropping
`with_entries(select(.value != null))` leaves four null keys on the row and
fails case 2; widening the allow-list to the attempt bookkeeping fails case 1,
case 4 and G11 of `tests/review-prs-gh-dedup-test.sh`.
