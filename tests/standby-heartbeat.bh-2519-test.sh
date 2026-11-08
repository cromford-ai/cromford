#!/bin/bash
# tests/standby-heartbeat.bh-2519-test.sh — bin/standby-heartbeat.sh, the
# standby's second report after a stream run (BH-2640, part of #2519): one POST
# {box, of, snapshot, ok} to the hub's /api/hub/standby/heartbeat, fail-open.
#
# What is proved here:
#   S1  a configured box POSTs exactly one body to /api/hub/standby/heartbeat,
#       box = bin/box-name.sh's answer, ok = (rc == 0), and prints the one line
#       `standby heartbeat recorded`; the secret never reaches stdout;
#   S2  every failure or missing piece still exits 0 with its own one line:
#       HTTP 500 (no ALERTS line), a transport failure, no secret, an empty
#       JOBS_URL, no box name, a bad <of>, a wrong arg count, a jobs-client with
#       a missing module — and the unconfigured ones never call curl;
#   S3  the REAL bin/state-restore.sh --standby sends exactly ONE heartbeat per
#       run after the watchdog report (which is unchanged), keeps its exit code
#       (0 on success, 1 on a tampered object), and a refusal sends none.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/standby-heartbeat.bh-2519-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

CANARY=hbsecret-canary-2640
TS1=20260915T232000Z
HB_PATH=/api/hub/standby/heartbeat

# ── the scratch harness: the real heartbeat, client, modules and box-name ────
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/state" "$T/fakebin"
cp "$DIR/bin/standby-heartbeat.sh" "$H/bin/" || { echo "FAIL: missing bin/standby-heartbeat.sh"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-name.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" || exit 1

# curl stand-in. Jobs requests (-w '\n%{http_code}') are logged to
# $T/jobs.log as "<url> <auth?> <body>" and answered $CURL_HTTP; watchdog
# requests (wd.test.invalid) go to $T/wd.log. $CURL_RC != 0 fails the transport.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
url=""; body=""; auth=noauth; prev=""
for a in "$@"; do
  case "$prev" in --data-binary|--data) body=$a ;; -H) case "$a" in authorization:*) auth=auth ;; esac ;; esac
  case "$a" in http*://*) url=$a ;; esac
  prev=$a
done
case "$url" in
  https://wd.test.invalid/*) printf '%s %s\n' "$url" "$body" >> "$STUB_DIR/wd.log"; exit "${WD_RC:-0}" ;;
esac
printf '%s %s %s\n' "$url" "$auth" "$body" >> "$STUB_DIR/jobs.log"
[ "${CURL_RC:-0}" = 0 ] || exit "$CURL_RC"
printf '%s\n%s' '{"ok":true}' "${CURL_HTTP:-200}"
SH
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" JOBS_RETRY_SLEEP=0
unset HARNESS_SECRET JOBS_URL JOBS_BOX HARNESS_ENV_DIR

