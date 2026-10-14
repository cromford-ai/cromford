
-- ── BH-5806 (BH-5794.1): classify every BLOCK ───────────────────────────────
-- The block-learning loop's first wave (#5794). bin/lesson-classify.sh (hub,
-- hourly) reads each BLOCK verdict once, splits it into its findings, and one
-- cheap model call (model_routes role lesson.classify) names each finding's
-- category. Routes: worker/jobs/src/routes/block-findings.js. D1 (SQLite), not
-- Supabase, so there is no RLS: every route needs the HARNESS_SECRET bearer,
-- which is the admin-only gate here. Note: docs/notes/2026-10-10-BH-5806-classify-blocks.md.
--
-- block_categories: the taxonomy, as rows (#5794: "categories are DB rows, not
-- hardcoded"). Seeded from the 2026-10 review-block analysis; INSERT OR IGNORE,
-- so an operator's edit is never overwritten. Wave 2 (#5807) adds rows.
CREATE TABLE IF NOT EXISTS block_categories (
  id TEXT PRIMARY KEY,             -- the slug the model answers with
  name TEXT NOT NULL,
  description TEXT,
  grp TEXT,                        -- the analysis group (Review infra, Logic bugs, ...)
  suggested_stage TEXT,            -- plan | builder | check | harness-fix: where a fix would go
  example_prs TEXT,                -- JSON array of PR numbers
  status TEXT NOT NULL DEFAULT 'active', -- active | retired
  added_by TEXT NOT NULL,
  reason TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
-- block_classify_runs: the dedup ledger, keyed on the verdict id and claimed
-- BEFORE the paid call (POST /api/block-classify/claim). ok and empty are
-- terminal; failed retries until attempts reaches lesson_classify.max_attempts.
CREATE TABLE IF NOT EXISTS block_classify_runs (
  verdict_id INTEGER PRIMARY KEY,  -- verdicts.id
  repo TEXT NOT NULL,
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,
  status TEXT NOT NULL,            -- claimed | ok | empty | failed
  attempts INTEGER NOT NULL DEFAULT 0,
  model TEXT,
  error TEXT,
  findings INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_block_classify_runs_status ON block_classify_runs(status);
-- block_findings: one row per numbered finding of one BLOCK verdict. category is
-- a block_categories id; an answer naming no known id is stored as `other`, with
-- the model's own label in raw_category. files are read off the finding text by
-- the lane, never by the model. verdict_at is the BLOCK's own time (the weekly
-- view counts by it).
CREATE TABLE IF NOT EXISTS block_findings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  verdict_id INTEGER NOT NULL,
  n INTEGER NOT NULL,
  repo TEXT NOT NULL,
  pr INTEGER NOT NULL,
  ticket TEXT,
  head_sha TEXT NOT NULL,
  source TEXT,                     -- verdicts.source: lead | human | box
  category TEXT NOT NULL,
  raw_category TEXT,
  confidence REAL,
  cause TEXT,
  files TEXT,                      -- JSON array
  infra_false INTEGER NOT NULL DEFAULT 0, -- 1 = an infra or false BLOCK, not the PR's fault
  text TEXT NOT NULL,
  model TEXT,
  verdict_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(verdict_id, n)
);
CREATE INDEX IF NOT EXISTS idx_block_findings_cat ON block_findings(category, verdict_at);
CREATE INDEX IF NOT EXISTS idx_block_findings_at ON block_findings(verdict_at);
INSERT OR IGNORE INTO block_categories (id, name, description, grp, suggested_stage, example_prs, status, added_by, reason, created_at, updated_at) VALUES
  ('rp-suite-missing-at-head', 'Rules pack runs a suite the PR head does not have', 'The rules pack ran tests/scratch-closure-lint.bh-4552-test.sh on branches cut before BH-4552 landed. The shell printed "No such file or directory" and the pack wrote BLOCK.', 'Review infra', 'harness-fix', '[4595, 4593, 4589, 4577, 4568]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 48 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('ci-tests-skipped', 'CI skipped every test shard on the head', 'The CI plan skipped all test shards, mostly on a stacked base, a feature-branch base or a DIRTY head. The reviewer then BLOCKed because no test of the PR ran.', 'Review infra', 'check', '[5395, 5140, 5138, 5110, 5087]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 22 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('test-hand-copies-lib', 'Test hand-copies bin/lib files', 'New tests copied bin/lib files into a scratch harness instead of using scratch_install_closure. The scratch-closure lint (BH-4552) went red.', 'Test quality', 'builder', '[5709, 4895, 4749, 4747, 4744]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 20 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('evidence-not-bound-to-head', 'Evidence or notes do not match the head', 'The body, plan.md or a docs note described an older head, a fix that was not in the diff, or a change that did not happen (FRAUD: false-completion). Examples: "No test changed" when a test changed, "fixture-only" when a guard list changed, a spend cap claimed as 1 while the registry ships 0.', 'PR body and evidence', 'builder', '[5370, 5237, 5141, 5067, 4908]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 15 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('stacked-parent-drift', 'Stacked branch drifted from its parent', 'The branch stacked on a parent ticket branch. The parent was rebuilt, rewritten or fixed, and the child kept the old parent commits: conflicts, an inherited red check, or 19 files of an unreviewed PR (#5535).', 'Merge and staleness', 'harness-fix', '[5535, 5097, 4761, 4747, 4714]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 14 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('logic-decision-rule-wrong', 'Decision rule matches the wrong cases', 'Classifiers and gates that put cases on the wrong side: risk tier calls guard scripts and test weakening "low", a header rule matches prose, a witness rule counts merged members, a credential-ask fires on product wording, a lead skips the rules pack when CI is green.', 'Logic bugs', 'plan', '[5379, 5371, 5160, 5138, 5110]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 14 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('other', 'Other (fits no category)', 'Findings that fit no category with 3 or more members.', 'Other', 'check', '[5258, 5129, 5763, 5674, 5654]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 14 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('rp-repo-setup-failed', 'Rules pack repo setup failed or base did not resolve', 'The pack printed "repo setup failed", "base ... does not resolve to a commit" or "scratch_rm refused", then wrote BLOCK. No code was reviewed.', 'Review infra', 'harness-fix', '[5310, 5308, 5301, 5290, 5282]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 13 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('shared-append-conflict', 'Conflict in a shared append or generated file', 'Two PRs appended to the same point: worker/jobs/schema.sql seeds, worker/jobs/src/index.js, schema fragments, a shared PLUMBING list, a verification-map row, catalog row counts. 2 findings are hand edits to generated files.', 'Merge and staleness', 'harness-fix', '[5600, 5129, 5087, 4908, 4867]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 12 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('newest-comment-ignored', 'Newest ticket comment not built', 'the operator or the triage added a later comment that changed the spec (new columns, a cadence, "do not merge", folded-in inputs). The plan built the original description.', 'Scope', 'plan', '[5459, 5237, 4785, 4761, 4714]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 12 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('missing-live-probe', 'Required live or production probe missing', 'The ticket or a rule (BH-1000) asked for a live probe: /api/flags, hub-lease.sh check, a registry probe, a live batch. The body had none, often across 4 rounds (#4332, #5087). The builder box may not reach production.', 'PR body and evidence', 'builder', '[5768, 5087, 5010, 4614, 4332]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 11 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('closes-overclaim', '"Closes #N" on a partial build', 'The body said "Closes #N" but slices of the ticket were not built and not filed. A merge would close the ticket and lose the rest.', 'PR body and evidence', 'builder', '[5459, 5199, 4952, 4792, 4426]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 11 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('acceptance-item-unmet', 'Acceptance item not delivered', 'A named ticket item was not met: a page time of 30 min shipped as 2 h, an acceptance grep that still fails, a prod seed that returned 0 rows, a design reference never committed.', 'Scope', 'builder', '[5160, 5086, 4908, 4867, 4785]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 9 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('logic-stuck-state-or-burned-budget', 'Failure path leaves a stuck state or burns a budget', 'An exit path skips the cleanup: a failed review leaves the head stuck, an error exit still counts against the spawn cap, a transient rc burns the one rebase, a park state waits forever with no deadline or alert.', 'Logic bugs', 'plan', '[5138, 5067, 4977, 4895, 4712]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 9 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('concurrent-rewrite-conflict', 'Another ticket rewrote the same code first', 'Not an append point: main rewrote the same lines (lead-review-enqueue.sh after BH-5294, fly-pool.sh after #4800, publish-share.sh after BH-4901). The PR went DIRTY while it waited, most often before a >12 h autopilot review.', 'Merge and staleness', 'harness-fix', '[5693, 5395, 5140, 5138, 4895]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 8 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('logic-writer-reader-mismatch', 'Writer and reader disagree on a format or contract', 'One side writes a short sha and the other compares 40-hex. A shell reader and a JS check split differently. A documented mode is ignored by one of its readers. A route breaks the reset contract of BH-5400.', 'Logic bugs', 'plan', '[5060, 5050, 4977, 4942, 4600]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 8 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('logic-alert-blast-radius', 'Alert or freeze blast radius not bounded', 'One critical page per candidate (about 665 on the first tick), one claim that mutes later pages for 48 h, a red nightly run that freezes merges fleet-wide, a sweep with no max age.', 'Logic bugs', 'plan', '[5199, 5160, 5061, 4198]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 8 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('callers-not-ported', 'Callers not ported after main changed an interface', 'Main renamed a script, added a new reader, changed a file format or added a lint. The PR kept the old caller or old format (data-lane-apply.sh pause file, renamed tier2-autoenqueue.sh, TSV deleted on main).', 'Collisions with other work', 'plan', '[5087, 4685, 4624, 4614, 4600]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 7 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('missing-body-section', 'Required PR-body section missing', 'Why, mutation counts, gate table, Task 0 snapshot, kill-knob callout or plan disclosures were missing.', 'PR body and evidence', 'check', '[5459, 5199, 5087, 5086]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 5 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('guard-silenced', 'Guard silenced with an allow-list or marker', 'To get green, the builder added a scratch-closure-allow marker or added literals to a leakcheck allow-list (KNOWN_FAKE_IDENTIFIERS, KNOWN_PUBLIC_CHECKSUMS) instead of fixing the flagged code.', 'Test quality', 'check', '[5645, 4867, 4811, 4803, 4427]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 5 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('test-nondeterminism', 'Test depends on clock, env or moving main', 'Tests used $RANDOM, a fixture that expires with the wall clock, GH_TOKEN that CI does not set, a box-local .git/info/exclude, or a diff against the moving origin/main.', 'Test quality', 'builder', '[5273, 5735, 5061, 5060, 4966]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 5 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('new-file-not-registered', 'New file or suite not registered', 'A new shim had no suite (orphan ratchet), a new suite had no row in catalog/ci-suite-durations.tsv, a new lane var had no allow-list line.', 'Test quality', 'builder', '[4685, 4618, 4606]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 4 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('weakened-or-missing-tests', 'Test weakened, or new branch untested', 'A timeout went from 15 to 60, a schema guard regex stopped catching a removed column, new branches had no test.', 'Test quality', 'check', '[5302, 4977, 4761]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 4 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('logic-unsafe-default', 'Default leaves the feature off, or on too hard', 'A knob with required:false so the feature is off in production, shadow mode on by default that runs real work, a default regen that rewrites deployment.json on every repair.', 'Logic bugs', 'plan', '[5110, 4649, 4189]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 4 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('logic-false-status-report', 'Status says done when nothing happened', 'An after-report says "Handled" when only an approve was recorded, an unreadable map is recorded as "serial", a page shows "no detail recorded" because rows were truncated.', 'Logic bugs', 'plan', '[5097, 5057, 4425]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 4 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('duplicate-of-merged-work', 'Duplicate of work already on main', 'The PR rebuilt something that another ticket had already merged (BH-4329 check, c139f7b87 prompt edit, #4883 worker files).', 'Collisions with other work', 'plan', '[4701, 4342, 4332]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 3 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('out-of-plan-files', 'Changes outside the plan', 'The diff changed files the plan did not name: inventory logic the ticket called out of scope, a stray generated file from another ticket, an out-of-scope edit that also conflicted.', 'Scope', 'check', '[5545, 5138, 5110]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 3 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('test-cannot-fail', 'Test cannot fail or uses unreal fixtures', 'A check that cannot fail (scrollWidth exclusion skips the scroller), fixtures in a format the real code never writes (40-hex vs short sha), or a missing record that leaves the suite green with the defect present.', 'Test quality', 'builder', '[5086, 4977, 4942]', 'active', 'seed', 'BH-5806 seed: the 2026-10 analysis of 300 PRs, 3 BLOCK findings', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
  ('iron-law', 'Iron law broken', 'The diff breaks a standing rule the lead brief makes a BLOCK by itself: a hardcoded model id, a new table with no RLS or admin-only gate, a native browser dialog, a metered call with no dedup before the spend, a destructive schema change.', 'Iron laws', 'check', '[]', 'active', 'seed', 'BH-5806 seed: a bucket the ticket names (lead review lr-5892-022054a3bba0)', '2026-10-13T00:00:00Z', '2026-10-13T00:00:00Z'),
  ('fixture-leak-hygiene', 'Fixture or leak hygiene', 'A test fixture carries a credential-shaped literal, a real client or person name, or a real host or account id, so the leak check or gitleaks refuses it. The fix builds the value at run time or uses a placeholder.', 'Test quality', 'builder', '[]', 'active', 'seed', 'BH-5806 seed: a bucket the ticket names (lead review lr-5892-022054a3bba0)', '2026-10-13T00:00:00Z', '2026-10-13T00:00:00Z'),
  ('brittle-whole-output-test', 'Brittle whole-output test', 'A test pins the whole output of a command (every line, a full JSON payload, a row count of a shared file), so an unrelated change elsewhere turns it red. The fix asserts only the lines the change is about.', 'Test quality', 'builder', '[]', 'active', 'seed', 'BH-5806 seed: a bucket the ticket names (lead review lr-5892-022054a3bba0)', '2026-10-13T00:00:00Z', '2026-10-13T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lesson_classify.max_attempts','3','BH-5806: paid classify attempts per BLOCK verdict before the ledger refuses it (failed only; ok and empty are terminal)','seed','2026-10-10T00:00:00Z'),
  ('lesson_classify.since_days','14','BH-5806: how many days back GET /api/block-classify/pending looks for BLOCK verdicts','seed','2026-10-10T00:00:00Z');
-- The classify model, rank 0 at hub scope: the cheap route first (#5794). It
-- copies the model and runner of the hub review.trivial route seeded above (the
-- cheap tier), so no model id is written here a second time (tests/alert-triage-
-- runners R6). Moving it to a newer Haiku is a PUT /api/model-routes, not a
-- deploy. No review.trivial row = no seed, and the lane logs "no lesson.classify
-- model route" and calls nothing. Same tombstone guard as jev-pilot.baseline.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'lesson.classify', 0, r.model, r.runner, 'seed', '2026-10-10T00:00:00Z'
  FROM model_routes r
  WHERE r.project IS NULL AND r.role = 'review.trivial' AND r.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'lesson.classify');
-- The agent-call STAGE route of the same call (bin/agent-call.sh lesson-classify):
-- every through-agent-call site in catalog/llm-sites.json has a hub rung-0
-- stage.<stage> row (tests/stage-route-seed.bh-2536 R1). The same cheap rung,
-- copied from review.trivial, with the same tombstone guard.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.lesson-classify', 0, r.model, r.runner, 'seed', '2026-10-10T00:00:00Z'
  FROM model_routes r
  WHERE r.project IS NULL AND r.role = 'review.trivial' AND r.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.lesson-classify');
