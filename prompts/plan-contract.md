# Plan contract v2 — decompose-and-route

The decomposition contract for routing planned work to cheaper builders. v1 (pilot 1321) produced faithful units and a blocked PR — every defect traced to plan-level omissions. v2 adds the SYSTEM INVARIANTS section as a mandatory, frontier-authored part of the plan, written BEFORE decomposition.

## 1. System invariants (NEW — the T3 kernel; frontier-authored, never delegated)

Before any unit is cut, the plan must answer, in writing, for the whole feature:

- **State durability.** Every piece of cross-run state names its store and defends it. Default: a real table (append-only ledger with a natural unique key) for anything that dedups, watermarks, or claims. Config-JSON blobs only for operator-editable knobs — never for state the correctness of writes depends on, and never pruned against a capped or filtered query.
- **Failure ≠ success, per side effect.** For every external side effect (send, post, DND write, expiry): what is recorded on success, on failure, on not-configured — and in what order relative to the state write (claim-before-post for at-most-once, post-before-persist never without an idempotent retry story). "Stamped done without delivery" must be impossible by construction.
- **Adversarial negatives.** Any classifier or matcher that gates an irreversible or client-visible action ships with an adversarial negative list IN THE PLAN (realistic inputs that must NOT trigger), and its unit's acceptance tests must include them.
- **Neighbor interactions.** Enumerate the caps, schedulers, cron lanes, locks, and sibling agents the feature's queries and registry entries will touch (e.g. query row caps interacting with pruning; cron schedule buckets like step-catchup lanes; scheduled-send exemptions on expiry sweeps). Each gets either a spec clause in a unit or an explicit non-interaction argument.
- **Config-not-code, enumerated.** List every threshold/target the feature introduces and its AgentConfig key + default. A constant not on the list is a review finding.

## 2. Decomposition rules (from pilot 1321, kept)

- Tracer first: unit 0 is the thinnest end-to-end slice (real trigger → persisted result → observable outcome) and commits the shared names it really uses as working code, not skeletons. Units slice by user capability, not by layer; a layer split is a decomposition failure. Every unit names its observable outcome.
- Units own disjoint files; anything two units would touch belongs to unit 0. Semantic dependencies sequence (blocked-by); parallelize only true independents. Prefer few, chunky units.
- Every sub-ticket carries the whole-feature brief + the FULL invariants section, its exact files, a pattern-pointer to copy, concrete acceptance tests (red-first), and non-goals.
- Bounce rule: needing a file outside scope = stop and report, never improvise.
- Tier gate: a unit routes cheap only if the plan compiled all four spec parts AND no invariant's implementation lives inside it undesigned. Invariant-bearing wiring (the unit that persists state or orders side effects) gets its invariant decisions made in the plan, not by the builder.

## 3. Gates (kept, now with teeth)

- Frontier per-unit review; integration runs the FULL suite (a green unit can break a neighbor through one shared file — observed live in pilot 1321 via a registry cron schedule).
- Frontier whole-PR blind-style adversarial review before merge — per-unit review + green integration passed a blockable PR in pilot 1321; the whole-diff read is the safety mechanism for cheap-built work, not overhead.

## 4. Requirements-coverage matrix (v3, from pilot 1313)

Pilot 1313: the invariants section eliminated the invariant-class defects (zero bounce rounds, blind review praised the engineering) — and the challenger still blocked, on three requirements the PLAN under-read: a headline late-delivery grace path never planned, owed-ness logic for late registrants missing, and an explicitly-banned alert channel retained in narrowed form.

- The plan MUST end with a matrix: every numbered ticket requirement → the unit that implements it → the acceptance test that proves it. A requirement with no row is a plan defect; "not applicable" requires a written argument.
- Negative/policy requirements ("no X going forward", "never Y") get the same treatment — a row naming the unit that REMOVES or refuses the behavior and the test that pins its absence.
- The whole-PR review checks the matrix against the ticket before checking the code.

## 5. KIND: which workflow this ticket gets (SDLC item 7, 2026-09-06)

One workflow served every ticket — copy tweak, schema migration and defect all got the same "write the acceptance tests first" execute prompt and the same lens routing. The defect is the one that suffered: what proves a bug fix is a REPRODUCTION that fails on the code as it stands, and nothing asked for one.

