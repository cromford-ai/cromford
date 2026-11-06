#!/bin/bash
# tests/name-guard.bh-8918-test.sh — BH-8918. Pins bin/name-guard.py, the
# product-board name guard, and runs it over this repo's own diff.
#
# The deny terms are literal ONLY in catalog/name-guard.d/. This suite never
# writes one: it reads every term from the real deny files at run time and
# builds each fixture line from it.
#
# FIXTURE PART. One scratch git repo per case (origin/main = base commit,
# branch `work` = the change). The guard runs through its real CLI over
# `git diff <base>...HEAD`. Every deny file with no `scope:` line is the
# unscoped kind; every deny file with one is the scoped kind.
#   hits:     each unscoped term in a snake_case, camelCase and kebab-case
#             identifier, a route string, a SQL name, a UI string, a comment,
#             mixed case, and (multi-word terms) the apostrophe and hyphen
#             forms; an added line that starts with `++`; a scoped term in a
#             path inside its scope; the new line number after a change.
#   non-hits: a term inside a longer word; a removed line; an unchanged
#             context line; an added line in an allow-listed path; a scoped
#             term in a path outside its scope; a renamed file's unchanged
#             lines (pure rename and rename with an edit); a deleted file.
#   allow by stem: a fixture lists dir proves a `<glob> <stem>` allow line
#             exempts only that stem.
#   usage:    no args and an unresolvable base are rc 2.
# LIVE PART. bin/name-guard.py --base <b> over this repo, <b> resolved by
# rd_base (RATCHET_BASE, TI_BASE, origin/main). No base = red.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/name-guard.bh-8918-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1

GUARD="$DIR/bin/name-guard.py"
LISTS="$DIR/catalog/name-guard.d"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# terms_of <deny file>: one term per line, comments, blanks and scope: lines out.
terms_of() { sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e '/^scope:/d' "$1"; }

# run_guard <repo> [extra args]: sets OUT and RC.
run_guard() {
  local r="$1"; shift
  OUT=$(python3 "$GUARD" --base origin/main --repo "$r" "$@" 2>&1); RC=$?
}

# new_repo <name>: an empty fixture repo at $T/<name> (base commit on origin/main).
new_repo() { R="$T/$1"; rd_fixture_repo "$R" >/dev/null 2>&1 || { bad "$1: cannot build fixture repo"; return 1; }; }
commit_work() { rd_git "$1" add -A && rd_git "$1" commit -qm work; }

expect_rc() { # <case> <want rc>
  if [ "$RC" = "$2" ]; then ok; else bad "$1: rc $RC, want $2; output: $OUT"; fi
}
expect_line() { # <case> <fixed string>
  if grep -qF -- "$2" <<<"$OUT"; then ok; else bad "$1: output lacks [$2]; output: $OUT"; fi
}

UNSCOPED=() SCOPED=()
for f in "$LISTS"/*.txt; do
  [ "$(basename "$f")" = allow.txt ] && continue
  if grep -q '^scope:' "$f"; then SCOPED+=("$f"); else UNSCOPED+=("$f"); fi
done
[ "${#UNSCOPED[@]}" -gt 0 ] || bad "no unscoped deny file under $LISTS"
[ "${#SCOPED[@]}" -gt 0 ] || bad "no scoped deny file under $LISTS"

# forms <term>: "<form>\t<line>" for each fixture form of one term.
forms() {
  python3 - "$1" <<'PY'
import re, sys
t = sys.argv[1]
w = re.findall(r"[a-z0-9]+", re.sub(r"['@]", "", t.lower()))
mixed = "".join(c.upper() if i % 2 else c.lower() for i, c in enumerate(t))
out = [
    ("snake", "load_%s_id = 1" % "_".join(w)),
    ("camel", "const load%sId = 1;" % "".join(x.capitalize() for x in w)),
    ("kebab", 'class="load-%s-id"' % "-".join(w)),
    ("route", 'fetch("/api/%s/list")' % "-".join(w)),
    ("sql", "CREATE TABLE %s_rows (id INTEGER);" % "_".join(w)),
    ("ui", 'label: "Open %s now"' % t),
    ("comment", "// see %s here" % t),
    ("mixed", 'x = "%s"' % mixed),
    ("plusplus", "++ %s" % t),
]
if len(w) > 1:
    out.append(("apostrophe", 'title: "%s"' % "'".join(w)))
    out.append(("hyphen", 'title: "%s"' % "-".join(w)))
for k, v in out:
    print("%s\t%s" % (k, v))
PY
}
# joined <term>: the term's words with nothing between them.
joined() { python3 -c 'import re,sys; print("".join(re.findall(r"[a-z0-9]+", re.sub(r"['"'"'@]", "", sys.argv[1].lower()))))' "$1"; }
# sample_path <glob>: one path the glob matches.
sample_path() { sed -e 's#\*\*#a/b#g' -e 's#\*#-fixture#g' <<<"$1"; }

[ -f "$GUARD" ] || bad "missing $GUARD"

# ── hits: every unscoped term, every form ─────────────────────────────────
n=0
for f in "${UNSCOPED[@]}"; do
  stem=$(basename "$f" .txt)
  while IFS= read -r term; do
    n=$((n + 1))
    new_repo "hit-$n" || continue
    mkdir -p "$R/src/forms"
    forms_out=$(forms "$term")
    while IFS=$'\t' read -r form line; do
      printf '%s\n' "$line" > "$R/src/forms/$form.js"
    done <<<"$forms_out"
    commit_work "$R"
    run_guard "$R" --lists "$LISTS"
    expect_rc "hit-$n ($stem term $n)" 1
    while IFS=$'\t' read -r form _; do
      expect_line "hit-$n $form" "name-guard: src/forms/$form.js:1: term \"$term\" ($stem)"
    done <<<"$forms_out"
  done < <(terms_of "$f")
done
[ "$n" -gt 0 ] || bad "the unscoped deny files hold no term"

# One unscoped term and one scoped term reused by the cases below.
U_FILE=${UNSCOPED[0]:-/dev/null}; U_STEM=$(basename "$U_FILE" .txt)
U_TERM=$(terms_of "$U_FILE" | sed -n 1p)
S_FILE=${SCOPED[0]:-/dev/null}; S_STEM=$(basename "$S_FILE" .txt)
S_TERM=$(terms_of "$S_FILE" | sed -n 1p)
S_IN=$(sample_path "$(sed -n 's/^scope:[[:space:]]*//p' "$S_FILE" | sed -n 1p)")

