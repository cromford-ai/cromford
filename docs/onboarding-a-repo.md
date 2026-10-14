# Onboarding a repo

Adding a repo is one setting and one command. Getting good builds out of it
takes a little more: Cromford needs to know how your repo installs, tests and
builds.

## Add it to your settings

List the repo in `SELFHOST_PROJECTS` in your `selfhost.conf`, as
`name=owner/repo`. The name is lowercase letters, digits and hyphens. Separate
several with spaces. Run the dry-run again: with `SELFHOST_POOL=fly`, each
project gets its own build app and volume in the plan.

## Enroll it on the hub

```bash
bin/load-project.sh <owner/repo> --project <name> --box <box>
```

This needs a running hub. It adds the project to `fleet.conf`, renders its
prompt, commits and pushes to your fork, creates the `ai-build` label on the
repo, and sets up the box. Always pass `--box`. The script's header explains
its other flags.

To add a machine to the fleet, see [Adding a box](ADDING-A-BOX.md).

Enrolling builds nothing by itself. Cromford only acts on issues labeled
`ai-build`.

Per-project secrets and settings go in the project's own env file under
`/etc/harness/env/`. `env-templates/project.env.example` lists them, with a
line on what each is for.

## Wire browser QA

Browser QA is required. Without it, Cromford merges builds that no browser has
opened, and nothing fails to tell you. At the end of the enroll step,
`bin/load-project.sh` prints a `== browser QA ==` block with one line per
item. Each line is `ok`, `OWED: <fix>`, or `UNKNOWN` when the probe could not
run where you ran it. The items, in the order the block prints them:

1. **A `vercel.conf` row** for the project. Without it, preview QA never runs.
2. **A real prod URL** in `fleet.conf`, not `-`. Without it, post-merge prod
   QA never runs.
3. **A QA account**: `QA_TEST_USER_ID` and `QA_CLERK_SECRET_KEY` in
   `env/<name>.env` on the hub, and a role for the project in
   `state/qa-accounts.json`.
4. **A deploy kind that is not `none`**: the settings row
   `deploy.<name>.kind` is `github-deployment` (also the default when there is
   no row) or `smoke-only`. With `none`, prod smoke is off.
5. **Clerk accepts the prod origin**: `GET https://<fapi>/v1/environment` with
   `Origin: <prod url>` answers 200. The FAPI host comes from the publishable
   key on the prod sign-in page. A Clerk production instance refuses an origin
   it does not list (`origin_invalid`), and then no QA account can sign in.

To check again, run `bin/qa-wiring-check.sh <name>` on the hub. It never prints
a key value, only `set` or `UNSET`. The daily `qa-wiring-sweep` hub lane runs
the same check for every project. It sends one alert per project per day until
every line is `ok`.

Set up the Clerk test account:

1. Create a user with a password in the PRODUCTION Clerk instance of the app.
2. On the hub, record the user id under the project, with a role, in
   `state/qa-accounts.json`.
3. Put the same user id in `env/<name>.env` as `QA_TEST_USER_ID`.
4. Put the production Clerk secret key in `env/<name>.env` as
   `QA_CLERK_SECRET_KEY`. Keep the file at chmod 600.
5. Serve prod on a domain the Clerk instance allows. Do not use a
   `*.vercel.app` host.

If the project has no web UI, exempt it with the settings row
`qa_wiring.<name>.exempt=<reason>`. The check then prints `exempt: <reason>`
and the lane does not alert.

## What the repo needs

- **A `CLAUDE.md` at the root with a Verification Contract.** Add a
  `## Verification Contract` heading. The first fenced block under it is the
  command Cromford runs to check a build, for example
  `npm ci && npm run lint && npm test && npm run build`. Keep deploys out of it.
  This repo's own [CLAUDE.md](../CLAUDE.md#verification-contract) is a worked
  example. An `AGENTS.md` is read as context, but the verify command only comes
  from `CLAUDE.md`.
- **CI on pull requests.** Cromford's merge gate reads your checks, so a repo
  with no CI has nothing to gate on.
- **The `ai-build` label.** The enroll step creates it.
- **Optional: a CodeGraph index.** A repo with a `.codegraph/` directory gets a
  code graph pass before each plan. Without one, that pass is skipped.

## Study it first

```bash
bin/onboard-study.sh <repo-dir>
```

This reads a checkout and reports the install, test, build, lint and deploy
commands it found, a draft Verification Contract, a readiness grade, and any
deploy config. It calls no model and runs none of your repo's code. Its one
write is the `.codegraph/` index inside the checkout. Add `--json` for a
machine-readable report.

## Your first ticket

Start small: a copy change or a small fix you can check in a minute. Open it
with the `ai-build` label and say how you'll know it's right. If triage asks a
question, answer it in the thread. When the PR opens, read the plan and the
review before the code.
