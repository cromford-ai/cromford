#!/bin/bash
# tests/account-lease-cas-test.sh — a claude account's lease cap is ONE fact for
# the whole fleet, decided by a compare-and-swap, not by each box counting its
# own files (BH-1043, audit §2.4).
#
# THE BUG. bin/lib/pool-account.sh counts live leases as FILES under
# state/quota/leases/<account>/<machine-id>. That directory is per BOX. So the
# hub at cap 4 and a second box at cap 4 both count 0 free slots as 4, and both
# lease the same account — eight heavy sessions on an account
# fly/account-capacity.conf rates at ~4. Nothing errors; the account just starts
# refusing, and the refusals look like the account's problem.
#
# THE SHAPE OF THE FIX. The cap is checked INSIDE one INSERT in the jobs worker
# (`account_leases`, cap in the WHERE of the select the insert draws from), so
# two boxes racing for the last slot cannot both be told they won. The file
# lease stays — it is the local record the release path and the rank still read —
# but it is no longer the arbiter.
#
# WHAT THIS DRIVES. The real bin/lib/pool-account.sh, on TWO scratch boxes with
# separate $HARNESS trees, against a fake curl whose account_leases table is one
# shared file. The fake enforces the cap the way the SQL does (count the rows
# that have not expired, excluding the claimant's own) — block G pins the
# worker's statement against that same rule so the fake cannot drift into
# proving something the worker does not do.
#
# Sections:
#   A  one account, cap 1: box 1 wins, box 2 is refused and ships the default
#   B  the count is SHARED: box 2 reads box 1's lease
#   C  refused on one account, the pool takes the next candidate
#   D  release frees the slot for the other box
#   E  an EXPIRED row blocks nobody (the TTL is the server's)
#   F  fail-open: an unreachable worker leases exactly as it does today
#   G  the worker's claim is a CAS, and the client maps 409 to "refused"
#
# Run from anywhere: tests/account-lease-cas-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The clock is read ONCE: every expiry below is derived from it, so no case can
# straddle a second boundary. # determinism: ok single anchor, every stamp derived
NOW=$(date -u +%s)
TOKPOOL="sk-ant-oat01-FIXTURE-POOL-do-not-ship"
TOKMASTER="sk-ant-oat01-FIXTURE-MASTER-token"

mkdir -p "$T/db" "$T/fakebin"
DB="$T/db/account_leases.tsv"   # account \t machine \t expires_epoch
: > "$DB"
REQ="$T/db/requests.log"
: > "$REQ"

# ── the shared table, as the worker implements it ────────────────────────────
# POST /api/account-leases/claim   {account, machine_id, cap, ttl_s}
#   200 {claimed:true,...}   the cap had room (or this machine already held a row)
#   409 {claimed:false,...}  the cap is full, counted over rows that have not
#                            expired and are not this machine's own
# POST /api/account-leases/release {machine_id, account?}
# GET  /api/account-leases?account=<a>
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2 ;;
    -H) shift 2 ;;
    -H*|-sS|-s) shift ;;
    -m|--connect-timeout|-w) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s %s\n' "$METHOD" "${URL#*workers.dev}" "$BODY" >> "$REQ"
