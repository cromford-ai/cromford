#!/bin/bash
# tests/ci-batch-escalate-select.bh-7287-test.sh — a merge-queue batch that
# touches a test-infra path runs that path's own suites plus a fixed canary
# list, mode=infra, instead of the whole corpus (BH-7287, BH-7033.1).
#
# WHY. catalog/ci-batch-escalate.tsv had 24 escalate rows. 21 of them were the
# planner, the selector, the runners and tests/lib/scratch.sh, so every batch
# that touched one ran all ~2,500 suites. Those rows are now kind `infra`: the
# batch runs the self and reads suites of each infra path (bin/test-impact.sh
# select --why --map-only), the 40 suites of catalog/ci-infra-canary.txt, and
# the normal selection of the batch's other paths (always set included). Only
# .github/ (not a top-level workflow), .mergify.yml and a DELETE of a row from
# the rules file still escalate.
#
# The real bin/ci-plan.sh and the real bin/test-impact.sh drive the S cases;
# the map is built once and handed to test-impact through a wrapper. U and R
# run in a scratch git repo, so cbe_deletes_row reads a real `git diff -U0`.
#
#   S1  tests/lib/scratch.sh: mode=infra, list = self/reads + canaries + always
#   S2  .mergify.yml: full, `selection input: .mergify.yml`
#   S3  a non-workflow .github/ path: full; a top-level workflow: not full
#   S4  every infra row of the rules: mode=infra
#   S5  CI_FULL_TRIGGERS=+tests/lib/scratch.sh: full (escalate beats infra)
#   S6  an infra path plus an unmapped path, union off (BH-7290): full, `unmapped: <p>`
#   S7  an infra path plus an ordinary path: infra, the other path's suites kept
#   S8  a shard re-plan (--expect-n) of S1 agrees
#   C1-C5 a canary list that is missing, names a missing suite, has a glob,
#       has a `..` or is empty: full, `infra canary list unreadable (...)`
#   F1  the infra select fails: rc 2, no n= written
#   U1-U12 cbe_deletes_row and cbe_infra units
#   R1-R3 a rules fragment in a batch: add-only selects, a delete is full, a
#       why edit is infra
#   G1  the infra rows answer cbe_infra, not cbe_reason; 4 escalate rows left
#   G2  the canary list: 40 suites, unique, present, never nightly or guard
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
CANARY="$DIR/catalog/ci-infra-canary.txt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
cbe() { ( . "$LIB" || exit 9; cbe_reason "$1" ); }
# rc 9 when the function does not exist, so neither rc 0 nor rc 1 can pass by accident
cbi() { ( . "$LIB" || exit 9; command -v cbe_infra > /dev/null || exit 9; cbe_infra "$1" ); }
# The real rules, composed from catalog/ci-batch-escalate.d/ (BH-8649: the old
# single file is retired).
TSV="$T/composed.tsv"
[ -d "$DIR/catalog/ci-batch-escalate.d" ] && ( . "$LIB" && unset CI_BATCH_ESCALATE_TSV && cbe_rules "$DIR" ) > "$TSV" \
  && grep -q $'\tescalate\t' "$TSV" \
  || { echo "FAIL: cannot compose the real rules"; exit 1; }
canaries() { grep -vE '^[[:space:]]*(#|$)' "$CANARY" 2>/dev/null; }
# sample <pattern> — one concrete path the row matches
sample() {
  case "$1" in
    */) printf '%szz-bh7287.txt\n' "$1" ;;
    *) printf '%s\n' "${1//\*/}" ;;
  esac
}

# The 15 paths the ticket names, and the 6 rows D3 of the plan moves with them.
TICKET_PATHS=(tests/lib/scratch.sh bin/test-impact.sh bin/test-impact-gate.sh bin/ci-plan.sh bin/test-tiers.sh
  bin/lib/suite-runner.sh bin/test-suite-run.sh bin/test-trace-safety.sh bin/run-tests-in-docker.sh
  bin/lib/docker-host.sh bin/lib/env-path.sh bin/lib/test-image-node.sh bin/suite-reuse.sh
  bin/lib/suite-fingerprint.sh bin/lib/train-shape.sh bin/lib/test-protected.sh
  bin/lib/ci-batch-escalate.sh catalog/test-tiers.tsv catalog/test-quarantine-protected.txt
  catalog/nightly-strict.txt catalog/test-impact-always.txt catalog/ci-batch-regression.d/bh-6838.txt)

