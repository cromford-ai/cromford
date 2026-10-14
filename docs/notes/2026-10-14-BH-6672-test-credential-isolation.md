# Tests get no GitHub credential, and build files carry no token shape (BH-6672)

Doc: TESTING

## The gap

A pool box exports `GH_TOKEN` as a live GitHub App installation token.
`tests/lib/scratch.sh` did not unset it, so every suite inherited it.
`tests/batch-resolve-test.sh` logged the token in full from its `gh` wrapper,
and a failed assertion printed it. `HARNESS_IMPACT_GATE_RUN` then copied the
suite output into `$BUILD/harness-suite` unscrubbed, and a review lens read it.

## What changed

- `tests/lib/scratch.sh` unsets `GH_TOKEN`, `GITHUB_TOKEN`,
  `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` and `MC_GIT_TOKEN`, and sets
  `GH_CONFIG_DIR` to `$SCRATCH/.gh-config`. `GH_APP_RATCHET_OWNER_TOKEN` stays:
  CI gives it to `tests/gh-app-ratchet-test.sh` on purpose. A suite that needs
  a token sets a fixture after it sources the lib.
- `tests/batch-resolve-test.sh` moves `HOME` and `GH_CONFIG_DIR` into `$T`,
  unsets the two token names again, and its `gh` wrapper logs only the first 4
  characters of the token plus `*`.
- `bin/test-trace-safety.sh` starts every test with `GH_TOKEN` and
  `GITHUB_TOKEN` set to a canary (`ghs_canary` + 30 hex characters, made once
  per run). A test whose stdout or stderr holds the canary is
  `HIT <test> printed-credential GH_TOKEN (…)`. It counts like every other hit,
  so `Tests cannot touch a real harness` goes red. Under `--gate` a failed
  test's output is printed through `token_redact`.
- New `bin/lib/token-redact.sh`: `token_redact` (stdin to stdout) and
  `token_redact_file <path>` (in place, fail closed). Each token shape becomes
  `<redacted:github-token>`: a classic `gh[pousr]_` token, the newer
  `gh[pousr]_<id>_<JWT>` installation token, a `github_pat_` token, and the
  credential in an `x-access-token:…@` URL.
- `RB_TOKEN_REDACT` in the harness suite run block of `bin/lib/rb/gates.sh`
  scrubs `$BUILD/<harness-suite file>` before `HARNESS_EXIT` is written (both
  arms), `$BUILD/pr-body.md` before the PR create (`bin/lib/rb/pr.sh`) and
  `$BUILD/pr-body-edit.md` before `gh pr edit` (`bin/lib/rb/result.sh`). A
  harness with no lib writes one `token-redact: … missing` line to
  `pipeline.log` and leaves the file as written.

## Not covered

- The six hand-written `github_pat_` seds in `bin/batch-resolve.sh` and
  `bin/lib/mc/rebase.sh` stay as they are.
- `pipeline.log`, `ALERTS.log` and lane logs are not scrubbed. No suite output
  goes there.

## Check on the box

```bash
grep -c 'redacted:github-token' /root/harness/builds/*/harness-suite* 2>/dev/null | grep -v ':0$'
grep -h 'token-redact:' /root/harness/builds/*/pipeline.log 2>/dev/null | tail
```
