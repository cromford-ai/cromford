# A GitHub token is a length, not a prefix: `secret-literals` stops parking every gh-shim PR

Doc: checks/README.md

`checks/secret-literals/check.sh` matched a GitHub credential with

    gh[pousr]_ followed by six alphanumerics

written out as six character classes because mawk has no `{n}` quantifier. Six
alphanumerics is also the shape of `author`. Every function in the REST shim is
named that way — `ghs_author`, `ghs_paginate`, `ghs_passthru`, `ghs_fields_ok`,
`ghs_slug` — so PR #882 answered `CHECKS: 38 hit(s) — secret-literals(x38)` when
BH-1124 was filed and 42 by the time this build ran, every hit a function name,
not a credential. The merge conductor held #882 in BLOCKED_HUMAN for 617 minutes
on them, and any PR that touched a shim file re-tripped it.

The header comment said why there was no quantifier. It never said what replaced
the length bound, because nothing did.

## What changed, in `checks/secret-literals/check.sh`

One new awk function, `gh_token(t)`, and the `gh[pousr]_` line of the
credential-shaped condition became a call to it. Nothing else in the condition
moved: `github_pat_`, `AKIA`, `sk-ant-api`, `xox`, the PEM header and the JWT
header are byte-for-byte what they were.

**LENGTH.** A run has to be at least 24 characters — the four-character prefix
plus 20 alphanumerics. That is the bound `bin/transcript-scrub.sh:124`,
`tests/evals/capture-fixture.py`, `tests/evals/run-evals.sh` and
`tests/skills-sync-test.sh` already redact on, so the repo had agreed on it four
times before this ticket. `match()` and `RLENGTH` carry the bound, so there is
still no `{n}` anywhere in the file.

**Why 24 and not 40.** A real PAT or installation token is the prefix plus 36
alphanumerics, 40 in total, and the ticket says so. The ticket also says the
existing 34-character PAT fake in this repo MUST still hit, and a `>= 40` bound
fails that requirement — the ticket is internally inconsistent and 24 is the
reading that satisfies both of its sentences. It also errs toward detection: the
longest run in this repo that is NOT a token is 13 characters, so the margin is
11.

**SHAPE.** A run immediately followed by `_`, `(`, `=` or `$`, or introduced by
`def `, `function ` or a `|`, is a symbol being defined, called or piped into, not
a literal. Those four `!=` comparisons are written out rather than folded into an
`index()` call because `index()` with an empty needle is not worth relying on, and
the needle IS empty for a run at end-of-line — which must still fire.

**The shape rule stops at 40.** It arbitrates the 24-39 band only; a run of real
token length fires unconditionally. The first cut of this rule applied the shape
clauses at every length, so a genuine 40-character token lost to the punctuation
around it: `| ghs_… |` in a markdown table cell under `docs/**` (which the runner
scans), a token at end of line behind a `|`, and `TOKEN=ghs_…=` all went quiet,
and main's six-class pattern fired on all three. The review of this PR probed
them under mawk and called it — the same narrowing-regression class as the
advance note below. `token-in-table-cell`, `token-after-trailing-pipe`,
`token-with-trailing-equals` and the `mutation-real-length` case pin it now; the
37-character shape probes in section C are unaffected, which is what keeps the
`|`/`=` clauses proven to still quiet identifiers.

**Every run on the line is examined**, not just the first. `match()` finds one
match; an identifier earlier on a line must not hide a literal later on it, so
`gh_token` loops and tracks an absolute offset into the original text.

A rejected run is resumed from two characters in — past `gh`, not past the run.
`[A-Za-z0-9]+` stops at an underscore, so a prefix nested inside an identifier
splits into two runs: `ghs_ghp` (rejected by the `_` clause) and the real
`ghp_` plus 36 alphanumerics behind it. Advancing past the whole rejected run
landed after the second prefix and never looked at it, which would have been a
shape the six-class pattern caught and this one did not — a narrowing that
loses detection, which is the one thing this change must not do. The security
review found it; `nested-prefix-does-not-hide-a-literal` and the
`mutation-advance` case pin it now.

## Who sees the new verdict

Nothing in this change edits a caller, and all four of them see it:

- `bin/merge-sweep.sh` iron-law scan — mined-check hits are added to `FLAGS`, so a
  false hit parked the PR and wrote an ALERTS line.