# ── G1. the infra rows answer cbe_infra and not cbe_reason; four escalate rows left
# (BH-8608 added the fragment folder's own row).
for p in "${TICKET_PATHS[@]}"; do
  cbi "$p"; rc=$?; [ "$rc" = 0 ] && ok || bad "G1: $p must be an infra path (cbe_infra rc=$rc)"
  r=$(cbe "$p"); rc=$?; { [ "$rc" = 1 ] && [ -z "$r" ]; } && ok || bad "G1: $p must not escalate (rc=$rc, got '$r')"
done
mapfile -t INFRA_ROWS < <(awk -F'\t' '!/^#/ && $2 == "infra" { print $1 }' "$TSV")
[ "${#INFRA_ROWS[@]}" = 23 ] && ok || bad "G1: the tsv must carry 23 infra rows (got ${#INFRA_ROWS[@]})"
for pat in ${INFRA_ROWS[@]+"${INFRA_ROWS[@]}"}; do
  p=$(sample "$pat")
  cbi "$p"; rc=$?; [ "$rc" = 0 ] && ok || bad "G1: row $pat: $p must answer cbe_infra rc 0 (rc=$rc)"
  cbe "$p" > /dev/null && bad "G1: row $pat: $p must not answer cbe_reason" || ok
done
ESC=$(awk -F'\t' '!/^#/ && $2 == "escalate" { print $1 }' "$TSV" | LC_ALL=C sort | paste -sd' ' -)
[ "$ESC" = ".github/ .mergify.yml catalog/ci-batch-escalate.d/ catalog/ci-batch-escalate.tsv" ] && ok \
  || bad "G1: the escalate rows must be exactly .github/ .mergify.yml catalog/ci-batch-escalate.d/ catalog/ci-batch-escalate.tsv (got '$ESC')"

# ── G2. the canary list: 40 suites, unique, in the tree, never dropped by the tier step.
canaries > "$T/canaries"
[ "$(grep -c . "$T/canaries")" = 40 ] && ok || bad "G2: the canary list must hold 40 suites (got $(grep -c . "$T/canaries"))"
[ "$(LC_ALL=C sort -u "$T/canaries" | grep -c .)" = "$(grep -c . "$T/canaries")" ] && ok || bad "G2: the canary list has a duplicate"
while IFS= read -r s; do
  [ -f "$DIR/$s" ] && ok || bad "G2: canary $s is not in the tree"
  awk -F'\t' -v s="$s" '$1 == s && ($2 == "nightly" || $2 == "guard") { f = 1 } END { exit !f }' "$DIR/catalog/test-tiers.tsv" \
    && bad "G2: canary $s has a nightly or guard tier row" || ok
done < "$T/canaries"

# ── The real selector, with the map built once.
"$DIR/bin/test-impact.sh" map --out "$T/map" || { echo "FAIL: the map could not be built"; exit 1; }
cat > "$T/impact.sh" <<EOF
#!/bin/bash
exec "$DIR/bin/test-impact.sh" "\$@" --map "$T/map"
EOF
chmod +x "$T/impact.sh"
"$DIR/bin/test-impact.sh" always --map "$T/map" > "$T/always" || { echo "FAIL: always set unreadable"; exit 1; }
[ -s "$T/always" ] || { echo "FAIL: the always set is empty"; exit 1; }
: > "$T/notiers.tsv"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)

