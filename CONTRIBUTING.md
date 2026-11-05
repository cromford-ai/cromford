# Contributing to Cromford

Issues and pull requests are welcome on
[cromford-ai/cromford](https://github.com/cromford-ai/cromford). The guide to
Cromford lives at [cromford.dev](https://cromford.dev). To run it on your own
accounts, start at [docs/SELF-HOST.md](docs/SELF-HOST.md).
[docs/ABOUT.md](docs/ABOUT.md) says how this repository is released and what is
not in it yet.

## How a change lands

The maintainers review every PR. An accepted change is carried into the main
codebase, and it appears here in the next release commit
(`Cromford <date> (upstream <sha>)`). So a PR here is not merged directly. Its
change arrives in a release commit.

- **Say what the change is for in the PR body.** That text travels with the
  diff. A PR whose reasoning is only in the commit messages loses it.
- **Small and self-contained lands fastest.** A 40-line fix with a test lands.
  A 900-line refactor touching twelve files is a conversation first.
- **Open an issue before a large change**, so nobody writes something that
  cannot be taken.

## How the factory expects changes to look

- One ticket, one branch, one PR.
- Small diffs. The size gate starts at 700 lines and 20 files.
- A new file over an edit to a shared list, so parallel changes don't collide.
- Tests in a new file for the change, not appended to someone else's suite.
- A harmless metric (time, size, line count) is reported, never a hard limit.

[docs/OPERATING.md](docs/OPERATING.md) says why for each of these, and lists
the defaults a fresh install starts with.

## Licence

Cromford is licensed under the Apache License 2.0. Contributions are under the
same terms: inbound = outbound, as section 5 of the licence says. By opening a
PR you license your change under Apache 2.0.

## Before you push

```bash
bin/run-tests-in-docker.sh
```

That runs the whole shell suite on Debian, which is the platform it is written
for. Run it natively if you are already on Linux:

```bash
for t in tests/*.sh tests/mc/*.sh; do bash "$t"; done
```

Also run the identifier guard:

```bash
bash tests/no-client-identifiers-test.sh
```

On macOS about 28 suites fail on `mapfile`, bash 3.2 syntax and GNU-coreutils
flags. Those are the platform, not your change. Don't use that as cover,
because it is exactly how a real regression hides. Use the container.

Do not run that bare loop as root on a machine that has a live `/root/harness`.
[tests/README.md](tests/README.md) explains why, gives the namespace recipe that
makes it safe, and covers the two checks CI runs over the suite itself.

## CI on this repository

`.github/workflows/ci.yml` runs on every push and pull request, on a hosted
runner with no secrets. It checks shell and JavaScript syntax, builds the
dashboard, runs the Node suites for the dashboard, jobs, OTP, watchdog, MCP and
agent core, and runs the authorization and lock-worker security regressions.
It also runs focused shell regressions, dependency audits, shellcheck at error
severity, the identifier guard and gitleaks 8.30.1. The full shell corpus runs
weekly and on manual dispatch; run it locally before pushing as shown above.

Node is pinned in `.node-version`, shared by CI and the Linux test image.
The jobs and OTP `npm test` commands prepare their ignored lane and LLM-site
catalogs automatically. For a direct `node --test` invocation importing the
jobs worker, first run `bash bin/test-worker-bootstrap.sh`. That preparation
requires Bash and jq, as do the repository's existing catalog generators.

## Example names

Every `project-1`, `box-1`, `TK-142`, `example-org` and `10.0.0.x` in this
repository is an example name. Keep using them. A PR that brings in a
realistic-looking hostname or customer name gets bounced even if the name is
made up, because the reviewer cannot tell.

`tests/no-client-identifiers-test.sh` fails if the tree starts carrying an
identifier by its shape: a network address outside the example range, an
account uuid, a long hex id, a hosting or messaging id, a machine hostname, a
ticket key that is not `TK-`, or a credential pattern. It holds no list of
names, on purpose. The maintainers run a second guard that checks names before
every release.

## Red-first

A test that never failed proves nothing. Write the test, **run it, watch it
fail**, and only then write the code. If it passes the first time, it is not
testing what you think.

**Never weaken a test to get to green.** Not skipped, not loosened, not deleted.
If a test is genuinely wrong, fix it *and* say so in the PR body with the
reasoning.

**Prove the feature, not the scaffolding.** A green build and a passing
typecheck prove the code compiles. They prove nothing about whether the thing
works. Before you write "this works", ask whether the behaviour actually
happened once.

The full set is in [rules/CLAUDE.md](rules/CLAUDE.md) and
[prompts/build-discipline.md](prompts/build-discipline.md). They are the rules
Cromford runs its own builds under.

## What not to touch

**`.github/workflows/`.** CI changes are a privilege boundary: the workflow is
what proves everything else. A PR that edits it will not be taken.

**`fleet.conf`, `vercel.conf`, `cron/`.** These are registries of example rows.
They show the column layout and give the suite something real to assert
against. Changing the *format* is a fine PR. Changing the rows is not.

**If you are running Cromford rather than contributing to it**, none of that
applies to your own fork. Put real values in `fleet.conf`; that is what it is
for. The identifier guard will then fail on your fork, correctly, because your
fork carries real hostnames. That's expected. The guard is for changes coming
back here, not for your deployment.

## Things that make a PR easy to take

- One concern per PR.
- A test that fails without your change.
- Comments that say *why*, not what.
- Example names, consistent with the ones already in the tree.
- No new dependency without a paragraph on why the standard library will not do.

## Reporting something you cannot fix

Open an issue. A description of the failure, what you expected, and the smallest
reproduction you can manage is worth more than a patch that guesses.

If you think you have found a security problem, do not put the details in a
public issue. Open an issue that asks for a security contact, with no details,
and a maintainer will reach out.