- The plan carries `KIND: bug|feature|copy|migration|infra` on the line immediately BEFORE the final `SIZE:` line. Deterministic evidence outranks it: a board type field, a GitHub `bug` label or a COLON-anchored title prefix (`fix:`, `[bug]`, `chore:` — never a dash or slash separator, and never `build`/`data`, which are ordinary English about the work) classifies the ticket without asking a model, and `bin/kind-gate.sh` settles the two. When neither speaks the kind is `unknown` — not-measured, never a guess — and no kind-specific routing applies.
- **KIND: bug adds a `## Reproduction` section**, and it is the section the build is judged on: `REPRO:` (the exact command or test that FAILS against the code as it stands), `OBSERVED:`, `EXPECTED:`, `ROOT CAUSE: <file:line>` (found by reading the code — the place the defect lives, never the call site where the symptom showed), `BLAST RADIUS:` (the callers and dependents from the graph). EXECUTE runs the REPRO command before it edits anything and saves the failure as `red.txt`, so `bin/repro-gate.sh` proves it against the merge base. A REPRO that does not fail today stops the build for a human rather than being fixed around — five pre-existing failures were once blamed on a PR that did not cause them (TK-113), and a fail-closed 404 is not missing code (TK-44).
- Write those five as their own colon-anchored lines, never as `VALIDATE:`/`SATISFIES:` lines: `bin/plan-gate.sh` scores any block carrying those as a task, and a reproduction is evidence about the defect rather than a task that delivers a criterion.
- **KIND: copy** buys less verification, not more: the preview E2E smoke and the reopen-armed extra security lens are skipped. The lens the DIFF earns is never skipped — a diff touching auth, money, schema or webhooks gets the security review whatever the board's label says.
- The kind rides into `logs/findings.log` (`kind=`), the ledger (a `build_kind` artifact at plan time, and the `kind` field on the verdict row), and `$BUILD/kind.txt` as the documented file fallback. `KIND_GATE_ENFORCE=0` is the shipped default: everything is recorded, nothing is withheld. `=1` arms the tier-2 demotion for a bug with no reproduction, and the copy skips.

## 6. SIZE: the plan declares how big it is, and too big is split (2026-09-12)

Decomposition existed since SCALE-PLAN wave 2 and fired on one input: a planner writing `SIZE: XL` on the last line of its own plan. Self-reported, all-or-nothing, unmeasured — an `L` plan that turned into 1,400 lines looked exactly like an `L` plan that turned into 200. Measured across 381 merged harness PRs, the MEDIAN diff is 1,268 lines changed; large orgs land 100-300, because review cost, conflict probability and re-review cost all grow superlinearly with size.

