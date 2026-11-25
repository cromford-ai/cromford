#!/bin/bash
# tests/br-discovery-scale.bh-9952-test.sh — BH-9952: discovery at the hub's
# size. The blocked-resolver pass for cromford took 1,978 s on the hub
# with the BH-9467 cache hitting (discovery_src=rebuilds:571,builds:603).
#
# THE FIXTURE (the hub's size): 10,015 build dirs for p1 (mixed RESULT lines)
# and 300 pool- twins, 1,200 records (20 with a rebuild-fresh last attempt),
# and 500 ledger rows (300 that name a local dir, 200 ledger-only: 50 of them
# with an archive index row, and state files that skip, emit, fail to parse
# or sit on the 90-minute floor).
#
#   S1  pass 2's prof discovery= is under 60
#   S2  the candidate rows (RAW) of the fast path, ticks 1-3, are byte-equal to
#       the old path's (BR_OPT_OFF=bh-9952-discovery-batch,bh-9467-discovery-cache)
#   S3  discovery_sub= names builds.union/ledger/glob and rebuilds.union/queue/
#       walk; discovery_src= keeps the whole sources in br_candidates' order
#   S4  bor_union is read once per project per tick: 2 feed calls, not 4
#   S5  fork counts (PATH shims for jq and date): 2 batched state jq calls (the
#       second after the file that does not parse) and 1 per-row fallback (that
#       file), no `date -d` of a ledger or attempt time; the old path, on the
#       same tick, forks per row
#   S6  the ledger cache: tick 2 skips the stable ledger rows; a state file
#       with a new mtime is read again with the same decision; a row on the
#       time floor is never noted
#   S7  bdb_archived answers what ba_path answers, on a decision table
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh in observe mode against a
# scratch $HARNESS (the rig of tests/br-discovery-incremental.bh-9467-test.sh)
# with the real bin/lib/builds-of-record.sh and bin/lib/build-archive.sh. The
# ledger is a job_artifact_feed stub in the scratch jobs-client. The RAW rows
# come from a scratch-only fragment that wraps br_candidates (zz-test-raw.sh
# in $T, never in the repo). No vendor is called (BH-7563): gh is a local
# stub, GH_TOKEN is empty.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/br-discovery-scale.bh-9952-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
REALJQ=$(command -v jq); REALDATE=$(command -v date)

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
STAMPAT() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
DAY=86400

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos" "$T/shim"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
# The fragment under test, named by its rooted path so the orphan check sees it.
FRAG="$DIR/bin/blocked-resolver.d/bh-9952-discovery-batch.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh bin/lib/br/opt/profile.sh \
         bin/lib/builds-of-record.sh bin/lib/build-archive.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"pulls?state=closed"*)
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; _ghs_send 200 '[]'; exit 0 ;;
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
# The jobs client: no queue rows (queue_list rc 1), and the ledger from
# $T/feed-<kind>.tsv. Each feed call logs the bash call stack.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
job_artifact_feed() {
  printf '%s %s\n' "\$1" "\${FUNCNAME[*]}" >> "$T/feed-calls.txt"
  [ -f "$T/feed-\$1.tsv" ] && cat "$T/feed-\$1.tsv"
  return 0
}
EOF
touch "$H/flags/fly-pool-p1"
# THE RAW ROWS, through a scratch-only fragment sorted after every real one:
# br_candidates' stdout is copied to $RAW_OUT.
cat > "$H/bin/blocked-resolver.d/zz-test-raw.sh" <<'EOF'
eval "$(declare -f br_candidates | sed '1s/^br_candidates/_zz_br_candidates/')"
br_candidates() { _zz_br_candidates | tee -a "${RAW_OUT:-/dev/null}"; }
EOF

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
LOGF="$H/logs/blocked-resolver.log"
U="https://github.com/o/p1/pull"
OLD=(BR_OPT_OFF=bh-9952-discovery-batch,bh-9467-discovery-cache)
BASEENV=(BR_PER_TICK=50 BR_PER_TICK_P1=1)
RUN() { # RUN <raw file> [env...]
  local raw="$1"; shift; : > "$raw"; : > "$LOGF"
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" RAW_OUT="$raw" \
    BR_SSH="$T/fakebin/br-ssh" env "${BASEENV[@]}" "$@" \
    timeout 900 bash "$H/bin/blocked-resolver.sh" p1 >>"$T/run.log" 2>&1 ) || true; }
LASTPROF() { grep ' prof: ' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { LASTPROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
CACHELINE() { grep "discovery cache $1: " "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }

[ -f "$FRAG" ] || bad "0: bin/blocked-resolver.d/bh-9952-discovery-batch.sh must exist"

# ============================================================================
# THE FIXTURE
# ============================================================================
touch "$H/flags/blocked-resolver-observe"
printf 'o/p1#9001\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\tconflict-unresolvable: x\t%s/9001\n' "$((NOW - 7200))" "$U" > "$ROWS"
B="$H/builds"
dirs=(); for n in $(seq 1 10000); do dirs+=("$B/p1-TK-$n-202610010000"); done
for n in $(seq 1 300); do dirs+=("$B/pool-p1-TK-$n-202610010000"); done
mkdir -p "${dirs[@]}"
for n in $(seq 1 10000); do
  case $((n % 100)) in
    1) l="BUILD_DEAD x" ;; 2) l="PLAN_BLOCKED see x" ;; 3) l="REVIEW_BLOCKED gate" ;;
    *) if [ $((n % 2)) = 0 ]; then l="PR_CREATED $U/$n"; else l="PR_MERGED $U/$n"; fi ;;
  esac
  printf '%s\n' "$l" > "$B/p1-TK-$n-202610010000/RESULT"
