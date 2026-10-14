# The main-red detector publishes the detail row and honours an operator clear (BH-2373)

Doc: HARNESS-COORDINATION

Part of BH-2329, slice 3 of 4. The contract (the `main_red` and
`main_red_events` tables) landed in BH-2371 and the console banner in BH-2374.
The worker routes (`GET`/`PUT /api/main-red`, `POST /api/main-red/clear`) are
BH-2372, and that slice was still open when this one was built.

## What changed in `bin/main-red-detector.sh`

- **`mr_row <flag> on|off <reason>`** PUTs `/api/main-red` through `_jobs_req`.
  The body is `{name, active, slug, project, sha, workflow, job, run_url, since,
  reason}`.
  - `on` reads `sha`, `workflow`, `job`, `since` and `run` (sent as `run_url`)
    from the flag file that was just written.
  - `off` has no flag file left to read, so those fields go out null.
  - A field the flag lacks is null, never a made-up value.
  - `project` is the `fleet.conf` project whose repo column is the slug
    (`mr_project`). It is null when no row names the repo, which is the case
    for the harness repo itself.
- **`mr_publish` calls `mr_row` after the `flag_set` attempt**, whether that
  attempt landed or not. So every raise, still-red republish, new-sha rewrite,
  green clear and marker-heal also sends the detail row. `mr_publish` still
  returns `flag_set`'s rc.
  - A failed detail PUT logs `<flag>: detail row not published` and returns 0.
    The next red tick republishes it.
  - `--explain` logs `WOULD PUBLISH detail <flag>=on|off` and sends nothing.
- **`mr_cleared_load`** runs once per run, before the per-repo loop:
  `GET /api/main-red?all=1`. It reads the rows from `main_red`, or from
  `rows`, or from a bare array, and it keeps
  `MR_CLEARED[<name>]=<cleared_sha>` for each row where `active` is `0` or
  `false` and `cleared_sha` is non-empty.
  - If the read fails, answers 404 or does not parse, it logs one line,
    `main-red clears unreadable — no operator clear honoured this run`, and
    leaves the map empty. The detector then raises exactly as it did before.
  - `--explain` makes this read too.
- **The honour point** sits right after `mr_arms` and before the BH-1927
  confirm re-read. It applies when the judged sha (column 5 of `WORST`) is
  non-empty and equal to `MR_CLEARED[<flag>]`, compared as a whole string and
  never as a prefix. On a match the detector:
  - writes verdict `decision=red reason=operator-cleared sha=<sha>`;
  - removes `flags/main-red-<slug>` and `state/main-red/<flag>.published`;
  - logs `<slug>: main still red on <sha8> but an operator cleared this sha — no freeze, no page`;
  - moves on to the next repo. It makes no publish, sends no alert and does no
    confirm re-read.
  - `--explain` logs the same line with `WOULD HONOUR CLEAR` and deletes nothing.

## Why

A `pause_flags` row that an operator turned off came back on within five
minutes: the still-red path's `mr_publish on` re-raised it, or the first-red
path paged `--critical` again. A clear that re-raises on the next tick is not a
clear.

The honour is keyed on the exact sha. A new red sha is a new episode, so it
raises and pages as before. The same goes for a row that is still `active=1`,
a clear stamped on a different flag name, and an empty `cleared_sha`.

`bin/main-red-pr-pair.sh` reads verdict `decision=red` as "the detector has
looked" and freezes nothing on it. That means an honoured clear is not
re-raised from PR evidence either.

## Until BH-2372 is deployed

Production answers 404 on `/api/main-red`. Until the routes are deployed:

- every run logs `main-red clears unreadable` once and freezes exactly as it
  did before;
- every detail PUT logs `detail row not published`.

Nothing is honoured until the worker serves the GET. The GET's response key is
assumed to be `main_red`, the key the console banner reads, with `rows` or a
bare array also accepted. If BH-2372 uses a different key, the read counts as
unparseable and the detector fails toward the freeze.

Suite: `tests/main-red-clear.bh-2329-test.sh`.
