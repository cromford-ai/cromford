// core.d/bh-9447-unblock-silence.js — BH-9447: the unblock_decisions columns of
// the silence default (a safe recommended lever runs when nobody answers).
//   silence_claimed_at  when bin/lib/unblock/silence.sh claimed the card for a
//                       silence run, BEFORE ub_act (one attempt per card, ever)
//   silence_lever       the lever it claimed for (lead_rerequest, requeue, ...)
//   silence_outcome     claimed, then ub_act's outcome: done | failed | refused | would
//   silence_detail      ub_act's detail (at most 500 chars)
// idx_unblock_decisions_silence serves the day-cap count of the claim
// (routes/unblock-silence.js SILENCE_CLAIM_SQL). It is partial, so it holds
// only the silence rows; test/unblock-silence.bh-9447.test.js S6 EXPLAINs it.
export const ADDED_COLUMNS = {
  unblock_decisions: [
    ["silence_claimed_at", "TEXT"], ["silence_lever", "TEXT"], ["silence_outcome", "TEXT"], ["silence_detail", "TEXT"],
  ],
};
export const ADDED_INDEXES = {
  unblock_decisions: [
    "CREATE INDEX IF NOT EXISTS idx_unblock_decisions_silence ON unblock_decisions(project, silence_claimed_at) WHERE silence_claimed_at IS NOT NULL",
  ],
};