[ "${CURL_DOWN:-0}" = 1 ] && exit 7
NOWS="${FAKE_NOW:-$(date -u +%s)}"
live() { awk -F'\t' -v a="$1" -v m="$2" -v n="$NOWS" '$1==a && $2!=m && $3+0>n' "$DB" | grep -c '' ; }
case "$URL" in
  */api/account-leases/claim)
    A=$(jq -r '.account // ""' <<<"$BODY"); M=$(jq -r '.machine_id // ""' <<<"$BODY")
    CAP=$(jq -r '.cap // 4' <<<"$BODY"); TTL=$(jq -r '.ttl_s // 10800' <<<"$BODY")
    [ -n "$A" ] && [ -n "$M" ] || { printf '{"error":"account and machine_id are required"}\n400'; exit 0; }
    N=$(live "$A" "$M")
    if [ "$CAP" -gt 0 ] && [ "$N" -ge "$CAP" ]; then
      printf '{"claimed":false,"reason":"cap","account":"%s","live":%s,"cap":%s}\n409' "$A" "$N" "$CAP"; exit 0
    fi
    awk -F'\t' -v a="$A" -v m="$M" '!($1==a && $2==m)' "$DB" > "$DB.new" 2>/dev/null || : > "$DB.new"
    printf '%s\t%s\t%s\n' "$A" "$M" "$(( NOWS + TTL ))" >> "$DB.new"
    mv "$DB.new" "$DB"
    printf '{"claimed":true,"account":"%s","machine_id":"%s","live":%s,"cap":%s}\n200' "$A" "$M" "$(( N + 1 ))" "$CAP"
    exit 0 ;;
  */api/account-leases/release)
    A=$(jq -r '.account // ""' <<<"$BODY"); M=$(jq -r '.machine_id // ""' <<<"$BODY")
    awk -F'\t' -v a="$A" -v m="$M" 'BEGIN{OFS="\t"} !($2==m && (a=="" || $1==a))' "$DB" > "$DB.new"
    mv "$DB.new" "$DB"
    printf '{"released":1}\n200'; exit 0 ;;
  */api/account-leases\?*account=*)
    A="${URL#*account=}"; A="${A%%&*}"
    printf '{"account":"%s","live":%s}\n200' "$A" "$(live "$A" '')"
    exit 0 ;;
  */api/account-leases*)
    # No account named: the whole fleet's counts in one call, which is what a
    # pick uses so seven candidates cost one round trip and not seven.
    printf '{"counts":%s}\n200' \
      "$(awk -F'\t' -v n="$NOWS" '$3+0>n {c[$1]++} END{printf "{"; s=""; for (a in c) {printf "%s\"%s\":%d", s, a, c[a]; s=","} printf "}"}' "$DB")"
    exit 0 ;;
esac
printf '{"error":"unknown endpoint"}\n404'
CURL
chmod +x "$T/fakebin/curl"

# ── two boxes, one registry each, one shared table ───────────────────────────
mkbox() { # mkbox <dir> <box-name>
  local H="$1"
  mkdir -p "$H/bin/lib" "$H/env/accounts.d" "$H/env/tokens.d" "$H/state/quota" \
           "$H/logs" "$H/flags" "$H/fly" "$H/bundle"
  cp "$DIR/bin/account-pick.sh" "$DIR/bin/auth-fingerprint.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
  mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/pool-account.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
  printf 'claude 4\ncodex 4\n' > "$H/fly/account-capacity.conf"
  printf '%s\n' "$2" > "$H/state/box-name"
  for A in a b; do
    cat > "$H/env/accounts.d/$A.env" <<EOF
ACCOUNT_NAME=$A
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=$( [ "$A" = a ] && echo 10 || echo 20 )
CLAUDE_CONFIG_DIR=$H/.claude-$A
EOF
    chmod 600 "$H/env/accounts.d/$A.env"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s-%s\n' "$TOKPOOL" "$A" > "$H/env/tokens.d/$A-setup-token.env"
    chmod 600 "$H/env/tokens.d/$A-setup-token.env"
    jq -n --arg a "$A" --arg t "$(date -u -d "@$(( NOW - 60 ))" '+%Y-%m-%dT%H:%M:%SZ')" \
      '{account:$a,vendor:"claude",status:"unreadable",source:"none",polled_at:$t,
        five_hour:null,seven_day:null,per_model:{}}' > "$H/state/quota/$A.json"
  done
}
H1="$T/h1"; H2="$T/h2"
mkbox "$H1" box-one
mkbox "$H2" box-two

bundle() { # bundle <harness> — a fresh bundle carrying the project-6 token
  printf 'CONSOLE_URL=https://console.test\nCLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=gh-fixture\nRUNNER_EXECUTE=claude\n' \
    "$TOKMASTER" > "$1/bundle/global.env"
  chmod 600 "$1/bundle/global.env"
}

