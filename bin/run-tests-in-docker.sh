#!/bin/bash
# bin/run-tests-in-docker.sh — run the shell suite on Linux, from anywhere.
#
# IT LIVES IN bin/ AND NOT IN tests/, AND THAT IS THE GUARD. This is a test
# RUNNER, not a test. In tests/ it matched the `for t in tests/*.sh` sweep that
# CI and every contributor use, so running the suite ran this, which built an
# image and ran the whole suite again inside it. That cost ten minutes per CI
# run and then failed the job. An env-var guard was the first fix and it was the
# wrong one: it keyed on $CI, which is unset on a laptop, so the recursion
# survived exactly where people would hit it by hand. Being outside the glob
# cannot be got wrong.
#
# THERE IS A SECOND RUNNER NOW, AND THIS ONE IS NOT GOING ANYWHERE.
# bin/remote-gate.sh (BH-1205) runs the same suites on the shared Fly test host
# — sixteen heavy suites concurrently in 28 s, against this script's ten local
# containers SIGKILLing each other past load 120 on a Mac drain (#1193). Use
# that when you have Fly access; use this one when you do not, or when you are
# reproducing a failure that only happens in this image. docs/REMOTE-GATE.md.
#
# WHY. The suite is written for the platform the fleet runs on: Debian, GNU
# coreutils, bash 5. On macOS a large minority of it fails for reasons that have
# nothing to do with the code under test — `mapfile` does not exist in bash 3.2,
# `date -d` is not a thing, `grep -P` is missing, `sed -i` wants an argument.
# Those failures are indistinguishable, at a glance, from real ones, and a
# developer who learns that "about thirty always fail" stops reading the list.
# This script removes the excuse: one command, the same Linux the boxes run.
#
#   bin/run-tests-in-docker.sh                  # whole suite, names of failures
#   bin/run-tests-in-docker.sh tests/foo.sh     # specific suites, FULL output —
#                                               # this is how you debug one
#   bin/run-tests-in-docker.sh --shard 0/4      # one quarter, the way CI runs it
#   IMAGE=other:tag bin/run-tests-in-docker.sh  # a different base image
#
# --shard i/n (BH-1192) picks the same quarter of the corpus CI's shard i runs,
# out of bin/lib/suite-runner.sh, so reproducing a red shard locally is the
# shard number and nothing else. It applies to the whole-suite run only: naming
# suites is how you debug them, and a shard that silently dropped three of four
# named suites would be its own bug.
#
# The image is built once and kept. Remove it with
# `docker image rm cromford-tests:trixie.5` if you want a clean rebuild
# (`cromford-tests:trixie.4` (mawk as awk), `:trixie.3` (no python3-yaml),
# `:trixie.2` (apt node 20) and `:trixie` (no rsync) are the older tags still on
# machines that built them — remove those to reclaim the space once nothing on
# the machine is using them).
#
# THE TAG SUFFIX MOVES WHENEVER THE PACKAGE LIST MOVES. Because the image is
# built once and kept, `docker image inspect` short-circuits the build, so a
# package added here never reaches a machine that already holds the old tag —
# which is how three harness-sync suites went on printing "rsync missing —
# skipping" on the Mac drain (BH-1128).
#
# It mounts the repo READ-ONLY and copies it to a scratch dir inside the
# container, because several suites write next to their fixtures and one of them
# regenerates a crontab. Your checkout is never modified.
#
# A REMOTE DOCKER_HOST SHIPS THE TREE INSTEAD OF MOUNTING IT (BH-1193). A bind
# mount resolves on the DAEMON's host, so against `DOCKER_HOST=ssh://root@<host>`
# the mount is a path that does not exist there and the container runs no suite
# at all. So on a remote endpoint this script stages the tree with rsync and
# does create -> cp -> start; the local path is untouched. The endpoint is
# resolved in one place, bin/lib/docker-host.sh, from the environment or from
# <env dir>/global.env, and a configured endpoint that does not answer is exit 2
# — never a quiet fall back to the machine the containers were moved off. So is
# a container that never ran to completion: on that path `docker start` answers
# 1 for a docker-level failure, and 1 is also a real suite count, so the status
# is only believed once `docker inspect` says the container reached `exited`.
# docs/notes/2026-09-22-BH-1193-remote-docker-host.md.
#
# Exit code is the number of failing suites, including the expected ones, capped
# at 125, so CI and a human read the same thing.
#
# MEASURED on the tree this script was added to, by running both:
#   macOS 15 / bash 3.2   96 pass   28 fail
#   debian trixie        121 pass    3 fail
# rsync was added to the image on 2026-09-20 (BH-1128) so the three harness-sync
# suites run instead of skipping — recount when you next run the full suite.
#
# The suites that fail here and nowhere else are listed in
# tests/known-container-failures.txt, which is the one place that list lives;
# the runner prints `expected` next to them in the failing list so a NEW failure
# stands out. They are NOT root-caused — they pass in CI on ubuntu-latest, so
# the difference is something about this image or about the
# read-only-mount-then-copy setup, not the code.
#
# An earlier version of this file guessed at explanations for a larger failure
# set and every guess was wrong; the real cause of most of them was that Debian
# bookworm ships jq 1.6, which prints a whole float as `100` where jq 1.7 prints
# `100.0`. That is why the base is trixie. Treat the remaining three the same
# way: measure before explaining.
#
# The count printed at the end of a run is the number to trust, not this comment.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGE="${IMAGE:-cromford-tests:trixie.5}"

