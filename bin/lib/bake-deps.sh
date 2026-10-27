#!/bin/bash
# bin/lib/bake-deps.sh — the ONE manifest of every dependency fly/Dockerfile
# bakes by version (BH-1528), and the resolver that turns a manifest row into
# the exact version a build pins. Sourced by bin/fly-image-build.sh,
# bin/fly-image-refresh.sh and bin/bake-seed.sh.
#
# WHY. BH-1517 found the claude/codex CLIs frozen for weeks: an unpinned install
# RUN line never changes its text, so Depot's layer cache serves the same layer
# on every nightly rebuild. Every other unpinned install in the image had the
# same trap (node via NodeSource setup_22.x, bun/codegraph via curl|sh, gh and
# tailscale via apt, semgrep via bare pip), and rtk/playwright were pinned by
# literals in the Dockerfile. Each one is now an ARG whose value comes from a
# settings row `bake.<name>.version`; a changed row changes that one RUN line's
# text, which busts that layer and (see fly/Dockerfile's stage layout) never
# the warm bake.
#
# The manifest holds NAMES, never versions (no-hardcode rule): the versions are
# DB rows, set by an operator (bin/bake-seed.sh) or by whatever updates that
# tool. The CLIs keep their own BH-1517 rows (cli.claude_code.version /
# cli.codex.version) and are not repeated here.
#
# Columns: <name> <Dockerfile ARG> <hub probe binary, or - >
#   hub probe: this host's own `<binary> --version` may stand in for a missing
#   row ONLY when the hub installs that tool from the same artifact the image
#   does. rtk (GitHub release binary) and codegraph (the versioned bundle its
#   installer and npm both ship) qualify. node, gh and tailscale do NOT: on the
#   hub they come from Ubuntu/NodeSource apt with their own cadence (probed
#   2026-09-22: hub node 22.22.3, gh 2.45.0, tailscale 1.98.9 vs image 22.23.2,
#   2.100.0, 1.102.3), so the probe would silently DOWNGRADE the image. bun,
#   semgrep and playwright are not installed on the hub at all.
#   flyctl qualifies (BH-8335): bin/fly-image-build.sh already needs it on the
#   host that bakes, and the fleet installs it from the superfly release
#   tarball, the artifact the image's bake-flyctl block downloads.
bake_deps() {
  cat <<'EOF'
node NODE_VERSION -
playwright PLAYWRIGHT_VERSION -
semgrep SEMGREP_VERSION -
tailscale TAILSCALE_VERSION -
gh GH_VERSION -
bun BUN_VERSION -
codegraph CODEGRAPH_VERSION codegraph
rtk RTK_VERSION rtk
flyctl FLYCTL_VERSION flyctl
EOF
}

bake_dep_names() { bake_deps | awk '{print $1}'; }

