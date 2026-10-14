# AGENT-ARCHITECTURE AUDIT TICKET (draft — NOT filed)

The ready-to-file `ai-build` body that puts an architecture contract into a repo
that does not have one. The harness never writes `AGENT_ARCHITECTURE.md` itself:
a contract assembled by a script that never read the code describes the
directory tree, not the invariants, and an invariant that is not true is worse
than none because everything downstream is written as if it held.

Same body serves both paths:

- **new projects** — `bin/load-project.sh <owner/repo> --arch-ticket` files it
  automatically at onboarding (it substitutes `<PROJECT>` and `<REPO_SLUG>`),
- **existing projects** — file it by hand:

```bash
gh issue create -R <owner/repo> \
  --title "agent architecture: audit the repo and draft AGENT_ARCHITECTURE.md" \
  --label ai-build --body-file docs/ARCH-AUDIT-TICKET.md
```

Everything below the line is the issue body.

---

## Scope

This repo has no `AGENT_ARCHITECTURE.md`. Run the agent-architecture audit
against it and produce one.

The audit brief is `prompts/arch-audit.md` in cromford — read it in full
before starting; it carries the discovery questions, the objectivity test every
proposed check must pass, and the rules the audit itself runs under. The output
shape is `docs/AGENT-ARCHITECTURE-TEMPLATE.md`.

**Why this exists.** An agent working an under-specified task optimizes for what
is in its context: it copies the nearest pattern, edits the file already open,
takes the shortest path that compiles, and follows an instruction even when
obeying breaks an invariant nobody put in front of it. Those are rational moves
given what it can see. The contract's job is to make the locally-obvious change
the globally-correct one here, and to make the unsafe shortcut fail mechanically
with an error naming the supported pattern.

Deliverable — a PR adding:

- **`AGENT_ARCHITECTURE.md` at the repository root** (that exact name, that
  exact location, markdown headings). `bin/verification-map.sh` reads that path
  and lists its sections into the primer the harness PLAN stage consults, so a
  contract filed anywhere else or written with bold text where headings belong
  reaches no planner and nothing reports that it did not.
- **A proposed-checks list in the PR body** — one entry per mechanical boundary
  check the audit proposes, each naming what it observes, the tool, the failure
  threshold, the CI step, and every violation currently in the tree with its
  disposition (fix in the adoption PR, or excluded with a reason).
- **the `## Conflict shape` section from `bin/arch-conflict-scan.sh`** in
  `AGENT_ARCHITECTURE.md`, and its proposed tickets listed in the PR body.

## How to build it (the part that decides whether this is worth anything)

1. **Answer the five discovery questions against this repo's code**, not against
   general good practice: the shortcut an under-specified agent would take here;
   the durable values with more than one writer; the import directions that must
   never happen; the shared roots that accumulate branches instead of gaining
   isolated files; the conventions that exist only as prose.
2. **Use the history.** The last few dozen merged PRs and their review comments
   are the record of which mistake keeps being made and keeps being caught by a
   human. That recurring comment is the contract's first rule.
3. **Fill in the named nouns.** The rules are only obeyable once they name this
   repo's real Feature/Entrypoint/boundary equivalents. A contract written in the
   abstract is one every reader skims.
4. **Mark debt as debt.** Every rule with no check behind it is written
   `PROSE-ONLY (debt)` in the mechanical-backing table. Describing prose as if it
   enforced something is the failure this whole contract exists to end.

## Acceptance tests

In this repo's own framework (see its `CLAUDE.md` verification contract; if it
has none, say so in the PR and provide a manual checklist instead):

- a test asserting `AGENT_ARCHITECTURE.md` exists at the repo root and carries
  all five rule sections plus a mechanical-backing row for each — a contract
  with a rule deleted, or with a backing row missing, must FAIL it;
- a test asserting the mechanical-backing table's "enforced by" column is either
  a check that exists in this repo (the named CI step / config is present) or
  the literal `PROSE-ONLY (debt)` — a row naming a check that does not exist
  must FAIL it, because that row is the exact lie the table is here to prevent;
- for each check the audit proposes: a seeded fixture pair in the proposal
  proving it fires on a violation and stays silent on a clean file — adoption
  and its CI tests happen in the later guardrail-promotion PR, never this one.
  A rule that matches nothing looks exactly like a repo with nothing to find.

Red before green: write these first against the absent contract and record the
failing output. A test that passes before the contract exists is testing nothing.

## Escape hatch (required on anything that blocks)

Any check adopted in the promotion PR uses the ONE shared hatch, never a new
mechanism: the
`skip-guardrail` PR label **plus** a written `Guardrail-Justification:` line of
real reasoning in the PR body — both required, neither sufficient alone. Shell
checks source `guardrails/lib/escape-hatch.sh`; other steps wrap the same
condition. Never wire `GUARDRAIL_JUSTIFICATION` to the raw PR body: that makes
any body a justification, and `bin/guardrail-promote.sh` refuses such a draft.

## QA screens

None — this ticket adds documentation only; no CI configuration lands from it.
The proof
is the contract itself: the PR body names, for at least two rules, the real
merged PR or review comment that made that rule necessary in this repo.

## Out of scope

- **Landing any mechanical check from this ticket's PR.** The audit proposes; checks
  reach CI through the normal guardrail promotion path (a PR on this repo,
  reviewed and merged by a person). Do not merge a check as part of this
  ticket's own work, and do not enable one that lands red.
- **Restructuring the code.** Moving files, extracting a layer, or collapsing
  two writers into one owner are separate tickets that this contract's findings
  justify. File them and link them here.
- **Filing or applying the proposed structural tickets.** The conflict
  section's proposals are listed in the PR body for a person or the
  orchestrator to file.
- **Writing rules for a future architecture.** The contract describes the
  invariants this repo has or must have now, not the ones it should grow into.
