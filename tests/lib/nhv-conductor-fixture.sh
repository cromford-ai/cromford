#!/bin/bash
# tests/lib/nhv-conductor-fixture.sh — the real bin/merge-conductor.sh over a
# Mergify repo (queue_rules in .mergify.yml) with a fake gh, for the BH-3806
# suites. Sourced (never executed) by a suite that already sourced scratch.sh
# and set DIR; it is the BH-3777 fixture (tests/mc/needs-human-verdict.bh-3777-
# test.sh) made N-PR, plus the two reads BH-3806 adds: the head's combined
# commit status, and the DELETE of our merge-queue label.
#
# THE AUTHORITY STUB. bin/lib/verdict-status.sh is replaced by one whose
# la_decide answers the rc and LA_REASON in $T/la-rc / $T/la-reason (or, per
# call, the next line of $T/la-seq: `<rc>`), and logs every call to
# $T/la-calls.txt, and sets LA_PROTECTED_PATHS from $T/la-paths (BH-9887).
# la_scope answers $T/la-scope (default 0, governed).
# $T/nomemo makes the stub define mc_la_decide as a plain pass-through, which
# overrides the lib's memo (verdict-status.sh is sourced after classify.sh).
#
# The fake gh, per PR <n> (the number is read off the call's path):
#   labels-<n>       the PR's labels, one per line (a label POST adds
#                    merge-queue; a DELETE of it removes it)
#   label-adds.txt   every label POST          label-dels.txt  every DELETE
#   queue-cmds.txt   every comment POST        status-reads.txt every status GET
#   $T/status-mode   none (no lead-verdict) | success | failure | 500
#   $T/del500        the label DELETE answers HTTP 500
# Every assertion reads those files, the rows and the conductor log.
# Callers: tests/mc/nhv-already-labelled.bh-3806-test.sh,
# tests/mc/la-decide-once.bh-3806-test.sh, tests/mc/nhv-other-callers.bh-3806-test.sh.

nhvf_setup() {
  export HARNESS="$T/h"
  mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin" || return 1
  cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" \
     "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/" || return 1
  cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
  mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
  cp "$DIR/bin/lib/block-gate.sh" "$T/h/bin/lib/"
  cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
  mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
  cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/merge-conductor.sh"
  printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
  export FLEET_CONF="$T/h/fleet.conf"
  : > "$T/h/env/global.env"
  printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
  local s
  for s in beat deploy-request pre-arm-guards codegraph-ensure; do
    printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
  done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lead-verdict-calls.txt"\nexit 0\n' "$T" > "$T/h/bin/lead-verdict.sh"; chmod +x "$T/h/bin/lead-verdict.sh"

  cat > "$T/h/bin/lib/verdict-status.sh" <<EOF
la_decide() {
  printf '%s\n' "\$*" >> "$T/la-calls.txt"
  LA_REASON=\$(cat "$T/la-reason" 2>/dev/null)
  LA_PROTECTED_PATHS=\$(cat "$T/la-paths" 2>/dev/null)
  local rc
  if [ -s "$T/la-seq" ]; then rc=\$(head -1 "$T/la-seq"); sed -i 1d "$T/la-seq"
  else rc=\$(cat "$T/la-rc" 2>/dev/null || echo 0); fi
  return "\$rc"
}
la_scope() { return "\$(cat "$T/la-scope" 2>/dev/null || echo 0)"; }
la_human_needed() { printf '%s\n' "\$*" >> "$T/lhn-calls.txt"; return 0; }
vs_publish() { printf '%s\n' "\$*" >> "$T/vs-calls.txt"; return 0; }
vs_context() { echo lead-verdict; }
if [ -e "$T/nomemo" ]; then mc_la_decide() { la_decide "\$1" "\$2" "\$3" conductor; }; fi
EOF

  MGFY_YML=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
CHECK=\$(cat "$T/checkmode" 2>/dev/null || echo none)
N=\$(printf '%s\n' "\$*" | grep -oE '(pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
N=\${N:-0}
HEAD=\$(cat "$T/head-\$N" 2>/dev/null)
LBL=\$(tr '\n' ',' < "$T/labels-\$N" 2>/dev/null | sed 's/,\$//')
Q=""; prev=""; for a in "\$@"; do [ "\$prev" = -q ] && Q="\$a"; prev="\$a"; done
fx() { if [ -n "\$Q" ]; then printf '%s' "\$1" | jq -r "\$Q"; else printf '%s\n' "\$1"; fi; }
case "\$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*"/reviews"*) fx '[]' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*) fx "{\"number\":\$N,\"base\":{\"ref\":\"main\"}}" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    printf '%s\n' "\$*" >> "$T/status-reads.txt"
    case "\$(cat "$T/status-mode" 2>/dev/null || echo none)" in
      success) restpr --raw 200 '{"state":"success","statuses":[{"context":"ci","state":"success"},{"context":"lead-verdict","state":"success"}]}' ;;
      failure) restpr --raw 200 '{"state":"failure","statuses":[{"context":"lead-verdict","state":"failure"}]}' ;;
      500)     restpr --raw 500 '{"message":"boom"}' ;;
      *)       restpr --raw 200 '{"state":"success","statuses":[{"context":"ci","state":"success"}]}' ;;
    esac ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "\$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N" ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    printf '%s\n' "\$*" >> "$T/label-dels.txt"
    [ -e "$T/del500" ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
    grep -vxF 'merge-queue' "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *v3.diff*) restpr --diff '+++ b/catalog/switches.d/x-off.json
+{}
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*) restpr OPEN "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*) restpr --raw 200 "{\"state\":\"closed\",\"number\":\$N}" ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 "{\"state\":\"open\",\"number\":\$N}" ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
  chmod +x "$T/fakebin/curl"
  ROWS="$T/h/state/merge-conductor/pr-state.tsv"
  CLOG="$T/h/logs/merge-conductor.log"
  : > "$T/prs"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}

