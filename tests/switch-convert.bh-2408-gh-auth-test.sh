#!/bin/bash
# tests/switch-convert.bh-2408-gh-auth-test.sh — BH-2441 (BH-2408 slice 2): the
# GitHub App token/auth kill switches and lane-reaper's are read by lane_switch,
# so a `switch.<name>[.<box>]` settings row settles them before the file does.
#
# Seven reads of four switches, each driven through the REAL script or lib:
#   1 gh_app_default_token (bin/lib/gh-app-default.sh)   gh-app-default-off
#   2 triage-map.sh render's gh probe                    gh-app-default-off
#   3 gh_rotate_armed (bin/fly-pool.sh, block verbatim)  gh-app-rotate-off
#   4 bin/gh-token.sh's CLI (killed)                     gh-app-tokens-off
#   5 gh_auth_armed (bin/lib/gh-app-auth.sh)             gh-app-tokens-off
#   6 gh_token_live (bin/lib/gh-token-live.sh)           gh-app-tokens-off
#   7 bin/lane-reaper.sh, by bash -x trace               lane-reaper-off
# For each k:
#   Rk row switch.<n>=1, no file          -> switched off;
#   Fk row switch.<n>=0 + flags/<n>       -> runs, one `flags/<n> ignored` line;
#   Lk no rows: file -> off, no file      -> runs (what the file answered before).
#   B1 switch.lane-reaper-off.hub-1=1 stops lane-reaper on hub-1, .otherbox=1 does not.
#   N3 a gh-app-rotate-off row leaves gh_auth_armed alone.
#   C1 every `lane_switch <literal>` in the seven files has its catalog file,
#      whose readers name the file; O1 each file's lowest switch sorts into g-o;
#   X1 nothing in bin/ fly/ worker/ console-ui/src writes these four flags.
# Run from anywhere: tests/switch-convert.bh-2408-gh-auth-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/switch-convert-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "switch-convert.bh-2408-gh-auth: jq missing — skipping"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "switch-convert.bh-2408-gh-auth: openssl missing — skipping (bin/gh-token.sh needs it)"; exit 0; }

sc_harness "$T/h" || { echo "FAIL: sc_harness"; exit 1; }
H="$SC_ROOT"
mkdir -p "$H/env" "$T/fakebin" "$H/state/gh-app-tokens" "$H/locks"
cp "$DIR/bin/lib/gh-app-default.sh" "$H/bin/lib/"

# A throwaway App key: bin/gh-token.sh signs a JWT with it before any curl.
openssl genrsa -out "$H/env/github-app.pem" 2048 2>/dev/null; chmod 600 "$H/env/github-app.pem"
printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$H" > "$H/env/github-app.env"

# $H/bin/gh-token.sh — the stub gh_app_default_token forks; it records each call.
cat > "$H/bin/gh-token.sh" <<SH
#!/bin/bash
echo "gh-token \$*" >> "$T/mints"
printf 'ghs_stubmint\n'
SH
chmod +x "$H/bin/gh-token.sh"

# curl for the real bin/gh-token.sh (site 4): logs every URL, answers a mint.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; while [ $# -gt 0 ]; do case "$1" in -H|-d|-X) shift 2 ;; -sS|-s|-S) shift ;; *) URL="$1"; shift ;; esac; done
echo "$URL" >> "$CURL_LOG"
case "$URL" in
  */app/installations) printf '[{"id":4242,"account":{"login":"TestOwner"}}]\n' ;;
  */access_tokens) printf '{"token":"ghs_realmint","expires_at":"%s"}\n' "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  *) echo '{}' ;;
