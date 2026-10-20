# Module map: one file per module, a generated load order

A directory of sourced shell modules gets its load order from the modules
themselves. Each module declares its own place in one header line. A generator
writes the order to `<dir>/MODULES`, and a loader sources the modules in that
order. To add a module, you add one file and run one command. No existing file
and no hand-written list changes.

- Loader and order engine: [`bin/lib/module-map.sh`](../bin/lib/module-map.sh)
- Generator and CI gate: [`bin/module-map-build.sh`](../bin/module-map-build.sh)
- Tests: [`tests/module-map.bh-5240-test.sh`](../tests/module-map.bh-5240-test.sh)

## The header

Put this line in the first 30 lines of the module, directly under
`# shellcheck shell=bash`:

```bash
# module: <name> after: <dep> <dep>...
```

- `<name>` is the file name without `.sh`. It and each `<dep>` match
  `[a-z0-9][a-z0-9_-]*`.
- Separate deps with spaces or commas. No `after:`, or an empty `after:`,
  means no deps.
- A `.sh` file with no `# module:` line is not a module. The loader never
  sources it, and the generator never checks it.
- A `# module:` line that does not match the grammar is an error, not a skip.

## The order

`mm_order <dir>` uses Kahn's sort. When more than one module is ready, the
first name in `LC_ALL=C` order goes first, so the order is deterministic. A
cycle, an unknown dep, a name that is not the basename, a malformed header or
zero modules gives rc 1 and one line per error on stderr.

## Commands

1. Add or edit the module file and its header.
2. Run `bin/module-map-build.sh --write` to regenerate every `bin/lib/*/MODULES`.
3. Run `bin/module-map-build.sh --check` to validate. CI runs this command in
   the step "lane renders generate and their sources validate".
4. Commit the module and the regenerated `MODULES` together.

`bin/module-map-build.sh <dir>` prints the order of one directory.
`--check` gives rc 1 when `MODULES` is missing or stale, when the order fails,
when a function is defined in two modules of the same directory, or when a
module has a top-level `declare`, `typeset` or `local` with no `-g`. Both scans
are static; the script header states their limits.

## Loading

```bash
. "$HERE/lib/module-map.sh" || exit 1
mm_load "$HERE/lib/<dir>" || exit 1
```

`mm_load` reads `<dir>/MODULES` when it is readable, and the headers when it is
not. That fallback lets a scratch copy of `<dir>/*.sh` load. It checks that
every listed file is readable before it sources any of them. It sources at
function scope, so a module that sets a global with `declare` must use
`declare -g`.

## Users

`bin/lib/mc/` has headers and a generated `MODULES`. The shim
`bin/lib/merge-conductor-lib.sh` loads it with one guarded source of
`bin/lib/mc/load.sh`, and `load.sh` calls `mm_load` on its own directory
(BH-5240 C1). So a new mc module is one new file plus
`bin/module-map-build.sh --write`, and the shim does not change.

`load.sh` has no `# module:` header, so it is not a module. It sources
`bin/lib/mc/module-map.sh`, a git symlink to `../module-map.sh`. The loader
is written once, and a suite that copies `bin/lib/mc/*.sh` with `cp` gets a
real copy of it. Such a copy has no `MODULES`, so `mm_load` takes the order
from the headers. `tests/module-map-mc-cutover.bh-5240-test.sh` pins this.

`bin/lib/br/` has headers and a generated `MODULES` too (BH-5241). The
resolver does not call `mm_load` yet. It keeps its literal
`BR_MODULES="discovery keys ladder record cap headgate"` loop, because that loop names the missing module
in its `RESOLVER MODULE MISSING` refusal. `tests/br-split-layout.bh-5241-test.sh`
case B4 holds that literal equal to `bin/lib/br/MODULES`, in order.
`bin/lib/br/opt/` has no headers and no `MODULES`, so the build does not see it.
