#!/bin/bash
# bin/fly-envbundle.sh <project> <outdir> [--pool] — build the env bundle a Fly builder
# needs for a REAL build, into <outdir>/{global.env,<project>.env}. Runs on the
# HUB. Prints nothing sensitive; the caller (fly-dispatch.sh) pushes the bundle
# to the builder's tmpfs and shreds <outdir> immediately after.
#
# TRANSPORT / SOURCING (task brief, HARD-WON):
#   The hub does NOT keep other projects' watcher secrets on disk. The build
#   secrets live on the project's OWNING watcher box. We pull them over tailnet
#   ssh from that box at dispatch time (hub->box ssh works), assemble the bundle
#   under a caller-supplied mktemp dir, and never persist it longer than the push.
#
# WHITELIST (task brief + plan "fly-envbundle.sh" — the single isolation choke
# point; review this hard). Only these leave the hub for a builder:
#
# TWO CREDENTIALS IN THE BUNDLE ARE NOW PER-MACHINE, AND NEITHER IS SWAPPED HERE.
# This script always writes the owning box's own values; bin/fly-pool.sh then
# REPLACES two lines in the copy it is about to push, per machine, before it
# leaves the hub: GH_TOKEN (a repo-scoped App token, 2026-09-14; since BH-1578
# minted from the builders App, env/github-app-builders.env, with the
# GH_TOKEN_INSTALLATION_ID line naming its bucket for the ledger) and
# CLAUDE_CODE_OAUTH_TOKEN (a leased max account, bin/lib/pool-account.sh,
# 2026-09-14). So "the whole pool shares the box's Claude account" is no longer
# true on a box with env/tokens.d, and the sanity check at the bottom is about
# the bundle being COMPLETE, not about which account ends up paying. The
# whitelist below is unchanged and still the only thing that leaves the hub.
#
#   from the box's global.env : CLAUDE_CODE_OAUTH_TOKEN, CONSOLE_URL,
#       HARNESS_SECRET, IS_SANDBOX, VERCEL_PLUGIN_TELEMETRY, TRIAGE_MODEL,
#       LOCKS_URL + LOCKS_TOKEN (the cross-harness ticket lock a build takes in
#       bin/lib/rb/gates.sh, 2026-10-20), all RUNNER_* (runner + failover parity with agent-call.sh), and a
#       JOBS_URL line verbatim when the box has one (empty included).
#   ALL of the box's <project>.env (board token/base, Turso/DB creds the QA
#       stage reads, migration/QA/bypass secrets — every var the pipeline stages
#       read on a builder for THIS project).
#   GH_TOKEN : the owning box's `bin/gh-token.sh --pat <slug>` (C2,
#       2026-09-24) — its PAT ladder (env/global.env, env/gh-pat, the keyring
#       only as the last rung), so it survives the fleet's keyring logout.
#       DELIBERATELY NOT AN APP TOKEN (review of #2231): bin/fly-dispatch.sh
#       ships this bundle as-is and has no rotation, so a 1-hour installation
#       token would 401 the final push of any dispatch build past ~60 min, and a
#       hub-App-authored PR cannot be APPROVEd by the same App in review-prs.
#       The pool route swaps this line per machine for a rotated builders-App
#       token (bin/fly-pool.sh). So the builder's `gh auth setup-git` + git
#       push/pr work.
#       THE PAT IS REQUIRED FOR fly-dispatch ONLY (BH-4798, 2026-10-06). The
#       pool route (bin/fly-pool.sh spawn, bin/fly-pool-rollout.sh smoke) passes
#       `--pool`, and there a missing PAT is a WARN and the bundle ships without
#       a GH_TOKEN line, but only when this hub is armed for App tokens, because
#       only then does fly-pool.sh swap one in. Unarmed, it still dies. Why: on
#       2026-10-06 the small box's keyring logout took its only plain PAT, this
#       script died for every cromford and project-8 pool spawn,
#       and none of those machines would ever have used that PAT.
#   REPO_SLUG / BASE_BRANCH : resolved from fleet.conf on the hub (warm-up clone
#       target + PR base) — no hardcoded owner on the builder.
# NEVER leaves the hub: ORGO_API_KEY, TELEGRAM_*, SLACK_* (the chat transports
#   are the hub's alone), FLY_* tokens, TS_AUTHKEY_*,
#   and any OTHER project's env. Blanket copy is forbidden — explicit keys only.
#   One Fly credential does reach a pool machine, and not through this file:
#   bin/fly-pool.sh pushes a Fly SSH token scoped to the test-host app (no
#   deploy, no secrets, no other app), valid only for the route's hours, to
#   /run/harness-env/testhost.env (BH-8335).
#
# API KEY PROJECTS (BH-9718): when the settings row claude_auth.<project> is
# `api-key` (bin/lib/claude-auth.sh), the project pays with its own Anthropic
# API key. The bundle then has no CLAUDE_CODE_OAUTH_TOKEN line and has the
# marker line CLAUDE_AUTH_MODE=api-key, in all three modes. The key itself is
# never in the bundle and never on the hub: it is the pool app's Fly secret
# ANTHROPIC_API_KEY_<PROJECT>, which fly/entrypoint.sh stages in RAM on the
# machine. A row with any other value dies (rc 1, no bundle file left). With
# no row the bundle is the same as before. See docs/ACCOUNT-ROUTING.md.
#
# SSH OFF (BH-8316): the settings row pool.envbundle_ssh.<project> = off refuses
# the ssh extract (rc 1, 0 ssh calls, one ALERTS line "push path refused: ssh
# off"). See envbundle_ssh_guard below and
# docs/notes/2026-10-25-MKF-1-pull-path-project-6.md.
#
# --hub-global (BH-8317): the GLOBAL whitelist only, extracted from THIS host's
# own env/global.env. No owning-box lookup, no ssh, no ssh-off guard, no
# gh-token.sh call, no <project>.env read: <outdir>/<project>.env is written
# empty and gets no REPO_SLUG. The CLAUDE_CODE_OAUTH_TOKEN check still applies;
# the GH_TOKEN check does not (the pool never ships the PAT). Its only caller is
# `bin/fly-pool-secrets-sync.sh <project> --no-box`, so the whitelist keeps one
# copy. See docs/notes/2026-10-25-BH-8317-secret-store.md.
#
# SHARED POOL APP (BH-9783): --hub-global refuses (rc 1, no bundle file left)
# an api-key project whose pool app another project also names
# (state/fly/<p>.json .app or flags/fly-pool-app-<p>). Its marker would land in
# the app's HBUNDLE_G_* secrets, which every project on the app boots from.
set -uo pipefail

