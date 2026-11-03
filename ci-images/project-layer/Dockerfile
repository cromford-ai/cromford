# ci/Dockerfile — this repo's CI image: the shared ci-base plus this repo's own
# node_modules (BH-7256, the project-layer kit from example-org/cromford
# ci-images/project-layer/).
#
# ci-base already holds node, Playwright's Chromium and its OS libraries,
# shellcheck, gh, yq and the GNU tools (example-org/cromford
# docs/CI-IMAGES.md has the list and the pins). This layer adds only what the
# lockfile installs, so the CI jobs that run in it skip setup-node, `npm ci` and
# `playwright install`.
#
# PIN ci-base BY ITS :<sha12>. Never `:latest`: a rebuild of the base on
# cromford main would then change this repo's CI with no reviewed diff. To
# move the pin, edit CI_BASE below; the tag of this image moves with it.
#
# THE TAG IS THE CONTENT. ci/ci-image.sh hashes this file, ci/ci-image.conf and
# every `input=` file in that conf. A COPY source below that is not an `input=`
# line would change the image without moving the tag: list each one there.
#
# The build context is the staged inputs only (`ci/ci-image.sh stage <dir>`),
# at their repo paths. linux/amd64 only, as ci-base.
ARG CI_BASE=ghcr.io/example-org/ci-base:ad930bd49a76
FROM ${CI_BASE}

# The node_modules tree, from the lockfile. The CI job links the checkout's
# node_modules to it only when .lock-sha256 equals the checkout's lockfile
# hash. If the repo uses pnpm or yarn, change the lockfile name here, in
# ci/ci-image.conf and in the link step, and use the matching install command.
COPY package.json package-lock.json /opt/ci/node/app/
RUN set -eux; cd /opt/ci/node/app; npm ci --no-audit --no-fund; \
    sha256sum package-lock.json | cut -d' ' -f1 > .lock-sha256

# Prisma. Keep this block only when the repo runs `prisma generate` in CI: it
# bakes the engines into /root/.cache/prisma (empty in ci-base). Add
# `input=prisma/schema.prisma` to ci/ci-image.conf when you keep it.
# COPY prisma/schema.prisma /opt/ci/node/app/prisma/schema.prisma
# RUN set -eux; cd /opt/ci/node/app; npx prisma generate
