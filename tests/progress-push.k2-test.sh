#!/bin/bash
# tests/progress-push.k2-test.sh — K2, the push side of the outside dead-man.
# bin/progress-push.sh reads the jobs worker's GET /api/progress/stamps, adds
# the hub-local facts the worker cannot see (held build rows, owed tickets,
# pause flags, which detectors are hub-scoped), restricts it to the projects
# fleet.conf declares, attaches the thresholds from its own settings knobs, and
# POSTs the lot to the watchdog. Driven against a fixture harness with a fake curl.
#
# What this pins:
#   P1 the payload: stamps relayed, pending = queued - held (build), queued
#      (merge), owed (triage); a declared project the DB never saw is present
#      and empty; an undeclared DB project is dropped; cfg carries every knob's
#      default (triage NOT in the silent cadences, share-mirror NOT a detector
#      until its credential exists, a daily and a weekly no-merge window,
#      lead-review -> any); detector_hub comes from the lane catalog's scope;
#      the GET asks for the knob's detectors and windows with the bearer; the
#      POST is bounded and uses env/.watchdog-secret over WATCHDOG_SECRET.
#   P2 knobs are the config: env overrides reach cfg and the GET; a malformed
#      map entry is dropped, not guessed at.
#   P3 an unreachable jobs worker still pushes — errors names it and the DB
#      halves of pending are null (unknown), never 0.
#   P4 a section the worker could not read rides through in errors.
#   P5 pause flags: paused-<project> pauses that project; all-off pushes an
#      all-off MARKER (so the watchdog says "fleet all-off", not "hub lease").
#   P6 no secret, or an empty fleet.conf: nothing is pushed.
#   P7 --dry-run: asks the watchdog what WOULD page for this live snapshot,
#      prints it, and never stores or pages.
# Run from anywhere: tests/progress-push.k2-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state/pool/alpha-os" "$T/flags" "$T/env" "$T/fakebin" "$T/catalog"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
cp -R "$DIR/bin/lib/jobs" "$T/bin/lib/"
genv() { printf 'HARNESS_SECRET=test-secret\nWATCHDOG_SECRET=fixture-watchdog-env\nWATCHDOG_URL=https://wd-fixture.example\nJOBS_URL=https://jobs-fixture.example\n' > "$T/env/global.env"; }
genv
# The lane catalog the hub renders: only `.lanes[].id/.scope` is read.
cat > "$T/catalog/lanes.json" <<'EOF'
{"lanes":[{"id":"fleet-slo","scope":"hub"},{"id":"pipeline-health","scope":"hub"},{"id":"cost-rollup","scope":"hub"},
          {"id":"ci-minutes-watch","scope":"hub"},{"id":"alert-warn-flush","scope":"box"}]}
EOF

# The stamps GET is told apart by its URL and answers like curl -w '\n%{http_code}';
# the watchdog POSTs read their body from stdin.
cat > "$T/fakebin/curl" <<SH
#!/bin/bash
case "\$*" in
  */api/progress/stamps*)
    printf '%s\n' "\$*" > "$T/GET.args"
    [ "\$(cat "$T/mode")" = down ] && exit 7
    cat "$T/stamps-fixture"; printf '\n200'; exit 0 ;;
  */api/progress/dry-run*)
    printf '%s\n' "\$*" > "$T/DRY.args"
    cat > "$T/DRY.json"
    printf '%s' '{"cfg_ok":true,"cfg_error":null,"clamped":[],"note":"a live incident needs 2 consecutive failing ticks","incidents":[{"key":"silent:alpha-os:merge","text":"alpha-os merge: 1 pending"}]}'
    exit 0 ;;
  # TEST-CHANGE BH-4153: paused-<project> is a row read DB-first now, and the
  # exit-7 catch-all below makes it unreadable, which fails closed (every project
  # pushed as paused). No row exists here: 404 = off. P5's flags/ file still
  # pauses through the lazy import / local hold (the import PUT hits exit 7).
  */api/flags/*) printf '{"error":"not found"}\n404'; exit 0 ;;
  */api/progress*)
    printf '%s\n' "\$*" > "$T/POST.args"
    cat /dev/fd/3 > "$T/POST.auth"
    cat > "$T/PUSH.json"; printf 'ok'; exit 0 ;;
esac
exit 7
SH
chmod +x "$T/fakebin/curl"

FLEET='alpha-os Org/alpha https://a.example /api/board 2 box-alpha
beta-os  Org/beta  https://b.example /api/board 4 box-beta'
printf '%s\n' "$FLEET" > "$T/fleet.conf"

