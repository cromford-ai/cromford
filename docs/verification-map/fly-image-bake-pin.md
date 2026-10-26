# Baked-dependency pin and drift (Fly builder images)

**What it is:** every tool the Fly builder image installs is pinned to an
exact version held in a settings row, `bake.<name>.version` (BH-1528, extending
BH-1517's claude/codex pin). The manifest of names lives in
`bin/lib/bake-deps.sh`; the versions only ever live in the rows. The Dockerfile
takes one `ARG` per tool, installs exactly that version from a versioned
artifact, and fails the build if `<tool> --version` says anything else.

**How an operator reaches it:** no UI. `bin/bake-seed.sh` prints every row (and
exits 1 while one is missing); `bin/bake-seed.sh <name>=<version> ...` writes
missing rows, `--force` replaces existing ones. The next
`bin/fly-image-build.sh <project>` (or the nightly `bin/fly-image-refresh.sh`)
picks the change up.

**Preconditions / seed needs:** the rows. Resolution per dependency is row ->
the version this project's last good image baked (`state/fly/<project>.bake`)
-> the hub's own install, only where `bin/lib/bake-deps.sh` approves a probe
(rtk, codegraph) -> refuse. Before the first pinned build of a project there is
no `.bake`, so the rows must exist (`bin/bake-seed.sh`), or every image of that
project refuses and the pool keeps its last good image.

**Per-project dependencies (BH-8319):** a heavy extra only some projects need
(today: `rust` and `webkit`, manifest `bake_project_deps` in
`bin/lib/bake-deps.sh`) is baked ONLY when that project's own row names an
exact x.y.z:

- `bake.<project>.rust.version` (for example `1.90.0`): the official
  static.rust-lang.org toolchain, checked against its `.sha256`, verified with
  `cargo --version`, plus a `cargo fetch --locked` crate cache on the warm layer.
- `bake.<project>.webkit.version` (for example `2.48.7`, the upstream version of
  `libwebkit2gtk-4.1-dev`): the Tauri/webkit system packages.

`bin/fly-image-build.sh` renders `fly/Dockerfile` per project into
`fly/.render/` (`bake_render_dockerfile`): each `# >>> project-<name>[-*]` block
stays only for a kept name. With no row the render is the old Dockerfile byte
for byte, so the other pools rebake nothing. `off` or no row skips the block
(deleting the row is the opt-out). A row with no exact x.y.z (`latest`, `1.90`)
refuses the build before flyctl runs. A settings outage keeps the version the
last image baked. The baked value lands in `state/fly/<project>.bake` (and so
`fly_image_bake.<project>`) as `rust=<v>` / `webkit=<v>`, and the build log
prints `== project deps: rust=<v|skipped> webkit=<v|skipped> ==`.

Operator step to opt a project in (on the hub):

```bash
. bin/jobs-client.sh && setting_set bake.project-6-desktop.rust.version 1.90.0 "BH-8319 opt-in"
bin/fly-image-build.sh project-6-desktop   # log: bake-pin: rust 1.90.0
```

**How to drive it:**

| what | how |
|---|---|
| resolution order, the refusal, build-arg plumbing, the Dockerfile layout, bake-pin checks, drift alerts, the seeder | `bash tests/fly-image-bake-pin.bh-1528-test.sh` |
| per-project rows, the render, `bake_apt_version`, the project blocks, the stubbed `cargo --version` check | `bash tests/fly-image-rust-bake.bh-8319-test.sh` |
| a real build (x86_64 docker with buildx) | `docker buildx build --platform linux/amd64 --build-arg <every *_VERSION> fly/` — each tool prints `bake-pin: <tool> <version>`. The source `fly/Dockerfile` carries every project block, so it needs `RUST_VERSION` and `WEBKIT_VERSION` too; for a project without them, build its render (`. bin/lib/bake-deps.sh; bake_render_dockerfile fly/Dockerfile fly/.render/Dockerfile.x` then `-f fly/.render/Dockerfile.x`) |
| on the hub | `bin/bake-seed.sh`, then after a nightly run `cat state/fly/<project>.bake` |

**Files it owns on a live box:**

- `state/fly/<project>.bake` — `<name>=<version>` lines for the image
  `state/fly/<project>.image` points at. Written ONLY when this run parsed a
  pushed image ref (the BH-1531 rule for `.cli`).
- settings `fly_image_bake.<project>` — the DB twin of that file, refreshed on
  every nightly iteration, a failed rebuild included.
- `flags/alerted-fly-image-bake-drift-<project>-<name>-<YYYYMMDD>` — one drift
  alert per project per dependency per UTC day.
- `flags/alerted-fly-image-bake-norow-fleet-<YYYYMMDD>` — one `[fleet]` "no
  usable row" line per UTC day naming every missing row. It needs no `.bake`,
  so it also fires before the first pinned build.
- `/opt/warm/pnpm-home` inside the image (with `/root/.local/share/pnpm` a
  symlink to it): the pnpm store, shipped in the same COPY as
  `/opt/warm/repo/node_modules` so their hardlinks survive; `bake_warm_links`
  fails the build when none do.

**What must never regress:** no install in `fly/Dockerfile` may resolve
"latest" (no curl|sh installer, no apt repo that only serves the newest, no
version literal); an empty ARG and a version mismatch must both fail the build
by name; the warm stage must depend on base alone, so only a node bump or a base
edit rebakes it; the pnpm store and node_modules must never cross into the
final stage in separate COPYs (that doubles their bytes); a settings outage must never read as "no rows" (no alert) and
must never break a project that has a last baked set.
