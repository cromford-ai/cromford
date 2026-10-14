#!/bin/bash
# tests/schema-untracked.bh-6005-4-test.sh — worker/jobs/schema.sql leaves git
# (BH-6005.4, ticket #6011).
#
# WHY. schema.sql was the render of worker/jobs/schema.d/ AND a committed file,
# so two branches that each added one fragment both re-rendered it and conflicted
# on it: on 2026-10-11 that parked 8 approved PRs for up to 1,300 minutes. The
# render is now git-ignored and composed where it is read (the deploy, CI, the
# test corpus), and bin/schema-build.sh --check refuses it coming back.
#
#   B1-B9 bin/schema-build.sh in a scratch repo that ignores the render:
#     B1 untracked-ignored, no file: --check rc 0, empty stdout
#     B2 the render force-added back into git: --check rc 1, "must not be in git"
#        and "add or edit a fragment"
#     B3 a stale local render: --check rc 0, one "stale local render" note
#     B4 a stray 9999-x.sql.bak in schema.d/: --check rc 1, naming the file
#     B6 --write over a stale earlier render: rc 0, the file equals the print
#     B7 --write during a merge whose MERGE_HEAD appended a table to schema.sql:
#        rc 1, naming the table (the branch-history scan still runs)
#     B8 --write in a TRACKED fixture with a hand edit: rc 1 (unchanged)
#     B9 --check in a non-git tree with no file: rc 1 (unchanged)
#   U1 two branches that each add one fragment merge with no CONFLICT; the
#      control (the render tracked and re-rendered on each branch) conflicts
#   U2 the real repo: worker/jobs/schema.sql is not in git and is ignored
#      (TEST-CHANGE BH-5239.4: the Cloud worker's schema was deleted, so the
#      check that it stays in git went with it; no-cloud-in-engine.bh-5239 NC-1
#      pins that nothing is tracked under the Cloud dir)
#   U3 the real repo: --check rc 0 with the file absent and with it present
#   U4 a scratch copy with no schema.sql: three schema node tests pass and leave
#      no schema.sql behind (the corpus composes for itself, BH-6005.1)
#   U5 the additive gate reads the fragments: a DROP in a fragment is red
#   U6 the regenerated-paths row for schema.sql is gone: mc_regen_cmd_for_path
#      answers rc 1 for it, with the real conf and with no conf
#   U7 Archie's union allowlist matches worker/jobs/schema.sql by pattern even
#      when the file is not on disk (it expanded the globs against the cwd)
#   U8 --check with --root given as a relative path, through a symlink, or with
#      a trailing slash still sees the ignored render as untracked (rc 0 with
#      no render; tracked_state compares physical paths)
#   U9 the queue_risk.globs.schema seed matches schema.d/ fragments: a fresh DB
#      gets the new globs, the untouched BH-5430 seed row moves to them, an
#      operator's row is kept, and a second apply changes nothing
# Run from anywhere: tests/schema-untracked.bh-6005-4-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"

# run <root> <args...> — the script installed under <root>; stdout, stderr, rc kept.
run() {
  local root="$1"; shift
  ( cd "$root" && bin/schema-build.sh "$@" ) >"$T/out" 2>"$T/err"; RC=$?
}
# repo <tag> [tracked] — a scratch git repo with the script's closure and one
# base fragment. Default: the render is ignored and not in git. `tracked`:
# the old shape, the render committed.
repo() {
  W="$T/$1"; mkdir -p "$W/worker/jobs/schema.d"
  scratch_install_closure bin/schema-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
  printf '%s\n' 'CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);' > "$W/worker/jobs/schema.d/0000-base.sql"
  git -C "$W" init -q -b main
  if [ "${2:-}" = tracked ]; then
    run "$W" --write; git -C "$W" add -A
  else
    printf 'worker/jobs/schema.sql\n' > "$W/.gitignore"; git -C "$W" add -A
  fi
  git -C "$W" commit -qm base
  git -C "$W" update-ref refs/remotes/origin/main HEAD
}

# ── B1 untracked-ignored, no file ─────────────────────────────────────────────
repo b1
run "$W" --check
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "B1 --check with the render ignored and absent must be rc 0 and quiet (rc=$RC: $(cat "$T/err"))"

# ── B2 the render back in git ─────────────────────────────────────────────────
run "$W" --write
git -C "$W" add -f worker/jobs/schema.sql
run "$W" --check
[ "$RC" = 1 ] && grep -q 'must not be in git' "$T/err" && grep -q 'add or edit a fragment' "$T/err" && ok \
  || bad "B2 a force-added render must be refused (rc=$RC: $(cat "$T/err"))"
git -C "$W" rm -q --cached worker/jobs/schema.sql

