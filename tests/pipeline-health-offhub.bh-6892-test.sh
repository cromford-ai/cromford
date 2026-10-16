#!/bin/bash
# tests/pipeline-health-offhub.bh-6892-test.sh — BH-6892 (BH-6881.10): a
# `bin/pipeline-health.sh --project <p>` run on a lane-run machine (LANE_RUN_ID
# set) writes no fleet-wide file that a write-back cannot carry.
#
#   M1  the .rw carries state/health-active.txt and state/closeout-aged-out.tsv
#       as @rows paths, the .ro no longer lists them, and the health-active
#       ERE's namespace list is PH_PROJ_NS of bin/pipeline-health.sh
#   E1  the health-active @rows ERE takes fx's keys only (prefix decoys out)
#   C1  the closeout @rows ERE takes fx's rows only (case kept, decoys out)
#   A1  publish fx from a hub that holds fx and fx2 lines, fetch it into a
#       machine root, run the REAL script there: rc 0, the write-back validates
#       and carries fx's lines only, and none of the fleet-wide files
#   A2  fx and fx2 write-backs from the same generation both apply, 0 conflicts
#   L1  the alert line of A1 is one POST; replayed on the hub it lands in
#       logs/ALERTS.log once, and a second replay keeps it once
#   L2  a key that cleared posts one `resolved` line; the hub replay beats
#       resolved:true with the same alertid
#   L3  past ALERT_LINE_TICK_MAX every line is still a POST; no machine ALERTS.log
#   L4  the jobs API answers 500: the run still exits 0
#   D1  a fleet stamp 10 min old (TTL 7200) suppresses the machine's first page
#   D2  the machine's own stamp survives write-back and the next snapshot
#   D3  the seed drops stamps older than 8 days and never takes fx2's keys
#   R1  the stale-parent check reads GitHub REST and never runs git on
#       $HUB_REPOS; R1b a failed PR list carries staleparent:fx:9
#   R2  a child diff equal to a base diff under another sha pages once
#   R3  STALE_PARENT_REST_DIFF_MAX=1: no PR judged, both keys carried, the
#       one diff read is cached; R4 a base list past 3 pages carries the
#       project; R5 an unreadable PR commit list carries the PR
#   C2  closeout_record_aged in a run waits on state/closeout-aged-out.tsv.lock
#   C3  bin/disk-clean.sh skips its tsv prune while that lock is held
#   N1  LANE_RUN_ID unset, --project: stamp, health-alerted.json, fleet_alert beat
#   N2  LANE_RUN_ID unset, no arguments (every section): the same
#   N3  LANE_RUN_ID empty, --project: the same
#   P1  the BH-6892 schema fragment seeds lane_placement.pipeline-health=hub
#       and no fragment seeds it fly
#
# The lane-snapshot and alert-lines routes are a stub jobs client that keeps
# the worker's state in files under $T/srv (the BH-6884 shape). bin/beat.sh is
# a stub that logs each payload. gh is a stub on PATH that logs each call.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-offhub.bh-6892-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO/bin/lib/lane-run-inputs.sh"
PHS="$REPO/bin/pipeline-health.sh"
RW="$REPO/catalog/lane-run-inputs.d/pipeline-health.rw"
RO="$REPO/catalog/lane-run-inputs.d/pipeline-health.ro"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
  || { echo "SKIP: jq, flock or python3 missing"; exit 0; }
unset REGISTRY_SOURCE HARNESS H LANE_RUN_ID PL_LANE PL_PROJECT PL_LOCK_FD GH_TOKEN
export LRI_MANIFEST_DIR="$REPO/catalog/lane-run-inputs.d"
NOW=$(date +%s)
REALGIT=$(command -v git)
export JOBS_HTTP=200
SRV="$T/srv"; mkdir -p "$SRV" "$T/fakebin" "$T/stub" "$T/gitshim"

# ---------------------------------------------------------------------------
# The jobs client stub. Sourced by this shell and installed as bin/jobs-client.sh
# in every tree, so the machine's bin/alert-line.sh reaches it too.
#   /api/lane-snapshots/pipeline-health/<p>/...   the BH-6884 file-backed worker
#   POST /api/alert-lines          one body a line in $SRV/alert-posts.jsonl
#   GET  /api/alert-lines?...      $SRV/alert-get.json
#   POST /api/alert-lines/applied  one body a line in $SRV/alert-acks.log
# $SRV/alert-fail present = every alert-lines call fails (a 500).
cat > "$T/stub/jobs-client.sh" <<EOF
# shellcheck shell=bash
SRV="$SRV"
EOF
cat >> "$T/stub/jobs-client.sh" <<'EOF'
_srv() { local rest="${1#/api/lane-snapshots/pipeline-health/}"; SP="${rest%%/*}"; SUB="${rest#"$SP"}"; SUB="${SUB%%\?*}"; SD="$SRV/$SP"; mkdir -p "$SD"; }
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$SRV/req.log"
  case "$1 $2" in
    "POST /api/alert-lines/applied") [ -f "$SRV/alert-fail" ] && return 1
      printf '%s\n' "$3" >> "$SRV/alert-acks.log"; echo '{"applied":1}'; return 0 ;;
    "GET /api/alert-lines?"*) [ -f "$SRV/alert-fail" ] && return 1; cat "$SRV/alert-get.json"; return 0 ;;
    "POST /api/alert-lines") [ -f "$SRV/alert-fail" ] && return 1
      printf '%s\n' "$3" >> "$SRV/alert-posts.jsonl"
      printf '{"id":%s,"dup":false}\n' "$(wc -l < "$SRV/alert-posts.jsonl")"; return 0 ;;
    *" /api/lane-snapshots/pipeline-health/"*) ;;
    *) return 1 ;;
  esac
  _srv "$2"
  case "$1 $SUB" in
    "GET ") [ -f "$SD/snap.json" ] || return 2
      jq -s '.[0] + {writebacks: .[1].writebacks}' "$SD/snap.json" <(cat "$SD/wblist.json" 2>/dev/null || echo '{"writebacks":[]}') ;;
    "GET /parts/"*) cat "$SD/part-${SUB#/parts/}.json" ;;
    "GET /writebacks") cat "$SD/wblist.json" 2>/dev/null || echo '{"writebacks":[]}' ;;
    "GET /writebacks/"*) [ -f "$SD/wb-${SUB#/writebacks/}.json" ] || return 2; cat "$SD/wb-${SUB#/writebacks/}.json" ;;
    "POST /commit") printf '%s' "$3" | jq '{sha, parts, applied_through, age_s: 0, truncated: false}' > "$SD/snap.json"; echo '{}' ;;
    "POST /writebacks/ack") printf '%s\n' "$3" >> "$SD/ack.log"; echo '{}' ;;
    *) return 1 ;;
  esac
}
_jobs_req_file() {
  local n
  printf '%s %s\n' "$1" "$2" >> "$SRV/req.log"
  _srv "$2"
  case "$1 $SUB" in
    "PUT /parts/"*) cp "$3" "$SD/part-${SUB#/parts/}.json"; echo '{}' ;;
    "POST /writebacks") n=$(( $(find "$SD" -maxdepth 1 -name 'posted-*.json' | wc -l) + 1 ))
      cp "$3" "$SD/posted-$n.json"; echo "{\"id\":$n}" ;;
    *) return 1 ;;
  esac
}
setting_get() { return 1; }
_jobs_box_name() { echo fixture-box; }
EOF
# shellcheck source=/dev/null
. "$T/stub/jobs-client.sh" || exit 1

