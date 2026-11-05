import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';

const repo = fileURLToPath(new URL('../', import.meta.url));
test('lane archives refuse oversized metadata even when regular file content is tiny', () => {
  const source = readFileSync(join(repo, 'bin/lib/lane-run-inputs.sh'), 'utf8');
  const parser = source.split("<<'PYMEMBERS'\n")[1].split('\nPYMEMBERS')[0];
  const scratch = mkdtempSync(join(tmpdir(), 'fixture-archive-'));
  try {
    const testCode = `import gzip, io, pathlib, tarfile, sys\npath = pathlib.Path(sys.argv[1])\nbuf = io.BytesIO()\nwith tarfile.open(fileobj=buf, mode='w', format=tarfile.PAX_FORMAT) as fixture:\n    member = tarfile.TarInfo('fixture')\n    member.size = 1\n    member.pax_headers = {'comment': 'fixture' * 10000}\n    fixture.addfile(member, io.BytesIO(b'x'))\npath.write_bytes(gzip.compress(buf.getvalue()))\nsys.argv = ['fixture', str(path), '134217728', '32768']\n` + parser;
    const result = spawnSync('python3', ['-B', '-c', testCode, join(scratch, 'fixture.tgz')], { encoding: 'utf8', timeout: 10000 });
    assert.equal(result.status, 1, result.stderr);
    assert.equal(result.stdout, '');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('boot installs TERM handling before bootstrap starts and can stop its daemon', { timeout: 10000 }, async () => {
  const source = readFileSync(join(repo, 'fly/entrypoint.sh'), 'utf8');
  const handler = source.slice(source.indexOf('boot_stop()'), source.indexOf('\nlog()'));
  assert.match(handler, /trap 'boot_stop 143' TERM/);
  assert.ok(source.indexOf('boot_stop()') < source.indexOf('# --- 0. identity'));
  const child = spawn('bash', ['-c', `${handler}\nsleep 30 & TAILSCALED_PID=$!\nprintf 'ready\\n'\nwhile :; do sleep 0.1 & wait $!; done`], { stdio: ['ignore', 'pipe', 'pipe'] });
  const exited = once(child, 'exit');
  try {
    await once(child.stdout, 'data');
    child.kill('SIGTERM');
    const [code] = await exited;
    assert.equal(code, 143);
  } finally { child.kill('SIGKILL'); }
});
