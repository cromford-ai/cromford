#!/bin/bash
# bin/lib/bootstrap-tool-pins.sh — pinned installs of Bun, Playwright and
# CodeGraph for bin/bootstrap-machine.sh (BH-9266). Sourced, never run.
#
# WHY. bootstrap-machine.sh piped the Bun web installer into a shell, installed
# CodeGraph from the `main` branch install script, and Playwright with no
# version (outside audit, cromford-ai/cromford#5 and #6). The Fly image already
# pins all three from the bake.<name>.version settings rows (fly/Dockerfile
# bake-bun, bake-codegraph, bake-playwright). This file gives a box the same
# pins through the same reader, bake_row_version (bin/lib/bake-deps.sh).
#
# FAIL-OPEN. No function here stops the caller, and the file has no early
# termination of the shell anywhere. A missing row, an unreachable jobs worker
# or a box with no HARNESS_SECRET gives the documented fallback and one WARN
# line per tool. A failed install gives one WARN line and rc 0 from btp_ensure.
# The caller's git identity step runs before this, and every step after it runs.
#
# Functions:
#   btp_version <name>           -> the version to pin on stdout, always rc 0
#   btp_installed <path-or-bin>  -> first dotted number of `<bin> --version`, empty if absent
#   btp_bun_asset                -> bun-linux-aarch64 | bun-linux-x64 | bun-linux-x64-baseline
#   btp_install_bun <v> <dir>    -> release zip, sha256 against SHASUMS256.txt; rc 0/1
#   btp_install_codegraph <v>    -> npm install -g @colbymchenry/codegraph@<v>; rc 0/1
#   btp_install_playwright <v>   -> npm install -g playwright@<v> + chromium; rc 0/1
#   btp_ensure <name>            -> skip when at the pin, else install; always rc 0
#   btp_ensure_all               -> bun, playwright, codegraph; always rc 0
#
# Env seams (tests). Each default is the production value:
#   BTP_BUN_RELEASE_BASE  https://github.com/oven-sh/bun/releases/download
#   BTP_BUN_DEST          /usr/local/bin (the fly/Dockerfile location)
#   BTP_BUN_ARCH          `uname -m`
#   BTP_CPUINFO           /proc/cpuinfo
#   BTP_HARNESS_DIR       the bin/ directory above this file; jobs-client.sh,
#                         lib/cli-version.sh and lib/bake-deps.sh load from it

_BTP_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Fallbacks: used ONLY when the row cannot be read or is not x.y.z. Each equals
# the live row value, read with bake_row_version on 2026-11-09.
BTP_FALLBACK_bun=1.4.2          # fallback of settings row bake.bun.version
BTP_FALLBACK_codegraph=1.5.0    # fallback of settings row bake.codegraph.version
BTP_FALLBACK_playwright=1.48.2  # fallback of settings row bake.playwright.version

_btp_fallback() {
  case "$1" in
    bun) printf '%s' "$BTP_FALLBACK_bun" ;;
    codegraph) printf '%s' "$BTP_FALLBACK_codegraph" ;;
    playwright) printf '%s' "$BTP_FALLBACK_playwright" ;;
  esac
}

# _btp_row <name> -> the parsed row on stdout. rc 0 read, 2 no row, 1 outage or
# no credentials (bake_row_version's contract), 3 the libraries did not load.
# A subshell, so the jobs client's globals and `set -u` stay out of the caller.
_btp_row() {
  local hd="${BTP_HARNESS_DIR:-$_BTP_LIB_DIR/..}"
  (
    set +eu
    # shellcheck source=/dev/null
    { [ -r "$hd/jobs-client.sh" ] && . "$hd/jobs-client.sh" \
        && . "$hd/lib/cli-version.sh" && . "$hd/lib/bake-deps.sh"; } >/dev/null 2>&1 || return 3
    bake_row_version "$1" 2>/dev/null
  )
}

btp_version() {
  local name="$1" v="" rc=0 why="" fb
  fb=$(_btp_fallback "$name")
  v=$(_btp_row "$name") || rc=$?
  case "$rc" in
    0) [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || why="not a version" ;;
    2) why="no row" ;;
    3) why="jobs client not loadable" ;;
    *) why="unreachable" ;;
  esac
  if [ -n "$why" ]; then
    echo "WARN: bootstrap pin: bake.$name.version $why; using fallback $fb" >&2
    v="$fb"
  fi
  printf '%s\n' "$v"
  return 0
}

btp_installed() {
  [ -n "${1:-}" ] || return 0
  [ -x "$1" ] || command -v "$1" >/dev/null 2>&1 || return 0
  "$1" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
  return 0
}

# Bun's x64 release is the AVX2 build; a CPU without AVX2 gets SIGILL from it.
# The old Bun web installer picked -baseline on such CPUs; this keeps that choice.
btp_bun_asset() {
  local arch="${BTP_BUN_ARCH:-$(uname -m)}"
  case "$arch" in
    aarch64|arm64) printf 'bun-linux-aarch64' ;;
    *) if grep -qE '^flags[[:space:]]*:.*[[:space:]]avx2([[:space:]]|$)' "${BTP_CPUINFO:-/proc/cpuinfo}" 2>/dev/null; then
         printf 'bun-linux-x64'
       else
         printf 'bun-linux-x64-baseline'
       fi ;;
  esac
}

