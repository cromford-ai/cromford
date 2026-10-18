#!/bin/bash
# tests/registry-seed-role.bh-7191-test.sh — BH-7303 (BH-7191.1): every box in
# the fleet registry has a role, and the readers agree on it.
#
#   R1 the committed fleet.conf: `bin/fleet-conf.sh --boxes-with-roles` has
#      box-review-2 review2 review and bh-hub-2 hub2 hub
#   R2-R5 the defaults: a project-row box is build, the hub (and `local`) is
#      hub, the `@standby` box is standby, a `@retired`-only box is retired
#   R6 a `# @box <box> <ip>` line, a 4-field `@boxrole` line and an unknown
#      role give no line
#   S1-S3 `bin/registry-seed.sh --emit`: the box rows carry the same roles,
#      and an `@boxrole` box keeps its own box_id
#   R7 db mode: `_rg_render` prints `# @boxrole`, the db-mode
#      `--boxes-with-roles` answers the registry's role, and the
#      `registry-export.sh --snapshot` import.json box row carries `role`
#   R8 `bin/registry.sh set-box-role` / `add-box --role` (curl stub)
#   D1-D6 `fvc_decide` with the real rules dir: gate-only and retired SKIP
#      and stop the later rules; any other role is not the role rule's business
#   B1 `bin/box-lists-check.sh` on the committed tree: the `@boxrole` box ids
#      in catalog/lanes.d are not strangers
# Run from anywhere: tests/registry-seed-role.bh-7191-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FC="$DIR/bin/fleet-conf.sh"
SEED="$DIR/bin/registry-seed.sh"
REG="$DIR/bin/registry.sh"
EXPORT="$DIR/bin/registry-export.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1 (want '$3', got '$2')"; fi; }
has() { if grep -qxF -- "$3" <<<"$2"; then ok; else bad "$1 (no line '$3' in: $(tr '\n' '|' <<<"$2"))"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1 (unexpected '$3' in: $(tr '\n' '|' <<<"$2"))"; else ok; fi; }
unset HUB_BOX_NAME LANE_REGISTRY
export REGISTRY_SOURCE=file
TAB=$'\t'
roles() { env FLEET_CONF="$1" "$FC" --boxes-with-roles; }

# ---- R1 the committed fleet.conf ---------------------------------------------------------
OUT=$(roles "$DIR/fleet.conf"); R=$?
eq "R1 rc" "$R" 0
has "R1 review-2 from its @boxrole line" "$OUT" "box-review-2${TAB}review2${TAB}review"
has "R1 bh-hub-2 from its @boxrole line" "$OUT" "bh-hub-2${TAB}hub2${TAB}hub"
has "R1 the hub is always listed" "$OUT" "box-hub${TAB}hub${TAB}hub"
has "R1 a project box is build" "$OUT" "box-project-3-2${TAB}project-3${TAB}build"
has "R1 the @standby box is standby" "$OUT" "box-small${TAB}small${TAB}standby"
has "R1 the @retired-only box is retired" "$OUT" "box-project-10-1${TAB}project-10${TAB}retired"
eq "R1 one line per box" "$(cut -f1 <<<"$OUT" | sort | uniq -d)" ""
eq "R1 sorted by box" "$(cut -f1 <<<"$OUT")" "$(cut -f1 <<<"$OUT" | LC_ALL=C sort)"

# ---- R2-R6 a fixture -----------------------------------------------------------------------
TREE="$T/tree"; mkdir -p "$TREE/catalog"
cat > "$TREE/fleet.conf" <<'EOF'
# fixture registry
# @standby box-small box-hub hub
# @box box-x 192.0.2.9
# @boxrole box-review-2 review2 review
# @boxrole box-gate-1 gate1 gate-only
# @boxrole box-short shortid
# @boxrole box-odd oddid boss
# @retired gone-os box-gone
# @retired alpha-old box-alpha
alpha-os Org/alpha https://a.example /api/board 2 box-alpha 192.0.2.1
small-os Org/small https://s.example /api/board 4 box-small 192.0.2.2
home-os  Org/home  - - 6 local
EOF
OUT=$(roles "$TREE/fleet.conf"); R=$?
eq "R2 rc" "$R" 0
has "R2 a project-row box is build" "$OUT" "box-alpha${TAB}alpha${TAB}build"
has "R3 the hub is hub" "$OUT" "box-hub${TAB}hub${TAB}hub"
eq "R3 a local row adds no second hub line" "$(grep -c "${TAB}hub${TAB}" <<<"$OUT")" 1
has "R4 the @standby box is standby, not build" "$OUT" "box-small${TAB}small${TAB}standby"
has "R5 a @retired-only box is retired" "$OUT" "box-gone${TAB}gone${TAB}retired"
has "R5 a project row outranks @retired" "$OUT" "box-alpha${TAB}alpha${TAB}build"
has "R2 @boxrole wins" "$OUT" "box-gate-1${TAB}gate1${TAB}gate-only"
hasnt "R6 a # @box line is never a role line" "$OUT" "box-x"
hasnt "R6 a 4-field @boxrole line gives no line" "$OUT" "box-short"
hasnt "R6 an unknown role gives no line" "$OUT" "box-odd"
eq "R6 exactly the six boxes" "$(grep -c . <<<"$OUT")" 6
printf '# nothing\n' > "$T/empty.conf"
H1=$(roles "$T/empty.conf"); R=$?
eq "R6 a file with no rows still lists the hub, rc 0" "$R:$H1" "0:box-hub${TAB}hub${TAB}hub"
OUT2=$(env HUB_BOX_NAME=box-9 FLEET_CONF="$TREE/fleet.conf" "$FC" --boxes-with-roles)
has "R3 HUB_BOX_NAME names the hub" "$OUT2" "box-9${TAB}hub${TAB}hub"

# ---- S1-S3 the seed ------------------------------------------------------------------------
printf '{"box_aliases":{"box-hub":"hub","box-alpha":"alpha"},"accounts":{}}\n' > "$TREE/catalog/cost-accounts.json"
cat > "$T/lanes.json" <<'EOF'
{"lanes":[{"id":"watchdog-ping","boxes":["alpha","ghost"]},{"id":"harness-sync-timer","boxes":["alpha"]},{"id":"other","boxes":["alpha","small"]}]}
EOF
env LANE_REGISTRY="$T/lanes.json" "$SEED" --emit --root "$TREE" > "$T/seed.json" 2>"$T/seed.err"; R=$?
eq "S1 --emit rc ($(head -c 200 "$T/seed.err"))" "$R" 0
box() { jq -r --arg b "$1" '.boxes[] | select(.box == $b) | "\(.box_id) \(.role)"' "$T/seed.json"; }
eq "S1 an @boxrole box seeds its own box_id and role" "$(box box-review-2)" "review2 review"
eq "S1 a gate-only @boxrole box seeds gate-only" "$(box box-gate-1)" "gate1 gate-only"
eq "S2 a project box seeds build" "$(box box-alpha)" "alpha build"
eq "S3 the @standby box seeds standby" "$(box box-small)" "small standby"
eq "S1 the hub seeds hub" "$(box box-hub)" "hub hub"
eq "S1 a @retired-only box seeds retired" "$(box box-gone)" "gone retired"
eq "S1 every box row has a role key" "$(jq '[.boxes[] | has("role")] | all' "$T/seed.json")" true
# A box known only from cost-accounts aliases has no role.
jq '.box_aliases["box-alias"] = "alias"' "$TREE/catalog/cost-accounts.json" > "$T/ca" && mv "$T/ca" "$TREE/catalog/cost-accounts.json"
env LANE_REGISTRY="$T/lanes.json" "$SEED" --emit --root "$TREE" > "$T/seed2.json" 2>/dev/null
eq "S1 an alias-only box has a null role" "$(jq -r '.boxes[] | select(.box == "box-alias") | .role' "$T/seed2.json")" null

# The committed tree: the two @boxrole boxes are in the seed.
env "$SEED" --emit --root "$DIR" > "$T/seed-main.json" 2>/dev/null
eq "S1 committed: review-2" "$(jq -r '.boxes[] | select(.box == "box-review-2") | "\(.box_id) \(.role)"' "$T/seed-main.json")" "review2 review"
eq "S1 committed: bh-hub-2" "$(jq -r '.boxes[] | select(.box == "bh-hub-2") | "\(.box_id) \(.role)"' "$T/seed-main.json")" "hub2 hub"

# ---- R7 db mode, the render and the export -------------------------------------------------
HD="$T/hdb"; mkdir -p "$HD/state/registry" "$HD/logs"
cat > "$T/registry.json" <<'EOF'
{"version": 3,
 "projects": [{"project":"alpha-os","repo":"Org/alpha","prod":"https://a.example","board_prefix":"/api/board","cron_offset":2,"box":"box-alpha","position":0,"status":"active"}],
 "boxes": [
   {"box":"box-alpha","box_id":"alpha","tailnet_ip":"192.0.2.1","cost_box":"alpha","standby_hub_name":null,"standby_hub_id":null,"role":null},
   {"box":"box-gate-1","box_id":"gate1","tailnet_ip":"192.0.2.7","cost_box":null,"standby_hub_name":null,"standby_hub_id":null,"role":"gate-only"}],
 "lane_boxes": [{"lane":"watchdog-ping","box_id":"alpha"}],
 "box_accounts": []}
EOF
RENDER=$( . "$DIR/bin/lib/registry.sh" && _rg_render "$T/registry.json" ); R=$?
eq "R7 _rg_render rc" "$R" 0
has "R7 _rg_render prints the role line" "$RENDER" "# @boxrole box-gate-1 gate1 gate-only"
hasnt "R7 _rg_render prints no role line for a null role" "$RENDER" "@boxrole box-alpha"
cp "$T/registry.json" "$HD/state/registry/registry.json"
printf '%s\n' "$RENDER" > "$HD/state/registry/fleet.conf"
echo 3 > "$HD/state/registry/version"
DB=$(env REGISTRY_SOURCE=db HARNESS="$HD" JOBS_URL= HARNESS_SECRET= FLEET_CONF="$T/empty.conf" "$FC" --boxes-with-roles); R=$?
eq "R7 db-mode rc" "$R" 0
has "R7 db mode answers the registry's gate-only" "$DB" "box-gate-1${TAB}gate1${TAB}gate-only"
has "R7 db mode: a null role reads as the default" "$DB" "box-alpha${TAB}alpha${TAB}build"
env HARNESS="$HD" REGISTRY_EXPORT_NOW=1760000000 "$EXPORT" --snapshot "$T/snap" --registry "$T/registry.json" --checkout "$T/nocheckout" >/dev/null 2>"$T/exp.err"; R=$?
eq "R7 --snapshot rc ($(head -c 200 "$T/exp.err"))" "$R" 0
eq "R7 import.json keeps the role" "$(jq -r '.boxes[] | select(.box == "box-gate-1") | .role' "$T/snap/latest/import.json" 2>/dev/null)" gate-only
eq "R7 import.json keeps a null role as null" "$(jq -r '.boxes[] | select(.box == "box-alpha") | .role' "$T/snap/latest/import.json" 2>/dev/null)" null
# A template @boxrole line prints verbatim.
printf '# @boxrole box-review-2 review2 review\nalpha-os Org/alpha https://a.example /api/board 2 box-alpha 192.0.2.1\n' > "$T/tpl.conf"
TPL=$(env HARNESS="$HD" "$EXPORT" --fleet-conf --template "$T/tpl.conf" --registry "$T/registry.json" 2>/dev/null)
has "R7 a template @boxrole line prints verbatim" "$TPL" "# @boxrole box-review-2 review2 review"

# ---- R8 the CLI ----------------------------------------------------------------------------
mkdir -p "$T/cbin" "$T/cstub"
cat > "$T/cbin/curl" <<'SH'
#!/bin/bash
S="${CURL_STUB_DIR:?}"
M=GET; U="${!#}"; B=""
while [ $# -gt 0 ]; do
  case "$1" in -X) M="$2"; shift 2 ;; --data-binary) B="$2"; shift 2 ;; *) shift ;; esac
