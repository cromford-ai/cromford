// A minimal MIME reader for the otp inbox (BH-7732). No dependency, so the
// worker bundles as one file and node --test drives it directly.
//
// parseMime(raw) -> { headers, text, html, bodyText }
//   raw       the message bytes (Uint8Array) or a string.
//   headers   Map: lowercase header name -> its first value, unfolded, with
//             RFC 2047 encoded words decoded.
//   text      the first text/plain part, decoded ("" when none).
//   html      the first text/html part, decoded ("" when none).
//   bodyText  text when it has content, else html as plain text.
// Handles multipart/* to a depth of 5, base64 and quoted-printable bodies,
// and any charset TextDecoder knows (utf-8 when it does not). An attachment
// part is skipped.

const MAX_DEPTH = 5;
const utf8 = new TextDecoder("utf-8");

// bytes <-> a binary string with one char per byte.
function toBinary(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return s;
}
function fromBinary(s) {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
  return out;
}

function decodeBytes(bytes, charset) {
  const cs = String(charset || "utf-8").trim().toLowerCase();
  try { return new TextDecoder(cs).decode(bytes); } catch { return utf8.decode(bytes); }
}

function base64Bytes(s) {
  const clean = s.replace(/[^A-Za-z0-9+/]/g, "");
  try { return fromBinary(atob(clean.slice(0, clean.length - (clean.length % 4)))); } catch { return new Uint8Array(0); }
}

// Quoted-printable (RFC 2045): `=\r\n` is a soft break, `=XX` a byte.
function qpBytes(s) {
  return fromBinary(s.replace(/=\r?\n/g, "").replace(/=([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16))));
}

// RFC 2047 encoded words: =?charset?B|Q?text?=. Whitespace between two
// adjacent encoded words is dropped.
export function decodeWords(v) {
  if (!v || v.indexOf("=?") < 0) return v || "";
  return v
    .replace(/(=\?[^?\s]+\?[BbQq]\?[^?\s]*\?=)\s+(?==\?[^?\s]+\?[BbQq]\?)/g, "$1")
    .replace(/=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/g, (_, cs, enc, text) => {
      const charset = cs.split("*")[0];
      const bytes = enc.toUpperCase() === "B"
        ? base64Bytes(text)
        : fromBinary(text.replace(/_/g, " ").replace(/=([0-9A-Fa-f]{2})/g, (__, h) => String.fromCharCode(parseInt(h, 16))));
      return decodeBytes(bytes, charset);
    });
}

// The header block (a binary string) as a Map. 8-bit header bytes are read
// as utf-8.
function parseHeaders(block) {
  const map = new Map();
  const lines = utf8.decode(fromBinary(block)).replace(/\r?\n[ \t]+/g, " ").split(/\r?\n/);
  for (const line of lines) {
    const i = line.indexOf(":");
    if (i <= 0) continue;
    const name = line.slice(0, i).trim().toLowerCase();
    if (!map.has(name)) map.set(name, decodeWords(line.slice(i + 1).trim()));
  }
  return map;
}

// "text/plain; charset=utf-8; boundary=..." -> { type, params }
function parseType(v) {
  const parts = String(v || "text/plain").split(";");
  const params = {};
  for (const p of parts.slice(1)) {
    const i = p.indexOf("=");
    if (i < 0) continue;
    params[p.slice(0, i).trim().toLowerCase()] = p.slice(i + 1).trim().replace(/^"(.*)"$/, "$1");
  }
  return { type: parts[0].trim().toLowerCase(), params };
}

function split(bin) {
  const m = /\r?\n\r?\n/.exec(bin);
  return m ? [bin.slice(0, m.index), bin.slice(m.index + m[0].length)] : [bin, ""];
}

function walk(bin, depth, out) {
  const [head, body] = split(bin);
  const headers = parseHeaders(head);
  const { type, params } = parseType(headers.get("content-type"));
  if (/^attachment\b/i.test(headers.get("content-disposition") || "")) return headers;
  if (type.startsWith("multipart/")) {
    if (depth >= MAX_DEPTH || !params.boundary) return headers;
    const delim = "--" + params.boundary;
    const chunks = body.split(delim);
    // chunks[0] is the preamble; a chunk that starts with "--" is the close.
    for (const chunk of chunks.slice(1)) {
      if (chunk.startsWith("--")) break;
      walk(chunk.replace(/^[ \t]*\r?\n/, "").replace(/\r?\n$/, ""), depth + 1, out);
    }
    return headers;
  }
  if (type !== "text/plain" && type !== "text/html") return headers;
  const cte = String(headers.get("content-transfer-encoding") || "").trim().toLowerCase();
  const bytes = cte === "base64" ? base64Bytes(body) : cte === "quoted-printable" ? qpBytes(body) : fromBinary(body);
  const text = decodeBytes(bytes, params.charset);
  if (type === "text/plain" && out.text === null) out.text = text;
  if (type === "text/html" && out.html === null) out.html = text;
  return headers;
}

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", ndash: "-", mdash: "-", copy: "(c)", zwnj: "", zwj: "" };

// HTML as plain text: style, script, head and comments dropped, block ends as
// line breaks, tags dropped, entities decoded.
export function htmlToText(html) {
  return String(html || "")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<(style|script|head|title)\b[\s\S]*?<\/\1\s*>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|tr|td|th|li|h[1-6]|table|section|center)\s*>/gi, "\n")
    .replace(/<[^>]*>/g, " ")
    .replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) => {
      if (e[0] === "#") {
        const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
        try { return String.fromCodePoint(n); } catch { return " "; }
      }
      const v = ENTITIES[e.toLowerCase()];
      return v === undefined ? m : v;
    })
    .replace(/[ \t\u00a0]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function parseMime(raw) {
  const bin = typeof raw === "string" ? toBinary(new TextEncoder().encode(raw)) : toBinary(raw || new Uint8Array(0));
  const out = { text: null, html: null };
  const headers = walk(bin, 0, out);
  const text = out.text || "";
  const html = out.html || "";
  return { headers, text, html, bodyText: text.trim() ? text : htmlToText(html) };
}
