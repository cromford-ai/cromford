// BH-7732: the otp inbox decision rule. extractCode(subject, text) on every
// MUST and MUST NOT row of the plan's Failure-modes table, and parseMime on
// each raw fixture (the bytes Email Routing hands the worker, CRLF lines).
//   C1 MUST match rows      C2 MUST NOT match rows (near misses)
//   C3 subject first, then body; nearest candidate wins; digits win a tie
//   M1-M6 parseMime on each fixture, then extractCode on its result
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const { extractCode } = await import('../src/code.js').catch(() => ({}));
const { parseMime } = await import('../src/mime.js').catch(() => ({}));
const FIX = new URL('./fixtures/', import.meta.url);
// The fixtures are stored with LF lines; real mail arrives with CRLF.
const eml = (name) => new Uint8Array(Buffer.from(readFileSync(new URL(name, FIX), 'utf8').replace(/\r?\n/g, '\r\n'), 'utf8'));

const MUST = [
  ['', 'Your verification code is 482913', '482913'],
  ['482913 is your Acme code', '', '482913'],
  ['', 'Use code 123 456 to sign in', '123456'],
  ['', 'Use code 123-456 to sign in', '123456'],
  ['G-551204 is your Google verification code', '', '551204'],
  ['', 'Your one-time passcode: K7Q2ZP', 'K7Q2ZP'],
  ['', 'Your login code:\n\n  604281\n\nIt expires in 10 minutes.', '604281'],
  ['', 'Your code is 482913 - expires in 10 minutes', '482913'],
  ['', 'PIN: 4417', '4417'],
  ['Sign in to Example', 'Welcome back! Enter this to continue:\n730415\nThanks', '730415'],
];
const MUST_NOT = [
  'Enter your ZIP code 94107',
  'Use promo code SAVE20',
  'Order #12345678 confirmed, your code ships soon',
  'Call +1 415 555 0123 for a code',
  'Code sent Oct 20, 2026',
  'code valid until 12:30',
  'Your code request on 2026-10-20 was received',
  '.c1{color:#FF5733} our news, no code here',
  'Open https://x.test/verify/839201 to finish',
  'Total $1234 code',
  'Tracking code 1234567890 is on its way',
  'Use promo code SAVE20.\nOrder #12345678 confirmed, your code ships soon.',
  'Your code costs 1,250.00 this month',
  'Write to support+839201@x.test for a code',
];

test('C1 every MUST row returns its code with status code', () => {
  assert.equal(typeof extractCode, 'function', 'src/code.js exports extractCode');
  for (const [subject, text, want] of MUST) {
    assert.deepEqual(extractCode(subject, text), { code: want, status: 'code' }, `subject=${JSON.stringify(subject)} text=${JSON.stringify(text)}`);
  }
});

test('C2 every MUST NOT row returns no_code', () => {
  assert.equal(typeof extractCode, 'function', 'src/code.js exports extractCode');
  for (const text of MUST_NOT) {
    assert.deepEqual(extractCode('Your account', text), { code: null, status: 'no_code' }, JSON.stringify(text));
  }
  assert.deepEqual(extractCode('', ''), { code: null, status: 'no_code' });
  assert.deepEqual(extractCode(null, undefined), { code: null, status: 'no_code' });
});

test('C3 the subject wins over the body, the nearest candidate wins, digits win a tie', () => {
  assert.equal(typeof extractCode, 'function', 'src/code.js exports extractCode');
  assert.equal(extractCode('Your code is 111222', 'Your code is 333444').code, '111222');
  assert.equal(extractCode('', 'Your code, from team ZX9Q77, is 482913').code, 'ZX9Q77', 'nearest wins, even over digits further away');
  assert.equal(extractCode('', 'ref 777888 ... and your code 482913').code, '482913');
  assert.equal(extractCode('', 'AB12CD code 482913').code, '482913', 'equal distance: digits win');
});

test('M1 code-plain.eml: headers, text and the code', () => {
  assert.equal(typeof parseMime, 'function', 'src/mime.js exports parseMime');
  const m = parseMime(eml('code-plain.eml'));
  assert.equal(m.headers.get('subject'), 'Your Acme sign-in');
  assert.equal(m.headers.get('message-id'), '<fixture-plain-1@vendor.example.test>');
  assert.match(m.text, /Your verification code is 482913\./);
  assert.equal(extractCode(m.headers.get('subject'), m.text).code, '482913');
});

test('M2 code-html-base64.eml: a base64 HTML-only body, style dropped, entities decoded, the code alone in a cell', () => {
  assert.equal(typeof parseMime, 'function', 'src/mime.js exports parseMime');
  const m = parseMime(eml('code-html-base64.eml'));
  assert.equal(m.text, '');
  assert.match(m.html, /<td>730415<\/td>/);
  const r = extractCode(m.headers.get('subject'), m.bodyText);
  assert.doesNotMatch(m.bodyText, /font-size|<td>/);
  assert.match(m.bodyText, /Thanks & see you soon\./);
  assert.equal(r.code, '730415');
});

test('M3 code-qp.eml: quoted-printable soft breaks join the code; Q-encoded latin1 subject', () => {
  assert.equal(typeof parseMime, 'function', 'src/mime.js exports parseMime');
  const m = parseMime(eml('code-qp.eml'));
  assert.equal(m.headers.get('subject'), "Votre code d'accès");
  assert.match(m.text, /voilà votre information/);
  assert.match(m.text, /passcode is 551820\. Use it within 10 minutes\. a=b/);
  assert.equal(extractCode(m.headers.get('subject'), m.bodyText).code, '551820');
});

test('M4 code-subject.eml: B-encoded subject, multipart/alternative text/plain part', () => {
  assert.equal(typeof parseMime, 'function', 'src/mime.js exports parseMime');
  const m = parseMime(eml('code-subject.eml'));
  assert.equal(m.headers.get('subject'), '391027 is your Acme code');
  assert.equal(m.text.trim(), 'Your login code: 391027');
  assert.match(m.html, /<b>391027<\/b>/);
  assert.equal(m.bodyText.trim(), 'Your login code: 391027', 'text/plain is the body text when it exists');
  assert.equal(extractCode(m.headers.get('subject'), m.bodyText).code, '391027');
});

test('M5 newsletter-no-code.eml: nested multipart, attachment skipped, no code', () => {
  assert.equal(typeof parseMime, 'function', 'src/mime.js exports parseMime');
  const m = parseMime(eml('newsletter-no-code.eml'));
  assert.match(m.bodyText, /Use promo code SAVE20 at checkout\./);
  assert.doesNotMatch(m.bodyText, /FF5733|var x|999999/);
  assert.deepEqual(extractCode(m.headers.get('subject'), m.bodyText), { code: null, status: 'no_code' });
});

test('M6 no-message-id.eml: no Message-ID header, an alphanumeric code', () => {
  assert.equal(typeof parseMime, 'function', 'src/mime.js exports parseMime');
  const m = parseMime(eml('no-message-id.eml'));
  assert.equal(m.headers.get('message-id'), undefined);
  assert.equal(extractCode(m.headers.get('subject'), m.bodyText).code, 'K7Q2ZP');
});
