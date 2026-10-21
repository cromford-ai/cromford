# fly/hub/Dockerfile — the hub image for the dedicated Fly machine (BH-7715).
# A thin layer on the pool builder image (fly/Dockerfile), which already holds
# tailscale, gh, git, jq, node, claude, codex, rsync and python3. This layer
# adds what a hub runs that a builder does not: cron, sshd, age and zstd for
# bin/state-backup.sh / bin/state-restore.sh, the aws CLI they use for the
# bucket, and flyctl for the pool lanes (fly-pool-tick.sh, fly-pool.sh,
# fly-dispatch.sh, fly-image-refresh.sh, fly-idle-reaper.sh). The base has no
# flyctl. It also bakes a pinned pnpm, because bin/bootstrap-machine.sh installs
# pnpm repos (project-1) with pnpm. Build it from the repo root:
#   docker build -f fly/hub/Dockerfile --build-arg HUB_BASE_IMAGE=<builder image ref> \
#     --build-arg FLYCTL_VERSION=<x.y.z> --build-arg PNPM_VERSION=<x.y.z> \
#     -t registry.fly.io/<hub app>:hub-<date> .
# The runbook is docs/notes/2026-10-20-BH-7715-hub-move.md.
ARG HUB_BASE_IMAGE
FROM ${HUB_BASE_IMAGE}

# The base layer's own apt line is unpinned too (the LTS is the pin).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      cron openssh-server age zstd python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/awscli \
 && /opt/awscli/bin/pip install --no-cache-dir awscli \
 && ln -sf /opt/awscli/bin/aws /usr/local/bin/aws

# Key login only; the entrypoint passes the host key from the volume.
RUN printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
      'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/hub.conf

# flyctl, pinned and sha256-checked against the release's checksums.txt. It goes
# in /usr/local/bin, NOT /root/.fly/bin: fly-pool.sh, fly-dispatch.sh and
# fly-image-refresh.sh put /root/.fly/bin before the rest of PATH, so a flyctl
# there would shadow the no-write shim of `hub-move.sh tick` (which refuses a
# no-write tick when /root/.fly/bin/flyctl exists).
ARG FLYCTL_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require FLYCTL_VERSION "${FLYCTL_VERSION:-}"; \
    curl -fsSL -o /tmp/flyctl.tar.gz \
      "https://github.com/superfly/flyctl/releases/download/v${FLYCTL_VERSION}/flyctl_${FLYCTL_VERSION}_Linux_x86_64.tar.gz"; \
    bake_sha256 /tmp/flyctl.tar.gz "https://github.com/superfly/flyctl/releases/download/v${FLYCTL_VERSION}/flyctl_${FLYCTL_VERSION}_checksums.txt" \
      "flyctl_${FLYCTL_VERSION}_Linux_x86_64.tar.gz"; \
    tar -xzf /tmp/flyctl.tar.gz -C /usr/local/bin flyctl; \
    rm -f /tmp/flyctl.tar.gz; \
    ln -sf flyctl /usr/local/bin/fly; \
    test ! -e /root/.fly/bin/flyctl; \
    bake_verify flyctl "$FLYCTL_VERSION" /usr/local/bin/flyctl version

# pnpm, pinned (BH-7715). The base's `corepack enable` leaves only a shim that
# downloads pnpm on first use; bootstrap-machine.sh runs pnpm on every pnpm repo
# it clones (npm stops on project-1's pnpm-only overrides key), so the hub
# bakes the binary. COREPACK_ENABLE_DOWNLOAD_PROMPT=0: no prompt without a TTY.
ARG PNPM_VERSION
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require PNPM_VERSION "${PNPM_VERSION:-}"; \
    corepack enable pnpm; \
    corepack install -g "pnpm@${PNPM_VERSION}"; \
    cd /tmp; bake_verify pnpm "$PNPM_VERSION" pnpm --version

COPY --chmod=755 fly/hub/entrypoint.sh /opt/hub-boot/entrypoint.sh
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/hub-boot/entrypoint.sh"]
