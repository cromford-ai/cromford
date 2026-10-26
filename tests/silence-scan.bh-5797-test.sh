#!/bin/bash
# tests/silence-scan.bh-5797-test.sh — BH-5797 scope 3: the silence check's
# scanner, bin/lib/silence-scan.sh ss_scan over catalog/silence-markers.tsv. A
# diff that widens a public-leak allow-list (a KNOWN_FAKE_* entry in bin/share,
# a gitleaks marker) is a human hit; any other allow-list line or marker is a
# lead hit. A marker with no reason on its line fails the builder verify step
# (bin/marker-reason-lint.sh). The worklist gate that acts on the hits
# (bin/lib/lead-gates.d/30-silence.sh) has its own suites:
# tests/lead-gates-silence.bh-5875-test.sh and
# tests/lead-gates-silence-ports.bh-8362-test.sh.
#
#   S1  an added scratch-closure marker line is a hit
#   S2  an added KNOWN_FAKE_IDENTIFIERS entry (bin/share, hunk inside the set)
#       is a hit (ticket acceptance test 2)
#   S2c the real bin/share/mapping.py with a -U3 patch: an entry just under
#       the KNOWN_FAKE_SECRETS or KNOWN_FAKE_CREDENTIALS opener is a human hit
#       although the @@ header names an earlier definition; a string inside a
#       def is no hit (lead review lr-5811)
#   S3  an added line in an allow-list or baseline file is a hit, and a file
#       GitHub shows no patch for is a hit too
#   S4  the negative list: a removed marker line, a context line, a path with
#       "allow" inside a word, a suite named *-allowlist-test.sh, and the
#       pattern file itself are no hit; an unparseable compare is rc 2, and
#       one with no files list is rc 1 (GitHub showed no file)
#   S1-S4 also check each hit's route (human or lead): a KNOWN_FAKE_* entry,
#       a gitleaks marker, a leak or identifier allow-list and the gitleaks
#       ignore file are human; other ratchet baselines and markers are lead
#   R1  bin/marker-reason-lint.sh: a bare added determinism marker is rc 1 and
#       named; one with a reason, one in a .md file and a removed one are rc 0
#   R2  the rules pack carries the marker-reason component
# Marker text is built from pieces so this suite's own lines are no hit.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/silence-scan.bh-5797-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "silence-scan: jq is required"; exit 2; }

LIB="$DIR/bin/lib/silence-scan.sh"
CAT="$DIR/catalog/silence-markers.tsv"
SCA="scratch-closure-""allow"; DOK="determinism: ""ok"; KFI="KNOWN_FAKE_""IDENTIFIERS"

# cmp <out> <files-json> — a compare answer with one commit and these files
cmp() { jq -nc --argjson f "$2" '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat"}}], files:$f}' > "$1"; }
# file <path> <patch> — one compare file entry
file() { jq -nc --arg p "$1" --arg d "$2" '{filename:$p, status:"modified", patch:$d}'; }
scan() { ( . "$LIB" && ss_scan "$1" "$CAT" ); }

[ -r "$LIB" ] && bash -n "$LIB" && ok || bad "bin/lib/silence-scan.sh is missing or does not parse"
[ -r "$CAT" ] && ok || bad "catalog/silence-markers.tsv is missing"

# ── S1 ──────────────────────────────────────────────────────────────────────
cmp "$T/s1.json" "[$(file tests/x-test.sh $'@@ -1,2 +1,3 @@\n #!/bin/bash\n+cp a b  # '"$SCA"$': one lib\n echo')]"
out=$(scan "$T/s1.json"); rc=$?
[ "$rc" = 0 ] && grep -q $'^lead\ttests/x-test.sh' <<<"$out" && ok || bad "S1 a scratch-closure marker is no hit (rc $rc): $out"
cmp "$T/s1b.json" "[$(file tests/y-test.sh $'@@ -1,2 +1,3 @@\n x\n+sleep 0.2 # '"$DOK"$' bounded wait\n y')]"
out=$(scan "$T/s1b.json"); rc=$?
[ "$rc" = 0 ] && ok || bad "S1 a determinism marker is no hit (rc $rc): $out"

