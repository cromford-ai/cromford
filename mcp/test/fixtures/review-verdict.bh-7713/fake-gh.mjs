// BH-7713 fixture: a stand-in for `gh api` on PATH for the end-to-end cases
// in mcp/test/review-verdict.test.mjs. It appends one JSON line per call
// ({method, path, input}) to $FAKE_LOG and answers fixture JSON for the one
// PR acme/widgets#7, whose head is $FAKE_GH_HEAD. Any other call exits 1.
import { appendFileSync, readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const mi = args.indexOf('--method');
const method = mi >= 0 ? args[mi + 1] : 'GET';
const path = args.at(-1);
const input = args.includes('--input') ? JSON.parse(readFileSync(0, 'utf8')) : undefined;
appendFileSync(process.env.FAKE_LOG, JSON.stringify({ method, path, input }) + '\n');

const P = 'repos/acme/widgets';
const answers = {
  [`GET ${P}/pulls/7`]: { number: 7, head: { sha: process.env.FAKE_GH_HEAD }, base: { repo: { full_name: 'acme/widgets' } }, labels: [] },
  [`GET ${P}/issues/7/comments?per_page=100`]: [],
  [`GET ${P}/pulls/7/reviews?per_page=100`]: [],
  [`POST ${P}/issues/7/comments`]: { id: 1, html_url: 'https://github.com/acme/widgets/pull/7#issuecomment-1' },
  [`POST ${P}/pulls/7/reviews`]: { id: 2, state: 'CHANGES_REQUESTED' },
};
const key = `${args[0]} ${method} ${path}`.replace(/^api /, '');
if (args[0] !== 'api' || !(key in answers)) {
  process.stderr.write(`fake gh: unimplemented: ${args.join(' ')}\n`);
  process.exit(1);
}
process.stdout.write(JSON.stringify(answers[key]) + '\n');
