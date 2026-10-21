#!/bin/bash
# tests/lane-run-secrets.bh-7848-test.sh — BH-7848: the lane app's secret list
# (catalog/lane-run-secrets.d/fly-pool.tsv) and its reader
# (bin/lane-run-secrets.sh).
#
#   L1  the list has FLY_API_TOKEN_<PROJECT>, GH_APP_ID, GH_APP_PRIVATE_KEY
#       (required) and GH_APP_INSTALLATION_<OWNER> (optional)
#   L2  round-trip with the REAL fly/lane-run-entrypoint.sh: every name on the
#       list has a consumer there or in the lf_app_ready gate, and every
#       GH_APP_*/FLY_API_TOKEN* variable the entrypoint reads is on the list
#   R1  fly-pool project-6-os prints exactly the six expanded lines
#   R2  two projects with one owner: the owner line once, a token line each
#   R3  placeholder expansion: a.b-c -> A_B_C, owner my-org -> MY_ORG
#   R4  refused input: rc 2, empty stdout, the line number named for a row
#   R5  project-6 and project-6-os each expand to their own token name
#   R6  the real reader over the real list (no fixture list); without the list
#       it exits 2
#   S1  --stage-cmd prints one `flyctl secrets import -a lane-run-mk --stage`
#       and one `# GH_APP_PRIVATE_KEY` line
#   S2  the printed command, run against fixture env files and a fake flyctl:
#       stdin carries the NAME=value lines of every non-file row, argv carries
#       no value; an empty required variable stops it before any line
#   S3  no fixture value in the reader's own stdout or stderr; no line says
#       ok, staged or ready
#
# Run from anywhere: tests/lane-run-secrets.bh-7848-test.sh (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
export REGISTRY_SOURCE=file
unset HARNESS_ENV_DIR

LIST="$REPO/catalog/lane-run-secrets.d/fly-pool.tsv"
ENTRY="$REPO/fly/lane-run-entrypoint.sh"

# The scratch tree: the reader and its closure, a fixture list dir, a fixture
# fleet.conf.
R="$T/r"; mkdir -p "$R/catalog/lane-run-secrets.d" "$R/env"
scratch_install_closure bin/lane-run-secrets.sh "$R" >/dev/null || { bad "install the reader closure"; }
scratch_install_closure bin/fleet-conf.sh "$R" >/dev/null || { bad "install fleet-conf closure"; }
[ -f "$LIST" ] && cp "$LIST" "$R/catalog/lane-run-secrets.d/fly-pool.tsv"
cat > "$R/fleet.conf" <<'EOF'
# fixture fleet.conf (project repo prod board offset box ip)
project-6     example-org/project-6-runtime -  -  3  box-fixture-a 192.0.2.10
project-6-os  example-org/project-6         -  -  1  box-fixture-b 192.0.2.11
a.b-c         my-org/fixture-repo         -  -  1  box-fixture-c 192.0.2.12
EOF
export FLEET_CONF="$R/fleet.conf"
RD="$R/bin/lane-run-secrets.sh"
run() { # run <outfile> <errfile> args...; echoes rc
  local o="$1" e="$2"; shift 2
  bash "$RD" "$@" >"$o" 2>"$e"; echo $?
}

echo "L1-L2: the list"
row() { awk -F'\t' -v n="$1" '!/^#/ && $1 == n {print $2}' "$LIST" 2>/dev/null; }
for want in 'FLY_API_TOKEN_<PROJECT> required' 'GH_APP_ID required' 'GH_APP_PRIVATE_KEY required' 'GH_APP_INSTALLATION_<OWNER> optional'; do
  set -- $want
  [ "$(row "$1")" = "$2" ] && ok "L1 $1 is $2" || bad "L1 $1 is not on the list as $2"
done
NAMES=$(awk -F'\t' '!/^[[:space:]]*(#|$)/ {print $1}' "$LIST" 2>/dev/null | sed -e 's/<PROJECT>$//' -e 's/<OWNER>$//')
if [ -z "$NAMES" ]; then bad "L2 the list is empty or missing"; fi
for nm in $NAMES; do
  case "$nm" in
    HARNESS_SECRET|JOBS_URL)
      grep -q "\" $nm \"" "$REPO/bin/lane-fleet.sh" && grep -q "\$$nm" "$ENTRY" \
        && ok "L2 $nm: lf_app_ready gate and the entrypoint read it" || bad "L2 $nm has no consumer" ;;
    FLY_API_TOKEN_)
      grep -qF "'^FLY_API_TOKEN(_[A-Z0-9_]+)?\$'" "$ENTRY" && ok "L2 $nm: the entrypoint writes it to fly.env" || bad "L2 $nm has no consumer" ;;
    GH_APP_INSTALLATION_)
      grep -qF "'^GH_APP_INSTALLATION_[A-Za-z0-9_]+='" "$ENTRY" && ok "L2 $nm: the entrypoint writes it to github-app.env" || bad "L2 $nm has no consumer" ;;
    *)
      grep -q "\${$nm:-}" "$ENTRY" && ok "L2 $nm: the entrypoint reads it" || bad "L2 $nm has no consumer in the entrypoint" ;;
  esac
