#!/usr/bin/env node
// Parse committed application/test modules without running their top-level code.
// Fixture repositories deliberately contain invalid examples and are excluded.
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const cwd = fileURLToPath(new URL('../', import.meta.url));
const result = spawnSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd, encoding: 'utf8' });
if (result.status !== 0) throw new Error(result.stderr || 'Cannot enumerate JavaScript files');
const files = [...new Set(result.stdout.split('\0'))].filter((path) => /\.(?:m?js)$/.test(path) && !/(?:^|\/)fixtures\//.test(path));
let failed = 0;
let cursor = 0;
async function checkNext() {
  while (cursor < files.length) {
    const path = files[cursor++];
    await new Promise((resolve) => {
      const parsed = spawn(process.execPath, ['--check', path], { cwd, stdio: ['ignore', 'ignore', 'pipe'] });
      let error = '';
      parsed.stderr.setEncoding('utf8');
      parsed.stderr.on('data', (data) => { error += data; });
      parsed.on('error', (e) => { error += e.message; });
      parsed.on('close', (code) => {
        if (code !== 0) {
          failed++;
          process.stderr.write(error || `${path}: syntax check did not execute\n`);
        }
        resolve();
      });
    });
  }
}
await Promise.all(Array.from({ length: Math.min(4, files.length) }, checkNext));
console.log(`JavaScript syntax: ${files.length} files checked, ${failed} failures`);
process.exitCode = failed ? 1 : 0;
