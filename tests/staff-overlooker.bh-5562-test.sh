#!/bin/bash
# tests/staff-overlooker.bh-5562-test.sh — BH-5562 (BH-5556.5): Archie as the
# Overlooker of the seven staff agents, driven through the SHIPPED entry points
# bin/archie-overlook.sh and (O1) bin/staff.sh tick. The ticket names this
# suite tests/staff-overlooker.test.sh; harness convention is one suite per
# ticket key, so it lives here (the BH-4576 precedent).
#
#   O1  cross-agent dedup: three real staff ticks on one item file ONE issue;
#       the dup scan beats once per fingerprint on 2+ open issues, and makes
#       no GitHub read when nothing was filed since the last scan
#   O2  the loop wire (FAMILY_MAX same-family actions in one UTC day) and the
#       filing wire (FILE_MAX filings): flag staff-off-<name>, exactly 1 beat,
#       ledger row; the negatives; flag_set failure
#   O3  the weekly report: one block per accountable owner, precision and
#       spend per agent, sent once per ISO week through archie_beat_gate
#   O4  the Overlooker soul fragment: in the concatenated soul, parse counts
#       unchanged, Archie stays the only voice
#   O5  the lane switch and ARCHIE_OVERLOOK_ENABLED=0; registry defaults equal
#       the script defaults
#
# STUBS. A scratch harness $H (a symlink tree of bin/ and agent-core/) with
# bin/lane-alert.sh, bin/agent-call.sh and bin/archie-tg-send.sh replaced by
# loggers. One fixture file, sourced by both lanes after their libs (sandbox
# only), replaces the worker (_jobs_req, _jobs_req_file), the ledger
# (job_ledger_get/put, files under $FXT/ledger), the flags (flag_active,
# flag_set, files under $H/flags), GitHub (gh_rest, gh_rest_issue_list) and the
# model route. curl and gh on PATH log and fail.
#
# MUTATIONS (D1), each tried by hand once against bin/archie-overlook.sh:
# drop the flag_set -> O2a red; compare the family count with -gt -> O2a red
# (25 must trip); skip the ledger read -> O2c red; skip the flag_active check
# -> O2c red; count all outcomes as filed -> O2f red; beat a marker on one
# issue -> O1d red; drop the stamp check -> O1d red; move the stamp after a
# failed list -> O1d red; sort the owners in reverse -> O3a red; precision from
# all closed issues (no 7-day window) -> O3b red; mark `sent` without the gate
# -> O3d red; drop the weekday check -> O3d red; drop the lane gate -> O5a red;
# skip the pending retry when the flag is active -> O2g red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-overlooker.bh-5562-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-overlooker: jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "staff-overlooker: node is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

for SRC in "$DIR/bin/archie-overlook.sh" "$DIR/prompts/archie-soul.d/80-overlooker.md" \
           "$DIR/catalog/lanes.d/archie-overlook.json" "$DIR/cron/lanes/729-archie-overlook.cron"; do
  [ -r "$SRC" ] || bad "missing $SRC"
done
if [ ! -r "$DIR/bin/archie-overlook.sh" ]; then
  echo "staff-overlooker.bh-5562: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/agent-core" "$H/agent-core"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp "$DIR/catalog/prompts/staff-tick.md" "$H/catalog/prompts/" 2>/dev/null
cp -r "$DIR/prompts/staff" "$H/prompts/" 2>/dev/null
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh" "$H/bin/archie-tg-send.sh"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/beats.log"
exit 0
SH
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' | tee -a "$FXT/../tg-all.log" >> "$FXT/tg.log"
exit "$(cat "$FXT/tg.rc" 2>/dev/null || echo 0)"
SH
# The staff tick's model: file a ticket for every item.
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${STAFF_AGENT:-}" >> "$FXT/ac.log"
pf="${6#@}"
printf '{"type":"result","subtype":"success","total_cost_usd":0.1}' > "$5.json"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture finding title", body: "Seen at the fixture source."}]}' > "$5"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh" "$H/bin/archie-tg-send.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
mkdir -p "$H/bin/staff"
for N in quartermaster watchman clerk; do
  rm -f "$H/bin/staff/$N-collect.sh"   # cp -rs made it a symlink into the checkout
  printf '#!/bin/bash\ncat "$FXT/items.jsonl" 2>/dev/null\n' > "$H/bin/staff/$N-collect.sh"
  chmod +x "$H/bin/staff/$N-collect.sh"
done

