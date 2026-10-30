export const COST_ARCHIVE_FLOOR_DAYS = 60;

export default [
  {
    // BH-6774: cost rows older than the window MOVE to the archive store. The
    // id is the rowid (the key is (box, row_hash)); the read is the ts index.
    rule: "cost_rows.archive", table: "cost_rows", key: "retention.cost_rows.archive_days", def: 0,
    // The floor is the widest window of a hot-only cost_rows reader
    // (test/archive-readers.d/*.json: triage-waste.js, 60 d). Every wide reader
    // reads the archive too (lib/archive-read.js). A window below 60 runs as 60.
    floorDays: COST_ARCHIVE_FLOOR_DAYS,
    archive: "cost_rows",
    ids: "SELECT rowid AS id FROM cost_rows WHERE ts < ?1 ORDER BY ts LIMIT ?2",
    sel: "SELECT * FROM cost_rows WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM cost_rows WHERE rowid IN (SELECT value FROM json_each(?1))",
  },
];