# The spec is validated HERE, before an image build and a repo copy, and by the
# same function the container will use — a bad shard must cost a message, not
# ten minutes ending in a container that ran nothing.
# shellcheck source=lib/suite-runner.sh
. "$REPO/bin/lib/suite-runner.sh" || {
  echo "run-in-docker: cannot source bin/lib/suite-runner.sh" >&2; exit 2; }
# shellcheck source=lib/docker-host.sh
. "$REPO/bin/lib/docker-host.sh" || {
  echo "run-in-docker: cannot source bin/lib/docker-host.sh" >&2; exit 2; }
SHARD=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --shard)   [ $# -ge 2 ] || { echo "run-in-docker: --shard needs a spec like 0/4" >&2; exit 2; }
               SHARD="$2"; shift ;;
    --shard=*) SHARD="${1#--shard=}" ;;
    *)         ARGS+=("$1") ;;
  esac
  shift
done
if [ -n "$SHARD" ]; then
  suite_shard_parse "$SHARD" >/dev/null || exit 2
  [ "${#ARGS[@]}" -eq 0 ] || {
    echo "run-in-docker: --shard picks a slice of the WHOLE suite; drop it to run named suites." >&2; exit 2; }
fi
set -- ${ARGS[@]+"${ARGS[@]}"}

# ── the endpoint ────────────────────────────────────────────────────────────
# Resolved once, EXPORTED once, so every docker call below — info, image
# inspect, build, and the run — goes to the same daemon, and the image is built
# where the suites will run. An empty answer is the local daemon.
# The else branch is not tidiness: `DOCKER_HOST='   '` resolves to nothing and
# the line below says "the local docker daemon", but leaving the whitespace in
# the environment hands that garbage to every docker call under a message that
# says the opposite. docker then fails to parse it and the operator is pointed
# at Docker Desktop instead of at their own env.
ENDPOINT=$(docker_host_resolve)
if [ -n "$ENDPOINT" ]; then export DOCKER_HOST="$ENDPOINT"; else unset DOCKER_HOST; fi
REMOTE=0
docker_host_is_remote "$ENDPOINT" && REMOTE=1
echo "run-in-docker: running on $(docker_host_label "$ENDPOINT")"

command -v docker >/dev/null || {
  echo "run-in-docker: docker is not installed or not on PATH." >&2
  echo "  Install Docker Desktop (macOS) or docker.io (Linux), or run the" >&2
  echo "  suite natively on a Debian box: for t in tests/*.sh; do bash \$t; done" >&2
  exit 2
}
docker info >/dev/null 2>&1 || {
  if [ "$REMOTE" = 1 ]; then
    echo "run-in-docker: the docker daemon at $ENDPOINT is not responding, and nothing was run here instead." >&2
    echo "  Check the host is up and that DOCKER_HOST=$ENDPOINT is right, or unset it to use this machine." >&2
  else
    echo "run-in-docker: the docker daemon is not responding. Start Docker and retry." >&2
  fi
  exit 2
}

