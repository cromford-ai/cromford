#!/bin/bash
# tests/lead-authority-mode.bh-4145-test.sh — BH-4145: the settings row
# lead_authority_mode (per repo lead_authority_mode.<owner>.<name>, else
# global; no row = lane). Under lane a protected-path hit is REPORTED, not
# withheld: la_decide answers rc 0 with LA_PROTECTED_HIT=1, a lead MERGE
# publishes lead-verdict: success and leaves ONE PR comment per head, and
# la_human_needed pages nobody. Under human, BH-3683 exactly.
# Driven against a scratch harness carrying the real bin/lib/lead-authority.sh
# and the real bin/lead-verdict.sh, with the fake gh/curl/lane-alert of
# tests/lead-authority.bh-3683-test.sh plus:
#   * GET /api/lead-protected-paths — tests/lib/lpp-stub.sh, rows in $LPPF
#     seeded with the cromford globs (demo-os has none);
#   * $W/set503.<key> — that one settings key answers 503;
#   * POST repos/*/issues/*/comments answers $G/comment-status (default 201),
#     every body logged to $G/comments.
#   M1 no mode row = lane: hit rc 0, the lane reason, LA_PROTECTED_HIT=1; the REPRO
#   M2 global human = today's rc 1 and string
#   M3 per-repo beats global both ways; ' Lane ' / HUMAN normalise
#   M4 lane never reads lead_authority.<k>, human:precision/human revoke nothing
#   M5 human + human:precision on an unprotected PR = rc 1 revoked
#   M6 source human = rc 0, no read at all
#   M7 la_human_needed: lane pages nobody; human (or unreadable) pages once
#   M8 bin/lead-verdict.sh post under lane: success, one comment, dedupe, 500 retry
#   M9 every hold (rc 2) and every non-hit
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-authority-mode.bh-4145-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/lead-authority.sh"
CLI="$DIR/bin/lead-verdict.sh"
[ -f "$LIB" ] && [ -f "$CLI" ] && ok || bad "bin/lib/lead-authority.sh and bin/lead-verdict.sh must exist"

IN=example-org/cromford
KEY=example-org.cromford
OUT=example-org/demo-os
HEAD=aaaaaaaa11111111111111111111111111111111
HEAD2=bbbbbbbb22222222222222222222222222222222
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W/set" "$T/fakebin" "$T/tmp" "$T/tok"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
# The cromford lead_protected_paths rows: every cromford glob of catalog/lead-protected-paths.seed.tsv,
# as listed in the fixture below (suite F of lead-authority-db.bh-4148 pins the two equal).
BH_GLOBS_F="$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    for a in "\$@"; do case "\$a" in body=*) printf '%s\n' "\${a#body=}" >> "$G/comments" ;; esac; done
    st=\$(cat "$G/comment-status" 2>/dev/null || echo 201)
    restpr --raw "\$st" '{"id":9}' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/files"*)
    : > "$G/filesread"
    [ -e "$G/files500" ] && { restpr --raw 500 '{"message":"boom"}'; exit 0; }
    case "\$*" in
      *"&page=1"*) restpr --raw 200 "\$(cat "$G/files.json" 2>/dev/null || echo '[]')" ;;
      *) restpr --raw 200 '[]' ;;
    esac ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    if [ -e "$G/filesread" ] && [ -f "$G/head-after-files" ]; then restpr OPEN "\$(cat "$G/head-after-files")"
    else restpr OPEN "\$(cat "$G/head")"; fi ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *) echo "" ;;
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
printf '%s %s\n' "\$m" "\$p" >> "$W/log"
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -e "$W/set503" ] || [ -e "$W/set503.\$k" ]; then code=503; out='{"error":"down"}'
    elif [ -f "$W/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$W/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/verdicts")
    printf '%s\n' "\$body" >> "$W/posted"
    code=201; out=\$(jq -c '{verdict:(. + {id:21,created_at:"2026-10-03T10:00:00Z"})}' <<<"\$body") ;;
  "GET /api/verdicts?"*) out='{"rows":[],"standing":null,"truncated":false}' ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state"
cp "$CLI" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in verdict-status gh-rest gh-app-auth env-path lead-reviews verdicts hub-box lane-gate; do
  [ -f "$DIR/bin/lib/$f.sh" ] && cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
done
cp "$LIB" "$H/bin/lib/lead-authority.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=box-hub TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" GH_APP_TOKENS=0
unset LEAD_VERDICT_CONTEXT GH_TOKEN

