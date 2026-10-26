-- BH-8360 (slice C0): the switch of the resume-run enqueue in
-- routes/web-task-human.js (POST /api/web-task/answer). With 1, an answer to a
-- web-task human step whose run has stopped (lane_runs.status done or died)
-- enqueues one new web-task lane run with the stopped run's args_json,
-- enqueued_by 'web-task-resume:<step_id>'. 0 (the seed and the code default)
-- is off: the answer route is unchanged. No table, so no index and no
-- retention rule. Note: docs/notes/2026-10-25-BH-8360-web-task-resume-enqueue.md.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('web_task.resume_enqueue','0','BH-8360: 1 = an answer to a web-task human step whose run has stopped (done or died) enqueues one new web-task lane run with the stopped run''s args (enqueued_by web-task-resume:<step>); 0 = off; the code default is 0','seed','2026-10-25T00:00:00Z');
