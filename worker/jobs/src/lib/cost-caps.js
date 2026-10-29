// cost-caps — BH-2564 (BH-2511 W1): the key shapes and the value grammar a
// caps row must have for the box readers to bind it.
//
// The source of truth is the shell: _cb_row_ok (bin/lib/cost-budget.sh) and
// _lc_row_ok (bin/lib/lane-caps.sh). Everything here MIRRORS them, so a row
// the editor accepts is a row every box binds, and a row it refuses is one the
// box would have named as `row:<key>` in its legacy list and ignored.

// Both conf files' settings rows, fleet AND box-suffixed. The generic PUT
// /api/settings audits every key this matches; the editor routes take only the
// fleet shapes capFleetKey() accepts.
export const CAP_KEY_PREFIX_RE = /^conf\.(cost-caps|lane-caps)\./;

const SUBJECT_KEYS = [
  [/^conf\.cost-caps\.budget\.([a-z0-9_-]+)$/, "cost-caps", "budget"],
  // BH-7876: a project's daily ceiling, keyed project FIRST, the shape
  // _cb_row reads (`?*.daily_usd`). After `budget`, as in _cb_row, so
  // `conf.cost-caps.budget.daily_usd` stays project `daily_usd`'s budget.
  [/^conf\.cost-caps\.([a-z0-9_-]+)\.daily_usd$/, "cost-caps", "daily"],
  [/^conf\.lane-caps\.lane\.([a-z0-9_-]+)$/, "lane-caps", "lane"],
  [/^conf\.lane-caps\.noise\.([a-z0-9_-]+)$/, "lane-caps", "noise"],
];
const BARE_KEYS = new Map([
  ["conf.cost-caps.default", ["cost-caps", "default"]],
  ["conf.cost-caps.ceiling", ["cost-caps", "ceiling"]],
  ["conf.lane-caps.default", ["lane-caps", "default"]],
]);

// capFleetKey(key) -> {file, kind, subject} | null. Exactly the seven fleet
// shapes (the six of BH-2564 and BH-7876's daily ceiling), anchored: a box
// suffix (`budget.acme.hub-1`, `default.hub-1`) or any
// extra segment is null, because those rows belong to one box and the editor
// writes the fleet's value.
export function capFleetKey(key) {
  if (typeof key !== "string" || key.length > 64) return null;
  const bare = BARE_KEYS.get(key);
  if (bare) return { file: bare[0], kind: bare[1], subject: null };
  for (const [re, file, kind] of SUBJECT_KEYS) {
    const m = re.exec(key);
    if (m) return { file, kind, subject: m[1] };
  }
  return null;
}

// The four field checks, one per shell helper.
// _cb_num: digits and dots, and awk's `v+0 > 0`. awk reads the longest numeric
// prefix, which is what parseFloat does, so `1.2.3` passes in both.
const cbNum = (v) => /^[0-9.]+$/.test(v) && parseFloat(v) > 0;
// _lc_num: digits and dots with at least one digit (`.` is not a cap).
const lcNum = (v) => /^[0-9.]+$/.test(v) && /[0-9]/.test(v);
// _lc_int: a positive whole number `[ "$v" -gt 0 ]` takes, so no more than
// bash's signed 64-bit range (a larger one is an "integer expression expected").
const lcInt = (v) => /^[0-9]+$/.test(v) && BigInt(v) > 0n && BigInt(v) <= 9223372036854775807n;
// _lc_count: a non-negative whole number.
const lcCount = (v) => /^[0-9]+$/.test(v);

const GRAMMAR = {
  "cost-caps": {
    budget: [2, (a, b) => cbNum(a) && (b === "" || cbNum(b)), "<usd per PR> [min PRs], each a number > 0"],
    default: [2, (a, b) => cbNum(a) && (b === "" || cbNum(b)), "<usd per PR> [min PRs], each a number > 0"],
    ceiling: [1, (a) => cbNum(a), "one number > 0"],
    // _cb_row_ok `daily`: one number > 0 and nothing after it.
    daily: [1, (a) => cbNum(a), "one number > 0"],
  },
  "lane-caps": {
    lane: [2, (a, b) => (a === "off" || lcNum(a)) && (b === "" || lcInt(b)), "<usd|off> [bytes], usd >= 0, bytes a whole number > 0"],
    default: [2, (a, b) => (a === "off" || lcNum(a)) && (b === "" || lcInt(b)), "<usd|off> [bytes], usd >= 0, bytes a whole number > 0"],
    noise: [1, (a) => a === "off" || lcCount(a), "<count|off>, count a whole number >= 0"],
  },
};

// validateCapValue(cap, value) -> null when valid, else the error string.
// `cap` is capFleetKey()'s result: `default` is a kind in BOTH files, with two
// different grammars, so the kind alone cannot say which one applies. The
// value is split the way the readers' `read -r x y z` splits it, and a third
// field is always a refusal (the shell's `z` must be empty).
export function validateCapValue(cap, value) {
  const g = cap && GRAMMAR[cap.file]?.[cap.kind];
  if (!g) return "not a cost-caps/lane-caps key";
  if (typeof value !== "string") return "value must be a string";
  if (/[\t\n\r]/.test(value)) return "value must be one line with no tabs";
  const v = value.trim();
  if (!v) return "value must be non-empty";
  const [max, ok, want] = g;
  const fields = v.split(/ +/);
  if (fields.length > max || !ok(fields[0], fields[1] ?? "")) {
    return `${cap.file} ${cap.kind} value must be ${want}`;
  }
  return null;
}

// capChangeStmt(...) -> the prepared audit INSERT, for the SAME env.DB.batch as
// the settings upsert it records, so a row and its audit land together or not
// at all.
export function capChangeStmt(env, key, before, after, actor, reason, at) {
  return env.DB.prepare(
    "INSERT INTO cost_cap_changes (key, before_value, after_value, actor, reason, at) VALUES (?1,?2,?3,?4,?5,?6)"
  ).bind(key, before, after, actor, reason, at);
}
