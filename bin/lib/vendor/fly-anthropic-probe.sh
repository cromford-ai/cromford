# shellcheck shell=bash
# owner: BH-9677
# bin/lib/vendor/fly-anthropic-probe.sh — the Fly-side Anthropic key probe
# seam (BH-9677, BH-9334.3). Sourced only: no output, no `set`, no trap.
#
# fly_anthropic_key_probe <app> <secret-name> <base-url> <curl-timeout-s> <ssh-timeout-s>
#   Runs ONE `fly ssh console -a <app> -q -C ...` on the app's machine. There a
#   short sh script reads the Fly secret <secret-name> from the machine env and
#   sends ONE `GET <base-url>/v1/models` with the x-api-key and
#   anthropic-version headers. The key goes to curl on stdin (`curl -K -`);
#   printf is a shell builtin, so the key is on no argv. The key never leaves
#   the machine: the script prints only the marker line
#   `KEYPROBE <http-code>` or `KEYPROBE nosecret`.
#   stdout  the marker value (`200`, `401`, ..., `nosecret`), rc 0
#   rc 1    no flyctl, a non-zero ssh rc, or no marker line in the output
#           (one stderr line with the ssh rc; never the command output)
#   rc 2    a bad argument or a bad vendor mode; no call
#   rc 70   fake mode and the app is not seeded
# Fake mode (HARNESS_VENDOR_FAKE=1): the answer is the seed
# <dir>/fly-anthropic-probe.json `{"key_probe":{"<app>":"<answer>"}}`; no call.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1
# shellcheck source=../fly-bin.sh
. "${BASH_SOURCE[0]%/*}/../fly-bin.sh" || return 1

fly_anthropic_key_probe() {
  local app="${1:-}" sec="${2:-}" base="${3:-}" cto="${4:-}" sto="${5:-}"
  local mode out rc fly script line v=""
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { echo "fly-anthropic-probe: bad app name '$app'" >&2; return 2; }
  [[ "$sec" =~ ^ANTHROPIC_API_KEY_[A-Z0-9_]+$ ]] || { echo "fly-anthropic-probe: bad secret name '$sec'" >&2; return 2; }
  [[ "$base" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?$ ]] || { echo "fly-anthropic-probe: bad base URL '$base'" >&2; return 2; }
  [[ "$cto" =~ ^[0-9]+$ && "$sto" =~ ^[0-9]+$ ]] || { echo "fly-anthropic-probe: bad timeouts '$cto' '$sto'" >&2; return 2; }
  base="${base%/}"
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    out=$(vendor_fake fly-anthropic-probe key_probe "$app") || return 70
    jq -r . <<<"$out"
    return 0
  fi
  fly=$(fly_bin) || { echo "fly-anthropic-probe: no flyctl on this box" >&2; return 1; }
  # Only double quotes inside: the whole script rides in single quotes, and
  # every value in it passed a regex above that admits no quote.
  script="k=\$(printenv $sec); [ -n \"\$k\" ] || { echo \"KEYPROBE nosecret\"; exit 0; };"
  script+=" c=\$(printf \"header = \\\"x-api-key: %s\\\"\\nheader = \\\"anthropic-version: 2023-06-01\\\"\\nurl = \\\"%s/v1/models\\\"\\n\" \"\$k\" \"$base\""
  script+=" | curl -sS -o /dev/null -w \"%{http_code}\" -m $cto -K - 2>/dev/null); echo \"KEYPROBE \${c:-000}\""
  vendor_call_log fly-anthropic-probe key-probe
  rc=0
  out=$(timeout "$sto" "$fly" ssh console -a "$app" -q -C "/bin/sh -c '$script'" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "fly-anthropic-probe: fly ssh console -a $app exited $rc" >&2
    return 1
  fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^KEYPROBE\ ([0-9]{3}|nosecret)$ ]]; then v="${BASH_REMATCH[1]}"; break; fi
  done <<<"$out"
  if [ -z "$v" ]; then
    echo "fly-anthropic-probe: fly ssh console -a $app printed no KEYPROBE line (rc 0)" >&2
    return 1
  fi
  printf '%s\n' "$v"
}
