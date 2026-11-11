#!/bin/bash
# tests/watchdog-auth-callers.bh-9264-test.sh — BH-9264 phase 1: every caller of
# the watchdog worker sends its secret in an `Authorization: Bearer` header that
# curl reads from a config on a file descriptor. The secret is in no curl argv
# and in no URL (`?s=` is gone from every caller).
#
#   H1-H5  bin/lib/watchdog-url.sh watchdog_secret: lookup order
#          .watchdog-secret > $WATCHDOG_SECRET > $HARNESS_SECRET, CR/LF-only file
#          skipped, unreadable file skipped with no stderr, none = rc 1 + no output;
#          watchdog_curl with an empty secret = rc 1 and 0 curl calls
#   H6     a secret holding `"` and `\` reaches the real curl's header unchanged
#          (curl --libcurl over file:///dev/null, no network)
#   H7     no bash here-string in the two helpers
#   C1-C8  the 8 bin/ callers, each installed with scratch_install_closure and
#          run with a recording fake curl: (a) the watchdog route is called,
#          (b) the watchdog secret is in no argv word, (c) no URL has s=,
#          (d) the curl config for that call is the Bearer header. Each also runs
#          once with a failing curl and keeps its existing failure line or rc.
#   W1     the "Stamp the outside dead-man" step of publish-cromford.yml, run
#          with the fake curl: header from stdin config, no s= in the URL
#   S1     no non-comment line in bin/**/*.sh or .github/workflows/*.yml puts a
#          secret in a `?s=` query
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/watchdog-auth-callers.bh-9264-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null && command -v git >/dev/null \
  || { echo "jq/python3/git missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

WD=http://watchdog.invalid
WS='wd-fixture-9264'   # the watchdog secret (env/.watchdog-secret)
HS='hs-fixture-9264'   # HARNESS_SECRET (the fallback, and the jobs bearer)

# ── the fake curl ────────────────────────────────────────────────────────────
# argv (one line per call) to $CURL_LOG. The content of a --config/-K file (or
# stdin for `-K -`) goes to $CURL_CFG_LOG as "<url><TAB><config line>", one line
# per config line, or "<url><TAB>NO-CONFIG". $CURL_RC != 0 fails the call.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
cfg=""; prev=""; url=""
for a in "$@"; do
  case "$prev" in --config|-K) cfg="$a" ;; esac
  case "$a" in --config=*) cfg="${a#--config=}" ;; http://*|https://*) url="$a" ;; esac
  prev="$a"
done
if [ -n "$cfg" ]; then
  if [ "$cfg" = - ]; then body=$(cat); else body=$(cat -- "$cfg" 2>/dev/null) || body="UNREADABLE $cfg"; fi
  printf '%s\n' "$body" | while IFS= read -r l; do printf '%s\t%s\n' "$url" "$l"; done >> "$CURL_CFG_LOG"
else
  printf '%s\tNO-CONFIG\n' "$url" >> "$CURL_CFG_LOG"
fi
case "$*" in *"@-"*) [ "$cfg" = - ] || cat >/dev/null ;; esac
[ "${CURL_RC:-0}" = 0 ] || exit "$CURL_RC"
case "$url" in
  */api/standby) printf '[]' ;;
  */api/commands/ack/*) printf 'ok' ;;
  */api/commands) printf '[{"id":"c-fixture-1","ts":1,"type":"noop"}]' ;;
  *) printf '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl"
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

