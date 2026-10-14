# The local MCP server logs in with the console secret (BH-5226)

Doc: MCP

## What changed

- `mcp/lib/console.mjs`: with no `HARNESS_CONSOLE_TOKEN` and a
  `HARNESS_CONSOLE_SECRET`, `consoleFetch` now logs in once with
  `GET <url>/login/<secret>` (`redirect: 'manual'`), takes the `dash=` value from
  `Set-Cookie` and sends `Cookie: dash=<value>`. Before this a secret alone
  returned `console_auth_not_configured` and sent nothing.
- The cookie is held in a module-level `WeakMap` keyed by the `cfg` object, in
  memory only. Concurrent calls share one in-flight login.
- A 401 in cookie mode drops the cookie, logs in once more and retries once. A
  second 401 is `http_401`. A token-mode 401 is `http_401` with no login.
- A login answer with no non-empty `dash` cookie is `console_login_failed`, and
  no API request is sent.
- A token still wins when both are set: Bearer, no `/login` request.
- `redact(text, cfg)` also scrubs the cached cookie and the URL-encoded secret,
  and rewrites `/login/<secret>` to `/login/[redacted]`.
- A fetch that throws (login or API) writes one redacted stderr line,
  `cromford-mcp: console <METHOD> <path> failed: <message> (<cause>)`, then
  returns `network_error` as before.
- Signatures of `consoleFetch` and `redact` are unchanged; `server.mjs`,
  `tools.mjs` and the tools are untouched.

## Tests

`tests/mcp-auth.bh-5226-test.sh` runs `mcp/test/no-secret-leak.test.mjs`: the
login flow in-process, sweeps of the spawned server with a token and with a
secret (every no-confirm tool, then a 500 that echoes the headers), a network
failure, and two mutation pins that run a copy of `mcp/` with `redact` broken.
`mcp/test/tracer.test.mjs` U8 keeps only its no-token-no-secret row.
