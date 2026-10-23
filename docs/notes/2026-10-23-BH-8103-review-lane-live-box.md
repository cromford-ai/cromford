# The review lane on a live box moves no shared checkout and runs no suite (BH-8103)

Doc: MERGE-CONDUCTOR, iron-law-guard

## What changed

- `mc_rereview` (`bin/lib/mc/rebase.sh`) starts `bin/agent-call.sh review` from
  a private, empty dir: `${MC_RR_SCRATCH_ROOT:-${TMPDIR:-/tmp}/mc-rereview-<uid>}/<repo>-<num>-<head12>`.
  It never starts from the cwd that the detached job inherited. The dir is made
  before the call and removed after it. If the dir cannot be made, the result is
  a lane failure (rc 2, `<out>.lanefail` names the dir), and nothing is called.
  A relative out file goes to agent-call as an absolute path.
- `bin/iron-law-guard.sh` family 7 applies on `HARNESS_LANE=review` on a live
  box. A box is live when `${HARNESS_CHECKOUT:-/root/harness-checkout}/.git`
  exists; `HARNESS_LIVE=1/0` overrides that. Rule `review-checkout` denies a
  git verb that moves HEAD or the work tree, and `gh pr checkout`, in a shared
  checkout or in a dir it cannot resolve. Rule `review-suite` denies a run of a
  shell suite. Each deny writes one findings row and no ALERTS line. The full
  rule table is in `docs/verification-map/iron-law-guard.md`.

## Why

At 00:18Z on 2026-10-23, the conductor's re-review agent ran
`git checkout -q pr8069` in the hub's `/root/harness-checkout`. Then it ran
`bash tests/agent-call-call-guard.k3-test.sh` there as root. The scratch cwd
removes the default that put the agent in a shared tree. The guard is the wall,
because that agent went into the checkout with its own `cd`.

## Operator check after deploy

On the hub, count review-caused moves in `logs/checkout-moves.log` from the
deploy date to +7 days. The count must be 0.