- The plan carries a **`## Size` section** with two lines, `FILES: <n>` and `LINES: <n>`, and it is mechanically checked by `bin/size-gate.sh`. A plan with no size declaration is `PLAN_MALFORMED` — the same terminal, the same requeue-once-then-a-human ledger, as a plan whose tasks carry no `VALIDATE:`/`SATISFIES:` line. Not-measured and small-enough are different facts and only one of them is a claim.
- **The unit is PRODUCT lines.** Tests, docs and markdown, the plan/spec itself, lockfiles, generated code and Prisma migration snapshots do not count — `bin/size-scope.sh` owns that list, is the only place it lives, and prints it with `--rules`. Counting tests would punish the red-first discipline the rest of this pipeline pays to enforce; counting lockfiles would make `npm install` a decomposable event.
- **The threshold is per project, not a constant**: `bin/size-threshold.sh` resolves, per axis, the settings rows `size_gate.lines.<project>` / `size_gate.files.<project>` → `size_gate.lines` / `size_gate.files` (seeded 700 / 20, editable and audited on the console's /config) → `flags/size-gate-<project>` (the box-local lever) → `catalog/size-thresholds.conf` → 700 lines / 20 files. The source it used is on the record as `src=` (BH-4985).
- **Both numbers are the plan's own, and the check happens after the build** (BH-612, 2026-09-16). The file axis used to be "corroborated" against `planned-files.txt`, but `bin/planned-files.sh` builds that as a deliberate over-listing of every path the plan MENTIONS — the callers it read, the `## Out of scope` list, the "do NOT edit src/x.ts" line — because over-listing costs a serialization and under-listing costs a conflict. Judged on it, a 45-line two-file fix whose prose named eighteen callers was decomposed (project-5 #1906, #1907). So `FILES:` is now judged on what you DECLARE; the mention count stays on the record as `SIZE_FILES_PLANNED`, and as `SIZE_FILES_MENTIONED: n (not gating)` when it is over the tolerated limit. The honest check moved to where reality exists: at PR-open the declaration is compared with the product files the diff actually carries, and a plan that declared itself inside the limit while shipping past it is flagged `SIZE_DECLARATION_EXCEEDED` in the evidence block — a warning on the PR, never a block.
- Over either limit the ticket is handed to `bin/run-decompose.sh`, which files **ordered** children (each under the same budget, each carrying `Order: <n> of <total>`, file-disjoint where they genuinely are; §15 says how: one seam file per sibling) and `children.txt` is written in landing order. On a GitHub-Issues board the children are filed as `ai-build` issues carrying `Part of #<parent>` and `Blocked-by: #<sibling>`, and the parent loses the `ai-build` label as the master of the split.
- **Enforcement is ON by default since 2026-09-14**: over the threshold the build STOPS at `DECOMPOSED` and the split ships instead, and a plan that declares no size is `PLAN_MALFORMED`. Size the plan honestly — an estimate shaded down to dodge the split is the 1,900-line PR nobody reviews. `flags/size-gate-enforce-off` (fleet) and `SIZE_GATE_ENFORCE_<project>=0` (one project) turn it back off; `SIZE: XL` splits either way.
- **A split child is never split again** (depth 1). A ticket whose TITLE begins `<PARENT KEY>.<n>:` is already a slice of something: if your plan for it is still over the threshold, say so in the plan and it is built whole rather than split.
- **A plan that builds only ONE slice of its ticket says so on its own line: `SLICE: C<n> of #<ticket>`** (C0 for the first slice; BH-2508). The planner prompt asks for it in these words: IF THIS PLAN BUILDS ONLY ONE SLICE of the ticket and leaves the rest to child tickets, write the line 'SLICE: C<n> of #$TICKET' on its own line in plan.md (C0 for the first slice): the merge close-out reads that exact line to leave this ticket open and take ai-build off it. `issue_close_guard` matches it at line start (bold, italic or quote markup allowed) and only for THIS ticket's number. Both repair passes (plan gate, size gate) are told to keep the line as it is.
- At PR-open the diff that actually shipped is measured the same way. Over **2×** the threshold the PR carries a `SIZE:` note naming the number (always) and demotes to tier 2 (only when armed). It never blocks — by then the code is written, and the estimate being wrong is a planning finding, not a reason to throw the diff away.

## 7. DEPENDS: the plan says whether a `Blocked-by` line is real (W2-G, 2026-09-14)

Decomposition sequences children with `Blocked-by: #N`, and everything downstream
has treated that line as an ORDER: the child waits for #N to close, or at best
stacks on #N's open PR. But the line is written once, by hand, before either
slice exists, and it over-declares. project-5's #666-#678 wave declares five
chain levels — at 60-75 minutes a level, five sequential hours of a box that is
otherwise idle — while several of those children share no files with their
parent at all. the operator, on being told the wave runs only as wide as its hand-written
Blocked-by lines: *"how do we do that by default?"*

So the line became a claim the harness checks (`bin/dep-verify.sh`), and the plan
is half the evidence.

- **A plan for a ticket whose body carries `Blocked-by:` lines MUST carry a
  `## Dependencies` section with one line per blocker**, each exactly
  `DEPENDS: #N hard — <reason>` or `DEPENDS: #N soft — <reason>`.
- **hard** = this slice imports, calls, extends or migrates on top of code `#N`
  adds; it cannot compile or run until `#N` lands. **soft** = ordering preference
  only — nothing here reads a symbol, table or route `#N` introduces.
- The call is made from the code the planner just read, never from the fact that
  somebody typed the line.
- **Missing, unreadable or absent is UNKNOWN.** What UNKNOWN does is the box's
  `DEP_UNKNOWN_MODE` (default `soft` since 2026-09-16: the child is released and
  the merge conductor rebases it if a real overlap surfaces; `hard` holds it like
  a hard verdict). Either way the line you write is the evidence that decides the
  pair for real, so say hard when it is hard: a wrong `soft` costs a build
  against a base that does not carry the code it needs.
- The other half of the evidence is mechanical and the plan does not get a vote
  on it: the child's `planned-files.txt` must be **disjoint** from the blocker's
  file set (its open PR's changed files, else its merged PR's, else the blocker's
  own pre-plan list), under the same overlap rule `bin/conflict-check.sh` and
  `bin/plan-overlap.sh` apply. Both halves, or the ticket waits.
- **The author's escape hatch outranks both**: `Blocked-by: #N (hard)` or
  `Needs: #N` in the issue body is hard with no verification at all. A split
  child gets exactly one of those and it is the contract chunk
  (`bin/run-decompose.sh`, BH-481): every sibling imports it, so that link is
  real and nothing second-guesses it.
- **A decomposed child's body already carries its `DEPENDS:` lines** — the filer
  writes one per sibling, `hard` with the symbol when the spec said this slice
  imports that sibling's code and `soft` otherwise. Carry them into the plan's
  `## Dependencies` section, and change one only when the code you just read
  says the filer was wrong. Say so in the plan when you do.
- `DEPENDS:` is deliberately not a `VALIDATE:`/`SATISFIES:` line and the section
  is not a task block — `bin/plan-gate.sh` scores neither, for the same reason
  `## Reproduction` is written the way it is in §5.

## 8. Documentation: a dated note, not the monolith (BH-476, 2026-09-18)

"Document it" used to mean "append a paragraph to the doc this touches", and five docs absorbed it: `docs/MERGE-CONDUCTOR.md` was edited in 18 of the 100 PRs merged 2026-09-13..15, `docs/BUILD-CONCURRENCY.md` in 14, `docs/RUN-BUILD-GRAPH.md`, `docs/OPERATOR-SETUP.md` and `docs/EVENTS.md` in 9 each. They hold 5,625 lines between them, most of it dated prose about changes, and on 2026-09-16 nine of seventeen cromford builds were deferred on file overlap in exactly those files. Two builds documenting two unrelated things collided on the same paragraph boundary.

- **One change, one new file:** `docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md` — the date the change was made, the ticket key, and 2-5 lowercase hyphenated words. It says what changed, why, and which rule, state or command it touches, and it carries a `Doc: <NAME>[, <NAME>]` line naming the contract docs it belongs to (no tag line is legal; the note lands under `untagged` rather than being dropped).
- **The note is in the plan's file list**, like any other file the build writes. A plan that says "document it" without naming the note file has not planned the documentation.
- **Never edited after merge.** A correction is a later note, not a rewrite of an old one. That is what makes notes conflict-free: no two builds ever hold the same file open.
- **`docs/notes/INDEX.md` is rendered, never hand-written** — `bin/render-doc-index.sh` regenerates it in a docs pass. A feature PR does not re-render it, and a plan must not add that step: the whole point is that one generated file stops being a merge surface on every build.
- **The five contract docs keep their stable text** — state tables, invariants, commands — plus the short Changes region pointing at the index. `guardrails/doc-monolith-edit` checks for exactly that — a PR that edits them outside the region without a `docs:` title — and fails it once armed in CI (the adoption PR is still to come); until then it is a review-blocker, so a plan that routes documentation into a monolith is planning a rejected build either way.

## 8. Test files are per-ticket (#580)

Test files are the fleet's largest merge-conflict surface: 20 of 24 unresolvable
conductor cases were siblings appending cases to the same shared
`tests/<tier>/<area>.test.ts`. Two builds that touch no product file in common
still collide there, and the conflict surfaces at merge time, hours after either
of them could cheaply have been told.

- **New test cases go in a NEW file named for the ticket**:
  `tests/<tier>/<area>.<key-lower>.test.ts`, shell suites
  `tests/<area>.<key-lower>-test.sh`. Name that file in the plan's
  files-to-touch — it is what the executor is handed.
- **One exception**: the ticket's scope is to CHANGE an existing test's
  behaviour — a bug reproduction that belongs next to the case it fixes, a spec
  change to a case that already exists. Then the shared file is the right file
  and the plan says which case it is changing.
- The rule is applied twice before a planner ever sees it, from one definition
  in `bin/lib/test-home-lib.sh`: `bin/planned-files-cheap.sh` rewrites a shared
  test path in the pre-plan list to this ticket's own name (recording the swap
  at `state/preplan-files/<project>-<KEY>`, and leaving a `KIND: bug` ticket
  alone), and `bin/run-preplan.sh` interpolates the same sentence into the
  pre-plan prompt.
