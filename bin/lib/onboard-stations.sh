# BH-7934.1 owns this file
# shellcheck shell=bash
# bin/lib/onboard-stations.sh — the onboarding station functions, sourced by
# bin/load-project.sh and by the onboarding runner (BH-7934.2). One
# implementation of the stations for both callers: the bodies are
# bin/load-project.sh steps 1-5, moved as is.
#
# Interface, one function per station: obs_register, obs_prompt, obs_label,
# obs_box, obs_clone. Each reads the globals PROJECT SLUG REPO PROD BOX PREFIX
# BASE REGISTRY_SOURCE that bin/load-project.sh sets, prints its own lines,
# and returns non-zero on failure (never exit, so the runner records the step).
# The tracker station (used instead of label when the tracker is not
# github-issues) calls onb_tracker_check from bin/lib/hub-probes/tracker-test.sh
# and does not copy it.
#
# What a caller must do first: set ROOT to the cromford checkout, run
# `cd "$ROOT"` (the paths below are relative to it, as they were in
# load-project.sh), and source bin/lib/deployment.sh (obs_box reads
# HARNESS_REPO). Other globals read, each with the CLI's own default when
# unset: PREFIX_LC (from PREFIX), CONTEXT_FILE (empty), FLY (0), QUEUE
# (fly/onboard-queue.conf). Globals a station SETS: REG_MODE (obs_register; the
# others derive it when it is unset) and OBS_RUN_ON_BOX (obs_box, obs_clone).
#
# A function called as `obs_x || exit 1` runs with `set -e` OFF inside it, so
# each command the old top-level code left to `set -e` carries its own
# `|| return 1`. Sourcing this file defines functions only: no statement runs.

# _obs_reg_mode — prints `db` when REGISTRY_SOURCE is exactly "db", else `file`.
# Anything but exactly "db" is file mode, as in fleet-conf.sh.
_obs_reg_mode() {
  if [ "${REGISTRY_SOURCE:-}" = db ]; then echo db; else echo file; fi
}

