# The conductor's READY gate decides on the REQUIRED checks (BH-8012)

Doc: MERGE-CONDUCTOR, MERGIFY

## What changed

On 2026-10-22 from 08:30Z to 09:54Z the conductor queued 0 project-6 PRs.
Three PRs were ready by the repo's own rule. project-6's `.mergify.yml`
required `check-success=ci`, and `ci` was green. The conductor log for #2296:

```
09:26:32Z example-org/project-6#2296 - -> WAIT_CI head=923d2b47 reviewed=923d2b47 merge=UNSTABLE reason=checks pending
09:26:38Z AUTOENQUEUE example-org/project-6#2296 not enqueued at 923d2b47: conductor — the conductor did not clear this head READY this tick
```

Only the four non-required `E2E n/4` checks were pending. Two gates held
the PR:

1. `mc_ci_state` (`bin/lib/mc/classify.sh`) reduces every workflow on the
   head. One pending workflow makes the word `pending`.
2. Autoenqueue G5 (`bin/lib/autoenqueue.sh`) accepted `mergeable_state`
   `clean` only. GitHub reports `unstable` while a non-required check runs
   or is red.

## The rule now

- `pr_worker` calls `mc_cireq_apply` (fragment
  `bin/merge-conductor.d/bh-8012-required-ci.sh`) at the ci-read step, after
  the memo block and before the red-strike block.
- `mcr_ci_override` (`bin/lib/mc-required-ci.sh`) turns a CI word of
  `pending` or `red` into `green` when all of these are true:
  1. `MC_CI_REQUIRED_ONLY` is not 0.
  2. The provider is `mergify` and the repo is not project-4 (the same
     exception as `mc_discount`).
  3. `mc_mergify_required_checks` reads at least one `check-success` name.
  4. One `commits/<head>/check-runs?per_page=100` page holds every run.
  5. The latest run of each required name (exact name) is
     `completed/success` (`crs_word`, the BH-7121 rule).
- Any other case keeps the raw word. The override never makes a word
  stricter, and it never changes `none` or `unavailable`.
- When it fires: one log line per (PR, head),
  `<key> CI_REQUIRED_GREEN on <h8>: required <names> green; <word> is non-required — not held on non-required checks`,
  and the `MC_ATTEMPTS` mark `cireqgreen <key> <head>`. The read memo keeps
  the raw word.
- A red non-required workflow takes no red strike and no rerun.
- The flake ladder does not read `green:UNSTABLE` when the override fired,
  so a cancelled non-required run buys no rerun.
- `mc_discount` already turns `UNSTABLE` + `green` into `CLEAN`, so
  `mc_classify` answers `READY`. The classifier did not change.
- Autoenqueue G5 accepts `unstable` when `mcr_ae_unstable_ok` says yes: a
  harness row (not external, BH-4572), the knob on, `MC_AUTOENQUEUE_CHECK`
  unset, and every G4 name came from `.mergify.yml` (not the legacy
  fallback list). G4 has already proved those names `completed/success` on
  the head in the same call. `blocked`, `dirty`, `behind` and all other
  states stay refused with the same skip line.
- Mergify still enforces its queue conditions.

## Not changed

- `mc_ci_state` and its other callers: `bin/blocked-resolver.sh`,
  `bin/lib/mq-premerge.sh`, `bin/lib/pr-owner/enroll.sh`.
- Non-Mergify repos. Branch protection required contexts are not read.
- No per-project "extra checks to wait for" setting existed, so none is
  kept. project-6 waits for no extra check.

## Knob

`MC_CI_REQUIRED_ONLY` (default 1; 0 = the behavior before BH-8012),
`catalog/lanes.d/merge-conductor.knobs.d/MC_CI_REQUIRED_ONLY.json`.

## Test

`tests/mc-required-ci.bh-8012-test.sh`: unit cases for the override and
for G5, and whole conductor ticks (READY plus the enqueue in the same tick,
required `ci` pending stays `WAIT_CI`, the kill switch).
