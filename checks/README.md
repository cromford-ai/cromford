# `checks/` — the mined checks the harness runs itself

## What this is

The rule miner (`bin/rule-miner.sh`) had two output lanes and neither of them
enforced anything on the harness side:

| lane | artifact | where it runs | how long until it bites |
|---|---|---|---|
| prose | a `D<n>` rule in `prompts/build-discipline.md` | a model's context | never mechanically — a model can forget it |
| guardrail | a drafted check PR'd onto a PROJECT repo by `bin/guardrail-promote.sh` | that repo's CI | after a whole adoption build lands |
| **checks/ (this)** | **a script here** | **the harness's own gates, on every diff** | **immediately** |

Between 2026-08-19 and 2026-08-29 the guardrail lane promoted **zero** checks,
so a review-finding family could recur seven times across four projects and
still be re-litigated by a paid model on the eighth. This directory closes that:
a family the miner has RULED on becomes a deterministic script the harness runs
in milliseconds, before it pays anyone to look.

## Detection only

**Nothing in this lane fixes, reverts, closes, or merges anything.** Each
`check.sh` reads a stream on stdin and writes findings to stdout — it has no
git write, no `gh` call, and no edit path. A hit does exactly two things:

1. `bin/merge-sweep.sh` **parks** the PR and writes one `ALERTS.log` line, the
   same treatment the inline iron-law red-flag scan already gives. A parked PR
   is merged by a human or not at all.
2. `bin/run-build.sh` puts the hits in the **review prompt** as mechanical
   evidence, alongside the test-tamper, reproduction, intent and E2E gates. The
   reviewer adjudicates them; the check does not.

The escape hatch is the parking itself: a hit costs a human read, never a
disabled check. That is deliberately different from `guardrails/`, whose checks
turn a project's CI red and therefore need the `skip-guardrail` + written
justification hatch.

## Layout

```
checks/<slug>/check.sh      the check (executable, reads stdin, writes stdout)
checks/<slug>/WHY.md        family key, 30-day count, the real findings it was
                            mined from, the objectivity test, known false positives
checks/<slug>/exclusions.tsv OPTIONAL. The known false positives the check
                            applies itself, one TAB row each: kind action pattern why
checks/<slug>/fixtures/violation.diff   a seeded violation — the check MUST fire
checks/<slug>/fixtures/clean.diff       the same code done right — MUST stay silent
checks/<slug>/fixtures/tree-bad/        OPTIONAL. A whole checkout shaped wrong —
                            its presence is how a check declares it reads trees
checks/<slug>/fixtures/tree-good/       the same checkout done right — MUST stay silent
```

## The contract

`bin/checks-run.sh <diff-file>` normalizes a unified diff to one TAB-separated
record per **added** line — `<path>\t<line-in-new-file>\t<text>` — and pipes that
stream to every `check.sh`. Doing the parse once is what keeps each check a
dozen lines long, and it puts the exclusion set in ONE place: test/mock files,
`scripts/migrations/`, `.harness/specs/`, fixture directories, and comment-only
added lines are dropped before any check sees them (the same exclusions
`bin/merge-sweep.sh` applies, and for the same reasons).

A check prints `path:line<TAB>reason` per hit and exits **0 clean / 1 hits**.
Any other rc is reported as `CHECK-ERROR` — a check that could not run must
never read as a check that passed.

A check may also print `NOTE<TAB>path:line<TAB>reason` for a line its own
`exclusions.tsv` excludes. The runner prints it as
`CHECK-NOTE <slug> <path>:<line> <reason>` after every `CHECK-HIT`, adds
` — <k> note(s): <slug>(xN)` to the summary, and does not count it as a hit.
The review prompt shows the notes, so each skip stays visible. A missing list,
or an invalid row, is no exclusion: the check runs in its strict form.

The runner exits **0 clean (notes only is clean) / 1 hits / 2 could not run**.

## The catalog

