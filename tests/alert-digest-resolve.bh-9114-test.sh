#!/bin/bash
# tests/alert-digest-resolve.bh-9114-test.sh — a warn digest closes its own
# console row right after the console took it (BH-9114).
#
# bin/alert-digest.sh --warn-batch beats ONE fleet_alert per batch, akey
# warnbatch:<box>:<ts>:<pid>. The console opened a row for it and kept it open
# for 48h, although every warn in it is a row of its own: each warn counted
# twice (about 157 open digest rows on 2026-11-05).
#   D1 the console took the beat: one GET /open, then one POST
#      {"ids":[<that row>],"reason":"digest"}
#   D2 the beat answered HTTP 500: no GET, no POST (never closed unsent)
#   D3 ALERT_DIGEST_RESOLVE=0: no GET
#   D4 a near-miss akey (one digit more, one digit less): not resolved
#   D5 no row with the akey: log "not-found", the lane exits 0
#   D6 the beat itself is unchanged: kind, project, triaged, akey shape, line
# The REAL alert-digest.sh, beat.sh and lib run; curl is a PATH stub that keeps
# the console's side, so 0 network calls.
# Run from anywhere: tests/alert-digest-resolve.bh-9114-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

[ -r "$DIR/bin/lib/console-alert-resolve.sh" ] || { echo "FAIL: bin/lib/console-alert-resolve.sh is missing"; exit 1; }
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub"
for s in bin/alert-digest.sh bin/beat.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: scratch_install_closure $s"; exit 1; }
done
cp "$DIR/bin/alert_family.py" "$H/bin/" 2>/dev/null
chmod +x "$H/bin/"*.sh 2>/dev/null
export HARNESS="$H" PATH="$T/stub:$PATH" LANE_GATE_DISABLE=1
# Quarantine off puts beat.sh on its direct path: one send == one POST /api/beat.
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=fixture-secret\n' > "$H/env/global.env"
printf 'testbox\n' > "$H/state/box-id"
# The console: /api/beat records the payload and answers STUB_BEAT_CODE;
# /api/alerts/open lists rows built from the last beaten akey per STUB_OPEN;
# /api/alerts/resolve records the body.
cat > "$T/stub/curl.py" <<'PY'
import json, os, sys
T = os.environ["STUB_T"]; args = sys.argv[1:]
url = next((a for a in args if a.startswith("http")), "")
def opt(n): return args[args.index(n) + 1] if n in args else None
def log(name, s):
    with open(os.path.join(T, name), "a") as f: f.write(s + "\n")
def emit(body, code=200):
    o = opt("-o")
    if o: open(o, "w").write(body)
    else: sys.stdout.write(body)
    if opt("-w"): sys.stdout.write(str(code))
if url.endswith("/api/beat"):
    log("beats.jsonl", opt("-d"))
    emit("{}", int(os.environ.get("STUB_BEAT_CODE", "200")))
elif url.endswith("/api/alerts/open"):
    log("gets.txt", url)
    ak = json.loads(open(os.path.join(T, "beats.jsonl")).read().splitlines()[-1])["akey"]
    mode = os.environ.get("STUB_OPEN", "match")
    rows = [{"id": 7001, "akey": "alert:some-other-row", "line": "x"}]
    if mode == "match": rows.append({"id": 7002, "akey": ak, "line": "digest"})
    if mode == "near": rows += [{"id": 7003, "akey": ak + "3", "line": "digest"},
                                {"id": 7004, "akey": ak[:-1], "line": "digest"},
                                {"id": 7005, "akey": "", "line": ak}]
    emit(json.dumps({"alerts": rows}))
elif url.endswith("/api/alerts/resolve"):
    log("posts.jsonl", opt("-d"))
    emit('{"resolved":1}')
else:
    emit("{}")
PY
printf '#!/bin/bash\nSTUB_T="%s" exec python3 -I "%s/stub/curl.py" "$@"\n' "$T" "$T" > "$T/stub/curl"
chmod +x "$T/stub/curl"

