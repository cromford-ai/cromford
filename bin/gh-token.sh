#!/bin/bash
# bin/gh-token.sh <owner/repo> — print a SHORT-LIVED GitHub App installation
# token scoped to that one repo. Also:
#   gh-token.sh --status [--json]
#                          REST and GraphQL remaining/limit and reset time for
#                          EVERY token this box holds — one row per App cache
#                          file, one for the default PAT, one for the admin PAT,
#                          deduped by token value (BH-426)
#   gh-token.sh --warm     refresh the cache for every repo fleet.conf names
#   gh-token.sh --read <owner/repo>   a token for a READ-ONLY call (see below)
#
# THE WALL THIS REMOVES (the operator, 2026-09-14, "every throughput ceiling is a bug").
# Today every lane, every box and every pool machine authenticates GitHub with
# ONE personal access token — GH_TOKEN out of env/global.env, GH_ADMIN_TOKEN out
# of env/github-admin.env for the repos the default one cannot see. A PAT gets
# 5000 REST requests an hour for the whole account, so 4000 builder machines
# share one 5000/h bucket: the fleet hits the ceiling long before it runs out of
# work, and the symptom is a 403 in a lane that has no idea why. A GitHub App
# gets 5000/h PER INSTALLATION and scales with the installation's repo count, and
# an installation token dies in an hour — so a leaked builder token is an hour of
# one repo, not the fleet's whole GitHub identity forever.
#
# WHAT IT DOES. Signs an RS256 JWT with the App's private key using openssl
# (no new dependency — openssl is already on every box for the same reason git
# is), asks GitHub for that owner's installation id if env does not name it,
# exchanges the JWT for an installation token at
# POST /app/installations/{id}/access_tokens with `repositories:[<repo>]` so the
# token can see ONE repo, and caches it in state/gh-app-tokens/<owner>-<repo>.json
# until 5 minutes before it expires.
#
# THE FALLBACK IS TODAY, BYTE FOR BYTE. With env/github-app.env absent, with
# GH_APP_TOKENS=0, or with flags/gh-app-tokens-off present (or the
# `switch.gh-app-tokens-off` settings row on), this script prints
# the PAT the fleet uses right now and nothing else changes: the admin token for
# a repo only that one can see (the bin/lib/gh-repo-token.sh answer, not a second
# copy of it), otherwise GH_TOKEN, otherwise `gh auth token`. So a box that has
# not been set up yet, or one where the operator flips the flag, behaves exactly as it
# did on 2026-09-13.
#
# `--read <owner/repo>` (or GH_TOKEN_READ=1) IS THE ONE EXCEPTION, and only for
# READS (2026-09-14, collaborator-1's project-2 PRs). The project-2 box's PAT answers
# 403 on actions/runs, check-runs, commits/status and the statusCheckRollup
# GraphQL, so bin/review-prs.sh could not tell green CI from no CI and deferred
# three approved PRs for days; an App installation token reads the same endpoint
# fine. GH_APP_TOKENS=0 and flags/gh-app-tokens-off guard WRITES and AUTHORSHIP
# — who pushes, who opens the PR, whose identity lands on a commit — and none of
# that is at stake in a GET of a workflow-run list, so --read ignores those two
# switches. It ignores NOTHING else: with no App credentials at all (no
# GH_APP_ID, no readable key, no openssl) it prints the PAT exactly as every
# other invocation does, and the pool's GH_APP_ROTATE / flags/gh-app-rotate-off
# semantics live in bin/fly-pool.sh and are untouched by this mode.
#
# THE LOCK IS DEDUPE, NOT A QUEUE (the operator, 2026-09-13 — "we never lock and
# serialize"). Two lanes asking for the same repo's token in the same second
# should buy ONE token, so the mint holds flock for the ~1s it takes and
# re-reads the cache on the way in. It waits at most 5 seconds and then mints
# anyway: a slow token is a bug, a build that blocks on a token is a worse one.
#
# A CALLER CAN ASK FOR A MINIMUM LIFE (2026-09-14, the TK-680 push rejection).
# An installation token lives exactly one hour and the cache hands it out until 5
# minutes before that, which is right for a lane that spends its token in
# seconds and wrong for a POOL BUILD that runs 40-75 minutes: TK-680/681/682
# were spawned 13:29Z on a token minted 12:42Z and their pre-PR push at 13:53Z
# answered "Invalid username or token", throwing the whole build away. So
# `--min-life <sec>` (or `--fresh`) says how much life the caller actually needs;
# a cached token with less than that is treated as stale and a new one is minted
# and cached in its place. The default is the 300s this script has always used,
# so a caller that asks for nothing gets exactly today's answer.
#
# `--expires-at <owner/repo>` prints the cached token's expiry and nothing else.
# It exists so bin/fly-pool.sh can record on each machine record WHEN the token it
# shipped dies, and decide about rotation later without a second API call — the
# cache filename is derived here and a second copy of that derivation elsewhere
# would drift.
#
# `--app <profile>` MINTS FROM ANOTHER GITHUB APP (BH-1578, 2026-09-23). The
# Fly builders spent the hub App's 6,600/h installation bucket — every pool
# machine's token was minted here, as the hub — and drained it in the hour the
# merge lanes needed it. So a second App (cromford-builders) is a PROFILE:
# `--app builders` (or GH_APP_PROFILE=builders) reads env/github-app-builders.env
# INSTEAD of env/github-app.env — never on top of it, so no hub
# GH_APP_INSTALLATION_<OWNER> can leak into a builders mint — and keeps its own
# token cache (state/gh-app-tokens-builders/), its own installation cache and
# its own locks, so a hub lane and a builder mint never share an entry or a
# bucket. No profile, or `--app hub`, is byte-for-byte today's path. A profile
# whose env file is absent answers from the hub App with one stderr line: a
# caller is never worse off than before the profile existed. bin/fly-pool.sh is
# the caller and decides WHICH profile from a settings knob (POOL_GH_APP_PROFILE).
#
# `--app-hook` prints the App's OWN webhook as `<url>\t<events,csv>` (pool
# doctor, 2026-09-24): GET /app/hook/config and GET /app, both on the JWT. An App
# with no webhook answers an empty url, rc 0; rc 1 means the App could not be
# asked at all. bin/doorbell-coverage-check.sh reads it, because an App-level
# webhook rings for every repo the installation covers and no installation
# token can list a repo's hooks without the Webhooks permission — which is why
# the doorbell used to ask for a PAT. A GET, so the write kill switches do not
# apply (the --read rule).
#
# `--app-slug` prints the App's own slug (BH-9287): GET /app on the JWT,
# `.slug`, one line, rc 0. rc 1 and NOTHING printed when the App is not
# configured, jq is missing or GitHub sends no slug, so a caller never names
# an App it did not hear from. With `--app <profile>` it asks that profile's
# App. A GET (the --read rule): the write kill switches do not apply, and no
# token cache or lock is touched. bin/lib/verdict-status.sh (vs_app_name)
# reads it to name the App in the conductor's status-unpublished alert.
#
# `--installation-id <owner/repo>` prints the installation the cached token was
# minted on, the way --expires-at prints its expiry: bin/fly-pool.sh ships it in
# the bundle so the #1484 ledger on a builder can name the bucket it spends.
#
# `--extra-read <csv> <owner/repo>` MINTS A SECOND, READ-ONLY TOKEN (BH-5910). A
# pool token sees one repo, so a plan that copies code from a sibling repo got
# "Repository not found" on the builder. This token lists the project repo plus
# each extra repo, with `permissions:{contents:read, metadata:read}`. GitHub
# applies a token's permissions to every repo in it, so the project's own token
# is NOT this one: `gh-token.sh <owner/repo>` is unchanged and never reads the
# list. An extra repo the installation does not cover would make the whole mint
# answer 422, so each one is checked first (GET /repos/<repo>/installation on the
# JWT); a missing one is one `EXTRA_READ_REPO_MISSING <repo>` line on stderr and
# in logs/gh-rate.log, and the mint goes ahead without it. Comma or space
# separated, at most 10. Nothing left, unarmed, killed or a failed mint: rc 1 and
# NO output. Never the PAT and never the hub retry: either one would hand a
# builder a wider credential than the one it asked for. bin/fly-pool.sh is the
# caller (knob EXTRA_READ_REPOS, settings row lane.fly-pool.<project>.extra_read_repos).
#
# NO TOKEN VALUE EVER REACHES A LOG, A COMMENT OR AN ALERT. The cache files are
# mode 600 under state/, the key is read by name from env/ (mode 600, never
# committed), and logs/gh-rate.log carries counts only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-$(cd "$HERE/.." && pwd)}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# BH-2646: mint() reports each mint's health. Guarded, so a bin/lib/ that
# predates the lib still mints; the reporter is fail-open and never prints.
{ [ -r "$HERE/lib/token-health.sh" ] && . "$HERE/lib/token-health.sh"; } || token_health_report() { :; }
APIB="${GH_APP_API_BASE:-https://api.github.com}"
# How much life a cached token must still have to be handed out. 300s is what
# this script has always used and is still the default; `--min-life`/`--fresh`
# raise it for one call (see the header).
MIN_LIFE=300
CACHE="$H/state/gh-app-tokens"
INSTCACHE="$H/state/gh-app-installations.json"
RATELOG="$H/logs/gh-rate.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
warn() { echo "gh-token: $*" >&2; }

