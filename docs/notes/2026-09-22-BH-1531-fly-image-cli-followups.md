# 2026-09-22 — BH-1531: the baked-CLI drift floor now runs on failed nights too

Doc: DB-COORDINATION-SPEC

## What changed

Three edits in the Fly builder-image lane, the review notes N1/N2/N3 left on
#1520 (BH-1517):

- `bin/fly-image-refresh.sh` — the baked-CLI bookkeeping + drift floor block
  moved OUT of the `if [ "$OK" = 1 ]` branch, so it runs on every per-project
  iteration including a rebuild that FAILED both attempts. Consequences: the
  `fly_image_cli.<p>` settings row is refreshed every nightly run rather than
  only after a successful rebuild, and a failed-rebuild night now also raises
  the `CLI drift` ALERTS line (still one per project per UTC day, same flag)
  when the image the pool keeps running is more than `CLI_DRIFT_MAX_PATCH`
  patch versions behind `cli.claude_code.version` / `cli.codex.version`.
- `bin/fly-image-build.sh` — `state/fly/<p>.cli` is written only inside the
  `[ -n "$IMG_REF" ]` branch, next to `state/fly/<p>.image`. On the
  ref-not-parsed path both files are left untouched and the WARN line says so.
  That is what makes the floor above a real stale-builder detector: `.cli`
  always describes the image `.image` points at, never a build that never
  landed.
- `bin/fly-image-build.sh` — `_resolve_cli_version` runs the settings row
  through `cli_version_parse` before it becomes a `--build-arg`. A row carrying
  a version inside other text (`2.1.280 (Claude Code)`) still pins `2.1.280`; a
  row with no dotted number (`latest`, a typo) logs
  `WARN: <key> row "<raw>" is not a dotted version — ignoring it …` and falls
  through to the existing host-CLI fallback, with the existing FATAL refusal
  still firing when that resolves nothing either. Before this, `latest` reached
  the remote build and failed there twice a night, and the alert blamed the
  rebuild instead of the row.

## Why

The floor as merged compared the row with the file the same run had just
written — a self-compare that could not detect a stuck builder. N2 is the
precondition for N1 being meaningful, and N3 stops an operator typo from
burning two remote builds per project per night.

## Verify

`bash tests/fly-image-cli-pin.bh-1531-test.sh` (cases A-N3a/b/c, A-N2,
A1-regress, C-N1a/b/c) with `tests/fly-image-cli-pin.bh-1517-test.sh` still
green. On the hub after merge: `tail -3 logs/fly-image-refresh.log` after the
next 05:40Z run, and `cat state/fly/<p>.cli` for one pool project.
