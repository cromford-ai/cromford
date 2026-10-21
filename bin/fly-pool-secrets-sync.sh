#!/bin/bash
# bin/fly-pool-secrets-sync.sh <project> [--dry-run] — BH-7430 (BH-6896 S3).
#
# Writes the pool's STATIC env bundle into the pool app's Fly secrets, once, at
# operator time, so a pull-path spawn (bin/fly-pool.sh POOL_MACHINE_PULL=1)
# never ssh-es to the owning box. The bundle is exactly what the push path
# builds per spawn: `bin/fly-envbundle.sh <project> <tmp> --pool` (its
# whitelist is still the only thing that leaves the hub). Each line becomes
# one secret:
#   global.env    KEY=VAL -> HBUNDLE_G_KEY=VAL
#   <project>.env KEY=VAL -> HBUNDLE_P_KEY=VAL
#   HBUNDLE_SYNCED_AT=<UTC>  the marker bin/fly-pool.sh reads once per tick
# in ONE `fly secrets import --stage` (a failed import leaves no new marker).
# --stage: a live build is never restarted by a secrets change; the next
# `fly machine run` gets the new values. fly/entrypoint.sh turns them back into
# /run/harness-env/{global.env,<project>.env} and unsets them.
#
# QUOTING: `fly secrets import` parses dotenv. A value of only [A-Za-z0-9_.\/:@+,=-]
# is written as is; any other value (space, #, ", $, backslash) is written in
# single quotes, which dotenv keeps literal. A value with a single quote cannot
# be carried: the sync stops with an alert naming the key, never the value.
# NOT SYNCED: GH_TOKEN and GH_TOKEN_INSTALLATION_ID. A pull spawn always gets a
# minted App token in its seed (no mint, no pull), so the owning box's PAT has
# no reader on a pull machine and stays off the app.
# STALE NAMES: an HBUNDLE_* secret the new bundle no longer has is unset
# (--stage) after the import, so a key removed on the box leaves the app too.
#
# --dry-run prints the secret NAMES it would import and unset, never a value,
# and changes nothing. Any failure: one ALERTS line naming the app and the
# step, rc 1. The temp dir (it holds the bundle) is removed on every exit.
set -uo pipefail

P="${1:-}"
case "${2:-}" in ''|--dry-run) DRY="${2:-}" ;; *) echo "usage: fly-pool-secrets-sync.sh <project> [--dry-run]" >&2; exit 2 ;; esac
[ -n "$P" ] || { echo "usage: fly-pool-secrets-sync.sh <project> [--dry-run]" >&2; exit 2; }
HARNESS="${HARNESS:-/root/harness}"
command -v jq >/dev/null 2>&1 || { echo "fly-pool-secrets-sync/$P FATAL: jq required" >&2; exit 1; }

fail() { # fail <step> <why>
  echo "fly-pool-secrets-sync/$P FATAL: $1: $2" >&2
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool-secrets/$P] sync of the env bundle to ${APP:-the pool app} FAILED at $1: $2. Pull-path spawns keep the old secrets (or take the push path). Re-run bin/fly-pool-secrets-sync.sh $P." >/dev/null 2>&1 || true
  exit 1
}

APP=$(jq -r '.app // ""' "$HARNESS/state/fly/$P.json" 2>/dev/null)
[ -n "$APP" ] || { APP=""; fail "app lookup" "no .app in state/fly/$P.json"; }

# The Fly token, resolved as bin/fly-pool.sh resolves it (BH-7107).
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/fly.env" 2>/dev/null; set +a
export PATH="${FLY_BIN_DIR:-/root/.fly/bin}:$PATH"
TV="FLY_API_TOKEN_$(echo "$P" | tr '[:lower:].-' '[:upper:]__')"
# shellcheck source=bin/lib/fly-token.sh
. "$HARNESS/bin/lib/fly-token.sh" 2>/dev/null || true
if command -v fly_token_resolve >/dev/null 2>&1; then fly_token_resolve "$P"; else FLY_TOKEN_VAL="${!TV:-}"; fi
export FLY_ACCESS_TOKEN="${FLY_TOKEN_VAL:-}"
[ -n "$FLY_ACCESS_TOKEN" ] || fail "fly token" "neither $TV nor FLY_API_TOKEN is set"
FLY=$(command -v fly || command -v flyctl) || fail "flyctl" "no fly binary on PATH"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hbundle.XXXXXX") || fail "mktemp" "no temp dir"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

