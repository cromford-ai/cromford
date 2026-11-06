// BH-6001: Mission Control at phone width. Under 600px every link, button and
// row action has a hit area of 44x44 CSS px or more, body text is 13px or more
// and meta text 11px or more, and the fix lives once in the shared layer
// (src/phone-floor.css), never per screen.
//
// A unit test has no layout engine, so this suite proves the CSS contract
// against the markup the shared components really render: every interactive
// element they emit is matched by a rule in the 600px block that gives it a
// 44px hit area. tests/drive/tap-drive.mjs measures the real hit area in a
// browser (npm run drive:tap).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h } from 'preact';

const store = new Map();
globalThis.window = globalThis.window || {
  location: { pathname: '/jobs', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
window.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => { store.set(k, String(v)); },
  removeItem: (k) => { store.delete(k); }
};
{
  const root = { attrs: { 'data-theme': 'mill' }, getAttribute(k) { return this.attrs[k] ?? null; }, setAttribute(k, v) { this.attrs[k] = String(v); }, style: { setProperty() {} } };
  globalThis.document = globalThis.document || { documentElement: root, querySelector: () => null, getElementById: () => null };
}

const { TopBar, BottomNav } = await import('../src/app.js');
const { PageHeadline, StatGrid, SectionHead, StationTrack } = await import('../src/ui/line.js');
const { SortableTable } = await import('../src/ui/SortableTable.js');
const { TicketKey } = await import('../src/ui/TicketKey.js');
const { ProjectLink, ErrorBox, HealthPill, UnavailableChip, Stat, Section } = await import('../src/ui/primitives.js');
const { HeldTag } = await import('../src/ui/HeldTag.js');
const { html, Link } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const FLOOR_REL = 'src/phone-floor.css';
const floorText = () => (fs.existsSync(path.join(root, FLOOR_REL)) ? read(FLOOR_REL) : '');
const STYLES = read('src/styles.css');

// ---- CSS helpers ------------------------------------------------------------

const stripComments = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');

// Top-level statements of a stylesheet: { prelude, body } for each `x { ... }`,
// with brace matching so a nested @media block is one statement.
function statements(css) {
  const out = [];
  let i = 0;
  const s = stripComments(css);
  while (i < s.length) {
    const open = s.indexOf('{', i);
    if (open < 0) { if (s.slice(i).trim()) out.push({ prelude: s.slice(i).trim(), body: null }); break; }
    let depth = 0; let j = open;
    for (; j < s.length; j++) {
      if (s[j] === '{') depth++;
      else if (s[j] === '}' && --depth === 0) break;
    }
    out.push({ prelude: s.slice(i, open).trim(), body: s.slice(open + 1, j) });
    i = j + 1;
  }
  return out;
}

// Split a selector list on top-level commas (not the ones inside :where()).
function splitList(sel) {
  const parts = []; let depth = 0; let cur = '';
  for (const ch of sel) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) { parts.push(cur.trim()); cur = ''; } else cur += ch;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

function decls(body) {
  const out = {};
  for (const d of body.split(';')) {
    const k = d.indexOf(':');
    if (k < 0) continue;
    out[d.slice(0, k).trim()] = d.slice(k + 1).trim().replace(/\s+/g, ' ');
  }
  return out;
}

// The rules of a flat block: [{ selectors: [...], decls: {...} }].
const rules = (block) => statements(block).filter((st) => st.body !== null && !st.prelude.startsWith('@'))
  .map((st) => ({ selectors: splitList(st.prelude), decls: decls(st.body) }));

// The body of the `@media (max-width: 600px)` block, or null.
function phoneBlock(css) {
  const st = statements(css).find((x) => /^@media\s*\(\s*max-width:\s*600px\s*\)$/.test(x.prelude));
  return st ? st.body : null;
}

// ---- selector matcher (the subset phone-floor.css uses) ---------------------
// Compound: tag, .class, [attr], [attr="v"], :where(list), :not(list),
// :has(> list), with descendant and child combinators.

function parseCompound(src) {
  const c = { tag: null, classes: [], attrs: [], where: [], not: [], has: [], pseudoEl: null };
  let i = 0;
  const ident = () => { const m = /^[a-zA-Z0-9_-]+/.exec(src.slice(i)); i += m ? m[0].length : 0; return m ? m[0] : ''; };
  const paren = () => {
    let depth = 0; const start = i;
    for (; i < src.length; i++) { if (src[i] === '(') depth++; else if (src[i] === ')' && --depth === 0) { i++; break; } }
    return src.slice(start + 1, i - 1);
  };
  if (src[i] === '*') i++;
  else if (/[a-zA-Z]/.test(src[i] || '')) c.tag = ident().toLowerCase();
  while (i < src.length) {
    const ch = src[i];
    if (ch === '.') { i++; c.classes.push(ident()); } else if (ch === '[') {
      const end = src.indexOf(']', i);
      const m = /^\[\s*([a-zA-Z-]+)\s*(?:=\s*"?([^"\]]*)"?)?\s*\]$/.exec(src.slice(i, end + 1));
      c.attrs.push({ name: m[1], value: m[2] });
      i = end + 1;
    } else if (src.startsWith('::', i)) { i += 2; c.pseudoEl = ident(); } else if (ch === ':') {
      i++;
      const name = ident();
      const arg = src[i] === '(' ? paren() : null;
      if (name === 'where' || name === 'is') c.where.push(splitList(arg));
      else if (name === 'not') c.not.push(splitList(arg));
      else if (name === 'has') c.has.push(splitList(arg));
      else c.unknown = name;
    } else throw new Error(`selector parse: unexpected "${ch}" in ${src}`);
  }
  return c;
}

