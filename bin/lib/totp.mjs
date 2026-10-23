// bin/lib/totp.mjs — RFC 6238 TOTP codes for the web-task lane (BH-7596).
// Pure: node:crypto only, no network, no file, no state.
//
//   node bin/lib/totp.mjs code [--digits N] [--step S] [--algorithm A]
//     Reads the base32 secret from STDIN ONLY and prints the code with no
//     newline, rc 0. Defaults: 6 digits, 30 s step, sha1 (the RFC defaults).
//     Digits 6..10, step an integer >= 1, algorithm sha1|sha256|sha512.
//     These are the bounds of the format, not tunable limits: 6 is the
//     RFC 4226 minimum and 10 is the most digits a 31-bit value has.
//   node bin/lib/totp.mjs next-window [--step S]
//     Prints the seconds left in the current step (1..S), for a retry that
//     waits for the next code.
//   Bad input: rc 2 and one stderr line `totp: bad <parameter>`. The line
//   names the parameter, never its value, so the secret is never printed.
//   The clock is env TOTP_NOW (unix seconds, an integer), else Date.now().
//
// The secret may be in groups, lower case, with `-` and `=` padding at the
// end (as sites show it under "can't scan the QR code"): spaces and `-` are
// dropped, trailing `=` is dropped, then it is upper-cased (RFC 4648 base32).
import { createHmac } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const ALGORITHMS = ['sha1', 'sha256', 'sha512'];

export class TotpInputError extends Error {
  constructor(param) { super(`totp: bad ${param}`); this.param = param; }
}

// base32Decode(s) — a Buffer, or a TotpInputError('secret') for anything that
// is not base32 after the normalization above (the message holds no input).
export function base32Decode(s) {
  const t = String(s).replace(/[\s-]+/g, '').replace(/=+$/, '').toUpperCase();
  if (!t || !/^[A-Z2-7]+$/.test(t)) throw new TotpInputError('secret');
  let bits = 0; let acc = 0; const out = [];
  for (const c of t) {
    acc = ((acc << 5) | ALPHABET.indexOf(c)) & 0xffff;
    bits += 5;
    if (bits >= 8) { bits -= 8; out.push((acc >>> bits) & 0xff); }
  }
  return Buffer.from(out);
}

const digitsOk = (v) => Number.isInteger(v) && v >= 6 && v <= 10;
const stepOk = (v) => Number.isSafeInteger(v) && v >= 1;
const atOk = (v) => Number.isSafeInteger(v) && v >= 0;

// totp({key, at, step, digits, algorithm}) — the code as a zero-padded string.
// key is a Buffer, at is unix seconds.
export function totp({ key, at, step = 30, digits = 6, algorithm = 'sha1' }) {
  if (!digitsOk(digits)) throw new TotpInputError('digits');
  if (!stepOk(step)) throw new TotpInputError('step');
  if (!ALGORITHMS.includes(algorithm)) throw new TotpInputError('algorithm');
  if (!atOk(at)) throw new TotpInputError('TOTP_NOW');
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(at / step)));
  const h = createHmac(algorithm, key).update(counter).digest();
  const off = h[h.length - 1] & 0x0f; // RFC 4226 section 5.3 dynamic truncation
  const bin = ((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3];
  return String(bin % 10 ** digits).padStart(digits, '0');
}

// secondsToNextStep(at, step) — seconds left in the step that holds `at`.
export function secondsToNextStep(at, step = 30) {
  if (!stepOk(step)) throw new TotpInputError('step');
  if (!atOk(at)) throw new TotpInputError('TOTP_NOW');
  return step - (at % step);
}

function now() {
  const raw = process.env.TOTP_NOW;
  if (raw === undefined || raw === '') return Math.floor(Date.now() / 1000);
  if (!/^\d{1,15}$/.test(raw)) throw new TotpInputError('TOTP_NOW');
  return Number(raw);
}

// The flags of a verb: --name value pairs from `allowed`; anything else is
// `bad argument` (a stray word may be a secret typed on argv: never echo it).
function flags(argv, allowed) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const name = argv[i].startsWith('--') ? argv[i].slice(2) : '';
    if (!allowed.includes(name)) throw new TotpInputError('argument');
    if (i + 1 >= argv.length) throw new TotpInputError(name);
    out[name] = argv[i + 1];
  }
  return out;
}
const asInt = (v, param) => {
  if (v === undefined) return undefined;
  if (!/^\d+$/.test(v) || !Number.isSafeInteger(Number(v))) throw new TotpInputError(param);
  return Number(v);
};

function main(argv) {
  const [verb, ...rest] = argv;
  if (verb === 'code') {
    const f = flags(rest, ['digits', 'step', 'algorithm']);
    const digits = asInt(f.digits, 'digits'); const step = asInt(f.step, 'step');
    const algorithm = f.algorithm === undefined ? undefined : f.algorithm.toLowerCase();
    if (algorithm !== undefined && !ALGORITHMS.includes(algorithm)) throw new TotpInputError('algorithm');
    if (digits !== undefined && !digitsOk(digits)) throw new TotpInputError('digits');
    if (step !== undefined && !stepOk(step)) throw new TotpInputError('step');
    const at = now();
    const key = base32Decode(readFileSync(0, 'utf8'));
    process.stdout.write(totp({ key, at, step, digits, algorithm }));
    return 0;
  }
  if (verb === 'next-window') {
    const f = flags(rest, ['step']);
    process.stdout.write(`${secondsToNextStep(now(), asInt(f.step, 'step'))}\n`);
    return 0;
  }
  process.stderr.write('totp: usage: totp.mjs code [--digits N] [--step S] [--algorithm A] | next-window [--step S]\n');
  return 2;
}

// Node resolves import.meta.url to the real path; argv[1] keeps a symlinked
// path (/root/harness -> /data/harness), so compare the real paths.
const isMain = (() => {
  try { return Boolean(process.argv[1]) && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href; }
  catch { return false; }
})();
if (isMain) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(e instanceof TotpInputError ? `${e.message}\n` : 'totp: failed\n');
    process.exitCode = e instanceof TotpInputError ? 2 : 1;
  }
}