# --- configuration ------------------------------------------------------------
# env/github-app.env is sourced, not parsed: it is an env file like every other
# one in env/, and GH_APP_PRIVATE_KEY_FILE is a path, not a secret.
#
# THE PROFILE IS READ FIRST (BH-1578), because it decides which env file, cache
# and lock names everything below uses. It comes from `--app <name>` anywhere in
# the option run, or GH_APP_PROFILE. The name becomes part of a path, so it is
# held to [a-z0-9-]; anything else is a usage error, never a path.
GH_APP_PROFILE="${GH_APP_PROFILE:-}"
ORIG_ARGS=("$@")
_prev=""
for _a in "$@"; do
  case "$_prev" in --app) GH_APP_PROFILE="$_a" ;; esac
  case "$_a" in --app=*) GH_APP_PROFILE="${_a#--app=}" ;; esac
  _prev="$_a"
done
unset _a _prev
case "$GH_APP_PROFILE" in
  hub) GH_APP_PROFILE="" ;;
  *[!a-z0-9-]*) echo "gh-token: App profile '$GH_APP_PROFILE' is not [a-z0-9-]" >&2; exit 2 ;;
esac
if [ -n "$GH_APP_PROFILE" ] && [ ! -r "$HENV/github-app-$GH_APP_PROFILE.env" ]; then
  warn "App profile '$GH_APP_PROFILE': $HENV/github-app-$GH_APP_PROFILE.env is absent — answering from the hub App"
  GH_APP_PROFILE=""
fi
APPENV="$HENV/github-app.env"
if [ -n "$GH_APP_PROFILE" ]; then
  # A profile's App is ONLY what its own file says. The hub's id, key and owner
  # installations may already be in this process's environment (a caller that
  # sourced env/github-app.env); a builders JWT sent to a hub installation id is
  # a 404 and a PAT fallback, so none of them survive into a profile mint.
  APPENV="$HENV/github-app-$GH_APP_PROFILE.env"
  unset GH_APP_ID GH_APP_PRIVATE_KEY_FILE
  for _v in $(compgen -v GH_APP_INSTALLATION_); do unset "$_v"; done; unset _v
  CACHE="$CACHE-$GH_APP_PROFILE"
  INSTCACHE="${INSTCACHE%.json}-$GH_APP_PROFILE.json"
fi
if [ -r "$APPENV" ]; then set -a; # shellcheck disable=SC1090,SC1091
  . "$APPENV"; set +a; fi
# THE HUB FILE'S KILL SWITCH COVERS EVERY PROFILE (#1590 review I2). A profile
# does not source env/github-app.env, so `GH_APP_TOKENS=0` written there — the
# switch an operator reaches for — would stop the hub and leave the builders
# minting. Read by name, never sourced: nothing else of the hub's may leak in.
if [ -n "$GH_APP_PROFILE" ] && [ "$(sed -n 's/^\(export \)\{0,1\}GH_APP_TOKENS=//p' "$HENV/github-app.env" 2>/dev/null \
      | tr -d "\"' " | tail -n 1)" = 0 ]; then
  GH_APP_TOKENS=0
fi
GH_APP_ID="${GH_APP_ID:-}"
GH_APP_PRIVATE_KEY_FILE="${GH_APP_PRIVATE_KEY_FILE:-$HENV/github-app${GH_APP_PROFILE:+-$GH_APP_PROFILE}.pem}"

# READ_ONLY — set by --read / GH_TOKEN_READ=1. The caller is about to spend the
# token on a GET, so the two WRITE kill switches do not apply to it (header).
READ_ONLY=0
[ "${GH_TOKEN_READ:-0}" = 1 ] && READ_ONLY=1

