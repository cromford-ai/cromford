#!/bin/bash
# tests/lib/lead-worklist-fixture.bh-4956.sh — the stub layer the BH-4956 lead
# review suites share. Sourced AFTER tests/lib/scratch.sh (it needs $T), never
# executed. lwf_setup builds a scratch harness carrying bin/lead-review.sh's
# real bin/lib closure (scratch_install_closure), the lead-delta knob registry
# and the lead protected paths (catalog/), and fake curl / gh / df on PATH:
#
#   the jobs worker (curl), state under $FX:
#     GET  /api/pr-state/needs-review?repo=  needs.<o_r>.json rows | needs.<o_r>.fail = 500
#     POST /api/lead-reviews/start            per (pr, sha12) state start.<pr>.<sha12>:
#                                             none/`running <job>` with the job gone (or the
#                                             same job asking again) = 200;
#                                             `running <job>` live = 409 live; done|failed|
#                                             superseded = 409 terminal. start.<k>.force
#                                             (done|failed|live) overrides. A /result
#                                             on an s-<pr>-<sha12> id writes the state.
#     POST /api/lead-reviews/<id>/claim      200 | claim.<id> holds another code
#     POST /api/lead-reviews/<id>/result     200 | result.fail = 500
#     GET  /api/lead-reviews?status=          rows.json | rows.fail = 500
#     POST /api/jobs, PATCH /api/jobs/<id>    job_open is a mkdir test-and-set per key;
#                                             done or failed releases the key
#     GET  /api/jobs?kind=lead_review         jobsrun.json (array) | jobsrun.fail = 500
#     GET  /api/settings/<key>                settings/<key> | FAIL = 500 | absent = 404
#     GET  /api/metrics/llm-spend             spend.fail = 500 | spend.seq (one line a
#                                             read, the last one sticks) | spend.usd | 0
#     GET/PUT /api/pr-attempts                attempts (lines `<n> <kind> <sha>`) |
#                                             attempts.fail = 500
#     DELETE /api/pr-attempts                 removes the line (200) | 404 when absent
#     POST /api/pr-state-events               201 | events.fail = 500
#     GET  /api/verdicts                      verdicts.json | {rows:[]}; verdicts.fail = 500 (every
#                                             read); standing.fail = 500 for a standing_only read
#     POST /api/verdicts                      201 {verdict:{id:901,...}} | verdictpost.fail = 500
#     GET  /api/verdict?pr=<url>              the builder verdict of PR <n>: bv.<n> (its content) |
#                                             bv.<n>.none = 404 | bv.<n>.fail = 500 | else APPROVE
#                                             bound to the PR's needs-review head (head.<n>, $SHA)
#     GET  /api/fix-rounds                    fixrounds.json | {fix_round_jobs:[]}; fixrounds.fail = 500
#     POST /api/wakes/lane                    200
#   every request is logged as `<METHOD> <path> <body>` to $T/log/worker.
#   gh: logs its argv to $T/log/gh; pulls/<n> answers state.<n> (open) and head.<n> ($SHA); ghfail.<n> = 500; ghbad.<n> = 200 with no head sha; ghdown.<n> = transport failure (no status);
#     ghrl.<n> = 403 "API rate limit exceeded". The body carries mergeable:true,
#     mergeable_state:"clean", and head.ref from ref.<n> when that file exists.
#     pulls/<n> carries base.ref $FX/base.<n> (main). The ghfail/ghbad/ghdown/ghrl
#     knobs fire only inside a review-pool worker (its TMPDIR is not $T/tmp): they
#     are for review_one's live-head read. Gate 15's base read runs in the tick
#     itself, where basefail.<n> = 500 and basebad.<n> = 200 with no base.ref.
#     The open-PR list rows carry updated_at (upd.<n>, else 2026-10-10T03:00:00Z) and base.ref main.
#     GET repos/<o>/<r>/git/ref/heads/<b> answers basetip (else 0...09).
#     GET repos/<o>/<r>/contents/.mergify.yml answers mergify.yml base64 (absent = 404).
#     GET repos/<o>/<r>/commits/<sha>/check-runs answers checks.<sha> (else no runs).
#     POST repos/<o>/<r>/statuses/<sha> = 201 | statusfail = 500.
#     GET repos/<o>/<r> answers default_branch $FX/defbranch (main); repofail = 500.
#     GET repos/<o>/<r>/compare/<base>...<head> answers cmp.<head> (else one clean
#     non-merge commit); cmpfail.<head> = 500. Gate 15 of lead-review.sh reads it.
#   bin/agent-call.sh: logs the PR to $T/log/agent-prs and the in-flight count to
#     $T/log/conc; with $FX/block it waits for $FX/release.<pr> or release.all,
#     else sleeps $FX/sleep; agentrc.<pr> = exit with that rc and no answer.
#   bin/lane-alert.sh: logs its argv to $T/log/lane-alert.
#   LEAD_VERDICT_TOKEN_FILE is $FX/lead-token (absent unless a suite writes it),
#   so no box's own token decides a suite's path.
# Helpers: lwf_needs, lwf_needs_at, lwf_rows, lwf_tick, lwf_tick_bg, lwf_reset, lwf_cnt, lwf_agents,
# lwf_peak, lwf_live, lwf_summary, lwf_bv, lwf_ci_green, lwf_main_merge.

