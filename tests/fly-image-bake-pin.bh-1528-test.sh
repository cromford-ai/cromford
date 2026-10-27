#!/bin/bash
# tests/fly-image-bake-pin.bh-1528-test.sh — BH-1528: every dependency the Fly
# builder image bakes is pinned from a bake.<name>.version settings row and
# watched for drift — BH-1517's CLI pin, extended to node, playwright, semgrep,
# tailscale, gh, bun, codegraph, rtk and flyctl (manifest: bin/lib/bake-deps.sh).
#
# What this pins:
#   A. bin/fly-image-build.sh passes every manifest dependency as its own
#      --build-arg, resolved row -> this project's last baked version -> the
#      host's install (manifest-approved probes only) -> REFUSE, naming every
#      missing row at once, before flyctl is ever invoked. The baked set is
#      recorded to state/fly/<project>.bake next to the image ref.
#   B. fly/Dockerfile: one ARG per manifest entry, no default, consumed only by
#      its own marker block, which calls bake_require + bake_verify; no literal
#      versions, no curl|sh installers; the warm stage depends on no tool ARG,
#      so a tool bump never rebakes it. fly/bake-pin.sh's two checks FATAL on
#      an empty ARG and on a version mismatch.
#   C. bin/fly-image-refresh.sh records fly_image_bake.<project> and alerts ONCE
#      per project per dependency per UTC day on drift; missing rows fold into
#      one line per project per day; a settings outage alerts nothing.
#   D. bin/bake-seed.sh refuses unknown names/unparseable values before writing
#      anything, seeds only missing rows unless --force, and its report exits 1
#      while any row is missing.
#
# Run from anywhere: tests/fly-image-bake-pin.bh-1528-test.sh   (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The manifest as the test knows it: names + ARGs. Asserted against
# bin/lib/bake-deps.sh in B0, so a dependency added there without a Dockerfile
# block (or the reverse) fails here instead of in a nightly build.
DEPS="node:NODE_VERSION playwright:PLAYWRIGHT_VERSION semgrep:SEMGREP_VERSION tailscale:TAILSCALE_VERSION gh:GH_VERSION bun:BUN_VERSION codegraph:CODEGRAPH_VERSION rtk:RTK_VERSION flyctl:FLYCTL_VERSION"

# ===========================================================================
# Shared fakebin. curl is the jobs-client transport: settings rows are files
# under $ROWS (one file per key, its content the value); PUTs are recorded.
# ===========================================================================
FB="$T/fakebin"; ROWS="$T/rows"
mkdir -p "$FB" "$ROWS"
cat > "$FB/fly" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo '[]' ;;
  deploy*) echo "$*" >> "${DEPLOY_ARGS_SINK:-/dev/null}"
           echo "image: registry.fly.io/${STUB_APP:-builder-demo}:deployment-01TEST" ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$FB/gh"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  *"GET "*"/api/settings/"*)
    K="${URL##*/api/settings/}"
    if [ -f "$ROWS/$K" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$(cat "$ROWS/$K")"
    else printf '{}\n404\n'; fi ;;
  *"PUT "*"/api/settings") printf '{"accepted":1}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
