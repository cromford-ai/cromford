#!/bin/bash
# tests/alert-line-wave-fly-review.bh-2314-test.sh — BH-2363 (BH-2314.1): the
# fly, auth and review/merge alert writers go through bin/alert-line.sh.
#
# Driven, not grepped (D2/D3): every case runs the REAL script from the
# checkout (`bash "$DIR/bin/<script>"`, HARNESS=<scratch>) into a scratch tree
# that holds the real bin/alert-line.sh and its readers plus a STUB bin/beat.sh
# that records each payload. A converted site shows up twice: as a
# kind:"alert" beat carrying the exact pre-conversion text, and as the same
# line in the scratch logs/ALERTS.log. A site still on the raw echo leaves the
# file line and no beat.
#
#   A1 update-model-prices: slug map absent  -> beat + line + sent marker
#   A2 claude-auth-check: no model route     -> rc 75, beat + line
#   A2b claude-auth-check canary loop: two new down lanes -> two lines, one
#       per lane (alert-state.sh and alerts-supersede.py read them one by one)
#   A3 fly-pool quarantine: 1 bad file -> original line; 3 -> ONE batched line
#   A3c/d fly-pool orphan page: 1 orphan -> original line; 3 -> ONE batched line
#   A4 fly-image-refresh: failed rebuild keeps its '%F %T Z' stamp
#   A5 no converted file routes through bin/lane-alert.sh: THIS diff adds no
#      lane-alert.sh line to the 12 (tests/lib/ratchet-delta.sh — against the
#      merge-base with main, so main's own moves cancel; no base is red), bar
#      a declared new page (LA_NEW). --strict / RATCHET_MODE=strict holds each
#      file to the counts pinned at BH-2363 instead.
#   A6 census: no raw ALERTS.log write and no ratchet baseline left in the 12
#
# Run from anywhere: tests/alert-line-wave-fly-review.bh-2314-test.sh (exit 0 = pass)
# No network, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
sha() { printf %s "$1" | sha1sum | cut -c1-40; }

# The twelve converted scripts, by rooted path (D41).
SCRIPTS=(
  "$DIR/bin/fly-pool.sh" "$DIR/bin/claude-auth-check.sh" "$DIR/bin/review-prs.sh"
  "$DIR/bin/harness-sync.sh" "$DIR/bin/update-model-prices.sh" "$DIR/bin/merge-sweep.sh"
  "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-image-refresh.sh" "$DIR/bin/review-rescue.sh"
  "$DIR/bin/fly-results-ingest.sh" "$DIR/bin/fly-pool-tick.sh" "$DIR/bin/merge-queue.sh"
)

export ALERTS_CONF="$T/alerts.conf"; : > "$ALERTS_CONF"
export FLEET_CONF="$T/fleet.conf"; : > "$FLEET_CONF"

# mktree <dir> — a scratch harness: the real helper and what it calls, and a
# beat.sh stub that appends every payload to <dir>/beats.jsonl.
mktree() {
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/locks"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$DIR/bin/project-of.sh" "$d/bin/"
  cp "$DIR/bin/lib/alert-state.sh" "$d/bin/lib/"
  cat > "$d/bin/beat.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$(cd "$(dirname "$0")/.." && pwd)/beats.jsonl"
exit 0
EOF
  chmod +x "$d/bin/beat.sh"
}
alert_beats() { jq -c 'select(.kind=="alert")' "$1/beats.jsonl" 2>/dev/null; }
nbeats() { local n; n=$(alert_beats "$1" | grep -c .); printf '%s' "${n:-0}"; }
# beat_line <dir> — the first alert beat's line minus its two stamp fields
beat_line() { alert_beats "$1" | head -1 | jq -r '.line'; }