done
# The other way: every GH_APP_* / FLY_API_TOKEN* the entrypoint reads.
for v in $(grep -oE '\$\{?(GH_APP_[A-Z_]+|FLY_API_TOKEN[A-Z_]*)' "$ENTRY" | tr -d '${' | sort -u) \
         $(grep -oE "\^(GH_APP_INSTALLATION_|FLY_API_TOKEN)" "$ENTRY" | tr -d '^' | sort -u); do
  case "$v" in GH_APP_PRIVATE_KEY_FILE) continue ;; esac   # written by the entrypoint, not read
  [ "$v" = FLY_API_TOKEN ] && v=FLY_API_TOKEN_
  grep -qx "$v" <<<"$NAMES" && ok "L2 entrypoint reads $v: on the list" || bad "L2 entrypoint reads $v: not on the list"
done

echo "R1-R6: the reader"
O="$T/o"; E="$T/e"
rc=$(run "$O" "$E" fly-pool project-6-os)
EXP='FLY_API_TOKEN_project-6_OS required fly.env:FLY_API_TOKEN_project-6_OS
GH_APP_ID required github-app.env:GH_APP_ID
GH_APP_INSTALLATION_example-org optional github-app.env:GH_APP_INSTALLATION_example-org
GH_APP_PRIVATE_KEY required file:github-app.pem
HARNESS_SECRET required global.env:HARNESS_SECRET
JOBS_URL required global.env:JOBS_URL'
[ "$rc" = 0 ] && [ "$(cat "$O")" = "$EXP" ] && ok "R1 fly-pool project-6-os: the six expanded lines" \
  || { bad "R1 rc=$rc"; sed 's/^/       /' "$O" "$E"; }

rc=$(run "$O" "$E" fly-pool project-6 project-6-os)
[ "$rc" = 0 ] && [ "$(grep -c '^GH_APP_INSTALLATION_example-org ' "$O")" = 1 ] && [ "$(grep -c '^GH_APP_ID ' "$O")" = 1 ] \
  && ok "R2 one owner, one installation line; shared names once" || { bad "R2 rc=$rc"; sed 's/^/       /' "$O"; }
grep -qx 'FLY_API_TOKEN_project-6 required fly.env:FLY_API_TOKEN_project-6' "$O" \
  && grep -qx 'FLY_API_TOKEN_project-6_OS required fly.env:FLY_API_TOKEN_project-6_OS' "$O" \
  && [ "$(wc -l <"$O")" = 7 ] && ok "R2/R5 a token line for each project (7 lines)" || bad "R2/R5 token lines"

rc=$(run "$O" "$E" fly-pool a.b-c)
[ "$rc" = 0 ] && grep -qx 'FLY_API_TOKEN_A_B_C required fly.env:FLY_API_TOKEN_A_B_C' "$O" \
  && grep -qx 'GH_APP_INSTALLATION_MY_ORG optional github-app.env:GH_APP_INSTALLATION_MY_ORG' "$O" \
  && ok "R3 a.b-c -> A_B_C, my-org -> MY_ORG" || { bad "R3 rc=$rc"; sed 's/^/       /' "$O" "$E"; }

rc=$(run "$O" "$E" fly-pool project-6)
grep -qx 'FLY_API_TOKEN_project-6 required fly.env:FLY_API_TOKEN_project-6' "$O" && ! grep -q PROJECT_6_OS "$O" \
  && ok "R5 project-6 alone: FLY_API_TOKEN_project-6, no PROJECT_6_OS" || bad "R5 project-6 expands wrong"