// A complex selector as [compound, combinator, compound, ...] from left to right.
function parseComplex(sel) {
  const toks = []; let depth = 0; let cur = '';
  const s = sel.trim().replace(/\s*>\s*/g, ' > ');
  for (const ch of s) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ' ' && depth === 0) { if (cur) toks.push(cur); cur = ''; } else cur += ch;
  }
  if (cur) toks.push(cur);
  const out = [];
  for (const t of toks) {
    if (t === '>') { out.push('>'); continue; }
    if (out.length && out[out.length - 1] !== '>') out.push(' ');
    out.push(parseCompound(t));
  }
  return out;
}

function matchCompound(el, c) {
  if (c.unknown) return false;
  if (c.tag && el.tag !== c.tag) return false;
  for (const k of c.classes) if (!el.classes.includes(k)) return false;
  for (const a of c.attrs) {
    if (!(a.name in el.attrs)) return false;
    if (a.value !== undefined && el.attrs[a.name] !== a.value) return false;
  }
  for (const list of c.where) if (!list.some((s) => matches(el, s))) return false;
  for (const list of c.not) if (list.some((s) => matches(el, s))) return false;
  for (const list of c.has) {
    const hit = list.some((rel) => {
      const r = rel.trim();
      return r.startsWith('>')
        ? el.children.some((k) => matches(k, r.slice(1).trim()))
        : descendants(el).some((k) => matches(k, r));
    });
    if (!hit) return false;
  }
  return true;
}

const descendants = (el) => el.children.flatMap((k) => [k, ...descendants(k)]);

// Does `el` match the complex selector (pseudo-elements are ignored here)?
function matches(el, sel) {
  const parts = parseComplex(sel);
  const step = (node, idx) => {
    if (!matchCompound(node, parts[idx])) return false;
    if (idx === 0) return true;
    const comb = parts[idx - 1];
    if (comb === '>') return node.parent ? step(node.parent, idx - 2) : false;
    for (let p = node.parent; p; p = p.parent) if (step(p, idx - 2)) return true;
    return false;
  };
  return step(el, parts.length - 1);
}

// ---- markup walker ----------------------------------------------------------

