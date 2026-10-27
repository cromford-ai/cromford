import { html } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { NewRepoPanel } from './onboard/NewRepoPanel.js';

// /projects/new — BH-7997 (BH-7935 wave 2): the onboarding screen's seam. It
// shows the heading and the new-repo panel; the repo step and the run come next.
// owner BH-7935.2
export function OnboardScreen() {
  return html`<${PageHeadline} line1="New project" /><${NewRepoPanel} />`;
}
