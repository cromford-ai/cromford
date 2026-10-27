#!/bin/bash
# tests/fly-images.bh-2523-test.sh — BH-2523: the per-project Fly image pointer,
# bake manifest and bake time as a fly_images row on the jobs worker, written by
# the build and the rollout, and read DB-first by the four readers that decide
# "rebake or not" and "which image".
#
#   S1  fir_put sends PUT /api/fly-images with the exact JSON body
#   S2  one GET per project per process answers every reader helper
#   S3  FLY_IMAGES_DB=0 sends nothing: put rc 0, reads rc 2
#   S4  no client: put 0, read 2 under set -euo pipefail; a refused put is rc 3
#       plus one logs/fly-image-build.log line and the row-stale marker, which
#       makes every read unknown until a recorded activating put removes it; a
#       row for another project, or naming another app's ref, is not an answer
#   S5  bin/fly-image-build.sh: a parsed ref makes ONE activating PUT with a
#       baked_at, no ref makes none, and a fresh hub keeps the row's bake
#   S6  bin/fly-pool-rollout.sh (order changed by BH-2743): the new ref is put
#       `baked` before SMOKE; a passing smoke activates it, a failing one marks
#       it smoke_failed and never PUTs an activation; an activation the worker
#       never records leaves the marker and one ALERTS line; a fresh hub's
#       failed smoke puts the file back on the row's previous ref
#   S7  bin/fleet-propagate.sh on a FRESH hub (empty state/fly) with a fresh
#       row debounces and never calls fly-image-build
#   S7b every untrustworthy answer still bakes: future, non-numeric, empty,
#       unreachable, another project's row, FLY_IMAGES_DB=0, --force
#   S7c an unusable answer falls back to the hub's .baked-at file
#   S8  bin/fly-pool.sh spawns and bin/fly-provision.sh boots the row's digest
#       over a stale state/fly/<p>.image, and fall back to the file without one
#       or while the row-stale marker is there
#   S9  the lib registry declares FLY_IMAGES_DB
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/fly-images.bh-2523-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
LIB="$DIR/bin/lib/fly-image-row.sh"
ROUTE="$DIR/worker/jobs/src/routes/fly-images.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date +%s) # one wall-clock read; every fixture age is derived from it

[ -r "$LIB" ] && ok || bad "the seam $LIB does not exist"
[ -r "$ROUTE" ] && ok || bad "the worker route $ROUTE does not exist"

# Nothing here may reach a real worker: no secret, no URL, env dir in $T.
unset FLY_IMAGES_DB HARNESS_SECRET JOBS_URL
export HARNESS="$T" HARNESS_ENV_DIR="$T/env" JOBS_BOX=testbox
mkdir -p "$T/logs" "$T/ans" "$T/env"
REF_A='registry.fly.io/builder-alpha-os:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA'
REF_Z='registry.fly.io/builder-alpha-os:deployment-01ZZZZZZZZZZZZZZZZZZZZZZZZ'

