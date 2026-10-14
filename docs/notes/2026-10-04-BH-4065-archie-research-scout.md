# Archie's research scout: X and web into the Ideas ledger (BH-4065, wave 4 of #3966)

Doc: DB-COORDINATION-SPEC, MODEL-ROUTES, OPERATOR-SETUP, LLM_CALL_SITES

## What changed

A new hub lane, `archie-research` (`bin/archie-research.sh`,
`cron/lanes/725-archie-research.cron`, behind `hub-lease.sh check`):

- `scan`, daily at 06:40Z. One xAI X search per topic (the `x_search` tool on
  `POST <endpoint_url xai>/v1/responses`) and one web scan (an agent-call on the
  claude runner whose only tool is WebSearch, through agent-call's new
  `AGENT_CALL_TOOLS` allowlist: no Read, no WebFetch, no MCP server, because
  the pages it reads are written by strangers). Each new find is scored "does this apply to us?" in ONE batched
  agent-call with no tools. Finds that apply and score at least
  `ARCHIE_RESEARCH_MIN_SCORE` (7) become `gate_pending` proposals in the
  existing Ideas ledger, with their source links.
- `digest`, daily at 07:10Z. It sends ONE triaged `fleet_alert` beat per ISO
  week, for the week before (akey `archie-research:digest:<week>`): the counts,
  the spend and the top five finds with links and proposal slugs, signed
  Archie. A week with nothing scored is recorded `empty` and sends nothing.

Topics (knob `ARCHIE_RESEARCH_TOPICS`): AI software factories, autonomous SDLC,
agent harnesses, improving AI dev loops, Anthropic and AI vendor releases.

## The ledger

The jobs DB table `archie_research` (`worker/jobs/schema.sql`, routes in
`worker/jobs/src/routes/archie-research.js`, bearer-gated), one row per dedupe
key, normalised once in `bin/lib/archie-research.sh`:

| key | what | bought |
|---|---|---|
| `xq:<topic>:<day>` | one X search | once per topic per UTC day |
| `wq:<day>` | the web scan | once per day |
| `x:<post id>` | an X post (x.com, twitter.com, `?s=` all fold) | scored once, ever |
| `web:<sha40 of the canonical url>` | a web page (https, no www, no utm/fbclid/gclid/ref/s/t, sorted params, no trailing /) | scored once, ever |
| `sb:<sha16>` | one scoring batch (its items and their attempt numbers) | once |
| `digest:<ISO week>` | the weekly beat | once per week |

Every billable call is preceded by `POST /api/archie-research/claim` (attempts
+1, written before the call: no claim, no call) and followed by
`POST /api/archie-research/settle`, with one of three outcomes:

- `ok` is terminal.
- `empty` is terminal. It was still billed, and the same search is never
  repeated that day.
- `failed` is retried by a later claim, up to `ARCHIE_RESEARCH_MAX_ATTEMPTS` (3).

A find is claimed before it is scored, so a post or url that has a row in any
settled state is never sent to the vendor again. A call that billed nothing
(agent-call rc 74-79) hands its attempt back (`refund`, only for the notes
`refused`, `no-route`, `not-configured`).

The table grows by about 30 rows a day (5 searches, 1 scan, up to 20 finds, 1
batch) and is never pruned.

## The cap

`ARCHIE_RESEARCH_USD_CAP_DAY`, seeded as the settings row
`lane.archie-research.archie_research_usd_cap_day = 1.00`. Before every billable
call the lane reads `GET /api/archie-research/spend?day=&reserve_usd=`. That is
the day's priced dollars plus `ARCHIE_RESEARCH_RESERVE_USD` (0.25) for every
attempt with no price (in flight, crashed, or an answer with no usage), never
$0. If spent plus one reserve (or, for an agent-call, plus its own ceiling
`ARCHIE_RESEARCH_LLM_MAX_USD` when that is higher) is over the cap, nothing more is bought that day,
and ONE ALERTS line a day says so. An unreadable ledger makes no call at all
(fail closed). The cap covers the X searches and both agent-calls. A row's
spend counts on the day of its latest claim.

## The key

`ARCHIE_XAI_API_KEY`, Archie's own xAI key, in `/etc/harness/env/global.env`
on the hub (`env-templates/lanes/377-archie-research.env.example`). The X half
uses it and nothing else. When it is unset, or equal to the grok runner's
`XAI_API_KEY` or `GROK_CODE_XAI_API_KEY`, no X call is made, no other key is
tried, and ONE ALERTS line a day says so. The web half still runs. The key goes
to curl in a 0600 header file that is removed after the call, never on argv or
in a log.

