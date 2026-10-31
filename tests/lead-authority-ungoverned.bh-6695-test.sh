#!/bin/bash
# tests/lead-authority-ungoverned.bh-6695-test.sh — BH-6695: a failed read of
# the lead_protected_paths rows, with no cache file, holds only a governed repo
# (a seed line in catalog/lead-protected-paths.seed.tsv); any other repo is
# "not governed". Plus the per-process memo of _la_db_globs (#6665).
# Same transport as tests/lead-authority-db.bh-4148-test.sh: the real
# bin/jobs-client.sh, bin/lib/verdict-status.sh, bin/lib/lead-authority.sh and
# bin/lead-verdict.sh; curl (the jobs worker, tests/lib/lpp-stub.sh) and gh are
# local fakes, so the suite makes 0 vendor calls. Each case resets its own rows.
#   U1-U8  the no-cache rule: seed file, seed line, cache file, no root
#   E1     a lead MERGE post during an outage: demo-os publishes, cromford not
#   A1     the authority verb on an ungoverned repo during an outage
#   R1     risk-tier.sh reads the ungoverned repo's globs as readable
#   M1-M7  the memo: one GET per repo per shell, a new process reads fresh,
#          keys never collide, rc 2 memoized, la_memo_reset, no bad-slug entry
#   B32    the new functions stay Bash 3.2 safe
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-authority-ungoverned.bh-6695-test.sh
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

SEEDF="$DIR/catalog/lead-protected-paths.seed.tsv"
LIBF="$H/bin/lib/lead-authority.sh"
SC="$H/state/lead-authority"
UNGOV='not governed (rows unreadable; no seed line, no cache)'
seed() { mkdir -p "$H/catalog"; cp "$SEEDF" "$H/catalog/"; }
noseed() { scratch_rm "$H/catalog"; }
# every case starts from no rows, no cache and no seed file: no order dependence
fresh() { reset; noseed; }

# U1 ───────────────────────────────────────────────────────────────────────────
fresh; seed; touch "$DOWN"
lib "la_scope $OUT"; RC=$?
[ "$RC" = 1 ] && ok || bad "U1 ungoverned repo, outage, no cache: la_scope rc $RC (want 1)"
R=$(lib "la_globs $OUT"); RC=$?
[ "$RC" = 0 ] && [ -z "$R" ] && ok || bad "U1 la_globs rc $RC, '$R' (want rc 0, empty)"
R=$(lib '_la_db_globs example-org/demo-os; echo "rc=$? src=$LA_GLOBS_SRC"')
[ "$R" = "rc=0 src=none (rows unreadable; no seed line, no cache)" ] && ok || bad "U1 LA_GLOBS_SRC names the rule: '$R'"
R=$(decide "$OUT" 41 lead)
[ "${R%% *}" = rc=0 ] && grep -qF "reason=$UNGOV" <<<"$R" && ok || bad "U1 la_decide lead = rc 0 '$UNGOV' ($R)"
[ ! -e "$SC/globs-example-org_demo-os.cache" ] && ok || bad "U1 the ungoverned answer wrote a cache file"
[ "$(gets)" -ge 1 ] && ok || bad "U1 the GET was never tried"

# U2 ───────────────────────────────────────────────────────────────────────────
fresh; seed; touch "$DOWN"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "U2 seeded repo, outage, no cache: la_scope rc $RC (want 2)"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=2 ] && ok || bad "U2 seeded repo la_decide = rc 2 ($R)"
lib "la_globs $IN" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "U2 seeded repo la_globs rc $RC (want 2)"

# U3 / U4 ──────────────────────────────────────────────────────────────────────
fresh; seed; touch "$DOWN"
lib "la_scope example-org/cromford-os"; RC=$?
[ "$RC" = 1 ] && ok || bad "U3 a prefix of a seeded repo is not seeded: rc $RC (want 1)"
lib "la_scope example-org/board-harnes"; RC=$?
[ "$RC" = 1 ] && ok || bad "U3 a truncated seeded name is not seeded: rc $RC (want 1)"
lib "la_scope example-org/Cromford"; RC=$?
[ "$RC" = 2 ] && ok || bad "U4 a mixed-case seeded repo stays held: rc $RC (want 2)"