FIX_OK='{"as_of":"2026-09-25T12:00:00Z","spend_min":60,"long_min":[1440,10080],"lookback_h":168,
 "projects":{
  "alpha-os":{"stamps":{"triage":"2026-09-25T11:55:00Z","build_ok":"2026-09-25T10:00:00Z","build_result":"2026-09-25T11:00:00Z","review":null,"merge":"2026-09-25T09:00:00Z","qa":null,"cost":"2026-09-25T11:58:00Z"},
              "spend":{"execute":12.5},"spend_long":{"1440":80,"10080":300},"queued":{"build":3,"merge":1}},
  "zeta-os":{"stamps":{"triage":"2026-09-25T11:55:00Z"},"spend":{},"spend_long":{"1440":0,"10080":0},"queued":{"build":9,"merge":9}}},
 "detectors":[{"lane":"fleet-slo","project":"-","box":"box-hub","at":"2026-09-25T11:50:00Z","outcome":"ran","why":null}],
 "errors":[]}'

OUT=""
run() {
  rm -f "$T/PUSH.json" "$T/GET.args" "$T/POST.args" "$T/DRY.json" "$T/DRY.args"
  OUT=$(env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$T" FLEET_CONF="$T/fleet.conf" \
    JOBS_RETRY_SLEEP=0 JOBS_RETRIES=0 LANE_REGISTRY="${REGF-$T/catalog/lanes.json}" "$@" bash "$DIR/bin/progress-push.sh" ${ARGS:-} </dev/null 2>/dev/null)
}
q() { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }
fixture() { echo ok > "$T/mode"; printf '%s' "$1" > "$T/stamps-fixture"; }

# ── P1 ──────────────────────────────────────────────────────────────────────
fixture "$FIX_OK"
touch "$T/state/pool/alpha-os/TK-1.held"
printf '{"alpha-os":{"count":2}}' > "$T/state/stale-owed.json"
printf 'wd-secret\n' > "$T/env/.watchdog-secret"
run
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "P1: the push must be valid JSON (got: $(head -c 300 "$T/PUSH.json" 2>/dev/null))"
[ "$(q '.projects["alpha-os"].pending | tojson')" = '{"build":2,"merge":1,"triage":2}' ] \
  && ok || bad "P1: pending = queued-held / queued / owed (got: $(q '.projects["alpha-os"].pending|tojson'))"
[ "$(q '.projects["alpha-os"].stamps.merge')" = "2026-09-25T09:00:00Z" ] && ok || bad "P1: stamps are relayed as-is"
[ "$(q '.projects["alpha-os"].spend.execute')/$(q '.projects["alpha-os"].spend_long|tojson')" = '12.5/{"1440":80,"10080":300}' ] \
  && ok || bad "P1: spend is relayed (got: $(q '.projects["alpha-os"]|[.spend,.spend_long]|tojson'))"
[ "$(q '.projects["beta-os"].stamps|tojson')/$(q '.projects["beta-os"].pending|tojson')" = '{}/{"build":0,"merge":0,"triage":0}' ] \
  && ok || bad "P1: a declared project the DB never saw is present, empty (got: $(q '.projects["beta-os"]|tojson'))"
[ "$(q '.projects|has("zeta-os")')" = false ] && ok || bad "P1: a DB project fleet.conf does not declare is dropped"
[ "$(q '.projects["alpha-os"].paused')/$(q 'has("all_off")')" = false/false ] && ok || bad "P1: not paused, no all-off marker"
[ "$(q '.detectors|length')" = 1 ] && ok || bad "P1: detector rows are relayed"
[ "$(q '.errors|tojson')" = '[]' ] && ok || bad "P1: no errors (got: $(q '.errors|tojson'))"
[ "$(q '[.cfg.spend_window_min,.cfg.spend_min_usd,.cfg.spend_quiet_min,.cfg.silent_mult,.cfg.detector_mult,.cfg.repage_min]|map(tostring)|join(",")')" \
  = "60,5,180,2,2,360" ] && ok || bad "P1: cfg carries the knob defaults (got: $(q '.cfg|tojson'))"
[ "$(q '.cfg.nomerge|tojson')" = '{"1440":50,"10080":250}' ] && ok || bad "P1: a daily and a weekly no-merge window (got: $(q '.cfg.nomerge|tojson'))"
[ "$(q '.cfg.lane_cadence_min|tojson')" = '{"build":120,"merge":60}' ] \
  && ok || bad "P1: triage is NOT a silent-stop lane by default; merge 60 (got: $(q '.cfg.lane_cadence_min|tojson'))"
[ "$(q '.cfg.stage_lanes.execute')/$(q '.cfg.stage_lanes.review')/$(q '.cfg.stage_lanes["lead-review"]')" = "build/review/any" ] \
  && ok || bad "P1: stage->lane map parsed, lead-review -> any (got: $(q '.cfg.stage_lanes|tojson'))"
[ "$(q '.cfg.detectors|tojson')" = '{"fleet-slo":15,"pipeline-health":15,"cost-rollup":60,"alert-warn-flush":30,"ci-minutes-watch":360,"progress-push":10}' ] \
  && ok || bad "P1: detector cadences, share-mirror out until its credential exists (got: $(q '.cfg.detectors|tojson'))"
[ "$(q '.cfg.detector_hub|tojson')" = '["ci-minutes-watch","cost-rollup","fleet-slo","pipeline-health"]' ] \
  && ok || bad "P1: hub-scope detectors from the lane catalog (got: $(q '.cfg.detector_hub|tojson'))"
GA=$(cat "$T/GET.args" 2>/dev/null)
case "$GA" in *"https://jobs-fixture.example/api/progress/stamps?"*) ok ;; *) bad "P1: the GET goes to JOBS_URL (got: $GA)" ;; esac
case "$GA" in *"detectors=alert-warn-flush,ci-minutes-watch,cost-rollup,fleet-slo,pipeline-health") ok ;; *) bad "P1: the GET asks for every configured detector but the push itself (got: $GA)" ;; esac
case "$GA" in *"spend_min=60"*"long_min=1440,10080"*) ok ;; *) bad "P1: the GET carries the windows (got: $GA)" ;; esac
case "$GA" in *"Bearer test-secret"*) ok ;; *) bad "P1: the jobs GET is authed with the jobs bearer (got: $GA)" ;; esac
PA=$(cat "$T/POST.args" 2>/dev/null)
case "$PA $(cat "$T/POST.auth" 2>/dev/null)" in *"https://wd-fixture.example/api/progress"*"Bearer wd-secret"*) ok ;; *) bad "P1: the POST uses env/.watchdog-secret first, like watchdog-ping.sh (got: $PA)" ;; esac
case "$PA" in *"-m 15"*) ok ;; *) bad "P1: the POST is bounded (got: $PA)" ;; esac
[ "$(grep -c 'progress-push' "$T/logs/progress-push.log" 2>/dev/null)" = 1 ] && ok || bad "P1: one log line per run"
rm -f "$T/env/.watchdog-secret"; run
case "$(cat "$T/POST.args" 2>/dev/null) $(cat "$T/POST.auth" 2>/dev/null)" in *"/api/progress"*"Bearer fixture-watchdog-env"*) ok ;; *) bad "P1: without the file, WATCHDOG_SECRET" ;; esac

