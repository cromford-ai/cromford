// The "create a new repo" panel of /projects/new (BH-8001, BH-7935.4).
// Onboard.js mounts it on the New repo segment with the form's owner, name and
// template. Create repo asks in an in-app modal, files one keyed POST
// /api/coord/onboarding/repo-create, then polls GET
// /api/onboarding/repo-create/<probe_id> until the hub-probe lane answers. On
// ok it hands the slug to onCreated, which fills step 1's repo field. The
// styles are the existing onboard.css classes.
// owner BH-7935.4
import { useEffect, useRef, useState } from 'preact/hooks';
import { html } from '../../router.js';
import { api, AuthError } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { useConfirm } from '../../ui/Modal.js';
import { Skeleton } from '../../ui/primitives.js';
import { knobInt, parseSlug } from '../../lib/onboard.js';

// The two settings rows the poll reads (schema fragment
// worker/jobs/schema.d/202611030701-bh-8001-onboarding-templates.sql). The
// fallback applies when a row is absent or unreadable. The hub-probe lane
// ticks every 10 minutes, so the max covers more than one tick.
const POLL_MS = { key: 'onboarding.create_poll_ms', fallback: 5000 };
const POLL_MAX_S = { key: 'onboarding.create_poll_max_s', fallback: 900 };
const settingRow = (q) => (q.data && q.data.setting) || null;
const NO_ANSWER = 'The hub has not answered yet. It checks every 10 minutes.';

// The form makes a repo only when parseSlug keeps both halves unchanged: no
// trim, no URL, no .git strip. The worker refuses the same inputs.
function inputOk(owner, name) {
  const p = parseSlug(`${owner}/${name}`);
  return Boolean(p) && p.owner === owner && p.repo === name;
}