- **Kill switch**: `flags/test-reroute-off` — the file form, which works from
  any lane because the pre-plan pass reads it off `$HARNESS` — or
  `TEST_REROUTE=0` in the environment that lane runs with. Either one turns the
  list rewrite off. It does not silence the planner sentence, which is a
  sentence and costs nothing to ignore.

- **Fixtures in the plan's tests look fake on purpose (BH-5789).** Name RFC 5737 addresses (`192.0.2.x`, `198.51.100.x`, `203.0.113.x`) and tokens with `fixture` in the value. Never a tailnet `100.64/10` or RFC1918 address, a real hostname or a client name. `bin/fixture-hygiene.sh` refuses the new test lines that break this.

## 9. Rollout: the body convention (BH-816, 2026-09-19)

When the work is a sequence of waves that must land in order, a plan-writing
session emits ONE ticket in the shape below instead of filing N issues by hand
and labelling each one as the previous merges. The harness files one child per
wave, sequences them with `Blocked-by: #<n> (hard)`, and parks the master. No
model call is spent on the master: the waves are already written, and the
ordinary PLAN stage fleshes each child out when its turn comes.

```
## Rollout
### Wave: <title>
after: <title of an earlier wave>[, <title>]     (optional; omit for none)
<body: the wave's own Scope / Acceptance tests / QA screens / Out of scope>
### Wave: <title>
...
```