# obs_register — step 1: the registry row (the D1 registry in db mode, a
# fleet.conf append in file mode), with a free cron offset among the box's
# projects.
obs_register() {
  local OFF USED BOX_IP cand pj
  echo "== registry =="
  export FLEET_CONF="$ROOT/fleet.conf"
  # REGISTRY_SOURCE=db (BH-5650): the D1 registry is what every reader sees, so
  # the row goes THERE. A fleet.conf append in db mode would be a row no
  # fleet-conf.sh call returns, committed as if it were the registry. The two
  # reads below need no branch: fleet-conf.sh and box-for.sh read the registry in
  # db mode already. Anything but exactly "db" is file mode, as in fleet-conf.sh.
  REG_MODE=$(_obs_reg_mode)
  if bin/fleet-conf.sh "$PROJECT" repo >/dev/null 2>&1; then
    echo "fleet.conf row exists — skipping"
    OFF=$(bin/fleet-conf.sh "$PROJECT" offset) || return 1
  else
    # Free cron-offset minute (0-9) among projects on the SAME box; least-used if full.
    USED=$(for pj in $(bin/fleet-conf.sh --projects); do
      [ "$(bin/box-for.sh "$pj" 2>/dev/null)" = "$BOX" ] && bin/fleet-conf.sh "$pj" offset || true; done)
    OFF=""
    for cand in 1 3 5 7 0 2 4 6 8 9; do
      grep -qx "$cand" <<<"$USED" || { OFF=$cand; break; }
    done
    [ -n "$OFF" ] || OFF=$(sort <<<"$USED" | uniq -c | sort -n | awk 'NR==1{print $2}')
    if [ "$REG_MODE" = db ]; then
      # No token = no write, and NO fallback append: the reader would not see it.
      [ -n "${REGISTRY_ADMIN_TOKEN:-}" ] \
        || { echo "FATAL: REGISTRY_SOURCE=db and REGISTRY_ADMIN_TOKEN is unset — cannot write the registry row for $PROJECT; nothing written"; return 1; }
      bin/registry.sh add-project "$PROJECT" --repo "$SLUG" --prod "$PROD" --offset "$OFF" --box "$BOX" \
        || { echo "FATAL: bin/registry.sh add-project $PROJECT failed (above) — no prompt, no commit"; return 1; }
      # TTL 0: the 60 s cache was filled by the reads above, without this row.
      REGISTRY_CACHE_TTL_S=0 bin/fleet-conf.sh "$PROJECT" offset >/dev/null \
        || { echo "FATAL: the registry row for $PROJECT did not read back — not committing"; return 1; }
      echo "registry: added ($PROJECT offset=$OFF box=$BOX)"
    else
      # A registry whose last byte is not "\n" GLUES the new row onto the last one
      # and publishes it (harness-console onto cromford, 2026-09-16, hand-split
      # in 00a9911): the old row's box column grew a project name, the new project
      # had no row at all, and the push went out green.
      [ ! -s fleet.conf ] || [ -z "$(tail -c1 fleet.conf)" ] || echo >> fleet.conf || return 1
      # The 7th column is the box's tailnet address. A box the registry already
      # knows gets it (project-6-desktop, 8a1d9bc7c: a 6-column row on small made
      # box-register refuse "box small already has the address -"). A new box has
      # none yet, so its row stays at 6 columns until box-register sets it.
      BOX_IP=$(bin/fleet-conf.sh --tailnet-ip-of-box "$BOX" 2>/dev/null) || BOX_IP=""
      printf '%-13s %-26s %-36s %-3s %-2s %s%s\n' "$PROJECT" "$SLUG" "$PROD" "-" "$OFF" "$BOX" "${BOX_IP:+ $BOX_IP}" >> fleet.conf || return 1
      # Read the row back through the same parser every lane uses, BEFORE the commit
      # step below can publish it. This is the one check that would have stopped
      # 00a9911's row from reaching main.
      bin/fleet-conf.sh "$PROJECT" offset >/dev/null \
        || { echo "FATAL: fleet.conf row for $PROJECT did not parse back — not committing"; return 1; }
      echo "fleet.conf: added ($PROJECT offset=$OFF box=$BOX)"
    fi
  fi
}