genv() { printf 'HARNESS_SECRET=%s\nJOBS_URL=%s\n' "$CANARY" "${1-https://jobs.test.invalid}" > "$H/env/global.env"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
njobs() { lines "$T/jobs.log"; }
hb() { # hb <args...> — the shipped script, as state-restore calls it
  env HARNESS="$H" BOX_NAME="${HB_BOX-standby-box}" bash "$H/bin/standby-heartbeat.sh" "$@" > "$T/hb.out" 2>"$T/hb.err"
}
reset() { rm -f "$T/jobs.log"; : > "$H/logs/ALERTS.log"; genv; unset CURL_HTTP CURL_RC; }

# ── S1: recorded ─────────────────────────────────────────────────────────────
reset
hb hub "$TS1" 0; RC=$?
check "S1 rc" "$RC" 0
check "S1 stdout" "$(cat "$T/hb.out")" "standby heartbeat recorded"
check "S1 one request" "$(njobs)" 1
check "S1 url" "$(cut -d' ' -f1 "$T/jobs.log")" "https://jobs.test.invalid$HB_PATH"
check "S1 bearer sent" "$(cut -d' ' -f2 "$T/jobs.log")" auth
check "S1 body" "$(cut -d' ' -f3- "$T/jobs.log")" "{\"box\":\"standby-box\",\"of\":\"hub\",\"snapshot\":\"$TS1\",\"ok\":true}"
check "S1 ok is a boolean" "$(cut -d' ' -f3- "$T/jobs.log" | jq -r '.ok|type')" boolean
grep -q "$CANARY" "$T/hb.out" "$T/hb.err" && bad "S1 the secret reached output" || ok
grep -q "jobs.test.invalid" "$T/hb.out" && bad "S1 the URL reached stdout" || ok
reset
hb hub "$TS1" 1; RC=$?
check "S1 rc=1 exit" "$RC" 0
check "S1 rc=1 body ok" "$(cut -d' ' -f3- "$T/jobs.log" | jq -c .ok)" false
reset
hb hub "" 1; RC=$?
check "S1 empty snapshot rc" "$RC" 0
check "S1 empty snapshot body" "$(cut -d' ' -f3- "$T/jobs.log" | jq -c '[.snapshot,.ok]')" '["",false]'

# ── S2: every failure exits 0 with one line ─────────────────────────────────
s2() { # s2 <label> <want stdout> <want jobs requests> <args...>
  local label="$1" want="$2" wantn="$3" rc; shift 3
  hb "$@"; rc=$?
  check "S2 $label rc" "$rc" 0
  check "S2 $label stdout" "$(cat "$T/hb.out")" "$want"
  check "S2 $label requests" "$(njobs)" "$wantn"
}
reset; export CURL_HTTP=500
s2 "http 500" "standby heartbeat failed (HTTP 500, fail-open)" 1 hub "$TS1" 0
check "S2 http 500 no ALERTS line" "$(grep -c . "$H/logs/ALERTS.log")" 0
reset; export CURL_RC=28 JOBS_RETRIES=0
s2 "transport" "standby heartbeat failed (HTTP none, fail-open)" 1 hub "$TS1" 0
check "S2 transport no ALERTS line" "$(grep -c . "$H/logs/ALERTS.log")" 0
unset JOBS_RETRIES
reset; : > "$H/env/global.env"
s2 "no secret" "standby heartbeat skipped: HARNESS_SECRET not configured" 0 hub "$TS1" 0
reset; genv ""
s2 "empty JOBS_URL" "standby heartbeat skipped: JOBS_URL not configured" 0 hub "$TS1" 0
reset; mv "$H/bin/box-name.sh" "$T/box-name.real"
printf '#!/bin/bash\nexit 1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"
HB_BOX="" s2 "no box name" "standby heartbeat skipped: box name not configured" 0 hub "$TS1" 0
mv "$T/box-name.real" "$H/bin/box-name.sh"
reset
s2 "of=Hub" "standby heartbeat skipped: <of> 'Hub' is not [a-z0-9-]+" 0 Hub "$TS1" 0
reset
s2 "of=../hub" "standby heartbeat skipped: <of> '../hub' is not [a-z0-9-]+" 0 ../hub "$TS1" 0
reset
s2 "two args" "standby heartbeat skipped: usage: standby-heartbeat.sh <of> <snapshot> <rc>" 0 hub "$TS1"
reset
s2 "rc not numeric" "standby heartbeat skipped: <rc> 'x' is not a number" 0 hub "$TS1" x
reset; mv "$H/bin/lib/jobs/req.sh" "$T/req.sh.bak"
hb hub "$TS1" 0; RC=$?
check "S2 missing module rc" "$RC" 0
check "S2 missing module requests" "$(njobs)" 0
mv "$T/req.sh.bak" "$H/bin/lib/jobs/req.sh"

# ── S3: the real stream run sends it, once, after the watchdog ──────────────
# Fixture shape from tests/state-restore-standby.bh-401-test.sh: the real
# bin/state-backup.sh makes the object, a fake aws serves it.
if ! command -v age >/dev/null 2>&1; then
  cat > "$T/fakebin/age" <<'SH'
#!/bin/bash
if [ "${1:-}" = "-d" ]; then
  shift; ID=""; FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in -i) ID="${2:-}"; shift 2 ;; -*) shift ;; *) FILE="$1"; shift ;; esac
  done
  if [ -n "$ID" ] && ! grep -qx 'stand-in-key-material-not-a-real-identity' "$ID" 2>/dev/null; then
    echo "age: no identity matched any of the recipients" >&2; exit 1
  fi
  if [ -n "$FILE" ]; then exec base64 -d -- "$FILE"; fi
  exec base64 -d
fi
exec base64
SH
  chmod +x "$T/fakebin/age"
fi
if ! command -v age-keygen >/dev/null 2>&1; then
  cat > "$T/fakebin/age-keygen" <<'SH'
