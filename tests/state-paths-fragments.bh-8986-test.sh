#!/bin/bash
# tests/state-paths-fragments.bh-8986-test.sh — catalog/state-paths.json is a
# COMPOSITION of catalog/state-paths.d/ (BH-8986), built by
# bin/state-paths-build.sh and never committed.
#
#   F0  the defect: two branches that each append a row to the old one-file
#       catalog conflict; this tree carries catalog/state-paths.d/ and does not
#       track catalog/state-paths.json
#   F1  the split commit's fragments compose to its parent's file byte for byte
#   F2  two branches that each add a fragment merge clean; both rows compose,
#       in file-name order, and the base rows are unchanged
#   F3  the composer's refuse table (a)-(h); F3n the near misses it ACCEPTS
#   F4  --check: rc 0 untracked, rc 1 on a tracked composed file, no repo
#       write; an unchanged --compose writes nothing; mode 644
#   F5  bin/state-paths-guard.sh composes its default catalog; a broken
#       fragment is rc 2 naming catalog/state-paths.d; no temp file is left
#   F6  bin/pool-state-paths-lint.sh composes its default catalog
#   F7  bin/state-drain.sh reads the fragments, not a stale composed copy; a
#       broken fragment refuses the run
#   F8  bin/test-impact.sh selects the catalog's readers for a fragment diff
#   F9  tests/no-state-files.bh-4159-test.sh reads the composed allowlist
#   F10 tests/lib/scratch.sh composes the catalog when it is sourced
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SB="$DIR/bin/state-paths-build.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
  || { echo "state-paths-fragments: jq/git missing — skipping"; exit 0; }

export GIT_AUTHOR_DATE="@1760000000 +0000" GIT_COMMITTER_DATE="@1760000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"
gitc() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# row <path> [class] — one catalog row on one line.
row() { printf '{"path": "%s", "class": "%s", "authority": "fixture %s", "note": "fixture"}' "$1" "${2:-cache}" "$1"; }
# fragment <file> <path[:class]>... — a fragment file: `[`, one row per line, `]`.
fragment() {
  local f="$1" sep="" p; shift
  { echo "["; for p in "$@"; do printf '%s    %s' "$sep" "$(row "${p%%:*}" "$( [ "${p#*:}" != "$p" ] && echo "${p#*:}" || echo cache)")"; sep=$',\n'; done; printf '\n]\n'; } > "$f"
}
# fresh <tag> — a scratch git repo with the composer and the REAL fragments,
# the composed path git-ignored as in the repo. Sets W.
fresh() {
  W="$T/$1"; mkdir -p "$W/catalog"
  scratch_install_closure bin/state-paths-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
  cp -r "$DIR/catalog/state-paths.d" "$W/catalog/state-paths.d" 2>/dev/null
  printf 'catalog/state-paths.json\n' > "$W/.gitignore"
  gitc init -q "$W"; gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm base
}
run() { local w="$1"; shift; "$w/bin/state-paths-build.sh" --repo "$w" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
fpath() { printf '%s/catalog/state-paths.d/%s' "$W" "$1"; }

# The OLD one-file catalog: the split commit's parent. A history-less tree has
# none: F1 is skipped and F0 uses the composition, which F1 proves equal.
OLD="$T/old.json"; : > "$OLD"
SPLIT=$(git -C "$DIR" log --no-renames --diff-filter=A --format=%H -1 -- catalog/state-paths.d/0000-base.json 2>/dev/null)
if [ -n "$SPLIT" ] && git -C "$DIR" cat-file -e "$SPLIT^:catalog/state-paths.json" 2>/dev/null; then
  git -C "$DIR" show "$SPLIT^:catalog/state-paths.json" > "$OLD"
else
  SPLIT=""
  git -C "$DIR" cat-file -e HEAD:catalog/state-paths.json 2>/dev/null \
    && git -C "$DIR" show HEAD:catalog/state-paths.json > "$OLD"
fi
LEGACY="$T/legacy.json"
if [ -s "$OLD" ]; then
  cp "$OLD" "$LEGACY"
else
  echo "state-paths-fragments: SKIP F1 split comparison: no split commit with a parent catalog, and HEAD tracks none (a history-less tree)"
  "$SB" --repo "$DIR" --compose --to "$LEGACY" 2>/dev/null
fi
[ -s "$LEGACY" ] && ok || bad "setup: no one-file catalog: no old copy in history, and --compose --to could not build one"

# =============================================================================
# F0 THE DEFECT. Appending a row to the old file edits the last row's line
# (its comma) and inserts before the same `  ]`.
# =============================================================================
append_row() { # append_row <file> <path> — what an S1 fix did to the old file
  F0_ROW="    $(row "$2")" awk '
    BEGIN { s = ENVIRON["F0_ROW"] }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (line[i] == "  ]") { close_at = i; break }
      for (i = 1; i <= NR; i++) {
        if (i == close_at - 1) print line[i] ","
        else if (i == close_at) { print s; print line[i] }
        else print line[i]
      }
    }' "$1" > "$1.new" && mv "$1.new" "$1"
}
if [ -s "$LEGACY" ]; then
  R0="$T/f0"; mkdir -p "$R0/catalog"; cp "$LEGACY" "$R0/catalog/state-paths.json"
  gitc init -q "$R0"; gitc -C "$R0" add -A >/dev/null; gitc -C "$R0" commit -qm base
  gitc -C "$R0" checkout -qb a; append_row "$R0/catalog/state-paths.json" row-a; gitc -C "$R0" commit -qam a
  gitc -C "$R0" checkout -q main; gitc -C "$R0" checkout -qb b; append_row "$R0/catalog/state-paths.json" row-b; gitc -C "$R0" commit -qam b
  [ "$(jq -r '.paths[-1].path' "$R0/catalog/state-paths.json" 2>/dev/null)" = row-b ] && ok \
    || bad "F0 the fixture append must leave valid JSON with the new row last"
  if gitc -C "$R0" merge --no-edit a >"$T/f0.merge" 2>&1; then
    bad "F0 two appends to the one-file catalog merged clean — the reproduction is wrong"
  else
    grep -q 'CONFLICT (content)' "$T/f0.merge" && ok \
      || bad "F0 the merge must fail on a content conflict: $(cat "$T/f0.merge")"
  fi
