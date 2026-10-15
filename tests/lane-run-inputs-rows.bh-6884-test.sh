#!/bin/bash
# tests/lane-run-inputs-rows.bh-6884-test.sh — BH-6884 (BH-6881.2): the
# `@rows <path> <ERE>` manifest directive of bin/lib/lane-run-inputs.sh. A
# fleet-wide TSV rides to a lane machine and back as ONE project's lines.
#
#   R1  the snapshot carries only the project's lines (mixed case in, the
#       longer repo's `Demo-Console` rows out)
#   R2  demo and other write-backs both apply; other lines stay in place
#   R3  a hub edit to a demo line after the fetch is a conflict, file kept
#   R4  a write-back line that is not the project's is rejected, file kept
#   R5  a malformed @rows is one `lri:` line and rc 1, per reason
#   R6  a re-apply (lost ack) is a no-op, not a conflict
#   R7  a hub edit to another project's line is not a conflict
#   R8  no hub file: an empty member, and the apply creates the file; no
#       project lines on the hub: the new lines go at the end
#   R9  the file lock busy: rc 1, no ack, file unchanged; then it applies
#   R10 every project line removed: an empty member, no deletion; the apply
#       drops them; a fetch overlays a pending write-back
#   R11 a deletion of, or a member-less base line for, the @rows path rejects
#
# Every case runs the production entry points (lri_publish, lri_fetch,
# lri_checkpoint, lri_apply_pending) against a stubbed jobs client that keeps
# the worker's state in files under $T/srv/<project>.
#
# Run from anywhere: tests/lane-run-inputs-rows.bh-6884-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="${LRI_LIB:-$REPO/bin/lib/lane-run-inputs.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
unset REGISTRY_SOURCE HARNESS H

PS=state/mc/pr-state.tsv
mkdir -p "$T/m"
printf '%s\n' "$PS" "@rows $PS ^\$slug#" > "$T/m/rowslane.rw"
export LRI_MANIFEST_DIR="$T/m"
printf '%s\n' 'demo example-org/Demo https://demo.example.com - 0' 'other example-org/Other https://other.example.com - 1' \
  'norepo - https://norepo.example.com - 2' 'dotted example-org/My.Repo https://dotted.example.com - 3' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"

# The jobs client, stubbed. Each request is one line in $T/req.log. The
# worker's state for project <p> lives in $T/srv/<p>: snap.json (written by
# POST commit), part-<n>.json (PUT), wblist.json and wb-<id>.json (the
# pending write-backs, set by QUEUE), posted-<n>.json (a checkpoint POST) and
# ack.log (one ack body a line).
export JOBS_HTTP=200
_srv() { local rest="${1#/api/lane-snapshots/rowslane/}"; SP="${rest%%/*}"; SUB="${rest#"$SP"}"; SUB="${SUB%%\?*}"; SD="$T/srv/$SP"; mkdir -p "$SD"; }
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/req.log"
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
  printf '%s %s\n' "$1" "$2" >> "$T/req.log"
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
# L <root> <cmd...> — one call of the lib in a subshell rooted at <root>.
L() { local r="$1"; shift; ( export HARNESS="$r"; . "$LIB" || exit 99; "$@" ); }
: > "$T/req.log"

FIXLINES=$'example-org/Demo#1\topen\t100\nexample-org/Other#5\topen\t101\nexample-org/demo#2\topen\t102\nexample-org/Demo-Console#9\topen\t103\nexample-org/Other#6\topen\t104'
DEMO_LINES=$'example-org/Demo#1\topen\t100\nexample-org/demo#2\topen\t102'
# HUB <root> — a hub root whose pr-state.tsv is the five-line fixture.
HUB() { mkdir -p "$1/state/mc" && printf '%s\n' "$FIXLINES" > "$1/$PS"; }
# PUB <hub> <p> — publish; PUBLISHED holds the output.
PUB() { PUBLISHED=$(L "$1" lri_publish rowslane "$2"); }
# SNAP <p> <out.tgz> — the snapshot the worker holds for <p>, reassembled.
SNAP() { local n; : > "$2"; for ((n = 0; n < $(jq -r .parts "$T/srv/$1/snap.json"); n++)); do jq -j .b64 "$T/srv/$1/part-$n.json" | base64 -d >> "$2"; done; }
# FETCH <machine> <p> — a fresh lane machine root, fetched.
FETCH() { mkdir -p "$1"; L "$1" lri_fetch rowslane "$2" x >/dev/null; }
# CKPT <machine> <p> — post a checkpoint; POSTED is the body file it sent.
CKPT() { POSTED="$T/no-checkpoint-body"
  LANE_RUN_ID=run-fixture-1 L "$1" lri_checkpoint rowslane "$2" >/dev/null || return 1
  POSTED=$(find "$T/srv/$2" -maxdepth 1 -name 'posted-*.json' | sort -V | tail -n 1); }