# armed — is this box minting App tokens at all? Three independent offs, because
# the flag file needs no deploy and the env var needs no file. The first two are
# the write/authorship guards and a read-only call skips them; the credential
# checks below are absolute and no mode bypasses them.
# killed — one of the two WRITE kill switches is on (and this is not a read).
# Split out of armed() so a profile can tell "switched off" (answer the PAT, as
# the hub would) from "cannot mint" (ask the hub App, see hub_retry).
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
killed() {
  [ "$READ_ONLY" != 1 ] || return 1
  HARNESS="$H" lane_switch gh-app-tokens-off && return 0
  [ "${GH_APP_TOKENS:-1}" = 0 ] && return 0
  return 1
}
armed() {
  killed && return 1
  [ -n "$GH_APP_ID" ] || return 1
  [ -r "$GH_APP_PRIVATE_KEY_FILE" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  return 0
}

# --- the fallback: exactly the PAT the fleet resolves today --------------------
# bin/lib/gh-repo-token.sh is the ONE answer to "which PAT can see this repo"
# (2026-09-12, the project-5 loss). Sourced, never re-implemented: a second copy
# that drifted would route a repo to a token that 404s and log nothing.
pat_for() { # pat_for <owner/repo> -> the PAT string, or nothing
  local slug="$1" tok=""
  # THE QUESTION HERE IS PAT-ONLY, AND IT HAS TO BE (BH-765). Since the lib's
  # ladder tries an App installation token first, and that rung mints one by
  # running THIS script, an unguarded ask would be: caller -> gh-token.sh (mint
  # fails) -> pat_for -> lib -> App rung -> gh-token.sh -> … until the box runs
  # out of pids. `_GHRT_NO_APP` is the lib's own "answer the PAT question only"
  # switch; the lib passes it into every mint it makes, and this is the other
  # direction of the same cycle.
  local _GHRT_NO_APP=1
  if [ -r "$H/bin/lib/gh-repo-token.sh" ]; then
    # shellcheck source=bin/lib/gh-repo-token.sh
    . "$H/bin/lib/gh-repo-token.sh"
    if gh_repo_use_token "$slug" >/dev/null 2>&1; then tok="${GH_TOKEN:-}"; fi
  fi
  [ -n "$tok" ] || tok="${GH_TOKEN:-}"
  [ -n "$tok" ] || tok=$(gh auth token 2>/dev/null)
  # C2: a box whose keyring was logged out (bin/ensure-box-gh-app-default.sh)
  # keeps its PAT in env/gh-pat, read by name only — the same file the ledger
  # shim's GH_USE_PAT escape reads. Absent file: nothing, as before.
  if [ -z "$tok" ] && [ -r "$HENV/gh-pat" ]; then
    tok=$(sed -e '/^[[:space:]]*#/d' -e 's/^export //' -e 's/^GH_TOKEN=//' -e 's/^GH_PAT=//' "$HENV/gh-pat" 2>/dev/null \
          | tr -d "\"' \t\r" | sed -n '/./{p;q;}')
  fi
  printf '%s' "$tok"
}

# plain_pat -> the box's PLAIN PAT for --pat, or nothing (review round 2 of
# #2231, security). --pat's answer is shipped whole into long-lived Fly bundles
# (bin/fly-envbundle.sh), so it is NEVER the lib's ladder: that ladder ends in
# the org-admin rung, and on a logged-out box with no GH_TOKEN it reached admin
# before env/gh-pat and the admin PAT went into a bundle. Only three sources,
# in order: GH_TOKEN, the gh keyring, env/gh-pat. A value that IS the admin PAT
# (a caller that exported the admin rung) or an App installation token (ghs_,
# an hour of life, not a PAT) is skipped, never printed. github-admin.env is
# read for that comparison only.
plain_pat() {
  local adm tok c
  adm=$(_admin_pat)
  for c in env keyring file; do
    case "$c" in
      env)     tok="${GH_TOKEN:-}" ;;
      keyring) tok=$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null) ;;
      file)    tok=""
               [ -r "$HENV/gh-pat" ] && tok=$(sed -e '/^[[:space:]]*#/d' -e 's/^export //' -e 's/^GH_TOKEN=//' -e 's/^GH_PAT=//' "$HENV/gh-pat" 2>/dev/null \
                 | tr -d "\"' \t\r" | sed -n '/./{p;q;}') ;;
    esac
    [ -n "$tok" ] || continue
    [ -n "$adm" ] && [ "$tok" = "$adm" ] && continue
    case "$tok" in ghs_*) continue ;; esac
    printf '%s' "$tok"; return 0
  done
  return 1
}

# --- JWT (RS256, openssl) -----------------------------------------------------
# Base64url with no padding, which is what a JWS needs and what `openssl base64`
# does not give you on its own.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
app_jwt() {
  local now hdr pay si sig
  now=$(date +%s)
  # iat is backdated 60s because GitHub rejects a JWT whose iat is in ITS future
  # and the two clocks are never identical; exp is 9 minutes, one under the
  # 10-minute maximum, for the same reason.
  hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  pay=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now-60))" "$((now+540))" "$GH_APP_ID" | b64url)
  si="$hdr.$pay"
  sig=$(printf '%s' "$si" | openssl dgst -sha256 -sign "$GH_APP_PRIVATE_KEY_FILE" 2>/dev/null | b64url) || return 1
  [ -n "$sig" ] || return 1
  printf '%s.%s' "$si" "$sig"
}

api_jwt() { # api_jwt <method> <path> [body]
  local m="$1" p="$2" body="${3:-}" jwt
  jwt=$(app_jwt) || return 1
  if [ -n "$body" ]; then
    curl -sS -m 10 -X "$m" -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" -d "$body" "$APIB$p" 2>/dev/null
  else
    curl -sS -m 10 -X "$m" -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
      "$APIB$p" 2>/dev/null
  fi
}

# --- installation id ----------------------------------------------------------
# env wins (GH_APP_INSTALLATION_<OWNER>, owner upper-cased with - and . as _),
# then the discovery cache, then GET /app/installations. The cache exists so a
# box that lists installations once never lists them again: that call is billed
# against the App's own 5000/h, same as everything else.
_owner_var() { printf 'GH_APP_INSTALLATION_%s' "$(printf '%s' "$1" | tr 'a-z.-' 'A-Z__')"; }
install_id() { # install_id <owner> -> id on stdout
  local owner="$1" lc var id rows
  lc=$(printf '%s' "$owner" | tr 'A-Z' 'a-z')
  var=$(_owner_var "$owner"); id="${!var:-}"
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  id=$(jq -r --arg o "$lc" '.[$o] // empty' "$INSTCACHE" 2>/dev/null)
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  rows=$(api_jwt GET /app/installations) || return 1
  id=$(printf '%s' "$rows" | jq -r --arg o "$lc" \
        'if type=="array" then (.[] | select((.account.login // "" | ascii_downcase)==$o) | .id) else empty end' 2>/dev/null | head -n 1)
  [ -n "$id" ] || return 1
  mkdir -p "$H/state" 2>/dev/null
  # Merge rather than overwrite: two owners on one box must both survive. A
  # corrupt cache is replaced, not appended to — jq answers {} for it.
  local prev; prev=$(jq -c '.' "$INSTCACHE" 2>/dev/null) || prev=""
  case "$prev" in '{'*) ;; *) prev='{}' ;; esac
  jq -n --argjson old "$prev" --arg o "$lc" --arg i "$id" '$old + {($o): $i}' \
    > "$INSTCACHE.tmp" 2>/dev/null && mv "$INSTCACHE.tmp" "$INSTCACHE" 2>/dev/null
  printf '%s' "$id"
}