lease() { # lease <harness> <ticket-key> <machine-id> [extra env...]
  local H="$1" K="$2" M="$3"; shift 3
  bundle "$H"
  env PATH="$T/fakebin:$PATH" HARNESS="$H" HOME="$H" DB="$DB" REQ="$REQ" \
      ACCOUNTS_DIR="$H/env/accounts.d" HARNESS_SECRET=test-secret \
      JOBS_URL=https://harness-jobs.operator.workers.dev FAKE_NOW="$NOW" \
      ACCOUNT_POOL_MAX_LEASES=1 "$@" \
    bash -c '. "$1/bin/account-pick.sh"; . "$1/bin/jobs-client.sh"; . "$1/bin/lib/pool-account.sh"
             pool_account_lease proj "$2" "$1/bundle/global.env" "$3"' \
      _ "$H" "$K" "$M" 2>/dev/null
}
lname()   { sed -n 's/.*\bname=\([^ ]*\).*/\1/p' <<<"$1"; }
# Each section starts from an empty world: the shared table AND both boxes' own
# lease trees. A leftover file lease from the previous section would cap an
# account locally and hide the very thing the next case is measuring.
reset_leases() { : > "$DB"; scratch_rm "$H1/state/quota/leases"; scratch_rm "$H2/state/quota/leases"; }
lreason() { sed -n 's/.*\breason=\([^ ]*\).*/\1/p' <<<"$1"; }

# =============================================================================
# A. ONE ACCOUNT, CAP 1 — box 1 wins, box 2 is refused
# =============================================================================
rm -f "$H1/env/tokens.d/b-setup-token.env" "$H2/env/tokens.d/b-setup-token.env"
: > "$DB"
OUT1=$(lease "$H1" K-1043a m-one-1)
[ "$(lname "$OUT1")" = a ] && ok || bad "A: box 1 did not get the only account: $OUT1"

OUT2=$(lease "$H2" K-1043b m-two-1)
[ "$(lname "$OUT2")" = default ] \
  && ok || bad "A: box 2 leased an account box 1 already filled to its cap: $OUT2"
[ "$(lreason "$OUT2")" = all_leased ] \
  && ok || bad "A: the refusal must name the lease cap, not a guess: $OUT2"
# The loser must ship the bundle it arrived with — a refused account is never a
# refused launch.
grep -q "CLAUDE_CODE_OAUTH_TOKEN=$TOKMASTER" "$H2/bundle/global.env" \
  && ok || bad "A: the refused box did not ship the default project-6 token"

# =============================================================================
# B. THE COUNT IS SHARED — box 2 reads the row box 1 wrote
# =============================================================================
N=$(env PATH="$T/fakebin:$PATH" HARNESS="$H2" DB="$DB" REQ="$REQ" HARNESS_SECRET=test-secret \
      JOBS_URL=https://harness-jobs.operator.workers.dev FAKE_NOW="$NOW" \
      bash -c '. "$1/bin/jobs-client.sh"; account_lease_count a' _ "$H2" 2>/dev/null)
[ "$N" = 1 ] && ok || bad "B: box 2 counted '$N' live leases on a, not the 1 box 1 holds"
# ...and its own file tree says zero, which is exactly why the file could not be
# the arbiter.
[ "$(find "$H2/state/quota/leases" -type f 2>/dev/null | grep -c '')" = 0 ] \
  && ok || bad "B: the fixture is wrong — box 2 has local lease files for a"

# A pick ranks every account, so the counts arrive in ONE call, not one per
# candidate: at seven accounts and ten machines a tick the per-account shape
# would be seventy round trips every two minutes, each in front of a machine
# waiting to launch.
: > "$REQ"
lease "$H2" K-1043b2 m-two-1b >/dev/null
[ "$(grep -cE 'GET /api/account-leases *$' "$REQ")" = 1 ] \
  && ok || bad "B: expected exactly one batched counts call: $(grep '/api/account-leases' "$REQ")"
