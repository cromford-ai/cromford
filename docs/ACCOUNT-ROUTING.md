# Quota-aware account routing

A box can hold N accounts of a vendor — Claude subscription accounts, Codex
accounts, API-key accounts for grok/OpenRouter/Fireworks — and `bin/agent-call.sh`
can pick, per stage call, the account of the wanted vendor that still has quota
headroom. Nothing here changes which MODEL a stage uses; it changes which ACCOUNT
pays for it.

**The `agent-call.sh` hook is default OFF.** With `ACCOUNT_ROUTING` unset or `0` —
or set to `1` on a box with no `env/accounts.d/*.env` — `agent-call.sh` runs the
same commands with the same environment it runs today. The only observable
difference in the second case is one line per call in `logs/account-routing.log`.

**Fly pool machines are the exception, and they are default ON** (2026-09-14).
They are routed by a different piece of code with a different switch — see
[Pool machines (Fly)](#pool-machines-fly).

### Hub and boxes = project-6; pools = the max accounts

the operator, 2026-09-14: *"for project-6 I want to use it for project-5 and
aiorg/project-6 build boxes and the main hub."* So the split is deliberate and
the two halves do not share a switch:

| where | account | switch |
|---|---|---|
| the hub's own stages (review, preplan, triage, conductor re-reviews) and the project-5 / project-6 / project-9 / small boxes | the project-6 token in that box's `global.env` | `ACCOUNT_ROUTING=0` on the hub |
| ephemeral Fly **pool** builder machines | one of `max1..max7`, leased per machine | `POOL_ACCOUNT_ROUTING` (default on) |

`max1..max7` are **pool-only**. The pool lease is therefore *not* gated on
`ACCOUNT_ROUTING`: it calls `bin/account-pick.sh`'s ranking functions directly as
a library, so setting `ACCOUNT_ROUTING=0` on the hub — which is the intended
state — does not disable pool routing.

---

## Terms of service — read this before registering a second account

Anthropic's Consumer Terms of Service and Usage Policy prohibit sharing account
credentials with other people and using multiple accounts (or any other method)
to get around usage limits; a consumer subscription is for one person's use.
OpenAI's ChatGPT terms carry the same restriction for Codex subscriptions. This
harness ships the *mechanism* — per-account credentials, quota reads,
headroom-based routing, cooldowns — because the same machinery is what separate,
legitimately-owned accounts need: client-owned accounts that already pay for
their own builds (project-3, project-2), Claude for Work seats, and metered API-key
vendors that have no such limits at all (grok, OpenRouter and Fireworks are
"unmetered" here for exactly that reason). Registering more than one consumer
account for the same person on a box, or routing one person's work across
accounts to exceed a plan's limits, is a decision the harness does not make and
does not encourage: whether and how to use this is the operator's call and the operator's
responsibility, and the default is OFF.

---

## The pieces

| file | what it does |
|---|---|
| `env/accounts.d/<name>.env` | the registry: one account per file, gitignored, `chmod 600`. Format: `env-templates/accounts.d/EXAMPLE.env.example` |
| `bin/account-pick.sh <stage> <vendor> <model>` | prints the chosen account plus the `export`/`unset` lines for its credentials; exit 2 = no account of that vendor has headroom |
| `bin/quota-poll.sh` | hourly (cron, :23): writes `state/quota/<account>.json` |
| `bin/quota-status.sh [--json]` | the per-account table for this box, one line per vendor cooling that account; `--clear-cooldown <vendor> <account>` releases one |
| `bin/lib/oauth-usage-fetch.py` | the one network call (Anthropic's OAuth usage endpoint) |
| `logs/account-routing.log` | `ts,project,stage,model,account,reason` — one line per pick |
| `logs/quota-poll.log` | `ts account status [reason]` — one line per account per poll |
| `env/tokens.d/<name>-setup-token.env` | the **shippable** 1-year setup token for an account, `chmod 600`, hub only. Deliberately OUTSIDE `accounts.d`, which holds logins that cannot ship |
| `bin/lib/pool-account.sh` | leases an account to one Fly pool machine at launch: `pool_account_lease`, `pool_account_release`, `pool_account_prune`, `pool_account_leases`, `pool_account_cooldown` |
| `state/quota/leases/<account>/<machine-id>` | one file per live pool build on that account |
| `state/quota/cooldown/<vendor>/<account>` | epoch seconds: that VENDOR's account refused us and is skipped for `ACCOUNT_COOLDOWN_SECS` |

---

## Adding an account to a box

### 1. Create the credential

**Claude, full login (preferred).** Only a full login's accessToken can read the
usage endpoint, so this is the only form that gets real 5-hour / weekly /
per-model numbers:

```bash
CLAUDE_CONFIG_DIR=/root/.claude-operator2 claude login
# then prove it can actually answer, BEFORE you enable the account:
CLAUDE_CONFIG_DIR=/root/.claude-operator2 claude -p 'reply ok' --output-format json
```

> A headless `claude login` into a fresh config dir has not yet been driven on a
> box in this fleet — the flag exists in the installed CLI (v2.1.263) and
> `CODEX_HOME` is in `codex --help` (0.153.4), but the login flow itself is
> unverified here. Run the probe above and treat its output as the acceptance
> step. If the credentials file never lands, `quota-poll.sh` will write
> `status: error` for the account rather than a number.

**Give the new config dir the machine rules.** The CLI reads `CLAUDE.md`,
`RTK.md` and `settings.json` from `CLAUDE_CONFIG_DIR`, so a routed build in a
fresh dir would run *without* the fleet rules and without the rtk hook:

```bash
ln -sfn /root/.claude/CLAUDE.md      /root/.claude-operator2/CLAUDE.md
ln -sfn /root/.claude/RTK.md         /root/.claude-operator2/RTK.md
ln -sfn /root/.claude/settings.json  /root/.claude-operator2/settings.json
```

Symlinks, not copies: `update-runners.sh` re-renders those three paths daily, and
a symlink keeps tracking. `quota-poll.sh` writes ONE `ALERTS.log` line per
account per day if any of the three is missing.

**Claude, setup-token.** `claude setup-token` also works for calls, but the usage
endpoint answers a setup-token HTTP 403 (`user:profile` scope), so the account's
status reads `unreadable` and routing falls back to cooldowns for it.

**Codex.** `CODEX_HOME=/root/.codex-operator2 codex login`. There is no quota source
for codex, so the status is `unknown` and the account is always considered
available until a call fails.

**API-key vendors.** Nothing to create; put the existing key in the file.

### 2. Register it

```bash
mkdir -p /root/harness/env/accounts.d
cp /root/harness-checkout/env-templates/accounts.d/EXAMPLE.env.example \
   /root/harness/env/accounts.d/operator2.env
chmod 600 /root/harness/env/accounts.d/operator2.env
$EDITOR /root/harness/env/accounts.d/operator2.env
```

The filename stem must equal `ACCOUNT_NAME`. `default.env` is refused — `default`
is the reserved name of the implicit account. A file that fails validation is
skipped with a `registry_skip:<file>:<reason>` line in
`logs/account-routing.log`, never a crash.

### 3. Check it

```bash
/root/harness/bin/quota-poll.sh          # writes state/quota/operator2.json
/root/harness/bin/quota-status.sh        # the table
/root/harness/bin/account-pick.sh eval claude claude-fable-5-1   # who would pay
```

### 4. Turn routing on

```bash
echo 'ACCOUNT_ROUTING=1' >> /root/harness/env/global.env
```

Then watch `logs/account-routing.log` and `logs/failovers.log` for a few builds.
To turn it back off, remove that line — no other state has to be undone.

---

## The `default` account

`default` is whatever `env/global.env` already exports (plus `~/.claude`,
`~/.codex`). It is always in the registry, at priority 100, and picking it emits
**zero** `export`/`unset` lines — the child's environment is byte-identical to a
non-routed call. It is a candidate whenever a vendor has no registry account at
all (so an unconfigured box stays a pure no-op) or when a default credential for
that vendor is actually detectable.

Its numbers are **derived, never polled**: `bin/extra-usage-track.sh` already
polls that account at :58, and the usage endpoint's rate limit is per account, so
a second poller would cost the tracker its sample. The tracker snapshots its raw
response to `state/extra-usage-last.json` and `quota-poll.sh` reads that.

**Which snapshot, though — the login's or the token's?** (BH-1456.) The plain
`state/extra-usage-last.json` is the BOX LOGIN's meter, and on a box where the
stored login and `env/global.env`'s `CLAUDE_CODE_OAUTH_TOKEN` are the same
account that is the right file. On the hub they are not: the login is
operator@example.com and the `default` token bills operator@example.com. So
`ACCOUNT_DEFAULT_LABEL` names the tracker login label whose snapshot describes
the account the token actually bills, and `quota-poll.sh` derives `default` from
`state/extra-usage-last-<label>.json` instead, recording
`source: extra-usage-track:<label>` so the row says whose meter it is. Set to a
label with no snapshot on this box, it logs one
`default fallback label_snapshot_missing:<label>` row per run and uses the plain
snapshot. Unset, the derivation is exactly what it was before.

---

## The rule the picker applies

1. Candidates: enabled accounts of the vendor whose `ACCOUNT_MODELS` allows the
   model, plus `default`.
2. Drop accounts inside their cooldown for THIS vendor
   (`state/quota/cooldown/<vendor>/<account>` newer than `ACCOUNT_COOLDOWN_SECS`)
   — see **Cooldowns** below.
3. Drop accounts over a headroom threshold, using `state/quota/<name>.json` ONLY
   when its `status` is `ok` and `polled_at` is younger than
   `ACCOUNT_POLL_STALE_SECS`: `five_hour.pct >= ACCOUNT_5H_MAX`, or
   `seven_day.pct >= ACCOUNT_WEEK_MAX`, or `per_model[<family>].pct >=
   ACCOUNT_MODEL_MAX` when the endpoint reports that family (`family` is the
   second dash-token of a `claude-*` slug, so `claude-fable-5-1` → `fable`).
   **A missing, stale, unreadable, unknown, unmetered or errored poll counts as
   AVAILABLE** — headroom unknown is not headroom zero, and refusing to call an
   account we have no numbers for would take the fleet down the day the poller
   breaks.

   **Overage answers before those thresholds** (BH-1456). When the poll's
   `extra_usage` object says `is_enabled: true`, the account is billing extra
   usage and the subscription windows above no longer describe what it can
   serve, so they are skipped: weekly 100% with overage on is a healthy working
   account, and on the hub it is the account every stage bills to. It is ranked
   on `extra_usage.pct` instead. What still drops it, because these are the
   reasons it genuinely cannot bill:

   | `extra_usage` says | class | detail |
   |---|---|---|
   | `spend_limit_reached: true` | `capped` | `spend_limit` |
   | `disabled_reason` non-null (Anthropic turned it off) | `capped` | `disabled` |
   | `user_disabled: true` | `capped` | `disabled` |
   | `pct >= ACCOUNT_EXTRA_MAX` | `capped` | `extra_cap` |
   | enabled and none of the above | `metered` | `overage` |

   `is_enabled: false` is "overage is off" and an ABSENT `extra_usage` (`null`)
   is "we have no reading" — neither takes the overage path, and both fall
   through to the thresholds exactly as before this change.

   `account_reading_class` prints `class|rank_pct|detail`. The detail is which
   rule produced the class (`5h`, `week`, `model`, `spend_limit`, `disabled`,
   `extra_cap`, `overage`, empty for a plain metered account); `account_pick`
   logs it as `drop:capped:<detail>` and the pool's `_pa_metered` prints
   `capped:<detail>`, because `capped` alone meant five different things and an
   operator could not tell a spent quota from a billing failure.
4. Sticky: if `state/quota/pins/<build-dir>` names an account that is still
   eligible, keep it, so a build's later stages hit the same warm prompt cache.
   Otherwise the lowest `ACCOUNT_PRIORITY` number wins; ties break on the lower
   fresh 5-hour utilization (an account with no fresh number sorts last among its
   ties), then on name.
5. Nothing left → exit 2, and `agent-call.sh` returns rc 76: no call, no cost
   row, and the survival ladder engages immediately. The stage's output file is
   overwritten with a single `AGENT_CALL_NO_HEADROOM …` marker line, so a caller
   that ends up reading it (every later rung unavailable too) sees the refusal
   rather than a stale answer from an earlier attempt at the same path.

### Cooldowns

A cooldown is evidence about **one vendor's account**, so the key carries both:
`state/quota/cooldown/<vendor>/<account>`, epoch seconds, written by
`bin/agent-call.sh` when a call is classified `account-exhausted` or `auth`, and
by `pool_account_cooldown` (always `claude`) from the hub's Fly reap. The picker
skips that account for `ACCOUNT_COOLDOWN_SECS` (default `MODEL_COOLDOWN_SECS`,
21600) and no other vendor's pick can see it. `default` is a name every vendor
shares, so `cooldown/codex/default` and `cooldown/claude/default` are two
independent files and cooling one says nothing about the other.

A cooldown file left directly under `cooldown/` by an older release is never read
as a cooldown by anything. The first library call that sees one moves it to
`cooldown/.legacy/<account>` and writes one `legacy_cooldown_ignored` row to
`logs/account-routing.log`; nothing has to be cleaned up by hand.

To release an account before its window expires:

```bash
/root/harness/bin/quota-status.sh --clear-cooldown codex default
```

It prints what it did, logs a `cooldown_cleared:<vendor>` routing row and one
`failovers.log` line, and exits 0. When there was nothing to clear it says
`no cooldown for <vendor>/<account>`, exits 1 and logs nothing at all; an
unknown vendor or an invalid account name is exit 2 and touches nothing. It is
the only write
`quota-status.sh` makes, and it touches nothing else — not pins, not leases, not
`state/model-cooldown-<model>-<account>`, which is a different file with a
different meaning (see the ladder section below).

---

## How this interacts with the survival ladder

The ladder itself is unchanged. For a claude-primary stage with routing on:

1. `run_attempt claude` picks account A. Inside, the fable→opus candidate loop
   runs exactly as before — but its cooldown file is now
   `state/model-cooldown-<model>-<account>`, so A running out of fable credits no
   longer sends B straight to opus for six hours. If fable is out on A and opus
   serves, the stage succeeds and **no account cooldown is stamped**: fable
   exhaustion degrades to opus, not to another account.
2. If the attempt still fails it is **classified** (see the next section), and
   an `account-exhausted` or `auth` class stamps A into
   `state/quota/cooldown/<vendor>/A` — the vendor it was called on, so an
   exhausted codex account never refuses a claude pick — and retries on the next
   account with headroom —
   and then the next, until the vendor has no account left (2026-09-16; before
   that it stopped after exactly one retry and descended a rung with healthy
   accounts still on the box). The scanned file is `$OUT` on the claude lane and
   `$OUT.err` on codex, whose `$OUT` on a failure is the events stream plus
   every file the agent read — matching that text would cool an account down
   for a failure that had nothing to do with quota.
3. From there the script is identical to today: Grok tier-2 → configured
   fallback → OpenRouter → Fireworks → DEAD alert.
4. A kill or a budget stop fences the retry off exactly like tier-2 — a killed
   run is never re-bought on another account.
5. A cooled account comes back on its own: the first pick after
   `ACCOUNT_COOLDOWN_SECS` may choose it again, and that call is the probe.

Only the `claude` and `codex` lanes call the picker in this wave. grok,
OpenRouter and Fireworks accounts are accepted by the registry and shown by
`quota-status.sh` (status `unmetered`), but those lanes are not hooked.


---

## Failure classes and recovery (2026-09-16)

the operator: *"if it's stuck for very little it falls back; we need recovery
procedures. Falling all the way to Fireworks is bad but ok as the LAST
resort."*

Before this, `agent-call.sh` read one thing off a failed attempt — the exit code
— and answered every kind of failure the same way: change vendor. A 30-second
503, an account that ran out of weekly quota, an expired login and an agent that
genuinely could not do the job all bought the next rung down, which is how a
stage with a healthy second Claude account ended up answering from an open
model. Now every failed attempt is classified first, and the class picks the
recovery. The class is on the `failovers.log` line
(`class=<class>(<detail>) rc=… acct=…`), so why a stage descended is logged
rather than inferred.

| class | what it looks like | recovery, in order |
|---|---|---|
| `transient` | timeout (rc 124), external kill, 5xx/overloaded, 429 / rate-limit error, network errors | retry the **same runner on the same account**, `LADDER_SAME_RETRIES` times, sleeping `LADDER_BACKOFF_SECS` and doubling. A **timeout** resumes the same session id when the CLI takes `--resume`, and never escalates fable→opus — the model was not the problem |
| `account-exhausted` | usage/weekly/**session** limit, out of credits, spend limit, "hit your … limit" | cool this account down (`state/quota/cooldown/<vendor>/<account>`, so `account-pick.sh` skips it for `ACCOUNT_COOLDOWN_SECS` on THAT vendor only) and retry on the next account of the **same vendor**, until the picker says none is left (rc 76) |
| `auth` | 401/403, unauthorized, on hold, suspended, not logged in | same as above: the credential, not the vendor, is what failed |
| `real-failure` | the vendor answered and the answer failed; also a budget stop; also `rc 79 PROMPT_TOO_LARGE` (an argv-only lane — grok, gemini — refusing a prompt over `AGENT_ARGV_MAX`; nothing was called and nothing was truncated) | no same-vendor retry — descend a rung (the claude lane's own fable→opus retry still happens inside the attempt). On `prompt_too_large` the account is fine, so it is never cooled down |

An external kill keeps its own rule, unchanged: one same-lane retry and no
vendor change at all, because re-buying a killed run somewhere else is pure
cost.

### The descent, and the last resort

Only once the vendor has nothing left to give does the ladder move:

```
claude (every account with headroom)
  -> grok            (tier 2; skipped entirely when LADDER_TIER2_GROK=0)
  -> RUNNER_<STAGE>_FALLBACK
  -> openrouter, anthropic/<stage model>
  -> openrouter, deepseek-v4-flash      \ the LAST RESORT rungs: allowed, never
  -> fireworks (kimi, then deepseek)    / silent — one ALERTS line each
```

Fireworks and deepseek stay allowed — they are the one rung that still answers
when Anthropic itself is the outage — but every descent past the OpenRouter
`anthropic/` slug writes a single lane alert naming the rung and the classes
that got the stage there:

```
LAST RESORT: execute project-3 fell to fireworks after transient account-exhausted
```

Each vendor rung gets the same recovery treatment before the next one is tried,
so a blip on the fallback vendor is not a reason to walk further down either.

### Knobs

| var | default | meaning |
|---|---|---|
| `LADDER_SAME_RETRIES` | `2` | transient retries on the same runner+account before descending. `0` restores the pre-2026-09-16 straight descent |
| `LADDER_BACKOFF_SECS` | `60` | first sleep before a transient retry; doubles each retry. `0` = no sleep (what the tests use) |
| `LADDER_TIER2_GROK` | `1` | `0` removes the Grok rung from the descent entirely |
| `LADDER_EXHAUST_REGEX` | `usage credits\|usage limit\|session limit\|weekly limit\|out of credits\|credit balance\|spend limit\|hit your …limit\|quota exceeded\|limit reached` | the `account-exhausted` class. `ACCOUNT_EXHAUST_REGEX`, the older knob, is **additive** since BH-1090: it is OR'd with this list rather than replacing it, so widening the merge conductor's vocabulary with it cannot silently narrow the ladder's |
| `LADDER_TRANSIENT_REGEX` | `rate_limit_error\|rate limit exceeded\|too many requests\|429\|529\|overloaded\|internal server error\|bad gateway\|service unavailable\|gateway time…\|(http\|status\|code\|error) 5xx\|temporarily unavailable\|timed out\|connection reset/refused/closed\|socket hang up\|network error\|ECONNRESET\|ETIMEDOUT\|EAI_AGAIN` | the `transient` class |
| `LADDER_AUTH_REGEX` | `401\|403\|unauthorized\|forbidden\|authentication_error\|invalid api key\|invalid … token\|on hold\|suspended\|not logged in\|please login\|setup-token` | the `auth` class |

All three regexes are matched case-insensitively and are **deliberately narrow**:
they are the vendors' own error text. A failed agent run echoes back every file
it read, and this repo's own sources talk about rate limits — a loose pattern
cools an account down, or buys two more attempts, for a failure that had nothing
to do with either. `tests/ladder-recovery-test.sh` and case 11 of
`tests/account-routing-test.sh` drive all of this for real against fake CLIs.

---

## Cost attribution

`cost.csv` gains no column. When routing picked a named account and the live
credential fingerprint has no label in `catalog/auth-accounts.json` /
`state/auth-accounts.local.json`, the existing free-text `auth_account` column
carries the account's `ACCOUNT_LABEL`: the picker's `label=` line, else the
registry file's `ACCOUNT_LABEL` (read with `grep`, never sourced). Only an
account with no label is written `acct:<name>`. Whenever the column holds a
label resolved from the name rather than proved by the fingerprint, the row's
note carries `acct=<name>`. This is the same spelling the pool's fp overlay
writes, so a hub row and a pool row for one account agree (BH-3986). One rule,
`cost_row_auth_account` in `bin/lib/cost-row.sh`, serves both `agent-call.sh`
and `claude-cost.sh` (orchestrator turns pass `ORC_ACCOUNT_LABEL`). A real
fingerprint label still wins — the 2026-08-31 rule that attribution is resolved
live, never inferred, is unchanged. To map an account's fingerprint to a proper
label: `CLAUDE_CONFIG_DIR=/root/.claude-operator2 bin/auth-label.sh "<label>" claude`.

The `model` column is the model that served the row (a ladder fallback, the
grok or codex rung's own model, or, on a pre-call refusal, the model the
primary runner's rung would have used). When that is not the model the caller
asked for, the note ends with `requested_model=<asked>`. Rows written before
BH-3986 say `acct:<name>`; `bin/cost-rows-acct-backfill.sh` prints the
human-run SQL that rewrites them (runbook:
`docs/notes/2026-10-03-BH-3986-cost-row-attribution.md`).

---

## Orchestrator turns

Since 2026-09-15 (the operator: "move your turns to the max picker too") each
orchestrator turn asks the picker too — `bin/lib/orc-account.sh`, called by
`bin/orchestrate.sh` right after it reads `env/orchestrator.env`, stage
`orchestrator`, vendor `claude`, the turn's model, pin key `orchestrator`
(sticky while the account has headroom, so the briefing's prompt cache stays
warm). It honours the pick **by name, through the account's setup-token**
(`env/tokens.d/<name>-setup-token.env`), not through the registry file's
`CLAUDE_CONFIG_DIR` login: the orchestrator's memory dir, the session transcript
its cost row is priced from, and `orchestrator-burn.sh` all live under
`/root/.claude`, and a moved config dir would orphan all three. Rows carry the
token's fingerprint label, or `acct:<name>` as the fallback (`COST_ACCT_NAME`,
same rule as agent-call). Every degraded case — routing off, no picker, picker
exit 2, `name=default`, missing or empty token file — keeps the
`orchestrator.env` token; a turn is never refused. The master switch is the
fleet `ACCOUNT_ROUTING`; `ORC_ACCOUNT_ROUTING=0` or
`flags/orc-account-routing-off` turns just the orchestrator off. The turn's
account is logged once per turn in `logs/failovers.log` (`turn account: <name>
(<reason>)`) and by the picker in `logs/account-routing.log`.

## API key projects

A project can pay for Claude with its own Anthropic API key instead of the
fleet's OAuth accounts (BH-9334). Two settings rows say so. `bin/lib/claude-auth.sh`
reads them: `claude_auth_mode <project>` and `runner_lock_for <project>`.

| row | values | no row |
|---|---|---|
| `claude_auth.<project>` | `oauth` or `api-key` (`CLAUDE_AUTH_MODES`) | `oauth` |
| `runner_lock.<project>` | `claude` (`RUNNER_LOCKS`) | no lock |

Both prefixes are protected. The jobs worker accepts a write only with the human
verdict token, and it signs each value into `setting_sigs`. So a write goes
through `bin/protected-setting.sh` on the operator's Mac, the only place that token lives.

The key is the Fly secret `ANTHROPIC_API_KEY_<PROJECT>` (the project name in
upper case, `-` becomes `_`) on the project's Fly app. One key per project. It is
never in the hub env dir, a log or the console D1.

### Onboarding

```
fly secrets set -a <app> ANTHROPIC_API_KEY_<PROJECT>=...
bin/load-project.sh <owner/repo> --project <p> --claude-auth api-key --runner-lock claude --fly-app <app>
```

- `--claude-auth oauth|api-key` writes `claude_auth.<p>`. `oauth` runs no probe.
- `--runner-lock claude` writes `runner_lock.<p>`.
- `--fly-app <app>` is required with `api-key` and refused without it.
- rc 2: a bad flag value, `api-key` with no `--fly-app`, or a project name that
  cannot form the secret name. Nothing is written.
- rc 3: the key probe did not answer 200. Nothing is written.
- rc 1: a row write failed. The output names any claude row already written.

The key probe runs before any write. It is ONE `fly ssh console -a <app>` call
(`bin/lib/vendor/fly-anthropic-probe.sh`). On the machine, a short script reads
the secret from the machine env and sends ONE `GET <anthropic>/v1/models` with the
`x-api-key` header. The key goes to curl on stdin, so it is on no argv, and it
never leaves the machine. The script prints one line, `KEYPROBE <http-code>` or
`KEYPROBE nosecret`. load-project continues only on `200`:

| answer | load-project prints |
|---|---|
| `200` | `key probe: ANTHROPIC_API_KEY_<P> on <app> answered 200` |
| `nosecret` | `REFUSED: no secret ANTHROPIC_API_KEY_<P> on Fly app <app> (fly secrets set ...)` |
| `401` | `REFUSED: the key probe answered 401: Anthropic refused ANTHROPIC_API_KEY_<P> (invalid key)` |
| `403` | `REFUSED: the key probe answered 403: the key has no access (disabled key or org)` |
| other code | `REFUSED: the key probe answered <code>; the key is not proven, re-run` |
| no marker, ssh error, timeout | `REFUSED: could not run the key probe on Fly app <app> (...)` |

The timeouts are the lib knobs `load-project-key-probe`:
`LOAD_PROJECT_KEY_PROBE_TIMEOUT_S` (curl, default 30) and
`LOAD_PROJECT_KEY_PROBE_SSH_TIMEOUT_S` (the whole ssh call, default 120). A value
outside the registry min/max is refused, never clamped.

The rows are written `runner_lock.<p>` first and `claude_auth.<p>` last, so a
failed write never leaves a project billed by key without its lock. To change a
row later, run `bin/protected-setting.sh claude_auth.<p> oauth "<why>"`.

Claude Code precedence (parent #9334): `ANTHROPIC_API_KEY` outranks
`CLAUDE_CODE_OAUTH_TOKEN`, and a managed `forceLoginMethod` or
`forceLoginOrgUUID` setting blocks the key.

The subscription meters skip an api-key project (BH-9719, `bin/lib/meter-skip.sh`):

- `bin/account-capacity.sh claude <p>` answers `unlimited (...)` for it and
  reads no quota. `bin/concurrency-apply.sh` passes each pool project, so the
  shared account count does not cap that project's build rule. One line per
  project per UTC day goes to `logs/account-capacity.log`.
- `bin/extra-usage-track.sh` polls nothing on a box with only the fallback login
  when every project on the box is `api-key`. It writes no `status=no-login`
  row and raises no `EXTRA-USAGE METER DOWN`. One line per UTC day goes to
  `logs/agent-rules.log`.

The spend brake of such a project is `cost_ceiling.<p>` (docs/COST.md, "API key
projects").

Status: the rows, the worker guard, the reader and these onboarding flags exist.
The runtime path (the env bundle, the pool-lease skip, the own-account pin, the
billing mode and the runner lock at build time) lands with #9676 and #9675. Until
then a row changes no build.

## Pool machines (Fly)

### The problem

`bin/fly-envbundle.sh` builds one env bundle per launch and puts exactly one
`CLAUDE_CODE_OAUTH_TOKEN` in it: the owning box's project-6 setup-token. Every
machine in a project's pool got that same token. So a 20-machine burst was 20
heavy sessions on ONE account (`fly/account-capacity.conf` says the useful
ceiling is about 4), and every cost row those machines pushed to D1 carried the
project-6 fingerprint, so per-account spend on the console was one blob.

### The mechanism

Same seam, and deliberately the same shape, as the per-machine GitHub App token
swap that already runs one line earlier in `bin/fly-pool.sh`:

1. `fly-envbundle.sh` writes the bundle with the box's own values. It swaps
   nothing; the whitelist is unchanged.
2. `spawn_one` calls
   `pool_account_lease <project> <ticket-key> <bundle-global.env> <machine-id>`.
3. That **replaces** the bundle's `CLAUDE_CODE_OAUTH_TOKEN=` line with the leased
   account's token from `env/tokens.d`. Replaced, never appended: `set -a;
   . global.env` uses the LAST assignment, so an append would silently keep the
   project-6 token under a lease claiming otherwise.
4. It writes `state/quota/leases/<account>/<machine-id>`, appends a
   `pool-execute` row to `logs/account-routing.log`, and prints
   `name=… reason=… label=… leases=… five_h=…` for the caller to log.
5. It drops a one-entry `auth-accounts.local.json` (`{fingerprint: label}`)
   beside the bundle, which `fly-pool.sh` pushes to the machine's
   `/data/harness/state/`. That is what makes the machine's own cost rows come
   back labelled `maxN@example.com` — see [Cost attribution](#cost-attribution).
6. The account NAME (never the token) is recorded as `auth_account` on the
   machine json, so the reap and the console can attribute the build.

Only accounts that have a `tokens.d` file are eligible. A login-only registry
entry (`CLAUDE_CONFIG_DIR`, no token file) can pay for a call on the box itself
but cannot be handed to a Fly machine.

### Lease accounting, and why the hub's picker is not enough

`bin/account-pick.sh` ranks on a meter `quota-poll.sh` refreshes every 10
minutes. That is right for a lane that makes one call and wrong for a pool: a
tick launches ten machines inside a minute, every one reads the SAME stale meter,
and every one picks the same lowest-5h account. So each pick writes a lease file
and the rank is:

```
5h pct + live_leases * ACCOUNT_LEASE_WEIGHT_PCT
```

Registry priority is the primary key (lowest `ACCOUNT_PRIORITY` number wins
outright); this score orders the accounts inside a priority band, and the name
breaks a remaining tie so two readers of the same state answer the same thing.
The weight is measured, not a
feeling: one Fable review-sized call is about 3.5% of a 5-hour window (measured
2026-09-14) and a build is several stages, so `8` is roughly "what this machine
is about to spend", in the unit the meter already reports.

An account is **skipped** when it is at its lease cap, at `ACCOUNT_5H_MAX` or
`ACCOUNT_WEEK_MAX`, in cooldown (`state/quota/cooldown/claude/<account>` — this
pool leases claude accounts and nothing else), or has no fresh meter.

> **A stopped poller is skipped here, which INVERTS `account-pick.sh`'s fail-open
> rule on purpose.** There, "no numbers" counts as available, or a broken poller
> takes the whole fleet down. Here the fallback is the project-6 token the pool
> already ships, so an account whose meter has gone stale or missing costs nothing
> to skip and could cost a 40-minute build to guess at. An `unreadable` reading is
> **not that case** — that is the poller answering, not the poller stopping, and
> it ranks with an empty meter. Both pickers read the file through one classifier,
> `account_reading_class`; see `docs/BUILD-CONCURRENCY.md`.

### Fail open, always

**A launch is never refused for lack of an account.** Unarmed, saturated, token
unreadable, rewrite failed — every path returns 0, answers `name=default`, and
ships the bundle with exactly the bytes it has today. When nothing ranked, the
`reason=` in `logs/account-routing.log` names the class that did it:
`all_capped`, `all_stale`, `all_cooling` or `all_leased`. `default_saturated` is
left for a MIXED set of causes, and for the defensive case where there was no
candidate account at all.

### Releasing

A lease is released when the machine is destroyed, when it is reaped, and when a
spawn fails after the lease was taken. `pool_account_prune` also runs once per
tick and drops every lease older than `ACCOUNT_LEASE_TTL_SECS`, so a machine lost
between two ticks cannot pin an account for ever. An account that merely *looks*
busy is an account this picker stops using.

### No reuse of a default-token machine

The pool hands a reaped machine the next queued job instead of spawning a new
one when the queue is non-empty (`reused MID for KEY` in `logs/fly-pool.log`).
The account rides with the machine, so a machine that booted on the default
project-6 token would keep spending project-6 on every job it is handed. Since
2026-09-15 (the operator: "no reuse") the reap destroys such a machine while routing is
armed (`pool_account_armed`), logging `shipped the default token and account
routing is armed — destroying instead of reusing`; the queued job spawns fresh
on the next tick and takes a lease. Machines that carry a lease are still
reused, and so is every machine when routing is not armed.
`POOL_REUSE_DEFAULT_TOKEN=1` in `env/global.env` restores reuse for a rollback.

### Refusal feedback

When the reap sees usage-limit text in a machine's `failovers.log` — matched with
the same `ACCOUNT_EXHAUST_REGEX` `agent-call.sh` classifies with — it writes that
account's cooldown marker **on the hub** (`state/quota/cooldown/claude/<account>`),
and the next launches skip it. The hub
has to do this because the machine cannot: `agent-call.sh`'s own cooldown is
fenced on `ACCOUNT_ROUTING` + `ACCT_NAME`, and neither rides the bundle, so a
pool machine does not know it is on a named account at all.

### The kill switch

Either of these turns the whole thing off, and the pool goes back to shipping the
project-6 token to every machine:

```bash
echo 'POOL_ACCOUNT_ROUTING=0' >> /root/harness/env/global.env
# or, without editing env:
touch /root/harness/flags/pool-account-routing-off
```

### Adding an eighth account

Two steps, both on the hub. Register it as in
[Adding an account to a box](#adding-an-account-to-a-box), then give it a
shippable token:

```bash
# 1. the registry entry (a LOGIN — this alone cannot be handed to a Fly machine)
vi /root/harness/env/accounts.d/max8.env      # ACCOUNT_VENDOR=claude, ACCOUNT_PRIORITY=50,
                                              # ACCOUNT_LABEL=max8@example.com,
                                              # CLAUDE_CONFIG_DIR=/root/.claude-max8
chmod 600 /root/harness/env/accounts.d/max8.env

# 2. the shippable 1-year setup token, ONE line: CLAUDE_CODE_OAUTH_TOKEN=...
CLAUDE_CONFIG_DIR=/root/.claude-max8 claude setup-token
vi /root/harness/env/tokens.d/max8-setup-token.env
chmod 600 /root/harness/env/tokens.d/max8-setup-token.env
```

Nothing else. The next pool tick ranks it with the rest. Skip step 2 and the
account is usable on the box but never leased to a Fly machine.

### Reading the state

```bash
bin/quota-status.sh                      # the table, now with a live-lease line per account
bin/quota-status.sh --json | jq '.[] | {account, leases, five_hour}'
ls state/quota/leases/*/                 # who is holding what, right now
cat state/quota/leases/max3/<machine-id> # project, ticket_key, started_at
grep pool-execute logs/account-routing.log | tail -20
grep 'gets account' logs/fly-pool-<project>.log | tail
```

The routing log is `ts,project,stage,model,account,reason` — account NAMES and
reasons only, never a token.

---

## Environment reference

All of these live in `env/global.env`. Every one has a documented default; none
is a bare constant in the code.

| var | default | meaning |
|---|---|---|
| `ACCOUNT_ROUTING` | unset (off) | `1` turns the `agent-call.sh` hook on |
| `ACCOUNT_5H_MAX` | `85` | drop an account when its 5-hour pct is ≥ this |
| `ACCOUNT_WEEK_MAX` | `90` | drop when the 7-day pct is ≥ this. **Not applied at all when the account is billing extra usage** (BH-1456) |
| `ACCOUNT_EXTRA_MAX` | `97` | drop when `extra_usage.pct` is ≥ this — the ceiling on the OVERAGE meter, which is what bounds an account that is past its subscription windows |
| `ACCOUNT_OVERAGE_COOLDOWN_SECS` | `900` | how long an account that refused us *while in overage* is skipped, instead of `ACCOUNT_COOLDOWN_SECS`. Written as a backdated stamp, so every cooldown reader keeps its single window |
| `ACCOUNT_DEFAULT_LABEL` | unset | which `extra-usage-track` login label the implicit `default` account's meter is derived from (`state/extra-usage-last-<label>.json`). Unset = the box login's plain snapshot. **Hub: `project-6-account`**, because the hub's stored login and its `default` token are different accounts |
| `ACCOUNT_MODEL_MAX` | `90` | drop when the per-model pct is ≥ this (only if the endpoint reports that family) |
| `ACCOUNT_POLL_STALE_SECS` | `10800` | a poll older than this counts as "headroom unknown" = available |
| `ACCOUNT_COOLDOWN_SECS` | `${MODEL_COOLDOWN_SECS:-21600}` | how long an exhausted account is skipped |
| `ACCOUNT_EXHAUST_REGEX` | unset (the pool reap's own fallback list is `usage credits\|usage limit\|too many requests\|rate_limit_error\|HTTP 429`) | what counts as "this account is exhausted" (case-insensitive). Since BH-1090 it is **additive everywhere it is read as a classifier**: `bin/agent-call.sh`'s `LADDER_EXHAUST_REGEX`, `bin/lib/orc-account.sh`'s copy of it (the turn ladder) and the merge conductor's `MC_LANE_EXHAUST_RE` all OR it with their built-in list, so one knob means one thing on a box. `bin/fly-pool.sh`'s reap grep still uses it as a whole pattern with its own default. Deliberately narrow — a bare `rate limit` also matches source files the agent merely read back into its output |
| `ACCOUNT_DEFAULT_PRIORITY` | `100` | the implicit account's priority |
| `LADDER_SAME_RETRIES` | `2` | transient retries on the same runner+account before the ladder descends (see "Failure classes and recovery") |
| `LADDER_BACKOFF_SECS` | `60` | first transient-retry sleep, doubling |
| `LADDER_TIER2_GROK` | `1` | `0` removes the Grok rung from the descent |
| `ACCOUNT_POLL_MIN_SECS` | `3000` | `quota-poll.sh` skips an account polled more recently than this |
| `ACCOUNT_POLL_STAGGER_SECS` | `90` | sleep between two accounts that actually call out |
| `ACCOUNT_PIN_TTL_SECS` | `604800` | pins older than this are swept |
| `ACCOUNTS_DIR` | `$HARNESS/env/accounts.d` | registry location (tests point it at a fixture) |
| `POOL_ACCOUNT_ROUTING` | `1` (**on**) | `0` turns Fly pool leasing off. Independent of `ACCOUNT_ROUTING` by design |
| `ACCOUNT_LEASE_WEIGHT_PCT` | `8` | a live pool lease is worth this many 5h-percent in the pool rank |
| `ACCOUNT_LEASE_TTL_SECS` | `10800` | a lease older than this is stale: not counted, then pruned |
| `ACCOUNT_POOL_MAX_LEASES` | `fly/account-capacity.conf`'s claude sessions-per-account (`4`) | per-account lease cap. `0` = no cap |
| `POOL_TOKENS_DIR` | `$HARNESS/env/tokens.d` | shippable setup tokens (tests point it at a fixture) |
| `OAUTH_USAGE_FETCH` | `bin/lib/oauth-usage-fetch.py` | the fetcher; tests substitute a stub |

Per-account fields live in the registry file itself: `ACCOUNT_NAME`,
`ACCOUNT_VENDOR`, `ACCOUNT_ENABLED`, `ACCOUNT_PRIORITY`, `ACCOUNT_MODELS`,
`ACCOUNT_LABEL`, plus the credential. See the example file.

---

## Secrets

Tokens live only in `env/accounts.d/*.env` (0600, gitignored) and in the config
dirs the CLIs own. They reach `bin/lib/oauth-usage-fetch.py` through the
environment, never argv. `state/quota/*.json` holds numbers and reset timestamps
only; `logs/account-routing.log` holds account NAMES and reasons only. The
account name is regex-restricted so it can never carry a comma into a CSV.

The **shippable** pool tokens are the one credential that deliberately leaves the
hub, and they live in `env/tokens.d/*.env` (0600, gitignored, hub only) rather
than in `accounts.d` precisely so that "a registry entry" and "a credential a Fly
machine can be handed" stay two different things. A token is read into a shell
variable, written into the bundle, and cleared. It is never printed, never
logged, never passed as an argument, and reaches no file except the bundle
itself. What lands in the machine json, the lease file and the routing log is the
account NAME; what lands in the pushed overlay is the account LABEL and a
12-hex fingerprint. Neither is a secret, and both are what the console needs to
attribute spend.

## What this wave deliberately does not do

Console UI, the mobile app, the Telegram beat, cross-box balancing, automatic
account creation, hooking the grok/OpenRouter/Fireworks lanes, reading codex
quota (no source exists), and any change to which model a stage uses.

The pool wave (2026-09-14) additionally does not touch: the persistent per-project
builder machines behind `bin/fly-dispatch.sh` (a long-lived machine with no
machine-scoped lease to release, so the TTL model does not fit it), and the
project-5 / project-6 / project-9 / small boxes, which stay on the project-6 token
by the operator's instruction and would be a separate rotation change.

## Own-account projects (BH-1657)

A project that owns its own Claude account is pinned to it by a **label**, never a token:

- Source of truth: settings row `account.<project>` (value = label, e.g. `own:project-3`), read by
  `account_for_project` in `bin/lib/project-account.sh` through lane-gate's settings fetch (60s cache).
- Fallback only when this box has no settings answer at all: env `ACCOUNT_OWN_PROJECTS="project-3=own:project-3,..."`.
  Unset in both = shared pool, unchanged.
- Secret stays on disk: `<env dir>/accounts.d/<label>.env` (env dir from `harness_env_dir`, normally `/etc/harness/env`) (`CLAUDE_CODE_OAUTH_TOKEN=`). `project_account_exports`
  prints the export for an eval and never logs it; a missing file is rc 3.
- Labels containing `/`, `..` or a leading `.` are refused. Project match is exact.
- Pool lease (`pool_account_lease`): a pinned project takes no lease and no DB claim; the bundle's token is
  replaced with the label's and the fp overlay names the label (`reason=own_account`). This happens even when
  pool routing is unarmed. Token file missing = fail closed: the token line is stripped (`reason=own_account_unavailable`),
  never shipped on project-6.
- `shared` as the row's value is the explicit unpin (`label= source=db`): the worker refuses an
  empty value and has no DELETE, so this is how the console puts a project back on the pool.
- agent-call (`bin/agent-call.sh`, every hub lane and build stage reaches Claude through it): for a
  pinned project's **claude** rung the picker is never asked, whatever `ACCOUNT_ROUTING` says:
  1. token file present: the call runs on it, with a box `ANTHROPIC_API_KEY` unset in the child;
  2. no file, but the live token's fp maps to the label or one of its aliases in `catalog/account-aliases.json`
     (a Fly builder's bundle, or the owning box whose overlay names its own token `claude:<x>-dedicated`):
     runs on the live token. An unmapped fp (`unknown`) never matches; no alias file = exact label only;
  3. otherwise it fails closed: nothing is called, rc 76, failovers.log gets
     `pinned account <label> for <project> has no token on this box, not falling back to shared accounts, descending`.
  account-routing.log records `pinned` / `pinned_unavailable`, and `<outfile>.account` names the label.
  Codex rungs are not pinned and keep their routing.
- A `pinned_unavailable` refusal raises ONE warn lane-alert `account-pin-<box>-<project>` per box+project per
  `ACCOUNT_PIN_ALERT_WINDOW_S` (default 21600, settings row `lib.project-account.account_pin_alert_window_s`),
  resolved by the next pinned call that works. `bin/claude-auth-check.sh` (hourly, hub) runs
  `bin/account-pin-probe.sh --alert` for every pinned project on the hub and, over ssh, on each owning box;
  an unresolvable pin alerts from the box that cannot resolve it, and an unreachable probe is only a
  `could-not-probe` line in `logs/account-pin-probe.log` (BH-3559).
- Ladder: a pinned account that refuses (quota, credits, auth) never rotates. No cooldown stamp, no
  second claude attempt, one `pinned account <label> refused (<class>), no fallback to shared claude
  accounts, descending a rung` line, and the stage goes to the non-claude rungs.
- Cost rows: `auth_account` is the label verbatim when the live fp is unmapped (a mapped fp label wins).
- Worker `PUT /api/settings` refuses an `account.<project>` value that is not a label or `shared`
  (anything starting `sk-`, `/`, `..`, over 64) with a 400 that does not echo the value.
- Mission Control: `/settings`, hub tab, PROJECT ACCOUNTS lists every fleet project (plus any pinned
  project no longer in the fleet) with its label or "shared pool"; SET goes through the in-app confirm.
- `bin/quota-status.sh` (text mode) ends with an OWN-ACCOUNT PROJECTS block:
  `<project> <label> <db|env> <fp8|missing>`, fp8 of the token file, never the token. `--json` is unchanged.
- Still owed (operator step, not code): write the four `account.<project>` rows and remove the
  hand-configured `#OWN-ACCOUNT-2026-09-23` env lines once `GET /api/settings` shows them.