const VOID = new Set(['input', 'br', 'img', 'hr', 'meta', 'link', 'source', 'wbr', 'col']);
function parseMarkup(markup) {
  const top = { tag: '#root', classes: [], attrs: {}, children: [], parent: null };
  let cur = top;
  const re = /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[^\s=/>]+(?:="[^"]*")?)*)\s*(\/?)>/g;
  for (let m; (m = re.exec(markup));) {
    const [, close, rawTag, rawAttrs, self] = m;
    const tag = rawTag.toLowerCase();
    if (close) { while (cur !== top && cur.tag !== tag) cur = cur.parent; if (cur !== top) cur = cur.parent; continue; }
    const attrs = {};
    for (const a of rawAttrs.matchAll(/([^\s=/>]+)(?:="([^"]*)")?/g)) attrs[a[1]] = a[2] ?? '';
    const el = { tag, attrs, classes: (attrs.class || '').split(/\s+/).filter(Boolean), children: [], parent: cur };
    cur.children.push(el);
    if (!self && !VOID.has(tag)) cur = el;
  }
  return top;
}

const INTERACTIVE = (el) => ['a', 'button', 'input', 'select', 'textarea', 'summary'].includes(el.tag) || el.attrs.role === 'button';
const interactive = (markup) => descendants(parseMarkup(markup)).filter(INTERACTIVE);
const label = (el) => `${el.tag}${el.classes.map((c) => `.${c}`).join('')}`;

// ---- the coverage rule ------------------------------------------------------

const TAP = 'var(--tap)';
const SPAN = `max(100%, ${TAP})`;

// Classes in styles.css that clip their content to one line (an ::after hit
// area inside one is cut off).
function truncators(css) {
  const out = new Set();
  const walk = (block) => {
    for (const st of statements(block)) {
      if (st.body === null) continue;
      if (st.prelude.startsWith('@')) { walk(st.body); continue; }
      const d = decls(st.body);
      if (d.overflow !== 'hidden' || d['text-overflow'] !== 'ellipsis') continue;
      for (const sel of splitList(st.prelude)) {
        const m = /^\.([a-zA-Z0-9_-]+)$/.exec(sel);
        if (m) out.add(m[1]);
      }
    }
  };
  walk(css);
  return out;
}

// Classes in styles.css that clip on any axis (overflow hidden, auto or
// scroll). A control that is a direct child of one sits flush to the clipping
// edge, so its ::after spill is cut off there: it needs a box rule.
function clippers(css) {
  const out = new Set();
  const walk = (block) => {
    for (const st of statements(block)) {
      if (st.body === null) continue;
      if (st.prelude.startsWith('@')) { walk(st.body); continue; }
      const d = decls(st.body);
      if (!['overflow', 'overflow-x', 'overflow-y'].some((k) => /^(hidden|auto|scroll)\b/.test(d[k] || ''))) continue;
      for (const sel of splitList(st.prelude)) {
        const m = /^\.([a-zA-Z0-9_-]+)$/.exec(sel);
        if (m) out.add(m[1]);
      }
    }
  };
  walk(css);
  return out;
}

const truncatedBy = (el, trunc) => {
  for (let n = el; n && n.tag !== '#root'; n = n.parent) {
    const hit = n.classes.find((c) => trunc.has(c));
    if (hit) return hit;
  }
  return null;
};

// covers(el, block) -> null when covered, else the reason it is not.
function coverage(block, trunc = truncators(STYLES), clip = clippers(STYLES)) {
  const rs = block ? rules(block) : [];
  const pseudo = rs.filter((r) => r.decls.width === SPAN && r.decls.height === SPAN && r.decls.position === 'absolute' &&
    r.selectors.every((s) => s.endsWith('::after')));
  const hosts = rs.filter((r) => r.decls.position === 'relative');
  const boxes = rs.filter((r) => r.decls['min-height'] === TAP || r.decls['line-height'] === TAP);
  const named = (list, el, pick) => list.some((r) => r.selectors.some((s) => (!pick || pick(r)) && matches(el, s.replace(/::after$/, ''))));
  return (el) => {
    const box = named(boxes, el, (r) => r.decls['min-width'] === TAP || r.decls['line-height'] === TAP ||
      (r.decls['min-height'] === TAP && (el.tag === 'input' || el.tag === 'select' || el.tag === 'textarea')));
    const tr = truncatedBy(el, trunc);
    if (tr) return box ? null : `sits in the .${tr} truncator, which clips an ::after hit area, and no box rule names it`;
    const flush = el.parent && el.parent.classes.find((c) => clip.has(c));
    if (flush) return box ? null : `is a direct child of the .${flush} clipper, which cuts its ::after off, and no box rule names it`;
    if (box) return null;
    if (!named(pseudo, el)) return 'no ::after hit-area rule names it';
    if (!named(hosts, el)) return 'no position: relative host rule names it';
    return null;
  };
}

// ---- the shared components, rendered ----------------------------------------

const BASE = { path: '/jobs', snap: { snapshot_age_min: 1 }, openAlerts: 2, loading: false, secondsLeft: 5, watchdogDown: false,
  identity: { data: { actor: 'ops@example.invalid', access: 'on', email: 'ops@example.invalid' }, error: null } };

const COMPONENTS = {
  SortableTable: () => h(SortableTable, {
    rows: [{ project: 'project-3', key: 'TK-104', n: 2 }],
    columns: [
      { key: 'project', label: 'PROJECT', cell: (r) => h(ProjectLink, { project: r.project }) },
      { key: 'key', label: 'TICKET', cell: (r) => h(TicketKey, { k: r.key, alt: { to: '/jobs/x', label: 'open' } }) },
      { key: 'title', label: 'TITLE', sort: null, cell: () => html`<${Link} to="/runs/1" class="cell-wrap">a long title<//>` },
      { key: 'act', label: 'ACTION', sort: null, cell: () => html`<button class="btn btn--sm">RETRY</button>` },
      { key: 'mock', label: 'MOCKUP', cell: () => html`<a class="tag" href="/ideas/1">MOCKUP</a>` }
    ]
  }),
  TopBar: () => h(TopBar, BASE),
  BottomNav: () => h(BottomNav, { path: '/jobs', openAlerts: 2 }),
  PageHeadline: () => h(PageHeadline, { chip: 'Jobs · live', asOf: 'as of 21:40Z', line1: 'a', line2: 'b', lede: 'c' },
    html`<${Link} to="/alerts">2 alerts<//>`),
  StatGrid: () => h(StatGrid, { items: [{ label: 'Claimed', value: 3, to: '/jobs' }, { label: 'Lost', value: 0 }] }),
  Stat: () => h(Stat, { label: 'Open', value: 4, to: '/alerts' }),
  Section: () => h(Section, { title: 'MACHINES', right: html`<${Link} to="/machines">ALL MACHINES ›<//>` }),
  SectionHead: () => h(SectionHead, { num: 1, title: 'The line', right: html`<${Link} to="/kanban">kanban<//>` }),
  StationTrack: () => h(StationTrack, { at: 2, targets: ['ev-1', 'ev-2', 'ev-3', null, null, null, null, null] }),
  TicketKey: () => h(TicketKey, { k: 'TK-104' }),
  ProjectLink: () => h(ProjectLink, { project: 'project-3' }),
  ErrorBox: () => h(ErrorBox, { error: 'boom', onRetry: () => {} })
};
// Pills, chips and tags render no control of their own; a test proves that
// rather than assuming it, so a future link in one is covered or goes red.
const PASSIVE = {
  HealthPill: () => h(HealthPill, { ageMin: 3 }),
  UnavailableChip: () => h(UnavailableChip, { what: 'jobs', reason: 'D1 down' }),
  HeldTag: () => h(HeldTag, { held: true, by: 'ops', at: '10:00Z', why: 'waiting' })
};

function uncovered(block) {
  const cov = coverage(block);
  const out = [];
  for (const [name, mk] of Object.entries({ ...COMPONENTS, ...PASSIVE })) {
    for (const el of interactive(render(mk()))) {
      const why = cov(el);
      if (why) out.push(`${name}: ${label(el)} — ${why}`);
    }
  }
  return out;
}

// ---- tokens -----------------------------------------------------------------

function firstRoot(css) {
  const st = statements(css).find((x) => x.prelude === ':root');
  return st ? decls(st.body) : {};
}
function phoneTokens(floorCss) {
  const base = { ...firstRoot(STYLES) };
  const block = phoneBlock(floorCss);
  if (block) for (const r of rules(block)) if (r.selectors.includes(':root')) Object.assign(base, r.decls);
  return base;
}
function resolve(tokens, value, seen = new Set()) {
  const m = /^var\((--[a-z0-9-]+)\)$/.exec(String(value).trim());
  if (!m) return value;
  assert.ok(!seen.has(m[1]), `var() loop at ${m[1]}`);
  seen.add(m[1]);
  return resolve(tokens, tokens[m[1]], seen);
}
const pxOf = (v) => { const m = /^(\d+(?:\.\d+)?)px$/.exec(String(v)); return m ? Number(m[1]) : NaN; };

function tokenFloor(floorCss) {
  const t = phoneTokens(floorCss);
  const fs = Object.keys(t).filter((k) => k.startsWith('--fs-'));
  const errs = [];
  if (fs.length < 10) errs.push(`only ${fs.length} --fs-* tokens found`);
  for (const k of fs) {
    const v = pxOf(resolve(t, t[k]));
    if (!(v >= 11)) errs.push(`${k} is ${resolve(t, t[k])} at 390px, under 11px`);
  }
  for (const k of ['--fs-lg', '--fs-sm']) {
    const v = pxOf(resolve(t, t[k]));
    if (!(v >= 13)) errs.push(`${k} is ${resolve(t, t[k])} at 390px, under 13px`);
  }
  return { errs, tokens: t };
}

// ---- T1 ---------------------------------------------------------------------

test('T1 under 600px every --fs-* token is 11px or more, body and cells 13px or more, --tap is 44px', () => {
  const floor = floorText();
  assert.ok(phoneBlock(floor) !== null, `${FLOOR_REL} has no @media (max-width: 600px) block`);
  const { errs, tokens } = tokenFloor(floor);
  assert.deepEqual(errs, []);
  // body reads --fs-lg (styles.css html, body)
  const body = decls(statements(STYLES).find((x) => x.prelude === 'html, body').body);
  assert.equal(body['font-size'], 'var(--fs-lg)');
  assert.ok(pxOf(resolve(tokens, body['font-size'])) >= 13);
  assert.equal(resolve(tokens, tokens['--fs-3xs']), '11px', '--fs-3xs is 11px on a phone');
  assert.equal(firstRoot(STYLES)['--fs-3xs'], '9px', 'the desktop :root still says 9px');
  assert.equal(resolve(tokens, tokens['--tap']), '44px');
});

// ---- T2 ---------------------------------------------------------------------

test('T2 every control the shared components render has a 44px hit area under 600px', () => {
  for (const [name, mk] of Object.entries(COMPONENTS)) {
    assert.ok(interactive(render(mk())).length >= 1, `${name} rendered no control, so it proves nothing`);
  }
  for (const [name, mk] of Object.entries(PASSIVE)) {
    assert.equal(interactive(render(mk())).length, 0, `${name} now renders a control: add it to COMPONENTS`);
  }
  const block = phoneBlock(floorText());
  assert.ok(block !== null, `${FLOOR_REL} has no @media (max-width: 600px) block`);
  assert.deepEqual(uncovered(block), []);
  // the row-action and sort controls are among what was checked
  const table = interactive(render(COMPONENTS.SortableTable())).map(label);
  for (const want of ['a.cell-name', 'a.tk', 'a.tk-alt', 'button.btn.btn--sm', 'a.tag', 'a.cell-wrap', 'button']) {
    assert.ok(table.includes(want), `SortableTable fixture renders ${want} (${table.join(' ')})`);
  }
  assert.ok(interactive(render(COMPONENTS.StationTrack())).some((e) => e.classes.includes('st--jump')));
});

// ---- T3 ---------------------------------------------------------------------

test('T3 a link inside a one-line truncator gets a box rule, not only the clipped ::after', () => {
  const trunc = truncators(STYLES);
  for (const c of ['cell-wrap', 'stat__value']) assert.ok(trunc.has(c), `styles.css .${c} is a truncator`);
  const clip = clippers(STYLES);
  // BH-9118 deleted .topbar__nav: the section links are in the side menu.
  for (const c of ['statgrid', 'bottomnav']) assert.ok(clip.has(c), `styles.css .${c} clips`);
  assert.ok(!clip.has('topbar__nav'), 'the old scrolling tab row is gone');
  const block = phoneBlock(floorText());
  assert.ok(block !== null, `${FLOOR_REL} has no @media (max-width: 600px) block`);
  const cov = coverage(block, trunc);
  const els = interactive(render(COMPONENTS.SortableTable())).filter((e) => truncatedBy(e, trunc));
  assert.ok(els.some((e) => e.classes.includes('cell-wrap')), 'the fixture carries a cell-wrap link');
  for (const el of els) assert.equal(cov(el), null, label(el));
  // the flush children of a clipper: the stat grid, the bottom nav
  const flush = ['TopBar', 'StatGrid', 'BottomNav'].flatMap((n) => interactive(render(COMPONENTS[n]())))
    .filter((e) => e.parent.classes.some((c) => clip.has(c)));
  assert.deepEqual([...new Set(flush.map((e) => e.parent.classes[0]))].sort(), ['bottomnav', 'statgrid']);
  for (const el of flush) assert.equal(cov(el), null, `${label(el)} in .${el.parent.classes[0]}`);
  // a link INSIDE a truncator span (LeadReviews' stat value, Needs' cell-wrap span)
  for (const m of [html`<span class="stat__value"><${Link} to="/x">3<//></span>`, html`<span class="cell-wrap"><${Link} to="/x">t<//></span>`]) {
    const [el] = interactive(render(m));
    assert.equal(cov(el), null, `${label(el)} inside ${el.parent.classes.join('.')}`);
  }
});

// ---- T4 ---------------------------------------------------------------------

test('T4 the overlap guards: 44px rows, 44px-wide table links, a 12px key-pair gap, label-wide bottom-nav tabs, 44px section heads', () => {
  const block = phoneBlock(floorText());
  assert.ok(block !== null, `${FLOOR_REL} has no @media (max-width: 600px) block`);
  const rs = rules(block);
  const rule = (sel) => rs.find((r) => r.selectors.includes(sel));
  assert.equal(rule('table.tbl tr:has(a, button) > td')?.decls.height, TAP);
  const gap = rule('.tk-pair')?.decls['column-gap'];
  assert.ok(pxOf(gap) >= 12, `.tk-pair column-gap is ${gap}`);
  assert.equal(rule('.tk-pair > a')?.decls['min-width'], TAP);
  const pair = interactive(render(h(TicketKey, { k: 'TK-9', alt: { to: '/jobs/x', label: 'job' } })));
  assert.deepEqual(pair.map((e) => matches(e, '.tk-pair > a')), [true, true], 'both links of a key pair');
  // a tab is never narrower than its label (minmax(44px, max-content) shrank
  // every tab to 44px once the row overflowed, and labels ran under the next)
  assert.equal(rule('.bottomnav')?.decls['grid-auto-columns'], 'minmax(max-content, 1fr)');
  assert.equal(rule('.bottomnav a')?.decls['min-width'], TAP);
  assert.equal(rule('table.tbl a.tag')?.decls['min-height'], TAP);
  // a one-digit link in a 12px-padded cell would spill 18px into the next column
  const cellLink = rule(':where(table.tbl td) a');
  assert.equal(cellLink?.decls['min-width'], TAP);
  assert.equal(cellLink?.decls.display, 'inline-block');
  // BH-6001 lead BLOCK at d661ae84b: an 18px-tall key link in a cell left its
  // 44px area to the ::after, which the table's scroll edge clipped (390px /now,
  // "BH-7" missed at -22,21 on Linux chromium). The link's own box is 44px tall.
  assert.equal(cellLink?.decls['min-height'], TAP);
  assert.equal(cellLink?.decls['line-height'], TAP);
  const head = rule('.section__head:has(a, button)');
  assert.equal(head?.decls['min-height'], TAP);
  assert.equal(head?.decls['align-items'], 'center');
  // the shared rules reach the rendered markup
  const tdLink = interactive(render(COMPONENTS.SortableTable())).find((e) => e.tag === 'a');
  assert.ok(matches(tdLink, ':where(table.tbl td) a'), `${label(tdLink)} is a table-cell link`);
  const sec = descendants(parseMarkup(render(COMPONENTS.Section()))).find((e) => e.classes.includes('section__head'));
  assert.ok(matches(sec, '.section__head:has(a, button)'), 'the Section head with a right link matches');
  assert.ok(!matches(descendants(parseMarkup(render(h(Section, { title: 'X' })))).find((e) => e.classes.includes('section__head')),
    '.section__head:has(a, button)'), 'a Section head with no control keeps its height');
});

// ---- T5 ---------------------------------------------------------------------

function classesIn(files) {
  const out = new Set();
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8');
    for (const m of src.matchAll(/class(?:Name)?=(?:"([^"]*)"|\$\{\s*[`'"]([^`'"$]*))/g)) {
      for (const c of (m[1] ?? m[2]).split(/\s+/)) if (/^[a-z][a-z0-9_-]*$/.test(c)) out.add(c);
    }
  }
  return out;
}
const jsUnder = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
  (d.isDirectory() ? jsUnder(path.join(dir, d.name)) : d.name.endsWith('.js') ? [path.join(dir, d.name)] : []));

test('T5 one shared fix, phone only: one 600px block, no px font sizes, no single-screen class, imported after styles.css', () => {
  const floor = floorText();
  assert.ok(floor, `${FLOOR_REL} exists`);
  const top = statements(floor);
  assert.equal(top.length, 1, `exactly one top-level statement (${top.map((t) => t.prelude).join(' | ')})`);
  assert.match(top[0].prelude, /^@media\s*\(\s*max-width:\s*600px\s*\)$/);
  const rs = rules(top[0].body);
  assert.ok(rs.length >= 5);
  for (const r of rs) {
    if ('font-size' in r.decls) assert.doesNotMatch(r.decls['font-size'], /\d\s*px/, `${r.selectors.join(', ')} sets a px font-size`);
  }
  // A class one screen file uses, and no shared file does, is that screen's.
  const screenFiles = jsUnder(path.join(root, 'src/screens'));
  const shared = classesIn([...jsUnder(path.join(root, 'src/ui')), path.join(root, 'src/app.js')]);
  const perScreen = new Map();
  for (const f of screenFiles) for (const c of classesIn([f])) perScreen.set(c, (perScreen.get(c) || 0) + 1);
  const screenOnly = new Set([...perScreen].filter(([c, n]) => n === 1 && !shared.has(c)).map(([c]) => c));
  assert.ok(screenOnly.has('tile__name'), 'the screen-only list is real (Fleet.js .tile__name)');
  // The one exception, named: src/screens/Ticket.js .d-meta wraps label-and-link
  // spans 6px apart, which no shared rule can space. It may only set line-height.
  const EXCEPT = { 'd-meta': ['line-height'] };
  const perScreen1 = [];
  for (const r of rs) {
    for (const sel of r.selectors) {
      const cls = [...sel.matchAll(/\.([a-zA-Z0-9_-]+)/g)].map((m) => m[1]);
      if (!(cls.length && cls.every((c) => screenOnly.has(c)))) continue;
      perScreen1.push(sel);
      const allowed = cls.length === 1 && EXCEPT[cls[0]];
      assert.ok(allowed && Object.keys(r.decls).every((k) => allowed.includes(k)), `${sel} names only single-screen classes`);
    }
  }
  assert.deepEqual(perScreen1, ['.d-meta'], 'exactly one screen-owned rule');
  const main = read('src/main.js');
  const a = main.indexOf("import './styles.css';");
  const b = main.indexOf("import './phone-floor.css';");
  assert.ok(a >= 0 && b > a, 'src/main.js imports ./phone-floor.css after ./styles.css');
});

// ---- T6 ---------------------------------------------------------------------

test('T6 the matchers go red on a broken floor', () => {
  const block = phoneBlock(floorText());
  assert.ok(block !== null, `${FLOOR_REL} has no @media (max-width: 600px) block`);
  const drop = (pred) => rules(block).filter((r) => !pred(r))
    .map((r) => `${r.selectors.join(', ')} { ${Object.entries(r.decls).map(([k, v]) => `${k}: ${v}`).join('; ')} }`).join('\n');
  const noAfter = uncovered(drop((r) => r.selectors.some((s) => s.endsWith('::after'))));
  assert.ok(noAfter.some((l) => /a\.tk\b/.test(l)), `no ::after rule leaves a.tk uncovered (${noAfter.join('; ')})`);
  const noHost = uncovered(drop((r) => r.decls.position === 'relative'));
  assert.ok(noHost.some((l) => /position: relative/.test(l)));
  // A table-cell link's own 44px box (the :where(table.tbl td) a rule) also
  // covers a.cell-wrap in a cell, so both box rules go to prove the matcher.
  const noTrunc = uncovered(drop((r) => r.selectors.some((s) => s.includes('cell-wrap') || s === ':where(table.tbl td) a')));
  assert.ok(noTrunc.some((l) => /a\.cell-wrap/.test(l)), `no truncator rule leaves a.cell-wrap uncovered (${noTrunc.join('; ')})`);
  const tenPx = `@media (max-width: 600px) { :root { --fs-3xs: 10px; --tap: 44px; } }`;
  assert.ok(tokenFloor(tenPx).errs.some((e) => e.startsWith('--fs-3xs')));
  assert.ok(tokenFloor('').errs.some((e) => e.startsWith('--fs-3xs')), 'the desktop 9px token fails the floor');
  // the matcher itself: a negative and a positive
  const [tk] = interactive(render(h(TicketKey, { k: 'TK-1' })));
  assert.equal(matches(tk, 'button'), false);
  assert.equal(matches(tk, ':where(a, button)'), true);
  assert.equal(matches(tk, 'table.tbl a.tk'), false);
});
