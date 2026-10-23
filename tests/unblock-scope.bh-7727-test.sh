#!/bin/bash
# tests/unblock-scope.bh-7727-test.sh — BH-7727 (UNB-5): the unblock lane's
# per-project opt-in, bin/lib/unblock/scope.sh, and its seed fragment.
#
#   S0  the seed fragment: 12 `off` mode rows, no cromford row, the
#       project-6-os standing approval, an operator row survives a re-apply,
#       and the sqlite -> settings cache -> scope.sh round trip
#   S1  unb_scope_mode: the mode table (case, spaces, near misses, prefix)
#   S2  unb_scope_approved: only `1` is approved
#   S3  unb_scope_decide (plan S5 case 1): skip / would / would-escalate / act /
#       escalate, and a bad needs_approval refused
#   S4  unb_scope_lock (plan S5 case 2): two projects hold separate locks at
#       once; the same project twice is busy; a bad name is rc 2
#   S5  unb_scope_projects: only shadow/act projects, in fleet.conf order
#   S6  fail closed: no cache, empty root, a stale cache, no lane-gate
#   S7  agreement with the writer: for every S1 row value, unb_scope_mode and
#       act.sh's _ub_mode (gate 3, live setting-get) give the same mode
#
# The grammar is act.sh's _ub_mode: strip every whitespace character, then
# exactly `act` or `shadow`; no case fold. A project name is never lowercased.
#
# No worker, no network, no vendor (BH-7563): every harness is a scratch tree
# with a fixture settings cache, a fixture fleet.conf and no bin/jobs-client.sh.
# The clock is pinned (LANE_GATE_NOW). Each case builds its own harness.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-scope.bh-7727-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