# ===========================================================================
# S1-S4: the seam, with _jobs_req stubbed. The stub records
# "<method> <path> <body>" to $T/calls and answers from $T/ans/<key>
# (+ <key>.rc), key = "<method> <path>" with every non-alphanumeric turned to _.
# ===========================================================================
# A secret and a URL so the seam sees a worker; _jobs_req is the stub, and the
# URL is a closed local port, so nothing can leave this box either way.
cat > "$T/prelude.sh" <<EOF
. "$LIB" || exit 99
export HARNESS_SECRET=stub-secret JOBS_URL=http://127.0.0.1:9
_jobs_req() {
  local key; key=\$(printf '%s' "\$1 \$2" | tr -c 'A-Za-z0-9' _)
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls"
  cat "$T/ans/\$key" 2>/dev/null
  return "\$(cat "$T/ans/\$key.rc" 2>/dev/null || echo 0)"
}
EOF
run() { bash -c ". '$T/prelude.sh'; $1" 2>&1; }
answer() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }
answer_rc() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _).rc"; }
reset() { rm -f "$T/calls" "$T/ans"/* "$T/state/fly"/*.row-stale; : > "$T/logs/fly-image-build.log"; }
STALE="$T/state/fly/alpha-os.row-stale"
calls() { grep ' /api/fly-images' "$T/calls" 2>/dev/null; }
ncalls() { calls | grep -c . | head -1; }
rowjson() { # rowjson <project> <digest> <baked_at-json> [bake]
  jq -nc --arg p "$1" --arg d "$2" --argjson b "$3" --arg k "${4:-}" \
    '{row:{project:$p,app:("builder-"+$p),digest:$d,bake:(if $k=="" then null else $k end),cli:null,baked_at:$b,active:1,box:"hub",set_at:"t"},as_of:"t"}'
}

# ---------- S1 exact body ----------------------------------------------------
reset
answer "PUT /api/fly-images" '{"ok":true}'
printf 'node=22.1\nrtk=0.4\n' > "$T/bake"; printf 'claude=2.1\ncodex=0.1\n' > "$T/cli"
out=$(run "fir_put alpha-os builder-alpha-os '$REF_A' '$T/bake' '$T/cli' 1700000000 1; echo rc=\$?")
[ "$out" = "rc=0" ] && ok || bad "S1 out: $out"
[ "$(ncalls)" = 1 ] && ok || bad "S1 calls: $(calls)"
[ "$(calls | cut -d' ' -f1,2)" = "PUT /api/fly-images" ] && ok || bad "S1 method/path: $(calls)"
got=$(calls | cut -d' ' -f3- | jq -Sc . 2>/dev/null)
want=$(jq -Snc --arg d "$REF_A" '{project:"alpha-os",app:"builder-alpha-os",digest:$d,bake:"node=22.1\nrtk=0.4\n",cli:"claude=2.1\ncodex=0.1\n",baked_at:1700000000,active:1,box:"testbox"}')
[ "$got" = "$want" ] && ok || bad "S1 body: $got want $want"
# No files, no baked_at, no active: the keys are absent, never "" or 0 (the
# worker's COALESCE keeps what the build stored).
reset; answer "PUT /api/fly-images" '{"ok":true}'
run "fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' 1" >/dev/null
got=$(calls | cut -d' ' -f3- | jq -Sc . 2>/dev/null)
want=$(jq -Snc --arg d "$REF_A" '{project:"alpha-os",app:"builder-alpha-os",digest:$d,active:1,box:"testbox"}')
[ "$got" = "$want" ] && ok || bad "S1 bare body: $got want $want"
# A digest that is not a Fly registry ref, or is another app's, is never sent:
# rc 3 and the marker, because the row did not follow the file.
for d in 'docker.io/x:latest' 'registry.fly.io/builder-beta-os:deployment-01C' 'registry.fly.io/builder-alpha-os-2:deployment-01C'; do
  reset
  out=$(run "fir_put alpha-os builder-alpha-os '$d' '' '' '' 1; echo rc=\$?")
  [ "$out" = "rc=3" ] && [ "$(ncalls)" = 0 ] && ok || bad "S1 bad digest $d must send nothing, rc 3: $out / $(calls)"
  [ -s "$STALE" ] && ok || bad "S1 bad digest $d must leave the row-stale marker"
done

# ---------- S2 one GET per process -------------------------------------------
reset
answer "GET /api/fly-images?project=alpha-os" "$(rowjson alpha-os "$REF_A" $((NOW - 300)) $'node=22.1\n')"
out=$(run "fir_digest alpha-os; echo; fir_baked_at alpha-os; echo; fir_active alpha-os; fir_bake_to alpha-os '$T/b2'; echo bake=\$?; fir_digest alpha-os; echo")
want=$(printf '%s\n%s\n%s\t%s\t%s\nbake=0\n%s' "$REF_A" "$((NOW - 300))" "$REF_A" builder-alpha-os "$((NOW - 300))" "$REF_A")
[ "$out" = "$want" ] && ok || bad "S2 answers: [$out] want [$want]"
[ "$(calls | grep -c '^GET ')" = 1 ] && ok || bad "S2 expected one GET, got: $(calls)"
[ "$(cat "$T/b2" 2>/dev/null)" = "node=22.1" ] && ok || bad "S2 fir_bake_to wrote: $(cat "$T/b2" 2>/dev/null)"
# The worker answered "no row": rc 1, not 2, and still one GET.
reset
answer "GET /api/fly-images?project=alpha-os" '{"row":null,"as_of":"t"}'
out=$(run "rc=0; fir_digest alpha-os || rc=\$?; echo d=\$rc; rc=0; fir_baked_at alpha-os || rc=\$?; echo b=\$rc")
[ "$out" = $'d=1\nb=1' ] && ok || bad "S2 no-row rcs: $out"
[ "$(calls | grep -c '^GET ')" = 1 ] && ok || bad "S2 no-row expected one GET, got: $(calls)"

# ---------- S3 FLY_IMAGES_DB=0 -------------------------------------------------
reset
answer "GET /api/fly-images?project=alpha-os" "$(rowjson alpha-os "$REF_A" $((NOW - 300)))"
out=$(FLY_IMAGES_DB=0 run "fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' 1; echo p=\$?; rc=0; fir_digest alpha-os || rc=\$?; echo d=\$rc; rc=0; fir_baked_at alpha-os || rc=\$?; echo b=\$rc")
[ "$out" = $'p=0\nd=2\nb=2' ] && ok || bad "S3 rcs: $out"
[ "$(ncalls)" = 0 ] && ok || bad "S3 FLY_IMAGES_DB=0 must send nothing: $(calls)"

# ---------- S4 no client, refused put, foreign row ----------------------------
mkdir -p "$T/nc/bin/lib"; cp "$LIB" "$T/nc/bin/lib/"
out=$(bash -c "set -euo pipefail; . '$T/nc/bin/lib/fly-image-row.sh'; fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' 1; echo p=\$?; rc=0; fir_digest alpha-os || rc=\$?; echo d=\$rc; echo end" 2>&1)
[ "$out" = $'p=0\nd=2\nend' ] && ok || bad "S4 no client under set -euo pipefail: $out"
# A real client that is not configured (no secret, no URL) loads lazily and
# answers unknown, and leaves the caller's options as they were.
mkdir -p "$T/rc/bin/lib/jobs"; cp "$LIB" "$DIR/bin/lib/env-path.sh" "$T/rc/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$T/rc/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$T/rc/bin/lib/jobs/"
out=$(bash -c "set -e; . '$T/rc/bin/lib/fly-image-row.sh'; fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' 1; echo p=\$?; rc=0; fir_digest alpha-os || rc=\$?; echo d=\$rc; case \$- in *e*) echo e-kept;; *) echo e-lost;; esac" 2>&1)
[ "$out" = $'p=0\nd=2\ne-kept' ] && ok || bad "S4 unconfigured real client: $out"
# A put the worker refused: rc 3, one log line naming it, the marker naming
# the digest that did not land — under set -e too.
reset
answer "PUT /api/fly-images" '{"error":"nope"}'; answer_rc "PUT /api/fly-images" 1
out=$(run "set -e; rc=0; fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' 1 || rc=\$?; echo rc=\$rc")
[ "$out" = "rc=3" ] && ok || bad "S4 refused put rc: $out"
[ "$(grep -c "fly_images.*alpha-os.*$REF_A" "$T/logs/fly-image-build.log")" = 1 ] && ok \
  || bad "S4 a refused put must leave one log line: $(cat "$T/logs/fly-image-build.log")"
[ "$(cut -d' ' -f2 "$STALE" 2>/dev/null)" = "$REF_A" ] && ok || bad "S4 a refused put must leave the marker: $(cat "$STALE" 2>/dev/null)"
# While the marker is there the row is not read at all (this hub's files win),
# even though the worker would answer a good row.
answer "GET /api/fly-images?project=alpha-os" "$(rowjson alpha-os "$REF_Z" $((NOW - 300)) $'node=22.1\n')"
: > "$T/calls"
out=$(run "rc=0; fir_digest alpha-os || rc=\$?; echo d=\$rc; rc=0; fir_baked_at alpha-os || rc=\$?; echo b=\$rc; rc=0; fir_bake_to alpha-os '$T/b4' || rc=\$?; echo k=\$rc")
[ "$out" = $'d=2\nb=2\nk=2' ] && ok || bad "S4 the marker must make every read unknown: $out"
[ "$(calls | grep -c '^GET ')" = 0 ] && ok || bad "S4 the marker must skip the GET: $(calls)"
# A recorded put that does not activate leaves it; a recorded activating put
# removes it, and the row reads again.
answer "PUT /api/fly-images" '{"ok":true}'; answer_rc "PUT /api/fly-images" 0
run "fir_put alpha-os builder-alpha-os '$REF_Z' '' '' '' ''" >/dev/null
[ -e "$STALE" ] && ok || bad "S4 a non-activating put must not clear the marker"
out=$(run "fir_put alpha-os builder-alpha-os '$REF_Z' '' '' '' 1; echo p=\$?; fir_digest alpha-os")
[ "$out" = "p=0"$'\n'"$REF_Z" ] && [ ! -e "$STALE" ] && ok || bad "S4 a recorded activating put must clear the marker: $out"
# A 200 without ok:true is not a write either.
reset; answer "PUT /api/fly-images" '{}'
out=$(run "fir_put alpha-os builder-alpha-os '$REF_A' '' '' '' 1; echo rc=\$?")
[ "$out" = "rc=3" ] && [ -e "$STALE" ] && ok || bad "S4 a 200 without ok is rc 3 with the marker: $out"
[ "$(grep -c fly_images "$T/logs/fly-image-build.log")" = 1 ] && ok || bad "S4 a 200 without ok must log"
# A row whose project is not the one asked for is not an answer.
reset
answer "GET /api/fly-images?project=alpha-os" "$(rowjson alpha-os-2 "$REF_A" $((NOW - 300)))"
out=$(run "rc=0; fir_digest alpha-os || rc=\$?; echo d=\$rc")
[ "$out" = "d=2" ] && ok || bad "S4 a foreign row must read unknown: $out"
# A row whose digest is not under its own app is not an answer either.
reset
answer "GET /api/fly-images?project=alpha-os" "$(rowjson alpha-os 'registry.fly.io/builder-beta-os:deployment-01C' $((NOW - 300)))"
out=$(run "rc=0; fir_digest alpha-os || rc=\$?; echo d=\$rc")
[ "$out" = "d=2" ] && ok || bad "S4 another app's digest must read unknown: $out"

# ===========================================================================
# Shared curl stub for S5, S6 and S8: settings rows are files under $ROWS,
# the fly_images row for <p> is $FIR/<p>.json (absent = row:null), every
# request is recorded to $REQ_SINK as "METHOD URL BODY".
# ===========================================================================
FB="$T/fakebin"; ROWS="$T/rows"; FIR="$T/fir"
mkdir -p "$FB" "$ROWS" "$FIR"
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
  "GET "*"/api/fly-images?project="*)
    P="${URL##*project=}"
    if [ -f "$FIR/$P.json" ]; then cat "$FIR/$P.json"; printf '\n200\n'
    else printf '{"row":null,"as_of":"t"}\n200\n'; fi ;;
  "PUT "*"/api/fly-images")
    if [ -n "${FAIL_PUT_DIGEST:-}" ] && [[ "$BODY" == *"\"$FAIL_PUT_DIGEST\""* ]]; then printf '{"error":"down"}\n503\n'
    else printf '{"ok":true}\n200\n'; fi ;;
  *) printf '{}\n200\n' ;;
esac
CURL
chmod +x "$FB/curl"
fir_puts() { grep '^PUT [^ ]*/api/fly-images ' "$1" 2>/dev/null; }

# ===========================================================================
# S5 bin/fly-image-build.sh
# ===========================================================================
cat > "$FB/fly" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo '[]' ;;
  deploy*) echo "$*" >> "${DEPLOY_ARGS_SINK:-/dev/null}"
           [ -n "${NO_REF:-}" ] || echo "image: registry.fly.io/${STUB_APP:-builder-demo}:deployment-01TEST" ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$FB/gh"
