#!/bin/bash
# tests/console-preview-fly.bh-8030-test.sh — BH-8030: the console preview
# lane's build and Pages upload run on a Fly pool machine, not on the hub,
# behind the settings row lane_placement.console-preview-deploy = fly.
#
# Drives the REAL hub lane (bin/console-preview-deploy.sh) against a scratch
# harness (scratch_install_closure), a scratch origin with refs/pull/<n>/head,
# and stubs for gh, npm, npx (wrangler), curl, node and the jobs client (one
# seam: $HB/bin/jobs-client.sh, a local settings and queue store under $T).
#
#   H1  no placement row: the lane runs as before (npm ci, the upload, the
#       comment, `done`), and queues no pool row
#   H2  lane_placement.default = fly moves nothing: the hub builds
#   H3  the row set, but the project does not route builder=pool: the hub builds
#   F1  the row set: ONE pool row per console head (CP-<pr>-<head8>-1, target
#       fly, meta kind console_preview with the head), no npm, npx or node on
#       the hub, state `pool 1 0`; a fork head and a head with no console-ui/
#       change queue nothing
#   F2  a row still queued: no second row, no build, no comment
#   F3  CPV_DEPLOYED: QA and ONE comment with the marker, state `done`; the
#       next run posts nothing and queues nothing
#   F4  CPV_HEAD_FAILED: `failed 1`, then job 2 is queued; a second failure is
#       terminal: ONE terminal comment, never built again
#   F5  CPV_BOX_FAILED: one console-preview-box alert, no charge (`box 1 0`), no
#       new row that run; the next run queues job 2
#   F6  a row queued past CONSOLE_PREVIEW_POOL_TIMEOUT_S: closed failed by the
#       hub, the box's fault, no charge
#   F7  a deploy of another head is never taken as this head's
#   M1  bin/lib/queue-row-job.sh: the row becomes a console_preview job, or is
#       refused (rc 3, the row closed failed, no file)
#   M2  fly/builder-runner.sh sends a console_preview job to the CP body only,
#       and the body (bin/lib/console-preview-job.sh) deploys the head with the
#       hub's unprivileged build: CPV_DEPLOYED; the token file is removed
#   M3  the body's other answers: CPV_HEAD_FAILED, CPV_BOX_FAILED token, slug
#   P1  the pool arms read a CP- row as a lane row, never as a ticket
#   R1-R3 bin/fly-pool.sh's reap, BUILD_DEFERRED and death arms on a CP row
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/console-preview-fly.bh-8030-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in git jq flock; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset CONSOLE_PREVIEW_DEPLOY CONSOLE_PREVIEW_MAX_PER_RUN CONSOLE_PAGES_URL CONSOLE_PAGES_PROJECT CLOUDFLARE_API_TOKEN \
      CLOUDFLARE_ACCOUNT_ID CONSOLE_PREVIEW_QA_SCREENS CONSOLE_PREVIEW_WRANGLER CONSOLE_PREVIEW_MAX_ATTEMPTS \
      CONSOLE_PREVIEW_POOL_PROJECT CONSOLE_PREVIEW_POOL_TIMEOUT_S JOBS_URL
SLUG=o/console-fixture
PROJ=bh-fixture

# ── fixture: origin with PR refs, a hub checkout, a scratch harness ───────────
O="$T/gh/o/console-fixture.git"; W="$T/work"; CK="$T/ck"; HB="$T/h"
mkdir -p "$T/gh/o"
git init -q --bare -b main "$O"; git init -q -b main "$W"
mkdir -p "$W/console-ui/src" "$W/console-ui/functions/api" "$W/worker/jobs" "$W/catalog" "$W/docs"
echo '{"name":"console-ui"}' > "$W/console-ui/package.json"
echo 'export const who = "main";' > "$W/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$W/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$W/worker/jobs/wrangler.jsonc"
echo '{}' > "$W/catalog/x.json"; echo base > "$W/docs/x.md"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
pr() { # pr <n> [path] -> head sha of a PR that changes <path> (default console-ui/src/app.js)
  local f="${2:-console-ui/src/app.js}"
  git -C "$W" checkout -q -B "pr$1" main
  echo "change $1" >> "$W/$f"; git -C "$W" commit -qam "pr $1"
  git -C "$W" push -q "$O" "HEAD:refs/pull/$1/head"
  git -C "$W" rev-parse HEAD
}
S21=$(pr 21); S24=$(pr 24); S25=$(pr 25); S26=$(pr 26 docs/x.md); S27=$(pr 27); S28=$(pr 28); S29=$(pr 29)
git clone -q "$O" "$CK"

mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin" "$T/q" "$T/settings"
scratch_install_closure bin/console-preview-deploy.sh "$HB" >/dev/null || bad "closure of bin/console-preview-deploy.sh"
scratch_install_closure bin/lib/lane-placement.sh "$HB" >/dev/null 2>&1 || true
printf 'CLOUDFLARE_API_TOKEN=%s\n' tok-fixture-8030 > "$HB/env/cloudflare.env"
printf 'HARNESS_SECRET=%s\n' hsec-fixture-8030-not-real > "$HB/env/global.env"
printf '%s %s - - 0 local\n' "$PROJ" "$SLUG" > "$HB/fleet.conf"
QATOK="1791700000.$(printf 'ab%.0s' $(seq 1 32))"
CLEAN_PROJECT='{"success":true,"result":{"deployment_configs":{"preview":{"env_vars":{"VITE_X":{"value":"1"}}}}}}'
printf '%s\n' "$CLEAN_PROJECT" > "$T/cfproject"

# The jobs client seam: settings from $T/settings/<key>, queue rows in $T/q/<key>.json.
cat > "$HB/bin/jobs-client.sh" <<EOF
# test seam for bin/jobs-client.sh (tests/console-preview-fly.bh-8030-test.sh)
_setting_key_ok() { case "\${1:-}" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac; [ "\${#1}" -le 128 ]; }
setting_get() { _setting_key_ok "\${1:-}" || return 1; [ -e "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
_jobs_box_name() { echo hub-fixture; }
queue_routing_facts() { printf '%s|0\n' "\$(cat "$T/routing" 2>/dev/null || echo pool)"; }
queue_put() { # project key ticket target attempt meta
  printf 'queue_put %s %s %s %s\n' "\$1" "\$2" "\$3" "\$4" >> "$T/calls.log"
  printf '%s' "\$6" > "$T/q/\$2.meta"
  jq -nc --arg p "\$1" --arg at "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{project:\$p,status:"queued",enqueued_at:\$at,reason:""}' > "$T/q/\$2.json"
  echo queued
}
queue_done() { # project key status reason
  printf 'queue_done %s %s %s\n' "\$1" "\$2" "\$3" >> "$T/calls.log"
  jq -c --arg s "\$3" --arg r "\${4:-}" '.status = \$s | .reason = \$r' "$T/q/\$2.json" > "$T/q/\$2.json.n" && mv "$T/q/\$2.json.n" "$T/q/\$2.json"
}
_jobs_req() { # GET /api/queue?project=P&key=K&limit=1
  local q="\${2#*\\?}" k
  k=\${q#*key=}; k=\${k%%&*}
  case "\$1 \$2" in
    "GET /api/queue?"*) if [ -s "$T/q/\$k.json" ]; then jq -c '{queue:[.]}' "$T/q/\$k.json"; else echo '{"queue":[]}'; fi; return 0 ;;
  esac
  return 1
}
EOF

cat > "$T/sbin/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$T/calls.log"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
case "\$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    all="\$*"; n=\${all#*/issues/}; n=\${n%%/*}
    for a in "\$@"; do case "\$a" in body=@*) cat "\${a#body=@}" > "$T/posted-\$n"; echo x >> "$T/postcount-\$n" ;; esac; done
    send 201 '{"id":1}' ;;
  *"-X GET repos/"*"/issues/"*"/comments"*) send 200 '[]' ;;
  *"-X GET repos/"*"/pulls"*) send 200 "\$(cat "$T/openprs")" ;;
esac
exit 0
EOF
cat > "$T/sbin/npm" <<EOF
#!/bin/bash
printf 'npm %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  ci) exit 0 ;;
  run) [ "\$2" = build ] && { [ -f "$T/npm.buildfail" ] && exit 1; mkdir -p dist; echo '<html>' > dist/index.html; exit 0; } ;;
esac
exit 1
EOF
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/calls.log"
echo "✨ Deployment complete! Take a peek over at https://x.example.invalid"
exit 0
EOF
cat > "$T/sbin/curl" <<STUB
#!/bin/bash
printf 'curl %s\n' "\$*" >> "$T/calls.log"
case "\$*" in
  *"/pages/projects/"*) cat "$T/cfproject" ;;
  *"/api/qa/session"*) printf '{"ok":true,"token":"%s","expires_at":1791700000}\n' "$QATOK" ;;
  *) exit 7 ;;
esac
STUB
cat > "$T/sbin/node" <<STUB
#!/bin/bash
printf 'node %s\n' "\$*" >> "$T/calls.log"
printf 'SCREEN / 1440 ok\nSCREEN / 390 ok\nQA COVERAGE: screens=2 flows=0 shots=2\nQA: PASS\n'; exit 0
STUB
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
chmod +x "$T/sbin/"* "$HB/bin/lane-alert.sh"

