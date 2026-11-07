#!/bin/bash
# tests/patch-same-semantic.bh-9154-test.sh — the lockfile and whitespace rungs
# of bin/lib/patch-same.sh (patch_same_semantic, reached through
# patch_same_review) against REAL git histories.
#
# Every case builds a reviewed head R (one commit off main) and a new head H:
# main moves on a far file, and H is a fresh commit off the new main carrying
# R's change plus the case's variant. R is not an ancestor of H, as after a
# rebase.
#
#   LOCKFILE (default knobs unless named). The lockfile rung passes only a
#   change that keeps the install set: the same packages, versions, resolved
#   URLs and integrity, every resolved host in PATCH_SAME_LOCK_HOSTS. The
#   commit author is never the permission.
#     L1  lockfile metadata-only (reorder, top-level name)  -> lockfile rc 0
#     L2  lockfile + package.json version bump              -> rc 1
#     L3  lockfile metadata-only, any author                -> lockfile rc 0
#     L4  lockfile at the crafted path `x b/package-lock.json` -> rc 1
#     L5  lockfile + one code line                          -> rc 1
#     L6  sub/package-lock.json, sub/package.json equal     -> lockfile rc 0
#     L6b sub/package-lock.json + sub/package.json changed  -> rc 1
#     L2b package.json bump in both, a lockfile change in H, but main moved
#         package.json so the two manifest diffs are not byte-equal -> rc 1
#     L7  lockfile deleted                                  -> rc 1
#     L7b R deleted the lockfile, H modifies it             -> rc 1
#     L7c lockfile changed and made 755                     -> rc 1
#     L7d a lockfile ADDED on H only                        -> rc 1
#     L7e a lockfile added on both R and H                  -> rc 1
#     L8  PATCH_SAME_LOCKFILES empty                        -> rc 1
#     L11 one resolved URL moved to another host, same integrity -> rc 1
#     L11b one resolved URL moved on the same host          -> rc 1
#     L12 one integrity hash changed                        -> rc 1
#     L13 one package version changed                       -> rc 1
#     L14 a package added                                   -> rc 1
#     L15 a package removed                                 -> rc 1
#     L16 both heads resolve off the host allow-list        -> rc 1
#     L16b L16 with that host in PATCH_SAME_LOCK_HOSTS      -> lockfile rc 0
#     L17 a v1 nested dependency's resolved changed         -> rc 1
#     L18 the lockfile is not JSON                          -> rc 1
#     L19 yarn.lock named in PATCH_SAME_LOCKFILES (no parser) -> rc 1
#   WHITESPACE:
#     W1  trailing spaces removed on a .sh line             -> whitespace rc 0
#     W2  trailing space after a `\` continuation           -> rc 1
#     W3  .py indentation                                   -> rc 1
#     W3b .py trailing space (a significant file)           -> rc 1
#     W4  .yml trailing space                               -> rc 1
#     W5  a blank line added                                -> rc 1
#     W6  CRLF -> LF in .js                                 -> whitespace rc 0
#     W7  trailing space + mode 644 -> 755                  -> rc 1
#     W7b trailing space + a mode change on another file    -> rc 1
#     W7c W7b on a git whose patch-id skips a chunk with no hunk (a mode-only
#         change): the header compare still refuses         -> rc 1
#     W8  PATCH_SAME_WS_SIGNIFICANT names .sh               -> W1 is rc 1
#     W9  LF -> CRLF in .sh (a CR added)                    -> rc 1
#   BYTES:  patch_same (the byte callers) stays rc 1 on L1 and W1.
#   STUB:   a git that fails                                -> rc 1
#   KNOBS:  catalog/lanes.d/_lib.patch-same.json defaults equal the code fallbacks.
# Run from anywhere: tests/patch-same-semantic.bh-9154-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
. "$DIR/bin/lib/patch-same.sh" || { echo "FAIL: cannot source bin/lib/patch-same.sh"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PATCH_SAME_LOCKFILES PATCH_SAME_LOCK_HOSTS PATCH_SAME_WS_SIGNIFICANT
G="$T/repo"
g() { git -C "$G" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$G/f.sh" && rm -f "$G/f.sh.bak"; }

# lockjson [<left-pad version> <resolved> <integrity> [<extra packages entry>]] — a v3 package-lock.json.
RES=https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz
lockjson() {
  printf '{"lockfileVersion": 3, "packages": {"": {"name": "a"}, "node_modules/left-pad": {"version": "%s", "resolved": "%s", "integrity": "%s"}%s}}' \
    "${1:-1.3.0}" "${2:-$RES}" "${3:-sha512-AAAA}" "${4:-}"
}
seed() {
  scratch_rm "$G" 2>/dev/null; mkdir -p "$G/sub" "$G/x b"
  g init -q -b main
  seq 1 30 | sed 's/^/line /' > "$G/f.sh"
  printf 'other\n' > "$G/o.txt"
  printf '{\n"name": "a",\n"a": 1,\n"b": 2,\n"c": 3,\n"d": 4,\n"e": 5,\n"version": "1.0.0"\n}\n' > "$G/package.json"
  printf '%s\n' "$(lockjson)" > "$G/package-lock.json"
  printf '{"name": "s", "version": "1.0.0"}\n' > "$G/sub/package.json"
  printf '{"lockfileVersion": 3}\n' > "$G/sub/package-lock.json"
  printf '{"name": "x", "version": "1.0.0"}\n' > "$G/x b/package.json"
  printf '{"lockfileVersion": 3}\n' > "$G/x b/package-lock.json"
  printf 'a@1:\n  version 1\n' > "$G/yarn.lock"
  printf 'def f(x):\n    return x\n' > "$G/a.py"
  printf 'jobs:\n  a:\n    run: x\n' > "$G/c.yml"
  printf 'var a = 1;\n' > "$G/a.js"
  g add -A; g commit -qm base
}
# pair <R-setup> <H-setup> [<H author email>] [<main-move cmd>] — sets R and H.
pair() {
  seed
  g checkout -qb pr; eval "$1"; g add -A; g commit -qm pr-change; R=$(g rev-parse HEAD)
  g checkout -q main; printf 'main moved\n' >> "$G/o.txt"; eval "${4:-:}"; g add -A; g commit -qm main-moved
  g checkout -qb pr2 main; eval "$2"; g add -A
  GIT_AUTHOR_EMAIL="${3:-bot@example.invalid}" g commit -qm pr-change; H=$(g rev-parse HEAD)
}
CODE="edit 10 'line 10 CHANGED BY PR'"
# LOCK: the same install set, entries reordered and a top-level name added.
LOCK='printf "{\"name\": \"a\", \"packages\": {\"node_modules/left-pad\": {\"integrity\": \"sha512-AAAA\", \"resolved\": \"$RES\", \"version\": \"1.3.0\", \"license\": \"WTFPL\"}, \"\": {\"name\": \"a\"}}, \"lockfileVersion\": 3}\n" > "$G/package-lock.json"'
# lockto <args for lockjson> — H writes that lockfile.
lockto() { printf '%s\n' "$(lockjson "$@")" > "$G/package-lock.json"; }
want() { # want <case> <how> [env assignments...] — patch_same_review prints <how>, rc 0
  local c="$1" w="$2" out rc; shift 2
  out=$(env "$@" bash -c '. "$1"; patch_same_review "$2" main "$3" "$4"' _ "$DIR/bin/lib/patch-same.sh" "$G" "$R" "$H"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "$w" ] && ok || bad "$c patch_same_review: rc=$rc out='$out', want $w rc 0"
}
want_diff() { # want_diff <case> [env assignments...] — rc 1, nothing printed
  local c="$1" out rc; shift
  out=$(env "$@" bash -c '. "$1"; patch_same_review "$2" main "$3" "$4"' _ "$DIR/bin/lib/patch-same.sh" "$G" "$R" "$H"); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "$c patch_same_review: rc=$rc out='$out', want rc 1"
}
A=PATCH_SAME_LOCK_HOSTS=registry.npmjs.org

# ---- L1: lockfile-only, harness author
pair "$CODE" "$CODE; $LOCK"
want L1 lockfile "$A"
out=$(patch_same_semantic "$G" main "$R" "$H"); rc=$?
[ "$rc" = 0 ] && [ "$out" = lockfile ] && ok || bad "L1 patch_same_semantic: rc=$rc out='$out'"
patch_same "$G" main "$R" "$H" >/dev/null && bad "BYTES L1: byte patch_same must stay rc 1 on a lockfile change" || ok

# ---- L2: lockfile + package.json version bump
pair "$CODE" "$CODE; $LOCK; printf '{\"name\": \"a\", \"version\": \"1.0.1\"}\n' > \"\$G/package.json\""
want_diff L2 "$A"

# ---- L2b: the same manifest bump on both sides, but main inserted a line at
# the top of package.json, so the hunk headers differ (patch-id equal, bytes not)
BUMP='sed -i.bak "s/1.0.0/1.0.1/" "$G/package.json" && rm -f "$G/package.json.bak"'
pair "$CODE; $BUMP" "$CODE; $BUMP; $LOCK" "" 'sed -i.bak "1a\\
\"z\": 0," "$G/package.json" && rm -f "$G/package.json.bak"'
want_diff L2b "$A"

# ---- L3: lockfile metadata-only, an author no list names: the content decides
pair "$CODE" "$CODE; $LOCK" someone@example.invalid
want L3 lockfile "$A"

# ---- L4: a lockfile at a crafted path whose name holds ` b/`
pair "$CODE" "$CODE; printf '{\"lockfileVersion\": 3, \"x\": 1}\n' > \"\$G/x b/package-lock.json\""
want_diff L4 "$A"

# ---- L5: lockfile + one code line
pair "$CODE" "$CODE; $LOCK; edit 20 'line 20 ALSO'"
want_diff L5 "$A"

# ---- L6: nested lockfile, nested package.json equal (unchanged in both)
pair "$CODE" "$CODE; printf '{\"lockfileVersion\": 3, \"y\": 2}\n' > \"\$G/sub/package-lock.json\""
want L6 lockfile "$A"

# ---- L6b: nested lockfile + nested package.json changed
pair "$CODE" "$CODE; printf '{\"lockfileVersion\": 3, \"y\": 2}\n' > \"\$G/sub/package-lock.json\"; printf '{\"name\": \"s\", \"version\": \"2.0.0\"}\n' > \"\$G/sub/package.json\""
want_diff L6b "$A"

# ---- L7: lockfile deleted
pair "$CODE" "$CODE; rm -f \"\$G/package-lock.json\""
want_diff L7 "$A"

# ---- L7b: R deleted the lockfile, H modifies it instead
pair "$CODE; rm -f \"\$G/package-lock.json\"" "$CODE; $LOCK"
want_diff L7b "$A"

# ---- L7c: lockfile changed and its mode moved to 755
pair "$CODE" "$CODE; $LOCK; chmod 755 \"\$G/package-lock.json\""
want_diff L7c "$A"

# ---- L7d: a lockfile added on H only (its install set is new code)
NEWLOCK='mkdir -p "$G/n"; printf "{\"name\": \"n\"}\n" > "$G/n/package.json"; printf "%s\n" "$(lockjson)" > "$G/n/package-lock.json"'
pair "$CODE; mkdir -p \"\$G/n\"; printf '{\"name\": \"n\"}\n' > \"\$G/n/package.json\"" "$CODE; $NEWLOCK"
want_diff L7d
# ---- L7e: the same new lockfile added on both sides, H with a metadata edit
pair "$CODE; $NEWLOCK" "$CODE; $NEWLOCK; printf '{\"name\": \"n\", %s\n' \"\$(lockjson | cut -c2-)\" > \"\$G/n/package-lock.json\""
want_diff L7e

# ---- L11-L15: the install set moved
pair "$CODE" "$CODE; lockto 1.3.0 https://evil.example.invalid/left-pad-1.3.0.tgz"
want_diff L11
pair "$CODE" "$CODE; lockto 1.3.0 https://registry.npmjs.org/left-pad/-/left-pad-9.9.9.tgz"
want_diff L11b
pair "$CODE" "$CODE; lockto 1.3.0 \"\$RES\" sha512-BBBB"
want_diff L12
pair "$CODE" "$CODE; lockto 1.3.1"
want_diff L13
pair "$CODE" "$CODE; lockto 1.3.0 \"\$RES\" sha512-AAAA ', \"node_modules/evil\": {\"version\": \"1.0.0\", \"resolved\": \"https://registry.npmjs.org/evil/-/evil-1.0.0.tgz\", \"integrity\": \"sha512-CCCC\"}'"
want_diff L14
pair "$CODE; lockto 1.3.0 \"\$RES\" sha512-AAAA ', \"node_modules/b\": {\"version\": \"1.0.0\"}'" "$CODE; lockto"
want_diff L15

# ---- L16: both heads already resolve off the allow-list; H only reorders
OFF=https://mirror.example.invalid/left-pad-1.3.0.tgz
pair "$CODE; lockto 1.3.0 $OFF" "$CODE; printf '{\"name\": \"a\", %s\n' \"\$(lockjson 1.3.0 $OFF | cut -c2-)\" > \"\$G/package-lock.json\""
want_diff L16
want L16b lockfile PATCH_SAME_LOCK_HOSTS='registry.npmjs.org mirror.example.invalid'

# ---- L17: v1 lockfile, a nested dependency's resolved changed
V1='{"lockfileVersion": 1, "dependencies": {"a": {"version": "1.0.0", "resolved": "https://registry.npmjs.org/a/-/a-1.0.0.tgz", "dependencies": {"b": {"version": "2.0.0", "resolved": "https://registry.npmjs.org/b/-/b-2.0.0.tgz"}}}}}'
pair "$CODE; printf '%s\n' '$V1' > \"\$G/package-lock.json\"" "$CODE; printf '%s\n' '${V1/b-2.0.0.tgz/b-2.0.1.tgz}' > \"\$G/package-lock.json\""
want_diff L17
pair "$CODE; printf '%s\n' '$V1' > \"\$G/package-lock.json\"" "$CODE; printf '%s\n' '${V1/\"lockfileVersion\": 1, /\"lockfileVersion\": 1, \"name\": \"a\", }' > \"\$G/package-lock.json\""
want L17b lockfile

# ---- L18: a lockfile that is not JSON
pair "$CODE" "$CODE; printf 'not json\n' > \"\$G/package-lock.json\""
want_diff L18

# ---- L19: yarn.lock is named, but the rung has no yarn parser
pair "$CODE" "$CODE; printf '# meta\na@1:\n  version 1\n' > \"\$G/yarn.lock\""
want_diff L19 PATCH_SAME_LOCKFILES='package-lock.json yarn.lock'

# ---- L8: no lockfile names
pair "$CODE" "$CODE; $LOCK"
want_diff L8 "$A" PATCH_SAME_LOCKFILES=

# ---- L9: default knobs, a metadata-only lockfile edit
pair "$CODE" "$CODE; $LOCK"
want L9 lockfile

# ---- W1: trailing spaces on a .sh line
pair "$CODE" "edit 10 'line 10 CHANGED BY PR  '"
want W1 whitespace
patch_same "$G" main "$R" "$H" >/dev/null && bad "BYTES W1: byte patch_same must stay rc 1 on a whitespace change" || ok
# ---- W8: the same pair, .sh made significant
want_diff W8 PATCH_SAME_WS_SIGNIFICANT=.sh

# ---- W2: trailing space after a `\` continuation
pair "edit 10 'line 10 CHANGED \\\\'" "edit 10 'line 10 CHANGED \\\\ '"
want_diff W2

# ---- W3: .py indentation
pair "printf 'def f(x):\n    return x + 1\n' > \"\$G/a.py\"" "printf 'def f(x):\n  return x + 1\n' > \"\$G/a.py\""
want_diff W3
# ---- W3b: .py trailing space
pair "printf 'def f(x):\n    return x + 1\n' > \"\$G/a.py\"" "printf 'def f(x):\n    return x + 1 \n' > \"\$G/a.py\""
want_diff W3b

# ---- W4: .yml trailing space
pair "printf 'jobs:\n  a:\n    run: y\n' > \"\$G/c.yml\"" "printf 'jobs:\n  a:\n    run: y \n' > \"\$G/c.yml\""
want_diff W4

# ---- W5: a blank line added
pair "$CODE" "edit 10 'line 10 CHANGED BY PR\n'"
want_diff W5

# ---- W6: CRLF -> LF in .js
pair "printf 'var a = 1;\r\nvar b = 2;\r\n' > \"\$G/a.js\"" "printf 'var a = 1;\nvar b = 2;\n' > \"\$G/a.js\""
want W6 whitespace

# ---- W9: LF -> CRLF in .sh: --ignore-space-at-eol hides the CR, bash does not
pair "$CODE" "$CODE; sed -i.bak 's/\$/\r/' \"\$G/f.sh\" && rm -f \"\$G/f.sh.bak\""
want_diff W9

# ---- W7: trailing space + mode change
pair "$CODE" "edit 10 'line 10 CHANGED BY PR '; chmod 755 \"\$G/f.sh\""
want_diff W7

# ---- W7b: trailing space + a mode change on a file with no content change
pair "$CODE" "edit 10 'line 10 CHANGED BY PR '; chmod 755 \"\$G/o.txt\""
want_diff W7b
mkdir -p "$T/oldgit"; REALGIT=$(command -v git)
# The stub's patch-id hashes only file chunks that carry a hunk, so a
# mode-only chunk is invisible to it, as to a patch-id that skips headers.
cat > "$T/oldgit/git" <<EOF2
#!/bin/bash
if [ "\$1" = patch-id ]; then
  awk '/^diff --git /{if (c != "" && h) printf "%s", c; c = ""; h = 0} /^@@ /{h = 1} {c = c \$0 "\\n"} END{if (c != "" && h) printf "%s", c}' | "$REALGIT" "\$@"
else exec "$REALGIT" "\$@"; fi
EOF2
chmod +x "$T/oldgit/git"
want_diff W7c PATH="$T/oldgit:$PATH"

# ---- STUB: a git that fails
pair "$CODE" "$CODE; $LOCK"
mkdir -p "$T/stub"; printf '#!/bin/sh\nexit 1\n' > "$T/stub/git"; chmod +x "$T/stub/git"
out=$(PATH="$T/stub:$PATH" patch_same_semantic "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "STUB patch_same_semantic on a failing git: rc=$rc out='$out'"

# ---- KNOBS: catalog defaults equal the code fallbacks
cat_def() { jq -r --arg e "$1" '.libs[].knobs[] | select(.env == $e) | .default' "$DIR/catalog/lanes.d/_lib.patch-same.json" 2>/dev/null; }
for k in PATCH_SAME_LOCKFILES PATCH_SAME_LOCK_HOSTS PATCH_SAME_WS_SIGNIFICANT; do
  code=$(env -u "$k" bash -c '. "$1"; _ps_knob "$2"' _ "$DIR/bin/lib/patch-same.sh" "$k" 2>/dev/null)
  cat=$(cat_def "$k")
  [ -n "$cat" ] && [ "$cat" = "$code" ] && ok || bad "KNOBS $k: catalog default '$cat' != code fallback '$code'"
done

echo "patch-same-semantic.bh-9154: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
