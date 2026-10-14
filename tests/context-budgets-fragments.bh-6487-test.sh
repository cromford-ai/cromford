#!/bin/bash
# tests/context-budgets-fragments.bh-6487-test.sh — catalog/context-budgets.json
# is a COMPOSITION of catalog/context-budgets.d/ (BH-6487, the last part of
# BH-4987 item 4), built by bin/context-budgets-build.sh and never committed.
#
#   B0  the defect: two branches that each append a lane to the old one-file
#       manifest conflict; this tree carries catalog/context-budgets.d/ and does
#       not track catalog/context-budgets.json
#   B1  the split commit's fragments compose to its parent's file byte for byte
#   B2  two branches that each add a fragment merge clean; both lanes compose,
#       in file-name order
#   B3  the composer's accept/refuse table (a)-(i), and the negative list of
#       plan System invariants (c): six inputs that must be ACCEPTED (B3n)
#   B4  --check: rc 1 on a tracked composed file, rc 0 untracked, no repo write
#   B5  an unchanged second --compose writes and prints nothing; mode 644
#   B6  bin/harness-sync.sh composes into the jobs worker deploy snapshot; a
#       broken fragment is one deploy ALERT, no deploy, no stamp
#   B7  bin/harness-sync.sh: a fragment-only commit moves the budget sync sha,
#       and catalog-sync is given the composed file with the new lane
#   B8  tests/lib/scratch.sh composes the manifest when it is sourced
#   B9  the worker's own import (routes/llm-sites.js) loads the composed file
#   B10 bin/test-impact.sh selects the manifest's readers for a fragment diff
#   B11 bin/rules-pack.sh rp_lanes_render composes with its own composer
#   B12 bin/prequeue-worker-schema.sh composes before node runs
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CB="$DIR/bin/context-budgets-build.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
  || { echo "context-budgets-fragments: jq/git missing — skipping"; exit 0; }

export GIT_AUTHOR_DATE="@1760000000 +0000" GIT_COMMITTER_DATE="@1760000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"
gitc() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# lane <name> — one lane object on one line.
lane() {
  printf '{ "lane": "%s", "stage": "%s", "runner": null, "target_tokens": 1000, "ceiling_tokens": 2000 }' "$1" "$1"
}
# fragment <file> <name>... — a fragment file: `[`, one lane per line, `]`.
fragment() {
  local f="$1" sep=""; shift
  { echo "["; for n in "$@"; do printf '%s    %s' "$sep" "$(lane "$n")"; sep=$',\n'; done; printf '\n]\n'; } > "$f"
}
# fresh <tag> — a scratch git repo with the composer and the REAL fragments,
# the composed path git-ignored as in the repo. Sets W.
fresh() {
  W="$T/$1"; mkdir -p "$W/catalog"
  scratch_install_closure bin/context-budgets-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
  cp -r "$DIR/catalog/context-budgets.d" "$W/catalog/context-budgets.d" 2>/dev/null
  printf 'catalog/context-budgets.json\n' > "$W/.gitignore"
  gitc init -q "$W"; gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm base
}
run() { local w="$1"; shift; "$w/bin/context-budgets-build.sh" --repo "$w" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# The OLD one-file manifest: the split commit's parent, or HEAD's own copy when
# HEAD still tracks it. A history-less tree has neither: B1 is skipped and B0
# uses the composition, which B1 proves equal where it runs.
OLD="$T/old.json"; : > "$OLD"
SPLIT=$(git -C "$DIR" log --diff-filter=A --format=%H -1 -- catalog/context-budgets.d/0000-base.json 2>/dev/null)
if [ -n "$SPLIT" ] && git -C "$DIR" cat-file -e "$SPLIT^:catalog/context-budgets.json" 2>/dev/null; then
  git -C "$DIR" show "$SPLIT^:catalog/context-budgets.json" > "$OLD"
else
  SPLIT=""
  git -C "$DIR" cat-file -e HEAD:catalog/context-budgets.json 2>/dev/null \
    && git -C "$DIR" show HEAD:catalog/context-budgets.json > "$OLD"
fi
LEGACY="$T/legacy.json"
if [ -s "$OLD" ]; then
  cp "$OLD" "$LEGACY"
else
  echo "context-budgets-fragments: SKIP B1 split comparison: no split commit with a parent manifest, and HEAD tracks none (a history-less tree)"
  "$CB" --repo "$DIR" --compose --to "$LEGACY" 2>/dev/null
fi
[ -s "$LEGACY" ] && ok || bad "setup: no one-file manifest: no old copy in history, and --compose --to could not build one"

# =============================================================================
# B0 THE DEFECT. Appending a lane to the old file edits the last element's
# closing line (its comma) and inserts before the same `  ],`.
# =============================================================================
append_lane() { # append_lane <file> <name> — what a build did to the old file
  B0_LANE="    $(lane "$2")" awk '
    BEGIN { s = ENVIRON["B0_LANE"] }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (line[i] == "  \"lanes\": [") { open_at = i; break }
      for (i = open_at; i <= NR; i++) if (line[i] == "  ],") { close_at = i; break }
      for (i = 1; i <= NR; i++) {
        if (i == close_at - 1) print line[i] ","
        else if (i == close_at) { print s; print line[i] }
        else print line[i]
      }
    }' "$1" > "$1.new" && mv "$1.new" "$1"
}
if [ -s "$LEGACY" ]; then
  R0="$T/b0"; mkdir -p "$R0/catalog"; cp "$LEGACY" "$R0/catalog/context-budgets.json"
  gitc init -q "$R0"; gitc -C "$R0" add -A >/dev/null; gitc -C "$R0" commit -qm base
  gitc -C "$R0" checkout -qb a; append_lane "$R0/catalog/context-budgets.json" lane-a; gitc -C "$R0" commit -qam a
  gitc -C "$R0" checkout -q main; gitc -C "$R0" checkout -qb b; append_lane "$R0/catalog/context-budgets.json" lane-b; gitc -C "$R0" commit -qam b
  [ "$(jq -r '.lanes[-1].lane' "$R0/catalog/context-budgets.json" 2>/dev/null)" = lane-b ] && ok \
    || bad "B0 the fixture append must leave valid JSON with the new lane last"
  if gitc -C "$R0" merge --no-edit a >"$T/b0.merge" 2>&1; then
    bad "B0 two appends to the one-file manifest merged clean — the reproduction is wrong"
  else
    grep -q 'CONFLICT (content)' "$T/b0.merge" && ok \
      || bad "B0 the merge must fail on a content conflict: $(cat "$T/b0.merge")"
  fi