reset() {
  rm -f "${G:?}"/* "${W:?}"/log "$W"/posted "$W"/set503* "$W"/set/* "$T/alerts"
  scratch_rm "$H/state/lead-authority"
  rm -f "$LPPF" "$LPPF.raw" "$LPPF.log" "$DOWNF"; set -f; lpp_set "$LPPF" "$IN" $(cat "$BH_GLOBS_F"); set +f
  echo "$HEAD" > "$G/head"; echo '[{"filename":"README.md"}]' > "$G/files.json"
}
files() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({filename:.})' > "$G/files.json"; }
setrow() { printf '%s' "$2" > "$W/set/$1"; }
ghlog() { cat "$G/calls" 2>/dev/null; }
statuses() { ghlog | grep -c -- '-X POST repos/.*/statuses/'; }
ncomments() { ghlog | grep -c -- "-X POST repos/$IN/issues/7/comments"; }
setgets() { cat "$W/log" 2>/dev/null | grep -c '^GET /api/settings/'; }
lib() { ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/verdicts.sh" 2>/dev/null
          . "$H/bin/lib/verdict-status.sh" 2>/dev/null; eval "$1" ) 2>"$T/lib.err"; }
decide() { lib "la_decide $1 $2 $HEAD $3; echo \"rc=\$? hit=\${LA_PROTECTED_HIT:-} reason=\${LA_REASON:-}\""; }
rcof() { printf '%s' "${1%% *}"; }
cli() { bash "$H/bin/lead-verdict.sh" "$@" 2>"$T/cli.err"; }
MARK="$H/state/lead-authority/lane-hit-example-org_cromford-7-${HEAD:0:12}"

# ── M1: no mode row = lane ─────────────────────────────────────────────────
reset; files README.md .mergify.yml
R=$(decide "$IN" 7 lead)
[ "$(rcof "$R")" = rc=0 ] && ok || bad "M1 no mode row: a protected hit is rc 0 ($R; $(cat "$T/lib.err"))"
grep -qF 'reason=touches protected paths: .mergify.yml; cleared to merge on the lead verdict (lead_authority_mode=lane)' <<<"$R" && ok \
  || bad "M1 the lane reason names the path ($R)"
grep -q ' hit=1 ' <<<"$R" && ok || bad "M1 LA_PROTECTED_HIT=1 ($R)"
grep -q "^GET /api/settings/lead_authority\.$KEY\$" "$W/log" && bad "M1 lane must not read the authority row" || ok
# The plan's REPRO, verbatim but for _jobs_req (BH-4140: the globs are DB rows; one row here).
REPRO=$(cd "$DIR" && bash -c 'setting_get(){ return 2; }; _jobs_req(){ echo "{\"rows\":[{\"repo\":\"example-org/cromford\",\"glob\":\".mergify.yml\",\"removed_at\":null}]}"; }; gh_rest(){ case "$2" in *"/files"*) echo "[{\"filename\":\".mergify.yml\"}]";; *) echo "{\"head\":{\"sha\":\"aaaaaaaa11111111111111111111111111111111\"}}";; esac; }; . bin/lib/lead-authority.sh; rc=0; la_decide example-org/cromford 1 aaaaaaaa11111111111111111111111111111111 lead || rc=$?; echo "rc=$rc $LA_REASON"; [ "$rc" = 0 ]'); RC=$?
[ "$RC" = 0 ] && [ "$REPRO" = 'rc=0 touches protected paths: .mergify.yml; cleared to merge on the lead verdict (lead_authority_mode=lane)' ] && ok \
  || bad "M1 the plan's REPRO exits 0 (rc $RC: $REPRO)"
reset; files .mergify.yml bin/lead-verdict.sh bin/lib/verdicts.sh bin/merge-conductor.sh rules/settings.json bin/secret-read-guard.py
R=$(decide "$IN" 7 lead)
[ "$(rcof "$R")" = rc=0 ] && grep -q '+1 more; cleared to merge on the lead verdict' <<<"$R" && ok || bad "M1 six hits truncate to five, +1 more ($R)"

# ── M2: global human = BH-3683 ─────────────────────────────────────────────
reset; files README.md .mergify.yml; setrow lead_authority_mode human
R=$(decide "$IN" 7 lead)
[ "$R" = 'rc=1 hit= reason=touches protected paths: .mergify.yml' ] && ok || bad "M2 global human = today's rc 1 and string ($R)"

