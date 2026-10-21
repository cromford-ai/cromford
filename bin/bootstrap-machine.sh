#!/bin/bash
# gh-identity: app-token — BH-469 converted it: the box-gh-default step exports
# GH_TOKEN from bin/gh-token.sh before the first clone, so every later gh call in
# this script runs on the App installation token (falling back to the PAT in
# global.env on a box that mints none). The exception it used to hold — no App
# token exists yet on a brand-new box — is what ensure-box-gh-app-default.sh now
# installs, one step earlier.
# Bootstrap a fresh Orgo box as a single-project board watcher.
# Usage: bootstrap-machine.sh <project>   (any row in fleet.conf)
# PRECONDITIONS (do these FIRST, by hand or via Orgo API):
#   1. /etc/harness/env/global.env exists (CONSOLE_URL, HARNESS_SECRET,
#      CLAUDE_CODE_OAUTH_TOKEN, VERCEL_PLUGIN_TELEMETRY=off) — chmod 600
#      (or /root/harness/env/global.env, which bootstrap migrates on its first step)
#   2. /etc/harness/env/<project>.env exists (that project's board token/base) — chmod 600
#      (or /root/harness/env/<project>.env, which bootstrap migrates on its first step)
#   3. EITHER gh auth works (fine-grained PAT scoped to this project's repo):
#      `gh auth status` — OR /etc/harness/env/github-app.env and its .pem are on
#      the box, in which case the GitHub App installation token is this box's
#      identity and no human login is needed at all. bin/lib/gh-repo-token.sh
#      stays the PAT fallback for repos the App is not installed on.
#   4. claude CLI present: `claude --version`
set -euo pipefail
PROJECT="${1:?usage: bootstrap-machine.sh <project> [--repos-only]}"
# --repos-only (BH-6043): only the clone, the Node install and codegraph of
# /root/repos/<project> (bm_repos below). No env seeds, no packages, no box id,
# no crontab. It gives a box that already runs the fleet a checkout of another
# project, e.g. so the lead-review lane on that box can take cromford
# reviews by spillover. A full bootstrap would install that project's lanes.
REPOS_ONLY=0
case "${2:-}" in
  "") ;;
  --repos-only) REPOS_ONLY=1 ;;
  *) echo "usage: bootstrap-machine.sh <project> [--repos-only]" >&2; exit 2 ;;
