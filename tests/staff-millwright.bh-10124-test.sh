#!/bin/bash
# tests/staff-millwright.bh-10124-test.sh — BH-10124 (C3 of #9423): Millwright's
# metric failed_bakes_and_broken_boxes, its collector and its bake-rerun lever.
#
#   P1-P3  the REAL bin/fleet-propagate.sh writes .pool_fail: a failed bake sets
#          {sha, at, reason}, an ok bake removes it, a debounced pool or a pool
#          not in the run keeps its entry, and .pools keeps its shape
#   P4     end to end: a real failed bake -> the REAL lever writes the mark ->
#          a real propagate drain bakes that pool and clears the mark and the
#          .pool_fail entry
#   B1-B6  mw_bakes (bin/lib/millwright-read.sh): listed, fixed, queued, pool
#          gone, bad names, an unreadable record
#   X1-X6  mw_probe_cmd and mw_boxes: resolv shapes, the read-only probe and an
#          unreachable box, /tmp use% and its knob, the stale-bin rule, an
#          unreadable GET /api/boxes
#   C1-C5  bin/staff/millwright-collect.sh, and bin/staff.sh tick millwright
#          (the production entry point) at level observe and file
#   L1-L9  bin/staff/millwright-lever.sh: the outcome row at level act, no row
#          below act, taken ids, queued bakes, the day cap, an unreadable
#          metric, the kill switches, a bake fixed meanwhile, a failed sample
#   R1     the soul parses with the four new REPORT lines
#   Z1     0 network calls: every request is a stubbed route, no real ssh
#
# Every vendor is a stub: the jobs client through MW_FIXTURE / STAFF_FIXTURE
# (a file the lanes source in sandbox mode), ssh through MW_SSH, the bake
# through a fake bin/fly-image-build.sh. A guard ssh and curl on PATH fail the
# suite if anything reaches a real one.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-millwright.bh-10124-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-millwright: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "staff-millwright: git is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

LIB_REL=bin/lib/millwright-read.sh
COL_REL=bin/staff/millwright-collect.sh
LEV_REL=bin/staff/millwright-lever.sh
for f in "$LIB_REL" "$COL_REL" "$LEV_REL" catalog/lanes.d/_lib.staff-millwright.json \
         catalog/lanes.d/staff-millwright-lever.json cron/lanes/787-staff-millwright-lever.cron \
         worker/jobs/schema.d/202611252036-bh-10124-millwright-lever.sql; do
  [ -s "$DIR/$f" ] && ok || bad "missing $f"
done

# 2026-11-25T12:00:00Z, pinned (D60).
NOW=1795608000
SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222

# Guards: a real ssh or curl fails the suite (Z1).
mkdir -p "$T/guard"
for b in ssh curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/real-calls.log"\nexit 97\n' "$b" "$T" > "$T/guard/$b"
  chmod +x "$T/guard/$b"
done
GPATH="$T/guard:$PATH"

# ═════ the fixture every lane sources (MW_FIXTURE / STAFF_FIXTURE) ═══════════
FXT="$T/fx"; mkdir -p "$FXT"
cat > "$T/fixture.sh" <<'SH'
_fx_log() { printf '%s\n' "$*" >> "$FXT/req.log"; }
_jobs_req() {
  _fx_log "$1 $2"
  case "$1 $2" in
    "GET /api/boxes")
      [ -f "$FXT/boxes.fail" ] && return 1
      cat "$FXT/boxes.json" 2>/dev/null || printf '{"boxes":[]}'; return 0 ;;
    "GET /api/staff/agent?name=millwright")
      if [ -f "$FXT/roster.json" ]; then cat "$FXT/roster.json"
      else printf '{"agent":{"name":"millwright","autonomy":"augmentation","cap":"augmentation","status":"active","soul":"prompts/staff/millwright-soul.md"}}'; fi
      return 0 ;;
    "GET /api/staff/levers/scorecard?agent=millwright&days=1")
      if [ -f "$FXT/scorecard.touch" ]; then touch -d "@$(( $(date +%s) + 600 ))" "$(cat "$FXT/scorecard.touch")"; fi
      [ -f "$FXT/scorecard.fail" ] && return 1
      cat "$FXT/scorecard.json" 2>/dev/null || printf '{"agent":"millwright","days":1,"actions":0}'; return 0 ;;
  esac
  _fx_log "UNKNOWN $1 $2" ; printf '%s %s\n' "$1" "$2" >> "$FXT.unknown.log"
  return 1
}
_jobs_req_file() {
  _fx_log "$1 $2 $(jq -c . "$3" 2>/dev/null)"
  case "$1 $2" in
    "POST /api/staff/levers/metric")
      [ -f "$FXT/metric.fail" ] && { JOBS_HTTP=500; return 1; }
      JOBS_HTTP=200; printf '{"ok":true}'; return 0 ;;
    "POST /api/staff/levers/actions")
      JOBS_HTTP=$(cat "$FXT/action.code" 2>/dev/null || echo 200)
      if [ -f "$FXT/action.body" ]; then cat "$FXT/action.body"
      else printf '{"ok":true,"action":{"action_key":"%s"}}' "$(jq -r .key "$3" | sha256sum | cut -c1-64)"; fi
      case "$JOBS_HTTP" in 2??) return 0 ;; esac; return 1 ;;
    "POST /api/staff/findings/claim")
      printf '{"claimed":true,"fingerprint":"%s","finding":{"agent":"millwright","status":"claimed"}}' \
        "$(jq -cS .item "$3" | sha256sum | cut -c1-64)"; return 0 ;;
    "POST /api/staff/findings/record"|"POST /api/staff/ticks") printf '{"ok":true}'; return 0 ;;
    "POST /api/staff/chat/take") printf '{"notes":[]}'; return 0 ;;
  esac
  printf '%s %s\n' "$1" "$2" >> "$FXT.unknown.log"
  return 1
}
setting_get() {
  _fx_log "SETTING $1"
  [ -f "$FXT/settings/$1" ] || return 1
  cat "$FXT/settings/$1"
}
flag_active() { [ -e "${HARNESS:-$H}/flags/$1" ]; }
registry_json_path() { [ -f "$FXT/registry.fail" ] && return 1; printf '%s\n' "$FXT/registry.json"; }
gh_rest() { printf 'gh_rest %s\n' "$*" >> "$FXT/gh.log"; return 75; }
gh_rest_issue_list() { printf 'list %s\n' "$*" >> "$FXT/gh.log"; return 75; }
lane_role_model() { printf 'stub-model\n'; }
SH

