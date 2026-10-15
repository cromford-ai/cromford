#!/bin/bash
# bin/fly-image-build.sh <project> — build the builder image and push it to the
# per-app Fly registry (Phase 1). Run this on a host WITH DOCKER (the hub has
# none); fly-provision.sh then references registry.fly.io/builder-<project>.
#
# Per plan "Fly specifics > Image": the image is publishable-safe (no secrets, no
# repo, no env). We build from fly/Dockerfile and push to the app registry so the
# machine can pull it. Rebuild+repush here is the update path (the update-runners
# analog) when the toolchain moves.
#
# Open-detail decisions (simplest robust option, per task brief):
#   - Uses `fly deploy --build-only --push` (plan's stated mechanism): flyctl
#     builds fly/Dockerfile via its remote/depot builder and pushes to
#     registry.fly.io/<app>, no local docker daemon needed for the PUSH — but a
#     docker/depot builder IS needed, hence "run where docker exists".
#     A pure-docker fallback (build + `fly deploy --image`) is provided commented
#     for hosts that prefer local docker; default path is flyctl remote build.
#   - The app must exist before push (registry is app-scoped). If it doesn't,
#     we create it here so the operator can build the image before/without
#     running fly-provision (provision then finds the image already present).
#   - FLY_ORG + FLY_API_TOKEN come from env/fly.env if present, else the caller's
#     existing `fly auth` session (this may run off-hub where fly.env is absent).
set -uo pipefail

PROJECT="${1:?usage: fly-image-build.sh <project>}"
APP="builder-$PROJECT"
# The harness root, same spelling as bin/fleet-propagate.sh. Unset or
# /root/harness on every box, so production reads exactly the paths it always
# had; the fixture suite points it at a scratch tree so tests never write to a
# live box.
H="${HARNESS:-/root/harness}"

# fly/ dir is a sibling of bin/ in the repo checkout this script ships in.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HERE/lib/gh-app-auth.sh" ] && . "$HERE/lib/gh-app-auth.sh"
# BH-1517: setting_get (cli.claude_code.version / cli.codex.version) and
# cli_version_of (the fallback probe of this host's own installed CLI).
# shellcheck source=bin/jobs-client.sh
[ -r "$HERE/jobs-client.sh" ] && . "$HERE/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/cli-version.sh
[ -r "$HERE/lib/cli-version.sh" ] && . "$HERE/lib/cli-version.sh"
# BH-1528: the manifest of every other baked dependency + its resolver.
# shellcheck source=bin/lib/bake-deps.sh
[ -r "$HERE/lib/bake-deps.sh" ] && . "$HERE/lib/bake-deps.sh"
# BH-2523: the fly_images row — written on a pushed ref, read for the last bake.
# shellcheck source=bin/lib/fly-image-row.sh
[ -r "$HERE/lib/fly-image-row.sh" ] && . "$HERE/lib/fly-image-row.sh"
# BH-6710: the warm-layer bust key the nightly refresh rolls (state/fly/warm-bust).
# shellcheck source=bin/lib/warm-bust.sh
[ -r "$HERE/lib/warm-bust.sh" ] && . "$HERE/lib/warm-bust.sh"
FLYDIR="$(cd "$HERE/../fly" && pwd)" || { echo "FATAL: fly/ dir not found next to bin/"; exit 1; }
DOCKERFILE="$FLYDIR/Dockerfile"
[ -f "$DOCKERFILE" ] || { echo "FATAL: $DOCKERFILE missing"; exit 1; }

FLY=$(command -v fly || command -v flyctl) || { echo "FATAL: flyctl not installed"; exit 1; }

# Optional hub creds; off-hub the operator's own `fly auth login` suffices.
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir)
FLYENV="$HENV/fly.env"
if [ -f "$FLYENV" ]; then set -a; . "$FLYENV"; set +a; fi
[ -n "${FLY_API_TOKEN:-}" ] && { export FLY_API_TOKEN; export FLY_ACCESS_TOKEN="$FLY_API_TOKEN"; }

