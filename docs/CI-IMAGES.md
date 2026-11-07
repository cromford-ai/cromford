# CI images

The shared CI base image is `ghcr.io/example-org/ci-base`. It holds the tools that
every CI job used to install from scratch: node, Playwright's Chromium and its OS
libraries, the GNU tools the harness suites need, shellcheck, gh and yq. A CI
job that runs in the image starts its tests without a setup phase.

- Source: [`ci-images/base/Dockerfile`](../ci-images/base/Dockerfile)
- Build script: [`ci-images/base/build.sh`](../ci-images/base/build.sh)
- Workflow: `.github/workflows/ci-image.yml`
- Suite: `tests/ci-image-dockerfile.bh-7254-test.sh`

This is slice 1 of 4 (BH-7254). Slices 2 and 3 add the project layers
(project-6, then cromford CI). Slice 4 rolls the image out to the other
fleet repos: see [Rollout (slice 4)](#rollout-slice-4).

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

## Rollout (slice 4)

Slice 4 (BH-7256) moves every other fleet repo that runs CI onto the image. A
cromford build cannot open a PR in another repo. So each repo gets one
child ticket on its OWN board, and that project's build lane makes the PR.
The repos build in parallel.

### The kit

`ci-images/project-layer/` holds the files a child copies into its `ci/`
directory. The child ticket carries them inline, because a child build cannot
read cromford.

| Kit file | Goes to | What it does |
|---|---|---|
| `Dockerfile` | `ci/Dockerfile` | `FROM ${CI_BASE}`, with `ARG CI_BASE` pinned to a `ci-base:<sha12>`. It runs `npm ci` from the repo's lockfile into `/opt/ci/node/app` and writes `.lock-sha256` in the form `bin/ci-node-modules.sh` reads. An optional Prisma block is commented out. |
| `ci-image.sh` | `ci/ci-image.sh` | The `bin/ci-image.sh` contract (`inputs`, `tag`, `ref`, `stage`, `mode`, `ensure`; exit 0/1/2). The image name and the inputs come from `ci/ci-image.conf`. A missing tag that cannot be built is `::error::ci-image: <ref> is missing and could not be built (<step>)`, rc 1, and never a host run. |
| `ci-image.conf` | `ci/ci-image.conf` | `image=` (one line) and `input=` (one line per file the Dockerfile COPYs). `ci/Dockerfile` and the conf are always inputs. |
| `ci-image-job.yml` | the repo's test workflow | The `ci-image` job, and one test job with `needs: [ci-image]`, `container: image: ${{ needs.ci-image.outputs.ref }}`, `packages: read`, each install step behind `if: needs.ci-image.outputs.ref == ''`, and an image-only step that links the baked `node_modules`. |
| `child-ticket.md` | the child ticket body | Why, the steps, the acceptance, the kit files and the marker line `ci-image-rollout-of: BH-7256 repo=<owner/repo>`. |

The kit pins `ci-base:ad930bd49a76`, the tag that the push to main built for
the merge of #7286 (`ci-image.yml` tags a main push with the first 12 hex of
its sha). The switch is the slice 3 switch: `CI_IMAGE` unset and no
`ci-image` label is host mode, so a repo that copies the kit changes nothing
until a labelled run or `CI_IMAGE=on`.

### Filing the children

`bin/ci-image-rollout.sh` reads the targets from `bin/fleet-conf.sh
--projects`. It removes every sandbox repo and no other project. fleet.conf
has no sandbox column, so the rule is a name
rule: a project name with the dash token `sbx` (`cromford-sbx-linear`), or a
repo name that holds `sandbox` in any case (`example-org/cromford-sandbox-jira`).
Run it on the hub,
where each project's env file and a gh token that reads the repos are present:

```bash
bin/ci-image-rollout.sh plan --all          # runs-ci | on-image | no-ci | filed <ref> | unknown <why>
bin/ci-image-rollout.sh file --all          # dry run: `would file <project> <repo> :: <title>`
bin/ci-image-rollout.sh file --all --apply  # files the missing children
```

- "Runs CI" is a `.github/workflows` with one or more `*.yml` or `*.yaml`
  files. A readable repo without one is `no-ci`. An unreadable repo, a rate
  limit (gh rc 75) or an empty answer is `unknown <why>`, and the run exits 1.
