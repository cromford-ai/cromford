// Local-only adapter: real built UI and Worker/Pages handlers, ephemeral data.
// The unpublished harness-console authentication probe is the only service stub.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { resolve, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import jobs from '../../worker/jobs/src/index.js';
import locks from '../../locks-worker/src/index.js';
import watchdog from '../../worker/watchdog/src/index.js';
import { openDb, d1 } from '../../worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { onRequest as coord } from '../../console-ui/functions/api/coord/[[path]].js';
import { onRequest as dash } from '../../console-ui/functions/api/[[path]].js';
const root = fileURLToPath(new URL('../../', import.meta.url));
const dist = resolve(root, 'console-ui/dist');
const o = await openDb();
const env = { DB: o.DB, HARNESS_SECRET: 'fixture-main', BOX_OPS_TOKEN: 'fixture-owner-token',
  BOX_OPS_OWNERS: 'owner@example.com', QA_READ_TOKEN: 'fixture-qa-read' };
const lockDb = new DatabaseSync(':memory:');
lockDb.exec(readFileSync(resolve(root, 'locks-worker/schema.sql'), 'utf8'));
const lockEnv = { DB: d1(lockDb), HARNESS_TOKENS: JSON.stringify({ 'fixture-lock-token': 'fixture-holder' }), MINT_CAP: '1' };
const t = Math.floor(Date.now()/1000);
lockDb.prepare('INSERT INTO locks VALUES (?,?,?,?,?,?)').run('fixture-ticket','ticket','fixture-holder','fixture-lease',t+600,t);
for (const [id,name,token,role,prefix] of [
  ['fixture-minter','fixture_min','fixture-minter-token','minter','fixture_'],
  ['fixture-other','fixtureXoutside','fixture-machine-token','machine',null]]) {
  lockDb.prepare('INSERT INTO tokens (id,name,token_hash,created_by,created_at,expires_at,role,prefix) VALUES (?,?,?,?,?,?,?,?)')
    .run(id,name,createHash('sha256').update(token).digest('hex'),'fixture-admin',t,t+3600,role,prefix);
}
const commandDb = new DatabaseSync(':memory:');
commandDb.exec('CREATE TABLE commands (id INTEGER PRIMARY KEY, ckey TEXT, type TEXT, status TEXT, result TEXT, payload TEXT)');
commandDb.prepare('INSERT INTO commands VALUES (?,?,?,?,?,?)').run(1,'fixture:TK-1:merge_pr','merge_pr','refused','refused: head moved since sha aaaaaaaa','{}');
const pageEnv = { ...env, CONSOLE_DB: d1(commandDb) };
const wdEnv = { WATCHDOG_SECRET: 'fixture-watchdog-only', HARNESS_SECRET: env.HARNESS_SECRET, KV: { get: async () => '{}' } };
const ctx = { waitUntil: (p) => p.catch(() => {}) };
globalThis.fetch = async (url, init = {}) => {
  const u = new URL(url);
  if (u.hostname === 'harness-jobs.operator.workers.dev') return jobs.fetch(new Request(url,init),env);
  if (u.hostname === 'harness-console.operator.workers.dev') {
    const cookie = new Headers(init.headers).get('cookie') || '';
    if (u.pathname === '/api/dash/fleet' && /(?:^|;\s*)(dash=fixture-operator|dashqa=fixture-preview)(?:;|$)/.test(cookie)) return Response.json({ projects: [] });
    return Response.json({ error: 'unauthorized' }, { status: 403 });
  }
  throw new Error('External network is disabled in the audit harness');
};
const mime = { '.js':'application/javascript', '.css':'text/css', '.html':'text/html', '.woff2':'font/woff2', '.svg':'image/svg+xml' };
async function handle(req) {
  const url = new URL(req.url);
  if (url.pathname.startsWith('/jobs/')) return jobs.fetch(new Request(new URL(url.pathname.slice(5)+url.search,url),req),env);
  if (url.pathname.startsWith('/locks/')) return locks.fetch(new Request(new URL(url.pathname.slice(6)+url.search,url),req),lockEnv,ctx);
  if (url.pathname.startsWith('/watchdog/')) return watchdog.fetch(new Request(new URL(url.pathname.slice(9)+url.search,url),req),wdEnv);
  if (url.pathname === '/fixture/command') return Response.json(commandDb.prepare('SELECT ckey FROM commands WHERE id=1').get());
  if (url.pathname.startsWith('/api/coord/')) return coord({ request:req, env:pageEnv, params:{path:url.pathname.slice(11).split('/')} });
  if (url.pathname.startsWith('/api/')) return dash({ request:req, env:pageEnv, params:{} });
  const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '');
  const file = resolve(dist, rel);
  if (file !== dist && !file.startsWith(dist+'/')) return new Response('not found',{status:404});
  try { return new Response(await readFile(file),{headers:{'content-type':mime[extname(file)]||'application/octet-stream'}}); }
  catch { return new Response(await readFile(resolve(dist,'index.html')),{headers:{'content-type':'text/html'}}); }
}
const server = createServer(async (incoming,out) => {
  try {
    const chunks=[]; for await (const chunk of incoming) chunks.push(chunk);
    const req=new Request(`http://127.0.0.1:${server.address().port}${incoming.url}`,{method:incoming.method,headers:incoming.headers,
      ...(['GET','HEAD'].includes(incoming.method)?{}:{body:Buffer.concat(chunks)})});
    const res=await handle(req);out.writeHead(res.status,Object.fromEntries(res.headers));out.end(Buffer.from(await res.arrayBuffer()));
  } catch (err) { console.error(err);out.writeHead(500);out.end('fixture harness failure'); }
});
server.listen(Number(process.argv[2]), '127.0.0.1');
for (const signal of ['SIGTERM','SIGINT']) process.on(signal,()=>server.close(()=>process.exit(0)));