done
for n in $(seq 1 300); do printf 'PR_MERGED %s/%s\n' "$U" "$n" > "$B/pool-p1-TK-$n-202610010000/RESULT"; done
find "$B" -mindepth 2 -maxdepth 2 -name RESULT -exec touch -d "@$((NOW - 3 * DAY))" {} +

# 1,200 records: fix-round last attempt, except 20 with a rebuild-fresh one.
mkdir -p "$ST/p1"
for i in $(seq 1 1200); do
  k=$((30000 + i))
  if [ "$i" -le 20 ]; then
    printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","attempts":[{"at":"%s","action":"rebuild-fresh","reason":"x","detail":"enqueued"}],"parked_url":"%s/%s","rebuild_seen":[]}\n' \
      "$k" "$(STAMPAT $((NOW - 2 * DAY)))" "$U" "$k" > "$ST/p1/p1-TK-$k.json"
  else
    printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","attempts":[{"at":"%s","action":"fix-round","reason":"x","detail":"y"}]}\n' \
      "$k" "$(STAMPAT $((NOW - DAY)))" > "$ST/p1/p1-TK-$k.json"
  fi
done
# Their fresh builds: 10 landed, 5 dead, 5 none yet (a wait).
for i in $(seq 1 15); do
  k=$((30000 + i)); d="$B/p1-TK-$k-202611200000"; mkdir -p "$d"
  if [ "$i" -le 10 ]; then printf 'PR_CREATED %s/%s\n' "$U" "$k" > "$d/RESULT"; else printf 'BUILD_DEAD fresh\n' > "$d/RESULT"; fi
  touch -d "@$((NOW - DAY))" "$d/RESULT"
done

# 500 ledger rows. 300 name a local dir; 200 are ledger-only (m 20001-20200).
LBD() { printf 'p1-TK-%s-202611010000' "$1"; }
{ for n in $(seq 1 300); do
    printf 'jl%s\tPR_MERGED %s/%s\tbox-b\tt\t2026-10-20T01:00:%02dZ\t{"build_dir":"p1-TK-%s-202610010000","key":"TK-%s"}\n' "$n" "$U" "$n" "$((n % 60))" "$n" "$n"
  done
  for m in $(seq 20001 20200); do
    u="2026-10-20T0$((m % 10)):$((10 + m % 50)):$((10 + m % 49))Z"
    [ "$m" -ge 20152 ] && [ "$m" -le 20160 ] && u=$(ISO $((NOW - 600)))
    printf 'jm%s\tBUILD_DEAD remote\tbox-b\tt\t%s\t{"build_dir":"%s","key":"TK-%s"}\n' "$m" "$u" "$(LBD "$m")" "$m"
  done
} > "$T/feed-result.tsv"
printf 'jm20140\t%s/20140\n' "$U" > "$T/feed-pr_url.tsv"
# 50 archived names (exact, pool- and fly- forms), a MOVE_FAILED row and a row
# whose dir is gone.
A="$H/builds-archive"; mkdir -p "$A/202611"
{ printf '#archived_at\tdir\trelpath\tproject\tkey\tticket_id\tresult1\n'
  for m in $(seq 20001 20050); do
    case $((m % 3)) in 0) nm=$(LBD "$m") ;; 1) nm="pool-$(LBD "$m")" ;; *) nm="fly-$(LBD "$m")" ;; esac
    mkdir -p "$A/202611/$nm"
    printf '2026-11-02T00:00:00Z\t%s\t202611/%s\tp1\tTS-%s\t-\tBUILD_DEAD\n' "$nm" "$nm" "$m"
  done
  printf '2026-11-02T00:00:00Z\t%s\t202611/%s\tp1\tTS-20051\t-\tMOVE_FAILED\n' "$(LBD 20051)" "$(LBD 20051)"
  mkdir -p "$A/202611/$(LBD 20051)"
  printf '2026-11-02T00:00:00Z\t%s\t202611/%s\tp1\tTS-20052\t-\tBUILD_DEAD\n' "$(LBD 20052)" "$(LBD 20052)"
} > "$A/index.tsv"
# State files of the ledger-only rows.
for m in $(seq 20061 20100); do   # this build already consumed: a stable skip
  printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","rebuild_seen":["%s"],"attempts":[]}\n' "$m" "pool-$(LBD "$m")" > "$ST/p1/p1-TK-$m.json"