- `mc_iron_law_scan` in `bin/lib/merge-conductor-lib.sh`, whose count reaches
  `mc_classify` and becomes `BLOCKED_HUMAN iron-law (N hit(s))`. This is the path
  that cost #882 its 617 minutes.
- `bin/run-build.sh` review gates, where hits ride into the review prompt as
  mechanical evidence — a paid reviewer was adjudicating noise.
- `.github/workflows/harness-ci.yml`'s `bin/checks-run.sh --tree .`, which never
  reaches this check at all: `secret-literals` ships no `fixtures/tree-bad/`, so
  it is stdin-only and tree mode skips it.

The change only ever removes hits, so no caller can start parking something it
used to pass.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/secret-literals-token-length.bh-1124-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/checks-suite-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/tests-scratch-only-check-test.sh

The new suite drives the real `bin/checks-run.sh` over generated diffs and asserts
its rc and its `CHECK-HIT` lines, never the text of the pattern. The three
gh-shim lines in its silent case are copied verbatim from the #882 diff, and it
runs that case twice — once against a scratch copy of `checks/` and once against
the catalog this repo ships. Section D sabotages the scratch copy: dropping the
length bound turns the gh-shim case red, and disabling the single `(` exclusion
turns the 37-character call red, so neither half of the rule is riding on the
other. Both are restored and re-asserted green afterwards.

Its two long fixture strings carry the word FIXTURE inside the run, and that is
load-bearing rather than decorative — in `.harness/specs/BH-1124/plan.md` too,
which ships in the mirror and named the unmarked draft string until review
caught it. `bin/share/leakcheck.py` and the mirror's own
`tests/no-client-identifiers-test.sh` refuse to publish a `gh[pousr]_` run of 20
or more alphanumerics unless a marker from `mapping.FIXTURE_MARKERS` sits INSIDE
the matched string. The first draft used a plain alphabet run and turned
`tests/share-mirror-clean-test.sh` and `tests/share-publish-clean.bh-795-test.sh`
red. The marker is the mechanism those scanners document; a shorter fixture would
have stopped proving the branch, and an allowlist entry would have put this
ticket into a lane it does not own.

Both fixtures grew, in opposite directions. `clean.diff` gained a
`bin/lib/gh-shim/read-maps.sh` section with those three real lines, so section 2
of `tests/checks-suite-test.sh` now fails if the false positive ever comes back and
section 3 fails if a sibling check picks it up instead. `violation.diff` gained a
40-character `ghs_` fixture literal, so the branch is still proven to FIRE rather
than quietly turned off — a bounded pattern that matched nothing would look
exactly like a clean diff, which is the failure this catalog exists to refuse.

That fixture line is why two existing assertions changed number. The sweep
red-flag count in `tests/checks-suite-test.sh` and the `secret-literals(xN)`
summary in `tests/tests-scratch-only-check-test.sh` both read that fixture, and
both went from 3 to 4. Same assertions, same strictness, one more seeded
violation to count.

The end-to-end regression case is the real thing: `gh pr diff 882` piped through
the fixed runner answers `CHECKS: clean (4 check(s), 473 added line(s) scanned)`
at rc 0, against 42 hits before.

## Not in this change

- The conductor's iron-law park still pages with a COUNT and no hit lines. The
  ticket marks that optional and separate, and it grows: the count is all
  `mc_iron_law_scan` returns, `mc_classify` takes it as a number, and the alert
  text is built from the state row's TSV `why` field that BH-1044 just spent a
  build bounding. New signature on a pure classifier, new field on a bounded
  state row, `tests/mc/*.sh` churn — its own ticket.
- The `mc_verdict` provenance item the ticket lists under "Also worth a look".
  The ticket says to split it out if it is its own ticket. It is.
- `AKIA`, `sk-ant-api`, `xox`, PEM and JWT keep their patterns exactly as they
  were. `AKIA` has the same six-class shape and the same theoretical weakness, but
  no observed false positive and no ticket line asking for it.
- `github_pat_` keeps its own branch. `i` is not in `[pousr]`, so it was never
  matched by the pattern this ticket bounds, its 11-character prefix is already far
  more specific, and its body legitimately contains `_` — a run-length test there
  needs a different shape and a reason to exist.
