# ci-images/base/Dockerfile — the shared CI base image, ghcr.io/example-org/ci-base.
# docs/CI-IMAGES.md says what is in it, how to bump a pin, how a repo adopts it
# and how to roll back. Build it with ci-images/base/build.sh, never by hand: the
# script stages the two-file context this file expects (this file and
# fly/testhost/node-install.sh as node-install.sh).
#
# EVERY NON-APT TOOL IS PINNED HERE, as an ARG with an exact x.y.z default, and
# each RUN fails the build unless `<tool> --version` reports that ARG. The pins
# are literals on purpose: the image rebuilds only when a file under
# ci-images/base/ changes, so a pin held anywhere else would never rebuild it.
# Downloads are checked: node against nodejs.org SHASUMS256.txt (by
# node-install.sh), ShellCheck against the literal SHELLCHECK_SHA256 (the same
# pin bin/ci-shellcheck.sh holds), gh and yq against the checksum list each
# release publishes, Playwright by npm's registry integrity. Apt packages are
# not version-pinned: they come from the trixie point release of the day.
#
# Layer order: apt, node, Playwright + Chromium (heavy, bumped rarely), then
# shellcheck, gh, yq (small, bumped more often), so a small bump does not
# rebuild the Chromium layer.

# The base of bin/run-tests-in-docker.sh's local test image. trixie for jq 1.7,
# which prints a whole float the way CI's runners do (see that script).
FROM debian:trixie-slim

LABEL org.opencontainers.image.source=https://github.com/example-org/cromford
LABEL org.opencontainers.image.description="Shared CI base image: node, Playwright Chromium, GNU tools, shellcheck, gh, yq"
ENV DEBIAN_FRONTEND=noninteractive

# bin/run-tests-in-docker.sh's apt set (its header says why each is there), plus
# sqlite3, tar, gzip and unzip. awk is gawk, as on CI's runners (#5686).
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash coreutils jq git curl ca-certificates util-linux procps xz-utils \
      python3 python3-yaml rsync gawk sqlite3 tar gzip unzip \
 && update-alternatives --set awk /usr/bin/gawk \
 && case "$(awk --version)" in "GNU Awk"*) ;; *) echo "awk is not GNU Awk" >&2; exit 1 ;; esac \
 && rm -rf /var/lib/apt/lists/*

# Node: the major .github/workflows/harness-ci.yml pins, at the bake.node.version
# row's value, through the test hosts' own sha256-checked installer. It refuses
# a node without node:sqlite or --experimental-strip-types.
ARG NODE_VERSION=22.23.2
COPY node-install.sh /usr/local/bin/ci-node-install.sh
RUN chmod 755 /usr/local/bin/ci-node-install.sh \
 && /usr/local/bin/ci-node-install.sh "$NODE_VERSION" \
 && test "$(node --version)" = "v$NODE_VERSION"

# Playwright and its Chromium. The Playwright version fixes the Chromium build,
# so this pin is the Chromium pin. 1.55.0 is the first Playwright that knows
# Debian 13; an older one maps trixie to Ubuntu 20.04 package names and
# --with-deps fails. A project whose own Playwright is a different version
# downloads its own browser (docs/CI-IMAGES.md).
ARG PLAYWRIGHT_VERSION=1.64.1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
 && test "$(playwright --version)" = "Version ${PLAYWRIGHT_VERSION}" \
 && playwright install --with-deps chromium \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

# Prisma's default engines cache dir; the project layers fill it.
RUN mkdir -p /root/.cache/prisma

# ShellCheck: SHELLCHECK_PIN and SHELLCHECK_SHA256_x86_64 of bin/ci-shellcheck.sh,
# so `bin/ci-tool-present.sh shellcheck <pin>` is true on this image.
ARG SHELLCHECK_VERSION=0.11.0
ARG SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
RUN cd /tmp \
 && curl -fsSL --retry 3 -o sc.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
 && echo "${SHELLCHECK_SHA256}  sc.tar.xz" | sha256sum -c - \
 && tar -xJf sc.tar.xz \
 && install -m 755 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
 && rm -rf sc.tar.xz "shellcheck-v${SHELLCHECK_VERSION}" \
 && shellcheck --version | grep -qx "version: ${SHELLCHECK_VERSION}"

# gh: the bake.gh.version row's value (the Fly image's gh), checked against the
# release's own checksum list, as fly/Dockerfile checks it.
ARG GH_VERSION=2.100.0
RUN cd /tmp \
 && curl -fsSL --retry 3 -O "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && curl -fsSL --retry 3 -O "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
 && grep -E "^[0-9a-f]{64}  gh_${GH_VERSION}_linux_amd64\.tar\.gz\$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && install -m 755 "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf "gh_${GH_VERSION}_linux_amd64" "gh_${GH_VERSION}_linux_amd64.tar.gz" "gh_${GH_VERSION}_checksums.txt" \
 && gh --version | grep -q "^gh version ${GH_VERSION} "

# yq: mikefarah's, the yq GitHub's ubuntu runners ship (Debian's yq package is a
# different program). The release's `checksums` file has one column per hash;
# `checksums_hashes_order` names them, so the SHA-256 column is looked up.
ARG YQ_VERSION=4.45.1
RUN cd /tmp \
 && base="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}" \
 && curl -fsSL --retry 3 -O "$base/yq_linux_amd64" \
 && curl -fsSL --retry 3 -O "$base/checksums" \
 && curl -fsSL --retry 3 -O "$base/checksums_hashes_order" \
 && col=$(grep -nx 'SHA-256' checksums_hashes_order | cut -d: -f1) && [ -n "$col" ] \
 && want=$(awk -v c="$((col + 1))" '$1 == "yq_linux_amd64" {print $c}' checksums) \
 && echo "$want" | grep -qxE '[0-9a-f]{64}' \
 && echo "$want  yq_linux_amd64" | sha256sum -c - \
 && install -m 755 yq_linux_amd64 /usr/local/bin/yq \
 && rm -f yq_linux_amd64 checksums checksums_hashes_order \
 && yq --version | grep -q "version v${YQ_VERSION}\$"
