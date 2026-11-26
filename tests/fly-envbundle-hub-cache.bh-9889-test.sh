#!/bin/bash
# tests/fly-envbundle-hub-cache.bh-9889-test.sh — BH-9889 (C0): when the owning
# box is dark (ssh rc 255), `bin/fly-envbundle.sh <p> <dir> --pool` uses the
# hub's last good copy of the env bundle, up to pool.env_bundle_cache_max_h.
#
# THE INCIDENT. A watcher box went dark. Every pool spawn for its projects died
# "ssh env extract from <ip> failed (ssh rc 255)" and the jobs stayed queued
# for hours, although the hub had shipped the same bundle minutes before.
#
# PINNED:
#   C1  live --pool extract: rc 0, bundle-cache/<p>.raw written, file 600, dir 700.
#   C2  ssh rc 255 + cache 1 h old: rc 0, both files byte-identical to C1's,
#       exactly 1 'env bundle from hub cache (box unreachable)' line, cache
#       mtime unchanged.
#   C3  rc 255 + cache 30 h: rc 1, the FATAL of today, no hit line.
#   C3b rc 255 + cache exactly 24 h: miss.
#   C4  rc 255 + no cache: rc 1, same FATAL.  C5 rc 1 + fresh cache: rc 1.
#   C6  mode 644 cache; C7 symlink to a 600 cache; C8 empty cache: miss.
#   C9  row 0: rc 255 + fresh cache is a miss; a live run writes no cache.
#   C10 rows 169 / abc / -1 / 1.5: 24 h + one WARN without 'read failed'
#       (hit on a 1 h cache).
#   C10b row ' 6 ': 5 h cache hit, 7 h cache miss.
#   C11 no row + env POOL_ENV_BUNDLE_CACHE_MAX_H=2: 3 h cache miss, 1 h hit.
#   C12 no --pool (fly-dispatch): rc 255 + fresh cache is rc 1; a live run
#       writes no cache.  C13 --hub-global never creates bundle-cache/.
#   C14 ssh-off row: refused, 0 ssh calls, no hit line, cache not read.
#   C15 no fixture secret value in any captured stderr or stdout.
#   C17 a settings outage: 1 'read failed' line (no second read), cache hit.
#   C17b the same outage on a live extract: 1 line, the cache is written.
#   C16 bin/fly-pool.sh pool_bundle_reason of a miss is the FATAL of today.
#   C19 --pool without ENVBUNDLE_HUB_CACHE=1 (secrets-sync, rollout, docker
#       pool host) never reads or writes the cache; only fly-pool.sh sets it.
#   C18 the cache lives in state/bundle-cache/, outside the env dir that
#       bin/harden-state.sh freezes (chattr +i) and bin/audit-tail.sh pages on;
#       a live run over an older cache replaces it (content and mtime).
# Each case runs in its own copy of the fixture harness; no order dependence
# except that C1's bundle is the reference copy (built first, read only).
# No network: ssh and curl are shims, beat.sh is a stub.
#
# Run from anywhere: bash tests/fly-envbundle-hub-cache.bh-9889-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

P=cache-proj
NOW=1761400000
HIT='env bundle from hub cache (box unreachable)'
BASE="$T/base"
mkdir -p "$BASE/bin/lib" "$BASE/env" "$BASE/logs" "$BASE/state" "$T/fake"
for s in bin/fly-envbundle.sh bin/alert-line.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$BASE" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cat > "$BASE/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
case "$1" in
  --tailnet-ip) [ "${BOX_MODE:-remote}" = local ] && echo local || echo 192.0.2.10 ;;
  *) [ "${2:-}" = repo ] && echo example-org/cache-proj ;;
