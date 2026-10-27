#!/bin/bash
# tests/fly-images.bh-2743-test.sh — BH-2743: the rollout writes the fly_images
# row `baked` (inactive) before SMOKE, flips it active only on SMOKE_OK, and
# records `smoke_failed` on the candidate otherwise. The previous active row is
# never touched on a failed smoke. The worker half is
# worker/jobs/test/fly-images.bh-2743.test.js.
#
#   S1  the seam: fir_put's 8th arg sends "state" with no "active"; a state with
#       active=1, or an unknown state, is rc 3 and sends nothing
#   S2  bin/fly-image-build.sh: FLY_IMAGE_CANDIDATE=1 puts state baked with no
#       active; without it the put activates, as before (propagate, refresh)
#   R1  bin/fly-pool-rollout.sh, smoke fails (no result): baked, then
#       smoke_failed; no activating PUT, no PUT naming the prior ref, no ALERTS,
#       the file restored
#   R2  smoke passes: baked, then active:1, the activation after SMOKE_OK
#   R3  smoke machine not started: smoke_failed, no activation
#   R4  pointer moved during smoke: no activation of the probed ref
#   R5  SMOKE_OK but the worker never records the activation: two tries, the
#       row-stale marker, one ALERTS line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/fly-images.bh-2743-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/fly-image-row.sh"
BUILD="$DIR/bin/fly-image-build.sh"
ROLLOUT="$DIR/bin/fly-pool-rollout.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -r "$ROLLOUT" ] && [ -r "$BUILD" ] && ok || bad "the rollout or build script is missing"

# Nothing here may reach a real worker: no secret, no URL, env dir in $T.
unset FLY_IMAGES_DB HARNESS_SECRET JOBS_URL FLY_IMAGE_CANDIDATE
export HARNESS="$T" HARNESS_ENV_DIR="$T/env" JOBS_BOX=testbox
mkdir -p "$T/logs" "$T/ans" "$T/env"
REF_A='registry.fly.io/builder-alpha-os:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA'

