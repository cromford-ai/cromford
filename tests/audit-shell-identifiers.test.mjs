import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
test('generated credential and project variable names are legal shell identifiers', () => {
  const listed = spawnSync('git', ['ls-files', '-z', '*.sh', '*.toml'], { cwd: repo, encoding: 'utf8' });
  assert.equal(listed.status, 0, listed.stderr);
  const invalid = [];
  for (const path of listed.stdout.split('\0').filter(Boolean)) {
    const body = readFileSync(join(repo, path), 'utf8');
    for (const match of body.matchAll(/\b(?:FLY_API_TOKEN_|GH_APP_INSTALLATION_|BR_PER_TICK_)[A-Za-z0-9_]+-[A-Za-z0-9_-]+|\bPR_project-\d+/g)) {
      invalid.push(`${path}: ${match[0]}`);
    }
  }
  assert.deepEqual(invalid, [], 'bash -n accepts these invalid assignments, but they fail when executed');
});
