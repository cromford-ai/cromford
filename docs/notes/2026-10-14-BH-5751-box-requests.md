# The orchestrator handles box and project requests from chat (BH-5751)

Doc: ADDING-A-BOX, HARNESS-COORDINATION

## What changed

- New script `bin/box-request.sh`. `bin/orchestrate.sh` runs
  `box-request.sh intercept "$TEXT"` in a new block,
  `# >>> box request intercept`, after Archie's intercept and before the turn
  claim. rc 0 = the reply goes out and no model turn runs. rc 1 = the normal
  turn runs. No script = the normal turn runs.
- The verbs. The message must be one line that starts with the verb. The
  `[telegram: from …]` line that `bin/poll-commands.sh` puts above a chat
  message is dropped first.
  - `/box launch <project> [--id <box>] [--account a] [--vcpus N --mem-gb N --disk-gb N] [facts]`
    and `we need a box for <project>` (also `I need a new|dedicated box for`):
    the quote step.
  - `/box list`: the Orgo computers and the newest 10 `orgo_*`/`fly_*` hub
    commands. It reads only.
  - `/project load <project> [facts] [--cap N]`: the placement rule. It
    queues nothing until a yes.
  - `yes`, `yes.` or `yes!`: only while this chat and thread has an open
    offer younger than `BOX_REQUEST_OFFER_S`. Any other `yes` is a normal turn.
  - Facts: `--repo-mb N`, `--builds-day N`, `--desktop`, `--isolated`. A fact
    that is not given is unknown, and the reply names it.
- The placement rule is data: `prompts/box-placement.json`. The first rule
  that matches wins. It picks shared, fly or dedicated. It holds no price.
- The quote step queues `orgo_launch_quote` and waits up to
  `BOX_REQUEST_QUOTE_WAIT_S` for the hub's box-ops lane to finish it. The
  monthly figure comes from the row's `usd_mo=<n>`, with the worker's own
  pattern. Then it writes an offer (ledger `box_offer/<transport>:<chat>:<thread>`)
  and asks for a yes. An explicit box ask always prices a dedicated box. The
  reply also states the rule's recommendation.
- The launch step runs on the offer owner's yes. It claims ledger
  `box_launch/q<quote_id>` first, then queues `orgo_launch` with `quote_id`
  and `confirm_monthly_usd` = the quoted figure. A 409 `stale_quote` gets a
  new quote and a new question. The old quote id is never sent again. An
  unknown outcome is never resent.
- A `/project load` yes: dedicated runs the quote step (the launch still needs
  a second yes). Fly queues `fly_onboard`, or `fly_pool_cap` when
  `flags/fly-pool-<p>` exists and `--cap N` was given. Shared queues nothing:
  adding a project to the shared box is a `fleet.conf` PR.
- After a queued launch, `box-request.sh watch <id>` runs detached. It sends
  the `box-launch:` summary line once through `bin/archie-tg-send.sh`
  (akey `box-launch-<id>`). After `BOX_REQUEST_WATCH_S` it writes one ALERTS
  line.
- Every queued command carries the owner's email as `actor`. The email comes
  from `BOX_CHAT_OWNERS`. Slack and Mission Control senders never resolve.
- `prompts/archie-soul.d/10-authority.md`: MAY gets the free price check.
  NEVER gets a launch without the owner's yes for that launch.

## Operator steps

1. Set `BOX_CHAT_OWNERS=telegram:<username>=<email>` in the hub's
   `env/global.env`. Each email must also be in the worker secret
   `BOX_OPS_OWNERS`.
2. Until step 1, every box verb that queues answers "Only an owner can ask for
   this" and queues nothing.

Knobs: `env-templates/lanes/383-box-request.env.example`. A knob that is not a
positive integer is one ALERTS line and the reply "Box requests are not
configured".
