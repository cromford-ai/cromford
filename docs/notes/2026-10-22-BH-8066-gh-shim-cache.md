# The gh PATH shim is a read-through cache for `gh api` GETs (BH-8066)

Doc: GH-REST

## What changed

Over the 24 hours before 2026-10-22 20:00Z the fleet made 286,509 REST calls
and 22,983 GraphQL calls for 193 merged PRs: 1,484 calls per merged PR. The App
installation ran at about 9,500 calls an hour against a 6,900 cap. Two thirds
of the calls re-read state that did not change.

`bin/gh-ledger/gh` is the first `gh` on PATH on the hub, the boxes and the Fly
builders. It now calls `bin/lib/gh-cache.sh` for each eligible `gh api` GET:

- An entry younger than `GH_CACHE_TTL_S` (default 60, 0 = off) is replayed
  from `state/gh-cache/` with no request. The ledger row has status `cache`,
  counted 0.
- An entry past the TTL is revalidated with `If-None-Match`. A 304 replays the
  entry and resets its fetch time. A 200 replaces it.
- With no entry, the caller's own `If-None-Match` is removed, so the 200 gives
  a body to keep. gh_rest pays one counted 200 per key per box to seed it.
- Any answer other than 200 or 304 is printed as gh gave it, and the entry is
  deleted.

Eligible: method GET (fields only with an explicit `-X GET`), no `--input`,
`--paginate`, `--slurp`, `--verbose` or `--cache`, one endpoint that is not
`graphql`, has no `{owner}`/`{repo}`/`{branch}` placeholder, and is not
`rate_limit`, `actions/artifacts/N/zip`, `actions/jobs/N/logs` or
`installation/token`. An unknown flag makes a call ineligible.

Stored only when: status 200, rc 0, nothing on stderr, exactly one HTTP
request, an ETag, no `Cache-Control: no-store`, at most `GH_ETAG_MAX_BYTES`.

The key is sha1(GET, the token bucket `gh_quota_bucket` names, the argv without
If-None-Match). The output flags (`--jq`, `-i`, …) are part of the key, so two
renderings of one URL never share an entry.

## Invalidation

A hit older than `GH_CACHE_WAKE_GRACE_S` (default 5) reads
`GET /api/wakes?since=<watermark>` through the jobs client, at most once per
grace per box (`flock -n` on `state/gh-cache/.wakes.lock`; a busy lock makes
the call conditional). Each wake drops `<repo>~r~*` (lists and repo metadata)
and the object's entries: `n-<N>` for a PR or issue number, `s-<sha12>` for a
`checks` sha. The first sync seeds the watermark from the hub's wake cursor and
drops every entry once. A box that cannot read the wakes (no
`HARNESS_SECRET`, no client, a failed read, no hub cursor) is TTL-only; it
writes one `wakes unreachable` line to `logs/gh-cache.log`, retries after
`GH_CACHE_TTL_S`, and writes one `wakes reachable again` line when it works.

The wake row is not changed. It already carries `repo`, `kind` and `key`
(the PR or issue number, or the head sha of a `checks` wake). A wake the worker
deduplicated into an earlier row of the same minute moves no watermark; the TTL
bounds that case.

## Ledger and reports

- Ledger column 15 `served`: `cache`, `304`, `-` (status 000) or `200` (any
  other answer). gh_rest reads the `X-Gh-Cache-Served` header a replay carries,
  writes `cache`/`304` with counted 0, and does not persist the replayed
  rate-limit headers.
- A `cache` row is not a request. `bin/gh-budget-report.sh`,
  `bin/gh-ledger-report.sh`, `bin/gh-quota-report.sh` and
  `GET /api/metrics/gh-ledger` (every group, the totals and the per-box read)
  leave it out of calls.
- `bin/gh-budget-report.sh` prints `SERVED cache=<n> (<p>%) 304=<n> (<p>%)
  200=<n> (<p>%)` and a `served` JSON block, from `group=served` or the local
  hour files. A worker without that group prints `SERVED n/a (worker has no
  served group)`.

## Retention

`state/gh-cache/` uses the gh-rest-etag sweep (`_gh_etag_sweep <dir>`) after a
store: at most hourly, entries older than `GH_ETAG_TTL_H` (48) go, and the
newest `GH_ETAG_MAX` (20000) stay.

## Owed

The ticket's last acceptance item needs one day on the hub after deploy:
`bin/gh-budget-report.sh --window 24h` must show calls per merged PR under 300.