prjson() { # prjson <n> <branch> <sha> [repo]
  jq -nc --argjson n "$1" --arg b "$2" --arg s "$3" --arg r "${4:-$SLUG}" \
    '{number:$n, head:{ref:$b, sha:$s, repo:{full_name:$r}}, base:{ref:"main"}}'
}
setprs() { printf '%s\n' "$@" | jq -sc . > "$T/openprs"; }
P21=$(prjson 21 ticket/bh-21 "$S21"); P24=$(prjson 24 ticket/bh-24 "$S24"); P25=$(prjson 25 ticket/bh-25 "$S25" fork/console-fixture)
P26=$(prjson 26 ticket/bh-26 "$S26"); P27=$(prjson 27 ticket/bh-27 "$S27"); P28=$(prjson 28 ticket/bh-28 "$S28")
P29=$(prjson 29 ticket/bh-29 "$S29")
reset() {
  rm -f "$T"/posted-* "$T"/postcount-* "$T"/npm.* "$T/routing"
  scratch_rm "$HB/state/console-preview-deploy"; scratch_rm "$T/q"; scratch_rm "$T/settings"
  mkdir -p "$T/q" "$T/settings"; : > "$T/calls.log"
}
fly_on() { printf 'fly' > "$T/settings/lane_placement.console-preview-deploy"; }
# run: one lane tick with every /root default pointed at the scratch tree;
# calls.log holds THIS tick's calls only.
run() {
  : > "$T/calls.log"
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN -u JOBS_URL HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      FLEET_CONF="$HB/fleet.conf" HARNESS_REPO="$SLUG" PATH="$T/sbin:$PATH" LANE_GATE_DISABLE=1 GH_ETAG=0 TMPDIR="$T" \
      HARNESS_TEST_SANDBOX=1 CONSOLE_PREVIEW_BUILD_USER=self CONSOLE_PREVIEW_BUILD_TMP="$T" \
      CONSOLE_PREVIEW_DEPLOY=1 CONSOLE_PAGES_URL=https://pages-fixture.example.invalid ${RUN_ENV:-} \
      bash "$HB/bin/console-preview-deploy.sh" ) > "$T/out" 2>&1
  RC=$?
}
rec()    { cat "$HB/state/console-preview-deploy/$1" 2>/dev/null; }
puts()   { grep -c '^queue_put ' "$T/calls.log"; }
hubbuild() { grep -cE '^(npm|npx|node) ' "$T/calls.log"; }
posts()  { [ -f "$T/postcount-$1" ] && wc -l < "$T/postcount-$1" | tr -d ' ' || echo 0; }
alerts() { grep -c '^alert .*--id console-preview-box ' "$T/calls.log"; }
key()    { printf 'CP-%s-%s-%s' "$1" "${2:0:8}" "$3"; }
setrow() { # setrow <key> <status> <reason> [enqueued_at]
  jq -nc --arg s "$2" --arg r "$3" --arg at "${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    '{project:"bh-fixture",status:$s,enqueued_at:$at,reason:$r}' > "$T/q/$1.json"
}
URL21=https://ticket-bh-21.pages-fixture.example.invalid

# ── H1: no placement row — unchanged ──────────────────────────────────────────
reset; setprs "$P21"; run
[ "$RC" = 0 ] && ok || bad "H1 rc=$RC $(cat "$T/out")"
grep -q '^npm ci ' "$T/calls.log" && grep -q '^npx .*pages deploy .*--commit-hash '"$S21" "$T/calls.log" && ok \
  || bad "H1 THE POINT: with no row the hub builds and uploads as before: $(grep -E '^(npm|npx)' "$T/calls.log")"
[ "$(puts)" = 0 ] && ok || bad "H1 no pool row with no placement row: $(grep '^queue_put' "$T/calls.log")"
[ "$(rec "$S21")" = done ] && [ "$(posts 21)" = 1 ] && grep -qx "<!-- console-preview sha=$S21 url=$URL21 -->" "$T/posted-21" && ok \
  || bad "H1 one comment and done: rec='$(rec "$S21")' posts=$(posts 21) $(cat "$T/out")"

# ── H2: only the default row says fly — the hub builds ───────────────────────
reset; setprs "$P21"; printf 'fly' > "$T/settings/lane_placement.default"; run
grep -q '^npm ci ' "$T/calls.log" && [ "$(puts)" = 0 ] && ok \
  || bad "H2 lane_placement.default=fly never moves this lane: puts=$(puts) $(grep -E '^npm' "$T/calls.log")"

# ── H3: the row set, but the project is not pool-routed — the hub builds ─────
reset; setprs "$P21"; fly_on; echo local > "$T/routing"; run
grep -q '^npm ci ' "$T/calls.log" && [ "$(puts)" = 0 ] && ok \
  || bad "H3 a project that does not route builder=pool builds on the hub: puts=$(puts) $(cat "$T/out")"
grep -q "routes builder=local" "$T/out" && ok || bad "H3 one line says why: $(cat "$T/out")"

