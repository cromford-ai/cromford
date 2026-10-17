# A shared CI base image, ghcr.io/example-org/ci-base (BH-7254)

Doc: CI-IMAGES

Every CI job installed its tools from scratch. On project-6 that setup took about
1 minute per job. This change adds the image those jobs can start from. It is
slice 1 of 4: no CI job uses the image yet.

**What changed.**

- `ci-images/base/Dockerfile`: the image. Every non-apt tool is an `ARG` with an
  exact version, and each install checks the download and `--version`.
- `ci-images/base/build.sh <image> <sha> [--latest] [--push]`: builds from a
  two-file context and tags `:<sha12>`. It exits 2 on a usage error and 1 on a
  failed docker step.
- `.github/workflows/ci-image.yml`: runs `build.sh` when the image inputs
  change, or by hand. A PR pushes `:<sha12>` of its head. Only main moves
  `:latest`. A fork PR builds and does not push.
- `bin/share/sanitize.py`: the public copy drops the new workflow (it needs the
  CI_RUNNER fleet and ghcr write access).

**Decisions.**

- Playwright is 1.64.1, not the `bake.playwright.version` row (1.48.2).
  Playwright before 1.55.0 does not know Debian 13, and `--with-deps` fails there.
- gh and yq are checked against their release's checksum list, not a literal
  sha256. The build box could not reach github.com to read those lists.
- The `FROM` line has no digest, for the same reason. The run summary records
  the base digest.

See [CI-IMAGES](../CI-IMAGES.md).
