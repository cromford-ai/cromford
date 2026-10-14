// BH-5750: what the console reads out of a box_commands row's `detail` — the
// price a quote recorded, the lines to show verbatim, the NEXT: hints and the
// fail tag. bin/box-ops.sh writes the detail from the script's own output,
// fields joined with " | ". Nothing here computes or invents a price (D26):
// the figure is the one the line carries, by the worker's own rule.

// How often and how long a priced dialog polls for its quote row (T3.2).
export const QUOTE_POLL = { intervalMs: 5000, timeoutMs: 180000 };

const RESIZE_COST_RE = /(?:COST: resize \S+|PLAN cost) \+\$(\d+(?:\.\d+)?)\/mo/;
const LAUNCH_USD_RE = /\busd_mo=(\d+(?:\.\d+)?)\b/;

// The monthly USD figure a finished quote row recorded, as a string, or null.
// The same rule as worker/jobs/src/lib/box-command-args.js quoteFigure (the
// worker re-checks it): resize is the FIRST COST:/PLAN cost line, an ok quote
// with neither costs "0"; launch is usd_mo=, none is no figure.
export function quoteFigure(quoteType, detail) {
  if (typeof detail !== 'string') return null;
  if (quoteType === 'orgo_resize_quote') {
    const m = RESIZE_COST_RE.exec(detail);
    return m ? m[1] : '0';
  }
  if (quoteType === 'orgo_launch_quote') {
    const m = LAUNCH_USD_RE.exec(detail);
    return m ? m[1] : null;
  }
  return null;
}

// The detail as its fields, in order.
export function detailFields(detail) {
  if (typeof detail !== 'string') return [];
  return detail.split(/ \| |\n/).map((s) => s.trim()).filter(Boolean);
}

const FINISHED = new Set(['ok', 'fail']);

// A quote row as the dialog shows it. `lines` are verbatim fields: the price
// line(s) on an ok quote, the NEEDS PURCHASE lines on a failed one, else the
// whole detail. `confirmable` only for an ok row that carries a figure.
export function quoteView(row) {
  if (!row || !FINISHED.has(row.status)) return { phase: 'pending', figure: null, lines: [], confirmable: false };
  const fields = detailFields(row.detail);
  if (row.status === 'fail') {
    const np = fields.filter((f) => f.startsWith('NEEDS PURCHASE:'));
    return { phase: 'fail', figure: null, lines: np.length ? np : fields, confirmable: false };
  }
  const figure = quoteFigure(row.type, row.detail);
  const pick = row.type === 'orgo_launch_quote'
    ? fields.filter((f) => /^capacity:/.test(f) || LAUNCH_USD_RE.test(f))
    : fields.filter((f) => RESIZE_COST_RE.test(f));
  return { phase: 'ok', figure, lines: pick.length ? pick : fields, confirmable: figure !== null };
}

const abortableSleep = (ms, signal) => new Promise((resolve) => {
  if (signal.aborted) { resolve(); return; }
  const t = setTimeout(() => { signal.removeEventListener('abort', done); resolve(); }, ms);
  const done = () => { clearTimeout(t); resolve(); };
  signal.addEventListener('abort', done, { once: true });
});

// Poll `list()` (api.boxCommands('hub')) every intervalMs for the row with
// this id until it is ok/fail, the time is up, or the signal aborts. A list
// that throws is retried on the next tick; onTick sees each error.
// -> { row } | { timeout: true } | { aborted: true }
export async function pollQuote(id, { list, signal, intervalMs = QUOTE_POLL.intervalMs, timeoutMs = QUOTE_POLL.timeoutMs, now = Date.now, sleep, onTick } = {}) {
  const wait = sleep || ((ms) => abortableSleep(ms, signal));
  const start = now();
  while (now() - start < timeoutMs) {
    await wait(intervalMs);
    if (signal.aborted) return { aborted: true };
    try {
      const payload = await list();
      if (signal.aborted) return { aborted: true };
      const row = payload && Array.isArray(payload.commands) ? payload.commands.find((c) => c && c.id === id) : null;
      if (onTick) onTick({ row: row || null, error: null });
      if (row && FINISHED.has(row.status)) return { row };
    } catch (e) {
      if (signal.aborted) return { aborted: true };
      if (onTick) onTick({ row: null, error: e && e.message ? e.message : String(e) });
    }
  }
  return { timeout: true };
}

// The BOX COMMANDS DETAIL cell: NEXT: fields apart, each its own line.
export function detailView(detail) {
  const fields = detailFields(detail);
  return { text: fields.filter((f) => !f.startsWith('NEXT:')), next: fields.filter((f) => f.startsWith('NEXT:')) };
}

const FAIL_TAGS = [['WAITING:', 'WAITING'], ['NEEDS PURCHASE:', 'NEEDS PURCHASE'], ['refused:', 'REFUSED']];

// The tag a failed row shows instead of FAIL, when its detail says why.
export function failTag(row) {
  if (!row || row.status !== 'fail' || typeof row.detail !== 'string') return null;
  const fields = detailFields(row.detail);
  for (const [word, tag] of FAIL_TAGS) if (fields.some((f) => f.startsWith(word))) return tag;
  return null;
}
