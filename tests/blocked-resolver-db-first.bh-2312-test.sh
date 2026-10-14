#!/bin/bash
# tests/blocked-resolver-db-first.bh-2312-test.sh — the blocked resolver reads
# its builds of record from the jobs ledger (BH-2349, slice 3 of BH-2312).
#
# Two sources in bin/blocked-resolver.sh used to learn "which builds ended how"
# by globbing builds/*/RESULT on the hub alone: br_from_builds (the rebuild
# candidates) and br_from_rebuilds (did the fresh rebuild this lane started
# finish). A build whose record never reached the hub was invisible to both.
# They now read bin/lib/builds-of-record.sh's bor_union first:
#
#   B1-B6 br_from_builds admits a LEDGER-ONLY record through the same reason
#         case and floors, and never one the resolver already acted on
#   B7    outage (rc 1): byte-identical to the lib-absent glob path
#   R1-R4 br_from_rebuilds reads ledger updated_at instead of RESULT mtime
#   R5    outage (rc 1): identical to the lib-absent glob path
#   M1-M2 D1: with the bor_union call mutated to `false` B1 and R1 go red
#   P1-P4 br_park_time dates a ledger-only park from its ledger row, and a
#         ledger that does not answer is UNKNOWN (rc 2), never "not merged"
#   E1-E2 the REAL lane end to end (D2): the ledger row lands a rebuild, and a
#         ledger-only park is enqueued through br_rebuild_fresh
#   E3    the REAL lane: a ledger-only park whose ticket merged after it is
#         resolved-merged and NOT rebuilt (the 2026-09-14 guard, review B1)
#
# HOW IT DRIVES. §B/§R extract the shipped function text from
# bin/blocked-resolver.sh and run it with the REAL bin/jobs-client.sh, the REAL
# lib and the REAL record layer (bin/lib/br/record.sh); the only stub is `curl`
# (the worker), answering kind=result / kind=pr_url from fixture JSON, the same
# shape as tests/builds-of-record.bh-2312-test.sh. §E runs the whole lane.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-db-first.bh-2312-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"; FIX="$T/fix"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/br" "$H/builds" "$H/state/blocked-resolver" \
         "$H/flags" "$T/fakebin" "$FIX"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/builds-of-record.sh" "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/br/*.sh "$H/bin/lib/br/"
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-").
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
ST="$H/state/blocked-resolver"

# The stub worker. WORKER_DOWN=1 is a transport failure (curl rc 7).
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
printf 'GET %s\n' "$URL" >> "$REQ_SINK"
[ "${WORKER_DOWN:-0}" = 1 ] && exit 7
F=""
case "$URL" in
  *kind=result\&*) F="$FIX/result" ;;
  *kind=pr_url\&*) F="$FIX/pr_url" ;;
esac
if [ -n "$F" ] && [ -f "$F" ]; then printf '%s\n200\n' "$(cat "$F")"; exit 0; fi
printf '{"artifacts":[]}\n200\n'
STUB
chmod +x "$T/fakebin/curl"

# BH-6461: the key family moved to bin/lib/br/keys.sh; the corpus is the driver
# plus bin/lib/br/*.sh (tests/lib/br-corpus.sh), so the extraction finds it there.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
# The code under test: the lane's own function text.
extract() { # extract <out-file> [sed-expr applied to the extracted text]
  : > "$1"
  for fn in br_from_builds br_from_rebuilds br_rebuild_outcome br_key_shape br_park_time; do
    awk -v f="^$fn\\\\(\\\\) \\\\{" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$1"
  done
  [ -z "${2:-}" ] || sed -i "$2" "$1"
}
extract "$T/fn.sh"
grep -q '^br_from_builds() {' "$T/fn.sh" && grep -q '^br_from_rebuilds() {' "$T/fn.sh" \
  && ok || bad "setup: could not extract br_from_builds/br_from_rebuilds"

# drive <snippet>: the snippet runs with the real client, the lib (unless
# NO_LIB=1) and the record layer sourced over the scratch harness.
drive() {
  ( export PATH="$T/fakebin:$PATH" H="$H" HARNESS="$H" ST="$ST" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=test-box \
           FIX="$FIX" JOBS_RETRIES=0 REQ_SINK="$T/req.txt" WORKER_DOWN="${WORKER_DOWN:-0}"
    ONLY="${ONLY:-}"; OBSERVE=0; PER_TICK=10; EFF_PER_TICK=10
    # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh" || exit 99
    # shellcheck source=/dev/null
    [ "${NO_LIB:-0}" = 1 ] || . "$H/bin/lib/builds-of-record.sh" || exit 99
    # shellcheck source=/dev/null
    . "$H/bin/lib/br/record.sh" && . "$H/bin/lib/rebuild-ledger.sh" || exit 99
    # shellcheck source=/dev/null
    . "${FN:-$T/fn.sh}" || exit 99
    STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
    say() { printf '%s\n' "$*" >> "$T/say.txt"; }
    flag_on() { [ -f "$H/flags/$1" ]; }
    eval "$1" ) 2>/dev/null
}
builds()   { drive br_from_builds | sort -u; }
rebuilds() { drive br_from_rebuilds; }

res_row() { # res_row <job> <ref> <updated_at> <build_dir> [key]
  jq -cn --arg j "$1" --arg r "$2" --arg u "$3" --arg d "$4" --arg k "${5:-}" \
    '{job_id:$j, artifact_ref:$r, box:"box1", ticket_id:$k, updated_at:$u,
      detail:({build_dir:$d, job_status:"done"} + (if $k == "" then {} else {key:$k} end) | tojson)}'
}
feed() { # feed <file> <row-json>...
  local f="$1"; shift
  printf '%s\n' "$@" | jq -cs '{artifacts: .}' > "$FIX/$f"
}
local_rec() { # local_rec <dir-name> <age-seconds> <line1>
  mkdir -p "$H/builds/$1"
  printf '%s\n' "$3" > "$H/builds/$1/RESULT"
  touch -d "@$((NOW - $2))" "$H/builds/$1/RESULT"
}
state() { # state <rkey> <json>
  mkdir -p "$ST/tproj"; printf '%s\n' "$2" > "$ST/tproj/$1.json"
}
reset() {
  rm -f "$FIX"/* "$T/req.txt" "$T/say.txt"
  scratch_rm "$H/builds"; scratch_rm "$ST"; mkdir -p "$H/builds" "$ST"
}
TAB=$'\t'
B7DIR=tproj-BH-7-20260925T0000
ROW_B1="build${TAB}tproj${TAB}tproj-BH-7${TAB}rescue-giving-up${TAB}-${TAB}-${TAB}BH-7${TAB}-"

# ═════════════════════════════════════════════════════════════════════════════
# B1 — a ledger-only REVIEW_BLOCKED record, 7 h old, becomes a candidate
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
GOT=$(builds)
[ "$GOT" = "$ROW_B1" ] && ok || bad "B1: one ledger-only rescue-giving-up row expected, got '$GOT'"
grep -q 'kind=result&project=tproj' "$T/req.txt" 2>/dev/null && ok \
  || bad "B1: br_from_builds must ask the ledger for tproj's results"

# The 6-hour review backstop: the same row 2 h old is still review-rescue's.
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 7200)" "$B7DIR" BH-7)"
[ -z "$(builds)" ] && ok || bad "B1: a ledger-only REVIEW_BLOCKED under 6 h must wait, got '$(builds)'"

# ═════════════════════════════════════════════════════════════════════════════
# B2 — PR_CREATE_FAILED through the same case; the 90-minute floor
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J7 'PR_CREATE_FAILED: gh said no' "$(ISO 7200)" "$B7DIR" BH-7)"
GOT=$(builds)
[ "$GOT" = "build${TAB}tproj${TAB}tproj-BH-7${TAB}pr-create-failed${TAB}-${TAB}-${TAB}BH-7${TAB}-" ] \
  && ok || bad "B2: a 2 h ledger-only PR_CREATE_FAILED must be pr-create-failed, got '$GOT'"
feed result "$(res_row J7 'PR_CREATE_FAILED: gh said no' "$(ISO 1800)" "$B7DIR" BH-7)"
[ -z "$(builds)" ] && ok || bad "B2: a 30-minute ledger-only record must wait out the floor, got '$(builds)'"
feed result "$(res_row J7 'PR_CREATE_FAILED: gh said no' "not-a-date" "$B7DIR" BH-7)"
[ -z "$(builds)" ] && ok || bad "B2: an unparseable updated_at must fail closed, got '$(builds)'"

# ═════════════════════════════════════════════════════════════════════════════
# B3 — the build_dir is already in rebuild_seen (bare and pool- spelling)
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
state tproj-BH-7 "{\"outcome\":\"\",\"attempts\":[],\"rebuild_seen\":[\"$B7DIR\"]}"
[ -z "$(builds)" ] && ok || bad "B3: a build_dir in rebuild_seen must not be re-offered, got '$(builds)'"
state tproj-BH-7 "{\"outcome\":\"\",\"attempts\":[],\"rebuild_seen\":[\"pool-$B7DIR\"]}"
[ -z "$(builds)" ] && ok || bad "B3: the pool- spelling in rebuild_seen must count too, got '$(builds)'"
state tproj-BH-7 '{"outcome":"","attempts":[],"rebuild_seen":["tproj-BH-7-20260101T0000"]}'
[ "$(builds)" = "$ROW_B1" ] && ok || bad "B3: another build's seen entry must not hide this one, got '$(builds)'"

# ═════════════════════════════════════════════════════════════════════════════
# B4 — the ladder already acted after this record (the superseded stand-in)
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
state tproj-BH-7 "$(jq -cn --arg at "$(ISO 3600)" '{outcome:"",attempts:[{at:$at,action:"rebuild-fresh"}]}')"
[ -z "$(builds)" ] && ok || bad "B4: an attempt newer than the record must stop the re-offer, got '$(builds)'"
# A hold line is not a ladder attempt: an older rebuild plus a newer `held`
# still reads as "acted before this record".
state tproj-BH-7 "$(jq -cn --arg a "$(ISO 30000)" --arg b "$(ISO 60)" \
  '{outcome:"",attempts:[{at:$a,action:"rebuild-fresh"},{at:$b,action:"held"}]}')"
[ "$(builds)" = "$ROW_B1" ] && ok || bad "B4: a held line must not count as acting, got '$(builds)'"

# ═════════════════════════════════════════════════════════════════════════════
# B5 — a ledger row that also has a local dir belongs to the glob loop
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
local_rec "pool-$B7DIR" 25200 'REVIEW_BLOCKED review said no'
: > "$H/builds/pool-$B7DIR/.blocked-resolver-superseded"
[ -z "$(builds)" ] && ok || bad "B5: a superseded local dir must not come back through the ledger, got '$(builds)'"
rm -f "$H/builds/pool-$B7DIR/.blocked-resolver-superseded"
GOT=$(builds)
[ "$GOT" = "build${TAB}tproj${TAB}tproj-BH-7${TAB}rescue-giving-up${TAB}-${TAB}$H/builds/pool-$B7DIR${TAB}BH-7${TAB}-" ] \
  && ok || bad "B5: exactly one row, carrying the local record, expected, got '$GOT'"

# ═════════════════════════════════════════════════════════════════════════════
# B6 — $ONLY, and the terminals that are not rebuild candidates
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
[ -z "$(ONLY=other builds)" ] && ok || bad "B6: ONLY=other must not offer tproj, got '$(ONLY=other builds)'"
grep -q 'project=tproj' "$T/req.txt" 2>/dev/null \
  && bad "B6: ONLY=other must not even ask the ledger for tproj" || ok
for line in 'ABANDONED_TIMEOUT reaped at 90m' 'PR_CREATED https://github.com/o/tproj/pull/5' \
            'RESULT_UNVERIFIED PR_CREATED https://github.com/o/tproj/pull/5' 'PR_MERGED x'; do
  feed result "$(res_row J7 "$line" "$(ISO 25200)" "$B7DIR" BH-7)"
  [ -z "$(builds)" ] && ok || bad "B6: a ledger-only '$line' must not be offered, got '$(builds)'"
done
# A row with no job id is the lib's local-only shape; the glob owns those.
feed result "$(res_row - 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
[ -z "$(builds)" ] && ok || bad "B6: a row with job_id '-' is not ledger-only, got '$(builds)'"

# ═════════════════════════════════════════════════════════════════════════════
# B7 — outage: the output is the glob path's, byte for byte
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J8 'REVIEW_BLOCKED review said no' "$(ISO 25200)" tproj-BH-8-20260925T0000 BH-8)"
local_rec "pool-$B7DIR" 7200 'PR_CREATE_FAILED: gh said no'
local_rec tproj-BH-6-20260925T0000 25200 'BUILD_DEAD the lane died'
A=$(WORKER_DOWN=1 drive br_from_builds); B=$(NO_LIB=1 drive br_from_builds)
{ [ -n "$A" ] && [ "$A" = "$B" ]; } && ok || bad "B7: outage output must equal the lib-absent output: '$A' vs '$B'"
grep -q 'BH-8' <<<"$A" && bad "B7: an outage must not surface the (unreadable) ledger row" || ok
# And with the worker up, the ledger adds its row on top of the same glob rows.
C=$(drive br_from_builds)
[ "$(grep -v 'BH-8' <<<"$C")" = "$B" ] && grep -q "${TAB}BH-8${TAB}" <<<"$C" && ok \
  || bad "B7: worker up must be the glob rows plus the ledger-only row, got '$C'"

# ═════════════════════════════════════════════════════════════════════════════
# R — the rebuild-outcome poll
# ═════════════════════════════════════════════════════════════════════════════
R9DIR=tproj-BH-9-20260925T1200
AT=$(ISO 3600)
r_state() { # r_state [seen-json-array]
  state tproj-BH-9 "$(jq -cn --arg at "$AT" --argjson s "${1:-[]}" \
    '{project:"tproj",rkey:"tproj-BH-9",outcome:"",rebuilds:1,attempts:[{at:$at,action:"rebuild-fresh"}],rebuild_seen:$s}')"
}
RSTATE() { cat "$ST/tproj/tproj-BH-9.json" 2>/dev/null; }

# R1 — a ledger row newer than the attempt, no local dir: the rebuild landed.
reset; r_state
feed result "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" "$R9DIR" BH-9)"
GOT=$(rebuilds)
[ -z "$GOT" ] && ok || bad "R1: a landed rebuild prints no candidate, got '$GOT'"
[ "$(RSTATE | jq -r '.attempts[-1].action')" = rebuild-landed ] && ok \
  || bad "R1: rebuild-landed must be recorded, got $(RSTATE | jq -c '.attempts')"
RSTATE | jq -e --arg d "$R9DIR" '.rebuild_seen | index($d)' >/dev/null && ok \
  || bad "R1: rebuild_seen must gain $R9DIR, got $(RSTATE | jq -c '.rebuild_seen')"

# R1b — two rows newer than the attempt: the newest wins, whatever the feed order.
reset; r_state
feed result "$(res_row J8 'BUILD_DEAD the lane died' "$(ISO 600)" tproj-BH-9-20260925T1600 BH-9)" \
            "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" "$R9DIR" BH-9)"
GOT=$(rebuilds)
[ "$GOT" = "rebuild${TAB}tproj${TAB}tproj-BH-9${TAB}rebuild-build-dead${TAB}-${TAB}-${TAB}BH-9${TAB}-" ] \
  && ok || bad "R1b: the newest of two rows must be the outcome, got '$GOT'"
feed result "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" "$R9DIR" BH-9)" \
            "$(res_row J8 'BUILD_DEAD the lane died' "$(ISO 600)" tproj-BH-9-20260925T1600 BH-9)"
reset_state_only() { scratch_rm "$ST"; mkdir -p "$ST"; }
reset_state_only; r_state
GOT=$(rebuilds)
[ "$GOT" = "rebuild${TAB}tproj${TAB}tproj-BH-9${TAB}rebuild-build-dead${TAB}-${TAB}-${TAB}BH-9${TAB}-" ] \
  && ok || bad "R1b: the newest must win when the feed hands it second, got '$GOT'"

# R2 — the same row OLDER than the attempt is a previous build: ignored.
reset; r_state
feed result "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 4200)" "$R9DIR" BH-9)"
rebuilds >/dev/null
[ "$(RSTATE | jq '.attempts | length')" = 1 ] && [ "$(RSTATE | jq '.rebuild_seen | length')" = 0 ] && ok \
  || bad "R2: a row older than the attempt must not be consumed, got $(RSTATE)"

# R2b — BH-23 is not BH-234.
reset
state tproj-BH-23 "$(jq -cn --arg at "$AT" '{outcome:"",attempts:[{at:$at,action:"rebuild-fresh"}]}')"
feed result "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" tproj-BH-234-20260925T1200 BH-234)"
rebuilds >/dev/null
[ "$(jq '.attempts | length' "$ST/tproj/tproj-BH-23.json")" = 1 ] && ok \
  || bad "R2b: BH-234's record must not answer BH-23's rebuild, got $(cat "$ST/tproj/tproj-BH-23.json")"

# R3 — already consumed: in rebuild_seen.
reset; r_state "[\"$R9DIR\"]"
feed result "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" "$R9DIR" BH-9)"
rebuilds >/dev/null
[ "$(RSTATE | jq '.attempts | length')" = 1 ] && ok \
  || bad "R3: a build_dir in rebuild_seen must not be consumed twice, got $(RSTATE | jq -c '.attempts')"
reset; r_state "[\"pool-$R9DIR\"]"
feed result "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" "$R9DIR" BH-9)"
rebuilds >/dev/null
[ "$(RSTATE | jq '.attempts | length')" = 1 ] && ok \
  || bad "R3: the pool- spelling in rebuild_seen must count too, got $(RSTATE | jq -c '.attempts')"

# R4 — local-only record, empty ledger (rc 2): mtime is honoured.
reset; r_state
local_rec "$R9DIR" 3000 'BUILD_DEAD the lane died'
GOT=$(rebuilds)
[ "$GOT" = "rebuild${TAB}tproj${TAB}tproj-BH-9${TAB}rebuild-build-dead${TAB}-${TAB}$H/builds/$R9DIR${TAB}BH-9${TAB}-" ] \
  && ok || bad "R4: a local record newer than the attempt must be a rebuild-build-dead row, got '$GOT'"
reset; r_state
local_rec "$R9DIR" 4200 'BUILD_DEAD the lane died'
[ -z "$(rebuilds)" ] && ok || bad "R4: a local record older than the attempt must be ignored"
# R4b — superseded / abandoned local dirs.
for m in .blocked-resolver-superseded .blocked-resolver-abandoned; do
  reset; r_state
  local_rec "$R9DIR" 3000 'BUILD_DEAD the lane died'; : > "$H/builds/$R9DIR/$m"
  [ -z "$(rebuilds)" ] && ok || bad "R4b: a $m dir must never be the outcome, got '$(rebuilds)'"
done
# R4c — a ledger row WITH a local dir: the local RESULT line wins (pr-url-reconcile
# rewrites line 1 there), and the dir is the record.
reset; r_state
feed result "$(res_row J9 'PR_CREATE_FAILED: stale' "$(ISO 3000)" "$R9DIR" BH-9)"
local_rec "pool-$R9DIR" 3000 'BUILD_DEAD the lane died'
GOT=$(rebuilds)
[ "$GOT" = "rebuild${TAB}tproj${TAB}tproj-BH-9${TAB}rebuild-build-dead${TAB}-${TAB}$H/builds/pool-$R9DIR${TAB}BH-9${TAB}-" ] \
  && ok || bad "R4c: the local RESULT line and dir must win over the ledger line, got '$GOT'"

# R5 — outage: identical to the lib-absent glob path.
reset; r_state; local_rec "$R9DIR" 3000 'BUILD_DEAD the lane died'
A=$(WORKER_DOWN=1 drive br_from_rebuilds)
reset; r_state; local_rec "$R9DIR" 3000 'BUILD_DEAD the lane died'
B=$(NO_LIB=1 drive br_from_rebuilds)
{ [ -n "$A" ] && [ "$A" = "$B" ]; } && ok || bad "R5: outage output must equal the lib-absent output: '$A' vs '$B'"
# The ledger is asked once per project per call, however many state files share it.
reset; r_state
state tproj-BH-10 "$(jq -cn --arg at "$AT" '{outcome:"",attempts:[{at:$at,action:"rebuild-fresh"}]}')"
rebuilds >/dev/null
[ "$(grep -c 'kind=result' "$T/req.txt" 2>/dev/null)" = 1 ] && ok \
  || bad "R5: one result feed read per project per call expected, got $(grep -c 'kind=result' "$T/req.txt" 2>/dev/null)"

# ═════════════════════════════════════════════════════════════════════════════
# M — D1 mutation: without the bor_union read, B1 and R1 go red
# ═════════════════════════════════════════════════════════════════════════════
extract "$T/fn-mut.sh" 's/bor_union "[^"]*"/false/g'
grep -q 'bor_union "' "$T/fn-mut.sh" && bad "M: the mutation left a bor_union call behind" || ok
reset
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
[ -z "$(FN="$T/fn-mut.sh" drive br_from_builds)" ] && ok \
  || bad "M1: with bor_union mutated away B1 must produce nothing (else B1 is vacuous)"
reset; r_state
feed result "$(res_row J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" "$R9DIR" BH-9)"
FN="$T/fn-mut.sh" drive br_from_rebuilds >/dev/null
[ "$(RSTATE | jq '.attempts | length')" = 1 ] && ok \
  || bad "M2: with bor_union mutated away R1 must consume nothing (else R1 is vacuous)"

# ═════════════════════════════════════════════════════════════════════════════
# P — dating a ledger-only park (the merged guard's clock, review B1)
# ═════════════════════════════════════════════════════════════════════════════
# P1 — no RESULT, no queue row, no state file: the ledger row's updated_at.
reset
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)"
GOT=$(drive 'br_park_time tproj tproj-BH-7 BH-7 -; echo "rc=$?"')
[ "$GOT" = "$((NOW - 25200))
rc=0" ] && ok || bad "P1: a ledger-only park must be dated by its ledger row ($((NOW - 25200))), got '$GOT'"
# P2 — the NEWEST row for the ticket, and BH-70's row never answers for BH-7.
feed result "$(res_row J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7)" \
            "$(res_row J8 'PLAN_BLOCKED x' "$(ISO 9000)" tproj-BH-7-20260925T0500 BH-7)" \
            "$(res_row J70 'PLAN_BLOCKED y' "$(ISO 100)" tproj-BH-70-20260925T0600 BH-70)"
GOT=$(drive 'br_park_time tproj tproj-BH-7 BH-7 -; echo "rc=$?"')
[ "$GOT" = "$((NOW - 9000))
rc=0" ] && ok || bad "P2: the newest BH-7 row ($((NOW - 9000))) dates the park, not BH-70's, got '$GOT'"
# P3 — the ledger does not answer: UNKNOWN (rc 2), even with a state file on disk.
state tproj-BH-7 '{"outcome":"","attempts":[]}'
GOT=$(WORKER_DOWN=1 drive 'br_park_time tproj tproj-BH-7 BH-7 -; echo "rc=$?"')
[ "$GOT" = "rc=2" ] && ok || bad "P3: an unanswered ledger must date nothing (rc 2), got '$GOT'"
# P4 — no lib (not a ledger-only park): today's behaviour, the state file's mtime.
GOT=$(NO_LIB=1 drive 'br_park_time tproj tproj-BH-7 BH-7 - >/dev/null; echo "rc=$?"')
[ "$GOT" = "rc=0" ] && ok || bad "P4: without the lib the state file still dates the park, got '$GOT'"

# ═════════════════════════════════════════════════════════════════════════════
# E — the REAL lane, end to end (D2)
# ═════════════════════════════════════════════════════════════════════════════
E="$T/e"
mkdir -p "$E/bin/lib" "$E/logs" "$E/state/blocked-resolver" "$E/flags" "$E/locks" "$E/env" \
         "$E/builds" "$E/state/merge-conductor" "$E/state/build-queue/tproj" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$E/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$E" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/rebuild-ledger.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/builds-of-record.sh" "$E/bin/lib/"
mkdir -p "$E/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$E/bin/lib/mc/"
chmod +x "$E/bin/"*.sh
cp "$H/fleet.conf" "$E/fleet.conf"
: > "$E/env/global.env"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$E/bin/$f"; chmod +x "$E/bin/$f"
done
# The lane's jobs client: the queue is recorded, and job_artifact_feed answers
# from TSV fixtures (the real client's parse is §B/§R's business).
cat > "$E/bin/jobs-client.sh" <<EOF
queue_put()  { printf '%s\n' "\$*" >> "$T/e-queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
job_artifact_feed() { cat "$T/e-feed-\$1.tsv" 2>/dev/null || true; }
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/e-gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"--json state"*) echo OPEN ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
: > "$T/closed.txt"; : > "$T/comments.txt"
# Fly-routed, so the rebuild is a queue_put and never an ssh to the owning box.
touch "$E/flags/fly-pool-tproj"
ERUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$E" FLEET_CONF="$E/fleet.conf" REPOS_ROOT="$T/repos" \
           GH_TOKEN="" BR_MAX_REBUILDS=3 BR_MAX_MECHANICAL=0 BR_MAX_FIXROUNDS=0 \
           bash "$E/bin/blocked-resolver.sh" >>"$T/e-run.log" 2>&1 ) || true; }
feed_tsv() { # feed_tsv <job> <ref> <updated_at> <build_dir> <key>
  printf '%s\t%s\tbox1\t%s\t%s\t{"build_dir":"%s","key":"%s"}\n' "$1" "$2" "$5" "$3" "$4" "$5" > "$T/e-feed-result.tsv"
}

# E1 — a remote rebuild whose record never reached this box lands from the ledger.
state_e() { mkdir -p "$E/state/blocked-resolver/tproj"; printf '%s\n' "$2" > "$E/state/blocked-resolver/tproj/$1.json"; }
state_e tproj-BH-9 "$(jq -cn --arg at "$AT" \
  '{project:"tproj",rkey:"tproj-BH-9",outcome:"",rebuilds:1,attempts:[{at:$at,action:"rebuild-fresh"}]}')"
feed_tsv J9 'PR_CREATED https://github.com/x/y/pull/5' "$(ISO 3000)" "$R9DIR" BH-9
ERUN
EST=$(cat "$E/state/blocked-resolver/tproj/tproj-BH-9.json" 2>/dev/null)
[ "$(jq -r '.attempts[-1].action' <<<"$EST")" = rebuild-landed ] && ok \
  || bad "E1: the real lane must record rebuild-landed from the ledger row, got $(jq -c '.attempts' <<<"$EST"); log: $(tail -5 "$E/logs/blocked-resolver.log" 2>/dev/null)"
jq -e --arg d "$R9DIR" '.rebuild_seen | index($d)' <<<"$EST" >/dev/null && ok \
  || bad "E1: the real lane must remember $R9DIR in rebuild_seen, got $(jq -c '.rebuild_seen' <<<"$EST")"

# E2 — a ledger-only park is enqueued through br_rebuild_fresh, once.
scratch_rm "$E/state/blocked-resolver"; mkdir -p "$E/state/blocked-resolver"
: > "$T/e-queue.txt"
feed_tsv J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7
ERUN
grep -q 'BH-7' "$T/e-queue.txt" && ok \
  || bad "E2: the real lane must enqueue a rebuild of the ledger-only park, queue: '$(cat "$T/e-queue.txt")'; log: $(tail -5 "$E/logs/blocked-resolver.log" 2>/dev/null)"
N1=$(grep -c 'BH-7' "$T/e-queue.txt")
ERUN
[ "$(grep -c 'BH-7' "$T/e-queue.txt")" = "$N1" ] && ok \
  || bad "E2: the next tick must not enqueue the same park again, queue: '$(cat "$T/e-queue.txt")'"

# E3 — a ledger-only park whose TICKET merged after the park is resolved, not
# rebuilt. The merged guard dates the park from the ledger row; without that
# date it never asked GitHub and the ladder rebuilt merged work (review B1).
scratch_rm "$E/state/blocked-resolver"; mkdir -p "$E/state/blocked-resolver"
: > "$T/e-queue.txt"; : > "$T/e-gh.txt"
feed_tsv J7 'REVIEW_BLOCKED review said no' "$(ISO 25200)" "$B7DIR" BH-7
printf 'https://github.com/o/tproj/pull/77\t%s\tticket/bh-7\tBH-7: the fix\n' "$(ISO 20000)" > "$T/mergedprs"
ERUN
grep -q 'BH-7' "$T/e-queue.txt" \
  && bad "E3: a ledger-only park whose ticket merged after it must NOT be rebuilt, queue: '$(cat "$T/e-queue.txt")'; log: $(tail -5 "$E/logs/blocked-resolver.log" 2>/dev/null)" \
  || ok
grep -q 'search/issues' "$T/e-gh.txt" && ok \
  || bad "E3: the merged guard must ask GitHub for the ticket's merged PRs, gh calls: $(cat "$T/e-gh.txt")"
EST=$(cat "$E/state/blocked-resolver/tproj/tproj-BH-7.json" 2>/dev/null)
[ "$(jq -r '.outcome // ""' <<<"$EST")" = RESOLVED_MERGED ] && ok \
  || bad "E3: the park must resolve RESOLVED_MERGED, got '$(jq -c '{outcome,attempts}' <<<"$EST")'; log: $(tail -5 "$E/logs/blocked-resolver.log" 2>/dev/null)"
rm -f "$T/mergedprs"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
