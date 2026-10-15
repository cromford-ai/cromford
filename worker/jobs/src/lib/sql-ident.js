// A SQL identifier (a table or a column name) that goes into SQL text. D1 can
// bind a value but not a name, so a name is part of the string. This check
// makes a name that is not a plain identifier throw before it reaches the DB.
const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

export function sqlIdent(name) {
  if (typeof name !== "string" || !IDENT_RE.test(name)) {
    throw new TypeError(`not a SQL identifier: ${String(name).slice(0, 64)}`);
  }
  return name;
}
