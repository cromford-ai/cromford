# Agent-architecture audit — the brief

You are auditing ONE repository and producing its architecture contract. This
brief is what a build session runs; the ticket that carries it into a project is
`docs/ARCH-AUDIT-TICKET.md`.

## What you are actually solving for

An agent working an under-specified task optimizes for what is in its context.
Given a choice it will:

- copy the nearest pattern it can see, whether or not that pattern is the
  supported one,
- edit the file that is already open rather than the file that should own the
  change,
- take the shortest path that compiles,
- leave code in place whose callers it cannot see, because deleting it looks
  risky from where it is standing,
- follow the instruction it was given even when obeying breaks an invariant
  nobody put in front of it.

Every one of those is the rational move given what the agent can see. So the
audit's target is not carelessness and the fix is not a politer prompt. The
target is the **gap between what is locally obvious in this repo and what is
globally correct in it**. You are looking for the places where the cheapest
visible move is the wrong one, and your output makes that move either
unnecessary (the supported path becomes cheaper) or impossible (it fails
mechanically, with an error naming the pattern that is supported).

## Discovery — the questions to answer against THIS repo

Read the code. These are questions about what is there, not about what would be
nice.

1. **What locally-obvious-but-wrong shortcut would an under-specified agent take
   here?** Walk the last few dozen merged PRs and the review comments on them:
   the shortcut that keeps being taken and keeps being caught by a human is the
   one to close. Name the shortcut, the file where it is tempting, and what the
   supported path is instead.
2. **Which durable values have more than one writer?** A durable value is
   anything that outlives a request: a persisted row or column, a cache entry, a
   file on disk, a config value, shared in-memory state. For each one, find
   every write site. More than one is the finding — record the value, its
   writers, and which of them should become the single owner.
3. **Which import directions must never happen?** Layer inversions, crossings of
   a process or trust boundary, cycles. State each as a direction (`A` must never
   import from `B`), not as a vibe about coupling, because a direction is
   checkable and a vibe is not.
4. **Which shared roots accumulate branches that should be isolated files?**
   Find the entry points, switches, dispatchers, and common helpers that grow an
   `if`/`case`/flag every time a feature is added. Adding a branch there is the
   smallest possible diff, which is exactly why it keeps happening. Record what
   the isolated-file form would be and where a new unit gets registered.
5. **Which existing conventions live only as prose?** Sweep `CLAUDE.md`, the
   README, contributing docs, and recurring review comments for rules that are
   stated and never enforced. Each one is either promotable to a check or is
   honest debt — and it must end up marked as one of those two things, never
   left ambiguous.
6. **Which files collide, and why?** Measure first:
   `bin/conflict-hotspots.sh -C <repo> --ref origin/main > hotspots.tsv` (it
   needs full history; on rc 3 run `git fetch --unshallow origin` and retry, and
   if that is impossible say "hotspots unmeasured" in the contract). Then run
   `bin/arch-conflict-scan.sh -C <repo> --hotspots hotspots.tsv` from
   cromford (on a box, `/root/harness/bin/`). It finds append-only
   registries, giant files, hand-kept lists of other files, and generated files
   that are committed, and proposes one structural fix for each: fragments, a
   module map, or generation.

## Required output

A PR on the target repo containing:

1. **`AGENT_ARCHITECTURE.md` at the repository root**, following
   `docs/AGENT-ARCHITECTURE-TEMPLATE.md` in cromford: the five-rule
   contract, the repo's own named nouns, and the mechanical-backing table with
   every unenforced rule marked `PROSE-ONLY (debt)`.

   The filename, the location, and the markdown-heading style are load-bearing:
   `bin/verification-map.sh` reads exactly `<repo>/AGENT_ARCHITECTURE.md` and
   lists its sections by heading into the primer the PLAN stage reads. A
   contract named something else, or nested in `docs/`, or written with bold
   text where headings belong, reaches no planner and nothing reports that it
   did not.

2. **A proposed-checks list** — one entry per boundary check you are proposing,
   each with: what it observes, the tool that observes it, the threshold at
   which it fails, the CI step that would run it, and the violations that exist
   in the repo right now (with the plan for each: fix in the adoption PR, or
   explicit exclusion with a reason).

3. **The `## Conflict shape` section**, pasted into `AGENT_ARCHITECTURE.md`
   exactly as `bin/arch-conflict-scan.sh` printed it. Do not add rows or
   proposals it did not print; anything you judge a conflict risk beyond it goes
   under a separate `### Auditor notes` heading as judgment. Copy its
   `### Proposed tickets` list into the PR body as a list for a person or the
   orchestrator to file. **The audit never files these tickets and never
   applies them**: no `gh issue create`, no file moves, no new generators in
   this PR. A repo with no findings keeps the section with the scan's "No
   conflict-shape findings" line; it is evidence, not a gap to fill. Re-run the
   audit for a project once its measured hotspots cover at least a week.

