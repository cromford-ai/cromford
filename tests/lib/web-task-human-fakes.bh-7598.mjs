// tests/lib/web-task-human-fakes.bh-7598.mjs — the local fakes for
// tests/web-task-human.bh-7598-test.sh: a fake Telegram Bot API and the 2FA
// fixture site, in one HTTP server on 127.0.0.1. Never a real vendor.
//
//   node web-task-human-fakes.bh-7598.mjs <calls.jsonl> <bot-token> <site-code>
//
// Fake Telegram (bin/lib/web-human/telegram.sh points WEB_HUMAN_TG_API here):
//   POST /bot<token>/sendMessage and /bot<token>/sendPhoto (multipart or JSON)
//   append ONE line per call to <calls.jsonl>: {n, method, token_ok, chat_id,
//   has_photo, text, reply_markup}. The bot token itself is never recorded.
//   Answer {ok:true, result:{message_id: 100+n}}; a wrong token is 401.
//   POST /__fail_next makes the next send answer 400 {ok:false}.
// The 2FA fixture site:
//   GET /login    200 "Enter the code we sent to your phone"
//   POST /verify  form body code=<c>: 200 "signed in" when c is <site-code>
//                 (the code only the test human knows), else 401 "wrong code".
//
// Prints the port on stdout once it listens. Exits on its own after 180 s.
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';

const [, , calls, botToken, siteCode] = process.argv;
let n = 0;
let failNext = false;

async function send(method, token, headers, raw) {
  const req = new Request('http://fake.invalid/', { method: 'POST', headers: { 'content-type': headers['content-type'] || '' }, body: raw });
  let chat = null, text = null, markup = null, photo = false;
  if (/^multipart\/form-data/.test(headers['content-type'] || '')) {
    const f = await req.formData();
    chat = f.get('chat_id'); text = f.get(method === 'sendPhoto' ? 'caption' : 'text'); markup = f.get('reply_markup');
    const p = f.get('photo');
    photo = !!(p && typeof p === 'object' && p.size > 0);
  } else {
    const b = await req.json();
    chat = b.chat_id === undefined ? null : String(b.chat_id); text = (method === 'sendPhoto' ? b.caption : b.text) ?? null; markup = b.reply_markup ?? null;
  }
  if (typeof markup === 'string') { try { markup = JSON.parse(markup); } catch { /* recorded as given */ } }
  n += 1;
  const rec = { n, method, token_ok: token === botToken, chat_id: chat, has_photo: photo, text, reply_markup: markup };
  appendFileSync(calls, `${JSON.stringify(rec)}\n`);
  if (token !== botToken) return [401, { ok: false, error_code: 401, description: 'Unauthorized' }];
  if (failNext) { failNext = false; return [400, { ok: false, error_code: 400, description: 'Bad Request: fixture failure' }]; }
  return [200, { ok: true, result: { message_id: 100 + n } }];
}

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    const raw = Buffer.concat(chunks);
    let code = 404, out = 'not found', type = 'text/plain';
    try {
      const m = /^\/bot([^/]+)\/(sendMessage|sendPhoto)$/.exec(req.url);
      if (m && req.method === 'POST') {
        const [c, o] = await send(m[2], m[1], req.headers, raw);
        code = c; out = JSON.stringify(o); type = 'application/json';
      } else if (req.url === '/__fail_next' && req.method === 'POST') {
        failNext = true; code = 200; out = 'ok';
      } else if (req.url === '/login' && req.method === 'GET') {
        code = 200; out = 'Enter the code we sent to your phone';
      } else if (req.url === '/verify' && req.method === 'POST') {
        const got = new URLSearchParams(raw.toString('utf8')).get('code');
        [code, out] = got === siteCode ? [200, 'signed in'] : [401, 'wrong code'];
      }
    } catch (e) { code = 500; out = String(e && e.message); }
    res.writeHead(code, { 'content-type': type });
    res.end(out);
  });
});
server.listen(0, '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
setTimeout(() => process.exit(0), 180e3).unref();
