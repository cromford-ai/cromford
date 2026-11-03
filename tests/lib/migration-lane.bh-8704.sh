#!/bin/bash
# shellcheck shell=bash
# tests/lib/migration-lane.bh-8704.sh — the shared fixture of the BH-8704
# migration-lane suites, sourced by tests/migration-lane.bh-8704-test.sh and
# tests/migration-lane-apply.bh-8704-test.sh. One file was one suite until it
# ran past the 180 s life of tests/lib/project-lease.bh-6883.mjs (lead BLOCK
# lr-8720-27bf53f74f3e); each suite now starts its own worker. Not a test: it
# lives in tests/lib/ so the tests/*.sh sweep never runs it.
#
# Every case runs the REAL entry point bin/migration-lane.sh <project> in a
# scratch harness tree. Real: git (a local bare repo is `origin`, PR heads are
# refs/pull/<n>/head), the jobs worker (tests/lib/project-lease.bh-6883.mjs on
# node:sqlite: settings rows, the ledger, the project lease), the apply command
# (a script committed on the fixture's main). Fake: the mlx_* seams (GitHub, the
# verdict readers, the app status endpoint, the alert, sleep), defined in
# $T/seams.sh and loaded through BASH_ENV, each logging its calls to
# $C/calls. Each case has its own project, PR numbers and fixture dir, so no
# case reads another's data and the order does not matter.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
# The suite sources scratch.sh first (tests-scratch-only); load it here only when it did not.
declare -F scratch_rm >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/scratch.sh" || exit 1
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRV="$DIR/tests/lib/project-lease.bh-6883.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
for c in node jq curl git flock sha256sum; do
  command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c missing"; exit 0; }
done

# ── the scratch harness ────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/locks" "$H/repos" "$H/catalog"
for L in bin/migration-lane.sh bin/jobs-client.sh bin/fleet-conf.sh bin/lanes-build.sh bin/project-lane-run.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
[ -x "$H/bin/migration-lane.sh" ] || { echo "setup: bin/migration-lane.sh missing"; exit 1; }
cp -R "$DIR/catalog/lanes.d" "$H/catalog/lanes.d"
: > "$H/fleet.conf"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 LANE_GATE_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_START_SPREAD_S=0
export MC_REPOS="$H/repos" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$H/fleet.conf"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null' EXIT

# A gh that is never meant to run, and a curl that records every host.
FB="$T/fakebin"; mkdir -p "$FB"
printf '#!/bin/bash\necho "gh $*" >> "%s/gh.log"\nexit 1\n' "$T" > "$FB/gh"
REALCURL=$(command -v curl)
cat > "$FB/curl" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in http://*|https://*) echo "\$a" >> "$T/curl-hosts.log" ;; esac; done
exec "$REALCURL" "\$@"
EOF
chmod +x "$FB/gh" "$FB/curl"
export PATH="$FB:$PATH"
: > "$T/gh.log"; : > "$T/curl-hosts.log"

