#!/bin/bash
# tests/orphan-reconcile-prlist.bh-8271-test.sh — BH-8271: orphan-reconcile
# reuses its last open-PR list read while no `pr` wake rang for the repo and
# the copy is no older than PR_RECORD_MAX_AGE_S (default 900). Every GitHub
# list read it makes instead logs one `PRR_MISS <repo>#list why=<no-row|stale>`.
#
# The REAL bin/orphan-reconcile.sh runs on a fixture board: open ai-build
# issues #11, #12, #13 and open PRs #101 (head ticket/TK-11, owns #11), #102
# (body `Closes #12`, owns #12) and #103 (unrelated); #13 has no owner. gh and
# curl are PATH shims; prs_wake_seen is an exported table double (lines
# `kind key rc`, `*` matches anything, a `-` query key matches every key, like
# the real feed; no match rc 1). Each case copies a fresh $H from one template.
#
#   P1  no copy: 1 pulls read, 1 PRR_MISS why=no-row, copy written, pl=read
#   P2  +300 s, feed quiet: 0 pulls reads, 0 PRR_MISS, pl=hit, same verdicts
#   P3  a `pr 104` wake (new PR #104 claims #13): 1 read, why=stale, #13 OWNED;
#       an `issue 11` or `checks <sha>` wake only: hit
#   P4  copy age 899 and 900: hit; 901: read why=stale
#   P5  the feed cannot tell (rc 2): read why=stale
#   P6  PR_RECORD_MAX_AGE_S=0 / WAKE_BACKSTOP=0: read, even at age 0; no wake-backstop.sh:
#       read every run, no copy written, no PRR_MISS
#   P7  every pulls call answers 500: with a copy the tick completes from it
#       (0 pulls reads, same verdicts); with no copy it enqueues nothing
#   P8  no per-PR read (pulls/<n>, reviews, check-runs, status) in any case
#   P9  truncated json / missing meta: read why=stale, copy rewritten
#   P10 150 open PRs (two pages): the copy holds and serves all 150
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/orphan-reconcile-prlist.bh-8271-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

TPL="$T/tpl"
mkdir -p "$TPL/bin/lib" "$TPL/logs" "$TPL/state" "$TPL/locks" "$TPL/flags" "$TPL/env" \
         "$TPL/prompts" "$TPL/builds" "$TPL/fixture" "$T/fakebin"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh \
         bin/lib/wake-backstop.sh bin/lib/pr-record.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$TPL/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$TPL/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$TPL/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TPL/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TPL/bin/pr-owner-sweep.sh"
chmod +x "$TPL/bin/"*.sh

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
jq -n --arg u "$(ISO 86400)" '[11,12,13] | map({number: ., title: "TK-\(.) ticket \(.)", body: "## Scope", comments: 0, updated_at: $u})' \
  > "$TPL/fixture/open.json"
jq -n '[{number:101, title:"wip", head:{ref:"ticket/TK-11"}, body:""},
        {number:102, title:"a fix", head:{ref:"feature/x"}, body:"Closes #12"},
        {number:103, title:"chore: deps", head:{ref:"deps/bump"}, body:""}]' > "$TPL/fixture/prs.json"