The shape the parser accepts:

- **`## Rollout` and `### Wave:` are case-insensitive.** Leading and trailing
  whitespace on the heading line is trimmed. `##Rollout` with no space is not
  the heading, and neither is a suffixed `## Rollout risk`.
- **HTML bodies are tolerated.** An in-app board stores `<h2>Rollout</h2>` and
  `<h3>Wave: …</h3>`; the detector strips tags before it looks, so the HTML
  body and the markdown one read the same (`fc_strip_fences` in
  `bin/lib/file-children.sh` maps `<h2>`/`<h3>` to `##`/`###` and drops the
  rest).
- **`after:` only as the first non-blank line of a wave.** It names earlier
  waves by title, comma-separated. A name that resolves to a later wave, to an
  unknown wave or to the wave itself is a refusal, not a guess.
- **Text above the `## Rollout` heading stays on the master** as its own
  description. Write the context there; write nothing below it that is not a
  wave.
- **A heading inside a fence or a code span is NOT a rollout.** Issue #816's own
  body documents this convention inside a fence, and that body must never arm
  the lane. `fc_strip_fences` drops fenced blocks of either marker, backtick
  spans, `<pre>` and `<code>` before `fc_has_rollout` looks for the heading, and an
  unterminated fence or span swallows the rest: a body we cannot parse
  confidently does not file issues on anyone's repo.
- **A blockquoted `> ## Rollout` is a quoted spec, not a declaration**, and does
  not arm the lane either.
- **A stray backtick in front of a raw `<pre>`/`<code>` hides what follows it.**
  The span runs to end of line, and the OPEN tag it would otherwise swallow is
  re-emitted, so the block stays open and everything after it is code. Write the
  waves above any such line, or close the span: a `## Rollout` under an unclosed
  backtick plus a `<pre>` is read as "not a rollout", and one inside an already
  open `## Rollout` section is `ROLLOUT_FAILED unterminated code block`.
- **A `<h2>`/`<h3>` tag inside the section must be the WHOLE trimmed line.**
  `body one <h3>Wave 2: b</h3> trailing` refuses with `mid-line heading tag`,
  because the detector counts it as a wave and the parser does not — that
  divergence used to file fewer waves than the author wrote, quietly. An inline
  tag in the text ABOVE `## Rollout` is prose and is fine.