esac
SH
# gh: `auth token` says "not logged in" (exit 1, triage-map's probe) and
# `api repos/...` answers (gh-token.sh's PAT fallback checks the PAT sees it).
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in api\ repos/*) exit 0 ;; esac
exit 1
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export CURL_LOG="$T/curl.log"

# reset — a clean case: no flags, no cache, no throttle, no call logs.
reset() {
  local p
  for p in state/lane-gate logs/lane-gate.log state/settings-cache.json \
           state/gh-app-tokens state/gh-app-default.knobs state/gh-app-default.alerted; do
    scratch_rm "$H/$p" || exit 1
  done
  rm -f "$H/flags"/*
  mkdir -p "$H/state/gh-app-tokens"
  : > "$CALLS"; : > "$T/mints"; : > "$CURL_LOG"
}

# --- the seven observers: each prints `off` or `run` ---------------------------
site1() {  # gh_app_default_token: rc 1 with no fork = off; the minted token = run
  local out
  out=$(env HARNESS="$H" HARNESS_ENV_DIR="$H/env" bash -c '
    set -uo pipefail
    . "$1" || exit 9
    gh_app_default_token example-org/x; echo " rc=$?"' _ "$DIR/bin/lib/gh-app-default.sh" 2>/dev/null)
  if [ "$out" = " rc=1" ] && [ ! -s "$T/mints" ]; then echo off
  elif [ "$out" = "ghs_stubmint rc=0" ] && [ -s "$T/mints" ]; then echo run
  else echo "odd($out|mints=$(wc -l < "$T/mints"))"; fi
}
site2() {  # triage-map render: gh says not logged in, so the App route decides
  local out
  out=$(env HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$DIR/tests/fixtures/fleet-map.conf" \
        PATH="$T/fakebin:$PATH" "$DIR/bin/triage-map.sh" render 2>/dev/null | grep -E '^  (CAN|CANNOT|UNKNOWN): gh ')
  case "$out" in
    "  CANNOT: gh "*) echo off ;;
    "  CAN: gh "*) echo run ;;
    *) echo "odd($out)" ;;
  esac
}
# gh_rotate_armed, verbatim from bin/fly-pool.sh: the function plus the line
# above it (the loader), dropped into $H/bin so that loader resolves $H/bin/lib.
FP_N=$(grep -n '^gh_rotate_armed() {' "$DIR/bin/fly-pool.sh" | cut -d: -f1)
awk -v s="$((FP_N - 1))" -v n="$FP_N" 'NR >= s && (NR < n || !d) { print } NR >= n && /^}/ { d = 1 }' \
  "$DIR/bin/fly-pool.sh" > "$H/bin/fp-rotate.sh"
grep -q '^gh_rotate_armed() {' "$H/bin/fp-rotate.sh" && ok || bad "3 no gh_rotate_armed() in bin/fly-pool.sh"
site3() {
  local out
  out=$(env HARNESS="$H" bash -c '
    set -uo pipefail
    gh_auth_armed() { return 0; }
    . "$1" || exit 9
    gh_rotate_armed; echo "rc=$?"' _ "$H/bin/fp-rotate.sh" 2>/dev/null)
  case "$out" in rc=1) echo off ;; rc=0) echo run ;; *) echo "odd($out)" ;; esac
}
site4() {  # bin/gh-token.sh CLI: killed prints the PAT with no request; else it mints
  local out
  out=$(env HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$T/fakebin:$PATH" GH_APP_API_BASE=http://api.test \
        GH_TOKEN=pattok "$DIR/bin/gh-token.sh" TestOwner/x 2>/dev/null)
  if [ "$out" = pattok ] && ! grep -q access_tokens "$CURL_LOG"; then echo off
  elif [ "$out" = ghs_realmint ] && grep -q access_tokens "$CURL_LOG"; then echo run
  else echo "odd($out|curl=$(wc -l < "$CURL_LOG"))"; fi
}
site5() {  # gh_auth_armed rc
  local out
  out=$(env HARNESS="$H" bash -c '
    set -uo pipefail
    . "$1" || exit 9
    gh_auth_armed; echo "rc=$?"' _ "$DIR/bin/lib/gh-app-auth.sh" 2>/dev/null)
  case "$out" in rc=1) echo off ;; rc=0) echo run ;; *) echo "odd($out)" ;; esac
}
printf 'ghs_livefile\n' > "$T/live"
site6() {  # gh_token_live rc + the GH_TOKEN it exports
  local out
  out=$(env -u GH_TOKEN HARNESS="$H" GH_TOKEN_LIVE_FILE="$T/live" bash -c '
    set -uo pipefail
    . "$1" || exit 9
    gh_token_live; echo "rc=$? tok=${GH_TOKEN:-none}"' _ "$DIR/bin/lib/gh-token-live.sh" 2>/dev/null)
  case "$out" in "rc=1 tok=none") echo off ;; "rc=0 tok=ghs_livefile") echo run ;; *) echo "odd($out)" ;; esac
}
LR_LINE=$(grep -n 'lane_switch lane-reaper-off' "$DIR/bin/lane-reaper.sh" | grep -v ':[[:space:]]*#' | head -1 | cut -d: -f1)
# A function sourced from another file (lane_switch, the lane gate) is traced
# with ITS file's line numbers, which run past any line of lane-reaper.sh, so
# sc_trace's trace cannot tell "stopped at the read" from "ran on". This trace
# tags every line with its source file (PS4 set through BASH_ENV, as sc_trace
# does, because bash ignores an inherited PS4 as root) and keeps lane-reaper.sh's
# own lines, in sc_trace's `+N: ` shape, for sc_trace_past.
printf '%s\n' "PS4='+\${BASH_SOURCE[0]##*/}|\${LINENO}: '" > "$T/.lr-ps4"
site7() {  # lane-reaper: does the trace run past the switch read?
  local rc
  HARNESS="$H" BASH_ENV="$T/.lr-ps4" bash -x "$DIR/bin/lane-reaper.sh" >/dev/null 2> "$T/lr.trace"
  sed -n 's/^\(+*\)lane-reaper\.sh|\([0-9]*: \)/\1\2/p' "$T/lr.trace" > "$T/lr.own"
  sc_trace_past "$T/lr.own" "${LR_LINE:-}" 2>/dev/null; rc=$?
  case "$rc" in 1) echo off ;; 0) echo run ;; *) echo "odd(trace rc $rc, line '${LR_LINE:-}')" ;; esac
}

