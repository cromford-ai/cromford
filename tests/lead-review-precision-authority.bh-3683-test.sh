#!/bin/bash
# tests/lead-review-precision-authority.bh-3683-test.sh — BH-3683: when the lead
# lane's MERGE precision drops under LEAD_REVIEW_AUTHORITY_MIN_PRECISION, the
# daily precision run flips the repo's authority row to human:precision and pages
# ONCE; it flips back when precision recovers, and never touches an operator's
# `human`. Runs the real bin/lead-review-precision.sh (and, for R1's tail, the
# real bin/lead-verdict.sh) against a scratch harness with only these stubbed:
#   * curl — the jobs worker: GET /api/verdicts from $T/vrows.json, GET/PUT
#            /api/settings over $T/set/<key> ($T/set503 = GET outage, $T/put500 =
#            PUT refused), POST /api/verdicts, and GET /api/lead-protected-paths
#            answered by tests/lib/lpp-stub.sh (rows in $T/lpp.json, $T/lpp-down
#            = 500) — the repo is governed by its lead_protected_paths rows;
#   * gh   — the closed-PR list ($T/pulls1.json), main's commits
#            ($T/commits.json), check runs (none), PR heads, PR files
#            ($T/files.json), the statuses POST;
#   * date — `date +%s` answers the suite's pinned NOW (+1 day once $T/nextday
#            exists), everything else is the real date;
#   * $H/bin/lane-alert.sh — records `rc=<n> <argv>` in $T/log/alerts and exits
#            with $T/alertrc (default 0).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-precision-authority.bh-3683-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$H/catalog" "$T/fakebin" "$T/log" "$T/tmp" "$T/set" "$T/tok"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/lead-verdict.sh" "$DIR/bin/lead-review-precision.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in env-path hub-box lane-gate gh-rest gh-app-auth verdict-status verdicts lead-reviews lead-authority; do
  [ -f "$DIR/bin/lib/$f.sh" ] && cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
done
LPP="$T/lpp.json"; LPPDOWN="$T/lpp-down"
lpp_install "$T/fakebin" "$LPP" "$LPPDOWN"
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

NOW=$(date +%s)
IN=$(date -u -d "@$((NOW - 86400))" +%Y-%m-%dT%H:%M:%SZ)
REPO=example-org/cromford
KEY=lead_authority.example-org.cromford
sha() { printf 'c%039d' "$1"; }
REALDATE=$(command -v date)

cat > "$T/fakebin/date" <<EOF
#!/bin/bash
if [ "\$*" = "+%s" ]; then
  if [ -e "$T/nextday" ]; then echo \$(( $NOW + 86400 )); else echo $NOW; fi
  exit 0
fi
exec "$REALDATE" "\$@"
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
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/verdicts?"*)
    out=\$(jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
      [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
      | {repo:\$r, pr:\$pr, head:\$h, rows:\$rows, standing:null, truncated:false}' "$T/vrows.json") ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -e "$T/set503" ]; then code=503; out='{"error":"down"}'
    elif [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "PUT /api/settings")
    if [ -e "$T/put500" ]; then code=500; out='{"error":"boom"}'
    else jq -r .value <<<"\$body" > "$T/set/\$(jq -r .key <<<"\$body")"; out='{"ok":true}'; fi ;;
  "POST /api/verdicts") code=201; out=\$(jq -c '{verdict:(. + {id:31,created_at:"2026-09-30T00:00:00Z"})}' <<<"\$body") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
p=""; prev=""; m=""
for a in "\$@"; do [ "\$prev" = -X ] && { m="\$a"; p=next; }; [ "\$p" = next ] && [ "\$a" != "\$m" ] && p="\$a"; prev="\$a"; done
okf() { printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$(cat "\$1")"; }
okb() { printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$1"; }
case "\$m \$p" in
  "GET repos/"*"/pulls?"*)
    [ -e "$T/pulls500" ] && { printf 'HTTP/1.1 500 Boom\r\n\r\n{"message":"boom"}\n'; exit 1; }
    case "\$p" in *"&page=1") okf "$T/pulls1.json" ;; *) okb '[]' ;; esac ;;
  "GET repos/"*"/commits?"*) case "\$p" in *"&page=1") okf "$T/commits.json" ;; *) okb '[]' ;; esac ;;
  "GET repos/"*"/check-runs"*) okb '{"check_runs":[]}' ;;
  "GET repos/"*"/pulls/"*"/files"*) case "\$p" in *"&page=1"*) okf "$T/files.json" ;; *) okb '[]' ;; esac ;;
  "GET repos/"*"/pulls/"*) n=\${p##*/}; okb "{\"head\":{\"sha\":\"\$(printf 'c%039d' "\$n")\"}}" ;;
  "POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
  *) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