cat > "$T/fx.sh" <<'SH'
fx_fp() { printf '%s' "$1" | sha256sum | cut -c1-64; }
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name="*)
      jq -cn --arg n "${2#*name=}" '{agent: {name: $n, role: "x", autonomy: "augmentation", cap: "augmentation",
        status: "active", soul: ("prompts/staff/" + $n + "-soul.md"), lanes: []}}'; return 0 ;;
    "GET /api/staff/agents")
      [ -f "$FXT/roster.fail" ] && return 1
      cat "$FXT/agents.json"; return 0 ;;
  esac
  return 1
}
# The claim route's one-ticket-per-fingerprint rule: the first agent to claim a
# fingerprint owns it; every later claim is 409 already_claimed.
_jobs_req_file() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  local id fp ag owner
  case "$2" in
    /api/staff/findings/claim)
      id=$(jq -r .item.id "$3"); ag=$(jq -r .agent "$3"); fp=$(fx_fp "$id")
      mkdir -p "$FXT/claims"
      if [ -f "$FXT/claims/$fp" ]; then
        owner=$(cat "$FXT/claims/$fp")
        printf '{"claimed":false,"error":"already_claimed","fingerprint":"%s","finding":{"id":1,"agent":"%s","status":"claimed"}}' "$fp" "$owner"
        return 9
      fi
      echo "$ag" > "$FXT/claims/$fp"
      printf '{"claimed":true,"fingerprint":"%s","finding":{"id":1,"agent":"%s","status":"claimed"}}' "$fp" "$ag"; return 0 ;;
    /api/staff/findings/record) printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
job_ledger_get() {
  printf 'LGET %s %s\n' "$1" "$2" >> "$FXT/ledger.log"
  [ -f "$FXT/ledger.fail" ] && return 1
  [ -f "$FXT/ledger/$1__$2" ] || return 2
  head -1 "$FXT/ledger/$1__$2"; return 0
}
job_ledger_put() {
  printf 'LPUT %s %s %s\n' "$1" "$2" "$3" >> "$FXT/ledger.log"
  [ -f "$FXT/ledger.fail" ] && return 1
  mkdir -p "$FXT/ledger"; printf '%s\n' "$3" > "$FXT/ledger/$1__$2"
}
flag_active() { [ -e "$HARNESS/flags/$1" ]; }
# flag_set: the real file path (bin/lib/jobs/flags.sh _flag_set_file) writes
# the flag file and THEN returns 1 when the database PUT fails, so
# flagset.fail leaves the file. flagset.fail.nofile is the failure before any
# write (a bad name or scope).
flag_set() {
  printf 'FLAGSET %s\n' "$*" >> "$FXT/flags.log"
  [ -f "$FXT/flagset.fail.nofile" ] && return 1
  mkdir -p "$HARNESS/flags"; : > "$HARNESS/flags/$1"
  [ -f "$FXT/flagset.fail" ] && return 1
  return 0
}
gh_rest() {
  local m=$1 p=$2; shift 2
  printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"
  [ "${1:-}" = --input ] && cp "$2" "$FXT/gh-payload.json"
  GH_REST_STATUS=201
  printf '{"number":7,"html_url":"https://github.com/example-org/cromford/issues/7"}\n'
}
# gh_rest_issue_list <slug> <state> <label> <max>: $FXT/issues/<state>-<label>.json
gh_rest_issue_list() {
  printf 'LIST %s %s %s %s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$FXT/gh.log"
  [ -f "$FXT/list.fail.$2.$3" ] && { GH_REST_STATUS=502; return 75; }
  GH_REST_STATUS=200
  cat "$FXT/issues/$2-$3.json" 2>/dev/null || echo '[]'
  return 0
}
lane_role_model() { printf 'stub-model\n'; }
SH

