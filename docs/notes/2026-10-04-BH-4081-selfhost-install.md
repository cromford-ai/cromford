# Self-host install: the dry-run planner (BH-4081 slice C0, #3979 wave 7)

Doc: OPERATOR-SETUP, config-inventory

## What changed

- `bin/selfhost-install.sh --config <file>` is the one command for a self-hosted
  harness in the operator's own accounts. This slice ships its dry-run, which is
  the default and the only mode built. It:
  - reads the settings file as data (never sourced). It refuses an unknown key, a
    duplicate key, a line that is not `KEY=value`, and any secret-shaped key
    (`…TOKEN`, `…SECRET`, `…API_KEY`, `…PASSWORD`, `…PRIVATE_KEY`) without
    echoing its value;
  - names every missing or invalid setting in one refusal (rc 1);
  - prints one `RESOURCE` line per row of `catalog/selfhost/resources.tsv`.
    Per-project rows print once per `SELFHOST_PROJECTS` entry, and rows whose
    condition is false print as `skip(<term>)` so every resource stays visible.
    A row already in `<--state>/ledger.tsv` prints as `recorded`;
  - prints the `ENV` lines apply would write to env/global.env (the BH-4080
    deployment knobs; the merge and bot git identities follow the operator's,
    so none of our defaults survive on their box), the `CAP` lines, the
    `SECRET` names with the rows that need them, and a `SUMMARY`.
  - makes no network call and writes no file. It does not source
    `bin/lib/deployment.sh`, whose defaults are our deployment's values.
- `--apply` exits 2 with `nothing was created`. It is not built.
- `env-templates/selfhost.conf.example` holds the settings. Values are blank
  except `SELFHOST_CHAT=none` and the caps. Secrets never go in it.
- Caps: `SELFHOST_CAP_USD_PER_CALL` (default 5) becomes `AGENT_CALL_BUDGET_USD`
  and `SELFHOST_CAP_USD_DAY` (default 20) becomes `LLM_USD_CAP_DAY`. 0, blank,
  negative or non-numeric is refused. `SELFHOST_CAPS_OFF=1` is the only way off.
  The harness has no call or token cap, and the plan says so on its own line.

## Exit codes

0 plan printed, 1 settings refused, 2 usage or `--apply`, 3 catalog malformed
(`catalog <path>:<line> malformed`).

## Not built (later slices of #4081)

- C1 Cloudflare apply: D1 create and schema apply, per-install wrangler configs
  (the checked-in ones carry our account and database ids), the watchdog KV, the
  R2 bucket, the Pages console, worker secrets, all of it into the ledger.
- C2 hub and build-pool apply (Fly or a VM).
- C3 GitHub App or PAT, model keys and chat wiring at apply time.
- C4 call and token caps.
- C5 the live clean install into a throwaway Cloudflare + Fly account.

The ledger rules C1–C3 must follow: write the `provider kind name` row only
after the provider confirms the create, look up and record an "already exists"
answer, never prune, and check the ledger before every create call.

## Drive it

```
cp env-templates/selfhost.conf.example /tmp/s.conf   # fill the values
bin/selfhost-install.sh --config /tmp/s.conf; echo rc=$?
```

Suite: `tests/selfhost-install-dryrun.bh-4081-test.sh`.
