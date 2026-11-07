#!/bin/bash
# tests/fleet-status-standby.bh-401-test.sh — BH-401.1 (issue #1921): the hub's
# fleet-status push reads the watchdog's standby list and carries it as a
# top-level `.standby`, driven against a fixture harness with a fake curl.
#
# What this pins:
#   F1 a good list is projected to the six issue fields, the GET is bounded
#      (-m 5), goes to WATCHDOG_URL, and `.hub` keeps its nine keys;
#   F2 an unreachable watchdog is `.standby == null` plus a reason, and the
#      dead-man push still happens — absent is never an empty list;
#   F3 non-JSON / non-array answers are named (nonjson / shape), and a real
#      empty list stays `[]` with no error;
#   F4 the 60000-byte backstop sheds `.standby` and `.standby_error`.
# Run from anywhere: tests/fleet-status-standby.bh-401-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
cp "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_SECRET=fixture-watchdog-secret\nWATCHDOG_URL=https://wd-fixture.example\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# The standby GET is told apart by its URL; everything else is the status POST.
cat > "$T/fakebin/curl" <<SH
#!/bin/bash
case "\$*" in
  */api/standby*)
    printf '%s\n' "\$*" > "$T/GET.args"
    [ "\$(cat "$T/mode")" = down ] && exit 7
    cat "$T/standby-fixture"; exit 0 ;;
esac
cat > "$T/PUSH.json"
SH
chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
EOF

run() {
  rm -f "$T/PUSH.json" "$T/BEAT.json" "$T/GET.args"
  PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh" </dev/null >/dev/null 2>&1
}
q() { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }
fixture() { echo ok > "$T/mode"; printf '%s' "$1" > "$T/standby-fixture"; }

# ── F1: a good list ─────────────────────────────────────────────────────────
fixture '[{"box":"box-small","of":"box-hub","snapshot":"20260924T120000Z","ok":true,"report_age_min":2,"stream_age_min":7,"extra":1}]'
run
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "F1: the push must be valid JSON"
[ "$(q '.standby[0] | [.box,.of,(.stream_age_min|tostring),(.report_age_min|tostring),.snapshot,(.ok|tostring)] | join(",")')" \
  = "box-small,box-hub,7,2,20260924T120000Z,true" ] \
  && ok || bad "F1: .standby[0] carries the reported row (got: $(q '.standby|tojson'))"
[ "$(q '.standby[0] | keys | join(",")')" = "box,of,ok,report_age_min,snapshot,stream_age_min" ] \
  && ok || bad "F1: rows are projected to the six issue fields (got: $(q '.standby[0]|keys|tojson'))"
[ "$(q 'has("standby_error")')" = false ] && ok || bad "F1: a good list must carry no standby_error"
[ "$(q '.hub | keys | join(",")')" = "disk_pct,epoch,holder,lease_age_s,lease_alert,load1,mem_total_mb,mem_used_mb,uptime_s" ] \
  && ok || bad "F1: .hub keeps its nine keys (got: $(q '.hub|keys|tojson'))"
GA=$(cat "$T/GET.args" 2>/dev/null)
case "$GA" in *"-m 5"*) ok ;; *) bad "F1: the standby GET must be bounded by -m 5 (got: $GA)" ;; esac
case "$GA" in *"https://wd-fixture.example/api/standby"*) ok ;; *) bad "F1: the GET must go to WATCHDOG_URL using a header (got: $GA)" ;; esac
case "$GA" in *"-X POST"*) bad "F1: the standby read must be a GET (got: $GA)" ;; *) ok ;; esac

# ── F2: unreachable watchdog ────────────────────────────────────────────────
fixture '[]'; echo down > "$T/mode"
run
[ -s "$T/PUSH.json" ] && ok || bad "F2: the dead-man push must still happen when the standby GET fails"
[ "$(q '.standby')" = null ] && ok || bad "F2: unreachable is null, never [] (got: $(q '.standby|tojson'))"
[ "$(q '.standby_error')" = unreachable ] && ok || bad "F2: unreachable must be named (got: $(q '.standby_error|tojson'))"
[ "$(q 'has("projects")')" = true ] && ok || bad "F2: the rest of the snapshot must survive"

# ── F3: nonjson / shape / empty ─────────────────────────────────────────────
fixture 'not json'; run
[ "$(q '.standby')/$(q '.standby_error')" = "null/nonjson" ] \
  && ok || bad "F3: non-JSON is null + nonjson (got: $(q '[.standby,.standby_error]|tojson'))"
fixture '{}'; run
[ "$(q '.standby')/$(q '.standby_error')" = "null/shape" ] \
  && ok || bad "F3: a non-array is null + shape (got: $(q '[.standby,.standby_error]|tojson'))"
fixture '[]'; run
[ "$(q '.standby|tojson')" = "[]" ] && ok || bad "F3: a real empty list stays [] (got: $(q '.standby|tojson'))"
[ "$(q 'has("standby_error")')" = false ] && ok || bad "F3: an empty list is not an error"

# ── F4: the size backstop sheds .standby and .standby_error ────────────────
# The pad rides in on stale_owed (the gh-quota B5 technique).
pad() { jq -n --arg k "$(printf 'p%.0s' $(seq 1 61000))" '{($k):{count:3}}' > "$T/state/stale-owed.json"; rm -f "$T/state/stale-owed-reported.json"; }
pad
fixture '[{"box":"box-small","of":"box-hub","snapshot":"20260924T120000Z","ok":true,"report_age_min":2,"stream_age_min":7}]'
run
[ "$(q '.snapshot_trimmed')" = size ] && ok || bad "F4: an oversized payload must be trimmed (got: $(q 'keys|tojson'))"
[ "$(q 'has("standby")')" = false ] && ok || bad "F4: .standby must be shed"
pad; echo down > "$T/mode"; run
[ "$(q '.snapshot_trimmed')/$(q 'has("standby_error")')" = size/false ] \
  && ok || bad "F4: .standby_error must be shed too (got: $(q 'keys|tojson'))"

echo "fleet-status-standby.bh-401: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
