# ci-images/cromford/Dockerfile — the image that harness-ci.yml's lint,
# console-ui, worker-jobs and tests-shard jobs run in when the CI_IMAGE switch
# is on (BH-7255). Each tests-shard installed node, codegraph, semgrep, PyYAML,
# gitleaks, age, zstd and rsync before its first suite, and the two JS jobs ran
# `npm ci` on every run. This image has all of it, at the pins the workflow's
# guarded install steps check (bin/ci-tool-present.sh), so in image mode every
# guard finds its tool and no install runs.
#
# THE TAG IS THE CONTENT. bin/ci-image.sh hashes this file and the inputs it
# COPYs (`bin/ci-image.sh inputs`) into ghcr.io/example-org/cromford-ci:<12
# hex>. Change a pin or a lockfile and the tag moves; the ci-image job builds
# and pushes the new tag once, or fails by name. A COPY source that is not in
# that list would change the image without moving the tag, and
# tests/ci-image-use.bh-7255-test.sh is red on one.
#
# EVERY VERSION IS A LITERAL HERE, and each one equals the pin in
# .github/workflows/harness-ci.yml (or bin/ci-shellcheck.sh for ShellCheck).
# The suite above is red on a drift: an image that baked another version would
# make each guard install over it, and the image would save nothing.
#
# The context is the staged inputs only (`bin/ci-image.sh stage <dir>`), never
# the whole checkout. linux/amd64 only: the gitleaks and ShellCheck digests
# below are of the x86_64 assets. The Mac (arm64) pull is BH-7255 slice C1.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DO_NOT_TRACK=1

# The apt set of bin/run-tests-in-docker.sh's local image, plus age, zstd,
# openssl and the venv semgrep lives in. awk IS gawk, as in that image and on
# the CI shards (#5686: mawk parses an `awk -v` value differently).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash coreutils jq git curl ca-certificates util-linux procps xz-utils \
      python3 python3-yaml python3-venv rsync gawk age zstd openssl; \
    update-alternatives --set awk /usr/bin/gawk; \
    awk --version | head -n1 | grep -q '^GNU Awk'; \
    rm -rf /var/lib/apt/lists/*

# node: harness-ci.yml pins node-version '22'; this is the bake.node.version
# row on 2026-10-17. fly/testhost/node-install.sh checks the tarball against
# SHASUMS256.txt and refuses a node without node:sqlite or strip-types.
ARG NODE_VERSION=22.23.2
COPY fly/testhost/node-install.sh /usr/local/bin/testhost-node-install.sh
RUN set -eux; chmod 755 /usr/local/bin/testhost-node-install.sh; \
    /usr/local/bin/testhost-node-install.sh "$NODE_VERSION"

ARG CODEGRAPH_VERSION=1.5.0
RUN set -eux; \
    npm install -g --no-audit --no-fund "@colbymchenry/codegraph@${CODEGRAPH_VERSION}"; \
    codegraph --version | grep -qw "$CODEGRAPH_VERSION"; \
    codegraph telemetry off || true

ARG SEMGREP_VERSION=1.176.1
RUN set -eux; \
    python3 -m venv /opt/venv-semgrep; \
    /opt/venv-semgrep/bin/pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}"; \
    ln -sf /opt/venv-semgrep/bin/semgrep /usr/local/bin/semgrep; \
    semgrep --version | grep -qw "$SEMGREP_VERSION"

ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
RUN set -eux; \
    curl -fsSL -o /tmp/gitleaks.tar.gz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"; \
    echo "${GITLEAKS_SHA256}  /tmp/gitleaks.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks; \
    install -m 755 /tmp/gitleaks /usr/local/bin/gitleaks; \
    rm -f /tmp/gitleaks.tar.gz /tmp/gitleaks; \
    gitleaks version | grep -qw "$GITLEAKS_VERSION"

ARG SHELLCHECK_VERSION=0.11.0
ARG SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
RUN set -eux; \
    curl -fsSL -o /tmp/sc.tar.xz \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"; \
    echo "${SHELLCHECK_SHA256}  /tmp/sc.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/sc.tar.xz -C /tmp; \
    install -m 755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; \
    rm -rf /tmp/sc.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"; \
    shellcheck --version | grep -qw "$SHELLCHECK_VERSION"

# The two node_modules trees, from their lockfiles. bin/ci-node-modules.sh
# links the checkout's node_modules to these only when .lock-sha256 equals the
# checkout's lockfile hash, written here in the form it reads.
COPY worker/jobs/package.json worker/jobs/package-lock.json /opt/ci/node/worker-jobs/
RUN set -eux; cd /opt/ci/node/worker-jobs; npm ci --no-audit --no-fund; \
    sha256sum package-lock.json | cut -d' ' -f1 > .lock-sha256
COPY console-ui/package.json console-ui/package-lock.json /opt/ci/node/console-ui/
RUN set -eux; cd /opt/ci/node/console-ui; npm ci --no-audit --no-fund; \
    sha256sum package-lock.json | cut -d' ' -f1 > .lock-sha256
