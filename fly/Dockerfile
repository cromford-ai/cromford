# syntax=docker/dockerfile:1.7
# (^ BuildKit frontend pin: the warm-bake layer below uses a `--mount=type=secret`
#  for the clone token — never an ARG, never a layer.)
# fly/Dockerfile — builder image for the Fly.io builder trial (Phase 1).
#
# Publishable-safe by construction: NO secrets, NO repo, NO env baked in. The
# only credential a running machine ever holds is TS_AUTHKEY (a Fly secret,
# injected at runtime, never here); all client tokens arrive at job time over
# the tailnet into a tmpfs. See docs/FLY-BUILDER-TRIAL.md "Security".
#
# Toolchain (per the plan's "Fly specifics > Image"):
#   ubuntu:24.04 base; node + corepack/pnpm; bun; git; gh;
#   jq/unzip/curl/ca-certificates/openssh-client/rsync/python3-venv/tini;
#   python3-yaml (BH-1741: the mergify-template suites parse YAML with it);
#   (rsync: the bh-ci runner runs tests/ and two suites stage a tree with it —
#    without it they skipped and passed, BH-1128's shape again); tailscale;
#   claude CLI + codex CLI (failover-runner parity with agent-call.sh);
#   codegraph (telemetry off); semgrep in an isolated venv; rtk; playwright +
#   chromium baked at PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers.
# ENTRYPOINT is tini -> fly/entrypoint.sh.
#
# EVERY BAKED TOOL IS PINNED (BH-1517 for claude/codex, BH-1528 for the rest).
# Each tool is one `ARG <TOOL>_VERSION` declared directly above the one RUN that
# consumes it; bin/fly-image-build.sh passes the value from the settings row
# bake.<name>.version (manifest: bin/lib/bake-deps.sh) and refuses to build when
# a version resolves from nowhere. No version literal lives in this file — a
# default here would be exactly the hardcode the rows replace. Each RUN:
#   bake_require  the ARG is non-empty (fly/bake-pin.sh), else FATAL;
#   installs EXACTLY that version from a versioned artifact (never an
#     installer's "latest", never an apt repo that only serves the newest);
#   bake_sha256   where the vendor publishes a checksum list (node, gh, bun,
#     rtk) the download must match it; tailscale's apt repo is GPG-signed;
#     playwright/codegraph come from npm (registry integrity), semgrep from
#     PyPI (TLS only);
#   bake_verify   `<tool> --version` equals the ARG, else FATAL.
# Why an ARG and not a floating install: an install line whose text never
# changes is a layer Depot's cache serves forever (2.1.267 baked for weeks while
# the hub ran 2.1.280). A changed row changes one RUN line's text, which busts
# that layer and every layer after it IN ITS STAGE — and nothing else.
#
# STAGES (BH-1528) — so one small tool's bump never forces a warm rebake:
#   base  = apt packages + node. Everything else stands on it.
#   warm  = FROM base: the per-project checkout + install + build caches. It
#           needs only git + node + corepack, so it depends on base alone: a
#           bump of bun/gh/tailscale/codegraph/semgrep/rtk/playwright/claude/
#           codex never touches it. A node bump DOES rebake it (correct: the
#           node_modules and build caches are node-version-specific), and so
#           does any edit to base's lines.
#           Consequence: warm has none of final's tools. A repo postinstall
#           that expects playwright's OS libs, or downloads browsers into
#           /opt/pw-browsers, runs without them there (and warm's
#           /opt/pw-browsers is not copied); no current warm-env relies on it,
#           and a failing warm build is non-fatal.
#   final = FROM base: the toolchain, one pinned layer per tool, ordered from
#           rarely-bumped/heavy (playwright+chromium) to bumped-daily
#           (claude/codex, last), then COPY --from=warm. A tool bump re-runs
#           that tool's layer, the lighter ones after it, and the /opt/warm copy
#           (which re-runs every night anyway: WARM_BUST).
# Cost note: on a cold build (the first one after BH-1528, or a node bump)
# BuildKit runs the warm stage in PARALLEL with the tool layers on the same
# Depot builder, so RAM pressure is somewhat higher on that one build. It is
# neutral after that: WARM_BUST rebakes warm every night anyway, so "a tool bump
# never rebakes warm" saves the intra-day rebuilds (fleet-propagate on merge).
# A warm `next build` that runs out of JS heap is NON-fatal (.warm-build-failed;
# the image ships without .next/cache), so the refresh's retry never sees it;
# its fix is a NODE_OPTIONS line in that project's fly/warm-env file. The very
# first build after BH-1528 merges misses every layer (every RUN line's text
# changed): a one-time full rebuild of all images.
#
# Other open-detail decisions (simplest robust option):
#   - Base is ubuntu:24.04 (LTS) — the plan names 24.04 explicitly. The base apt
#     packages track the distro and are not version-pinned (the LTS is the pin).
#   - node from the official nodejs.org tarball for the exact NODE_VERSION.
#     NodeSource's apt repo publishes two suffix schemes for the same version
#     (22.23.2-1nodesource1 and 22.23.2-ns6.3.6), so an apt pin is ambiguous.
#     pnpm via `corepack enable` (no version pin — corepack resolves the repo's
#     packageManager field, keeping us in lockstep with each repo).
#   - gh from its versioned GitHub release tarball: the cli.github.com apt repo
#     serves ONLY the newest gh, so it cannot be pinned there. /usr/bin/gh is
#     kept as a symlink (bin/gh-rest-shim's last-resort path).
#   - tailscale from its official apt repo, `tailscale=<version>` — that repo
#     keeps every release.
#   - codegraph from npm (@colbymchenry/codegraph@<version>), the same
#     versioned bundle its install.sh fetches; the curl|sh installer only ever
#     serves the newest and is not version-addressable. DO_NOT_TRACK=1 plus
#     `codegraph telemetry off` bakes the opt-out in.
#   - semgrep isolated in /opt/venv-semgrep (never pollutes the repo's python),
#     symlinked onto PATH — mirrors run-build.sh's `command -v semgrep` contract.
#   - Playwright: pinned so the baked chromium matches the runtime
#     `npx playwright` the QA stage invokes. Repos may install their own newer
#     playwright into node_modules; the system chromium + OS deps satisfy
#     `--with-deps`.

FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DO_NOT_TRACK=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers

# --- base OS packages ---------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release \
      git jq unzip zip xz-utils \
      openssh-client rsync \
      python3 python3-venv python3-pip python3-yaml \
      tini \
      iproute2 iptables procps; \
    rm -rf /var/lib/apt/lists/*

COPY bake-pin.sh /opt/fly-boot/bake-pin.sh

# --- node (official tarball, pinned) + corepack/pnpm ---------------------------
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

# =============================================================================
FROM base AS warm
# --- per-project warm bake (build speed pass 2, 2026-08-13) -------------------
# Bake a recent checkout of the project repo, its installed node_modules, and
# the caches one production build produces (.next/cache, *.tsbuildinfo) into
# /opt/warm/repo. A pool machine then seeds /data/repos from this and does an
# incremental fetch+install instead of a cold clone+install (~5 min/machine).
# The nightly fly-image-refresh.sh keeps the warmth <=24h stale.
#
# Safety rails:
#   - The GitHub token arrives ONLY as a BuildKit secret mount; the origin URL
#     is reset to tokenless https right after the clone, so no credential ever
#     persists in a layer or in .git/config. NO real secret is baked, period.
#   - The bake build runs with DUMMY env from fly/warm-env/<project>.env
#     (checked in, dummy by construction — mirrors each repo's CI dummy-env
#     pattern; project-3's comes from its e2e.yml). WARM_BUILD_CMD in that file can
#     override the repo's build script (project-4 MUST override: its build script
#     runs a data-migration script an image bake must never execute).
#   - A failing warm build is non-fatal: the image keeps checkout+node_modules
#     (the bulk of the win) and marks .warm-build-failed for the runner's logs.
#     A HUNG one is too (BH-3463): fly/warm-build.sh kills the build after
#     WARM_BUILD_TIMEOUT_S (default 600 s), prints `warm-build: TIMED OUT` and
#     the image still ships — the pool is recorded warm=cold instead of the
#     whole bake dying at fleet-propagate's outer timeout with no image pushed.
#   - --depth=50 keeps .git small; the machine-side `git fetch` deepens it.
#   - WARM_BUST (build date, passed by fly-image-build.sh) busts the depot
#     layer cache daily so the nightly refresh re-clones instead of silently
#     reusing yesterday's layer.
#   - Everything no-ops when WARM_REPO_SLUG is empty (no slug/token on the
#     build host): /opt/warm is then an empty dir (the final stage's COPY needs
#     it to exist) and the image is simply the cold toolchain image.
#   - Size discipline: only checkout + node_modules + .next/cache +
#     *.tsbuildinfo earn their bytes; .next build output is pruned to cache/.
#   - ONE HOME FOR THE PNPM STORE (BH-1528 review F1). pnpm hardlinks every
#     node_modules/.pnpm file to its store (/root/.local/share/pnpm/store).
#     Hardlinks survive a COPY only when both ends travel in the SAME COPY, so
#     in the SAME RUN as the install (a rename keeps the inodes) the pnpm home
#     moves under /opt/warm and its old path becomes a symlink. The final stage
#     then ships store + node_modules in one `COPY --from=warm /opt/warm`, and
#     the store path the runner's warm install uses (builder-runner.sh) still
#     resolves, via the symlink that rides in with /root. Two COPYs doubled
#     every pnpm image's node_modules bytes (reproduced: 56.6 MB -> 109 MB);
#     `bake_warm_links` in the final stage fails the build if it regresses.
ARG WARM_REPO_SLUG=""
ARG WARM_PROJECT=""
ARG WARM_BUST=""
COPY warm-bake.sh /opt/fly-boot/warm-bake.sh
RUN chmod +x /opt/fly-boot/warm-bake.sh
COPY warm-env/ /opt/warm-env/
RUN --mount=type=secret,id=gh_token set -eux; \
    echo "warm bake: ${WARM_REPO_SLUG:-disabled} bust=${WARM_BUST:-none}"; \
    mkdir -p /opt/warm; \
    if [ -n "$WARM_REPO_SLUG" ]; then \
      TOKEN="$(cat /run/secrets/gh_token)"; \
      set +x; git clone --depth 50 "https://x-access-token:${TOKEN}@github.com/${WARM_REPO_SLUG}.git" /opt/warm/repo; set -x; \
      git -C /opt/warm/repo remote set-url origin "https://github.com/${WARM_REPO_SLUG}.git"; \
      bash /opt/fly-boot/warm-bake.sh /opt/warm/repo; \
      if [ -d /root/.local/share/pnpm ]; then \
        mv /root/.local/share/pnpm /opt/warm/pnpm-home; \
        ln -s /opt/warm/pnpm-home /root/.local/share/pnpm; \
      fi; \
    fi
# BH-3463: the build step is fly/warm-build.sh under WARM_BUILD_TIMEOUT_S
# (bin/fly-image-build.sh passes the pool.warm_build_timeout_s row, env, or 600).
# Copied HERE, after the clone+install RUN, so editing it never busts that layer.
COPY warm-build.sh /opt/fly-boot/warm-build.sh
ARG WARM_BUILD_TIMEOUT_S=600
RUN set -eux; \
    if [ -e /opt/warm/repo/.git ]; then \
      bash /opt/fly-boot/warm-build.sh /opt/warm/repo; \
      cd /opt/warm/repo; \
      if [ -d .next ]; then \
        find .next -mindepth 1 -maxdepth 1 ! -name cache -exec rm -rf {} + ; \
      fi; \
      rm -rf /opt/warm/repo/warm-bake.db* /root/.npm/_logs /tmp/* || true; \
    fi

# =============================================================================
FROM base AS final

# --- playwright + chromium (pinned; heaviest layer, rarely bumped: first) -----
# PLAYWRIGHT_BROWSERS_PATH is an ENV in base, so `install --with-deps` drops the
# browser + OS libs at /opt/pw-browsers; repos resolve this path at QA time.
# >>> bake-playwright
ARG PLAYWRIGHT_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require PLAYWRIGHT_VERSION "${PLAYWRIGHT_VERSION:-}"; \
    npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium; \
    bake_verify playwright "$PLAYWRIGHT_VERSION" npx --yes "playwright@${PLAYWRIGHT_VERSION}" --version; \
    ls -la "${PLAYWRIGHT_BROWSERS_PATH}"
# <<< bake-playwright

# --- semgrep in isolated venv, symlinked onto PATH (pinned) --------------------
# >>> bake-semgrep
ARG SEMGREP_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require SEMGREP_VERSION "${SEMGREP_VERSION:-}"; \
    python3 -m venv /opt/venv-semgrep; \
    /opt/venv-semgrep/bin/pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}"; \
    ln -sf /opt/venv-semgrep/bin/semgrep /usr/local/bin/semgrep; \
    bake_verify semgrep "$SEMGREP_VERSION" semgrep --version
# <<< bake-semgrep

# --- tailscale (official apt repo, pinned: the repo keeps every release) -----
# >>> bake-tailscale
ARG TAILSCALE_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require TAILSCALE_VERSION "${TAILSCALE_VERSION:-}"; \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg; \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "tailscale=${TAILSCALE_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    bake_verify tailscale "$TAILSCALE_VERSION" tailscale --version
# <<< bake-tailscale

# --- gh (versioned GitHub release tarball, pinned) ----------------------------
# >>> bake-gh
ARG GH_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require GH_VERSION "${GH_VERSION:-}"; \
    curl -fsSL -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    bake_sha256 /tmp/gh.tar.gz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
      "gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    tar -xzf /tmp/gh.tar.gz -C /tmp; \
    install -m 755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh; \
    ln -sf /usr/local/bin/gh /usr/bin/gh; \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"; \
    bake_verify gh "$GH_VERSION" gh --version
# <<< bake-gh

# --- bun (versioned GitHub release zip, pinned; static binary) ---------------
# bun-linux-x64 is the AVX2 build (bun.sh/install used to pick -baseline on
# CPUs without AVX2 by itself). Fly's x86 hosts have AVX2.
# >>> bake-bun
ARG BUN_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require BUN_VERSION "${BUN_VERSION:-}"; \
    curl -fsSL -o /tmp/bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip"; \
    bake_sha256 /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/SHASUMS256.txt" \
      bun-linux-x64.zip; \
    unzip -q /tmp/bun.zip -d /tmp/bun; \
    install -m 755 /tmp/bun/bun-linux-x64/bun /usr/local/bin/bun; \
    ln -sf bun /usr/local/bin/bunx; \
    rm -rf /tmp/bun /tmp/bun.zip; \
    bake_verify bun "$BUN_VERSION" bun --version
# <<< bake-bun

# --- codegraph (npm, pinned; telemetry hard-off) ------------------------------
# >>> bake-codegraph
ARG CODEGRAPH_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require CODEGRAPH_VERSION "${CODEGRAPH_VERSION:-}"; \
    npm install -g "@colbymchenry/codegraph@${CODEGRAPH_VERSION}"; \
    bake_verify codegraph "$CODEGRAPH_VERSION" codegraph --version; \
    codegraph telemetry off || true
# <<< bake-codegraph

# --- rtk: token-compressed Bash output for build sessions (pinned) ------------
# The boxes have run rtk since 2026-08-22, but pool builders had NO hooks at
# all — execute (the priciest stage) fed raw test/git/npm output into context.
# Same binary + PreToolUse hook shape as the box installs (rules/RTK.md is the
# canonical usage note; ~/.claude/CLAUDE.md's @RTK.md reference resolves here).
# >>> bake-rtk
ARG RTK_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require RTK_VERSION "${RTK_VERSION:-}"; \
    curl -fsSL -o /tmp/rtk.tar.gz \
      "https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/rtk-x86_64-unknown-linux-musl.tar.gz"; \
    bake_sha256 /tmp/rtk.tar.gz "https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/checksums.txt" \
      rtk-x86_64-unknown-linux-musl.tar.gz; \
    tar -xzf /tmp/rtk.tar.gz -C /tmp; \
    install -m 755 /tmp/rtk /usr/local/bin/rtk; \
    ln -sf /usr/local/bin/rtk /usr/bin/rtk; \
    rm -f /tmp/rtk.tar.gz /tmp/rtk; \
    bake_verify rtk "$RTK_VERSION" rtk --version; \
    mkdir -p /root/.claude; \
    printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/rtk hook claude","timeout":5}]}]}}' \
      > /root/.claude/settings.json
# <<< bake-rtk

# --- gitleaks: the leak gate a build must not skip (pinned, BH-5789) ---------
# tests/share-publish-clean.bh-795-test.sh skipped its gitleaks arm on a pool
# builder with no gitleaks, so a fixture leak showed up only in CI or the merge
# queue (#5700, #5282, #4967 broke batch #5770). The pin is bin/lib/gitleaks-pin.sh's,
# literal here because the build context is fly/ and cannot read it;
# tests/gitleaks-images.bh-5789-test.sh (G1) fails when the two differ. The
# tarball is checked against the pin's sha256 before anything is unpacked.
# >>> bake-gitleaks
ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
RUN set -eux; . /opt/fly-boot/bake-pin.sh; \
    curl -fsSL -o /tmp/gitleaks.tar.gz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"; \
    echo "${GITLEAKS_SHA256}  /tmp/gitleaks.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks; \
    install -m 755 /tmp/gitleaks /usr/local/bin/gitleaks; \
    rm -f /tmp/gitleaks.tar.gz /tmp/gitleaks; \
    bake_verify gitleaks "$GITLEAKS_VERSION" gitleaks version
# <<< bake-gitleaks

# --- throwaway Postgres for the harness suite run (pinned, BH-5962) ----------
# bin/lib/pg-test.sh starts it for a project with the fly-pool knob
# POOL_TEST_POSTGRES=1. The artifact is the versioned npm tarball of
# @embedded-postgres/linux-x64 (immutable, checked against the pin's sha256);
# the pin is bin/lib/pgtest-pin.sh's, literal here because the build context is
# fly/. pg-symlinks.json lists the soname links the npm postinstall would make.
# >>> bake-pgtest
ARG PGTEST_PKG_VERSION=16.14.0-beta.17
ARG PGTEST_SHA256=dfe7ecd8365ab907786e5f3d69179399f9675ac800153219efb2590257c2d551
ARG PGTEST_PG_VERSION=16.14
RUN set -eux; . /opt/fly-boot/bake-pin.sh; \
    curl -fsSL -o /tmp/pgtest.tgz \
      "https://registry.npmjs.org/@embedded-postgres/linux-x64/-/linux-x64-${PGTEST_PKG_VERSION}.tgz"; \
    echo "${PGTEST_SHA256}  /tmp/pgtest.tgz" | sha256sum -c -; \
    mkdir -p /tmp/pgtest-x /opt/pgtest; \
    tar -xzf /tmp/pgtest.tgz -C /tmp/pgtest-x; \
    cp -a /tmp/pgtest-x/package/native/. /opt/pgtest/; \
    jq -r '.[] | "\(.source) \(.target)"' /opt/pgtest/pg-symlinks.json | \
      while read -r s t; do ln -sf "$(basename "$s")" "/opt/pgtest/${t#native/}"; done; \
    chmod -R a+rX /opt/pgtest; \
    rm -rf /tmp/pgtest.tgz /tmp/pgtest-x; \
    bake_verify postgres "$PGTEST_PG_VERSION" env LD_LIBRARY_PATH=/opt/pgtest/lib /opt/pgtest/bin/postgres --version
# <<< bake-pgtest

# >>> project-webkit
# --- per-project blocks (BH-8319): kept only for a project whose row names them
# bin/fly-image-build.sh renders this file per project (bake_render_dockerfile,
# bin/lib/bake-deps.sh): a `project-<name>` block stays only when the row
# bake.<project>.<name>.version holds an exact x.y.z, else it is cut out with its
# markers. Every rust/webkit/cargo line lives inside a block, so a project with
# no row gets this file byte for byte as it was before BH-8319 and keeps every
# cached layer. The blocks stand after pgtest and before claude/codex, so a CLI
# bump never rebakes them.
# --- Tauri/webkit system packages (pinned: libwebkit2gtk-4.1-dev) -------------
# The dev package is pinned to the row's upstream version (bake_apt_version
# resolves the full Debian version, or FATALs when the archive dropped it). The
# companion packages track the LTS, the same as base's apt line.
ARG WEBKIT_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require WEBKIT_VERSION "${WEBKIT_VERSION:-}"; \
    apt-get update; \
    WEBKIT_DEB="$(bake_apt_version libwebkit2gtk-4.1-dev "$WEBKIT_VERSION")"; \
    apt-get install -y --no-install-recommends "libwebkit2gtk-4.1-dev=${WEBKIT_DEB}" \
      libxdo-dev libayatana-appindicator3-dev librsvg2-dev file; \
    rm -rf /var/lib/apt/lists/*; \
    bake_verify webkit "$WEBKIT_VERSION" dpkg-query -W -f='${Version}' libwebkit2gtk-4.1-dev
# <<< project-webkit
# >>> project-rust
# --- rust toolchain (official standalone tarball, pinned) ---------------------
# The versioned dist tarball, checked against its published .sha256, installed
# into /usr/local with only the components a build uses. The C toolchain cargo
# links with tracks the LTS. CARGO_HOME stays the default /root/.cargo.
ARG RUST_VERSION
RUN set -eux; . /opt/fly-boot/bake-pin.sh; bake_require RUST_VERSION "${RUST_VERSION:-}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev; \
    rm -rf /var/lib/apt/lists/*; \
    RUST_DIR="$(mktemp -d)"; \
    curl -fsSL -o "$RUST_DIR/rust.tar.xz" \
      "https://static.rust-lang.org/dist/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.xz"; \
    bake_sha256 "$RUST_DIR/rust.tar.xz" "https://static.rust-lang.org/dist/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.xz.sha256" \
      "rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.xz"; \
    tar -xJf "$RUST_DIR/rust.tar.xz" -C "$RUST_DIR"; \
    "$RUST_DIR/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu/install.sh" --prefix=/usr/local \
      --components=rustc,cargo,rust-std-x86_64-unknown-linux-gnu,clippy-preview,rustfmt-preview; \
    rm -rf "$RUST_DIR"; \
    bake_verify rust "$RUST_VERSION" cargo --version
# <<< project-rust
# --- claude CLI + codex CLI (npm global, PINNED; failover parity w/ agent-call.sh) ---
# LAST of the tool layers: these move almost daily (cli.claude_code.version /
# cli.codex.version follow the hub's own update), so a bump here re-runs only
# this layer and the COPYs below it.
# ARGs declared right above the RUN that consumes them: no default of "latest"
# — an empty value here is a caller bug (bin/fly-image-build.sh refuses to build
# without both resolved) and the install below fails loudly rather than
# silently falling through to whatever npm resolves for an empty version spec.
#
# The block between the markers is extracted VERBATIM and RUN by
# tests/fly-image-cli-pin.bh-1517-test.sh against stub npm/claude/codex, so the
# pin-or-fail behaviour is proven, not merely grepped for.
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

# --- the warm bake, from its own stage ----------------------------------------
# /opt/warm is the runner's contract (/opt/warm/repo). /root carries what the
# warm install and build left in the caches the single-stage image used to bake
# alongside it: the pnpm store, the npm cache, corepack's pnpm binary, and the
# prisma/next caches. The runner's incremental install on a pool machine reuses
# them, so dropping them here would quietly make every first install slower.
# COPY merges directories: the toolchain's own /root/.claude/settings.json (rtk
# hook) is untouched because the warm stage never writes one. The pnpm store is
# NOT in /root: it lives in /opt/warm/pnpm-home (see the warm stage's "ONE HOME
# FOR THE PNPM STORE"), so store and node_modules cross in ONE COPY and keep
# their hardlinks; /root carries only the symlink to it.
# warm-bake.sh + warm-env/ ride along at their old paths.
COPY --chmod=755 warm-bake.sh /opt/fly-boot/warm-bake.sh
COPY warm-env/ /opt/warm-env/
COPY --from=warm /root/ /root/
COPY --from=warm /opt/warm /opt/warm
# >>> warm-links
RUN set -eu; . /opt/fly-boot/bake-pin.sh; bake_warm_links /opt/warm
# <<< warm-links
# >>> project-rust-warm
# --- cargo crate cache on the warm layer (kept with project-rust) -------------
# After the /opt/warm COPY (which changes every night: WARM_BUST), so the crate
# cache is as fresh as the warm checkout. `cargo fetch --locked` for each
# Cargo.lock in the checkout (node_modules pruned) fills /root/.cargo. Bounded
# by the warm build's knob: bin/fly-image-build.sh passes the
# pool.warm_build_timeout_s value as WARM_CARGO_TIMEOUT_S (its own ARG: the
# warm stage timeout ARG stays out of this stage; 600 is the documented
# fallback). Non-fatal like the warm build: a failure prints
# `warm-cargo: FAILED` and leaves /opt/warm/.warm-cargo-failed.
ARG WARM_CARGO_TIMEOUT_S
RUN set -eu; \
    if [ -e /opt/warm/repo/.git ]; then \
      find /opt/warm/repo -maxdepth 3 -name node_modules -prune -o -name Cargo.lock -print | \
      while IFS= read -r lock; do \
        d="$(dirname "$lock")"; \
        echo "warm-cargo: cargo fetch --locked in $d"; \
        if ! timeout "${WARM_CARGO_TIMEOUT_S:-600}" cargo fetch --locked --manifest-path "$d/Cargo.toml"; then \
          echo "warm-cargo: FAILED in $d (non-fatal: the image ships without that crate cache)"; \
          : > /opt/warm/.warm-cargo-failed; \
        fi; \
      done; \
    fi
# <<< project-rust-warm

# --- entrypoint ---------------------------------------------------------------
# The runner scripts live on the volume at /data/harness/fly (compat-symlinked by
# entrypoint) so update-runners-style syncs update them without an image rebuild.
# The image ships its OWN copy at /opt/fly-boot as the boot floor; entrypoint
# prefers the volume copy when present. This keeps a machine bootable even before
# the first harness sync populates /data.
COPY entrypoint.sh /opt/fly-boot/entrypoint.sh
COPY builder-runner.sh /opt/fly-boot/builder-runner.sh
# BH-7430: the pull-path harness fetch (HARNESS_SHA set by bin/fly-pool.sh).
COPY harness-fetch.sh /opt/fly-boot/harness-fetch.sh
RUN chmod +x /opt/fly-boot/entrypoint.sh /opt/fly-boot/builder-runner.sh /opt/fly-boot/harness-fetch.sh

# BH-1574: the GitHub-call ledger shim first on PATH for every process in the
# machine (bin/gh-ledger/ holds ONLY `gh`; it runs /usr/local/bin/gh and writes
# one ledger row per request). The directory arrives with the harness sync on the
# volume, so until it exists this entry resolves nothing and gh is found exactly
# where it was. fly/builder-runner.sh exports the same prefix for images built
# before this line.
ENV PATH="/data/harness/bin/gh-ledger:${PATH}"

# tini as PID 1 reaps the background tailscaled/heartbeat processes cleanly.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/fly-boot/entrypoint.sh"]