_btp_npm_bin() { local p; p=$(npm prefix -g 2>/dev/null) && [ -n "$p" ] && printf '%s/bin/%s' "$p" "$1"; }

btp_install_bun() {
  local v="$1" dest="$2" base="${BTP_BUN_RELEASE_BASE:-https://github.com/oven-sh/bun/releases/download}"
  local asset tmp want got
  asset=$(btp_bun_asset)
  tmp=$(mktemp -d) || { echo "ERROR: bun $v: no temp dir" >&2; return 1; }
  if ! curl -fsSL -o "$tmp/$asset.zip" "$base/bun-v$v/$asset.zip" \
     || ! curl -fsSL -o "$tmp/SHASUMS256.txt" "$base/bun-v$v/SHASUMS256.txt"; then
    echo "ERROR: bun $v: download failed from $base/bun-v$v/; not installed" >&2
    rm -rf "$tmp"; return 1
  fi
  # fly/bake-pin.sh bake_sha256's match: "<sha>  <name>" or "<sha> *<name>".
  want=$(awk -v n="$asset.zip" '$2 == n || $2 == "*" n {print $1}' "$tmp/SHASUMS256.txt" | head -1)
  got=$(sha256sum "$tmp/$asset.zip" | cut -d' ' -f1)
  if [ -z "$want" ] || [ "$got" != "$want" ]; then
    echo "ERROR: bun $v: $asset.zip sha256 $got does not match SHASUMS256.txt (${want:-not listed}); not installed" >&2
    rm -rf "$tmp"; return 1
  fi
  # Only a verified zip is unpacked. The new binary goes in beside the old one
  # and replaces it only after it reports the pinned version.
  if ! unzip -q "$tmp/$asset.zip" -d "$tmp/x" \
     || ! install -m 755 "$tmp/x/$asset/bun" "$dest/.bun.btp-new"; then
    echo "ERROR: bun $v: unpack or install into $dest failed" >&2
    rm -rf "$tmp" "$dest/.bun.btp-new"; return 1
  fi
  rm -rf "$tmp"
  got=$(btp_installed "$dest/.bun.btp-new")
  if [ "$got" != "$v" ]; then
    echo "ERROR: bun $v: the installed binary reports '${got:-nothing}'" >&2
    rm -f "$dest/.bun.btp-new"; return 1
  fi
  mv -f "$dest/.bun.btp-new" "$dest/bun" && ln -sf bun "$dest/bunx"
}

btp_install_codegraph() {
  local v="$1" got
  DO_NOT_TRACK=1 npm install -g "@colbymchenry/codegraph@$v" >/dev/null || return 1
  got=$(btp_installed "$(_btp_npm_bin codegraph)")
  [ "$got" = "$v" ] || { echo "ERROR: codegraph $v: the installed binary reports '${got:-nothing}'" >&2; return 1; }
}

btp_install_playwright() {
  local v="$1" got
  npm install -g "playwright@$v" >/dev/null || return 1
  _btp_playwright_browsers "$v" || return 1
  got=$(npx --yes "playwright@$v" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
  [ "$got" = "$v" ] || { echo "ERROR: playwright $v: npx playwright@$v reports '${got:-nothing}'" >&2; return 1; }
}

# Idempotent: playwright skips a browser it already has.
_btp_playwright_browsers() {
  npx --yes "playwright@$1" install --with-deps chromium >/dev/null 2>&1
}

btp_ensure() {
  local name="$1" v have rc=0 path on_path
  v=$(btp_version "$name")
  case "$name" in
    bun) path="${BTP_BUN_DEST:-/usr/local/bin}/bun" ;;
    *) path=$(_btp_npm_bin "$name") || path="$name" ;;
  esac
  have=$(btp_installed "$path")
  if [ "$have" = "$v" ]; then
    echo "bootstrap pin: $name $v already installed"
    # A box at the pin whose browsers are missing heals here.
    if [ "$name" = playwright ]; then
      _btp_playwright_browsers "$v" || echo "WARN: bootstrap pin: playwright $v browsers not installed" >&2
    fi
  else
    case "$name" in
      bun) btp_install_bun "$v" "${BTP_BUN_DEST:-/usr/local/bin}" || rc=$? ;;
      codegraph) btp_install_codegraph "$v" || rc=$? ;;
      playwright) btp_install_playwright "$v" || rc=$? ;;
      *) rc=1 ;;
    esac
    if [ "$rc" = 0 ]; then
      echo "bootstrap pin: $name $v installed"
    else
      echo "WARN: bootstrap pin: $name $v not installed (rc $rc)" >&2
    fi
  fi
  # An old ~/.bun/bin/bun earlier on PATH would shadow the pin.
  if [ "$name" = bun ]; then
    on_path=$(command -v bun 2>/dev/null || true)
    if [ -n "$on_path" ] && [ "$on_path" != "$path" ]; then
      echo "WARN: bun on PATH is $on_path, not the pinned $path" >&2
    fi
  fi
  return 0
}

btp_ensure_all() {
  btp_ensure bun
  btp_ensure playwright
  btp_ensure codegraph
  return 0
}