# The fake ssh: root@<ip> <cmd>. It answers $FXT/ssh/<ip>: SLEEP = hang past
# the timeout, RC<n> = exit n, else the file is the box's answer.
cat > "$T/fakessh" <<'SH'
#!/bin/bash
ip=""; cmd=""
for a in "$@"; do case "$a" in root@*) ip=${a#root@} ;; *) cmd=$a ;; esac; done
printf '%s\n' "$ip" >> "$FXT/ssh.log"
printf '%s\n' "$cmd" > "$FXT/ssh.cmd"
f="$FXT/ssh/$ip"
[ -f "$f" ] || exit 255
case "$(head -1 "$f")" in
  SLEEP) exec tail -f /dev/null ;;
  RC*) exit "$(head -1 "$f" | cut -c3-)" ;;
esac
cat "$f"
SH
chmod +x "$T/fakessh"

fx_reset() {
  scratch_rm "$FXT" || exit 1
  mkdir -p "$FXT/settings" "$FXT/ssh"
  : > "$FXT/req.log"
  printf '{"boxes":[]}\n' > "$FXT/registry.json"
  printf '{"boxes":[]}\n' > "$FXT/boxes.json"
}
fx_reset

# ═════ the scratch harness for the lib, collector and lever ══════════════════
LH="$T/lh"
mkdir -p "$LH/logs" "$LH/state/fly" "$LH/flags" "$LH/locks"
for L in "$LIB_REL" "$COL_REL" "$LEV_REL" bin/jobs-client.sh bin/lib/staff-contract.sh bin/lib/lane-gate.sh; do
  [ -r "$DIR/$L" ] || continue
  scratch_install_closure "$L" "$LH" >/dev/null || bad "scratch_install_closure $L failed"
done
chmod +x "$LH/bin/staff/"*.sh 2>/dev/null
export HARNESS_TEST_SANDBOX=1 FXT LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= JOBS_ALERT=0
unset STAFF_ENABLED MW_TMP_FULL_PCT MW_SSH_TIMEOUT_S MW_LAG_FRESH_MIN MW_BOXES_MAX MWL_LIB_ONLY

h_reset() { # h_reset <harness> — empty state, logs and flags
  scratch_rm "$1/state" || exit 1; scratch_rm "$1/logs" || exit 1; scratch_rm "$1/flags" || exit 1
  mkdir -p "$1/state/fly" "$1/logs" "$1/flags"
}
# seed_fail <harness> <project> <sha> <at> [reason] — a .pool_fail entry plus a live pool flag.
seed_fail() {
  local f="$1/state/fleet-propagate.json"
  [ -s "$f" ] || echo '{"last_sha":"x","pools":{}}' > "$f"
  jq --arg p "$2" --arg s "$3" --argjson a "$4" --arg r "${5:-fail}" '.pool_fail[$p] = {sha:$s, at:$a, reason:$r}' "$f" > "$f.t" && mv "$f.t" "$f"
  printf 'builder-%s\n' "$2" > "$1/flags/fly-pool-app-$2"
}
# lib <cmd...> — run in a subshell with the read lib and the fixture loaded.
lib() {
  ( export HARNESS="$LH" MW_NOW="$NOW" MW_SSH="$T/fakessh" PATH="$GPATH"
    . "$LH/$LIB_REL" || exit 9
    . "$T/fixture.sh"
    "$@" )
}

# ═════ B: mw_bakes ═══════════════════════════════════════════════════════════
# B1 failed, .image older: listed, queued 0.
h_reset "$LH"; seed_fail "$LH" b1-pool "$SHA_A" $((NOW - 100)) timeout
touch -d "@$((NOW - 5000))" "$LH/state/fly/b1-pool.image"
OUT=$(lib mw_bakes "$LH"); RC=$?
eq "B1 rc" "$RC" 0
eq "B1 line" "$OUT" "b1-pool	$SHA_A	$((NOW - 100))	timeout	0"
# B1b .image missing: listed too.
rm -f "$LH/state/fly/b1-pool.image"
eq "B1b no .image" "$(lib mw_bakes "$LH" | cut -f1)" b1-pool
# B2 .image newer than at: fixed, not listed.
touch -d "@$((NOW - 50))" "$LH/state/fly/b1-pool.image"
eq "B2 fixed" "$(lib mw_bakes "$LH")" ""
# B3 a mark present: listed, queued 1.
h_reset "$LH"; seed_fail "$LH" b3-pool "$SHA_A" $((NOW - 100))
echo "$SHA_A" > "$LH/state/fly/b3-pool.image-dirty"
eq "B3 queued" "$(lib mw_bakes "$LH" | cut -f5)" 1
# B4 pool flag missing or empty: not listed.
h_reset "$LH"; seed_fail "$LH" b4-pool "$SHA_A" $((NOW - 100)); rm -f "$LH/flags/fly-pool-app-b4-pool"
eq "B4 flag missing" "$(lib mw_bakes "$LH")" ""
: > "$LH/flags/fly-pool-app-b4-pool"
eq "B4 flag empty" "$(lib mw_bakes "$LH")" ""
# B5 a bad project name and a short sha: skipped with a warn line each; a good one stays.
h_reset "$LH"; seed_fail "$LH" b5-good "$SHA_A" $((NOW - 100))
jq --arg s "$SHA_A" '.pool_fail["../x"] = {sha:$s, at:1, reason:"r"} | .pool_fail["b5-short"] = {sha:"abc123", at:1, reason:"r"}' \
  "$LH/state/fleet-propagate.json" > "$T/r.json" && mv "$T/r.json" "$LH/state/fleet-propagate.json"
printf 'x\n' > "$LH/flags/fly-pool-app-b5-short"
eq "B5 only the good one" "$(lib mw_bakes "$LH" | cut -f1)" b5-good
eq "B5 warn lines" "$(grep -c 'agent=millwright warn: fleet-propagate .pool_fail' "$LH/logs/staff.log" 2>/dev/null)" 2
# B6 the record is not JSON: rc 3. No record, or no key: rc 0 and nothing.
h_reset "$LH"; echo 'not json {' > "$LH/state/fleet-propagate.json"
lib mw_bakes "$LH" > "$T/o"; eq "B6 not JSON rc" "$?" 3
echo '[1,2]' > "$LH/state/fleet-propagate.json"
lib mw_bakes "$LH" > "$T/o"; eq "B6 not an object rc" "$?" 3
rm -f "$LH/state/fleet-propagate.json"
OUT=$(lib mw_bakes "$LH"); eq "B6 no record rc" "$?" 0; eq "B6 no record lines" "$OUT" ""
echo '{"last_sha":"x","pools":{"p":{"status":"fail"}}}' > "$LH/state/fleet-propagate.json"
OUT=$(lib mw_bakes "$LH"); eq "B6 no key rc" "$?" 0; eq "B6 no key lines" "$OUT" ""