fi
[ -f "$DIR/catalog/context-budgets.d/0000-base.json" ] && ok \
  || bad "B0 catalog/context-budgets.d/0000-base.json does not exist: every new lane still appends to one catalog/context-budgets.json and two of them conflict"
[ -z "$(git -C "$DIR" ls-files -- catalog/context-budgets.json 2>/dev/null)" ] && ok \
  || bad "B0 catalog/context-budgets.json is still tracked in git"

# =============================================================================
# B1 byte for byte at the split.
# =============================================================================
"$CB" --repo "$DIR" --compose --to "$T/b1.json" >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "B1 --compose --to must exit 0 on the repo, got $RC: $(cat "$T/err")"
if [ -n "$SPLIT" ]; then
  B1W="$T/b1split"; mkdir -p "$B1W/bin"
  git -C "$DIR" archive "$SPLIT" catalog/context-budgets.d bin/context-budgets-build.sh | tar -x -C "$B1W"
  "$B1W/bin/context-budgets-build.sh" --repo "$B1W" --compose --to "$T/b1.split" 2>/dev/null
  cmp -s "$T/b1.split" "$OLD" && ok \
    || bad "B1 at the split commit ${SPLIT:0:12} the fragments must compose to its parent's catalog/context-budgets.json byte for byte"
elif [ -s "$OLD" ]; then
  cmp -s "$T/b1.json" "$OLD" && ok \
    || bad "B1 the composition must equal HEAD's catalog/context-budgets.json byte for byte: $(diff "$OLD" "$T/b1.json" 2>&1 | head -5)"
fi

# =============================================================================
# B2 two branches each add a fragment: a clean merge, both lanes composed.
# =============================================================================
fresh b2
BASEN=$(cat "$W"/catalog/context-budgets.d/[0-9]*.json 2>/dev/null | jq -s 'map(length) | add' 2>/dev/null)
case "$BASEN" in ''|*[!0-9]*) BASEN=0 ;; esac
gitc -C "$W" checkout -qb a; fragment "$W/catalog/context-budgets.d/9998-a.json" a
gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm a
gitc -C "$W" checkout -q main; gitc -C "$W" checkout -qb b; fragment "$W/catalog/context-budgets.d/9999-b.json" b
gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm b
gitc -C "$W" merge -q --no-edit a >"$T/b2.merge" 2>&1; MRC=$?
[ "$MRC" = 0 ] && ok || bad "B2 git merge of two fragment branches must exit 0, got $MRC: $(cat "$T/b2.merge")"
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "B2 --compose after the merge must exit 0, got $RC: $(cat "$T/err")"
[ "$(jq -c '[.lanes[-2:][].lane]' "$W/catalog/context-budgets.json" 2>/dev/null)" = '["a","b"]' ] && ok \
  || bad "B2 the two new lanes must come last, in file-name order: $(jq -c '[.lanes[-2:][].lane]' "$W/catalog/context-budgets.json" 2>&1)"
