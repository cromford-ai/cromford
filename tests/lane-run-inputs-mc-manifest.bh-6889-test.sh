#!/bin/bash
# tests/lane-run-inputs-mc-manifest.bh-6889-test.sh — BH-6889 (BH-6881.5): the
# merge-conductor lane manifest pair, catalog/lane-run-inputs.d/merge-conductor.ro
# and .rw, and the `$repokey` path-line token of bin/lib/lane-run-inputs.sh.
#
# The fixture is the K1 shape of the BH-6495 conductor suite, rebuilt here: a
# rich hub root holds project mgfy (example-org/mgfy-os, READY PR #31, record
# builds/pool-mgfy-MG-31-*) and a decoy project mgfyc
# (example-org/mgfy-os-console) with its own record, pr-state rows and markers.
#
#   T1a the snapshot of mgfy is extracted into a machine root with the code
#       closure; one `merge-conductor-pr.sh mgfy example-org/mgfy-os#31 <head>`
#       run there, and the same run on the hub, read only files the .ro (or
#       the .rw) allows. A read is an atime move (every file starts with
#       atime < mtime); with strace on PATH an openat trace is checked too.
#   T1b every file the run writes, outside the machine-local set that the .rw
#       NOT CARRIED block names, is allowed by the .rw.
#   T1c the run on the hub and on the machine print the same PROF line and
#       leave the same mgfy row (columns 1-3 and 7); a machine copy with
#       flags/main-red-mgfy prints another PROF line
#   T2  lri_paths merge-conductor mgfy ro|rw parse; the .rw has the literal
#       pr-state.tsv line and one @rows line whose ERE ends in `#`, no @row
#   R1  the snapshot's pr-state.tsv holds the mgfy rows only (mixed case in;
#       mgfy-os-console, mgfy-osx and xexample-org rows out)
#   R2  a write-back that adds a mgfy-os-console row is rejected; the same
#       write-back without it applies
#   K1  lri_paths prints the $repokey lines with the folded repo
#   K2  the $repokey glob takes this repo's markers and refuses the decoys'
#   K3  a project with no repo: one `lri:` line, rc 1; the fold keeps case
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-run-inputs-mc-manifest.bh-6889-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO/bin/lib/lane-run-inputs.sh"
MRO="$REPO/catalog/lane-run-inputs.d/merge-conductor.ro"
MRW="$REPO/catalog/lane-run-inputs.d/merge-conductor.rw"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
unset REGISTRY_SOURCE HARNESS H
# A lane machine image carries the lane registry (catalog/*, pulled with main):
# bin/lib/main-red-gate.sh resolves MC_MAIN_RED_TEST_PATHS from it.
DIR="$REPO"
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
REG=$(rendered_registry) || exit 1
export LRI_MANIFEST_DIR="$REPO/catalog/lane-run-inputs.d"
# ONE clock read: the prequeue marker must be fresh for the run, and every
# fixture mtime is derived from it.
NOW=$(date -u +%s)
LANE=merge-conductor

KSLUG=example-org/mgfy-os; CSLUG=example-org/mgfy-os-console
KHEAD=$(printf 'a%.0s' {1..40}); KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
KB="$T/fakebin"; mkdir -p "$KB"

# ---------------------------------------------------------------------------
# The jobs client, stubbed in-shell (the BH-6719 shape). Every request is one
# line in $T/req.log; a PUT or POST body is kept as $T/body.<n>. GET <api>
# answers 404 (no current snapshot), GET <api>/writebacks answers
# $T/wblist.json, GET <api>/writebacks/<id> answers $T/wb-<id>.json.
export JOBS_HTTP=200
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/req.log"
  case "$1 $2" in
    "GET "*/writebacks) cat "$T/wblist.json" 2>/dev/null || echo '{"writebacks":[]}' ;;
    "GET "*/writebacks/*) cat "$T/wb-${2##*/}.json" ;;
    "GET "*) return 2 ;;
    *) printf '%s' "${3:-}" > "$T/body.$(wc -l < "$T/req.log")"; echo '{"id":1}' ;;
  esac
}
_jobs_req_file() {
  printf '%s %s\n' "$1" "$2" >> "$T/req.log"
  cp "$3" "$T/body.$(wc -l < "$T/req.log")"; echo '{"id":1}'
}
setting_get() { return 1; }
_jobs_box_name() { echo fixture-box; }
# L <root> <cmd...> — one call of the lib in a subshell rooted at <root>.
L() { local r="$1"; shift; ( export HARNESS="$r" FLEET_CONF="$r/fleet.conf"; . "$LIB" || exit 99; "$@" ); }
# SNAP <out.tgz> — the snapshot the last publish PUT, reassembled.
SNAP() { local f; : > "$1"
  for f in $(grep -n '^PUT ' "$T/req.log" | cut -d: -f1); do jq -j .b64 "$T/body.$f" | base64 -d >> "$1"; done; }
