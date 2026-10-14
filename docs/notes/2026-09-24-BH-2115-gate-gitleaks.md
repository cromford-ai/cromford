# The pool's gate runs the gitleaks arm; publish-share checks its download

Doc: CI-RUNNERS

## What changed

- **`bin/lib/gitleaks-pin.sh` (new)** holds the pin (`GITLEAKS_PIN_VERSION`,
  `GITLEAKS_PIN_SHA256`) and `gitleaks_pin_ensure <dest-dir>`. It uses the
  gitleaks already on PATH when `bin/ci-tool-present.sh` says it is exactly
  8.30.1. Otherwise it takes the linux_x64 release tarball from a per-box cache
  (`${HARNESS_STATE_DIR:-/root/harness/state}/tools/`, override
  `GITLEAKS_PIN_CACHE`), downloading it when missing, and runs `sha256sum -c`
  against the pinned literal on every use before unpacking. A mismatch deletes
  the tarball and fails.
- **`bin/test-impact-gate.sh`'s isolated runner** (pool builders, and Orgo
  boxes as root beside `/root/harness`) now passes `GITLEAKS_REQUIRED=1` and
  puts the snapshot's `tools/` dir first on PATH in the suites' `env -i`. When
  a selected suite contains `command -v gitleaks`, the runner first calls
  `gitleaks_pin_ensure` into that `tools/` dir. If the install cannot happen
  (no network, checksum mismatch, a platform with no pinned asset), the gate
  exits 125 with `gitleaks 8.30.1 could not be installed (<reason>)` before any
  suite runs, which run-build records as `could-not-run`.
- **`.github/workflows/publish-share.yml`** checks the downloaded tarball with
  `echo "$SHA  /tmp/gl.tgz" | sha256sum -c -` before `tar`, with the same
  `SHA=` literal as harness-ci.yml.
- `tests/gitleaks-pin.bh-2115-test.sh` pins it: the three copies of the pin are
  equal (P1), the publish step executed against a wrong tarball stops before
  `sudo install` (W1, W2), the ensure function's paths (E1-E5), and the gate as
  real root (G1-G4).

## Why

BH-2059 made CI fail instead of skip share-publish-clean's gitleaks arm, but
the pool's gate runs suites as `nobody` under `env -i` with neither
`GITLEAKS_REQUIRED` nor gitleaks, so the arm still skipped on every pool and
box gate. The publish workflow unpacked whatever the download returned.

## The rule this adds

A gitleaks version bump now moves THREE copies of the pin together:
harness-ci.yml's `install gitleaks` step, publish-share.yml's `Install
gitleaks` step and `bin/lib/gitleaks-pin.sh`, plus the sha in both
`KNOWN_PUBLIC_CHECKSUMS` lists (`bin/share/mapping.py` and
`bin/share/overlay/tests/no-client-identifiers-test.sh`). P1 is red until the
three agree.

## Not changed

The `local`, `remote` and `plan` runners. CI's `local` run already installs the
pin and exports `GITLEAKS_REQUIRED=1`. `fly/Dockerfile` bakes no gitleaks: the
gate installs it at run time only when a selected suite probes for it, which
covers both Fly and Orgo boxes with no image rebuild. On an ephemeral Fly
builder that is one ~10 MB download per gate that needs it.
