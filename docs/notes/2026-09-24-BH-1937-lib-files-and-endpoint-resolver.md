# One registry file per lib, and `endpoint_url` as the one URL resolver

Doc: OPERATOR-SETUP

## What changed

BH-1937 is part 1 of 5 of BH-1511's split. It adds the two seams the other
parts import. It converts no variable and registers no real lib or endpoint.

- **`catalog/lanes.d/_lib.<id>.json`** (`bin/lanes-build.sh`). A lib's knobs can
  now live in their own file, `{"libs":[{...}]}`, next to `_lib.json`. Each file
  gets the same shape check `_lib.json` gets, and all of them are merged into
  the composed `.libs`, sorted by id. The same lib id in two files is rc 1, and
  the message names every file that holds it:
  `lanes-build.sh: duplicate lib id 'a-lib' in _lib.json and _lib.y.json`.
  The per-lane loop skips `_lib.*` the way it skipped `_lib`. With no
  `_lib.*.json` present the composition is byte-identical to before.
  Why: every lib conversion would otherwise append to `_lib.json`, which is a
  hand-appended shared index and a conflict between every pair of siblings.
  A new lib is a NEW file. `_lib.json` stays readable, and nothing moves out of
  it here.
- **`bin/lib/endpoints.sh`, `endpoint_url <service>`**. It prints the URL on
  stdout with rc 0. When nothing answers it prints nothing, writes one stderr
  line and returns rc 1. It has no literal fallback. `<service>` must match
  `[a-z0-9-]` and must not start with `-`. The knob is `ENDPOINT_<SERVICE>`
  (upper case, `-` becomes `_`) in the lib `endpoint-<service>`, and its
  settings key is `lib.endpoint-<service>.endpoint_<service>`. The value comes
  only from `lib_env_apply`: operator row, then cached row (logged once), then
  env, then registry default.

## What a sibling registering an endpoint needs to know

- Register it as `catalog/lanes.d/_lib.endpoint-<service>.json` with
  `settable: false` (BH-1165). `lib_env_apply` never reads a row for a
  `settable: false` knob, so for a real endpoint only the env and the registry
  default answer. The row and cached-row rungs are proved with a settable
  fixture knob in `tests/endpoints-resolver.bh-1937-test.sh` (E1, E2). E8 pins
  that a row is ignored for a `settable: false` one.
- Register it `required: true`. `lib_env_apply` applies a registry default only
  to required knobs, so the default of an optional knob would never answer.
- A required knob with nothing set makes `lib_env_apply` write its daily
  FAIL CLOSED line to `logs/ALERTS.log` and `exit 75`. `endpoint_url` runs it in
  a subshell, so the caller gets rc 1 and keeps running. The ALERTS line is
  kept on purpose, because a missing endpoint is worth a page.
- Call it as `url=$(endpoint_url <service>) || …`. It does not export
  `ENDPOINT_<SERVICE>` into the caller.
