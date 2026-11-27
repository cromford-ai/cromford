-- ── BH-10217: the cap of GET /api/pr-record-refs ─────────────────────────────
-- Reader: routes/pr-record-refs.js refReadMax (code fallback
-- REF_READ_MAX_DEFAULT = 50). The hub lane bin/tickets-snapshot-push.sh asks
-- for the closed and merged record rows of each branch-only ref of a repo in
-- one call; over the cap the answer is 400 too_many and the lane reads GitHub
-- for that repo on that tick (never a silent cut).
-- No table is created here, so no index, RLS or retention rule applies.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('pr_records.ref_read_max','50','BH-10217: most head refs GET /api/pr-record-refs takes per call; over it the answer is 400 too_many. No row or not an integer 1..1000 = 50 (routes/pr-record-refs.js REF_READ_MAX_DEFAULT)','seed','2026-11-26T11:40:00Z');