MON=1791799200   # Mon 2026-10-12T10:00:00Z, ISO week 2026-W42
TUE=$((MON + 86400))
DAY=2026-10-12
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT" "$T/net.log"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/issues" "$FXT/ledger" "$H/flags" "$H/logs"
  : > "$FXT/req.log"; : > "$FXT/gh.log"; : > "$FXT/beats.log"; : > "$FXT/flags.log"; : > "$FXT/ledger.log"; : > "$FXT/ac.log"
  roster operator@example.com quartermaster watchman dispatcher inspector millwright clerk archivist
}
roster() { # roster <accountable> <name>... (replaces the roster)
  local acc=$1; shift
  printf '%s\n' "$@" | jq -R . | jq -sc --arg a "$acc" '{agents: [.[] | {name: ., role: "x", accountable: $a, status: "active"}]}' \
    > "$FXT/agents.json"
}
# acted <agent> <count> <class> <outcome> <mtime ISO> [tag]: acted files in the
# shape bin/staff.sh finish() writes.
acted() {
  local a=$1 n=$2 c=$3 o=$4 when=$5 tag=${6:-x} i f
  mkdir -p "$H/state/staff/$a/acted"
  for i in $(seq 1 "$n"); do
    f="$H/state/staff/$a/acted/$(printf '%s' "$a-$c-$o-$tag-$i" | sha256sum | cut -c1-64).json"
    jq -cn --arg o "$o" --arg c "$c" '{outcome: $o, class: $c[0:200], recommendation: "Fixture finding"}' > "$f"
    touch -d "$when" "$f"
  done
}
ov() { # ov [now] — the shipped lane, sandboxed
  env HARNESS="$H" FXT="$FXT" ARCHIE_OVERLOOK_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE="${GATE_OFF-1}" JOBS_URL= ARCHIE_NOW="${1:-$MON}" PATH="$T/fakebin:$PATH" \
    bash "$H/bin/archie-overlook.sh" >"$T/out.txt" 2>&1
}
tick() { # tick <agent> — the shipped staff tick
  env HARNESS="$H" FXT="$FXT" STAFF_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= PATH="$T/fakebin:$PATH" \
    bash "$H/bin/staff.sh" tick "$1" >"$T/tick.txt" 2>&1
}
beats() { grep -c -- "${1:-.}" "$FXT/beats.log"; }
flagsets() { lines "$FXT/flags.log"; }
lists() { grep -c '^LIST ' "$FXT/gh.log"; }
noweekly() { printf 'sent\n' > "$FXT/ledger/archie_overlook__weekly-2026-W42"; }

# ═════ O1: three agents, one fingerprint, one ticket ═════════════════════════
reset; noweekly
jq -cn '{item: {id: "shared-1"}, title: "Shared fixture finding", source: {kind: "fixture",
  url: "https://example.com/fx/shared-1", labels: []}, observedAt: "2026-10-12T00:00:00Z"}' > "$FXT/items.jsonl"
FP=$(printf '%s' shared-1 | sha256sum | cut -c1-64)
tick quartermaster; tick watchman; tick clerk
eq "O1a claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 3
eq "O1a issue creates" "$(grep -c '^POST repos/' "$FXT/gh.log")" 1
eq "O1a agent-calls" "$(lines "$FXT/ac.log")" 1
eq "O1a the owner" "$(cat "$FXT/claims/$FP")" quartermaster
eq "O1b label" "$(jq -c .labels "$FXT/gh-payload.json" 2>/dev/null)" '["staff:quartermaster"]'
jq -r .body "$FXT/gh-payload.json" 2>/dev/null | grep -qF "<!-- staff-fp:$FP -->" && ok || bad "O1b: no fingerprint marker"
# O1c: the dup scan over that state: the one open issue is not a duplicate.
jq -n --rawfile b <(jq -r .body "$FXT/gh-payload.json") \
  '[{number: 7, html_url: "https://github.com/example-org/cromford/issues/7", body: $b}]' > "$FXT/issues/open-staff:quartermaster.json"
: > "$FXT/gh.log"
ov; rc=$?
eq "O1c rc" "$rc" 0
eq "O1c lists (one per roster agent)" "$(lists)" 7
eq "O1c beats" "$(beats)" 0
[ -f "$H/state/archie-overlook/dupscan.stamp" ] && ok || bad "O1c: no stamp after a full scan"

# O1d: two open issues with the same marker = exactly one beat.
reset; noweekly
acted quartermaster 1 cost-drift filed "2026-10-12T09:00:00Z"
M1="<!-- staff-fp:$FP -->"; FP2=$(printf '%s' other-2 | sha256sum | cut -c1-64)
jq -cn --arg m "x $M1" '[{number: 7, html_url: "https://github.com/example-org/cromford/issues/7", body: $m}]' \
  > "$FXT/issues/open-staff:quartermaster.json"
jq -cn --arg m "y $M1" --arg m2 "z <!-- staff-fp:$FP2 -->" '[{number: 9, html_url: "https://github.com/example-org/cromford/issues/9", body: $m},
  {number: 11, html_url: "https://github.com/example-org/cromford/issues/11", body: $m2}]' > "$FXT/issues/open-staff:watchman.json"
