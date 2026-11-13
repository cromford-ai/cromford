#!/bin/bash
# tests/triage-gh-session-arm.bh-9354-test.sh — the triage tick arms the
# session gh wrapper (BH-9354), and only when it should.
#
#   M1 bin/run-triage.sh's arm line, extracted from the shipped driver and run
#      after a tick armed a ghs_ App token, puts bin/gh-session first on PATH
#   M2 the line sits after `# <<< triage github auth`, outside the block
#      tests/triage-gh-app-token-test.sh extracts verbatim
#   M3 GH_SESSION_SLUG / _PROJECT / _TOKEN_FP / _ARMED_AT / _EXPIRES_AT are
#      set, the fingerprint is not the token, and the knob defaults reach the env
#   M4 armed twice = one PATH entry
#   M5 not armed: a PAT in GH_TOKEN, GH_SESSION_REMINT=0 (the knob row is the
#      off switch), an empty GH_TOKEN (env untouched: no PATH entry, no
#      GH_SESSION_SLUG)
# Nothing touches the network: bin/gh-token.sh is a stub.
# Run from anywhere: bash tests/triage-gh-session-arm.bh-9354-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/flags" "$H/logs" "$H/state"
for s in bin/gh-session/gh bin/lib/triage-gh-token.sh bin/lib/gh-session-token.sh; do
  if [ -f "$DIR/$s" ]; then scratch_install_closure "$s" "$H" >/dev/null || bad "fixture: closure of $s"; fi
done
cat > "$H/bin/gh-token.sh" <<'STUB'
#!/bin/bash
case "$1" in --expires-at) echo 2026-11-12T23:30:00Z ;; *) echo ghs_fixtureminted000000000000000000000 ;; esac
STUB
chmod +x "$H/bin/gh-token.sh"
APP="ghs_fixturearmedtick000000000000000000"

# The arm line(s) from the shipped driver: the lines after `# <<< triage
# github auth` up to the next blank line that call triage_gh_session_arm.
awk '/^# <<< triage github auth/{f=1; next} f && /^$/{exit} f' "$DIR/bin/run-triage.sh" \
  | grep 'triage_gh_session_arm' > "$T/armline.sh"
[ -s "$T/armline.sh" ] && ok || bad "M2: bin/run-triage.sh has no triage_gh_session_arm line right after '# <<< triage github auth'"
grep -q 'triage_gh_session_arm' <<<"$(awk '/^# >>> triage github auth/{f=1} /^# <<< triage github auth/{f=0} f' "$DIR/bin/run-triage.sh")" && bad "M2: the arm line must sit OUTSIDE the extracted auth block" || ok
grep -qE '^[[:space:]]*(function[[:space:]]+)?triage_gh_session_arm[[:space:]]*\(\)' "$DIR/bin/run-triage.sh" \
  && bad "M2: the driver must not define the function (rt-split-layout A6)" || ok

# arm [env…] — source the lib as run-triage.sh does, run the shipped arm line,
# print the resulting env. ARM_TWICE=1 runs the line twice.
arm() {
  env -i PATH="/usr/bin:/bin" HOME="$T" HARNESS="$H" GH_TOKEN="${ARM_TOKEN:-$APP}" ARM_TWICE="${ARM_TWICE:-}" "$@" \
    bash -c '
      PROJECT=fixproj; TRIAGE_GH_SLUG=example-org/x
      [ -r "$HARNESS/bin/lib/triage-gh-token.sh" ] && . "$HARNESS/bin/lib/triage-gh-token.sh"
      . "'"$T/armline.sh"'"
      [ -n "$ARM_TWICE" ] && . "'"$T/armline.sh"'"
      printf "PATH=%s\n" "$PATH"
      printf "GH=%s\n" "$(command -v gh)"
      env | grep "^GH_SESSION_" | sort' 2>"$T/arm.err"
}

# ── M1 / M3 ─────────────────────────────────────────────────────────────────
out=$(arm)
grep -qx "GH=$H/bin/gh-session/gh" <<<"$out" && ok || bad "M1: after the arm line, gh resolves to bin/gh-session/gh (got: $(grep '^GH=' <<<"$out"); stderr $(head -c 200 "$T/arm.err"))"
grep -qx "GH_SESSION_SLUG=example-org/x" <<<"$out" && ok || bad "M3: GH_SESSION_SLUG"
grep -qx "GH_SESSION_PROJECT=fixproj" <<<"$out" && ok || bad "M3: GH_SESSION_PROJECT"
want_fp=$(printf '%s' "$APP" | sha256sum | cut -c1-16)
grep -qx "GH_SESSION_TOKEN_FP=$want_fp" <<<"$out" && ok || bad "M3: GH_SESSION_TOKEN_FP is the sha256 16-hex prefix of the armed token"
grep -qF -- "$APP" <<<"$(grep '^GH_SESSION_' <<<"$out")" && bad "M3: no GH_SESSION_* var may hold the token value" || ok
grep -qE '^GH_SESSION_ARMED_AT=[0-9]+$' <<<"$out" && ok || bad "M3: GH_SESSION_ARMED_AT is an epoch"
grep -qx "GH_SESSION_EXPIRES_AT=2026-11-12T23:30:00Z" <<<"$out" && ok || bad "M3: GH_SESSION_EXPIRES_AT from gh-token.sh --expires-at"
for kv in GH_SESSION_REMINT=1 GH_SESSION_MIN_LIFE_S=600 GH_SESSION_MINT_TIMEOUT_S=15 GH_SESSION_PROBE_TIMEOUT_S=10 \
          GH_SESSION_ALERT_EVERY_S=3600 GH_SESSION_PAT_FALLBACK=1; do
  grep -qx "$kv" <<<"$out" && ok || bad "M3: knob default reaches the env: $kv"
done
out=$(arm GH_SESSION_MIN_LIFE_S=1200)
grep -qx "GH_SESSION_MIN_LIFE_S=1200" <<<"$out" && ok || bad "M3: a set knob is kept"
out=$(arm GH_SESSION_MIN_LIFE_S=99999)
grep -qx "GH_SESSION_MIN_LIFE_S=600" <<<"$out" && ok || bad "M3: an out-of-range knob falls back to its default"

# ── M4 ──────────────────────────────────────────────────────────────────────
out=$(ARM_TWICE=1 arm)
n=$(grep '^PATH=' <<<"$out" | sed 's/^PATH=//' | tr ':' '\n' | grep -cx "$H/bin/gh-session")
[ "$n" = 1 ] && ok || bad "M4: armed twice = one PATH entry, got $n"

# ── M5 ──────────────────────────────────────────────────────────────────────
untouched() { # <name> <out>
  if grep -q '^GH_SESSION_SLUG=' <<<"$2" || grep -q "$H/bin/gh-session" <<<"$(grep '^PATH=' <<<"$2")"; then
    bad "M5 $1: the env must be untouched"
  else ok; fi
}
untouched "PAT token" "$(ARM_TOKEN=ghp_fixturepat00000000000000000000000 arm)"
untouched "GH_SESSION_REMINT=0" "$(arm GH_SESSION_REMINT=0)"
untouched "empty GH_TOKEN" "$(ARM_TOKEN=' ' arm)"

echo "triage-gh-session-arm.bh-9354: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
