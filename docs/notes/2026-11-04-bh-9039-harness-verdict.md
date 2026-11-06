# BH-9039: a builder-only clearance publishes `harness-verdict` on every repo

Slice C1 of #8890 (Acceptance 3). PR #9033 (slice C0) did this on lead-required
repos only. This slice does it on every repo, the row-0 default included.

## The two contexts

| Context | Who publishes it | When |
|---|---|---|
| `lead-verdict` | `bin/lead-verdict.sh post` (lead or human rows) | success on MERGE / MERGE-WITH-NOTES, failure on BLOCK, pending on retract |
| `lead-verdict` | the conductor (`mc_enqueue_mergify`, `mc_rebind_publish`, `mc_vs_ttl_republish`) | only when a lead or human MERGE / MERGE-WITH-NOTES stands on the head |
| `harness-verdict` | the conductor, same three paths | every other clearance (a builder APPROVE alone) |

`lr_clear_context` (`bin/lib/lead-required.sh`) picks the context. It no longer
reads `lr_required`. It makes one `vd_standing` read per publish on every repo.
An unreadable verdict reader gives `harness-verdict`, never `lead-verdict`.
`lr_required` still drives the WAIT_LEAD gate and the batch-resolve fence.

## The cromford queue rule

`config/mergify/repos/cromford.conf` carries
`status_check_any=lead-verdict|harness-verdict`. `bin/mergify-template.sh`
renders it in the hotfix, flake-fix, solo and default `queue_conditions`:

```
- "check-success~=^(lead-verdict|harness-verdict)$"
- "-check-failure=lead-verdict"
- "-check-failure=harness-verdict"
```

Either success clears the PR. A `lead-verdict` failure (a lead BLOCK) holds the
PR out even when `harness-verdict` is success. A `pending` lead-verdict does
not hold the PR (before this slice, the conductor's next success overwrote it).

The in-code readers use the same rule through `vs_clear_row`
(`bin/lib/verdict-status.sh`): `mc_vs_success_on`, `mc_vs_state_on` with no
context argument, landing step 7, `lsr_sweep`, the stuck-work facts (columns
6 and 7) and pipeline-health's lead-merge-unqueued read.

## Reading the logs

`VS_REBIND_PUBLISHED <head> <ctx>=success`, `VS_REPUBLISHED <head> <ctx>=success`
and the enqueue's "the <ctx> status could not be published" note name the
context that was POSTed. After this slice a builder-only clearance shows
`harness-verdict` there. A line that names `lead-verdict` means a lead or human
MERGE stood on that head.

## Rollback

1. Revert the PR. The conf, `.mergify.yml` and the code go back together.
2. A head that carries only `harness-verdict` then reads `absent` in
   `mc_vs_state_on`, so the TTL republish publishes `lead-verdict` on it.
