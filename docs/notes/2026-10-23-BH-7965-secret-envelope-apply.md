# Secret envelopes: the hub applies an envelope (BH-7965, BH-7937.2)

Doc: SECRETS-ENVELOPE

## What changed

- New hub lane `secrets-apply` (every minute, `bin/secrets-apply.sh`). It lists the
  pending `ai-account:` envelopes and runs `bin/envelope-consume.sh <id>` on each:
  read once, decrypt (RSA-OAEP SHA-256), prove with the vendor, write to the boxes
  over ssh, confirm.
- New hub lane `secret-envelope-sweep` (hourly at :23). It deletes expired
  envelopes and archives, then deletes, events older than 90 days. It ships in
  dry-run (`SECRET_ENVELOPE_SWEEP_DRY_RUN=1`).
- New operator one-shot `bin/envelope-keygen.sh [--rotate]`: the RSA-4096 hub key
  at `/etc/harness/envelope.key` and its public half in settings row
  `hub_envelope_public_key`.
- New vendor seams `bin/lib/vendor/<v>.sh probe` for claude, codex, openrouter,
  fireworks and xai. There is a fake for tests and a nightly contract suite.
- Four worker routes in `worker/jobs/src/routes/secret-envelope-apply.js`: pending
  list, confirm, sweep, public-key. Two new settings rows:
  `secret_envelope_events_retention_days` (90) and `secret_envelope_sweep_batch` (500).

## Why

BH-7937 moves AI-account secrets from the console to the fleet with no plain value
on the worker. BH-7964 shipped the store. This slice is the hub half that reads and applies an envelope.

## Operator steps

1. Set `ENVELOPE_HUB_TOKEN` on the jobs worker and in the hub's `global.env`.
2. Run `bin/envelope-keygen.sh` once on the hub.