# ── B3 a stale local render ───────────────────────────────────────────────────
printf '%s\n' 'CREATE TABLE z (id INTEGER PRIMARY KEY);' > "$W/worker/jobs/schema.d/0100-z.sql"
run "$W" --check
[ "$RC" = 0 ] && [ "$(grep -c 'stale local render' "$T/err")" = 1 ] && ok \
  || bad "B3 a stale local render is a note, rc 0 (rc=$RC: $(cat "$T/err"))"

# ── B4 a stray file in schema.d/ ──────────────────────────────────────────────
: > "$W/worker/jobs/schema.d/9999-x.sql.bak"
run "$W" --check
[ "$RC" = 1 ] && grep -q '9999-x.sql.bak' "$T/err" && ok || bad "B4 a stray file must be red and named (rc=$RC: $(cat "$T/err"))"
rm -f "$W/worker/jobs/schema.d/9999-x.sql.bak"

# ── B6 --write over a stale earlier render ────────────────────────────────────
repo b6
run "$W" --write
printf '%s\n' 'CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT, extra TEXT);' > "$W/worker/jobs/schema.d/0000-base.sql"
printf '%s\n' '-- stale' 'CREATE TABLE gone_local (id INTEGER);' >> "$W/worker/jobs/schema.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "B6 --write over a stale local render must succeed (rc=$RC: $(cat "$T/err"))"
( cd "$W" && bin/schema-build.sh --worker jobs ) > "$T/print" 2>/dev/null
cmp -s "$T/print" "$W/worker/jobs/schema.sql" && ok || bad "B6 the written file must equal the print"

# ── B7 --write during a merge that brings a table only in schema.sql ──────────
repo b7
git -C "$W" checkout -q -b side
run "$W" --write
git -C "$W" add -f worker/jobs/schema.sql
printf '%s\n' 'CREATE TABLE IF NOT EXISTS prebranch_fixture (id INTEGER);' >> "$W/worker/jobs/schema.sql"
git -C "$W" add -f worker/jobs/schema.sql; git -C "$W" commit -qm 'pre-split table'
git -C "$W" checkout -q main
printf '%s\n' 'CREATE TABLE m (id INTEGER);' > "$W/worker/jobs/schema.d/0200-m.sql"
git -C "$W" add -A; git -C "$W" commit -qm m
git -C "$W" merge -q --no-commit --no-ff side >/dev/null 2>&1 || true
run "$W" --write
[ "$RC" = 1 ] && grep -q 'prebranch_fixture' "$T/err" && ok \
  || bad "B7 --write must refuse a table MERGE_HEAD put only in schema.sql (rc=$RC: $(cat "$T/err"))"
git -C "$W" merge --abort >/dev/null 2>&1

# ── B8 tracked fixture, hand edit (unchanged) ─────────────────────────────────
repo b8 tracked
printf '%s\n' 'CREATE TABLE hand (id INTEGER);' >> "$W/worker/jobs/schema.sql"
run "$W" --write
[ "$RC" = 1 ] && grep -q 'hand' "$T/err" && ok || bad "B8 a tracked render with a hand edit must still be refused by --write (rc=$RC)"

# ── B9 non-git tree, no file (unchanged) ──────────────────────────────────────
W="$T/b9"; mkdir -p "$W/worker/jobs/schema.d"
scratch_install_closure bin/schema-build.sh "$W" >/dev/null
printf '%s\n' 'CREATE TABLE a (id INTEGER);' > "$W/worker/jobs/schema.d/0000-base.sql"
run "$W" --check
[ "$RC" = 1 ] && ok || bad "B9 --check outside git with no render must stay rc 1 (rc=$RC)"

# ── U1 two fragment branches merge cleanly; the tracked control conflicts ────
u1() { # u1 <tag> [tracked] — prints the merge-tree rc and output
  repo "$1" "${2:-}"
  local b
  for b in alpha beta; do
    git -C "$W" checkout -q -b "$b" main
    printf 'CREATE TABLE %s (id INTEGER);\n' "$b" > "$W/worker/jobs/schema.d/0100-$b.sql"
    [ "${2:-}" = tracked ] && run "$W" --write
    git -C "$W" add -A; git -C "$W" commit -qm "$b"
  done
  git -C "$W" merge-tree --write-tree alpha beta > "$T/mt" 2>&1; MT=$?
}
u1 u1
[ "$MT" = 0 ] && ! grep -q CONFLICT "$T/mt" && ok || bad "U1 two fragment branches must merge with no conflict (rc=$MT: $(cat "$T/mt"))"
u1 u1c tracked
[ "$MT" = 1 ] && grep -q 'CONFLICT (content).*worker/jobs/schema.sql' "$T/mt" && ok \
  || bad "U1 control: with the render tracked the same branches conflict on schema.sql (rc=$MT: $(cat "$T/mt"))"

