#!/bin/bash
# tests/schema-stamp-order.bh-7229-test.sh — BH-7229: schema-fragment-name
# judges dependency, not stamp age. A new stamp fragment is a finding only when
# it uses a table or view that a fragment sorting AFTER it creates (the composed
# schema.sql would run the use before the CREATE). A stamp that only went stale
# because main moved is clean. The CI step prints the finding line.
#
#   S1  stale stamp + INSERT INTO a later base table: rc 1, the base form
#   S2  stale stamp, uses only an earlier table: rc 0, no output
#   S3  two new fragments, the earlier one indexes a table the later creates:
#       rc 1, the in-this-diff form
#   S4  a later table named only in a `--` comment, and a column named like a
#       later table: rc 0
#   S5  upper-case quoted use of a later table: rc 1
#   S6  a self-created table a later fragment also creates; a later fragment of
#       another worker: rc 0
#   S7  sr_stamp_split: base form -> note, diff form -> real; the real
#       bin/prepush-gate.sh prints `git mv` on the base form only, and
#       --restamp then makes the rule rc 0
#   S8  the harness-ci.yml `fast always-lints` step, run with a stub rules
#       pack: `::error title=rules-pack::<finding>`, rc 1; no finding, no ::error
#   S9  two queued PRs with stale stamps: sr_apply at minute M, then M+1 after
#       PR1 merged; both renamed, PR2 after PR1, restamp_same carries each, the
#       batch is rc 0
#   S10 the same batch with no rename: rc 0
#   S11 a bad base: rc 125; an unreadable later fragment: rc 0
#   S12 a PR branch behind main: the later fragment is only at the base (not
#       on disk), and the use is still the base form
# Real git, fixture repos only. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/schema-stamp-order.bh-7229-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# shellcheck source=../bin/lib/rules-pack-checks.sh
. "$DIR/bin/lib/rules-pack-checks.sh" || { echo "FAIL: cannot source bin/lib/rules-pack-checks.sh"; exit 1; }
# shellcheck source=../bin/lib/schema-restamp.sh
. "$DIR/bin/lib/schema-restamp.sh" || { echo "FAIL: cannot source bin/lib/schema-restamp.sh"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
SD=worker/jobs/schema.d
BASEFORM='at the base creates and which sorts after this fragment'
DIFFFORM='in this diff creates and which sorts after this fragment'

g() { git -C "$R" "$@"; }
# fixture <tag> — main: 0000-base (table base) and 202610170154-bh-1-top
#   (table top_t); BASE is that commit, the tree is checked out on it.
fixture() {
  R="$T/$1"; scratch_rm "$R" 2>/dev/null; mkdir -p "$R/$SD" "$R/worker/other/schema.d"
  printf 'CREATE TABLE base (id INTEGER);\n' > "$R/$SD/0000-base.sql"
  printf 'CREATE TABLE IF NOT EXISTS top_t (id INTEGER);\n' > "$R/$SD/202610170154-bh-1-top.sql"
  g init -q -b main; g add -A; g commit -qm base; BASE=$(g rev-parse HEAD)
}
put() { printf '%s\n' "$2" > "$R/$1"; }
lint() { OUT=$(rp_schema_fragment_name "$R" "$BASE" 2>"$T/err"); RC=$?; }

# ── S1 a real inversion against a base fragment ──
fixture s1; put "$SD/202610160900-bh-2-a.sql" 'CREATE TABLE a2 (id INTEGER);
INSERT INTO top_t (id) VALUES (1);'
g add -A; lint
[ "$RC" = 1 ] && [ "$(grep -c . <<<"$OUT")" = 1 ] && grep -qF "$BASEFORM" <<<"$OUT" && grep -qF 'take a stamp later than 202610170154' <<<"$OUT" \
  && [ "$OUT" = "$SD/202610160900-bh-2-a.sql: schema-fragment-name: uses table top_t, which $SD/202610170154-bh-1-top.sql $BASEFORM; take a stamp later than 202610170154 (bin/prepush-gate.sh --restamp)" ] \
  && ok || bad "S1 rc $RC out [$OUT]"
S1LINE=$OUT

# ── S2 stale only: clean ──
fixture s2; put "$SD/202610160900-bh-2-a.sql" 'CREATE TABLE a2 (id INTEGER);
INSERT INTO base (id) VALUES (1);
CREATE INDEX IF NOT EXISTS a2_ix ON a2(id);'
g add -A; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S2 a stale stamp with no later use must be clean: rc $RC out [$OUT]"

# ── S3 an inversion inside this diff ──
fixture s3; put "$SD/202610170200-bh-3-ix.sql" 'CREATE INDEX IF NOT EXISTS u_ix ON u(id);'
put "$SD/202610170201-bh-3-u.sql" 'CREATE TABLE u (id INTEGER);'
lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/202610170200-bh-3-ix.sql: schema-fragment-name: uses table u, which $SD/202610170201-bh-3-u.sql $DIFFFORM; give $SD/202610170201-bh-3-u.sql an earlier stamp than this fragment" ] \
  && ok || bad "S3 rc $RC out [$OUT]"
S3LINE=$OUT

# ── S4 a comment and a column are not uses ──
fixture s4; put "$SD/202610160900-bh-2-a.sql" '-- reads FROM top_t later, and INSERT INTO top_t
CREATE TABLE x (top_t INTEGER);
SELECT top_t FROM x;'
g add -A; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S4 a comment or a column name must be clean: rc $RC out [$OUT]"

# ── S5 upper case, quoted ──
fixture s5; put "$SD/202610160900-bh-2-a.sql" 'INSERT INTO "TOP_T" VALUES (1);'
lint
[ "$RC" = 1 ] && grep -qF "uses table top_t, which $SD/202610170154-bh-1-top.sql $BASEFORM" <<<"$OUT" && ok || bad "S5 rc $RC out [$OUT]"
fixture s5b; put "$SD/202610160900-bh-2-a.sql" 'select * from [top_t] join `base` on 1;'
lint
[ "$RC" = 1 ] && grep -qF 'uses table top_t' <<<"$OUT" && ok || bad "S5 bracket quote: rc $RC out [$OUT]"

# ── S6 self-created, and another worker ──
fixture s6; put "$SD/202610160900-bh-2-a.sql" 'CREATE TABLE IF NOT EXISTS top_t (id INTEGER);
INSERT INTO top_t VALUES (1);'
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S6 a self-created table must be clean: rc $RC out [$OUT]"
fixture s6b; put worker/other/schema.d/202610170300-bh-4-o.sql 'CREATE TABLE o (id INTEGER);'
g add -A; g commit -qm other; BASE=$(g rev-parse HEAD)
put "$SD/202610160900-bh-2-a.sql" 'INSERT INTO o VALUES (1);'
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S6 another worker's later fragment must not count: rc $RC out [$OUT]"

# ── S7 the readers: the lead-review split and the prepush gate ──
printf 'schema-fragment-name: %s\nschema-fragment-name: %s\n' "$S1LINE" "$S3LINE" > "$T/split.in"
sr_stamp_split "$T/split.in" "$T/real" "$T/note"
[ "$(cat "$T/note")" = "schema-fragment-name: $S1LINE" ] && [ "$(cat "$T/real")" = "schema-fragment-name: $S3LINE" ] && [ -n "$S1LINE" ] && [ -n "$S3LINE" ] \
  && ok || bad "S7 split note=[$(cat "$T/note")] real=[$(cat "$T/real")]"
TBL="$T/table.tsv"
printf 'rules-pack\tbash %s/bin/rules-pack.sh --runner local --tree . --base <base> --only schema-fragment-name --out <out>/rules-pack.d\n' "$DIR" > "$TBL"
NOW_E=$(date -u -d '2026-10-17 05:00' +%s)
mkdir -p "$T/nolg"
gate() { # gate <out> — the real gate on $R with the seam table
  ( cd "$R" && HARNESS="$T/nolg" PREPUSH_GATE_TABLE="$TBL" SR_NOW_EPOCH="$NOW_E" HARNESS_TEST_SANDBOX=1 \
      bash "$DIR/bin/prepush-gate.sh" --tree "$R" --base main --out "$T/$1" ) >"$T/gate.out" 2>&1; RC=$?; OUT=$(cat "$T/gate.out")
}
fixture s7; g checkout -qb pr; put "$SD/202610160900-bh-2-a.sql" 'INSERT INTO top_t VALUES (1);'; g add -A; g commit -qm pr
gate g7a
[ "$RC" = 1 ] && grep -qF "git mv $SD/202610160900-bh-2-a.sql $SD/202610170500-bh-2-a.sql" <<<"$OUT" && ok || bad "S7 the gate on the base form: rc $RC out [$OUT]"
( cd "$R" && SR_NOW_EPOCH="$NOW_E" bash "$DIR/bin/prepush-gate.sh" --tree "$R" --restamp --base main ) >"$T/rs.out" 2>&1; rsrc=$?
lint
[ "$rsrc" = 0 ] && [ -f "$R/$SD/202610170500-bh-2-a.sql" ] && [ "$RC" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "S7 --restamp rc $rsrc [$(cat "$T/rs.out")], then the rule rc $RC out [$OUT]"
fixture s7b; g checkout -qb pr; put "$SD/202610170200-bh-3-ix.sql" 'CREATE INDEX IF NOT EXISTS u_ix ON u(id);'
put "$SD/202610170201-bh-3-u.sql" 'CREATE TABLE u (id INTEGER);'; g add -A; g commit -qm pr
gate g7b
[ "$RC" = 1 ] && grep -qF "$DIFFFORM" <<<"$OUT" && ! grep -qF 'git mv' <<<"$OUT" && ok || bad "S7 the gate on the diff form must give no git mv: rc $RC out [$OUT]"

# ── S8 the CI step prints the finding line ──
WF="$DIR/.github/workflows/harness-ci.yml"
awk '/- name: fast always-lints \(BH-3860\)/{f=1} f && /^        run: \|/{r=1; next} r && /^      - name:/{exit} r{sub(/^          /,""); print}' "$WF" > "$T/step.sh"
grep -q 'bin/rules-pack.sh' "$T/step.sh" && ok || bad "S8 cannot extract the fast always-lints run block from $WF"
step() { # step <tag> <finding-or-empty> — run the block in a stub tree
  local W="$T/ci-$1"; mkdir -p "$W/bin"
  cat > "$W/bin/rules-pack.sh" <<EOF
#!/bin/bash
o=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && o=\$2; shift; done
mkdir -p "\$o"; : > "\$o/findings.txt"; : > "\$o/suites.txt"
[ -n "$2" ] && printf '%s\n' "$2" > "\$o/findings.txt"
[ -n "$2" ] && { printf '%s\n' "$2"; exit 1; }; exit 0
EOF
  printf '#!/bin/bash\nexit 0\n' > "$W/bin/fast-lints.sh"
  chmod +x "$W/bin/rules-pack.sh" "$W/bin/fast-lints.sh"
  ( cd "$W" && RUNNER_TEMP="$W/tmp" BASE_REF=main bash "$T/step.sh" ) >"$T/step.out" 2>&1; RC=$?; OUT=$(cat "$T/step.out")
}
step red 'schema-fragment-name: worker/jobs/schema.d/x.sql: schema-fragment-name: uses table t at 100%'
[ "$RC" = 1 ] && grep -qxF '::error title=rules-pack::schema-fragment-name: worker/jobs/schema.d/x.sql: schema-fragment-name: uses table t at 100%25' <<<"$OUT" \
  && ok || bad "S8 a finding must print as ::error: rc $RC out [$OUT]"
step green ''
[ "$RC" = 0 ] && ! grep -q '::error' <<<"$OUT" && ok || bad "S8 no finding must print no ::error: rc $RC out [$OUT]"

# ── S9 two queued PRs, renamed in queue order, the batch passes ──
fixture s9; MAIN0=$BASE
g checkout -qb pr1; put "$SD/202610160900-bh-2-a.sql" 'CREATE TABLE IF NOT EXISTS pa (id INTEGER);
INSERT INTO top_t VALUES (1);'; g add -A; g commit -qm pr1; PR1=$(g rev-parse HEAD)
g checkout -q main; g checkout -qb pr2; put "$SD/202610160901-bh-3-b.sql" 'CREATE TABLE IF NOT EXISTS pb (id INTEGER);
INSERT INTO top_t VALUES (2);'; g add -A; g commit -qm pr2; PR2=$(g rev-parse HEAD)
M=$(date -u -d '2026-10-17 06:00' +%s)
g checkout -q pr1; n1=$(SR_NOW_EPOCH=$M sr_apply "$R" main); r1=$?
c1=$(restamp_same "$R" main "$PR1" pr1)
g checkout -q main; g merge -q --no-ff -m 'merge pr1' pr1
g checkout -q pr2; n2=$(SR_NOW_EPOCH=$((M + 60)) sr_apply "$R" main); r2=$?
c2=$(restamp_same "$R" main "$PR2" pr2)
s1=$(g ls-tree --name-only pr1 -- "$SD/" | grep -- '-bh-2-a.sql'); s2=$(g ls-tree --name-only pr2 -- "$SD/" | grep -- '-bh-3-b.sql')
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ -n "$n1" ] && [ -n "$n2" ] && [ "$s1" = "$SD/202610170600-bh-2-a.sql" ] && [ "$s2" = "$SD/202610170601-bh-3-b.sql" ] \
  && ok || bad "S9 both renamed in queue order: rc $r1/$r2 names [$s1] [$s2]"
[[ ${s2##*/} > ${s1##*/} ]] && ok || bad "S9 PR2 [$s2] must sort after PR1 [$s1]"
[ "$c1" = restamp ] && [ "$c2" = restamp ] && ok || bad "S9 the lead verdict must carry for both: [$c1] [$c2]"
g checkout -q main; g merge -q --no-ff -m 'merge pr2' pr2
OUT=$(rp_schema_fragment_name "$R" "$MAIN0"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S9 the batch (main + PR1 + PR2) against the batch base: rc $RC out [$OUT]"

# ── S10 the same batch, no rename ──
fixture s10; MAIN0=$BASE
put "$SD/202610160900-bh-2-a.sql" 'CREATE TABLE IF NOT EXISTS pa (id INTEGER);
INSERT INTO base VALUES (1);'
put "$SD/202610160901-bh-3-b.sql" 'CREATE TABLE IF NOT EXISTS pb (id INTEGER);
INSERT INTO pa VALUES (2);'
g add -A; g commit -qm batch
OUT=$(rp_schema_fragment_name "$R" "$MAIN0"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S10 a stale batch with no inversion: rc $RC out [$OUT]"

# ── S11 exit paths ──
OUT=$(rp_schema_fragment_name "$R" no-such-ref-7229 2>/dev/null); RC=$?
[ "$RC" = 125 ] && ok || bad "S11 a bad base must be rc 125, got $RC"
# A dangling link: unreadable even as root (chmod 000 is not).
fixture s11; ln -s "$T/no-such-file-7229" "$R/$SD/202610170400-bh-5-gone.sql"
put "$SD/202610160900-bh-2-a.sql" 'INSERT INTO base VALUES (1);'
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S11 an unreadable later fragment: rc $RC out [$OUT] err [$(cat "$T/err")]"

# ── S12 the later fragment is at the base only ──
fixture s12; g checkout -q -b pr HEAD; g rm -q "$SD/202610170154-bh-1-top.sql"; g commit -qm 'fork before top'
g checkout -q main; g checkout -q -b pr2 pr; put "$SD/202610160900-bh-2-a.sql" 'INSERT INTO top_t VALUES (1);'
[ ! -e "$R/$SD/202610170154-bh-1-top.sql" ] && ok || bad "S12 setup: the later fragment must not be on disk"
lint
[ "$RC" = 1 ] && grep -qF "uses table top_t, which $SD/202610170154-bh-1-top.sql $BASEFORM" <<<"$OUT" && ok || bad "S12 rc $RC out [$OUT]"

echo "schema-stamp-order.bh-7229: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
