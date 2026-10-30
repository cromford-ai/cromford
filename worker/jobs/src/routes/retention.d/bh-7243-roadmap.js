export default [
  // BH-7243.0: the roadmap. Each rule copies to the archive before it deletes;
  // unbound, it deletes nothing and reports "archive not bound" only while a
  // row waits (quietUnbound).
  // The idea and wave deletes repeat the state test, so an idea restored or a
  // wave reopened between the id read and the delete stays. Waves hold
  // cost_usd (money): archived, never only deleted.
  {
    rule: "roadmap_ideas.discarded", table: "roadmap_ideas", key: "retention.roadmap_ideas.discarded_days", def: 180,
    archive: "roadmap_ideas", quietUnbound: true,
    ids: "SELECT id FROM roadmap_ideas WHERE lane = 'discarded' AND discarded_at < ?1 ORDER BY discarded_at LIMIT ?2",
    sel: "SELECT * FROM roadmap_ideas WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM roadmap_ideas WHERE id IN (SELECT value FROM json_each(?1)) AND lane = 'discarded'",
  },
  {
    rule: "roadmap_idea_events.age", table: "roadmap_idea_events", key: "retention.roadmap_idea_events.days", def: 730,
    archive: "roadmap_idea_events", quietUnbound: true,
    ids: "SELECT id FROM roadmap_idea_events WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM roadmap_idea_events WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM roadmap_idea_events WHERE id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "roadmap_waves.closed", table: "roadmap_waves", key: "retention.roadmap_waves.days", def: 365,
    archive: "roadmap_waves", quietUnbound: true,
    ids: "SELECT id FROM roadmap_waves WHERE status IN ('rejected','failed') AND updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    sel: "SELECT * FROM roadmap_waves WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM roadmap_waves WHERE id IN (SELECT value FROM json_each(?1)) AND status IN ('rejected','failed')",
  },
];
