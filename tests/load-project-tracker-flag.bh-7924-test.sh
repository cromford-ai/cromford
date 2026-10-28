#!/bin/bash
# tests/load-project-tracker-flag.bh-7924-test.sh — BH-7924 (T8):
# bin/load-project.sh --tracker linear|jira --prefix <KEY> writes the tracker
# settings rows through bin/jobs-client.sh setting-set, before the registry
# row and before the prompt render (which reads tracker_kind, BH-8450).
#
#   L1  --tracker linear --prefix CRO (file mode): tracker_linear.<p>.team=CRO
#       and tracker_adapter.<p>=linear, each written before the fleet.conf row
#       and the prompt exist; the row keeps column 4 `-`
#   L2  --tracker jira --prefix SCRUM: tracker_jira.<p>.write_projects,
#       read_projects and comment_projects = SCRUM, and tracker_adapter.<p>=jira
#   L3  the same writes with REGISTRY_SOURCE=db (a stub bin/registry.sh), and
#       fleet.conf is not touched
#   L4  --tracker trello, --tracker linear with no --prefix, and a prefix the
#       adapter refuses: rc 2, nothing written (no row, no prompt, no setting)
#   L5  a failed setting write is FATAL before any registry write: rc != 0,
#       no fleet.conf row, no prompt
#   L6  without --tracker no setting is written (the old path)
#
# gh, git's network verbs and bin/jobs-client.sh are stubs; the checkout is a
# scratch git repo. Nothing leaves the machine.
#   HARNESS_TEST_SANDBOX=1 bash tests/load-project-tracker-flag.bh-7924-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

REAL_GIT=$(command -v git); export REAL_GIT
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
STUB
chmod +x "$T/stub/gh" "$T/stub/git"

# The jobs-client stub. Run as `setting-set <key> <value> [note]` it records
# the write and whether the registry row and the prompt existed at that
# moment. Sourced (tracker_kind in the prompt render), it answers setting_get
# from what was recorded.
JC_STUB='#!/bin/bash
setting_get() {
  local v
  v=$(awk -F "\t" -v k="$1" '"'"'$2 == k {v = $3} END {if (v != "") print v}'"'"' "$LP_SETS" 2>/dev/null)
  [ -n "$v" ] || return 2
  printf "%s" "$v"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ "${1:-}" = setting-set ] || exit 1
  [ -e "$LP_FAIL" ] && exit 1
  row=no; grep -q "^$LP_PROJECT " "$LP_ROWS" 2>/dev/null && row=yes
  prompt=no; [ -e "prompts/$LP_PROJECT.md" ] && prompt=yes
  printf "%s\t%s\t%s\trow=%s\tprompt=%s\n" "$1" "$2" "$3" "$row" "$prompt" >> "$LP_SETS"
  exit 0
fi'

mkrepo() { # mkrepo <dir> — a scratch cromford checkout
  local R="$1" s
  mkdir -p "$R/prompts/_template"
  for s in bin/load-project.sh bin/fleet-conf.sh bin/box-for.sh bin/lib/tracker.sh; do
    ( cd "$DIR" && scratch_install_closure "$s" "$R" ) >/dev/null || return 1
  done
  printf '%s\n' "$JC_STUB" > "$R/bin/jobs-client.sh"; chmod +x "$R/bin/jobs-client.sh"
  cp "$DIR/prompts/TEMPLATE-GH.md" "$R/prompts/TEMPLATE-GH.md"
  # A linear or jira project's prompt render appends this fragment (obs_prompt).
  cp "$DIR/prompts/_template/trk-commands.md" "$R/prompts/_template/trk-commands.md"
  printf 'alpha  Acme/alpha  -  -  2  box-small\n' > "$R/fleet.conf"
  (
    cd "$R" || exit 1
    "$REAL_GIT" init -q .
    "$REAL_GIT" config user.email t@t
    "$REAL_GIT" config user.name t
    "$REAL_GIT" add -A
    "$REAL_GIT" commit -qm base
  ) >/dev/null 2>&1
}
# load <repo> <name> <args...> — the real loader; rc in RC, sets in $T/<name>.sets
load() {
  local R="$1" n="$2"; shift 2
  : > "$T/$n.sets"
  RC=0
  ( cd "$R" && env -u REGISTRY_SOURCE PATH="$T/stub:$PATH" HARNESS="$R" LP_SETS="$T/$n.sets" \
      LP_FAIL="$T/$n.fail" LP_PROJECT="${LP_PROJECT:-newp}" LP_ROWS="${LP_ROWS:-$R/fleet.conf}" \
      ${LP_ENV:-} bash bin/load-project.sh "$@" ) > "$T/$n.out" 2>&1 || RC=$?
}
sets() { cut -f2,3 "$T/$1.sets" | tr '\t' '=' | tr '\n' ' '; }

# ---- L1 linear, file mode --------------------------------------------------------
mkrepo "$T/l1" || { echo "FAIL: scratch checkout"; exit 1; }
load "$T/l1" l1 Acme/newp --box box-small --no-bootstrap --tracker linear --prefix CRO
eq "L1 rc" "$RC" 0
[ "$RC" = 0 ] || cat "$T/l1.out"
eq "L1 rows" "$(sets l1)" "tracker_linear.newp.team=CRO tracker_adapter.newp=linear "
eq "L1 written before the registry row and the prompt" "$(cut -f4,5 "$T/l1.sets" | sort -u | tr '\t\n' '  ')" "row=no prompt=no "
eq "L1 fleet.conf column 4 stays -" "$(awk '$1 == "newp" {print $4}' "$T/l1/fleet.conf")" "-"
[ -e "$T/l1/prompts/newp.md" ] && ok || bad "L1 the prompt was not rendered"