# ── P2: knobs ───────────────────────────────────────────────────────────────
run PROGRESS_SILENT_MULT=4 PROGRESS_DETECTORS="pipeline-health:15,fleet-slo:ten,progress-push:10" PROGRESS_SPEND_WINDOW_MIN=30 PROGRESS_NOMERGE="2880:90"
[ "$(q '.cfg.silent_mult')" = 4 ] && ok || bad "P2: PROGRESS_SILENT_MULT reaches cfg"
[ "$(q '.cfg.detectors|tojson')" = '{"pipeline-health":15,"progress-push":10}' ] \
  && ok || bad "P2: a malformed map entry is dropped (got: $(q '.cfg.detectors|tojson'))"
[ "$(q '.cfg.nomerge|tojson')" = '{"2880":90}' ] && ok || bad "P2: PROGRESS_NOMERGE reaches cfg (got: $(q '.cfg.nomerge|tojson'))"
GA=$(cat "$T/GET.args" 2>/dev/null)
case "$GA" in *"detectors=pipeline-health") ok ;; *) bad "P2: the knob's detectors are what is asked for (got: $GA)" ;; esac
case "$GA" in *"spend_min=30"*"long_min=2880"*) ok ;; *) bad "P2: the window knobs reach the GET (got: $GA)" ;; esac

# ── P3: jobs worker unreachable ─────────────────────────────────────────────
fixture "$FIX_OK"; echo down > "$T/mode"
run
[ -s "$T/PUSH.json" ] && ok || bad "P3: the push still happens"
[ "$(q '.errors|tojson')" = '["jobs-unreachable"]' ] && ok || bad "P3: named (got: $(q '.errors|tojson'))"
[ "$(q '.projects["alpha-os"].pending|tojson')" = '{"build":null,"merge":null,"triage":2}' ] \
  && ok || bad "P3: the DB halves are unknown, the local half stays (got: $(q '.projects["alpha-os"].pending|tojson'))"

