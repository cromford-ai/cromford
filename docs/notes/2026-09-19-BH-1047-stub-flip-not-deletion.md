# 2026-09-19 — BH-1047: the test-tamper gate learns that a stub flip is not a deletion

Doc: E2E-POLICY, MERGE-CONDUCTOR

## What was wrong

`bin/test-tamper-scan.sh` counted the NET loss of test-case openers per file and
nothing else. A contract-first decomposition always loses that count: the `.0`
child ships cases whose bodies are named stubs, and the `.N` filler deletes them
and writes the real cases in another file. Five project-4 fillers — TK-1828, 1872,
1896, 1908, 1909 — ended `REVIEW_BLOCKED test-tamper`, sat one to two days each,
and were then adjudicated legitimate by hand on a Mac. Nothing in the harness
could have ruled on them either: the record's own report named a count, not the
cases, and `bin/blocked-resolver.sh` held a `REVIEW_BLOCKED` record behind a
6-hour floor that belongs to `bin/review-rescue.sh` — a lane that re-runs the
same scanner and would have reached the same answer.

## What changed

**1. The scanner classifies each removed opener.** One awk pass per file emits
one row per removed opener — `stub` or `real`, its token count, why, and the
opener text. A removed case is a STUB when

- its own text, one of the three COMMENT lines immediately above it in the same
  hunk, or an enclosing `describe`/`context` matches the marker vocabulary from
  the ticket — `stub`, `placeholder`, `until <KEY>-`, `implements the
  body/bodies`, `must flip`, this build's ticket key, or a `<PARENT>.<N>`
  sibling key; or
- the file was created by the `.0` contract child of the same parent, read off a
  `.0` build record found by its `ticket-meta.json` title: either its
  `changed-files.txt` names the file, or its `branch` file names the ref this
  build is based on, in which case the files added between
  `merge-base(origin/<base>, BASE)` and `BASE` are candidates too — and in both
  cases the path must be absent from the mainline AND the commit that ADDED it
  must name the `.0` record (its ticket key or the `<PARENT>.0` title), because
  the `.0` can itself be stacked on an unmerged ticket whose suites are absent
  from main and inside the range.

The comment window is comments only and anything else closes it — an opener, a
`const`, a `beforeEach` — so a marker reaches the case written under it and
stops there. In a contract-first file a real case
sits directly under a stub all the time, and "any preceding line" would have let
`it("refuses to move money twice for the same idempotency key")` ride out of the
gate on the stub above it.

Provenance is read off a `.0` RECORD and never off "I am stacked on something".
`bin/run-build.sh` stacks a child on ANY blocked-by parent's branch and
`bin/run-decompose.sh` stacks siblings on each other, so a sibling's branch
carries real cases: taking the stack itself as the marker would let any stacked
child gut its parent's tests and pay with one trivial `it()`. With no `.0`
record on the box the build falls back to marker (a), which is the answer this
scanner gave before BH-1047.

Markers are matched case-insensitively on word boundaries against a lowercased
line, so `stubborn` is not `stub`. The match runs in awk against a lowercased
line rather than with `\b`, which mawk — the awk on these boxes — reads as a
backspace.

**2. A stub is exempt only in exchange for a replacement.** The same diff must
ADD at least one case in another test file importing the SAME module: JS/TS
specifier equality after path normalisation (relative specifiers resolved
against the repo root, extension and trailing `/index` stripped; bare packages
ignored), dotted-name equality for Python, no pairing for any other stack. Each
exempted case prints as `stub-flip: <file>: <case> (<why>) -> <replacement>`;
an unmatched one prints as `stub-flip-unpaired:` and counts as a deletion
exactly as it did before.

**3. The report names the cases.** `DELETED_CASES:` lists every removed opener
that still counts (capped at 40), `CONTRACT_CHILD: <PARENT>.<ORD> (parent …,
key …)` records the lineage, and `stub_flips=N` joins the existing parentheses
on line 1. Everything new is printed AFTER the four count lines, so
`bin/run-build.sh`'s `JUSTIFICATION: NONE` + `^BLOCKING_COUNT: [1-9]` block,
`bin/evidence-summary.sh`'s `^BLOCKING_COUNT: [1-9]`, and every other caller
grep match the line they always matched.

**4. The pairing reaches the reviewer.** The rc-0 arm of the tamper gate in
`bin/run-build.sh` carries the whole report into `GATES_NOTE` when it sees a
`stub-flip:` line, with the instruction that a replacement missing its assertion
is a BLOCK. A genuinely clean scan keeps the old one-liner: claiming pairings on
a diff that removed nothing would be a false status string.

**5. The resolver rules within one tick, and says on what.** A record blocked on
test-tamper whose report carries `CONTRACT_CHILD:` skips the 6-hour rescue floor
in `br_from_builds` (the 90-minute floor `bin/pr-url-reconcile.sh` owns is
untouched). `br_adjudicate`'s prompt and both comment bodies are prefixed with
`Deleted cases under adjudication:` and the list, or with "the scanner named no
cases; this is a pre-BH-1047 report" when the record predates this. An
adjudication that produces no verdict pages once through `bin/lane-alert.sh`
with that list and touches `<record>/.adjudicate-noverdict-paged` AFTER the
alert returns, so a failed page is re-sent next tick rather than stamped as
delivered. Silence still spends no adjudication counter.

Both are scoped to a TAMPER block (`test-tamper`, and `rescue-real-deletion` for
the page, which is the same block found by the rescan). The scanner writes
`CONTRACT_CHILD:` into the report of every `.N` child whatever blocked it, so a
contract child parked on the reproduction or intent gate has the line and no
deleted case at all: it keeps the 6-hour backstop, and nobody is paged to "rule
on these deleted cases" when there are none.

## What stayed blocking, on purpose

Whole-file deletions (a deleted stub FILE goes to adjudication as before), the
`.0` contract child deleting its own stubs, a marker written only on an ADDED
line, a real case that merely sits under a stub, a build stacked on a branch no
`.0` record claims, and a "replacement" in a file importing a different module. Added openers
pay off REAL removals before stub ones, so a stub retitle can never absorb the
add a real deletion needed. `is_test_path` is untouched —
`tests/test-home-lib.bh-580-test.sh` pins its parity with
`bin/lib/test-home-lib.sh`.

## Where it is pinned

`tests/test-tamper-scan.bh-1047-test.sh` (classifier, pairing, lineage, every
negative, over real throwaway git repos), `tests/run-build-gates.bh-1047-test.sh`
(the pairing through the real gate block), `tests/blocked-resolver.bh-1047-test.sh`
(the floor, the named cases, the single page), and
`docs/verification-map/test-tamper-stub-flip.md`.

## Known limits

The five project-4 records are not on this box, so why their adjudication never
ran there is not diagnosable here; the resolver change is the mechanism the
ticket asked for, not a proof of that cause. A stub file with no resolvable
imports — a bash fixture suite, for instance — can never pair and blocks as
today. The marker list is a code constant, not an env knob.