[ "$BASEN" -gt 0 ] && [ "$(jq '.lanes|length' "$W/catalog/context-budgets.json" 2>/dev/null)" = "$((BASEN + 2))" ] && ok \
  || bad "B2 the composed manifest must hold base+2 lanes (base=$BASEN), got $(jq '.lanes|length' "$W/catalog/context-budgets.json" 2>&1)"
[ "$(jq -r '._key|type' "$W/catalog/context-budgets.json" 2>/dev/null)" = string ] \
  && [ "$(jq -r '._doc' "$W/catalog/context-budgets.json" 2>/dev/null)" = docs/CONTEXT-COMPOSITION.md ] && ok \
  || bad "B2 the composition must carry the head (_doc) and the tail (_key) keys"

# =============================================================================
# B3 the accept/refuse table.
# =============================================================================
# (a) the real sources: --compose writes the file.
fresh b3a
run "$W" --compose
[ "$RC" = 0 ] && [ -f "$W/catalog/context-budgets.json" ] && ok || bad "B3a the real sources must compose, got $RC: $(cat "$T/err")"
grep -q 'composed catalog/context-budgets.json ([0-9]* lanes)' "$T/out" && ok \
  || bad "B3a a write must print the composed line: $(cat "$T/out")"
# (b) plus a new fragment.
fresh b3b; fragment "$W/catalog/context-budgets.d/9999-x.json" x
run "$W" --compose
[ "$RC" = 0 ] && [ "$(jq -r '.lanes[-1].lane' "$W/catalog/context-budgets.json" 2>/dev/null)" = x ] && ok \
  || bad "B3b a new fragment must compose last, got $RC: $(cat "$T/err")"
# (c) LEGACY: no fragments, a committed manifest: used as is, no write.
W="$T/b3c"; mkdir -p "$W/catalog"
scratch_install_closure bin/context-budgets-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$LEGACY" "$W/catalog/context-budgets.json"; touch -d @1000000000 "$W/catalog/context-budgets.json"
B3C=$(stat -c '%i %Y' "$W/catalog/context-budgets.json")
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "B3c LEGACY --compose must exit 0, got $RC: $(cat "$T/err")"
[ "$(stat -c '%i %Y' "$W/catalog/context-budgets.json")" = "$B3C" ] && ok || bad "B3c LEGACY --compose must not write the manifest"
run "$W" --compose --to "$T/b3c.to"
[ "$RC" = 0 ] && cmp -s "$T/b3c.to" "$LEGACY" && ok || bad "B3c LEGACY --compose --to must copy the committed manifest, got $RC"
rm -f "$W/catalog/context-budgets.json"
run "$W" --compose
[ "$RC" = 2 ] && ok || bad "B3c no fragments and no manifest must be rc 2, got $RC"

# The negative list (plan, System invariants (c)): each of these must be
# ACCEPTED. accept <label> <want-lanes-jq> <writer...> — rc 0, valid JSON, and
# the jq test on the composed file is true.
accept() {
  local label="$1" want="$2"; shift 2
  fresh "b3n-$label"; "$@"
  run "$W" --compose
  [ "$RC" = 0 ] && ok || bad "B3n $label must be ACCEPTED (rc 0), got $RC: $(cat "$T/err")"
  jq -e "$want" "$W/catalog/context-budgets.json" >/dev/null 2>&1 && ok \
    || bad "B3n $label: the composed file must satisfy $want: $(jq -c '[.lanes[-3:][].lane]' "$W/catalog/context-budgets.json" 2>&1)"
}
na_ws()     { fragment "$W/catalog/context-budgets.d/9999-x.json" x; sed -i '$s/^]$/]   /' "$W/catalog/context-budgets.d/9999-x.json"; }
na_crlf()   { fragment "$W/catalog/context-budgets.d/9999-x.json" x; sed -i 's/$/\r/' "$W/catalog/context-budgets.d/9999-x.json"; }
na_two()    { fragment "$W/catalog/context-budgets.d/9999-x.json" x y; }
na_note()   { printf '[\n    { "lane": "x", "_note": "why", "stage": "x", "runner": null, "target_tokens": 1, "ceiling_tokens": 2 }\n]\n' > "$W/catalog/context-budgets.d/9999-x.json"; }
na_alone()  { find "$W/catalog/context-budgets.d" -name '[0-9]*.json' ! -name 0000-base.json -delete; }
na_0001()   { fragment "$W/catalog/context-budgets.d/0001-x.json" x; }
accept ws-close   '.lanes[-1].lane == "x"' na_ws
grep -c $'\]   $' "$W/catalog/context-budgets.d/9999-x.json" >/dev/null && ok || bad "B3n ws-close: the fixture must end in \"]   \""
accept crlf       '.lanes[-1].lane == "x"' na_crlf
accept two-lanes  '[.lanes[-2:][].lane] == ["x","y"]' na_two
accept note-key   '.lanes[-1]._note == "why"' na_note
accept base-alone '.lanes | length > 0' na_alone
accept frag-0001  'any(.lanes[]; .lane == "x")' na_0001

