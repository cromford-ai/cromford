# Test hosts run node 22 from the bake.node.version row

Doc: REMOTE-GATE

BH-1617.

## What changed

`fly/testhost/Dockerfile` no longer installs Debian trixie's apt `nodejs npm`,
which is a node 20. A new `ARG NODE_VERSION` has no default and is in the
`test -n` guard. `fly/testhost/node-install.sh` installs the nodejs.org tarball
at exactly that version. It checks the tarball against `SHASUMS256.txt`, and it
refuses to finish unless the installed node reports that version, can
`import('node:sqlite')`, and runs with `--experimental-strip-types`. `xz-utils`
joins the apt list for `tar -J`. Node is installed before codegraph's
`npm install -g`, and the npm comes from the tarball.

The value is the `bake.node.version` settings row, the same one `fly/Dockerfile`
bakes into the builder image (BH-1528). `bin/bake-seed.sh` on the hub prints it.
The deploy line in `docs/REMOTE-GATE.md` now passes it, and the image label is
`testhost-1617`.

## Why

On node 20, `tests/jobs-worker-test.sh` failed 18 checks (no `node:sqlite`) and
`tests/repro-gate-test.sh` failed 2 (no `--experimental-strip-types`). That
happened on unchanged main on every test host, so every gate run carried false
reds that the builder had to re-prove as pre-existing. CI runs node 22
(`actions/setup-node`, `node-version: '22'`).

## Still owed

The image has to be rebuilt and each of testhost-1..4 rolled while it is idle.
The commands are in `docs/REMOTE-GATE.md`, "Deploying the test host image".
That's an operator step. A build session never deploys.

## Tests

`tests/testhost-node-install.bh-1617-test.sh`