esac
STUB
cat > "$BASE/bin/gh-token.sh" <<'STUB'
#!/bin/bash
printf 'ghp_cachefixture_pat\n'
STUB
cat > "$BASE/bin/beat.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$HARNESS/beat.calls"
exit 1
STUB
# ssh shim: one line per call; SSH_RC non-zero = the box did not answer.
cat > "$T/fake/ssh" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in root@*) printf '%s\n' "$a" >> "$CAP/ssh.calls" ;; esac; done
[ "${SSH_RC:-0}" = 0 ] || exit "$SSH_RC"
printf '===GLOBAL===\nCLAUDE_CODE_OAUTH_TOKEN=tok-cache-fixture\nGH_TOKEN=ghp_cachefixture_pat\n===PROJECT===\nBOARD_TOKEN=board-cache-fixture\n'
STUB
cat > "$T/fake/curl" <<'STUB'
#!/bin/bash
echo call >> "$CAP/curl.calls"
exit 7
STUB
chmod +x "$BASE/bin/"*.sh "$T/fake/ssh" "$T/fake/curl"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-cache-fixture\n' > "$BASE/env/global.env"
printf 'BOARD_TOKEN=board-cache-fixture\n' > "$BASE/env/$P.env"

# prep <tag> [values json] — a fresh harness copy and a fresh settings cache.
prep() {
  H="$T/c-$1/h"; CAP="$T/c-$1/cap"; OUT="$T/c-$1/out"
  rm -rf "$T/c-$1"; mkdir -p "$T/c-$1" "$CAP"
  cp -a "$BASE" "$H"
  local vals="${2:-}"; [ -n "$vals" ] || vals='{}'
  jq -nc --argjson now "$NOW" --argjson v "$vals" '{fetched_at:$now, values:$v}' > "$H/state/settings-cache.json"
}
CF() { printf '%s\n' "$H/state/bundle-cache/$P.raw"; }
# seed <age seconds> [mode] — put C1's cache file in this harness, aged.
seed() {
  mkdir -p -m 700 "$H/state/bundle-cache"
  cp "$REF_CACHE" "$(CF)"; chmod "${2:-600}" "$(CF)"
  touch -d "@$(( $(date +%s) - $1 ))" "$(CF)"
}
# run_eb [third arg] -- [env assignments...]. ENVBUNDLE_HUB_CACHE=1 is set the
# way bin/fly-pool.sh sets it; a case clears it with ENVBUNDLE_HUB_CACHE=.
run_eb() {
  local third="$1"; shift
  env -i PATH="$T/fake:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" CAP="$CAP" \
    LANE_GATE_NOW="$NOW" JOBS_URL="" JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_SLEEP=0 ENVBUNDLE_HUB_CACHE=1 "$@" \
    bash "$H/bin/fly-envbundle.sh" "$P" "$OUT" ${third:+"$third"} >"$CAP/out" 2>"$CAP/err"
  RC=$?
  ERR=$(cat "$CAP/err")
  cat "$CAP/out" "$CAP/err" >> "$T/all-output"
}
nhit() { grep -cF "$HIT" <<<"$ERR"; }
nlines() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
FATAL="FATAL: ssh env extract from 192.0.2.10 failed (ssh rc"
# miss <tag> <rc> — the cache was not used: today's FATAL, no hit line, no files.
miss() {
  [ "$RC" = 1 ] && ok || bad "$1: rc must be 1, got $RC ($ERR)"
  grep -qF "$FATAL $2)" <<<"$ERR" && ok || bad "$1: the FATAL of today with ssh rc $2, got: $ERR"
  [ "$(nhit)" = 0 ] && ok || bad "$1: no hub-cache line on a miss, got: $ERR"
  [ ! -s "$OUT/global.env" ] && ok || bad "$1: no bundle file on a miss"
}
# hit <tag> — the cache served: rc 0, one line, files equal to C1's.
hit() {
  [ "$RC" = 0 ] && ok || bad "$1: rc must be 0, got $RC ($ERR)"
  [ "$(nhit)" = 1 ] && ok || bad "$1: exactly 1 '$HIT' line, got: $ERR"
  cmp -s "$OUT/global.env" "$REF/global.env" && cmp -s "$OUT/$P.env" "$REF/$P.env" && ok \
    || bad "$1: the cached bundle must equal the live bundle of C1"
}