echo "== ensuring app $APP exists =="
# >>> app-exists probe
# Read the list into a variable FIRST, never `fly apps list | grep -q`. Under
# `set -o pipefail` grep -q exits on its first match while flyctl is still
# writing the ~67KB JSON, flyctl dies of SIGPIPE (141), pipefail fails the whole
# pipeline, and an app that EXISTS reads as MISSING. Serially that race is
# usually lost by grep; under fleet-propagate's 10-way parallel bake flyctl is
# slow enough that 7-10 of 10 hit it — which is why every propagate from
# 2026-09-17 17:55Z reported `0/10 pool images rebaked` and paged CRITICAL.
APPS_JSON=""; APPS_RC=0
APPS_JSON=$("$FLY" apps list --json 2>/dev/null) || APPS_RC=$?
if [ "$APPS_RC" != 0 ] || [ -z "$APPS_JSON" ]; then
  # Fail CLOSED: a failed list is NOT evidence the app is missing, and creating
  # on that guess is what produced the FATAL above.
  echo "FATAL: fly apps list failed (rc=$APPS_RC) — refusing to guess whether $APP exists"; exit 1
fi
# A here-string, not `printf '%s' "$APPS_JSON" | grep -q`: that is still a
# pipeline, and a BUILTIN producer past one pipe buffer dies of SIGPIPE too.
# Measured on this box (bash 5.2, 20 runs, match on the first line of a
# pretty-printed listing): 67KB/1004 lines reads ABSENT 20/20 through
# `printf | grep -q`, 0/20 through a here-string. flyctl indents its --json, so
# the real listing is exactly that shape. Bash spills an over-capacity
# here-string to a temp file, so there is no writer left to kill and no
# pipeline for pipefail to fail.
if ! grep -q "\"$APP\"" <<<"$APPS_JSON"; then
  if [ -n "${FLY_ORG:-}" ]; then
    CREATE_OUT=""; CREATE_RC=0
    CREATE_OUT=$("$FLY" apps create "$APP" --org "$FLY_ORG" 2>&1) || CREATE_RC=$?
    printf '%s\n' "$CREATE_OUT"
    if [ "$CREATE_RC" != 0 ]; then
      case "$CREATE_OUT" in
        *"already been taken"*|*"already exists"*)
          echo "WARN: $APP already exists — continuing (create raced a concurrent bake, or the list was stale)" ;;
        *) echo "FATAL: apps create failed"; exit 1 ;;
      esac
    fi
  else
    echo "FATAL: app $APP missing and FLY_ORG unset — create it first (fly apps create $APP --org <org>)"; exit 1
  fi
fi
# <<< app-exists probe

# --- warm bake inputs (build speed pass 2, 2026-08-13) ------------------------
# Bake a recent checkout + node_modules + build caches of the project repo into
# the image (see fly/Dockerfile warm-bake section). The repo slug comes from
# fleet.conf; the clone token is bin/gh-token.sh's answer for it, passed ONLY as
# a BuildKit --build-secret (never a --build-arg — args persist in image
# history). WARM_BUST busts the depot layer cache so the nightly refresh
# actually re-bakes instead of reusing yesterday's clone layer. Its value is
# the date in state/fly/warm-bust, which bin/fly-image-refresh.sh rolls when it
# starts (BH-6710), so a propagate bake after 00:00Z reuses the layer the last
# refresh built. No valid bust file: today's date, as before.
# Missing slug or token => warm bake skipped, image builds cold (old behavior).
SLUG=""
for FC in "${FLEET_CONF:-}" "$H/fleet.conf" "$HERE/../fleet.conf"; do
  [ -n "$FC" ] && [ -f "$FC" ] || continue
  SLUG=$(awk -v p="$PROJECT" '$1 == p {print $2; exit}' "$FC")
  [ -n "$SLUG" ] && break
