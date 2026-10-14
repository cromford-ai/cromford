#!/bin/bash
# tests/llm-sites-fragments.bh-4987-test.sh — catalog/llm-sites.json is a
# COMPOSITION of catalog/llm-sites.d/ (BH-4987, item 4 of the RESUME list),
# built by bin/llm-sites-build.sh and never committed.
#
#   S0 the defect: two branches that each append a site to the old one-file
#      catalog conflict; this tree carries catalog/llm-sites.d/0000-base.json
#   S1 the composition equals the old file byte for byte (the split commit's
#      parent's copy)
#   S2 two branches that each add a fragment merge clean, and the composed
#      catalog and the doc carry both sites, in file-name order
#   S3 the source / tracked decision table (cases a-f) and the fragment names
#   S4 a refused fragment is rc 2, the old catalog stays, no temp file remains
#   S5 a second --compose with no change does not rewrite the file
#   S6 bin/harness-sync.sh composes the catalog into the worker deploy snapshot;
#      a broken fragment is one ALERT, no deploy, no stamp
#   S7 bin/test-impact.sh selects tests/llm-call-ratchet-test.sh for a diff that
#      only adds a fragment
#   S8 the worker's own import (llm-sites-catalog.js) loads the composed file
#   S9 the composed catalog is mode 644
#   S10 bin/rules-pack.sh composes a judged tree with its own trusted composer
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LB="$DIR/bin/llm-sites-build.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
  || { echo "llm-sites-fragments: jq/git missing — skipping"; exit 0; }

