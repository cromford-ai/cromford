#!/usr/bin/env node
// bin/staff-core.mjs — BH-5561 (BH-5556.4): the staff heartbeat's bridge to
// agent-core. bin/staff.sh calls it; it holds no rule of its own.
//
//   node staff-core.mjs soul <file>   -> {"ok","errors","may","never","report"}
//   node staff-core.mjs decide        stdin {level, cap, never, decisions:[{fingerprint, action}]}
//                                     -> {"items":[{fingerprint, verdict, never, executable}]}
//
// verdict is agent-core decide(level, cap, {name: action, never}). never is a
// NEVER-list match: decide() refuses it even at the top level. executable is
// the one action this wave can carry out, `file a ticket`, compared with the
// same normalisation decide() uses for NEVER entries (agent-core autonomy.js).
//
// rc 0 with the JSON on stdout; rc 2 on a bad argument or unreadable stdin.
// The import is relative to this file, and node resolves a symlinked bin/ to
// its real path, so the checkout and $HARNESS/bin + $HARNESS/agent-core work.
import { readFileSync } from 'node:fs';
import { parseSoul, validateSoul, decide } from '../agent-core/src/index.js';

const EXECUTABLE = 'file a ticket';
const norm = (s) => s.toLowerCase().replace(/`/g, '').replace(/\s+/g, ' ').trim().replace(/\.$/, '').trim();
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const die = (msg) => { process.stderr.write(`staff-core: ${msg}\n`); process.exit(2); };

const [mode, arg] = process.argv.slice(2);

if (mode === 'soul') {
  if (!arg) die('usage: staff-core.mjs soul <file>');
  let md;
  try { md = readFileSync(arg, 'utf8'); } catch {
    out({ ok: false, errors: ['soul file missing'], may: [], never: [], report: [] });
    process.exit(0);
  }
  const soul = parseSoul(md);
  const v = validateSoul(soul);
  out({ ok: v.ok, errors: v.errors, may: soul.may, never: soul.never, report: soul.report });
} else if (mode === 'decide') {
  let req;
  try { req = JSON.parse(readFileSync(0, 'utf8')); } catch { die('stdin is not JSON'); }
  if (!req || typeof req !== 'object' || !Array.isArray(req.decisions) || !Array.isArray(req.never)) {
    die('stdin needs {level, cap, never: [], decisions: []}');
  }
  const items = req.decisions.map((d) => {
    const action = d && typeof d.action === 'string' ? d.action : '';
    const act = { name: action, never: req.never };
    return {
      fingerprint: d && d.fingerprint,
      verdict: decide(req.level, req.cap, act),
      // At the top level only a NEVER match refuses a readable action.
      never: action.trim() !== '' && decide('autonomy', 'autonomy', act) === 'refuse',
      executable: action.trim() !== '' && norm(action) === EXECUTABLE,
    };
  });
  out({ items });
} else {
  die('usage: staff-core.mjs soul <file> | decide');
}