# bake_row_version <name> -> the parsed bake.<name>.version row on stdout,
# empty when the row is missing or not a dotted version ("latest", a typo). The
# parse is BH-1531's: a dotted number inside other text ("v22.23.2") still pins.
# rc is setting_get's: 0 read, 2 no row, 1 outage — so a caller can tell "no
# row" from "could not ask" (the refresh lane must not alert on an outage).
bake_row_version() {
  local raw="" rc=0
  declare -F setting_get >/dev/null 2>&1 || return 2
  raw=$(setting_get "bake.$1.version" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  cli_version_parse "$raw" 2>/dev/null
  return 0
}

# bake_last_baked <file> <name> -> the version recorded for <name> by the last
# successful build of this project (state/fly/<project>.bake), empty if none.
bake_last_baked() {
  [ -f "${1:-}" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# bake_dep_resolve <name> <probe> <last-baked-file> -> the version to pin, on
# stdout; empty when nothing resolves (the caller refuses). Order:
#   1. the bake.<name>.version row                 (the wanted version)
#   2. what this project's last good image baked   (no change, never latest)
#   3. the hub's own install, manifest-approved probes only
# Every fallback says so on stderr, naming the source it used.
bake_dep_resolve() {
  local name="$1" probe="$2" last="$3" v=""
  v=$(bake_row_version "$name")
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v=$(bake_last_baked "$last" "$name")
  if [ -n "$v" ]; then
    echo "== $name: no usable bake.$name.version row — keeping this image's last baked $name ($v) ==" >&2
    printf '%s' "$v"; return 0
  fi
  [ "$probe" != - ] && declare -F cli_version_of >/dev/null 2>&1 && v=$(cli_version_of "$probe" 2>/dev/null)
  [ "$v" = missing ] && v=""
  [ -n "$v" ] && echo "== $name: no usable bake.$name.version row — falling back to this host's installed $probe ($v) ==" >&2
  printf '%s' "$v"
}

# --- per-project dependencies (BH-8319) ----------------------------------------
# Most pools need the same toolchain, so everything above is baked into every
# image. A few projects need a heavy extra that no other project uses
# (project-6-desktop: a Rust toolchain plus the Tauri/webkit system packages).
# Those live in fly/Dockerfile as `# >>> project-<name>[-<suffix>]` blocks, and
# bin/fly-image-build.sh renders a per-project Dockerfile that keeps a block
# only when that project's own row bake.<project>.<name>.version names an
# exact x.y.z. With no row the render is the Dockerfile with every project block
# cut out, markers included, so the other pools keep every cached layer.
#
# Columns: <name> <Dockerfile ARG>. Names only, never versions (the rows hold
# them; an operator sets one with setting_set, see
# docs/verification-map/fly-image-bake-pin.md).
bake_project_deps() {
  cat <<'EOF2'
rust RUST_VERSION
webkit WEBKIT_VERSION
EOF2
}

# bake_project_row_version <project> <name> -> the RAW bake.<project>.<name>.version
# value on stdout. rc is setting_get's: 0 read, 2 no row (or an empty value),
# 1 outage. Not parsed here: the resolver tells "off" from "latest".
bake_project_row_version() {
  local raw="" rc=0
  declare -F setting_get >/dev/null 2>&1 || return 2
  raw=$(setting_get "bake.$1.$2.version" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s' "$raw"
}

# bake_project_resolve <project> <name> <last-bake-file> -> the version to pin on
# stdout, or nothing (skip the block). rc 1 = REFUSE the build (FATAL on stderr).
#   row x.y.z (also "v1.90.0", "rust 1.90.0 stable")  -> pin it
#   row "off"                                          -> skip
#   row with no exact x.y.z ("latest", "1.90")         -> refuse: an opt-in
#       with no pin must never drop silently and never float
#   no row (or an empty value)                         -> skip. The row is the
#       opt-in, so deleting it is the opt-out, even if the last image baked it
#   settings outage                                    -> the last baked version
#       if there is one (an outage changes no image), else skip
bake_project_resolve() {
  local proj="$1" name="$2" last="$3" raw="" rc=0 v=""
  raw=$(bake_project_row_version "$proj" "$name") || rc=$?
  case "$rc" in
    0)
      if [ "$raw" = off ]; then echo "== $name: off by row bake.$proj.$name.version ==" >&2; return 0; fi
      declare -F cli_version_parse >/dev/null 2>&1 && v=$(cli_version_parse "$raw" 2>/dev/null)
      if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "FATAL: row bake.$proj.$name.version=\"$raw\" is not an exact x.y.z version (set one, or \"off\") — refusing to build with an unpinned $name" >&2
        return 1
      fi
      printf '%s' "$v" ;;
    2)
      v=$(bake_last_baked "$last" "$name")
      [ -n "$v" ] && echo "== $name: no bake.$proj.$name.version row — dropping the $name $v the last image baked ==" >&2
      return 0 ;;
    *)
      v=$(bake_last_baked "$last" "$name")
      [ -n "$v" ] && { echo "== $name: settings outage (could not read bake.$proj.$name.version) — keeping this image's last baked $name ($v) ==" >&2; printf '%s' "$v"; }
      return 0 ;;
  esac
}

# bake_render_dockerfile <src> <dst> [kept names...] -> <dst> is <src> with every
# `# >>> project-<b>` ... `# <<< project-<b>` block removed (markers included)
# unless <b> is a kept name or starts with "<name>-" (so "rust" keeps
# project-rust and project-rust-warm, "webkit" keeps only project-webkit, and
# "rus" keeps nothing). Other blocks (bake-*, cli-pin-verify) are untouched.
# An unclosed or unmatched project marker is FATAL (rc 1): a half-cut
# Dockerfile must never reach Depot.
bake_render_dockerfile() {
  local src="$1" dst="$2"; shift 2
  [ -f "$src" ] || { echo "FATAL: render source $src missing" >&2; return 1; }
  awk -v keep="$*" '
    BEGIN { n = split(keep, K, " ") }
    function kept(b,   i) {
      for (i = 1; i <= n; i++)
        if (b == "project-" K[i] || index(b, "project-" K[i] "-") == 1) return 1
      return 0
    }
    /^# >>> project-/ {
      if (open != "") { print "FATAL: " FILENAME ": # >>> " substr($0, 7) " opens inside " open > "/dev/stderr"; bad = 1; exit 1 }
      open = substr($0, 7); drop = !kept(open)
      if (!drop) print; next
    }
    /^# <<< project-/ {
      if (substr($0, 7) != open) { print "FATAL: " FILENAME ": " $0 " closes no open block (open: " (open == "" ? "none" : open) ")" > "/dev/stderr"; bad = 1; exit 1 }
      if (!drop) print
      open = ""; drop = 0; next
    }
    !drop { print }
    END {
      if (bad) exit 1
      if (open != "") { print "FATAL: " FILENAME ": # >>> " open " has no closing # <<< " open > "/dev/stderr"; exit 1 }
    }
  ' "$src" > "$dst"
}