esac
# Project registry lives in fleet.conf (repo root / /root/harness) — one line per
# project, and it is the ONLY source. The four literal rows that used to sit
# here as a "fallback" were the same four every other lane copied; a fallback
# that only knows the original four cannot help the project you are bootstrapping
# right now, and it hides a missing registry row behind a working bootstrap.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }
HENV=$(harness_env_dir /root/harness)
REPO_SLUG=$("$HERE/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
OFF=$("$HERE/fleet-conf.sh" "$PROJECT" offset 2>/dev/null || true)
if [ -z "$REPO_SLUG" ] || [ -z "$OFF" ]; then
  echo "FATAL: '$PROJECT' has no fleet.conf row (need repo slug + cron offset). Add it to fleet.conf and re-run." >&2
  exit 1
fi

# bm_install — the install for a Node repo, with the manager its lockfile names
# (BH-7715). npm on a pnpm repo stops on a pnpm-only overrides key
# (EINVALIDPACKAGENAME, project-1, hub-move dry-run seed 2026-10-21).
bm_install() {
  local d="/root/repos/$PROJECT" pm=npm
  [ -f "$d/package.json" ] || return 0
  if [ -f "$d/pnpm-lock.yaml" ]; then pm=pnpm; elif [ -f "$d/yarn.lock" ]; then pm=yarn; fi
  if [ "$pm" = npm ]; then (cd "$d" && npm install --no-audit --no-fund); return; fi
  command -v "$pm" >/dev/null 2>&1 || corepack enable "$pm" >/dev/null 2>&1 || true
  command -v "$pm" >/dev/null 2>&1 \
    || { echo "FATAL: $PROJECT has a $pm lockfile, but $pm is not on PATH and corepack could not enable it" >&2; exit 1; }
  (cd "$d" && { "$pm" install --frozen-lockfile || "$pm" install; })
}

# bm_repos — /root/repos/$PROJECT: the full clone (never shallow), the preplan
# clone, the install for a Node repo (bm_install), and the CodeGraph index. Both
# the full bootstrap and --repos-only run it.
bm_repos() {
echo "== repos =="
[ -d "/root/repos/$PROJECT" ] || gh repo clone "$REPO_SLUG" "/root/repos/$PROJECT"
# >>> repo not shallow (tests/mc-rebase-shallow-test.sh section 5 runs this block)
# gh repo clone is full; a hand restore with --depth is not, and a shallow
# /root/repos/<project> fails every conductor rebase of a PR that forked before
# the boundary with "refusing to merge unrelated histories" (BH-517).
if [ "$(git -C "/root/repos/$PROJECT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
  echo "/root/repos/$PROJECT is a shallow clone — git fetch --unshallow origin"
  git -C "/root/repos/$PROJECT" fetch --unshallow origin
fi
[ "$(git -C "/root/repos/$PROJECT" rev-parse --is-shallow-repository 2>/dev/null)" != true ] \
  || { echo "/root/repos/$PROJECT is STILL shallow after --unshallow — refusing to finish bootstrap on it" >&2; exit 1; }
# <<< repo not shallow
[ -d "/root/repos/.preplan-$PROJECT" ] || git clone -q "/root/repos/$PROJECT" "/root/repos/.preplan-$PROJECT"
git -C "/root/repos/.preplan-$PROJECT" remote set-url origin "https://github.com/$REPO_SLUG.git"
# Install only when the repo is a Node project (small non-Node projects
# load too — the build stage handles its own toolchain per the repo CLAUDE.md).
bm_install
# Build the repo's CodeGraph index (local, fast; safe to re-run)
# An `if`, not `&&`: as bm_repos's last command a missing codegraph would make
# the function return 1, and set -e would end the bootstrap (#6168 review).
if command -v codegraph >/dev/null 2>&1; then
  (cd "/root/repos/$PROJECT" && CODEGRAPH_TELEMETRY=0 codegraph init >/dev/null 2>&1 || true)
fi
}

# >>> repos only
if [ "$REPOS_ONLY" = 1 ]; then
  echo "== repos only: $PROJECT ($REPO_SLUG) =="
  # Read, never written: the PAT fallback inside gh-token.sh reads GH_TOKEN
  # from global.env. The box's gh default is already installed on a fleet box.
  if [ -r "$HENV/global.env" ]; then set -a; . "$HENV/global.env"; set +a; fi
  _t=$("$HERE/gh-token.sh" "$REPO_SLUG" 2>/dev/null || true); [ -n "$_t" ] && export GH_TOKEN="$_t"; unset _t
  mkdir -p /root/repos
  bm_repos
  echo "repos-only done: /root/repos/$PROJECT"
  exit 0
fi
# <<< repos only

# Secrets live in /etc/harness/env (BH-392). This is idempotent: on an already
# migrated box it prints "already migrated" and returns 0; on a fresh box it
# creates the empty dir and the compat symlink. Strict under `set -e` — a refusal
# (pool/tmpfs shape) is a bootstrap that must not continue.
echo "== env dir =="
"$HERE/migrate-env-dir.sh"
# Re-resolved AFTER the migration: harness_env_dir resolves the same way
# harden-state.sh does, so a box on /etc/harness/env behaves exactly like one on
# /root/harness/env — and $HENV is what lets the preflight block below be driven
# by a fixture (tests/bootstrap-hardened-env-test.sh).
HENV=$(harness_env_dir /root/harness)

echo "== preflight =="
# >>> preflight
# EVERY FAILURE HERE NAMES ITSELF. 2026-09-16, box-small: `chmod 600
# env/*.env` hit EPERM on chattr +i files (chmod on an immutable file fails even
# when the mode is unchanged), `set -e` killed the script one line after
# "== preflight ==" with no FATAL of its own, no crons were installed, and the
# loader that called it had nothing to report. Every new project load on a
# hardened box hit it.
preflight_fatal() { echo "FATAL: preflight: $*" >&2; exit 1; }
node --version                          || preflight_fatal "node not found (PRECONDITIONS 4)"
claude --version                         || preflight_fatal "claude CLI not found (PRECONDITIONS 4)"
# >>> gh preflight
# A keyring login is no longer a precondition: on an App-token box there is
# deliberately nobody logged in. BOTH calls sit under the `if` because
# `gh auth setup-git` also exits 1 without a login, and `set -e` would kill the
# bootstrap one line later.
if gh auth status -h github.com >/dev/null 2>&1; then
  # Plain git needs gh's credential helper (gh repo clone works without it, but every
  # later `git pull` fails "could not read Username" — cost the project-10 box 4 builds, 2026-07-29).
  gh auth setup-git                      || preflight_fatal "gh auth setup-git failed"
else
  echo "WARN: gh has no keyring login on this box. That is fine if $HENV/github-app.env is present — the App installation token becomes the identity in the box-gh-default step below, which also installs git's credential helper. bin/lib/gh-repo-token.sh stays the PAT fallback for repos the App is not installed on."
fi
# <<< gh preflight
[ -f "$HENV/global.env" ] && [ -f "$HENV/$PROJECT.env" ] \
  || preflight_fatal "env files missing in $HENV (see PRECONDITIONS)"
for f in "$HENV"/*.env; do
  [ -f "$f" ] || continue
  [ "$(stat -c '%a' "$f")" = 600 ] && continue     # right already; never chmod a +i file for nothing
  if ! chmod 600 "$f" 2>/dev/null; then
    # Wrong AND immutable: the flag comes off and goes back on ONLY through
    # harden-state.sh, never by a raw chattr here.
    "$HERE/harden-state.sh" --release "$f" && chmod 600 "$f" && "$HERE/harden-state.sh" --rearm "$f" \
      || preflight_fatal "cannot set $f to 600 (immutable, and harden-state.sh could not release/rearm it)"
  fi
done
# <<< preflight
# THE BOX'S COMMIT IDENTITY, SET ONCE (BH-1134). Every lane commits as the global
# git identity (bin/lib/git-identity.sh pins it for agent sessions and refuses to
# push anything else), so a box with none would refuse every fix round. Only an
# UNSET half is written; an identity someone configured is never overwritten.
# Outside the preflight markers on purpose: tests/bootstrap-hardened-env-test.sh
# runs that block verbatim, and this line writes ~/.gitconfig.
# shellcheck source=bin/lib/git-identity.sh
{ . "$HERE/lib/git-identity.sh" && gi_ensure_global \
    && echo "git identity: $(git config --global user.name) <$(git config --global user.email)>"; } \
  || echo "WARN: could not set the global git identity — set it by hand: git config --global user.name ${HARNESS_GIT_NAME:-<name>}; git config --global user.email ${HARNESS_GIT_EMAIL:-<email>}"

# DNS before anything reaches the network (BH-5337): a dangling systemd stub
# resolv.conf becomes a static file; a dead resolver is one ALERTS line.
echo "== dns =="; "$HERE/dns-guard.sh" || true
echo "== packages =="
command -v unzip >/dev/null || apt-get install -y unzip
# rsync: harness-sync.sh deploys bin/ and prompts/ with it; without it the
# deploy fails SILENTLY (stderr to log) and triage dies "prompt file missing"
# (box-small first load, 2026-08-18).
command -v rsync >/dev/null || apt-get install -y rsync
# Newer Orgo images ship without cron (box-project-2-1, 2026-07-24).
command -v crontab >/dev/null || apt-get install -y cron
# OS security updates from the first boot (BH-6742): security pockets only,
# no reboot, no service restart. bin/update-runners.sh repeats it daily.
"$HERE/security-updates-ensure.sh" || true
# Run the daemon under supervisord like the hub so it survives restarts.
pgrep -x cron >/dev/null || {
  if [ -d /etc/supervisor/conf.d ]; then
    printf '[program:cron]\ncommand=/usr/sbin/cron -f\nautostart=true\nautorestart=true\nstdout_logfile=/var/log/cron-supervisor.log\nstderr_logfile=/var/log/cron-supervisor.log\n' > /etc/supervisor/conf.d/cron.conf
    supervisorctl reread && supervisorctl update
  else
    /usr/sbin/cron
  fi
}
# Timezone: every box agrees on UTC (#395 slice, BH-443). Orgo boxes have no
# systemd (PID 1 is init.sh), so the symlink branch is the one that normally
# runs. Every step carries `|| true` because this file is `set -euo pipefail`
# and a box that cannot set its own timezone is still a box worth bootstrapping.
if [ -d /run/systemd/system ]; then
  timedatectl set-timezone UTC || true
else
  ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime || true
  echo Etc/UTC > /etc/timezone || true
fi
[ "$(date +%Z)" = UTC ] || echo "WARN: timezone is still $(date +%Z), not UTC"
# Auditd install/repair (#395 slice, BH-443): idempotent, fail-open, and it may
# register a supervisord program exactly the way the cron block above does.
# HARNESS is pinned to the live tree because $HERE may be the checkout's bin/.
HARNESS=/root/harness "$HERE/audit-install.sh" || true
command -v bun >/dev/null || { curl -fsSL https://bun.sh/install | bash; export PATH="$HOME/.bun/bin:$PATH"; echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.bashrc; }
# QA + security tooling (2026-07-27): playwright drives preview deployments in the
# QA stage; semgrep feeds the review stage. Both fail-open in run-build.sh.
# Debian pip is externally-managed — semgrep goes in its own venv (whisper pattern).
command -v semgrep >/dev/null || {
  apt-get install -y -q python3-venv >/dev/null 2>&1 || true
  python3 -m venv /root/harness/venv-semgrep 2>/dev/null \
    && /root/harness/venv-semgrep/bin/pip install -q semgrep \
    && ln -sf /root/harness/venv-semgrep/bin/semgrep /usr/local/bin/semgrep || true
}
# gitleaks (BH-5789): the builder and review boxes run the leak gate a build
# must not skip (HARNESS_IMPACT_GATE_RUN sets GITLEAKS_REQUIRED=1). The pinned,
# sha256-checked binary from bin/lib/gitleaks-pin.sh, the same one CI installs;
# gitleaks_pin_ensure answers at once when the pin is already on PATH.
# shellcheck source=bin/lib/gitleaks-pin.sh
if . "$HERE/lib/gitleaks-pin.sh" 2>/dev/null; then
  gitleaks_pin_ensure /usr/local/bin || echo "WARN: the pinned gitleaks could not be installed; builds on this box fail their leak gate until it is"
else
  echo "WARN: bin/lib/gitleaks-pin.sh not found; gitleaks not installed"
fi
command -v playwright >/dev/null || npm install -g playwright >/dev/null 2>&1 || true
npx playwright install --with-deps chromium >/dev/null 2>&1 || true

# CodeGraph (2026-07-29, the operator): local semantic code index + MCP tools for every
# Claude session. Telemetry stays off on fleet boxes (client code). Repos get
# indexed after clone below; builds/triage use codegraph explore/query first.
if ! command -v codegraph >/dev/null 2>&1; then
  DO_NOT_TRACK=1 curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
codegraph telemetry off >/dev/null 2>&1 || true
codegraph install -t claude -l global -y >/dev/null 2>&1 || true
grep -q VERCEL_PLUGIN_TELEMETRY ~/.bashrc || echo "export VERCEL_PLUGIN_TELEMETRY=off" >> ~/.bashrc
echo y | npx -y plugins add vercel/vercel-plugin || true

echo "== harness dirs =="
mkdir -p /root/harness/{logs,state,locks,flags,builds,plans}
# Box identity for repo-managed crontabs (cron/<box-id>.cron via update-runners).
# Hostnames are NOT identity — five fleet boxes report the Orgo default
# "orgo-desktop". Derive it from the fleet.conf box column, which is the only
# place that actually knows which machine owns this project: the old
# "${PROJECT%-os}" guess names the box after whichever project happened to be
# bootstrapped FIRST, so loading project-7 onto box-project-6-1 would
# have written box-id "project-7" and pointed the box at a cron file that does
# not exist. The guess survives only as the last resort for a project with no
# registry row at all.
# shellcheck source=bin/lib/cron-lines.sh
. "$HERE/lib/cron-lines.sh"
BOX_HOST=$("$HERE/box-for.sh" "$PROJECT" 2>/dev/null || true)
if [ -n "$BOX_HOST" ]; then BOX_ID=$(cron_box_id_for "$BOX_HOST"); else BOX_ID="${BOX_ID:-${PROJECT%-os}}"; fi
[ -s /root/harness/state/box-id ] || echo "$BOX_ID" > /root/harness/state/box-id
BOX_ID=$(cat /root/harness/state/box-id)
# Build concurrency is a CAP, and an explicit one (the operator, 2026-09-13: "we never
# lock and serialize"). BUILD_SLOTS=0 means bin/run-build.sh takes no slot lock at
# all, so a second ticket never waits behind the first; a box that genuinely needs
# a ceiling (cores, RAM) sets a number here and run-build DEFERS rather than
# queues. The old flags/build-slots file is not written any more — it is read only
# as a legacy fallback when BUILD_SLOTS is unset.
# >>> global.env seeds
# global.env is +i once bin/harden-state.sh has armed the box (BH-390), and +i
# blocks appends too, so a re-bootstrap of an armed box died on the next line.
# Hold the re-arm lane's lock on fd 8 for the few milliseconds of
# release -> append -> rearm, so the */10 arm-all tick cannot re-arm the file
# between them. Same lock file and same fd the lane itself uses
# (bin/harden-state.sh:15-16); --release/--rearm do not take it, so there is no
# self-deadlock here. Strict, no `|| true`: a bootstrap that cannot arm the box
# is not complete (same rule as the arm at the end).
exec 8>/root/harness/locks/harden-state.lock
flock -w 60 8 || { echo "FATAL: locks/harden-state.lock held for 60s (a re-arm tick is stuck) — re-run" >&2; exit 1; }
"$HERE/harden-state.sh" --release "$HENV/global.env"
grep -q '^BUILD_SLOTS=' "$HENV/global.env" 2>/dev/null || echo "BUILD_SLOTS=0" >> "$HENV/global.env"
# Runner failovers: any stage whose primary runner dies (cap/auth/crash/timeout)
# retries once on codex (agent-call.sh). Weekly-cap lesson, project-4 2026-07-24.
for s in TRIAGE PLAN PREPLAN EXECUTE REVIEW FIX IDEATE PRD MOCKUP REVISE MAP SIGNALS SYNTH CHAT; do
  grep -q "RUNNER_${s}_FALLBACK" "$HENV/global.env" || echo "RUNNER_${s}_FALLBACK=codex" >> "$HENV/global.env"
done
"$HERE/harden-state.sh" --rearm "$HENV/global.env"
exec 8>&-
# <<< global.env seeds
mkdir -p /root/worktrees /root/repos

echo "== box gh default =="
# >>> box gh default
# The App installation token becomes this box's default GitHub identity BEFORE
# the first clone: the clone is the first GitHub call, and on a box with no
# keyring login nothing else can authenticate it. global.env is sourced here for
# the same reason — the PAT fallback inside gh-token.sh reads GH_TOKEN from it.
set -a; . "$HENV/global.env"; set +a
"$HERE/ensure-box-gh-app-default.sh" "$REPO_SLUG" || echo "WARN: gh App default not installed — gh keeps its current login"
# An EMPTY answer is never exported: gh-token.sh prints nothing when the box
# mints no App token and global.env carries no PAT either, and GH_TOKEN="" makes
# the clone below run unauthenticated instead of on gh's keyring login.
_t=$("$HERE/gh-token.sh" "$REPO_SLUG" 2>/dev/null || true); [ -n "$_t" ] && export GH_TOKEN="$_t"; unset _t
# <<< box gh default

bm_repos

echo "== cron =="
# Fly builder trial (Phase 2): the dispatcher + results-ingest crons are
# HUB-ONLY — the hub is the single box that holds env/fly.env (deploy tokens),
# so its presence is the hub signal. Watchers never run the dispatcher; their
# only Fly touchpoint is the flag-gated enqueue shim inside run-build.sh.
FLY_CRON=""
if [ -f "$HENV/fly.env" ]; then
  FLY_CRON=fly
  echo "== fly builder trial: this box has env/fly.env -> installing hub dispatcher crons =="
fi
# THE INCIDENT THIS SHAPE FIXES (project-7, 2026-08-30). Bootstrap used to hand-
# write ONE project's lines while update-runners.sh applied a hand-maintained
# repo file — two writers, no reconciliation, and onboarding a second project
# onto a box installed lanes the file had never heard of. The 05:17 tick copied
# the file back and the lane died silently.
#
# So bootstrap now runs the SAME renderer the daily job runs. It seeds the
# box-level singletons (per BOX, not per project — a two-project box runs one
# preplan tick), then render-crontab.sh lays down a block for EVERY project
# fleet.conf gives this box. Bootstrapping project N can no longer erase M.
CRONBASE=$(mktemp)
# Start from the live crontab minus the box-level singletons, which are re-
# emitted below so a box that never had them gets them. Project lines are NOT
# filtered here: the renderer absorbs every one it owns, for EVERY project on
# this box, which is exactly the guarantee bootstrap used to lack.
crontab -l 2>/dev/null \
  | grep -v preplan-tick | grep -v reconcile-prs | grep -v update-runners \
  | grep -v fly-dispatch | grep -v fly-results-ingest \
  | grep -v harden-state | grep -v state-backup \
  > "$CRONBASE" || true
cron_box_lines "$FLY_CRON" >> "$CRONBASE"
# >>> crontab render+apply
# NEVER `render | crontab -`. crontab(1) consumes stdin and commits BEFORE the
# pipeline's failure surfaces, so a render that dies — a missing
# /root/harness/fleet.conf (reachable: load-project runs harness-sync with
# `|| true`), a malformed registry row, an unterminated marker — pipes ZERO
# BYTES into it and `set -euo pipefail` aborts one instruction too late. On a
# populated box that wipes every lane, the @reboot sshd/cron/tailscaled line
# and the watchdog ping: the box is unreachable after its next reboot and
# nothing pings in the meantime, which is a strictly worse outcome than the
# stale crontab we were trying to fix.
#
# So: render to a file, prove it is both successful AND non-empty, and only
# then hand it to crontab. Same guard update-runners.sh applies on its path.
# --root defaults to $HERE/.. = /root/harness, which carries the fleet.conf and
# prompts/ that harness-sync deploys — the same registry the daily tick reads.
CRONTMP=$(mktemp)
if ! "$HERE/render-crontab.sh" --base "$CRONBASE" "$BOX_ID" > "$CRONTMP"; then
  rm -f "$CRONTMP" "$CRONBASE"
  echo "FATAL: render-crontab.sh failed for box $BOX_ID — the live crontab was NOT touched. Check /root/harness/fleet.conf and cron marker balance, then re-run." >&2
  exit 1
fi
if [ ! -s "$CRONTMP" ]; then
  rm -f "$CRONTMP" "$CRONBASE"
  echo "FATAL: render-crontab.sh produced an EMPTY crontab for box $BOX_ID — refusing to install it. The live crontab was NOT touched." >&2
  exit 1
fi
crontab "$CRONTMP"
rm -f "$CRONTMP" "$CRONBASE"
# <<< crontab render+apply
crontab -l

echo "== smoke test =="
set -a; . "$HENV/global.env"; . "$HENV/$PROJECT.env"; set +a
# The env files carry the PAT; gh-token.sh answers the App token when this box
# mints them and that same PAT when it does not. Exported explicitly so the gh
# read below runs on the identity this box will actually use from now on. An
# empty answer leaves the env files' own GH_TOKEN standing, same as the identity
# block above.
_t=$("$HERE/gh-token.sh" "$REPO_SLUG" 2>/dev/null || true); [ -n "$_t" ] && export GH_TOKEN="$_t"; unset _t
BASE_VAR=$(grep -oE "^[A-Z_]+_(API|APP)_BASE" "$HENV/$PROJECT.env" | head -1)
if [ -n "$BASE_VAR" ] && [ -n "${!BASE_VAR:-}" ] && [ "${!BASE_VAR}" != "-" ]; then
  echo "board reachable: $(curl -s -o /dev/null -w '%{http_code}' -m 10 "${!BASE_VAR}")"
else
  echo "board: GitHub Issues (no app API base) — checking gh instead"
  for _P in "$HERE/lib/gh-rest.sh" "${HARNESS:-/root/harness}/bin/lib/gh-rest.sh"; do
    # shellcheck source=bin/lib/gh-rest.sh
    [ -r "$_P" ] && { . "$_P"; break; }
  done
  gh_rest GET "repos/$REPO_SLUG/issues" -F per_page=1 >/dev/null && echo "gh issue access OK (GH_TOKEN from gh-token.sh)"
fi
# >>> smoke model (BH-1510.4) — the model comes from the bootstrap.smoke row in
# model_routes (bin/lib/model-route.sh), never a literal. No route in the DB and
# none cached is FATAL: the resolver has already written its ALERTS line, and a
# smoke turn on a guessed model would prove nothing about the one this box runs.
# tests/model-literal-strict.bh-1510-4-test.sh runs this block as shipped.
# The `|| SMOKE_M=""` is load-bearing: under this file's `set -e` a bare failing
# model_for would end the bootstrap with rc 75 and no FATAL line naming the role.
# The turn itself goes through agent-call (BH-2535): stage probe, lane
# claude-auth-check, so it writes a priced cost row like every other call.
# AGENT_CALL_RUNNERS=claude pins the runner: a fallback rung answering OK would
# pass the smoke on a dead claude login. Any non-zero rc (a refusal included:
# its marker is the outfile's first line) and an rc-0 empty answer are FATAL.
# tests/bootstrap-smoke-agent-call.bh-2535-test.sh runs this block as shipped.
. "$HERE/lib/model-route.sh" && SMOKE_M=$(model_for bootstrap.smoke) || SMOKE_M=""
[ -n "$SMOKE_M" ] || { echo "FATAL: no model route for bootstrap.smoke (model_routes) — seed it or PUT /api/model-routes/bootstrap.smoke"; exit 1; }
# A private dir, because agent-call leaves sidecars (<out>.json, .err, ...) next
# to the outfile and the whole dir goes when the smoke is done.
SMOKE_D=$(mktemp -d); SMOKE_OUT="$SMOKE_D/out"
AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=claude-auth-check "$HERE/agent-call.sh" probe fleet "$SMOKE_M" 90 "$SMOKE_OUT" "Reply exactly: OK" \
  || { _rc=$?; echo "FATAL: claude session failed (agent-call rc $_rc: $(head -c 200 "$SMOKE_OUT" 2>/dev/null))"; rm -rf "${SMOKE_D:?}"; exit 1; }
[ -s "$SMOKE_OUT" ] || { echo "FATAL: claude session failed (agent-call rc 0 with no answer)"; rm -rf "${SMOKE_D:?}"; exit 1; }
rm -rf "${SMOKE_D:?}"
# <<< smoke model
echo "== tmpfs =="
# BH-6041: size a tmpfs /tmp from RAM and persist it in fstab, before harden
# makes files immutable. Never fatal: a box with a disk /tmp is a log line.
"$HERE/tmpfs-ensure.sh" || echo "WARN: tmpfs-ensure rc $?"
echo "== harden =="
# Last, because every earlier step writes to env/ and logs/. The hardened=N/M
# changed=K line it prints stays in the bootstrap log. A box that cannot be
# armed is not a box this fleet is willing to call bootstrapped, so this is
# fatal rather than a warning.
"$HERE/harden-state.sh" || { echo "FATAL: harden-state.sh could not arm this box — env/, the ssh key and the ledgers are NOT immutable; fix chattr/lsattr and re-run" >&2; exit 1; }
echo "== BOOTSTRAP COMPLETE: $PROJECT watcher live on this box =="