# ═════ X: the probe and mw_boxes ═════════════════════════════════════════════
# X1 resolv shapes, through the real probe command run locally.
probe() { bash -c "$(lib mw_probe_cmd "$1" "$T")" 2>/dev/null; }
mkdir -p "$T/rs"
printf 'nameserver 1.1.1.1\n' > "$T/rs/ok-plain"
printf '   nameserver 9.9.9.9\nsearch x\n' > "$T/rs/ok-spaces"
ln -sf "$T/rs/ok-plain" "$T/rs/ok-link"
: > "$T/rs/bad-empty"
printf 'search example.test\noptions ndots:1\n' > "$T/rs/bad-search"
printf '# nameserver 1.1.1.1\n' > "$T/rs/bad-comment"
printf 'nameserver\n' > "$T/rs/bad-noaddr"
printf 'nameserver   # no address\n' > "$T/rs/bad-hashaddr"
ln -sf "$T/rs/gone-target" "$T/rs/bad-dangling"
for f in ok-plain ok-spaces ok-link; do
  has "X1 $f" "$(probe "$T/rs/$f")" "resolv=ok"
done
for f in bad-empty bad-search bad-comment bad-noaddr bad-hashaddr bad-dangling bad-missing; do
  has "X1 $f" "$(probe "$T/rs/$f")" "resolv=broken"
done
[[ $(probe "$T/rs/ok-plain") =~ ^mw\ resolv=ok\ tmp=[0-9]+$ ]] && ok || bad "X1 the probe line shape: $(probe "$T/rs/ok-plain")"
# X2 the probe is read-only, and a box that hangs or fails is unreachable, not a fault.
PC=$(lib mw_probe_cmd)
for w in 'rm ' '>' 'mv ' 'tee' 'cp ' 'dd '; do
  case "$PC" in *"$w"*) bad "X2 the probe holds '$w': $PC" ;; *) ok ;; esac
done
fx_reset
printf '{"boxes":[{"box":"x2-hang","box_id":"x2-hang","tailnet_ip":"192.0.2.21"},{"box":"x2-gone","box_id":"x2-gone","tailnet_ip":"192.0.2.22"},{"box":"x2-mute","box_id":"x2-mute","tailnet_ip":"192.0.2.23"}]}\n' > "$FXT/registry.json"
echo SLEEP > "$FXT/ssh/192.0.2.21"; echo RC255 > "$FXT/ssh/192.0.2.22"; echo "hello" > "$FXT/ssh/192.0.2.23"
T0=$(date +%s)
OUT=$(MW_SSH_TIMEOUT_S=2 MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x2"); RC=$?
EL=$(( $(date +%s) - T0 ))
eq "X2 rc" "$RC" 0
eq "X2 no fault" "$OUT" ""
has "X2 counts" "$(cat "$T/x2/counts")" "unreachable=3 probed=4 boxes_read=ok registry=ok"
[ "$EL" -lt 10 ] && ok || bad "X2 the hung box held the read ${EL}s (timeout 2)"
eq "X2 the command sent is the probe" "$(cat "$FXT/ssh.cmd")" "$PC"
# X3 /tmp use%: 90 and 100 are full, 89 is not, '-' is unknown. Plus a broken resolv on a box.
fx_reset
printf '{"boxes":[
  {"box":"x3-a","box_id":"x3-a","tailnet_ip":"192.0.2.31"},{"box":"x3-b","box_id":"x3-b","tailnet_ip":"192.0.2.32"},
  {"box":"x3-c","box_id":"x3-c","tailnet_ip":"192.0.2.33"},{"box":"x3-d","box_id":"x3-d","tailnet_ip":"192.0.2.34"},
  {"box":"x3-hub","box_id":"hub","tailnet_ip":"192.0.2.35"},{"box":"x3-old","box_id":"x3-old","tailnet_ip":"192.0.2.36","role":"retired"},
  {"box":"x3-noip","box_id":"x3-noip"}]}\n' > "$FXT/registry.json"
echo "mw resolv=ok tmp=90" > "$FXT/ssh/192.0.2.31"; echo "mw resolv=ok tmp=100" > "$FXT/ssh/192.0.2.32"
echo "mw resolv=ok tmp=89" > "$FXT/ssh/192.0.2.33"; echo "mw resolv=broken tmp=-" > "$FXT/ssh/192.0.2.34"
echo "mw resolv=broken tmp=100" > "$FXT/ssh/192.0.2.35"; echo "mw resolv=broken tmp=100" > "$FXT/ssh/192.0.2.36"
OUT=$(MW_RESOLV="$T/rs/bad-comment" lib mw_boxes "$LH" "$T/x3"); RC=$?
eq "X3 rc" "$RC" 0
eq "X3 faults" "$OUT" "hub	resolv-broken	/etc/resolv.conf has no usable nameserver
x3-a	tmp-full	90%
x3-b	tmp-full	100%
x3-d	resolv-broken	/etc/resolv.conf has no usable nameserver"
eq "X3 probed IPs (no hub, no retired, no IP-less box)" "$(sort "$FXT/ssh.log" | paste -sd' ')" "192.0.2.31 192.0.2.32 192.0.2.33 192.0.2.34"
# X4 the knob: 95 makes 90 not full; 49 and 101 fall back to 90 with one warn line each.
OUT=$(MW_TMP_FULL_PCT=95 MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x4" | cut -f1,2 | paste -sd' ')
eq "X4 knob 95" "$OUT" "x3-b	tmp-full x3-d	resolv-broken"
for k in 49 101 abc; do
  : > "$LH/logs/staff.log"
  OUT=$(MW_TMP_FULL_PCT=$k MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x4" | awk -F'\t' '$2 == "tmp-full"' | cut -f1 | paste -sd' ')
  eq "X4 knob $k = default 90" "$OUT" "x3-a x3-b"
  eq "X4 knob $k warn" "$(grep -c "warn: MW_TMP_FULL_PCT=$k is outside 50..100; using the default 90" "$LH/logs/staff.log")" 1
done
# X5 stale bin: lag 31 > 30 fresh = fault; 30 not; a 61-min-old reading not; null not; threshold 120 not.
fx_reset
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
jq -n --arg f "$(iso $((NOW - 300)))" --arg o "$(iso $((NOW - 3660)))" --arg ms "$(date -u -d "@$((NOW - 120))" +%Y-%m-%dT%H:%M:%S.123Z)" '{boxes: [
  {box:"x5-stale", harness_lag_min:31, lag_checked_at:$f, harness_commit:"abcdef0123456789"},
  {box:"x5-ms", harness_lag_min:45, lag_checked_at:$ms, harness_commit:"0123456789abcdef"},
  {box:"x5-equal", harness_lag_min:30, lag_checked_at:$f, harness_commit:"a"},
  {box:"x5-old", harness_lag_min:31, lag_checked_at:$o, harness_commit:"b"},
  {box:"x5-null", harness_lag_min:null, lag_checked_at:$f},
  {box:"x5-nocheck", harness_lag_min:99, lag_checked_at:null}]}' > "$FXT/boxes.json"
