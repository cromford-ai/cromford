// BH-7243.2 owns this file.
import { html } from '../../router.js';
import { Empty } from '../../ui/primitives.js';
import { PageHeadline } from '../../ui/line.js';

export const RoadmapBoardView = ({ project }) => html`
  <div class="page">
    <${PageHeadline} chip="Roadmap" line1=${project} line2="Not built yet."/>
    <${Empty} title="Not built yet" note="The roadmap board lands with BH-7243.2." />
  </div>`;
