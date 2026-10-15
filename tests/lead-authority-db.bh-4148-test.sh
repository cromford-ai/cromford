#!/bin/bash
# tests/lead-authority-db.bh-4148-test.sh — BH-4148 (BH-4140.3): the lead's
# protected-path globs come from the lead_protected_paths rows, read through
# GET /api/lead-protected-paths?repo=<owner/name, lowercased>, never from a
# committed TSV or the lead_protected_paths_extra.<owner>.<name> settings row.
# Driven through the real transport: the real bin/jobs-client.sh and
# bin/lib/lead-authority.sh (loaded by the real bin/lib/verdict-status.sh), the
# real bin/lead-verdict.sh authority and post verbs, with only these faked:
#   * curl — the jobs worker: the route answered by tests/lib/lpp-stub.sh
#            (rows in $T/lpp.json, $T/lpp-down = 500), settings rows from
#            $W/set/<key>, POST/GET /api/verdicts, everything else 404;
#   * gh   — GitHub REST: pulls/<n> answers $G/head, pulls/<n>/files
#            $G/files.json, statuses POST 201; every call logged to $G/calls.
# No catalog/ dir and no TSV exist anywhere in $T until F, which adds the seed file.
#   D1  rows -> la_globs prints exactly them, la_scope rc 0, human-mode hit rc 1
#   D2  a PUT add governs the next decide: human rc 1, lane rc 0 + LA_PROTECTED_HIT
#   D3  worker down, no cache -> la_scope rc 2, la_decide rc 2 (lead and
#       conductor), no status POST from a lead MERGE post
#   D4  a removed row (PUT remove, or removed_at in the body) does not govern
#   D5  the last-good cache: written on a read, answers when fresh, rc 2 when
#       stale (by mtime or by lead_protected_paths_cache_max_s) or missing;
#       a 404 / non-array answer is unreadable, never "no rows"
#   D6  the extras settings row no longer adds a glob, and is never read
#   D7  a mixed-case slug reads the lowercased rows
#   A1  the authority verb lists the rows and their source, no extras line
#   A2  the authority verb dies with the hold text on unreadable
#   N   negatives: rows:null, another repo's row; N1 docs/mergify.yml.md is no
#       .mergify.yml hit; N2 an ungoverned repo is rc 0 and costs no mode read
#   B32 the new functions stay Bash 3.2 safe: no ${x,,}, declare -a, mapfile
#   F   the seed floor (BH-4148 review): with catalog/lead-protected-paths.seed.tsv
#       in the tree, a seed glob with no DB row (live or removed) stays
#       protected: an unseeded table, a partial seed and a reset table all keep
#       every seed path; a console remove still un-protects one; other repos are
#       untouched; the seed file and the fixture hold the same globs.
#   F0  with HARNESS and H unset, the seed file next to the lib is the floor
#       (rc 0), and no cache file is written. F0b: a set root with no seed file
#       does not fall back to the lib's tree (rc 1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-authority-db.bh-4148-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

IN=example-org/cromford
OUT=example-org/demo-os
HEAD=aaaaaaaa11111111111111111111111111111111
G="$T/gh"; W="$T/worker"; LPP="$T/lpp.json"; DOWN="$T/lpp-down"
mkdir -p "$G" "$W/set" "$T/fakebin" "$T/tmp" "$T/tok"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
lpp_install "$T/fakebin" "$LPP" "$DOWN"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/files"*)
    case "\$*" in
      *"&page=1"*) restpr --raw 200 "\$(cat "$G/files.json" 2>/dev/null || echo '[]')" ;;
      *) restpr --raw 200 '[]' ;;
    esac ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*) restpr OPEN "\$(cat "$G/head")" ;;
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
printf '%s %s\n' "\$m" "\${url#http://lpp.stub}" >> "$W/log"
case "\$url" in
$(lpp_curl_case m url body)
  *"/api/settings/"*)
    k="\${url##*/api/settings/}"
    if [ -f "$W/set/\$k" ]; then printf '%s\n200' "\$(jq -nc --arg k "\$k" --arg v "\$(cat "$W/set/\$k")" '{setting:{key:\$k,value:\$v}}')"
    else printf '{"error":"no such setting"}\n404'; fi ;;
  *"/api/verdicts?"*) printf '{"rows":[],"standing":null,"truncated":false}\n200' ;;
  *"/api/verdicts")
    printf '%s\n' "\$body" >> "$W/posted"
    printf '%s\n201' "\$(jq -c '{verdict:(. + {id:21,created_at:"2026-10-05T10:00:00Z"})}' <<<"\$body")" ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state"