rc=\$(cat "$T/alertrc" 2>/dev/null || echo 0)
printf 'rc=%s %s\n' "\$rc" "\$*" >> "$T/log/alerts"
exit "\$rc"
EOF
chmod +x "$T/fakebin/date" "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_REVIEW_AUTO_REPOS="$REPO" GH_APP_TOKENS=0 \
  LEAD_VERDICT_TOKEN_FILE="$T/tok/lead"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME GH_TOKEN LEAD_REVIEW_PRECISION_WINDOW_DAYS LEAD_REVIEW_PRECISION_WARN \
  LEAD_REVIEW_PRECISION_MIN_N LEAD_REVIEW_PRECISION_MAX_PAGES LEAD_REVIEW_AUTHORITY_MIN_PRECISION LEAD_VERDICT_CONTEXT

# score <prs...> -- <reverted prs...> : every PR merged yesterday with a lead MERGE
score() {
  local n i=0 pr=() rv=() side=pr
  for n in "$@"; do [ "$n" = -- ] && { side=rv; continue; }; if [ "$side" = pr ]; then pr+=("$n"); else rv+=("$n"); fi; done
  for n in "${pr[@]}"; do
    jq -nc --argjson n "$n" --arg s "$(sha "$n")" --arg m "$IN" '{number:$n, merged_at:$m, updated_at:$m, head:{sha:$s}}'
  done | jq -sc . > "$T/pulls1.json"
  for n in "${pr[@]}"; do
    i=$((i+1))
    jq -nc --argjson id "$i" --argjson pr "$n" --arg h "$(sha "$n")" --arg r "$REPO" \
      '{id:$id, repo:$r, pr:$pr, head_sha:$h, source:"lead", verdict:"MERGE", note:"lead-review:lr-\($pr)"}'
  done | jq -sc . > "$T/vrows.json"
  for n in ${rv[@]+"${rv[@]}"}; do printf 'Revert "thing (#%s)"\n' "$n"; done \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | map({commit:{message:.}})' > "$T/commits.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{pulls500,set503,put500,alertrc,nextday} "$T/set"/* "$H/logs/lead-review-precision.log"
  rm -f "$LPP" "$LPP.log" "$LPPDOWN"
  scratch_rm "$H/state/lead-review-precision"
  scratch_rm "$H/state/lead-authority"
  lpp_set "$LPP" "$REPO" .mergify.yml bin/lib/lead-authority.sh
  echo box-hub > "$H/state/box-name"
  echo '[{"filename":"README.md"}]' > "$T/files.json"
  # TEST-CHANGE BH-4145: default mode is now lane; this suite pins human-mode behaviour
  printf human > "$T/set/lead_authority_mode"
  score 11 12 13 14 15 -- 12 13
}
run() { ( cd "$T" && env "$@" bash "$H/bin/lead-review-precision.sh" ) > "$T/out" 2>&1; RC=$?; }
puts() { cat "$T/log/worker" 2>/dev/null | grep -c '^PUT /api/settings'; }
lastput() { grep '^PUT /api/settings' "$T/log/worker" 2>/dev/null | tail -1 | cut -d' ' -f3-; }
crit() { cat "$T/log/alerts" 2>/dev/null | grep -c '^rc=0 --severity critical --id lead-authority-revoked-'; }
LOGF() { cat "$H/logs/lead-review-precision.log" 2>/dev/null; }
owed() { ls "$H/state/lead-review-precision/"authority-page-owed-* 2>/dev/null | wc -l | tr -d ' '; }

