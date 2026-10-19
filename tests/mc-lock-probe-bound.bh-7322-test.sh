#!/bin/bash
# tests/mc-lock-probe-bound.bh-7322-test.sh — BH-7322: the PR body read in the
# conductor's lock-probe step has a time bound, a cut read is one
# LOCK_PROBE_TIMEOUT line and a `locked` fan-in outcome, and a WORKER_DEADLINE
# kill in step lock-probe names the PR lock path.
#
# Sentry CROMFORD-HARNESS-H: "merge-conductor: worker killed at 53s deadline in
# step lock-probe (project-9)". pr_body_read (bin/lib/mc/classify.sh) sent the
# body read with no GH_REST_TIMEOUT_S, so a stalled GitHub read held the worker
# until mc_worker_bounded (bin/lib/fanin.sh) killed it.
#
#   K1-K4  mc_probe_read_timeout_s: default 20, 0 = 0, `abc` = 20; the knob
#          fragment's default is 20
#   L1     a second process holds the PR lock: mc_pr_lock_take, wait unset,
#          returns rc 1 in under 5 s
#   L2     MC_PR_LOCK_WAIT_S=0 and =x: rc 1 at once
#   L3     MC_PR_LOCK_WAIT_S=2: rc 1 after 2-4 s (the re-kick wait, bounded)
#   B1     the body answers: rc 0, no flag file, no note
#   B2     the read hangs, bound 2 s: rc 75 in under 10 s, flag `timeout\t<e>\t2`
#   B3     a fast 403: rc 75, empty flag, no note
#   B4     a 403 after 2 s under a 4 s bound: empty flag, no note
#   B5     knob 0: a 3 s answer is read (no bound)
#   B7     10 s to the worker deadline: the read is not sent, flag `timeout\t0\t0`
#   B8     25 s to the deadline, knob 20: the bound is 25 - 15 = 10 (9 or 10)
#   N1     B2 writes exactly one LOCK_PROBE_TIMEOUT line with elapsed >= 2
#   N2     B2 leaves <FANIN_STAGE_FILE>.locked
#   N3     B2 on a READY row writes a probe-timeout ready-why note; B3 none
#   S1     a deadline kill in step lock-probe: title ends `(lock <path>)`,
#          extra.lock = the path, tags step and worker_key
#   S2     step review: the title is byte-identical to before, extra.lock empty
#   S3     step lock-probe-x and step start: no lock suffix
#   S4     step lock-probe, P empty: no lock suffix
#   F1     the real conductor tick over 10 PRs, #4's body read hangs, knob 2:
#          enumerated 10 accounted 10, no WORKER_DEADLINE, one LOCK_PROBE_TIMEOUT
#   F2     the same tick with knob 0 (the defect): #4 is killed in step
#          lock-probe and the Sentry title names the lock
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-lock-probe-bound.bh-7322-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_INSTALLATION_ID MC_PR_PROBE_READ_TIMEOUT_S MC_PR_LOCK_WAIT_S MC_WORKER_DEADLINE_AT
CLASSIFY="$DIR/bin/lib/mc/classify.sh"
FANIN="$DIR/bin/lib/fanin.sh"
[ -r "$CLASSIFY" ] && [ -r "$FANIN" ] || { echo "the two libs are missing"; exit 1; }
NOW=$(date +%s)   # determinism: ok only the pr-state rows' stamps, never asserted
hd() { printf '%02d%038d' "$1" 0; }