[ "$(grep -c 'GET /api/account-leases?account=' "$REQ")" = 0 ] \
  && ok || bad "B: the rank still asks per account: $(grep '/api/account-leases' "$REQ")"

# =============================================================================
# C. REFUSED ON ONE ACCOUNT, THE POOL TAKES THE NEXT CANDIDATE
# =============================================================================
reset_leases
for H in "$H1" "$H2"; do
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s-b\n' "$TOKPOOL" > "$H/env/tokens.d/b-setup-token.env"
  chmod 600 "$H/env/tokens.d/b-setup-token.env"
done
OUT1=$(lease "$H1" K-1043c m-one-2)
[ "$(lname "$OUT1")" = a ] && ok || bad "C: box 1 did not take the priority account: $OUT1"
OUT2=$(lease "$H2" K-1043d m-two-2)
[ "$(lname "$OUT2")" = b ] \
  && ok || bad "C: box 2 must fall to the next candidate, not to the default: $OUT2"
grep -q "CLAUDE_CODE_OAUTH_TOKEN=$TOKPOOL-b" "$H2/bundle/global.env" \
  && ok || bad "C: box 2's bundle does not carry account b's token"

# =============================================================================
# D. RELEASE FREES THE SLOT FOR THE OTHER BOX
# =============================================================================
reset_leases
rm -f "$H1/env/tokens.d/b-setup-token.env" "$H2/env/tokens.d/b-setup-token.env"
lease "$H1" K-1043e m-one-3 >/dev/null
env PATH="$T/fakebin:$PATH" HARNESS="$H1" DB="$DB" REQ="$REQ" HARNESS_SECRET=test-secret \
    JOBS_URL=https://harness-jobs.operator.workers.dev FAKE_NOW="$NOW" \
  bash -c '. "$1/bin/account-pick.sh"; . "$1/bin/jobs-client.sh"; . "$1/bin/lib/pool-account.sh"
           pool_account_release m-one-3' _ "$H1" >/dev/null 2>&1
[ "$(grep -c '' "$DB")" = 0 ] \
  && ok || bad "D: the release did not drop the shared row: $(cat "$DB")"
OUT2=$(lease "$H2" K-1043f m-two-3)
[ "$(lname "$OUT2")" = a ] && ok || bad "D: the freed slot was not offered to box 2: $OUT2"

# =============================================================================
# E. AN EXPIRED ROW BLOCKS NOBODY
# =============================================================================
reset_leases
printf 'a\tm-ghost\t%s\n' "$(( NOW - 1 ))" > "$DB"
OUT2=$(lease "$H2" K-1043g m-two-4)
[ "$(lname "$OUT2")" = a ] \
  && ok || bad "E: an expired lease still held the account: $OUT2"

# =============================================================================
# F. FAIL-OPEN — an unreachable worker leases exactly as it does today
# =============================================================================
# A coordination outage must never refuse a launch: the whole library's contract
# is that every failure ships a working bundle.
reset_leases
OUT1=$(lease "$H1" K-1043h m-one-5 CURL_DOWN=1)
[ "$(lname "$OUT1")" = a ] \
  && ok || bad "F: an unreachable worker refused a launch: $OUT1"
OUT2=$(lease "$H2" K-1043i m-two-5 CURL_DOWN=1)
[ "$(lname "$OUT2")" = a ] \
  && ok || bad "F: with the worker down both boxes must behave as they do today: $OUT2"

# =============================================================================
# G. THE WORKER'S CLAIM IS A CAS, AND 409 MEANS REFUSED
# =============================================================================
# The fake above enforces the cap in bash. What makes that a fair model is that
# the worker enforces it inside ONE statement — a read-then-write would let two
# boxes both win the last slot, which is the bug this whole file exists for.
# BH-1195 split the worker: the claim SQL is in src/lib/core.js and the routes
# sit under src/routes/. Read the whole tree, so this asks about the CODE and
# not about which file it is spelled in today.
# One read, into a variable: `set -o pipefail` is on above, and `grep -q` closing
# a pipe early would make a PASSING grep look like a failed pipeline.
WORKER_SRC=$(find "$DIR/worker/jobs/src" -name '*.js' | sort | while read -r f; do cat "$f"; done)
CLAIM=$(tr '\n' ' ' <<<"$WORKER_SRC" | grep -o 'INSERT INTO account_leases[^`]*' | head -1)
grep -q 'INSERT INTO account_leases' <<<"$CLAIM" \
  && ok || bad "G: the worker has no account_leases insert"
