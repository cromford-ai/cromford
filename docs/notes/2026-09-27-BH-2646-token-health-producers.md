# Token health producers: OAuth logins and GitHub App mints report (BH-2646)

Doc: ACCOUNT-ROUTING

## What changed

`bin/lib/token-health.sh` is no longer a stub. `token_health_report <kind>
<subject> <ok|fail> [expires_at_iso] [error]` now sends one POST
`{kind, subject, box, ok, expires_at, error}` to
`/api/account-leases/token-health` through `bin/jobs-client.sh`'s `_jobs_req`.
The send uses `curl -m 5`, is never retried, and never writes the daily
jobs-client ALERTS line. It runs in a subshell, so the client's
`set -uo pipefail` and its `exit 1` on missing modules never reach the caller.
It always returns 0 and never prints to stdout. The only stderr line is local
misuse (bad kind, empty subject, bad status), and misuse sends nothing.

No request is made when `TOKEN_HEALTH_REPORT=0`, when `JOBS_URL` is empty, or
when no `jobs-client.sh` with its `lib/jobs/` modules sits beside the lib.

The error text is scrubbed before it leaves the box. Newlines become spaces,
any word containing `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`,
`sk-ant-` or `eyJ` is dropped, and the result is cut to 200 characters.

## Who reports, and under which subject

| Producer | kind | subject | When |
|---|---|---|---|
| `bin/oauth-refresh.sh CONFIG_DIR ACCOUNT` | `oauth` | the ACCOUNT arg | ok + file expiry (ISO) on exit 0, whether fresh or refreshed; fail + tail reason on exit 1; nothing on exit 2 or when ACCOUNT is empty |
| `bin/gh-token.sh` `mint()` | `gh_app` | `app-<installation id>` | ok + expiry after `cache_write`; fail when access_tokens fails or returns no token |
| `bin/gh-token.sh` `mint()` | `gh_app` | `app-unresolved-<owner>` | fail when the installation id cannot be resolved |

`bin/quota-poll.sh` passes the account name (`$A`) and
`bin/extra-usage-track.sh` passes the login label (`$LABEL`) as ACCOUNT.
Cache hits in gh-token.sh never reach `mint()` and send nothing. Both
producers source the lib behind a guard, so a box whose `bin/lib/` predates it
still refreshes and mints.

## Knob

`TOKEN_HEALTH_REPORT` (catalog/lanes.d/_lib.token-health.json, default 1) is
now read: 0 turns reporting off. `TOKEN_HEALTH_WARN_H` is still registered only.

Pinned by `tests/token-health.bh-2646-test.sh`.
