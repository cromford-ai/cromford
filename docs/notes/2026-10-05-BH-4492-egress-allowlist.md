# BH-4492: egress allowlist per build stage (wave 5 of BH-4475)

Doc: AGENT-CALL

**What changed.** A build-stage call can now reach only the hosts its settings
row lists. When `bin/agent-call.sh` runs a stage whose `$OUT` is in a build dir
and the stage has an `egress.stage.<stage>.hosts` row, `run_attempt` launches
the runner CLI inside its own network namespace (`unshare -n`, or `unshare -rn`
when not root). Inside it there is only loopback. The one way out is
`bin/egress-proxy.py`, started outside the namespace for that call. It allows
`CONNECT` and plain `http://` requests to the listed hosts, and answers 403 to
anything else. The runner gets `HTTPS_PROXY`/`HTTP_PROXY` (and the npm
spellings) pointed at it, and runs with `CAP_SYS_ADMIN` and `CAP_NET_ADMIN`
dropped, so a root agent cannot `nsenter` back out or rewire the namespace.
This is the same code on Fly pool builders and Orgo boxes.

**The rows** (seeded in `worker/jobs/schema.sql`, actor `seed`,
`INSERT OR IGNORE`, so a deploy never resets an edit):

- `egress.stage.execute.hosts`: the model APIs (`api.anthropic.com
  platform.claude.com api.x.ai api.openai.com chatgpt.com auth.openai.com
  openrouter.ai api.fireworks.ai generativelanguage.googleapis.com`) plus
  `registry.npmjs.org registry.yarnpkg.com pypi.org files.pythonhosted.org`.
  `auth.openai.com` is there because codex on a ChatGPT login
  (`~/.codex/auth.json`) refreshes its token there. `platform.claude.com` is
  the same thing for a Claude account on a `CLAUDE_CONFIG_DIR` login
  (`bin/lib/orc-account.sh`): Claude Code 2.1.289 refreshes at
  `https://platform.claude.com/v1/oauth/token`. Without either one, that
  runner fails once a refresh is due. `api.fireworks.ai` is the tier-3b
  survival lane (codex with a Fireworks `base_url`), and a build stage can
  reach it. `worker/jobs/test/egress-seed.bh-4492.test.js` reads every
  `base_url` host out of `bin/agent-call.sh` and fails if a row is missing
  one.
- `egress.stage.review.hosts`: the model APIs only.

`plan`, `fix` and `qa` have no row, so they run unfenced. Add a row to fence
one; no code change. To edit: `PUT /api/settings` with the key above, or the
console settings screen. The value is a space or comma list of `host` (ports
443 and 80), `*.suffix` (subdomains only, never the bare name) or `host:port`
(that port only), up to 256 characters. `off` turns the stage's fence off.

**Four states**, one line per call in `$BUILD/egress-state.txt`:

- `enforced`: the fence was up. `source=row`, or `source=fallback:<why>`
  when the row could not be read.
- `not-armed`: no settings cache, no row, or `off`. The call runs exactly as
  before. Calls outside a build dir (triage, chat) write nothing.
- unreadable: a settings cache that is not JSON with `.values`, or a row with an
  invalid entry or no entries. This FAILS CLOSED to `EG_FALLBACK_HOSTS` in
  `bin/lib/egress.sh`: the seeded model hosts minus gemini's (no build stage
  runs on gemini), so no registry is reachable. It is
  recorded as `enforced` with `source=fallback:settings-unreadable` or
  `fallback:row-unreadable:<key>`. One bad entry voids the whole row.
- `not-enforced`: the box cannot fence (`no-unshare`, `unshare-refused`,
  `no-python3`, `no-proxy-script`, `proxy-not-up`). The call runs with open
  network, and ONE `EGRESS ALLOWLIST NOT ENFORCED` line goes to `ALERTS.log`
  per box, stage and day (flag `flags/alerted-egress-unenforceable-<stage>-<yyyymmdd>`).
  The fence never refuses a call.

**Logs.** `$BUILD/egress.log` holds `DENY <host>:<port> via=proxy` (a refused
proxy request) and `DENY-DIRECT <ip>:<port> via=direct` (a connect that ignored
the proxy env, caught on ports 80/443 inside the namespace). Each line is tagged
`stage=` and `id=<call>`. At most 500 DENY lines per process, then one
`DENY-CAPPED`; the `END allow= deny=` counts stay exact. Only host:port is
logged, never a request line, header or body.

**Evidence block.** `bin/evidence-summary.sh` adds an `egress allowlist` row
when `egress-state.txt` exists: the state per stage, the refusal count, and up
to 10 distinct refused targets with their stage. `NOT ENFORCED` is printed in
capitals. Without the file, the render is unchanged.

**Known effects.** An execute agent can no longer reach github.com (`git
fetch`, the gitleaks download), api.fly.io (`bin/remote-gate.sh`) or doc sites
unless the row adds them. Claude Code's own telemetry hosts are refused too
(nothing on the fleet sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`); the CLI
carries on without them. Those refusals now show on the PR. Widen the row if a
host turns out to be needed.

**Not covered.** DNS is not proxied. A resolver on the namespace's own loopback
is dead, and the runners reach hosts by name through the proxy. A client that
puts a different name in TLS SNI than in its `CONNECT` (domain fronting) is not
detected. A direct connect to a port other than 80/443 is refused by the kernel
but not logged. An outer `HTTPS_PROXY` in the box env is overridden for the
stage; the proxy itself connects directly. The credential broker is a later
wave.

Pinned by `tests/egress-allowlist-test.sh` (the namespace cases need root or
user namespaces; elsewhere they print SKIP and name the test host) and
`worker/jobs/test/egress-seed.bh-4492.test.js`.
