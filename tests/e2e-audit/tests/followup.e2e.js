import { test } from '@e2e-dev/web';
import { expect } from 'e2e';
test('Pages rejects cross-origin cookie writes before its privileged proxy',async({app})=>{
  const res=await fetch(app.baseUrl+'/api/prompts',{method:'POST',headers:{cookie:'dash=fixture-operator',origin:'https://preview.fixture.test','content-type':'text/plain'},body:'{}'});
  expect(res.status).toBe(403);expect(res.headers.get('cache-control')).toBe('no-store');
});
test('QA reads cannot reach sibling private readers',async({app})=>{
  for(const path of ['/api/prompts','/api/cockpit','/api/ideas','/api/outcomes']){
    const res=await fetch(app.baseUrl+path,{headers:{cookie:'dashqa=fixture-preview; dash=fixture-forged'}});
    expect(res.status).toBe(403);
  }
});
test('fleet identity text cannot approve staff authority',async({app})=>{
  const res=await fetch(app.baseUrl+'/jobs/api/staff/agents/autonomy',{method:'POST',headers:{authorization:'Bearer fixture-main','content-type':'application/json'},body:JSON.stringify({agent:'watchman',autonomy:'augmentation',actor:'fixture-operator'})});
  expect(res.status).toBe(403);
});
