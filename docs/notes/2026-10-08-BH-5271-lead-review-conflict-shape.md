# The lead review checks conflict shape, and its prompt carries the project's hotspots (BH-5271)

Doc: LEAD-REVIEW

## What changed

- `prompts/lead-review-checklist.md` is now `Checklist-Version: 2`. Item 9,
  "Conflict shape", is new. Every lead report written from now on says
  `- checklist: v2`. A v1 report on disk still replays unchanged.
- `bin/lead-review.sh` puts a `## Conflict hotspots` section in the review
  prompt, after `## Host suite` and before `## Diff`. The section is the
  output of `hc_section <project>` from `bin/lib/hotspot-context.sh` (BH-5269),
  for the request's fleet project. It is the same text the plan primer shows.
- `catalog/context-budgets.json` names the section as a `lead-review` lane
  component.

## Item 9, as the reviewer reads it

- `[NOTE]`: the PR adds a new append-only shared list, or grows a listed
  hotspot file, when a fragment directory, an `entries/` directory, a
  generator or a module for that concern already exists.
- `[BLOCK]`: only when the same PR ALSO adds a per-ticket changelog comment to
  a file header, or a hand-written `bin/lib` list in a test instead of
  `scratch_install_closure`. A changelog header or a lib list with no shared
  list and no hotspot growth is not a conflict-shape BLOCK. This is the
  literal reading of the ticket's "also".
- Not conflict shape: a rationale comment next to its code, a `## Changes`
  line with a version bump in a versioned prompt, a dated note under
  `docs/notes/`, a new file in a fragment directory.
- ABSENT or COULD NOT READ in the section is not "no hotspots". The reviewer
  judges shared lists from the diff alone.

## Knob and failure states

- Row count: the existing `PLAN_CONTEXT_HOTSPOT_TOP` knob
  (`lib.plan-context-hotspots[.<project>]`, default 10, max 50, 0 = off). The
  plan primer and the lead review read the same list. There is no new knob.
- Never measured: `ABSENT: no conflict_hotspots measurement ...`.
- Knob 0: `ABSENT: hotspot section off ...`, and no request is made.
- Worker outage or a bad answer: `COULD NOT READ: ...`. The review runs.
- `bin/lib/hotspot-context.sh` not on the box: one log line, and the section
  says the lib is not loaded. The review runs.
- `logs/lead-review.log` gets one line per review:
  `<key>: conflict hotspots <yes|none|never|off|unknown>`.
- The read is one worker GET with fd 7 (the tick lock) closed.

## Proof

- `tests/lead-review-context-hotspots.bh-5271-test.sh` drives the real tick:
  rows, project and limit, never measured, outage, lib missing, knob 0, and the
  BH-3546 section order.
- `tests/lead-checklist-conflict-eval.bh-5271-test.sh` with the fixtures in
  `tests/fixtures/lead-checklist-conflict.bh-5271/`. Free mode (CI) checks the
  composed prompt for each case. Live mode is opt-in and metered: set
  `LEAD_CHECKLIST_EVAL_MODEL=<model>` and the suite grades the real model's
  NOTE / BLOCK / NONE per `expected.txt`.
