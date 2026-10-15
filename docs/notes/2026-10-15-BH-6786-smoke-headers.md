# The prod smoke probe is a browser page load on a per-project path (BH-6786)

Doc: EVENTS

## What changed

`bin/deploy-verify.sh` smoke-checks prod after a merge. It used a bare
`curl -s -o /dev/null -w '%{http_code}' -m 30 -L <prod>`, with no `Accept`,
no `Sec-Fetch-Dest` and the curl User-Agent. project-6-os `/` now redirects to
`/os`. Clerk answers a signed-out request that is not a page load with 404. So
the probe read 404 and paged `deployfail:project-6-os:d33bbe7e`
(2026-10-14 17:00Z) while prod was healthy.

Both smoke probes (the github-deployment path and the smoke-only path) now go
through `bin/lib/smoke-probe.sh`:

| Function | What it does |
|---|---|
| `smoke_code <url>` | `curl -L` with `Accept: text/html,application/xhtml+xml`, `Sec-Fetch-Dest: document`, `Sec-Fetch-Mode: navigate` and a browser User-Agent. Prints the final code; `000` if curl cannot connect. |
| `smoke_url <project> <base>` | Prints `<base>` plus the settings row `deploy.<project>.smoke_path` (key lowercased). No row, a settings outage or no client on the box prints `<base>` unchanged. |

A `smoke_path` value must match `^/[A-Za-z0-9._~?=&%-][A-Za-z0-9._~/?=&%-]{0,199}$`
or be exactly `/`. Any other value (no leading `/`, a leading `//`, a space,
more than 200 chars) is ignored: one stderr line names the key (it lands in
`deploy-verify.log`) and the probe uses `<base>`. The host always comes from
`bin/prod-url.sh`, never from the row.

The accepted codes do not change: `2*|3*` on the github-deployment path,
`2*|3*|404` on the smoke-only path. The OK and FAIL lines name the probed URL,
path included (`deploy-verify OK: prod deployed <sha8>, https://os.example.com/sign-in -> 200`).

If `bin/lib/smoke-probe.sh` is missing on a half-synced box, `deploy-verify.sh`
falls back to the old bare curl on the bare URL.

## Settings row

Seeded by `worker/jobs/schema.d/202610151536-bh-6786-smoke-path.sql`
(INSERT OR IGNORE):

| Key | Value |
|---|---|
| `deploy.project-6-os.smoke_path` | `/sign-in` |

Every other project has no row and keeps the bare prod URL. To set a path for
another project, write the row `deploy.<project>.smoke_path` in the settings
table.

Check the row after the next harness-sync applies the schema:

```bash
. /root/harness/bin/jobs-client.sh && setting_get deploy.project-6-os.smoke_path   # expect /sign-in
```

## The old alert

`deployfail:project-6-os:d33bbe7e` is a false positive. Resolve it by hand on
the hub (operator step):

1. Find its id: `curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open" | jq '.alerts[] | select(.akey=="deployfail:project-6-os:d33bbe7e") | .id'`
2. Resolve it: `curl -s -X POST -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' -d '{"ids":[<id>],"reason":"false positive: smoke check without browser headers (BH-6786)"}' "$CONSOLE_URL/api/alerts/resolve"`
3. Check that step 1 now prints nothing.

## Replay against prod

The probe sees only today's prod. An old merge sha cannot change what
os.example.com answers now, so this is not a per-merge replay. It is 10
old/new probe pairs against today's prod, one per project-6-os merge that the
old probe checked. Run it on a box with egress to os.example.com:

```bash
. /root/harness/bin/lib/smoke-probe.sh
for i in $(seq 1 10); do
  old=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -L https://os.example.com)
  new=$(smoke_code https://os.example.com/sign-in)
  echo "probe $i old=$old new=$new"
done
```

Result, 2026-10-15T07:45:33Z to 07:45:37Z, from the BH-6786 fix session:

```
probe 1 old=404 new=200
probe 2 old=404 new=200
probe 3 old=404 new=200
probe 4 old=404 new=200
probe 5 old=404 new=200
probe 6 old=404 new=200
probe 7 old=404 new=200
probe 8 old=404 new=200
probe 9 old=404 new=200
probe 10 old=404 new=200
```

The old probe read 404 10 times out of 10. The new probe read 200 10 times
out of 10, so 0 false 404 alerts. `smoke_code https://os.example.com` (new
headers, no path) also read 200. The build token cannot read
`example-org/project-6` (GitHub answered 404), so the run did not list the 10
merge shas.

## Tests

`tests/deploy-verify-smoke.bh-6786-test.sh` runs the real `bin/deploy-verify.sh`
with the real curl against a local stub server that answers 404 to a request
that is not a page load and 307 → 307 → 200 to a page load.
