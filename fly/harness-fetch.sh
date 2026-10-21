#!/bin/bash
# fly/harness-fetch.sh <sha> <owner/repo> <token-file> <dest> — BH-7430.
#
# A pool machine on the pull path (bin/fly-pool.sh POOL_MACHINE_PULL=1) gets
# its harness from GitHub, not from a hub tarball over `ssh sftp`. The hub pins
# the exact commit: HARNESS_SHA is the 40-hex HEAD of /root/harness-checkout
# when the spawn ran, so a machine never runs a harness its hub did not run.
#
# What it does: a shallow fetch of <sha> into a scratch repo beside <dest>,
# a check that FETCH_HEAD IS <sha>, then `git archive` of the same paths
# harness_tarball ships (bin prompts rules catalog fleet.conf fly) into <dest>,
# and the same HARNESS_COMMIT stamp (bin/lib/harness-tarball.sh, BH-1632).
# The token is the read token the hub seeded at /run/harness-env/
# gh-token-harness. It rides in an http.extraHeader set through GIT_CONFIG_*
# env, so it is never on argv, in the URL, in .git/config or in a log line.
#
# rc 0 = fetched and stamped; rc 1 = 3 attempts failed (one FATAL line);
# rc 2 = a bad argument (no fetch tried). Copied into the image at
# /opt/fly-boot/harness-fetch.sh (fly/Dockerfile) and run by fly/entrypoint.sh.
set -uo pipefail

SHA="${1:-}"; SLUG="${2:-}"; TOKF="${3:-}"; DEST="${4:-}"
fail() { echo "harness-fetch FATAL: $1" >&2; exit "$2"; }

[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "sha is not 40 hex characters" 2
[[ "$SLUG" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || fail "repo slug is not owner/repo" 2
[ -n "$DEST" ] && [ "${DEST#/}" != "$DEST" ] || fail "dest must be an absolute path" 2
[ -s "$TOKF" ] || fail "no token file at ${TOKF:-<unset>}" 2
TOK=$(head -n 1 "$TOKF" | tr -d '[:space:]')
[ -n "$TOK" ] || fail "the token file is empty" 2

# GIT_FETCH_URL_OVERRIDE is the test seam (a local bare repo stands in for
# GitHub). Production never sets it.
URL="${GIT_FETCH_URL_OVERRIDE:-https://github.com/$SLUG.git}"
WORK="$DEST.fetch"
ATTEMPTS="${HARNESS_FETCH_ATTEMPTS:-3}"; case "$ATTEMPTS" in ''|*[!0-9]*|0) ATTEMPTS=3 ;; esac

mkdir -p "$DEST" || fail "cannot create $DEST" 1
n=0; got=""
while [ "$n" -lt "$ATTEMPTS" ]; do
  n=$((n + 1))
  rm -rf "$WORK"
  if git init -q "$WORK" 2>/dev/null \
     && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
        GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$TOK" | base64 -w0)" \
        GIT_TERMINAL_PROMPT=0 \
        timeout 60 git -C "$WORK" fetch -q --depth 1 "$URL" "$SHA" >/dev/null 2>&1; then
    got=$(git -C "$WORK" rev-parse FETCH_HEAD 2>/dev/null)
    [ "$got" = "$SHA" ] && break
  fi
  got=""
  [ "$n" -lt "$ATTEMPTS" ] && sleep 5
done
TOK=""
if [ "$got" != "$SHA" ]; then
  rm -rf "$WORK"
  fail "fetch of ${SHA:0:12} from $SLUG failed $ATTEMPTS times" 1
fi
if ! git -C "$WORK" archive FETCH_HEAD bin prompts rules catalog fleet.conf fly | tar x -C "$DEST"; then
  rm -rf "$WORK"
  fail "extract of ${SHA:0:12} into $DEST failed" 1
fi
rm -rf "$WORK"
printf '%s\n' "$SHA" > "$DEST/HARNESS_COMMIT"
mkdir -p "$DEST/logs" "$DEST/state" "$DEST/locks" "$DEST/builds"
echo "harness-fetch: $SLUG ${SHA:0:12} into $DEST (attempt $n)"
exit 0