# --- rate visibility ----------------------------------------------------------
# One line per MINT, never per use: a cached token answers with no request at
# all, so a line here means the fleet actually spent a round-trip. Counts only.
rate_log() { # rate_log <owner/repo> <token>
  local slug="$1" tok="$2" js rem lim
  js=$(curl -sS -m 10 -H "Authorization: token $tok" -H "Accept: application/vnd.github+json" \
        "$APIB/rate_limit" 2>/dev/null)
  rem=$(printf '%s' "$js" | jq -r '.rate.remaining // empty' 2>/dev/null)
  lim=$(printf '%s' "$js" | jq -r '.rate.limit // empty' 2>/dev/null)
  mkdir -p "$H/logs" 2>/dev/null
  echo "$(STAMP) gh-rate $slug remaining=${rem:-?}/${lim:-?}" >> "$RATELOG"
}

# --- cache --------------------------------------------------------------------
cache_file() { printf '%s/%s.json' "$CACHE" "$(printf '%s' "${1//\//-}" | tr -c 'A-Za-z0-9._-' '_')"; }
# A cached token is good until 5 minutes before expiry. Anything unparseable
# reads as expired: a mint is cheap, a 401 halfway through a push is not.
cache_read() { # cache_read <owner/repo> -> token on stdout, rc 1 when it has less
               # than MIN_LIFE seconds left, or is absent/unparseable
  local f exp now tok
  f=$(cache_file "$1"); [ -s "$f" ] || return 1
  tok=$(jq -r '.token // empty' "$f" 2>/dev/null); [ -n "$tok" ] || return 1
  exp=$(jq -r '.expires_at // empty' "$f" 2>/dev/null)
  [ -n "$exp" ] || return 1
  exp=$(date -u -d "$exp" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  [ "$((exp - now))" -gt "$MIN_LIFE" ] || return 1
  printf '%s' "$tok"
}
# `installation_id` is the 4th argument and it is ADDITIVE (BH-1509 S-10): the
# fleet spends from one 6,600/h bucket PER INSTALLATION, and
# bin/lib/gh-rest-ledger.sh keys its quota reading `app-<installation id>` by
# matching GH_TOKEN against these rows. A row written before this change has no
# such field, so every reader asks for it with `// empty` and gets the legacy
# flat `app` bucket until the next mint (an hour at most).
cache_write() { # cache_write <owner/repo> <token> <expires_at> [installation_id]
  local f; f=$(cache_file "$1")
  mkdir -p "$CACHE" 2>/dev/null; chmod 700 "$CACHE" 2>/dev/null
  ( umask 077
    jq -n --arg t "$2" --arg e "$3" --arg s "$1" --arg m "$(STAMP)" --arg i "${4:-}" \
      '{repo:$s,token:$t,expires_at:$e,minted_at:$m}
       + (if $i == "" then {} else {installation_id:$i} end)' > "$f.tmp" ) 2>/dev/null || return 1
  mv "$f.tmp" "$f" 2>/dev/null && chmod 600 "$f" 2>/dev/null
}

# The cached token's expiry, for a caller that has to know WHEN rather than WHAT.
# Empty (rc 1) when nothing is cached: an absent expiry must never read as "soon".
cache_expires_at() { # cache_expires_at <owner/repo> -> RFC3339 on stdout
  local f exp; f=$(cache_file "$1"); [ -s "$f" ] || return 1
  exp=$(jq -r '.expires_at // empty' "$f" 2>/dev/null); [ -n "$exp" ] || return 1
  printf '%s' "$exp"
}

# The installation the cached token was minted on (BH-1578), digits only, for
# the same reason as --expires-at: bin/fly-pool.sh records it without a second
# API call. Empty (rc 1) for a row written before BH-1509, or no row at all.
cache_installation_id() { # cache_installation_id <owner/repo> -> id on stdout
  local f id; f=$(cache_file "$1"); [ -s "$f" ] || return 1
  id=$(jq -r '.installation_id // empty' "$f" 2>/dev/null)
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$id"
}

mint() { # mint <owner/repo> -> token on stdout
  local slug="$1" owner repo id js tok exp
  owner="${slug%%/*}"; repo="${slug#*/}"
  id=$(install_id "$owner") || { warn "no installation id for $owner"
    token_health_report gh_app "app-unresolved-$owner" fail "" "no installation id" >/dev/null 2>&1; return 1; }
  js=$(api_jwt POST "/app/installations/$id/access_tokens" \
        "$(jq -nc --arg r "$repo" '{repositories:[$r]}')") || {
    token_health_report gh_app "app-$id" fail "" "access_tokens request failed" >/dev/null 2>&1; return 1; }
  tok=$(printf '%s' "$js" | jq -r '.token // empty' 2>/dev/null)
  exp=$(printf '%s' "$js" | jq -r '.expires_at // empty' 2>/dev/null)
  [ -n "$tok" ] && [ -n "$exp" ] || { warn "$slug: access_tokens returned no token"
    token_health_report gh_app "app-$id" fail "" "access_tokens returned no token" >/dev/null 2>&1; return 1; }
  cache_write "$slug" "$tok" "$exp" "$id" || warn "$slug: token minted but not cached"
  token_health_report gh_app "app-$id" ok "$exp" >/dev/null 2>&1
  rate_log "$slug" "$tok"
  printf '%s' "$tok"
}

token_for() { # token_for <owner/repo> -> token on stdout (cache, then mint)
  local slug="$1" tok lf
  tok=$(cache_read "$slug") && { printf '%s' "$tok"; return 0; }
  mkdir -p "$H/locks" 2>/dev/null
  lf="$H/locks/gh-app-token${GH_APP_PROFILE:+-$GH_APP_PROFILE}-$(basename "$(cache_file "$slug")" .json).lock"
  # Testing writability BEFORE `exec 8>` on purpose: a failed exec redirection
  # prints its own error line that `2>/dev/null` on the exec cannot suppress, and
  # a lock we cannot take is not a reason to refuse a token.
  { : > "$lf"; } 2>/dev/null || { mint "$slug"; return $?; }
  exec 8>"$lf"
  flock -w 5 8 2>/dev/null || true
  tok=$(cache_read "$slug") && { exec 8>&-; printf '%s' "$tok"; return 0; }
  tok=$(mint "$slug"); local rc=$?
  exec 8>&-
  [ "$rc" = 0 ] || return "$rc"
  printf '%s' "$tok"
}

# --- subcommands --------------------------------------------------------------
# WHAT --status REPORTS, AND WHY BOTH BUCKETS (BH-426). "Nothing in fleet_status
# shows how much of either budget is left" — GitHub meters REST and GraphQL
# SEPARATELY, and the merge path spends both, so a gauge that reports one number
# is a gauge that can read healthy while the lane that is actually failing has
# nothing left. Every token this box holds gets one row carrying both buckets and
# both reset times, and `--json` is the machine-readable form bin/lib/gh-quota.sh
# pushes into the snapshot.
#
# rate_row <json> -> one TSV line:
#   <rest_rem> <rest_lim> <rest_reset> <gql_rem> <gql_lim> <gql_reset> <rest_unreadable> <gql_unreadable>
# GitHub's /rate_limit answers with a top-level `.rate` object (deprecated) and a
# `.resources` map; on this installation only the second is populated, which is
# why every --status line once read `?/?` (BH-470). A bucket that did not parse is
# reported as 0/0 WITH its unreadable flag set — never as `?`, and never as
# headroom: the flag is what says which of "no answer" and a genuine
# `remaining: 0` this row is, and a genuine 0 is real news.
rate_row() {
  printf '%s' "$1" | jq -r '
    def bucket($o): if ($o|type) == "object"
                       and (($o.remaining|type) == "number")
                       and (($o.limit|type) == "number")
                    then $o else null end;
    bucket(.resources.core // .rate // null) as $c |
    bucket(.resources.graphql // null)       as $g |
    [ ($c.remaining // 0), ($c.limit // 0),
      (if ($c.reset|type) == "number" then $c.reset else 0 end),
      ($g.remaining // 0), ($g.limit // 0),
      (if ($g.reset|type) == "number" then $g.reset else 0 end),
      (if $c == null then 1 else 0 end),
      (if $g == null then 1 else 0 end) ] | @tsv' 2>/dev/null
}

# iso_of <epoch> -> RFC3339 UTC, or NOTHING for a missing/zero/unparseable reset.
# Empty is the unknown answer all the way out to the payload (null there, `-` in
# the text line): a reset time we do not have must never be printed as an epoch-0
# timestamp in 1970, which reads as "reset long ago, plenty left".
iso_of() {
  case "${1:-}" in ''|0|*[!0-9]*) return 0 ;; esac
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true
}

# _status_fp <token> -> 12 hex of its sha256, for DEDUPE only. The admin PAT is
# very often the same string as the default one, and the bucket belongs to the
# token, not to the name we call it by — so two names for one value is ONE row.
# The value itself never reaches a comparison that gets printed, a filename or a
# log; only the fingerprint does, and that only in memory.
_status_fp() { printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}' | cut -c1-12; }

# _admin_pat -> GH_ADMIN_TOKEN, read BY NAME out of env/github-admin.env exactly
# as bin/lib/gh-repo-token.sh:94 reads it. Sourcing that lib here is not an
# option (see pat_for's note: its App rung re-enters this script), so the one sed
# is repeated rather than the file.
_admin_pat() {
  sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$HENV/github-admin.env" 2>/dev/null \
    | tr -d "\"' \t\r" | head -n 1
}

# _status_gql <token> -> "<remaining>\t<limit>\t<reset>\t<used>" from the
# X-RateLimit-* headers of ONE GraphQL request, or nothing (BH-1574).
#
# WHY NOT /rate_limit. Its `resources.graphql` answered used=0 remaining=5000 on
# the hub while a `gh pr list` on the same token, the same minute, came back with
# X-RateLimit-Used: 80 (2026-09-23). A gauge that reads 0 used while the bucket
# is spending is the gauge that never warns. So the GraphQL numbers come from a
# GraphQL response's own headers, and only when those headers say
# `x-ratelimit-resource: graphql` — anything else (no headers, a REST answer, an
# error page) prints nothing and the caller keeps /rate_limit as the fallback.
# The query asks for nothing but rateLimit: the cheapest GraphQL request there is.
_status_gql() {
  local hdr
  hdr=$(curl -sS -m 5 -o /dev/null -D - -X POST \
          -H "Authorization: token $1" -H "Content-Type: application/json" \
          --data '{"query":"query{rateLimit{used}}"}' "$APIB/graphql" 2>/dev/null) || return 0
  printf '%s\n' "$hdr" | awk '
    { line = $0; sub(/\r$/, "", line)
      k = line; sub(/:.*/, "", k); k = tolower(k)
      v = line; sub(/^[^:]*:[ \t]*/, "", v)
      if (k == "x-ratelimit-remaining") r = v
      else if (k == "x-ratelimit-limit") l = v
      else if (k == "x-ratelimit-reset") t = v
      else if (k == "x-ratelimit-used") u = v
      else if (k == "x-ratelimit-resource") s = tolower(v) }
    END { if (s == "graphql" && r ~ /^[0-9]+$/ && l ~ /^[0-9]+$/)
            printf "%s\t%s\t%s\t%s\n", r, l, (t ~ /^[0-9]+$/ ? t : 0), (u ~ /^[0-9]+$/ ? u : "") }'
}

do_status() { # do_status [--json]
  local mode=text
  [ "${1:-}" = --json ] && mode=json
  local -a S_ID=() S_KIND=() S_SLUG=() S_TOK=() S_EXP=() S_OUT=() S_CRED=()
  local seen=" " f slug exp tok fp iid
  # One row per App cache file, identified by the repo it was minted for.
  if [ -d "$CACHE" ]; then
    for f in "$CACHE"/*.json; do
      [ -s "$f" ] || continue
      tok=$(jq -r '.token // empty' "$f" 2>/dev/null); [ -n "$tok" ] || continue
      slug=$(jq -r '.repo // "?"' "$f" 2>/dev/null)
      exp=$(jq -r '.expires_at // empty' "$f" 2>/dev/null)
      fp=$(_status_fp "$tok")
      case "$seen" in *" $fp "*) continue ;; esac
      seen="$seen$fp "
      S_ID+=("$slug"); S_KIND+=(app); S_SLUG+=("$slug"); S_TOK+=("$tok"); S_EXP+=("$exp")
      # BH-4717.2: the quota bucket is the INSTALLATION, so every repo minted from
      # it shares one credential. A cache with no id keys on its own repo.
      iid=$(jq -r '.installation_id // empty' "$f" 2>/dev/null)
      case "$iid" in ''|*[!0-9]*) S_CRED+=("app:$slug") ;; *) S_CRED+=("app-installation:$iid") ;; esac
    done
  fi
  # Then the PATs this box can hold, in the order a lane resolves them. App rows
  # come FIRST so that a PAT which happens to equal an installation token keeps
  # the more specific identity.
  local dpat apat
  dpat="${GH_TOKEN:-}"; [ -n "$dpat" ] || dpat=$(gh auth token 2>/dev/null)
  apat=$(_admin_pat)
  if [ -n "$dpat" ]; then
    fp=$(_status_fp "$dpat")
    case "$seen" in *" $fp "*) ;; *)
      seen="$seen$fp "
      S_ID+=("pat:default"); S_KIND+=(pat); S_SLUG+=(""); S_TOK+=("$dpat"); S_EXP+=(""); S_CRED+=("pat:default") ;;
    esac
  fi
  if [ -n "$apat" ]; then
    fp=$(_status_fp "$apat")
    case "$seen" in *" $fp "*) ;; *)
      seen="$seen$fp "
      S_ID+=("pat:admin"); S_KIND+=(pat); S_SLUG+=(""); S_TOK+=("$apat"); S_EXP+=(""); S_CRED+=("pat:admin") ;;
    esac
  fi
  if [ "${#S_ID[@]}" -eq 0 ]; then
    if [ "$mode" = json ]; then printf '[]\n'; else echo "gh-token: no tokens on this box"; fi
    return 0
  fi
  local i js row rr rl rres gr gl gres ru gu riso giso gq hgr hgl hgres hgu gused gsrc
  for i in "${!S_ID[@]}"; do
    js=$(curl -sS -m 5 -H "Authorization: token ${S_TOK[$i]}" \
          -H "Accept: application/vnd.github+json" "$APIB/rate_limit" 2>/dev/null)
    row=$(rate_row "$js")
    # An empty body (or one jq refused outright) is BOTH buckets unreadable.
    [ -n "$row" ] || row=$(printf '0\t0\t0\t0\t0\t0\t1\t1')
    IFS=$'\t' read -r rr rl rres gr gl gres ru gu <<<"$row"
    # BH-1574: GraphQL from the headers of a GraphQL response when it gave them;
    # /rate_limit stays the fallback, and `graphql_source` says which one this
    # row is. An unknown `used` is `-` / null, never 0.
    gused=""; gsrc=rate_limit
    gq=$(_status_gql "${S_TOK[$i]}")
    if [ -n "$gq" ]; then
      IFS=$'\t' read -r hgr hgl hgres hgu <<<"$gq"
      gr=$hgr; gl=$hgl; gused=$hgu; gsrc=headers; gu=0
      [ "${hgres:-0}" = 0 ] || gres=$hgres
    fi
    if [ "$ru" = 1 ]; then
      # Never the token, only the identity we call it by.
      echo "gh-token: --status ${S_ID[$i]}: /rate_limit answered with no rate object (unauthenticated or unparseable) — reporting 0/0" >&2
    fi
    riso=$(iso_of "$rres"); giso=$(iso_of "$gres")
    if [ "$mode" = json ]; then
      S_OUT+=("$(jq -nc --arg id "${S_ID[$i]}" --arg k "${S_KIND[$i]}" --arg s "${S_SLUG[$i]}" \
        --argjson rr "$rr" --argjson rl "$rl" --argjson gr "$gr" --argjson gl "$gl" \
        --arg ri "$riso" --arg gi "$giso" --arg ex "${S_EXP[$i]}" \
        --argjson u "$ru" --argjson gu "$gu" --arg gused "$gused" --arg gsrc "$gsrc" \
        --arg cr "${S_CRED[$i]}" \
        '{identity:$id, kind:$k, slug:(if $s == "" then null else $s end),
          rest_remaining:$rr, rest_limit:$rl,
          graphql_remaining:$gr, graphql_limit:$gl,
          graphql_used:(if $gused == "" then null else ($gused|tonumber) end),
          graphql_source:$gsrc,
          resets_at:{rest:(if $ri == "" then null else $ri end),
                     graphql:(if $gi == "" then null else $gi end)},
          expires_at:(if $ex == "" then null else $ex end),
          unreadable:($u == 1), graphql_unreadable:($gu == 1),
          credential:$cr}')")
    else
      # The App rows keep the bare slug as their first field: the operator text
      # this has printed since BH-470 is what tests/gh-default-auth-lanes-test.sh
      # and every runbook grep for, so the new numbers are APPENDED to it.
      # BH-1574: graphql_used / graphql_source APPENDED — every field before
      # them keeps its place for the greps named above.
      printf '%s remaining=%s/%s expires_at=%s graphql=%s/%s rest_resets_at=%s graphql_resets_at=%s graphql_used=%s graphql_source=%s\n' \
        "${S_ID[$i]}" "$rr" "$rl" "${S_EXP[$i]:--}" "$gr" "$gl" "${riso:--}" "${giso:--}" "${gused:--}" "$gsrc"
    fi
  done
  if [ "$mode" = json ]; then
    printf '%s\n' "${S_OUT[@]}" | jq -sc '.'
  fi
}

# --warm is called by the highest-frequency lane on the hub (bin/wake-loop.sh) so
# that the mint happens OFF the critical path of a build or a merge: by the time
# run-build.sh or the conductor asks, the cache is already warm and the answer
# costs no request at all.
do_warm() {
  local p slug rc=0
  armed || { echo "gh-token: App tokens not armed — nothing to warm"; return 0; }
  for p in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || continue
    case "$slug" in ''|'-'|*[!A-Za-z0-9._/-]*) continue ;; esac
    case "$slug" in */*) ;; *) continue ;; esac
    if token_for "$slug" >/dev/null 2>&1; then echo "$slug warm"; else echo "$slug FAILED"; rc=1; fi
  done
  return "$rc"
}

# hub_retry <why> — a profile that cannot answer asks the hub App instead
# (BH-1578). The builders App is installed on example-org only, so a pool project
# owned elsewhere would otherwise drop from today's hub App token to the PAT.
# Re-executes this script with the same arguments minus --app, so the answer
# (token, expiry or installation) is exactly the one the hub path gives. A no-op
# without a profile, which is also what ends the recursion.
#
# NOTHING OF THE PROFILE CROSSES INTO THE HUB MINT (#1590 review I1). The profile
# env was sourced under `set -a`, so its GH_APP_ID, key path and
# GH_APP_INSTALLATION_* are EXPORTED; a hub env that leaves any of them to its
# default would otherwise sign with the builders key or send the hub JWT to the
# builders installation (a 404, then the PAT). They are unset before the exec.
hub_retry() {
  [ -n "$GH_APP_PROFILE" ] || return 0
  local -a a=(); local skip=0 x v
  for x in "${ORIG_ARGS[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$x" in --app) skip=1; continue ;; --app=*) continue ;; esac
    a+=("$x")
  done
  unset GH_APP_ID GH_APP_PRIVATE_KEY_FILE
  for v in $(compgen -v GH_APP_INSTALLATION_); do unset "$v"; done
  exec env GH_APP_PROFILE=hub "$0" "${a[@]}"
}

# profile_row_live <owner/repo> — rc 0 when there is no profile (the hub's
# --expires-at / --installation-id are today's, unchanged) or when the profile's
# cached row still has MIN_LIFE left (#1590 review B2). A STALE builders row is
# not the token this invocation would hand out — the mint path would have
# replaced it or fallen to the hub — so answering from it named the wrong bucket
# in the bundle hint and handed rotation an expiry that never moved forward.
# Callers pass the same --min-life to all three asks so they agree on the row.
profile_row_live() {
  [ -n "$GH_APP_PROFILE" ] || return 0
  cache_read "$1" >/dev/null
}

# profile_retry_record <owner/repo> — a profile could not MINT and the hub App is
# about to answer instead (#1590 review B2). That moves these builders back onto
# the hub's bucket, which is the exact incident the profile exists to prevent, so
# it is never silent:
#   - every retry is one counted line in logs/gh-rate.log (counts, never a token),
#     with the hour's running count from state/gh-app-profile-retry/;
#   - the FIRST retry of a profile in an hour is one ALERTS line (rate-limited by
#     a flag per profile per hour, the fleet's usual once-per-window page);
#   - one `hub-retry` line on stderr, which bin/fly-pool.sh captures and logs.
# The retry itself is bounded by the hub's token cache: repeated asks for a repo
# inside an hour are cache hits there, not new hub mints.
profile_retry_record() {
  local slug="$1" hr d cf n flag
  hr=$(date -u +%Y%m%d%H)
  d="$H/state/gh-app-profile-retry"
  mkdir -p "$d" "$H/logs" "$H/flags" 2>/dev/null
  cf="$d/$GH_APP_PROFILE-$hr.count"
  n=$(cat "$cf" 2>/dev/null | tr -dc '0-9'); n=$(( ${n:-0} + 1 ))
  printf '%s\n' "$n" > "$cf" 2>/dev/null
  find "$d" -name '*.count' -mmin +1440 -delete 2>/dev/null
  # The hourly flags below are bounded the way bin/lib/gh-quota.sh bounds its own
  # (D21, BH-1602): 180 min, and the current hour's flag is never that old.
  find "$H/flags" -maxdepth 1 -name 'alerted-gh-app-profile-retry-*' -mmin +180 -delete 2>/dev/null
  echo "$(STAMP) gh-app-profile-retry profile=$GH_APP_PROFILE->hub $slug reason=mint-failed count=$n" >> "$RATELOG" 2>/dev/null
  flag="$H/flags/alerted-gh-app-profile-retry-$GH_APP_PROFILE-$hr"
  if [ ! -f "$flag" ]; then
    touch "$flag" 2>/dev/null
    echo "$(STAMP) [gh-token] gh-app-profile-retry: App profile '$GH_APP_PROFILE' could not mint for $slug — the hub App answered, so pool machines are spending the HUB installation bucket again. Every retry is counted in logs/gh-rate.log (gh-app-profile-retry lines); check env/github-app-$GH_APP_PROFILE.env and the App's installation." >> "$H/logs/ALERTS.log" 2>/dev/null
  fi
  warn "hub-retry profile=$GH_APP_PROFILE->hub $slug count=$n this hour"
}

# --- the extra-read token (BH-5910, see the header) ---------------------------
XREAD_MAX=10
# xread_list <owner/repo> <csv> -> the valid extra slugs, one per line: the
# project itself dropped, deduped case-insensitively, sorted, capped. An entry
# that is not owner/repo is named missing here; the cap is named, never silent.
xread_list() {
  local slug="$1" e lc seen=" " n=0
  local -a all=() kept=()
  IFS=$', \t\n' read -r -d '' -a all <<< "$2" || true
  for e in ${all[@]+"${all[@]}"}; do
    [ -n "$e" ] || continue
    if ! [[ "$e" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then xread_missing "$slug" "$e" "(not owner/repo)"; continue; fi
    lc="${e,,}"
    [ "$lc" = "${slug,,}" ] && continue
    case "$seen" in *" $lc "*) continue ;; esac
    seen="$seen$lc "; kept+=("$e")
  done
  [ "${#kept[@]}" -gt 0 ] || return 0
  while IFS= read -r e; do
    n=$((n + 1))
    if [ "$n" -gt "$XREAD_MAX" ]; then warn "--extra-read: over the cap of $XREAD_MAX, dropped $e"; continue; fi
    printf '%s\n' "$e"
  done < <(printf '%s\n' "${kept[@]}" | sort -f)
}
xread_missing() { # xread_missing <project slug> <repo> [why]
  warn "EXTRA_READ_REPO_MISSING $2${3:+ $3}"
  mkdir -p "$H/logs" 2>/dev/null
  echo "$(STAMP) EXTRA_READ_REPO_MISSING $2${3:+ $3} for $1" >> "$RATELOG" 2>/dev/null
}
# extra_read_check <project owner> <installation id> <repo> -> rc 0 when the
# installation covers <repo>, 1 when it does not, 2 when the check itself failed.
# Another owner is another installation, so that is a 1 with no request.
extra_read_check() {
  local owner="$1" id="$2" x="$3" xo js got
  xo="${x%%/*}"
  [ "${xo,,}" = "${owner,,}" ] || return 1
  js=$(api_jwt GET "/repos/$x/installation") || return 2
  [ -n "$js" ] || return 2
  got=$(printf '%s' "$js" | jq -r 'if type=="object" then (.id // "" | tostring) else "" end' 2>/dev/null) || return 2
  [ -n "$got" ] && [ "$got" = "$id" ]
}
# mint_extra_read <cache key> <owner/repo> <extra…> -> token on stdout
mint_extra_read() {
  local key="$1" slug="$2" owner repo id js tok exp x rc; shift 2
  owner="${slug%%/*}"; repo="${slug#*/}"
  id=$(install_id "$owner") || { warn "no installation id for $owner"
    token_health_report gh_app "app-unresolved-$owner" fail "" "no installation id" >/dev/null 2>&1; return 1; }
  local -a names=()
  for x in "$@"; do
    extra_read_check "$owner" "$id" "$x"; rc=$?
    case "$rc" in
      0) names+=("${x#*/}") ;;
      2) xread_missing "$slug" "$x" "(unverified)" ;;
      *) xread_missing "$slug" "$x" ;;
    esac
  done
  [ "${#names[@]}" -gt 0 ] || { warn "--extra-read: no extra repo left for $slug — nothing minted"; return 1; }
  js=$(api_jwt POST "/app/installations/$id/access_tokens" \
        "$(jq -nc --arg r "$repo" '{repositories:([$r] + $ARGS.positional), permissions:{contents:"read",metadata:"read"}}' --args "${names[@]}")") || {
    token_health_report gh_app "app-$id" fail "" "access_tokens request failed" >/dev/null 2>&1; return 1; }
  tok=$(printf '%s' "$js" | jq -r '.token // empty' 2>/dev/null)
  exp=$(printf '%s' "$js" | jq -r '.expires_at // empty' 2>/dev/null)
  [ -n "$tok" ] && [ -n "$exp" ] || { warn "$slug: extra-read access_tokens returned no token"
    token_health_report gh_app "app-$id" fail "" "access_tokens returned no token" >/dev/null 2>&1; return 1; }
  cache_write "$key" "$tok" "$exp" "$id" || warn "$slug: extra-read token minted but not cached"
  token_health_report gh_app "app-$id" ok "$exp" >/dev/null 2>&1
  rate_log "$slug#xread-${#names[@]}" "$tok"
  printf '%s' "$tok"
}

PAT_ONLY=0
XREAD_SET=0; XREAD_CSV=""
USAGE='usage: gh-token.sh [--app <profile>] [--min-life <sec>|--fresh] [--read|--pat|--extra-read <csv>] <owner/repo> | --expires-at <owner/repo> | --installation-id <owner/repo> | --app-hook | --app-slug | --status [--json] | --warm'
JSON_STATUS=0
# Options come first and are consumed here, so every case below still reads $1 as
# the subcommand or the slug exactly as it always has.
while [ $# -gt 0 ]; do
  case "$1" in
    --min-life) MIN_LIFE=$(printf '%s' "${2:-}" | tr -dc '0-9')
                [ -n "$MIN_LIFE" ] || { echo "$USAGE" >&2; exit 2; }; shift 2 ;;
    --min-life=*) MIN_LIFE=$(printf '%s' "${1#--min-life=}" | tr -dc '0-9')
                [ -n "$MIN_LIFE" ] || { echo "$USAGE" >&2; exit 2; }; shift ;;
    # --fresh is "as new as this script can give you": an installation token
    # lives 3600s, so 3300 means anything minted more than 5 minutes ago is
    # re-minted. Not 3600 — that would refuse the token GitHub handed back one
    # second earlier and mint forever.
    --fresh)    MIN_LIFE=3300; shift ;;
    # --read is a MODE, not an argument: the slug still follows it, so every
    # case below reads $1 exactly as it always has.
    --read)     READ_ONLY=1; shift ;;
    # --pat (C2 review, 2026-09-24): the box's PLAIN PAT only — never a mint,
    # and never the admin PAT (plain_pat: GH_TOKEN, keyring, env/gh-pat).
    # For a credential that must outlive an installation token's hour and has
    # no rotation (the fly-dispatch bundle), or a repo the App is not installed
    # on (the share mirror). rc 1 + a stderr line when no plain PAT exists.
    --pat)      PAT_ONLY=1; shift ;;
    # --extra-read <csv> (BH-5910): a MODE with its list; the slug still follows.
    --extra-read) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
                XREAD_SET=1; XREAD_CSV="$2"; shift 2 ;;
    --extra-read=*) XREAD_SET=1; XREAD_CSV="${1#--extra-read=}"; shift ;;
    # --json is a MODE for --status, accepted on either side of it: an operator
    # types `--status --json` and a caller that builds its argv from this loop
    # types it first. Both land here, so $1 below is still the subcommand.
    --json)     JSON_STATUS=1; shift ;;
    # --app was already read above, where the profile decides the env file; here
    # it is only consumed so $1 below is still the subcommand or the slug.
    --app)      [ -n "${2:-}" ] || { echo "$USAGE" >&2; exit 2; }; shift 2 ;;
    --app=*)    shift ;;
    *) break ;;
  esac
