#!/bin/bash
# bin/envelope-consume.sh <id> — BH-7965 (BH-7937.2): read one secret envelope
# on the hub, prove the secret with its vendor, write it to the boxes, confirm.
# bin/secrets-apply.sh runs it once per pending envelope. Doc: docs/SECRETS-ENVELOPE.md.
#
#   1. GET /api/secrets/envelope/<id> (main bearer AND x-envelope-hub-token).
#      The read deletes the envelope, so this runs at most once per id.
#   2. Decrypt with openssl pkeyutl, RSA-OAEP SHA-256 (MGF1 SHA-256): the
#      current key, then each envelope.key.<epoch> younger than the TTL.
#   2b. A fleet:<target>[:<arg>] scope (BH-8541) stops here: bin/lib/envelope-fleet.sh
#      writes the value to the hub's OWN env file (fly.env or global.env; no
#      ssh, no vendor probe), reads it back and sets its flag. For
#      fleet:telegram the hub then runs bin/fleet-telegram-chat.sh (#7974),
#      which stores telegram.chat_id and telegram.bot_present. Confirm detail:
#      `fleet=<fly|tailscale|telegram>[ chat=<ok|waiting|not-installed>]`, or
#      apply_failed `fleet=<target> <refused|write-failed|unflagged>` /
#      `fleet=telegram chat=failed` (the token line stays written). Exits 0, 1, 2, 3, 75.
#   3. Parse the scope ai-account:<vendor>:<label>:<use_kind>[:<project>].
#   4. Prove the secret: bin/lib/vendor/<vendor>.sh probe, the value on stdin.
#   5. Write it to every target box over ssh, the value on stdin:
#        claude  accounts.d/<label>.env  CLAUDE_CODE_OAUTH_TOKEN=<value>
#        other   project: env/<project>.env  <VENDOR>_API_KEY_<LABEL>=<value>
#                pool, fallback: env/global.env  <VENDOR>_API_KEY=<value>,
#                only when that line is not there yet (never overwritten)
#      Targets: project = that project's box (fleet-conf.sh --tailnet-ip);
#      pool and fallback = every box (fleet-conf.sh --tailnet-ips).
#   6. POST /api/secrets/envelope/<id>/confirm {ok, detail}: always the last step.
#
# Exit 0 every box written, `applied`. 1 nothing written (`apply_failed`, or a
# bad id and no call). 2 decrypt failed (`apply_failed "decrypt failed"`).
# 3 no such envelope (404), no event. 4 some boxes failed: the good boxes keep
# the file, `apply_failed` names the others. 75 the worker did not answer or
# refused the hub token (one ALERTS line for a refused token or a lost confirm).
#
# The secret lives in one shell variable and in pipes only. It is never on
# argv, in a log line or on stderr. Logs carry the id, the scope, rcs and counts.
# Env: ENVELOPE_KEY, ENVELOPE_NOW (epoch seconds; test seam),
#      SECRETS_APPLY_SSH_TIMEOUT_S (lane.secrets-apply.secrets_apply_ssh_timeout_s).
set -uo pipefail
set +x
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
umask 077

ID="${1:-}"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "$ID" =~ $UUID_RE ]] || { echo "usage: envelope-consume.sh <envelope-uuid>" >&2; exit 1; }

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" >/dev/null 2>&1 || { echo "envelope-consume: jobs-client did not load" >&2; exit 75; }
# shellcheck source=bin/lib/envelope.sh
. "$SELF/lib/envelope.sh" || exit 75
# shellcheck source=bin/lib/project-account.sh
. "$SELF/lib/project-account.sh" >/dev/null 2>&1 || true
export ENVELOPE_FLEET_CONF_BIN="$SELF/fleet-conf.sh"

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/secrets-apply.log"
log() { printf '%s envelope-consume %s %s\n' "$(date -u +%FT%TZ)" "$ID" "$1" >> "$LOG" 2>/dev/null; }
alert() { "$SELF/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

KEY="${ENVELOPE_KEY:-/etc/harness/envelope.key}"
NOW="${ENVELOPE_NOW:-$(date +%s)}"
SSH_T="${SECRETS_APPLY_SSH_TIMEOUT_S:-15}"   # fallback of lane.secrets-apply.secrets_apply_ssh_timeout_s
[[ "$SSH_T" =~ ^[0-9]+$ ]] && [ "$SSH_T" -ge 3 ] && [ "$SSH_T" -le 120 ] \
  || { log "refused: SECRETS_APPLY_SSH_TIMEOUT_S not in 3..120"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/envconsume.XXXXXX") || exit 75
VALUE=""
trap 'VALUE=""; unset VALUE; rm -rf "$TMP"' EXIT

# confirm <true|false> <detail> — the last step. A lost confirm is an ALERTS line.
confirm() {
  local code
  jq -nc --argjson ok "$1" --arg d "$2" '{ok:$ok, detail:$d}' > "$TMP/confirm.json"
  code=$(envelope_req POST "/api/secrets/envelope/$ID/confirm" "$TMP/confirm.json" "$TMP/confirm.out")
  case "$code" in
    2??) log "confirm ok=$1 detail=$2"; return 0 ;;
  esac
  log "confirm not recorded (http $code) ok=$1 detail=$2"
  alert --id "secrets-apply:confirm:$ID" --severity warn secrets-apply \
    "envelope $ID: $2; confirm not recorded (http $code). Read secret_envelope_events and the box env files by hand."
  return 1
}
# fail <exit> <detail> — confirm false, then exit (75 when the confirm is lost).
fail() { confirm false "$2" || exit 75; exit "$1"; }

# ── 1. read once ──────────────────────────────────────────────────────────────
CODE=$(envelope_req GET "/api/secrets/envelope/$ID" "$TMP/env.json"); RC=$?
case "$CODE" in
  200) ;;
  404) log "no envelope (404)"; exit 3 ;;
  401|403) log "hub token not accepted (http $CODE)"
    alert --id secrets-apply:hub-token --severity warn secrets-apply \
      "hub token not accepted (http $CODE) on the envelope read. Set the same ENVELOPE_HUB_TOKEN on the hub and the jobs worker."
    exit 75 ;;
  503) log "envelope read not configured (http 503)"
    alert --id secrets-apply:hub-token --severity warn secrets-apply \
      "envelope read not configured (http 503): the jobs worker has no ENVELOPE_HUB_TOKEN secret."
    exit 75 ;;
  *) log "worker did not answer (http $CODE rc $RC)"; exit 75 ;;
