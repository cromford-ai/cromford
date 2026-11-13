# BH-9354: a triage session's gh keeps a valid token for the whole session

Doc: CALL-GUARD

## The incident

On 2026-11-09 four triage sessions on box-small got `HTTP 401 Bad
credentials` from `gh` and `gh-rest-shim` (BH-9283 twice, BH-9262, BH-9285).
At the same time the box's App token and env/gh-pat answered 200. The lead
reported a box that had "lost its GitHub token". That was wrong.

## How GH_TOKEN reaches the session (before this change)

1. `bin/run-triage.sh` sources `bin/lib/triage-gh-token.sh` and runs
   `triage_gh_premint` (`gh-token.sh --min-life 3000`).
2. The `# >>> triage github auth` block runs `gh_default_auth_for_project`
   (`bin/lib/gh-app-auth.sh`). It calls `gh-token.sh <slug>` once and exports
   `GH_TOKEN=ghs_…`. This is the only mint for the whole tick.
3. `bin/lib/rt/shards.sh` starts each shard with `lock_spawn_unheld setsid
   bin/triage-shard.sh`. The shard inherits the exported `GH_TOKEN`.
4. `bin/triage-shard.sh` runs `bin/agent-call.sh triage …`. agent-call passes
   the env to the runner (`env "${FENCE_ENV[@]}" PATH=…`, no `env -i`).
5. In the session, `gh` is `bin/gh-ledger/gh`. Its C2 block picks an identity
   only when `GH_TOKEN` is empty. In a triage session it is never empty.
6. `bin/gh-rest-shim` runs the first non-fence `gh` on PATH, so it uses the
   same token.
7. git uses `gh auth git-credential` or another helper. That is why `git
   ls-remote` worked while `gh` failed.

So a token that went bad after step 2 (expired in a long session, revoked, or
a wrong token at step 2) stayed in the session until the session ended. This
change does not prove which of the three happened on 2026-11-09. The
recovered-call log line below names the refused token, so the next event does.

## What changed

- `bin/gh-session/gh` (new): the session's `gh`. `triage_gh_session_arm`
  (`bin/lib/triage-gh-token.sh`, one call line after `# <<< triage github
  auth` in `bin/run-triage.sh`) puts it first on the tick's PATH when the
  tick armed a `ghs_` token. It runs in front of `bin/gh-ledger/gh`, so the
  ledger still sees every call.
  - Rung 0, every call: the token from `gh-token.sh --min-life
    GH_SESSION_MIN_LIFE_S` (a cache read), else the armed token.
  - On a 401 (rc != 0 and gh's stderr says `HTTP 401` or `Bad credentials`):
    rung 1 `gh-token.sh --fresh`, rung 2 env/gh-pat. A call that reads stdin,
    a watch and `auth` get rung 0 only. Rungs 0 and 1 take only a `ghs_`
    token: `gh-token.sh` prints the PAT when a mint fails, and the PAT is
    rung 2 only.
  - Recovered: one `gh-session: recovered 401` line in `logs/<project>.log`.
  - 401 on every credential: one `[gh-session]` ALERTS line per slug per
    `GH_SESSION_ALERT_EVERY_S`, written by `gh_app_default_alert`
    (`bin/lib/gh-app-default.sh`, source `gh-session`). It names each token tried (prefix and length,
    never the value), the expiry from `gh-token.sh --expires-at`, and the box
    probe (`GET repos/<slug>` on a box App token and on env/gh-pat). When a
    probe answers 200 it says "The box credentials are valid; the fault is in
    this session's token path. Do not replace the PAT."
  - A caller that set its own token (a build started from the session), a
    nested gh and a mint pass straight through.
- `bin/lib/gh-session-token.sh` (new): the decisions (the 401 rule, retry
  eligibility, the mint, the probe, the alert).
- `bin/lib/call-guard.sh`: an allowed call exports `GH_SESSION_AUTH_FAIL_FILE`.
  The wrapper touches it on the all-401 path. `call_guard_finish` then settles
  `unbilled` when no runner that ran is metered, so a 401 tick does not count
  toward the repeat limit. A metered runner still counts as paid.
- Knobs `lib.gh-session.*` (`catalog/lanes.d/_lib.gh-session.json`): remint
  1, min life 600 s, mint timeout 15 s, probe timeout 10 s, alert window
  3600 s, PAT fallback 1. The off switch is the row
  `lib.gh-session.gh_session_remint` = 0. There is no flags/ file.

## How to check it on a box

- In a triage tick's env, `command -v gh` prints
  `/root/harness/bin/gh-session/gh`.
- `grep 'gh-session' /root/harness/logs/<project>.log`
- `grep '\[gh-session\]' /root/harness/logs/ALERTS.log`
