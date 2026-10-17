#!/bin/bash
# bin/lib/gitleaks-pin.sh — the gitleaks the gate installs: pinned, and checked
# against a sha256 literal before anything is unpacked (BH-2115). Sourced,
# never executed; sourcing it only sets the two pins and defines one function.
#
#   gitleaks_pin_ensure <dest-dir>   put an executable gitleaks at exactly the
#                                    pin in <dest-dir>. rc 0, or rc 1 with a
#                                    one-line reason on stderr.
#
# THE PIN HAS FOUR COPIES: this file, the "install gitleaks" step of
# .github/workflows/harness-ci.yml, the "Install gitleaks" step of
# .github/workflows/publish-cromford.yml, and fly/Dockerfile's bake-gitleaks
# layer (BH-5789; tests/gitleaks-images.bh-5789-test.sh G1 pins that one). A workflow cannot source a shell file, so
# the copies stay literal and tests/gitleaks-pin.bh-2115-test.sh (P1) fails when
# any of them differs. A version bump moves all three together, plus the sha in
# both KNOWN_PUBLIC_CHECKSUMS lists (bin/share/mapping.py and the overlay's
# no-client-identifiers-test.sh). The sha is the release asset's, checked
# against the release's own checksums.txt. Fetching it at run time from the same
# place as the binary would prove nothing (#2104).
#
# fly/testhost/Dockerfile is not a copy: it takes the pin as build args from
# this file through docs/REMOTE-GATE.md's deploy block (BH-7317), so a bump
# also needs a test host rebuild.
#
# They are assigned, not defaulted, so no environment variable can move the pin.
GITLEAKS_PIN_VERSION=8.30.1
GITLEAKS_PIN_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

# In order: the pinned binary already on PATH (no network); otherwise the
# linux_x64 release tarball from the per-box cache, downloading it when it is
# missing. The tarball is sha-checked on EVERY use, so a truncated or tampered
# cache is deleted and refused, never trusted. The download lands in a pid-named
# temp file and is renamed into place, so two gates on one box never read each
# other's partial file. A cache dir that cannot be written (a read-only state
# dir) downloads into <dest-dir> for this run only.
gitleaks_pin_ensure() {
  local dest="${1:-}" present v="$GITLEAKS_PIN_VERSION" cache tgz asset
  [ -n "$dest" ] && [ -d "$dest" ] || { echo "gitleaks-pin: no dest dir ('$dest')" >&2; return 1; }
  present="$(dirname "${BASH_SOURCE[0]}")/../ci-tool-present.sh"
  if bash "$present" gitleaks "$v" >/dev/null 2>&1; then
    cp "$(command -v gitleaks)" "$dest/gitleaks" && chmod 0755 "$dest/gitleaks" && return 0
    echo "gitleaks-pin: could not copy the gitleaks on PATH into $dest" >&2; return 1
  fi
  [ "$(uname -sm)" = "Linux x86_64" ] \
    || { echo "gitleaks-pin: no pinned gitleaks asset for $(uname -sm)" >&2; return 1; }
  asset="gitleaks_${v}_linux_x64.tar.gz"
  cache="${GITLEAKS_PIN_CACHE:-${HARNESS_STATE_DIR:-${HARNESS:-/root/harness}/state}/tools}"
  if ! mkdir -p "$cache" 2>/dev/null || ! [ -w "$cache" ]; then
    [ -f "$cache/$asset" ] || cache="$dest"
  fi
  tgz="$cache/$asset"
  if [ ! -f "$tgz" ]; then
    curl -sSfL --max-time 60 "https://github.com/gitleaks/gitleaks/releases/download/v${v}/${asset}" -o "$tgz.$$.tmp" \
      && mv "$tgz.$$.tmp" "$tgz" \
      || { rm -f "$tgz.$$.tmp"; echo "gitleaks-pin: could not download $asset" >&2; return 1; }
  fi
  if ! echo "$GITLEAKS_PIN_SHA256  $tgz" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tgz"
    echo "gitleaks-pin: sha256 mismatch on $asset — deleted, not unpacked" >&2; return 1
  fi
  tar -xzf "$tgz" -C "$dest" gitleaks && chmod 0755 "$dest/gitleaks" \
    || { rm -f "$dest/gitleaks"; echo "gitleaks-pin: could not unpack gitleaks from $asset" >&2; return 1; }
  [ "$tgz" = "$dest/$asset" ] && rm -f "$tgz"
  PATH="$dest:$PATH" bash "$present" gitleaks "$v" >/dev/null 2>&1 \
    || { rm -f "$dest/gitleaks"; echo "gitleaks-pin: the unpacked gitleaks does not report $v" >&2; return 1; }
}
