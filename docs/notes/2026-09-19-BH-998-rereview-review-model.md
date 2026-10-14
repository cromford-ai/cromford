# BH-998 — the conductor's head-bound re-review resolves its review model

Doc: MERGE-CONDUCTOR

`mc_rereview` in `bin/lib/merge-conductor-lib.sh` passed `claude-fable-5-1` to
`bin/agent-call.sh review` as a literal, so a box that set `REVIEW_MODEL` in
`env/global.env` still bought the hardcoded model for every HEAD_MOVED re-review —
the only review call in the fleet that ignored the operator's setting, against
rules/CLAUDE.md "AI model config".

What changed: a new `bin/lib/review-model.sh` exposes `review_model [harness]`,
which resolves `REVIEW_MODEL` from the environment first, then the `REVIEW_MODEL=`
line of the harness `env/global.env` (read, never sourced), then one documented
fallback constant — `claude-fable-5-1`, the value the line already had, so a box
that configures nothing behaves exactly as before. `mc_rereview` now calls
`"$(review_model "$MC_H")"`. Nothing else about the call moved: same stage, same
project, same 1200s timeout, same prompt, same sidecar handling and dedup key.

Command/state touched: none new. The edit point for operators is `REVIEW_MODEL` in
`env/global.env`, which the conductor tick and `bin/blocked-resolver.sh` already
`set -a` source.

The BH-680 split (#929) landed `bin/lib/mc/rebase.sh` on main while this was in
flight, and it carries a verbatim copy of `mc_rereview`. The same resolution is
applied there, so the two bodies stay byte-identical and the ticket's grep is empty
in both files. The copy runs in the lib's own process, which sources
`bin/lib/review-model.sh`, so the module needs no source line of its own — adding
one would make it define a function the split's module map does not assign it.

BH-1019 (#1074) wrapped the same statement in
`AGENT_CALL_RUNNERS="${MC_RR_RUNNERS-claude}"`. That is untouched: the RUNNER stays
claude-only, only the MODEL moves off the literal.

Not in scope: the other `claude-fable-5-1` literals in `bin/*.sh` — they already
honour `REVIEW_MODEL` inline.