# ── F1: the row set — one pool row per console head, nothing built on the hub ─
reset; setprs "$P21" "$P24" "$P25" "$P26"; fly_on; run
[ "$RC" = 0 ] && ok || bad "F1 rc=$RC $(cat "$T/out")"
[ "$(hubbuild)" = 0 ] && ok || bad "F1 THE POINT: no npm, npx or node on the hub: $(grep -E '^(npm|npx|node)' "$T/calls.log")"
[ "$(puts)" = 2 ] && ok || bad "F1 exactly two pool rows (21 and 24): $(grep '^queue_put' "$T/calls.log")"
grep -qx "queue_put $PROJ $(key 21 "$S21" 1) 21 fly" "$T/calls.log" && grep -qx "queue_put $PROJ $(key 24 "$S24" 1) 24 fly" "$T/calls.log" && ok \
  || bad "F1 one row per head, CP-<pr>-<head8>-1 on the fleet project, target fly: $(grep '^queue_put' "$T/calls.log")"
M21="$T/q/$(key 21 "$S21" 1).meta"
[ "$(jq -r '.kind' "$M21" 2>/dev/null)" = console_preview ] && [ "$(jq -r '.head' "$M21")" = "$S21" ] \
  && [ "$(jq -r '.pr' "$M21")" = 21 ] && [ "$(jq -r '.alias' "$M21")" = ticket-bh-21 ] && [ "$(jq -r '.slug' "$M21")" = "$SLUG" ] \
  && [ "$(jq -r '.acct' "$M21")" = acct-fixture ] && [ "$(jq -r '.wrangler' "$M21")" = 3.114.17 ] && ok \
  || bad "F1 the meta is the job: $(cat "$M21" 2>/dev/null)"
jq -e 'tostring | test("tok-fixture") | not' "$M21" >/dev/null 2>&1 && ok || bad "F1 the meta carries no token"
[ "$(rec "$S21")" = "pool 1 0" ] && [ "$(rec "$S24")" = "pool 1 0" ] && ok || bad "F1 state 'pool 1 0': 21='$(rec "$S21")' 24='$(rec "$S24")'"
[ -z "$(rec "$S25")" ] && ok || bad "F1 a fork head is never queued: '$(rec "$S25")'"
[ "$(rec "$S26")" = no-console ] && ok || bad "F1 a head with no console-ui change is no-console: '$(rec "$S26")'"
[ "$(posts 21)" = 0 ] && [ "$(posts 24)" = 0 ] && ok || bad "F1 no comment before a result"

# ── F2: rows still queued — no second row, no build, no comment ──────────────
run
[ "$(puts)" = 0 ] && [ "$(hubbuild)" = 0 ] && [ "$(posts 21)" = 0 ] && ok \
  || bad "F2 an in-flight row is waited on: puts=$(puts) hub=$(hubbuild) $(cat "$T/out")"
grep -q "in flight" "$T/out" && ok || bad "F2 the log says in flight: $(cat "$T/out")"

# ── F3 / F4: the results are read once ───────────────────────────────────────
setrow "$(key 21 "$S21" 1)" done "CPV_DEPLOYED $S21"
setrow "$(key 24 "$S24" 1)" done "CPV_HEAD_FAILED vite build failed"
run
[ "$(posts 21)" = 1 ] && grep -qx "<!-- console-preview sha=$S21 url=$URL21 -->" "$T/posted-21" \
  && grep -q "^QA: PASS for head $S21\." "$T/posted-21" && ok \
  || bad "F3 THE POINT: one comment with the marker and QA from the pool result: posts=$(posts 21) $(cat "$T/posted-21" 2>/dev/null)"
[ "$(rec "$S21")" = done ] && ok || bad "F3 the state is done: '$(rec "$S21")'"
grep -qF "node $HB/bin/console-qa-run.mjs $URL21 " "$T/calls.log" && ok || bad "F3 QA ran on the hub: $(grep '^node' "$T/calls.log")"
grep -qE '^(npm|npx) ' "$T/calls.log" && bad "F3 still no npm or npx on the hub" || ok
[ "$(rec "$S24")" = "failed 1 1" ] && [ "$(posts 24)" = 0 ] && ok || bad "F4 a head failure is charged once: '$(rec "$S24")' posts=$(posts 24)"
run
[ "$(posts 21)" = 1 ] && ok || bad "F3 THE POINT: the next run posts nothing again: posts=$(posts 21)"
grep -q "^queue_put $PROJ CP-21-" "$T/calls.log" && bad "F3 a done head is never queued again" || ok
grep -qx "queue_put $PROJ $(key 24 "$S24" 2) 24 fly" "$T/calls.log" && [ "$(rec "$S24")" = "pool 2 1" ] && ok \
  || bad "F4 the next try is job 2, attempts kept: '$(rec "$S24")' $(grep '^queue_put' "$T/calls.log")"
setrow "$(key 24 "$S24" 2)" done "CPV_HEAD_FAILED npm ci failed"
run
[ "$(rec "$S24")" = "failed 2 2" ] && [ "$(posts 24)" = 1 ] && grep -q "<!-- console-preview-failed sha=$S24 -->" "$T/posted-24" && ok \
  || bad "F4 the second head failure is terminal with one comment: '$(rec "$S24")' posts=$(posts 24)"