# bin/beat.sh: one payload a line in <tree>/beat.log.
cat > "$T/stub/beat.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "$HARNESS/beat.log"
exit 0
EOF
# bin/queued-fly-relayed.sh: no record is a relayed stub.
printf '#!/bin/bash\nexit 1\n' > "$T/stub/queued-fly-relayed.sh"
chmod +x "$T/stub/beat.sh" "$T/stub/queued-fly-relayed.sh"

# gh: one call a line in <tree>/gh.calls. Fixture files in the tree:
#   prs-r.json    o/fx's open PRs for the stalepr check (served with -i)
#   sp-list.json  o/fx's open PRs for the stale-parent check
#   sp-commits-<n>.json, sp-base.json, diff-<sha>  its REST reads
#   splistfail    present = the stale-parent PR list fails
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
A="$*"
echo "$A" >> "$HARNESS/gh.calls"
case "$A" in
  "api repos/"*" -q .id") exit 0 ;;
  *"api rate_limit"*)
    now=$(date +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "$((now+3600))" "$((now+3600))" ;;
  *"-i "*"repos/o/fx/pulls?state="*) printf 'HTTP/2.0 200\r\n\r\n'; cat "$HARNESS/prs-r.json" 2>/dev/null || echo '[]' ;;
  *"-i "*"/pulls?state="*) printf 'HTTP/2.0 200\r\n\r\n'; echo '[]' ;;
  "api repos/o/fx/pulls?state=open&per_page=100")
    [ -f "$HARNESS/splistfail" ] && exit 1; cat "$HARNESS/sp-list.json" 2>/dev/null || echo '[]' ;;
  "api repos/"*"/pulls?state=open&per_page=100") echo '[]' ;;
  *"application/vnd.github.diff"*"repos/o/fx/commits/"*) cat "$HARNESS/diff-${A##*/}" 2>/dev/null || exit 1 ;;
  *"api repos/o/fx/pulls/"*"/commits"*) n=${A#*pulls/}; n=${n%%/*}; cat "$HARNESS/sp-commits-$n.json" 2>/dev/null || exit 1 ;;
  *"api repos/o/fx/commits?sha="*) cat "$HARNESS/sp-base.json" 2>/dev/null || echo '[]' ;;
  *) exit 1 ;;
esac
EOF
# git shim (R1 only): one call a line in $T/git.log, then the real git.
cat > "$T/gitshim/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git.log"
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/gh" "$T/gitshim/git"

# o/fx's one aging PR (the stalepr check), copied into every tree.
printf '[{"number":7,"created_at":"2026-09-10T00:00:00Z","updated_at":"2026-09-10T00:00:00Z","title":"FX-7","draft":false,"state":"open","merged_at":null,"closed_at":null,"body":"","labels":[],"html_url":"https://github.com/o/fx/pull/7","head":{"ref":"b","sha":"s7"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"}}]\n' > "$T/stub/prs-r.json"

# mktree <dir> — a harness tree: the stubs, then the REAL closure of
# bin/pipeline-health.sh and bin/alert-line.sh (no-clobber keeps the stubs).
mktree() {
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/env" "$d/locks" || return 1
  cp "$T/stub/beat.sh" "$T/stub/queued-fly-relayed.sh" "$T/stub/jobs-client.sh" "$d/bin/" || return 1
  scratch_install_closure bin/pipeline-health.sh "$d" >/dev/null || return 1
  scratch_install_closure bin/alert-line.sh "$d" >/dev/null || return 1
  printf 'fx\to/fx\nfx2\to/fx2\n' > "$d/fleet.conf"
  : > "$d/env/global.env"; : > "$d/alerts.conf"
  touch "$d/flags/remediation-disabled"
  cp "$T/stub/prs-r.json" "$d/prs-r.json"
}
# record <tree> <dir> <age-s> — a build record with a PR_CREATED RESULT.
record() { mkdir -p "$1/builds/$2" && printf 'PR_CREATED https://github.com/o/%s/pull/2\n' "${2%%-*}" > "$1/builds/$2/RESULT" \
  && touch -d "@$(( NOW - $3 ))" "$1/builds/$2/RESULT"; }
