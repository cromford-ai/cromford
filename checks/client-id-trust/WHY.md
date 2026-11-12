# client-id-trust

- **Family key:** `fd7bbe69fac5`
- **30-day count when promoted:** 7
- **Projects:** project-4, project-1, pool-project-4, pool-project-2
- **Ruled by the miner:** 2026-08-26 (`state/rule-mining/20260826/10-findings-fd7bbe69fac5.md`)
- **Promoted to `checks/`:** 2026-08-29

## The findings it was mined from

```
2026-08-26 [project-4]            ticket=TK-330  lens=security :: Unsafe trust of client-supplied ids
2026-08-26 [project-1]        ticket=TK-115  lens=security :: Unsafe trust of client-supplied ids
2026-08-26 [pool-project-2] ticket=TK-139  lens=security :: Unsafe trust of client-supplied ids
```

Seven reviews, four projects, one question asked seven times by a paid model.
Reviewers caught it every time — that is the system working, and paying for it
every time is the system leaking.

## The objectivity test

- **Measurable observation:** an added line containing a `where:` object whose
  only key is `id`, in a file under `/api/`, `/server/`, `/actions/`, or named
  `route.ts` / `actions.ts` / `handler.ts`.
- **Named tool:** `checks/client-id-trust/check.sh` (awk over the added-line
  stream normalized by `bin/checks-run.sh`).
- **Explicit threshold:** one or more such lines.

## Applied exclusions (BH-9436)

`checks/client-id-trust/exclusions.tsv` lists the known false positives the
check applies itself, one path row each. A matching hit becomes a
`CHECK-NOTE` line in the scan output: the review still sees it, and it does
not park the PR. The rows: a `cron/` route (it resolves its own job id), a
`webhooks/` route (it resolves its own event id; the signature check is the
auth), a test fake or fixture directory or file (`fakes/`, `__fixtures__/`,
`fake.ts`, `prisma.fake.ts`; project-4#2205), and an `admin/` or `(admin)/`
route (project-3#649). Each one matches a whole path segment: `crons/`,
singular `webhook/`, `fakeNews/` and `administrators/` still hit. A missing
list or an invalid row is no exclusion, so a broken install gives more hits,
never fewer. Pinned by `tests/checks-false-positives.bh-9436-test.sh`.

## Known false positives

- A lookup whose scope is applied on the NEXT line rather than in the same
  `where`. The check is line-local on purpose: a multi-line read is where a
  shell check starts guessing.
- A `where` whose scope column is named something this check does not know
  (it knows `userId`, `ownerId`, `orgId`, `organizationId`, `tenantId`,
  `clerkId`, `accountId`, `workspaceId`, `companyId`, `createdById`,
  `memberships`, and any explicit `AND:` / `OR:`).

Both are read-and-move-on for the human the hit parks it for. Nothing is
auto-fixed and nothing is auto-blocked.
