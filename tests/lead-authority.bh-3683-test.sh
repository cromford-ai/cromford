#!/bin/bash
# tests/lead-authority.bh-3683-test.sh — BH-3683: the hub lead-review lane is the
# verdict authority, and a PR touching a protected path needs a --source human
# verdict before anything publishes `lead-verdict: success`. Driven against a
# scratch harness carrying the real bin/lib/lead-authority.sh, the real
# catalog/lead-protected-paths.tsv, bin/lead-verdict.sh and the conductor lib,
# with only these stubbed:
#   * gh   — GitHub REST: pulls/<n> answers $G/head (then $G/head-after-files
#            once a files page was read), pulls/<n>/files answers $G/files.json
#            ($G/files500 = 500, $G/filesfull = every page full), statuses POST
#            answers 201; every call logged to $G/calls;
#   * curl — the jobs worker: settings rows from $W/set/<key> ($W/set503 = an
#            outage), POST /api/verdicts, GET /api/verdicts (standing = $W/standing);
#            every call logged to $W/log, bodies to $W/posted, lead headers to $W/hdr;
#   * $H/bin/lane-alert.sh — records its argv in $T/alerts.
#   G  glob semantics, la_globs (extras only add), _la_key
#   D  la_decide: scope, files, rename, unreadable, authority row, sources, catalog
#   P  bin/lead-verdict.sh post: withheld on a protected PR (exit 5), human publishes
#   V  bin/lead-verdict.sh authority + usage
#   C  mc_enqueue_mergify obeys the same rule
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-authority.bh-3683-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

IN=example-org/cromford
OUT=example-org/demo-os
HEAD=aaaaaaaa11111111111111111111111111111111
HEAD2=bbbbbbbb22222222222222222222222222222222
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W/set" "$T/fakebin" "$T/tmp" "$T/tok"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/files"*)
    : > "$G/filesread"
    [ -e "$G/files500" ] && { restpr --raw 500 '{"message":"boom"}'; exit 0; }
    if [ -e "$G/filesfull" ]; then
      restpr --raw 200 "\$(jq -nc '[range(100) | {filename:"docs/f\(.).md"}]')"
    else
      case "\$*" in
        *"&page=1"*) restpr --raw 200 "\$(cat "$G/files.json" 2>/dev/null || echo '[]')" ;;
        *) restpr --raw 200 '[]' ;;
      esac
    fi ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    if [ -e "$G/filesread" ] && [ -f "$G/head-after-files" ]; then restpr OPEN "\$(cat "$G/head-after-files")"
    else restpr OPEN "\$(cat "$G/head")"; fi ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*"/labels"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
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
p="\${url#https://jobs.test}"
printf '%s %s\n' "\$m" "\$p" >> "$W/log"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -e "$W/set503" ]; then code=503; out='{"error":"down"}'
    elif [ -f "$W/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$W/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/verdicts")
    printf '%s\n' "\$body" >> "$W/posted"; printf '%s' "\$hdrs" > "$W/hdr"
    code=201; out=\$(jq -c '{verdict:(. + {id:21,created_at:"2026-09-30T10:00:00Z"})}' <<<"\$body") ;;
  "GET /api/verdicts?"*)
    out=\$(jq -nc --argjson s "\$(cat "$W/standing" 2>/dev/null || echo null)" '{rows:[], standing:\$s, truncated:false}') ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/catalog"
cp "$DIR/bin/lead-verdict.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in verdict-status gh-rest gh-app-auth env-path lead-reviews verdicts hub-box lane-gate lead-authority; do
  [ -f "$DIR/bin/lib/$f.sh" ] && cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
done
[ -f "$DIR/catalog/lead-protected-paths.tsv" ] && cp "$DIR/catalog/lead-protected-paths.tsv" "$H/catalog/"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=box-hub TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" GH_APP_TOKENS=0
unset LEAD_VERDICT_CONTEXT GH_TOKEN