# check <case> <logdir> <url> [secret]: (a)-(d) for one watchdog call
check() {
  local id="$1" d="$2" url="$3" sec="${4:-$WS}" argv cfg
  argv=$(cat "$d/curl.log" 2>/dev/null); cfg=$(cat "$d/cfg.log" 2>/dev/null)
  grep -qE "(^| )$(printf '%s' "$url" | sed 's/[.[\*^$/]/\\&/g')( |$)" <<<"$argv" \
    && ok || bad "$id(a): no call to $url (argv: $(head -c 600 <<<"$argv"))"
  grep -qF -- "$sec" <<<"$argv" && bad "$id(b): the secret is in curl argv" || ok
  grep -qE 'https?://[^ ]*[?&]s=' <<<"$argv" && bad "$id(c): a URL carries s=: $(grep -oE 'https?://[^ ]*[?&]s=' <<<"$argv" | head -3)" || ok
  grep -qxF -- "$url	header = \"Authorization: Bearer $sec\"" <<<"$cfg" \
    && ok || bad "$id(d): the config for $url is not the Bearer header (cfg: $(sed "s/$sec/<sec>/g" <<<"$cfg" | head -c 600))"
}
# fresh <dir>: an empty pair of logs, exported for the fake curl
fresh() { mkdir -p "$1"; : > "$1/curl.log"; : > "$1/cfg.log"; export CURL_LOG="$1/curl.log" CURL_CFG_LOG="$1/cfg.log"; }
# box <dir> [global.env lines...]: a scratch harness with env/.watchdog-secret
box() {
  local h="$1"; shift
  mkdir -p "$h/bin/lib" "$h/env" "$h/logs" "$h/flags" "$h/state"
  printf '%s\n' "WATCHDOG_URL=$WD" "HARNESS_SECRET=$HS" "$@" > "$h/env/global.env"
  printf '%s\n' "$WS" > "$h/env/.watchdog-secret"
}
inst() { scratch_install_closure "$1" "$2" >/dev/null || bad "install $1 into $2"; }

# ── H: the helpers ───────────────────────────────────────────────────────────
. "$DIR/bin/lib/watchdog-url.sh" || { echo "cannot source bin/lib/watchdog-url.sh"; exit 1; }
HD="$T/h-env"; mkdir -p "$HD"
sec_of() { # sec_of <file content|-none-> <WATCHDOG_SECRET> <HARNESS_SECRET>
  scratch_rm "$HD/.watchdog-secret"
  [ "$1" = -none- ] || printf '%s' "$1" > "$HD/.watchdog-secret"
  OUT=$(WATCHDOG_SECRET="$2" HARNESS_SECRET="$3" watchdog_secret "$HD" 2>"$T/h.err"); RC=$?
}
sec_of "file-fixture" "" "";              [ "$RC" = 0 ] && [ "$OUT" = file-fixture ] && ok || bad "H1: file only: want file-fixture rc 0, got '$OUT' rc $RC"
sec_of $'file-fixture\r\n' "wde-fixture" "hse-fixture"; [ "$OUT" = file-fixture ] && ok || bad "H2: the file wins over both env values (got '$OUT')"
sec_of $'\r\n' "wde-fixture" "hse-fixture";  [ "$OUT" = wde-fixture ] && ok || bad "H3: a CR/LF-only file falls to WATCHDOG_SECRET (got '$OUT')"
sec_of -none- "" "hse-fixture";              [ "$OUT" = hse-fixture ] && ok || bad "H3b: no file and no WATCHDOG_SECRET falls to HARNESS_SECRET (got '$OUT')"
# H4 unreadable: mode 000 for a user; root reads any mode, so a directory there.
scratch_rm "$HD/.watchdog-secret"
if [ "$(id -u)" = 0 ]; then mkdir "$HD/.watchdog-secret"; else printf 'x-fixture' > "$HD/.watchdog-secret"; chmod 000 "$HD/.watchdog-secret"; fi
OUT=$(WATCHDOG_SECRET="wde-fixture" HARNESS_SECRET="" watchdog_secret "$HD" 2>"$T/h.err"); RC=$?
[ "$OUT" = wde-fixture ] && [ ! -s "$T/h.err" ] && ok || bad "H4: an unreadable file falls through with no stderr (got '$OUT', err: $(cat "$T/h.err"))"
scratch_rm "$HD/.watchdog-secret"
sec_of -none- "" "";  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "H5: no secret anywhere: want rc 1 and no output, got rc $RC '$OUT'"
fresh "$T/h5"
PATH="$T/fakebin:$PATH" watchdog_curl "" -fsS "$WD/api/ping/b"; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/h5/curl.log" ] && ok || bad "H5b: watchdog_curl with an empty secret: want rc 1 and 0 curl, got rc $RC ($(cat "$T/h5/curl.log"))"
fresh "$T/h5c"
PATH="$T/fakebin:$PATH" watchdog_curl "$WS" -fsS -m 10 "$WD/api/ping/b" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "H5c: watchdog_curl rc $RC"
check H5c "$T/h5c" "$WD/api/ping/b"
fresh "$T/h5d"
CURL_RC=22 PATH="$T/fakebin:$PATH" watchdog_curl "$WS" -fsS "$WD/api/ping/b" >/dev/null; RC=$?
[ "$RC" = 22 ] && ok || bad "H5d: watchdog_curl must return curl's rc (want 22, got $RC)"