# U5 ───────────────────────────────────────────────────────────────────────────
fresh; seed; mkdir -p "$SC"; : > "$SC/globs-example-org_demo-os.cache"
touch -d '25 hours ago' "$SC/globs-example-org_demo-os.cache" 2>/dev/null || touch -t 202001010000 "$SC/globs-example-org_demo-os.cache"
touch "$DOWN"
lib "la_scope $OUT"; RC=$?
[ "$RC" = 2 ] && ok || bad "U5 a stale empty cache file marks the repo governed: rc $RC (want 2)"

# U6 / U6b ─────────────────────────────────────────────────────────────────────
fresh; noseed; touch "$DOWN"
lib "la_scope $OUT"; RC=$?
[ "$RC" = 2 ] && ok || bad "U6 no seed file: an unknown repo is held, rc $RC (want 2)"
mkdir -p "$H/catalog"; chmod 000 "$H/catalog" 2>/dev/null
if [ ! -r "$H/catalog/lead-protected-paths.seed.tsv" ] && [ "$(id -u)" != 0 ]; then
  lib "la_scope $OUT"; RC=$?
  [ "$RC" = 2 ] && ok || bad "U6 an unreadable seed file holds: rc $RC (want 2)"
fi
chmod 755 "$H/catalog" 2>/dev/null; noseed
fresh; mkdir -p "$H/catalog"
printf '# a comment\n# example-org/demo-os\tx\nexample-org/cromford\t.mergify.yml\n' > "$H/catalog/lead-protected-paths.seed.tsv"
touch "$DOWN"
lib "la_scope $OUT"; RC=$?
[ "$RC" = 1 ] && ok || bad "U6b a commented seed line does not govern: rc $RC (want 1)"
lib "la_scope $IN"; RC=$?
[ "$RC" = 2 ] && ok || bad "U6b the live seed line still holds: rc $RC (want 2)"
noseed

# U7 ───────────────────────────────────────────────────────────────────────────
# No root (the lead's Mac): the seed file next to the lib. The repo's own lib
# and seed file, read as delivered.
R=$( ( unset HARNESS H; _jobs_req() { return 1; }; setting_get() { return 2; }
       . "$DIR/bin/lib/lead-authority.sh"; la_scope "$OUT"; echo "out=$?"; la_scope "$IN"; echo "in=$?" ) 2>/dev/null )
[ "$R" = "$(printf 'out=1\nin=2')" ] && ok || bad "U7 no root: demo-os rc 1, cromford rc 2 ($(tr '\n' ' ' <<<"$R"))"
[ ! -e "$DIR/state/lead-authority/globs-example-org_demo-os.cache" ] && ok || bad "U7 no root wrote a cache file"

# U8 ───────────────────────────────────────────────────────────────────────────
fresh; seed; mkdir -p "$SC"; : > "$SC/globs-example-org_demo-os.cache"; touch "$DOWN"
R=$(lib 'la_scope example-org/demo-os; echo "rc=$? src=$LA_GLOBS_SRC"')
[ "$R" = "rc=1 src=cache $SC/globs-example-org_demo-os.cache" ] && ok || bad "U8 a fresh empty cache answers as before: '$R'"

# E1 ───────────────────────────────────────────────────────────────────────────
fresh; seed; touch "$DOWN"
cli post "$OUT" 41 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(statuses)" = 1 ] && ok || bad "E1 an ungoverned lead MERGE publishes during an outage (rc $RC, statuses $(statuses)): $(tail -3 "$T/cli.err")"
fresh; seed; touch "$DOWN"
cli post "$IN" 7 "$HEAD" MERGE --source lead >/dev/null; RC=$?
[ "$RC" != 0 ] && [ "$(statuses)" = 0 ] && ok || bad "E1 a seeded lead MERGE stays held during an outage (rc $RC, statuses $(statuses))"

