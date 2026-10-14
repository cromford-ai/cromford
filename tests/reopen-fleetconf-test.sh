#!/bin/bash
# tests/reopen-fleetconf-test.sh — bin/reopen-metrics.sh over the REGISTRY, and
# the GitHub-Issues reopen decision.
#
# The bug this pins: the reopen counter looped over four hardcoded project
# names. Every project enrolled after those four measured zero reopens forever
# — and zero reopens reads exactly like a perfect record, which is the worst
# possible default for a signal whose only job is to withdraw trust. So the
# assertion that matters is not "the numbers are right", it is "every project
# in fleet.conf has a row at all".
#
# The GitHub lane is tested through a `gh` STUB on PATH, not the network: the
# fixture is a real /issues/events page shape, and the stub serves it for page
# 1 and an empty page after, so paging, the decision, and the daily-rerun
# dedup all run their real control flow.
# Run from anywhere: tests/reopen-fleetconf-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
SCRIPT="$DIR/bin/reopen-metrics.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TODAY=$(date -u +%Y%m%d)
D3=$(date -u -d '3 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-3d +%Y-%m-%d)
D3C=${D3//-/}
D40=$(date -u -d '40 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-40d +%Y-%m-%d)

# ---------- fixture registry: two app-board rows, two GitHub-Issues rows ------
mkdir -p "$T/env" "$T/logs" "$T/state" "$T/builds" "$T/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
cat > "$T/fleet.conf" <<'EOF'
# tests fixture — same columns as the live registry:
#   <project> <github-repo-slug> <prod-base-url> <board-api-prefix> <cron-offset> [box]
alpha-os   Acme/alpha-os   https://alpha.example  /api/board  2
beta-os    Acme/beta-os    https://beta.example   /api/board  4 box-beta
gamma      Acme/gamma      https://gamma.example  -           6 box-small
delta      Acme/delta      -                      -           8 box-small
epsilon    Acme/epsilon    -                      -           9 box-small
# zeta has neither a board API nor a repo slug — unmeasurable, and it must say so.
zeta       -               -                      -           1 box-small
# sib / sib-nav are the build-dir PREFIX COLLISION: builds/sib-* also matches
# every builds/sib-nav-* directory.
sib        Acme/sib        -                      -           5 box-small
sib-nav    Acme/sib-nav    -                      -           7 box-small
EOF

# ---------- 1. the decision function, driven by a fixture events page --------
# Extracted verbatim so the test cannot drift from the shipped logic.
awk '/^# >>> gh reopen decision/{f=1;next} /^# <<< gh reopen decision/{exit} f' \
  "$SCRIPT" > "$T/decision.sh"
[ -s "$T/decision.sh" ] && ok || bad "could not extract the gh decision block — markers missing?"
# shellcheck disable=SC1091
. "$T/decision.sh"

cat > "$T/events.json" <<EOF
[
  {"event":"closed",   "created_at":"${D3}T09:00:00Z","issue":{"number":11}},
  {"event":"reopened", "created_at":"${D3}T10:00:00Z","issue":{"number":11}},
  {"event":"closed",   "created_at":"${D3}T09:00:00Z","issue":{"number":12}},
  {"event":"labeled",  "created_at":"${D3}T11:00:00Z","issue":{"number":12},"label":{"name":"ai-build"}},
  {"event":"labeled",  "created_at":"${D3}T11:30:00Z","issue":{"number":13},"label":{"name":"ai-build"}},
  {"event":"closed",   "created_at":"${D3}T08:00:00Z","issue":{"number":14}},
  {"event":"labeled",  "created_at":"${D3}T12:00:00Z","issue":{"number":14},"label":{"name":"bug"}},
  {"event":"closed",   "created_at":"${D40}T09:00:00Z","issue":{"number":15}},
  {"event":"reopened", "created_at":"${D40}T10:00:00Z","issue":{"number":15}},
  {"event":"closed",   "created_at":"${D3}T07:00:00Z","issue":{"number":16}},
  {"event":"labeled",  "created_at":"${D3}T13:00:00Z","issue":{"number":16},"label":{"name":"ai-build"}},
  {"event":"labeled",  "created_at":"${D3}T14:00:00Z","issue":{"number":16},"label":{"name":"ai-build"}}
]
EOF
SINCE_ISO=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)
OUT=$(gh_reopens_from_events "$T/events.json" "$SINCE_ISO" ai-build)

grep -q "^$D3C	#11$" <<<"$OUT" && ok || bad "a reopened event must count (got: $(tr '\n' ' ' <<<"$OUT"))"
grep -q "^$D3C	#12$" <<<"$OUT" && ok || bad "ai-build re-added while CLOSED must count"
grep -q '#13' <<<"$OUT" && bad "ai-build added while OPEN is a normal launch, not a reopen" || ok
grep -q '#14' <<<"$OUT" && bad "a non-build label on a closed issue is not a reopen" || ok
grep -q '#15' <<<"$OUT" && bad "an event older than the window must not count" || ok
# #16 got the build label re-added twice on the same day: one reopen, not two,
# or a single client bounce would demote a project twice over.
[ "$(grep -c '#16' <<<"$OUT")" = 1 ] && ok || bad "same-day reopen+relabel must collapse to one row (got $(grep -c '#16' <<<"$OUT"))"

# 1b. THE SAME BOUNCE, ACROSS MIDNIGHT. The label goes back on at 23:00 and the
# issue is reopened at 01:00 — one client bounce, two calendar dates, so a
# dedup that compares "YYYYMMDD<TAB>#key" strings sees two different strings
# and lets both through. Two rows off one bounce is 2/12 = 0.17, which crosses
# the 0.15 demotion threshold entirely on its own.
DA=$(date -u -d '5 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-5d +%Y-%m-%d)
DB=$(date -u -d '4 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-4d +%Y-%m-%d)
cat > "$T/midnight.json" <<EOF
[
  {"event":"closed",  "created_at":"${DA}T08:00:00Z","issue":{"number":21}},
  {"event":"labeled", "created_at":"${DA}T23:00:00Z","issue":{"number":21},"label":{"name":"ai-build"}},
  {"event":"reopened","created_at":"${DB}T01:00:00Z","issue":{"number":21}}
]
EOF
MOUT=$(gh_reopens_from_events "$T/midnight.json" "$SINCE_ISO" ai-build)
[ "$(grep -c '#21' <<<"$MOUT")" = 1 ] && ok \
  || bad "one bounce straddling midnight must be ONE reopen (got $(grep -c '#21' <<<"$MOUT"): $(tr '\n' ' ' <<<"$MOUT"))"

# ...and two GENUINELY separate bounces, days apart, must still both count —
# the refractory window suppresses a duplicate signal, not a repeat offence.
DC=$(date -u -d '2 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d)
cat > "$T/twice.json" <<EOF
[
  {"event":"closed",  "created_at":"${DA}T08:00:00Z","issue":{"number":22}},
  {"event":"reopened","created_at":"${DA}T09:00:00Z","issue":{"number":22}},
  {"event":"closed",  "created_at":"${DC}T08:00:00Z","issue":{"number":22}},
  {"event":"reopened","created_at":"${DC}T09:00:00Z","issue":{"number":22}}
]
EOF
[ "$(gh_reopens_from_events "$T/twice.json" "$SINCE_ISO" ai-build | grep -c '#22')" = 2 ] && ok \
  || bad "two bounces days apart must both count"

# ---------- 2. gh stub: the GitHub lane end to end, no network ---------------
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<EOF
#!/bin/bash
# Three GH repos, three outcomes: gamma has events, delta answers with an empty
# page (measured and quiet), epsilon cannot be read at all.
for a in "\$@"; do case "\$a" in
  repos/Acme/gamma/*page=1*) cat "$T/events.json"; exit 0 ;;
  repos/Acme/epsilon/*)      echo "gh: HTTP 404" >&2; exit 1 ;;
esac; done
echo '[]'
EOF
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

# metrics.csv with rows for alpha-os only (the "original four" shape).
printf 'build_dir,project,key,started,pr_at,merged_at,result_kind,size,fix_rounds,conflict_defers,duration_min\n' > "$T/logs/metrics.csv"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  printf 'alpha-os-A-%s,alpha-os,A-%s,%s,,,PR_MERGED,S,0,0,5\n' "$i" "$i" "$D3" >> "$T/logs/metrics.csv"
done
# gamma has no metrics.csv rows at all — only build dirs, the fallback source.
for i in 1 2 3; do mkdir -p "$T/builds/gamma-G-$i"; echo "PR_MERGED https://x/pull/$i" > "$T/builds/gamma-G-$i/RESULT"; done
mkdir -p "$T/builds/gamma-G-9"; echo "REVIEW_BLOCKED nope" > "$T/builds/gamma-G-9/RESULT"
# Prefix collision: 2 builds for sib, 4 for sib-nav. A bare builds/sib-* glob
# would credit all 6 to sib.
for i in 1 2; do mkdir -p "$T/builds/sib-S-$i"; echo "PR_MERGED x" > "$T/builds/sib-S-$i/RESULT"; done
for i in 1 2 3 4; do mkdir -p "$T/builds/sib-nav-N-$i"; echo "PR_MERGED x" > "$T/builds/sib-nav-N-$i/RESULT"; done

run() { HARNESS="$T" FLEET_CONF="$T/fleet.conf" HARNESS_SECRET= JOBS_URL=http://127.0.0.1:9 bash "$SCRIPT" >/dev/null 2>&1; echo $?; }
[ "$(run)" = 0 ] && ok || bad "script must exit 0 (measure-only, fail-open)"

RJ="$T/state/reopen-rate.json"
jq -e . "$RJ" >/dev/null 2>&1 && ok || bad "reopen-rate.json must be valid JSON: $(cat "$RJ" 2>/dev/null)"

# THE REGRESSION: every registry project gets a row, not just a hardcoded four.
for P in alpha-os beta-os gamma delta epsilon zeta sib sib-nav; do
  jq -e --arg p "$P" 'has($p)' "$RJ" >/dev/null 2>&1 \
    && ok || bad "$P missing from reopen-rate.json — fleet.conf not iterated"
done

# ---------- 3. GitHub reopens land in the shared CSV schema ------------------
head -1 "$T/logs/reopens.csv" | grep -qx 'date,project,key,from,to' && ok || bad "CSV header changed"
grep -q "^$D3C,gamma,#11,done,open$" "$T/logs/reopens.csv" && ok \
  || bad "GH reopen row must use the shared schema (got: $(grep gamma "$T/logs/reopens.csv" | tr '\n' ' '))"
[ "$(jq -r '.gamma.reopens_14d' "$RJ")" = 3 ] && ok \
  || bad "gamma should show 3 reopens in the window (got $(jq -r '.gamma.reopens_14d' "$RJ"))"

# ---------- 4. builds_total sources ------------------------------------------
[ "$(jq -r '."alpha-os".builds_total' "$RJ")" = 12 ] && ok \
  || bad "an original project keeps its metrics.csv denominator (got $(jq -r '."alpha-os".builds_total' "$RJ"))"
[ "$(jq -r '.gamma.builds_total' "$RJ")" = 3 ] && ok \
  || bad "a GH project counts PR-shaped RESULT dirs (got $(jq -r '.gamma.builds_total' "$RJ"))"
# Prefix collision: builds/sib-* also matches builds/sib-nav-*. Crediting a
# sibling's builds to this project's denominator makes the rate quietly wrong.
[ "$(jq -r '.sib.builds_total' "$RJ")" = 2 ] && ok \
  || bad "sib must count only its own 2 builds, not sib-nav's (got $(jq -r '.sib.builds_total' "$RJ"))"
[ "$(jq -r '."sib-nav".builds_total' "$RJ")" = 4 ] && ok \
  || bad "sib-nav must count its own 4 builds (got $(jq -r '."sib-nav".builds_total' "$RJ"))"

# 4b. A project with neither a board API nor a repo slug cannot be measured at
# all. It still gets a row (absent from the scorecard is worse), and it says so
# out loud instead of being skipped in silence.
grep -q 'zeta has no board API and no repo slug' "$T/logs/ALERTS.log" && ok \
  || bad "an unmeasurable project must hit ALERTS.log, not be silently skipped"

# ---------- 5. daily re-run must not re-bill the same reopen -----------------
# The window is 14 days and the cron is daily, so an un-deduped append would
# re-count every reopen every night and the rate would climb with no client
# ever coming back.
BEFORE=$(wc -l < "$T/logs/reopens.csv")
run >/dev/null
[ "$(wc -l < "$T/logs/reopens.csv")" = "$BEFORE" ] && ok || bad "second run duplicated reopen rows"
[ "$(jq -r '.gamma.reopens_14d' "$RJ")" = 3 ] && ok \
  || bad "reopens_14d drifted on re-run (got $(jq -r '.gamma.reopens_14d' "$RJ"))"

# ---------- 6. an unreachable board is skipped LOUDLY, still gets a row ------
# alpha-os/beta-os have no credentials here, so their snapshot fails. The
# failure must be recorded, and the project must still appear at 0 reopens
# rather than vanishing from the scorecard.
grep -q 'alpha-os snapshot failed' "$T/logs/ALERTS.log" && ok || bad "a failed snapshot must hit ALERTS.log"
[ "$(jq -r '."alpha-os".reopens_14d' "$RJ")" = 0 ] && ok || bad "alpha-os should read 0 reopens, not vanish"

# 6b. THREE OUTCOMES on the GitHub lane. A repo that answered with an empty
# page is measured-and-quiet, not broken; only a repo we could not READ is a
# failure. Collapsing the two would alert every quiet week until nobody reads
# the line — the same shape as treating a billed-but-empty vendor response as
# a retryable failure.
[ "$(jq -r '.delta.reopens_14d' "$RJ")" = 0 ] && ok || bad "a quiet repo reads 0 reopens"
grep -q 'delta gh issue events unreadable' "$T/logs/ALERTS.log" \
  && bad "an EMPTY events page must not be reported as unreadable" || ok
grep -q 'epsilon gh issue events unreadable' "$T/logs/ALERTS.log" \
  && ok || bad "a gh call that FAILED must hit ALERTS.log"

# ---------- 7. the 14d window is real ---------------------------------------
echo "$(date -u -d '40 days ago' +%Y%m%d 2>/dev/null || date -u -v-40d +%Y%m%d),delta,#99,done,open" >> "$T/logs/reopens.csv"
echo "$TODAY,delta,#98,done,open" >> "$T/logs/reopens.csv"
run >/dev/null
[ "$(jq -r '.delta.reopens_14d' "$RJ")" = 1 ] && ok \
  || bad "only in-window rows count (got $(jq -r '.delta.reopens_14d' "$RJ"))"

# ---------- 8. the CSV guard spans the ADJACENT day -------------------------
# The refractory collapse keeps the EARLIEST of a pair, which is only stable
# while both halves are still inside the fetched pages. On a repo busy enough
# to push the 23:00 event past the page cap, tomorrow's run sees only the 01:00
# half, treats it as a fresh first, and writes a second row for a bounce
# already on the ledger. So the append guard checks yesterday and tomorrow too.
YDAY=$(date -u -d '1 day ago' +%Y%m%d 2>/dev/null || date -u -v-1d +%Y%m%d)
DBC=${DB//-/}
: > "$T/logs/reopens.csv"; echo 'date,project,key,from,to' > "$T/logs/reopens.csv"
DAC=${DA//-/}
echo "$DAC,gamma,#21,done,open" >> "$T/logs/reopens.csv"   # yesterday's run already logged it
cp "$T/midnight.json" "$T/events.json"                      # today only the 01:00 half survives
python3 - "$T/events.json" <<'PY'
import json,sys
p=sys.argv[1]; e=json.load(open(p))
json.dump([x for x in e if x["event"]=="reopened"], open(p,"w"))
PY
run >/dev/null
[ "$(grep -c ',gamma,#21,' "$T/logs/reopens.csv")" = 1 ] && ok \
  || bad "an adjacent-day row for the same bounce must not be appended twice (got $(grep -c ',gamma,#21,' "$T/logs/reopens.csv"))"
[ -n "$YDAY" ] && ok || bad "date arithmetic unavailable"

# ---------- 9. an unreadable registry is LOUD, and still measures the four ---
# The fallback list is only useful if it reaches the snapshot lane. With no
# registry, board_prefix lookups fail; if that were allowed to read as "-" the
# four would divert to the GitHub lane, fail the repo lookup, and `continue`
# without a word — a silent no-op wearing a fallback's clothes, masked by
# stale rate rows that keep updating from the existing CSV.
NF="$T/nofleet"; mkdir -p "$NF/bin" "$NF/h/logs" "$NF/h/state" "$NF/h/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$NF/h/bin/"
cp "$DIR/bin/reopen-metrics.sh" "$DIR/bin/fleet-conf.sh" "$NF/bin/"
HARNESS="$NF/h" FLEET_CONF="$NF/does-not-exist.conf" bash "$NF/bin/reopen-metrics.sh" >/dev/null 2>&1
RJ2="$NF/h/state/reopen-rate.json"
grep -q 'fleet.conf unreadable' "$NF/h/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "an unreadable registry must announce itself in ALERTS.log"
jq -e 'has("project-1") and has("project-4")' "$RJ2" >/dev/null 2>&1 && ok \
  || bad "the fallback four must still get rows (got: $(cat "$RJ2" 2>/dev/null))"
grep -q 'project-1 snapshot failed' "$NF/h/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "the fallback four must route to the SNAPSHOT lane, not the GitHub lane"
grep -q 'project-1 gh issue events' "$NF/h/logs/ALERTS.log" 2>/dev/null \
  && bad "the fallback four must not be diverted to the GitHub lane" || ok

# ============================================================================
# The consumer: run-build.sh's tier demoter, extracted VERBATIM and driven with
# synthetic rate files. Demotion-only is the property under test — there is no
# input here that turns a tier-2 build into a tier-1 one, and there must never
# be one, because that is the difference between a trust metric and an
# auto-merge expansion nobody approved.
# ============================================================================
RB="$RB_ALL"
awk '/^# >>> reopen trust signal/{f=1;next}  /^# <<< reopen trust signal/{exit}  f' "$RB" > "$T/signal.sh"
awk '/^# >>> reopen trust demoter/{f=1;next} /^# <<< reopen trust demoter/{exit} f' "$RB" > "$T/demoter.sh"
awk '/^# >>> reopen extra lens/{f=1;next}    /^# <<< reopen extra lens/{exit}    f' "$RB" > "$T/lens.sh"
for B in signal demoter lens; do
  [ -s "$T/$B.sh" ] && ok || bad "could not extract the '$B' block from run-build.sh — markers missing?"
done

rate() { printf '%s' "$1" > "$T/rate.json"; }

# gate <project> <starting-tier> -> "<TIER>|<QA_NOTE>"   (env knobs inherited)
gate() {
  local HH="$T/h"; scratch_rm "$HH"; mkdir -p "$HH/state" "$HH/build"
  [ -s "$T/rate.json" ] && cp "$T/rate.json" "$HH/state/reopen-rate.json"
  HARNESS="$HH" BUILD="$HH/build" PROJECT="$1" KEY=K TIER="$2" \
  bash -c 'set -uo pipefail; STAMP(){ echo TS; }; QA_NOTE=""; . "$0"; . "$1"; printf "%s|%s" "$TIER" "$QA_NOTE"' \
    "$T/signal.sh" "$T/demoter.sh" 2>/dev/null
}
# lens <project> -> the RISKY value the review stage would see
lens() {
  local HH="$T/h"; scratch_rm "$HH"; mkdir -p "$HH/state" "$HH/build"
  [ -s "$T/rate.json" ] && cp "$T/rate.json" "$HH/state/reopen-rate.json"
  HARNESS="$HH" BUILD="$HH/build" PROJECT="$1" KEY=K RISKY=0 \
  bash -c 'set -uo pipefail; STAMP(){ echo TS; }; . "$0"; . "$1"; printf "%s" "$RISKY"' \
    "$T/signal.sh" "$T/lens.sh" 2>/dev/null
}

# 8. over the threshold with a real denominator -> forced tier-2, reason stated
rate '{"hot-os":{"reopens_14d":5,"builds_total":20}}'
G=$(gate hot-os 1)
[ "${G%%|*}" = 2 ] && ok || bad "0.25 > 0.15 must force tier-2 (got '$G')"
# TEST-CHANGE(BH-4581): wording only, tier logic unchanged
grep -q 'TRUST: reopen rate 0.25 (5/20, 14d) over 0.15 — recorded tier-2 (risk signal)' <<<"$G" && ok \
  || bad "the QA_NOTE must carry the ACTUAL rate, not just a verdict (got '$G')"

# 9. under the threshold -> untouched
rate '{"hot-os":{"reopens_14d":2,"builds_total":20}}'
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "0.10 <= 0.15 must not demote (got '$(gate hot-os 1)')"

# 10. tiny denominator -> untouched. 1-in-3 is 33% and means nothing.
rate '{"hot-os":{"reopens_14d":1,"builds_total":3}}'
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "below REOPEN_MIN_SAMPLE must not demote"
REOPEN_MIN_SAMPLE=2
export REOPEN_MIN_SAMPLE
[ "$(gate hot-os 1 | cut -d'|' -f1)" = 2 ] && ok || bad "REOPEN_MIN_SAMPLE must be tunable down"
unset REOPEN_MIN_SAMPLE

# 11. threshold is tunable
rate '{"hot-os":{"reopens_14d":5,"builds_total":20}}'
REOPEN_DEMOTE_RATE=0.30
export REOPEN_DEMOTE_RATE
[ "$(gate hot-os 1 | cut -d'|' -f1)" = 1 ] && ok || bad "REOPEN_DEMOTE_RATE must be tunable up"
unset REOPEN_DEMOTE_RATE

# 11b. a JUNK threshold must fail OPEN, not hot. awk coerces a non-numeric -v
# to 0, so `n/d > 0` is true for any project with a single reopen — one typo in
# global.env would demote the entire fleet.
rate '{"hot-os":{"reopens_14d":1,"builds_total":20}}'
REOPEN_DEMOTE_RATE=oops
export REOPEN_DEMOTE_RATE
[ "$(gate hot-os 1 | cut -d'|' -f1)" = 1 ] && ok || bad "a junk REOPEN_DEMOTE_RATE must not demote (0.05 is under the 0.15 default)"
REOPEN_DEMOTE_RATE=""
[ "$(gate hot-os 1 | cut -d'|' -f1)" = 1 ] && ok || bad "an empty REOPEN_DEMOTE_RATE must fall back to the default"
unset REOPEN_DEMOTE_RATE
REOPEN_MIN_SAMPLE=lots
export REOPEN_MIN_SAMPLE
rate '{"hot-os":{"reopens_14d":5,"builds_total":20}}'
[ "$(gate hot-os 1 | cut -d'|' -f1)" = 2 ] && ok || bad "a junk REOPEN_MIN_SAMPLE must fall back to 10, not break the gate"
unset REOPEN_MIN_SAMPLE

# 12. fail-open: no file, unparseable file, missing project, junk values
rm -f "$T/rate.json"
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "a missing rate file must change nothing"
rate 'not json at all'
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "an unparseable rate file must change nothing"
rate '{"other-os":{"reopens_14d":9,"builds_total":10}}'
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "another project's rate must not demote this one"
rate '{"hot-os":{"reopens_14d":"lots","builds_total":20}}'
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "non-numeric values must change nothing"

# 13. DEMOTION ONLY: the worst possible rate never promotes a tier-2 build.
rate '{"hot-os":{"reopens_14d":20,"builds_total":20}}'
[ "$(gate hot-os 2 | cut -d'|' -f1)" = 2 ] && ok || bad "tier-2 must stay tier-2"
rate '{"hot-os":{"reopens_14d":0,"builds_total":500}}'
[ "$(gate hot-os 2 | cut -d'|' -f1)" = 2 ] && ok || bad "a spotless record must NOT promote to tier-1"

# 14. the extra-lens knob is OFF by default and additive when armed
rate '{"hot-os":{"reopens_14d":5,"builds_total":20}}'
[ "$(lens hot-os)" = 0 ] && ok || bad "REOPEN_EXTRA_LENS must default OFF (got '$(lens hot-os)')"
REOPEN_EXTRA_LENS=1
export REOPEN_EXTRA_LENS
[ "$(lens hot-os)" = 1 ] && ok || bad "armed, a hot project must get the security lens"
rate '{"hot-os":{"reopens_14d":1,"builds_total":20}}'
[ "$(lens hot-os)" = 0 ] && ok || bad "armed but cold must still skip the lens"
unset REOPEN_EXTRA_LENS

echo "reopen-fleetconf-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