# ── S2 (acceptance test 2) ──────────────────────────────────────────────────
cmp "$T/s2.json" "[$(file bin/share/mapping.py $'@@ -540,6 +540,7 @@ '"$KFI"$' = {\n     "acme-demo",\n+    "demo-client-x",\n     "zz-fixture",')]"
out=$(scan "$T/s2.json"); rc=$?
[ "$rc" = 0 ] && grep -q $'^human\tbin/share/mapping.py: .*demo-client-x' <<<"$out" && ok || bad "S2 a $KFI entry is no hit (rc $rc): $out"
cmp "$T/s2b.json" "[$(file bin/share/mapping.py $'@@ -10,6 +10,7 @@ def map_paths():\n     a = 1\n+    "just-a-string",\n     b = 2')]"
out=$(scan "$T/s2b.json"); rc=$?
[ "$rc" = 1 ] && ok || bad "S2 a string line outside the known-fakes set is a hit (rc $rc): $out"

# S2c (lead review lr-5811): the real bin/share/mapping.py, an entry added just
# under a set opener. GitHub's -U3 patch puts an EARLIER definition in the @@
# header there (FIXTURE_MARKERS, def project_for_env_prefix), so the set name
# must come from the context line that opens it.
realpatch() { # realpatch <after-line-regex> <entry> <out> — a compare from git diff -U3
  local m="$T/mapping.mod.py"
  awk -v re="$1" -v e="$2" '{ print } !d && $0 ~ re { print e; d = 1 }' "$DIR/bin/share/mapping.py" > "$m"
  git diff --no-index -U3 "$DIR/bin/share/mapping.py" "$m" | awk '/^@@/{f=1} f' > "$T/real.patch"
  cmp "$3" "[$(jq -nc --rawfile d "$T/real.patch" '{filename:"bin/share/mapping.py", status:"modified", patch:($d | rtrimstr("\n"))}')]"
}
realpatch '^KNOWN_FAKE_SECRETS = [{]' '    "demo-secret-fixture-1",' "$T/s2c.json"
grep -q '^@@ .*FIXTURE_MARKERS' "$T/real.patch" && ok || bad "S2c precondition: the -U3 header is not the earlier FIXTURE_MARKERS line: $(head -1 "$T/real.patch")"
grep -q $'^human\tbin/share/mapping.py: .*demo-secret-fixture-1' <<<"$(scan "$T/s2c.json")" \
  && ok || bad "S2c an entry under KNOWN_FAKE_SECRETS is no human hit: $(scan "$T/s2c.json")"
realpatch '^KNOWN_FAKE_CREDENTIALS = [{]' '    "demo-cred-fixture-2",' "$T/s2d.json"
grep -q '^@@ .*def project_for_env_prefix' "$T/real.patch" && ok || bad "S2c precondition: the -U3 header is not def project_for_env_prefix: $(head -1 "$T/real.patch")"
grep -q $'^human\tbin/share/mapping.py: .*demo-cred-fixture-2' <<<"$(scan "$T/s2d.json")" \
  && ok || bad "S2c an entry under KNOWN_FAKE_CREDENTIALS is no human hit: $(scan "$T/s2d.json")"
realpatch '^def project_for_env_prefix' '    "just-a-string-in-a-def",' "$T/s2e.json"
[ "$(scan "$T/s2e.json" >/dev/null; echo $?)" = 1 ] && ok || bad "S2c a string line inside a def is a hit: $(scan "$T/s2e.json")"

# ── S3 ──────────────────────────────────────────────────────────────────────
cmp "$T/s3.json" "[$(file tests/raw-claude-allowlist.txt $'@@ -3,2 +3,3 @@\n bin/a.sh\n+bin/new.sh\n bin/b.sh')]"
out=$(scan "$T/s3.json"); rc=$?
[ "$rc" = 0 ] && grep -q $'^lead\ttests/raw-claude-allowlist.txt' <<<"$out" && ok || bad "S3 an allow-list line is no hit (rc $rc): $out"
cmp "$T/s3b.json" "[$(file tests/gh-app-ratchet-baseline/new.sh.txt $'@@ -0,0 +1 @@\n+3')]"
[ "$(scan "$T/s3b.json" >/dev/null; echo $?)" = 0 ] && ok || bad "S3 a ratchet baseline line is no hit"
jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat"}}], files:[{filename:"tests/llm-call-ratchet-allowlist.txt", status:"modified"}]}' > "$T/s3c.json"
out=$(scan "$T/s3c.json"); rc=$?
[ "$rc" = 0 ] && grep -q 'patch not shown' <<<"$out" && ok || bad "S3 an allow-list file with no patch is no hit (rc $rc): $out"