esac
SCOPE=$(jq -r '.scope // empty' "$TMP/env.json" 2>/dev/null)
CT=$(jq -r '.ciphertext // empty' "$TMP/env.json" 2>/dev/null)
rm -f "$TMP/env.json"
[ -n "$SCOPE" ] && [ -n "$CT" ] || fail 1 "bad envelope answer"
log "read scope=$SCOPE"

# ── 2. decrypt ────────────────────────────────────────────────────────────────
TTL=$(setting_get secret_envelope_ttl_s 2>/dev/null) || TTL=""
[[ "$TTL" =~ ^[0-9]+$ ]] && [ "$TTL" -ge 60 ] && [ "$TTL" -le 86400 ] || TTL=900   # fallback of settings row secret_envelope_ttl_s
decrypt() { printf '%s' "$CT" | base64 -d 2>/dev/null | openssl pkeyutl -decrypt -inkey "$1" \
  -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 2>/dev/null; }
KEYS=()
[ -r "$KEY" ] && KEYS+=("$KEY")
for k in "$KEY".*; do
  [ -r "$k" ] || continue
  ts="${k##*.}"; [[ "$ts" =~ ^[0-9]+$ ]] || continue
  [ $((NOW - ts)) -lt "$TTL" ] && KEYS+=("$k")
done
OKD=0
for k in "${KEYS[@]}"; do
  if VALUE=$(decrypt "$k") && [ -n "$VALUE" ]; then OKD=1; break; fi
done
CT=""
[ "$OKD" = 1 ] || fail 2 "decrypt failed"

# ── 2b. fleet: scopes (BH-8541) — the hub's own env files, no ssh, no probe ──
case "$SCOPE" in
  fleet:*)
    # shellcheck source=bin/lib/envelope-fleet.sh
    . "$SELF/lib/envelope-fleet.sh" || fail 1 "fleet lib missing"
    FPARSED=$(envelope_fleet_scope_parse "$SCOPE") || FPARSED="-"
    FT=${FPARSED%% *}
    printf '%s' "$VALUE" > "$TMP/fleet.val"; VALUE=""
    envelope_fleet_apply "$SCOPE" "$TMP/fleet.val" >/dev/null 2>&1; FRC=$?
    rm -f "$TMP/fleet.val"
    log "fleet $FT rc=$FRC"
    case "$FRC" in
      0) ;;
      1) fail 1 "fleet=$FT refused" ;;
      3) fail 1 "fleet=$FT unflagged" ;;
      *) fail 1 "fleet=$FT write-failed" ;;
    esac
    if [ "$FT" != telegram ]; then confirm true "fleet=$FT" || exit 75; exit 0; fi
    if [ ! -x "$SELF/fleet-telegram-chat.sh" ]; then
      log "telegram chat verb not installed"
      confirm true "fleet=telegram chat=not-installed" || exit 75; exit 0
    fi
    # The consumer sourced global.env at start, so its env holds the OLD token:
    # the verb runs without it and reads the line just written. Its line may
    # hold a chat id or vendor text: it is never logged or put in the event.
    TL=$(env -u TELEGRAM_BOT_TOKEN HARNESS="$H" "$SELF/fleet-telegram-chat.sh" 2>/dev/null | head -n 1; exit "${PIPESTATUS[0]}"); TRC=$?
    case "$TRC:$TL" in
      "0:TELEGRAM_CHAT ok "?*) confirm true "fleet=telegram chat=ok" || exit 75; exit 0 ;;
      "0:TELEGRAM_CHAT waiting" | "0:TELEGRAM_CHAT waiting "*) confirm true "fleet=telegram chat=waiting" || exit 75; exit 0 ;;
    esac
    log "telegram chat verb rc=$TRC"
    fail 1 "fleet=telegram chat=failed" ;;