# H6 the real curl parses the config back to the exact secret.
if command -v curl >/dev/null; then
  ODD='odd"fixture\x\\y'
  C_OUT=$(watchdog_curl "$ODD" -s --libcurl - file:///dev/null 2>/dev/null)
  GOT=$(printf '%s\n' "$C_OUT" | python3 -c '
import ast, re, sys
for l in sys.stdin:
    m = re.search(r"curl_slist_append\(slist1, (\".*\")\);", l)
    if m: print(ast.literal_eval(m.group(1))); break')
  [ "$GOT" = "Authorization: Bearer $ODD" ] && ok || bad "H6: real curl read the header as '$GOT', want 'Authorization: Bearer $ODD'"
else
  echo "H6: curl missing — skipped"
fi

# H7 no here-string in either helper (bash 3.2 writes it to $TMPDIR).
for f in watchdog_secret watchdog_curl; do
  BODY=$(declare -f "$f") || { bad "H7: $f is not defined"; continue; }
  grep -qF '<<<' <<<"$BODY" && bad "H7: $f uses a here-string" || ok
done

# ── C1 watchdog-ping ─────────────────────────────────────────────────────────
run_lane() { # run_lane <h> <script> [args] -> RC
  local h="$1" s="$2"; shift 2
  env -u WATCHDOG_URL -u HARNESS_SECRET -u WATCHDOG_SECRET PATH="$T/fakebin:$PATH" HARNESS="$h" \
    HARNESS_ENV_DIR="$h/env" LANE_GATE_DISABLE=1 bash "$h/$s" "$@" </dev/null >"$h/run.out" 2>&1
  RC=$?
}
H="$T/c1"; box "$H"; inst bin/watchdog-ping.sh "$H"; fresh "$H"
run_lane "$H" bin/watchdog-ping.sh box1
[ "$RC" = 0 ] && ok || bad "C1: rc $RC"
check C1 "$H" "$WD/api/ping/box1"
fresh "$H"; CURL_RC=22 run_lane "$H" bin/watchdog-ping.sh box1
[ "$RC" = 0 ] && [ -s "$H/curl.log" ] && ok || bad "C1-fail: a failed ping stays fail-quiet rc 0 (rc $RC)"

# ── C2 watchdog-poll (commands + ack) ────────────────────────────────────────
H="$T/c2"; box "$H"; inst bin/watchdog-poll.sh "$H"; fresh "$H"
run_lane "$H" bin/watchdog-poll.sh
[ "$RC" = 0 ] && ok || bad "C2: rc $RC ($(cat "$H/run.out"))"
check C2 "$H" "$WD/api/commands"
check C2-ack "$H" "$WD/api/commands/ack/c-fixture-1"
has "$H/logs/watchdog-commands.log" 'id=c-fixture-1 -> noop' && ok || bad "C2: the noop command was not journaled"
fresh "$H"; CURL_RC=22 run_lane "$H" bin/watchdog-poll.sh
[ "$RC" = 0 ] && ok || bad "C2-fail: a failed poll exits 0 (rc $RC)"
has "$H/curl.log" /api/commands/ack/ && bad "C2-fail: no ack after a failed list" || ok
# No secret anywhere: no call at all.
H="$T/c2n"; box "$H"; inst bin/watchdog-poll.sh "$H"; rm -f "$H/env/.watchdog-secret"
printf 'WATCHDOG_URL=%s\n' "$WD" > "$H/env/global.env"; fresh "$H"
run_lane "$H" bin/watchdog-poll.sh
[ "$RC" = 0 ] && [ ! -s "$H/curl.log" ] && ok || bad "C2-none: no secret means rc 0 and no call (rc $RC, $(cat "$H/curl.log"))"

# ── C3 progress-push ─────────────────────────────────────────────────────────
H="$T/c3"; box "$H" "JOBS_URL=https://jobs-fixture.invalid"
inst bin/progress-push.sh "$H"; inst bin/fleet-conf.sh "$H"; inst bin/jobs-client.sh "$H"
mkdir -p "$H/state/pool/alpha-os" "$H/catalog"
printf '{"lanes":[{"id":"fleet-slo","scope":"hub"}]}\n' > "$H/catalog/lanes.json"
printf 'alpha-os Org/alpha https://a.example /api/board 2 box-alpha\n' > "$H/fleet.conf"
prun() {
  env -i PATH="$T/fakebin:$PATH" HOME="$T" CURL_LOG="$CURL_LOG" CURL_CFG_LOG="$CURL_CFG_LOG" CURL_RC="${CURL_RC:-0}" \
    HARNESS="$H" FLEET_CONF="$H/fleet.conf" JOBS_RETRY_SLEEP=0 JOBS_RETRIES=0 LANE_REGISTRY="$H/catalog/lanes.json" \
    LANE_GATE_DISABLE=1 bash "$H/bin/progress-push.sh" </dev/null >"$H/run.out" 2>&1
  RC=$?
}
fresh "$H"; prun
check C3 "$H" "$WD/api/progress"
grep -qF -- "$HS" <<<"$(grep -F "$WD" "$H/curl.log")" && bad "C3: HARNESS_SECRET in a watchdog argv" || ok
fresh "$H"; CURL_RC=22 prun
grep -qF 'watchdog=post failed' <<<"$(grep 'projects=' "$H/logs/progress-push.log" 2>/dev/null | tail -1)" \
  && ok || bad "C3-fail: the tick line must say watchdog=post failed (log: $(tail -1 "$H/logs/progress-push.log" 2>/dev/null))"

# ── C4 tickets-snapshot-push ─────────────────────────────────────────────────
PROJ="bh9264p$$"
H="$T/c4"; box "$H"; inst bin/tickets-snapshot-push.sh "$H"
printf '#!/bin/bash\necho %s\n' "$PROJ" > "$H/bin/fleet-projects-or-alert.sh"
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in prod) echo http://board.invalid ;; board_prefix) echo /api ;; repo) echo o/r ;; esac
EOF
printf '#!/bin/bash\necho tok\n' > "$H/bin/internal-token-for.sh"
printf '#!/bin/bash\necho "$*" >> "%s/alerts.log"\n' "$H" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/"*.sh
fresh "$H"; run_lane "$H" bin/tickets-snapshot-push.sh
[ "$RC" = 0 ] && ok || bad "C4: rc $RC"
check C4 "$H" "$WD/api/tickets-snapshot"
fresh "$H"; CURL_RC=22 run_lane "$H" bin/tickets-snapshot-push.sh
has "$H/alerts.log" 'push to watchdog FAILED' && ok || bad "C4-fail: a failed push must alert (alerts: $(cat "$H/alerts.log" 2>/dev/null))"
rm -f "/tmp/snap-$PROJ.json" "/tmp/snap-$PROJ.enriched"

# ── C5 cost-rollup ───────────────────────────────────────────────────────────
H="$T/c5"; box "$H"; inst bin/cost-rollup.sh "$H"
mkdir -p "$H/builds" "$H/state/cost"
cat > "$H/bin/jobs-client.sh" <<'JC'
job_artifact_feed() { return 0; }
_jobs_req() { case "$2" in /api/metrics/cost-rows*) printf '{"cost_rows":[]}' ;; *) return 1 ;; esac; }
JC
printf '#!/bin/bash\nexit 1\n' > "$H/bin/fleet-conf.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$H" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh"
printf 'project-1 -\n' > "$H/fleet.conf"
crun() {
  env -u WATCHDOG_URL -u WATCHDOG_SECRET PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
    COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 WINDOWS_ONLY=1 STAMP_DRY=1 HARNESS_SECRET="$HS" \
    bash "$H/bin/cost-rollup.sh" </dev/null > "$H/run.out" 2>&1
}
fresh "$H"; crun
check C5 "$H" "$WD/api/cost-snapshot"
has "$H/logs/agent-rules.log" 'cost-snapshot push to watchdog FAILED' && bad "C5: a 0-rc push is not FAILED" || ok
fresh "$H"; CURL_RC=22 crun
has "$H/logs/agent-rules.log" 'cost-snapshot push to watchdog FAILED' && ok \
  || bad "C5-fail: agent-rules.log must name the FAILED push ($(grep -i snapshot "$H/logs/agent-rules.log" 2>/dev/null))"

