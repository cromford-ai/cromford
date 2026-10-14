# review-prs: REVIEW_D1_HOLD_MAX_H is 0-168, and two D1-hold nits

Doc: REVIEW-PRS

Follow-ups from the review of BH-2457 (PR #2486). This corrects the "0-999" in
`2026-09-25-BH-2457-review-prs-d1-hold-fallback.md`.

- **One bound for `REVIEW_D1_HOLD_MAX_H`: 0-168.** The registry
  (`catalog/lanes.d/review-prs.json`) always said `"max": 168`, but
  `rp_d1_hold_or_fallback` in `bin/review-prs.sh` accepted 0-999. Now a value
  above 168 takes the same path as a non-number: one log line naming the
  0-168 range, and the default 6 is used. It is not clamped to 168. The
  registry note says 0-168 too.
- **Empty `RP_AC_ENV` is safe on bash < 4.4.** The paid review's `env` line
  expands it as `${RP_AC_ENV[@]+"${RP_AC_ENV[@]}"}`. The plain
  `"${RP_AC_ENV[@]}"` is an "unbound variable" error under `set -u` on macOS
  bash 3.2 when the array is empty. The Linux boxes never hit it.
- **The test's worker-less box is an EMPTY `JOBS_URL`.** In
  `tests/review-prs-gh-dedup-test.sh`, `d1_off` used to unset `JOBS_URL`.
  Production reads an unset one as the fleet worker (`bin/lib/jobs/req.sh`), so
  that is a configured box. `d1_off` now sets it empty, and the stub jobs client
  carries req.sh's unset-means-fleet-default line, so V6 fails if `d1_off` goes
  back to unsetting.

Pinned by `tests/review-prs-d1-nits.bh-2492-test.sh` and V6 of
`tests/review-prs-gh-dedup-test.sh`.
