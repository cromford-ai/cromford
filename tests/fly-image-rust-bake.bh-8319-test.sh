#!/bin/bash
# tests/fly-image-rust-bake.bh-8319-test.sh — BH-8319 (MKF-4): the pool image
# carries a Rust toolchain, the Tauri/webkit packages and a warm cargo cache
# ONLY for a project whose own row names them.
#
# What this pins:
#   R. bake_project_resolve (bin/lib/bake-deps.sh): the row
#      bake.<project>.<name>.version is the opt-in. An exact x.y.z pins; "off",
#      empty or no row skips; "latest" or "1.90" refuses; a settings outage keeps
#      what the last image baked; another project's row and the global
#      bake.rust.version do not count.
#   D. bake_render_dockerfile: keeps a `# >>> project-<name>[-*]` block only for a
#      kept name, removes every other project block with its markers, and
#      refuses an unclosed marker.
#   P. bake_apt_version (fly/bake-pin.sh): the Debian version for an exact
#      upstream version, never a near miss; FATAL when the archive has no match.
#   L. fly/Dockerfile's three project blocks: ARG first and no default, the
#      bake-pin checks, no version literal, the ARG used nowhere else, and the
#      cargo fetch after the /opt/warm COPY, bounded and non-fatal.
#   B. bin/fly-image-build.sh end to end against a stub fly: no row = today's
#      layer list; a row = the build-arg, the kept blocks and a `.bake` line; a
#      bad row refuses before flyctl; an outage pins the last baked version.
#   V. the project-rust RUN, extracted verbatim and run under stubs: `cargo
#      --version` must equal RUST_VERSION.
#
# Run from anywhere: tests/fly-image-rust-bake.bh-8319-test.sh   (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
DF="$DIR/fly/Dockerfile"
PIN="$DIR/fly/bake-pin.sh"

# ===========================================================================
# Shared fakebin (the bh-1528 pattern). curl is the jobs-client transport:
# settings rows are files under $ROWS; CURL_MODE=down is an outage. The stub
# fly records argv and copies the --dockerfile it was given to $DF_SINK.
# ===========================================================================
FB="$T/fakebin"; ROWS="$T/rows"
mkdir -p "$FB" "$ROWS"
cat > "$FB/fly" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo '[]' ;;
  deploy*) echo "$*" >> "${DEPLOY_ARGS_SINK:-/dev/null}"
           prev=""
           for a in "$@"; do
             [ "$prev" = --dockerfile ] && { echo "$a" > "${DF_PATH_SINK:-/dev/null}"; cp "$a" "${DF_SINK:-/dev/null}"; }
             prev="$a"
           done
           echo "image: registry.fly.io/${STUB_APP:-builder-demo}:deployment-01TEST" ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$FB/gh"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac
done
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  *"GET "*"/api/settings/"*)
    K="${URL##*/api/settings/}"
    if [ -f "$ROWS/$K" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$(cat "$ROWS/$K")"
    else printf '{}\n404\n'; fi ;;
  *) printf '{}\n200\n' ;;