export GIT_AUTHOR_DATE="@1760000000 +0000" GIT_COMMITTER_DATE="@1760000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"
gitc() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# site <id> — one site object on one line, the shape the catalog's later sites use.
site() {
  printf '{ "id": "%s", "script": "bin/%s.sh", "marker": "agent-call.sh\\" %s fleet", "kind": "agent-call", "lane": "%s", "stage": "%s", "project": "fleet", "runners": ["claude"], "through_agent_call": true, "priced": "yes", "gated": "agent-call", "dedup": "none", "deterministic_candidate": null, "note": "fixture %s" }' \
    "$1" "$1" "$1" "$1" "$1" "$1"
}
# fragment <file> <id>... — a fragment file: `[`, one site per line, `]`.
fragment() {
  local f="$1" sep=""; shift
  { echo "["; for id in "$@"; do printf '%s    %s' "$sep" "$(site "$id")"; sep=$',\n'; done; printf '\n]\n'; } > "$f"
}
# fresh <tag> — a scratch git repo with the composer and the REAL fragments,
# the composed path git-ignored as in the repo. Sets W.
fresh() {
  W="$T/$1"; mkdir -p "$W/catalog"
  scratch_install_closure bin/llm-sites-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
  cp -r "$DIR/catalog/llm-sites.d" "$W/catalog/llm-sites.d"
  printf 'catalog/llm-sites.json\ndocs/LLM_CALL_SITES.md\n' > "$W/.gitignore"
  gitc init -q "$W"; gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm base
}
run() { local w="$1"; shift; "$w/bin/llm-sites-build.sh" --repo "$w" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# The OLD one-file catalog: the split commit's parent, or HEAD's own copy when
# HEAD still tracks it (the tree before the split). Never origin/main: it moves.
# A tree with no such history (the impact gate's isolated runner archives HEAD
# into a one-commit repo) has no old copy: S1 is then skipped, and S0 and S3c use
# the composition as their one-file catalog, which S1 proves equal where it runs.
OLD="$T/old.json"; : > "$OLD"
SPLIT=$(git -C "$DIR" log --diff-filter=A --format=%H -1 -- catalog/llm-sites.d/0000-base.json 2>/dev/null)
if [ -n "$SPLIT" ] && git -C "$DIR" cat-file -e "$SPLIT^:catalog/llm-sites.json" 2>/dev/null; then
  git -C "$DIR" show "$SPLIT^:catalog/llm-sites.json" > "$OLD"
else
  SPLIT=""
  git -C "$DIR" cat-file -e HEAD:catalog/llm-sites.json 2>/dev/null \
    && git -C "$DIR" show HEAD:catalog/llm-sites.json > "$OLD"
fi
# LEGACY — the one-file catalog the S0 and S3c fixtures start from.
LEGACY="$T/legacy.json"
if [ -s "$OLD" ]; then
  cp "$OLD" "$LEGACY"
else
  echo "llm-sites-fragments: SKIP S1 split comparison: no split commit with a parent catalog, and HEAD tracks none (a history-less tree)"
  "$LB" --repo "$DIR" --compose --to "$LEGACY" 2>/dev/null
fi
[ -s "$LEGACY" ] && ok || bad "setup: no one-file catalog: no old copy in history, and --compose --to could not build one"

# =============================================================================
# S0 THE DEFECT. Appending a site to the old file edits the last element's line
# (its comma) and inserts before the same `  ]`, so two appends conflict.
# =============================================================================
append_site() { # append_site <file> <id> — what a build did to the old file
  # ENVIRON, not -v: awk -v reads backslash escapes and would eat the \".
  S0_SITE="    $(site "$2")" awk '
    BEGIN { s = ENVIRON["S0_SITE"] }
    { line[NR] = $0 }
    END {
      for (i = NR; i > 0; i--) if (line[i] == "  ]") { close_at = i; break }
      for (i = 1; i <= NR; i++) {
        if (i == close_at - 1) print line[i] ","
        else if (i == close_at) { print s; print line[i] }
        else print line[i]
      }
    }' "$1" > "$1.new" && mv "$1.new" "$1"
}
if [ -s "$LEGACY" ]; then
  R0="$T/s0"; mkdir -p "$R0/catalog"; cp "$LEGACY" "$R0/catalog/llm-sites.json"
  gitc init -q "$R0"; gitc -C "$R0" add -A >/dev/null; gitc -C "$R0" commit -qm base
  gitc -C "$R0" checkout -qb a; append_site "$R0/catalog/llm-sites.json" site-a; gitc -C "$R0" commit -qam a
  gitc -C "$R0" checkout -q main; gitc -C "$R0" checkout -qb b; append_site "$R0/catalog/llm-sites.json" site-b; gitc -C "$R0" commit -qam b
  jq -e '.sites | length > 0' "$R0/catalog/llm-sites.json" >/dev/null 2>&1 && ok || bad "S0 the fixture append must leave valid JSON"
  if gitc -C "$R0" merge -q --no-edit a >/dev/null 2>&1; then
    bad "S0 two appends to the one-file catalog merged clean — the reproduction is wrong"
  else
    ok   # the old layout conflicts: this is the defect
  fi
fi
[ -f "$DIR/catalog/llm-sites.d/0000-base.json" ] && ok \
  || bad "S0 catalog/llm-sites.d/0000-base.json does not exist: every new site still appends to one catalog/llm-sites.json and two of them conflict"
[ -f "$DIR/catalog/llm-sites.d/_head.json" ] && ok \
  || bad "S0 catalog/llm-sites.d/_head.json does not exist"

# =============================================================================
# S1 byte for byte at the split.
# =============================================================================
"$LB" --repo "$DIR" --compose --to "$T/s1.json" >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 --compose --to must exit 0 on the repo, got $RC: $(cat "$T/err")"
if [ -n "$SPLIT" ]; then
  # Landed: the split commit's own fragments compose to its parent's file.
  S1W="$T/s1split"; mkdir -p "$S1W"
  scratch_install_closure bin/llm-sites-build.sh "$S1W" >/dev/null || { echo "closure install failed"; exit 1; }
  git -C "$DIR" archive "$SPLIT" catalog/llm-sites.d | tar -x -C "$S1W"
  "$S1W/bin/llm-sites-build.sh" --repo "$S1W" --compose --to "$T/s1.split" 2>/dev/null
  cmp -s "$T/s1.split" "$OLD" && ok \
    || bad "S1 at the split commit ${SPLIT:0:12} the fragments must compose to its parent's catalog/llm-sites.json byte for byte"
elif [ -s "$OLD" ]; then
  cmp -s "$T/s1.json" "$OLD" && ok \
    || bad "S1 the composition must equal HEAD's catalog/llm-sites.json byte for byte: $(diff "$OLD" "$T/s1.json" 2>&1 | head -5)"
fi

# =============================================================================
# S2 two branches each add a fragment: a clean merge, both sites composed.
# =============================================================================
fresh s2
# TEST-CHANGE (BH-5561 main merge): the repo now has fragments past 0000-base
# (a new site is a new file), so the count is every fragment's sites, and the
# two test fragments are numbered 9999 so they sort after every real one.
BASEN=$(cat "$W"/catalog/llm-sites.d/[0-9]*.json | jq -s 'map(length) | add')
gitc -C "$W" checkout -qb a; fragment "$W/catalog/llm-sites.d/9999-site-a.json" site-a
gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm a
gitc -C "$W" checkout -q main; gitc -C "$W" checkout -qb b; fragment "$W/catalog/llm-sites.d/9999-site-b.json" site-b
gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm b
gitc -C "$W" merge -q --no-edit a >"$T/s2.merge" 2>&1; MRC=$?
[ "$MRC" = 0 ] && ok || bad "S2 git merge of two fragment branches must exit 0, got $MRC: $(cat "$T/s2.merge")"
[ -z "$(git -C "$W" diff --name-only --diff-filter=U)" ] && ok \
  || bad "S2 no path may be left conflicted: $(git -C "$W" diff --name-only --diff-filter=U)"
run "$W"
[ "$RC" = 0 ] && ok || bad "S2 the default render after the merge must exit 0, got $RC: $(cat "$T/err")"
[ "$(jq '.sites|length' "$W/catalog/llm-sites.json" 2>/dev/null)" = "$((BASEN + 2))" ] && ok \
  || bad "S2 the composed catalog must hold $((BASEN + 2)) sites, got $(jq '.sites|length' "$W/catalog/llm-sites.json" 2>&1)"
[ "$(jq -r '.sites[-2:][].id' "$W/catalog/llm-sites.json" 2>/dev/null | tr '\n' ' ')" = "site-a site-b " ] && ok \
  || bad "S2 the two new sites must come last, in file-name order: $(jq -r '.sites[-2:][].id' "$W/catalog/llm-sites.json" 2>&1 | tr '\n' ' ')"
[ "$(jq -r '.sites[0].id' "$W/catalog/llm-sites.json")" = "$(jq -r '.[0].id' "$W/catalog/llm-sites.d/0000-base.json")" ] && ok \
  || bad "S2 the base fragment's first site must stay first"
grep -qF '`site-a`' "$W/docs/LLM_CALL_SITES.md" 2>/dev/null && grep -qF '`site-b`' "$W/docs/LLM_CALL_SITES.md" 2>/dev/null && ok \
  || bad "S2 docs/LLM_CALL_SITES.md must list both new sites"

# =============================================================================
# S3 the decision table.
# =============================================================================
# (a) fragments, no catalog on disk: --compose writes it; --check is green.
fresh s3a
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "S3a --compose must exit 0, got $RC: $(cat "$T/err")"
"$W/bin/llm-sites-build.sh" --repo "$W" --compose --to "$T/s3a.to" 2>/dev/null
cmp -s "$W/catalog/llm-sites.json" "$T/s3a.to" && ok || bad "S3a --compose must write the composition to catalog/llm-sites.json"
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S3a --check must exit 0 with an untracked, git-ignored catalog, got $RC: $(cat "$T/err")"
grep -q 'is composed, not committed' "$T/out" && ok || bad "S3a --check must print its status line: $(cat "$T/out")"
# (b) a stale untracked catalog is overwritten.
printf '{"sites":[]}\n' > "$W/catalog/llm-sites.json"
run "$W" --compose
[ "$RC" = 0 ] && cmp -s "$W/catalog/llm-sites.json" "$T/s3a.to" && ok \
  || bad "S3b --compose must overwrite a stale catalog with the composition (rc $RC)"
# (c) LEGACY: no fragments, a committed catalog: used as is, no write.
W="$T/s3c"; mkdir -p "$W/catalog"
scratch_install_closure bin/llm-sites-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$LEGACY" "$W/catalog/llm-sites.json"; touch -d @1000000000 "$W/catalog/llm-sites.json"
gitc init -q "$W"; gitc -C "$W" add -A >/dev/null; gitc -C "$W" commit -qm legacy
S3C=$(stat -c '%i %Y' "$W/catalog/llm-sites.json")
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "S3c LEGACY --compose must exit 0, got $RC: $(cat "$T/err")"
[ "$(stat -c '%i %Y' "$W/catalog/llm-sites.json")" = "$S3C" ] && ok || bad "S3c LEGACY --compose must not write the catalog"
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S3c LEGACY --check must exit 0 with a TRACKED catalog and no fragments, got $RC: $(cat "$T/err")"
grep -q 'is composed, not committed' "$T/out" && bad "S3c LEGACY --check must not claim a composition: $(cat "$T/out")" || ok
# (d) no fragments and no catalog: rc 2.
W="$T/s3d"; mkdir -p "$W/catalog"
scratch_install_closure bin/llm-sites-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
run "$W" --compose
[ "$RC" = 2 ] && ok || bad "S3d --compose with no source must be rc 2, got $RC"
# (e) fragments AND a tracked, hand-edited catalog: --check rc 1, names the fix.
fresh s3e
"$W/bin/llm-sites-build.sh" --repo "$W" --compose >/dev/null 2>&1
jq '.sites += [{"id":"hand-edit"}]' "$W/catalog/llm-sites.json" > "$T/s3e.json" && cp "$T/s3e.json" "$W/catalog/llm-sites.json"
gitc -C "$W" add -f catalog/llm-sites.json >/dev/null; gitc -C "$W" commit -qm 'hand edit'
run "$W" --check
[ "$RC" = 1 ] && ok || bad "S3e --check must be rc 1 when catalog/llm-sites.json is tracked, got $RC: $(cat "$T/err")"
grep -qF 'catalog/llm-sites.d/NNNN-<id>.json' "$T/err" && ok || bad "S3e the refusal must say to move the site into a fragment: $(cat "$T/err")"
grep -q 'is composed, not committed' "$T/out" && bad "S3e a red --check must not print the status line" || ok
# (f) tracked with the composition's exact bytes: still rc 1.
fresh s3f
"$W/bin/llm-sites-build.sh" --repo "$W" --compose >/dev/null 2>&1
gitc -C "$W" add -f catalog/llm-sites.json >/dev/null; gitc -C "$W" commit -qm 'commit the render'
run "$W" --check
[ "$RC" = 1 ] && ok || bad "S3f --check must be rc 1 for a tracked catalog even with identical bytes, got $RC"
grep -q 'is composed, not committed' "$T/out" && bad "S3f a red --check must not print the status line" || ok
# Fragment names.
fresh s3n
fragment "$W/catalog/llm-sites.d/0001-a.json" name-a
fragment "$W/catalog/llm-sites.d/0001-b.json" name-b
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "S3 names 0001-a.json and 0001-b.json must be accepted, got $RC: $(cat "$T/err")"
for n in 1-a.json 0001-A.json notes.txt 0001-a.json.bak; do
  fresh "s3n-$(echo "$n" | tr -c 'a-zA-Z0-9\n' _)"
  fragment "$W/catalog/llm-sites.d/$n" "name-$(echo "$n" | tr -c 'a-z0-9\n' -)"
  run "$W" --compose
  [ "$RC" = 2 ] && grep -qF "$n" "$T/err" && ok || bad "S3 the name $n must be refused rc 2 with its name, got $RC: $(cat "$T/err")"
  run "$W" --check
  [ "$RC" = 2 ] && ok || bad "S3 --check must be rc 2 on the bad name $n, got $RC"
  grep -q 'is composed, not committed' "$T/out" && bad "S3 a refused --check ($n) must not print the status line" || ok
done

# =============================================================================
# S4 a refused fragment: rc 2, the old catalog stays, no temp file remains.
# =============================================================================
s4() { # s4 <label> <file> <content-writer...>
  local label="$1" f="$2"; shift 2
  fresh "s4-$label"
  "$W/bin/llm-sites-build.sh" --repo "$W" --compose >/dev/null 2>&1
  local before; before=$(sha "$W/catalog/llm-sites.json")
  "$@" "$W/catalog/llm-sites.d/$f"
  run "$W" --compose
  [ "$RC" = 2 ] && ok || bad "S4 $label must be rc 2, got $RC: $(cat "$T/err")"
  [ "$(sha "$W/catalog/llm-sites.json")" = "$before" ] && ok || bad "S4 $label must leave the old catalog/llm-sites.json as it was"
  [ -z "$(find "$W/catalog" -maxdepth 1 -name '.llm-sites*' 2>/dev/null)" ] && ok \
    || bad "S4 $label left a temp file: $(find "$W/catalog" -maxdepth 1 -name '.llm-sites*')"
}
w_notjson() { printf '[\n    { "id": "x",\n]\n' > "$1"; }
w_object()  { printf '{\n  "id": "x"\n}\n' > "$1"; }
w_dupid()   { fragment "$1" "$(jq -r '.[0].id' "$DIR/catalog/llm-sites.d/0000-base.json")"; }
w_noid()    { printf '[\n    { "script": "bin/x.sh" }\n]\n' > "$1"; }
w_oneline() { printf '[%s]\n' "$(site one-line)" > "$1"; }
w_badname() { fragment "$1" bad-name; }
s4 notjson 0001-x.json w_notjson
s4 object  0001-x.json w_object
s4 dupid   0001-x.json w_dupid
grep -q 'twice' "$T/err" && ok || bad "S4 a duplicate id must be named as one: $(cat "$T/err")"
s4 noid    0001-x.json w_noid
s4 oneline 0001-x.json w_oneline
s4 badname 0001-X.json w_badname

# =============================================================================
# S5 an unchanged second --compose writes nothing.
# =============================================================================
fresh s5
"$W/bin/llm-sites-build.sh" --repo "$W" --compose >/dev/null 2>&1
touch -d @1000000000 "$W/catalog/llm-sites.json"
S5=$(stat -c '%i %Y' "$W/catalog/llm-sites.json")
run "$W" --compose
[ "$RC" = 0 ] && ok || bad "S5 a second --compose must exit 0, got $RC"
[ "$(stat -c '%i %Y' "$W/catalog/llm-sites.json")" = "$S5" ] && ok || bad "S5 an unchanged --compose must not rewrite the catalog (inode/mtime moved)"
[ ! -s "$T/out" ] && ok || bad "S5 an unchanged --compose prints nothing: $(cat "$T/out")"

# =============================================================================
# S6 bin/harness-sync.sh: the worker deploy snapshot composes the catalog.
# =============================================================================
H="$T/h6"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/prompts" "$H/fly" \
         "$H/catalog" "$H/checks" "$H/guardrails" "$H/config" "$H/env" "$H/fakebin"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$H/env/cloudflare.env"
ALERTS="$H/logs/ALERTS.log"; NPXLOG="$H/npx.log"
cat > "$H/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
H="$H"
EOF
cat >> "$H/fakebin/npx" <<'EOF'
printf '%s | %s\n' "$PWD" "$*" >> "$NPX_LOG"
if [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "deploy" ] && [ -f "$PWD/../../catalog/llm-sites.json" ]; then
  cp "$PWD/../../catalog/llm-sites.json" "$H/deployed-catalog-$(basename "$PWD").json"
fi
exit 0
EOF
chmod +x "$H/fakebin/npx"
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
mkdir -p "$CK/bin" "$CK/prompts" "$CK/fly" "$CK/catalog" "$CK/worker/jobs/src/lib"
printf '#!/bin/bash\n:\n' > "$CK/bin/x.sh"
scratch_install_closure bin/llm-sites-build.sh "$CK" >/dev/null || { echo "closure install failed"; exit 1; }
chmod 755 "$CK/bin/llm-sites-build.sh"
cp -r "$DIR/catalog/llm-sites.d" "$CK/catalog/llm-sites.d"
printf 'catalog/llm-sites.json\ndocs/LLM_CALL_SITES.md\n' > "$CK/.gitignore"
printf 'p\n' > "$CK/prompts/p.md"; printf 'f\n' > "$CK/fly/f.txt"; printf 'fleet\n' > "$CK/fleet.conf"
cat > "$CK/worker/jobs/wrangler.jsonc" <<'EOF'
{ "name": "jobs-test", "main": "src/index.js" }
EOF
printf 'import CATALOG from "../../../../catalog/llm-sites.json" with { type: "json" };\nexport default CATALOG;\n' \
  > "$CK/worker/jobs/src/lib/llm-sites-catalog.js"
git -C "$CK" add -A >/dev/null; git -C "$CK" commit -qm seed
git -C "$CK" branch -M main 2>/dev/null; git -C "$CK" push -q origin main
git -C "$CK" branch --set-upstream-to=origin/main main >/dev/null 2>&1
sync6() {
  ( export HARNESS="$H" HARNESS_CHECKOUT="$CK" PATH="$H/fakebin:$PATH"
    bash "$DIR/bin/harness-sync.sh" ) >"$H/out.txt" 2>"$H/err.txt"
  RC=$?
}
# SAFETY PROBE first (from schema-compose-deploy.bh-6005-0): a dirty checkout
# must refuse at rc 30 into $HARNESS, or the deploy path below would rsync this
# fixture over the live /root/harness.
echo probe >> "$CK/bin/x.sh"
sync6
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  bad "S6 bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — the deploy cases are not run"
else
  ok
  git -C "$CK" checkout -q -- bin/x.sh; : > "$ALERTS"; : > "$NPXLOG"
  sync6
  [ "$RC" = 0 ] && ok || bad "S6 a clean deploy must exit 0, got $RC: $(tail -5 "$H/err.txt")"
  [ "$(grep -cF 'wrangler deploy' "$NPXLOG")" = 1 ] && ok || bad "S6 worker jobs must deploy once: $(cat "$NPXLOG")"
  "$LB" --repo "$CK" --compose --to "$H/want.json" >/dev/null 2>&1
  cmp -s "$H/deployed-catalog-jobs.json" "$H/want.json" && ok \
    || bad "S6 the deploy snapshot must hold catalog/llm-sites.json composed from the fragments before wrangler runs ($( [ -f "$H/deployed-catalog-jobs.json" ] && echo differs || echo missing))"
  case "$(cat "$H/state/worker-deployed-jobs" 2>/dev/null)" in
    *-sites-*) ok ;;
    *) bad "S6 the jobs deploy stamp must carry the -sites-<sha> key: $(cat "$H/state/worker-deployed-jobs" 2>/dev/null)" ;;
  esac
  [ ! -s "$ALERTS" ] && ok || bad "S6 a clean compose writes no ALERT: $(cat "$ALERTS")"
  STAMP0=$(cat "$H/state/worker-deployed-jobs" 2>/dev/null)
  # A broken fragment: one ALERT, no deploy, the stamp stays.
  printf '[\n    { "id": "broken",\n]\n' > "$CK/catalog/llm-sites.d/0001-broken.json"
  git -C "$CK" add -A >/dev/null; git -C "$CK" commit -qm broken; git -C "$CK" push -q origin main
  : > "$ALERTS"; : > "$NPXLOG"
  sync6
  [ "$(grep -c 'llm-sites' "$ALERTS")" = 1 ] && ok || bad "S6 a broken fragment must write exactly one llm-sites ALERT line: $(cat "$ALERTS")"
  [ "$(grep -cF 'wrangler deploy' "$NPXLOG")" = 0 ] && ok || bad "S6 a broken fragment must not deploy: $(cat "$NPXLOG")"
  [ "$(cat "$H/state/worker-deployed-jobs" 2>/dev/null)" = "$STAMP0" ] && ok || bad "S6 a broken fragment must not stamp the deploy"
  [ -z "$(find "$H/state" -maxdepth 1 -name 'worker-snap.*' 2>/dev/null)" ] && ok || bad "S6 the snapshot must be dropped after the pass"
