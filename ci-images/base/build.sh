#!/bin/bash
# ci-images/base/build.sh — build, and optionally push, the shared CI base image
# (ci-images/base/Dockerfile). .github/workflows/ci-image.yml runs it; a person
# runs the same command (docs/CI-IMAGES.md).
#
#   ci-images/base/build.sh <image> <sha> [--latest] [--push]
#
#   <image>   e.g. ghcr.io/example-org/ci-base (lowercase, no tag)
#   <sha>     the commit the image is built from: 12 to 40 lowercase hex. The
#             image is tagged <image>:<first 12 of sha>.
#   --latest  also tag <image>:latest (the workflow passes it on main only)
#   --push    push every tag, then print image=, digest= and size= lines
#
# The build context is a fresh temp dir holding exactly the Dockerfile and
# fly/testhost/node-install.sh (as node-install.sh), not the repo: a repo-root
# context ships tens of MB to the daemon (BH-1193). It is removed on every exit.
#
# Exit: 0 built (and pushed); 1 a docker step failed (nothing is pushed after a
# failed build); 2 usage error, docker is never called.
set -uo pipefail
usage() { [ -n "${1:-}" ] && echo "build.sh: $1" >&2
  echo "usage: ci-images/base/build.sh <image> <sha> [--latest] [--push]" >&2; exit 2; }

IMAGE="" SHA="" LATEST=0 PUSH=0
for a in "$@"; do
  case "$a" in
    --latest) LATEST=1 ;;
    --push)   PUSH=1 ;;
    -h|--help) usage ;;
    -*) usage "unknown flag: $a" ;;
    *) if [ -z "$IMAGE" ]; then IMAGE="$a"
       elif [ -z "$SHA" ]; then SHA="$a"
       else usage "unexpected argument: $a"; fi ;;
  esac
done
[ -n "$IMAGE" ] || usage "no image name"
[[ "$IMAGE" =~ ^[a-z0-9][a-z0-9._/:-]*$ ]] && [[ "$IMAGE" != *: ]] || usage "image '$IMAGE' is not a lowercase image name"
[[ "$SHA" =~ ^[0-9a-f]{12,40}$ ]] || usage "sha '$SHA' is not 12 to 40 lowercase hex"
SHA12="${SHA:0:12}"

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
CTX=$(mktemp -d) || { echo "build.sh: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$CTX"' EXIT
cp "$HERE/Dockerfile" "$CTX/Dockerfile" \
  && cp "$REPO/fly/testhost/node-install.sh" "$CTX/node-install.sh" \
  || { echo "build.sh: cannot stage the build context" >&2; exit 1; }

TAGS=("$IMAGE:$SHA12")
[ "$LATEST" = 1 ] && TAGS+=("$IMAGE:latest")
args=(build --platform linux/amd64 --cache-from "$IMAGE:latest" --build-arg BUILDKIT_INLINE_CACHE=1)
for t in "${TAGS[@]}"; do args+=(-t "$t"); done
args+=("$CTX")

echo "build.sh: docker ${args[*]}" >&2
docker "${args[@]}" || { echo "build.sh: docker build failed; nothing pushed" >&2; exit 1; }
[ "$PUSH" = 1 ] || exit 0

for t in "${TAGS[@]}"; do
  docker push "$t" || { echo "build.sh: docker push $t failed" >&2; exit 1; }
done
digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE:$SHA12" \
  | grep -E "^${IMAGE//./\\.}@sha256:[0-9a-f]{64}\$" | head -n1)
size=$(docker image inspect --format '{{.Size}}' "$IMAGE:$SHA12")
[ -n "$digest" ] || { echo "build.sh: pushed, but $IMAGE:$SHA12 has no $IMAGE@sha256 repo digest" >&2; exit 1; }
[[ "$size" =~ ^[0-9]+$ ]] || { echo "build.sh: docker image inspect gave size '$size'" >&2; exit 1; }
echo "image=$IMAGE:$SHA12"
echo "digest=$digest"
echo "size=$size"
