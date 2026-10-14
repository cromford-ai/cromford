# A head that moved without its patch changing keeps its verdict, with no new review

Doc: MERGE-CONDUCTOR

## What was wrong

- The merge conductor, `bin/review-prs.sh` and `bin/review-autopilot.sh` bought a Fable review
  (up to 400K context) whenever a PR's head moved past the reviewed head.
- The conductor's patch-id rebind caught a plain rebase. It missed a fix round that only merged
  main whenever main had touched a line near a hunk: the whole-diff patch-id includes context
  lines and is taken against the merge-base, which the merge moves (#2131). The two review
  lanes had no same-patch check at all.

## What changed

- `bin/lib/patch-same.sh` `patch_same <git-dir> <main-ref> <reviewed> <head>` is pure git and
  uses no model. It answers `identical`, `main-merge` or `patch-id`, and rc 1
  whenever it cannot prove the same patch:
  - `main-merge`: the head descends from the reviewed sha, and every commit between them that
    is not on main is a two-parent merge whose tree equals `git merge-tree` of its parents,
    with no conflict.
  - `patch-id`: `git patch-id --verbatim`, whitespace included. The conductor's own patch-id
    moved from `--stable` to `--verbatim` too: `--stable` strips all whitespace, so a Python or
    YAML re-indent, or `rm -rf $D/cache` -> `rm -rf $D/ cache`, kept the approved id (#2386
    review).
  - There is no range-diff rung: `git range-diff` pairs a mode change and a file-to-symlink
    swap as `=` (#2386 review).
- The conductor: `mc_patch_id_rebind` falls back to `mc_patch_same` when the patch-ids differ,
  and rebinds exactly as before.
- `bin/review-prs.sh`: on a moved head, it replays the standing verdict (REQUEST_CHANGES
  included) onto the new head with `job_verdict_rebind`. It makes no agent call, and nothing
  is posted to or dismissed on GitHub.
- `bin/review-autopilot.sh`: it writes the new head's key with the prior `reviewed … verdict=`
  line, which `mc_autopilot_verdict` reads as before. No call is made, nothing is posted, and
  the daily cap is not charged.
- A lead or human CHANGES_REQUESTED still stands: `bg_cr_standing` (BH-2199) reads GitHub
  review state, and a replay writes none.
- The iron guardrail 1 exception in `rules/topics/01-iron-guardrails.md` names the new proof.