## The objectivity test — every proposed check must pass it

A check may only be proposed for **blocking** CI if it has all three:

- a **measurable observation** — something a tool can see in the code or the
  diff, with no reading of intent;
- a **named tool** that performs the observation;
- an **explicit threshold** at which it fails.

Checks that pass, for calibration: `madge --circular` at zero tolerance; eslint
`no-restricted-imports` encoding a layer contract; a dependency-cruiser ruleset;
a grep-shaped step with a stated count. Each names a tool and a number.

Anything judgment-shaped — "this abstraction is premature", "this belongs
elsewhere", "the naming is inconsistent" — **fails the test and goes in the
contract prose, not into a check.** It is not less important; it is differently
enforced. A judgment call wired to a blocking gate produces false positives, and
a check that is wrong even occasionally is a check somebody disables the first
week, taking the rules that were right down with it.

The bar for a BLOCKING check is a near-zero false-positive rate on this repo's
real code, demonstrated — not assumed — by running the check over the current
tree and accounting for every hit.

**Exclusions are not free, or the bar launders itself.** A current-tree hit you
excluded rather than fixed counts AGAINST the false-positive rate unless it
carries a ticket to fix it. Otherwise any check can be made to look clean by
excluding everything it found, and the number that was supposed to measure
precision ends up measuring only how much was swept aside. A check whose
current-tree accounting is mostly exclusions fails the bar.

## Hard rules for the audit itself

- **The audit NEVER lands a check.** Its output is a proposal. Checks reach a
  repo the way every other guardrail does: a PR opened by
  `bin/guardrail-promote.sh` (Wave A promotion mechanics) on the target repo,
  reviewed, and merged by a person. This lane opens PRs; it does not merge them.
  A check that arrives without review has turned someone's CI red on the say-so
  of a draft, and that is how a whole guardrail pack gets deleted on a Friday.
- **Every check ships with the escape hatch, and it is the existing one.** Do
  not invent a second mechanism: source `guardrails/lib/escape-hatch.sh` for
  shell checks, and wrap non-shell steps in the same condition — the
  `skip-guardrail` label **plus** a written `Guardrail-Justification:` line,
  both required, neither sufficient on its own. Never wire
  `GUARDRAIL_JUSTIFICATION` to the raw PR body; that makes any body a
  justification, and `bin/guardrail-promote.sh` refuses the PR outright when it
  sees it.
- **A check lands green or it does not land.** The adoption PR fixes or
  explicitly excludes every existing violation. A check that arrives red is a
  check that gets commented out.
- **Prove it fires.** For each proposed check, show it firing on a seeded
  violation and silent on a clean file. A rule that matches nothing looks
  exactly like a repo with nothing to find, so "it ran quietly" is not evidence.
- **Say what you could not determine.** A boundary you suspect but cannot
  establish from the code goes in the contract as an open question, named. A
  confident-sounding invariant that turns out not to hold is worse than an
  admitted gap, because everything downstream is written as if it held.
- **Do not restructure the repo.** This audit describes and proposes. Moving
  files, extracting layers, or collapsing a writer into one owner are separate
  tickets that the contract's findings justify — they are not part of this PR.
  That includes the conflict section's proposals.

<!-- client-questions:begin (BH-9028) -->
## Client questions: recommend, give reasons, state the default (the operator, 2026-11-03)

This applies when this lane writes a question to a client on a board: a triage `needs_clarification` comment, a PLAN_BLOCKED close-out, or any other comment that asks the client something. A bare list of questions is never posted. Each question has four parts, in this order, one line each:

1. The question.
2. `Recommended: <the answer we recommend>`
3. 1 to 3 reasons, in plain words for a non-engineer, on one line.
4. The default for no reply, a line that starts `If we do not hear from you`. Example: "If we do not hear from you by <date>, we build the recommended option." Write a date only when a lane or a person on our side acts on that date. Otherwise write what happens, with no date.

The client can then answer with one word: "yes", or the other option.

A planner that stops on a question writes every question in ONE fenced block in plan.md. The fence opens with three backticks and `client-questions`, and holds a JSON array, one object per question:
`[{"question": "Which fee field does the rep edit?", "recommended": "The per-client fee field.", "reasons": ["It is the field the invoice reads."], "default": "we build it on the per-client fee field."}]`

On a `PLAN_BLOCKED` result, run `/root/harness/bin/client-questions.sh render <dir>/plan.md` and post its output as the questions. This overrides any "post the plan's open questions" line in this file. Exit 3 means the plan has no client-questions block: write the four parts yourself from plan.md. Any other non-zero exit means a question has no recommended answer, reasons or default: post no questions comment, and write one ALERTS.log line that names the ticket and the reason the script printed.

The De-AI voice and the direct-link rules still apply. Ticket status and the client-court skip do not change.
<!-- client-questions:end -->