LIB_REL=bin/lib/unblock/scope.sh
[ -s "$REPO/bin/lib/unblock/scope.sh" ] || bad "setup: $REPO/bin/lib/unblock/scope.sh is missing"
# The fragment is named by the UTC minute it was written; find it by its slug.
SEEDS=("$REPO"/worker/jobs/schema.d/*-bh-7727-unblock-projects.sql)
[ "${#SEEDS[@]}" = 1 ] && [ -s "${SEEDS[0]}" ] || bad "setup: want exactly one schema.d/*-bh-7727-unblock-projects.sql, got ${#SEEDS[@]}"
SEED=${SEEDS[0]}
NOW=1792000000            # 2026-10-14T00:26:40Z, pinned
export LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60
unset PL_LANE PL_PROJECT PL_LOCK_FD PL_TEST_BARRIER LANE_GATE_DISABLE REGISTRY_SOURCE

# mkh <name> [fetched_at] — a scratch harness with the lib's closure and
# bin/fleet-conf.sh, a fixture fleet.conf, and no worker client. Prints its path.
mkh() {
  local h="$T/$1"
  mkdir -p "$h/bin" "$h/state" "$h/locks" "$h/logs"
  # A setup failure is recorded in a file (this runs inside $(...), where a
  # FAIL count or an echo would be lost or would corrupt the printed path).
  ( cd "$REPO" && scratch_install_closure "$LIB_REL" "$h" && scratch_install_closure bin/fleet-conf.sh "$h" ) >/dev/null 2>&1 \
    || echo "setup $1: could not install the closure" >> "$T/setup-failed"
  rm -f "$h/bin/jobs-client.sh"
  printf '# fixture fleet\nalpha a/a\nbeta b/b\ngamma g/g\ndelta d/d\n' > "$h/fleet.conf"
  printf '%s' "$h"
}

# cache <harness> <fetched_at> [key=value ...] — write state/settings-cache.json
# in the shape _lg_settings_refresh writes (values / seeded maps).
cache() {
  local h="$1" fa="$2" kv args=()
  shift 2
  for kv in "$@"; do args+=("${kv%%=*}" "${kv#*=}"); done
  jq -nc --argjson fa "$fa" '$ARGS.positional as $a
    | {fetched_at:$fa, values:(reduce range(0; $a|length; 2) as $i ({}; .[$a[$i]] = $a[$i+1])), seeded:{}}' \
    --args "${args[@]}" > "$h/state/settings-cache.json"
}

# run <harness> <cmd...> — a fresh shell that sources the lib from <harness>
# with HARNESS=<harness> and runs <cmd>. Prints `<stdout>|rc=<rc>`.
run() {
  local h="$1" out rc
  shift
  out=$(HARNESS="$h" H="" FLEET_CONF="$h/fleet.conf" bash -c '. "$HARNESS/bin/lib/unblock/scope.sh" || exit 9; "$@"' _ "$@" 2>/dev/null)
  rc=$?
  printf '%s|rc=%s' "$out" "$rc"
}

# ══ S0: the seed fragment ═══════════════════════════════════════════════════
echo "S0 seed fragment"
if [ ! -s "$SEED" ]; then
  bad "S0 missing $SEED"
elif ! python3 -I -c 'import sqlite3' 2>/dev/null; then
  echo "S0 skipped: python3 sqlite3 missing"
else
  HARNESS_TEST_SANDBOX=1 bash "$REPO/bin/schema-build.sh" --root "$REPO" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
    || bad "S0 bin/schema-build.sh --to failed"
  grep -qF "unblock.standing_approval.project-6-os" "$T/schema.sql" 2>/dev/null \
    && ok "S0 the composed schema carries the fragment" || bad "S0 the composed schema lacks the fragment"
  GOT=$(python3 -I - "$T/schema.sql" "$SEED" "$T/s0-cache.json" "$NOW" <<'PY' 2>&1
import json, sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
modes = dict(db.execute("SELECT key, value FROM settings WHERE key LIKE 'unblock.project.%.mode'"))
appr = dict(db.execute("SELECT key, value FROM settings WHERE key LIKE 'unblock.standing_approval.%'"))
actors = {a for (a,) in db.execute("SELECT actor FROM settings WHERE key LIKE 'unblock.%'")}
want = ["project-1","project-2","project-3","project-4","project-5","project-6",
        "project-8","project-9","project-7","harness-console","cromford","project-6-os"]
a = "n=%d off=%d all=%s bh=%s appr=%s actors=%s" % (
    len(modes), sum(1 for v in modes.values() if v == "off"),
    all(modes.get("unblock.project.%s.mode" % p) == "off" for p in want),
    "unblock.project.cromford.mode" in modes,
    ",".join("%s=%s" % kv for kv in sorted(appr.items())),
    ",".join(sorted(actors)))
db.execute("UPDATE settings SET value='shadow' WHERE key='unblock.project.project-6-os.mode'")
db.executescript(open(sys.argv[2]).read())
b = db.execute("SELECT value FROM settings WHERE key='unblock.project.project-6-os.mode'").fetchone()[0]
rows = db.execute("SELECT key, value, actor FROM settings").fetchall()
cache = {"fetched_at": int(sys.argv[4]),
         "values": {k: v for k, v, act in rows if act != "registry-seed"},
         "seeded": {k: v for k, v, act in rows if act == "registry-seed"}}
json.dump(cache, open(sys.argv[3], "w"))
print(a + " | reapply=" + b)
PY
)
  # TEST-CHANGE (BH-7722): UNB-0's fragment is in the composed schema now and
  # seeds cromford (mode shadow, standing approval 1), as this fragment's
  # header says it will. So the composed schema holds 13 mode rows; this
  # fragment still holds no cromford row (the grep below pins that).
  check "S0 12 off rows plus UNB-0's cromford shadow row, project-6-os and cromford approved, actor seed; shadow survives a re-apply ($GOT)" \
    '[ "$GOT" = "n=13 off=12 all=True bh=True appr=unblock.standing_approval.cromford=1,unblock.standing_approval.project-6-os=1 actors=seed | reapply=shadow" ]'
  grep -qE "'unblock\.(project\.cromford\.mode|standing_approval\.cromford)'" "$SEED" \
    && bad "S0 this fragment seeds a cromford row (UNB-0 owns it)" || ok "S0 this fragment holds no cromford row"
  grep -qiE '^[[:space:]]*(drop|alter|delete|update|create)[[:space:]]' "$SEED" \
    && bad "S0 the fragment holds DDL or a destructive statement" || ok "S0 the fragment is INSERT OR IGNORE only"
  H0=$(mkh s0)
  cp "$T/s0-cache.json" "$H0/state/settings-cache.json"
  check "S0 round trip: project-6-os reads shadow" '[ "$(run "$H0" unb_scope_mode project-6-os)" = "shadow|rc=0" ]'
  check "S0 round trip: project-5 reads off" '[ "$(run "$H0" unb_scope_mode project-5)" = "off|rc=0" ]'
  check "S0 round trip: project-6-os is approved" '[ "$(run "$H0" unb_scope_approved project-6-os)" = "|rc=0" ]'
  check "S0 round trip: project-5 is not approved" '[ "$(run "$H0" unb_scope_approved project-5)" = "|rc=1" ]'
fi

# ══ S1: the mode table ══════════════════════════════════════════════════════
echo "S1 mode"
H1=$(mkh s1)
cache "$H1" "$NOW" \
  unblock.project.p-act.mode=act unblock.project.p-upper.mode=ACT "unblock.project.p-space.mode= act " \
  unblock.project.p-shadow.mode=shadow unblock.project.p-off.mode=off unblock.project.p-empty.mode= \
  unblock.project.p-actt.mode=actt unblock.project.p-on.mode=on unblock.project.p-one.mode=1 \
  unblock.project.p-true.mode=true unblock.project.p-actmode.mode=act-mode unblock.project.project-6.mode=act \
  unblock.project.p-sh-upper.mode=Shadow "unblock.project.p-inner.mode=a ct" "unblock.project.p-nl.mode=$(printf 'act\nx')"
while read -r p want; do
  check "S1 $p -> $want" '[ "$(run "$H1" unb_scope_mode "$p")" = "$want|rc=0" ]'
done <<'EOF'
p-act act
p-upper off
p-sh-upper off
p-space act
p-inner act
p-shadow shadow
p-off off
p-missing off
p-empty off
p-actt off
p-on off
p-one off
p-true off
p-actmode off
p-nl off
project-6-os off
project-6 act
EOF
check "S1 an upper-case project name is refused, not lowercased (off, rc 2)" '[ "$(run "$H1" unb_scope_mode P-Act)" = "off|rc=2" ]'
check "S1 Cromford is refused (off, rc 2)" '[ "$(run "$H1" unb_scope_mode Cromford)" = "off|rc=2" ]'
check "S1 a name with a leading dash is refused (off, rc 2)" '[ "$(run "$H1" unb_scope_mode -act)" = "off|rc=2" ]'
check "S1 a bad project name prints off, rc 2" '[ "$(run "$H1" unb_scope_mode "../x")" = "off|rc=2" ]'
check "S1 an empty project prints off, rc 2" '[ "$(run "$H1" unb_scope_mode "")" = "off|rc=2" ]'

# ══ S2: the approval table ══════════════════════════════════════════════════
echo "S2 approval"
H2=$(mkh s2)
cache "$H2" "$NOW" \
  unblock.standing_approval.a-one=1 "unblock.standing_approval.a-space= 1 " unblock.standing_approval.a-zero=0 \
  unblock.standing_approval.a-true=true unblock.standing_approval.a-yes=yes unblock.standing_approval.a-empty= \
  unblock.standing_approval.other=1
while read -r p want; do
  check "S2 $p -> rc $want" '[ "$(run "$H2" unb_scope_approved "$p")" = "|rc=$want" ]'
done <<'EOF'
a-one 0
a-space 0
a-zero 1
a-true 1
a-yes 1
a-empty 1
a-missing 1
other-x 1
EOF
check "S2 an upper-case project name is rc 2, not lowercased" '[ "$(run "$H2" unb_scope_approved A-One)" = "|rc=2" ]'
check "S2 a bad project name is not approved (rc 2)" '[ "$(run "$H2" unb_scope_approved "a/b")" = "|rc=2" ]'

# ══ S3: the decide table (plan S5 case 1) ═══════════════════════════════════
echo "S3 decide"
H3=$(mkh s3)
cache "$H3" "$NOW" \
  unblock.project.sh.mode=shadow unblock.project.ac.mode=act \
  unblock.project.sh-ok.mode=shadow unblock.project.ac-ok.mode=act unblock.project.off.mode=off \
  unblock.standing_approval.sh-ok=1 unblock.standing_approval.ac-ok=1 unblock.standing_approval.none=1
while read -r p need want rc; do
  check "S3 $p needs_approval=$need -> $want rc $rc" '[ "$(run "$H3" unb_scope_decide "$p" "$need")" = "$want|rc=$rc" ]'
done <<'EOF'
none 0 skip 0
none 1 skip 0
off 1 skip 0
sh 0 would 0
ac 0 act 0
ac 1 escalate 0
sh 1 would-escalate 0
ac-ok 1 act 0
sh-ok 1 would 0
ac 2 skip 2
ac x skip 2
ac - skip 2
EOF
check "S3 a missing needs_approval -> skip rc 2" '[ "$(run "$H3" unb_scope_decide ac)" = "skip|rc=2" ]'
check "S3 a bad project -> skip rc 2" '[ "$(run "$H3" unb_scope_decide "a b" 0)" = "skip|rc=2" ]'

# ══ S4: separate per-project locks (plan S5 case 2) ═════════════════════════
echo "S4 lock"
H4=$(mkh s4)
B="$T/s4-barrier"; mkdir -p "$B"
# The holder takes alpha's lock, says so, and keeps it until the test releases
# it (5 s at most).
HARNESS="$H4" H="" bash -c '. "$HARNESS/bin/lib/unblock/scope.sh" || exit 9
  unb_scope_lock alpha; echo "$?" > "$1/held"
  i=0; until [ -e "$1/release" ] || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i+1)); done' _ "$B" &
HOLDER=$!
i=0; until [ -s "$B/held" ] || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i+1)); done
check "S4 the holder took alpha's lock" '[ "$(cat "$B/held" 2>/dev/null)" = 0 ]'
check "S4 beta's lock is free while alpha is held" '[ "$(run "$H4" unb_scope_lock beta)" = "|rc=0" ]'
check "S4 a second alpha run is busy (rc 1)" '[ "$(run "$H4" unb_scope_lock alpha)" = "|rc=1" ]'
check "S4 the busy attempt left alpha held" '! flock -n "$H4/locks/unblock-alpha.lock" true'
check "S4 the lock files are per project" '[ -e "$H4/locks/unblock-alpha.lock" ] && [ -e "$H4/locks/unblock-beta.lock" ]'
check "S4 a bad name is rc 2" '[ "$(run "$H4" unb_scope_lock "../x")" = "|rc=2" ]'
touch "$B/release"; wait "$HOLDER" 2>/dev/null
check "S4 alpha is free after its holder exits" '[ "$(run "$H4" unb_scope_lock alpha)" = "|rc=0" ]'

# ══ S5: the in-scope project list ═══════════════════════════════════════════
echo "S5 projects"
H5=$(mkh s5)
cache "$H5" "$NOW" unblock.project.alpha.mode=off unblock.project.beta.mode=shadow \
  unblock.project.delta.mode=act unblock.project.zeta.mode=act
GOT=$(run "$H5" unb_scope_projects)
WANT=$(printf 'beta\tshadow\ndelta\tact|rc=0')
check "S5 only shadow/act fleet projects, in fleet.conf order" '[ "$GOT" = "$WANT" ]'
H5b=$(mkh s5b)
cache "$H5b" "$NOW"
check "S5 no rows: an empty list, rc 0" '[ "$(run "$H5b" unb_scope_projects)" = "|rc=0" ]'

# ══ S6: fail closed ═════════════════════════════════════════════════════════
echo "S6 fail closed"
H6=$(mkh s6)
check "S6 no cache file: off" '[ "$(run "$H6" unb_scope_mode alpha)" = "off|rc=0" ]'
check "S6 no cache file: skip on decide" '[ "$(run "$H6" unb_scope_decide alpha 0)" = "skip|rc=0" ]'
check "S6 no cache file: no project in scope" '[ "$(run "$H6" unb_scope_projects)" = "|rc=0" ]'
check "S6 no cache file: nothing created under state/" '[ -z "$(ls -A "$H6/state")" ] || [ "$(ls -A "$H6/state")" = lane-gate ]'
EMPTY=$(cd "$T" && HARNESS="" H="" bash -c '. "$1" || exit 9
  printf "%s,%s" "$(unb_scope_mode alpha)" "$?"; unb_scope_approved alpha; printf ",%s" "$?"
  unb_scope_lock alpha; printf ",%s" "$?"; printf ",%s" "$(unb_scope_projects | wc -l)"' _ "$H6/bin/lib/unblock/scope.sh" 2>/dev/null)
check "S6 empty root: off rc 2, not approved, lock rc 2, no projects ($EMPTY)" '[ "$EMPTY" = "off,2,1,2,0" ]'
check "S6 empty root built no path from \"\" (no ./locks, no ./state)" '[ ! -e "$T/locks" ] && [ ! -e "$T/state" ] && [ ! -e /locks/unblock-alpha.lock ]'
H6s=$(mkh s6s)
cache "$H6s" $((NOW - 7200)) unblock.project.alpha.mode=act
check "S6 a stale cache keeps the last known row (act)" '[ "$(run "$H6s" unb_scope_mode alpha)" = "act|rc=0" ]'
# No lane-gate in the tree: the setting_get fallback answers, trimmed and lowered.
H6n=$(mkh s6n)
rm -f "$H6n/bin/lib/lane-gate.sh"
FB=$(HARNESS="$H6n" H="" bash -c 'setting_get() { case "$1" in unblock.project.alpha.mode) printf " shadow\n" ;; unblock.project.gamma.mode) printf Shadow ;; unblock.standing_approval.alpha) printf 1 ;; *) return 1 ;; esac; }
  . "$HARNESS/bin/lib/unblock/scope.sh" || exit 9
  printf "%s,%s,%s" "$(unb_scope_mode alpha)" "$(unb_scope_mode beta)" "$(unb_scope_mode gamma)"; unb_scope_approved alpha; printf ",%s" "$?"' 2>/dev/null)
check "S6 no lane-gate: setting_get answers, same grammar ($FB)" '[ "$FB" = "shadow,off,off,0" ]'
FB2=$(HARNESS="$H6n" H="" bash -c '. "$HARNESS/bin/lib/unblock/scope.sh" || exit 9; unb_scope_mode alpha' 2>/dev/null)
check "S6 no lane-gate and no setting_get: off" '[ "$FB2" = off ]'
OPTS=$(HARNESS="$H6s" H="" bash -c 'set +o pipefail; set +u; . "$HARNESS/bin/lib/unblock/scope.sh"; unb_scope_mode alpha >/dev/null; set -o | awk '"'"'$1=="pipefail"||$1=="nounset"{print $1"="$2}'"'"' | tr "\n" " "' 2>/dev/null)
check "S6 the caller's shell options are kept ($OPTS)" '[ "$OPTS" = "nounset=off pipefail=off " ]'

# ══ S7: agreement with the writer (act.sh _ub_mode) ═════════════════════════
# act.sh re-reads the row live before any write (gate 3). If scope.sh put a
# project in scope that act.sh refuses, or the reverse, the lane would plan
# work it cannot do. For each row value, both readers must give one mode.
echo "S7 agreement with act.sh"
H7=$(mkh s7)
( cd "$REPO" && scratch_install_closure bin/lib/unblock/act.sh "$H7" ) >/dev/null 2>&1 \
  || bad "S7 setup: could not install act.sh's closure"
# The jobs-client stub answers setting-get from a file, rc 2 when there is no
# row (as tests/unblock-act.bh-7726-test.sh does). It never reaches a worker.
cat > "$H7/bin/jobs-client.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = setting-get ] || exit 2
f="$HARNESS/stub/setting/$2"
[ -f "$f" ] || exit 2
cat "$f"; echo
EOF
chmod +x "$H7/bin/jobs-client.sh"
mkdir -p "$H7/stub/setting"
i=0
# One row value per line; `\n` is a newline, <missing> is no row at all.
while IFS= read -r v; do
  i=$((i+1)); p="s7-$i"
  v=${v//\\n/$'\n'}
  if [ "$v" = "<missing>" ]; then
    cache "$H7" "$NOW"
  else
    printf '%s' "$v" > "$H7/stub/setting/unblock.project.$p.mode"
    cache "$H7" "$NOW" "unblock.project.$p.mode=$v"
  fi
  W=$(HARNESS="$H7" H="" _UB_P="$p" bash -c '. "$HARNESS/bin/lib/unblock/act.sh" || exit 9; _ub_mode' 2>/dev/null)
  [ "$W" = no-opt-in ] && W=off
  S=$(run "$H7" unb_scope_mode "$p")
  check "S7 row '${v//$'\n'/\\n}': act.sh=$W scope.sh=${S%|rc=*}" '[ -n "$W" ] && [ "$S" = "$W|rc=0" ]'
done <<'EOF'
act
 act 
act\n
shadow
 shadow\n
off
<missing>

ACT
Shadow
actt
on
1
true
act-mode
a ct
EOF

if [ -s "$T/setup-failed" ]; then
  while IFS= read -r l; do bad "$l"; done < "$T/setup-failed"
fi
echo
echo "unblock-scope: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
