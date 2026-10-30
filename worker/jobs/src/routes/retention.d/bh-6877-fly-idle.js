export default [
  // BH-6877: the Fly idle reaper's stop and destroy rows. They hold the $/h a
  // stop saved or a destroy avoided, so each goes into fly_idle_daily first.
  // The id reads use fly_idle_stops_stopped_at and
  // fly_idle_destroys_destroyed_at; the deletes use the PRIMARY KEY.
  {
    rule: "fly_idle_stops.age", table: "fly_idle_stops", key: "retention.fly_idle_stops.days", def: 400,
    ids: "SELECT stop_id AS id FROM fly_idle_stops WHERE stopped_at < ?1 ORDER BY stopped_at LIMIT ?2",
    rollup: `INSERT INTO fly_idle_daily (day, app, action, n, usd_per_hour_sum)
             SELECT substr(stopped_at, 1, 10), app, 'stop', COUNT(*), SUM(COALESCE(usd_per_hour, 0))
               FROM fly_idle_stops WHERE stop_id IN (SELECT value FROM json_each(?1))
              GROUP BY 1, 2
             ON CONFLICT (day, app, action) DO UPDATE SET n = n + excluded.n,
               usd_per_hour_sum = usd_per_hour_sum + excluded.usd_per_hour_sum`,
    del: "DELETE FROM fly_idle_stops WHERE stop_id IN (SELECT value FROM json_each(?1))",
  },
  {
    rule: "fly_idle_destroys.age", table: "fly_idle_destroys", key: "retention.fly_idle_destroys.days", def: 400,
    ids: "SELECT destroy_id AS id FROM fly_idle_destroys WHERE destroyed_at < ?1 ORDER BY destroyed_at LIMIT ?2",
    rollup: `INSERT INTO fly_idle_daily (day, app, action, n, usd_per_hour_sum)
             SELECT substr(destroyed_at, 1, 10), app, 'destroy', COUNT(*), SUM(COALESCE(usd_per_hour, 0))
               FROM fly_idle_destroys WHERE destroy_id IN (SELECT value FROM json_each(?1))
              GROUP BY 1, 2
             ON CONFLICT (day, app, action) DO UPDATE SET n = n + excluded.n,
               usd_per_hour_sum = usd_per_hour_sum + excluded.usd_per_hour_sum`,
    del: "DELETE FROM fly_idle_destroys WHERE destroy_id IN (SELECT value FROM json_each(?1))",
  },
];