# _obs_prompt_render — step 2: render prompts/<project>.md and show the
# crontab preview.
_obs_prompt_render() {
  local CONTEXT BOX_ID CRON_PREVIEW LINES
  local prefix_lc="${PREFIX_LC:-$(echo "$PREFIX" | tr '[:upper:]' '[:lower:]')}"
  echo "== prompt =="
  if [ -f "prompts/$PROJECT.md" ]; then
    echo "prompts/$PROJECT.md exists — skipping"
  else
    CONTEXT=""
    if [ -n "${CONTEXT_FILE:-}" ]; then CONTEXT=$(cat "$CONTEXT_FILE") || return 1; fi
    export CONTEXT
    python3 - "$PROJECT" "$SLUG" "$PROD" "$PREFIX" "$prefix_lc" "$BASE" <<'PY' || return 1
import sys, os
project, slug, prod, prefix, prefix_lc, base = sys.argv[1:7]
t = open('prompts/TEMPLATE-GH.md').read()
# drop the template header note
lines = t.split('\n')
lines[0] = f'# Triage run — {project} (GitHub Issues board)'
t = '\n'.join(lines)
ctx = os.environ.get('CONTEXT','').strip()
t = t.replace('<CONTEXT>', ctx if ctx else '')
for a,b in [('<PROJECT>',project),('<REPO_SLUG>',slug),('<PROD_URL>',prod),
            ('<KEY_PREFIX_LC>',prefix_lc),('<key_prefix_lc>',prefix_lc),
            ('<KEY_PREFIX>',prefix),('<BASE_BRANCH>',base)]:
    t = t.replace(a,b)
open(f'prompts/{project}.md','w').write(t)
PY
    echo "prompts/$PROJECT.md rendered"
  fi

  echo "== crontab =="
  # THE CRONTAB IS NO LONGER A COMMITTED ARTIFACT (BH-1247). This block used to
  # regenerate cron/<box-id>.cron and publish it in the SAME commit as the
  # fleet.conf row, because a row published without a regenerated cron file was a
  # lane the next 05:17 tick quietly deleted — that is how project-7 died ten
  # hours after it was loaded.
  #
  # The render is produced on the box now, by bin/render-crontab.sh, from the
  # registry plus the fragments. So the fleet.conf row IS the whole of onboarding
  # and the second step cannot be forgotten: there is no file left to forget to
  # regenerate. What is still worth doing here is SHOWING the operator the lines
  # this box will gain — rendered into a temp file, never into the tree.
  # shellcheck source=bin/lib/cron-lines.sh
  . bin/lib/cron-lines.sh || return 1
  BOX_ID=$(cron_box_id_for "$BOX") || return 1
  CRON_PREVIEW=$(mktemp) || return 1
  # No `trap ... EXIT` for the temp file: inside a function it would REPLACE the
  # caller's own EXIT trap (the runner's, or the vmap block's in load-project.sh).
  # Every path below reaches the rm -f instead.
  if bin/render-crontab.sh "$BOX_ID" > "$CRON_PREVIEW" 2>/dev/null && [ -s "$CRON_PREVIEW" ]; then
    LINES=$(grep -c -- "$PROJECT" "$CRON_PREVIEW" 2>/dev/null) || LINES=0
    echo "cron/$BOX_ID.cron renders $LINES line(s) for $PROJECT (generated on the box, not committed):"
    grep -- "$PROJECT" "$CRON_PREVIEW" | sed 's/^/    /' || true
    [ "$LINES" -gt 0 ] || echo "WARN: the render carries NO line for $PROJECT — check the fleet.conf row and bin/box-for.sh"
  else
    echo "WARN: bin/render-crontab.sh $BOX_ID would not render — the box would keep its current crontab."
    echo "      Run it by hand and read the error before relying on this onboarding."
  fi
  rm -f "$CRON_PREVIEW"
}

# _obs_prompt_publish — step 3: commit + push cromford (pull --rebase
# first — the hub pushes too), then check that origin matches HEAD. Under
# FLY=1 the queue file rides the same commit (load-project.sh step 4d writes
# the line between the render and this publish).
_obs_prompt_publish() {
  local -a COMMIT_PATHS
  local fly="${FLY:-0}" queue="${QUEUE:-fly/onboard-queue.conf}"
  [ -n "${REG_MODE:-}" ] || REG_MODE=$(_obs_reg_mode)
  echo "== commit + push =="
  # cron/<box>.cron is NOT in this list any more (BH-1247): it is generated on the
  # box and git-ignored, so there is nothing to diff, nothing to stage, and
  # nothing that can be forgotten. What onboarding commits is the fleet.conf row
  # and the prompt — and the row alone is now enough to keep the lane alive,
  # which is the property the cron regeneration used to buy by hand.
  # In db mode the row is already in the registry (BH-5650), so fleet.conf is out
  # of the diff check and out of `git add`: a stray local edit to it must not ride
  # an onboarding commit. The prompt still commits — code stays in PRs.
  COMMIT_PATHS=(fleet.conf "prompts/$PROJECT.md")
  if [ "$REG_MODE" = db ]; then COMMIT_PATHS=("prompts/$PROJECT.md"); fi
  if ! git diff --quiet -- "${COMMIT_PATHS[@]}" 2>/dev/null \
     || [ -n "$(git status --porcelain -- "${COMMIT_PATHS[@]}")" ] \
     || { [ "$fly" = 1 ] && [ -n "$(git status --porcelain -- "$queue")" ]; }; then
    git add "${COMMIT_PATHS[@]}" || return 1
    # Staged only under --fly, so the default path stages exactly what it staged
    # before this flag existed.
    if [ "$fly" = 1 ]; then git add "$queue" || return 1; fi
    git commit -q -m "load-project: $PROJECT ($SLUG) on $BOX

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || return 1
  fi
  # Publish MUST land before the box syncs — verify, don't assume (a refused
  # rebase or rejected push here left a box bootstrapping against a registry
  # that didn't have the project, 2026-08-18).
  git pull --rebase --autostash -q || { echo "FATAL: rebase failed — resolve and re-run"; return 1; }
  git push -q || { echo "FATAL: push failed — resolve and re-run"; return 1; }
  git fetch -q origin || return 1
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/HEAD)" ] \
    || { echo "FATAL: origin does not match HEAD after push"; return 1; }
  echo "published $(git rev-parse --short HEAD)"
}

