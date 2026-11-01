#!/bin/bash
# tests/lead-authority-human-retired.bh-5035-test.sh — BH-5035: the `human`
# value of lead_authority_mode is removed, and so is the precision lane's
# human:precision write.
#
# lead_authority_mode accepts only `lane` (no row = lane). A stored `human`
# row is REFUSED at read time: la_decide answers rc 2 (a hold, fail closed)
# with a reason that names BH-5035 and the command that clears the row. It is
# never read as lane, and never as the old "human verdict required" (rc 1).
# Under lane the authority row lead_authority.<owner>.<name> is not read.
# bin/lead-review-precision.sh no longer writes human:precision on a precision
# drop and no longer pages critical for one; its restore arm (human:precision
# back to lane) stays.
#
# Driven against a scratch harness: the real bin/lib/lead-authority.sh,
# bin/lead-verdict.sh, bin/jobs-client.sh and bin/lead-review-precision.sh with
# their source closures. Stubbed: curl (the jobs worker: settings rows in
# $W/set/<key>, lead_protected_paths rows through tests/lib/lpp-stub.sh,
# verdicts), gh (PR files, PR head, statuses, the closed-PR list, commits),
# date (+%s pinned) and bin/lane-alert.sh (records its argv).
#   L1 global human, protected hit → rc 2, the retired reason
#   L2 per-repo human, global lane → rc 2 retired
#   L3 ' Human ' / HUMAN → rc 2 retired (trim, case)
#   L4 per-repo lane, global human → rc 0 (per-repo wins; near miss)
#   L5 no rows, protected hit → rc 0, LA_PROTECTED_HIT=1, the lane reason
#   L6 authority row human:precision, unprotected PR → rc 0, row not read
#   L7 mode 'humans' / 'human:precision' → rc 2 with the garbage reason
#   L8 ungoverned repo, mode row human → rc 0 not governed, no settings read
#   L9 bin/lead-verdict.sh post MERGE --source lead under human → exit 5, no status
#   P1 precision 0.5 < 0.8, no mode row → no write, no critical page, log line
#   P2 same with a stored human mode row → still no write
#   P3 authority row human:precision, precision 1.0 → one write back to lane
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-authority-human-retired.bh-5035-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

IN=example-org/cromford
KEY=example-org.cromford
OUT=example-org/demo-os
HEAD=aaaaaaaa11111111111111111111111111111111
NOW=1793419200            # 2026-10-31T04:00:00Z, pinned: no clock read in this file
MERGED_AT=2026-10-30T04:00:00Z
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W/set" "$T/fakebin" "$T/tmp" "$T/tok"
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
REALDATE=$(command -v date)

H="$T/h"; mkdir -p "$H/logs" "$H/state" "$H/catalog"
for s in bin/lead-verdict.sh bin/jobs-client.sh bin/lead-review-precision.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { bad "could not install the closure of $s"; echo "lead-authority-human-retired.bh-5035: $PASS passed, $FAIL failed"; exit 1; }
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
printf 'lead-test-token-fixture\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

cat > "$T/fakebin/date" <<EOF
#!/bin/bash
[ "\$*" = "+%s" ] && { echo $NOW; exit 0; }
exec "$REALDATE" "\$@"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
okb() { printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$1"; }
case "\$*" in
  *"-X GET repos/"*"/pulls?"*) case "\$*" in *"&page=1"*) okb "\$(cat "$G/pulls1.json" 2>/dev/null || echo '[]')" ;; *) okb '[]' ;; esac ;;
  *"-X GET repos/"*"/commits?"*) case "\$*" in *"&page=1"*) okb "\$(cat "$G/commits.json" 2>/dev/null || echo '[]')" ;; *) okb '[]' ;; esac ;;
  *"-X GET repos/"*"/check-runs"*) okb '{"check_runs":[]}' ;;
  *"-X GET repos/"*"/pulls/"[0-9]*"/files"*)
    case "\$*" in *"&page=1"*) okb "\$(cat "$G/files.json" 2>/dev/null || echo '[]')" ;; *) okb '[]' ;; esac ;;
  *"-X GET repos/"*"/pulls/"[0-9]*) okb "{\"state\":\"open\",\"head\":{\"sha\":\"\$(cat "$G/head")\"}}" ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
  *"-X POST repos/"*"/comments"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":9}\n' ;;
  *) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
