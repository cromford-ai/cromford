#!/bin/bash
# tests/fly-envbundle-ssh-off.bh-8316-test.sh — BH-8316 (MKF-1, 2026-10-25): the
# settings row pool.envbundle_ssh.<project> = off makes bin/fly-envbundle.sh
# refuse the ssh extract, so a pool spawn that falls back to the push path is
# visible instead of silent.
#
# PINNED:
#   A   row `off`, remote box -> rc 1, 0 ssh calls, exactly 1 ALERTS line
#       "push path refused: ssh off" for the project, one beat with
#       akey alert:envbundle-ssh-off-<p>, a FATAL naming the row.
#   A2  row ` OFF ` -> refused as A (trim + case fold).
#   B   no row -> runs as today: rc 0, 1 ssh call, the bundle, no extra stderr.
#   B2  rows on / of / off-later / 0 -> each runs (rc 0, 1 ssh call).
#   C   the row read fails (no cache, worker unreachable) -> fail open: rc 0,
#       1 ssh call, exactly 1 `read failed` stderr line, 0 ALERTS lines.
#   D   owning box `local`, row off -> the local extract runs (no ssh at all).
#   E   no row + env POOL_ENVBUNDLE_SSH=off -> refused; row on + env off -> runs.
#   F   bin/fly-pool.sh's `# >>> bundle reason` block, lifted by its markers,
#       turns A's stderr into the refusal reason.
#   G   no fixture secret value reaches any alert, beat or stderr.
# Every case runs in its own copy of the fixture harness; no order dependence.
# No network: ssh and curl are shims, beat.sh is a stub.
#
# Run from anywhere: bash tests/fly-envbundle-ssh-off.bh-8316-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

P=project-6-os
NOW=1761400000
BASE="$T/base"
mkdir -p "$BASE/bin/lib" "$BASE/env" "$BASE/logs" "$BASE/state" "$T/fake"
for s in bin/fly-envbundle.sh bin/alert-line.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$BASE" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
# BOX_MODE picks the owning box: remote (a tailnet ip) or local (the hub).
cat > "$BASE/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
case "$1" in
  --tailnet-ip) [ "${BOX_MODE:-remote}" = local ] && echo local || echo 192.0.2.10 ;;
  *) [ "${2:-}" = repo ] && echo example-org/project-6-os ;;
esac
STUB
cat > "$BASE/bin/gh-token.sh" <<'STUB'
#!/bin/bash
printf 'ghp_fixture_pat\n'
STUB
# beat.sh records the payload and fails, so alert-line.sh appends the line.
cat > "$BASE/bin/beat.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$HARNESS/beat.calls"
exit 1
STUB
# The ssh shim: one line per call, then the fixture bundle.
cat > "$T/fake/ssh" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in root@*) printf '%s\n' "$a" >> "$CAP/ssh.calls" ;; esac; done
printf '===GLOBAL===\nCLAUDE_CODE_OAUTH_TOKEN=tok-fixture-1\nGH_TOKEN=ghp_fixture_pat\n===PROJECT===\nX=1\n'
STUB
# curl is never the real one: an unreachable worker.
cat > "$T/fake/curl" <<'STUB'
#!/bin/bash
echo call >> "$CAP/curl.calls"
exit 7
STUB
chmod +x "$BASE/bin/"*.sh "$T/fake/ssh" "$T/fake/curl"
# The local extract (case D) reads these.
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-fixture-1\n' > "$BASE/env/global.env"
printf 'X=1\n' > "$BASE/env/$P.env"

# cache <h> <json values object> — a fresh settings cache, so setting_get
# answers with no request.
cache() {
  jq -nc --argjson now "$NOW" --argjson v "$2" '{fetched_at:$now, values:$v}' > "$1/state/settings-cache.json"
}

