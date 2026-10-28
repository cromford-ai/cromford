// The Pages-side queue for the console's PROBE NOW (BH-7924): a run_script
// command that runs bin/connection-probe.sh <project> on the box that owns
// <project>. The hub forwards it (bin/poll-commands.sh run_script arm) and the
// box runs it through bin/cmd-run-script.sh, whose allowlist is the second
// guard.
//
// The console worker has no run_script kind and refuses it with 400 'unknown
// action'. The Pages proxy then queues the row itself, through the same
// fallback and auth probe as the BH-5820 board commands and BH-7708 pool_hold.
// This arm admits ONE shape only: script connection-probe.sh with the row's
// project as its one arg. Any other script or args is 'unknown action', so the
// browser can start no other script through it.

export const CONNECTION_PROBE_TYPES = new Set(['run_script']);
export const CONNECTION_PROBE_SCRIPT = 'connection-probe.sh';
const PROJECT = /^[A-Za-z0-9._-]{1,100}$/;

// The command row for a sent body, or {error} for a 400. `sent.actor` is the
// proxy's resolved identity, never the browser's.
export function connectionProbeCommand(sent) {
  const refused = { error: 'unknown action' };
  if (!CONNECTION_PROBE_TYPES.has(sent.type)) return refused;
  if (sent.script !== CONNECTION_PROBE_SCRIPT) return refused;
  const project = typeof sent.project === 'string' ? sent.project : '';
  if (!PROJECT.test(project)) return refused;
  const args = sent.args;
  if (!Array.isArray(args) || args.length !== 1 || args[0] !== project) return refused;
  // The same click within one minute is the same command; the minute is UTC.
  const minute = new Date().toISOString().slice(0, 16);
  return {
    type: 'run_script', project,
    ckey: `${project}:run_script:connection-probe:${minute}`,
    payload: { script: CONNECTION_PROBE_SCRIPT, args: [project], actor: sent.actor }
  };
}