| check | family | 30d count when promoted | projects |
|---|---|---|---|
| [`client-id-trust/`](client-id-trust/) | `fd7bbe69fac5` — unsafe trust of client-supplied ids | 7 | project-4, project-1, pool-project-4, pool-project-2 |
| [`sql-command-injection/`](sql-command-injection/) | `53e19b60469c` — injection (SQL / command / path) | 5 | project-4, pool-project-4, pool-project-3, pool-project-2 |
| [`secret-literals/`](secret-literals/) | `4d8b31f48fbd` — secrets / tokens in code or logs | 5 | pool-project-4, pool-project-1, pool-project-3, pool-project-2 |
| [`tests-scratch-only/`](tests-scratch-only/) | `b3957447980a` — a test or a bin script deletes a path it does not own | 1 (an incident, not a miner ruling) | cromford |
| [`worker-schema-ensure-columns/`](worker-schema-ensure-columns/) | `dc4787efd501` — a schema.sql index on a column only ensureColumns creates | 1 (an incident, BH-2473) | cromford |

The first three were ruled by the 2026-08-26 miner run and are recorded in
`state/repeat-family.json`. `tests-scratch-only` is the exception that proves the
lane works both ways: it was never mined, it was earned on 2026-09-15 when a
`tests/*.sh` that owned no scratch tree deleted the live `/root/harness` (#388,
root cause #404, scope #394). A family whose recurrence costs a restore from
backup does not get to wait for a second occurrence.

## Every check is proven on every CI run

`tests/checks-suite-test.sh` runs each check against its seeded violation (must
FIRE) and its clean fixture (must stay SILENT), and asserts no check fires on
another check's clean fixture. A rule that matches nothing looks exactly like a
diff with nothing to find, so "it ran and was quiet" is not evidence on its own.

## Adding a check

Mirror an existing directory: `check.sh` + `WHY.md` + both fixtures, then add
the slug to the loop at the top of `tests/checks-suite-test.sh`. `WHY.md` must
carry the family key and the real findings — a check nobody can trace back to a
recurrence is a check nobody can argue with when it is wrong.

## Tree mode

A diff answers "did this PR add something dangerous?". It cannot answer "is
anything in this checkout dangerous?" — and the exclusion set above drops every
`tests/` path before a check sees it, so a rule about test files can never fire
in diff mode at all. That is why `tests-scratch-only` has two rules (R1 and R2)
that exist only in tree mode.

```sh
bin/checks-run.sh --tree <root>          every tree-capable check, over a checkout
checks/<slug>/check.sh --tree <root>     one of them, on its own
```

**A check is tree-capable iff its directory ships `fixtures/tree-bad/`** — the
same "prove it on a fixture" contract the diff lane already has. No marker file,
no registry. A stdin-only check is never handed `--tree`: it would read an empty
stream, find nothing, and report a pass it never earned.

The runner's tree rc is the diff rc with one extra way to be honest:

| rc | meaning |
|---|---|
| 0 | `CHECKS: clean (<n> tree check(s), root <root>)` |
| 1 | `CHECKS: <n> hit(s) — <slug>(xN)` |
| 2 | no such tree, no catalog, a tree check that exited >1, **or a catalog with nothing tree-capable in it** |

That last one matters: a run that scanned zero checks has not proven the tree is
clean, and saying "clean" there would be the vacuous green this whole catalog
exists to refuse. The same rule runs one level down: **a check must read its own
scanner's exit status and answer 2 when a stage died**, because empty output
from a scan that crashed is not a clean tree either.
`tests/checks-suite-test.sh` section 8 drives every tree-capable check against
its own `tree-bad` and `tree-good` fixtures.

**Tree fixtures must be INERT.** A `tree-bad/` is a checkout shaped wrong on
purpose, so its files are the dangerous shapes themselves. They are data, mode
644, and nothing in the repo runs them — but that is not a property this repo
controls: `bin/repro-gate.sh` globs `tests/`-shaped paths out of a diff and runs
`bash` over them, and it has already selected fixture scripts that way. Write
every fixture so that EXECUTING it does nothing: a stub lib that `exit 0`s on
source, defaults that point under `/dev/null/…` rather than at a real root. The
rules read text, so inertness costs no detection. `tests-scratch-only`'s suite
(section A0) shows the pattern.

## Portability note

`/usr/bin/awk` is mawk on Debian and on GitHub's Ubuntu runners, and older mawk
does not support interval quantifiers (`{n}`). No pattern in this catalog uses
them. A pattern that silently matches nothing is the exact failure this catalog
exists to prevent.