# ── C6 state-restore --standby ───────────────────────────────────────────────
H="$T/c6"; inst bin/state-restore.sh "$H"; inst bin/restore-merge.sh "$H"
mkdir -p "$H/env" "$H/sbin" "$H/live/state"
printf '#!/bin/bash\necho standby-box\n' > "$H/bin/box-name.sh"
printf '#!/bin/bash\nexit 1\n' > "$H/bin/hub-lease.sh"
printf '#!/bin/bash\ntouch %s/hb\n' "$H" > "$H/bin/standby-heartbeat.sh"
printf '#!/bin/bash\nexit 1\n' > "$H/sbin/aws"
for b in zstd age; do printf '#!/bin/bash\nexit 0\n' > "$H/sbin/$b"; done
chmod +x "$H/bin/"*.sh "$H/sbin/"*
printf '%s\n' 'BACKUP_S3_ENDPOINT=https://s3.test.invalid' BACKUP_S3_BUCKET=bkt BACKUP_S3_ACCESS_KEY_ID=akid-fixture \
  BACKUP_S3_SECRET_ACCESS_KEY=sak-fixture "WATCHDOG_URL=$WD" > "$H/env/global.env"
printf '%s\n' "$WS" > "$H/env/.watchdog-secret"
printf 'key-fixture\n' > "$H/age.key"
srun() {
  env -u WATCHDOG_URL -u HARNESS_SECRET -u WATCHDOG_SECRET PATH="$H/sbin:$T/fakebin:$PATH" \
    HARNESS_ROOT="$H" ETC_HARNESS_ENV="$T/no-such-etc" \
    bash "$H/bin/state-restore.sh" hub latest --apply --standby --identity "$H/age.key" --live "$H/live" </dev/null > "$H/run.out" 2>&1
}
fresh "$H"; srun
check C6 "$H" "$WD/api/standby/standby-box"
has "$H/run.out" 'standby report failed' && bad "C6: a 0-rc report is not failed ($(cat "$H/run.out"))" || ok
fresh "$H"; CURL_RC=22 srun
has "$H/run.out" 'standby report failed (fail-open)' && ok || bad "C6-fail: want the fail-open line (out: $(cat "$H/run.out"))"
[ -e "$H/hb" ] && ok || bad "C6: the standby heartbeat must still run"

