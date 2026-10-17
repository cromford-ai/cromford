#!/bin/bash
# tests/docs-guide-port.bh-7138-test.sh — the port channel ships docs/guide/
# unchanged (BH-7138, the rest of BH-6507).
#
# tests/docs-guide-pages.bh-6507-test.sh pins the sanitize channel (arms P1-P3).
# The after-merge step ports to the public copy through bin/port-to-cromford.sh,
# which runs bin/share/port.py plan. port.py has its own STRIP_RULES and a .md-only
# dollar redaction (DOLLAR_RE) that sanitize does not have, so this suite runs
# the real port.py over a scratch upstream that adds the guide.
#
#   C0  strip_reason, sanitize.dropped give None and sanitize.rewrite_path is the
#       identity for the 4 pages and docs/guide.md
#   C1  port.py plan rc 0; all 5 paths in .copied, none in .stripped or .dollars
#   C2  every staged file is byte-identical to its source
#   C3  leakcheck.py --quiet rc 0 on the staged guide
#   C4  the scratch upstream checkout is not written to
#   N1  a docs/guide/ strip rule (in a copy of bin/share) turns C0 and C1 red
#   N2  a page with a dollar amount turns C2 red
#
# Writes only under the scratch dir $T, never into the checkout.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/docs-guide-port.bh-7138-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PAGES=(docs/guide/01-quickstart.md docs/guide/02-onboarding.md docs/guide/03-connectors.md
       docs/guide/04-archie.md docs/guide.md)
for p in "${PAGES[@]}"; do [ -f "$DIR/$p" ] && ok || bad "missing $p"; done
[ "$FAIL" -eq 0 ] || { echo "docs-guide-port: $PASS passed, $FAIL failed"; exit 1; }

export GIT_AUTHOR_NAME=porter GIT_AUTHOR_EMAIL=porter@example.invalid
export GIT_COMMITTER_NAME=porter GIT_COMMITTER_EMAIL=porter@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# make_upstream <dir>: a repo with bin/share at tag base and the 5 files at tag guide.
make_upstream() {
  local up=$1 p
  mkdir -p "$up/bin" || return 1
  cp -r "$DIR/bin/share" "$up/bin/share" || return 1
  git init -q -b main "$up" && git -C "$up" add -A && git -C "$up" commit -qm base \
    && git -C "$up" tag base || return 1
  for p in "${PAGES[@]}"; do
    mkdir -p "$up/$(dirname "$p")" && cp "$DIR/$p" "$up/$p" || return 1
  done
}
commit_guide() { git -C "$1" add -A && git -C "$1" commit -qm guide && git -C "$1" tag guide; }

# check_c0 <share dir>: every path keeps, the reason printed for one that does not.
check_c0() {
  python3 - "$1" "${PAGES[@]}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import port, sanitize
bad = 0
for p in sys.argv[2:]:
    for name, got, want in (("strip_reason", port.strip_reason(p), None),
                            ("sanitize.dropped", sanitize.dropped(p), None),
                            ("sanitize.rewrite_path", sanitize.rewrite_path(p), p)):
        if got != want:
            print("%s(%s) = %r, want %r" % (name, p, got, want)); bad = 1
sys.exit(bad)
PY
}

# check_c1 <manifest>: every path copied, none stripped, none dollar-redacted.
check_c1() {
  local m=$1 p rc=0
  [ -s "$m" ] || { echo "no manifest at $m"; return 1; }
  for p in "${PAGES[@]}"; do
    jq -e --arg p "$p" '.copied | index($p) != null' "$m" >/dev/null || { echo "$p not in .copied"; rc=1; }
    jq -e --arg p "$p" '[.stripped[] | select(.path == $p)] | length == 0' "$m" >/dev/null \
      || { echo "$p stripped: $(jq -r --arg p "$p" '.stripped[] | select(.path == $p) | .reason' "$m")"; rc=1; }
    jq -e --arg p "$p" '[.dollars[] | select(.path == $p)] | length == 0' "$m" >/dev/null \
      || { echo "$p dollar-redacted"; rc=1; }
  done
  return $rc
}

