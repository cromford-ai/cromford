-- ── BH-9117: the NEEDS sweep knobs ──────────────────────────────────────────
-- Read by bin/needs-sweep.sh (daily hub lane) with setting_get. A missing or
-- non-numeric row is the code fallback named on each row. Flip
-- console.needs.sweep_dry_run to 0 after reading one dry run in
-- logs/needs-sweep.log. No table is created here (D1, not Supabase: no RLS,
-- index or retention rule applies). INSERT OR IGNORE: an operator's row
-- survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('console.needs.max_age_days','14','BH-9117: days a parked or pr_created console build row with no PR and no newer row may sit before the sweep moves it to stage stale; also the age past which a dead_letter command is marked expired (fallback 14). Reader: bin/needs-sweep.sh','seed','2026-11-05T22:46:00Z'),
  ('console.needs.sweep_dry_run','1','BH-9117: 1 = the NEEDS sweep decides and logs but changes no row; 0 = it applies (fallback 1, an outage is dry). Reader: bin/needs-sweep.sh','seed','2026-11-05T22:46:00Z'),
  ('console.needs.sweep_max_rows','5000','BH-9117: most build rows the NEEDS sweep changes in one run; the rest wait for the next run (fallback 5000). Reader: bin/needs-sweep.sh','seed','2026-11-05T22:46:00Z'),
  ('console.needs.sweep_max_reads','300','BH-9117: most GitHub reads (PR and issue) the NEEDS sweep makes in one run; a row past the cap is kept and the run says INCOMPLETE (fallback 300). Reader: bin/needs-sweep.sh','seed','2026-11-05T22:46:00Z'),
  ('console.needs.sweep_page_size','500','BH-9117: rows the NEEDS sweep asks for per /api/needs-sweep/candidates page; the endpoint clamps it to its env NEEDS_SWEEP_PAGE_MAX (fallback 500). Reader: bin/needs-sweep.sh','seed','2026-11-09T00:00:00Z'),
  ('console.needs.sweep_apply_chunk','100','BH-9117: build rows the NEEDS sweep sends per /api/needs-sweep/apply call; keep it at or under the endpoint env NEEDS_SWEEP_APPLY_MAX (fallback 100). Reader: bin/needs-sweep.sh','seed','2026-11-09T00:00:00Z'),
  ('console.needs.sweep_http_timeout_s','30','BH-9117: seconds the NEEDS sweep waits for one console call (curl --max-time) (fallback 30). Reader: bin/needs-sweep.sh','seed','2026-11-09T00:00:00Z');
