// tests/lib/web-otp-site.bh-8172.mjs — a fixture site on 127.0.0.1 that asks
// for a TOTP code after the password, for tests/web-otp-step.bh-8172-test.sh,
// so createSignIn (bin/lib/web-signin-step.mjs) and then createOtpStep
// (bin/lib/web-otp-step.mjs) pass it over real HTTP.
//
//   node web-otp-site.bh-8172.mjs <cred-file> <log> <clock-file> [reject=<n>]
//
// <cred-file> (mode 600, made by the suite) holds three lines: the fixture
// username, the fixture password and the base32 TOTP secret. They never go on
// argv. <clock-file> holds the site's clock in unix seconds; the site reads it
// on each code check, so the suite moves time by writing the file.
// reject=<n>: the first n POST /otp are refused whatever the code (default 0).
//
// Routes:
//   GET  /one      the sign-in form: username + password + submit, posts to /login
//   POST /login    right username and password: the `pending2fa` cookie, 303 to
//                  /otp. Else 200 with the form again and an error line.
//   GET  /otp      with `pending2fa`: the one-time-code form, posts to /otp.
//                  Without it: 303 to /one.
//   POST /otp      without `pending2fa`: 303 to /one. A refused post (reject=)
//                  or a code that is not the code of the CURRENT 30 s window
//                  (bin/lib/totp.mjs at the clock-file time): 200 with the
//                  form again and "Invalid code". Right: the `session` cookie,
//                  303 to /welcome.
//   GET  /welcome  with `session`: "Welcome", no input. Without it: 303 to /one.
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>; a body, a code or a cookie is never
// logged. Exits on its own after 180 s.
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , credFile, log, clockFile, rejectArg = 'reject=0'] = process.argv;
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
const { totp, base32Decode } = await import(`${ROOT}bin/lib/totp.mjs`);
const [USER, PASS, SECRET] = readFileSync(credFile, 'utf8').split('\n');
const KEY = base32Decode(SECRET);
const PENDING = 'fixture-pending-8172';
const SESSION = 'fixture-session-8172';
let rejectLeft = Number((/^reject=(\d+)$/.exec(rejectArg) || [])[1] || 0);

const page = (title, body) => `<!doctype html><html><head><title>${title}</title></head><body>${body}</body></html>`;
const formOne = (err = '') => page('Sign in', `${err}<form method="post" action="/login">
<input name="username" autocomplete="username" type="text">
<input name="password" type="password">
<button type="submit">Sign in</button></form>`);
const formOtp = (err = '') => page('Two-step verification', `${err}<p>Enter the code from your app.</p>
<form method="post" action="/otp">
<input name="otp" autocomplete="one-time-code" inputmode="numeric">
<button type="submit">Verify</button></form>`);

function cookies(req) {
  const out = {};
  for (const part of String(req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

const clock = () => Number(readFileSync(clockFile, 'utf8').trim());

function route(method, path, req, body) {
  const c = cookies(req);
  const form = new URLSearchParams(body);
  if (method === 'GET' && path === '/one') return [200, {}, formOne()];
  if (method === 'POST' && path === '/login') {
    if (form.get('username') === USER && form.get('password') === PASS) {
      return [303, { location: '/otp', 'set-cookie': `pending2fa=${PENDING}; Path=/; HttpOnly` }, ''];
    }
    return [200, {}, formOne('<p class="error">Wrong username or password.</p>')];
  }
  if (path === '/otp') {
    if (c.pending2fa !== PENDING) return [303, { location: '/one' }, ''];
    if (method === 'GET') return [200, {}, formOtp()];
    if (method === 'POST') {
      const refused = rejectLeft > 0;
      if (refused) rejectLeft -= 1;
      if (!refused && form.get('otp') === totp({ key: KEY, at: clock() })) {
        return [303, { location: '/welcome', 'set-cookie': `session=${SESSION}; Path=/; HttpOnly` }, ''];
      }
      return [200, {}, formOtp('<p class="error">Invalid code.</p>')];
    }
  }
  if (method === 'GET' && path === '/welcome') {
    if (c.session === SESSION) return [200, {}, page('Welcome', '<h1>Welcome</h1><p>You are signed in.</p>')];
    return [303, { location: '/one' }, ''];
  }
  return [404, {}, page('Not found', '<p>Not found</p>')];
}

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    const path = new URL(req.url, 'http://127.0.0.1').pathname;
    const [status, headers, html] = route(req.method, path, req, body);
    appendFileSync(log, `${req.method} ${path} ${status}\n`);
    res.writeHead(status, { 'content-type': 'text/html; charset=utf-8', ...headers });
    res.end(html);
  });
});
server.listen(0, '127.0.0.1', () => {
  process.stdout.write(`${server.address().port}\n`);
});
setTimeout(() => process.exit(0), 180000).unref();