# refuse <label> <writer...> — the writer damages $W; rc 2, the old file
# stays, no temp file is left beside it.
refuse() {
  local label="$1"; shift
  fresh "b3-$label"
  "$W/bin/context-budgets-build.sh" --repo "$W" --compose >/dev/null 2>&1
  local before; before=$(sha "$W/catalog/context-budgets.json")
  [ -n "$before" ] || { bad "B3 $label: no composed file to start from"; return; }
  "$@"
  run "$W" --compose
  [ "$RC" = 2 ] && ok || bad "B3 $label must be rc 2, got $RC: $(cat "$T/err")"
  [ "$(sha "$W/catalog/context-budgets.json")" = "$before" ] && ok || bad "B3 $label must leave the old catalog/context-budgets.json as it was"
  [ -z "$(find "$W/catalog" -maxdepth 1 -name '.context-budgets*' 2>/dev/null)" ] && ok \
    || bad "B3 $label left a temp file: $(find "$W/catalog" -maxdepth 1 -name '.context-budgets*')"
  run "$W" --check
  [ "$RC" = 2 ] && ok || bad "B3 $label: --check must be rc 2 too, got $RC"
}
fpath() { printf '%s/catalog/context-budgets.d/%s' "$W" "$1"; }
w_stray()    { echo notes > "$(fpath notes.txt)"; }
w_laneint()  { printf '[\n    {"lane":1}\n]\n' > "$(fpath 0001-x.json)"; }
w_dup()      { fragment "$(fpath 0001-x.json)" "$(jq -r '.[0].lane' "$DIR/catalog/context-budgets.d/0000-base.json")"; }
w_headlanes(){ jq '. + {lanes: []}' "$(fpath _head.json)" > "$T/h.json" && cp "$T/h.json" "$(fpath _head.json)"; }
w_sharekey() { jq '. + {_key: "dup"}' "$(fpath _head.json)" > "$T/h.json" && cp "$T/h.json" "$(fpath _head.json)"; }
w_oneline()  { printf '[%s]\n' "$(lane one-line)" > "$(fpath 0001-x.json)"; }
w_notjson()  { printf '[\n    { "lane": "x",\n]\n' > "$(fpath 0001-x.json)"; }
w_notail()   { rm -f "$(fpath _tail.json)"; }
w_tailopen() { sed -i '1s/^{$/{ "_x": 1,/' "$(fpath _tail.json)"; }
w_nofrag()   { rm -f "$W"/catalog/context-budgets.d/[0-9]*.json; }
w_object()   { printf '{\n  "lane": "x"\n}\n' > "$(fpath 0001-x.json)"; }
refuse d-stray     w_stray
grep -qF 'notes.txt' "$T/err" && ok || bad "B3d the refusal must name the stray file: $(cat "$T/err")"
refuse e-laneint   w_laneint
refuse f-dup       w_dup
grep -q 'twice' "$T/err" && ok || bad "B3f a duplicate lane must be named as one: $(cat "$T/err")"
refuse g-headlanes w_headlanes
refuse h-sharekey  w_sharekey
grep -qF '_key' "$T/err" && ok || bad "B3h the refusal must name the shared key: $(cat "$T/err")"
refuse i-oneline   w_oneline
refuse notjson     w_notjson
refuse notail      w_notail
refuse tailopen    w_tailopen
refuse nofrag      w_nofrag
refuse object      w_object