SHA() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# The stub gh and curl of the BH-6495 K1 fixture.
cp "$REPO/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$REPO/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
cat > "$T/list.json" <<J
[{"number":31,"url":"$KU/31","headRefOid":"$KHEAD","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
jq -nc --arg r "$KSLUG" --arg h "$KHEAD" '[{number:31, html_url:("https://github.com/"+$r+"/pull/31"), title:"t", draft:false, state:"open",
  updated_at:"2026-10-11T00:00:00Z", created_at:"2026-10-10T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
  head:{sha:$h, ref:"ticket/mg-31", repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]' > "$T/rest-list.json"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$KB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *"api -i -X GET repos/$KSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$KSLUG/commits/main"*|*"api -i -X GET repos/$KSLUG/git/ref/heads/main"*) restpr --raw 200 '{"sha":"$KMAIN","object":{"sha":"$KMAIN"}}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":2,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"},{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":"In merge queue"},"app":{"slug":"mergify"}}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*|*"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/cmds.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$T/merges.txt"; exit 1 ;;
  *"issue close"*|*"-X PATCH repos/"*"/issues/"*) printf '%s\n' "\$*" >> "$T/closes.txt" ;;
  *"api -i -X GET repos/$KSLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*|*"api --paginate repos/"*"/reviews"*) echo '[]' ;;
  *"api repos/"*"/comments --paginate"*) : ;;
  *"api repos/$KSLUG/issues/31"*) printf '{"number":31,"state":"open","labels":[],"body":""}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*) restpr OPEN "$KHEAD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls?state=open"*) restpr --raw 200 "\$(cat "$T/rest-list.json")" ;;
  *"api -i -X GET repos/"*"/pulls?state=open"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*|*"api -i -X GET repos/"*"/pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api repos/$KSLUG -q .id"*) echo 1 ;;
  *"pr list -R $KSLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$KB/gh"
cat > "$KB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/lead-protected-paths*) "$KB/lpp-answer" GET "\$URL"; exit 0 ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$KB/curl"
# shellcheck source=tests/lib/lpp-stub.sh
. "$REPO/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$T/lpp.json" "$KSLUG"
lpp_install "$KB" "$T/lpp.json" "$T/lpp-down"

# CODE <root> — what a lane machine image holds: the conductor's code closure,
# the repo-tracked catalog file it reads, an empty env, and the stub lanes.
CODE() {
  local r="$1" s
  mkdir -p "$r/bin/lib" "$r/logs" "$r/state" "$r/flags" "$r/locks" "$r/builds" "$r/env" "$r/tmp" "$r/catalog" || return 1
  scratch_install_closure bin/merge-conductor-pr.sh "$r" >/dev/null || return 1
  scratch_install_closure bin/merge-conductor.sh "$r" >/dev/null || return 1
  scratch_install_closure bin/jobs-client.sh "$r" >/dev/null || return 1
  scratch_install_closure bin/fleet-conf.sh "$r" >/dev/null || return 1
  cp "$REPO/catalog/lead-protected-paths.seed.tsv" "$r/catalog/" || return 1
  for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$r/bin/$s.sh"; done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$r/bin/lane-alert.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$r/bin/alert-line.sh"
  chmod +x "$r/bin/"*.sh
  : > "$r/env/global.env"
}