ov
eq "O1d beats" "$(beats)" 1
eq "O1d dup beat id" "$(beats "--id staff-dup-${FP:0:12} --severity warn archie-overlook ")" 1
grep -q 'issues/7 .*issues/9' "$FXT/beats.log" && ok || bad "O1d: the beat does not name both issues: $(cat "$FXT/beats.log")"
grep -q "${FP2:0:12}" "$FXT/beats.log" && bad "O1d: a marker on one issue was beaten" || ok
# Nothing filed since the scan: 0 GitHub reads.
: > "$FXT/gh.log"; : > "$FXT/beats.log"
ov
eq "O1d no new filing: lists" "$(lists)" 0
# A new filing: the scan runs again; the beat is the same id (lane-alert dedups).
sleep 1; acted watchman 1 x filed "@$(date +%s)" fresh
ov
eq "O1d new filing: lists" "$(lists)" 7
# A list that fails: nothing beaten, the stamp is not advanced, the next tick retries.
: > "$FXT/gh.log"; : > "$FXT/beats.log"
sleep 1; acted watchman 1 x filed "@$(date +%s)" fresh2
touch "$FXT/list.fail.open.staff:clerk"
ov
eq "O1d list fails: beats" "$(beats)" 0
rm -f "$FXT/list.fail.open.staff:clerk"; : > "$FXT/gh.log"
ov
eq "O1d after a failed list: retried" "$(lists)" 7
eq "O1d after a failed list: beat" "$(beats staff-dup-)" 1
# A marker in a closed issue is not a duplicate (only open issues are read).
grep -q '^LIST [^ ]* closed ' "$FXT/gh.log" && bad "O1d: the dup scan read closed issues" || ok

# ═════ O2: the loop wire and the filing wire ═════════════════════════════════
TRIP="--id staff-trip-quartermaster-$DAY --severity warn archie-overlook "
reset; noweekly
acted quartermaster 25 cost-drift digested "2026-10-12T08:00:00Z"
ov; rc=$?
eq "O2a rc" "$rc" 0
eq "O2a flag_set calls" "$(flagsets)" 1
grep -q '^FLAGSET staff-off-quartermaster on ' "$FXT/flags.log" && ok || bad "O2a flag_set args: $(cat "$FXT/flags.log")"
[ -e "$H/flags/staff-off-quartermaster" ] && ok || bad "O2a: no staff-off-quartermaster flag"
eq "O2b beats" "$(beats)" 1
eq "O2b trip beat" "$(beats "$TRIP")" 1
grep -q 'Flag staff-off-quartermaster written' "$FXT/beats.log" && ok || bad "O2b beat text: $(cat "$FXT/beats.log")"
grep -q '—' "$FXT/beats.log" && bad "O2b: an em dash in the beat" || ok
eq "O2a ledger" "$(cat "$FXT/ledger/archie_overlook__trip-quartermaster-$DAY" 2>/dev/null)" paused
# O2c: the flag is active: nothing again.
: > "$FXT/beats.log"; : > "$FXT/flags.log"
ov
eq "O2c flag active: flag_set" "$(flagsets)" 0
eq "O2c flag active: beats" "$(beats)" 0
# A person cleared the flag; the ledger row says it tripped today: no re-pause.
rm -f "$H/flags/staff-off-quartermaster"
ov
eq "O2c cleared by a person: flag_set" "$(flagsets)" 0
eq "O2c cleared by a person: beats" "$(beats)" 0
# A flag a person (or the staff lane) already set, and no ledger row: no
# second flag_set and no beat.
reset; noweekly; acted quartermaster 25 cost-drift digested "2026-10-12T08:00:00Z"
touch "$H/flags/staff-off-quartermaster"
ov
eq "O2c flag set by hand: flag_set" "$(flagsets)" 0
eq "O2c flag set by hand: beats" "$(beats)" 0
# The next UTC day the count starts again from that day's files.
ov $((MON + 86400 + 3600))
eq "O2c next day: flag_set" "$(flagsets)" 0

# O2d: the negatives, and the one-slug case.
o2d() { # o2d <label> <want flag_set count> ; acted files already written
  ov; eq "O2d $1" "$(flagsets)" "$2"
}
reset; noweekly; acted quartermaster 24 cost-drift digested "2026-10-12T08:00:00Z"; o2d "24 same family" 0
reset; noweekly; acted quartermaster 13 cost-drift digested "2026-10-12T08:00:00Z"
acted quartermaster 12 disk-full digested "2026-10-12T08:00:00Z"; o2d "13+12 two families" 0
reset; noweekly; acted quartermaster 25 cost-drift digested "2026-10-11T22:00:00Z"; o2d "25 yesterday" 0
reset; noweekly; acted quartermaster 13 "Cost Drift" digested "2026-10-12T08:00:00Z"
acted quartermaster 12 cost-drift digested "2026-10-12T08:00:00Z"; o2d "Cost Drift + cost-drift one slug" 1
reset; noweekly; acted archie 25 cost-drift digested "2026-10-12T08:00:00Z"; o2d "not on the roster" 0
eq "O2d not on the roster: beats" "$(beats)" 0
reset; noweekly; acted quartermaster 30 cost-drift digested "2026-10-12T08:00:00Z"; o2d "30 same family" 1
# 25 unparsable acted files are one family (unclassified): a loop.
reset; noweekly; mkdir -p "$H/state/staff/quartermaster/acted"
for i in $(seq 1 25); do printf 'not json %s\n' "$i" > "$H/state/staff/quartermaster/acted/bad$i.json"
  touch -d "2026-10-12T08:00:00Z" "$H/state/staff/quartermaster/acted/bad$i.json"; done