# ---- the scratch harness: the REAL conductor and its libs, gh/curl stubbed ----
SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
F="$T/f"
mkdir -p "$F/h/logs" "$F/h/state/merge-conductor" "$F/h/flags" "$F/h/locks" "$F/h/builds" "$F/h/env" "$F/h/tmp" "$F/fakebin"
for s in bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$F/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
scratch_rm "$F/h/bin/lib/gh-limit-logger.sh"
mkdir -p "$F/h/catalog" && cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$F/h/catalog/" || exit 1
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$F/h/fleet.conf"
: > "$F/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/$s.sh"; chmod +x "$F/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$F" > "$F/h/bin/lane-alert.sh"; chmod +x "$F/h/bin/lane-alert.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$F/fakebin/restpr"; chmod +x "$F/fakebin/restpr"
# openprs <n>... — the open list: PR <n> on feat/f-<n> (not a ticket branch),
# head hd <n>, and no build record, so the worker reaches the body probe.
openprs() { printf '%s\n' "$@" | jq -Rsc --arg s "$SLUG" '[split("\n")[] | select(length > 0) | tonumber | {number:., html_url:("https://github.com/"+$s+"/pull/"+tostring),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-10-18T00:00:00Z", head:{ref:("feat/f-"+tostring), sha:((if . < 10 then "0" else "" end)+tostring+("0"*38)), repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}]' > "$F/open.json"; }
# The gh stub. $F/body-<n> says how the per-PR read of #<n> answers (the
# list's own lazy reads always answer at once): `hang` (exec sleep 60),
# `slow:<s>` (the body after <s> s), `403`, `late403:<s>` (a 403 after <s> s);
# else the body at once. The body never carries the harness marker.
cat > "$F/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$F/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$F/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*|*"pr merge"*) printf '%s\n' "\$A" >> "$F/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    if [ "\${HPL_READ_ROLE:-}" != list-lazy ]; then
      printf '%s\n' "\$N" >> "$F/body-reads.txt"
      M=\$(cat "$F/body-\$N" 2>/dev/null)
      case "\$M" in
        hang) exec sleep 60 ;;   # determinism: ok the stub IS the stalled body read under test
        slow:*) sleep "\${M#slow:}" ;;   # determinism: ok a slow answer the bound must not cut when off
        403) restpr --raw 403 '{"message":"Forbidden"}'; exit 0 ;;
        late403:*) sleep "\${M#late403:}"; restpr --raw 403 '{"message":"Forbidden"}'; exit 0 ;;   # determinism: ok a refusal that arrives under the bound
      esac
    fi
    restpr OPEN "\$(printf '%02d%038d' "\$N" 0)" "feat/f-\$N" main "" MERGEABLE CLEAN operator "" "plain body, no marker" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
