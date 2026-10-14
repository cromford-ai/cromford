# The propagate lane bakes at most two warm pools at once, one cold pool at a time, and says why a bake failed

Doc: OPERATOR-SETUP

At 2026-09-20 00:00Z the first `bin/fleet-propagate.sh` tick after midnight baked
all ten pool images in parallel. `fly-image-build.sh` passes
`WARM_BUST=$(date -u +%F)` to the image build, so at midnight every pool's warm
layer went cold on the same tick and all ten bakes paid for a full checkout +
install + `next build` against one Fly remote builder. One OOM'd, five starved
past the 1800s timeout, and the alert said only `failed: project-4 …` — every cause
had to be read out of `state/fleet-propagate/pool-<p>.out` by hand.

BH-821 had already bounded WHETHER a pool bakes on a tick. This bounds HOW MANY
bake at once, and makes the failure legible without opening a file.

## What changed, in `bin/fleet-propagate.sh`

**Two lanes in step (c), instead of one `for … & done; wait`.**
`pool_cold <p>` is true when the UTC date-part of `state/fly/<p>.baked-at` is not
today's — the same expression the Dockerfile's cache bust uses, so "cold" here
means exactly "this bake will not reuse a layer". Absent, unparseable and future
stamps are cold, matching the debounce's own treatment of them.

- the COLD lane is a single subshell that bakes its pools one after another;
- the WARM lane is a subshell that launches `bake_one <p> &` and `wait -n`s
  whenever `POOL_BAKE_PARALLEL` are in flight (`0` skips the wait entirely);
- both run at once, then the parent `wait`s.

So the ceiling is `POOL_BAKE_PARALLEL + 1` remote builds and never two cold ones.
The cold lane deliberately does NOT take a slot from the cap: one cold bake at a
time is the point, and charging it to the cap would starve the cheap pools on
exactly the day they are cheapest. `wait -n` runs only inside the warm subshell,
so it can never reap the cold lane — that one is the parent's child, not its own.

**`POOL_BAKE_PARALLEL`**, `env/global.env`, default 2, `0` = unlimited (same
sense as `BUILD_SLOTS` in the fleet rules). Parsed next to
`POOL_IMAGE_MIN_AGE_MIN` and outside the deploy-only block, so `--check` answers
with the value the real tick would use. A non-numeric value logs one line naming
what it refused and uses 2. Documented in `env-templates/global.env.example`.

**`POOL_BAKE_TIMEOUT_S`**, default 1800 — the literal that was already in the
branch, lifted to a knob so the `timeout` class can be proven through the real
`timeout(1)` (rc 124) instead of a stubbed exit code. It is a TEST override like
`FLEET_PROPAGATE_PATH`; production never sets it, and it is not in the template.

**`bake_reason <rc> <outfile>`**, called ONLY for a non-zero rc. Precedence:

| class | what matches |
|---|---|
| `timeout` | rc 124 — killed by our own `timeout`, never the word in the body |
| `oom` | `exit code:? 137` followed by a non-digit — never `137` inside a digest |
| `install` | `npm (ERR!\|error) code (EUSAGE\|ERESOLVE)`, `ERR_PNPM_OUTDATED_LOCKFILE`, `from lock file` |
| `builder` | `deadline_exceeded`, `releasing/creating the builder` |
| `build` | everything else, including `fly-image-build.sh`'s own FATALs |

An `ok` bake never gets a reason, whatever its output says: the 2026-09-19 out
files contain both `warm build FAILED — baking checkout+node_modules only` (the
designed fallback) and a `exit code: 137` from a step that was retried and
succeeded, and both of those runs returned 0. One label per class, so `install`
covers pnpm lockfile failures too rather than splitting into `npm-ci`/`install`.

**The record grew.** `pool-<p>.result` is now `status<TAB>reason<TAB>warm_sha`
and `pools.<p>` in `state/fleet-propagate.json` is
`{status, reason, warm_sha}` — the shape the ticket asked for. `.baked-at`
stamping and `.image-dirty` clearing still key on the status alone, so BH-821's
semantics are untouched. The result line is split by parameter expansion rather
than `IFS=$'\t' read`: tab is IFS whitespace, so `read` folds the empty reason of
an `ok` row and hands the sha to the reason field.

**`warm_sha`** is grepped out of the bake's out file:
`fly/warm-bake.sh` now prints `warm-bake: repo sha <40 hex>` after it `cd`s into
the checkout. Empty means the layer was REUSED (the image build's RUN never
re-executed) or the image baked cold — it is a provenance field, never an input
to status. That is also the honest answer to "was this green bake fresh?".

**The log line and the alert name the class.** `POOL_BAD` entries are
`<p>(<reason>)`, the summary line gains ` failed=project-4(timeout),project-3(oom)`
after `images=a/b`, and the `--critical` text carries the same tokens. A run with
no failure prints no `failed=` and no reason token at all.

**`--check` names the lane**: `<p>: bake` or `<p>: bake (cold, serial lane)`,
debounced lines unchanged. It still writes nothing.

## And in `fly/warm-bake.sh`

Beside the sha line, it sources `${WARM_ENV_FILE:-/opt/warm-env/$WARM_PROJECT.env}`
when that file exists and applies `$WARM_NPM_FLAGS` to `npm ci` / `npm install`
(intentional word-split, `SC2086` disabled on the branch). The pnpm path is
unchanged. A repo that needs `--legacy-peer-deps` sets it in
`fly/warm-env/<project>.env` instead of teaching the script about that repo. The
repo's own `.npmrc` needed no change at all — the install already runs from the
repo directory, which is what the suite now pins.

## Not done, on purpose

Adding the repo sha to the image build-arg (the ticket's optional ask) would
cold-bake every pool on every commit to that repo — dozens of full builds a day
across ten pools, which is the load class this ticket exists to stop — and would
need a sha-aware cold detector on top of the date one. The sha is RECORDED
instead. If it is wanted as a bust, it is a second ticket with both halves.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate.bh-1115-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/warm-bake.bh-1115-test.sh

The first drives the real `bin/fleet-propagate.sh` against a scratch harness with
a real git origin; the `fly-image-build.sh` stub counts its own in-flight bakes
under `flock`, per lane, so "warm max 2, cold max 1, total max ≤ 3" is measured
from what actually overlapped rather than read off the source. §A is the cap
(unset / 1 / 0 / garbage), §B the two lanes, §C `--check`, §D the classifier on
the four incident shapes plus five adversarial negatives, §E the record object,
§F the log line and the alert. The second drives `fly/warm-bake.sh` with npm and
corepack stubs that record their argv and their `$PWD`.

`tests/fleet-propagate-test.sh`, `tests/fleet-propagate.bh-821-test.sh` and
`tests/warm-bake-guard-test.sh` changed by one jq token per `.pools[…]` read
(`→ .pools[…].status`) and nothing else.