# nhvf_pr <n> <full-head> — one open PR with a build record approving that head.
nhvf_pr() {
  local n="$1" head="$2" rec="$T/h/builds/pool-mgfy-MG-$1-2026100100"
  printf '%s\n' "$n" >> "$T/prs"; sort -un -o "$T/prs" "$T/prs"
  printf '%s' "$head" > "$T/head-$n"; : > "$T/labels-$n"
  mkdir -p "$rec"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$n" > "$rec/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$rec/review.md"
  printf '%s' "$head" > "$rec/reviewed-sha"
  : > "$rec/pipeline.log"
}

nhvf_list() {
  local n csv lbl
  for n in $(cat "$T/prs"); do
    lbl="[]"
    csv=$(tr '\n' ',' < "$T/labels-$n" 2>/dev/null | sed 's/,$//')
    [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
    printf '{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s}\n' \
      "$n" "$n" "$(cat "$T/head-$n")" "$n" "$lbl"
  done | jq -sc . > "$T/list.json"
}

nhvf_tick() {
  nhvf_list
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_PR_PARALLEL=1 MC_MERGIFY_REASK_TICKS=1 \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }
}

nhvf_clear() {
  local f
  for f in gh-calls.txt merge-calls.txt label-adds.txt label-dels.txt queue-cmds.txt status-reads.txt la-calls.txt lhn-calls.txt vs-calls.txt lead-verdict-calls.txt; do : > "$T/$f"; done
  : > "$CLOG"; : > "$T/h/logs/ALERTS.log"
}

nhvf_la() { echo "$1" > "$T/la-rc"; printf '%s' "$2" > "$T/la-reason"; rm -f "$T/la-seq"; }

# nhvf_reset — a fresh conductor state, every PR unlabelled, and every row
# seeded READY by one tick whose la_decide is undecidable (rc 2: the BH-2199
# hold, which returns before the label POST). Status none, governed, merges on.
nhvf_reset() {
  local n
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/block-gate"
  rm -f "$T/h/state/merge-sweep-done.txt" "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe "$T/del500" "$T/nomemo" "$T/la-scope" 2>/dev/null
  for n in $(cat "$T/prs"); do : > "$T/labels-$n"; done
  echo none > "$T/checkmode"; echo none > "$T/status-mode"
  touch "$T/h/flags/merge-conductor-merge"
  nhvf_la 2 "the files could not be read whole"
  nhvf_clear; nhvf_tick
  echo running > "$T/checkmode"; nhvf_clear
}

# nhvf_field <n> <col> — a column of PR <n>'s row.
nhvf_field() { awk -F'\t' -v k="example-org/mgfy-os#$1" -v n="$2" '$1==k {print $n}' "$ROWS" 2>/dev/null; }
nhvf_count() { local c; c=$(grep -c -- "$1" "$T/$2" 2>/dev/null); echo "${c:-0}"; }
