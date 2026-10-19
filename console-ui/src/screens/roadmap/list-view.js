// BH-7243.1 owns this file.
import { html } from '../../router.js';
import { Empty } from '../../ui/primitives.js';
import { PageHeadline } from '../../ui/line.js';

export const RoadmapIndexView = () => html`
  <div class="page">
    <${PageHeadline} chip="Roadmap" line1="Roadmaps" line2="Not built yet."/>
    <${Empty} title="Not built yet" note="The roadmap index lands with BH-7243.1." />
  </div>`;
export const RoadmapListView = ({ project }) => html`
  <div class="page">
    <${PageHeadline} chip="Roadmap" line1=${project} line2="Not built yet."/>
    <${Empty} title="Not built yet" note="The roadmap list lands with BH-7243.1." />
  </div>`;
export const RoadmapIdeaView = ({ id }) => html`
  <div class="page">
    <${PageHeadline} chip="Idea" line1=${id} line2="Not built yet."/>
    <${Empty} title="Not built yet" note="The idea page lands with BH-7243.1." />
  </div>`;
