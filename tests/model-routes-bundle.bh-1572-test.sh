#!/bin/bash
# tests/model-routes-bundle.bh-1572-test.sh — the dispatcher ships its model
# route answers in the job bundle, so a worker blip does not defer a fresh
# builder (BH-1572, the F4 follow-up of #1569's round-2 review).
#
# WHY. A freshly spawned Fly builder has an empty route cache. When it cannot
# reach the worker at job start, model_routes_warm only logs, model_env_or_route
# answers rc 75 and the build ends BUILD_DEFERRED: no guessed model, which is
# right, but a short worker blip deferred every fresh builder in every project.
# The dispatcher has just resolved the same roles on its own box, so it ships
# them (bin/lib/model-route.sh model_routes_bundle) and the builder installs
# them before it warms (model_routes_bundle_install, from fly/builder-runner.sh).
#
# WHAT IS PROVEN, through the REAL resolver against a stubbed worker
# (tests/lib/model-route-stub.sh), with the real run-build tiering block and the
# real model_routes_warm cut out of fly/builder-runner.sh:
#   A. the builder: fresh + worker down + bundle -> builds on the bundled
#      ladders; fresh + worker down + no bundle -> still defers; worker up ->
#      the live answer wins over the bundle; a box cache newer than the bundle
#      is kept; the bundle is consumed; a malformed or rung-0-less entry is
#      never installed; an installed ladder drops the stale .hub marker.
#   B. the dispatcher: every build role for the project, stamped now when the
#      worker answered and with the cache's mtime when it did not; after the
#      first failed ask the rest are read from the cache (one ask, not twelve);
#      a project override is what ships for that project; nothing to answer ->
#      rc 75 and no file.
#   C. both dispatchers push the bundle before the job file, and the pool
#      resolves it once per tick, before the first spawn.
#
# Run from anywhere: tests/model-routes-bundle.bh-1572-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
O55=claude-opus-5-5; O5=claude-opus-5; FB=claude-fable-5-1; SN=claude-sonnet-5
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

mrs_install "$T/fakebin"
# A counting curl in front of the stub, so "asked once" is measurable even when
# the stub answers down (it exits before its own sink).
mkdir -p "$T/countbin"
cat > "$T/countbin/curl" <<EOF
#!/bin/bash
echo x >> "\$CURL_COUNT"
exec "$T/fakebin/curl" "\$@"
EOF
chmod +x "$T/countbin/curl"
reset_routes() { rm -rf "$T/routes"; mrs_table_1523 "$T/routes"; }
reset_routes

# A harness with the resolver and its transport where a lane expects them.
mkbox() { # mkbox <dir> — an empty box: resolver, client, no cache
  scratch_rm "$1"; mkdir -p "$1/bin/lib/jobs" "$1/logs" "$1/state" "$1/flags" "$1/env"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  cp "$DIR/bin/lib/model-route.sh" "$DIR/bin/lib/env-path.sh" "$1/bin/lib/"
}
lenv() { # lenv <cmd...> — run as a lane would, against the stub worker
  env -u EXECUTE_MODEL -u REVIEW_MODEL -u REVIEW_MODEL_T0 -u FIX_MODEL -u QA_MODEL -u PLAN_MODEL \
      PATH="$T/countbin:$T/fakebin:$PATH" HARNESS_SECRET=test-secret CURL_COUNT="$T/curl.count" \
      JOBS_URL=https://jobs.invalid MRS_ROUTES="$T/routes" JOBS_RETRIES=0 "$@"
}

# =============================================================================
# A. the builder
# =============================================================================
sed -n '/^model_routes_warm() {$/,/^}$/p' "$DIR/fly/builder-runner.sh" > "$T/warm.sh"
[ -s "$T/warm.sh" ] && ok || bad "A0 no model_routes_warm in fly/builder-runner.sh"
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
sed -n '/^# >>> model tiering$/,/^# <<< model tiering$/p' "$RB_ALL" > "$T/tiering.sh"
[ -s "$T/tiering.sh" ] && ok || bad "A0 no '>>> model tiering' block in bin/run-build.sh"

FH="$T/fh"; ENVD="$T/env"
warm() { # warm [ENV=VAL...] — the builder's job-start warm, logged to stdout
  lenv "$@" HARNESS="$FH" bash -c 'HARNESS="$1" PROJECT=testproj ENVDIR="$2"; log() { echo "$*"; }; . "$3"; model_routes_warm' \
    _ "$FH" "$ENVD" "$T/warm.sh"
}
tiering() { # tiering [ENV=VAL...] -> 'PLAN EXECUTE REVIEW T0 FIX QA'; rc = the block's exit
  mkdir -p "$T/b"; rm -f "$T/b/RESULT"
  lenv "$@" HARNESS="$FH" bash -c '
    set -uo pipefail
    PROJECT=testproj KEY=K-1 BUILD="$1" ALERTS="$HARNESS/logs/ALERTS.log"
    STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
    RESULT() { echo "$1" > "$BUILD/RESULT"; }
    . "$2"
    echo "$PLAN_MODEL $EXECUTE_MODEL $REVIEW_MODEL $REVIEW_MODEL_T0 $FIX_MODEL $QA_MODEL"' _ "$T/b" "$T/tiering.sh"
}