lwf_setup() {
  local s n refs=()
  LWF_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  H="$T/h"; FX="$T/fx"; L="$H/logs/lead-review.log"
  mkdir -p "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/jobs" "$FX/settings" \
    "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state"
  for s in bin/lead-review.sh bin/lead-verdict.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
    cp "$LWF_SRC/$s" "$H/bin/"
    scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
  done
  [ -r "$H/bin/lib/jobs/req.sh" ] || { echo "the closure did not install bin/lib/jobs/*.sh"; exit 1; }
  cp "$LWF_SRC/catalog/lanes.d/_lib.json" "$LWF_SRC/catalog/lanes.d/_lib.lead-delta.json" "$H/catalog/lanes.d/"
  cp "$LWF_SRC/catalog/lead-protected-paths.tsv" "$H/catalog/"
  cp "$LWF_SRC/prompts/lead-review.md" "$LWF_SRC/prompts/lead-review-checklist.md" "$H/prompts/"
  echo box-demo > "$H/state/box-name"
  printf '%s\n' \
    'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo' \
    'demo2-os example-org/demo2-os https://demo2.test /api/board 1 box-demo' \
    'other-os example-org/other-os https://other.test /api/board 1 box-other' > "$H/fleet.conf"
  cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lane-alert"
exit 0
EOF
  cat > "$H/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
EOF
  cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
pr="\${AGENT_CALL_PR##*/}"
( flock 9; printf '%s\n' "\$pr" >> "$T/log/agent-prs" ) 9>"$T/agent.lock"
if [ -e "$FX/agentrc.\$pr" ]; then exit "\$(cat "$FX/agentrc.\$pr")"; fi
( flock 9; mkdir -p "$T/run"; : > "$T/run/\$pr"; ls "$T/run" | wc -l | tr -d ' ' >> "$T/log/conc" ) 9>"$T/agent.lock"
if [ -e "$FX/block" ]; then
  i=0
  while [ ! -e "$FX/release.\$pr" ] && [ ! -e "$FX/release.all" ] && [ "\$i" -lt 600 ]; do sleep 0.1; i=\$((i + 1)); done
else
  sleep "\$(cat "$FX/sleep" 2>/dev/null || echo 0)"
fi
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
( flock 9; rm -f "$T/run/\$pr" ) 9>"$T/agent.lock"
exit 0
EOF
  chmod +x "$H/bin/lane-alert.sh" "$H/bin/alert-line.sh" "$H/bin/agent-call.sh"

  # git: one PR commit, published at refs/pull/<n>/head for every PR the suites use
  O="$T/origin/demo-os.git"; W="$T/work/demo-os"
  git init -q --bare -b main "$O"; git init -q -b main "$W"
  printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
  git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base; git -C "$W" push -q "$O" main
  echo two >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr change"
  SHA=$(git -C "$W" rev-parse HEAD)
  for n in $(seq 1 12) $(seq 101 112) $(seq 201 205); do refs+=("HEAD:refs/pull/$n/head"); done
  git -C "$W" push -q "$O" "${refs[@]}"
  git clone -q "$O" "$T/repos/demo-os"; git clone -q "$O" "$T/repos/demo2-os"

  cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
qv() { printf '%s' "\$p" | sed -n "s/.*[?&]\$1=\\([^&]*\\).*/\\1/p" | sed 's/%2F/\\//g; s/%2f/\\//g'; }
code=200; out='{}'
case "\$m \$p" in
  "GET /api/pr-state/needs-review"*)
    f="$FX/needs.\$(qv repo | tr '/' '_')"
    if [ -e "\$f.fail" ]; then code=500; out='{"error":"fixture outage"}'
    elif [ -r "\$f.json" ]; then out=\$(jq -c '{rows:., as_of:"t"}' "\$f.json")
    else out='{"rows":[],"as_of":"t"}'; fi ;;
  "POST /api/lead-reviews/start")
    pr=\$(printf '%s' "\$body" | jq -r '.pr'); s=\$(printf '%s' "\$body" | jq -r '.head_sha')
    j=\$(printf '%s' "\$body" | jq -r '.job_id'); r=\$(printf '%s' "\$body" | jq -r '.repo')
    k="\$pr.\${s:0:12}"; id="s-\$pr-\${s:0:12}"
    st=\$(cat "$FX/start.\$k.force" 2>/dev/null || cat "$FX/start.\$k" 2>/dev/null)
    row() { jq -nc --arg i "\$id" --arg r "\$r" --argjson p "\$pr" --arg s "\$s" --arg st "\$1" --arg j "\$2" \
      '{id:\$i, repo:\$r, pr:\$p, head_sha:\$s, status:\$st, job_id:\$j, scope_notes:null, requested_by:"lead-review-worklist"}'; }
    case "\$st" in
      done|failed|superseded) code=409; out=\$(jq -nc --argjson q "\$(row "\$st" "")" '{error:"finished", request:\$q, terminal:true}') ;;
      live) code=409; out=\$(jq -nc --argjson q "\$(row running job-live)" '{error:"live", request:\$q}') ;;
      "running "*)
        hj="\${st#running }"
        if [ "\$hj" != "\$j" ] && [ -d "$T/jobs/\${hj#job-}" ]; then code=409; out=\$(jq -nc --argjson q "\$(row running "\$hj")" '{error:"live", request:\$q}')
        else echo "running \$j" > "$FX/start.\$k"; out=\$(jq -nc --argjson q "\$(row running "\$j")" --arg h "\$hj" '{request:\$q, reclaimed_from:\$h}'); fi ;;
      *) echo "running \$j" > "$FX/start.\$k"; out=\$(jq -nc --argjson q "\$(row running "\$j")" '{request:\$q, created:true}') ;;
    esac ;;
  "POST /api/lead-reviews/"*/result)
    if [ -e "$FX/result.fail" ]; then code=500; out='{"error":"fixture outage"}'
    else
      id="\${p#/api/lead-reviews/}"; id="\${id%/result}"
      o=\$(printf '%s' "\$body" | jq -r '.outcome')
      case "\$id" in s-*) k="\${id#s-}"; echo "\$o" > "$FX/start.\${k%%-*}.\${k#*-}" ;; esac
    fi ;;
  "POST /api/lead-reviews/"*/claim)
    id="\${p#/api/lead-reviews/}"; id="\${id%/claim}"
    [ -r "$FX/claim.\$id" ] && { code=\$(cat "$FX/claim.\$id"); out='{"error":"fixture claim refusal"}'; } ;;
  "GET /api/lead-reviews"*)
    if [ -e "$FX/rows.fail" ]; then code=500; out='{"error":"fixture outage"}'
    else out=\$(jq -c '{requests:., truncated:false}' "$FX/rows.json" 2>/dev/null || echo '{"requests":[],"truncated":false}'); fi ;;
  "POST /api/jobs")
    k=\$(printf '%s' "\$body" | jq -r '.ticket_id')
    if mkdir "$T/jobs/\$k" 2>/dev/null; then out=\$(jq -nc --arg k "\$k" '{job:{id:("job-" + \$k)}}')
    else code=409; out='{"job":{"id":"job-x","box":"box-other"}}'; fi ;;
  "PATCH /api/jobs/job-"*)
    case "\$(printf '%s' "\$body" | jq -r '.status // empty')" in
      done|failed) rmdir "$T/jobs/\${p#/api/jobs/job-}" 2>/dev/null ;;
    esac ;;
  "GET /api/jobs?"*)
    if [ -e "$FX/jobsrun.fail" ]; then code=500; out='{"error":"fixture outage"}'
    else out=\$(jq -c '{jobs:.}' "$FX/jobsrun.json" 2>/dev/null || echo '{"jobs":[]}'); fi ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
  "GET /api/metrics/llm-spend"*)
    if [ -e "$FX/spend.fail" ]; then code=500; out='{"error":"fixture outage"}'
    elif [ -s "$FX/spend.seq" ]; then
      ( flock 9; v=\$(head -n 1 "$FX/spend.seq")
        [ "\$(wc -l < "$FX/spend.seq")" -gt 1 ] && sed -i 1d "$FX/spend.seq"
        printf '%s' "\$v" > "$FX/spend.cur" ) 9>"$T/spend.lock"
      out=\$(jq -nc --argjson u "\$(cat "$FX/spend.cur")" '{usd:\$u}')
    else out=\$(jq -nc --argjson u "\$(cat "$FX/spend.usd" 2>/dev/null || echo 0)" '{usd:\$u}'); fi ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ ! -e "$FX/settings/\$k" ]; then code=404; out='{"error":"no such setting"}'
    elif [ "\$(cat "$FX/settings/\$k")" = FAIL ]; then code=500; out='{"error":"fixture outage"}'
    else out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$FX/settings/\$k")" '{setting:{key:\$k, value:\$v}}'); fi ;;
  "GET /api/pr-attempts"*)
    if [ -e "$FX/attempts.fail" ]; then code=500; out='{"error":"fixture outage"}'
    elif grep -qxF "\$(qv number) \$(qv kind) \$(qv sha)" "$FX/attempts" 2>/dev/null; then
      out=\$(jq -nc --arg k "\$(qv kind)" --arg s "\$(qv sha)" '{attempt:{kind:\$k, sha:\$s}}')
    else code=404; out='{"error":"not found"}'; fi ;;
  "DELETE /api/pr-attempts"*)
    ln="\$(qv number) \$(qv kind) \$(qv sha)"
    if grep -qxF "\$ln" "$FX/attempts" 2>/dev/null; then grep -vxF "\$ln" "$FX/attempts" > "$FX/attempts.new"; mv -f "$FX/attempts.new" "$FX/attempts"
    else code=404; out='{"error":"not found"}'; fi ;;
  "PUT /api/pr-attempts")
    printf '%s\n' "\$(printf '%s' "\$body" | jq -r '"\(.number) \(.kind) \(.sha)"')" >> "$FX/attempts"; code=201 ;;
  "POST /api/pr-state-events")
    if [ -e "$FX/events.fail" ]; then code=500; out='{"error":"fixture outage"}'; else code=201; fi ;;
  "GET /api/verdicts"*)
    if [ -e "$FX/verdicts.fail" ] || { [ -e "$FX/standing.fail" ] && [[ "\$p" == *standing_only=1* ]]; }; then code=500; out='{"error":"fixture outage"}'
    else out=\$(cat "$FX/verdicts.json" 2>/dev/null || echo '{"rows":[],"truncated":false}'); fi ;;
  "POST /api/verdicts")
    if [ -e "$FX/verdictpost.fail" ]; then code=500; out='{"error":"fixture outage"}'
    else code=201; out=\$(printf '%s' "\$body" | jq -c '{verdict:(. + {id:901, created_at:"2026-10-10T03:00:00Z"})}'); fi ;;
  "GET /api/verdict?"*)
    n=\$(printf '%s' "\$p" | sed -n 's/.*pull%2F\([0-9]*\).*/\1/p')
    if [ -e "$FX/bv.\$n.fail" ]; then code=500; out='{"error":"fixture outage"}'
    elif [ -e "$FX/bv.\$n.none" ]; then code=404; out='{"error":"no job recorded this PR"}'
    elif [ -r "$FX/bv.\$n" ]; then out=\$(cat "$FX/bv.\$n")
    else
      h=\$(cat "$FX"/needs.*.json 2>/dev/null | jq -rs --argjson n "\${n:-0}" '[.[][]? | select(.number == \$n) | .head] | first // empty')
      [ -n "\$h" ] || h=\$(cat "$FX/head.\$n" 2>/dev/null || echo "$SHA")
      out=\$(jq -nc --arg h "\$h" '{verdict:"APPROVE", reviewed_sha:\$h, artifacts:[]}')
    fi ;;
  "GET /api/fix-rounds"*)
    if [ -e "$FX/fixrounds.fail" ]; then code=500; out='{"error":"fixture outage"}'
    else out=\$(cat "$FX/fixrounds.json" 2>/dev/null || echo '{"fix_round_jobs":[],"truncated":false}'); fi ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
