#!/bin/bash
# tests/lane-run-inputs-manifest.bh-6719-test.sh — BH-6719 (BH-6047.6): the
# lane-run input allow-list lives in one manifest pair per lane,
# catalog/lane-run-inputs.d/<lane>.rw and <lane>.ro, and
# bin/lib/lane-run-inputs.sh reads them. No lane's list is in the lib.
#
#   M1  lri_paths blocked-resolver demo ro|rw prints what main printed
#   M1b _lri_list over a fixture tree lists what main listed (ro and rw), and
#       the blocked-resolver snapshot carries the same members
#   M2  lri_paths pipeline-health demo ro|rw holds the project's inputs
#   M3  a pipeline-health snapshot holds demo's files and demo's log lines only
#   M4  a pipeline-health write-back outside .rw is rejected, inside is applied
#   M5  a lane with no manifest: nothing printed, published or fetched
#   M6  a malformed manifest is an error, never "no inputs"; every committed
#       manifest parses; a new lane works with no code edit
#   M7  the lri_member_ok accept and refuse table, lane by argument and by
#       LRI_LANE
#
# The jobs client is a function stub that records each request, so no worker
# runs. The BH-6128 suite drives the same lib through the real worker.
#
# Run from anywhere: tests/lane-run-inputs-manifest.bh-6719-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="${LRI_LIB:-$REPO/bin/lib/lane-run-inputs.sh}"
MANI="$REPO/catalog/lane-run-inputs.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
# ONE clock read: every fixture mtime is derived from it.
NOW=$(date -u +%s)

# The jobs client, stubbed. Every request is one line in $T/req.log. A PUT or
# a POST body is kept as $T/body.<n>. GET <api> answers 404 (no current
# snapshot); GET <api>/writebacks answers $T/wblist.json; GET
# <api>/writebacks/<id> answers $T/wb-<id>.json.
export JOBS_HTTP=200
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/req.log"
  case "$1 $2" in
    "GET "*/writebacks) cat "$T/wblist.json" 2>/dev/null || echo '{"writebacks":[]}' ;;
    "GET "*/writebacks/*) cat "$T/wb-${2##*/}.json" ;;
    "GET "*) return 2 ;;
    *) printf '%s' "${3:-}" > "$T/body.$(wc -l < "$T/req.log")"; echo '{"id":1}' ;;
  esac
}
_jobs_req_file() {
  printf '%s %s\n' "$1" "$2" >> "$T/req.log"
  cp "$3" "$T/body.$(wc -l < "$T/req.log")"; echo '{"id":1}'
}
setting_get() { return 1; }
_jobs_box_name() { echo fixture-box; }
# L <root> <cmd...> — one call of the lib in a subshell rooted at <root>.
L() { local r="$1"; shift; ( export HARNESS="$r"; . "$LIB" || exit 99; "$@" ); }
# PUTS — the number of PUT requests logged so far.
PUTS() { grep -c '^PUT ' "$T/req.log" 2>/dev/null; }
# SNAP <out.tgz> — the snapshot the last publish PUT, reassembled.
SNAP() { local f; : > "$1"
  for f in $(grep -n '^PUT ' "$T/req.log" | cut -d: -f1); do jq -j .b64 "$T/body.$f" | base64 -d >> "$1"; done; }
: > "$T/req.log"

