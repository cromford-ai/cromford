# Docs files never defer a build; changelog entries move to fragments (BH-9096)

Doc: SCHEDULER, BUILD-CONCURRENCY

## Why

On project-3 a build was deferred with
`OVERLAP_DEFER ... files=[docs/UI.md,docs/UI.md]`, and two builds that each
added a top entry to `docs/RECENT-CHANGES.md` conflicted on the second merge.

The `*.md` glob was not the cause. Three overlap paths never read
`OVERLAP_IGNORE`: `bin/plan-overlap.sh` (`judge`), `bin/plan-sibling.sh`
(`check` and `inflight`) and `bin/conflict-check.sh`. The other three
(`bin/overlap-guard.sh`, `bin/overlap-schedule.sh`, `bin/sibling-serial.sh`)
already dropped `docs/UI.md` with the default list.

## What changed

- `bin/lib/docs-overlap.sh` is the shared rule for the three paths. A pair is
  docs-safe when either side ends in lowercase `.md`. The rule is on when the
  resolved `OVERLAP_IGNORE` list holds the bare `*.md` token, which the default
  does. An override without `*.md` puts the docs collision back in all six
  paths. There is no separate switch.
- A docs-only result logs `PLAN_HOTSPOT <K> choice=build vs <K2> docs-only` or
  `PLAN_SIBLING ... docs-only` and prints no `OVERLAP_DEFER`.
- `bin/lib/changelog-fragment.sh:clf_strip` runs from the
  `# >>> changelog fragment` block of `bin/lib/rb/execute.sh`, before the gates,
  the review and the first push. It moves a pure addition to
  `docs/RECENT-CHANGES.md` into `docs/recent-changes.d/<key>.md` and resets the
  changelog to the merge-base, in one commit. A rewrite of an older line, a new
  changelog, or a diff that is only the changelog stays in the PR.
- Path list: row `conf.changelog-fragment.paths` (fallback
  `docs/RECENT-CHANGES.md`). Switch: `changelog-fragment-off`.

## Not done here

- No fold of fragments back into `docs/RECENT-CHANGES.md`. That needs a write
  to main, which a build box never does.
- `merge=union` is not relied on. A fragment has a unique name per ticket, so
  no merge driver is needed.

## Check on a box

`grep -E 'docs-only|changelog fragment:' builds/<project>-<KEY>-*/pipeline.log`

Suites: `tests/docs-overlap.bh-9096-test.sh`,
`tests/changelog-fragment.bh-9096-test.sh`.