done
case "$B" in @*) B=$(cat "${B#@}") ;; esac
printf '%s %s %s\n' "$M" "$U" "$B" >> "$S/calls"
printf '{"ok":true,"changed":1,"version":4}\n200'
SH
chmod +x "$T/cbin/curl"
cli() { env PATH="$T/cbin:$PATH" HARNESS="$T/nohome" CURL_STUB_DIR="$T/cstub" JOBS_URL=http://jobs.test \
  HARNESS_SECRET=sec-fixture REGISTRY_ADMIN_TOKEN=adm-fixture "$REG" "$@"; }
: > "$T/cstub/calls"
cli set-box-role bh-hub-2 gate-only --actor t >/dev/null 2>"$T/cli.err"; R=$?
eq "R8 set-box-role rc ($(head -c 200 "$T/cli.err"))" "$R" 0
L=$(head -1 "$T/cstub/calls")
eq "R8 set-box-role PATCHes the box" "${L%% \{*}" "PATCH http://jobs.test/api/registry/boxes/bh-hub-2"
eq "R8 the body carries the role" "$(jq -r .role <<<"{${L#*\{}")" gate-only
: > "$T/cstub/calls"
cli add-box box-review-2 --ip 192.0.2.5 --like small --id review2 --role review --actor t >/dev/null 2>&1; R=$?
eq "R8 add-box --role rc" "$R" 0
L=$(head -1 "$T/cstub/calls")
eq "R8 add-box posts the role" "$(jq -r '"\(.role) \(.box_id)"' <<<"{${L#*\{}")" "review review2"
: > "$T/cstub/calls"
cli add-box box-z --ip 192.0.2.6 --like small --actor t >/dev/null 2>&1
L=$(head -1 "$T/cstub/calls")
eq "R8 add-box with no --role sends no role key" "$(jq -r 'has("role")' <<<"{${L#*\{}")" false
: > "$T/cstub/calls"
cli set-box-role bh-hub-2 >/dev/null 2>&1; R=$?
eq "R8 set-box-role with no role is rc 2" "$R" 2
eq "R8 ... and makes no call" "$(grep -c . "$T/cstub/calls")" 0
cli set-box-role >/dev/null 2>&1; R=$?
eq "R8 set-box-role with no box is rc 2" "$R" 2
cli show a b >/dev/null 2>&1; R=$?
eq "R8 a second name on another verb is still refused" "$R" 2

# ---- D1-D6 the role rule through fvc_decide ------------------------------------------------
NOWE=1760000000
decide() { # decide <role> <lag> -> fvc_decide's lines for one row
  ( . "$DIR/bin/lib/fleet-version-decide.sh" || exit 9
    printf 'box-q\t%s\tabcdef1234567890\t%s\t%s\t\t1\t\n' "$1" "$NOWE" "$2" \
      | FVC_NOW="$NOWE" fvc_decide )
}
OUT=$(decide gate-only 900)
eq "D1 gate-only: exactly the one SKIP line" "$OUT" "SKIP box-q gate-only (registry role)"
OUT=$(decide retired 900)
eq "D2 retired: exactly the one SKIP line" "$OUT" "SKIP box-q retired"
for RL in gate GATE-ONLY "" gate-only-x review; do
  OUT=$(decide "$RL" 5)
  hasnt "D3-D5 role '$RL' is not skipped" "$OUT" "SKIP"
  has "D3-D5 role '$RL' reaches the lag rule" "$OUT" "OK box-q lag=5m"
done
OUT=$(decide build 900)
has "D6 build with lag 900 still ALERTs from the lag rule" "$OUT" "ALERT box-q lag lag=900m sha=abcdef12"
hasnt "D6 build is not skipped" "$OUT" "SKIP"
# The rule alone: silent rc 0 for any other role, rc 2 for the two.
RR=$( . "$DIR/bin/lib/fleet-version-rules.d/10-role.sh"; FVC_BOX=b FVC_ROLE=build fvc_rule_role; echo "rc=$?" )
eq "D6 fvc_rule_role on build prints nothing and is rc 0" "$RR" "rc=0"
RR=$( FVC_RULES=(); . "$DIR/bin/lib/fleet-version-rules.d/10-role.sh"; FVC_BOX=b FVC_ROLE=retired fvc_rule_role >/dev/null; echo "rc=$?" )
eq "D2 fvc_rule_role on retired is rc 2" "$RR" "rc=2"

# ---- B1 the box lists accept the @boxrole ids ----------------------------------------------
OUT=$("$DIR/bin/box-lists-check.sh" --root "$DIR" 2>&1); R=$?
eq "B1 box-lists-check on the committed tree ($(tail -3 <<<"$OUT" | tr '\n' '|'))" "$R" 0

echo "registry-seed-role.bh-7191-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