# obs_prompt — steps 2-3: render, crontab preview, commit + push.
obs_prompt() {
  _obs_prompt_render || return 1
  _obs_prompt_publish || return 1
}

# obs_label — step 4: the `ai-build` label on the repo, through the App token.
# The CLI armed GH_TOKEN before step 1, so it mints no second token here.
obs_label() {
  if [ -z "${GH_TOKEN:-}" ] && command -v gh_auth_for >/dev/null 2>&1; then
    gh_auth_for "$SLUG" || true
  fi
  echo "== ai-build label =="
  gh label create ai-build -R "$SLUG" --color 1D76DB \
    --description "Harness-buildable: the board watcher acts on this" 2>/dev/null \
    && echo "label created" || echo "label exists"
}

# _obs_box_cmd — sets OBS_RUN_ON_BOX: ssh to $BOX, or a local bash when $BOX is
# this machine.
# Run the block LOCALLY when the target box IS this machine. Loading project-7
# from the project-6 box itself tried `ssh root@box-project-6-1`, which
# is a tailnet name the box does not resolve for ITSELF: the ssh died with
# "Could not resolve hostname", so the runtime fleet.conf was never synced and
# the env stub was never written — and because the failure was at the very last
# step it read as "nearly done" rather than "not done".
_obs_box_cmd() {
  if ! declare -F cron_box_id_for >/dev/null; then
    # shellcheck source=bin/lib/cron-lines.sh
    . bin/lib/cron-lines.sh || return 1
  fi
  OBS_RUN_ON_BOX=(ssh -o ConnectTimeout=15 "root@$BOX" bash -s --)
  if [ "$BOX" = "$(hostname 2>/dev/null)" ] \
     || { [ -r /root/harness/state/box-id ] && [ "$(cron_box_id_for "$BOX")" = "$(cat /root/harness/state/box-id)" ]; }; then
    echo "target box is THIS machine — running the bootstrap block locally, not over ssh"
    OBS_RUN_ON_BOX=(bash -s --)
  fi
}

