# Builds of record: a ledger reader lib (BH-2312.0)

Doc: JOBS

`bin/lib/builds-of-record.sh` (BH-2347) is new. It is the read side of the key -> PR binding the
build already writes to the jobs ledger (`result` and `pr_url` artifacts). The BH-2312 lanes that
scan `builds/*/RESULT` will source it; this slice has no consumer yet and changes no lane.

The caller sources `bin/jobs-client.sh` first. Without `job_artifact_feed` every call is rc 1.

- `bor_list <project> [since] [limit]` makes two `job_artifact_feed` calls (`result`, `pr_url`) and
  joins them on job_id in one awk pass. It prints TSV
  `key, build_dir, box, updated_at, result_line, pr_url (or -), job_id`, one row per build_dir (the
  newest), with the `pool-`/`fly-` copy prefix stripped. rc 0 rows, rc 2 none, rc 1 outage on either
  feed and nothing printed.
- `bor_local_dir <build_dir>` prints `$H/builds/<name>`, else `pool-<name>`, else `fly-<name>`;
  rc 2 when none is on disk.
- `bor_union <project>` is `bor_list` plus local `<project>-<KEY>-*/RESULT` records the ledger does
  not name (job_id `-`, RESULT mtime, first RESULT line). The rest of a dir name must start with a
  ticket key, so `project-4` does not take in `project-4-*`. rc 1 from `bor_list` is rc 1 here.

The knob: `BOR_LIMIT` (rows per feed call, default 500, max 1000) is registered in
`catalog/lanes.d/_lib.builds-of-record.json`, so the settings row `lib.builds-of-record.bor_limit`
sets it for a caller that has sourced `bin/lib/lane-gate.sh`. The ticket said "via `lane_setting`";
no such function exists, and `lib_env_apply` is the mechanism a shared lib's knob uses. A feed that
returns `limit` rows writes `BOR_TRUNCATED=1` to stderr and exports it (the export only survives a
direct call, not `$(...)`).

Tests: `tests/builds-of-record.bh-2312-test.sh`.
