## User flows (BH-8029)

USER FLOWS (iron law, BH-8029, 2026-10-22). A new feature ties into the user flows that exist. Users reach it through the screens, menus, pickers and builders they already use, not only through its new route.
1. PLAN lists each existing entry point the feature touches: navigation, builders and their pickers (workflow step and trigger pickers, the agent builder), the in-app AI (assistant, agent interview, builder chat, brain or catalog text the model reads), Connect and setup flows, and existing lists and details.
2. For each entry point the feature does not touch, the plan says "no change, because <reason>".
3. TEST: at least one acceptance test reaches the feature from an existing entry point, not only from its new route.
4. The rule applies to UI-bearing projects (OS apps). A backend-only or harness-only change writes "no user-facing entry point" in the plan.
- PLAN must carry a `## Entry points` section: one line per entry point (touched, or "no change, because ..."), or the single line "no user-facing entry point".
- REVIEW checks the plan's entry points against the diff. A user-facing feature that a user cannot reach from an existing entry point is `[BLOCK user-flows]`. A missing "no change, because" line, or no entry-point test on a feature a user can reach, is a `[NOTE]`.