# WBTGZ <body.json> <out.tgz> — the write-back archive a body carries.
WBTGZ() { jq -j .b64 "$1" | base64 -d > "$2"; }
# QUEUE <p> <id> <body.json> — serve that body as the one pending write-back.
QUEUE() { cp "$3" "$T/srv/$1/wb-$2.json"
  jq -n --argjson i "$2" --arg s "$(jq -r .sha "$3")" '{writebacks:[{id:$i, sha:$s}]}' > "$T/srv/$1/wblist.json"; }
# APPLY <hub> <p> — APPLIED is the output, ARC the rc. The served list empties.
APPLY() { APPLIED=$(L "$1" lri_apply_pending rowslane "$2" 2>/dev/null); ARC=$?; }
UNQUEUE() { rm -f "$T/srv/$1/wblist.json"; }
SHA() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ============================================================================
echo "R1: the snapshot carries only the project's lines"
H1="$T/h1"; HUB "$H1"
PUB "$H1" demo; rc=$?
SNAP demo "$T/r1.tgz"
GOT=$(tar -xzOf "$T/r1.tgz" "$PS" 2>/dev/null)
[ "$rc" = 0 ] && [ "$GOT" = "$DEMO_LINES" ] && ok "R1 the demo member is exactly its 2 lines, in file order ($PUBLISHED)" \
  || bad "R1 rc=$rc member: $GOT"
grep -q 'example-org/demo#2' <<<"$GOT" && ok "R1 the mixed-case example-org/demo#2 line rides" || bad "R1 lacks the mixed-case line"
grep -q 'Demo-Console' <<<"$GOT" && bad "R1 the Demo-Console row rides under ^\$slug#" || ok "R1 no Demo-Console row"
grep -q 'Other' <<<"$GOT" && bad "R1 an Other row rides" || ok "R1 no Other row"
[ "$(tar -tzf "$T/r1.tgz" | grep -cxF "$PS")" = 1 ] && ok "R1 the path is one member, not a filtered copy plus the whole file" \
  || bad "R1 members: $(tar -tzf "$T/r1.tgz")"
L "$H1" lri_member_ok demo "$PS" - rw rowslane && ok "R1 lri_member_ok accepts the @rows path (rw)" || bad "R1 lri_member_ok refuses the @rows path"
PUB "$H1" other
SNAP other "$T/r1o.tgz"
[ "$(tar -xzOf "$T/r1o.tgz" "$PS")" = $'example-org/Other#5\topen\t101\nexample-org/Other#6\topen\t104' ] \
  && ok "R1 the other snapshot holds other's 2 lines" || bad "R1 other: $(tar -xzOf "$T/r1o.tgz" "$PS")"

# ============================================================================
echo "R2: two projects' write-backs both apply (and R6: a re-apply)"
rm -rf "$T/srv"; H2="$T/h2"; HUB "$H2"
PUB "$H2" demo; PUB "$H2" other
FETCH "$T/m2d" demo; FETCH "$T/m2o" other
[ "$(cat "$T/m2d/$PS")" = "$DEMO_LINES" ] && ok "R2 the demo machine holds demo's lines" || bad "R2 demo machine: $(cat "$T/m2d/$PS")"
sed -i 's/^example-org\/Demo#1\topen\t100$/example-org\/Demo#1\tmerged\t200/' "$T/m2d/$PS"
sed -i 's/^example-org\/Other#5\topen\t101$/example-org\/Other#5\tclosed\t300/' "$T/m2o/$PS"
CKPT "$T/m2d" demo || bad "R2 demo checkpoint failed"
DBODY="$POSTED"
CKPT "$T/m2o" other || bad "R2 other checkpoint failed"
OBODY="$POSTED"
WBTGZ "$DBODY" "$T/r2d.tgz"
BL=$(tar -xzOf "$T/r2d.tgz" .lri/base.tsv)
[ "$BL" = "$PS"$'\t'"$(printf '%s\n' "$DEMO_LINES" | sha256sum | cut -d' ' -f1)" ] \
  && ok "R2 base.tsv carries the sha256 of demo's lines at fetch time" || bad "R2 base.tsv: $BL"