fi

# =============================================================================
# S7 test selection follows a fragment-only diff.
# =============================================================================
printf 'catalog/llm-sites.d/0001-x.json\n' > "$T/s7.changed"
TI_OUT=$("$DIR/bin/test-impact.sh" --root "$DIR" select --changed "$T/s7.changed" --map-only --why 2>"$T/s7.err"); TRC=$?
[ "$TRC" = 0 ] && ok || bad "S7 test-impact select must exit 0, got $TRC: $(head -5 "$T/s7.err")"
grep -q '^tests/llm-call-ratchet-test\.sh'$'\t' <<<"$TI_OUT" && ok \
  || bad "S7 a diff that only adds a fragment must select tests/llm-call-ratchet-test.sh (got $(cut -f1 <<<"$TI_OUT" | sort -u | grep -c .) suites)"
# The ratchet suite is also an always-suite, so the proof of the alias is the
# WHY: the readers of the composed path are picked BECAUSE of that path.
grep -q $'^tests/archie-learning\.bh-4066-test\.sh\treads\tcatalog/llm-sites\.json$' <<<"$TI_OUT" && ok \
  || bad "S7 a fragment-only diff must select the composed catalog's readers through catalog/llm-sites.json: $(grep -F 'llm-sites' <<<"$TI_OUT" | head -3)"