OUT=$(MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x5"); RC=$?
eq "X5 rc" "$RC" 0
eq "X5 faults" "$OUT" "x5-ms	stale-bin	lag=45 max=30 sha=0123456789ab
x5-stale	stale-bin	lag=31 max=30 sha=abcdef012345"
echo 120 > "$FXT/settings/harness_version.max_lag_min"
eq "X5 threshold row 120" "$(MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x5")" ""
echo 40 > "$FXT/settings/harness_version.max_lag_min"
eq "X5 threshold row 40" "$(MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x5" | cut -f1)" x5-ms
eq "X5 MW_LAG_FRESH_MIN=10 drops none (both readings are fresh)" "$(MW_LAG_FRESH_MIN=10 MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x5" | cut -f1)" x5-ms
# X6 GET /api/boxes fails: rc 3, the probe faults still print. A failed registry: rc 3 too.
fx_reset; touch "$FXT/boxes.fail"
printf '{"boxes":[{"box":"x6-a","box_id":"x6-a","tailnet_ip":"192.0.2.61"}]}\n' > "$FXT/registry.json"
echo "mw resolv=broken tmp=10" > "$FXT/ssh/192.0.2.61"
OUT=$(MW_RESOLV="$T/rs/ok-plain" lib mw_boxes "$LH" "$T/x6"); RC=$?
eq "X6 boxes unreadable rc" "$RC" 3
eq "X6 the probe fault still prints" "$(cut -f1,2 <<<"$OUT")" "x6-a	resolv-broken"
has "X6 counts" "$(cat "$T/x6/counts")" "boxes_read=failed registry=ok"
echo '{"error":"x"}' > "$FXT/boxes.json"; rm -f "$FXT/boxes.fail"
lib mw_boxes "$LH" "$T/x6" >/dev/null; eq "X6 a body with no .boxes array rc" "$?" 3
fx_reset; touch "$FXT/registry.fail"
OUT=$(MW_RESOLV="$T/rs/bad-empty" lib mw_boxes "$LH" "$T/x6"); RC=$?
eq "X6 registry unreadable rc" "$RC" 3
eq "X6 registry unreadable: the hub fault still prints" "$(cut -f1,2 <<<"$OUT")" "hub	resolv-broken"
# mw_metric: value = bakes + distinct fault boxes; either half unreadable = rc 3, nothing printed.
fx_reset; h_reset "$LH"
seed_fail "$LH" m-one "$SHA_A" $((NOW - 100)); seed_fail "$LH" m-two "$SHA_B" $((NOW - 100))
echo "$SHA_B" > "$LH/state/fly/m-two.image-dirty"
printf '{"boxes":[{"box":"m-box","box_id":"m-box","tailnet_ip":"192.0.2.71"},{"box":"m-down","box_id":"m-down","tailnet_ip":"192.0.2.72"}]}\n' > "$FXT/registry.json"
echo "mw resolv=broken tmp=95" > "$FXT/ssh/192.0.2.71"
jq -n --arg f "$(iso $((NOW - 60)))" '{boxes:[{box:"m-box", harness_lag_min:50, lag_checked_at:$f, harness_commit:"c0ffee"}]}' > "$FXT/boxes.json"
OUT=$(MW_RESOLV="$T/rs/ok-plain" lib mw_metric "$LH" "$T/m"); RC=$?
eq "metric rc" "$RC" 0
eq "metric object" "$(jq -c . <<<"$OUT")" '{"value":3,"bakes":2,"boxes":1,"resolv":1,"tmp":1,"stale":1,"unreachable":1}'
touch "$FXT/boxes.fail"
OUT=$(MW_RESOLV="$T/rs/ok-plain" lib mw_metric "$LH" "$T/m"); RC=$?
eq "metric boxes unreadable rc" "$RC" 3; eq "metric boxes unreadable prints nothing" "$OUT" ""
rm -f "$FXT/boxes.fail"; echo 'x{' > "$LH/state/fleet-propagate.json"
OUT=$(MW_RESOLV="$T/rs/ok-plain" lib mw_metric "$LH" "$T/m"); RC=$?
eq "metric record unreadable rc" "$RC" 3; eq "metric record unreadable prints nothing" "$OUT" ""

# ═════ C: the collector ══════════════════════════════════════════════════════
col() {
  env HARNESS="$LH" MW_FIXTURE="$T/fixture.sh" MW_NOW="$NOW" MW_SSH="$T/fakessh" MW_RESOLV="$T/rs/ok-plain" \
    CONSOLE_URL=https://console.example.test/ PATH="$GPATH" "$@" bash "$LH/$COL_REL" > "$T/col.out" 2> "$T/col.err"
  RC=$?
}
# C1 one fault of each kind: four sorted lines.
fx_reset; h_reset "$LH"
seed_fail "$LH" c1-pool "$SHA_A" $((NOW - 100)) build-error
printf '{"boxes":[{"box":"c1-box","box_id":"c1-box","tailnet_ip":"192.0.2.81"},{"box":"c1-tmp","box_id":"c1-tmp","tailnet_ip":"192.0.2.82"}]}\n' > "$FXT/registry.json"
echo "mw resolv=broken tmp=10" > "$FXT/ssh/192.0.2.81"; echo "mw resolv=ok tmp=97" > "$FXT/ssh/192.0.2.82"
jq -n --arg f "$(iso $((NOW - 60)))" '{boxes:[{box:"c1-lag", harness_lag_min:75, lag_checked_at:$f, harness_commit:"feedfacecafe0001"}]}' > "$FXT/boxes.json"
col
eq "C1 rc" "$RC" 0
eq "C1 lines" "$(lines "$T/col.out")" 4
eq "C1 classes in order" "$(jq -r .class "$T/col.out" | paste -sd' ')" "bake-failed resolv-broken stale-bin tmp-full"
eq "C1 bake item" "$(jq -c 'select(.class == "bake-failed") | .item' "$T/col.out")" '{"check":"bake-failed","project":"c1-pool","sha":"111111111111"}'
eq "C1 bake title" "$(jq -r 'select(.class == "bake-failed") | .title' "$T/col.out")" \
  "Pool image bake for c1-pool failed at 11111111 (build-error) and no ok bake since; fix: bin/fly-image-build.sh c1-pool"
