#!/bin/bash
# tests/build-archive-readers.bh-7437-test.sh — BH-7437 part 2, item 3: every
# by-key reader of builds/ still resolves a build that bin/builds-retention.sh
# moved to builds-archive/, or answers that it is archived and where.
#
#   I1-I4  bin/lib/build-archive.sh: the index round trip (the real writer),
#          exact key match (TK-8 vs TK-88), a missing index, a row with no dir
#   F1-F4  bin/fetch-artifact.sh (the real script): an archived-only key, a
#          live dir without the file plus an archived dir with it, a live dir
#          with the file wins, a bad key refused before any index read
#   D1-D5  the decision readers: launch-fastpath check 17, ticket identity,
#          starved-ready, merged-ticket-advance _ma_builds, blocked-resolver
#          discovery (ledger-only rows)
#
# Run from anywhere (exit 0 = pass).
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

H="$T/h"
mkdir -p "$H/builds" "$H/logs" "$H/state" "$H/locks"
for s in bin/fetch-artifact.sh bin/launch-fastpath.sh bin/merged-ticket-advance.sh \
         bin/lib/build-archive.sh bin/lib/ticket-identity.sh bin/lib/starved-ready.sh \
         bin/lib/br/discovery.sh bin/lib/builds-of-record.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "setup: could not install $s"; exit 1; }
done
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
cat > "$H/fleet.conf" <<'CONF'
alpha-os  Org/alpha  https://alpha.example  /api/board  2 box-alpha
CONF
A="$H/builds-archive"

# arch <dir> <result1> [ticket_id] — an archived dir, written the way
# bin/builds-retention.sh writes it: the row through the real writer, then the
# dir under builds-archive/<YYYYMM>/.
arch() {
  local n="$1" r="$2" tid="${3:--}" s
  ( . "$H/bin/lib/build-archive.sh"; ba_parse "$n" || exit 1
    s="$BA_STAMP"; mkdir -p "$A/${s:0:6}/$n"; printf '%s\n' "$r" > "$A/${s:0:6}/$n/RESULT"
    ba_index_append "$H" "$n" "${s:0:6}/$n" "$BA_P" "$BA_K" "$tid" "$r" )
}
lib() { ( . "$H/bin/lib/build-archive.sh"; "$@" ); }

# ============================================================================
echo "I: the index"
arch alpha-os-TK-88-202609011200 "PR_MERGED https://github.com/o/r/pull/88	tab"
arch pool-alpha-os-TK-88-202609011300 "PR_MERGED https://github.com/o/r/pull/88"
got=$(lib ba_dirs "$H" alpha-os TK-88)
want="$A/202609/pool-alpha-os-TK-88-202609011300"$'\n'"$A/202609/alpha-os-TK-88-202609011200"
[ "$got" = "$want" ] && ok "I1 round trip, newest stamp first" || bad "I1 got [$got]"
row=$(grep -F 'alpha-os-TK-88-202609011200' "$A/index.tsv" | head -1)
[ "$(awk -F'\t' '{print NF}' <<<"$row")" = 7 ] && [ "$(cut -f7 <<<"$row")" = "PR_MERGED https://github.com/o/r/pull/88 tab" ] \
  && ok "I1 7 fields, the tab in result1 stripped" || bad "I1 row [$row]"
lib ba_dirs "$H" alpha-os TK-8 >/dev/null; rc=$?
[ "$rc" = 2 ] && ok "I2 TK-8 does not match TK-88 (rc 2)" || bad "I2 TK-8 rc=$rc"
lib ba_has_key "$H" alpha-os TK-88 && ok "I2 ba_has_key TK-88" || bad "I2 ba_has_key TK-88"
[ "$(lib ba_path "$H" alpha-os-TK-88-202609011300)" = "$A/202609/pool-alpha-os-TK-88-202609011300" ] \
  && ok "I2 ba_path finds the pool- name from the bare name" || bad "I2 ba_path"
E="$T/empty"; mkdir -p "$E"
out=$(lib ba_dirs "$E" alpha-os TK-88); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok "I3 a missing index: rc 2, no output" || bad "I3 rc=$rc out=$out"
lib ba_path "$E" alpha-os-TK-88-202609011200 >/dev/null; rc=$?
[ "$rc" = 2 ] && ok "I3 ba_path with no index: rc 2" || bad "I3 ba_path rc=$rc"
( . "$H/bin/lib/build-archive.sh"; ba_index_append "$H" alpha-os-TK-77-202609011200 202609/alpha-os-TK-77-202609011200 alpha-os TK-77 - "PR_MERGED x" )
out=$(lib ba_dirs "$H" alpha-os TK-77); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok "I4 a row whose dir is gone is skipped" || bad "I4 rc=$rc out=$out"

