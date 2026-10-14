# Operator setup

<!-- changes:begin -->
> **What changed since this doc was written lives in [`docs/notes/`](notes/INDEX.md)**, one dated note per change. Add a note there instead of appending here; guardrail `doc-monolith-edit` checks it once it is armed in CI (the adoption PR that `guardrails/README.md` prescribes; not yet opened).
<!-- changes:end -->

How to run this harness. Two paths:

- **Path A — join an existing fleet.** Someone already runs the control plane
  and gives you a URL and a shared secret. You stand up a box and register a
  project. This is the short path.
- **Path B — run your own.** You deploy the control plane too. Longer, and one
  piece of it is not in this repository — see
  [What Path B is missing](#what-path-b-is-missing) before you start, because it
  determines whether Path B is possible for you today.

Everything here is read from the code and cited, so you can check a claim rather
than trust it. Where a step could not be verified by running it, the text says
so.

---

## What you are standing up

```
                 ┌─────────────────────────────┐
   your app ◄────┤  watcher box (one per        │
   board API     │  project, or shared)         │
                 │  cron → triage → build → PR  │
                 └───────────┬─────────────────┘
                             │
                 ┌───────────▼─────────────────┐
                 │  jobs worker + D1            │  claims, phases, artifacts,
                 │  (Cloudflare)                │  queues, cost rows
                 └───────────┬─────────────────┘
                             │
   ┌─────────────┐  ┌────────▼────────┐  ┌──────────────────┐
   │  watchdog   │  │  hub box        │  │  console          │
   │  worker     │  │  cross-project  │  │  (separate repo)  │
   │  (pages you)│  │  lanes, merges  │  │  Telegram + UI    │
   └─────────────┘  └─────────────────┘  └──────────────────┘
```

A **watcher box** is a Debian VM. It holds one project's secrets, runs that
project's cron lanes, and builds. The **hub** is a watcher box that also runs the
cross-project lanes. The **jobs worker** is a Cloudflare Worker over a D1
database — the coordination plane. The **watchdog** is a second, deliberately
separate Worker whose only job is to notice when everything else has gone quiet.

You do not need Fly, and you do not need more than one box.

---

## Prerequisites

### Accounts

Three are required. The rest are optional and the text says what you lose.

| What | Required | Notes |
|---|---|---|
| **Anthropic** | yes | `claude setup-token`, run on a machine **with a browser**, prints `CLAUDE_CODE_OAUTH_TOKEN`. It is the only *model* credential you need |
| **GitHub** | yes | A fine-grained PAT. Scopes below — the list is longer than you would guess |
| **Cloudflare** | yes for Path B | Workers, D1 **and** KV, plus scheduled triggers. Free tier covers all four |
| **Telegram** | recommended | A bot from BotFather. Without it the watchdog has nowhere to page, and you will not know the fleet died |
| **Slack** | optional | A Slack app installed from the console's `slack/app-manifest.yml`. A second chat front door, nothing more — the watchdog stays Telegram-only on purpose. See [Slack (optional)](#slack-optional) |
| **xAI / OpenRouter / Fireworks** | optional | Fallback lanes. Without them a Claude outage stops the box rather than degrading |
| **Fly.io** | optional | Ephemeral build machines. Skip it and builds run on the watcher box, which is the original path |

**GitHub PAT scopes.** Two repositories, and the scope list differs:

**Make it one PAT covering both repositories**, not two. `gh` stores one token
per host, and the box needs to reach both.

| Repo | Scopes | Why |
|---|---|---|
| The project you are building | Contents RW, Pull requests RW, **Issues RW**, Metadata R | Issues RW is not optional on the GitHub-Issues lane: the whole board is `gh issue list/view/comment/close`, and onboarding creates the `ai-build` label |
| **Your fork of this harness** | Contents RW, Metadata R | `bin/load-project.sh` commits the registry row and pushes it, and every box fetches from that fork |

You need the fork. `bin/harness-sync.sh` fetches an origin on every build and
treats a failed fetch as *unknown*, never as fresh
(`bin/harness-sync.sh:14-19`), so a box with no reachable origin never passes
the freshness gate. Fork this repository first; everything below assumes your
fork is `origin`.

**Getting the Telegram chat id.** BotFather gives you a token, never a chat id.
Message your new bot once, then:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
```

**Cloudflare auth on a headless box.** `wrangler login` is an interactive
browser flow. On a VM, use a token instead — Workers Scripts Edit, D1 Edit, KV
Storage Edit:

```bash
export CLOUDFLARE_API_TOKEN='<token>'
```

**Which Cloudflare token lives where (BH-3905).** Worker deploys are moving off
the hub into the `Deploy workers` GitHub workflow, which deploys with the
`cloudflare-deploy` GitHub environment's `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` secrets. On the hub, two files under the env dir:

- `cloudflare.env` — once runbook step R3 has run, this holds a token with
  **Cloudflare Pages: Read only**. Its readers are `bin/pipeline-health.sh`'s
  console drift check and `bin/cf-token-scope-probe.sh`. Until R3 has run it
  still holds the broad token above, and `bin/harness-sync.sh` deploys from it.
- `cloudflare-deploy.env` — rollback only, absent in steady state: it is the
  file the hub deploys from when CI deploys are rolled back.

`bin/cf-token-scope-probe.sh` proves the narrowed token cannot write Workers
secrets or D1 (exit 0 = all five probes pass). The runbook (R1-R6), the
rollback and what this does not cover are in
[`docs/notes/2026-10-03-BH-3905-deploy-off-hub.md`](notes/2026-10-03-BH-3905-deploy-off-hub.md).

### On the box

Debian or Ubuntu, root. `bin/bootstrap-machine.sh` checks for four things and
fails fast without them, so install them first:

```bash
apt-get update && apt-get install -y git curl jq ca-certificates
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
npm i -g @anthropic-ai/claude-code

# gh
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
apt-get update && apt-get install -y gh
printf '%s' '<your PAT>' | gh auth login --with-token && gh auth status
gh auth setup-git     # so plain `git push` has a credential — onboarding pushes
```

`jq` is not optional: the runtime parses every board response with it.

`claude` must also be authenticated. `claude setup-token` needs a browser, so
run it on your laptop and carry the token to the box in `env/global.env`.

`bin/bootstrap-machine.sh` installs the rest — `unzip`, `rsync`, `cron` plus a
supervisord unit so the daemon survives a restart, `bun`, `semgrep` in its own
venv, Playwright with chromium, and `codegraph` (`bin/bootstrap-machine.sh:34-73`).
It does **not** install `claude`, authenticate `gh`, or create your env files.
Those are preconditions, and it checks for them (`:26,30`). It does *append* to
`global.env`: fourteen `RUNNER_<STAGE>_FALLBACK` lines, if they are absent
(`:95-97`). So the file is machine-touched even though you own it.

---

## Step 0: the code, and the secret everything shares

**There are two trees, and this is the single easiest thing to get wrong.**

| Path | What it is |
|---|---|
| `/root/harness-checkout` | The **git checkout**. Has an origin, gets fetched, is what "is this box up to date" means |
| `/root/harness` | The **live copy**. `bin/` and `prompts/` rsynced out of the checkout; also holds `env/`, `logs/`, `state/`, `flags/`, `builds/` |

Clone to the checkout, then let the sync produce the live copy:

```bash
git clone https://github.com/<you>/cromford.git /root/harness-checkout
mkdir -p /root/harness/env && chmod 700 /root/harness/env
```

Override the checkout path with `HARNESS_CHECKOUT` if you must
(`bin/harness-sync.sh:30`). Do not skip it: without a git checkout at that path,
`harness-sync.sh` exits **20 — UNKNOWN**, never "fresh" (`:36`). That is also
why the "dirty checkout returns 30" behaviour described later can only fire if
this split exists; clone straight to `/root/harness` and the freshness gate has
nothing to look at.

The first sync is the thing that populates the live copy, and it happens during
step 7 — `bin/bootstrap-machine.sh` runs from the checkout. Until then, invoke
scripts as `/root/harness-checkout/bin/...`; afterwards, `/root/harness/bin/...`
is the deployed copy and the one cron runs.

Generate the shared bearer now, because the very next command uses it. It is one
secret, held by every box and every Worker:

```bash
export HARNESS_SECRET="$(openssl rand -hex 32)"
```

**Clear the example registry before you start.** The repo ships placeholder rows
in `fleet.conf` and matching placeholder crontabs in `cron/`. Left in place,
each row gets a triage lane firing every ten minutes at an app that does not
exist — and if you delete the rows but keep the crontabs, the load-bearing
`tests/cron-fleet-parity-test.sh` fails, correctly, because the registry and the
committed crontabs no longer agree.

```bash
: > fleet.conf             # keep the comment header if you want the column docs
: > vercel.conf            # same: upstream's Vercel project ids, useless to you
rm -f cron/*.cron          # including cron/hub.cron: it is the upstream fleet's
```

`vercel.conf` maps a project to the Vercel team and project that serve its
production domain, and `bin/harness-sync.sh` distributes it alongside
`fleet.conf`. It is only read by the deploy-snapshot lane on the hub, so an
empty one costs you that lane and nothing else. Populate it if and when you want
deploy verification.

**Expect the suite to go red after this, and know which parts.** Seven suites
read `cron/` and assert it against the registry, so emptying both is coherent
but emptying one is not:

| Suite | What it asserts about `cron/` |
|---|---|
| `tests/cron-fleet-parity-test.sh` | Every registry row has a rendered crontab, and vice versa |
| `tests/watchdog-boxes-test.sh` | The worker's box list, `worker/watchdog/src/boxes.json`, and the committed ping lines are the same set, both ways (`:64-71`) |
| `tests/lane-liveness-test.sh` | Every declared lane has a cron line that ticks it |
| `tests/overage-per-box-test.sh` | Each box polling its meter is collected by the rollup |
| `tests/cost-rows-db-test.sh` | Each box pushes its cost rows |
| `tests/account-routing-test.sh` | The hourly quota poll exists per box |
| `tests/postmerge-qa-test.sh` | The production QA lane is scheduled |

The parity suite goes green as soon as your own registry row and its rendered
`cron/<box-id>.cron` are committed, which `bin/load-project.sh` does for you.

**The other six read the same render, so make your lines committed sources.**
Since BH-1247 every `cron/<box-id>.cron` is git-ignored and rendered by
`bin/render-cron.sh` from committed sources: `cron/lanes/<NNN>-<id>.cron` plus
the lane's `.boxes` membership in `catalog/lanes.d/<id>.json` (composed into
`catalog/lanes.json`), and this box's own lines in
`cron/boxes/<box-id>.d/<NNN>-<slug>.cron`. The suites assert against that
render, so a line that exists only in the live crontab is invisible to them.
To turn them green, add every crontab line this guide asks for as a committed
source, not as a live-crontab edit: a box-only line as a fragment under
`cron/boxes/<box-id>.d/`, a lane the fleet shares as a `cron/lanes/` file plus
its `catalog/lanes.d/<id>.json` membership. A box id that no registry lane lists
in `.boxes` does not render at all (`render-cron.sh: <box-id>: no registry lane
lists this box`), so a new box goes into the `.boxes` of the lanes it runs
first. Then install the render:

```bash
bin/render-crontab.sh <box-id> | crontab -
```

That is the one install path, so the suites and the box read the same lines.

`env/` is already in `.gitignore` (`.gitignore:2`), so the secrets you are about
to write cannot be committed by accident. Confirm it yourself once, because you
will be pushing from this checkout:

```bash
git check-ignore -v env/global.env     # must print a match
```

## Path B, step 1: the jobs worker

The coordination plane. Skip to [step 4](#step-4-the-registry) if you are on
Path A — you will be given `CONSOLE_URL`, `JOBS_URL` and `HARNESS_SECRET`.

```bash
cd /root/harness-checkout/worker/jobs
npm install                         # there is a package.json here but no lockfile
npx wrangler d1 create <your>-jobs-db
# put the returned database_id and your account_id into wrangler.jsonc
npx wrangler d1 execute <your>-jobs-db --remote --file=./schema.sql
printf '%s' "$HARNESS_SECRET" | npx wrangler secret put HARNESS_SECRET
npx wrangler deploy
```

**`--remote` is load-bearing.** Without it wrangler writes a local dev database
and reports success (`skills/console-deploy/SKILL.md:99-102`).

> Verified from `worker/jobs/README.md:21-25` and `skills/console-deploy/SKILL.md:92-96`.
> The `d1 create` line is **not** in the repo — the committed config points at a
> database that already exists — so it is written here from Cloudflare's
> documented command and is the one step in this section nobody has run from a
> blank account. Expect to edit `wrangler.jsonc` after it.
>
> **The committed `wrangler.jsonc` in both workers carries the upstream fleet's
> account and database ids.** Edit `name`, `account_id` and the binding ids
> before your first `wrangler deploy`, or you will deploy a worker named after
> someone else's into your own account and wonder why the ids do not resolve.

Re-applying `schema.sql` **is** the migration mechanism: every statement is
`IF NOT EXISTS` and the file is additive-only, forever
(`worker/jobs/schema.sql:4-8`). Two later column additions are handled at
runtime by reading `PRAGMA table_info` (`worker/jobs/README.md:34-40`).

`HARNESS_SECRET` is the only secret, and it is a plain bearer shared by every
box. **There is no unauthenticated route**, not even a health check — the auth
test precedes every path (`bearerOk` in `worker/jobs/src/lib/http.js`, called by
`fetch` in `worker/jobs/src/index.js` before the gated route table).

What lives in there, 26 tables (`worker/jobs/schema.sql`):

| Group | Tables | What it is |
|---|---|---|
| Work | `jobs`, `job_claims`, `job_phases`, `stage_events`, `job_heartbeats` | One row per claimed unit of work, its phase attempts, and its liveness |
| Output | `job_artifacts`, `job_transcripts`, `phase_contracts` | The plan file, PR url, verdict, merge sha; the scrubbed conversation behind an attempt |
| Queues | `build_queue`, `merge_queue` | Work waiting before a claim, and PRs waiting to land. Claims are compare-and-swap so two dispatchers cannot take the same row (`src/index.js:2474`) |
| Money | `cost_rows`, `pr_costs`, `burn_days`, `budget_catalog`, `budget_cap_flags`, `extra_usage_snapshots` | Every priced call, rolled up per PR and per day |
| Policy | `concurrency_rules`, `retry_policies`, `pause_flags`, `review_gate`, `review_gate_thresholds` | What may run at once, what retries, what is paused, when review tightens |
| Fleet | `lanes`, `cli_versions`, `box_status`, `ledgers` | Lane liveness, per-box CLI versions, the done-ledger |
| Outcomes | `outcome_metrics` | Reverted, reopened, merged-then-red, and repair rounds per PR — what feeds the review gate |

**No secrets in any row, `meta` included** (`schema.sql:10`).

`wrangler deploy` prints the worker's URL. **That is your `JOBS_URL`** — export
it now, and put it in `env/global.env` at step 6:

```bash
export JOBS_URL='https://<the url wrangler printed>'
```

> **Do not run `jobs-client.sh catalog-sync` yet**, even though it belongs to
> this worker. `JOBS_URL` has a default, and the default is the upstream fleet's
> worker (`bin/jobs-client.sh:19`). Run any client command before `env/global.env`
> exists and you push your data to a stranger's coordination plane using the
> secret you just generated. It is the last step in [step 6](#step-6-the-env-files).

## Path B, step 2: the watchdog worker

A second Worker, on purpose. If the thing that notices silence shares a
deployment with the thing that goes silent, it notices nothing.

```bash
export WATCHDOG_SECRET="$(openssl rand -hex 32)"   # NOT the same as HARNESS_SECRET
export TELEGRAM_BOT_TOKEN='<from BotFather>'
export TELEGRAM_CHAT_ID='<from the getUpdates call above>'

cd /root/harness-checkout/worker/watchdog
# No package.json here — npx fetches wrangler on demand. Pin it if you care
# which version deploys: npx wrangler@3 ...
npx wrangler kv namespace create harness-watchdog-kv   # put the id in wrangler.jsonc
printf '%s' "$TELEGRAM_BOT_TOKEN" | npx wrangler secret put TELEGRAM_BOT_TOKEN
printf '%s' "$TELEGRAM_CHAT_ID"   | npx wrangler secret put TELEGRAM_CHAT_ID
printf '%s' "$WATCHDOG_SECRET"    | npx wrangler secret put HARNESS_SECRET
npx wrangler deploy
```

**Set those three variables before you paste that block.** `wrangler secret put`
reading an unset variable stores an **empty** secret and exits 0 — the worker
deploys green, and the alarm is dead. This is the one component whose silent
failure you cannot detect by watching the pipeline, because the pipeline is what
it watches.

> The secret names are read from `worker/watchdog/wrangler.jsonc:16-17`; the KV
> create line is written from Cloudflare's documentation for the same reason as
> above. The account id, KV id and cron trigger in the committed
> `wrangler.jsonc` are the upstream fleet's and must be replaced.

It runs every 5 minutes (`wrangler.jsonc:13`) and pages on: a box whose ping is
over 15 minutes old; a hub that is pinging but has pushed no fleet status for 45
minutes; a wedged build lane; stale owed tickets; and a hub silent for 30
minutes (`worker/watchdog/src/index.js:207-290`). Re-alerts are damped to once
an hour, and recovery is announced.

**Its auth is a query parameter, not a header** — `?s=<secret>`
(`src/index.js:51-53`). A deliberate difference from the jobs worker, and it
will confuse you once.

**Why the watchdog gets its own secret.** Its binding is still called
`HARNESS_SECRET` — that is the variable name in the Worker — but the *value*
must differ from the fleet's. Each box sends the contents of
`env/.watchdog-secret` if that file exists, falling back to the shared secret
(`bin/watchdog-ping.sh:32-35`), so giving it a distinct value means the alarm
survives a rotation of the main secret. That is the whole point: the alarm is
what tells you the rotation broke something.

Put the same value on the box:

```bash
printf '%s' "$WATCHDOG_SECRET" > /root/harness/env/.watchdog-secret && chmod 600 $_
```

Four box-side scripts read that file: the ping, the ticket snapshot, the cost
rollup and the transcript scrubber.

**This bot is not the console's bot.** Two different Telegram integrations share
the word: the watchdog pages you directly and works on its own, while the
console hosts the interactive `/command` bot and is not in this repository. You
can have the first without the second.

`wrangler deploy` prints this worker's URL. Export it — several steps below use
it, and it goes in `env/global.env` at step 6:

```bash
export WATCHDOG_URL='https://<the url wrangler printed>'
```

Prove the Telegram path end to end before you rely on it:

```bash
curl -X POST "$WATCHDOG_URL/api/test-alert?s=$WATCHDOG_SECRET"
```

**The ping is not generated — you must add it.** Every box in the upstream
fleet has this line in its committed cron file, but `cron_box_lines`
(`bin/lib/cron-lines.sh`) does not emit it, so a freshly bootstrapped box has no
ping at all. Add it yourself, once per box, outside the managed markers:

Two details decide whether this works, and both are silent when wrong.

**The worker only watches boxes named in its config file.** The list is
`worker/watchdog/src/boxes.json`, a JSON array of box names that
`worker/watchdog/src/index.js:27` imports, and the scheduled check iterates it
(`:209-211`). A box that is not in that file is never checked for silence.
**Edit `boxes.json` to name your boxes and redeploy the worker**, or the
dead-man switch watches nobody. A ping from a name the file does not know is
still stored and still answered `ok`, but it now pages: one Telegram alert per
hour per unknown name, saying it is missing from `boxes.json`
(`:138-141`). So a box you forgot to add is noise, not silence. A box that is
listed but has never pinged is still skipped rather than alerted on (`:211`).

**Pass the box's full hostname, not its short id.** Every committed cron line
passes the whole `box-*` name (`cron/hub.cron:25`), and that string is
the KV key the worker looks up. `state/box-id` holds the *short* id, which names
the crontab file and is a different thing. Use the name you put in `boxes.json`:

```bash
( crontab -l; echo "*/5 * * * * /root/harness/bin/watchdog-ping.sh <this-box-hostname>" ) | crontab -
```

Add it after step 7, once the live copy exists.

The ping is **fail-quiet by contract**: it swallows every error and always exits
0, because the watchdog noticing the silence *is* the alarm
(`bin/watchdog-ping.sh:12-13,37-38`). The corollary is that a box which never
pings is not alerted on either — the watchdog skips listed boxes it has never
heard from (`worker/watchdog/src/index.js:211`). So a missing ping fails silent,
and you will believe you are covered. Only the reverse case pages: a box that
pings under a name missing from `boxes.json`.

## Path B, step 3: the console

**This is the gap.** See [What Path B is missing](#what-path-b-is-missing).

## Slack (optional)

Slack is a second front door to the same orchestrator, not a second harness.
Messages arrive through the console exactly as Telegram messages do, and the
answer goes back the same way. Skip this whole section and nothing changes.

Three pieces have to line up, and the last one is a switch you flip by hand
after the first two are live.

**1. The Slack app.** Install it from the manifest the console repo ships,
`slack/app-manifest.yml`, into your workspace. That file is the source of truth
for the scopes and events the console expects; do not hand-assemble an app.
Installing it gives you a bot token that starts `xoxb-`.

**2. The token, in two places.**

- The **console** needs it as its own secret, because the console is what
  receives Slack events and posts replies.
- The **hub** needs it in `env/global.env` (chmod 600, never in git):

  ```bash
  printf 'SLACK_BOT_TOKEN=xoxb-...\n' >> /root/harness/env/global.env
  chmod 600 /root/harness/env/global.env
  ```

  The hub uses it for one job: `bin/chat-media.sh` downloads a Slack
  attachment's `url_private` with it so the orchestrator can read the file.
  Unset, a Slack attachment is refused with an ALERTS line rather than saved as
  a broken file — the message itself still gets answered. No other box gets this
  variable: `bin/fly-envbundle.sh` copies explicit keys only and `SLACK_*` is
  not among them.

**3. The console's settings rows**, which decide who may talk to it and where:

| Row | What it does |
|---|---|
| `slack_enabled` | The console's own on/off for the Slack transport |
| `slack_allowed_users` | Who is allowed to give the orchestrator instructions |
| `slack_hub_channel` | The channel the hub answers in |

**Then flip the hub's flag.** Until this file exists, the orchestrator replies
by curling api.telegram.org, which means a Slack question gets a turn and no
answer:

```bash
touch /root/harness/flags/orc-reply-via-console     # on
rm    /root/harness/flags/orc-reply-via-console     # back to Telegram-direct
```

With the flag present, a text reply to a message that carried a command id goes
out as one `chat_reply` beat with `relay:true` and the origin ids, and the
console delivers it on whichever transport asked. What happens when that beat
does not land depends on where the question came from, and neither case is
silent:

- **Telegram origin** — the reply is sent directly to Telegram as before, and
  one ALERTS line says the relay failed.
- **Slack origin** — there is no direct path to fall back to, so the reply stays
  in `/root/orchestrator/last-reply.txt` and the ALERTS line says exactly that.

Order matters only in one direction: flip the flag **after** the console's Slack
transport is deployed. A console that accepts the beat but does not yet know how
to relay it answers 2xx, which reads here as delivered — so an early flip drops
Telegram answers quietly, with only `/root/orchestrator/last-reply.txt` to show
for them. `rm` the flag and the next turn is Telegram-direct again.

Voice replies stay Telegram-only. A Slack conversation gets text, and the
orchestrator skips text-to-speech entirely for it rather than billing
ElevenLabs for audio nobody receives.

## Step 4: the registry

The fleet registry is the harness-jobs D1 database. It holds the projects, the
boxes, the lane memberships and the account-to-box rows. A box reads it when
`REGISTRY_SOURCE=db` is in `env/global.env`. `bin/harness-sync.sh` appends
that line once, when the registry answers with the checkout's project set
(BH-5651). No script keeps its own copy of the project list —
`tests/fleet-projects-not-hardcoded-test.sh` fails a script that tries.

Change the registry with `bin/registry.sh`. A write needs `HARNESS_SECRET`
and `REGISTRY_ADMIN_TOKEN` in the operator env:

```bash
bin/registry.sh add-box <name> --ip <tailnet-ip> --like <box-id>   # add a box
bin/registry.sh move-project <project> --box <box>                 # move a project
bin/registry.sh show                                               # check
```

`add-box` copies the lane memberships and account rows of the `--like` box.

On a box in db mode, `$H/fleet.conf` and the box maps of
`$H/catalog/cost-accounts.json` are an export of the registry.
`bin/registry-export.sh --install` writes them. `bin/harness-sync.sh` and the
`*/5` `bin/registry-sync.sh` lane run it. Do not edit these files on a box.
The committed `fleet.conf` is a seed and a human reference.

Rollback: put `REGISTRY_SOURCE=file` in `env/global.env`. The box then reads
the committed files. The next `bin/harness-sync.sh` copies the committed
`fleet.conf` back to `$H/fleet.conf`. The seed never changes an existing
`REGISTRY_SOURCE=` line.

In file mode, to add a box or to move a project, use `bin/box-register.sh`.
It writes the box into every list that names a box and then checks them
against `fleet.conf`. [Adding a box](ADDING-A-BOX.md) has the steps.

The `fleet.conf` format: seven
whitespace-separated columns (`fleet.conf:2-20`, parsed at
`bin/fleet-conf.sh:78-93`):

| # | Column | Meaning | Optional |
|---|---|---|---|
| 1 | `project` | The harness-wide name. Must match `prompts/<project>.md` and `env/<project>.env` | required |
| 2 | `repo` | `owner/repo` on GitHub | required |
| 3 | `prod-base-url` | Production origin. `-` means none, which suppresses the healthcheck lane | required, `-` allowed |
| 4 | `board-api-prefix` | Where the app serves its board API. `-` routes the project to the GitHub-Issues lane | required, `-` allowed |
| 5 | `cron-offset` | Minute past the hour when triage fires; it then runs at offset, +10, … +50. **Keep offsets distinct across projects sharing one LLM account** or three ticks hit it at once | required, numeric |
| 6 | `box` | Which box owns this project's watcher. `local` is the hub | optional |
| 7 | `tailnet_ip` | That box's address. Added 2026-09-11 to retire nine per-script IP tables | optional |

Parsing is positional, so a field cannot be blank mid-row — use `-` for columns
3 and 4, or truncate the row after 5 or 6.

**Column 7 is omitted, not `-`.** Truncate the row after column 6. A literal `-`
there is a string, and something will try to reach a host called `-`. An absent
column 7 means UNKNOWN and every caller fails closed rather than guessing an
address (`fleet.conf:13-20`, `bin/fleet-conf.sh:57-61`). `bin/load-project.sh`
writes a 6-column row, so add the seventh by hand later if other boxes need to
reach this one. It is **not** how onboarding reaches the box — that uses the box
name in column 6.

**`local` in column 6 makes this box the hub** for that project
(`bin/box-for.sh:14-17`). On a single-box install that is what you want. But
electing the hub does not *give* you the hub lanes: `cron/hub.cron` is a
committed base file in the upstream repo, not something the renderer emits, and
`cron_box_lines` does not include them. On a one-box install you must add the
cross-project lanes yourself, outside the managed markers — see
[The hub](#the-hub).

Query it rather than parsing it:

```bash
bin/fleet-conf.sh --projects                # every project
bin/fleet-conf.sh --projects-with-board     # the ones with an app board
bin/fleet-conf.sh --projects-on-box box-1   # the ones this box owns
bin/fleet-conf.sh project-1 repo            # one field
bin/fleet-conf.sh --tailnet-ip project-1    # exit 1 and silence if unknown
```

## Step 5: the prompts

One file per project: `prompts/<project>.md`. Start from
`prompts/TEMPLATE.md` (app board) or `prompts/TEMPLATE-GH.md` (GitHub Issues).
This is where the project's own vocabulary lives — what its statuses mean, who
its system actor is, which board its tickets are on.

The templates carry angle-bracket placeholders, and substituting them is the
whole job. `bin/load-project.sh` does it for you; by hand, replace every one:

| Token | With |
|---|---|
| `<PROJECT>` | The name in column 1 of `fleet.conf` |
| `<REPO_SLUG>` | `owner/repo` |
| `<PROD_URL>` | Column 3, or `-` |
| `<BOARD_PREFIX>` | Column 4 |
| `<KEY_PREFIX>`, `<KEY_PREFIX_LC>` | The ticket key prefix, upper and lower case |
| `<BASE_BRANCH>` | Usually `main` |
| `<CONTEXT>` | A paragraph on what this project is, for the model |

```bash
PROJECT=myproj
grep -o '<[A-Z_]*>' "prompts/$PROJECT.md" | sort -u   # nothing should remain
```

The generic prompts alongside them are shared and should not be forked per
project: `build-discipline.md`, `plan-contract.md`, `arch-audit.md`,
`remediator.md`.

## Step 6: the env files

Two files are required; three more are optional. None is ever in git — `env/`
is gitignored.

| File | When |
|---|---|
| `env/global.env` | always |
| `env/<project>.env` | one per project with an app board |
| `env/.watchdog-secret` | if you self-host the watchdog |
| `env/accounts.d/<name>.env` | only for multi-account routing |
| `env/fly.env` | only for the Fly pool |
| `env/github-app.env` + `env/github-app.pem` | only for GitHub App tokens (see "GitHub App installation tokens") |

All `chmod 600`.

**After bootstrap they are also immutable.** `bin/harden-state.sh` sets `chattr
+i` on every file under `env/` and on the box's `id_ed25519*` /
`authorized_keys`, and `chattr +a` (append-only) on ten ledgers under `logs/`:
`cost.csv`, `ALERTS.log`, `harden-state.log`, `alerts-state.log`,
`agent-rules.log`, `findings.log`, `medic.log`, `blocked-resolver.log`,
`READY-QUEUE.log`, `extra-usage.csv`. Bootstrap arms the box as its last step,
and a `*/10` cron lane re-arms anything left released.

So editing an env file by hand is three commands, from `/root/harness`:

```bash
bin/harden-state.sh --release env/global.env
# edit it
bin/harden-state.sh --rearm env/global.env
```

Forget the third and the cron lane does it for you inside ten minutes. The
window you get is the one you take, not one you keep.

`bin/harden-state.sh --status` prints `hardened=N/M` and exits 0 only when N
equals M. That figure, plus `logs/harden-state.log` (one line per run that
actually changed a flag), is how you check a box by hand — including the hub,
which has no `fleet.conf` row with a prod URL and therefore never runs
`bin/healthcheck.sh` at all. On the watcher boxes the 06:43/18:43 healthcheck
prints the same figure and raises an alert when it is short or unreadable.

Two consequences worth meeting on purpose rather than at 3am:

- **`ALERTS.log` and `cost.csv` can no longer be rotated or truncated.** `+a`
  permits appends and nothing else, so anything that rotates a ledger has to
  `--release` it, rotate, and `--rearm`.
- **The Orgo restore/merge path has to go through `--release` too.** That path
  overwrote `env/*` on 2026-09-15 (#388); against `+i` the copy now fails
  outright, so a restore is `--release`, restore the file, `--rearm`, per file,
  or it does not land.

**`/root/harness/env/global.env`** — fleet-wide. Copy
`env-templates/global.env.example` and fill in. The required set:

```
HARNESS_SECRET=<the value from step 0>
CLAUDE_CODE_OAUTH_TOKEN=<from `claude setup-token`>
JOBS_URL=https://<your-jobs-worker>.workers.dev
WATCHDOG_URL=https://<your-watchdog>.workers.dev
# CONSOLE_URL is required by bootstrap, and the console is not in this repo.
# Point it somewhere that returns a clean HTTP 404 — not a domain that fails
# DNS, which produces a different and noisier failure on every beat.
CONSOLE_URL=https://example.com/no-console
```

The template does not carry everything the code reads. The full set that
matters on a fresh box:

| Variable | Required | Notes |
|---|---|---|
| `HARNESS_SECRET` | yes | The shared bearer from step 0 |
| `CLAUDE_CODE_OAUTH_TOKEN` | yes | From `claude setup-token` |
| `JOBS_URL` | **yes in practice** | Not in the template, and **it has a default: the upstream fleet's worker** (`bin/jobs-client.sh:19`). Unset, your boxes coordinate through someone else's database |
| `CONSOLE_URL` | yes | Required by bootstrap. Without a console, see [What Path B is missing](#what-path-b-is-missing) |
| `WATCHDOG_URL` | if self-hosted | Same story, different default |
| `RUNNER_<STAGE>_FALLBACK` | no | Bootstrap appends these for 14 stages if absent |
| `XAI_API_KEY`, `OPENROUTER_API_KEY`, `FIREWORKS_API_KEY` | no | The fallback ladder. Absent, a Claude failure ends the attempt instead of degrading |
| `WATCHDOG_SECRET` | if self-hosted | Not read by the harness — but the verification step below needs it, and this is the only file that survives your shell |
| `ACCOUNT_ROUTING` | no | `1` to enable multi-account picking |
| `CLOUDFLARE_API_TOKEN` | if this box deploys Workers | `bin/harness-sync.sh` redeploys a changed Worker only on a box that has Cloudflare credentials, and reads them from `cloudflare.env`, not this file. On the hub after BH-3905's runbook it is a Pages Read token, and deploy credentials sit only in `cloudflare-deploy.env` for a rollback (see "Which Cloudflare token lives where") |

**The lanes source this file themselves.** `bin/run-triage.sh`,
`bin/run-build.sh`, `bin/cost-rows-push.sh` and `bin/watchdog-ping.sh` all read
`env/global.env` on entry, so cron's near-empty environment is not a problem and
the crontab lines below carry no sourcing.

With that file in place, the jobs client finally points at *your* worker, so
push the budget catalog:

**Not yet, though.** `/root/harness/bin/` does not exist until the first sync,
which happens during step 7. Come back to this after bootstrap:

```bash
set -a; . /root/harness/env/global.env; set +a
/root/harness/bin/jobs-client.sh catalog-sync
```

**`/root/harness/env/<project>.env`** — one per project. Copy
`env-templates/project.env.example`. The two that matter:

```
<PREFIX>_INTERNAL_API_TOKEN=<the token your app accepts>
<PREFIX>_API_BASE=https://<your app>
```

Only the **suffix** is fixed, but the prefix is not a free choice either: one
consumer matches `^[A-Z_]+_INTERNAL_API_TOKEN`, which forbids digits. `ACME_` is
fine, `ACME2_` is not — and the failure is a fail-open `RUN unknown-project` that
buys a paid triage session every ten minutes, silently. See
[docs/BOARD-API-CONTRACT.md](BOARD-API-CONTRACT.md#authentication). Exactly one
`*_INTERNAL_API_TOKEN` per file, or the project is skipped fleet-wide with an
alert (`bin/internal-token-for.sh:41-49`).

**`VERCEL_AUTOMATION_BYPASS_SECRET` deserves its own line**, because its absence
fails *silently*: preview QA hits the SSO wall, so every PR lands tier 2 forever
with no error anywhere (`bin/load-project.sh:308-325`).

## Step 7: bootstrap the box

On a first install the live copy does not exist yet, so run it **from the
checkout**. Afterwards either path works, and cron uses the live one:

```bash
/root/harness-checkout/bin/bootstrap-machine.sh <project>
```

It refuses without a `fleet.conf` row — there is no fallback table any more
(`:12-23`). It then installs the toolchain, creates
`logs/ state/ locks/ flags/ builds/ plans/`, derives `state/box-id` from
`bin/box-for.sh` rather than the hostname (five boxes can all report the same
hostname), seeds `BUILD_SLOTS=0` in `env/global.env` (uncapped: builds never queue behind
each other — set a number only if this box's cores/RAM need one), clones the app repo to
`/root/repos/<project>`, renders the crontab, and finishes with a **real smoke
test** (`:171-180`): it reaches the board — or, for a project with no board,
runs `gh issue list` instead, so the GitHub-Issues lane is handled and does not
hard-fail here — and then runs a 90-second `claude -p` session. **A failed
`claude` session is fatal**; the board check is informational.

It **ends by arming the box**: `bin/harden-state.sh` is the last thing it runs,
and a bootstrap that cannot make `env/`, the ssh key and the ledgers immutable
fails there instead of printing `BOOTSTRAP COMPLETE`. The two seeds it writes
into `global.env` (`BUILD_SLOTS`, the `RUNNER_*_FALLBACK` set) are wrapped in
`--release` / `--rearm` under `locks/harden-state.lock`, so re-running bootstrap
on a box that is already armed works rather than dying on an append.

The crontab step is worth understanding, because it is where a project quietly
disappears. Crontabs are generated, not hand-edited:

```
<every line the box already had, byte for byte>
# BEGIN fleet-managed project=<name>
  ...seven lanes...
# END fleet-managed project=<name>
```

Everything outside the markers is yours and is preserved exactly
(`bin/render-crontab.sh:15-17`). Unbalanced markers are **fatal**, because a
dangling `BEGIN` silently swallows the rest of the file including the watchdog
ping (`:102-142`). The daily re-render has a drift guard: a render that would
*drop* a live triage lane refuses the whole apply
(`bin/update-runners.sh:196-222`).

## Enrolling a project: pick ONE of these

Steps 4, 5 and 7 above describe what enrolment *consists of*. There are two ways
to do it and **they are alternatives, not a sequence** — run the script after
doing it by hand and you get two registry rows for one project.

### The script (recommended, and the only sane path for a repo with no board)

```bash
bin/load-project.sh <owner>/<repo>
```

It does steps 4, 5 and 7 in one pass: picks a free cron offset among that box's
projects, appends the registry row, renders the prompt from `TEMPLATE-GH.md`,
regenerates the crontab **in the same commit as the row** (a row published
without one is a lane the next 05:17 tick deletes), pushes, creates the
`ai-build` label, and runs the bootstrap — locally if the target box is this
machine, over ssh to the **box name** otherwise
(`bin/load-project.sh:66-302`).

You still write `env/<project>.env` yourself. Do it before the script runs.

### By hand

Only when you need something the script does not do, such as an app board rather
than GitHub Issues. Steps 4 → 5 → 6 → 7, and then one step the script would have
done for you and which is easy to miss:

Two things the script would have done and you now must. The label first,
because without it the harness can never be handed anything
(`bin/load-project.sh:164`):

```bash
gh label create ai-build -R <owner>/<repo> --color 1D76DB
```

Then the crontab file — `rm -f cron/*.cron`
in step 0 removed the upstream's, and only `bin/load-project.sh` regenerates one
automatically:

```bash
BOX_ID=$(cat /root/harness/state/box-id)      # after bootstrap
bin/render-crontab.sh "$BOX_ID" > "cron/$BOX_ID.cron"
git add fleet.conf "prompts/$PROJECT.md" "cron/$BOX_ID.cron"
git commit -m "enrol $PROJECT" && git push
```

**Committing is not optional.** `bin/harness-sync.sh --check` returns 30 for a
checkout that is locally dirty in `bin/`, `prompts/`, `rules/` or `fleet.conf`,
and the pre-build context gate refuses every build attempt on a 30
(`bin/context-gate.sh:34-62`). Leave your registry row uncommitted and the box
will triage happily and never build, with the reason in a log you have not
thought to read yet.

Either way, the project builds nothing until an issue is labeled `ai-build`.

---

## The hub

One box is the hub. It runs everything a watcher box runs, plus the lanes that
are about the fleet rather than a project. Each of these appears in
`cron/hub.cron` and in no other cron file:

| Lane | Cadence | What it does |
|---|---|---|
| `poll-commands.sh` | every minute | Claims console commands, runs them, acks; syncs new alert lines and pause flags up |
| `merge-sweep.sh` | every 10 min | Merges verified tier-2 PRs under a double gate — approve verdict, primary review lane, head-bound sha, green CI, iron-law scan, automerge not disabled  A repo no gh token can see is one ALERT per day, never a silent skip; on issue-driven projects the merge comments on and closes the issue |
| `pipeline-health.sh` | every 10 min | Deterministic pipeline tripwires (stuck queues, unreaped machines, aging PRs, cost caps, checkout drift). Since 2026-09-12 also **sweep should have landed** (an APPROVE'd, OPEN, CLEAN PR the sweep has not merged in 30 min — names the record and the sweep's last log line about it) and **starved project** (an issue-driven project with launchable ai-build issues, nothing running, nothing queued, no build row in 2h) Since 2026-09-12 (E2E policy) also **perma-red check** (`permared:` — a workflow red on `main` for ≥3 days across ≥3 runs, one alert per repo/workflow/day: "check X red N days — fix or delete"; docs/E2E-POLICY.md) |
| `claude-auth-check.sh` | hourly (+6h canaries) | End-to-end Claude auth probe per box; every 6h the runner-lane canaries and the **default gh token visibility canary** — every fleet.conf repo the default PAT cannot see is one alert naming whether the admin token can |
| `alert-triage.sh` | every 10 min | Collects quarantined alerts from every box, runs one session that fixes what it can, escalates only what needs a human |
| `fly-pool-tick.sh` | every 2 min | Ticks the ephemeral build pool, if you use Fly |
| `sweep-stale-builds.sh` | daily | Closes abandoned build rows. Hub-only because it reads the hub's build dirs (and, while `fly_machines_rows` is off, the hub's pool files); live keys come from `build_queue` and machines rows, no ssh; **an unreadable evidence source skips the whole run** |
| `cost-rollup.sh` | nightly + hourly | The per-PR cost view |

`merge-queue.sh` sounds hub-shaped and is not — it is a per-project lane on
every watcher, serialising landings for that project.

### Reaching the hub without ssh (BH-662)

Assume you cannot ssh to the hub. On 2026-09-17 port 22 refused from the Mac and
from a watcher box while every one of the hub's cron lanes kept running, and
there is a repo-side reason to expect exactly that: `cron/small.cron:1`,
`cron/project-5.cron:13` and `cron/project-6.cron:16` each carry an
`@reboot … /usr/sbin/sshd` line and `cron/hub.cron` carried none. On these VMs
cron is alive from the image and sshd is started by that line, so a hub that
rebooted (the 2026-09-15 wipe/resize window) runs every lane and listens on
nothing.

**The restore needs no ssh to land.** `cron/hub.cron` now carries both an
`@reboot` line and a `*/5` keepalive
(`pgrep -x sshd >/dev/null || { mkdir -p /run/sshd && /usr/sbin/sshd; }`).
`bin/update-runners.sh` applies that file on the hub at 05:17Z daily, after
`bin/fleet-propagate.sh` has synced the merge within 5 minutes, and the first
`*/5` tick afterwards starts sshd. Both lines are no-ops when sshd is up.
Confirm from the Mac with `ssh root@<hub tailnet ip> true`.

**Two channels that work while it is down.** Both are how hub operations should
be run, not workarounds:

1. **The repo.** A merged file under `fly/` reaches `/root/harness/fly/` on the
   hub's own `fleet-propagate` tick (\*/5, `bin/harness-sync.sh:141`), and a
   merged `cron/hub.cron` line reaches the crontab at 05:17Z. This is how
   `fly/pool-caps.conf` has always been edited, and `fly/onboard-queue.conf` is
   the worked example: add a project line, merge, and the hub runs
   `bin/fly-onboard.sh <project>` for you on its next `bin/fly-pool-tick.sh`.
2. **The console `chat` command addressed to project `orchestrator`**
   (`bin/poll-commands.sh` chat handler → `/root/orchestrator/inbox` →
   `orchestrate.sh`). From that session `bin/fly-onboard.sh <p>` is a one-line
   operation. **Caveat, stated because it bites:** console claims are not
   box-scoped (`bin/poll-commands.sh:194-201`) — whichever box's poller claims
   first wins, very often the hub but not always — so a command that must run on
   the hub is a request, not a guarantee. The repo channel is the deterministic
   one.

**The diagnosis to run once you are on the hub**, whichever way you got there:

```bash
pgrep -a sshd                 # nothing  -> sshd is not running (the expected cause)
ss -ltn | grep ':22 '         # nothing  -> nothing is listening on 22
crontab -l | grep -c '@reboot'  # 0 on the old crontab, ≥1 once this lands
```

If sshd IS running and listening, the cause is not this — look at the tailnet
(ACLs, `tailscale status`) instead, and the two lines above change nothing.

### The hub runs no agent build work

The hub coordinates; boxes work (docs/HUB-THINNING-PLAN.md). Since BH-393 that
is a control, not a paragraph: `bin/agent-call.sh` refuses build stages here
(rc 77, nothing called and nothing billed), `bin/run-build.sh` refuses with
`BUILD_REFUSED hub-no-build` (rc 3) naming the box the ticket belongs on,
`bin/run-preplan.sh` refuses before it creates a plan dir (rc 3), and
`bin/up10-lane.sh --here` refuses outright.

What you will see in `logs/ALERTS.log`, once per (lane, ticket) per UTC day:

```
2026-09-16 18:02:15Z [hub-no-build] refused execute BH-393 on box-hub — the hub runs no agent build work (HUB_BUILD_OK=1 overrides, docs/HUB-THINNING-PLAN.md)
```

The dedupe marker is `flags/alerted-hub-no-build-<lane>-<ticket>-<YYYYMMDD>`;
delete it to make the line repeat today.

| Knob (`env/global.env`) | Default | What |
|---|---|---|
| `HUB_BUILD_OK` | unset | `1` lets this box run build lanes even though it is the hub |
| `HUB_NO_BUILD_LANES` | `build plan preplan preplan-files execute fix qa` | The refused list. `review` is **not** in it — the hub's review lanes have not moved yet |
| `HUB_BOX_NAME` | `box-hub` | The hub's fleet name. Identity comes from `bin/box-name.sh`, never `hostname` |

`HUB_BUILD_OK=1` does **not** re-open `up10-lane.sh --here` on the hub. That is
the lane that was mid-flight in `/root/harness/tmp/wt-up10-*` when the hub was
wiped on 2026-09-15, and it has no override. Run self-improvement work with
`/root/harness/bin/up10-lane.sh <slug> <brief-file>` from anywhere: it resolves
the owning box through `bin/box-for.sh cromford`, hops over ssh, files the
`ai-build` issue and starts the ordinary build there.

### `/root/repos/<project>` must be a FULL clone (BH-517)

The hub's `/root/repos/<project>` is the checkout the merge conductor rebases
in, and it has to carry the whole history: a clone made with `--depth` has no
merge base with `origin/main` for any PR that forked before its boundary, so
every rebase of an older PR dies `fatal: refusing to merge unrelated histories`
and the PR loops `NEEDS_REBASE`. `gh repo clone` (what `bin/bootstrap-machine.sh`
runs) is full, and a `--filter=blob:none` partial clone is fine — partial is not
shallow. A hand restore with a depth, which is how the 2026-09-15 wipe was
recovered, is not.

Three things now hold it: `bin/bootstrap-machine.sh` refuses to finish on a
clone it cannot unshallow, `bin/pipeline-health.sh` pages
`hubreposhallow:<project>` once a day for any `/root/repos/*/.git/shallow` it
finds, and `mc_rebase` heals the clone itself — one `git fetch --unshallow
origin` under the project git lock, logged, then the merge is retried in the
same call. To fix one by hand:

```
git -C /root/repos/<project> fetch --unshallow origin
```

### Silence guards (2026-09-12)

Four stacked gaps cost ten hours on project-5: the hub's default PAT 404'd on
the repo, so every lane that listed its PRs ran an empty loop and logged
nothing; six Fable-approved, CLEAN PRs sat unmerged with nothing detecting the
state; a correct lane alert sat unread in `ALERTS.log`; and the box's triage
gate fingerprinted issue threads only, so hand-merged PRs that closed no issue
left it answering "gate no-change" all day. The guards, all deterministic:

- **`bin/lib/gh-repo-token.sh`** — `gh_repo_use_token <owner/repo>` routes a
  consumer to the org-admin token (`env/github-admin.env`, `GH_ADMIN_TOKEN`)
  when the default one cannot see the repo, and `gh_repo_invisible_alert`
  pages once per (lane, repo, day) when no token can. `merge-sweep.sh`,
  `pipeline-health.sh` and `review-autopilot.sh` go through it. The pool's
  reap-time PR check does **not** and will not: it keeps its own inline REST
  probe, for the reason `bin/lib/gh-repo-token.sh` gives for `merge-sweep.sh` —
  the fixtures copy that script standalone into a scratch tree. Either way the
  pool never relabels a real PR as `RESULT_UNVERIFIED` over token scope any
  more, or over a rate-limited read (BH-709, 2026-09-17: a failed read is
  UNKNOWN, never a state — see
  [docs/verification-map/pr-verify-gate.md](verification-map/pr-verify-gate.md)).
  Token values never reach a log.
- **`pipeline-health.sh`** — the `sweepstall:` and `starved:` detectors above,
  both through the existing alert + RESOLVED retraction path. The starved
  check covers issue-driven projects only; a board's buildable state is a
  thread-level judgement the triage prompt owns.
- **`claude-auth-check.sh`** — the 6h `ghinvisible:` canary above.
- **Backup freshness (BH-399)** — the same shape one level down: a backup that
  stops raises no error at all, so the AGE of `state/backup-last.json` is the
  signal. Each box reports its own facts from `bin/state-backup.sh` and
  `bin/backup-records-sync.sh` (hub, `*/5`) writes the records,
  `bin/fleet-status-push.sh` carries it as `backups.<box>` and the Fleet
  screen renders it, and `pipeline-health.sh` pages `backupstale:` (past
  `backup_stale_min`, default 30 — two missed cycles of the `5,20,35,50` lane)
  and `backupmissing:` (a box that has NEVER stamped), once an hour per box,
  both retractable. A box switched off or still unconfigured is carried as
  state and never paged — `bin/state-backup.sh` already says that once per UTC
  day, and an hourly duplicate is how a channel gets muted. Raise the
  threshold with no deploy:
  `bin/jobs-client.sh setting-set backup_stale_min 45 "why"` (box-local escape
  hatch: `BACKUP_STALE_MIN` in `env/global.env`). See
  [docs/verification-map/backup-freshness.md](verification-map/backup-freshness.md).
- **E2E policy (2026-09-12, `docs/E2E-POLICY.md`)** — `bin/lib/e2e-paths.sh`
  is the one definition of "E2E path" / "E2E-class check"; `review-prs.sh`'s
  re-review debounce and `review-autopilot.sh`'s prompt treat E2E-class
  checks as advisory when the diff touches no E2E path (fail closed
  otherwise); `pipeline-health.sh` pages `permared:` once a day per workflow
  red on `main` for 3+ days. The merge sweep's CLEAN gate is unchanged.
- **`triage-gate.sh` / `gate-diff.sh`** — the GitHub-Issues fingerprint carries
  the open harness PRs (number, head sha, mergeStateStatus, state), one extra
  `gh pr list` per tick; a merge reads as `board prs: REMOVED <n>` in the tick
  scope, a check flip or rebase as `CHANGED`.
- **`run-build.sh`** — on issue-driven projects the PR body carries
  `Closes #<n>`, and a verified tier-1 merge comments on and closes the issue
  explicitly (so does the tier-2 sweep), belt and braces.
- **`lane-alert.sh --critical`** — a detached lane's alert additionally DMs
  the operator on Telegram when the orchestrator monitor is off
  (`/root/orchestrator/flags/monitor-off`), using `TELEGRAM_BOT_TOKEN` from
  `env/global.env`.

**These lanes are not generated per project.** The renderer emits per-project
blocks and a short list of per-box singletons (`bin/lib/cron-lines.sh
cron_box_lines`); the hub's cross-project lanes are committed sources in the
upstream repo. On your own single-box install, commit the ones you want, then
render and install. Never edit the live crontab by hand: the next render
replaces it, and the cron suites never see it. Five of them are registry lanes
already (`cron/lanes/<NNN>-<id>.cron`), so your box joins each one's `.boxes`;
`merge-sweep.sh` has no registry lane, so it is a fragment of your box:

```bash
BOX_ID=$(cat /root/harness/state/box-id)
for id in alert-triage sweep-stale-builds cost-rollup cost-rows-push quota-poll; do
  jq --arg b "$BOX_ID" '.boxes = ((.boxes + [$b]) | unique)' "catalog/lanes.d/$id.json" > "catalog/lanes.d/$id.json.tmp" \
    && mv "catalog/lanes.d/$id.json.tmp" "catalog/lanes.d/$id.json"
done
mkdir -p "cron/boxes/$BOX_ID.d"
echo '6,16,26,36,46,56 * * * * /root/harness/bin/merge-sweep.sh' > "cron/boxes/$BOX_ID.d/900-merge-sweep.cron"
bin/lanes-build.sh --check
git add catalog/lanes.d "cron/boxes/$BOX_ID.d"
bin/render-crontab.sh "$BOX_ID" | crontab -
crontab -l    # check: the markers are balanced and nothing appears twice
```

Notes on that list. `poll-commands.sh` is omitted because it is only useful with
a console. `cost-rollup.sh` renders twice on purpose: a full nightly pass and an
hourly window refresh that skips the hour the full pass runs. **`cost-rows-push.sh`
and `quota-poll.sh` are per-box, not hub-only** — every box in the upstream fleet
is in their `.boxes`, so put every box of yours there too or that box's cost rows
never reach the database and account routing never sees its quota. `quota-poll.sh` is inert without
`env/accounts.d/`, so it is harmless if you do not use multi-account routing.
The watchdog ping is not repeated here; you added it in step 2.

**The trailing `>/dev/null 2>&1 #` on the quota-poll and cost-rows-push lines is not decoration.**
`tests/account-routing-test.sh:605-613` matches the quota-poll line with an
anchored regex that requires exactly that shape, including the comment marker,
and reports any other spelling as "a quota-poll line of the wrong shape". The registry
lane files (`cron/lanes/560-quota-poll.cron`, `570-cost-rows-push.cron`) already
carry that shape, so joining their `.boxes` gets it right; a line of your own
must copy it verbatim. A box that deliberately has no quota-poll line must instead carry the
literal words `NO quota-poll line, deliberately` with the reason, or the same
suite fails it for an unexplained absence.

The box-id that names a crontab is derived, not configured
(`bin/lib/cron-lines.sh:27-37`): `local` and the hub's own name map to `hub`;
otherwise the hostname prefix is stripped, and a trailing `-<digit>` is dropped
because that is a machine generation, not a different box.

---

## Keeping code fresh

`bin/harness-sync.sh` is the self-update path, and it is not a `git pull` in a
cron line.

`--check` reports freshness and nothing else, with meaningful exit codes: `0` at
origin, `10` behind, `20` **unknown** because the fetch failed — never counted
as fresh — and `30` diverged or locally dirty in `bin/`, `prompts/`, `rules/` or
`fleet.conf` (`:14-19`). A deploy refuses on 30 and never force-resets a box.

It rsyncs `bin/`, `prompts/`, `catalog/`, `checks/` and `guardrails/` into
`/root/harness`, and copies `fleet.conf` and `vercel.conf` across as well —
which is how a registry row written on one box reaches the others
(`bin/harness-sync.sh:120-127`). The copy which is temp-file-and-rename, so a running pipeline keeps its
open inode (`:24-25`). Then it applies the agent rules, syncs skills, clears
stale pool halts, and deploys any changed Worker if this box has Cloudflare
credentials.

Four things trigger it: `bin/fleet-propagate.sh` within five minutes of a merge
(below); the daily 05:17 `update-runners.sh`; **every build**, via the context
gate — if the box is behind it syncs and then *refuses that attempt*, so the
build runs entirely on fresh code (`bin/context-gate.sh:34-62`); and project
onboarding.

### Propagation on every merge (2026-09-14)

`bin/fleet-propagate.sh` is a hub cron line (`*/5`, operator block in
`cron/hub.cron`). When `origin/main` moves and the diff touches a path the fleet
actually runs — `bin/`, `prompts/`, `fly/`, `rules/`, `skills/`, `cron/`,
`catalog/`, `checks/`, `guardrails/`, `worker/`, `fleet.conf`, `vercel.conf` —
it syncs the hub, ssh's **every** box in `fleet.conf` through
`update-runners.sh`, and rebuilds **every** pool image with
`bin/fly-image-build.sh`. A commit that touches none of those paths records the
sha and skips; nothing is ssh'd and nothing is rebaked.

Why the pools are in this lane at all: pool machines are volume-less, so their
`run-build.sh` and entrypoint come from the BAKED image, and
`bin/fly-image-build.sh` bakes from the LIVE hub install. A `bin/` or `fly/`
change reaches a pool only after hub sync **and** an image rebuild, which is why
the hub syncs first and alone here, before the boxes and bakes fan out.

It records `state/fleet-propagate.json` (`last_sha`, per-box `rc` + the sha the
box actually landed on, per-pool result, `changed_paths`) and fires exactly one
`bin/lane-alert.sh` per run: informational on a clean sweep, `--critical` naming
the box or pool and its rc when anything failed. Every pool result is reported
honestly: rc=0 is `ok`, any non-zero rc is `fail` and makes the run `--critical`.
(The warm-bake layer now skips dependency install when the repo has no package
manifest, so `project-6` no longer needs special-case toleration.) A tick that lands on a running `harness-sync` or a running image
build logs `DEFERRED` and waits for the next one.

`--check` prints what would propagate and writes nothing; `--force` propagates
even when no fleet path changed.

The 05:17Z sync and the 05:40Z `fly-image-refresh.sh` stay exactly as they were:
the backstop for a box that was asleep, unreachable or deferred when its merge
went past.

### Agent rules are repo-managed

`rules/CLAUDE.md` is the machine-wide rules file, and it is rendered onto every
box at `/root/.claude/CLAUDE.md` by `bin/sync-agent-rules.sh apply` — on every
sync, every daily tick, and as a self-heal before a build when the context gate
sees drift.

**Edits to `/root/.claude/CLAUDE.md` on a box are silently reverted**
(`rules/CLAUDE.md:3-10`). The escape hatch is `/root/.claude/CLAUDE.local.md`,
which is appended and never overwritten.

> Earlier versions of this document said the box file was provisioned by hand
> and drifted. That has not been true since 2026-08-14.

The same mechanism gives the non-Claude runners the same rules: they load
nothing automatically, so `sync-agent-rules.sh render` produces a block that
`bin/agent-call.sh` prepends to every non-Claude session.

---

## Runners and vendor lanes

Each stage names its runner through an env var derived from the stage name —
`RUNNER_TRIAGE`, `RUNNER_EXECUTE`, and so on, with `RUNNER_<STAGE>_FALLBACK`
beside it (`bin/agent-call.sh:80-83`). Default is `claude`.

When a call fails, `agent-call.sh` walks a fixed ladder:

1. Primary, promoted to the fallback first if the primary is not installed or
   authenticated (`:1096-1102`)
2. Same vendor, next account with headroom, if account routing is on
3. Same lane retry, if the failure was a kill inside the timeout window
4. **grok** — the first provider fallback (`:1180-1185`)
5. Your configured fallback, if it is not grok
6. **openrouter** — a survival lane that preserves the stage's model through
   `anthropic/` slugs, with a loud alert (`:1209-1219`)
7. **fireworks** — open models only; the stage model is not preserved
8. Dead

The ladder is refused outright after a budget stop or a kill, so a runaway
cannot walk itself down the list spending money. The order is pinned by
`tests/agent-call-provider-order-test.sh`.

**A review served on rung 6 is a CLAUDE review (2026-09-16).** The openrouter
lane keeps the stage's own model, so its `(runner, model)` pair is
`openrouter` + `anthropic/claude-…`. Judge provenance reads the PAIR
(`bin/lib/review-provenance.sh`) and records it as `claude-via-openrouter`,
which every merge gate treats as primary — the word stays honest about the lane,
and any reader that has not been taught it holds the PR rather than merging it.
Both markers (`<out>.runner`, `<out>.model`) are written by whichever attempt
served last, for every lane: they used to disagree, and a grok review that
inherited `claude-opus-5` from the claude attempt above it is the bug that made
this explicit (project-5 #1624).

**A prompt over `AGENT_ARGV_MAX` (96000 bytes) goes to the codex-backed lanes on
STDIN, not argv (2026-09-16).** Linux caps one argv element at 128KB, so rungs
6 and 7 used to fail with `Argument list too long` on every review-sized prompt
— the survival ladder was structurally dead for exactly the calls that most
needed it (project-5 #1621). Under the ceiling nothing changed. Since BH-495
that covers the codex **primary** lane too (`codex exec … -`), which is the
execute runner on project-4/project-1 and any `RUNNER_<STAGE>=codex`.

**`grok` and `gemini` take the prompt as argv only, so over the ceiling they
REFUSE (BH-495).** Neither CLI is installed on the build boxes, so nobody here
has verified a stdin path for them; instead of an execve that cannot succeed,
the lane writes `PROMPT_TOO_LARGE <bytes> <runner> …` to `<out>` and
`<out>.err`, exits **79**, and the ladder classifies it
`real-failure(prompt_too_large)` — descend to a lane that takes stdin, no
same-runner retry, no account cooldown. Nothing is ever truncated: a truncated
review is a verdict on code nobody read. If a box ever gets one of those CLIs
and `--help` shows a file/stdin prompt flag, that lane joins the stdin arm.

Credentials, per vendor:

| Runner | Needs | Billing |
|---|---|---|
| claude | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | Subscription unless only the API key is set |
| codex | `~/.codex/auth.json`, or `CODEX_API_KEY`/`OPENAI_API_KEY` | Always treated as subscription |
| grok | `XAI_API_KEY`, and the key is **unset for the call** unless `GROK_BILLING=api` | Metered only when you flip that |
| openrouter | `OPENROUTER_API_KEY`, plus the codex binary | Always metered |
| fireworks | `FIREWORKS_API_KEY`, plus the codex binary | Always metered |

`bin/billing-mode.sh <runner>` prints `metered`, `subscription` or `unknown` for
the credentials live in the current environment, and it is called at row-write
time rather than inferred later.

The runner CLIs themselves:

| CLI | Installed as | Kept current by |
|---|---|---|
| claude | npm global `@anthropic-ai/claude-code`, or the native launcher `~/.local/bin/claude` | `bin/cli-update.sh` daily at 05:17Z |
| codex | npm global `@openai/codex` | `bin/cli-update.sh` daily at 05:17Z |
| grok | native only: `~/.grok/bin/grok` -> `~/.grok/downloads/grok-linux-x64`, from `curl -fsSL https://x.ai/cli/install.sh \| bash` | `bin/cli-update.sh` daily at 05:17Z, by re-running that installer |

`bin/cli-update.sh` (every box, from `bin/update-runners.sh`) updates the CLIs in
`CLI_UPDATE_CLIS`, default `claude codex grok`, and exits non-zero only when one
ends up WORSE or MISSING. grok is read through its launcher before PATH, because
that is what the lanes run — xAI's installer never links into `/usr/bin`. Its
previous release is kept one cycle at `~/.grok/downloads.prev`, and the update
log prints the one-command rollback. The hub's `bin/cli-version-check.sh`
(05:40Z) then probes every CLI named in `catalog/cli-min-versions.json` on every
box and writes one ALERTS line per box below a floor, behind the hub, missing a
CLI or split between its two PATHs. Floors live in that catalog, per model.

`GROK_OUTPUT_JSON=1` (default `0`) makes the grok lane run with
`--output-format json`, keep the CLI's result document at `<out>.envelope` and
price the cost row from the vendor's own `usage` and `total_cost_usd` rather
than from the ledger walk. It is off until a probe on a 1.0.40 box confirms
which envelope field carries the answer text. The fleet-wide flip is one
settings row, `lib.agent-call.grok_output_json = 1` (PUT /api/settings), which
outranks the env on every box; see `catalog/lanes.d/_lib.json` for the other
`lib.agent-call.*` knobs.

**`GROK_BILLING=api` is an architecture change, not an env edit.** Flipping it
moves a lane from flat-rate to per-token; it cost $460 in two days once
(`bin/billing-mode.sh:47-52`).

`openrouter` and `fireworks` are the codex CLI pointed at another provider
through config overrides, which is why both require the codex binary even though
neither talks to OpenAI.

### Several accounts of one vendor

Drop one file per account into `/root/harness/env/accounts.d/<name>.env`,
`chmod 600`, modelled on `env-templates/accounts.d/EXAMPLE.env.example`. Set
`ACCOUNT_ROUTING=1` and `bin/account-pick.sh` will choose which account pays,
skipping any that is over its 5-hour, weekly or per-model headroom.

It exports the chosen account's credential and **unsets every other credential
variable for that vendor** in the child process, because the CLI prefers an env
token over a config-dir login. A file whose name does not match its
`ACCOUNT_NAME`, names an unknown vendor, or carries no credential is skipped
with a logged reason rather than silently ignored (`bin/account-pick.sh:100-155`).

---

## Cost

Every call writes a 16-column row to `logs/cost.csv` the moment it returns
(`bin/agent-call.sh:290,1016`):

```
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,
cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account
```

`cost_usd` is filled only by the Claude CLI, which reports its own. Everything
else is priced downstream from tokens.

`bin/cost-rows-push.sh` ships new rows to D1 every 10 minutes from a cursor,
advancing it only after a 2xx, and deduplicating on a hash of the raw line so a
replay is free (`bin/jobs-client.sh:1185-1186`). `bin/cost-rollup.sh` collects
every box nightly and builds the per-PR view.

Pricing is a JSON table, **per token, not per million**, refreshed nightly from
OpenRouter's model list through a hand-maintained name map. The refresh writes
`state/model-prices.json` on the hub (runtime state, never the git checkout —
a cron that dirtied the checkout stopped every hub deploy for 16h, BH-628), and
`catalog/model-prices.json` stays the committed fallback every box and fly
builder prices from. Readers try `$MODEL_PRICES`, then `state/`, then the
catalog. Lookup
is an exact dictionary hit — no prefixes, no fuzzy matching. A miss costs $0 in
the rollup, which is why the unpriced alert exists: any model that produced
tokens and priced at zero in the last 24 hours is named in a daily alert, split
into *no price-table entry*, *no tokens reported*, and *priced model, still $0*
(`bin/cost-rollup.sh:1194-1248`).

**A lane you cannot price is a lane you cannot trust.** Blank cost fields on a
live lane are a bug, not a cosmetic gap.

Budgets are `$/PR` rows in `catalog/cost-caps.conf` (override:
`flags/cost-caps.conf`) plus a fleet `ceiling` per 24 hours — see
[COST.md](COST.md). At 2× a project's `$/PR` budget, or when it spends with
zero merged PRs, the health lane pauses the project itself: the autohalt has
been **on by default** since K1 (2026-09-24). Kill switches:
`flags/cost-autohalt-off`, or the settings row
`lane.pipeline-health.cost_autohalt = 0`.

---

## Kill switches

Flags are files under `/root/harness/flags/`. The **file** is the flag —
database rows drive the file rather than replacing it, so a Worker outage leaves
every box behaving exactly as it was, and a manual `touch` is not fought by an
unchanged row (`bin/jobs-client.sh:405-441`).

The ones to know:

| Flag | Stops |
|---|---|
| `automerge-disabled` | **All** automatic merging, everywhere, and forces every build to tier 2 |
| `paused-<project>` | Triage, the product lane, and migrations for that project |
| `build-slots` | **Legacy.** The box-wide build cap now lives in `env/global.env` as `BUILD_SLOTS` (0 = unlimited, the default). This file is still read when `BUILD_SLOTS` is unset, and nothing writes it any more — see docs/BUILD-CONCURRENCY.md |
| `wip-limit-<project>` | Concurrent builds for one project |
| `context-gate-disabled` | The pre-build freshness gate — builds proceed on drifted context |
| `postmerge-qa-disabled` | Production QA after a merge |
| `migration-autopilot-disabled` | Automatic migration application |
| `remediation-disabled` | Both remediation tiers |
| `gh-app-tokens-off` | GitHub App installation tokens for every WRITE and every lane's ordinary auth — they fall back to the PAT they used before ("GitHub App installation tokens"). It does **not** stop `gh-token.sh --read`, the read-only fallback for Actions reads; remove `env/github-app.env` for that |
| `gh-app-rotate-off` | **Only** the mid-build token rotation. Pool machines still get a repo-scoped token at spawn; the hub stops replacing it while they run |
| `cost-autohalt-off` | **Only** the cost breakers' PAUSE (hub). The `$/PR` rate alert, the zero-merge and ceiling pages still fire; nothing is paused. Same as the settings row `lane.pipeline-health.cost_autohalt = 0` — see [COST.md](COST.md) |
| `clock-sync-off` | The box's clock discipline (`CLOCK_SYNC=0` is the same switch) — see "The box clock" |
| `HUB_BUILD_OK=1` | Not a flag file — an `env/global.env` var, and the only override for the hub's no-agent-build-work guard. It does not cover `up10-lane.sh --here`, which has none ("The hub runs no agent build work") |

Opt-*in* flags exist too, and are off by default on purpose:
`remediation-agent-enabled`, `product-autonomy-<project>`,
`orchestrator-continue`. (`cost-autohalt-optin` is gone: the cost autohalt is
on by default since K1, and `cost-autohalt-off` is its kill switch.)

### Family 6 — destructive filesystem verbs (BH-391)

The act-time iron-law guard (`bin/iron-law-guard.sh`) runs as a Bash PreToolUse
hook and denies five irreversible families on the build lanes. **Family 6 is the
one that applies to every marked session, build lane or not**: a destructive
filesystem verb aimed at something the box cannot get back.

**What it refuses.** `rm` in any form, `find -delete`, `git clean`,
`git worktree remove`, `rsync --delete`, `truncate`, `shred`, a pure-truncation
redirect (`> file`), and any of those whose target contains an empty or unset
expansion — `rm -rf "$WT/env"` with `WT` unset is refused on the unset variable
alone, because that is the shape that deletes a root.

**The protected roots.** `/root/orchestrator`, `/root/repos`,
`/root/harness-checkout`, `/etc/harness`, `/root/.ssh`, and `env`, `state`,
`logs`, `builds`, `flags`, `locks` under the harness dir. Losing any of them
costs a rebuild of the box, and no session has a reason to delete one.

**The allow-list**, because a lane must still be able to clean up after itself:
`/tmp`, `$TMPDIR`, and whatever `WT`, `BUILD_DIR`, `HARNESS_LANE_WT` and
`HARNESS_LANE_BUILD_DIR` name for that session, plus the lane's own build dir
under `$HARNESS/builds/<project>-<ticket>-*`. The most specific root wins, so a
worktree inside a protected tree is still the lane's own to delete.

**Which sessions carry the marker.** The pipeline stages — plan, execute, review,
fix, qa, triage — get it from `bin/agent-call.sh`. The three conversational
launchers get it from `bin/iron-law-arm.sh`, called from their own scripts:
`bin/orchestrate.sh` (lane `orchestrator`), `bin/box-chat.sh` (lane `chat`) and
`bin/greenfield.sh` (lane `greenfield`). Those three keep their merge and deploy
authority — families 1-5 apply to the guarded build stages only — and pick up
family 6. Every other Bash session on the box carries no marker and the hook has
no opinion about it.

**It is a tripwire, not a sandbox.** The turn still runs as root with the full
tool set, and a session that writes its own script or reaches for the same file
through Python is not stopped by a classifier reading a command line. Arming can
never refuse a turn either: when the guard or `jq` is missing, the launcher gets
nothing, runs unfenced, and one line lands in `logs/ALERTS.log` saying so
(`grep 'iron-law guard MISSING' /root/harness/logs/ALERTS.log` should stay empty
on a synced box). The actual wall — making the roots immutable so nothing on the
box can delete them at all — is `chattr`, tracked in #388.

---

## GitHub App installation tokens

**Optional, and one-time.** Skip it and nothing changes: every lane keeps using the
PAT it uses today.

### Why you would

Out of the box every lane on every box and every ephemeral Fly builder
authenticates GitHub with **one** personal access token — `GH_TOKEN` in
`env/global.env`, plus `GH_ADMIN_TOKEN` in `env/github-admin.env` for repos the
default one cannot see. That has two costs that only show up at scale:

- **5000 REST requests per hour, for the whole account, shared by everything.**
  The pollers in `docs/EVENTS.md` §8 spend a few hundred an hour before a single
  build runs. Past a few hundred concurrent builders GitHub is the throughput
  ceiling, and the symptom is a 403 in a lane that has no idea why.
- **One credential that never expires, copied everywhere.**
  `bin/fly-envbundle.sh` puts that PAT on every pool machine. A leak is the
  fleet's whole GitHub identity, permanently.

A GitHub App installation token is rate-limited **per installation**, can be
scoped to **one repo**, and **expires in an hour**. `bin/gh-token.sh` mints and
caches them; `bin/lib/gh-app-auth.sh` is the one line a lane adds.

### What you do once

1. **Create the App.** GitHub → your org (`example-org`) → Settings → Developer
   settings → GitHub Apps → **New GitHub App**. Name it something like
   `cromford`. Homepage URL can be the repo. **Uncheck Webhook → Active**
   (the fleet's webhook is the org-level one in `docs/EVENTS.md` §4.3, not the
   App's).

2. **Repository permissions** — exactly these:

   | Permission | Level | Who needs it |
   |---|---|---|
   | Contents | Read and write | `git push` of a build branch, the conductor's rebase, `flaky-quarantine.sh` |
   | Pull requests | Read and write | `gh pr create` / `view` / `list` / `diff` / `comment` / `merge` |
   | Issues | Read and write | the `ai-build` issue lane, triage gate, `unblocked-children.sh` |
   | Checks | Read-only | the CLEAN gate's `statusCheckRollup` |
   | Actions | Read and write | `actions/runs` reads in `merge-sweep.sh`, `flaky-detect.sh`; `gh workflow run` / re-run in `pre-arm-guards.sh` and operator re-runs of flaky checks |
   | Deployments | Read-only | `wait-preview.sh`, `deploy-verify.sh`, `postmerge-qa.sh` read `/deployments` — **not in the original spec for this change; the §8 inventory is where it surfaced, and without it post-merge QA cannot see a deploy** |
   | Metadata | Read-only | mandatory, GitHub adds it |
   | Workflows | Read and write | a PR that touches `.github/workflows/**` cannot be pushed without it |

   Nothing else is granted on purpose: Administration, Secrets, Environments and
   org-level scopes are unused by any lane, and the token this App mints rides
   every ephemeral pool machine. The harness falls back to the PAT for anything
   the App is refused, and permissions are additive later (edit the App, then
   re-approve the installation).

3. **Generate a private key** (App settings → Private keys → Generate) and put
   the downloaded `.pem` on every box:

   ```bash
   install -m 600 /dev/stdin /root/harness/env/github-app.pem < ~/Downloads/<app>.private-key.pem
   ```

4. **Install the App** on `example-org` with access to all repositories (or at
   minimum every repo in `fleet.conf`; every fleet repo lives under that one
   owner — `project-7` is a repo, not an owner). Install →
   note the installation id, which is the last path segment of the settings URL
   (`.../settings/installations/<id>`), or read them off with
   `gh api /app/installations -q '.[]|"\(.account.login) \(.id)"'`.

5. **Write `env/github-app.env`** on every box (copy
   `env-templates/github-app.env.example`):

   ```
   GH_APP_ID=<numeric App ID from the settings page, not the client id>
   GH_APP_PRIVATE_KEY_FILE=/root/harness/env/github-app.pem
   GH_APP_TOKENS=1
   GH_APP_INSTALLATION_example-org=<installation id>
   GH_APP_SLUG=cromford          # only if you named the App something else
   ```

   ```bash
   chmod 600 /root/harness/env/github-app.env /root/harness/env/github-app.pem
   ```

   The installation ids are optional — left out, `bin/gh-token.sh` discovers them
   once with `GET /app/installations` and caches the answer in
   `state/gh-app-installations.json`. Naming them saves that request.

   `env/` is `chmod 600` and gitignored. Neither the key nor a token is ever
   committed, logged, printed in a board comment, or put in a git remote URL.

6. **Check it.**

   ```bash
   bin/gh-token.sh example-org/<repo> | head -c 4     # -> ghs_   (an installation token)
   bin/gh-token.sh --status                         # remaining/limit per cached token
   tail /root/harness/logs/gh-rate.log              # one line per MINT, counts only
   ```

   A token beginning `ghp_`/`github_pat_` means the fallback answered: the App is
   not armed (no `env/github-app.env`, `GH_APP_TOKENS=0`, `flags/gh-app-tokens-off`)
   or the mint failed — `bin/gh-token.sh <slug>` without `2>/dev/null` says which.

### The App is an AUTHOR too (2026-09-14)

A PR opened on an installation token is authored by **the App**, not by the PAT's owner:

```bash
gh pr view 696 -R example-org/project-5 --json author
# {"author":{"login":"app/cromford","is_bot":true}}
```

Everything that finds harness PRs — the merge conductor, the merge sweep, both reviewers,
the rebase train, pipeline health, the tickets snapshot, the cost rollup, the triage gate —
recognises them by the **author set `HARNESS_PR_AUTHORS`** (`bin/lib/gh-pr-list.sh`), default
`operator app/cromford`. **Nothing to set:** the default covers the fleet's App, and
`bin/lib/gh-pr-list.sh` also unions in `app/<GH_APP_SLUG>` when that file names one, so an
App with a different name needs the one line in step 5 above and nothing else. A box with a
different PAT owner sets the whole set once in `env/global.env`:

```
HARNESS_PR_AUTHORS="someoperator app/their-harness"
```

The set carries every spelling of the same actor, because the APIs disagree: `gh pr list
--json author` says `app/cromford`, the REST `pulls` endpoint says `cromford[bot]`,
a git author name says `cromford`.

*Why it is written down:* on 2026-09-14 those consumers still asked for `--author operator`,
so App-authored PRs were invisible to all of them. project-5 #696 and #697 — reviewed
APPROVE, CI green — sat unmerged with zero merge-conductor log lines while #737, opened on
the PAT the same day, was enqueued normally.

### Tokens that outlive a build (2026-09-14)

An installation token lives **exactly one hour**. A pool build takes **40-75
minutes**. Those two numbers were never compared, and on 2026-09-14 they met:
project-5 TK-680/681/682 were spawned 13:29Z on a token minted 12:42Z, built
cleanly, and their pre-PR push at 13:53-14:01Z answered

```
remote: Invalid username or token. Password authentication is not supported for Git operations.
```

Three finished builds were thrown away and requeued; seven more machines were
destroyed and the fleet was put back on the PAT with `flags/gh-app-tokens-off`
while it was fixed. Three things now make an App token safe for a build longer
than an hour, and all three are on by default once the App is armed:

1. **Spawn-time freshness.** A pool bundle never ships a token with less than
   `POOL_GH_TOKEN_MIN_LIFE` (default 3300s = 55 min) of life left.
   `bin/fly-pool.sh` asks for it with `bin/gh-token.sh --min-life <sec>`, which
   treats a cached token with less life than that as stale and mints a new one
   (and caches it, so the next asker pays nothing).

2. **Rotation under a running build.** The hub's pool tick already walks every
   live machine, so it is where a token about to die is replaced. A machine whose
   bundled token is within `POOL_GH_TOKEN_ROTATE_BEFORE` (default 1200s = 20 min)
   of expiry is handed a fresh one over the same console push the spawn uses, to
   `/run/harness-env/gh-token` (mode 600) — never more often than
   `POOL_GH_TOKEN_ROTATE_EVERY` (default 1800s = 30 min) per machine. The expiry
   rides on the machine record (`state/fly-pool/<project>/<machine-id>.json`,
   field `gh_token_expires_at`), so "is this one due" costs a date comparison
   against a local file and no GitHub call at all.

   ```
   2026-09-14 14:31:50Z [pool/project-5] rotated App token on adbff3e8db077c for example-org/project-5 (expires 15:31Z)
   ```

   A replacement is shipped **only when it is genuinely newer**. `bin/gh-token.sh`
   prints the fleet PAT rather than nothing when a mint fails, and a PAT has no
   cache expiry — so an expiry that did not move forward means no mint happened,
   the push is refused, and the machine keeps what it has. That is what stops a
   rotation from putting the permanent credential back on a builder.

3. **Resolution at the moment the token is spent.** A running process cannot
   re-source its own environment, so nothing reads the rotated token unless it is
   asked for at call time:
   - `bin/lib/gh-token-live.sh`'s `gh_token_live` exports `GH_TOKEN` from
     `/run/harness-env/gh-token` when that file exists and is non-empty, and
     leaves the environment untouched otherwise. `bin/run-build.sh` calls it
     immediately before every branch push, the pre-PR push, `gh pr create` and
     the builder-direct close-out; `bin/board-closeout.sh` calls it before its
     `gh issue comment`.
   - `fly/gh-credential.sh` is a five-line git credential helper reading the same
     file, installed by `fly/builder-runner.sh` as
     `credential.https://github.com.helper` **only when the file is present**, so
     plain `git push` picks up a rotation too. Without the file, git keeps the
     `gh auth setup-git` helper it has today.

   ```bash
   # on a pool machine, if you ever need to see which token a build would use now
   stat -c '%a %n' /run/harness-env/gh-token      # -> 600 /run/harness-env/gh-token
   git -C /data/repos/<project> config --get credential.https://github.com.helper
   ```

Every knob above is read from the environment or `env/global.env` on the hub, so
a project whose builds run longer than 75 minutes is one line, not a code change.

### What changes once it is armed

| Lane | What it does |
|---|---|
| `bin/run-build.sh` | resolves `GH_TOKEN` once after sourcing `global.env`; every `gh` call and `git push` in the build uses the repo-scoped token, and `gh_token_live` re-reads the rotated one immediately before each push, `gh pr create` and the close-out |
| `bin/merge-conductor.sh` | `use_token` asks for an App token before the PAT probe (`docs/MERGE-CONDUCTOR.md` §7.1) |
| `bin/fly-pool.sh` | replaces the `GH_TOKEN=` line in each machine's env bundle with a token minted **for that machine** (asking for `POOL_GH_TOKEN_MIN_LIFE` of life), writes the same token to `/run/harness-env/gh-token`, records its expiry on the machine record, and rotates it under long builds |
| `fly/builder-runner.sh` | installs `fly/gh-credential.sh` as git's credential helper when `/run/harness-env/gh-token` is present, so `git push` reads the token at call time rather than at boot |
| `bin/wake-loop.sh` | keeps the cache warm once per invocation so no build or merge pays for a mint (`docs/EVENTS.md` §8.1) |

Not yet on App tokens, stated so nobody assumes otherwise: the conductor's
**rebase** fetch/push still resolves a PAT inside `mc_git_auth`, and the per-box
lanes not listed above (`merge-sweep.sh`, `review-prs.sh`, `deploy-train.sh`,
`postmerge-qa.sh`, …) still use the PAT for everything they do. They are
unchanged and working; moving them is follow-up work, not a regression here.

**The one exception, and it is read-only.** `bin/lib/gh-ci-read.sh` gives the
box-side **Actions reads** a second credential: `gh api repos/<slug>/actions/runs`
runs on the default token exactly as it always has, and only when that read FAILS
does it retry once with `bin/gh-token.sh --read <slug>`. Callers today:
`bin/review-prs.sh` (the re-review CI debounce), `bin/merge-sweep.sh` (the
rebase-note supersede and both UNSTABLE discounts) and `bin/lib/flaky.sh`. One
line per fallback lands in the caller's log (`logs/gh-ci-read.log` by default)
naming which credential answered — never the credential itself.

`--read` (equivalently `GH_TOKEN_READ=1`) deliberately **ignores
`flags/gh-app-tokens-off` and `GH_APP_TOKENS=0`**. Those two guard writes and
authorship — who pushes, who opens a PR, whose identity lands on a commit — and
a GET of a workflow-run list is none of that. It ignores nothing else: with no
App credentials on the box it prints the PAT like every other invocation, and
the pool's `GH_APP_ROTATE` / `flags/gh-app-rotate-off` semantics are untouched.
To stop the read-only path as well, remove `env/github-app.env`.

Why it exists (2026-09-14): the project-2 box's fine-grained PAT answers 403
"Resource not accessible by personal access token" on `actions/runs`,
`check-runs`, `commits/status` AND the `statusCheckRollup` GraphQL for
`example-org/project-2`. `review-prs.sh` read that as "CI status unavailable",
deferred every re-review, alerted once at 12h and then went quiet — three of
collaborator-1's PRs sat for days. An App installation token reads the same endpoint
fine.

### Turning it off

Any one of these, no deploy needed, effective on the next call:

```bash
touch /root/harness/flags/gh-app-tokens-off              # per box, instant
sed -i 's/^GH_APP_TOKENS=.*/GH_APP_TOKENS=0/' /root/harness/env/github-app.env
rm /root/harness/env/github-app.env                      # or just never create it
```

Every lane then resolves the PAT exactly as it did before, and the unarmed path
forks no extra process. No pool machine gets `/run/harness-env/gh-token`, so
`gh_token_live` is a no-op and `fly/builder-runner.sh` keeps the
`gh auth setup-git` credential helper — the whole path is off, not half off.

To stop **only** the mid-build rotation and keep the spawn-time swap:

```bash
touch /root/harness/flags/gh-app-rotate-off              # per box, instant
# or GH_APP_ROTATE=0 in env/global.env (or the environment)
```

Pool machines still boot with a repo-scoped token; the hub simply stops replacing
it while they run, which is the pre-2026-09-14 behaviour — including its failure
mode on builds longer than the token's hour.

### Rotating the key

Generate a second private key in the App's settings **before** removing the
first — GitHub allows two — swap the `.pem` on every box, confirm
`bin/gh-token.sh <slug>` still prints a `ghs_` token, then delete the old key.
Cached tokens in `state/gh-app-tokens/` outlive the rotation by up to an hour and
keep working; they are signed artifacts, not derived from the key at use time.

---

## The box clock — `bin/clock-sync.sh`

These are Orgo containers: init is `init.sh`, and there is no systemd, no ntpd
and no chrony on them. On 2026-09-14 every fleet box measured **66-464 seconds
SLOW** (the hub ~7s). That is not cosmetic. `bin/gh-token.sh` hands out a cached
App token while it still has 300s of life *by this box's clock*, so a box 444s
slow hands out tokens GitHub has already expired and the build dies mid-push
with `Invalid username or token`; the App JWT's `iat`/`exp` margins and every
`deferred_at` age comparison drift with it too.

`*/30 * * * * /root/harness/bin/clock-sync.sh` runs on every box and on the hub
(an operator line, outside the managed blocks in `cron/*.cron`). It:

- does **nothing** when an NTP daemon is actually running (`timedatectl`
  `NTPSynchronized=yes`, or a live `chronyd`/`ntpd`/`systemd-timesyncd`) — two
  writers is how a clock oscillates;
- otherwise reads the `Date` header of `https://api.github.com` (falling back to
  `https://www.cloudflare.com`) and, when `|offset| > 30s`, sets the clock with
  `date -s`;
- logs one line either way to `logs/clock-sync.log`
  (`clock-sync: offset=-444 set (source=https://api.github.com)`), and is
  idempotent — the tick after a set finds nothing to do;
- writes ONE `ALERTS.log` line a day if `date -s` is denied (no `CAP_SYS_TIME`),
  naming what is needed and from whom. `date -s` works in these containers
  today; the alert is for the box where it stops working.

Off with `CLOCK_SYNC=0` in `env/global.env`, or `touch flags/clock-sync-off`.
Knobs: `CLOCK_SYNC_TOLERANCE` (default 30s), `CLOCK_SYNC_SOURCES`,
`CLOCK_SYNC_TIMEOUT`. Pinned by `tests/clock-sync-test.sh`.

---

## Rotating the shared secret

One value is held by every box and every Worker, so the order matters. Workers
first, boxes second, and expect a window in between where boxes cannot reach the
coordination plane — which is survivable, because `bin/jobs-client.sh` fails
open by contract: an unreachable or unauthorised worker returns nonzero, prints
nothing, and the pipeline behaves exactly as it did before the database existed.

```bash
NEW=$(openssl rand -hex 32)
printf '%s' "$NEW" | npx wrangler secret put HARNESS_SECRET   # in worker/jobs
# then, on every box:
sed -i "s|^HARNESS_SECRET=.*|HARNESS_SECRET=$NEW|" /root/harness/env/global.env
```

Do **not** rotate the watchdog's value at the same time. It is separate
precisely so that the thing which tells you a rotation went wrong is not part of
the rotation.

## The Fly builder pool

Optional. One ephemeral Fly machine per build instead of a build on the watcher
box. It exists because per-second billing on 8 dedicated cores beats a
permanently-provisioned box, and because a wedged VM took a whole box down once
(`bin/fly-pool.sh:2-21`).

**Skipping it breaks nothing.** Every Fly script self-gates on the absence of
`env/fly.env` and exits 0 quietly; without `flags/builder-fly-<project>` the
build simply runs locally, which is the original path
(`bin/run-build.sh:78`, `bin/fly-dispatch.sh:45`).

If you do want it: a dedicated Fly org (builders must not share an org with
anything else), `env/fly.env` with `FLY_ORG` and a bootstrap `FLY_API_TOKEN`,
then `bin/fly-image-build.sh` on a host with Docker followed by
`bin/fly-provision.sh <project>` on the hub. Per-app deploy tokens are minted
automatically and scoped so a leaked one can start and stop **one** builder.

Four flags control it: `builder-fly-<project>` routes builds to the queue,
`fly-pool-<project>` enables the pool (a NUMBER in it is an optional hard
ceiling; empty means no ceiling), `fly-pool-app-<project>` names
the pool's own app — **without it the pool is reap-only and refuses to spawn**,
a guard added after pool machines multiplied uncontrollably in the wrong app —
and `pool-halt-<project>` brakes spawning after two consecutive context-gate
refusals.

Note that the pool resolves the owning box through `fleet.conf --tailnet-ip` and
fails closed when column 7 is empty.

**One tick spawns the whole burst (2026-09-13).** A spawn is ~40-60s of waiting
(`machine run`, boot, harness push, env bundle), and `bin/fly-pool.sh` used to do
them one after another — 14 queued jobs took seven ticks to reach a pool that
could have held them at once. The tick now computes its budget once, launches
that many spawns concurrently, and waits for all of them.

**The budget is queue depth, and there is no default cap (2026-09-14).** "We can
launch unlimited builders with fly.io" — so `bin/pool-cap.sh` answers `0` (no
ceiling) unless a number is configured, and a tick spawns one machine per queued
build. `bin/fly-pool-tick.sh` runs every project's tick concurrently for the
same reason: a tick waits ~60s for its own spawns, so a sequential sweep made
the ninth project's pool wait on the first eight. Each tick self-locks per
project (`flock -n`), so nothing overlaps itself.

- A number in `flags/fly-pool-<project>` or a line in `fly/pool-caps.conf` is
  still a hard ceiling — a **cost** decision now, not a capacity one.
- `POOL_CAP_MAX` in `env/global.env` is the fleet-wide brake (unset = unlimited)
  and trims every project at once.
- The number every box already had in `flags/fly-pool-<project>` (2, then 10,
  then 20) is retired by the first tick after this lands: the file stays, since
  its presence enables the pool, the old value is kept in
  `state/fly-pool/legacy-caps.<project>`, and one line says so in
  `logs/fly-pool.log`. It happens once per project — a number written after that
  stands.
- `POOL_AUTOSCALE=0` in `env/global.env` restores the pre-2026-09-14 behaviour
  byte-for-byte: default 3, `cap - live`, sequential sweep, no retirement.
- Every tick logs `pool <p>: queued=N running=M spawning=K cap=unlimited|C` to
  `logs/fly-pool.log`.

The cap is still `bin/pool-cap.sh` and nothing else reads that ladder —
see docs/BUILD-CONCURRENCY.md.

### Onboarding ONE project onto the pool (BH-662)

`bin/fly-onboard.sh <project> [--cap N]`, **on the hub**. It wraps
`bin/fly-pool-rollout.sh` for exactly one project: ensure the token, the
`builder-<p>` and `pool-<p>` apps and the image, run a real SMOKE on a real pool
machine, and — only on `SMOKE_OK`, and only inside the rollout — write the
routing flags. It writes no flag of its own, so "routed without a green probe"
cannot happen.

The shape of what it prints (also appended to `logs/fly-pool-rollout.log`) — the
step lines are the rollout's own, the last line is the verdict:

```
start (cap unset → autoscale)
<stamp> [<p>] image: registry.fly.io/builder-<p>:<deployment>
<stamp> [<p>] SMOKE_OK on pool machine <machine-id>
FLY_ONBOARD <p> OK: /root/harness/flags/fly-pool-<p>=present(cap unlimited) /root/harness/flags/builder-fly-<p>=present free-slots="unlimited (fly-routed: ...)"
```

- `--cap N` writes a hard ceiling into `flags/fly-pool-<p>`. Unset is the default
  and means autoscale. `--cap 0` / `--cap abc` are **refused** (rc 2), never
  clamped.
- Already routed → `ALREADY`, rc 0, and **zero** flyctl calls. Re-running it is
  free.
- Failure → rc 1, neither flag written, and ONE line in `logs/ALERTS.log`:
  `[fly-onboard] <p> onboarding FAILED at "<step>" — …`.
- Off the hub → rc 3 with the reason, before any flyctl call. Use the queue
  instead (below).

**Queue it from anywhere, with no ssh:** `bin/load-project.sh <owner>/<repo>
--fly` appends the project to `fly/onboard-queue.conf` **in the loader's own
commit**, or add the line by hand and merge. `bin/fleet-propagate.sh` (\*/5)
syncs `fly/` to the hub and the `fly-onboard-drain` block in
`bin/fly-pool-tick.sh` (\*/10) runs `bin/fly-onboard.sh` there. Retries are
bounded: `FLY_ONBOARD_MAX_ATTEMPTS` (default 3) attempts,
`FLY_ONBOARD_RETRY_MIN` (default 360) minutes apart, ledgered in
`state/fly-onboard/<p>.attempts` and `.last`, then one give-up ALERTS line.
Drive it all with `tests/fly-onboard-*-test.sh`.

---

## What Path B is missing

**The console backend is not in this repository yet.** It will be published as its own repository.

The console is the Worker that holds the Telegram bot, the command queue the hub
polls, and the operator dashboard. `console-ui/` in this repo is only the
front-end single-page app; the API contract it is written against lives with
that Worker.

Without it, concretely:

| Works | Does not |
|---|---|
| Triage, plan, build, review, PR, preview QA | The Telegram bot, and every `/command` through it |
| The merge lanes and tiers | `bin/poll-commands.sh`, so console-issued commands never arrive |
| Cost capture and the rollup | The dashboard |
| The jobs worker and all coordination | `bin/beat.sh` alert delivery to a chat |
| The watchdog, including Telegram paging | Setting a pause flag from anywhere but the box |

So the pipeline runs and pages you; what you lose is the remote control surface.
`CONSOLE_URL` and `HARNESS_SECRET` are required by
`bin/bootstrap-machine.sh`, so point `CONSOLE_URL` at any URL that 404s
politely and the beats will fail soft.

Publishing the console backend is planned. Until it lands, **Path B is
complete except for the control surface**, and this document will be wrong
about that the day it changes.

---

## Verifying it works

In order, because each depends on the last:

```bash
PROJECT=myproj                                                # your column-1 name
bin/fleet-conf.sh --projects                                  # the registry parses
set -a; . env/global.env; set +a
bin/jobs-client.sh lanes                                      # the worker answers
curl -X POST "$WATCHDOG_URL/api/test-alert?s=$(cat env/.watchdog-secret)"
bin/healthcheck.sh "$PROJECT"                                 # your app is reachable
bin/run-triage.sh "$PROJECT"                                  # one real tick
```

`bin/healthcheck.sh` exits 0 immediately if column 3 is `-`.

**A clean triage tick is not acceptance.** On a fresh project there is nothing
labeled `ai-build`, so the tick correctly does nothing — and a zero-work success
is indistinguishable from a completely broken input path. The acceptance test is
a real pull request:

```bash
gh issue create -R <owner>/<repo> -t "Add a /version route" \
  -b "Acceptance: GET /version returns 200 with the deployed sha." \
  --label ai-build
```

**To force a build without waiting for a tick**, triage is not the command —
it only decides RUN or SKIP. The builder takes three arguments
(`bin/run-build.sh:3`):

```bash
# usage: run-build.sh <project> <ticket-id> <ticket-key>
# GitHub-Issues lane: the issue number is the id, the key is <PREFIX>-<number>.
# Read the prefix out of the rendered prompt rather than deriving it — the
# default is the project name's initials, and --prefix may have overridden it.
grep -m1 -oE '\b[A-Z]{1,6}-' "prompts/$PROJECT.md"
bin/run-build.sh "$PROJECT" 41 MP-41
```

That runs plan → execute → review → PR in the foreground, which is also the
fastest way to find out that a credential is missing.

### What the first day looks like

Two alarms are expected before anything is wrong:

- The watchdog pages about **stale owed tickets** and an **unpriced model** on a
  schedule, and on day one there is no history for either. Give it 24 hours
  before treating those as signal.
- A box with no `watchdog-ping` cron line is not alerted on at all, because the
  watchdog skips boxes it has never heard from. Silence there is not health.

> The end-to-end sequence in this section has not been executed against a blank
> Cloudflare account and a fresh VM while writing this document. The individual
> commands are read from the scripts that implement them. The two `wrangler`
> creation lines are the ones most likely to need adjusting, since the committed
> configuration points at databases that already exist.