# ── R1 (acceptance 3): precision 0.6 < 0.8 revokes the lane and pages once ───
reset; run LEAD_REVIEW_AUTHORITY_MIN_PRECISION=0.8
[ "$RC" = 0 ] && ok || bad "R1 rc $RC: $(cat "$T/out")"
[ "$(puts)" = 1 ] && [ "$(lastput | jq -r '.key + "=" + .value')" = "$KEY=human:precision" ] && ok \
  || bad "R1 one PUT of $KEY=human:precision: $(grep PUT "$T/log/worker" 2>/dev/null)"
[ "$(crit)" = 1 ] && grep -q 'REVOKED: precision 0.6 under 0.8' "$T/log/alerts" && grep -q "setting-set $KEY lane" "$T/log/alerts" \
  && ok || bad "R1 exactly one critical revocation page: $(cat "$T/log/alerts" 2>/dev/null)"
# The lane's next MERGE on an UNPROTECTED PR is advice only now.
bash "$H/bin/lead-verdict.sh" post "$REPO" 11 "$(sha 11)" MERGE --source lead > /dev/null 2> "$T/lv.err"; RC=$?
[ "$RC" = 5 ] && grep -q 'lane authority revoked' "$T/lv.err" && ok || bad "R1 a lane MERGE after revocation exits 5 naming it (rc $RC, $(cat "$T/lv.err"))"
grep -q -- '-X POST repos/.*/statuses/' "$T/log/gh" && bad "R1 no status is published after revocation" || ok

# ── R2: pages once — same day, next day, still 0.6 ──────────────────────────
run; run
touch "$T/nextday"; run
[ "$(puts)" = 1 ] && [ "$(crit)" = 1 ] && ok || bad "R2 no second PUT or page (puts $(puts), pages $(crit)): $(cat "$T/log/alerts")"

# ── R3: a failed page is owed and paid first on the next run ────────────────
reset; echo 1 > "$T/alertrc"; run
[ "$(puts)" = 1 ] && [ "$(owed)" = 1 ] && [ "$(crit)" = 0 ] && ok || bad "R3 the page failed: marker written (puts $(puts), owed $(owed))"
rm -f "$T/alertrc"; run
[ "$(crit)" = 1 ] && [ "$(owed)" = 0 ] && [ "$(puts)" = 1 ] && ok || bad "R3 the owed page is sent and the marker removed (pages $(crit), owed $(owed), puts $(puts))"
run
[ "$(crit)" = 1 ] && ok || bad "R3 and it is not sent a second time"

# ── R4: a failed PUT pages nobody and owes nothing ──────────────────────────
reset; touch "$T/put500"; run
[ "$(crit)" = 0 ] && [ "$(owed)" = 0 ] && [ ! -f "$T/set/$KEY" ] && ok || bad "R4 no page, no marker on a failed PUT"
[ "$(LOGF | grep -c 'could not write the authority row')" = 1 ] && ok || bad "R4 one log line: $(LOGF)"

# ── R5: recovery restores lane; an operator's human is sticky ───────────────
reset; score 11 12 13 14 15; echo human:precision > "$T/set/$KEY"; run
[ "$(lastput | jq -r '.key + "=" + .value')" = "$KEY=lane" ] && ok || bad "R5 precision 1.0 restores lane: $(lastput)"
[ "$(cat "$T/log/alerts" 2>/dev/null | grep -c '^rc=0 --severity warn --id lead-authority-restored-')" = 1 ] && ok || bad "R5 one warn restore beat: $(cat "$T/log/alerts")"
reset; score 11 12 13 14 15; echo human > "$T/set/$KEY"; run
[ "$(puts)" = 0 ] && ok || bad "R5 a precision recovery never touches an operator's human row"
reset; echo human > "$T/set/$KEY"; run
[ "$(puts)" = 0 ] && [ "$(crit)" = 0 ] && ok || bad "R5 a low precision does not rewrite an operator's human row or page"

# ── R6: too few, an errored repo, or an unreadable row: nothing changes ─────
reset; score 11 12 13 14 -- 12 13; run
[ "$(puts)" = 0 ] && [ "$(crit)" = 0 ] && ok || bad "R6 lead_merge 4 < MIN_N 5 changes nothing"
reset; touch "$T/pulls500"; run
[ "$(puts)" = 0 ] && ok || bad "R6 an errored repo changes nothing"
reset; touch "$T/set503"; run
[ "$(puts)" = 0 ] && [ "$(crit)" = 0 ] && ok || bad "R6 a settings outage changes nothing"
LOGF | grep -q "authority row .* could not be read" && ok || bad "R6 the outage is logged: $(LOGF)"

