# BH-8003 — mc_rebase merge identity; the rc-4 alert names the logged reason

## What failed

On 2026-10-22, 04:19Z to 07:05Z, the blocked-resolver's mechanical rung could
not rebase 5 project-6 PRs on the hub. The hub has no project-6 clone, so
`mc_rebase` used the scratch clone `tmp/conductor/example-org_project-6`. The
merge ran with no git identity in its environment and failed:

    .../pull/2285 rebase: merge failed — Committer identity unknown

`mc_rebase` returned rc 4. The resolver alert said "a clone or credential
problem", which pointed the reader at the wrong cause.

## The fix

1. `mc_rebase` (`bin/lib/mc/rebase.sh`) gives the merge and the resolved-merge
   commit an explicit identity:
   `${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}` / `${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}`.
   This is the identity the regenerate commit and the restack already use. The
   merge no longer depends on the caller's HOME or global git config. This
   applies to the scratch-clone path and to the hub-clone path.
2. The rc-4 alert of rung 1 (`br_mechanical`) and rung 1b (`br_regen_rung`)
   names the reason `mc_rebase` logged for this PR in this call
   (`mc_rebase_reason <url> <mark>`). If no reason was logged, the alert says
   "a setup failure that logged no reason (credential, clone or fetch)". rc 4
   stays rc 4: it still spends no rung and closes nothing.

## Proof

`tests/mc-rebase-scratch-identity.bh-8003-test.sh` runs `mc_rebase` on a
scratch clone with an empty HOME, `GIT_CONFIG_GLOBAL=/dev/null` and
`user.useConfigOnly=true`. On the old code it fails "Committer identity
unknown". It also drives the real resolver for rung 1 and rung 1b.

## Post-deploy check (not run in the build)

After the next resolver tick on the hub:

1. Run `grep 'project-6/pull/.* rebase: merge failed' /root/harness/logs/merge-conductor.log | tail`.
   No new line after the deploy time must show.
2. Run `grep 'rung 1 mechanical' /root/harness/logs/blocked-resolver.log | grep -i project-6 | tail`.
   A project-6 park must show the rung with no rc 4 setup alert after it.
