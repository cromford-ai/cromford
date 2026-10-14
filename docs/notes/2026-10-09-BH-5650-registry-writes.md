# Audited registry writes and the add-box command (BH-5650)

Doc: fleet-registry

## What changed

Wave 2 of 3 of BH-5633.

- harness-jobs has per-row write routes for the D1 registry, in
  `worker/jobs/src/routes/registry-write.js`. Projects and boxes have POST,
  PATCH and DELETE. A box also has `POST .../boxes/<box>/drain`. Lane membership
  and box accounts have POST and DELETE. Every column of those two tables is
  part of the key, so they have no PATCH.
- Each write route checks the registry admin token (403) before any read. It
  then validates the whole changed registry and writes one D1 batch: the rows,
  one `registry_audit` row per changed row and one version bump. A write that
  changes nothing writes no audit row and keeps the version.
- The import and the write routes share `applyRegistry`. The import still
  never deletes.
- `POST /api/registry/boxes` with `like: <box_id>` copies every lane
  membership of that box and every account row whose box is exactly the like
  box's name, id or cost name. Glob rows such as `pool-*` are not copied.
- `GET /api/registry` returns `known_lanes`: every lane the audit ever held a
  membership for. `bin/render-cron.sh` gives such a lane with no rows zero
  boxes, so a drain takes effect. A lane the registry never held keeps its
  file `.boxes`.
- In db mode, `bin/render-cron.sh` renders a box that has a registry boxes row
  and no lanes with its box fragments only. Before, it refused the box.
- `bin/registry.sh` is the operator CLI: `show`, `add-box`, `move-project`,
  `drain-box`, `add-project`.
- `cron/boxes/_template.d/` holds the PATH and fleet-managed fragments. A box
  with no own directory renders from it. `render-cron.sh --all` and
  `tests/lib/rendered.sh` skip directories that start with `_`, and
  `render-cron.sh _template` exits 2.
- The db-mode `fleet.conf` render writes `# @box <box> <ip>` for every box with
  an IP. `bin/fleet-conf.sh --tailnet-ip-of-box` and `--tailnet-ips` read it,
  so a box with no project yet answers its IP. A committed `fleet.conf` has no
  such line.
- `bin/load-project.sh` with `REGISTRY_SOURCE=db` writes the project row
  through `bin/registry.sh add-project` and does not append to or commit
  `fleet.conf`.
- `bin/registry-sync.sh` is a new `*/5` lane on every box. It does nothing
  unless `REGISTRY_SOURCE=db`. It re-renders and applies the crontab only when
  the registry version changed.

## Why

Wave 1 gave the registry a read path. Moving a project or adding a box still
needed a `fleet.conf` commit. This wave makes those changes an audited API
write that every box picks up on its next sync tick.
