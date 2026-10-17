#!/bin/bash
# tests/flags-written.bh-6805-test.sh — BH-6805: the box client reads the
# worker's 200 {"flag":null,"written":true} (writePorted: the write committed,
# the read-back hit a D1 overload) as a LANDED write. flag_set, flag_clear and
# _flag_import_one cache the state with no row, return 0 and send no second
# request; before this, each returned 1 and its caller re-sent the write.
#
#   W1-W3  written:true on the PUT, the DELETE and the import PUT: rc 0, one request
#   N1-N4  no written, written:false, written:"true", a row for another name: rc 1
#   N5     a real row still takes the row path (set_at from the row)
#
# The worker is a PATH `curl` stub: PUT/DELETE answer $ST/answer with 200, GET
# answers $ST/get-status (503, not "overloaded", so nothing is re-sent).
# No network, no model. Exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "flags-written.bh-6805: jq missing, cannot run"; exit 1; }

S="$T/h"; ST="$T/stub"
mkdir -p "$S/bin/lib/jobs" "$S/flags" "$S/state" "$S/logs" "$S/env" "$ST" "$T/fakebin"
: > "$S/env/global.env"
for s in bin/jobs-client.sh bin/lib/flags.sh bin/fleet-conf.sh bin/box-for.sh; do
  scratch_install_closure "$s" "$S" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
printf 'p org/p https://x.example /api/board 2 boxa\n' > "$S/fleet.conf"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
ST="${STUB_DIR:?}"
URL="${!#}"; METHOD=GET
while [ $# -gt 1 ]; do case "$1" in -X) METHOD="$2"; shift 2 ;; *) shift ;; esac; done
P=${URL#http://stub}
printf '%s %s\n' "$METHOD" "${P%%\?*}" >> "$ST/curl.log"
case "$METHOD" in
  PUT|DELETE) printf '%s\n200' "$(cat "$ST/answer")" ;;
  GET) if [ "$(cat "$ST/get-status")" = 404 ]; then printf '{"error":"not found"}\n404'
       else printf '{"error":"harness_flags unavailable","retryable":true}\n503'; fi ;;
  *) printf '{}\n404' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

reset() { # reset <answer> [get-status]
  scratch_rm "$S/flags"; scratch_rm "$S/state/flags-cache"; mkdir -p "$S/flags"
  : > "$S/logs/jobs-client.log"; : > "$ST/curl.log"
  printf '%s' "$1" > "$ST/answer"; echo "${2:-503}" > "$ST/get-status"
}
lib() {
  env HARNESS="$S" JOBS_URL=http://stub HARNESS_SECRET=x JOBS_BOX=boxa JOBS_RETRIES=0 \
      STUB_DIR="$ST" PATH="$T/fakebin:$PATH" FLEET_CONF="$S/fleet.conf" HUB_BOX_NAME=box-hub \
      bash -c '. "$HARNESS/bin/lib/flags.sh" || exit 99; '"$1" 2>>"$T/stderr"
}
count() { grep -c "^$1 " "$ST/curl.log" 2>/dev/null || true; }
cache() { jq -r "$1" "$S/state/flags-cache/fleet/paused-p" 2>/dev/null; }
logged() { grep -c "$1" "$S/logs/jobs-client.log" 2>/dev/null || true; }
WRITTEN='{"flag":null,"written":true}'

# W1 flag_set on written:true
reset "$WRITTEN"
eq "W1 flag_set rc" "$(lib 'flag_set paused-p on r; echo $?')" "0"
eq "W1 exactly one PUT" "$(count PUT)" "1"
eq "W1 cache on" "$(cache .on)" "true"
eq "W1 cache src" "$(cache .src)" "db"
[ -e "$S/flags/paused-p" ] && bad "W1 a flags/paused-p file was written" || ok
eq "W1 no 'not written' line" "$(logged 'not written')" "0"
eq "W1 'cached without a row' logged" "$(logged 'cached without a row')" "1"
eq "W1 flag_has reads it back as on" "$(lib 'flag_has paused-p; echo $?')" "0"

# W2 flag_clear on written:true
reset "$WRITTEN"
eq "W2 flag_clear rc" "$(lib 'flag_clear paused-p r; echo $?')" "0"
eq "W2 exactly one DELETE" "$(count DELETE)" "1"
eq "W2 no PUT" "$(count PUT)" "0"
eq "W2 cache off" "$(cache .on)" "false"
eq "W2 flag_has reads it back as off" "$(lib 'flag_has paused-p; echo $?')" "1"

# W3 _flag_import_one on written:true, no row before
reset "$WRITTEN" 404
echo legacy > "$S/flags/paused-p"
eq "W3 import output" "$(lib '_flag_import_one paused-p; echo "rc=$?"')" "imported paused-p fleet
rc=0"
[ -e "$S/flags/paused-p" ] && bad "W3 the legacy file is still there" || ok
eq "W3 exactly one PUT" "$(count PUT)" "1"
eq "W3 cache on" "$(cache .on)" "true"

# N1-N4: answers that are not a landed write
reset '{"flag":null}'
eq "N1 no written: rc" "$(lib 'flag_set paused-p on r; echo $?')" "1"
eq "N1 'not written' logged" "$(logged 'not written')" "1"
eq "N1 no 'cached without a row'" "$(logged 'cached without a row')" "0"
reset '{"flag":null,"written":false}'
eq "N2 written:false rc" "$(lib 'flag_set paused-p on r; echo $?')" "1"
reset '{"flag":null,"written":"true"}'
eq "N3 written as a string rc" "$(lib 'flag_set paused-p on r; echo $?')" "1"
reset '{"written":true,"flag":{"name":"other","scope":"fleet","value":null,"set_at":"2026-10-16T00:00:00Z","cleared_at":null}}'
eq "N4 a row for another name rc" "$(lib 'flag_set paused-p on r; echo $?')" "1"

# N5 a real row still takes the row path
reset '{"flag":{"name":"paused-p","scope":"fleet","value":null,"set_at":"2026-10-16T01:02:03Z","cleared_at":null}}'
eq "N5 row rc" "$(lib 'flag_set paused-p on r; echo $?')" "0"
eq "N5 cache set_at from the row" "$(cache .set_at)" "2026-10-16T01:02:03Z"

echo "flags-written.bh-6805: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
