// BH-6668: the step labels of a Kanban card track overlapped (eight nowrap
// labels on a 27-36 px node pitch). A card track now shows only its current
// station's label; the track's title lists all eight stations.
//
// K1/K2 read the shipped stylesheet. K3/K4 render the real PipelineBoard and
// evaluate the K1 selectors against its markup, so a card shows exactly one
// label and it is the card's own station. The browser check (bounding boxes at
// 390x844 and 1280x900) is tests/drive/kanban-steps.bh-6668-drive.mjs.
// (File name: console-ui runs tests/*.test.js.)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/kanban', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
const { render } = await import('preact-render-to-string');
const { PipelineBoard } = await import('../src/screens/Kanban.js');
const { cardStation } = await import('../src/lib/line-screens.js');

// Every leaf rule of the stylesheet, comments stripped, @media bodies flattened.
function cssRules(src) {
  const text = src.replace(/\/\*[^]*?\*\//g, '');
  const out = [];
  const walk = (s) => {
    let i = 0;
    while (i < s.length) {
      const open = s.indexOf('{', i);
      if (open === -1) break;
      const head = s.slice(i, open).trim();
      let depth = 1; let j = open + 1;
      for (; j < s.length && depth; j++) { if (s[j] === '{') depth++; else if (s[j] === '}') depth--; }
      const body = s.slice(open + 1, j - 1);
      if (head.startsWith('@')) walk(body);
      else {
        const decls = {};
        for (const d of body.split(';')) {
          const k = d.indexOf(':');
          if (k > 0) decls[d.slice(0, k).trim()] = d.slice(k + 1).trim();
        }
        out.push({ selectors: head.split(/,(?![^(]*\))/).map((x) => x.trim().replace(/\s+/g, ' ')), decls });
      }
      i = j;
    }
  };
  walk(text);
  return out;
}

const RULES = cssRules(fs.readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8'));
const SHOW = [
  '.card__track .st.now .lbl',
  '.card__track .st.done:last-child .lbl',
  '.card__track .st.done:has(+ .st:not(.done):not(.now)) .lbl'
];

function showRule() {
  const r = RULES.find((x) => SHOW.every((s) => x.selectors.includes(s)));
  assert.ok(r, `no rule lists all of: ${SHOW.join(' | ')}`);
  return r;
}

test('K1 a card track hides every station label and shows the current one', () => {
  const hide = RULES.find((x) => x.selectors.includes('.card__track .st .lbl') && x.decls.display === 'none');
  assert.ok(hide, 'no rule sets `.card__track .st .lbl { display: none }`');
  const show = showRule();
  assert.ok(show.decls.display, 'the show rule sets no display');
  assert.notEqual(show.decls.display, 'none');
  // Cascade: the show rule comes after the hide rule, so it wins at equal or higher specificity.
  assert.ok(RULES.indexOf(show) > RULES.indexOf(hide), 'the show rule must come after the hide rule');
});

test('K2 no rule outside a card track hides station labels', () => {
  const bad = RULES.filter((x) => x.decls.display === 'none' && x.selectors.some((s) => /\.lbl\b/.test(s) && /\.st\b/.test(s) && !s.includes('.card__track')));
  assert.deepEqual(bad.map((x) => x.selectors.join(', ')), [], 'the Jobs and ticket tracks keep all their labels');
});

const card = (id, ticket, stage, over = {}) => ({ id, project: 'project-3', ticket, ticket_key: ticket, bkey: ticket, stage, age_min: 5, tier: 2, ...over });
const COLUMNS = {
  queued: [],
  building: [card(1, 'TK-1', 'executing')],
  merge_queue: [card(3, 'TK-3', 'queued', { pr_url: 'https://github.com/example-org/project-3/pull/30' })],
  review: [card(4, 'TK-4', 'reviewing')],
  merged_deployed: [card(5, 'TK-5', 'merged')],
  dead_failed: [card(6, 'TK-6', 'failed')]
};
const BOARD = { columns: COLUMNS, counts: { queued: 0, building: 1, merge_queue: 1, review: 1, merged_deployed: 1, dead_failed: 1 }, building_stale: 0, snapshot_age_min: 1 };
const OUT = render(h(PipelineBoard, { board: BOARD, external: [], shipped: null, showEmpty: false, emptyNote: '', onToggleAudit() {} }));
const TITLE = '01 Triage · 02 Plan · 03 Build · 04 Review · 05 Merge · 06 Deploy · 07 Prod QA · 08 Close';

// Each rendered card track: its title and its station classes in order.
function tracks(out) {
  const res = [];
  const re = /<div class="card__track"([^>]*)>([^]*?aria-label="([^"]*)"[^]*?)<\/div><\/div>(?=\s*<span class="card__foot")/g;
  for (let m; (m = re.exec(out));) {
    const title = (/title="([^"]*)"/.exec(m[1]) || [])[1];
    const st = [...m[2].matchAll(/<div class="(st(?: [a-z]+)?)">/g)].map((x) => x[1].split(' ').slice(1));
    res.push({ title, aria: m[3], st });
  }
  return res;
}

test('K3 each Kanban build card track carries the eight-station title', () => {
  const t = tracks(OUT);
  assert.equal(t.length, 4, 'four build cards on the line (the failed card draws no track)');
  for (const x of t) {
    assert.equal(x.title, TITLE, `${x.aria}: title`);
    assert.equal(x.st.length, 8, `${x.aria}: eight stations`);
  }
  const building = t.find((x) => x.aria.startsWith('TK-1 '));
  assert.deepEqual(building.st.filter((c) => c.includes('now')).length, 1);
  const merged = t.find((x) => x.aria.startsWith('TK-5 '));
  assert.deepEqual(merged.st, [['done'], ['done'], ['done'], ['done'], ['done'], ['done'], [], []]);
});

// Evaluate one `.card__track .st<compound> .lbl` selector on station i.
function matches(sel, st, i) {
  const m = /^\.card__track \.st((?:\.[a-z]+)*)((?::[a-z-]+(?:\([^]*\))?)?) \.lbl$/.exec(sel);
  assert.ok(m, `selector shape not understood: ${sel}`);
  const cls = m[1].split('.').filter(Boolean);
  if (!cls.every((c) => st[i].includes(c))) return false;
  const pseudo = m[2];
  if (!pseudo) return true;
  if (pseudo === ':last-child') return i === st.length - 1;
  if (pseudo === ':has(+ .st:not(.done):not(.now))') return i + 1 < st.length && !st[i + 1].includes('done') && !st[i + 1].includes('now');
  assert.fail(`pseudo-class not understood: ${pseudo}`);
}

test('K4 exactly one station per card shows its label, and it is the card\'s station', () => {
  const show = showRule();
  const want = {};
  for (const [col, cards] of Object.entries(COLUMNS)) for (const c of cards) want[c.ticket] = cardStation(c, col);
  for (const x of tracks(OUT)) {
    const key = x.aria.split(' ')[0];
    const shown = x.st.map((_, i) => i).filter((i) => show.selectors.some((s) => matches(s, x.st, i)));
    assert.deepEqual(shown, [want[key]], `${key}: the shown label`);
  }
});
