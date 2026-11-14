#!/bin/bash
# tests/cred-probe-api-key.bh-9676-test.sh — BH-9676 (C0): cred_probe claude
# and cred_account_fp claude read ANTHROPIC_API_KEY when no OAuth token is set
# (the order auth_fp_for_runner uses: OAuth token, then key, then login).
#
#   P1  OAuth token only            -> Bearer probe, as before
#   P2  OAuth token + key           -> Bearer probe; the key is not sent
#   P3  key only, 200 JSON          -> ALIVE, x-api-key sent, no Authorization
#   P4  key only, 401               -> DEAD 401
#   P5  key only, 403               -> DEAD 403
#   P6  key only, 429               -> INCONCLUSIVE   P6b 529 -> INCONCLUSIVE
#   P7  neither, no login file      -> INCONCLUSIVE no credential, curl not called
#   P8  cred_account_fp claude: OAuth > key > login file; a 16-hex hash
#   every case: the key value is in no stdout, stderr or curl sink.
# The fake curl on PATH records header NAMES only (never values): 0 network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/cred-probe.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/bin" "$T/home" "$T/tmp" "$T/login/.claude"
KEY="sk-ant-api""03-bh9676-probe-fixture"
TOK="sk-ant-oat""01-bh9676-probe-fixture"
LOGIN="sk-ant-oat""01-bh9676-login-fixture"
sha16() { printf '%s' "$1" | sha256sum | cut -c1-16; }

cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
o=""; w=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) o="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    -H) case "$2" in @*) sed 's/:.*//' "${2#@}" >> "$SINK" ;; *) printf '%s\n' "${2%%:*}" >> "$SINK" ;; esac; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf 'URL %s\n' "$url" >> "$SINK"
printf '%s' "${STUB_BODY-}" > "$o"
printf '%s' "${w//%\{http_code\}/${STUB_CODE:-200}}"
STUB
chmod +x "$T/bin/curl"

CLEAN=(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CONFIG_DIR -u OAUTH_USAGE_FETCH
       -u STUB_CODE -u STUB_BODY PATH="$T/bin:$PATH" HOME="$T/home" HARNESS="$T/h" TMPDIR="$T/tmp"
       SINK="$T/sink" ENDPOINT_ANTHROPIC=https://stub.invalid ENDPOINT_ANTHROPIC_OAUTH=https://stub.invalid)
probe() { # probe [VAR=val ...] -> OUT, ERR, RC
  : > "$T/sink"
  OUT=$("${CLEAN[@]}" "$@" bash -c '. "$1"; cred_probe claude' _ "$LIB" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
nokey() { # nokey <case>
  grep -qF "$KEY" <<<"$OUT$ERR" && bad "$1 the key reached stdout/stderr" || ok
  grep -qF "$KEY" "$T/sink" && bad "$1 the key reached the curl sink" || ok
}
has() { grep -qx "$2" "$T/sink" && ok || bad "$1 sink lacks '$2': $(tr '\n' ' ' < "$T/sink")"; }
hasnot() { grep -qx "$2" "$T/sink" && bad "$1 sink has '$2': $(tr '\n' ' ' < "$T/sink")" || ok; }

probe CLAUDE_CODE_OAUTH_TOKEN="$TOK" STUB_CODE=200 STUB_BODY='{"data":[]}'
[ "$OUT" = "ALIVE http 200" ] && [ "$RC" = 0 ] && ok || bad "P1 '$OUT' rc=$RC"
has P1 Authorization; has P1 anthropic-beta; hasnot P1 x-api-key; nokey P1

probe CLAUDE_CODE_OAUTH_TOKEN="$TOK" ANTHROPIC_API_KEY="$KEY" STUB_CODE=200 STUB_BODY='{"data":[]}'
[ "$OUT" = "ALIVE http 200" ] && ok || bad "P2 '$OUT' rc=$RC"
has P2 Authorization; hasnot P2 x-api-key; nokey P2

probe ANTHROPIC_API_KEY="$KEY" STUB_CODE=200 STUB_BODY='{"data":[]}'
[ "$OUT" = "ALIVE http 200" ] && [ "$RC" = 0 ] && ok || bad "P3 '$OUT' rc=$RC err=$ERR"
has P3 x-api-key; has P3 anthropic-version; hasnot P3 Authorization; hasnot P3 anthropic-beta
has P3 "URL https://stub.invalid/v1/models"; nokey P3

for cr in 401:DEAD:1 403:DEAD:1 429:INCONCLUSIVE:2 529:INCONCLUSIVE:2; do
  c=${cr%%:*}; rest=${cr#*:}; cls=${rest%%:*}; wrc=${rest#*:}
  probe ANTHROPIC_API_KEY="$KEY" STUB_CODE="$c" STUB_BODY='{"error":{}}'
  [ "$OUT" = "$cls${cls:+ }$( [ "$cls" = DEAD ] && echo "$c" || echo "http $c")" ] && [ "$RC" = "$wrc" ] \
    && ok || bad "P4-6 key $c -> '$OUT' rc=$RC (want $cls rc $wrc)"
  has "P4-6/$c" x-api-key; nokey "P4-6/$c"
done

probe
[ "$OUT" = "INCONCLUSIVE no credential" ] && [ "$RC" = 2 ] && ok || bad "P7 '$OUT' rc=$RC"
[ -s "$T/sink" ] && bad "P7 curl called with no credential" || ok

# P8 fingerprint order
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$LOGIN" > "$T/login/.claude/.credentials.json"
fp() { "${CLEAN[@]}" HOME="$T/login" "$@" bash -c '. "$1"; cred_account_fp claude' _ "$LIB" 2>&1; }
[ "$(fp CLAUDE_CODE_OAUTH_TOKEN="$TOK" ANTHROPIC_API_KEY="$KEY")" = "$(sha16 "$TOK")" ] && ok || bad "P8 OAuth must win"
out=$(fp ANTHROPIC_API_KEY="$KEY")
[ "$out" = "$(sha16 "$KEY")" ] && ok || bad "P8 key before login: '$out' want $(sha16 "$KEY")"
[[ "$out" =~ ^[0-9a-f]{16}$ ]] && ! grep -qF "$KEY" <<<"$out" && ok || bad "P8 not a hash: $out"
[ "$(fp)" = "$(sha16 "$LOGIN")" ] && ok || bad "P8 login last"

echo "cred-probe-api-key.bh-9676: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
