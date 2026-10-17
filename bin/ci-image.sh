#!/bin/bash
# bin/ci-image.sh — the cromford CI image: its tag, and the switch that
# says whether a harness-ci run uses it (BH-7255).
#
#   ci-image.sh inputs        the files the tag hashes, one per line, sorted
#   ci-image.sh tag           12 hex: sha256 over `path NUL content NUL` of each input
#   ci-image.sh ref           ghcr.io/example-org/cromford-ci:<tag>
#   ci-image.sh stage <dir>   copy only the inputs into <dir> (the build context)
#   ci-image.sh mode          `image` or `host`, from CI_IMAGE_VAR and CI_IMAGE_LABEL
#   ci-image.sh ensure        the ci-image job's step: decide the mode, make sure
#                             the tag exists (build + push it when it does not),
#                             and write `ref=<ref>` (image) or `ref=` (host) to
#                             $GITHUB_OUTPUT as the LAST thing it does
#
# THE SWITCH. CI_IMAGE_VAR is the repo variable `CI_IMAGE`; CI_IMAGE_LABEL is
# `true` when the PR carries the `ci-image` label (the workflow passes
# `contains(labels, 'ci-image')`, an exact name match). The table:
#   CI_IMAGE=on                 image
#   CI_IMAGE=off                host, whatever the label says (the kill switch)
#   CI_IMAGE unset, label true  image (one PR run in the image)
#   CI_IMAGE unset, label false host (today's path; the default)
#   anything else               rc 2, by name. `ON`, `true`, `1` or ` on` never
#                               switch a run silently either way.
#
# A MISSING TAG FAILS BY NAME. In image mode `ensure` asks the registry for
# the tag. When it is not there it builds the image from the staged inputs and
# pushes it. A failed login, build or push is
#   ::error::ci-image: <ref> is missing and could not be built (<step>)
# and rc 1, so lint, console-ui, worker-jobs and tests-shard do not start.
# It never falls back to the host. In host mode it calls no docker at all.
#
# Exit: 0 ref written (present, built+pushed, or host), 1 the image is missing
# and could not be made, 2 misuse or a bad switch value or an unreadable input.
#
# Test seams: CI_IMAGE_ROOT (the checkout, default this script's repo), and
# docker found on PATH. GHCR_USER + GHCR_TOKEN, when both are set, are a
# `docker login ghcr.io` before the registry is asked.
set -uo pipefail

ROOT="${CI_IMAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_NAME=ghcr.io/example-org/cromford-ci

# Sorted (LC_ALL=C). The Dockerfile COPYs exactly these besides itself.
INPUTS=(
  ci-images/cromford/Dockerfile
  console-ui/package-lock.json
  console-ui/package.json
  fly/testhost/node-install.sh
  worker/jobs/package-lock.json
  worker/jobs/package.json
)

die2() { echo "ci-image: $*" >&2; exit 2; }

cmd_inputs() { printf '%s\n' "${INPUTS[@]}"; }

cmd_tag() {
  local f h
  for f in "${INPUTS[@]}"; do
    [ -r "$ROOT/$f" ] || die2 "cannot read input $f under $ROOT"
  done
  h=$(for f in "${INPUTS[@]}"; do printf '%s\0' "$f"; cat "$ROOT/$f"; printf '\0'; done | sha256sum | cut -c1-12)
  [[ "$h" =~ ^[0-9a-f]{12}$ ]] || die2 "sha256sum gave no hash"
  printf '%s\n' "$h"
}

cmd_ref() {
  local t
  t=$(cmd_tag) || exit 2
  printf '%s:%s\n' "$REPO_NAME" "$t"
}

cmd_stage() {
  local dir="${1:-}" f
  [ -n "$dir" ] || die2 "usage: ci-image.sh stage <dir>"
  for f in "${INPUTS[@]}"; do
    [ -r "$ROOT/$f" ] || die2 "cannot read input $f under $ROOT"
    mkdir -p "$dir/$(dirname "$f")" && cp "$ROOT/$f" "$dir/$f" || die2 "cannot stage $f into $dir"
  done
}

# mode_why -> "image <why>" or "host <why>", rc 2 on a bad value.
mode_why() {
  local v="${CI_IMAGE_VAR-}" l="${CI_IMAGE_LABEL-}"
  case "$l" in true|false|'') ;; *) die2 "CI_IMAGE_LABEL '$l' is not true or false" ;; esac
  case "$v" in
    on)  echo "image CI_IMAGE=on" ;;
    off) echo "host CI_IMAGE=off" ;;
    '')  if [ "$l" = true ]; then echo "image the ci-image label"; else echo "host CI_IMAGE unset"; fi ;;
    *)   die2 "CI_IMAGE '$v' is not on, off or unset — refusing to pick host or image for it" ;;
  esac
}

cmd_mode() { local m; m=$(mode_why) || exit 2; printf '%s\n' "${m%% *}"; }

put_ref() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'ref=%s\n' "$1" >> "$GITHUB_OUTPUT"; fi
}

fail1() { echo "::error::ci-image: $1 is missing and could not be built ($2)"; exit 1; }

cmd_ensure() {
  local m ref ctx
  m=$(mode_why) || exit 2
  if [ "${m%% *}" = host ]; then
    echo "ci-image: host (${m#* })"
    put_ref ""
    return 0
  fi
  ref=$(cmd_ref) || exit 2
  command -v docker >/dev/null 2>&1 || fail1 "$ref" "no docker on this runner"
  if [ -n "${GHCR_USER:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
    printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null \
      || fail1 "$ref" "docker login ghcr.io"
  fi
  if docker manifest inspect "$ref" >/dev/null 2>&1; then
    echo "ci-image: $ref (present; ${m#* })"
    put_ref "$ref"
    return 0
  fi
  ctx=$(mktemp -d) || fail1 "$ref" "mktemp"
  # shellcheck disable=SC2064 # expand ctx now: it is the one dir to remove
  trap "rm -rf '$ctx'" EXIT
  ( cmd_stage "$ctx" ) || fail1 "$ref" "stage"
  docker build --platform linux/amd64 -t "$ref" -f "$ctx/ci-images/cromford/Dockerfile" "$ctx" \
    || fail1 "$ref" "docker build"
  docker push "$ref" || fail1 "$ref" "docker push"
  echo "ci-image: $ref (built+pushed; ${m#* })"
  put_ref "$ref"
}

case "${1:-}" in
  inputs) cmd_inputs ;;
  tag)    cmd_tag ;;
  ref)    cmd_ref ;;
  stage)  shift; cmd_stage "$@" ;;
  mode)   cmd_mode ;;
  ensure) cmd_ensure ;;
  *) die2 "usage: ci-image.sh inputs|tag|ref|stage <dir>|mode|ensure" ;;
esac