fi
[ -f "$DIR/catalog/state-paths.d/0000-base.json" ] && ok \
  || bad "F0 catalog/state-paths.d/0000-base.json does not exist: every S1 fix still appends to one catalog/state-paths.json and two of them conflict"
[ -z "$(git -C "$DIR" ls-files -- catalog/state-paths.json 2>/dev/null)" ] && ok \
  || bad "F0 catalog/state-paths.json is still tracked in git"

# =============================================================================
# F1 byte for byte at the split.
# =============================================================================
"$SB" --repo "$DIR" --compose --to "$T/f1.json" >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "F1 --compose --to must exit 0 on the repo, got $RC: $(cat "$T/err")"
if [ -n "$SPLIT" ]; then
  F1W="$T/f1split"; mkdir -p "$F1W"
  git -C "$DIR" archive "$SPLIT" catalog/state-paths.d bin/state-paths-build.sh | tar -x -C "$F1W"
  "$F1W/bin/state-paths-build.sh" --repo "$F1W" --compose --to "$T/f1.split" 2>/dev/null
  cmp -s "$T/f1.split" "$OLD" && ok \
    || bad "F1 at the split commit ${SPLIT:0:12} the fragments must compose to its parent's catalog/state-paths.json byte for byte"
  [ "$(jq '.paths|length' "$T/f1.split" 2>/dev/null)" = "$(jq '.paths|length' "$OLD")" ] && ok \
    || bad "F1 the split must keep the row count"
  [ "$(jq -c '[.paths[]|.path+.class]' "$T/f1.split" 2>/dev/null)" = "$(jq -c '[.paths[]|.path+.class]' "$OLD")" ] && ok \
    || bad "F1 the split must keep every path and class"
elif [ -s "$OLD" ]; then
  cmp -s "$T/f1.json" "$OLD" && ok \
    || bad "F1 the composition must equal HEAD's catalog/state-paths.json byte for byte: $(diff "$OLD" "$T/f1.json" 2>&1 | head -5)"