# FIX <root> — the fixture tree: three record prefixes, an aged record dir,
# prefix decoys, an oversized review.md, an oversized pr-state.tsv, nested
# and symlinked decoys.
FIX() {
  local r="$1" d
  mkdir -p "$r"/builds/{demo-BH-1-a,pool-demo-BH-2,fly-demo-BH-3-z/sub,demo-BH-9-old,demo-os-TK-1-x,demo10-BH-1-x,demo-bh-1-x,other-BH-2-x} \
           "$r"/state/blocked-resolver/{demo/sub,other,rounds,unmapped/n,unmapped-family,handoffs/a} \
           "$r"/state/{build-notes/demo,build-queue/demo,build-queue/other,merge-conductor,pipeline-health/demo} \
           "$r"/plans/{demo-BH-1/x,other-BH-1} "$r"/flags/sub "$r"/logs || return 1
  for d in builds/demo-BH-1-a/RESULT builds/demo-BH-1-a/plan.md builds/demo-BH-1-a/transcript.txt \
           builds/pool-demo-BH-2/job.json builds/pool-demo-BH-2/.blocked-resolver-held \
           builds/fly-demo-BH-3-z/COMMENTED builds/fly-demo-BH-3-z/sub/RESULT builds/demo-BH-9-old/RESULT \
           builds/demo-os-TK-1-x/RESULT builds/demo10-BH-1-x/RESULT builds/demo-bh-1-x/RESULT builds/other-BH-2-x/RESULT \
           state/blocked-resolver/demo/a.json state/blocked-resolver/demo/sub/b.json state/blocked-resolver/other/x.json \
           state/blocked-resolver/rounds/demo-o-1.json state/blocked-resolver/rounds/other-o-1.json \
           state/blocked-resolver/.tick-budget-demo state/blocked-resolver/.tick-budget-other \
           state/blocked-resolver/.saturation-demo.tsv state/blocked-resolver/unmapped/m1 state/blocked-resolver/unmapped/n/m2 \
           state/blocked-resolver/handoffs/a/h.json state/build-notes/demo/BH-1.md \
           state/build-queue/demo/BH-1.json state/build-queue/demo/BH-1.txt state/build-queue/other/BH-2.json \
           state/pipeline-health/demo/closeout-aged.tsv plans/demo-BH-1/planned-files.txt \
           plans/demo-BH-1/x/planned-files.txt plans/other-BH-1/planned-files.txt \
           flags/automerge-disabled flags/sub/x fleet.conf; do
    printf '%s\n' "$d" > "$r/$d"
  done
  printf 'demo\t%s\nother\t%s\n' "$((NOW - 60))" "$((NOW - 90))" > "$r/state/blocked-resolver/.last-visited.tsv"
  head -c 300000 /dev/zero | tr '\0' x > "$r/builds/demo-BH-1-a/review.md"
  head -c 300000 /dev/zero | tr '\0' y > "$r/state/merge-conductor/pr-state.tsv"
  ln -s ../fleet.conf "$r/flags/link"
  printf '%s\n' "2026-10-14 merge-conductor: o#1 handed to bin/blocked-resolver.sh" "2026-10-14 merge-conductor: o#2 merged" \
    > "$r/logs/merge-conductor.log"
  printf '%s\n' "2026-10-14T00:00:00Z [pool/demo] reaped BH-1" "2026-10-14T00:00:01Z [pool/other] reaped BH-2" \
    "2026-10-14T00:00:02Z [pool/demo10] reaped BH-3" > "$r/logs/fly-pool.log"
  find "$r" -mindepth 1 -exec touch -h -d "@$((NOW - 86400))" {} +
  touch -d "@$((NOW - 40 * 86400))" "$r/builds/demo-BH-9-old"
}

# ============================================================================
echo "M1: lri_paths blocked-resolver prints main's list"
GOLDEN_RO=$(sed -n '/^GOLDEN_RO$/,/^GOLDEN_RO_END$/p' "$0" | sed '1d;$d')
OUT=$(L "$T/none" lri_paths blocked-resolver demo ro); rc=$?
[ "$rc" = 0 ] && [ "$OUT" = "$GOLDEN_RO" ] && ok "M1 ro equals the 22-line golden" \
  || bad "M1 ro rc=$rc: $(diff <(printf '%s\n' "$GOLDEN_RO") <(printf '%s\n' "$OUT"))"
OUT=$(L "$T/none" lri_paths blocked-resolver demo rw); rc=$?
[ "$rc" = 0 ] && [ "$OUT" = "$(head -n 15 <<<"$GOLDEN_RO")" ] && ok "M1 rw equals the first 15 lines" \
  || bad "M1 rw rc=$rc: $OUT"

