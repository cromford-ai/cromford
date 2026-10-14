# 2026-10-06 — BH-4936: served-sha watch, the tracer of #4916

Doc: OPERATOR-SETUP, ALERTS-STATE-MACHINE

**Why.** project-3 #467 merged 2026-10-06T16:10Z as 2b2272a4. Vercel never
created a deployment for it, prod served a ~5h old build, and nothing alerted.
Nothing in the harness compared what a production domain serves with main HEAD.

**What changed.** A new hub lane, `bin/served-sha-watch.sh`
(`cron/lanes/251-served-sha-watch.cron`, every 5 minutes, behind
`hub-lease.sh check`), and its library `bin/lib/served-sha-watch.sh`. Per
`vercel.conf` project it reads main HEAD (`gh_rest`, App identity through
`gh_default_auth_for_project`), the sha the domain serves (alias, then
deployment), HEAD's production deployment state, and GitHub's compare when the
shas differ. It judges, writes `state/served-sha-watch/<project>.json` and
logs to `logs/served-sha-watch.log`. It sends no alert and starts no deploy.
Those are #4937 and #4938, and they plug in as hooks.

**The judge** (`ssw_judge now head_ts lag_s head served compare dep_state`, first match wins):

| # | condition | verdict |
|---|---|---|
| 1 | head or served empty, or not 8-40 lowercase hex | unreadable |
| 2 | one sha is a prefix of the other at the shorter length | in-sync |
| 3 | compare `identical` or `behind` (served descends from HEAD) | in-sync |
| 4 | compare unread | unreadable |
| 5 | HEAD's production deployment `failed` | alert |
| 6 | no head_ts | wait |
| 7 | `now - head_ts >= lag_s` | alert, else wait |

head_ts is HEAD's committer date. When that is missing it is the `first_seen`
the state file recorded for this head (NOW on first sighting, so the first
tick waits). `building`, `ready`, `none` and `unread` deployment states change
nothing except through the age. A build still running past the lag alerts.

**The hook contract.** The driver sources `bin/lib/served-sha-watch.d/*.sh` in
lexical order and, per project after the state write, calls every
`ssw_hook_*` function in a subshell as
`ssw_hook_<name> <project> <verdict> <head> <served> <dep_state> <age_s> <state_file>`,
with `SSW_SLUG SSW_TEAM SSW_PID SSW_VNAME SSW_NOW SSW_LAG_S SSW_DOMAIN
SSW_AUTODEPLOY H` exported. Hooks also run on `unreadable` and `in-sync`. A
non-zero rc is logged (`hook <name> rc=<n>`), never fatal. After the hooks, an
`in-sync` verdict deletes the state file. The driver merges its fields into the
existing state object, so keys a hook writes there survive the next tick.

**Choices made without the parent plan** (it was planned on another box):
an unread compare while the shas differ is `unreadable`, not an age alert;
`SERVED_SHA_VERCEL_AUTH`, when set, is the only auth file tried; and the token
reaches curl only through its `-K -` config on stdin, never argv.

Verified by `tests/served-sha-watch.bh-4936-test.sh`.
