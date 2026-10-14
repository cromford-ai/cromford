#!/bin/bash
# tests/box-ops-fly.bh-2518-test.sh — BH-2518 (BH-2658 contract): the Fly
# machine-ops seam bin/lib/box-ops-fly.sh and the box_commands schema block.
#
# The lib is sourced with a fake `fly` first on PATH that touches a marker, so
# "makes no fly call" is observed, not read from the source. The schema case
# applies the BH-2518 block of worker/jobs/schema.sql twice to one in-memory DB
# through node:sqlite (sqlite3 is not on every box) and checks the CHECKs and the
# open-command unique index refuse what they should. The real stop/destroy
# cases (BH-2661) live in tests/box-ops-fly.bh-2661-test.sh.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/box-ops-fly.bh-2518-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/box-ops-fly.sh"
SCHEMA="$DIR/worker/jobs/schema.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin"
cat > "$T/fakebin/fly" <<EOF
#!/bin/bash
touch "$T/fly-called"
exit 0
EOF
chmod +x "$T/fakebin/fly"

[ -f "$LIB" ] && ok || bad "S0: $LIB missing"

# --- S1. sourcing prints nothing and leaves the caller's options alone -------
OUT=$( ( set -u; before=$-; . "$LIB"; echo "opts=$before/$-" ) 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1: source rc=$RC"
case "$OUT" in
  opts=*) b=${OUT#opts=}; [ "${b%%/*}" = "${b#*/}" ] && ok || bad "S1: options changed '$OUT'" ;;
  *) bad "S1: sourcing printed '$OUT'" ;;
esac

# --- S2. a project no fleet owns is refused: rc != 0, one refused: line, no fly
# call. HARNESS is an empty scratch dir so no live fleet-conf.sh is consulted.
for fn in box_ops_fly_stop box_ops_fly_destroy; do
  rm -f "$T/fly-called"
  OUT=$( ( set -u; export HARNESS="$T/noharness" PATH="$T/fakebin:$PATH"; . "$LIB"; "$fn" abc12345 proj app ) 2>/dev/null ); RC=$?
  [ "$RC" -ne 0 ] && ok || bad "S2: $fn rc=$RC"
  case "$OUT" in "refused: "*) [ "$OUT" = "${OUT%%$'\n'*}" ] && ok || bad "S2: $fn printed more than one line '$OUT'" ;; *) bad "S2: $fn stdout '$OUT'" ;; esac
  [ ! -e "$T/fly-called" ] && ok || bad "S2: $fn called fly"
  # no args under set -u must still refuse cleanly, not die on an unset var
  OUT=$( ( set -u; export HARNESS="$T/noharness" PATH="$T/fakebin:$PATH"; . "$LIB"; "$fn"; echo "alive rc=$?" ) 2>/dev/null )
  case "$OUT" in "refused: "*$'\n'"alive rc=1") ok ;; *) bad "S2: $fn with no args got '$OUT'" ;; esac
done

# --- S3. the schema block: additive, idempotent, and its guards refuse -------
BLOCK=$(awk '/^-- ── BH-2518: box_commands/{on=1} on&&/^-- ── /&&!/BH-2518/{exit} on' "$SCHEMA")
[ -n "$BLOCK" ] && ok || bad "S3: no BH-2518 box_commands block in schema.sql"
grep -Eqi '^[[:space:]]*(DROP|ALTER|INSERT|UPDATE|DELETE)' <<<"$BLOCK" && bad "S3: non-additive statement in the block" || ok
grep -q 'D1 has no RLS' <<<"$BLOCK" && ok || bad "S3: no RLS note"
if command -v node >/dev/null 2>&1; then
  printf '%s\n' "$BLOCK" > "$T/block.sql"
  cat > "$T/smoke.mjs" <<'EOF'
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
const sql = readFileSync(process.argv[2], 'utf8');
const db = new DatabaseSync(':memory:');
db.exec(sql); db.exec(sql);
const out = [];
const idx = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='box_commands' ORDER BY name").all().map((r) => r.name);
out.push('indexes=' + idx.join(','));
const ins = db.prepare("INSERT INTO box_commands (box,type,target,args,reason,status,requested_by,requested_at) VALUES (?,?,?,?,?,?,?,?)");
const tryIns = (label, ...a) => { try { ins.run(...a); out.push(label + '=ok'); } catch (e) { out.push(label + '=refused'); } };
tryIns('first', 'hub', 'fly_machine_stop', 'm1', '{}', 'stray', 'requested', 'console', 't0');
tryIns('second_open', 'hub', 'fly_machine_stop', 'm1', '{}', 'again', 'claimed', 'console', 't1');
db.exec("UPDATE box_commands SET status='ok' WHERE target='m1'");
tryIns('after_ok', 'hub', 'fly_machine_stop', 'm1', '{}', 'again', 'requested', 'console', 't2');
tryIns('other_target', 'hub', 'fly_machine_stop', 'm2', '{}', 'stray', 'requested', 'console', 't3');
tryIns('blank_reason', 'hub', 'backup_now', '', null, '   ', 'requested', 'console', 't4');
tryIns('bad_status', 'hub', 'backup_now', '', null, 'x', 'done', 'console', 't5');
tryIns('bad_type', 'hub', 'reboot', '', null, 'x', 'requested', 'console', 't6');
console.log(out.join(' '));
EOF
  OUT=$(node --no-warnings "$T/smoke.mjs" "$T/block.sql" 2>&1); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "S3: smoke rc=$RC out='$OUT'"
  [ "$OUT" = "indexes=box_commands_box_status,box_commands_open first=ok second_open=refused after_ok=ok other_target=ok blank_reason=refused bad_status=refused bad_type=refused" ] \
    && ok || bad "S3: smoke got '$OUT'"
else
  echo "NOTE: node not on PATH, schema smoke case skipped"
fi

echo "box-ops-fly: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
