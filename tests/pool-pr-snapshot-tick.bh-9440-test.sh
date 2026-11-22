#!/bin/bash
# tests/pool-pr-snapshot-tick.bh-9440-test.sh — BH-9440 C1, from the production
# entry point: a bin/fly-pool.sh tick runs `bin/overlap-guard.sh --refresh
# <project>`, so the hub PR snapshot that sibling-serial reads exists.
#
#   K1  a tick with a queued row writes state/overlap-guard/<p>-prs.json with a
#       non-harness PR (author client-dev) and logs `PR snapshot: REFRESH ... ok`
#   K2  the next tick inside OVERLAP_PR_CACHE_SECS makes no refresh
#   K3  a tick with no queued row makes no refresh
#   K4  a failed read keeps the old snapshot, logs `REFRESH ... failed`, and
#       writes ONE alert line over two ticks
#
# The tests/pool-after-release.bh-5967-test.sh scaffold (fake flyctl, fake gh,
# recording jobs client); the REST snapshot reads go to
# og_fake_gh below. No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# og_fake_gh <dir> — write a fake `gh` into <dir>/fakebin that answers the REST
# seam's `gh api -i -X GET <path> ...` from files under <dir>/gh/, logs every call
# to <dir>/gh.log, and answers 502 while <dir>/gh-fail exists. No network.
og_fake_gh() {
  local d="$1"
  mkdir -p "$d/fakebin" "$d/gh"; : > "$d/gh.log"
  cat > "$d/fakebin/gh" <<FGH
#!/bin/bash
echo "\$*" >> "$d/gh.log"
[ -e "$d/gh-fail" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{"message":"bad gateway"}\n'; exit 1; }
path=""; page=1
for a in "\$@"; do case "\$a" in repos/*) path="\$a" ;; page=*) page="\${a#page=}" ;; esac; done
case "\$path" in
  repos/*/*/pulls) f="$d/gh/pulls.\$page" ;;
  repos/*/*/pulls/*/files) n="\${path%/files}"; n="\${n##*/}"; f="$d/gh/files.\$n" ;;
  repos/*/*/commits) f="$d/gh/commits" ;;
  repos/*/*/commits/*) f="$d/gh/commit.\${path##*/}" ;;
  *) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
