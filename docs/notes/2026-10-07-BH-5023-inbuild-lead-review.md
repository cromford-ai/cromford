# A medium-risk PR gets its lead-grade review inside the build (BH-5023)

Doc: MERGE-CONDUCTOR

## What changed

- A build that settles APPROVE and has a PR now runs
  `bin/inbuild-lead-review.sh` before close-out (the
  `# >>> inbuild lead review` block of `bin/run-build.sh`). The script acts
  only when the head is still the one the build settled on, the risk tier
  (`bin/lib/risk-tier.sh`, wave 1) is **medium**, and the repo's
  `risk_tier.mode[.<owner>.<name>]` row is `enforce`. In `shadow` it logs
  `WOULD review in-build` to the build's `pipeline.log` and spends nothing.
  In `off` it does nothing.
- On a medium head it files a lead review request for that head
  (`requested_by: inbuild:<box>:<KEY>`) and runs
  `bin/lead-review.sh one <request-id>` right away. `one` is a new
  subcommand that runs the lead lane's own `review_one` on that one request,
  so the prompt (`prompts/lead-review.md` plus the checklist), the model route
  (`model_for lead.review`), the rules pack, the host suite and the paid-once
  ledger are the same as the lead lane's. It takes no tick lock. The job key
  and the claim are the same as the tick's, so the two never review one head
  twice. `flags/lane-off-lead-review` stops it too.
- The hub's `bin/lead-review-land.sh` promotes the result as it does any lead
  review: MERGE gives `lead-verdict` success on that sha, and BLOCK gives
  failure plus the REQUEST_CHANGES review that briefs a fix round. For an
  `inbuild:` row it first checks that a builder APPROVE is bound to that head
  (`reviewed_sha` = head, or `reapproved@<head>`). Without one it posts
  nothing, stamps nothing and sends one critical lane-alert
  (`lead-inbuild-noapprove-<id>`). The verdict row's note carries
  `inbuild:<box>` beside `lead-review:<id>`.
- The jobs worker lets a caller with only the bearer create a request when
  `requested_by` is exactly `inbuild:<box>:<KEY>` and there is no priority.
  Every other create still needs the lead token.
- The hub's `bin/lead-review-enqueue.sh` holds a medium head under enforce
  for the in-build review before it requests a lead review itself. The hold
  is `risk_tier.inbuild_grace_s`, a settings row (fallback 3600 s), counted
  from the first tick that saw the head (marker
  `state/lead-review-enqueue/inbuild-wait-<slug>-<n>-<sha12>`, kept 7 days).
  Its tick line counts `risk_inbuild_wait=`. When the hold runs out, the head
  is requested as before. A rebound head (`reapproved@<head>`) is never held,
  because no build settled on it.

## What re-runs it, and what does not

Any push `bin/run-build.sh` makes runs the in-build review again on the new
head: a fresh build, or a resolver rebuild. A push from another lane (a CI
repair round, a rebase train, a fix round) does not. That head waits out the
grace and then goes to the lead lane. An old head's `lead-verdict` never
carries over to a new one.

## Knobs

    bin/jobs-client.sh setting-set risk_tier.inbuild_grace_s 1800   # shorter hold
    bin/jobs-client.sh setting-set risk_tier.mode.<owner>.<name> enforce

A build gets up to `LEAD_REVIEW_DEADLINE_S` + 120 s longer when it reviews a
medium head in-build.
