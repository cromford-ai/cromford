# The claude and runner canaries probe the credential first (BH-2560, BH-2549.2)

Doc: AUTH-PROBE

## What changed

- `bin/lane-probe.sh` stops calling vendor CLIs. The default mode is one
  inference through `bin/agent-call.sh` (stage `canary`, project `fleet`,
  `AGENT_CALL_RUNNERS=<lane>`, lane `claude-auth-check`), so a canary now writes
  a cost row and runs the same vendor flags a build does. It gains a `claude`
  lane (model role `triage`).
- `lane-probe.sh <lane> --endpoint` (or `--endpoint <lane>`) prints
  `cred_probe <lane>` as line 1. Only on `cred_inference_claim` rc 0 does it add
  an `INFERENCE` section and record the outcome. It exits 0 either way.
- `bin/claude-auth-check.sh`: the hourly box loop and project-1-lane act on the
  endpoint verdict, with the claimed daily inference overriding it. Remote
  boxes are asked for `lane-probe.sh claude --endpoint` over ssh instead of the
  shipped probe script. `PROBE_BODY` calls agent-call instead of `claude -p`.
  The 6-hourly loop marks and clears lanes on `ALIVE`/`DEAD` only.
- The conductor marker is cleared only by an inference answer of ok.

## Why

The canaries bought an inference every hour on every box, through bare vendor
CLIs, so none of it wrote a cost row. The endpoint check answers "is the
credential alive" without a model call. The inference stays for what only it
can show (credits exhausted, the CLI's own login broken), once a day, through
agent-call.

## Still owed

The contract in `bin/lib/cred-probe.sh` is a stub until BH-2559: it answers
`NO_ENDPOINT` and the claim always returns 0, so every run still spends.