# ---- L2 jira ----------------------------------------------------------------------
mkrepo "$T/l2" || { echo "FAIL: scratch checkout"; exit 1; }
load "$T/l2" l2 Acme/newp --box box-small --no-bootstrap --tracker jira --prefix SCRUM
eq "L2 rc" "$RC" 0
eq "L2 rows" "$(sets l2)" "tracker_jira.newp.write_projects=SCRUM tracker_jira.newp.read_projects=SCRUM tracker_jira.newp.comment_projects=SCRUM tracker_adapter.newp=jira "
eq "L2 written before the registry row and the prompt" "$(cut -f4,5 "$T/l2.sets" | sort -u | tr '\t\n' '  ')" "row=no prompt=no "

# ---- L3 REGISTRY_SOURCE=db ---------------------------------------------------------
mkrepo "$T/l3" || { echo "FAIL: scratch checkout"; exit 1; }
# db mode: bin/registry.sh add-project appends to a fixture registry, and
# fleet-conf.sh reads that registry (the real script over the fixture file).
mv "$T/l3/bin/fleet-conf.sh" "$T/l3/bin/fleet-conf.real.sh"
cp "$T/l3/fleet.conf" "$T/l3.db"
printf '#!/bin/bash\nFLEET_CONF="%s" REGISTRY_SOURCE=file exec "%s/bin/fleet-conf.real.sh" "$@"\n' "$T/l3.db" "$T/l3" > "$T/l3/bin/fleet-conf.sh"
cat > "$T/l3/bin/registry.sh" <<STUB
#!/bin/bash
[ "\$1" = add-project ] || exit 1
p="\$2"; shift 2; repo=""; prod=-; off=0; box=""
while [ \$# -gt 0 ]; do case "\$1" in --repo) repo="\$2" ;; --prod) prod="\$2" ;; --offset) off="\$2" ;; --box) box="\$2" ;; esac; shift 2; done
printf '%s %s %s - %s %s\n' "\$p" "\$repo" "\$prod" "\$off" "\$box" >> "$T/l3.db"
echo "registry: add-project changed=1 version=2"
STUB
chmod +x "$T/l3/bin/fleet-conf.sh" "$T/l3/bin/registry.sh"
cp "$T/l3/fleet.conf" "$T/l3.fleet.orig"
LP_ROWS="$T/l3.db" LP_ENV="REGISTRY_SOURCE=db REGISTRY_ADMIN_TOKEN=fixture-admin-token" \
  load "$T/l3" l3 Acme/newp --box box-small --no-bootstrap --tracker linear --prefix CRO
eq "L3 rc" "$RC" 0
[ "$RC" = 0 ] || cat "$T/l3.out"
eq "L3 rows" "$(sets l3)" "tracker_linear.newp.team=CRO tracker_adapter.newp=linear "
eq "L3 written before the registry row" "$(cut -f4 "$T/l3.sets" | sort -u)" "row=no"
grep -q '^newp ' "$T/l3.db" && ok || bad "L3 the registry stub got no row"
cmp -s "$T/l3/fleet.conf" "$T/l3.fleet.orig" && ok || bad "L3 db mode changed fleet.conf"

# ---- L4 refusals -------------------------------------------------------------------
mkrepo "$T/l4" || { echo "FAIL: scratch checkout"; exit 1; }
H4=$("$REAL_GIT" -C "$T/l4" rev-parse HEAD)
for args in "--tracker trello --prefix CRO" "--tracker linear" "--tracker jira --prefix S" "--tracker linear --prefix cro" "--tracker"; do
  # shellcheck disable=SC2086 # the flag list is split on purpose
  load "$T/l4" l4 Acme/newp --box box-small --no-bootstrap $args
  eq "L4 '$args' rc" "$RC" 2
  eq "L4 '$args' no setting" "$(cat "$T/l4.sets")" ""
done
grep -q '^newp ' "$T/l4/fleet.conf" && bad "L4 a refusal wrote a registry row" || ok
[ -e "$T/l4/prompts/newp.md" ] && bad "L4 a refusal rendered a prompt" || ok
eq "L4 no commit" "$("$REAL_GIT" -C "$T/l4" rev-parse HEAD)" "$H4"

# ---- L5 a failed setting write -------------------------------------------------------
mkrepo "$T/l5" || { echo "FAIL: scratch checkout"; exit 1; }
touch "$T/l5.fail"
load "$T/l5" l5 Acme/newp --box box-small --no-bootstrap --tracker linear --prefix CRO
[ "$RC" != 0 ] && ok || bad "L5 rc 0 after a failed setting write"
grep -q 'FATAL' "$T/l5.out" && ok || bad "L5 no FATAL line: $(cat "$T/l5.out")"
grep -q '^newp ' "$T/l5/fleet.conf" && bad "L5 a registry row was written after the failed setting" || ok
[ -e "$T/l5/prompts/newp.md" ] && bad "L5 a prompt was rendered after the failed setting" || ok

# ---- L6 no --tracker -------------------------------------------------------------------
mkrepo "$T/l6" || { echo "FAIL: scratch checkout"; exit 1; }
load "$T/l6" l6 Acme/newp --box box-small --no-bootstrap
eq "L6 rc" "$RC" 0
eq "L6 no setting" "$(cat "$T/l6.sets")" ""

echo "load-project-tracker-flag.bh-7924-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
