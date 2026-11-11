# Run Cromford on your own accounts

This guide takes you from a fork of this repo to a checked install plan for
your own Cloudflare, GitHub, Fly (or VM) and model accounts. Every command here
is checked against the code by `tests/selfhost-guide-commands.bh-4686-test.sh`,
so if a script or flag changes, that suite goes red until this page catches up.

## 1. What this guide does today

Read this first, because it sets what you can and can't do yet.

`bin/selfhost-install.sh` plans an install. It reads your settings, checks
them, and prints every resource, env line, spend cap and secret name the
install needs. It makes no network call and writes nothing. The step that
actually creates resources (`--apply`) is not built yet. Run it today and it
exits 2 without touching anything.

So the dry-run is how you prove your settings are complete. Creating the
resources is still done by hand, and
[docs/OPERATOR-SETUP.md](OPERATOR-SETUP.md) walks through that. This page links
to it and doesn't repeat it.

## 2. What you need

Accounts:

- A GitHub account that owns your fork, plus a GitHub App or a personal access token.
- A Cloudflare account (D1, Workers, KV, R2, Pages).
- A Fly account, or a VM you already run for the hub.
- A model credential: a Claude Code subscription token or an Anthropic API key.
- Optional: a Telegram bot or a Slack bot for alerts.

Here is every resource the plan can list. It comes straight from
[catalog/selfhost/resources.tsv](../catalog/selfhost/resources.tsv). `When` says
which settings turn a row on, `per-project` rows repeat once per project, and
`<KEY>` in a name is the value of that setting.

| Provider | Kind | Name | When | Secret names it needs |
|---|---|---|---|---|
| cloudflare | d1 | `harness-jobs` | always | `CLOUDFLARE_API_TOKEN` |
| cloudflare | d1 | `harness-locks` | always | `CLOUDFLARE_API_TOKEN` |
| cloudflare | worker | `harness-jobs` | always | `CLOUDFLARE_API_TOKEN`, `HARNESS_SECRET`, `GITHUB_WEBHOOK_SECRET` |
| cloudflare | worker | `harness-locks` | always | `CLOUDFLARE_API_TOKEN`, `HARNESS_TOKENS`, `ADMIN_TOKEN` |
| cloudflare | worker | `harness-watchdog` | always | `CLOUDFLARE_API_TOKEN`, `HARNESS_SECRET`, `STAMP_SECRET` |
| cloudflare | kv | `harness-watchdog` | always | `CLOUDFLARE_API_TOKEN` |
| cloudflare | r2 | `<BACKUP_S3_BUCKET>` | always | `CLOUDFLARE_API_TOKEN`, `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY` |
| cloudflare | pages | `<CONSOLE_PAGES_PROJECT>` | always | `CLOUDFLARE_API_TOKEN` |
| fly | app | `<HARNESS_HUB_BOX>` | hub=fly | `FLY_API_TOKEN` |
| fly | volume | `<HARNESS_HUB_BOX>/hub_data` | hub=fly | `FLY_API_TOKEN` |
| vm | host | `<SELFHOST_HUB_HOST>` | hub=vm | none |
| fly | app | `builder-<project>` | pool=fly, per-project | `FLY_API_TOKEN` |
| fly | volume | `builder-<project>/builder_data` | pool=fly, per-project | `FLY_API_TOKEN` |
| github | app-installation | `<HARNESS_GH_OWNER>` | gh=app | `GH_APP_ID`, `GH_APP_PRIVATE_KEY_FILE` |
| github | pat | `<HARNESS_GH_OWNER>` | gh=pat | `GH_TOKEN` |
| model | oauth-token | `claude-code` | model=oauth | `CLAUDE_CODE_OAUTH_TOKEN` |
| model | api-key | `anthropic` | model=api-key | `ANTHROPIC_API_KEY` |
| chat | telegram-bot | `telegram` | chat=telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| chat | slack-bot | `slack` | chat=slack | `SLACK_BOT_TOKEN` |

**Cost.** The catalog has no price column, so this page gives no dollar
figures. Here's what your bill scales with:

- The hub: one Fly app and one volume, or the VM you already pay for.
- The build pool: one Fly app and one volume per project when `SELFHOST_POOL=fly`.
- Model spend, which is per call. This is the part the caps in section 8 hold down.
- The Cloudflare resources above. They're small, but they're on your account.

## 3. Fork, clone, configure

Fork and clone in one step with the GitHub CLI:

```bash
gh repo fork <upstream-owner>/<repo> --clone
```

Or clone a fork you already made:

```bash
git clone https://github.com/<you>/<repo>.git
```

Run everything below from the root of your clone. Copy the settings template:

```bash
cp env-templates/selfhost.conf.example selfhost.conf
```

Now fill in `selfhost.conf`, one `KEY=value` per line. The file is read as
data, never sourced. An unknown key or a key set twice is refused, so a typo
can't quietly fall back to a default. Blank values are blank on purpose:
nothing defaults to someone else's account.

| Key | What it is | Where to get it |
|---|---|---|
| `SELFHOST_CF_ACCOUNT_ID` | Your Cloudflare account id, 32 hex characters | The Cloudflare dashboard sidebar |
| `HARNESS_WORKERS_SUBDOMAIN` | Your workers.dev subdomain. The jobs worker is served at `harness-jobs.<subdomain>.workers.dev` | Cloudflare dashboard, Workers overview |
| `CONSOLE_PAGES_PROJECT` | The Pages project name the console deploys to | Pick a name that's free in your account |
| `BACKUP_S3_BUCKET` | The R2 bucket the state backup writes to | Pick a name that's free in your account |
| `HARNESS_REPO` | Your fork, as `owner/repo` | Your fork's GitHub URL |
| `HARNESS_GH_OWNER` | The GitHub owner the App or token acts on. Leave it blank to use the owner half of `HARNESS_REPO` | Your GitHub user or org name |
| `HARNESS_OPERATOR_LOGIN` | Your GitHub login, used to filter PR authors | Your GitHub profile |
| `HARNESS_GIT_NAME` | The commit name the boxes use. Merge and bot commits use it too | Your choice |
| `HARNESS_GIT_EMAIL` | The commit email the boxes use | Your choice. A GitHub noreply address works |
| `SELFHOST_GH_AUTH` | `app` for a GitHub App installation (recommended) or `pat` for a personal access token | Your choice. Install the App, or scope the token, only on the repos the harness watches |
| `HARNESS_BOX_PREFIX` | The box name prefix. A project with no box set is owned by `<prefix><project>` | Your choice, for example a short tag and a hyphen |
| `HARNESS_HUB_BOX` | The hub's name (and its Fly app name when the hub is on Fly) | Your choice |
| `SELFHOST_HUB` | `fly` to run the hub as a Fly app, `vm` for a VM you already have | Your choice |
| `SELFHOST_HUB_HOST` | The VM's hostname or address. Needed only when `SELFHOST_HUB=vm` | Your VM provider |
| `FLY_ORG` | Your Fly org. Needed when the hub or the pool is on Fly | The Fly dashboard |
| `SELFHOST_POOL` | `fly` for one build app per project, `local` to build on the hub | Your choice |
| `SELFHOST_PROJECTS` | The repos to watch, space-separated `name=owner/repo`, where `name` is lowercase letters, digits and hyphens | The repos you want built |
| `SELFHOST_MODEL_AUTH` | `oauth` for a Claude Code subscription token, `api-key` for an Anthropic API key | Your choice |
| `SELFHOST_RUNNER_LOCK` | `claude` to keep every project on Claude, with no fallback to a non-Claude runner. Blank means no lock | Your choice. Ships blank |
| `SELFHOST_CHAT` | `none`, `telegram` or `slack` | Your choice. Ships as `none` |
| `SELFHOST_CAP_USD_PER_CALL` | The dollar cap on one agent call. Ships as `5` | See section 8 |
| `SELFHOST_CAP_USD_DAY` | The dollar cap per lane per day. Ships as `20` | See section 8 |
| `SELFHOST_CAPS_OFF` | Set to `1` to turn the caps off. Blank or `0` keeps them on | See section 8 |