grep -q 'SELECT COUNT(\*) FROM account_leases' <<<"$CLAIM" \
  && ok || bad "G: the cap is not counted inside the claim statement: $CLAIM"
grep -q 'machine_id<>' <<<"$CLAIM" \
  && ok || bad "G: the count does not exclude the claimant's own row (a renew would refuse itself): $CLAIM"
grep -q 'expires_at>' <<<"$CLAIM" \
  && ok || bad "G: the count is not limited to live rows: $CLAIM"
grep -q 'ON CONFLICT(account, machine_id)' <<<"$CLAIM" \
  && ok || bad "G: a re-claim by the same machine is not an upsert: $CLAIM"
grep -q 'account_leases' "$DIR/worker/jobs/schema.sql" \
  && ok || bad "G: account_leases is not in schema.sql"
# TEST-CHANGE (BH-4987): CREATED_TABLES derives from worker/jobs/schema.d, so
# account_leases has no hand entry to grep. The derived entry is asked of the
# real parser over the real composed schema (importing core.js itself would need
# the git-ignored catalog/lanes.json); worker/jobs/test/created-tables.bh-4987
# T1 pins that the exported map carries every derived table.
LEASE_DERIVED=$(node --input-type=module -e "
  const { createdTablesFrom } = await import('$DIR/worker/jobs/src/lib/created-tables.js');
  const { jobsSchemaSql } = await import('$DIR/worker/jobs/test/lib/jobs-schema.js');
  const e = createdTablesFrom(jobsSchemaSql()).account_leases || [];
  console.log(/^CREATE TABLE IF NOT EXISTS account_leases\b/.test(e[0] || '') ? 'yes' : 'no');
" 2>&1)
if grep -q 'account_leases:' <<<"$WORKER_SRC"; then ok
elif grep -q 'createdTablesFrom(SCHEMA_SQL)' <<<"$WORKER_SRC" && [ "$LEASE_DERIVED" = yes ]; then ok
else bad "G: account_leases is not in CREATED_TABLES — it would ship dead until a hand-run schema apply ($LEASE_DERIVED)"; fi

# The client's rc contract, driven for real against the fake: 0 won, 1 refused,
# 2 unknown. A caller that cannot tell 1 from 2 would treat an outage as a full
# account and put the whole pool back on the project-6 token.
claim() { # claim <harness> <account> <machine> [extra env...]
  local H="$1" A="$2" M="$3"; shift 3
  env PATH="$T/fakebin:$PATH" HARNESS="$H" DB="$DB" REQ="$REQ" HARNESS_SECRET=test-secret \
      JOBS_URL=https://harness-jobs.operator.workers.dev FAKE_NOW="$NOW" "$@" \
    bash -c '. "$1/bin/jobs-client.sh"; account_lease_claim "$2" "$3" proj K-x 1 3600 >/dev/null 2>&1; echo $?' \
      _ "$H" "$A" "$M" 2>/dev/null
}
reset_leases
[ "$(claim "$H1" a m-cas-1)" = 0 ] && ok || bad "G: the first claim did not win"
[ "$(claim "$H2" a m-cas-2)" = 1 ] && ok || bad "G: the second claim at cap 1 was not refused with rc 1"
[ "$(claim "$H1" a m-cas-1)" = 0 ] && ok || bad "G: a machine could not renew its OWN lease"
[ "$(claim "$H2" a m-cas-3 CURL_DOWN=1)" = 2 ] \
  && ok || bad "G: an unreachable worker must be rc 2 (unknown), never rc 1 (refused)"

echo "account-lease-cas: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