esac
exit 0
EOF
chmod +x "$F/fakebin/gh"
cat > "$F/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$URL" in *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$M" "$URL"; exit 0 ;; esac
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$F/fakebin/curl"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$F/lpp.json" "$SLUG"
lpp_install "$F/fakebin" "$F/lpp.json" "$F/lpp-down"
cat > "$F/fakebin/sentry-curl" <<EOF
#!/bin/bash
cat > /dev/null
f=""; while [ \$# -gt 0 ]; do case "\$1" in --data-binary) f="\${2#@}"; shift 2 ;; *) shift ;; esac; done
k=\$(ls "$F"/sentry-env-*.txt 2>/dev/null | wc -l)
[ -n "\$f" ] && cp "\$f" "$F/sentry-env-\$k.txt"
printf 200
EOF
chmod +x "$F/fakebin/sentry-curl"
touch "$F/h/flags/merge-conductor-actions" "$F/h/flags/merge-conductor-merge" "$F/h/flags/conductor-owns-merges"
CLOG="$F/h/logs/merge-conductor.log"
ROWS="$F/h/state/merge-conductor/pr-state.tsv"
STATE="$F/h/state/merge-conductor"
row() { printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#$1" "${2:-WAIT_CI}" $((NOW-600)) "$(hd "$1")" "$(hd "$1")" "$U" "$1"; }
# fresh — a clean state dir, no rows, no stub modes.
fresh() { scratch_rm "$F/h/state"; mkdir -p "$STATE"; : > "$ROWS"; : > "$CLOG"
  rm -f "$F"/body-* "$F"/sentry-env-*.txt "$F"/stage.* "$F"/flag.*; : > "$F/c-calls.txt"; : > "$F/c-alerts.txt"; : > "$F/body-reads.txt"; touch "$F/c-writes.txt"; }
ENVC=(PATH="$F/fakebin:$PATH" HARNESS="$F/h" FLEET_CONF="$F/h/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test
  GH_TOKEN=pat-fixture-default HARNESS_PR_AUTHORS=operator
  HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=50 HARNESS_SENTRY_CURL="$F/fakebin/sentry-curl"
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 MC_STEP_POLL_S=1
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0)
events() { local f; for f in "$F"/sentry-env-*.txt; do [ -f "$f" ] && tail -1 "$f"; done | jq -c "select(.tags.reason == \"$1\")" 2>/dev/null; }

# The driver: the conductor's own lib and fan-in lib, as bin/merge-conductor.sh
# sources them, then one named case.
cat > "$F/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" || exit 99
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/fanin.sh" || exit 98
mc_init
SLUG=example-org/demo; P="${DRV_P-demo}"
case "$1" in
  knob) mc_probe_read_timeout_s ;;
  body)
    NUM=$2; KEY="$SLUG#$NUM"; HEAD=$(printf '%02d%038d' "$NUM" 0)
    FANIN_STAGE_FILE="$DRV_DIR/stage.$NUM"
    [ -n "${DRV_LEFT:-}" ] && MC_WORKER_DEADLINE_AT=$(( $(date +%s) + DRV_LEFT ))   # determinism: ok a deadline relative to now, as mc_worker_bounded sets it
    s=$SECONDS; rc=0
    pr_body_read "https://github.com/$SLUG/pull/$NUM" "$DRV_DIR/flag.$NUM" > "$DRV_DIR/body.$NUM" || rc=$?
    echo "rc=$rc took=$((SECONDS - s))" ;;
  take)
    exec 9>"$(mc_pr_lock "$P" "$2")"
    s=$SECONDS; rc=0; mc_pr_lock_take || rc=$?
    echo "rc=$rc took=$((SECONDS - s)) lock=$(mc_pr_lock "$P" "$2")" ;;
  deadline)
    NUM=$2; STEPN=$3; MC_TICK_ID="s$NUM"; MC_FANIN_T0=0
    sentry_report() {
      jq -nc --arg reason "$3" --arg message "$4" --argjson extra "${5:-null}" --argjson tags "${6:-null}" \
        '{reason:$reason,message:$message,extra:$extra,tags:$tags}' >> "$DRV_DIR/sev.$NUM"
    }
    if [ "$STEPN" = start ]; then pr_worker() { sleep 5; }   # determinism: ok the stub worker IS the stall the deadline kills
    else pr_worker() { mc_step "$STEPN"; sleep 5; }; fi       # determinism: ok the stub worker IS the stall the deadline kills
    ROW=$(printf '%s\turl\t6a7867e3ff00000000000000000000000000beef\tbr\tfalse\tCLEAN\t-' "$NUM")
    mc_worker_bounded "$ROW"; w=$(mc_fanin_outcome $? "$ROW")
    echo "word=$w lock=$( [ -n "$P" ] && mc_pr_lock "$P" "$NUM")" ;;
esac
EOF
drv() { ( unset -f gh; cd "$F" && timeout -k 5 60 env "${ENVC[@]}" TMPDIR="$F/h/tmp" DRV_DIR="$F" MC_TICK_ID=drv "$@" 2>&1 | tail -1 ); }
took() { sed -E 's/.*took=([0-9]+).*/\1/' <<<"$1"; }
flag() { if [ -f "$F/flag.$1" ]; then tr '\t' '|' < "$F/flag.$1"; else echo absent; fi; }
notes() { grep -c "LOCK_PROBE_TIMEOUT" "$CLOG" 2>/dev/null || true; }

