# A rerun never sees the fixed workflow: close/reopen instead (BH-3787)

Doc: MERGE-CONDUCTOR

**Status (2026-10-01, BH-3787).** This is slice 4 of BH-3775 and fills the
contract's `cit_rekick_step` hook (see `2026-10-01-BH-3775-ci-timeout-budget.md`).
It only acts on a `CIT_TIMEOUTS` line, and only the scan slice writes those.
Until the scan slice lands, `CIT_TIMEOUTS` stays empty and this lib is never
called.

## Why

Say a required check dies at its `timeout-minutes`. The repo then fixes the
workflow file on the base branch. The BH-636 ladder still re-runs the dead
run. A rerun keeps the run's old merge ref and its old workflow file, so it
dies the same way. The PR then sits in `WAIT_CI` behind a `CI_FLAKE_TWICE` page
for a fix that has already landed. Only a fresh `pull_request` event reads the
new file, and a close/reopen is the event the conductor can fire.

## What changed

**`bin/lib/mc-ci-timeout-rekick.sh`** (new, sourced by `bin/lib/mc-ci-timeout.sh`
after its stubs):

- `cit_wf_changed_since <slug> <base> <wfpath> <since-iso>` returns rc 0 when
  the newest commit on `<base>` touching `<wfpath>` is strictly later than
  `<since-iso>`. It does this in one `gh_rest GET
  repos/<slug>/commits?sha=<base>&path=<wfpath>&per_page=1` per (slug, base,
  path) per tick. The answer is cached under `flock` at
  `$MC_TICK_DIR/<tick>.cit-wfhead-<slug>-<base>-<path>`. A failed or empty read
  is cached as `-` and reads as "not changed". The cache is keyed by the tick
  id because `MC_TICK_DIR` outlives a tick, and a base fix has to be seen on
  the very next one.
- `cit_rekick_step` sets `CIT_REKICK=1` on the first `CIT_TIMEOUTS` line whose
  workflow changed. What happens next:
  - The `citkick <key> <head>` mark is already in attempts: nothing happens and
    the ladder runs as usual.
  - Observe mode: it logs `<key> would kick <head8> (…)` and writes nothing.
  - Actions mode: it writes the mark FIRST, then calls `mc_kick_ci`.
    - The kick landed: it logs `CI_TIMEOUT_REKICK <key> <head> (…)` and sets
      `CIT_SKIP_RUNG=1`, so no rerun follows.
    - A HOLD or a refused close: it logs `CI_TIMEOUT_REKICK failed … held or
      refused, PR kept`.
    - Close landed, reopen failed: it logs `… close landed, reopen failed`.
      `mc_kick_ci` has already paged `LEFT CLOSED`.
    - Either failure keeps the mark and the ladder runs as usual.

The result is one kick per head. A new head is a new key and gets one more
kick. Turning `MC_CI_TIMEOUT` off, or the actions flag, turns this off.

Pinned by `tests/mc/ci-timeout-rekick.bh-3775-test.sh` (R0 to R7 against the
real `bin/merge-conductor.sh`).