# gh: the open board, the all-states list, the PR list (pages of 100 from
# fixture/prs.json; $HARNESS/pulls-status set = every pulls call answers it).
# Every call is logged to $HARNESS/gh-calls.log.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
ARGS="$*"
printf '%s\n' "$ARGS" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*[ ?&]page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/pulls"*)
    [ -f "$HARNESS/pulls-status" ] && SEND "$(cat "$HARNESS/pulls-status")" '{"message":"no"}'
    SEND 200 "$(jq -c --argjson p "$PAGE" '.[(($p - 1) * 100):($p * 100)]' "$HARNESS/fixture/prs.json")" ;;
  *"/issues/"*) SEND 404 '{"message":"Not Found"}' ;;
  *"/issues"*"state=all"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(cat "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# The double, exported so the lane's own shell inherits it.
prs_wake_seen() {
  local r
  printf 'WAKE %s %s %s %s\n' "$@" >> "$HARNESS/wake.calls"
  [ -f "$HARNESS/wake" ] || return 2
  r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*" || key == "-") { print $3; exit }' "$HARNESS/wake")
  return "${r:-1}"
}
export -f prs_wake_seen

# fresh <case> — a new $H copied from the template, feed quiet.
fresh() {
  H="$T/$1"
  cp -a "$TPL" "$H" || { echo "setup: could not copy the template for $1"; exit 1; }
  export HARNESS="$H"
  printf '* * 1\n' > "$H/wake"
  CD="$H/state/orphan-reconcile/example-org_project-5"
}
# run [VAR=val...] — one pass, the grace markers dropped first so every run
# sees the same board. Each run starts its own call log.
run() {
  cat "$H/gh-calls.log" >> "$H/gh-calls.all" 2>/dev/null
  rm -f "$H/state/orphan-reconcile/$P"/*.enqueued "$H/gh-calls.log"
  OUT=$(env HARNESS_TEST_SANDBOX=1 "$@" "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null)
  LOGS=$(cat "$H/logs/$P.log" 2>/dev/null)
  : > "$H/logs/$P.log"
}
pulls()   { grep -c -- 'repos/example-org/project-5/pulls' "$H/gh-calls.log" 2>/dev/null; }
misses()  { grep -c 'PRR_MISS' <<<"$LOGS"; }
miss()    { grep -c "PRR_MISS example-org/project-5#list why=$1\$" <<<"$LOGS"; }
summary() { grep -o 'reconcile: open=.*' <<<"$LOGS" | tail -1; }
verdicts() { awk -F'\t' '$1 ~ /^TK-/ {print $1"\t"$3"\t"$4}' <<<"$OUT" | sort; }
stamp()   { printf -- '-\t%s\n' "$1" > "$CD/prlist.meta"; }   # stamp <epoch>
v13()     { awk -F'\t' '$1=="TK-13" {print $3"\t"$4}' <<<"$OUT"; }

# ── P1 ─────────────────────────────────────────────────────────────────────
fresh p1
run
[ "$(pulls)" = 1 ] && ok || bad "P1 wanted 1 pulls read, got $(pulls): $(cat "$H/gh-calls.log")"
[ "$(misses)" = 1 ] && [ "$(miss no-row)" = 1 ] && ok || bad "P1 wanted one PRR_MISS why=no-row: $(grep PRR_MISS <<<"$LOGS")"
[ -s "$CD/prlist.json" ] && [ -s "$CD/prlist.meta" ] && ok || bad "P1 no copy written: $(ls "$CD" 2>&1)"
summary | grep -q ' pl=read ' && ok || bad "P1 summary '$(summary)', wanted pl=read"
V1=$(verdicts)
grep -q $'^TK-11\tOWNED\tpr:#101' <<<"$V1" && grep -q $'^TK-12\tOWNED\tpr:#102' <<<"$V1" \
  && grep -q $'^TK-13\tORPHAN' <<<"$V1" && ok || bad "P1 verdicts: $V1"

# ── P2 ─────────────────────────────────────────────────────────────────────
stamp "$NOW"
run WAKE_BACKSTOP_NOW=$((NOW + 300))
[ "$(pulls)" = 0 ] && ok || bad "P2 wanted 0 pulls reads, got $(pulls)"
[ "$(misses)" = 0 ] && ok || bad "P2 wanted no PRR_MISS: $(grep PRR_MISS <<<"$LOGS")"
summary | grep -q ' pl=hit ' && ok || bad "P2 summary '$(summary)', wanted pl=hit"
[ "$(verdicts)" = "$V1" ] && ok || bad "P2 verdicts differ from P1: $(verdicts)"
grep -q '^WAKE example-org/project-5 pr - ' "$H/wake.calls" && ok || bad "P2 the feed was not asked for a pr wake on any key: $(cat "$H/wake.calls" 2>/dev/null)"

# ── P3 ─────────────────────────────────────────────────────────────────────
fresh p3
run
stamp "$NOW"
jq '. + [{number:104, title:"TK-13: the fix", head:{ref:"ticket/TK-13"}, body:""}]' "$H/fixture/prs.json" > "$H/fixture/prs.new" \
  && mv "$H/fixture/prs.new" "$H/fixture/prs.json"
printf 'pr 104 0\n* * 1\n' > "$H/wake"
run WAKE_BACKSTOP_NOW=$((NOW + 60))
[ "$(pulls)" = 1 ] && [ "$(misses)" = 1 ] && [ "$(miss stale)" = 1 ] && ok \
  || bad "P3 a pr wake wanted 1 read + 1 why=stale, got $(pulls) / $(grep PRR_MISS <<<"$LOGS")"
v13 | grep -q $'^OWNED\tpr:#104' && ok || bad "P3 TK-13 '$(v13)', wanted OWNED by #104"
for W in 'issue 11 0' 'checks 0123abcd 0'; do
  fresh "p3-${W%% *}"
  run
  stamp "$NOW"
  printf '%s\n* * 1\n' "$W" > "$H/wake"
  run WAKE_BACKSTOP_NOW=$((NOW + 60))
  [ "$(pulls)" = 0 ] && [ "$(misses)" = 0 ] && ok || bad "P3 a '$W' wake only wanted a hit, got $(pulls) reads"
done

# ── P4 ─────────────────────────────────────────────────────────────────────
for A in 899 900 901; do
  fresh "p4-$A"
  run
  stamp $((NOW - 1000))
  run WAKE_BACKSTOP_NOW=$((NOW - 1000 + A))
  if [ "$A" = 901 ]; then
    [ "$(pulls)" = 1 ] && [ "$(miss stale)" = 1 ] && ok || bad "P4 age $A wanted a read why=stale, got $(pulls): $(grep PRR_MISS <<<"$LOGS")"
  else
    [ "$(pulls)" = 0 ] && [ "$(misses)" = 0 ] && ok || bad "P4 age $A wanted a hit, got $(pulls) reads"
  fi
done

# ── P5 ─────────────────────────────────────────────────────────────────────
fresh p5
run
stamp "$NOW"
printf '* * 2\n' > "$H/wake"
run WAKE_BACKSTOP_NOW=$((NOW + 60))
[ "$(pulls)" = 1 ] && [ "$(miss stale)" = 1 ] && ok || bad "P5 a feed that cannot tell wanted a read why=stale, got $(pulls)"

# ── P6 ─────────────────────────────────────────────────────────────────────
for K in PR_RECORD_MAX_AGE_S=0 WAKE_BACKSTOP=0; do
  fresh "p6-${K%%=*}"
  run "$K"
  stamp "$NOW"
  # Age 0: only the knob (or the switch) can refuse the copy.
  run "$K" WAKE_BACKSTOP_NOW="$NOW"
  [ "$(pulls)" = 1 ] && [ "$(miss stale)" = 1 ] && ok || bad "P6 $K wanted a read why=stale on run 2, got $(pulls)"
done
fresh p6-nolib
rm -f "$H/bin/lib/wake-backstop.sh"
run
run
[ "$(pulls)" = 1 ] && ok || bad "P6 no wake-backstop.sh wanted a read every run, got $(pulls)"
[ -e "$CD/prlist.json" ] && bad "P6 no wake-backstop.sh still wrote a copy" || ok
[ "$(misses)" = 0 ] && ok || bad "P6 no wake-backstop.sh logged PRR_MISS (no copy is kept, so nothing is missed)"
[ "$(verdicts)" = "$V1" ] && ok || bad "P6 no wake-backstop.sh verdicts differ: $(verdicts)"

# ── P7 ─────────────────────────────────────────────────────────────────────
fresh p7
run
stamp "$NOW"
echo 500 > "$H/pulls-status"
run WAKE_BACKSTOP_NOW=$((NOW + 60))
[ "$(pulls)" = 0 ] && ok || bad "P7 a valid copy wanted 0 pulls reads, got $(pulls)"
[ "$(verdicts)" = "$V1" ] && ok || bad "P7 verdicts from the copy differ from P1: $(verdicts)"
fresh p7-nocopy
echo 500 > "$H/pulls-status"
run
grep -q 'reconcile: the open PR list unverifiable' <<<"$LOGS" && ok || bad "P7 no copy + failing gh: no unverifiable line: $LOGS"
[ -s "$H/launches.log" ] && bad "P7 no copy + failing gh launched: $(cat "$H/launches.log")" || ok
[ -e "$CD/prlist.json" ] && bad "P7 a failed read wrote a copy" || ok

# ── P9 ─────────────────────────────────────────────────────────────────────
fresh p9-trunc
run
stamp "$NOW"
head -c 20 "$CD/prlist.json" > "$CD/prlist.cut" && mv "$CD/prlist.cut" "$CD/prlist.json"
run WAKE_BACKSTOP_NOW=$((NOW + 60))
[ "$(pulls)" = 1 ] && [ "$(miss stale)" = 1 ] && ok || bad "P9 a truncated copy wanted a read why=stale, got $(pulls): $(grep PRR_MISS <<<"$LOGS")"
jq -e 'length == 3' "$CD/prlist.json" >/dev/null 2>&1 && ok || bad "P9 the truncated copy was not rewritten"
[ "$(verdicts)" = "$V1" ] && ok || bad "P9 verdicts after a truncated copy: $(verdicts)"
fresh p9-meta
run
rm -f "$CD/prlist.meta"
run WAKE_BACKSTOP_NOW=$((NOW + 60))
[ "$(pulls)" = 1 ] && [ "$(miss stale)" = 1 ] && ok || bad "P9 a missing meta wanted a read why=stale, got $(pulls): $(grep PRR_MISS <<<"$LOGS")"

# ── P10 ────────────────────────────────────────────────────────────────────
fresh p10
jq -n '[range(101; 251) | {number: ., title: "pr \(.)", head:{ref:"b/\(.)"}, body:""}]
       | .[0].head.ref = "ticket/TK-11" | .[149].body = "Closes #13"' > "$H/fixture/prs.json"
run
[ "$(jq 'length' "$CD/prlist.json" 2>/dev/null)" = 150 ] && ok || bad "P10 the copy holds $(jq 'length' "$CD/prlist.json" 2>&1) PRs, wanted 150"
stamp "$NOW"
run WAKE_BACKSTOP_NOW=$((NOW + 60))
[ "$(pulls)" = 0 ] && ok || bad "P10 run 2 wanted a hit, got $(pulls)"
v13 | grep -q $'^OWNED\tpr:#250' && ok || bad "P10 the hit lost PR #250 on page 2: TK-13 '$(v13)'"

# ── P8 ─────────────────────────────────────────────────────────────────────
ALL=$(cat "$T"/*/gh-calls.all "$T"/*/gh-calls.log 2>/dev/null)
[ -n "$ALL" ] && ok || bad "P8 no gh call log at all"
grep -E 'pulls/[0-9]|/reviews|/check-runs|/status|/commits/' <<<"$ALL" && bad "P8 a per-PR read happened" || ok

echo "orphan-reconcile-prlist: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
