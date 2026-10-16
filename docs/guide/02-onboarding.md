---
title: Onboarding a repo
description: Add a repo to Cromford, study it, and give it a Verification Contract.
order: 2
---

# Onboarding a repo

Adding a repo is one setting and one command. Good builds need one more
thing: Cromford must know how your repo installs, tests and builds.

## Add it to your settings

List the repo in `SELFHOST_PROJECTS` in `selfhost.conf`, as `name=owner/repo`.
The name is lowercase letters, digits and hyphens. Separate projects with
spaces. Run the dry-run again. With `SELFHOST_POOL=fly`, each project gets its
own build app and volume in the plan.

## Study it first

Run the study pass on a local checkout of the repo:

```bash
bin/onboard-study.sh <repo-dir>
```

It reports the install, test, build, lint and deploy commands it found, a
draft Verification Contract, a readiness grade and any deploy config. It calls
no model and runs none of your repo's code. Its one write is the `.codegraph/`
index inside the checkout. Add `--json` for a machine-readable report.

The enroll command below does not run the study pass. Run it by hand.

## Enroll it on the hub

```bash
bin/load-project.sh <owner/repo> --project <name> --box <box>
```

This needs a running hub. It adds the project to `fleet.conf`, renders its
prompt, commits and pushes to your fork, creates the `ai-build` label on the
repo, and sets up the box. Always pass `--box`. The script's header explains
its other flags.

Enrolling builds nothing. Cromford acts only on issues with the `ai-build`
label.

Per-project secrets and settings go in the project's own env file under
`/etc/harness/env/`. `env-templates/project.env.example` lists them.

## What the repo needs

- **A `CLAUDE.md` at the root with a Verification Contract.** Add a
  `## Verification Contract` heading. The first fenced block under it is the
  command Cromford runs to check a build, for example
  `npm ci && npm run lint && npm test && npm run build`. Keep deploys out of
  it. The study pass prints a draft you can start from.
- **CI on pull requests.** The merge gate reads your checks. A repo with no CI
  gives it nothing to gate on.
- **The `ai-build` label.** The enroll step creates it.
- **Optional: a CodeGraph index.** A repo with a `.codegraph/` directory gets
  a code graph pass before each plan.

## Browser QA

A repo with a web UI needs browser QA wired: a preview row, a prod URL, a QA
account and a deploy kind. The enroll step prints a `== browser QA ==` block
with one line per item. To check again, run this on the hub:

```bash
bin/qa-wiring-check.sh <name>
```

[Onboarding a repo](../onboarding-a-repo.md#wire-browser-qa) explains each
item and how to exempt a project with no web UI.

## Your first ticket

Start small: a copy change or a small fix you can check in a minute. If
triage asks a question, answer it in the thread. When the PR opens, read the
plan and the review before the code.
