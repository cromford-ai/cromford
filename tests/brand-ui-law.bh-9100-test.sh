#!/bin/bash
# tests/brand-ui-law.bh-9100-test.sh — BH-9100: when a repo declares a brand
# file, the plan, execute, fix, review and lead-review stages carry the brand
# law (prompts/iron-laws.d/20261105-brand-ui.md) with the file's path, through
# bin/lib/brand-ui-law.sh and bin/agent-call.sh. A repo with no file keeps
# today's system append and records one note.
#
#   B1  bul_text prints the law for every brand stage; the stage list is read
#       from the brand-stages: line; no placeholder and no [BLOCK tag is left
#   B2  driven: plan and review of a UI diff carry the title and the path, for
#       two projects; no note is written
#   B3  driven: no brand file = the append is the sil_text append byte for byte;
#       B3b two calls into one out dir leave one note line
#   B4  driven: the path setting (project row, fleet row, no row, outage, env)
#   B5  the review UI decision table (HIT / MISS / UNKNOWN, prompt and git list)
#   B6  non-brand stages print nothing; sil_text does not read the brand file;
#       the prototype law file is unchanged
#   B7  an invalid path setting falls back to the default with one stderr line
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS
# with a fake claude; what the CLI was handed is read back.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/bin/lib/stage-iron-laws.sh" || { echo "FAIL: bin/lib/stage-iron-laws.sh missing"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LAWS_DIR="$DIR/prompts/iron-laws.d"
LAW_FILE="$LAWS_DIR/20261105-brand-ui.md"
TITLE='BRAND RULES (iron law, BH-9100'
DEF='docs/claude/brand-ui.md'
BRAND_STAGES="plan execute fix review lead-review"
# No git lookup may climb out of the scratch tree into a real checkout.
export GIT_CEILING_DIRECTORIES
GIT_CEILING_DIRECTORIES=$(dirname "$T")
unset BRAND_UI_FILE BRAND_UI_GLOBS AGENT_CALL_REPO_DIR AGENT_CALL_DIFF_BASE
export REPOS_ROOT="$T/repos"

# Repo fixtures: one with the default file, one with none, one with the file at
# a setting path only.
mk_repo() { mkdir -p "$T/repos/$1"; [ -z "${2:-}" ] || { mkdir -p "$T/repos/$1/$(dirname "$2")"; echo "# brand" > "$T/repos/$1/$2"; }; }
mk_repo project-3 "$DEF"
mk_repo sample-project "$DEF"
mk_repo bare
mk_repo custom design/brand.md

# Fake setting_get: $T/settings.tsv is key<TAB>value; $T/settings.outage = rc 1.
SETTINGS_TSV="$T/settings.tsv"; : > "$SETTINGS_TSV"
fake_setting_get_src() {
  cat <<EOF
setting_get() {
  [ -e "$T/settings.outage" ] && return 1
  local v
  v=\$(awk -F'\t' -v k="\$1" '\$1 == k { print \$2; f=1 } END { exit f ? 0 : 1 }' "$SETTINGS_TSV") || return 2
  printf '%s' "\$v"
}
EOF
}
set_row() { printf '%s\t%s\n' "$1" "$2" >> "$SETTINGS_TSV"; }
clear_rows() { : > "$SETTINGS_TSV"; rm -f "$T/settings.outage"; }

