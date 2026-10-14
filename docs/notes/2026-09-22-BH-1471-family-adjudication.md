# One iron-law ruling now covers a whole family of PRs

Doc: resolver-family-adjudication, resolver-opt-hooks

**What changed.** `bin/lib/br/opt/family.sh` is new — the second of the two
optional modules `bin/blocked-resolver.sh`'s `BR_OPT_MODULES` loop already names
(BH-1468 shipped the seam; #1470 owns `mechanical.sh`). It fills the two hooks
`br_adjudicate` already calls, and nothing else in the repo changes:
`bin/blocked-resolver.sh`, `bin/merge-sweep.sh`, `bin/merge-conductor.sh`,
`bin/lib/br/opt/README.md` and `catalog/lanes.d/blocked-resolver.json` are all
untouched.

- **`br_family_key <reason> <rec> <url>` → `<slug>:<shape12>`, or nothing.** The
  slug is the sorted unique set of `CHECK-HIT` slugs on `<rec>/checks.txt`
  joined by `+`, or the literal `ironlaw` when there is no such file (the inline
  red-flag scan parked it). The shape is `sha1 | cut -c1-12` of the flagged
  ADDED lines of the PR's diff with the `+` and the surrounding whitespace
  stripped and `LC_ALL=C sort -u` applied. `test-tamper` hashes the
  `DELETED_CASES` block instead, read exactly the way `br_adjudicate` reads it.
- **`br_opt_family_pre`** carries a stored ACCEPT: marker, comment, record
  attempt, `EVENT family-carried`, `uses` bump, `br_count family`, rc 0 — and no
  model call.
- **`br_opt_family_record`** stores an ACCEPT, once per family, under
  `state/blocked-resolver/.families/<key>.json`.

**Why the store is a dotfile directory and the ticket's path is not used.** The
ticket asks for `$ST/families/`. `br_from_rebuilds` globs `"$ST"/*/*.json` and
reads `basename(dirname(f))` as a PROJECT NAME, so `$ST/families/<key>.json`
matches that glob and would offer a rebuild candidate for a project called
`families` on every tick, for ever. A leading dot is not matched by `*`, and it
is the precedent the lane already documents twice for exactly this reason
(`.saturation.tsv`, `.tick-budget`). The suite asserts the tick's `candidates=`
field is unchanged with rows in the store.

**Why the fingerprint is not capped at six lines.** The ticket says "the same
lines `br_ironlaw_context` selects", and that function applies `head -6` before
building the prompt. That cap is about how much context a model gets. Applied to
a HASH it would make two PRs that agree on their first six flagged lines and
differ afterwards share a shape — a false carry, which is the one direction this
feature must not fail in. So the selection rule is shared and the cap is not.

**Why the carry is iron-law only while the store takes both reasons.** The only
artifact a carry writes is `iron-law-accepted-<head>`. The lane's `test-tamper`
ACCEPT arm does far more than that — it appends a `TEST-CHANGE` block and then
resumes or rebuilds — so carrying a tamper ruling with a marker would silently
drop the park. `br_opt_family_pre` therefore declines every reason but
`iron-law`, and `br_opt_family_record` stores an ACCEPT for either. The
asymmetry is asserted rather than assumed: case 4c parks two tamper records of
one family and both buy their own ruling while one row is stored.

**The order, and what each failure costs.** The head is read and the TTL
confirmed FIRST, the marker is written NEXT, the comment is sent LAST. A head
this tick could not read buys nothing at all — no marker, no comment, no `uses`
bump, no count — and the adjudication is offered again next tick, which is
`br_adjudicate`'s own rule for the same situation. A comment that fails to post
leaves the marker standing and writes one log line: a failed comment must never
retract a marker that has already unparked a judged sha, and the reverse (a
comment with no marker) cannot happen because the comment is strictly after it.
A record that is not a directory declines rather than carries — a carry there
would consume the ruling and unpark nothing.

**What is never stored.** A `REJECT` (a carried REJECT would spend a fix round
on a PR nobody looked at). A session that came back with no verdict — it reaches
neither arm of `br_adjudicate`, so the hook is never called, and a paid-for
empty answer cannot become a free carried ACCEPT. An empty key, from an
unreadable diff, no flagged lines, an empty `DELETED_CASES` block or a box with
no `sha1sum`. And an existing row is never REWRITTEN, so a second ruling cannot
silently refresh a `BR_FAMILY_TTL_SECS` window. An out-of-TTL row is left on
disk, unused — never pruned, because a pruned ruling silently re-buys the model
call it exists to avoid.

**What it costs in GitHub reads.** The fingerprint needs the diff, and the diff
is not on a build record: `bin/run-build.sh` and `bin/lib/rb/execute.sh` both
`rm -f "$BUILD/checks-input.diff"`, and `checks.txt` carries slugs and locations
but not line text. So the module makes the same `GET /repos/:slug/pulls/:n` with
the diff Accept header that `br_adjudicate` makes a few lines later — one extra
read per iron-law adjudication candidate, bounded by `BR_PER_TICK`. On the carry
path it replaces a review-stage model call; on the declining path it is one
cheap REST read spent to avoid an expensive one. The key is memoised in
`$BRF_KEY` for the life of the row's dispatch (both hooks are called directly by
`br_adjudicate`, never inside a `$( )`), so the ruling path pays that read once
rather than once per hook.

**Concurrency.** No lock is taken. The file NAME is the natural unique key, so
two ticks cannot create two rows for one family; rows are written tmp + `mv`, so
a killed tick leaves no partial row; the marker write is idempotent. Two ticks
racing can lose one `uses` increment, which is telemetry. A lock held across a
tick would be a queue (D33).

**How to see it on a box.** `logs/blocked-resolver.log`: the `tick:` line's
`families=` against its `llm_rungs=`, and one `EVENT family-carried` line per
carried PR. `jq . state/blocked-resolver/.families/*.json`: one row per family,
with `uses` climbing. On the PR itself: "We ruled on this exact shape already,
on `<url>`. Same check, same lines, so we are not paying for a second read."
`BR_OPT_OFF=family` is the kill switch; `BR_FAMILY_TTL_SECS` (0 = never
expires) bounds how long a ruling may be carried. Both were already declared by
BH-1468 and neither needs setting anywhere for today's behaviour.

**What it touches.** `bin/lib/br/opt/family.sh`,
`tests/blocked-resolver-family.bh-1471-test.sh`,
`docs/verification-map/resolver-family-adjudication.md`,
`docs/verification-map/entries/BH-1471.md`, and this note.
