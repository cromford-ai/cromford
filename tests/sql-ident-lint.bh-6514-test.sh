#!/bin/bash
# tests/sql-ident-lint.bh-6514-test.sh — the SQL identifier ratchet,
# bin/sql-ident-lint.sh (BH-6514, slice BH-6521). Cases L1-L13 drive the lint
# on fixture repos (a `git init` tree with files under worker/x/src/). L14 runs
# it on this checkout, so the merge-queue corpus runs the ratchet: a PR that
# adds an unmarked run-time `prepare(` over the baseline is red here. L15 pins
# the catalog/silence-markers.tsv row that routes a new marker to the lead.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LINT="$REPO/bin/sql-ident-lint.sh"
M="sql-ident""-ok:"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }

# fx <name>: a fresh fixture repo; prints its path.
fx() {
  local d="$T/$1"
  mkdir -p "$d/worker/x/src" && git -C "$d" init -q && printf '%s\n' "$d"
}
# put <repo> <rel> : stdin to the file, then git add.
put() { mkdir -p "$1/$(dirname "$2")"; cat > "$1/$2"; git -C "$1" add -A; }
# run <repo> [args...]: sets OUT, ERR, RC.
run() {
  local r="$1"; shift
  OUT=$("$LINT" --root "$r" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
last() { printf '%s\n' "$OUT" | tail -n 1; }
expect() { # expect <case> <rc> <summary-or-empty>
  if [ "$RC" != "$2" ]; then bad "$1: rc $RC, want $2" "$OUT"$'\n'"$ERR"; return; fi
  if [ -n "${3:-}" ] && [ "$(last)" != "sql-ident-lint: $3" ]; then bad "$1: summary" "$(last)"; return; fi
  ok "$1"
}
has() { grep -qF -- "$2" <<<"$OUT" && ok "$1" || bad "$1: no '$2'" "$OUT"; }
hasnt() { grep -qF -- "$2" <<<"$OUT" && bad "$1: has '$2'" "$OUT" || ok "$1"; }

# ── L1 an unmarked interpolated prepare is red and named ─────────────────────
R=$(fx l1)
put "$R" worker/x/src/a.js <<'EOF'
export async function f(env, x) {
  // reads t
  return env.DB.prepare(`SELECT ${x} FROM t`).all();
}
EOF
run "$R"
expect "L1 unmarked site is rc 1" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"
has "L1 names path:line" "worker/x/src/a.js:3: unmarked SQL text built at run time"

# ── L2 a marked site passes: on the line, in the block above, multi-line ─────
R=$(fx l2a)
put "$R" worker/x/src/a.js <<EOF
export async function f(env, x) {
  // reads t
  return env.DB.prepare(\`SELECT \${x} FROM t\`).all(); // $M TABLES const
}
EOF
run "$R"; expect "L2 marker on the line" 0 "1 sites in 1 files, 1 marked, 0 unmarked, 0 within baseline, 0 over"
R=$(fx l2b)
put "$R" worker/x/src/a.js <<EOF
export async function f(env, x) {
  // $M x is one of the TABLES const names,
  // checked by sqlIdent above.
  return env.DB.prepare(\`SELECT \${x} FROM t\`).all();
}
EOF
run "$R"; expect "L2 marker in the 2-line block above" 0 "1 sites in 1 files, 1 marked, 0 unmarked, 0 within baseline, 0 over"
R=$(fx l2c)
put "$R" worker/x/src/a.js <<EOF
export async function f(env, x) {
  // $M MAX_ROWS is a number const
  const r = await env.DB.prepare(
    \`SELECT a FROM t LIMIT \${x}\`
  ).all();
  return r;
}
EOF
run "$R"; expect "L2 multi-line call, marker above prepare(" 0 "1 sites in 1 files, 1 marked, 0 unmarked, 0 within baseline, 0 over"
run "$R" --print
has "L2 --print row is marked at the prepare line" $'worker/x/src/a.js:3\tmarked\t`SELECT a FROM t LIMIT ${x}`'

# ── L3 adversarial negatives are no site; a regex with a backtick hides nothing
R=$(fx l3)
put "$R" worker/x/src/a.js <<'EOF'
export function g(env, x, db) {
  const q = /[`'"]/;
  env.DB.prepare("SELECT ${x}").all();
  env.DB.prepare(`SELECT 1`).all();
  // env.DB.prepare(`SELECT ${x}`)
  /* env.DB.prepare(`SELECT ${x}`) */
  db.prepareStatement(`${x}`);
  const s = `SELECT ${x}`; env.DB.prepare(s);
  env.DB.prepare("SELECT a " + "FROM t");
  env.DB.prepare("SELECT a LIMIT " + 5);
  env.DB.prepare('it\'s `${x}` + ' + "y");
  return q.test(x) && x / 2 / 3;
}
EOF
run "$R"; expect "L3 adversarial list is 0 sites" 0 "0 sites in 0 files, 0 marked, 0 unmarked, 0 within baseline, 0 over"
put "$R" worker/x/src/b.js <<'EOF'
const q = /[`'"]/;
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
run "$R"; expect "L3 a regex holding a backtick does not hide a later site" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"
has "L3 the site is the one after the regex" "worker/x/src/b.js:2:"
R=$(fx l3n)
put "$R" worker/x/src/a.js <<'EOF'
export const h = (env, a, b) => env.DB.prepare(`SELECT ${a ? `x` : `y${b}`} FROM t`).all();
EOF
run "$R"; expect "L3 nested template in \${} is one site" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"

# ── L4 concatenation: a non-literal operand is a site; literals only are not ─
R=$(fx l4)
put "$R" worker/x/src/a.js <<'EOF'
export const h = (env, x) => env.DB.prepare("SELECT a FROM " + x).all();
EOF
run "$R"; expect "L4 \"a \" + x is a site" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"
R=$(fx l4b)
put "$R" worker/x/src/a.js <<'EOF'
export const h = (env) => env.DB.prepare("SELECT a " + "FROM t").all();
export const k = (env) => env.DB.prepare("SELECT a FROM t LIMIT " + 5).all();
export const m = (env) => env.DB.prepare(`SELECT a ` + `FROM t`, 1).all();
EOF
run "$R"; expect "L4b literal-only joins are 0 sites" 0 "0 sites in 0 files, 0 marked, 0 unmarked, 0 within baseline, 0 over"

# ── L5 what does NOT mark: a gap, no reason, a marker inside a string ────────
R=$(fx l5a)
put "$R" worker/x/src/a.js <<EOF
// $M TABLES const

export const h = (env, x) => env.DB.prepare(\`SELECT \${x}\`).all();
EOF
run "$R"; expect "L5 a blank line between marker and site" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"
R=$(fx l5b)
put "$R" worker/x/src/a.js <<EOF
export const h = (env, x) => env.DB.prepare(\`SELECT \${x}\`).all(); // $M
export const k = (env, x) => env.DB.prepare(\`SELECT \${x}\`).all(); // $M ok.
EOF
run "$R"; expect "L5 a marker with no 3-letter reason" 1 "2 sites in 1 files, 0 marked, 2 unmarked, 0 within baseline, 2 over"
R=$(fx l5c)
put "$R" worker/x/src/a.js <<EOF
export const h = (env, x) => env.DB.prepare(\`SELECT \${x} /* $M TABLES const */\` + "// $M TABLES const").all();
EOF
run "$R"; expect "L5 marker text inside a string" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"
R=$(fx l5d)
put "$R" worker/x/src/a.js <<EOF
// $M TABLES const
const y = 1;
export const h = (env, x) => env.DB.prepare(\`SELECT \${x}\`).all();
EOF
run "$R"; expect "L5 a code line between marker and site" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"

# ── L6 a fragment allows its count; one more site is over and named ──────────
R=$(fx l6)
put "$R" worker/x/src/a.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
mkdir -p "$R/tests/fixtures/sql-ident-baseline"
echo 1 > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__a.js.count.txt"
run "$R"; expect "L6 1 unmarked within a count of 1" 0 "1 sites in 1 files, 0 marked, 1 unmarked, 1 within baseline, 0 over"
printf '%s\n' 'export const k = (env, y) => env.DB.prepare("SELECT a FROM " + y).all();' >> "$R/worker/x/src/a.js"
run "$R"; expect "L6 a second unmarked site is over" 1 "2 sites in 1 files, 0 marked, 2 unmarked, 1 within baseline, 1 over"
has "L6 the new line is named" "worker/x/src/a.js:2: unmarked"
hasnt "L6 the baselined line is not named" "worker/x/src/a.js:1:"

# ── L7 a count above the unmarked sites is a NOTE, not red ───────────────────
echo 3 > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__a.js.count.txt"
run "$R"; expect "L7 count 3, 2 unmarked: rc 0" 0 "2 sites in 1 files, 0 marked, 2 unmarked, 2 within baseline, 0 over"
has "L7 NOTE names the fragment" "NOTE worker__x__src__a.js.count.txt: count 3 is above the 2 unmarked sites; regenerate the baseline"

# ── L8 a fragment whose source is gone is a NOTE ─────────────────────────────
echo 2 > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__a.js.count.txt"
echo 4 > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__gone.js.count.txt"
run "$R"; expect "L8 gone source: rc 0" 0 "2 sites in 1 files, 0 marked, 2 unmarked, 2 within baseline, 0 over"
has "L8 NOTE says gone" "NOTE worker__x__src__gone.js.count.txt: source file worker/x/src/gone.js is gone; delete the fragment"
hasnt "L8 no NOTE for the fragment that fits" "NOTE worker__x__src__a.js"

# ── L9 a file that does not parse is rc 2, named, no summary ─────────────────
R=$(fx l9)
put "$R" worker/x/src/ok.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
put "$R" worker/x/src/broken.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}
EOF
run "$R"; expect "L9 unterminated template is rc 2" 2
case "$ERR" in *"cannot parse worker/x/src/broken.js: unterminated template from line 1"*) ok "L9 stderr names the path" ;; *) bad "L9 stderr" "$ERR" ;; esac
[ -z "$OUT" ] && ok "L9 no summary line on rc 2" || bad "L9 stdout not empty" "$OUT"

# ── L10 rc 2: unknown flag, root not a git tree, a bad fragment ──────────────
R=$(fx l10)
put "$R" worker/x/src/a.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
run "$R" --bogus; expect "L10 unknown flag" 2
case "$ERR" in *"unknown argument --bogus"*) ok "L10 names the flag" ;; *) bad "L10 flag stderr" "$ERR" ;; esac
mkdir -p "$T/notgit"
run "$T/notgit"; expect "L10 root not a git work tree" 2
case "$ERR" in *"is not a git work tree"*) ok "L10 names the root" ;; *) bad "L10 root stderr" "$ERR" ;; esac
mkdir -p "$R/tests/fixtures/sql-ident-baseline"
echo abc > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__a.js.count.txt"
run "$R"; expect "L10 fragment holding abc" 2
case "$ERR" in *"bad fragment worker__x__src__a.js.count.txt"*) ok "L10 names the fragment" ;; *) bad "L10 fragment stderr" "$ERR" ;; esac
run "$R" --print --print-baseline; expect "L10 --print with --print-baseline" 2
run "$R" worker/x/src/nope.js; expect "L10 a FILE arg that does not exist" 2

# ── L11 round trip: the header recipe writes fragments the next run accepts ──
R=$(fx l11)
put "$R" worker/x/src/a.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
export const k = (env, y) => env.DB.prepare("SELECT a FROM " + y).all();
EOF
put "$R" worker/x/src/sub/b.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
mkdir -p "$R/bin" && cp "$LINT" "$R/bin/sql-ident-lint.sh"
RECIPE=$(sed -n '/^# Regenerate the baseline/{n;p;n;p;}' "$LINT" | sed 's/^#   //')
[ "$(printf '%s\n' "$RECIPE" | wc -l)" = 2 ] && ok "L11 recipe is 2 lines in the header" || bad "L11 recipe" "$RECIPE"
# The recipe's B is relative to the repo root. It runs here with B made
# absolute under the scratch repo, so its `rm -f "$B"/*.count.txt` names a
# path the trace runner can see is inside $T (a relative path in a child
# `bash -c` read as the checkout's own fixtures: BH-6521, batch #6782).
RECIPE_ABS=${RECIPE/B=tests\/fixtures\/sql-ident-baseline/B=$R/tests/fixtures/sql-ident-baseline}
[ "$RECIPE_ABS" != "$RECIPE" ] && ok "L11 the recipe sets B" || bad "L11 the recipe's B line" "$RECIPE"
(cd "$R" && bash -c "set -e; $RECIPE_ABS")
printf '%s\n' "$(cd "$R/tests/fixtures/sql-ident-baseline" && for f in *; do printf '%s=%s ' "$f" "$(cat "$f")"; done)" > "$T/l11.out"
[ "$(cat "$T/l11.out")" = "worker__x__src__a.js.count.txt=2 worker__x__src__sub__b.js.count.txt=1 " ] \
  && ok "L11 recipe wrote 2 fragments" || bad "L11 fragments" "$(cat "$T/l11.out")"
run "$R"; expect "L11 next run is clean" 0 "3 sites in 2 files, 0 marked, 3 unmarked, 3 within baseline, 0 over"
hasnt "L11 no NOTE" "NOTE"

# ── L12 the summary counts: 1 marked, 1 baselined, 1 over ────────────────────
R=$(fx l12)
put "$R" worker/x/src/a.js <<EOF
export const h = (env, x) => env.DB.prepare(\`SELECT \${x}\`).all(); // $M TABLES const
export const k = (env, y) => env.DB.prepare("SELECT a FROM " + y).all();
EOF
put "$R" worker/x/src/b.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
mkdir -p "$R/tests/fixtures/sql-ident-baseline"
echo 1 > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__a.js.count.txt"
run "$R"; expect "L12 exact summary, rc 1" 1 "3 sites in 2 files, 1 marked, 2 unmarked, 1 within baseline, 1 over"
has "L12 the over site is b.js" "worker/x/src/b.js:1: unmarked"
run "$R" --print-baseline
[ "$RC" = 0 ] && [ "$OUT" = $'worker__x__src__a.js.count.txt\t1\nworker__x__src__b.js.count.txt\t1' ] \
  && ok "L12 --print-baseline lists unmarked counts, ignores fragments" || bad "L12 --print-baseline rc $RC" "$OUT"

# ── L13 FILE args: only those files; other fragments get no NOTE ─────────────
R=$(fx l13)
put "$R" worker/x/src/a.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
put "$R" worker/x/src/b.js <<'EOF'
export const h = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
export const k = (env, x) => env.DB.prepare(`SELECT ${x}`).all();
EOF
mkdir -p "$R/tests/fixtures/sql-ident-baseline"
echo 9 > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__b.js.count.txt"
echo 9 > "$R/tests/fixtures/sql-ident-baseline/worker__x__src__gone.js.count.txt"
run "$R" worker/x/src/a.js; expect "L13 scans only the FILE arg" 1 "1 sites in 1 files, 0 marked, 1 unmarked, 0 within baseline, 1 over"
hasnt "L13 no NOTE for other files' fragments" "NOTE"

# ── L14 the real tree: rc 0, registry.js marked, no registry.js fragment ─────
OUT=$("$LINT" --root "$REPO" 2>"$T/err"); RC=$?
if [ "$RC" = 0 ] && [[ "$(last)" == *", 0 over" ]]; then ok "L14 real tree is rc 0, 0 over"; else bad "L14 real tree rc $RC" "$(printf '%s\n' "$OUT" | grep -v '^NOTE' | tail -n 20)"$'\n'"$(cat "$T/err")"; fi
OUT=$("$LINT" --root "$REPO" --print worker/jobs/src/routes/registry.js 2>&1); RC=$?
n=$(printf '%s\n' "$OUT" | grep -c $'^worker/jobs/src/routes/registry.js:[0-9]*\tmarked\t')
[ "$n" = 4 ] && ok "L14 registry.js has 4 marked sites" || bad "L14 registry.js marked rows: $n" "$OUT"
[[ "$(last)" == *" 0 unmarked,"* ]] && ok "L14 registry.js has 0 unmarked" || bad "L14 registry.js unmarked" "$(last)"
[ ! -e "$REPO/tests/fixtures/sql-ident-baseline/worker__jobs__src__routes__registry.js.count.txt" ] \
  && ok "L14 no registry.js fragment" || bad "L14 registry.js fragment exists"

# ── L15 the silence-markers row ──────────────────────────────────────────────
CAT="$REPO/catalog/silence-markers.tsv"
[ "$(grep -c $'^sql-ident\tlead\t' "$CAT")" = 1 ] && ok "L15 one sql-ident lead row" || bad "L15 row count"
prev=$(grep -B1 $'^sql-ident\tlead\t' "$CAT" | head -n 1 | cut -f1)
[ "$prev" = determinism ] && ok "L15 row follows determinism" || bad "L15 previous row: $prev"
. "$REPO/bin/lib/silence-scan.sh" || exit 1
OUT=$(printf 'worker/x/src/a.js\t\t%s\n' "  return env.DB.prepare(x); // $M" | ss_match "$CAT" reasonless)
[ -n "$OUT" ] && ok "L15 a bare marker is reasonless" || bad "L15 bare marker not flagged"
OUT=$(printf 'worker/x/src/a.js\t\t%s\n' "  return env.DB.prepare(x); // $M TABLES const" | ss_match "$CAT" reasonless)
[ -z "$OUT" ] && ok "L15 a marker with a reason passes" || bad "L15 reasoned marker flagged" "$OUT"
OUT=$(printf 'worker/x/src/a.js\t\t%s\n' "  return env.DB.prepare(x); // $M TABLES const" | ss_match "$CAT")
[[ "$OUT" == lead$'\t'*"a SQL identifier marker (BH-6514)"* ]] && ok "L15 a marker goes to the lead" || bad "L15 marker route" "$OUT"
OUT=$(printf 'tests/fixtures/sql-ident-baseline/x.count.txt\t\t3\n' | ss_match "$CAT")
[[ "$OUT" == lead$'\t'* ]] && ok "L15 a baseline fragment routes to lead, not human" || bad "L15 fragment route" "$OUT"

echo "sql-ident-lint.bh-6514: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