fi

# =============================================================================
# F2 two branches each add a fragment: a clean merge, both rows composed.
# =============================================================================
fresh f2
# The base is EVERY real fragment, composed: a ticket's own NNNN-<name>.json is
# a real row too (BH-9072 added 9072-lane-wake-gate.json, and a base of
# 0000-base.json alone turned F2 red). The fixture names sort after any 4-digit
# ticket fragment ("99998-" > "9999-" in C order).
"$W/bin/state-paths-build.sh" --repo "$W" --compose >/dev/null 2>&1
BASEROWS=$(jq -c '.paths' "$W/catalog/state-paths.json" 2>/dev/null)
rm -f "$W/catalog/state-paths.json"
gitc -C "$W" checkout -qb a; fragment "$(fpath 99998-a.json)" zz-a
gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm a
gitc -C "$W" checkout -q main; gitc -C "$W" checkout -qb b; fragment "$(fpath 99999-b.json)" zz-b
gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm b
gitc -C "$W" merge -q --no-edit a >"$T/f2.merge" 2>&1; MRC=$?
[ "$MRC" = 0 ] && ok || bad "F2 git merge of two fragment branches must exit 0, got $MRC: $(cat "$T/f2.merge")"
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "F2 --compose after the merge must exit 0, got $RC: $(cat "$T/err")"
[ "$(jq -c '[.paths[-2:][].path]' "$W/catalog/state-paths.json" 2>/dev/null)" = '["zz-a","zz-b"]' ] && ok \
  || bad "F2 the two new rows must come last, in file-name order: $(jq -c '[.paths[-2:][].path]' "$W/catalog/state-paths.json" 2>&1)"
[ -n "$BASEROWS" ] && [ "$(jq -c '.paths[:-2]' "$W/catalog/state-paths.json" 2>/dev/null)" = "$BASEROWS" ] && ok \
  || bad "F2 the base rows must be unchanged and first"
[ "$(jq -r '.version' "$W/catalog/state-paths.json" 2>/dev/null)" = 1 ] && ok \
  || bad "F2 the composition must carry the head's version key"

