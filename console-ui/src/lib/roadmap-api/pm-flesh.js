// BH-7260 owns this file.
// The PM flesh-out read. It goes through the coord proxy, which forwards a GET
// as-is; the claim and the result writes are box-only and stay 405 there.
// request() keeps src/api.js's error rules, so a lost session is an AuthError
// and a refusal carries err.status and err.body.
import { AuthError } from '../../api.js';

async function request(path) {
  let res;
  try {
    res = await fetch(path, { credentials: 'same-origin' });
  } catch (e) {
    throw new Error('network unreachable');
  }
  let body = null;
  const text = await res.text();
  if (text) {
    try { body = JSON.parse(text); } catch { body = null; }
  }
  if ((res.status === 403 && !(body && body.error === 'owner_only'))
    || (res.status === 404 && body && body.error === 'unauthorized')) {
    throw new AuthError();
  }
  if (!res.ok) {
    const err = new Error(body && body.error ? body.error : `http_${res.status}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

// -> {project, idea_id, runs, latest|null, as_of}
export const pmRuns = (project, ideaId) =>
  request(`/api/coord/pm/runs?${new URLSearchParams({ project, idea_id: ideaId })}`);

// The FLESH OUT command. It goes through api.action (POST /api/dash/action).
// The Pages proxy admits only this shape (functions/_lib/pm-flesh-command.js):
// run_script, pm-flesh-launch.sh, args [project, idea id]. No --force: a re-run
// of a billed run stays a person's CLI step.
export const PM_FLESH_SCRIPT = 'pm-flesh-launch.sh';
export const fleshIdOk = (id) => typeof id === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$/.test(id);
export const fleshCommand = (project, id) =>
  ({ type: 'run_script', project, script: PM_FLESH_SCRIPT, args: [project, id] });

// What the FLESH OUT answer may claim: queued only on a command_id or ok.
export function fleshOutcome(answer, err) {
  if (err) return { ok: false, text: `FLESH OUT not sent: ${err.message || err}` };
  if (answer && answer.command_id !== undefined && answer.command_id !== null) {
    return { ok: true, id: answer.command_id, text: `FLESH OUT queued as command #${answer.command_id}. The PM agent runs on the project's box. The result shows here when it is done. Press RELOAD to read it again.` };
  }
  if (answer && answer.ok === true) {
    return { ok: true, id: null, text: 'FLESH OUT queued. The PM agent runs on the project\'s box. The result shows here when it is done. Press RELOAD to read it again.' };
  }
  return { ok: false, text: 'FLESH OUT was not confirmed: the console answered with no command id.' };
}
