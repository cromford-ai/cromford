// The kanban's verdict badge (BH-9558): it says who decided.
//
// A lead or human BLOCK is "lead-blocked". A lead MERGE is "lead approved"
// ("lead approved, notes" with notes). A risk-tier MERGE (gate 60 signed a
// low-risk PR off; no lead read it) is "low-risk sign-off". A builder word keeps the label
// verdictLabel gives it. With no `verdictBy` (the overlay did not run), the
// badge is exactly today's.
import { verdictLabel } from './stages.js';

const LEAD_LABEL = { MERGE: 'lead approved', 'MERGE-WITH-NOTES': 'lead approved, notes' };
const RISK_LABEL = { MERGE: 'low-risk sign-off', 'MERGE-WITH-NOTES': 'low-risk sign-off, notes' };
const GREEN = new Set(['APPROVE', 'MERGE', 'MERGE-WITH-NOTES']);

export function verdictBadge({ verdict, verdictBy = null, verdictState = null } = {}) {
  const word = String(verdict || '').toUpperCase();
  const cls = GREEN.has(word) ? 'tag tag--green' : 'tag tag--warn';
  const title = verdictBy ? `${verdict} by ${verdictBy}` : String(verdict);
  let text;
  if (verdictState === 'lead_blocked') text = 'lead-blocked';
  else if (verdictBy === 'risk-tier' && RISK_LABEL[word]) text = RISK_LABEL[word];
  else if (LEAD_LABEL[word]) text = LEAD_LABEL[word];
  else text = verdictLabel(verdict);
  return { cls, text, title };
}