done
# #425: armed ABOVE the token read (it honours GH_TOKEN) so the probe below and the image's clone share ONE identity.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
# C2: the clone token comes from bin/gh-token.sh (App, then its PAT ladder), never
# from the keyring — `gh auth token` is the operator's PAT there, and empty once logged out.
GHTOK="${GH_TOKEN:-}"
if [ -z "$GHTOK" ] && [ -n "$SLUG" ] && [ "$SLUG" != "-" ] && [ -x "$HERE/gh-token.sh" ]; then
  GHTOK=$("$HERE/gh-token.sh" --fresh "$SLUG" 2>/dev/null | head -n 1)
  [ -n "$GHTOK" ] && export GH_TOKEN="$GHTOK"
fi
WARM_ARGS=()
# The hub's fine-grained PAT reaches only the repos it was scoped to. A slug it
# cannot read used to make the clone 403 INSIDE the image build and fail the
# whole image (2026-09-11: project-5, project-6, project-7) — the probe below
# turns that into a cold image with a line saying why. WARM_BAKE=0 forces cold.
WARM_READABLE=0
if [ -n "$SLUG" ] && [ "$SLUG" != "-" ] && [ -n "$GHTOK" ] && [ "${WARM_BAKE:-1}" != 0 ]; then
  gh api "repos/$SLUG" --silent >/dev/null 2>&1 && WARM_READABLE=1 \
    || echo "== warm bake SKIPPED: the hub gh token cannot read $SLUG (403) — image builds cold =="
fi
if [ "$WARM_READABLE" = 1 ]; then
  # WARM_BUST_NOW is a test clock seam; production never sets it.
  WB_NOW="${WARM_BUST_NOW:-$(date -u +%s)}"
  WARM_BUST=""; WARM_BUST_SRC=date
  if declare -F warm_bust_read >/dev/null 2>&1; then
    read -r WARM_BUST _ < <(warm_bust_read "$H/state/fly" "$WB_NOW") && WARM_BUST_SRC=state
  fi
  [ -n "$WARM_BUST" ] || { WARM_BUST=$(date -u -d "@$WB_NOW" +%F 2>/dev/null || date -u +%F); WARM_BUST_SRC=date; }
  WARM_ARGS=(--build-arg "WARM_REPO_SLUG=$SLUG" --build-arg "WARM_PROJECT=$PROJECT" \
             --build-arg "WARM_BUST=$WARM_BUST" --build-secret "gh_token=$GHTOK")
  echo "== warm bake enabled for $SLUG (checkout + install + build caches) =="
  echo "== warm bust: $WARM_BUST ($WARM_BUST_SRC) =="
  # BH-3463: the warm `next build` gets its own timeout (fly/warm-build.sh), so a
  # hung build ships a cold warm layer instead of holding the whole bake until
  # fleet-propagate's outer timeout kills it with nothing pushed. The
  # pool.warm_build_timeout_s row, then env WARM_BUILD_TIMEOUT_S, then 600. A
  # value that is not a positive number of seconds is named and skipped.
  WBT=""; WBT_SRC=""
  _wbt_ok() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ] 2>/dev/null; }
  if declare -F setting_get >/dev/null 2>&1; then
    _wbt=$(setting_get pool.warm_build_timeout_s 2>/dev/null) || _wbt=""
    if [ -n "$_wbt" ]; then
      if _wbt_ok "$_wbt"; then WBT="$_wbt"; WBT_SRC="settings row pool.warm_build_timeout_s"
      else echo "WARN: pool.warm_build_timeout_s row \"$_wbt\" is not a number of seconds — ignoring it" >&2; fi
    fi
  fi
  if [ -z "$WBT" ] && [ -n "${WARM_BUILD_TIMEOUT_S:-}" ]; then
    if _wbt_ok "$WARM_BUILD_TIMEOUT_S"; then WBT="$WARM_BUILD_TIMEOUT_S"; WBT_SRC="env WARM_BUILD_TIMEOUT_S"
    else echo "WARN: WARM_BUILD_TIMEOUT_S=\"$WARM_BUILD_TIMEOUT_S\" is not a number of seconds — ignoring it" >&2; fi
  fi
  [ -n "$WBT" ] || { WBT=600; WBT_SRC="default"; }
  WARM_ARGS+=(--build-arg "WARM_BUILD_TIMEOUT_S=$WBT")
  echo "== warm build timeout: ${WBT}s ($WBT_SRC) =="