# =============================================================================
# F3 the refuse table: rc 2, the old file stays, no temp file beside it.
# =============================================================================
refuse() {
  local label="$1"; shift
  fresh "f3-$label"
  "$W/bin/state-paths-build.sh" --repo "$W" --compose >/dev/null 2>&1
  local before; before=$(sha "$W/catalog/state-paths.json")
  [ -n "$before" ] || { bad "F3 $label: no composed file to start from"; return; }
  "$@"
  run "$W" --compose
  [ "$RC" = 2 ] && ok || bad "F3 $label must be rc 2, got $RC: $(cat "$T/err")"
  [ "$(sha "$W/catalog/state-paths.json")" = "$before" ] && ok || bad "F3 $label must leave the old catalog/state-paths.json as it was"
  [ -z "$(find "$W/catalog" -maxdepth 1 -name '.state-paths*' 2>/dev/null)" ] && ok \
    || bad "F3 $label left a temp file: $(find "$W/catalog" -maxdepth 1 -name '.state-paths*')"
  cp "$T/err" "$T/err.compose"
  run "$W" --check
  [ "$RC" = 2 ] && ok || bad "F3 $label: --check must be rc 2 too, got $RC"
  cp "$T/err.compose" "$T/err"
}
BASE1=$(jq -r '.paths[0].path' "$LEGACY")
w_dupx()     { fragment "$(fpath 0001-x.json)" "$BASE1"; }
w_dupin()    { fragment "$(fpath 0001-x.json)" zz-same zz-same; }
w_notjson()  { printf '[ {"path":\n]\n' > "$(fpath 0001-x.json)"; }
w_object()   { printf '{}\n' > "$(fpath 0001-x.json)"; }
w_empty()    { printf '[\n]\n' > "$(fpath 0001-x.json)"; }
w_string()   { printf '[\n    "x"\n]\n' > "$(fpath 0001-x.json)"; }
w_nopath()   { printf '[\n    {"class": "cache"}\n]\n' > "$(fpath 0001-x.json)"; }
w_intpath()  { printf '[\n    {"path": 1, "class": "cache"}\n]\n' > "$(fpath 0001-x.json)"; }
w_short()    { fragment "$(fpath 12-x.json)" zz-x; }
w_upper()    { fragment "$(fpath 0001-X.json)" zz-x; }
w_stray()    { echo notes > "$(fpath notes.txt)"; }
w_nohead()   { rm -f "$(fpath _head.json)"; }
w_headpaths(){ jq '. + {paths: []}' "$(fpath _head.json)" > "$T/h.json" && cp "$T/h.json" "$(fpath _head.json)"; }
w_nofrag()   { rm -f "$W"/catalog/state-paths.d/[0-9]*.json; }
w_oneline()  { printf '[%s]\n' "$(row zz-one)" > "$(fpath 0001-x.json)"; }
refuse a-dup-across w_dupx
grep -qF "$BASE1" "$T/err" && grep -q twice "$T/err" && ok || bad "F3a a duplicate path must be named: $(cat "$T/err")"
refuse b-dup-inside w_dupin
grep -qF zz-same "$T/err" && ok || bad "F3b a duplicate path inside one fragment must be named: $(cat "$T/err")"
refuse c-notjson    w_notjson
grep -qF 0001-x.json "$T/err" && ok || bad "F3c the refusal must name the unparseable fragment: $(cat "$T/err")"
refuse d-object     w_object
refuse d-empty      w_empty
refuse d-string     w_string
refuse e-nopath     w_nopath
refuse e-intpath    w_intpath
refuse f-short      w_short
refuse f-upper      w_upper
refuse f-stray      w_stray
grep -qF notes.txt "$T/err" && ok || bad "F3f the refusal must name the stray file: $(cat "$T/err")"
refuse g-nohead     w_nohead
refuse g-headpaths  w_headpaths
refuse h-nofrag     w_nofrag
refuse oneline      w_oneline

# F3n the near misses: each must be ACCEPTED, and the jq test must hold.
accept() {
  local label="$1" want="$2"; shift 2
  fresh "f3n-$label"; "$@"
  run "$W" --compose
  [ "$RC" = 0 ] && ok || bad "F3n $label must be ACCEPTED (rc 0), got $RC: $(cat "$T/err")"
  jq -e "$want" "$W/catalog/state-paths.json" >/dev/null 2>&1 && ok \
    || bad "F3n $label: the composed file must satisfy $want: $(jq -c '[.paths[-3:][].path]' "$W/catalog/state-paths.json" 2>&1)"
}
na_crlf()   { fragment "$(fpath 9999-x.json)" zz-x; sed -i 's/$/\r/' "$(fpath 9999-x.json)"; }
na_ws()     { fragment "$(fpath 9999-x.json)" zz-x; sed -i '$s/^]$/]   /' "$(fpath 9999-x.json)"; }
na_five()   { fragment "$(fpath 10001-x.json)" zz-x; }
na_prefix() { fragment "$(fpath 9998-a.json)" zz-pool; fragment "$(fpath 9999-b.json)" zz-pool-stats; }
na_same()   { fragment "$(fpath 9999-x.json)" zz-x:box-local zz-y:box-local; }
na_one()    { fragment "$(fpath 9998-a.json)" zz-a; fragment "$(fpath 9999-b.json)" zz-b; }
accept crlf     '.paths[-1].path == "zz-x"' na_crlf
accept ws-close '.paths[-1].path == "zz-x"' na_ws
accept five     'any(.paths[]; .path == "zz-x")' na_five
accept prefix   '[.paths[-2:][].path] == ["zz-pool","zz-pool-stats"]' na_prefix
accept same     '[.paths[-2:][].class] == ["box-local","box-local"]' na_same
accept one-each '[.paths[-2:][].path] == ["zz-a","zz-b"]' na_one

