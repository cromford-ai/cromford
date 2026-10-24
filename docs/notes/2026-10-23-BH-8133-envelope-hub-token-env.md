# BH-8133: ENVELOPE_HUB_TOKEN named where it must be set

Doc: DB-COORDINATION-SPEC, OPERATOR-SETUP

PR #7992 (BH-7964) shipped the jobs worker secret `ENVELOPE_HUB_TOKEN`. Its PR body did not name where to set it. This change names it in the two operator surfaces:

- `env-templates/lanes/385-secret-envelope-hub-token.env.example` adds a commented `#ENVELOPE_HUB_TOKEN=` line to the rendered `global.env.example`. Set it on the hub only, in `/etc/harness/env/global.env`.
- `worker/jobs/wrangler.jsonc` lists it in the secrets comment block. Set it with `wrangler secret put ENVELOPE_HUB_TOKEN --name harness-jobs`.

Use the same value in both places. Unset or blank on the worker, `GET /api/secrets/envelope/<id>` answers 503 (fail closed). No code changes. `tests/envelope-hub-token-env.bh-8133-test.sh` pins both surfaces and the name the worker reads.
