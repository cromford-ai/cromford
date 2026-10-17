# fly/lane-run.Dockerfile — the image of the Fly app `lane-run` (BH-6126).
# Built from the repo root: flyctl deploy . -c fly/lane-run.toml --build-only
# --push --image-label latest --build-arg HARNESS_COMMIT=$(git rev-parse HEAD)
# plus the three version build args named below (BH-6260).
# It bakes bin/, catalog/ and fleet.conf; a machine then pulls main of the
# harness repo before its claims (bin/lib/lane-run-code.sh). HARNESS_COMMIT is
# the `harness.commit` label bin/lane-fleet.sh logs, and /opt/harness/
# HARNESS_COMMIT when it is 7-40 hex (else no file, so the first sync runs).
# No secret and no env file is in the image: the entrypoint writes them from
# Fly secrets at boot. procps gives `ps`, which bin/fly-idle-reaper.sh probes
# with before it stops a machine (BH-6877): an image without it is never stopped.
#
# BH-6260 (the operator, 2026-10-17: "definitely let the fly machines have
# credentials"): the image bakes node, the claude CLI and the codex CLI, so
# bin/agent-call.sh can run the agent rungs of a lane (blocked-resolver's
# test-tamper adjudication and inline fix agent) on this machine. The blocks
# between the `# >>> bake-node` and `# >>> cli-pin-verify` markers are
# byte-identical copies of the same blocks in fly/Dockerfile (the pool image);
# tests/lane-run-agent-clis.bh-6260-test.sh fails when they drift. Each version
# is a required build arg, never "latest":
#   --build-arg NODE_VERSION=<bake.node.version row>
#   --build-arg CLAUDE_CODE_VERSION=<cli.claude_code.version row>
#   --build-arg CODEX_VERSION=<cli.codex.version row>
# The credentials are Fly secrets (CLAUDE_CODE_OAUTH_TOKEN, CODEX_AUTH_JSON),
# written to files by fly/lane-run-entrypoint.sh at boot, never baked here.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 util-linux tini gh openssl xz-utils procps \
 && rm -rf /var/lib/apt/lists/*
# bake-pin.sh: bake_require / bake_sha256 / bake_verify, the pool image's checks.
COPY fly/bake-pin.sh /opt/fly-boot/bake-pin.sh
# >>> bake-node
ARG NODE_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require NODE_VERSION "${NODE_VERSION:-}"; \
    curl -fsSL -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    bake_sha256 /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
      "node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'; \
    rm -f /tmp/node.tar.xz; \
    corepack enable; \
    bake_verify node "$NODE_VERSION" node --version; \
    npm --version
# <<< bake-node
# >>> cli-pin-verify
ARG CLAUDE_CODE_VERSION
ARG CODEX_VERSION
RUN set -eux; \
    if [ -z "${CLAUDE_CODE_VERSION:-}" ] || [ -z "${CODEX_VERSION:-}" ]; then \
      echo "FATAL: CLAUDE_CODE_VERSION and CODEX_VERSION build args are required (pinned, never latest)" >&2; \
      exit 1; \
    fi; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}"; \
    CV="$(claude --version | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"; \
    if [ "$CV" != "$CLAUDE_CODE_VERSION" ]; then \
      echo "FATAL: claude --version reports $CV, expected $CLAUDE_CODE_VERSION" >&2; exit 1; \
    fi; \
    XV="$(codex --version | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"; \
    if [ "$XV" != "$CODEX_VERSION" ]; then \
      echo "FATAL: codex --version reports $XV, expected $CODEX_VERSION" >&2; exit 1; \
    fi; \
    claude --version; \
    codex --version
# <<< cli-pin-verify
# HARNESS_COMMIT is declared below the tool layers: an ARG busts the cache of
# every RUN after it, and it changes on every commit.
ARG HARNESS_COMMIT=unknown
LABEL harness.commit=$HARNESS_COMMIT
COPY bin /opt/harness/bin
COPY catalog /opt/harness/catalog
COPY fleet.conf /opt/harness/fleet.conf
COPY fly/lane-run-entrypoint.sh /opt/lane-run/entrypoint.sh
RUN if printf '%s' "$HARNESS_COMMIT" | grep -qE '^[0-9a-f]{7,40}$'; then \
      printf '%s\n' "$HARNESS_COMMIT" > /opt/harness/HARNESS_COMMIT; fi
ENV HARNESS=/opt/harness
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/lane-run/entrypoint.sh"]
