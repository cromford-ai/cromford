# E2E policy — deterministic browser E2E across the fleet

**Decided by the operator, 2026-09-12 ("go").** The browser E2E suites stay: they are
the QA team. What changes is WHEN they run and what a red one is allowed to
mean. Before this, project-4's E2E judged production on every deployment event, was
red on `main` for nine straight days, held every PR `UNSTABLE`, and the merge
sweep grew a per-repo discount to route around it. A check that is always red
is not a check; it is noise that trains everyone to ignore the badge.

## The six points

Per app repo (project-4, project-3, project-1, project-5; the small boards
follow when they get browser suites):

1. **PR-required checks are the fast, deterministic ones only:** typecheck,
   lint, unit, and the repo's harness gates (test-tamper / static guards where
   they exist). Nothing that needs production or a deployed preview is
   required. Branch protection on `main` lists exactly those context names
   (`strict:false`, no admin enforcement, no review requirement, no force
   pushes); never a browser E2E or a prod-targeted check.
2. **Browser E2E on a PR runs ONLY when the diff touches an E2E path:** `app/`
   `src/app/` `pages/` `components/` `ui/` `middleware.*` `proxy.*` route
   handlers, auth code, e2e specs (`tests/e2e/**` `e2e/**` `playwright*`), or
   deps (`package.json`, `package-lock.json`, `next.config.*`, tailwind /
   global css). Otherwise the browser jobs SKIP with a green
   "skipped: no E2E paths in diff" summary — never a red, never a hanging
   "expected" context. `pull_request`-triggered workflows use a real `paths:`
   filter; `deployment_status`-triggered ones use a changed-files gate step
   (`gh api repos/{repo}/compare/main...{sha}`) whose output the browser jobs
   read.
3. **Full suite on every push to `main` and post-deploy against the DEPLOYED
   sha:** poll the deployment / health endpoint for the sha (cap 15 min),
   never `sleep 30`. Prefer `deployment_status` success events where the repo
   receives Vercel deployment events.
4. **Full suite nightly** (cron about 03:00Z, staggered per repo) against
   production, reporting failure the way the repo already does.
5. **Nothing stays red on `main` for more than 3 days.** It gets fixed or
   deleted, with an alert. The harness detects it (below); the repo owner
   leaves nothing perma-red behind.
6. **The harness box review treats E2E results as advisory unless the diff
   hit an E2E path.** A red E2E on a UI diff is a review blocker; a red E2E on
   a migration-only diff is a note.

## The harness side (this repo)

- **`bin/lib/e2e-paths.sh`** is the ONE definition of "E2E path" and
  "E2E-class check name" (`e2e`, `playwright`, `production qa`, `prod qa`,
  `preview qa`, `browser`). It is sourced by every consumer below; a second
  copy of either regex is a bug. Pinned by `tests/e2e-paths-lib-test.sh`.
  Keep it in step with the repos' `paths:` filters: a path the repos gate on
  but this file ignores would let the harness call a red E2E advisory on the
  very diff the repo decided to run it for.
- **`bin/review-prs.sh`** (point 6): the external-PR re-review debounce waits
  for green CI per head. E2E-class runs are now set aside when the diff
  touches no E2E path — a red or pending "E2E Tests" / "Production QA" no
  longer holds a migration PR's re-review for 12 hours and then alerts.
  When the diff does touch an E2E path they count exactly as before. A head
  whose only runs are E2E-class waits (no substantive evidence yet), and the
  lane fails closed to the old rule when the lib or the changed-file list is
  unavailable. `tests/review-ci-gate-test.sh` pins every branch.
  The read itself now has a second credential: `bin/lib/gh-ci-read.sh` retries
  `actions/runs` once on a read-only GitHub App token when the box's PAT 403s
  on it, so "CI status unavailable" means both credentials refused rather than
  "this box cannot read Actions at all" (2026-09-14, project-2;
  `tests/external-review-ci-read-test.sh`).
- **`bin/review-autopilot.sh`** (point 6): the aging-PR reviewer's prompt
  carries a deterministic line — computed by the script, not the model —
  saying whether this diff touches an E2E path, and therefore whether a red
  E2E-class check is a BLOCK or a note.