# ── R7: the knob is validated and registered ───────────────────────────────
reset; run LEAD_REVIEW_AUTHORITY_MIN_PRECISION=1.5
LOGF | grep -q "LEAD_REVIEW_AUTHORITY_MIN_PRECISION='1.5' is not a number in \[0,1\]; using 0.8" && ok || bad "R7 1.5 falls back to 0.8: $(LOGF)"
[ "$(lastput | jq -r .value)" = human:precision ] && ok || bad "R7 and the fallback 0.8 still revokes at 0.6"
K=$(jq -c '.knobs[] | select(.env == "LEAD_REVIEW_AUTHORITY_MIN_PRECISION") | [.type, .default, .min, .max]' "$DIR/catalog/lanes.d/lead-review-precision.json")
[ "$K" = '["float",0.8,0,1]' ] && ok || bad "R7 the knob is registered float 0.8 in [0,1]: '$K'"
reset; run LEAD_REVIEW_AUTHORITY_MIN_PRECISION=0.5
[ "$(puts)" = 0 ] && ok || bad "R7 a threshold of 0.5 does not revoke at 0.6"

# ── R8: a scored repo with no lead_protected_paths rows is named, not governed
reset; run LEAD_REVIEW_AUTO_REPOS="$REPO example-org/demo-os"
[ "$(LOGF | grep -c 'example-org/demo-os: scored but not governed: no live lead_protected_paths rows')" = 1 ] && ok || bad "R8 one 'not governed' line: $(LOGF)"
grep -q 'lead_authority.example-org.demo-os' "$T/log/worker" && bad "R8 an ungoverned repo's row is never read" || ok

# ── R9 (BH-4145): under lead_authority_mode=lane a drop revokes nothing ─────
# No mode row is the default lane. The row would be inert, so it is not written
# and no critical page claims every PR now needs a human verdict.
reset; rm -f "$T/set/lead_authority_mode"; run LEAD_REVIEW_AUTHORITY_MIN_PRECISION=0.8
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(crit)" = 0 ] && [ "$(owed)" = 0 ] && ok \
  || bad "R9 lane: no PUT, no critical page, nothing owed (rc $RC, puts $(puts), pages $(crit), owed $(owed)): $(cat "$T/log/alerts" 2>/dev/null)"
[ "$(LOGF | grep -c 'lead_authority_mode=lane (no row), so nothing is withheld')" = 1 ] && ok || bad "R9 one log line names the mode: $(LOGF)"
printf lane > "$T/set/lead_authority_mode"; run LEAD_REVIEW_AUTHORITY_MIN_PRECISION=0.8
[ "$(puts)" = 0 ] && [ "$(crit)" = 0 ] && ok || bad "R9 an explicit lane row behaves the same (puts $(puts), pages $(crit))"
# ── R10 (BH-4148): the rows are unreadable (route 500, no cache): authority unchanged ──
reset; touch "$LPPDOWN"; run LEAD_REVIEW_AUTHORITY_MIN_PRECISION=0.8
[ ! -e "$H/state/lead-authority/globs-example-org_cromford.cache" ] && ok || bad "R10 no cache exists to fall back to"
grep -q '^GET /api/lead-protected-paths' "$T/log/worker" && ok || bad "R10 the run asked the worker for the rows: $(cat "$T/log/worker" 2>/dev/null)"
[ "$(LOGF | grep -c "$REPO: protected paths unreadable (jobs worker, no fresh cache); held: authority unchanged")" = 1 ] && ok || bad "R10 one 'held: authority unchanged' line: $(LOGF)"
[ "$(puts)" = 0 ] && [ ! -f "$T/set/$KEY" ] && ok || bad "R10 the authority row is never written: $(grep PUT "$T/log/worker" 2>/dev/null)"
grep -q "$KEY" "$T/log/worker" && bad "R10 the authority row is not even read: $(grep "$KEY" "$T/log/worker")" || ok
[ "$(crit)" = 0 ] && [ "$(owed)" = 0 ] && ok || bad "R10 nothing is paged or owed (pages $(crit), owed $(owed))"

echo "lead-review-precision-authority: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
