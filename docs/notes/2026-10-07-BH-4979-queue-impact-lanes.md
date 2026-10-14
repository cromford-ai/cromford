# The merge conductor works out each PR's impact lane, and Mergify parallel lanes ship dark (BH-4979)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

- New `bin/lib/queue-partition.sh`. `qp_impact` maps a PR's changed files to an
  impact lane: the suites `bin/test-impact.sh select --why` picks, minus the
  always-suites, or the serial lane with a reason (unmappable file, serial
  path, train, `fix-main-red`, more than 25 files, unreadable file list).
  `qp_partition` groups queued PRs into partitions (union-find over shared
  suites).
- `mc_enqueue_mergify` (`bin/lib/mc/queue.sh`) runs it after the
  `lead-verdict` publish and before the label, in the marked block
  `# >>> queue partition scopes (BH-4979)`. The settings row
  `queue_partition.mode` decides `off|shadow|enforce`, and no row means `shadow`.
  Shadow logs one `PARTITION` line per enqueue and uploads nothing.
- `bin/mergify-template.sh` has two new conf keys: `queue_mode`
  (`serial|parallel`) and `scope_default_capacity`. `serial` renders
  byte-identically to before. cromford.conf is committed `serial`.

## Why

One red PR in a serial batch stream failed and bisected PRs it could not
affect. Mergify's partition rules, which the ticket named, were removed on
2025-10-31. Their successor is parallel mode with manual scopes, and the
scopes have to be computed per commit. That's the conductor's job.

## What it touches

The live queue does not change in this PR. Turning lanes on is the flip in
docs/MERGIFY.md section 6, which needs `MERGIFY_CI_KEY` and a live PUT probe.