# bplan <path>... [-- VAR=val ...] — one batch plan; sets RC OUT GO SUM, list in $T/list
bplan() {
  local paths=() vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do paths+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; vars=("$@")
  printf '%s\n' "${paths[@]}" > "$T/changed"
  rm -f "$T/go" "$T/list" "$T/sum"
  OUT=$(env -u GITHUB_ACTIONS -u CI_INFRA_CANARY_FILE -u CI_FULL_TRIGGERS CI_EVENT=pull_request \
          TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum" \
          ${vars[@]+"${vars[@]}"} "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null); SUM=$(cat "$T/sum" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
missing() { LC_ALL=C comm -23 <(LC_ALL=C sort -u "$1") <(LC_ALL=C sort -u "$T/list" 2>/dev/null); }
infra_ok() { # infra_ok <tag> <paths...> — mode=infra, escalation=-, under the corpus, always set and canaries carried
  local tag="$1"; shift
  bplan "$@"
  { [ "$RC" = 0 ] && [ "$(out mode)" = infra ] && [ "$(out escalation)" = - ] \
      && [ -n "$(out count)" ] && [ "$(out count)" -lt "$(out total)" ]; } && ok \
    || bad "$tag: $* must be mode=infra (rc=$RC mode=$(out mode) escalation='$(out escalation)' count=$(out count) total=$(out total)) [$(tail -3 <<<"$OUT")]"
  [ -z "$(missing "$T/always")" ] && ok || bad "$tag: the list must carry the always set"
  [ -z "$(missing "$T/canaries")" ] && ok || bad "$tag: the list must carry every canary (missing $(missing "$T/canaries" | head -2))"
}
escalates() { # escalates <tag> <expected escalation> <paths...> [-- VAR=val ...]
  local tag="$1" want="$2"; shift 2
  bplan "$@"
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "$want" ] && [ "$(out count)" = "$(out total)" ]; } && ok \
    || bad "$tag: $* must be mode=full with escalation '$want' (rc=$RC mode=$(out mode) escalation='$(out escalation)' count=$(out count) total=$(out total)) [$(tail -3 <<<"$OUT")]"
}
# selfreads <path>... — the self and reads suites test-impact gives for the paths
selfreads() {
  printf '%s\n' "$@" > "$T/sr.changed"
  TI_BATCH_SELECT=1 "$T/impact.sh" select --why --map-only --changed "$T/sr.changed" --out "$T/sr.why" 2>/dev/null \
    || { echo "selfreads failed" >&2; return 1; }
  awk -F'\t' '$2 == "self" || $2 == "reads" { print $1 }' "$T/sr.why" | LC_ALL=C sort -u
}

# ── S1. tests/lib/scratch.sh: the ticket's own acceptance case.
selfreads tests/lib/scratch.sh > "$T/s1.sr" || bad "S1: the self/reads select failed"
[ -s "$T/s1.sr" ] && ok || bad "S1: tests/lib/scratch.sh must have self/reads suites"
printf 'tests/lib/scratch.sh\n' > "$T/s1.changed"
"$DIR/bin/test-impact.sh" regression --changed "$T/s1.changed" | cut -f1 > "$T/s1.reg" || bad "S1: the regression read failed"
LC_ALL=C sort -u "$T/s1.sr" "$T/canaries" "$T/always" "$T/s1.reg" | grep . > "$T/s1.want"
infra_ok S1 tests/lib/scratch.sh
S1N=$(out n)
EXTRA=$(LC_ALL=C comm -3 "$T/s1.want" <(LC_ALL=C sort -u "$T/list" 2>/dev/null))
[ -z "$EXTRA" ] && ok || bad "S1: the list must be exactly self/reads + canaries + always (diff: $(head -4 <<<"$EXTRA" | tr '\n' ' '))"
[ "$(out count)" = "$(grep -c . "$T/list" 2>/dev/null)" ] && ok || bad "S1: count=$(out count) must be the list's line count"
# under a tenth of the corpus: self/reads + 40 canaries + the always set (77 suites with the map's `*` rows)
[ -n "$(out count)" ] && [ "$(( $(out count) * 10 ))" -lt "$(out total)" ] && ok \
  || bad "S1: a scratch.sh-only batch must plan under a tenth of the corpus (count=$(out count) total=$(out total))"
has "infra: 1 path(s) (tests/lib/scratch.sh): $(grep -c . "$T/s1.sr") self/reads + 40 canaries (BH-7033.1)" "$(out summary)" && ok \
  || bad "S1: the summary must name the infra path and its counts: '$(out summary)'"
has "impact: $(out count) of $(out total) suites (infra: " "$(out summary)" && has "mode=infra" "$(out summary)" && ok \
  || bad "S1: the summary must count the list and say mode=infra: '$(out summary)'"
{ [ "$(out spa)" = 1 ] && [ "$(out worker)" = 1 ]; } && ok || bad "S1: spa and worker stay on in infra mode (spa=$(out spa) worker=$(out worker))"
has "escalation: -" "$SUM" && ok || bad "S1: the step summary must say escalation: - [$SUM]"

