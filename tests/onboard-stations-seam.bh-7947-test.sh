#!/usr/bin/env bash
# BH-7947 (BH-7934.0): the onboarding station seam bin/lib/onboard-stations.sh.
# It ships empty: the owner comment, the interface comment, no statement and
# no function. BH-7934.1 adds the obs_* functions and changes the "no function"
# check below (it lists this suite under its "Tests that must change").
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
SEAM="$ROOT/bin/lib/onboard-stations.sh"
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

[ -f "$SEAM" ] && ok "S1 the seam file exists" || { bad "S1 the seam file exists ($SEAM)"; exit 1; }
bash -n "$SEAM" && ok "S2 bash -n passes" || bad "S2 bash -n passes"
[ "$(head -n 1 "$SEAM")" = "# BH-7934.1 owns this file" ] && ok "S3 the first line is the owner comment" || bad "S3 the first line is the owner comment"
for f in obs_register obs_prompt obs_label obs_box obs_clone; do
  grep -Eq "^#.*\\b$f\\b" "$SEAM" && ok "S4 $f is named in a comment" || bad "S4 $f is named in a comment"
done
for g in PROJECT SLUG REPO PROD BOX PREFIX BASE REGISTRY_SOURCE; do
  grep -Eq "^#.*\\b$g\\b" "$SEAM" && ok "S5 global $g is named" || bad "S5 global $g is named"
done
grep -Eq '^#.*non-zero' "$SEAM" && ok "S6 the return contract is named" || bad "S6 the return contract is named"
# shellcheck disable=SC1090
out=$(bash -c '. "$1"; rc=$?; declare -F | grep -c " obs_" ; exit "$rc"' _ "$SEAM"); rc=$?
[ "$rc" -eq 0 ] && ok "S7 a source returns rc 0" || bad "S7 a source returns rc 0 (rc $rc)"
[ "${out:-0}" = "0" ] && ok "S8 no obs_ function is defined yet" || bad "S8 no obs_ function is defined yet ($out)"
[ -z "$(grep -Ev '^[[:space:]]*(#|$)' "$SEAM")" ] && ok "S9 the file has no statements" || bad "S9 the file has no statements"

[ "$fail" -eq 0 ] && echo "PASS onboard-stations-seam" || echo "FAILED onboard-stations-seam"
exit "$fail"