# A1 ───────────────────────────────────────────────────────────────────────────
fresh; seed; touch "$DOWN"
OUTV=$(cli authority "$OUT"); RC=$?
[ "$RC" = 0 ] && grep -qxF 'globs (lead_protected_paths, from none (rows unreadable; no seed line, no cache)): 0' <<<"$OUTV" \
  && grep -q '^in scope: no' <<<"$OUTV" && ok || bad "A1 authority on an ungoverned repo in an outage (rc $RC): $OUTV $(cat "$T/cli.err")"

# R1 ───────────────────────────────────────────────────────────────────────────
fresh; seed; touch "$DOWN"
printf '{"files":[{"filename":"README.md","status":"modified","additions":1,"deletions":0,"patch":"@@ -1 +1 @@\\n-a\\n+b"}]}' > "$T/cmp.json"
RTC=". '$DIR/bin/lib/risk-tier.sh'; RT_RULES_LOADED=1; RT_LOW_SMALL_LINES=50; RT_LOW_SMALL_LINES_MAX=100; RT_HIGH_GLOBS=; RT_SENSITIVE_GLOBS=; RT_RULES_UNREADABLE=
  rt_low_small '$T/cmp.json' $OUT medium; echo; rt_low_small '$T/cmp.json' $IN medium"
R=$(lib "$RTC")
[ "$(head -1 <<<"$R" | cut -f1)" = yes ] && ok || bad "R1 risk-tier reads demo-os's globs as readable (low-small yes): $R $(cat "$T/lib.err")"
grep -q 'protected paths unreadable' <<<"$R" && ok || bad "R1 risk-tier still reads cromford as unreadable: $R"