# ── C7 fleet-status-push (status POST + standby GET) ─────────────────────────
H="$T/c7"; box "$H"; inst bin/fleet-status-push.sh "$H"; inst bin/fleet-conf.sh "$H"; inst bin/fleet-fly-block.sh "$H"
cp "$DIR/bin/alert_family.py" "$H/bin/"
mkdir -p "$H/builds"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$H" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf 'alpha-os Org/alpha https://a.example /api/board 2 box-alpha\n' > "$H/fleet.conf"
frun() {
  rm -f "$H/BEAT.json"
  env -u WATCHDOG_URL -u WATCHDOG_SECRET PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
    FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 bash "$H/bin/fleet-status-push.sh" </dev/null >"$H/run.out" 2>&1
}
fresh "$H"; frun
check C7 "$H" "$WD/api/status"
check C7-standby "$H" "$WD/api/standby"
[ "$(jq -r 'has("standby_error")' "$H/BEAT.json" 2>/dev/null)" = false ] && ok || bad "C7: a good [] standby list carries no standby_error"
fresh "$H"; CURL_RC=22 frun
SBE=$(jq -r '.standby_error // empty' "$H/BEAT.json" 2>/dev/null)
[ -n "$SBE" ] && [ "$SBE" != unconfigured ] && ok || bad "C7-fail: a failed standby GET must set standby_error (got '$SBE')"

