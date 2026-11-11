import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
// A namespace import, so a missing export fails its own test rather than the whole file.
import * as AF from '../src/lib/alert-family.js';

// BH-9114: the Alerts screen counts its open rows by family, so a spike (157
// warn digests, 96 per-pid heartbeat rows) reads at a glance next to OPEN NOW.

test('F1: alertFamily classifies console akeys, near misses included', () => {
  const cases = [
    ['alert:ph-staleremote-project-3-12', 'ph-staleremote'],
    ['alert:ph-stuckqueue:project-3:4', 'ph-stuckqueue'],
    ['orclane:hb-pr-owner-sweep-1710927-3', 'hb-pr-owner-sweep'],
    ['orclane:hb-pr-owner-sweep', 'hb-pr-owner-sweep'],
    ['warnbatch:hub:20261105120000:1', 'warnbatch'],
    ['orclane:warnbatch:hub:1', 'warnbatch'],
    ['mq-headbound:project-3:12', 'mq-headbound'],
    ['alert:auto-abc123', 'auto'],
    ['alert:autox-1', 'autox'],
    ['', '(no key)'],
    [null, '(no key)'],
    [undefined, '(no key)'],
    ['ph-', 'ph-'],
    ['PH-x', 'PH-x'],
    ['alert:hb-l1-unreadable', 'hb-l1-unreadable'],
    ['alert:alert:x-2', 'alert']
  ];
  for (const [k, want] of cases) assert.equal(AF.alertFamily(k), want, `alertFamily(${JSON.stringify(k)})`);
});

test('F2: familyCounts sorts by count desc, then by name; empty input is []', () => {
  const rows = [
    { akey: 'warnbatch:hub:1:1' }, { akey: 'warnbatch:hub:2:2' }, { akey: 'warnbatch:a:3:3' },
    { akey: 'mq-tc:x:1' }, { akey: 'orclane:hb-x-1-2' }, { akey: 'orclane:hb-x-3-4' },
    { akey: 'authdown:hub' }, { akey: '' }
  ];
  assert.deepEqual(AF.familyCounts(rows), [
    { family: 'warnbatch', n: 3 },
    { family: 'hb-x', n: 2 },
    { family: '(no key)', n: 1 },
    { family: 'authdown', n: 1 },
    { family: 'mq-tc', n: 1 }
  ]);
  assert.deepEqual(AF.familyCounts([]), []);
  assert.deepEqual(AF.familyCounts(null), []);
});

const strip = (props) => render(h(AF.AlertFamilyStrip, props));
const text = (m) => m.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const rows3 = [
  { akey: 'warnbatch:hub:1:1' }, { akey: 'warnbatch:hub:2:2' },
  { akey: 'orclane:hb-pr-owner-sweep-1-2' }, { akey: 'alert:ph-stalepr-project-3-3' }
];

test('F3: the strip shows BY FAMILY and one linked pill per family with its count', () => {
  const out = strip({ rows: rows3 });
  assert.match(text(out), /BY FAMILY/);
  const pills = out.match(/<a\b[^>]*>[\s\S]*?<\/a>/g) || [];
  assert.equal(pills.length, 3, out);
  assert.equal(text(pills[0]), 'warnbatch 2');
  assert.deepEqual(pills.slice(1).map(text).sort(), ['hb-pr-owner-sweep 1', 'ph-stalepr 1']);
  const hrefs = pills.map((p) => p.match(/href="([^"]*)"/)[1]);
  assert.ok(hrefs.includes('/alerts?openfamily=warnbatch'), hrefs.join(' '));
  assert.ok(hrefs.includes('/alerts?openfamily=hb-pr-owner-sweep'), hrefs.join(' '));
  // project is kept, and the family is encoded
  const withP = strip({ rows: [{ akey: '' }], project: 'project-3' });
  assert.match(withP, /href="\/alerts\?project=project-3&amp;openfamily=%28no%20key%29"/);
  // the active pill is marked so the reader sees which filter is on
  const act = strip({ rows: rows3, active: 'warnbatch' });
  assert.match(act, /aria-current="true"[^>]*>[^<]*warnbatch/);
});

test('F4: an empty set renders nothing', () => {
  assert.equal(strip({ rows: [] }), '');
  assert.equal(strip({ rows: undefined }), '');
});

test('F5: filterByFamily keeps only the chosen family, and no family keeps all rows', () => {
  const got = AF.filterByFamily(rows3, 'warnbatch');
  assert.equal(got.length, 2);
  assert.ok(got.every((r) => r.akey.startsWith('warnbatch:')));
  assert.equal(AF.filterByFamily(rows3, null).length, 4);
  assert.equal(AF.filterByFamily(rows3, '').length, 4);
  assert.equal(AF.filterByFamily(rows3, 'nope').length, 0);
});