QUEUE demo 1 "$DBODY"; APPLY "$H2" demo
[ "$ARC" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && ok "R2 demo: $APPLIED" || bad "R2 demo rc=$ARC: $APPLIED"
# The project's lines go where its first old line was; the other lines keep
# their order and Demo-Console#9 keeps its index.
WANT=$'example-org/Demo#1\tmerged\t200\nexample-org/demo#2\topen\t102\nexample-org/Other#5\topen\t101\nexample-org/Demo-Console#9\topen\t103\nexample-org/Other#6\topen\t104'
[ "$(cat "$H2/$PS")" = "$WANT" ] && ok "R2 after demo: demo's lines at its first line, the rest in order" || bad "R2 after demo: $(cat "$H2/$PS")"
[ "$(sed -n 4p "$H2/$PS" | cut -f1)" = 'example-org/Demo-Console#9' ] && ok "R2 Demo-Console#9 is still line 4" || bad "R2 line 4: $(sed -n 4p "$H2/$PS")"
QUEUE other 1 "$OBODY"; APPLY "$H2" other
[ "$ARC" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && ok "R2 other: $APPLIED" || bad "R2 other rc=$ARC: $APPLIED"
WANT=$'example-org/Demo#1\tmerged\t200\nexample-org/demo#2\topen\t102\nexample-org/Other#5\tclosed\t300\nexample-org/Other#6\topen\t104\nexample-org/Demo-Console#9\topen\t103'
[ "$(cat "$H2/$PS")" = "$WANT" ] && ok "R2 after other: both projects' changes are in, demo's lines untouched" || bad "R2 after other: $(cat "$H2/$PS")"
B6=$(SHA "$H2/$PS")
QUEUE demo 1 "$DBODY"; APPLY "$H2" demo
[ "$ARC" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && ok "R6 re-apply: $APPLIED" || bad "R6 re-apply rc=$ARC: $APPLIED"
[ "$(SHA "$H2/$PS")" = "$B6" ] && ok "R6 the hub file is unchanged by the re-apply" || bad "R6 file changed: $(cat "$H2/$PS")"
UNQUEUE demo; UNQUEUE other

# ============================================================================
echo "R3: a hub edit to a demo line after the fetch is a conflict"
rm -rf "$T/srv"; H3="$T/h3"; HUB "$H3"
PUB "$H3" demo; FETCH "$T/m3" demo
sed -i 's/\topen\t100$/\tmerged\t200/' "$T/m3/$PS"
CKPT "$T/m3" demo || bad "R3 checkpoint failed"
sed -i 's/^example-org\/Demo#1\topen\t100$/example-org\/Demo#1\thub-edit\t150/' "$H3/$PS"
cp "$H3/$PS" "$T/r3.pre"
QUEUE demo 1 "$POSTED"; APPLY "$H3" demo
[ "$APPLIED" = "applied=1 conflicts=1 rejected=0" ] && ok "R3 $APPLIED" || bad "R3 rc=$ARC: $APPLIED"
cmp -s "$T/r3.pre" "$H3/$PS" && ok "R3 the hub file is byte-identical to its pre-apply copy" || bad "R3 file changed: $(cat "$H3/$PS")"

# ============================================================================
echo "R4: a line that is not the project's rejects the write-back"
for c in other console empty; do
  rm -rf "$T/srv"; H4="$T/h4-$c"; HUB "$H4"
  PUB "$H4" demo; FETCH "$T/m4-$c" demo
  case "$c" in
    other) printf 'example-org/Other#7\topen\t400\n' >> "$T/m4-$c/$PS" ;;
    console) printf 'example-org/Demo-Console#10\topen\t400\n' >> "$T/m4-$c/$PS" ;;
    empty) printf '\n' >> "$T/m4-$c/$PS" ;;
  esac
  CKPT "$T/m4-$c" demo || bad "R4 $c checkpoint failed"
  B4=$(SHA "$H4/$PS")
  QUEUE demo 1 "$POSTED"; APPLY "$H4" demo
  [ "$APPLIED" = "applied=0 conflicts=0 rejected=1" ] && ok "R4 $c line: $APPLIED" || bad "R4 $c rc=$ARC: $APPLIED"
  [ "$(SHA "$H4/$PS")" = "$B4" ] && ok "R4 $c: the hub file sha is unchanged" || bad "R4 $c: file changed"
  [ "$(tail -n 1 "$T/srv/demo/ack.log" 2>/dev/null | jq -c .rejected)" = '[1]' ] && ok "R4 $c: the ack lists id 1 as rejected" \
    || bad "R4 $c ack: $(cat "$T/srv/demo/ack.log" 2>&1)"
