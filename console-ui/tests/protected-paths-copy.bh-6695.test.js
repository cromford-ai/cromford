import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { h } from 'preact';
import { render } from 'preact-render-to-string';
import { SettingsView } from '../src/screens/Settings.js';

// BH-6695 (#6663 folded in): the PROTECTED PATHS note on the hub tab of
// /settings says what the lead lane reads: the rows are the source, and the
// seed file only adds a glob that has no row yet. The TSV and its "DB cutover"
// are gone (BH-4148), so no copy under src/ names them.

const SRC = join(dirname(fileURLToPath(import.meta.url)), '..', 'src');

function sectionNote(markup, title) {
  const at = markup.indexOf(`>${title}<`);
  assert.ok(at >= 0, `the ${title} section is rendered`);
  const m = markup.slice(at).match(/class="section__note">([^<]*)</);
  assert.ok(m, `the ${title} section has a note`);
  return m[1].replace(/&#39;|&#x27;/g, "'");
}

test('C1: the hub tab renders the PROTECTED PATHS note with the new copy', () => {
  const base = { tabs: [{ id: 'hub', label: 'HUB' }], rows: [], boxRows: [], status: null, error: null, loading: false,
    busy: null, setBusy() {}, note: null, onDismissNote() {}, actions: {}, accountActions: null, dialog: null, onTab() {}, onReload() {}, controlKinds: [] };
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const note = sectionNote(render(h(SettingsView, { ...base, activeTab: 'hub' })), 'PROTECTED PATHS');
  assert.ok(!note.includes('lead-protected-paths.tsv'), `no TSV in the note: ${note}`);
  assert.ok(!note.includes('DB cutover'), `no "DB cutover" in the note: ${note}`);
  assert.ok(note.includes('reads these rows'), `the note says the lane reads the rows: ${note}`);
  assert.ok(note.includes('catalog/lead-protected-paths.seed.tsv only adds a glob that has no row yet'), `the note names the seed file's role: ${note}`);
});

test('C2: no file under console-ui/src names catalog/lead-protected-paths.tsv', () => {
  const hits = [];
  const walk = (d) => {
    for (const n of readdirSync(d)) {
      const p = join(d, n);
      if (statSync(p).isDirectory()) walk(p);
      else if (readFileSync(p, 'utf8').includes('catalog/lead-protected-paths.tsv')) hits.push(p);
    }
  };
  walk(SRC);
  assert.deepEqual(hits, []);
});