# mkhub <dir> — a hub tree with fx and fx2 lines in every fleet-wide file.
mkhub() {
  local d="$1"
  mktree "$d" || return 1
  printf '%s\n' costcap:hub stalepr:FX:1 staleparent:fx:9 stalepr:fx2 uncommented:fx2:3 > "$d/state/health-active.txt"
  printf 'fx\tfx-BH-0-202609010000\tPR_CREATED x\taged\nfx2\tfx2-BH-0-202609010000\tPR_CREATED y\taged\n' > "$d/state/closeout-aged-out.tsv"
  jq -nc --argjson n "$NOW" '{"costcap:hub":($n-60), "stalepr:fx2":($n-60), "uncommented:fx2:3":($n-60),
    "stalepr:fx:3":($n-9*86400), "leadunqueued:o/fx#3":($n-60), "leadunqueued:o/fx2#4":($n-60)}' > "$d/state/health-alerted.json"
  record "$d" fx-BH-1-202609010000 $((200 * 3600))
  record "$d" fx-BH-2-202610150000 7200
  record "$d" fx2-BH-5-202610150000 7200
}
# envrun <tree> <args...> — the environment one run gets; the caller adds
# LANE_RUN_ID. RC is the run's exit code.
envrun() {
  local d="$1"; shift
  ( cd "$d" && env PATH="${XPATH:-}$T/fakebin:$PATH" HARNESS="$d" GH_BUDGET_TTL_S=0 ALERTS_CONF="$d/alerts.conf" \
      FLEET_CONF="$d/fleet.conf" LANE_GATE_DISABLE=1 HARNESS_ENV_DIR="$d/env" GH_BUDGET_CORE_REMAINING=4000 \
      HUB_REPOS="${HUBREPOS:-$T/no-repos}" "$@" ) > "$d/out.txt" 2> "$d/err.txt"
  RC=$?
}
# mrun <tree> <p> [VAR=VAL...] — one machine run of project <p>.
mrun() { local d="$1" p="$2"; shift 2
  envrun "$d" LANE_RUN_ID=run-fixture-1 PL_LANE=pipeline-health PL_PROJECT="$p" "$@" "$d/bin/pipeline-health.sh" --project "$p"; }
# L <root> <cmd...> — one call of the lri lib in a subshell rooted at <root>.
L() { local r="$1"; shift; ( export HARNESS="$r" FLEET_CONF="$r/fleet.conf"; . "$LIB" || exit 99; "$@" ); }
PUB()   { L "$1" lri_publish pipeline-health "$2"; }
FETCH() { mktree "$1" || return 1; rm -f "$1/state/health-alerted.json" "$1/state/health-active.txt"
  L "$1" lri_fetch pipeline-health "$2" x >/dev/null; }
# CKPT <machine> <p> — post a checkpoint; POSTED is the body file it sent.
CKPT() { POSTED="$T/no-checkpoint-body"
  LANE_RUN_ID=run-fixture-1 L "$1" lri_checkpoint pipeline-health "$2" >/dev/null || return 1
  POSTED=$(find "$SRV/$2" -maxdepth 1 -name 'posted-*.json' | sort -V | tail -n 1); }
WBTGZ() { jq -j .b64 "$1" | base64 -d > "$2"; }
QUEUE() { cp "$3" "$SRV/$1/wb-$2.json"
  jq -n --argjson i "$2" --arg s "$(jq -r .sha "$3")" '{writebacks:[{id:$i, sha:$s}]}' > "$SRV/$1/wblist.json"; }
UNQUEUE() { rm -f "$SRV/$1/wblist.json"; }
APPLY() { APPLIED=$(L "$1" lri_apply_pending pipeline-health "$2" 2>/dev/null); ARC=$?; }
SNAPM() { local n; for ((n = 0; n < $(jq -r .parts "$SRV/$1/snap.json"); n++)); do jq -j .b64 "$SRV/$1/part-$n.json" | base64 -d; done \
  | tar -xzOf - "$2" 2>/dev/null; }
# posts <jq filter> — how many alert-line POSTs match.
posts() { [ -s "$SRV/alert-posts.jsonl" ] || { echo 0; return; }; jq -c "select($1)" "$SRV/alert-posts.jsonl" | grep -c .; }
# HUBAPPLY <hub> — alr_apply once on the hub, from every POST so far.
HUBAPPLY() {
  local n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    jq -c --argjson id "$n" --arg k "$(printf '%s' "$line" | sha256sum | cut -c1-64)" '. + {id:$id, dedup_key:$k}' <<<"$line"
  done < "$SRV/alert-posts.jsonl" | jq -sc '{lines:., truncated:false}' > "$SRV/alert-get.json"
  ( export HARNESS="$1" JOBS_URL=https://jobs.invalid HARNESS_SECRET=fixture-secret PATH="$T/fakebin:$PATH"
    . "$T/stub/jobs-client.sh"; . "$1/bin/lib/alert-line-remote.sh" || exit 99; alr_apply )
}

# ============================================================================
echo "M1: the manifests"
OUT=$(L "$T/none" lri_paths pipeline-health fx rw); rc=$?
for want in state/health-active.txt state/closeout-aged-out.tsv; do
  [ "$rc" = 0 ] && grep -qxF "$want" <<<"$OUT" && ok "M1 rw holds $want" || bad "M1 rw rc=$rc lacks $want: $OUT"
done
for no in state/health-active.txt state/closeout-aged-out.tsv; do
  grep -qF "$no" <<<"$(grep -v '^[[:space:]]*#' "$RO")" && bad "M1 the .ro still names $no" || ok "M1 the .ro does not name $no"
done
NSRW=$(sed -n 's/^@rows state\/health-active\.txt \^(\([^)]*\)):.*/\1/p' "$RW" | tr '|' '\n' | sort)
NSPH=$(sed -n 's/^PH_PROJ_NS="\(.*\)"$/\1/p' "$PHS" | tr ' ' '\n' | sort)
[ -n "$NSRW" ] && [ "$NSRW" = "$NSPH" ] && ok "M1 the @rows namespace list is PH_PROJ_NS ($(grep -c . <<<"$NSRW") names)" \
  || bad "M1 @rows names [$(tr '\n' ' ' <<<"$NSRW")] != PH_PROJ_NS [$(tr '\n' ' ' <<<"$NSPH")]"