PROJECT="${1:?usage: fly-envbundle.sh <project> <outdir> [--pool|--hub-global]}"
OUTDIR="${2:?usage: fly-envbundle.sh <project> <outdir> [--pool|--hub-global]}"
HARNESS="${HARNESS:-/root/harness}"

die() { echo "fly-envbundle/$PROJECT FATAL: $*" >&2; exit 1; }
# A typo here must never run dispatch semantics as pool or the reverse.
HUBG=""
case "${3:-}" in
  ''|--pool) POOL="${3:-}" ;;
  --hub-global) POOL=""; HUBG=1 ;;
  *) die "usage: fly-envbundle.sh <project> <outdir> [--pool|--hub-global] (got '${3}')" ;;
esac
command -v jq >/dev/null 2>&1 || die "jq required"

# Owning watcher box tailnet IPs (same map fleet auth checks use). The hub pulls
# THIS project's build secrets from its owning box; nothing else's env is touched.
# THE REGISTRY ANSWERS THIS (2026-09-11). This was one of nine copies of the
# same table across bin/ — a box that moved had to be found in all nine, and
# until fleet.conf grew a `tailnet_ip` column it genuinely could not answer.
# Unknown prints nothing and returns 1: callers fail closed rather than ssh
# to `root@`, which hangs instead of erroring.
owning_box_ip() {
  "$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$1" 2>/dev/null
}
BOX=local; SLUG=""
if [ -z "$HUBG" ]; then
  BOX=$(owning_box_ip "$PROJECT") || die "no owning box mapping for $PROJECT"

  # The repo the bundle's GH_TOKEN is minted for, resolved BEFORE the extract
  # (C2): the token is scoped to one repo, so the box has to be told which.
  SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
  case "$SLUG" in */*) ;; *) die "no github repo slug for $PROJECT in fleet.conf — cannot mint the bundle's GH_TOKEN" ;; esac
fi

mkdir -p "$OUTDIR"
chmod 700 "$OUTDIR"

# --- remote extractor: runs on the owning box, prints the whitelisted bundle ---
# We build the two env files' text on the box (where the secrets live) and stream
# it back over ssh; nothing is written to the box disk. GH_TOKEN comes from the
# box's `bin/gh-token.sh --pat` for this project's repo (C2): the box's PLAIN PAT
# (GH_TOKEN, the keyring, env/gh-pat once the keyring is logged out) and NEVER
# the org-admin PAT, which --pat refuses even when it is the inherited GH_TOKEN
# (review round 2 of #2231: a Fly machine running agents must not hold it). Not
# an App token: see the GH_TOKEN note in the whitelist above.
REMOTE_SCRIPT='
. /root/harness/bin/lib/env-path.sh 2>/dev/null || harness_env_dir() { printf "%s\n" /root/harness/env; }; E=$(harness_env_dir)
set -a; . $E/global.env 2>/dev/null; set +a
G=""
for v in CLAUDE_CODE_OAUTH_TOKEN CONSOLE_URL HARNESS_SECRET IS_SANDBOX VERCEL_PLUGIN_TELEMETRY TRIAGE_MODEL; do
  eval "val=\${$v:-}"; [ -n "$val" ] && G="$G$v=$val\n"
done
# The cross-harness ticket lock a build takes (bin/lib/rb/gates.sh, 2026-10-20).
# Its own line: it is not an agent credential, so the lane-run parity check
# (tests/lane-run-agent-clis.bh-6260-test.sh C4) must not count it as one.
for v in LOCKS_URL LOCKS_TOKEN; do
  eval "val=\${$v:-}"; [ -n "$val" ] && G="$G$v=$val\n"
done
# JOBS_URL rides verbatim, an EMPTY value included (BH-1957): a box that set
# `JOBS_URL=` (no coordination DB) hands its machines "not configured" rather
# than letting them fall to the legacy default. No line, nothing bundled.
while IFS= read -r line; do
  case "$line" in RUNNER_*=*|JOBS_URL=*) G="$G$line\n";; esac
done < <(grep -E "^(RUNNER_[A-Z_]+|JOBS_URL)=" $E/global.env 2>/dev/null)
# Tier-3/3b survival lanes (2026-08-02/19): OpenRouter + Fireworks creds ride to builders too.
while IFS= read -r line; do
  case "$line" in OPENROUTER_*=*|FIREWORKS_*=*) G="$G$line\n";; esac
done < <(grep -E "^(OPENROUTER|FIREWORKS)_[A-Z_]+=" $E/global.env 2>/dev/null)
GH=$(/root/harness/bin/gh-token.sh --pat __SLUG__ 2>/dev/null | head -n 1)
[ -n "$GH" ] && G="${G}GH_TOKEN=$GH\n"
printf "===GLOBAL===\n"
printf "$G"
printf "===PROJECT===\n"
cat "$E/__PROJECT__.env" 2>/dev/null
'
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PROJECT__/$PROJECT}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__SLUG__/$SLUG}"

# SSH OFF GUARD (BH-8316, MKF-1). A project whose pool machines pull their
# bundle (machine_pull) needs no ssh extract. The operator then sets the row
# pool.envbundle_ssh.<project> = off, and an ssh extract that still happens is a
# silent fallback to the push path. With the row off this refuses it: 0 ssh
# calls, one ALERTS line, rc 1 (fly-pool.sh unclaims; the job stays queued).
# Read order: the row, then env POOL_ENVBUNDLE_SSH (knob, fly-pool registry)
# when there is no row, then `on`. Only `off` (trimmed, any case) refuses. A
# failed read fails open with one WARN line: a settings outage must not stop
# every spawn. The client loads in a subshell, so a half-synced bin/lib/jobs/
# (its `exit 1`) reads as a failed read, not as a silent exit here.
# envbundle_ssh_read <key> — setting_get's answer and rc; call it in $( ).
envbundle_ssh_read() {
  . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 1
  JOBS_ALERT=0 setting_get "$1" 2>/dev/null
}
envbundle_ssh_guard() {
  local key="pool.envbundle_ssh.$PROJECT" v rc
  v=$(envbundle_ssh_read "$key"); rc=$?
  case "$rc" in
    0) ;;
    # Fallback of the row pool.envbundle_ssh.<project> (knob POOL_ENVBUNDLE_SSH).
    2) v="${POOL_ENVBUNDLE_SSH:-on}" ;;
    *) echo "fly-envbundle/$PROJECT WARN: settings row $key read failed; ssh extract runs as before" >&2; return 0 ;;
  esac
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; v="${v,,}"
  [ "$v" = off ] || return 0
  "$HARNESS/bin/alert-line.sh" --id "envbundle-ssh-off-$PROJECT" --project "$PROJECT" \
    "[fly-envbundle/$PROJECT] push path refused: ssh off (settings row $key=off). A spawn for $PROJECT asked for the ssh env extract from $BOX; its machines must pull the bundle (lane.fly-pool.$PROJECT.machine_pull=1). Check bin/fly-pool-probe-pull.sh $PROJECT, or set the row to on for a secrets re-sync." 2>/dev/null || true
  die "push path refused: ssh off (settings row $key)"
}

# The box's harness is /root/harness; only a local extract (the hub owning the
# project) runs against this process's own HARNESS, which on the hub is the same
# path and in a test is the fixture's.
if [ -n "$HUBG" ]; then
  # The same extractor minus its two non-global lines: the gh-token.sh mint
  # (and the line that appends its answer) and the <project>.env cat.
  HUB_SCRIPT=$(printf '%s\n' "$REMOTE_SCRIPT" | grep -v -e 'gh-token\.sh' -e '^\[ -n "\$GH" \]' -e '^cat "\$E/')
  case "$HUB_SCRIPT" in *gh-token*|*'cat "$E/'*) die "--hub-global could not strip the project lines from the extractor" ;; esac
  RAW=$(bash -c "${HUB_SCRIPT//\/root\/harness/$HARNESS}" 2>/dev/null) || { rc=$?; die "hub global env extract failed (rc $rc)"; }
elif [ "$BOX" = "local" ]; then
  RAW=$(bash -c "${REMOTE_SCRIPT//\/root\/harness/$HARNESS}" 2>/dev/null) || { rc=$?; die "local env extract failed (rc $rc)"; }
else
  envbundle_ssh_guard
  RAW=$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 "root@$BOX" "$REMOTE_SCRIPT" 2>/dev/null) \
    || { rc=$?; die "ssh env extract from $BOX failed (ssh rc $rc)"; }
fi
[ -n "$RAW" ] || die "empty env extract for $PROJECT"

# Split the stream into the two bundle files. The remote already expanded the
# global block's newlines (remote `printf "$G"`), so each var is on its own line
# in RAW between the markers — a straight awk split is correct, no re-expansion.
umask 077
: > "$OUTDIR/global.env"; : > "$OUTDIR/$PROJECT.env"
printf '%s\n' "$RAW" | awk '
  /^===GLOBAL===$/ {mode="g"; next}
  /^===PROJECT===$/ {mode="p"; next}
  { if (mode=="g") print > G; else if (mode=="p") print > P }
' G="$OUTDIR/global.env" P="$OUTDIR/$PROJECT.env"

# --- REPO_SLUG + BASE_BRANCH from fleet.conf on the hub -----------------------
# SLUG was resolved (and required) above, before the extract. --hub-global
# has no project part, so no slug either.
[ -n "$HUBG" ] || echo "REPO_SLUG=$SLUG" >> "$OUTDIR/$PROJECT.env"

# --- the Claude credential mode (BH-9718) -------------------------------------
# Read on the hub, after the extract, so the box's extractor does not change.
# The lib in a subshell: rc 3 = no lib on this hub, which reads `oauth` (the
# rule agent-call.sh uses). Its stderr names the row value, so it is dropped.
# CACHE ONLY: the hub's lanes keep state/settings-cache.json fresh (60 s TTL),
# so the read makes no GET and writes no jobs-client alert. No cache reads
# `oauth`; on the machine agent-call.sh reads the row again and refuses (rc 76)
# a claude call with no key, so a missed row never bills the wrong account.
CAUTH=$( [ -r "$HARNESS/bin/lib/claude-auth.sh" ] || exit 3
         . "$HARNESS/bin/lib/claude-auth.sh" >/dev/null 2>&1 || exit 3
         _lg_settings_refresh() { :; }
         claude_auth_mode "$PROJECT" 2>/dev/null ); CARC=$?
case "$CARC" in
  0) ;;
  3) CAUTH=oauth ;;
  *) rm -f "$OUTDIR/global.env" "$OUTDIR/$PROJECT.env"
     die "settings row claude_auth.$PROJECT is not oauth or api-key; no Claude credential is bundled" ;;
esac
# --- a shared pool app refuses an api-key mode (BH-9783) --------------------
# --hub-global writes the app's HBUNDLE_G_* secrets, which every project that
# names the app boots from. So an api-key project's marker on a shared app
# reaches the oauth projects too. The app is the one state/fly/<p>.json (what
# the sync writes to) or flags/fly-pool-app-<p> names; a project counts when
# either of its two files names the same app.
envbundle_app_of() { # envbundle_app_of <state-json> <flag> -> app names, one per line
  jq -r '.app // empty' "$1" 2>/dev/null | head -n 1 | tr -d '[:space:]'; echo
  head -n 1 "$2" 2>/dev/null | tr -d '[:space:]'; echo
}
if [ -n "$HUBG" ] && [ "$CAUTH" = api-key ]; then
  SAPP=$(envbundle_app_of "$HARNESS/state/fly/$PROJECT.json" "$HARNESS/flags/fly-pool-app-$PROJECT" | grep -m1 .)
  if [ -n "$SAPP" ]; then
    SHARED=$(
      for f in "$HARNESS"/state/fly/*.json "$HARNESS"/flags/fly-pool-app-*; do
        [ -f "$f" ] || continue
        case "$f" in *-active.json) continue ;; */state/fly/*) q="${f##*/}"; q="${q%.json}" ;; *) q="${f##*/fly-pool-app-}" ;; esac
        [[ "$q" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        # Not grep -q: it closes the pipe early, and pipefail reads that as a miss.
        envbundle_app_of "$HARNESS/state/fly/$q.json" "$HARNESS/flags/fly-pool-app-$q" | grep -xF -- "$SAPP" >/dev/null && printf '%s\n' "$q"
      done | sort -u | tr '\n' ' ')
    SHARED="${SHARED% }"
    if [ "$(wc -w <<<"$SHARED")" -gt 1 ]; then
      rm -f "$OUTDIR/global.env" "$OUTDIR/$PROJECT.env"
      die "--hub-global: pool app $SAPP is named by more than one project ($SHARED); claude_auth.$PROJECT is api-key, and its CLAUDE_AUTH_MODE=api-key in the app's HBUNDLE_G_* secrets would reach every one of them. Give $PROJECT its own pool app."
    fi
  fi
fi
if [ "$CAUTH" = api-key ]; then
  # Replace, never append: the builder sources global.env, so a second line wins.
  { grep -v -e '^CLAUDE_CODE_OAUTH_TOKEN=' -e '^ANTHROPIC_API_KEY=' -e '^CLAUDE_AUTH_MODE=' "$OUTDIR/global.env"
    printf 'CLAUDE_AUTH_MODE=api-key\n'; } > "$OUTDIR/global.env.new" 2>/dev/null \
    && mv "$OUTDIR/global.env.new" "$OUTDIR/global.env" 2>/dev/null
  rm -f "$OUTDIR/global.env.new" 2>/dev/null
fi

# Sanity: the two things a real build cannot proceed without.
if [ "$CAUTH" = api-key ]; then
  grep -qx 'CLAUDE_AUTH_MODE=api-key' "$OUTDIR/global.env" 2>/dev/null || die "bundle missing the api-key marker CLAUDE_AUTH_MODE=api-key"
  ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$OUTDIR/global.env" 2>/dev/null || die "api-key bundle still carries CLAUDE_CODE_OAUTH_TOKEN"
else
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$OUTDIR/global.env" 2>/dev/null || die "bundle missing CLAUDE_CODE_OAUTH_TOKEN"
fi
# GH_TOKEN is only required here for fly-dispatch, which ships the bundle as-is.
# The pool swaps the line for a builders-App token when this hub is armed, so a
# --pool bundle with no PAT warns and ships (BH-4798; the header has the why).
if [ -z "$HUBG" ] && ! grep -q '^GH_TOKEN=' "$OUTDIR/global.env" 2>/dev/null; then
  NOPAT="bin/gh-token.sh --pat $SLUG printed nothing on $BOX — that box has no PAT for the builder (GH_TOKEN in env/global.env, or env/gh-pat once its keyring is logged out)"
  [ -n "$POOL" ] || die "bundle missing GH_TOKEN: $NOPAT"
  # shellcheck source=bin/lib/gh-app-auth.sh
  [ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
  if command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed; then
    echo "fly-envbundle/$PROJECT WARN: bundle has no GH_TOKEN (bin/gh-token.sh --pat $SLUG printed nothing on $BOX); the pool route swaps in a builders-App token, so the bundle ships without the PAT. fly-dispatch still needs one: put it in env/gh-pat on $BOX." >&2
  else
    die "bundle missing GH_TOKEN: $NOPAT (and this hub is not armed for App tokens, so the pool cannot swap one in)"
  fi
fi

chmod 600 "$OUTDIR/global.env" "$OUTDIR/$PROJECT.env" 2>/dev/null || true
# Where this bundle came from, one non-secret line (BH-10141). bin/fly-pool.sh
# names it in its default-token line next to the token's fingerprint. Not one
# of the two env files, so stdout and every caller that reads them are unchanged.
if [ -n "$HUBG" ]; then BSRC="hub env/global.env"
elif [ "$BOX" = local ]; then BSRC="local env/global.env"
else BSRC="env/global.env on root@$BOX"; fi
printf '%s\n' "$BSRC" > "$OUTDIR/bundle-source" 2>/dev/null && chmod 600 "$OUTDIR/bundle-source" 2>/dev/null || true
echo "$OUTDIR/global.env $OUTDIR/$PROJECT.env"