# ── the image ───────────────────────────────────────────────────────────────
# Deliberately small and explicit. Every package is here because a suite needs
# it, not because it might:
#   bash, coreutils   the suite's shell and the GNU flag set it assumes
#   jq                fixture JSON; several suites hard-refuse without it
#   git               suites that build throwaway repos to test the git lanes
#   curl, ca-certs    the http client the fixtures stub out but still invoke
#   util-linux        flock, which the locking suites exercise directly
#   procps            pgrep/pkill in the process-supervision suites
#   python3           the gate and alert-family helpers are python
#   python3-yaml      the workflow and .mergify.yml suites parse YAML (the test
#                     host, fly/testhost/Dockerfile, installs it too); without it
#                     they end rc 3 or skip on every local run
#   gawk              CI's shards run gawk; trixie's default awk is mawk, and the
#                     two parse an `awk -v` value differently (\( -> ( on gawk),
#                     so a suite passed here and failed in CI (#5686). awk IS
#                     gawk here: the build sets the alternative and fails if
#                     `awk --version` is not GNU Awk
#   xz-utils          node-install.sh unpacks the nodejs.org tar.xz
#   node              NOT from apt: the nodejs.org tarball of CI's major, for the
#                     worker unit tests under worker/ and locks-worker/
#                     (node:sqlite) — see the build below
#   rsync             bin/harness-sync.sh deploys with it; the three suites that
#                     drive it hard-skip without it, so the image was passing
#                     them by printing one line (BH-1128)
#
# The base is TRIXIE, not bookworm, for one reason: jq. Bookworm ships jq 1.6,
# which prints a whole float as `100`; CI's runner and jq 1.7 print `100.0`.
# Several suites compare that string, so on a bookworm image they fail with a
# diff that looks like a real regression and is not. Matching CI's jq is worth
# more than matching CI's distro name.
# NOT installed: semgrep and codegraph. Those suites skip cleanly when the tool
# is absent, and pulling them in would triple the image for two suites. CI
# installs them and sets *_REQUIRED=1 to turn the skip into a failure; this
# script deliberately does not, so a local run stays fast.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "run-in-docker: building $IMAGE (first run only)"
  # NODE: the node CI runs, not Debian's apt nodejs (a node 20 with no
  # node:sqlite, so the worker/jobs node tests
  # "did not run" here while CI passed them). The version comes from
  # bin/lib/test-image-node.sh (NODE_VERSION, else the bake.node.version row,
  # else the exact shipped .node-version) and is refused
  # unless its major is CI's. It is installed by fly/testhost/node-install.sh,
  # the test hosts' own installer (BH-1617): sha256-checked, and it refuses a
  # node without node:sqlite or --experimental-strip-types.
  # shellcheck source=lib/test-image-node.sh
  . "$REPO/bin/lib/test-image-node.sh" || { echo "run-in-docker: cannot source bin/lib/test-image-node.sh" >&2; exit 2; }
  NODE_PIN=$(test_image_node_version "$REPO") || { echo "run-in-docker: no node version to build $IMAGE with — nothing ran." >&2; exit 2; }
  # The context is `-`, the Dockerfile on stdin with NO context (BH-1193):
  # against ssh://root@<host> the client tars and ships any context, and $REPO
  # was 47 MB over the link before the build could start. So node-install.sh
  # travels as a build arg (base64, a few KB) and the Dockerfile has no COPY and
  # no ADD.
  NODE_INSTALL_B64=$(base64 < "$REPO/fly/testhost/node-install.sh" | tr -d '\n') && [ -n "$NODE_INSTALL_B64" ] \
    || { echo "run-in-docker: cannot read fly/testhost/node-install.sh — nothing ran." >&2; exit 2; }
  docker build -t "$IMAGE" --build-arg "NODE_VERSION=$NODE_PIN" \
    --build-arg "NODE_INSTALL_B64=$NODE_INSTALL_B64" - >/dev/null <<'DOCKERFILE'