- **The `after:` line is read strictly.** An indented (4+ space) `after:` is a
  code block, so it refuses with `indented after: line` rather than being
  honoured or dropped; `after:` with nothing after it refuses with `empty after:
  list`; and a name repeated in the list (`after: a, a`) counts once.

The wave count and the rest of the parse belong to `bin/run-rollout.sh`, which
the rollout slice of #816 adds: 2 to 12 waves, unique titles, no `## Rollout`
inside a wave body, and, on an in-app board, a board that advertises the
`dependencies` capability. Until that script is on a box, a `## Rollout` body
there is planned and built like any other ticket.

## 10. Operating lessons (BH-5289)

- A plan never lists `catalog/ci-suite-durations.tsv` in files-to-touch. The
  file is git-ignored; CI composes the timing rows from its own runs
  (docs/ci-durations.md, BH-5518).
- A plan that proposes a new limit on a harmless metric (time, size, line count)
  makes it a report, not a gate. Money and safety caps stay gates.
- A plan whose files overlap a live sibling's plan says so and sequences behind
  it, instead of racing it to main.
- A plan outside `bin/` and `worker/` that adds or changes a decision rule (a classifier, gate, regex, glob, match or filter) also carries the §13 Decision rule case table, with its near misses, case sources and PLAN_BLOCKED rule. §13 is the one definition; this bullet only widens its scope, and `bin/plan-gate.sh` checks it only for `bin/` and `worker/` plans. (lesson-propose: logic-decision-rule-wrong)
- A plan that adds a state that can wait or count must include a table of exits. Such a state can be a queued row, a park, a hold, a marker file, an attempt counter, a lock or a temp directory. The table has one row for each state. Each row names the code that ends that state on success, on a hard failure, on a transient failure, on SIGTERM, and when the head moves or the PR closes. It also names the deadline that ends the state if nothing else does, and the alert that fires at that deadline. Do not count a transient failure against an attempt cap. A transient failure is a rate limit, rc 75, a timeout or a box fault. If no code ends a state on some path, the plan must say so and give the reason. (lesson-propose: logic-stuck-state-or-burned-budget)
- docs/OPERATING.md has the reasons and the knobs.

## 11. Conflict discipline and `## Shared files` (BH-5269)

- Read the CONFLICT HOTSPOTS section of the project primer before choosing files. Those rows are the project's own weekly measurement.
- Prefer the seam to the hotspot: a new file to a shared list, a fragment directory to a registry, a module to a big script, a dated note to a changelog header, `scratch_install_closure` to a hand-written lib list.
- The plan carries a `## Shared files` section. One line per hotspot file the plan names: `- <path> — <reason>` (why this change must touch it, or "named only, not edited"). Write `None` when the plan names no hotspot.
- `bin/plan-gate.sh` reports a hotspot named outside that section and not listed in it (`SHARED_UNLISTED: <path>`, `PLAN_SHARED: unlisted`). It is a report, not a refusal (§10): the trace verdict and the exit code do not change.

## 12. Test style: assert the fields you own (BH-5792)

