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

## The canary PR

After onboarding, the project is **held**: no ticket builds until a no-op PR
goes green in the repo's own CI. Three repos were onboarded with a
CI that was red on every PR and merged 0 of 16 PRs. The canary finds that
before the first ticket does.

- `bin/load-project.sh` (the `== onboarding canary ==` block) and the
  onboarding runner's `ready` station run `bin/onboard-canary.sh --hold <p>`.
  It writes the settings row `onboard.<p>.canary_gate=held` and opens one PR,
  `[harness] onboarding canary, do not merge`, from the branch
  `harness/onboard-canary-<yyyymmddhhmm>`. The PR's one commit writes
  `.harness/onboard-canary.md`.
- The hub lane `onboard-canary` reads the PR's check runs and commit statuses
  every 5 minutes. Then it writes the verdict to `onboard.<p>.canary`
  (`pending`, `green`, `red` or `no-checks`, with the head sha). Then it closes
  the PR unmerged and deletes the branch.
  - **green**: every check and status passed. The gate row goes to `released`
    and tickets build.
  - **red**: one check failed, or a check still ran at the timeout
    (`ONBOARD_CANARY_TIMEOUT_MIN`, default 60). The project stays held. One
    alert names the failing checks and the first error line.
  - **no checks**: the repo has no workflows and no status after
    `ONBOARD_CANARY_NOCHECK_GRACE_MIN` (default 10), or nothing reported at the
    timeout. The project stays held, and one alert says "no checks".
- While held, a build of the project answers
  `BUILD_DEFERRED onboard-canary held: <state> <sha12>` and the next tick
  offers it again (`bin/lib/rb/gates.d/onboard-canary.sh`). A project with no
  gate row is never held. If the gate row cannot be read, the build runs, with
  one log line: an outage of the settings store must not stop every build.
- A hold is never silent. A project held for `ONBOARD_CANARY_HELD_ALERT_HOURS`
  (default 24) with no override gets the alert `onboard-canary:<p>:held`. It
  stays open until a green canary or `--override` releases the project. The
  alert never releases the project by itself.

Commands (on the hub):

```bash
bin/onboard-canary.sh --status [<project>]   # <p> <gate> <state> <sha12> <pr-url> <at>
bin/onboard-canary.sh --start <project>      # run the canary again after a CI fix
bin/onboard-canary.sh --override <project> "<reason>"   # release a held project
```

Use `--override` only for a repo that cannot have CI. It writes the row
`onboard.<p>.canary_override=<reason>` and releases the gate. An empty reason
is refused.

Every Monday at 06:17Z the lane opens a canary for every fleet project
(`--weekly`). A red weekly canary writes an alert and does not hold the
project. To skip a project, set the row `onboard.<p>.canary_skip=<reason>`.
Log: `logs/onboard-canary.log`. Off: `bin/harness-ctl.sh off onboard-canary`.

## Your first ticket

Start small: a copy change or a small fix you can check in a minute. Open it
with the `ai-build` label and say how you'll know it's right. If triage asks a
question, answer it in the thread. When the PR opens, read the plan and the
review before the code.