- A repo already on the image is `on-image` and gets no child. The script
  reads this from the repo, not from a list of names. The rule: the
  `.github/workflows` list holds a file named exactly `ci-image.yml` or
  `ci-image.yaml`, or `ci/ci-image.conf` is a file. Slices 2 and 3
  (example-org/project-6, example-org/cromford) have `ci-image.yml`. A repo
  whose child PR merged has `ci/ci-image.conf`, so a re-run files no second
  child for it. A conf read that fails (not a 404) is `unknown conf-read-failed`,
  never `runs-ci`. `ci-image.yml.disabled`, `my-ci-image.yml` and a
  `ci-image.yml` directory do not count.
- A GitHub-Issues board (fleet.conf board prefix `-`) gets a REST issue with
  the `ai-build` label. An app board gets `POST <base>/boards/<first board
  id>/tickets`.
- The marker line is the dedup key. Before each create the script searches
  the board for it (all states). A row with the exact child title on an app
  board also counts. A failed or incomplete search refuses that project. A
  rerun files only the missing children.
- After an `--apply` run, wait before a re-run. GitHub search needs time
  (seconds to minutes) to index a new issue. A fast re-run does not see the
  new child and can file a duplicate. Run `plan --all` first and check that
  each filed repo shows `filed <ref>`. An `--apply` run that filed on a GitHub
  board prints the same warning on stderr.
- Knobs: `lib.ci-image-rollout.ci_rollout_curl_max_time` (curl `--max-time`
  of each app-board call, fallback 25 s, 5..120) and
  `lib.ci-image-rollout.ci_rollout_search_per_page` (`per_page` of the dedup
  search, fallback 100, 1..100). The registry entry is
  `catalog/lanes.d/_lib.ci-image-rollout.json`; the env names
  `CI_ROLLOUT_CURL_MAX_TIME` and `CI_ROLLOUT_SEARCH_PER_PAGE` work too.

Each child also asks for two things that need an operator or a repo admin:

- The ghcr grant: `ci-base`, Package settings, "Manage Actions access", add
  the repo with the Read role.
- The repo variable `CI_RUNNER` set to `"monkci-ubuntu-24.04-4"` where it is
  unset or `"ubuntu-latest"` (MonkCI, see [CI-RUNNERS.md](CI-RUNNERS.md)).