`bin/vendor-spend-pull.sh` polls `XAI_API_KEY` only, so Archie's key's spend is
not in that poll. The lane's own priced cost rows (stage `archie-xsearch`,
runner `grok`, lane `archie-research`) are the record. The vendor-side spend
limit on the key is the backstop.

## Cost rows

Each X search writes one 26-column `logs/cost.csv` row through
`cost_row_emit`. Its tokens are priced through `cost_price_tokens`, plus
`ARCHIE_XAI_TOOL_CALL_USD` (0.005) per server-side tool call, with note
`xai:tool_calls=<n>`. An answer with no usage gets a blank cost and the note
`UNPRICED:no-usage`, and is counted at the reserve. The two agent-calls write
their own rows (stage `archie-research`), and the lane reads their cost back
by `COST_RUN_ID`.

## Proposals

For each scored find of the last 7 days with `applies`, a score at least
`ARCHIE_RESEARCH_MIN_SCORE` and no proposal yet, the lane does these steps in
order:

1. Write `state/archie-research/<slug>/ticket.html` and `mockup.html` (a
   sources sheet: the links, nothing invented).
2. Add an entry to `state/archie-research.ledger.json` (a working copy). The
   entry carries both bodies as `artifacts.ticket_html` and
   `artifacts.mockup_html`, because Approve does not run here.
3. `prow_put <ARCHIE_RESEARCH_PROJECT> <slug> … gate_pending if_absent`
   (default project `cromford`).
4. Send ONE `kind:proposal` beat with `status:gate_pending` and the source url
   in `detail`.
5. Record the find's `proposal_slug`.

A put or beat that did not land is retried by the next scan with no vendor
call. The slug is `archie-<first 12 hex of sha256(key)>`.

Approve on the Ideas screen runs `bin/product-cmd.sh post_proposal` on the
project's OWNING box (cromford: box-small), not on the hub. That
box gets the entry from the row (`prow_restore`), finds no
`state/archie-research/<slug>/` there, and `bin/post-proposal.sh` writes the
two bodies out from the record under `state/proposal-artifacts/<project>/<slug>/`.
cromford's board is GitHub Issues (fleet.conf board prefix `-`), so
`post-proposal.sh` has a GitHub-Issues arm: one `[Proposal]` issue on the
repo, labelled `ai-build` so triage picks it up, with the sources sheet inlined
in the body. It uses the same `posting` claim, row stamp and `posted` beat as
the in-app boards. A 4xx hands the claim back, and any other failure holds it
and raises an ALERT through `bin/alert-line.sh`.

That arm files an issue only for a repo on the settings row
`lane.archie-research.approve_files_issue_repos` (seeded `example-org/cromford`
in `worker/jobs/schema.sql`; a comma or whitespace separated list of exact,
case-sensitive `owner/repo` names). With no row, or with `JOBS_URL` empty on
purpose, the code default `example-org/cromford` applies. If the row cannot
be read while a worker is configured, nothing is filed and one ALERT says
"approve allowlist unreadable". Any other GitHub-Issues project (project-5,
project-6) keeps main's behaviour: `post-proposal: unknown project`, exit 1, no
row claim and no `gh` call, so its Ideas row keeps only the status the console
set. To widen it, write the row (`PUT /api/settings`), e.g. from a shell that
sourced `bin/jobs-client.sh`: `setting_set lane.archie-research.approve_files_issue_repos
'example-org/cromford,example-org/project-5'`. It is not a lane knob in
`catalog/lanes.d/archie-research.json`, because no env var feeds it, so
`harness-ctl.sh set` does not reach it.

## Not done here

- Nothing is posted to X or anywhere public. The scan session's only tool is
  WebSearch: it cannot fetch a URL, read a file, run Bash or reach an MCP
  server. The scoring session has no tools.
- `catalog/model-prices.json` is untouched. The xAI tool-call price is the
  `ARCHIE_XAI_TOOL_CALL_USD` knob.
- The xAI Responses shape (`usage.input_tokens`/`output_tokens`, the tool count
  from `server_side_tool_usage`, `num_server_side_tools_used` or
  `num_sources_used`) is read in `ar_xai_parse` only. If the live answer
  differs, the first cost row shows `UNPRICED:` instead of a wrong number.

## Operate

- Off: `ARCHIE_RESEARCH_ENABLED=0`, `flags/lane-off-archie-research`, or
  `bin/harness-ctl.sh off archie-research`. Knobs:
  `catalog/lanes.d/archie-research.json`.
- Log: `logs/archie-research.log`. A scan writes one line,
  `topics= x_calls= web_calls= finds= new= deferred= scored= proposals= spent=$x/$cap skipped=`.
- Schema check after deploy: `HUB_PROBE: d1-count archie_research all`.
