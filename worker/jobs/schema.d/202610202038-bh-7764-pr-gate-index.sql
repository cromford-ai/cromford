-- BH-7764: gateFacts (lib/pr-gate.js) reads WHERE repo=?1 AND state='gate'
-- ORDER BY number, id. Equality on (repo, state), then the order. Additive.
CREATE INDEX IF NOT EXISTS idx_pr_state_events_gate ON pr_state_events(repo, state, number, id);