scratch_install_closure bin/lead-verdict.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
CACHE="$H/state/lead-authority/globs-example-org_cromford.cache"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_URL=http://lpp.stub JOBS_RETRIES=0 \
  JOBS_BOX=box-hub TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" GH_APP_TOKENS=0
unset LEAD_VERDICT_CONTEXT GH_TOKEN

reset() {
  rm -f "$G"/* "$W"/set/* "$W/log" "$W/posted" "$DOWN" "$LPP" "$LPP.raw" "$LPP.log"
  scratch_rm "$H/state/lead-authority"
  printf '{"rows":[]}' > "$LPP"
  echo "$HEAD" > "$G/head"; echo '[{"filename":"README.md"}]' > "$G/files.json"
}
files() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | map({filename:.})' > "$G/files.json"; }
statuses() { cat "$G/calls" 2>/dev/null | grep -c -- '-X POST repos/.*/statuses/'; }
# lib <shell code> — the lib loaded the way a post loads it, in a subshell.
lib() { ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/verdicts.sh" 2>/dev/null
          . "$H/bin/lib/verdict-status.sh" 2>/dev/null; eval "$1" ) 2>"$T/lib.err"; }
decide() { lib "la_decide $1 $2 $HEAD $3; echo \"rc=\$? hit=\${LA_PROTECTED_HIT:-} paths=\${LA_PROTECTED_PATHS:-} reason=\${LA_REASON:-}\""; }
cli() { bash "$H/bin/lead-verdict.sh" "$@" 2>"$T/cli.err"; }
gets() { cat "$LPP.log" 2>/dev/null | grep -c '^GET .*/api/lead-protected-paths'; }

[ ! -e "$DIR/catalog/lead-protected-paths.tsv" ] && ok || bad "catalog/lead-protected-paths.tsv still exists"
[ -z "$(find "$T" -name '*.tsv' 2>/dev/null)" ] && [ ! -d "$H/catalog" ] && ok || bad "a TSV or catalog/ exists in the scratch tree"

# D1 ───────────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml 'bin/lib/mc/**'
R=$(lib "la_globs $IN"); RC=$?
[ "$RC" = 0 ] && [ "$R" = "$(printf '.mergify.yml\nbin/lib/mc/**')" ] && ok || bad "D1 la_globs prints exactly the 2 rows (rc $RC): '$R'"
lib "la_scope $IN"; RC=$?
[ "$RC" = 0 ] && ok || bad "D1 la_scope rc $RC with rows (want 0)"
files bin/lib/mc/x.sh; printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && grep -q 'touches protected paths: bin/lib/mc/x.sh' <<<"$R" && ok || bad "D1 human: a row's glob governs, rc 1 naming bin/lib/mc/x.sh ($R)"
[ "$(gets)" -ge 3 ] && ok || bad "D1 every read went to the worker ($(gets) GETs)"
reset
lib "la_scope $OUT"; RC=$?
[ "$RC" = 1 ] && ok || bad "D1b la_scope rc $RC on an empty answer (want 1)"

# D2 ───────────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml; files tmp/x
printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=no protected path' <<<"$R" && ok || bad "D2 before the PUT, tmp/x is no protected path ($R)"
lib "_jobs_req PUT /api/lead-protected-paths '{\"repo\":\"example-org/cromford\",\"glob\":\"tmp/**\",\"op\":\"add\",\"added_by\":\"t\"}' >/dev/null"; RC=$?
[ "$RC" = 0 ] && ok || bad "D2 the PUT add answered rc $RC"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && grep -q 'tmp/x' <<<"$R" && ok || bad "D2 human: a PUT-added glob governs the next decide, rc 1 naming tmp/x ($R)"
printf lane > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'hit=1 paths=tmp/x ' <<<"$R" && ok || bad "D2 lane: rc 0, LA_PROTECTED_HIT=1, LA_PROTECTED_PATHS=tmp/x ($R)"
# one GET of the rows per decide: the scope and the match share a read
: > "$LPP.log"; decide "$IN" 7 lead >/dev/null
[ "$(gets)" = 1 ] && ok || bad "D2 one la_decide = one GET of the rows ($(gets))"

