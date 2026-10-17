# CI images

The shared CI base image is `ghcr.io/example-org/ci-base`. It holds the tools that
every CI job used to install from scratch: node, Playwright's Chromium and its OS
libraries, the GNU tools the harness suites need, shellcheck, gh and yq. A CI
job that runs in the image starts its tests without a setup phase.

- Source: [`ci-images/base/Dockerfile`](../ci-images/base/Dockerfile)
- Build script: [`ci-images/base/build.sh`](../ci-images/base/build.sh)
- Workflow: `.github/workflows/ci-image.yml`
- Suite: `tests/ci-image-dockerfile.bh-7254-test.sh`

This is slice 1 of 4 (BH-7254). No CI job uses the image yet. Slices 2 and 3
add the project layers (project-6, then cromford CI). Slice 4 rolls the
image out to the other fleet repos.

## What is in the image

The base is `debian:trixie-slim`, the base of the local test image in
`bin/run-tests-in-docker.sh`. trixie ships jq 1.7, which prints a whole float
the way CI's runners do.

| Tool | Version | Source | How the build checks it |
|---|---|---|---|
| bash, coreutils, jq, git, curl, ca-certificates, util-linux (flock), procps, xz-utils, python3, python3-yaml, rsync, gawk, sqlite3, tar, gzip, unzip | trixie point release of the build day | apt | `awk` is set to gawk; the build fails if `awk --version` is not GNU Awk |
| node | `NODE_VERSION` (22.x) | nodejs.org tarball, through `fly/testhost/node-install.sh` | SHASUMS256.txt digest; `node --version`; node:sqlite and `--experimental-strip-types` work |
| Playwright + Chromium | `PLAYWRIGHT_VERSION` | npm `playwright`, then `playwright install --with-deps chromium` | npm registry integrity; `playwright --version` |
| shellcheck | `SHELLCHECK_VERSION` | GitHub release tarball | literal `SHELLCHECK_SHA256`; `shellcheck --version` |
| gh | `GH_VERSION` | GitHub release tarball | the release's `gh_<v>_checksums.txt`; `gh --version` |
| yq (mikefarah) | `YQ_VERSION` | GitHub release binary `yq_linux_amd64` | the release's `checksums` file (SHA-256 column); `yq --version` |

The exact versions are the `ARG` defaults in the Dockerfile. Read them there:
this page does not repeat them, so it cannot go stale.

Other facts a consumer needs:

- `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` is set in the image. Chromium is
  there.
- `/root/.cache/prisma` exists and is empty. A project layer fills it.
- The image is `linux/amd64` only.

Not in the image: semgrep, gitleaks, actionlint, codegraph. A project layer adds
what its CI needs.

### The pins and where they come from

- `NODE_VERSION`: the `bake.node.version` settings row (the Fly image's node).
  Its major must equal the `node-version` of `.github/workflows/harness-ci.yml`;
  the suite refuses another major.
- `PLAYWRIGHT_VERSION`: Playwright 1.55.0 is the first release that knows
  Debian 13. An older one maps trixie to Ubuntu 20.04 package names, and
  `--with-deps` fails. For that reason the image does not use the
  `bake.playwright.version` row (1.48.2 on 2026-10-17).
- `SHELLCHECK_VERSION` and `SHELLCHECK_SHA256`: copies of `SHELLCHECK_PIN` and
  `SHELLCHECK_SHA256_x86_64` in `bin/ci-shellcheck.sh`. The suite refuses a
  difference. With them equal, `bin/ci-tool-present.sh shellcheck <pin>` is true
  in the image and `bin/ci-shellcheck.sh` does not download anything.
- `GH_VERSION`: the `bake.gh.version` settings row (the Fly image's gh).
- `YQ_VERSION`: a mikefarah release. GitHub's ubuntu runners ship mikefarah yq,
  so a job that moves onto the image sees the same program. Debian's `yq`
  package is a different program.

## How to rebuild

The image rebuilds when a PR or a push to main changes `ci-images/base/**`,
`fly/testhost/node-install.sh` or `.github/workflows/ci-image.yml`.

1. Edit the pin in `ci-images/base/Dockerfile`.
2. Run `HARNESS_TEST_SANDBOX=1 bash tests/ci-image-dockerfile.bh-7254-test.sh`.
3. Open a PR. The `ci-image` run builds the image, pushes
   `ghcr.io/example-org/ci-base:<sha12>` (the PR head's first 12 hex) and runs the
   smoke test.
4. Read the run summary. It shows `image=`, `digest=`, `size=`, the digest of
   the `debian:trixie-slim` tag at run time and the smoke output.
5. After the merge, the push to main builds again and also moves `:latest`.

To rebuild without a change (for example, to take new apt security fixes), run
the workflow by hand: Actions, `ci-image`, "Run workflow", branch `main`.

To build on your own machine (docker with BuildKit):

```bash
ci-images/base/build.sh ghcr.io/example-org/ci-base "$(git rev-parse HEAD)"
```

Add `--push` to push (log in to ghcr.io first) and `--latest` to also tag
`:latest`. The script exits 2 on a usage error and 1 when a docker step fails.
On an arm64 machine (Apple silicon) the build runs emulated and is slow.

### Commands that print a new pin

- node: `curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.version | startswith("v22."))][0].version'`
- Playwright: `npm view playwright version`
- shellcheck: bump `bin/ci-shellcheck.sh` first (its header says how), then
  copy the two values.
- gh: `gh release view -R cli/cli --json tagName -q .tagName`
- yq: `gh release view -R mikefarah/yq --json tagName -q .tagName`

gh and yq need no sha256 edit: the build checks each download against the
checksum list of its own release.

## How a repo adopts it

A repo does not use `ci-base` directly. It builds a thin project layer:

```dockerfile
FROM ghcr.io/example-org/ci-base:<sha12>
# the repo's own dependencies: node_modules, the Prisma engines, ...
```

The project layer's tag is the hash of the repo's lockfile, so the layer
rebuilds only when the dependencies change. Slices 2 and 3 add the first two
layers.

Rules for a consumer:

- Pin `ci-base` by `:<sha12>`. Never use `:latest` in a consumer: a rebuild on
  main would then change every repo's CI without a reviewed diff.
- If the repo's own Playwright is a different version from the image's, its
  `playwright install` downloads its own Chromium. Match the version to use the
  baked browser.
- Another repo's workflow can pull the image only after the package grants it
  access: GitHub, example-org org, Packages, `ci-base`, Package settings, "Manage
  Actions access", add the repo with the Read role.

## Rollback

1. Find the previous good tag: the `ci-base` package page lists every
   `:<sha12>`, and each one is the commit it was built from.
2. Set the consumer's `FROM` (or `container: image:`) back to that `:<sha12>`.
3. If `:latest` must move back too, retag the good digest:
   `docker buildx imagetools create -t ghcr.io/example-org/ci-base:latest ghcr.io/example-org/ci-base:<good sha12>`.

## Limits

- amd64 only.
- Apt packages are not version-pinned. Two builds on two days can hold
  different trixie point releases. The pinned tools do not change.
- The `FROM` line has no digest. The workflow summary records the digest of
  `debian:trixie-slim` for each run.
- Tags accumulate: one `:<sha12>` per PR push and per main push. Nothing
  deletes them yet. To delete old versions: the `ci-base` package page,
  "Manage versions".
- A PR from a fork builds and smoke-tests the image but does not push it: its
  token has no `packages: write`.