# ============================================================================
echo "F: bin/fetch-artifact.sh"
fa() { "$H/bin/fetch-artifact.sh" "$@" 2>/dev/null; }
printf 'VERDICT: APPROVE\narchived review\n' > "$A/202609/pool-alpha-os-TK-88-202609011300/review.md"
OUT=$(fa alpha-os TK-88 review cid-f1); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .archived <<<"$OUT")" = true ] && [ "$(jq -r .missing <<<"$OUT")" = false ] \
  && [ "$(jq -r .build_dir <<<"$OUT")" = "$A/202609/pool-alpha-os-TK-88-202609011300" ] \
  && [ "$(jq -r .content <<<"$OUT")" = "$(cat "$A/202609/pool-alpha-os-TK-88-202609011300/review.md")" ] \
  && ok "F1 an archived-only key answers archived:true with the archive dir" || bad "F1 rc=$RC out=$OUT"
[ "$(fa --path alpha-os TK-88 review)" = "$A/202609/pool-alpha-os-TK-88-202609011300/review.md" ] \
  && ok "F1 --path resolves into builds-archive/" || bad "F1 --path [$(fa --path alpha-os TK-88 review)]"
grep -q 'fetch_artifact id=cid-f1 .* archived dir=' "$H/logs/console-commands.log" \
  && ok "F1 the journal says archived" || bad "F1 journal: $(tail -1 "$H/logs/console-commands.log")"
L="$H/builds/alpha-os-TK-88-202610051200"; mkdir -p "$L"; echo QUEUED_FLY > "$L/RESULT"
OUT=$(fa alpha-os TK-88 review cid-f2)
[ "$(jq -r .archived <<<"$OUT")" = true ] && [ "$(jq -r .missing <<<"$OUT")" = false ] \
  && [ "$(jq -r .build_dir <<<"$OUT")" = "$A/202609/pool-alpha-os-TK-88-202609011300" ] \
  && ok "F2 a live dir without the file: the archived dir that holds it answers" || bad "F2 out=$OUT"
OUT=$(fa alpha-os TK-88 qa cid-f2b)
[ "$(jq -r .archived <<<"$OUT")" = false ] && [ "$(jq -r .missing <<<"$OUT")" = true ] && [ "$(jq -r .build_dir <<<"$OUT")" = "$L" ] \
  && ok "F2 nobody holds qa.md: the newest LIVE dir is the answer, archived:false" || bad "F2b out=$OUT"
echo "live review" > "$L/review.md"
OUT=$(fa alpha-os TK-88 review cid-f3)
[ "$(jq -r .archived <<<"$OUT")" = false ] && [ "$(jq -r .build_dir <<<"$OUT")" = "$L" ] && [ "$(jq -r .content <<<"$OUT")" = "live review" ] \
  && ok "F3 a live dir with the file wins over the archive" || bad "F3 out=$OUT"
mv "$A/index.tsv" "$A/index.tsv.away"; mkfifo "$A/index.tsv"
OUT=$(timeout 5 "$H/bin/fetch-artifact.sh" alpha-os 'TK-88*' review cid-f4 2>/dev/null); RC=$?
rm -f "$A/index.tsv"; mv "$A/index.tsv.away" "$A/index.tsv"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "F4 a bad key is refused rc 1 before the index is read" || bad "F4 rc=$RC out=$OUT"
OUT=$(fa nope-os TK-88 review cid-f4b); RC=$?
[ "$RC" = 1 ] && ok "F4 an unknown project is refused rc 1" || bad "F4b rc=$RC"

# ============================================================================
echo "D: the decision readers"
arch alpha-os-TK-30-202609011200 "QUEUED_FLY TK-30" 9031
arch pool-alpha-os-TK-30-202609011300 "PR_MERGED https://github.com/o/r/pull/30"

# D1 launch-fastpath check 17, the real function body.
d1() ( . "$H/bin/lib/build-archive.sh"; project=alpha-os; MARKDIR="$T/marks"
       eval "$(sed -n '/^local_eligible() {/,/^}/p' "$H/bin/launch-fastpath.sh")"
       local_eligible "$1"; rc=$?; printf '%s|%s' "$rc" "$LOCAL_WHY" )
[ "$(d1 TK-30)" = "1|prior build record exists (archived) — relaunches are triage's call" ] \
  && ok "D1 local_eligible refuses an archived-only key" || bad "D1 got [$(d1 TK-30)]"
[ "$(d1 TK-31)" = "0|" ] && ok "D1 a key with no record is eligible" || bad "D1 TK-31 [$(d1 TK-31)]"

