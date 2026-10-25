// tests/lib/web-write-site.bh-7599.mjs — a fixture site on 127.0.0.1 for
// tests/web-task-write.bh-7599-test.sh, so the write gate
// (bin/lib/web-write-step.mjs) is proven against real HTTP writes.
//
//   node web-write-site.bh-7599.mjs <count-file> <log>
//
// Routes:
//   GET  /settings   a settings form: a text input `theme` and a `Save` submit,
//                    posts to /settings. (The shared fake page parses only
//                    form, input and button tags, so the setting is an input.)
//   POST /settings   stores the theme, appends `settings` to <count-file>,
//                    303 to /settings.
//   GET  /checkout   a card form: an input with autocomplete="cc-number" and a
//                    `Pay` submit, posts to /checkout.
//   POST /checkout   appends `checkout` to <count-file>, 200 "Paid".
//   GET  /state      JSON { settings, checkout, theme }: the POST counts read
//                    from <count-file> and the stored theme.
//
// Prints the port on stdout once it listens. Every request appends one line
// `<METHOD> <path> <status>` to <log>; a body is never logged. Exits on its
// own after 180 s.
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';

const [, , countFile, log] = process.argv;
let theme = 'fixture-theme-light';

const page = (title, body) => `<!doctype html><html><head><title>${title}</title></head><body>${body}</body></html>`;
const settingsForm = () => page('Settings', `<p>Theme: ${theme}</p><form method="post" action="/settings">
<input name="theme" type="text">
<button type="submit">Save</button></form>`);
const checkoutForm = () => page('Checkout', `<form method="post" action="/checkout">
<input name="card" autocomplete="cc-number" type="text">
<button type="submit">Pay</button></form>`);

function counts() {
  let lines = [];
  try { lines = readFileSync(countFile, 'utf8').split('\n').filter(Boolean); } catch { lines = []; }
  return { settings: lines.filter((l) => l === 'settings').length, checkout: lines.filter((l) => l === 'checkout').length };
}

function route(method, path, body) {
  if (method === 'GET' && path === '/settings') return [200, { 'content-type': 'text/html' }, settingsForm()];
  if (method === 'POST' && path === '/settings') {
    theme = new URLSearchParams(body).get('theme') || theme;
    appendFileSync(countFile, 'settings\n');
    return [303, { location: '/settings' }, ''];
  }
  if (method === 'GET' && path === '/checkout') return [200, { 'content-type': 'text/html' }, checkoutForm()];
  if (method === 'POST' && path === '/checkout') {
    appendFileSync(countFile, 'checkout\n');
    return [200, { 'content-type': 'text/html' }, page('Paid', '<p>Paid</p>')];
  }
  if (method === 'GET' && path === '/state') return [200, { 'content-type': 'application/json' }, JSON.stringify({ ...counts(), theme })];
  return [404, {}, 'not found'];
}

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const path = new URL(req.url, 'http://127.0.0.1').pathname;
    const [status, headers, out] = route(req.method, path, body);
    appendFileSync(log, `${req.method} ${path} ${status}\n`);
    res.writeHead(status, headers);
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { console.log(server.address().port); });
setTimeout(() => process.exit(0), 180000).unref();