# ============================================================================
echo "E1/C1: the @rows EREs"
H0="$T/h0"; mktree "$H0" || exit 1
printf '%s\n' stalepr:fx:12 noprogress:fx stalepr:fx2:1 costcap:fx stalepr:xfx:1 leadunqueued:o/fx#3 STALEPR:fx2:1 stalepr:fx > "$H0/state/health-active.txt"
printf 'fx\td1\nFX\td2\nfx2\td3\nxfx\td4\n' > "$H0/state/closeout-aged-out.tsv"
PUB "$H0" fx >/dev/null; rc=$?
GOT=$(SNAPM fx state/health-active.txt)
[ "$rc" = 0 ] && [ "$GOT" = $'stalepr:fx:12\nnoprogress:fx\nstalepr:fx' ] && ok "E1 the snapshot holds fx's 3 keys only" \
  || bad "E1 rc=$rc member: $(tr '\n' ' ' <<<"$GOT")"
GOT=$(SNAPM fx state/closeout-aged-out.tsv)
[ "$GOT" = $'fx\td1\nFX\td2' ] && ok "C1 the snapshot holds fx and FX rows, not fx2 or xfx" || bad "C1 member: $(tr '\t\n' ' |' <<<"$GOT")"

# ============================================================================
echo "A1/A2: one project's run on a machine, and two write-backs"
HUB="$T/hub"; mkhub "$HUB" || exit 1
PUB "$HUB" fx >/dev/null && PUB "$HUB" fx2 >/dev/null || bad "A1 publish failed"
M1="$T/m1"; FETCH "$M1" fx || bad "A1 fetch fx failed"
M2="$T/m2"; FETCH "$M2" fx2 || bad "A2 fetch fx2 failed"
[ "$(cat "$M1/state/health-active.txt")" = $'stalepr:FX:1\nstaleparent:fx:9' ] && ok "A1 the machine starts from fx's ACTIVE lines" \
  || bad "A1 machine ACTIVE: $(tr '\n' ' ' < "$M1/state/health-active.txt")"
mrun "$M1" fx
[ "$RC" = 0 ] && ok "A1 the machine run exits 0" || bad "A1 rc=$RC err=$(tail -5 "$M1/err.txt")"
grep -qx 'stalepr:fx' "$M1/state/health-active.txt" && grep -qx 'uncommented:fx:1' "$M1/state/health-active.txt" \
  && ok "A1 the run fired stalepr:fx and uncommented:fx:1" || bad "A1 ACTIVE: $(tr '\n' ' ' < "$M1/state/health-active.txt")"
CKPT "$M1" fx || bad "A1 checkpoint failed"
WBTGZ "$POSTED" "$T/a1.tgz"
MEM=$(tar -tzf "$T/a1.tgz" 2>/dev/null)
( export HARNESS="$HUB"; . "$LIB" || exit 99; LRI_LANE=pipeline-health _lri_validate fx "$T/a1.tgz" writeback ) \
  && ok "A1 _lri_validate accepts the write-back" || bad "A1 _lri_validate refuses: $(tr '\n' ' ' <<<"$MEM")"
for f in state/health-active.txt state/closeout-aged-out.tsv; do
  GOT=$(tar -xzOf "$T/a1.tgz" "$f" 2>/dev/null)
  [ -n "$GOT" ] && ! grep -viE '^((stuckqueue|poolhalt|uncommented|emptyurl|staleremote|tickloop|stalepr|starved|strandedqueue|staledequeue|staleparent|noprogress|stalehold|stalledblocker):fx(:|$)|fx[[:space:]])' <<<"$GOT" >/dev/null \
    && ok "A1 every line of $f is fx's ($(grep -c . <<<"$GOT"))" || bad "A1 $f: $(tr '\t\n' ' |' <<<"$GOT")"
done
grep -q $'^fx\tfx-BH-1-202609010000' <<<"$(tar -xzOf "$T/a1.tgz" state/closeout-aged-out.tsv 2>/dev/null)" \
  && ok "A1 the aged-out dir is a new fx row" || bad "A1 no aged-out row for fx-BH-1"
for no in state/health-active.stamp state/health-alerted.json logs/ALERTS.log state/alert-quarantine.jsonl; do
  grep -qxF "$no" <<<"$MEM" && bad "A1 the write-back carries $no" || ok "A1 the write-back does not carry $no"
done
grep -qE '^(state/alerts/|state/alert-line-sent/)' <<<"$MEM" && bad "A1 the write-back carries alert state" || ok "A1 no state/alerts or alert-line-sent member"
[ ! -e "$M1/state/health-active.stamp" ] && ok "A1 no stamp on the machine" || bad "A1 the machine wrote state/health-active.stamp"
[ ! -s "$M1/logs/ALERTS.log" ] && ok "A1 no ALERTS.log bytes on the machine" || bad "A1 machine ALERTS.log: $(cat "$M1/logs/ALERTS.log")"
grep -q fleet_alert "$M1/beat.log" 2>/dev/null && bad "A1 the machine made a fleet_alert beat" || ok "A1 no beat.sh call on the machine"
mrun "$M2" fx2
[ "$RC" = 0 ] && ok "A2 the fx2 run exits 0" || bad "A2 fx2 rc=$RC"
CKPT "$M2" fx2 || bad "A2 checkpoint fx2 failed"
cp "$POSTED" "$T/a2.json"
cp "$SRV/fx/$(basename "$(find "$SRV/fx" -maxdepth 1 -name 'posted-*.json' | sort -V | tail -n 1)")" "$T/a1.json"
QUEUE fx 1 "$T/a1.json"; APPLY "$HUB" fx; A1OUT="$APPLIED"; A1RC=$ARC; UNQUEUE fx
QUEUE fx2 1 "$T/a2.json"; APPLY "$HUB" fx2; A2OUT="$APPLIED"; A2RC=$ARC; UNQUEUE fx2
[ "$A1RC" = 0 ] && [ "$A1OUT" = "applied=1 conflicts=0 rejected=0" ] && ok "A2 fx applies: $A1OUT" || bad "A2 fx rc=$A1RC: $A1OUT"
[ "$A2RC" = 0 ] && [ "$A2OUT" = "applied=1 conflicts=0 rejected=0" ] && ok "A2 fx2 applies: $A2OUT" || bad "A2 fx2 rc=$A2RC: $A2OUT"
HA=$(cat "$HUB/state/health-active.txt")
for k in costcap:hub stalepr:FX:1 stalepr:fx uncommented:fx:1 uncommented:fx2:1; do
  grep -qxF "$k" <<<"$HA" && ok "A2 the hub ACTIVE holds $k" || bad "A2 hub ACTIVE lacks $k: $(tr '\n' ' ' <<<"$HA")"