NAMES=(- gh-app-default-off gh-app-default-off gh-app-rotate-off gh-app-tokens-off gh-app-tokens-off gh-app-tokens-off lane-reaper-off)
for k in 1 2 3 4 5 6 7; do
  n=${NAMES[$k]}
  # Rk — the row alone switches it off.
  reset; sc_rows "switch.$n=1"
  eq "R$k switch.$n=1, no file" "$(site$k)" off
  # Fk — row 0 beats the file, and says so once.
  reset; sc_rows "switch.$n=0"; touch "$H/flags/$n"
  eq "F$k switch.$n=0 + flags/$n" "$(site$k)" run
  eq "F$k one 'flags/$n ignored' line" "$(sc_ignored_lines "$H" "$n")" 1
  # Lk — no rows: the file answers exactly as before.
  reset; sc_rows; touch "$H/flags/$n"
  eq "L$k no rows + flags/$n" "$(site$k)" off
  reset; sc_rows
  eq "L$k no rows, no file" "$(site$k)" run
done

# N3 — the rotate switch is not the tokens switch.
reset; sc_rows switch.gh-app-rotate-off=1
eq "N3 switch.gh-app-rotate-off=1 leaves gh_auth_armed armed" "$(site5)" run

# B1 — the box dimension (JOBS_BOX=hub-1 from the fixture).
reset; sc_rows switch.lane-reaper-off.hub-1=1
eq "B1 switch.lane-reaper-off.hub-1=1 on hub-1" "$(site7)" off
reset; sc_rows switch.lane-reaper-off.otherbox=1
eq "B1 switch.lane-reaper-off.otherbox=1 on hub-1" "$(site7)" run

# --- registry -----------------------------------------------------------------
FILES=(bin/lib/gh-app-default.sh bin/triage-map.sh bin/fly-pool.sh bin/gh-token.sh
       bin/lib/gh-app-auth.sh bin/lib/gh-token-live.sh bin/lane-reaper.sh)
for f in "${FILES[@]}"; do
  sw=$(grep -vE '^[[:space:]]*#' "$DIR/$f" | grep -oE 'lane_switch [a-z0-9_-]+' | awk '{print $2}' | sort -u)
  [ -n "$sw" ] && ok || bad "C1 $f reads no switch through lane_switch"
  for n in $sw; do
    c="$DIR/catalog/switches.d/$n.json"
    eq "C1 $f: catalog/switches.d/$n.json name" "$(jq -r '.name // empty' "$c" 2>/dev/null)" "$n"
    jq -e --arg f "$f" '.readers | index($f)' "$c" >/dev/null 2>&1 && ok || bad "C1 catalog/switches.d/$n.json readers lack $f"
  done
  first=$(head -1 <<<"$sw")
  case "$first" in [g-o]*) ok ;; *) bad "O1 $f: lowest switch '$first' is outside g-o" ;; esac
done
for n in gh-app-default-off gh-app-rotate-off gh-app-tokens-off lane-reaper-off; do
  c="$DIR/catalog/switches.d/$n.json"
  jq -e '(.box_scoped == true) and (.what | type == "string" and length > 0) and (.readers == (.readers | sort))' "$c" >/dev/null 2>&1 \
    && ok || bad "C1 $c: box_scoped, a what and sorted readers"
done
X=$(cd "$DIR" && grep -rnE '(touch|rm|>|flag_set|flag_clear)[^#]*flags/(gh-app-default-off|gh-app-rotate-off|gh-app-tokens-off|lane-reaper-off)' \
      bin fly worker console-ui/src 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '(echo|say|printf) ')
[ -z "$X" ] && ok || bad "X1 a writer of this slice's flags: $X"

echo "switch-convert.bh-2408-gh-auth: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