printf 'HTTP/1.1 200 OK\r\n\r\n'
if [ -s "\$f" ]; then cat "\$f"; else echo '[]'; fi
exit 0
FGH
  chmod +x "$d/fakebin/gh"
}
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
clear_boundary 86400 60
unset GH_TOKEN GITHUB_TOKEN
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The jobs client RECORDS the queue writes: the row is the thing under test.
# Executed (a setting read) it answers nothing, so every setting falls back.
cat > "$H/bin/jobs-client.sh" <<JC
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
queue_put()  { printf 'put %s\n' "\$*" >> "$T/q.log"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/q.log"; return 0; }
JC

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
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=fixture-fly-token FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}
# gh: the repo is visible; ticket/bh-890's open-PR list is $T/pr-890 (open,
# none or broken); ticket/bh-1016 has no PR; the hold read finds an ai-build
# issue with no comments.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/1016"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"TS fixture","body":""}'; exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'; exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"ticket/bh-890"* ]]; then
    case "\$(cat "$T/pr-890" 2>/dev/null)" in
      open)   printf 'HTTP/1.1 200 OK\\n\\n[{"number":890,"html_url":"https://github.com/example-org/project-5/pull/890"}]\\n' ;;
      broken) printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n' ;;
      *)      printf 'HTTP/1.1 200 OK\\n\\n[]\\n' ;;
    esac
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
exit 0
GH
chmod +x "$T/fakebin/gh"

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"
  return 0
}
# machine_json <mid> <deferrals> — a live machine for BH-1016 whose RESULT is read.
machine_json() {
  jq -nc --arg m "$1" --argjson d "$2" \
    '{machine:$m,key:"BH-1016",ticket_id:"1016",attempt:1,deferrals:$d,deaths:0,spawned_at:"2026-10-10T13:20:00Z"}' \
    > "$H/state/fly-pool/project-5/$1.json"
}
QF="$H/state/build-queue/project-5/BH-1016.json"
qf() { jq -r "$1" "$QF" 2>/dev/null || echo no-queue-file; }
spawned() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null; }
# gh_rest bounds each read as `timeout -k 5 <s> gh ...` (POOL_GH_READ_TIMEOUT_S):
# this fake timeout drops the options and the duration, then runs the command.
printf '#!/bin/bash\nwhile [ "${1#-}" != "$1" ]; do case "$1" in -k|-s) shift 2 ;; *) shift ;; esac; done\nshift; exec "$@"\n' > "$T/fakebin/timeout"
had_tok=0; [ -e "$H/bin/lib/gh-repo-token.sh" ] && had_tok=1
for L in bin/overlap-guard.sh bin/lib/gh-rest-list.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
# No credential ladder this suite did not already have: it would look for real
# tokens on this box.
[ "$had_tok" = 1 ] || rm -f "$H/bin/lib/gh-repo-token.sh"
# The REST snapshot paths go to the fixture fake; every other gh call to the
# bh-5967 fake.
og_fake_gh "$T/og"
mv "$T/fakebin/gh" "$T/fakebin/gh-5967"
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    repos/example-org/project-5/pulls|repos/example-org/project-5/pulls/*/files|repos/example-org/project-5/commits|repos/example-org/project-5/commits/*)
      exec "$T/og/fakebin/gh" "\$@" ;;
  esac
done
exec "$T/fakebin/gh-5967" "\$@"
GH
chmod +x "$T/fakebin/gh"
echo none > "$T/pr-890"
CF="$H/state/overlap-guard/project-5-prs.json"
jq -nc '[{number:77, html_url:"https://github.com/example-org/project-5/pull/77", draft:false,
          user:{login:"client-dev"}, head:{ref:"client/fix", sha:"abcdef1"}}]' > "$T/og/gh/pulls.1"
printf '[{"filename":"src/a.ts"}]\n' > "$T/og/gh/files.77"
q1016() { jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-10T13:00:00Z"}' > "$QF"; }
pool() { run_pool GH_ETAG=0; }

# ── K1 ──────────────────────────────────────────────────────────────────────
reset_state; write_fly_stub ""; q1016
pool
grep -q 'PR snapshot: REFRESH project-5 ok prs=1 main=0' "$H/logs/fly-pool.log" && ok \
  || bad "K1: THE GAP: the tick refreshes the PR snapshot: $(grep -i 'snapshot\|refresh' "$H/logs/fly-pool.log" | tail -2)"
[ "$(jq -r '.[0].author + " " + .[0].files[0].path' "$CF" 2>/dev/null)" = "client-dev src/a.ts" ] && ok \
  || bad "K1: the snapshot holds the client's PR #77: $(cat "$CF" 2>/dev/null || echo none)"

# ── K2: inside the cache window, no second refresh ─────────────────────────
: > "$T/og/gh.log"; q1016
pool
grep -q 'PR snapshot:' "$H/logs/fly-pool.log" && bad "K2: a fresh snapshot is not read again: $(grep 'PR snapshot' "$H/logs/fly-pool.log")" || ok
grep -q 'project-5/pulls' "$T/og/gh.log" && bad "K2: no PR list read inside the window" || ok

# ── K3: no queued row, no refresh ───────────────────────────────────────────
reset_state; write_fly_stub ""; touch -d '10 minutes ago' "$CF"; : > "$T/og/gh.log"
pool
[ -s "$T/og/gh.log" ] && bad "K3: no refresh with nothing queued: $(head -2 "$T/og/gh.log")" || ok

# ── K4: a failed read keeps the snapshot, one alert over two ticks ─────────
reset_state; write_fly_stub ""; q1016; touch -d '10 minutes ago' "$CF"; cp "$CF" "$T/before.json"
rm -f "$H/state/overlap-guard/project-5.alerted-"*
touch "$T/og/gh-fail"
pool
grep -q 'PR snapshot: REFRESH project-5 failed' "$H/logs/fly-pool.log" && ok || bad "K4: the failed refresh is logged: $(grep 'PR snapshot' "$H/logs/fly-pool.log")"
touch -d '10 minutes ago' "$CF"; q1016
pool
cmp -s "$CF" "$T/before.json" && ok || bad "K4: the old snapshot is kept"
[ "$(grep -c 'snapshot refresh failed' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "K4: one alert over two ticks: $(grep 'snapshot refresh' "$H/logs/ALERTS.log")"
rm -f "$T/og/gh-fail"

[ -z "${GH_TOKEN:-}" ] && ok || bad "no token in the test"
echo "pool-pr-snapshot-tick.bh-9440: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
