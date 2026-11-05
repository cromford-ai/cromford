# shellcheck shell=bash
# Full machine bootstrap shares bake.<tool>.version with the image builder.
# All pins resolve before package installation. Repos-only never loads this file.
bm_tool_pins_resolve() {
  local tool key raw missing=0
  for tool in bun codegraph playwright; do
    key="BOOTSTRAP_${tool^^}_VERSION"
    if [[ -v $key ]]; then raw="${!key}"
    else raw=$(setting_get "bake.$tool.version" 2>/dev/null) || raw=""; fi
    if ! [[ $raw =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "FATAL: $tool needs an exact x.y.z version in $key or bake.$tool.version; refusing unpinned bootstrap" >&2
      missing=1
      continue
    fi
    printf -v "BM_${tool^^}_VERSION" '%s' "$raw"
  done
  [ "$missing" = 0 ]
}

_bm_tool_matches() {
  local got
  command -v "$1" >/dev/null 2>&1 || return 1
  got=$("$1" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){2}[^[:space:]]*' | head -1) || return 1
  [ "$got" = "$2" ]
}

_bm_bun_install() (
  set -euo pipefail
  local scratch asset url
  case "$(uname -m)" in
    x86_64) asset=bun-linux-x64; grep -qw avx2 /proc/cpuinfo || asset=bun-linux-x64-baseline ;;
    aarch64|arm64) asset=bun-linux-aarch64 ;;
    *) echo 'FATAL: unsupported Bun bootstrap architecture' >&2; exit 1 ;;
  esac
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-bun.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  url="https://github.com/oven-sh/bun/releases/download/bun-v${BM_BUN_VERSION}"
  curl -fsSL -o "$scratch/bun.zip" "$url/$asset.zip"
  bake_sha256 "$scratch/bun.zip" "$url/SHASUMS256.txt" "$asset.zip"
  unzip -q "$scratch/bun.zip" -d "$scratch"
  install -m 755 "$scratch/$asset/bun" /usr/local/bin/bun
  ln -sf bun /usr/local/bin/bunx
)

bm_tool_pins_install() {
  local lib_dir
  # Verify the whole set again if this function is called directly.
  for lib_dir in "${BM_BUN_VERSION:-}" "${BM_CODEGRAPH_VERSION:-}" "${BM_PLAYWRIGHT_VERSION:-}"; do
    [[ $lib_dir =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'FATAL: resolve exact bootstrap tool pins first' >&2; return 1; }
  done
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=fly/bake-pin.sh
  . "$lib_dir/../../fly/bake-pin.sh" || return 1
  _bm_tool_matches bun "$BM_BUN_VERSION" || _bm_bun_install || return 1
  bake_verify bun "$BM_BUN_VERSION" bun --version
  if ! _bm_tool_matches codegraph "$BM_CODEGRAPH_VERSION"; then
    CODEGRAPH_TELEMETRY=0 DO_NOT_TRACK=1 npm install -g "@colbymchenry/codegraph@${BM_CODEGRAPH_VERSION}" || return 1
  fi
  bake_verify codegraph "$BM_CODEGRAPH_VERSION" codegraph --version
  if ! _bm_tool_matches playwright "$BM_PLAYWRIGHT_VERSION"; then
    npm install -g "playwright@${BM_PLAYWRIGHT_VERSION}" || return 1
  fi
  bake_verify playwright "$BM_PLAYWRIGHT_VERSION" playwright --version
  # This is the verified installed CLI; npx must never fetch a floating package.
  playwright install --with-deps chromium
}
