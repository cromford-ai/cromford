// The Ready screen's nine cards (BH-8744, BH-7935.3), pure. The input is the
// worker's GET /api/onboarding/ready/<project> answer
// (worker/jobs/src/routes/onboarding-ready.js):
//   {project, repo, prod, box, tailnet, account, fly,
//    facts:{state: pending|fail|stale|pass, vercel?, qa_account?, migration_token?}}
//
// "connected" comes only from a stored row (prod, the routing row, the registry
// box with a tailnet IP) or a fresh `pass` ready-facts row whose key is true.
// Alerts and Tracker have no stored source yet, so they never say connected.

const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const CONFIG = { kind: 'link', href: '/config' };

// The tag of a card whose source is a ready-facts key.
function factsTag(facts, key) {
  const state = facts && facts.state;
  if (state === 'pass') {
    if (facts[key] === true) return 'connected';
    if (facts[key] === false) return 'not set';
    return 'unknown';
  }
  if (state === 'fail') return 'unknown';
  if (state === 'stale') return 'stale';
  return 'checking';
}

function prodTag(prod) {
  if (prod == null || prod === '' || prod === '-') return 'not set';
  return /^https:\/\/\S+$/.test(prod) ? 'connected' : 'unknown';
}

function boxTag(box, tailnet) {
  if (box == null || box === '') return 'shared box';
  return tailnet === true ? 'connected' : 'not set';
}

function accountTag(account) {
  const v = account == null ? '' : String(account).trim();
  return v === '' || v === 'shared' ? 'fleet pool' : v;
}

// The tone class of a tag (styles.css .tag--*).
export function tagTone(tag) {
  if (tag === 'connected') return 'green';
  if (tag === 'not set' || tag === 'stale') return 'warn';
  if (tag === 'unknown') return 'bad';
  if (tag === 'checking' || tag === 'not checked') return 'idle';
  return 'plain';
}

const CARDS = [
  ['prod', 'Production URL', 'Without it, nothing checks that a merge reached production.', (s) => prodTag(s.prod)],
  ['vercel', 'Preview QA', 'Without it, nothing opens a preview build before a merge.', (s) => factsTag(s.facts, 'vercel')],
  ['qa', 'QA test account', 'Without it, QA sees only the screens a guest can see.', (s) => factsTag(s.facts, 'qa_account')],
  ['fly', 'Fly builder pool', 'Without it, builds wait for a slot on the shared box.', (s) => (s.fly === true ? 'connected' : 'not set')],
  ['box', 'Dedicated box and Tailscale', 'Without it, this project shares a box and its build slots.', (s) => boxTag(s.box, s.tailnet)],
  ['alerts', 'Alerts', 'Without it, alerts go to the fleet channel, not to you.', () => 'fleet default'],
  ['migrations', 'Migrations', 'Without it, a schema change waits for a person to apply it.', (s) => factsTag(s.facts, 'migration_token')],
  ['tracker', 'Tracker', 'Without it, only GitHub Issues labelled ai-build start a build.', () => 'not checked'],
  ['account', 'AI account', 'Without it, this project bills the fleet pool.', (s) => accountTag(s.account)],
];

export const READY_CARD_IDS = CARDS.map((c) => c[0]);

// Nine {id, title, tag, tone, sentence, action} rows, in the spec order.
export function readyCards(state) {
  const s = state && typeof state === 'object' ? state : {};
  return CARDS.map(([id, title, sentence, tagOf]) => {
    const tag = tagOf(s);
    return { id, title, tag, tone: tagTone(tag), sentence, action: id === 'account' ? { kind: 'sheet' } : CONFIG };
  });
}

// The two headline actions. `ticket` is null when the repo is not owner/name.
export function readyActions(project, repo) {
  return {
    ticket: REPO_RE.test(String(repo ?? '')) ? `https://github.com/${repo}/issues/new` : null,
    project: `/p/${encodeURIComponent(project)}`,
  };
}