# ============================================================================
echo "M1b: _lri_list and the blocked-resolver snapshot over a fixture tree"
B="$T/b"; FIX "$B" || exit 1
GOLDEN_LIST_RO=$(sed -n '/^GOLDEN_LIST_RO$/,/^GOLDEN_LIST_RO_END$/p' "$0" | sed '1d;$d')
GOLDEN_LIST_RW=$(sed -n '/^GOLDEN_LIST_RW$/,/^GOLDEN_LIST_RW_END$/p' "$0" | sed '1d;$d')
OUT=$(L "$B" _lri_list demo ro 30 | tr '\t' ' ')
[ "$OUT" = "$GOLDEN_LIST_RO" ] && ok "M1b _lri_list demo ro 30 equals main's" \
  || bad "M1b ro: $(diff <(printf '%s\n' "$GOLDEN_LIST_RO") <(printf '%s\n' "$OUT"))"
OUT=$(L "$B" _lri_list demo rw 0 | tr '\t' ' ')
[ "$OUT" = "$GOLDEN_LIST_RW" ] && ok "M1b _lri_list demo rw 0 equals main's" \
  || bad "M1b rw: $(diff <(printf '%s\n' "$GOLDEN_LIST_RW") <(printf '%s\n' "$OUT"))"
: > "$T/req.log"
OUT=$(L "$B" lri_publish blocked-resolver demo); rc=$?
SNAP "$T/br.tgz"
GOLDEN_SNAP=$( (printf '%s\n' "$GOLDEN_LIST_RO" | cut -d' ' -f2; echo logs/merge-conductor.log) | LC_ALL=C sort)
[ "$rc" = 0 ] && [ "$(tar -tzf "$T/br.tgz" 2>/dev/null | sed 's#/$##' | LC_ALL=C sort)" = "$GOLDEN_SNAP" ] \
  && ok "M1b the blocked-resolver snapshot holds the listed files plus the conductor log" \
  || bad "M1b snapshot rc=$rc out=$OUT: $(tar -tzf "$T/br.tgz" 2>&1)"
[ "$(tar -xzOf "$T/br.tgz" logs/merge-conductor.log 2>/dev/null)" = "2026-10-14 merge-conductor: o#1 handed to bin/blocked-resolver.sh" ] \
  && ok "M1b the conductor log rides as its hand-off line only" || bad "M1b conductor log: $(tar -xzOf "$T/br.tgz" logs/merge-conductor.log 2>&1)"

# ============================================================================
echo "M2: lri_paths pipeline-health"
OUT=$(L "$T/none" lri_paths pipeline-health demo ro); rc=$?
[ "$rc" = 0 ] && [ -n "$OUT" ] && ok "M2 ro is non-empty" || bad "M2 ro rc=$rc empty"
for want in 'state/build-queue/demo/*.json' "logs/fly-pool.log (this project's pool lines only)" 'builds/demo-<KEY>-*/<record file>' 'flags/*' 'fleet.conf'; do
  grep -qxF -- "$want" <<<"$OUT" && ok "M2 ro holds $want" || bad "M2 ro lacks $want"
done
OUT=$(L "$T/none" lri_paths pipeline-health demo rw); rc=$?
grep -qxF 'state/pipeline-health/demo/*' <<<"$OUT" && ok "M2 rw holds state/pipeline-health/demo/*" || bad "M2 rw: $OUT"
for no in 'flags/*' 'fleet.conf' 'state/health-active.txt'; do
  grep -qxF -- "$no" <<<"$OUT" && bad "M2 rw holds $no" || ok "M2 rw does not hold $no"
done

# ============================================================================
echo "M3: the pipeline-health snapshot is the project's only"
P="$T/p"; FIX "$P" || exit 1
mkdir -p "$P/builds/demo-BH-1-x" "$P/builds/other-BH-2-y" "$P/state/remote-results/demo"
echo r > "$P/builds/demo-BH-1-x/RESULT"; echo r > "$P/builds/other-BH-2-y/RESULT"
echo '{}' > "$P/state/remote-results/demo/BH-1.json"
printf '%s\n' "2026-10-14T00:00:00Z demo rc=0 :: BH-1" "2026-10-14T00:00:01Z demo something else" > "$P/logs/demo.log"
: > "$T/req.log"
OUT=$(L "$P" lri_publish pipeline-health demo); rc=$?
SNAP "$T/ph.tgz"
MEM=$(tar -tzf "$T/ph.tgz" 2>/dev/null)
[ "$rc" = 0 ] && [ "$(PUTS)" -ge 1 ] && ok "M3 published ($OUT)" || bad "M3 publish rc=$rc puts=$(PUTS) out=$OUT"
for want in builds/demo-BH-1-x/RESULT state/build-queue/demo/BH-1.json state/remote-results/demo/BH-1.json \
            logs/fly-pool.log logs/demo.log flags/automerge-disabled fleet.conf; do
  grep -qxF "$want" <<<"$MEM" && ok "M3 holds $want" || bad "M3 lacks $want"
