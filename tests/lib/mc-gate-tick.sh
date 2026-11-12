# shellcheck shell=bash
# tests/lib/mc-gate-tick.sh — BH-9368: one WHOLE bin/merge-conductor.sh tick
# fixture for a Mergify repo whose required checks are `ci`, `e2e-ratchet` and
# `gate` (the project-6 shape). Sourced by the BH-9368 suites, never run.
#
# The caller has sourced tests/lib/scratch.sh (T, scratch_*), and sets DIR (the
# repo root). mgt_setup builds the scratch tree. Every answer comes from a file
# under $BX, so a test changes one file and ticks again:
#   head               the PR head (absent: MGT_H1)
#   runs.json          actions/runs on the head (workflow_runs)
#   jobs-<id>.json     one jobs page of run <id>
#   cr.json            commits/<sha>/check-runs
#   files.json         pulls/31/files
#   content[-<sha8>]   the raw bytes of every contents/<path>?ref=<sha> read
#   st-body            the app's migrations/status answer (absent: {"applied":[]})
#   set/<key>          a settings row
#   dispatch-code      the HTTP status of a workflow dispatch (absent: 204)
#   mergify-nochecks   .mergify.yml names no check-success (no required set)
# And it logs: calls.txt (every gh call), reruns.txt, dispatches.txt,
# queue-posts.txt, contents-reads.txt, status.log, curl-all.log.
# 0 network: the fake gh and curl are first on PATH; mgt_offhost lists any curl
# that left the .test hosts.

MGT_SLUG=example-org/mkey-os
MGT_H1=$(printf 'a%.0s' $(seq 40)); MGT_H2=$(printf 'b%.0s' $(seq 40)); MGT_H3=$(printf 'c%.0s' $(seq 40))

# mgt_setup <frag-or-lib>... — the scratch tree, with these repo paths (and
# their closures) installed beside the conductor. A path that does not exist is
# skipped: that is how a suite runs the tick from before a fragment existed.
mgt_setup() {
  local s
  # shellcheck source=tests/lib/fixture-harness.sh
  . "$DIR/tests/lib/fixture-harness.sh" || return 1
  # shellcheck source=tests/lib/verdict-fixture.sh
  . "$DIR/tests/lib/verdict-fixture.sh" || return 1
  # shellcheck source=tests/lib/gh-list-bridge.sh
  . "$DIR/tests/lib/gh-list-bridge.sh" || return 1
  vpf_export || return 1
  C="$T/w"; CH="$C/h"; BX="$C/fx"
  fx_mc_harness "$DIR" "$C" || return 1
  fx_conductor_tick "$DIR" "$C" || return 1
  ( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh bin/lib/flaky.sh \
      bin/lib/mc-ci-advisory.sh bin/merge-conductor.d/bh-8012-required-ci.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || return 1
  for s in "$@"; do
    [ -r "$DIR/$s" ] || continue
    ( cd "$DIR" && scratch_install_closure "$s" "$CH" >/dev/null ) || return 1
  done
  cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
  printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
  printf 'mkey %s - - 2 box-m\n' "$MGT_SLUG" > "$CH/fleet.conf"
  : > "$CH/env/global.env"
  printf 'DATA_LANE_APP_BASE=http://app.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$CH/env/mkey.env"
  for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/model-calls.txt\nexit 0\n' "$BX" > "$CH/bin/agent-call.sh"; chmod +x "$CH/bin/agent-call.sh"
  MGT_REC="$CH/builds/pool-mkey-TK-31-202611110001"; mkdir -p "$MGT_REC"
  MGT_U="https://github.com/$MGT_SLUG/pull"
  local yml yml0
  yml0=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
  yml=$(printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success=ci\n      - check-success=e2e-ratchet\n      - check-success=gate\n    merge_method: squash\n' | base64 | tr -d '\n')
  mkdir -p "$C/fakebin"
  cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
out=""; w=""; M=GET; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$C/curl-all.log"
emit() {
  if [ -n "\$out" ]; then printf '%s' "\$2" > "\$out"; else printf '%s' "\$2"; fi
  case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$1" ;; *) printf '%s' "\$1" ;; esac
}
case "\$M \$URL" in
  "GET "*/api/internal/migrations/status)
    echo "\$URL" >> "$BX/status.log"
    emit 200 "\$(cat "$BX/st-body" 2>/dev/null || echo '{"applied":[]}')" ;;
  "GET "*/api/settings/*)
    k="\${URL##*/api/settings/}"
    if [ -f "$BX/set/\$k" ]; then emit 200 "\$(jq -nc --arg k "\$k" --arg v "\$(cat "$BX/set/\$k")" '{setting:{key:\$k,value:\$v}}')"
    else emit 404 '{"error":"not found"}'; fi ;;
  "GET "*/api/verdicts\?*) emit 200 "\$(cat "$BX/standing" 2>/dev/null || echo '{"standing":null}')" ;;
  "PUT "*|"POST "*) emit 200 '{"ok":true}' ;;
  *) emit 404 '{"error":"not found"}' ;;