#!/bin/bash
OUT=""
while [ $# -gt 0 ]; do case "$1" in -o) OUT="${2:-}"; shift 2 ;; *) shift ;; esac; done
[ -n "$OUT" ] && printf 'stand-in-key-material-not-a-real-identity\n' > "$OUT"
printf 'Public key: age1standin-recipient-not-a-real-key\n' >&2
SH
  chmod +x "$T/fakebin/age-keygen"
fi
if ! command -v zstd >/dev/null 2>&1; then
  printf '#!/bin/bash\nexec cat\n' > "$T/fakebin/zstd"; chmod +x "$T/fakebin/zstd"
fi
printf '#!/bin/bash\necho "*/15 * * * * true"\n' > "$T/fakebin/crontab"
printf '#!/bin/bash\necho 0000000000000000000000000000000000000000\n' > "$T/fakebin/git"
chmod +x "$T/fakebin/crontab" "$T/fakebin/git"
cat > "$T/fakebin/aws" <<SH
#!/bin/bash
S3ROOT="$T/s3"; S3META="$T/s3meta"
mkdir -p "\$S3ROOT" "\$S3META"
VERB=""
if [ "\${1:-}" = s3api ]; then VERB="\${2:-}"; shift 2; fi
BUCKET=""; KEY=""; BODY=""; PREFIX=""; META=""; OUTFILE=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --bucket) BUCKET="\$2"; shift 2 ;;
    --key) KEY="\$2"; shift 2 ;;
    --body) BODY="\$2"; shift 2 ;;
    --prefix) PREFIX="\$2"; shift 2 ;;
    --metadata) META="\$2"; shift 2 ;;
    --endpoint-url|--output|--region|--continuation-token) shift 2 ;;
    --*) shift ;;
    *) OUTFILE="\$1"; shift ;;
  esac
done
case "\$VERB" in
  put-object)
    mkdir -p "\$(dirname "\$S3ROOT/\$BUCKET/\$KEY")" "\$(dirname "\$S3META/\$BUCKET/\$KEY")"
    cp "\$BODY" "\$S3ROOT/\$BUCKET/\$KEY" || exit 253
    printf '%s\n' "\${META#sha256=}" > "\$S3META/\$BUCKET/\$KEY"
    printf '{"ETag":"stub"}\n' ;;
  head-object)
    [ -f "\$S3ROOT/\$BUCKET/\$KEY" ] || exit 254
    printf '{"ContentLength":%s,"Metadata":{"sha256":"%s"}}\n' \
      "\$(stat -c%s "\$S3ROOT/\$BUCKET/\$KEY")" "\$(cat "\$S3META/\$BUCKET/\$KEY" 2>/dev/null)" ;;
  list-objects-v2)
    [ -d "\$S3ROOT/\$BUCKET" ] || { printf '{"Contents":[]}\n'; exit 0; }
    find "\$S3ROOT/\$BUCKET" -type f -printf '%s\t%P\n' \
      | awk -F'\t' -v p="\$PREFIX" 'index(\$2, p) == 1' | LC_ALL=C sort -k2 \
      | jq -R -n -c '{Contents: [inputs | split("\t") | {Key: .[1], Size: (.[0] | tonumber)}]}' ;;
  get-object)
    [ -f "\$S3ROOT/\$BUCKET/\$KEY" ] || exit 254
    cp "\$S3ROOT/\$BUCKET/\$KEY" "\$OUTFILE" || exit 253
    printf '{"ContentLength":%s}\n' "\$(stat -c%s "\$OUTFILE")" ;;
  *) exit 252 ;;
esac
SH
chmod +x "$T/fakebin/aws"

