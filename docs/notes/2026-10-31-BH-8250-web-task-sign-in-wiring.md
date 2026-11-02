# web-task agent signs in and types a TOTP code (BH-8250, slice C1 of #8226 and #8172)

Doc: DB-COORDINATION-SPEC

## What changed

The S1 web-task agent (`bin/web-task-agent.mjs`, BH-7594) now calls the step
modules of `docs/notes/2026-10-24-BH-8226-sign-in-step.md` and
`docs/notes/2026-10-24-BH-8172-otp-step.md`. Before this slice, those modules
had no production caller.

- Two new agent actions, `{"action":"sign_in"}` and `{"action":"type_otp"}`.
  The model names no value and no field. `sign_in` runs `createSignIn` with a
  `createTypeSecret` instance (default provider `wv_read`). `type_otp` runs
  `createOtpStep` with a `createTypeOtp` instance (default providers
  `wt_totp_code` and `wt_totp_step`), so the code is made at typing time. The
  project is `WEB_TASK_PROJECT`. The four modules load on the first such action
  only, so a read-only run needs none of them.
- One vault site per run: the page host at the first `sign_in` or `type_otp`,
  and only when it is an exact entry of the allow-list. Else
  `refused: sign-in not allowed on <host>` (`otp not allowed` for `type_otp`),
  not terminal, with no vault read. A call on another host after that gets
  `refused: this run signs in on <site> only`.
- A terminal step outcome (the attempt cap, `refused: otp refused`, a failed
  vault read, a bad step knob, no `WEB_TASK_PROJECT`) stops the run: status
  `error`, reason `stopped: <outcome>`.
- The record of either action is `{step, action, outcome}`. Any other field
  the model sends is dropped by `decide.sh`, and the agent does not record it.
- `result.json` has a new field `vault_site` (the vault site, or `""`).

## The write window

The S1 guards abort every request that is not GET, HEAD or OPTIONS, and an
init script cancels every submit event. There is one exception now. While a
`sign_in` or `type_otp` step runs, a POST passes when its URL passes the
step's host gate (`gate()` of `bin/lib/web-signin-step.mjs`: the exact vault
site, https or loopback http, no userinfo). A POST to another allowed host, a
subdomain, or any POST after the step returns is refused as before
(`kind: method`).

- Submit events: the tool layer sets a one-shot flag `window.__wtSubmitOpen`
  just before the step's own click or Enter, so that one submit passes the init
  script. A page script that sets the flag gains nothing: the network guard
  still aborts its POST.
- Redirects of a POST navigation in the window: the guard follows them itself,
  at most `WEB_TASK_MAX_HOPS`. Every hop must pass the allow-list
  (`kind: redirect` else). A 307/308 repeats the POST only on the vault site,
  and a 301/302/303 becomes a GET with no body (`context.request`, which shares
  the cookie store). The browser gets the last response. After an `ok:`
  outcome the agent navigates to the last hop, so the next observation shows
  the real URL.

## Redaction

`scrub` replaces each value typed in the run with `[secret]`
(`createTypeSecret`'s `redact`) and then each code typed with `[code]`. It
scrubs the obs files (the prompt input), every outcome, `result.json` and the
`WEB_TASK_RESULT` line. Secrets go first, so a code inside a longer value
cannot split that value before it is redacted. After the first step, every
screenshot masks the password input, each input a secret was typed into
(`screenshotOptions`) and the OTP inputs (`OTP_SELECTORS`, now exported from
`bin/lib/web-otp-step.mjs`).

## The lane

- `bin/web-task.sh` runs `lib_env_apply web-signin`, `web-otp` and
  `web-otp-step` before the agent starts, so the settings rows
  `lib.web-signin.*`, `lib.web-otp.*` and `lib.web-otp-step.*` reach the
  agent as env. No new knob: the registry defaults stay
  (`WEB_TASK_SIGNIN_TIMEOUT_S` 20, `WEB_TASK_SIGNIN_ATTEMPTS` 1,
  `WEB_TASK_OTP_ATTEMPTS` 2, `WEB_TASK_OTP_STEP_TIMEOUT_S` 20).
- The result comment adds one line when `result.json` names a `vault_site`
  (a host) and a `sign_in` action ended `ok:`: "I signed in on `<site>` with
  the stored credential. The only forms the browser sent were the sign-in and
  code forms."

## Test seam

`WEB_TASK_TOTP_CLOCK` (read only under `HARNESS_TEST_SANDBOX=1`): a file that
holds the TOTP clock. `type_otp` reads it as `now()`, and a wait for the next
window moves the file instead of sleeping. `tests/web-task-vault.bh-8250-test.sh`
uses it so the retry case reads no wall clock.

## Debt this closes

- `docs/notes/2026-10-24-BH-8226-sign-in-step.md`, "Owed to slice C1 of
  #8226": item 1 (the `sign_in` branch), item 3 (redact on the agent sinks:
  obs, outcomes, result, result line; the lane comment reads only the
  scrubbed result), item 4 (`screenshotOptions` on every screenshot), item 5
  (`lib_env_apply web-signin`) and item 6
  (`tests/web-task-vault.bh-8250-test.sh`).
- `docs/notes/2026-10-24-BH-8172-otp-step.md`, "Owed to slice C1 of #8172":
  items 1, 2 and 3.

## Still owed

- The real proof on a site the operator names, with a test account (#8226 item 7,
  #8172 item 4, #8289 "Acc: real proof"): moved to #8299.
- #8226 item 2 (fill the `bin/lib/web-task/vault.sh` seam) is not done. The
  agent reads through `createTypeSecret`'s own `wv_read` provider, and
  `wt_vault_get` still has no caller.
- The header comments of `bin/lib/web-signin-step.mjs`,
  `bin/lib/web-secret-action.mjs`, `bin/lib/web-otp-action.mjs` and
  `bin/lib/web-otp-step.mjs` still say "No production caller yet". The agent
  is their caller now. This slice did not edit those files beyond the export.