else
  echo "== warm bake SKIPPED (no repo slug in fleet.conf or no gh token) — image builds cold =="
fi

# --- pinned CLI versions (BH-1517) --------------------------------------------
# The unpinned `npm install -g @anthropic-ai/claude-code @openai/codex` RUN line
# in fly/Dockerfile never changed, so Depot's layer cache served the SAME layer
# on every nightly rebuild — every Fly builder ran Claude Code 2.1.267 for weeks
# while the hub moved on to 2.1.280 (logs/fly-image-build.log: `#21 CACHED`).
# The fix pins the install to an exact version, passed as a build ARG, which
# changes the RUN line's interpolated text (and therefore the layer key) the
# day the version moves. The wanted versions are DB values —
# cli.claude_code.version / cli.codex.version, written by bin/cli-update.sh
# after the HUB's own daily update — with this host's own installed CLI as the
# fallback when no row exists yet. Never "latest": an unpinned floor is exactly
# the bug this fixes, so a build refuses outright when neither source resolves.
_resolve_cli_version() { # _resolve_cli_version <setting-key> <binary>
  local key="$1" bin="$2" v="" raw=""
  if declare -F setting_get >/dev/null 2>&1; then
    v=$(setting_get "$key" 2>/dev/null) || v=""
  fi
  # BH-1531 (N3): the row is operator-editable, so it can say "latest", carry a
  # typo, or be "2.1.280 (Claude Code)". Run it through the ONE parser
  # (bin/lib/cli-version.sh) before it becomes a --build-arg: a dotted number
  # inside other text still pins, anything with no dotted number is ignored
  # here and the host fallback below decides (and FATALs if it is empty too).
  # Without this, "latest" reached --build-arg and failed inside the remote
  # build twice a night, and the alert blamed the rebuild instead of the row.
  if [ -n "$v" ] && declare -F cli_version_parse >/dev/null 2>&1; then
    raw="$v"
    v=$(cli_version_parse "$v" 2>/dev/null) || v=""
    [ -z "$v" ] && echo "WARN: $key row \"$raw\" is not a dotted version — ignoring it and falling back to this host's installed $bin" >&2
  fi
  if [ -z "$v" ] && declare -F cli_version_of >/dev/null 2>&1; then
    v=$(cli_version_of "$bin" 2>/dev/null) || v=""
    [ "$v" = missing ] && v=""
    # BH-1531: the reason differs — no row at all, or a row that did not parse
    # (the WARN above named it). Never claim "no row yet" when there was one.
    if [ -n "$v" ]; then
      if [ -n "$raw" ]; then echo "== $bin: $key row unusable — falling back to this host's installed $bin ($v) ==" >&2
      else echo "== $bin: no $key setting row yet — falling back to this host's installed $bin ($v) ==" >&2; fi
    fi
  fi
  printf '%s' "$v"
}
CLAUDE_CODE_VERSION=$(_resolve_cli_version cli.claude_code.version claude)
CODEX_VERSION=$(_resolve_cli_version cli.codex.version codex)
[ -n "$CLAUDE_CODE_VERSION" ] || { echo "FATAL: no CLAUDE_CODE_VERSION available (no cli.claude_code.version setting row and no claude installed on this host) — refusing to build with an unpinned CLI"; exit 1; }
[ -n "$CODEX_VERSION" ] || { echo "FATAL: no CODEX_VERSION available (no cli.codex.version setting row and no codex installed on this host) — refusing to build with an unpinned CLI"; exit 1; }
echo "== pinning image CLIs: claude=$CLAUDE_CODE_VERSION codex=$CODEX_VERSION =="