done
for m in $(seq 20101 20130); do   # an attempt after the record: a stable skip
  printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","attempts":[{"at":"2026-10-21 05:00:00Z","action":"rebuild-fresh-failed"},{"at":"2026-10-22 05:00:00Z","action":"held"}]}\n' "$m" > "$ST/p1/p1-TK-$m.json"
done
for m in $(seq 20131 20150); do   # an attempt before the record: offered
  printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","attempts":[{"at":"2026-10-19 05:00:00Z","action":"fix-round"}]}\n' "$m" > "$ST/p1/p1-TK-$m.json"
done
printf '{"project":"p1", not json\n' > "$ST/p1/p1-TK-20151.json"   # fails closed
for m in 20152 20153; do          # on the 90-minute floor, with a state file
  printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","attempts":[{"at":"2026-10-19 05:00:00Z","action":"fix-round"}]}\n' "$m" > "$ST/p1/p1-TK-$m.json"
done
nd=$(find "$B" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$nd" -ge 10300 ] && ok || bad "setup: $nd build dirs, want >= 10,300"

# ============================================================================
# S2 (old path) — the reference rows.
# ============================================================================
RUN "$T/raw-old.txt" "${OLD[@]}"
[ -s "$T/raw-old.txt" ] && ok || bad "S2: the old path printed candidate rows (log: $(tail -3 "$T/run.log"))"
OLDDIS=$(PFIELD discovery)
grep -c . "$T/raw-old.txt" > "$T/raw-old.count"
# The fixture's shape, read from the old path: build rows and ledger rows.
grep -q $'^build\tp1\tp1-TK-20131\tbuild-dead\t-\t-\tTS-20131' "$T/raw-old.txt" && ok \
  || bad "S2: the old path offers ledger row 20131 (attempt before the record)"
grep -q $'\tp1-TK-20061\t' "$T/raw-old.txt" && bad "S2: the old path does not offer 20061 (rebuild_seen)" || ok

# ============================================================================
# Ticks 1-3 of the fast path.
# ============================================================================
rm -f "$ST"/.disc-cache-*
: > "$T/feed-calls.txt"
RUN "$T/raw-new1.txt"
NFEED1=$(grep -c ' br_candidates' "$T/feed-calls.txt")
CL1=$(CACHELINE builds)
RUN "$T/raw-new2.txt"
NFEED2=$(grep -c ' br_candidates' "$T/feed-calls.txt")
CL2=$(CACHELINE builds); P2=$(LASTPROF)
NEWDIS=$(PFIELD discovery)

# S1. Pass 2 discovery under 60 s.
case "$NEWDIS" in ''|*[!0-9]*) bad "S1: no discovery= on pass 2 (prof: $P2)" ;;
  *) [ "$NEWDIS" -lt 60 ] && ok || bad "S1: THE BUG: pass 2 discovery=$NEWDIS, want under 60 (prof: $P2)" ;; esac

# S2. Byte-equal rows.
cmp -s "$T/raw-old.txt" "$T/raw-new1.txt" && ok || { bad "S2: tick 1 rows differ from the old path"; diff "$T/raw-old.txt" "$T/raw-new1.txt" | head -8; }
cmp -s "$T/raw-old.txt" "$T/raw-new2.txt" && ok || { bad "S2: tick 2 rows (cache hits) differ from the old path"; diff "$T/raw-old.txt" "$T/raw-new2.txt" | head -8; }

# S3. The sub-timers.
for part in builds.union builds.ledger builds.glob rebuilds.union rebuilds.queue rebuilds.walk; do
  grep -qE "discovery_sub=([^ ]*,)?${part//./\\.}:[0-9]+" <<<"$P2" && ok || bad "S3: discovery_sub= names $part (prof: $P2)"
