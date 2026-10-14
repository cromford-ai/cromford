# SCALE-PLAN-2 — full-dev-team throughput (the operator, 2026-07-31)

Goal: process far more tickets in parallel without quality loss. Constraints
learned 2026-07-30/31: the Orgo plan caps vCPU per computer (a higher cap is an
enterprise sale; the Scale plan does NOT lift it), RAM comes in fixed tiers, and
capacity is an account-level add-on pool. The plan limits and prices are in
`catalog/orgo-plans.json`. Capacity is a MONTHLY pool —
idle-downsizing saves nothing; right-size the pool instead.

## Shipped
- Fleet RAM right-sized: 16GB on build-heavy boxes (project-1/project-2/project-4), 8GB on
  project-3/redirect. All boxes 4c (plan cap).
- Security second-review lens in run-build: schema/auth/money diffs get an
  independent security-only pass; BOTH reviews must APPROVE (2026-07-31).
- Preview-QA stage (pre-existing, 2026-07-27): playwright drives the Vercel
  preview at 1280+375px before any merge on UI diffs.
- CodeGraph everywhere: graph-evidence file lists feed overlap serialization.
- Migrations ride the deploy train (apply within seconds of VERIFIED).
- pnpm pilot ticket filed on project-3 (2026-07-31); other repos follow on success.
  Rationale: content-addressed store cuts worktree installs from minutes to
  seconds — the single largest build-time win.

## Status update (2026-08-01)
- pnpm rollout: project-1 #411, project-2 #238, project-4 #1038 MERGED; project-3 TK-42 in the Fly
  builder pipeline. Items 2 (merge train — live, union-validates batches AND any
  single PR landing onto moved main) and 4 (claims ledger — live, planners shard
  via state/claims + the cross-harness lock service) are SHIPPED.
- Builder pool: Fly trial live (docs/FLY-BUILDER-TRIAL.md as-built) — project-3
  routed via flag; overflow-routing planned post-verdict.
- NEW since plan: cross-harness lock service (locks-worker/, deployed at
  harness-locks.operator.workers.dev) — coordinates our fleet with partner's fork
  on all five boards (docs/HARNESS-COORDINATION.md).

## Next (in order)
1. **pnpm rollout** — after project-3 proves clean: project-4, project-2, project-1 (busiest last).
   Redirect repos are client-owned tooling: propose to their team, never impose.
2. **Merge train batching** (merge-queue.sh v2): collect approved PRs per project
   into a candidate branch, ONE rebase+typecheck+build for the batch, land
   together, deploy train ships one sha. Kills the N-serial-rebases cost and the
   conflict pileups (2026-07-29: four PRs conflicted waiting out a merge wave).
   Semantic-conflict members drop out of the batch back to .blocked.
3. **Builder pool (horizontal)** — Orgo economics: 4c builder ≈ $1 computer +
   $30 vCPU + $16-32 RAM ≈ $47-63/mo. the operator buys pool capacity (console sliders;
   API cannot purchase), then: POST /computers, bootstrap-machine.sh, tailnet
   join, builder claims jobs from a shared build queue. Queue home: the console
   worker (already sees every build). Watcher boxes keep triage/board ownership;
   builders are stateless and disposable.
4. **Cross-ticket file-claims ledger** — planners consult an active-claims dir
   (files -> building ticket) and shard around each other instead of waiting out
   the 45-min overlap serializer.
5. **Test-infra funding** — repos without runnable suites cap quality at any
   speed (project-10 mobile has none). One infra ticket per gap, client-approved where
   the repo is theirs.

## Capacity notes
- Account pool after right-sizing: 20 vCPU / 64 GB across 5 boxes; the operator tops up
  RAM add-on to cover (console). Builder additions are slider + bootstrap.
- Aug 3 cost report decides bundles-vs-API for model spend at higher volume
  (bundles run 10-30% below API rates).
