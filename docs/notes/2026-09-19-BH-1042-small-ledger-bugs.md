# Four small ledger bugs: a stamp, a cursor, a stamp that outlived its rows, and a stale map

Doc: PR-OWNERSHIP, DB-COORDINATION-SPEC, OPERATOR-SETUP, BUILD-CONCURRENCY

BH-1042, from the 2026-09-19 audit (facts #28, #29, #30, #33). Four independent
one-to-ten-line fixes that share a shape: a value written by one clock or one
tick was being trusted by another, and in every case the failure was silent.

## 1. The pr-owners overlay compared two different clocks

`bin/pr-owner-sweep.sh` stamps `state/pr-owners/<owner>_<repo>.json` with
`generated_at` from `date -u +%s` on the box. The D1 overlay then kept a
`pr_owners` row only when `row.updated_at >= file.generated_at` — but
`updated_at` is written by the WORKER. On a box whose clock runs ahead (the
normal state of an Orgo machine after a resume) every row the worker had just
stamped lost to the local clock, so a PR another box closed went on being
reported OWNED here.

What changed: the sweep now captures the answer its own PUT came back with and
writes that `as_of` onto the file as **`synced_as_of`**. The overlay compares
against `(.synced_as_of // .generated_at)`, so both sides of the `>=` are the
worker's clock. `generated_at` keeps its old meaning — the moment this box
wrote the file — and is the fallback for the one tick after an outage.

Ordering is file (`mv`) → PUT → stamp. The stamp is derived from the delivery's
own answer, so "stamped without delivery" cannot happen; a PUT that fails but a
GET that answered falls back to the GET's `as_of`; neither answering writes
nothing at all. BH-435's guarantee is unchanged: a row the worker stamped
BEFORE our push still never overlays.

## 2. The rehydrate cursor and the stamps were different formats

`decision-log.sh` and `findings-log.sh` stamp lines `%Y-%m-%d %H:%M:%SZ` — a
space. `log_rehydrate` asked for its window with `%Y-%m-%dT%H:%M:%SZ` — a `T`.
The worker does not parse either: `listLines` binds the cursor into
`stamp >= ?`, a SQLite string compare, and 0x20 sorts before 0x54. Every row
stamped on the boundary day itself fell outside the window, so a 30-day
rehydrate returned 29 days and `bin/repeat-family.sh` answered NOT MEASURED
while the rows existed.

The cursor is now written in the writers' own format. `@uri` encodes the space
as `%20`, `searchParams` decodes it, and `str(...,32)` keeps all 20 characters.

## 3. `state/catalog-synced` said "pushed once", not "still there"

`bin/harness-sync.sh` pushed `catalog/context-budgets.json` into
`budget_catalog` only when the stamp differed from the manifest's tree sha.
Nothing ever asked the DB whether the rows were still there, so a reset table
with the stamp left behind meant nobody re-pushed and every lane fell back to
the catalog file, permanently and silently.

New read-only verb, `bin/jobs-client.sh catalog-probe [file]`: it takes the
first lane in the manifest with a numeric `ceiling_tokens`, builds the key
`catalogEntries()` writes for it (`<stage>/<project // "*">/*`), and asks
`GET /api/catalog/<lane>`.

| rc | meaning | what harness-sync does |
|---|---|---|
| 0 | the worker served the lane from `budget_catalog` | nothing |
| 2 | the worker ANSWERED and holds no row on that ladder | `rm state/catalog-synced`, log `budget catalog stamp voided`, the existing block re-pushes |
| 1 | no answer, or no sized lane in the manifest | nothing — an outage is not a reset |

Cost is one GET per DEPLOY run (`update-runners.sh` daily, plus a stale
pre-build `context-gate.sh` sync) — never per tick, and never a PUT unless the
row is really gone. `--check` exits before this block and makes no call.

Why a probe and not an etag in the stamp: no route lists or counts
`budget_catalog` (only `PUT /api/catalog` and `GET /api/catalog/:lane`), so a
literal etag needs a worker change and a deploy. Etag DRIFT deliberately does
not trigger a re-push — the sha gate exists so a routine deploy is not a PUT.
If a count route is wanted later, `catalog_probe` is the single place to swap.

## 4. The ticket keymap kept closed tickets, and outranked the queue row

`bin/triage-gate.sh` wrote every listed ticket into
`state/<project>.keymap.json`, closed ones included, and the only reader — the
client-court guard in `bin/lib/rt/shards.sh` — trusted it over the queue row's
own `ticket_id`. A shipped ticket's key sitting in the map sent the guard to a
DONE or blocked ticket and dropped live work.

Two halves, because neither covers the other's case:

- **write time:** the keymap now drops tickets whose `status` (lower-cased) is
  one of `done`, `closed`, `cancelled`, `canceled`, `archived`. Any other
  status counts as open — fail-open, because dropping a live key costs a build
  and keeping a dead one costs one gate call. `done` is the status this harness
  itself writes (`bin/board-closeout.sh`).
- **read time:** for non-`board` units the guard reads
  `state/build-queue/<p>/<KEY>.json`'s `ticket_id` FIRST and falls back to the
  keymap. `-`, `null` and empty are the dispatcher's placeholders, not answers,
  and fall through. `board`-class lines carry the raw ticket id and consult
  neither. This is the arm that still works when the map was not rebuilt at all
  (a fetch failure), which the write-time filter cannot help with.

## How to drive all four

`docs/verification-map/ledger-stamps.md` carries the reach/drive table. The
four suites, red on the merge base and green after:

```
HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-sweep-server-clock.bh-1042-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/jobs-client-rehydrate-boundary.bh-1042-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/harness-sync-catalog-reset.bh-1042-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-keymap-stale.bh-1042-test.sh
```

No schema change, no route change, no cron line, no new environment variable.