esac
exit 0
EOF
  chmod +x "$C/fakebin/curl"
  for s in claude codex; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/model-calls.txt\nexit 0\n' "$BX" > "$C/fakebin/$s"; chmod +x "$C/fakebin/$s"; done
  cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$BX/calls.txt"
HD=\$(cat "$BX/head" 2>/dev/null || echo "$MGT_H1")
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"run rerun"*|*"/rerun"*) printf '%s\n' "\$*" >> "$BX/reruns.txt" ;;
  *"api -i -X GET repos/$MGT_SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$MGT_SLUG/contents/.mergify.yml"*)
    if [ -e "$BX/mergify-nochecks" ]; then restpr --raw 200 '{"content":"$yml0"}'; else restpr --raw 200 '{"content":"$yml"}'; fi ;;
  *"api -i -X GET repos/$MGT_SLUG/contents/"*)
    printf '%s\n' "\$*" >> "$BX/contents-reads.txt"
    a="\$*"; ref=\${a##*ref=}; ref=\${ref%% *}
    f="$BX/content-\${ref:0:8}"; [ -f "\$f" ] || f="$BX/content"
    if [ -f "\$f" ] && [ ! -e "$BX/content-404" ]; then restpr --raw 200 "\$(jq -nc --arg c "\$(base64 < "\$f" | tr -d '\n')" '{type:"file",encoding:"base64",content:\$c}')"
    else restpr --raw 404 '{"message":"Not Found"}'; fi ;;
  *"api -i -X POST repos/$MGT_SLUG/actions/workflows/"*"/dispatches"*)
    printf '%s\n' "\$*" >> "$BX/dispatches.txt"; restpr --raw "\$(cat "$BX/dispatch-code" 2>/dev/null || echo 204)" '' ;;
  *"actions/runs/"*"/jobs"*) a="\$*"; id=\${a#*actions/runs/}; id=\${id%%/*}; restpr --raw 200 "\$(cat "$BX/jobs-\$id.json" 2>/dev/null || echo '{"total_count":0,"jobs":[]}')" ;;
  *"actions/runs?head_sha="*" -q "*) q=""; while [ \$# -gt 0 ]; do [ "\$1" = -q ] && { q="\$2"; break; }; shift; done; jq -r "\$q" "$BX/runs.json" ;;
  *"actions/runs?head_sha="*) printf '%s\n' "\$*" >> "$BX/runs-reads.txt"; restpr --raw 200 "\$(cat "$BX/runs.json")" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 "\$(cat "$BX/cr.json")" ;;
  *"api -i -X POST repos/$MGT_SLUG/issues/31/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$BX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"issues/31/labels"*) restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$BX/merges.txt"; exit 0 ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$BX/comment-posts.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X POST "*|*"api -X POST "*) restpr --raw 201 '{}' ;;
  *"api -i -X GET repos/$MGT_SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$MGT_SLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/$MGT_SLUG/pulls/31/files"*) restpr --raw 200 "\$(cat "$BX/files.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$MGT_SLUG/pulls/31"*) restpr OPEN "\$HD" ticket/TK-31 main "" MERGEABLE unstable operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$MGT_SLUG -q .id"*) echo 1 ;;
  *"pr list -R $MGT_SLUG --state open"*) jq -c --arg h "\$HD" '.[0].headRefOid = \$h' "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
  chmod +x "$C/fakebin/gh"
  cat > "$C/list.json" <<J
[{"number":31,"url":"$MGT_U/31","headRefOid":"$MGT_H1","headRefName":"ticket/TK-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"UNSTABLE","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[],"updatedAt":"2026-11-09T10:00:00Z"}]
J
  printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
  touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
  CLOG="$CH/logs/merge-conductor.log"; ATT="$CH/state/merge-conductor/attempts.txt"
  return 0
}

