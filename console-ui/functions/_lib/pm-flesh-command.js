// BH-7260 owns this file. The Pages-side queue for the idea page's FLESH OUT
// button: a run_script command that runs bin/pm-flesh-launch.sh <project>
// <idea-id> on the box that owns <project>. That launcher starts
// bin/pm-flesh.sh detached. The hub forwards the row (bin/poll-commands.sh
// run_script arm) and the box runs it through bin/cmd-run-script.sh, whose
// allowlist (catalog/run-script-allowlist.d/bh-7260-pm-flesh.json) is the
// second guard.
//
// The console worker has no run_script kind and refuses it with 400 'unknown
// action'. The Pages proxy then queues the row itself, through the same
// fallback and auth probe as PROBE NOW (connection-probe-command.js). This arm
// admits ONE shape only: script pm-flesh-launch.sh with exactly the row's
// project and one idea id as its args. Any other script or args is 'unknown
// action', so the browser can start no other script and pass no --force.

export const PM_FLESH_SCRIPT = 'pm-flesh-launch.sh';
const PROJECT = /^[A-Za-z0-9._-]{1,64}$/;
// The launcher's own id rule (bin/pm-flesh-launch.sh).
export const PM_FLESH_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$/;

// The command row for a sent body, or {error} for a 400. `sent.actor` is the
// proxy's resolved identity, never the browser's.
export function pmFleshCommand(sent) {
  const refused = { error: 'unknown action' };
  if (sent.type !== 'run_script' || sent.script !== PM_FLESH_SCRIPT) return refused;
  const project = typeof sent.project === 'string' ? sent.project : '';
  if (!PROJECT.test(project)) return refused;
  const args = sent.args;
  if (!Array.isArray(args) || args.length !== 2 || args[0] !== project) return refused;
  const id = args[1];
  if (typeof id !== 'string' || !PM_FLESH_ID.test(id)) return refused;
  // The same click within one minute is the same command; the minute is UTC.
  const minute = new Date().toISOString().slice(0, 16);
  return {
    type: 'run_script', project,
    ckey: `${project}:run_script:pm-flesh:${id}:${minute}`,
    payload: { script: PM_FLESH_SCRIPT, args: [project, id], actor: sent.actor }
  };
}