o2d "25 unparsable" 1
# A roster name with bad characters is never read.
reset; noweekly; roster operator@example.com 'Bad Name' quartermaster
mkdir -p "$H/state/staff/Bad Name"; acted quartermaster 2 x digested "2026-10-12T08:00:00Z"
ov; eq "O2d bad roster name: flag_set" "$(flagsets)" 0
grep -q "roster name 'Bad Name' is not a valid agent name" "$H/logs/archie-overlook.log" && ok || bad "O2d: no bad-name log line"

# O2e: seven agents over the threshold: 7 flags, 7 beats; a second run 0.
reset; noweekly
for N in quartermaster watchman dispatcher inspector millwright clerk archivist; do
  acted "$N" 25 loop digested "2026-10-12T08:00:00Z"
done
ov
eq "O2e flags" "$(flagsets)" 7
eq "O2e beats" "$(beats staff-trip-)" 7
: > "$FXT/beats.log"; : > "$FXT/flags.log"
ov
eq "O2e second run flags" "$(flagsets)" 0
eq "O2e second run beats" "$(beats)" 0

# O2f: the filing wire.
reset; noweekly
for c in a b c d e f g h i j; do acted quartermaster 1 "class-$c" filed "2026-10-12T08:00:00Z"; done
ov
eq "O2f 10 filings: flag_set" "$(flagsets)" 1
grep -q 'filed 10 tickets today' "$FXT/beats.log" && ok || bad "O2f beat text: $(cat "$FXT/beats.log")"
reset; noweekly
for c in a b c d e f g h i; do acted quartermaster 1 "class-$c" filed "2026-10-12T08:00:00Z"; done
ov; eq "O2f 9 filings: flag_set" "$(flagsets)" 0
# The knobs move the wires.
reset; noweekly; acted quartermaster 5 cost-drift digested "2026-10-12T08:00:00Z"
STAFF_OVERLOOK_FAMILY_MAX=5 ov; eq "O2f FAMILY_MAX=5" "$(flagsets)" 1
reset; noweekly; acted quartermaster 5 cost-drift digested "2026-10-12T08:00:00Z"
STAFF_OVERLOOK_FAMILY_MAX=1 ov; eq "O2f FAMILY_MAX=1 is out of range: default" "$(flagsets)" 0
grep -q 'warn: STAFF_OVERLOOK_FAMILY_MAX=1 is outside 2..1000' "$H/logs/archie-overlook.log" && ok || bad "O2f: no knob warn line"

# O2g: flag_set writes the flag file, then fails on the database row. The
# agent is paused on this box, so the beat says so and names the missing row.
# The ledger row stays `pending`, so the next run calls flag_set again even
# though the flag is active.
reset; noweekly; acted quartermaster 25 cost-drift digested "2026-10-12T08:00:00Z"
touch "$FXT/flagset.fail"
ov
eq "O2g flag_set calls" "$(flagsets)" 1
eq "O2g beats" "$(beats "$TRIP")" 1
[ -e "$H/flags/staff-off-quartermaster" ] && ok || bad "O2g: the stub left no flag file"
grep -q 'paused staff agent quartermaster on this box' "$FXT/beats.log" && ok || bad "O2g beat text: $(cat "$FXT/beats.log")"
grep -q 'could not write flag' "$FXT/beats.log" && bad "O2g: the beat says the flag is not written, but the file is there" || ok
eq "O2g ledger" "$(cat "$FXT/ledger/archie_overlook__trip-quartermaster-$DAY" 2>/dev/null)" pending
rm -f "$FXT/flagset.fail"
ov
eq "O2g retry flag_set calls" "$(flagsets)" 2
eq "O2g retry ledger" "$(cat "$FXT/ledger/archie_overlook__trip-quartermaster-$DAY" 2>/dev/null)" paused
ov
eq "O2g third run flag_set calls" "$(flagsets)" 2
# O2g2: flag_set fails before it writes anything: the beat says the flag is
# not written, the log does not say paused, and the next run tries again.
reset; noweekly; acted quartermaster 25 cost-drift digested "2026-10-12T08:00:00Z"
touch "$FXT/flagset.fail.nofile"
ov
eq "O2g2 flag_set calls" "$(flagsets)" 1
[ -e "$H/flags/staff-off-quartermaster" ] && bad "O2g2: a flag file after a failed write" || ok
grep -q 'could not write flag staff-off-quartermaster' "$FXT/beats.log" && ok || bad "O2g2 beat text: $(cat "$FXT/beats.log")"
grep -q 'paused' "$H/logs/archie-overlook.log" && bad "O2g2: the log says paused" || ok
eq "O2g2 ledger" "$(cat "$FXT/ledger/archie_overlook__trip-quartermaster-$DAY" 2>/dev/null)" pending
rm -f "$FXT/flagset.fail.nofile"
ov
eq "O2g2 retry flag_set calls" "$(flagsets)" 2
eq "O2g2 retry ledger" "$(cat "$FXT/ledger/archie_overlook__trip-quartermaster-$DAY" 2>/dev/null)" paused