# mgt_runs <id|name|conclusion>... — an actions/runs page on the current head.
mgt_runs() {
  local h; h=$(cat "$BX/head" 2>/dev/null || echo "$MGT_H1")
  printf '%s\n' "$@" | jq -Rnc --arg h "$h" '[inputs | select(length > 0) | split("|")
    | {id: (.[0]|tonumber), name: .[1], path: (".github/workflows/" + .[1] + ".yml"), status: "completed",
       conclusion: .[2], run_started_at: "2026-11-09T10:00:00Z", created_at: "2026-11-09T10:00:00Z", run_attempt: 1, head_sha: $h}]
    | {total_count: length, workflow_runs: .}' > "$BX/runs.json"
}
# mgt_jobs <id> <name|conclusion>... — the one jobs page of run <id>.
mgt_jobs() {
  local id="$1"; shift
  printf '%s\n' "$@" | jq -Rnc '[inputs | select(length > 0) | split("|") | {name: .[0], status: "completed", conclusion: .[1]}]
    | {total_count: length, jobs: .}' > "$BX/jobs-$id.json"
}
# mgt_checks <name|conclusion>... — the check-runs page. Its total_count is
# MGT_CR_TOTAL (default 150): a project-6 head holds more check runs than the
# one page of 100 the BH-8012 net reads, so that net stands down (BH-9210 note)
# and only a fresh actions/runs read can see the head green.
mgt_checks() {
  printf '%s\n' "$@" | jq -Rnc --argjson t "${MGT_CR_TOTAL:-150}" '[inputs | select(length > 0) | split("|")
    | {name: .[0], status: "completed", conclusion: .[1], started_at: "2026-11-09T10:00:00Z", completed_at: "2026-11-09T10:10:00Z"}]
    | {total_count: ([$t, length] | max), check_runs: .}' > "$BX/cr.json"
}
# mgt_gate_red — ci and e2e-ratchet green, gate failed, perf-budgets (report only) failed.
mgt_gate_red() {
  mgt_runs '101|CI|success' '103|migration-ledger|failure' '104|perf|failure'
  mgt_jobs 101 'ci|success' 'e2e-ratchet|success'
  mgt_jobs 103 'gate|failure'
  mgt_jobs 104 'perf-budgets (report only)|failure'
  mgt_checks 'ci|success' 'e2e-ratchet|success' 'gate|failure' 'perf-budgets (report only)|failure'
}
# mgt_gate_green — the same head with gate green; only the report-only check red.
mgt_gate_green() {
  mgt_runs '101|CI|success' '103|migration-ledger|success' '104|perf|failure'
  mgt_jobs 101 'ci|success' 'e2e-ratchet|success'
  mgt_jobs 103 'gate|success'
  mgt_jobs 104 'perf-budgets (report only)|failure'
  mgt_checks 'ci|success' 'e2e-ratchet|success' 'gate|success' 'perf-budgets (report only)|failure'
}
# mgt_gate_ci_red — gate AND ci failed.
mgt_gate_ci_red() {
  mgt_runs '101|CI|failure' '103|migration-ledger|failure'
  mgt_jobs 101 'ci|failure' 'e2e-ratchet|success'
  mgt_jobs 103 'gate|failure'
  mgt_checks 'ci|failure' 'e2e-ratchet|success' 'gate|failure'
}
# mgt_sql [bytes] — the PR adds prisma/sql/20261109150013_own_google_send_config.sql.
MGT_SQLP=prisma/sql/20261109150013_own_google_send_config.sql
MGT_SQLN=20261109150013_own_google_send_config
mgt_sql() {
  printf '[{"filename":"%s","status":"added"},{"filename":"src/a.ts","status":"modified"}]\n' "$MGT_SQLP" > "$BX/files.json"
  printf '%s' "${1:-CREATE TABLE own_google_send_config (id int);
}" > "$BX/content"
  echo 'prisma/sql/*.sql' > "$BX/set/mc_migration_hold.globs.mkey"
}
# mgt_sum [file] — the sha256 of the content fixture.
mgt_sum() { sha256sum < "${1:-$BX/content}" | cut -c1-64; }
# mgt_ledger <checksum> — production holds the SQL file at <checksum>.
mgt_ledger() { jq -nc --arg f "$MGT_SQLN.sql" --arg c "$1" '{applied:[{filename:$f, checksum:$c, appliedAt:"2026-11-09T12:00:00Z", actor:"fixture-operator"}], pending:[]}' > "$BX/st-body"; }

# mgt_fresh [head] — a clean slate: state, logs, fixture answers, the build record.
mgt_fresh() {
  scratch_rm "$CH/state"; scratch_rm "$BX"; mkdir -p "$CH/state" "$BX/set"
  : > "$CLOG"; : > "$CH/logs/ALERTS.log"; rm -f "$C/curl-all.log"
  local h="${1:-$MGT_H1}"; echo "$h" > "$BX/head"
  echo "PR_CREATED $MGT_U/31" > "$MGT_REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$MGT_REC/review.md"
  echo "$h" > "$MGT_REC/reviewed-sha"; : > "$MGT_REC/pipeline.log"
  jq -nc '{standing:{verdict:"MERGE-WITH-NOTES",source:"lead",id:5334,created_at:"2026-11-09T15:20:00Z",report_url:"-",reviewer:"lead"}}' > "$BX/standing"
}
# mgt_head <sha> — the PR moves to <sha>; the review is bound to it.
mgt_head() { echo "$1" > "$BX/head"; echo "$1" > "$MGT_REC/reviewed-sha"; }
# mgt_tick [env...] — one conductor tick; state carries over until mgt_fresh.
mgt_tick() {
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_RED_RERUN_SETTLE_SECS=0 "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
}
mgt_n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
# mgt_row — the stored row's `state|reason`.
mgt_row() { awk -F'\t' -v k="$MGT_SLUG#31" '$1==k {print $2 "|" $7}' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
mgt_log() { grep '#31' "$CLOG" 2>/dev/null | tail -"${1:-6}" | cut -c1-300; }
mgt_alerts() { grep -c "${1:-.}" "$CH/logs/ALERTS.log" 2>/dev/null || true; }
mgt_offhost() { awk '{print $2}' "$C/curl-all.log" 2>/dev/null | grep -vE '^https?://[a-z0-9.-]+\.test(/|$)' || true; }