for b in claude codex; do printf '#!/bin/bash\n[ "$1" = --version ] && echo "1.0.0"\n' > "$FB/$b"; done
chmod +x "$FB"/*
# Every manifest row except node, so node can only come from "what this
# project last baked" — the file on an old hub, the row on a fresh one.
for d in playwright:1.48.2 semgrep:1.176.1 tailscale:1.102.3 gh:2.100.0 bun:1.4.2 codegraph:1.5.0 rtk:0.45.0 flyctl:0.4.119; do
  printf '%s' "${d#*:}" > "$ROWS/bake.${d%%:*}.version"
done
new_bh() {
  local h; h=$(mktemp -d "$T/bh-XXXXXX")
  mkdir -p "$h/state/fly" "$h/env" "$h/logs" "$h/flags"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$h/env/global.env"
  echo "$h"
}
build_run() { # build_run <project> [env...]
  local proj="$1"; shift
  : > "$T/deploy-args"; : > "$T/req5"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" ROWS="$ROWS" FIR="$FIR" HARNESS="$BH" WARM_BAKE=0 FLY_ORG=stub-org \
        DEPLOY_ARGS_SINK="$T/deploy-args" STUB_APP="builder-$proj" REQ_SINK="$T/req5" JOBS_BOX=testbox \
        "$@" bash "$DIR/bin/fly-image-build.sh" "$proj" 2>&1); RC=$?
}
# S5a a parsed ref: exactly one activating PUT carrying this run's baked_at.
BH=$(new_bh); rm -f "$FIR"/*
printf 'node=22.1\n' > "$BH/state/fly/demo.bake"
build_run demo
[ "$RC" = 0 ] && ok || bad "S5a rc=$RC: $OUT"
[ "$(fir_puts "$T/req5" | wc -l | tr -d ' ')" = 1 ] && ok || bad "S5a expected one PUT /api/fly-images, got: $(fir_puts "$T/req5")"
B5=$(fir_puts "$T/req5" | cut -d' ' -f3-)
[ "$(jq -r .digest <<<"$B5" 2>/dev/null)" = "registry.fly.io/builder-demo:deployment-01TEST" ] && ok || bad "S5a digest: $B5"
[ "$(jq -r '.active, .app, .project' <<<"$B5" 2>/dev/null | tr '\n' ' ')" = "1 builder-demo demo " ] && ok || bad "S5a active/app/project: $B5"
BA=$(jq -r .baked_at <<<"$B5" 2>/dev/null)
case "$BA" in ''|*[!0-9]*) bad "S5a baked_at not an epoch: $B5" ;;
  *) [ "$BA" -ge "$NOW" ] && [ "$BA" -le "$((NOW + 600))" ] && ok || bad "S5a baked_at $BA not this run's" ;; esac
[ "$(jq -r .bake <<<"$B5" 2>/dev/null | grep -c '^node=22.1$')" = 1 ] && ok || bad "S5a the row must carry the bake: $B5"
# S5b no parsed ref: no row, the files untouched.
BH=$(new_bh); rm -f "$FIR"/*
printf 'node=22.1\n' > "$BH/state/fly/demo.bake"
build_run demo NO_REF=1
[ "$(fir_puts "$T/req5" | wc -l | tr -d ' ')" = 0 ] && ok || bad "S5b no ref must write no row: $(fir_puts "$T/req5")"
# S5c a FRESH hub (no state/fly/demo.bake) keeps the row's baked node.
BH=$(new_bh)
rowjson demo "registry.fly.io/builder-demo:deployment-01OLD" $((NOW - 3600)) $'node=22.1\n' > "$FIR/demo.json"
build_run demo
[ "$RC" = 0 ] && ok || bad "S5c a fresh hub with a row must build: rc=$RC: $OUT"
grep -q -- "--build-arg NODE_VERSION=22.1\( \|$\)" "$T/deploy-args" && ok \
  || bad "S5c NODE_VERSION must come from the row's bake: $(cat "$T/deploy-args")"
# ... and without the row the same fresh hub refuses (node resolves from nothing).
BH=$(new_bh); rm -f "$FIR"/*
build_run demo
[ "$RC" != 0 ] && grep -q 'bake.node.version' <<<"$OUT" && ok || bad "S5c without a row a fresh hub must refuse on node: rc=$RC"

# ===========================================================================
# S6 bin/fly-pool-rollout.sh
# ===========================================================================
. "$DIR/tests/lib/fly-rollout-fixture.sh" || exit 1
PROBED='registry.fly.io/builder-proj-x:deployment-01BBBBBBBBBBBBBBBBBBBBBBBB'
PRIOR='registry.fly.io/builder-proj-x:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA'
s6_case() { # s6_case <dir>
  rollout_fixture "$1" "$DIR"
  cp "$FB/curl" "$1/fb/curl"
  # The rollout loads the seam from its harness root, and the seam loads the
  # jobs client beside itself: install both into the scratch harness, as a
  # hub's own bin/ holds them.
  mkdir -p "$1/h/bin/lib/jobs"
  cp "$DIR/bin/jobs-client.sh" "$1/h/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$LIB" "$1/h/bin/lib/"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/h/bin/lib/jobs/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$1/h/env/global.env"
  printf '%s\n' "$PRIOR" > "$1/h/state/fly/proj-x.image"
}
# S6a smoke fails: PROBED baked, then PROBED smoke_failed; no activation at all.
rollout_reset_knobs; s6_case "$T/s6a"
MINT_TOKEN='FlyV1 fm2_minted' REQ_SINK="$T/s6a/req" FIR="$FIR" rollout_run "$T/s6a" proj-x
L=$(fir_puts "$T/s6a/req" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.digest, .state, has("active")' <<<"$L" 2>/dev/null | tr '\n' ' ')" = "$PROBED baked false " ] && ok \
  || bad "S6a the publish must put the built ref baked, not active: $(fir_puts "$T/s6a/req")"
L=$(fir_puts "$T/s6a/req" | tail -1 | cut -d' ' -f3-)
[ "$(jq -r '.digest, .state, has("active")' <<<"$L" 2>/dev/null | tr '\n' ' ')" = "$PROBED smoke_failed false " ] && ok \
  || bad "S6a a failed smoke must mark PROBED smoke_failed: $(fir_puts "$T/s6a/req")"
[ "$(fir_puts "$T/s6a/req" | cut -d' ' -f3- | jq -c 'select(.active == 1)' 2>/dev/null | grep -c .)" = 0 ] && ok \
  || bad "S6a a failed smoke must send no activating PUT: $(fir_puts "$T/s6a/req")"
[ "$(cat "$T/s6a/h/state/fly/proj-x.image")" = "$PRIOR" ] && ok || bad "S6a the file is restored as before"
# S6b smoke passes: PROBED baked, then PROBED active.
rollout_reset_knobs; s6_case "$T/s6b"
MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK REQ_SINK="$T/s6b/req" FIR="$FIR" rollout_run "$T/s6b" proj-x
[ "$(fir_puts "$T/s6b/req" | wc -l | tr -d ' ')" = 2 ] && ok || bad "S6b expected two PUTs: $(fir_puts "$T/s6b/req")"
L=$(fir_puts "$T/s6b/req" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.digest, .state, has("active")' <<<"$L" 2>/dev/null | tr '\n' ' ')" = "$PROBED baked false " ] && ok \
  || bad "S6b the first PUT is the probed ref, baked: $L"
L=$(fir_puts "$T/s6b/req" | tail -1 | cut -d' ' -f3-)
[ "$(jq -r '.digest, .active, .app' <<<"$L" 2>/dev/null | tr '\n' ' ')" = "$PROBED 1 builder-proj-x " ] && ok \
  || bad "S6b a passing smoke must activate the probed ref: $L"
[ -z "$(rollout_alerts "$T/s6b")" ] && [ ! -e "$T/s6b/h/state/fly/proj-x.row-stale" ] && ok \
  || bad "S6b a recorded rollout alerts nothing and leaves no marker: $(rollout_alerts "$T/s6b")"
# S6c smoke passes AND the worker never records the activation: two tries, the
# marker on this hub, and one ALERTS line naming the project and the ref the
# row must move to.
rollout_reset_knobs; s6_case "$T/s6c"
MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK REQ_SINK="$T/s6c/req" FIR="$FIR" FAIL_PUT_DIGEST="$PROBED" ROLLOUT_ROW_RETRY_WAIT=0 \
  rollout_run "$T/s6c" proj-x
[ "$(fir_puts "$T/s6c/req" | cut -d' ' -f3- | jq -c 'select(.active == 1)' 2>/dev/null | grep -c .)" = 2 ] && ok \
  || bad "S6c the activation must be tried twice: $(fir_puts "$T/s6c/req")"
[ "$(cut -d' ' -f2 "$T/s6c/h/state/fly/proj-x.row-stale" 2>/dev/null)" = "$PROBED" ] && ok \
  || bad "S6c an unrecorded activation must leave the row-stale marker"
A6=$(rollout_alerts "$T/s6c")
[ "$(grep -c . <<<"$A6")" = 1 ] && grep -q "proj-x" <<<"$A6" && grep -qF "\"digest\":\"$PROBED\"" <<<"$A6" && ok \
  || bad "S6c one actionable ALERTS line naming project and the activation to run: [$A6]"
# S6d a FRESH hub (no state/fly/proj-x.image) whose row names a good ref: a
# failed smoke sends no activating PUT, and the file follows the row's ref.
rollout_reset_knobs; s6_case "$T/s6d"; rm -f "$T/s6d/h/state/fly/proj-x.image"
rowjson proj-x "$PRIOR" $((NOW - 3600)) > "$FIR/proj-x.json"
MINT_TOKEN='FlyV1 fm2_minted' REQ_SINK="$T/s6d/req" FIR="$FIR" rollout_run "$T/s6d" proj-x
rm -f "$FIR/proj-x.json"
[ "$(fir_puts "$T/s6d/req" | cut -d' ' -f3- | jq -c 'select(.active == 1)' 2>/dev/null | grep -c .)" = 0 ] && ok \
  || bad "S6d a fresh hub's failed smoke must send no activating PUT: $(fir_puts "$T/s6d/req")"
[ "$(cat "$T/s6d/h/state/fly/proj-x.image" 2>/dev/null)" = "$PRIOR" ] && ok || bad "S6d the file follows the row's previous ref"
rollout_reset_knobs

# ===========================================================================
# S7 bin/fleet-propagate.sh — the fresh-hub case
# ===========================================================================
export HARNESS_LANE=test
PH="$T/ph"
mkdir -p "$PH/bin/lib" "$PH/logs" "$PH/state" "$PH/locks" "$PH/flags" "$T/pbin"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$PH/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$PH" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
cp "$LIB" "$PH/bin/lib/"
echo hub > "$PH/state/box-id"
printf 'alpha-os Acme/alpha-os - - 2 box-alpha 10.0.0.1\n' > "$PH/fleet.conf"
: > "$PH/flags/fly-pool-app-alpha-os"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$SSH_CALLS"; echo cafe123456789; exit 0\n' > "$T/pbin/ssh"
printf '#!/bin/bash\nexit 1\n' > "$T/pbin/pgrep"
cat > "$T/pbin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
printf '#!/bin/bash\necho "synced (stub)"; exit 0\n' > "$PH/bin/harness-sync.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BAKE_CALLS"; exit 0\n' > "$PH/bin/fly-image-build.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERTS"; exit 0\n' > "$PH/bin/lane-alert.sh"
# The hub's jobs client, stubbed: _jobs_req answers the fly_images GET from
# $PFIR/<project>.json (+ .rc) and records every request.
cat > "$PH/bin/jobs-client.sh" <<'EOF'
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PCALLS"
  case "$1 $2" in
    "GET /api/fly-images?project="*)
      local p="${2##*project=}" rc
      rc=$(cat "$PFIR/$p.rc" 2>/dev/null || echo 0)
      [ "$rc" = 0 ] || return "$rc"
      if [ -f "$PFIR/$p.json" ]; then cat "$PFIR/$p.json"; else printf '{"row":null}'; fi
      return 0 ;;
  esac
  return 1
}
EOF
chmod +x "$T/pbin"/* "$PH/bin"/*.sh
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"; echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"
PFIR="$T/pfir"; mkdir -p "$PFIR"
N=1
pcommit() { N=$((N+1)); echo "echo v$N" > "$T/src/bin/run-build.sh"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "v$N" && git -C "$T/src" push -q origin main; }
prun() { # prun [flags...] — a fresh hub every time: no state/fly at all
  scratch_rm "$PH/state/fly"; : > "$T/bake.calls"; : > "$T/pcalls"
  # PRE_STAMP: a hub that DOES hold a .baked-at file (the fallback cases).
  [ -n "${PRE_STAMP:-}" ] && { mkdir -p "$PH/state/fly"; echo "$PRE_STAMP" > "$PH/state/fly/alpha-os.baked-at"; }
  ( HARNESS="$PH" HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/pbin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    PCALLS="$T/pcalls" PFIR="$PFIR" POOL_IMAGE_MIN_AGE_MIN=30 \
    bash "$PH/bin/fleet-propagate.sh" "$@" ) > "$T/pout" 2>"$T/perr"
}
pstatus() { jq -r '.pools["alpha-os"].status' "$PH/state/fleet-propagate.json" 2>/dev/null; }
nbake() { grep -c . "$T/bake.calls" 2>/dev/null | head -1; }
prow() { rowjson alpha-os "$REF_A" "$1" > "$PFIR/alpha-os.json"; rm -f "$PFIR/alpha-os.rc"; }

# S7 the fleet baked alpha-os 5 minutes ago; this hub has never seen it.
prow $((NOW - 300)); pcommit; prun; RC=$?
[ "$RC" = 0 ] && ok || bad "S7 rc=$RC: $(cat "$T/perr")"
[ "$(nbake)" = 0 ] && ok || bad "S7 a fresh hub with a fresh row must NOT bake (bake calls: $(cat "$T/bake.calls"))"
[ "$(pstatus)" = debounced ] && ok || bad "S7 the pool must be recorded debounced (got $(pstatus))"
grep -q '^GET /api/fly-images?project=alpha-os ' "$T/pcalls" && ok || bad "S7 the row must be asked for: $(cat "$T/pcalls")"
# And an old row is not fresh: it bakes.
prow $((NOW - 7200)); pcommit; prun
[ "$(nbake)" = 1 ] && ok || bad "S7 a row older than the window must bake (got $(nbake))"

# ---------- S7b every untrustworthy answer still bakes ------------------------
s7b() { # s7b <label> [prun flags...] — the caller has set up the row
  local label="$1"; shift
  pcommit; prun "$@"
  [ "$(nbake)" = 1 ] && ok || bad "S7b $label must bake (bake calls: $(nbake), status $(pstatus))"
}
prow $((NOW + 3600));                                     s7b "a future baked_at"
rowjson alpha-os "$REF_A" '"soon"' > "$PFIR/alpha-os.json"; s7b "a non-numeric baked_at"
rowjson alpha-os "$REF_A" null > "$PFIR/alpha-os.json";     s7b "an empty baked_at"
prow $((NOW - 300)); echo 1 > "$PFIR/alpha-os.rc";          s7b "an unreachable worker"
rm -f "$PFIR"/*; rowjson alpha-os-2 "$REF_A" $((NOW - 300)) > "$PFIR/alpha-os-2.json"
                                                          s7b "a row for alpha-os-2 only"
rowjson alpha-os-2 "$REF_A" $((NOW - 300)) > "$PFIR/alpha-os.json"
                                                          s7b "an answer naming another project"
prow $((NOW - 300)); export FLY_IMAGES_DB=0;              s7b "FLY_IMAGES_DB=0"; unset FLY_IMAGES_DB
prow $((NOW - 300));                                      s7b "--force" --force

# ---------- S7c an unusable row falls back to the file, not straight to a bake -
prow $((NOW + 3600)); pcommit; PRE_STAMP=$((NOW - 120)) prun
[ "$(nbake)" = 0 ] && [ "$(pstatus)" = debounced ] && ok \
  || bad "S7c a future row with a fresh .baked-at must debounce on the file (bakes $(nbake), status $(pstatus))"
echo 1 > "$PFIR/alpha-os.rc"; pcommit; PRE_STAMP=$((NOW - 120)) prun
[ "$(nbake)" = 0 ] && ok || bad "S7c an unreachable worker with a fresh .baked-at must debounce on the file (bakes $(nbake))"
rm -f "$PFIR/alpha-os.rc"

# ===========================================================================
# S8 bin/fly-pool.sh and bin/fly-provision.sh pick the row's digest
# ===========================================================================
OLDREF='registry.fly.io/builder-tproj:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA'
ROWREF='registry.fly.io/builder-tproj:deployment-01ZZZZZZZZZZZZZZZZZZZZZZZZ'
QH="$T/qh"
mkdir -p "$QH/bin/lib/jobs" "$QH/logs" "$QH/flags" "$QH/locks" "$QH/env" "$QH/state/fly" \
         "$QH/state/fly-pool/tproj" "$QH/state/build-queue/tproj" "$QH/builds" "$T/qfb"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$QH/bin/"
cp "$DIR/bin/lib/env-path.sh" "$LIB" "$QH/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$QH/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$QH/bin/lib/jobs/"
: > "$QH/env/fly.env"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$QH/env/global.env"
printf '10\n' > "$QH/flags/fly-pool-tproj"; printf 'pool-tproj\n' > "$QH/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj"}\n' > "$QH/state/fly/tproj.json"
printf 'testbox\n' > "$QH/state/box-name"
printf '#!/bin/bash\nexit 0\n' > "$QH/bin/beat.sh"
cat > "$QH/bin/fly-envbundle.sh" <<'BUNDLE'
#!/bin/bash
mkdir -p "$2"
printf 'CONSOLE_URL=https://console.test\nCLAUDE_CODE_OAUTH_TOKEN=k\nGH_TOKEN=g\nRUNNER_EXECUTE=claude\n' > "$2/global.env"
printf 'BOARD_TOKEN=b\n' > "$2/$1.env"; chmod 600 "$2/global.env" "$2/$1.env"
BUNDLE
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/qfb/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/qfb/sleep"
cat > "$T/qfb/fly" <<'STUB'
#!/bin/bash
case "$*" in
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf '%s\n' "$*" >> "$RUN_ARGS"; echo 'Machine ID: 00000000000100' ;;
esac
exit 0
STUB
cp "$FB/curl" "$T/qfb/curl"
chmod +x "$QH/bin"/*.sh "$T/qfb"/*
qtick() {
  rm -f "$QH/state/fly-pool/tproj"/*.json "$T/run.args"; : > "$QH/logs/fly-pool.log"
  jq -nc '{key:"SP-1",ticket_id:"2",attempt:0,deferrals:0,deaths:0}' > "$QH/state/build-queue/tproj/SP-1.json"
  ( unset HARNESS_ENV_DIR; export PATH="$T/qfb:$PATH" HARNESS="$QH" FLY_BIN_DIR="$T/qfb" FLY_API_TOKEN_TPROJ=tok \
           BOX_NAME=testbox RUN_ARGS="$T/run.args" FIR="$FIR" FLY_MACHINES_ROWS=off
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
printf '%s\n' "$OLDREF" > "$QH/state/fly/tproj.image"
rowjson tproj "$ROWREF" $((NOW - 300)) > "$FIR/tproj.json"
qtick
grep -q "machine run $ROWREF " "$T/run.args" 2>/dev/null && ok \
  || bad "S8 pool must spawn the row's digest over a stale file (runs: $(cat "$T/run.args" 2>/dev/null); log: $(tail -3 "$QH/logs/fly-pool.log"))"
# The marker (a put from this hub that never landed): the row names newer
# bits, possibly ones whose smoke failed, and the file wins.
echo "$NOW $OLDREF" > "$QH/state/fly/tproj.row-stale"
qtick
grep -q "machine run $OLDREF " "$T/run.args" 2>/dev/null && ok \
  || bad "S8 pool with the row-stale marker must spawn the file's ref (runs: $(cat "$T/run.args" 2>/dev/null))"
rm -f "$QH/state/fly/tproj.row-stale"
rm -f "$FIR/tproj.json"
qtick
grep -q "machine run $OLDREF " "$T/run.args" 2>/dev/null && ok \
  || bad "S8 pool with no row must fall back to the file (runs: $(cat "$T/run.args" 2>/dev/null))"

# fly-provision.sh
PV="$T/pv"
mkdir -p "$PV/h/bin/lib/jobs" "$PV/h/env" "$PV/h/state/fly" "$PV/h/locks" "$PV/fb"
printf 'FLY_ORG=testorg\nFLY_API_TOKEN="FlyV1 fm2_bootstrap"\n' > "$PV/h/env/fly.env"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$PV/h/env/global.env"
cp "$DIR/bin/lib/env-path.sh" "$LIB" "$PV/h/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$PV/h/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$PV/h/bin/lib/jobs/"
cat > "$PV/fb/flyctl" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "apps list")     printf '[]\n' ;;
  "volumes list")  printf '[{"id":"vol_aaa","name":"builder_data"}]\n' ;;
  "machine list")  printf '[]\n' ;;
  "machine run")   printf '%s\n' "$3" >> "$RUN_ARGS" ;;
esac
exit 0
STUB
chmod 755 "$PV/fb/flyctl"; cp "$PV/fb/flyctl" "$PV/fb/fly"; cp "$FB/curl" "$PV/fb/curl"
pvrun() { rm -f "$T/pv.args"; ( unset HARNESS_ENV_DIR; export HARNESS="$PV/h" RUN_ARGS="$T/pv.args" FIR="$FIR"
  PATH="$PV/fb:$PATH" bash "$DIR/bin/fly-provision.sh" tproj ) >> "$PV/run.out" 2>&1; }
rowjson tproj "$ROWREF" $((NOW - 300)) > "$FIR/tproj.json"
printf '%s\n' "$OLDREF" > "$PV/h/state/fly/tproj.image"
pvrun
[ "$(cat "$T/pv.args" 2>/dev/null)" = "$ROWREF" ] && ok || bad "S8 provision must boot the row's digest (got: $(cat "$T/pv.args" 2>/dev/null); $(tail -3 "$PV/run.out"))"
echo "$NOW $OLDREF" > "$PV/h/state/fly/tproj.row-stale"; pvrun
[ "$(cat "$T/pv.args" 2>/dev/null)" = "$OLDREF" ] && ok || bad "S8 provision with the row-stale marker boots the file (got: $(cat "$T/pv.args" 2>/dev/null))"
rm -f "$PV/h/state/fly/tproj.row-stale"
rm -f "$FIR/tproj.json"; pvrun
[ "$(cat "$T/pv.args" 2>/dev/null)" = "$OLDREF" ] && ok || bad "S8 provision with no row keeps the file (got: $(cat "$T/pv.args" 2>/dev/null))"
rm -f "$PV/h/state/fly/tproj.image"; pvrun
[ "$(cat "$T/pv.args" 2>/dev/null)" = "registry.fly.io/builder-tproj:latest" ] && ok || bad "S8 provision with neither keeps :latest (got: $(cat "$T/pv.args" 2>/dev/null))"

# ===========================================================================
# S9 the registry declares the kill switch
# ===========================================================================
if "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1; then
  K=$(jq -c '.libs[] | select(.id=="fly-image-row") | {file, k: (.knobs[] | select(.env=="FLY_IMAGES_DB") | {default, settable, min, max})}' "$T/lanes.json" 2>/dev/null)
  [ "$K" = '{"file":"bin/lib/fly-image-row.sh","k":{"default":1,"settable":true,"min":0,"max":1}}' ] && ok \
    || bad "S9 FLY_IMAGES_DB must be registered on lib fly-image-row: $K"
else
  bad "S9 bin/lanes-build.sh could not compose the registry"
fi

# The worker half. The worker imports the RENDERED catalog/lanes.json by a
# static path; it is git-ignored, so a fresh checkout has none (the worker CI
# job renders it first).
if ! command -v node >/dev/null 2>&1 || [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "fly-images.bh-2523-test: worker node suite SKIPPED — no node or catalog/lanes.json is not rendered (bin/lanes-build.sh --write)"
elif (cd "$DIR/worker/jobs" && node --test test/fly-images.bh-2523.test.js >"$T/node.out" 2>&1); then ok
else bad "worker/jobs/test/fly-images.bh-2523.test.js failed: $(grep -E '^ *not ok|Error' "$T/node.out" | head -20)"
fi

echo "fly-images.bh-2523-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
