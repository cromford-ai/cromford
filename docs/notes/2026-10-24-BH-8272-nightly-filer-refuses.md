# The nightly filer refuses to file without the App token (BH-8272)

Doc: OPERATING

## Why

Issue #8139 waited 14 hours for a build that never started. The nightly red
lane (`bin/nightly-ticket.sh`) opened it as the workflow token, so the
`labeled ai-build` actor was `github-actions[bot]`. The trigger-actor gate
(`bin/lib/trigger-actor.sh`) refuses that actor, as designed (BH-6957).

## Cause

Run 39920471215 (event `schedule`, branch `main`, 2026-10-23T07:50:26Z), job
"Nightly verdict (a red night files a ticket)":

- The step `harness App token for the ticket filer` was **skipped**.
- Its condition was `github.ref == 'refs/heads/main' && vars.HARNESS_APP_ID != ''`.
  The ref was `main`, so the repo variable `HARNESS_APP_ID` was empty.
- The mint did not fail. It never ran. The variable was never set. The BH-6957
  note listed it as an operator step, and nobody did it.
- The filer then fell back to `GH_TOKEN` with a `::warning::`. Nobody reads a
  warning on a nightly run.

## What changed

1. **The filer refuses.** In `bin/nightly-ticket.sh`, `wgh` makes no gh call
   when `NT_APP_TOKEN` is empty. It prints once per run
   `nightly-ticket: no App token; refusing to file a ticket the trigger-actor gate would ignore`,
   plus one `::error::` under GitHub Actions, and the script exits 1. Comments on
   an issue that is already open still post as `GH_TOKEN`, because a comment
   starts no build.
2. **The mint is loud.** In `.github/workflows/harness-nightly.yml`, the
   `app-token` step runs on every `main` run (`if:` no longer tests
   `vars.HARNESS_APP_ID`) with `continue-on-error: false`. An unset variable or
   secret is a failed step, so the verdict job is red on main and the main-red
   detector reads it. The verdict step has `if: ${{ !cancelled() }}`, so it
   still judges the night after a failed mint. It calls the filer only when
   `NT_APP_TOKEN` is not empty. Otherwise a red night prints
   `::error::the nightly run is red and no App token was minted: no ticket filed (BH-8272)`.
3. **The refusal comment names the recovery.** When `_ta_post` refuses a label
   by `github-actions[bot]` on an issue whose body carries the filer's marker
   (`<!-- harness-nightly-red:` or `<!-- harness-nightly-red -->`), it reads the
   issue once and adds one sentence: the nightly red lane labelled it because
   the App token was missing, and a person on the trigger list can take
   `ai-build` off and put it back. A failed read keeps the plain text.

## Operator steps

These are go-live steps. This box gets HTTP 403 on `actions/variables` and
`actions/secrets`, so it cannot set or confirm them.

1. Set the repo variable `HARNESS_APP_ID` to the harness App id.
2. Set the repo secret `HARNESS_APP_PRIVATE_KEY` to the App private key (PEM).
3. After the next `main` nightly, run `gh run view <id> --json jobs` and check
   that the step `harness App token for the ticket filer` is `success`.

Until steps 1 and 2 are done, every `main` nightly fails on the mint step.
That is the intended signal.

## Tests

- `tests/nightly-ticket-refuse.bh-8272-test.sh` (N1-N5: the real filer, a stub gh)
- `tests/nightly-ticket-workflow.bh-8272-test.sh` (W1-W4: the parsed workflow,
  and the verdict step's real run text executed against stubs)
- `tests/trigger-actor-nightly-recovery.bh-8272-test.sh` (G1-G7: the real
  `ta_gate`, a stubbed wire)
- `tests/nightly-ticket-app-token.bh-6957-test.sh` A3, A3b and W1 now pin the
  refusal and the mandatory mint.