# ── P4: a section error rides through ───────────────────────────────────────
fixture "$(printf '%s' "$FIX_OK" | jq -c '.errors=["cost"] | .projects["alpha-os"].spend=null | .projects["alpha-os"].spend_long=null')"
run
[ "$(q '.errors|tojson')" = '["cost"]' ] && ok || bad "P4: section errors relayed (got: $(q '.errors|tojson'))"
[ "$(q '.projects["alpha-os"].spend')/$(q '.projects["alpha-os"].spend_long')" = null/null ] && ok || bad "P4: unknown spend stays null"

# ── P5: pause flags ─────────────────────────────────────────────────────────
fixture "$FIX_OK"
touch "$T/flags/paused-alpha-os"; run
[ "$(q '.projects["alpha-os"].paused')/$(q '.projects["beta-os"].paused')" = true/false ] \
  && ok || bad "P5: paused-<project> pauses that project only"
rm -f "$T/flags/paused-alpha-os"; touch "$T/flags/all-off"; run
[ "$(q '.all_off')" = true ] && ok || bad "P5: all-off pushes the marker (got: $(head -c 200 "$T/PUSH.json" 2>/dev/null))"
[ "$(q '.cfg.detectors["progress-push"]')" = 10 ] && ok || bad "P5: the marker carries the config"
[ -e "$T/GET.args" ] && bad "P5: under all-off nothing else is read" || ok
rm -f "$T/flags/all-off"

# ── P6: nothing to say ──────────────────────────────────────────────────────
printf 'WATCHDOG_URL=https://wd-fixture.example\nJOBS_URL=https://jobs-fixture.example\n' > "$T/env/global.env"
run
[ -e "$T/PUSH.json" ] && bad "P6: no secret, no push" || ok
genv
: > "$T/fleet.conf"; run
[ -e "$T/PUSH.json" ] && bad "P6: an empty fleet.conf pushes nothing (silence is the signal)" || ok
printf '%s\n' "$FLEET" > "$T/fleet.conf"

# ── P7: --dry-run ───────────────────────────────────────────────────────────
fixture "$FIX_OK"
ARGS=--dry-run run
[ -e "$T/PUSH.json" ] && bad "P7: a dry run never stores a snapshot" || ok
jq -e '.projects["alpha-os"].pending.build == 2' "$T/DRY.json" >/dev/null 2>&1 && ok || bad "P7: the dry run sends the same payload (got: $(head -c 200 "$T/DRY.json" 2>/dev/null))"
case "$OUT" in *"silent:alpha-os:merge"*) ok ;; *) bad "P7: it prints what WOULD page (got: $OUT)" ;; esac
case "$OUT" in *"2 consecutive"*) ok ;; *) bad "P7: it prints the confirm note (got: $OUT)" ;; esac
[ "$(grep -c 'dry' "$T/logs/progress-push.log" 2>/dev/null)" = 0 ] && ok || bad "P7: a dry run writes no lane log line"

# ── P8: nit 3 — the registry comes through the loader; unreadable is SAID ────
rm -f "$T/logs/ALERTS.log"
REGF="$T/catalog/nope.json" run
[ "$(q '.errors|index("registry") != null')" = true ] && ok || bad "P8: an unreadable registry is named in errors (got: $(q '.errors|tojson'))"
[ "$(q '.cfg.detector_hub|tojson')" = '[]' ] && ok || bad "P8: no scope known, none claimed"
REGF="$T/catalog/nope.json" run
[ "$(grep -c 'registry' "$T/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "P8: ONE warn line across two unreadable runs (got: $(cat "$T/logs/ALERTS.log" 2>/dev/null))"
grep -q 'WARN' "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "P8: the line is a warn"
run
[ "$(q '.cfg.detector_hub|length')" = 4 ] && [ "$(q '.errors|tojson')" = '[]' ] && ok || bad "P8: readable again, back to normal"
[ -e "$T/flags/warned-progress-push-registry" ] && bad "P8: the warn marker clears on recovery" || ok
grep -q 'lanes_json_path' "$DIR/bin/progress-push.sh" && ok || bad "P8: the script resolves the registry through the loader"
grep -q '/catalog/lanes.json' "$DIR/bin/progress-push.sh" && bad "P8: no direct read of catalog/lanes.json" || ok

# ── P9: nit 5 — the public copy publishes (and so stamps) at least daily ────
WF="$DIR/.github/workflows/publish-cromford.yml"
grep -qE "^[[:space:]]+- cron: '[0-9]+ [0-9]+ \* \* \*'" "$WF" && ok || bad "P9: publish-cromford.yml has a daily schedule trigger"
grep -q 'api/stamp/share-mirror' "$WF" && ok || bad "P9: publish-cromford.yml stamps share-mirror"

echo "progress-push.k2: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
