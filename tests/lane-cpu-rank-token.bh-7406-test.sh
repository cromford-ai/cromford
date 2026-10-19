#!/bin/bash
# tests/lane-cpu-rank-token.bh-7406-test.sh — BH-7406 C0: bin/lane-cpu-rank.sh
# posts on a token armed AFTER the 1 h window, names why a run failed, and the
# seeded settings row sends the table to #7406. Runs the script as shipped in a
# scratch harness, with the same seams as tests/lane-cpu-rank.bh-7252-test.sh.
#   GitHub:  a stub lib (LANE_CPU_RANK_GH_LIB). gh_auth_for exports
#            GH_TOKEN=tok-<n> and records `mint <n> before|after` (after = the
#            sampler stub already ran). gh_rest_comment answers 401 (rc 75,
#            GH_REST_STATUS=401 GH_REST_REASON=auth) when the token in use was
#            minted before the sampler: an installation token lives 1 h and the
#            window is 1 h, so that token is dead at post time on the hub.
#   Sampler: LANE_CPU_RANK_SAMPLER, a stub that touches $T/sampled, prints
#            $T/sample.out and $T/sample.err, exits $T/sample.rc.
#
#   K1  default run: two mints, the second after the window; the post used
#       tok-2; state posted; log rank=posted, no why=   (red before BH-7406)
#   K2  LANE_CPU_RANK_SECONDS=60: the same order
#   K3  post 401 even after the re-arm: attempts 1, no posted,
#       why=http-401/auth
#   K4  post network failure: why=http-000/network
#   K5  read 403 rate limit: rank=read-failed why=http-403/rate-limit, one
#       mint, no sampler
#   K6  sampler rc 2 "no ticks" -> why=sampler-rc-2:no_ticks; rc 64 with no
#       stderr -> why=sampler-rc-64; no second mint
#   K7  HARNESS_REPO empty -> not-configured why=HARNESS_REPO; posted and found
#       lines carry no why=
#   K8  the schema fragment: one INSERT OR IGNORE settings row
#       lane_cpu_rank.issue=7406; applies to sqlite, keeps an operator value
#   K9  the marker exists: rank=found, one mint, no post
#   K10 row lane_cpu_rank.issue=7406: issue=7406(row), state-7406, the marker
#       <!-- lane-cpu-rank:7406 --> ends the body, 1 post, 0 alerts
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_REL=bin/lane-cpu-rank.sh
FRAG="$REPO/worker/jobs/schema.d/202610182044-bh-7406-lane-cpu-rank-issue.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in "$SCRIPT_REL" bin/lib/lane-placement.sh bin/lib/lane-gate.sh; do
  [ -f "$REPO/$L" ] || continue
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null

STATE_DIR="$H/state/lane-cpu-rank"
LOG="$H/logs/lane-cpu-rank.log"

