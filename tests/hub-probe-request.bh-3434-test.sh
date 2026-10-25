#!/bin/bash
# tests/hub-probe-request.bh-3434-test.sh — the hub-probe request path
# (BH-3451, BH-3434.4): `HUB_PROBE:` lines in a build's review.md or the
# builder's final output are parsed by bin/lib/hub-probes/request.sh and filed
# through the contract's hp_request, from RESULT() in bin/run-build.sh.
# _jobs_req is redefined after the source to log `METHOD PATH BODY`, so
# "nothing was filed" is an empty call log.
#   S1-S2   the lib exists, parses, carries no /root/harness literal (D43)
#   R1-R3   valid lines: exact parse output, one POST per line, dedup, rc 1 on outage
#   N1-N15  adversarial lines: empty parse output and ZERO POSTs
#   N16     control characters are dropped even when hp_validate would accept
#   L1      a dropped HUB_PROBE: line is logged on stderr
#   U1      an unreadable file: parser rc 2, no POST
#   P1-P4   the REAL RESULT() block and seam block from the pipeline text
#           (bin/run-build.sh flattened by tests/lib/rb-all.sh) (D2)
#   G1-G2   the prompts the build and review stages load carry the rule
# Run from anywhere: tests/hub-probe-request.bh-3434-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

REQ="$DIR/bin/lib/hub-probes/request.sh"
# --- S1-S2 ------------------------------------------------------------------
[ -f "$REQ" ] && bash -n "$REQ" 2>/dev/null && ok || bad "S1 missing or unparseable $REQ"
if [ -f "$REQ" ] && ! grep -q '/root/harness' "$REQ"; then ok; else bad "S2 $REQ is missing or carries a /root/harness literal"; fi

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/hub-probes" "$T/b"
cp "$DIR/bin/lib/jobs/hub-probe.sh" "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/hub-probes/common.sh" "$H/bin/lib/hub-probes/"
cp "$REQ" "$H/bin/lib/hub-probes/" 2>/dev/null
CALLS="$T/calls.log"; RCF="$T/rc"
export CALLS RCF H
STUBS='_jobs_req() { printf "%s %s %s\n" "$1" "$2" "${3:-}" >> "$CALLS"; [ "$(cat "$RCF")" = 0 ] || return 1; echo "{\"created\":true,\"row\":{\"id\":1}}"; }'
export STUBS

# hpr <jobs_req rc> <fn args...> — one request.sh call from the scratch copy.
# stdout -> $T/out, stderr -> $T/err, rc -> $T/vrc, call log reset first.
hpr() {
  echo "$1" > "$RCF"; shift; : > "$CALLS"
  bash -c '
    . "$H/bin/lib/jobs/hub-probe.sh" || exit 99
    . "$H/bin/lib/hub-probes/request.sh" || exit 98
    eval "$STUBS"
    "$@"' _ "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/vrc"
}
out() { cat "$T/out"; }
vrc() { cat "$T/vrc"; }
ncalls() { grep -c . "$CALLS"; }
body() { sed -n "${1}s/^[A-Z]* [^ ]* //p" "$CALLS"; }

SHA=0123456789abcdef0123456789abcdef01234567
F="$T/in.md"

# --- R1 ---------------------------------------------------------------------
printf 'Findings: the status write needs the App.\nHUB_PROBE: app-status-write example-org/cromford %s\nTIER: 2\n' "$SHA" > "$F"
hpr 0 hp_parse_request_lines "$F"
[ "$(vrc)" = 0 ] && [ "$(out)" = "$(printf 'app-status-write\texample-org/cromford %s' "$SHA")" ] && ok || bad "R1 parse rc=$(vrc) out=$(out)"
hpr 0 hp_file_requests cromford BH-9 "$F" build:review
[ "$(vrc)" = 0 ] && [ "$(ncalls)" = 1 ] && ok || bad "R1 file rc=$(vrc) calls=$(ncalls)"
[ "$(cut -d' ' -f1-2 "$CALLS")" = "POST /api/hub-probe" ] && ok || bad "R1 path: $(cat "$CALLS")"
[ "$(body 1 | jq -c '[.project,.ticket_key,.probe,.args,.requested_by]')" = "[\"cromford\",\"BH-9\",\"app-status-write\",[\"example-org/cromford\",\"$SHA\"],\"build:review\"]" ] \
  && ok || bad "R1 body: $(body 1)"
grep -q 'hub-probe: filed app-status-write example-org/cromford .* (created=true)' "$T/out" && ok || bad "R1 log: $(out)"