# ── U2 the real repo ──────────────────────────────────────────────────────────
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DIR" ls-files --error-unmatch worker/jobs/schema.sql >/dev/null 2>&1 \
    && bad "U2 worker/jobs/schema.sql must not be in git" || ok
  git -C "$DIR" check-ignore -q --no-index worker/jobs/schema.sql && ok || bad "U2 worker/jobs/schema.sql must be ignored"
fi

# ── U3 --check on the real repo, file absent and present ──────────────────────
U3="$T/u3"; mkdir -p "$U3"
git -C "$DIR" archive HEAD bin worker/jobs/schema.d .gitignore | tar -x -C "$U3"
git -C "$U3" init -q -b main && git -C "$U3" add -A && git -C "$U3" commit -qm snap
run "$U3" --check --worker jobs
[ "$RC" = 0 ] && ok || bad "U3 --check with no render must be rc 0 (rc=$RC: $(cat "$T/err"))"
run "$U3" --write --worker jobs
run "$U3" --check --worker jobs
[ "$RC" = 0 ] && ok || bad "U3 --check with a fresh render present must be rc 0 (rc=$RC: $(cat "$T/err"))"

# ── U4 the node schema tests compose for themselves ───────────────────────────
if command -v node >/dev/null 2>&1 && [ -d "$DIR/worker/jobs/node_modules" ]; then
  U4="$T/u4"; mkdir -p "$U4"
  # worker/jobs/src imports ../../agent-core (the shared runtime).
  git -C "$DIR" archive HEAD worker/jobs bin catalog agent-core | tar -x -C "$U4"
  rm -f "$U4/worker/jobs/schema.sql"
  ln -s "$DIR/worker/jobs/node_modules" "$U4/worker/jobs/node_modules"
  "$U4/bin/lanes-build.sh" --root "$U4" --write >/dev/null 2>&1
  # The worker also imports catalog/llm-sites.json, composed and git-ignored
  # since BH-4987 (#6264), so the archive does not carry it.
  "$U4/bin/llm-sites-build.sh" --compose --repo "$U4" >/dev/null 2>&1
  ( cd "$U4/worker/jobs" && node --test test/settings-schema.test.js test/alerts-schema.bh-1068.test.js test/cost-caps-schema-seed.bh-4155.test.js ) >"$T/u4.out" 2>&1; R4=$?
  [ "$R4" = 0 ] && ok || bad "U4 the schema node tests must pass with no schema.sql (rc=$R4: $(tail -5 "$T/u4.out"))"
  [ ! -e "$U4/worker/jobs/schema.sql" ] && ok || bad "U4 the node tests must not leave a schema.sql behind"
else
  echo "NOTE: U4 skipped — node or worker/jobs/node_modules missing (npm ci in worker/jobs first)"
fi