# LEGACY: no fragments, a committed file: used as is, no write.
W="$T/f3legacy"; mkdir -p "$W/catalog"
scratch_install_closure bin/state-paths-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$LEGACY" "$W/catalog/state-paths.json"; touch -d @1000000000 "$W/catalog/state-paths.json"
L0=$(stat -c '%i %Y' "$W/catalog/state-paths.json")
run "$W" --compose
[ "$RC" = 0 ] && [ "$(stat -c '%i %Y' "$W/catalog/state-paths.json")" = "$L0" ] && ok \
  || bad "F3 LEGACY --compose must exit 0 and not write, got $RC"
run "$W" --compose --to "$T/f3l.to"
[ "$RC" = 0 ] && cmp -s "$T/f3l.to" "$LEGACY" && ok || bad "F3 LEGACY --compose --to must copy the committed file, got $RC"
rm -f "$W/catalog/state-paths.json"
run "$W" --compose --to "$T/f3l.to2"
[ "$RC" = 2 ] && ok || bad "F3 LEGACY with no file must be rc 2, got $RC"

# =============================================================================
# F4 --check, idempotence and mode.
# =============================================================================
fresh f4
( umask 077; "$W/bin/state-paths-build.sh" --repo "$W" --compose ) >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "F4 --compose must exit 0, got $RC: $(cat "$T/err")"
[ "$(stat -c '%a' "$W/catalog/state-paths.json" 2>/dev/null)" = 644 ] && ok \
  || bad "F4 the composed catalog must be mode 644, got $(stat -c '%a' "$W/catalog/state-paths.json" 2>&1)"
touch -d @1000000000 "$W/catalog/state-paths.json"
F4S=$(stat -c '%i %Y' "$W/catalog/state-paths.json")
run "$W" --compose
[ "$RC" = 0 ] && [ "$(stat -c '%i %Y' "$W/catalog/state-paths.json")" = "$F4S" ] && [ ! -s "$T/out" ] && ok \
  || bad "F4 an unchanged --compose must exit 0, write nothing and print nothing (rc $RC): $(cat "$T/out")"