# The hub resolves a bundle with the worker up (B proves its shape; here it is
# the dispatcher's real output, not a hand-typed file).
HUB="$T/hub"; mkbox "$HUB"
BUNDLE="$T/bundle.tsv"
lenv HARNESS="$HUB" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle testproj "$2"' _ "$HUB" "$BUNDLE"
[ -s "$BUNDLE" ] && ok || bad "A1 the dispatcher must write a bundle with the worker up"

# --- A1. fresh + worker down + bundle -> builds on the bundle ----------------
mkbox "$FH"; scratch_rm "$ENVD"; mkdir -p "$ENVD"; cp "$BUNDLE" "$ENVD/model-routes.tsv"
WLOG=$(warm MRS_MODE=down)
case "$WLOG" in *"12 from the dispatcher's bundle; 12 resolved"*) ok ;; *) bad "A1 the warm must install the bundle, then resolve every role from it: $WLOG" ;; esac
OUT=$(tiering MRS_MODE=down); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$FB $O55 $O55 $O55 $O55 $O55" ] \
  && ok || bad "A1 a fresh builder whose worker is down must build on the bundled ladders: rc=$RC '$OUT'"
[ ! -e "$ENVD/model-routes.tsv" ] && ok || bad "A1 the bundle must be consumed by the warm"
[ "$(cut -f2 "$FH/state/model-routes/build.execute@testproj.tsv" | paste -sd,)" = "$O55,$O5" ] \
  && ok || bad "A1 the whole ladder must be installed, not only its primary"