run
[ "$(puts)" = 0 ] && [ "$(posts 24)" = 1 ] && ok || bad "F4 a terminal head is never tried again: puts=$(puts) posts=$(posts 24)"

# ── F5: the pool's fault — no charge, one alert, job 2 next run ──────────────
reset; setprs "$P27" "$P28"; fly_on; run
setrow "$(key 27 "$S27" 1)" done "CPV_BOX_FAILED upload: preview deploy failed on the box side (wrangler rc=1)"
run
[ "$(alerts)" = 1 ] && grep '^alert ' "$T/calls.log" | grep -q "PR #27 head ${S27:0:12}" && ok \
  || bad "F5 one console-preview-box alert naming PR 27: $(grep '^alert' "$T/calls.log")"
[ "$(rec "$S27")" = "box 1 0" ] && [ "$(posts 27)" = 0 ] && ok || bad "F5 no charge, no comment: '$(rec "$S27")' posts=$(posts 27)"
[ "$(puts)" = 0 ] && ok || bad "F5 no new pool row in the run that read a box fault: $(grep '^queue_put' "$T/calls.log")"
run
grep -qx "queue_put $PROJ $(key 27 "$S27" 2) 27 fly" "$T/calls.log" && [ "$(rec "$S27")" = "pool 2 0" ] && ok \
  || bad "F5 the next run queues job 2: '$(rec "$S27")' $(grep '^queue_put' "$T/calls.log")"

# ── F6: a row queued past the timeout is the box's fault ─────────────────────
setrow "$(key 28 "$S28" 1)" queued "" "2020-01-01T00:00:00Z"
run
grep -qx "queue_done $PROJ $(key 28 "$S28" 1) failed" "$T/calls.log" && [ "$(rec "$S28")" = "box 1 0" ] && ok \
  || bad "F6 the hub closes a stale row failed and charges nothing: '$(rec "$S28")' $(grep '^queue_done' "$T/calls.log")"

# ── F7: a deploy of another head is not this head's ──────────────────────────
reset; setprs "$P29"; fly_on; run
setrow "$(key 29 "$S29" 1)" done "CPV_DEPLOYED $S21"
run
[ "$(posts 29)" = 0 ] && [ "$(rec "$S29")" = "box 1 0" ] && ok || bad "F7 another head's deploy posts nothing: '$(rec "$S29")' posts=$(posts 29)"

# ════════════════════════════════════════════════════════════════════════════
# M  the machine side
# ════════════════════════════════════════════════════════════════════════════
CMETA=$(jq -nc --arg s "$SLUG" --arg h "$S21" '{kind:"console_preview",slug:$s,pr:21,head:$h,alias:"ticket-bh-21",acct:"acct-fixture",project:"mission-control",wrangler:"3.114.17"}')
CKEY=$(key 21 "$S21" 1)
qrj() { # qrj <dest> <key> <meta> -> rc of queue_row_job_file
  ( mkdir -p "$T/hq/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$T/qrj-alerts" > "$T/hq/bin/alert-line.sh"; chmod +x "$T/hq/bin/alert-line.sh"
    queue_done() { printf '%s\n' "$*" >> "$T/qdone"; }
    # shellcheck source=bin/lib/queue-row-job.sh
    . "$DIR/bin/lib/queue-row-job.sh"
    HARNESS="$T/hq" queue_row_job_file "$PROJ" "$1" "$2" 21 0 "$3" >/dev/null )
}
mkdir -p "$T/m"
qrj "$T/m/job.json" "$CKEY" "$CMETA"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.console_preview.kind' "$T/m/job.json" 2>/dev/null)" = console_preview ] \
  && [ "$(jq -r '.console_preview.head' "$T/m/job.json")" = "$S21" ] && [ "$(jq -r '.key' "$T/m/job.json")" = "$CKEY" ] && ok \
  || bad "M1 a good row becomes a console_preview job: rc=$rc $(cat "$T/m/job.json" 2>/dev/null)"
qrj "$T/m/bad1.json" "$CKEY" "$(jq -c '.alias = "x;rm -rf /"' <<<"$CMETA")"; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/m/bad1.json" ] && grep -q "$CKEY failed console preview meta rejected (alias)" "$T/qdone" && ok \
  || bad "M1 a bad alias is refused: rc=$rc $(cat "$T/qdone" 2>/dev/null)"
qrj "$T/m/bad2.json" "TK-21" "$CMETA"; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/m/bad2.json" ] && ok || bad "M1 console_preview meta on a ticket key is refused: rc=$rc"
qrj "$T/m/bad3.json" "$CKEY" '{"hotfix":true}'; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/m/bad3.json" ] && ok || bad "M1 a CP key with no console_preview meta is refused (never a build of ticket 21): rc=$rc"
qrj "$T/m/bad4.json" "CP-21-ffffffff-1" "$CMETA"; rc=$?
[ "$rc" = 3 ] && ok || bad "M1 a key that does not name the head is refused: rc=$rc"

