import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = (p) => readFileSync(join(repo, p), 'utf8');
const part = (s, a, b) => s.slice(s.indexOf(a), s.indexOf(b, s.indexOf(a)));
const bash = (script, args = [], env = {}) => spawnSync('bash', ['-c', script, 'fixture', ...args], {
  encoding: 'utf8', env: { ...process.env, ...env }, timeout: 15000,
});

test('worker bootstrap composes context budgets in a clean checkout', () => {
  const root = mkdtempSync(join(tmpdir(), 'fixture-budget-bootstrap-'));
  try {
    mkdirSync(join(root, 'bin'));
    for (const file of ['test-worker-bootstrap.sh', 'context-budgets-build.sh']) copyFileSync(join(repo, 'bin', file), join(root, 'bin', file));
    for (const file of ['lanes-build.sh', 'llm-sites-build.sh']) writeFileSync(join(root, 'bin', file), '#!/bin/bash\nexit 0\n');
    const frags = join(root, 'catalog', 'context-budgets.d');
    mkdirSync(frags, { recursive: true });
    writeFileSync(join(frags, '_head.json'), '{\n  "version": 1\n}\n');
    writeFileSync(join(frags, '_tail.json'), '{\n  "defaults": {}\n}\n');
    writeFileSync(join(frags, '0000-fixture.json'), '[\n  {"lane":"fixture-classifier","max_usd":0.05}\n]\n');
    const result = bash('bash "$1/bin/test-worker-bootstrap.sh"', [root]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(readFileSync(join(root, 'catalog', 'context-budgets.json'))).lanes[0].lane, 'fixture-classifier');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

for (const policy of [
  { level: 'automation', cap: 'autonomy', never: [] },
  { level: 'autonomy', cap: 'automation', never: [] },
  { level: 'autonomy', cap: 'autonomy', never: ['file a ticket'] },
]) test(`held staff filing obeys current policy ${JSON.stringify(policy)}`, () => {
  const root = mkdtempSync(join(tmpdir(), 'fixture-held-policy-'));
  try {
    mkdirSync(join(root, 'held'));
    mkdirSync(join(root, 'tmp'));
    const fp = 'a'.repeat(64);
    writeFileSync(join(root, 'held', `${fp}.json`), JSON.stringify({ row: { fingerprint: fp, action: 'file a ticket' }, mode: 'auto', class: 'fixture', ftitle: 'fixture' }));
    writeFileSync(join(root, 'held-list'), `${fp}\n`);
    const block = part(read('bin/staff.sh'), '# ═════ held filings:', '# ═════ the attempt cap');
    const result = bash(`STATE="$1"; TMPD="$1/tmp"; SELF="$2/bin"; H="$2"; AGENT=fixture; LEVEL="$3"; CAP="$4"; NEVER="$5"; HELD=0; FILED=0; REFUSED=0; DIGESTED=0; UNSUPPORTED=0
      cp "$1/held-list" "$1/tmp/held"
      log(){ :; }; digest(){ :; }; finish(){ :; }; file_issue(){ echo unexpected-filing; return 0; }
      ${block}`, [root, repo, policy.level, policy.cap, JSON.stringify(policy.never)]);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /unexpected-filing/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('no-tools invocation excludes all MCP servers and profile overrides', () => {
  const text = read('bin/agent-call.sh');
  const argvBlock = part(text, '        if [ "$NO_TOOLS" = 1 ]; then', '        # RESUME A STUCK SESSION');
  const profileBlock = part(text, '        # Under either tool restriction', '        # SETTINGS COMPOSITION');
  const result = bash(`NO_TOOLS=1; TOOL_FENCED=1; TOOLS_ALLOW=""; cm=fixture-model; STAGE=fixture; PROJECT=fixture; runner=claude
    _budget_for(){ echo 0.01; }
    ${argvBlock}
    SP_ARGS=(--strict-mcp-config --mcp-config fixture-profile.json --setting-sources user); profile(){ ${profileBlock} }; profile
    printf '%s\\n' "\${ARGS[@]}"`);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /--strict-mcp-config\n--mcp-config\n\{"mcpServers":\{\}\}/);
  assert.doesNotMatch(result.stdout, /fixture-profile|\nuser\n/);
  assert.match(result.stdout, /--setting-sources\n\n$/);
});

test('warm package lifecycle runs in a layer without the clone secret mount', () => {
  const docker = read('fly/Dockerfile');
  const runs = docker.match(/^RUN(?:[^\n]*\\\n)*[^\n]*/gm) || [];
  const secretRun = runs.find((s) => s.includes('id=gh_token'));
  assert.ok(secretRun);
  assert.doesNotMatch(secretRun, /bash \/opt\/fly-boot\/warm-bake\.sh/);
  assert.ok(secretRun.indexOf('set +x') < secretRun.indexOf('TOKEN="$(cat'));
  assert.match(docker, /ENTRYPOINT \["\/opt\/fly-boot\/entrypoint\.sh"\]/);
  assert.match(read('fly/entrypoint.sh'), /exec \/usr\/bin\/tini -- "\$RUNNER"/);
});

for (const failure of ['copy', 'visited', 'log-marker']) test(`writeback ${failure} failure stays unacknowledged`, () => {
  const root = mkdtempSync(join(tmpdir(), 'fixture-writeback-failure-'));
  try {
    const script = `source "$2/bin/lib/lane-run-inputs.sh"
      HARNESS="$1/root"; mkdir -p "$HARNESS/state" "$1/st" "$1/archive/.lri"; LRI_LOG_APPEND_MAX=262144
      printf 'state/fixture.txt\t-\n' > "$1/archive/.lri/base.tsv"
      printf 'fixture content' > "$1/archive/state-file"
      mkdir -p "$1/archive/state"; mv "$1/archive/state-file" "$1/archive/state/fixture.txt"
      if [ "$3" = visited ]; then printf 'fixture\tvalue\n' > "$1/archive/.lri/visited.tsv"; fi
      if [ "$3" = log-marker ]; then printf 'fixture log\n' > "$1/archive/.lri/log-append"; mkdir -p "$1/st/logs-through"; fi
      tar -czf "$1/fixture.tgz" -C "$1/archive" .lri state/fixture.txt
      _lri_rows(){ LRI_ROWS=""; }; _lri_rows_ere(){ return 1; }; _lri_state(){ printf '%s/st' "$FIXTURE_ROOT"; }
      _lri_get(){ if [[ $1 == */writebacks ]]; then printf '{"writebacks":[{"id":1,"sha":"fixture-sha"}]}' > "$2"; else printf '{}' > "$2"; fi; }
      _lri_b64_file(){ command cp "$FIXTURE_ROOT/fixture.tgz" "$2"; }
      _lri_sha(){ if [[ $1 == *.tgz ]]; then printf fixture-sha; elif [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; fi; }
      _lri_validate(){ return 0; }; _lri_base_line(){ LRI_REL=state/fixture.txt; LRI_BASE=-; }
      _lri_visited_merge(){ return 1; }
      _jobs_req(){ echo unexpected-ack >> "$FIXTURE_ROOT/ack"; }
      cp(){ if [ "$FIXTURE_FAILURE" = copy ]; then return 1; else command cp "$@"; fi; }
      _lri_apply_locked fixture fixture; exit $?`;
    const result = bash(script, [root, repo, failure], { FIXTURE_ROOT: root, FIXTURE_FAILURE: failure });
    assert.notEqual(result.status, 0, result.stderr);
    assert.equal(existsSync(join(root, 'ack')), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('lane archives reject excessive expanded content before extraction', () => {
  const root = mkdtempSync(join(tmpdir(), 'fixture-archive-budget-'));
  try {
    writeFileSync(join(root, 'fixture.txt'), 'fixture content exceeds the budget');
    const result = bash(`source "$2/bin/lib/lane-run-inputs.sh"
      tar -czf "$1/fixture.tgz" -C "$1" fixture.txt
      LRI_ARCHIVE_EXPANDED_MAX=16; _lri_members "$1/fixture.tgz"`, [root, repo]);
    assert.notEqual(result.status, 0, result.stdout);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

for (const runner of ['claude', 'codex']) test(`armed ${runner} guard refuses missing enforcement files`, () => {
  const source = read('bin/agent-call.sh');
  const block = part(source, '  # Configured guard enforcement', '  # >>> llm-gate-runner');
  const root = mkdtempSync(join(tmpdir(), 'fixture-guard-enforcement-'));
  try {
    const result = bash(`HARNESS="$1"; OUT="$1/result"; ALERTS="$1/alerts"; STAGE=execute; PROJECT=fixture; NO_TOOLS=0; IRON_LAW_ENFORCE=1; runner="$2"
      STAMP(){ echo fixture-time; }; attempt(){ ${block}
 echo unexpected-call; }; attempt`, [root, runner]);
    assert.equal(result.status, 78, result.stderr);
    assert.doesNotMatch(result.stdout, /unexpected-call/);
    assert.match(readFileSync(join(root, 'result'), 'utf8'), /AGENT_CALL_REFUSED/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('two shipped lane workers keep shared inputs exclusive through checkpoint', () => {
  const root = mkdtempSync(join(tmpdir(), 'fixture-lane-exclusive-'));
  try {
    mkdirSync(join(root, 'bin', 'lib'), { recursive: true });
    copyFileSync(join(repo, 'bin', 'lane-run-worker.sh'), join(root, 'bin', 'lane-run-worker.sh'));
    const files = {
      'bin/jobs-client.sh': `setting_get(){ return 2; }; _jobs_box_name(){ echo fixture; }
        _jobs_req(){ JOBS_HTTP=200; if [[ $2 == */claim ]]; then
          if [ -e "$H/claimed-$MACHINE" ]; then JOBS_HTTP=204; else
            touch "$H/claimed-$MACHINE"; local id=1; [ "$MACHINE" = fixture-two ] && id=2
            jq -nc --argjson i "$id" --arg p "$MACHINE" '{id:$i,lane:"fixture",project:$p,args:["bin/fixture.sh"]}'
          fi; fi; }; _jobs_req_file(){ return 0; }`,
      'bin/lib/project-lanes.sh': 'pl_name_ok(){ return 0; }',
      'bin/lib/lane-run-heartbeat.sh': 'lrh_start(){ :; }; lrh_stop(){ :; }; lrh_lost(){ return 1; }',
      'bin/lib/lane-run-inputs.sh': `lri_fetch(){ printf '%s' "$2" > "$H/shared-input"; }
        lri_checkpoint(){ [ "$(cat "$H/shared-input")" = "$2" ] || echo checkpoint-overlap >> "$H/violations"; }`,
      'bin/lib/lane-run-code.sh': 'lrc_enabled(){ return 1; }; lrc_due(){ return 1; }',
      'bin/lib/lane-run-repos.sh': 'lrr_enabled(){ return 1; }',
      'bin/lib/lane-run-warm.sh': ':',
      'bin/fixture.sh': '#!/bin/bash\nexit 0\n',
      'bin/project-lane-run.sh': `#!/bin/bash
        mkdir "$HARNESS/running" 2>/dev/null || echo simultaneous-runs >> "$HARNESS/violations"
        sleep 0.2
        [ "$(cat "$HARNESS/shared-input")" = "$2" ] || echo input-overlap >> "$HARNESS/violations"
        rmdir "$HARNESS/running" 2>/dev/null || :
        echo 'PROF fixture done'`,
    };
    for (const [path, body] of Object.entries(files)) writeFileSync(join(root, path), `${body}\n`, { mode: 0o755 });
    const result = bash(`HARNESS="$1" bash "$1/bin/lane-run-worker.sh" --once --machine fixture-one > "$1/one.log" 2>&1 & one=$!
      HARNESS="$1" bash "$1/bin/lane-run-worker.sh" --once --machine fixture-two > "$1/two.log" 2>&1 & two=$!
      wait "$one"; a=$?; wait "$two"; b=$?; cat "$1/one.log" "$1/two.log"; [ "$a" = 0 ] && [ "$b" = 0 ]`, [root]);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(existsSync(join(root, 'claimed-fixture-one')), true);
    assert.equal(existsSync(join(root, 'claimed-fixture-two')), true);
    assert.equal(existsSync(join(root, 'violations')), false);
    assert.match(readFileSync(join(root, 'logs', 'lane-run-worker.log'), 'utf8'), /run 1 fixture\/fixture-one rc 0/);
    assert.match(readFileSync(join(root, 'logs', 'lane-run-worker.log'), 'utf8'), /run 2 fixture\/fixture-two rc 0/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
