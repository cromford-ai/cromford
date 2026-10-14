# Vendor API base URLs are endpoint knobs (endpoints wave 1)

Doc: CONFIG

Four scripts no longer carry a vendor base URL literal. `bin/fly-api.sh`, `bin/qa-clerk-ban.sh`,
`bin/vendor-spend-pull.sh` and `bin/update-model-prices.sh` resolve it through
`endpoint_url <service>` (`bin/lib/endpoints.sh`, BH-1937) before any call, and exit nonzero when it
cannot resolve.

The knobs are `ENDPOINT_FLY_MACHINES`, `ENDPOINT_CLERK`, `ENDPOINT_OPENROUTER` and `ENDPOINT_OPENAI`
(`catalog/lanes.d/_lib.endpoint-*.json`).
- They register `settable: false` and `required: true`, with today's URL as the default, so nothing
  resolves differently.
- They resolve from the env, else the registry default. No settings row can redirect a call that
  carries a Bearer token (BH-1165).
- A proxy or vendor move is an env or registry edit.
- `CLERK_API` in the env still wins in `qa-clerk-ban.sh`.
