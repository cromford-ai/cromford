# review-prs holds a paid review when the D1 verdict ledger cannot be read

Doc: REVIEW-PRS, COST

`state/<project>.pr-reviews.json` was the paid-review dedup, and D1 (`job_verdict`) was asked
only after a file miss.
- **The runaway class.** When D1 was unreadable and GitHub held nothing, the lane failed open and
  bought the review. That is how a worker blip became the $328/day runaway.
- **Now D1 is the truth and the file only caches it.** D1 unreadable on a box that has a worker
  (`jobs_configured`) means **held**: no paid call, one log line per PR, and one alert per project
  per day. The next tick asks again.
- **`BLOCK` counts.** A D1 `BLOCK` verdict (the `verdict_single_home` word for REQUEST_CHANGES) is
  replayed instead of being bought again.
- **The call-guard (K3) stays the backstop.**