ST0=$(git -C "$W" status --porcelain)
run "$W" --check
[ "$RC" = 0 ] && ok || bad "F4 --check must be rc 0 with an untracked, ignored catalog, got $RC: $(cat "$T/err")"
NFRAG=$(find "$W/catalog/state-paths.d" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')
grep -qE "^state-paths-build: [0-9]+ paths from +$NFRAG fragments; catalog/state-paths.json is composed, not committed\$" "$T/out" && ok \
  || bad "F4 --check must print its status line: $(cat "$T/out")"
[ "$(git -C "$W" status --porcelain)" = "$ST0" ] && ok || bad "F4 --check must write nothing in the repo"
gitc -C "$W" add -f catalog/state-paths.json >/dev/null; gitc -C "$W" commit -qm 'commit the render'
run "$W" --check
[ "$RC" = 1 ] && grep -q TRACKED "$T/err" && ok \
  || bad "F4 --check must be rc 1 naming TRACKED when catalog/state-paths.json is tracked, got $RC: $(cat "$T/err")"
grep -qF 'git rm --cached catalog/state-paths.json' "$T/err" && ok || bad "F4 the refusal must give the git rm fix: $(cat "$T/err")"
grep -q 'composed, not committed' "$T/out" && bad "F4 a red --check must not print the status line" || ok

# =============================================================================
# F5 the guard composes its default catalog.
# =============================================================================
G="$T/f5"; mkdir -p "$G/bin" "$G/guardrails/lib" "$G/catalog" "$G/src/bin" "$G/tmp"
# scratch_closure_list cannot resolve guardrails/lib/escape-hatch.sh (it reports
# "sources missing"), so the guard and its hatch are copied; the composer is
# installed by closure.
cp "$DIR/bin/state-paths-guard.sh" "$G/bin/"
scratch_install_closure bin/state-paths-build.sh "$G" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$DIR/guardrails/lib/escape-hatch.sh" "$G/guardrails/lib/" 2>/dev/null
cp -r "$DIR/catalog/state-paths.d" "$G/catalog/"
printf '#!/bin/bash\necho x > "$H/state/pool/x"\n' > "$G/src/bin/zz-new.sh"
printf 'bin/zz-new.sh\n' > "$T/f5.list"
OUT=$(env -u SPG_CATALOG TMPDIR="$G/tmp" SPG_FILES="$T/f5.list" SPG_ROOT="$G/src" bash "$G/bin/state-paths-guard.sh" 2>&1); RC=$?
[ "$RC" = 1 ] && grep -qF 'state/pool' <<<"$OUT" && ok \
  || bad "F5 the guard with the composed catalog must flag the state/pool writer (rc 1), got $RC: $OUT"
[ -z "$(ls -A "$G/tmp")" ] && ok || bad "F5 the guard must leave no temp file: $(ls -A "$G/tmp")"
[ ! -e "$G/catalog/state-paths.json" ] && ok || bad "F5 the guard must compose into a temp file, not the canonical path"
printf '[\n    {"path": "pool", "class": "cache"}\n]\n' > "$G/catalog/state-paths.d/0001-dup.json"
OUT=$(env -u SPG_CATALOG TMPDIR="$G/tmp" SPG_FILES="$T/f5.list" SPG_ROOT="$G/src" bash "$G/bin/state-paths-guard.sh" 2>&1); RC=$?
[ "$RC" = 2 ] && grep -qF 'catalog/state-paths.d' <<<"$OUT" && ok \
  || bad "F5 a broken fragment must be rc 2 naming catalog/state-paths.d, got $RC: $OUT"
[ -z "$(ls -A "$G/tmp")" ] && ok || bad "F5 a refused compose must leave no temp file: $(ls -A "$G/tmp")"
OUT=$(SPG_CATALOG="$LEGACY" TMPDIR="$G/tmp" SPG_FILES="$T/f5.list" SPG_ROOT="$G/src" bash "$G/bin/state-paths-guard.sh" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "F5 SPG_CATALOG must still win over the fragments (rc 1), got $RC: $OUT"
grep -qF 'under catalog/state-paths.d/ (or add a new NNNN-<name>.json fragment)' "$DIR/bin/state-paths-guard.sh" \
  && ! grep -qxF 'catalog/state-paths.json in this same PR.' "$DIR/bin/state-paths-guard.sh" && ok \
  || bad "F5 the guard's fix text must point at a fragment under catalog/state-paths.d/"

# =============================================================================
# F6 the pool lint composes its default catalog.
# =============================================================================
L="$T/f6"; mkdir -p "$L/bin" "$L/guardrails/lib" "$L/catalog" "$L/tmp"
cp "$DIR/bin/pool-state-paths-lint.sh" "$DIR/bin/fly-pool.sh" "$L/bin/"   # see F5: no closure for the hatch
scratch_install_closure bin/state-paths-build.sh "$L" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$DIR/guardrails/lib/escape-hatch.sh" "$L/guardrails/lib/" 2>/dev/null
cp -r "$DIR/catalog/state-paths.d" "$DIR/catalog/lane-run-inputs.d" "$L/catalog/"
OUT=$(TMPDIR="$L/tmp" bash "$L/bin/pool-state-paths-lint.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && [[ "$(tail -n 1 <<<"$OUT")" == "pool-state-paths: unclassified=0 checked="* ]] && ok \
  || bad "F6 the pool lint on the composed catalog must be rc 0 unclassified=0, got $RC: $(tail -3 <<<"$OUT")"
[ -z "$(ls -A "$L/tmp")" ] && [ ! -e "$L/catalog/state-paths.json" ] && ok || bad "F6 the lint must leave no temp file and no canonical write"
printf '[\n    {"path": 7}\n]\n' > "$L/catalog/state-paths.d/0001-bad.json"
OUT=$(TMPDIR="$L/tmp" bash "$L/bin/pool-state-paths-lint.sh" 2>&1); RC=$?
[ "$RC" = 2 ] && grep -qF 'catalog/state-paths.d' <<<"$OUT" && ok \
  || bad "F6 a broken fragment must be rc 2 naming catalog/state-paths.d, got $RC: $OUT"

# =============================================================================
# F7 state-drain: the fragments win over a stale composed copy.
# =============================================================================
. "$DIR/tests/lib/rendered.sh" || exit 1
unset STATE_DRAIN_DRY_RUN STATE_DRAIN_MIN_IDLE_DAYS STATE_DRAIN_ARCHIVE_KEEP_DAYS STATE_DRAIN_MAX_PER_RUN \
      STATE_DRAIN_SCAN_TIMEOUT_S STATE_DRAIN_STATE_DIR STATE_DRAIN_ARCHIVE_DIR STATE_DRAIN_CRONTAB_FILE \
      STATE_DRAIN_NOW 2>/dev/null || true
H="$T/h7"
scratch_install_closure bin/state-drain.sh "$H" >/dev/null || bad "F7 cannot install bin/state-drain.sh's closure"
scratch_install_closure bin/state-paths-build.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
mkdir -p "$H/logs" "$H/flags" "$H/locks" "$H/catalog" "$H/env"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
cp -r "$DIR/catalog/state-paths.d" "$H/catalog/"
# the stale copy a box keeps (harness-sync rsyncs catalog/ with no --delete)
"$SB" --repo "$DIR" --compose --to "$H/catalog/state-paths.json" 2>/dev/null
printf '[\n    {"path": "zz-new", "class": "rows", "authority": "fixture"}\n]\n' > "$H/catalog/state-paths.d/9001-zz-new.json"
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SD_LEDGER"; }
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$SD_ALERTS"\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
export SD_LEDGER="$T/f7.ledger" SD_ALERTS="$T/f7.alerts"
NOW=1790000000; OLD7=$((NOW - 60 * 86400))
S="$T/f7/state"; A="$T/f7/archive"; mkdir -p "$S/zz-new" "$A"
echo x > "$S/zz-new/a"; find "$S/zz-new" -exec touch -h -d "@$OLD7" {} +
: > "$T/f7.crontab"
drain() {
  timeout 120 env HARNESS_ROOT="$H" HARNESS="$H" HOME="$T" HARNESS_TEST_SANDBOX=1 TMPDIR="$T/f7" \
    STATE_DRAIN_STATE_DIR="$S" STATE_DRAIN_ARCHIVE_DIR="$A" STATE_DRAIN_CRONTAB_FILE="$T/f7.crontab" \
    STATE_DRAIN_NOW="$NOW" "$@" bash "$H/bin/state-drain.sh"
}
drain STATE_DRAIN_DRY_RUN=1 > "$T/f7.out" 2>"$T/f7.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "F7 state-drain must exit 0, got $RC: $(cat "$T/f7.err")"
[ "$(awk -F'\t' '$2=="zz-new"{print $1}' "$T/f7.out")" = catalog ] && ok \
  || bad "F7 zz-new is a rows path of a fragment and must be kept 'catalog', not read from the stale copy: $(cat "$T/f7.out" "$T/f7.err" | head -5)"
[ -z "$(find "$T/f7" -maxdepth 1 -name 'tmp.*' 2>/dev/null)" ] && ok || bad "F7 state-drain must remove its composed temp file"
printf '[\n    {"path": "zz-new",\n]\n' > "$H/catalog/state-paths.d/9002-broken.json"
rm -f "$SD_LEDGER" "$SD_ALERTS" "$H/logs/state-drain.log"
drain STATE_DRAIN_DRY_RUN=0 > "$T/f7.out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ -d "$S/zz-new" ] && ok || bad "F7 a broken fragment must delete nothing (rc $RC)"
grep -qE ' refused \(catalog .*state-paths.d could not be composed' "$H/logs/state-drain.log" 2>/dev/null && ok \
  || bad "F7 a broken fragment must refuse the run, not fall back to the stale copy: $(cat "$H/logs/state-drain.log" 2>/dev/null)"
[ "$(cut -f3 "$SD_LEDGER" 2>/dev/null)" = refused ] && [ "$(grep -c -- '--severity warn' "$SD_ALERTS" 2>/dev/null)" = 1 ] && ok \
  || bad "F7 a refused run writes one refused ledger row and one warn ($(cat "$SD_LEDGER" "$SD_ALERTS" 2>/dev/null))"

# =============================================================================
# F8 test selection follows a fragment-only diff.
# =============================================================================
printf 'catalog/state-paths.d/9999-x.json\n' > "$T/f8.changed"
TI_OUT=$("$DIR/bin/test-impact.sh" --root "$DIR" select --changed "$T/f8.changed" --map-only --why 2>"$T/f8.err"); TRC=$?
[ "$TRC" = 0 ] && ok || bad "F8 test-impact select must exit 0, got $TRC: $(head -5 "$T/f8.err")"
for s in tests/no-state-files.bh-4159-test.sh tests/pool-state-paths.bh-7431-test.sh tests/state-drain.bh-8443-test.sh; do
  grep -qE "^${s//./\\.}"$'\t[a-z]+\tcatalog/state-paths\\.json$' <<<"$TI_OUT" && ok \
    || bad "F8 a fragment-only diff must select $s through catalog/state-paths.json: $(grep -F "$s" <<<"$TI_OUT" | head -2)"
done

# =============================================================================
# F9 the no-state-files allowlist reads the composed catalog.
# =============================================================================
SEG=$(env -u NO_STATE_FILES_REPO HARNESS_TEST_SANDBOX=1 bash "$DIR/tests/no-state-files.bh-4159-test.sh" --list-segments 2>&1); SRC=$?
[ "$SRC" = 0 ] && ! grep -q 'cannot read the allowlist' <<<"$SEG" && ok \
  || bad "F9 no-state-files --list-segments must read the composed allowlist (rc $SRC): $(head -3 <<<"$SEG")"
ALLOWN=$(jq '[.paths[]|select(.class!="rows")]|length' "$DIR/catalog/state-paths.json" 2>/dev/null)
[ "${ALLOWN:-0}" -ge 49 ] && ok || bad "F9 the composed catalog must class at least 49 cache/box-local paths, got ${ALLOWN:-none}"
LEAK=$(jq -r '.paths[]|select(.class!="rows")|.path' "$DIR/catalog/state-paths.json" 2>/dev/null \
  | while IFS= read -r p; do awk -F'\t' -v p="$p" '$1==p' <<<"$SEG"; done)
[ -z "$LEAK" ] && ok || bad "F9 an allowlisted segment must not be listed as a site: $LEAK"
grep -qF 'catalog/state-paths.d/NNNN-<name>.json' "$DIR/tests/no-state-files.bh-4159-test.sh" && ok \
  || bad "F9 the S1 fix text must tell the author to add a fragment file catalog/state-paths.d/NNNN-<name>.json"

# =============================================================================
# F10 tests/lib/scratch.sh composes the catalog at source time.
# =============================================================================
R10="$T/r10"; mkdir -p "$R10/tests/lib" "$R10/catalog"
cp "$DIR/tests/lib/scratch.sh" "$R10/tests/lib/"
scratch_install_closure bin/state-paths-build.sh "$R10" >/dev/null || { echo "closure install failed"; exit 1; }
cp -r "$DIR/catalog/state-paths.d" "$R10/catalog/"
( . "$R10/tests/lib/scratch.sh" ) >"$T/f10.out" 2>"$T/f10.err"; R10RC=$?
"$SB" --repo "$R10" --compose --to "$T/f10.want" >/dev/null 2>&1
[ "$R10RC" = 0 ] && [ -f "$R10/catalog/state-paths.json" ] && cmp -s "$R10/catalog/state-paths.json" "$T/f10.want" && ok \
  || bad "F10 sourcing scratch.sh must compose catalog/state-paths.json (rc $R10RC): $(cat "$T/f10.err")"
printf '[\n    {"path": "broken",\n]\n' > "$R10/catalog/state-paths.d/0001-broken.json"
( . "$R10/tests/lib/scratch.sh"; echo after-source ) >"$T/f10c.out" 2>"$T/f10c.err"; R10RC=$?
[ "$R10RC" = 0 ] && grep -q after-source "$T/f10c.out" && grep -qF 'state-paths' "$T/f10c.err" && ok \
  || bad "F10 a broken fragment must print one line and not stop the suite (rc $R10RC)"

echo "state-paths-fragments.bh-8986: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