# ── C8 mac-burn-push (Mac secret file order) ─────────────────────────────────
M="$T/c8"; inst bin/mac/mac-burn-push.sh "$M"
mkdir -p "$M/ledger/proj"
printf '{"timestamp":"%s.000Z","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%S')" > "$M/ledger/proj/s.jsonl"  # determinism: ok — the scan reads a 24h window off the real clock, so the fixture row is stamped now
printf '{"per_token": {"m": {"prompt": 0.01, "completion": 0.05, "cache_read": 0.001, "cache_write": 0.0125}}}\n' > "$M/prices.json"
mac() { # mac <home>
  env -u MACBURN_SECRET_FILE HOME="$1" PATH="$T/fakebin:$PATH" MACBURN_LEDGER_DIR="$M/ledger" MACBURN_PRICES="$M/prices.json" \
    WATCHDOG_URL="$WD/" bash "$M/bin/mac/mac-burn-push.sh" >/dev/null 2>&1
  RC=$?
}
MH="$M/home-both"; mkdir -p "$MH/.orgo"; printf '%s\n' "$WS" > "$MH/.orgo/.watchdog-secret"; printf '%s\n' "$HS" > "$MH/.orgo/.harness-secret"
fresh "$M"; mac "$MH"
[ "$RC" = 0 ] && ok || bad "C8: rc $RC (log: $(cat "$MH/.mk-macburn.log" 2>/dev/null))"
check C8 "$M" "$WD/api/mac-burn"
MH="$M/home-old"; mkdir -p "$MH/.orgo"; printf '%s\n' "$HS" > "$MH/.orgo/.harness-secret"
fresh "$M"; mac "$MH"
check C8-old "$M" "$WD/api/mac-burn" "$HS"
fresh "$M"; CURL_RC=22 mac "$MH"
[ "$RC" = 1 ] && has "$MH/.mk-macburn.log" 'push FAILED' && ok || bad "C8-fail: want rc 1 and a push FAILED line (rc $RC)"

# ── W1 the stamp step of publish-cromford.yml ────────────────────────────────
step_body() { # step_body <workflow> <step-name-prefix> — the run: | body, dedented
  python3 - "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
want = sys.argv[2].lower()
for i, l in enumerate(lines):
    m = re.match(r"^(\s*)- name:\s*(.*)$", l)
    if not (m and m.group(2).lower().startswith(want)):
        continue
    ind = len(m.group(1))
    for j in range(i + 1, len(lines)):
        s = lines[j]
        if re.match(r"^\s*- ", s) and len(s) - len(s.lstrip()) <= ind:
            break
        if re.match(r"^\s*run:\s*\|", s):
            rind = len(s) - len(s.lstrip())
            out = []
            for k in range(j + 1, len(lines)):
                b = lines[k]
                if b.strip() and len(b) - len(b.lstrip()) <= rind:
                    break
                out.append(b)
            dd = min((len(b) - len(b.lstrip()) for b in out if b.strip()), default=0)
            print("\n".join(b[dd:] for b in out))
            sys.exit(0)
    break
sys.exit(1)
PY
}
BODY=$(step_body "$DIR/.github/workflows/publish-cromford.yml" "stamp the outside dead-man") \
  || bad "W1: no 'Stamp the outside dead-man' step with a run: body"
W="$T/w1"; mkdir -p "$W/catalog"
printf '{"repo":"example-org/cromford","watchdog_url":"%s"}\n' "$WD" > "$W/catalog/fleet-watchdog.json"
BODY="${BODY//'${{ github.repository }}'/example-org/cromford}"
ST='stamp-fixture-9264'
fresh "$W"
(cd "$W" && STAMP_SECRET="$ST" PATH="$T/fakebin:$PATH" bash --noprofile --norc -eo pipefail -c "$BODY") > "$W/run.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "W1: rc $RC ($(cat "$W/run.out"))"
check W1 "$W" "$WD/api/stamp/share-mirror" "$ST"
fresh "$W"
(cd "$W" && CURL_RC=22 STAMP_SECRET="$ST" PATH="$T/fakebin:$PATH" bash --noprofile --norc -eo pipefail -c "$BODY") > "$W/run.out" 2>&1; RC=$?
[ "$RC" = 0 ] && has "$W/run.out" 'watchdog stamp failed (non-fatal)' && ok || bad "W1-fail: a failed stamp stays non-fatal (rc $RC, $(cat "$W/run.out"))"

# ── S1 static: no `?s=<secret>` left in bin/ or the workflows ────────────────
HITS=$(cd "$DIR" && grep -nE '\?s=\$' bin/*.sh bin/*/*.sh .github/workflows/*.yml 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -z "$HITS" ] && ok || bad "S1: a caller still puts a secret in ?s=: $HITS"

echo "watchdog-auth-callers.bh-9264: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