eq "C1 resolv item" "$(jq -c 'select(.class == "resolv-broken") | .item' "$T/col.out")" '{"check":"resolv-broken","box":"c1-box"}'
has "C1 resolv title" "$(jq -r 'select(.class == "resolv-broken") | .title' "$T/col.out")" "bin/dns-guard.sh on c1-box"
eq "C1 tmp item" "$(jq -c 'select(.class == "tmp-full") | .item' "$T/col.out")" '{"check":"tmp-full","box":"c1-tmp"}'
has "C1 tmp title" "$(jq -r 'select(.class == "tmp-full") | .title' "$T/col.out")" "/tmp is 97% full"
eq "C1 stale item" "$(jq -c 'select(.class == "stale-bin") | .item' "$T/col.out")" '{"check":"stale-bin","box":"c1-lag","sha":"feedfacecafe"}'
has "C1 stale title" "$(jq -r 'select(.class == "stale-bin") | .title' "$T/col.out")" "lags main by 75 min, over harness_version.max_lag_min 30"
jq -e -s 'all(.[]; .source == {kind:"millwright", url:"https://console.example.test/machines", labels:[]} and .observedAt == "2026-11-25T12:00:00Z")' \
  "$T/col.out" >/dev/null && ok || bad "C1 source/observedAt: $(cat "$T/col.out")"
# C3 the same state twice prints the same bytes.
cp "$T/col.out" "$T/col.first"; col
cmp -s "$T/col.out" "$T/col.first" && ok || bad "C3 the same state printed different bytes"
# C2 a queued bake prints no line.
echo "$SHA_A" > "$LH/state/fly/c1-pool.image-dirty"; col
eq "C2 a queued bake is not printed" "$(jq -r .class "$T/col.out" | paste -sd' ')" "resolv-broken stale-bin tmp-full"
rm -f "$LH/state/fly/c1-pool.image-dirty"
# C4 a half unreadable: a warn line, the rest prints, rc 0. The read lib missing: rc 1, nothing.
touch "$FXT/boxes.fail"; : > "$LH/logs/staff.log"; col
eq "C4 boxes unreadable rc" "$RC" 0
eq "C4 boxes unreadable: the rest prints" "$(jq -r .class "$T/col.out" | paste -sd' ')" "bake-failed resolv-broken tmp-full"
eq "C4 warn line" "$(grep -c 'agent=millwright warn: box read incomplete' "$LH/logs/staff.log")" 1
rm -f "$FXT/boxes.fail"
cp "$LH/state/fleet-propagate.json" "$T/rec.keep"; echo 'nope' > "$LH/state/fleet-propagate.json"; col
eq "C4 record unreadable rc" "$RC" 0
eq "C4 record unreadable: the boxes print" "$(jq -r .class "$T/col.out" | paste -sd' ')" "resolv-broken stale-bin tmp-full"
cp "$T/rec.keep" "$LH/state/fleet-propagate.json"
mv "$LH/$LIB_REL" "$T/lib.keep"; col
eq "C4 no read lib rc" "$RC" 1; eq "C4 no read lib prints nothing" "$(lines "$T/col.out")" 0
mv "$T/lib.keep" "$LH/$LIB_REL"

# C5 the production entry point: bin/staff.sh tick millwright.
S="$T/s"
mkdir -p "$S/prompts/staff" "$S/catalog/prompts"
scratch_install_closure bin/staff.sh "$S" >/dev/null || bad "scratch_install_closure bin/staff.sh failed"
for L in bin/jobs-client.sh "$COL_REL"; do
  [ -r "$DIR/$L" ] && { scratch_install_closure "$L" "$S" >/dev/null || bad "C5 closure of $L failed"; }
done
cp "$DIR/bin/staff-core.mjs" "$S/bin/"
cp -r "$DIR/agent-core" "$S/agent-core"
cp "$DIR/prompts/staff/millwright-soul.md" "$S/prompts/staff/"
cp "$DIR/catalog/prompts/staff-tick.md" "$S/catalog/prompts/"
cat > "$S/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${STAFF_AGENT:-}" >> "$FXT/ac.log"
pf="${6#@}"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture title", body: "Fixture body."}]}' > "$5"
exit 0
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/beats.log"\n' > "$S/bin/lane-alert.sh"
chmod +x "$S/bin/agent-call.sh" "$S/bin/lane-alert.sh" "$S/bin/staff/"*.sh 2>/dev/null
c5() {
  scratch_rm "$S/state" || exit 1; scratch_rm "$S/logs" || exit 1
  mkdir -p "$S/state/fly" "$S/flags"
  cp "$LH/state/fleet-propagate.json" "$S/state/"; cp "$LH/flags/fly-pool-app-c1-pool" "$S/flags/"
  : > "$FXT/ac.log"; : > "$FXT/gh.log"; : > "$FXT/req.log"
  env HARNESS="$S" STAFF_FIXTURE="$T/fixture.sh" MW_FIXTURE="$T/fixture.sh" MW_NOW="$NOW" MW_SSH="$T/fakessh" \
    MW_RESOLV="$T/rs/ok-plain" STAFF_TIMED=1 PATH="$GPATH" bash "$S/bin/staff.sh" tick millwright > "$T/c5.out" 2>&1
  RC=$?
}
c5
eq "C5 observe rc" "$RC" 0
eq "C5 claims" "$(grep -c '^POST /api/staff/findings/claim' "$FXT/req.log")" 4
eq "C5 claimed classes" "$(grep '^POST /api/staff/findings/claim' "$FXT/req.log" | sed 's/^[^{]*//' | jq -r .class | sort | paste -sd' ')" \
  "bake-failed resolv-broken stale-bin tmp-full"
