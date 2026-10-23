#!/bin/bash
# tests/mc-land-rows.bh-2311-test.sh — BH-2357 (BH-2311.1): the land watermark
# (BH-870) lives in `ledgers kind=mc_land key=<project>`, and
# state/merge-conductor/land/<project> is its cache.
#
# WHAT IT PINS, each off a REAL conductor tick (bin/merge-conductor.sh, the fake
# git and gh of tests/land-rebase.bh-870-test.sh), reading what the run DID:
#   wiped    the land file is gone and the ledger holds the sha main is at: no
#            baseline, no landing, no rebase job. A box that lost its state does
#            not re-fire or re-baseline.
#   norow    the ledger has no row yet (rc 2): the file decides.
#   outage   the ledger GET fails at the transport: the file decides, both ways
#            (the file at main is no fire, the file at an older sha is a landing).
#   record   a handled landing PUTs the ledger (kind mc_land, status = main)
#            BEFORE the file is rewritten, and both end at main.
#   flag     pr-state-rows down: zero mc_land ledger requests, the file decides.
#
# HOW. bin/jobs-client.sh is a two-module stand-in: the REAL req.sh and jobs.sh
# (job_ledger_get / job_ledger_put / pr_rows_on), over a curl shim that serves
# /api/ledger from a TSV and answers every other route with a 404.
#
# Run from anywhere: tests/mc-land-rows.bh-2311-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

MAIN0=0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a
MAIN1=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
MAIN2=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
H21=2121212121212121212121212121212121212121
NEW21=9999999999999999999999999999999999999999
SLUG=example-org/demo-os

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/lib/hold-push.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/deploy-request.sh" "$T/h/bin/"
cp "$DIR/bin/lib/jobs/req.sh" "$DIR/bin/lib/jobs/jobs.sh" "$T/h/bin/lib/jobs/"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
cat > "$T/h/bin/jobs-client.sh" <<'JC'
JOBS_HARNESS="${HARNESS:-/root/harness}"
. "$JOBS_HARNESS/bin/lib/jobs/req.sh" || return 1
. "$JOBS_HARNESS/bin/lib/jobs/jobs.sh" || return 1
job_verdict_rebind() { return 0; }
JC
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/lane-alerts.txt" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-verify.sh"; chmod +x "$T/h/bin/deploy-verify.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/prod-url.sh"; chmod +x "$T/h/bin/prod-url.sh"
touch "$T/h/flags/merge-conductor-actions"

ST="$T/h/state/merge-conductor"
LANDF="$ST/land/demo-os"
LOG="$T/h/logs/merge-conductor.log"
REQ="$T/req.log"
LEDGER="$T/ledger.tsv"

# --- the fake git (the land-rebase.bh-870 one, trimmed to what a tick reads) --
echo "$MAIN1" > "$T/ctl-main-sha"
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
printf '%s\n' "\$A" >> "$T/git-argv.txt"
case "\$A" in
  *--version*) echo "git version 2.45.0"; exit 0 ;;
  *ls-remote*"refs/heads/"*) printf '%s\trefs/heads/main\n' "\$(cat "$T/ctl-main-sha")"; exit 0 ;;
  *ls-remote*) echo "0000000000000000000000000000000000000000	HEAD"; exit 0 ;;
  *merge-tree*) exit 0 ;;
  *"merge-base --is-ancestor"*) exit 1 ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *" merge "*)  exit 0 ;;
  *rev-parse*)  if [ -f "$T/rev2" ]; then printf '%s\n' "$NEW21"; else touch "$T/rev2"; printf '%s\n' "$H21"; fi; exit 0 ;;
  *patch-id*)   md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*)   printf 'a stable patch\n'; exit 0 ;;
  *push*)       exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"issue close"*|*"pr review"*) echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/prlist.json" ;;
  *"pr list"*) echo "" ;;
  *"actions/runs"*) restpr --runs 'completed|success' ;;
  *"pr view"*"--json mergeCommit"*) printf '%s\n' "$NEW21" ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# --- the fake jobs worker: /api/ledger from $LEDGER, everything else 404 -----
# ctl-ledger-mode "down" fails /api/ledger at the transport (exit 7). A ledger PUT
# notes what the land FILE held at that moment, which is how "the ledger is
# written first" is read.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) METHOD="\$2"; shift 2;;
    --data-binary) BODY="\$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -*) shift;;
    *) URL="\$1"; shift;;
  esac
