---
title: Quickstart
description: What Cromford is, and the steps from a clone to your first pull request.
order: 1
---

# Quickstart

## What Cromford is

Cromford watches your boards. When a ticket comes in, it reads the whole
thread and decides whether the ticket is ready to build. A ready ticket gets a
written plan, a build on its own branch, and a review by a separate session.
The result is a pull request. Merges go through Cromford's own gates, never
straight from a build.

You run it on your own accounts: GitHub, Cloudflare, Fly or a VM you already
have, and a key for at least one model vendor.

## What you need

- A GitHub account, plus a GitHub App or a personal access token.
- A Cloudflare account (D1, Workers, KV, R2, Pages).
- A Fly account, or a Linux VM you already run.
- A model key for at least one of: Claude, Codex, Grok, OpenRouter, Fireworks.

Some stages still need Claude today.
[What still needs Claude today](../choosing-models.md#what-still-needs-claude-today)
lists them. The rest is optional:
[Optional services](../optional-services.md) covers them.

## Steps

The installer plans your install, but its `--apply` step is not built yet.
Today `--apply` exits 2 and touches nothing. So you check your settings with
the dry-run, then you create the resources by hand.

**1. Clone the repo.** Every command below runs from inside the `cromford`
folder.

```bash
git clone https://github.com/cromford-ai/cromford
cd cromford
```

**2. Run the leak guard.** Expect exit 0.

```bash
bash tests/no-client-identifiers-test.sh
```

**3. Copy the settings template.** Fill in `selfhost.conf`, one `KEY=value`
per line. Secrets never go in it. The
[settings table](../SELF-HOST.md#3-fork-clone-configure) says what each key is.

```bash
cp env-templates/selfhost.conf.example selfhost.conf
```

**4. Check the plan.**

```bash
bin/selfhost-install.sh --config selfhost.conf --dry-run
```

On the template as copied, this exits 1 and names each blank you must fill.
When the file is filled in, it exits 0. It prints every resource, env line,
spend cap and secret name your install needs. The last line is
`SUMMARY ... live_calls=0 writes=0`, so nothing was touched.

**5. Create the resources by hand.** Follow
[Install](../SELF-HOST.md#5-install) and [Operator setup](../OPERATOR-SETUP.md).
Use the names, env lines and secret names your dry-run printed.

**6. Connect a board.** GitHub Issues is the default. See
[Connectors](03-connectors.md).

**7. Onboard a repo.** See [Onboarding](02-onboarding.md).

**8. Open your first ticket.** Open an issue with the `ai-build` label. Say
what you want and how you will know it is right.

```bash
gh issue create -R <owner/repo> --label ai-build --title "<title>" --body "<what you want built>"
```

Expect a triage comment, then a plan, a build, a review and a pull request.

The [deployment guide](../SELF-HOST.md) has the full detail for each step.
Set your [spending caps](../spending-caps.md) before the first build.
