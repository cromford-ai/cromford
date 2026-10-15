# Pool bake fan-out (the cap, the cold lane, the failure class)

**What it is:** `bin/fleet-propagate.sh` step (c) bakes the pool builder images
the debounce let through. It used to start all of them AT ONCE. At 2026-09-20
00:00Z the first tick after midnight met a freshly rolled `WARM_BUST` (the
Dockerfile's layer cache is busted daily by `date -u +%F`, so every warm layer
was cold on the same tick) and ten full `next build`s went at one Fly remote
builder: one OOM'd, five starved past the 1800s timeout, and the alert said only
`failed: project-4 …` — every cause had to be read out of the out files.

So the fan-out is bounded and every failure is named:

- `POOL_BAKE_PARALLEL` (default 2) caps the pools whose warm layer is current.
- A pool whose last `ok` bake is **not from today** is COLD — its bake pays for
  the whole checkout + install + build — and is baked in a **serial lane**, one
  at a time, running alongside the capped lane. Ceiling: cap + 1 remote builds,
  and never two cold ones.
- Every failed bake carries a reason: `timeout`, `oom`, `install`, `builder` or
  `build`, in the log line, in the record and in the `--critical` text.
- The record is `pools.<project>: {status, reason, warm_sha}`. `warm_sha` is the
  sha `fly/warm-bake.sh` printed inside the image build.

**How an operator reaches it:** `cron/hub.cron` line 138, `*/5 * * * *
/root/harness/bin/fleet-propagate.sh`. The nightly `bin/fly-image-refresh.sh`
(05:40Z) is a different lane and is already serial — it reads neither knob.

**The warm bust and the refresh lock (BH-6710).** The warm layer's cache key
(`WARM_BUST`) is the date in `state/fly/warm-bust` (`<YYYY-MM-DD> <epoch>`,
`bin/lib/warm-bust.sh`). The nightly refresh rolls it when it starts, so the
propagate ticks between 00:00Z and 05:40Z reuse the last refresh's layer. A pool
is cold when its last `ok` bake is older than the bust epoch. With no valid bust
file (missing, garbage, or older than yesterday) the old rule holds: cold = not
baked today, and `fly-image-build.sh` passes today's date. The refresh holds
`locks/fleet-propagate-bake.lock` (fd 6) for its whole run, so a propagate tick
in that window defers its pools and a later tick bakes them. Its wait for a
running propagate bake step is `FLY_IMAGE_REFRESH_LOCK_WAIT_S` (default 2100);
when the wait runs out it logs `bake lock busy for <W>s — baking without it` and
bakes. `logs/fly-image-refresh.log` carries `bake lock taken` and `warm bust
rolled to <date>`; `logs/fly-image-build.log` carries `== warm bust: <date>
(state|date) ==` per bake. Drive it with `HARNESS_TEST_SANDBOX=1 bash
tests/pool-bake-cause.bh-6710-test.sh`.

**How to drive it:**

| what | how |
|---|---|
| the cap, the two lanes, the classifier, the alert text | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate.bh-1115-test.sh` |
| the sha line and `WARM_NPM_FLAGS` | `HARNESS_TEST_SANDBOX=1 bash tests/warm-bake.bh-1115-test.sh` |
| the debounce this composes with (whether a pool bakes at all) | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-propagate.bh-821-test.sh` |
| which lane the next tick would use, on the hub, spending nothing | `/root/harness/bin/fleet-propagate.sh --check` — one `bake`, `bake (cold, serial lane)` or `debounced (Nm old, under 30m)` line per pool |
| the knobs and the state files, from the header | `/root/harness/bin/fleet-propagate.sh --help` |
| what actually happened | `tail /root/harness/logs/fleet-propagate.log` — one `<p>: warm layer cold (last ok bake <date>\|never) — serial lane` line per cold pool, and a summary line whose `failed=<p>(<reason>),…` appears only when something failed |
| the run record | `jq '.pools' /root/harness/state/fleet-propagate.json` — `{status, reason, warm_sha}` per pool |

**Where the knobs live:**

- `env/global.env` — `POOL_BAKE_PARALLEL` (documented in
  `env-templates/global.env.example`; default 2 with the file absent).
- `POOL_BAKE_TIMEOUT_S` (default 1800) is a TEST override, like
  `FLEET_PROPAGATE_PATH`. Production never sets it; it exists so the `timeout`
  class is proven through the real `timeout(1)`, not a stubbed exit code.
- `fly/warm-env/<project>.env` — `WARM_NPM_FLAGS`, applied to `npm ci` /
  `npm install` inside the image build. The repo's own `.npmrc` needs no knob:
  the install runs from the repo directory.

**What must never regress:**

- **The cap is config, and a bad value refuses loudly.** A hardcoded number in
  the branch is the bug this entry exists to prevent. `POOL_BAKE_PARALLEL=abc`
  logs one line naming the value it refused and uses 2 — never unlimited.
- **`0` is unlimited, and it lifts the WARM cap only.** Cold pools stay serial
  whatever the knob says, because one cold bake at a time is the whole point.
- **A cold pool is never in the parallel lane.** Cold = no `ok` bake at or
  after the bust epoch in `state/fly/warm-bust`, or, with no valid bust file,
  no `ok` bake stamped with today's UTC date. Each is the exact key
  `fly-image-build.sh` passes as `WARM_BUST`. Absent, unparseable and future
  stamps are all cold.
- **The cold lane does not consume a cap slot.** It runs beside the capped lane,
  so a cold day does not also starve the pools that are cheap to bake.
- **`ok` never carries a reason.** The classifier runs only for a non-zero rc.
  An out file with `exit code: 137` in it from a step that was retried and
  succeeded is `ok`, `reason: ""` — a bake that returned 0 is a success.
- **The classes stay narrow.** `timeout` comes from rc 124 (our own
  `timeout(1)`), never from the word "timeout" in the body. `oom` needs
  `exit code: 137` as an exit code, never `137` inside a digest. Precedence is
  timeout → oom → install → builder → build, so a build that OOM'd while the
  builder was also complaining reads `oom`. The catch-all is `build`.
- **`failed=` prints only when something failed.** A clean run's log line and
  alert carry no reason token at all, so the token's presence is the signal.
- **The class rides WITH the BH-806 why-line, it never replaces it.** A failed
  bake still writes `$WORK/pool-<P>.why` (`rc=<n>: <the bake's own failing
  line>`) and still gets its `pool <P>: fail — rc=…` log line: the class says
  which KIND of failure, the quoted line says which failure. Those why-lines
  are indexed by the BARE pool name, so the reason is decorated onto a
  separate list (`POOL_BAD_LABEL`) for the summary and the alert — gluing it
  into `POOL_BAD` makes every why-line read `(no why recorded)`.
- **`--check` spends nothing** and prints the lane the next real tick would use.
- **An empty `warm_sha` is not a failure.** It means the warm layer was reused
  (the image build's RUN never re-executed) or the image baked cold. Status is
  the only thing the stamp and the dirty-marker clearing key on.