- **`bin/merge-sweep.sh`** — the CLEAN requirement is UNCHANGED, on purpose.
  With paths-gated browser jobs a non-UI PR's E2E skips green and the PR is
  CLEAN on its own, so the sweep needs no discount to land it; a UI PR whose
  E2E is red is exactly the PR that must not auto-merge, and CLEAN is the
  signal that still says so once branch protection stops requiring E2E; and
  the sweep merges unattended, so a second, looser reading of "green" there
  is where a red that should have blocked gets waved in. The two existing
  discounts (phantom-context green-run; pre-policy project-4) are untouched.
- **`bin/pipeline-health.sh` — the `permared:` detector** (point 5): hourly,
  for every `fleet.conf` repo (through `bin/lib/gh-repo-token.sh`, so a repo
  only the admin token can see is still covered and one no token can see
  pages as invisible), lists workflow runs on `main` from the last 30 days and
  groups them by workflow file. A workflow pages when its newest concluded
  runs are an unbroken red streak (`failure` / `timed_out` /
  `startup_failure`) of at least 3 runs whose oldest member is at least 3
  days old; a `success` ends the streak; `cancelled` / `skipped` / `neutral`
  runs are neither red nor green. ONE alert per (repo, workflow) per day:

  ```
  check <workflow> red <N> days on <owner/repo> — fix or delete (<K> consecutive red runs on main since <date>, no success between; <path>; latest <run url>)
  ```

  Dry-run on 2026-09-12 17:0xZ against the live fleet named exactly one:
  project-4 "E2E Tests", red 9 days, 53 consecutive red runs since 2026-09-03.
  Pinned by `tests/pipeline-health-permared-test.sh`.

### Lead review ratchet (BH-7941)

In the lead review, E2E is a ratchet. A failing E2E test is a BLOCK only when
it is a regression: it passes on main's latest full E2E run (or the nightly)
and fails on the head. A test that also fails on main is a NOTE with a
follow-up for its area. One full E2E run on the head is enough evidence; the
lead never blocks for "3 full runs" or a per-spec table.

- **`bin/lib/e2e-main-baseline.sh`** `emb_prompt_file` writes the lead
  prompt's `## Main E2E` section, between `## Live probes` and
  `## Conflict hotspots`. It loads through
  `bin/lib/lead-review/libs.d/202610230549-bh-7941-e2e-main-baseline.sh`. It
  reads main's newest completed E2E-class run (event push or schedule) and the
  head's, through `gh_rest`. It lists the failing Playwright spec ids red on
  both (pre-existing) and red on the head only (regression). A failed read is
  `COULD NOT READ (<why>)`, never "no failures". Pinned by
  `tests/e2e-main-baseline.bh-7941-test.sh`.
- **`prompts/lead-review-checklist.md` item 17** (v11) is the rule for the
  model.
- **`bin/lib/review-level.sh` `rl_cap`, lens lead only**, is the mechanical
  floor. Before the ALWAYS-BLOCK floor it rewrites an E2E finding that says
  the test is red on main (or on the nightly) too, or that asks for N full
  runs or a per-spec table, to
  `[NOTE demoted from <tag>, e2e ratchet (BH-7941): ...]`. A regression, a
  negation, a deleted or skipped test, a failure that names no main or
  nightly, or another ALWAYS-BLOCK class (a tenant leak found through a red
  spec) still stands. The phrases are in `catalog/review-e2e-ratchet.tsv`.
  The phrase alone never demotes a failure. `bin/lead-review.sh` passes the
  `## Main E2E` body to `rl_cap --e2e`, and a "red on main too" line demotes
  only when every spec file it names is in the measured pre-existing list and
  none is in the regression list. A line that names no spec file, or a review
  where main could not be read, stands. A `weakened-test` tag or text on a
  "red on main too" line stands. An evidence ask that names a regression spec
  stands. An evidence ask that also says the head is red (a failing run or
  spec, "both red"; the `e2e-head-red` row) stands, and so does one tagged
  `core-flow-broken`: the ask for more runs is on top of a real failure.
  Pinned by `tests/review-level-e2e-ratchet.bh-7941-test.sh` and, through a
  real tick, `tests/lead-review-e2e-ratchet.bh-7941-test.sh`.
