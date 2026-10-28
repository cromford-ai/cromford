#!/bin/bash
# shellcheck shell=bash
# bin/lib/envelope.sh — BH-7965 (BH-7937.2): the hub half of the secret
# envelope. Sourced by bin/envelope-keygen.sh, bin/envelope-consume.sh,
# bin/secrets-apply.sh and bin/lib/hub-probes/tracker-test.sh, never run.
# Doc: docs/SECRETS-ENVELOPE.md.
#
#   envelope_req <method> <path> [body-file] <out-file>
#       ONE request to the jobs worker with the main bearer AND the
#       x-envelope-hub-token header. The URL and both credentials ride in a
#       curl config on stdin (`-K -`), never on argv. The answer's payload goes
#       to <out-file>, the HTTP code to stdout ("000" = no answer). rc 0 when
#       the worker answered at all, 1 when the request could not be made (no
#       JOBS_URL, no HARNESS_SECRET, no ENVELOPE_HUB_TOKEN, a credential with a
#       quote, backslash or newline in it), 2 on a transport failure.
#   envelope_scope_parse <scope>
#       The scope grammar ai-account:<vendor>:<label>:<use_kind>[:<project>].
#       rc 0 prints "<vendor> <label> <use_kind> <project|->"; rc 1 prints one
#       fixed reason. `bin/fleet-conf.sh --projects` must list <project>
#       (ENVELOPE_FLEET_CONF_BIN names the script, the caller sets it).
#   envelope_decrypt <key-path>
#       Reads the base64 ciphertext on stdin and prints the plaintext, rc 0.
#       Tries <key-path>, then each <key-path>.<epoch> younger than the
#       settings row secret_envelope_ttl_s (60..86400, else 900), with
#       openssl pkeyutl RSA-OAEP SHA-256 (MGF1 SHA-256). rc 1 and no output
#       when no key opens it. ENVELOPE_NOW (epoch seconds) is the test clock.
#
# No function here prints a credential, a ciphertext or a secret value.

ENVELOPE_VENDORS="claude codex openrouter fireworks xai"

# A curl config value is a double-quoted string: refuse what would need escaping.
_envelope_cfg_ok() { case "$1" in *'"'*|*\\*|*$'\n'*|*$'\r'*) return 1 ;; esac; return 0; }

envelope_req() {
  local method="$1" path="$2" body="" out code rc
  if [ "$#" -ge 4 ]; then body="$3"; out="$4"; else out="$3"; fi
  [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || { printf '000'; return 1; }
  # Trimmed at both ends, the same rule the worker's hubTokenOk applies.
  local hub="${ENVELOPE_HUB_TOKEN:-}"
  hub="${hub#"${hub%%[![:space:]]*}"}"; hub="${hub%"${hub##*[![:space:]]}"}"
  [ -n "$hub" ] || { printf '000'; return 1; }
  _envelope_cfg_ok "$JOBS_URL$path" && _envelope_cfg_ok "$HARNESS_SECRET" && _envelope_cfg_ok "$hub" \
    || { printf '000'; return 1; }
  : > "$out"
  code=$({
    printf 'url = "%s%s"\n' "$JOBS_URL" "$path"
    printf 'request = "%s"\n' "$method"
    printf 'header = "authorization: Bearer %s"\n' "$HARNESS_SECRET"
    printf 'header = "x-envelope-hub-token: %s"\n' "$hub"
    if [ -n "$body" ]; then
      printf 'header = "content-type: application/json"\n'
      printf 'data-binary = "@%s"\n' "$body"
    fi
  } | curl -sS -m "${JOBS_TIMEOUT:-8}" -o "$out" -w '%{http_code}' -K - 2>/dev/null)
  rc=$?
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
  [ "$rc" -eq 0 ] && [ "$code" != 000 ] && return 0
  return 2
}

envelope_scope_parse() {
  local scope="${1:-}" kind vendor label use project rest
  case "$scope" in ai-account:*) ;; *) echo "not an ai-account scope"; return 1 ;; esac
  [[ "$scope" =~ ^ai-account:[a-z0-9._:@-]{1,96}$ ]] && [[ "$scope" != *..* ]] || { echo "scope format"; return 1; }
  rest="${scope#ai-account:}"
  IFS=: read -r vendor label use project kind <<< "$rest"
  [ -z "$kind" ] || { echo "scope has too many fields"; return 1; }
  [ -n "$vendor" ] && [ -n "$label" ] && [ -n "$use" ] || { echo "scope has too few fields"; return 1; }
  case " $ENVELOPE_VENDORS " in *" $vendor "*) ;; *) echo "unknown vendor"; return 1 ;; esac
  # A pasted key in the label slot: refuse before the charset check, so the
  # reason is the useful one.
  case "$label" in sk-*|sk_*|xai-*|fw_*|or-*) echo "label looks like a key"; return 1 ;; esac
  [ "${#label}" -le 48 ] || { echo "label looks like a key"; return 1; }
  [[ "$label" =~ ^[a-z0-9._@-]{1,48}$ ]] && [[ "$label" != .* ]] || { echo "label format"; return 1; }
  if command -v _pacct_label_ok >/dev/null 2>&1; then _pacct_label_ok "$label" || { echo "label format"; return 1; }; fi
  case "$use" in
    project)
      [ -n "$project" ] || { echo "project scope needs a project"; return 1; }
      [[ "$project" =~ ^[a-z0-9._-]+$ ]] && [[ "$project" != .* ]] || { echo "project format"; return 1; }
      [ -n "${ENVELOPE_FLEET_CONF_BIN:-}" ] && "$ENVELOPE_FLEET_CONF_BIN" --projects 2>/dev/null | grep -qxF -- "$project" \
        || { echo "unknown project"; return 1; } ;;
    pool|fallback)
      [ -z "$project" ] || { echo "only a project scope names a project"; return 1; }
      project=- ;;
    *) echo "unknown use kind"; return 1 ;;
  esac
  printf '%s %s %s %s\n' "$vendor" "$label" "$use" "$project"
}

envelope_decrypt() {
  local key="${1:-}" ct ttl now k ts out
  ct=$(cat)
  [ -n "$ct" ] && [ -n "$key" ] || return 1
  ttl=""
  declare -F setting_get >/dev/null 2>&1 && ttl=$(setting_get secret_envelope_ttl_s 2>/dev/null)
  [[ "$ttl" =~ ^[0-9]+$ ]] && [ "$ttl" -ge 60 ] && [ "$ttl" -le 86400 ] || ttl=900   # fallback of settings row secret_envelope_ttl_s
  now="${ENVELOPE_NOW:-$(date +%s)}"
  for k in "$key" "$key".*; do
    [ -r "$k" ] || continue
    if [ "$k" != "$key" ]; then
      ts="${k##*.}"; [[ "$ts" =~ ^[0-9]+$ ]] || continue
      [ $((now - ts)) -lt "$ttl" ] || continue
    fi
    if out=$(printf '%s' "$ct" | base64 -d 2>/dev/null | openssl pkeyutl -decrypt -inkey "$k" \
        -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 2>/dev/null) && [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  done
  return 1
}
