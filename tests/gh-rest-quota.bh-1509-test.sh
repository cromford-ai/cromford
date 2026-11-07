#!/bin/bash
# tests/gh-rest-quota.bh-1509-test.sh — BH-1509 S-10: the App quota bucket is
# keyed by INSTALLATION ID, and the fleet push sends the bucket it found.
#
# WHY. BH-1484 keyed the App meter as one flat `app`, on the true-at-the-time
# reading that the whole fleet runs under ONE installation. Two installations
# (the hub's 161623167 and the Cromford Board App's 163842147) are two
# separate 6,600/h buckets, and a reading filed under `app` by one box is then
# rendered as the other box's headroom. So the bucket name carries the id:
# `app-<installation id>`.
#
#   1. bin/gh-token.sh records the installation id it minted for, in the token
#      cache JSON beside the token itself (`installation_id`).
#   2. gh_quota_bucket resolves a `ghs_` token to its installation by matching
#      the token value against those cache rows, and falls back to the legacy
#      `app` on ANY miss — an unarmed box, a token minted before this change, no
#      cache dir at all. A miss is never empty and never a non-zero rc: the
#      per-call observe hook runs under the caller's `set -e`.
#   3. bin/fleet-status-push.sh picks the App bucket FILE by name rather than
#      asking for `app`, and pushes whatever bucket that file belongs to.
#
# Nothing here touches the network: `gh` is the same replay stub the parent
# suite uses and the token cache is a fixture file.
# Run from anywhere: bash tests/gh-rest-quota.bh-1509-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/gh-rest.sh"
LEDLIB="$DIR/bin/lib/gh-rest-ledger.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The two REAL installation ids from the ticket body, not invented ones.
HUB_INST=161623167
BOARD_INST=163842147

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/tmp" "$T/bin" "$T/fx"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T"
export GH_ETAG=0

cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
f=$(find "$D/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
rc=0
[ -f "$f.rc" ] && rc=$(cat "$f.rc")
cat "$f"
rm -f "$f" "$f.rc"
exit "$rc"
STUB
chmod +x "$T/bin/gh"

FXN=0
fx() { # fx <status> <remaining> <limit> <reset> [body]
  FXN=$((FXN + 1))
  local f rc
  f="$T/fx/$(printf '%02d' "$FXN")"
  { printf 'HTTP/2.0 %s Status\r\n' "$1"
    printf 'x-ratelimit-remaining: %s\r\n' "$2"
    printf 'X-RateLimit-Limit: %s\r\n' "$3"
    printf 'x-ratelimit-reset: %s\r\n' "$4"
    printf '\r\n'
    printf '%s' "${5:-}"
  } > "$f"
  case "$1" in 2*|304) rc=0 ;; *) rc=1 ;; esac
  printf '%s' "$rc" > "$f.rc"
}
reset() { rm -rf "$T/fx"; mkdir -p "$T/fx"; FXN=0; rm -f "$T/gh-calls.txt" "$T/out"; }
# The recursive rm names its path literally so checks/tests-scratch-only can see
# it lives inside the scratch tree.
ledreset() { rm -rf "$T/h/state/gh-rest-ledger"; mkdir -p "$T/h/state/gh-rest-ledger"; }
cachereset() { rm -rf "$T/h/state/gh-app-tokens"; mkdir -p "$T/h/state/gh-app-tokens"; }
# cacherow <slug> <token> [installation_id] — the shape bin/gh-token.sh writes.
cacherow() {
  local f="$T/h/state/gh-app-tokens/$1.json"
  if [ -n "${3:-}" ]; then
    jq -n --arg s "$1" --arg t "$2" --arg i "$3" \
      '{repo:$s,token:$t,expires_at:"2030-01-01T00:00:00Z",minted_at:"2026-09-22 22:00:00Z",installation_id:$i}' > "$f"
  else
    jq -n --arg s "$1" --arg t "$2" \
      '{repo:$s,token:$t,expires_at:"2030-01-01T00:00:00Z",minted_at:"2026-09-22 22:00:00Z"}' > "$f"
  fi
}

. "$LIB" || { echo "could not source $LIB"; exit 1; }