# M2: builder-runner -> run_console_preview_job -> cpv_pool_job_run, on a clone.
HR="$T/hr"; mkdir -p "$HR/bin/lib"
scratch_install_closure bin/lib/console-preview-job.sh "$HR" >/dev/null 2>&1 || echo "note: bin/lib/console-preview-job.sh is not installable"
awk '/^_run_job\(\) \{/,/^\}/; /^run_console_preview_job\(\) \{/,/^\}/; /^console_preview_setup_result\(\) \{/,/^\}/' \
  "$DIR/fly/builder-runner.sh" > "$T/runner-fns.sh"
MR="$T/mrepo"; git clone -q "$O" "$MR"
mrun() { # mrun <case> [job.json] — the runner on the job; RESULT in $T/<case>/RESULT
  local d="$T/$1"; mkdir -p "$d/env" "$d/tmp"
  [ -e "$d/env/cloudflare.env" ] || printf 'CLOUDFLARE_API_TOKEN=tok-fixture-m\n' > "$d/env/cloudflare.env"
  : > "$T/calls.log"
  ( JOB="${2:-$T/m/job.json}" RESULT_FILE="$d/RESULT" HARNESS="$HR" PROJECT="$PROJ" REPO="$MR" SINK="$d/sink"
    export SINK PATH="$T/sbin:$PATH" TMPDIR="$d/tmp" HARNESS_TEST_SANDBOX=1 CONSOLE_PREVIEW_BUILD_USER=self CONSOLE_PREVIEW_BUILD_TMP="$d/tmp"
    log() { printf 'log %s\n' "$*" >> "$SINK"; }; beat() { :; }
    load_env() { :; }; model_routes_warm() { :; }; start_heartbeat() { :; }; stop_heartbeat() { :; }
    warm_up() { printf 'warm_up\n' >> "$SINK"; return 0; }
    run_rebase_job() { printf 'run_rebase_job\n' >> "$SINK"; return 0; }
    run_rereview_job() { printf 'run_rereview_job\n' >> "$SINK"; return 0; }
    slot_preflight() { printf 'build path\n' >> "$SINK"; return 1; }
    # shellcheck source=/dev/null
    . "$T/runner-fns.sh"
    CPV_RUNNER_CFENV="$d/env/cloudflare.env"
    _run_job )
}
mrun m2
[ "$(head -1 "$T/m2/RESULT" 2>/dev/null)" = "CPV_DEPLOYED $S21" ] && ok || bad "M2 THE POINT: the machine deploys the head: $(cat "$T/m2/RESULT" 2>/dev/null) $(cat "$T/m2/sink" 2>/dev/null)"
grep -q "^npm ci --ignore-scripts " "$T/calls.log" && grep -q "^npx --yes wrangler@3.114.17 pages deploy dist --project-name mission-control --branch ticket-bh-21 --commit-hash $S21 " "$T/calls.log" && ok \
  || bad "M2 the hub's build rules: npm ci --ignore-scripts and the pinned upload of the alias: $(cat "$T/calls.log")"
grep -q 'build path\|run_rebase_job\|run_rereview_job' "$T/m2/sink" 2>/dev/null && bad "M2 a console_preview job never reaches another path: $(cat "$T/m2/sink")" || ok
[ -e "$T/m2/env/cloudflare.env" ] && bad "M2 the token file is removed after the job" || ok
grep -qx "PR: 21" "$T/m2/RESULT" && grep -qx "HEAD: $S21" "$T/m2/RESULT" && grep -q '^TIMINGS: total=' "$T/m2/RESULT" && ok \
  || bad "M2 the RESULT trailer: $(cat "$T/m2/RESULT")"
ls -d "$T/m2/tmp"/console-preview-* >/dev/null 2>&1 && bad "M2 the build and deploy trees are removed: $(ls "$T/m2/tmp")" || ok
bash "$DIR/bin/result-prefix-ok.sh" "$(head -1 "$T/m2/RESULT")" && ok || bad "M2 CPV_DEPLOYED is a RESULT word"
bash "$DIR/bin/result-prefix-ok.sh" "CPVX_DEPLOYED" && bad "M2 CPVX_ is not a RESULT word" || ok

