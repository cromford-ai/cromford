#!/bin/bash
# tests/fly-pool-state-trace.bh-7431-test.sh — BH-7431 (BH-6896 S4 acceptance
# 2): the find-newer trace of the BH-6896 note (Appendix C) passes against the
# fly-pool lists. Every state/ path one pool tick writes has a catalog row
# (catalog/state-paths.json) or a line in catalog/lane-run-inputs.d/fly-pool.*.
#
#   R1  idle: 0 queued jobs, 0 machines
#   R2  reap: 2 tracked machines answer PR_CREATED; the reap pulls the
#       artifacts and destroys both machines
#   R3  spawn: 3 queued jobs, 0 machines; each job gets a machine
#   R4  mutation: the traces against a catalog copy with no remote-results
#       row and a fly-pool.rw copy with no remote-results line are rc 1 and
#       name state/remote-results; with no fly-cost row (a catalog row only)
#       rc 1 and name state/fly-cost
#
# Per state: reset the fixture, set every file under the scratch harness to an
# old mtime, stamp the marker, run the REAL bin/fly-pool.sh once, list every
# file newer than the marker (find -newer), normalise it with the note's
# Appendix C sed, then run bin/pool-state-paths-lint.sh --trace on the list.
# Each state also asserts the tick really reached that state (machine run
# count, destroy count, the reaped record), so a tick that dies early cannot
# pass on an empty trace.
#
# HOW IT DRIVES: the shape of tests/fly-pool-sibling-serial.bh-6374-test.sh
# (scratch_install_closure of bin/fly-pool.sh) with the note's Appendix A
# counting shim as fly, flyctl, gh, curl, ssh and sleep. No shim opens a
# network connection. The tick runs under env -i, with JOBS_URL empty (no
# worker: every row read falls back to its file). Tokens are tok-fixture-*,
# the box address is RFC 5737 (192.0.2.10), and the App key is a throwaway
# key made here.
#
# What the fixtures do not reach (as in the note, section 1 "Trace
# confirmation"): the death park, a malformed entry, .snapmt, the HOLD and
# After: markers, .defer-to-human, _spawn-hold, the hold cache, build notes,
# preplan files, the deploy snapshot, state/quota, pool-tailnet, the sibling
# clock and the owner-box ssh relay. tests/pool-state-paths.bh-7431-test.sh
# checks those through the source scan of bin/fly-pool.sh instead.
#
# Run from anywhere: tests/fly-pool-state-trace.bh-7431-test.sh  (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/pool-state-paths-lint.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
for c in jq openssl find; do command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c missing"; exit 0; }; done

P=project-5; SLUG=example-org/project-5
H="$T/h"; SH="$T/shims"
POOL="$H/state/fly-pool/$P"; QD="$H/state/build-queue/$P"; PD="$H/state/pool/$P"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$POOL" "$QD" "$H/state/remote-results/$P" "$PD" "$H/builds" \
         "$SH" "$T/tmp" "$T/home" || exit 1

# --- the fixture harness (the note's Appendix B setup.sh) ---------------------
TV="FLY_API_TOKEN_$(echo "$P" | tr '[:lower:].-' '[:upper:]__')"
printf '%s=tok-fixture-fly\n' "$TV" > "$H/env/fly.env"
printf 'GH_TOKEN=tok-fixture-gh\n' > "$H/env/global.env"
printf 'REPO_SLUG=%s\n' "$SLUG" > "$H/env/$P.env"
printf '%s %s - - 9 box-fixture 192.0.2.10\n' "$P" "$SLUG" > "$H/fleet.conf"
# A throwaway App key: the hub is armed for App tokens (fixture, never a real App).
openssl genrsa -out "$H/env/github-app.pem" 2048 2>/dev/null || { echo "openssl genrsa failed"; exit 1; }
cp "$H/env/github-app.pem" "$H/env/github-app-builders.pem"
printf 'GH_APP_ID=1\nGH_APP_INSTALLATION_example-org=12345\n' > "$H/env/github-app.env"
cp "$H/env/github-app.env" "$H/env/github-app-builders.env"
: > "$H/flags/fly-pool-$P"
printf 'pool-%s\n' "$P" > "$H/flags/fly-pool-app-$P"
printf '{"app":"pool-%s"}\n' "$P" > "$H/state/fly/$P.json"
printf 'registry.fly.io/pool-%s:deploy-01\n' "$P" > "$H/state/fly/$P.image"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure install of bin/jobs-client.sh failed"
for s in alert-line.sh beat.sh fly-envbundle.sh gh-token.sh pool-cap.sh sibling-serial.sh; do
  [ -f "$H/bin/$s" ] || scratch_install_closure "bin/$s" "$H" >/dev/null 2>&1 || bad "closure install of bin/$s failed"
