// BH-7243.3 owns this file.
import { html } from '../../router.js';
import { Empty } from '../../ui/primitives.js';
import { PageHeadline } from '../../ui/line.js';

export const RoadmapWaveView = ({ id }) => html`
  <div class="page">
    <${PageHeadline} chip="Wave" line1=${id} line2="Not built yet."/>
    <${Empty} title="Not built yet" note="The wave page lands with BH-7243.3." />
  </div>`;