# ── S8. a shard re-plans S1 with the plan job's n and agrees.
OUT=$(env -u GITHUB_ACTIONS -u CI_INFRA_CANARY_FILE -u CI_FULL_TRIGGERS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t \
        TI_BASE="$HEADSHA" CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" \
        CI_PLAN_CHANGED_FILE="$T/s1.changed" CI_PLAN_TIER_FILE="$T/notiers.tsv" "$PLAN" --expect-n "${S1N:-x}" --out "$T/s8.list" 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ -n "$S1N" ] && cmp -s "$T/s8.list" "$T/list"; } && ok || bad "S8: a shard re-plan with --expect-n $S1N must agree (rc=$rc) [$(tail -2 <<<"$OUT")]"

# ── S2. .mergify.yml still runs the corpus.
escalates S2 "selection input: .mergify.yml" .mergify.yml

# ── S3. a non-workflow .github/ path is full; a top-level workflow is not.
escalates S3 "selection input: .github/actions/x/action.yml" .github/actions/x/action.yml
bplan .github/workflows/zz.yml
{ [ "$RC" = 0 ] && [ "$(out mode)" != full ] && [ "$(out mode)" != infra ]; } && ok \
  || bad "S3: a top-level workflow must select its readers (rc=$RC mode=$(out mode) escalation='$(out escalation)')"

# ── S4. every infra row of the tsv plans infra end to end.
for pat in ${INFRA_ROWS[@]+"${INFRA_ROWS[@]}"}; do
  infra_ok "S4 $pat" "$(sample "$pat")"
done

# ── S5. escalate beats infra: the settings row forces a moved path back to full.
escalates S5 "selection input: tests/lib/scratch.sh" tests/lib/scratch.sh -- CI_FULL_TRIGGERS=+tests/lib/scratch.sh

# ── S6. a full answer on the other paths still wins.
escalates S6 "unmapped: zz-unmapped-bh7287/x.sh" tests/lib/scratch.sh zz-unmapped-bh7287/x.sh -- CI_PLAN_MEMBER_UNION=0

# ── S7. the other paths' selection is kept.
infra_ok S7 tests/lib/scratch.sh bin/merge-sweep.sh
awk -F'\t' '$2 == "bin/merge-sweep.sh" { print $1 }' "$T/map" | LC_ALL=C sort -u > "$T/s7.map"
[ -s "$T/s7.map" ] && ok || bad "S7: the map has no row for bin/merge-sweep.sh"
[ -z "$(missing "$T/s7.map")" ] && ok || bad "S7: bin/merge-sweep.sh's suites are missing: $(missing "$T/s7.map" | head -3)"
has "infra: 1 path(s) (tests/lib/scratch.sh)" "$(out summary)" && has "selected: 1 changed path(s)" "$(out summary)" && ok \
  || bad "S7: the reason must carry the infra part and the rest's reason: '$(out summary)'"

# ── C1-C5. a canary list the planner cannot trust runs the corpus.
printf 'tests/zz-no-such-test.sh\n' > "$T/c2.txt"
printf 'tests/*.sh\n' > "$T/c3.txt"
printf 'tests/../tests/ci-plan-test.sh\n' > "$T/c4.txt"
printf '# nothing\n\n' > "$T/c5.txt"
for c in "C1 $T/no-such-canary.txt" "C2 $T/c2.txt" "C3 $T/c3.txt" "C4 $T/c4.txt" "C5 $T/c5.txt"; do
  bplan tests/lib/scratch.sh -- CI_INFRA_CANARY_FILE="${c#* }"
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && has "infra canary list unreadable (" "$(out escalation)" \
      && [ "$(out count)" = "$(out total)" ]; } && ok \
    || bad "${c%% *}: a bad canary list must run the corpus (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$(tail -2 <<<"$OUT")]"
done

# ── F1. the infra select fails: rc 2, no shard count.
cat > "$T/impact-fail.sh" <<EOF
#!/bin/bash
case " \$* " in *" --why --map-only "*) echo "stub: the infra select failed" >&2; exit 1 ;; esac
exec "$T/impact.sh" "\$@"
EOF
chmod +x "$T/impact-fail.sh"
bplan tests/lib/scratch.sh -- CI_PLAN_IMPACT="$T/impact-fail.sh"
{ [ "$RC" = 2 ] && ! grep -q '^n=' "$T/go" 2>/dev/null; } && ok || bad "F1: a failed infra select must be rc 2 with no n= (rc=$RC) [$(tail -2 <<<"$OUT")]"

