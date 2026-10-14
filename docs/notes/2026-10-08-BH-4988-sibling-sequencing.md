# BH-4988: sequence rollout siblings on any shared file, seams in the .0 contract

Doc: SCHEDULER

What changed:

- New `bin/plan-sibling.sh`. `bin/lib/rb/gates.sh`'s `# >>> plan overlap` block
  runs `plan-sibling.sh check` whenever `bin/plan-overlap.sh` says build. For a
  child ticket (a `Part of #P` line in its body) on a GitHub-Issues board it
  reads the open sibling issues (same `Part of #P`), their open PRs (head
  `ticket/<prefix>-<n>`, `ticket/<prefix>-<n>-rN` or `agent/<PREFIX>-<n>`,
  minus the PR this build is stacked on) and those PRs' changed files. A
  non-fragment intersection with this plan's `planned-files.txt` answers
  plan-overlap's own `OVERLAP_DEFER <KEY> vs <SIB> files=[..]`, so the existing
  defer and `After:` hold apply until that PR merges or closes. Disjoint
  siblings still build in parallel.
- Every `After:` decision on a child ticket (from plan-sibling or plan-overlap)
  is posted once on the child issue by `plan-sibling.sh note`, deduped on the
  comment-mark key `sequenced <project> <KEY>:<OTHER>`. The mark is written only
  after the post answered rc 0.
- Both decomposer prompts in `bin/run-decompose.sh` tell the `.0` contract to
  pre-create the shared seams (fragment file or registry slot per sibling,
  section stubs, empty module files) and name them on its contract line.
  `skills/harness/SKILL.md` says the same for author-planned rollouts.
- `bin/lanes-build.sh` composes the libs scope through stdin and a temp file
  instead of `--argjson`. One argv string is capped at 131,072 bytes. With
  the new fragment, the libs array (130,002 bytes once composed, more while it
  still carries each lib's source tag) went past that cap, and main's script
  failed `--check` with "jq refused the composition". Without the new
  fragment, the old and new scripts write byte-identical `catalog/lanes.json`.

Why: plan-overlap only sees builds in flight. A sibling that finished building
but has an unmerged PR was invisible at plan time, so the next sibling built
the same file and the two PRs conflicted at merge (BH-3921.1 vs .2 on
`bin/lib/triage-state.sh`).

Log lines (build `pipeline.log` and `logs/plan-hotspot.log`):
`PLAN_SIBLING <KEY> choice=after after=<SIB> pr=#<n> files=[..]`,
`choice=build siblings=<k> prs=<m> disjoint`, `choice=build unjudged=<what> rc=<n>`
(a failed read fails open and is never logged as "no siblings"),
`choice=build unjudged=in-app-board`, `incomplete=1` past a read cap, and
`comment=posted|already|failed|off`.

Knobs (`catalog/lanes.d/_lib.plan-sibling.json`, `lib.plan-sibling.*`):
`PLAN_SIBLING_SEQ` (1), `PLAN_SIBLING_COMMENT` (1), `PLAN_SIBLING_MAX_ISSUES`
(500), `PLAN_SIBLING_MAX_PRS` (8). Kill flag: plan-overlap's own
(`OVERLAP_SCHED=0`, `plan-overlap-off`).

Not done: in-app boards are logged `unjudged=in-app-board` (no sibling read, no
note). The fragment rule is a copy of `plan-overlap.sh:fragment_safe`, to be
moved into one lib after #5310 merges. `open_pr_for_key` does not see `-rN`
branches, so a hold on a rebuilt sibling is released at the first pre-PLAN
check and re-judged at the next plan.

Tests: `tests/plan-sibling-sequence.bh-4988-test.sh`.
