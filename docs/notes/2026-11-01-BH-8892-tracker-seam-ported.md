# BH-8892: plan-blocked-stop and the infra collector read the tracker through the seam

Doc: GH-REST

## What changed

1. `bin/lib/tracker/github-issues.sh` has a new read verb,
   `trk_gh_issue_field <n> <jq filter>`. It makes one `_gh_rest_field` call
   on `repos/$TRK_SLUG/issues/<n>` and returns its rc (0, 44, 75). A bad
   slug, a bad number or an empty filter is rc 1 with no call.
2. `_pbs_parent` (`bin/lib/plan-blocked-stop.sh`) reads the rollout parent
   with `trk_gh_issue_field`. The cache file and the rc handling do not change.
3. `_unblock_infra_starve` (`bin/lib/unblock/collectors/infra.sh`) asks
   `tracker_kind`, not fleet.conf column 4. `_unblock_infra_parent_state`
   reads the parent issue with `trk_gh_issue_raw`, and only when the kind is
   `github-issues`.

## Why

`tests/tracker-direct-calls-ratchet.bh-7919-test.sh` R1 was red on main.
BH-8839 and BH-8766 added direct tracker calls outside the allowlist. The
allowlist and the ratchet do not change.

## Behavior change

A project whose tracker is Jira or Linear (fleet.conf column 4 `-`, settings
row `tracker_adapter.<p>` names the adapter) now gets no GitHub parent read in
the starve collector. Before, it was read as GitHub. A project whose kind does
not resolve is also unread. An unread parent holds a record only until
`UNBLOCK_STACK_PARENT_STALE_H`, then it goes out with `dep_unread`. A
github-issues or board project does not change.

Test: `tests/tracker-seam-ported.bh-8892-test.sh`.