# ── A scratch repo with the planner, its lib and the real rules, composed into
# one fragment ($RF).
G="$T/repo"; mkdir -p "$G/catalog" "$G/tests"
scratch_install_closure bin/ci-plan.sh "$G" > /dev/null || { echo "FAIL: cannot install bin/ci-plan.sh's closure"; exit 1; }
RF=catalog/ci-batch-escalate.d/rules.tsv
mkdir -p "$G/catalog/ci-batch-escalate.d" && cp "$TSV" "$G/$RF"
printf '#!/bin/bash\nexit 0\n' > "$G/tests/c-test.sh"
printf '# fixture canary list\ntests/c-test.sh\n' > "$G/canary.txt"
# The stub selector answers with two suites, and the corpus with ten.
cat > "$G/impact.sh" <<'EOF'
#!/bin/bash
cmd="$1"; shift; out=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift ;; esac; shift
done
if [ "$cmd" = select ]; then
  printf 'tests/a-test.sh\ntests/b-test.sh\n' > "$out"
  echo "impact: 2 of 10 suites (selected: 1 changed path(s))" >&2
else
  for i in 0 1 2 3 4 5 6 7 8 9; do echo "tests/s$i-test.sh"; done > "$out"
  echo "impact: 10 of 10 suites (full: corpus)" >&2
fi
EOF
printf '#!/bin/bash\ncat\n' > "$G/tiers.sh"
chmod +x "$G/impact.sh" "$G/tiers.sh"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm base \
  || { echo "FAIL: cannot commit the scratch base"; exit 1; }
BASE=$(git -C "$G" rev-parse HEAD)
edit() { # edit <tag> <cmd> — reset the rules file to the base, change it, commit
  git -C "$G" checkout -q "$BASE" -- $RF
  ( cd "$G" && eval "$2" ) || { bad "$1: the edit failed"; return 1; }
  git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qam "$1" --allow-empty
}
gplan() { # gplan [VAR=val ...] — the real planner in the scratch repo, TI_BASE=$BASE
  rm -f "$G/go"
  OUT=$(cd "$G" && env -u GITHUB_ACTIONS -u CI_FULL_TRIGGERS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$BASE" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$G/impact.sh" CI_PLAN_TIERS="$G/tiers.sh" \
          CI_INFRA_CANARY_FILE="$G/canary.txt" GITHUB_OUTPUT="$G/go" "$@" bin/ci-plan.sh --out "$G/list" 2>&1); RC=$?
  GO=$(cat "$G/go" 2>/dev/null)
}
# move_row — the bin/ci-plan.sh row, removed and re-added at the end of the file
move_row() {
  awk -F'\t' '$1 == "bin/ci-plan.sh" { m = $0; next } { print } END { print m }' $RF > x.tsv \
    && mv x.tsv $RF
}
cbd() { ( . "$G/bin/lib/ci-batch-escalate.sh" || exit 9; command -v cbe_deletes_row > /dev/null || exit 9; cbe_deletes_row "$@" ); }
# deletes <tag> <want-rc> — cbe_deletes_row over the current base..head diff
deletes() {
  local rc
  git -C "$G" diff --no-renames -U0 "$BASE" HEAD -- $RF > "$T/u.diff"
  cbd "$T/u.diff"; rc=$?
  [ "$rc" = "$2" ] && ok || bad "$1: cbe_deletes_row must be rc $2 (rc=$rc) [$(grep '^[-+][^-+]' "$T/u.diff" | head -4 | tr '\n' '|')]"
}