# =============================================================================
# S8 the worker's production import loads the composed catalog.
# =============================================================================
if command -v node >/dev/null 2>&1; then
  "$LB" --repo "$DIR" --compose >/dev/null 2>"$T/s8.err" || bad "S8 --compose on the repo failed: $(cat "$T/s8.err")"
  WANT=$(jq '.sites|length' "$DIR/catalog/llm-sites.json")
  [ "$WANT" -ge 49 ] 2>/dev/null && ok || bad "S8 the composed catalog must carry at least the 49 split sites, got $WANT"
  if (cd "$DIR" && node -e 'import("./worker/jobs/src/lib/llm-sites-catalog.js").then(m=>process.exit(m.LLM_SITES.length===Number(process.argv[1])?0:1),e=>{console.error(e.message);process.exit(2)})' "$WANT") 2>"$T/s8.err"; then
    ok
  else
    bad "S8 worker/jobs/src/lib/llm-sites-catalog.js must load $WANT sites: $(cat "$T/s8.err")"
  fi
else
  echo "llm-sites-fragments: S8 SKIPPED — node is not installed"
fi

# =============================================================================
# S9 the composed catalog is 0644, not mktemp's 0600: a root compose into a
# nobody snapshot (bin/rules-pack.sh --runner isolated) must stay readable.
# =============================================================================
fresh s9
( umask 077; "$W/bin/llm-sites-build.sh" --repo "$W" --compose ) >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "S9 --compose must exit 0, got $RC: $(cat "$T/err")"
[ "$(stat -c '%a' "$W/catalog/llm-sites.json" 2>/dev/null)" = 644 ] && ok \
  || bad "S9 the composed catalog must be mode 644, got $(stat -c '%a' "$W/catalog/llm-sites.json" 2>&1)"

