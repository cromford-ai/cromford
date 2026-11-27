import test from 'node:test';
import assert from 'node:assert/strict';
import {
  statusLabel, statusTone, statusRank, awaitingDecision,
  dusLabel, dusRank, scoreExplain, summarise, facet, ideaPath, assetUrl
} from '../src/lib/ideas.js';

// The rules under test are the ones that would go wrong quietly: a gate that
// stops reading as "waiting on a human", a count that drops a status it has
// never seen, a score explanation that invents a missing input.

test('the gate is the only state that reads as waiting on a human', () => {
  assert.equal(awaitingDecision({ status: 'gate_pending' }), true);
  assert.equal(statusTone('gate_pending'), 'warn');
  for (const s of ['candidate', 'posted', 'shipped', 'vetoed', 'expired']) {
    assert.equal(awaitingDecision({ status: s }), false, s);
  }
  assert.equal(awaitingDecision(null), false);
});

test('a status nobody has taught this screen still renders and still sorts last', () => {
  assert.equal(statusLabel('some_new_state'), 'SOME NEW STATE');
  assert.equal(statusTone('some_new_state'), 'muted');
  assert.ok(statusRank('some_new_state') > statusRank('expired'));
  assert.equal(statusLabel(''), 'UNKNOWN');
});

test('lifecycle order runs from the gate to the graveyard', () => {
  assert.ok(statusRank('gate_pending') < statusRank('candidate'));
  assert.ok(statusRank('posted') < statusRank('shipped'));
  assert.ok(statusRank('shipped') < statusRank('vetoed'));
});

test('the derisk/unclog/scale bucket keeps SELECT order, and an unset one is nothing', () => {
  assert.equal(dusLabel('derisk'), 'DERISK');
  assert.equal(dusLabel(''), null);
  assert.equal(dusLabel('whatever'), null);
  assert.ok(dusRank('derisk') < dusRank('unclog'));
  assert.ok(dusRank('unclog') < dusRank('scale'));
  assert.ok(dusRank('scale') < dusRank(''));
});

test('a score is only explained when every input for it exists', () => {
  assert.equal(scoreExplain({ impact: 8, confidence: 7, effort: 1 }), 'impact 8 × confidence 7 ÷ effort 1');
  assert.equal(scoreExplain({ impact: 8, confidence: null, effort: 1 }), null);
  assert.equal(scoreExplain({ impact: 8, confidence: 7 }), null);
  assert.equal(scoreExplain(null), null);
});

test('the strip counts the rows it was handed, not the ledger behind them', () => {
  const rows = [
    { project: 'project-3', status: 'gate_pending', shots: 2 },
    { project: 'project-3', status: 'candidate', shots: 0 },
    { project: 'project-4', status: 'shipped', shots: 2 },
    { project: 'project-4', status: 'posted', shots: 0 },
    { project: 'project-4', status: 'vetoed', shots: 0 }
  ];
  const s = summarise(rows);
  assert.equal(s.total, 5);
  assert.equal(s.awaiting, 1);
  assert.equal(s.withMockup, 2);
  assert.equal(s.posted, 2); // posted + shipped, not the vetoed one
  assert.equal(s.shipped, 1);
  assert.deepEqual(s.projects, ['project-3', 'project-4']);
  assert.equal(s.byStatus.gate_pending, 1);
  assert.equal(s.byStatus.vetoed, 1);
});

test('an empty or absent set summarises to zeroes rather than throwing', () => {
  for (const input of [[], null, undefined]) {
    const s = summarise(input);
    assert.equal(s.total, 0);
    assert.equal(s.awaiting, 0);
    assert.deepEqual(s.projects, []);
  }
});

test('facets are stable: lifecycle order for status, alphabetical for the rest', () => {
  const rows = [
    { status: 'shipped', project: 'project-3', dus: 'scale' },
    { status: 'gate_pending', project: 'project-4', dus: 'derisk' },
    { status: 'shipped', project: 'project-4', dus: '' }
  ];
  assert.deepEqual(facet(rows, 'status'), ['gate_pending', 'shipped']);
  assert.deepEqual(facet(rows, 'project'), ['project-3', 'project-4']);
  assert.deepEqual(facet(rows, 'dus'), ['derisk', 'scale']);
});

test('every link is encoded, so a slug can never break out of its path', () => {
  assert.equal(ideaPath({ project: 'project-3', slug: 'board-secret-guard' }), '/ideas/project-3/board-secret-guard');
  assert.equal(assetUrl('project-3', 'a/b', 'desktop'), '/api/ideas/asset/project-3/a%2Fb/desktop');
});