# =============================================================================
# B4 --check.
# =============================================================================
fresh b4
run "$W" --compose
ST0=$(git -C "$W" status --porcelain)
run "$W" --check
[ "$RC" = 0 ] && ok || bad "B4k --check must be rc 0 with an untracked, ignored manifest, got $RC: $(cat "$T/err")"
grep -q 'composed, not committed' "$T/out" && ok || bad "B4k --check must print its status line: $(cat "$T/out")"
[ "$(git -C "$W" status --porcelain)" = "$ST0" ] && ok || bad "B4 --check must write nothing in the repo"
gitc -C "$W" add -f catalog/context-budgets.json >/dev/null; gitc -C "$W" commit -qm 'commit the render'
run "$W" --check
[ "$RC" = 1 ] && ok || bad "B4j --check must be rc 1 when catalog/context-budgets.json is tracked, got $RC: $(cat "$T/err")"
grep -qF 'move the lane into a fragment' "$T/err" && ok || bad "B4j the refusal must say to move the lane into a fragment: $(cat "$T/err")"
grep -q 'composed, not committed' "$T/out" && bad "B4j a red --check must not print the status line" || ok

# =============================================================================
# B5 idempotence and mode.
# =============================================================================
fresh b5
( umask 077; "$W/bin/context-budgets-build.sh" --repo "$W" --compose ) >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "B5 --compose must exit 0, got $RC: $(cat "$T/err")"
[ "$(stat -c '%a' "$W/catalog/context-budgets.json" 2>/dev/null)" = 644 ] && ok \
  || bad "B5 the composed manifest must be mode 644, got $(stat -c '%a' "$W/catalog/context-budgets.json" 2>&1)"
touch -d @1000000000 "$W/catalog/context-budgets.json"
B5=$(stat -c '%i %Y' "$W/catalog/context-budgets.json")
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "B5 a second --compose must exit 0, got $RC"
[ "$(stat -c '%i %Y' "$W/catalog/context-budgets.json")" = "$B5" ] && ok || bad "B5 an unchanged --compose must not rewrite the manifest"
[ ! -s "$T/out" ] && ok || bad "B5 an unchanged --compose prints nothing: $(cat "$T/out")"

# =============================================================================
# B6 + B7 bin/harness-sync.sh: the box sync and the jobs worker deploy.
# =============================================================================
H="$T/h6"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/prompts" "$H/fly" \
         "$H/catalog" "$H/checks" "$H/guardrails" "$H/config" "$H/env" "$H/fakebin"
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$H/env/cloudflare.env"
ALERTS="$H/logs/ALERTS.log"; NPXLOG="$H/npx.log"; SYNCLOG="$H/sync.log"
cat > "$H/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
H="$H"
EOF
cat >> "$H/fakebin/npx" <<'EOF'
printf '%s | %s\n' "$PWD" "$*" >> "$NPX_LOG"
if [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "deploy" ] && [ -f "$PWD/../../catalog/context-budgets.json" ]; then
  cp "$PWD/../../catalog/context-budgets.json" "$H/deployed-budgets-$(basename "$PWD").json"
fi
exit 0
EOF
chmod +x "$H/fakebin/npx"
# The budget DB sync stub: records which lanes it was handed.
cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
[ "\$1" = catalog-sync ] && jq -r '.lanes[-1].lane' "\$2" >> "$SYNCLOG"
exit 0
EOF
chmod +x "$H/bin/jobs-client.sh"
if ! command -v rsync >/dev/null; then
  cat > "$H/fakebin/rsync" <<'EOF'
#!/bin/bash
paths=()
for a in "$@"; do case "$a" in -*) ;; *) paths+=("$a") ;; esac; done
SRC="${paths[0]:-}"; DST="${paths[1]:-}"
[ -d "$SRC" ] && [ -n "$DST" ] || exit 0
mkdir -p "$DST" && cp -a "$SRC". "$DST" 2>/dev/null
exit 0
EOF
  chmod +x "$H/fakebin/rsync"
fi
gitc init -q --bare "$H/origin"
git clone -q "$H/origin" "$H/ck" 2>/dev/null
git -C "$H/ck" config user.email t@t; git -C "$H/ck" config user.name t
CK="$H/ck"
mkdir -p "$CK/bin" "$CK/prompts" "$CK/fly" "$CK/catalog" "$CK/worker/jobs/src/routes"
printf '#!/bin/bash\n:\n' > "$CK/bin/x.sh"
scratch_install_closure bin/context-budgets-build.sh "$CK" >/dev/null || { echo "closure install failed"; exit 1; }
chmod 755 "$CK/bin/context-budgets-build.sh"
cp -r "$DIR/catalog/context-budgets.d" "$CK/catalog/context-budgets.d" 2>/dev/null
printf 'catalog/context-budgets.json\n' > "$CK/.gitignore"
printf 'p\n' > "$CK/prompts/p.md"; printf 'f\n' > "$CK/fly/f.txt"; printf 'fleet\n' > "$CK/fleet.conf"
cat > "$CK/worker/jobs/wrangler.jsonc" <<'EOF'
{ "name": "jobs-test", "main": "src/index.js" }
EOF
printf 'import BUDGETS from "../../../../catalog/context-budgets.json" with { type: "json" };\nexport default BUDGETS;\n' \
  > "$CK/worker/jobs/src/routes/llm-sites.js"