PS=state/merge-conductor/pr-state.tsv
MREC=builds/pool-mgfy-MG-31-202610110001
CREC=builds/pool-mgfyc-MG-7-202610110002
PQ="state/merge-conductor/prequeue/example-org_mgfy-os_31_${KHEAD}_${KMAIN}"
# HUBDATA <root> — the hub's data: fleet.conf, both records, the flags, the
# pr-state rows (one mgfy row in mixed case, three decoy repos) and markers of
# both projects. Every file gets mtime NOW-3600.
HUBDATA() {
  local r="$1" m
  printf '%s\n' "mgfy $KSLUG - - 2 box-m" "mgfyc $CSLUG - - 2 box-m" "mgfyn - - - 2 box-m" > "$r/fleet.conf"
  mkdir -p "$r/$MREC" "$r/$CREC" || return 1
  echo "PR_CREATED $KU/31" > "$r/$MREC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$r/$MREC/review.md"
  echo "$KHEAD" > "$r/$MREC/reviewed-sha"; : > "$r/$MREC/pipeline.log"
  echo "PR_CREATED https://github.com/$CSLUG/pull/7" > "$r/$CREC/RESULT"; printf 'TIER: 2\nVERDICT: APPROVE\n' > "$r/$CREC/review.md"
  touch "$r/flags/merge-conductor-actions" "$r/flags/merge-conductor-merge"
  mkdir -p "$r/state/merge-conductor/prequeue" || return 1
  printf 'green %s 1 -\n' "$NOW" > "$r/$PQ"
  printf 'green %s 1 -\n' "$NOW" > "$r/state/merge-conductor/prequeue/example-org_mgfy-os-console_31_${KHEAD}_${KMAIN}"
  {
    printf '%s#31\tREADY\t%s\t%s\t%s\t-\tclean, approved, checks green\t%s/31\n' "$KSLUG" "$((NOW - 600))" "$KHEAD" "$KHEAD" "$KU"
    printf 'example-org/MGFY-OS#40\tMERGED\t%s\t-\t-\t-\tmerged\t%s/40\n' "$((NOW - 900))" "$KU"
    printf '%s#31\tREADY\t%s\t-\t-\t-\tready\thttps://github.com/%s/pull/31\n' "$CSLUG" "$((NOW - 600))" "$CSLUG"
    printf 'example-org/mgfy-osx#2\tREADY\t%s\t-\t-\t-\tready\thttps://github.com/example-org/mgfy-osx/pull/2\n' "$((NOW - 600))"
    printf 'xexample-org/mgfy-os#3\tREADY\t%s\t-\t-\t-\tready\thttps://github.com/xexample-org/mgfy-os/pull/3\n' "$((NOW - 600))"
  } > "$r/$PS"
  for m in stuck/example-org_mgfy-os_31_READY_abc stuck/example-org_mgfy-os-console_31_READY_abc stuck/example-org_mgfy-osx_2_READY_abc \
           ready-why/example-org_mgfy-os-console_31 closed-watch/example-org_mgfy-os-console/31 head-lag/example-org_mgfy-os-console_31; do
    mkdir -p "$r/state/merge-conductor/$(dirname "$m")" && printf 'fixture\n' > "$r/state/merge-conductor/$m"
  done
  ( cd "$r" && find builds flags state fleet.conf -exec touch -h -d "@$((NOW - 3600))" {} + )
}

# AT_RESET <root> — every non-code file gets atime 2 h before its mtime, so
# under relatime the first read moves it. AT_LIST <root> — path TAB atime TAB
# mtime of every file, sorted.
AT_RESET() { ( cd "$1" && find . -type f ! -path './bin/*' -printf '%P\t%T@\n' | while IFS=$'\t' read -r f m; do
    touch -a -d "@$(( ${m%.*} - 7200 ))" "$f"; done ); }
AT_LIST() { ( cd "$1" && find . -type f -printf '%P\t%A@\t%T@\n' | LC_ALL=C sort ); }
# READS <before> <after> — files whose atime moved and mtime did not.
# WRITES <before> <after> — files whose mtime moved, and new files.
READS() { join -t$'\t' "$1" "$2" | awk -F'\t' '$2 != $4 && $3 == $5 {print $1}'; }
WRITES() { { join -t$'\t' "$1" "$2" | awk -F'\t' '$3 != $5 {print $1}'; join -v2 -t$'\t' "$1" "$2" | cut -f1; } | LC_ALL=C sort -u; }
# The machine-local set: code, secrets, locks, caches, logs and the per-tick
# state the .rw NOT CARRIED block names. Nothing here rides in either direction.
LOCAL_ERE='^(bin|catalog|env|locks|tmp|logs)/|^state/(flags-cache|gh-[^/]*|heartbeat|heartbeat-done|lane-gate|lead-authority|merge-conductor-pr|pr-snapshot|fanin|lane-run-inputs|settings-cache\.json|box-name)(/|$)|^state/merge-conductor/(tick/|attempts\.txt$|rereviews-[0-9]{8}\.txt$|lane-epoch$|hold-reminder-at$|diffs/)|\.lock$'