# Unit harness: a subshell that sources the lib with the fake setting_get.
# It runs in $T/nogit unless the caller cds first: the checkout's own git
# state must never decide a case.
mkdir -p "$T/u" "$T/nogit"
fake_setting_get_src > "$T/u/setting-get.sh"
bul() { # bul <stage> <project> <prompt> <out> [laws-dir]  (stdout = bul_text)
  mkdir -p "$(dirname "$4")"
  ( case "$PWD/" in "$T"/*) ;; *) cd "$T/nogit" || exit 1 ;; esac
    . "$T/u/setting-get.sh" || exit 1
    . "$DIR/bin/lib/brand-ui-law.sh" || exit 1
    bul_text "$1" "$2" "$3" "$4" "${5:-$LAWS_DIR}" )
}
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# ── B1 ─────────────────────────────────────────────────────────────────────
echo "--- B1"
[ "$(head -1 "$LAW_FILE")" = "brand-stages: $BRAND_STAGES" ] && ok || bad "B1 law file line 1 is not the brand-stages line"
for st in $BRAND_STAGES; do
  out=$(bul "$st" project-3 "" "$T/u/o-$st/out.txt" 2>/dev/null)
  has "$out" "$TITLE" && ok || bad "B1 $st: title missing: '${out:0:80}'"
  has "$out" "\`$DEF\`" && ok || bad "B1 $st: path missing"
  has "$out" '{{BRAND_UI_FILE}}' && bad "B1 $st: placeholder left" || ok
  has "$out" '[BLOCK ' && bad "B1 $st: law names a [BLOCK tag" || ok
  has "$out" '## Brand tokens' && ok || bad "B1 $st: PLAN brand tokens line missing"
  has "$out" 'is a `[NOTE]`' && ok || bad "B1 $st: review NOTE line missing"
  has "$out" 'brand-stages:' && bad "B1 $st: header line leaked into the body" || ok
done
FXL="$T/fxlaws"; mkdir -p "$FXL"
printf 'brand-stages: plan qa\r\n\r\nFX BODY {{BRAND_UI_FILE}} and {{BRAND_UI_FILE}}\r\n' > "$FXL/20261105-brand-ui.md"
[ "$(bul qa project-3 "" "$T/u/fx/out.txt" "$FXL")" = "FX BODY $DEF and $DEF" ] && ok \
  || bad "B1 a stage added to the brand-stages line must be honoured (CRLF stripped): '$(bul qa project-3 "" "$T/u/fx/out.txt" "$FXL")'"
[ -z "$(bul execute project-3 "" "$T/u/fx/out.txt" "$FXL")" ] && ok || bad "B1 a stage dropped from the line must print nothing"

# ── B5 ─────────────────────────────────────────────────────────────────────
echo "--- B5"
dg() { printf 'review this\ndiff --git a/%s b/%s\n+x\n' "$1" "$1"; }
HITS="src/components/Nav.tsx app/bookings/page.tsx styles/app.scss src/app/globals.css packages/ui/Button.jsx"
MISSES="bin/run-build.sh src/lib/bookings.ts apps/web/x.ts docs/ui.md README.md prisma/schema.prisma tests/ui.test.ts catalog/ui-paths.tsv"
for st in review lead-review; do
  for p in $HITS; do
    out=$(cd "$T/nogit" && bul "$st" project-3 "$(dg "$p")" "$T/u/b5/out.txt" 2>/dev/null)
    has "$out" "$TITLE" && ok || bad "B5 $st HIT $p: no rule"
  done
  for p in $MISSES; do
    rm -rf "$T/u/b5m"
    out=$(cd "$T/nogit" && bul "$st" project-3 "$(dg "$p")" "$T/u/b5m/out.txt" 2>/dev/null)
    [ -z "$out" ] && ok || bad "B5 $st MISS $p: rule printed"
    [ ! -e "$T/u/b5m/brand-ui-note.txt" ] && ok || bad "B5 $st MISS $p: a note was written"
  done
  mixed="$(for i in 1 2 3 4 5 6 7 8 9 10; do dg "bin/s$i.sh"; done; dg src/x/Card.tsx)"
  has "$(cd "$T/nogit" && bul "$st" project-3 "$mixed" "$T/u/b5/out.txt")" "$TITLE" && ok || bad "B5 $st: one .tsx among ten .sh must hit"
  # UNKNOWN: no diff in the prompt, cwd not a git tree.
  has "$(cd "$T/nogit" && bul "$st" project-3 "no diff here" "$T/u/b5/out.txt")" "$TITLE" && ok || bad "B5 $st UNKNOWN (no git): rule must be included"
done
# The git fallback: a branch adding a page vs a branch adding a script.
G="$T/gitrepo"; mkdir -p "$G"
( cd "$G" && git init -q -b main . && git config user.email t@example.com && git config user.name t \
  && echo a > README.md && git add . && git commit -qm init \
  && git checkout -qb ui && mkdir -p app/x && echo p > app/x/page.tsx && git add . && git commit -qm ui \
  && git checkout -qb sh main && mkdir -p bin && echo s > bin/x.sh && git add . && git commit -qm sh \
  && git checkout -qb same main ) >/dev/null 2>&1 || bad "B5 setup: scratch git repo"
gb() { ( cd "$G" && git checkout -q "$1" && AGENT_CALL_DIFF_BASE=main bul "$2" project-3 "no diff here" "$T/u/b5g/out.txt" 2>/dev/null ); }
for st in review lead-review; do
  has "$(gb ui "$st")" "$TITLE" && ok || bad "B5 $st git: app/x/page.tsx must hit"
  [ -z "$(gb sh "$st")" ] && ok || bad "B5 $st git: bin/x.sh only must miss"
  has "$(gb same "$st")" "$TITLE" && ok || bad "B5 $st git: an empty diff is UNKNOWN, rule included"
done
# Plan, execute and fix are not gated on the diff.
for st in plan execute fix; do
  has "$(cd "$T/nogit" && bul "$st" project-3 "$(dg bin/run-build.sh)" "$T/u/b5/out.txt")" "$TITLE" && ok || bad "B5 $st must carry the rule even for a non-UI diff"
done
# The globs knob: env, then the row.
has "$(cd "$T/nogit" && BRAND_UI_GLOBS='*.sh' bul review project-3 "$(dg bin/run-build.sh)" "$T/u/b5/out.txt")" "$TITLE" && ok || bad "B5 env BRAND_UI_GLOBS must be used"
clear_rows; set_row ui.brand_ui_globs '*.prisma'
has "$(cd "$T/nogit" && bul review project-3 "$(dg prisma/schema.prisma)" "$T/u/b5/out.txt")" "$TITLE" && ok || bad "B5 row ui.brand_ui_globs must be used"
[ -z "$(cd "$T/nogit" && bul review project-3 "$(dg src/components/Nav.tsx)" "$T/u/b5/out.txt")" ] && ok || bad "B5 row ui.brand_ui_globs replaces the default"
clear_rows

# ── B7 ─────────────────────────────────────────────────────────────────────
echo "--- B7"
for v in '../x.md' '/etc/x.md' 'a b.md' 'docs/../x.md'; do
  clear_rows; set_row ui.brand_file.project-3 "$v"
  err=$(bul plan project-3 "" "$T/u/b7/out.txt" 2>&1 >/dev/null)
  out=$(bul plan project-3 "" "$T/u/b7/out.txt" 2>/dev/null)
  has "$out" "\`$DEF\`" && ok || bad "B7 '$v': default path not used"
  n=$(grep -c '^brand-ui: ' <<<"$err") || true
  [ "$n" = 1 ] && ok || bad "B7 '$v': want one brand-ui: stderr line, got $n: '$err'"
done
clear_rows

# ── B6 ─────────────────────────────────────────────────────────────────────
echo "--- B6"
for st in preplan triage qa prodqa ""; do
  rm -rf "$T/u/b6"
  out=$(bul "$st" project-3 "" "$T/u/b6/out.txt"); rc=$?
  [ -z "$out" ] && [ "$rc" = 0 ] && ok || bad "B6 '$st': want nothing rc 0, got rc=$rc '${out:0:40}'"
  [ ! -e "$T/u/b6/brand-ui-note.txt" ] && ok || bad "B6 '$st': a non-brand stage wrote a note"
done
has "$(sil_text plan "$LAWS_DIR")" 'BRAND RULES' && bad "B6 sil_text read the brand law" || ok
# Blob of the 2026-10-13 law on main at 9830b1412 (ticket item 5: unchanged).
# Pinned in pieces: the share leak check reads a long bare hex run as a token.
PROTO_BLOB="242a272e854dde66""9808ffdb2c5906a7""b055612f"
[ "$(git hash-object "$LAWS_DIR/20261013-performance-prototype.md")" = "$PROTO_BLOB" ] && ok \
  || bad "B6 prompts/iron-laws.d/20261013-performance-prototype.md changed"

# ---------- fakes for the driven cases ---------------------------------------
mrs_fixture "$T" sample-project project-3 custom bare
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env" "$T/wt"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
: > "$SINK.append"; prev=""
for a in "$@"; do
  [ "$prev" = --append-system-prompt ] && printf '%s\n<<END>>\n' "$a" >> "$SINK.append"
  prev="$a"
done
echo ran > "$SINK"
cat > /dev/null
printf '{"type":"result","result":"ok","num_turns":1,"usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/alert-line.sh"
printf '#!/bin/bash\necho "fixture machine rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/iron-law-guard.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
# The deployed jobs client, reduced to the one knob reader this lib uses.
fake_setting_get_src > "$T/bin/jobs-client.sh"
echo '{}' > "$T/catalog.json"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: lanes-build.sh could not compose the registry"
mkdir -p "$T/prompts"; cp -R "$LAWS_DIR" "$T/prompts/"

# run_call <stage> <project> <prompt> <outdir> [ENV=...] — drives bin/agent-call.sh.
run_call() {
  local st="$1" pj="$2" pr="$3" od="$4"; shift 4
  rm -f "$T/sink" "$T/sink.append"; mkdir -p "$od"; rm -rf "$T/state/lane-gate" "$T/state/model-cooldown-"*
  ( cd "$T/wt" || exit 1
    export SINK="$T/sink" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" LANE_REGISTRY="$REG" \
           LADDER_BACKOFF_SECS=0 HUB_BUILD_OK=1 REPOS_ROOT="$T/repos" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" AUTH_ACCOUNTS_CATALOG="$T/catalog.json" \
           JOBS_URL=''
    for s in PREPLAN PLAN EXECUTE FIX REVIEW QA PRODQA TRIAGE LEAD_REVIEW; do export "RUNNER_$s=claude"; done
    env -u ACCOUNT_ROUTING -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u ANTHROPIC_API_KEY -u AGENT_ADVISOR_MODEL -u AGENT_ADVISOR_STAGES -u AGENT_SYSTEM_APPEND \
        -u LANE_GATE_DISABLE -u CLAUDE_CONFIG_DIR -u AGENT_CALL_NO_TOOLS \
        "$@" bash "$DIR/bin/agent-call.sh" "$st" "$pj" claude-opus-5-5 600 "$od/out.txt" "$pr" >/dev/null 2>&1 )
  [ -s "$T/sink" ] || bad "driven $st $pj: claude never ran"
}
append_has() { grep -qF -- "$1" "$T/sink.append" 2>/dev/null; }
UIDIFF="$(dg src/components/Bookings.tsx)"

# ── B2 ─────────────────────────────────────────────────────────────────────
echo "--- B2"
for pj in project-3 sample-project; do
  for st in plan review; do
    od="$T/b2/$pj-$st"
    run_call "$st" "$pj" "$UIDIFF" "$od"
    append_has "$TITLE" && ok || bad "B2 $pj $st: brand title missing from --append-system-prompt"
    append_has "\`$DEF\`" && ok || bad "B2 $pj $st: brand path missing"
    append_has 'REVIEW LEVELS (iron law, BH-7123' && ok || bad "B2 $pj $st: the sil_text laws were lost"
    [ ! -e "$od/brand-ui-note.txt" ] && ok || bad "B2 $pj $st: a note was written with the file present"
  done
done
# AGENT_CALL_REPO_DIR wins over REPOS_ROOT.
run_call plan bare "$UIDIFF" "$T/b2/env" AGENT_CALL_REPO_DIR="$T/repos/project-3"
append_has "$TITLE" && ok || bad "B2 AGENT_CALL_REPO_DIR must win over REPOS_ROOT/<project>"

# ── B3 ─────────────────────────────────────────────────────────────────────
echo "--- B3"
for st in plan execute fix review lead-review; do
  run_call "$st" bare "$UIDIFF" "$T/b3/$st"
  printf '%s\n<<END>>\n' "$(sil_text "$st" "$T/prompts/iron-laws.d")" > "$T/b3/$st.want"
  cmp -s "$T/sink.append" "$T/b3/$st.want" && ok || bad "B3 bare $st: append is not the sil_text append byte for byte"
done
OD="$T/b3/one"
run_call plan bare "$UIDIFF" "$OD"
run_call execute bare "$UIDIFF" "$OD"
n=$( { wc -l < "$OD/brand-ui-note.txt"; } 2>/dev/null) || n=0
[ "$n" = 1 ] && ok || bad "B3b want one note line, got $n"
grep -qE "^brand-ui: bare: no brand file at docs/claude/brand-ui\.md in $T/repos/bare; brand rule not applied \(BH-9100\)$" "$OD/brand-ui-note.txt" 2>/dev/null \
  && ok || bad "B3b note line format: '$(cat "$OD/brand-ui-note.txt" 2>/dev/null)'"
# No repo dir at all.
rm -rf "$T/u/b3n"
( cd "$T/nogit" && REPOS_ROOT="$T/none" bul plan ghost "" "$T/u/b3n/out.txt" >/dev/null )
grep -qx "brand-ui: ghost: no brand file at $DEF in no repo dir; brand rule not applied (BH-9100)" "$T/u/b3n/brand-ui-note.txt" 2>/dev/null \
  && ok || bad "B3b no repo dir note: '$(cat "$T/u/b3n/brand-ui-note.txt" 2>/dev/null)'"
# A directory at the path is not a brand file.
mkdir -p "$T/repos/dirrepo/$DEF"
[ -z "$(bul plan dirrepo "" "$T/u/b3d/out.txt")" ] && ok || bad "B3 a directory at the path must count as absent"

# ── B4 ─────────────────────────────────────────────────────────────────────
echo "--- B4"
clear_rows; set_row ui.brand_file.custom design/brand.md
run_call plan custom "$UIDIFF" "$T/b4/a"
append_has '`design/brand.md`' && ok || bad "B4 project row: design/brand.md missing"
append_has "\`$DEF\`" && bad "B4 project row: the default path still named" || ok
clear_rows; set_row ui.brand_file design/brand.md
run_call review custom "$UIDIFF" "$T/b4/b"
append_has '`design/brand.md`' && ok || bad "B4 fleet row: design/brand.md missing"
clear_rows; set_row ui.brand_file design/brand.md; set_row ui.brand_file.custom design/brand.md
set_row ui.brand_file.project-3 design/brand.md
run_call plan project-3 "$UIDIFF" "$T/b4/c"
append_has "$TITLE" && bad "B4 setting at a missing file (default present) must give no rule" || ok
grep -qF 'no brand file at design/brand.md' "$T/b4/c/brand-ui-note.txt" 2>/dev/null && ok || bad "B4 the note must name the setting path"
clear_rows
run_call plan project-3 "$UIDIFF" "$T/b4/d"
append_has "\`$DEF\`" && ok || bad "B4 no row (rc 2): default not used"
touch "$T/settings.outage"; set_row ui.brand_file.project-3 design/brand.md
run_call plan project-3 "$UIDIFF" "$T/b4/e"
append_has "\`$DEF\`" && ok || bad "B4 outage (rc 1): default not used"
clear_rows; set_row ui.brand_file.custom "$DEF"
run_call plan custom "$UIDIFF" "$T/b4/f" BRAND_UI_FILE=design/brand.md
append_has '`design/brand.md`' && ok || bad "B4 env BRAND_UI_FILE must win over the row"
clear_rows

echo "brand-ui-law: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
