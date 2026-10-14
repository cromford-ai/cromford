#!/bin/bash
# tests/deploy-kind.bh-3387-test.sh — a project with no GitHub production
# deployment must not page "DEPLOY-VERIFY FAILED" on every merge.
#
# THE INCIDENT (2026-09-28). cromford reaches its boxes through
# harness-sync/update-runners and has no GitHub "Production" deployment, yet
# every merge sent bin/deploy-request.sh into bin/deploy-verify.sh, which polled
# repos/<slug>/deployments for 20 minutes, found nothing and paged
# deployfail:cromford:<sha> (79ef9558, b58a59ba, 90953299).
#
# THE FIX. A settings row, deploy.<project>.kind = github-deployment | none |
# smoke-only, read by bin/lib/deploy-kind.sh before any deployments call:
#   none        -> one SKIP line, no gh call, no alert; stale deployfail pages close
#   smoke-only  -> the prod smoke curl only, never the deployments poll
#   no row / outage / unknown value -> today's behaviour, unchanged
#
# Driven end to end through the real bin/deploy-verify.sh, bin/deploy-request.sh
# and bin/deploy-kind-resolve.sh with gh, curl, beat.sh and bin/jobs-client.sh
# stubbed. The new files are copied only when present, so at the merge base the
# suite goes red on its assertions instead of aborting on a missing cp.
# Run from anywhere: bash tests/deploy-kind.bh-3387-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SKIPLINE='deploy-verify SKIP: tproj has no GitHub production deployment (deploy.kind=none)'

# ── the scratch harness: real scripts, stubbed edges ─────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$T/fakebin" "$T/build"
cp "$DIR/bin/deploy-verify.sh" "$DIR/bin/deploy-request.sh" "$DIR/bin/prod-url.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
[ -f "$DIR/bin/lib/deploy-kind.sh" ] && cp "$DIR/bin/lib/deploy-kind.sh" "$H/bin/lib/"
[ -f "$DIR/bin/deploy-kind-resolve.sh" ] && cp "$DIR/bin/deploy-kind-resolve.sh" "$H/bin/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj https://tproj.example - 2 box-t 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
printf 'DEPLOY_HOOK_URL=https://hooks.example/deploy\nDEPLOY_HOOK_WAIT=0\n' > "$H/env/tproj.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> '"$T"'/beat.txt\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# The settings client: setting_get answers from $T/kind.
#   absent file -> rc 2 (no row)   "OUTAGE" -> rc 1   anything else -> rc 0, the value
# It records every key it was asked for, so the tests can pin the key's shape.
cat > "$H/bin/jobs-client.sh" <<EOF
setting_get() {
  printf '%s\n' "\$1" >> "$T/keys.txt"
  [ -f "$T/kind" ] || return 2
  local v; v=\$(cat "$T/kind")
  [ "\$v" = OUTAGE ] && return 1
  printf '%s' "\$v"
}
EOF

# gh: $T/mode decides what the deployments API answers (404 = unreadable).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
MODE=\$(cat "$T/mode" 2>/dev/null || echo ok)
case "\$*" in
  *deployments/*statuses*) cat "$T/dstate" 2>/dev/null || echo success ;;
  *deployments*)
    case "\$MODE" in
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      *)   echo '[{"id":77,"environment":"production","created_at":"2026-09-14T03:00:00Z"}]' ;;
    esac ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# curl: the console alerts API, the deploy hook, and the prod smoke GET.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl.txt"
case "\$*" in
  */api/alerts/open*) cat "$T/open.json" 2>/dev/null; exit 0 ;;
  */api/alerts/resolve*)
    while [ "\$#" -gt 0 ]; do [ "\$1" = -d ] && { printf '%s\n' "\$2" >> "$T/resolve.txt"; break; }; shift; done
    echo '{"ok":true}'; exit 0 ;;
  *"-X POST"*) printf '%s\n' "\$*" >> "$T/hook.txt"; exit 0 ;;
esac
printf '%s\n' "\$*" >> "$T/smoke.txt"
cat "$T/code" 2>/dev/null || echo 200
exit 0
EOF
chmod +x "$T/fakebin/curl"