# --- pinned baked dependencies (BH-1528) --------------------------------------
# The same trap as the CLIs above, for everything else fly/Dockerfile installs:
# every manifest entry (bin/lib/bake-deps.sh) becomes one --build-arg, resolved
# from its bake.<name>.version row, then from what this project's last good
# image baked (state/fly/<project>.bake: no change, never latest), then from
# this host's own install where the manifest says the hub's copy is the same
# artifact. A dependency that resolves from none of them refuses the WHOLE
# build before anything is sent to Depot, naming every missing row at once —
# the pool keeps running its last good image.
declare -F bake_deps >/dev/null 2>&1 || { echo "FATAL: bin/lib/bake-deps.sh not found — refusing to build with unpinned dependencies"; exit 1; }
BAKE_ARGS=(); BAKED=""; BAKE_MISSING=""
# BH-2523: "what this project last baked" is the fly_images row first, so a
# fresh hub with no state/fly/<project>.bake keeps the fleet's pins; the file
# when the row gives no manifest (none, off, worker down).
LAST_BAKE="$H/state/fly/$PROJECT.bake"
ROW_BAKE=$(mktemp "${TMPDIR:-/tmp}/flybake-XXXX") || ROW_BAKE=""
trap '[ -n "$ROW_BAKE" ] && rm -f "$ROW_BAKE"' EXIT
if [ -n "$ROW_BAKE" ] && declare -F fir_bake_to >/dev/null 2>&1 \
   && fir_bake_to "$PROJECT" "$ROW_BAKE" && [ -s "$ROW_BAKE" ]; then
  LAST_BAKE="$ROW_BAKE"
fi
while read -r BNAME BARG BPROBE; do
  [ -n "$BNAME" ] || continue
  BV=$(bake_dep_resolve "$BNAME" "$BPROBE" "$LAST_BAKE")
  if [ -z "$BV" ]; then BAKE_MISSING="$BAKE_MISSING bake.$BNAME.version"; continue; fi
  BAKE_ARGS+=(--build-arg "$BARG=$BV")
  BAKED="$BAKED$BNAME=$BV"$'\n'
done < <(bake_deps)
[ -z "$BAKE_MISSING" ] || { echo "FATAL: no pinned version for:$BAKE_MISSING (no row, no last-baked version for $PROJECT, no approved host install) — set them with bin/bake-seed.sh <name>=<version>; refusing to build with an unpinned dependency"; exit 1; }
echo "== pinning baked deps: $(printf '%s' "$BAKED" | tr '\n' ' ')=="

echo "== building + pushing image to registry.fly.io/$APP =="
# --build-only --push: flyctl builds fly/Dockerfile and pushes to the app
# registry without deploying a machine (fly-provision does machine run).
# flyctl deploy requires a config even for --build-only; generate a minimal
# one (2026-07-31 fix: without it, deploy aborts "could not create a fly.toml
# from any machines" and nothing is pushed).
TOML=$(mktemp /tmp/flybuild-XXXX.toml)
printf 'app = "%s"\n' "$APP" > "$TOML"
# The build output is captured to a per-run file so the pushed ref is read
# from THIS run (2026-09-14: the ref was grepped from the shared
# logs/fly-image-build.log, which fleet-propagate.sh never writes — every
# propagate bake recorded the last standalone bake's tag and all 8 pool
# pointers sat on a 10:41Z image while the registry held the new one).
OUT=$(mktemp /tmp/flybuild-XXXX.out)
"$FLY" deploy \
  --app "$APP" \
  --config "$TOML" \
  --dockerfile "$DOCKERFILE" \
  --build-only --push --remote-only \
  --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" \
  --build-arg "CODEX_VERSION=$CODEX_VERSION" \
  "${BAKE_ARGS[@]}" \
  ${WARM_ARGS[@]+"${WARM_ARGS[@]}"} \
  "$FLYDIR" 2>&1 | tee "$OUT"