# ---------- S1 the seam carries a state --------------------------------------
cat > "$T/prelude.sh" <<EOF
. "$LIB" || exit 99
export HARNESS_SECRET=stub-secret JOBS_URL=http://127.0.0.1:9
_jobs_req() {
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls"
  printf '{"ok":true}'
}
EOF
run() { bash -c ". '$T/prelude.sh'; $1" 2>&1; }
s1_reset() { rm -f "$T/calls" "$T/state/fly"/*.row-stale; }
s1_body() { grep ' /api/fly-images ' "$T/calls" 2>/dev/null | cut -d' ' -f3- | jq -Sc . 2>/dev/null; }
for st in baked smoke_failed; do
  s1_reset
  out=$(run "fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' '' $st; echo rc=\$?")
  want=$(jq -Snc --arg d "$REF_A" --arg s "$st" '{project:"alpha-os",app:"builder-alpha-os",digest:$d,state:$s,box:"testbox"}')
  [ "$out" = rc=0 ] && [ "$(s1_body)" = "$want" ] && ok || bad "S1 $st put: out=$out body=$(s1_body) want $want"
  [ ! -e "$T/state/fly/alpha-os.row-stale" ] && ok || bad "S1 a recorded $st put leaves no marker"
done
# A candidate put never clears the marker: only a recorded activation does.
s1_reset; mkdir -p "$T/state/fly"; echo "1 x" > "$T/state/fly/alpha-os.row-stale"
run "fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' '' baked" >/dev/null
[ -e "$T/state/fly/alpha-os.row-stale" ] && ok || bad "S1 a baked put must not clear the row-stale marker"
for args in "1 baked" "1 smoke_failed" "'' bogus" "'' active" "'' demoted" "'' SMOKE_FAILED"; do
  s1_reset
  out=$(run "fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' $args; echo rc=\$?")
  [ "$out" = rc=3 ] && [ ! -s "$T/calls" ] && ok || bad "S1 fir_put ... $args must be rc 3 and send nothing: out=$out calls=$(cat "$T/calls" 2>/dev/null)"
done
# The activating put is unchanged: active:1 and no state key.
s1_reset
run "fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' 1" >/dev/null
want=$(jq -Snc --arg d "$REF_A" '{project:"alpha-os",app:"builder-alpha-os",digest:$d,active:1,box:"testbox"}')
[ "$(s1_body)" = "$want" ] && ok || bad "S1 activating body: $(s1_body) want $want"

# ===========================================================================
# Shared curl stub for S2 and R1-R5: every request is recorded to $REQ_SINK as
# "METHOD URL BODY"; a PUT whose body names $FAIL_PUT_DIGEST gets a 503. A PUT
# with "active":1 also appends to $ACT_SINK whether $ROLLOUT_LOG already holds
# the SMOKE_OK line at that moment, which is how R2 proves the order.
# ===========================================================================
FB="$T/fakebin"; ROWS="$T/rows"
mkdir -p "$FB" "$ROWS"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$(printf '%s' "$BODY" | tr '\n' ' ')" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*"/api/settings/"*)
    K="${URL##*/api/settings/}"
    if [ -f "$ROWS/$K" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$(cat "$ROWS/$K")"
    else printf '{}\n404\n'; fi ;;
  "GET "*"/api/fly-images?project="*) printf '{"row":null,"as_of":"t"}\n200\n' ;;
  "PUT "*"/api/fly-images")
    if [ -n "${ACT_SINK:-}" ] && [[ "$BODY" == *'"active":1'* ]]; then
      if grep -q 'SMOKE_OK' "${ROLLOUT_LOG:-/dev/null}" 2>/dev/null; then echo after-smoke >> "$ACT_SINK"; else echo before-smoke >> "$ACT_SINK"; fi
    fi
    if [ -n "${FAIL_PUT_DIGEST:-}" ] && [[ "$BODY" == *"\"$FAIL_PUT_DIGEST\""* ]]; then printf '{"error":"down"}\n503\n'
    else printf '{"ok":true}\n200\n'; fi ;;
  *) printf '{}\n200\n' ;;
esac
CURL
chmod +x "$FB/curl"
fir_puts() { grep '^PUT [^ ]*/api/fly-images ' "$1" 2>/dev/null | cut -d' ' -f3-; }

# ---------- S2 bin/fly-image-build.sh ----------------------------------------
cat > "$FB/fly" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo '[]' ;;
  deploy*) echo "image: registry.fly.io/${STUB_APP:-builder-demo}:deployment-01TEST" ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$FB/gh"