done
printf '%s %s %s\n' "\$METHOD" "\$URL" "\$BODY" >> "$REQ"
case "\$URL" in */api/ledger*) : ;; *) printf '{"error":"not found"}\n404\n'; exit 0 ;; esac
[ "\$(cat "$T/ctl-ledger-mode" 2>/dev/null)" = down ] && exit 7
touch "$LEDGER"
if [ "\$METHOD" = PUT ]; then
  IFS=\$'\t' read -r k v s < <(printf '%s' "\$BODY" | jq -r '[.kind, .key, .status] | @tsv')
  [ "\$k" = mc_land ] && echo "PUT \$k \$v \$s file=\$(cat "$LANDF" 2>/dev/null)" >> "$T/ledger-put.log"
  grep -v "^\$k	\$v	" "$LEDGER" > "$LEDGER.tmp"; printf '%s\t%s\t%s\n' "\$k" "\$v" "\$s" >> "$LEDGER.tmp"; mv "$LEDGER.tmp" "$LEDGER"
  printf '{"ok":true}\n200\n'; exit 0
fi
q="\${URL#*\?}"; k=\$(printf '%s' "\$q" | tr '&' '\n' | sed -n 's/^kind=//p'); v=\$(printf '%s' "\$q" | tr '&' '\n' | sed -n 's/^key=//p')
s=\$(awk -F'\t' -v k="\$k" -v v="\$v" '\$1==k && \$2==v {print \$3}' "$LEDGER")
[ -n "\$s" ] || { printf '{"error":"not found"}\n404\n'; exit 0; }
jq -nc --arg s "\$s" '{ledger:{status:\$s}}'; printf '200\n'
EOF
chmod +x "$T/fakebin/curl"

PR() {
  jq -nc --argjson n "$1" --arg u "https://github.com/$SLUG/pull/$1" --arg h "$2" \
     --arg b "ticket/pb-$1" --arg ms "$3" --arg mg "$4" --argjson l "$5" --arg base "$6" \
     '{number:$n,url:$u,headRefOid:$h,headRefName:$b,isDraft:false,mergeStateStatus:$ms,
       mergeable:$mg,state:"OPEN",labels:$l,baseRefName:$base}'
}
REC() {
  local d="$T/h/builds/demo-os-TK-$1-20260912002$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  printf '%s' "$d"
}
R21=$(REC 21 "$H21")

export PATH="$T/fakebin:$PATH"
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_REPOS="$T/repos" \
            MC_RR_PATH="$T/fakebin:$PATH" HARNESS_SECRET=x JOBS_URL=http://jobs.test \
            JOBS_BOX=testbox JOBS_RETRIES=0 JOBS_ALERT=0 "$@" bash "$T/h/bin/merge-conductor.sh" \
            >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
