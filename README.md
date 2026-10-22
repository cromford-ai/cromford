# Cromford

Cromford is the open-source software factory ([cromford.dev](https://cromford.dev)). It takes tickets off a product board,
decides which are actually ready to build, plans them, builds them on a remote
machine, reviews the result adversarially, opens a PR, QAs the preview, merges,
confirms the deploy rolled, and then checks in production that the thing it
merged is really there.

It runs unattended. The design problem it exists to solve is not "can a model
write code" — it is what has to be true around the model so that a loop nobody
is watching does not open the wrong PR, spend money twice, or tell a customer
something shipped when it did not.

## The pipeline

One ticket moves through fixed stages. Each has its own runner, its own model,
its own budget, and its own idea of what "done" means.

| Stage | Script | What it does | Refuses when |
|---|---|---|---|
| **triage** | `bin/run-triage.sh` | Reads the whole ticket thread and decides RUN or SKIP | The last word is a question to the customer that nobody answered |
| **plan** | `bin/run-build.sh` | Writes the change down first, ending in named acceptance tests | It cannot name a test that would fail today |
| **build** | `bin/run-build.sh` | Implements against the plan, on a watcher box or a Fly machine | Tests were weakened rather than made to pass |
| **review** | `bin/run-build.sh`, `bin/review-prs.sh` | An adversarial pass over the diff, never the author's own session | The verify script does not prove the behaviour it claims |
| **preview QA** | `bin/e2e-smoke.sh` | Loads the PR's own preview deployment and clicks | The route 404s or the preview never built |
| **merge** | `bin/merge-conductor.sh` (owner; observe-only until its flags), `bin/merge-queue.sh`, `bin/merge-sweep.sh` | Every harness PR sits in one named state with an age budget; queued per project so two builds never race the same base | CI is not green, the base moved, the head moved after the approval, or the tier is wrong |
| **deploy-verify** | `bin/deploy-train.sh` | Confirms a production deployment actually followed the merge | No deployment appeared within the window |
| **post-merge QA** | `bin/postmerge-qa.sh` | Drives the real production surface | The shipped behaviour is not there |

Stages talk through files and a database, not through one long conversation. A
stage that dies is restartable because its inputs are on disk.

**Merge tiers.** A build lands in tier 1 or tier 2. Tier 1 is eligible for
automatic merge once review approves and CI is green. Tier 2 waits for a human.
`flags/automerge-disabled` forces every build to tier 2 —
`bin/run-build.sh:1592`.

## What holds it together

**Deterministic before LLM.** Anything a script can decide, a script decides.
The gate that says "this ticket has an unanswered question on it" is a status
field and a comparison, not a judgement call — so it costs nothing, never
drifts, and is testable (`bin/triage-gate.sh`; on GitHub-Issues projects its
fingerprint also carries the open harness PRs, so a merge or a check flip
wakes the tick). The model is asked only the questions that genuinely need
reading comprehension.

**Configuration is data.** Which model a stage uses, what a lane may spend,
which projects are enrolled, what may run concurrently: rows and registry files,
not constants. `fleet.conf` is the project registry and no script keeps its own
copy — `tests/fleet-projects-not-hardcoded-test.sh` fails if one tries.

**A fleet of boxes, plus an optional pool.** Each project's watcher runs on a
box; `fleet.conf` column 6 says which. One box is the hub and runs the
cross-project lanes. Builds can optionally be pushed to an ephemeral Fly machine
per build instead of running on the watcher — opt-in, and nothing breaks if you
never enable it (`bin/fly-pool.sh`).

**Multi-vendor lanes.** Every stage names a runner. When the primary is missing,
unauthenticated, or fails, `bin/agent-call.sh` walks a fixed ladder —
claude → grok → codex-configured openrouter → fireworks — alerting as it
degrades, and refusing to walk it at all when the failure was a budget stop or a
kill. The order is pinned by `tests/agent-call-provider-order-test.sh`.

**Every call is priced.** `bin/agent-call.sh` appends a 16-column row to
`logs/cost.csv` for each call. `bin/cost-rows-push.sh` ships rows to D1 every 10
minutes; `bin/cost-rollup.sh` builds the per-PR view nightly. A model with no
price in `catalog/model-prices.json` raises a daily alert rather than quietly
costing $0.

**It learns from its own PRs.** Review findings are mined for repeats
(`bin/rule-miner.sh`), and a family of repeats becomes a guardrail under
`guardrails/` — a rule that fails next time in CI instead of being found again
by a reviewer. Nothing in that lane merges or loosens a gate; it only tightens.

## Run it on your own accounts

<!-- selfhost:begin -->
You can run Cromford on your own Cloudflare, GitHub, Fly (or VM) and model
accounts. Fork it, copy the settings template, fill it in, and check it:

```bash
gh repo fork <upstream-owner>/<repo> --clone
cp env-templates/selfhost.conf.example selfhost.conf
bin/selfhost-install.sh --config selfhost.conf --dry-run
```

The dry-run prints every resource, env line, spend cap and secret name, and
creates nothing. The installer's `--apply` step is not built yet, so resources
are still built by hand. [docs/SELF-HOST.md](docs/SELF-HOST.md) walks through
every setting, the caps, upgrades and the common failures.
<!-- selfhost:end -->

## Read next

| If you want to | Read |
|---|---|
| Run it on your own accounts, from a fork | [docs/SELF-HOST.md](docs/SELF-HOST.md) |
| Stand up your own fleet, or join one | [docs/OPERATOR-SETUP.md](docs/OPERATOR-SETUP.md) |
| Recover a wiped box (Orgo snapshot + R2 state backup) | [docs/RESTORE.md](docs/RESTORE.md) |
| Make your app drivable by the harness | [docs/BOARD-API-CONTRACT.md](docs/BOARD-API-CONTRACT.md) |
| Contribute a change | [CONTRIBUTING.md](CONTRIBUTING.md) |
| See how the parts connect: boxes, Cloudflare, Fly, GitHub, vendors | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Understand what a build actually does, step by step | [docs/RUN-BUILD-GRAPH.md](docs/RUN-BUILD-GRAPH.md) |
| Understand the database and who writes what | [docs/DB-COORDINATION-SPEC.md](docs/DB-COORDINATION-SPEC.md) |
| Understand how context is composed and budgeted | [docs/CONTEXT-COMPOSITION.md](docs/CONTEXT-COMPOSITION.md) |
| Make a lane advance on a GitHub event instead of its cron tick | [docs/EVENTS.md](docs/EVENTS.md) |
| Know which LLM account pays for what | [docs/ACCOUNT-ROUTING.md](docs/ACCOUNT-ROUTING.md) |
| Read what went wrong before, and what the rule is now | [docs/LESSONS.md](docs/LESSONS.md) |
| Run a factory day to day: what went wrong, the defaults, the knobs | [docs/OPERATING.md](docs/OPERATING.md) |
| Understand how this repository relates to Cromford | [docs/ABOUT.md](docs/ABOUT.md) |
| See the dated notes this README used to be | [docs/CHANGELOG-NOTES.md](docs/CHANGELOG-NOTES.md) |

Repeated procedures are repo-managed skills, one `SKILL.md` per competency under
[skills/](skills/), deployed to every box by `bin/sync-skills.sh`. A session
loads a tested procedure on demand instead of carrying it in every prompt.

## Verification contract

**Run the suite:**

```
for t in tests/*.sh tests/mc/*.sh; do bash "$t"; done
```

No network, no secrets, no fixtures to generate. Some suites need `jq`,
`semgrep` or `codegraph` and skip cleanly without them; CI sets
`CODEGRAPH_REQUIRED=1` and `SEMGREP_REQUIRED=1` to turn those skips into
failures (`.github/workflows/harness-ci.yml`).

**Load-bearing suites** — these encode decisions rather than mechanics, and a
failure in one is a design regression, not a flake:

| Suite | What it protects |
|---|---|
| `tests/fleet-projects-not-hardcoded-test.sh` | No script may keep its own copy of the project list |
| `tests/cron-fleet-parity-test.sh` | The registry and the committed crontabs agree |
| `tests/agent-call-provider-order-test.sh` | The vendor failover ladder is the order it claims |
| `tests/iron-law-guard-test.sh`, `tests/lane-fence-test.sh` | The act-time command fence still denies what it must |
| `tests/alert-loop-test.sh` | An alerting lane cannot alert about its own alerts |
| `tests/board-lane-loop-test.sh` | The triage lane corrects an app's automated board move at most once per ticket and commit, then alerts and stops (TK-135 loop) |
| `tests/evals-suite-test.sh` | A prompt change still makes the same triage decisions. It drives `tests/evals/run-evals.sh`, which the `tests/*.sh` glob does not reach on its own |

**Platform.** The suite is written for Linux. On anything else, run it in the
container. The runner lives in `bin/`, not `tests/`, so the loop above never
re-enters it:

```
bin/run-tests-in-docker.sh
```

That builds a small Debian image with the tools the suite needs and runs the
whole thing inside it. It is close to CI but not identical — CI additionally
installs `semgrep` and `codegraph` and sets `*_REQUIRED=1`, which turns two
clean skips into real checks. Measured on the tree this was written against:

| | pass | fail |
|---|---:|---:|
| Debian trixie (the container) | 121 | 3 |
| macOS 15, bash 3.2 | 96 | 28 |

Most of the macOS gap is `mapfile`, bash 3.2 syntax and GNU-coreutils flags —
the platform, not the code. Three suites fail in the container but pass in CI;
they are named in the script's header, and that header says plainly that their
cause is not yet understood rather than guessing at one.

The container needs Docker and network for the first build, so the "no network,
no secrets" claim above is about the suite itself, not about fetching an image.

**Before you push**, if you are contributing to this repository, also run
`bash tests/no-client-identifiers-test.sh`. See [CONTRIBUTING.md](CONTRIBUTING.md).
