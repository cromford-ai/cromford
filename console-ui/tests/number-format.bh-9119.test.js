import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { fmtNum, fmtUsd, usdBasis, countOrNull } from '../src/lib/format.js';
import { fmtUsdExact } from '../src/lib/spend.js';
import { fmtTokens } from '../src/lib/account-usage.js';
import { Stat } from '../src/ui/primitives.js';
import { StatGrid } from '../src/ui/line.js';
import { SortableTable } from '../src/ui/SortableTable.js';
import { DailyCeilingsView } from '../src/screens/DailyCeilings.js';

// BH-9119: every number a person reads in the console has a comma separator
// (12224.73 reads 12,224.73), from one formatter with a fixed en-US locale.

test('N1: fmtNum and fmtUsd group thousands, keep sign, zero and absence', () => {
  const cases = [
    [fmtNum(12224.73, { decimals: 2 }), '12,224.73'],
    [fmtUsd(12224.73), '$12,224.73'],
    [fmtNum(4823), '4,823'],
    [fmtNum(1.5), '1.5'],
    [fmtNum(-4823), '-4,823'],
    [fmtUsd(-12224.73), '-$12,224.73'],
    [fmtUsdExact(-12224.73), '-$12,224.73'],
    [fmtUsdExact(12224.73), '$12,224.73'],
    [fmtUsdExact(0.004), '<$0.01'],
    [fmtNum(0), '0'],
    [fmtUsd(0), '$0.00'],
    [fmtNum(-0.001, { decimals: 2 }), '0.00'],
    [fmtUsd(-0.001), '$0.00'],
    [fmtNum(null), '—'],
    [fmtNum(undefined), '—'],
    [fmtNum(''), '—'],
    [fmtNum(true), '—'],
    [fmtNum(NaN), '—'],
    [fmtNum(Infinity), '—'],
    [fmtUsd(null), '—'],
    [fmtNum('12224.73', { decimals: 2 }), '12,224.73'],
    [fmtUsd(0.0123, { decimals: 4 }), '$0.0123'],
    [fmtUsd(1234.5678, { decimals: 3 }), '$1,234.568'],
    [usdBasis(12224.73).text, '$12,224.73'],
    [countOrNull(4823), '4,823'],
    [countOrNull(0), '0'],
    [countOrNull(null), 'no data'],
    [fmtTokens(12345678900), '12,345.68M'],
  ];
  for (const [got, want] of cases) assert.equal(got, want);
});

test('N2: the output does not change with the process locale', () => {
  const mod = new URL('../src/lib/format.js', import.meta.url).href;
  const out = execFileSync(process.execPath, ['--input-type=module', '-e',
    `import { fmtNum, fmtUsd } from ${JSON.stringify(mod)}; console.log(fmtNum(12224.73, { decimals: 2 }) + '|' + fmtUsd(4823))`], {
    env: { ...process.env, LANG: 'de_DE.UTF-8', LC_ALL: 'de_DE.UTF-8' },
    cwd: fileURLToPath(new URL('../', import.meta.url)),
  }).toString().trim();
  assert.equal(out, '12,224.73|$4,823.00');
});

test('N3: Stat and StatGrid group a number value, a string passes through', () => {
  assert.match(render(h(Stat, { label: 'NEEDS', value: 4823 })), />\s*4,823/);
  assert.match(render(h(Stat, { label: 'PR', value: '#9118' })), />\s*#9118/);
  const grid = render(h(StatGrid, { items: [{ label: 'RUNS', value: 12224 }, { label: 'DAY', value: '2026-11-05' }] }));
  assert.match(grid, /12,224/);
  assert.match(grid, /2026-11-05/);
});

test('N4: SortableTable groups a number cell and sorts on the raw number', () => {
  const columns = [
    { key: 'n', label: 'N', cell: (r) => r.n },
    { key: 'pr', label: 'PR', cell: (r) => `#${r.pr}` },
    { key: 'id', label: 'ID', plain: true, cell: (r) => r.id },
  ];
  const rows = [{ n: 10000, pr: 9118, id: 9118 }, { n: 9000, pr: 9119, id: 9119 }];
  const out = render(h(SortableTable, { columns, rows, defaultSort: 'n', defaultDir: 'asc' }));
  const a = out.indexOf('9,000');
  const b = out.indexOf('10,000');
  assert.ok(a !== -1 && b !== -1, 'both grouped values render');
  // A sort on the shown text would put "10,000" before "9,000".
  assert.ok(a < b, '9,000 sorts before 10,000');
  assert.match(out, />#9118</);
  assert.match(out, />9118</);
  assert.doesNotMatch(out, /9,118/);
});

test('N5: the DailyCeilings screen renders a 5000 ceiling as $5,000.00', () => {
  const row = { key: 'conf.cost-caps.acme-os.daily_usd', value: '5000', actor: 'console', note: null, updated_at: '2026-11-05T18:00:00Z' };
  const settings = { data: { settings: [row] }, loading: false };
  const spend = { data: { 'acme-os': { usd: 12224.73 } }, loading: false };
  const out = render(h(DailyCeilingsView, { settings, spend }));
  assert.match(out, /\$5,000\.00/);
  assert.match(out, /\$12,224\.73/);
});