printf '%s\n' "\$a" >> "$T/log/gh"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/compare/[^/]+\.\.\.([0-9a-f]+) ]]; then
  c="\${BASH_REMATCH[1]}"
  if [ -e "$FX/cmpfail.\$c" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  printf 'HTTP/2 200\r\n\r\n'
  if [ -r "$FX/cmp.\$c" ]; then cat "$FX/cmp.\$c"
  else echo '{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: x"}}]}'; fi
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/git/ref/heads/ ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "\$(cat "$FX/basetip" 2>/dev/null || printf '%040d' 9)" '{object:{sha:\$s}}'
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/contents/\.mergify\.yml ]]; then
  if [ ! -r "$FX/mergify.yml" ]; then printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; exit 1; fi
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg c "\$(base64 -w0 < "$FX/mergify.yml")" '{content:\$c}'
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/commits/([0-9a-f]+)/check-runs ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  cat "$FX/checks.\${BASH_REMATCH[1]}" 2>/dev/null || echo '{"total_count":0,"check_runs":[]}'
  exit 0
fi
if [[ "\$a" =~ POST\ repos/[^/]+/[^/]+/statuses/ ]]; then
  if [ -e "$FX/statusfail" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  printf 'HTTP/2 201\r\n\r\n{"state":"success"}'
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/\ ]+\$ ]]; then
  if [ -e "$FX/repofail" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg b "\$(cat "$FX/defbranch" 2>/dev/null || echo main)" '{default_branch:\$b}'
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls\ .*page=([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  if [ "\${BASH_REMATCH[1]}" = 1 ]; then
    for n in \$(seq 1 12) \$(seq 101 112); do
      [ "\$(cat "$FX/state.\$n" 2>/dev/null || echo open)" = open ] || continue
      jq -nc --argjson n "\$n" --arg s "\$(cat "$FX/head.\$n" 2>/dev/null || echo "$SHA")" --arg u "\$(cat "$FX/upd.\$n" 2>/dev/null || echo 2026-10-10T03:00:00Z)" \
        '{number:\$n, head:{sha:\$s}, labels:[], updated_at:\$u, base:{ref:"main"}}'
    done | jq -sc .
  else echo '[]'; fi
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls/([0-9]+) ]]; then
  n="\${BASH_REMATCH[1]}"
  if [ "\${TMPDIR:-}" = "$T/tmp" ]; then
    if [ -e "$FX/basefail.\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
    if [ -e "$FX/basebad.\$n" ]; then printf 'HTTP/2 200\r\n\r\n{"state":"open"}'; exit 0; fi
  else
    if [ -e "$FX/ghfail.\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
    if [ -e "$FX/ghrl.\$n" ]; then printf 'HTTP/2 403\r\n\r\n{"message":"API rate limit exceeded"}'; exit 1; fi
    if [ -e "$FX/ghbad.\$n" ]; then printf 'HTTP/2 200\r\n\r\n{"state":"open"}'; exit 0; fi
    if [ -e "$FX/ghdown.\$n" ]; then exit 1; fi
  fi
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "\$(cat "$FX/head.\$n" 2>/dev/null || echo "$SHA")" --arg st "\$(cat "$FX/state.\$n" 2>/dev/null || echo open)" \
    --arg r "\$(cat "$FX/ref.\$n" 2>/dev/null)" --arg b "\$(cat "$FX/base.\$n" 2>/dev/null || echo main)" \
    '{state:\$st,head:({sha:\$s} + (if \$r == "" then {} else {ref:\$r} end)),base:{ref:\$b},title:"t",body:"b",mergeable:true,mergeable_state:"clean"}'
  exit 0
fi
exit 0
EOF
  cat > "$T/fakebin/df" <<'EOF'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 104857600 1%% /tmp\n'
EOF
  printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
  chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/df"

  export PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
    JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" \
    LANE_GATE_DISABLE=1 GH_ETAG=0 REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05 \
    REVIEW_POOL_TMP_SWEEP="" LW_READ_TTL_S=0 LEAD_REVIEW_WORKLIST=1 LEAD_VERDICT_TOKEN_FILE="$FX/lead-token"
  unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_MAX_PAGES PR_SNAPSHOT \
    HOTFIX_LABEL HOTFIX_LANE LEAD_REVIEW_CONCURRENCY LEAD_REVIEW_BOX_MAX LEAD_REVIEW_TMP_MIN_MB LLM_USD_CAP_DAY \
    REVIEW_POOL_TMP_PATH LEAD_REVIEW_AUTO_REPOS LEAD_REVIEW_MAX_PER_PR_DAY LEAD_REVIEW_SPILLOVER \
    LEAD_REVIEW_RERUN_MAX HARNESS_PARTICIPANT_TOKEN_FILE LEAD_REVIEW_REQUIRE_BUILDER_APPROVE
  # TEST-CHANGE (BH-5876): gate 13 (bin/lib/lead-gates.d/90-caps.sh) holds every
  # worklist head when either cap knob is empty, and this scratch harness has no
  # catalog/lanes.json to export them. 4 is lw_pr_day_ok's own fallback; 50 is
  # above every suite's per-tick item count. A tick that sets either keeps it.
  export LEAD_REVIEW_ENQUEUE_MAX_PER_TICK="${LEAD_REVIEW_ENQUEUE_MAX_PER_TICK:-50}" \
    LEAD_REVIEW_MAX_PER_PR_DAY="${LEAD_REVIEW_MAX_PER_PR_DAY:-4}"
}

# The suites that source this fixture test the worklist, so it is on
# (LEAD_REVIEW_WORKLIST=1); the lane default is 0 (worklist W7 pins it).

# lwf_needs <owner/repo> <pr>... — the needs-review rows for a repo, in route order, on $SHA
lwf_needs() { local slug="$1"; shift; lwf_needs_at "$slug" "$SHA" "$@"; }
# lwf_needs_at <owner/repo> <head> <pr>... — the same rows on another head
lwf_needs_at() {
  local slug="$1" head="$2" n out='[]'; shift 2
  for n in "$@"; do
    out=$(jq -c --arg r "$slug" --argjson n "$n" --arg s "$head" \
      '. + [{repo:$r, number:$n, url:("https://github.com/" + $r + "/pull/" + ($n|tostring)), head:$s,
             hotfix:0, nudged:0, approved_at:"2026-10-10T03:00:00Z"}]' <<<"$out")
  done
  printf '%s\n' "$out" > "$FX/needs.${slug//\//_}.json"
}
# lwf_rows <status> <pr>... — request rows on example-org/demo-os at $SHA
lwf_rows() {
  local st="$1" n i=0 out='[]'; shift
  for n in "$@"; do
    out=$(jq -c --arg n "$n" --arg s "$SHA" --arg st "$st" --argjson i "$i" \
      '. + [{id:("r-" + $n), repo:"example-org/demo-os", pr:($n|tonumber), head_sha:$s, status:$st,
             created_at:("2026-10-10 03:00:0" + ($i|tostring)), scope_notes:null, requested_by:"lead-verdict"}]' <<<"$out")
    i=$((i + 1))
  done
  printf '%s\n' "$out" > "$FX/rows.json"
}
lwf_reset() {
  rm -f "$T/log"/* "$L"
  find "$FX" -mindepth 1 -maxdepth 1 -type f -delete
  find "$FX/settings" -mindepth 1 -type f -delete
  scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; scratch_rm "$T/run"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/lead-review"
  rm -f "$H/state"/review-pool-* "$H/locks"/lead-review-*.lock
  echo '[]' > "$FX/rows.json"
}
lwf_tick() { ( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
lwf_tick_bg() { ( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" exec bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1 & TICK_PID=$!; }
lwf_cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
lwf_agents() { lwf_cnt . "$T/log/agent-prs"; }
lwf_peak() { sort -n "$T/log/conc" 2>/dev/null | tail -1; }
lwf_live() { find "$T/run" -type f 2>/dev/null | wc -l | tr -d ' '; }
lwf_summary() { grep ' tick seen=' "$L" 2>/dev/null | tail -1; }
# lwf_wait <seconds> <command...> — poll until the command succeeds; rc 1 on timeout
lwf_wait() { local i=0 lim=$(( $1 * 20 )); shift; until "$@"; do i=$((i + 1)); [ "$i" -ge "$lim" ] && return 1; sleep 0.05; done; }
# lwf_bv <pr> <verdict> <reviewed sha> [headbound] [build box] — the builder
#   verdict GET /api/verdict?pr= answers for <pr> (bin/lib/jobs/jobs.sh job_verdict)
lwf_bv() {
  jq -nc --arg v "$2" --arg s "$3" --arg hb "${4:-}" --arg b "${5:-}" '{verdict:$v, reviewed_sha:$s,
    artifacts:(if $hb == "" then [] else [{artifact_kind:"verdict", detail:({headbound:$hb} | tojson)}] end)}
    + (if $b == "" then {} else {job:{box:$b}} end)' > "$FX/bv.$1"
}
# lwf_ci_green <sha>... — CI green on each sha: the base .mergify.yml asks for
#   one check, `Tests`, and each sha has one completed-success run of it
lwf_ci_green() {
  local s
  printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "Tests"\n' > "$FX/mergify.yml"
  for s in "$@"; do
    jq -nc --arg s "$s" '{total_count:1, check_runs:[{name:"Tests", head_sha:$s, status:"completed",
      conclusion:"success", app:{slug:"github-actions"}}]}' > "$FX/checks.$s"
  done
}
# lwf_main_merge — H1: the PR commit $SHA with a new main merged in (patch_same
#   main-merge), published as main and refs/pull/201/head
lwf_main_merge() {
  local gc=(git -C "$W" -c user.email=t@t -c user.name=t)
  "${gc[@]}" checkout -q -b lwf-main "$SHA~1"; echo m > "$W/b.txt"; "${gc[@]}" add b.txt; "${gc[@]}" commit -qm "main moves"
  NEWMAIN=$("${gc[@]}" rev-parse HEAD)
  "${gc[@]}" checkout -q -b lwf-merge "$SHA"; "${gc[@]}" merge -q --no-edit lwf-main; H1=$("${gc[@]}" rev-parse HEAD)
  git -C "$W" push -q "$O" "$NEWMAIN:refs/heads/main" "$H1:refs/pull/201/head"
}