# ============================================================================
# K — the knob reader and its fragment.
# ============================================================================
fresh
[ "$(drv bash "$F/drv.sh" knob)" = 20 ] && ok || bad "K1 the default is 20 ($(drv bash "$F/drv.sh" knob))"
[ "$(drv MC_PR_PROBE_READ_TIMEOUT_S=0 bash "$F/drv.sh" knob)" = 0 ] && ok || bad "K2 0 reads as 0 (off)"
[ "$(drv MC_PR_PROBE_READ_TIMEOUT_S=abc bash "$F/drv.sh" knob)" = 20 ] && ok || bad "K3 abc reads as 20"
KF="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_PR_PROBE_READ_TIMEOUT_S.json"
[ "$(jq -r '.env, .default, .min, .read_in' "$KF" 2>/dev/null | tr '\n' ' ')" = "MC_PR_PROBE_READ_TIMEOUT_S 20 0 bin/lib/mc/classify.sh " ] \
  && ok || bad "K4 the knob fragment: default 20, min 0, read_in classify.sh ($(cat "$KF" 2>/dev/null))"

# ============================================================================
# L — the PR lock itself never waits on a cron tick (AT1).
# ============================================================================
LK="$F/h/locks/merge-conductor-demo-7.lock"
( exec 9>"$LK"; flock 9; : > "$F/lk-held"; sleep 30 ) & LKP=$!   # determinism: ok a second process holds the lock for the L cases
for _ in $(seq 50); do [ -e "$F/lk-held" ] && break; sleep 0.1; done   # determinism: ok wait for the holder to take the lock
R=$(drv bash "$F/drv.sh" take 7)
grep -q "^rc=1 " <<<"$R" && [ "$(took "$R")" -lt 5 ] && grep -qF "lock=$LK" <<<"$R" && ok || bad "L1 a held lock: rc 1 in under 5 s, no wait ($R)"
for w in 0 x; do
  R=$(drv MC_PR_LOCK_WAIT_S=$w bash "$F/drv.sh" take 7)
  grep -q "^rc=1 " <<<"$R" && [ "$(took "$R")" -lt 2 ] && ok || bad "L2 MC_PR_LOCK_WAIT_S=$w: rc 1 at once ($R)"
done
R=$(drv MC_PR_LOCK_WAIT_S=2 bash "$F/drv.sh" take 7)
TK=$(took "$R")
grep -q "^rc=1 " <<<"$R" && [ "$TK" -ge 2 ] && [ "$TK" -le 4 ] && ok || bad "L3 MC_PR_LOCK_WAIT_S=2: rc 1 after 2-4 s ($R)"
kill "$LKP" 2>/dev/null; wait "$LKP" 2>/dev/null

# ============================================================================
# B, N — the real pr_body_read (AT2).
# ============================================================================
# B1 — the body answers.
fresh
R=$(drv MC_PR_PROBE_READ_TIMEOUT_S=2 bash "$F/drv.sh" body 1)
grep -q '^rc=0 ' <<<"$R" && [ "$(flag 1)" = absent ] && [ "$(cat "$F/body.1")" = "plain body, no marker" ] && [ "$(notes)" = 0 ] \
  && ok || bad "B1 a fast body: rc 0, no flag, the body, no note ($R flag=$(flag 1))"