grep '^POST /api/staff/findings/claim' "$FXT/req.log" | grep -q '"agent":"millwright"' && ok || bad "C5 the claim is not millwright's"
eq "C5 one model call" "$(cat "$FXT/ac.log")" "staff-tick|millwright"
eq "C5 observe: no GitHub call" "$(lines "$FXT/gh.log")" 0
eq "C5 observe: four level digests" "$(cnt 'agent=millwright .*verdict=level' "$S/logs/staff-digest.log")" 4
eq "C5 observe: no filed outcome" "$(cat "$S"/state/staff/millwright/acted/*.json 2>/dev/null | grep -c '"outcome":"filed"')" 0
grep -q 'contract_level=observe' "$S/logs/staff.log" 2>/dev/null && ok || bad "C5 summary: $(cat "$S/logs/staff.log" 2>/dev/null)"
# Level file: the same tick reaches the filing path (GitHub is stubbed to an outage, so it holds).
echo file > "$FXT/settings/staff.millwright.level"
c5
eq "C5 file rc" "$RC" 0
[ "$(lines "$FXT/gh.log")" -ge 1 ] && ok || bad "C5 file: the filing path never called GitHub"
eq "C5 file: no level digest" "$(cnt 'verdict=level' "$S/logs/staff-digest.log")" 0
grep -q 'held=4 contract_level=file ' "$S/logs/staff.log" 2>/dev/null && ok || bad "C5 file summary: $(cat "$S/logs/staff.log" 2>/dev/null)"
rm -f "$FXT/settings/staff.millwright.level"
# Without the collector the tick claims nothing (D2).
mv "$S/$COL_REL" "$T/col.keep"; c5
eq "C5 no collector claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 0
mv "$T/col.keep" "$S/$COL_REL"

# ═════ L: the lever ══════════════════════════════════════════════════════════
LOGL="$LH/logs/staff-millwright-lever.log"
lev() {
  env HARNESS="$LH" MW_FIXTURE="$T/fixture.sh" MWL_NOW="$NOW" MW_NOW="$NOW" MW_SSH="$T/fakessh" \
    MW_RESOLV="$T/rs/ok-plain" HARNESS_SECRET=fixture-harness-secret PATH="$GPATH" "$@" \
    bash "$LH/$LEV_REL" > "$T/lev.out" 2>&1
  RC=$?
}
posts() { grep -c "^POST $1 " "$FXT/req.log"; }
last() { tail -1 "$LOGL" 2>/dev/null; }
l_seed() { # one failed bake (l-pool at SHA_A), level $1
  fx_reset; h_reset "$LH"
  seed_fail "$LH" l-pool "$SHA_A" $((NOW - 100)) timeout
  [ -n "${1:-}" ] && echo "$1" > "$FXT/settings/staff.millwright.level"
  return 0
}
# U the verdict function.
(
  MWL_LIB_ONLY=1 . "$LH/$LEV_REL" || exit 1
  f=0; b="$T/u.json"
  chk() { printf '%s' "$2" > "$b"; [ "$(mwl_action_verdict "$1" "$b" "$3")" = "$4" ] || { echo "FAIL: U $1 $2 -> want $4"; f=1; }; }
  chk 200 '{"ok":true,"action":{"action_key":"ab"}}' 0 run
  chk 200 '{"ok":true,"existing":true,"action":{}}' 0 taken
  chk 409 '{"error":"key_mismatch"}' 1 taken
  chk 500 '{"error":"x"}' 1 failed
  chk 200 '{"ok":false}' 0 failed
  chk 200 'not json' 0 failed
  chk "" '' 1 failed
  exit "$f"
) && ok || bad "U action verdicts"

# L1 level act, one failed bake, room 2: the outcome row, the mark, the sample.
l_seed act; lev
eq "L1 rc" "$RC" 0
eq "L1 one action POST" "$(posts /api/staff/levers/actions)" 1
A=$(grep '^POST /api/staff/levers/actions ' "$FXT/req.log" | sed 's/^[^{]*//')
eq "L1 action body" "$(jq -c '{agent, lever, target, dryRun, metric, metricBefore, key, detail}' <<<"$A")" \
  '{"agent":"millwright","lever":"bake-rerun","target":"l-pool","dryRun":false,"metric":"failed_bakes_and_broken_boxes","metricBefore":1,"key":"bake-rerun:l-pool:111111111111","detail":"reason=timeout"}'
eq "L1 the mark holds the sha" "$(cat "$LH/state/fly/l-pool.image-dirty" 2>/dev/null)" "$SHA_A"
eq "L1 one sample" "$(posts /api/staff/levers/metric)" 1
eq "L1 sample body" "$(grep '^POST /api/staff/levers/metric ' "$FXT/req.log" | sed 's/^[^{]*//' | jq -c .)" \
  '{"agent":"millwright","metric":"failed_bakes_and_broken_boxes","value":1,"detail":"bakes=1 boxes=0 resolv=0 tmp=0 stale=0 unreachable=0"}'
has "L1 log" "$(last)" "level=act value=1 sample=ok action=recorded:1 marks=1 detail=bakes=1 boxes=0"
# The sample is posted before the action (the sample settles due actions first).
eq "L1 order" "$(grep -E '^POST /api/staff/levers/(metric|actions) ' "$FXT/req.log" | cut -d' ' -f2 | paste -sd' ')" \
  "/api/staff/levers/metric /api/staff/levers/actions"
# L2 level observe, file, no row and a bad row: a sample, no action, no mark.
for lv in observe file "" "act;rm"; do
  l_seed "$lv"; lev
  eq "L2 [$lv] rc" "$RC" 0
  eq "L2 [$lv] sample" "$(posts /api/staff/levers/metric)" 1
  eq "L2 [$lv] no action" "$(posts /api/staff/levers/actions)" 0
  [ ! -e "$LH/state/fly/l-pool.image-dirty" ] && ok || bad "L2 [$lv] wrote a mark"
  want=observe; [ "$lv" = file ] && want=file
  has "L2 [$lv] log" "$(last)" "level=$want value=1 sample=ok action=none marks=0"
