# The schema restamp also renames the fragment in plan.md and the PR body (BH-7120)

Doc: MERGE-CONDUCTOR

## Why

On 2026-10-16 the conductor restamped PR #7055's fragment
`worker/jobs/schema.d/202610160227-bh-6889-alert-lines.sql` to `202610160644-…`
(commit 9586feeebb). The lead-review enqueue then refused the PR:
`plan-files: files not in the plan's "Files to touch" ...: worker/jobs/schema.d/202610160644-bh-6889-alert-lines.sql`.
A person fixed plan.md by hand in 942e0d8d92.

The cause had two parts:

- The BH-6889 plan named the fragment by a placeholder,
  `worker/jobs/schema.d/<UTC-minute>-bh-6889-alert-lines.sql`, and never by the old
  name. `sr_apply` rewrites only exact old basenames, so plan.md did not change.
- The PR body's `## Files outside the plan` line named the old path. The restamp
  never edits the PR body.

## What changed

- `bin/lib/schema-restamp.sh`
  - `_sr_py_replace` has two new modes, `rewrite-plan` and `equal-plan`. After the
    basename rule, `<dir>/` + STAMPISH + `<suffix>` becomes `<dir>/<new>`.
    `<suffix>` is the `-<key>-<name>.sql` tail of the old name. STAMPISH is
    exactly 12 digits, or one `<…>` placeholder with no `/`, `<`, `>` or space
    inside. A suffix that two renames in one dir share gets no placeholder rule.
  - `sr_apply` applies `rewrite-plan` to each `.harness/specs/<KEY>/plan.md`
    that the PR added or changed since the merge-base. The edit is in the same
    restamp commit.
  - `sr_commit_only` checks an M line at `.harness/specs/<KEY>/plan.md` with
    `equal-plan`. Every other M line keeps `equal`. Any other plan.md change
    (an extra line, another stamp, a nested `sub/plan.md`) is still rc 1.
  - New `sr_text_rewrite <plan-lines> <file>`: rewrites old basenames to new in
    one file. rc 0 changed, 1 unchanged, 2 failed.
- `bin/lib/mc-prequeue.d/restamp.sh`
  - After a confirmed push (ls-remote shows the new sha), `_pq_rs_body` reads
    the PR body with one `gh_rest GET`, runs `sr_text_rewrite` on a copy, and
    sends one `gh_rest PATCH` only when the text changed.
  - The answer stays `pushed <sha> <n>` in every body outcome. There is no
    alert and no retry. One log line:
    `<key> SCHEMA_RESTAMP body <patched|unchanged|failed> pr=<num> reason=<text>`.

## Tests

- `tests/schema-restamp-plan.bh-7120-test.sh`: the lib, and a
  `psc_plan_missing` round trip on the restamped head.
- `tests/prequeue-restamp-body.bh-7120-test.sh`: the conductor hook through
  `pq_gate`, with a `gh_rest` stub.