# check_c2 <staging> <source root>: each staged file byte-identical to its source.
check_c2() {
  local s=$1 src=$2 p rc=0
  for p in "${PAGES[@]}"; do
    if [ ! -f "$s/$p" ]; then echo "$p not staged"; rc=1
    elif ! cmp -s "$src/$p" "$s/$p"; then echo "$p changed by the port:"; head -20 < <(diff -u "$src/$p" "$s/$p"); rc=1
    fi
  done
  return $rc
}

# ── the real channel ────────────────────────────────────────────────────────
UP="$T/up"
make_upstream "$UP" && commit_guide "$UP" && ok || bad "scratch upstream setup"

out=$(check_c0 "$DIR/bin/share" 2>&1) && ok || bad "C0 a guide path is stripped, dropped or renamed: $out"

out=$(python3 "$UP/bin/share/port.py" plan "$UP" base guide "$T/c/staging" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok || bad "C1 port.py plan rc=$rc: $out"
out=$(check_c1 "$T/c/port-manifest.json" 2>&1) && ok || bad "C1 $out"

out=$(check_c2 "$T/c/staging" "$DIR" 2>&1) && ok || bad "C2 $out"

out=$(python3 "$DIR/bin/share/leakcheck.py" "$T/c/staging/docs" --quiet 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok || bad "C3 leakcheck rc=$rc on the staged guide: $out"

[ -z "$(git -C "$UP" status --porcelain)" ] && ok || bad "C4 port.py wrote to the upstream: $(git -C "$UP" status --porcelain)"

# ── N1: a docs/guide/ strip rule makes C0 and C1 go red ─────────────────────
mkdir -p "$T/n1"
cp -r "$UP/bin/share" "$T/n1/share"
python3 - "$T/n1/share/port.py" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
anchor = "STRIP_RULES = [\n"
assert anchor in s, "STRIP_RULES anchor missing"
open(f, "w").write(s.replace(anchor, anchor + '    ("docs/guide/", "test strip"),\n', 1))
PY
[ $? -eq 0 ] && ok || bad "N1 could not add a strip rule to the copy"
out=$(check_c0 "$T/n1/share" 2>&1) && bad "N1 C0 stayed green with a docs/guide/ strip rule" || ok
python3 "$T/n1/share/port.py" plan "$UP" base guide "$T/n1/c/staging" >/dev/null 2>&1 \
  && ok || bad "N1 port.py plan failed on the copy"
n=$(jq '[.stripped[] | select(.reason == "test strip")] | length' "$T/n1/c/port-manifest.json" 2>/dev/null)
[ "$n" = 4 ] && ok || bad "N1 want the 4 pages stripped with reason 'test strip', got ${n:-none}"
out=$(check_c1 "$T/n1/c/port-manifest.json" 2>&1) && bad "N1 C1 stayed green with the 4 pages stripped" || ok

# ── N2: a dollar amount on a page makes C2 go red ───────────────────────────
UP2="$T/up2"
make_upstream "$UP2" && printf '\nThe plan costs $12 a month.\n' >> "$UP2/docs/guide/01-quickstart.md" \
  && commit_guide "$UP2" && ok || bad "N2 scratch upstream setup"
python3 "$UP2/bin/share/port.py" plan "$UP2" base guide "$T/n2/c/staging" >/dev/null 2>&1 \
  && ok || bad "N2 port.py plan failed"
grep -q 'costs \$N a month' "$T/n2/c/staging/docs/guide/01-quickstart.md" 2>/dev/null \
  && ok || bad "N2 the dollar amount was not redacted to \$N"
out=$(check_c2 "$T/n2/c/staging" "$UP2" 2>&1) && bad "N2 C2 stayed green on a redacted page" || ok
out=$(check_c1 "$T/n2/c/port-manifest.json" 2>&1) && bad "N2 C1 stayed green with the page in .dollars" || ok

echo "docs-guide-port: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
