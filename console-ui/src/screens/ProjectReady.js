import { html } from '../router.js';
import { PageHeadline } from '../ui/line.js';

// /projects/:project/ready — BH-7997 (BH-7935 wave 2): the "project is ready"
// screen's seam. It shows the heading only.
// owner BH-7935.3
export function ProjectReadyScreen({ project }) {
  return html`<${PageHeadline} line1=${`Ready: ${project}`} />`;
}