**Secrets never go in this file.** No tokens, keys or passwords. The installer
refuses any key whose name ends in `TOKEN`, `SECRET`, `API_KEY`, `PASSWORD` or
`PRIVATE_KEY`. Secrets live only under `/etc/harness/env/` on the box. The dry-run
prints the names of the ones your settings need, from this list:
`CLOUDFLARE_API_TOKEN`, `HARNESS_SECRET`, `GITHUB_WEBHOOK_SECRET`,
`HARNESS_TOKENS`, `ADMIN_TOKEN`, `STAMP_SECRET`, `BACKUP_S3_ACCESS_KEY_ID`,
`BACKUP_S3_SECRET_ACCESS_KEY`, `FLY_API_TOKEN`, `GH_APP_ID`,
`GH_APP_PRIVATE_KEY_FILE`, `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
`ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `SLACK_BOT_TOKEN`.
With `SELFHOST_MODEL_AUTH=api-key` the dry-run also names one
`ANTHROPIC_API_KEY_<PROJECT>` per project (the project name in upper case, `-`
as `_`). It is a Fly secret on that project's app. It never goes in this file.

Least privilege for each credential:

- Cloudflare: an API token limited to your one account, with edit rights only on D1, Workers, KV, R2 and Pages.
- Fly: a token for your `FLY_ORG` only.
- GitHub: an App installed only on the repos the harness watches, or a token limited to the same repos.
- R2 backup keys: read and write on your `BACKUP_S3_BUCKET` only.

## 4. Dry-run

```bash
bin/selfhost-install.sh --config selfhost.conf --dry-run
```

`--dry-run` is the default and the only mode built. A good run exits 0 and
prints, in this order:

- `RESOURCE <provider> <kind> <name> <action> from=<setting>`. Each row is one
  resource. The action is `create`, `recorded` (already in your ledger, see
  below), or `skip(<term>)` when a setting turns that row off.
- `ENV <KEY>=<value>`. Each line is one the box's `env/global.env` needs.
- `CAP ...`. The spend caps, see section 8.
- `SETTING <key>=<value>`. The per-project settings rows `claude_auth.<project>`,
  `runner_lock.<project>` and `cost_ceiling.<project>` (`SELFHOST_CAP_USD_DAY`,
  or `skip(caps off)`). They print only with `SELFHOST_MODEL_AUTH=api-key` or
  `SELFHOST_RUNNER_LOCK=claude`.
- `SECRET <NAME> needed-by=<row ids>`. Each secret your settings need, and which rows need it.
- `SUMMARY resources=<n> create=<n> recorded=<n> skipped=<n> live_calls=0 writes=0`.
  `live_calls=0 writes=0` is the promise that nothing was touched.

If you've already built some resources by hand, list them in a ledger so the
plan shows them as `recorded`. The ledger is `<state-dir>/ledger.tsv`, one
tab-separated line per resource: provider, kind, name, id, created_at. The
dry-run reads it and never writes it.

```bash
bin/selfhost-install.sh --config selfhost.conf --dry-run --state <state-dir>
```

Exit codes: 0 means the plan printed, 1 means your settings were refused (every
problem is named in one message), 2 means bad usage or `--apply`, 3 means the
catalog file is malformed.

## 5. Install

Not built yet. `bin/selfhost-install.sh --apply` exits 2 and creates nothing.
Until it ships, build the resources from your dry-run plan by hand, following
[docs/OPERATOR-SETUP.md](OPERATOR-SETUP.md). The plan gives you the exact names,
env lines and secret names to use.

## 6. Onboard your first repo

Once your hub is up, enroll a repo:

```bash
bin/load-project.sh <owner/repo> --project <name> --box <box>
```

This needs a running, bootstrapped box. It adds the project to `fleet.conf`,
renders its prompt, commits and pushes to your fork, creates the `ai-build`
label on the repo, then runs the bootstrap on the box over ssh. Run it from a
checkout with push access, an authed `gh`, and ssh to the box. Always pass
`--box`: the built-in default box name belongs to another deployment. Other
flags it takes include `--prod <url>`, `--base <branch>`, `--no-bootstrap` and
`--fly`; its header comment explains each one.

Loading a project builds nothing on its own. The watcher only acts on issues
labeled `ai-build`.

## 7. First ticket, first PR

Open an issue with the label:

