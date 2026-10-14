// worker/jobs/src/lib/created-tables.js — the composed jobs schema text as the
// statements ensureTable runs, keyed by table (BH-4987).
//
// createdTablesFrom(sql) returns { <table>: [CREATE TABLE …, CREATE [UNIQUE]
// INDEX … ON <table>(…), …] } for every `CREATE TABLE IF NOT EXISTS` in the
// text, in schema order. An index statement goes under the table it is ON,
// whatever table was created just before it. Every other statement (INSERT
// seed rows, CREATE VIEW, ALTER) is ignored. Comments are dropped, and a `;`
// inside a quoted string or identifier never splits a statement.
//
// It is pure: no I/O, and it never throws on content. A statement it cannot
// classify is ignored, so the worst case is a missing key, which T1 in
// test/created-tables.bh-4987.test.js refuses.

const CREATE_TABLE = /^CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+"?(\w+)"?/i;
const CREATE_INDEX = /^CREATE\s+(?:UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+\S+\s+ON\s+"?(\w+)"?\s*\(/i;

// statementsOf(sql) — the statements of sql with comments removed, trimmed,
// empty ones dropped.
export function statementsOf(sql) {
  const out = [];
  let cur = "";
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const c = sql[i];
    if (c === "'" || c === '"') {
      // A quoted run ends at the next unpaired quote; a doubled quote is an
      // escaped one and stays inside the run.
      let j = i + 1;
      for (;;) {
        if (j >= n) break;
        if (sql[j] === c) {
          if (sql[j + 1] === c) { j += 2; continue; }
          break;
        }
        j++;
      }
      cur += sql.slice(i, j + 1);
      i = j + 1;
    } else if (c === "-" && sql[i + 1] === "-") {
      const j = sql.indexOf("\n", i);
      i = j === -1 ? n : j;
    } else if (c === "/" && sql[i + 1] === "*") {
      const j = sql.indexOf("*/", i + 2);
      i = j === -1 ? n : j + 2;
      cur += " ";
    } else if (c === ";") {
      out.push(cur);
      cur = "";
      i++;
    } else {
      cur += c;
      i++;
    }
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter((s) => s !== "");
}

export function createdTablesFrom(sql) {
  const map = {};
  for (const s of statementsOf(String(sql ?? ""))) {
    let m = CREATE_TABLE.exec(s);
    if (m) {
      if (!map[m[1]]) map[m[1]] = [];
      map[m[1]].push(s);
      continue;
    }
    m = CREATE_INDEX.exec(s);
    if (m && map[m[1]]) map[m[1]].push(s);
  }
  return map;
}
