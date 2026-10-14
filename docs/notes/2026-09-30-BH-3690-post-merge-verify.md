# Post-merge verify: prod serves the sha we merged (BH-3690, slice C0)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

- **`bin/post-merge-verify.sh <project> --target <t> --merged <sha> --served <sha|""> [--slug o/r] [--log f]`**
  is one contract any deploying lane can call once it knows which sha prod
  serves. The judge and the side effects are in `bin/lib/post-merge-verify.sh`.
  It always exits 0, so a verifier that fails never changes its caller's verdict.
- **The comparison.** Equal shas, or one a short prefix of the other (trimmed and
  lowercased), match. Otherwise, with `--slug`, it asks
  `gh api repos/<slug>/compare/<merged>...<served>`: `ahead`/`identical` (the
  served commit contains the merge, deploy-train's ancestry rule) is a match and
  `behind`/`diverged` a mismatch. An empty or non-hex served sha, a failed
  compare or any other status is `unreadable`. That is recorded and never paged
  as a mismatch.
- **What each verdict does.** The row is `ledgers(kind=post_merge_verify,
  key=<project>:<target>@<merged>)`.
  - match: status `verified`, one `post-merge-verify OK` log line. No page, no gh.
  - unreadable: status `unreadable`, one log line.
  - mismatch: one warn page through `bin/alert-line.sh`, then status `paged`, then
    one ticket on the harness repo (`fleet-conf.sh cromford repo`) with label
    `infra` and no `ai-build`, so a page never launches a build. The ticket is
    found first with a REST `search/issues` title search (not `gh issue list`,
    which the BH-1585 GraphQL ratchet forbids), and filed with `gh issue create`
    only if the search finds nothing. Status `ticketed` (detail
    `{served,issue}`) is written only from a parsed issue number. A key that is
    `ticketed` does nothing on a rerun. One that is `paged` retries only the
    ticket. When the ledger is unreachable, the marker
    `state/post-merge-verify/<sha1 of key>` answers the same question.
  - `deploy.<project>.kind=none`: one `SKIP (deploy.kind=none)` line before any
    gh call or ledger write. A settings outage is not a skip.
- **The first caller is `bin/deploy-verify.sh`.** In its `deploy-verify OK` arm,
  after the hotfix hook, it reads `.sha` off the production deployment it just
  saw succeed and calls the contract with `--target app`, bounded by
  `timeout 120`. The bite is the hook-recovery path, which accepts "the newest
  post-hook production deployment" whatever commit that is. The `kind=none` and
  smoke-only paths exit before this point, because they have no served sha.

## Operator probe

`grep -h 'post-merge-verify' /root/harness/builds/*/pipeline.log` on a box that
auto-merged, and `bin/jobs-client.sh ledger-list post_merge_verify` for the rows.

## Left for child slices

- C1: a harness-jobs worker `/api/version` route (sha stamped at `wrangler deploy`),
  and `bin/harness-sync.sh` calling the contract with `--target worker`.
- C2: `console-pages-deploy.sh` calling it with Cloudflare's deployment commit
  (`--target pages`), plus re-promoting the previous Pages deployment on a mismatch.
- C3: the box harness checkout equals main within N minutes (`--target checkout`),
  replacing pipeline-health's page-only drift path.
- C4: the digest and precision-lane feeds that read `ledgers(kind=post_merge_verify)`.