# M1 ───────────────────────────────────────────────────────────────────────────
fresh; lpp_set "$LPP" "$IN" .mergify.yml 'tmp/**'
R=$(lib '_la_db_globs example-org/cromford; a="$?|$LA_GLOBS|$LA_GLOBS_FLOOR|$LA_GLOBS_SRC"
         _la_db_globs example-org/cromford; b="$?|$LA_GLOBS|$LA_GLOBS_FLOOR|$LA_GLOBS_SRC"
         [ "$a" = "$b" ] && echo same; printf "%s\n" "$a"')
[ "$(gets)" = 1 ] && ok || bad "M1 two reads in one shell = 1 GET ($(gets))"
[ "$(head -1 <<<"$R")" = same ] && grep -q '^0|.mergify.yml$' <<<"$R" && grep -qx 'tmp/\*\*||db' <<<"$R" && ok || bad "M1 the memo answers what the GET answered: $R"

# M2 ───────────────────────────────────────────────────────────────────────────
fresh; lpp_set "$LPP" "$IN" .mergify.yml
lib ". \"$H/bin/lib/lead-delta.sh\" 2>/dev/null || . \"$DIR/bin/lib/lead-delta.sh\"; command -v ld_protected >/dev/null && ld_protected $IN </dev/null >/dev/null; echo \$?" >/dev/null
[ "$(gets)" = 1 ] && ok || bad "M2 ld_protected = 1 GET of the rows ($(gets))"

# M3 ───────────────────────────────────────────────────────────────────────────
fresh; lpp_set "$LPP" "$IN" .mergify.yml; files tmp/x; printf human > "$W/set/lead_authority_mode"
R=$(decide "$IN" 7 lead)
[ "${R%% *}" = rc=0 ] && grep -q 'reason=no protected path' <<<"$R" && ok || bad "M3 process A: tmp/x is no protected path ($R)"
lib "_jobs_req PUT /api/lead-protected-paths '{\"repo\":\"example-org/cromford\",\"glob\":\"tmp/**\",\"op\":\"add\",\"added_by\":\"t\"}' >/dev/null"
R=$(bash -c '. "$1/bin/jobs-client.sh" >/dev/null 2>&1; . "$1/bin/lib/verdicts.sh" 2>/dev/null; . "$1/bin/lib/verdict-status.sh" 2>/dev/null
             la_decide example-org/cromford 7 "$2" lead; echo "rc=$? reason=$LA_REASON"' _ "$H" "$HEAD" 2>/dev/null)
[ "${R%% *}" = rc=1 ] && grep -q 'tmp/x' <<<"$R" && ok || bad "M3 process B: the PUT-added glob governs (rc 1 naming tmp/x): $R"
# and inside one shell the memo keeps the first answer until la_memo_reset
R=$(lib '_la_db_globs example-org/cromford; echo "$LA_GLOBS" | tr "\n" " "; echo
         _jobs_req PUT /api/lead-protected-paths "{\"repo\":\"example-org/cromford\",\"glob\":\"new/**\",\"op\":\"add\",\"added_by\":\"t\"}" >/dev/null
         _la_db_globs example-org/cromford; echo "$LA_GLOBS" | tr "\n" " "; echo
         la_memo_reset; _la_db_globs example-org/cromford; echo "$LA_GLOBS" | tr "\n" " "')
[ "$(sed -n 1p <<<"$R")" = "$(sed -n 2p <<<"$R")" ] && grep -q 'new/\*\*' <<<"$(sed -n 3p <<<"$R")" && ! grep -q 'new/' <<<"$(sed -n 1p <<<"$R")" \
  && ok || bad "M3 the memo holds for the shell, la_memo_reset reads fresh: $R"

# M4 ───────────────────────────────────────────────────────────────────────────
fresh; lpp_set "$LPP" example-org/a.b dot/**; lpp_set "$LPP" example-org/a-b dash/**; lpp_set "$LPP" example-org/a_b under/**
lpp_set "$LPP" example-org/a_2eb enc/**
R=$(lib 'for r in example-org/a.b example-org/a-b example-org/a_b example-org/a_2eb example-org/a.b example-org/a-b example-org/a_b example-org/a_2eb; do la_globs $r; done | tr "\n" " "')
[ "$R" = 'dot/** dash/** under/** enc/** dot/** dash/** under/** enc/** ' ] && ok || bad "M4 a.b, a-b, a_b and a_2eb (the encoded a.b) keep their own entries: '$R'"
[ "$(gets)" = 4 ] && ok || bad "M4 4 repos, 8 reads = 4 GETs ($(gets))"

# M5 ───────────────────────────────────────────────────────────────────────────
fresh; seed; touch "$DOWN"
R=$(lib 'la_scope example-org/cromford; a=$?; la_scope example-org/cromford; b=$?; echo "$a $b"; la_memo_reset; la_scope example-org/cromford; echo "after=$?"' | tr '\n' ' ')
[ "$R" = '2 2 after=2 ' ] && ok || bad "M5 rc 2 both times and after a reset: '$R'"
[ "$(gets)" = 2 ] && ok || bad "M5 rc 2 is memoized (1 GET for 2 calls), la_memo_reset makes a 2nd GET ($(gets))"
noseed

# M6 ───────────────────────────────────────────────────────────────────────────
fresh
R=$(lib '_la_db_globs a/b/c; echo "rc=$? keys=${_LA_MEMO_KEYS:-}"')
[ "$R" = 'rc=2 keys=' ] && ok || bad "M6 a bad slug is rc 2 with no memo entry: '$R'"
[ "$(gets)" = 0 ] && ok || bad "M6 a bad slug made a GET ($(gets))"

# M7 ───────────────────────────────────────────────────────────────────────────
fresh; lpp_set "$LPP" "$IN" .mergify.yml; files README.md
R=$(lib "la_scope $IN; la_decide $IN 7 $HEAD conductor; echo rc=\$?")
[ "$R" = rc=0 ] && [ "$(gets)" = 1 ] && ok || bad "M7 la_scope then la_decide in one shell = 1 GET ($R, $(gets) GETs)"

# B32 ──────────────────────────────────────────────────────────────────────────
for fn in _la_db_globs _la_read_globs _la_seed_file _la_memo_var la_memo_reset; do
  body=$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$DIR/bin/lib/lead-authority.sh")
  [ -n "$body" ] || { bad "B32 $fn not found in bin/lib/lead-authority.sh"; continue; }
  ! grep -nE ',,\}|\^\^\}|declare -a|declare -A|local -a|mapfile|readarray' <<<"$body" && ok || bad "B32 $fn uses a Bash 4 construct"
done

echo "lead-authority-ungoverned: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