done

case "${1:-}" in
  --status)
    [ "${2:-}" = --json ] && JSON_STATUS=1
    if [ "$JSON_STATUS" = 1 ]; then do_status --json; else do_status; fi
    exit 0 ;;
  --warm)   do_warm; exit $? ;;
  --expires-at)
    case "${2:-}" in */*) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
    command -v jq >/dev/null 2>&1 || exit 1
    profile_row_live "$2" || hub_retry
    cache_expires_at "$2" || { hub_retry; exit 1; }
    printf '\n'; exit 0 ;;
  --app-hook)
    READ_ONLY=1
    armed && command -v jq >/dev/null 2>&1 || exit 1
    APPJ=$(api_jwt GET /app) || exit 1
    printf '%s' "$APPJ" | jq -e '.id' >/dev/null 2>&1 || exit 1
    HOOKJ=$(api_jwt GET /app/hook/config) || exit 1
    printf '%s\t%s\n' "$(printf '%s' "$HOOKJ" | jq -r '.url // ""' 2>/dev/null)" \
      "$(printf '%s' "$APPJ" | jq -r '(.events // []) | join(",")' 2>/dev/null)"
    exit 0 ;;
  --app-slug)
    READ_ONLY=1
    armed && command -v jq >/dev/null 2>&1 || exit 1
    APPJ=$(api_jwt GET /app) || exit 1
    printf '%s' "$APPJ" | jq -er '.slug | select(type == "string" and length > 0)' 2>/dev/null || exit 1
    exit 0 ;;
  --installation-id)
    case "${2:-}" in */*) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
    command -v jq >/dev/null 2>&1 || exit 1
    profile_row_live "$2" || hub_retry
    cache_installation_id "$2" || { hub_retry; exit 1; }
    printf '\n'; exit 0 ;;
  ''|-*)    echo "$USAGE" >&2; exit 2 ;;