# D2 ticket identity: the archived stub has the board id, its twin the merge.
d2() ( . "$H/bin/lib/ticket-identity.sh"; ticket_identity_conflict "$H" alpha-os "$1" "$2"; echo "rc=$?" )
[ "$(d2 9031 TK-99)" = "TK-30	build-record	merged"$'\n'"rc=0" ] \
  && ok "D2 an archived merged key with the same ticket id is a conflict" || bad "D2 got [$(d2 9031 TK-99)]"
# The ledger and queue sources are not stubbed here, so "nothing found" is rc 2.
[ "$(d2 9031 TK-30)" = "rc=2" ] && ok "D2 the same key prints no conflict" || bad "D2 same key [$(d2 9031 TK-30)]"
[ "$(d2 9555 TK-99 | head -1)" != "TK-30	build-record	merged" ] && ok "D2 another ticket id is not matched" || bad "D2 other id"

# D3 starved-ready: an archived key is built, so it costs no probe.
mkdir -p "$T/sr/bin/lib" "$T/sr/state/starved-ready" "$T/sr/logs"
for s in bin/lib/starved-ready.sh bin/lib/build-archive.sh bin/lib/ready-queue.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$T/sr" ) >/dev/null || bad "setup: could not install $s in sr"
done
ln -s "$H/bin/fleet-conf.sh" "$T/sr/bin/fleet-conf.sh"
cp -r "$A" "$T/sr/builds-archive"
printf '#!/bin/bash\n[ "$2" = --buildable-strict ] && { echo "$3" >> "%s/probes.txt"; echo OK; }\n' "$T/sr" > "$T/sr/bin/triage-gate.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\n' "$T/sr" > "$T/sr/bin/lane-alert.sh"
chmod +x "$T/sr/bin/"*.sh
jq -nc '{"bd-1":[{id:"9030",key:"TK-30",status:"todo",waitingOn:"team",triageVerdict:"ready"},
                 {id:"9032",key:"TK-32",status:"todo",waitingOn:"team",triageVerdict:"ready"}]}' > "$T/sr/state/alpha-os.gate.json"
printf '9030\t%s\n9032\t%s\n' 1790000000 1790000000 > "$T/sr/state/starved-ready/alpha-os.tsv"
( ready_queue_rows_on() { return 1; }; queue_list() { return 0; }
  export STARVED_READY_NOW=1790009000
  . "$T/sr/bin/lib/starved-ready.sh" && starved_ready_check "$T/sr" alpha-os ) >/dev/null 2>&1
[ "$(cat "$T/sr/probes.txt" 2>/dev/null)" = 9032 ] \
  && ok "D3 the archived key TK-30 is not probed; TK-32 is" || bad "D3 probes [$(cat "$T/sr/probes.txt" 2>/dev/null)]"

# D4 merged-ticket-advance _ma_builds, the real function body.
d4() ( . "$H/bin/lib/build-archive.sh"; HARNESS="$H"; PROJECT=alpha-os
       eval "$(sed -n '/^_ma_builds() {/,/^}/p' "$H/bin/merged-ticket-advance.sh")"
       _ma_builds "$1" )
mkdir -p "$H/builds/alpha-os-TK-30-202610101200"
want="202610101200	$H/builds/alpha-os-TK-30-202610101200"$'\n'"202609011300	$A/202609/pool-alpha-os-TK-30-202609011300"$'\n'"202609011200	$A/202609/alpha-os-TK-30-202609011200"
[ "$(d4 TK-30)" = "$want" ] && ok "D4 _ma_builds lists the archived dirs, stamp order" || bad "D4 got [$(d4 TK-30)]"
scratch_rm "$H/builds/alpha-os-TK-30-202610101200"

# D5 blocked-resolver discovery: a ledger-only row whose dir is archived.
d5() ( H="$H"; ST="$T/br-state"; ONLY=""
       . "$H/bin/lib/builds-of-record.sh"; . "$H/bin/lib/br/discovery.sh"
       br_rkey() { printf '%s' "${1//[^A-Za-z0-9._-]/-}"; }
       bor_union() { printf 'x\talpha-os-TK-%s-202609011200\tx\t2026-09-01T12:00:00Z\tBUILD_DEAD died\t-\tjob-%s\n' "$D5K" "$D5K"; }
       br_from_builds 2>/dev/null )
d5_out=$(D5K=30 d5)
[ -z "$d5_out" ] && ok "D5 an archived ledger record is not re-offered" || bad "D5 got [$d5_out]"
d5_ctl=$(D5K=40 d5)
grep -q 'build-dead' <<<"$d5_ctl" && ok "D5 control: a ledger record with no dir anywhere is offered" || bad "D5 control [$d5_ctl]"

echo "build-archive-readers.bh-7437: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
