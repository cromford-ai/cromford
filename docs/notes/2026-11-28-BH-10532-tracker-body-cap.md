# BH-10532: Jira and Linear webhook body cap and pre-read signature shape check

## What changed

- `POST /webhooks/jira` and `POST /webhooks/linear` (`worker/jobs/src/routes/webhooks.js`) do not call `req.text()` any more.
- The order on each route is now:
  1. 405 when the method is not POST.
  2. `trackerPreCheck(env, vendor, headers)` (`worker/jobs/src/lib/tracker-webhooks.js`), with no body read:
     503 when the vendor secret is unset, 401 `bad signature` when the signature header is missing or has the wrong shape.
     Jira: `sha256=` + 64 lowercase hex. Linear: 64 lowercase hex.
  3. `readCappedBody(req, bodyCapOf(env, vendor))`: 413 `{error: "payload too large", cap}` over the cap.
  4. The unchanged `verifyJira` / `verifyLinear` HMAC on the capped body.
- `bodyCapOf(env, vendor = "github")` (`worker/jobs/src/lib/webhook-receiver.js`) reads `webhook.<vendor>.max_body_bytes` from the in-memory settings snapshot. An unknown vendor, a cold snapshot or a value outside 1024..26214400 uses the fallback 5242880.
- New settings rows `webhook.jira.max_body_bytes` and `webhook.linear.max_body_bytes`, seeded with 5242880 by `worker/jobs/schema.d/202611280232-bh-10532-tracker-webhook-body-caps.sql` (`INSERT OR IGNORE`).
- The GitHub route is unchanged.

## Why the shape check changes no outcome

`hexEqual` is case-sensitive and `hmacSha256Hex` returns lowercase hex. A header that fails the shape check already failed the HMAC before this change. The 401 now comes before the body read.

## Tests

`worker/jobs/test/webhook-body-cap-trackers.bh-10532.test.js`.