# M3: the other answers.
touch "$T/npm.buildfail"; mrun m3a; rm -f "$T/npm.buildfail"
[ "$(head -1 "$T/m3a/RESULT" 2>/dev/null)" = "CPV_HEAD_FAILED vite build failed" ] && ok || bad "M3 a failed vite build is the head's: $(head -1 "$T/m3a/RESULT" 2>/dev/null)"
mkdir -p "$T/m3b/env"; : > "$T/m3b/env/cloudflare.env"; mrun m3b
case "$(head -1 "$T/m3b/RESULT" 2>/dev/null)" in "CPV_BOX_FAILED token: "*) ok ;; *) bad "M3 no token is the box's: $(head -1 "$T/m3b/RESULT" 2>/dev/null)" ;; esac
grep -q '^npm ' "$T/calls.log" && bad "M3 no build without a token" || ok
jq '.console_preview.slug = "evil/console-fixture"' "$T/m/job.json" > "$T/m/evil.json"; mrun m3c "$T/m/evil.json"
case "$(head -1 "$T/m3c/RESULT" 2>/dev/null)" in "CPV_BOX_FAILED repo: "*) ok ;; *) bad "M3 a slug that is not the repo is refused: $(head -1 "$T/m3c/RESULT" 2>/dev/null)" ;; esac
grep -q '^npm ' "$T/calls.log" && bad "M3 no build of another repo's job" || ok

# ════════════════════════════════════════════════════════════════════════════
# P  the pool arms read a CP row as a lane row
# ════════════════════════════════════════════════════════════════════════════
awk '/^pool_spawn_decision\(\) \{/,/^\}/' "$DIR/bin/fly-pool.sh" > "$T/psd.sh"
P1OUT=$( SINK="$T/p1sink"; export SINK
  say() { printf '%s\n' "$*"; }
  for f in pool_tick_budget_spent psr_marker_has psr_marker_put psr_marker_clear hold_check pool_hold_check pool_spawn_cap_check; do
    eval "$f() { printf '%s\n' $f >> \"\$SINK\"; return 1; }"
  done
  _POOL_ROWS_DECIDED=1
  # shellcheck source=/dev/null
  . "$T/psd.sh"
  pool_spawn_decision "$T/m/job.json" "$CKEY" 21; echo "rc=$?" )
case "$P1OUT" in *"console preview row"*"rc=0"*) ok ;; *) bad "P1 a CP row passes with the lane-row line: $P1OUT" ;; esac
[ -s "$T/p1sink" ] && bad "P1 no ticket gate is asked of a CP row: $(tr '\n' ' ' < "$T/p1sink")" || ok
( . "$DIR/bin/lib/docker-pool-host.sh" >/dev/null 2>&1; dph_key_ok "$CKEY" ) && bad "P1 the docker pool refuses CP-*" || ok
P4=$( . "$DIR/bin/lib/pool-orphan-rows.sh"; pool_orphan_row_verdict claimed fly pool-x pool-x "$CKEY" 9999 60 0 0 0 "" )
[ "$P4" = "$(printf 'keep\tconsole-preview')" ] && ok || bad "P1 pool-orphan-rows keeps a CP row: '$P4'"
P3=$( . "$DIR/bin/lib/pool-stall.sh"; pool_inflight_hold_due 21 "$CKEY" ok 1 "a|1" "b|1" 0 4 )
[ "$P3" = "$(printf 'skip\tconsole-preview')" ] && ok || bad "P1 pool-stall skips a CP row: '$P3'"
P6=$( SINK="$T/p6sink"; export SINK
  . "$DIR/bin/lib/ticket-ownership.sh" 2>/dev/null
  to_issue_repo() { printf 'to_issue_repo\n' >> "$SINK"; echo o/r; }
  to_hold_verdict() { printf 'to_hold_verdict\n' >> "$SINK"; return 0; }
  to_build_hold "$PROJ" 21 "$CKEY" >/dev/null; echo "rc=$?" )
[ "$P6" = "rc=1" ] && [ ! -s "$T/p6sink" ] && ok || bad "P1 a CP row is not a ticket to hold: $P6"

# ════════════════════════════════════════════════════════════════════════════
# R  bin/fly-pool.sh: the reap, BUILD_DEFERRED and death arms on a CP row
# ════════════════════════════════════════════════════════════════════════════
H="$T/p"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$H/state/fly" \
         "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" "$H/state/build-queue/tproj" "$T/pbin" "$T/relay"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/psink"; return 0; }
queue_put() { printf 'put %s\n' "\$*" >> "$T/psink"; echo queued; return 0; }
queue_status() { echo claimed; return 0; }
_jobs_req() { printf 'req %s\n' "\$*" >> "$T/psink"; cat "$T/prow.json" 2>/dev/null; }
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
printf 'HARNESS_SECRET=fixture-secret\n' > "$H/env/global.env"
printf 'FLY_API_TOKEN_TPROJ=tok-fixture-1\n' > "$H/env/fly.env"
printf 'tproj %s - - 0 local\n' "$SLUG" > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-tproj"; printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/pbeat"\nexit 0\n' "$T" > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/pbin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/pbin/flock"; printf '#!/bin/bash\nexit 0\n' > "$T/pbin/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/pgh"\nexit 1\n' "$T" > "$T/pbin/gh"
cat > "$T/pbin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/pfly"
case "\$*" in
  *"machine status"*) echo "State: \$(cat "$T/pmstate" 2>/dev/null || echo started)"; exit 0 ;;
  *"ssh console"*"head"*"RESULT"*) head -1 "$T/relay/RESULT" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*"RESULT"*) [ -s "$T/relay/RESULT" ] && base64 -w0 "$T/relay/RESULT"; exit 0 ;;
  *"ssh console"*) exit 0 ;;
  *"machines list"*) echo '[]' ;;