RESET() {
  : > "$T/build/pipeline.log"; : > "$H/logs/ALERTS.log"; : > "$T/hook.txt"; : > "$T/gh.txt"
  : > "$T/beat.txt"; : > "$T/smoke.txt"; : > "$T/curl.txt"; : > "$T/resolve.txt"; : > "$T/keys.txt"
  rm -f "$T/kind" "$T/dv-launched" "$T/resolver-launched"
}
KIND() { if [ -n "$1" ]; then printf '%s' "$1" > "$T/kind"; else rm -f "$T/kind"; fi; }
DV() { # DV -> rc of the real deploy-verify; stderr kept in $T/dv.err
  ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" CONSOLE_URL="" HARNESS_SECRET="" \
      bash "$H/bin/deploy-verify.sh" tproj o/tproj deadbeefdeadbeef "$T/build" >/dev/null 2>"$T/dv.err" )
}
PIPE() { cat "$T/build/pipeline.log"; }
DEPLOYS() { grep -c 'deployments' "$T/gh.txt"; }

# ============================================================================
# 1. kind=none: one SKIP line, no deployments call, no ALERTS line, no beat.
# ============================================================================
RESET; KIND none; echo 404 > "$T/mode"; echo 200 > "$T/code"
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "1: kind=none must exit 0 (rc=$RC)"
grep -qF "$SKIPLINE" <<<"$(PIPE)" && ok || bad "1: kind=none must log the SKIP line (got: $(PIPE))"
[ "$(grep -c 'SKIP' "$T/build/pipeline.log")" = 1 ] && ok || bad "1: kind=none must log exactly one SKIP line"
[ "$(DEPLOYS)" = 0 ] && ok || bad "1: kind=none made a deployments API call ($(cat "$T/gh.txt"))"
[ -s "$H/logs/ALERTS.log" ] && bad "1: kind=none must never write ALERTS.log ($(cat "$H/logs/ALERTS.log"))" || ok
[ -s "$T/beat.txt" ] && bad "1: kind=none must never beat ($(cat "$T/beat.txt"))" || ok
[ -s "$T/smoke.txt" ] && bad "1: kind=none must not smoke-curl prod" || ok
grep -qx 'deploy.tproj.kind' "$T/keys.txt" && ok || bad "1: the row read must be deploy.tproj.kind (asked: $(cat "$T/keys.txt"))"

# ...and a mixed-case project name reads the lowercase key (D17).
RESET; KIND none
( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" CONSOLE_URL="" HARNESS_SECRET="" \
    bash -c ". '$H/bin/lib/deploy-kind.sh' && deploy_kind TProj" > "$T/out.txt" 2>/dev/null ); RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out.txt")" = none ] && ok || bad "1: deploy_kind TProj must answer none (rc=$RC, out=$(cat "$T/out.txt"))"
grep -qx 'deploy.tproj.kind' "$T/keys.txt" && ok || bad "1: deploy_kind must lowercase the project (asked: $(cat "$T/keys.txt"))"

# ============================================================================
# 2. kind=smoke-only, prod 200: the smoke curl only — no deployments poll, no hook.
# ============================================================================
RESET; KIND smoke-only; echo 404 > "$T/mode"; echo 200 > "$T/code"
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "2: smoke-only on a healthy prod must exit 0 (rc=$RC)"
[ "$(DEPLOYS)" = 0 ] && ok || bad "2: kind=smoke-only probed deployments ($(cat "$T/gh.txt"))"
grep -q 'smoke-only (deploy.kind=smoke-only)' <<<"$(PIPE)" && ok || bad "2: the smoke-only branch must name deploy.kind=smoke-only (got: $(PIPE))"
grep -q 'prod answers 200' <<<"$(PIPE)" && ok || bad "2: the smoke result must be recorded (got: $(PIPE))"
grep -q 'deployments unreadable' <<<"$(PIPE)" && bad "2: a declared smoke-only project must not claim the API was unreadable (got: $(PIPE))" || ok
[ -s "$T/smoke.txt" ] && ok || bad "2: smoke-only must actually curl prod"
[ -s "$T/hook.txt" ] && bad "2: smoke-only must not fire the deploy hook ($(cat "$T/hook.txt"))" || ok
grep -q 'SKIP' <<<"$(PIPE)" && bad "2: smoke-only is not a skip" || ok

# ============================================================================
# 3. kind=smoke-only, prod 503: still a FAIL, and still no deployments call.
# ============================================================================
RESET; KIND smoke-only; echo 404 > "$T/mode"; echo 503 > "$T/code"
DV; RC=$?
[ "$RC" = 1 ] && ok || bad "3: smoke-only must FAIL on a dead prod (rc=$RC)"
grep -q 'DEPLOY-VERIFY FAILED' "$H/logs/ALERTS.log" && ok || bad "3: a dead prod must write one ALERTS line"
[ "$(DEPLOYS)" = 0 ] && ok || bad "3: kind=smoke-only probed deployments on the FAIL path ($(cat "$T/gh.txt"))"
echo 200 > "$T/code"

