import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-7263 (BH-7243.0): the console seams the four roadmap children build on.
//
// S1 the ROUTES table maps the 4 roadmap paths to their screens
// S2 RoadmapScreen renders the list view by default and the board
//    placeholder with ?view=board. The list, index and idea views are built
//    (BH-7243.1) and render without "Not built yet"; the board and wave
//    placeholders still say it
// S3 the IDEAS tab is lit on /roadmap*; NAV has no new slot
// S4 api.roadmapIdeas / api.roadmapAddIdea call the coord proxy paths
// S5 /ideas still routes to the old screens; WaveSelectBar and WaveActions
//    render nothing

globalThis.window = globalThis.window || {
  location: { pathname: '/roadmap', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { ROUTES, NAV } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { api } = await import('../src/api.js');
const { IdeasScreen } = await import('../src/screens/Ideas.js');
const { IdeaScreen } = await import('../src/screens/Idea.js');
const RS = await import('../src/screens/Roadmap.js').catch(() => ({}));
const { WaveSelectBar } = await import('../src/screens/roadmap/wave-select.js').catch(() => ({}));
const { WaveActions } = await import('../src/screens/roadmap/wave-actions.js').catch(() => ({}));

const routeOf = (path) => {
  for (const [pattern, C] of ROUTES) {
    const params = matchRoute(pattern, path);
    if (params) return { C, params };
  }
  return null;
};

test('S1 the 4 roadmap paths route to their screens', () => {
  const want = [
    ['/roadmap', RS.RoadmapIndexScreen, {}],
    ['/roadmap/cromford', RS.RoadmapScreen, { project: 'cromford' }],
    ['/roadmap/cromford/idea/abc', RS.RoadmapIdeaScreen, { project: 'cromford', id: 'abc' }],
    ['/roadmap/cromford/wave/w1', RS.RoadmapWaveScreen, { project: 'cromford', id: 'w1' }],
  ];
  for (const [path, C, params] of want) {
    assert.equal(typeof C, 'function', `screen for ${path} is exported`);
    const hit = routeOf(path);
    assert.ok(hit, `${path} is routed`);
    assert.equal(hit.C, C, path);
    assert.deepEqual({ ...hit.params }, params, path);
  }
});

test('S2 RoadmapScreen picks the list or the board view; the board and wave placeholders say Not built yet', () => {
  window.location.search = '';
  const listHtml = render(h(RS.RoadmapScreen, { project: 'cromford' }));
  // BH-7243.1 built the list: its first render is the ADD IDEA form, not the placeholder.
  assert.doesNotMatch(listHtml, /Not built yet/);
  assert.doesNotMatch(listHtml, /BH-7243\.2/);
  assert.match(listHtml, /data-testid="roadmap-add"/);
  window.location.search = '?view=board';
  const boardHtml = render(h(RS.RoadmapScreen, { project: 'cromford' }));
  assert.match(boardHtml, /Not built yet/);
  assert.match(boardHtml, /BH-7243\.2/);
  assert.doesNotMatch(boardHtml, /data-testid="roadmap-add"/);
  window.location.search = '';
  const idx = render(h(RS.RoadmapIndexScreen, {}));
  assert.doesNotMatch(idx, /Not built yet/);
  assert.match(idx, /Roadmaps/);
  const idea = render(h(RS.RoadmapIdeaScreen, { project: 'cromford', id: 'abc' }));
  assert.doesNotMatch(idea, /Not built yet/);
  assert.match(idea, /BACK TO cromford/);
  const wave = render(h(RS.RoadmapWaveScreen, { project: 'cromford', id: 'w1' }));
  assert.match(wave, /Not built yet/);
  assert.match(wave, /BH-7243\.3/);
});

test('S3 the IDEAS tab is lit on /roadmap*, and NAV has no new slot', () => {
  const ideas = NAV.find((n) => n.to === '/ideas');
  assert.ok(ideas);
  for (const p of ['/roadmap', '/roadmap/cromford', '/roadmap/cromford/wave/w1', '/ideas', '/ideas/x/y']) {
    assert.equal(ideas.match(p), true, p);
  }
  assert.equal(ideas.match('/roadmapx'), false);
  assert.equal(NAV.filter((n) => n.to.startsWith('/roadmap')).length, 0, 'no new NAV slot');
  assert.equal(NAV.filter((n) => n.match('/roadmap/cromford')).length, 1, 'only IDEAS is lit');
});

test('S4 api.roadmapIdeas and api.roadmapAddIdea call the coord proxy', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => '{"ideas":[]}' };
  };
  try {
    await api.roadmapIdeas('cromford', 'next');
    await api.roadmapIdeas('cromford');
    await api.roadmapAddIdea({ project: 'cromford', title: 'T', source: 'operator' });
  } finally { globalThis.fetch = real; }
  assert.equal(seen[0].url, '/api/coord/roadmap/ideas?project=cromford&lane=next');
  assert.equal(seen[1].url, '/api/coord/roadmap/ideas?project=cromford');
  assert.equal(seen[2].url, '/api/coord/roadmap/ideas');
  assert.equal(seen[2].method, 'POST');
  assert.equal(JSON.parse(seen[2].body).title, 'T');
});

test('S5 /ideas still routes to the old screens; WaveSelectBar and WaveActions render nothing', () => {
  assert.equal(routeOf('/ideas').C, IdeasScreen);
  assert.equal(routeOf('/ideas/x/y').C, IdeaScreen);
  assert.equal(typeof WaveSelectBar, 'function');
  assert.equal(typeof WaveActions, 'function');
  assert.equal(render(h(WaveSelectBar, { project: 'cromford', selected: [] })), '');
  assert.equal(render(h(WaveActions, { project: 'cromford', wave: { id: 'w1' } })), '');
});
