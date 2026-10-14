# 2026-09-22 — BH-1304: case 7 renders its own registry, the stamp dir must be ours, harness-sync composes only on change

Doc: OPERATOR-SETUP

Three follow-ups carried out of the BH-1247 review (rounds 3 and 4 of #1275,
§ Suggestions). None of them changes what the fleet does; each removes an
order-coupling or a cost that taking `catalog/lanes.json` out of git introduced.

## 1. `tests/lane-liveness-single-fact-test.sh` case 7 renders what it imports

Case 7 imports `worker/jobs/src/index.js`, which reaches `core.js`, which
statically imports `../../../../catalog/lanes.json`. That file is generated and
no longer committed, so in a fresh checkout the import dies on
`ERR_MODULE_NOT_FOUND` — and the case passed anyway, because case 6's
`rendered_cron_dir` had already left a render in the checkout. Case 7 now
composes it itself, with the same two lines `tests/jobs-worker-test.sh` uses.

The ticket asked for `rendered_registry`, and that helper renders into
`$T/.rendered/lanes.json`. The import path is baked into the module and cannot
be pointed at `$T`, so calling the helper would have left the coupling in place;
the render goes into the checkout's git-ignored `catalog/lanes.json` instead.

## 2. `_lr_stamp` refuses a stamp directory it does not own

`bin/lib/lanes-registry.sh` keeps its staleness key in
`${TMPDIR:-/tmp}/harness-lanes-<uid>/stamp-<digest>`. That directory was created
0700, which protects the case where we created it — `mkdir -p` says nothing at
all about a directory somebody else got to first, and on a shared host that is
where the write lands.

A pre-existing entry is now used only if it is a real directory owned by this
euid. A symlink is tested for before `-O` (which follows one, so a link into a
directory we do own would otherwise pass), and another user's directory is
refused whatever its mode. Refused means `_lr_stamp` prints nothing and returns
1:

- `lanes_stamp_write` returns 1 — one lost convergence, never a write elsewhere.
- `lanes_json_path` reads it as "no stamp", so the render is stale and it
  re-renders into `catalog/`, exactly as it does after a `/tmp` sweep.
- the read-only-tree fallback tier (a shared `render-<key>.json` beside the
  stamp) is SKIPPED rather than aimed at the refused directory. That tier
  derived its directory with `dirname` of the stamp path, and `dirname ""` is
  `.` — a render in whatever directory the lane was running from, in a library
  whose one rule is that the render is the only thing it writes.

Fail-open is unchanged: a lane that cannot read its kill switch still gets a
registry, and the last resort is still an existing render however old.

## 3. `bin/harness-sync.sh` composes the registry only when a worker deploys

The worker block composed `catalog/lanes.json` before the change-key skip, so
every tick — one every five minutes on the hub, and almost all of them deploy
nothing — paid for a full `jq` composition it then threw away. The lane sources
are already inside the worker's change key (the `-lanes-<sha>` suffix), so an
unchanged key means the bundle would be identical. The compose moved below
`[ "$(cat "$WSTATE")" = "$WSHA" ] && continue`, before the D1 schema apply and
the deploy. `WLANES` carries the "this worker imports the registry" answer
across the skip and is reset per worker.

Behaviour on failure is deliberately unchanged: a compose failure on a changed
key still writes its ALERTS line and the deploy still runs, so `wrangler`
reports the bundle failure itself.

## State and commands this touches

- `${TMPDIR:-/tmp}/harness-lanes-<uid>/` — who may own it. No new state, no new
  key. A refusal costs one re-render.
- `bin/harness-sync.sh` deploy path — when the compose runs. `state/worker-deployed-<worker>`
  and its `<tree sha>-lanes-<lane sources sha>` key are untouched.
- Observable after deploy: a hub tick where `state/worker-deployed-jobs` does
  not move logs no compose in `logs/update-runners.log`.

## Tests

- `tests/lanes-registry-stamp-owner.bh-1304-test.sh` — A own dir accepted and
  stamped, B planted symlink refused (nothing written through it), C foreign
  dir refused (nothing written into it), D no render leaks into the caller's CWD
  and an existing render is still served. C needs root or passwordless sudo to
  chown; D needs a non-root runner. Each prints a SKIPPED line rather than a
  vacuous pass.
- `tests/harness-sync-render-on-change.bh-1304-test.sh` — drives
  `bin/harness-sync.sh` itself: R1 first deploy composes then deploys, R2 the
  no-op tick composes and deploys nothing, R3 a lane-file-only change still
  composes and redeploys, R4 a compose failure keeps its ALERT and its deploy,
  R5 a worker that does not import the registry composes nothing.
- `tests/lane-liveness-single-fact-test.sh` case 7 now runs on its own.
