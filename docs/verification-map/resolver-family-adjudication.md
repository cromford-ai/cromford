# Resolver family-batched iron-law adjudication (`bin/lib/br/opt/family.sh`)

**What it is:** the optional module that makes one Fable iron-law ruling cover a
whole FAMILY of parked PRs. The merge sweep's iron-law scan is a detector over
added lines, and one cause usually flags several PRs at once — the 2026-09-22
wave had five hits in one PR and eighteen "red-flag lines" in another that were
literal model slugs in a JSON catalog. Both were false positives, both waited
hours, and both paid a review-stage model call per PR. This module fingerprints
the flagged lines, remembers the ruling, and writes the jobs-DB row
`ironlaw-head-accept` `<owner/repo>#<pr>@<head>` for every later PR whose
flagged lines normalize to the same thing — no second model call, and the row
still bound to the sha it was written for.

**How a user reaches it:** there is **no UI route**. It is a module of
`bin/blocked-resolver.sh`, sourced by the `BR_OPT_MODULES` loop on every tick of
the hub's `4,14,24,34,44,54 * * * *` lane, and it answers at two hook sites
inside `br_adjudicate` (see [resolver-opt-hooks.md](resolver-opt-hooks.md) for
the seam itself).

**Key routes/screens:** the four operator surfaces, all on the hub:

- `logs/blocked-resolver.log`, the `tick:` line — `families=` is how many parks
  carried a stored ruling this tick, `llm_rungs=` is how many reached a model
  call. A tick that batched shows `families` above 0 with `llm_rungs` below the
  number of iron-law parks.
- `logs/blocked-resolver.log`, `EVENT family-carried` — one line per carried PR,
  naming the family key and the PR the ruling came from.
- `state/blocked-resolver/.families/<slug>:<shape12>.json` — one file per
  family. A DOTFILE directory: `br_from_rebuilds` globs `state/blocked-resolver/*/*.json`
  and reads the parent directory name as a project, so a non-dot `families/`
  would invent a phantom project on every tick.
- the carried PR itself — the comment "We ruled on this exact shape already,
  on `<url>`. Same check, same lines, so we are not paying for a second read."

**Selectors:** not applicable — no rendered screen. The observable artifacts are
the `ironlaw-head-accept` rows `bin/merge-sweep.sh` and `bin/merge-conductor.sh`
read (`ila_gate`, `bin/lib/ironlaw-carry.sh`), the store rows, the `EVENT`
lines and the `tick:` line. The `iron-law-accepted-<sha>` file in the build
record is gone since BH-7804; nothing writes or reads it.

**Key behaviours to drive:**

- **The key is a fingerprint, never an identity.** `<slug>:<shape12>` where the
  slug is the sorted unique set of `CHECK-HIT` slugs on the record's
  `checks.txt` (absent ⇒ the literal `ironlaw`, for the inline red-flag scan)
  and the shape is `sha1 | cut -c1-12` of the flagged added lines with the `+`
  and surrounding whitespace stripped and `LC_ALL=C sort -u` applied. Never a PR
  url, never a head sha, never a record path.
- **Empty is not a family.** An unreadable diff, no flagged lines, an empty
  `DELETED_CASES` block or a box with no `sha1sum` all produce an empty key, and
  the park takes today's per-PR adjudication.
- **ACCEPT only, and never overwritten.** A `REJECT` is never stored and never
  carried; a run that produced no verdict reaches neither arm of
  `br_adjudicate`, so it is never stored either. An existing row is never
  rewritten, so a second ruling cannot silently refresh a TTL.
- **Order.** The `ironlaw-head-accept` row is written only after the store row
  is confirmed inside `BR_FAMILY_TTL_SECS` and after the head has been read, and
  before the comment, the `EVENT`, the attempt and the `uses` bump. A head this
  tick could not read buys nothing at all: no row, no comment, no `uses` bump,
  and the adjudication is offered again next tick. A row the jobs DB does not
  take is the same: nothing carried, nothing spent, no model call, and the carry
  is offered again next tick. A comment that fails to post leaves the row
  standing and writes one log line. A PR with no build record is carried too:
  the row needs only the PR url and the head.
- **Iron-law only on the carry.** The store keeps a `test-tamper` ruling too,
  but a tamper ACCEPT does far more than record an ACCEPT (a `TEST-CHANGE` block,
  then a resume or a fresh rebuild), so `br_opt_family_pre` declines every
  reason but `iron-law` and a tamper park always buys its own ruling.
- **Observe mode** logs one `WOULD carry family` line and writes no ACCEPT row,
  no store row and no comment.
- **`BR_OPT_OFF=family`** leaves the module unsourced: today's per-PR
  adjudication, byte for byte.

**Preconditions:** the hub box (the lane is hub-scoped and gated on the hub
lease); `sha1sum` and `jq` on PATH; at least one build record carrying the PR's
`checks.txt`, or none, in which case the slug is `ironlaw`.

**Verify it works:** on the hub, `jq . state/blocked-resolver/.families/*.json`
shows a row whose `uses` climbs as sibling PRs are carried, and
`grep 'EVENT family-carried' logs/blocked-resolver.log` names each one, each
followed by `CARRIED family <key> from <url> — DB accept recorded
(<owner/repo>#<pr>@<head>), no model call`; the carried PR is merged by the next
`bin/merge-sweep.sh` pass rather than parked again.

**Manual-only / not automatable:** nothing here is destructive, but a carry is
client-visible (it posts a PR comment and unparks a PR for the merge sweep), so
it is never driven against a live hub to demonstrate it — the suite drives the
real lane against a scratch `$HARNESS` instead.

**Tests that pin it:** `tests/blocked-resolver-family.bh-1471-test.sh` — case 1
sources the module and pins the fingerprint; every other case drives the real
`bin/blocked-resolver.sh` against a scratch `$HARNESS` and asserts on ACCEPT rows,
store rows, `EVENT` lines, the `tick:` line and the posted comment bodies.
`tests/blocked-resolver-opt-hooks.bh-1468-test.sh` owns the seam the module
plugs into. `tests/ironlaw-file-drop.bh-7804-test.sh` cases F1-F3 pin the row,
and the no-spend defer when it cannot be written.