HARNESS="$HARNESS" "$HARNESS/bin/fly-envbundle.sh" "$P" "$TMP/b" --pool >/dev/null 2>"$TMP/err" \
  || fail "env bundle" "$(grep 'FATAL:' "$TMP/err" | tail -n 1 | sed 's/^.*FATAL: //' | tr -d '\000-\037' | cut -c1-200)"

# The import stream. Only KEY=VAL lines with a shell-name key; the excluded
# keys are dropped; a key that appears twice keeps its LAST value, as `. file`.
( umask 077
  for f in global:G "$P":P; do
    src="$TMP/b/${f%%:*}.env"; pre="HBUNDLE_${f##*:}_"
    [ -r "$src" ] || continue
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$src" | awk -F= -v pre="$pre" -v bad="$TMP/badkeys" '
      # `fly secrets import` reads dotenv: an unquoted value loses everything
      # after a #, keeps no quote and expands $VAR. A value outside the plain
      # set goes in single quotes (literal in dotenv). A single quote inside
      # the value cannot be quoted: that key is named in badkeys, no import.
      function q(k, v) {
        if (v ~ /^[A-Za-z0-9_.\/:@+,=-]*$/) return v
        if (index(v, "\047") > 0) { print pre k >> bad; return "" }
        return "\047" v "\047"
      }
      $1 == "GH_TOKEN" || $1 == "GH_TOKEN_INSTALLATION_ID" { next }
      { k = $1; v = substr($0, length($1) + 2); if (!(k in seen)) order[++n] = k; seen[k] = v }
      END { for (i = 1; i <= n; i++) print pre order[i] "=" q(order[i], seen[order[i]]) }'
  done > "$TMP/import"
  printf 'HBUNDLE_SYNCED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TMP/import" )
rm -rf "$TMP/b"
[ ! -s "$TMP/badkeys" ] || fail "env bundle" "a value has a single quote, which dotenv import cannot carry (key names only): $(tr '\n' ' ' < "$TMP/badkeys" | cut -c1-200)"
NEW=$(cut -d= -f1 "$TMP/import" | sort -u)
[ "$(grep -c '^HBUNDLE_G_' <<<"$NEW")" -gt 0 ] || fail "env bundle" "the bundle has no global line"

OLD=$(timeout 60 "$FLY" secrets list -a "$APP" --json 2>/dev/null \
      | jq -r '.[]? | (.Name // .name // empty)' 2>/dev/null | grep '^HBUNDLE_' | sort -u)
STALE=$(comm -23 <(printf '%s\n' "$OLD" | grep -v '^$') <(printf '%s\n' "$NEW"))

if [ -n "$DRY" ]; then
  echo "fly-pool-secrets-sync/$P: dry run for $APP — would import $(grep -c . <<<"$NEW") secret(s):"
  printf '  %s\n' $NEW
  if [ -n "$STALE" ]; then echo "would unset $(grep -c . <<<"$STALE") stale secret(s):"; printf '  %s\n' $STALE; fi
  exit 0
fi

timeout 120 "$FLY" secrets import --stage -a "$APP" < "$TMP/import" >/dev/null 2>"$TMP/err" \
  || fail "secrets import" "fly secrets import exited non-zero"
if [ -n "$STALE" ]; then
  # shellcheck disable=SC2086
  timeout 120 "$FLY" secrets unset --stage -a "$APP" $STALE >/dev/null 2>"$TMP/err" \
    || fail "stale unset" "the new bundle is in, but $(grep -c . <<<"$STALE") stale HBUNDLE secret(s) are still on the app"
fi
echo "fly-pool-secrets-sync/$P: $APP has $(grep -c . <<<"$NEW") HBUNDLE secret(s), $(grep -c . <<<"$STALE") stale unset"
exit 0
