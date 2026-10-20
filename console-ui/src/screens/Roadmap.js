// The /roadmap screens (BH-7243). Each one only renders its view from
// screens/roadmap/, which the BH-7243 children own.
import { html, useSearchParam } from '../router.js';
import { RoadmapIndexView, RoadmapListView, RoadmapIdeaView } from './roadmap/list-view.js';
import { RoadmapBoardView } from './roadmap/board-view.js';
import { RoadmapWaveView } from './roadmap/wave-view.js';
import { WaveActions } from './roadmap/wave-actions.js';

export const RoadmapIndexScreen = () => html`<${RoadmapIndexView} />`;

export function RoadmapScreen({ project }) {
  const view = useSearchParam('view');
  return view === 'board'
    ? html`<${RoadmapBoardView} project=${project} />`
    : html`<${RoadmapListView} project=${project} />`;
}

export const RoadmapIdeaScreen = ({ project, id }) => html`<${RoadmapIdeaView} project=${project} id=${id} />`;
export const RoadmapWaveScreen = ({ project, id }) => html`
  <${RoadmapWaveView} project=${project} id=${id} />
  <${WaveActions} project=${project} wave=${{ id }} />`;