# B2 — the read hangs past the bound. N1-N3 read the same run.
fresh; echo hang > "$F/body-2"; row 2 READY > "$ROWS"
R=$(drv MC_PR_PROBE_READ_TIMEOUT_S=2 bash "$F/drv.sh" body 2)
TK=$(took "$R"); FL=$(flag 2)
grep -q '^rc=75 ' <<<"$R" && [ "$TK" -ge 2 ] && [ "$TK" -lt 10 ] && ok || bad "B2 a hung read: rc 75 after 2-10 s ($R)"
[[ "$FL" =~ ^timeout\|([0-9]+)\|2$ ]] && [ "${BASH_REMATCH[1]}" -ge 2 ] && ok || bad "B2 the flag file is timeout<TAB><elapsed>=2+<TAB>2 ($FL)"
NL=$(grep "LOCK_PROBE_TIMEOUT" "$CLOG")
[ "$(notes)" = 1 ] && ok || bad "N1 exactly one LOCK_PROBE_TIMEOUT line ($(cat "$CLOG"))"
[[ "$NL" =~ $SLUG#2\ LOCK_PROBE_TIMEOUT\ step=lock-probe\ call=pr-body-read\ elapsed=([0-9]+)s\ bound=2s: ]] && [ "${BASH_REMATCH[1]}" -ge 2 ] \
  && ok || bad "N1 the line names the key, the step, the call, elapsed >= 2 and the bound ($NL)"
! grep -q WORKER_DEADLINE "$CLOG" && [ ! -s "$F/c-alerts.txt" ] && ok || bad "N1 no WORKER_DEADLINE line and no alert"
[ -e "$F/stage.2.locked" ] && ok || bad "N2 the fan-in locked mark is left ($(ls "$F" | grep stage))"
IFS=$'\t' read -r _ WH WK _ < "$STATE/ready-why/example-org_demo_2" 2>/dev/null
[ "${WK:-}" = probe-timeout ] && [ "${WH:-}" = "$(hd 2)" ] && ok || bad "N3 a READY row gets a probe-timeout note on its head ($(cat "$STATE/ready-why/example-org_demo_2" 2>/dev/null))"
# B3 — a fast refusal is not a timeout.
fresh; echo 403 > "$F/body-3"; row 3 READY > "$ROWS"
R=$(drv MC_PR_PROBE_READ_TIMEOUT_S=2 bash "$F/drv.sh" body 3)
grep -q '^rc=75 ' <<<"$R" && [ "$(flag 3)" = "" ] && [ "$(notes)" = 0 ] && [ ! -e "$F/stage.3.locked" ] && [ ! -e "$STATE/ready-why/example-org_demo_3" ] \
  && ok || bad "B3 a fast 403: rc 75, empty flag, no note, no mark ($R flag=$(flag 3))"
# B4 — a refusal under the bound, by more than the 1 s clock step.
fresh; echo late403:2 > "$F/body-4"
R=$(drv MC_PR_PROBE_READ_TIMEOUT_S=4 bash "$F/drv.sh" body 4)
grep -q '^rc=75 ' <<<"$R" && [ "$(flag 4)" = "" ] && [ "$(notes)" = 0 ] && ok || bad "B4 a 403 after 2 s, bound 4: empty flag, no note ($R flag=$(flag 4))"
# B5 — knob 0: no bound.
fresh; echo slow:3 > "$F/body-5"
R=$(drv MC_PR_PROBE_READ_TIMEOUT_S=0 bash "$F/drv.sh" body 5)
grep -q '^rc=0 ' <<<"$R" && [ "$(took "$R")" -ge 3 ] && [ "$(flag 5)" = absent ] && ok || bad "B5 knob 0: a 3 s answer is read ($R)"
# B7 — under 1 s left before the deadline margin: no read is sent.
fresh; echo hang > "$F/body-7"
R=$(drv MC_PR_PROBE_READ_TIMEOUT_S=20 DRV_LEFT=10 bash "$F/drv.sh" body 7)
grep -q '^rc=75 ' <<<"$R" && [ "$(took "$R")" -lt 2 ] && [ "$(flag 7)" = "timeout|0|0" ] && ok || bad "B7 10 s to the deadline: rc 75 at once, flag timeout|0|0 ($R flag=$(flag 7))"
[ ! -s "$F/body-reads.txt" ] && ok || bad "B7 the body read is not sent ($(cat "$F/body-reads.txt"))"
grep -qF "$SLUG#7 LOCK_PROBE_TIMEOUT step=lock-probe call=pr-body-read elapsed=0s bound=0s (no worker time left)" "$CLOG" && ok || bad "B7 the note says bound=0s ($(grep LOCK_PROBE "$CLOG"))"
# B8 — the bound is capped by the time left before the deadline margin.
fresh; echo hang > "$F/body-8"
R=$(drv MC_PR_PROBE_READ_TIMEOUT_S=20 DRV_LEFT=25 bash "$F/drv.sh" body 8)
FL=$(flag 8); TK=$(took "$R")
[[ "$FL" =~ ^timeout\|[0-9]+\|(9|10)$ ]] && [ "$TK" -ge 9 ] && [ "$TK" -lt 18 ] && ok || bad "B8 25 s left, knob 20: the bound is 10 ($R flag=$FL)"

# ============================================================================
# S — the WORKER_DEADLINE event names the lock in step lock-probe (AT3).
# ============================================================================
fresh
sev() { jq -rc "$2" "$F/sev.$1" 2>/dev/null | head -1; }
R=$(drv DRV_P=project-9 MC_WORKER_DEADLINE_S=1 MC_WORKER_DEADLINE_CAP_S= bash "$F/drv.sh" deadline 61 lock-probe)
SL="$F/h/locks/merge-conductor-project-9-61.lock"
grep -q "^word=killed:deadline lock=$SL\$" <<<"$R" && ok || bad "S1 setup: killed:deadline ($R)"
[ "$(sev 61 .message)" = "WORKER_DEADLINE: worker killed after 1s on 6a7867e3 in step lock-probe (lock $SL)" ] && ok || bad "S1 the title names the lock ($(sev 61 .message))"
[ "$(sev 61 .extra.lock)" = "$SL" ] && ok || bad "S1 extra.lock is the path ($(sev 61 .extra))"
[ "$(sev 61 .tags.step)" = lock-probe ] && [ "$(sev 61 .tags.worker_key)" = "$SLUG#61" ] && ok || bad "S1 tags step and worker_key ($(sev 61 .tags))"
R=$(drv DRV_P=project-9 MC_WORKER_DEADLINE_S=1 MC_WORKER_DEADLINE_CAP_S= bash "$F/drv.sh" deadline 62 review)
[ "$(sev 62 .message)" = "WORKER_DEADLINE: worker killed after 1s on 6a7867e3 in step review" ] && [ "$(sev 62 .extra.lock)" = "" ] \
  && ok || bad "S2 step review: the title is unchanged, no lock ($(sev 62 .message) / $(sev 62 .extra.lock))"
for c in 63:lock-probe-x 64:start; do
  R=$(drv DRV_P=project-9 MC_WORKER_DEADLINE_S=1 MC_WORKER_DEADLINE_CAP_S= bash "$F/drv.sh" deadline "${c%%:*}" "${c#*:}")
  [ "$(sev "${c%%:*}" .message)" = "WORKER_DEADLINE: worker killed after 1s on 6a7867e3 in step ${c#*:}" ] && ok || bad "S3 step ${c#*:}: no lock suffix ($(sev "${c%%:*}" .message))"
done
R=$(drv DRV_P= MC_WORKER_DEADLINE_S=1 MC_WORKER_DEADLINE_CAP_S= bash "$F/drv.sh" deadline 65 lock-probe)
[ "$(sev 65 .message)" = "WORKER_DEADLINE: worker killed after 1s on 6a7867e3 in step lock-probe" ] && ok || bad "S4 P empty: no lock suffix ($(sev 65 .message) $R)"

# ============================================================================
# F — the real conductor tick: 10 PRs, #4's body read hangs (AT4).
# ============================================================================
PRS=(1 2 3 4 5 6 7 8 9 10)
tick() { ( unset -f gh; cd "$F" && env -u MC_STEP_HOLD_MAX -u MC_STEP_TIMEOUT_S "${ENVC[@]}" "$@" bash "$F/h/bin/merge-conductor.sh" > "$F/mc.out" 2>&1 ); }
# A 30 s deadline: the bound is capped at the time left minus 15 s
# (mc_lock_wait_left), so a 15 s worker would send no body read at all.
fresh; openprs "${PRS[@]}"; echo hang > "$F/body-4"
S0=$SECONDS
tick MC_WORKER_DEADLINE_S=30 MC_PR_PROBE_READ_TIMEOUT_S=2
F1_S=$((SECONDS - S0))
TL=$(grep -F "FANIN merge-conductor $SLUG:" "$CLOG" | tail -1)
grep -q 'enumerated 10 accounted 10' <<<"$TL" && ok || bad "F1 FANIN accounts for all 10 PRs (${TL:-no FANIN}; $(tail -5 "$F/mc.out"))"
! grep -q 'killed:' <<<"$TL" && ok || bad "F1 no worker is killed ($TL)"
grep -qx 4 "$F/body-reads.txt" && ok || bad "F1 setup: #4's body read was sent ($(sort -n "$F/body-reads.txt" | tr '\n' ' '))"
[ "$(sort -un "$F/body-reads.txt" | grep -c .)" = 10 ] && ok || bad "F1 every PR's body was read ($(sort -n "$F/body-reads.txt" | tr '\n' ' '))"
! grep -q WORKER_DEADLINE "$CLOG" && ok || bad "F1 no WORKER_DEADLINE line ($(grep WORKER_DEADLINE "$CLOG"))"
[ -z "$(events conductor-worker-deadline)" ] && ok || bad "F1 no conductor-worker-deadline event"
[ "$(grep -c "LOCK_PROBE_TIMEOUT" "$CLOG")" = 1 ] && grep -qF "$SLUG#4 LOCK_PROBE_TIMEOUT step=lock-probe call=pr-body-read elapsed=" "$CLOG" \
  && ok || bad "F1 one LOCK_PROBE_TIMEOUT line, for #4 ($(grep LOCK_PROBE "$CLOG"))"
grep -qF "$SLUG#4 not a harness PR (branch feat/f-4, no record, body unread" "$CLOG" && ok || bad "F1 the probe arm logs #4's body as unread ($(grep -F '#4 ' "$CLOG" | tail -3))"
grep -qF "$SLUG#5 not a harness PR (branch feat/f-5, no record, no marker)" "$CLOG" && ok || bad "F1 a sibling's body is read and judged ($(grep -F '#5 ' "$CLOG" | tail -3))"
grep -Eq 'skipped:locked( rc=[0-9]+)? 1(,|\))' <<<"$TL" && ok || bad "F1 #4 is skipped:locked in the tally ($TL)"
[ "$F1_S" -lt 30 ] && ok || bad "F1 the tick ends before the worker deadline (took ${F1_S}s)"
# F2 — the defect, reproduced: the bound off, #4 holds its worker to the deadline.
fresh; openprs "${PRS[@]}"; echo hang > "$F/body-4"
tick MC_WORKER_DEADLINE_S=30 MC_PR_PROBE_READ_TIMEOUT_S=0
TL=$(grep -F "FANIN merge-conductor $SLUG:" "$CLOG" | tail -1)
grep -q 'enumerated 10 accounted 10' <<<"$TL" && grep -Eq 'killed:deadline( rc=[0-9]+)? 1(,|\))' <<<"$TL" && ok || bad "F2 knob 0: #4 is killed:deadline (${TL:-no FANIN})"
WD=$(grep -F "$SLUG#4 WORKER_DEADLINE: " "$CLOG")
grep -qF '| step: lock-probe (' <<<"$WD" && ok || bad "F2 the kill is in step lock-probe ($(grep WORKER_DEADLINE "$CLOG"))"
EV=$(events conductor-worker-deadline | head -1)
jq -e --arg l "$F/h/locks/merge-conductor-demo-4.lock" '(.message.formatted | endswith("in step lock-probe (lock " + $l + ")")) and .tags.step == "lock-probe"' <<<"$EV" >/dev/null 2>&1 \
  && ok || bad "F2 the Sentry title names the lock ($(jq -c '.message' <<<"$EV" 2>/dev/null))"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-lock-probe-bound.bh-7322: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
