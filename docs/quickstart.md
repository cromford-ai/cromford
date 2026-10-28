# Quickstart

This takes you from a clone to your first pull request on your own accounts.
It's the short version. The [deployment guide](SELF-HOST.md) has the detail,
and this page links to it instead of repeating it.

One thing first. `bin/selfhost-install.sh` plans your install, but the step
that creates the resources (`--apply`) is not built yet. Today it exits 2 and
touches nothing. So you check your settings with the dry-run, then create the
resources by hand.

## What you need

- A GitHub account, plus a GitHub App or a personal access token.
- A Cloudflare account (D1, Workers, KV, R2, Pages).
- A Fly account, or a Linux VM you already run.
- a model key for at least one of: Claude, Codex, Grok, OpenRouter, Fireworks.

Some stages still need Claude today, and the installer only asks for a Claude
credential. [What still needs Claude today](choosing-models.md#what-still-needs-claude-today)
lists them.

None of the rest is required. [Optional services that make it better](optional-services.md)
covers the merge queue, CI runners, chat alerts and the rest.

## Steps

**1. Clone the repo.**

```bash
git clone https://github.com/cromford-ai/cromford
cd cromford
```

You get a `cromford` folder. Every command below runs from inside it.

**2. Run the checks the public CI runs.**

```bash
bash tests/no-client-identifiers-test.sh
```

Expect exit 0. This is the leak guard the repo's own CI runs on every push.
To run the full suite, see `CONTRIBUTING.md`.

**3. Copy the settings template and fill it in.**

```bash
cp env-templates/selfhost.conf.example selfhost.conf
```

Fill in `selfhost.conf`, one `KEY=value` per line. Secrets never go in it.
The [settings table](SELF-HOST.md#3-fork-clone-configure) says what each key is
and where to find its value.

**4. Check the plan.**

```bash
bin/selfhost-install.sh --config selfhost.conf --dry-run
```

On the template as copied, this exits 1 and names every blank you still have
to fill. Once it's filled in, it exits 0, prints every resource, env line,
spend cap and secret name your install needs, and ends with
`SUMMARY ... live_calls=0 writes=0`. That means nothing was touched.

**5. Create the resources by hand.** Follow [Install](SELF-HOST.md#5-install)
in the deployment guide and [OPERATOR-SETUP](OPERATOR-SETUP.md). Your dry-run
gives you the exact names, env lines and secret names to use. Expect a running
hub you can reach.

**6. Connect a board.** GitHub Issues is the default and needs nothing beyond
your GitHub credential. [Connecting a board](connecting-a-board.md) covers Jira
and Linear, and what each one supports today. To use one of them, follow its
numbered steps: [Set up Linear](connecting-a-board.md#set-up-linear) or
[Set up Jira](connecting-a-board.md#set-up-jira). The user guide has the same
steps: [Set up Linear](guide/03-connectors.md#set-up-linear) and
[Set up Jira](guide/03-connectors.md#set-up-jira).

**7. Onboard a repo.** Follow [Onboarding a repo](onboarding-a-repo.md).
Expect the project in `fleet.conf`, the `ai-build` label on the repo, and a
Verification Contract in the repo's `CLAUDE.md`.

**8. Open your first ticket.** Open an issue on that repo with the `ai-build`
label. Write what you want and how you'll know it's right.

```bash
gh issue create -R <owner/repo> --label ai-build --title "<title>" --body "<what you want built>"
```

Expect a triage comment, then a plan, a build, a review, and a pull request.
