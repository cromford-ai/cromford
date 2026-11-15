# AGENTS.md

Notes for coding agents (and people) changing Cromford.

## How the factory expects changes to look

- One ticket, one branch, one PR.
- Small diffs. The size gate starts at 1200 lines and 30 files, and a plan over
  it is split before it is built.
- A new file over an edit to a shared list or index. Parallel changes that all
  append to one file conflict on a hunk none of them is about.
- Tests go in a new per-change file under `tests/`, and a test fails before the
  change and passes after it.
- No `$RANDOM` in tests, and a fixture secret carries a marker like `fixture`
  inside its value.
- A harmless metric (time, size, line count) is reported, never a hard limit.
  Money and safety caps stay hard.

Read [docs/OPERATING.md](docs/OPERATING.md) for the reasons, the knobs and the
defaults. [CONTRIBUTING.md](CONTRIBUTING.md) says how a change lands.
