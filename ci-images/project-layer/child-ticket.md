## Why

the operator (2026-10-17): every project's CI must start from a prebuilt image, not install its tools in every job. The shared base `ghcr.io/example-org/ci-base` exists (example-org/cromford#7254). cromford CI uses it (example-org/cromford#7255). This ticket moves @@REPO@@ onto it. It is one child of example-org/cromford#7256. Each fleet repo has its own child, so the repos build in parallel.

## What

1. Copy the three kit files below into this repo: `ci/Dockerfile`, `ci/ci-image.sh` (mode 755), `ci/ci-image.conf`.
2. In `ci/ci-image.conf`, set one `input=` line for each file that `ci/Dockerfile` COPYs. If the repo uses `pnpm-lock.yaml` or `yarn.lock`, use that lockfile and its install command in the Dockerfile and in the link step.
3. Keep the Prisma block in `ci/Dockerfile` only if CI runs `prisma generate`.
4. Add the `ci-image` job from the workflow block below to the workflow that runs the tests.
5. On each test job: add `needs: [ci-image]`, `container:` with `image: ${{ needs.ci-image.outputs.ref }}` and the ghcr credentials, and `permissions: packages: read`. If `CI_RUNNER` is MonkCI and the job uses upload-artifact or download-artifact, do not use `container:` on that job. Follow example-org/project-6 `.github/actions/ci-image/action.yml`: the job's `run:` steps execute in the image through an in-image default shell, and the `uses:` steps stay on the host (project-6 PR #3238: on MonkCI a job container cannot reach the artifact service).
6. On each test job: put `if: needs.ci-image.outputs.ref == ''` on every setup-node, `npm ci` and `playwright install` step. Add the link step with `if: needs.ci-image.outputs.ref != ''` before the first test command.
7. If the repo variable `CI_RUNNER` is unset or `"ubuntu-latest"`, set it to `"monkci-ubuntu-24.04-4"` (MonkCI, the value cromford uses; docs/CI-RUNNERS.md in cromford). Give each job `runs-on: ${{ fromJSON(vars.CI_RUNNER || '"ubuntu-latest"') }}`.
8. Ask an operator for the ghcr grant: GitHub, example-org org, Packages, `ci-base`, Package settings, "Manage Actions access", add @@REPO@@ with the Read role. Without it the image build cannot pull `ci-base`.
9. Open the PR with the `ci-image` label. That run uses the image. After one green labelled run, set the repo variable `CI_IMAGE=on`.

If the repo has a test job that already runs in a container, keep it and note it in the PR body.

## Acceptance

- No CI job runs setup-node, `npm ci` or `playwright install` when the image exists.
- A missing image fails the `ci-image` job by name: `::error::ci-image: <ref> is missing and could not be built (<step>)`.
- Report on this ticket and on example-org/cromford#7256: CI wall time of one green PR run before the change and one after, the image tag (`@@IMAGE@@:<tag>`), and the runner.

## Kit: ci/Dockerfile

```dockerfile
@@KIT_DOCKERFILE@@
```

## Kit: ci/ci-image.sh

```bash
@@KIT_SCRIPT@@
```

## Kit: ci/ci-image.conf

```
@@KIT_CONF@@
```

## Kit: the workflow jobs

```yaml
@@KIT_JOB@@
```

ci-image-rollout-of: BH-7256 repo=@@REPO@@