# ── M3: per-repo beats global, normalisation ───────────────────────────────
reset; files .mergify.yml; setrow lead_authority_mode human; setrow "lead_authority_mode.$KEY" lane
R=$(decide "$IN" 7 lead); [ "$(rcof "$R")" = rc=0 ] && ok || bad "M3 global human + per-repo lane = rc 0 ($R)"
reset; files .mergify.yml; setrow lead_authority_mode lane; setrow "lead_authority_mode.$KEY" human
R=$(decide "$IN" 7 lead); [ "$(rcof "$R")" = rc=1 ] && ok || bad "M3 global lane + per-repo human = rc 1 ($R)"
grep -q '^GET /api/settings/lead_authority_mode$' "$W/log" && bad "M3 a per-repo row means the global is never read" || ok
reset; files .mergify.yml; setrow lead_authority_mode ' Lane '
R=$(decide "$IN" 7 lead); [ "$(rcof "$R")" = rc=0 ] && ok || bad "M3 ' Lane ' normalises to lane ($R)"
reset; files .mergify.yml; setrow "lead_authority_mode.$KEY" HUMAN
R=$(decide "$IN" 7 lead); [ "$(rcof "$R")" = rc=1 ] && ok || bad "M3 HUMAN normalises to human ($R)"
R=$(lib "_la_mode $IN; echo \"rc=\$? \$LA_MODE|\$LA_MODE_SRC\"")
[ "$R" = "rc=0 human|lead_authority_mode.$KEY" ] && ok || bad "M3 _la_mode names the row it read ($R)"
reset; R=$(lib "_la_mode $IN; echo \"rc=\$? \$LA_MODE|\$LA_MODE_SRC\"")
[ "$R" = "rc=0 lane|no row" ] && ok || bad "M3 _la_mode with no row = lane (no row) ($R)"

# ── M4: lane ignores the authority row ─────────────────────────────────────
for v in human:precision human; do
  reset; files .mergify.yml; setrow "lead_authority.$KEY" "$v"
  R=$(decide "$IN" 7 lead)
  [ "$(rcof "$R")" = rc=0 ] && ok || bad "M4 lane + lead_authority=$v = rc 0 ($R)"
  grep -q "^GET /api/settings/lead_authority\.$KEY\$" "$W/log" && bad "M4 the authority row is never requested under lane ($v)" || ok
done

# ── M5: human + human:precision on an unprotected PR ───────────────────────
reset; setrow lead_authority_mode human; setrow "lead_authority.$KEY" human:precision
R=$(decide "$IN" 7 lead)
[ "$(rcof "$R")" = rc=1 ] && grep -q 'lane authority revoked' <<<"$R" && ok || bad "M5 human + human:precision = rc 1 revoked ($R)"

# ── M6: source human ───────────────────────────────────────────────────────
reset; files .mergify.yml
R=$(decide "$IN" 7 human)
[ "$(rcof "$R")" = rc=0 ] && [ ! -s "$W/log" ] && [ ! -s "$G/calls" ] && ok \
  || bad "M6 source human = rc 0 with zero reads ($R; worker $(cat "$W/log" 2>/dev/null); gh $(ghlog))"

# ── M7: la_human_needed ────────────────────────────────────────────────────
reset
lib "la_human_needed $IN 7 $HEAD 'touches protected paths: .mergify.yml' lead-review"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$T/alerts" ] && ! ls "$H/state/lead-authority/"human-needed-* >/dev/null 2>&1 && ok \
  || bad "M7 lane: rc 0, no alert, no marker (rc $RC, alerts $(cat "$T/alerts" 2>/dev/null))"
reset; setrow lead_authority_mode human
lib "la_human_needed $IN 7 $HEAD 'touches protected paths: .mergify.yml' lead-review"
[ "$(grep -c . "$T/alerts" 2>/dev/null)" = 1 ] && ls "$H/state/lead-authority/"human-needed-* >/dev/null 2>&1 && ok \
  || bad "M7 human: one alert and the marker ($(cat "$T/alerts" 2>/dev/null))"
reset; touch "$W/set503.lead_authority_mode.$KEY"
lib "la_human_needed $IN 7 $HEAD 'x' lead-review"
[ "$(grep -c . "$T/alerts" 2>/dev/null)" = 1 ] && ok || bad "M7 an unreadable mode still pages ($(cat "$T/alerts" 2>/dev/null))"

# ── M8: the real CLI under lane ────────────────────────────────────────────
reset; files README.md .mergify.yml
cli post "$IN" 7 "$HEAD" MERGE --source lead --note "lead-review:9" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "M8 a lane MERGE on a protected PR exits 0 (rc $RC, err $(cat "$T/cli.err"))"
[ "$(statuses)" = 1 ] && ghlog | grep -- "-X POST repos/$IN/statuses/$HEAD" | grep -q -- '-f state=success' && ok \
  || bad "M8 one success status ($(ghlog | grep statuses))"
[ "$(ncomments)" = 1 ] && grep -qxF 'touches protected paths .mergify.yml; cleared to merge on the lead verdict' "$G/comments" && ok \
  || bad "M8 exactly one comment naming the path ($(ncomments): $(cat "$G/comments" 2>/dev/null))"
[ "$(jq -r .note "$W/posted" 2>/dev/null)" = 'lead-review:9 authority:lane-protected' ] && ok \
  || bad "M8 the verdict note carries authority:lane-protected ($(cat "$W/posted"))"