reset() {
  rm -f "$G"/* "$W"/log "$W"/posted "$W"/hdr "$W"/standing "$W"/set503 "$W"/set/* "$T/alerts"
  scratch_rm "$H/state/lead-authority"
  echo "$HEAD" > "$G/head"; echo '[{"filename":"README.md"}]' > "$G/files.json"
  # TEST-CHANGE BH-4145: default mode is now lane; this suite pins human-mode behaviour
  printf human > "$W/set/lead_authority_mode"
}
files() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({filename:.})' > "$G/files.json"; }
ghlog() { cat "$G/calls" 2>/dev/null; }
statuses() { ghlog | grep -c -- '-X POST repos/.*/statuses/'; }
filescalls() { ghlog | grep -c -- '/files?'; }
setgets() { cat "$W/log" 2>/dev/null | grep -c '^GET /api/settings/'; }
nalerts() { [ -f "$T/alerts" ] && grep -c . "$T/alerts" || echo 0; }
# lib <shell code> — the lib loaded the way a post loads it, in a subshell.
lib() { ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/verdicts.sh" 2>/dev/null
          . "$H/bin/lib/verdict-status.sh" 2>/dev/null; eval "$1" ) 2>"$T/lib.err"; }
decide() { lib "la_decide $1 $2 $HEAD $3; echo \"rc=\$? reason=\${LA_REASON:-}\""; }
cli() { bash "$H/bin/lead-verdict.sh" "$@" 2>"$T/cli.err"; }

[ -f "$DIR/bin/lib/lead-authority.sh" ] && ok || bad "bin/lib/lead-authority.sh does not exist"
[ -f "$DIR/catalog/lead-protected-paths.tsv" ] && ok || bad "catalog/lead-protected-paths.tsv does not exist"

