#!/bin/bash
# tests/fleet-propagate-hub-timeout.bh-7122-test.sh — bin/fleet-propagate.sh: a
# hub sync killed AFTER the code copy is ok + warn, not a CRITICAL "OLD harness"
# page; a kill before the copy still pages.
#
# WHY (BH-7122). The hub step runs bin/harness-sync.sh under one outer timeout.
# The code copy runs early and most kills land in the steps after it, so a kill
# paged "Still running the OLD harness: hub" while live bin/ was already new.
# harness-sync now stamps state/harness-sync-phase; this lane reads it after
# an rc 124.
#
# The hub's harness-sync is a stub that writes its stamp and pending markers
# through the REAL writer (bin/lib/harness-sync-step.sh), then sleeps or exits.
# git is real, against a scratch origin. lane-gate is real, against a composed
# registry and a seeded settings cache.
#   P1  `step=worker-phase <NEW>` + a kill: hub=ok(post-copy timeout:
#       worker-phase), --severity warn, no "OLD harness", .hub_post_copy
#   P1b the same stamp and rc 124 straight from the sync: ok + warn
#   P2  no stamp + a kill: hub=fail(harness-sync rc=124), --critical, OLD: hub
#   P3  `copied <NEW>` + a console-pages marker: the warn names it, .hub_pending
#   P4  a stamp at a commit that descends from NEW: ok
#   P5  a stamp at the previous sha: CRITICAL
#   P6  a garbage stamp, and a sha the checkout does not know: CRITICAL
#   P7  alert-verify fleet-propagate-partial reads the P1 line as clean (rc 0)
#       and the P2 line as partial (rc 1)
#   P8  `copied <NEW>` and rc 30: CRITICAL (only a timeout is reclassified)
#   P9  the settings row lane.fleet-propagate.hub_sync_timeout_s=90 reaches
#       `timeout` as 90; no row and no env passes 300
#   P10 HUB_SYNC_TIMEOUT_S=abc uses 300 and logs one line
#   P11 a box failure with a post-copy hub: --critical, hub not in the OLD list
#   P12 round trip: the REAL bin/harness-sync.sh hangs in agent-rules after its
#       copy; the real stamp gives hub=ok(post-copy timeout: agent-rules)
#
# Run from anywhere: tests/fleet-propagate-hub-timeout.bh-7122-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "fleet-propagate-hub-timeout.bh-7122-test: SKIPPED — jq missing"; exit 0; }

H="$T/harness"
mkdir -p "$H/bin/alert-verify" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/bin"
: > "$H/env/global.env"     # never the box's own /etc/harness/env
cp "$DIR/bin/fleet-propagate.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/lane-gate.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/alert-verify/fleet-propagate-partial.sh "$H" >/dev/null || exit 1
echo hub > "$H/state/box-id"
cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha 192.0.2.1
EOF
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: lanes-build.sh could not compose the registry"

# ── stubs ────────────────────────────────────────────────────────────────────
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
IP=""; for A in "$@"; do case "$A" in root@*) IP="${A#root@}" ;; esac; done
if [ -n "${SSH_FAIL_IP:-}" ] && [ "$IP" = "$SSH_FAIL_IP" ]; then echo "0000000"; exit 7; fi
echo "cafe123456789"; exit 0
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && exit 0
exit 0
EOF
# timeout: records its argv, then is the real one.
REAL_TIMEOUT=$(command -v timeout)
cat > "$T/bin/timeout" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/timeout.argv"
exec "$REAL_TIMEOUT" "\$@"
EOF
# The hub's harness-sync: the stamp and markers come from the real writer.
cat > "$H/bin/harness-sync.sh" <<EOF
#!/bin/bash
. "$DIR/bin/lib/harness-sync-step.sh" || exit 99
if [ -n "\${HS_STAMP_RAW:-}" ]; then printf '%s\n' "\$HS_STAMP_RAW" > "\$HARNESS/state/harness-sync-phase"
elif [ -n "\${HS_STAMP_PHASE:-}" ]; then HS_SHA="\$HS_STAMP_SHA" hs_phase "\$HS_STAMP_PHASE"; fi
for s in \${HS_PENDING:-}; do HS_SHA="\$HS_STAMP_SHA" hs_pending_queue "\$s"; done
case "\${HS_ACT:-ok}" in
  sleep) exec sleep "\${HS_SLEEP:-8}" ;;   # determinism: ok — the hung sync; cut by the outer timeout under test
  exit*) exit "\${HS_ACT#exit}" ;;
