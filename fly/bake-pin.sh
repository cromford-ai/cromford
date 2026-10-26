#!/bin/sh
# fly/bake-pin.sh — sourced by every version-pinned RUN in fly/Dockerfile
# (BH-1528). Two checks, both FATAL, so a build can never bake something other
# than what bin/fly-image-build.sh resolved from the bake.<name>.version rows:
#
#   bake_require <ARG-name> <value>
#       the ARG arrived non-empty. An empty ARG is a caller bug (the build
#       script refuses before it gets here); without this check an empty
#       version spec falls through to whatever the installer calls "latest".
#   bake_verify <label> <wanted> <command...>
#       runs <command...> (a `--version`), takes the first dotted number it
#       prints, and requires it to equal <wanted>. A silently substituted
#       version would be worse than a stale one: nothing downstream would ever
#       notice.
#
# POSIX sh on purpose: RUN lines execute under /bin/sh (dash on ubuntu).

bake_require() {
  if [ -z "${2:-}" ]; then
    echo "FATAL: build arg $1 is required (pinned from a bake.*.version row, never latest)" >&2
    exit 1
  fi
}

bake_verify() {
  _bp_label="$1"; _bp_want="$2"; shift 2
  _bp_got="$("$@" 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  if [ "$_bp_got" != "$_bp_want" ]; then
    echo "FATAL: $_bp_label reports ${_bp_got:-nothing}, expected $_bp_want" >&2
    exit 1
  fi
  echo "bake-pin: $_bp_label $_bp_got"
}

#   bake_warm_links <warm-dir>
#       when the warm bake left a pnpm store (<warm-dir>/pnpm-home) beside its
#       node_modules, the two must still share inodes in the FINAL image. pnpm
#       hardlinks node_modules/.pnpm files to the store; a COPY that splits them
#       breaks every link and bakes the bytes twice (BH-1528 review F1). Zero
#       linked files = FATAL. No store (npm project, cold image) = nothing to
#       check. Prints `du` counted with and without hardlinks, so the build log
#       shows the saving.
bake_warm_links() {
  _bp_nm="$1/repo/node_modules/.pnpm"
  if [ ! -d "$1/pnpm-home" ] || [ ! -d "$_bp_nm" ]; then
    echo "bake-pin: warm links: no pnpm store in $1, nothing to check"; return 0
  fi
  _bp_all=$(find "$_bp_nm" -type f | wc -l)
  _bp_linked=$(find "$_bp_nm" -type f -links +1 | wc -l)
  if [ "$_bp_all" -gt 0 ] && [ "$_bp_linked" -eq 0 ]; then
    echo "FATAL: none of the $_bp_all node_modules/.pnpm files share an inode with the pnpm store — store and node_modules must arrive in ONE COPY" >&2
    exit 1
  fi
  echo "bake-pin: warm links: $_bp_linked/$_bp_all node_modules/.pnpm files hardlinked; $1 is $(du -sk "$1" | cut -f1) KB on disk ($(du -skl "$1" | cut -f1) KB counting links twice)"
}

#   bake_sha256 <file> <sums-url> <asset-name>
#       the downloaded <file> must match <asset-name>'s line in the vendor's
#       published checksum list (BH-1528 review F4). Same TLS origin as the
#       artifact, so this catches a corrupted or truncated download and a
#       swapped asset whose checksum list was not re-published with it, not a
#       wholly compromised release. An asset missing from the list = FATAL.
bake_sha256() {
  _bp_want=$(curl -fsSL "$2" | awk -v n="$3" '$2 == n || $2 == "*" n {print $1; exit}')
  if [ -z "$_bp_want" ]; then
    echo "FATAL: $3 is not listed in $2" >&2; exit 1
  fi
  _bp_got=$(sha256sum "$1" | cut -d' ' -f1)
  if [ "$_bp_got" != "$_bp_want" ]; then
    echo "FATAL: $3 sha256 $_bp_got does not match $2 ($_bp_want)" >&2; exit 1
  fi
  echo "bake-pin: $3 sha256 ok"
}

#   bake_apt_version <package> <upstream-version>
#       prints the full Debian version (epoch and revision included) apt
#       offers for <package> whose upstream part is EXACTLY <upstream-version>
#       (BH-8319: libwebkit2gtk-4.1-dev for a project's webkit row). The first
#       match apt-cache madison lists is the newest. 2.48.70 never matches
#       2.48.7. No match = FATAL naming the package, the wanted version and the
#       newest one offered: the Ubuntu archive drops a superseded version, and a
#       silently substituted one would be worse than a failed build. Run it
#       after `apt-get update`.
bake_apt_version() {
  _bp_re=$(printf '%s' "$2" | sed 's/\./\\./g')
  _bp_all=$(apt-cache madison "$1" 2>/dev/null | awk -F'|' '{gsub(/[[:space:]]/, "", $2); if ($2 != "") print $2}')
  _bp_hit=$(printf '%s\n' "$_bp_all" | grep -E "^([0-9]+:)?${_bp_re}(-|$)" | head -1)
  if [ -z "$2" ] || [ -z "$_bp_hit" ]; then
    echo "FATAL: $1 $2 is not available from apt (newest offered: $(printf '%s\n' "$_bp_all" | head -1 | grep . || echo none))" >&2
    exit 1
  fi
  printf '%s\n' "$_bp_hit"
}