setting() { "$REALCURL" -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
ledger_put() { "$REALCURL" -sS -X PUT -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
  -d "$(jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "$4" '{kind:$k,key:$v,status:$s,actor:"fixture",detail:$d}')" "$JOBS_URL/api/ledger" > /dev/null; }
ledger_get() { "$REALCURL" -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/ledger?kind=$(jq -rn --arg v "$1" '$v|@uri')&key=$(jq -rn --arg v "$2" '$v|@uri')" | jq -r '.ledger | "\(.status // "") \(.detail // "")"' 2>/dev/null; }
lease_free() { # rc 0 when a probe holder can take the lease at once (then gives it back)
  local out f
  out=$("$REALCURL" -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
    -d "$(jq -nc --arg p "$1" '{lane:"migration",project:$p,holder:"probe-holder"}')" "$JOBS_URL/api/project-leases/acquire")
  f=$(jq -r '.fence // empty' <<<"$out")
  [ -n "$f" ] || return 1
  "$REALCURL" -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
    -d "$(jq -nc --arg p "$1" --argjson f "$f" '{lane:"migration",project:$p,holder:"probe-holder",fence:$f}')" "$JOBS_URL/api/project-leases/release" > /dev/null
}

# ── the seams ──────────────────────────────────────────────────────────────
# Fixture state lives in $ML_FX (one dir per case):
#   prs.tsv     <n>\t<head>\t<draft>     files/<n>  added paths
#   ci/<sha>    ci state (else ci_default, else green)
#   nolead/<n>  no lead MERGE            box/<head> box word (rc 2 when "rc2")
#   block/<n>   a BLOCK scan line        cr/<n>     a CR standing
#   headnow/<n> the head the re-read sees state.json status the app answers
#   status_fail status unreadable        merge_rc/<n> merge rc
#   on_batch_ci a script run on the first CI read of a non-member sha
#   ci_wait     log paths: a CI read waits for the other tick's refusal line
cat > "$T/seams.sh" <<'EOF'
_fx() { printf '%s\n' "$*" >> "$ML_FX/calls"; }
mlx_pr_list() {
  _fx pr_list
  [ -e "$ML_FX/list_fail" ] && return 75
  jq -Rn '[inputs | split("\t") | {n: (.[0]|tonumber), head: .[1], draft: (.[2] == "true")}]' < "$ML_FX/prs.tsv" > "$2"
}
mlx_pr_files() { _fx "pr_files $2"; cp "$ML_FX/files/$2" "$3"; }
mlx_pr_head() {
  _fx "pr_head $2"
  if [ -s "$ML_FX/headnow/$2" ]; then echo "open $(cat "$ML_FX/headnow/$2")"; else echo "open $(awk -F'\t' -v n="$2" '$1==n{print $2}' "$ML_FX/prs.tsv")"; fi
}
mlx_ci_state() {
  _fx "ci $2"
  if ! grep -q "	$2	" "$ML_FX/prs.tsv" && [ -e "$ML_FX/on_batch_ci" ] && [ ! -e "$ML_FX/on_batch_ci.done" ]; then
    touch "$ML_FX/on_batch_ci.done"; bash "$ML_FX/on_batch_ci"
  fi
  # ci_wait names logs: hold the CI read (bounded, 30 s) until the other tick
  # has logged its refusal, so the two ticks overlap on every machine.
  if [ -s "$ML_FX/ci_wait" ]; then
    local i; for ((i = 0; i < 300; i++)); do
      xargs grep -hsE 'lease held by another tick|already running on this box' < "$ML_FX/ci_wait" | grep -q . && break
      sleep 0.1
    done
  fi
  if [ -s "$ML_FX/ci/$2" ]; then cat "$ML_FX/ci/$2"; else cat "$ML_FX/ci_default" 2>/dev/null || echo green; fi
}
mlx_lead_clears() { _fx "lead $2"; [ ! -e "$ML_FX/nolead/$2" ]; }
mlx_box_word() {
  _fx "box $2"
  [ -s "$ML_FX/box/$3" ] || return 1
  [ "$(cat "$ML_FX/box/$3")" = rc2 ] && return 2
  cat "$ML_FX/box/$3"
}
mlx_block_scan() { _fx "block $2"; [ -s "$ML_FX/block/$2" ] || return 0; cat "$ML_FX/block/$2"; return 1; }
mlx_cr_standing() { _fx "cr $2"; [ -e "$ML_FX/cr/$2" ] || return 1; echo "https://example.invalid/review	reviewer	2026-10-28T00:00:00Z	cr-1@abc"; return 0; }
mlx_git_remote() { _fx git_remote; ML_REMOTE="$ML_FX/origin.git"; }
mlx_pr_create() {
  local n; n=$((900 + $(grep -c '^pr_create' "$ML_FX/calls")))
  _fx "pr_create $2 $3"; cp "$4" "$ML_FX/batch-body-$n.md"; echo "$n"
}
mlx_pr_close() { _fx "pr_close $2"; }
mlx_comment() { _fx "comment $2 $(head -1 "$3")"; cat "$3" >> "$ML_FX/comments"; }
mlx_merge() {
  _fx "merge $2 $3"
  local rc=0; [ -s "$ML_FX/merge_rc/$2" ] && rc=$(cat "$ML_FX/merge_rc/$2")
  [ "$rc" = 0 ] && printf 'mergesha%s' "$2"
  [ "$rc" = 0 ] || printf 'refused-fixture'
  return "$rc"
}
mlx_status_get() {
  _fx status_get
  [ -e "$ML_FX/status_fail" ] && return 1
  if [ -s "$ML_FX/status.json" ]; then cp "$ML_FX/status.json" "$1"; else echo '{"pending":[],"applied":[]}' > "$1"; fi
}
mlx_alert() { _fx "alert $1 $2"; printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ML_FX/alerts"; }
mlx_sleep() { _fx "sleep $1"; }
EOF
export BASH_ENV="$T/seams.sh"

# The apply command committed on the fixture's main: it applies prisma/sql/*.sql
# in name order like the project's ledger CLI, keeping applied rows as they are.
APPLY_MAIN='#!/bin/bash
echo main > "$ML_FX/apply-marker"
printf "%s" "$DATABASE_URL" > "$ML_FX/dburl"
env | grep -cE "^(MIGRATION_TOKEN|HARNESS_SECRET)=" > "$ML_FX/creds"
st="$ML_FX/status.json"; [ -s "$st" ] || echo "{\"pending\":[],\"applied\":[]}" > "$st"
for f in $(ls prisma/sql/*.sql | LC_ALL=C sort); do
  b=${f##*/}
  jq -e --arg b "$b" "any(.applied[]; .filename == \$b)" "$st" >/dev/null && continue
  [ -s "$ML_FX/skip" ] && grep -qF "$(cat "$ML_FX/skip")" <<<"$b" && continue
  echo "$b" >> "$ML_FX/apply-order"
  jq --arg b "$b" --arg s "$(sha256sum "$f" | cut -d" " -f1)" ".applied += [{filename:\$b, checksum:\$s}]" "$st" > "$st.t" && mv "$st.t" "$st"
done
echo "applied ok"'

# newp <name> — a fresh project mk-<name>: origin with main, a hub clone, a
# fleet.conf row, the two enabling settings rows and its env file.
newp() {
  P="mk-$1"; C="$T/c-$1"; export ML_FX="$C"
  mkdir -p "$C"/{files,ci,nolead,box,block,cr,headnow,merge_rc}
  : > "$C/prs.tsv"; : > "$C/calls"; : > "$C/alerts"
  git init -q --bare -b main "$C/origin.git"
  git init -q -b main "$C/seed"
  mkdir -p "$C/seed/prisma/sql" "$C/seed/scripts/db"
  echo "CREATE TABLE base (id int);" > "$C/seed/prisma/sql/0001_base.sql"
  printf 'line one\nline two\n' > "$C/seed/README.md"
  printf '%s\n' "$APPLY_MAIN" > "$C/seed/scripts/db/apply.sh"
  git -C "$C/seed" add -A && git -C "$C/seed" commit -q -m base
  git -C "$C/seed" push -q "$C/origin.git" main
  # Production already holds main's own migration.
  jq -nc --arg s "$(sha256sum "$C/seed/prisma/sql/0001_base.sql" | cut -d' ' -f1)" \
    '{pending: [], applied: [{filename: "0001_base.sql", checksum: $s}]}' > "$C/status.json"
  git clone -q "$C/origin.git" "$H/repos/$P"
  printf '%s Fixture/%s - - 2 hub\n' "$P" "$P" >> "$H/fleet.conf"
  setting "mc_migration_hold.apply_lane.$P" migration
  setting "mc_migration_hold.globs.$P" 'prisma/sql/*.sql'
  cat > "$H/env/$P.env" <<EOT
MIGRATION_LANE_APPLY_CMD="bash scripts/db/apply.sh"
MIGRATION_LANE_DATABASE_URL=postgres://fixture-user:fixture-pass@db.example.invalid/$P
DATA_LANE_APP_BASE=https://app.example.invalid
MIGRATION_TOKEN=tok-fixture-$1
EOT
}
SLUG() { printf 'Fixture/%s' "$P"; }

# mkpr <n> <path> <content> [<path2> <content2>] [--draft] — a PR branch off main.
mkpr() {
  local n="$1" draft=false w="$C/w-$1" head
  shift
  [ -d "$w" ] && scratch_rm "$w"
  git clone -q "$C/origin.git" "$w"
  while [ "$#" -ge 2 ]; do
    mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" > "$w/$1"; shift 2
  done
  [ "${1:-}" = --draft ] && draft=true
  git -C "$w" add -A && git -C "$w" commit -q -m "pr $n"
  git -C "$w" push -q origin "HEAD:refs/pull/$n/head"
  head=$(git -C "$w" rev-parse HEAD)
  git -C "$w" diff --name-only --diff-filter=A origin/main HEAD > "$C/files/$n"
  printf '%s\t%s\t%s\n' "$n" "$head" "$draft" >> "$C/prs.tsv"
  [ "${NOCV:-0}" = 1 ] || ledger_put mc-merge-verdict "$(SLUG)#$n" clear "$head iron-law scan clean"
  eval "HEAD_$n=$head"
}
headof() { awk -F'\t' -v n="$1" '$1==n{print $2}' "$C/prs.tsv"; }
run() { ( cd "$T" && LANE_GATE_DISABLE="${LGD:-1}" bash "$H/bin/migration-lane.sh" "$@" ) >> "$C/run.out" 2>&1; }
calls() { grep -c "^$1" "$C/calls"; }
lg() { grep -F "[$P] " "$H/logs/migration-lane.log"; }
merges() { grep '^merge ' "$C/calls" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'; }