esac
exit 0
FLY
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$T/pbin"/*
jq -nc --argjson m "$CMETA" --arg k "$CKEY" \
  '{queue:[{project:"tproj",ticket_key:$k,ticket_id:"21",status:"claimed",target:"fly",attempt:0,meta:$m}]}' > "$T/prow.json"
preap() { # preap <key> <result-file-or-empty> [machine-state]
  local p
  for p in "$H/builds"/* "$H/state/build-queue/tproj"/* "$H/logs/ALERTS.log" \
           "$T/psink" "$T/pbeat" "$T/pgh" "$T/pfly" "$T/relay/RESULT" "$T/pmstate"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  [ -n "$2" ] && cp "$2" "$T/relay/RESULT"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$T/pmstate"
  : > "$H/logs/fly-pool.log"
  jq -nc --arg k "$1" '{machine:"m1",key:$k,ticket_id:"21",attempt:0}' > "$H/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/pbin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_API_TOKEN_TPROJ=tok-fixture-1 \
           FLY_BIN_DIR="$T/pbin" POOL_SPAWN=0 GH_TOKEN="" POOL_PR_VERIFY_SLEEP=0
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  PLOCAL=$(ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1)
}
printf 'CPV_DEPLOYED %s\nPR: 21\nHEAD: %s\nALIAS: ticket-bh-21\nTIMINGS: total=40\n' "$S21" "$S21" > "$T/r1"
preap "$CKEY" "$T/r1"
grep -q "^done tproj $CKEY done CPV_DEPLOYED $S21" "$T/psink" 2>/dev/null && ok || bad "R1 THE POINT: the row is closed done with RESULT line 1: $(cat "$T/psink" 2>/dev/null) $(tail -5 "$H/logs/fly-pool.log")"
[ -f "$PLOCAL/COMMENTED" ] && ok || bad "R1 the dir owes no board close-out (COMMENTED)"
grep -E 'pulls|issues|comments' "$T/pgh" 2>/dev/null && bad "R1 no PR read and no board comment for a CP row: $(cat "$T/pgh")" || ok
ls "$H/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R1 a CPV RESULT is never a remote result" || ok
grep -q "reaped console preview $CKEY" "$H/logs/fly-pool.log" && ok || bad "R1 the reap line is logged: $(tail -5 "$H/logs/fly-pool.log")"
grep -q 'machine destroy' "$T/pfly" 2>/dev/null && ok || bad "R1 the machine that held the token is destroyed, never reused: $(cat "$T/pfly" 2>/dev/null)"
printf 'PR_CREATED https://github.com/o/console-fixture/pull/55\n' > "$T/r1b"
preap "$CKEY" "$T/r1b"
grep -q "^done tproj $CKEY failed" "$T/psink" 2>/dev/null && ok || bad "R1 a build word on a CP key fails the row: $(cat "$T/psink" 2>/dev/null)"
ls "$H/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R1 a build word on a CP key is never read as a build" || ok

preap "$CKEY" "" stopped
grep -q "^done tproj $CKEY failed" "$T/psink" 2>/dev/null && ok || bad "R2 a dead CP machine fails the row: $(cat "$T/psink" 2>/dev/null)"
grep -qE "^done tproj $CKEY failed .*(died|deferred) [0-9]+ times" "$T/psink" 2>/dev/null && bad "R2 the reason is no blocked-resolver trigger" || ok
grep -q "^put tproj $CKEY" "$T/psink" 2>/dev/null && bad "R2 THE POINT: a dead CP row is never requeued (it would be a build of ticket 21)" || ok
ls "$H/state/build-queue/tproj/"* >/dev/null 2>&1 && bad "R2 no queue file and no .failed.json: $(ls "$H/state/build-queue/tproj")" || ok

printf 'BUILD_DEFERRED warm-up failed\n' > "$T/r3"
preap "$CKEY" "$T/r3"
grep -q "^done tproj $CKEY failed" "$T/psink" 2>/dev/null && ok || bad "R3 a stand-down fails the row: $(cat "$T/psink" 2>/dev/null)"
grep -q "^put tproj $CKEY" "$T/psink" 2>/dev/null && bad "R3 THE POINT: a deferred CP row is never requeued" || ok
[ -f "$PLOCAL/COMMENTED" ] && ok || bad "R3 COMMENTED is stamped"

echo "console-preview-fly.bh-8030-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