# ── C1: a live --pool extract writes the cache ───────────────────────────────
prep c1; run_eb --pool
[ "$RC" = 0 ] && ok || bad "C1: rc must be 0, got $RC ($ERR)"
[ -f "$(CF)" ] && [ ! -L "$(CF)" ] && ok || bad "C1: bundle-cache/$P.raw must be written after a good --pool extract"
[ "$(stat -c %a "$(CF)" 2>/dev/null)" = 600 ] && ok || bad "C1: cache file mode 600, got $(stat -c %a "$(CF)" 2>/dev/null)"
[ "$(stat -c %a "$H/state/bundle-cache" 2>/dev/null)" = 700 ] && ok || bad "C1: cache dir mode 700, got $(stat -c %a "$H/state/bundle-cache" 2>/dev/null)"
grep -qx '===GLOBAL===' "$(CF)" 2>/dev/null && grep -qx '===PROJECT===' "$(CF)" && ok || bad "C1: the cache holds the raw extract stream"
[ -z "$ERR" ] && ok || bad "C1: a live run with a good write adds no stderr, got: $ERR"
REF="$T/ref"; mkdir -p "$REF"; cp "$OUT/global.env" "$OUT/$P.env" "$REF/" 2>/dev/null
REF_CACHE="$T/ref/cache.raw"; cp "$(CF)" "$REF_CACHE" 2>/dev/null || : > "$REF_CACHE"

# ── C2: box dark, cache 1 h ──────────────────────────────────────────────────
prep c2; seed 3600; M0=$(stat -c %Y "$(CF)"); run_eb --pool SSH_RC=255; hit C2
[ "$(stat -c %Y "$(CF)")" = "$M0" ] && ok || bad "C2: a cached run must not refresh the cache mtime"
grep -q "ssh rc 255 from 192.0.2.10" <<<"$ERR" && grep -q 'cache age 1h of 24h' <<<"$ERR" && ok \
  || bad "C2: the hit line names the ssh rc, the box and the age, got: $ERR"
[ "$(nlines "$CAP/ssh.calls")" = 1 ] && ok || bad "C2: exactly 1 ssh attempt"

# ── C3 / C3b: stale, and the boundary ────────────────────────────────────────
prep c3;  seed $((30*3600)); run_eb --pool SSH_RC=255; miss C3 255
prep c3b; seed $((24*3600)); run_eb --pool SSH_RC=255; miss C3b 255
# ── C4: no cache ─────────────────────────────────────────────────────────────
prep c4; run_eb --pool SSH_RC=255; miss C4 255
# ── C5: the box answered and failed ──────────────────────────────────────────
prep c5; seed 3600; run_eb --pool SSH_RC=1; miss C5 1
prep c5b; seed 3600; run_eb --pool SSH_RC=130; miss C5b 130
# ── C6 / C7 / C8: unsafe or empty files ──────────────────────────────────────
prep c6; seed 3600 644; run_eb --pool SSH_RC=255; miss C6 255
prep c7; seed 3600; mv "$(CF)" "$H/env/real.raw"; ln -s "$H/env/real.raw" "$(CF)"
run_eb --pool SSH_RC=255; miss C7 255
prep c8; seed 3600; : > "$(CF)"; touch -d "@$(( $(date +%s) - 3600 ))" "$(CF)"; run_eb --pool SSH_RC=255; miss C8 255

# ── C9: row 0 = off ──────────────────────────────────────────────────────────
prep c9 '{"pool.env_bundle_cache_max_h":"0"}'; seed 3600; run_eb --pool SSH_RC=255; miss C9 255
prep c9b '{"pool.env_bundle_cache_max_h":"0"}'; run_eb --pool
[ "$RC" = 0 ] && [ ! -e "$H/state/bundle-cache" ] && ok || bad "C9b: row 0 writes no cache on a live run (rc $RC)"

# ── C10: bad rows -> 24 h + one WARN ─────────────────────────────────────────
for v in 169 abc -1 1.5; do
  prep "c10-$v" "{\"pool.env_bundle_cache_max_h\":\"$v\"}"; seed 3600; run_eb --pool SSH_RC=255; hit "C10 '$v'"
  [ "$(grep -c 'pool.env_bundle_cache_max_h' <<<"$ERR")" = 1 ] && grep -q 'cache max age 24h' <<<"$ERR" && ok \
    || bad "C10 '$v': exactly 1 WARN naming the row and 24, got: $ERR"
  grep -q 'read failed' <<<"$ERR" && bad "C10 '$v': a bad value is not a 'read failed' line, got: $ERR" || ok
