// core.d/bh-8817-unblock-cards.js — BH-8817 (C0): the unblock_decisions columns
// that route a Tackler card to Archie first and page the operator once.
//   answer_source      'archie' when Archie answered (hold | none | acted); NULL = a person
//   archie_lever       the lever Archie pulled through bin/lib/unblock/act.sh
//                      when the answer is acted (requeue, fix_round, ...); else NULL
//   routed_to          'operator' once Archie (needs-operator) or Tackler's timeout sweep
//                      hands the card to the operator; NULL = still Archie's
//   routed_at          when routed_to was set
//   route_reason       "<by>: <reason>" (by = archie | timeout)
//   paged_at           when Tackler's sweep paged the operator for this card (page once)
//   archie_claimed_at  Archie's claim before its model call (dedup before spend)
// No new index: every read is by rowid, or through idx_unblock_decisions_created
// (GET /api/unblock/cards/daily and /cards/repeats) and
// idx_unblock_decisions_outcome_project (the list), test/unblock-cards.bh-8817.test.js W6.
export const ADDED_COLUMNS = {
  unblock_decisions: [
    ["answer_source", "TEXT"], ["routed_to", "TEXT"], ["routed_at", "TEXT"],
    ["route_reason", "TEXT"], ["paged_at", "TEXT"], ["archie_claimed_at", "TEXT"],
    ["archie_lever", "TEXT"],
  ],
};