# A roster that cannot be read: one log line, nothing paused, no GitHub read.
reset; noweekly; acted quartermaster 25 cost-drift filed "2026-10-12T08:00:00Z"; touch "$FXT/roster.fail"
ov; rc=$?
eq "O2h roster unreadable rc" "$rc" 0
eq "O2h roster unreadable: flag_set" "$(flagsets)" 0
eq "O2h roster unreadable: lists" "$(lists)" 0
grep -q 'roster unreadable' "$H/logs/archie-overlook.log" && ok || bad "O2h: no roster line"

# ═════ O3: the weekly report ═════════════════════════════════════════════════
reset
roster operator@example.com quartermaster watchman dispatcher inspector millwright clerk
jq -c '.agents += [{name: "archivist", role: "x", accountable: "ops@example.com", status: "active"}]' "$FXT/agents.json" > "$FXT/a2" && mv "$FXT/a2" "$FXT/agents.json"
acted quartermaster 3 cost-drift filed "2026-10-10T08:00:00Z"
acted quartermaster 4 cost-drift digested "2026-10-11T08:00:00Z"
acted quartermaster 9 cost-drift digested "2026-10-01T08:00:00Z" old
iso_ago() { date -u -d "@$((MON - $1 * 86400))" +%Y-%m-%dT%H:%M:%SZ; }
jq -cn --arg a "$(iso_ago 1)" --arg b "$(iso_ago 2)" --arg c "$(iso_ago 3)" --arg d "$(iso_ago 10)" '[
  {number: 1, closed_at: $a, state_reason: "completed"}, {number: 2, closed_at: $b, state_reason: "completed"},
  {number: 3, closed_at: $c, state_reason: "not_planned"}, {number: 4, closed_at: $d, state_reason: "completed"}]' \
  > "$FXT/issues/closed-staff:quartermaster.json"
touch "$FXT/list.fail.closed.staff:clerk"
. "$DIR/bin/lib/cost-row.sh" || exit 1
crow() { # crow <ts> <stage> <usd>: one row in the COST_ROW_HDR column order
  printf '%s,hub,fleet,%s,claude,m,0,1,0,0,0,0,%s,api,,,,,,,,,,,,\n' "$1" "$2" "$3"
}
{ echo "$COST_ROW_HDR"
  crow "$(iso_ago 1)" staff.quartermaster 0.40; crow "$(iso_ago 2)" staff.quartermaster 0.84
  crow "$(iso_ago 9)" staff.quartermaster 9.00; crow "$(iso_ago 1)" staff-tick 0.50
  crow "$(iso_ago 1)" plan 7.00; } > "$H/logs/cost.csv"