# D3 ───────────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml; touch "$DOWN"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "D3 la_scope rc $RC with the worker down and no cache (want 2)"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && grep -q 'the protected paths of example-org/cromford could not be read (jobs worker, no cache younger than 86400s)' <<<"$R" && ok \
  || bad "D3 lead la_decide = rc 2 naming the unreadable rows ($R)"
R=$(decide "$IN" 7 conductor)
[ "${R%% *}" = rc=2 ] && ok || bad "D3 conductor la_decide = rc 2 ($R)"
R=$(decide "$OUT" 41 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "D3 an ungoverned repo is rc 2 too while unreadable, never 'not governed' ($R)"
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" != 0 ] && [ "$(statuses)" = 0 ] && ok || bad "D3 a lead MERGE post publishes no status while unreadable (rc $RC, statuses $(statuses))"
[ ! -e "$CACHE" ] && ok || bad "D3 a failed read wrote a cache"

# D4 ───────────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml 'tmp/**'; files tmp/x
lib "_jobs_req PUT /api/lead-protected-paths '{\"repo\":\"example-org/cromford\",\"glob\":\"tmp/**\",\"op\":\"remove\"}' >/dev/null"; RC=$?
[ "$RC" = 0 ] && [ "$(jq -r '.rows[] | select(.glob == "tmp/**") | .removed_at' "$LPP")" != null ] && ok || bad "D4 the PUT remove did not soft-delete (rc $RC)"
printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=no protected path' <<<"$R" && ok || bad "D4 human: a removed row is 'no protected path' ($R)"
printf '{"rows":[{"repo":"example-org/cromford","glob":".mergify.yml","removed_at":null},{"repo":"example-org/cromford","glob":"tmp/**","removed_at":"2026-10-04T01:00:00Z"},{"repo":"example-org/cromford","glob":"bad glob","removed_at":null}]}' > "$LPP.raw"
R=$(lib "la_globs $IN")
[ "$R" = .mergify.yml ] && ok || bad "D4 a body row with removed_at set, or with whitespace, is ignored: '$R'"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=no protected path' <<<"$R" && ok || bad "D4 human: the removed_at row does not govern ($R)"

# D5 ───────────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml 'tmp/**'; files tmp/x
lib "la_globs $IN" >/dev/null
[ -f "$CACHE" ] && [ "$(cat "$CACHE")" = "$(printf '.mergify.yml\ntmp/**')" ] && ok || bad "D5 a successful read writes the cache: $(cat "$CACHE" 2>/dev/null)"
[ -z "$(find "$H/state/lead-authority" -name '.globs.*')" ] && ok || bad "D5 a tmp file was left behind"
touch "$DOWN"
R=$(lib "la_globs $IN"); RC=$?
[ "$RC" = 0 ] && [ "$R" = "$(printf '.mergify.yml\ntmp/**')" ] && ok || bad "D5 a fresh cache answers while the worker is down (rc $RC): '$R'"
R=$(lib '_la_db_globs example-org/cromford; echo "$LA_GLOBS_SRC"')
[ "$R" = "cache $CACHE" ] && ok || bad "D5 LA_GLOBS_SRC names the cache: '$R'"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'hit=1 paths=tmp/x ' <<<"$R" && ok || bad "D5 la_decide hits through the cached globs ($R)"
touch -t 202001010000 "$CACHE"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "D5 a cache older than 86400 s is rc 2 (rc $RC)"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "D5 la_decide on a stale cache = rc 2 ($R)"
rm -f "$CACHE"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "D5 no cache is rc 2 (rc $RC)"
# the cap row: 120 s, a cache 5 minutes old is stale. The settings read rides
# the same worker, so it stays up and only the route answers 404 (an old worker).
rm -f "$DOWN"; lib "la_globs $IN" >/dev/null
touch -d '5 minutes ago' "$CACHE" 2>/dev/null || touch -t "$(date -v-5M +%Y%m%d%H%M 2>/dev/null)" "$CACHE"
cp "$T/fakebin/lpp-answer" "$T/lpp-answer.real"
printf '#!/bin/bash\nprintf "%%s %%s\\n" "$1" "$2" >> "%s"\nprintf '"'"'{"error":"x"}\\n404'"'"'\n' "$LPP.log" > "$T/fakebin/lpp-answer"
R=$(lib "la_globs $IN"); RC=$?
[ "$RC" = 0 ] && [ -n "$R" ] && ok || bad "D5 a 404 from the route, cache 5 min old, no cap row: the cache answers (rc $RC)"
printf 120 > "$W/set/lead_protected_paths_cache_max_s"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "D5 cap row 120 s and a cache 5 min old = rc 2 (rc $RC)"
printf 'junk' > "$W/set/lead_protected_paths_cache_max_s"
lib "la_scope $IN"; RC=$?
[ "$RC" = 0 ] && ok || bad "D5 a garbage cap row falls back to 86400 (rc $RC)"
printf 30 > "$W/set/lead_protected_paths_cache_max_s"
lib "la_scope $IN"; RC=$?
[ "$RC" = 0 ] && ok || bad "D5 a cap row under 60 falls back to 86400 (rc $RC)"
rm -f "$CACHE" "$W/set/lead_protected_paths_cache_max_s"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "D5 a 404 with no cache is unreadable, never 'no rows' (rc $RC)"
cp "$T/lpp-answer.real" "$T/fakebin/lpp-answer"
printf '{"rows":{"glob":".mergify.yml"}}' > "$LPP.raw"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "D5 a 2xx whose rows is not an array is unreadable (rc $RC)"
printf 'not json' > "$LPP.raw"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "D5 a non-JSON 2xx is unreadable (rc $RC)"
rm -f "$LPP.raw"
# an empty answer is cached too: an ungoverned repo rides out a blip
reset; lib "la_scope $OUT"
[ -f "$H/state/lead-authority/globs-example-org_demo-os.cache" ] && [ ! -s "$H/state/lead-authority/globs-example-org_demo-os.cache" ] && ok \
  || bad "D5 an empty answer writes an empty cache"
touch "$DOWN"
lib "la_scope $OUT"; RC=$?
[ "$RC" = 1 ] && ok || bad "D5 a fresh empty cache answers 'not governed' through an outage (rc $RC)"
# no jobs client and no harness root: nothing to read, nothing cached
LIBF="$H/bin/lib/lead-authority.sh"
R=$( ( unset HARNESS H; . "$LIBF"; la_scope "$IN"; echo "rc=$?" ) 2>/dev/null )
[ "$R" = rc=2 ] && ok || bad "D5 bare lib (no _jobs_req, no root) = rc 2 ($R)"

# D6 ───────────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml; files tmp/x
printf 'tmp/**' > "$W/set/lead_protected_paths_extra.example-org.cromford"
printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=no protected path' <<<"$R" && ok || bad "D6 the extras row no longer adds a glob ($R)"
R=$(lib "la_globs $IN")
[ "$R" = .mergify.yml ] && ok || bad "D6 la_globs ignores the extras row: '$R'"
! grep -q 'lead_protected_paths_extra' "$W/log" 2>/dev/null && ok || bad "D6 the extras settings key was read: $(grep extra "$W/log")"

# D7 ───────────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml
lib "la_scope example-org/Cromford"; RC=$?
[ "$RC" = 0 ] && ok || bad "D7 a mixed-case slug reads the rows (rc $RC)"
grep -q '^GET .*/api/lead-protected-paths?repo=example-org/cromford&all=1$' "$LPP.log" && ! grep -q 'Board' "$LPP.log" && ok \
  || bad "D7 the GET sends the lowercased slug: $(cat "$LPP.log")"

# A1 / A2 ───────────────────────────────────────────────────────────────────────
reset; lpp_set "$LPP" "$IN" .mergify.yml 'bin/lib/mc/**'
OUTV=$(cli authority "$IN"); RC=$?
[ "$RC" = 0 ] && grep -q '^globs (lead_protected_paths, from db): 2$' <<<"$OUTV" && grep -qx '  bin/lib/mc/\*\*' <<<"$OUTV" \
  && grep -qx '  .mergify.yml' <<<"$OUTV" && grep -qx 'in scope: yes' <<<"$OUTV" && ok || bad "A1 authority lists the DB rows (rc $RC): $OUTV $(cat "$T/cli.err")"
! grep -q 'extra globs\|committed globs' <<<"$OUTV" && ok || bad "A1 authority still prints a committed/extras line: $OUTV"
OUTV=$(cli authority "$OUT"); RC=$?
[ "$RC" = 0 ] && grep -q 'in scope: no (no live lead_protected_paths rows; the lane is the authority)' <<<"$OUTV" && ok || bad "A1 authority on a repo with no rows says so (rc $RC): $OUTV"
touch "$DOWN"; scratch_rm "$H/state/lead-authority"
OUTV=$(cli authority "$IN"); RC=$?
[ "$RC" != 0 ] && grep -q 'the protected paths of example-org/cromford could not be read' "$T/cli.err" && ok \
  || bad "A2 authority exits non-zero on worker 500 with no cache (rc $RC): $(cat "$T/cli.err")"

# N ────────────────────────────────────────────────────────────────────────────
reset; printf '{"rows":null}' > "$LPP.raw"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "N {\"rows\":null} is unreadable (rc $RC)"
rm -f "$LPP.raw"
reset; printf '{"rows":[{"repo":"example-org/other","glob":"tmp/**","removed_at":null}]}' > "$LPP.raw"; files tmp/x
printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=not governed' <<<"$R" && ok || bad "N another repo's row is ignored ($R)"
rm -f "$LPP.raw"
reset; : > "$W/log"
R=$(decide "$OUT" 41 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=not governed' <<<"$R" && ok || bad "N2 example-org/demo-os with no rows = rc 0 not governed ($R)"
! grep -q 'lead_authority_mode' "$W/log" && ok || bad "N2 an ungoverned repo costs no mode read: $(cat "$W/log")"
reset; lpp_set "$LPP" "$IN" .mergify.yml; files docs/mergify.yml.md docs/.mergify.yml.md
printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=no protected path' <<<"$R" && ok || bad "N1 docs/.mergify.yml.md does not match .mergify.yml ($R)"

# F ────────────────────────────────────────────────────────────────────────────
FIX="$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"
SEEDF="$DIR/catalog/lead-protected-paths.seed.tsv"
[ "$(grep -v '^#' "$SEEDF" | cut -f2 | sort)" = "$(grep -v '^#' "$FIX" | sort)" ] && ok || bad "F the seed file and the fixture hold different globs"
[ "$(grep -v '^#' "$SEEDF" | cut -f1 | sort -u)" = example-org/cromford ] && ok || bad "F the seed file names a repo other than example-org/cromford"
mkdir -p "$H/catalog"; cp "$SEEDF" "$H/catalog/"
want_all=$(grep -v '^#' "$FIX" | sort)
# unseeded: the live table has no row at all (production on 2026-10-05)
reset
R=$(lib "la_globs $IN" | sort)
[ "$R" = "$want_all" ] && ok || bad "F an unseeded table still protects all $(printf '%s\n' "$want_all" | wc -l | tr -d ' ') seed globs: '$(head -3 <<<"$R")...'"
lib "la_scope $IN"; RC=$?
[ "$RC" = 0 ] && ok || bad "F an unseeded table is governed (la_scope rc $RC, want 0)"
files bin/worker-deploy.sh
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'hit=1 paths=bin/worker-deploy.sh' <<<"$R" && ok || bad "F lane: an unseeded protected path is reported as a hit ($R)"
printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=1 ] && grep -q 'touches protected paths: bin/worker-deploy.sh' <<<"$R" && ok || bad "F human: an unseeded protected path needs a human verdict ($R)"
grep -q '^GET .*/api/lead-protected-paths?repo=example-org/cromford&all=1$' "$LPP.log" && ok || bad "F the read asks for removed rows too: $(cat "$LPP.log")"
OUTV=$(cli authority "$IN"); RC=$?
NSEED=$(grep -c . "$FIX")   # TEST-CHANGE BH-4148 (merge of main): the count is the fixture's, not a literal 36 (main added 2 globs)
[ "$RC" = 0 ] && grep -q "^of which $NSEED have no DB row yet" <<<"$OUTV" && grep -qx 'in scope: yes' <<<"$OUTV" && ok || bad "A1 authority names the seed floor (rc $RC): $OUTV"
# partial seed: 32 rows, the four BH-4087 globs never added
reset
P4='bin/worker-deploy.sh
bin/lib/d1-schema.sh
bin/cf-token-scope-probe.sh
bin/protected-setting.sh'
set -f  # the globs are rows, not patterns for the shell
# shellcheck disable=SC2046
lpp_set "$LPP" "$IN" $(grep -v '^#' "$FIX" | grep -vxF "$P4"); set +f
R=$(lib "la_globs $IN" | sort)
[ "$R" = "$want_all" ] && ok || bad "F a 32-row seed still protects the four unseeded globs"
R=$(lib '_la_db_globs example-org/cromford; printf "%s\n" "$LA_GLOBS_FLOOR"' | sort)
[ "$R" = "$(printf '%s\n' "$P4" | sort)" ] && ok || bad "F LA_GLOBS_FLOOR is exactly the four unseeded globs: '$R'"
# fully seeded, then a console remove: the removed row is a decision
reset
set -f
# shellcheck disable=SC2046
lpp_set "$LPP" "$IN" $(grep -v '^#' "$FIX"); set +f
R=$(lib '_la_db_globs example-org/cromford; printf "%s|" "$LA_GLOBS_FLOOR"')
[ "$R" = "|" ] && ok || bad "F a full seed leaves no floor: '$R'"
lib "_jobs_req PUT /api/lead-protected-paths '{\"repo\":\"example-org/cromford\",\"glob\":\"bin/worker-deploy.sh\",\"op\":\"remove\",\"added_by\":\"t\"}' >/dev/null"; RC=$?
[ "$RC" = 0 ] && ok || bad "F the PUT remove answered rc $RC"
R=$(lib "la_globs $IN")
! grep -qx 'bin/worker-deploy.sh' <<<"$R" && [ "$(printf '%s\n' "$R" | awk 'NF' | wc -l | tr -d ' ')" = "$(( $(grep -c . "$FIX") - 1 ))" ] && ok || bad "F a console remove un-protects the glob (one fewer than the seed, TEST-CHANGE: derived, was a literal 35): $(printf '%s\n' "$R" | grep worker-deploy)"
files bin/worker-deploy.sh; printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=no protected path' <<<"$R" && ok || bad "F a removed seed glob no longer governs ($R)"
# a reset table (rows and history gone) after a good read: the floor holds again
reset
R=$(lib "la_globs $IN" | sort)
[ "$R" = "$want_all" ] && ok || bad "F a reset table falls back to the seed floor, not to not-governed"
# other repos: the floor names none of them
reset; files tmp/x
R=$(decide "$OUT" 41 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=not governed' <<<"$R" && ok || bad "F example-org/demo-os stays not governed with the seed file present ($R)"
# outage with no cache still holds; the floor never answers for an unreadable DB
reset; touch "$DOWN"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "F worker down, no cache: rc $RC (want 2) even with the seed file"
# F0: no harness root (the lead's Mac): the seed file next to the lib is the floor,
# and nothing is cached, because there is no state dir to write to.
reset
R=$( ( unset HARNESS H; _jobs_req() { printf '{"rows":[]}'; }; setting_get() { return 2; }
       . "$LIBF"; la_globs "$IN" | sort; la_scope "$IN"; echo "rc=$?" ) 2>/dev/null )
[ "$(printf '%s\n' "$R" | grep -v '^rc=')" = "$want_all" ] && ok || bad "F0 no root: la_globs is every seed glob next to the lib: '$(head -3 <<<"$R")...'"
[ "$(printf '%s\n' "$R" | tail -1)" = rc=0 ] && ok || bad "F0 no root: la_scope rc 0 from the floor next to the lib ($(tail -1 <<<"$R"))"
[ -z "$(find "$H/state" "$H/bin" -name 'globs-*.cache' 2>/dev/null)" ] && ok || bad "F0 no root wrote a cache: $(find "$H/state" "$H/bin" -name 'globs-*.cache')"
# F0b: a set root with no seed file never falls back to the lib's tree.
EMPTYR="$T/emptyroot"; mkdir -p "$EMPTYR"
R=$( ( unset H; export HARNESS="$EMPTYR"; _jobs_req() { printf '{"rows":[]}'; }; setting_get() { return 2; }
       . "$LIBF"; la_scope "$IN"; echo "rc=$?" ) 2>/dev/null )
[ "$R" = rc=1 ] && ok || bad "F0b a root with no seed file reads no floor from the lib's tree ($R, want rc=1)"
scratch_rm "$H/catalog"

# B32 ──────────────────────────────────────────────────────────────────────────
# The lead's Mac sources this lib under Bash 3.2: the new readers keep to it.
for fn in _la_db_globs _la_cache_max _la_seed_floor la_globs la_scope; do
  body=$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$DIR/bin/lib/lead-authority.sh")
  [ -n "$body" ] || { bad "B32 $fn not found in bin/lib/lead-authority.sh"; continue; }
  # shellcheck disable=SC2016
  ! grep -nE ',,\}|\^\^\}|declare -a|local -a|mapfile|readarray' <<<"$body" && ok || bad "B32 $fn uses a Bash 4 construct"
done
grep -q '_la_catalog\|_la_committed\|_la_extras' "$DIR/bin/lib/lead-authority.sh" && bad "B32 a TSV or extras reader is still defined" || ok

echo "lead-authority-db: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