CURL
stub_ver() { # stub_ver <binary> <printed --version line, or empty to remove>
  if [ -z "${2:-}" ]; then rm -f "$FB/$1"; return; fi
  printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s"\n' "$2" > "$FB/$1"; chmod +x "$FB/$1"
}
chmod +x "$FB"/*
stub_ver claude "2.1.280 (Claude Code)"; stub_ver codex "codex-cli 0.155.1"

rows_reset() { rm -f "$ROWS"/*; }
row() { printf '%s' "$2" > "$ROWS/$1"; }
seed_all() { # every manifest row set to a distinct recognizable version
  row bake.node.version 22.23.2;       row bake.playwright.version 1.48.2
  row bake.semgrep.version 1.176.1;    row bake.tailscale.version 1.102.3
  row bake.gh.version 2.100.0;         row bake.bun.version 1.4.2
  row bake.codegraph.version 1.5.0;    row bake.rtk.version 0.45.0
  row bake.flyctl.version 0.4.119
}
new_h() {
  local h; h=$(mktemp -d "$T/h-XXXXXX")
  mkdir -p "$h/bin/lib/jobs" "$h/state/fly" "$h/env" "$h/logs" "$h/flags"
  cp "$DIR/bin/jobs-client.sh" "$h/bin/"
  cp "$DIR/bin/alert-line.sh" "$h/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$h/bin/lib/jobs/"
  cp "$DIR/bin/lib/cli-version.sh" "$h/bin/lib/"
  [ -f "$DIR/bin/lib/bake-deps.sh" ] && cp "$DIR/bin/lib/bake-deps.sh" "$h/bin/lib/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$h/env/global.env"
  echo "$h"
}

# ===========================================================================
# A. bin/fly-image-build.sh
# ===========================================================================
build_run() { # build_run <project> [env...]
  local proj="$1"; shift
  : > "$T/deploy-args"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$H" WARM_BAKE=0 FLY_ORG=stub-org \
        DEPLOY_ARGS_SINK="$T/deploy-args" STUB_APP="builder-$proj" \
        "$@" bash "$DIR/bin/fly-image-build.sh" "$proj" 2>&1); RC=$?
}
has_arg() { grep -q -- "--build-arg $1=$2\( \|$\)" "$T/deploy-args"; }

# A1. Every row present -> every dependency's ARG reaches fly deploy with the
# row's exact value, and the baked set is recorded next to the image ref.
H=$(new_h); rows_reset; seed_all
build_run demo1
[ "$RC" = 0 ] && ok || bad "A1: rc=$RC: $OUT"
has_arg NODE_VERSION 22.23.2 && ok || bad "A1: NODE_VERSION did not reach fly deploy: $(cat "$T/deploy-args")"
has_arg PLAYWRIGHT_VERSION 1.48.2 && ok || bad "A1: PLAYWRIGHT_VERSION missing"
has_arg SEMGREP_VERSION 1.176.1 && ok || bad "A1: SEMGREP_VERSION missing"
has_arg TAILSCALE_VERSION 1.102.3 && ok || bad "A1: TAILSCALE_VERSION missing"
has_arg GH_VERSION 2.100.0 && ok || bad "A1: GH_VERSION missing"
has_arg BUN_VERSION 1.4.2 && ok || bad "A1: BUN_VERSION missing"
has_arg CODEGRAPH_VERSION 1.5.0 && ok || bad "A1: CODEGRAPH_VERSION missing"
has_arg RTK_VERSION 0.45.0 && ok || bad "A1: RTK_VERSION missing"
has_arg FLYCTL_VERSION 0.4.119 && ok || bad "A1: FLYCTL_VERSION missing"
grep -q 'bun=1.4.2' "$H/state/fly/demo1.bake" 2>/dev/null && grep -q 'node=22.23.2' "$H/state/fly/demo1.bake" && ok \
  || bad "A1: state/fly/demo1.bake not recorded: $(cat "$H/state/fly/demo1.bake" 2>/dev/null)"

# A2. One row missing, no last-baked record, no approved host probe -> FATAL
# naming the row; flyctl deploy never runs; nothing recorded.
H=$(new_h); rows_reset; seed_all; rm -f "$ROWS/bake.bun.version"
build_run demo2
[ "$RC" != 0 ] && ok || bad "A2: a missing bun row must refuse the build (rc=$RC)"
grep -q 'FATAL.*bake.bun.version' <<<"$OUT" && ok || bad "A2: FATAL does not name bake.bun.version: $OUT"
[ -s "$T/deploy-args" ] && bad "A2: fly deploy ran without a pinned bun: $(cat "$T/deploy-args")" || ok
[ -f "$H/state/fly/demo2.bake" ] && bad "A2: .bake written despite the refusal" || ok

# A3. Several missing -> ONE refusal naming all of them (fix them in one pass).
H=$(new_h); rows_reset; seed_all; rm -f "$ROWS/bake.gh.version" "$ROWS/bake.semgrep.version"
build_run demo3
FATAL_LINE=$(grep 'FATAL' <<<"$OUT")
grep -q 'bake.gh.version' <<<"$FATAL_LINE" && grep -q 'bake.semgrep.version' <<<"$FATAL_LINE" && ok \
  || bad "A3: the refusal must name every missing row: $OUT"

# A4. Missing row BUT this project's last good image baked it -> keeps that
# version (no change, never latest) and says so.
H=$(new_h); rows_reset; seed_all; rm -f "$ROWS/bake.bun.version"
printf 'bun=1.3.14\n' > "$H/state/fly/demo4.bake"
build_run demo4
[ "$RC" = 0 ] && ok || bad "A4: rc=$RC: $OUT"
has_arg BUN_VERSION 1.3.14 && ok || bad "A4: last-baked bun not used: $(cat "$T/deploy-args")"
grep -q "keeping this image's last baked bun (1.3.14)" <<<"$OUT" && ok || bad "A4: no fallback line: $OUT"

# A5. Missing row for a manifest-approved probe (rtk) -> the host's rtk.
H=$(new_h); rows_reset; seed_all; rm -f "$ROWS/bake.rtk.version"; stub_ver rtk "rtk 0.46.1"
build_run demo5
[ "$RC" = 0 ] && ok || bad "A5: rc=$RC: $OUT"
has_arg RTK_VERSION 0.46.1 && ok || bad "A5: host rtk not used: $(cat "$T/deploy-args")"
stub_ver rtk ""

# A6. Missing node row with node installed on the host -> STILL refuses: the
# hub's node comes from a different source and would silently downgrade.
H=$(new_h); rows_reset; seed_all; rm -f "$ROWS/bake.node.version"; stub_ver node "v22.22.3"
build_run demo6
[ "$RC" != 0 ] && grep -q 'bake.node.version' <<<"$OUT" && ok \
  || bad "A6: node must never fall back to the host install (rc=$RC): $OUT"
stub_ver node ""

# A7. A row reading "latest" is not a version -> treated as missing -> refuse.
H=$(new_h); rows_reset; seed_all; row bake.gh.version latest
build_run demo7
[ "$RC" != 0 ] && ok || bad "A7: a 'latest' row must never pin (rc=$RC)"
grep -q -- '=latest' "$T/deploy-args" && bad "A7: 'latest' reached fly deploy" || ok

# A8. The settings worker is DOWN but the project has a last baked set -> the
# build pins exactly what it baked last time; an outage breaks no image.
H=$(new_h); rows_reset
printf 'node=22.23.2\nplaywright=1.48.2\nsemgrep=1.176.1\ntailscale=1.102.3\ngh=2.100.0\nbun=1.4.2\ncodegraph=1.5.0\nrtk=0.45.0\nflyctl=0.4.119\n' > "$H/state/fly/demo8.bake"
build_run demo8 CURL_MODE=down
[ "$RC" = 0 ] && ok || bad "A8: an outage with a last-baked set must still build (rc=$RC): $OUT"
has_arg GH_VERSION 2.100.0 && ok || bad "A8: last-baked gh not pinned: $(cat "$T/deploy-args")"

# ===========================================================================
# B. fly/Dockerfile + fly/bake-pin.sh
# ===========================================================================
DF="$DIR/fly/Dockerfile"
block() { awk -v m="$1" '$0 == "# >>> " m {f=1; next} $0 == "# <<< " m {f=0} f' "$DF"; }
stage() { awk -v s="$1" '/^FROM /{f=($0 ~ (" AS " s "$"))} f' "$DF"; }

# B0. The manifest in bin/lib/bake-deps.sh is exactly the set this test knows.
if [ -f "$DIR/bin/lib/bake-deps.sh" ]; then
  GOT=$(bash -c ". '$DIR/bin/lib/bake-deps.sh'; bake_deps" | awk '{printf "%s:%s ", $1, $2}' | sed 's/ $//')
  [ "$GOT" = "$DEPS" ] && ok || bad "B0: manifest drifted from the test: '$GOT'"
else bad "B0: bin/lib/bake-deps.sh missing"; fi

for D in $DEPS; do
  NAME="${D%%:*}"; ARG="${D#*:}"; B=$(block "bake-$NAME")
  # B1. Its own marker block, opening with its ARG (no default: a literal default
  # would be the hardcode the row replaces).
  [ -n "$B" ] && ok || { bad "B1: no '# >>> bake-$NAME' block in fly/Dockerfile"; continue; }
  [ "$(sed -n 1p <<<"$B")" = "ARG $ARG" ] && ok || bad "B1: bake-$NAME must open with 'ARG $ARG' (no default): $(sed -n 1p <<<"$B")"
  [ "$(grep -c "^ARG $ARG" "$DF")" = 1 ] && ok || bad "B1: ARG $ARG must be declared exactly once"
  # B2. The RUN requires the ARG and verifies the installed version against it.
  # "${X:-}", not "$X": RUN lines run under set -u, and an unset ARG would
  # otherwise die as "parameter not set" before bake_require could name it.
  grep -qF "bake_require $ARG \"\${$ARG:-}\"" <<<"$B" && ok || bad "B2: bake-$NAME does not bake_require $ARG as \"\${$ARG:-}\""
  grep -q "bake_verify $NAME \"\$$ARG\"" <<<"$B" && ok || bad "B2: bake-$NAME does not bake_verify its version"
  # B3. No version literal inside the block.
  grep -qE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$B" && bad "B3: bake-$NAME holds a version literal: $(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$B" | head -1)" || ok
  # B5. The ARG is referenced nowhere outside its own block (so no other layer
  # keys on it).
  OUTSIDE=$(awk -v m="bake-$NAME" '$0 == "# >>> " m {f=1} !f; $0 == "# <<< " m {f=0}' "$DF" | grep -v '^#' | grep -c "\$$ARG\b\|\${$ARG")
  [ "$OUTSIDE" = 0 ] && ok || bad "B5: \$$ARG used outside its block ($OUTSIDE lines)"
done

# B4. The warm stage depends on base alone: no tool ARG in it; the only tool in
# base is node; claude/codex (bumped daily) are the LAST tool layer in final.
W=$(stage warm)
[ -n "$W" ] && ok || bad "B4: no 'FROM base AS warm' stage"
grep -q '^FROM base AS warm$' "$DF" && grep -q '^FROM base AS final$' "$DF" && ok || bad "B4: warm/final must both build FROM base"
grep -qE '^ARG (PLAYWRIGHT|SEMGREP|TAILSCALE|GH|BUN|CODEGRAPH|RTK|CLAUDE_CODE|CODEX)_VERSION' <<<"$W" && bad "B4: a tool ARG sits in the warm stage" || ok
[ "$(stage base | grep -c '^ARG .*_VERSION')" = 1 ] && stage base | grep -q '^ARG NODE_VERSION$' && ok || bad "B4: base must pin node and nothing else"
LAST_TOOL=$(stage final | grep -E '^# >>> (bake-|cli-pin-verify$)' | tail -1)
[ "$LAST_TOOL" = "# >>> cli-pin-verify" ] && ok || bad "B4: claude/codex must be the last tool layer (got '$LAST_TOOL')"
grep -q '^COPY --from=warm /opt/warm /opt/warm$' "$DF" && ok || bad "B4: final must COPY /opt/warm from the warm stage"

# B6. No installer piped into a shell anywhere (those only serve latest).
DF_CODE=$(grep -v '^#' "$DF")
grep -qE 'curl[^|]*\|[[:space:]]*(DO_NOT_TRACK=[^ ]* )?(ba)?sh' <<<"$DF_CODE" && bad "B6: a curl|sh installer remains" || ok

# B7. fly/bake-pin.sh, the two FATAL checks every block uses.
PIN="$DIR/fly/bake-pin.sh"
if [ -f "$PIN" ]; then
  OUT=$(sh -c ". '$PIN'; bake_require GH_VERSION ''; echo reached" 2>&1); RC=$?
  [ "$RC" != 0 ] && grep -q 'FATAL: build arg GH_VERSION is required' <<<"$OUT" && ! grep -q reached <<<"$OUT" && ok \
    || bad "B7: an empty ARG must FATAL (rc=$RC): $OUT"
  stub_ver gh "gh version 2.97.0 (2026-07-31)"
  OUT=$(PATH="$FB:$PATH" sh -c ". '$PIN'; bake_verify gh 2.100.0 gh --version; echo reached" 2>&1); RC=$?
  [ "$RC" != 0 ] && grep -q 'FATAL: gh reports 2.97.0, expected 2.100.0' <<<"$OUT" && ok \
    || bad "B7: a version mismatch must FATAL (rc=$RC): $OUT"
  stub_ver gh "gh version 2.100.0 (2026-09-03)"
  OUT=$(PATH="$FB:$PATH" sh -c ". '$PIN'; bake_verify gh 2.100.0 gh --version" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "B7: a matching version must pass (rc=$RC): $OUT"
  stub_ver gh ""; printf '#!/bin/bash\nexit 1\n' > "$FB/gh"; chmod +x "$FB/gh"
else bad "B7: fly/bake-pin.sh missing"; fi

# B8. Review F1: the pnpm store and node_modules must cross into final in ONE
# COPY. The store moves under /opt/warm in the SAME RUN as the install (a
# rename keeps the hardlinks; a later layer would copy-up and break them), and
# the final stage checks the links with bake_warm_links.
INSTALL_RUN=$(awk '/^RUN --mount=type=secret,id=gh_token/{f=1} f{print} f && !/\\$/{exit}' "$DF")
grep -q 'warm-bake.sh /opt/warm/repo' <<<"$INSTALL_RUN" && grep -q 'mv /root/.local/share/pnpm /opt/warm/pnpm-home' <<<"$INSTALL_RUN" \
  && grep -q 'ln -s /opt/warm/pnpm-home /root/.local/share/pnpm' <<<"$INSTALL_RUN" && ok \
  || bad "B8: the pnpm home must move under /opt/warm in the install RUN itself"
FINAL=$(stage final)
[ "$(grep -c '^COPY --from=warm /opt/warm' <<<"$FINAL")" = 1 ] && ok || bad "B8: exactly one COPY of /opt/warm"
grep -q 'pnpm' <<<"$(grep '^COPY --from=warm' <<<"$FINAL")" && bad "B8: the store must not get a COPY of its own" || ok
LINKS=$(block warm-links)
grep -q 'bake_warm_links /opt/warm' <<<"$LINKS" && ok || bad "B8: no warm-links check in the final stage"
[ "$(grep -n '^# >>> warm-links' "$DF" | cut -d: -f1)" -gt "$(grep -n '^COPY --from=warm /opt/warm' "$DF" | cut -d: -f1)" ] && ok \
  || bad "B8: the warm-links check must run after the /opt/warm COPY"

if [ -f "$PIN" ]; then
  # B9. bake_warm_links on real inodes: linked passes, copied FATALs, no store
  # (npm project, cold image) passes.
  WL="$T/wl"; mkdir -p "$WL/repo/node_modules/.pnpm/a" "$WL/pnpm-home/store"
  printf 'x%.0s' $(seq 1 64) > "$WL/pnpm-home/store/f1"
  ln "$WL/pnpm-home/store/f1" "$WL/repo/node_modules/.pnpm/a/f1"
  OUT=$(sh -c ". '$PIN'; bake_warm_links '$WL'" 2>&1); RC=$?
  [ "$RC" = 0 ] && grep -q 'warm links: 1/1' <<<"$OUT" && ok || bad "B9: hardlinked store must pass (rc=$RC): $OUT"
  rm "$WL/repo/node_modules/.pnpm/a/f1"; cp "$WL/pnpm-home/store/f1" "$WL/repo/node_modules/.pnpm/a/f1"
  OUT=$(sh -c ". '$PIN'; bake_warm_links '$WL'; echo reached" 2>&1); RC=$?
  [ "$RC" != 0 ] && grep -q 'FATAL: none of the 1 node_modules/.pnpm files share an inode' <<<"$OUT" && ! grep -q reached <<<"$OUT" && ok \
    || bad "B9: broken hardlinks must FATAL (rc=$RC): $OUT"
  OUT=$(sh -c ". '$PIN'; bake_warm_links '$T/no-such-warm'" 2>&1); RC=$?
  [ "$RC" = 0 ] && grep -q 'nothing to check' <<<"$OUT" && ok || bad "B9: no store must pass (rc=$RC): $OUT"

  # B10. bake_sha256 against a stubbed vendor checksum list (review F4).
  printf 'payload' > "$T/asset.bin"
  SUM=$(sha256sum "$T/asset.bin" | cut -d' ' -f1)
  printf '%s  asset.bin\n%s  other.bin\n' "$SUM" "$SUM" > "$T/sums.txt"
  mkdir -p "$T/sumcurl"; printf '#!/bin/bash\ncat "%s"\n' "$T/sums.txt" > "$T/sumcurl/curl"
  chmod +x "$T/sumcurl/curl"
  OUT=$(PATH="$T/sumcurl:$PATH" sh -c ". '$PIN'; bake_sha256 '$T/asset.bin' https://x/sums asset.bin" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "B10: a matching checksum must pass (rc=$RC): $OUT"
  printf 'tampered' > "$T/asset.bin"
  OUT=$(PATH="$T/sumcurl:$PATH" sh -c ". '$PIN'; bake_sha256 '$T/asset.bin' https://x/sums asset.bin; echo reached" 2>&1); RC=$?
  [ "$RC" != 0 ] && grep -q 'FATAL: asset.bin sha256' <<<"$OUT" && ! grep -q reached <<<"$OUT" && ok || bad "B10: a mismatch must FATAL (rc=$RC): $OUT"
  OUT=$(PATH="$T/sumcurl:$PATH" sh -c ". '$PIN'; bake_sha256 '$T/asset.bin' https://x/sums missing.bin" 2>&1); RC=$?
  [ "$RC" != 0 ] && grep -q 'FATAL: missing.bin is not listed' <<<"$OUT" && ok || bad "B10: an unlisted asset must FATAL (rc=$RC): $OUT"
  # B11. Every downloaded tarball/zip is checked (node, gh, bun, rtk).
  for N in node gh bun rtk; do
    grep -q 'bake_sha256 ' <<<"$(block "bake-$N")" && ok || bad "B11: bake-$N downloads without bake_sha256"
  done
fi

# ===========================================================================
# C. bin/fly-image-refresh.sh
# ===========================================================================
stub_builder() { # stub_builder <h> <bake-file-content>
  printf '%s' "$2" > "$1/bake.content"
  cat > "$1/bin/fly-image-build.sh" <<STUB
#!/bin/bash
echo "image: registry.fly.io/builder-\$1:deployment-STUBTAG"
cp "$1/bake.content" "$1/state/fly/\$1.bake"
printf 'claude=2.1.280\ncodex=0.155.1\n' > "$1/state/fly/\$1.cli"
STUB
  chmod +x "$1/bin/fly-image-build.sh"
}
refresh_run() { # refresh_run <h> [env...]
  local h="$1"; shift
  : > "$T/req.log"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$h" REQ_SINK="$T/req.log" "$@" \
        bash "$DIR/bin/fly-image-refresh.sh" 2>&1); RC=$?
}
BAKED_OK=$'node=22.23.2\nplaywright=1.48.2\nsemgrep=1.176.1\ntailscale=1.102.3\ngh=2.100.0\nbun=1.4.2\ncodegraph=1.5.0\nrtk=0.45.0\nflyctl=0.4.119\n'

# C1. Rows match the baked set -> fly_image_bake.<project> recorded; no alert.
H=$(new_h); rows_reset; seed_all; : > "$H/flags/fly-pool-democ1"
stub_builder "$H" "$BAKED_OK"
refresh_run "$H" FLY_MACHINES_ROWS=on
grep -q '"key":"fly_image_bake.democ1"' "$T/req.log" && ok || bad "C1: fly_image_bake.democ1 not written: $(grep settings "$T/req.log" | head -3)"
BAKE_PUT=$(grep 'fly_image_bake.democ1' "$T/req.log")
grep -q '"value":"node=22.23.2 playwright=1.48.2 semgrep=1.176.1 tailscale=1.102.3 gh=2.100.0 bun=1.4.2 codegraph=1.5.0 rtk=0.45.0 flyctl=0.4.119"' <<<"$BAKE_PUT" && ok \
  || bad "C1: fly_image_bake value wrong: $(grep fly_image_bake "$T/req.log")"
grep -q 'democ1' "$H/logs/ALERTS.log" 2>/dev/null && bad "C1: no drift, no alert: $(cat "$H/logs/ALERTS.log")" || ok

# C2. Two dependencies drift -> one alert EACH (per dependency), and a second
# same-day run adds nothing.
H=$(new_h); rows_reset; seed_all; row bake.bun.version 1.4.3; row bake.gh.version 2.101.0
: > "$H/flags/fly-pool-democ2"; stub_builder "$H" "$BAKED_OK"
refresh_run "$H"; refresh_run "$H"
[ "$(grep -c 'democ2.*drift' "$H/logs/ALERTS.log" 2>/dev/null)" = 2 ] && ok \
  || bad "C2: expected exactly 2 drift alerts (bun, gh) after two runs: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'democ2.*bun drift: baked=1.4.2 row bake.bun.version=1.4.3' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "C2: bun alert detail wrong"
grep -q 'democ2.*gh drift: baked=2.100.0 row bake.gh.version=2.101.0' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "C2: gh alert detail wrong"

# C3. The same drift on two projects -> one alert per project.
H=$(new_h); rows_reset; seed_all; row bake.rtk.version 0.46.0
: > "$H/flags/fly-pool-democ3a"; : > "$H/flags/fly-pool-democ3b"; stub_builder "$H" "$BAKED_OK"
refresh_run "$H"
[ "$(grep -c 'rtk drift' "$H/logs/ALERTS.log" 2>/dev/null)" = 2 ] && grep -q 'democ3a' "$H/logs/ALERTS.log" && grep -q 'democ3b' "$H/logs/ALERTS.log" && ok \
  || bad "C3: expected one rtk drift alert per project: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# C4. Missing rows -> ONE fleet line per UTC day naming each missing row, and
# no per-project line (review F3: ten copies of one fact is noise).
H=$(new_h); rows_reset; seed_all; rm -f "$ROWS/bake.bun.version" "$ROWS/bake.node.version"
: > "$H/flags/fly-pool-democ4"; : > "$H/flags/fly-pool-democ4b"; stub_builder "$H" "$BAKED_OK"
refresh_run "$H"; refresh_run "$H"
NOROW=$(grep 'no usable row' "$H/logs/ALERTS.log" 2>/dev/null)
[ "$(grep -c . <<<"$NOROW")" = 1 ] && grep -q '^.*\[fleet\]' <<<"$NOROW" && grep -q 'bake.node.version' <<<"$NOROW" && grep -q 'bake.bun.version' <<<"$NOROW" && ok \
  || bad "C4: expected ONE [fleet] no-row line naming node and bun: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# C6. The night before any pinned build: no .bake anywhere, rows missing, the
# build refuses -> the fleet line still fires (it needs no .bake).
H=$(new_h); rows_reset; : > "$H/flags/fly-pool-democ6"
printf '#!/bin/bash\necho "FATAL: no pinned version for: bake.node.version"\nexit 1\n' > "$H/bin/fly-image-build.sh"; chmod +x "$H/bin/fly-image-build.sh"
refresh_run "$H"
grep -q '\[fleet\].*no usable row for:.*bake.node.version.*bake.rtk.version' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "C6: the fleet no-row line must fire before any .bake exists: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# C5. The settings worker is down -> judge nothing, alert nothing (outage is
# not "no rows").
H=$(new_h); rows_reset; : > "$H/flags/fly-pool-democ5"; stub_builder "$H" "$BAKED_OK"
refresh_run "$H" CURL_MODE=down
grep -q 'democ5' "$H/logs/ALERTS.log" 2>/dev/null && bad "C5: an outage must not alert: $(cat "$H/logs/ALERTS.log")" || ok

# ===========================================================================
# D. bin/bake-seed.sh
# ===========================================================================
seed_run() { # seed_run <h> [args...]
  local h="$1"; shift
  : > "$T/req.log"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$h" REQ_SINK="$T/req.log" \
        bash "$h/bin/bake-seed.sh" "$@" 2>&1); RC=$?
}
H=$(new_h); cp "$DIR/bin/bake-seed.sh" "$H/bin/" 2>/dev/null
if [ -f "$H/bin/bake-seed.sh" ]; then
  # D1. Unknown name / unparseable value -> refused, NOTHING written.
  rows_reset
  seed_run "$H" bun=1.4.2 nodee=22.23.2 gh=latest playwright=1.48
  [ "$RC" != 0 ] && ok || bad "D1: a bad pair must refuse (rc=$RC)"
  grep -q 'nodee is not in' <<<"$OUT" && grep -q 'gh=latest is not an exact x.y.z' <<<"$OUT" \
    && grep -q 'playwright=1.48 is not an exact x.y.z' <<<"$OUT" && ok || bad "D1: every problem must be named: $OUT"
  grep -q '^PUT' "$T/req.log" && bad "D1: a refused batch wrote rows: $(cat "$T/req.log")" || ok
  # D2. Existing rows are kept without --force; missing ones are written.
  rows_reset; row bake.bun.version 1.4.2
  seed_run "$H" bun=1.4.3 gh=v2.100.0
  grep -q '"key":"bake.gh.version","value":"2.100.0"' "$T/req.log" && ok || bad "D2: missing gh row not written (parsed): $(cat "$T/req.log")"
  grep -q '"key":"bake.bun.version"' "$T/req.log" && bad "D2: an existing row was replaced without --force" || ok
  seed_run "$H" --force bun=1.4.3
  grep -q '"key":"bake.bun.version","value":"1.4.3"' "$T/req.log" && ok || bad "D2: --force did not replace the row"
  # D3. Report exits 1 while any row is missing, 0 once all are set.
  rows_reset; seed_all; rm -f "$ROWS/bake.semgrep.version"
  seed_run "$H"
  [ "$RC" = 1 ] && grep -q 'bake.semgrep.version=MISSING' <<<"$OUT" && ok || bad "D3: report must flag the missing row (rc=$RC): $OUT"
  row bake.semgrep.version 1.176.1
  seed_run "$H"
  [ "$RC" = 0 ] && ok || bad "D3: report must pass with every row set (rc=$RC): $OUT"
else bad "D: bin/bake-seed.sh missing"; fi

echo "fly-image-bake-pin.bh-1528-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
