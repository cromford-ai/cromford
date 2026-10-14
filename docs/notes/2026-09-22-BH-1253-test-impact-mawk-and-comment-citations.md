# BH-1253: test-impact runs under mawk, follows unbraced `$VAR/` source lines, refuses an empty tree, and stops counting comment citations for the orphan ratchet

Doc: test-impact

**What happened.** `bin/test-impact.sh` could not build a map on any machine in
the fleet. The awk on a box is mawk 1.3.4, and so is the one in the
`debian:trixie-slim` image `bin/run-tests-in-docker.sh` builds; only the hosted
CI runner has gawk. On mawk, `bin/test-impact.sh map` exited 2 with
`awk: run time error: regular expression compile failed (missing operand)` and
`tests/test-impact-test.sh` was `39 passed, 42 failed` — on every box, every
time it ran. CI never saw it, because CI is the one place with gawk.

Nothing was mis-selected as a result. Every failure path in this script falls
through to the whole corpus with a reason, so the boxes were running everything
and the workflow was printing `full: the map could not be built`. The lane was
blind, not unsafe. That is also why it sat.

**The five causes, and the fixes.**

1. **The mawk crash.** `RV_[$1] = (($1 in RV_) ? RV_[$1] "|" : "") $2`, at the
   map scan and again in the audit. mawk creates the array element for the
   LVALUE before it evaluates the right side, so `$1 in RV_` is TRUE the first
   time a suite is seen and the accumulated alternation starts with an empty
   branch — `(|DIR|ROOT|…)`, which mawk then refuses to compile. Written out as
   an explicit `if`/`else` at both sites. gawk evaluates the right side first,
   which is why it never showed there.

2. **`match()` returned the unrooted token.** With (1) patched, `audit` printed
   36 rows, all `fleet.conf`. `TI_PREFIX_AWK` listed `fleet[.]conf` and
   `vercel[.]conf` beside the generic `[A-Za-z0-9_-]+[.](md|conf)` that already
   matches both. gawk is leftmost-LONGEST and takes `@ROOT@/fleet.conf` at
   RSTART 20; mawk takes the shorter, later alternative at RSTART 27, the
   extractor sees an unrooted token behind a `/` and drops it as a scratch
   path. The two redundant alternatives are gone. Rule for the future: no
   alternative in that list may be matched by another one.

3. **Unbraced `$VAR/` source lines reached nothing.** `ti_source_edges` splits
   a line on non-path characters and `$` is one of them, so
   `. "$HARNESS/bin/lib/rb/$_m.sh"` tokenised to `HARNESS/bin/lib/rb/`, which is
   not a path in this tree. The braced `${HARNESS}/…` form worked only because
   `}` is a separator too. Thirty source lines in `bin/` produced no edge:
   `bin/run-build.sh` → `bin/lib/rb/`, `bin/run-build.sh` and
   `bin/lib/rb/review.sh` → `bin/lib/evidence.sh`, twenty scripts →
   `bin/jobs-client.sh`. Every `$NAME` / `${NAME}` is now blanked before the
   split; the token starts at the `/` and the existing leading-slash strip
   resolves it. The map went from 16,100 to 16,650 rows, 173 of them into
   `bin/lib/rb/`, which had none.

4. **A tree with no suites HUNG.** `awk 'prog' $(ls tests/*.sh tests/mc/*.sh)`
   with an empty glob is `awk 'prog'`, and awk with no file operand reads
   stdin. `map`, `orphans` and `audit` blocked for as long as the caller held
   stdin open — rc 124 under `timeout`, and an indefinite wait from a terminal.
   The suite list is built, and refused with rc 2, at the TOP of `ti_build_map`
   and `ti_audit`, and `ti_rootvars` takes it as arguments and refuses an empty
   one itself.

5. **The orphan ratchet counted comment citations.** A suite whose only mention
   of a script is `# see $DIR/bin/x.sh for the real thing` made that script
   look covered. That is the right answer for SELECTION — the map is an
   over-approximation and one extra suite on a diff is the safe direction — and
   exactly the wrong one for the RATCHET, where the question is whether
   anything tests the script. The map built FOR `orphans` now skips lines whose
   first non-blank character is `#` (`TI_ORPHAN_STRICT`, scoped to
   `ti_orphans`); every other command builds the same map it always did. 95
   orphans became 113. A trailing comment after real code still counts.
   `orphans --check` scores both trees with the current script, so the 18
   newly-visible holes appear on both sides and none reads as NEW — verified
   against `origin/main` before this landed.

**Which state and commands this touches.** `bin/test-impact.sh` only:
`map`, `select`, `ci-select`, `orphans`, `orphans --check`, `audit`, `always`.
`.github/workflows/harness-ci.yml` calls `ci-select` in four jobs and
`orphans --check` in `lint`; none of them changes. The map is derived and
git-ignored, so there is no stored artifact to regenerate.

**What this does NOT change.** Selection narrows for nobody: the comment rule
is scoped to the orphan build, and the source-edge fix only ADDS rows. The
`audit` is empty before and after. A `--map` override still bypasses the
rebuild entirely, so a test that hands `orphans` a pre-built map gets that
map's rows as-is.

**Evidence.** `tests/test-impact.bh-1253-test.sh` is the new per-ticket suite:
27 cases, all four defects driven through `bin/test-impact.sh` as a command.
It compares a map built under a mawk `PATH` shim with one built under the box's
own `awk` byte for byte, and skips the mawk half with a printed line on a host
that has no mawk. `tests/test-impact-test.sh` goes from `39 passed, 42 failed`
to `81 passed, 0 failed` on a mawk box — the first time that suite has been
green on a fleet machine or in the docker gate.

**Still open, deliberately.** `docs/CI-RUNNERS.md` says the Fly test image
carries gawk and the #1212 review reports `ubuntu:24.04` without it. That
discrepancy is not adjudicated here; it is a pointer for whoever next touches
the image. Nothing in this change depends on which of the two is right, because
the script now behaves identically under either awk.