git -C "$CK" add -A >/dev/null; git -C "$CK" commit -qm seed
git -C "$CK" branch -M main 2>/dev/null; git -C "$CK" push -q origin main
git -C "$CK" branch --set-upstream-to=origin/main main >/dev/null 2>&1
sync6() {
  ( export HARNESS="$H" HARNESS_CHECKOUT="$CK" PATH="$H/fakebin:$PATH"
    bash "$DIR/bin/harness-sync.sh" ) >"$H/out.txt" 2>"$H/err.txt"
  RC=$?
}
# SAFETY PROBE first: a dirty checkout must refuse at rc 30 into $HARNESS, or
# the deploy path below would rsync this fixture over the live /root/harness.
echo probe >> "$CK/bin/x.sh"
sync6
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  bad "B6 bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — the deploy cases are not run"
else
  ok
  git -C "$CK" checkout -q -- bin/x.sh; : > "$ALERTS"; : > "$NPXLOG"
  sync6
  [ "$RC" = 0 ] && ok || bad "B6 a clean deploy must exit 0, got $RC: $(tail -5 "$H/err.txt")"
  [ "$(grep -cF 'wrangler deploy' "$NPXLOG")" = 1 ] && ok || bad "B6 worker jobs must deploy once: $(cat "$NPXLOG")"
  "$CB" --repo "$CK" --compose --to "$H/want.json" >/dev/null 2>&1
  cmp -s "$H/deployed-budgets-jobs.json" "$H/want.json" && ok \
    || bad "B6 the deploy snapshot must hold catalog/context-budgets.json composed from the fragments before wrangler runs ($( [ -f "$H/deployed-budgets-jobs.json" ] && echo differs || echo missing))"
  case "$(cat "$H/state/worker-deployed-jobs" 2>/dev/null)" in
    *-budgets-*) ok ;;
    *) bad "B6 the jobs deploy stamp must carry the -budgets-<sha> key: $(cat "$H/state/worker-deployed-jobs" 2>/dev/null)" ;;
  esac
  cmp -s "$CK/catalog/context-budgets.json" "$H/want.json" && ok \
    || bad "B6 the default sync must compose catalog/context-budgets.json in the checkout"
  cmp -s "$H/catalog/context-budgets.json" "$H/want.json" && ok \
    || bad "B6 the default sync must rsync the composed manifest into \$HARNESS/catalog"
  [ ! -s "$ALERTS" ] && ok || bad "B6 a clean compose writes no ALERT: $(cat "$ALERTS")"
  # B7: the first sync pushed the manifest; a fragment-only commit moves the sha.
  B7BASE=$(jq -r '.lanes[-1].lane' "$H/want.json")
  [ "$(tail -n1 "$SYNCLOG" 2>/dev/null)" = "$B7BASE" ] && ok \
    || bad "B7 the first sync must hand catalog-sync the composed manifest: $(cat "$SYNCLOG" 2>/dev/null)"
  fragment "$CK/catalog/context-budgets.d/9999-x.json" x-new
  git -C "$CK" add -A >/dev/null; git -C "$CK" commit -qm x; git -C "$CK" push -q origin main
  sync6
  [ "$RC" = 0 ] && ok || bad "B7 the second sync must exit 0, got $RC"
  [ "$(tail -n1 "$SYNCLOG" 2>/dev/null)" = x-new ] && ok \
    || bad "B7 a fragment-only commit must re-push the manifest with the new lane: $(cat "$SYNCLOG" 2>/dev/null)"
  [ "$(cat "$H/state/catalog-synced" 2>/dev/null)" = "$(git -C "$CK" rev-parse HEAD)" ] && ok \
    || bad "B7 the catalog-synced stamp must move to the fragment commit"
  STAMP0=$(cat "$H/state/worker-deployed-jobs" 2>/dev/null)
  # B6: a broken fragment: one deploy ALERT, no deploy, the stamp stays.
  printf '[\n    { "lane": "broken",\n]\n' > "$CK/catalog/context-budgets.d/0001-broken.json"
  git -C "$CK" add -A >/dev/null; git -C "$CK" commit -qm broken; git -C "$CK" push -q origin main
  : > "$ALERTS"; : > "$NPXLOG"
  sync6
  [ "$(grep -c 'catalog/context-budgets.d at .*deploy of jobs SKIPPED' "$ALERTS")" = 1 ] && ok \
    || bad "B6 a broken fragment must write exactly one deploy ALERT naming catalog/context-budgets.d: $(cat "$ALERTS")"
  [ "$(grep -c 'bin/context-budgets-build.sh --check' "$ALERTS")" = 2 ] && ok \
    || bad "B6 the sync compose and the deploy compose must each write one ALERT line naming the check: $(cat "$ALERTS")"
  [ "$(grep -cF 'wrangler deploy' "$NPXLOG")" = 0 ] && ok || bad "B6 a broken fragment must not deploy: $(cat "$NPXLOG")"
  [ "$(cat "$H/state/worker-deployed-jobs" 2>/dev/null)" = "$STAMP0" ] && ok || bad "B6 a broken fragment must not stamp the deploy"
  [ "$(jq -r '.lanes[-1].lane' "$CK/catalog/context-budgets.json" 2>/dev/null)" = x-new ] && ok \
    || bad "B6 a refused sync compose must leave the last good manifest in place"
  [ -z "$(find "$H/state" -maxdepth 1 -name 'worker-snap.*' 2>/dev/null)" ] && ok || bad "B6 the snapshot must be dropped after the pass"