# =============================================================================
# S10 bin/rules-pack.sh composes a judged tree with ITS OWN trusted composer,
# never the tree's copy (that runs as root, outside the nobody sandbox).
# =============================================================================
S10F=$(sed -n '/^rp_lanes_render() {$/,/^}$/p' "$DIR/bin/rules-pack.sh")
if [ -z "$S10F" ]; then
  bad "S10 bin/rules-pack.sh has no rp_lanes_render() to drive"
else
  S10R="$T/s10root" S10J="$T/s10judged"
  mkdir -p "$S10R/bin" "$S10J/bin" "$S10J/catalog/llm-sites.d" "$T/s10w"
  printf '#!/bin/bash\necho trusted > "%s/trusted.ran"\n' "$T" > "$S10R/bin/llm-sites-build.sh"
  printf '#!/bin/bash\necho judged > "%s/judged.ran"\n' "$T" > "$S10J/bin/llm-sites-build.sh"
  chmod +x "$S10R/bin/llm-sites-build.sh" "$S10J/bin/llm-sites-build.sh"
  : > "$S10J/catalog/lanes.json"   # skip the lanes render: only the compose is under test
  ( ROOT="$S10R" W="$T/s10w"; eval "$S10F"; rp_lanes_render "$S10J" )
  [ -e "$T/trusted.ran" ] && ok || bad "S10 rp_lanes_render must run \$ROOT/bin/llm-sites-build.sh on a tree with fragments and no catalog"
  [ ! -e "$T/judged.ran" ] && ok || bad "S10 rp_lanes_render ran the judged tree's own bin/llm-sites-build.sh as this user (root on the hub)"
fi

echo "llm-sites-fragments.bh-4987: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
