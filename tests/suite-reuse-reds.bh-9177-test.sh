#!/bin/bash
# tests/suite-reuse-reds.bh-9177-test.sh — bin/suite-reuse.sh plan --reds OUT
# [--rerun-red] (BH-9177, slice C1 of #9063).
#
# The real helper in a committed scratch repo, with SUITE_REUSE_CURL pointed at
# worker.fetch over a file-backed node:sqlite database (the bh-5366 driver), so
# the reds come from the SQL the worker ships. The trust row is set to image.
#
#   H1  a fail row at (repo, a, fp): --reds gets `tests/a.sh<TAB><run_id><TAB>builder`,
#       --run and --reused lack a, summary `ran 2 reused 0 red 1 of 3`
#   H2  the same with --rerun-red: --run keeps a, --reds is empty
#   H3  no --reds flag: --run keeps a, and the summary has no `red` (ci-plan's call)
#   H4  a red at another fingerprint, and a red for a suite not asked: not served
#   H5  an answer with no `reds` field: plan on, --reds empty; `reds: "x"`:
#       `suite-reuse: off (bad ledger answer)`; a red row with a bad run_id: not served
#   H6  every suite reused green: `off (would run nothing)`; every suite red:
#       plan on, --run empty, --reds full
#   H7  a ledger that does not answer: --reds empty, --run = input
#   H8  the C2 reader (BH-9178): the REAL bin/prequeue-ledger.sh over the REAL
#       helper. A fail row for a, an ok row for b, nothing for c: rc 1,
#       --failed is exactly a, `red=1 green=1 unverified=1 ledger=on reds=on
#       reds_bad=0`. A second repo name with ok rows for a, b and c: the helper
#       says `off (would run nothing)`, rc 0, `green=3 red=0 unverified=0`.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
NOW=2026-11-06T00:00:00Z
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

SR="$DIR/bin/suite-reuse.sh"
if ! command -v node > /dev/null 2>&1 || ! node -e "require('node:sqlite')" > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "suite-reuse-reds: SKIPPED — needs node with node:sqlite, and jq"
  echo "suite-reuse-reds: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write > /dev/null 2>&1 \
    || bad "could not generate catalog/lanes.json the worker imports"
fi
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

# ── the scratch checkout ────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/suite-reuse.sh bin/test-impact.sh bin/fast-lints.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/catalog"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
for s in a b c d; do printf '#!/bin/bash\necho %s\n' "$s" > "$R/tests/$s.sh"; done
# fast-lints refuses an empty always set; d is always and never asked about.
printf 'tests/d.sh\n' > "$R/catalog/test-impact-always.txt"
G() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q && G add -A && G commit -qm init || { echo "cannot build the scratch checkout"; exit 1; }
printf '%s\n' tests/a.sh tests/b.sh tests/c.sh > "$T/in"

# ── the stub ledger: worker.fetch over a file-backed node:sqlite D1 ────────
cat > "$T/driver.mjs" <<'EOF'
import { readFileSync, existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const [, , dir, dbfile, method, path, bodyf, cls] = process.argv;
const fresh = !existsSync(dbfile);
const db = new DatabaseSync(dbfile);
if (fresh) db.exec(readFileSync(dir + '/worker/jobs/schema.sql', 'utf8'));
if (method === 'SQL') { db.exec(path); process.exit(0); }
if (method === 'Q') { console.log(JSON.stringify(db.prepare(path).all())); process.exit(0); }
const { d1 } = await import(dir + '/worker/jobs/test/lib/d1-sqlite.bh-1030.js');
const worker = (await import(dir + '/worker/jobs/src/index.js')).default;
const headers = { 'content-type': 'application/json',
  ...(cls === 'ci' ? { 'x-suite-ledger-token': 'tok-fixture' } : { authorization: 'Bearer SECRET-fixture' }) };
const res = await worker.fetch(new Request('https://jobs.test' + path, { method, headers, body: readFileSync(bodyf) }),
  { DB: d1(db), HARNESS_SECRET: 'SECRET-fixture', SUITE_LEDGER_TOKEN: 'tok-fixture' });
process.stdout.write((await res.text()) + '\n' + res.status + '\n');
EOF
# STUB_MODE rewrites the worker's real answer: noreds drops the field, badreds
# makes it a string, badrunid gives every red the run_id `a b`.
cat > "$T/stub.sh" <<EOF
#!/bin/bash
echo "\$1 \$2" >> "$T/calls"
[ "\${STUB_MODE:-}" = exit7 ] && exit 7
out=\$(node "$T/driver.mjs" "$DIR" "\${LEDGER_DB:-$T/ledger.db}" "\$@") || exit \$?
code=\${out##*\$'\n'}; body=\${out%\$'\n'*}
case "\${STUB_MODE:-}:\$2" in
  noreds:/api/suite-results/lookup) body=\$(jq -c 'del(.reds)' <<<"\$body") ;;
  badreds:/api/suite-results/lookup) body=\$(jq -c '.reds = "x"' <<<"\$body") ;;
  badrunid:/api/suite-results/lookup) body=\$(jq -c '.reds |= map(.run_id = "a b")' <<<"\$body") ;;
