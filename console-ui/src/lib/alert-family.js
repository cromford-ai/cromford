// BH-9114: the family of an open console alert, read from its akey. The
// console rows carry no family column, so the Alerts screen counts by this to
// show a spike (warn digests, per-pid heartbeat rows) next to OPEN NOW.
import { html, Link } from '../router.js';

export const NO_KEY = '(no key)';

// alertFamily(akey):
//   1. strip ONE leading `orclane:` or `alert:`;
//   2. the head is the text up to the first `:`;
//   3. a `ph-` head is its first two dash words (`ph-staleremote`);
//   4. a structured key (it still had a `:`) is its head (`warnbatch`, `mq-headbound`);
//   5. a legacy `auto-<hash>` key (BH-4053) is `auto`, or every hash would be its own family;
//   6. else the key is cut at its first `-<digit>` (`hb-lane-1710927-3` -> `hb-lane`);
//   7. an empty or missing akey is `(no key)`.
export function alertFamily(akey) {
  if (typeof akey !== 'string' || akey === '') return NO_KEY;
  let k = akey;
  if (k.startsWith('orclane:')) k = k.slice('orclane:'.length);
  else if (k.startsWith('alert:')) k = k.slice('alert:'.length);
  if (k === '') return NO_KEY;
  const colon = k.indexOf(':');
  const head = colon === -1 ? k : k.slice(0, colon);
  if (head.startsWith('ph-')) return head.split('-').slice(0, 2).join('-');
  if (colon !== -1) return head || NO_KEY;
  if (head.startsWith('auto-')) return 'auto';
  const cut = head.search(/-\d/);
  return cut > 0 ? head.slice(0, cut) : head;
}

// familyCounts(rows) -> [{family, n}], most rows first, then by name.
export function familyCounts(rows) {
  const n = new Map();
  for (const r of rows || []) {
    const f = alertFamily(r && r.akey);
    n.set(f, (n.get(f) || 0) + 1);
  }
  return [...n.entries()]
    .map(([family, c]) => ({ family, n: c }))
    .sort((a, b) => b.n - a.n || (a.family < b.family ? -1 : a.family > b.family ? 1 : 0));
}

// The rows of one family; no family keeps every row.
export const filterByFamily = (rows, family) =>
  (family ? (rows || []).filter((r) => alertFamily(r && r.akey) === family) : (rows || []));

export function openFamilyHref(family, project) {
  const q = new URLSearchParams();
  if (project) q.set('project', project);
  if (family) q.set('openfamily', family);
  const s = q.toString().replace(/\+/g, '%20');
  return s ? `/alerts?${s}` : '/alerts';
}

// BY FAMILY: one pill per family with its count, every family shown. Each pill
// filters the OPEN ALERTS table to its rows. Nothing for an empty set.
export function AlertFamilyStrip({ rows, project, active }) {
  const counts = familyCounts(rows);
  if (!counts.length) return null;
  return html`
    <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin:8px 0">
      <span style="font-size:var(--fs-2xs);color:var(--faint);letter-spacing:.08em">BY FAMILY</span>
      ${counts.map((c) => html`
        <${Link} key=${c.family} to=${openFamilyHref(c.family, project)}
          class=${c.family === active ? 'pill pill--warn' : 'pill'}
          aria-current=${c.family === active ? 'true' : undefined}
          title=${`show only the ${c.family} rows`}>${c.family} ${c.n}<//>`)}
    </div>`;
}