# --- R2 dedup + no-arg probe --------------------------------------------------
printf 'HUB_PROBE: app-status-write example-org/cromford %s\nHUB_PROBE: app-installation-repos\nHUB_PROBE: app-status-write example-org/cromford %s\n' "$SHA" "$SHA" > "$F"
hpr 0 hp_file_requests cromford BH-9 "$F" build:review
[ "$(vrc)" = 0 ] && [ "$(ncalls)" = 2 ] && ok || bad "R2 rc=$(vrc) calls=$(ncalls): $(cat "$CALLS")"
[ "$(body 2 | jq -c '[.probe,.args]')" = '["app-installation-repos",[]]' ] && ok || bad "R2 second body: $(body 2)"

# --- R3 outage -----------------------------------------------------------------
printf 'HUB_PROBE: app-permissions example-org-harness\n' > "$F"
hpr 1 hp_file_requests cromford BH-9 "$F" build:review
[ "$(vrc)" = 1 ] && [ "$(ncalls)" = 1 ] && grep -q 'NOT filed app-permissions example-org-harness' "$T/out" && ok \
  || bad "R3 rc=$(vrc) calls=$(ncalls) out=$(out)"

# --- N1-N15 adversarial: zero POSTs, empty parse ------------------------------
n=0
while IFS= read -r adv; do
  n=$((n+1))
  printf '%b\n' "$adv" > "$F"
  hpr 0 hp_parse_request_lines "$F"
  [ "$(vrc)" = 0 ] && [ -z "$(out)" ] && ok || bad "N$n parse emitted: rc=$(vrc) out=$(out) for: $adv"
  hpr 0 hp_file_requests cromford BH-9 "$F" build:review
  [ "$(ncalls)" = 0 ] && ok || bad "N$n filed: $(cat "$CALLS") for: $adv"