# RUN <root> [VAR=value...] — one `merge-conductor-pr.sh mgfy <key> <head>` run,
# as a lane-run machine starts it. PROF is its PROF line, RRC its exit code.
RUN() {
  local r="$1"; shift
  PROF=$( cd "$T" && env PATH="$KB:$PATH" HARNESS="$r" HARNESS_SECRET=secret-fixture-1 JOBS_URL=http://worker.test GH_TOKEN=pat-fixture \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$r/fleet.conf" LANE_REGISTRY="$REG" LANE_RUN_ID=t1 "$@" \
    bash "$r/bin/merge-conductor-pr.sh" mgfy "$KSLUG#31" "$KHEAD" 2>"$T/run.err" | grep '^PROF mc-pr' )
  RRC=$?
}
# ROW <root> — the mgfy #31 row's columns 1-3 and 7.
ROW() { awk -F'\t' -v k="$KSLUG#31" '$1 == k {print $1 "\t" $2 "\t" $3 "\t" $7}' "$1/$PS" 2>/dev/null; }
# CHECK <case> <mode> <root> <file-of-paths> — each path outside the
# machine-local set passes lri_member_ok <mode>; NOK holds the refused ones.
CHECK() {
  local c="$1" mode="$2" r="$3" f="$4" p n=0
  NOK=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [[ $p =~ $LOCAL_ERE ]] && continue
    n=$((n + 1))
    L "$r" lri_member_ok mgfy "$p" - "$mode" "$LANE" || NOK+="$p "
  done < "$f"
  [ -z "$NOK" ] && ok "$c every one of the $n traced paths is in the .$mode allow-list" || bad "$c not in the .$mode allow-list: $NOK"
}

# ============================================================================
H0="$T/h0"; CODE "$H0" || { echo "setup: code closure failed"; exit 1; }
HUBDATA "$H0" || { echo "setup: hub data failed"; exit 1; }