# ============================================================================
# G. globs
# ============================================================================
reset
R=$(lib '_la_match config/mergify/repos/cromford.conf "config/mergify/**" && echo y1
         _la_match catalog/switches.d/audit-off.json "catalog/switches.d/*-off.json" && echo y2
         _la_match catalog/switches.d/blocked-resolver-disabled.json "catalog/switches.d/*-off.json" && echo n3
         _la_match docs/.mergify.yml.md .mergify.yml && echo n4
         _la_match .mergify.yml .mergify.yml && echo y5')
[ "$(tr '\n' ' ' <<<"$R")" = "y1 y2 y5 " ] && ok || bad "G1 glob semantics (want 'y1 y2 y5 ', got '$(tr '\n' ' ' <<<"$R")')"
reset; printf 'bin/foo.sh docs/x/**' > "$W/set/lead_protected_paths_extra.example-org.cromford"
R=$(lib "la_globs $IN"); RC=$?
[ "$RC" = 0 ] && grep -qx '.mergify.yml' <<<"$R" && grep -qx 'config/mergify/\*\*' <<<"$R" && grep -qx 'bin/foo.sh' <<<"$R" \
  && grep -qx 'docs/x/\*\*' <<<"$R" && ok || bad "G2 la_globs = committed + both extras (rc $RC): $R"
printf -- '-.mergify.yml' > "$W/set/lead_protected_paths_extra.example-org.cromford"
R=$(lib "la_globs $IN")
grep -qx '.mergify.yml' <<<"$R" && ok || bad "G2 an extras row cannot drop .mergify.yml: $R"
# G4 (2026-10-01): the paths that ENFORCE this file (the conductor's publish
# path), CI, and the agent secret-read guard (BH-3689) are protected too.
reset
R=$(lib "la_globs $IN")
for g in 'bin/lib/mc/\*\*' 'bin/merge-conductor.sh' '.github/workflows/\*\*' 'bin/secret-read-guard.py' \
         'bin/secret-read-guard-install.sh' 'rules/settings.json'; do
  grep -qx "$g" <<<"$R" && ok || bad "G4 committed globs must protect $g: $R"
done
R=$(lib '_la_match bin/lib/mc/queue.sh "bin/lib/mc/**" && echo y1
         _la_match .github/workflows/harness-ci.yml ".github/workflows/**" && echo y2
         _la_match bin/merge-conductor-backstop.sh bin/merge-conductor.sh && echo n3')
[ "$(tr '\n' ' ' <<<"$R")" = "y1 y2 " ] && ok || bad "G4 conductor/CI paths match (want 'y1 y2 ', got '$(tr '\n' ' ' <<<"$R")')"
R=$(lib '_la_key example-org/Cromford'); RC=$?
[ "$RC" = 0 ] && [ "$R" = example-org.cromford ] && ok || bad "G3 _la_key lowercases and dots the slug (rc $RC, '$R')"
lib "_la_key example-org/$(printf 'x%.0s' {1..40})" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "G3 a slug whose extras key would pass 64 chars is rc 2 (rc $RC)"

# ============================================================================
# D. la_decide
# ============================================================================
reset; files .mergify.yml
R=$(decide "$OUT" 41 lead)
[ "${R%% *}" = rc=0 ] && [ "$(filescalls)" = 0 ] && [ "$(setgets)" = 0 ] && ok \
  || bad "D1 an out-of-scope repo is rc 0 with no files read and no settings read ($R, files $(filescalls), settings $(setgets))"
reset
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && [ "$(filescalls)" -ge 1 ] && ok || bad "D2 in scope, README only, no row = rc 0 ($R, err $(cat "$T/lib.err"))"
reset; files README.md .mergify.yml
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && grep -q '\.mergify\.yml' <<<"$R" && ok || bad "D3 .mergify.yml in the files = rc 1 naming it ($R)"
reset; echo '[{"filename":"bin/x.sh","previous_filename":"bin/lead-verdict.sh","status":"renamed"}]' > "$G/files.json"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && grep -q 'bin/lead-verdict.sh' <<<"$R" && ok || bad "D4 a rename out of a protected path is protected ($R)"
reset; echo '[{"filename":"bin/lib/verdicts.sh","status":"removed"}]' > "$G/files.json"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && ok || bad "D4 a deleted protected file is protected ($R)"
reset; touch "$G/files500"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "D5 a files page answering 500 = rc 2 ($R)"
reset; touch "$G/filesfull"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && [ "$(filescalls)" = 30 ] && ok || bad "D5 a full 30th page = rc 2 after 30 reads ($R, files $(filescalls))"
reset; echo "$HEAD2" > "$G/head-after-files"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && grep -q 'head moved' <<<"$R" && ok || bad "D5 a head that moved during the file read = rc 2 ($R)"
reset; printf 'human:precision' > "$W/set/lead_authority.example-org.cromford"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && grep -q 'revoked' <<<"$R" && ok || bad "D6 row human:precision = rc 1 revoked on an unprotected PR ($R)"
printf 'human' > "$W/set/lead_authority.example-org.cromford"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && grep -q 'revoked' <<<"$R" && ok || bad "D6 row human = rc 1 ($R)"
printf 'junk' > "$W/set/lead_authority.example-org.cromford"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "D6 an unknown authority value = rc 2 ($R)"
printf 'HUMAN' > "$W/set/lead_authority.example-org.cromford"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "D6 HUMAN (wrong case) is unknown = rc 2 ($R)"
printf 'lane' > "$W/set/lead_authority.example-org.cromford"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && ok || bad "D6 row lane = rc 0 on an unprotected PR ($R)"
reset; touch "$W/set503"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "D6 a settings outage = rc 2 ($R)"
reset; files .mergify.yml
R=$(decide "$IN" 7 human)
[ "${R%% *}" = rc=0 ] && [ "$(filescalls)" = 0 ] && [ "$(setgets)" = 0 ] && ok || bad "D7 source=human = rc 0 with no read ($R)"
reset; files .mergify.yml
jq -nc --arg h "$HEAD" '{verdict:"MERGE",source:"human",id:5,created_at:"x",head_sha:$h}' > "$W/standing"
R=$(decide "$IN" 7 conductor)
[ "${R%% *}" = rc=0 ] && ok || bad "D8 conductor with a standing human MERGE = rc 0 on a protected PR ($R)"
jq -nc --arg h "$HEAD" '{verdict:"MERGE",source:"lead",id:6,created_at:"x",head_sha:$h}' > "$W/standing"
R=$(decide "$IN" 7 conductor)
[ "${R%% *}" = rc=1 ] && ok || bad "D8 conductor with a standing lead MERGE = rc 1 ($R)"
reset; mv "$H/catalog/lead-protected-paths.tsv" "$T/catalog.bak" 2>/dev/null
R=$(decide "$OUT" 41 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "D9 no catalog = rc 2 for an out-of-scope repo too ($R)"
mv "$T/catalog.bak" "$H/catalog/lead-protected-paths.tsv" 2>/dev/null

# ============================================================================
# P. bin/lead-verdict.sh post
# ============================================================================
reset; files README.md .mergify.yml
cli post "$IN" 7 "$HEAD" MERGE --source lead --note "lead-review:9" >/dev/null; RC=$?
[ "$RC" = 5 ] && ok || bad "P1 a lane MERGE on a protected PR exits 5 (rc $RC, err $(cat "$T/cli.err"))"
[ "$(jq -r .note "$W/posted" 2>/dev/null)" = 'lead-review:9 authority:human-required' ] && ok \
  || bad "P1 the row is recorded with the authority token: $(cat "$W/posted" 2>/dev/null)"
[ "$(statuses)" = 0 ] && ok || bad "P1 no status POST on a protected PR: $(ghlog | grep statuses)"
grep -q '\.mergify\.yml' "$T/cli.err" && grep -q -- '--source human' "$T/cli.err" && ok || bad "P1 stderr names the path and --source human: $(cat "$T/cli.err")"
grep -q 'x-lead-verdict-client: 4' "$W/hdr" 2>/dev/null && ok || bad "P5 the lead post sends x-lead-verdict-client: 4"
reset; files README.md .mergify.yml
cli post "$IN" 7 "$HEAD" MERGE --source human >/dev/null; RC=$?
L=$(ghlog | grep -- "-X POST repos/$IN/statuses/$HEAD")
[ "$RC" = 0 ] && grep -q -- '-f state=success' <<<"$L" && grep -q -- '-f context=lead-verdict' <<<"$L" && ok \
  || bad "P2 a human MERGE on a protected PR publishes success (rc $RC, $L, err $(cat "$T/cli.err"))"
reset; files .mergify.yml
cli post "$IN" 7 "$HEAD" BLOCK --source lead >/dev/null; RC=$?
[ "$RC" = 0 ] && ghlog | grep -- '/statuses/' | grep -q -- '-f state=failure' && ok || bad "P3 a lane BLOCK on a protected PR still publishes failure (rc $RC)"
reset
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" = 0 ] && ghlog | grep -- '/statuses/' | grep -q -- '-f state=success' && ok || bad "P4 a lane MERGE on an unprotected in-scope PR publishes (rc $RC, err $(cat "$T/cli.err"))"
[ "$(jq -r '.note // ""' "$W/posted" 2>/dev/null)" = '' ] && ok || bad "P4 no authority token on a published row"
reset; files .mergify.yml; touch "$G/files500"
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" = 5 ] && [ "$(statuses)" = 0 ] && ok || bad "P6 an undecidable authority withholds too (rc $RC, statuses $(statuses))"

# ============================================================================
# V. the authority verb and usage
# ============================================================================
reset
OUTV=$(cli authority "$IN"); RC=$?
[ "$RC" = 0 ] && grep -q 'in scope: yes' <<<"$OUTV" && grep -q '\.mergify\.yml' <<<"$OUTV" && grep -q 'authority: lane (no row)' <<<"$OUTV" \
  && ok || bad "V1 authority prints scope, globs and the row (rc $RC): $OUTV $(cat "$T/cli.err")"
files .mergify.yml
OUTV=$(cli authority "$IN" 7 "$HEAD")
grep -q 'human required:' <<<"$OUTV" && grep -q '\.mergify\.yml' <<<"$OUTV" && ok || bad "V1 with pr+sha it prints the decision: $OUTV"
OUTV=$(cli authority "$OUT")
grep -q 'in scope: no' <<<"$OUTV" && ok || bad "V1 an out-of-scope repo says so: $OUTV"
[ "$(statuses)" = 0 ] && [ ! -f "$W/posted" ] && ok || bad "V1 the authority verb writes nothing"
cli >/dev/null; grep -q '5 (post)' "$T/cli.err" && ok || bad "V1 usage prints the exit-5 line: $(cat "$T/cli.err")"

# ============================================================================
# C. mc_enqueue_mergify
# ============================================================================
enq() { (
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { printf '%s\n' "$3" >> "$G/asked"; return 0; }
  mc_queue_state() { printf 'queued'; }
  mc_mergify_witness() { return 1; }
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify "$IN" "https://github.com/$IN/pull/7" "$HEAD"
) 2>"$T/enq.err"; }
reset; files .mergify.yml
jq -nc --arg h "$HEAD" '{verdict:"MERGE",source:"lead",id:6,created_at:"x",head_sha:$h}' > "$W/standing"
OUTC=$(enq); RC=$?
[ "$(statuses)" = 0 ] && ok || bad "C1 no status POST from the conductor on a protected PR: $(ghlog | grep statuses)"
# BH-3806: C1 INVERTED ON PURPOSE. Until BH-3806 the label and the ask still
# went out here and the row read QUEUED while Mergify waited on a status only a
# person can publish; now the enqueue refuses with rc 4 and writes nothing.
[ "$RC" = 4 ] && ! grep -q -- "/labels" <<<"$(ghlog)" && [ ! -s "$G/asked" ] && ok \
  || bad "C1 a withheld verdict is rc 4 with no label POST and no queue ask (rc $RC, out $OUTC, asked $(cat "$G/asked" 2>/dev/null))"
ls "$H/state/lead-authority/"human-needed-* >/dev/null 2>&1 && ok || bad "C1 the human-needed marker is written"
[ "$(nalerts)" = 1 ] && grep -q -- '--severity warn --id lead-human-needed-' "$T/alerts" && grep -q -- '--source human' "$T/alerts" && ok \
  || bad "C1 one warn lead-human-needed beat naming --source human: $(cat "$T/alerts" 2>/dev/null)"
grep -q 'withheld' <<<"$OUTC" && grep -qF -- "bin/lead-verdict.sh post $IN 7 $HEAD MERGE --source human" <<<"$OUTC" && ok \
  || bad "C1 the rc 4 refusal says the status is withheld and names the --source human command: $OUTC"
enq >/dev/null
[ "$(nalerts)" = 1 ] && ok || bad "C4 a second enqueue on the same head asks nobody again: $(cat "$T/alerts")"
reset; files .mergify.yml
jq -nc --arg h "$HEAD" '{verdict:"MERGE",source:"human",id:5,created_at:"x",head_sha:$h}' > "$W/standing"
enq >/dev/null
ghlog | grep -- "/statuses/$HEAD" | grep -q -- '-f state=success' && [ "$(nalerts)" = 0 ] && ok \
  || bad "C2 a standing human MERGE lets the conductor publish success: $(ghlog | grep statuses)"
reset; touch "$G/files500"
OUTC=$(enq); RC=$?
[ "$RC" = 3 ] && [ "$(statuses)" = 0 ] && ! grep -q -- '/labels' <<<"$(ghlog)" && grep -q 'lead authority could not be decided' <<<"$OUTC" && ok \
  || bad "C3 an undecidable authority = rc 3, no label, no status (rc $RC, out $OUTC)"
reset
OUTC=$(enq)
ghlog | grep -- "/statuses/$HEAD" | grep -q -- '-f state=success' && ok || bad "C5 an unprotected in-scope PR still gets the conductor's status: $OUTC"

echo "lead-authority: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