ov $TUE
eq "O3d other weekday: sends" "$(lines "$FXT/tg.log")" 0
ov; rc=$?
eq "O3d rc" "$rc" 0
eq "O3d sends" "$(lines "$FXT/tg.log")" 1
eq "O3d akey" "$(jq -r .akey "$FXT/tg.log" 2>/dev/null)" staff-weekly-2026-W42
eq "O3d ledger" "$(cat "$FXT/ledger/archie_overlook__weekly-2026-W42" 2>/dev/null)" sent
R=$(jq -r .line "$FXT/tg.log" 2>/dev/null)
eq "O3a owner lines" "$(grep '^Owner: ' <<<"$R" | tr '\n' '|')" "Owner: operator@example.com|Owner: ops@example.com|"
eq "O3a archivist under ops" "$(sed -n '/^Owner: ops@example.com/,$p' <<<"$R" | grep -c '^- archivist:')" 1
eq "O3a six agents under operator" "$(sed -n '/^Owner: operator@example.com/,/^Owner: ops/p' <<<"$R" | grep -c '^- ')" 6
QL=$(grep '^- quartermaster:' <<<"$R")
eq "O3b quartermaster line" "$QL" "- quartermaster: filed 3, digested 4, precision 67% (2 of 3), spend \$1.24"
eq "O3b no closed issues" "$(grep -c '^- watchman: .*precision n/a,' <<<"$R")" 1
eq "O3b list fails" "$(grep -c '^- clerk: .*precision unreadable,' <<<"$R")" 1
eq "O3c unattributed lines" "$(grep -c '^unattributed staff-tick spend \$0.50$' <<<"$R")" 1
eq "O3c unattributed before the owners" "$(sed -n 2p <<<"$R")" 'unattributed staff-tick spend $0.50'
eq "O3c no spend" "$(grep -c '^- watchman: .*spend \$0.00$' <<<"$R")" 1
[ "${#R}" -le 3500 ] && ok || bad "O3e report is ${#R} chars"
grep -q '—' <<<"$R" && bad "O3e: an em dash in the report" || ok
[ -s "$H/state/archie-overlook/weekly-2026-W42.md" ] && ok || bad "O3: no report file"
# The same week again: no send.
ov $((MON + 3600))
eq "O3d second run sends" "$(lines "$FXT/tg.log")" 1
# The gate cannot send: the ledger stays pending, the next run sends.
rm -f "$FXT/ledger/archie_overlook__weekly-2026-W42" "$FXT/tg.log"; echo 1 > "$FXT/tg.rc"
ov
eq "O3d gate rc 1: ledger" "$(cat "$FXT/ledger/archie_overlook__weekly-2026-W42" 2>/dev/null)" pending
rm -f "$FXT/tg.rc"
ov
eq "O3d resend after pending" "$(cat "$FXT/ledger/archie_overlook__weekly-2026-W42" 2>/dev/null)" sent
eq "O3d resend sends" "$(jq -s --arg w staff-weekly-2026-W42 'map(select(.akey == $w)) | length' "$FXT/tg.log")" 2
# A ledger that cannot be read sends nothing (it cannot tell sent from not).
rm -f "$FXT/tg.log"; touch "$FXT/ledger.fail"
ov
eq "O3d ledger unreadable: sends" "$(lines "$FXT/tg.log")" 0
rm -f "$FXT/ledger.fail"
# Report files older than 12 weeks go.
mkdir -p "$H/state/archie-overlook"; echo old > "$H/state/archie-overlook/weekly-2026-W20.md"
touch -d '2026-05-01T00:00:00Z' "$H/state/archie-overlook/weekly-2026-W20.md"
rm -f "$FXT/ledger/archie_overlook__weekly-2026-W42"
ov
[ ! -e "$H/state/archie-overlook/weekly-2026-W20.md" ] && ok || bad "O3: an old report file stayed"
[ -s "$H/state/archie-overlook/weekly-2026-W42.md" ] && ok || bad "O3: retention removed this week's report"
# Quiet hours hold the report as a digest row; that counts as queued, so sent.
rm -f "$FXT/ledger/archie_overlook__weekly-2026-W42" "$FXT/tg.log"
ARCHIE_QUIET_FROM_H=9 ARCHIE_QUIET_TO_H=11 ov
eq "O3d quiet hours: sends" "$(lines "$FXT/tg.log")" 0
ls "$FXT/ledger" | grep -q '^archie_digest__dg-' && ok || bad "O3d quiet hours: no digest row"
eq "O3d quiet hours: ledger" "$(cat "$FXT/ledger/archie_overlook__weekly-2026-W42" 2>/dev/null)" sent