done
grep -q other <<<"$MEM" && bad "M3 holds another project's path: $(grep other <<<"$MEM")" || ok "M3 holds no path of project other"
grep -qx 'builds/demo10-BH-1-x/RESULT' <<<"$MEM" && bad "M3 holds demo10's record" || ok "M3 holds no record of demo10"
FP=$(tar -xzOf "$T/ph.tgz" logs/fly-pool.log 2>/dev/null)
[ "$FP" = "2026-10-14T00:00:00Z [pool/demo] reaped BH-1" ] && ok "M3 logs/fly-pool.log holds demo's pool line only" || bad "M3 fly-pool.log: $FP"
[ "$(tar -xzOf "$T/ph.tgz" logs/demo.log 2>/dev/null)" = "2026-10-14T00:00:00Z demo rc=0 :: BH-1" ] \
  && ok "M3 logs/demo.log holds the run-result line only" || bad "M3 demo.log: $(tar -xzOf "$T/ph.tgz" logs/demo.log 2>&1)"

# ============================================================================
echo "M4: a pipeline-health write-back is checked against .rw"
# WB <dir> <id> <relpath...> — a write-back tgz of <relpath>s (absent base),
# served as write-back <id>.
WB() { local w="$1" id="$2" rel; shift 2
  mkdir -p "$w/.lri"; : > "$w/.lri/base.tsv"; : > "$w/.lri/deletions"
  for rel in "$@"; do mkdir -p "$w/$(dirname "$rel")"; echo machine > "$w/$rel"; printf '%s\t-\n' "$rel" >> "$w/.lri/base.tsv"; done
  tar --owner=0 --group=0 --numeric-owner --format=gnu -czf "$w.tgz" -C "$w" "$@" .lri/base.tsv .lri/deletions || return 1
  jq -n --rawfile b <(base64 -w0 "$w.tgz") '{b64:$b}' > "$T/wb-$id.json"
  jq -n --argjson i "$id" --arg s "$(sha256sum "$w.tgz" | cut -d' ' -f1)" '{writebacks:[{id:$i, sha:$s}]}' > "$T/wblist.json"
}
H4="$T/h4"; mkdir -p "$H4/state"; echo hub > "$H4/state/health-active.txt"
WB "$T/wb1" 1 state/health-active.txt || exit 1
( export HARNESS="$H4"; . "$LIB" || exit 99; LRI_LANE=pipeline-health _lri_validate demo "$T/wb1.tgz" writeback ) \
  && bad "M4 _lri_validate accepted state/health-active.txt" || ok "M4 _lri_validate refuses state/health-active.txt"
AP=$(L "$H4" lri_apply_pending pipeline-health demo); rc=$?
[ "$AP" = "applied=0 conflicts=0 rejected=1" ] && ok "M4 apply: $AP" || bad "M4 apply rc=$rc: $AP"
[ "$(cat "$H4/state/health-active.txt")" = hub ] && ok "M4 the hub state/health-active.txt is unchanged" || bad "M4 health-active.txt changed"
WB "$T/wb2" 2 state/pipeline-health/demo/closeout-aged.tsv || exit 1
AP=$(L "$H4" lri_apply_pending pipeline-health demo); rc=$?
[ "$rc" = 0 ] && [ "$AP" = "applied=1 conflicts=0 rejected=0" ] && ok "M4 apply: $AP" || bad "M4 apply rc=$rc: $AP"
[ "$(cat "$H4/state/pipeline-health/demo/closeout-aged.tsv" 2>/dev/null)" = machine ] && ok "M4 closeout-aged.tsv is applied" || bad "M4 closeout-aged.tsv not applied"
rm -f "$T/wblist.json"