# ══ a. a ghs_ token whose cache row names an installation ═══════════════════
ledreset; cachereset; reset
cacherow 'example-org-cromford' ghs_x "$BOARD_INST"
B=$(GH_TOKEN=ghs_x gh_quota_bucket)
[ "$B" = "app-$BOARD_INST" ] && ok || bad "a1: a cached ghs_ token keys app-$BOARD_INST, got '$B'"
# And the WRITE path uses it: the reading file and the ledger column, not a
# hand call to the helper.
fx 200 4000 6600 1790000000 '{"ok":true}'
GH_TOKEN=ghs_x gh_rest GET repos/o/r/pulls > "$T/out"; rc=$?
[ "$rc" = 0 ] && ok || bad "a2: the read must still succeed, got rc $rc"
if [ -r "$T/h/state/gh-rest-ledger/.quota-app-$BOARD_INST" ]; then ok
else bad "a3: the reading must be written to .quota-app-$BOARD_INST, got: $(ls -a "$T/h/state/gh-rest-ledger")"; fi
LINE=$(cat "$T/h/state/gh-rest-ledger"/*.tsv 2>/dev/null | sed -n 1p)
[ "$(printf '%s' "$LINE" | cut -f10)" = "app-$BOARD_INST" ] && ok \
  || bad "a4: ledger column 10 must be app-$BOARD_INST, got '$(printf '%s' "$LINE" | cut -f10)'"
# The reading is readable back under its own name, which is what the gate does.
_GHQ_BKT_MEMO_KEY= GH_TOKEN=ghs_x _gh_quota_read
[ "${_GHQ_BUCKET:-}" = "app-$BOARD_INST" ] && [ "${_GHQ_REM:-}" = 4000 ] && ok \
  || bad "a5: the gate must read back its own bucket, got '${_GHQ_BUCKET:-}'/'${_GHQ_REM:-}'"

# A SECOND installation on the same box is a second file, never the same one.
ledreset; reset
cacherow 'example-org-hub' ghs_h "$HUB_INST"
fx 200 5000 6600 1790000000 '{"ok":true}'
_GHQ_BKT_MEMO_KEY= GH_TOKEN=ghs_h gh_rest GET repos/o/r/pulls > /dev/null
if [ -r "$T/h/state/gh-rest-ledger/.quota-app-$HUB_INST" ]; then ok
else bad "a6: a second installation gets its own bucket file, got: $(ls -a "$T/h/state/gh-rest-ledger")"; fi

# ══ b. a ghs_ token with no matching cache row falls back to `app` ══════════
B=$(_GHQ_BKT_MEMO_KEY= GH_TOKEN=ghs_nosuch gh_quota_bucket)
[ "$B" = app ] && ok || bad "b1: an unknown ghs_ token keeps the legacy 'app', got '$B'"

# ══ c. a cache row with no installation_id (minted before this change) ══════
cachereset
cacherow 'example-org-old' ghs_old
B=$(_GHQ_BKT_MEMO_KEY= GH_TOKEN=ghs_old gh_quota_bucket)
[ "$B" = app ] && ok || bad "c1: a pre-BH-1509 cache row keeps 'app', got '$B'"
# A non-numeric id never becomes part of a filename.
cacherow 'example-org-junk' ghs_junk '../../etc/passwd'
B=$(_GHQ_BKT_MEMO_KEY= GH_TOKEN=ghs_junk gh_quota_bucket)
[ "$B" = app ] && ok || bad "c2: a non-numeric installation id falls back to 'app', got '$B'"

# ══ d. no cache directory at all (an unarmed box) ═══════════════════════════
rm -rf "$T/h/state/gh-app-tokens"
B=$(_GHQ_BKT_MEMO_KEY= GH_TOKEN=ghs_x gh_quota_bucket)
[ "$B" = app ] && ok || bad "d1: an absent token cache falls back to 'app', got '$B'"
# PAT buckets are untouched by any of this.
[ "$(GH_TOKEN= gh_quota_bucket)" = pat-default ] && ok || bad "d2: an empty GH_TOKEN is still pat-default"
P=$(_GHQ_BKT_MEMO_KEY= GH_TOKEN=ghp_abc gh_quota_bucket)
case "$P" in pat-????????????) ok ;; *) bad "d3: a PAT is still pat-<sha12>, got '$P'" ;; esac

# ══ e. memoised per token: a second call needs no cache read ════════════════
cachereset
cacherow 'example-org-cromford' ghs_x "$BOARD_INST"
E=$(
  export GH_TOKEN=ghs_x
  _GHQ_BKT_MEMO_KEY=; _GHQ_BKT_MEMO_VAL=
  gh_quota_bucket > /dev/null
  chmod 000 "$T/h/state/gh-app-tokens" 2>/dev/null
  gh_quota_bucket
)
chmod 700 "$T/h/state/gh-app-tokens" 2>/dev/null
[ "$E" = "app-$BOARD_INST" ] && ok || bad "e1: the second call must answer from the memo, got '$E'"
# The memo keys on the TOKEN, not on the process: merge-sweep swaps GH_TOKEN per
# repo inside one shell, and a stale memo would file the second repo's reading
# under the first installation.
E2=$(
  _GHQ_BKT_MEMO_KEY=; _GHQ_BKT_MEMO_VAL=
  GH_TOKEN=ghs_x gh_quota_bucket > /dev/null
  cacherow 'example-org-hub' ghs_h "$HUB_INST"
  GH_TOKEN=ghs_h gh_quota_bucket
)
[ "$E2" = "app-$HUB_INST" ] && ok || bad "e2: switching GH_TOKEN must re-key the bucket, got '$E2'"

# ══ f. rc 0 under errexit, cache dir absent (the §6 contract) ══════════════
rm -rf "$T/h/state/gh-app-tokens"
cat > "$T/errexit.sh" <<EOS
set -euo pipefail
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/bin:\$PATH" GH_STUB_DIR="$T" GH_ETAG=0
export GH_TOKEN=ghs_x
. "$LEDLIB"
b=\$(gh_quota_bucket)
[ "\$b" = app ] || { echo "WRONG:\$b"; exit 9; }
echo SURVIVED
EOS
OUTE=$(bash "$T/errexit.sh" 2>/dev/null); rce=$?
[ "$OUTE" = SURVIVED ] && [ "$rce" = 0 ] && ok \
  || bad "f1: gh_quota_bucket under set -e with no cache must survive, got '$OUTE' rc $rce"

# ══ g. no token value leaks into the ledger or the logs ════════════════════
if [ "$(grep -rl 'ghs_x' "$T/h/state/gh-rest-ledger" "$T/h/logs" 2>/dev/null | wc -l | tr -d ' ')" = 0 ]; then ok
else bad "g1: a token value reached the ledger or the logs: $(grep -rl 'ghs_x' "$T/h/state/gh-rest-ledger" "$T/h/logs" 2>/dev/null)"; fi
if [ "$(ls -a "$T/h/state/gh-rest-ledger" | grep -c 'ghs_')" = 0 ]; then ok
else bad "g2: a token value reached a filename: $(ls -a "$T/h/state/gh-rest-ledger")"; fi

# ══ h. the mint records the installation id it used ════════════════════════
# The real bin/gh-token.sh, against the same throwaway-key + stubbed-curl
# fixture shape tests/gh-token-test.sh uses.
if command -v openssl >/dev/null 2>&1; then
  mkdir -p "$T/g/bin/lib" "$T/g/env" "$T/g/logs" "$T/g/state" "$T/g/locks" "$T/g/fakebin"
  cp "$DIR/bin/gh-token.sh" "$T/g/bin/"; chmod +x "$T/g/bin/gh-token.sh"
  cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$T/g/bin/lib/" 2>/dev/null
  [ -r "$DIR/bin/lib/env-path.sh" ] && cp "$DIR/bin/lib/env-path.sh" "$T/g/bin/lib/"
  openssl genrsa -out "$T/g/env/github-app.pem" 2048 2>/dev/null
  chmod 600 "$T/g/env/github-app.pem"
  printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s/g/env/github-app.pem\n' "$T" \
    > "$T/g/env/github-app.env"
  cat > "$T/g/fakebin/curl" <<'SH'
#!/bin/bash
URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;;
    -d) shift 2 ;;
    -X) shift 2 ;;
    -sS|-s|-S) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in
  */access_tokens)
    printf '{"token":"ghs_minted_1","expires_at":"%s"}\n' "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  */rate_limit) printf '{"rate":{"remaining":4996,"limit":5000}}\n' ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$T/g/fakebin/curl"
  TOKM=$(env PATH="$T/g/fakebin:$PATH" HARNESS="$T/g" GH_APP_API_BASE="http://api.test" \
          GH_APP_INSTALLATION_EXAMPLE_ORG="$BOARD_INST" GH_TOKEN=pattok \
          "$T/g/bin/gh-token.sh" example-org/cromford 2>/dev/null)
  [ "$TOKM" = ghs_minted_1 ] && ok || bad "h1: the fixture mint must print its token, got '$TOKM'"
  CF="$T/g/state/gh-app-tokens/example-org-cromford.json"
  GOTID=$(jq -r '.installation_id // empty' "$CF" 2>/dev/null)
  [ "$GOTID" = "$BOARD_INST" ] && ok \
    || bad "h2: the cache must record installation_id=$BOARD_INST, got '$GOTID' from $(cat "$CF" 2>/dev/null)"
  # And the ledger then keys that minted token by the id the mint recorded — the
  # two halves joined, through the real files both sides use.
  BM=$(HARNESS="$T/g" _GHQ_BKT_MEMO_KEY= GH_TOKEN=ghs_minted_1 gh_quota_bucket)
  [ "$BM" = "app-$BOARD_INST" ] && ok \
    || bad "h3: a freshly minted token must key app-$BOARD_INST, got '$BM'"