done
for k in staleparent:fx:9 uncommented:fx2:3; do
  grep -qxF "$k" <<<"$HA" && bad "A2 the hub ACTIVE still holds the retracted $k" || ok "A2 the retracted $k is gone"
done
grep -q $'^fx2\tfx2-BH-0' "$HUB/state/closeout-aged-out.tsv" && grep -q $'^fx\tfx-BH-1' "$HUB/state/closeout-aged-out.tsv" \
  && ok "A2 the hub tsv holds fx2's old row and fx's new row" || bad "A2 hub tsv: $(tr '\t\n' ' |' < "$HUB/state/closeout-aged-out.tsv")"

# ============================================================================
echo "L1/L2: alert lines through /api/alert-lines and the hub replay"
UC=$(posts '.alertid == "ph-uncommented_fx_1"')
[ "$UC" = 1 ] && ok "L1 the uncommented:fx:1 page is one POST" || bad "L1 want 1 POST, got $UC: $(cat "$SRV/alert-posts.jsonl" 2>/dev/null)"
[ "$(posts '.alertid == "ph-uncommented_fx_1" and .project == "fx" and .lane == "pipeline-health" and .run_id == "run-fixture-1"')" = 1 ] \
  && ok "L1 the POST names lane, project and run" || bad "L1 POST fields: $(head -1 "$SRV/alert-posts.jsonl" 2>/dev/null)"
