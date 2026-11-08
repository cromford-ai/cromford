# Archie may merge through bin/archie-merge.sh, under head-bound gates (BH-9212)

Doc: ARCHIE

## Why

the operator asked on 2026-11-07 for Archie to be able to merge. A CLEAN, approved
hotfix waited for him while the merge conductor showed READY and asked Mergify
nothing (#9188, #9197, #9202). The soul listed every merge under NEVER.

## What changed

- `prompts/archie-soul.d/10-authority.md`: a gated merge is MAY, only through
  `bin/archie-merge.sh`. NEVER names an ungated merge (`gh pr merge`, an admin
  merge, any merge outside the script). The other hard limits stay.
- `prompts/archie-soul.d/40-earned-autonomy.md`: `archie-merge` is its own
  class. One reverted merge runs `bin/archie-merge.sh reverted` and merges are
  ask-first again.
- `bin/archie-merge.sh <project> <owner/repo>#<n> <head40> --reason <text>`
  checks the gates on the exact head, in this order: `authority`,
  `kill-switch`, `no-mergify`, `lock`, `state`, `head-moved`, `mergeable`,
  `queued`, `hold`, `main-red`, `verdict`, `checks`, `iron-law`, `cap`. It
  then writes one `archie_actions` row (playbook `queue-enqueue`, evidence
  `source: archie-merge`, repo, pr, head, verdict_id, check_run_ids, reason)
  and only then posts `@mergifyio queue`. rc 0 QUEUED or ALREADY, 1 a missing
  lib or a failed send, 2 usage, 3 HOLD, 75 UNREADABLE.
- The settings row `archie.merge.authority` (`ask_first` | `merge`) is the
  on switch. The seed and the code fallback are `ask_first`. The worker puts
  `archie.merge.` under `PROTECTED_PREFIXES`: every PUT is signed, an unproven
  row is a 409 under sig enforce, and a bearer PUT of any value but
  `ask_first` is a 403. Only the human verdict token sets `merge`.
  `bin/lib/jobs/settings.sh` never answers the key from the box cache.
- Guardrail 1 in `rules/topics/01-iron-guardrails.md` names Archie's merge path.

## Operator steps

1. Replace the 2026-08-06 merge paragraph in `/root/orchestrator/CLAUDE.md`
   (hub only, not in this repo) with: "Merge authority: the one rule is
   `prompts/archie-soul.d/10-authority.md` (MAY merge through
   bin/archie-merge.sh under its gates; never by any other merge command).
   This file does not restate it."
2. To turn the authority on, run
   `bin/protected-setting.sh archie.merge.authority merge` on the operator's Mac.
3. To turn it off, any box may run
   `bin/jobs-client.sh setting-set archie.merge.authority ask_first`.