MonkCI and `container:`. On MonkCI a job container cannot reach the artifact
service, so `upload-artifact` and `download-artifact` fail in a job that has
`container:` (example-org/project-6 PR #3238). example-org/project-6 does not use
`container:`. Its `.github/actions/ci-image/action.yml` runs the job's `run:`
steps in the image through an in-image default shell, and the `uses:` steps
stay on the host. A child on MonkCI with an artifact step uses that pattern
for that job. The kit's `container:` path stays for the other jobs and for
GitHub-hosted runners. project-6 pins the same `ci-base:ad930bd49a76` as the
kit.

### Acceptance table

One green PR run before the change and one after, per repo. A row stays
`pending` until its child reports the two runs. The filer reads fleet.conf at
run time; the rows below are the 2026-11-02 `targets` output (15 projects).
cromford and project-6-os are `on-image`: their own slices moved them.

| Project | Repo | Child ticket | PR | Image tag | Runner | CI wall before | CI wall after |
|---|---|---|---|---|---|---|---|
| cromford | example-org/cromford | on-image (slice 3) | #7301 | see slice 3 | see slice 3 | see slice 3 | see slice 3 |
| project-6-os | example-org/project-6 | on-image (slice 2) | see slice 2 | see slice 2 | see slice 2 | see slice 2 | see slice 2 |
| project-1 | example-org/project-1 | pending | pending | pending | pending | pending | pending |
| project-2 | example-org/project-2 | pending | pending | pending | pending | pending | pending |
| project-3 | example-org/project-3 | pending | pending | pending | pending | pending | pending |
| project-4 | example-org/project-4 | pending | pending | pending | pending | pending | pending |
| project-5 | example-org/project-5 | pending | pending | pending | pending | pending | pending |
| project-6 | example-org/project-6-runtime | pending | pending | pending | pending | pending | pending |
| project-8 | example-org/project-8 | pending | pending | pending | pending | pending | pending |
| project-9 | example-org/project-9 | pending | pending | pending | pending | pending | pending |
| project-7 | example-org/project-7 | pending | pending | pending | pending | pending | pending |
| harness-console | example-org/cromford-console | pending | pending | pending | pending | pending | pending |
| cromford | example-org/cromford-web | pending | pending | pending | pending | pending | pending |
| project-6-desktop | example-org/project-6-desktop | pending | pending | pending | pending | pending | pending |
| project-21 | example-org/project-21 | pending | pending | pending | pending | pending | pending |

A repo that `plan` reports as `no-ci` gets no child; its row then says
`no-ci` in the Child ticket cell.

## Rollback

1. Find the previous good tag: the `ci-base` package page lists every
   `:<sha12>`, and each one is the commit it was built from.
2. Set the consumer's `FROM` (or `container: image:`) back to that `:<sha12>`.
3. If `:latest` must move back too, retag the good digest:
   `docker buildx imagetools create -t ghcr.io/example-org/ci-base:latest ghcr.io/example-org/ci-base:<good sha12>`.

## Base image digests

A tag can point at a new image at any time. So every public base image in a
committed Dockerfile is pinned by digest, and the tag stays on the line for
the reader (BH-9209, Aikido 57216460). These 5 lines carry a pin:

| File | FROM |
|---|---|
| `ci-images/base/Dockerfile` | `debian:trixie-slim@sha256:a72b4433de1c...` |
| `ci-images/cromford/Dockerfile` | `debian:trixie-slim@sha256:a72b4433de1c...` |
| `fly/testhost/Dockerfile` | `debian:trixie-slim@sha256:a72b4433de1c...` |
| `fly/Dockerfile` | `ubuntu:24.04@sha256:fe81560990fa... AS base` |
| `fly/lane-run.Dockerfile` | `ubuntu:24.04@sha256:fe81560990fa...` |

`ci-images/project-layer/Dockerfile` (`ARG CI_BASE=ghcr.io/example-org/ci-base:<sha12>`)
and `fly/hub/Dockerfile` (`ARG HUB_BASE_IMAGE`, no default, the build passes
the builder image) name images this repo builds. They carry no digest.

`tests/docker-base-digest.bh-9209-test.sh` reads every committed Dockerfile.
It fails on a `FROM` that names a public image without `@sha256:<64 hex>`. A
new Dockerfile must pin its base, or the test fails. A `FROM <stage>`,
`scratch`, an ARG with no default and a `ghcr.io/example-org/` or
`registry.fly.io/` image pass.

Schedule: refresh once a month. Refresh at once when a Debian or Ubuntu
security advisory names a package in the base.

Read the current digest of a tag (the multi-arch index digest):

```bash
docker buildx imagetools inspect debian:trixie-slim --format '{{json .Manifest.Digest}}'
```

On a box with no docker, use the registry API:

```bash
repo=library/debian tag=trixie-slim
tok=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" | jq -r .token)
curl -fsSI -H "Authorization: Bearer $tok" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://registry-1.docker.io/v2/$repo/manifests/$tag" | grep -i docker-content-digest
```

For `ubuntu:24.04`, set `repo=library/ubuntu tag=24.04`.

To bump a digest:

1. Read the new digest with one of the commands above.
2. Change every `FROM` that uses that tag in one PR.
3. Let `ci-image.yml` rebuild ci-base on that PR (it touches `ci-images/base/**`).
4. Rebuild the Fly images through their usual paths (`bin/fly-image-build.sh`, `bin/fly-image-refresh.sh`).
5. Run `bash tests/docker-base-digest.bh-9209-test.sh`.

## Limits

- amd64 only.
- Apt packages are not version-pinned. Two builds on two days can hold
  different trixie point releases. The pinned tools do not change.
- The `FROM` line pins the digest (BH-9209). The workflow summary still
  records the tag's current digest, so a run shows when the tag has moved.
- Tags accumulate: one `:<sha12>` per PR push and per main push. Nothing
  deletes them yet. To delete old versions: the `ci-base` package page,
  "Manage versions".
- A PR from a fork builds and smoke-tests the image but does not push it: its
  token has no `packages: write`.