done
prep c10b5 '{"pool.env_bundle_cache_max_h":" 6 "}'; seed $((5*3600)); run_eb --pool SSH_RC=255; hit "C10b 5h"
[ "$(grep -c WARN <<<"$ERR")" = 1 ] && ok || bad "C10b: ' 6 ' is a good value (only the hit line warns), got: $ERR"
prep c10b7 '{"pool.env_bundle_cache_max_h":" 6 "}'; seed $((7*3600)); run_eb --pool SSH_RC=255; miss "C10b 7h" 255

# ── C11: no row -> env, then 24 ──────────────────────────────────────────────
prep c11; seed $((3*3600)); run_eb --pool SSH_RC=255 POOL_ENV_BUNDLE_CACHE_MAX_H=2; miss C11 255
prep c11b; seed 3600; run_eb --pool SSH_RC=255 POOL_ENV_BUNDLE_CACHE_MAX_H=2; hit C11b
prep c11c; seed $((23*3600)); run_eb --pool SSH_RC=255; hit "C11c no row no env = 24"

# ── C12 / C13: other callers never use the cache ─────────────────────────────
prep c12; seed 3600; run_eb '' SSH_RC=255; miss C12 255
prep c12b; run_eb ''
[ "$RC" = 0 ] && [ ! -e "$H/state/bundle-cache" ] && ok || bad "C12b: a fly-dispatch run writes no cache (rc $RC)"
prep c13; run_eb --hub-global
[ "$RC" = 0 ] && [ ! -e "$H/state/bundle-cache" ] && ok || bad "C13: --hub-global never touches bundle-cache/ (rc $RC, $ERR)"
prep c13b; run_eb --pool BOX_MODE=local
[ "$RC" = 0 ] && [ ! -e "$H/state/bundle-cache" ] && ok || bad "C13b: a local extract writes no cache (rc $RC)"

# ── C14: ssh off is refused before the cache ─────────────────────────────────
prep c14 "{\"pool.envbundle_ssh.$P\":\"off\"}"; seed 3600; run_eb --pool SSH_RC=255
[ "$RC" = 1 ] && ok || bad "C14: rc must be 1, got $RC"
[ "$(nlines "$CAP/ssh.calls")" = 0 ] && ok || bad "C14: 0 ssh calls"
[ "$(nhit)" = 0 ] && grep -q 'push path refused: ssh off' <<<"$ERR" && ok || bad "C14: refused by the guard, no hit line, got: $ERR"

# ── C17: a settings outage is one WARN line, and the cache still serves ─────
prep c17; rm -f "$H/state/settings-cache.json"; seed 3600
run_eb --pool SSH_RC=255 JOBS_URL=http://192.0.2.1 HARNESS_SECRET=secret-cache-fixture; hit C17
[ "$(grep -c 'read failed' <<<"$ERR")" = 1 ] && ok || bad "C17: exactly 1 'read failed' line for one outage, got: $ERR"
[ "$(nlines "$CAP/curl.calls")" -ge 1 ] && ok || bad "C17: the guard asked the (unreachable) worker"
# C17b the same outage on a live extract: 1 'read failed' line, the cache is
# written with the fallback max (24 h), rc 0.
prep c17b; rm -f "$H/state/settings-cache.json"
run_eb --pool JOBS_URL=http://192.0.2.1 HARNESS_SECRET=secret-cache-fixture
[ "$RC" = 0 ] && ok || bad "C17b: rc must be 0, got $RC ($ERR)"
[ "$(grep -c 'read failed' <<<"$ERR")" = 1 ] && [ "$(grep -c . <<<"$ERR")" = 1 ] && ok || bad "C17b: exactly 1 stderr line, the guard's 'read failed', got: $ERR"
cmp -s "$(CF)" "$REF_CACHE" && ok || bad "C17b: the cache is written with the fallback max during a settings outage"

