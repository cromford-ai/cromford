# A pool image can carry a Rust toolchain per project (BH-8319)

Doc: FLY-BUILDER-TRIAL

MKF-4 of #8315. project-6-desktop needs Rust and the Tauri/webkit packages to
build on the pool (MKF-5, #8320). No other project needs them.

## What changed

- `fly/Dockerfile` has three new marker blocks: `project-webkit` and
  `project-rust` (after `bake-pgtest`, before `cli-pin-verify`) and
  `project-rust-warm` (after `warm-links`). Every rust, webkit and cargo line is
  inside a block.
- `bin/lib/bake-deps.sh`: `bake_project_deps` (manifest: `rust RUST_VERSION`,
  `webkit WEBKIT_VERSION`), `bake_project_row_version`, `bake_project_resolve`
  and `bake_render_dockerfile`. `bake_deps` did not change.
- `fly/bake-pin.sh`: `bake_apt_version <pkg> <upstream>` gives the full Debian
  version for an exact upstream version, or FATAL.
- `bin/fly-image-build.sh` reads the rows `bake.<project>.rust.version` and
  `bake.<project>.webkit.version`. It renders a per-project Dockerfile into
  `fly/.render/` (a unique file per run, removed on exit) and passes it as
  `--dockerfile`, with one `--build-arg` per kept dependency. The kept values go
  into `state/fly/<project>.bake` as `rust=<v>` / `webkit=<v>`.

## Rules

- The row is the opt-in. No row, an empty value or `off` skips the block, even
  when the last image baked it.
- A row with no exact x.y.z (`latest`, `stable`, `1.90`) refuses the build
  before flyctl runs.
- A settings outage keeps the version the last image baked.
- With no row, the render is the pre-BH-8319 `fly/Dockerfile` byte for byte, so
  the other pools rebake nothing.
- The cargo fetch is bounded by `pool.warm_build_timeout_s` and is non-fatal
  (`warm-cargo: FAILED`, `/opt/warm/.warm-cargo-failed`).

## Operator step

`setting_set bake.project-6-desktop.rust.version <x.y.z>` (and
`.webkit.version`) through `bin/jobs-client.sh`, then
`bin/fly-image-build.sh project-6-desktop`. The log prints
`bake-pin: rust <x.y.z>`.

Test: `tests/fly-image-rust-bake.bh-8319-test.sh`.