```bash
gh issue create -R <owner/repo> --label ai-build --title "<title>" --body "<what you want built>"
```

What happens next: triage reads the whole thread and decides whether it's
ready. If the last word is an open question to you, it waits. A ready ticket
gets a written plan that ends in named acceptance tests, then a build, then a
review by a separate session, then a PR. The PR is the output. Merging only
happens through the harness's own gates, never from the build session. The
README's pipeline table lists what each stage refuses.

Once it is running, read [OPERATING.md](OPERATING.md): what goes wrong day to
day, what the factory does about it, and the defaults you start with.

## 8. Spend caps

The caps are on by default, because the bill is yours. The template ships with:

- `SELFHOST_CAP_USD_PER_CALL=5`, which the dry-run prints as `CAP AGENT_CALL_BUDGET_USD=5`: at most $5 on one agent call.
- `SELFHOST_CAP_USD_DAY=20`, which it prints as `CAP LLM_USD_CAP_DAY=20`: at most $20 per lane per day.

Both must be positive numbers. `0` does not mean unlimited. The only way to
turn the caps off is `SELFHOST_CAPS_OFF=1`, and then the dry-run prints
`CAP off (SELFHOST_CAPS_OFF=1)`.

Once the harness is running, change a lane's daily cap with:

```bash
bin/harness-ctl.sh set <lane> LLM_USD_CAP_DAY <n>
```

Two things to know:

- The hub's triage lanes carry a second, older daily cap in
  [catalog/lane-caps.conf](../catalog/lane-caps.conf). The lower of the two is
  what you actually get, so raising `LLM_USD_CAP_DAY` alone may change nothing.
- There is no call-count or token cap yet. The dry-run says so on its
  `CAP calls/tokens` line. Dollars are the cap.

## 9. Upgrade

Pull upstream changes into your fork:

```bash
git remote add upstream https://github.com/<upstream-owner>/<repo>.git
git fetch upstream
git merge upstream/main
```

Then run the dry-run again. A new catalog row that isn't in your ledger shows as
`create`, which is how you spot a resource the new version needs. A new
required setting shows up as a refusal that names it.

```bash
bin/selfhost-install.sh --config selfhost.conf --dry-run
```

## 10. Uninstall

The dry-run created nothing, so there's nothing to undo from it. For resources
you built by hand, the table in section 2 is the list to delete, filtered by
your settings (your dry-run's `RESOURCE` lines show exactly which apply to
you). Remove them in each provider's dashboard or CLI, then delete the secrets
under `/etc/harness/env/` on each box. This page gives no delete commands
because there's no install ledger to drive them yet.

## 11. Troubleshooting

The five failures you're most likely to hit, with the exact text the installer
prints.

**The template as shipped.** Running the dry-run on a fresh copy prints
`selfhost-install: refused selfhost.conf, nothing planned:` followed by one
line per required blank, starting with `SELFHOST_CF_ACCOUNT_ID is blank`.
Cause: the template is blank on purpose. Fix: fill in every key the message
names (section 3), then run it again.

**`SELFHOST_CF_ACCOUNT_ID is not 32 hex characters`.** Cause: you pasted
something other than the account id, often the zone id, the account name, or a
value with upper-case letters. Fix: copy the 32-character lower-case id from the
Cloudflare dashboard sidebar.

**`GH_TOKEN looks like a secret; secrets never go in this file`.** The key name
varies. Cause: a key ending in `TOKEN`, `SECRET`, `API_KEY`, `PASSWORD` or
`PRIVATE_KEY` is in `selfhost.conf`. Fix: delete that line. Secrets go under
`/etc/harness/env/` on the box, never in this file.

**`FLY_ORG is blank and the hub or the pool is on Fly`.** Cause:
`SELFHOST_HUB=fly` or `SELFHOST_POOL=fly` with no Fly org. Fix: set `FLY_ORG`,
or switch to `SELFHOST_HUB=vm` and `SELFHOST_POOL=local` if you're not using Fly.

**`--apply is not built yet`, or `--config <file> is required`.** Both exit 2.
Cause: `--apply` was passed (it isn't built, see section 5), or `--config` was
left off. Fix: run the exact command from section 4.