# --- A2. fresh + worker down + NO bundle -> still defers ---------------------
mkbox "$FH"; scratch_rm "$ENVD"; mkdir -p "$ENVD"
warm MRS_MODE=down >/dev/null
OUT=$(tiering MRS_MODE=down); RC=$?
{ [ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED no model route' "$T/b/RESULT"; } \
  && ok || bad "A2 no bundle + worker down must still defer, never guess: rc=$RC '$OUT'"

# --- A3. worker up -> the live answer wins over the bundle -------------------
mkbox "$FH"; scratch_rm "$ENVD"; mkdir -p "$ENVD"; cp "$BUNDLE" "$ENVD/model-routes.tsv"
mrs_route "$T/routes" build.execute testproj "$SN:claude"
warm >/dev/null
OUT=$(tiering MRS_MODE=down)
[ "$(echo "$OUT" | awk '{print $2}')" = "$SN" ] \
  && ok || bad "A3 a worker the builder reaches must win over the bundle: '$OUT'"
reset_routes

# --- A4. a box cache newer than the bundle is kept ---------------------------
mkbox "$FH"; scratch_rm "$ENVD"; mkdir -p "$ENVD"
mkdir -p "$FH/state/model-routes"
printf '0\t%s\tclaude\n' "$SN" > "$FH/state/model-routes/build.execute@testproj.tsv"
awk -F'\t' -v OFS='\t' '{ $2 = $2 - 600; print }' "$BUNDLE" > "$ENVD/model-routes.tsv"   # resolved 10 min ago
warm MRS_MODE=down >/dev/null
[ "$(cut -f2 "$FH/state/model-routes/build.execute@testproj.tsv" | paste -sd,)" = "$SN" ] \
  && ok || bad "A4 an older bundle must not overwrite a newer box cache"
[ "$(cut -f2 "$FH/state/model-routes/build.plan@testproj.tsv" 2>/dev/null)" = "$FB" ] \
  && ok || bad "A4 roles the box had no answer for must still be installed"
# ...and the installed file carries the dispatcher's resolution time, not now.
want=$(awk -F'\t' '$1=="build.plan"{print $2 - 600; exit}' "$BUNDLE")
[ "$(mtime "$FH/state/model-routes/build.plan@testproj.tsv")" = "$want" ] \
  && ok || bad "A4 an installed ladder must be stamped with the dispatcher's resolution time"

# --- A5. a malformed or rung-0-less entry is never installed -----------------
mkbox "$FH"; scratch_rm "$ENVD"; mkdir -p "$ENVD"
NOW=$(date +%s)
printf 'build.plan\t%s\t1\t%s\tclaude\n' "$NOW" "$FB" > "$ENVD/model-routes.tsv"         # no rung 0
printf 'bad role!\t%s\t0\t%s\tclaude\n' "$NOW" "$FB" >> "$ENVD/model-routes.tsv"          # not a role
printf 'build.qa\tsoon\t0\t%s\tclaude\n' "$O55" >> "$ENVD/model-routes.tsv"                # no stamp
printf 'build.fix\t%s\t0\t%s\tclaude\n' "$NOW" "$O55" >> "$ENVD/model-routes.tsv"          # fine
N=$(HARNESS="$FH" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle_install "$2" testproj' _ "$FH" "$ENVD/model-routes.tsv")
[ "$N" = 1 ] && [ -s "$FH/state/model-routes/build.fix@testproj.tsv" ] \
  && [ ! -e "$FH/state/model-routes/build.plan@testproj.tsv" ] && [ ! -e "$FH/state/model-routes/build.qa@testproj.tsv" ] \
  && [ -z "$(ls "$FH/state/model-routes" | grep -v '^build\.fix@testproj\.tsv$')" ] \
  && ok || bad "A5 only the well-formed ladder may be installed: n=$N, $(ls "$FH/state/model-routes" | paste -sd' ')"

# --- A6. an installed ladder drops the stale .hub marker ---------------------
# Without this, an outage would serve the box's OLDER hub copy (the marker says
# "this project ran on the hub ladder") over the dispatcher's fresher answer.
mkbox "$FH"; mkdir -p "$FH/state/model-routes"
printf '0\t%s\tclaude\n' "$O5" > "$FH/state/model-routes/build.execute.tsv"
printf '0\t%s\tclaude\n' "$O5" > "$FH/state/model-routes/build.execute@testproj.tsv"
: > "$FH/state/model-routes/build.execute@testproj.tsv.hub"
touch -t 202601010000 "$FH/state/model-routes/build.execute@testproj.tsv"
printf 'build.execute\t%s\t0\t%s\tclaude\n' "$NOW" "$SN" > "$T/b6.tsv"
HARNESS="$FH" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle_install "$2" testproj' _ "$FH" "$T/b6.tsv" >/dev/null
OUT=$(lenv MRS_MODE=down HARNESS="$FH" bash -c '. "$1/bin/lib/model-route.sh"; model_for build.execute testproj' _ "$FH")
[ "$OUT" = "$SN" ] && [ ! -e "$FH/state/model-routes/build.execute@testproj.tsv.hub" ] \
  && ok || bad "A6 the bundled ladder must be what an outage serves, not the older hub copy: '$OUT'"

# =============================================================================
# B. the dispatcher: model_routes_bundle
# =============================================================================
# --- B1. worker up: every build role, stamped now ----------------------------
T0=$(date +%s)
roles=$(cut -f1 "$BUNDLE" | sort -u | paste -sd' ')
want=$(printf '%s\n' build.plan build.execute build.review build.review.t0 build.fix build.qa claude.ladder \
  codex.default grok.default fireworks.default fireworks.floor openrouter.floor | sort | paste -sd' ')
[ "$roles" = "$want" ] && ok || bad "B1 the bundle must carry every build role the table answers: '$roles'"
[ "$(awk -F'\t' '$1=="claude.ladder"{print $3":"$4":"$5}' "$BUNDLE" | paste -sd,)" = "0:$FB:claude,1:$O55:claude,2:$O5:claude" ] \
  && ok || bad "B1 each role's whole ladder, in order"
awk -F'\t' -v t="$T0" '$2 > t + 5 || $2 < t - 120 {bad=1} END{exit bad}' "$BUNDLE" \
  && ok || bad "B1 a worker answer must be stamped with the time it was resolved"
# stage.* roles are bundled when routed, and never alert when they are not.
mrs_route "$T/routes" stage.execute "$O55:claude" "gpt-6-astra:codex"
lenv HARNESS="$HUB" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle testproj "$2"' _ "$HUB" "$T/b-stage.tsv"
[ "$(awk -F'\t' '$1=="stage.execute"{print $5}' "$T/b-stage.tsv" | paste -sd,)" = "claude,codex" ] \
  && ok || bad "B1 a routed stage.* role must ride the bundle"
! grep -q "stage\." "$HUB/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "B1 an unrouted stage.* role must not alert: $(grep stage. "$HUB/logs/ALERTS.log")"
reset_routes

# --- B2. a project override is what ships for that project -------------------
mrs_route "$T/routes" build.review testproj "$SN:claude"
lenv HARNESS="$HUB" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle testproj "$2"' _ "$HUB" "$T/b2.tsv"
[ "$(awk -F'\t' '$1=="build.review"{print $4}' "$T/b2.tsv" | paste -sd,)" = "$SN" ] \
  && ok || bad "B2 the project's override must be what the bundle ships for it"
reset_routes

# --- B3. worker down: served from the hub's cache, stamped with its mtime, one ask
touch -t 202609010000 "$HUB/state/model-routes/"*.tsv
: > "$T/curl.count"
lenv MRS_MODE=down HARNESS="$HUB" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle testproj "$2"' _ "$HUB" "$T/b3.tsv"; RC=$?
[ "$RC" = 0 ] && [ "$(cut -f1 "$T/b3.tsv" | sort -u | wc -l | tr -d ' ')" = 12 ] \
  && ok || bad "B3 worker down must still bundle this box's cached answers: rc=$RC"
[ "$(cut -f2 "$T/b3.tsv" | sort -u | paste -sd,)" = "$(mtime "$HUB/state/model-routes/build.plan@testproj.tsv")" ] \
  && ok || bad "B3 a cached answer must carry the cache's mtime, not now: $(cut -f2 "$T/b3.tsv" | sort -u | paste -sd,)"
[ "$(wc -l < "$T/curl.count" | tr -d ' ')" = 1 ] \
  && ok || bad "B3 after the worker fails once, the rest must come from the cache: $(wc -l < "$T/curl.count") asks"

# --- B4. nothing to answer: rc 75, no file -----------------------------------
EMPTY="$T/empty"; mkbox "$EMPTY"
lenv MRS_MODE=down HARNESS="$EMPTY" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle testproj "$2"' _ "$EMPTY" "$T/b4.tsv"; RC=$?
[ "$RC" = 75 ] && [ ! -e "$T/b4.tsv" ] && [ -z "$(ls "$T" | grep '^b4\.tsv')" ] \
  && ok || bad "B4 a box with nothing to ship must write no file and answer 75: rc=$RC"
lenv HARNESS="$EMPTY" bash -c '. "$1/bin/lib/model-route.sh"; model_routes_bundle "bad project" "$2"' _ "$EMPTY" "$T/b4.tsv"; RC=$?
[ "$RC" = 1 ] && ok || bad "B4 a malformed project is a caller bug (rc 1): rc=$RC"

# =============================================================================
# C. the dispatchers push it, before the job file
# =============================================================================
awk '/mput "\$MID" "\$POOL_MR_BUNDLE" \/run\/harness-env\/model-routes\.tsv/{b=NR}
     /mput "\$MID" "\$JF(PUSH)?" \/run\/harness\/job\.json/{j=NR} END{exit !(b && j && b < j)}' "$DIR/bin/fly-pool.sh" \
  && ok || bad "C1 fly-pool must push the bundle before the job file"
awk '/^  pool_mr_bundle$/{b=NR} /^  spawn_one "\$JF"/{s=NR} END{exit !(b && s && b == s - 1)}' "$DIR/bin/fly-pool.sh" \
  && ok || bad "C1 fly-pool must resolve the bundle once, before the first spawn (not inside the concurrent spawns)"
awk '/push_file "\$p" "\$tmp\/model-routes\.tsv" "\/run\/harness-env\/model-routes\.tsv"/{b=NR}
     /push_file "\$p" "\$active" +"\/run\/harness\/job\.json"/{j=NR} END{exit !(b && j && b < j)}' "$DIR/bin/fly-dispatch.sh" \
  && ok || bad "C2 fly-dispatch must push the bundle before the job file"
# pool_mr_bundle, driven: once per tick however many spawns ask for it.
sed -n '/^pool_mr_bundle() {$/,/^}$/p' "$DIR/bin/fly-pool.sh" > "$T/pmb.sh"
: > "$T/curl.count"
OUT=$(lenv HARNESS="$HUB" bash -c 'HARNESS="$1" P=testproj POOL_MR_BUNDLE=""; say() { echo "$*"; }; . "$2"
  pool_mr_bundle; pool_mr_bundle; pool_mr_bundle; cut -f1 "$POOL_MR_BUNDLE" | sort -u | wc -l; rm -f "$POOL_MR_BUNDLE"' _ "$HUB" "$T/pmb.sh")
[ "$(echo "$OUT" | tail -1 | tr -d ' ')" = 12 ] && [ "$(echo "$OUT" | grep -c 'bundling 12 resolved')" = 1 ] \
  && [ "$(wc -l < "$T/curl.count" | tr -d ' ')" = 17 ] \
  && ok || bad "C3 pool_mr_bundle must resolve once per tick: '$OUT', $(wc -l < "$T/curl.count") asks"

echo "model-routes-bundle.bh-1572: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
