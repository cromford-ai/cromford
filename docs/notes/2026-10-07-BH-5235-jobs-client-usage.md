# jobs-client's usage line is generated from the arms (BH-5264, BH-5235.4)

Doc: DB-COORDINATION-SPEC

## What changed

- `bin/jobs-client.sh` no longer carries its usage as one literal. That line
  was about 6 KB on the `*)` arm, and every PR that added a verb edited it, so
  any two verb PRs conflicted on a hunk neither of them was about.
- Each outer arm of `case "$CMD" in` now has its usage entry on the line above
  it, as `    #: <verb> <args>`. `transcript-get` has two, one per call form.
- `_jc_usage`, defined in the direct-invocation block, joins those lines with
  `|` in arm order and prints `usage: jobs-client.sh {...}`. The `*)` arm is
  `_jc_usage >&2; exit 2`, so the rc and the one-line stderr shape are what they
  were. The function is not defined when the file is sourced.
- `rule-unset` had an arm and no usage entry. It now has
  `#: rule-unset <scope> [selector] [kind]`, matching `job_rule_unset` in
  `bin/lib/jobs/jobs.sh`.
- The entries are the old ones verbatim. The generated list is the old list in
  arm order plus `rule-unset`; no arm moved.

## Adding a verb

Add the arm and a `    #: <verb> <args>` line directly above it, at 4 spaces.
Nothing else lists the verbs, and no test pins today's list either.
`tests/jobs-client-usage.bh-5235-test.sh` goes red on an arm with no `#:` line
and on a `#:` line with no arm. Against the 645b72ecb literal it only checks
that every old entry is still a `#:` line and that the old arms keep their
relative order, so it goes red when someone edits or drops an old verb or moves
its arm, but not when a verb is added. Its U5b case adds a documented verb to a
scratch copy and stays green, which is the proof.

## Open PRs that touch the old line

The ticket names #5163, #4714, #4332 and #4070 as open PRs that edit the
deleted usage literal (not re-checked from the build box, which has no GitHub
read). A PR like that conflicts once on rebase. Resolve it by dropping its
usage edit and adding a `#:` line above its new arm instead.