fi

# =============================================================================
# B8 tests/lib/scratch.sh composes the manifest at source time.
# =============================================================================
R8="$T/r8"; mkdir -p "$R8/tests/lib" "$R8/catalog"
cp "$DIR/tests/lib/scratch.sh" "$R8/tests/lib/"
scratch_install_closure bin/context-budgets-build.sh "$R8" >/dev/null || { echo "closure install failed"; exit 1; }
cp -r "$DIR/catalog/context-budgets.d" "$R8/catalog/" 2>/dev/null
rm -f "$R8/catalog/context-budgets.json"
( . "$R8/tests/lib/scratch.sh" ) >"$T/b8.out" 2>"$T/b8.err"; B8RC=$?
[ "$B8RC" = 0 ] && ok || bad "B8 sourcing scratch.sh must return 0, got $B8RC: $(cat "$T/b8.err")"
"$CB" --repo "$R8" --compose --to "$T/b8.want" >/dev/null 2>&1
[ -f "$R8/catalog/context-budgets.json" ] && cmp -s "$R8/catalog/context-budgets.json" "$T/b8.want" && ok \
  || bad "B8 sourcing scratch.sh must compose catalog/context-budgets.json"
[ ! -s "$T/b8.err" ] && ok || bad "B8 a good compose prints nothing: $(cat "$T/b8.err")"
R8B="$T/r8b"; mkdir -p "$R8B/tests/lib" "$R8B/catalog"
cp "$DIR/tests/lib/scratch.sh" "$R8B/tests/lib/"
scratch_install_closure bin/context-budgets-build.sh "$R8B" >/dev/null || { echo "closure install failed"; exit 1; }
( . "$R8B/tests/lib/scratch.sh" ) >"$T/b8b.out" 2>"$T/b8b.err"; B8RC=$?
[ "$B8RC" = 0 ] && [ ! -e "$R8B/catalog/context-budgets.json" ] && [ ! -s "$T/b8b.err" ] && ok \
  || bad "B8 a tree with no context-budgets.d gets no file and no stderr (rc $B8RC): $(cat "$T/b8b.err")"
printf '[\n    { "lane": "broken",\n]\n' > "$R8/catalog/context-budgets.d/0001-broken.json"
( . "$R8/tests/lib/scratch.sh"; echo after-source ) >"$T/b8c.out" 2>"$T/b8c.err"; B8RC=$?
[ "$B8RC" = 0 ] && grep -q after-source "$T/b8c.out" && ok || bad "B8 a broken fragment must not stop the suite (rc $B8RC)"
[ "$(grep -c '^scratch.sh: catalog/context-budgets.json could not be composed' "$T/b8c.err")" = 1 ] && ok \
  || bad "B8 a broken fragment must print the one scratch.sh line: $(cat "$T/b8c.err")"

# =============================================================================
# B9 the worker's production import loads the composed manifest.
# =============================================================================
if command -v node >/dev/null 2>&1 && node -e 'process.exit(Number(process.versions.node.split(".")[0])>=22?0:1)'; then
  "$CB" --repo "$DIR" --compose >/dev/null 2>"$T/b9.err" || bad "B9 --compose on the repo failed: $(cat "$T/b9.err")"
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1
  "$DIR/bin/llm-sites-build.sh" --repo "$DIR" --compose >/dev/null 2>&1
  if (cd "$DIR" && node -e 'import("./worker/jobs/src/routes/llm-sites.js").then(m=>process.exit(Array.isArray(m.routes)?0:1),e=>{console.error(e.message);process.exit(2)})') 2>"$T/b9.err"; then
    ok
  else
    bad "B9 worker/jobs/src/routes/llm-sites.js must load with the composed manifest: $(cat "$T/b9.err")"
  fi
