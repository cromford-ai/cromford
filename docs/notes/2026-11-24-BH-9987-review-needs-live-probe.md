# BH-9987: a ticket reaches `review` only after a live probe of its primary screen

Slice C1 of #9908. In one week clients moved 9 tickets from `review` back to
`in_progress` (7 project-2, 1 project-4, 1 project-3). `bin/board-closeout.sh`
moved an in-app ticket to `review` at PR open, before any merge or deploy, so
the production link in the comment did not show the change yet.

## Change

- New lib `bin/lib/review-probe.sh`: `rp_required`, `rp_primary_route`,
  `rp_probe`, `rp_passes`. One unauthenticated GET, redirects followed (at most
  5). Outcomes: `served` (2xx at the base host and the route), `signin` (2xx at
  a `/sign-in`, `/signin`, `/login` or `/log-in` path on any host), `elsewhere`
  (any other 2xx), `error` (000, 3xx, 4xx, 5xx, no parse). Only `served` and
  `signin` pass.
- `bin/board-closeout.sh`: an in-app `PR_CREATED` moves the ticket to
  `in_progress`, not `review`. The comment says "It moves to review after it
  merges and its main screen answers in production." The issues lane,
  `PR_MERGED`, slices at merge and staging projects do not change. With no lib
  on the box the ticket goes to `review` as before, and stderr says why.
- `bin/merged-ticket-advance.sh`, step 6p: a client-filed move to `review`
  whose audit is not `PASS` (`NOT_COVERED_NO_QA_ENV`, or a peer build) first
  probes `<prod-url.sh>` + the first static route of the plan's `## QA screens`
  (else `/`; always `/` on the peer path). A pass adds one paragraph with the
  probed URL to the comment. Anything else holds the ticket: no comment, no
  marker, no move, no `.tries` bump, one `MERGED_ADVANCE_PROBE_HOLD` log line,
  one alert per ticket and audit token (`state/merged-advance-<p>-<id>-<token>.probe-alerted`).
  The next run probes again. `PASS`, a move to `done`, a staging hold and a
  move retry make no probe.
- The `MERGED_ADVANCE` log line ends with a new field, `no-live-probe=N`.
- Knobs (`catalog/lanes.d/_lib.review-probe.json`):
  `lib.review-probe.review_probe_require` (default 1; 0 gives the old
  behavior) and `lib.review-probe.review_probe_timeout_s` (default 20 s).

## Not changed

- `bin/decompose-parent-close.sh` still moves a split parent to `review` when
  every child is `done`. Each child passed its own gate.
- A hand move to `review` by a person.

Suite: `tests/review-probe.bh-9987-test.sh`.

Doc: BOARD-API-CONTRACT, VERIFICATION-MAP