esac

SLUG="$1"
case "$SLUG" in */*) ;; *) echo "gh-token: '$SLUG' is not owner/repo" >&2; exit 2 ;; esac
# The extra-read token is answered before every other mode: it has no PAT and no
# hub fallback, so a failure here is rc 1 with nothing printed (header).
if [ "$XREAD_SET" = 1 ]; then
  armed && command -v jq >/dev/null 2>&1 || exit 1
  mapfile -t XREAD < <(xread_list "$SLUG" "$XREAD_CSV")
  [ "${#XREAD[@]}" -gt 0 ] || { warn "--extra-read: no extra repo for $SLUG — nothing minted"; exit 1; }
  XKEY="$SLUG#xread-$(printf '%s\n' "${XREAD[@],,}" | sha256sum | cut -c1-8)"
  TOK=$(cache_read "$XKEY") || TOK=""
  if [ -z "$TOK" ]; then
    mkdir -p "$H/locks" 2>/dev/null
    XLF="$H/locks/gh-app-token${GH_APP_PROFILE:+-$GH_APP_PROFILE}-$(basename "$(cache_file "$XKEY")" .json).lock"
    if { : > "$XLF"; } 2>/dev/null; then
      exec 8>"$XLF"; flock -w 5 8 2>/dev/null || true
      TOK=$(cache_read "$XKEY") || TOK=$(mint_extra_read "$XKEY" "$SLUG" "${XREAD[@]}") || TOK=""
      exec 8>&-
    else
      TOK=$(mint_extra_read "$XKEY" "$SLUG" "${XREAD[@]}") || TOK=""
    fi
  fi
  [ -n "$TOK" ] || exit 1
  printf '%s\n' "$TOK"; exit 0
fi
if [ "${PAT_ONLY:-0}" = 1 ]; then
  PAT=$(plain_pat)
  [ -n "$PAT" ] || { echo "gh-token: no PAT for $SLUG — --pat reads GH_TOKEN, then the gh keyring, then $HENV/gh-pat, and none holds a plain PAT (the admin PAT is never an answer here)" >&2; exit 1; }
  printf '%s\n' "$PAT"; exit 0
fi
command -v jq >/dev/null 2>&1 || { pat_for "$SLUG"; exit 0; }
if armed && TOK=$(token_for "$SLUG") && [ -n "$TOK" ]; then
  printf '%s\n' "$TOK"
  exit 0
fi
# Unconfigured, killed, or a mint that failed: today's PAT, and the caller cannot
# tell the difference. A mint failure is stderr + the PAT, never an empty answer.
# Under a profile the hub App is asked first: the PAT is the last rung, as it is
# for every hub lane. A profile that is SWITCHED OFF (the kill switches) goes
# straight to the PAT, exactly as the hub does; only a profile that could not
# mint is retried, and that retry is recorded (profile_retry_record).
if [ -n "$GH_APP_PROFILE" ] && ! killed; then
  profile_retry_record "$SLUG"
  hub_retry
fi
PAT=$(pat_for "$SLUG")
[ -n "$PAT" ] || exit 1
printf '%s\n' "$PAT"