esac
echo "synced (stub)"; exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"
exit 0
EOF
chmod +x "$T/bin"/* "$H/bin"/*.sh

# ── a real scratch repo: bare origin + the hub's checkout ────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"
echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"

N=1
commit() { # a new bin/ change on main, so every case has something to propagate
  N=$((N+1)); echo "echo v$N" > "$T/src/bin/run-build.sh"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "v$N" && git -C "$T/src" push -q origin main
  PREV=$NEW; NEW=$(git -C "$T/src" rev-parse HEAD)
}
NEW=$(git -C "$T/src" rev-parse HEAD); PREV=""
# run — fleet-propagate.sh itself; the stub's behaviour rides in HS_* vars.
run() {
  : > "$T/alerts"; : > "$T/timeout.argv"
  scratch_rm "$H/state/harness-sync-pending"; rm -f "$H/state/harness-sync-phase"
  local t0; t0=$(date +%s)
  ( export HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" POOL_IMAGE_MIN_AGE_MIN=0 LANE_REGISTRY="$REG" \
      FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" ALERTS="$T/alerts" \
      SSH_FAIL_IP="${SSH_FAIL_IP:-}" HS_ACT="${HS_ACT:-ok}" HS_SLEEP="${HS_SLEEP:-8}" \
      HS_STAMP_PHASE="${HS_STAMP_PHASE:-}" HS_STAMP_SHA="${HS_STAMP_SHA:-}" HS_STAMP_RAW="${HS_STAMP_RAW:-}" \
      HS_PENDING="${HS_PENDING:-}"
    if [ -n "${HUBTO+x}" ]; then export HUB_SYNC_TIMEOUT_S="$HUBTO"; else unset HUB_SYNC_TIMEOUT_S; fi
    bash "$H/bin/fleet-propagate.sh" ) > "$T/out" 2>"$T/err"
  RC=$?
  ELAPSED=$(( $(date +%s) - t0 ))
}
jsonq() { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }
lastline() { grep -F -- "..${NEW:0:7} hub=" "$H/logs/fleet-propagate.log" | tail -n 1; }
crit() { grep -q -- '^--critical fleet-propagate' "$T/alerts"; }
warn() { grep -q -- '^--severity warn fleet-propagate' "$T/alerts"; }
oldhub() { grep -q 'Still running the OLD harness: hub' "$T/alerts"; }

# first run records where the fleet is; nothing propagates
run
[ "$RC" = 0 ] && ok || bad "setup: the first run must exit 0 (rc=$RC: $(cat "$T/err"))"

# ── P1. killed after the copy, in worker-phase: ok + warn ───────────────────
commit
HUBTO=2 HS_ACT=sleep HS_STAMP_PHASE=step=worker-phase HS_STAMP_SHA="$NEW" run
lastline | grep -q " hub=ok(post-copy timeout: worker-phase) boxes=1/1 " && ok \
  || bad "P1 the run line must say hub=ok(post-copy timeout: worker-phase), got: $(lastline)"
warn && ok || bad "P1 the alert must be --severity warn: $(cat "$T/alerts")"
crit && bad "P1 a post-copy kill must not page --critical: $(cat "$T/alerts")" || ok
grep -q 'OLD harness' "$T/alerts" && bad "P1 the text must not say OLD harness: $(cat "$T/alerts")" || ok
grep -q "The hub sync timed out after the code copy, in step worker-phase; live bin/ is at ${NEW:0:7}" "$T/alerts" && ok \
  || bad "P1 the warn must name the step and the live sha: $(cat "$T/alerts")"
[ "$(jsonq .hub)" = ok ] && ok || bad "P1 .hub must stay ok (got $(jsonq .hub))"
[ "$(jsonq .hub_post_copy)" = worker-phase ] && ok || bad "P1 .hub_post_copy must be worker-phase (got $(jsonq .hub_post_copy))"
[ "$(jsonq .last_sha)" = "$NEW" ] && ok || bad "P1 last_sha must advance"
[ "$ELAPSED" -lt 8 ] && ok || bad "P1 HUB_SYNC_TIMEOUT_S=2 must cut the 8 s sync (run took ${ELAPSED}s)"
grep -q "hub: harness-sync rc=124 after the code copy (phase step=worker-phase ${NEW:0:7}), step worker-phase — counted ok" "$H/logs/fleet-propagate.log" && ok \
  || bad "P1 the log must explain the reclassification: $(tail -n 3 "$H/logs/fleet-propagate.log")"
P1_LINE=$(lastline); P1_SHA=$NEW

# ── P1b. rc 124 straight from the sync (exactly what `timeout` returns) ─────
commit
HS_ACT=exit124 HS_STAMP_PHASE=step=worker-phase HS_STAMP_SHA="$NEW" run
lastline | grep -q " hub=ok(post-copy timeout: worker-phase) " && ok || bad "P1b want hub=ok(post-copy timeout: worker-phase), got: $(lastline)"
crit && bad "P1b must not page --critical: $(cat "$T/alerts")" || ok
warn && ok || bad "P1b must be --severity warn: $(cat "$T/alerts")"

# ── P2. killed with no stamp: the CRITICAL page stays ───────────────────────
commit
HUBTO=2 HS_ACT=sleep run
lastline | grep -q " hub=fail(harness-sync rc=124) " && ok || bad "P2 want hub=fail(harness-sync rc=124), got: $(lastline)"
crit && ok || bad "P2 a kill before the copy must page --critical: $(cat "$T/alerts")"
oldhub && ok || bad "P2 the page must say 'Still running the OLD harness: hub': $(cat "$T/alerts")"
[ "$(jsonq .hub_post_copy)" = "" ] && ok || bad "P2 .hub_post_copy must be empty (got $(jsonq .hub_post_copy))"
P2_LINE=$(lastline); P2_SHA=$NEW

# ── P3. `copied <NEW>` with a pending console-pages deploy ──────────────────
commit
HS_ACT=exit124 HS_STAMP_PHASE=copied HS_STAMP_SHA="$NEW" HS_PENDING=console-pages run
lastline | grep -q " hub=ok(post-copy timeout: copied) " && ok || bad "P3 want hub=ok(post-copy timeout: copied), got: $(lastline)"
grep -q 'Pending deploy steps: console-pages\.' "$T/alerts" && ok || bad "P3 the warn must name console-pages: $(cat "$T/alerts")"
HP=$(jq -c .hub_pending "$H/state/fleet-propagate.json" 2>/dev/null)
[ "$HP" = '["console-pages"]' ] && ok || bad "P3 .hub_pending must be [\"console-pages\"] (got $HP)"
warn && ok || bad "P3 must be --severity warn"

# ── P4. the stamp sha descends from NEW (pushed after the fetch) ────────────
commit
git -C "$T/src" checkout -q -b later
echo later > "$T/src/bin/later.sh"; git -C "$T/src" add -A && git -C "$T/src" commit -qm later
LATER=$(git -C "$T/src" rev-parse HEAD); git -C "$T/src" push -q origin later
git -C "$T/src" checkout -q main
HS_ACT=exit124 HS_STAMP_PHASE="done" HS_STAMP_SHA="$LATER" run
lastline | grep -q " hub=ok(post-copy timeout: done) " && ok || bad "P4 a descendant stamp sha must be ok, got: $(lastline)"
crit && bad "P4 must not page: $(cat "$T/alerts")" || ok

# ── P5. the stamp is at the previous sha: the copy did not happen for NEW ───
commit
HS_ACT=exit124 HS_STAMP_PHASE="done" HS_STAMP_SHA="$PREV" run
lastline | grep -q " hub=fail(harness-sync rc=124) " && ok || bad "P5 an older stamp sha must stay fail, got: $(lastline)"
crit && oldhub && ok || bad "P5 must page --critical with OLD harness: hub: $(cat "$T/alerts")"

# ── P6. garbage, and a sha the checkout does not know ───────────────────────
commit
HS_ACT=exit124 HS_STAMP_RAW="garbage line here" run
lastline | grep -q " hub=fail(harness-sync rc=124) " && crit && ok || bad "P6 a garbage stamp must stay CRITICAL, got: $(lastline)"
commit
HS_ACT=exit124 HS_STAMP_RAW="copied 1234567890abcdef1234567890abcdef12345678 2026-10-16T00:00:00Z" run
lastline | grep -q " hub=fail(harness-sync rc=124) " && crit && ok || bad "P6 an unknown sha must stay CRITICAL, got: $(lastline)"

# ── P7. alert-verify reads the real P1 and P2 lines ─────────────────────────
q() { printf 'box-hub\t1790000000\t%s\n' "$(jq -nc --arg l "[orchestrator/fleet-propagate] propagating $1 to the fleet FAILED in part — hub=fail" '{kind:"fleet_alert",project:"fleet",akey:"orclane:fleet-propagate-1",line:$l}')"; }
printf '%s\n' "$P1_LINE" > "$T/p7.log"
mkdir -p "$T/p7/logs"; cp "$T/p7.log" "$T/p7/logs/fleet-propagate.log"
q "${P1_SHA:0:7}" | HARNESS="$T/p7" bash "$H/bin/alert-verify/fleet-propagate-partial.sh" >/dev/null 2>&1; AV=$?
[ "$AV" = 0 ] && ok || bad "P7 a post-copy hub line must clear the partial page (rc=$AV, line: $P1_LINE)"
printf '%s\n' "$P2_LINE" > "$T/p7/logs/fleet-propagate.log"
q "${P2_SHA:0:7}" | HARNESS="$T/p7" bash "$H/bin/alert-verify/fleet-propagate-partial.sh" >/dev/null 2>&1; AV=$?
[ "$AV" = 1 ] && ok || bad "P7 a hub=fail line must still reproduce (rc=$AV, line: $P2_LINE)"

# ── P8. `copied <NEW>` but rc 30: only a timeout is reclassified ────────────
commit
HS_ACT=exit30 HS_STAMP_PHASE=copied HS_STAMP_SHA="$NEW" run
lastline | grep -q " hub=fail(harness-sync rc=30) " && crit && ok || bad "P8 rc 30 must stay CRITICAL, got: $(lastline)"

# ── P9. the settings row; and the default ───────────────────────────────────
commit
mkdir -p "$H/state"
# 90, not 2: the registry clamps an operator row to min 60 (the cut itself is
# P1, through the env the row is exported into).
jq -nc --argjson fa "$(date -u +%s)" '{fetched_at:$fa, values:{"lane.fleet-propagate.hub_sync_timeout_s":"90"}, seeded:{}}' > "$H/state/settings-cache.json"
run
grep -q '^90 .*harness-sync.sh' "$T/timeout.argv" && ok || bad "P9 the row 90 must reach timeout: $(cat "$T/timeout.argv")"
rm -f "$H/state/settings-cache.json"; scratch_rm "$H/state/lane-gate"
commit
run
grep -q '^300 .*harness-sync.sh' "$T/timeout.argv" && ok || bad "P9 no row and no env must pass 300: $(cat "$T/timeout.argv")"

# ── P10. a bad env value is 300 and one line ────────────────────────────────
commit
: > "$H/logs/fleet-propagate.log"
HUBTO=abc run
grep -q '^300 .*harness-sync.sh' "$T/timeout.argv" && ok || bad "P10 abc must use 300: $(cat "$T/timeout.argv")"
[ "$(grep -c 'HUB_SYNC_TIMEOUT_S=abc is not a number of seconds — using 300' "$H/logs/fleet-propagate.log")" = 1 ] && ok \
  || bad "P10 abc must log exactly one line: $(cat "$H/logs/fleet-propagate.log")"

# ── P11. a box failure with a post-copy hub: CRITICAL, hub not OLD ──────────
commit
SSH_FAIL_IP=192.0.2.1 HS_ACT=exit124 HS_STAMP_PHASE=step=cost-caps HS_STAMP_SHA="$NEW" run
crit && ok || bad "P11 a failed box must still page --critical: $(cat "$T/alerts")"
grep -q 'Still running the OLD harness: box-alpha(rc=7)\.' "$T/alerts" && ok \
  || bad "P11 the OLD list must name the box and not the hub: $(cat "$T/alerts")"
oldhub && bad "P11 hub must not be in the OLD list" || ok
grep -q 'in step cost-caps' "$T/alerts" && ok || bad "P11 the page must carry the post-copy note"

# ── P12. round trip: the REAL harness-sync is the hub sync, hung after its copy
# The checkout carries an agent-rules hook that hangs; the outer timeout (4 s)
# cuts the sync inside that step. The stamp the real writer left is what the
# real reader classifies.
SSH_FAIL_IP=""
cp "$DIR/bin/harness-sync.sh" "$H/bin/harness-sync.sh"
scratch_install_closure bin/harness-sync.sh "$H" >/dev/null || exit 1
cp "$DIR/bin/alert-line.sh" "$H/bin/" 2>/dev/null
mkdir -p "$T/src/prompts" "$T/src/fly"
echo p > "$T/src/prompts/p.md"; echo f > "$T/src/fly/f.txt"
cat > "$T/src/bin/sync-agent-rules.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = apply ] || exit 0
for _ in $(seq 1 600); do sleep 1; done   # determinism: ok — the hung post-copy step; cut by the outer timeout under test
EOF
chmod +x "$T/src/bin/sync-agent-rules.sh"
commit
HUBTO=4 run
lastline | grep -q " hub=ok(post-copy timeout: agent-rules) boxes=1/1 " && ok \
  || bad "P12 the real sync cut in agent-rules must be hub=ok(post-copy timeout: agent-rules), got: $(lastline) / $(tail -n 3 "$H/logs/fleet-propagate.log")"
[ "$(cut -d' ' -f1-2 "$H/state/harness-sync-phase" 2>/dev/null)" = "step=agent-rules $NEW" ] && ok \
  || bad "P12 the real writer must leave 'step=agent-rules $NEW', got: $(cat "$H/state/harness-sync-phase" 2>/dev/null)"
cmp -s "$T/src/bin/run-build.sh" "$H/bin/run-build.sh" && ok || bad "P12 the live bin/ must hold the new code"
warn && ! crit && ok || bad "P12 must be the warn beat, not a page: $(cat "$T/alerts")"

echo "fleet-propagate-hub-timeout.bh-7122-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