# ── C16: fly-pool.sh's bundle reason is today's on a miss ────────────────────
BLOCK=$(sed -n '/^# >>> bundle reason/,/^# <<< bundle reason/p' "$(cd "$(dirname "$0")/.." && pwd)/bin/fly-pool.sh")
[ -n "$BLOCK" ] && ok || bad "C16: '# >>> bundle reason' block not found in bin/fly-pool.sh"
for c in c3 c4 c6; do
  WHY=$(bash -c "$BLOCK"$'\npool_bundle_reason 1 "$1"' _ "$(cat "$T/c-$c/cap/err")")
  [ "$WHY" = "ssh env extract from 192.0.2.10 failed (ssh rc 255)" ] && ok \
    || bad "C16 $c: the unclaim reason must stay today's FATAL, got: '$WHY'"
done

# ── C18: outside the hardened env dir; a live run refreshes an old cache ────
prep c18; seed 7200; printf '===GLOBAL===\nOLD=1\n===PROJECT===\n' > "$(CF)"; touch -d "@$(( $(date +%s) - 7200 ))" "$(CF)"
M0=$(stat -c %Y "$(CF)"); run_eb --pool
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok || bad "C18: a live run over an old cache is rc 0 with no WARN, got rc $RC: $ERR"
cmp -s "$(CF)" "$REF_CACHE" && ok || bad "C18: the live run must replace the old cache content"
[ "$(stat -c %Y "$(CF)")" -gt "$M0" ] && ok || bad "C18: the live run must refresh the cache mtime"
case "$(CF)" in "$H/env/"*) bad "C18: the cache must not be under the env dir (harden-state freezes it)" ;; *) ok ;; esac
[ -z "$(find "$H/env" -name 'bundle-cache*' 2>/dev/null)" ] && ok || bad "C18: nothing named bundle-cache under the env dir"
HS="$(cd "$(dirname "$0")/.." && pwd)/bin/harden-state.sh"
grep -qF 'find "$ENV_DIR" -type f' "$HS" && ! grep -q 'state/bundle-cache\|HARNESS/state' "$HS" && ok \
  || bad "C18: harden-state's freeze set changed; re-check that it does not cover state/bundle-cache"

# ── C19: only fly-pool's spawn call opts in (ENVBUNDLE_HUB_CACHE=1) ─────────
# fly-pool-secrets-sync, fly-pool-rollout and docker-pool-host also pass --pool;
# they must never read or write the cache (a stale bundle must not reach Fly
# secrets or a rollout).
prep c19; seed 3600; run_eb --pool SSH_RC=255 ENVBUNDLE_HUB_CACHE=; miss C19 255
grep -q 'hub cache' <<<"$ERR" && bad "C19: no hub-cache line without the flag, got: $ERR" || ok
prep c19b; run_eb --pool ENVBUNDLE_HUB_CACHE=
[ "$RC" = 0 ] && [ ! -e "$H/state/bundle-cache" ] && ok || bad "C19b: --pool without the flag writes no cache (rc $RC)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -q 'ENVBUNDLE_HUB_CACHE=1 "$HARNESS/bin/fly-envbundle.sh" "$P" "$TMP" --pool' "$ROOT/bin/fly-pool.sh" && ok \
  || bad "C19c: bin/fly-pool.sh's spawn call must set ENVBUNDLE_HUB_CACHE=1"
OPTIN=$(grep -l 'ENVBUNDLE_HUB_CACHE' "$ROOT/bin/fly-pool-secrets-sync.sh" "$ROOT/bin/fly-pool-rollout.sh" "$ROOT/bin/lib/docker-pool-host.sh" "$ROOT/bin/fly-dispatch.sh" 2>/dev/null)
[ -z "$OPTIN" ] && ok || bad "C19d: only bin/fly-pool.sh may set ENVBUNDLE_HUB_CACHE, also in: $OPTIN"

# ── C15: no fixture secret on any captured line ──────────────────────────────
grep -qE 'tok-cache-fixture|ghp_cachefixture_pat|board-cache-fixture|secret-cache-fixture' "$T/all-output" && bad "C15: a fixture secret reached stdout/stderr" || ok

echo "fly-envbundle-hub-cache (BH-9889): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