# run_case <tag> [env assignments...] — a fresh harness copy in $T/c-<tag>; the
# caller sets up the cache with `prep <tag>` first. RC, ERR, H, CAP are set.
prep() {
  H="$T/c-$1/h"; CAP="$T/c-$1/cap"
  rm -rf "$T/c-$1"; mkdir -p "$T/c-$1" "$CAP"
  cp -a "$BASE" "$H"
}
run_case() {
  local tag="$1"; shift
  H="$T/c-$tag/h"; CAP="$T/c-$tag/cap"
  env -i PATH="$T/fake:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" CAP="$CAP" \
    LANE_GATE_NOW="$NOW" JOBS_URL="" JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_SLEEP=0 "$@" \
    bash "$H/bin/fly-envbundle.sh" "$P" "$T/c-$tag/out" --pool >"$CAP/out" 2>"$CAP/err"
  RC=$?
  ERR=$(cat "$CAP/err")
}
nlines() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# refused <tag> — the A assertions.
refused() {
  local t="$1"
  [ "$RC" = 1 ] && ok || bad "$t: rc must be 1, got $RC ($ERR)"
  [ "$(nlines "$CAP/ssh.calls")" = 0 ] && ok || bad "$t: 0 ssh calls, got $(nlines "$CAP/ssh.calls")"
  [ "$(nlines "$H/logs/ALERTS.log")" = 1 ] && ok || bad "$t: exactly 1 ALERTS line, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
  grep -q 'push path refused: ssh off' "$H/logs/ALERTS.log" 2>/dev/null && grep -q "$P" "$H/logs/ALERTS.log" && ok \
    || bad "$t: the ALERTS line says 'push path refused: ssh off' and names $P"
  grep -q 'FATAL: push path refused: ssh off' <<<"$ERR" && grep -q "pool.envbundle_ssh.$P" <<<"$ERR" && ok \
    || bad "$t: the FATAL names the row pool.envbundle_ssh.$P, got: $ERR"
  [ "$(jq -r '.akey' "$H/beat.calls" 2>/dev/null)" = "alert:envbundle-ssh-off-$P" ] && [ "$(jq -r '.project' "$H/beat.calls" 2>/dev/null)" = "$P" ] && ok \
    || bad "$t: one beat with akey alert:envbundle-ssh-off-$P and project $P, got: $(cat "$H/beat.calls" 2>/dev/null)"
  [ ! -e "$T/c-$t/out/global.env" ] && ok || bad "$t: no bundle file may be written on a refusal"
}
# ran <tag> — the B assertions.
ran() {
  local t="$1"
  [ "$RC" = 0 ] && ok || bad "$t: rc must be 0, got $RC ($ERR)"
  [ "$(nlines "$CAP/ssh.calls")" = 1 ] && ok || bad "$t: 1 ssh call, got $(nlines "$CAP/ssh.calls")"
  grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$T/c-$t/out/global.env" 2>/dev/null && ok || bad "$t: the bundle carries CLAUDE_CODE_OAUTH_TOKEN"
  [ "$(nlines "$H/logs/ALERTS.log")" = 0 ] && ok || bad "$t: 0 ALERTS lines, got: $(cat "$H/logs/ALERTS.log")"
}

# ── A: row off ──────────────────────────────────────────────────────────────
prep a; cache "$H" "{\"pool.envbundle_ssh.$P\":\"off\"}"; run_case a; refused a
# ── A2: row " OFF " ─────────────────────────────────────────────────────────
prep a2; cache "$H" "{\"pool.envbundle_ssh.$P\":\" OFF \"}"; run_case a2; refused a2

# ── B: no row ───────────────────────────────────────────────────────────────
prep b; cache "$H" '{"some.other.key":"off"}'; run_case b; ran b
[ -z "$ERR" ] && ok || bad "B: no row adds no stderr line, got: $ERR"
[ "$(nlines "$CAP/curl.calls")" = 0 ] && ok || bad "B: a fresh cache answers the read with no request"
# ── B2: values that are not off ─────────────────────────────────────────────
for v in on of off-later 0; do
  prep "b2-$v"; cache "$H" "{\"pool.envbundle_ssh.$P\":\"$v\"}"; run_case "b2-$v"; ran "b2-$v"
done

# ── C: the read fails -> fail open, one log line ────────────────────────────
prep c; run_case c JOBS_URL=http://192.0.2.1 HARNESS_SECRET=secret-fixture POOL_ENVBUNDLE_SSH=off; ran c
[ "$(grep -c 'read failed' <<<"$ERR")" = 1 ] && grep -q "WARN: settings row pool.envbundle_ssh.$P read failed" <<<"$ERR" && ok \
  || bad "C: exactly 1 'read failed' WARN line on stderr, got: $ERR"
[ "$(nlines "$CAP/curl.calls")" -ge 1 ] && ok || bad "C: the read must have asked the (unreachable) worker"

# ── D: owning box local, row off -> local extract, no ssh ───────────────────
prep d; cache "$H" "{\"pool.envbundle_ssh.$P\":\"off\"}"; run_case d BOX_MODE=local
[ "$RC" = 0 ] && ok || bad "D: a local extract runs with the row off, rc $RC ($ERR)"
[ "$(nlines "$CAP/ssh.calls")" = 0 ] && ok || bad "D: a local extract makes no ssh call"
[ "$(nlines "$H/logs/ALERTS.log")" = 0 ] && ok || bad "D: 0 ALERTS lines"

# ── E: the env fallback, and the row winning over it ────────────────────────
prep e1; cache "$H" '{}'; run_case e1 POOL_ENVBUNDLE_SSH=off; refused e1
prep e2; cache "$H" "{\"pool.envbundle_ssh.$P\":\"on\"}"; run_case e2 POOL_ENVBUNDLE_SSH=off; ran e2

# ── F: fly-pool.sh's bundle reason reads the refusal ────────────────────────
BLOCK=$(sed -n '/^# >>> bundle reason/,/^# <<< bundle reason/p' "$DIR/bin/fly-pool.sh")
[ -n "$BLOCK" ] && ok || bad "F: '# >>> bundle reason' block not found in bin/fly-pool.sh"
AERR=$(cat "$T/c-a/cap/err")
WHY=$(bash -c "$BLOCK"$'\npool_bundle_reason 1 "$1"' _ "$AERR")
[ "$WHY" = "push path refused: ssh off (settings row pool.envbundle_ssh.$P)" ] && ok \
  || bad "F: the unclaim reason must be the refusal, got: '$WHY'"

# ── G: no fixture secret value in any alert, beat or stderr ─────────────────
LEAK=$(grep -rlE 'tok-fixture-1|ghp_fixture_pat|secret-fixture' "$T"/c-*/cap/err "$T"/c-*/h/logs "$T"/c-*/h/beat.calls 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "G: a fixture secret reached: $LEAK"

echo "fly-envbundle-ssh-off (BH-8316): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