export function NewRepoPanel({ owner, name, template, onCreated }) {
  // Three independent reads, started together on mount.
  const templatesQ = useApi(() => api.onboardRepoTemplates(), []);
  const pollQ = useApi(() => api.coordSetting(POLL_MS.key), []);
  const maxQ = useApi(() => api.coordSetting(POLL_MAX_S.key), []);
  const timing = useRef({});
  timing.current = { pollMs: knobInt(settingRow(pollQ), POLL_MS.fallback), maxS: knobInt(settingRow(maxQ), POLL_MAX_S.fallback) };
  const created = useRef(onCreated);
  created.current = onCreated;

  const [modal, confirm] = useConfirm();
  // idle | confirming | posting | pending | timeout | ok | failed
  const [run, setRun] = useState({ status: 'idle' });
  const busy = useRef(false);
  const keyRef = useRef({ form: null, key: null });
  const pollRef = useRef(null);
  const alive = useRef(true);

  const stopPoll = () => {
    if (pollRef.current) { pollRef.current.stopped = true; clearTimeout(pollRef.current.timer); }
    pollRef.current = null;
  };
  useEffect(() => () => { alive.current = false; stopPoll(); }, []);

  // A thrown call (network, 5xx, 404) keeps the key: a Create of the same form
  // sends it again and the worker answers the first row.
  const fail = (e, what) => {
    busy.current = false;
    if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
    setRun({ status: 'failed', error: `${what}: ${e && e.message ? e.message : String(e)}` });
  };

  const poll = (id, slug) => {
    stopPoll();
    const p = { stopped: false, timer: null };
    pollRef.current = p;
    const started = Date.now();
    const step = async () => {
      let answer;
      try {
        answer = await api.onboardRepoCreateState(id);
      } catch (e) {
        if (!p.stopped) { pollRef.current = null; fail(e, 'Could not read the create state'); }
        return;
      }
      if (p.stopped) return;
      if (answer && answer.state === 'ok') {
        pollRef.current = null;
        busy.current = false;
        setRun({ status: 'ok', slug: answer.slug });
        created.current(answer.slug);
        return;
      }
      if (answer && answer.state === 'error') {
        // A terminal error: the next Create files a new row with a new key.
        pollRef.current = null;
        busy.current = false;
        keyRef.current = { form: null, key: null };
        setRun({ status: 'failed', error: answer.error || 'The create failed.' });
        return;
      }
      if ((Date.now() - started) / 1000 >= timing.current.maxS) {
        pollRef.current = null;
        busy.current = false;
        setRun({ status: 'timeout', id, slug });
        return;
      }
      setRun({ status: 'pending', id, slug, note: answer && typeof answer.note === 'string' ? answer.note : null });
      p.timer = setTimeout(step, timing.current.pollMs);
    };
    p.timer = setTimeout(step, timing.current.pollMs);
  };

  const tmpl = templatesQ.data && typeof templatesQ.data.templates === 'object' ? templatesQ.data.templates : null;
  const loading = templatesQ.loading && !tmpl;
  const unreadable = !loading && !tmpl;
  const noRow = Boolean(tmpl) && tmpl[template] !== true;
  const canCreate = Boolean(tmpl) && !noRow && inputOk(owner, name);
  // The button shows the flight; busy (a ref, set before the first await) is
  // the guard, so a second click before the next render files nothing.
  const inFlight = ['confirming', 'posting', 'pending'].includes(run.status);

  const onCreate = async () => {
    if (busy.current || !canCreate) return;
    busy.current = true;
    const before = run;
    const slug = `${owner}/${name}`;
    setRun({ status: 'confirming' });
    const yes = await confirm({
      title: `Create ${slug}?`,
      body: `This makes a new private GitHub repo from the ${template} template. The console cannot delete it.`,
      confirmLabel: 'CREATE REPO'
    });
    if (!alive.current) return;
    if (!yes) { busy.current = false; setRun(before); return; }
    const form = `${owner}/${name}/${template}`;
    if (keyRef.current.form !== form) keyRef.current = { form, key: crypto.randomUUID() };
    setRun({ status: 'posting', slug });
    let res;
    try {
      res = await api.onboardRepoCreate({ owner, name, template }, keyRef.current.key);
    } catch (e) {
      if (alive.current) fail(e, 'Could not create the repo');
      return;
    }
    if (!alive.current) return;
    if (!res || typeof res.probe_id !== 'string' || !res.probe_id) {
      busy.current = false;
      setRun({ status: 'failed', error: 'Could not create the repo: no probe id in the answer.' });
      return;
    }
    setRun({ status: 'pending', id: res.probe_id, slug, note: null });
    poll(res.probe_id, slug);
  };

  const onCheckAgain = () => {
    if (busy.current || run.status !== 'timeout') return;
    busy.current = true;
    setRun({ status: 'pending', id: run.id, slug: run.slug, note: null });
    poll(run.id, run.slug);
  };

  let gate = null;
  if (loading) gate = html`<${Skeleton} rows=${1} />`;
  else if (unreadable) {
    gate = html`<p class="onboard-detect__note">We could not read the templates.</p>
      <button type="button" class="btn btn--sm" onClick=${() => templatesQ.reload()}>Retry</button>`;
  } else if (noRow) gate = html`<p class="onboard-detect__note">The ${template} template has no template repo set.</p>`;

  let status = '';
  if (run.status === 'posting') status = `Sending the create for ${run.slug}…`;
  else if (run.status === 'pending') status = `Waiting for the hub to create ${run.slug}.${run.note ? ` ${run.note}` : ''}`;
  else if (run.status === 'timeout') status = NO_ANSWER;
  else if (run.status === 'ok') status = `Created ${run.slug}.`;

  return html`<section class="onboard-detect">
    ${gate}
    <button type="button" class="btn btn--primary" disabled=${!canCreate || inFlight} onClick=${onCreate}>Create repo</button>
    <p class="onboard-detect__note" role="status" aria-live="polite">${status}</p>
    ${run.status === 'timeout' ? html`<button type="button" class="btn btn--sm" onClick=${onCheckAgain}>Check again</button>` : null}
    ${run.status === 'failed' ? html`<p class="onboard-review__err" role="alert">${run.error}</p>` : null}
    ${modal}
  </section>`;
}