done <<ADV
HUB_PROBE: app-status-write example-org/cromford \$(id)
HUB_PROBE: app-status-write a/b 0123
HUB_PROBE: d1-count jobs 1=1;DROP TABLE jobs
HUB_PROBE: d1-count settings all
HUB_PROBE: run-anything x
we should HUB_PROBE: app-permissions later
hub_probe: app-permissions x
HUB_PROBE: app-permissions lead-verdict
<!-- lead-verdict --> HUB_PROBE: app-installation-repos
\`\`\`\nHUB_PROBE: app-installation-repos\n\`\`\`
  HUB_PROBE: app-installation-repos
HUB_PROBE: d1-count jobs\tall
HUB_PROBE: app-status-write ../x $SHA
HUB_PROBE:  app-permissions x
HUB_PROBE: app-installation-repos\x20
ADV
[ "$n" = 15 ] && ok || bad "N expected 15 adversarial lines, read $n"

# --- N16 the control-char skip on its own: hp_validate is neutralized to accept
# everything, so only request.sh's own filter stands between these and a POST.
printf 'HUB_PROBE: app-permissions a\tb\nHUB_PROBE: app-permissions a\001b\n' > "$F"
echo 0 > "$RCF"; : > "$CALLS"
bash -c '. "$H/bin/lib/jobs/hub-probe.sh" && . "$H/bin/lib/hub-probes/request.sh" || exit 98
  eval "$STUBS"; hp_validate() { return 0; }
  hp_parse_request_lines "$1"; hp_file_requests cromford BH-9 "$1" build:review' _ "$F" > "$T/out" 2>/dev/null
[ -z "$(out)" ] && [ "$(ncalls)" = 0 ] && ok || bad "N16 control characters got through: $(out) $(cat "$CALLS")"

# --- L1 ----------------------------------------------------------------------
printf 'HUB_PROBE: run-anything x\nplain prose\n' > "$F"
hpr 0 hp_parse_request_lines "$F"
grep -q '^hub-probe: dropped invalid request line: HUB_PROBE: run-anything x$' "$T/err" && [ "$(grep -c . "$T/err")" = 1 ] \
  && ok || bad "L1 stderr: $(cat "$T/err")"

# --- U1 ----------------------------------------------------------------------
hpr 0 hp_parse_request_lines "$T/does-not-exist"
[ "$(vrc)" = 2 ] && [ -z "$(out)" ] && ok || bad "U1 rc=$(vrc)"
hpr 0 hp_file_requests cromford BH-9 "$T/does-not-exist" build:review
[ "$(ncalls)" = 0 ] && ok || bad "U1 filed: $(cat "$CALLS")"

# --- P1-P4 production entry: the REAL RESULT() and seam, read through $RB_ALL --
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
SEAM="$T/seam.sh"
{ sed -n '/^# >>> result pr url ratchet$/,/^# <<< result pr url ratchet$/p' "$RB_ALL"
  sed -n '/^# >>> hub-probe request seam$/,/^# <<< hub-probe request seam$/p' "$RB_ALL"; } > "$SEAM"
grep -q '^RESULT()' "$SEAM" && grep -q '^# >>> hub-probe request seam$' "$SEAM" && ok || bad "P0 seam block not found in the pipeline text"
export SEAM
# prun <jobs_req rc> <harness root> <result line> — RESULT through the seam.
prun() {
  echo "$1" > "$RCF"; : > "$CALLS"; rm -f "$T/b/RESULT" "$T/b/pipeline.log"
  HARNESS="$2" BUILD="$T/b" PROJECT=cromford KEY=BH-9 bash -c '
    . "$H/bin/lib/jobs/hub-probe.sh" || exit 99
    eval "$STUBS"
    . "$SEAM" || exit 98
    RESULT "$1"' _ "$3" > "$T/out" 2> "$T/err"
  echo $? > "$T/vrc"
}
LINE="REVIEW_BLOCKED $T/b/review.md"
printf '## Findings\n- the status write was never proven (D1)\n\nHUB_PROBE: app-status-write example-org/cromford %s\n\nTIER: 2\nVERDICT: BLOCK\n' "$SHA" > "$T/b/review.md"
prun 0 "$H" "$LINE"
[ "$(vrc)" = 0 ] && [ "$(ncalls)" = 1 ] && ok || bad "P1 rc=$(vrc) calls=$(ncalls) err=$(cat "$T/err")"
[ "$(body 1 | jq -r .requested_by)" = build:review ] && ok || bad "P1 body: $(body 1)"
grep -q 'hub-probe: filed app-status-write' "$T/b/pipeline.log" 2>/dev/null && ok || bad "P1 pipeline.log: $(cat "$T/b/pipeline.log" 2>&1)"
[ "$(out)" = "$LINE" ] && [ "$(cat "$T/b/RESULT")" = "$LINE" ] && [ ! -s "$T/err" ] && ok || bad "P1 RESULT changed: out=$(out) file=$(cat "$T/b/RESULT")"

prun 1 "$H" "$LINE"
[ "$(vrc)" = 0 ] && [ "$(out)" = "$LINE" ] && [ "$(cat "$T/b/RESULT")" = "$LINE" ] && [ "$(ncalls)" = 1 ] \
  && grep -q 'NOT filed' "$T/b/pipeline.log" 2>/dev/null && ok || bad "P2 rc=$(vrc) out=$(out) log=$(cat "$T/b/pipeline.log" 2>&1)"

H2="$T/h2"; mkdir -p "$H2/bin/lib/hub-probes"; cp "$DIR/bin/lib/hub-probes/common.sh" "$H2/bin/lib/hub-probes/"
prun 0 "$H2" "$LINE"
[ "$(vrc)" = 0 ] && [ "$(out)" = "$LINE" ] && [ "$(cat "$T/b/RESULT")" = "$LINE" ] && [ "$(ncalls)" = 0 ] && [ ! -s "$T/err" ] \
  && ok || bad "P3 rc=$(vrc) out=$(out) calls=$(ncalls) err=$(cat "$T/err")"

rm -f "$T/b/review.md"
printf 'Done. The status check needs the App token.\nHUB_PROBE: d1-count jobs last-24h\n' > "$T/b/execute-run.txt"
prun 0 "$H" "PR_CREATED https://github.com/example-org/cromford/pull/1"
[ "$(vrc)" = 0 ] && [ "$(ncalls)" = 1 ] && [ "$(body 1 | jq -c '[.requested_by,.probe,.args]')" = '["build:execute-run","d1-count",["jobs","last-24h"]]' ] \
  && ok || bad "P4 rc=$(vrc) calls=$(cat "$CALLS")"

# --- G1-G2 the prompts ----------------------------------------------------------
# TEST-CHANGE (BH-7970): the general review lens text moved from bin/lib/rb/review.sh to prompts/stages/review.md.
for p in "$DIR/prompts/build-discipline.md" "$DIR/prompts/stages/review.md"; do
  [ "$(grep -c 'HUB_PROBE:' "$p")" -ge 1 ] && ok || bad "G1 no HUB_PROBE: in $p"
  for w in NEEDS_HUMAN: app-status-write app-permissions app-installation-repos d1-count; do
    grep -q -- "$w" "$p" && ok || bad "G2 $w missing from $p"
  done
done

echo "hub-probe-request.bh-3434: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