done
grep -qE ' discovery_src=rebuilds:[0-9]+,conductor:[0-9]+,queue:[0-9]+,builds:[0-9]+,reviews:[0-9]+,external:[0-9]+ project=p1 ' <<<"$P2" && ok \
  || bad "S3: discovery_src= keeps the whole sources only, in order (prof: $P2)"
grep -qE ' top=\[[^]]*\]$' <<<"$P2" && ok || bad "S3: top=[...] stays last (prof: $P2)"

# S4. One union read per project per tick: 2 feed calls (result, pr_url).
[ "$NFEED1" = 2 ] && ok || bad "S4: tick 1 made $NFEED1 feed calls from discovery, want 2 ($(cut -c1-120 "$T/feed-calls.txt" | head -4 | tr '\n' ';'))"
[ "$((NFEED2 - NFEED1))" = 2 ] && ok || bad "S4: tick 2 made $((NFEED2 - NFEED1)) feed calls from discovery, want 2"

# S6. The ledger cache.
CF="$ST/.disc-cache-builds-p1.tsv"
NL=$(grep -c '^ledger:' "$CF" 2>/dev/null)
[ "$NL" = 70 ] && ok || bad "S6: tick 1 notes the 70 stable ledger skips (40 rebuild_seen + 30 later attempt), got $NL"
grep -q "^ledger:p1/$(LBD 20152)"$'\t' "$CF" && bad "S6: a row on the 90-minute floor is never noted" || ok
grep -q "^ledger:p1/$(LBD 20131)"$'\t' "$CF" && bad "S6: an offered row is never noted" || ok
grep -q "^ledger:p1/$(LBD 20151)"$'\t' "$CF" && bad "S6: a state file that does not parse is never noted" || ok
W1=$(printf '%s' "$CL1" | sed -nE 's/.*\(([0-9]+) cache rows written\).*/\1/p')
H2=$(printf '%s' "$CL2" | sed -nE 's/.* ([0-9]+) unchanged and skipped.*/\1/p')
[ -n "$W1" ] && [ "$H2" = "$W1" ] && ok || bad "S6: tick 2 skips every row tick 1 noted, the 70 ledger rows included (tick 1: $CL1; tick 2: $CL2)"
# A state file with a new mtime: read again, same decision, noted again.
touch -d "@$((NOW - 60))" "$ST/p1/p1-TK-20061.json"
RUN "$T/raw-new3.txt"
CL3=$(CACHELINE builds)
H3=$(printf '%s' "$CL3" | sed -nE 's/.* ([0-9]+) unchanged and skipped.*/\1/p')
[ "$H3" = $((W1 - 1)) ] && ok || bad "S6: the touched state file is read again ($CL3; want $((W1 - 1)) skipped)"
grep -q "^ledger:p1/$(LBD 20061)"$'\t'"2026-10-20T" "$CF" && ok || bad "S6: the re-read row is noted again with its new signature"
cmp -s "$T/raw-old.txt" "$T/raw-new3.txt" && ok || bad "S2/S6: tick 3 rows differ from the old path"

# ============================================================================
# S5. Fork counts: PATH shims for jq and date, cache off so every ledger row
#     reaches its state read.
# ============================================================================
for b in jq date; do
  real=$REALJQ; [ "$b" = date ] && real=$REALDATE
  printf '#!/bin/bash\n{ printf "%%q " "$@"; echo; } >> "%s/shim/%s.log"\nexec "%s" "$@"\n' "$T" "$b" "$real" > "$T/shim/$b"
  chmod +x "$T/shim/$b"
done
shimrun() { : > "$T/shim/jq.log"; : > "$T/shim/date.log"
  ( export PATH="$T/shim:$PATH"; RUN "$1" BR_DISCOVERY_CACHE=0 "${@:2}" ); }