done
# L3 the bake id is already taken (existing, or 409): no mark.
l_seed act; printf '{"ok":true,"existing":true,"action":{"action_key":"x"}}' > "$FXT/action.body"; lev
eq "L3 existing: no mark" "$(cat "$LH/state/fly/l-pool.image-dirty" 2>/dev/null)" ""
has "L3 existing log" "$(last)" "action=taken:1 marks=0"
l_seed act; echo 409 > "$FXT/action.code"; printf '{"error":"key_mismatch"}' > "$FXT/action.body"; lev
eq "L3 409: no mark" "$(cat "$LH/state/fly/l-pool.image-dirty" 2>/dev/null)" ""
has "L3 409 log" "$(last)" "action=taken:1 marks=0"
l_seed act; echo 500 > "$FXT/action.code"; printf '{"error":"x"}' > "$FXT/action.body"; lev
eq "L3 500: no mark" "$(cat "$LH/state/fly/l-pool.image-dirty" 2>/dev/null)" ""
has "L3 500 log" "$(last)" "action=failed:1 marks=0"
# L4 a retry already queued: no action POST, the mark kept as it was.
l_seed act; echo "$SHA_B" > "$LH/state/fly/l-pool.image-dirty"; lev
eq "L4 no action" "$(posts /api/staff/levers/actions)" 0
eq "L4 the mark untouched" "$(cat "$LH/state/fly/l-pool.image-dirty")" "$SHA_B"
# L5 the day cap: 2 actions today = cap-reached; the scorecard fails = cap-unreadable.
l_seed act; printf '{"actions":2}' > "$FXT/scorecard.json"; lev
eq "L5 cap: no action" "$(posts /api/staff/levers/actions)" 0
has "L5 cap log" "$(last)" "action=cap-reached marks=0"
l_seed act; printf '{"actions":1}' > "$FXT/scorecard.json"; seed_fail "$LH" l-pool2 "$SHA_B" $((NOW - 100)); lev
eq "L5 room 1: one action for two bakes" "$(posts /api/staff/levers/actions)" 1
has "L5 room 1 log" "$(last)" "action=recorded:1 marks=1"
l_seed act; echo 1 > "$FXT/settings/staff.millwright.bake_rerun_max_day"; printf '{"actions":1}' > "$FXT/scorecard.json"; lev
has "L5 cap row 1" "$(last)" "action=cap-reached"
l_seed act; touch "$FXT/scorecard.fail"; lev
eq "L5 scorecard down: no action" "$(posts /api/staff/levers/actions)" 0
has "L5 scorecard down log" "$(last)" "action=cap-unreadable marks=0"
l_seed act; printf '{"actions":"2"}' > "$FXT/scorecard.json"; lev
has "L5 a non-number is unreadable" "$(last)" "action=cap-unreadable"
# L6 the metric unreadable: no sample, no action, no number.
l_seed act; echo 'x{' > "$LH/state/fleet-propagate.json"; lev
eq "L6 no sample" "$(posts /api/staff/levers/metric)" 0
eq "L6 no action" "$(posts /api/staff/levers/actions)" 0
has "L6 log" "$(last)" "level=- value=unreadable sample=- action=none"
l_seed act; touch "$FXT/boxes.fail"; lev
has "L6 boxes unreadable" "$(last)" "value=unreadable"
# L7 the kill switches: no request at all.
for k in flag:staff-off-all flag:staff-kill-all flag:staff-off-millwright flag:staff-kill-millwright env:STAFF_ENABLED=0 lane:lane-off-staff-millwright-lever; do
  l_seed act
  case "$k" in
    flag:*) : > "$LH/flags/${k#flag:}"; lev ;;
    env:*) lev STAFF_ENABLED=0 ;;
    lane:*) : > "$LH/flags/${k#lane:}"; lev LANE_GATE_DISABLE=0 ;;
  esac
  eq "L7 [$k] rc" "$RC" 0
  eq "L7 [$k] 0 requests" "$(grep -vc '^SETTING ' "$FXT/req.log")" 0
  [ ! -e "$LH/state/fly/l-pool.image-dirty" ] && ok || bad "L7 [$k] wrote a mark"
  case "$k" in
    flag:*|env:*) has "L7 [$k] logged" "$(last)" "killed by ${k#*:}" ;;
  esac
done
# L8 the pool is fixed between the read and the act: skipped, no POST.
l_seed act; echo "$LH/state/fly/l-pool.image" > "$FXT/scorecard.touch"; lev
eq "L8 no action" "$(posts /api/staff/levers/actions)" 0
has "L8 log" "$(last)" "skipped=l-pool:fixed"
# L9 the sample POST fails: sample=failed, the act step still runs.
l_seed act; touch "$FXT/metric.fail"; lev
has "L9 log" "$(last)" "sample=failed action=recorded:1 marks=1"
# Not configured: no HARNESS_SECRET = no request.
l_seed act; lev HARNESS_SECRET=
eq "L not configured: 0 requests" "$(lines "$FXT/req.log")" 0
has "L not configured log" "$(last)" "not-configured (no HARNESS_SECRET)"
# A bad argument is rc 2.
bash "$LH/$LEV_REL" --nope >/dev/null 2>&1; eq "L bad argument rc" "$?" 2

