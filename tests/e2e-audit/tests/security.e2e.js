import { test } from '@e2e-dev/web';
import { expect } from 'e2e';
const json = (body, headers = {}) => ({ method:'POST', headers:{'content-type':'application/json',...headers}, body:JSON.stringify(body) });
const main = { authorization:'Bearer fixture-main' };
const command = {box:'hub',type:'orgo_stop',target:'fixturebox',actor:'owner@example.com',confirm:true,reason:'fixture maintenance'};
test('production dashboard renders its signed-out state', async ({ app, browser }) => {
  await app.open('/');
  await expect(browser.locator('body')).toContainText('NOT SIGNED IN');
  await expect(browser.locator('body')).not.toContainText('THIS SCREEN FAILED');
});
test('a direct dashboard route also renders without a JavaScript crash', async ({ app, browser }) => {
  await app.open('/jobs');
  await expect(browser.locator('body')).toContainText('NOT SIGNED IN');
});
test('fleet bearer cannot impersonate owner but separate operator credential works', async ({ app }) => {
  const denied = await fetch(app.baseUrl+'/jobs/api/box-commands',json(command,main));
  expect(denied.status).toBe(403);
  const allowed = await fetch(app.baseUrl+'/jobs/api/box-commands',json(command,{...main,'x-box-ops-token':'fixture-owner-token'}));
  expect(allowed.status).toBe(201);
});
test('QA preview is scoped and cannot read login codes or escalate via a forged operator cookie', async ({ app }) => {
  for (const cookie of ['dashqa=fixture-preview','dash=fixture-forged; dashqa=fixture-preview']) {
    const denied=await fetch(app.baseUrl+'/api/coord/otp?to=fixture%40example.com&since=1',{headers:{cookie}});
    expect(denied.status).toBe(403);
  }
  const allowed=await fetch(app.baseUrl+'/api/coord/flags',{headers:{cookie:'dashqa=fixture-preview'}});
  expect(allowed.status).toBe(200);
});
test('unauthenticated merge retry leaves the command ledger unchanged', async ({ app }) => {
  const before=await (await fetch(app.baseUrl+'/fixture/command')).json();
  const res=await fetch(app.baseUrl+'/api/dash/action',json({type:'merge_pr',project:'fixture',ticket:'TK-1',verdict_sha:'b'.repeat(40)}));
  expect(res.status).toBe(403);
  expect(await (await fetch(app.baseUrl+'/fixture/command')).json()).toEqual(before);
});
test('ordinary settings writes cannot corrupt the encryption public key', async ({ app }) => {
  const res=await fetch(app.baseUrl+'/jobs/api/settings',{...json({key:'hub_envelope_public_key',value:'fixture-invalid-key'},main),method:'PUT'});
  expect(res.status).toBe(403);
});
test('prototype names fail lock authentication and a real credential succeeds', async ({ app }) => {
  for (const token of ['toString','constructor','__proto__']) {
    expect((await fetch(app.baseUrl+'/locks/v1/locks',{headers:{authorization:'Bearer '+token}})).status).toBe(401);
  }
  expect((await fetch(app.baseUrl+'/locks/v1/locks',{headers:{authorization:'Bearer fixture-lock-token'}})).status).toBe(200);
});
test('minter scope is literal and concurrent token issuance respects the hard cap', async ({ app }) => {
  const headers={authorization:'Bearer fixture-minter-token'};
  const listed=await (await fetch(app.baseUrl+'/locks/v1/admin/tokens',{headers})).json();
  expect(listed.tokens.some(t=>t.name==='fixtureXoutside')).toBe(false);
  const issued=await Promise.all(['fixture_one','fixture_two'].map(name=>fetch(app.baseUrl+'/locks/v1/admin/tokens',json({name},headers))));
  expect(issued.map(r=>r.status).sort()).toEqual([201,429]);
});
test('watchdog rejects URL and jobs credentials, accepting only its dedicated bearer', async ({ app }) => {
  expect((await fetch(app.baseUrl+'/watchdog/api/tickets-snapshot?s=fixture-watchdog-only')).status).toBe(403);
  expect((await fetch(app.baseUrl+'/watchdog/api/tickets-snapshot',{headers:main})).status).toBe(403);
  expect((await fetch(app.baseUrl+'/watchdog/api/tickets-snapshot',{headers:{authorization:'Bearer fixture-watchdog-only'}})).status).toBe(200);
});