# ============================================================================
echo "M5: a lane with no manifest has no inputs"
: > "$T/req.log"
OUT=$(L "$P" lri_paths nolane demo ro 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$OUT" ] && ok "M5 lri_paths prints nothing, rc 0" || bad "M5 lri_paths rc=$rc: $OUT"
L "$P" lri_publish nolane demo >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(PUTS)" = 0 ] && ok "M5 lri_publish rc 1, no PUT" || bad "M5 publish rc=$rc puts=$(PUTS)"
E5="$T/e5"; mkdir -p "$E5"
L "$E5" lri_fetch nolane demo x >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ -z "$(ls -A "$E5")" ] && [ ! -s "$T/req.log" ] && ok "M5 lri_fetch rc 0, nothing written, no request" \
  || bad "M5 fetch rc=$rc: $(ls -A "$E5") $(cat "$T/req.log")"

# ============================================================================
echo "M6: a malformed manifest is an error"
# BADM <name> <rw text> [ro text] — a manifest dir with lane `bad`.
BADM() { mkdir -p "$T/m-$1"; printf '%s\n' "$2" > "$T/m-$1/bad.rw"; [ -z "${3:-}" ] || printf '%s\n' "$3" > "$T/m-$1/bad.ro"; }
BADM token 'state/x/$p/<nope>'
BADM linesrw $'state/x/$p/*\n@lines logs/x.log foo'
BADM midstar 'state/**/x/$p'
BADM row2 $'state/x/$p/*\nstate/x/v.tsv\n@row state/x/v.tsv lk\n@row state/x/v.tsv lk2'
BADM unknown $'state/x/$p/*\n@frob a'
BADM abs '/etc/$p'
BADM dotdot 'state/../$p/*'
BADM linesnot 'state/x/$p/*' '@lines logs/x.log foo'
BADM rownot $'state/x/$p/*\n@row state/x/v.tsv lk'
BADM rowro 'state/x/$p/*' $'state/x/v.tsv\n@row state/x/v.tsv lk'
X6="$T/x6"; mkdir -p "$X6/state/x/demo"; echo keep > "$X6/state/x/demo/f"
for c in token linesrw midstar row2 unknown abs dotdot linesnot rownot rowro; do
  ERR=$( (export LRI_MANIFEST_DIR="$T/m-$c"; L "$X6" lri_paths bad demo ro) 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && [[ $ERR == "lri: $T/m-$c/bad."* ]] && [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] \
    && ok "M6a $c: lri_paths rc 1 ($ERR)" || bad "M6a $c: lri_paths rc=$rc err=$ERR"
done
export LRI_MANIFEST_DIR="$T/m-token"
: > "$T/req.log"
L "$X6" lri_publish bad demo >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(PUTS)" = 0 ] && ok "M6a lri_publish rc 1, no PUT" || bad "M6a publish rc=$rc puts=$(PUTS)"
L "$X6" lri_fetch bad demo x >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(cat "$X6/state/x/demo/f")" = keep ] && [ ! -e "$X6/state/lane-run-inputs" ] \
  && ok "M6a lri_fetch rc 2, overlay unchanged" || bad "M6a fetch rc=$rc"
LANE_RUN_ID=1 L "$X6" lri_checkpoint bad demo >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "M6a lri_checkpoint rc 1" || bad "M6a checkpoint rc=$rc"
L "$X6" lri_apply_pending bad demo >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(PUTS)" = 0 ] && ! grep -q '^POST ' "$T/req.log" && ok "M6a lri_apply_pending rc 1, no request" || bad "M6a apply rc=$rc"
L "$X6" lri_member_ok demo state/x/demo/f - rw bad && bad "M6a lri_member_ok accepted under a bad manifest" || ok "M6a lri_member_ok refuses every member"
unset LRI_MANIFEST_DIR

N6=0
for f in "$MANI"/*.rw "$MANI"/*.ro; do
  [ -f "$f" ] || continue
  lane=$(basename "$f"); lane="${lane%.*}"; N6=$((N6 + 1))
  OUT=$(L "$T/none" lri_paths "$lane" demo ro 2>&1); rc=$?
  [ "$rc" = 0 ] && [ -n "$OUT" ] && ok "M6b $(basename "$f") parses" || bad "M6b $(basename "$f") rc=$rc: $OUT"
done
[ "$N6" -ge 4 ] && ok "M6b $N6 committed manifest files checked" || bad "M6b only $N6 manifest files found in $MANI"

mkdir -p "$T/m-zz"; printf '%s\n' 'state/zz/$p/*' > "$T/m-zz/zz.rw"
export LRI_MANIFEST_DIR="$T/m-zz"
Z="$T/z"; mkdir -p "$Z/state/zz/demo" "$Z/state/zz/other"; echo a > "$Z/state/zz/demo/a"; echo b > "$Z/state/zz/other/b"
[ "$(L "$Z" lri_paths zz demo rw)" = 'state/zz/demo/*' ] && ok "M6c lri_paths zz" || bad "M6c lri_paths zz: $(L "$Z" lri_paths zz demo rw 2>&1)"
L "$Z" lri_member_ok demo state/zz/demo/a - rw zz && ok "M6c member ok" || bad "M6c member refused"
L "$Z" lri_member_ok demo state/zz/other/b - rw zz && bad "M6c other project's member accepted" || ok "M6c other project's member refused"
: > "$T/req.log"
L "$Z" lri_publish zz demo >/dev/null 2>&1; rc=$?
SNAP "$T/zz.tgz"
[ "$rc" = 0 ] && [ "$(tar -tzf "$T/zz.tgz" 2>/dev/null)" = state/zz/demo/a ] && ok "M6c lri_publish zz carries state/zz/demo/a only" \
  || bad "M6c publish rc=$rc: $(tar -tzf "$T/zz.tgz" 2>&1)"
unset LRI_MANIFEST_DIR

# ============================================================================
echo "M7: the lri_member_ok accept and refuse table"
# lane project relpath type mode want
while read -r lane p rel type mode want; do
  [ -n "$lane" ] || continue
  ( export HARNESS="$T/none"; . "$LIB" || exit 99; lri_member_ok "$p" "$rel" "$type" "$mode" "$lane" ); a=$?
  ( export HARNESS="$T/none"; . "$LIB" || exit 99; LRI_LANE="$lane" lri_member_ok "$p" "$rel" "$type" "$mode" ); b=$?
  [ "$want" = accept ] && w=0 || w=1
  [ "$a" = "$w" ] && [ "$b" = "$w" ] && ok "M7 $want $lane $p $rel $type $mode" || bad "M7 want $want $lane $p $rel $type $mode: arg rc=$a LRI_LANE rc=$b"
done <<'EOF'
blocked-resolver p1 state/blocked-resolver/p1/a/b.json - rw accept
blocked-resolver p1 builds/p1-BH-1 d rw accept
blocked-resolver p1 builds/pool-p1-BH-7-x/.blocked-resolver-held - rw accept
blocked-resolver p1 plans/p1-x/planned-files.txt - ro accept
blocked-resolver p1 state/blocked-resolver/.last-visited.tsv - rw accept
pipeline-health demo state/pipeline-health/demo/closeout-aged.tsv - rw accept
pipeline-health demo builds/demo-BH-1-x/RESULT - ro accept
pipeline-health demo builds/demo-BH-1-x d ro accept
pipeline-health demo logs/fly-pool.log - ro accept
blocked-resolver project-4 builds/project-4-TK-1-x/RESULT - ro refuse
blocked-resolver p1 builds/p10-BH-1-x/RESULT - ro refuse
blocked-resolver p1 plans/p1-x/y/planned-files.txt - ro refuse
blocked-resolver p1 flags/x - rw refuse
blocked-resolver p1 state/blocked-resolver/p1/x.json l rw refuse
blocked-resolver p1 ../x - ro refuse
blocked-resolver p1 state/blocked-resolver/p1/../../x - rw refuse
pipeline-health demo state/health-active.txt - rw refuse
pipeline-health demo builds/demo-BH-1-x/transcript.txt - ro refuse
pipeline-health demo builds/demo-BH-1-x/RESULT - rw refuse
pipeline-health demo logs/fly-pool.log - rw refuse
pipeline-health demo fleet.conf - rw refuse
pipeline-health demo state/blocked-resolver/demo/a.json - ro refuse
blocked-resolver demo state/pipeline-health/demo/closeout-aged.tsv - ro refuse
EOF

echo
echo "lane-run-inputs-manifest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
exit 0

# The goldens below were captured from origin/main's bin/lib/lane-run-inputs.sh
# (908ec1f7) before the manifests existed: GOLDEN_RO is
# `lri_paths blocked-resolver demo ro`; GOLDEN_LIST_* are `_lri_list demo ro 30`
# and `_lri_list demo rw 0` over FIX, with the TAB shown as a space.
: <<'GOLDENS'
GOLDEN_RO
state/blocked-resolver/demo/**
state/blocked-resolver/rounds/demo-*
state/blocked-resolver/.tick-budget-demo
state/blocked-resolver/.saturation-demo.tsv
state/blocked-resolver/.saturated-project-demo
state/blocked-resolver/.untouched-demo
state/blocked-resolver/unmapped/*
state/blocked-resolver/unmapped-family/*
state/blocked-resolver/handoffs/**
state/blocked-resolver/.last-visited.tsv
builds/demo-<KEY>-*/<record file>
builds/pool-demo-<KEY>-*/<record file>
builds/fly-demo-<KEY>-*/<record file>
state/build-notes/demo/*
state/pool/demo/*.terminal-noted
state/build-queue/demo/*.json
state/merge-conductor/pr-state.tsv
logs/merge-conductor.log (hand-off lines only)
plans/demo-*/planned-files.txt
flags/*
fleet.conf
state/pool/demo/*.terminal
GOLDEN_RO_END
GOLDEN_LIST_RO
d builds/demo-BH-1-a
- builds/demo-BH-1-a/RESULT
- builds/demo-BH-1-a/plan.md
d builds/fly-demo-BH-3-z
- builds/fly-demo-BH-3-z/COMMENTED
d builds/pool-demo-BH-2
- builds/pool-demo-BH-2/.blocked-resolver-held
- builds/pool-demo-BH-2/job.json
- flags/automerge-disabled
- fleet.conf
- plans/demo-BH-1/planned-files.txt
- state/blocked-resolver/.last-visited.tsv
- state/blocked-resolver/.saturation-demo.tsv
- state/blocked-resolver/.tick-budget-demo
- state/blocked-resolver/demo/a.json
- state/blocked-resolver/demo/sub/b.json
- state/blocked-resolver/handoffs/a/h.json
- state/blocked-resolver/rounds/demo-o-1.json
- state/blocked-resolver/unmapped/m1
- state/build-notes/demo/BH-1.md
- state/build-queue/demo/BH-1.json
- state/merge-conductor/pr-state.tsv
GOLDEN_LIST_RO_END
GOLDEN_LIST_RW
d builds/demo-BH-1-a
- builds/demo-BH-1-a/RESULT
- builds/demo-BH-1-a/plan.md
d builds/demo-BH-9-old
- builds/demo-BH-9-old/RESULT
d builds/fly-demo-BH-3-z
- builds/fly-demo-BH-3-z/COMMENTED
d builds/pool-demo-BH-2
- builds/pool-demo-BH-2/.blocked-resolver-held
- builds/pool-demo-BH-2/job.json
- state/blocked-resolver/.last-visited.tsv
- state/blocked-resolver/.saturation-demo.tsv
- state/blocked-resolver/.tick-budget-demo
- state/blocked-resolver/demo/a.json
- state/blocked-resolver/demo/sub/b.json
- state/blocked-resolver/handoffs/a/h.json
- state/blocked-resolver/rounds/demo-o-1.json
- state/blocked-resolver/unmapped/m1
- state/build-notes/demo/BH-1.md
GOLDEN_LIST_RW_END
GOLDENS