esac
CURL
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$FB/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.155.1"\n' > "$FB/codex"
chmod +x "$FB"/*

rows_reset() { rm -f "$ROWS"/*; }
row() { printf '%s' "$2" > "$ROWS/$1"; }
seed_all() { # every BH-1528 manifest row, so only the project rows vary
  row bake.node.version 22.23.2;       row bake.playwright.version 1.48.2
  row bake.semgrep.version 1.176.1;    row bake.tailscale.version 1.102.3
  row bake.gh.version 2.100.0;         row bake.bun.version 1.4.2
  row bake.codegraph.version 1.5.0;    row bake.rtk.version 0.45.0
}
new_h() {
  local h; h=$(mktemp -d "$T/h-XXXXXX")
  mkdir -p "$h/bin/lib/jobs" "$h/state/fly" "$h/env" "$h/logs" "$h/flags"
  cp "$DIR/bin/jobs-client.sh" "$h/bin/"
  scratch_install_closure bin/jobs-client.sh "$h" >/dev/null || echo "new_h: jobs-client closure failed" >&2
  scratch_install_closure bin/fly-image-build.sh "$h" >/dev/null || echo "new_h: fly-image-build closure failed" >&2
  # fly-image-build.sh renders into <its bin>/../fly/.render: give it a scratch
  # fly/ so no run writes into the repo tree (the trace gate's temp-root rule).
  mkdir -p "$h/fly" && cp "$DF" "$h/fly/Dockerfile" && cp "$PIN" "$h/fly/bake-pin.sh"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$h/env/global.env"
  echo "$h"
}

# ===========================================================================
# R. bake_project_resolve <project> <name> <last-bake-file>
# ===========================================================================
resolve() { # resolve <project> <name> <last-bake-file> [env...] -> RV, RC, RERR
  local p="$1" n="$2" l="$3"; shift 3
  RERR="$T/resolve.err"
  RV=$(env -i PATH="$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$H" "$@" bash -c '
    . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
    . "$HARNESS/bin/lib/cli-version.sh"; . "$HARNESS/bin/lib/bake-deps.sh"
    bake_project_resolve "$1" "$2" "$3"' _ "$p" "$n" "$l" 2>"$RERR"); RC=$?
}
H=$(new_h); NOLAST="$T/no-such.bake"
LAST89="$T/last89.bake"; printf 'node=22.23.2\nrust=1.89.0\n' > "$LAST89"
LASTNORUST="$T/lastnorust.bake"; printf 'node=22.23.2\n' > "$LASTNORUST"

rows_reset; row bake.demo.rust.version 1.90.0; resolve demo rust "$NOLAST"
[ "$RC" = 0 ] && [ "$RV" = 1.90.0 ] && ok || bad "R1: row 1.90.0 must pin 1.90.0 (rc=$RC v='$RV'): $(cat "$RERR")"
rows_reset; row bake.demo.rust.version v1.90.0; resolve demo rust "$NOLAST"
[ "$RC" = 0 ] && [ "$RV" = 1.90.0 ] && ok || bad "R2: row v1.90.0 must pin 1.90.0 (rc=$RC v='$RV')"
rows_reset; row bake.demo.rust.version "rust 1.90.0 stable"; resolve demo rust "$NOLAST"
[ "$RC" = 0 ] && [ "$RV" = 1.90.0 ] && ok || bad "R3: row 'rust 1.90.0 stable' must pin 1.90.0 (rc=$RC v='$RV')"
for W in latest stable nightly; do
  rows_reset; row bake.demo.rust.version "$W"; resolve demo rust "$LAST89"
  [ "$RC" != 0 ] && [ -z "$RV" ] && grep -q 'FATAL.*bake.demo.rust.version' "$RERR" && ok \
    || bad "R4: row '$W' must refuse naming bake.demo.rust.version (rc=$RC v='$RV'): $(cat "$RERR")"
done
rows_reset; row bake.demo.rust.version 1.90; resolve demo rust "$NOLAST"
[ "$RC" != 0 ] && grep -q 'FATAL.*bake.demo.rust.version' "$RERR" && ok || bad "R5: a two-part 1.90 must refuse (rc=$RC v='$RV')"
rows_reset; row bake.demo.rust.version off; resolve demo rust "$LAST89"
[ "$RC" = 0 ] && [ -z "$RV" ] && grep -q 'rust: off by row' "$RERR" && ok || bad "R6: row off must skip with a line (rc=$RC v='$RV'): $(cat "$RERR")"
rows_reset; row bake.demo.rust.version ""; resolve demo rust "$NOLAST"
[ "$RC" = 0 ] && [ -z "$RV" ] && ok || bad "R6: an empty row must skip (rc=$RC v='$RV')"
rows_reset; resolve demo rust "$LAST89"
[ "$RC" = 0 ] && [ -z "$RV" ] && grep -q '1.89.0' "$RERR" && ok || bad "R7: no row must skip and name the dropped 1.89.0 (rc=$RC v='$RV'): $(cat "$RERR")"
rows_reset; resolve demo rust "$NOLAST"
[ "$RC" = 0 ] && [ -z "$RV" ] && [ ! -s "$RERR" ] && ok || bad "R8: no row, no last bake must skip quietly (rc=$RC v='$RV'): $(cat "$RERR")"
rows_reset; row bake.demo.rust.version 1.90.0; resolve demo rust "$LAST89" CURL_MODE=down
[ "$RC" = 0 ] && [ "$RV" = 1.89.0 ] && grep -qi 'outage\|could not read' "$RERR" && ok || bad "R9: an outage must keep the last baked 1.89.0 (rc=$RC v='$RV'): $(cat "$RERR")"
resolve demo rust "$LASTNORUST" CURL_MODE=down
[ "$RC" = 0 ] && [ -z "$RV" ] && ok || bad "R10: an outage with no last rust must skip (rc=$RC v='$RV')"
rows_reset; row bake.other-project.rust.version 1.90.0; resolve demo rust "$NOLAST"
[ "$RC" = 0 ] && [ -z "$RV" ] && ok || bad "R11: another project's row must not install rust here (v='$RV')"
rows_reset; row bake.rust.version 1.90.0; resolve demo rust "$NOLAST"
[ "$RC" = 0 ] && [ -z "$RV" ] && ok || bad "R12: the global bake.rust.version is not a project row (v='$RV')"
rows_reset; row bake.demo.webkit.version 2.48.7
resolve demo webkit "$NOLAST"; WV="$RV"; WRC=$RC
resolve demo rust "$NOLAST"
[ "$WRC" = 0 ] && [ "$WV" = 2.48.7 ] && [ "$RC" = 0 ] && [ -z "$RV" ] && ok || bad "R13: webkit row alone must keep webkit only (webkit='$WV' rust='$RV')"
# The manifest itself.
GOT=$(bash -c ". '$DIR/bin/lib/bake-deps.sh'; bake_project_deps" | awk '{printf "%s:%s ", $1, $2}' | sed 's/ $//')
[ "$GOT" = "rust:RUST_VERSION webkit:WEBKIT_VERSION" ] && ok || bad "R0: project manifest is '$GOT'"

# ===========================================================================
# D. bake_render_dockerfile <src> <dst> <kept names...>
# ===========================================================================
render() { # render <src> <names...> -> $T/render.out, RC, RERR
  local src="$1"; shift
  RERR="$T/render.err"; rm -f "$T/render.out"
  bash -c ". '$DIR/bin/lib/bake-deps.sh'; bake_render_dockerfile \"\$@\"" _ "$src" "$T/render.out" "$@" 2>"$RERR"; RC=$?
}
markers() { grep -E '^# >>> project-' "$1" 2>/dev/null | sed 's/^# >>> //' | tr '\n' ' ' | sed 's/ $//'; }
# The independent oracle: sed's range delete of every project block.
sed '/^# >>> project-/,/^# <<< project-/d' "$DF" > "$T/oracle"

render "$DF"
[ "$RC" = 0 ] && cmp -s "$T/render.out" "$T/oracle" && ok || bad "D1: no names must remove every project block (rc=$RC): $(diff "$T/oracle" "$T/render.out" | head -5) $(cat "$RERR")"
grep -qE 'RUST_VERSION|WEBKIT_VERSION|cargo' "$T/render.out" && bad "D1: a rust/webkit/cargo line survived the no-row render" || ok
[ "$(grep -c '^# >>> project-' "$DF")" = 3 ] && ok || bad "D1: fly/Dockerfile must carry three project blocks"
render "$DF" rust
[ "$RC" = 0 ] && [ "$(markers "$T/render.out")" = "project-rust project-rust-warm" ] && ok || bad "D2: rust must keep project-rust + project-rust-warm (got '$(markers "$T/render.out")')"
render "$DF" rust webkit
[ "$RC" = 0 ] && [ "$(markers "$T/render.out")" = "project-webkit project-rust project-rust-warm" ] && cmp -s "$T/render.out" "$DF" && ok \
  || bad "D3: rust+webkit must keep all three, i.e. the source (got '$(markers "$T/render.out")')"
render "$DF" webkit
[ "$RC" = 0 ] && [ "$(markers "$T/render.out")" = "project-webkit" ] && ok || bad "D4: webkit must keep only project-webkit (got '$(markers "$T/render.out")')"
render "$DF" rus
[ "$RC" = 0 ] && [ -z "$(markers "$T/render.out")" ] && ok || bad "D5: 'rus' must keep nothing (got '$(markers "$T/render.out")')"
printf 'FROM scratch\n' > "$T/scratch.df"; render "$T/scratch.df" rust
[ "$RC" = 0 ] && cmp -s "$T/render.out" "$T/scratch.df" && ok || bad "D6: a source with no blocks must come back unchanged"
printf 'FROM scratch\n# >>> project-x\nRUN true\n' > "$T/open.df"; render "$T/open.df"
[ "$RC" != 0 ] && grep -q 'FATAL.*project-x' "$RERR" && ok || bad "D7: an unclosed marker must FATAL (rc=$RC): $(cat "$RERR")"
render "$T/open.df" x
[ "$RC" != 0 ] && ok || bad "D7: an unclosed KEPT marker must FATAL too (rc=$RC)"
render "$DF"
for M in bake-rtk bake-node cli-pin-verify warm-links bake-playwright; do
  grep -qx "# >>> $M" "$T/render.out" && ok || bad "D8: non-project block $M must stay"
done

# ===========================================================================
# P. bake_apt_version <pkg> <upstream> (stub apt-cache, run under sh)
# ===========================================================================
AB="$T/aptbin"; mkdir -p "$AB"
cat > "$AB/apt-cache" <<'APT'
#!/bin/sh
[ "$1" = madison ] || exit 1
[ -n "${MADISON:-}" ] && printf '%b' "$MADISON"
exit 0
APT
chmod +x "$AB/apt-cache"
apt_ver() { # apt_ver <madison-lines> <wanted> -> AV, RC, AERR
  AERR="$T/apt.err"
  AV=$(PATH="$AB:$PATH" MADISON="$1" sh -c ". '$PIN'; bake_apt_version libwebkit2gtk-4.1-dev '$2'" 2>"$AERR"); RC=$?
}
ML() { printf 'libwebkit2gtk-4.1-dev | %s | http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages\\n' "$@"; }
apt_ver "$(ML 2.48.7-0ubuntu0.24.04.1)" 2.48.7
[ "$RC" = 0 ] && [ "$AV" = 2.48.7-0ubuntu0.24.04.1 ] && ok || bad "P1: exact match must print it (rc=$RC v='$AV'): $(cat "$AERR")"
apt_ver "$(ML 2.48.70-0ubuntu1)" 2.48.7
[ "$RC" != 0 ] && [ -z "$AV" ] && grep -q FATAL "$AERR" && ok || bad "P2: 2.48.70 must not match 2.48.7 (rc=$RC v='$AV')"
apt_ver "$(ML 1:2.48.7-0ubuntu1)" 2.48.7
[ "$RC" = 0 ] && [ "$AV" = 1:2.48.7-0ubuntu1 ] && ok || bad "P3: an epoch version must match (rc=$RC v='$AV')"
apt_ver "$(ML 2.50.1-0ubuntu0.24.04.1)" 2.48.7
[ "$RC" != 0 ] && grep -q 'FATAL.*libwebkit2gtk-4.1-dev.*2\.48\.7.*2\.50\.1-0ubuntu0\.24\.04\.1' "$AERR" && ok \
  || bad "P4: a superseded version must FATAL naming pkg, wanted and newest (rc=$RC): $(cat "$AERR")"
apt_ver "$(ML 2.48.7-0ubuntu0.24.04.2 2.48.7-0ubuntu0.24.04.1)" 2.48.7
[ "$RC" = 0 ] && [ "$AV" = 2.48.7-0ubuntu0.24.04.2 ] && ok || bad "P5: the first (newest) madison line must win (v='$AV')"
apt_ver "" 2.48.7
[ "$RC" != 0 ] && grep -q FATAL "$AERR" && ok || bad "P6: empty madison output must FATAL (rc=$RC)"

# ===========================================================================
# L. the three project blocks in fly/Dockerfile
# ===========================================================================
block() { awk -v m="$1" '$0 == "# >>> " m {f=1; next} $0 == "# <<< " m {f=0} f' "$DF"; }
first_instr() { grep -v '^#' <<<"$1" | grep -v '^$' | head -1; }
BW=$(block project-webkit); BR=$(block project-rust); BC=$(block project-rust-warm)
[ -n "$BW" ] && [ -n "$BR" ] && [ -n "$BC" ] && ok || bad "L0: a project block is missing"
[ "$(first_instr "$BW")" = "ARG WEBKIT_VERSION" ] && ok || bad "L1: project-webkit must open with 'ARG WEBKIT_VERSION' (got '$(first_instr "$BW")')"
[ "$(first_instr "$BR")" = "ARG RUST_VERSION" ] && ok || bad "L1: project-rust must open with 'ARG RUST_VERSION' (got '$(first_instr "$BR")')"
grep -qF 'bake_require RUST_VERSION "${RUST_VERSION:-}"' <<<"$BR" && ok || bad "L2: project-rust must bake_require RUST_VERSION"
grep -q 'bake_sha256 ' <<<"$BR" && ok || bad "L2: project-rust must bake_sha256 the tarball"
grep -qF 'bake_verify rust "$RUST_VERSION" cargo --version' <<<"$BR" && ok || bad "L2: project-rust must bake_verify cargo --version"
grep -qF 'bake_require WEBKIT_VERSION "${WEBKIT_VERSION:-}"' <<<"$BW" && ok || bad "L2: project-webkit must bake_require WEBKIT_VERSION"
grep -q 'bake_apt_version libwebkit2gtk-4.1-dev' <<<"$BW" && grep -qF 'bake_verify webkit "$WEBKIT_VERSION"' <<<"$BW" && ok \
  || bad "L2: project-webkit must pin with bake_apt_version and bake_verify webkit"
for B in "$BW" "$BR" "$BC"; do
  grep -qE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$B" && bad "L3: a version literal in a project block: $(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$B" | head -1)" || ok
  grep -qE 'curl[^|]*\|[[:space:]]*(ba)?sh' <<<"$(grep -v '^#' <<<"$B")" && bad "L3: curl|sh in a project block" || ok
done
for A in RUST_VERSION WEBKIT_VERSION; do
  OUTSIDE=$(sed '/^# >>> project-/,/^# <<< project-/d' "$DF" | grep -c "$A")
  [ "$OUTSIDE" = 0 ] && ok || bad "L4: $A appears outside the project blocks ($OUTSIDE lines)"
  [ "$(grep -c "^ARG $A\$" "$DF")" = 1 ] && ok || bad "L4: ARG $A must be declared exactly once with no default"
done
L_COPY=$(grep -n '^COPY --from=warm /opt/warm /opt/warm$' "$DF" | cut -d: -f1)
L_RW=$(grep -n '^# >>> project-rust-warm$' "$DF" | cut -d: -f1)
L_CLI=$(grep -n '^# >>> cli-pin-verify$' "$DF" | cut -d: -f1)
L_RUST=$(grep -n '^# >>> project-rust$' "$DF" | cut -d: -f1)
[ -n "$L_RW" ] && [ -n "$L_COPY" ] && [ "$L_RW" -gt "$L_COPY" ] && ok || bad "L5: project-rust-warm must come after the /opt/warm COPY"
[ -n "$L_RUST" ] && [ -n "$L_CLI" ] && [ "$L_RUST" -lt "$L_CLI" ] && ok || bad "L5: project-rust must stand before cli-pin-verify (claude bumps must not rebake rust)"
grep -q 'cargo fetch --locked' <<<"$BC" && grep -qF 'timeout "${WARM_CARGO_TIMEOUT_S' <<<"$BC" && ok || bad "L6: the cargo fetch must run under WARM_CARGO_TIMEOUT_S"
[ "$(first_instr "$BC")" = "ARG WARM_CARGO_TIMEOUT_S" ] && ok || bad "L6: project-rust-warm must open with 'ARG WARM_CARGO_TIMEOUT_S'"
grep -q 'warm-cargo: FAILED' <<<"$BC" && grep -q '.warm-cargo-failed' <<<"$BC" && ok || bad "L6: a failed cargo fetch must be non-fatal and marked"

# L7. The cargo-warm RUN run for real under stubs: one Cargo.lock fetched under
# the timeout; node_modules is pruned; a failing fetch is non-fatal + marked.
WR="$T/warmrun"; mkdir -p "$WR/bin" "$WR/opt/warm/repo/.git" "$WR/opt/warm/repo/src-tauri" "$WR/opt/warm/repo/node_modules/x"
: > "$WR/opt/warm/repo/src-tauri/Cargo.lock"; : > "$WR/opt/warm/repo/node_modules/x/Cargo.lock"
printf '#!/bin/sh\necho "$*" >> "%s/cargo.log"\nexit "${CARGO_RC:-0}"\n' "$WR" > "$WR/bin/cargo"
printf '#!/bin/sh\necho "$1" >> "%s/timeout.log"\nshift; exec "$@"\n' "$WR" > "$WR/bin/timeout"
chmod +x "$WR/bin/"*
block project-rust-warm | grep -v '^ARG ' | grep -v '^#' | sed '1s/^RUN //' | sed "s#/opt/warm#$WR/opt/warm#g" > "$WR/run.sh"
OUT=$(PATH="$WR/bin:$PATH" WARM_CARGO_TIMEOUT_S=77 sh -eu "$WR/run.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q "fetch --locked --manifest-path $WR/opt/warm/repo/src-tauri/Cargo.toml" "$WR/cargo.log" 2>/dev/null && ok \
  || bad "L7: cargo fetch did not run for src-tauri (rc=$RC): $OUT $(cat "$WR/cargo.log" 2>/dev/null)"
grep -q node_modules "$WR/cargo.log" 2>/dev/null && bad "L7: a Cargo.lock under node_modules was fetched" || ok
[ "$(cat "$WR/timeout.log" 2>/dev/null)" = 77 ] && ok || bad "L7: the fetch must run under timeout \$WARM_CARGO_TIMEOUT_S (got '$(cat "$WR/timeout.log" 2>/dev/null)')"
[ -e "$WR/opt/warm/.warm-cargo-failed" ] && bad "L7: a good fetch must not leave the failure marker" || ok
OUT=$(PATH="$WR/bin:$PATH" WARM_CARGO_TIMEOUT_S=77 CARGO_RC=101 sh -eu "$WR/run.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q 'warm-cargo: FAILED' <<<"$OUT" && [ -e "$WR/opt/warm/.warm-cargo-failed" ] && ok \
  || bad "L7: a failed fetch must be non-fatal and marked (rc=$RC): $OUT"

# ===========================================================================
# B. bin/fly-image-build.sh end to end
# ===========================================================================
build_run() { # build_run <project> [env...]
  local proj="$1"; shift
  : > "$T/deploy-args"; rm -f "$T/df-got" "$T/df-path"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$H" WARM_BAKE=0 FLY_ORG=stub-org \
        DEPLOY_ARGS_SINK="$T/deploy-args" DF_SINK="$T/df-got" DF_PATH_SINK="$T/df-path" STUB_APP="builder-$proj" \
        "$@" bash "$H/bin/fly-image-build.sh" "$proj" 2>&1); RC=$?
}
instr() { grep -v '^#' "$1" | grep -v '^[[:space:]]*$'; }

# B1. No project row -> the Dockerfile flyctl gets is today's (every project
# block removed), no project build-arg, no rust line in .bake.
H=$(new_h); rows_reset; seed_all
build_run demob1
[ "$RC" = 0 ] && ok || bad "B1: rc=$RC: $OUT"
[ -s "$T/df-got" ] && [ "$(cat "$T/df-path")" != "$DF" ] && ok || bad "B1: fly deploy must get a rendered --dockerfile, not the source"
[ "$(instr "$T/df-got" 2>/dev/null)" = "$(instr "$T/oracle")" ] && ok || bad "B1: the no-row layer list differs from today's: $(diff <(instr "$T/oracle") <(instr "$T/df-got") | head -5)"
cmp -s "$T/df-got" "$T/oracle" && ok || bad "B1: the no-row render must be byte-identical to the source minus project blocks"
grep -qE 'RUST_VERSION|WEBKIT_VERSION' "$T/df-got" 2>/dev/null && bad "B1: a project ARG reached the no-row render" || ok
grep -qE -- '--build-arg (RUST|WEBKIT)_VERSION' "$T/deploy-args" && bad "B1: a project build-arg reached fly deploy" || ok
grep -qE '^(rust|webkit)=' "$H/state/fly/demob1.bake" 2>/dev/null && bad "B1: .bake records a project dep" || ok
grep -q '== project deps: rust=skipped webkit=skipped ==' <<<"$OUT" && ok || bad "B1: no project deps line: $OUT"

# B2. A rust row -> the build-arg, the two rust blocks, and rust= in .bake.
H=$(new_h); rows_reset; seed_all; row bake.demob2.rust.version 1.90.0
build_run demob2
[ "$RC" = 0 ] && ok || bad "B2: rc=$RC: $OUT"
grep -q -- '--build-arg RUST_VERSION=1.90.0\( \|$\)' "$T/deploy-args" && ok || bad "B2: RUST_VERSION did not reach fly deploy: $(cat "$T/deploy-args")"
[ "$(markers "$T/df-got")" = "project-rust project-rust-warm" ] && ok || bad "B2: render kept '$(markers "$T/df-got")'"
grep -qx 'rust=1.90.0' "$H/state/fly/demob2.bake" 2>/dev/null && ok || bad "B2: .bake lacks rust=1.90.0: $(cat "$H/state/fly/demob2.bake" 2>/dev/null)"
grep -q '== project deps: rust=1.90.0 webkit=skipped ==' <<<"$OUT" && ok || bad "B2: project deps line wrong: $OUT"

# B4 (same tree as B2: the writer/reader round trip). The worker is down -> the
# outage build pins what B2 baked.
build_run demob2 CURL_MODE=down
[ "$RC" = 0 ] && grep -q -- '--build-arg RUST_VERSION=1.90.0' "$T/deploy-args" && ok || bad "B4: an outage must pin the last baked rust (rc=$RC): $OUT"

# B3. Row 'latest' -> refused before flyctl deploy; nothing recorded.
H=$(new_h); rows_reset; seed_all; row bake.demob3.rust.version latest
build_run demob3
[ "$RC" != 0 ] && grep -q 'FATAL.*bake.demob3.rust.version' <<<"$OUT" && ok || bad "B3: row latest must refuse naming the row (rc=$RC): $OUT"
[ -s "$T/deploy-args" ] && bad "B3: fly deploy ran on a refused row" || ok
[ -f "$H/state/fly/demob3.bake" ] && bad "B3: .bake written on a refused row" || ok

# B5. The render file is gone after the run, on rc 0 and on rc != 0.
H=$(new_h); rows_reset; seed_all; row bake.demob5.webkit.version 2.48.7
build_run demob5
P5=$(cat "$T/df-path" 2>/dev/null)
[ "$RC" = 0 ] && [ -n "$P5" ] && [ ! -e "$P5" ] && ok || bad "B5: the render must be removed after a good run (rc=$RC path='$P5')"
grep -q -- '--build-arg WEBKIT_VERSION=2.48.7' "$T/deploy-args" && ok || bad "B5: WEBKIT_VERSION did not reach fly deploy"
H=$(new_h); rows_reset; seed_all; row bake.demob5b.rust.version 1.90.0
printf '#!/bin/bash\ncase "$1" in apps) echo "[]";; deploy) prev=""; for a in "$@"; do [ "$prev" = --dockerfile ] && echo "$a" > "$DF_PATH_SINK"; prev="$a"; done; exit 1;; esac\n' > "$T/failfly"
mkdir -p "$T/failbin"; cp "$T/failfly" "$T/failbin/fly"; chmod +x "$T/failbin/fly"
: > "$T/deploy-args"; rm -f "$T/df-path"
OUT=$(env -i PATH="$T/failbin:$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$H" WARM_BAKE=0 FLY_ORG=stub-org \
      DF_PATH_SINK="$T/df-path" bash "$H/bin/fly-image-build.sh" demob5b 2>&1); RC=$?
P5=$(cat "$T/df-path" 2>/dev/null)
[ "$RC" != 0 ] && [ -n "$P5" ] && [ ! -e "$P5" ] && ok || bad "B5: the render must be removed after a failed build (rc=$RC path='$P5'): $OUT"
grep -q 'demob' <<<"$(ls "$H/fly/.render/" 2>/dev/null)" && bad "B5: a render file was left in fly/.render: $(ls "$H/fly/.render/")" || ok

# B6. A warm bake with a rust row -> WARM_CARGO_TIMEOUT_S carries the
# pool.warm_build_timeout_s value; without a rust row it is not passed.
printf '#!/bin/bash\nexit 0\n' > "$T/okgh"
mkdir -p "$T/warmbin"; cp "$T/okgh" "$T/warmbin/gh"; chmod +x "$T/warmbin/gh"
warm_run() { # warm_run <project>
  printf '%s acme/%s\n' "$1" "$1" > "$T/fleet.conf"; : > "$T/deploy-args"
  OUT=$(env -i PATH="$T/warmbin:$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$H" FLY_ORG=stub-org GH_TOKEN=stub-token \
        FLEET_CONF="$T/fleet.conf" DEPLOY_ARGS_SINK="$T/deploy-args" STUB_APP="builder-$1" \
        bash "$H/bin/fly-image-build.sh" "$1" 2>&1); RC=$?
}
H=$(new_h); rows_reset; seed_all; row pool.warm_build_timeout_s 420; row bake.demob6.rust.version 1.90.0
warm_run demob6
[ "$RC" = 0 ] && grep -q -- '--build-arg WARM_CARGO_TIMEOUT_S=420' "$T/deploy-args" && ok \
  || bad "B6: a warm rust bake must pass WARM_CARGO_TIMEOUT_S=420 (rc=$RC): $(cat "$T/deploy-args") $OUT"
H=$(new_h); rows_reset; seed_all; row pool.warm_build_timeout_s 420
warm_run demob6b
[ "$RC" = 0 ] && grep -q -- '--build-arg WARM_BUILD_TIMEOUT_S=420' "$T/deploy-args" && ! grep -q WARM_CARGO_TIMEOUT_S "$T/deploy-args" && ok \
  || bad "B6: without a rust row WARM_CARGO_TIMEOUT_S must not be passed (rc=$RC): $(cat "$T/deploy-args")"

# ===========================================================================
# V. the project-rust RUN, verbatim, under stubs
# ===========================================================================
VB="$T/rustbin"; mkdir -p "$VB" "$T/vtmp"
# curl -o <file> <url> writes a payload; curl <sums-url> prints its real sum.
cat > "$VB/curl" <<'C'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; -*) shift;; *) url="$1"; shift;; esac; done
echo "$url" >> "$V_LOG"
if [ -n "$out" ]; then printf 'rust-payload' > "$out"; exit 0; fi
printf '%s  %s\n' "$(printf 'rust-payload' | sha256sum | cut -d' ' -f1)" "$(basename "${url%.sha256}")"
C
# tar -x... -f <archive> -C <dir>: lays out the installer the tarball carries.
cat > "$VB/tar" <<'C'
#!/bin/sh
dir=""; while [ $# -gt 0 ]; do case "$1" in -C) dir="$2"; shift 2;; *) shift;; esac; done
d="$dir/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu"; mkdir -p "$d"
printf '#!/bin/sh\necho "install.sh $*" >> "$V_LOG"\n' > "$d/install.sh"; chmod +x "$d/install.sh"
C
printf '#!/bin/sh\necho "apt-get $*" >> "$V_LOG"\n' > "$VB/apt-get"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "cargo ${STUB_CARGO:-1.90.0} (840b83a10 2025-07-30)"\n' > "$VB/cargo"
chmod +x "$VB"/*
# Every host path the RUN touches is rewritten into $T/vroot, so the verbatim
# `rm -rf /var/lib/apt/lists/*` never reaches the real host (it did: 237 trace
# hits and a non-root rm FAIL in CI). apt-get, curl, tar, cargo are stubs; the
# install.sh the tar stub lays out only logs, so --prefix=/usr/local is text.
VROOT="$T/vroot"; mkdir -p "$VROOT/var/lib/apt/lists" "$VROOT/opt/fly-boot"
cp "$PIN" "$VROOT/opt/fly-boot/bake-pin.sh"
: > "$VROOT/var/lib/apt/lists/stale-list"
block project-rust | grep -v '^ARG ' | grep -v '^#' | sed '1s/^RUN //' \
  | sed -e "s#/opt/fly-boot/bake-pin.sh#$VROOT/opt/fly-boot/bake-pin.sh#g" -e "s#/var/lib/apt/lists#$VROOT/var/lib/apt/lists#g" > "$T/rust-run.sh"
grep -q 'install.sh' "$T/rust-run.sh" && ok || bad "V0: the extracted project-rust RUN does not look like the install"
# No host path may survive the rewrite except the --prefix text install.sh logs.
LEFT=$(sed "s#$T##g" "$T/rust-run.sh" | grep -oE '(^|[ "=])/(var|etc|opt|root|usr|home)/[^ ";]*' | grep -v -- '=/usr/local$' || true)
[ -z "$LEFT" ] && ok || bad "V0: a host path survived the scratch rewrite: $LEFT"
vrun() { # vrun [env...]
  : > "$T/v.log"
  OUT=$(env -i PATH="$VB:$PATH" TMPDIR="$T/vtmp" V_LOG="$T/v.log" "$@" sh -eu "$T/rust-run.sh" 2>&1); RC=$?
}
vrun RUST_VERSION=1.90.0
[ "$RC" = 0 ] && grep -q 'bake-pin: rust 1.90.0' <<<"$OUT" && ok || bad "V1: a matching cargo must pass (rc=$RC): $OUT"
grep -q 'static.rust-lang.org/dist/rust-1.90.0-x86_64-unknown-linux-gnu.tar.xz$' "$T/v.log" && grep -q '\.tar\.xz\.sha256$' "$T/v.log" && ok \
  || bad "V1: the versioned tarball and its .sha256 must be fetched: $(cat "$T/v.log")"
grep -q 'install.sh --prefix=/usr/local --components=rustc,cargo,rust-std-x86_64-unknown-linux-gnu,clippy-preview,rustfmt-preview' "$T/v.log" && ok \
  || bad "V1: install.sh not run with the pinned components: $(cat "$T/v.log")"
grep -q 'bake-pin: rust-1.90.0-x86_64-unknown-linux-gnu.tar.xz sha256 ok' <<<"$OUT" && ok || bad "V1: the sha256 check did not run: $OUT"
[ -e "$VROOT/var/lib/apt/lists/stale-list" ] && bad "V1: the apt lists cleanup did not run in the scratch root" || ok
vrun RUST_VERSION=1.90.0 STUB_CARGO=1.89.0
[ "$RC" != 0 ] && grep -q 'FATAL: rust reports 1.89.0, expected 1.90.0' <<<"$OUT" && ok || bad "V2: a cargo mismatch must FATAL (rc=$RC): $OUT"
vrun RUST_VERSION=
[ "$RC" != 0 ] && grep -q 'FATAL: build arg RUST_VERSION is required' <<<"$OUT" && ok || bad "V3: an empty RUST_VERSION must FATAL (rc=$RC): $OUT"
[ -s "$T/v.log" ] && bad "V3: the empty-ARG run reached a download: $(cat "$T/v.log")" || ok

echo "fly-image-rust-bake.bh-8319-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
