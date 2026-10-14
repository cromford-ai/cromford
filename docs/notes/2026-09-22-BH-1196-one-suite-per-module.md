# One suite per module: `tests/blocked-resolver-test.sh` split seven ways, one shared fixture lib

Doc: MERGE-CONDUCTOR, RESOLVER-MODULES

**What changed.** `tests/blocked-resolver-test.sh` was a 2,342-line monolith
carrying 18 numbered sections and 455 runtime assertions. Its sections moved,
whole and verbatim, into seven suites named for the concern they drive — the
`bin/lib/br/` module where one exists, the neighbour contract where none does.
The six merge-conductor-family suites and the seven new ones now take their
scratch harness from one lib. No assertion was added, removed, reworded or
loosened; nothing under `bin/` changed.

## The partition

| section(s) in the old file | new suite |
|---|---|
| 1. the classifier | `tests/br-ladder-test.sh` |
| 2, 2b, 2c, 2d, 2e, 3, 6 | `tests/br-rebuild-test.sh` |
| 6b, 6c | `tests/br-reads-test.sh` |
| 4, 5, 7 | `tests/br-neighbors-test.sh` |
| 8, 8f | `tests/br-rungs-test.sh` |
| 9, 10 | `tests/br-contested-test.sh` |
| the SECOND "9." (the rebuild's own outcome) → **11.** | `tests/br-rebuild-outcome-test.sh` |

The old file had two sections numbered `9.`. The second one is `11.` in its new
file, with a comment saying where it came from; every other section keeps its
original number, in its original header, in its original order inside the file.

`bin/lib/br/record.sh` gets no suite. No section of the monolith drives it
purely — every `br_record` / `br_seen_rebuild` assertion goes through the
running lane — and a suite with no cases asserts nothing.

## How the move is judged

`tests/br/expected-sections.tsv` is `suite<TAB>section<TAB>ok<TAB>bad`,
generated from the monolith on the merge base (blob `b898b5fd`, `origin/main`
at 42c0c7c) BEFORE a line moved: 18 rows, ok 180, bad 391.
`tests/br-suite-partition.bh-1196-test.sh` re-counts the new files with the same
counter and asserts every section exists in exactly ONE suite with the same
counts, that the totals match, that `--list` on the runner prints exactly the
manifest's suites, and that the old file carries no section and no `ok`/`bad`
command word any more. 56 cases.

The counter: a section is a `# <id>. ` line IMMEDIATELY after a `# =====` rule
line, so a numbered list inside a comment is never a section and `# ---- 10a.`
sub-headers are not sections; `ok` and `bad` count as COMMAND WORDS only (start
of line, or after `;` `&` `|` `{`), so `"ok":true` in a stub's JSON and the
words inside a message string never count. Two of the test's cases are the
counter's own negatives and mutation: a fixture of nothing but the four
non-counting shapes must score 0/0 next to one real opener scoring 1/1, and
deleting one `&& ok || bad` line from a scratch copy of a real suite must cost
exactly one `ok` and one `bad`.

## The fixture lib

`tests/lib/fixture-harness.sh` is the one entry point, and it sources
`tests/lib/rb-all.sh` and `tests/lib/br-modules.sh` itself:

- `fx_tree <T>` — the scratch tree both families share.
- `fx_restpr <repo-dir> <T>` — the REST answer emitter.
- `fx_mc_harness <repo-dir> <T>` — the conductor family's eight-line block,
  which six suites carried and `tests/mc/classify-test.sh` carried twice.
- `fx_conductor_tick <repo-dir> <T>` — what the four suites that drive the whole
  tick add on top.
- `fx_br_harness <repo-dir> <T>` — the monolith's lines 24-123: modules, sibling
  libs, `fleet.conf`, the stub scripts, the recording `gh` and `br-ssh` stubs,
  the stubbed `PATH`, `GH_TOKEN=""`, and the `BRENV`/`RUN`/`ROW`/`ROWST`/
  `STATEJSON`/`SPENT` helpers.
- `fx_br_ladder_git <repo-dir> <T>` — the monolith's section-8 fixture (lines
  846-988): a real local git whose branches genuinely conflict with main, the
  `mc_rebase` rc contract, and the section's own `gh` and `agent-call` stubs.

Every function takes its roots as ARGUMENTS and returns non-zero on the first
failed `mkdir`/`cp`; every caller appends `|| exit 1`. Two things stay in each
suite on purpose: `. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init` (sourcing
the thing under test is the suite's own act) and the `cp` of the scripts the
suite DRIVES plus one rooted `$DIR/...` token, because `bin/test-impact.sh`
selects suites by those tokens and a `cp` that moved into the lib would stop
selecting the family when the lane changes.

## Carried setup

Two things the moved sections used to inherit from sections that now live in
another file, added as SETUP lines with a comment naming where they came from —
never by touching an assertion:

- the jobs-client stub (the monolith's lines 748-752, byte-identical to the one
  at 692) is installed by `fx_br_ladder_git`; the ladder's rebuild rung enqueues
  through it and section 8 never wrote its own.
- `SPENT tproj-TK-88` at the top of `tests/br-contested-test.sh`. Section 9b
  expects today's rung on that ticket to be the rebuild, which is true only
  because section 8 had already spent its mechanical rung and its fix round in
  the same process (measured on the monolith: `mechanicals` 1, `fixrounds` 1,
  `rebuilds` 0).

## `tests/blocked-resolver-test.sh` keeps its name for one release

Seven verification-map entries, three dated notes and `docs/MERGE-CONDUCTOR.md`
name that path. Rather than repoint all of them in the same diff that moves
2,300 lines, the file is now a ~60-line runner: it runs every suite the manifest
names, sums their summaries, prints `blocked-resolver-test: N passed, M failed`
and exits non-zero if any child failed OR printed no summary at all — a child
that dies before it can count must never read as zero failures. `--list` prints
the suites it would run. Removing it and repointing what names it is a follow-up
ticket, not filed at the time of writing.

The cost of the overlap is stated rather than hidden: in CI the seven suites run
in their own shards AND again through the runner in its shard, about 1m45s of
extra CI for one release.

## Verified

- Baseline on `origin/main` (42c0c7c), this session: `blocked-resolver-test: 455
  passed, 0 failed`; `merge-conductor-test: 23`, `mc/classify-test: 194`,
  `mc/queue-test: 24`, `mc/rebase-test: 199`, `mc/settle-test: 9`.
- After: the seven suites sum to 455 (66 + 36 + 51 + 19 + 78 + 145 + 60), the
  runner prints `blocked-resolver-test: 455 passed, 0 failed` rc 0, and the five
  mc suites print the same five counts as the baseline.

## Files touched

- `tests/blocked-resolver-test.sh` (monolith → runner)
- `tests/br-{ladder,rebuild,reads,neighbors,rungs,contested,rebuild-outcome}-test.sh` (new)
- `tests/br-suite-partition.bh-1196-test.sh`, `tests/br/expected-sections.tsv` (new)
- `tests/lib/fixture-harness.sh` (new)
- `tests/merge-conductor-test.sh`, `tests/mc/{classify,queue,rebase,settle}-test.sh` (fixture header only)
- `docs/verification-map/resolver-modules.md`, `docs/verification-map/mc-modules.md`, `docs/verification-map/entries/BH-1196.md`