done

# ============================================================================
echo "R5: a malformed @rows is one lri: line"
# R5M <case> <project> <want-ERE> <rw text> [ro text]
R5M() {
  local c="$1" p="$2" want="$3" err rc
  mkdir -p "$T/m5-$c"; printf '%s\n' "$4" > "$T/m5-$c/rowslane.rw"; [ -z "${5:-}" ] || printf '%s\n' "$5" > "$T/m5-$c/rowslane.ro"
  err=$( (export LRI_MANIFEST_DIR="$T/m5-$c"; L "$T/none" lri_paths rowslane "$p" rw) 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && [[ $err =~ $want ]] \
    && ok "R5 $c: rc 1, one line ($err)" || bad "R5 $c: rc=$rc err=$err"
}
R5M noere demo "^lri: .*/rowslane.rw:[0-9]+: @rows needs a path and an ERE\$" "$PS"$'\n'"@rows $PS"
R5M ro demo "^lri: .*/rowslane.ro:1: @rows is allowed in .rw only\$" "$PS" "@rows $PS ^\$slug#"
R5M nonrw demo "^lri: .*/rowslane.rw:2: the @rows path is not a path line of the .rw\$" "$PS"$'\n'"@rows state/mc/x.tsv ^\$slug#"
R5M twice demo "^lri: .*/rowslane.rw:3: a second @rows for $PS" "$PS"$'\n'"@rows $PS ^\$slug#"$'\n'"@rows $PS ^\$p"
R5M rowpath demo "^lri: .*/rowslane.rw:3: the @rows path is the @row path\$" "$PS"$'\n'"@row $PS lk"$'\n'"@rows $PS ^\$slug#"
R5M nocompile demo "^lri: .*/rowslane.rw:2: the @rows ERE does not compile\$" "$PS"$'\n'"@rows $PS ^(\$slug"
R5M norepo norepo "^lri: .*/rowslane.rw:2: @rows: no repo for norepo in fleet.conf\$" "$PS"$'\n'"@rows $PS ^\$slug#"
R5M ghost ghost "^lri: .*/rowslane.rw:2: @rows: no repo for ghost in fleet.conf\$" "$PS"$'\n'"@rows $PS ^\$slug#"
mkdir -p "$T/m5-ponly"; printf '%s\n' "$PS" "@rows $PS ^\$p	" > "$T/m5-ponly/rowslane.rw"
OUT=$( (export LRI_MANIFEST_DIR="$T/m5-ponly"; L "$T/none" lri_paths rowslane ghost rw) 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$OUT" = "$PS" ] && ok "R5 a \$p-only ERE needs no fleet.conf repo" || bad "R5 ponly rc=$rc: $OUT"
S=$(L "$T/none" _lri_slug demo); [ "$S" = 'example-org/demo' ] && ok "R5 \$slug is the lower-case fleet.conf repo ($S)" || bad "R5 _lri_slug demo: $S"
S=$(L "$T/none" _lri_slug dotted); [ "$S" = 'example-org/my\.repo' ] && ok "R5 \$slug escapes . ($S)" || bad "R5 _lri_slug dotted: $S"
for c in noere nocompile; do
  ( export LRI_MANIFEST_DIR="$T/m5-$c"; L "$T/h1" lri_apply_pending rowslane demo ) >/dev/null 2>&1 \
    && bad "R5 $c: lri_apply_pending rc 0 under a bad manifest" || ok "R5 $c: lri_apply_pending refuses"
done

# ============================================================================
echo "R7: a hub edit to another project's line is not a conflict"
rm -rf "$T/srv"; H7="$T/h7"; HUB "$H7"
PUB "$H7" demo; FETCH "$T/m7" demo
sed -i 's/^example-org\/demo#2\topen\t102$/example-org\/demo#2\tmerged\t202/' "$T/m7/$PS"
CKPT "$T/m7" demo || bad "R7 checkpoint failed"
sed -i 's/^example-org\/Other#5\topen\t101$/example-org\/Other#5\thub-edit\t150/' "$H7/$PS"
QUEUE demo 1 "$POSTED"; APPLY "$H7" demo
[ "$ARC" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && ok "R7 $APPLIED" || bad "R7 rc=$ARC: $APPLIED"
WANT=$'example-org/Demo#1\topen\t100\nexample-org/demo#2\tmerged\t202\nexample-org/Other#5\thub-edit\t150\nexample-org/Demo-Console#9\topen\t103\nexample-org/Other#6\topen\t104'
[ "$(cat "$H7/$PS")" = "$WANT" ] && ok "R7 demo's lines applied, the hub's Other edit kept" || bad "R7 file: $(cat "$H7/$PS")"

# ============================================================================
echo "R8: no hub file, and no hub lines for the project"
rm -rf "$T/srv"; H8="$T/h8"; mkdir -p "$H8/state/mc"
PUB "$H8" demo; rc=$?
SNAP demo "$T/r8.tgz"
[ "$rc" = 0 ] && tar -tzf "$T/r8.tgz" | grep -qxF "$PS" && [ -z "$(tar -xzOf "$T/r8.tgz" "$PS")" ] \
  && ok "R8 the snapshot carries an empty member" || bad "R8 rc=$rc members: $(tar -tzf "$T/r8.tgz" 2>&1)"
FETCH "$T/m8" demo
printf 'example-org/Demo#3\topen\t500\n' >> "$T/m8/$PS"
CKPT "$T/m8" demo || bad "R8 checkpoint failed"
QUEUE demo 1 "$POSTED"; APPLY "$H8" demo
[ "$ARC" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && ok "R8 $APPLIED" || bad "R8 rc=$ARC: $APPLIED"
[ "$(cat "$H8/$PS" 2>&1)" = $'example-org/Demo#3\topen\t500' ] && ok "R8 the apply creates the file with the one line" || bad "R8 file: $(cat "$H8/$PS" 2>&1)"
rm -rf "$T/srv"; H8b="$T/h8b"; mkdir -p "$H8b/state/mc"
printf 'example-org/Other#5\topen\t101\nexample-org/Other#6\topen\t104' > "$H8b/$PS"
PUB "$H8b" demo; FETCH "$T/m8b" demo
[ -f "$T/m8b/$PS" ] && [ ! -s "$T/m8b/$PS" ] && ok "R8b the machine holds an empty copy" || bad "R8b machine: $(cat "$T/m8b/$PS" 2>&1)"
printf 'example-org/Demo#3\topen\t500\n' >> "$T/m8b/$PS"
CKPT "$T/m8b" demo || bad "R8b checkpoint failed"
QUEUE demo 1 "$POSTED"; APPLY "$H8b" demo
[ "$(cat "$H8b/$PS")" = $'example-org/Other#5\topen\t101\nexample-org/Other#6\topen\t104\nexample-org/Demo#3\topen\t500' ] \
  && ok "R8b the new line goes at the end ($APPLIED)" || bad "R8b rc=$ARC $APPLIED file: $(cat "$H8b/$PS")"

# ============================================================================
echo "R9: the file lock busy stops the apply unacked"
rm -rf "$T/srv"; H9="$T/h9"; HUB "$H9"
PUB "$H9" demo; FETCH "$T/m9" demo
sed -i 's/\topen\t100$/\tmerged\t200/' "$T/m9/$PS"
CKPT "$T/m9" demo || bad "R9 checkpoint failed"
QUEUE demo 1 "$POSTED"
( flock -x 8; exec sleep 60 ) 8>>"$H9/$PS.lock" &
HOLDER=$!
for _ in $(seq 1 50); do flock -n "$H9/$PS.lock" true || break; sleep 0.1; done
B9=$(SHA "$H9/$PS"); : > "$T/req.log"
APPLY "$H9" demo
[ "$ARC" = 1 ] && ok "R9 lri_apply_pending rc 1 ($APPLIED)" || bad "R9 rc=$ARC: $APPLIED"
grep -q '^POST .*/ack' "$T/req.log" && bad "R9 an ack was posted" || ok "R9 no ack was posted"
[ "$(SHA "$H9/$PS")" = "$B9" ] && ok "R9 the hub file is unchanged" || bad "R9 file changed"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
APPLY "$H9" demo
[ "$ARC" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && [ "$(head -n 1 "$H9/$PS")" = $'example-org/Demo#1\tmerged\t200' ] \
  && ok "R9 with the lock free it applies: $APPLIED" || bad "R9 re-run rc=$ARC: $APPLIED $(head -n 1 "$H9/$PS")"

# ============================================================================
echo "R10: every project line removed"
rm -rf "$T/srv"; H10="$T/h10"; HUB "$H10"
PUB "$H10" demo; FETCH "$T/m10" demo
rm -f "$T/m10/$PS"
CKPT "$T/m10" demo || bad "R10 checkpoint failed"
WBTGZ "$POSTED" "$T/r10.tgz"
tar -tzf "$T/r10.tgz" | grep -qxF "$PS" && [ -z "$(tar -xzOf "$T/r10.tgz" "$PS")" ] && ok "R10 the write-back carries an empty member" \
  || bad "R10 members: $(tar -tzf "$T/r10.tgz")"
[ -z "$(tar -xzOf "$T/r10.tgz" .lri/deletions)" ] && ok "R10 no .lri/deletions line" || bad "R10 deletions: $(tar -xzOf "$T/r10.tgz" .lri/deletions)"
QUEUE demo 1 "$POSTED"
FETCH "$T/m10b" demo
[ -f "$T/m10b/$PS" ] && [ ! -s "$T/m10b/$PS" ] && ok "R10 a fetch overlays the pending write-back's empty member" || bad "R10 fetch overlay: $(cat "$T/m10b/$PS" 2>&1)"
APPLY "$H10" demo
[ "$ARC" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && ok "R10 $APPLIED" || bad "R10 rc=$ARC: $APPLIED"
[ "$(cat "$H10/$PS")" = $'example-org/Other#5\topen\t101\nexample-org/Demo-Console#9\topen\t103\nexample-org/Other#6\topen\t104' ] \
  && ok "R10 the apply drops demo's lines and keeps the others" || bad "R10 file: $(cat "$H10/$PS")"

# ============================================================================
echo "R11: a deletion or a member-less base line for the @rows path rejects"
# WB11 <case> <deletions text> [member] — a write-back of base.tsv and
# deletions; with `member`, plus a valid demo member at the @rows path.
WB11() { local w="$T/wb11-$1" m=()
  mkdir -p "$w/.lri"; printf '%s\t%s\n' "$PS" "$(printf '%s\n' "$DEMO_LINES" | sha256sum | cut -d' ' -f1)" > "$w/.lri/base.tsv"
  printf '%s' "$2" > "$w/.lri/deletions"
  if [ "${3:-}" = member ]; then mkdir -p "$w/state/mc"; printf 'example-org/Demo#1\tmerged\t200\n' > "$w/$PS"; m=("$PS"); fi
  tar --owner=0 --group=0 --numeric-owner --format=gnu -czf "$w.tgz" -C "$w" ${m[@]+"${m[@]}"} .lri/base.tsv .lri/deletions || return 1
  jq -n --rawfile b <(base64 -w0 "$w.tgz") --arg s "$(SHA "$w.tgz")" '{sha:$s, b64:$b}' > "$w.json"; }
for c in deletion nomember; do
  rm -rf "$T/srv"; H11="$T/h11-$c"; HUB "$H11"; mkdir -p "$T/srv/demo"
  case "$c" in deletion) WB11 "$c" "$PS"$'\n' member ;; nomember) WB11 "$c" "" ;; esac
  B11=$(SHA "$H11/$PS")
  QUEUE demo 1 "$T/wb11-$c.json"; APPLY "$H11" demo
  [ "$APPLIED" = "applied=0 conflicts=0 rejected=1" ] && ok "R11 $c: $APPLIED" || bad "R11 $c rc=$ARC: $APPLIED"
  [ "$(SHA "$H11/$PS")" = "$B11" ] && ok "R11 $c: the hub file is unchanged" || bad "R11 $c: file changed: $(cat "$H11/$PS" 2>&1)"
done

echo
echo "lane-run-inputs-rows: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
exit 0
