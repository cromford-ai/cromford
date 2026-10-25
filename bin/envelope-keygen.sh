#!/bin/bash
# bin/envelope-keygen.sh [--rotate] — BH-7965 (BH-7937.2): the hub's envelope
# key pair. An operator one-shot on the hub, never a lane.
#
#   bin/envelope-keygen.sh            make the key if there is none, then send
#                                     its public half to the worker
#   bin/envelope-keygen.sh --rotate   keep the old key as envelope.key.<epoch>
#                                     (bin/envelope-consume.sh tries it for one
#                                     TTL), make a new one, send its public half
#
# The private key is RSA-4096 at ${ENVELOPE_KEY:-/etc/harness/envelope.key},
# made under umask 077 and mode 600. It is never overwritten without --rotate:
# a second run keeps it and sends the same public half again. The public half
# goes to settings row hub_envelope_public_key through
# PUT /api/secrets/envelope/public-key (main bearer AND x-envelope-hub-token).
#
# Exit 0 sent. 1 a usage, openssl or credential error, or the worker refused
# the PEM (4xx). 75 the worker did not answer or answered 5xx: the key stays on
# disk and a re-run sends it again.
# Env: ENVELOPE_KEY (the key path), ENVELOPE_NOW (epoch seconds; test seam).
# Doc: docs/SECRETS-ENVELOPE.md.
set -uo pipefail
set +x
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
umask 077

ROTATE=0
case "${1:-}" in
  "") ;;
  --rotate) ROTATE=1 ;;
  *) echo "usage: envelope-keygen.sh [--rotate]" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { echo "usage: envelope-keygen.sh [--rotate]" >&2; exit 1; }

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" >/dev/null 2>&1 || { echo "envelope-keygen: jobs-client did not load" >&2; exit 1; }
# shellcheck source=bin/lib/envelope.sh
. "$SELF/lib/envelope.sh" || exit 1

KEY="${ENVELOPE_KEY:-/etc/harness/envelope.key}"
KDIR=$(dirname "$KEY")
NOW="${ENVELOPE_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]+$ ]] || { echo "envelope-keygen: ENVELOPE_NOW is not epoch seconds" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "envelope-keygen: openssl is not installed" >&2; exit 1; }
mkdir -p "$KDIR" || { echo "envelope-keygen: cannot make $KDIR" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/envkeygen.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

if [ -e "$KEY" ] && [ "$ROTATE" = 1 ]; then
  mv "$KEY" "$KEY.$NOW" || { echo "envelope-keygen: cannot move the old key aside" >&2; exit 1; }
  chmod 600 "$KEY.$NOW"
  echo "envelope-keygen: old key kept as $KEY.$NOW"
fi
if [ ! -e "$KEY" ]; then
  NEW=$(mktemp "$KDIR/.envelope.key.XXXXXX") || { echo "envelope-keygen: cannot write in $KDIR" >&2; exit 1; }
  if ! openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$NEW" 2>/dev/null; then
    rm -f "$NEW"; echo "envelope-keygen: openssl genpkey failed" >&2; exit 1
  fi
  chmod 600 "$NEW" && mv "$NEW" "$KEY" || { rm -f "$NEW"; echo "envelope-keygen: cannot install the key" >&2; exit 1; }
  echo "envelope-keygen: new RSA-4096 key at $KEY"
else
  echo "envelope-keygen: key exists at $KEY; kept (use --rotate to replace it)"
fi

openssl pkey -in "$KEY" -pubout -out "$TMP/pub.pem" 2>/dev/null || { echo "envelope-keygen: cannot read the key" >&2; exit 1; }
# Exactly one PUBLIC KEY block, and nothing private, or nothing is sent.
if [ "$(grep -c -- '-----BEGIN PUBLIC KEY-----' "$TMP/pub.pem")" != 1 ] \
   || [ "$(grep -c -- '-----END PUBLIC KEY-----' "$TMP/pub.pem")" != 1 ] \
   || grep -q PRIVATE "$TMP/pub.pem"; then
  echo "envelope-keygen: the public half is not one PUBLIC KEY block; not sent" >&2; exit 1
fi
FP=$(openssl pkey -pubin -in "$TMP/pub.pem" -outform DER 2>/dev/null | sha256sum | cut -c1-16)
jq -Rs '{pem: .}' < "$TMP/pub.pem" > "$TMP/body.json" || exit 1

CODE=$(envelope_req PUT /api/secrets/envelope/public-key "$TMP/body.json" "$TMP/out.json"); RC=$?
if [ "$RC" = 1 ]; then
  echo "envelope-keygen: JOBS_URL, HARNESS_SECRET or ENVELOPE_HUB_TOKEN is not set; public key not sent" >&2; exit 1
fi
case "$CODE" in
  2??) echo "envelope-keygen: public key sent (fingerprint $FP)"; exit 0 ;;
  4??) echo "envelope-keygen: the worker refused the public key (http $CODE); key kept" >&2; exit 1 ;;
  *)   echo "envelope-keygen: the worker did not take the public key (http $CODE); key kept, run again" >&2; exit 75 ;;
esac