AGEPUB=$(age-keygen -o "$T/age.key" 2>&1 | sed -n 's/^Public key: //p')
S3ENV=$(printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\nBACKUP_S3_BUCKET=bkt\nBACKUP_S3_ACCESS_KEY_ID=akid-canary-2640\nBACKUP_S3_SECRET_ACCESS_KEY=sak-canary-2640\n')
mkdir -p "$T/hub/env" "$T/hub/state" "$T/hub/logs" "$T/hub-orch" "$T/checkout" "$T/s3"
{ printf '%s\n' "$S3ENV"; printf 'HARNESS_SECRET=%s\nBACKUP_AGE_RECIPIENT=%s\n' "$CANARY" "$AGEPUB"; } > "$T/hub/env/global.env"
printf 'hub\n' > "$T/hub/state/box-id"
printf '{"hub":"state"}\n' > "$T/hub/state/x.json"
printf 'orch\n' > "$T/hub-orch/o.txt"
env HARNESS_ROOT="$T/hub" HARNESS_CHECKOUT="$T/checkout" ORCHESTRATOR_DIR="$T/hub-orch" \
    ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW=1789514400 \
    bash "$DIR/bin/state-backup.sh" > "$T/backup.out" 2>&1 \
  || bad "S3 setup: bin/state-backup.sh failed ($(tail -3 "$T/backup.out"))"
OBJ1="$T/s3/bkt/hub/$TS1.tar.zst"
[ -f "$OBJ1" ] && ok || bad "S3 setup: no object at hub/$TS1.tar.zst"

# The standby's own root: its global.env carries the jobs secret + URL, the way
# a real standby's restored hub env does.
SB="$T/sb"
mkdir -p "$SB/env"
{ printf '%s\n' "$S3ENV"; printf 'HARNESS_SECRET=%s\nJOBS_URL=https://jobs.test.invalid\n' "$CANARY"; } > "$SB/env/global.env"
printf 'wdsecret-2640\n' > "$SB/env/.watchdog-secret"
mklive() { mkdir -p "$1/logs" "$1/state" "$2"; printf 'standby-box\n' > "$1/state/box-id"; }
# The standby's name lives in ITS tree (state/box-name), not in the env, so a
# heartbeat that resolved /root/harness instead of state-restore's own root
# would name some other box.
mkdir -p "$SB/state"; printf 'standby-box\n' > "$SB/state/box-name"
rs() { # the production entry point, as the standby's stream cron runs it
  env -u HARNESS_SECRET -u HARNESS -u BOX_NAME HARNESS_ROOT="$SB" ETC_HARNESS_ENV="$T/no-such-etc" \
      WATCHDOG_URL=https://wd.test.invalid JOBS_RETRIES=0 \
      bash "$DIR/bin/state-restore.sh" "$@" > "$T/rs.out" 2>&1
}

reset; rm -f "$T/wd.log"
mklive "$T/l1" "$T/o1"
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l1" --orchestrator-live "$T/o1"; RC=$?
check "S3 success rc" "$RC" 0
check "S3 success heartbeats" "$(njobs)" 1
check "S3 success heartbeat url" "$(cut -d' ' -f1 "$T/jobs.log")" "https://jobs.test.invalid$HB_PATH"
check "S3 success heartbeat body" "$(cut -d' ' -f3- "$T/jobs.log" | jq -c '[.box,.of,.snapshot,.ok]')" "[\"standby-box\",\"hub\",\"$TS1\",true]"
check "S3 success watchdog reports" "$(lines "$T/wd.log")" 1
check "S3 success watchdog url+body" "$(cat "$T/wd.log")" \
  "https://wd.test.invalid/api/standby/standby-box {\"of\":\"hub\",\"snapshot\":\"$TS1\",\"ok\":true}"
check "S3 recorded is the last line" "$(tail -1 "$T/rs.out")" "standby heartbeat recorded"
grep -q "$CANARY" "$T/rs.out" && bad "S3 the jobs secret reached stdout" || ok

# the up-to-date re-run re-reports; with the hub answering 500 the exit code
# is unchanged and the fail-open is said
reset; rm -f "$T/wd.log"; export CURL_HTTP=500
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l1" --orchestrator-live "$T/o1"; RC=$?
check "S3 500 rc" "$RC" 0
grep -qx "up to date $TS1" "$T/rs.out" && ok || bad "S3 500: not the up-to-date path: $(cat "$T/rs.out")"
check "S3 500 heartbeats" "$(njobs)" 1
check "S3 500 line" "$(tail -1 "$T/rs.out")" "standby heartbeat failed (HTTP 500, fail-open)"
unset CURL_HTTP

# a tampered object: rc 1 kept, heartbeat ok:false
reset; rm -f "$T/wd.log"
mklive "$T/l2" "$T/o2"
printf 'x' >> "$OBJ1"
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l2" --orchestrator-live "$T/o2"; RC=$?
check "S3 failure rc" "$RC" 1
grep -q 'REFUSED: sha256 mismatch' "$T/rs.out" && ok || bad "S3 failure: no sha256 refusal: $(cat "$T/rs.out")"
check "S3 failure heartbeats" "$(njobs)" 1
check "S3 failure heartbeat body" "$(cut -d' ' -f3- "$T/jobs.log" | jq -c '[.box,.of,.snapshot,.ok]')" "[\"standby-box\",\"hub\",\"$TS1\",false]"
check "S3 failure watchdog reports" "$(lines "$T/wd.log")" 1

# a refusal before the trap (standby-of names hub, asked for nobody): no report at all
reset; rm -f "$T/wd.log"
mklive "$T/l3" "$T/o3"
printf 'box-hub hub\n' > "$T/l3/state/standby-of"
rs nobody latest --apply --standby --identity "$T/age.key" --live "$T/l3" --orchestrator-live "$T/o3"; RC=$?
check "S3 refusal rc" "$RC" 1
grep -q '^REFUSED: --standby of nobody' "$T/rs.out" && ok || bad "S3 refusal line: $(cat "$T/rs.out")"
check "S3 refusal heartbeats" "$(njobs)" 0
check "S3 refusal watchdog reports" "$(lines "$T/wd.log")" 0

echo "standby-heartbeat: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
