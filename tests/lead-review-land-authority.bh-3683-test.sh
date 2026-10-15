#!/bin/bash
# tests/lead-review-land-authority.bh-3683-test.sh — BH-3683: the hub land lane,
# bin/lead-review-land.sh, is the lead-verdict authority for a normal PR (no Mac
# anywhere) and records only advice on a PR that touches a protected path. Run
# WHOLE against a scratch harness carrying the real jobs client, lead-verdict.sh
# and bin/lib/lead-authority.sh, with only these stubbed:
#   * curl — a stateful jobs worker (the bh-1951 shape): lead-review list from
#            $T/requests.json, POST/GET /api/verdicts over $T/vrows.json, the
#            promoted stamp, GET /api/settings/<key> (404: no row), and GET
#            /api/lead-protected-paths answered by tests/lib/lpp-stub.sh (the
#            repo's lead_protected_paths rows, $T/lpp.json);
#   * gh   — PR 41's head, its files ($T/files.json), the statuses POST;
#   * $H/bin/lane-alert.sh — records its argv in $T/log/alerts.
#   L1 acceptance 2: an unprotected PR gets a published lead-verdict from the hub
#   L2 acceptance 1: a protected PR gets the row as advice, no status, one beat
#   L3 a withheld MERGE is not spot-checked; a published one still is (item 4)
#   L4 the lane never claims --source human
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land-authority.bh-3683-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

REPO=example-org/cromford
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$H/catalog" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/lead-verdict.sh" "$DIR/bin/lead-review-land.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in env-path lead-reviews verdicts hub-box lane-gate gh-rest gh-app-auth verdict-status lead-authority; do
  [ -f "$DIR/bin/lib/$f.sh" ] && cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