# ── U5 the additive gate reads the fragments ──────────────────────────────────
U5="$T/u5"; mkdir -p "$U5/worker/jobs/schema.d" "$U5/tests/lib"
scratch_install_closure bin/schema-build.sh "$U5" >/dev/null
cp "$DIR/tests/schema-additive.bh-1000-test.sh" "$U5/tests/"
cp "$DIR"/tests/lib/*.sh "$U5/tests/lib/"
printf '%s\n' 'CREATE TABLE IF NOT EXISTS fixture_t (id INTEGER);' > "$U5/worker/jobs/schema.d/0000-base.sql"
printf '%s\n' 'DROP TABLE fixture_t;' > "$U5/worker/jobs/schema.d/9999-bad.sql"
( cd "$U5" && bash tests/schema-additive.bh-1000-test.sh ) >"$T/u5.out" 2>&1; R5=$?
[ "$R5" != 0 ] && grep -q 'NOT ADDITIVE' "$T/u5.out" && ok || bad "U5 a DROP in a fragment must be red with NOT ADDITIVE (rc=$R5: $(tail -3 "$T/u5.out"))"
rm -f "$U5/worker/jobs/schema.d/9999-bad.sql"
( cd "$U5" && bash tests/schema-additive.bh-1000-test.sh ) >"$T/u5.out" 2>&1; R5=$?
[ "$R5" = 0 ] && ok || bad "U5 without the DROP the additive gate must pass (rc=$R5: $(tail -3 "$T/u5.out"))"

# ── U6 no regenerated-paths row for schema.sql ────────────────────────────────
U6=$( ( MC_H="$DIR"; MC_REGENERATED_PATHS_CONF="$DIR/config/regenerated-paths.conf"
        eval "$(awk '/^mc_regen_paths\(\) \{/,/^}/; /^mc_regen_cmd_for_path\(\) \{/,/^}/' "$DIR/bin/lib/mc/rebase.sh")"
        eval "$(grep '^MC_REGENERATED_PATHS_DEFAULT=' "$DIR/bin/lib/mc/rebase.sh")"
        mc_regen_cmd_for_path worker/jobs/schema.sql >/dev/null 2>&1; echo "real=$?"
        MC_REGENERATED_PATHS_CONF=/nonexistent mc_regen_cmd_for_path worker/jobs/schema.sql >/dev/null 2>&1; echo "none=$?" ) 2>/dev/null | tr '\n' ' ')
[ "$U6" = "real=1 none=1 " ] && ok || bad "U6 schema.sql must have no regenerated-paths row (got: $U6)"

# ── U7 the archie union allowlist matches by pattern, not by what is on disk ─
# afm_rr_union_match looped over an unquoted glob list, so `worker/*/schema.sql`
# expanded against the current directory: with worker/jobs/schema.sql gone from
# the tree (only another worker's schema.sql left), it stopped matching the jobs
# path and Archie's union playbook refused the conflict it exists for.
U7="$T/u7"; mkdir -p "$U7/worker/other"; : > "$U7/worker/other/schema.sql"
R7=$( cd "$U7" && eval "$(awk '/^afm_rr_union_match\(\) \{/,/^}/' "$DIR/bin/lib/archie-fm-repair.sh")" \
        && AFM_RR_GLOBS='worker/*/src/index.js,worker/*/schema.sql,catalog/*.json,*.d/*' \
        && afm_rr_union_match worker/jobs/schema.sql; echo $? )
[ "$R7" = 0 ] && ok || bad "U7 worker/jobs/schema.sql must match worker/*/schema.sql with no such file on disk (rc=$R7)"

# ── U8 tracked_state compares physical paths ─────────────────────────────────
repo u8
ln -s "$W" "$T/u8-link"
for r in . "$T/u8-link" "$W/"; do
  run "$W" --check --root "$r"
  [ "$RC" = 0 ] && ok || bad "U8 --check --root '$r' on an untracked tree with no render must be rc 0 (rc=$RC: $(cat "$T/err"))"
done

# ── U9 the queue-risk schema globs seed (lead review lr-6409) ─────────────────
if command -v node >/dev/null 2>&1 && node -e 'require("node:sqlite")' 2>/dev/null; then
  U9="$T/u9"; mkdir -p "$U9"
  ( cd "$DIR" && bin/schema-build.sh --worker jobs --to "$U9/schema.sql" ) >/dev/null 2>&1 || bad "U9 could not compose the schema"
  OLDG='worker/jobs/schema.sql *migrations/* worker/jobs/src/lib/core.js'
  NEWG='worker/jobs/schema.sql worker/*/schema.d/* *migrations/* worker/jobs/src/lib/core.js'
  # u9 <db> <pre-sql> — apply the composed schema to <db> after <pre-sql>; print the row.
  u9() {
    node --no-warnings -e '
      const { DatabaseSync } = require("node:sqlite"); const fs = require("node:fs");
      const [db, schema, pre] = process.argv.slice(1); const d = new DatabaseSync(db);
      if (pre) d.exec(pre);
      d.exec(fs.readFileSync(schema, "utf8"));
      const r = d.prepare("SELECT actor, value FROM settings WHERE key = ?").get("queue_risk.globs.schema");
      process.stdout.write(r.actor + "|" + r.value);' "$1" "$U9/schema.sql" "${2:-}" 2>&1
  }
  G=$(u9 "$U9/fresh.db")
  [ "$G" = "seed|$NEWG" ] && ok || bad "U9 a fresh DB must get the schema.d glob: '$G'"
  G=$(u9 "$U9/fresh.db")
  [ "$G" = "seed|$NEWG" ] && ok || bad "U9 a second apply must change nothing: '$G'"
  MK="CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT);"
  G=$(u9 "$U9/old.db" "$MK INSERT INTO settings VALUES ('queue_risk.globs.schema','$OLDG','BH-5430','seed','2026-10-08T00:00:00Z');")
  [ "$G" = "seed|$NEWG" ] && ok || bad "U9 the untouched BH-5430 seed row must move to the schema.d glob: '$G'"
  G=$(u9 "$U9/op.db" "$MK INSERT INTO settings VALUES ('queue_risk.globs.schema','$OLDG','mine','operator','2026-10-09T00:00:00Z');")
  [ "$G" = "operator|$OLDG" ] && ok || bad "U9 an operator's row must be kept: '$G'"
else
  echo "NOTE: U9 skipped — node:sqlite missing"
fi

echo "schema-untracked.bh-6005-4-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
