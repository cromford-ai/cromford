#!/bin/bash
# tests/compose-test-catalogs.bh-9268-test.sh — the worker suites compose the
# catalogs they import before they run (BH-9268).
#
# catalog/lanes.json, catalog/llm-sites.json and catalog/context-budgets.json
# are git-ignored renders that worker/jobs imports at a fixed path. A fresh
# clone (the public copy) has none, so `npm test` failed on load there.
# bin/compose-test-catalogs.sh, the `pretest` of worker/jobs and
# worker/otp-inbox, composes them into a temp folder and moves each into
# catalog/ only when it changed. A failed builder writes nothing.
#
# Sources under test: "$DIR/bin/compose-test-catalogs.sh" "$DIR/worker/jobs/package.json" "$DIR/worker/otp-inbox/package.json"
#
# Run from anywhere: tests/compose-test-catalogs.bh-9268-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
CATS="lanes.json llm-sites.json context-budgets.json"

# C0: the builder under test exists and parses
if bash -n "$DIR/bin/compose-test-catalogs.sh" 2>/dev/null; then ok; else
  bad "C0 $DIR/bin/compose-test-catalogs.sh is missing or does not parse"
fi

# fresh <dir> — a scratch repo with the builders and the catalog sources, and
# none of the three composed files (what a fresh clone has)
fresh() {
  mkdir -p "$1"
  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    (cd "$DIR" && git ls-files -co --exclude-standard -z -- bin catalog cron fleet.conf \
       worker/jobs/package.json worker/otp-inbox/package.json | tar --null -T - -c) | tar -x -C "$1"
  else
    (cd "$DIR" && tar -c bin catalog cron fleet.conf worker/jobs/package.json worker/otp-inbox/package.json) \
      | tar -x -C "$1"
  fi
  for f in $CATS; do rm -f "$1/catalog/$f"; done
}

# C1: from nothing, the pretest (as npm runs it) composes all three, and each parses
fresh "$T/r1"
if (cd "$T/r1/worker/jobs" && npm run --silent pretest) >"$T/c1.out" 2>&1; then ok; else
  bad "C1 npm run pretest in worker/jobs failed: $(tail -5 "$T/c1.out")"
fi
for f in $CATS; do
  if [ -s "$T/r1/catalog/$f" ] && jq -e . "$T/r1/catalog/$f" >/dev/null 2>&1; then ok; else
    bad "C1 catalog/$f missing or not JSON after the pretest"
  fi
done

# C2: the worker loads the composed lane catalog by its fixed import path
if (cd "$T/r1" && node -e "import('./catalog/lanes.json',{with:{type:'json'}}).then(m=>{if(!m.default)process.exit(3)})") 2>"$T/c2.err"; then ok; else
  bad "C2 node could not import catalog/lanes.json: $(head -3 "$T/c2.err")"
fi

# C3: a second run with no change rewrites nothing (mtimes and inodes stay)
before=$(for f in $CATS; do stat -c '%i %Y' "$T/r1/catalog/$f"; done)
sleep 1
bash "$T/r1/bin/compose-test-catalogs.sh" >/dev/null 2>&1; rc=$?
after=$(for f in $CATS; do stat -c '%i %Y' "$T/r1/catalog/$f"; done)
[ "$rc" = 0 ] && [ "$before" = "$after" ] && ok || bad "C3 an unchanged run rewrote a catalog (rc=$rc)"

# C4: a changed (stale) catalog is replaced
printf '[]\n' > "$T/r1/catalog/llm-sites.json"
bash "$T/r1/bin/compose-test-catalogs.sh" >/dev/null 2>&1
cmp -s "$T/r1/catalog/llm-sites.json" <(printf '[]\n') && bad "C4 a stale catalog was not replaced" || ok

# C5-C7: a failing builder -> rc 1, the builder named, NO catalog file written
i=4
for b in lanes-build llm-sites-build context-budgets-build; do
  i=$((i+1))
  fresh "$T/f$i"
  printf '#!/bin/bash\nexit 1\n' > "$T/f$i/bin/$b.sh"
  out=$(bash "$T/f$i/bin/compose-test-catalogs.sh" 2>&1); rc=$?
  left=$(cd "$T/f$i/catalog" && ls -A $CATS .*.json.* 2>/dev/null)
  if [ "$rc" = 1 ] && grep -q "bin/$b.sh failed" <<<"$out" && [ -z "$left" ]; then ok; else
    bad "C$i failing $b: rc=$rc out='$out' left='$left'"
  fi
done

# C8: both worker suites run it as their pretest
for p in worker/jobs worker/otp-inbox; do
  s=$(jq -r '.scripts.pretest // ""' "$DIR/$p/package.json")
  [ "$s" = "bash ../../bin/compose-test-catalogs.sh" ] && ok || bad "C8 $p pretest is '$s'"
done

echo "compose-test-catalogs.bh-9268-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