- An acceptance test asserts the fields this ticket owns (`.ready`, `body.accounts`, the rows it writes), never the whole payload. A whole-output pin breaks when another ticket adds an unrelated key (#4126 after BH-4010).
- A whole-output pin is allowed only in a contract test: a file named `*.contract.test.*`, or a file with a `# contract-test` (or `// contract-test`) line in its header.
- An acceptance test in a plan names the fields it asserts.
- `bin/test-payload-pin-lint.sh` reports a new whole-payload compare. It is a warning (`mode warn` in `catalog/payload-pin-lint.conf`), not a gate. docs/TESTING.md has the reasons.

## 13. Failure modes for bin/ and worker/ changes (BH-5800)

47 of the 66 logic-bug BLOCK findings in the 2026-10 review-block analysis
fell into six patterns a plan can answer before any code. A plan that changes
a file under `bin/` or `worker/` carries a `## Failure modes` section with one
bullet per heading below, in the form `- <Label>: <answer>. Test: <the
acceptance test>`, or `- <Label>: n/a — <why it does not apply>`. Each answer
becomes an acceptance test.

- **Decision rule:** for each decision rule, a table of 2 or more cases on
  each side, including the edge case (14 BLOCKs: a rule matched the wrong cases).
  The table includes the near misses for that rule: negated text ("NOT in
  C1"), partial or substring matches, other output formats and tool versions
  (npm "npm error" vs "npm err!", a bare HOLD line), data past the first page,
  state that children inherit, cases an earlier filter already removed
  (in-flight, other board types), and success lines that print next to
  errors. Take each case from production logs, live data or the real tool.
  When no live source can be read, use a fixture or the vendor docs and mark
  the case `source: assumed`. A case whose side is unknown stops the plan as
  PLAN_BLOCKED; a missing source does not. A test asserts every case (one
  table-driven test is enough).
- **Exit paths:** for each exit path, the state it leaves and the budget or
  counter it touches (9: a failure path left a stuck state or burned a budget).
- **Writer/reader round-trip:** for each new format, every writer and every
  reader, and a test that round-trips it (8: a short sha against a 40-hex).
- **Alert or freeze blast radius:** for each new alert or freeze, its
  worst-case count on the first tick and its scope (8: 665 pages on the first
  tick).
- **Defaults in prod:** for each new knob, its default in prod and why (4: the
  feature off in prod, or a shadow mode that does real work).
- **Status evidence:** for each status or report line, the evidence that makes
  it say "done" (4: done reported when nothing happened).

The headings are data in `catalog/plan-failure-modes.tsv`. `bin/plan-gate.sh`
refuses a plan that names a `bin/` or `worker/` path without them (an
`UNTRACED: failure modes — <label>` line, the same repair pass, then
PLAN_MALFORMED). The lead review checks each answer against the diff.

## 14. `## Spec changes from comments` (BH-5799)

- Read the ticket thread newest first. The plan carries a `## Spec changes from comments` section with one line per comment that changes scope: a new or removed column or field, a cadence, "do not merge", an input folded in, a narrowed or reversed body item.
- Each line starts with the comment id (the number after `#issuecomment-` on a GitHub issue), then the author, then what changed and which task delivers it. If no comment changes scope, the section is the single line `none`.
- On a GitHub-issue project, `bin/lib/plan-thread.sh` refuses a plan when a comment by a person or our App is newer than the plan's stamp (`plan-thread-at`) and plan.md does not cite its id. A reused or adopted plan is refused before the checkpoint and planned fresh in the same run. A plan refused at the top of the review stage ends `PLAN_STALE` with plan.md moved to `plan.md.thread-refused`. `PLAN_THREAD_GATE_ENFORCE=0` makes both a warning.
- The section rides into the PR body. The lead review checklist (item 1) compares it with the thread.
- `bin/plan-gate.sh` never scores this section as tasks.

## 15. Seam files and Owns: (BH-6384)
- When a split has a contract child (C0) and later children, C0 creates one seam file per later child. A seam is an empty placeholder export that the shared code already imports (for example `ReviewAutonomy = () => null` or `EXTRA_BODIES = {}`). Each seam has a one-line comment that names its owner child (`<KEY>.<n>`).
- Each later child's plan edits only its own seam file(s), plus files that no other sibling of the same parent lists.
- A shared list is a registry folder with one file per entry. It is never an array that several children append to.
- When two children must edit the same existing file, the later one carries `DEPENDS: #<earlier> hard — same file <path>`. It does not take a parallel slot. In the decompose spec this is the `after` entry `"<position>: same file <path>"`.
- The filer writes `Owns: <path>, <path>` into each child body from the spec's `owns` field, after the footer. `bin/decompose-lint.sh` logs `DECOMPOSE_LINT owns-overlap <path> <A> <B>` to the split's `pipeline.log` when two children own the same path and the later one has no hard link to the earlier one. It is a warning, not a gate.
- `bin/hub-module-warn.sh` logs `HUB_MODULE <file> <n> tickets (<keys>)` to `logs/<project>.log` once a day per project, when 3 or more pre-planned tickets of the project plan an edit to one file that exists at HEAD. It is a signal to split the module, not a gate.
- The Verify list rule (a file the build only runs is not a planned path) is BH-6299, in `bin/planned-files.sh`.

## 16. Perf/cost tickets prove the outcome (BH-6372)
- A ticket is perf/cost when `bin/lib/perf-ticket.sh` (`pt_classify`) says so. The rules are data in `catalog/perf-ticket.tsv`: a label, a title or body phrase, or a `Target metric:` line in the body.
- The plan carries a `## Target metric` section with one line `Target metric: <metric-id> from <current number> to <target number> [<unit>]`. The id is lower-case `a-z0-9-`. The two numbers differ.
- The `## Acceptance tests` section has ONE item for an outcome replay over the last `OUTCOME_REPLAY_N` real inputs (default 50, knob in `catalog/lanes.d/_lib.perf-ticket.json`). The item reports the metric and the top miss reasons.
- The same item names a hit rate for every fallback or escalation path the change adds or keeps.
- The plan says that the PR body reports the result in an `## Outcome replay` section. That section starts with the same `Target metric:` line and a `measured: <number>` line.
- `bin/lib/perf-plan-rule.sh` puts this rule into the plan prompt (`pt_plan_rule`). The plan stage passes `PLAN_GATE_PERF=1` to `bin/plan-gate.sh` for a perf ticket. A plan with a `## Target metric` heading is checked too.
- `bin/plan-gate.sh` refuses a perf plan with a gap: one `UNTRACED: outcome replay — <gap>` line per gap and `PLAN_OUTCOME_REPLAY: missing`. Then the same repair pass runs, then PLAN_MALFORMED. `PLAN_GATE_ENFORCE=0` makes it a warning, like every plan-gate refusal.

## 17. Spec trace (BH-6485)
- A ticket BODY may carry three lines. `Spec: <path>#<section>` names a spec section the slice must deliver. `Reference: <path>` names a reference screenshot the UI must match. `Cut: <section or requirement id>` names a part the slice does not deliver. Each key is at the start of a line, optionally after a `- ` bullet and a backtick. Values split on commas. Lines in a code fence and lines in comments do not count. `bin/lib/spec-trace.sh` holds the one parser.
- When the body names a `Spec:` section, the plan carries a `## Spec trace` section with at least one line per section: `S<section>: <requirement> → <task / file>` (`->` also counts, and the `S` is optional). A `Spec:` line with no `#section` is keyed by its path. Each `Reference:` path appears under `## QA screens`, next to the screen that must match it.
- `bin/plan-gate.sh` refuses a plan without them (`UNTRACED: spec trace — <section>: <why>`, `PLAN_SPEC_TRACE: missing`, rc 2). The repair pass runs once, then PLAN_MALFORMED. `bin/plan-gate.sh` never scores `## Spec trace` lines as tasks.
- The general review gets each named section verbatim and writes one row per requirement, above its TIER and VERDICT lines: `SPEC-TRACE: <section> | <requirement> | <delivered|partial|missing|contradicts|cut> | <file:line or ->`. After the verdict, `st_enforce` turns an APPROVE into a BLOCK when a section has no row, a section cannot be read, or a `missing`, `contradicts` or `cut` row has no `Cut:` token that equals its section or is a whole word in its requirement. It writes `SPEC-TRACE-GATE: BLOCK — <reasons> (cut-exempt=<n>)` and `VERDICT: BLOCK`. Only the rows of the latest pass count, so a re-review re-emits them all.
- When the body has `Reference:` lines and the diff touches UI, preview QA saves light and dark shots at 1440 and 390 px to `qa-shots/ref/<slug>-<theme>-<width>.png`. `bin/reference-shots.sh` pushes them to the side branch `harness-shots/<key>-<yyyymmdd>` and writes the PR body's `## Reference screenshots` table (preview next to reference). The self-check row `body-reference-shots` refuses a body without the images.
- The knobs are in `catalog/lanes.d/_lib.spec-trace.json`: `SPEC_TRACE_ENFORCE` (default 1; 0 logs only), `SPEC_TRACE_SECTION_MAX_BYTES` (12000), `SPEC_TRACE_TOTAL_MAX_BYTES` (40000), `REFERENCE_SHOTS_KEEP_DAYS` (30), `REFERENCE_SHOTS_PRUNE` (dry), `REFERENCE_SHOTS_PRUNE_MAX` (20).
- A body with none of these lines changes nothing: no prompt text, no gate, no row.
