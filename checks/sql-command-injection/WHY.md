# sql-command-injection

- **Family key:** `53e19b60469c`
- **30-day count when promoted:** 5
- **Projects:** project-4, pool-project-4, pool-project-3, pool-project-2
- **Ruled by the miner:** 2026-08-26 (`state/rule-mining/20260826/15-findings-53e19b60469c.md`)
- **Promoted to `checks/`:** 2026-08-29

## The findings it was mined from

```
2026-08-26 [project-4]            ticket=TK-330   lens=security :: Injection (SQL / command / path)
2026-08-26 [pool-project-4]       ticket=TK-1055  lens=security :: Injection (SQL / command / path)
2026-08-26 [pool-project-3]       ticket=TK-68    lens=security :: Injection (SQL / command / path)
```

## The objectivity test

- **Measurable observation:** three literal shapes on an added line —
  `$queryRawUnsafe(` / `$executeRawUnsafe(`; a template literal containing a SQL
  keyword AND a `${...}` interpolation; an `exec`/`execSync`/`spawnSync` call
  whose argument is an interpolating template literal.
- **Named tool:** `checks/sql-command-injection/check.sh`.
- **Explicit threshold:** one or more such lines.

Prisma's TAGGED `$queryRaw\`...\`` form is parameterized and is explicitly NOT
flagged — it is the fix, so flagging it would train people to route around the
check.

## What shape 2 accepts on its own (BH-4501)

A SQL template line is not reported when every `${...}` on it is one of these,
judged from the same file's ADDED lines only:

- **(a) A module constant.** `${N}` where `N` has exactly one column-0
  `const N = "<literal>"` (a quoted string with no backslash, or a backtick one
  with no `$`), and no other added line of the file declares, assigns,
  destructures or takes `N` as a parameter (of an arrow, a function, or a
  class or object method such as `async fetch(N)`). `${N.join("…")}` counts
  when that const is a one-line array of such literals and every other added
  occurrence of `N` is also `N.join("…")`. A `const` array is still mutable, so
  `N.push(…)`, `N[i] = …` or `N.splice(…)` anywhere in the added lines makes it
  unsafe.
- **(b) Literal choices.** `${c ? A : B}`, `${A || B}` and `${A + B}`, where A
  and B are each safe. The condition `c` is never interpolated, so it is not
  read. A nested template counts when its own interpolations are all safe.
- **(c) A bind placeholder.** `?${binds.length}` (or `?${binds.length + 1}`,
  or `?${3}`). The text before `${` must end in `?`. `binds` must be a local
  `binds = []` array under the same rule as (d), so `.length` is a number.
  `?${body.length}` still flags, because a JSON body can carry a string
  `length`.
- **(d) A literal-pushed array.** `${where.join(" AND ")}` where
  `where = []` is declared on an added line at or before the use, with no
  unchanged line between them. From that declaration to the next one, every
  `where.push(…)` pushes only safe values (`` `box=?${binds.length}` ``), and
  `where` is used in no other way.

Anything else still flags. That includes request reads, `url.searchParams`,
body fields, function calls, function-local consts, and a const that sits on
an unchanged context line. The check sees only added lines, so it cannot prove
those safe. Pinned by `tests/sql-command-injection-allowlist.bh-4501-test.sh`.

## Applied exclusions (BH-9436)

`checks/sql-command-injection/exclusions.tsv` lists the exclusions the check
applies itself:

- **Path rows** (action `skip`): a `.md` file, an `e2e/` path, a `seed/` or
  `seeds/` directory, and a `seed.ts` / `seed-*.ts` file. `seedling.ts`,
  `readme.md.ts` and `e2ex/` still hit.
- **Tag rows** (action `skip`): `sql`, `Prisma.sql`, `$queryRaw` and
  `$executeRaw`. A shape-2 line is not a hit when every SQL template on it
  opens right after one of these tags. An identifier boundary must come before
  the tag, and an optional `<...>` TypeScript generic may follow it, so
  `` tx.$queryRaw<{ ok: boolean }[]>`SELECT ... ${day}` `` (project-6#3074) is
  the parameterized form. `mysql`...``, `sql.unsafe(`...`)` and
  `Prisma.raw(`...`)` still hit, and so does an untagged SQL template on the
  same line as a tagged one.

The built-in `$queryRaw`/`$executeRaw` exclusion also takes the `<...>`
generic now, and stays in the script, so a missing list does not re-open it.
A missing list or an invalid row is no exclusion. Pinned by
`tests/checks-false-positives.bh-9436-test.sh`.

## Known false positives

- A query BUILDER that interpolates an identifier it controls
  (`` `ORDER BY ${sortColumn}` `` where `sortColumn` came from an allowlist).
  Real, and worth the human read: identifier interpolation is exactly where
  allowlists get dropped.
- Shapes outside (a)–(d) that are still safe, which this check flags on
  purpose. On main@0ad5fe5, `worker/jobs/src/routes/usage.js:149` pushes
  `` `${k}=?${binds.length}` `` with `k` from a loop over a literal list.
  `:175` and `:181` interpolate `${aggregates}`, a function-local const
  template. A loop variable and a local const are both one edit away from
  carrying input.
- A module const the PR did not add (it is a context line) flags at every new
  use. The check never sees the declaration, so it cannot vouch for it.
- The other direction is a known miss. An added module const used inside an
  unchanged function whose header (a context line) takes the same name as a
  parameter is accepted, because the check never sees that header either.
  Likewise a context line that mutates a shape-(d) array after its use inside
  a loop is not seen.
- `exec` as a substring of an unrelated identifier is excluded, but a local
  helper genuinely named `exec` will match.
