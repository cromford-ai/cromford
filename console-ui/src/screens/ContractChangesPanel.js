import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { prNumberFromUrl, whenLabel } from '../lib/format.js';

// The CONTRACT CHANGES section on /p/<project> (BH-9929): one row per step PR
// of the contract-change lane (expand, migrate, contract), from GET
// /api/contract-changes (worker/jobs/src/routes/contract-changes.js). One read,
// no limit in the request: the worker returns at most the settings row
// lib.contract-change.contract_changes_list_max, newest first. Read-only.
// The Ticket cell links to the parent issue in the repo the step PR is in;
// a row with no PR URL has no known repo, so its ticket is plain text.

const REPO_FROM_PR = /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/\d+(?:[/?#].*)?$/;
const dash = (v) => (v === null || v === undefined || v === '' ? html`<span class="na">—</span>` : v);

export function issueHref(row) {
  const m = typeof row.pr_url === 'string' ? REPO_FROM_PR.exec(row.pr_url) : null;
  const n = Number(row.parent_ticket);
  return m && Number.isInteger(n) && n > 0 ? `https://github.com/${m[1]}/issues/${n}` : null;
}

export default function ContractChangesPanel({ project }) {
  const read = useApi(() => api.contractChanges(project), [project]);
  if (!read.data && !read.error) return html`<${Skeleton} rows=${3} height=${18}/>`;
  // A failed read, or a body without its rows array, is an error, never the
  // empty state.
  const rows = read.data && read.data.rows;
  if (read.error || !Array.isArray(rows)) {
    return html`<${ErrorBox} error=${read.error || new Error('no rows in the answer')} onRetry=${read.reload}/>`;
  }
  if (!rows.length) return html`<${Empty} title="No contract changes on this project."/>`;

  const columns = [
    { key: 'parent_ticket', label: 'TICKET', sort: (r) => Number(r.parent_ticket), cell: (r) => {
      const href = issueHref(r);
      return href
        ? html`<a class="mono" href=${href} target="_blank" rel="noopener noreferrer">#${r.parent_ticket}</a>`
        : html`<span class="mono">#${r.parent_ticket}</span>`;
    } },
    { key: 'step', label: 'STEP', cell: (r) => r.step },
    { key: 'pr_url', label: 'PR', sort: (r) => prNumberFromUrl(r.pr_url), cell: (r) => {
      if (!r.pr_url) return dash(null);
      // Only an https URL becomes a link; anything else is shown as text.
      if (!/^https:\/\//.test(r.pr_url)) return html`<span class="mono cell-wrap">${r.pr_url}</span>`;
      const n = prNumberFromUrl(r.pr_url);
      return html`<a class="mono" href=${r.pr_url} target="_blank" rel="noopener noreferrer">${n !== null ? `#${n}` : 'PR'}</a>`;
    } },
    { key: 'backup_ref', label: 'BACKUP', cell: (r) => (r.backup_ref ? html`<span class="mono cell-wrap">${r.backup_ref}</span>` : dash(null)) },
    { key: 'restore_ref', label: 'RESTORE', cell: (r) => (r.restore_ref ? html`<span class="mono cell-wrap">${r.restore_ref}</span>` : dash(null)) },
    // The worker answers the step PR's live verdict (lead or human, from the
    // verdicts table) and names its source; `recorded` is the stored value.
    { key: 'verdict', label: 'VERDICT', sort: (r) => r.verdict || 'pending', cell: (r) => (r.verdict
      ? html`<span title=${r.verdict_head ? `on ${String(r.verdict_head).slice(0, 12)}` : ''}>${r.verdict}${r.verdict_source && r.verdict_source !== 'recorded' ? html` <span class="na">(${r.verdict_source})</span>` : ''}</span>`
      : html`<span class="na">pending</span>`) },
    { key: 'approved_by', label: 'APPROVED BY', cell: (r) => dash(r.approved_by) },
    { key: 'updated_at', label: 'UPDATED', cell: (r) => html`<span title=${r.updated_at || ''}>${whenLabel(r.updated_at)}</span>` },
  ];
  return html`
    <div class="contract-changes" style="overflow-x:auto;max-width:100%">
      <${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => `${r.parent_ticket}-${r.step}`}
        defaultSort="updated_at" defaultDir="desc"/>
    </div>`;
}
