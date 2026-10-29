// The /roadmap screens (BH-7243). Each one only renders its view from
// screens/roadmap/, which the BH-7243 children own.
import { html, Link, useSearchParam } from '../router.js';
import { RoadmapIndexView, RoadmapListView, RoadmapIdeaView } from './roadmap/list-view.js';
import { RoadmapBoardView } from './roadmap/board-view.js';
import { RoadmapWaveView } from './roadmap/wave-view.js';
import { RoadmapBriefView } from './roadmap/brief-view.js';
import { WaveActions } from './roadmap/wave-actions.js';

export const RoadmapIndexScreen = () => html`<${RoadmapIndexView} />`;

export function RoadmapScreen({ project }) {
  const view = useSearchParam('view');
  if (view === 'board') return html`<${RoadmapBoardView} project=${project} />`;
  if (view === 'brief') return html`<${RoadmapBriefView} project=${project} />`;
  return html`<${BriefLink} project=${project} /><${RoadmapListView} project=${project} />`;
}

// BH-7261: the one line above the list view that opens the weekly brief. The
// `page` class gives it the list view's side padding at every width.
const BriefLink = ({ project }) => html`
  <div class="page" style="flex-grow:0;padding-bottom:0"><${Link} to=${`/roadmap/${encodeURIComponent(project)}?view=brief`} class="btn btn--sm" data-testid="roadmap-brief-link">WEEKLY BRIEF<//></div>`;

export const RoadmapIdeaScreen = ({ project, id }) => html`<${RoadmapIdeaView} project=${project} id=${id} />`;
export const RoadmapWaveScreen = ({ project, id }) => html`
  <${RoadmapWaveView} project=${project} id=${id} />
  <${WaveActions} project=${project} wave=${{ id }} />`;
