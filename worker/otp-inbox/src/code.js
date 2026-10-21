// The otp inbox decision rule (BH-7732): which token in a vendor email is the
// one-time code. Every MUST and MUST NOT row is a case in
// test/code.bh-7732.test.js.
//
// extractCode(subject, text) -> { code, status }  status 'code' | 'no_code'
//   1. Remove URLs, email addresses, ISO and slash dates and HH:MM times.
//   2. Find keyword hits (KEYWORDS). A "code" hit that is part of a zip,
//      postal, promo, discount, coupon, referral or area code is skipped, and
//      the token right after it can never be the code.
//   3. Candidates: a 4-8 digit run ("123 456" and "123-456" join to one), a
//      `G-123456` (its digits), a 4-8 char token of capital letters AND
//      digits. Rejected: a token after # $ € £ + or /, a part of a longer
//      number (9+ digits, a phone, an amount), a year next to a month name.
//   4. The candidate nearest to a keyword (60 chars before, 80 after) wins;
//      on a tie, digits win. The subject is searched first, then the body.
//   5. With no keyword candidate: a body line whose only content is a 4-8
//      digit token (not a year). Else no_code.

const KEYWORDS = [
  "authentication code", "confirmation code", "verification", "security code", "sign-in code", "login code",
  "access code", "one-time", "passcode", "verify", "code", "otp", "pin",
];
const KEYWORD_RE = new RegExp(`\\b(?:${KEYWORDS.join("|")})\\b`, "gi");
const NEGATED_RE = /\b(?:zip|postal|promo|discount|coupon|referral|area)\s*$/i;
const MONTH_RE = /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b/i;
const BEFORE = 60;
const AFTER = 80;

// Text with no URL, address, date or time left in it. Each removal keeps the
// string length the same, so a distance means the same as in the input.
function clean(s) {
  const blank = (m) => " ".repeat(m.length);
  return String(s || "")
    .replace(/\b(?:https?:\/\/|www\.)\S+/gi, blank)
    .replace(/[^\s<>()"',;:]+@[^\s<>()"',;:]+\.[a-z]{2,}/gi, blank)
    .replace(/\b\d{4}-\d\d-\d\d(?:[T ]\d\d:\d\d(?::\d\d)?Z?)?\b/g, blank)
    .replace(/\b\d{1,2}\/\d{1,2}\/\d{2,4}\b/g, blank)
    .replace(/\b\d{1,2}:\d\d(?::\d\d)?\b/g, blank);
}

const isWord = (c) => !!c && /\w/.test(c);
const isDigit = (c) => !!c && /\d/.test(c);
const yearByMonth = (s, start, end, v) =>
  v.length === 4 && +v >= 1900 && +v <= 2099 && MONTH_RE.test(s.slice(Math.max(0, start - 12), end + 12));

// Every candidate token in s as { start, end, value, digits }.
function candidates(s) {
  const out = [];
  const taken = [];
  for (const m of s.matchAll(/\b[A-Z]-(\d{4,8})\b/g)) {
    out.push({ start: m.index, end: m.index + m[0].length, value: m[1], digits: true });
    taken.push([m.index, m.index + m[0].length]);
  }
  const overlaps = (a, b) => taken.some(([x, y]) => a < y && b > x);
  for (const m of s.matchAll(/\d+(?:[ -]\d+)*/g)) {
    const run = m[0], start = m.index, end = start + run.length;
    if (overlaps(start, end)) continue;
    const p = s[start - 1], p2 = s[start - 2], n = s[end], n2 = s[end + 1];
    if (p && "#$€£+/".includes(p)) continue;
    if (isWord(p) || (p === "-" && isWord(p2)) || ((p === "." || p === ",") && isDigit(p2))) continue;
    if (isWord(n) || n === "%" || (n && ".,/".includes(n) && isDigit(n2))) continue;
    const groups = run.split(/[ -]/);
    const add = (v, a, b) => { if (v.length >= 4 && v.length <= 8 && !yearByMonth(s, a, b, v)) out.push({ start: a, end: b, value: v, digits: true }); };
    if (groups.length === 1) { add(run, start, end); continue; }
    const joined = groups.join("");
    if (groups.every((g) => g.length >= 3 && g.length <= 4) && joined.length >= 6 && joined.length <= 8) { add(joined, start, end); continue; }
    // "482913 10 minutes": two space-separated groups are two tokens. Three
    // or more groups, or a dash, is a phone, a date or an id: never a code.
    if (groups.length === 2 && !run.includes("-")) {
      add(groups[0], start, start + groups[0].length);
      add(groups[1], end - groups[1].length, end);
    }
  }
  for (const m of s.matchAll(/(?<![\w#$€£+/-])(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]{4,8}(?![\w])/g)) {
    out.push({ start: m.index, end: m.index + m[0].length, value: m[0], digits: false });
  }
  return out;
}

// The keyword candidate nearest to a hit in one text, or null.
function nearest(raw) {
  const s = clean(raw);
  const cands = candidates(s);
  const banned = [];
  const hits = [];
  for (const m of s.matchAll(KEYWORD_RE)) {
    const start = m.index, end = start + m[0].length;
    if (/code$/i.test(m[0]) && NEGATED_RE.test(s.slice(Math.max(0, start - 20), start))) { banned.push([end, end + 4]); continue; }
    hits.push([start, end]);
  }
  let best = null;
  for (const c of cands) {
    if (banned.some(([a, b]) => c.start >= a && c.start <= b)) continue;
    for (const [hs, he] of hits) {
      let d = null;
      if (c.end <= hs && hs - c.end <= BEFORE) d = hs - c.end;
      else if (c.start >= he && c.start - he <= AFTER) d = c.start - he;
      if (d === null) continue;
      if (!best || d < best.d || (d === best.d && c.digits && !best.c.digits)) best = { d, c };
    }
  }
  return best ? best.c.value : null;
}

// A body line that is only a 4-8 digit token (not a year).
function loneLine(raw) {
  for (const line of clean(raw).split(/\r?\n/)) {
    const v = line.trim();
    if (/^\d{4,8}$/.test(v) && !(v.length === 4 && +v >= 1900 && +v <= 2099)) return v;
  }
  return null;
}

export function extractCode(subject, text) {
  const code = nearest(subject) ?? nearest(text) ?? loneLine(text);
  return code ? { code, status: "code" } : { code: null, status: "no_code" };
}