RC=${PIPESTATUS[0]}
rm -f "$TOML"
[ "$RC" -eq 0 ] || { rm -f "$OUT"; echo "FATAL: image build/push failed" >&2; exit 1; }

# Record the pushed image ref (fly tags build-only pushes deployment-XXXX, not
# :latest) so fly-provision.sh boots the exact image we just built.
# Write ONLY on success and ONLY this project's app (2026-08-25 TK-1175: the
# old failure branch grepped the whole shared log and copied another
# project's image ref into this project's state file).
mkdir -p "$H/state/fly"
IMG_REF=$(grep -oE "image: registry\.fly\.io/$APP:[^ ]+" "$OUT" 2>/dev/null | tail -1 | cut -d' ' -f2)
rm -f "$OUT"
if [ -n "$IMG_REF" ]; then
  echo "$IMG_REF" > "$H/state/fly/$PROJECT.image"
  # BH-1517: the CLI versions actually baked into THIS build, next to the image
  # ref, so bin/fly-image-refresh.sh can record them (fly_image_cli.<project>)
  # and run its drift floor check without re-probing the image.
  # BH-1531 (N2): written ONLY in this branch. .cli must describe the image
  # .image points at — writing it next to an untouched .image made the
  # fly_image_cli.<project> row describe an image the pool does not run, and
  # turned the refresh lane's drift floor into a self-compare.
  printf 'claude=%s\ncodex=%s\n' "$CLAUDE_CODE_VERSION" "$CODEX_VERSION" > "$H/state/fly/$PROJECT.cli"
  echo "== baked CLIs: claude=$CLAUDE_CODE_VERSION codex=$CODEX_VERSION (registry.fly.io/$APP) =="
  # BH-1528: same rule for the other baked dependencies — .bake describes the
  # image .image points at, and is both the refresh lane's drift input and this
  # script's "keep what you baked" fallback tomorrow.
  printf '%s' "$BAKED" > "$H/state/fly/$PROJECT.bake.tmp" && mv "$H/state/fly/$PROJECT.bake.tmp" "$H/state/fly/$PROJECT.bake"
  # BH-2523: the same facts as the fly_images row, after the files and only in
  # this branch: a build with no pushed ref records no bake. A put that does
  # not land (rc 3) leaves state/fly/<p>.row-stale, so this hub reads the files
  # just written instead of the row's older digest and bake; never fatal.
  # BH-2743: bin/fly-pool-rollout.sh sets FLY_IMAGE_CANDIDATE=1, and then the
  # row is recorded `baked` and NOT activated: the rollout activates it only
  # after its SMOKE passes. Without it (fleet-propagate, fly-image-refresh,
  # which have no smoke step) the put activates, as before.
  if declare -F fir_put >/dev/null 2>&1; then
    if [ "${FLY_IMAGE_CANDIDATE:-}" = 1 ]; then
      fir_put "$PROJECT" "$APP" "$IMG_REF" \
        "$H/state/fly/$PROJECT.bake" "$H/state/fly/$PROJECT.cli" "$(date -u +%s)" "" baked || true
    else
      fir_put "$PROJECT" "$APP" "$IMG_REF" \
        "$H/state/fly/$PROJECT.bake" "$H/state/fly/$PROJECT.cli" "$(date -u +%s)" 1 || true
    fi
  fi
else
  echo "WARN: pushed ref not found in this run's build output — state/fly/$PROJECT.image, .cli and .bake left untouched (they still describe the last good image)" >&2
fi
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset

echo "== done: registry.fly.io/$APP:<deployment-tag> pushed =="
echo "next (on the hub): bin/fly-provision.sh $PROJECT"

# --- local-docker fallback (uncomment if you prefer building with local docker):
# docker build -t "registry.fly.io/$APP:latest" -f "$DOCKERFILE" "$FLYDIR"
# fly auth docker
# docker push "registry.fly.io/$APP:latest"
# fly deploy --app "$APP" --image "registry.fly.io/$APP:latest" --build-only
