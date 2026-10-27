# Onboarding repo detect, wave 2 tracer (BH-7997 of #7935)

**What it is:** the first end-to-end path of the onboarding UI. The console
asks whether the GitHub App can see a repo. The jobs worker has no GitHub
credential, so it files a hub-probe row and answers what the row holds. The hub
reads GitHub when the hub-probe lane claims the row.

- Console routes (placeholders, URL only, no nav link yet): `/projects/new`
  shows the heading "New project"; `/projects/<project>/ready` shows
  "Ready: <project>".
- API (bearer-gated, through the coord proxy):
  `GET /api/coord/onboarding/repo?slug=<owner/repo or https://github.com/owner/repo>`
  and `GET /api/coord/onboarding/repos`.
- The chain: `worker/jobs/src/routes/onboarding-repo.js` -> `hub_probe_requests`
  row (`project=onboarding`, `probe=repo-detect`, `ticket_key=onb-repo-<epoch/60>`)
  -> `bin/hub-probe.sh` -> `bin/lib/hub-probes/repo-detect.sh` ->
  `bin/lib/onboard-github.sh` (`og_get`, the only GitHub seam).
- One row per slug per minute (one per 10 minutes for `/repos`): a second GET
  in the same bucket reads the same row and costs no GitHub read.

## Preconditions

- The hub mints App tokens (`env/github-app.env`, `bin/gh-token.sh`). Without
  that, the row is stored `fail` with output `not-configured` and the route
  answers `{state:"error", error:"not-configured"}`.

## Check after deploy

1. `GET /api/coord/onboarding/repo?slug=example-org/cromford` answers
   `{"state":"pending"}`.
2. After the next hub-probe tick, the same GET answers `{"state":"ok",
   "visible":true, "facts":{"default_branch":...}, "install_url":...}`.
3. `GET /api/coord/onboarding/repo?slug=nope` answers 400.

## Tests

- `tests/onboard-repo-detect.bh-7935-test.sh` (seam fake, validators, probe, one
  real hub-probe tick)
- `tests/onboard-github-vendor-budget.bh-7935-test.sh` (0 vendor calls)
- `worker/jobs/test/onboarding-repo.bh-7935.test.js` (routes on node:sqlite)
- `console-ui/tests/onboard-api.bh-7935.test.js` (wrappers, ROUTES)
- `tests/contract/onboard-github.bh-7935-contract-test.sh` (real GitHub; main,
  nightly and seam PRs)