done
# The globs this suite exercises: L2 touches bin/lib/verdict-status.sh, L3/L5 .mergify.yml.
LPP="$T/lpp.json"
lpp_install "$T/fakebin" "$LPP" "$T/lpp-down"
lpp_set "$LPP" "$REPO" .mergify.yml bin/lib/verdict-status.sh
printf '#!/bin/bash\n[ -e "%s" ] && exit 1\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alertfail" "$T/log/alerts" > "$H/bin/lane-alert.sh"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
SHA=$(printf 'a%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/vrows.json" ] || echo '[]' > "$T/vrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-09-30T00:00:00Z"}}'; fi ;;
  # TEST-CHANGE BH-4145: default mode is now lane; this suite pins human-mode behaviour
  "GET /api/settings/lead_authority_mode") out='{"setting":{"key":"lead_authority_mode","value":"human"}}' ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
  "POST /api/verdicts")
    if [ "\$(jq -r .source <<<"\$body")" != box ] && [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      n=\$(jq length "$T/vrows.json")
      row=\$(jq -c --argjson id "\$((n + 1))" '. + {id:\$id, created_at:"2026-09-30T00:00:00Z"}' <<<"\$body")
      jq -c --argjson r "\$row" '. + [\$r]' "$T/vrows.json" > "$T/vrows.tmp" && mv "$T/vrows.tmp" "$T/vrows.json"
      code=201; out=\$(jq -c '{verdict:.}' <<<"\$row")
    fi ;;
  "GET /api/verdicts?"*)
    out=\$(jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
      [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
      | {repo:\$r, pr:\$pr, head:(if \$h == "" then null else \$h end),
         standing:([\$rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | first),
         rows:\$rows, truncated:false}' "$T/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"-X GET repos/"*"/pulls/41/files"*)
    case "\$*" in *"&page=1"*) printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$(cat "$T/files.json")" ;; *) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;; esac ;;
  *"-X GET repos/"*"/pulls/41/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"-X GET repos/"*"/pulls/41"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n' ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" GH_APP_TOKENS=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT GH_TOKEN LEAD_VERDICT_CONTEXT

setreqs() {
  jq -nc --arg h "$SHA" --arg v "$1" --arg r "$REPO" '{requests:[{id:"lr-1", repo:$r, pr:41, head_sha:$h, status:"done",
    verdict:$v, reviewer_model:"stub-model", report_ref:"state/lead-reviews/lr-41.md", promoted_verdict_at:null,
    detail:null, created_at:"2026-09-30T00:00:00Z"}], truncated:false}' > "$T/requests.json"
}
files() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({filename:.})' > "$T/files.json"; }
reset() {
  rm -f "$T/log"/* "$T/vrows.json" "$T/alertfail" "$H/logs/lead-review-land.log" "$H/logs/ALERTS.log"
  scratch_rm "$H/state/lead-review-land"; scratch_rm "$H/state/lead-authority"
  echo box-hub > "$H/state/box-name"
  setreqs MERGE; files README.md
}
tick() { ( cd "$T" && env "$@" bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
LOGF() { cat "$H/logs/lead-review-land.log" 2>/dev/null; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
statuses() { cat "$T/log/gh" 2>/dev/null | grep -c -- '-X POST repos/.*/statuses/'; }
alerts() { cat "$T/log/alerts" 2>/dev/null; }

# ── L1 (acceptance 2): an unprotected PR, the hub alone publishes the status ──
reset; tick
[ "$RC" = 0 ] && ok || bad "L1 rc $RC: $(cat "$T/out")"
P=$(wlog | grep '^POST /api/verdicts ')
[ "$(grep -c . <<<"$P")" = 1 ] && grep -q '"source":"lead"' <<<"$P" && grep -q '"reviewer":"box:box-hub"' <<<"$P" && grep -q 'lead=1$' <<<"$P" \
  && ok || bad "L1 one source=lead row from box:box-hub: $P"
S=$(grep -- "-X POST repos/$REPO/statuses/$SHA" "$T/log/gh" 2>/dev/null)
grep -q -- '-f state=success' <<<"$S" && grep -q -- '-f context=lead-verdict' <<<"$S" && ok || bad "L1 lead-verdict success on the head: $S"
[ "$(wlog | grep -c '^POST /api/lead-reviews/lr-1/promoted ')" = 1 ] && ok || bad "L1 stamped promoted once: $(wlog)"
LOGF | grep -q 'lead review lr-1: MERGE posted as a source=lead row' && ok || bad "L1 the log line: $(LOGF)"
grep -q 'lead-human-needed' <<<"$(alerts)" && bad "L1 a published PR asks no human: $(alerts)" || ok

# ── L2 (acceptance 1 via the lane): a protected PR is advice, not a status ───
reset; files README.md bin/lib/verdict-status.sh; tick
P=$(wlog | grep '^POST /api/verdicts ')
[ "$(grep -c . <<<"$P")" = 1 ] && grep -q '"note":"lead-review:lr-1 report:state/lead-reviews/lr-41.md authority:human-required"' <<<"$P" \
  && ok || bad "L2 the row is posted with the authority token: $P"
[ "$(statuses)" = 0 ] && ok || bad "L2 no status POST on a protected PR: $(grep statuses "$T/log/gh")"
[ "$(wlog | grep -c '^POST /api/lead-reviews/lr-1/promoted ')" = 1 ] && ok || bad "L2 still stamped promoted: $(wlog)"
LOGF | grep -q 'recorded as advice; lead-verdict status withheld' && ok || bad "L2 the log says withheld: $(LOGF)"
LOGF | grep -q 'seen=1 promoted=1 stamped=1' && ok || bad "L2 counted as promoted: $(LOGF | tail -1)"
[ "$(alerts | grep -c -- '--severity warn --id lead-human-needed-')" = 1 ] && alerts | grep -q 'bin/lead-verdict.sh post .* --source human' \
  && ok || bad "L2 exactly one human-needed beat: $(alerts)"
# The stamp is lost: the list still answers the request unpromoted.
tick
[ "$(wlog | grep -c '^POST /api/verdicts ')" = 1 ] && [ "$(alerts | grep -c 'lead-human-needed')" = 1 ] && ok \
  || bad "L2 a second tick posts no second row and sends no second beat: $(alerts)"
[ "$(statuses)" = 0 ] && ok || bad "L2 the stamp-only tick publishes nothing either"

# ── L5: a beat that could not be sent is not stamped, and is asked next tick ─
reset; files .mergify.yml; touch "$T/alertfail"; tick
[ "$(wlog | grep -c '^POST /api/verdicts ')" = 1 ] && [ "$(wlog | grep -c '/promoted ')" = 0 ] && ok \
  || bad "L5 a failed beat: the row is posted, the request is not stamped: $(wlog)"
LOGF | grep -q 'human-needed beat could not be sent; not stamped' && ok || bad "L5 the log says so: $(LOGF)"
rm -f "$T/alertfail"; tick
[ "$(wlog | grep -c '^POST /api/verdicts ')" = 1 ] && [ "$(alerts | grep -c 'lead-human-needed')" = 1 ] && [ "$(wlog | grep -c '/promoted ')" = 1 ] \
  && ok || bad "L5 the next tick asks once and stamps, posting no second row: $(alerts) / $(wlog | grep -c '/promoted ')"
tick
[ "$(alerts | grep -c 'lead-human-needed')" = 1 ] && ok || bad "L5 and never asks twice for the head"

# ── L3: spot-check sampling (item 4) ────────────────────────────────────────
reset; files .mergify.yml; tick LEAD_REVIEW_SPOTCHECK_PCT=100
grep -q 'lead-spotcheck-' <<<"$(alerts)" && bad "L3 a withheld MERGE is not spot-checked: $(alerts)" || ok
reset; tick LEAD_REVIEW_SPOTCHECK_PCT=100
[ "$(alerts | grep -c 'lead-spotcheck-lr-1')" = 1 ] && ok || bad "L3 a published lane MERGE is still sampled: $(alerts)"

# ── L4: the hub never claims to be a human ──────────────────────────────────
grep -n -- '--source human' "$DIR/bin/lead-review-land.sh" && bad "L4 bin/lead-review-land.sh names --source human (the lane must never claim it)" || ok
[ -f "$DIR/bin/lead-review-land.sh" ] && ok || bad "L4 bin/lead-review-land.sh is missing"
grep -q '^POST /api/verdicts .*"source":"human"' <<<"$(wlog)" && bad "L4 the lane posted a human row" || ok

echo "lead-review-land-authority: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