- Settings rows (seeded by
  `worker/jobs/schema.d/202611031509-bh-7941-e2e-ratchet-knobs.sql`; per
  project `<key>.<project>`; env `REVIEW_LEVEL_<KEY>` wins):

  | Row | Default | What it sets |
  |---|---|---|
  | `review.e2e_ratchet` | 1 | 0 turns off the section read and the demotion |
  | `review.e2e_baseline_runs` | 50 | completed runs per list read (1-100) |
  | `review.e2e_baseline_jobs` | 2 | failed-job logs read per review |
  | `review.e2e_baseline_ids` | 30 | failing spec ids kept per run |
  | `review.e2e_baseline_timeout_s` | 15 | seconds per REST call |
  | `review.e2e_baseline_calls` | 6 | REST calls per review |

- CI, the merge conductor and the merge queue do not change. The in-build
  review and `bin/review-prs.sh` keep their E2E behaviour.

## Per-repo status (2026-09-12)

The app-repo halves are being opened in parallel by sibling lanes on branch
`orc/e2e-policy-20260912`. Status below is as of 17:05Z on 2026-09-12 and is
what THIS lane could see; the PR bodies carry the branch-protection
before/after and the CI evidence.

| Repo | Branch / PR | Fast checks (PR-required candidates) | E2E-class workflows | Status |
|---|---|---|---|---|
| project-4 | [`orc/e2e-policy-20260912`](https://github.com/example-org/project-4/tree/orc/e2e-policy-20260912) · [#1462](https://github.com/example-org/project-4/pull/1462) | Typecheck, Unit tests, Guard (names as seen by the sweep's project-4 rule) | `E2E Tests` (`e2e.yml`, deployment_status; red on main since 2026-09-03) | PR open; branch protection result in its body |
| project-3 | [`orc/e2e-policy-20260912`](https://github.com/example-org/project-3/tree/orc/e2e-policy-20260912) · [#313](https://github.com/example-org/project-3/pull/313) | `CI` (`ci.yml`) | `E2E Tests` (`e2e.yml`), `Production QA` (`e2e-prod.yml`) | PR open; branch protection result in its body |
| project-1 | [`orc/e2e-policy-20260912`](https://github.com/example-org/project-1/tree/orc/e2e-policy-20260912) · [#654](https://github.com/example-org/project-1/pull/654) | `Guardrails` (`guardrails.yml`) | none on main as of 17:05Z (no `e2e*.yml`); the PR adds the suite | PR open (17:21Z); branch protection result in its body |
| project-5 | [`orc/e2e-policy-20260912`](https://github.com/example-org/project-5/tree/orc/e2e-policy-20260912) · [#426](https://github.com/example-org/project-5/pull/426) | `CI` (`ci.yml`), `Static guards vs current main` (`static-guards.yml`) | `E2E Tests` (`e2e.yml`) | PR open (visible to the admin token only; the default PAT 404s — see `bin/lib/gh-repo-token.sh`) |
| project-2 | not in this wave | `Guardrails`, `Migration SQL gate` | none | no browser suite |
| project-8 / project-6 | not in this wave | — | none | — |

When a sibling PR merges, replace its row's status with the merged sha and
the branch-protection GET result; when the first nightly runs, note the date.

## What "advisory" does NOT mean

- It never touches the merge sweep's CLEAN gate (above).
- It never applies to typecheck, lint, unit or harness-gate checks — those
  are substantive on every diff.
- It never applies when the changed-file list could not be fetched: fail
  closed, every red counts.
- It is decided by `bin/lib/e2e-paths.sh`, never by the reviewing model's
  reading of the diff.

## Personas

A QA persona is "sign in as this kind of user, then click through these flows".
The definition lives in the app repo at `qa/personas.json`, and the map from an
app name to the paths that app owns lives next to it at `qa/apps.json`.
`bin/lib/qa-personas.sh` is the ONE reader of both files: it validates the
schema, scopes the personas to a diff, and prints the rows the lanes log. The
flow engine (`bin/qa-drive.mjs`), the preview lane, the production lane and the
persona generator all code against the shapes below and parse nothing
themselves. The lib landed first, on purpose; both QA lanes now pick their
personas through it (see Picking, below).

Diagnostics (`personas.json: …`, `apps.json: …`, `jq missing`) go to stderr.
Stdout carries only documents, the word `NONE`, list lines and FLOW rows, so a
caller can pipe stdout into `jq` without filtering.

### Schema v1 — `qa/personas.json`

```json
{ "version": 1,
  "personas": [
    { "id": "owner", "role": "qa-owner", "sign_in": "clerk-ticket",
      "apps": ["web"], "out_of_bounds": ["/billing"],
      "flows": [
        { "id": "dashboard", "title": "See the dashboard", "route": "/dashboard",
          "observable": "the scans table renders", "production_safe": true,
          "steps": [ {"goto": "/dashboard"}, {"expect": {"selector": "role=table"}} ] },
        { "id": "new-scan", "title": "Start a scan", "route": "/scans/new",
          "observable": "a queued scan row appears", "production_safe": false,
          "cleanup": "delete the queued scan named qa-smoke",
          "steps": [ {"goto": "/scans/new"},
                     {"fill": {"selector": "input[name=name]", "value": "qa-smoke"}},
                     {"click": "button:has-text(\"Start scan\")"},
                     {"expect": {"selector": "role=row", "text": "qa-smoke"}} ] } ] } ] }
```

The rules, in the order the validator checks them:

- `version` is exactly `1`.
- `personas` is a non-empty array.
- Per persona: `id` is a string matching `^[a-z0-9-]+$` and unique across the
  file; `role` is a non-empty string; `sign_in` is exactly `"clerk-ticket"`
  (v1 has one sign-in kind, any other value is refused); `apps` is optional and,
  when present, an array of strings, each of which must be a key of
  `qa/apps.json`'s `.apps` when that file is given; `out_of_bounds` is
  required, a non-empty array of non-empty strings (it is stored for the lanes
  to read, never driven; BH-5204 made it the floor an agent-drafted file must
  meet, so a persona that names nothing it must not touch is refused); `flows`
  is a non-empty array.
- Per flow: `id` is a string unique within its persona (two personas may reuse
  the same flow id); `route` is a string starting with `/`, so an absolute
  `https://…` is refused; `observable` is a non-empty string; `production_safe`
  is a JSON boolean, so `"true"`, `1`, `null` and a missing key are all refused
  and none of them defaults; `steps` is a non-empty array; `cleanup` is a
  non-empty string and is required when `production_safe` is `false`; `apps`
  is optional and, when present, a non-empty array of strings, each one of the
  persona's own `apps` when the persona names any, and a key of
  `qa/apps.json`'s `.apps` when that file is given. A flow's `apps` defects
  are reported after its step defects.
- Per step: exactly one key, one of `goto` (string starting `/`), `click`
  (string), `fill` (`{"selector": string, "value": string}`) or `expect`
  (`{"selector": string, "text"?: string}`). Zero keys, two keys or any other
  key is refused.
- Unknown keys at the top level and on a persona are ignored and passed
  through, so a later version can add a field without breaking this reader.

`qa_personas_validate` stops at the FIRST defect and prints one line naming the
jq path that failed, for example:

```
personas.json: .personas[1].flows[1].production_safe: must be a JSON boolean
```

### `qa/apps.json` and the glob rules

```json
{ "version": 1, "apps": { "admin": ["apps/admin/**"], "web": ["apps/web/**", "src/**"] } }
```

`.apps` must be an object and every value must be an array of strings. A map
that is not, or a file that is not readable JSON, is refused before any persona
rule is checked, with one `apps.json: <jq path>: <problem>` line on stderr and
rc 1, so a malformed map never reaches the glob compiler as a raw jq error.

Globs are anchored at the repo root and are segment aware: `**` matches any
depth, `*` matches within one segment and never crosses a `/`. So
`apps/admin/**` matches `apps/admin/x.ts` and `apps/admin/a/b/c.ts`, and does
NOT match `apps/admin-tools/x.ts` (a different segment) or
`docs/apps/admin/x.md` (not root anchored). Brackets are not character classes
in v1: a path like `apps/admin/[id]/page.tsx` is matched literally. Changed
paths are compared exactly as `git diff --name-only` prints them, with no
`./` normalisation.

A persona is in scope for a diff when it names no apps (`apps` absent or `[]`),
or when any changed file matches any glob of any app it names. When the
`apps.json` argument is empty every persona is in scope; that is the "this repo
has no app map" case, and it errs toward driving more, never less.

### The scoped file — what `qa_personas_scope` prints and `qa-drive.mjs --flows` reads

```json
{ "version": 1, "mode": "production",
  "personas": [ { "id": "owner", "role": "qa-owner", "sign_in": "clerk-ticket",
    "apps": ["web"], "out_of_bounds": ["/billing", "/settings/danger"],
    "flows": [
      { "id": "dashboard", "title": "See the dashboard", "route": "/dashboard", "observable": "the scans table renders", "production_safe": true,
        "steps": [ {"goto": "/dashboard"}, {"expect": {"selector": "role=table"}} ] },
      { "id": "new-scan", "title": "Start a scan", "route": "/scans/new", "observable": "a queued scan row appears", "production_safe": false,
        "cleanup": "delete the queued scan named qa-smoke",
        "skipped": "write flow, production" } ] } ] }
```

That is a real `production` document, printed by the lib from the fixture in
`tests/fixtures/qa-personas/`: the write flow kept its metadata and its
`cleanup`, lost its `steps`, and gained `skipped`. The same scope call in
`preview` prints the same persona with `new-scan` still carrying its four steps
and no `skipped` key.

Personas pass through unchanged, including `apps`, `out_of_bounds` and any
unknown keys. Only flows are transformed, and only by mode:

- `preview` — every flow keeps its `steps`, nothing gains `skipped`.
- `production` — a `production_safe: false` flow keeps its metadata, loses
  `steps`, and gains `"skipped": "write flow, production"`. Safe flows are
  untouched, so a file with no write flows produces the same document in both
  modes apart from `mode`.

When no persona is in scope the output is the single word `NONE` and rc 0. A
file that fails validation prints the validate line on stderr and returns 1: it
never degrades to `NONE` and never prints a partial document. A mode other than
`preview`/`production`, and a changed-files path that does not exist, are both
refused the same way — a missing diff file is not an empty diff.

### Picking: one role per changed area

Both lanes (`bin/e2e-smoke.sh` on the preview, `bin/postmerge-qa.sh` in
production) call `qa_personas_pick`, not `qa_personas_scope`. One role that
can see a changed area is enough to test it, so the lanes drive the fewest
personas that cover the diff (the operator, 2026-10-07).

1. **Changed areas.** Each app in `qa/apps.json`, in file order, with at least
   one changed path matching one of its globs, then `(unmapped)` when some
   changed path matches no app. With no `apps.json` there is one area, `*`.
2. **Owners.** The in-scope personas whose `apps` name the area, plus the
   personas that name no apps. `(unmapped)` is owned only by no-apps personas;
   `*` by everyone.
3. **Pick** the first `per-area` owners of each area, in `personas.json` order.
   Order the file least privileged first: that order is the ranking. A persona
   picked for two areas is driven once.
4. **Skipped.** Every persona not picked, with why: `area already covered`
   when it owns a changed area, else `not relevant to the diff`.
5. **Flows.** A picked persona keeps the flows with no `apps`, and the flows
   whose `apps` name an area it was picked for (all of them for `*` and
   `(unmapped)`). The rest go to `pick.flows_dropped`, not into the document
   with a `skipped` mark. If that would leave the persona with no flow, it
   keeps them all.
6. No persona picked is `NONE`. An empty diff with an app map has no area, so
   it is `NONE` even when a no-apps persona exists.

The picked document is the scoped document with `.personas` narrowed and one
more top-level key, which `qa-drive.mjs` ignores:

```json
"pick": { "per_area": 1,
          "areas":   [ {"area": "finance", "personas": ["finance-lead"]} ],
          "skipped": [ {"id": "viewer", "why": "not relevant to the diff"},
                       {"id": "admin",  "why": "area already covered"} ],
          "flows_dropped": [] }
```

`per-area` is the `qa.personas_per_area` settings row (seeded `1` by
`worker/jobs/schema.sql`), else env `QA_PERSONAS_PER_AREA`, else `1`. A value
that is not a whole number of at least 1 is `1`, with one stderr line saying
so. `E2E_MAX_PERSONAS` is unchanged and still caps the picked list.

Both lanes print the pick as one line. Grammar:

```
PERSONAS: picked <area>:<id>[+<id>…]|none …; skipped (not relevant to the diff): <ids>|none; skipped (area already covered): <ids>|none[; flows not relevant to the diff: <persona>/<flow> …]
```

The preview lane writes it into `e2e.md` immediately before the
`Personas: N in scope, D driven (mode preview)` line, where N is the picked
count. The production lane appends it to the report header after
`<ids> (mode production) — `, and logs it as
`<build>: PERSONAS: picked …`. When nobody is picked the header says
`PERSONAS: NONE (no persona owns a changed area)`.

### Drive flags, FLOW rows, coverage lines

Pinned here, implemented by the sibling slices: no flag below is parsed and no
row below is printed by anything on main yet. They are written down first so
the flow engine and the two lanes agree on one grammar instead of three.

```
bin/qa-drive.mjs <base> <resolve-root> <out-dir> [paths...] --flows <scoped.json> [--persona <id>] [--preview|--production]
```

With no mode flag the default is `production`, which is the fail-closed reading:
write flows are skipped unless someone asks for preview.

```
FLOW <persona-id> <flow-id> pass steps=<k>/<n> shot=<path|->
FLOW <persona-id> <flow-id> fail steps=<k>/<n> shot=<path|-> <reason>
FLOW <persona-id> <flow-id> blocked <reason>
FLOW <persona-id> <flow-id> skipped (write flow, production)
```

The coverage lines:

```
QA COVERAGE: screens=<n> flows=<executed> shots=<png count>
E2E COVERAGE: routes=N failed=M flows=F flows_failed=G flows_blocked=B
```

`flows=` counts pass plus fail only, never blocked or skipped. The five-field
`E2E COVERAGE:` form appears ONLY when a persona lane actually ran; with no
persona lane the two-field form stays byte-identical to what it prints today,
so nothing that greps for it has to learn a second shape.

### The library functions

```
qa_personas_validate <personas.json> [apps.json]
    rc 0 and silence when the file is valid. On the first defect, one line
    `personas.json: <jq path>: <problem>` on stderr and rc 1.

qa_personas_scope <personas.json> <apps.json|""> <changed-files-file> <preview|production>
    The scoped document (or `NONE`) on stdout, rc 0. Validates first: an
    invalid file gives the validate line on stderr, rc 1, and no stdout.

qa_personas_pick <personas.json> <apps.json|""> <changed-files-file> <preview|production> <per-area>
    qa_personas_scope, narrowed to one role per changed area (below). The
    picked document (or `NONE`) on stdout, rc 0. Refusals are scope's.

qa_personas_pick_note <picked.json>
    The one-line summary of the document's `pick` object.

qa_personas_per_area
    The per-area count: the `qa.personas_per_area` settings row, else
    `QA_PERSONAS_PER_AREA`, else 1.

qa_personas_list <scoped.json>
    One `<persona-id><TAB><role>` line per persona, in file order.

qa_personas_blocked_rows <scoped.json> <persona-id|*> <reason>
    One blocked row, in the grammar above, per flow of that persona, `*` for
    all of them. Flows already marked `skipped` still get a row: the lane is
    reporting that nothing ran, and "nothing ran" covers them too.
```

`qa_personas_list` and `qa_personas_blocked_rows` read a scoped document, not
the word `NONE`. A lane branches on `NONE` first; handing it to either of them
is a jq parse error, not an empty result.

Both lanes use `qa_personas_blocked_rows` for an unresolvable QA account, a
wrapper rc 75/90/91, a drive that emitted no FLOW rows at all, and the persona
cap (`not driven (persona cap)`).

Every function needs `jq`. Without it each one prints `personas.json: jq missing`
on stderr and returns 1 — never a silent pass.