# ============================================================================
# 4. No row, API readable, deployment succeeded: today's path, unchanged.
# ============================================================================
RESET; KIND ""; echo ok > "$T/mode"; echo success > "$T/dstate"
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "4: a missing row with a successful deploy must verify (rc=$RC)"
[ "$(DEPLOYS)" -gt 0 ] && ok || bad "4: a missing row must keep the deployments poll"
grep -q 'deploy-verify OK' <<<"$(PIPE)" && ok || bad "4: a missing row must reach deploy-verify OK (got: $(PIPE))"
grep -q 'SKIP' <<<"$(PIPE)" && bad "4: a missing row must never skip" || ok

# ============================================================================
# 5. An outage and an unknown value both keep today's path (D9, D11).
# ============================================================================
for V in OUTAGE bogus github-deployment; do
  RESET; KIND "$V"; echo ok > "$T/mode"; echo success > "$T/dstate"
  DV; RC=$?
  [ "$RC" = 0 ] && ok || bad "5[$V]: must verify as today (rc=$RC)"
  [ "$(DEPLOYS)" -gt 0 ] && ok || bad "5[$V]: must keep the deployments poll"
  grep -q 'deploy-verify OK' <<<"$(PIPE)" && ok || bad "5[$V]: must reach deploy-verify OK (got: $(PIPE))"
  grep -q 'SKIP' <<<"$(PIPE)" && bad "5[$V]: must never skip" || ok
  grep -q 'smoke-only' <<<"$(PIPE)" && bad "5[$V]: must not take the smoke-only branch" || ok
done
RESET; KIND bogus; echo ok > "$T/mode"; echo success > "$T/dstate"; DV
grep -q "bogus" "$T/dv.err" && ok || bad "5: an unknown deploy.kind value must be named once on stderr (got: $(cat "$T/dv.err"))"

# ============================================================================
# deploy-request: a second harness whose deploy-verify / resolver are markers.
# ============================================================================
H2="$T/h2"
mkdir -p "$H2/bin/lib" "$H2/logs" "$H2/env"
cp "$DIR/bin/deploy-request.sh" "$H2/bin/"
[ -f "$DIR/bin/lib/deploy-kind.sh" ] && cp "$DIR/bin/lib/deploy-kind.sh" "$H2/bin/lib/"
# The STUB client written above, copied by content so jobs-client-modules.bh-1194's
# fixture rule does not read it as a copy of the real bin/jobs-client.sh.
cat "$H/bin/jobs-client.sh" > "$H2/bin/jobs-client.sh"
: > "$H2/env/global.env"; : > "$H2/env/tproj.env"
printf '#!/bin/bash\ntouch %s/dv-launched\nexit 0\n' "$T" > "$H2/bin/deploy-verify.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > %s/resolver-launched\nexit 0\n' "$T" > "$H2/bin/deploy-kind-resolve.sh"
chmod +x "$H2/bin/"*.sh
DR() { # DR <inline 0|1> -> rc of the real deploy-request; stdout in $T/dr.out
  ( HARNESS="$H2" MC_DV_INLINE="$1" \
      bash "$H2/bin/deploy-request.sh" tproj o/tproj deadbeefdeadbeef "$T/build" > "$T/dr.out" 2>/dev/null )
}
WAITFOR() { local i; for i in $(seq 1 50); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }

# 6. inline, kind=none: no verifier, the SKIP line on stdout and pipeline.log, resolver launched.
RESET; KIND none
DR 1; RC=$?
[ "$RC" = 0 ] && ok || bad "6: deploy-request kind=none must exit 0 (rc=$RC)"
sleep 0.3
[ -e "$T/dv-launched" ] && bad "6: kind=none must not launch deploy-verify" || ok
grep -qF "$SKIPLINE" "$T/dr.out" && ok || bad "6: the SKIP line must be on stdout for mc_dv_run (got: $(cat "$T/dr.out"))"
grep -qF "$SKIPLINE" <<<"$(PIPE)" && ok || bad "6: the SKIP line must be in pipeline.log (got: $(PIPE))"
WAITFOR "$T/resolver-launched" && ok || bad "6: kind=none must launch bin/deploy-kind-resolve.sh"
grep -qx 'tproj' "$T/resolver-launched" 2>/dev/null && ok || bad "6: the resolver must be given the project"

