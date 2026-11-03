#!/bin/bash
# ci/ci-image.sh — this repo's CI image: its tag, and the switch that says
# whether a CI run uses it (BH-7256, the project-layer kit from
# example-org/cromford ci-images/project-layer/; the contract of
# cromford bin/ci-image.sh, with the image name and inputs in a conf).
#
#   ci-image.sh inputs        the files the tag hashes, one per line, sorted
#   ci-image.sh tag           12 hex: sha256 over `path NUL content NUL` of each input
#   ci-image.sh ref           <image>:<tag>
#   ci-image.sh stage <dir>   copy only the inputs into <dir> (the build context)
#   ci-image.sh mode          `image` or `host`, from CI_IMAGE_VAR and CI_IMAGE_LABEL
#   ci-image.sh ensure        the ci-image job's step: decide the mode, make sure
#                             the tag exists (build + push it when it does not),
#                             and write `ref=<ref>` (image) or `ref=` (host) to
#                             $GITHUB_OUTPUT as the LAST thing it does
#
# THE CONF is ci/ci-image.conf. `#` lines and blank lines are skipped. Every
# other line is one of:
#   image=ghcr.io/example-org/<repo>-ci   the image name, exactly one line
#   input=<repo path>                   a file the image is built from, one per line
# The inputs are the `input=` lines plus ci/Dockerfile and ci/ci-image.conf
# (always). A missing conf, no `image=`, two `image=`, an absolute or `..`
# path, or any other line is rc 2 by name.
#
# THE SWITCH. CI_IMAGE_VAR is the repo variable `CI_IMAGE`; CI_IMAGE_LABEL is
# `true` when the PR carries the `ci-image` label.
#   CI_IMAGE=on                 image
#   CI_IMAGE=off                host, whatever the label says (the kill switch)
#   CI_IMAGE unset, label true  image (one PR run in the image)
#   CI_IMAGE unset, label false host (the default)
#   anything else               rc 2, by name
#
# A MISSING TAG FAILS BY NAME. In image mode `ensure` asks the registry for
# the tag. When it is not there it builds the image from the staged inputs and
# pushes it. A failed login, build or push is
#   ::error::ci-image: <ref> is missing and could not be built (<step>)
# and rc 1, so the test jobs do not start. It never falls back to the host.
# In host mode it calls no docker at all.
#
# Exit: 0 ref written (present, built+pushed, or host), 1 the image is missing
# and could not be made, 2 misuse, a bad switch value, a bad conf or an
# unreadable input.
#
# Test seams: CI_IMAGE_ROOT (the checkout, default this script's repo), and
# docker found on PATH. GHCR_USER + GHCR_TOKEN, when both are set, are a
# `docker login ghcr.io` before the registry is asked.
set -uo pipefail

ROOT="${CI_IMAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONF_REL=ci/ci-image.conf
DOCKERFILE_REL=ci/Dockerfile
IMAGE=""
INPUTS=()

die2() { echo "ci-image: $*" >&2; exit 2; }

# load_conf — fills IMAGE and INPUTS (sorted, unique) from the conf, or rc 2.
load_conf() {
  local conf="$ROOT/$CONF_REL" line n=0 v
  local -a raw=("$DOCKERFILE_REL" "$CONF_REL")
  [ -r "$conf" ] || die2 "no conf at $conf (copy the kit's ci-image.conf example and set image= and input=)"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      image=*)
        v="${line#image=}"
        [ -z "$IMAGE" ] || die2 "$CONF_REL:$n: a second image= line"
        [[ "$v" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || die2 "$CONF_REL:$n: image '$v' is not a lowercase image name with no tag"
        IMAGE="$v" ;;
      input=*)
        v="${line#input=}"
        case "$v" in
          ''|/*|..|../*|*/..|*/../*) die2 "$CONF_REL:$n: input '$v' must be a repo-relative path with no .." ;;
        esac
        [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] || die2 "$CONF_REL:$n: input '$v' has a character outside A-Za-z0-9._/-"
        raw+=("$v") ;;
      *) die2 "$CONF_REL:$n: '$line' is not image=, input=, a # comment or blank" ;;
    esac
  done < "$conf"
  [ -n "$IMAGE" ] || die2 "$CONF_REL has no image= line"
  mapfile -t INPUTS < <(printf '%s\n' "${raw[@]}" | LC_ALL=C sort -u)
}

cmd_inputs() { load_conf; printf '%s\n' "${INPUTS[@]}"; }

cmd_tag() {
  local f h
  load_conf
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
  load_conf
  printf '%s:%s\n' "$IMAGE" "$t"
}

cmd_stage() {
  local dir="${1:-}" f
  [ -n "$dir" ] || die2 "usage: ci-image.sh stage <dir>"
  load_conf
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
  docker build --platform linux/amd64 -t "$ref" -f "$ctx/$DOCKERFILE_REL" "$ctx" \
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
