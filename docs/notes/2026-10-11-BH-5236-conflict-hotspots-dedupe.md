# Conflict hotspots: one count per merge, no mergify or stale refs (BH-5236)

Doc: CONFLICT_HOTSPOTS

## What changed

- `bin/conflict-hotspots.sh` replays each sync merge once per run. Before, the
  claimed set was reset for every PR and every branch, so one sync merge that
  four refs reached counted four times. The first PR or ref that reaches a
  merge owns the count. A branch tip sha is replayed once, so two refs at the
  same sha count one tip conflict.
- Refs whose id starts with `mergify/` are skipped by default and counted in
  the new footer key `branches_mergify_skipped`. `--include-mergify` scans
  them, after every other ref, so the real branch keeps the count.
- When `--branches` is `refs/remotes/<remote>/` and `<remote>` is configured,
  the script makes one `git ls-remote --heads <remote>` call. A local ref the
  remote no longer has is skipped and counted in `branches_stale_skipped`.
  The footer says `remote_check=on|off`. A remote that cannot be listed is the
  new rc 4, with no TSV printed. `--no-remote-check` turns the check off.
- `iso()` falls back to BSD `date -r` when GNU `date -d` fails, so the since
  and until labels print on macOS.
- `bin/conflict-hotspots-fleet.sh` fetches with `--prune`, so the weekly lane
  removes deleted branches from each box checkout.
- The new footer keys are at the END of the `# ref=` line. The fleet lane's
  `footer()` reads `pr_merges`, `sync_merges` and `merge_tree_errors` as before.

## Why

The ticket measured 103 conflicted sync records in a 72 h run that were only
67 distinct merges. Stale `origin/mergify/merge-queue/*` refs on the checkout
held the same ticket commits, and each one counted the conflict again.

## Regenerated doc

`docs/CONFLICT_HOTSPOTS.md` is regenerated with the fixed script over the same
window (`--now 1791335073`), from a new full clone made on 2026-10-11. Conflicted
sync merges went from 424 to 382, and unmerged branches scanned from 640 to 551.
The doc's correction section has the full old and new totals.

Suite: `tests/conflict-hotspots-dedupe.bh-5236-test.sh`.