refused() { # refused <label> <want-in-stderr> args...
  local lbl="$1" want="$2"; shift 2
  rc=$(run "$O" "$E" "$@")
  if [ "$rc" = 2 ] && [ ! -s "$O" ] && grep -qF -- "$want" "$E"; then ok "R4 $lbl: rc 2, stdout empty"
  else bad "R4 $lbl: rc=$rc stdout=$(wc -c <"$O")B stderr=$(head -c 200 "$E")"; fi
}
refused "unknown lane nope" "no secret list" nope project-6-os
refused "lane ../etc" "bad lane" ../etc project-6-os
refused "project not in fleet.conf" "no fleet.conf repo" fly-pool nosuch-fixture
refused "no project" "usage" fly-pool
refused "no argument" "usage"
refused "--stage-cmd bad app" "bad app name" --stage-cmd 'Bad_App' fly-pool project-6-os
refused "--stage-cmd with no lane" "usage" --stage-cmd lane-run-mk
# Row cases: a fixture list, the bad row on line 3.
row_case() { # row_case <label> <want> <row>
  printf '# fixture\nGH_APP_ID\trequired\tgithub-app.env:GH_APP_ID\tok row\n%s\n' "$3" > "$R/catalog/lane-run-secrets.d/fixture-lane.tsv"
  refused "$1" "$2" fixture-lane project-6-os
}
row_case "3 fields" ":3: want 4" $'JOBS_URL\trequired\tglobal.env:JOBS_URL'
row_case "5 fields" ":3: want 4" $'JOBS_URL\trequired\tglobal.env:JOBS_URL\tnote\textra'
row_case "need Required" ":3: need 'Required'" $'JOBS_URL\tRequired\tglobal.env:JOBS_URL\tnote'
row_case "need requiredx" ":3: need 'requiredx'" $'JOBS_URL\trequiredx\tglobal.env:JOBS_URL\tnote'
row_case "spaces for tabs" ":3: want 4" 'JOBS_URL required global.env:JOBS_URL note'
row_case "a name that is not a variable" ":3: name" $'JOBS-URL\trequired\tglobal.env:JOBS_URL\tnote'
row_case "a shell word in hub_source" ":3: hub_source" $'JOBS_URL\trequired\tglobal.env:$(id)\tnote'
printf '# fixture\n\nGH_APP_ID\toptional\tgithub-app.env:GH_APP_ID\tok row\n' > "$R/catalog/lane-run-secrets.d/fixture-lane.tsv"
rc=$(run "$O" "$E" fixture-lane project-6-os)
[ "$rc" = 0 ] && [ "$(cat "$O")" = 'GH_APP_ID optional github-app.env:GH_APP_ID' ] \
  && ok "R4 a comment, a blank line and an optional row are accepted" || bad "R4 accepted rows: rc=$rc $(cat "$O" "$E")"