# ═════ P: the REAL fleet-propagate writes .pool_fail; P4 the round trip ══════
PH="$T/ph"
mkdir -p "$PH/bin" "$PH/logs" "$PH/state" "$PH/locks" "$PH/flags" "$T/pbin"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$PH/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$PH" >/dev/null || bad "P closure of fleet-paths failed"
echo hub > "$PH/state/box-id"
printf 'p-alpha Acme/p-alpha - - 2 box-p 192.0.2.91\np-beta Acme/p-beta - - 2 box-p 192.0.2.91\n' > "$PH/fleet.conf"
printf 'builder-p-alpha\n' > "$PH/flags/fly-pool-app-p-alpha"
printf 'builder-p-beta\n' > "$PH/flags/fly-pool-app-p-beta"
cat > "$T/pbin/ssh" <<'EOF'
#!/bin/bash
echo "cafe123456789"; exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/pbin/pgrep"
cat > "$T/pbin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && exit 0
exit 0
EOF
printf '#!/bin/bash\necho "synced (stub)"; exit 0\n' > "$PH/bin/harness-sync.sh"
cat > "$PH/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
case " ${BAKE_FAIL:-} " in *" $1 "*) echo "Error: build failed (stub)"; exit 1 ;; esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$PH/bin/lane-alert.sh"
chmod +x "$T/pbin"/* "$PH/bin"/*
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"; echo "echo v0" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
PN=0
pcommit() { PN=$((PN+1)); echo "echo v$PN" > "$T/src/bin/run-build.sh"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "c$PN" && git -C "$T/src" push -q origin main; }
prun() {
  : > "$T/bake.calls"
  ( HARNESS="$PH" HARNESS_CHECKOUT="$T/checkout" FLEET_PROPAGATE_PATH="$T/pbin:/usr/bin:/bin:/usr/local/bin" \
    BAKE_CALLS="$T/bake.calls" BAKE_FAIL="${BAKE_FAIL:-}" POOL_IMAGE_MIN_AGE_MIN="${KNOB:-}" \
    POOL_BAKE_RETRY_MAX="${RETRY:-}" HARNESS_LANE=test bash "$PH/bin/fleet-propagate.sh" ) > "$T/p.out" 2> "$T/p.err"
}
pj() { jq -c "$1" "$PH/state/fleet-propagate.json" 2>/dev/null; }
stamp() { mkdir -p "$PH/state/fly"; echo "$2" > "$PH/state/fly/$1.baked-at"; }
prun   # the first run records where the fleet is

# P1 both pools fail (no retry): .pool_fail holds {sha, at, reason} for each.
stamp p-alpha $(( $(date +%s) - 86400 )); stamp p-beta $(( $(date +%s) - 86400 ))
pcommit; P1SHA=$(git -C "$T/src" rev-parse HEAD)
B0=$(date -u +%s); RETRY=0 BAKE_FAIL="p-alpha p-beta" prun; B1=$(date -u +%s)
eq "P1 bakes" "$(sort "$T/bake.calls" | paste -sd' ')" "p-alpha p-beta"
eq "P1 status" "$(pj '.pools["p-alpha"].status')" '"fail"'
eq "P1 entry sha" "$(pj '.pool_fail["p-alpha"].sha')" "\"$P1SHA\""
eq "P1 entry reason = the pool's reason" "$(pj '.pool_fail["p-alpha"].reason')" "$(pj '.pools["p-alpha"].reason')"
AT=$(pj '.pool_fail["p-alpha"].at')
[[ $AT =~ ^[0-9]+$ ]] && [ "$AT" -ge "$B0" ] && [ "$AT" -le "$B1" ] && ok || bad "P1 at=$AT not in [$B0,$B1]"
eq "P1 .pools shape unchanged" "$(pj '.pools["p-alpha"] | keys')" '["capture","phases","reason","status","warm","warm_sha"]'
eq "P1 mw_bakes reads it back" "$(lib mw_bakes "$PH" | cut -f1,2,5 | paste -sd' ')" "p-alpha	$P1SHA	0 p-beta	$P1SHA	0"
BETA=$(pj '.pool_fail["p-beta"]')
# P2 alpha bakes ok, beta is debounced: alpha's entry goes, beta's stays.
stamp p-alpha $(( $(date +%s) - 86400 )); stamp p-beta "$(date +%s)"
pcommit
KNOB=60 prun
eq "P2 alpha baked ok" "$(pj '.pools["p-alpha"].status')" '"ok"'
eq "P2 beta debounced" "$(pj '.pools["p-beta"].status')" '"debounced"'
eq "P2 alpha's entry is gone" "$(pj '.pool_fail | has("p-alpha")')" false
eq "P2 beta's entry is kept" "$(pj '.pool_fail["p-beta"]')" "$BETA"
# P3 a run without beta and with no failure leaves beta's entry unchanged.
rm -f "$PH/flags/fly-pool-app-p-beta"; stamp p-alpha $(( $(date +%s) - 86400 ))
pcommit; prun
eq "P3 alpha ok" "$(pj '.pools["p-alpha"].status')" '"ok"'
eq "P3 beta's entry unchanged" "$(pj '.pool_fail["p-beta"]')" "$BETA"
eq "P3 only beta" "$(pj '.pool_fail | keys')" '["p-beta"]'
printf 'builder-p-beta\n' > "$PH/flags/fly-pool-app-p-beta"
# P4 the round trip: a real failed bake -> the real lever marks it -> a real drain bakes it.
fx_reset; echo act > "$FXT/settings/staff.millwright.level"
jq '.pool_fail = {}' "$PH/state/fleet-propagate.json" > "$T/r.json" && mv "$T/r.json" "$PH/state/fleet-propagate.json"
stamp p-alpha $(( $(date +%s) - 86400 )); stamp p-beta $(( $(date +%s) - 86400 ))
pcommit; P4SHA=$(git -C "$T/src" rev-parse HEAD)
RETRY=0 BAKE_FAIL=p-alpha prun
eq "P4 alpha failed" "$(pj '.pool_fail["p-alpha"].sha')" "\"$P4SHA\""
[ ! -e "$PH/state/fly/p-alpha.image-dirty" ] && ok || bad "P4 fixture: no retry may be queued"
env HARNESS="$PH" MW_FIXTURE="$T/fixture.sh" MWL_NOW="$NOW" MW_NOW="$NOW" MW_SSH="$T/fakessh" MW_RESOLV="$T/rs/ok-plain" \
  HARNESS_SECRET=fixture-harness-secret PATH="$GPATH" bash "$LH/$LEV_REL" > "$T/p4.out" 2>&1
eq "P4 the lever marked alpha" "$(cat "$PH/state/fly/p-alpha.image-dirty" 2>/dev/null)" "$P4SHA"
has "P4 lever log" "$(tail -1 "$PH/logs/staff-millwright-lever.log")" "action=recorded:1 marks=1"
prun
eq "P4 the drain baked exactly alpha" "$(paste -sd' ' "$T/bake.calls")" "p-alpha"
eq "P4 the drain was ok" "$(pj '.pools["p-alpha"].status')" '"ok"'
[ ! -e "$PH/state/fly/p-alpha.image-dirty" ] && ok || bad "P4 the drain left the mark"
eq "P4 the entry is gone" "$(pj '.pool_fail | has("p-alpha")')" false
eq "P4 mw_bakes is empty" "$(lib mw_bakes "$PH")" ""

# ═════ R1 the soul ═══════════════════════════════════════════════════════════
if command -v node >/dev/null 2>&1; then
  SOUL=$(node "$DIR/bin/staff-core.mjs" soul "$DIR/prompts/staff/millwright-soul.md" 2>/dev/null)
  eq "R1 ok" "$(jq -r .ok <<<"$SOUL")" true
  eq "R1 report lines" "$(jq -r '.report | length' <<<"$SOUL")" 8
  for r in "a pool image bake that failed and has no ok bake since" "a box whose /etc/resolv.conf is broken" \
           "a box whose /tmp is full" "a box whose harness checkout lags main (a stale bin)"; do
    jq -e --arg r "$r" '.report | index($r)' <<<"$SOUL" >/dev/null && ok || bad "R1 REPORT lacks '$r'"
  done
  eq "R1 never" "$(jq -c .never <<<"$SOUL")" \
    '["merge a pull request","deploy","write to a production database","change a kill flag","change an autonomy level","print a secret value","file on a staff-filed ticket","delete a file on a box","upgrade a dependency"]'
  eq "R1 may" "$(jq -c .may <<<"$SOUL")" '["file a ticket","write a digest line","claim a finding"]'
else
  echo "R1 skipped: node is not installed"
fi

# ═════ Z1 no network ═════════════════════════════════════════════════════════
[ -e "$T/real-calls.log" ] && bad "Z1 a real ssh/curl/gh ran: $(cat "$T/real-calls.log")" || ok
[ -s "$FXT.unknown.log" ] && bad "Z1 an unstubbed route was asked: $(cat "$FXT.unknown.log")" || ok

echo "staff-millwright.bh-10124: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
