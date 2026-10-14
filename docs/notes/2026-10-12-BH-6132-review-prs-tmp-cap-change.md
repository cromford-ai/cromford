# review-prs reports a /tmp cap once per cap change (BH-6132)

Doc: sentry-report

## What happened

Sentry issue CROMFORD-HARNESS-9 had one review-prs-tmp-capped event per tick.
BH-6130 (9e32ef07) limited the event to one per box per
`REVIEW_TMP_CAPPED_REPORT_S` (default 86400). That window also hid a cap that
got worse inside it: a box that went from concurrency 2 to 1 sent nothing for
up to 24 hours.

## What changed

1. **Cap-lowered rule.** The marker `state/review-prs-tmp-capped.last` is now
   `<epoch> <concurrency>`. Inside the window, a capped tick whose concurrency
   is below the last reported one sends one more event. The same or a higher
   concurrency sends none, and a not-sent tick does not rewrite the marker. So
   a box sends at most two events a window: the window event and one 2 to 1
   drop.
2. **Payload.** `extra` adds `trigger` (`window` or `cap_lowered`) and
   `previous_concurrency` (null when unknown). The lane log line ends
   `reported (window)` or `reported (cap_lowered)`. The not-reported line names
   the last reported concurrency.
3. **Named setting.** `REVIEW_WORKER_TMP_MB` (lane review-prs, default 256 MB,
   the code default before) is now a registry knob. `rpool_init` sizes the /tmp
   cap as (free - `REVIEW_TMP_MIN_MB`) / `REVIEW_WORKER_TMP_MB`.

A BH-6130 one-field marker has no concurrency. Only the window applies to it,
so the deploy adds no event.

## Operator check

On a capped box, read `logs/pr-reviews.log` for `reported (cap_lowered)`, or
read `extra.trigger` on the newest event of the Sentry issue.