shimrun "$T/raw-shim-new.txt"
JB=$(grep 'rebuild_seen' "$T/shim/jq.log" | grep -c 'input_filename')
JR=$(grep 'rebuild_seen' "$T/shim/jq.log" | grep -v 'input_filename' | grep -c -- '--arg b')
DD=$(grep -cE -- '-d 2026-10-(19|2)' "$T/shim/date.log")
# jq stops at the file that does not parse, so the batch runs once more on
# the files after it: 2 batched calls for this fixture, never one per row.
[ "$JB" = 2 ] && ok || bad "S5: two batched state jq calls (rebuild_seen + input_filename), got $JB"
[ "$JR" = 1 ] && ok || bad "S5: one per-row fallback jq (the file that does not parse), got $JR"
[ "$DD" = 0 ] && ok || bad "S5: no date -d of a ledger or attempt time, got $DD ($(grep -E -- '-d ' "$T/shim/date.log" | head -3 | tr '\n' ';'))"
cmp -s "$T/raw-old.txt" "$T/raw-shim-new.txt" && ok || bad "S5: the cache-off fast path gives the same rows"
# The shims count: the old path forks per row on the same fixture.
shimrun "$T/raw-shim-old.txt" "${OLD[@]}"
OJR=$(grep 'rebuild_seen' "$T/shim/jq.log" | grep -c -- '--arg b')
ODD=$(grep -cE -- '-d 2026-10-(19|2)' "$T/shim/date.log")
[ "$OJR" -ge 90 ] && ok || bad "S5: the old path's per-row state jq count is the control ($OJR, want >= 90)"
[ "$ODD" -ge 90 ] && ok || bad "S5: the old path's per-row date -d count is the control ($ODD, want >= 90)"

# ============================================================================
# S7. bdb_archived equals ba_path.
# ============================================================================
X="$T/arch"; mkdir -p "$X/builds-archive/202611" "$X/builds-archive/202610"
mkd() { mkdir -p "$X/builds-archive/$1"; }
mkd 202611/p-BH-1-1; mkd 202611/pool-p-BH-3-1; mkd 202611/fly-p-BH-4-1; mkd 202610/p-BH-6-1; mkd 202611/p-BH-7-1
{ printf '#archived_at\tdir\trelpath\tproject\tkey\tticket_id\tresult1\n'
  printf 't\tp-BH-1-1\t202611/p-BH-1-1\tp\tBH-1\t-\tPR_MERGED\n'
  printf 't\tp-BH-2-1\t202611/p-BH-2-1\tp\tBH-2\t-\tPR_MERGED\n'             # dir gone
  printf 't\tpool-p-BH-3-1\t202611/pool-p-BH-3-1\tp\tBH-3\t-\tPR_MERGED\n'
  printf 't\tfly-p-BH-4-1\t202611/fly-p-BH-4-1\tp\tBH-4\t-\tPR_MERGED\n'
  printf 't\tp-BH-5-1\t202611/p-BH-5-1\tp\tBH-5\t-\tMOVE_FAILED\n'
  printf 't\tp-BH-6-1\t202610/p-BH-6-1\tp\tBH-6\t-\tPR_MERGED\n'            # older row, dir exists
  printf 't\tp-BH-6-1\t202611/p-BH-6-1\tp\tBH-6\t-\tPR_MERGED\n'            # newest row, dir gone
  printf 't\tp-BH-7-1\t202611/p-BH-7-1\tp\tBH-7\t-\n'                       # 6 fields: not a row
  printf 't\tp-BH-23-1\t202611/p-BH-1-1\tp\tBH-23\t-\tPR_MERGED\n'
} > "$X/builds-archive/index.tsv"
mkd 202611/p-BH-5-1
s7=$( say() { :; }; H="$X"; . "$T/h/bin/lib/build-archive.sh" || exit 99
      . "$T/h/bin/blocked-resolver.d/bh-9952-discovery-batch.sh" || exit 99
      for n in p-BH-1-1 p-BH-2-1 p-BH-3-1 p-BH-4-1 p-BH-5-1 p-BH-6-1 p-BH-7-1 p-BH-2 p-BH-23-1 p-BH-8-1 pool-p-BH-1-1; do
        ba_path "$H" "$n" >/dev/null 2>&1; a=$?; bdb_archived "$n"; b=$?
        [ "$a" = "$b" ] || echo "MISMATCH $n ba_path=$a bdb_archived=$b"
        printf '%s:%s ' "$n" "$a"
      done)
case "$s7" in *MISMATCH*) bad "S7: $(printf '%s' "$s7" | grep MISMATCH | tr '\n' ';')" ;;
  *"p-BH-1-1:0 "*"p-BH-2-1:2 "*"p-BH-6-1:0 "*"p-BH-7-1:2 "*) ok ;;
  *) bad "S7: the table did not run as written ($s7)" ;; esac

printf 'pass 2 %s\n' "$P2"
printf 'BEFORE/AFTER: discovery= old path (cache and batch off) %ss, fast path pass 2 %ss\n' "${OLDDIS:-?}" "${NEWDIS:-?}"
printf 'br-discovery-scale.bh-9952: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