# ── stubs ────────────────────────────────────────────────────────────────────
GHLIB="$T/ghlib.sh"
cat > "$GHLIB" <<EOF
gh_auth_for() {
  local n when=before
  n=\$(( \$(cat "$T/mints" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/mints"
  [ -e "$T/sampled" ] && when=after
  echo "\$when" > "$T/tok-\$n.when"
  echo "mint \$n \$when" >> "$T/calls"
  export GH_TOKEN="tok-\$n"
  return 0
}
gh_auth_reset() { :; }
gh_rest_issue_comments() {
  echo "read \$1 \$2" >> "$T/calls"
  if [ -e "$T/read.fail" ]; then GH_REST_STATUS=403; GH_REST_REASON=rate-limit; return 75; fi
  GH_REST_STATUS=200; GH_REST_REASON=
  cat "$T/comments.json"
}
gh_rest_comment() {
  echo "post \$1 \$2 \${GH_TOKEN:-none}" >> "$T/calls"
  cp "\$3" "$T/body.md"
  if [ -e "$T/post.force" ]; then read -r GH_REST_STATUS GH_REST_REASON < "$T/post.force"; return 75; fi
  if [ "\$(cat "$T/\${GH_TOKEN:-none}.when" 2>/dev/null)" != after ]; then
    GH_REST_STATUS=401; GH_REST_REASON=auth; return 75
  fi
  GH_REST_STATUS=201; GH_REST_REASON=
  return 0
}
EOF
SAMPLER="$T/sampler.sh"
cat > "$SAMPLER" <<EOF
#!/bin/bash
echo "sample \$*" >> "$T/calls"
touch "$T/sampled"
cat "$T/sample.out"
cat "$T/sample.err" >&2
exit \$(cat "$T/sample.rc")
EOF
chmod +x "$SAMPLER"
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "alert \$*" >> "$T/alerts"
EOF
chmod +x "$H/bin/lane-alert.sh"
cat > "$H/bin/jobs-client.sh" <<EOF
_setting_key_ok() { [[ "\$1" =~ ^[A-Za-z0-9._-]+\$ ]]; }
_jobs_req() { return 1; }
setting_get() {
  local v
  v=\$(awk -F '\t' -v k="\$1" '\$1 == k { print \$2; f = 1 } END { exit f ? 0 : 1 }' "$T/settings.tsv") || return 2
  printf '%s' "\$v"
}
EOF
printf '30.10 28.40 27.00 3/900 12345\n' > "$T/loadavg"

reset() {
  scratch_rm "$STATE_DIR" 2>/dev/null; mkdir -p "$STATE_DIR"
  : > "$LOG"; : > "$T/settings.tsv"
  rm -f "$T/calls" "$T/alerts" "$T/body.md" "$T/read.fail" "$T/post.force" "$T/sampled" "$T/mints" "$T"/tok-*.when
  echo '[]' > "$T/comments.json"
  printf '50.0\tmerge-conductor\t7200.0\n25.0\tpipeline-health\t3600.0\n25.0\tother\t3600.0\nLCS verdict\n' > "$T/sample.out"
  : > "$T/sample.err"; echo 0 > "$T/sample.rc"
  return 0
}
run() {
  env HARNESS="$H" HARNESS_REPO="${REPO_OVERRIDE-Example/fixture-repo}" HARNESS_TEST_SANDBOX=1 \
    LANE_CPU_RANK_GH_LIB="$GHLIB" LANE_CPU_RANK_SAMPLER="$SAMPLER" \
    LANE_CPU_RANK_LOADAVG="$T/loadavg" "$@" "$H/$SCRIPT_REL" > "$T/run.out" 2>&1
  RC=$?
}
lastlog() { tail -1 "$LOG" 2>/dev/null; }
ncalls() { grep -c "^${1}" "$T/calls" 2>/dev/null || true; }
state() { cat "$STATE_DIR/state-${1:-7252}" 2>/dev/null; }
mints() { grep '^mint' "$T/calls" 2>/dev/null | tr '\n' ';'; }

# ── K1 default run posts on a token armed after the window ───────────────────
reset; run
[ "$RC" = 0 ] && ok "K1 exit 0" || bad "K1 exit $RC: $(head -5 "$T/run.out")"
[ "$(mints)" = "mint 1 before;mint 2 after;" ] && ok "K1 two mints, the second after the window" \
  || bad "K1 mints: $(mints)"
grep -q '^post Example/fixture-repo 7252 tok-2$' "$T/calls" && ok "K1 the post used tok-2" \
  || bad "K1 post: $(grep '^post' "$T/calls")"
state | grep -q '^posted .* 7252$' && ok "K1 state posted" || bad "K1 state: $(state)"
lastlog | grep -q 'rank=posted issue=7252(default) rows=2 load5=28.40->28.40$' && ok "K1 log rank=posted, no why=" \
  || bad "K1 log: $(lastlog)"

# ── K2 a short window: the same order ────────────────────────────────────────
reset; run LANE_CPU_RANK_SECONDS=60
grep -q -- '--seconds 60' "$T/calls" && [ "$(mints)" = "mint 1 before;mint 2 after;" ] \
  && state | grep -q '^posted ' && ok "K2 SECONDS=60: re-armed after the window, posted" \
  || bad "K2: $(mints) / $(state)"

# ── K3 post 401 after the re-arm ─────────────────────────────────────────────
reset; echo '401 auth' > "$T/post.force"; run
[ "$(state)" = "attempts 1" ] && ok "K3 attempts 1, no posted" || bad "K3 state: $(state)"
lastlog | grep -q 'rank=post-failed issue=7252(default) rows=2 load5=28.40->28.40 why=http-401/auth$' \
  && ok "K3 why=http-401/auth" || bad "K3 log: $(lastlog)"

# ── K4 post network failure ──────────────────────────────────────────────────
reset; echo '000 network' > "$T/post.force"; run
lastlog | grep -q 'rank=post-failed .* why=http-000/network$' && ok "K4 why=http-000/network" || bad "K4 log: $(lastlog)"

# ── K5 read 403 rate limit ───────────────────────────────────────────────────
reset; touch "$T/read.fail"; run
lastlog | grep -q 'rank=read-failed issue=7252(default) rows=0 load5=NA->NA why=http-403/rate-limit$' \
  && ok "K5 why=http-403/rate-limit" || bad "K5 log: $(lastlog)"
[ "$(ncalls mint)" = 1 ] && [ "$(ncalls sample)" = 0 ] && ok "K5 one mint, no sampler" \
  || bad "K5 calls: $(cat "$T/calls")"

# ── K6 sampler failures ──────────────────────────────────────────────────────
reset; echo 2 > "$T/sample.rc"; printf 'no ticks\nsecond line\n' > "$T/sample.err"; run
lastlog | grep -q 'rank=sample-failed .* why=sampler-rc-2:no_ticks$' && ok "K6 why=sampler-rc-2:no_ticks" \
  || bad "K6 rc 2 log: $(lastlog)"
[ "$(ncalls mint)" = 1 ] && [ "$(ncalls post)" = 0 ] && ok "K6 rc 2: no second mint, no post" || bad "K6 calls: $(cat "$T/calls")"
reset; echo 64 > "$T/sample.rc"; run
lastlog | grep -q 'rank=sample-failed .* why=sampler-rc-64$' && ok "K6 why=sampler-rc-64" || bad "K6 rc 64 log: $(lastlog)"
reset; echo 2 > "$T/sample.rc"; head -c 300 /dev/zero | tr '\0' 'x' > "$T/sample.err"; run
w=$(lastlog | sed -n 's/.* why=//p')
[ "${#w}" -le 133 ] && [ "${#w}" -gt 13 ] && ok "K6 long stderr cut to 120 chars" || bad "K6 long: ${#w} $(lastlog)"

# ── K7 not-configured and the lines with no why= ─────────────────────────────
reset; REPO_OVERRIDE="" run
lastlog | grep -q 'rank=not-configured .* why=HARNESS_REPO$' && ok "K7 why=HARNESS_REPO" || bad "K7 log: $(lastlog)"
reset; run; run
[ "$(grep -c 'why=' "$LOG")" = 0 ] && ok "K7 posted lines carry no why=" || bad "K7 log: $(cat "$LOG")"

# ── K8 the schema fragment ───────────────────────────────────────────────────
if [ ! -f "$FRAG" ]; then
  bad "K8 fragment missing: ${FRAG#"$REPO"/}"
else
  [ "$(grep -c '^INSERT OR IGNORE INTO settings' "$FRAG")" = 1 ] && [ "$(grep -v '^--' "$FRAG" | grep -ci 'insert')" = 1 ] \
    && grep -q "('lane_cpu_rank.issue','7406'," "$FRAG" && ok "K8 one INSERT OR IGNORE row lane_cpu_rank.issue=7406" \
    || bad "K8 fragment: $(grep -v '^--' "$FRAG")"
  # sql <db> <statements...> — the sqlite3 CLI, or python3's sqlite3 module
  # when the CLI is missing. Prints the rows of the last statement.
  sql() {
    local db="$1"; shift
    if command -v sqlite3 >/dev/null 2>&1; then printf '%s\n' "$@" | sqlite3 "$db"
    else printf '%s\n' "$@" | python3 -I -c '
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); s = sys.stdin.read()
parts = [p for p in s.split(";\n") if p.strip()]
for p in parts[:-1]: c.executescript(p + ";")
for r in c.execute(parts[-1]): print("|".join(map(str, r)))
c.commit()' "$db"; fi
  }
  if command -v sqlite3 >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    DDL='CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT);'
    GET="SELECT value FROM settings WHERE key='lane_cpu_rank.issue';"
    rm -f "$T/k8a.db" "$T/k8b.db"
    [ "$(sql "$T/k8a.db" "$DDL" "$(cat "$FRAG")" "$(cat "$FRAG")" "$GET")" = 7406 ] \
      && ok "K8 applies twice to an empty table, reads 7406" || bad "K8 empty apply"
    [ "$(sql "$T/k8b.db" "$DDL" "INSERT INTO settings VALUES ('lane_cpu_rank.issue','7500','op','op','x');" "$(cat "$FRAG")" "$GET")" = 7500 ] \
      && ok "K8 an operator value 7500 stays" || bad "K8 operator value overwritten"
  else
    echo "  SKIP K8 sqlite apply: sqlite3 and python3 missing"
  fi
fi

# ── K9 the marker exists ─────────────────────────────────────────────────────
reset
jq -n '[{body:"Table.\n<!-- lane-cpu-rank:7252 -->"}]' > "$T/comments.json"; run
lastlog | grep -q 'rank=found issue=7252(default) rows=0 load5=NA->NA$' && ok "K9 rank=found, no why=" || bad "K9 log: $(lastlog)"
[ "$(ncalls mint)" = 1 ] && [ "$(ncalls post)" = 0 ] && ok "K9 one mint, no post" || bad "K9 calls: $(cat "$T/calls")"

# ── K10 the seeded row sends the table to #7406 ──────────────────────────────
reset; printf 'lane_cpu_rank.issue\t7406\n' >> "$T/settings.tsv"; run
lastlog | grep -q 'rank=posted issue=7406(row) ' && ok "K10 issue=7406(row)" || bad "K10 log: $(lastlog)"
state 7406 | grep -q '^posted .* 7406$' && ok "K10 state-7406 posted" || bad "K10 state: $(state 7406)"
tail -1 "$T/body.md" 2>/dev/null | grep -qxF '<!-- lane-cpu-rank:7406 -->' && ok "K10 the body ends with the 7406 marker" \
  || bad "K10 body last line: $(tail -1 "$T/body.md" 2>/dev/null)"
[ "$(ncalls post)" = 1 ] && [ ! -e "$T/alerts" ] && ok "K10 1 post, 0 alerts" || bad "K10 posts $(ncalls post), alerts: $(cat "$T/alerts" 2>/dev/null)"

echo "lane-cpu-rank-token: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