# 7. inline, no row: the verifier runs as today.
RESET; KIND ""
DR 1; RC=$?
[ -e "$T/dv-launched" ] && ok || bad "7: a missing row must still launch deploy-verify (rc=$RC)"
grep -q 'SKIP' <<<"$(PIPE)" && bad "7: a missing row must not skip" || ok

# 8. detached, kind=smoke-only: the verifier runs (it takes its own smoke branch).
RESET; KIND smoke-only
DR 0
WAITFOR "$T/dv-launched" && ok || bad "8: kind=smoke-only must still launch deploy-verify detached"
[ -e "$T/resolver-launched" ] && bad "8: smoke-only must not launch the resolver" || ok

# ============================================================================
# bin/deploy-kind-resolve.sh — closes exactly deployfail:<project>:* on kind=none.
# ============================================================================
cat > "$T/open.json" <<'EOF'
{"alerts":[
 {"id":11,"akey":"deployfail:tproj:aaa","line":"PROD DEPLOY problem after auto-merge"},
 {"id":12,"akey":"deployfail:tproj:bbb","line":"PROD DEPLOY problem after auto-merge"},
 {"id":13,"akey":"deployfail:tproj-x:ccc","line":"PROD DEPLOY problem"},
 {"id":14,"akey":"deployfail:project-3:ddd","line":"PROD DEPLOY problem"},
 {"id":15,"akey":"mq-lander:tproj:12","line":"Merge queue: #12"},
 {"id":16,"akey":"","line":"see deployfail:tproj:eee for context"}
]}
EOF
RES() { # RES [console-url] -> rc of the real resolver
  ( PATH="$T/fakebin:$PATH" HARNESS="$H" CONSOLE_URL="${1-https://console.example}" HARNESS_SECRET=s3cret \
      bash "$H/bin/deploy-kind-resolve.sh" tproj >/dev/null 2>&1 )
}

# 9. kind=none: one POST, ids 11 and 12 only, the reason verbatim.
RESET; KIND none
RES; RC=$?
[ "$RC" = 0 ] && ok || bad "9: the resolver must exit 0 (rc=$RC)"
[ "$(grep -c '/api/alerts/resolve' "$T/curl.txt")" = 1 ] && ok || bad "9: exactly one resolve POST (got: $(cat "$T/curl.txt"))"
IDS=$(jq -c '.ids | sort' "$T/resolve.txt" 2>/dev/null)
[ "$IDS" = '[11,12]' ] && ok || bad "9: only deployfail:tproj:* may close (ids=$IDS)"
[ "$(jq -r '.reason' "$T/resolve.txt" 2>/dev/null)" = 'not a deploying project' ] && ok \
  || bad "9: the reason must be 'not a deploying project' (got: $(cat "$T/resolve.txt"))"
grep -q 'resolved 2' "$H/logs/alerts-groom.log" 2>/dev/null && ok || bad "9: the run must log its count to alerts-groom.log"
# ...and it must be runnable a second time with nothing left open.
RESET; KIND none; printf '{"alerts":[]}' > "$T/open.json.empty"
cp "$T/open.json" "$T/open.json.full"; cp "$T/open.json.empty" "$T/open.json"
RES; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/resolve.txt" ] && ok || bad "9: nothing open must mean no POST (rc=$RC)"
cp "$T/open.json.full" "$T/open.json"

# 10. Any other kind: no POST at all.
for V in smoke-only github-deployment "" OUTAGE; do
  RESET; KIND "$V"
  RES; RC=$?
  [ "$RC" = 0 ] && ok || bad "10[${V:-missing}]: the resolver must exit 0 (rc=$RC)"
  [ -s "$T/resolve.txt" ] && bad "10[${V:-missing}]: must not resolve anything ($(cat "$T/resolve.txt"))" || ok
done

# 11. No console configured: rc 0, no curl at all.
RESET; KIND none
RES ""; RC=$?
[ "$RC" = 0 ] && ok || bad "11: an unconfigured console must exit 0 (rc=$RC)"
[ -s "$T/curl.txt" ] && bad "11: an unconfigured console must make no curl call ($(cat "$T/curl.txt"))" || ok

# ============================================================================
# 12. The seed: cromford is none, INSERT OR IGNORE, in the applied schema.
# ============================================================================
SEED=$(grep -A1 '^INSERT OR IGNORE INTO settings' "$DIR/worker/jobs/schema.sql" | grep -F "('deploy.cromford.kind','none',")
[ -n "$SEED" ] && ok || bad "12: worker/jobs/schema.sql must seed ('deploy.cromford.kind','none',…) under INSERT OR IGNORE INTO settings"

echo "deploy-kind.bh-3387-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