[ -e "$MARK" ] && ok || bad "M8 the comment marker is written after the POST"
ghlog | grep -E 'statuses|comments' | head -1 | grep -q statuses && ok || bad "M8 the comment follows the status publish"
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(ncomments)" = 1 ] && [ "$(statuses)" = 2 ] && ok \
  || bad "M8 a re-post on the same head adds no comment (rc $RC, comments $(ncomments), statuses $(statuses))"
reset; files .mergify.yml bin/lead-verdict.sh bin/lib/verdicts.sh bin/merge-conductor.sh rules/settings.json bin/secret-read-guard.py
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null
grep -q '^touches protected paths .*, +1 more; cleared to merge on the lead verdict$' "$G/comments" && ok || bad "M8 six paths: the comment says +1 more ($(cat "$G/comments" 2>/dev/null))"
reset; files .mergify.yml; echo 500 > "$G/comment-status"
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -e "$MARK" ] && [ "$(statuses)" = 1 ] && grep -q 'protected-path comment on .* did not post' "$T/cli.err" && ok \
  || bad "M8 a failed comment: exit 0, no marker, one stderr line (rc $RC, err $(cat "$T/cli.err"))"
rm -f "$G/comment-status"
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null
[ "$(ncomments)" = 2 ] && [ -e "$MARK" ] && ok || bad "M8 the next post comments (calls $(ncomments), marker $([ -e "$MARK" ] && echo y || echo n))"
reset; files .mergify.yml
cli post "$IN" 7 "$HEAD" BLOCK --source lead >/dev/null
[ "$(ncomments)" = 0 ] && ok || bad "M8 a BLOCK never comments"
reset; files .mergify.yml
cli post "$IN" 7 "$HEAD" MERGE --source human >/dev/null
[ "$(ncomments)" = 0 ] && [ "$(jq -r '.note // ""' "$W/posted")" = '' ] && ok || bad "M8 a human MERGE never comments or tags the note"
reset; files .mergify.yml; setrow lead_authority_mode human
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" = 5 ] && [ "$(statuses)" = 0 ] && [ "$(ncomments)" = 0 ] && ok || bad "M8 under human the post still withholds, exit 5 (rc $RC)"
reset; files .mergify.yml
OUTV=$(cli authority "$IN" 7 "$HEAD")
grep -qF 'a lead MERGE publishes (touches protected paths: .mergify.yml; cleared to merge on the lead verdict (lead_authority_mode=lane))' <<<"$OUTV" && ok \
  || bad "M8 the authority verb prints the lane decision: $OUTV"

# ── M9: holds and non-hits ─────────────────────────────────────────────────
hold() { # hold <case> — rc 2 from decide, and no status or comment from the CLI
  local r rc=0
  r=$(decide "$IN" 7 lead)
  [ "$(rcof "$r")" = rc=2 ] && ok || bad "M9 $1 = rc 2 ($r)"
  rm -f "$G/filesread"
  cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null || rc=$?
  [ "$rc" = 5 ] && [ "$(statuses)" = 0 ] && [ "$(ncomments)" = 0 ] && ok || bad "M9 $1: no status (rc $rc, statuses $(statuses))"
}
reset; files .mergify.yml; touch "$W/set503.lead_authority_mode.$KEY"; hold "per-repo mode row 503"
reset; files .mergify.yml; touch "$W/set503.lead_authority_mode"; hold "global mode row 503"
for v in off human:precision 'lane human' ' '; do
  reset; files .mergify.yml; setrow lead_authority_mode "$v"; hold "mode '$v'"
done
# An empty value straight from setting_get (the worker refuses to store one).
R=$(cd "$DIR" && bash -c 'setting_get(){ return 0; }; . bin/lib/lead-authority.sh; _la_mode example-org/cromford; echo "rc=$? [$LA_MODE]"')
[ "$R" = 'rc=2 []' ] && ok || bad "M9 an empty mode value = rc 2 ($R)"
reset; files .mergify.yml; echo "$HEAD2" > "$G/head-after-files"; hold "head moved during the file read"
reset; files .mergify.yml; touch "$G/files500"; hold "files 500"
reset; files docs/mergify.yml.md
R=$(decide "$IN" 7 lead)
[ "$R" = 'rc=0 hit= reason=no protected path' ] && ok || bad "M9 docs/mergify.yml.md is not a hit ($R)"
reset; files .mergify.yml
R=$(decide "$OUT" 41 lead)
[ "$R" = 'rc=0 hit= reason=not governed' ] && [ "$(setgets)" = 0 ] && ok || bad "M9 an ungoverned repo reads no settings ($R, $(setgets) reads)"

echo "lead-authority-mode: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