esac

# ── 3. scope ──────────────────────────────────────────────────────────────────
if ! PARSED=$(envelope_scope_parse "$SCOPE"); then fail 1 "scope refused: $PARSED"; fi
read -r VENDOR LABEL USE PROJECT <<< "$PARSED"

# ── 4. value and proof ────────────────────────────────────────────────────────
[[ "$VALUE" =~ ^[A-Za-z0-9._-]{8,512}$ ]] || fail 1 "value format"
printf '%s' "$VALUE" | "$SELF/lib/vendor/$VENDOR.sh" probe >/dev/null 2>&1; PRC=$?
case "$PRC" in
  0) log "probe $VENDOR ok" ;;
  1) fail 1 "vendor refused the key" ;;
  75) fail 1 "vendor unreachable" ;;
  *) fail 1 "probe error" ;;
esac

# ── 5. boxes ──────────────────────────────────────────────────────────────────
if [ "$USE" = project ]; then
  IPS=$("$SELF/fleet-conf.sh" --tailnet-ip "$PROJECT" 2>/dev/null) || IPS=""
else
  IPS=$("$SELF/fleet-conf.sh" --tailnet-ips 2>/dev/null) || IPS=""
fi
TARGETS=()
while IFS= read -r ip; do
  [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] && TARGETS+=("$ip")
done <<< "$IPS"
[ "${#TARGETS[@]}" -gt 0 ] || fail 1 "no box"

# The remote script names only validated words: the value comes on stdin.
REMOTE_HEAD='umask 077; H="${ENVELOPE_REMOTE_HARNESS:-/root/harness}"; . "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf "%s\n" "$1/env"; }; D=$(harness_env_dir "$H") || exit 2; mkdir -p "$D" || exit 2;'
if [ "$VENDOR" = claude ]; then
  REMOTE="$REMOTE_HEAD"' mkdir -p "$D/accounts.d" && t=$(mktemp "$D/accounts.d/.'"$LABEL"'.XXXXXX") && { printf "CLAUDE_CODE_OAUTH_TOKEN="; cat; echo; } > "$t" && chmod 600 "$t" && mv -f "$t" "$D/accounts.d/'"$LABEL"'.env"'
  WHAT="accounts.d/$LABEL.env"
else
  VUP=$(printf '%s' "$VENDOR" | tr '[:lower:]' '[:upper:]')
  if [ "$USE" = project ]; then
    NAME="${VUP}_API_KEY_$(printf '%s' "$LABEL" | tr '[:lower:].@-' '[:upper:]___')"; FILE="$PROJECT.env"; KEEP=0
  else
    NAME="${VUP}_API_KEY"; FILE=global.env; KEEP=1
  fi
  REMOTE="$REMOTE_HEAD"' f="$D/'"$FILE"'"; [ -e "$f" ] || : > "$f" || exit 2;'
  [ "$KEEP" = 1 ] && REMOTE="$REMOTE"' grep -q "^'"$NAME"'=" "$f" && exit 3;'
  REMOTE="$REMOTE"' t=$(mktemp "$D/.'"$FILE"'.XXXXXX") && { grep -v "^'"$NAME"'=" "$f"; [ $? -le 1 ] && printf "'"$NAME"'=" && cat && echo; } > "$t" && [ -s "$t" ] && chmod 600 "$t" && mv -f "$t" "$f" || { rm -f "$t"; exit 2; }'
  WHAT="$FILE $NAME"
fi

GOOD=0; BAD=()
for ip in "${TARGETS[@]}"; do
  printf '%s' "$VALUE" | ssh -o BatchMode=yes -o ConnectTimeout="$SSH_T" "root@$ip" "$REMOTE" >/dev/null 2>&1; SRC=$?
  if [ "$SRC" = 0 ]; then GOOD=$((GOOD + 1)); log "box $ip wrote $WHAT"
  elif [ "$SRC" = 3 ]; then BAD+=("$ip"); log "box $ip failed rc=3 (key exists; use Rotate)"
  else BAD+=("$ip"); log "box $ip failed rc=$SRC"; fi
done
VALUE=""
M=${#TARGETS[@]}

# ── 6. confirm last ───────────────────────────────────────────────────────────
if [ "${#BAD[@]}" = 0 ]; then
  confirm true "boxes=$GOOD/$M" || exit 75
  exit 0
fi
FAILED=$(IFS=,; printf '%s' "${BAD[*]}")
confirm false "boxes=$GOOD/$M failed=$FAILED" || exit 75
exit 4
