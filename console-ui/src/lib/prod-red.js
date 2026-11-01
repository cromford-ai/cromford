// BH-8884. The hub pushes `prod` in a project row of the fleet snapshot
// (bin/fleet-status-push.sh, `# >>> prod red`), read with the merge conductor's
// own reader, so the tag says red exactly while the queue is held:
//   {state:'red', since, sha, id}   the newest production deploy failed
//   {state:'unknown', generated_at} the deploy snapshot is unreadable or stale
//   absent                          green, or not a Vercel project
// No clock is read here.

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// `Oct 27 19:10Z`, in UTC.
export function sinceLabel(iso) {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return 'an unreadable time';
  const d = new Date(t);
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mm = String(d.getUTCMinutes()).padStart(2, '0');
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()} ${hh}:${mm}Z`;
}

// null, or {tone: 'bad' | 'muted', text, title} for the QUEUE cell tag.
export function prodMarker(prod) {
  if (!prod || typeof prod !== 'object') return null;
  if (prod.state === 'red') {
    return {
      tone: 'bad',
      text: `prod: red since ${sinceLabel(prod.since)}`,
      title: `The newest production deploy failed (commit ${prod.sha || 'unknown'}, Vercel ${prod.id || 'unknown'}). The merge queue holds every READY PR until a production deploy is READY.`
    };
  }
  if (prod.state === 'unknown') {
    return {
      tone: 'muted',
      text: 'prod: unknown',
      title: `The deploy snapshot is unreadable or stale (generated ${prod.generated_at || 'none'}). The merge queue does not hold on an unknown state.`
    };
  }
  return null;
}