else
  echo "openssl missing — skipping the mint cases (h)"
fi

# ══ i. the fleet push sends the App bucket FILE it found ═══════════════════
mkdir -p "$T/p/bin/lib" "$T/p/logs" "$T/p/state" "$T/p/flags" "$T/p/env" "$T/p/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/p/bin/"
for f in gh-rest-ledger.sh box-id.sh; do
  [ -r "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$T/p/bin/lib/"
done
printf 'HARNESS_SECRET=test-secret\nCONSOLE_URL=http://console.invalid\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/p/env/global.env"
cp "$DIR/bin/lib/watchdog-url.sh" "$T/p/bin/lib/"
printf '#!/bin/bash\nprintf %%s "$1" > %s/p/BEAT.json\n' "$T" > "$T/p/bin/beat.sh"
chmod +x "$T/p/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/p/PUSH.json\n' "$T" > "$T/p/fakebin/curl"
chmod +x "$T/p/fakebin/curl"
sed "s|^H=/root/harness|H=$T/p|" "$DIR/bin/fleet-status-push.sh" > "$T/p/fsp.sh"
cat > "$T/p/fleet.conf" <<'CONF'
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
CONF
QD="$T/p/state/gh-rest-ledger"
# HARNESS is exported at the top of this file for the ledger cases, and the push
# reads it as an override of its own H — so it is pointed at the push fixture
# here explicitly rather than inherited from the wrong tree.
prun() { rm -f "$T/p/PUSH.json" "$T/p/BEAT.json"
         ( cd "$T/p" && PATH="$T/p/fakebin:$PATH" HARNESS="$T/p" GH_TOKEN= \
             bash "$T/p/fsp.sh" >/dev/null 2>&1 ); }
pq() { jq -r "$1" "$T/p/PUSH.json" 2>/dev/null; }
NOWP=$(date -u +%s)
FUTURE=$((NOWP + 1800))
PAST=$((NOWP - 1800))

# An installation-keyed reading is pushed under its own name.
rm -rf "$T/p/state/gh-rest-ledger"; mkdir -p "$QD"
printf '%s 6600 %s %s\n' 4321 "$FUTURE" "$NOWP" > "$QD/.quota-app-$BOARD_INST"
printf '%s 6600 %s %s\n' 11 "$PAST" "$PAST" > "$QD/.quota-app"
prun
BK=$(pq '.gh_rest_quota | to_entries[0].value.gh_quota_bucket')
RM=$(pq '.gh_rest_quota | to_entries[0].value.gh_quota_remaining')
[ "$BK" = "app-$BOARD_INST" ] && ok \
  || bad "i1: the push must name the installation bucket, got '$BK' ($(pq '.gh_rest_quota|tojson'))"
[ "$RM" = 4321 ] && ok || bad "i2: and carry its own remaining, got '$RM'"

# Legacy only: unchanged behaviour, the flat `app`.
rm -rf "$T/p/state/gh-rest-ledger"; mkdir -p "$QD"
printf '%s 6600 %s %s\n' 999 "$FUTURE" "$NOWP" > "$QD/.quota-app"
prun
[ "$(pq '.gh_rest_quota | to_entries[0].value.gh_quota_bucket')" = app ] && ok \
  || bad "i3: with only a legacy reading the push still says 'app', got '$(pq '.gh_rest_quota|tojson')'"
[ "$(pq '.gh_rest_quota | to_entries[0].value.gh_quota_remaining')" = 999 ] && ok \
  || bad "i4: legacy remaining must survive, got '$(pq '.gh_rest_quota|tojson')'"

# No reading at all: ABSENT, never null and never zero.
rm -rf "$T/p/state/gh-rest-ledger"; mkdir -p "$QD"
prun
[ "$(pq '.gh_rest_quota')" = '{}' ] && ok \
  || bad "i5: no reading must push no gh_quota_* keys, got '$(pq '.gh_rest_quota|tojson')'"

# A STALE installation reading is an unknown too — not a 4321 from last window.
rm -rf "$T/p/state/gh-rest-ledger"; mkdir -p "$QD"
printf '%s 6600 %s %s\n' 4321 "$PAST" "$PAST" > "$QD/.quota-app-$BOARD_INST"
prun
[ "$(pq '.gh_rest_quota')" = '{}' ] && ok \
  || bad "i6: a reading past its reset must not be pushed, got '$(pq '.gh_rest_quota|tojson')'"

# Two fresh installation readings: the FRESHEST one is the box's own spend.
rm -rf "$T/p/state/gh-rest-ledger"; mkdir -p "$QD"
printf '%s 6600 %s %s\n' 100 "$FUTURE" "$((NOWP - 600))" > "$QD/.quota-app-$HUB_INST"
printf '%s 6600 %s %s\n' 200 "$FUTURE" "$NOWP" > "$QD/.quota-app-$BOARD_INST"
prun
[ "$(pq '.gh_rest_quota | to_entries[0].value.gh_quota_bucket')" = "app-$BOARD_INST" ] && ok \
  || bad "i7: the freshest App reading wins, got '$(pq '.gh_rest_quota|tojson')'"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