echo "--- A1: update-model-prices, slug map absent"
H1="$T/a1"; mktree "$H1"
MODEL_SLUGS="$T/none.json" HARNESS="$H1" HARNESS_CHECKOUT="$T/nock" bash "$DIR/bin/update-model-prices.sh" >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "A1: rc $RC, want 0"
WANT1="model-prices: slug map absent at $T/none.json — no refresh, keeping existing table (catalog/model-slugs.json is the only map since BH-1510)"
if [ "$(nbeats "$H1")" = 1 ]; then ok; else bad "A1: stub received $(nbeats "$H1") alert beat(s), want 1"; fi
L1=$(beat_line "$H1")
[ "$(printf %s "$L1" | cut -d' ' -f3-)" = "$WANT1" ] && ok || bad "A1: stub received '$L1', want text '$WANT1'"
[[ "$L1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]] && ok || bad "A1: stamp of '$L1' is not '%F %TZ'"
grep -qxF -- "$L1" "$H1/logs/ALERTS.log" 2>/dev/null && [ -n "$L1" ] && ok \
  || bad "A1: ALERTS.log got the line? file='$(cat "$H1/logs/ALERTS.log" 2>/dev/null)'"
[ -n "$L1" ] && [ -e "$H1/state/alert-line-sent/$(sha "$L1")" ] && ok || bad "A1: no state/alert-line-sent marker for the line"

echo "--- A2: claude-auth-check, no model route"
H2="$T/a2"; mktree "$H2"
printf 'lane_role_model() { return 1; }\n' > "$H2/bin/lib/lane-model.sh"
HARNESS="$H2" bash "$DIR/bin/claude-auth-check.sh" >/dev/null 2>&1
RC=$?
[ "$RC" = 75 ] && ok || bad "A2: rc $RC, want 75"
WANT2="[auth] no model route for triage/auth.fallback — auth probe not run"
L2=$(beat_line "$H2")
if [ "$(nbeats "$H2")" = 1 ] && [ "$(printf %s "$L2" | cut -d' ' -f3-)" = "$WANT2" ]; then ok
else bad "A2: stub received $(nbeats "$H2") beat(s), line '$L2', want text '$WANT2'"; fi
[ -n "$L2" ] && grep -qxF -- "$L2" "$H2/logs/ALERTS.log" && ok || bad "A2: ALERTS.log got the line? '$(cat "$H2/logs/ALERTS.log" 2>/dev/null)'"

echo "--- A2b: claude-auth-check canary loop, one LANE DOWN line per lane"
# Modelled on tests/lane-down-canary.bh-1674-test.sh: hour forced to 06 so the
# 6h canary runs, one local box (hub), both claude lanes already down so only
# the lane loop speaks. grok and fireworks fail their probe; both are new.
REAL_DATE=$(command -v date)
H2B="$T/a2b"; mktree "$H2B"; mkdir -p "$H2B/fakebin"
cp "$DIR/bin/lib/lane-down.sh" "$H2B/bin/lib/"
echo 'lane_role_model() { echo m-test; }' > "$H2B/bin/lib/lane-model.sh"
printf '#!/bin/bash\nexit 0\n' > "$H2B/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$H2B/bin/box-for.sh"
printf '#!/bin/bash\nexit 0\n' > "$H2B/bin/lane-alert.sh"
cat > "$H2B/bin/lane-probe.sh" <<'SH'
#!/bin/bash
R=$(dirname "$0")/..
if [ -f "$R/probe-$1" ]; then cat "$R/probe-$1"; else echo ok; fi
SH
cat > "$H2B/fakebin/date" <<SH
#!/bin/bash
for a in "\$@"; do [ "\$a" = "+%H" ] && { echo 06; exit 0; }; done
exec $REAL_DATE "\$@"
SH
printf '#!/bin/bash\necho "Not logged in · Please run /login"\n' > "$H2B/fakebin/claude"
printf '#!/bin/bash\nexit 1\n' > "$H2B/fakebin/ssh"
printf '#!/bin/bash\nclaude -p "$6" --model "$3" >"$5" 2>"$5.err"; exit $?\n' > "$H2B/bin/agent-call.sh"
chmod +x "$H2B"/bin/*.sh "$H2B"/fakebin/*
printf 'hub\nproject-1-lane\n' > "$H2B/state/claude-auth-down.txt"
echo 'grok 503 upstream' > "$H2B/probe-grok"
echo 'fireworks 401 denied' > "$H2B/probe-fireworks"
HARNESS="$H2B" PATH="$H2B/fakebin:$PATH" bash "$DIR/bin/claude-auth-check.sh" >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "A2b: rc $RC, want 0"
for ln in grok fireworks; do
  W="[auth] hub-$ln LANE DOWN (new)"
  n=$(alert_beats "$H2B" | jq -r '.line' | cut -d' ' -f3- | grep -cxF -- "$W")
  [ "$n" = 1 ] && ok || bad "A2b: $n alert beat(s) with text '$W', want 1: $(alert_beats "$H2B")"
  n=$(cut -d' ' -f3- "$H2B/logs/ALERTS.log" 2>/dev/null | grep -cxF -- "$W")
  [ "$n" = 1 ] && ok || bad "A2b: ALERTS.log holds $n line(s) '$W', want 1: $(cat "$H2B/logs/ALERTS.log" 2>/dev/null)"
done
[ "$(nbeats "$H2B")" = 2 ] && ok || bad "A2b: $(nbeats "$H2B") alert beats, want 2 (one per lane, never joined)"

echo "--- A3: fly-pool malformed-queue quarantine"
# pool3 <dir> <n> — a pool project 'tp' with <n> key-less queue files, one
# tick of the real bin/fly-pool.sh with a fly stub that lists no machines.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/fly" <<'EOF'
#!/bin/bash
case "$*" in *"machines list"*|*"machine list"*) echo '[]';; esac
exit 0
EOF
chmod +x "$T/fakebin/fly"
pool3() {
  local d="$1" n="$2" i
  mktree "$d"
  mkdir -p "$d/env" "$d/state/fly" "$d/state/build-queue/tp"
  printf 'FLY_API_TOKEN_TP=tok\n' > "$d/env/fly.env"; : > "$d/env/global.env"
  printf '3\n' > "$d/flags/fly-pool-tp"
  printf 'pool-tp\n' > "$d/flags/fly-pool-app-tp"
  printf '{"app":"pool-tp"}\n' > "$d/state/fly/tp.json"
  printf 'registry.fly.io/pool-tp:deploy-01\n' > "$d/state/fly/tp.image"
  for i in $(seq 1 "$n"); do
    printf '{}\n' > "$d/state/build-queue/tp/q$i.json"
  done
  HARNESS="$d" FLY_BIN_DIR="$T/fakebin" timeout 120 bash "$DIR/bin/fly-pool.sh" tp >/dev/null 2>&1
}
H3="$T/a3a"; pool3 "$H3" 1
WANT3="[pool/tp] QUARANTINED malformed queue entry q1.json (key='' ticket='') — find its producer"
L3=$(beat_line "$H3")
if [ "$(nbeats "$H3")" = 1 ] && [ "$(printf %s "$L3" | cut -d' ' -f3-)" = "$WANT3" ]; then ok
else bad "A3a: stub received $(nbeats "$H3") beat(s), line '$L3', want text '$WANT3'"; fi
[ -n "$L3" ] && grep -qxF -- "$L3" "$H3/logs/ALERTS.log" && ok || bad "A3a: ALERTS.log got the line? '$(cat "$H3/logs/ALERTS.log" 2>/dev/null)'"
[ -f "$H3/state/build-queue/tp/q1.json.bad" ] && ok || bad "A3a: q1.json was not quarantined to .bad"

H3="$T/a3b"; pool3 "$H3" 3
L3=$(beat_line "$H3")
if [ "$(nbeats "$H3")" = 1 ]; then ok; else bad "A3b: stub received $(nbeats "$H3") alert beat(s) for 3 bad files, want exactly 1"; fi
# The queue is walked `ls -tr`, so the entries come in mtime order, not by name.
T3=$(printf %s "$L3" | cut -d' ' -f3-)
case "$T3" in
  "[pool/tp] QUARANTINED 3 malformed queue entries: "*" — find their producer") ok ;;
  *) bad "A3b: batched line '$L3' is not the batch form" ;;
esac
for q in q1 q2 q3; do
  case "$T3" in *"$q.json (key='' ticket='')"*) ok ;; *) bad "A3b: batched line '$L3' does not name $q.json" ;; esac
done
N3=$(grep -c 'QUARANTINED' "$H3/logs/ALERTS.log" 2>/dev/null)
[ "${N3:-0}" = 1 ] && [ -n "$L3" ] && grep -qxF -- "$L3" "$H3/logs/ALERTS.log" && ok \
  || bad "A3b: ALERTS.log holds ${N3:-0} QUARANTINED line(s), want the one batched line"
N3B=$(ls "$H3/state/build-queue/tp/"*.bad 2>/dev/null | wc -l)
[ "$N3B" = 3 ] && ok || bad "A3b: $N3B of 3 files quarantined to .bad"

echo "--- A3c/d: fly-pool orphan page"
# The in-tick reap closes every job on a machine Fly no longer returns, so the
# sweep's last-resort orphan page is reached the way tests/fly-orphan-jobs-test.sh
# section 5 reaches it: the `# >>> dead-machine sweep` region of the real
# bin/fly-pool.sh, extracted verbatim and sourced with the tick's variables.
orph() { # orph <dir> <n> — n pool files on machines the listing does not carry
  local d="$1" n="$2" i
  mktree "$d"; mkdir -p "$d/pool"
  sed -n '/^# >>> dead-machine sweep (BH-660)/,/^# <<< dead-machine sweep/p' "$DIR/bin/fly-pool.sh" > "$d/sweep.sh"
  for i in $(seq 1 "$n"); do
    jq -nc --arg m "m${i}ghost" --arg k "OJ-$i" '{machine:$m,key:$k,ticket_id:"9"}' > "$d/pool/m${i}ghost.json"
  done
  printf '[{"id":"m4smoke","state":"started","updated_at":"%s"}]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$d/listing.json"
  ( set +u
    HARNESS="$d"; P=tproj; APP=pool-tproj; POOL="$d/pool"; POOL_APP=pool-tproj
    LIST_OK=1; LISTING="$d/listing.json"; LIST_WHY=""; REAPED_IDS=" "
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    say() { echo "$*" >> "$d/logs/fly-pool.log"; }
    destroy_machine() { return 0; }
    . "$d/sweep.sh" ) >/dev/null 2>&1
}
H3="$T/a3c"; orph "$H3" 1
[ -s "$H3/sweep.sh" ] && grep -q 'orphan_jobs' "$H3/sweep.sh" && ok || bad "A3c: could not extract the dead-machine sweep region"
WANT3C="[pool/tproj] OJ-1 still tracked on m1ghost which Fly no longer returns after the reap — the dead path did not close it"
L3=$(beat_line "$H3")
if [ "$(nbeats "$H3")" = 1 ] && [ "$(printf %s "$L3" | cut -d' ' -f3-)" = "$WANT3C" ]; then ok
else bad "A3c: stub received $(nbeats "$H3") beat(s), line '$L3', want text '$WANT3C'"; fi
[ -n "$L3" ] && grep -qxF -- "$L3" "$H3/logs/ALERTS.log" && ok || bad "A3c: ALERTS.log got the line? '$(cat "$H3/logs/ALERTS.log" 2>/dev/null)'"

H3="$T/a3d"; orph "$H3" 3
L3=$(beat_line "$H3"); T3=$(printf %s "$L3" | cut -d' ' -f3-)
[ "$(nbeats "$H3")" = 1 ] && ok || bad "A3d: stub received $(nbeats "$H3") alert beat(s) for 3 orphans, want exactly 1"
case "$T3" in
  "[pool/tproj] 3 jobs still tracked on machines Fly no longer returns after the reap — the dead path did not close them: "*) ok ;;
  *) bad "A3d: batched line '$L3' is not the batch form" ;;
esac
for i in 1 2 3; do
  case "$T3" in *"OJ-$i still tracked on m${i}ghost"*) ok ;; *) bad "A3d: batched line '$L3' does not name OJ-$i" ;; esac
  ls "$H3/flags/alerted-pool-orphan-tproj-OJ-$i-"* >/dev/null 2>&1 && ok || bad "A3d: per-key dated flag for OJ-$i not touched"
done
[ "$(grep -c 'still tracked on' "$H3/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "A3d: ALERTS.log holds $(grep -c 'still tracked on' "$H3/logs/ALERTS.log" 2>/dev/null) orphan line(s), want 1"
[ "$(jq -r '.orphan_jobs | length' "$H3/pool/.sweep.json" 2>/dev/null)" = 3 ] && ok \
  || bad "A3d: .sweep.json must still list all 3 orphans: $(cat "$H3/pool/.sweep.json" 2>/dev/null)"
# The flags dedupe the page: a second pass over the same orphans says nothing.
: > "$H3/beats.jsonl"
( set +u
  HARNESS="$H3"; P=tproj; APP=pool-tproj; POOL="$H3/pool"; POOL_APP=pool-tproj
  LIST_OK=1; LISTING="$H3/listing.json"; LIST_WHY=""; REAPED_IDS=" "
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }; say() { :; }; destroy_machine() { return 0; }
  . "$H3/sweep.sh" ) >/dev/null 2>&1
[ "$(nbeats "$H3")" = 0 ] && ok || bad "A3d: flagged orphans paged again: $(alert_beats "$H3")"

echo "--- A4: fly-image-refresh keeps its '%F %T Z' stamp"
H4="$T/a4"; mktree "$H4"
mkdir -p "$H4/state/fly"
: > "$H4/flags/fly-pool-tproj"
printf '#!/bin/bash\nexit 1\n' > "$H4/bin/fly-image-build.sh"; chmod +x "$H4/bin/fly-image-build.sh"
HARNESS="$H4" bash "$DIR/bin/fly-image-refresh.sh" >/dev/null 2>&1
L4=$(beat_line "$H4")
if [ "$(nbeats "$H4")" = 1 ] && [ "$(printf %s "$L4" | cut -d' ' -f4-)" = "[tproj] nightly builder-image rebuild FAILED — pool runs yesterday's image until fixed" ]; then ok
else bad "A4: stub received $(nbeats "$H4") beat(s), line '$L4'"; fi
[[ "$L4" =~ ^[0-9-]{10}\ [0-9:]{8}\ Z\  ]] && ok || bad "A4: stamp of '$L4' is not '%F %T Z' (space before Z)"
[ -n "$L4" ] && grep -qxF -- "$L4" "$H4/logs/ALERTS.log" && ok || bad "A4: ALERTS.log got the line? '$(cat "$H4/logs/ALERTS.log" 2>/dev/null)'"

echo "--- A5: nothing new routes through bin/lane-alert.sh"
# DELTA (the default): each file's count at HEAD may not exceed its count at
# the base, the merge-base with main (rd_base), plus its declared new pages.
# The old check compared to origin/main's TIP for equality, so main moving
# past the branch either way, or a new page (PR #2872) turned it red; the base
# makes main's own moves cancel, and fewer calls is never a violation.
# A NEW page (not a converted ALERTS.log writer) may legitimately route through
# lane-alert.sh for its --id state machine. Declare it in LA_NEW by its --id
# prefix: the allowance counts only prefixes HEAD has and the base lacks, so it
# retires itself once the page is on main, and an undeclared line stays red.
#   LA_NEW=( [<script>]="<id-prefix> <id-prefix> ..." )
#   BH-2674 (blocked-resolver): fix-round-queue-missing-, fix-round-unclaimed-,
#   fix-round-stale-claim- — one call each.
#   BH-3630 (blocked-resolver): br-unmapped- — one call, the warn page per
#   unmapped BLOCKED_HUMAN reason family.
#   BH-3990 (update-model-prices): model-prices-catalog-stale — one call, the
#   warn page (and its resolve) for a committed price catalog past its age.
#   BH-4926 (blocked-resolver): data-lane-escalate: — one call, the warn page a
#   data-lane park sends once per fp (br_dl_escalate).
declare -A LA_NEW=( [blocked-resolver]="fix-round-queue-missing- fix-round-unclaimed- fix-round-stale-claim- br-unmapped- data-lane-escalate: review-cap-notes:" [update-model-prices]="model-prices-catalog-stale" )
# STRICT (--strict / RATCHET_MODE=strict): the counts pinned at BH-2363 are a
# per-file ceiling; blocked-resolver is 19 + BH-2674's three fix-round pages
# + BH-3630's br-unmapped- page; update-model-prices is 6 + BH-3990's
# catalog-stale page.
declare -A LA=( [update-model-prices]=7 [claude-auth-check]=2 [blocked-resolver]=23 )
# a5_check <repo> — one line per file over its bound, rc 1 if any. Reads
# A5_MODE, LA and LA_NEW; the twelve scripts are looked up under <repo>/bin.
a5_check() {
  local repo="$1" base="" f s n want base_src id rc=0
  if [ "$A5_MODE" = delta ]; then base=$(rd_base "$repo") || { echo "A5: $base"; return 1; }; fi
  for s in "${SCRIPTS[@]}"; do
    f=$(basename "$s" .sh)
    [ -f "$repo/bin/$f.sh" ] || continue
    n=$(grep -c 'lane-alert.sh' "$repo/bin/$f.sh")
    if [ "$A5_MODE" = strict ]; then want=${LA[$f]:-0}
    else
      base_src=$(git -C "$repo" show "$base:bin/$f.sh" 2>/dev/null)
      want=$(printf '%s\n' "$base_src" | grep -c 'lane-alert.sh')
      for id in ${LA_NEW[$f]:-}; do
        grep -q -- "--id \"$id" "$repo/bin/$f.sh" || continue
        grep -q -- "--id \"$id" <<<"$base_src" && continue
        want=$((want + 1))
      done
    fi
    [ "$n" -le "$want" ] && continue
    echo "A5: bin/$f.sh names lane-alert.sh $n time(s), at most $want ($A5_MODE${base:+, base ${base:0:12}}) — a converted writer goes through bin/alert-line.sh; a new page declares its --id prefix in LA_NEW"
    rc=1
  done
  return $rc
}
A5_MODE=$(rd_mode "$@") || { bad "A5: $A5_MODE"; A5_MODE=delta; }
OUT=$(a5_check "$DIR"); [ $? = 0 ] && ok || bad "$OUT"

# A5 drift cases, hermetic: B has bin/blocked-resolver.sh with one lane-alert.sh line.
a5_repo() {
  scratch_rm "$1" || return 1; mkdir -p "$1/bin"
  # main edits the top, the PR the bottom, so the queue-draft merge is clean
  printf '#!/bin/bash\n: top\n: 1\n: 2\n: 3\n: 4\nbin/lane-alert.sh --id "old-page-x" m\n' > "$1/bin/blocked-resolver.sh"
  rd_fixture_repo "$1"
}
a5_main_add() { sed -i 's/^: top$/bin\/lane-alert.sh --id "main-page-y" m/' "$1/bin/blocked-resolver.sh"; }
a5_main_drop() { printf '#!/bin/bash\ntrue\n' > "$1/bin/blocked-resolver.sh"; }
a5_pr_add()   { echo 'bin/lane-alert.sh --id "pr-page-z" m' >> "$1/bin/blocked-resolver.sh"; rd_git "$1" commit -qam pr; }
a5_pr_docs()  { echo d >> "$1/README"; rd_git "$1" commit -qam docs; }
# a second call under a prefix main already carries: the allowance has retired
a5_pr_add_main_prefix() { echo 'bin/lane-alert.sh --id "main-page-y2" m' >> "$1/bin/blocked-resolver.sh"; rd_git "$1" commit -qam pr2; }
a5_case() {  # <name> <want_rc> <mode> <LA_NEW for blocked-resolver> <steps...>
  local name="$1" want="$2" mode="$3" decl="$4" R="$T/a5-$1" step out rc
  shift 4
  a5_repo "$R" || { bad "A5 case $name: setup"; return; }
  for step in "$@"; do
    case "$step" in
      main-add)  rd_main_commit "$R" 'main adds a page' a5_main_add ;;
      main-drop) rd_main_commit "$R" 'main drops a page' a5_main_drop ;;
      merge)     rd_git "$R" merge -q --no-edit refs/remotes/origin/main ;;
      nomain)    rd_git "$R" update-ref -d refs/remotes/origin/main ;;
      *)         "$step" "$R" ;;
    esac >/dev/null 2>&1 || { bad "A5 case $name: step $step"; return; }
  done
  out=$(A5_MODE="$mode"; LA_NEW=( [blocked-resolver]="$decl" ); LA=( [blocked-resolver]=1 ); RATCHET_BASE= TI_BASE= a5_check "$R"); rc=$?
  [ "$rc" = "$want" ] && ok || bad "A5 case $name: rc=$rc want $want: $out"
}
a5_case main-adds-branch-behind 0 delta '' main-add a5_pr_docs
a5_case main-drops-branch-behind 0 delta '' main-drop a5_pr_docs
a5_case main-adds-queue-draft  0 delta '' a5_pr_docs main-add merge
a5_case pr-adds-undeclared     1 delta '' a5_pr_add
a5_case pr-adds-after-drift    1 delta '' main-add a5_pr_add merge
a5_case pr-adds-declared       0 delta 'pr-page-' a5_pr_add
a5_case declared-other-prefix  1 delta 'other-' a5_pr_add
a5_case declared-already-on-main 1 delta 'main-page-' main-add merge a5_pr_add_main_prefix
a5_case no-base                1 delta '' a5_pr_docs nomain
a5_case strict-ceiling         1 strict '' a5_pr_docs main-add merge

echo "--- A6: census"
for s in "${SCRIPTS[@]}"; do
  f=$(basename "$s" .sh)
  n=$(grep -cE '>>\s*"?[^ ]*ALERTS\.log' "$s")
  [ "$n" = 0 ] && ok || bad "A6: bin/$f.sh still has $n raw ALERTS.log write(s)"
  [ ! -e "$DIR/tests/alert-writers-ratchet-baseline/$f.sh.txt" ] && ok || bad "A6: baseline $f.sh.txt still exists"
done

echo "alert-line-wave-fly-review: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