done
chmod +x "$H"/bin/*.sh 2>/dev/null

# --- the counting shim (the note's Appendix A, verbatim in behaviour) -------
cat > "$SH/countshim" <<'SHIM'
#!/bin/bash
tool=$(basename "$0")
: "${BH_CALLS:?BH_CALLS unset}"
log() { printf '%s\t%s\t%s\n' "$tool" "$1" "$2" >> "$BH_CALLS"; }
case "$tool" in
  sleep)
    log sleep "${1:-0}"; exit 0 ;;
  fly|flyctl)
    case "$*" in
      *"machines list"*)
        log "machines list" "-"
        ids=$(for f in "$BH_POOLDIR"/*.json; do [ -f "$f" ] && jq -r .machine "$f"; done)
        if [ -z "$ids" ]; then echo '[]'; else
          printf '%s\n' $ids | jq -R '{id:.,state:"started",config:{image:"registry.fly.io/fixture:deploy-01"}}' | jq -s .; fi ;;
      *"machine status"*) log "machine status" "-"; echo "State: started" ;;
      *"machine run"*)
        log "machine run" "-"
        n=$(grep -c 'machine run' "$BH_CALLS"); printf 'Machine ID: %014x\n' "$((0xabc0000000000 + n))" ;;
      *"machine destroy"*) log "machine destroy" "-" ;;
      *"ssh sftp"*) log "ssh sftp" "-" ;;
      *"ssh console"*)
        all="$*"; c="${all##*-C }"; c="${c//\\/}"
        case "$c" in
          *"head -1 /run/harness/RESULT"*)
            log "ssh console" "read-result"
            m="${all##*--machine }"; m="${m%% *}"
            if grep -qx "$m" "$BH_DONE" 2>/dev/null; then
              printf 'PR_CREATED https://github.com/%s/pull/101\nBUILD_DIR: /data/harness/builds/fixture-build\n' "$BH_SLUG"; fi ;;
          *"base64 -w0"*) log "ssh console" "pull-artifact"; printf 'Zml4dHVyZSBhcnRpZmFjdAo=' ;;
          *"base64 -d"*) log "ssh console" "put-file" ;;
          *) log "ssh console" "exec" ;;
        esac ;;
      *) log "other" "$1 $2" ;;
    esac
    exit 0 ;;
  gh)
    path=""; for a in "$@"; do case "$a" in repos/*|/repos/*|orgs/*|user*|app/*|installation*) path="$a";; esac; done
    log "${1:-} ${2:-}" "${path:-${3:-}}"
    case "${1:-} ${2:-}" in
      "auth status"|"auth token") echo "tok-fixture-gh"; exit 0 ;;
    esac
    hdr=0; for a in "$@"; do [ "$a" = -i ] && hdr=1; done
    case "$path" in
      */branches/*) code=404; body='{"message":"Branch not found"}' ;;
      */pulls*) code=200; body='[]' ;;
      */issues/*/comments*) code=200; body='[]' ;;
      */issues/*) n="${path##*/issues/}"; n="${n%%[!0-9]*}"
                  code=200; body="{\"number\":${n:-1},\"state\":\"open\",\"body\":\"\",\"labels\":[{\"name\":\"ai-build\"}]}" ;;
      */issues\?*|*/issues) code=200
                  body=$(for n in 8001 8002 8003 9001 9002; do printf '{"number":%s,"updated_at":"2026-10-15T00:00:00Z","comments":0,"state":"open","labels":[{"name":"ai-build"}]}\n' "$n"; done | jq -sc .) ;;
      *) code=200; body="{\"full_name\":\"${BH_SLUG}\",\"permissions\":{\"pull\":true}}" ;;
    esac
    [ "$hdr" = 1 ] && printf 'HTTP/2.0 %s OK\r\n\r\n' "$code"
    printf '%s\n' "$body"
    [ "$code" = 200 ] ; exit $? ;;
  curl)
    url=""; for a in "$@"; do case "$a" in http*) url="$a";; esac; done
    host="${url#*://}"; host="${host%%/*}"
    log "${host:-none}" "$(printf '%s' "${url#*://*/}" | cut -c1-60)"
    case "$url" in
      *api.github.com/app/installations/*/access_tokens)
        printf '{"token":"tok-fixture-app","expires_at":"%s"}' "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" ;;
      *api.github.com/app/installations) printf '[{"id":12345,"account":{"login":"example-org"}}]' ;;
      *api.github.com/rate_limit) printf '{"rate":{"remaining":4999,"limit":5000}}' ;;
      *) printf '{}' ;;
    esac
    exit 0 ;;
  ssh)
    log "box-ssh" "$(for a in "$@"; do case "$a" in root@*) printf '%s' "$a";; esac; done)"
    printf '===GLOBAL===\nCLAUDE_CODE_OAUTH_TOKEN=tok-fixture-oauth\nGH_TOKEN=tok-fixture-gh\n===PROJECT===\nFIXTURE_VAR=1\n'
    exit 0 ;;
esac
SHIM
chmod +x "$SH/countshim"
for t in fly flyctl gh curl ssh sleep; do ln -sf countshim "$SH/$t"; done
# Proof the shim is what answers: no network, a canned body, rc 0.
: > "$T/calls.proof"
OUT=$(BH_CALLS="$T/calls.proof" PATH="$SH:$PATH" curl -s https://example.com); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = '{}' ] && grep -q 'example.com' "$T/calls.proof" \
  && ok "the curl shim answers locally and logs the call" || bad "curl shim rc=$RC out=$OUT"

# --- one state: reset, stamp, tick, trace (the note's run.sh + trace.sh) ----
# trace_state <idle|reap|spawn> — leaves $T/trace.<st>.txt (normalised) and
# $T/calls.<st>.tsv.
trace_state() {
  local st="$1" i mid key now
  for i in "$POOL" "$QD" "$PD" "$H/builds" "$H/state/remote-results/$P" "$H/locks" "$H/plans"; do
    [ -e "$i" ] && scratch_rm "$i"
  done
  rm -f "$H"/flags/alerted-* 2>/dev/null
  mkdir -p "$POOL" "$QD" "$PD" "$H/builds" "$H/state/remote-results/$P" "$H/locks" "$H/plans"
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/done-machines"
  local nowiso; nowiso=$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)
  case "$st" in
    idle) ;;
    reap)
      for i in 1 2; do
        mid=$(printf 'd0ne%010x' "$i"); key="FX-$((900+i))"
        jq -nc --arg m "$mid" --arg k "$key" --arg t "$((9000+i))" --arg s "$nowiso" \
          '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:$s}' > "$POOL/$mid.json"
        echo "$mid" >> "$T/done-machines"
      done ;;
    spawn)
      for i in 1 2 3; do
        key="FX-$((800+i))"
        jq -nc --arg k "$key" --arg t "$((8000+i))" --arg e "$nowiso" \
          '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:$e}' > "$QD/$key.json"
      done ;;
  esac
  # Every fixture file is older than the marker, so find -newer lists only
  # what the tick wrote. No sleep: the mtimes are set, not waited for.
  now=$(date +%s)
  find "$H" -exec touch -h -d "@$((now - 120))" {} + 2>/dev/null
  touch -d "@$((now - 60))" "$T/mark"
  : > "$T/calls.$st.tsv"
  env -i HOME="$T/home" TMPDIR="$T/tmp" BH_CALLS="$T/calls.$st.tsv" BH_POOLDIR="$POOL" \
      BH_DONE="$T/done-machines" BH_SLUG="$SLUG" JOBS_URL= HARNESS_TEST_SANDBOX=1 \
      PATH="$SH:/usr/local/bin:/usr/bin:/bin" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      FLY_BIN_DIR="$SH" \
      bash "$DIR/bin/fly-pool.sh" "$P" >/dev/null 2>"$T/stderr.$st"
  echo "$?" > "$T/rc.$st"
  # The note's Appendix C normalisation, verbatim.
  find "$H" -newer "$T/mark" -type f ! -path "$H/bin/*" | sed "s|^$H/||" \
    | sed -E "s|/$P/|/<p>/|g; s|-$P-|-<p>-|g; s|\.$P$|.<p>|; s|/$P\.|/<p>.|; s|FX-[0-9]+|<KEY>|g; s|[0-9a-f]{14}|<machine>|g; s|[0-9]{12}|<ts>|g; s|[0-9]{8}|<date>|g" \
    | sed -E 's#example-org-[A-Za-z0-9.-]+\.(json|lock)#<owner>-<repo>.\1#; s#(cromford|harness-console|project-5)#<p>#g; s#<p>-console#<p>#; s#gh-calls/<date>[0-9]{2}\.log#gh-calls/<date><hh>.log#; s#gh-rest-ledger/[0-9-]+T[0-9]{2}\.tsv#gh-rest-ledger/<day>T<hh>.tsv#' \
    | LC_ALL=C sort -u > "$T/trace.$st.txt"
}
calls() { grep -c "$2" "$T/calls.$1.tsv" 2>/dev/null; }

# lint_trace <st> [catalog] — the lint over one state's trace.
lint_trace() {
  if [ -n "${2:-}" ]; then OUT=$("$LINT" --trace "$T/trace.$1.txt" --catalog "$2" 2>&1)
  else OUT=$("$LINT" --trace "$T/trace.$1.txt" 2>&1); fi
  RC=$?
}

for st in idle reap spawn; do
  echo "trace: $st"
  trace_state "$st"
  NS=$(grep -c '^state/' "$T/trace.$st.txt")
  echo "    tick rc=$(cat "$T/rc.$st"), $(grep -c . "$T/trace.$st.txt") paths traced, $NS under state/"
  grep '^state/' "$T/trace.$st.txt" | sed 's/^/    traced: /'
  case "$st" in
    idle)
      [ "$(calls idle 'machine run')" = 0 ] && [ "$(calls idle 'machine destroy')" = 0 ] \
        && ok "R1 idle: no machine run, no destroy" || bad "R1 idle calls: $(cat "$T/calls.idle.tsv")"
      grep -q 'fly-pool.log' "$T/trace.idle.txt" && ok "R1 idle: the tick ran (logs/fly-pool.log written)" \
        || bad "R1 idle: the tick wrote no log: $(cat "$T/stderr.idle")" ;;
    reap)
      [ "$(calls reap 'machine destroy')" -ge 2 ] && ok "R2 reap: both machines destroyed" \
        || bad "R2 reap: destroy calls $(calls reap 'machine destroy'): $(tail -5 "$H/logs/fly-pool.log")"
      [ "$(calls reap 'pull-artifact')" -ge 1 ] && ok "R2 reap: artifacts pulled ($(calls reap 'pull-artifact'))" \
        || bad "R2 reap: no artifact pulled: $(tail -5 "$H/logs/fly-pool.log")"
      grep -q '^builds/pool-<p>-<KEY>-' "$T/trace.reap.txt" && ok "R2 reap: a build record written under builds/" \
        || bad "R2 reap: no build record in the trace" ;;
    spawn)
      [ "$(calls spawn 'machine run')" = 3 ] && ok "R3 spawn: 3 machine run calls" \
        || bad "R3 spawn: machine run calls $(calls spawn 'machine run'): $(tail -8 "$H/logs/fly-pool.log")"
      grep -qxF 'state/fly-pool/<p>/<machine>.json' "$T/trace.spawn.txt" && ok "R3 spawn: machine records written" \
        || bad "R3 spawn: no machine record in the trace" ;;
  esac
  [ "$NS" -gt 0 ] && ok "R $st: the trace holds $NS state/ paths" || bad "R $st: no state/ path traced"
  lint_trace "$st"
  [ "$RC" = 0 ] && [ "$(tail -n 1 <<<"$OUT")" = "pool-state-paths: unclassified=0 checked=$NS" ] \
    && ok "R $st: lint --trace rc 0, unclassified=0 checked=$NS" || bad "R $st: lint rc=$RC :: $OUT"
done

# --- R4: mutation -----------------------------------------------------------
# remote-results has a catalog row AND a fly-pool.rw line, so the mutation
# removes both (a copy of each); fly-cost has a catalog row only (NOT CARRIED),
# so removing the row alone must fire. Each mutated path must be in the trace,
# or the case proves nothing: the case fails rather than add the path by hand.
echo "R4: mutation, a traced path with no class"
cat "$T"/trace.{idle,reap,spawn}.txt | LC_ALL=C sort -u > "$T/trace.all.txt"
mkdir -p "$T/mani-mut"
cp "$DIR"/catalog/lane-run-inputs.d/fly-pool.* "$T/mani-mut/" || bad "R4: could not copy the fly-pool lists"
sed -i '/^state\/remote-results\//d' "$T/mani-mut/fly-pool.rw"
grep -q '^state/remote-results/' "$T/mani-mut"/fly-pool.* && bad "R4: the remote-results line is still in the list copy"
# mut <path> <manifest-dir> — the lint over the whole trace, a catalog copy
# with no <path> row and the lists in <manifest-dir>; sets OUT and RC.
mut() {
  jq --arg p "$1" '.paths |= map(select(.path != $p))' "$DIR/catalog/state-paths.json" > "$T/cat-mut.json" \
    || { bad "R4: could not write the mutated catalog"; return; }
  OUT=$("$LINT" --trace "$T/trace.all.txt" --catalog "$T/cat-mut.json" --manifests "$2" 2>&1); RC=$?
}
for p in remote-results fly-cost; do
  grep -q "^state/$p/" "$T/trace.all.txt" || { bad "R4: no fixture state wrote state/$p, so the mutation proves nothing"; continue; }
done
mut remote-results "$T/mani-mut"
[ "$RC" = 1 ] && grep -q '^UNCLASSIFIED state/remote-results (' <<<"$OUT" \
  && ok "R4 no remote-results row and no fly-pool.rw line: rc 1, named" || bad "R4 remote-results rc=$RC :: $OUT"
mut remote-results "$DIR/catalog/lane-run-inputs.d"
[ "$RC" = 0 ] && ok "R4 no remote-results row but the fly-pool.rw line: rc 0 (the list classifies it)" \
  || bad "R4 remote-results row only rc=$RC :: $OUT"
mut fly-cost "$DIR/catalog/lane-run-inputs.d"
[ "$RC" = 1 ] && grep -q '^UNCLASSIFIED state/fly-cost (' <<<"$OUT" \
  && ok "R4 no fly-cost row (NOT CARRIED, row only): rc 1, named" || bad "R4 fly-cost rc=$RC :: $OUT"
OUT=$("$LINT" --trace "$T/trace.all.txt" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "R4 the same list against the real catalog and lists is rc 0" || bad "R4 real catalog rc=$RC :: $OUT"

echo
echo "fly-pool-state-trace.bh-7431: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
