import { html } from '../router.js';
import { agoFromMinutes } from '../lib/format.js';

// The WAITING FOR CLIENT APPROVAL tag (BH-9901), fed an approvalOf() result.
// Nothing renders unless the hub row says waiting. The ticket link is only an
// https URL the row carried; with none, the ticket id is plain text.
export const ClientApprovalTag = ({ approval }) => {
  if (!approval || approval.waiting !== true) return null;
  const id = approval.ticketId || 'unknown';
  return html`<span class="client-approval" style="display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap;min-width:0">
    <span class="tag tag--warn" title=${`Waiting for the client to approve on the board since ${approval.since}`}>
      WAITING FOR CLIENT APPROVAL · ${agoFromMinutes(approval.ageMin)}
    </span>
    ${approval.ticketUrl
      ? html`<a href=${approval.ticketUrl} target="_blank" rel="noopener noreferrer">ticket ${id} ↗</a>`
      : html`<span>ticket ${id}</span>`}
  </span>`;
};
