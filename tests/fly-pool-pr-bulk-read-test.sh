#!/bin/bash
# tests/fly-pool-pr-bulk-read-test.sh — one bulk open-PR read per tick fills the
# per-key PR cache, so a 156-row queue does not make 156 PR reads (hotfix, 2026-10-19:
# 10-16 s per read under hub load walked project-6-os for about 40 minutes).
#
#   A  156 rows, 60 open PRs (1 page): 1 bulk read, 0 per-key reads, one log line
#   A2 156 rows, 120 open PRs (2 pages): a listed key is cached, an absent key
#      reads its own PR (a PR that closes between pages hides the boundary PR)
#   B  a page read that fails: no cache fill, rows read their own PR (fail-safe)
#   C  a branch absent from a complete one-page listing is cached "no PR" and spawns; a PR
#      on a listed branch parks its row; a fork PR on the same branch name is no PR
#   D  POOL_PR_BULK=0: no bulk read, per-key reads as before, logged "off"
#   F  the listing budget spent before the last page: cache left empty, per-key reads run
#   G  a hotfix row newer than 4 plain rows is decided first (cap 3: it still spawns)
#   E  the page cap reached on a full page: cache left empty, per-key reads run
# determinism: ok-file the stub gh answers at once; the one sleep (F) is the stub's deliberate slow page, the thing under test is the budget cut.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install of bin/jobs-client.sh failed"; exit 1; }
scratch_install_closure bin/lib/flags.sh "$H" >/dev/null || { echo "closure install of bin/lib/flags.sh failed"; exit 1; }
scratch_install_closure bin/lib/hold.sh "$H" >/dev/null || { echo "closure install of bin/lib/hold.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"

cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

write_fly_stub() {
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}

# The stub gh. The repo probe answers 200 and the hold reads say "open, ai-build".
#   bulk read  pulls?state=open&per_page=100&page=N  -> appended to $T/bulk-reads
#     BULKMODE=ok       page 1 = $T/special.json plus fillers to 100, page 2 = 20 fillers
#     BULKMODE=one      page 1 = $T/special.json plus fillers to 60 (one short page)
#     BULKMODE=fail2    as ok, but page 2 answers 500
#     BULKMODE=slow1    as ok, but page 1 takes 2 s (the listing budget test)
#     BULKMODE=endless  every page is 100 fillers (the page cap is reached)
#   per-key read  pulls?state=open&head=  -> appended to $T/pr-reads, answers 200 []
# The stub body lives in its own file so no escaping layer hides what it does.
cat > "$T/gh-body.sh" <<'GH'
if [[ "$*" == *"pulls?state=open&per_page=100"* ]]; then
  echo "$*" >> "$T/bulk-reads"
  pg=1; re="[&]page=([0-9]+)"; [[ "$*" =~ $re ]] && pg=${BASH_REMATCH[1]}
  if [ "${BULKMODE:-ok}" = fail2 ] && [ "$pg" = 2 ]; then
    printf 'HTTP/1.1 500 Server Error\n\n{}\n'; exit 0
  fi
  [ "${BULKMODE:-ok}" = slow1 ] && [ "$pg" = 1 ] && /bin/sleep 2
  n=20; { [ "$pg" = 1 ] || [ "${BULKMODE:-ok}" = endless ]; } && n=100
  [ "${BULKMODE:-ok}" = one ] && n=60
  sp='[]'; [ "$pg" = 1 ] && [ -f "$T/special.json" ] && sp=$(cat "$T/special.json")
  printf 'HTTP/1.1 200 OK\n\n'
  jq -nc --argjson sp "$sp" --argjson n "$n" --argjson pg "$pg" \
    '($sp + [range(0; $n - ($sp|length)) | {number: ($pg*1000 + .), html_url: "u", head: {ref: ("feature/f\($pg)-\(.)"), repo: {owner: {login: "example-org"}}}}])[:$n]'
  exit 0
fi
if [[ "$*" == *"pulls?state=open"*"head="* ]]; then
  echo "$*" >> "$T/pr-reads"
  printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0
fi
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"t","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat "$T/gh-body.sh"; } > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H"/flags/alerted-pool-pr-* \
           "$T/pr-reads" "$T/bulk-reads" "$T/special.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
queue_n() { # queue_n <first> <last> — rows BH-<n>, ticket id n
  local n
  for n in $(seq "$1" "$2"); do
    jq -nc --arg k "BH-$n" --arg t "$n" \
      '{ticket_id:$t,key:$k,attempt:0,deferrals:0,deaths:0,enqueued_at:"2026-10-19T00:00:00Z"}' \
      > "$H/state/build-queue/project-5/BH-$n.json"
  done
}
count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
spawned() { count '\] spawned .* for BH-' "$H/logs/fly-pool.log"; }
pr_reads() { count . "$T/pr-reads"; }
bulk_reads() { count . "$T/bulk-reads"; }

# ── A: 156 rows, 60 open PRs on 1 page ──────────────────────────────────────
reset_state; write_fly_stub; queue_n 3001 3156
run_pool BULKMODE=one
[ "$(bulk_reads)" = 1 ] && ok || bad "A: expected 1 bulk page read, got $(bulk_reads)"
[ "$(pr_reads)" = 0 ] && ok || bad "A: expected 0 per-key PR reads, got $(pr_reads)"
grep -q 'PR bulk read: 60 open PRs in 1 pages, cache filled for 156 keys' "$H/logs/fly-pool.log" && ok || bad "A: the log line is missing: $(grep 'PR bulk' "$H/logs/fly-pool.log")"
[ "$(spawned)" = 3 ] && ok || bad "A: new rows must still spawn up to the cap of 3, got $(spawned)"

# ── A2: 2 pages: "no PR" is never taken from a multi-page listing ───────────
reset_state; queue_n 3001 3003
printf '%s' '[{"number":77,"html_url":"https://github.com/example-org/project-5/pull/77","head":{"ref":"ticket/bh-3001","repo":{"owner":{"login":"example-org"}}}}]' > "$T/special.json"
run_pool BULKMODE=ok
[ "$(bulk_reads)" = 2 ] && ok || bad "A2: expected 2 bulk page reads, got $(bulk_reads)"
grep -q 'head=example-org:ticket/bh-3001' "$T/pr-reads" 2>/dev/null && bad "A2: BH-3001 is listed, it must answer from the cache" || ok
grep -q 'head=example-org:ticket/bh-3002' "$T/pr-reads" 2>/dev/null && ok || bad "A2: BH-3002 is absent from a 2-page listing and must read its own PR: $(cat "$T/pr-reads" 2>/dev/null)"
grep -q 'skipping BH-3001: open PR exists' "$H/logs/fly-pool.log" && ok || bad "A2: BH-3001 has an open PR and must park"

# ── B: page 2 fails: nothing is cached as "no PR" ────────────────────────────
reset_state; queue_n 3001 3006
run_pool BULKMODE=fail2
[ "$(bulk_reads)" = 2 ] && ok || bad "B: expected 2 bulk page reads, got $(bulk_reads)"
[ "$(pr_reads)" -ge 1 ] && ok || bad "B: a failed page must fall back to per-key reads, got $(pr_reads)"
grep -q 'PR bulk read: off (page 2 answered 500)' "$H/logs/fly-pool.log" && ok || bad "B: the off line must name the page and the answer: $(grep 'PR bulk' "$H/logs/fly-pool.log")"

# ── C: absent branch = no PR; listed branch = open PR; fork PR = no PR ───────
reset_state; queue_n 3001 3003
printf '%s' '[{"number":77,"html_url":"https://github.com/example-org/project-5/pull/77","head":{"ref":"ticket/bh-3001","repo":{"owner":{"login":"example-org"}}}},{"number":78,"html_url":"u","head":{"ref":"ticket/bh-3002","repo":{"owner":{"login":"someone"}}}}]' > "$T/special.json"
run_pool BULKMODE=one
[ "$(pr_reads)" = 0 ] && ok || bad "C: expected 0 per-key PR reads, got $(pr_reads)"
grep -q 'skipping BH-3001: open PR exists' "$H/logs/fly-pool.log" && ok || bad "C: BH-3001 has an open PR and must park"
grep -q 'skipping BH-3002: open PR exists' "$H/logs/fly-pool.log" && bad "C: a fork PR is not an open PR for BH-3002" || ok
[ "$(spawned)" = 2 ] && ok || bad "C: BH-3002 and BH-3003 (absent from a complete listing) must spawn, got $(spawned)"
grep -q 'cache filled for 3 keys' "$H/logs/fly-pool.log" && ok || bad "C: the cache must be filled for all 3 keys"

# ── D: POOL_PR_BULK=0 restores per-key reads ─────────────────────────────────
reset_state; queue_n 3001 3006
run_pool BULKMODE=ok POOL_PR_BULK=0
[ "$(bulk_reads)" = 0 ] && ok || bad "D: no bulk read with POOL_PR_BULK=0, got $(bulk_reads)"
[ "$(pr_reads)" -ge 1 ] && ok || bad "D: per-key reads must run, got $(pr_reads)"
grep -q 'PR bulk read: off (POOL_PR_BULK=0)' "$H/logs/fly-pool.log" && ok || bad "D: the off line is missing: $(grep 'PR bulk' "$H/logs/fly-pool.log")"

# ── E: the page cap reached on a full page: cache stays empty ────────────────
reset_state; queue_n 3001 3006
run_pool BULKMODE=endless
[ "$(bulk_reads)" = 10 ] && ok || bad "E: expected the 10 page cap, got $(bulk_reads)"
[ "$(pr_reads)" -ge 1 ] && ok || bad "E: a capped listing is not complete: per-key reads must run, got $(pr_reads)"
grep -q 'PR bulk read: off (page cap 10 reached' "$H/logs/fly-pool.log" && ok || bad "E: the cap line is missing: $(grep 'PR bulk' "$H/logs/fly-pool.log")"

# ── F: the listing budget is spent after a slow full page ────────────────────
reset_state; queue_n 3001 3006
run_pool BULKMODE=slow1 POOL_PR_BULK_BUDGET_S=1
[ "$(bulk_reads)" = 1 ] && ok || bad "F: expected 1 bulk page read before the budget cut, got $(bulk_reads)"
[ "$(pr_reads)" -ge 1 ] && ok || bad "F: a cut listing is not complete: per-key reads must run, got $(pr_reads)"
grep -q 'PR bulk read: off (bulk budget 1s spent after page 1)' "$H/logs/fly-pool.log" && ok || bad "F: the budget line is missing: $(grep 'PR bulk' "$H/logs/fly-pool.log")"

# ── G: a hotfix row, newest in the queue, is decided first ───────────────────
reset_state; queue_n 3001 3004
jq -nc '{ticket_id:"3999",key:"BH-3999",attempt:0,deferrals:0,deaths:0,hotfix:true,enqueued_at:"2026-10-19T00:00:01Z"}' > "$H/state/build-queue/project-5/BH-3999.json"
run_pool BULKMODE=ok
grep -q '\] spawned .* for BH-3999' "$H/logs/fly-pool.log" && ok || bad "G: the hotfix row must take the one slot: $(grep spawned "$H/logs/fly-pool.log")"
[ "$(spawned)" = 3 ] && ok || bad "G: the pool cap of 3 holds, got $(spawned)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
