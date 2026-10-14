# BH-4987: worker/jobs/schema.sql is composed from schema.d/ fragments

Doc: worker/jobs/README.md

What changed: `worker/jobs/schema.sql` was the top conflict hotspot in
`docs/CONFLICT_HOTSPOTS.md` (BH-4986), because every new table was appended at
its end and two builds that each added one collided on the same hunk. Its
content now lives in `worker/jobs/schema.d/`. At this commit the whole file
moved, byte for byte, into fragments. What main gained before this landed
sits at its byte position: the base is split around the mid-file blocks
(`0000-base.sql`, `0001-bh-4985-size-gate.sql`, `0002-base-rest.sql`), and the
later tickets have their own files, `0000-bh-4717-*` and `0001-size-gate-hotfix`
through `0010-bh-5559-staff-charter` (15 fragments at merge time). The composition is
still byte for byte main's `schema.sql`.
`bin/schema-build.sh` composes `schema.sql` from the fragments: sorted by name
under `LC_ALL=C`, concatenated with plain `cat`, nothing added.

The rule from now on: a new table is a new file,
`worker/jobs/schema.d/NNNN-<name>.sql` (next free number, lower case name),
plus `bin/schema-build.sh --write`, and both files go in the same commit. Do
not edit `worker/jobs/schema.sql` directly. To change an existing statement,
edit the fragment that holds it and re-run `--write`, as often as you like
before the commit: `--write` knows its own earlier render.

Order is decided by the FULL file name under `LC_ALL=C`, not by the number
alone, and numbers are shared (`0000-base` and `0000-bh-4717`, three `0002-*`).
So pick a number higher than every existing one when your statement reads from
an earlier one (an `INSERT ... SELECT` seed, for example), and check where
`ls worker/jobs/schema.d/` puts the new file.

`--write` refuses, and names the statement, when the working `schema.sql` or a
commit on the branch holds a statement no fragment holds. Move a new statement
into a fragment. If it is an older text of a statement a fragment already
holds, edit that fragment instead: a second `CREATE TABLE IF NOT EXISTS` is
skipped by D1.

A merge-from-main push that touches `worker/*/schema.sql`, `worker/*/schema.d/`,
`bin/schema-build.sh` or `bin/lib/d1-schema.sh` runs the renders step, and so
`--check` (the `renders` row of `catalog/ci-merge-reuse.tsv`).

`worker/jobs/schema.sql` stays committed. It is unchanged in this commit, and
its readers (the D1 apply in `bin/harness-sync.sh`,
`bin/worker-schema-upgrade.sh`, CI's "schema.sql applies over main's" step,
the worker test corpus, about 220 files) read it exactly as before.

What keeps the two in step:
- CI's "lane renders generate and their sources validate" step runs
  `bin/schema-build.sh --check`, which is red on a hand edit to `schema.sql`, on
  a fragment committed without its render, and on a malformed fragment (stray
  file, bad name, empty, no final newline, a statement split across two
  fragments).
- `docs/verification-map/index/tail.md` declares the file `committed` in its
  Generated files table. When two branches that each add a fragment conflict on
  the render, the rebase lane union-resolves it (BH-4641) and then
  `mc_regen_generated` re-renders it from the merged fragments. The merge train
  takes one side and runs `bin/schema-build.sh --write`. Nobody hand merges it.
- The repo's Verification Contract runs `bin/schema-build.sh --check` after a
  train's regenerate.
- `--write` never deletes a statement. A branch cut before the split appends
  its tables to `schema.sql`. If `--write` finds a statement in `schema.sql`, or
  added to it by a branch commit that is not on `origin/main`, and no fragment
  holds it, it exits 1, names the statement and leaves `schema.sql` as it was.
  The rebase lane then logs a failed regenerate and CI's `--check` stays red, so
  the branch is parked, not stripped. Fix: move the statement into a new
  `schema.d/NNNN-<name>.sql` and run `--write` again.

`worker/watchdog` has no `schema.d/` and is skipped. The Cloud worker moved
to example-org/cromford-web (BH-5239).
