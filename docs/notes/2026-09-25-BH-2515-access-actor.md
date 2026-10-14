# Console writes name the operator's Cloudflare Access email

Doc: CONSOLE

## What changed

- `console-ui/functions/_lib/access-identity.js` (new, not a route) resolves
  who a console request is. It reads `Cf-Access-Authenticated-User-Email`, but
  only trusts it when `Cf-Access-Jwt-Assertion` verifies RS256 against
  `https://<team>/cdn-cgi/access/certs`, has the configured AUD in `aud`, has
  `iss` = `https://<team>`, has not expired (60 s skew), and carries the same
  email (trimmed, lower-cased) in its `email` claim. The certs are cached per
  isolate for 10 minutes; a failed fetch or an unknown `kid` is retried at most
  once a minute.
- The answer is one of four states: `on` (the email is the actor), `off`
  (`CF_ACCESS_TEAM_DOMAIN` or `CF_ACCESS_AUD` unset), `unverified` (env set,
  but this request proves nobody) and `unrecordable` (verified, but the email
  has a character outside the worker's actor charset `^[A-Za-z0-9._@-]{1,96}$`,
  e.g. `+`). Every state except `on` records `console`. Nothing is refused on
  identity; the `dash` cookie is still the gate.
- The coord proxy (`functions/api/coord/[[path]].js`) resolves that actor once
  per admitted write (`writeActor`) and stamps it wherever main's `WRITES`
  table stamped `SESSION_ACTOR`: every row's body and the call-guard DELETE
  query. Each row's allowlist and narrowing is unchanged. `GET
  /api/coord/whoami` answers `{actor, access, email}` from the function itself.
- The catch-all proxy (`functions/api/[[path]].js`) sets `actor` on the body of
  `POST /api/dash/action` (a command). A non-object body there is a 400. Every
  other request is forwarded as before.
- `bin/poll-commands.sh` `pause_board` / `pause_set` write the command
  payload's `actor` on the pauses row when it is a string in the worker's actor
  charset, and `console` otherwise (missing, non-string, blank, `x:y`).
- **Pause commands still record `console`.** harness-console's
  `pauseCommand()` rebuilds the command payload without `actor`, so the stamp
  above does not reach the box today. It is left there on purpose: the console
  worker is also reachable directly with the shared dash cookie, so it cannot
  tell a Pages-stamped actor from a browser-sent one. The pill's title names
  this exception.
- The top bar shows an identity pill: the email, `ACCESS OFF · writes as
  console`, `IDENTITY UNVERIFIED · writes as console`, `<email> · recorded as
  console`, or `identity unknown` when the whoami read failed.

## Setting it up

Put Cloudflare Access in front of the console host, then set both on the
Mission Control Pages project (production and preview):

- `CF_ACCESS_TEAM_DOMAIN`: `<team>.cloudflareaccess.com`
- `CF_ACCESS_AUD`: the Access application's AUD tag

With either one unset the console behaves as before and the pill says ACCESS OFF.

## Why the header alone is not enough

On a hostname Access does not cover (the `*.pages.dev` one) any client can send
`Cf-Access-Authenticated-User-Email`. Only the signed assertion proves Access
put it there.