echo "T2: the manifest pair parses"
ERR=$(L "$H0" lri_paths "$LANE" mgfy ro 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$ERR" ] && ok "T2 lri_paths ro rc 0, no lri: line" || bad "T2 ro rc=$rc: $ERR"
RWOUT=$(L "$H0" lri_paths "$LANE" mgfy rw 2>"$T/t2.err"); rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/t2.err" ] && ok "T2 lri_paths rw rc 0, no lri: line" || bad "T2 rw rc=$rc: $(cat "$T/t2.err")"
[ -f "$MRO" ] && [ -f "$MRW" ] && ok "T2 both manifest files exist" || bad "T2 missing $MRO or $MRW"
grep -qxF "$PS" "$MRW" 2>/dev/null && ok "T2 the .rw holds the literal $PS line" || bad "T2 no literal $PS line in the .rw"
NROWS=$(grep -c '^@rows[[:space:]]' "$MRW" 2>/dev/null)
ROWSLINE=$(grep '^@rows[[:space:]]' "$MRW" 2>/dev/null)
[ "$NROWS" = 1 ] && [ "$(awk '{print $2}' <<<"$ROWSLINE")" = "$PS" ] && [[ $(awk '{print $3}' <<<"$ROWSLINE") == *'#' ]] \
  && ok "T2 exactly one @rows line, on $PS, its ERE ends in # ($ROWSLINE)" || bad "T2 @rows lines=$NROWS: $ROWSLINE"
grep -q '^@row[[:space:]]' "$MRW" "$MRO" 2>/dev/null && bad "T2 an @row line is present" || ok "T2 no @row line"

# ============================================================================
echo "K1: the \$repokey lines print with the folded repo"
grep -qxF 'state/merge-conductor/stuck/example-org_mgfy-os_*' <<<"$RWOUT" \
  && ok "K1 rw prints state/merge-conductor/stuck/example-org_mgfy-os_*" || bad "K1 rw: $RWOUT"
grep -q 'repokey' <<<"$RWOUT$(L "$H0" lri_paths "$LANE" mgfy ro 2>/dev/null)" && bad "K1 an unreplaced \$repokey is printed" \
  || ok "K1 no \$repokey is left in the printed lines"

echo "K2: the \$repokey glob takes this repo's markers only"
for p in stuck/example-org_mgfy-os_31 stuck/example-org_mgfy-os_31_READY_abc stuck/example-org_mgfy-os_31_READY_x \
         ready-why/example-org_mgfy-os_31 closed-watch/example-org_mgfy-os/31; do
  L "$H0" lri_member_ok mgfy "state/merge-conductor/$p" - rw "$LANE" && ok "K2 rw accepts $p" || bad "K2 rw refuses $p"
done
for p in stuck/example-org_mgfy-os-console_31 stuck/example-org_mgfy-os-console_31_READY_x stuck/example-org_mgfy-osx_2 \
         ready-why/example-org_mgfy-os-console_31 closed-watch/example-org_mgfy-os-console/31 stuck/example-org_mgfy-os_31; do
  for m in rw ro; do
    L "$H0" lri_member_ok mgfy "state/merge-conductor/$p" - "$m" "$LANE" && bad "K2 $m accepts the decoy $p" || ok "K2 $m refuses the decoy $p"
  done
done

echo "K3: \$repokey with no repo is one lri: line"
# The real pair: the @rows line (parsed first) or a $repokey line refuses it.
for p in mgfyn ghost; do
  ERR=$(L "$H0" lri_paths "$LANE" "$p" rw 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] && [[ $ERR =~ ^lri:\ .*/merge-conductor\.rw:[0-9]+:\ .*no\ repo\ for\ $p\ in\ fleet\.conf$ ]] \
    && ok "K3 $p: the merge-conductor pair is rc 1, one line ($ERR)" || bad "K3 $p: rc=$rc err=$ERR"
  L "$H0" lri_member_ok "$p" "$PS" - rw "$LANE" && bad "K3 $p: lri_member_ok accepts under a bad manifest" || ok "K3 $p: lri_member_ok refuses"
done
# A manifest of $repokey path lines only, so the token's own error is the one.
mkdir -p "$T/mk"
printf '%s\n' '# fixture lane' 'state/k/plain/$p.txt' 'state/k/$repokey_*' 'state/k/two/$repokey/*' > "$T/mk/klane.rw"
printf '%s\n' 'dotted example-org/My.Repo - - 2 box-m' 'odd example-org/x+y@z - - 2 box-m' 'norepo - - - 2 box-m' > "$T/mk/fleet.conf"
for p in norepo ghost; do
  ERR=$( (export LRI_MANIFEST_DIR="$T/mk"; L "$T/mk" lri_paths klane "$p" rw) 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s\n' "$ERR" | wc -l)" = 1 ] && [ "$ERR" = "lri: $T/mk/klane.rw:3: \$repokey: no repo for $p in fleet.conf" ] \
    && ok "K3 $p: \$repokey is rc 1 and one line ($ERR)" || bad "K3 $p: rc=$rc err=$ERR"
done
OUT=$( (export LRI_MANIFEST_DIR="$T/mk"; L "$T/mk" lri_paths klane dotted rw) 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$OUT" = $'state/k/plain/dotted.txt\nstate/k/example-org_My.Repo_*\nstate/k/two/example-org_My.Repo/*' ] \
  && ok "K3 the fold keeps case and . (example-org/My.Repo -> example-org_My.Repo); a line with no token is unchanged" || bad "K3 dotted rc=$rc: $OUT"
OUT=$( (export LRI_MANIFEST_DIR="$T/mk"; L "$T/mk" lri_paths klane odd rw) 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(sed -n 2p <<<"$OUT")" = 'state/k/example-org_x_y_z_*' ] \
  && ok "K3 every char outside [A-Za-z0-9._-] folds to _ (example-org/x+y@z -> example-org_x_y_z)" || bad "K3 odd rc=$rc: $OUT"

# ============================================================================
echo "R1: the snapshot's pr-state.tsv holds the mgfy rows only"
: > "$T/req.log"
PUB=$(L "$H0" lri_publish "$LANE" mgfy 2>"$T/pub.err"); rc=$?
SNAP "$T/snap.tgz"
[ "$rc" = 0 ] && [ -s "$T/snap.tgz" ] && ok "R1 lri_publish rc 0 ($PUB)" || bad "R1 publish rc=$rc: $PUB $(cat "$T/pub.err")"
GOT=$(tar -xzOf "$T/snap.tgz" "$PS" 2>/dev/null | cut -f1)
[ "$GOT" = $'example-org/mgfy-os#31\nexample-org/MGFY-OS#40' ] && ok "R1 the member is the two mgfy rows, the mixed-case one included" \
  || bad "R1 member keys: $(tr '\n' ' ' <<<"$GOT")"
for d in 'example-org/mgfy-os-console#' 'example-org/mgfy-osx#' 'xexample-org/mgfy-os#'; do
  grep -qF "$d" <<<"$GOT" && bad "R1 a $d row rides" || ok "R1 no $d row"
done
MEMBERS=$(tar -tzf "$T/snap.tgz" 2>/dev/null | sed 's#/$##')
grep -qE 'mgfy-os-console|mgfy-osx|mgfyc' <<<"$MEMBERS" && bad "R1 a decoy member rides: $(grep -E 'mgfy-os-console|mgfy-osx|mgfyc' <<<"$MEMBERS" | tr '\n' ' ')" \
  || ok "R1 no member of mgfyc, mgfy-os-console or mgfy-osx rides"
for want in "$MREC/RESULT" "$MREC/review.md" "$MREC/reviewed-sha" "$PQ" fleet.conf flags/merge-conductor-actions \
            state/merge-conductor/stuck/example-org_mgfy-os_31_READY_abc; do
  grep -qxF "$want" <<<"$MEMBERS" && ok "R1 the snapshot carries $want" || bad "R1 the snapshot lacks $want"
done

# ============================================================================
echo "R2: a write-back that adds a mgfy-os-console row is rejected"
BASE=$(tar -xzOf "$T/snap.tgz" "$PS" 2>/dev/null | sha256sum | cut -d' ' -f1)
# WB <case> <extra line or empty> — a write-back of pr-state.tsv: the mgfy rows
# with #31 MERGED, plus <extra>; served as write-back 1.
WB() {
  local w="$T/wb-$1"
  mkdir -p "$w/.lri" "$w/state/merge-conductor"
  printf '%s\t%s\n' "$PS" "$BASE" > "$w/.lri/base.tsv"; : > "$w/.lri/deletions"
  tar -xzOf "$T/snap.tgz" "$PS" | sed "s/^$(printf '%s' "$KSLUG" | sed 's#/#\\/#')#31\tREADY/$(printf '%s' "$KSLUG" | sed 's#/#\\/#')#31\tMERGED/" > "$w/$PS"
  [ -z "$2" ] || printf '%s\n' "$2" >> "$w/$PS"
  tar --owner=0 --group=0 --numeric-owner --format=gnu -czf "$w.tgz" -C "$w" "$PS" .lri/base.tsv .lri/deletions || return 1
  jq -n --rawfile b <(base64 -w0 "$w.tgz") --arg s "$(SHA "$w.tgz")" '{sha:$s, b64:$b}' > "$T/wb-1.json"
  jq -n --arg s "$(SHA "$w.tgz")" '{writebacks:[{id:1, sha:$s}]}' > "$T/wblist.json"
}
H2="$T/h2"; cp -a "$H0" "$H2"; B2=$(SHA "$H2/$PS")
WB console "$(printf '%s#32\tREADY\t1\t-\t-\t-\tready\thttps://github.com/%s/pull/32' "$CSLUG" "$CSLUG")"
APPLIED=$(L "$H2" lri_apply_pending "$LANE" mgfy 2>/dev/null); rc=$?
[ "$APPLIED" = "applied=0 conflicts=0 rejected=1" ] && ok "R2 the console row: $APPLIED" || bad "R2 console rc=$rc: $APPLIED"
[ "$(SHA "$H2/$PS")" = "$B2" ] && ok "R2 the hub pr-state.tsv is unchanged" || bad "R2 file changed: $(cat "$H2/$PS")"
WB plain ""
APPLIED=$(L "$H2" lri_apply_pending "$LANE" mgfy 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$APPLIED" = "applied=1 conflicts=0 rejected=0" ] && ok "R2 control, the mgfy rows only: $APPLIED" || bad "R2 control rc=$rc: $APPLIED"
[ "$(awk -F'\t' -v k="$KSLUG#31" '$1 == k {print $2}' "$H2/$PS")" = MERGED ] && grep -qF "$CSLUG#31" "$H2/$PS" \
  && ok "R2 control: #31 is MERGED on the hub and the console row stays" || bad "R2 control file: $(cat "$H2/$PS")"
rm -f "$T/wblist.json" "$T/wb-1.json"

# ============================================================================
echo "T1: one machine run on the snapshot, one on the hub"
S0="$T/s0"; CODE "$S0" || { echo "setup: machine code failed"; exit 1; }
tar -xzf "$T/snap.tgz" -C "$S0" --no-same-owner 2>/dev/null || bad "T1 the snapshot does not extract"
SA="$T/sa"; SB="$T/sb"; HA="$T/ha"
cp -a "$S0" "$SA"; cp -a "$S0" "$SB"; cp -a "$H0" "$HA"
touch -d "@$((NOW - 3600))" "$SB/flags/main-red-mgfy"

# The atime probe: does a read move atime on this mount?
printf 'probe\n' > "$T/atime-probe"; touch -d "@$((NOW - 3600))" "$T/atime-probe"; touch -a -d "@$((NOW - 10800))" "$T/atime-probe"
A0=$(stat -c %X "$T/atime-probe"); cat "$T/atime-probe" >/dev/null; A1=$(stat -c %X "$T/atime-probe")
ATIME=1; [ "$A0" != "$A1" ] || { ATIME=0; echo "SKIP T1-trace: atime does not move on this mount"; }

AT_RESET "$SA"; AT_LIST "$SA" > "$T/sa.before"
RUN "$SA"; PROF_SA="$PROF"; RC_SA="$RRC"
AT_LIST "$SA" > "$T/sa.after"
AT_RESET "$HA"; AT_LIST "$HA" > "$T/ha.before"
RUN "$HA"; PROF_HA="$PROF"; RC_HA="$RRC"
AT_LIST "$HA" > "$T/ha.after"
RUN "$SB"; PROF_SB="$PROF"
echo "  (machine: rc=$RC_SA $PROF_SA; hub: rc=$RC_HA $PROF_HA; machine+main-red: $PROF_SB)"

echo "T1a: every file the run reads is in the .ro"
READS "$T/sa.before" "$T/sa.after" > "$T/sa.reads"; READS "$T/ha.before" "$T/ha.after" > "$T/ha.reads"
if [ "$ATIME" = 1 ]; then
  for want in "$MREC/review.md" "$MREC/RESULT" "$PQ" fleet.conf; do
    grep -qxF "$want" "$T/ha.reads" && ok "T1a the hub trace shows the read of $want" || bad "T1a the hub trace lacks $want: $(tr '\n' ' ' < "$T/ha.reads")"
  done
  CHECK "T1a machine:" ro "$SA" "$T/sa.reads"
  # On the hub mc_record_for (bin/lib/mc/classify.sh:488) globs every
  # project's builds/*/RESULT to find the PR's record, so it also opens the
  # decoy's. Those reads are the glob's, not an input: the machine has none of
  # them, and T1c shows its outcome is the same.
  grep -E '^builds/(pool-|fly-)?mgfyc-' "$T/ha.reads" > "$T/ha.other"
  grep -vE '^builds/(pool-|fly-)?mgfyc-' "$T/ha.reads" > "$T/ha.own"
  grep -qxF "$CREC/RESULT" "$T/ha.other" && ok "T1a the hub run opens the mgfyc RESULT through the record glob, and only that of mgfyc ($(wc -l < "$T/ha.other"))" \
    || bad "T1a the hub run did not open $CREC/RESULT: $(tr '\n' ' ' < "$T/ha.other")"
  CHECK "T1a hub:" ro "$HA" "$T/ha.own"
  grep -qE 'mgfyc|mgfy-os-console' "$T/sa.reads" && bad "T1a the machine read a decoy file: $(grep -E 'mgfyc|mgfy-os-console' "$T/sa.reads")" \
    || ok "T1a the machine read no mgfyc or mgfy-os-console file"
fi
if command -v strace >/dev/null 2>&1; then
  SC="$T/sc"; cp -a "$S0" "$SC"
  ( cd "$T" && env PATH="$KB:$PATH" HARNESS="$SC" HARNESS_SECRET=secret-fixture-1 JOBS_URL=http://worker.test GH_TOKEN=pat-fixture \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$SC/fleet.conf" LANE_REGISTRY="$REG" LANE_RUN_ID=t1 \
    strace -f -qq -e trace=openat -o "$T/strace.out" bash "$SC/bin/merge-conductor-pr.sh" mgfy "$KSLUG#31" "$KHEAD" >/dev/null 2>&1 )
  grep -v ' = -1 ' "$T/strace.out" | grep -oE "\"$SC/[^\"]+\"" | tr -d '"' | sed "s#^$SC/##" | LC_ALL=C sort -u \
    | while IFS= read -r p; do [ -f "$SC/$p" ] && printf '%s\n' "$p"; done > "$T/sc.opens"
  [ -s "$T/sc.opens" ] && ok "T1a strace saw $(wc -l < "$T/sc.opens") opened files" || bad "T1a strace saw no open"
  CHECK "T1a strace:" ro "$SC" "$T/sc.opens"
else
  echo "  (T1a strace: not on PATH; the atime trace and T1c stand)"
fi

echo "T1b: every file the run writes is in the .rw"
WRITES "$T/sa.before" "$T/sa.after" > "$T/sa.writes"; WRITES "$T/ha.before" "$T/ha.after" > "$T/ha.writes"
# The inventory, for the reader: what the machine run read and wrote outside
# the machine-local set.
echo "  (machine reads: $(grep -vE "$LOCAL_ERE" "$T/sa.reads" | tr '\n' ' '))"
echo "  (machine writes: $(grep -vE "$LOCAL_ERE" "$T/sa.writes" | tr '\n' ' '))"
for want in "$PS" state/merge-conductor/ready-why/example-org_mgfy-os_31; do
  grep -qxF "$want" "$T/sa.writes" && ok "T1b the machine run wrote $want" || bad "T1b the machine run did not write $want: $(tr '\n' ' ' < "$T/sa.writes")"
done
CHECK "T1b machine:" rw "$SA" "$T/sa.writes"
CHECK "T1b hub:" rw "$HA" "$T/ha.writes"

echo "T1c: the snapshot is enough (the hub and the machine agree)"
[ -n "$PROF_SA" ] && [ "$PROF_SA" = "$PROF_HA" ] && ok "T1c the same PROF line on the hub and the machine ($PROF_SA)" \
  || bad "T1c PROF hub='$PROF_HA' machine='$PROF_SA'; $(tail -3 "$T/run.err")"
[ "$RC_SA" = "$RC_HA" ] && ok "T1c the same exit code ($RC_SA)" || bad "T1c rc hub=$RC_HA machine=$RC_SA"
RSA=$(ROW "$SA"); RHA=$(ROW "$HA")
[ -n "$RSA" ] && [ "$RSA" = "$RHA" ] && ok "T1c the same mgfy #31 row, columns 1-3 and 7 ($(tr '\t' '|' <<<"$RSA"))" \
  || bad "T1c row hub='$RHA' machine='$RSA'"
[ -n "$PROF_SB" ] && [ "$PROF_SB" != "$PROF_SA" ] && ok "T1c flags/main-red-mgfy in the snapshot changes the run ($PROF_SB)" \
  || bad "T1c the main-red flag changed nothing: '$PROF_SB' vs '$PROF_SA'"
grep -q "$KSLUG MAIN_RED_FREEZE in force (flags/main-red-mgfy" "$SB/logs/merge-conductor.log" 2>/dev/null \
  && grep -q "$KSLUG#31 READY and HELD by the main-red freeze" "$SB/logs/merge-conductor.log" \
  && ok "T1c the machine run reads the flag from the snapshot and holds #31 (MAIN_RED_FREEZE)" \
  || bad "T1c no MAIN_RED_FREEZE hold in the machine log: $(grep -i 'main.red' "$SB/logs/merge-conductor.log" 2>/dev/null | tail -2) $(tail -2 "$T/run.err")"

echo
echo "lane-run-inputs-mc-manifest.bh-6889: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
exit 0