LINE=$(jq -r 'select(.alertid == "ph-uncommented_fx_1") | .line' "$SRV/alert-posts.jsonl" 2>/dev/null | head -1)
OUT=$(HUBAPPLY "$HUB"); rc=$?
[ "$rc" = 0 ] && ok "L1 alr_apply: $OUT" || bad "L1 alr_apply rc=$rc: $OUT"
[ -n "$LINE" ] && [ "$(grep -cxF -- "$LINE" "$HUB/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok "L1 the hub ALERTS.log holds the line once" \
  || bad "L1 hub ALERTS.log count: $(grep -cxF -- "$LINE" "$HUB/logs/ALERTS.log" 2>/dev/null)"
OUT=$(HUBAPPLY "$HUB")
[ "$(grep -cxF -- "$LINE" "$HUB/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok "L1 a second replay keeps it once ($OUT)" || bad "L1 the second replay doubled it"
RS=$(posts '.alertid == "ph-staleparent_fx_9" and .severity == "resolved"')
[ "$RS" = 1 ] && ok "L2 the cleared staleparent:fx:9 posts one resolved line" || bad "L2 resolved POSTs: $RS"
jq -e 'select(.alertid == "ph-staleparent_fx_9" and .resolved == true and (has("severity") | not))' "$HUB/beat.log" >/dev/null 2>&1 \
  && ok "L2 the hub replay beats resolved:true with alertid ph-staleparent_fx_9" || bad "L2 hub beats: $(cat "$HUB/beat.log" 2>/dev/null)"
grep -q 'RESOLVED staleparent:fx:9' "$HUB/logs/ALERTS.log" && ok "L2 the RESOLVED line is in the hub ALERTS.log" || bad "L2 no RESOLVED line on the hub"

# ============================================================================
echo "L3/L4: the tick cap and a failed post"
: > "$SRV/alert-posts.jsonl"
H3="$T/h3"; mkhub "$H3" || exit 1
for i in $(seq 1 23); do echo "stuckqueue:fx:k$i"; done >> "$H3/state/health-active.txt"
PUB "$H3" fx >/dev/null; M3="$T/m3"; FETCH "$M3" fx
mrun "$M3" fx ALERT_LINE_TICK_MAX=1
N3=$(posts 'true')
[ "$RC" = 0 ] && [ "$N3" = 26 ] && ok "L3 2 pages and 24 retractions are 26 POSTs past a cap of 1" \
  || bad "L3 rc=$RC POSTs=$N3: $(jq -r .alertid "$SRV/alert-posts.jsonl" | tr '\n' ' ')"
[ ! -s "$M3/logs/ALERTS.log" ] && ok "L3 0 bytes in the machine's ALERTS.log" || bad "L3 machine ALERTS.log: $(wc -c < "$M3/logs/ALERTS.log")"
touch "$SRV/alert-fail"
H4="$T/h4"; mkhub "$H4" || exit 1; PUB "$H4" fx >/dev/null; M4="$T/m4"; FETCH "$M4" fx
mrun "$M4" fx
[ "$RC" = 0 ] && ok "L4 the run exits 0 when every POST fails" || bad "L4 rc=$RC"
rm -f "$SRV/alert-fail"

# ============================================================================
echo "D1/D2/D3: the per-project dedup on a machine"
: > "$SRV/alert-posts.jsonl"
H5="$T/h5"; mkhub "$H5" || exit 1
jq --argjson t "$((NOW - 600))" '.["uncommented:fx:1"]=$t' "$H5/state/health-alerted.json" > "$T/x.json" && mv "$T/x.json" "$H5/state/health-alerted.json"
PUB "$H5" fx >/dev/null; M5="$T/m5"; FETCH "$M5" fx
mrun "$M5" fx
[ "$RC" = 0 ] && [ "$(posts '.alertid == "ph-uncommented_fx_1"')" = 0 ] && ok "D1 a 10-min-old fleet stamp suppresses the first page" \
  || bad "D1 rc=$RC POSTs=$(posts '.alertid == "ph-uncommented_fx_1"')"
AJ="$M5/state/pipeline-health/fx/alerted.json"
[ "$(jq -r '.["uncommented:fx:1"]' "$AJ" 2>/dev/null)" = "$((NOW - 600))" ] && ok "D1 the seed copied the fleet stamp" || bad "D1 alerted.json: $(cat "$AJ" 2>/dev/null)"
jq -e 'has("leadunqueued:o/fx#3")' "$AJ" >/dev/null 2>&1 && ok "D3 the seed takes leadunqueued:o/fx#3" || bad "D3 no leadunqueued:o/fx#3"
for k in stalepr:fx2 uncommented:fx2:3 leadunqueued:o/fx2#4 costcap:hub stalepr:fx:3; do
  jq -e --arg k "$k" 'has($k)' "$AJ" >/dev/null 2>&1 && bad "D3 the seed took $k" || ok "D3 the seed did not take $k"
done
[ "$(jq -r '.["uncommented:fx:1"] // 0' "$M5/state/health-alerted.json")" = "$((NOW - 600))" ] \
  && ok "D1 the fleet JSON on the machine is untouched" || bad "D1 the machine wrote state/health-alerted.json"
: > "$SRV/alert-posts.jsonl"
H6="$T/h6"; mkhub "$H6" || exit 1; PUB "$H6" fx >/dev/null; M6="$T/m6"; FETCH "$M6" fx
mrun "$M6" fx
FIRST=$(posts '.alertid == "ph-uncommented_fx_1"')
CKPT "$M6" fx; QUEUE fx 1 "$POSTED"; APPLY "$H6" fx; UNQUEUE fx
ST=$(jq -r '.["uncommented:fx:1"] // empty' "$H6/state/pipeline-health/fx/alerted.json" 2>/dev/null)
PUB "$H6" fx >/dev/null; M7="$T/m7"; FETCH "$M7" fx
mrun "$M7" fx
[ "$FIRST" = 1 ] && [ "$(posts '.alertid == "ph-uncommented_fx_1"')" = 1 ] && [ -n "$ST" ] \
  && ok "D2 the second machine run reads the first's stamp ($ST): one page in two runs ($APPLIED)" \
  || bad "D2 first=$FIRST total=$(posts '.alertid == "ph-uncommented_fx_1"') stamp=$ST apply=$APPLIED"
OLD=$(jq -nc --argjson n "$NOW" '{"stalepr:fx:5":($n - 9*86400), "stalepr:fx:6":($n - 60)}')
printf '%s\n' "$OLD" > "$M7/state/pipeline-health/fx/alerted.json"
mrun "$M7" fx
jq -e 'has("stalepr:fx:5") | not' "$M7/state/pipeline-health/fx/alerted.json" >/dev/null 2>&1 \
  && jq -e 'has("stalepr:fx:6")' "$M7/state/pipeline-health/fx/alerted.json" >/dev/null 2>&1 \
  && ok "D3 a write drops a 9-day-old stamp and keeps a fresh one" || bad "D3 alerted.json: $(cat "$M7/state/pipeline-health/fx/alerted.json")"

# ============================================================================
echo "R1: stale-parent from GitHub REST"
mkdir -p "$T/repos"; "$REALGIT" init -q "$T/repos/fx"; touch -d "@$((NOW - 86400))" "$T/repos/fx/.git/refs"
REFS0=$(stat -c %Y "$T/repos/fx/.git/refs")
H8="$T/h8"; mkhub "$H8" || exit 1
printf '[{"number":9,"base":{"ref":"main","repo":{"default_branch":"main"}},"html_url":"https://github.com/o/fx/pull/9"}]\n' > "$H8/sp-list.json"
C1=$(printf 'c%.0s' {1..40}); B1=$(printf 'b%.0s' {1..40}); P0=$(printf '0%.0s' {1..40})
printf '[{"sha":"%s","parents":[{"sha":"%s"}],"commit":{"message":"c1: child","committer":{"date":"2026-10-14T00:00:00Z"}}}]\n' "$C1" "$P0" > "$H8/sp-commits-9.json"
printf '[{"sha":"%s","parents":[{"sha":"%s"}],"commit":{"message":"b1: base","committer":{"date":"2026-10-14T01:00:00Z"}}}]\n' "$B1" "$P0" > "$H8/sp-base.json"
printf 'diff --git a/c.txt b/c.txt\nnew file mode 100644\nindex 0000000..1111111\n--- /dev/null\n+++ b/c.txt\n@@ -0,0 +1 @@\n+child\n' > "$H8/diff-$C1"
printf 'diff --git a/b.txt b/b.txt\nnew file mode 100644\nindex 0000000..2222222\n--- /dev/null\n+++ b/b.txt\n@@ -0,0 +1 @@\n+base\n' > "$H8/diff-$B1"
: > "$T/git.log"
XPATH="$T/gitshim:" HUBREPOS="$T/repos" envrun "$H8" LANE_RUN_ID=run-fixture-1 PL_LANE=pipeline-health PL_PROJECT=fx "$H8/bin/pipeline-health.sh" --project fx
[ "$RC" = 0 ] && ok "R1 the run exits 0" || bad "R1 rc=$RC err=$(tail -3 "$H8/err.txt")"
grep -qF "$T/repos" "$T/git.log" && bad "R1 git ran on \$HUB_REPOS: $(grep -cF "$T/repos" "$T/git.log") call(s)" || ok "R1 no git call names \$HUB_REPOS"
[ -z "$("$REALGIT" -C "$T/repos/fx" for-each-ref refs/ph-stale/ 2>/dev/null)" ] && [ "$(stat -c %Y "$T/repos/fx/.git/refs")" = "$REFS0" ] \
  && ok "R1 the hub clone's refs are untouched" || bad "R1 the hub clone's refs moved"
grep -qxF 'api repos/o/fx/pulls?state=open&per_page=100' "$H8/gh.calls" && grep -q 'api repos/o/fx/pulls/9/commits' "$H8/gh.calls" \
  && ok "R1 the PR list and the PR's commits came from REST" || bad "R1 gh calls: $(grep -c . "$H8/gh.calls")"
ND=$(grep -c 'application/vnd.github.diff' "$H8/gh.calls")
grep -qF "stale-parent rest fx: judged 1 PR(s), $ND diff(s) fetched, 0 cached" "$H8/logs/pipeline-health.log" \
  && ok "R1 the log line counts 1 PR and $ND diff fetch(es)" || bad "R1 log: $(grep 'stale-parent rest' "$H8/logs/pipeline-health.log")"
grep -qx 'staleparent:fx:9' "$H8/state/health-active.txt" && bad "R1 no stale commit, yet staleparent:fx:9 stays" || ok "R1 no stale commit: staleparent:fx:9 retracts"
H9="$T/h9"; mkhub "$H9" || exit 1; touch "$H9/splistfail"
HUBREPOS="$T/repos" envrun "$H9" LANE_RUN_ID=run-fixture-1 PL_LANE=pipeline-health PL_PROJECT=fx "$H9/bin/pipeline-health.sh" --project fx
grep -qx 'staleparent:fx:9' "$H9/state/health-active.txt" && ok "R1b a failed PR list carries staleparent:fx:9" \
  || bad "R1b ACTIVE: $(tr '\n' ' ' < "$H9/state/health-active.txt")"

# spfix <tree> <base-diff-text> — the R1 fixtures: PR 9 (child c1), base b1.
spfix() {
  cp "$H8/sp-list.json" "$H8/sp-commits-9.json" "$H8/sp-base.json" "$H8/diff-$C1" "$1/"
  printf '%s' "$2" > "$1/diff-$B1"
}
sprun() { HUBREPOS="$T/repos" envrun "$1" LANE_RUN_ID=run-fixture-1 PL_LANE=pipeline-health PL_PROJECT=fx "${@:2}" "$1/bin/pipeline-health.sh" --project fx; }
splog() { grep -F "stale-parent rest fx:" "$1/logs/pipeline-health.log"; }
: > "$SRV/alert-posts.jsonl"
H11="$T/h11"; mkhub "$H11" || exit 1; spfix "$H11" "$(cat "$H8/diff-$C1")"
sprun "$H11"
R2WANT='fx #9 stale-parent: carries 1 commit(s) already on main under another sha (cccccccc=bbbbbbbb "c1: child")'
[ "$RC" = 0 ] && [ "$(jq -c --arg w "$R2WANT" 'select(.alertid == "ph-staleparent_fx_9" and (.line | contains($w)))' "$SRV/alert-posts.jsonl" | grep -c .)" = 1 ] \
  && ok "R2 a child diff equal to a base diff under another sha pages staleparent:fx:9 once" \
  || bad "R2 rc=$RC POSTs: $(jq -c 'select(.alertid == "ph-staleparent_fx_9")' "$SRV/alert-posts.jsonl")"
grep -qx 'staleparent:fx:9' "$H11/state/health-active.txt" && ok "R2 staleparent:fx:9 stays active" || bad "R2 ACTIVE lost staleparent:fx:9"
grep -qP "^$B1\t[0-9a-f]{40}\t[0-9]+$" "$H11/state/pipeline-health/fx/patch-ids.tsv" 2>/dev/null \
  && ok "R2 the patch-id cache holds the base commit" || bad "R2 cache: $(cat "$H11/state/pipeline-health/fx/patch-ids.tsv" 2>/dev/null)"
H12="$T/h12"; mkhub "$H12" || exit 1; spfix "$H12" "$(cat "$H8/diff-$B1")"
echo staleparent:fx:10 >> "$H12/state/health-active.txt"
jq '. + [{number:10, base:{ref:"main", repo:{default_branch:"main"}}, html_url:"https://github.com/o/fx/pull/10"}]' "$H8/sp-list.json" > "$H12/sp-list.json"
cp "$H12/sp-commits-9.json" "$H12/sp-commits-10.json"
sprun "$H12" STALE_PARENT_REST_DIFF_MAX=1
grep -qF 'stale-parent rest fx: diff budget spent, 2 PR(s) left for next tick' <<<"$(splog "$H12")" \
  && grep -qF 'stale-parent rest fx: judged 0 PR(s), 1 diff(s) fetched, 0 cached' <<<"$(splog "$H12")" \
  && ok "R3 a budget of 1 diff judges no PR and names the 2 left" || bad "R3 log: $(splog "$H12")"
grep -qx 'staleparent:fx:9' "$H12/state/health-active.txt" && grep -qx 'staleparent:fx:10' "$H12/state/health-active.txt" \
  && ok "R3 both unjudged PRs keep their keys" || bad "R3 ACTIVE: $(tr '\n' ' ' < "$H12/state/health-active.txt")"
grep -q "^$B1"$'\t' "$H12/state/pipeline-health/fx/patch-ids.tsv" 2>/dev/null && ok "R3 the one diff it read is cached for the next tick" \
  || bad "R3 no cache row for the base commit"
H13="$T/h13"; mkhub "$H13" || exit 1; spfix "$H13" "$(cat "$H8/diff-$B1")"
jq -c '[range(100) as $i | .[0] | .sha = ("b" + ($i | tostring | ("000" + .)[-3:]) + (.sha[4:]))]' "$H8/sp-base.json" > "$H13/sp-base.json"
sprun "$H13"
grep -qF 'stale-parent rest fx: the main commit list is past 3 pages, project carried' <<<"$(splog "$H13")" \
  && grep -qx 'staleparent:fx:9' "$H13/state/health-active.txt" && ok "R4 a base list past 3 pages carries the project" \
  || bad "R4 log: $(splog "$H13") ACTIVE: $(tr '\n' ' ' < "$H13/state/health-active.txt")"
H14="$T/h14"; mkhub "$H14" || exit 1; spfix "$H14" "$(cat "$H8/diff-$B1")"; rm -f "$H14/sp-commits-9.json"
sprun "$H14"
grep -qF 'stale-parent rest fx: judged 0 PR(s), 0 diff(s) fetched, 0 cached' <<<"$(splog "$H14")" \
  && grep -qx 'staleparent:fx:9' "$H14/state/health-active.txt" && ok "R5 an unreadable PR commit list carries staleparent:fx:9" \
  || bad "R5 log: $(splog "$H14") ACTIVE: $(tr '\n' ' ' < "$H14/state/health-active.txt")"

# ============================================================================
echo "C2/C3: one lock for every writer of state/closeout-aged-out.tsv"
H10="$T/h10"; mkhub "$H10" || exit 1
# The holder keeps the lock 2 s. File mtimes come from a coarse kernel clock,
# so the check is "written at least 1.5 s after the holder took the lock".
( exec 9>"$H10/state/closeout-aged-out.tsv.lock"; flock 9; date +%s%N > "$T/c2.held.tmp"; mv "$T/c2.held.tmp" "$T/c2.held"; sleep 2 ) &
HOLDER=$!
n=0; until [ -e "$T/c2.held" ] || [ "$n" -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
envrun "$H10" "$H10/bin/pipeline-health.sh" --project fx
wait "$HOLDER"
WR=$(date -r "$H10/state/closeout-aged-out.tsv" +%s%N 2>/dev/null)
HELD=$(cat "$T/c2.held")
grep -q $'^fx\tfx-BH-1' "$H10/state/closeout-aged-out.tsv" && [ "$(( (${WR:-0} - HELD) / 1000000 ))" -ge 1500 ] \
  && ok "C2 the aged-out row waits for the tsv lock ($(( (WR - HELD) / 1000000 )) ms after it was taken)" \
  || bad "C2 the row was written $(( (${WR:-0} - HELD) / 1000000 )) ms after the holder took the lock"
C3="$T/c3"; mkdir -p "$C3/bin/lib" "$C3/env" "$C3/logs" "$C3/state" "$C3/locks" "$C3/flags" "$C3/builds"
scratch_install_closure bin/disk-clean.sh "$C3" >/dev/null
printf 'small\n' > "$C3/state/box-id"; : > "$C3/env/global.env"
printf 'p1\tp1-BH-1-202001010000\tx\ty\np1\tp1-BH-1-202001010000\tx\ty\n' > "$C3/state/closeout-aged-out.tsv"
cp "$C3/state/closeout-aged-out.tsv" "$T/c3.before"
exec 8>"$C3/state/closeout-aged-out.tsv.lock"; flock -n 8
env HARNESS_ROOT="$C3" ETC_HARNESS_ENV="$T/no-such-etc" DISK_CLEAN_REPOS="$T/no-repos" DISK_CLEAN_NPM_DIR="$T/no-npm" \
  DISK_CLEAN_NOW="$NOW" bash "$C3/bin/disk-clean.sh" > "$T/c3.out" 2>&1; rc=$?
exec 8>&-
[ "$rc" = 0 ] && cmp -s "$T/c3.before" "$C3/state/closeout-aged-out.tsv" && grep -q 'tsv prune skipped: lock held' "$C3/logs/disk-clean.log" 2>/dev/null \
  && ok "C3 disk-clean skips the prune while the tsv lock is held" || bad "C3 rc=$rc log: $(cat "$C3/logs/disk-clean.log" 2>/dev/null)"

# ============================================================================
echo "N1/N2/N3: the hub path is unchanged when LANE_RUN_ID is unset or empty"
: > "$SRV/alert-posts.jsonl"
for c in N1 N2 N3; do
  HN="$T/hn-$c"; mkhub "$HN" || exit 1
  case "$c" in
    N1) envrun "$HN" "$HN/bin/pipeline-health.sh" --project fx ;;
    N2) envrun "$HN" "$HN/bin/pipeline-health.sh" ;;
    N3) envrun "$HN" LANE_RUN_ID= "$HN/bin/pipeline-health.sh" --project fx ;;
  esac
  [ "$RC" = 0 ] && [ -s "$HN/state/health-active.stamp" ] && ok "$c rc 0 and state/health-active.stamp written" || bad "$c rc=$RC stamp missing"
  jq -e '.["uncommented:fx:1"] > 0' "$HN/state/health-alerted.json" >/dev/null 2>&1 && ok "$c state/health-alerted.json is the dedup file" \
    || bad "$c health-alerted.json: $(cat "$HN/state/health-alerted.json")"
  [ ! -e "$HN/state/pipeline-health/fx/alerted.json" ] && ok "$c no per-project dedup file" || bad "$c wrote the per-project dedup file"
  grep -q '"kind":"fleet_alert".*health:uncommented:fx:1' "$HN/beat.log" 2>/dev/null && ok "$c beat.sh got the fleet_alert call" || bad "$c no fleet_alert beat"
  grep -qF 'RESOLVED staleparent:fx:9' "$HN/logs/ALERTS.log" 2>/dev/null && ok "$c the RESOLVED line is a local ALERTS.log line" || bad "$c no local RESOLVED line"
done
[ "$(posts 'true')" = 0 ] && ok "N1-N3 no POST to /api/alert-lines" || bad "N1-N3 POSTs: $(posts 'true')"

# ============================================================================
echo "P1: the placement row"
FR=$(grep -l "lane_placement.pipeline-health" "$REPO"/worker/jobs/schema.d/*.sql 2>/dev/null)
grep -q "'lane_placement.pipeline-health','hub'" "$REPO"/worker/jobs/schema.d/*-bh-6892-*.sql 2>/dev/null \
  && ok "P1 the BH-6892 fragment seeds hub" || bad "P1 no BH-6892 fragment seeding hub"
[ -n "$FR" ] && ! grep -q "'fly'" <<<"$(grep -h "lane_placement.pipeline-health" $FR)" \
  && ok "P1 no fragment seeds lane_placement.pipeline-health fly" || bad "P1 fragments: ${FR:-none}"

echo
echo "pipeline-health-offhub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
