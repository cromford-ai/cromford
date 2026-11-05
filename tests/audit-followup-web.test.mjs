import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { createWriteGate } from '../bin/lib/web-write-step.mjs';
import { extractCode } from '../worker/otp-inbox/src/code.js';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import locks from '../locks-worker/src/index.js';

for (const change of ['page','operation']) test(`approval refuses a changed ${change} before writing`,async()=>{
  let url='https://fixture.test/settings'; let current=true; let writes=0;
  const page={url:()=>url,locator:()=>({count:async()=>0}),evaluate:async()=>false};
  const gate=createWriteGate({mode:'write',site:'fixture.test',shoot:async()=>fileURLToPath(import.meta.url),sleep:()=>new Promise(()=>{}),approve:async()=>{if(change==='page')url='https://fixture.test/different';else current=false;return 'approve';}});
  const result=await gate.gate(page,{tag:'button',name:'Save'},async()=>{writes++;},async()=>current);
  assert.equal(writes,0); assert.equal(result.terminal,true); assert.match(result.outcome,/changed/);
});
test('expired lock renewals return 404 and preserve the old expiry',async(t)=>{
  const sql=new DatabaseSync(':memory:');t.after(()=>sql.close());sql.exec(readFileSync(new URL('../locks-worker/schema.sql',import.meta.url),'utf8'));
  const now=Math.floor(Date.now()/1000);
  sql.prepare('INSERT INTO locks (key,kind,holder,lease_id,expires_at,acquired_at) VALUES (?,?,?,?,?,?)').run('fixture-key','issue','fixture-machine','fixture-lease',now-1,now-60);
  const prepare=(q,args=[])=>({bind:(...a)=>prepare(q,a),first:async()=>sql.prepare(q).get(...args)||null,run:async()=>({meta:{changes:Number(sql.prepare(q).run(...args).changes)}})});
  const res=await locks.fetch(new Request('https://locks.fixture/v1/renew',{method:'POST',headers:{authorization:'Bearer fixture-token','content-type':'application/json'},body:JSON.stringify({key:'fixture-key',lease_id:'fixture-lease'})}),{DB:{prepare},HARNESS_TOKENS:JSON.stringify({'fixture-token':'fixture-machine'})},{waitUntil:()=>{}});
  assert.equal(res.status,404);assert.equal(sql.prepare('SELECT expires_at FROM locks').get().expires_at,now-1);
});
test('OTP selection preserves nearest-keyword, digit tie, and negation rules',()=>{
  assert.equal(extractCode('Verification: G-123456','').code,'123456');
  assert.equal(extractCode('','promo code 1234\nYour login code is 654321').code,'654321');
  assert.equal(extractCode('','Your verification code: 123456').code,'123456');
  assert.equal(extractCode('','Contact fixture@example.com').status,'no_code');
});
test('removing an allowed site revokes an outstanding human answer before consumption',async(t)=>{
  const {openDb}=await import('../worker/jobs/test/lib/d1-sqlite.bh-1030.js');
  const {createHash}=await import('node:crypto');
  const {default:worker}=await import('../worker/jobs/src/index.js');
  const {db,DB}=await openDb(); t.after(()=>db.close());
  const now=new Date().toISOString();const later=new Date(Date.now()+3600000).toISOString();
  const env={DB,HARNESS_SECRET:'fixture-fleet'};const token='fixture-run-token';
  const id=Number(db.prepare("INSERT INTO lane_runs(lane,project,args_json,enqueued_at,claimed_at,claimed_by,lease_until,attempts,status) VALUES ('web-task','fixture-project','[]',?,?, 'fixture-machine',?,1,'claimed')").run(now,now,later).lastInsertRowid);
  db.prepare('INSERT INTO web_vault_run_token(run_id,machine,token_hash,created_at) VALUES (?,?,?,?)').run(id,'fixture-machine',createHash('sha256').update(token).digest('hex'),now);
  db.prepare("INSERT INTO settings(key,value,note,actor,updated_at) VALUES ('lane.web-task.fixture-project.allowed_domains','fixture.test','','fixture',?)").run(now);
  const call=async(path,body)=>{const res=await worker.fetch(new Request('https://jobs.fixture'+path,{method:'POST',headers:{authorization:'Bearer fixture-fleet','x-web-vault-run-token':token,'content-type':'application/json'},body:JSON.stringify(body)}),env);return {status:res.status,body:await res.json()};};
  const asked=await call('/api/web-task/human/ask',{run_id:id,machine:'fixture-machine',project:'fixture-project',site:'fixture.test',kind:'approve',prompt:'Approve fixture write'});
  assert.equal(asked.status,200);
  const answered=await call('/api/web-task/answer',{run_id:id,step_id:asked.body.step_id,nonce:asked.body.nonce,action:'done'});assert.equal(answered.status,200);
  db.prepare("UPDATE settings SET value='' WHERE key='lane.web-task.fixture-project.allowed_domains'").run();
  const polled=await call('/api/web-task/human/poll',{run_id:id,machine:'fixture-machine',step_id:asked.body.step_id});
  assert.equal(polled.status,403);assert.equal(polled.body.refused,'site_not_allowed');
  assert.equal(db.prepare('SELECT status FROM web_task_human_step WHERE id=?').get(asked.body.step_id).status,'answered');
});
