# BH-1335 — the rollout lane resumes, and two parser holes close

Doc: RUN-BUILD-GRAPH

Four defects in the rollout lane, all of them reproduced against main @ `7a587ad`
before anything was edited (`red.txt` in the build dir: 40 failing assertions).

**1. The watermark returned green over a half-filed record.**
`bin/run-rollout.sh` opened with `[ -s "$BUILD/children.txt" ] → ROLLOUT_ALREADY_FILED,
exit 0`, before the filer was ever called and with no `RESULT` line written at all.
A run that filed wave 1 and died answered exit 0 on every later tick, so waves 2
and 3 were never filed and the hook at `bin/run-build.sh:1924` read whatever
`RESULT` the previous run had left behind. It is now a three-way decision made
from the RECORD (`children.txt`) against the SPEC (`children.json`): K ≥ N logs
`ROLLOUT_ALREADY_FILED <KEY> (K of N waves on the record)` and prints a truthful
`RESULT "ROLLOUT_FILED N"`; 0 < K < N logs `ROLLOUT_RESUME <KEY> (K of N waves
already filed)` and falls THROUGH, so `fc_file_issues` reaches its own BH-1482
resume and files only the missing waves; and a record with no readable
`children.json` refuses — absent is not zero (D11).

The filer-side resume was not re-implemented. BH-1482 already landed the
append-only record reader, the per-ordinal `gh issue view` title reconciliation
and the file-only-what-is-missing loop in `bin/lib/fc-issues.sh`; this ticket only
stopped the lane script from returning before that code could run.
`bin/run-build.sh` is not touched — its hook already re-invokes the lane with the
same `$BUILD`, so "the hook resumes" is delivered by making the lane resume.

**2. The RESULT is now counted, not reported.** After the filer returns, the lane
recounts `children.txt`; fewer than N keys is `RESULT "ROLLOUT_FAILED filed K of N
waves"`, rc 1, whatever the filer's own rc said. That is what makes "never a green
partial" true by construction (D9/D12), and it is the arm that catches the case
the resume alone does not: `fc_file_issues` returns 0 without appending anything
when `DECOMPOSE_DRY_RUN=1` meets a non-empty `children.txt`
(`bin/lib/fc-issues.sh:63-66`), which used to print `ROLLOUT_FILED N` over a record
holding one key.

**3. An unclosed backtick span stopped eating HTML block markers.** `strip_span`
in `bin/lib/file-children.sh` and its byte-identical twin `strip_backticks` in
`bin/run-rollout.sh` dropped the rest of a line when a span had no closing marker.
That is the right fail-closed rule for text and the wrong one for a `<pre`/`<code`
OPEN tag, because that tag is exactly what the END pass needs in order to hide
what follows: `` ` `` then `<pre>` then `## Rollout` answered "this IS a rollout"
and filed two phantom waves, under our App identity, with no plan stage. Both
functions now re-emit the canonical marker (`<pre>` or `<code>`) for the first
open tag in the remainder they drop. **Open tags only** — re-emitting a `</pre>`
could close a real block early, the one direction that makes the detector say yes
more often. The rule is monotone (it can only hide more) and was verified inert
over the 1,092 tracked `.md` files in this checkout — every fixture, doc, prompt
and rules file — with zero changes to `fc_has_rollout`'s answer on any of them.

**4. `after:` answers by its real name.** An indented (4+ space) `after:` line was
detected on the trimmed copy and stripped off the RAW one, so the dependency name
came out as the whole literal and the refusal read `unknown dependency`; it is now
`indented after: line`. The prefix comes off the TRIMMED line, so a heading-legal
1-3 space indent parses the way markdown renders it. An empty list (`split("")`
returns 0) was consumed in silence with a green result and is now `empty after:
list`. `after: a, a` rendered `[1,1]` and now renders `[1]`.

A mid-line `<h2>`/`<h3>` inside the section also refuses now (`mid-line heading
tag`). The detector's `gsub` maps a mid-line tag onto a heading of its own while
`classify()` requires the whole trimmed line, so `body one <h3>Wave 2: b</h3>
trailing` counted as a wave in one and as body text in the other: a 3-wave body
filed 2 waves, green. Scoped to inside the `## Rollout` section — an inline tag in
a master's preamble is prose and never reaches a child.

**Out of scope, and still true:** a FRESH build dir for a master whose earlier
build dir filed some waves has no record to resume from, and would file them all
again. That is a build-record lifecycle question, not a parser one. The resume
here is same-build-dir only, which is the documented scope (`RESUME_BUILD`,
auto-resume, the reaper's re-invoke).

**Not changed, on purpose:** the `gh issue view --json` body fetch at
`bin/run-rollout.sh` is GraphQL-backed. The ticket records that as note-only, so
it carries a comment naming the reason rather than a rewrite.

Commands/state touched: no new store, no new env var, no cron line. The artifacts
an operator reads are the same four — `children.json`, `children.txt`,
`rollout-run.txt`, `pipeline.log` — reachable by hand with
`DECOMPOSE_DRY_RUN=1 bin/run-rollout.sh <project> <ticket> <KEY> <build-dir>`.