for b in claude codex; do printf '#!/bin/bash\n[ "$1" = --version ] && echo "1.0.0"\n' > "$FB/$b"; done
chmod +x "$FB"/*
for d in playwright:1.48.2 semgrep:1.176.1 tailscale:1.102.3 gh:2.100.0 bun:1.4.2 codegraph:1.5.0 rtk:0.45.0 flyctl:0.4.119; do
  printf '%s' "${d#*:}" > "$ROWS/bake.${d%%:*}.version"
done
build_run() { # build_run [env...]
  local bh; bh=$(mktemp -d "$T/bh-XXXXXX")
  mkdir -p "$bh/state/fly" "$bh/env" "$bh/logs" "$bh/flags"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$bh/env/global.env"
  printf 'node=22.1\n' > "$bh/state/fly/demo.bake"
  : > "$T/req2"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" ROWS="$ROWS" HARNESS="$bh" WARM_BAKE=0 FLY_ORG=stub-org \
        STUB_APP=builder-demo REQ_SINK="$T/req2" JOBS_BOX=testbox "$@" bash "$BUILD" demo 2>&1); RC=$?
}
build_run FLY_IMAGE_CANDIDATE=1
B=$(fir_puts "$T/req2")
[ "$RC" = 0 ] && [ "$(grep -c . <<<"$B")" = 1 ] && ok || bad "S2 candidate build: rc=$RC, expected one PUT: [$B] $OUT"
[ "$(jq -r '.state, has("active"), .digest' <<<"$B" 2>/dev/null | tr '\n' ' ')" = "baked false registry.fly.io/builder-demo:deployment-01TEST " ] && ok \
  || bad "S2 FLY_IMAGE_CANDIDATE=1 must put state baked with no active: $B"
[ "$(jq -r '.baked_at | type' <<<"$B" 2>/dev/null)" = number ] && [ "$(jq -r .bake <<<"$B" 2>/dev/null | grep -c '^node=22.1$')" = 1 ] && ok \
  || bad "S2 the candidate row still carries baked_at and bake: $B"
build_run
B=$(fir_puts "$T/req2")
[ "$(jq -r '.active, has("state")' <<<"$B" 2>/dev/null | tr '\n' ' ')" = "1 false " ] && ok \
  || bad "S2 without FLY_IMAGE_CANDIDATE the build still activates, with no state: $B"

# ===========================================================================
# R1-R5 bin/fly-pool-rollout.sh through the shared rollout fixture
# ===========================================================================
. "$DIR/tests/lib/fly-rollout-fixture.sh" || exit 1
PROBED='registry.fly.io/builder-proj-x:deployment-01BBBBBBBBBBBBBBBBBBBBBBBB'
PRIOR='registry.fly.io/builder-proj-x:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA'
r_case() { # r_case <dir>
  rollout_reset_knobs
  rollout_fixture "$1" "$DIR"
  cp "$FB/curl" "$1/fb/curl"
  mkdir -p "$1/h/bin/lib/jobs"
  cp "$DIR/bin/jobs-client.sh" "$1/h/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$LIB" "$1/h/bin/lib/"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/h/bin/lib/jobs/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$1/h/env/global.env"
  printf '%s\n' "$PRIOR" > "$1/h/state/fly/proj-x.image"
  # The fixture's build stub, plus one line recording how the rollout called it.
  sed -i "2a printf '%s\\\\n' \"\${FLY_IMAGE_CANDIDATE:-unset}\" > '$1/build-candidate'" "$1/h/bin/fly-image-build.sh"
}
r_run() { # r_run <dir> [env...]
  local c="$1"; shift
  env MINT_TOKEN='FlyV1 fm2_minted' REQ_SINK="$c/req" ACT_SINK="$c/act" ROLLOUT_LOG="$c/h/logs/fly-pool-rollout.log" \
      ROLLOUT_ROW_RETRY_WAIT=0 "$@" bash -c ". '$DIR/tests/lib/fly-rollout-fixture.sh' || exit 1; ROLLOUT_REPO='$DIR'; rollout_run '$c' proj-x"
}
puts_fmt() { fir_puts "$1/req" | jq -rc '[.digest, (.state // "-"), (.active // "-" | tostring)] | join(" ")' 2>/dev/null; }
n_active() { fir_puts "$1/req" | jq -c 'select(.active == 1)' 2>/dev/null | grep -c . ; }
n_prior() { fir_puts "$1/req" | jq -r .digest 2>/dev/null | grep -cxF "$PRIOR"; }

# ---------- R1 smoke fails ----------------------------------------------------
C="$T/r1"; r_case "$C"; r_run "$C"
[ "$(cat "$C/build-candidate" 2>/dev/null)" = 1 ] && ok || bad "R1 the rollout must run the build with FLY_IMAGE_CANDIDATE=1: $(cat "$C/build-candidate" 2>/dev/null)"
[ "$(puts_fmt "$C")" = "$PROBED baked -"$'\n'"$PROBED smoke_failed -" ] && ok \
  || bad "R1 a failed smoke must put PROBED baked, then PROBED smoke_failed: [$(puts_fmt "$C")]"
[ "$(n_active "$C")" = 0 ] && ok || bad "R1 a failed smoke must send NO activating PUT: [$(puts_fmt "$C")]"
[ "$(n_prior "$C")" = 0 ] && ok || bad "R1 the prior active row is never PUT (it never moved): [$(puts_fmt "$C")]"
[ -z "$(rollout_alerts "$C")" ] && ok || bad "R1 a recorded smoke_failed alerts nothing: $(rollout_alerts "$C")"
[ "$(cat "$C/h/state/fly/proj-x.image")" = "$PRIOR" ] && ok || bad "R1 the file is restored to PRIOR"
[ ! -e "$C/h/flags/fly-pool-proj-x" ] && ok || bad "R1 a failed smoke never enables the pool"

# ---------- R2 smoke passes ---------------------------------------------------
C="$T/r2"; r_case "$C"; r_run "$C" SMOKE_RESULT=SMOKE_OK
[ "$(puts_fmt "$C")" = "$PROBED baked -"$'\n'"$PROBED - 1" ] && ok \
  || bad "R2 a passing smoke must put PROBED baked, then PROBED active:1: [$(puts_fmt "$C")]"
[ "$(cat "$C/act" 2>/dev/null)" = after-smoke ] && ok || bad "R2 the activation must come after SMOKE_OK: $(cat "$C/act" 2>/dev/null)"
[ -z "$(rollout_alerts "$C")" ] && [ ! -e "$C/h/state/fly/proj-x.row-stale" ] && ok \
  || bad "R2 a recorded activation alerts nothing and leaves no marker: $(rollout_alerts "$C")"
[ -e "$C/h/flags/fly-pool-proj-x" ] && ok || bad "R2 SMOKE_OK enables the pool"

# ---------- R3 smoke machine not started --------------------------------------
C="$T/r3"; r_case "$C"; r_run "$C" MACHINE_STATE=stopped
[ "$(puts_fmt "$C")" = "$PROBED baked -"$'\n'"$PROBED smoke_failed -" ] && ok \
  || bad "R3 a machine that never started is a failed smoke: [$(puts_fmt "$C")]"
[ "$(n_active "$C")" = 0 ] && ok || bad "R3 no activating PUT: [$(puts_fmt "$C")]"

# ---------- R4 pointer moved during smoke --------------------------------------
C="$T/r4"; r_case "$C"
r_run "$C" SMOKE_RESULT=SMOKE_OK MOVE_POINTER_TO='registry.fly.io/builder-proj-x:deployment-01CCCCCCCCCCCCCCCCCCCCCCCC'
[ "$(n_active "$C")" = 0 ] && ok || bad "R4 a pointer moved during smoke must not activate PROBED: [$(puts_fmt "$C")]"
[ "$(puts_fmt "$C")" = "$PROBED baked -" ] && ok || bad "R4 the candidate stays baked: [$(puts_fmt "$C")]"

# ---------- R5 the activation is never recorded --------------------------------
C="$T/r5"; r_case "$C"; r_run "$C" SMOKE_RESULT=SMOKE_OK FAIL_PUT_DIGEST="$PROBED"
[ "$(n_active "$C")" = 2 ] && ok || bad "R5 the activation must be tried twice: [$(puts_fmt "$C")]"
[ "$(cut -d' ' -f2 "$C/h/state/fly/proj-x.row-stale" 2>/dev/null)" = "$PROBED" ] && ok \
  || bad "R5 an unrecorded activation must leave the row-stale marker"
A=$(rollout_alerts "$C")
[ "$(grep -c . <<<"$A")" = 1 ] && grep -q "proj-x" <<<"$A" && grep -qF "\"digest\":\"$PROBED\"" <<<"$A" && grep -qF "$PRIOR" <<<"$A" && ok \
  || bad "R5 one actionable ALERTS line naming the project, the PUT to run and the proven ref: [$A]"
[ -e "$C/h/flags/fly-pool-proj-x" ] && ok || bad "R5 the pool is still enabled (this hub reads the file through the marker)"

echo "fly-images.bh-2743-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