# ── hit: the line number is the NEW line number ───────────────────────────
new_repo lineno-base && {
  mkdir -p "$R/src"; printf 'one\ntwo\nthree\nfour\n' > "$R/src/n.js"
  rd_git "$R" add -A && rd_git "$R" commit -qm B2 && rd_git "$R" update-ref refs/remotes/origin/main HEAD
  printf 'one\ntwo\nx = "%s"\nfour\n' "$U_TERM" > "$R/src/n.js"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc lineno 1
  expect_line lineno "name-guard: src/n.js:3: term \"$U_TERM\" ($U_STEM)"
}

# ── hit: a scoped term in a path inside its scope ─────────────────────────
new_repo scoped-in && {
  mkdir -p "$(dirname "$R/$S_IN")"
  printf 'const %sId = 1;\n' "$(joined "$S_TERM")" > "$R/$S_IN"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc scoped-in 1
  expect_line scoped-in "name-guard: $S_IN:1: term \"$S_TERM\" ($S_STEM)"
}

# ── non-hit: the term inside a longer word (letters on either side) ───────
new_repo longer-word && {
  mkdir -p "$R/src"
  for f in "${UNSCOPED[@]}"; do
    while IFS= read -r term; do
      j=$(joined "$term"); printf 'zq%szq\n%sx\nx%s\n' "$j" "$j" "$j"
    done < <(terms_of "$f")
  done > "$R/src/long.js"
  mkdir -p "$(dirname "$R/$S_IN")"
  printf 'v = "%st"\n' "$(joined "$S_TERM")" > "$R/$S_IN"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc longer-word 0
}

# ── non-hit: a removed line ───────────────────────────────────────────────
new_repo removed-base && {
  mkdir -p "$R/src"; printf 'keep\nx = "%s"\n' "$U_TERM" > "$R/src/r.js"
  rd_git "$R" add -A && rd_git "$R" commit -qm B2 && rd_git "$R" update-ref refs/remotes/origin/main HEAD
  printf 'keep\n' > "$R/src/r.js"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc removed-line 0
}

# ── non-hit: an unchanged context line next to a change ───────────────────
new_repo context-base && {
  mkdir -p "$R/src"; printf 'a\nx = "%s"\nb\n' "$U_TERM" > "$R/src/c.js"
  rd_git "$R" add -A && rd_git "$R" commit -qm B2 && rd_git "$R" update-ref refs/remotes/origin/main HEAD
  printf 'a\nx = "%s"\nb changed\n' "$U_TERM" > "$R/src/c.js"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc context-line 0
  # --base reads a -U0 diff, which has no context line at all. A saved diff
  # with the default 3 lines of context puts the term on a ` ` line: still
  # not an added line, so no hit.
  # pr-scoped: ok the range is the scratch fixture repo $R's own, never this PR's
  rd_git "$R" diff origin/main...HEAD > "$T/context.diff"
  if grep -qF -- " x = " "$T/context.diff"; then ok; else bad "context-line-diff-file: fixture diff has no context line"; fi
  OUT=$(python3 "$GUARD" --diff-file "$T/context.diff" --lists "$LISTS" 2>&1); RC=$?
  expect_rc context-line-diff-file 0
}

# ── non-hit: added lines in allow-listed paths ────────────────────────────
new_repo allowed && {
  mkdir -p "$R/.harness/specs/a/b" "$R/.harness/specs" "$R/docs"
  printf 'x = "%s"\n' "$U_TERM" > "$R/.harness/specs/a/b/spec.md"
  printf 'x = "%s"\n' "$U_TERM" > "$R/.harness/specs/top.md"
  printf '<p>%s</p>\n' "$U_TERM" > "$R/docs/PRODUCT_BOARD_PLAN_fixture.html"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc allow-listed 0
}

