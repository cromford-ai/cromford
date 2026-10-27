# Secret envelopes: the hub half

A secret envelope moves one secret (a Claude token, an API key) from the
console to the fleet. The worker never sees the plain value. The console seals
the secret to the hub's public key. The jobs worker stores only the
ciphertext, and the hub reads it once. The store and the one-time read are
BH-7964 (`worker/jobs/src/routes/secret-envelopes.js`). This page covers the hub
half, BH-7965 (BH-7937.2). The console screen that seals an envelope is BH-7937.3.

## The key

- `bin/envelope-keygen.sh` makes the hub key pair. It is an operator one-shot on
  the hub, not a lane. The private key is RSA-4096 at
  `/etc/harness/envelope.key` (env `ENVELOPE_KEY`), made under `umask 077`, mode 600.
- A second run keeps the key and sends the same public half again.
  Only `--rotate` replaces the key (see Rotation).
- The public half goes to settings row `hub_envelope_public_key` through
  `PUT /api/secrets/envelope/public-key`. That route needs the main bearer AND
  `x-envelope-hub-token`, and it refuses any body that is not exactly one
  `PUBLIC KEY` block. `PUT /api/settings` cannot hold the PEM: it caps a value at 256 chars.
- A caller seals with RSA-OAEP, SHA-256, MGF1 SHA-256. A 4096-bit seal is 684
  base64 chars, inside the store's 344..1024 bound.

## The flow

1. The console seals the secret and stores it: `POST /api/secrets/envelope
   {scope, ciphertext}` (main bearer). The answer is `{id, expires_at}`.
2. Every minute the hub lane `secrets-apply` (`bin/secrets-apply.sh`,
   `cron/lanes/773-secrets-apply.cron`) lists the pending envelopes:
   `GET /api/secrets/envelope?state=pending&limit=$SECRETS_APPLY_BATCH`. It
   gets the id and scope only, never the ciphertext. `flock -n
   locks/secrets-apply.lock` dedupes the tick.
3. For each `ai-account:` scope, one after the other, it runs
   `bin/envelope-consume.sh <id>`. Other scopes (`tracker:`) stay for their own consumer.
4. `envelope-consume.sh` reads the envelope: `GET /api/secrets/envelope/<id>`.
   The read deletes the row, so an id is read at most once. Then it:
   1. decrypts with `openssl pkeyutl` (the current key, then each rotated key
      younger than the TTL).
   2. parses the scope (see Scope grammar).
   3. proves the value with `bin/lib/vendor/<vendor>.sh probe`, the value on stdin.
   4. writes it to the target boxes over ssh, the value on stdin, tmp file + `mv`, mode 600.
   5. confirms last: `POST /api/secrets/envelope/<id>/confirm {ok, detail}`.
      This writes ONE `applied` or `apply_failed` event. A second confirm is 409.
5. What is written on a box:
   - claude: `accounts.d/<label>.env`, one line `CLAUDE_CODE_OAUTH_TOKEN=<token>`.
     This is the file `project_account_exports` (`bin/lib/project-account.sh`) reads.
   - other vendors, use kind `project`: line `<VENDOR>_API_KEY_<LABEL>=<key>` in
     `env/<project>.env`. The label is upper case, and `.`, `@` and `-` become `_`.
     A line with the same name is replaced. Other lines stay as they are.
   - other vendors, use kind `pool` or `fallback`: line `<VENDOR>_API_KEY=<key>`
     in `env/global.env`, only when that line is not there yet. An existing pool
     key is never overwritten. That box counts as failed, and the log line says "key exists; use Rotate".