# S3 by route: a leak or identifier list and the gitleaks ignore file are
# human; a ratchet baseline that only names a gitleaks file is lead.
cmp "$T/s3d.json" "[$(file tests/leak-allowlist.txt $'@@ -1 +1,2 @@\n a\n+b')]"
grep -q $'^human\ttests/leak-allowlist.txt' <<<"$(scan "$T/s3d.json")" && ok || bad "S3 a leak allow-list line is not a human hit: $(scan "$T/s3d.json")"
cmp "$T/s3e.json" "[$(file .gitleaksignore $'@@ -1 +1,2 @@\n a\n+abc:1')]"
grep -q $'^human\t.gitleaksignore' <<<"$(scan "$T/s3e.json")" && ok || bad "S3 a .gitleaksignore line is not a human hit: $(scan "$T/s3e.json")"
cmp "$T/s3f.json" "[$(file tests/fixtures/root-fallback-baseline/bin__lib__gitleaks-pin.sh.count.txt $'@@ -1 +1 @@\n-1\n+2')]"
grep -q $'^lead\ttests/fixtures/root-fallback-baseline/' <<<"$(scan "$T/s3f.json")" && ok || bad "S3 a ratchet baseline is not a lead hit: $(scan "$T/s3f.json")"

# ── S4: the negative list ───────────────────────────────────────────────────
cmp "$T/s4.json" "[$(file tests/x-test.sh $'@@ -1,3 +1,2 @@\n x\n-cp a b # '"$SCA"$': gone\n  # '"$DOK"$' context only'),
  $(file bin/allowance.sh $'@@ -1 +1,2 @@\n x\n+y=1'),
  $(file tests/egress-allowlist-test.sh $'@@ -1 +1,2 @@\n x\n+bad "nope"'),
  $(file catalog/silence-markers.tsv "$(sed 's/^/+/' "$CAT" | sed '1s/^/@@ -0,0 +1,99 @@\n/')")]"
out=$(scan "$T/s4.json"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "S4 the negative list hit (rc $rc): $out"
echo 'not json' > "$T/s4b.json"
[ "$(scan "$T/s4b.json" >/dev/null 2>&1; echo $?)" = 2 ] && ok || bad "S4 an unparseable compare is not rc 2"
echo '{"total_commits":1,"commits":[]}' > "$T/s4c.json"
[ "$(scan "$T/s4c.json" >/dev/null 2>&1; echo $?)" = 1 ] && ok || bad "S4 a compare with no files list is not rc 1 (nothing shown, nothing to scan)"

# ── R1/R2: bin/marker-reason-lint.sh ────────────────────────────────────────
R="$T/r"; mkdir -p "$R/catalog" "$R/tests" "$R/docs"; cp "$CAT" "$R/catalog/"
( cd "$R" && git init -q -b main && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false
  printf '#!/bin/bash\nsleep 1 # %s gone later\n' "$DOK" > tests/old-test.sh
  git add -A && git commit -qm base && git checkout -qb ticket/x ) >/dev/null 2>&1
lint() { "$DIR/bin/marker-reason-lint.sh" --base main "$R" > "$T/lint.out" 2>"$T/lint.err"; echo $?; }
( cd "$R" && printf '#!/bin/bash\nsleep 0.2 # %s\n' "$DOK" > tests/bare-test.sh && git add -A && git commit -qm bare ) >/dev/null 2>&1
[ "$(lint)" = 1 ] && grep -q 'tests/bare-test.sh: a determinism lint marker with no reason' "$T/lint.out" && ok \
  || bad "R1 a bare marker is not a finding: $(cat "$T/lint.out" "$T/lint.err")"
( cd "$R" && printf '#!/bin/bash\nsleep 0.2 # %s — a bounded wait for the child\n' "$DOK" > tests/bare-test.sh \
  && printf 'Write `# %s` with a reason.\n' "$DOK" > docs/x.md && : > tests/old-test.sh && git add -A && git commit -qm reason ) >/dev/null 2>&1
[ "$(lint)" = 0 ] && ok || bad "R1 a marker with a reason, one in a .md file or a removed one is a finding: $(cat "$T/lint.out")"
awk -F'\t' '$1 == "marker-reason" && $2 == "delta" && $4 == "bin/marker-reason-lint.sh --base <fork> ." {f = 1} END {exit !f}' "$DIR/catalog/rules-pack.tsv" \
  && ok || bad "R2 the rules pack has no marker-reason component"

echo "silence-scan.bh-5797: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