# ── hit: a stem-limited allow line does not exempt the other deny files ───
new_repo allow-other-stem && {
  mkdir -p "$R/bin/lib"
  printf 'x="%s"\n' "$U_TERM" > "$R/bin/lib/tracker.sh"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc allow-other-stem 1
  expect_line allow-other-stem "name-guard: bin/lib/tracker.sh:1: term \"$U_TERM\" ($U_STEM)"
}

# ── allow by stem, on a fixture lists dir ─────────────────────────────────
FL="$T/fixture-lists"; mkdir -p "$FL"
printf 'scope: src/**\nfixtureword\n' > "$FL/fx.txt"
printf 'src/ok/** fx\nsrc/other/** nostem\n' > "$FL/allow.txt"
new_repo allow-stem && {
  mkdir -p "$R/src/ok/deep" "$R/src/bad" "$R/src/other"
  echo 'fixtureword = 1' > "$R/src/ok/deep/a.js"
  echo 'fixtureword = 1' > "$R/src/bad/a.js"
  echo 'fixtureword = 1' > "$R/src/other/a.js"
  echo 'fixtureword = 1' > "$R/outside.js"
  commit_work "$R"
  run_guard "$R" --lists "$FL"
  expect_rc allow-stem 1
  expect_line allow-stem 'name-guard: src/bad/a.js:1: term "fixtureword" (fx)'
  expect_line allow-stem 'name-guard: src/other/a.js:1: term "fixtureword" (fx)'
  if grep -qF 'src/ok/' <<<"$OUT"; then bad "allow-stem: src/ok/ is allow-listed for fx: $OUT"; else ok; fi
  if grep -qF 'outside.js' <<<"$OUT"; then bad "allow-stem: outside.js is outside the fx scope: $OUT"; else ok; fi
}

# ── non-hit: a scoped term in a path outside its scope ────────────────────
new_repo scoped-out && {
  mkdir -p "$R/src/outside"
  printf 'const %sId = 1;\n// %s\n' "$(joined "$S_TERM")" "$S_TERM" > "$R/src/outside/fixture.js"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc scoped-out 0
}

# ── non-hit: a renamed file's unchanged lines ─────────────────────────────
rename_case() { # <name> <edit 0|1>
  new_repo "$1" || return
  mkdir -p "$R/old"
  { for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done; printf 'x = "%s"\n' "$U_TERM"; } > "$R/old/a.js"
  rd_git "$R" add -A && rd_git "$R" commit -qm B2 && rd_git "$R" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$R/new"; rd_git "$R" mv old/a.js new/a.js
  [ "$2" = 1 ] && sed -i 's/^line 3$/line three/' "$R/new/a.js"
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc "$1" 0
}
rename_case rename-pure 0
rename_case rename-edit 1

# ── non-hit: a deleted file ───────────────────────────────────────────────
new_repo deleted && {
  mkdir -p "$R/src"; printf 'x = "%s"\n' "$U_TERM" > "$R/src/d.js"
  rd_git "$R" add -A && rd_git "$R" commit -qm B2 && rd_git "$R" update-ref refs/remotes/origin/main HEAD
  rd_git "$R" rm -q src/d.js
  commit_work "$R"
  run_guard "$R" --lists "$LISTS"
  expect_rc deleted-file 0
}

# ── --diff-file reads a saved diff ────────────────────────────────────────
new_repo diff-file && {
  mkdir -p "$R/src"; printf 'x = "%s"\n' "$U_TERM" > "$R/src/f.js"
  commit_work "$R"
  # pr-scoped: ok the range is the scratch fixture repo $R's own, never this PR's
  rd_git "$R" diff origin/main...HEAD > "$T/saved.diff"
  OUT=$(python3 "$GUARD" --diff-file "$T/saved.diff" --lists "$LISTS" 2>&1); RC=$?
  expect_rc diff-file 1
  expect_line diff-file "name-guard: src/f.js:1: term \"$U_TERM\" ($U_STEM)"
}

# ── usage: rc 2 ───────────────────────────────────────────────────────────
OUT=$(python3 "$GUARD" 2>&1); RC=$?
expect_rc usage-no-args 2
new_repo bad-base && {
  OUT=$(python3 "$GUARD" --base refs/heads/no-such-fixture-ref --repo "$R" --lists "$LISTS" 2>&1); RC=$?
  expect_rc bad-base 2
}

# ── live part: this repo's own diff ───────────────────────────────────────
if LB=$(rd_base "$DIR"); then
  OUT=$(python3 "$GUARD" --base "$LB" --repo "$DIR" 2>&1); RC=$?
  expect_rc "live diff ${LB:0:12}...HEAD" 0
else
  bad "live: $LB"
fi

echo "name-guard.bh-8918: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAIL"; exit 1