# ── U1-U9. cbe_deletes_row over real `git diff -U0` output. rc 0 = a delete (full).
edit U1 "sed -i '/^\.mergify\.yml\t/d' $RF"; deletes "U1 an escalate row removed" 0
edit U2 "sed -i 's/^\(\.mergify\.yml\t\)escalate\t/\1infra\t/' $RF"; deletes "U2 a kind changed" 0
edit U3 "printf 'zz-bh7287-doc.md\tallow\ta doc (fixture)\n' >> $RF"; deletes "U3 an added allow row" 0
edit U4 "printf 'zz-bh7287-two\tinfra\n' >> $RF"; deletes "U4 a malformed added row" 0
edit U4b "printf 'zz-bh7287-kind\tInfra\tx\n' >> $RF"; deletes "U4b an unknown kind" 0
edit U5 "sed -i 's/^\(tests\/lib\/scratch\.sh\tinfra\t\).*/\1the sandbox guard (changed)/' $RF"; deletes "U5 a why edit" 1
edit U6 "sed -i '1s/.*/# a changed first comment line/' $RF"; deletes "U6 a comment edit" 1
edit U7 "printf 'zz-bh7287-new.sh\tinfra\ta new runner (fixture)\n' >> $RF"; deletes "U7 an added infra row" 1
edit U8 move_row
deletes "U8 a row moved to another line" 1
grep -q $'^-bin/ci-plan.sh\t' "$T/u.diff" && ok || bad "U8: the fixture must remove and re-add the bin/ci-plan.sh row"
edit U9 "sed -i 's/^\(bin\/lib\/\*\.md\tallow\t\).*/\1a doc never selects on its own (changed)/' $RF"; deletes "U9 an allow row's why edit" 1
: > "$T/empty.diff"
cbd "$T/empty.diff"; [ "$?" = 0 ] && ok || bad "U10: an empty diff must count as a delete"
cbd "$T/no-such.diff"; [ "$?" = 0 ] && ok || bad "U10: a missing diff must count as a delete"
printf 'garbage\n' > "$T/bad.diff"
cbd "$T/bad.diff"; [ "$?" = 0 ] && ok || bad "U10: a diff it cannot parse must count as a delete"
# ── U11-U12. cbe_infra: an allow row beats it, and it never fails open.
printf 'bin/lib/\tinfra\tx\nbin/lib/*.md\tallow\tx\nzz-esc.sh\tescalate\tx\n' > "$T/u11.tsv"
r=$(CI_BATCH_ESCALATE_TSV="$T/u11.tsv" cbi bin/lib/x.sh); rc=$?; { [ "$rc" = 0 ] && [ -z "$r" ]; } && ok || bad "U11: bin/lib/x.sh must be infra, silently (rc=$rc out='$r')"
CI_BATCH_ESCALATE_TSV="$T/u11.tsv" cbi bin/lib/README.md; [ "$?" = 1 ] && ok || bad "U11: an allow row must beat an infra row"
CI_BATCH_ESCALATE_TSV="$T/u11.tsv" cbi zz-esc.sh; [ "$?" = 1 ] && ok || bad "U11: an escalate row is not an infra row"
CI_BATCH_ESCALATE_TSV="$T/u11.tsv" cbi bin/foo.sh; [ "$?" = 1 ] && ok || bad "U11: a path with no row is not infra"
CI_BATCH_ESCALATE_TSV="$T/no-such.tsv" cbi bin/lib/x.sh; [ "$?" = 1 ] && ok || bad "U12: an unreadable rules file is rc 1 here (cbe_reason escalates it)"
r=$(CI_BATCH_ESCALATE_TSV="$T/u11.tsv" cbe bin/lib/x.sh); rc=$?; { [ "$rc" = 1 ] && [ -z "$r" ]; } && ok || bad "U12: cbe_reason must skip an infra row (rc=$rc out='$r')"

# ── R1-R3. the rules file in a real batch diff.
edit R1 "printf 'zz-bh7287-esc.sh\tescalate\ta selection input (fixture)\n' >> $RF"
gplan
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && has "escalation rows added only (escalate)" "$(out summary)"; } && ok \
  || bad "R1: an add-only diff must select (rc=$RC mode=$(out mode) summary='$(out summary)') [$(tail -2 <<<"$OUT")]"
edit R2 "sed -i '/^\.mergify\.yml\t/d' $RF"
gplan
{ [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: $RF" ]; } && ok \
  || bad "R2: a deleted row must run the corpus (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$(tail -2 <<<"$OUT")]"
edit R3 "sed -i 's/^\(bin\/test-tiers\.sh\tinfra\t\).*/\1the tier step (changed)/' $RF"
gplan
{ [ "$RC" = 0 ] && [ "$(out mode)" = infra ] && [ "$(out escalation)" = - ] \
    && has "infra: 1 path(s) ($RF)" "$(out summary)" \
    && grep -qxF tests/c-test.sh "$G/list" && [ "$(out count)" = 3 ]; } && ok \
  || bad "R3: a why edit must plan infra with the canary (rc=$RC mode=$(out mode) count=$(out count) summary='$(out summary)') [$(tail -2 <<<"$OUT")]"

echo "ci-batch-escalate-select.bh-7287-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