# ═════ O4: the soul fragment ═════════════════════════════════════════════════
SD="$DIR/prompts/archie-soul.d"
SOUL=$(cat "$SD"/*.md)
grep -q '^Overlooker\.' <<<"$SOUL" && ok || bad "O4a: no Overlooker section in the concatenated soul"
for N in quartermaster watchman dispatcher inspector millwright clerk archivist; do
  grep -qw "$N" "$SD/80-overlooker.md" && ok || bad "O4a: the fragment does not name $N"
done
[ ! -e "$DIR/prompts/archie-soul.md" ] && ok || bad "O4a: prompts/archie-soul.md exists"
eq "O4a fragments that say Overlooker" "$(grep -l 'Overlooker' "$SD"/*.md | xargs -n1 basename | tr '\n' ' ')" "80-overlooker.md "
CNT=$(node --input-type=module -e '
  import { readFileSync, readdirSync } from "node:fs";
  const { parseSoul } = await import(process.argv[1] + "/agent-core/src/index.js");
  const d = process.argv[1] + "/prompts/archie-soul.d/";
  const fs = readdirSync(d).filter((f) => f.endsWith(".md")).sort();
  const n = (t) => { const s = parseSoul(t); return [s.may.length, s.never.length, s.report.length].join(","); };
  const all = fs.map((f) => readFileSync(d + f, "utf8")).join("");
  const without = fs.filter((f) => f !== "80-overlooker.md").map((f) => readFileSync(d + f, "utf8")).join("");
  console.log(n(all) + " " + n(without));' "$DIR" 2>&1)
eq "O4b MAY/NEVER/REPORT counts with and without the fragment" "${CNT%% *}" "${CNT##* }"
grep -q 'never message the operator' "$SD/80-overlooker.md" && ok || bad "O4c: the fragment does not say staff never message the operator"
grep -q 'report through Archie' "$SD/80-overlooker.md" && ok || bad "O4c: the fragment does not say staff report through Archie"
grep -qE '^(MAY|NEVER|REPORT)\b[^:]*:' "$SD/80-overlooker.md" && bad "O4b: the fragment opens an authority list" || ok
# O4d: the lane's only voices are lane-alert.sh and archie_beat_gate.
grep -qE 'archie-tg-send|api\.telegram\.org|fleet_alert|bin/beat\.sh' <<<"$(grep -vE '^[[:space:]]*#' "$DIR/bin/archie-overlook.sh")" \
  && bad "O4d: bin/archie-overlook.sh has a direct send path" || ok
# Every Telegram send in this suite was the weekly report.
eq "O4d tg sends other than the report" "$(jq -s 'map(select(.akey | startswith("staff-weekly-") | not)) | length' "$T/tg-all.log")" 0
[ -s "$T/tg-all.log" ] && ok || bad "O4d: the suite made no Telegram send at all"

# ═════ O5: the switches ══════════════════════════════════════════════════════
reset; acted quartermaster 25 cost-drift filed "2026-10-12T08:00:00Z"
ARCHIE_OVERLOOK_ENABLED=0 ov; rc=$?
eq "O5a ENABLED=0 rc" "$rc" 0
eq "O5a ENABLED=0 roster reads" "$(grep -c '/api/staff/agents' "$FXT/req.log")" 0
eq "O5a ENABLED=0 flag_set" "$(flagsets)" 0
eq "O5a ENABLED=0 lists" "$(lists)" 0
reset; acted quartermaster 25 cost-drift filed "2026-10-12T08:00:00Z"
touch "$H/flags/lane-off-archie-overlook"
GATE_OFF=0 ov; rc=$?
eq "O5a lane-off rc" "$rc" 0
eq "O5a lane-off roster reads" "$(grep -c '/api/staff/agents' "$FXT/req.log")" 0
eq "O5a lane-off flag_set" "$(flagsets)" 0
# O5b: the registry defaults equal the script defaults.
REG="$DIR/catalog/lanes.d/archie-overlook.json"
for K in ARCHIE_OVERLOOK_ENABLED STAFF_OVERLOOK_FAMILY_MAX STAFF_OVERLOOK_FILE_MAX STAFF_OVERLOOK_REPORT_DOW; do
  sd=$(grep -o "knob_int $K \"\${$K:-[0-9]*}\" [0-9]* [0-9]* [0-9]*" "$DIR/bin/archie-overlook.sh" | head -1)
  [ -n "$sd" ] || { bad "O5b: no knob_int read of $K in the script"; continue; }
  read -r _ _ _ d mn mx <<<"$sd"
  eq "O5b $K default/min/max" "$d $mn $mx" "$(jq -r --arg k "$K" '.knobs[] | select(.env == $k) | "\(.default) \(.min) \(.max)"' "$REG")"
done
eq "O5b fixture seam not settable" "$(jq -r '.knobs[] | select(.env == "ARCHIE_OVERLOOK_FIXTURE") | .settable' "$REG")" false
eq "O5b switch" "$(jq -r .switch.name "$REG")" lane-off-archie-overlook
grep -q '^8-58/15 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/archie-overlook.sh ' "$DIR/cron/lanes/729-archie-overlook.cron" \
  && ok || bad "O5b: the cron line"

[ -e "$T/net.log" ] && bad "a stub let a real curl/gh run: $(cat "$T/net.log")" || ok

echo "staff-overlooker.bh-5562: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
