import test from 'node:test';
import assert from 'node:assert/strict';
import { callTool } from '../mcp/lib/tools.mjs';
import { consoleFetch } from '../mcp/lib/console.mjs';
import { routes } from '../worker/jobs/src/routes/webhooks.js';

const middleware = async () => (await import('../console-ui/functions/_middleware.js')).onRequest;
test('Pages rejects ambient-cookie writes from other origins before dispatch', async () => {
  const handler = await middleware();
  for (const origin of ['https://preview.fixture.test', 'null', undefined]) {
    let dispatched = false;
    const headers = {cookie:'dash=fixture-session'};
    if (origin) headers.origin=origin;
    const res = await handler({request:new Request('https://console.fixture.test/api/prompts', {method:'POST',headers,body:'{}'}),next:async()=>{dispatched=true; return new Response('ok');}});
    assert.equal(res.status,403); assert.equal(dispatched,false);
  }
});
test('Pages applies exact QA reads across sibling routes, even beside a forged dash cookie', async () => {
  const handler=await middleware();
  for (const path of ['/api/prompts','/api/cockpit','/api/ideas','/api/outcomes','/api/coord/jobs/extra']) {
    const res=await handler({request:new Request('https://console.fixture.test'+path,{headers:{cookie:'dashqa=fixture-qa; dash=fixture-forged'}}),next:async()=>new Response('private')});
    assert.equal(res.status,403,path);
  }
  const allowed=await handler({request:new Request('https://console.fixture.test/api/coord/jobs',{headers:{cookie:'dashqa=fixture-qa'}}),next:async()=>new Response('projected')});
  assert.equal(allowed.status,200); assert.equal(allowed.headers.get('cache-control'),'no-store');
});
test('Pages admits same-origin writes and bearer-only clients; private responses never cache',async()=>{
  const handler=await middleware();
  for (const headers of [{cookie:'dash=fixture-session',origin:'https://console.fixture.test'},{authorization:'Bearer fixture-api'}]) {
    const res=await handler({request:new Request('https://console.fixture.test/api/prompts',{method:'POST',headers,body:'{}'}),next:async()=>new Response('ok',{headers:{'set-cookie':'dash=fixture-new; HttpOnly'}})});
    assert.equal(res.status,200); assert.equal(res.headers.get('cache-control'),'no-store'); assert.match(res.headers.get('set-cookie'),/fixture-new/);
  }
});
test('closed MCP schemas reject inherited property names before handlers', async()=>{
  let calls=0;
  const registry=new Map([['fixture',{inputSchema:{type:'object',properties:{},additionalProperties:false},handler:async()=>{calls++;return {};}}]]);
  for (const key of ['constructor','toString','__proto__']) {
    const res=await callTool(registry,'fixture',JSON.parse(`{"${key}":true}`),{cfg:{}});
    assert.equal(res.isError,true); assert.match(res.content[0].text,/invalid_arguments/);
  }
  assert.equal(calls,0);
});
test('MCP cookie writes carry the bound console origin', async(t)=>{
  const seen=[]; const previous=globalThis.fetch;
  t.after(()=>{globalThis.fetch=previous;});
  globalThis.fetch=async(url,init={})=>{
    if(String(url).includes('/login/'))return new Response('',{headers:{'set-cookie':'dash=fixture-mcp; HttpOnly'}});
    seen.push(init); return new Response('{}');
  };
  await consoleFetch({url:'https://console.fixture.test',secret:'fixture-secret'},'POST','/api/prompts',{});
  assert.equal(seen[0].headers.origin,'https://console.fixture.test');
});
test('malformed webhook signatures are rejected without consuming the body',async()=>{
  for(const [path,env,header] of [
    ['/webhooks/github',{GITHUB_WEBHOOK_SECRET:'fixture-secret'},'x-hub-signature-256'],
    ['/webhooks/jira',{JIRA_WEBHOOK_SECRET:'fixture-secret'},'x-hub-signature'],
    ['/webhooks/linear',{LINEAR_WEBHOOK_SECRET:'fixture-secret'},'linear-signature']]){
    let reads=0;
    const handler=routes.find(row=>row[1]===path)[2];
    const res=await handler({env,req:{method:'POST',headers:new Headers({[header]:'invalid'}),text:async()=>{reads++;return '{}';}}});
    assert.equal(res.status,401); assert.equal(reads,0,path);
  }
});
test('webhook raw-body cap counts streamed bytes even without Content-Length',async()=>{
  const handler=routes.find(row=>row[1]==='/webhooks/github')[2];
  const req=new Request('https://fixture.test/webhooks/github',{method:'POST',headers:{'x-hub-signature-256':'sha256='+'0'.repeat(64)},body:'x'.repeat(1024*1024+1)});
  const res=await handler({env:{GITHUB_WEBHOOK_SECRET:'fixture-secret'},req});
  assert.equal(res.status,413);
});
