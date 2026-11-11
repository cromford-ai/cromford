#!/bin/bash
# tests/br-discovery-incremental.bh-9467-test.sh — BH-9467 (#9369 fix 3):
# discovery is incremental. br_from_builds and br_from_rebuilds keep a per-path
# (signature, decision) cache and read only the paths that changed since the
# last tick. A one-PR run does not walk the build dirs or the queue rows.
#
# THE BUG (hub, 2026-11-09). Discovery took 906 s a tick (rebuilds:416,
# builds:403): every tick read every RESULT and every open record again.
#
#   I1  500 unchanged build dirs: tick 2 reads 0 RESULT files, same candidates
#   I1b 10 RESULTs rewritten with their mtime restored: tick 2 does not see
#       them (the proof that a skipped path is not read)
#   I2  3 RESULTs rewritten with a new mtime: read again, their rows emitted
#   I3  a marker file added: the dir is read again
#   I4  200 records whose last attempt is not a rebuild: tick 2 reads 0
#   I5  a rebuild wait is kept, and read again after BR_DISCOVERY_RECHECK_MIN;
#       RECHECK_MIN=0 never keeps it
#   I6  a fleet.conf change discards the cache with one line;
#       BR_DISCOVERY_CACHE=0 writes no file; BR_OPT_OFF gives the same rows;
#       a garbage cache row is ignored
#   I7  a one-PR run over 500 dirs and 200 records: builds and queue skipped,
#       the one record that names the PR is its candidate
#   I8  a one-PR run writes no cache file
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, end to end, against a
# scratch $HARNESS (the rig of tests/br-age-out.bh-9467-test.sh). The read
# counts are the fragment's own `discovery cache <source>:` line. No vendor is
# called (BH-7563): gh is a local stub, GH_TOKEN is empty.
# Run from anywhere: tests/br-discovery-incremental.bh-9467-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
STAMPAT() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
DAY=86400

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# The fragment under test, named by its rooted path so the orphan check sees it.
FRAG="$DIR/bin/blocked-resolver.d/bh-9467-discovery-cache.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh bin/lib/br/opt/profile.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning\n%s\n' "\${ADJ_VERDICT:-REJECT}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# THE gh STUB. The closed pull list answers [] (no PR here is closed), the open
# list is $T/openprs (tests/lib/gh-rest-stub.sh), and every call is logged.
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
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
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
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-p1"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
LOGF="$H/logs/blocked-resolver.log"
U="https://github.com/o/p1/pull"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
LOG() { cat "$LOGF" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
LASTPROF() { grep ' prof: ' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { LASTPROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
NLINES() { grep -c -- "$1" "$LOGF" 2>/dev/null; }
AGED() { grep -c -- "EVENT resolver_retired p1/p1-TK-$1 .*aged out" "$LOGF" 2>/dev/null; }
# BUILD <n> <RESULT line> <RESULT age secs> — a build dir p1-TK-<n>-<stamp>.
BUILD() { local d="$H/builds/p1-TK-$1-202610010000"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/RESULT"
          touch -d "@$((NOW - $3))" "$d/RESULT"; }
BDIR() { printf '%s' "$H/builds/p1-TK-$1-202610010000"; }
# REC <n> <json fields> — the ticket record p1-TK-<n>.json, one line.
REC() { mkdir -p "$ST/p1"; jq -c -n --arg k "p1-TK-$1" "{project:\"p1\",rkey:\$k,outcome:\"\",attempts:[]} + ($2)" > "$ST/p1/p1-TK-$1.json"; }
# OPR <num> <head ref> — one open-list item (an author harness_pr_list keeps).
OPR() {
  jq -nc --argjson n "$1" --arg r "$2" --arg u "$(ISO $((NOW - 600)))" \
    '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), title:"t", body:"",
      head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ref:$r}, base:{ref:"main"},
      draft:false, user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}'
}
CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          rm -f "$ST"/.disc-cache-* "$H/flags/blocked-resolver-observe" "$T/openprs" "$T/st-prlist" "$H/logs/ALERTS.log"
          : > "$T/gh.txt"; : > "$T/alerts.txt"; : > "$T/agent.txt"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"; : > "$ROWS"
          BRENV=(BR_PER_TICK=10 BR_PER_TICK_P1=1); }

