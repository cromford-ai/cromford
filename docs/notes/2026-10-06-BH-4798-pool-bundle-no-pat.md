# BH-4798: a box with no plain PAT no longer stops the pool at the env bundle

Doc: GH-REST, OPERATOR-SETUP

Follows `docs/notes/2026-09-24-C2-gh-app-default-cron.md`. That note's runbook
step 3 puts the PAT in `env/gh-pat` before step 4 runs
`bin/ensure-box-gh-app-default.sh`. On 2026-10-06 the small box got step 4
without step 3: the keyring logout took its only plain PAT, `bin/gh-token.sh
--pat` printed nothing, and `bin/fly-envbundle.sh` died "bundle missing
GH_TOKEN" for every cromford and project-8 pool spawn from
02:38Z on.

What changed:

- `bin/fly-envbundle.sh <project> <outdir> [--pool]`. With `--pool` and a hub
  armed for App tokens, a missing PAT is one `WARN: bundle has no GH_TOKEN`
  line on stderr and the bundle ships without a GH_TOKEN line. Unarmed, or with
  no flag (fly-dispatch, which ships the bundle as-is), it still dies. Any other
  third argument is a usage error.
- `bin/fly-pool.sh` spawn and `bin/fly-pool-rollout.sh` smoke pass `--pool`.
  The spawn now sends the bundler's stderr to `logs/fly-pool.log` (it used to
  be thrown away). Inside the App-token swap (marked `# >>> pool gh credential
  swap`), a machine that gets no App token AND has no PAT in its bundle is
  destroyed and its job unclaimed, rather than booted with no GitHub credential.
- `bin/ensure-box-gh-app-default.sh` step 5 refuses the keyring logout when no
  plain PAT survives it: no GH_TOKEN in `env/global.env` and nothing usable in
  `env/gh-pat` (an App token or the admin PAT does not count). It prints
  `logout SKIPPED`, raises one warn alert `--id gh-keyring-only-pat` that names
  `env/gh-pat`, still runs step 6, and exits 3. Once `env/gh-pat` exists, a
  re-run logs out and resolves that alert id.

Runbook, step 4 of the C2 note: if the script exits 3, write the PAT to
`env/gh-pat` (mode 600) on that box and run it again.

`docs/GH-REST.md` is unchanged: it documents the REST shim, not the PAT ladder
or the env bundle, and nothing in it became false.

Pinned by `tests/fly-envbundle-pool-nopat.bh-4798-test.sh`.
