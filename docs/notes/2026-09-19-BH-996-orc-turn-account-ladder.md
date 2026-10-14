# The orchestrator turn tries every account it can reach, and its survival banner states the measured refusal

Doc: ACCOUNT-ROUTING

**What changed.** A Telegram turn used to be ONE account deep. `orc_pick_account`
ran once before the turn (`bin/orchestrate.sh:279`), the model ladder ran fable
then opus on that one token, and the first non-zero rc after those two calls sent
the answer to a survival lane under a banner that read "Claude is out of
credits" — a sentence nothing had measured. Now:

- **`bin/lib/orc-account.sh` gained the classifier** (`orc_fail_class`,
  `orc_fail_phrase`) and the refusal helper (`orc_account_refuse`,
  `orc_pin_clear`). The three class regexes are `bin/agent-call.sh`'s `LADDER_*_REGEX` defaults
  verbatim — same env knob names, same defaults — so a box that overrides one for
  the build ladders gets the same override on the turn. `ORC_CREDITS_REGEX` is a
  fixed strict subset of the exhaust pattern and is the ONLY thing that may print
  "out of credits".
- **`bin/orchestrate.sh` gained the account ladder** (the `# >>> claude ladder`
  block). The model loop is now `orc_model_ladder()`, called from a loop over
  accounts: picked account → each further account the picker names, each at most
  once → the orchestrator.env default token → the survival lanes → the bash
  floor. Only `account-exhausted` and `auth` buy another account; a 529 or a real
  agent failure falls to survival exactly as before. The class is the STRONGEST
  verdict across the models that ran on that account, not a re-read of the last
  one's output: `fable: session limit` then `opus: 529` is an account refusal,
  and reading only the tail left the account uncooled under a banner saying it
  had not refused. A turn buys at most `ORC_ACCOUNT_RUNGS_MAX` (2) named
  accounts before taking the default token — every rung stamps a 6h cooldown the
  whole hub honours, and one chat message must not be able to park the max pool.
- **A refusal is stamped before the next pick.**
  `state/quota/cooldown/claude/<account>` — vendor-keyed, the path
  `bin/account-pick.sh:account_cooldown_file` reads and `bin/agent-call.sh`
  writes since BH-940. (A bare `cooldown/<account>` is the pre-BH-940 shape: the
  picker sweeps it to `.legacy/` and never reads it, so it would cool nothing.)
  The hub's build stages skip the account too, and
  `state/quota/pins/orchestrator` is REMOVED — the picker
  rewrites that pin to whatever it picked, so after a refusal it was the one file
  still naming the account that said no.
- **The banner and the survival brief carry the trail**, not a guess:
  `claude refused on max7 (session limit) and on default (session limit)`, plus
  `the default token was not tried (transient on max7 is not an account refusal)`
  when the failure was not the account's fault. The brief's old sentence ("out of
  credits or otherwise failing") is replaced by a `WHY YOU ARE ANSWERING:` line
  built from the same trail.

**Why.** On 2026-09-19 a session limit on the pinned max account took the operator's
Telegram channel to codex while six other accounts and the orchestrator.env token
sat untouched, and the reply told him the wrong reason for it. Both halves were
the same bug: the turn never measured what refused it, so it could neither route
around it nor name it.

**What it touches.**

- State: `state/quota/cooldown/claude/<account>` (written, shared with
  `bin/account-pick.sh:account_cooling` and `bin/agent-call.sh`),
  `state/quota/pins/orchestrator` (deleted on a refusal and after a re-pick lands
  on `default`). `default` is never cooled down and owns no pin.
- Logs: `logs/failovers.log` gains `turn account: max7 → refused(quota) →
  default (no-pick)` lines, and the survival note now carries the trail:
  `claude lane dead (max7 → refused(quota) → default → refused(quota), rc=1)`.
- Knobs: **none new.** `ACCOUNT_EXHAUST_REGEX`, `LADDER_EXHAUST_REGEX`,
  `LADDER_TRANSIENT_REGEX`, `LADDER_AUTH_REGEX` and `ACCOUNT_COOLDOWN_SECS` all
  already existed; `ORC_TOKEN_DEFAULT` is set by the script, not read from the
  environment.
- `bin/agent-call.sh` is untouched, on purpose (the ticket forbids it). The price
  is a second copy of three regex strings;
  `tests/orc-turn-ladder.bh-996-test.sh` compares the two files line for line so
  drift fails loudly.

**What did not change.** `rc=124` still ends the turn where it was — no
classification, no cooldown, no survival lane. The per-model stamp is still
written only on `usage credits` — but it is now keyed to the account that ran
(`state/model-cooldown-<model>-<account>`, exactly as `bin/agent-call.sh` keys
it, `default` taking no suffix). Written globally, max7's dry fable pool sent
every other account straight to opus for six hours, and only a fable success
clears it — the precise loss account routing exists to prevent. A box whose `bin/lib/orc-account.sh` predates
this note degrades to the old one-account behaviour through a `type
orc_fail_class` guard, with a banner that says it has no classifier rather than
inventing a reason.

**Still owed.** Nothing in this change was verified against a live Telegram turn
— cromford builds run on a build box and the hub owns that lane. The
evidence is `tests/orc-turn-ladder.bh-996-test.sh`, which drives the lifted
production blocks with the real `run_turn`, the real survival lanes and the real
account lib against a fake CLI.