[ -f "$FRAG" ] || bad "0: bin/blocked-resolver.d/bh-9467-discovery-cache.sh must exist"
# CLEANO — CLEAN, then observe mode (a rung writes nothing, so a rebuild rung
# cannot mark a fixture dir superseded between ticks) and one conductor row,
# so every tick has a candidate and writes its tick: line.
CLEANO() { CLEAN; touch "$H/flags/blocked-resolver-observe"
           printf 'o/p1#9001\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\tconflict-unresolvable: x\t%s/9001\n' "$((NOW - 7200))" "$U" >> "$ROWS"; }
CACHELINE() { grep "discovery cache $1: " "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
# MANY <from> <to> — build dirs p1-TK-<n>-<stamp> with a PR_CREATED or a
# PR_MERGED RESULT 3 days old: no row, ever.
MANY() { local n d
  for n in $(seq "$1" "$2"); do
    d="$H/builds/p1-TK-$n-202610010000"; mkdir -p "$d"
    if [ $((n % 2)) = 0 ]; then printf 'PR_CREATED %s/%s\n' "$U" "$n" > "$d/RESULT"; else printf 'PR_MERGED %s/%s\n' "$U" "$n" > "$d/RESULT"; fi
  done
  find "$H/builds" -mindepth 2 -maxdepth 2 -name RESULT -exec touch -d "@$((NOW - 3 * DAY))" {} +
}
# RECS <from> <to> — records whose last attempt is a fix round: no row, ever.
RECS() { local n; mkdir -p "$ST/p1"
  for n in $(seq "$1" "$2"); do
    printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","attempts":[{"at":"%s","action":"fix-round","reason":"x","detail":"y"}],"updated":"%s"}\n' \
      "$n" "$(STAMPAT $((NOW - DAY)))" "$(STAMPAT $((NOW - DAY)))" > "$ST/p1/p1-TK-$n.json"
  done; }

# ============================================================================
# I1. 500 unchanged build dirs.
# ============================================================================
CLEANO
MANY 1001 1500
echo '[]' > "$T/openprs"
RUN p1
[ "$(CACHELINE builds)" = "discovery cache builds: 500 path(s), 0 unchanged and skipped, 500 read (500 cache rows written)" ] && ok \
  || bad "I1: tick 1 reads all 500 ($(CACHELINE builds))"
[ -s "$ST/.disc-cache-builds-p1.tsv" ] && ok || bad "I1: tick 1 writes the cache file"
C1=$(LFIELD candidates); R1=$(PFIELD discovery_rows)
[ "$C1" = 1 ] && ok || bad "I1: the fixture has 1 candidate, the conductor row ($C1)"
: > "$LOGF"
RUN p1
[ "$(CACHELINE builds)" = "discovery cache builds: 500 path(s), 500 unchanged and skipped, 0 read (500 cache rows written)" ] && ok \
  || bad "I1: THE BUG: tick 2 reads 0 RESULT files ($(CACHELINE builds))"
[ "$(LFIELD candidates)" = "$C1" ] && [ "$(PFIELD discovery_rows)" = "$R1" ] && ok \
  || bad "I1: the candidates are unchanged ($C1/$R1 -> $(LFIELD candidates)/$(PFIELD discovery_rows))"

# I1b. 10 RESULTs rewritten to BUILD_DEAD with the mtime restored: not read.
for n in $(seq 1001 1010); do
  f="$H/builds/p1-TK-$n-202610010000/RESULT"; touch -r "$f" "$T/ref"
  printf 'BUILD_DEAD x\n' > "$f"; touch -r "$T/ref" "$f"
done
: > "$LOGF"
RUN p1
[ "$(CACHELINE builds)" = "discovery cache builds: 500 path(s), 500 unchanged and skipped, 0 read (500 cache rows written)" ] && ok \
  || bad "I1b: the rewritten-but-unchanged RESULTs are not read ($(CACHELINE builds))"
[ "$(LFIELD candidates)" = "$C1" ] && ok || bad "I1b: no row is emitted for them ($C1 -> $(LFIELD candidates))"

# I2. 3 RESULTs rewritten with a new mtime (2 h old: past the 90-minute floor).
for n in 1101 1102 1103; do
  f="$H/builds/p1-TK-$n-202610010000/RESULT"; printf 'BUILD_DEAD x\n' > "$f"; touch -d "@$((NOW - 7200))" "$f"
done
: > "$LOGF"
RUN p1
[ "$(CACHELINE builds)" = "discovery cache builds: 500 path(s), 497 unchanged and skipped, 3 read (497 cache rows written)" ] && ok \
  || bad "I2: exactly the 3 changed RESULTs are read ($(CACHELINE builds))"
[ "$(LFIELD candidates)" = $((C1 + 3)) ] && ok || bad "I2: their 3 rows are emitted ($C1 -> $(LFIELD candidates))"
# An emitted row is volatile: it is read again on the next tick.
: > "$LOGF"
RUN p1
[ "$(CACHELINE builds)" = "discovery cache builds: 500 path(s), 497 unchanged and skipped, 3 read (497 cache rows written)" ] && ok \
  || bad "I2: an emitted row is read again next tick ($(CACHELINE builds))"

# I3. A marker file in one of them: the dir is read again, and is now a skip.
touch "$H/builds/p1-TK-1101-202610010000/.blocked-resolver-abandoned"
: > "$LOGF"
RUN p1
[ "$(LFIELD candidates)" = $((C1 + 2)) ] && ok || bad "I3: the marked dir is read again and emits no row ($(LFIELD candidates))"
: > "$LOGF"
RUN p1
[ "$(CACHELINE builds)" = "discovery cache builds: 500 path(s), 498 unchanged and skipped, 2 read (498 cache rows written)" ] && ok \
  || bad "I3: the marked dir is a cached skip from the next tick ($(CACHELINE builds))"

# ============================================================================
# I4. 200 records whose last attempt is a fix round.
# ============================================================================
CLEANO
RECS 2001 2200
echo '[]' > "$T/openprs"
RUN p1
[ "$(CACHELINE rebuilds)" = "discovery cache rebuilds: 200 path(s), 0 unchanged and skipped, 200 read (200 cache rows written)" ] && ok \
  || bad "I4: tick 1 reads all 200 records ($(CACHELINE rebuilds))"
: > "$LOGF"
RUN p1
[ "$(CACHELINE rebuilds)" = "discovery cache rebuilds: 200 path(s), 200 unchanged and skipped, 0 read (200 cache rows written)" ] && ok \
  || bad "I4: tick 2 reads 0 records ($(CACHELINE rebuilds))"
# A record written in place (new size and mtime) is read again.
jq -c '.attempts += [{at:"x",action:"fix-round",reason:"x",detail:"again"}]' "$ST/p1/p1-TK-2001.json" > "$T/r.json" && mv "$T/r.json" "$ST/p1/p1-TK-2001.json"
: > "$LOGF"
RUN p1
[ "$(CACHELINE rebuilds)" = "discovery cache rebuilds: 200 path(s), 199 unchanged and skipped, 1 read (200 cache rows written)" ] && ok \
  || bad "I4: a rewritten record is read again ($(CACHELINE rebuilds))"

# ============================================================================
# I5. A rebuild wait: the fresh build has no result yet.
# ============================================================================
CLEANO
mkdir -p "$ST/p1"
printf '{"project":"p1","rkey":"p1-TK-3001","outcome":"","attempts":[{"at":"%s","action":"rebuild-fresh","reason":"x","detail":"enqueued"}],"updated":"%s","parked_url":"-"}\n' \
  "$(STAMPAT $((NOW - 3600)))" "$(STAMPAT $((NOW - 3600)))" > "$ST/p1/p1-TK-3001.json"
echo '[]' > "$T/openprs"
RUN p1
grep -qE "p1-TK-3001\.json	[^	]+	wait	[0-9]+$" "$ST/.disc-cache-rebuilds-p1.tsv" && ok \
  || bad "I5: the wait is noted ($(cat "$ST/.disc-cache-rebuilds-p1.tsv" 2>/dev/null))"
: > "$LOGF"
RUN p1
[ "$(CACHELINE rebuilds)" = "discovery cache rebuilds: 1 path(s), 1 unchanged and skipped, 0 read (1 cache rows written)" ] && ok \
  || bad "I5: a fresh wait is kept ($(CACHELINE rebuilds))"
# Age the noted epoch by 31 minutes: the record is read again.
awk -F'\t' -v OFS='\t' -v e="$((NOW - 31 * 60))" 'NR > 1 { $4 = e } { print }' "$ST/.disc-cache-rebuilds-p1.tsv" > "$T/c.tsv" \
  && mv "$T/c.tsv" "$ST/.disc-cache-rebuilds-p1.tsv"
: > "$LOGF"
RUN p1
[ "$(CACHELINE rebuilds)" = "discovery cache rebuilds: 1 path(s), 0 unchanged and skipped, 1 read (1 cache rows written)" ] && ok \
  || bad "I5: a wait older than BR_DISCOVERY_RECHECK_MIN is read again ($(CACHELINE rebuilds))"
: > "$LOGF"
BRENV+=(BR_DISCOVERY_RECHECK_MIN=0)
RUN p1
[ "$(CACHELINE rebuilds)" = "discovery cache rebuilds: 1 path(s), 0 unchanged and skipped, 1 read (1 cache rows written)" ] && ok \
  || bad "I5: RECHECK_MIN=0 never keeps a wait ($(CACHELINE rebuilds))"
BRENV+=(BR_DISCOVERY_RECHECK_MIN=x9)
: > "$LOGF"
RUN p1
[ "$(NLINES "BR_DISCOVERY_RECHECK_MIN is 'x9', not a number — the fallback 30 is used")" = 1 ] && ok \
  || bad "I5: a non-number knob is said once (log: $(LOG | grep -i RECHECK))"

# ============================================================================
# I6. Header, knob off, module off, garbage rows.
# ============================================================================
CLEANO
MANY 1001 1100
for n in 1101 1102; do d="$H/builds/p1-TK-$n-202610010000"; mkdir -p "$d"; printf 'BUILD_DEAD x\n' > "$d/RESULT"; touch -d "@$((NOW - 7200))" "$d/RESULT"; done
RECS 2001 2050
echo '[]' > "$T/openprs"
RUN p1
CON=$(LFIELD candidates)
[ "$CON" = 3 ] && ok || bad "I6: the fixture has 3 candidates (the conductor row and 2 BUILD_DEAD dirs): $CON"
touch -d "@$((NOW + 5))" "$H/fleet.conf"
: > "$LOGF"
RUN p1
[ "$(NLINES 'discovery cache builds: the cache header does not match')" = 1 ] && ok \
  || bad "I6: a fleet.conf change discards the builds cache with one line (log: $(LOG | grep 'discovery cache'))"
[ "$(CACHELINE builds)" = "discovery cache builds: 102 path(s), 0 unchanged and skipped, 102 read (100 cache rows written)" ] && ok \
  || bad "I6: every path is read after the discard ($(CACHELINE builds))"
# A garbage row and a truncated row are ignored; their paths are read again.
printf 'garbage line\n' >> "$ST/.disc-cache-builds-p1.tsv"
sed -i -e "s#^$H/builds/p1-TK-1001-202610010000\t.*#$H/builds/p1-TK-1001-202610010000\t1.0:2.0#" \
       -e "s#^$H/builds/p1-TK-1002-202610010000\t.*#$H/builds/p1-TK-1002-202610010000\tbad#" "$ST/.disc-cache-builds-p1.tsv"
: > "$LOGF"
RUN p1
[ "$(CACHELINE builds)" = "discovery cache builds: 102 path(s), 98 unchanged and skipped, 4 read (100 cache rows written)" ] && ok \
  || bad "I6: a bad row is ignored and its path read ($(CACHELINE builds))"
rm -f "$ST"/.disc-cache-*
: > "$LOGF"
BRENV+=(BR_DISCOVERY_CACHE=0)
RUN p1
ls "$ST"/.disc-cache-* >/dev/null 2>&1 && bad "I6: BR_DISCOVERY_CACHE=0 writes no cache file" || ok
[ "$(NLINES 'discovery cache')" = 0 ] && ok || bad "I6: BR_DISCOVERY_CACHE=0 says no cache line"
[ "$(LFIELD candidates)" = "$CON" ] && ok || bad "I6: the cache off finds the same candidates ($CON vs $(LFIELD candidates))"
BRENV=(BR_PER_TICK=10 BR_PER_TICK_P1=1 BR_OPT_OFF=bh-9467-discovery-cache)
rm -f "$ST"/.disc-cache-*
: > "$LOGF"
RUN p1
[ "$(LFIELD candidates)" = "$CON" ] && [ "$(NLINES 'discovery cache')" = 0 ] && ! ls "$ST"/.disc-cache-* >/dev/null 2>&1 && ok \
  || bad "I6: BR_OPT_OFF=bh-9467-discovery-cache finds the same candidates ($CON vs $(LFIELD candidates))"

# ============================================================================
# I7 + I8. A one-PR run over 500 dirs and 200 records: builds and queue are
#     skipped, the one record that names the PR is found, no cache file.
# ============================================================================
CLEANO
MANY 1001 1500
RECS 2001 2200
printf '{"project":"p1","rkey":"p1-TK-555","outcome":"","attempts":[{"at":"%s","action":"rebuild-fresh-failed","reason":"x","detail":"rc 1"}],"updated":"%s","parked_url":"%s/555","parked_rec":"-"}\n' \
  "$(STAMPAT $((NOW - 3600)))" "$(STAMPAT $((NOW - 3600)))" "$U" > "$ST/p1/p1-TK-555.json"
# A record of PR #5550 must not answer for #555.
printf '{"project":"p1","rkey":"p1-TK-5550","outcome":"","attempts":[{"at":"%s","action":"rebuild-fresh-failed","reason":"x","detail":"rc 1"}],"updated":"%s","parked_url":"%s/5550","parked_rec":"-"}\n' \
  "$(STAMPAT $((NOW - 3600)))" "$(STAMPAT $((NOW - 3600)))" "$U" > "$ST/p1/p1-TK-5550.json"
echo '[]' > "$T/openprs"
BRENV+=(BR_ONLY_PR=o/p1#555)
RUN p1
[ "$(NLINES 'one-PR run for o/p1#555: builds and queue sources skipped (their rows carry no PR url)')" = 1 ] && ok \
  || bad "I7: the skip line (log: $(LOG | grep 'one-PR' | head -3))"
[ "$(NLINES 'one-PR run for o/p1#555: 1 of 1 candidate(s) are its rows')" = 1 ] && ok \
  || bad "I7: the PR's record is its one candidate (log: $(LOG | grep 'one-PR' | head -3))"
[ "$(NLINES 'discovery cache')" = 0 ] && ok || bad "I7: a one-PR run reads no cache (log: $(LOG | grep 'discovery cache'))"
LASTPROF | grep -q 'discovery_src=rebuilds:[0-9]*,conductor:[0-9]*,queue:0,builds:0,' && ok \
  || bad "I7: discovery_src still names builds and queue, at 0 ($(LASTPROF))"
ls "$ST"/.disc-cache-* >/dev/null 2>&1 && bad "I8: a one-PR run writes no cache file ($(ls "$ST"/.disc-cache-*))" || ok

# ============================================================================
# Function case: bdc_one_pr_files — a grep that does not read falls back.
# ============================================================================
(
  say() { printf '%s\n' "$*" >> "$T/fsay.txt"; }
  # shellcheck source=bin/blocked-resolver.d/bh-9467-discovery-cache.sh
  . "$FRAG" || exit 1
  ST="$T/fst"; ONLY=p1; mkdir -p "$ST/p1"
  printf '{"parked_url":"https://github.com/o/p1/pull/7"}\n' > "$ST/p1/a.json"
  printf '{"parked_url":"https://github.com/o/p1/pull/77"}\n' > "$ST/p1/b.json"
  r=""
  a=(); BR_ONLY_PR="o/p1#7" bdc_one_pr_files a && [ "${#a[@]}" = 1 ] && [ "${a[0]}" = "$ST/p1/a.json" ] && r="${r}a"
  a=(x); BR_ONLY_PR="o/p1#8" bdc_one_pr_files a && [ "${#a[@]}" = 0 ] && r="${r}b"
  a=(); bdc_one_pr_files a || r="${r}c"                  # not a one-PR run
  grep() { return 2; }
  a=(); BR_ONLY_PR="o/p1#7" bdc_one_pr_files a || r="${r}d"
  unset -f grep
  [ "$r" = abcd ] || { echo "bdc_one_pr_files: $r"; exit 1; }
  grep -q 'the record grep did not read (rc 2) — every record is read' "$T/fsay.txt"
) && ok || bad "F: bdc_one_pr_files (one match, no match, not a one-PR run, a grep that does not read)"

echo "br-discovery-incremental.bh-9467: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
