# Conductor holds hand themselves to mc_hold_comment (BH-3456, BH-3436.4)

Doc: MERGE-CONDUCTOR

BH-3456 is part 4 of #3436. It only adds CALLS to the BH-3452 contract
`mc_hold_comment <key> <head> <kind> <reason>` (`bin/lib/mc-hold-comment.sh`).
The contract still posts nothing. #3455 owns the body and the
`<repo#n>@<kind>` dedupe. Every call runs on every tick the hold stands, is
guarded by `command -v mc_hold_comment`, and cannot change its caller's return
code.

## The call sites and their kinds

| Where | Hold | Kind |
|---|---|---|
| `mc_ready_why` (bin/lib/mc/classify.sh), after the note write | `ticket-hold` | `ticket-hold` |
| same | `lead-held` | `lead` |
| bin/merge-conductor.sh dep gate, `pdg_hold` rc 0 | open declared dependency | `dep-hold` (reason names `$PDGOUT`) |
| bin/merge-conductor.sh, cleared lead PR on Mergify | label cannot pin the head | `lead-mergify` |
| bin/merge-conductor.sh, after the re-entry arm | `BLOCKED_HUMAN` + CI `green` + reviewed == head, WHY `tightened*` / `provenance*` / `iron-law*` | `tightened` / `provenance` / `iron-law` |
| `_ae_skip` (bin/lib/tier2-autoenqueue.sh) | gate `hold` (a hold label) | `hold-label` |
| same | gates `lead`, `ticket-hold`, `pr-hold`, `hotfix` | the gate word |

The `mc_ready_why` call carries `_MC_HC_IN=1`, so #3455's body can tell it
was reached from inside `mc_ready_why`.

## What stays silent, and why

- `merges-off` and `lead-unread` in `mc_ready_why`. Nobody needs to act on the
  PR, and an unread fence is an outage, not a hold.
- dep gate rc 2 (unreadable). A dependency nobody could read is not a hold
  someone can lift.
- Every other `_ae_skip` gate: `base`, `ledger`, `verdict`, `standing`,
  `asked`, `conductor`, `check`, `reread`, `mergeable`, `pr-hold-read`,
  `main-red`, `block-gate`, `recover`. `bg_refuse` already comments for the
  block gate.
- Other parks: `review-block`, `verdict-contradiction`, `red-twice`,
  `hotfix-migration-hold`, `queue-ejected-twice`. The three classifier kinds
  are also silent unless CI is green and the approval is bound to the current
  head.

## One gate word changed

The self-enqueue's lead gate used to refuse with the gate word `lead` for three
different fence answers. Now each answer has its own word:

- rc 0, a held lead PR, is still `lead`.
- rc 2, an unreadable fence, is now `lead-read`.
- rc 1 on a cleared lead PR is now `lead-cleared`.

Without the split, an unreadable fence would have commented as a lead hold,
and a cleared lead PR would have been told to wait for the MERGE it already
has. The refusal itself is unchanged. The `aeskip` attempts line and the
`AUTOENQUEUE … not enqueued` log line carry the new word.

In a full tick a held lead PR is asked twice, once by the READY arm's fence and
once by the self-enqueue's, because the fence sits after `ae_mark`. Both calls
are kind `lead`, so #3455's dedupe makes them one comment.

Pinned by `tests/conductor-hold-comment-sites.bh-3456-test.sh`.
