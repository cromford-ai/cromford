# web-task S1: a read-only browser lane for sites with no API (BH-7594)

Doc: OPERATING, PROJECT-LANES, MODEL-ROUTES

## What changed

- A ticket of kind `web-task` is never planned, built or turned into a PR.
  `bin/kind-gate.sh` maps `web-task` (also `webtask`, `web_task`) from a board
  type field or a GitHub label only. A title prefix or a planner's KIND line
  never gives `web-task`: a wrong route spends model money and posts a comment.
- The build pipeline's `# >>> web-task hook (BH-7594)` block in
  `bin/lib/rb/plan.sh` sits after the untrusted input gate and before any plan
  model call. It calls `wt_route` in `bin/lib/web-task/route.sh`:
  - `WEBTASK_QUEUED lane-run row for <p>/<KEY>`: one `lane_runs` row for the
    `web-task` lane. The job closes `done`.
  - `BUILD_DEFERRED web-task: ...`: a web-task run of the project is already
    live. The next tick re-offers the ticket.
  - `WEBTASK_FAILED <why>`: the lane is not placed on fly, or the enqueue
    failed. The job closes `failed`.
  - `BUILD_REFUSED web-task: ...`: the project is an in-app board project.
    S1 reads and answers GitHub issues only, and an in-app ticket number is
    not an issue number of the repo. The in-app prompts already close
    `BUILD_REFUSED` with one ALERTS line, so the `WEBTASK_*` words only reach
    GitHub-issue projects.
- `RESULT_PREFIX_RE`, `_job_finish`, the gate-release owner list and the
  split-chain owner case know `WEBTASK_QUEUED`. The 8 GitHub-issue prompts
  that carry the `ROLLOUT_*` sweep rule carry a `WEBTASK_*` rule beside it.
- `bin/web-task.sh <ticket> <KEY> [job-id] <project>` (lane file
  `catalog/lanes.d/web-task.json`) runs on a Fly lane-run machine. It reads the
  issue and its thread, stops at the `<!-- web-task-result:<KEY> -->` marker
  (dedup before spend), reads the allow-list, resolves the model, runs
  `bin/web-task-agent.mjs`, publishes up to 5 screenshots and posts ONE
  comment. Only a `done` run ends its comment with the result marker. A run
  that stops at a cap, at the spend gate or on an error ends with
  `<!-- web-task-attempt:<KEY>:<stamp> -->`, which never blocks a later run.
  The thread read goes to the last page, up to `WEB_TASK_THREAD_MAX_PAGES`
  pages of 100; a longer thread is rc 75 and no run.
- `bin/web-task-agent.mjs` is the Playwright loop. One step is one
  observation, one screenshot, one model call (`bin/lib/web-task/decide.sh`
  through `bin/agent-call.sh` with no tools, lane `web-task`) and one action:
  `goto`, `click`, `type`, `scroll`, `read`, `done`. The guards are in the
  tool layer (`bin/lib/web-task/guards.mjs`):
  - a main-frame navigation to a host not on the list is aborted;
  - a redirect is never handed to the browser: the guard checks its
    `Location` and the tool layer re-issues the hop, so every hop of a chain
    is checked (Playwright does not route the browser's own redirect follow);
  - any request that is not GET, HEAD or OPTIONS is aborted;
  - a click on a submit-like control is refused, and an init script cancels
    every submit event;
  - `type` strips CR and LF and never presses Enter.
- The lane-run image (`fly/lane-run.Dockerfile`) bakes the pool image's
  `bake-playwright` block byte for byte (C1 of
  `tests/lane-run-agent-clis.bh-6260-test.sh` pins it) and installs the
  playwright module globally at the same pin (`# >>> web-task-playwright-module`).
- The schema fragment `worker/jobs/schema.d/202610281406-bh-7594-web-task-seeds.sql`
  seeds the `web-task` model route (copied from triage rung 0) and
  `lane_placement.web-task=fly`. It seeds no allow-list.
- Seam files for later slices, each function a stub that prints
  `not available` and returns 69: `bin/lib/web-task/vault.sh`, `otp.sh`,
  `session.sh`, `approval.sh`.

## Knobs and settings

- `WEB_TASK_MAX_STEPS` (default 40, 1..200) and `WEB_TASK_MAX_S` (default 600,
  30..3600): the per-run caps.
- `LLM_USD_CAP_DAY` (5 usd from the seeded row `lane.web-task.llm_usd_cap_day`; registry default 0), `LLM_LANE_ENABLED`, `LLM_RUNNER_ALLOWED`
  (`claude`): the llm-gate knobs of the lane.
- `lane.web-task.<project>.allowed_domains`: a comma list of hosts. Each host
  also allows its subdomains; an IPv4 entry allows only itself. No row or an
  empty row: the lane posts one "not set up" comment and runs nothing.

## Operator steps to go live

1. Rebuild and push the lane-run image with the new build arg:
   `--build-arg PLAYWRIGHT_VERSION=$(bin/jobs-client.sh setting-get bake.playwright.version)`
   (the recipe in `fly/lane-run.toml`).
2. Deploy the worker schema (`bin/harness-sync.sh` applies the fragment).
3. Set the allow-list for a project, for example
   `bin/jobs-client.sh setting-set lane.web-task.cromford.allowed_domains playwright.dev`.
4. Label a GitHub issue `web-task` with `ai-build`. The next build tick queues it. The lane takes `ai-build` off the issue once it answers, refuses or spends (an open labelled issue is re-offered every tick); add the label again to run the ticket again. A `done` answer is final; a run that did not finish (step-cap, time-cap, refused-spend, error) runs again.

## Not in S1

Sign-in, the vault, one-time codes, saved sessions and approval for write
actions (the four seam files), in-app board projects, an image-capable model
step (the model reads a text observation; the screenshots are kept for the
record and the comment), and a prune of old `harness-shots/*-web-task`
branches.