esac
printf '%s\n%s\n' "\$body" "\$code"
EOF
chmod +x "$T/stub.sh"
sql() { node "$T/driver.mjs" "$DIR" "$LEDGER_DB" SQL "$1" > /dev/null; }
trust_image() { sql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('lib.suite-reuse.suite_reuse_trust','image','t','t','2026-11-06T00:00:00Z')"; }

export SUITE_REUSE_CURL="$T/stub.sh" JOBS_URL=https://jobs.invalid HARNESS_SECRET=SECRET-fixture SUITE_IMAGE_ID=img-h
unset SUITE_LEDGER_URL SUITE_LEDGER_TOKEN SUITE_REUSE GITHUB_ACTIONS STUB_MODE FLY_IMAGE_REF ImageOS ImageVersion

# plan <tag> [extra args...] — outputs $T/<tag>.{run,reused,reds,fp,out}, rc PRC.
plan() {
  local tag="$1"; shift
  ( cd "$R" && "$SR" plan --class builder --repo acme/widget --ctx h --suites "$T/in" \
      --run "$T/$tag.run" --reused "$T/$tag.reused" --fingerprints "$T/$tag.fp" "$@" ) > "$T/$tag.out" 2>&1
  PRC=$?
}
record() { # record <key> <fp file> <rows...> — each row `suite status secs`
  local key="$1" fpf="$2"; shift 2
  printf '%s\n' "$@" | tr ' ' '\t' > "$T/res.$key"
  ( cd "$R" && "$SR" record --repo acme/widget --ctx h --run-key "$key" --fingerprints "$fpf" --results "$T/res.$key" ) > "$T/rec.$key.out" 2>&1
}
lines() { grep -c . "$1" 2>/dev/null || true; }

# ── H1 ──────────────────────────────────────────────────────────────────────
export LEDGER_DB="$T/h1.db"
plan h0; trust_image
record H1RED "$T/h0.fp" "tests/a.sh fail 4"
plan h1 --reds "$T/h1.reds"
[ "$PRC" = 0 ] && ok "H1 plan rc 0" || bad "H1 plan rc $PRC"
[ "$(cat "$T/h1.reds" 2>/dev/null)" = "$(printf 'tests/a.sh\tH1RED\tbuilder')" ] && ok "H1 --reds names a, its run and its class" \
  || bad "H1 --reds: '$(cat "$T/h1.reds" 2>/dev/null)' out: $(cat "$T/h1.out")"
[ "$(cat "$T/h1.run")" = "$(printf 'tests/b.sh\ntests/c.sh')" ] && ok "H1 --run lacks the red suite" || bad "H1 --run: $(cat "$T/h1.run")"
[ ! -s "$T/h1.reused" ] && ok "H1 --reused lacks the red suite" || bad "H1 --reused: $(cat "$T/h1.reused")"
grep -qxF 'suite-reuse: ran 2 reused 0 red 1 of 3 (saved ~0s)' "$T/h1.out" && ok "H1 summary counts the red" \
  || bad "H1 summary: $(grep 'suite-reuse: ran' "$T/h1.out")"
grep -qxF 'suite-reuse: red tests/a.sh from H1RED' "$T/h1.out" && ok "H1 one red line per served red" || bad "H1 red line: $(cat "$T/h1.out")"

# ── H2 ──────────────────────────────────────────────────────────────────────
plan h2 --reds "$T/h2.reds" --rerun-red
{ [ "$PRC" = 0 ] && [ -f "$T/h2.reds" ] && [ ! -s "$T/h2.reds" ] && cmp -s "$T/h2.run" "$T/in"; } \
  && ok "H2 --rerun-red: a runs, --reds empty" || bad "H2 rc=$PRC run=$(cat "$T/h2.run") reds=$(cat "$T/h2.reds" 2>/dev/null)"
grep -qxF 'suite-reuse: ran 3 reused 0 red 0 of 3 (saved ~0s)' "$T/h2.out" && ok "H2 summary: red 0" || bad "H2 out: $(cat "$T/h2.out")"

# ── H3 ──────────────────────────────────────────────────────────────────────
plan h3
cmp -s "$T/h3.run" "$T/in" && ok "H3 no --reds: a stays in --run" || bad "H3 --run: $(cat "$T/h3.run") out: $(cat "$T/h3.out")"
grep -q ' red ' "$T/h3.out" && bad "H3 the ci-plan call's lines changed: $(cat "$T/h3.out")" || ok "H3 no red in the summary or any line"

# ── H4 ──────────────────────────────────────────────────────────────────────
export LEDGER_DB="$T/h4.db"
plan h4a; trust_image
# a fail for b at a fingerprint one hex char off ours, and one for tests/z.sh.
FPB=$(awk -F'\t' '$1 == "tests/b.sh" { print $2 }' "$T/h4a.fp")
OFF="${FPB:0:63}$( [ "${FPB:63:1}" = 0 ] && echo 1 || echo 0 )"
printf 'tests/b.sh\t%s\t-\ntests/z.sh\t%s\t-\n' "$OFF" "$FPB" > "$T/h4.fakefp"
record H4X "$T/h4.fakefp" "tests/b.sh fail 1" "tests/z.sh fail 1"
plan h4 --reds "$T/h4.reds"
{ [ ! -s "$T/h4.reds" ] && cmp -s "$T/h4.run" "$T/in"; } && ok "H4 a red at another fingerprint or for a suite not asked is not served" \
  || bad "H4 reds: $(cat "$T/h4.reds") run: $(cat "$T/h4.run")"

# ── H5 ──────────────────────────────────────────────────────────────────────
export LEDGER_DB="$T/h1.db"
STUB_MODE=noreds plan h5a --reds "$T/h5a.reds"
{ [ "$PRC" = 0 ] && [ ! -s "$T/h5a.reds" ] && cmp -s "$T/h5a.run" "$T/in" && ! grep -q 'suite-reuse: off' "$T/h5a.out"; } \
  && ok "H5 an answer with no reds field: plan on, no reds" || bad "H5a out: $(cat "$T/h5a.out") reds: $(cat "$T/h5a.reds")"
STUB_MODE=badreds plan h5b --reds "$T/h5b.reds"
{ grep -qxF 'suite-reuse: off (bad ledger answer)' "$T/h5b.out" && [ ! -s "$T/h5b.reds" ] && cmp -s "$T/h5b.run" "$T/in"; } \
  && ok "H5 reds not an array: off (bad ledger answer)" || bad "H5b out: $(cat "$T/h5b.out")"
STUB_MODE=badrunid plan h5c --reds "$T/h5c.reds"
{ [ ! -s "$T/h5c.reds" ] && cmp -s "$T/h5c.run" "$T/in"; } && ok "H5 a red with a bad run_id is not served" \
  || bad "H5c reds: $(cat "$T/h5c.reds") out: $(cat "$T/h5c.out")"

# ── H6 ──────────────────────────────────────────────────────────────────────
export LEDGER_DB="$T/h6.db"
plan h6a; trust_image
record H6OK "$T/h6a.fp" "tests/a.sh ok 2" "tests/b.sh ok 2" "tests/c.sh ok 2"
plan h6g --reds "$T/h6g.reds"
{ grep -qxF 'suite-reuse: off (would run nothing)' "$T/h6g.out" && cmp -s "$T/h6g.run" "$T/in" && [ ! -s "$T/h6g.reused" ]; } \
  && ok "H6 every suite green: off (would run nothing)" || bad "H6g out: $(cat "$T/h6g.out")"
export LEDGER_DB="$T/h6r.db"
plan h6b; trust_image
record H6RED "$T/h6b.fp" "tests/a.sh fail 2" "tests/b.sh fail 2" "tests/c.sh fail 2"
plan h6r --reds "$T/h6r.reds"
{ [ "$PRC" = 0 ] && [ ! -s "$T/h6r.run" ] && [ "$(lines "$T/h6r.reds")" = 3 ] && ! grep -q 'suite-reuse: off' "$T/h6r.out"; } \
  && ok "H6 every suite red: plan on, --run empty, --reds full" || bad "H6r out: $(cat "$T/h6r.out") run: $(cat "$T/h6r.run") reds: $(cat "$T/h6r.reds")"

# ── H7 ──────────────────────────────────────────────────────────────────────
STUB_MODE=exit7 plan h7 --reds "$T/h7.reds"
{ [ "$PRC" = 0 ] && [ -f "$T/h7.reds" ] && [ ! -s "$T/h7.reds" ] && cmp -s "$T/h7.run" "$T/in" \
  && grep -qxF 'suite-reuse: off (ledger unreachable)' "$T/h7.out"; } \
  && ok "H7 a ledger that does not answer: --reds empty, --run = input" || bad "H7 rc=$PRC out: $(cat "$T/h7.out")"

# ── H8 ──────────────────────────────────────────────────────────────────────
# bin/prequeue-ledger.sh (C2) reads the helper's --reds file: column 1 is the
# suite. Its plan runner is a stub gate that writes the list (the bh-9178 shape).
R8="$T/repo8"
mkdir -p "$R8"
for s in bin/suite-reuse.sh bin/prequeue-ledger.sh bin/test-impact.sh bin/fast-lints.sh; do
  scratch_install_closure "$s" "$R8" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R8/tests/lib" "$R8/catalog"
printf '# scratch lib\n' > "$R8/tests/lib/scratch.sh"
for s in a b c d; do printf '#!/bin/bash\necho %s\n' "$s" > "$R8/tests/$s.sh"; done
printf 'tests/d.sh\n' > "$R8/catalog/test-impact-always.txt"
cat > "$R8/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in --list) l=$2; shift ;; esac; shift; done
[ -n "${l:-}" ] && printf '%s\n' tests/a.sh tests/b.sh tests/c.sh > "$l"
exit 0
SH
chmod +x "$R8/bin/test-impact-gate.sh"
G8() { GIT_COMMITTER_DATE="$NOW" GIT_AUTHOR_DATE="$NOW" git -C "$R8" -c user.email=t@t -c user.name=t "$@"; }
G8 init -q && G8 add -A && G8 commit -qm init || { echo "cannot build the H8 checkout"; exit 1; }
B8=$(G8 rev-parse HEAD)
export LEDGER_DB="$T/h8.db"
( cd "$R8" && "$SR" plan --class builder --repo acme/h8 --ctx local --suites "$T/in" --rev HEAD \
    --run "$T/h8fp.run" --reused "$T/h8fp.reused" --fingerprints "$T/h8.fp" ) > "$T/h8fp.out" 2>&1
trust_image
rec8() { # rec8 <repo> <key> <rows...>
  local repo="$1" key="$2"; shift 2
  printf '%s\n' "$@" | tr ' ' '\t' > "$T/res8.$key"
  ( cd "$R8" && "$SR" record --repo "$repo" --ctx local --run-key "$key" --fingerprints "$T/h8.fp" --results "$T/res8.$key" ) \
    > "$T/rec8.$key.out" 2>&1
}
pq8() { # pq8 <tag> <repo>
  ( cd "$R8" && SUITE_REUSE_CLASS=builder SUITE_REUSE_REPO="$2" bash bin/prequeue-ledger.sh --base "$B8" --head HEAD \
      --failed "$T/$1.failed" --summary "$T/$1.sum" ) > "$T/$1.out" 2>&1
  PRC=$?
}
rec8 acme/h8 H8RED "tests/a.sh fail 3"
rec8 acme/h8 H8OK "tests/b.sh ok 3"
pq8 h8a acme/h8
{ [ "$PRC" = 1 ] && [ "$(cat "$T/h8a.failed")" = tests/a.sh ] \
  && grep -qF 'green=1 red=1 unverified=1 ledger=on reds=on reds_bad=0' "$T/h8a.sum"; } \
  && ok "H8 prequeue-ledger reads the helper's reds: rc 1, --failed a, red=1 green=1 unverified=1" \
  || bad "H8a rc=$PRC failed=$(cat "$T/h8a.failed" 2>/dev/null) sum=$(cat "$T/h8a.sum" 2>/dev/null) out: $(cat "$T/h8a.out")"
rec8 acme/h8b H8ALL "tests/a.sh ok 3" "tests/b.sh ok 3" "tests/c.sh ok 3"
pq8 h8b acme/h8b
{ [ "$PRC" = 0 ] && grep -qxF 'suite-reuse: off (would run nothing)' "$T/h8b.out" \
  && grep -qF 'green=3 red=0 unverified=0' "$T/h8b.sum" && [ ! -s "$T/h8b.failed" ]; } \
  && ok "H8 every suite green: helper off (would run nothing), prequeue-ledger rc 0, green=3" \
  || bad "H8b rc=$PRC sum=$(cat "$T/h8b.sum" 2>/dev/null) out: $(cat "$T/h8b.out")"

echo "suite-reuse-reds: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