jobs_n()  { ls "$ST"/rebase/*.json 2>/dev/null | wc -l | tr -d ' '; }
logn()    { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
# Only the watermark's own traffic: the conductor also keeps its pr_state ledger.
nledger() { grep " http://jobs.test/api/ledger" "$REQ" 2>/dev/null | grep -c 'mc_land' || true; }
wait_jobs() {
  local j i
  for j in "$ST"/rebase/*.json; do
    [ -f "$j" ] || continue
    for i in $(seq 1 200); do [ "$(jq -r .status "$j" 2>/dev/null)" = done ] && break; sleep 0.2; done
  done
}
# RESET <file-sha|-> <ledger-sha|-> — the land file and the ledger row as given
# ("-" = absent), main at MAIN1, one eligible PR 21, flag up, nothing spawned.
RESET() {
  wait_jobs
  scratch_rm "$ST/land" || exit 1; scratch_rm "$ST/rebase" || exit 1; mkdir -p "$ST/rebase" "$ST/land"
  : > "$ST/pr-state.tsv"; : > "$ST/attempts.txt"; : > "$LOG"; : > "$REQ"; : > "$LEDGER"
  : > "$T/ledger-put.log"; : > "$T/git-argv.txt"; rm -f "$T/rev2" "$T/ctl-ledger-mode"
  echo "$H21" > "$R21/reviewed-sha"
  echo "$MAIN1" > "$T/ctl-main-sha"
  : > "$T/h/flags/pr-state-rows"
  printf '[%s]\n' "$(PR 21 "$H21" BEHIND MERGEABLE '[]' main)" > "$T/prlist.json"
  [ "$1" = - ] || echo "$1" > "$LANDF"
  [ "$2" = - ] || printf 'mc_land\tdemo-os\t%s\n' "$2" > "$LEDGER"
}
nofire() { # nofire <case>
  [ "$(logn "LAND baseline")" = 0 ] && ok || bad "$1: no baseline wanted: $(grep LAND "$LOG")"
  [ "$(logn "LAND main moved")" = 0 ] && ok || bad "$1: no landing wanted: $(grep LAND "$LOG")"
  [ "$(jobs_n)" = 0 ] && ok || bad "$1: want 0 rebase jobs, got $(jobs_n)"
}

echo "== wiped: the land file is gone, the ledger holds main =="
RESET - "$MAIN1"
scratch_rm "$ST/land" || exit 1
tick
nofire wiped
grep -q "GET http://jobs.test/api/ledger?kind=mc_land&key=demo-os" "$REQ" && ok || bad "wiped: the ledger must be read: $(cat "$REQ")"

echo "== norow: no ledger row yet, the file decides =="
RESET "$MAIN1" -
tick
nofire norow

echo "== outage: the file decides, both ways =="
RESET "$MAIN1" "$MAIN0"
echo down > "$T/ctl-ledger-mode"
tick
nofire outage-same
RESET "$MAIN0" -
echo down > "$T/ctl-ledger-mode"
tick
grep -q "demo-os LAND main moved ${MAIN0:0:8} -> ${MAIN1:0:8}" "$LOG" && ok || bad "outage-old: the file's older sha must be a landing: $(grep LAND "$LOG")"
[ "$(cat "$LANDF")" = "$MAIN1" ] && ok || bad "outage-old: the handled sha must still reach the file (got '$(cat "$LANDF")')"

echo "== record: a handled landing writes the ledger, then the file =="
RESET "$MAIN1" "$MAIN1"
echo "$MAIN2" > "$T/ctl-main-sha"
tick
grep -q "demo-os LAND main moved ${MAIN1:0:8} -> ${MAIN2:0:8}" "$LOG" && ok || bad "record: want a landing: $(grep LAND "$LOG")"
grep -q "demo-os LAND main ${MAIN2:0:8} handled:" "$LOG" && ok || bad "record: want it handled: $(grep LAND "$LOG")"
[ "$(cat "$T/ledger-put.log")" = "PUT mc_land demo-os $MAIN2 file=$MAIN1" ] && ok \
  || bad "record: want one ledger PUT of main, made while the file still held the old sha: [$(cat "$T/ledger-put.log")]"
grep -q '"kind":"mc_land","key":"demo-os","status":"'"$MAIN2"'"' "$REQ" && ok || bad "record: the PUT body: $(grep mc_land "$REQ")"
[ "$(cat "$LANDF")" = "$MAIN2" ] && ok || bad "record: the file must end at main (got '$(cat "$LANDF")')"
[ "$(awk -F'\t' '$1=="mc_land" {print $3}' "$LEDGER")" = "$MAIN2" ] && ok || bad "record: the ledger must end at main: $(cat "$LEDGER")"
# ...and a box that then loses the file does not fire the same landing again.
wait_jobs; scratch_rm "$ST/land" || exit 1; scratch_rm "$ST/rebase" || exit 1; mkdir -p "$ST/rebase"; : > "$LOG"
tick
nofire record-then-wiped

echo "== flag down: no ledger call, the file decides =="
RESET "$MAIN1" "$MAIN0"
rm -f "$T/h/flags/pr-state-rows"
tick
nofire flag-down
[ "$(nledger)" = 0 ] && ok || bad "flag-down: want 0 mc_land ledger requests: $(grep mc_land "$REQ")"
RESET - "$MAIN1"
rm -f "$T/h/flags/pr-state-rows"
tick
[ "$(logn "LAND baseline")" = 1 ] && ok || bad "flag-down: a missing file is still today's baseline: $(grep LAND "$LOG")"
[ "$(nledger)" = 0 ] && ok || bad "flag-down: the baseline record must not touch the mc_land ledger: $(grep mc_land "$REQ")"
wait_jobs

[ -s "$T/gh-writes.txt" ] && bad "a write verb ran: $(cat "$T/gh-writes.txt")" || ok
echo "mc-land-rows.bh-2311: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