else
  echo "context-budgets-fragments: B9 SKIPPED — no node >= 22 (JSON import attributes)"
fi

# =============================================================================
# B10 test selection follows a fragment-only diff.
# =============================================================================
printf 'catalog/context-budgets.d/9999-x.json\n' > "$T/b10.changed"
TI_OUT=$("$DIR/bin/test-impact.sh" --root "$DIR" select --changed "$T/b10.changed" --map-only --why 2>"$T/b10.err"); TRC=$?
[ "$TRC" = 0 ] && ok || bad "B10 test-impact select must exit 0, got $TRC: $(head -5 "$T/b10.err")"
# The alias is the proof: the suite is picked BECAUSE of the composed path.
grep -qE $'^tests/context-budget-manifest-test\\.sh\t[a-z]+\tcatalog/context-budgets\\.json$' <<<"$TI_OUT" && ok \
  || bad "B10 a fragment-only diff must select tests/context-budget-manifest-test.sh through catalog/context-budgets.json: $(grep -F 'context-budget' <<<"$TI_OUT" | head -3)"

# =============================================================================
# B11 bin/rules-pack.sh composes a judged tree with ITS OWN trusted composer.
# =============================================================================
B11F=$(sed -n '/^rp_lanes_render() {$/,/^}$/p' "$DIR/bin/rules-pack.sh")
if [ -z "$B11F" ]; then
  bad "B11 bin/rules-pack.sh has no rp_lanes_render() to drive"
else
  B11R="$T/b11root" B11J="$T/b11judged"
  mkdir -p "$B11R/bin" "$B11J/bin" "$B11J/catalog/context-budgets.d" "$T/b11w"
  printf '#!/bin/bash\necho trusted > "%s/trusted.ran"\n' "$T" > "$B11R/bin/context-budgets-build.sh"
  printf '#!/bin/bash\necho judged > "%s/judged.ran"\n' "$T" > "$B11J/bin/context-budgets-build.sh"
  chmod +x "$B11R/bin/context-budgets-build.sh" "$B11J/bin/context-budgets-build.sh"
  : > "$B11J/catalog/lanes.json"   # only the budgets compose is under test
  ( ROOT="$B11R" W="$T/b11w"; eval "$B11F"; rp_lanes_render "$B11J" )
  [ -e "$T/trusted.ran" ] && ok || bad "B11 rp_lanes_render must run \$ROOT/bin/context-budgets-build.sh on a tree with fragments and no manifest"
  [ ! -e "$T/judged.ran" ] && ok || bad "B11 rp_lanes_render ran the judged tree's own bin/context-budgets-build.sh"
fi

# =============================================================================
# B12 bin/prequeue-worker-schema.sh composes before node runs.
# =============================================================================
P="$T/b12"; mkdir -p "$P/catalog" "$P/worker/jobs/test" "$P/fakebin"
scratch_install_closure bin/prequeue-worker-schema.sh "$P" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/context-budgets-build.sh "$P" >/dev/null || { echo "closure install failed"; exit 1; }
cp -r "$DIR/catalog/context-budgets.d" "$P/catalog/" 2>/dev/null
: > "$P/worker/jobs/test/x.test.js"
printf '#!/bin/bash\nexit 0\n' > "$P/fakebin/npm"
cat > "$P/fakebin/node" <<EOF
#!/bin/bash
if [ -f ../../catalog/context-budgets.json ]; then echo present > "$T/b12.node"; else echo absent > "$T/b12.node"; fi
printf 'ok 1 - x\n# pass 1\n# skipped 0\n'
EOF
chmod +x "$P/fakebin/npm" "$P/fakebin/node"
( PATH="$P/fakebin:$PATH" bash "$P/bin/prequeue-worker-schema.sh" worker/jobs/test/x.test.js ) >"$T/b12.out" 2>&1; PRC=$?
[ "$PRC" = 0 ] && ok || bad "B12 prequeue-worker-schema.sh must exit 0 on the fixture, got $PRC: $(tail -3 "$T/b12.out")"
[ "$(cat "$T/b12.node" 2>/dev/null)" = present ] && ok \
  || bad "B12 catalog/context-budgets.json must exist when node runs: $(cat "$T/b12.node" 2>/dev/null || echo 'node never ran')"

echo "context-budgets-fragments.bh-6487: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