SPOOL="$H/state/alert-warn-batch.jsonl"
ASLOG="$H/logs/alerts-state.log"
spool() { printf '%s\t%s\n' 1000 "$(jq -nc --arg id "$1" --arg l "$2" '{alertid:$id,line:$l}')" >> "$SPOOL"; }
cnt() { local n; n=$(grep -c . "$T/$1" 2>/dev/null); printf '%s' "${n:-0}"; }
flush() {
  rm -f "$T/beats.jsonl" "$T/gets.txt" "$T/posts.jsonl" "$SPOOL"; : > "$ASLOG"
  spool w-a "a quiet warn A"
  ( for kv in "$@"; do export "${kv?}"; done; "$H/bin/alert-digest.sh" --warn-batch >/dev/null 2>&1 ); RC=$?
}

# ── D1 + D6 ─────────────────────────────────────────────────────────────────
flush
B=$(head -1 "$T/beats.jsonl" 2>/dev/null)
AK=$(jq -r '.akey' <<<"$B" 2>/dev/null)
[ "$RC" = 0 ] && [ "$(cnt beats.jsonl)" = 1 ] && [ "$(cnt gets.txt)" = 1 ] && [ "$(cnt posts.jsonl)" = 1 ] \
  && [ "$(jq -c '.ids' "$T/posts.jsonl")" = '[7002]' ] && [ "$(jq -r '.reason' "$T/posts.jsonl")" = digest ] && ok \
  || bad "D1 a beat the console took must close its row: rc=$RC beats=$(cnt beats.jsonl) gets=$(cnt gets.txt) posts=$(cat "$T/posts.jsonl" 2>/dev/null)"
grep -q 'warn-batch digest row: resolved' "$ASLOG" && ok || bad "D1 the log must say resolved: $(cat "$ASLOG")"
[ "$(jq -r '.kind' <<<"$B")" = fleet_alert ] && [ "$(jq -r '.project' <<<"$B")" = fleet ] \
  && [ "$(jq -r '.triaged' <<<"$B")" = true ] && [[ "$AK" =~ ^warnbatch:testbox:[0-9]{14}:[0-9]+$ ]] \
  && [ "$(jq -r '.line' <<<"$B")" = "Alerts (warn) on testbox, last batch: 1 condition(s), 1 event(s). None of these page on their own; this is the batched cadence.
  - a quiet warn A" ] && ok || bad "D6 the digest beat must be unchanged: $B"

# ── D2 the console did not take the beat ────────────────────────────────────
flush STUB_BEAT_CODE=500
[ "$(cnt beats.jsonl)" = 1 ] && [ "$(cnt gets.txt)" = 0 ] && [ "$(cnt posts.jsonl)" = 0 ] && ok \
  || bad "D2 a beat answered 500 must not GET or POST: gets=$(cnt gets.txt) posts=$(cnt posts.jsonl)"

# ── D3 the knob is off ──────────────────────────────────────────────────────
flush ALERT_DIGEST_RESOLVE=0
[ "$(cnt beats.jsonl)" = 1 ] && [ "$(cnt gets.txt)" = 0 ] && [ "$(cnt posts.jsonl)" = 0 ] && ok \
  || bad "D3 ALERT_DIGEST_RESOLVE=0 must not GET: gets=$(cnt gets.txt)"

# ── D4 near misses are not this row ─────────────────────────────────────────
flush STUB_OPEN=near
[ "$(cnt gets.txt)" = 1 ] && [ "$(cnt posts.jsonl)" = 0 ] && grep -q 'warn-batch digest row: not-found' "$ASLOG" && ok \
  || bad "D4 a prefix-equal akey, a shorter one or the akey in the line must not be resolved: $(cat "$T/posts.jsonl" 2>/dev/null)"

# ── D5 no row: not-found, rc 0 ──────────────────────────────────────────────
flush STUB_OPEN=none
[ "$RC" = 0 ] && [ "$(cnt posts.jsonl)" = 0 ] && grep -q 'warn-batch digest row: not-found' "$ASLOG" && ok \
  || bad "D5 no open row must log not-found and exit 0: rc=$RC :: $(cat "$ASLOG")"

echo "alert-digest-resolve.bh-9114: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
