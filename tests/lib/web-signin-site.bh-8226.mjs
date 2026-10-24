// tests/lib/web-signin-site.bh-8226.mjs — a fixture sign-in site on 127.0.0.1
// for tests/web-signin-step.bh-8226-test.sh, so createSignIn
// (bin/lib/web-signin-step.mjs) signs in over real HTTP.
//
//   node web-signin-site.bh-8226.mjs <cred-file> <log>
//
// <cred-file> (mode 600, made by the suite) holds two lines: the fixture
// username and the fixture password. They never go on argv.
//
// Routes:
//   GET  /one        a one-page form: username + password + submit, posts to /login
//   GET  /two        step 1 of a two-step form: username + submit, posts to /two/user
//   POST /two/user   keeps the username in the `pending` cookie, 303 to /two/pass
//   GET  /two/pass   step 2: password + submit, posts to /login
//   GET  /plain      a page with no form
//   POST /login      right username and password: sets the `session` cookie, 303
//                    to /welcome. Else 200 with the /one form again and an error line.
//   GET  /welcome    with the session cookie: "Welcome", no password input.
//                    Without it: 303 to /one.
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>; a body or a cookie is never logged.
// Exits on its own after 180 s.
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';

const [, , credFile, log] = process.argv;
const [USER, PASS] = readFileSync(credFile, 'utf8').split('\n');
const SESSION = 'fixture-session-8226';

const page = (title, body) => `<!doctype html><html><head><title>${title}</title></head><body>${body}</body></html>`;
const formOne = (err = '') => page('Sign in', `${err}<form method="post" action="/login">
<input name="username" autocomplete="username" type="text">
<input name="password" type="password">
<button type="submit">Sign in</button></form>`);
const formTwoUser = () => page('Sign in', `<form method="post" action="/two/user">
<input name="username" type="email">
<input type="submit" value="Next"></form>`);
const formTwoPass = () => page('Sign in', `<form method="post" action="/login">
<input name="password" type="password">
<button type="submit">Sign in</button></form>`);

function cookies(req) {
  const out = {};
  for (const part of String(req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function route(method, path, req, body) {
  const c = cookies(req);
  const form = new URLSearchParams(body);
  if (method === 'GET' && path === '/one') return [200, {}, formOne()];
  if (method === 'GET' && path === '/two') return [200, {}, formTwoUser()];
  if (method === 'POST' && path === '/two/user') {
    return [303, { location: '/two/pass', 'set-cookie': `pending=${encodeURIComponent(form.get('username') || '')}; Path=/` }, ''];
  }
  if (method === 'GET' && path === '/two/pass') return [200, {}, formTwoPass()];
  if (method === 'GET' && path === '/plain') return [200, {}, page('Plain', '<p>No form here.</p>')];
  if (method === 'POST' && path === '/login') {
    const user = form.has('username') ? form.get('username') : c.pending;
    if (user === USER && form.get('password') === PASS) {
      return [303, { location: '/welcome', 'set-cookie': `session=${SESSION}; Path=/; HttpOnly` }, ''];
    }
    return [200, {}, formOne('<p class="error">Wrong username or password.</p>')];
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
