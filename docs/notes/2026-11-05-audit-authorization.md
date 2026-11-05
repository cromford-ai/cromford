# Authorization audit fixes

Owner box operations now require the fleet bearer, an independent
`x-box-ops-token` header matching `BOX_OPS_TOKEN`, and an actor listed in
`BOX_OPS_OWNERS`. An unset token, or one equal to `HARNESS_SECRET`, fails
closed. Ordinary fleet boxes must never receive this token.

Set the same new `BOX_OPS_TOKEN` secret on the jobs worker and the Pages
project. Keep `BOX_OPS_OWNERS` on the jobs worker. Pages forwards the token
only after the console session probe succeeds and Cloudflare Access verifies
the caller's signed email assertion. Configure `CF_ACCESS_TEAM_DOMAIN` and
`CF_ACCESS_AUD` for owner controls. The fallback `console` identity cannot
request owner operations; direct trusted operators must present both tokens
and their owner actor. Browser-supplied actor and token values do not grant
owner authority.

Set a separate, matching `QA_READ_TOKEN` secret on jobs and Pages. It must
differ from `HARNESS_SECRET`. QA sessions use this credential, never the main
fleet credential. Only the exact GET paths `/api/coord/jobs`
and `/api/coord/flags` are available to them, and jobs
independently restricts the token to the corresponding `/api/` paths. Other
reads, including OTP, command payloads, settings, and newly added routes, are
denied. Any `dashqa` cookie enables this restriction even beside a forged
`dash` cookie. Additional QA views need explicit review at both boundaries.
Job and flag results expose only approved display fields. Free-form metadata,
heartbeat notes, flag values/reasons, and future columns are excluded at jobs
itself; operator responses retain their complete shape.

Merge retries verify the console session before changing the command ledger.
Generic settings writes reject `hub_envelope_public_key`; its existing
hub-token route remains the only public writer and retains its audit event.

Regression tests are in `tests/audit-authorization.test.mjs`. All five groups
failed against the original code before the changes. Existing owner, quote,
and merge-retry test fixtures now supply the credentials required by the
fixed behavior. The owner/quote fixtures also replace invalid hyphenated
Orgo IDs with valid `box3`/`box4` example IDs while retaining invalid-ID cases.