# obs_box — step 5: over ssh to the box (or locally), pull
# /root/harness-checkout, sync the runtime, write the env stub, run
# bootstrap-machine.sh <project> (crons, clone, smoke). Returns the block's own
# rc.
obs_box() {
  local BOOT_RC
  REG_MODE="${REG_MODE:-$(_obs_reg_mode)}"
  echo "== box: $BOX =="
  _obs_box_cmd || return 1
  BOOT_RC=0
  "${OBS_RUN_ON_BOX[@]}" "$PROJECT" "$PROD" "$PREFIX" "$BASE" "$HARNESS_REPO" "$REG_MODE" <<'REMOTE' || BOOT_RC=$?
set -euo pipefail
PROJECT="$1"; PROD="$2"; PREFIX="$3"; BASE="$4"; HREPO="$5"
# The registry mode (BH-5650). Absent (an older caller) = file.
REG_MODE="${6:-file}"
if [ "$REG_MODE" = db ]; then export REGISTRY_SOURCE=db; fi
. /root/harness/bin/lib/env-path.sh 2>/dev/null || harness_env_dir() { printf '%s\n' /root/harness/env; }; E=$(harness_env_dir)
# Preconditions: a provisioned fleet box (see docs/OPERATOR-SETUP.md).
[ -f "$E/global.env" ] || { echo "FATAL: $E/global.env missing — provision the box first"; exit 1; }
# C2: the box's GitHub credential is bin/gh-token.sh's answer (the App, then its
# PAT ladder: env/global.env, env/gh-pat). A keyring login is only the fallback —
# the fleet is logging it out, and it is the operator's PAT where it still exists.
_gt=""
[ -x /root/harness/bin/gh-token.sh ] && _gt=$(/root/harness/bin/gh-token.sh "$HREPO" 2>/dev/null || true)
if [ -z "$_gt" ] && ! gh auth status >/dev/null 2>&1; then
  echo "FATAL: no GitHub credential on box — /root/harness/bin/gh-token.sh $HREPO printed nothing (check env/github-app.env + .pem, or env/gh-pat) and gh has no keyring login"; exit 1
fi
unset _gt
# Sync the fresh checkout into the runtime.
# The clone below is a different repo from $SLUG, so it arms again — and this
# block runs ON THE BOX, where the lib is absent until the box's first sync.
[ -r /root/harness/bin/lib/gh-app-auth.sh ] && . /root/harness/bin/lib/gh-app-auth.sh || true
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$HREPO" || true
if [ -d /root/harness-checkout/.git ]; then
  git -C /root/harness-checkout pull --ff-only -q
else
  gh repo clone "$HREPO" /root/harness-checkout -- -q
fi
# In db mode the row is in the registry, not in the checkout's fleet.conf, and
# bootstrap-machine.sh below reads it there (REGISTRY_SOURCE exported above).
if [ "$REG_MODE" != db ]; then
  grep -qE "^$PROJECT[[:space:]]" /root/harness-checkout/fleet.conf \
    || { echo "FATAL: $PROJECT not in the box checkout's fleet.conf — was the publish step green?"; exit 1; }
fi
[ -f "/root/harness-checkout/prompts/$PROJECT.md" ] \
  || { echo "FATAL: prompts/$PROJECT.md missing in the box checkout"; exit 1; }
mkdir -p /root/harness
if [ -x /root/harness/bin/harness-sync.sh ]; then
  /root/harness/bin/harness-sync.sh || true
else
  cp -r /root/harness-checkout/bin /root/harness/
  cp -r /root/harness-checkout/prompts /root/harness/
  if [ "$REG_MODE" != db ]; then cp /root/harness-checkout/fleet.conf /root/harness/fleet.conf; fi
  for d in catalog rules; do [ -d "/root/harness-checkout/$d" ] && cp -r "/root/harness-checkout/$d" /root/harness/; done
fi
# Env stub (GitHub-Issues board: no app token needed; PROD may be "-").
# The sync above must have actually landed the prompt (rsync missing on a
# fresh box made it fail silently once — 2026-08-18).
[ -f "/root/harness/prompts/$PROJECT.md" ] \
  || { echo "FATAL: /root/harness/prompts/$PROJECT.md not deployed — check rsync + harness-sync log"; exit 1; }
ENVF="$E/$PROJECT.env"
# >>> env stub (BH-7930)
# A file that already exists (written by hand before the load, with tracker
# credentials) gets the two keys bootstrap reads appended when they are missing:
# a base var (same regex as bootstrap's smoke test) and BASE_BRANCH. The append
# never rewrites the file or changes its mode. A file that has both is not
# touched at all. tests/load-project-env-exists.bh-7930-test.sh runs this block.
_k1=""; _k2=""
if [ -f "$ENVF" ]; then
  grep -qE "^[A-Z_]+_(API|APP)_BASE=" "$ENVF" || _k1="${PREFIX}_API_BASE=$PROD"
  grep -q '^BASE_BRANCH=' "$ENVF" || _k2="BASE_BRANCH=$BASE"
fi
ADD="$_k1${_k1:+${_k2:+ }}$_k2"
if [ ! -f "$ENVF" ] || [ -n "$ADD" ]; then
  # Literal path, [ -x ]-guarded: a box that has not synced bin/ yet simply has
  # no harden-state.sh and the wrap is a no-op (a false [ -x ] on the left of &&
  # does not trip this heredoc's `set -e`). --release on a file that does not
  # exist is rc 0 and quiet; the --rearm after the write is what arms the file
  # again immediately, so the box is never left with one unhardened env file.
  [ -x /root/harness/bin/harden-state.sh ] && /root/harness/bin/harden-state.sh --release "$ENVF"
  if [ -n "$ADD" ]; then
    # A last line with no newline must not glue onto the first appended key.
    if [ -s "$ENVF" ] && [ -n "$(tail -c1 "$ENVF")" ]; then echo >> "$ENVF"; fi
    for _kv in "$_k1" "$_k2"; do [ -z "$_kv" ] || echo "$_kv" >> "$ENVF"; done
    _msg="env: added $ADD"
  else
    {
      echo "# $PROJECT project env — board is GitHub Issues (gh auth), no internal API token"
      echo "${PREFIX}_API_BASE=$PROD"
      echo "BASE_BRANCH=$BASE"
      echo "# optional, add when available:"
      echo "#DEPLOY_HOOK_URL="
      echo "#VERCEL_AUTOMATION_BYPASS_SECRET="
    } > "$ENVF"
    chmod 600 "$ENVF"
    _msg="env stub written: $ENVF"
  fi
  [ -x /root/harness/bin/harden-state.sh ] && /root/harness/bin/harden-state.sh --rearm "$ENVF"
  echo "$_msg"
fi
# <<< env stub
/root/harness/bin/bootstrap-machine.sh "$PROJECT"
REMOTE
  # The remote block's rc is CAPTURED rather than left to `set -e`. It propagates
  # today only because that line is a bare top-level command, which one `|| true`
  # or one `set +e` above it would silently undo — and the loader itself said
  # nothing, so the remote FATAL scrolled past under a "== LOADED" that never came.
  # The rung is stated honestly: publishing already happened, setup did not.
  [ "$BOOT_RC" = 0 ] || {
    echo "FATAL: bootstrap block on $BOX exited $BOOT_RC — registry, prompt and crontab are PUBLISHED, but the box is NOT set up. Fix the FATAL above and re-run (idempotent)."
    return "$BOOT_RC"
  }
}

# obs_clone — the runner's clone station: bootstrap-machine.sh <project>
# --repos-only on the box (the clone of /root/repos/<project>; no crontab).
# bin/load-project.sh does not call it: its obs_box runs the full bootstrap,
# which clones too.
obs_clone() {
  local CLONE_RC
  REG_MODE="${REG_MODE:-$(_obs_reg_mode)}"
  echo "== clone: $PROJECT on $BOX =="
  _obs_box_cmd || return 1
  CLONE_RC=0
  "${OBS_RUN_ON_BOX[@]}" "$PROJECT" "$REG_MODE" <<'CLONE' || CLONE_RC=$?
set -euo pipefail
PROJECT="$1"
# In db mode bootstrap-machine.sh reads the row from the registry (BH-5650).
if [ "${2:-file}" = db ]; then export REGISTRY_SOURCE=db; fi
/root/harness/bin/bootstrap-machine.sh "$PROJECT" --repos-only
CLONE
  [ "$CLONE_RC" = 0 ] || { echo "FATAL: clone on $BOX exited $CLONE_RC"; return "$CLONE_RC"; }
}