# R6: the production reader in the repo over the repo's own list.
out=$(bash "$REPO/bin/lane-run-secrets.sh" fly-pool project-6-os 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qx 'FLY_API_TOKEN_project-6_OS required fly.env:FLY_API_TOKEN_project-6_OS' <<<"$out" \
  && grep -qx 'GH_APP_PRIVATE_KEY required file:github-app.pem' <<<"$out" \
  && ok "R6 the real reader over the real list" || bad "R6 rc=$rc: $(head -c 300 <<<"$out")"
mv "$R/catalog/lane-run-secrets.d/fly-pool.tsv" "$T/held.tsv" 2>/dev/null
refused "the list deleted" "no secret list" fly-pool project-6-os
mv "$T/held.tsv" "$R/catalog/lane-run-secrets.d/fly-pool.tsv" 2>/dev/null

echo "S1-S3: --stage-cmd"
VAL=fixture-secret-VALUE
cat > "$R/env/fly.env" <<EOF
FLY_API_TOKEN_project-6_OS=$VAL
FLY_API_TOKEN='FlyV1 fixture-org-token'
EOF
cat > "$R/env/github-app.env" <<'EOF'
GH_APP_ID=fixture-app-id-1
GH_APP_PRIVATE_KEY_FILE=/nonexistent/fixture.pem
GH_APP_INSTALLATION_example-org=fixture-inst-1
EOF
cat > "$R/env/global.env" <<'EOF'
JOBS_URL=https://jobs.example.invalid
HARNESS_SECRET=fixture-harness-secret
EOF
printf -- '-----BEGIN FIXTURE KEY-----\nfixture\n-----END FIXTURE KEY-----\n' > "$R/env/github-app.pem"
export HARNESS_ENV_DIR="$R/env"
rc=$(run "$O" "$E" --stage-cmd lane-run-mk fly-pool project-6-os)
[ "$rc" = 0 ] && [ "$(grep -c 'flyctl secrets import -a lane-run-mk --stage$' "$O")" = 1 ] \
  && [ "$(grep -c '^# GH_APP_PRIVATE_KEY: ' "$O")" = 1 ] && [ "$(wc -l <"$O")" = 2 ] \
  && ok "S1 one import command and one by-hand line for the PEM" || { bad "S1 rc=$rc"; sed 's/^/       /' "$O" "$E"; }
cp "$O" "$T/stage.sh"

# S2: run it. The fake flyctl records its argv and stdin.
FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/flyctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$T/fly.argv"
cat > "$T/fly.stdin"
EOF
chmod +x "$FB/flyctl"
rm -f "$T/fly.argv" "$T/fly.stdin"
( unset FLY_API_TOKEN_project-6_OS GH_APP_ID GH_APP_INSTALLATION_example-org JOBS_URL HARNESS_SECRET FLY_API_TOKEN
  PATH="$FB:$PATH" bash "$T/stage.sh" ) >"$T/s2.out" 2>"$T/s2.err"; src=$?
WANT_IN="FLY_API_TOKEN_project-6_OS=$VAL
GH_APP_ID=fixture-app-id-1
GH_APP_INSTALLATION_example-org=fixture-inst-1
HARNESS_SECRET=fixture-harness-secret
JOBS_URL=https://jobs.example.invalid"
[ "$src" = 0 ] && [ "$(LC_ALL=C sort "$T/fly.stdin" 2>/dev/null)" = "$WANT_IN" ] \
  && ok "S2 the fake flyctl got every non-file NAME=value line on stdin" || { bad "S2 rc=$src stdin:"; sed 's/^/       /' "$T/fly.stdin" "$T/s2.err" 2>/dev/null; }
# Round-trip: the names on stdin are the reader's list minus the file: rows.
LISTN=$(bash "$RD" fly-pool project-6-os | awk '$3 !~ /^file:/ {print $1}' | LC_ALL=C sort)
[ -n "$LISTN" ] && [ "$(cut -d= -f1 "$T/fly.stdin" 2>/dev/null | LC_ALL=C sort)" = "$LISTN" ] \
  && ok "S2 stdin names = the list minus file: rows" || bad "S2 stdin names differ from the list"
[ "$(cat "$T/fly.argv" 2>/dev/null)" = "secrets import -a lane-run-mk --stage" ] && ! grep -q fixture "$T/fly.argv" "$T/s2.out" \
  && ok "S2 argv is exactly 'secrets import -a lane-run-mk --stage', no value" || bad "S2 argv: $(cat "$T/fly.argv" 2>/dev/null)"
# An optional variable that is not set sends no line.
sed -i '/^GH_APP_INSTALLATION_example-org=/d' "$R/env/github-app.env"
( unset FLY_API_TOKEN_project-6_OS GH_APP_ID GH_APP_INSTALLATION_example-org JOBS_URL HARNESS_SECRET
  PATH="$FB:$PATH" bash "$T/stage.sh" ) >/dev/null 2>&1
! grep -q '^GH_APP_INSTALLATION_' "$T/fly.stdin" && [ "$(wc -l <"$T/fly.stdin")" = 4 ] \
  && ok "S2 an unset optional variable sends no line" || bad "S2 optional: $(cat "$T/fly.stdin")"
# A required variable that is empty: no line at all, and the error names it.
cat > "$R/env/global.env" <<'EOF2'
JOBS_URL=https://jobs.example.invalid
HARNESS_SECRET=
EOF2
( unset FLY_API_TOKEN_project-6_OS GH_APP_ID GH_APP_INSTALLATION_example-org JOBS_URL HARNESS_SECRET
  PATH="$FB:$PATH" bash "$T/stage.sh" ) >/dev/null 2>"$T/s2.err"
[ ! -s "$T/fly.stdin" ] && grep -q 'HARNESS_SECRET' "$T/s2.err" && ! grep -q "$VAL" "$T/s2.err" \
  && ok "S2 an empty required variable stops it before any line" || bad "S2 empty required: stdin=$(cat "$T/fly.stdin") err=$(cat "$T/s2.err")"

# S3: the reader itself, every verb, never prints a value or a status word.
ALL="$T/s3"; : > "$ALL"
for args in "fly-pool project-6-os" "fly-pool project-6 project-6-os" "--stage-cmd lane-run-mk fly-pool project-6-os"; do
  # The values are in the reader's own environment: a reader that expanded one
  # would print it.
  # shellcheck disable=SC2086
  FLY_API_TOKEN_project-6_OS="$VAL" GH_APP_ID=fixture-app-id-1 HARNESS_SECRET=fixture-harness-secret \
    bash "$RD" $args >>"$ALL" 2>&1
done
! grep -qE "$VAL|fixture-app-id-1|fixture-harness-secret|FIXTURE KEY" "$ALL" && ok "S3 no fixture value in any output" \
  || bad "S3 a value leaked: $(grep -E "$VAL|fixture-" "$ALL" | head -3)"
! grep -qiwE 'ok|staged|ready' "$ALL" && ok "S3 no line says ok, staged or ready" || bad "S3 status word: $(grep -iwE 'ok|staged|ready' "$ALL" | head -3)"

echo
echo "lane-run-secrets: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