FROM debian:trixie-slim
ARG NODE_VERSION
ARG NODE_INSTALL_B64
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash coreutils jq git curl ca-certificates util-linux procps xz-utils \
      python3 python3-yaml rsync gawk \
 && update-alternatives --set awk /usr/bin/gawk \
 && awk --version | head -n1 | grep -q '^GNU Awk' \
 && rm -rf /var/lib/apt/lists/*
RUN printf '%s' "$NODE_INSTALL_B64" | base64 -d > /usr/local/bin/testhost-node-install.sh \
 && chmod 755 /usr/local/bin/testhost-node-install.sh && /usr/local/bin/testhost-node-install.sh "$NODE_VERSION"
WORKDIR /work
DOCKERFILE
  [ $? -eq 0 ] || { echo "run-in-docker: image build failed." >&2; exit 2; }
fi

# ── run ─────────────────────────────────────────────────────────────────────
# HARNESS_TEST_SANDBOX is set in exactly two places (#463): here and the tests/
# step of CI's decisions job. Both are throwaway machines with no /root/harness
# to lose. A bin/ lane on a real box must never set it — it is the guard that
# stops a test from deleting the live install (#388).
# The loop lives in bin/lib/suite-runner.sh and the container gets it as a
# `bash -c` string, NOT on stdin. Delivering it on stdin instead (the old `-s`
# plus heredoc form) put the runner's own remaining lines on the same stdin
# every suite inherits, so the first suite that read stdin ate the summary, the
# failing list and the final exit, and a red run reported success. Nothing is
# attached to the container's stdin now, and the library closes stdin per suite
# as well — see its header. The literal old spelling is kept out of this file on
# purpose: the guard against it coming back is a plain grep.
if [ "$REMOTE" = 0 ]; then
  docker run --rm \
    -v "$REPO:/repo:ro" \
    -e "SUITES=$*" \
    -e "SUITE_SHARD=$SHARD" \
    -e HARNESS_TEST_SANDBOX=1 \
    "$IMAGE" bash -c 'set -uo pipefail; . /repo/bin/lib/suite-runner.sh && suite_runner_main'
  exit $?
fi

# ── the remote endpoint: ship the tree ──────────────────────────────────────
# -v above would name a path on the REMOTE host, where it does not exist, and
# docker would create an empty /repo and run nothing. So the tree is staged and
# copied INTO the container: create, cp, start, in that order. A container that
# was created and never started cannot report a green run, because the exit
# status is start's and nothing else's.
command -v rsync >/dev/null || {
  echo "run-in-docker: rsync is not on PATH, and $ENDPOINT needs it to ship the tree — nothing ran." >&2
  exit 2
}
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/run-in-docker.XXXXXX") || {
  echo "run-in-docker: cannot create a staging directory in ${TMPDIR:-/tmp} — nothing ran." >&2
  exit 2
}
CID=""
# Neither the container nor the staging dir outlives this process, killed or not.
cleanup() {
  [ -z "$CID" ] || docker rm -f "$CID" >/dev/null 2>&1
  rm -rf "$STAGE"
  return 0
}
trap cleanup EXIT INT TERM

# -rlptD rather than -a for the same reason bin/remote-gate.sh gives: owners do
# not survive the hop and git calls the result a dubious ownership. The exclude
# list is that script's, and docker cp honours no .dockerignore, so this stage
# is the only thing keeping .git out of the container.
mkdir -p "$STAGE/repo"
rsync -rlptD --delete \
  --exclude .git --exclude node_modules --exclude .claude --exclude .codegraph \
  "$REPO/" "$STAGE/repo/" >/dev/null 2>&1 || {
  echo "run-in-docker: staging the tree for $ENDPOINT failed (rsync) — nothing ran." >&2
  exit 2
}

CID=$(docker create \
  -e "SUITES=$*" \
  -e "SUITE_SHARD=$SHARD" \
  -e HARNESS_TEST_SANDBOX=1 \
  "$IMAGE" bash -c 'set -uo pipefail; . /repo/bin/lib/suite-runner.sh && suite_runner_main') || CID=""
[ -n "$CID" ] || {
  echo "run-in-docker: docker create failed on $ENDPOINT — nothing ran." >&2
  exit 2
}
docker cp "$STAGE/repo" "$CID:/repo" >/dev/null 2>&1 || {
  echo "run-in-docker: copying the tree into the container on $ENDPOINT failed — nothing ran." >&2
  exit 2
}
# -a, never -i: the container keeps the empty stdin that bin/lib/suite-runner.sh
# exists to guarantee (BH-514 — the first suite that read stdin ate the summary,
# the failing list and the exit status, and a red run reported success).
docker start -a "$CID" </dev/null
RC=$?
# A NON-ZERO STATUS IS ONLY A SUITE COUNT ONCE DOCKER SAYS THE CONTAINER RAN.
# `docker start` returns 1 for a DOCKER-level failure — the daemon died between
# the cp and here, the host refused the container — and 1 is also a perfectly
# ordinary "one suite failed", so the two are indistinguishable from the status
# alone. The local path never had this problem: `docker run` answers 125 there,
# which is outside the plausible count. So ask docker what happened: a container
# that reached `exited` ran the suites and its status is the run's; anything
# else (still `created`, or an inspect that cannot answer) is this file's
# exit 2, "the run could not happen".
if [ "$RC" != 0 ]; then
  STATE=$(docker inspect --format '{{.State.Status}}' "$CID" 2>/dev/null)
  if [ "$STATE" != exited ]; then
    echo "run-in-docker: the container on $ENDPOINT never ran to completion (state: ${STATE:-unknown}) — no suite was tested." >&2
    exit 2
  fi
fi
exit "$RC"