6. Targets: `project` = that project's box (`bin/fleet-conf.sh --tailnet-ip
   <project>`). `pool` and `fallback` = every box (`--tailnet-ips`).

The plain value lives in one shell variable and in pipes only. It is never on
argv, in a log line, on stderr or in the worker. The logs carry the id, the scope, the rcs and the counts.

### Vendor proof

`bin/lib/vendor/<v>.sh probe` (claude, codex, openrouter, fireworks, xai) reads
the key from stdin. Exit 0 = proved, 1 = refused, 75 = unreachable, 99 = an
unknown verb (`unimplemented: <verb>`).
- claude runs `claude -p` with the model from `model_for claude.ladder`.
- codex runs `codex exec -` with `codex.default`.
- The API vendors make one GET that needs the key: `<base>/models` for fireworks
  and xai, `<base>/key` for openrouter (its `/models` answers 200 for any key).
  The base comes from settings row `vendor.<v>.base_url`, else the code
  fallback. The row is used only when its host is the fallback's host: any
  main-bearer holder can write the row, and the probe sends the plain key there.
- `HARNESS_VENDOR_FAKE=1` is the one fake switch for every `bin/lib/vendor/`
  seam (BH-8555). The seam answers from `tests/fixtures/vendor-fake/<v>.json`
  (override the root with `HARNESS_VENDOR_FAKE_DIR`) with 0 network calls.
  Unset, empty or `0` is real mode. Any other value fails closed: exit 99, no
  call. `vendor_fake_on` in `bin/lib/vendor/_common.sh` is the only reader.
- `HARNESS_VENDOR_MODE=fake` is a retired alias (BH-7974) for one release: it also turns on fake mode and prints one deprecation line. <!-- retired-alias BH-8555 -->
  `tests/vendor-fake-switch.bh-8555-test.sh` refuses the retired names (and the
  old fixture root) anywhere else in the tree.
- The real-vendor contract suite is `tests/contract/vendor-probe.bh-7965-contract.sh`.
  It runs nightly (`harness-nightly.yml`, job `vendor-contract`), never on a PR.

## Scope grammar

```
ai-account:<vendor>:<label>:<use_kind>[:<project>]
```

- `vendor` is one of `claude`, `codex`, `openrouter`, `fireworks`, `xai`.
- `label` is `[a-z0-9._@-]`, 1..48 chars, and does not start with `.`. A label
  that starts with `sk-`, `sk_`, `xai-`, `fw_` or `or-` is refused as "label
  looks like a key" (a pasted key), and so is a label over 48 chars.
- `use_kind` is one of `project`, `pool`, `fallback`.
- `project` is required for `project` and refused for the other kinds. It must be a
  project in `fleet.conf`.
- Three fields (`ai-account:claude:team-a`) or six fields are refused.

The parser is `envelope_scope_parse` in `bin/lib/envelope.sh`. A refused scope
writes nothing and confirms `apply_failed` with the reason.

## TTL

- An envelope lives `secret_envelope_ttl_s` seconds (settings row, default 900).
  A read after that is refused and deletes the row (BH-7964).
- A rotated key is tried for one TTL after the rotation. `secrets-apply` deletes
  `envelope.key.<epoch>` files older than the TTL.
- Every hour at :23 the `secret-envelope-sweep` lane (`bin/secret-envelope-sweep.sh`)
  sends `POST /api/secrets/envelope/sweep {dry_run}`. The worker then:
  - deletes the expired envelopes nobody read.
  - archives, then deletes, the events older than `secret_envelope_events_retention_days` (default 90).
  - deletes at most `secret_envelope_sweep_batch` rows (default 500) per table per call.
  - writes ONE `sweep` event per call, with detail
    `{dry_run, envelopes, events, archive, more}`.
- The knob `SECRET_ENVELOPE_SWEEP_DRY_RUN` is 1 by default (dry-run first): the
  sweep only counts. Set it to 0 to delete.

## What survives

- On the worker: no plain value, ever. After the read, the envelope row is gone. The audit rows in
  `secret_envelope_events` stay: `stored`, `consumed`, `expired`, `applied`,
  `apply_failed`, `sweep`, `public_key_set`. Their detail is a fixed reason or a
  count, never a value. Old events go to the archive database (`env.ARCHIVE`), never a silent delete.
  With the archive unbound, the sweep deletes no events and says `archive:"not bound"`.
- On a box: the env file or `accounts.d` file that was written.
- On a partial write (exit 4), the good boxes keep the file, and `apply_failed`
  names the failed boxes. Re-send the secret in a new envelope to finish.
- On the hub: the key file, the rotated keys inside one TTL, and the log lines in
  `logs/secrets-apply.log` and `logs/secret-envelope-sweep.log`.

## Rotation

- Key: `bin/envelope-keygen.sh --rotate` moves the key to
  `envelope.key.<epoch>` (mode 600), makes a new one and sends its public half.
  An envelope sealed to the old key still decrypts for one TTL.
- A pool or fallback API key: the consumer never overwrites
  `<VENDOR>_API_KEY` in `global.env`. To replace it, add a new label and revoke the
  old one (the BH-7937.3 Rotate action).

## Exit codes

| Script | 0 | 1 | 2 | 3 | 4 | 75 |
|---|---|---|---|---|---|---|
| `envelope-keygen.sh` | public half sent | usage, openssl or credential error, or a 4xx | | | | worker down or 5xx; the key stays |
| `envelope-consume.sh` | every box written, `applied` | nothing written (`apply_failed`, or a bad id and no call) | decrypt failed | no such envelope | some boxes failed | worker down, hub token refused, or the confirm was lost (one ALERTS line) |
| `secrets-apply.sh` | every tick | a knob out of range | | | | |
| `secret-envelope-sweep.sh` | 200 (an ALERTS line when the archive copy failed) | bad knob or 4xx | | | | worker down or 5xx |

## Setup

1. Set the same `ENVELOPE_HUB_TOKEN` as a jobs worker secret
   (`wrangler secret put ENVELOPE_HUB_TOKEN --name harness-jobs`) and as a line
   in the hub's `/etc/harness/env/global.env`. Until the hub has it,
   `secrets-apply` logs `not-configured` and does nothing.
2. Run `bin/envelope-keygen.sh` once on the hub.
