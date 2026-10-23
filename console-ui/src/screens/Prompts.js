import { html, Link, navigate, useSearchParam } from '../router.js';
import { useApi } from '../lib/hooks.js';
import { Skeleton, ErrorBox } from '../ui/primitives.js';
import { PageHeadline } from '../ui/line.js';
import { SortableTable } from '../ui/SortableTable.js';
import { PromptEditor } from '../ui/PromptEditor.js';
import { whenLabel } from '../lib/format.js';
import { PROMPT_KINDS, SOURCE_LABEL, listPrompts, listHref, editorHref } from '../lib/prompts.js';

// Settings · Fleet · Prompts and Settings · <project> · Prompts (BH-7940.5).
// The settings shell mounts this page for the `prompts` row of either scope.
// No ?kind= (or a kind that is not one of the seven): the list. A known kind:
// the editor, on the same page, with a link back to the list.

export function PromptsScreen({ scope = 'fleet', project }) {
  const kind = useSearchParam('kind');
  if (kind && PROMPT_KINDS.includes(kind)) {
    return html`
      <div class="page">
        <div><${Link} to=${listHref(scope, project)} class="btn btn--sm">← ALL PROMPTS<//></div>
        <${PromptEditor} key=${`${scope}/${project || ''}/${kind}`} scope=${scope} project=${project} kind=${kind}
          onSaved=${() => navigate(listHref(scope, project))}/>
      </div>`;
  }
  return html`<${PromptsList} scope=${scope} project=${project}/>`;
}

// One read per mount, no poll.
function PromptsList({ scope, project }) {
  const list = useApi(() => listPrompts(scope === 'project' ? project : ''), [scope, project]);
  return html`<${PromptsListView} scope=${scope} project=${project} list=${list}/>`;
}

const columns = (scope, project) => [
  {
    key: 'kind', label: 'KIND', sort: (r) => PROMPT_KINDS.indexOf(r.kind),
    cell: (r) => html`<${Link} to=${editorHref(scope, project, r.kind)} class="cell-name">${r.kind}<//>`
  },
  { key: 'source', label: 'SOURCE', sort: (r) => SOURCE_LABEL[r.source] || r.source, cell: (r) => SOURCE_LABEL[r.source] || r.source },
  { key: 'version', label: 'VERSION', cell: (r) => (r.version === null ? '—' : String(r.version)) },
  { key: 'author', label: 'AUTHOR', cell: (r) => r.author || '—' },
  { key: 'set_at', label: 'TIME', cell: (r) => (r.set_at ? html`<span title=${r.set_at}>${whenLabel(r.set_at)}</span>` : '—') }
];

// The render half: `list` is the useApi state of the one GET /api/prompts.
export function PromptsListView({ scope, project, list }) {
  const where = scope === 'project' ? project : 'the fleet';
  let body;
  if (list.error && !list.data) body = html`<${ErrorBox} error=${list.error} onRetry=${list.reload}/>`;
  else if (!list.data) body = html`<${Skeleton} rows=${PROMPT_KINDS.length} height=${18}/>`;
  else body = html`<${SortableTable} columns=${columns(scope, project)} rows=${list.data} rowKey=${(r) => r.kind}/>`;
  return html`
    <div class="page">
      <${PageHeadline} chip="Settings" line1="Prompts." line2=${`The seven prompt kinds for ${where}. Open one to edit it.`}/>
      ${body}
    </div>`;
}