exit 0
EOF
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$W/log"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$W/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$W/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "PUT /api/settings") jq -r .value <<<"\$body" > "$W/set/\$(jq -r .key <<<"\$body")"; out='{"ok":true}' ;;
  "GET /api/verdicts?"*)
    if [ -f "$W/vrows.json" ]; then
      out=\$(jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
        [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
        | {repo:\$r, pr:\$pr, head:\$h, rows:\$rows, standing:null, truncated:false}' "$W/vrows.json")
    else out='{"rows":[],"standing":null,"truncated":false}'; fi ;;
  "POST /api/verdicts")
    printf '%s\n' "\$body" >> "$W/posted"
    code=201; out=\$(jq -c '{verdict:(. + {id:21,created_at:"2026-10-31T04:00:00Z"})}' <<<"\$body") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
chmod +x "$T/fakebin/date" "$T/fakebin/gh" "$T/fakebin/curl"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s-fixture JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=box-hub TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" GH_APP_TOKENS=0 \
  LANE_GATE_DISABLE=1 LEAD_REVIEW_AUTO_REPOS="$IN"
unset LEAD_VERDICT_CONTEXT GH_TOKEN BOX_NAME HUB_BOX_NAME LEAD_REVIEW_PRECISION_WINDOW_DAYS LEAD_REVIEW_PRECISION_WARN \
  LEAD_REVIEW_PRECISION_MIN_N LEAD_REVIEW_PRECISION_MAX_PAGES LEAD_REVIEW_AUTHORITY_MIN_PRECISION

reset() {
  rm -f "${G:?}"/* "${W:?}"/log "$W"/posted "$W"/vrows.json "$W"/set/* "$T/alerts" "$H/logs/lead-review-precision.log"
  scratch_rm "$H/state/lead-authority"; scratch_rm "$H/state/lead-review-precision"
  rm -f "$LPPF" "$LPPF.raw" "$LPPF.log" "$DOWNF"
  lpp_set "$LPPF" "$IN" .mergify.yml bin/lib/lead-authority.sh
  echo box-hub > "$H/state/box-name"
  echo "$HEAD" > "$G/head"; echo '[{"filename":"README.md"}]' > "$G/files.json"
}
files() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({filename:.})' > "$G/files.json"; }
setrow() { printf '%s' "$2" > "$W/set/$1"; }
setgets() { local l; l=$(cat "$W/log" 2>/dev/null); grep -c '^GET /api/settings/' <<<"$l"; }
lib() { ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/verdicts.sh" 2>/dev/null
          . "$H/bin/lib/verdict-status.sh" 2>/dev/null; eval "$1" ) 2>"$T/lib.err"; }
decide() { lib "la_decide $1 $2 $HEAD $3; echo \"rc=\$? hit=\${LA_PROTECTED_HIT:-} reason=\${LA_REASON:-}\""; }
rcof() { printf '%s' "${1%% *}"; }
RETIRED="a value BH-5035 retired: delete the row or set it to lane (bin/jobs-client.sh setting-set"

# ── L1: global human → rc 2, the retired reason ─────────────────────────────
reset; files README.md .mergify.yml; setrow lead_authority_mode human
R=$(decide "$IN" 7 lead)
[ "$(rcof "$R")" = rc=2 ] && ok || bad "L1 a global human row must be rc 2 (refused), got: $R ($(cat "$T/lib.err"))"
grep -qF "the mode row lead_authority_mode reads 'human', $RETIRED lead_authority_mode lane)" <<<"$R" && ok \
  || bad "L1 the reason names the row, BH-5035 and the fix: $R"
grep -q ' hit=1 ' <<<"$R" && bad "L1 a refused mode reports no protected hit: $R" || ok

# ── L2: per-repo human over a global lane → rc 2 retired ────────────────────
reset; files .mergify.yml; setrow lead_authority_mode lane; setrow "lead_authority_mode.$KEY" human
R=$(decide "$IN" 7 lead)
[ "$(rcof "$R")" = rc=2 ] && grep -qF "the mode row lead_authority_mode.$KEY reads 'human', $RETIRED lead_authority_mode.$KEY lane)" <<<"$R" && ok \
  || bad "L2 a per-repo human row is rc 2 and names its key: $R"

# ── L3: trim and case ───────────────────────────────────────────────────────
for v in ' Human ' HUMAN; do
  reset; files .mergify.yml; setrow lead_authority_mode "$v"
  R=$(decide "$IN" 7 lead)
  [ "$(rcof "$R")" = rc=2 ] && grep -qF 'BH-5035 retired' <<<"$R" && ok || bad "L3 mode '$v' reads as the retired human: $R"
done
R=$(lib "_la_mode $IN; echo \"rc=\$? \$LA_MODE|\$LA_MODE_SRC|\${LA_MODE_RETIRED:-}\"")
[ "$R" = "rc=2 human|lead_authority_mode|1" ] && ok || bad "L3 _la_mode on HUMAN: rc 2, LA_MODE_RETIRED=1 ($R)"

# ── L4: per-repo lane beats a global human (near miss) ──────────────────────
reset; files .mergify.yml; setrow lead_authority_mode human; setrow "lead_authority_mode.$KEY" lane
R=$(decide "$IN" 7 lead)
[ "$(rcof "$R")" = rc=0 ] && grep -q ' hit=1 ' <<<"$R" && ok || bad "L4 a per-repo lane over a global human is rc 0 with the hit: $R"

# ── L5: no rows, protected hit → rc 0, the lane reason ──────────────────────
reset; files README.md .mergify.yml
R=$(decide "$IN" 7 lead)
[ "$R" = 'rc=0 hit=1 reason=touches protected paths: .mergify.yml; cleared to merge on the lead verdict (lead_authority_mode=lane)' ] && ok \
  || bad "L5 no row = lane: rc 0, the hit, the lane reason: $R"

# ── L6: the authority row is never read ─────────────────────────────────────
reset; setrow "lead_authority.$KEY" human:precision
R=$(decide "$IN" 7 lead)
[ "$R" = 'rc=0 hit= reason=no protected path' ] && ok || bad "L6 a human:precision authority row revokes nothing: $R"
WL=$(cat "$W/log" 2>/dev/null)
grep -q "^GET /api/settings/lead_authority\.$KEY " <<<"$WL" && bad "L6 the authority row must not be read" || ok

# ── L7: other values keep the garbage reason, not the retired one ───────────
for v in humans human:precision; do
  reset; files .mergify.yml; setrow lead_authority_mode "$v"
  R=$(decide "$IN" 7 lead)
  [ "$(rcof "$R")" = rc=2 ] && grep -qF "reads '$v', not lane" <<<"$R" && ok || bad "L7 mode '$v' is rc 2 with the garbage reason: $R"
  grep -qF 'BH-5035' <<<"$R" && bad "L7 mode '$v' is not the retired value: $R" || ok
  grep -qF 'not lane|human' <<<"$R" && bad "L7 the garbage reason no longer offers human: $R" || ok
done

# ── L8: an ungoverned repo never reads the mode ─────────────────────────────
reset; files .mergify.yml; setrow lead_authority_mode human
R=$(decide "$OUT" 41 lead)
[ "$R" = 'rc=0 hit= reason=not governed' ] && [ "$(setgets)" = 0 ] && ok || bad "L8 an ungoverned repo: rc 0, no settings read ($R, $(setgets) reads)"

# ── L9: the real CLI, fail closed ───────────────────────────────────────────
reset; files .mergify.yml; setrow lead_authority_mode human
bash "$H/bin/lead-verdict.sh" post "$IN" 7 "$HEAD" MERGE --source lead --note "lead-review:9" >/dev/null 2>"$T/cli.err"; RC=$?
[ "$RC" = 5 ] && ok || bad "L9 a lead MERGE under a stored human row exits 5 (rc $RC, err $(cat "$T/cli.err"))"
GL=$(cat "$G/calls" 2>/dev/null)
grep -q -- '-X POST repos/.*/statuses/' <<<"$GL" && bad "L9 no status is published" || ok
[ "$(jq -r .note "$W/posted" 2>/dev/null)" = 'lead-review:9 authority:human-required' ] && ok \
  || bad "L9 the row is recorded as advice: $(cat "$W/posted" 2>/dev/null)"
grep -qF 'BH-5035 retired' "$T/cli.err" && ok || bad "L9 stderr names the retired row: $(cat "$T/cli.err")"

# ── P1-P3: bin/lead-review-precision.sh ─────────────────────────────────────
score() { # score <n merged> <n reverted>
  local i n="$1" rv="$2"
  for i in $(seq 11 $((10 + n))); do
    jq -nc --argjson n "$i" --arg s "$(printf 'c%039d' "$i")" --arg m "$MERGED_AT" '{number:$n, merged_at:$m, updated_at:$m, head:{sha:$s}}'
  done | jq -sc . > "$G/pulls1.json"
  for i in $(seq 11 $((10 + n))); do
    jq -nc --argjson id "$i" --argjson pr "$i" --arg h "$(printf 'c%039d' "$i")" --arg r "$IN" \
      '{id:$id, repo:$r, pr:$pr, head_sha:$h, source:"lead", verdict:"MERGE", note:"lead-review:lr-\($pr)"}'
  done | jq -sc . > "$W/vrows.json"
  for i in $(seq 11 $((10 + rv))); do printf 'Revert "thing (#%s)"\n' "$i"; done \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | map({commit:{message:.}})' > "$G/commits.json"
}
prun() { ( cd "$T" && LEAD_REVIEW_AUTHORITY_MIN_PRECISION=0.8 bash "$H/bin/lead-review-precision.sh" ) > "$T/out" 2>&1; RC=$?; }
puts() { local l; l=$(cat "$W/log" 2>/dev/null); grep -c '^PUT /api/settings' <<<"$l"; }
crit() { local l; l=$(cat "$T/alerts" 2>/dev/null); grep -c -- '--severity critical' <<<"$l"; }
PLOG() { cat "$H/logs/lead-review-precision.log" 2>/dev/null; }

reset; score 6 3; prun
[ "$RC" = 0 ] && ok || bad "P1 the precision run exits 0 (rc $RC: $(cat "$T/out"))"
grep -q 'precision 0.5 < 0.8 over n=6' <<<"$(PLOG)" || bad "P1 fixture: the run must score precision 0.5 over n=6: $(PLOG)"
[ "$(puts)" = 0 ] && ok || bad "P1 a low precision writes no settings row: $(grep PUT "$W/log")"
[ "$(crit)" = 0 ] && ok || bad "P1 a low precision pages nobody critical: $(cat "$T/alerts")"
grep -qF "the lane stays the authority (the human mode was removed, BH-5035); lead_authority.$KEY is left alone" <<<"$(PLOG)" && ok \
  || bad "P1 one log line says the row is left alone: $(PLOG)"

reset; score 6 3; setrow lead_authority_mode human; prun
[ "$(puts)" = 0 ] && [ ! -f "$W/set/lead_authority.$KEY" ] && ok || bad "P2 a stored human mode row still gets no human:precision write: $(grep PUT "$W/log")"
[ "$(crit)" = 0 ] && ok || bad "P2 no critical page under a stored human mode row: $(cat "$T/alerts")"

reset; score 6 0; setrow "lead_authority.$KEY" human:precision; prun
[ "$(puts)" = 1 ] && [ "$(cat "$W/set/lead_authority.$KEY")" = lane ] && ok \
  || bad "P3 a legacy human:precision row goes back to lane on recovery: $(grep PUT "$W/log" 2>/dev/null) ($(PLOG))"

echo "lead-authority-human-retired.bh-5035: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
